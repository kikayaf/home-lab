# Loki

Source-controlled artifacts for the Loki log-aggregation server on `lab-platform-eng`.

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on `labnet`. Data at `/srv/loki/data`, config at `/srv/loki/conf/loki-config.yml`. Reached internally via `loki:3100` over labnet, and externally via `192.168.100.208:3100` for Promtail clients on other VMs.

## What it does

Stores logs shipped by Promtail (and only Promtail; nothing else writes to it). Grafana queries Loki via LogQL to render log panels and the Explore view. No external HTTP exposure: no nginx vhost. Querying happens through Grafana, ingestion happens from internal Promtail clients.

## Directory layout

```
/srv/loki/
  data/                 TSDB index, chunks, compactor working dir, rules
  conf/
    loki-config.yml     Source from services/loki/loki-config.yml
```

Ownership: UID 10001 (the `loki` user inside the official image).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/loki/{data,conf} && sudo chown -R 10001:10001 /srv/loki"

scp C:\vmimages\services\loki\loki-config.yml lab-platform-eng:/tmp/loki-config.yml
ssh lab-platform-eng "sudo mv /tmp/loki-config.yml /srv/loki/conf/loki-config.yml && sudo chown 10001:10001 /srv/loki/conf/loki-config.yml"
```

On `lab-platform-eng`:

```bash
docker network create labnet 2>/dev/null || true

docker run -d \
    --name loki \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:3100:3100 \
    -v /srv/loki/data:/loki \
    -v /srv/loki/conf/loki-config.yml:/etc/loki/loki-config.yml:ro \
    --user 10001:10001 \
    --memory 512m \
    grafana/loki:3.4.1 \
    -config.file=/etc/loki/loki-config.yml
```

### Reloading config

Loki doesn't have an in-place reload endpoint by default. Restart the container after editing `loki-config.yml`:

```bash
docker rm -f loki
docker run ...
```

Data survives because `/loki` is bind-mounted.

### Updating the image

```bash
docker pull grafana/loki:3.4.1
docker rm -f loki
docker run ...
```

## Connecting

### From Promtail (push logs)

`http://192.168.100.208:3100/loki/api/v1/push`. Configured in [`../promtail/promtail-config.yml`](../promtail/promtail-config.yml).

### From Grafana (read logs)

`http://loki:3100` over labnet (container DNS). Provisioned as a data source in [`../grafana/provisioning/datasources/loki.yml`](../grafana/provisioning/datasources/loki.yml).

### From a CLI

```bash
# On lab-platform-eng
curl -sG http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={host="lab-gateway"}' \
    --data-urlencode 'start='$(date -u -d '5 minutes ago' +%s)'000000000' | jq
```

## Security notes

- No auth (`auth_enabled: false`). Anyone on the lab subnet can read or write logs. Acceptable for a single-operator lab. For multi-tenant, set `auth_enabled: true` and front with nginx + basic auth or Cloudflare Access.
- Port binding `192.168.100.208:3100` (lab subnet only). Not exposed to home network or internet.
- No TLS on the push endpoint. Promtail clients send logs in cleartext over the lab network.
- Bind-mount data directory is owned by UID 10001 to match the image. Don't `sudo rm -rf /srv/loki/data` and re-create without re-chowning.

## Gotchas

- **Schema config dates are immutable**. Once `from: 2026-04-26` is set with `schema: v13`, never edit that entry. To change schema, add a new entry with a future `from` date and let Loki migrate.
- **Retention requires the compactor**. `retention_period: 336h` in `limits_config` only kicks in if the compactor is running with `retention_enabled: true` (it is in our config). Without that block, logs accumulate forever.
- **Monolithic mode is fine for a lab** but doesn't scale. If we ever need >1 GB/day of ingestion, look at the simple-scalable mode (separate read/write/backend processes).
- **Disk usage** scales with chunk + index size. Watch `/srv/loki/data` on lab-platform-eng. Alert is in step 3.12.7.
- **Old samples rejected** at 168h (7 days) by default. If a host's clock is way off, its logs get rejected. node_exporter clock-skew alerts catch this.
