# Home Private Cloud - lab reference

One-page cheatsheet for the Hyper-V home lab. Drop this into a Claude Project as static knowledge so any conversation has the topology, ports, conventions, and gotchas in context without re-reading the whole repo.

## Orientation

Hyper-V on a Windows host. Eight Ubuntu 24.04 VMs on `192.168.100.0/24`. `lab-gateway` is dual-homed (lab subnet + home network) and runs Tailscale, CoreDNS, iptables NAT, nginx, and ufw. Every VM is reachable via Tailscale from any device on the tailnet. DNS suffix is `lab.local`. Wildcard TLS for `*.lab.local` via mkcert (~825-day cert, mkcert root CA installed on Mac and iPad). Public exposure today is Tailscale Funnel for code-server only; planned migration to Cloudflare Tunnel.

## The fleet

| Hostname | IP | Role |
|---|---|---|
| `lab-gateway` | `192.168.100.201` | Tailscale, CoreDNS, iptables NAT, nginx reverse proxy, ufw, nginx_exporter |
| `lab-k3s-controlplane` | `192.168.100.202` | k3s server, embedded SQLite |
| `lab-k3s-node01` | `192.168.100.203` | k3s agent |
| `lab-k3s-node02` | `192.168.100.204` | k3s agent |
| `lab-datastore` | `192.168.100.205` | Postgres + pgvector, MinIO, Redis, Vaultwarden, postgres_exporter, redis_exporter |
| `lab-ai-ops` | `192.168.100.206` | Reserved (AI/ML, mostly idle) |
| `lab-automation` | `192.168.100.207` | Reserved (workflow runners, idle) |
| `lab-platform-eng` | `192.168.100.208` | code-server, Structurizr static site, Prometheus, Grafana, Loki, Alertmanager, ntfy |

Every VM also runs `node_exporter` (port 9100) and `Promtail` as systemd binaries.

## Service catalog (URL · port · host)

| Service | URL | Internal port | Host |
|---|---|---|---|
| code-server | `https://code.lab.local` (+ Tailscale Funnel) | 8080 | lab-platform-eng |
| Vaultwarden | `https://vault.lab.local` | 8222 | lab-datastore |
| MinIO S3 API | `https://s3.lab.local` | 9000 | lab-datastore |
| MinIO Console | `https://minio.lab.local` | 9001 | lab-datastore |
| Postgres | `lab-datastore.lab.local:5432` | 5432 | lab-datastore |
| Redis | `lab-datastore.lab.local:6379` | 6379 | lab-datastore |
| Prometheus | `https://prom.lab.local` | 9090 | lab-platform-eng |
| Grafana | `https://grafana.lab.local` | 3000 | lab-platform-eng |
| Alertmanager | `https://alerts.lab.local` | 9093 | lab-platform-eng |
| Loki | (internal, queried by Grafana) | 3100 | lab-platform-eng |
| ntfy | `https://ntfy.lab.local` | 8085 | lab-platform-eng |
| Structurizr site | `https://arch.lab.local` | (static via nginx) | lab-platform-eng |
| postgres_exporter | (internal scrape only) | 9187 | lab-datastore |
| redis_exporter | (internal) | 9121 | lab-datastore |
| nginx_exporter | (internal) | 9113 | lab-gateway |
| node_exporter | (internal scrape per VM) | 9100 | every VM |

## Common commands

### Push a service config

```powershell
scp services/<svc>/<file> lab-<host>:/tmp/<file>
ssh lab-<host> "sudo mv /tmp/<file> /srv/<svc>/conf/<file> && sudo chown <uid>:<uid> /srv/<svc>/conf/<file>"
```

UID 999 = postgres / redis. UID 472 = grafana. UID 65534 = prometheus / alertmanager. UID 10001 = loki. UID 1000 = ntfy / code-server.

### Push an nginx vhost (note the path)

```powershell
scp services/nginx/conf.d/<svc>.conf lab-gateway:/tmp/<svc>.conf
ssh lab-gateway "sudo mv /tmp/<svc>.conf /opt/nginx/conf.d/<svc>.conf && sudo chown root:root /opt/nginx/conf.d/<svc>.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

The mount on the host is `/opt/nginx/conf.d/`, NOT `/srv/nginx/conf.d/`. Pushing to `/srv` is silently ineffective.

### Reload Prometheus / Alertmanager / Grafana

```powershell
ssh lab-platform-eng "docker exec prometheus kill -HUP 1"
ssh lab-platform-eng "docker exec alertmanager kill -HUP 1"
ssh lab-platform-eng "docker restart grafana"
```

Prometheus + Alertmanager support SIGHUP reload. Grafana doesn't; restart it.

### Run a Postgres command

```powershell
ssh lab-datastore "docker exec -i postgres psql -U postgres -c 'SELECT version();'"
```

### Run a MinIO admin command (mc is on lab-datastore)

```powershell
ssh lab-datastore "mc admin info lab"
ssh lab-datastore "mc ls lab/"
```

Alias `lab` is configured against `http://192.168.100.205:9000`.

### Generate Mermaid views from the DSL

```powershell
C:\vmimages\architecture\generate-mermaid.ps1
```

SSHes to lab-platform-eng, runs `structurizr/structurizr` CLI on `workspace.dsl`, post-processes for ELK layout + colored layer subgraphs, pulls `.mmd` files back to `architecture/views/`.

### Prometheus targets / Loki labels / Alertmanager UI

- Targets: `https://prom.lab.local/targets` (set Healthy filter)
- Loki labels: `ssh lab-platform-eng "curl -s http://192.168.100.208:3100/loki/api/v1/labels"`
- Alertmanager: `https://alerts.lab.local`

### PowerShell execution-policy bypass

```powershell
powershell -ExecutionPolicy Bypass -File <path>
```

Or once per user: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`.

## Conventions

- **Hyper-V VM names** are prefixed `vmN-` (`vm1-lab-gateway`). Linux hostnames drop the prefix.
- **Admin user** is `adminuser` with NOPASSWD sudo and SSH-key-only auth via `~/.ssh/controlplane01`.
- **IP range** `192.168.100.201-220` is reserved for lab VMs. `06-provision-all-vms.ps1` validates.
- **Container port binding**: `<lab-ip>:<port>:<container-port>`, NOT `0.0.0.0:<port>`. Tailscale Funnel binds `tailscale0:443` and conflicts otherwise.
- **`labnet` Docker network** for container-to-container DNS on the same host. Cross-host always uses lab IP.
- **`*.local.json` files are gitignored.** Used for Vaultwarden import JSON files. Always remove after import.
- **Source-controlled credentials are forbidden.** Generated passwords go to Vaultwarden via import-file workflow, then the local file gets removed.
- **`*.lab.local` DNS resolves via wildcard** in CoreDNS pointing at lab-gateway (192.168.100.201). nginx routes by Host header from there.
- **Each commit is one logical change.** Stage runbooks tend to be one commit per stage; smaller refactors are their own commits.

## Critical gotchas

| Trap | Why it bites | Fix |
|---|---|---|
| nginx mount is `/opt/nginx/conf.d/`, not `/srv/nginx/conf.d/` | scp to `/srv` returns success, nginx never sees the file | Always push to `/opt/nginx/conf.d/`, verify with `docker exec nginx ls /etc/nginx/conf.d/` |
| `localhost:<port>` doesn't reach service from same VM | Container is bound to lab IP only | Use lab IP, or `docker exec <container>` |
| PowerShell + ssh + bash + jq quoting | Double quotes get stripped through the layers | Use `@'...'@` here-string OR open the URL in browser. Never fight quoting twice |
| Grafana datasource UID was auto-generated initially | Imported dashboards reference `${DS_PROMETHEUS}` | UID is now pinned to `Prometheus` in provisioning yaml. Don't change it |
| MinIO Prometheus scrape via nginx returns HTML | nginx mangles the Authorization header | Scrape direct: `http://192.168.100.205:9000/minio/v2/metrics/cluster` |
| Redis container started before labnet existed | `redis_exporter` can't resolve `redis:6379` | `docker network connect labnet redis` (one-time, persistent) |
| cAdvisor 0.49 / 0.51 fail on overlay2 | Hardcoded `overlayfs` path lookup | Cut. node_exporter + per-service exporters cover most use cases. Logged in BACKLOG |
| Structurizr `defaultRenderer: elk` init hint not always picked up | Mermaid versions differ | Post-processor replaces `graph TB` with `flowchart-elk TB` directly |
| mkcert root CA only trusted on devices it's installed on | iPad / phone won't trust `*.lab.local` until rootCA.pem is loaded as a profile | AirDrop the rootCA.pem, install profile, enable in Certificate Trust Settings |

## Where to look for what

- **"How do I add a new service?"** Read `runbooks/stage-3-redis.md` or `stage-3-observability.md` for the established pattern.
- **"What's planned but not done?"** `BACKLOG.md` is the master list (data tier, messaging tier, app workloads, edge/access, security, ops, tech debt, ideas).
- **"What's the architecture supposed to look like?"** `architecture/workspace.dsl` (DSL source of truth). `architecture/views/*.mmd` (rendered Mermaid). README.md (network diagrams).
- **"Why was X done that way?"** The corresponding runbook's "Gotchas" section. The pain points that shaped decisions are recorded there.
- **"What credentials exist?"** Vaultwarden at `https://vault.lab.local`. Lab folder.
- **"What's running where right now?"** Lab Overview dashboard at `https://grafana.lab.local`.

## Repo top level

```
C:\vmimages\
  CLAUDE.md            Entry-point doc for any Claude session
  README.md            Top-level architecture overview + Mermaid network diagrams
  BACKLOG.md           Tracked additions and tech debt
  lab-reference.md     This file: dense one-pager for project knowledge
  scripts/             Stage 1 PowerShell provisioning (8 numbered scripts)
  runbooks/            Stage 2 + stage 3 operational guides (one per phase)
  services/            Source-controlled configs for every service running
  architecture/        Structurizr DSL + auto-generated Mermaid views
  Exports/  VMs/  seeds/  ISO/   Hyper-V working dirs (gitignored)
```
