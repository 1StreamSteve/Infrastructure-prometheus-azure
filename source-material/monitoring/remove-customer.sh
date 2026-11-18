#!/usr/bin/env bash
# remove-customer.sh
# Full customer offboarding from Prometheus monitoring.
# Run on the monitoring VM.
#
# What it does:
#   1. Removes all scrape jobs for the customer from prometheus.yml
#   2. Reloads Prometheus config (hot-reload, no restart)
#   3. Deletes all historical time-series data for the customer
#   4. Cleans tombstones to reclaim disk space
#
# Usage:
#   sudo bash remove-customer.sh <customer-label>
#
# Examples:
#   sudo bash remove-customer.sh acme
#   sudo bash remove-customer.sh stagezero
#
# The <customer-label> must match the 'customer' label value used in
# prometheus.yml scrape job labels (e.g., customer: 'acme').
#
# Prerequisites:
#   - Prometheus running with --web.enable-lifecycle and --web.enable-admin-api
#   - prometheus.yml at /etc/prometheus/prometheus.yml

set -euo pipefail

CUSTOMER="${1:-}"
PROM_URL="http://127.0.0.1:9090"
PROM_CONFIG="/etc/prometheus/prometheus.yml"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 <customer-label>"; exit 1; }
[[ -n "$CUSTOMER" ]] || { echo "Usage: sudo bash $0 <customer-label>"; exit 1; }
[[ -f "$PROM_CONFIG" ]] || { echo "ERROR: ${PROM_CONFIG} not found."; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Preflight: verify Prometheus is reachable ────────────────────────────────
if ! curl -sf "${PROM_URL}/-/ready" &>/dev/null; then
    echo "ERROR: Prometheus is not responding at ${PROM_URL}."
    echo "       Is it running? Check: systemctl status prometheus"
    exit 1
fi

# ── Preflight: verify the customer label exists in Prometheus ────────────────
SERIES_COUNT=$(curl -sf "${PROM_URL}/api/v1/series?match[]={customer=\"${CUSTOMER}\"}" \
    | grep -o '"__name__"' | wc -l || echo 0)

if [[ "$SERIES_COUNT" -eq 0 ]]; then
    log "WARNING: No time-series found with customer=\"${CUSTOMER}\" in Prometheus."
    log "         The customer may already have been removed, or the label is wrong."
fi

# ── Preflight: verify scrape jobs exist in prometheus.yml ────────────────────
JOB_COUNT=$(grep -c "customer: '${CUSTOMER}'" "$PROM_CONFIG" 2>/dev/null || echo 0)

log "=== Removing customer: ${CUSTOMER} ==="
log "Scrape jobs found in prometheus.yml: ${JOB_COUNT}"
log "Time-series in Prometheus TSDB:      ${SERIES_COUNT}"
echo ""

# ── Confirmation ─────────────────────────────────────────────────────────────
read -rp "This will permanently delete all monitoring data for '${CUSTOMER}'. Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# ── 1. Backup prometheus.yml ─────────────────────────────────────────────────
BACKUP="${PROM_CONFIG}.bak-$(date '+%Y%m%d-%H%M%S')"
cp "$PROM_CONFIG" "$BACKUP"
log "Backed up prometheus.yml → ${BACKUP}"

# ── 2. Remove scrape jobs from prometheus.yml ────────────────────────────────
if [[ "$JOB_COUNT" -gt 0 ]]; then
    log "Removing scrape jobs for '${CUSTOMER}'..."

    # Build a list of job_name values that reference this customer.
    # Jobs follow the pattern: job_name: 'node-<customer>-odoo', 'node-<customer>-pg',
    # 'postgres-<customer>', etc. We match any job block containing customer: '<customer>'.
    #
    # Strategy: use awk to identify and remove complete job blocks.
    # A job block starts with "  - job_name:" and ends before the next "  - job_name:" or EOF.
    awk -v customer="$CUSTOMER" '
    BEGIN { skip = 0; buffer = "" }
    /^  - job_name:/ {
        if (skip) {
            # Previous block was marked for removal — discard buffer
            buffer = ""
        } else if (buffer != "") {
            # Previous block was clean — print it
            printf "%s", buffer
            buffer = ""
        }
        skip = 0
        buffer = $0 "\n"
        next
    }
    {
        buffer = buffer $0 "\n"
        # Check if this line contains the customer label
        if ($0 ~ "customer: '"'"'" customer "'"'"'") {
            skip = 1
        }
    }
    END {
        if (!skip && buffer != "") {
            printf "%s", buffer
        }
    }
    ' "$PROM_CONFIG" > "${PROM_CONFIG}.tmp"

    mv "${PROM_CONFIG}.tmp" "$PROM_CONFIG"
    chown prometheus:prometheus "$PROM_CONFIG"

    # Verify the removal
    REMAINING=$(grep -c "customer: '${CUSTOMER}'" "$PROM_CONFIG" 2>/dev/null || echo 0)
    if [[ "$REMAINING" -gt 0 ]]; then
        log "WARNING: ${REMAINING} references to '${CUSTOMER}' still in prometheus.yml."
        log "         Review manually: grep -n '${CUSTOMER}' ${PROM_CONFIG}"
    else
        log "All scrape jobs for '${CUSTOMER}' removed."
    fi
else
    log "No scrape jobs to remove (already clean)."
fi

# ── 3. Reload Prometheus ─────────────────────────────────────────────────────
log "Reloading Prometheus config..."
RELOAD_RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${PROM_URL}/-/reload")
if [[ "$RELOAD_RESULT" == "200" ]]; then
    log "Prometheus config reloaded successfully."
else
    log "WARNING: Prometheus reload returned HTTP ${RELOAD_RESULT}."
    log "         Check config syntax: promtool check config ${PROM_CONFIG}"
    log "         If reload failed, restore backup: cp ${BACKUP} ${PROM_CONFIG}"
    read -rp "Continue with data deletion anyway? [y/N] " CONTINUE
    [[ "$CONTINUE" =~ ^[Yy]$ ]] || { log "Aborted. Restore backup if needed."; exit 1; }
fi

# ── 4. Delete historical time-series data ────────────────────────────────────
if [[ "$SERIES_COUNT" -gt 0 ]]; then
    log "Deleting time-series data for customer='${CUSTOMER}'..."
    DELETE_RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${PROM_URL}/api/v1/admin/tsdb/delete_series" \
        --data-urlencode "match[]={customer=\"${CUSTOMER}\"}")

    if [[ "$DELETE_RESULT" == "204" ]]; then
        log "Series data marked for deletion."
    else
        log "WARNING: delete_series returned HTTP ${DELETE_RESULT}."
        log "         Ensure --web.enable-admin-api is set on Prometheus."
    fi

    # ── 5. Clean tombstones to reclaim disk ──────────────────────────────────
    log "Cleaning tombstones to reclaim disk space..."
    CLEAN_RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${PROM_URL}/api/v1/admin/tsdb/clean_tombstones")

    if [[ "$CLEAN_RESULT" == "204" ]]; then
        log "Tombstones cleaned — disk space reclaimed."
    else
        log "WARNING: clean_tombstones returned HTTP ${CLEAN_RESULT}."
    fi
else
    log "No time-series data to delete."
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
echo ""
log "=== Verification ==="

# Check no scrape jobs remain
FINAL_JOBS=$(grep -c "customer: '${CUSTOMER}'" "$PROM_CONFIG" 2>/dev/null || echo 0)
if [[ "$FINAL_JOBS" -eq 0 ]]; then
    echo "  PASS  No scrape jobs for '${CUSTOMER}' in prometheus.yml"
else
    echo "  FAIL  ${FINAL_JOBS} scrape jobs still reference '${CUSTOMER}'"
fi

# Check no active targets remain (give Prometheus a moment to process the reload)
sleep 2
ACTIVE_TARGETS=$(curl -sf "${PROM_URL}/api/v1/targets" 2>/dev/null \
    | grep -o "\"customer\":\"${CUSTOMER}\"" | wc -l || echo 0)
if [[ "$ACTIVE_TARGETS" -eq 0 ]]; then
    echo "  PASS  No active targets for '${CUSTOMER}' in Prometheus"
else
    echo "  FAIL  ${ACTIVE_TARGETS} active targets still reference '${CUSTOMER}'"
fi

echo ""
log "=== Customer '${CUSTOMER}' removed ==="
log "Backup: ${BACKUP}"
echo ""
echo "  Optional: clean up the customer's VMs (exporters, UFW rules, DB user)."
echo "  See DEPLOYMENT-GUIDE.md → 'Removing a Customer' for VM cleanup steps."
