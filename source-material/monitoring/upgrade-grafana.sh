#!/usr/bin/env bash
# upgrade-grafana.sh
# Upgrade Grafana OSS on the monitoring VM via direct .deb download.
# Bypasses apt.grafana.com (unreachable from some Azure IPs).
#
# Usage:
#   sudo bash upgrade-grafana.sh              # upgrades to the default version below
#   sudo bash upgrade-grafana.sh 12.4.1       # upgrades to a specific version
#
# What it does:
#   1. Checks current installed version
#   2. Downloads the new .deb from dl.grafana.com
#   3. Stops Grafana
#   4. Installs the .deb (preserves /etc/grafana/grafana.ini and provisioning)
#   5. Restarts Grafana
#   6. Verifies Grafana is running and responding

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────────────────────
DEFAULT_VERSION="13.0.1"
TARGET_VERSION="${1:-$DEFAULT_VERSION}"
DEB_FILE="grafana_${TARGET_VERSION}_amd64.deb"
DOWNLOAD_URL="https://dl.grafana.com/oss/release/${DEB_FILE}"
# ─────────────────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 [version]"; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Check current version ────────────────────────────────────────────────
CURRENT_VERSION="(not installed)"
if dpkg -l grafana 2>/dev/null | grep -q "^ii"; then
    CURRENT_VERSION=$(dpkg -l grafana | awk '/^ii/{print $3}')
fi

log "Current Grafana version: ${CURRENT_VERSION}"
log "Target  Grafana version: ${TARGET_VERSION}"

if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    log "Already at target version. Nothing to do."
    exit 0
fi

# ── 2. Download ──────────────────────────────────────────────────────────────
log "Downloading Grafana ${TARGET_VERSION}..."
cd /tmp
if [[ -f "${DEB_FILE}" ]]; then
    log "File already exists in /tmp — skipping download."
else
    wget -q --show-progress "${DOWNLOAD_URL}" -O "${DEB_FILE}"
fi

# Verify the download isn't empty or an error page
FILE_SIZE=$(stat -c%s "${DEB_FILE}" 2>/dev/null || echo 0)
if [[ "$FILE_SIZE" -lt 1000000 ]]; then
    log "ERROR: Downloaded file is too small (${FILE_SIZE} bytes). Check the version number."
    log "URL: ${DOWNLOAD_URL}"
    rm -f "${DEB_FILE}"
    exit 1
fi

# ── 3. Pre-upgrade backup of grafana.ini ─────────────────────────────────────
if [[ -f /etc/grafana/grafana.ini ]]; then
    BACKUP="/etc/grafana/grafana.ini.bak-${CURRENT_VERSION}"
    cp /etc/grafana/grafana.ini "$BACKUP"
    log "Backed up grafana.ini → ${BACKUP}"
fi

# ── 4. Stop Grafana ─────────────────────────────────────────────────────────
log "Stopping Grafana..."
systemctl stop grafana-server || true

# ── 5. Install ───────────────────────────────────────────────────────────────
log "Installing Grafana ${TARGET_VERSION}..."
dpkg -i "${DEB_FILE}" || true
apt-get install -f -y -qq

# ── 6. Restart Grafana ──────────────────────────────────────────────────────
log "Starting Grafana..."
systemctl daemon-reload
systemctl start grafana-server

# ── 7. Verify ────────────────────────────────────────────────────────────────
log "Verifying..."
sleep 3

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

check "grafana-server running"   "systemctl is-active --quiet grafana-server"
check "Grafana API responding"   "curl -sf http://127.0.0.1:3000/api/health | grep -q ok"

NEW_VERSION=$(dpkg -l grafana | awk '/^ii/{print $3}')
echo ""
echo "  Upgraded: ${CURRENT_VERSION} → ${NEW_VERSION}"
echo "  Result:   ${PASS} PASS, ${FAIL} FAIL"

[[ $FAIL -gt 0 ]] && { echo "Some checks failed — review above."; exit 1; }

# ── 8. Clean up ──────────────────────────────────────────────────────────────
rm -f "/tmp/${DEB_FILE}"
log "=== Grafana upgrade complete ==="
