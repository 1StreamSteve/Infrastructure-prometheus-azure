#!/usr/bin/env bash
# setup-exporters.sh
# Run on nginx LB VMs (VM1, VM2) to install BOTH exporters and open UFW.
# Self-contained — does NOT depend on deploy.sh having run first.
#
# Installs:
#   - prometheus-node-exporter     (:9100) — OS metrics
#   - prometheus-nginx-exporter    (:9113) — nginx stub_status metrics
#
# Prerequisites:
#   - nginx must be installed and running
#   - nginx stub_status must be enabled (the script configures it if missing)
#
# Usage:
#   sudo bash setup-exporters.sh <MONITORING-VM-PRIVATE-IP>
#
# Example:
#   sudo bash setup-exporters.sh 10.0.0.6

set -euo pipefail

MONITORING_IP="${1:-}"

[[ $EUID -eq 0 ]]       || { echo "Run as root (sudo bash $0 <monitoring-ip>)"; exit 1; }
[[ -n "$MONITORING_IP" ]] || { echo "Usage: sudo bash $0 <MONITORING-VM-PRIVATE-IP>"; exit 1; }
[[ "$MONITORING_IP" == *"<"* ]] && { echo "Error: replace <MONITORING-VM-PRIVATE-IP> with the actual IP."; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== nginx LB exporter setup for $(hostname) ==="
log "Monitoring VM IP: ${MONITORING_IP}"

# ── 1. Confirm nginx is running ─────────────────────────────────────────────
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    log "FATAL: nginx is not running. Install and configure nginx first."
    exit 1
fi

# ── 2. Enable nginx stub_status (required by nginx exporter) ────────────────
STUB_CONF="/etc/nginx/conf.d/stub-status.conf"
if ! curl -sf http://127.0.0.1:8080/stub_status &>/dev/null; then
    log "Configuring nginx stub_status on 127.0.0.1:8080..."
    cat > "$STUB_CONF" << 'EOF'
# Prometheus nginx exporter needs stub_status.
# Bound to localhost only — not accessible from the network.
server {
    listen 127.0.0.1:8080;
    server_name _;

    location /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }

    location / {
        return 404;
    }
}
EOF
    nginx -t || { log "FATAL: nginx config test failed after adding stub_status."; rm -f "$STUB_CONF"; exit 1; }
    systemctl reload nginx
    sleep 1
    log "stub_status enabled."
else
    log "stub_status already responding — skipping."
fi

# ── 3. Install node_exporter ─────────────────────────────────────────────────
if systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
    log "node_exporter already running — skipping install."
else
    log "Installing prometheus-node-exporter..."
    apt-get update -qq
    apt-get install -y -qq prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter
fi

# ── 4. Install nginx exporter ───────────────────────────────────────────────
if systemctl is-active --quiet prometheus-nginx-exporter 2>/dev/null; then
    log "nginx-exporter already running — skipping install."
else
    log "Installing prometheus-nginx-exporter..."
    apt-get install -y -qq prometheus-nginx-exporter 2>/dev/null || {
        # If not in apt repos, install from GitHub release
        log "Not in apt — installing from GitHub..."
        NGXEXP_VERSION="1.3.0"
        NGXEXP_URL="https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v${NGXEXP_VERSION}/nginx-prometheus-exporter_${NGXEXP_VERSION}_linux_amd64.tar.gz"

        cd /tmp
        wget -q "$NGXEXP_URL" -O nginx-prometheus-exporter.tar.gz
        tar xzf nginx-prometheus-exporter.tar.gz
        install -m 755 nginx-prometheus-exporter /usr/local/bin/
        rm -rf nginx-prometheus-exporter.tar.gz nginx-prometheus-exporter

        # Create service user
        id nginx_exporter &>/dev/null || useradd --no-create-home --shell /bin/false nginx_exporter

        # Create systemd service
        cat > /etc/systemd/system/prometheus-nginx-exporter.service << 'EOF'
[Unit]
Description=Prometheus nginx Exporter
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=nginx_exporter
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
  --nginx.scrape-uri=http://127.0.0.1:8080/stub_status \
  --web.listen-address=:9113
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    }

    systemctl enable --now prometheus-nginx-exporter
fi

# ── 5. UFW — allow monitoring VM to scrape both exporters ────────────────────
log "Opening UFW ports 9100 + 9113 for ${MONITORING_IP}..."

if ! ufw status | grep -q "9100.*${MONITORING_IP}"; then
    ufw allow from "${MONITORING_IP}" to any port 9100 proto tcp \
        comment "node_exporter — monitoring VM"
fi

if ! ufw status | grep -q "9113.*${MONITORING_IP}"; then
    ufw allow from "${MONITORING_IP}" to any port 9113 proto tcp \
        comment "nginx-exporter — monitoring VM"
fi

ufw reload

# ── 6. Smoke test ─────────────────────────────────────────────────────────────
log "Smoke test..."
PASS=0; FAIL=0
check() {
    local label="$1" cmd="$2" retries=5
    for ((i=1; i<=retries; i++)); do
        if eval "$cmd" &>/dev/null; then
            echo "  PASS  $label"; PASS=$((PASS+1)); return
        fi
        sleep 2
    done
    echo "  FAIL  $label"; FAIL=$((FAIL+1))
}

check "nginx running"                "systemctl is-active --quiet nginx"
check "stub_status responding"       "curl -sf http://127.0.0.1:8080/stub_status | grep -q 'Active connections'"
check "node_exporter running"        "systemctl is-active --quiet prometheus-node-exporter"
check "node_exporter :9100 up"       "curl -sf http://127.0.0.1:9100/metrics | grep -q node_exporter_build"
check "nginx-exporter running"       "systemctl is-active --quiet prometheus-nginx-exporter"
check "nginx-exporter :9113 up"      "curl -sf http://127.0.0.1:9113/metrics | grep -q nginx_up"
# UFW checks — skip if firewall is inactive
if ufw status | grep -q "Status: active"; then
    check "UFW 9100 rule present"    "ufw status | grep -q '9100.*${MONITORING_IP}'"
    check "UFW 9113 rule present"    "ufw status | grep -q '9113.*${MONITORING_IP}'"
else
    log "UFW is inactive — skipping rule checks (rules were added but won't apply until 'ufw enable')"
fi

echo ""
echo "Result: ${PASS} PASS, ${FAIL} FAIL"
[[ $FAIL -gt 0 ]] && { echo "Some checks failed — see above."; exit 1; }

log "=== Done. $(hostname) is ready to be scraped by ${MONITORING_IP} ==="
