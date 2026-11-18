#!/bin/bash
# =============================================================================
# remove-customer.sh: stop monitoring a customer and delete its history
# =============================================================================
#
#   sudo bash /opt/prometheus-azure-build/tools/remove-customer.sh <customer>
#   sudo bash /opt/prometheus-azure-build/tools/remove-customer.sh <customer> --keep-data
#
# <customer> is the customer label, which is also the file name in
# /etc/prometheus/targets/customers/ (e.g. acme-v2 for acme-v2.yml).
#
#   1. Moves the customer's target file out of the customers folder into
#      /var/backups/prometheus-azure-sync/removed-customers/ (so it can be
#      put back), if it is still there.
#   2. Waits until Prometheus has no targets left for the customer.
#      No reload is needed.
#   3. Unless --keep-data: shows how many series the customer has, asks for
#      the customer name to be typed back, deletes them
#      (admin API delete_series + clean_tombstones), and checks none are left.
#
# Grafana needs nothing: the customer's alerts resolve on their own.
# The exporters on the customer's VMs are not touched; see the KB guide if
# the VMs are staying.
#
# --yes skips the typed confirmation (tests only).
# Exit codes: 0 done, 1 usage or precondition, 3 targets did not go,
#             4 deletion failed or series remain.
# =============================================================================

set -euo pipefail
PROM=http://127.0.0.1:9090
CDIR=/etc/prometheus/targets/customers
SAVE=/var/backups/prometheus-azure-sync/removed-customers

CUST=${1:-}
shift || true
KEEP=0 YES=0
for a in "$@"; do
    case $a in --keep-data) KEEP=1;; --yes) YES=1;; *) echo "unknown option $a"; exit 1;; esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0 <customer>"; exit 1; }
[[ "$CUST" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "Usage: sudo bash $0 <customer> [--keep-data]  (lower case, e.g. acme-v2)"; exit 1; }
[[ "$CUST" != infrastructure ]] || { echo "infrastructure is not a customer"; exit 1; }
curl -fsS --max-time 5 -o /dev/null "$PROM/-/ready" || { echo "Prometheus is not ready at $PROM"; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Counts come from jq on the API's JSON. On any API error they are empty, and
# empty is treated as "don't know", never as zero.
targets() { curl -fsS --max-time 10 "$PROM/api/v1/targets?state=active" \
              | jq --arg c "$CUST" '[.data.activeTargets[] | select(.labels.customer == $c)] | length'; }
series()  { curl -fsS --max-time 60 -G "$PROM/api/v1/series" --data-urlencode "match[]={customer=\"$CUST\"}" \
              | jq '.data | length'; }
# After delete_series the series index still lists the deleted series until
# the next compaction (within about 2 hours), so the proof that the data is
# gone is a query for samples, not the series list. Cheap once deleted.
samples() { curl -fsS --max-time 120 -G "$PROM/api/v1/query" \
              --data-urlencode "query=count(last_over_time({customer=\"$CUST\"}[400d]))" \
              | jq -r 'if .status == "success" then (.data.result[0].value[1] // "0") else empty end'; }

# ---- 1. the target file ------------------------------------------------------
if [[ -f "$CDIR/$CUST.yml" ]]; then
    mkdir -p "$SAVE"; chmod 700 "$SAVE"
    dest="$SAVE/$CUST-$(date +%Y%m%d-%H%M%S).yml"
    mv "$CDIR/$CUST.yml" "$dest"
    log "Moved $CDIR/$CUST.yml to $dest"
    log "To put it back: sudo mv $dest $CDIR/$CUST.yml"
else
    log "No $CDIR/$CUST.yml (already removed)."
fi

# ---- 2. targets gone ---------------------------------------------------------
n=""
for _ in $(seq 1 30); do
    n=$(targets 2>/dev/null || true)
    [[ "$n" == 0 ]] && break
    sleep 2
done
case "$n" in
    0)  log "Prometheus has no targets left for $CUST." ;;
    "") log "Could not read Prometheus targets. Stopping before any deletion."; exit 3 ;;
    *)  log "Prometheus still has $n target(s) for $CUST after 60s. Is $CUST in another file?"
        grep -l "customer: $CUST\b" /etc/prometheus/targets/*.yml $CDIR/*.yml 2>/dev/null | sed 's/^/    /' || true
        exit 3 ;;
esac

if [[ $KEEP -eq 1 ]]; then
    log "--keep-data: history kept. Done."
    exit 0
fi

# ---- 3. history --------------------------------------------------------------
s=$(series 2>/dev/null || true)
[[ "$s" =~ ^[0-9]+$ ]] || { log "Could not count series for $CUST. Nothing deleted."; exit 4; }
if (( s == 0 )); then
    log "No series stored for customer=\"$CUST\". Nothing to delete."
    exit 0
fi
log "$s series stored for customer=\"$CUST\"."
if [[ $YES -eq 0 ]]; then
    read -rp "Type the customer name to delete all of its monitoring history permanently: " typed
    [[ "$typed" == "$CUST" ]] || { log "Did not match. Nothing deleted."; exit 1; }
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -G "$PROM/api/v1/admin/tsdb/delete_series" \
       --data-urlencode "match[]={customer=\"$CUST\"}")
[[ $code == 204 ]] || { log "delete_series returned HTTP $code (is --web.enable-admin-api set?). Stopping."; exit 4; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROM/api/v1/admin/tsdb/clean_tombstones")
[[ $code == 204 ]] || log "clean_tombstones returned HTTP $code; the data is deleted but disk is not reclaimed yet."

left=$(samples 2>/dev/null || true)
if [[ "$left" == 0 ]]; then
    log "Deleted. No samples left for $CUST. (The series list may still name them until the next compaction.)"
else
    log "Samples still found for $CUST after deletion: ${left:-could not query}"; exit 4
fi
