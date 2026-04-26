# Promtail

Source-controlled artifacts for the Loki log shipper on every lab VM.

## Deployed on

Every VM, as a systemd binary running as root. Listens on `127.0.0.1:9080` for the readiness check and ships logs outbound to Loki at `192.168.100.208:3100/loki/api/v1/push`.

## What it does

Tails the systemd journal, `/var/log/*` text logs, nginx logs (where they exist), and Docker container logs (where Docker runs), and pushes line-by-line to Loki with structured labels.

## Why root + systemd binary

- journald and `/var/lib/docker/containers/*/*-json.log` need root or specific group access; running as root is the simplest.
- A Docker-based Promtail would need a lot of bind mounts and capabilities and still couldn't read journald cleanly.
- The binary is ~150 MB; small enough not to matter.
- The systemd unit applies hardening (`ProtectKernelTunables`, etc.) so root-on-a-non-malicious-binary is acceptable in this lab.

## Layout

```
services/promtail/
  README.md                  You are here
  promtail-config.yml        One config used on every VM
  install.sh                 Idempotent installer (runs on the VM)
  deploy-all.ps1             PowerShell loop: scp + run install.sh on all 8 VMs
```

The systemd unit is rendered by `install.sh` via heredoc; no separate `.service` file in source.

## Deploy / update

### First-time install across all VMs

From Windows host:

```powershell
C:\vmimages\services\promtail\deploy-all.ps1
```

Walks every VM, scps the config + install script, runs the installer, smoke-tests `:9080/ready`.

### Bumping the version

Edit `PROMTAIL_VERSION` in `install.sh`. Re-run `deploy-all.ps1`. The install script stops + reinstalls cleanly.

### Editing the config

Edit `promtail-config.yml`. Re-run `deploy-all.ps1`. Each VM picks up the new config and Promtail restarts.

## Scrape configs (universal config)

| Job              | Source                                                 | Active when                     |
|------------------|--------------------------------------------------------|---------------------------------|
| systemd-journal  | journald                                               | Always (every VM has systemd)   |
| nginx            | `/var/log/nginx/*.log`                                 | Only on lab-gateway             |
| docker           | `/var/lib/docker/containers/*/*-json.log`              | Only on lab-gateway, lab-datastore, lab-platform-eng |
| varlogs          | `/var/log/{syslog,auth.log,kern.log,dpkg.log,...}`     | Always                          |

Promtail silently no-ops scrape configs whose target paths don't exist, so the same file works on every VM.

## Security notes

- Logs travel in cleartext over the lab subnet to Loki on lab-platform-eng. Acceptable for a single-operator internal lab.
- Promtail runs as root. Hardening flags in the unit (`NoNewPrivileges`, `ProtectKernel*`) reduce the blast radius.
- No auth on the Loki push endpoint. Anyone on the lab subnet can write to Loki. If we ever want stricter, set `auth_enabled: true` in Loki and put a tenant header on Promtail clients.

## Gotchas

- **`config.expand-env=true` requires `Environment=HOSTNAME=%H`** in the systemd unit so `${HOSTNAME}` in the config resolves to the VM hostname (not literal `${HOSTNAME}`). %H is systemd's host-name specifier.
- **Positions file persistence**. `/var/lib/promtail/positions.yaml` records where Promtail left off in each file. Don't delete it on a working VM unless you want to re-ship logs from scratch (they'll get rejected as too old, but Loki will log warnings).
- **journald label cardinality** can explode if many systemd units come and go. The relabel keeps only `unit`, `host`, `level`. If we ever ship an app that creates ephemeral systemd scopes (k3s pods do this), watch the cardinality in Grafana > Explore > Loki > _name + count.
- **Docker log files don't include the container name** by default; only the container ID (12 chars). The `container_id` label in our config is a stable join key against cAdvisor's labels (when we eventually have that working). Today we cross-reference via `docker ps`.
- **k3s nodes** technically have container logs at `/var/lib/docker/containers` only if Docker is installed; k3s uses containerd directly with a different path (`/var/log/pods/*` or `/var/log/containers/*`). On lab-k3s-* the docker scrape config matches nothing; that's fine for now. Add a separate scrape for k3s pod logs when we deploy the first k3s workload.
