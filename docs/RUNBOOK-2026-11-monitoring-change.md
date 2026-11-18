# Monitoring-VM-001 change, November 2026: git control, per-customer targets and new alerts (Ubuntu 24.04, Prometheus 2.51.2, Grafana 13.0.1)

This brings the Azure monitoring VM under git and fixes three things: alerts that never said what tripped, customer targets buried in `prometheus.yml`, and external probe alerts firing on short blips between Azure and Bree Street. Ubuntu patching and the kernel are a separate change, not this one.

Every step here was rehearsed end to end on the WSL test rig (`tests/step6-sync.sh`, 46 PASS) against a copy of the live config taken on 18 Nov 2026.

## What you end up with

- The VM running exactly what is on `main`, with `sync.sh` reporting `Nothing to do` and `verify.sh` all PASS.
- One file per customer in `/etc/prometheus/targets/customers/`, which the team adds and removes on the VM with no reload.
- Alerts that name what tripped, in the email subject and the SMS, e.g. `[FIRING:1] WARNING HighCPU | citiq-v2 | cx-app-vm-005 | 95%`.
- External probes judged over a window: ExternalSiteDown only when every probe has failed for 5 minutes, and an email-only ExternalSiteDegraded when over half fail in 15 minutes.
- A full snapshot of the old config on the VM, and an Azure restore point taken just before.

## Before you start

- Change number: `#_____`. Window about 60 minutes. Grafana is down for about 10 seconds during the sync; Prometheus keeps scraping throughout.
- `main` on GitHub at commit `_______` or later (the commit this runbook was signed off on).
- From your PC: Azure CLI logged in (`az login`), and the repo cloned at `C:\1Stream_Claude_Code\Infrastructure-prometheus-azure`.
- Bastion access to Monitoring-VM-001 and root (`sudo -i`).
- A phone on the SMS list (`contactpoints.yml`), to see the test SMS arrive.
- Part A done ahead of the window: the VM needs its deploy key on the repo and its clone in place.
- **Work in a screen session on the VM.** A dropped Bastion session would otherwise kill a step halfway. If it drops, `screen -r prom-change` and let the step finish.

## How it works

`sync.sh` applies the git-owned files listed in `sync-manifest.conf` and nothing else. It never touches the customer files, `grafana.ini` (SMTP and admin passwords) or the Prometheus data.

An apply:
1. Takes a full snapshot.
2. Installs the files.
3. Validates everything: `promtool`, `check-targets.py`, blackbox `--config.check`, `check-rules.py`, `nginx -t`, `fail2ban-client -t`.
4. Reloads Prometheus, blackbox, nginx and fail2ban, and restarts Grafana, which only reads its provisioning at start-up.
5. Checks each one afterwards. Any failure puts every file back and applies the old ones again.

The migration script is a one-off. It reads the live June-style `prometheus.yml` and writes the customer files. It refuses to write anything unless the new layout scrapes exactly the old targets with exactly the old labels. The only allowed differences are the five agreed ones:
- three postgres `vm` labels, so each DB VM is named the same everywhere (`stagezero-v2-pg` becomes `cx-db-vm-001`)
- the two external probes, which move from every 60s to every 30s

| `sync.sh` exit | Meaning |
|---|---|
| 0 | Done |
| 1 | Refused before changing anything (not a clean `main`, bad argument) |
| 2 | The stack was already unhealthy; nothing touched |
| 4 | Validation failed; files put back, nothing reloaded |
| 5 | A post-apply check failed; files put back and re-applied |
| 6 | A restore could not put the previous state back. Act now |

## Part A: deploy key and clone (ahead of the window, no impact)

**A1. Give the VM a read-only deploy key.** From your PC (CMD):

```
cd /d C:\1Stream_Claude_Code\Infrastructure-prometheus-azure
az vm run-command invoke -g RG_INFRASTRUCTURE -n Monitoring-VM-001 --command-id RunShellScript ^
  --scripts @tools/node-git/01-deploy-key.sh --query "value[0].message" -o tsv
```

The output ends with `host key: ssh.github.com:443 pinned (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU)` and a `PUBKEY Monitoring-VM-001: ssh-ed25519 ...` line. Outbound 22 is blocked from our networks, so the key reaches GitHub through `ssh.github.com:443`.

**A2. Add the key to the repo.** GitHub, the repo, Settings, Deploy keys, Add deploy key. Title `Monitoring-VM-001 read-only`, paste the `ssh-ed25519 ...` part, leave "Allow write access" unticked.

**A3. Clone.** From your PC (CMD):

```
az vm run-command invoke -g RG_INFRASTRUCTURE -n Monitoring-VM-001 --command-id RunShellScript ^
  --scripts @tools/node-git/02-clone.sh --query "value[0].message" -o tsv
```

Expect `HEAD:` and `origin/main:` to show the same commit. Nothing the monitoring stack reads has changed yet.

## Part B: the change window

### B1. Restore point

From your PC (CMD):

```
pwsh -NoProfile -File tools\azure\Invoke-PreChangeBackup.ps1 -RetainDays 30
```

Wait for `The VM has an instant-restore point. Safe to proceed with the change.` (about 8 minutes). Anything else, stop.

### B2. Screen session and starting state

On the VM (bash):

```bash
sudo -i
screen -S prom-change
mkdir -p /root/prom-change && cd /opt/prometheus-azure-build && git pull --ff-only
git log -1 --oneline
uname -r | tee /root/prom-change/kernel-before.txt
python3 tools/targets-snapshot.py save /root/prom-change/00-before.json
```

Expect `19 targets, 0 not up`. If any target is down, find out why before going on: it would muddy every comparison after this.

Note the kernel for the record; this change doesn't touch it.

### B3. Migrate the customers into their own files

Dry run first:

```bash
python3 tools/one-off/2026-11-split-customers.py | tee /root/prom-change/migrate-dry.txt | head -20
```

Check for:
- `old config: 19 targets in 19 jobs`
- `customers: citiq-v2 (4), om-pfdirect-v2 (4), stagezero-v2 (4)`
- the five deliberate changes: three `vm ... -> cx-db-vm-00x` and two `scrape interval 60s -> 30s`
- `equivalence: OK`

If it says `STOPPED`, the live config is not what was rehearsed. Stop and look at what it lists.

```bash
python3 tools/one-off/2026-11-split-customers.py --write
```

This writes the three files and runs the checker on them (`all good`). Nothing reads them yet: the old `prometheus.yml` has no file targets.

### B4. Sync

```bash
bash sync.sh | tee /root/prom-change/sync-dry.txt | tail -5
```

Expect `8 change(s) pending`:
- CHANGED: `prometheus.yml`, `rules.yml`, `contactpoints.yml`, `policies.yml`
- NEW: `infrastructure.yml`, `external.yml`, `customer.yml.example`, `templates.yml`

The diff of each changed file is in `sync-dry.txt`. Nothing else should be listed. Anything more means the VM has drifted since the 18 Nov capture; stop and look.

```bash
bash sync.sh --apply | tee /root/prom-change/sync-apply.txt
```

Expect, in order:
- `All checks passed.`
- `Prometheus reloaded: config loaded, 19 active targets (had 19).`
- `Grafana restarted: 17 rules, 3 contact point receivers, templates ['1stream'] loaded.`
- `Synced to commit ...`, then the two undo commands. **Copy those two lines into the change record.**

### B5. Verify

```bash
bash verify.sh | tee /root/prom-change/verify.txt | tail -1
python3 tools/targets-snapshot.py save /root/prom-change/02-after-sync.json
python3 tools/targets-snapshot.py diff /root/prom-change/00-before.json /root/prom-change/02-after-sync.json
bash sync.sh | tail -1
```

Expect:
- `verify.sh`: `0 FAIL, 0 UNDETERMINED`
- the diff: exactly the five deliberate differences, `19 before, 19 after, 5 difference(s)`
- `sync.sh`: `VM matches commit ... Nothing to do.`

For up to 5 minutes the PostgreSQL dashboard can show each DB VM under both its old and new name. The old series fade out over Prometheus's 5 minute lookback. Both read healthy, so nothing alerts.

Any alert that was firing before the change re-evaluates under the new rules, and sends one notification in the new format.

### B6. A real alert, end to end

This proves the new subject reaches email and SMS. It also walks the team's add and remove customer process. First confirm nothing answers on the test address:

```bash
curl -s --max-time 3 http://10.0.0.250:9100/metrics >/dev/null && echo "IN USE, pick another" || echo "free"
cat > /etc/prometheus/targets/customers/changetest.yml <<'EOF'
- targets: ['10.0.0.250:9100']
  labels: {job: node-changetest-odoo, customer: changetest, vm: change-test, role: odoo}
EOF
python3 tools/check-targets.py | tail -1
```

Expect `all good`. Within about 3 minutes (the 1 minute `for`, evaluation and 30s grouping), infra@ and the SMS phones get:

```
[FIRING:1] CRITICAL OdooVmDown | changetest | change-test | up 0
```

Then remove it the way the team will remove a real customer:

```bash
bash tools/remove-customer.sh changetest
```

Type `changetest` when asked. Expect `Deleted. No samples left for changetest.` About 5 minutes later (the next 5 minute notification interval): `[RESOLVED] CRITICAL OdooVmDown | changetest | change-test`. On the rig the firing pair came 110 seconds after the file was written and the resolved pair 301 seconds after the removal.

### B7. Close

```bash
cat /var/lib/prometheus-azure-sync/last-sync
exit    # leave screen
```

Attach `/root/prom-change/` to the change record (`sync-apply.txt` and `verify.txt` at least).

## Rollback

**Config, any time after B4.** `sync.sh` printed the full-snapshot undo at the end of the apply:

```bash
bash /opt/prometheus-azure-build/sync.sh --restore-full /var/backups/prometheus-azure-sync/full-<ts>-pre-sync.tgz
```

This puts back the June `prometheus.yml`, the 14 June rules and the old contact points. It removes the rules and the `email-only` contact point the change added, and checks Grafana matches. On the rig this took about a minute.

The customer files stay, but the June config doesn't read them. `sync.sh --list-backups` lists every snapshot.

**A config change that fails during B4.** Nothing to do: `sync.sh` has already put every file back and re-applied it (exit 4 or 5). Read the `[WARN]` lines, fix it in git, and run B4 again.

**Last resort, if the VM itself is in trouble.** Azure portal, vault `cx-nginx-vm-001-backup`, Backup items, Monitoring-VM-001, Restore VM, Replace existing, the restore point from B1. Prometheus loses the minutes written since B1.

## Troubleshooting

**`Refusing to apply from this checkout.`** The clone isn't a clean `main` at `origin/main`. Run `git pull --ff-only` and `git status`. Never use `--any-ref` on the VM: it is for the test rig.

**Exit 2, `... is not ready BEFORE any change`.** The stack was already unhealthy. Fix that first (`systemctl status`, `journalctl -u <unit>`); nothing was touched.

**Exit 4.** A check failed before anything went live. The `[WARN] check failed:` line names it, with the check's own output above it.

**Exit 5 at `prometheus`, `Prometheus now has N active targets, had M`.** The change dropped targets. If that was intended, run again with `--allow-fewer-targets`. If not, the change is wrong.

**Exit 5 at `grafana`.** Grafana rejected the provisioning, or its database does not match the files. `journalctl -u grafana-server -n 100` shows the reason. The old files are already back.

**`check-targets.py` ERROR on a customer file.** The message names the file and the rule broken. A broken customer file keeps its last good targets in Prometheus, and doesn't affect other customers, but fix it promptly.

**`remove-customer.sh`: `Prometheus still has N target(s)`.** The customer also appears in another file. It lists the files.

## Maintenance

- After a Grafana upgrade (`upgrade-grafana.sh`), run `verify.sh`. Provisioned rules, contact points and templates are read again at start-up, and `verify.sh` checks the database matches the files.
- Prometheus and blackbox_exporter are upstream binaries in `/usr/local/bin`, not apt packages, so apt never upgrades them.
- `grafana.ini` has its `[smtp]` block twice, from the June setup script running twice. It's harmless (Grafana uses the last one) and is left for a tidy-up by hand. It's outside git.
- Rebuilding the VM: install `prometheus-node-exporter` before creating any `prometheus` user. The package creates it as a system user and fails to install if an ordinary one exists.
