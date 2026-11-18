#!/bin/bash
# step5-alerts.sh: prove the new alert rules, templates and routing on the
# test rig. Run inside the rig as root, with the working tree deployed and the
# customer files in place (tests/step4-customer-files.sh leaves them there):
#   wsl -d monitoring-synctest -u root -- bash /mnt/c/.../tests/step5-alerts.sh
#
# Breaks eight things at once, waits, then checks every email Grafana sent:
# subjects name the customer/site, VM or URL and reading; degraded goes to
# email only; what must not fire did not. Then clears the faults and checks
# the resolved emails. About 25 minutes.

set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=/var/lib/rig/step5; rm -rf "$OUT"; mkdir -p "$OUT"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
INFRA='infra@1stream.co.za'
SMS='0726050094@sms5.vine.co.za'

mails() {   # one line per email: <rcpt>\t<subject>
    python3 - <<'PY'
import email, email.header, glob
for f in sorted(glob.glob('/var/lib/rig/mail/*.eml')):
    m = email.message_from_bytes(open(f, 'rb').read())
    s = str(email.header.make_header(email.header.decode_header(m['Subject'] or '')))
    print(f"{m['X-Rig-Rcpt']}\t{' '.join(s.split())}")
PY
}
expect() {  # expect <description> <rcpt regex> <subject regex>
    # The recipient field can list several addresses (the SMS receiver sends
    # one email to all three numbers), so <rcpt> may match anywhere in it.
    local tab=$'\t'
    if mails | grep -E "^[^${tab}]*$2[^${tab}]*${tab}.*$3" >/dev/null; then ok "$1"; else bad "$1 (no email to $2 matching: $3)"; fi
}
expect_none() {  # expect_none <description> <regex over rcpt+subject line>
    local hit; hit=$(mails | grep -E "$2" | head -1)
    if [[ -z "$hit" ]]; then ok "$1"; else bad "$1: $hit"; fi
}

echo "== 0. clean start"
rig reset >/dev/null; rig cert uc.1stream.co.za 90 >/dev/null; rig cert scripts.1stream.co.za 90 >/dev/null
bash "$REPO/tests/rig/provision.sh" > "$OUT/provision.txt" 2>&1 || { bad "provision"; tail "$OUT/provision.txt"; exit 1; }
for _ in $(seq 1 60); do [[ $(rig q 'up == 1' | wc -l) -ge 19 ]] && break; sleep 5; done
python3 - > "$OUT/rules.txt" <<'PY'
import base64, json, urllib.request
h = {'Authorization': 'Basic ' + base64.b64encode(b'admin:rig').decode()}
rules = json.load(urllib.request.urlopen(urllib.request.Request(
    'http://127.0.0.1:3000/api/v1/provisioning/alert-rules', headers=h)))
print('count', len(rules))
print('classic', sum(1 for r in rules for d in r['data'] if d['model'].get('type') == 'classic_conditions'))
print('provenance', sorted({r.get('provenance') for r in rules}))
PY
cat "$OUT/rules.txt"
grep -q '^count 17' "$OUT/rules.txt" && ok "17 rules provisioned" || bad "rule count"
grep -q '^classic 0' "$OUT/rules.txt" && ok "no classic conditions left" || bad "classic conditions still present"
grep -q "provenance \['file'\]" "$OUT/rules.txt" && ok "all rules file-provisioned (locked in the UI)" || bad "provenance"
echo "  waiting for a quiet start (no alert pending or firing)"
for _ in $(seq 1 60); do rig alerts | tail -1 | grep -q '^0 alert' && break; sleep 10; done
rig alerts | tail -1 | grep -q '^0 alert' && ok "quiet before the faults" || { bad "alerts already active"; rig alerts; }
health=$(curl -s -u admin:rig http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[r["name"]+": "+str(r.get("lastError","")) for g in d["data"]["groups"] for r in g["rules"] if r.get("health")!="ok"]
print("\n".join(bad))')
[[ -z "$health" ]] && ok "every rule evaluates without error" || bad "rule errors: $health"
rig mail-clear >/dev/null

echo "== 1. faults on ($(date +%T))"
rig cert uc.1stream.co.za 10 >/dev/null
rig site citiq reset >/dev/null
rig site stagezero reset >/dev/null
rig exp 10.5.0.4:9100 cpu_busy=95 >/dev/null
rig exp 10.1.0.5:9187 max_tx=400 >/dev/null
rig exp 10.2.0.5:9187 down=true >/dev/null
rig site scripts tlshang 12 >/dev/null
( while true; do rig site uc reset >/dev/null; sleep 60; rig site uc ok >/dev/null; sleep 40; done ) &
FLAP=$!
rig wait 1080

echo "== 2. firing ($(date +%T))"
rig alerts | tee "$OUT/alerts-firing.txt"
mails | tee "$OUT/mail-firing.txt"
expect "SiteDown names citiq and its URL"            "$INFRA" '\[FIRING:1\] CRITICAL SiteDown \| citiq-v2 \| http://10\.5\.0\.4:8069 \| probe failing'
expect "SiteDown for stagezero is its own email"     "$INFRA" '\[FIRING:1\] CRITICAL SiteDown \| stagezero-v2 \| http://10\.1\.0\.4:8069'
expect "SiteDown reaches the SMS numbers"            "$SMS" 'CRITICAL SiteDown \| citiq-v2'
expect "HighCPU names customer, VM and reading"      "$INFRA" 'WARNING HighCPU \| citiq-v2 \| cx-app-vm-005 \| 9[0-9]%'
expect "LongRunningTransaction names the DB VM"      "$INFRA" 'WARNING LongRunningTransaction \| stagezero-v2 \| cx-db-vm-001 \| [0-9]+s open'
expect "PostgresDown uses the fixed vm name"         "$INFRA" 'CRITICAL PostgresDown \| om-pfdirect-v2 \| cx-db-vm-002'
expect "ExternalSiteDown names scripts"              "$INFRA" 'CRITICAL ExternalSiteDown \| scripts-v1-platform \| https://scripts\.1stream\.co\.za'
expect "ExternalSiteDown reaches SMS"                "$SMS" 'CRITICAL ExternalSiteDown \| scripts-v1-platform'
expect "ExternalSiteDegraded for flapping uc"        "$INFRA" 'WARNING ExternalSiteDegraded \| uc-voice-platform \| https://uc\.1stream\.co\.za \| [0-9.]+% of probes OK'
expect "SSLCertExpiringSoon names uc and days left"  "$INFRA" 'WARNING SSLCertExpiringSoon \| uc-voice-platform \| https://uc\.1stream\.co\.za \| (9|10) days left'
expect_none "flapping uc never ExternalSiteDown"     'ExternalSiteDown \| uc-voice-platform'
expect_none "degraded never goes to SMS"             "sms5.*ExternalSiteDegraded"
expect_none "no SlowResponse from failed probes"     'SlowResponse'
expect_none "no subject without a who"               '\| unknown'
expect_none "no old-style subjects"                  '1Stream Alerts|\[no value\]'
if grep -rl '\[no value\]\|%!' /var/lib/rig/mail/ >/dev/null 2>&1; then bad "an email body has [no value] or a format error"; else ok "no [no value] or format errors in any body"; fi
f=$(grep -l 'HighCPU' /var/lib/rig/mail/*.eml | head -1); [[ -n "$f" ]] && { echo "--- sample body (HighCPU)"; rig mail-show "$f" | tee "$OUT/sample-body.txt" | head -40; }
grep -q 'Customer:  citiq-v2' "$OUT/sample-body.txt" && grep -q 'VM:        cx-app-vm-005' "$OUT/sample-body.txt" \
    && ok "email body lists customer and VM" || bad "body missing customer/VM"

echo "== 3. faults off ($(date +%T))"
kill $FLAP 2>/dev/null; wait $FLAP 2>/dev/null
rig reset >/dev/null; rig cert uc.1stream.co.za 90 >/dev/null
rig mail-clear >/dev/null
rig wait 600
mails | tee "$OUT/mail-resolved.txt"
expect "SiteDown citiq resolves"                     "$INFRA" '\[RESOLVED\] CRITICAL SiteDown \| citiq-v2 \| http://10\.5\.0\.4:8069'
expect "PostgresDown resolves"                       "$INFRA" '\[RESOLVED\] CRITICAL PostgresDown \| om-pfdirect-v2 \| cx-db-vm-002'
expect "ExternalSiteDown scripts resolves"           "$INFRA" '\[RESOLVED\] CRITICAL ExternalSiteDown \| scripts-v1-platform'
expect "HighCPU resolves"                            "$INFRA" '\[RESOLVED\] WARNING HighCPU \| citiq-v2 \| cx-app-vm-005'
expect_none "resolved subjects carry no stale reading" 'RESOLVED.*(probes OK|% *$|s open)'

echo
echo "Result: $PASS PASS, $FAIL FAIL"
[[ $FAIL -eq 0 ]]
