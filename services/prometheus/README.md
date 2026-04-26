# Prometheus

Source-controlled artifacts for the Prometheus instance on `lab-platform-eng`.

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on `labnet`. Data at `/srv/prometheus/data`, config at `/srv/prometheus/conf/prometheus.yml`. Reached via nginx at `https://prom.lab.local`.

## What it does

Pulls metrics from every exporter in the lab on a 15-second schedule and stores them as time-series in its TSDB. Grafana queries Prometheus to draw dashboards. Alertmanager (added in step 3.12.7) consumes Prometheus alert rules.

Targets covered (filled in across steps 3.12.2 - 3.12.5):

- **node** - host metrics on all eight VMs (port 9100)
- **cadvisor** - container metrics on Docker hosts (port 8080)
- **postgres** - postgres_exporter on lab-datastore (port 9187)
- **redis** - redis_exporter on lab-datastore (port 9121)
- **nginx** - nginx-prometheus-exporter on lab-gateway (port 9113)
- **minio** - native /minio/v2/metrics/cluster on lab-datastore (port 443 over HTTPS)
- **grafana** - native /metrics on the Grafana container
- **prometheus** - its own /metrics

## Directory layout

```
/srv/prometheus/
  data/          TSDB. ~30 days retention. Mounted at /prometheus.
  conf/
    prometheus.yml         Source from services/prometheus/prometheus.yml
    rules/                 Alert rules (yml files), loaded by glob
    secrets/
      minio_bearer_token   Plain text token; chmod 600
```

Ownership: UID 65534 (the `nobody` user the prom/prometheus image runs as).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/prometheus/{data,conf/rules,conf/secrets} && sudo chown -R 65534:65534 /srv/prometheus"

scp C:\vmimages\services\prometheus\prometheus.yml lab-platform-eng:/tmp/prometheus.yml
ssh lab-platform-eng "sudo mv /tmp/prometheus.yml /srv/prometheus/conf/prometheus.yml && sudo chown 65534:65534 /srv/prometheus/conf/prometheus.yml"
```

On `lab-platform-eng`:

```bash
# labnet may already exist if this VM joined it earlier; idempotent.
docker network create labnet 2>/dev/null || true

docker run -d \
    --name prometheus \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:9090:9090 \
    -v /srv/prometheus/data:/prometheus \
    -v /srv/prometheus/conf:/etc/prometheus:ro \
    --user 65534:65534 \
    --memory 1g \
    prom/prometheus:v2.55.1 \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=30d \
    --web.console.libraries=/usr/share/prometheus/console_libraries \
    --web.console.templates=/usr/share/prometheus/consoles \
    --web.enable-lifecycle
```

`--web.enable-lifecycle` lets us reload config in-place via `curl -X POST http://localhost:9090/-/reload`.

### Reloading after a config change

```bash
# On lab-platform-eng. Picks up edits to prometheus.yml without restarting.
curl -X POST http://localhost:9090/-/reload
```

If you change command-line flags (retention, listen address, etc.), `docker rm -f prometheus` and re-run.

### Updating the image

```bash
docker pull prom/prometheus:v2.55.1   # bump tag first
docker rm -f prometheus
docker run ...                         # same command, fresh image
```

Data survives because it's in the bind mount.

## Connecting

### From another lab VM (Grafana)

Use `prometheus:9090` (container DNS on labnet). No password.

### From a browser

`https://prom.lab.local` (via nginx). Useful for ad-hoc PromQL.

### From a CLI

```bash
curl -s 'http://192.168.100.208:9090/api/v1/query?query=up' | jq
```

## Security notes

- No auth on Prometheus itself. The vhost is behind nginx with wildcard `*.lab.local` TLS, lab-subnet only. If we want stronger gating, add nginx basic auth or move it behind Cloudflare Access.
- Port binding `192.168.100.208:9090` (lab subnet only). Not exposed to home network or internet.
- MinIO scrape uses a bearer token at `/srv/prometheus/conf/secrets/minio_bearer_token`. Generated with `mc admin prometheus generate lab` on a host with `mc` configured. File mode 600, owned by 65534.
- Alert rules and config are world-readable in git. They contain no secrets.

## Gotchas

- **Retention is wall-clock, not size**. `--storage.tsdb.retention.time=30d` keeps 30 days regardless of how many series you scrape. If you start scraping 100k series, the disk fills up. Watch `/srv/prometheus/data` size; alert is in step 3.12.7.
- **Reload silently fails on bad config**. After editing `prometheus.yml`, check `docker logs prometheus --tail 20` for parse errors before assuming the reload worked.
- **Container DNS for `grafana:3000`** only works because both containers are on `labnet`. If a target ever resolves to nothing, check `docker network inspect labnet`.
- **Time-series cardinality** explodes if you accidentally label a metric with a high-variance value (request IDs, user emails). When writing alerts or recording rules, keep label values bounded.
- **Federation / remote_write** is not configured. If we want longer retention, the path is VictoriaMetrics + remote_write (see BACKLOG).
