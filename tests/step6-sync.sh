#!/bin/bash
# step6-sync.sh: the change window, rehearsed on the test rig. Run inside the
# rig as root:
#   wsl -d monitoring-synctest -u root -- bash /mnt/c/.../tests/step6-sync.sh
#
# Starts from the live baseline, clones the repo to /opt/prometheus-azure-build
# (the working tree committed on a rigtest branch), then: dry run, refusal
# without --any-ref, migration, apply, verify. Then the failure paths: a
# broken Prometheus change, a change Grafana rejects, a dropped target, the
# restore paths, and remove-customer.sh.

set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLONE=/opt/prometheus-azure-build
OUT=/var/lib/rig/step6; rm -rf "$OUT"; mkdir -p "$OUT"
CUST=/etc/prometheus/targets/customers
BASELINE=e7fb88b
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
q()   { rig q "$1" | wc -l; }
sync_run() {   # sync_run <name> <args...>: run sync.sh, keep its output, return its exit code
    local name=$1; shift
    bash "$CLONE/sync.sh" "$@" > "$OUT/$name.txt" 2>&1; local rc=$?
    echo "    sync $* -> exit $rc"; return $rc
}
expect_rc() {  # expect_rc <want> <got> <what>
    [[ "$2" == "$1" ]] && ok "$3 (exit $2)" || { bad "$3: exit $2, wanted $1"; tail -15 "$OUT/$LAST.txt" 2>/dev/null | sed 's/^/      /'; }
}
commit_clone() {   # commit_clone <message>: commit whatever is changed in the clone
    git -C "$CLONE" add -A && git -C "$CLONE" -c user.email=rig@test -c user.name=rig commit -qm "$1"
}
wait_until() {   # wait_until <secs> <command>
    local s=$1; shift
    for _ in $(seq 1 "$s"); do eval "$*" &>/dev/null && return 0; sleep 1; done; return 1
}

echo "== 0. rig on the live baseline"
bash "$REPO/tests/rig/provision.sh" > "$OUT/provision.txt" 2>&1 || { tail "$OUT/provision.txt"; exit 2; }
rm -f $CUST/*.yml
rm -rf /var/backups/prometheus-azure-sync /var/lib/prometheus-azure-sync
bash "$REPO/tests/rig/rig-deploy.sh" --ref $BASELINE > "$OUT/deploy-baseline.txt" 2>&1 || exit 2
wait_until 420 "python3 $REPO/tools/targets-snapshot.py save $OUT/b.json | grep -q ': 19 targets, 0 not up' && [[ \$(rig q 'up == 1' | wc -l) == 19 ]]" \
    && ok "baseline running, 19 targets up" || { bad "baseline not settled"; exit 2; }

echo "== 1. clone, as 02-clone.sh would (from the local repo, working tree on a branch)"
rm -rf "$CLONE"
git -c safe.directory='*' clone -q "$REPO" "$CLONE"
git -C "$CLONE" checkout -qb rigtest
( cd "$REPO" && git -c safe.directory='*' ls-files -co --exclude-standard -z ) \
    | (cd "$REPO" && xargs -0 cp --parents -t "$CLONE")
( cd "$REPO" && git -c safe.directory='*' ls-files -d -z ) | (cd "$CLONE" && xargs -0r rm -f)
commit_clone "rig: working tree under test"
ok "clone at $(git -C "$CLONE" log -1 --format=%h) on rigtest"
GOOD=$(git -C "$CLONE" rev-parse HEAD)

echo "== 2. dry run changes nothing"
cp /etc/prometheus/prometheus.yml "$OUT/prom-before.yml"
LAST=dry1; sync_run dry1; rc=$?; expect_rc 0 $rc "dry run"
grep -q 'change(s) pending' "$OUT/dry1.txt" && ok "dry run lists pending changes" || bad "dry run listed nothing"
cmp -s /etc/prometheus/prometheus.yml "$OUT/prom-before.yml" && ok "dry run left prometheus.yml alone" || bad "dry run changed a file"

echo "== 3. refuses to apply from a non-main checkout"
LAST=refuse; sync_run refuse --apply; rc=$?; expect_rc 1 $rc "apply without --any-ref refused"
cmp -s /etc/prometheus/prometheus.yml "$OUT/prom-before.yml" && ok "refusal changed nothing" || bad "refusal changed a file"

echo "== 4. migration, then apply"
python3 "$CLONE/tools/one-off/2026-11-split-customers.py" > "$OUT/migrate-dry.txt" && ok "migration dry run" || bad "migration dry run"
python3 "$CLONE/tools/one-off/2026-11-split-customers.py" --write > "$OUT/migrate.txt" && ok "migration wrote $(ls $CUST | wc -l) customer files" || bad "migration --write"
md5sum $CUST/*.yml > "$OUT/customers.md5"
python3 "$REPO/tools/targets-snapshot.py" save "$OUT/before.json" >/dev/null
LAST=apply; sync_run apply --apply --any-ref; rc=$?; expect_rc 0 $rc "apply"
T_APPLIED=$(date +%s)
# The old per-customer scrape jobs are removed, and Prometheus writes no
# staleness markers for a job that is removed outright (only for a target that
# leaves a job that stays), whether by reload or restart. So the old postgres
# vm series stay visible for the 5 minute lookback, then go. Harmless (both
# read up=1); the runbook mentions it. Prove they do go.
n_now=$(q 'up{job=~"postgres-.*"}')
echo "    $n_now postgres up series straight after the apply (3 new, plus old ones until they age out)"
if wait_until 330 "[[ \$(rig q 'up{job=~\"postgres-.*\"}' | wc -l) == 3 ]]"; then
    ok "old postgres vm series gone $(( $(date +%s) - T_APPLIED ))s after the apply (lookback is 300s)"
else
    bad "$(q 'up{job=~"postgres-.*"}') postgres up series 330s after the apply"
fi
python3 "$REPO/tools/targets-snapshot.py" save "$OUT/after.json" >/dev/null
python3 "$REPO/tools/targets-snapshot.py" diff "$OUT/before.json" "$OUT/after.json" > "$OUT/diff.txt"
[[ $(grep -c '^LABELS' "$OUT/diff.txt") == 3 && $(grep -c '^INTERVAL' "$OUT/diff.txt") == 2 && $(grep -cvE '^LABELS|^INTERVAL|before, .* after' "$OUT/diff.txt") == 0 ]] \
    && ok "targets after apply: only the 5 deliberate differences" || { bad "unexpected target differences"; cat "$OUT/diff.txt"; }
md5sum -c --quiet "$OUT/customers.md5" && ok "sync left the customer files untouched" || bad "customer files changed by sync"
grep -q 'Grafana restarted: 17 rules' "$OUT/apply.txt" && ok "Grafana restarted with 17 rules and the template" || bad "Grafana check line missing"
bash "$CLONE/verify.sh" > "$OUT/verify1.txt" 2>&1; rc=$?
[[ $rc == 0 ]] && ok "verify.sh all PASS ($(tail -1 "$OUT/verify1.txt"))" || { bad "verify.sh exit $rc"; grep -E 'FAIL|UNDETERMINED' "$OUT/verify1.txt"; }
LAST=dry2; sync_run dry2; rc=$?
grep -q 'Nothing to do' "$OUT/dry2.txt" && ok "second dry run: nothing to do" || bad "second dry run still has changes"
APPLY_BK=$(sed -n 's/^backup=//p' /var/lib/prometheus-azure-sync/last-sync)
APPLY_FULL=$(sed -n 's/^snapshot=//p' /var/lib/prometheus-azure-sync/last-sync)

echo "== 5. a broken Prometheus change is rolled back before anything reloads"
sed -i 's/^  scrape_interval:     15s/  scrape_interval:     fifteen/' "$CLONE/prometheus/prometheus.yml"
commit_clone "rig: broken prometheus.yml"
LAST=broken-prom; sync_run broken-prom --apply --any-ref; rc=$?; expect_rc 4 $rc "broken prometheus.yml rejected"
cmp -s /etc/prometheus/prometheus.yml <(git -C "$CLONE" show "$GOOD:prometheus/prometheus.yml") && ok "live prometheus.yml is still the good one" || bad "live prometheus.yml changed"
[[ $(curl -fsS http://127.0.0.1:9090/metrics | awk '$1 == "prometheus_config_last_reload_successful" {print $2}') == 1 ]] \
    && ok "Prometheus still on a good config" || bad "Prometheus config state"
git -C "$CLONE" reset -q --hard "$GOOD"

echo "== 6a. a rule that cannot evaluate is stopped by check-rules.py before anything goes live"
python3 - "$CLONE/grafana/provisioning/alerting/rules.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# Valid YAML, and Grafana would load it, but the condition names no refId.
s = s.replace("      - uid: high-cpu\n        title: HighCPU\n        condition: C", "      - uid: high-cpu\n        title: HighCPU\n        condition: Z", 1)
open(p, 'w').write(s)
PY
commit_clone "rig: rule with a dangling condition"
LAST=broken-rule; sync_run broken-rule --apply --any-ref; rc=$?; expect_rc 4 $rc "dangling condition rejected by validation"
grep -q 'condition "Z" is not one of its refIds' "$OUT/broken-rule.txt" && ok "the error names the rule and the bad condition" || bad "error text"
cmp -s /etc/grafana/provisioning/alerting/rules.yml <(git -C "$CLONE" show "$GOOD:grafana/provisioning/alerting/rules.yml") && ok "live rules.yml is still the good one" || bad "live rules.yml changed"
git -C "$CLONE" reset -q --hard "$GOOD"

echo "== 6b. a change only Grafana can reject is rolled back after the restart"
python3 - "$CLONE/grafana/provisioning/alerting/contactpoints.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# The email-only receiver's type becomes one Grafana has never heard of.
s = s.replace("      - uid: email-only-uid\n        type: email", "      - uid: email-only-uid\n        type: notarealtype", 1)
open(p, 'w').write(s)
PY
grep -q 'type: notarealtype' "$CLONE/grafana/provisioning/alerting/contactpoints.yml" || bad "test setup: could not break the contact point"
commit_clone "rig: contact point type Grafana does not know"
LAST=broken-graf; sync_run broken-graf --apply --any-ref; rc=$?; expect_rc 5 $rc "unknown contact point type: rolled back"
grep -q 'Previous files re-applied and healthy' "$OUT/broken-graf.txt" && ok "previous files re-applied and healthy" || bad "re-apply after Grafana failure"
git -C "$CLONE" reset -q --hard "$GOOD"
bash "$CLONE/verify.sh" > "$OUT/verify2.txt" 2>&1 && ok "verify.sh all PASS after the Grafana rollback" || { bad "verify after Grafana rollback"; grep -E 'FAIL|UNDET' "$OUT/verify2.txt"; }

echo "== 7. dropping a target is caught; --allow-fewer-targets allows it; --restore undoes it"
python3 - "$CLONE/prometheus/targets/external.yml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split('\n')
out, skip = [], False
for l in lines:
    if l.startswith("- targets: ['https://scripts"): skip = True; continue
    if skip and l.startswith('  labels'): skip = False; continue
    out.append(l)
open(p, 'w').write('\n'.join(out))
PY
commit_clone "rig: drop the scripts probe"
LAST=drop; sync_run drop --apply --any-ref; rc=$?; expect_rc 5 $rc "dropped target rolled back"
[[ $(q 'up{job="blackbox-ext-scripts-v1-platform"}') == 1 ]] && ok "scripts probe still scraped" || bad "scripts probe lost"
LAST=drop-ok; sync_run drop-ok --apply --any-ref --allow-fewer-targets; rc=$?; expect_rc 0 $rc "--allow-fewer-targets applies it"
wait_until 60 "[[ \$(rig q 'up{job=\"blackbox-ext-scripts-v1-platform\"} == 1' | wc -l) == 0 ]]" && ok "scripts probe gone" || bad "scripts probe still there"
DROP_BK=$(sed -n 's/^backup=//p' /var/lib/prometheus-azure-sync/last-sync)
LAST=restore; sync_run restore --restore "$DROP_BK"; rc=$?; expect_rc 0 $rc "--restore of that sync"
wait_until 60 "[[ \$(rig q 'up{job=\"blackbox-ext-scripts-v1-platform\"} == 1' | wc -l) == 1 ]]" && ok "scripts probe back" || bad "scripts probe not back"
git -C "$CLONE" reset -q --hard "$GOOD"

echo "== 8. backups"
LAST=backup; sync_run backup --backup; rc=$?; expect_rc 0 $rc "--backup"
LAST=list; sync_run list --list-backups; rc=$?; expect_rc 0 $rc "--list-backups"
grep -c 'full-' "$OUT/list.txt" | xargs -I{} echo "    {} full snapshots listed"

echo "== 9. --restore-full back to the June state, then forward again"
LAST=rfull; sync_run rfull --restore-full "$APPLY_FULL"; rc=$?; expect_rc 0 $rc "--restore-full to the pre-change snapshot"
grep -q 'static_configs' /etc/prometheus/prometheus.yml && ok "prometheus.yml is the June one again" || bad "prometheus.yml not restored"
classic=$(sqlite3 -readonly /var/lib/grafana/grafana.db "select count(*) from alert_rule where data like '%classic_conditions%'")
[[ "$classic" == 14 ]] && ok "Grafana back on the 14 June rules" || bad "Grafana has $classic classic rules after restore-full"
wait_until 60 "[[ \$(rig q 'up == 1' | wc -l) -ge 19 ]]" && ok "June config scraping again" || bad "June config not scraping"
LAST=forward; sync_run forward --apply --any-ref; rc=$?; expect_rc 0 $rc "apply again after the restore"
bash "$CLONE/verify.sh" > "$OUT/verify3.txt" 2>&1 && ok "verify.sh all PASS" || { bad "verify after forward"; grep -E 'FAIL|UNDET' "$OUT/verify3.txt"; }

echo "== 10. remove-customer.sh"
sed -e 's/<customer>/rigtest-v2/g' -e 's/<ODOO-VM-IP>/10.9.0.4/g' -e 's/<PG-VM-IP>/10.9.0.5/g' \
    -e 's/<odoo-vm-name>/cx-app-vm-009/g' -e 's/<pg-vm-name>/cx-db-vm-009/g' \
    /etc/prometheus/targets/customer.yml.example > $CUST/rigtest-v2.yml
wait_until 60 "[[ \$(rig q 'up{customer=\"rigtest-v2\"} == 1' | wc -l) == 4 ]]" && ok "test customer scraped" || bad "test customer not scraped"
sleep 20
citiq_before=$(curl -s -G http://127.0.0.1:9090/api/v1/series --data-urlencode 'match[]={customer="citiq-v2"}' | jq '.data|length')
bash "$CLONE/tools/remove-customer.sh" rigtest-v2 --yes > "$OUT/remove.txt" 2>&1; rc=$?
cat "$OUT/remove.txt" | sed 's/^/    /'
[[ $rc == 0 ]] && ok "remove-customer.sh exit 0" || bad "remove-customer.sh exit $rc"
[[ ! -f $CUST/rigtest-v2.yml ]] && ls /var/backups/prometheus-azure-sync/removed-customers/rigtest-v2-*.yml >/dev/null 2>&1 \
    && ok "file moved to removed-customers" || bad "file not moved"
# Samples, not the series list: the list keeps deleted series until compaction.
s=$(curl -s -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=count(last_over_time({customer="rigtest-v2"}[400d]))' | jq -r '.data.result[0].value[1] // "0"')
[[ "$s" == 0 ]] && ok "no samples left for the removed customer" || bad "$s series still have samples"
citiq_after=$(curl -s -G http://127.0.0.1:9090/api/v1/series --data-urlencode 'match[]={customer="citiq-v2"}' | jq '.data|length')
(( citiq_after >= citiq_before )) && ok "other customers' history untouched (citiq $citiq_before -> $citiq_after series)" || bad "citiq lost series"
bash "$CLONE/tools/remove-customer.sh" "Bad_Name" > /dev/null 2>&1; [[ $? == 1 ]] && ok "bad customer name refused" || bad "bad name not refused"

echo "== 11. final verify"
bash "$CLONE/verify.sh" > "$OUT/verify4.txt" 2>&1; rc=$?
tail -1 "$OUT/verify4.txt"
[[ $rc == 0 ]] && ok "verify.sh all PASS" || { bad "verify.sh exit $rc"; grep -E 'FAIL|UNDET' "$OUT/verify4.txt"; }

echo
echo "Result: $PASS PASS, $FAIL FAIL"
[[ $FAIL -eq 0 ]]
