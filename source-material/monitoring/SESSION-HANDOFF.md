# Monitoring VM -- Session Handoff
*Last updated: 2026-06-04*

Use this document to resume work in a new chat session.

---

## Project Context

**1Stream Managed Technology Solutions** -- Steve Buckley, CTO
**Product:** 1SCX (Odoo 18 on Azure, multi-tenant)
**Project folder:** `C:\Claude Projects\Azure\monitoring\`
**Naming convention:** Use `CUSTOMER-TENANT` as the generic placeholder in all configs/docs (not stagezero or CXTENANT).

---

## Architecture Decision

**Self-hosted Grafana + Prometheus on a dedicated monitoring VM** -- NOT Grafana Cloud, NOT Azure Managed Grafana. Rationale:
- Keeps everything inside Azure
- Free (no per-metric costs)
- Dedicated VM means monitoring never competes with workloads
- Scales cleanly as more customer VMs are added

**URL:** `https://prometheus.1stream.co.za`
**Access path:** Browser -> VM1/VM2 LBs (SSL, geo-block, bot filter, rate limit) -> Monitoring VM nginx (HTTPS) -> Grafana (:3000)
**Auth:** Grafana login only (no basic auth -- LBs handle perimeter security)
**Retention:** 365 days (`--storage.tsdb.retention.time=365d`)
**Admin API:** Enabled (`--web.enable-admin-api`) for series deletion/customer offboarding

---

## Target Monitoring Architecture

```
   Browser -> https://prometheus.1stream.co.za
                        |
               +--------+--------+
               |  VM1/VM2 LBs    |   <- SSL terminates here (wildcard cert)
               |  nginx vhost    |   <- geo-block, bot filter, rate limit
               +--------+--------+
                        | proxy_pass https://10.0.0.6
                        v
               +------------------------------+
               |   Monitoring VM (Standard_B2s)|
               |                              |
               |  nginx         (443 -> 3000)  |  <- SSL (wildcard cert), no basic auth
               |  Grafana       (:3000 local)  |  <- Grafana login is the auth layer
               |  Prometheus    (:9090 local)  |
               |  node_exporter (:9100 local)  |
               |  blackbox_exp  (:9115 local)  |
               |  fail2ban                     |
               +--------------+---------------+
                              | scrapes (private VNet)
         +--------------------+----------------------------+
         |                    |                            |
  +------+------+      +------+------+             +------+----------+
  | VM1 nginx   |      | VM2 nginx   |             | Per-customer    |
  | :9113 nginx |      | :9113 nginx |             |                 |
  | :9100 node  |      | :9100 node  |             |  Odoo VM        |
  +-------------+      +-------------+             |  :9100 node     |
                                                   |                 |
                                                   |  Postgres VM    |
                                                   |  :9100 node     |
                                                   |  :9187 postgres |
                                                   +-----------------+
```

**Exporters per VM type:**
| VM type | Exporters |
|---------|-----------|
| nginx LB (VM1/VM2) | `prometheus-nginx-exporter` :9113 + `node_exporter` :9100 |
| Monitoring VM | `node_exporter` :9100 + `blackbox_exporter` :9115 (both localhost) |
| Odoo VM (Ubuntu 24) | `node_exporter` :9100 |
| Postgres VM (Ubuntu 24) | `node_exporter` :9100 + `postgres_exporter` :9187 |

---

## Current Live State (as of 2026-06-04)

**Deployed and verified:**
- Monitoring VM: Prometheus, Grafana 13.0.1, nginx, blackbox_exporter, node_exporter, fail2ban
- VM1 + VM2: node_exporter, nginx exporter (both scraping successfully)
- Two customer tenants: stagezero-v2 (10.1.0.x), om-pfdirect-v2 (10.2.0.x)
  - Each has: node_exporter on Odoo VM, node_exporter + postgres_exporter on Postgres VM
  - Blackbox probes on internal Odoo IP:8069 (http_2xx_lenient module)
- External HTTP probes: voice platform, scripts platform (http_2xx module, job prefix `blackbox-ext-`)
- Email alerting via M365 SMTP: working
- SMS alerting: configured but not yet enabled (waiting for alert tuning)

**Grafana dashboards:**
| Dashboard | Source |
|-----------|--------|
| Node Exporter Full | Community ID 1860 |
| nginx Prometheus Exporter | Community ID 12708 |
| PostgreSQL | Community ID 9628 (modified -- see known issues) |
| Customer HTTP Probes | `grafana-blackbox-dashboard.json` (custom, filters by `customer` label) |
| External HTTP Probes | `grafana-external-probes-dashboard.json` (custom, filters by `instance`, job prefix `blackbox-ext-`) |

**Grafana folder:** "CX Monitors" (renamed from "1Stream Alerts")

---

## Files Built

All in `C:\Claude Projects\Azure\monitoring\`:

| File | Status | Purpose |
|------|--------|---------|
| `setup-monitoring-vm.sh` | [DONE] | Full install script (Prometheus, Grafana .deb, Blackbox Exporter, nginx, fail2ban, UFW) |
| `setup-exporters.sh` | [DONE] | Run on VM1/VM2 -- installs node_exporter, opens UFW |
| `setup-customer-exporters.sh` | [DONE] | Run on Odoo/Postgres VMs -- UFW-optional, installs exporters |
| `prometheus.yml` | [DONE] | Scrape config with customer + external probe templates |
| `nginx-grafana.conf` | [DONE] | Monitoring VM nginx vhost (no basic auth) |
| `prometheus.1stream.co.za.conf` | [DONE] | LB nginx vhost (geo-block, bot filter, rate limit, WebSocket) |
| `provisioning/datasources/prometheus.yml` | [DONE] | Auto-wires Prometheus into Grafana |
| `provisioning/alerting/contactpoints.yml` | [DONE] | M365 email contact point |
| `provisioning/alerting/policies.yml` | [DONE] | Alert routing |
| `provisioning/alerting/rules.yml` | [DONE] | 14 alert rules (folder: CX Monitors) |
| `DEPLOYMENT-GUIDE.md` | [DONE] | Step-by-step deployment walkthrough |
| `upgrade-grafana.sh` | [DONE] | Upgrade Grafana OSS via .deb download |
| `remove-customer.sh` | [DONE] | Full customer offboarding (scrape jobs + data cleanup) |
| `install-blackbox-exporter.sh` | [DONE] | Standalone blackbox_exporter install for existing monitoring VM |
| `grafana-blackbox-dashboard.json` | [DONE] | Custom Grafana dashboard for customer blackbox HTTP probes |
| `grafana-external-probes-dashboard.json` | [DONE] | Custom Grafana dashboard for external site HTTP probes |

### Blackbox exporter modules

| Module | Use case |
|--------|----------|
| `http_2xx` | External HTTPS sites (standard HTTP/1.1+ endpoints) |
| `http_2xx_lenient` | Internal Odoo IP:8069 (no HTTP version constraint -- Odoo returns HTTP/1.0) |
| `http_post_2xx` | POST endpoint probing (available, not currently used) |
| `icmp` | Ping probing (available, not currently used) |

### Alert rules (14 total)

**nginx:** NginxDown (critical), ExporterDown (warning), HighActiveConnections (warning)
**OS (all VMs):** HighCPU, LowMemory, LowDisk, HighSystemLoad (all warning)
**Postgres:** PostgresDown (critical), LongRunningTransaction, PgDeadlocks (all warning)
**Odoo:** OdooVmDown (critical)
**Blackbox HTTP:** SiteDown (critical), SlowResponse (warning), SSLCertExpiringSoon (warning)

All rules use `noDataState: OK` -- missing exporters stay quiet instead of firing false alerts.

### Security hardening

**LBs (VM1/VM2):**
- SSL termination with wildcard cert
- Geo-blocking (South Africa only)
- AI scraper and bad bot blocking
- Rate limiting: 5 req/min login, 30 req/s general
- Security headers: CSP, HSTS, X-Frame-Options DENY, no server tokens
- WebSocket upgrade map for Grafana Live

**Monitoring VM:**
- No public IP -- only reachable via LBs and VNet
- NSG: SSH (management IP) + HTTPS (VM1/VM2 IPs) + exporter ports (VNet only)
- nginx proxies HTTPS (443) -> Grafana (:3000), no basic auth
- Grafana login is the auth layer (sign-up disabled)
- Prometheus bound to 127.0.0.1:9090 only
- fail2ban on nginx-limit-req
- UFW: only 22, 80, 443

### Notifications
- **Email:** M365 SMTP (smtp.office365.com:587) -- working
- **SMS:** Grapevine email-to-SMS gateway (vine.co.za) -- not yet enabled
  - Subject mode: `<number>@sms5.vine.co.za` (recommended)
  - Body mode: `<number>@sms2.vine.co.za`

### Key Prometheus flags
```
--storage.tsdb.retention.time=365d
--web.listen-address=127.0.0.1:9090
--web.enable-lifecycle
--web.enable-admin-api
```

### Known issues
- `apt.grafana.com` is unreachable from Azure IPs (Fastly CDN blocks). Script uses direct `.deb` download from `dl.grafana.com` instead.
- `postgres_exporter` needs `--no-collector.stat_bgwriter` for PG17 compatibility (baked into setup-customer-exporters.sh).
- `setup-customer-exporters.sh` is UFW-optional -- skips firewall rules if UFW is not active, logs a reminder to check Azure NSG.
- Blackbox probes target internal Odoo IP:8069 (not public URL) -- LB geo-blocking blocks the exporter. Uses `http_2xx_lenient` module because Odoo returns HTTP/1.0 which the strict `http_2xx` module rejects.
- Custom Grafana dashboards used instead of community 7587 -- 7587 expects specific variable names that don't match our setup.
- PG17 removed `pg_stat_bgwriter` view -- checkpoint write/sync panels on PostgreSQL dashboard (9628) have no data. Delete those panels.
- `process_virtual_memory_bytes` is a gauge -- community dashboard 9628 wraps it in `rate()` which returns 0. Fix: use raw metric with no `rate()`.
- Grafana provisioned alert rules get overridden once edited in UI -- must clear `alert_rule` table in grafana.db to force re-read from file: `sqlite3 /var/lib/grafana/grafana.db "DELETE FROM alert_rule; DELETE FROM alert_rule_version;"`
- All alert rules use `noDataState: OK` so missing exporters don't trigger false alerts.
- Grafana folder renamed from "1Stream Alerts" to "CX Monitors".
- Pasting YAML via bastion sessions mangles indentation -- use heredoc (`cat >> file << 'EOF'`) or scp instead of editor paste.
- Phantom alert emails can persist after deleting/fixing alert rules because Grafana's internal alertmanager stores notification state on disk in `/var/lib/grafana/alerting/`. Clearing the DB tables alone is not enough. Full fix: stop Grafana, `DELETE FROM alert_instance; DELETE FROM alert_configuration_history;`, `rm -rf /var/lib/grafana/alerting/*`, start Grafana.
- HighPgConnections alert rule was removed entirely -- 2000 max_connections with 15 workers/tenant makes 80% threshold impractical, and Grafana's alert evaluator intermittently fails on `group_left` queries.

---

## Placeholders to Fill Before Deploying

In `setup-monitoring-vm.sh` CONFIG block:

| Placeholder | What it is |
|-------------|-----------|
| `VM1_IP` | VM1 private VNet IP |
| `VM2_IP` | VM2 private VNet IP |
| `SMTP_FROM` | M365 mailbox that sends alerts |
| `SMTP_USER` | Usually same as SMTP_FROM |
| `SMTP_PASSWORD` | M365 password or app password |
| `ALERT_TO` | Where alerts go |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin UI password |
| `CUSTOMER_TENANT_ODOO_IP` | CUSTOMER-TENANT Odoo VM private IP (also used as blackbox probe target) |
| `CUSTOMER_TENANT_PG_IP` | CUSTOMER-TENANT Postgres VM private IP |

---

## Deployment Sequence

See `DEPLOYMENT-GUIDE.md` for the full walkthrough. Summary:

1. Provision monitoring VM in Azure (Standard_B2s, P10 128 GB disk, Ubuntu 24.04, same VNet, no public IP)
2. DNS A record: `prometheus.1stream.co.za` -> LB public IP
3. `setup-exporters.sh` on VM1 and VM2
4. `setup-customer-exporters.sh odoo` on each Odoo VM
5. `setup-customer-exporters.sh postgres` on each Postgres VM
6. Copy wildcard cert from VM1 to monitoring VM
7. Fill CONFIG vars, scp, run `setup-monitoring-vm.sh`
8. Deploy `prometheus.1stream.co.za.conf` to VM1 and VM2
9. Import dashboards: 1860 (Node), 12708 (nginx), 9628 (PostgreSQL)
10. Import custom dashboards: `grafana-blackbox-dashboard.json`, `grafana-external-probes-dashboard.json`
11. Fix PG dashboard: delete bgwriter panels, fix `process_virtual_memory_bytes` query
12. Test email/SMS alerts + security checklist

---

## Customer Lifecycle

### Adding a new customer
1. Run `setup-customer-exporters.sh` on their VMs
2. Add scrape jobs + blackbox probe to `/etc/prometheus/prometheus.yml` (templates at bottom of file)
   - Use `http_2xx_lenient` module, target `http://<ODOO-IP>:8069`
3. Reload: `curl -X POST http://127.0.0.1:9090/-/reload`

### Adding an external probe
1. Copy the external probe template from `prometheus.yml`
2. Use `http_2xx` module, job prefix `blackbox-ext-`, `category: 'external'` label
3. Reload Prometheus

### Removing a customer
```bash
sudo bash remove-customer.sh <customer-label>
```
Or manually: see DEPLOYMENT-GUIDE.md -> "Removing a Customer"

### Resetting Grafana alert rules from file
```bash
sudo systemctl stop grafana-server
sudo sqlite3 /var/lib/grafana/grafana.db "DELETE FROM alert_rule; DELETE FROM alert_rule_version;"
sudo systemctl start grafana-server
```

### Clearing stale alert notifications (phantom emails)
```bash
sudo systemctl stop grafana-server
sudo sqlite3 /var/lib/grafana/grafana.db "DELETE FROM alert_instance; DELETE FROM alert_configuration_history;"
sudo rm -rf /var/lib/grafana/alerting/*
sudo systemctl start grafana-server
```

### Wiping Prometheus TSDB (fresh start)
```bash
sudo systemctl stop prometheus
sudo rm -rf /data/prometheus/*
sudo systemctl start prometheus
sudo systemctl restart grafana-server
```

---

## nginx-azure Stack Context

See `C:\Claude Projects\nginx-azure\SESSION-HANDOFF.md` for full context.
- VM1 and VM2 both deployed and verified
- nginx exporter on both VMs
- Wildcard cert: `/etc/nginx/ssl/star.1stream.co.za.crt` + `.key`
- Odoo backend: `10.0.0.10` (ports 8069 + 8072)

---

## Future Recommendations (not yet implemented)

- Probe Odoo `/web/health` endpoint (v18) for true app health, not just HTTP 200
- `azure-metrics-exporter` for Azure LB metrics (backend health, SNAT exhaustion)
- `PrometheusTargetDown` alert rule: `up == 0` for any scrape target
- Disk I/O saturation alert: `rate(node_disk_io_time_seconds_total)`
- Recording rules for rolling availability: `avg_over_time(probe_success[5m])`
- Backup monitoring via node_exporter textfile_collector
- SMS alerting via Grapevine once email alerts are tuned
