# 1Stream Prometheus + Grafana Deployment Guide

**Stack:** Prometheus 2.51 · Grafana OSS 11.6 · nginx reverse proxy · fail2ban · Ubuntu 24.04
**URL:** `https://prometheus.1stream.co.za`
**Notifications:** Email via Office 365 SMTP · SMS via Grapevine email-to-SMS gateway
**Targets:** nginx LB VMs, Odoo VMs, Postgres VMs
**Retention:** 365 days (`--storage.tsdb.retention.time=365d`)

---

## Architecture Overview

```
   Browser → https://prometheus.1stream.co.za
                        │
               ┌────────┴────────┐
               │  VM1/VM2 LBs    │   ← SSL terminates here (wildcard cert)
               │  nginx vhost    │   ← geo-block, bot filter, rate limit
               └────────┬────────┘
                        │ proxy_pass https://10.0.0.6
                        ▼
               ┌──────────────────────────────┐
               │   Monitoring VM (Standard_B2s)│
               │                              │
               │  nginx         (443 → 3000)   │  ← SSL (wildcard cert), no basic auth
               │  Grafana       (:3000 local)  │  ← Grafana login is the auth layer
               │  Prometheus    (:9090 local)  │
               │  node_exporter (:9100 local)  │
               │  fail2ban                     │
               └──────────────┬───────────────┘
                              │ scrapes (private VNet)
         ┌────────────────────┼────────────────────────────┐
         │                    │                            │
  ┌──────┴──────┐      ┌──────┴──────┐             ┌──────┴──────────┐
  │ VM1 nginx   │      │ VM2 nginx   │             │ Per-customer    │
  │ :9113 nginx │      │ :9113 nginx │             │                 │
  │ :9100 node  │      │ :9100 node  │             │  Odoo VM        │
  └─────────────┘      └─────────────┘             │  :9100 node     │
                                                   │                 │
                                                   │  Postgres VM    │
                                                   │  :9100 node     │
                                                   │  :9187 postgres │
                                                   └─────────────────┘
```

All scraping happens over the Azure VNet (private IPs). Web access flows through the LBs (VM1/VM2), which handle SSL termination, geo-blocking, bot filtering, and rate limiting. The monitoring VM does NOT need a public IP.

---

## Step 1 — Provision the Monitoring VM in Azure Portal

1. Go to **Azure Portal → Virtual Machines → Create**

2. **Basics tab:**
   - Subscription: your subscription
   - Resource Group: same as your other 1SCX VMs
   - VM name: `1scx-monitoring` (or similar)
   - Region: same as your other VMs (critical — must be same VNet)
   - Image: **Ubuntu Server 24.04 LTS**
   - Size: **Standard_B2s** (2 vCPU, 4 GB RAM — sufficient for monitoring)
   - Authentication: SSH public key (use your existing key)
   - Username: `steve`

3. **Disks tab:**
   - OS disk: **P10 Premium SSD (128 GB)** — Prometheus with 365-day retention and ~10 targets needs 50-100 GB. Consider P15 (256 GB) at 30+ targets.

4. **Networking tab:**
   - Virtual network: **same VNet as VM1/VM2 and customer VMs**
   - Subnet: same subnet (or a dedicated monitoring subnet if you prefer)
   - Public IP: **No** — traffic reaches the monitoring VM via the LBs over the private VNet
   - NIC network security group: Basic
   - Inbound: **SSH (22)** from your management IP, **HTTPS (443)** from VM1/VM2 private IPs only

5. Click **Review + Create → Create**

6. **Note down:**
   - Private IP (Azure portal → VM → Networking → Private IP): `__________`
   - Public IP (Azure portal → VM → Overview → Public IP): `__________`

---

## Step 2 — Create DNS Record

In your DNS provider for `1stream.co.za`:

- **Type:** A (or CNAME)
- **Name:** `prometheus`
- **Value:** the **LB public IP** (same IP serving your Odoo sites on VM1/VM2)
- **TTL:** 300 (5 min) — can increase later

Verify: `nslookup prometheus.1stream.co.za` should return the LB public IP.

---

## Step 3 — Prep VM1 and VM2 (nginx LB VMs)

These already have `prometheus-nginx-exporter` from your deploy.sh. This step adds `node_exporter` and opens the UFW rules.

**On each of VM1 and VM2:**

```bash
# Copy the script to the VM
scp setup-exporters.sh steve@<VM1-IP>:~/

# SSH in and run
ssh steve@<VM1-IP>
sudo bash ~/setup-exporters.sh <MONITORING-VM-PRIVATE-IP>
```

Repeat for VM2. You should see all 6 checks PASS on each VM.

---

## Step 4 — Prep Customer VMs

For each customer, you'll run `setup-customer-exporters.sh` on their Odoo and Postgres VMs.

### 4a — Odoo VM (e.g., CUSTOMER-TENANT)

```bash
scp setup-customer-exporters.sh steve@<CUSTOMER-TENANT-ODOO-IP>:~/

ssh steve@<CUSTOMER-TENANT-ODOO-IP>
sudo bash ~/setup-customer-exporters.sh odoo <MONITORING-VM-PRIVATE-IP>
```

Expected result: 2–3 PASS (node_exporter running, :9100 up, and UFW rule if UFW is active). If UFW is not active, the script skips firewall rules and logs a reminder to ensure your Azure NSG allows the monitoring VM through on port 9100.

### 4b — Postgres VM (e.g., CUSTOMER-TENANT)

```bash
scp setup-customer-exporters.sh steve@<CUSTOMER-TENANT-PG-IP>:~/

ssh steve@<CUSTOMER-TENANT-PG-IP>
sudo bash ~/setup-customer-exporters.sh postgres <MONITORING-VM-PRIVATE-IP>
```

Expected result: 4–6 PASS (node_exporter + postgres_exporter running and responding, plus UFW rules if UFW is active). If UFW is not active, the script skips firewall rules — ensure your Azure NSG allows the monitoring VM through on ports 9100 and 9187.

**Important:** The script auto-generates a password for the `prometheus` Postgres user and prints it at the end. You don't need to save it anywhere — the exporter stores it locally in `/etc/default/postgres_exporter`. But note it down in case you need to troubleshoot.

### Adding more customers later

Repeat 4a and 4b for each new customer's VMs, then add their scrape jobs to `prometheus.yml` using the template at the bottom of that file (see Step 6b).

---

## Step 5 — Copy Wildcard Certificate to Monitoring VM

The monitoring VM needs the same wildcard cert used by VM1/VM2 for its local nginx (LBs proxy to it over HTTPS).

```bash
# From VM1:
scp /etc/nginx/ssl/star.1stream.co.za.crt steve@<MONITORING-VM-PRIVATE-IP>:/tmp/
scp /etc/nginx/ssl/star.1stream.co.za.key steve@<MONITORING-VM-PRIVATE-IP>:/tmp/

# SSH into the monitoring VM:
ssh steve@<MONITORING-VM-PRIVATE-IP>
sudo mkdir -p /etc/nginx/ssl
sudo mv /tmp/star.1stream.co.za.crt /etc/nginx/ssl/
sudo mv /tmp/star.1stream.co.za.key /etc/nginx/ssl/
sudo chmod 600 /etc/nginx/ssl/star.1stream.co.za.key
```

---

## Step 6 — Deploy the Monitoring VM

### 6a — Fill in the CONFIG variables

Edit `setup-monitoring-vm.sh` and replace every placeholder in the CONFIG block at the top:

| Variable | What it is | Example |
|----------|-----------|---------|
| `VM1_IP` | VM1 private VNet IP | `10.0.0.4` |
| `VM2_IP` | VM2 private VNet IP | `10.0.0.5` |
| `SMTP_FROM` | M365 mailbox sending alerts | `alerts@1stream.co.za` |
| `SMTP_USER` | Usually same as SMTP_FROM | `alerts@1stream.co.za` |
| `SMTP_PASSWORD` | M365 account or app password | *(your password)* |
| `ALERT_TO` | Where alerts go | `alerts@1stream.co.za` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana UI admin password | *(strong password)* |
| `CUSTOMER-TENANT_ODOO_IP` | CUSTOMER-TENANT Odoo VM private IP | `10.0.0.10` |
| `CUSTOMER-TENANT_PG_IP` | CUSTOMER-TENANT Postgres VM private IP | `10.0.0.11` |

### 6b — Adding more customers to prometheus.yml

Before running the script, if you have more customers beyond CUSTOMER-TENANT, open `prometheus.yml` and copy the template block at the bottom for each one. Replace `<CUSTOMER>`, `<CUSTOMER-ODOO-IP>`, and `<CUSTOMER-PG-IP>`. Then add matching variables to `setup-monitoring-vm.sh`'s CONFIG block and sed substitutions.

### 6c — Copy everything to the monitoring VM and run

```bash
# From your local machine, copy the entire monitoring folder:
scp -r monitoring/ steve@<MONITORING-VM-PUBLIC-IP>:~/monitoring/

# SSH in:
ssh steve@<MONITORING-VM-PUBLIC-IP>

# Run the setup script:
sudo bash ~/monitoring/setup-monitoring-vm.sh
```

The script will:
1. Update system packages
2. Install Prometheus 2.51 (365-day retention, lifecycle API, admin API enabled)
3. Install Grafana OSS 13.0.1 via direct `.deb` download (bypasses `apt.grafana.com` which is unreachable from some Azure IPs)
4. Write the Prometheus config with all scrape targets
5. Configure Grafana with M365 SMTP, provisioned datasource, and alert rules
6. Install nginx as HTTPS reverse proxy (no basic auth — Grafana login is the auth layer)
7. Configure fail2ban to block brute-force attempts
8. Set up UFW (only SSH, HTTP, HTTPS open)
9. Run smoke tests

You should see **7 PASS, 0 FAIL**. The script will then print the Grafana URL and login credentials.

---

## Step 7 — Deploy LB Vhost on VM1 and VM2

Deploy `prometheus.1stream.co.za.conf` to each LB so they can proxy traffic to the monitoring VM.

**On each of VM1 and VM2:**

```bash
# Copy the vhost config
scp prometheus.1stream.co.za.conf steve@<VM1-IP>:~/

ssh steve@<VM1-IP>
sudo cp ~/prometheus.1stream.co.za.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/prometheus.1stream.co.za.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo nginx -s reload
```

Repeat for VM2.

> **Note:** If you already have a WebSocket upgrade `map` in `nginx.conf`, remove the `map $http_upgrade $grafana_connection_upgrade` block from this vhost to avoid a duplicate directive error. If you also see `variables_hash` warnings, add to the `http` block in `nginx.conf`:
> ```nginx
> variables_hash_max_size 2048;
> variables_hash_bucket_size 128;
> ```

---

## Step 8 — Verify Access

### 8a — Grafana UI

1. Open `https://prometheus.1stream.co.za` in your browser
2. You should see the **Grafana login page** directly (no basic auth prompt)
3. Log in with `admin` / the `GRAFANA_ADMIN_PASSWORD` you set
4. To reset the admin password: `grafana-cli admin reset-admin-password <new-password>` (on the monitoring VM)

### 8b — Check Prometheus Targets

In Grafana:
1. Go to **Explore** (compass icon)
2. Select **Prometheus** datasource
3. Run the query: `up`
4. Every target should show `1`. If any show `0`, check:
   - UFW rules on the target VM (`sudo ufw status`)
   - The exporter is running on the target (`systemctl status prometheus-node-exporter`)
   - The private IP in `prometheus.yml` is correct

### 8c — Test Email Alerts

1. In Grafana: **Alerting → Contact points**
2. Find `email-oncall` → click **Test**
3. Confirm you receive the test email in your inbox

---

## Step 9 — Import Grafana Dashboards

### 9a — Node Exporter Full (all VMs)

1. Grafana → **Dashboards → New → Import**
2. Enter dashboard ID: **1860**
3. Click **Load**
4. Select **Prometheus** as the data source
5. Click **Import**

This gives you CPU, memory, disk, network, and system load for every VM with a node_exporter.

### 9b — nginx Prometheus Exporter (VM1/VM2)

1. Grafana → **Dashboards → New → Import**
2. Enter dashboard ID: **12708**
3. Click **Load**
4. Select **Prometheus** as the data source
5. Click **Import**

This gives you active connections, request rates, and response codes for your nginx LBs.

### 9c — PostgreSQL Dashboard

1. Grafana → **Dashboards → New → Import**
2. Enter dashboard ID: **9628**
3. Click **Load**
4. Select **Prometheus** as the data source
5. Click **Import**

This gives you connection counts, transaction rates, cache hit ratios, and table/index stats.

### 9d — Blackbox Exporter (HTTP response times)

1. Grafana → **Dashboards → New → Import**
2. Enter dashboard ID: **7587**
3. Click **Load**
4. Select **Prometheus** as the data source
5. Click **Import**

This gives you HTTP response times, probe success/failure, SSL cert expiry, and DNS/connect/TLS/transfer time breakdown for each customer's Odoo URL.

### 9e — Set Up a Customer Variable (optional but recommended)

To filter any dashboard by customer:

1. Open a dashboard → **Settings** (gear icon) → **Variables**
2. Add variable:
   - Name: `customer`
   - Type: Query
   - Data source: Prometheus
   - Query: `label_values(up, customer)`
   - Multi-value: Yes
   - Include All: Yes
3. Save
4. Edit panels to filter by `customer=~"$customer"`

---

## Step 10 — Verify Alert Rules

1. Grafana → **Alerting → Alert rules**
2. You should see rules in the "1Stream Alerts" folder:

| Rule | Severity | Fires when |
|------|----------|-----------|
| NginxDown | critical | nginx_up == 0 for 1 min |
| ExporterDown | warning | nginx exporter unreachable for 2 min |
| HighActiveConnections | warning | active conns > 400 for 5 min |
| HighCPU | warning | CPU > 85% for 5 min |
| LowMemory | warning | available RAM < 10% for 5 min |
| LowDisk | warning | root partition < 20% free for 5 min |
| HighSystemLoad | warning | load1 > 4.0 for 5 min |
| PostgresDown | critical | postgres_exporter unreachable for 2 min |
| HighPgConnections | warning | connections > 80% max for 5 min |
| LongRunningTransaction | warning | TX open > 5 min |
| PgDeadlocks | warning | deadlock rate > 0 for 5 min |
| OdooVmDown | critical | Odoo VM node_exporter unreachable for 2 min |
| SiteDown | critical | HTTP probe failing for 2 min |
| SlowResponse | warning | response time > 5s for 5 min |
| SSLCertExpiringSoon | warning | SSL cert expires within 14 days |

All rules should show **Normal** (green) if everything is healthy.

---

## Step 11 — Security Checklist

Confirm these are in place before considering the deployment complete:

**LBs (VM1/VM2):**
- [ ] **HTTPS only** — HTTP redirects to HTTPS (test: `curl -I http://prometheus.1stream.co.za`)
- [ ] **Geo-blocking** — requests from outside South Africa return 403
- [ ] **Bot blocking** — known AI scrapers and bad bots return 403
- [ ] **Rate limiting** — login endpoint limited to 5 req/min, general limited to 30 req/s
- [ ] **Security headers** — test with `curl -I https://prometheus.1stream.co.za` (HSTS, X-Frame-Options: DENY, CSP, etc.)
- [ ] **Server tokens hidden** — response headers should NOT show nginx version
- [ ] **TLS 1.2+ only** — `nmap --script ssl-enum-ciphers -p 443 prometheus.1stream.co.za`
- [ ] **No sensitive paths exposed** — `curl https://prometheus.1stream.co.za/.env` returns 404

**Monitoring VM:**
- [ ] **No public IP** — only reachable via LBs and VNet
- [ ] **NSG** — inbound restricted to SSH (management IP) + HTTPS (VM1/VM2 IPs) + exporter ports (VNet only)
- [ ] **Grafana sign-up disabled** — `allow_sign_up = false` in grafana.ini
- [ ] **No basic auth on nginx** — Grafana login is the auth layer
- [ ] **Prometheus bound to localhost** — `--web.listen-address=127.0.0.1:9090` (not accessible from internet)
- [ ] **UFW active** — only ports 22, 80, 443 open (`sudo ufw status`)
- [ ] **fail2ban running** — `sudo systemctl status fail2ban` is active

---

## Adding a New Customer Later

When onboarding a new customer (e.g., `acme`):

**1. On the customer's Odoo VM:**
```bash
sudo bash setup-customer-exporters.sh odoo <MONITORING-VM-PRIVATE-IP>
```

**2. On the customer's Postgres VM:**
```bash
sudo bash setup-customer-exporters.sh postgres <MONITORING-VM-PRIVATE-IP>
```

**3. On the monitoring VM — add scrape jobs:**

Edit `/etc/prometheus/prometheus.yml` and add (copy from the template block):
```yaml
  - job_name: 'node-acme-odoo'
    static_configs:
      - targets: ['<ACME-ODOO-IP>:9100']
        labels:
          vm:       'acme-odoo'
          role:     'odoo'
          customer: 'acme'

  - job_name: 'node-acme-pg'
    static_configs:
      - targets: ['<ACME-PG-IP>:9100']
        labels:
          vm:       'acme-pg'
          role:     'postgres'
          customer: 'acme'

  - job_name: 'postgres-acme'
    static_configs:
      - targets: ['<ACME-PG-IP>:9187']
        labels:
          vm:       'acme-pg'
          role:     'postgres'
          customer: 'acme'
```

** Verify yml formatting - Indentation is very important to yml files

promtool check config /etc/prometheus/prometheus.yml

**4. Reload Prometheus (no restart needed):**
```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

**5. Verify in Grafana:** run `up` query — new targets should appear.

---

## Removing a Customer

When offboarding a customer (e.g., `acme`):

**1. Remove scrape jobs from Prometheus:**
```bash
sudo nano /etc/prometheus/prometheus.yml
# Delete the 3 job blocks: node-acme-odoo, node-acme-pg, postgres-acme
```

**2. Reload config and delete historical data:**
```bash
curl -X POST http://127.0.0.1:9090/-/reload
curl -X POST 'http://127.0.0.1:9090/api/v1/admin/tsdb/delete_series' \
  --data-urlencode 'match[]={customer="acme"}'
curl -X POST http://127.0.0.1:9090/api/v1/admin/tsdb/clean_tombstones
```

**3. Clean up customer VMs** (skip if VMs are being decommissioned):
```bash
# On the Odoo VM:
sudo ufw delete allow from <MONITORING-IP> to any port 9100
sudo apt-get remove --purge prometheus-node-exporter

# On the Postgres VM:
sudo ufw delete allow from <MONITORING-IP> to any port 9100
sudo ufw delete allow from <MONITORING-IP> to any port 9187
sudo systemctl stop postgres_exporter && sudo systemctl disable postgres_exporter
sudo rm /etc/systemd/system/postgres_exporter.service /etc/default/postgres_exporter
sudo rm /usr/local/bin/postgres_exporter
sudo userdel postgres_exporter
sudo systemctl daemon-reload
sudo apt-get remove --purge prometheus-node-exporter
sudo -u postgres psql -c "DROP USER prometheus;"
```

> **Note:** `--web.enable-admin-api` must be set on the Prometheus service for the delete/clean_tombstones commands to work. This is included in the setup script.

---

## SMS Notifications via Email-to-SMS Gateway

Grafana can send SMS alerts by emailing a gateway provider (same approach as Nagios). The provider receives the email and delivers it as an SMS.

### Grapevine (vine.co.za) Gateway

Grapevine provides two email-to-SMS addresses per account:

| Type | Email format | Use |
|------|-------------|-----|
| Subject mode | `<number>@sms5.vine.co.za` | SMS body = email **subject** line |
| Body mode | `<number>@sms2.vine.co.za` | SMS body = email **body** |

Where `<number>` is the full cellphone number (e.g., `0821234567`).

**Recommended:** Use **subject mode** (`sms5.vine.co.za`) — Grafana alert subjects are concise and fit well in an SMS. Body mode may truncate or include HTML formatting.

### Setting up SMS contact points in Grafana

1. Go to **Alerting → Contact points → Add contact point**
2. Name: `sms-steve` (or whoever)
3. Type: **Email**
4. Addresses: `0821234567@sms5.vine.co.za` (replace with actual cell number)
5. Click **Save**

To send alerts to both email AND SMS, either:
- **Option A — Multiple receivers in one contact point:** Add both the email address and the SMS gateway address in the same Email contact point (comma-separated)
- **Option B — Separate contact points with notification policy:** Create separate `email-oncall` and `sms-oncall` contact points, then in **Alerting → Notification policies**, route critical alerts to both

### Recommended notification policy

| Severity | Notify |
|----------|--------|
| `critical` | Email + SMS |
| `warning` | Email only |

To configure this:
1. **Alerting → Notification policies**
2. Set default contact point to `email-oncall`
3. Add a nested policy: match label `severity = critical` → contact point `sms-oncall`
4. On the nested policy, check **Continue matching subsequent sibling nodes** so the default email policy also fires

### Testing
1. **Alerting → Contact points** → find `sms-oncall` → click **Test**
2. You should receive an SMS within a few seconds
3. If it doesn't arrive, check that the Grapevine account is active and the M365 mailbox can send to external addresses

---

## Troubleshooting

**Target shows DOWN in Prometheus:**
- Check UFW on the target VM: `sudo ufw status | grep 9100`
- Check exporter is running: `systemctl status prometheus-node-exporter`
- Test from monitoring VM: `curl http://<TARGET-IP>:9100/metrics`
- Verify IPs are on the same VNet

**No alert emails:**
- Grafana → Alerting → Contact points → Test the email-oncall contact point
- Check Grafana logs: `sudo journalctl -u grafana-server -f | grep smtp`
- Verify SMTP credentials are correct and the M365 account has SMTP AUTH enabled
- Check if M365 blocks the sending: Entra ID → Users → the mailbox → Mail → check for blocks

**Prometheus won't start:**
- Check config syntax: `promtool check config /etc/prometheus/prometheus.yml`
- Check logs: `sudo journalctl -u prometheus -f`

**Grafana shows "No data":**
- Ensure Prometheus datasource URL is `http://localhost:9090` (not https, not 127.0.0.1)
- Test: `curl http://localhost:9090/api/v1/query?query=up`

**fail2ban banning your own IP:**
- Unban: `sudo fail2ban-client set nginx-http-auth unbanip <YOUR-IP>`
- Check banned IPs: `sudo fail2ban-client status nginx-http-auth`

---

## File Inventory

All files in the `monitoring/` folder:

| File | Run where | Purpose |
|------|-----------|---------|
| `setup-monitoring-vm.sh` | Monitoring VM | Full install: Prometheus, Grafana (.deb), Blackbox Exporter, nginx, fail2ban, UFW |
| `setup-exporters.sh` | VM1, VM2 | Installs node_exporter, opens UFW for nginx LB VMs |
| `setup-customer-exporters.sh` | Customer VMs | Installs exporters on Odoo/Postgres VMs (UFW-optional) |
| `prometheus.yml` | (deployed by setup script) | Prometheus scrape configuration |
| `nginx-grafana.conf` | (deployed by setup script) | Monitoring VM nginx vhost (no basic auth) |
| `prometheus.1stream.co.za.conf` | VM1, VM2 | LB nginx vhost for Grafana (geo-block, bot filter, rate limit) |
| `provisioning/datasources/prometheus.yml` | (deployed by setup script) | Grafana datasource auto-config |
| `provisioning/alerting/contactpoints.yml` | (deployed by setup script) | M365 email contact point |
| `provisioning/alerting/policies.yml` | (deployed by setup script) | Alert routing policy |
| `provisioning/alerting/rules.yml` | (deployed by setup script) | 15 alert rules |
| `upgrade-grafana.sh` | Monitoring VM | Upgrade Grafana OSS via .deb download |
| `remove-customer.sh` | Monitoring VM | Full customer offboarding (scrape jobs + data cleanup) |
