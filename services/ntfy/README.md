# ntfy

Self-hosted push-notification server. Source-controlled artifacts for the ntfy instance on `lab-platform-eng`.

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on `labnet`. Data at `/srv/ntfy/cache`, config at `/srv/ntfy/conf/server.yml`. Reached via nginx at `https://ntfy.lab.local`.

## What it does

Receives messages over HTTP and pushes them to subscribers in real-time over WebSockets / SSE / long-poll. The official ntfy mobile app (iOS / Android) and browser clients subscribe to a "topic" (just a string, like `lab-alerts`) and receive notifications instantly. Open source, self-hostable, no account needed.

In our setup:

- Alertmanager pushes to topic `lab-alerts` whenever a Prometheus rule fires
- Phone subscribes to `https://ntfy.lab.local/lab-alerts` via the ntfy app's custom-server feature
- Tailscale on the phone makes `ntfy.lab.local` resolvable from anywhere

## Directory layout

```
/srv/ntfy/
  cache/          cache.db (SQLite) and attachments/ subdir
  conf/
    server.yml    Source from services/ntfy/server.yml
```

Ownership: UID 1000 (the `ntfy` user inside the official image).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/ntfy/{cache,conf} && sudo chown -R 1000:1000 /srv/ntfy"

scp C:\vmimages\services\ntfy\server.yml lab-platform-eng:/tmp/server.yml
ssh lab-platform-eng "sudo mv /tmp/server.yml /srv/ntfy/conf/server.yml && sudo chown 1000:1000 /srv/ntfy/conf/server.yml"
```

On `lab-platform-eng`:

```bash
docker run -d \
    --name ntfy \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:8085:80 \
    -v /srv/ntfy/cache:/var/cache/ntfy \
    -v /srv/ntfy/conf/server.yml:/etc/ntfy/server.yml:ro \
    --user 1000:1000 \
    --memory 256m \
    binwiederhier/ntfy:v2.11.0 \
    serve
```

### Smoke test

```bash
# From any lab VM
curl -d "hello from the lab" https://ntfy.lab.local/lab-alerts
```

The web UI at `https://ntfy.lab.local` (subscribed to `lab-alerts`) should show the message. The mobile app, if subscribed, should buzz.

### Phone setup

1. Install the ntfy app (iOS App Store / Google Play / F-Droid)
2. Settings (gear icon) > "Default server" > set to `https://ntfy.lab.local`
3. Back to subscriptions, tap `+`, topic name: `lab-alerts`
4. Tailscale must be running on the phone for `ntfy.lab.local` to resolve

### Updating the image

```bash
docker pull binwiederhier/ntfy:v2.11.0
docker rm -f ntfy
docker run ...
```

Cache and config survive because they're bind-mounted.

## Connecting

### From Alertmanager (push)

`http://ntfy/?` over labnet (container DNS). Configured as a webhook receiver in [`../alertmanager/alertmanager.yml`](../alertmanager/alertmanager.yml).

### From a CLI (publish)

```bash
curl -d "deploy started" https://ntfy.lab.local/lab-alerts
curl -H "Title: Backup done" -H "Tags: white_check_mark" -d "0 errors" https://ntfy.lab.local/lab-alerts
curl -H "Priority: max" -d "DISK FULL" https://ntfy.lab.local/lab-alerts
```

### From a script (publish)

```bash
# Send a notification at the end of a long-running script
./run-backup.sh && curl -d "backup OK" https://ntfy.lab.local/lab-alerts \
                || curl -H "Priority: max" -d "backup FAILED" https://ntfy.lab.local/lab-alerts
```

## Security notes

- `auth-default-access: read-write` means anyone on the tailnet (or lab subnet) can publish to and subscribe to any topic. Acceptable for a single-operator lab. For multi-tenant or public exposure, switch to `deny-all` and provision specific tokens.
- Topic names are not auth boundaries unless you enable ACLs. Pick unguessable topic names if you ever expose ntfy publicly.
- The vhost is behind wildcard `*.lab.local` TLS, lab-subnet only.
- No external exposure. To use from outside the tailnet later, route through Cloudflare Tunnel + Cloudflare Access.

## Gotchas

- **Phone can't resolve `ntfy.lab.local` without Tailscale**. If notifications stop arriving on cellular data, check the Tailscale switch on the phone. Fallback: use ntfy.sh hosted with a random topic until we have Cloudflare Tunnel.
- **`behind-proxy: true` matters** when behind nginx. Without it, every request looks like it's coming from the nginx container's IP and rate limits trigger immediately.
- **Topic name `lab-alerts` is hardcoded in alertmanager.yml**. Change one place, change the other.
- **Attachment uploads** are limited to 15 MB and total 5 GB cache. We don't push attachments today; raise limits if we ever do.
- **Cache duration 24h** means historical messages clear after a day. The phone app caches its own copy; no operational impact.
