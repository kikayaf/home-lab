# Backlog

Tracked additions, ideas, and tech debt. Items here are planned but not scheduled. When one becomes the next priority, it graduates to a numbered step in a stage runbook.

Sections:

1. [Data tier](#data-tier-lab-datastore) — stateful stores on `lab-datastore`
2. [Messaging tier](#messaging-tier-lab-automation) — queues and event streams on `lab-automation`
3. [Application workloads](#application-workloads) — services that consume the platform
4. [Edge and access](#edge-and-access) — how we reach the lab
5. [Security and hardening](#security-and-hardening)
6. [Operational improvements](#operational-improvements)
7. [Self-documenting infrastructure](#self-documenting-infrastructure)
8. [Tech debt](#tech-debt)

## Data tier (`lab-datastore`)

Services that hold state, deployed as Docker containers with bind-mounted data under `/srv/<service>/data/`.

| Item | What it is | Trigger to add | Notes |
|---|---|---|---|
| **Redis** | In-memory KV store, cache, pub/sub, simple queue | Scheduled: stage 3.7 | Tiny footprint; every non-trivial app wants it |
| **pgvector extension** | Vector similarity search inside Postgres | Install with Postgres at 3.5 | No new service; just an extension. Enables RAG / embeddings / "find similar" workloads |
| **VictoriaMetrics** | Prometheus-compatible long-term TSDB | When Prometheus retention matters (weeks → years) | Lighter than InfluxDB; drop-in for Prometheus remote-write |
| **InfluxDB v2** | Time-series DB with richer query language | If Flux query language is specifically wanted | Heavier than VictoriaMetrics; usually skip |
| **OpenSearch** | Log analytics + full-text search + Kibana UX | When "grep logs in a browser" isn't enough | Wants 4 GB+ RAM. Large jump in complexity |
| **Meilisearch** | Lightweight search engine | If an app needs a search bar | Much lighter than OpenSearch; good default |
| **Typesense** | Same space as Meilisearch | Alternative to Meilisearch | Pick one; comparable tradeoffs |
| **Qdrant / Weaviate** | Standalone vector DBs | If pgvector doesn't scale or lacks a needed feature | Usually pgvector is enough for a lab |
| **ClickHouse** | Columnar analytics DB | Large-scale event/analytics workloads | Overkill for typical lab use |
| **Neo4j / ArangoDB** | Graph DBs | Specific graph modeling use case | Only if you have a real graph problem |
| **MongoDB** | Document store | If an app specifically requires it | Postgres JSONB usually solves the same problem |
| **CouchDB** | Document store with sync protocol | Offline-first apps with replication needs | Niche |
| **SMB or NFS server** | File sharing to Mac / other VMs | When you want a shared drive | SMB for Windows integration, NFS for Linux-to-Linux |

## Messaging tier (`lab-automation`)

| Item | What it is | Trigger to add | Notes |
|---|---|---|---|
| **RabbitMQ** | AMQP message broker (queues, exchanges) | When apps need reliable work queues | Pair with Celery / Sidekiq / Temporal |
| **Kafka** (KRaft mode, single node) | Event streaming log | When event sourcing or high-volume streams matter | Resource-heavy; bump `lab-automation` to 8 GB |
| **NATS** | Lightweight modern messaging (pub/sub, streams, KV) | When we want pub/sub without Kafka's weight | Go-native, simple ops |
| **Temporal** | Workflow engine | For long-running stateful workflows | Uses Postgres + its own workers |
| **n8n** | Low-code workflow automation | For everyday automation flows | Ships as a single Docker container |

## Application workloads

Services you actually use or demo. Mostly land as k3s Deployments exposed via nginx vhost.

| Item | What it is | Placement | Trigger to add |
|---|---|---|---|
| **Structurizr Lite** | Renders `architecture/workspace.dsl` at `arch.lab.local` | `lab-platform-eng` or k3s | Closes the self-documenting loop |
| **Prometheus** | Metrics scrape + TSDB | k3s (or `lab-ai-ops` Docker) | First observability move |
| **Grafana** | Dashboards, alerting UI | k3s | Pairs with Prometheus + Loki |
| **Loki** | Log aggregation (LogQL) | k3s | For cluster and service logs |
| **Promtail / Alloy** | Log shipper for Loki | DaemonSet on k3s nodes | Companion to Loki |
| **code-server** | VS Code in browser | `lab-platform-eng` + Tailscale Funnel | Scheduled: stage 3.8. Unblocks work-PC access |
| **Keycloak** or **Authentik** | SSO / OIDC provider | k3s | When multiple services start sharing identity |
| **Homepage / Heimdall** | Dashboard of lab links | k3s, exposed at `home.lab.local` | Quality-of-life |
| **Uptime Kuma** | Self-hosted status page | k3s | "Is it up?" style monitoring |
| **Ollama** | Local LLM inference | `lab-ai-ops` | Needed for local AI work; GPU passthrough is nice-to-have |
| **LiteLLM or OpenWebUI** | Frontend for Ollama / OpenAI-compatible APIs | k3s | Browser UI for lab-hosted LLMs |

## Edge and access

| Item | What it is | Trigger | Notes |
|---|---|---|---|
| **TLS on nginx** | Self-signed wildcard `*.lab.local`, then Let's Encrypt with DNS-01 | When services start carrying anything non-trivial | Self-signed first (easy), LE later (real cert) |
| **Tailscale Serve / Funnel** configs | Specific services exposed via Funnel | When we add work-PC-accessible services | Central in stage 3.8 |
| **SSH over HTTPS** | sslh multiplexer, or Cloudflare Access SSH | If native SSH from restricted networks is needed | Code-server via Funnel usually removes this need |

### Cloudflare Tunnel + Cloudflare Access (planned upgrade path from Tailscale Funnel)

Stage 3.8 uses Tailscale Funnel to expose `code-server` to the public internet for work-PC access. Long-term, Cloudflare Tunnel is the cleaner answer. This section captures the plan for when we migrate.

**Why migrate**

- `.ts.net` URLs are publicly reachable by anyone who knows the URL; only defense is the service's password.
- Tailscale ToS technically limits Funnel to light, personal use.
- Some corporate DNS filtering blocks `*.ts.net`; Cloudflare subdomains on a real domain don't trip the same filters.
- Only one Funnel URL per tailnet device; scaling to many public services means path-based routing (messy) or multiple tailnet devices.
- Cloudflare Access gives proper auth (Google SSO, GitHub, email OTP, etc.) in front of every service, individually.

**What "migrate" means in practice**

- **Keep Tailscale as-is**: the VPN mesh, subnet router, Split DNS, Tailscale SSH. None of this changes. Personal-device access to the lab continues to use Tailscale.
- **Add Cloudflare Tunnel for public exposure**: runs `cloudflared` as a Docker container on `lab-gateway`. Outbound-initiated tunnel to Cloudflare's edge. No inbound ports, no firewall changes. Maps public subdomains of your domain to internal services (`code.example.com → http://192.168.100.208:8080`, `grafana.example.com → http://...`, etc.).
- **Add Cloudflare Access**: SSO policies per service. Authenticate against a chosen identity provider, get a signed JWT, Cloudflare forwards to the backend. No shared passwords.
- **Turn off `tailscale funnel`**: the one feature we stop using. `tailscale serve` internal-only stuff stays if we used it.

**What we need before migrating**

- A domain registered at Cloudflare (or moved to Cloudflare DNS). About $10/year for a `.com`, less for TLDs like `.net`, `.io`.
- A Cloudflare account (free tier is enough).
- ~30 minutes of setup.

**Architectural effect**

- Edge layer in `architecture/workspace.dsl` gains a `cloudflared` container and a `cloudflareAccess` external system.
- Operator access paths become:
  - Personal devices on tailnet: tailnet → lab-gateway → service (unchanged).
  - Public internet (work PC): public → Cloudflare → Cloudflare Access SSO → Cloudflare Tunnel → cloudflared on lab-gateway → service.
- Nothing we build in 3.8 with Funnel is wasted; code-server the service doesn't change, only the front door.

**Trigger to move**

Any of:

- Work-PC DNS filtering blocks `*.ts.net`.
- You decide you want SSO (Google, GitHub, etc.) instead of the code-server password.
- You want to add a second public-accessible service (Grafana, Structurizr) and don't want to share the Funnel URL.
- You register a domain for other reasons and it becomes free to wire up.

**Setup summary when we do it**

1. Register a domain and point DNS at Cloudflare.
2. Deploy `cloudflare/cloudflared:<pinned>` on lab-gateway as a Docker container, authenticate once with `cloudflared tunnel login`.
3. Create a tunnel, configure ingress rules in `config.yml` mapping public hostnames to internal URLs.
4. Add DNS records in Cloudflare (automated via `cloudflared tunnel route dns`).
5. In Cloudflare Zero Trust dashboard, create Access applications and identity providers; set policies per service.
6. Turn off `tailscale funnel` once the Cloudflare path is verified.

## Security and hardening

| Item | Trigger |
|---|---|
| Rotate k3s node token | After stage 3 stable, or periodically |
| Tighten pre-existing ufw rules on every VM (ports 10445, 31403, 11434, 3000 opened to Anywhere from template) | When we next touch ufw |
| Add Cloudflare Access or similar SSO in front of internal services | When external exposure broadens |
| Per-service ufw rules instead of "allow lab subnet full" | When we want real isolation between lab VMs |
| Network policies (k3s NetworkPolicy) between namespaces | When multiple workloads share the cluster |
| Secret storage: `.env` files now → Docker secrets / Vault / SOPS + age-encrypted Git | When secrets proliferate |
| Passwordless SSH from Mac (copy/create a Mac-local key, push pubkey to every VM, drop password auth) | When the password prompts get annoying |

## Operational improvements

| Item | Trigger |
|---|---|
| Backup automation: `pg_dump` + `restic` to MinIO and offsite (B2) | Right after Postgres lands |
| Monitoring lab itself (prometheus node_exporter on every VM, alerts on disk/mem/CPU) | After observability stack lands |
| Automated k3s upgrades (via system-upgrade-controller) | Once we're past the learning-k3s phase |
| Deployment via GitOps (ArgoCD or FluxCD) instead of manual `kubectl apply` | When manifest count grows past 5-10 |
| Centralized config for Docker services on lab-gateway (compose instead of raw `docker run`) | If we add more than 3 services there |
| Per-VM `apt upgrade` automation (unattended-upgrades or scheduled reboots) | Whenever |
| Log shipping for Docker services on non-k3s VMs (promtail/alloy) | After Loki lands |

## Self-documenting infrastructure

From `architecture/README.md`'s self-hosted/self-documenting plan:

| Item | Trigger |
|---|---|
| Structurizr Lite container on `lab-platform-eng` rendering the repo's `workspace.dsl` | Application-layer workload |
| Scheduled Hyper-V inventory export on Windows host (VM list, vSwitch map, NAT rules) → JSON under `architecture/live/` | Once DSL is self-hosted |
| `kubectl get all -A` scraped into same live dir | Same |
| DSL diff tool that compares live state to `workspace.dsl` and opens a PR when they drift | After the above two are in place |
| Flip `Planned` tags to live automatically based on scraped state | Icing |

## Tech debt

Things we noticed but deferred during stages 1-3.

| Item | Where noticed | Fix shape |
|---|---|---|
| Pre-existing ufw rules (10445, 31403, 11434, 3000, all "Anywhere") on every lab VM | Stage 2 step 7 | Script to remove these on all 8 VMs; re-run baseline afterward |
| Cloud-init network regeneration on hot-add | Stage 2 step 2 | Already patched at runtime (`99-disable-network-config.cfg`). Move the mitigation into the clone user-data's runcmd so new clones are born protected |
| Pre-existing `/usr/local/bin/kubectl` on lab-k3s-controlplane shadows k3s symlink | Stage 3 step 1 | Remove the stray binary, let k3s symlink take over. Or just document `KUBECONFIG` env as the workaround |
| Hyper-V MAC addresses baked into docs (`workspace.dsl`, `runbooks/stage-2-*.md`) | GitHub prep | Parameterize with placeholders if the repo goes truly public |
| SSH config on Mac not set up | Stage 3 step 3 | Copy the managed block from Windows `~/.ssh/config` to Mac |
| Mac doesn't have `controlplane01` private key | Stage 3 step 3 | Generate a Mac-local key and add to every VM's authorized_keys, or scp the existing key over |
| Tailscale SSH username mismatch when connecting as `felixkikaya` from Mac | Stage 3 step 3 | Either alias in SSH config, or adjust Tailscale ACL to map Mac user to `adminuser` |
| Tailscale CLI not on Mac PATH | Stage 2 step 1 | `sudo ln -s /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale` |
| `docker restart` required after Corefile structural changes | Stage 2 step 6 | Expected (reload 5s only covers hosts-plugin changes). Documented. Leave |
| Windows NAT (`Lab-NAT`) still active even though lab-gateway took over | Stage 2 step 4.4 | Optional: `Remove-NetNat -Name Lab-NAT`. Left as emergency fallback |
| Node token in command history on node01 and node02 | Stage 3 step 2 | `history -c && rm ~/.bash_history` on those VMs; consider `k3s token rotate` |

## Ideas worth revisiting

Thoughts we had that didn't graduate to a concrete item yet. Not actionable; capturing so they're not lost.

- Swap `Lab` vSwitch from Internal to Private once stage 2 is fully trusted, forcing all access through Tailscale + lab-gateway. Today the Windows host is directly on the lab subnet; private would drop that.
- Dedicate a second VHD on `lab-datastore` for `/srv/` so the OS disk and data disk are independent (backup/growth story is cleaner).
- Move the architecture DSL rendering into a GitHub Action so every commit updates rendered SVGs attached to the repo.
- Consider a proper secrets-management tool (Vault, Bitwarden CLI, 1Password Connect, age+sops in git) once we have more than a handful of secrets.
- ARM support: none of the lab VMs are ARM today, but keeping images multi-arch where possible (most already are) would let us add a Raspberry Pi to the tailnet later and pull its weight.
