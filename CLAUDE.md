# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Home Private Cloud

A Hyper-V home lab on a single Windows host. Eight Ubuntu 24.04 VMs on an isolated `192.168.100.0/24` subnet, behind Windows NAT in stage 1 and behind a dual-homed `lab-gateway` VM running Tailscale + CoreDNS + nginx + iptables in stage 2 onwards. Stage 3 lands real workloads (k3s cluster, Postgres, MinIO, Redis, Vaultwarden, Structurizr, observability stack with Prometheus/Grafana/Loki/Alertmanager + ntfy).

The repo holds three things, not source code in the conventional sense:

- **Provisioning scripts** that build the VM fleet from a template (stage 1, fully automated)
- **Source-controlled service configs and runbooks** for everything that runs on top (stages 2 and 3, operator-driven)
- **Architecture model** as Structurizr DSL with auto-generated Mermaid views

## Repository layout

| Path | What lives there |
|---|---|
| `scripts/` | Numbered PowerShell scripts that build, verify, and destroy stage 1. Run in order from a Windows host as Administrator. `00-config.ps1` is the source of truth for VM names, IPs, paths, and SSH keys. |
| `runbooks/` | Stage 2 and stage 3 step-by-step operational guides. Each runbook is the authoritative record of "what we actually did and why." Add a new runbook for any non-trivial change. |
| `services/` | Source-controlled configs for every service running on the lab. One folder per service; configs get pushed to the right VM and bind-mounted into the corresponding Docker container. |
| `architecture/` | Structurizr DSL (`workspace.dsl`) is the single source of truth for the architecture model. Auto-generated Mermaid views live in `views/`. |
| `BACKLOG.md` | Tracked additions, ideas, and tech debt. Items here graduate to a numbered runbook step when they become next priority. |
| `README.md` | Top-level architecture overview with embedded Mermaid network diagrams. The "elevator pitch" of the project. |

`Exports/`, `seeds/`, `VMs/`, `ISO/` are Hyper-V working directories, all gitignored.

## The fleet

| Hostname | IP | Role |
|---|---|---|
| `lab-gateway` | `192.168.100.201` | Tailscale, CoreDNS, iptables NAT, nginx reverse proxy, ufw |
| `lab-k3s-controlplane` | `192.168.100.202` | k3s server, embedded SQLite |
| `lab-k3s-node01` | `192.168.100.203` | k3s agent |
| `lab-k3s-node02` | `192.168.100.204` | k3s agent |
| `lab-datastore` | `192.168.100.205` | Postgres, MinIO, Redis, Vaultwarden + service exporters |
| `lab-ai-ops` | `192.168.100.206` | Reserved for AI/ML workloads (mostly idle today) |
| `lab-automation` | `192.168.100.207` | Reserved for workflow runners (idle today) |
| `lab-platform-eng` | `192.168.100.208` | code-server, Structurizr, Prometheus, Grafana, Loki, Alertmanager, ntfy |

DNS suffix is `lab.local`. SSH alias `ssh lab-<hostname>` works from any lab VM and from the Windows host.

## Common workflows

### Stage 1: build the fleet from scratch

Open PowerShell as Administrator, then:

```powershell
cd C:\vmimages\scripts\
.\00a-setup-lab-network.ps1
.\01-prepare-template.ps1
.\03-export-template.ps1
.\04-setup-wsl-tools.ps1
.\06-provision-all-vms.ps1
.\07-configure-ssh.ps1
.\08-verify-lab.ps1
```

Step 04 sometimes wants a reboot and a second run. Step 06 takes 15-25 minutes hands-off.

### Stage 2 / 3: deploying a new service

The pattern across every runbook is the same:

1. Author the service config under `services/<name>/` on the Windows host
2. scp the config to the target VM under `/srv/<name>/conf/` (most VMs) or `/opt/nginx/conf.d/` (nginx-only)
3. Run `docker run -d ...` to start the container, bound to the lab IP (`-p 192.168.100.X:<port>:<port>`), with bind mounts to the conf and data dirs
4. If the service is HTTP-facing, add an nginx vhost under `services/nginx/conf.d/`, push it to lab-gateway, reload nginx
5. Save any generated credentials to Vaultwarden (`https://vault.lab.local`)
6. Write the runbook in `runbooks/`

### Reloading nginx after a vhost change

```powershell
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

### Reloading Prometheus after a config or rules change

```powershell
ssh lab-platform-eng "docker exec prometheus kill -HUP 1"
```

### Generating Mermaid views from the DSL

```powershell
C:\vmimages\architecture\generate-mermaid.ps1
```

The script SSHes into lab-platform-eng, runs the Structurizr CLI Docker image against `workspace.dsl`, and pulls the `.mmd` files back to `architecture/views/`. Commit the regenerated views alongside any DSL change.

### Running a destructive PowerShell script blocked by execution policy

```powershell
powershell -ExecutionPolicy Bypass -File <path>
```

Or persistently, once: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`.

## Critical gotchas (everything Claude needs to know to not waste a turn)

- **The live nginx mount on lab-gateway is `/opt/nginx/conf.d/`, not `/srv/nginx/conf.d/`.** scp to `/srv/...` is silently ineffective. The nginx README documents this; the deploy commands in older runbooks use the wrong path - cross-check before copy-pasting.
- **Most Docker containers bind to `<lab-ip>:<port>`, not `0.0.0.0:<port>`.** This is a workaround for Tailscale Funnel claiming `tailscale0:443`. So `curl localhost:9090` from inside lab-platform-eng will fail; use `curl 192.168.100.208:9090` or `docker exec <container> ...`.
- **PowerShell + ssh + bash + jq quoting eats nested double quotes.** When a one-liner fails with "invalid char escape" or "unknown jq function" matching a quoted argument, switch to a here-string `@'...'@` or skip the API and use the browser. Never fight PowerShell quoting for more than one round.
- **`.local.json` suffix is gitignored.** Use it for credential import files (Bitwarden JSON imports for Vaultwarden) so they don't accidentally land in commits.
- **Some VMs don't share a Docker network with each other.** Container-to-container DNS names like `redis` only resolve when both containers are on the same Docker network on the same host. `labnet` is the convention; attach new containers with `--network labnet`. Cross-host comms use the lab IP.
- **The Grafana data source UID is pinned to `Prometheus` (capital P)** in `services/grafana/provisioning/datasources/prometheus.yml`. Imported community dashboards from grafana.com use `${DS_PROMETHEUS}` placeholders; the dashboard install pipeline sed-replaces this with `Prometheus` so the UID matches. If anyone changes the UID, every imported dashboard's panels go grey.
- **The MinIO Prometheus scrape goes direct to `192.168.100.205:9000` over HTTP**, not via nginx at `s3.lab.local`. nginx doesn't pass the Authorization header reliably to the MinIO metrics endpoint.
- **cAdvisor is deferred.** v0.49 and v0.51 hardcode `image/overlayfs/` in the Docker layer-DB lookup but modern Docker uses `overlay2`. Logged in BACKLOG; node_exporter + per-service exporters cover most observability needs.

## Conventions

- **Hyper-V VM names** are prefixed `vmN-` for deterministic Hyper-V sort order (`vm1-lab-gateway`). The prefix is Hyper-V-side only; Linux hostnames drop it.
- **Admin user** on every VM is `adminuser` with NOPASSWD sudo and SSH-key-only auth (`~/.ssh/controlplane01`).
- **IP range** `192.168.100.201-.220` is reserved for lab VMs. The provisioning script validates the range.
- **Source-controlled secrets are forbidden.** Generated passwords go to Vaultwarden via the import-file workflow (`*.local.json`, gitignored), then the local file gets removed.
- **Every commit on its own logical change.** Stage runbooks tend to be one commit per stage; smaller refactors are their own commits. The git history reads like a build log.

## Where to look for what

- "How do I add a new service?" Read any of the recent stage 3 runbooks (`runbooks/stage-3-redis.md`, `stage-3-vaultwarden.md`, `stage-3-observability.md`) for the established pattern.
- "What's planned but not done?" `BACKLOG.md` is the master list, organized by tier (data tier, messaging tier, app workloads, edge and access, security, operational improvements, tech debt).
- "What's the architecture supposed to look like?" `architecture/workspace.dsl` is the source of truth. `architecture/views/` has rendered Mermaid views. The top-level `README.md` has the elevator-pitch network diagrams.
- "Why was X done that way?" Check the corresponding runbook's "Gotchas" section. The pain points that shaped each design decision are captured there.
