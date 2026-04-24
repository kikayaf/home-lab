# Stage 3, Step 8: code-server on lab-platform-eng + Tailscale Funnel

## Goal

Make the lab usable from a work PC (or any machine) that can't install Tailscale. Browser is the only requirement on the client side; authentication is via a password on the service, and the transport is standard HTTPS through Tailscale's public edge.

## Architecture change

**Before:** lab reachable only from personal tailnet devices (Mac, iPad, etc.). Work PC was a dead end.

**After:** code-server (browser-based VS Code) runs on `lab-platform-eng`. Accessible two ways:

- **From tailnet**: `http://code.lab.local/` via nginx reverse proxy. Clean internal URL.
- **From public internet (including restricted work networks)**: `https://lab-gateway.<tail-hash>.ts.net/` via Tailscale Funnel. Goes directly to code-server (bypassing nginx because the hostname doesn't match any nginx vhost).

From the browser terminal inside code-server, you can `kubectl`, `ssh lab-datastore`, edit files in the lab, etc., because code-server runs inside the lab network.

## Prerequisites

- Stage 2 complete (tailnet, nginx, ufw, DNS).
- Stage 3 steps 1-4 complete (k3s up, smoke test worked).
- Tailnet allows Funnel (enable at https://login.tailscale.com/f/funnel on first attempt; Tailscale's CLI gives a direct activation link).
- MagicDNS + HTTPS certificates enabled on the tailnet (we did both in stage 2 step 5).

## Step 3.8.1: Install Docker on lab-platform-eng

Same one-liner used on lab-gateway in stage 2.

```bash
ssh lab-platform-eng

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker adminuser
exit
ssh lab-platform-eng   # reconnect for group membership

docker version
```

## Step 3.8.2: Deploy code-server

Generate a strong password:

```bash
openssl rand -base64 32
# e.g. +062lHokAFTFV4n9lJCC4HwfFihtWVIeHcA7YUlVVdI=
```

Save in a password manager immediately. This is the only auth in front of the service.

Prepare bind-mount directories with UID 1000 ownership (matches the `coder` user inside the image):

```bash
sudo mkdir -p /srv/code-server/{config,local,project}
sudo chown -R 1000:1000 /srv/code-server
```

Run the container:

```bash
docker run -d \
    --name code-server \
    --restart unless-stopped \
    -p 8080:8080 \
    -e PASSWORD='<the-generated-password>' \
    -e TZ=America/Los_Angeles \
    -v /srv/code-server/config:/home/coder/.config \
    -v /srv/code-server/local:/home/coder/.local \
    -v /srv/code-server/project:/home/coder/project \
    codercom/code-server:4.95.3
```

### Design notes

- **Bind mounts** under `/srv/code-server/` so config, extensions, and workspace survive container replacement. Same convention we planned for data services on `lab-datastore`.
- **UID 1000** is what code-server runs as inside the container; host directories must match or the container can't write.
- **`-e TZ`** so timestamps in logs and Git commits are in your wall-clock zone.
- **Pinned image** `codercom/code-server:4.95.3`. Bump deliberately.

### Rollback

```bash
docker rm -f code-server
sudo rm -rf /srv/code-server   # optional: wipes state too
```

## Step 3.8.3: Verify internal access (direct IP)

From your Mac (already on the tailnet):

```bash
open http://192.168.100.208:8080
```

Password prompt, paste password, land in VS Code in a browser. Open Terminal > New Terminal to confirm the internal shell works.

## Step 3.8.4: nginx vhost for code.lab.local

Config at [`../services/nginx/conf.d/code.conf`](../services/nginx/conf.d/code.conf):

- Matches `server_name code.lab.local`.
- Proxies to `http://192.168.100.208:8080`.
- WebSocket upgrade headers and long timeouts (code-server uses WebSockets for terminal, LSP, file watcher).
- `client_max_body_size 100M` for file uploads/paste buffers.

### Deploy

```powershell
scp C:\vmimages\services\nginx\conf.d\code.conf lab-gateway:/tmp/code.conf
ssh lab-gateway "sudo mv /tmp/code.conf /opt/nginx/conf.d/code.conf && sudo chmod 644 /opt/nginx/conf.d/code.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

### Verify from Mac

```bash
open http://code.lab.local/
```

Same code-server login as before, now reached by name. Works because CoreDNS's `*.lab.local` wildcard resolves `code.lab.local` to lab-gateway, nginx sees the Host header, proxies to code-server.

## Step 3.8.5: Tailscale Funnel for public access

### Admin panel prep (one-time per tailnet)

1. https://login.tailscale.com/admin/dns → **Enable HTTPS Certificates** if not already on (required for Funnel).
2. When `tailscale funnel` is run for the first time, it will print a direct link to approve Funnel usage for the tailnet. Click it.

### Configure on lab-gateway

Modern Tailscale (1.76+) consolidated serve + funnel into one command:

```bash
ssh lab-gateway

# If any prior `tailscale serve` config exists, clear it first
sudo tailscale serve reset

# Funnel public HTTPS 443 to code-server's internal HTTP endpoint
sudo tailscale funnel --bg http://192.168.100.208:8080

sudo tailscale funnel status
```

Expected:

```
# Funnel on:
#   - https://lab-gateway.<tail-hash>.ts.net
https://lab-gateway.<tail-hash>.ts.net (Funnel on)
|-- / proxy http://192.168.100.208:8080
```

### Why funnel directly to the backend instead of through nginx

The public URL's hostname is `lab-gateway.<tail-hash>.ts.net`, not `code.lab.local`. nginx's vhost matching is based on the Host header, and there's no server block for the `.ts.net` hostname. So funneling through nginx would land on the catch-all 404.

Two options to handle this: add a server block matching the funnel hostname (adds an nginx vhost per funneled service, messy) or funnel directly to the backend (simpler, which is what we did).

For a single public service, direct is cleaner. If we later funnel multiple services through one lab-gateway node, we'll revisit (and likely move to Cloudflare Tunnel with proper subdomain routing per the backlog).

### Rollback

```bash
sudo tailscale funnel reset
```

Funnel off, URL disappears from the public internet. Internal access via `code.lab.local` is unaffected (different path, different layer).

## Step 3.8.6: Verify from work PC

On any machine off the tailnet, browse:

```
https://lab-gateway.<tail-hash>.ts.net/
```

Expected: code-server login page over standard HTTPS. The URL prompts for the same password you set in 3.8.2.

Once logged in, the browser Terminal gives a shell inside the code-server container on `lab-platform-eng`. From that shell you can reach every lab VM (ssh, kubectl, internal DNS) because you ARE on the lab network at that point.

## Deployed configuration artifacts

- **code-server container** on `lab-platform-eng` (Docker). Bind mounts at `/srv/code-server/{config,local,project}`, password in env var.
- **nginx vhost** at `services/nginx/conf.d/code.conf`, deployed to `/opt/nginx/conf.d/code.conf` on lab-gateway.
- **Tailscale Funnel** configuration on lab-gateway, persisted in Tailscale's own state (not a file we manage). Re-creatable with the single `tailscale funnel --bg http://192.168.100.208:8080` command.

## Access paths

```
Personal device on tailnet:
  Mac browser -> http://code.lab.local/
    -> Tailscale Split DNS resolves *.lab.local -> 192.168.100.201
    -> Mac routes via Tailscale subnet router -> lab-gateway
    -> nginx matches server_name code.lab.local
    -> proxy_pass http://192.168.100.208:8080
    -> code-server

Public internet (work PC, phone without tailnet, anywhere):
  Browser -> https://lab-gateway.<tail-hash>.ts.net/
    -> Tailscale's public edge over HTTPS
    -> Funnel to lab-gateway
    -> Tailscale forwards to http://192.168.100.208:8080
    -> code-server
```

## Gotchas

**A. Tailscale Funnel CLI changed.** Older docs (and older releases of Tailscale) used `tailscale funnel 443 on`. Current CLI uses `tailscale funnel <target>` with target being a URL/port/socket. If you get `Error: the CLI for serve and funnel has changed`, see `tailscale funnel --help` for the current form.

**B. Funnel requires separate activation per tailnet.** First `tailscale funnel` command emits `Funnel is not enabled on your tailnet` with a direct activation link (`https://login.tailscale.com/f/funnel?node=<id>`). Click the link to approve, then re-run the command.

**C. Tailscale Funnel URLs are publicly reachable by anyone who knows them.** Only defense is the service's own authentication (code-server's password in this case). Use a strong password, rotate if leaked, consider migrating to Cloudflare Tunnel + Access for real SSO (see `../BACKLOG.md`).

**D. nginx is NOT in the Funnel path.** When accessed via the `.ts.net` hostname, requests go Tailscale -> code-server directly. The `code.lab.local` internal path still goes through nginx. Two different access patterns with the same backend.

**E. Tailscale's Funnel bandwidth is limited on free tier.** Fine for one-person lab access; if you ever proxy real traffic through Funnel, check the limits in Tailscale's current pricing page.

## Next

Stage 3.8 unlocks the work-PC use case. Next logical step is 3.5 (Postgres + pgvector on `lab-datastore`) per the current stage 3 plan. Alternatives in priority order:

- Postgres + MinIO + Redis on `lab-datastore` (unblocks stateful app work).
- Observability stack (Prometheus, Grafana, Loki) on k3s or `lab-ai-ops`.
- Structurizr Lite on `lab-platform-eng` (closes the self-documenting loop).

See `../BACKLOG.md` for the full inventory.
