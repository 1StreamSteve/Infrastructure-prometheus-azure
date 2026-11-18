#!/bin/bash
# rig-deploy.sh: put the repo's git-managed files on the rig, per
# sync-manifest.conf, and (re)start what they belong to.
#
# This is the rig's stand-in until sync.sh exists (step 6). After that the rig
# is deployed with sync.sh itself, the same way as the server.

set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
log() { echo "[rig-deploy] $*"; }

declare -A APPLY=()
while read -r src dest owner mode apply; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    install -D -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$REPO/$src" "$dest"
    APPLY[$apply]=1
done < "$REPO/sync-manifest.conf"

# The customer folder exists on the server and is never written by sync.
install -d -o prometheus -g prometheus /etc/prometheus/targets /etc/prometheus/targets/customers

ln -sf /etc/nginx/sites-available/prometheus.1stream.co.za.conf /etc/nginx/sites-enabled/prometheus.1stream.co.za.conf
rm -f /etc/nginx/sites-enabled/default

systemctl daemon-reload
for u in prometheus blackbox_exporter grafana-server nginx fail2ban; do
    systemctl enable -q "$u"
    systemctl restart "$u"
done

# Wait for each service to answer before calling the deploy good.
wait_for() {
    local what=$1 cmd=$2
    for _ in $(seq 1 60); do eval "$cmd" &>/dev/null && { log "up: $what"; return 0; }; sleep 2; done
    log "NOT UP: $what"; return 1
}
wait_for prometheus "curl -sf http://127.0.0.1:9090/-/ready"
wait_for blackbox   "curl -sf http://127.0.0.1:9115/metrics"
wait_for grafana    "curl -sf http://127.0.0.1:3000/api/health"
wait_for nginx      "nginx -t"
