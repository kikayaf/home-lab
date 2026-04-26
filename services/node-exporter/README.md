# node_exporter

Source-controlled artifacts for the host-level metrics agent on every lab VM.

## Deployed on

Every VM (`lab-gateway`, `lab-k3s-controlplane`, `lab-k3s-node01`, `lab-k3s-node02`, `lab-datastore`, `lab-ai-ops`, `lab-automation`, `lab-platform-eng`) as a systemd service. Listens on `:9100`. No Docker container; binary install via the official release tarball.

## What it does

Exposes the standard host metrics on a Prometheus-scrapeable endpoint at `http://<host>:9100/metrics`. CPU, memory, disk, network, load, filesystems, mounts, systemd unit states, processes. The Prometheus instance on `lab-platform-eng` scrapes each one (see [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml)).

## Why a binary, not Docker

- It's host metrics. Running it inside a Docker container makes it harder to see the actual host's filesystem and processes (you have to bind-mount `/proc`, `/sys`, `/`, etc.).
- The binary is ~20 MB, single static Go binary. No dependencies.
- The systemd unit isolates it (`ProtectSystem=strict`, `NoNewPrivileges`, etc.).

## Layout

```
services/node-exporter/
  README.md                         You are here
  install.sh                        Idempotent install script (runs on the VM)
  deploy-all.ps1                    PowerShell loop: scp+ssh to all 8 VMs
```

The systemd unit is rendered inside `install.sh` via heredoc; no separate `.service` file in source. Keeps the install single-file.

## Deploy / update

### First-time install across all VMs

From Windows host:

```powershell
C:\vmimages\services\node-exporter\deploy-all.ps1
```

Walks every VM, scp's `install.sh`, runs it. Each VM ends with a smoke test (`curl :9100/metrics`).

### Single VM

```powershell
scp C:\vmimages\services\node-exporter\install.sh <host>:/tmp/install-node-exporter.sh
ssh <host> 'bash /tmp/install-node-exporter.sh'
```

### Bumping the version

Edit `NE_VERSION` in `install.sh`, re-run `deploy-all.ps1`. The script's idempotency check (`systemctl is-active`) won't help here; it only short-circuits if it's already running. To force a re-install, either bump the version (binary will be replaced) or `sudo systemctl stop node_exporter` first.

A cleaner version-bump path is captured in BACKLOG (Operational improvements: per-VM apt upgrade automation).

## Security notes

- Listens on `:9100` on all interfaces of the VM. Lab-subnet only by virtue of the VM being on `192.168.100.0/24` and there being no routes outward.
- node_exporter exposes a lot. CPU, processes, mounts, network sockets. Any host on the lab subnet (or tailnet) can read this. Acceptable for a single-operator lab; not acceptable for multi-tenant.
- The binary runs as a non-root system user `node_exporter`. It can read `/proc` and `/sys` (world-readable) but not modify anything.
- Hardening flags in the systemd unit (`ProtectSystem=strict`, `PrivateTmp`, etc.) prevent the agent from being a foothold if it ever gets compromised.
- No TLS on the scrape endpoint. Add `--web.config.file=` with a TLS config later if we ever expose it beyond the lab.

## Gotchas

- **`ProtectSystem=strict` blocks writes** to `/`. node_exporter doesn't write anywhere, so this is fine. If we later add a textfile collector (`--collector.textfile.directory=/var/lib/node_exporter`), we'll need to add `ReadWritePaths=/var/lib/node_exporter` to the unit.
- **The `--collector.systemd` flag is not free**: it queries dbus for every unit on every scrape. Cheap enough at our scale (a few hundred units per VM, 15s scrape) but watch CPU on lab-platform-eng if we ever blow up the VM count.
- **Port 9100 conflicts with PostgreSQL?** No, Postgres is on 5432. But `9100` is also used by HP JetDirect printers historically; not relevant here.
- **k3s nodes already have other Prometheus-style endpoints** (kubelet on 10250, kube-proxy on 10249, etc.). node_exporter sits beside them on 9100.
