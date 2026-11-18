#!/usr/bin/env bash
# install-blackbox-exporter.sh
# Run on the monitoring VM to add blackbox_exporter to an existing setup.
#
# Usage:
#   sudo bash install-blackbox-exporter.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

BBOX_VERSION="0.25.0"

# ── 1. Install binary ───────────────────────────────────────────────────────
log "Downloading blackbox_exporter ${BBOX_VERSION}..."
cd /tmp
wget -q "https://github.com/prometheus/blackbox_exporter/releases/download/v${BBOX_VERSION}/blackbox_exporter-${BBOX_VERSION}.linux-amd64.tar.gz" -O blackbox_exporter.tar.gz
tar xzf blackbox_exporter.tar.gz
install -m 755 "blackbox_exporter-${BBOX_VERSION}.linux-amd64/blackbox_exporter" /usr/local/bin/
rm -rf blackbox_exporter.tar.gz "blackbox_exporter-${BBOX_VERSION}.linux-amd64"

# ── 2. Config ────────────────────────────────────────────────────────────────
log "Writing /etc/blackbox_exporter/blackbox.yml..."
mkdir -p /etc/blackbox_exporter
cat > /etc/blackbox_exporter/blackbox.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 15s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200, 301, 302, 303]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  http_post_2xx:
    prober: http
    timeout: 15s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: POST
      preferred_ip_protocol: "ip4"

  http_2xx_lenient:
    prober: http
    timeout: 15s
    http:
      valid_status_codes: [200, 301, 302, 303]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"

  icmp:
    prober: icmp
    timeout: 5s
EOF

# ── 3. Service user ──────────────────────────────────────────────────────────
id blackbox_exporter &>/dev/null || useradd --no-create-home --shell /bin/false blackbox_exporter
chown -R blackbox_exporter:blackbox_exporter /etc/blackbox_exporter

# ── 4. Systemd service ──────────────────────────────────────────────────────
log "Creating systemd service..."
cat > /etc/systemd/system/blackbox_exporter.service << 'EOF'
[Unit]
Description=Prometheus Blackbox Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=blackbox_exporter
ExecStart=/usr/local/bin/blackbox_exporter \
  --config.file=/etc/blackbox_exporter/blackbox.yml \
  --web.listen-address=127.0.0.1:9115
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now blackbox_exporter

# ── 5. Smoke test ────────────────────────────────────────────────────────────
log "Verifying..."
sleep 2

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

check "blackbox_exporter running"  "systemctl is-active --quiet blackbox_exporter"
check "blackbox :9115 responding"  "curl -sf http://127.0.0.1:9115/metrics | grep -q blackbox_exporter_build"

echo ""
echo "Result: ${PASS} PASS, ${FAIL} FAIL"
[[ $FAIL -gt 0 ]] && { echo "Some checks failed — see above."; exit 1; }

log "=== Blackbox Exporter installed ==="
echo ""
echo "  Next steps:"
echo "    1. Add blackbox scrape jobs to /etc/prometheus/prometheus.yml"
echo "       (see the template at the bottom of the file)"
echo "    2. Reload Prometheus: curl -X POST http://127.0.0.1:9090/-/reload"
echo "    3. Import Grafana dashboard ID 7587 (Blackbox Exporter)"
echo ""
