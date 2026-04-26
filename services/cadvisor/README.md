# cAdvisor

Source-controlled artifacts for the container-metrics agent on every Docker host.

## Deployed on

`lab-gateway`, `lab-datastore`, `lab-platform-eng` as a privileged Docker container. Listens on `:8088` (not the default `:8080`, which is occupied by code-server on `lab-platform-eng`).

## What it does

Exports per-container metrics on a Prometheus-scrapeable endpoint. CPU/memory/disk/network usage broken out by container name, image, and Docker labels. Pairs with node_exporter (host-level) and the service exporters (postgres/redis/nginx/minio metrics) to give a full picture of what's using resources and where.

## Why privileged + heavy bind mounts

cAdvisor reaches into the host kernel's cgroups and the Docker socket to read accounting data. The bind mounts (`/`, `/var/run`, `/sys`, `/var/lib/docker`, `/dev/disk`) and `--privileged` are how it gets there. The trade-off is that the container has near-root view of the host. Acceptable for a single-operator lab; in production you'd run cAdvisor with stricter capabilities and selinux/apparmor profiles.

## Layout

```
services/cadvisor/
  README.md            You are here
  deploy-all.ps1       PowerShell loop: docker run on the three Docker hosts
```

No source-controlled config; cAdvisor's defaults are sane for our scale, and the few flags we change (housekeeping interval, docker-only) are passed on the command line in the deploy script.

## Deploy / update

### First-time install across all Docker hosts

From Windows host:

```powershell
C:\vmimages\services\cadvisor\deploy-all.ps1
```

Walks each Docker host, removes any old `cadvisor` container, runs the new one bound to `<lab-ip>:8088`, smoke-tests by curling `/metrics`.

### Reloading Prometheus afterward

The Prometheus config already has the cAdvisor scrape entries. After cAdvisor is running:

```powershell
ssh lab-platform-eng "curl -X POST http://localhost:9090/-/reload"
```

Or just wait the next scrape interval (15s) and Prometheus will start succeeding against the targets.

### Updating the image

Edit `$image` in `deploy-all.ps1`, re-run. The script's `docker rm -f cadvisor` clears the old container before the new one starts.

## Security notes

- `--privileged` and the bind mounts make cAdvisor a high-trust container. Do not run untrusted images on the same hosts. (We don't.)
- Port binding `<lab-ip>:8088` (lab subnet only). Not exposed to home network or internet.
- No auth on `/metrics`. Anyone on the lab subnet can read container stats. Acceptable for a single-operator lab.
- `--docker_only=true` skips the LXC, containerd outside Docker, and other code paths. Smaller attack surface, faster scrapes.

## Gotchas

- **Port 8080 conflicts with code-server** on `lab-platform-eng`. We use `:8088` everywhere to keep the Prometheus config uniform. If you ever change this, update both `prometheus.yml` and `deploy-all.ps1`.
- **The container needs `/dev/kmsg`**. Without `--device=/dev/kmsg`, cAdvisor logs a stream of "missing kernel ring buffer" warnings.
- **First scrape after deploy is slow** (cAdvisor builds its initial inventory). Give it 30 seconds before deciding it's broken.
- **Memory cap of 256 MB** is comfortable for our scale. cAdvisor's memory usage scales with container count and series cardinality. If we ever run dozens of containers per host, raise the cap.
