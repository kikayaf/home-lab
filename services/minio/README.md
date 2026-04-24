# MinIO (S3-compatible object storage)

Source-controlled artifacts for the MinIO instance on `lab-datastore`.

## Deployed on

`lab-datastore` (`192.168.100.205`) as a Docker container. Data lives at `/srv/minio/data`.

## What it serves

- **S3 API** on port `9000`, exposed through nginx at `http://s3.lab.local`. Apps point their S3 client at this URL for object storage.
- **Web console** on port `9001`, exposed through nginx at `http://minio.lab.local`. Browser UI for creating buckets, managing users, inspecting objects.

## What to use it for

- Application blob storage (uploads, generated files).
- Loki chunk storage (when observability stack lands).
- Prometheus remote-write for long-term metrics (if we go that route).
- restic backup target (once backup automation lands).
- Model artifacts for AI workloads.
- Static site hosting (MinIO can serve public-read buckets as websites).

## Directory layout on `lab-datastore`

```
/srv/minio/
  data/          MinIO backend storage (mounted at /data in the container)
                 Bucket contents live here as nested directories and files.
```

Ownership is kept as `root` because MinIO's container image runs as root by default. If we ever switch to a non-root entrypoint, we'll `chown -R 1000:1000 /srv/minio`.

## Deploy / update

### First-time install

```bash
ssh lab-datastore

# Prepare directory
sudo mkdir -p /srv/minio/data

# Generate admin credentials
MINIO_USER='labadmin'            # can be anything except 'admin'
MINIO_PASS=$(openssl rand -base64 32)
echo "user: $MINIO_USER"
echo "pass: $MINIO_PASS"
# SAVE BOTH in your password manager before moving on.
```

Run the container (pin the image tag to whatever's current stable on Docker Hub at install time):

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

Version pin: after the first pull, run `docker inspect minio --format '{{.Config.Image}}'`, replace `latest` with the specific `RELEASE.YYYY-MM-DDTHH-MM-SSZ` tag and re-run. Version pinning + periodic bumps > floating latest.

### Upgrade path

MinIO does in-place version upgrades well; stop old container, start new one pointing at the same `/srv/minio/data`. Downgrades are NOT supported; check upstream release notes before jumping a major version.

## Bootstrap: create a bucket and user for an app

With the MinIO CLI (`mc`) installed locally, or via the web console at `http://minio.lab.local`:

```bash
# Install mc (once, anywhere on the lab)
curl -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x /usr/local/bin/mc

# Configure an alias for our MinIO instance
mc alias set labminio http://s3.lab.local labadmin '<paste-root-password>'

# Create a bucket
mc mb labminio/myapp-bucket

# Create a user with scoped access
mc admin user add labminio myapp-user '<app-password>'
mc admin policy attach labminio readwrite --user myapp-user
```

App connects with these credentials against `http://s3.lab.local` as the endpoint. Region can be anything (MinIO ignores it but SDKs require one; `us-east-1` is conventional).

## Security notes

- Root credentials are the administrative master key. Store in password manager. Rotate by `docker exec minio mc admin user rotate ...` (see docs) if suspected.
- Per-app users with scoped policies beat sharing the root credentials.
- No TLS on the S3/console ports today. Internal-only over the lab subnet + Tailscale. Add TLS when we set up wildcard `*.lab.local` certs.
- Port binding is `192.168.100.205:9000/9001` (lab subnet) not `0.0.0.0`. Home network and public internet can't reach it directly.

## Gotchas

- **MinIO refuses trivial passwords.** Root password must be at least 8 characters; the `openssl rand -base64 32` output is fine.
- **Can't use username `admin`.** MinIO reserves that. Use `labadmin`, `root`, or whatever.
- **`MINIO_BROWSER_REDIRECT_URL`** is important when the console is behind a reverse proxy: without it, MinIO console redirects to its own port number and breaks behind nginx.
