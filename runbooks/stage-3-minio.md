# Stage 3, Step 6: MinIO on lab-datastore

## Goal

Stand up S3-compatible object storage on `lab-datastore`, exposed at `http://s3.lab.local` (API) and `http://minio.lab.local` (console). Complement to Postgres from step 3.5; together they cover the two most common state needs apps have (relational + blob).

## Architecture change

**Before:** nowhere to put blobs (uploads, model artifacts, logs, backups). Apps would have to bring their own.

**After:** any app can point its S3 SDK at `http://s3.lab.local` with a per-app user/password and write to its own bucket. Admin UI at `http://minio.lab.local` for operators.

## Prerequisites

- Stage 2 complete.
- Docker on `lab-datastore` (installed in step 3.5).
- nginx reverse proxy on lab-gateway with wildcard DNS for `*.lab.local` (stages 2 + 3.6).

## Step 3.6.1: Directory + credentials

```bash
ssh lab-datastore

sudo mkdir -p /srv/minio/data

MINIO_USER='labadmin'
MINIO_PASS=$(openssl rand -base64 32)
echo "MINIO_ROOT_USER=$MINIO_USER"
echo "MINIO_ROOT_PASSWORD=$MINIO_PASS"
```

Save both in a password manager. MinIO won't accept `admin` as the username (reserved), so we use `labadmin`.

## Step 3.6.2: Run the MinIO container

```bash
docker run -d \
    --name minio \
    --restart unless-stopped \
    -p 192.168.100.205:9000:9000 \
    -p 192.168.100.205:9001:9001 \
    -e MINIO_ROOT_USER="$MINIO_USER" \
    -e MINIO_ROOT_PASSWORD="$MINIO_PASS" \
    -e MINIO_BROWSER_REDIRECT_URL=http://minio.lab.local \
    -e TZ=America/Los_Angeles \
    -v /srv/minio/data:/data \
    minio/minio:latest \
    server /data --console-address ':9001'
```

Image version after first pull: `RELEASE.2025-09-07T16-13-09Z`. Pin via `docker inspect minio --format '{{.Config.Image}}'` and re-deploy with that exact tag in a follow-up commit.

### Design notes

- **Two ports**: 9000 is the S3 API, 9001 is the browser console. Keep them separate; MinIO's own defaults.
- **Bind to `192.168.100.205:*`**: lab subnet only. Not reachable from home network or internet directly.
- **`MINIO_BROWSER_REDIRECT_URL`**: required when the console lives behind a reverse proxy. Without it, MinIO redirects users to its own `192.168.100.205:9001`, which is only reachable from inside the lab and breaks the clean `minio.lab.local` URL story.
- **Bind mount at `/srv/minio/data`**: the sole stateful piece. Container restarts, upgrades, or replacements don't touch it.

### Verify

```bash
docker ps --filter name=minio
docker logs minio --tail 30

curl -I http://192.168.100.205:9000/minio/health/live
# HTTP/1.1 200 OK
```

Logs should show `Status: 1 Online, 0 Offline` and the S3-API + WebUI URLs.

## Step 3.6.3: nginx vhosts

Two vhosts, one per MinIO port. Configs at [`../services/nginx/conf.d/s3.conf`](../services/nginx/conf.d/s3.conf) and [`../services/nginx/conf.d/minio.conf`](../services/nginx/conf.d/minio.conf).

### Deploy from Windows

```powershell
scp C:\vmimages\services\nginx\conf.d\s3.conf    lab-gateway:/tmp/s3.conf
scp C:\vmimages\services\nginx\conf.d\minio.conf lab-gateway:/tmp/minio.conf
ssh lab-gateway "sudo mv /tmp/s3.conf /opt/nginx/conf.d/s3.conf && sudo mv /tmp/minio.conf /opt/nginx/conf.d/minio.conf && sudo chmod 644 /opt/nginx/conf.d/s3.conf /opt/nginx/conf.d/minio.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

### Config highlights

**s3.conf** (API):

- `client_max_body_size 0`: no upload size limit. S3 objects are big.
- `proxy_buffering off`, `proxy_request_buffering off`: streaming uploads don't get staged in nginx's buffer.
- Long timeouts (300s): multi-GB transfers shouldn't get killed mid-stream.
- `proxy_http_version 1.1` + `Connection ""`: required for S3 clients using keepalive and chunked transfer encoding.

**minio.conf** (console):

- WebSocket upgrade headers: the console uses WS for real-time updates.
- Same large-body + timeout settings as S3 since the console can also handle uploads.

## Step 3.6.4: Verify from Mac

```bash
dig s3.lab.local +short           # 192.168.100.201
dig minio.lab.local +short        # 192.168.100.201

curl -I http://s3.lab.local/minio/health/live
# HTTP/1.1 200 OK, with MinIO's X-Amz-* headers preserved

open http://minio.lab.local/
# Browser console login, labadmin + generated password
# Create a test bucket, upload a file, confirm it appears
```

Bucket creation + upload confirms: DNS → nginx → WebSocket upgrade → MinIO console → backend disk write. That's the whole stack in one click.

## Deployed configuration artifacts

- **MinIO container**: `minio/minio:RELEASE.2025-09-07T16-13-09Z`, ports `192.168.100.205:9000,9001`.
- **Data** at `/srv/minio/data` on lab-datastore. Bucket contents live here.
- **nginx vhosts**: `s3.lab.local` (API), `minio.lab.local` (console).

## Common operations

### Install the MinIO CLI (`mc`)

`mc` is the MinIO/S3 CLI. Install it anywhere in the lab (lab-gateway is handy):

```bash
ssh lab-gateway
curl -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc
sudo mv /tmp/mc /usr/local/bin/mc
sudo chmod +x /usr/local/bin/mc

# Set up an alias for our MinIO instance
mc alias set labminio http://s3.lab.local labadmin '<paste-root-password>'

# Test
mc admin info labminio
```

### Create a bucket

```bash
mc mb labminio/myapp-bucket
mc ls labminio/
```

### Create a per-app user with scoped access

```bash
mc admin user add labminio myapp-user '<app-specific-password>'
mc admin policy attach labminio readwrite --user myapp-user
```

App then connects with `myapp-user` creds against `http://s3.lab.local`, region doesn't matter (`us-east-1` is convention; MinIO ignores region).

### Mirror a local directory into a bucket

```bash
mc mirror /some/local/path labminio/myapp-bucket/
```

### Use as a Loki chunk store

`loki.yaml`:

```yaml
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  aws:
    endpoint: s3.lab.local
    bucketnames: loki-chunks
    access_key_id: loki-user
    secret_access_key: loki-user-password
    s3forcepathstyle: true
    insecure: true
```

## Gotchas

**A. MinIO rejects `admin` as root username.** Reserved word. Use anything else (`labadmin`, `root`, `mc`, etc.).

**B. `MINIO_BROWSER_REDIRECT_URL` is required when proxied.** Without it, the console redirects users to the internal `192.168.100.205:9001` address after login; clients outside the lab subnet can't reach that, so they see a hung browser.

**C. S3 clients need `s3forcepathstyle: true` (or equivalent) for MinIO.** AWS SDKs default to virtual-host-style addressing (`<bucket>.s3.lab.local`). MinIO supports both, but forcing path style (`s3.lab.local/<bucket>`) avoids DNS wildcard edge cases.

**D. S3 API doesn't use the console password.** Root credentials work for both ports, but any per-app user you create (`mc admin user add`) has its own access key and secret. Apps talk to `s3.lab.local` with app keys; humans talk to `minio.lab.local` with root or admin users.

**E. MinIO community edition has been shedding features.** If a feature disappears between versions, check release notes. Alternative OSS projects (Garage, SeaweedFS) exist if we ever hit that wall; MinIO is still the easiest for S3 compatibility today.

## Next

From the remaining data-tier in [`../BACKLOG.md`](../BACKLOG.md):

- **Redis** on lab-datastore (`stage-3-redis.md`, planned). Cache + simple queue.
- **restic** + cron for `pg_dumpall` and `/srv/` snapshots, targeting this MinIO as one of the backup destinations (automated backups, planned).
- **Structurizr Lite** on lab-platform-eng (closes self-documenting loop).
- **Observability stack** (Prometheus + Grafana + Loki). Loki would use this MinIO as chunk storage.
