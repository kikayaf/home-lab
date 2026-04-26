# Architecture

Single source of truth for the lab's architecture diagrams, written in [Structurizr DSL](https://docs.structurizr.com/dsl) using the [C4 model](https://c4model.com).

## Why Structurizr DSL

C4 is the de facto standard for communicating software architecture to mixed audiences (operators, engineers, stakeholders). Structurizr DSL is the reference implementation: one source file captures the model, and the tool generates consistent multi-level views from it. Text-based, versionable alongside the scripts, evolves with the lab.

Compared to Mermaid (which is used in the READMEs for quick inline diagrams), Structurizr gives us:

- Formal levels: System Context, Container, Component, Deployment.
- Enforced consistency across views (rename a container once, it updates everywhere).
- Deployment views that show where containers physically run (maps directly onto the VM fleet).
- A "container" abstraction that covers VMs, Docker containers, k8s pods, and services uniformly.

## Files

- `workspace.dsl` - the whole model plus four views.

## Modeling choice

**Each service is a C4 "container"**. Most deploy as **Docker containers** (image name in the technology field); a few run **native** via systemd (tailscale, k3s); two are **kernel features** (iptables, ufw). VMs are **deployment nodes** that host these containers, with a `Docker engine` deployment sub-node shown inside any VM that runs Docker.

**The model is organized as a layered architecture**, which is what a well-architected system looks like at this abstraction. Each layer is a `group` in the DSL and a visual cluster in the container view.

## The layers

| Layer | Purpose | Services |
|---|---|---|
| **Edge & Access** | Entry points into the lab. Remote access, DNS, reverse proxy. | tailscale (native), coredns (Docker), nginx (Docker) |
| **Application** | Workloads the operator and users consume. | workflows, devtools, model serving (all Docker) |
| **Platform** | Orchestration and container runtime. Where workloads run. | k3s server, k3s agents (native) |
| **Data** | Stateful persistence. Separated from apps so they can be rebuilt without data risk. | PostgreSQL, MinIO, restic (all Docker) |
| **Security** (cross-cutting) | Firewall and NAT enforcement across every other layer. | iptables NAT, ufw (kernel) |
| **Observability** (cross-cutting) | Metrics, logs, dashboards. Every layer above emits signals consumed here. | Prometheus, Grafana, Loki (all Docker) |
| **Infrastructure** | Substrate everything sits on. Modeled in the deployment view, not the container view. | Physical host, Hyper-V, Lab vSwitch, VMs, Docker engine |

Dependency direction: higher layers depend on lower ones. Cross-cutting layers (security, observability) have edges into many layers but are rarely called by them.

## Views this workspace generates

| View | What it shows | Audience |
|---|---|---|
| `SystemContext` | Operator, Internet, Home network, Tailnet, and the Home Lab system. | Stakeholders, new engineers |
| `Containers` | Layered architecture view. Services grouped into six layers (Edge, Application, Platform, Data, Security cross-cutting, Observability cross-cutting). Technology column tells you Docker vs native vs kernel. | Anyone adding or understanding a service |
| `Stage1Deployment` | Infrastructure layer. Physical hierarchy: Windows host → Hyper-V → Lab vSwitch → each VM → (Docker engine / systemd / Linux kernel) → containers. Makes the Docker runtime boundary explicit. | Anyone debugging infra or placing workloads |

As stage 2 lands (lab-gateway promoted to the real gateway), a `Stage2Deployment` view will be added. The model stays the same; only deployment edges change.

## How to render

Pick whichever fits your moment.

### 1. Zero-install (quickest)

Go to https://structurizr.com/dsl, paste the contents of `workspace.dsl`, click "Render". Every view renders in the browser. Good for a one-off look.

### 2. Local via Docker (Structurizr Lite)

Runs as a container. From this folder:

```powershell
docker run -it --rm -p 8080:8080 `
    -v "${PWD}:/usr/local/structurizr" `
    structurizr/lite
```

Then browse http://localhost:8080. Structurizr Lite watches the file; edits to `workspace.dsl` are reflected on refresh.

Fittingly, this can also run as a k3s deployment on the lab itself once k3s is up. The manifest will land in this folder later.

### 3. VS Code extension

Install **"Structurizr DSL"** by ciarant. Opens a side-by-side preview that live-updates as you edit.

### 4. Export to other formats

Using the Structurizr CLI (`docker run --rm -v "${PWD}:/usr/local/structurizr" structurizr/cli ...`):

- `structurizr-cli export -workspace workspace.dsl -format mermaid` - generates Mermaid per view
- `structurizr-cli export -workspace workspace.dsl -format plantuml/c4plantuml` - generates PlantUML
- `structurizr-cli export -workspace workspace.dsl -format dot` - Graphviz

Mermaid export is what to use when embedding a view directly into a README. We have this wired up automatically via [`./generate-mermaid.ps1`](./generate-mermaid.ps1); see the next section.

## Mermaid views (auto-generated)

Pre-rendered Mermaid views live in [`./views/`](./views/) and are committed alongside the DSL so GitHub renders them inline without needing to spin up Structurizr.

Workflow:

1. Edit `workspace.dsl`
2. Run `.\architecture\generate-mermaid.ps1` from PowerShell (uses Structurizr CLI on lab-platform-eng over SSH; pulls `.mmd` files back to `architecture/views/`)
3. Commit the DSL change + the regenerated views together

The script wipes stale views first, so removing a view from the DSL also removes its `.mmd` file. Open the `views/` folder for the per-view files. Embed in any markdown via:

````markdown
```mermaid
{{< include "architecture/views/Containers.mmd" >}}
```
````

(GitHub doesn't support that include syntax directly; either copy the contents into a markdown code fence, or just link to the file: [`./views/Containers.mmd`](./views/Containers.mmd) - GitHub renders standalone `.mmd` files as Mermaid diagrams.)

## Conventions in the DSL

- **Services = C4 containers**. One service per container (tailscale, coredns, postgres, grafana, ...). Keeps the container view readable and lets the deployment view place each one precisely.
- **Technology field is explicit**. `Docker: <image>` for containerized services, `<language> · systemd` for native ones, `Kernel netfilter` for kernel features. Makes runtime obvious from the diagram alone.
- **Groups = architectural layers**. Every container sits in exactly one group, and that group is its layer (Edge, Application, Platform, Data, Security, Observability).
- **Tags drive styling**:
  - Runtime (sets color + shape): `Docker`, `Native`, `Kernel`
  - Layer (redundant with groups, useful for filtering/scripting): `Layer-Edge`, `Layer-App`, `Layer-Platform`, `Layer-Data`, `Layer-Security`, `Layer-Observability`
  - Deployment (for the deployment view): `VM`, `ContainerRuntime`, `Hypervisor`, `Hardware`, `Network`
  - Meta: `External`, `Planned` (dashed border for services not yet installed)
- **Why color by runtime, not by layer**: groups already visually separate layers. Coloring by runtime (Docker vs native vs kernel) adds an orthogonal dimension that makes "what's actually a Docker container" visible at a glance.
- **Dependency direction is enforced in the relationships**. Higher layers call lower ones; cross-cutting layers (security, observability) may have edges into everything but are generally not called by them.

## Self-hosted and self-documenting (planned)

Longer-term intent: this architecture layer lives inside the lab it describes. Two stages:

**Self-hosted.** Run Structurizr Lite as a Docker container on `lab-platform-eng`. Mount this folder, expose it through `nginx` at `arch.lab.local`. The model is already wired into the DSL (`structurizr` container in the Application layer, proxied by nginx). Operationally:

```bash
# on lab-platform-eng, once stage 2 is up
docker run -d --name structurizr \
    -p 8080:8080 \
    -v /srv/architecture:/usr/local/structurizr \
    --restart unless-stopped \
    structurizr/lite
```

Point `/srv/architecture` at a git clone of `C:\vmimages\architecture\` (sync via rsync on commit, or a CI job). Edits to `workspace.dsl` reflect live.

**Self-documenting.** Beyond just rendering what we write, have the lab contribute to its own architecture docs. Candidate sources:

- **Hyper-V inventory**: a scheduled PowerShell task on the host exports the current VM list, vSwitch map, and NAT rules to a JSON file under `architecture/live/`. A small DSL generator diffs this against `workspace.dsl` and opens a pull request when drift is detected.
- **k3s state**: once k3s is up, scrape `kubectl get all -A` and deployed Helm charts. Generated services become `Planned` → `Live` by updating tags.
- **Docker Compose / compose-on-VM inventory**: parse `docker ps --format json` per VM over SSH, attribute containers to the right Application-layer entry.
- **Prometheus service discovery**: once observability is running, every live target becomes evidence that a container in the model is actually deployed. Flip the `Planned` tag off based on target health.

None of this is built yet. The intent is captured here so it shapes decisions made earlier (e.g., keeping the DSL identifiers stable, tagging consistently so automation can match).

## Extending

When a new service lands, add it as a container inside the right group, plus a containerInstance inside the VM's Docker engine (or systemd/kernel) deployment node, plus any relationships. Example adding `redis` on `lab-datastore`:

```dsl
group "Data tier (lab-datastore)" {
    // existing postgres, minio, restic...
    redis = container "Redis" "Cache + pub/sub" "Docker: redis:7-alpine" {
        tags "Docker,Planned"
    }
}

// in the deployment environment, inside lab-datastore's Docker engine:
dockerDS = deploymentNode "Docker engine" {
    containerInstance homeLab.redis
    // ...existing
}

homeLab.k3sAgent01 -> homeLab.redis "Cache reads/writes" "TCP 6379"
```

Drop the `Planned` tag once the service is actually deployed. That's it, no diagram edits needed.

Rename carefully: identifiers propagate across all views, so a rename is a single source edit.
