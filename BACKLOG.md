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
| **Structurizr Lite** | Renders `architecture/workspace.dsl` at `arch.lab.local` | `lab-platform-eng` Docker | Done in stage 3.11 (with caveats about renderer, see Ideas worth revisiting) |
| **Prometheus** | Metrics scrape + TSDB | `lab-platform-eng` Docker | Done in stage 3.12 |
| **Grafana** | Dashboards, alerting UI | `lab-platform-eng` Docker | Done in stage 3.12 |
| **Loki** | Log aggregation (LogQL) | `lab-platform-eng` Docker | Done in stage 3.12 |
| **Promtail** | Log shipper for Loki | systemd binary on every VM | Done in stage 3.12 |
| **Alertmanager** | Alert routing | `lab-platform-eng` Docker | Done in stage 3.12 |
| **code-server** | VS Code in browser | `lab-platform-eng` + Tailscale Funnel | Scheduled: stage 3.8. Unblocks work-PC access |
| **Keycloak** or **Authentik** | SSO / OIDC provider | k3s | When multiple services start sharing identity |
| **Homepage / Heimdall** | Dashboard of lab links | k3s, exposed at `home.lab.local` | Quality-of-life |
| **Uptime Kuma** | Self-hosted status page | k3s | "Is it up?" style monitoring |
| **Vaultwarden** | Self-hosted Bitwarden-compatible password vault (human passwords) | `lab-datastore` Docker or k3s pod | Data in Postgres (already available); web UI behind nginx at `vault.lab.local`; Cloudflare Tunnel later for cross-device access. Removes dependency on cloud password managers and gives you a place to store passwords we keep generating |
| **Ollama** | Local LLM inference | `lab-ai-ops` | Needed for local AI work; GPU passthrough is nice-to-have |
| **LiteLLM or OpenWebUI** | Frontend for Ollama / OpenAI-compatible APIs | k3s | Browser UI for lab-hosted LLMs |

## Edge and access

| Item | What it is | Trigger | Notes |
|---|---|---|---|
| **TLS on nginx** (done, mkcert wildcard) | Private CA + `*.lab.local` wildcard via mkcert | Done stage 3.10 | Certs valid ~825 days, manual rotation for now |
| **cert-manager** on k3s | Kubernetes-native cert automation (watches Certificate CRs, issues + rotates) | First k3s workload that wants TLS on an Ingress | Pair with either step-ca internal issuer or ACME DNS-01 external issuer |
| **step-ca** (Smallstep internal CA) | ACME-compatible internal CA, auto-rotate lab certs | When we want cert-manager to stop touching mkcert and do ACME-style internal | Deploy as k3s StatefulSet; cert-manager points its ClusterIssuer here |
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
| Machine secrets manager (HashiCorp Vault, OpenBao, or Infisical) for service credentials, API keys, cert material | When passwords in `.env` files and chat history become too many to track |
| File-level secret encryption in git (`sops` + `age`, or `git-crypt`) for infra-level secrets | When we want secrets versioned alongside code without exposing them |
| Passwordless SSH from Mac (copy/create a Mac-local key, push pubkey to every VM, drop password auth) | When the password prompts get annoying |

## Operational improvements

| Item | Trigger |
|---|---|
| Backup automation: `pg_dump` + `restic` to MinIO and offsite (B2) | Right after Postgres lands. Now urgent: the data tier (Postgres, MinIO, Redis, Vaultwarden) has real state and zero protection |
| Wire Alertmanager to Slack / email / webhook | After the rules have been tuned for a week and we know what's noisy |
| Automated k3s upgrades (via system-upgrade-controller) | Once we're past the learning-k3s phase |
| Deployment via GitOps (ArgoCD or FluxCD) instead of manual `kubectl apply` | When manifest count grows past 5-10 |
| Centralized config for Docker services on lab-gateway (compose instead of raw `docker run`) | If we add more than 3 services there |
| Per-VM `apt upgrade` automation (unattended-upgrades or scheduled reboots) | Whenever |
| Long-term metric retention via VictoriaMetrics + remote_write | If we ever want to look at trends beyond 30 days. Today Prometheus retention is 30d wall-clock |
| Loki retention beyond 14 days | Same trigger; today Loki keeps 14 days |
| k3s pod log shipping into Loki | When the first k3s workload that we actually care about lands. Today the Promtail Docker scrape doesn't match anything on lab-k3s-* nodes |

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
- Consider a proper secrets-management tool (Vault, Bitwarden CLI, 1Password Connect, age+sops in git) once we have more than a handful of secrets. See the dedicated section below.
- ARM support: none of the lab VMs are ARM today, but keeping images multi-arch where possible (most already are) would let us add a Raspberry Pi to the tailnet later and pull its weight.

- **Better renderer for the architecture site.** structurizr-site-generatr (current choice) renders the Structurizr DSL via C4-PlantUML, which doesn't honor custom element-tag styles. Containers all draw as default blue rectangles; group boundaries and layer labels carry the visual signal but not per-layer colors. Options to revisit: (a) switch to Structurizr Cloud (paste DSL, get colored SVGs, serve static); (b) export to Mermaid via Structurizr CLI and serve those; (c) use IcePanel free tier; (d) live with monochrome since the layered structure is still legible. Trigger to revisit: when we have stakeholders viewing the diagrams or when we're feeling fastidious. Today's priority is workloads.

- **Per-container metrics (cAdvisor or alternative).** Tried cAdvisor v0.49.1 and v0.51.0 during stage 3.12; both hardcode `image/overlayfs/` in the Docker layer-DB lookup but modern Docker uses `image/overlay2/`. Symlink workaround silenced the layerdb errors but per-container scopes still didn't surface as series. For now we live without per-container Prometheus metrics; node_exporter + per-service exporters + `docker stats` for ad-hoc checks cover the ground. Options to revisit: (a) wait for upstream cAdvisor fix; (b) use Docker daemon's native `metrics-addr` (engine-level only, not per-container); (c) try a different exporter (process_exporter, container-exporter); (d) move to k3s where the kubelet already exposes container metrics natively. Trigger to revisit: when we have many more containers and "what's hot right now" needs answering without SSH.

## Password vaults and secret management

Two different problems that people often conflate. Both are planned; timing depends on pain.

### Human password vault

The thing you use daily for website logins, API credentials you copy-paste, and the lab-service passwords we've been generating.

| Option | License | Strengths | Weaknesses |
|---|---|---|---|
| **Vaultwarden** | GPLv3 | Bitwarden-server-compatible in ~100 MB. Works with all Bitwarden clients (browser, mobile, desktop, CLI). Postgres backing (ours already). | Unofficial implementation; the trade-off for keeping it lightweight is that some Bitwarden enterprise features aren't there |
| **Bitwarden self-hosted (official)** | GPLv3 | Official, full feature set | ~2-4 GB resource footprint; overkill for a solo lab |
| **Passbolt** | AGPLv3 | Team-oriented, good sharing model | Heavier, needs MySQL/MariaDB rather than Postgres |
| **KeePassXC** + sync | GPLv2 | Local-first; file sync via Git/Dropbox/SMB | No server; no web UI; phone apps are less polished |
| **1Password** (not OSS) | Proprietary | Best-in-class UX | Paid; data in Apple/Agile servers |

**Recommendation for this lab**: Vaultwarden on `lab-datastore` (or a k3s pod, either works) with Postgres as the data backend. Exposed internally via nginx at `vault.lab.local`. Reachable from work PC via Cloudflare Tunnel (when we migrate off Funnel). Browser extensions connect to the self-hosted URL. All Bitwarden clients work unchanged; they just point at our server instead of `bitwarden.com`.

**Trigger to build**: when the number of generated passwords crosses "more than I can remember without writing them down" (we're close already; several lab-service passwords exist in chat history).

### Machine secrets (service-to-service credentials)

The thing services need at runtime: DB passwords, API keys, TLS certs, GitHub tokens for CI, tailnet auth keys.

| Option | License | Strengths | Weaknesses |
|---|---|---|---|
| **HashiCorp Vault** | BSL (not OSS after v1.14) | Industry standard, huge feature set (dynamic secrets, PKI, transit encryption, SSH certs) | License change; heavy; steep learning curve |
| **OpenBao** | MPLv2 | Fork of Vault 1.14, stays OSS; drop-in compatible | Community still growing |
| **Infisical** | MIT | Developer-friendly, nice UI, good DX | Younger; fewer integrations than Vault |
| **age + sops, encrypted in git** | Free, OSS | No server needed; secrets live alongside code | Manual rotation; no dynamic secrets |
| **Docker secrets / k8s Secrets** | Free | Already available where we run containers | Just-opaque storage; no rotation, no audit |

**Recommendation for this lab**: Start with `sops` + `age` for infra-level secrets that fit with git (e.g., deployment configs, env files). Move to OpenBao or Vault only when service-to-service dynamic creds are needed. Not on the critical path yet.

**Trigger to build**: when we have more than 3-4 services with long-lived credentials.

### Certificate management (separate concern)

Different from password/secret management. Certs are files issued by a CA, not passwords; they belong in infrastructure tooling, not in Vaultwarden.

Current state: mkcert wildcard `*.lab.local`, manual rotation, valid for ~825 days. Fine for a small lab with one wildcard.

Future path:

- **cert-manager** (k8s-native) issues and rotates certs for k3s Ingresses and other resources. Add when the first k3s workload needs TLS (Grafana, Structurizr, etc., once they move to k3s Ingress).
- **step-ca** (Smallstep) pairs with cert-manager as an internal ACME CA. Replaces the manual mkcert flow with automated rotation. Add alongside cert-manager if we want internal certs to auto-rotate without operator touches.
- **Cloudflare Tunnel** handles external cert termination entirely at Cloudflare's edge. When we migrate public access from Tailscale Funnel to Cloudflare Tunnel (see earlier), external TLS becomes a solved problem with no cert manager required.
- **acme.sh / certbot** only necessary if we ever serve public traffic directly from our IP without Cloudflare, which is unlikely.
