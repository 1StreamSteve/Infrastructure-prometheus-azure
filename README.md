# Infrastructure-prometheus-azure

Configuration for the Azure monitoring VM, Monitoring-VM-001 (`10.0.0.6`, RG_INFRASTRUCTURE). It runs Prometheus, blackbox_exporter, Grafana with Grafana-managed alerting, and nginx in front of Grafana. Users reach Grafana at https://prometheus.1stream.co.za through the nginx pair CX-Nginx-VM-001/002.

GitHub is the source of truth for everything on the VM except:

- the customer target files in `/etc/prometheus/targets/customers/`, which the team adds and removes on the VM
- `grafana.ini`, which holds the SMTP and admin passwords

Status and history are in [PLAN.md](PLAN.md).

## Layout

| Path | What it is | On the VM |
|---|---|---|
| `prometheus/prometheus.yml` | Scrape config; targets come from files | `/etc/prometheus/` |
| `prometheus/targets/infrastructure.yml` | Monitoring VM and the nginx pair | `/etc/prometheus/targets/` |
| `prometheus/targets/external.yml` | External HTTPS probes (uc, scripts) | `/etc/prometheus/targets/` |
| `prometheus/targets/customer.yml.example` | Template for a customer file | `/etc/prometheus/targets/` |
| `blackbox/blackbox.yml` | Probe modules | `/etc/blackbox_exporter/` |
| `grafana/provisioning/` | Alert rules, notification templates, contact points, routing, datasource | `/etc/grafana/provisioning/` |
| `nginx/`, `systemd/`, `fail2ban/` | The VM's vhost, unit files and jail | as in `sync-manifest.conf` |
| `sync-manifest.conf` | Every git-managed file, its server path, owner, mode | |
| `sync.sh`, `verify.sh` | Apply git to the VM; read-only health check | run from `/opt/prometheus-azure-build` |
| `tools/` | Target and rule checkers, remove-customer, capture, deploy key and clone | |
| `exporters/setup-customer-exporters.sh` | Run on a customer's Odoo and Postgres VMs | |
| `tests/` | WSL test rig and the scenario tests behind every change | |
| `source-material/monitoring/` | The original June 2026 build, for reference only | |

The LB vhost for `prometheus.1stream.co.za` and the nginx exporter on CX-Nginx-VM-001/002 belong to `1Stream/Infrastructure-Azure-Nginx`.

## Changing the system files

The repo is cloned on the VM at `/opt/prometheus-azure-build` with a read-only deploy key (`tools/node-git/`). On the VM, in a `screen` session:

```bash
cd /opt/prometheus-azure-build && sudo git pull
sudo bash sync.sh            # dry run: shows every change as a diff
sudo bash sync.sh --apply    # validate, apply, check, roll back by itself on failure
sudo bash verify.sh
```

`sync.sh --list-backups`, `--restore <dir>` and `--restore-full <tgz>` undo a sync.

## Adding or removing a customer

Customers are files on the VM, not in git. Copy the template, fill it in, check it:

```bash
sudo cp /etc/prometheus/targets/customer.yml.example /etc/prometheus/targets/customers/acme-v2.yml
sudo nano /etc/prometheus/targets/customers/acme-v2.yml
python3 /opt/prometheus-azure-build/tools/check-targets.py
```

Prometheus picks the file up within seconds, with no reload. To remove a customer and its history:

```bash
sudo bash /opt/prometheus-azure-build/tools/remove-customer.sh acme-v2
```

## Testing a change before it goes near the VM

`tests/rig/New-TestRig.ps1` builds a WSL distro, `monitoring-synctest`, with the same Prometheus, blackbox and Grafana versions. The production addresses are faked on loopback and an SMTP sink keeps every alert email. The `tests/step*.sh` scripts run the scenarios. `tests/rig/Remove-TestRig.ps1` stops the rig.

## Read-only capture of the VM

`tools/node-capture/Invoke-NodeCapture.ps1` takes a snapshot of the VM through an Azure Run Command, with no SSH, without changing anything on it, and with secrets redacted:

```
pwsh -NoProfile -File tools\node-capture\Invoke-NodeCapture.ps1 -ResourceGroup RG_INFRASTRUCTURE -VmName Monitoring-VM-001 -StorageAccount 1streaminfrafiles
```

The storage account only accepts the office IP, so run it from the office or add your IP to `1streaminfrafiles` for the duration. Captures land in `source-material/node-capture-<date>/` and are never committed.
