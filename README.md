# Infrastructure-prometheus-azure

Configuration for the Azure monitoring VM, Monitoring-VM-001 (`10.0.0.6`, RG_INFRASTRUCTURE). It runs Prometheus, blackbox_exporter, Grafana with Grafana-managed alerting, and nginx in front of Grafana. Users reach Grafana at https://prometheus.1stream.co.za through the nginx pair CX-Nginx-VM-001/002.

GitHub is the source of truth for everything on the VM except:

- the customer target files in `/etc/prometheus/targets/customers/`, which the team adds and removes on the VM
- `grafana.ini`, which holds the SMTP and admin passwords

Work in progress. See [PLAN.md](PLAN.md) for the current state and the steps left.

## Related

- The LB vhost for `prometheus.1stream.co.za` and the nginx exporter on CX-Nginx-VM-001/002 belong to `1Stream/Infrastructure-Azure-Nginx`.
- `source-material/monitoring/` is the original June 2026 build, kept for reference. It is not deployed.

## Read-only capture of the VM

`tools/node-capture/Invoke-NodeCapture.ps1` takes a snapshot of the VM through an Azure Run Command, with no SSH, without changing anything on it, and with secrets redacted:

```
pwsh -NoProfile -File tools\node-capture\Invoke-NodeCapture.ps1 -ResourceGroup RG_INFRASTRUCTURE -VmName Monitoring-VM-001 -StorageAccount 1streaminfrafiles
```

The storage account only accepts the office IP, so run it from the office or add your IP to `1streaminfrafiles` for the duration. Captures land in `source-material/node-capture-<date>/` and are never committed.
