#!/bin/bash
# step4-customer-files.sh: prove the move to per-customer target files on the
# test rig. Run inside the rig as root, with the June-style (baseline)
# prometheus.yml still deployed:
#   wsl -d monitoring-synctest -u root -- bash /mnt/c/.../tests/step4-customer-files.sh
#
# 1. snapshot targets on the old config
# 2. migration dry run, then --write, against the live old config
# 3. deploy the new git files, snapshot again, and diff: the only
#    differences allowed are the three postgres vm labels
# 4. checker passes on the result, and fails each broken file it is fed
# 5. a new customer file is picked up without a reload, and a deleted one dropped
# 6. a broken customer file: what Prometheus does with it

set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=/var/lib/rig/step4; rm -rf "$OUT"; mkdir -p "$OUT"
CUST=/etc/prometheus/targets/customers
PASS=0 FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
q()    { rig q "$1" | wc -l; }
wait_for() {   # wait_for <secs> <description> <command>
    local s=$1 what=$2 cmd=$3
    for _ in $(seq 1 "$s"); do eval "$cmd" &>/dev/null && { ok "$what"; return 0; }; sleep 1; done
    bad "$what (not within ${s}s)"; return 1
}

BASELINE=e7fb88b   # "Baseline: system files exactly as live on Monitoring-VM-001"

echo "== 0. rig on the baseline (June-style prometheus.yml, no customer files)"
bash "$REPO/tests/rig/provision.sh" > "$OUT/provision0.txt" 2>&1 || { tail "$OUT/provision0.txt"; exit 2; }
rm -f $CUST/*.yml
bash "$REPO/tests/rig/rig-deploy.sh" --ref $BASELINE > "$OUT/deploy-baseline.txt" 2>&1 || { tail "$OUT/deploy-baseline.txt"; exit 2; }
grep -q 'static_configs' /etc/prometheus/prometheus.yml && ok "baseline config deployed" || { bad "baseline not deployed"; exit 2; }
# Both conditions: the targets API shows 19 discovered and up (series alone
# can be the previous run's, still inside the 5 minute lookback), and the
# restart's leftovers have gone stale so only 19 up series remain.
wait_for 420 "baseline: 19 targets discovered and up, and only 19 up series" \
    "python3 $REPO/tools/targets-snapshot.py save $OUT/before.json | grep -q ': 19 targets, 0 not up' && [[ \$(rig q 'up == 1' | wc -l) == 19 ]]"

echo "== 1. before"
python3 "$REPO/tools/targets-snapshot.py" save "$OUT/before.json"
grep -c '"health": "up"' "$OUT/before.json" | grep -qx 19 && ok "before snapshot holds 19 up targets" || { bad "before snapshot is not 19 up targets"; exit 1; }

echo "== 2. migration"
python3 "$REPO/tools/one-off/2026-11-split-customers.py" > "$OUT/dry-run.txt"; rc=$?
[[ $rc -eq 0 ]] && ok "dry run exits 0" || bad "dry run exit $rc"
grep -q 'equivalence: OK' "$OUT/dry-run.txt" && ok "dry run proves equivalence" || bad "no equivalence line"
n=$(grep -c ' vm .* -> ' "$OUT/dry-run.txt" || true)
[[ "$n" == 3 ]] && ok "exactly 3 deliberate vm changes" || bad "$n vm changes, expected 3"
n=$(grep -c 'scrape interval 60s -> 30s' "$OUT/dry-run.txt" || true)
[[ "$n" == 2 ]] && ok "external probes 60s -> 30s listed as deliberate" || bad "$n interval changes, expected 2"
[[ -z "$(ls -A $CUST 2>/dev/null)" ]] && ok "dry run wrote nothing" || bad "dry run left files in $CUST"
sed -n '/deliberate changes/,/equivalence/p' "$OUT/dry-run.txt"
python3 "$REPO/tools/one-off/2026-11-split-customers.py" --write > "$OUT/write.txt"; rc=$?
[[ $rc -eq 0 ]] && ok "--write exits 0 (checker passed)" || { bad "--write exit $rc"; cat "$OUT/write.txt"; }
ls -l $CUST

echo "== 3. deploy new config and compare"
bash "$REPO/tests/rig/provision.sh" > "$OUT/provision.txt" 2>&1 || { bad "provision"; tail "$OUT/provision.txt"; }
promtool check config /etc/prometheus/prometheus.yml > "$OUT/promtool.txt" 2>&1 && ok "promtool check config" || { bad "promtool"; cat "$OUT/promtool.txt"; }
wait_for 90 "all targets scraped once on the new config" \
    "python3 $REPO/tools/targets-snapshot.py save $OUT/after.json | grep -q ', 0 not up' && [[ \$(grep -c '\"health\": \"up\"' $OUT/after.json) -ge 19 ]]"
python3 "$REPO/tools/targets-snapshot.py" diff "$OUT/before.json" "$OUT/after.json" | tee "$OUT/diff.txt"
labels=$(grep -c '^LABELS' "$OUT/diff.txt" || true)
intervals=$(grep -cE '^INTERVAL +blackbox-ext-.* (1m|1m0s|60s) -> 30s' "$OUT/diff.txt" || true)
other=$(grep -cvE '^LABELS|^INTERVAL +blackbox-ext-.* (1m|1m0s|60s) -> 30s|before, .* after' "$OUT/diff.txt" || true)
[[ "$labels" == 3 && "$intervals" == 2 && "$other" == 0 ]] && ok "only the 3 postgres vm labels and the 2 external intervals changed"     || bad "diff: $labels label changes, $intervals interval changes, $other other"
[[ $(grep '^LABELS' "$OUT/diff.txt" | grep -vc "'vm'") == 0 ]] && ok "the label changes are vm only" || bad "a non-vm label changed"
# Instances, not series: the rig restarts Prometheus, and a restart (unlike
# sync.sh's reload) leaves the old postgres vm series visible for 5 minutes.
[[ $(q 'up{job=~"node-.*-odoo"}') == 3 ]] && ok "OdooVmDown selector still finds 3 Odoo VMs" || bad "node-.*-odoo selector"
[[ $(q 'count by (instance) (up{job=~"postgres-.*"})') == 3 ]] && ok "PostgresDown selector still finds 3 instances" || bad "postgres-.* selector"
[[ $(q 'probe_success{job=~"blackbox-.*"}') == 5 ]] && ok "SiteDown selector still finds 5 probes" || bad "blackbox-.* selector"
[[ $(q 'up{job=~"nginx-.*"}') == 2 ]] && ok "ExporterDown selector still finds 2" || bad "nginx-.* selector"

echo "== 4. checker"
python3 "$REPO/tools/check-targets.py" > "$OUT/check.txt"; rc=$?
cat "$OUT/check.txt"
[[ $rc -eq 0 ]] && ok "checker passes on the migrated files" || bad "checker exit $rc"
python3 "$REPO/tools/check-targets.py" --root "$REPO/prometheus/targets" >/dev/null && ok "checker passes on the repo's git files" || bad "checker on repo files"

NEG=$OUT/neg/customers; mkdir -p "$NEG"
cp $CUST/citiq-v2.yml "$NEG/"
neg() {   # neg <name> <file-content> <expected error fragment>
    local name=$1 body=$2 frag=$3
    printf '%s\n' "$body" > "$NEG/$name.yml"
    out=$(python3 "$REPO/tools/check-targets.py" "$NEG/citiq-v2.yml" "$NEG/$name.yml" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && grep -qi -- "$frag" <<<"$out"; then ok "rejects $name"; else bad "$name not rejected as '$frag' (rc=$rc): $out"; fi
    rm -f "$NEG/$name.yml"
}
neg wrong-cust  "- targets: ['10.9.0.4:9100']
  labels: {job: node-wrong-cust-odoo, customer: other, vm: cx-app-vm-009, role: odoo}" 'must be "wrong-cust"'
neg bad-job     "- targets: ['10.9.0.4:9100']
  labels: {job: nodes-bad-job-odoo, customer: bad-job, vm: cx-app-vm-009, role: odoo}" 'dropped by Prometheus'
neg ext-job     "- targets: ['http://10.9.0.4:8069']
  labels: {job: blackbox-ext-thing, customer: ext-job}" 'reserved'
neg dup         "- targets: ['10.5.0.4:9100']
  labels: {job: node-dup-odoo, customer: dup, vm: cx-app-vm-005, role: odoo}" 'already monitored'
neg placeholder "- targets: ['<ODOO-VM-IP>:9100']
  labels: {job: node-placeholder-odoo, customer: placeholder, vm: x, role: odoo}" 'placeholder'
neg broken      "- targets: ['10.9.0.4:9100'
  labels: {job: node-broken-odoo" 'not valid YAML'
neg vm-mismatch "- targets: ['10.9.0.5:9100']
  labels: {job: node-vm-mismatch-pg, customer: vm-mismatch, vm: cx-db-vm-009, role: postgres}
- targets: ['10.9.0.5:9187']
  labels: {job: postgres-vm-mismatch-pg, customer: vm-mismatch, vm: vm-mismatch-pg, role: postgres}" 'differs from the node vm'
neg extra-label "- targets: ['10.9.0.4:9100']
  labels: {job: node-extra-label-odoo, customer: extra-label, vm: cx-app-vm-009, role: odoo, team: x}" 'not allowed'
neg no-job      "- targets: ['10.9.0.4:9100']
  labels: {customer: no-job, vm: cx-app-vm-009, role: odoo}" 'no job label'
neg probe-ip    "- targets: ['10.9.0.4:8069']
  labels: {job: blackbox-probe-ip, customer: probe-ip}" 'must be a URL'
neg Upper       "- targets: ['10.9.0.4:9100']
  labels: {job: node-Upper-odoo, customer: Upper, vm: cx-app-vm-009, role: odoo}" 'lower case'

echo "== 5. add and remove a customer without a reload"
# From Prometheus's own /metrics: it does not scrape itself, so a PromQL query
# for this is empty, and two empties would compare equal and pass.
reload_ts() { curl -fsS http://127.0.0.1:9090/metrics | awk '$1 == "prometheus_config_last_reload_success_timestamp_seconds" {print $2}'; }
reloads0=$(reload_ts)
[[ -n "$reloads0" ]] && ok "reload timestamp readable ($reloads0)" || bad "cannot read the reload timestamp"
sed -e 's/<customer>/rigtest-v2/g' -e 's/<ODOO-VM-IP>/10.9.0.4/g' -e 's/<PG-VM-IP>/10.9.0.5/g' \
    -e 's/<odoo-vm-name>/cx-app-vm-009/g' -e 's/<pg-vm-name>/cx-db-vm-009/g' \
    /etc/prometheus/targets/customer.yml.example > $CUST/rigtest-v2.yml
python3 "$REPO/tools/check-targets.py" >/dev/null && ok "template filled in passes the checker" || bad "filled template fails the checker"
wait_for 60 "new customer's 4 targets scraped" "[[ \$(rig q 'up{customer=\"rigtest-v2\"} == 1' | wc -l) == 4 ]]"
rig q 'up{customer="rigtest-v2"}'

echo "== 6. broken customer file"
cp $CUST/rigtest-v2.yml "$OUT/rigtest-v2.good"
printf -- "- targets: ['10.9.0.4:9100'\n  labels: {job: node-rigtest-v2-odoo\n" > $CUST/rigtest-v2.yml
sleep 20
n=$(rig q 'up{customer="rigtest-v2"}' | wc -l)
echo "  info  with its file broken, rigtest-v2 has $n targets (Prometheus keeps the last good read if 4)"
[[ $n == 4 ]] && ok "broken file keeps the last good targets" || echo "  NOTE  broken file dropped its targets ($n)"
[[ $(q 'count by (instance) (up{customer="citiq-v2"} == 1)') == 4 ]] && ok "other customers unaffected by a broken file" || bad "a broken file affected another customer"
journalctl -u prometheus --since "-1min" --no-pager | grep -i 'file_sd\|discovery' | tail -2
python3 "$REPO/tools/check-targets.py" >/dev/null; [[ $? -eq 1 ]] && ok "checker flags the broken file" || bad "checker missed the broken file"

rm -f $CUST/rigtest-v2.yml
wait_for 60 "deleted customer's targets dropped" "[[ \$(rig q 'up{customer=\"rigtest-v2\"}' | wc -l) == 0 ]]"
reloads1=$(reload_ts)
[[ -n "$reloads1" && "$reloads0" == "$reloads1" ]] && ok "no config reload was needed for add, break or remove" || bad "a reload happened"

echo
echo "Result: $PASS PASS, $FAIL FAIL"
[[ $FAIL -eq 0 ]]
