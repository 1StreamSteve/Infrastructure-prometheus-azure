#!/bin/bash
# =============================================================================
# 01-deploy-key.sh: give the monitoring VM its own read-only GitHub deploy key
# =============================================================================
#
# Runs as root on the monitoring VM (by hand, or through an Azure Run Command). It:
#   - generates /root/.ssh/prometheus-azure-deploy (ed25519, no passphrase) unless
#     the node already has one;
#   - adds a `github-prometheus-azure` host alias to /root/.ssh/config that reaches
#     GitHub over ssh.github.com:443 (outbound 22 is blocked from our networks);
#   - pins GitHub's ed25519 host key for ssh.github.com:443, and stops if the
#     fingerprint is not the published one;
#   - prints the public key to add to the repo as a READ-ONLY deploy key.
#
# Touches nothing outside /root/.ssh. Safe to re-run.
# =============================================================================

set -euo pipefail
GITHUB_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
H=$(hostname -s)
K=/root/.ssh/prometheus-azure-deploy

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -f "$K" ]]; then
    echo "key: $K already exists, keeping it"
else
    ssh-keygen -q -t ed25519 -N '' -C "$H prometheus-azure read-only deploy key" -f "$K"
    echo "key: generated $K"
fi

if grep -q '^Host github-prometheus-azure$' /root/.ssh/config 2>/dev/null; then
    echo "ssh config: github-prometheus-azure alias already present"
else
    cat >> /root/.ssh/config <<EOF

Host github-prometheus-azure
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $K
    IdentitiesOnly yes
EOF
    echo "ssh config: added github-prometheus-azure alias"
fi
chmod 600 /root/.ssh/config

KH=$(ssh-keyscan -p 443 -t ed25519 ssh.github.com 2>/dev/null)
[[ -n "$KH" ]] || { echo "FAIL: no answer from ssh.github.com:443 (outbound 443 blocked?)"; exit 2; }
FP=$(echo "$KH" | ssh-keygen -lf - | awk '{print $2}')
if [[ "$FP" != "$GITHUB_FP" ]]; then
    echo "FAIL: ssh.github.com host key fingerprint is $FP, expected $GITHUB_FP. Not trusting it."
    exit 3
fi
grep -qF "$(echo "$KH" | awk '{print $3}')" /root/.ssh/known_hosts 2>/dev/null || echo "$KH" >> /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
echo "host key: ssh.github.com:443 pinned ($FP)"

echo "PUBKEY $H: $(cat "$K.pub")"
