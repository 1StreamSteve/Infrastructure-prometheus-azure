#!/bin/bash
# =============================================================================
# 02-clone.sh: clone the repo onto the monitoring VM at /opt/prometheus-azure-build
# =============================================================================
#
# Run as root after 01-deploy-key.sh, once the node's public key has been
# added to the repo as a read-only deploy key. Clones main through the
# github-prometheus-azure alias. Changes nothing the monitoring stack reads: sync.sh does that,
# later, by hand.
#
# If /opt/prometheus-azure-build is already a clone of the repo, it just fetches.
#
# When the repo moves from 1StreamSteve to the 1Stream org, the deploy key
# moves with it. Point the clone at the new home:
#   git -C /opt/prometheus-azure-build remote set-url origin \
#       git@github-prometheus-azure:1Stream/Infrastructure-prometheus-azure.git
# =============================================================================

set -euo pipefail
DIR=/opt/prometheus-azure-build
URL=git@github-prometheus-azure:1StreamSteve/Infrastructure-prometheus-azure.git

command -v git >/dev/null || { echo "FAIL: git not installed (apt-get install -y git)"; exit 2; }

if [[ -d "$DIR/.git" ]]; then
    echo "repo: $DIR exists, fetching"
    git -C "$DIR" fetch --prune origin
else
    [[ -e "$DIR" ]] && { echo "FAIL: $DIR exists and is not a git clone; not touching it"; exit 3; }
    git clone --branch main "$URL" "$DIR"
fi

echo "remote: $(git -C "$DIR" remote get-url origin)"
echo "HEAD:   $(git -C "$DIR" log -1 --oneline)"
echo "origin/main: $(git -C "$DIR" rev-parse --short origin/main)"
