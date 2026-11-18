#!/usr/bin/env python3
"""Fake exporters and fake sites for the monitoring test rig.

Every exporter and site in rig-targets.json listens on its production address
(the rig puts those addresses on loopback). Behaviour is read from a JSON state
file per target on every request, so tests change it with `rig` while running.

Exporter state  /var/lib/rig/state/exp_<ip>_<port>.json
  node      cpu_busy (%), load1, mem_avail_pct, disk_free_pct
  postgres  pg_up, max_tx (s), deadlocks_per_s
  nginx     nginx_up, conns
  any       down: true  -> HTTP 503, so Prometheus records up=0

Site state      /var/lib/rig/state/site_<name>.json
  mode: ok | slow | error | hang | reset | tlshang
  arg:  seconds for slow/hang/tlshang, status code for error
"""
import json, os, socket, ssl, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = '/var/lib/rig/state'
CERTS = '/etc/rig/certs'
CFG = json.load(open(os.environ.get('RIG_TARGETS', os.path.join(HERE, 'rig-targets.json'))))

DEFAULTS = {
    'node': {'cpu_busy': 20, 'load1': 0.5, 'mem_avail_pct': 50, 'disk_free_pct': 60},
    'postgres': {'pg_up': 1, 'max_tx': 0, 'deadlocks_per_s': 0},
    'nginx': {'nginx_up': 1, 'conns': 10},
    'site': {'mode': 'ok', 'arg': 0},
}


def load_state(name, kind):
    s = dict(DEFAULTS[kind])
    try:
        with open(os.path.join(STATE, name + '.json')) as f:
            s.update(json.load(f))
    except (FileNotFoundError, ValueError):
        pass
    return s


EPOCH = 1.7e9   # counters start as if they had run at their rate since 2023


class Counters:
    """Monotonic counters integrated over time, so changing a rate mid-test
    never makes a counter go backwards. They start from wall-clock time at
    their rate, so a restart of the fakes is not seen as a counter reset (which
    Prometheus would turn into a burst, e.g. 90% CPU)."""
    def __init__(self):
        self.lock = threading.Lock()
        self.last = {}
        self.vals = {}

    def advance(self, key, rates):
        now = time.time()
        with self.lock:
            dt = now - self.last.get(key, now)
            self.last[key] = now
            v = self.vals.setdefault(key, {k: (now - EPOCH) * r for k, r in rates.items()})
            for k, r in rates.items():
                v[k] = v.get(k, (now - EPOCH) * r) + dt * r
            return dict(v)


COUNTERS = Counters()


def node_metrics(key, meta, s):
    busy = max(0.0, min(100.0, float(s['cpu_busy']))) / 100
    rates = {}
    for cpu in ('0', '1'):
        rates[f'idle{cpu}'] = 1 - busy
        rates[f'user{cpu}'] = busy * 0.8
        rates[f'system{cpu}'] = busy * 0.2
    c = COUNTERS.advance(key, rates)
    total_mem, size = 8 * 2**30, 128 * 2**30
    out = ['# TYPE node_cpu_seconds_total counter']
    for cpu in ('0', '1'):
        for mode in ('idle', 'user', 'system'):
            out.append(f'node_cpu_seconds_total{{cpu="{cpu}",mode="{mode}"}} {c[mode + cpu]:.3f}')
    out += [
        f'node_load1 {float(s["load1"])}',
        f'node_memory_MemTotal_bytes {total_mem}',
        f'node_memory_MemAvailable_bytes {total_mem * float(s["mem_avail_pct"]) / 100:.0f}',
        f'node_filesystem_size_bytes{{device="/dev/root",fstype="ext4",mountpoint="/"}} {size}',
        f'node_filesystem_avail_bytes{{device="/dev/root",fstype="ext4",mountpoint="/"}} {size * float(s["disk_free_pct"]) / 100:.0f}',
        f'node_uname_info{{nodename="{meta.get("nodename", "rig")}",release="6.8.0",sysname="Linux"}} 1',
        'node_exporter_build_info{version="rig"} 1',
    ]
    return out


def postgres_metrics(key, meta, s):
    c = COUNTERS.advance(key, {'deadlocks': float(s['deadlocks_per_s'])})
    return [
        f'pg_up {int(s["pg_up"])}',
        f'pg_stat_activity_max_tx_duration{{datname="odoo",server="127.0.0.1:5432",state="active"}} {float(s["max_tx"])}',
        'pg_stat_activity_max_tx_duration{datname="odoo",server="127.0.0.1:5432",state="idle"} 0',
        '# TYPE pg_stat_database_deadlocks counter',
        f'pg_stat_database_deadlocks{{datid="16384",datname="odoo",server="127.0.0.1:5432"}} {c["deadlocks"]:.3f}',
    ]


def nginx_metrics(key, meta, s):
    return [f'nginx_up {int(s["nginx_up"])}',
            f'nginx_connections_active {float(s["conns"])}',
            'nginxexporter_build_info{version="rig"} 1']


GEN = {'node': node_metrics, 'postgres': postgres_metrics, 'nginx': nginx_metrics}


def exporter_handler(addr, meta):
    key = 'exp_' + addr.replace(':', '_')

    class H(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *a):
            pass

        def do_GET(self):
            s = load_state(key, meta['type'])
            if s.get('down'):
                body, code = b'down (rig)\n', 503
            else:
                body, code = ('\n'.join(GEN[meta['type']](key, meta, s)) + '\n').encode(), 200
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    return H


def site_handler(name):
    key = 'site_' + name

    class H(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *a):
            pass

        def do_GET(self):
            s = load_state(key, 'site')
            mode, arg = s['mode'], float(s.get('arg') or 0)
            if mode == 'reset':
                self.close_connection = True
                self.connection.close()
                return
            if mode in ('slow', 'hang'):
                time.sleep(arg or 60)
            code = int(arg) if mode == 'error' else 200
            body = f'{name} {mode}\n'.encode()
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    return H


class SiteServer(ThreadingHTTPServer):
    """TLS is wrapped per connection in the worker thread, so `tlshang` can
    stall the handshake the way scripts.1stream.co.za does."""
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, bind, handler, name, ctx):
        self.name, self.ctx = name, ctx
        super().__init__(bind, handler)

    def finish_request(self, request, client_address):
        if self.ctx is not None:
            s = load_state('site_' + self.name, 'site')
            if s['mode'] == 'tlshang':
                time.sleep(float(s.get('arg') or 30))
            try:
                request = self.ctx.wrap_socket(request, server_side=True)
            except (ssl.SSLError, OSError):
                return
        super().finish_request(request, client_address)


class ExpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def split(addr):
    host, port = addr.rsplit(':', 1)
    return host, int(port)


def main():
    os.makedirs(STATE, exist_ok=True)
    servers = []
    for addr, meta in CFG['exporters'].items():
        servers.append(ExpServer(split(addr), exporter_handler(addr, meta)))
    for name, meta in CFG['sites'].items():
        ctx = None
        if meta.get('tls'):
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(f'{CERTS}/{meta["host"]}.crt', f'{CERTS}/{meta["host"]}.key')
        servers.append(SiteServer(split(meta.get('listen', meta['bind'])), site_handler(name), name, ctx))
    for srv in servers:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f'rig fakes: {len(servers)} listeners up', flush=True)
    while True:
        time.sleep(3600)


if __name__ == '__main__':
    main()
