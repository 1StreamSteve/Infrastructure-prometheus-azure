#!/bin/bash
# =============================================================================
# sync.sh: apply the git-owned files to Monitoring-VM-001
# =============================================================================
#
# Keeps the running monitoring VM in step with git. A change window runs it
# after `git pull` in /opt/prometheus-azure-build.
#
# What it touches: only the files listed in sync-manifest.conf.
#
# What it never touches: the customer target files in
# /etc/prometheus/targets/customers (the team owns those on the VM),
# grafana.ini (SMTP and admin passwords), nginx.conf, packages, ufw, the
# Prometheus data. It reloads Prometheus, blackbox_exporter, nginx and
# fail2ban rather than restarting them. Grafana only reads its provisioning
# at start-up, so a Grafana change restarts grafana-server (about 10 seconds
# without the UI; alert state is kept in its database).
#
# Usage (as root, from the repo checkout):
#   sudo bash sync.sh                    dry run: show what would change
#   sudo bash sync.sh --apply            apply it
#
# Options:
#   --apply            make the changes (default is a dry run)
#   --any-ref          allow a checkout that is not a clean main matching
#                      origin/main (lab testing from a branch)
#   --allow-fewer-targets
#                      the change removes an infrastructure or external
#                      target on purpose (otherwise a drop in the number of
#                      active targets after the reload is treated as a fault)
#   --restore DIR      put back the files from an earlier sync's backup
#                      (/var/backups/prometheus-azure-sync/<ts>) and apply them
#
# Backups (none of these need the repo to be on main):
#   --backup           take a full snapshot now (do this before any hand edit)
#   --list-backups     list full snapshots and per-sync backups
#   --restore-full TGZ write every file in a full snapshot back and apply.
#                      Git-managed files that did not exist at the snapshot
#                      are removed; customer files created since are left.
#                      The current state is snapshotted first, so a restore
#                      can be undone with another --restore-full.
#
# Every --apply takes a full snapshot first, as well as the per-sync backup.
# A full snapshot covers /etc/prometheus (customer files included),
# /etc/blackbox_exporter, /etc/grafana (grafana.ini included), the monitoring
# vhost, the two unit files and jail.local. Snapshots stay on the VM
# (root-only, mode 600) and the newest 30 of each kind are kept.
#
# Order of an --apply:
#   1. Refuse if Prometheus, blackbox or nginx is already unhealthy.
#   2. Back up every file it is about to change to
#      /var/backups/prometheus-azure-sync/<ts>/.
#   3. Install the files.
#   4. Validate everything: promtool check config, check-targets.py on the
#      git-owned target files, blackbox --config.check, YAML parse and
#      check-rules.py on the Grafana provisioning, nginx -t,
#      fail2ban-client -t, systemd-analyze verify. Any failure: put every
#      file back, nothing reloaded.
#   5. Go live, in order: blackbox, Prometheus, nginx, fail2ban reloads, then
#      the Grafana restart. After each: check it is healthy (Prometheus:
#      config reload successful and, once discovery has settled, no fewer
#      targets; Grafana: its database holds exactly the rules and contact
#      points in the files, built the same way, and the templates are loaded).
#      Any failure: put every file back and apply the old ones again.
#   6. systemctl daemon-reload if a unit file changed. The service is NOT
#      restarted; the summary says which one needs it.
#
# Exit codes: 0 ok, 1 usage or precondition, 2 live stack already unhealthy,
#             4 validation failed (rolled back, nothing reloaded),
#             5 post-apply check failed (rolled back and re-applied),
#             6 a restore could not put the previous state back (act now).
# =============================================================================

set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/sync-manifest.conf"
LOG_FILE="/var/log/prometheus-azure-sync.log"
STATE_DIR="/var/lib/prometheus-azure-sync"
BACKUP_ROOT="/var/backups/prometheus-azure-sync"
TS="$(date +%Y%m%d-%H%M%S)"
PROM=http://127.0.0.1:9090
BBOX=http://127.0.0.1:9115
GRAFANA=http://127.0.0.1:3000
GRAFANA_DB=/var/lib/grafana/grafana.db

APPLY=0
ANY_REF=0
ALLOW_FEWER=0
RESTORE=""
RESTORE_FULL=""
DO_BACKUP=0
LIST_BACKUPS=0
KEEP=30

SNAPSHOT_PATHS=(
    /etc/prometheus
    /etc/blackbox_exporter
    /etc/grafana
    /etc/nginx/sites-available/prometheus.1stream.co.za.conf
    /etc/systemd/system/prometheus.service
    /etc/systemd/system/blackbox_exporter.service
    /etc/fail2ban/jail.local
)

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
[[ -t 1 ]] || { RED=; GRN=; YEL=; BLD=; RST=; }

say()  { echo "$*"; }
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
warn() { echo "${YEL}[WARN]${RST} $*"; }
die()  { echo "${RED}[FAIL]${RST} $*" >&2; exit "${2:-1}"; }

usage() { sed -n '/^# Usage/,/^# Every --apply/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 1; }

while (( $# )); do
    case "$1" in
        --apply)        APPLY=1 ;;
        --any-ref)      ANY_REF=1 ;;
        --allow-fewer-targets) ALLOW_FEWER=1 ;;
        --restore)      [[ $# -ge 2 ]] || usage; RESTORE="$2"; shift ;;
        --restore-full) [[ $# -ge 2 ]] || usage; RESTORE_FULL="$2"; shift ;;
        --backup)       DO_BACKUP=1 ;;
        --list-backups) LIST_BACKUPS=1 ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash sync.sh)."
[[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"

exec 9>/run/prometheus-azure-sync.lock
flock -n 9 || die "Another sync.sh is running."

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
if   [[ -n "$RESTORE_FULL" ]];  then MODE_LABEL="RESTORE-FULL"
elif [[ -n "$RESTORE" ]];       then MODE_LABEL="RESTORE"
elif [[ $DO_BACKUP -eq 1 ]];    then MODE_LABEL="BACKUP"
elif [[ $LIST_BACKUPS -eq 1 ]]; then MODE_LABEL="LIST"
elif [[ $APPLY -eq 1 ]];        then MODE_LABEL="APPLY"
else                                 MODE_LABEL="DRY RUN"; fi
say ""
say "${BLD}=== prometheus-azure sync ${TS} (${MODE_LABEL}) on $(hostname -s) ===${RST}"

# -----------------------------------------------------------------------------
# Health and apply helpers, one per kind of file
# -----------------------------------------------------------------------------
http_ok()   { curl -fsS --max-time 5 -o /dev/null "$1"; }
http_post() { [[ "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$1")" == 200 ]]; }
# Prometheus's own metrics. It does not scrape itself, so these are only on
# its /metrics page, never in a PromQL query. Empty if unreadable.
prom_metric() { curl -fsS --max-time 5 "$PROM/metrics" 2>/dev/null | awk -v m="$1" '$1 == m {print $2}' || true; }
active_targets() { curl -fsS --max-time 10 "$PROM/api/v1/targets?state=active" | jq '.data.activeTargets | length'; }

prom_healthy()    { http_ok "$PROM/-/ready"; }
bbox_healthy()    { http_ok "$BBOX/metrics"; }
nginx_healthy()   { systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1; }
grafana_healthy() { [[ "$(curl -fsS --max-time 5 "$GRAFANA/api/health" 2>/dev/null | jq -r .database 2>/dev/null)" == ok ]]; }

# Grafana's database must match the files: exactly the rules in rules.yml,
# each built the same way (classic condition or expressions) as in the file;
# exactly the file-provisioned contact points in contactpoints.yml; and every
# template in templates.yml loaded. Read-only, so it never locks Grafana.
grafana_provisioned() {
    python3 - "$GRAFANA_DB" /etc/grafana/provisioning/alerting <<'PY'
import json, os, sqlite3, sys, yaml
db, d = sys.argv[1:3]
def load(n):
    p = os.path.join(d, n)
    return (yaml.safe_load(open(p)) or {}) if os.path.exists(p) else {}
file_rules = {r['uid']: r for g in (load('rules.yml').get('groups') or []) for r in g['rules']}
want = set(file_rules)
file_classic = {u for u, r in file_rules.items() if 'classic_conditions' in json.dumps(r.get('data'))}
want_cps = {r['uid'] for c in (load('contactpoints.yml').get('contactPoints') or []) for r in c['receivers']}
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
rows = con.execute('SELECT uid, data FROM alert_rule').fetchall()
have = {u for u, _ in rows}
db_classic = {u for u, d in rows if 'classic_conditions' in (d or '')}
have_cps = {k for t, k, p in con.execute('SELECT record_type, record_key, provenance FROM provenance_type')
            if p == 'file' and t == 'contactPoint'}
problems = []
if have != want:
    problems.append(f'rules differ: missing {sorted(want - have)}, extra {sorted(have - want)}')
if db_classic != file_classic:
    problems.append(f'rule build differs from the file: classic in Grafana only {sorted(db_classic - file_classic)}, '
                    f'in the file only {sorted(file_classic - db_classic)}')
if have_cps != want_cps:
    problems.append(f'contact points differ: missing {sorted(want_cps - have_cps)}, extra {sorted(have_cps - want_cps)}')
names = [t['name'] for t in (load('templates.yml').get('templates') or [])]
cfg = con.execute('SELECT alertmanager_configuration FROM alert_configuration ORDER BY id DESC LIMIT 1').fetchone()
tmpls = json.loads(cfg[0]).get('template_files', {}) if cfg else {}
for n in names:
    if n not in tmpls:
        problems.append(f'template {n} not loaded')
print('; '.join(problems) if problems else f'{len(have)} rules, {len(have_cps)} contact point receivers, templates {names} loaded')
sys.exit(1 if problems else 0)
PY
}

apply_prometheus() {
    local before=$1 t0 t1 okflag
    t0=$(prom_metric prometheus_config_last_reload_success_timestamp_seconds)
    http_post "$PROM/-/reload" || { warn "Prometheus /-/reload did not return 200"; return 1; }
    okflag=$(prom_metric prometheus_config_last_reload_successful)
    t1=$(prom_metric prometheus_config_last_reload_success_timestamp_seconds)
    case "$okflag" in
        1) ;;
        0) warn "Prometheus reports the reload failed (journalctl -u prometheus)"; return 1 ;;
        *) warn "Cannot read Prometheus's reload status from $PROM/metrics"; return 1 ;;
    esac
    awk -v a="${t0:-0}" -v b="${t1:-0}" 'BEGIN { exit !(b > a) }' \
        || { warn "Prometheus's last successful reload did not move forward ($t0 -> $t1)"; return 1; }
    # Target files are live the moment they are written, and service discovery
    # applies changes in batches (about every 5s). So wait for the count to
    # settle: at least 10s, then two equal readings 5s apart (up to a minute),
    # before comparing it with the count before the change.
    local n=-1 prev=-2 i
    sleep 10
    for i in $(seq 1 10); do
        n=$(active_targets 2>/dev/null || echo -1)
        [[ "$n" == "$prev" && "$n" -ge 0 ]] && break
        prev=$n; sleep 5
    done
    [[ "$n" -ge 0 ]] || { warn "Cannot read Prometheus's targets after the reload"; return 1; }
    if (( n < before )); then
        if [[ $ALLOW_FEWER -eq 1 ]]; then warn "Prometheus now has $n active targets, had $before (allowed)"
        else warn "Prometheus now has $n active targets, had $before (use --allow-fewer-targets if intended)"; return 1; fi
    fi
    ok "Prometheus reloaded: config loaded, $n active targets (had $before)."
}
apply_blackbox() {
    http_post "$BBOX/-/reload" || { warn "blackbox /-/reload did not return 200"; return 1; }
    bbox_healthy || return 1
    ok "blackbox_exporter reloaded."
}
apply_nginx() {
    systemctl reload nginx || return 1
    sleep 2
    nginx_healthy || return 1
    ok "nginx reloaded."
}
apply_fail2ban() {
    fail2ban-client reload >/dev/null || return 1
    fail2ban-client ping >/dev/null 2>&1 || return 1
    ok "fail2ban reloaded."
}
# Grafana provisioning adds and updates, but never removes a rule or contact
# point that has gone from the files. So before a restart, anything the
# database holds as file-provisioned that the files no longer have is listed
# in a one-off deletes file, which goes once Grafana has applied it. Only
# file-provisioned items are ever deleted; anything made in the UI is left.
DELETES_FILE=/etc/grafana/provisioning/alerting/zz-sync-deletes.yml
grafana_write_deletes() {
    python3 - "$GRAFANA_DB" /etc/grafana/provisioning/alerting "$DELETES_FILE" <<'PY'
import os, sqlite3, sys, yaml
db, d, out = sys.argv[1:4]
def load(n):
    p = os.path.join(d, n)
    return (yaml.safe_load(open(p)) or {}) if os.path.exists(p) else {}
want_rules = {r['uid'] for g in (load('rules.yml').get('groups') or []) for r in g['rules']}
want_cps = {r['uid'] for c in (load('contactpoints.yml').get('contactPoints') or []) for r in c['receivers']}
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
prov = [(t, k) for t, k, p in con.execute('SELECT record_type, record_key, provenance FROM provenance_type') if p == 'file']
rules = sorted(k for t, k in prov if t == 'alertRule' and k not in want_rules)
cps = sorted(k for t, k in prov if t == 'contactPoint' and k not in want_cps)
if rules or cps:
    doc = {'apiVersion': 1}
    if rules: doc['deleteRules'] = [{'orgId': 1, 'uid': u} for u in rules]
    if cps: doc['deleteContactPoints'] = [{'orgId': 1, 'uid': u} for u in cps]
    with open(out, 'w') as f:
        f.write('# Written by sync.sh for one Grafana restart, then removed.' + chr(10))
        yaml.safe_dump(doc, f, sort_keys=False)
    print(f'rules {rules}, contact points {cps}')
PY
}

apply_grafana() {
    local dels
    rm -f "$DELETES_FILE"
    dels=$(grafana_write_deletes) || { warn "Could not compare Grafana's database with the files"; return 1; }
    if [[ -n "$dels" ]]; then
        chown grafana:grafana "$DELETES_FILE"; chmod 640 "$DELETES_FILE"
        say "  Grafana: removing what the files no longer have: $dels"
    fi
    systemctl restart grafana-server || { rm -f "$DELETES_FILE"; return 1; }
    local i msg
    for i in $(seq 1 45); do grafana_healthy && break; sleep 2; done
    rm -f "$DELETES_FILE"
    grafana_healthy || { warn "Grafana did not come back healthy"; return 1; }
    for i in $(seq 1 15); do msg=$(grafana_provisioned 2>&1) && break; sleep 2; done
    if ! msg=$(grafana_provisioned 2>&1); then warn "Grafana provisioning: $msg"; return 1; fi
    ok "Grafana restarted: $msg."
}

# Apply every kind in AFTER_NEEDED, in a safe order. Returns 1 at the first
# failure, with FAILED_AT set.
FAILED_AT=""
apply_all() {
    local before=$1 k
    for k in blackbox prometheus nginx fail2ban grafana; do
        [[ -n "${AFTER_NEEDED[$k]:-}" ]] || continue
        case $k in
            prometheus) apply_prometheus "$before" || { FAILED_AT=$k; return 1; } ;;
            *)          "apply_$k"                  || { FAILED_AT=$k; return 1; } ;;
        esac
    done
    if [[ -n "${AFTER_NEEDED[systemd]:-}" ]]; then
        systemctl daemon-reload
        ok "systemd daemon-reload done."
        warn "A unit file changed. Its service was NOT restarted. When ready: systemctl restart <unit>"
    fi
}

# -----------------------------------------------------------------------------
# Snapshots
# -----------------------------------------------------------------------------
snapshot() {
    local label=$1 rel=() p
    for p in "${SNAPSHOT_PATHS[@]}"; do
        [[ -e "$p" || -L "$p" ]] && rel+=("${p#/}")
    done
    mkdir -p "$BACKUP_ROOT"; chmod 700 "$BACKUP_ROOT"
    local f="$BACKUP_ROOT/full-${TS}-${label}.tgz"
    tar -C / -czpf "$f" "${rel[@]}" || { rm -f "$f"; return 1; }
    chmod 600 "$f"
    tar -tzf "$f" >/dev/null || { rm -f "$f"; return 1; }
    echo "$f"
}

prune() {
    ls -1t "$BACKUP_ROOT"/full-*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f || true
    ls -1dt "$BACKUP_ROOT"/[0-9]*-[0-9]*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf || true
}

# Everything a restore may need to re-apply.
declare -A AFTER_NEEDED=()
all_kinds() { local k; for k in prometheus blackbox grafana nginx fail2ban systemd; do AFTER_NEEDED[$k]=1; done; }

# -----------------------------------------------------------------------------
# --list-backups, --backup
# -----------------------------------------------------------------------------
if [[ $LIST_BACKUPS -eq 1 ]]; then
    say "Full snapshots (restore with --restore-full <file>):"
    ls -1t "$BACKUP_ROOT"/full-*.tgz 2>/dev/null | while read -r f; do
        printf '  %s  %s\n' "$(du -h "$f" | cut -f1)" "$f"; done || true
    say "Per-sync backups (restore with --restore <dir>):"
    ls -1dt "$BACKUP_ROOT"/[0-9]*-[0-9]*/ 2>/dev/null | while read -r d; do
        printf '  commit %-8s %3s file(s)  %s\n' "$(cat "$d/commit" 2>/dev/null)" \
            "$(wc -l < "$d/restore.list")" "${d%/}"; done || true
    exit 0
fi

if [[ $DO_BACKUP -eq 1 ]]; then
    f=$(snapshot manual) || die "Snapshot failed."
    prune
    ok "Full snapshot: $f ($(du -h "$f" | cut -f1))"
    exit 0
fi

# -----------------------------------------------------------------------------
# --restore-full
# -----------------------------------------------------------------------------
if [[ -n "$RESTORE_FULL" ]]; then
    [[ -f "$RESTORE_FULL" ]] || die "No such snapshot: $RESTORE_FULL"
    tar -tzf "$RESTORE_FULL" >/dev/null 2>&1 || die "$RESTORE_FULL is not a readable tarball."
    before=$(active_targets 2>/dev/null || echo 0)
    pre=$(snapshot pre-restore) || die "Could not snapshot the current state first. Nothing changed."
    ok "Current state saved: $pre"
    tar -C / -xzpf "$RESTORE_FULL" || die "Could not unpack $RESTORE_FULL. Check the files by hand; current state is in $pre." 6
    # Git-managed files the snapshot did not have (added by a later sync) go.
    in_snap=$(tar -tzf "$RESTORE_FULL")
    while read -r src dst owner mode apply; do
        [[ -z "$src" || "$src" == \#* ]] && continue
        if [[ -e "$dst" ]] && ! grep -qxF "${dst#/}" <<<"$in_snap"; then
            rm -f "$dst"; say "  removed $dst (not in the snapshot)"
        fi
    done < "$MANIFEST"
    all_kinds
    if ! apply_all 0; then
        warn "Restored files failed at $FAILED_AT. Putting back the state from before the restore."
        tar -C / -xzpf "$pre" || die "Could not put the previous state back from $pre. Act now." 6
        apply_all 0 || warn "Previous state re-applied but $FAILED_AT is unhealthy. Act now."
        die "Restore failed its checks and was undone." 5
    fi
    ok "Restored from $RESTORE_FULL and applied."
    say "Undo this restore:  sudo bash $SCRIPT_DIR/sync.sh --restore-full $pre"
    exit 0
fi

# -----------------------------------------------------------------------------
# --restore
# -----------------------------------------------------------------------------
if [[ -n "$RESTORE" ]]; then
    RESTORE="${RESTORE%/}"
    [[ -f "$RESTORE/restore.list" ]] || die "$RESTORE has no restore.list; not a sync backup."
    pre=$(snapshot pre-restore) || die "Could not snapshot the current state first. Nothing changed."
    ok "Current state saved: $pre"
    say "Restoring from $RESTORE (backup taken before commit $(cat "$RESTORE/commit" 2>/dev/null || echo unknown))"
    while IFS='|' read -r kind path apply; do
        case "$kind" in
            file)   cp -a "$RESTORE/files$path" "$path"; say "  restored $path" ;;
            absent) rm -f "$path";                      say "  removed  $path (did not exist before)" ;;
        esac
        AFTER_NEEDED[$apply]=1
    done < <(tac "$RESTORE/restore.list")
    apply_all 0 || die "Restored, but $FAILED_AT is not healthy. Undo with: --restore-full $pre" 5
    ok "Restored from $RESTORE and applied."
    say "Undo this restore:  sudo bash $SCRIPT_DIR/sync.sh --restore-full $pre"
    exit 0
fi

# -----------------------------------------------------------------------------
# Git: know exactly what is being applied
# -----------------------------------------------------------------------------
G=(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR")
COMMIT="$("${G[@]}" rev-parse --short HEAD 2>/dev/null)" || die "$SCRIPT_DIR is not a git checkout."
BRANCH="$("${G[@]}" rev-parse --abbrev-ref HEAD)"
DIRTY="$("${G[@]}" status --porcelain --untracked-files=no)"
UPSTREAM="$("${G[@]}" rev-parse --short origin/main 2>/dev/null || echo none)"
say "repo ${SCRIPT_DIR}  branch ${BRANCH}  commit ${COMMIT}  origin/main ${UPSTREAM}"

REF_PROBLEMS=()
[[ "$BRANCH" == "main" ]]      || REF_PROBLEMS+=("not on main (on $BRANCH)")
[[ -z "$DIRTY" ]]              || REF_PROBLEMS+=("uncommitted changes to tracked files")
[[ "$COMMIT" == "$UPSTREAM" ]] || REF_PROBLEMS+=("HEAD $COMMIT is not origin/main $UPSTREAM (git pull?)")
if (( ${#REF_PROBLEMS[@]} )); then
    for p in "${REF_PROBLEMS[@]}"; do warn "$p"; done
    if [[ $APPLY -eq 1 && $ANY_REF -eq 0 ]]; then
        die "Refusing to apply from this checkout. Use --any-ref only for lab testing."
    fi
fi

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------
ENTRIES=()
lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    read -r src dst owner mode apply extra <<< "$line" || true
    [[ -z "${src:-}" ]] && continue
    [[ -z "${extra:-}" && -n "${apply:-}" ]] || die "Manifest line $lineno malformed: $raw"
    [[ -f "$SCRIPT_DIR/$src" ]]  || die "Manifest line $lineno: $src not in repo."
    [[ "$dst" == /* ]]           || die "Manifest line $lineno: destination must be absolute"
    [[ "$dst" != /etc/prometheus/targets/customers/* ]] || die "Manifest line $lineno: customer files are never synced"
    [[ "$mode" =~ ^0[0-7]{3}$ ]] || die "Manifest line $lineno: bad mode $mode"
    [[ "$owner" =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] || die "Manifest line $lineno: bad owner $owner"
    case "$apply" in prometheus|blackbox|grafana|nginx|fail2ban|systemd) ;; *) die "Manifest line $lineno: unknown apply=$apply" ;; esac
    ENTRIES+=("$src|$dst|$owner|$mode|$apply")
done < "$MANIFEST"

# -----------------------------------------------------------------------------
# Plan: compare repo with live
# -----------------------------------------------------------------------------
CHANGES=()
for e in "${ENTRIES[@]}"; do
    IFS='|' read -r src dst owner mode apply <<< "$e"
    srcp="$SCRIPT_DIR/$src"
    if [[ ! -e "$dst" ]]; then
        say "${YEL}NEW${RST}      $dst  (from $src)"
    elif [[ -L "$dst" || ! -f "$dst" ]]; then
        die "$dst exists but is not a regular file; sort that out by hand first."
    elif ! cmp -s "$srcp" "$dst"; then
        say "${YEL}CHANGED${RST}  $dst  (from $src)"
        diff -u --label "live $dst" --label "repo $src" "$dst" "$srcp" | sed 's/^/    /' || true
    elif [[ "$(stat -c '%U:%G %a' "$dst")" != "$owner ${mode#0}" ]]; then
        say "${YEL}OWNER/MODE${RST} $dst  $(stat -c '%U:%G %a' "$dst") -> $owner ${mode#0}"
    else
        continue
    fi
    CHANGES+=("$e")
    AFTER_NEEDED["$apply"]=1
done

say ""
if (( ${#CHANGES[@]} == 0 )); then
    ok "VM matches commit $COMMIT. Nothing to do."
    exit 0
fi
say "${BLD}${#CHANGES[@]} change(s) pending: ${!AFTER_NEEDED[*]}.${RST}"
if [[ $APPLY -eq 0 ]]; then
    say "Dry run only. Re-run with --apply to make these changes."
    exit 0
fi

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
prom_healthy  || die "Prometheus is not ready BEFORE any change. Fix that first; nothing was touched." 2
bbox_healthy  || die "blackbox_exporter is not answering BEFORE any change. Fix that first; nothing was touched." 2
nginx_healthy || die "nginx is down or fails nginx -t BEFORE any change. Fix that first; nothing was touched." 2
BEFORE_TARGETS=$(active_targets) || die "Cannot read Prometheus targets. Nothing was touched." 2
ok "Live stack healthy before changes ($BEFORE_TARGETS active targets)."
grafana_healthy || warn "Grafana is not healthy before changes; continuing, the restart may fix it."

FULL=$(snapshot pre-sync) || die "Full snapshot failed. Nothing changed."
ok "Full snapshot: $FULL"

BK="$BACKUP_ROOT/$TS"
mkdir -p "$BK/files"
chmod 700 "$BACKUP_ROOT" "$BK"
: > "$BK/restore.list"
echo "$COMMIT" > "$BK/commit"
for e in "${CHANGES[@]}"; do
    IFS='|' read -r src dst owner mode apply <<< "$e"
    if [[ -e "$dst" ]]; then
        mkdir -p "$BK/files$(dirname "$dst")"
        cp -a "$dst" "$BK/files$dst"
        echo "file|$dst|$apply" >> "$BK/restore.list"
    else
        echo "absent|$dst|$apply" >> "$BK/restore.list"
    fi
done
ok "Backed up to $BK"

rollback() {
    warn "Rolling back from $BK"
    tac "$BK/restore.list" | while IFS='|' read -r kind path apply; do
        case "$kind" in
            file)   cp -a "$BK/files$path" "$path" ;;
            absent) rm -f "$path" ;;
        esac
    done
}

for e in "${CHANGES[@]}"; do
    IFS='|' read -r src dst owner mode apply <<< "$e"
    mkdir -p "$(dirname "$dst")"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$SCRIPT_DIR/$src" "$dst.sync-new"
    mv -f "$dst.sync-new" "$dst"
    say "  installed $dst"
done

# ---- Validate everything before anything goes live ----
FAILS=()
if [[ -n "${AFTER_NEEDED[prometheus]:-}" ]]; then
    if ! out=$(promtool check config /etc/prometheus/prometheus.yml 2>&1); then
        echo "$out" | sed 's/^/    /'; FAILS+=("promtool check config")
    fi
    if ! out=$(python3 "$SCRIPT_DIR/tools/check-targets.py" /etc/prometheus/targets/infrastructure.yml /etc/prometheus/targets/external.yml 2>&1); then
        echo "$out" | sed 's/^/    /'; FAILS+=("check-targets.py on the git-owned target files")
    fi
fi
if [[ -n "${AFTER_NEEDED[blackbox]:-}" ]]; then
    blackbox_exporter --config.check --config.file=/etc/blackbox_exporter/blackbox.yml >/dev/null 2>&1 \
        || FAILS+=("blackbox_exporter --config.check")
fi
if [[ -n "${AFTER_NEEDED[grafana]:-}" ]]; then
    for f in /etc/grafana/provisioning/alerting/*.yml /etc/grafana/provisioning/datasources/*.yml; do
        python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null || FAILS+=("YAML parse $f")
    done
    # Grafana loads a broken rule and only fails when it evaluates it, so
    # check references, data sources, durations, routes and templates first.
    if ! out=$(python3 "$SCRIPT_DIR/tools/check-rules.py" /etc/grafana/provisioning/alerting 2>&1); then
        echo "$out" | grep '^ERROR' | sed 's/^/    /'; FAILS+=("check-rules.py")
    fi
fi
if [[ -n "${AFTER_NEEDED[nginx]:-}" ]]; then
    nginx -t >/dev/null 2>&1 || { nginx -t 2>&1 | sed 's/^/    /'; FAILS+=("nginx -t"); }
fi
if [[ -n "${AFTER_NEEDED[fail2ban]:-}" ]]; then
    fail2ban-client -t >/dev/null 2>&1 || FAILS+=("fail2ban-client -t")
fi
if [[ -n "${AFTER_NEEDED[systemd]:-}" ]] && command -v systemd-analyze >/dev/null; then
    for e in "${CHANGES[@]}"; do
        IFS='|' read -r src dst owner mode apply <<< "$e"
        [[ "$apply" == systemd ]] && { systemd-analyze verify "$dst" >/dev/null 2>&1 || FAILS+=("systemd-analyze verify $dst"); }
    done
fi
if (( ${#FAILS[@]} )); then
    for f in "${FAILS[@]}"; do warn "check failed: $f"; done
    rollback
    die "Validation failed. Files restored, nothing reloaded, monitoring untouched." 4
fi
ok "All checks passed."

# Customer files are the team's, never changed here; report, don't block.
if ! out=$(python3 "$SCRIPT_DIR/tools/check-targets.py" 2>&1); then
    warn "A customer target file has problems (not changed by this sync):"
    echo "$out" | grep -A20 '^ERROR' | sed 's/^/    /'
fi

# ---- Go live ----
if ! apply_all "$BEFORE_TARGETS"; then
    warn "Go-live failed at: $FAILED_AT"
    rollback
    all_kinds
    if apply_all 0; then ok "Previous files re-applied and healthy."
    else warn "Previous files re-applied but $FAILED_AT is unhealthy. Act now, or: --restore-full $FULL"; fi
    die "Post-apply check failed. Rolled back." 5
fi

mkdir -p "$STATE_DIR"
printf 'commit=%s\nbranch=%s\napplied=%s\nbackup=%s\nsnapshot=%s\nby=%s\n' \
    "$COMMIT" "$BRANCH" "$TS" "$BK" "$FULL" "${SUDO_USER:-root}" > "$STATE_DIR/last-sync"
prune

say ""
ok "${BLD}Synced to commit $COMMIT.${RST} Log: $LOG_FILE"
say "Undo just this sync:     sudo bash $SCRIPT_DIR/sync.sh --restore $BK"
say "Put the whole VM back:   sudo bash $SCRIPT_DIR/sync.sh --restore-full $FULL"
