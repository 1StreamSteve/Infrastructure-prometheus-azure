#!/bin/bash
# =============================================================================
# verify.sh: read-only health check of Monitoring-VM-001
# =============================================================================
#
# Run after every sync.sh --apply, after patching, and whenever something
# looks off. Changes nothing.
#
#   sudo bash /opt/prometheus-azure-build/verify.sh
#
# Every check prints PASS, FAIL or UNDETERMINED. UNDETERMINED means the check
# could not get an answer (an API down, a file unreadable); it is never
# counted as a pass.
#
# Exit codes: 0 all PASS, 1 any FAIL, 2 no FAIL but something UNDETERMINED.
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROM=http://127.0.0.1:9090
BBOX=http://127.0.0.1:9115
GRAFANA=http://127.0.0.1:3000
GRAFANA_DB=/var/lib/grafana/grafana.db

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo bash verify.sh)"; exit 1; }

P=0 F=0 U=0
pass()  { echo "  PASS          $*"; P=$((P+1)); }
fail()  { echo "  FAIL          $*"; F=$((F+1)); }
undet() { echo "  UNDETERMINED  $*"; U=$((U+1)); }
info()  { echo "  info          $*"; }

echo "=== verify $(hostname -s) $(date '+%Y-%m-%d %H:%M:%S %Z') ==="

echo "-- services"
for u in prometheus blackbox_exporter grafana-server nginx fail2ban prometheus-node-exporter; do
    s=$(systemctl is-active "$u" 2>/dev/null); s=${s:-unknown}
    [[ $s == active ]] && pass "$u active" || fail "$u is $s"
    e=$(systemctl is-enabled "$u" 2>/dev/null); e=${e:-unknown}
    [[ $e == enabled ]] || fail "$u is $e at boot"
done

echo "-- Prometheus"
if curl -fsS --max-time 5 -o /dev/null "$PROM/-/ready"; then
    pass "ready"
    # Prometheus does not scrape itself: read its own /metrics, not PromQL.
    r=$(curl -fsS --max-time 5 "$PROM/metrics" 2>/dev/null | awk '$1 == "prometheus_config_last_reload_successful" {print $2}')
    r=${r:-none}
    case $r in 1) pass "config loaded";; 0) fail "last config reload FAILED (journalctl -u prometheus)";; *) undet "reload status unreadable ($r)";; esac
    # Just after a reload, new targets show health "unknown" until their first
    # scrape. Wait for that (up to a minute) rather than call them down.
    for _ in $(seq 1 12); do
        t=$(curl -fsS --max-time 10 "$PROM/api/v1/targets?state=active") || break
        [[ $(jq '[.data.activeTargets[] | select(.health == "unknown")] | length' <<<"$t") == 0 ]] && break
        sleep 5
    done
    if t=$(curl -fsS --max-time 10 "$PROM/api/v1/targets?state=active"); then
        n=$(jq '.data.activeTargets | length' <<<"$t")
        down=$(jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.labels.instance) \(.lastError)"' <<<"$t")
        if [[ "$n" -eq 0 ]]; then fail "no active targets at all"
        elif [[ -z "$down" ]]; then pass "all $n targets up"
        else fail "$(grep -c . <<<"$down") of $n targets not up:"; sed 's/^/                  /' <<<"$down"; fi
        info "per pool: $(jq -r '[.data.activeTargets[].scrapePool] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"$t")"
    else
        undet "targets API unreadable"
    fi
else
    fail "Prometheus not ready on $PROM"
fi
out=$(promtool check config /etc/prometheus/prometheus.yml 2>&1) && pass "promtool check config" || { fail "promtool check config"; sed 's/^/                  /' <<<"$out"; }

echo "-- target files"
if [[ -f "$SCRIPT_DIR/tools/check-targets.py" ]]; then
    out=$(python3 "$SCRIPT_DIR/tools/check-targets.py" 2>&1); rc=$?
    case $rc in
        0) pass "check-targets.py: $(grep -c '^OK' <<<"$out") file(s) good";;
        1) fail "check-targets.py found problems:"; grep -A20 '^ERROR' <<<"$out" | sed 's/^/                  /';;
        *) undet "check-targets.py could not run: $(tail -1 <<<"$out")";;
    esac
    info "customers: $(ls /etc/prometheus/targets/customers/*.yml 2>/dev/null | xargs -rn1 basename | sed 's/\.yml$//' | paste -sd' ')"
else
    undet "tools/check-targets.py not found next to verify.sh"
fi

echo "-- blackbox_exporter"
curl -fsS --max-time 5 -o /dev/null "$BBOX/metrics" && pass "answering" || fail "not answering on $BBOX"
blackbox_exporter --config.check --config.file=/etc/blackbox_exporter/blackbox.yml >/dev/null 2>&1 \
    && pass "config check" || fail "blackbox config check"

echo "-- Grafana"
h=$(curl -fsS --max-time 5 "$GRAFANA/api/health" 2>/dev/null | jq -r .database 2>/dev/null)
[[ $h == ok ]] && pass "healthy" || fail "health: ${h:-no answer}"
if [[ -r "$GRAFANA_DB" ]]; then
    out=$(python3 - "$GRAFANA_DB" /etc/grafana/provisioning/alerting/rules.yml <<'PY' 2>&1
import json, sqlite3, sys, yaml
db, rules_file = sys.argv[1:3]
want = {r['uid'] for g in yaml.safe_load(open(rules_file))['groups'] for r in g['rules']}
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
rows = con.execute('SELECT uid, data FROM alert_rule').fetchall()
have = {u for u, _ in rows}
print('RULES', len(have), 'missing', sorted(want - have), 'extra', sorted(have - want))
print('CLASSIC', [u for u, d in rows if 'classic_conditions' in (d or '')])
prov = {(t, k) for t, k, p in con.execute('SELECT record_type, record_key, provenance FROM provenance_type') if p == 'file'}
print('UNPROVISIONED', sorted(u for u in have if ('alertRule', u) not in prov))
print('CONTACTS', sorted(k for t, k in prov if t == 'contactPoint'))
err = con.execute("SELECT rule_uid, labels FROM alert_instance WHERE current_state = 'Error'").fetchall()
print('ERRORS', [e[0] for e in err])
cfg = con.execute('SELECT alertmanager_configuration FROM alert_configuration ORDER BY id DESC LIMIT 1').fetchone()
print('TEMPLATES', sorted(json.loads(cfg[0]).get('template_files', {})) if cfg else [])
PY
)
    if [[ $? -ne 0 ]]; then undet "Grafana database unreadable: $(tail -1 <<<"$out")"
    else
        line() { grep "^$1 " <<<"$out" | cut -d' ' -f2-; }
        r=$(line RULES); [[ "$r" == *"missing [] extra []"* ]] && pass "rules match rules.yml (${r%% *})" || fail "rules: $r"
        [[ "$(line CLASSIC)" == "[]" ]] && pass "no classic conditions" || fail "classic conditions in $(line CLASSIC)"
        [[ "$(line UNPROVISIONED)" == "[]" ]] && pass "every rule provisioned from file" || fail "rules not from file: $(line UNPROVISIONED)"
        c=$(line CONTACTS)
        for cp in email-oncall-uid sms-oncall-uid email-only-uid; do
            [[ "$c" == *"'$cp'"* ]] && pass "contact point $cp provisioned" || fail "contact point $cp missing"
        done
        [[ "$(line ERRORS)" == "[]" ]] && pass "no rule in Error state" || fail "rules in Error: $(line ERRORS)"
        [[ "$(line TEMPLATES)" == *"'1stream'"* ]] && pass "1stream notification template loaded" || fail "templates loaded: $(line TEMPLATES)"
    fi
else
    undet "cannot read $GRAFANA_DB"
fi

echo "-- nginx, fail2ban"
nginx -t >/dev/null 2>&1 && pass "nginx -t" || fail "nginx -t"
code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' --resolve prometheus.1stream.co.za:443:127.0.0.1 https://prometheus.1stream.co.za/api/health)
[[ $code == 200 ]] && pass "Grafana through the local vhost (HTTPS 200)" || fail "local vhost /api/health returned $code"
fail2ban-client ping >/dev/null 2>&1 && pass "fail2ban answering" || fail "fail2ban not answering"

echo "-- git and sync state"
if [[ -d "$SCRIPT_DIR/.git" ]]; then
    G=(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR")
    info "checkout $("${G[@]}" rev-parse --short HEAD) on $("${G[@]}" rev-parse --abbrev-ref HEAD), origin/main $("${G[@]}" rev-parse --short origin/main 2>/dev/null)"
    [[ -f /var/lib/prometheus-azure-sync/last-sync ]] && info "last sync: $(tr '\n' ' ' < /var/lib/prometheus-azure-sync/last-sync)"
fi
drift=0
while read -r src dst owner mode apply; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    if [[ ! -f "$dst" ]]; then fail "missing on the VM: $dst"; drift=1
    elif ! cmp -s "$SCRIPT_DIR/$src" "$dst"; then fail "differs from git: $dst"; drift=1; fi
done < "$SCRIPT_DIR/sync-manifest.conf"
[[ $drift -eq 0 ]] && pass "every git-managed file matches this checkout"

echo "-- host"
info "kernel $(uname -r), up since $(uptime -s)"
df_pct=$(df --output=pcent /data/prometheus 2>/dev/null | tail -1 | tr -dc 0-9)
if [[ -z "$df_pct" ]]; then undet "cannot read disk use of /data/prometheus"
elif (( df_pct < 80 )); then pass "Prometheus disk ${df_pct}% used"
else fail "Prometheus disk ${df_pct}% used"; fi
[[ -f /var/run/reboot-required ]] && info "reboot required: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"

echo
echo "Result: $P PASS, $F FAIL, $U UNDETERMINED"
(( F > 0 )) && exit 1
(( U > 0 )) && exit 2
exit 0
