# Service exporters

Source-controlled artifacts for the per-service Prometheus exporters: Postgres, Redis, nginx, and MinIO's native metrics endpoint.

## What lives where

| Exporter                       | Host             | Port | Image                                              |
|--------------------------------|------------------|------|----------------------------------------------------|
| postgres_exporter              | lab-datastore    | 9187 | `prometheuscommunity/postgres-exporter:v0.16.0`    |
| redis_exporter                 | lab-datastore    | 9121 | `oliver006/redis_exporter:v1.66.0`                 |
| nginx-prometheus-exporter      | lab-gateway      | 9113 | `nginx/nginx-prometheus-exporter:1.3.0`            |
| MinIO native `/minio/v2/...`   | lab-datastore    | 443  | (built into MinIO; no exporter container)          |

Prometheus scrape definitions live in [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml). Add new exporters here and add the matching scrape job there in the same commit.

## Deploy / update

### postgres_exporter

A dedicated read-only Postgres user with `pg_monitor` role.

On `lab-datastore`, get a password and create the user. The password lives in Vaultwarden after this:

```bash
PGEXP_PASS=$(openssl rand -base64 32)
echo "PGEXP_PASS=$PGEXP_PASS"
# SAVE in Vaultwarden as "Postgres exporter user (lab-datastore)"

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

### redis_exporter

Reads via the same Redis password we use for app connections. Uses Docker DNS on `labnet` to reach `redis:6379`.

On `lab-datastore`, supply the existing Redis password:

```bash
REDIS_PASS='<paste from Vaultwarden>'

docker run -d \
    --name redis_exporter \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.205:9121:9121 \
    -e REDIS_ADDR="redis://redis:6379" \
    -e REDIS_PASSWORD="$REDIS_PASS" \
    --memory 64m \
    oliver006/redis_exporter:v1.66.0
```

### nginx-prometheus-exporter

Two-step. First, we add an `stub_status` listener to nginx (sourced from [`../nginx/conf.d/stub_status.conf`](../nginx/conf.d/stub_status.conf)). Second, we run the exporter pointed at it.

From Windows host (push the new vhost):

```powershell
scp C:\vmimages\services\nginx\conf.d\stub_status.conf lab-gateway:/tmp/stub_status.conf
ssh lab-gateway "sudo mv /tmp/stub_status.conf /opt/nginx/conf.d/stub_status.conf && sudo chown root:root /opt/nginx/conf.d/stub_status.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

On `lab-gateway`:

```bash
docker run -d \
    --name nginx_exporter \
    --restart unless-stopped \
    -p 192.168.100.201:9113:9113 \
    --memory 32m \
    nginx/nginx-prometheus-exporter:1.3.0 \
    --nginx.scrape-uri=http://192.168.100.201:8090/stub_status
```

### MinIO native metrics

MinIO already exposes `/minio/v2/metrics/cluster` (and `/node`, `/bucket`, `/resource`). It needs a bearer token. Generate one with `mc`:

```bash
# On any host with mc configured against the lab MinIO alias (e.g., lab-datastore)
mc admin prometheus generate lab cluster
# This prints a Prometheus scrape_config block; copy the bearer_token value out of it
```

Place the token in the Prometheus secrets directory:

```bash
# On lab-platform-eng
sudo bash -c 'echo "<paste-token>" > /srv/prometheus/conf/secrets/minio_bearer_token'
sudo chmod 600 /srv/prometheus/conf/secrets/minio_bearer_token
sudo chown 65534:65534 /srv/prometheus/conf/secrets/minio_bearer_token
```

The Prometheus config already has the `minio` job pointing at this file (see [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml)).

### Reload Prometheus to pick up everything

```bash
docker exec prometheus kill -HUP 1
```

Or on lab-platform-eng:

```bash
curl -X POST http://192.168.100.208:9090/-/reload
```

## Security notes

- **postgres_exporter** uses a dedicated read-only user with the `pg_monitor` role. It can read internal stats but not query application data.
- **redis_exporter** uses the same Redis password apps use. If you ever rotate the Redis password, restart `redis_exporter` with the new value.
- **nginx-prometheus-exporter** scrapes `http://192.168.100.201:8090/stub_status`, an HTTP endpoint locked down by `allow`/`deny` rules to lab subnet + Docker bridge.
- **MinIO bearer token** is a secret. Stored at `/srv/prometheus/conf/secrets/minio_bearer_token` (mode 600). Add to Vaultwarden as backup. Rotate by re-running `mc admin prometheus generate` and replacing the file.

## Gotchas

- **postgres_exporter image dropped the `--auto-discover-databases` flag** in 0.15+ - by default it only scrapes the database in the connection string. Add `PG_EXPORTER_AUTO_DISCOVER_DATABASES=true` if you want per-database metrics across all DBs.
- **redis_exporter scrapes are cheap** but `redis-cli INFO` is one of the things it triggers; if Redis is loaded, the cardinality from cluster info commands can spike. We're nowhere near that scale.
- **nginx stub_status is HTTP-only** in our setup. That's fine because the listener is bound to lab IP + 8090 with `allow` rules. If you ever expose it broader, put TLS on it.
- **MinIO bearer token expires** if the underlying user's password rotates. The token is signed with the user's secret; generating a new one creates a different token.
