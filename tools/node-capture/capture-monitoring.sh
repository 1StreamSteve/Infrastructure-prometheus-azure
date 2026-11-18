#!/bin/bash
# =============================================================================
# capture-monitoring.sh: read-only snapshot of the Azure monitoring VM
# =============================================================================
#
# Collects the files the Prometheus/Grafana/blackbox/nginx build depends on,
# plus live state from Prometheus's API and Grafana's database, into one
# tarball, and prints it as base64 on stdout between BEGIN/END markers.
# Progress, warnings and findings go to stderr.
#
# Built to run as root through an Azure managed Run Command (see
# Invoke-NodeCapture.ps1), but runs the same way by hand:
#     sudo bash capture-monitoring.sh > node.b64 2> node.log
#
# It changes nothing on the node. Grafana's database is opened read-only
# (sqlite mode=ro). The only writes are to a mktemp directory removed on exit.
#
# Left out or scrubbed on purpose:
#   - /etc/nginx/ssl and any *.key *.pem *.crt *.pfx *.p12. Only a listing and
#     each certificate's subject, issuer and expiry are recorded.
#   - ELF binaries under /usr/local (prometheus, promtool, blackbox_exporter).
#     Recorded with size and sha256 in _state/usr-local-binaries.txt.
#   - grafana.db itself (users, password hashes, API keys). Only the alerting,
#     folder, dashboard, datasource (no secure fields) and annotation tables
#     are read out.
#   - Any password/secret/token/api key value in a captured file is replaced
#     with REDACTED-BY-CAPTURE, as is the password in any user:pass@ URL.
#   - Shell history.
#
# Exit codes: 0 ok, 2 copy failed, 3 archive implausibly large.
# =============================================================================

set -euo pipefail
umask 077
export LC_ALL=C

log() { echo "[capture] $*" >&2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s)
WORK=$(mktemp -d /tmp/moncap.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/$HOST"
FS="$ROOT/fs"
STATE="$ROOT/_state"
PROMD="$STATE/prom"
GDB="$STATE/grafana-db"
mkdir -p "$FS" "$STATE" "$PROMD" "$GDB"

PROM=http://127.0.0.1:9090
log "host=$HOST ts=$TS"

# -----------------------------------------------------------------------------
# 1. Files
# -----------------------------------------------------------------------------
PATHS=(
    /etc/prometheus
    /etc/blackbox_exporter
    /etc/grafana
    /etc/nginx
    /var/www
    /usr/local/bin
    /usr/local/sbin
    /usr/local/etc
    /etc/crontab
    /etc/cron.d
    /etc/cron.daily
    /var/spool/cron/crontabs
    /etc/systemd/system
    /etc/logrotate.d
    /etc/ufw
    /etc/default
    /etc/fail2ban
    /etc/netplan
    /etc/hosts
    /etc/hostname
    /etc/apt/sources.list
    /etc/apt/sources.list.d
    /etc/apt/preferences.d
)

REL=()
for p in "${PATHS[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then REL+=("${p#/}"); else log "absent: $p"; fi
done

# Small text files in home directories (the original build was scp'd to
# ~/monitoring). No dot-directories, no history.
while IFS= read -r -d '' f; do
    REL+=("${f#/}")
done < <(find /home /root -maxdepth 4 -type f -size -1M \
            -not -path '*/.*' -print0 2>/dev/null)

BIN_LIST="$STATE/usr-local-binaries.txt"
: > "$BIN_LIST"
EXCLUDES=(
    --exclude=etc/nginx/ssl
    --exclude='*.key' --exclude='*.pem' --exclude='*.crt'
    --exclude='*.pfx' --exclude='*.p12' --exclude='*.db'
)
while IFS= read -r -d '' f; do
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)
    if [[ "$magic" == "7f454c46" ]]; then
        printf '%s  %s bytes  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" \
            "$(stat -c %s "$f")" "$f" >> "$BIN_LIST"
        EXCLUDES+=("--exclude=${f#/}")
    fi
done < <(find /usr/local /home /root -maxdepth 4 -type f -print0 2>/dev/null)

set +e
tar -C / "${EXCLUDES[@]}" -cf - "${REL[@]}" 2>"$WORK/tar.err" \
    | tar -C "$FS" -xpf - 2>>"$WORK/tar.err"
rcs=("${PIPESTATUS[@]}")
set -e
if (( rcs[0] > 1 || rcs[1] != 0 )); then
    log "copy FAILED (tar exit ${rcs[*]})"
    cat "$WORK/tar.err" >&2
    exit 2
fi
[[ -s "$WORK/tar.err" ]] && { log "tar warnings:"; cat "$WORK/tar.err" >&2; }

# -----------------------------------------------------------------------------
# 2. Scrub
# -----------------------------------------------------------------------------
while IFS= read -r f; do
    rm -f "$f"
    log "REMOVED (private key block): ${f#"$FS"/}"
done < <(grep -rlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$FS" 2>/dev/null || true)

# Redact the value of anything that looks like a secret assignment, in ini,
# shell, env and yaml forms, and passwords inside user:pass@ URLs.
SECRET_KEYS='[A-Za-z0-9_.-]*(password|passwd|secret|token|api_?key|licensekey)[A-Za-z0-9_.-]*'
while IFS= read -r f; do
    sed -i -E \
        -e "s/^([[:space:]]*;?[[:space:]]*\"?${SECRET_KEYS}\"?[[:space:]]*[=:][[:space:]]*).+$/\1REDACTED-BY-CAPTURE/I" \
        -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1REDACTED-BY-CAPTURE@#g' \
        "$f"
    log "redacted: ${f#"$FS"/}"
done < <(grep -rlIiE "(${SECRET_KEYS}[\"]?[[:space:]]*[=:])|(://[^:/@[:space:]]+:[^@[:space:]]+@)" "$FS" 2>/dev/null || true)

# -----------------------------------------------------------------------------
# 3. Live state. Each command's exit code is written into its own file, so a
#    failure shows up as a failure and never as an empty "nothing here".
# -----------------------------------------------------------------------------
cap() {
    local name=$1; shift
    local out="$STATE/$name.txt"
    { echo "\$ $*"; "$@"; } > "$out" 2>&1
    echo "[exit $?]" >> "$out"
}
capsh() {
    local name=$1 cmd=$2
    local out="$STATE/$name.txt"
    { echo "\$ $cmd"; bash -c "$cmd"; } > "$out" 2>&1
    echo "[exit $?]" >> "$out"
}

set +e
cap  os-release        cat /etc/os-release
cap  uname             uname -a
cap  uptime            uptime
cap  df                df -hT
capsh versions         'for b in prometheus promtool blackbox_exporter; do echo "== $b"; command -v $b; $b --version 2>&1 | head -3; done; echo "== grafana"; grafana-server -v 2>&1 || grafana server -v 2>&1; dpkg -l grafana 2>&1 | tail -1'
cap  promtool-check    promtool check config /etc/prometheus/prometheus.yml
capsh blackbox-check   'blackbox_exporter --config.check --config.file=/etc/blackbox_exporter/blackbox.yml'
cap  nginx-t           nginx -t
cap  nginx-T           nginx -T
capsh ssl-listing      'find /etc/nginx/ssl -printf "%M %u:%g %10s %TY-%Tm-%Td %p\n" 2>&1'
capsh ssl-certs        'find /etc/nginx/ssl -name "*.crt" -type f | while read -r c; do echo "== $c"; openssl x509 -in "$c" -noout -subject -issuer -enddate -ext subjectAltName 2>&1; done'
cap  units-enabled     systemctl list-unit-files --state=enabled --no-pager
cap  units-failed      systemctl list-units --failed --no-pager
cap  timers            systemctl list-timers --all --no-pager
capsh unit-cat         'for u in prometheus grafana-server blackbox_exporter prometheus-node-exporter nginx fail2ban; do systemctl cat "$u" 2>&1; echo; systemctl is-active "$u"; echo; done'
capsh unit-status      'for u in prometheus grafana-server blackbox_exporter prometheus-node-exporter nginx fail2ban; do systemctl status "$u" --no-pager -l 2>&1 | head -15; echo; done'
capsh crontabs-l       'for u in $(cut -d: -f1 /etc/passwd); do o=$(crontab -l -u "$u" 2>/dev/null) && { echo "== $u"; echo "$o"; }; done; true'
cap  ufw-status        ufw status verbose
cap  fail2ban-status   fail2ban-client status
cap  ip-addr           ip -br addr
cap  ip-route          ip route
cap  listening         ss -tlnp
cap  packages          dpkg-query -W -f='${Package}\t${Version}\n'
cap  apt-holds         apt-mark showhold
capsh home-tree        'find /home /root -maxdepth 4 -not -path "*/.*" -printf "%M %u:%g %10s %TY-%Tm-%Td %p\n" 2>&1'
capsh opt-tree         'find /opt -maxdepth 2 -printf "%M %u:%g %p\n"'
capsh prom-data        'du -sh /data/prometheus 2>&1; ls -la /data/prometheus 2>&1 | head -40'
capsh grafana-var      'ls -la /var/lib/grafana /var/lib/grafana/alerting 2>&1; du -sh /var/lib/grafana 2>&1'
capsh grafana-log-ngalert 'tail -n 300000 /var/log/grafana/grafana.log 2>/dev/null | grep -E "logger=ngalert|logger=alerting|level=error" | tail -n 6000'
capsh prom-journal     'journalctl -u prometheus --since "7 days ago" --no-pager -p warning 2>&1 | tail -n 500'
capsh bbox-journal     'journalctl -u blackbox_exporter --since "7 days ago" --no-pager 2>&1 | tail -n 500'
capsh grafana-journal  'journalctl -u grafana-server --since "7 days ago" --no-pager -p warning 2>&1 | tail -n 500'
set -e

# -----------------------------------------------------------------------------
# 4. Prometheus API. Instant queries and status endpoints, then failure and
#    slow-probe events over 30 days in one-day chunks (subqueries that only
#    return the bad samples), then raw external probe samples for 30 days.
# -----------------------------------------------------------------------------
pget() {   # pget <name> <path> [curl -G args...]
    local name=$1 path=$2; shift 2
    local out="$PROMD/$name.json"
    curl -sS --max-time 120 -G "$PROM$path" "$@" > "$out" 2> "$out.err"
    local rc=$?
    if [[ $rc -ne 0 ]]; then log "prom $name FAILED (curl $rc)"; else rm -f "$out.err"; fi
}
pq() {     # pq <name> <promql> [unix time]
    local name=$1 expr=$2 t=${3:-}
    if [[ -n "$t" ]]; then pget "$name" /api/v1/query --data-urlencode "query=$expr" --data-urlencode "time=$t"
    else pget "$name" /api/v1/query --data-urlencode "query=$expr"; fi
}

set +e
if curl -sf --max-time 5 "$PROM/-/ready" >/dev/null; then
    pget buildinfo   /api/v1/status/buildinfo
    pget flags       /api/v1/status/flags
    pget runtime     /api/v1/status/runtimeinfo
    pget config      /api/v1/status/config
    pget tsdb        /api/v1/status/tsdb
    pget targets     /api/v1/targets
    pget rules       /api/v1/rules
    pq up                 'up'
    pq node-uname         'node_uname_info'
    pq node-cpus          'count by (job, instance, vm) (node_cpu_seconds_total{mode="idle"})'
    pq ssl-days-left      '(probe_ssl_earliest_cert_expiry - time()) / 86400'
    pq ssl-chain          'probe_ssl_last_chain_info'
    pq probe-http-version 'probe_http_version'
    pq probe-success-30d  'avg_over_time(probe_success[30d])'
    pq probe-dur-p50-30d  'quantile_over_time(0.5, probe_duration_seconds[30d])'
    pq probe-dur-p95-30d  'quantile_over_time(0.95, probe_duration_seconds[30d])'
    pq probe-dur-p99-30d  'quantile_over_time(0.99, probe_duration_seconds[30d])'
    pq probe-dur-max-30d  'max_over_time(probe_duration_seconds[30d])'
    pq up-avg-30d         'avg_over_time(up[30d])'
    pq cpu-by-vm-now      '100 - (avg by (customer, vm, instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
    pq load1-now          'node_load1'
    pq mem-free-pct-now   '(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100'
    pq disk-free-pct-now  '(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}) * 100'
    pq pg-max-tx-now      'pg_stat_activity_max_tx_duration'

    NOW=$(date +%s)
    mkdir -p "$PROMD/events" "$PROMD/ext-raw"
    for d in $(seq 0 29); do
        t=$(( NOW - d * 86400 ))
        n=$(printf '%02d' "$d")
        pq "events/probe-fail-d$n"  '(probe_success == 0)[1d:15s]' "$t"
        pq "events/probe-slow-d$n"  '(probe_duration_seconds > 3)[1d:15s]' "$t"
        pq "events/up-down-d$n"     '(up == 0)[1d:15s]' "$t"
        pq "ext-raw/d$n" '{__name__=~"probe_success|probe_duration_seconds|probe_http_status_code",job=~"blackbox-ext-.*"}[1d]' "$t"
        for ph in resolve connect tls processing transfer; do
            pq "ext-raw/phase-$ph-d$n" "probe_http_duration_seconds{phase=\"$ph\",job=~\"blackbox-ext-.*\"}[1d]" "$t"
        done
    done
    log "prometheus API captured"
else
    log "Prometheus not ready at $PROM, API state skipped"
fi
set -e

# -----------------------------------------------------------------------------
# 5. Grafana database, read-only. Alerting, folders, dashboards, datasources
#    (no secure fields) and 45 days of alert state history (annotations).
# -----------------------------------------------------------------------------
set +e
python3 - "$GDB" <<'PY' 2>&1 | sed 's/^/[capture] /' >&2
import json, os, sqlite3, sys, time
out = sys.argv[1]
db = '/var/lib/grafana/grafana.db'
if not os.path.exists(db):
    print('grafana.db not found'); sys.exit(0)
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
con.row_factory = sqlite3.Row

def enc(o):
    if isinstance(o, (bytes, bytearray)):
        return o.decode('utf-8', 'replace')
    return str(o)

def q(name, sql, args=()):
    try:
        rows = [dict(r) for r in con.execute(sql, args)]
        res = {'ok': True, 'rows': rows}
        msg = f'{len(rows)} rows'
    except Exception as e:
        res = {'ok': False, 'error': str(e), 'sql': sql}
        msg = f'ERROR {e}'
    with open(os.path.join(out, name + '.json'), 'w') as f:
        json.dump(res, f, indent=1, default=enc)
    print(f'grafana-db {name}: {msg}')
    return res

q('tables', "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
q('folder', 'SELECT * FROM folder')
q('dashboard-list', 'SELECT id, uid, title, slug, is_folder, folder_id, folder_uid, version, created, updated FROM dashboard')
q('dashboard-provisioning', 'SELECT * FROM dashboard_provisioning')
q('alert_rule', 'SELECT * FROM alert_rule')
q('alert_rule_version-summary', 'SELECT rule_uid, count(*) AS versions, max(created) AS last_change FROM alert_rule_version GROUP BY rule_uid')
q('provenance_type', 'SELECT * FROM provenance_type')
q('alert_configuration', 'SELECT * FROM alert_configuration')
q('alert_configuration_history', 'SELECT id, org_id, configuration_hash, configuration_version, created_at, "default", last_applied FROM alert_configuration_history ORDER BY id')
q('alert_instance', 'SELECT * FROM alert_instance')
q('data_source', 'SELECT id, uid, name, type, access, url, is_default, json_data, version, updated FROM data_source')
since_ms = int((time.time() - 45 * 86400) * 1000)
q('annotation-alerts-45d', 'SELECT id, alert_id, epoch, epoch_end, prev_state, new_state, text, data, dashboard_uid, panel_id FROM annotation WHERE alert_id > 0 AND epoch >= ? ORDER BY epoch', (since_ms,))

ddir = os.path.join(out, 'dashboards')
os.makedirs(ddir, exist_ok=True)
try:
    for r in con.execute('SELECT uid, title, data FROM dashboard WHERE is_folder = 0'):
        with open(os.path.join(ddir, f"{r['uid']}.json"), 'w') as f:
            f.write(enc(r['data']) if not isinstance(r['data'], str) else r['data'])
    print(f'grafana-db dashboards written: {len(os.listdir(ddir))}')
except Exception as e:
    print(f'grafana-db dashboards ERROR {e}')
PY
set -e

# Report, don't print, anything still credential-like, for review before any
# of it is committed.
grep -rliE '(password|passwd|secret|token|apikey|api_key)[[:space:]"]*[=:]' "$ROOT" 2>/dev/null \
    | grep -v '/_state/prom/' \
    | sed "s|^$ROOT/|[capture] REVIEW (credential-like string): |" >&2 || true

# -----------------------------------------------------------------------------
# 6. Manifest and archive
# -----------------------------------------------------------------------------
( cd "$ROOT" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z \
    | xargs -0 sha256sum ) > "$ROOT/MANIFEST.sha256"
log "files captured: $(wc -l < "$ROOT/MANIFEST.sha256")"

ARCHIVE="$WORK/$HOST-$TS.tgz"
tar -C "$WORK" -czf "$ARCHIVE" "$HOST"
SIZE=$(stat -c %s "$ARCHIVE")
SUM=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
log "archive $(basename "$ARCHIVE") ${SIZE} bytes sha256=$SUM"

if (( SIZE > 50 * 1024 * 1024 )); then
    log "archive over 50MB, refusing to emit it"
    exit 3
fi

echo "-----BEGIN NODECAP host=$HOST ts=$TS bytes=$SIZE sha256=$SUM-----"
base64 -w 76 "$ARCHIVE"
echo "-----END NODECAP-----"
log "done"
