#!/usr/bin/env bash
# setup-monitoring-vm.sh
# Run once on the dedicated monitoring VM (Ubuntu 24.04).
# Installs: Prometheus, Grafana OSS, nginx (reverse proxy), node_exporter.
# Configures: scrape jobs, Grafana provisioning, M365 SMTP alerting, UFW.
#
# Usage:
#   1. Fill in the four variables in the CONFIG block below.
#   2. Copy this repo's monitoring/ folder to the VM:
#        scp -r monitoring/ steve@<MONITORING-VM-IP>:~/monitoring/
#   3. SSH in and run:
#        sudo bash ~/monitoring/setup-monitoring-vm.sh
#
# ── CONFIG — edit these before running ───────────────────────────────────────
VM1_IP="<VM1-PRIVATE-IP>"          # e.g. 10.0.0.4
VM2_IP="<VM2-PRIVATE-IP>"          # e.g. 10.0.0.5
SMTP_FROM="<ALERT-FROM-EMAIL>"     # M365 mailbox that sends alerts, e.g. monitoring@1stream.co.za
SMTP_USER="<M365-SMTP-USER>"       # Usually same as SMTP_FROM
SMTP_PASSWORD="<M365-SMTP-PASSWORD>"
ALERT_TO="<ALERT-TO-EMAIL>"        # Where alerts are delivered, e.g. steve@1stream.co.za
GRAFANA_ADMIN_PASSWORD="<GRAFANA-ADMIN-PASSWORD>"   # Set a strong password
# Customer VM IPs (add more as needed)
CUSTOMER_TENANT_ODOO_IP="<CUSTOMER-TENANT-ODOO-IP>"     # e.g. 10.0.0.10
CUSTOMER_TENANT_PG_IP="<CUSTOMER-TENANT-PG-IP>"         # e.g. 10.0.0.11
# CUSTOMER_TENANT_URL not needed — blackbox probes internal Odoo IP:8069 directly
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)"

# Validate placeholders
for var in VM1_IP VM2_IP SMTP_FROM SMTP_USER SMTP_PASSWORD ALERT_TO GRAFANA_ADMIN_PASSWORD CUSTOMER_TENANT_ODOO_IP CUSTOMER_TENANT_PG_IP; do
    [[ "${!var}" == *"<"* ]] && die "Please fill in \$$var before running."
done

log "=== 1Stream Monitoring VM Setup ==="

# ── 1. System update ──────────────────────────────────────────────────────────
log "Updating packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ── 2. Install dependencies ───────────────────────────────────────────────────
log "Installing dependencies..."
apt-get install -y -qq curl wget gnupg2 apt-transport-https software-properties-common \
    nginx apache2-utils prometheus-node-exporter fail2ban

# ── 3. Install Prometheus ─────────────────────────────────────────────────────
log "Installing Prometheus..."
PROM_VERSION="2.51.2"
PROM_ARCH="linux-amd64"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.${PROM_ARCH}.tar.gz"

cd /tmp
wget -q "$PROM_URL" -O prometheus.tar.gz
tar xzf prometheus.tar.gz
cd "prometheus-${PROM_VERSION}.${PROM_ARCH}"

install -m 755 prometheus promtool /usr/local/bin/
install -d /etc/prometheus
install -m 644 prometheus.yml /etc/prometheus/prometheus.yml.example

# Prometheus TSDB data lives under /data (keeps it separate from OS paths)
install -d /data/prometheus

# Prometheus user
id prometheus &>/dev/null || useradd --no-create-home --shell /bin/false prometheus
chown -R prometheus:prometheus /etc/prometheus /data/prometheus
cd /tmp && rm -rf prometheus.tar.gz "prometheus-${PROM_VERSION}.${PROM_ARCH}"

# ── 3b. Install Blackbox Exporter ─────────────────────────────────────────────
log "Installing Blackbox Exporter..."
BBOX_VERSION="0.25.0"
BBOX_ARCH="linux-amd64"
BBOX_URL="https://github.com/prometheus/blackbox_exporter/releases/download/v${BBOX_VERSION}/blackbox_exporter-${BBOX_VERSION}.${BBOX_ARCH}.tar.gz"

cd /tmp
wget -q "$BBOX_URL" -O blackbox_exporter.tar.gz
tar xzf blackbox_exporter.tar.gz
install -m 755 "blackbox_exporter-${BBOX_VERSION}.${BBOX_ARCH}/blackbox_exporter" /usr/local/bin/
rm -rf blackbox_exporter.tar.gz "blackbox_exporter-${BBOX_VERSION}.${BBOX_ARCH}"

# Blackbox config
mkdir -p /etc/blackbox_exporter
cat > /etc/blackbox_exporter/blackbox.yml << 'BBOX_EOF'
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
BBOX_EOF

# Blackbox systemd service
id blackbox_exporter &>/dev/null || useradd --no-create-home --shell /bin/false blackbox_exporter
chown -R blackbox_exporter:blackbox_exporter /etc/blackbox_exporter

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

# ── 4. Write prometheus.yml ───────────────────────────────────────────────────
log "Writing /etc/prometheus/prometheus.yml..."
sed \
    -e "s|<VM1-PRIVATE-IP>|${VM1_IP}|g" \
    -e "s|<VM2-PRIVATE-IP>|${VM2_IP}|g" \
    -e "s|<CUSTOMER-TENANT-ODOO-IP>|${CUSTOMER_TENANT_ODOO_IP}|g" \
    -e "s|<CUSTOMER-TENANT-PG-IP>|${CUSTOMER_TENANT_PG_IP}|g" \
    "${SCRIPT_DIR}/prometheus.yml" \
    > /etc/prometheus/prometheus.yml
chown prometheus:prometheus /etc/prometheus/prometheus.yml

# ── 5. Prometheus systemd service ────────────────────────────────────────────
log "Configuring Prometheus systemd service..."
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus Monitoring
Documentation=https://prometheus.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/data/prometheus \
  --storage.tsdb.retention.time=365d \
  --web.listen-address=127.0.0.1:9090 \
  --web.enable-lifecycle \
  --web.enable-admin-api
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

# ── 6. Install Grafana OSS ────────────────────────────────────────────────────
log "Installing Grafana OSS..."
GRAFANA_VERSION="13.0.1"
GRAFANA_DEB="grafana_${GRAFANA_VERSION}_amd64.deb"

if dpkg -l grafana 2>/dev/null | grep -q "^ii"; then
    log "Grafana already installed — skipping."
else
    # Direct .deb download (bypasses apt.grafana.com which is unreachable from some Azure IPs)
    log "Downloading Grafana ${GRAFANA_VERSION}..."
    wget -q "https://dl.grafana.com/oss/release/${GRAFANA_DEB}" -O "/tmp/${GRAFANA_DEB}"
    dpkg -i "/tmp/${GRAFANA_DEB}" || true
    apt-get install -f -y -qq
    rm -f "/tmp/${GRAFANA_DEB}"
fi

# ── 7. Configure Grafana (grafana.ini overrides) ──────────────────────────────
log "Configuring Grafana..."
GRAFANA_CONF=/etc/grafana/grafana.ini

# Server block — set root_url so redirects work behind nginx
sed -i "s|^;*\s*root_url\s*=.*|root_url = https://prometheus.1stream.co.za/|" "$GRAFANA_CONF"
sed -i "s|^;*\s*serve_from_sub_path\s*=.*|serve_from_sub_path = false|" "$GRAFANA_CONF"

# Admin password
sed -i "s|^;*\s*admin_password\s*=.*|admin_password = ${GRAFANA_ADMIN_PASSWORD}|" "$GRAFANA_CONF"

# Disable sign-up (internal tool only)
sed -i "s|^;*\s*allow_sign_up\s*=.*|allow_sign_up = false|" "$GRAFANA_CONF"

# SMTP — Microsoft 365
cat >> "$GRAFANA_CONF" << EOF

#################################### SMTP ####################################
[smtp]
enabled      = true
host         = smtp.office365.com:587
user         = ${SMTP_USER}
password     = ${SMTP_PASSWORD}
from_address = ${SMTP_FROM}
from_name    = 1Stream Monitoring
startTLS_policy = MandatoryStartTLS
skip_verify  = false
EOF

# ── 8. Grafana provisioning ───────────────────────────────────────────────────
log "Installing Grafana provisioning files..."
PROV_DIR=/etc/grafana/provisioning

# Datasource
cp "${SCRIPT_DIR}/provisioning/datasources/prometheus.yml" \
    "${PROV_DIR}/datasources/prometheus.yml"

# Alerting
mkdir -p "${PROV_DIR}/alerting"
sed "s|<ALERT-TO-EMAIL>|${ALERT_TO}|g" \
    "${SCRIPT_DIR}/provisioning/alerting/contactpoints.yml" \
    > "${PROV_DIR}/alerting/contactpoints.yml"
cp "${SCRIPT_DIR}/provisioning/alerting/policies.yml" \
    "${PROV_DIR}/alerting/policies.yml"
cp "${SCRIPT_DIR}/provisioning/alerting/rules.yml" \
    "${PROV_DIR}/alerting/rules.yml"

chown -R grafana:grafana "${PROV_DIR}"

# ── 9. nginx SSL setup ────────────────────────────────────────────────────────
log "Setting up nginx..."
mkdir -p /etc/nginx/ssl

if [[ ! -f /etc/nginx/ssl/star.1stream.co.za.crt ]]; then
    cat << 'MSG'

  ┌─────────────────────────────────────────────────────────────────────┐
  │  ACTION REQUIRED: copy the wildcard cert from VM1 before continuing │
  │                                                                     │
  │  On VM1, run:                                                       │
  │    scp /etc/nginx/ssl/star.1stream.co.za.crt \                      │
  │        steve@<MONITORING-VM-IP>:/etc/nginx/ssl/                     │
  │    scp /etc/nginx/ssl/star.1stream.co.za.key \                      │
  │        steve@<MONITORING-VM-IP>:/etc/nginx/ssl/                     │
  │                                                                     │
  │  Then re-run this script.                                           │
  └─────────────────────────────────────────────────────────────────────┘
MSG
    exit 1
fi
chmod 600 /etc/nginx/ssl/star.1stream.co.za.key

# Remove default site
rm -f /etc/nginx/sites-enabled/default

# Install the Grafana vhost
cp "${SCRIPT_DIR}/nginx-grafana.conf" \
    /etc/nginx/sites-available/prometheus.1stream.co.za.conf
ln -sf /etc/nginx/sites-available/prometheus.1stream.co.za.conf \
       /etc/nginx/sites-enabled/prometheus.1stream.co.za.conf

# ── 10. Basic auth for nginx ──────────────────────────────────────────────────
if [[ ! -f /etc/nginx/.htpasswd ]]; then
    log "Creating nginx basic auth file..."
    echo "Enter a password for the 'admin' monitoring user:"
    htpasswd -c /etc/nginx/.htpasswd admin
else
    log "nginx .htpasswd already exists — skipping."
fi

# ── 11. UFW ───────────────────────────────────────────────────────────────────
log "Configuring UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP (redirect)'
ufw allow 443/tcp  comment 'HTTPS (Grafana)'
# Prometheus UI is localhost-only (bound to 127.0.0.1:9090) — no public rule needed
# node_exporter is localhost-only on this VM — no public rule needed
ufw --force enable

# ── 12. Fail2ban — protect against brute-force on basic auth ────────────────
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/prometheus.1stream.co.za.error.log
maxretry = 5

[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/prometheus.1stream.co.za.error.log
maxretry = 10
EOF

systemctl enable --now fail2ban

# ── 13. Enable & start services ───────────────────────────────────────────────
log "Enabling services..."
systemctl daemon-reload
systemctl enable --now prometheus
systemctl enable --now grafana-server
systemctl enable --now prometheus-node-exporter
systemctl enable --now blackbox_exporter

nginx -t
systemctl enable --now nginx

# ── 13. Smoke test ────────────────────────────────────────────────────────────
log "Smoke test..."
PASS=0
FAIL=0
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

check "Prometheus running"       "systemctl is-active --quiet prometheus"
check "Prometheus :9090 up"      "curl -sf http://127.0.0.1:9090/-/healthy"
check "Grafana running"          "systemctl is-active --quiet grafana-server"
check "Grafana :3000 up"         "curl -sf http://127.0.0.1:3000/api/health"
check "node_exporter running"    "systemctl is-active --quiet prometheus-node-exporter"
check "blackbox_exporter running" "systemctl is-active --quiet blackbox_exporter"
check "blackbox :9115 up"        "curl -sf http://127.0.0.1:9115/metrics | grep -q blackbox_exporter_build"
check "nginx running"            "systemctl is-active --quiet nginx"
check "nginx config valid"       "nginx -t"

echo ""
echo "Result: ${PASS} PASS, ${FAIL} FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Some checks failed — review output above."
    exit 1
fi

log "=== Setup complete ==="
cat << EOF

  Grafana is available at: https://prometheus.1stream.co.za
  Default login:           admin / ${GRAFANA_ADMIN_PASSWORD}

  Next steps:
    1. In Grafana → Dashboards → Import → ID 1860  (Node Exporter Full)
    2. In Grafana → Dashboards → Import → ID 12708 (nginx Prometheus Exporter)
    3. Confirm alert emails arrive: Grafana → Alerting → Contact points → Test
    4. Add DNS A record: prometheus.1stream.co.za → this VM's public IP

EOF
