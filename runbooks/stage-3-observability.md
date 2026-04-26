# Stage 3, Step 12: Observability stack

## Goal

Stand up Prometheus + Grafana + Loki + Alertmanager on `lab-platform-eng` with metric exporters on every VM and per-service exporters for the data tier. End state: every VM and every important workload reports CPU/memory/disk + service-specific metrics + logs to one place, with rule-based alerts and a single overview dashboard pinned to home.

## Architecture change

**Before (end of step 3.11):** every workload was a black box. Knowing whether Postgres was healthy meant SSHing to lab-datastore and running `psql`. Knowing whether disk was filling on lab-automation meant SSHing there and running `df`. No alerts, no central log search, no time-series history.

**After:**

- Prometheus on `lab-platform-eng:9090`, retention 30 days, scraping eight node_exporters + four service exporters (postgres, redis, nginx, MinIO native) + self/grafana/alertmanager/loki on a 15s interval.
- Grafana on `lab-platform-eng:3000`, behind nginx at `https://grafana.lab.local`, with provisioned Prometheus + Loki data sources and six dashboards in the Lab folder.
- Loki on `lab-platform-eng:3100`, Promtail as a systemd binary on every VM shipping journald + nginx + Docker container logs.
- Alertmanager on `lab-platform-eng:9093`, behind nginx at `https://alerts.lab.local`, routing all alerts to a "log only" receiver until rules are tuned.
- Alert rules: instance down, high CPU, high memory, disk almost full, disk filling fast, clock skew, failed systemd units, postgres/redis/nginx/minio down, plus self-monitoring.

## Prerequisites

- Stage 3.10 wildcard TLS at `*.lab.local` (used for `prom.lab.local`, `grafana.lab.local`, `alerts.lab.local`).
- Docker on `lab-platform-eng` with the `labnet` network created on first deploy.
- Postgres, Redis, MinIO, Vaultwarden already up so we have something interesting to scrape.

## Port allocations

| Service              | Host             | Port                          |
|----------------------|------------------|-------------------------------|
| Prometheus           | lab-platform-eng | 9090                          |
| Grafana              | lab-platform-eng | 3000                          |
| Loki                 | lab-platform-eng | 3100                          |
| Alertmanager         | lab-platform-eng | 9093                          |
| node_exporter        | every VM         | 9100                          |
| Promtail             | every VM         | 9080 (readiness only)         |
| postgres_exporter    | lab-datastore    | 9187                          |
| redis_exporter       | lab-datastore    | 9121                          |
| nginx-prom-exporter  | lab-gateway      | 9113                          |
| nginx stub_status    | lab-gateway      | 8090 (in container only)      |

## Step 3.12.1: Prometheus + Grafana on lab-platform-eng

Source artifacts: [`../services/prometheus/`](../services/prometheus/) and [`../services/grafana/`](../services/grafana/).

Push configs and create directories:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/prometheus/{data,conf/rules,conf/secrets} && sudo chown -R 65534:65534 /srv/prometheus"
scp C:\vmimages\services\prometheus\prometheus.yml lab-platform-eng:/tmp/prometheus.yml
ssh lab-platform-eng "sudo mv /tmp/prometheus.yml /srv/prometheus/conf/prometheus.yml && sudo chown 65534:65534 /srv/prometheus/conf/prometheus.yml"

ssh lab-platform-eng "sudo mkdir -p /srv/grafana/{data,dashboards} /srv/grafana/provisioning/{datasources,dashboards} && sudo chown -R 472:472 /srv/grafana"
scp C:\vmimages\services\grafana\provisioning\datasources\prometheus.yml lab-platform-eng:/tmp/grafana-ds.yml
scp C:\vmimages\services\grafana\provisioning\dashboards\dashboards.yml lab-platform-eng:/tmp/grafana-dash.yml
ssh lab-platform-eng "sudo mv /tmp/grafana-ds.yml /srv/grafana/provisioning/datasources/prometheus.yml && sudo mv /tmp/grafana-dash.yml /srv/grafana/provisioning/dashboards/dashboards.yml && sudo chown -R 472:472 /srv/grafana/provisioning"
```

Then on `lab-platform-eng`, generate the Grafana admin password (save in Vaultwarden) and start both containers:

```bash
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

GRAFANA_ADMIN_PASS=$(openssl rand -base64 32)
echo "GRAFANA_ADMIN_PASS=$GRAFANA_ADMIN_PASS"
# SAVE to Vaultwarden as "Grafana admin (lab-platform-eng)"

docker run -d \
    --name grafana \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:3000:3000 \
    -v /srv/grafana/data:/var/lib/grafana \
    -v /srv/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v /srv/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    -e GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASS" \
    -e GF_USERS_ALLOW_SIGN_UP=false \
    -e GF_AUTH_ANONYMOUS_ENABLED=false \
    -e GF_SERVER_ROOT_URL=https://grafana.lab.local \
    -e GF_SERVER_DOMAIN=grafana.lab.local \
    -e GF_ANALYTICS_REPORTING_ENABLED=false \
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e TZ=America/Los_Angeles \
    --user 472:472 \
    --memory 512m \
    grafana/grafana:11.3.0
```

Push the nginx vhosts (the live mount is `/opt/nginx/conf.d/`, not `/srv/nginx/conf.d/` - first-deploy gotcha):

```powershell
scp C:\vmimages\services\nginx\conf.d\prom.conf    lab-gateway:/tmp/prom.conf
scp C:\vmimages\services\nginx\conf.d\grafana.conf lab-gateway:/tmp/grafana.conf
ssh lab-gateway "sudo mv /tmp/prom.conf /opt/nginx/conf.d/prom.conf && sudo mv /tmp/grafana.conf /opt/nginx/conf.d/grafana.conf && sudo chown root:root /opt/nginx/conf.d/prom.conf /opt/nginx/conf.d/grafana.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

Verify: `https://prom.lab.local` and `https://grafana.lab.local` open. Login admin / saved password.

## Step 3.12.2: node_exporter on all eight VMs

Source: [`../services/node-exporter/`](../services/node-exporter/).

```powershell
C:\vmimages\services\node-exporter\deploy-all.ps1
```

Walks every VM in turn, scp's `install.sh`, runs it as adminuser. Each VM ends with `[<host>] node_exporter OK on :9100`.

Verify: `https://prom.lab.local/targets` shows `node` 8/8 up.

## Step 3.12.3: Node Exporter Full dashboard (1860)

```powershell
ssh lab-platform-eng @'
set -e
curl -fsSL https://grafana.com/api/dashboards/1860/revisions/latest/download \
    | sed 's/${DS_PROMETHEUS}/Prometheus/g' \
    | jq 'del(.__inputs, .__requires)' \
    | sudo tee /srv/grafana/dashboards/node-exporter-full-1860.json > /dev/null
sudo chown 472:472 /srv/grafana/dashboards/node-exporter-full-1860.json
'@

scp lab-platform-eng:/srv/grafana/dashboards/node-exporter-full-1860.json C:\vmimages\services\grafana\dashboards\node-exporter-full-1860.json
```

Datasource UID is pinned to `Prometheus` in `services/grafana/provisioning/datasources/prometheus.yml`; that's why the sed-replace lands on `Prometheus` (the literal UID).

Verify: Grafana > Dashboards > Lab > Node Exporter Full populates with all eight hosts in the picker.

## Step 3.12.4: cAdvisor (deferred)

Tried both `gcr.io/cadvisor/cadvisor:v0.49.1` and `:v0.51.0`. Both hardcode `/rootfs/var/lib/docker/image/overlayfs/layerdb/` in the Docker storage-driver lookup, but modern Docker uses `overlay2`. A symlink workaround silenced the layerdb errors but per-container scopes still didn't surface as Prometheus series. With dropping `--docker_only=true` we get systemd-slice cgroup metrics but not Docker container series.

For a lab this size, the gap is small: node_exporter covers host totals, the per-service exporters cover Postgres/Redis/nginx/MinIO/Loki/Grafana/Alertmanager, and `docker stats` covers ad-hoc per-container checks. Tracked in BACKLOG > Ideas worth revisiting > "Per-container metrics".

## Step 3.12.5: Service exporters

Source: [`../services/exporters/`](../services/exporters/).

### postgres_exporter (lab-datastore)

```bash
PGEXP_PASS=$(openssl rand -base64 32)
echo "PGEXP_PASS=$PGEXP_PASS"
# Save to Vaultwarden as "Postgres exporter user (lab-datastore)"

docker exec -i postgres psql -U postgres <<EOF
CREATE USER postgres_exporter WITH PASSWORD '$PGEXP_PASS';
ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;
GRANT pg_monitor TO postgres_exporter;
EOF

docker run -d \
    --name postgres_exporter \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.205:9187:9187 \
    -e DATA_SOURCE_NAME="postgresql://postgres_exporter:$PGEXP_PASS@postgres:5432/postgres?sslmode=disable" \
    --memory 128m \
    prometheuscommunity/postgres-exporter:v0.16.0
```

### redis_exporter (lab-datastore)

The Redis container was originally on the default bridge network. Attach it to `labnet` so the exporter can reach it by name:

```bash
docker network connect labnet redis

docker run -d \
    --name redis_exporter \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.205:9121:9121 \
    -e REDIS_ADDR="redis:6379" \
    -e REDIS_PASSWORD='<from-Vaultwarden>' \
    --memory 64m \
    oliver006/redis_exporter:v1.66.0
```

Note the bare `host:port` form for `REDIS_ADDR`. The `redis://host:port` URL form fails with "unknown network redis" on this exporter version because Go's `net.Dial` interprets `redis` as a network type.

### nginx-prometheus-exporter (lab-gateway)

```powershell
scp C:\vmimages\services\nginx\conf.d\stub_status.conf lab-gateway:/tmp/stub_status.conf
ssh lab-gateway "sudo mv /tmp/stub_status.conf /opt/nginx/conf.d/stub_status.conf && sudo chown root:root /opt/nginx/conf.d/stub_status.conf && docker exec nginx nginx -t && docker exec nginx nginx -s reload"
ssh lab-gateway "docker network create labnet 2>/dev/null; docker network connect labnet nginx 2>/dev/null; echo done"
```

The stub_status listener binds to port 8090 inside the nginx container's namespace (no IP, since the host's lab IP doesn't exist inside the container). The exporter reaches it via labnet container DNS, so no host port mapping is needed for stub_status itself.

```bash
docker run -d \
    --name nginx_exporter \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.201:9113:9113 \
    --memory 32m \
    nginx/nginx-prometheus-exporter:1.3.0 \
    --nginx.scrape-uri=http://nginx:8090/stub_status
```

### MinIO native metrics

Install `mc` on lab-datastore and generate a Prometheus bearer token:

```bash
sudo curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
sudo chmod +x /usr/local/bin/mc
mc alias set lab http://192.168.100.205:9000 labadmin '<MinIO root password from Vaultwarden>'
mc admin prometheus generate lab cluster
```

Copy the `bearer_token:` value (long JWT). Save to Vaultwarden as "MinIO Prometheus bearer token (lab-datastore)". Then place on lab-platform-eng:

```bash
echo '<token>' | sudo tee /srv/prometheus/conf/secrets/minio_bearer_token > /dev/null
sudo chmod 600 /srv/prometheus/conf/secrets/minio_bearer_token
sudo chown 65534:65534 /srv/prometheus/conf/secrets/minio_bearer_token

docker exec prometheus kill -HUP 1
```

The `prometheus.yml` minio job hits MinIO directly at `192.168.100.205:9000` over HTTP (not via nginx at s3.lab.local). nginx doesn't pass the Authorization header through reliably for the metrics endpoint.

### Dashboards (postgres 9628, redis 763, nginx 12708, MinIO 13502)

Same fetch + sed + jq pipeline as the Node Exporter Full dashboard. PowerShell + bash space-quoting will mangle a `for` loop with multi-token strings; use a separator that survives parsing or run each fetch on its own line.

## Step 3.12.6: Loki + Promtail

Source: [`../services/loki/`](../services/loki/) and [`../services/promtail/`](../services/promtail/).

Stand up Loki:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/loki/{data,conf} && sudo chown -R 10001:10001 /srv/loki"
scp C:\vmimages\services\loki\loki-config.yml lab-platform-eng:/tmp/loki-config.yml
ssh lab-platform-eng "sudo mv /tmp/loki-config.yml /srv/loki/conf/loki-config.yml && sudo chown 10001:10001 /srv/loki/conf/loki-config.yml"
```

```bash
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

Provision the Loki data source in Grafana:

```powershell
scp C:\vmimages\services\grafana\provisioning\datasources\loki.yml lab-platform-eng:/tmp/grafana-loki-ds.yml
ssh lab-platform-eng "sudo mv /tmp/grafana-loki-ds.yml /srv/grafana/provisioning/datasources/loki.yml && sudo chown 472:472 /srv/grafana/provisioning/datasources/loki.yml && docker restart grafana"
```

Roll out Promtail:

```powershell
C:\vmimages\services\promtail\deploy-all.ps1
```

Verify in Grafana > Explore > Loki:

```
{job="systemd-journal"}
```

## Step 3.12.7: Alertmanager + alert rules

Source: [`../services/alertmanager/`](../services/alertmanager/) and [`../services/prometheus/rules/`](../services/prometheus/rules/).

Stand up Alertmanager:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/alertmanager/{data,conf} && sudo chown -R 65534:65534 /srv/alertmanager"
scp C:\vmimages\services\alertmanager\alertmanager.yml lab-platform-eng:/tmp/alertmanager.yml
ssh lab-platform-eng "sudo mv /tmp/alertmanager.yml /srv/alertmanager/conf/alertmanager.yml && sudo chown 65534:65534 /srv/alertmanager/conf/alertmanager.yml"
```

```bash
docker run -d \
    --name alertmanager \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:9093:9093 \
    -v /srv/alertmanager/data:/alertmanager \
    -v /srv/alertmanager/conf:/etc/alertmanager:ro \
    --user 65534:65534 \
    --memory 128m \
    prom/alertmanager:v0.27.0 \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/alertmanager \
    --web.external-url=https://alerts.lab.local
```

Push rules and the updated `prometheus.yml` (which enables Alertmanager + adds scrapes for Alertmanager and Loki):

```powershell
scp C:\vmimages\services\prometheus\rules\node-alerts.yml    lab-platform-eng:/tmp/node-alerts.yml
scp C:\vmimages\services\prometheus\rules\service-alerts.yml lab-platform-eng:/tmp/service-alerts.yml
scp C:\vmimages\services\prometheus\prometheus.yml           lab-platform-eng:/tmp/prometheus.yml

ssh lab-platform-eng @'
sudo mv /tmp/node-alerts.yml /srv/prometheus/conf/rules/node-alerts.yml
sudo mv /tmp/service-alerts.yml /srv/prometheus/conf/rules/service-alerts.yml
sudo mv /tmp/prometheus.yml /srv/prometheus/conf/prometheus.yml
sudo chown 65534:65534 /srv/prometheus/conf/rules/*.yml /srv/prometheus/conf/prometheus.yml
docker exec prometheus kill -HUP 1
'@
```

Push the alerts vhost:

```powershell
scp C:\vmimages\services\nginx\conf.d\alerts.conf lab-gateway:/tmp/alerts.conf
ssh lab-gateway "sudo mv /tmp/alerts.conf /opt/nginx/conf.d/alerts.conf && sudo chown root:root /opt/nginx/conf.d/alerts.conf && docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

Verify: `https://alerts.lab.local` opens the Alertmanager UI; `https://prom.lab.local/alerts` lists all rules from both files.

## Step 3.12.8: Lab Overview dashboard

```powershell
scp C:\vmimages\services\grafana\dashboards\lab-overview.json lab-platform-eng:/tmp/lab-overview.json
ssh lab-platform-eng "sudo mv /tmp/lab-overview.json /srv/grafana/dashboards/lab-overview.json && sudo chown 472:472 /srv/grafana/dashboards/lab-overview.json"
```

Wait ~30s for Grafana to provision. Open Dashboards > Lab > Lab Overview. Pin as home dashboard.

## Verification end to end

- `https://prom.lab.local/targets` (Healthy filter): 14 targets up
  - prometheus (1), grafana (1), alertmanager (1), loki (1)
  - node (8), postgres (1), redis (1), nginx (1), minio (1)
- `https://prom.lab.local/alerts`: 16 rules listed across 4 groups, none firing initially
- `https://alerts.lab.local`: empty (no firing alerts)
- `https://grafana.lab.local` > Dashboards > Lab folder: 6 dashboards (Lab Overview, Node Exporter Full, PostgreSQL, Redis, NGINX, MinIO)
- `https://grafana.lab.local` > Explore > Loki: `{host="lab-gateway"}` returns recent journal lines

## Common gotchas

- **The live nginx mount is `/opt/nginx/conf.d/`, not `/srv/nginx/conf.d/`.** Pushing a vhost to `/srv/nginx/...` is silently ineffective; nginx is reading a different directory.
- **Prometheus / Grafana / Loki / Alertmanager containers all bind to `192.168.100.208:<port>`, not `0.0.0.0`.** The Tailscale Funnel workaround established this pattern. Curl from the host has to use the lab IP, not localhost.
- **PowerShell + ssh + bash + jq quoting eats double quotes.** When a one-liner fails with "invalid char escape" or "unknown jq function" matching a quoted argument, switch to either an `@'...'@` here-string or skip the API and use the browser.
- **The Promtail config `match` stage is fragile around regex escaping.** We dropped that pipeline entirely; per-stream labeling can be done with LogQL in queries instead.
- **The Grafana data source UID gets pinned to `Prometheus` (capital P) in `provisioning/datasources/prometheus.yml`** so dashboards that hard-code `${DS_PROMETHEUS}` from grafana.com line up after a sed substitution. If that UID changes, every imported dashboard's panels go grey.
- **The MinIO scrape goes direct to `192.168.100.205:9000`**, not through nginx at `s3.lab.local`. nginx doesn't pass the Authorization header reliably to the `/minio/v2/metrics/cluster` endpoint.
- **Sample passwords are saved as we go**: Grafana admin, postgres_exporter user, MinIO bearer token. Always to Vaultwarden, never just to chat scrollback.
