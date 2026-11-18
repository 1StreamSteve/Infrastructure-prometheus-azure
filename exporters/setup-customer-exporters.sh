#!/usr/bin/env bash
# setup-customer-exporters.sh
# Run on customer Odoo or Postgres VMs to install exporters and open UFW
# so the monitoring VM can scrape metrics.
#
# Usage:
#   Odoo VM:     sudo bash setup-customer-exporters.sh odoo     <MONITORING-VM-PRIVATE-IP>
#   Postgres VM: sudo bash setup-customer-exporters.sh postgres  <MONITORING-VM-PRIVATE-IP>
#
# Examples:
#   sudo bash setup-customer-exporters.sh odoo     10.0.0.6
#   sudo bash setup-customer-exporters.sh postgres  10.0.0.6
#
# What it installs:
#   odoo mode:     node_exporter (:9100)
#   postgres mode: node_exporter (:9100) + postgres_exporter (:9187) + prometheus DB user

set -euo pipefail

VM_TYPE="${1:-}"
MONITORING_IP="${2:-}"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 <odoo|postgres> <monitoring-ip>"; exit 1; }
[[ "$VM_TYPE" == "odoo" || "$VM_TYPE" == "postgres" ]] || { echo "Usage: sudo bash $0 <odoo|postgres> <MONITORING-VM-PRIVATE-IP>"; exit 1; }
[[ -n "$MONITORING_IP" ]] || { echo "Usage: sudo bash $0 $VM_TYPE <MONITORING-VM-PRIVATE-IP>"; exit 1; }
[[ "$MONITORING_IP" == *"<"* ]] && { echo "Error: replace placeholder with actual IP."; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== Customer exporter setup (${VM_TYPE}) on $(hostname) ==="
log "Monitoring VM IP: ${MONITORING_IP}"

# ── 1. Install node_exporter ─────────────────────────────────────────────────
if systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
    log "node_exporter already running — skipping install."
else
    log "Installing prometheus-node-exporter..."
    apt-get update -qq
    apt-get install -y -qq prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter
fi

# ── 2. UFW — allow monitoring VM to scrape node_exporter ─────────────────────
UFW_ACTIVE=false
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    UFW_ACTIVE=true
fi

if $UFW_ACTIVE; then
    log "Opening UFW port 9100 for ${MONITORING_IP}..."
    if ! ufw status | grep -q "9100.*${MONITORING_IP}"; then
        ufw allow from "${MONITORING_IP}" to any port 9100 proto tcp \
            comment "node_exporter — monitoring VM"
    fi
else
    log "UFW is not active — skipping firewall rules. Ensure your NSG/firewall allows ${MONITORING_IP} → port 9100."
fi

# ── 3. Postgres-specific setup ───────────────────────────────────────────────
if [[ "$VM_TYPE" == "postgres" ]]; then

    # 3a. Install postgres_exporter
    log "Installing postgres_exporter..."
    PGEXP_VERSION="0.15.0"
    PGEXP_URL="https://github.com/prometheus-community/postgres_exporter/releases/download/v${PGEXP_VERSION}/postgres_exporter-${PGEXP_VERSION}.linux-amd64.tar.gz"

    cd /tmp
    wget -q "$PGEXP_URL" -O postgres_exporter.tar.gz
    tar xzf postgres_exporter.tar.gz
    install -m 755 "postgres_exporter-${PGEXP_VERSION}.linux-amd64/postgres_exporter" /usr/local/bin/
    rm -rf postgres_exporter.tar.gz "postgres_exporter-${PGEXP_VERSION}.linux-amd64"

    # 3b. Create prometheus DB user (idempotent)
    log "Creating prometheus Postgres user..."
    PROM_PG_PASSWORD="$(openssl rand -hex 16)"

    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='prometheus'" | grep -q 1; then
        log "Postgres user 'prometheus' already exists — updating password."
        sudo -u postgres psql -c "ALTER USER prometheus WITH PASSWORD '${PROM_PG_PASSWORD}';"
    else
        sudo -u postgres psql -c "CREATE USER prometheus WITH PASSWORD '${PROM_PG_PASSWORD}' CONNECTION LIMIT 3;"
        sudo -u postgres psql -c "GRANT pg_monitor TO prometheus;"
    fi

    # 3c. Connection string env file
    mkdir -p /etc/default
    cat > /etc/default/postgres_exporter << EOF
DATA_SOURCE_NAME="postgresql://prometheus:${PROM_PG_PASSWORD}@127.0.0.1:5432/postgres?sslmode=disable"
EOF
    chmod 600 /etc/default/postgres_exporter

    # 3d. postgres_exporter systemd service
    id postgres_exporter &>/dev/null || useradd --no-create-home --shell /bin/false postgres_exporter
    chown postgres_exporter:postgres_exporter /etc/default/postgres_exporter

    cat > /etc/systemd/system/postgres_exporter.service << 'EOF'
[Unit]
Description=Prometheus Postgres Exporter
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=postgres_exporter
EnvironmentFile=/etc/default/postgres_exporter
ExecStart=/usr/local/bin/postgres_exporter \
  --web.listen-address=:9187 \
  --collector.process_idle \
  --collector.postmaster \
  --collector.stat_statements \
  --no-collector.stat_bgwriter
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now postgres_exporter

    # 3e. UFW — allow monitoring VM to scrape postgres_exporter
    if $UFW_ACTIVE; then
        log "Opening UFW port 9187 for ${MONITORING_IP}..."
        if ! ufw status | grep -q "9187.*${MONITORING_IP}"; then
            ufw allow from "${MONITORING_IP}" to any port 9187 proto tcp \
                comment "postgres_exporter — monitoring VM"
        fi
    else
        log "UFW is not active — skipping port 9187 rule. Ensure your NSG/firewall allows ${MONITORING_IP} → port 9187."
    fi

    # 3f. Enable pg_stat_statements if not already loaded
    PG_CONF=$(sudo -u postgres psql -tAc "SHOW config_file" 2>/dev/null || echo "")
    if [[ -n "$PG_CONF" ]]; then
        if ! grep -q "shared_preload_libraries.*pg_stat_statements" "$PG_CONF" 2>/dev/null; then
            log "NOTE: pg_stat_statements is not in shared_preload_libraries."
            log "      To enable it, add to postgresql.conf:"
            log "        shared_preload_libraries = 'pg_stat_statements'"
            log "      Then restart PostgreSQL. This is optional but recommended."
        fi
    fi
fi

if $UFW_ACTIVE; then
    ufw reload
fi

# ── 4. Smoke test ─────────────────────────────────────────────────────────────
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

check "node_exporter running"       "systemctl is-active --quiet prometheus-node-exporter"
check "node_exporter :9100 up"      "curl -sf http://127.0.0.1:9100/metrics | grep -q node_exporter_build"

if [[ "$VM_TYPE" == "postgres" ]]; then
    check "postgres_exporter running"  "systemctl is-active --quiet postgres_exporter"
    check "postgres_exporter :9187 up" "curl -sf http://127.0.0.1:9187/metrics | grep -q pg_up"
fi

# UFW checks — skip if firewall is inactive
if ufw status | grep -q "Status: active"; then
    check "UFW 9100 rule present"    "ufw status | grep -q '9100.*${MONITORING_IP}'"
    if [[ "$VM_TYPE" == "postgres" ]]; then
        check "UFW 9187 rule present"  "ufw status | grep -q '9187.*${MONITORING_IP}'"
    fi
else
    log "UFW is inactive — skipping rule checks (rules were added but won't apply until 'ufw enable')"
fi

echo ""
echo "Result: ${PASS} PASS, ${FAIL} FAIL"
[[ $FAIL -gt 0 ]] && { echo "Some checks failed — see above."; exit 1; }

log "=== Done. $(hostname) is ready to be scraped by ${MONITORING_IP} ==="

if [[ "$VM_TYPE" == "postgres" ]]; then
    echo ""
    echo "  IMPORTANT: Save this postgres_exporter password (it was auto-generated):"
    echo "    ${PROM_PG_PASSWORD}"
    echo ""
    echo "  It's stored in /etc/default/postgres_exporter on this VM."
    echo "  You don't need it for Prometheus config — the exporter connects locally."
fi
