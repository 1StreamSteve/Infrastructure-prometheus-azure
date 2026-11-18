# Plan: Azure monitoring under git, plus three fixes

Monitoring-VM-001 (`10.0.0.6`, RG_INFRASTRUCTURE) runs Prometheus 2.51.2, blackbox_exporter 0.25.0, Grafana 13.0.1 (Grafana-managed alerting, not Alertmanager) and nginx. It went live in June 2026 from the files in `source-material/monitoring`. This plan brings it under git and makes three changes. Steve deploys in a change window.

## What the investigation found (18 Nov 2026)

Read-only capture through an Azure Run Command, in `source-material/node-capture-20261118` (not committed).

- **Live matches the source**, apart from the filled-in placeholders and `prometheus.yml`. The live `prometheus.yml` has the nginx pair, external probes for `uc.1stream.co.za` and `scripts.1stream.co.za`, and three customers: stagezero-v2, om-pfdirect-v2 and citiq-v2. All 14 alert rules are file-provisioned and have never been edited in the UI. The folder is "1Stream Alerts".
- **Why alerts don't say what tripped.** Every rule uses a classic condition, which collapses all series into one alert instance and drops their labels. SiteDown fires once for "some probe is failing", with only `alertname`, `grafana_folder` and `severity` as labels, so the annotations render `[no value]` and the SMS subject is `[FIRING:1] SiteDown (1Stream Alerts critical)`. One failing probe also holds the alert open for every probe, customer and external alike.
- **External probe noise.** SiteDown fired 10 times in 45 days, all on the external probes, none longer than 2 minutes. The customer probes and every scrape target were clean for 30 days.
  - scripts.1stream.co.za stalls in the TLS handshake for about an hour from around 23:05 (13 and 17 Nov). uc was fine during both windows, so it is the scripts server, not the link.
  - uc.1stream.co.za had full 15s timeouts at night on 22 and 28 Oct.
  - The few slow-but-successful probes are 5s DNS retries on the monitoring VM.
- **The `vm` label isn't consistent.** postgres_exporter targets call the DB VM `stagezero-v2-pg`, while its node_exporter calls it `cx-db-vm-001`.
- **Not monitored:** 1streamcx (VM-004), flash (VM-006), amathuba (VM-008), CX-QA.
- **Backup:** Monitoring-VM-001 is in vault `cx-nginx-vm-001-backup`, daily.
- **Owned by the nginx repo, not this one:** the LB vhost `prometheus.1stream.co.za.conf` on CX-Nginx-VM-001/002 and the nginx exporter on those nodes.

## Decisions agreed

1. **Customer target files are server-only.** One file per customer in `/etc/prometheus/targets/customers/`. The team adds and removes them on the VM. Git owns everything else and ships a template and a checker, never the customer files. `sync.sh` never writes to that folder.
2. **SMS keeps getting everything**, except the new external "degraded" warning, which goes to email only.
3. **External probes:**
   - **critical:** every probe failed for 5 minutes straight
   - **email-only warning:** more than half failed over 15 minutes
4. **Fix the postgres `vm` label now** to the Azure VM name. That costs a one-off join in the PostgreSQL dashboard history.

## Design

### Repo layout

```
prometheus/prometheus.yml              system config, file_sd jobs
prometheus/targets/infrastructure.yml  nginx pair + monitoring VM
prometheus/targets/external.yml        uc, scripts (external probes)
prometheus/targets/customer.yml.example  template for the team
blackbox/blackbox.yml
grafana/provisioning/alerting/         rules, contact points, policies, templates
grafana/provisioning/datasources/prometheus.yml
grafana/dashboards/                    the two custom dashboards (import by hand, as now)
nginx/prometheus.1stream.co.za.conf    the monitoring VM's own vhost
systemd/                               prometheus.service, blackbox_exporter.service
exporters/                             scripts run on customer and nginx VMs
sync.sh, verify.sh, sync-manifest.conf
tools/check-targets.py                 validates customer files (sync and the team run it)
tools/remove-customer.sh               purge a removed customer's series
tools/node-capture/, tools/node-git/, tools/one-off/
tests/                                 WSL test rig
source-material/monitoring/            the original June build, for reference
```

### Customer files (issue 2)

- **Jobs read the files by glob.** Prometheus jobs `node`, `postgres` and `blackbox-customer` all read `targets/customers/*.yml`. Each keeps only its own targets by `job` prefix.
- **Every target sets its `job` label explicitly**, for example `job: node-citiq-v2-odoo`. Prometheus only applies `job_name` when the target has no `job` label of its own. So every series keeps its exact current identity, and history, dashboards and rule selectors carry on. To be proven on the test rig.
- **New and removed files are picked up without a reload.**
- **Removing a customer** is: delete its file, then run `tools/remove-customer.sh <customer>` to delete its series.
- **The checker** (`tools/check-targets.py`) checks each customer file for:
  - valid YAML
  - the required labels, with `customer` matching the file name
  - a known job prefix
  - no duplicate targets across files

  A file the checker rejects never silently drops targets.
- **The one-off migration** (`tools/one-off/2026-11-split-customers.py`) writes the customer files from the live `prometheus.yml`. It compares the target label sets Prometheus reports before and after. The postgres `vm` change must be the only difference.

### Alerts (issue 1)

- **Rule expressions.** Every rule is rebuilt from a Prometheus query, a Reduce (last) and a Threshold, in place of the classic condition. That gives one alert instance per server or probe, with its labels.
- **Keeping `customer` in aggregations.** Rules that aggregate do it `by (customer, vm, instance)` (HighCPU, LongRunningTransaction), so `customer` survives.
- **Templates.** A notification template, `1stream.subject`, gives email and SMS the same subject:
  - `[FIRING] CRITICAL SiteDown | citiq-v2 | http://10.5.0.4:8069`
  - `[FIRING] WARNING HighCPU | citiq-v2 | cx-app-vm-005 | 92%`
  - `[FIRING] CRITICAL ExternalSiteDown | uc-voice-platform | https://uc.1stream.co.za`

  External probes show `site` where the customer goes. A grouped notification adds `(+N more)`. The body lists each alert with summary, labels, value and links.
- **Grouping.** `group_by` changes to `alertname, customer, vm, instance`, so different systems never merge into one notification.
- **No-data handling.** `noDataState: OK` on every rule. `execErrState: Error` stays, so a broken Prometheus still alerts.
- **UIDs.** Rule UIDs stay where the rule keeps its meaning. Renamed or removed rules are deleted explicitly with `deleteRules`.

### External probes (issue 3)

- External probes move to 30s, scrape timeout 15s.
- `SiteDown`, `SlowResponse` and `SSLCertExpiringSoon` stay as they are for the customer probes, now per probe, and exclude `blackbox-ext-*`.
- New external rules:

| Rule | Query | Fires when | Severity | Route |
|---|---|---|---|---|
| ExternalSiteDown | `max_over_time(probe_success{job=~"blackbox-ext-.*"}[5m])` | < 1, for 1m | critical | email + SMS |
| ExternalSiteDegraded | `avg_over_time(probe_success{job=~"blackbox-ext-.*"}[15m])` | < 0.5 | warning | email only |
| ExternalSlowResponse | `quantile_over_time(0.5, probe_duration_seconds{job=~"blackbox-ext-.*"}[10m])` | > 5, for 5m | warning | email + SMS |

- Against the last 30 days:
  - ExternalSiteDown would have fired 0 times.
  - ExternalSiteDegraded would have fired once, for scripts on 17 Nov.
  - ExternalSlowResponse would have fired 0 times.

### Contact points and routing

- `email-oncall` (email + SMS, existing uid) stays the default.
- New `email-only` contact point.
- A child policy sends `alertname = ExternalSiteDegraded` to `email-only`.

### Deployment

- **Clone location:** `/opt/prometheus-azure-build`, read-only deploy key, alias to `ssh.github.com:443`, host key pinned.
- **`sync.sh`** (modelled on the nginx repo):
  1. dry-run diff
  2. snapshot `/etc/prometheus`, `/etc/blackbox_exporter`, Grafana provisioning, the vhost and units to `/var/backups/prometheus-azure-sync/<ts>`
  3. validate: `promtool check config`, blackbox `--config.check`, YAML parse of provisioning, `check-targets.py`, `nginx -t`
  4. apply
  5. reload: Prometheus `/-/reload`, blackbox `/-/reload`, nginx reload, and Grafana provisioning by restart or the admin reload API (settled on the test rig)
  6. verify
  7. roll back automatically on failure

  `--restore` undoes the last sync.
- **Never touched by sync:** `grafana.ini` (SMTP password, admin password) and the customer target folder.

## Steps

Each step is committed and tested before the next. The repo is personal, so steps push straight to `main` until it moves to the org.

1. **Scaffold.** *Done 18 Nov 2026.* `.gitignore` (captures, test binaries), README, this plan, the original build in `source-material/monitoring`, and the capture tools. Push.
2. **Baseline.** *Done 18 Nov 2026: 10 files plus `sync-manifest.conf` (server path, owner and mode as live). `tests/compare-capture.sh` matched all 10 byte for byte against the capture.* Put the live system files into the repo layout exactly as running: `prometheus.yml`, provisioning, `blackbox.yml`, the vhost and the units. Test: byte-compare against the capture. That makes every later change a readable diff against what runs today.
3. **Test rig.** A WSL Ubuntu 24.04 distro, `monitoring-synctest`, with the same binaries and Grafana .deb as the VM. It has:
   - a local blackbox target that can be switched between up, slow and down
   - fake node targets
   - an SMTP sink that saves every email Grafana sends

   Scripted in `tests/` so it can be rebuilt. Test: the baseline config runs and reproduces today's `[no value]` email.
4. **Customer files (issue 2).** New `prometheus.yml`, the infrastructure and external target files, the template, `check-targets.py` and the migration script. Tests on the rig:
   - target labels identical before and after the migration, apart from the postgres `vm` label
   - a new file is picked up without a reload, and a deleted file drops its targets
   - a broken file is caught by the checker, and Prometheus keeps running
5. **Alert rules and templates (issues 1 and 3).** Rules, templates, contact points and policies. Tests on the rig:
   - one alert per failing target, with the right labels
   - the subjects and bodies captured by the SMTP sink match the examples above
   - external down, degraded and slow behave as designed with the test target switched
   - the degraded alert reaches email only
6. **Deployment tooling.** `sync.sh`, `verify.sh`, `remove-customer.sh`, the deploy key and clone scripts. Test on the rig: dry run, apply, a deliberately broken change that rolls itself back, and `--restore`.
7. **Runbook** for the change window, with rollback. Steve reviews it.
8. **Change window (Steve).**
   1. Pre-change restore point (`Invoke-PreChangeBackup.ps1` from the nginx repo).
   2. Deploy key, clone.
   3. Run the migration, then `sync.sh`, then `verify.sh`.
   4. Contact point test, and a real test alert through to SMS.
9. **Close-out.** Mode 6 KB guides: updating the monitoring VM, adding and removing a customer. Then move the repo to the org.

## Follow-ups, not in this change

- Bring 1streamcx, flash, amathuba and CX-QA under monitoring: exporters on their VMs, then one customer file each.
- What runs on the scripts server around 23:00 that stalls TLS handshakes.
- The 5s DNS retries on the monitoring VM.
- The dashboards. Grafana 13 keeps them in its unified storage, so the capture didn't get them. Export the live ones through the API and keep them in `grafana/dashboards/`.
- HighSystemLoad uses a fixed 4.0 rather than a per-VM CPU count.
- Prometheus and blackbox_exporter are upstream tarballs, not apt packages.

Resolved since the investigation: uc's Let's Encrypt renewal now runs outside the SSL alert window (Steve, 18 Nov 2026).
