#!/bin/bash
# =============================================================================
# provision.sh: build the monitoring test rig inside a WSL Ubuntu 24.04 distro
# =============================================================================
#
# Same Prometheus, blackbox_exporter and Grafana versions as Monitoring-VM-001,
# installed the same way, so the production files run unchanged:
#   - production scrape addresses (10.x) are added to loopback by rig-net
#   - fakes.py serves exporters and Odoo sites on those addresses, and HTTPS
#     for uc/scripts.1stream.co.za with certificates from a rig-only CA
#   - Grafana sends mail to smtp-sink.py on 127.0.0.1:2525, never outside
#
# Run as root inside the distro (New-TestRig.ps1 does this):
#   bash tests/rig/provision.sh stage1   # wsl.conf, then the distro restarts
#   bash tests/rig/provision.sh          # everything else, idempotent
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

REPO=$(cd "$(dirname "$0")/../.." && pwd)
RIG=$REPO/tests/rig
PROM_VERSION=2.51.2
BBOX_VERSION=0.25.0
GRAFANA_VERSION=13.0.1
CACHE=/var/cache/rig

log() { echo "[rig] $*"; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Stage 1: systemd on, and /etc/hosts ours rather than WSL's
# -----------------------------------------------------------------------------
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[network]
generateHosts=false

[user]
default=root
EOF

if [[ "${1:-}" == "stage1" ]]; then
    log "wsl.conf written, restart the distro and run provision.sh again"
    exit 0
fi
[[ "$(ps -p 1 -o comm=)" == "systemd" ]] || { echo "systemd is not PID 1: restart the distro" >&2; exit 3; }

cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 $(hostname)
127.0.0.2 uc.1stream.co.za
127.0.0.3 scripts.1stream.co.za
::1 localhost ip6-localhost ip6-loopback
EOF

# -----------------------------------------------------------------------------
# Packages
# -----------------------------------------------------------------------------
# Order matters, as on the VM: the prometheus-node-exporter package creates
# `prometheus` as a SYSTEM user, and its postinst fails (exit 13) if a
# non-system `prometheus` user already exists. The June setup script installed
# the package before its own `useradd`, so the VM is fine. An earlier rig build
# did it the other way round; move such a user to a free system UID first.
if id prometheus &>/dev/null && (( $(id -u prometheus) >= 1000 )); then
    systemctl stop prometheus 2>/dev/null || true
    sysuid=$(for i in $(seq 999 -1 100); do getent passwd $i >/dev/null || getent group $i >/dev/null || { echo $i; break; }; done)
    usermod -u "$sysuid" prometheus && groupmod -g "$sysuid" prometheus
    chown -R prometheus:prometheus /etc/prometheus /data/prometheus
    log "prometheus user moved to system UID $sysuid"
fi

# A real node_exporter, as on the VM, but off to one side: the fakes own
# 127.0.0.1:9100 (the VM's own node target), so this one listens on
# 127.0.0.9:9101 and is not scraped. Its address is set before the package
# configures, and apt starts no services on the rig (policy-rc.d): the rig
# starts what it needs itself, after.
echo 'ARGS="--web.listen-address=127.0.0.9:9101"' > /etc/default/prometheus-node-exporter
log "apt packages"
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT
dpkg --configure -a >/dev/null
apt-get update -qq
apt-get install -y -qq -o Dpkg::Options::=--force-confold \
    curl ca-certificates openssl python3 python3-yaml python3-aiosmtpd \
    nginx fail2ban ufw jq sqlite3 adduser libfontconfig1 musl iproute2 iptables git \
    prometheus-node-exporter >/dev/null
rm -f /usr/sbin/policy-rc.d
systemctl enable -q prometheus-node-exporter
systemctl restart prometheus-node-exporter

mkdir -p "$CACHE"
fetch() { [[ -s "$CACHE/$2" ]] || curl -fsSL "$1" -o "$CACHE/$2"; }

# -----------------------------------------------------------------------------
# Prometheus, blackbox_exporter: upstream tarballs to /usr/local/bin, as live
# -----------------------------------------------------------------------------
id prometheus &>/dev/null        || useradd --no-create-home --shell /bin/false prometheus
id blackbox_exporter &>/dev/null || useradd --no-create-home --shell /bin/false blackbox_exporter

if [[ "$(/usr/local/bin/prometheus --version 2>/dev/null | head -1)" != *"$PROM_VERSION"* ]]; then
    log "Prometheus $PROM_VERSION"
    fetch "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" prom.tgz
    tar -xzf "$CACHE/prom.tgz" -C /tmp
    install -m 755 /tmp/prometheus-${PROM_VERSION}.linux-amd64/{prometheus,promtool} /usr/local/bin/
    rm -rf /tmp/prometheus-${PROM_VERSION}.linux-amd64
fi
install -d -o prometheus -g prometheus /etc/prometheus /data/prometheus

if [[ "$(/usr/local/bin/blackbox_exporter --version 2>&1 | head -1)" != *"$BBOX_VERSION"* ]]; then
    log "blackbox_exporter $BBOX_VERSION"
    fetch "https://github.com/prometheus/blackbox_exporter/releases/download/v${BBOX_VERSION}/blackbox_exporter-${BBOX_VERSION}.linux-amd64.tar.gz" bbox.tgz
    tar -xzf "$CACHE/bbox.tgz" -C /tmp
    install -m 755 /tmp/blackbox_exporter-${BBOX_VERSION}.linux-amd64/blackbox_exporter /usr/local/bin/
    rm -rf /tmp/blackbox_exporter-${BBOX_VERSION}.linux-amd64
fi
install -d -o blackbox_exporter -g blackbox_exporter /etc/blackbox_exporter

# -----------------------------------------------------------------------------
# Grafana: the .deb from dl.grafana.com, as live
# -----------------------------------------------------------------------------
if [[ "$(dpkg-query -W -f='${Version}' grafana 2>/dev/null || true)" != "$GRAFANA_VERSION" ]]; then
    log "Grafana $GRAFANA_VERSION"
    fetch "https://dl.grafana.com/oss/release/grafana_${GRAFANA_VERSION}_amd64.deb" grafana.deb
    dpkg -i "$CACHE/grafana.deb" >/dev/null || apt-get install -f -y -qq >/dev/null
fi

# Same edits the production setup script made, then a single rig [smtp] block.
GI=/etc/grafana/grafana.ini
if ! grep -q '^# RIG SMTP' "$GI"; then
    log "grafana.ini"
    sed -i "s|^;*\s*root_url\s*=.*|root_url = https://prometheus.1stream.co.za/|" "$GI"
    sed -i "s|^;*\s*serve_from_sub_path\s*=.*|serve_from_sub_path = false|" "$GI"
    sed -i "s|^;*\s*admin_password\s*=.*|admin_password = rig|" "$GI"
    sed -i "s|^;*\s*allow_sign_up\s*=.*|allow_sign_up = false|" "$GI"
    cat >> "$GI" <<'EOF'

# RIG SMTP: the rig's sink on 127.0.0.1:2525. Production uses M365 here.
[smtp]
enabled         = true
host            = 127.0.0.1:2525
from_address    = admin@1stream.co.za
from_name       = 1Stream Monitoring
startTLS_policy = NoStartTLS
skip_verify     = true
EOF
fi

# -----------------------------------------------------------------------------
# Rig CA and certificates: uc, scripts, and the wildcard nginx expects
# -----------------------------------------------------------------------------
CERTS=/etc/rig/certs
mkdir -p "$CERTS" /etc/nginx/ssl
if [[ ! -f $CERTS/rig-ca.crt ]]; then
    log "rig CA"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=1Stream monitoring test rig CA" \
        -keyout $CERTS/rig-ca.key -out $CERTS/rig-ca.crt 2>/dev/null
    cp $CERTS/rig-ca.crt /usr/local/share/ca-certificates/rig-ca.crt
    update-ca-certificates >/dev/null
fi
issue() {   # issue <name> <days> [san...]
    local name=$1 days=$2; shift 2
    local san; san=$(printf 'DNS:%s,' "$@"); san=${san%,}
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$1" -addext "subjectAltName=$san" \
        -keyout "$CERTS/$name.key" -out "$CERTS/$name.csr" 2>/dev/null
    openssl x509 -req -in "$CERTS/$name.csr" -CA $CERTS/rig-ca.crt -CAkey $CERTS/rig-ca.key \
        -CAcreateserial -days "$days" -copy_extensions copy -out "$CERTS/$name.crt" 2>/dev/null
    rm -f "$CERTS/$name.csr"
}
[[ -f $CERTS/uc.1stream.co.za.crt ]]      || issue uc.1stream.co.za 90 uc.1stream.co.za
[[ -f $CERTS/scripts.1stream.co.za.crt ]] || issue scripts.1stream.co.za 90 scripts.1stream.co.za
if [[ ! -f /etc/nginx/ssl/star.1stream.co.za.crt ]]; then
    issue star.1stream.co.za 365 '*.1stream.co.za'
    cp $CERTS/star.1stream.co.za.crt $CERTS/star.1stream.co.za.key /etc/nginx/ssl/
    chmod 600 /etc/nginx/ssl/star.1stream.co.za.key
fi

# -----------------------------------------------------------------------------
# Rig services: loopback addresses, fakes, SMTP sink, and the `rig` command
# -----------------------------------------------------------------------------
install -d /opt/rig /var/lib/rig/state /var/lib/rig/mail
install -m 644 "$RIG/rig-targets.json" /opt/rig/
install -m 755 "$RIG/fakes.py" "$RIG/smtp-sink.py" /opt/rig/
install -m 755 "$RIG/rig" /usr/local/bin/rig

cat > /usr/local/sbin/rig-net <<'EOF'
#!/bin/bash
# Add (up) or remove (down) the production 10.x addresses on loopback.
op=${1:-up}
for ip in $(python3 -c '
import json; c=json.load(open("/opt/rig/rig-targets.json"))
a={x.rsplit(":",1)[0] for x in c["exporters"]} | {s["bind"].rsplit(":",1)[0] for s in c["sites"].values()}
print("\n".join(sorted(i for i in a if not i.startswith("127."))))'); do
    if [[ $op == up ]]; then ip addr add "$ip/32" dev lo 2>/dev/null || true
    else ip addr del "$ip/32" dev lo 2>/dev/null || true; fi
done
# Sites whose production port is taken on the rig (nginx owns 0.0.0.0:443)
# listen elsewhere; NAT locally generated traffic from bind to listen.
python3 -c '
import json; c=json.load(open("/opt/rig/rig-targets.json"))
for s in c["sites"].values():
    if "listen" in s: print(s["bind"], s["listen"])' | while read -r bind listen; do
    rule=(OUTPUT -d "${bind%:*}" -p tcp --dport "${bind##*:}" -j DNAT --to-destination "$listen")
    iptables -t nat -D "${rule[@]}" 2>/dev/null || true
    [[ $op == up ]] && iptables -t nat -A "${rule[@]}"
done
exit 0
EOF
chmod 755 /usr/local/sbin/rig-net

cat > /etc/systemd/system/rig-net.service <<'EOF'
[Unit]
Description=Rig: production addresses on loopback
Before=rig-fakes.service prometheus.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rig-net up
ExecStop=/usr/local/sbin/rig-net down
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rig-fakes.service <<'EOF'
[Unit]
Description=Rig: fake exporters and sites
After=rig-net.service
Requires=rig-net.service
[Service]
Environment=RIG_TARGETS=/opt/rig/rig-targets.json
ExecStart=/usr/bin/python3 /opt/rig/fakes.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rig-smtp.service <<'EOF'
[Unit]
Description=Rig: SMTP sink on 127.0.0.1:2525
[Service]
ExecStart=/usr/bin/python3 /opt/rig/smtp-sink.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q rig-net rig-fakes rig-smtp
systemctl restart rig-net rig-fakes rig-smtp

# -----------------------------------------------------------------------------
# The repo's files, then the services
# -----------------------------------------------------------------------------
bash "$RIG/rig-deploy.sh"
log "provisioned: $(rig status | tail -1)"
