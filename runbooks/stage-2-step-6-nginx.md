# Stage 2, Step 6: nginx reverse proxy on lab-gateway

## Goal

Stand up a reverse proxy on `lab-gateway` that dispatches `*.lab.local` HTTP requests to the right backend service by Host header. After this step, adding a new internal service (grafana, structurizr, minio, etc.) is a two-file change (one nginx vhost snippet, optionally one docker container) with no DNS work needed.

## Architecture change

**Before (end of step 5):**

```
Mac dig grafana.lab.local   →  NXDOMAIN (no specific record, no wildcard)
Mac reaches a service       →  have to know IP:port, or add /etc/hosts
```

**After (end of step 6):**

```
Mac dig grafana.lab.local              →  192.168.100.201 (wildcard in lab.local zone)
Mac curl http://grafana.lab.local/     →  nginx on lab-gateway
                                       →  proxy_pass to real backend VM:port
                                       →  response
```

Two changes made it work together:

1. **DNS wildcard**: `*` record in the lab.local zone file sends unknown `*.lab.local` names to lab-gateway. Specific VM records still win (RFC 1034).
2. **nginx**: runs on lab-gateway:80, matches by Host header, proxies to the right backend or returns a catch-all 404.

## Prerequisites

- Steps 1-5 complete (Tailscale subnet router, dual-homed lab-gateway, NAT, fleet default gateway flipped, CoreDNS serving lab.local with Split DNS to the tailnet).
- Docker engine running on lab-gateway (installed in step 5.1).

## Step 6.1: Switch CoreDNS from `hosts` plugin to a proper zone file

### What we did

Replaced the CoreDNS `hosts`-plugin-based config with a proper zone file loaded by the `file` plugin. Added a `*` wildcard to the zone. Reason: the `template` plugin we tried first runs BEFORE the `hosts` plugin in CoreDNS's built-in plugin order, so a wildcard template overrides specific hosts entries, which we don't want. Zone-file wildcards behave correctly (specific records override wildcards per RFC 1034).

### Commands

Updated [`../services/coredns/Corefile`](../services/coredns/Corefile) to use `file /etc/coredns/zones/lab.local` instead of the inline `hosts` block. Created [`../services/coredns/zones/lab.local`](../services/coredns/zones/lab.local) with a SOA, NS, per-VM A records, and `* IN A 192.168.100.201`.

Deploy:

```powershell
ssh lab-gateway "sudo mkdir -p /opt/coredns/zones"
scp C:\vmimages\services\coredns\Corefile         lab-gateway:/tmp/Corefile
scp C:\vmimages\services\coredns\zones\lab.local  lab-gateway:/tmp/lab.local
ssh lab-gateway "sudo mv /tmp/Corefile /opt/coredns/Corefile && sudo mv /tmp/lab.local /opt/coredns/zones/lab.local && sudo chmod 644 /opt/coredns/Corefile /opt/coredns/zones/lab.local"
ssh lab-gateway "docker restart coredns"
```

### Verify

```bash
# On lab-gateway, ask CoreDNS directly:
dig @192.168.100.201 lab-datastore.lab.local +short     # 192.168.100.205 (specific wins)
dig @192.168.100.201 arch.lab.local +short              # 192.168.100.201 (wildcard)
dig @192.168.100.201 anything.lab.local +short          # 192.168.100.201 (wildcard)
dig @192.168.100.201 cloudflare.com +short              # 104.x.x.x (upstream forward)
```

### Rollback

Revert `Corefile` to the `hosts` plugin form (see git history). Restart container.

## Step 6.2: Write the nginx config

### What we did

Created [`../services/nginx/conf.d/default.conf`](../services/nginx/conf.d/default.conf) with a single catch-all server block. It's the `default_server` for port 80, so any Host header that doesn't match a more specific `server` block (once we add real services) hits this and returns a 404 with a descriptive message naming the Host it got.

Per-service vhosts go in `services/nginx/conf.d/<service>.conf` alongside this one. The stock `nginx:1.27-alpine` image's built-in `nginx.conf` already does `include /etc/nginx/conf.d/*.conf`, so we don't own the main config, only the vhost snippets.

### Deploy

```powershell
ssh lab-gateway "sudo mkdir -p /opt/nginx/conf.d"
scp C:\vmimages\services\nginx\conf.d\default.conf lab-gateway:/tmp/default.conf
ssh lab-gateway "sudo mv /tmp/default.conf /opt/nginx/conf.d/default.conf && sudo chmod 644 /opt/nginx/conf.d/default.conf"
```

## Step 6.3: Run nginx as a Docker container

### Commands

```bash
docker run -d \
    --name nginx \
    --restart unless-stopped \
    -p 80:80 \
    -v /opt/nginx/conf.d:/etc/nginx/conf.d:ro \
    nginx:1.27-alpine
```

- Port 80 binds to all interfaces on lab-gateway (eth0 lab, eth1 home, tailscale0).
- `conf.d` is mounted read-only; container can't accidentally modify our source of truth.

### Verify

```bash
docker ps --filter name=nginx           # Up N seconds, 0.0.0.0:80->80/tcp
docker logs nginx --tail 10             # no errors, worker processes started
```

### Update path after the first run

When you edit `conf.d/*.conf`, push the file and reload:

```powershell
scp C:\vmimages\services\nginx\conf.d\<file>.conf lab-gateway:/tmp/<file>.conf
ssh lab-gateway "sudo mv /tmp/<file>.conf /opt/nginx/conf.d/<file>.conf && sudo chmod 644 /opt/nginx/conf.d/<file>.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

`nginx -t` validates syntax before reload; `nginx -s reload` gracefully swaps config without dropping existing connections.

## Step 6.4: Verify end-to-end from Mac

```bash
dig arch.lab.local +short               # 192.168.100.201
curl -s http://arch.lab.local/          # nginx 404 text with "No vhost ... 'arch.lab.local'"
dig lab-datastore.lab.local +short      # 192.168.100.205 (unchanged)
```

If the `curl` returns the 404 text with the Host correctly echoed back, the whole pipeline works: Mac DNS → Tailscale Split DNS → CoreDNS → wildcard → lab-gateway → nginx default_server → response.

## Adding a real service

Pattern for when you bring up a service (say grafana on `lab-ai-ops:3000`):

1. Create `services/nginx/conf.d/grafana.conf`:

   ```nginx
   server {
       listen 80;
       server_name grafana.lab.local;

       access_log /var/log/nginx/grafana.access.log main;
       error_log  /var/log/nginx/grafana.error.log;

       location / {
           proxy_pass http://192.168.100.206:3000;
           proxy_set_header Host              $host;
           proxy_set_header X-Real-IP         $remote_addr;
           proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```

2. Push + reload:

   ```powershell
   scp C:\vmimages\services\nginx\conf.d\grafana.conf lab-gateway:/tmp/grafana.conf
   ssh lab-gateway "sudo mv /tmp/grafana.conf /opt/nginx/conf.d/grafana.conf && sudo chmod 644 /opt/nginx/conf.d/grafana.conf"
   ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
   ```

3. `curl http://grafana.lab.local/` from your Mac, service answers.

No DNS edits. The wildcard already resolves `grafana.lab.local` to lab-gateway; nginx's new `server_name grafana.lab.local;` takes over from the default_server.

## Deployed configuration artifacts

- **CoreDNS zone**: [`../services/coredns/zones/lab.local`](../services/coredns/zones/lab.local), mounted at `/etc/coredns/zones/lab.local` in the CoreDNS container.
- **nginx vhosts**: [`../services/nginx/conf.d/`](../services/nginx/conf.d/), mounted read-only at `/etc/nginx/conf.d/` in the nginx container.
- **nginx container**: `nginx:1.27-alpine`, `--restart unless-stopped`, port 80 on all lab-gateway interfaces.

## Gotchas

**A. `template` plugin runs before `hosts` in CoreDNS's built-in plugin order.** Our first attempt put a wildcard in the `template` plugin; it overrode all specific `hosts` entries because CoreDNS called it first. Fix: zone file with `file` plugin. DNS wildcards in zone files respect RFC 1034 specificity rules, so `lab-datastore.lab.local` still wins.

**B. nginx doesn't reload config on file change.** The Docker bind-mount makes the file content visible inside the container, but nginx only re-reads on SIGHUP. Always follow a config push with `docker exec nginx nginx -t && docker exec nginx nginx -s reload`.

**C. lab-gateway's own DNS does NOT use CoreDNS.** Deliberate, to avoid depending on a container running on self. So `dig somename.lab.local` from lab-gateway's shell goes to `1.1.1.1` and returns NXDOMAIN. Always test `lab.local` resolution with `dig @192.168.100.201 ...` when on lab-gateway, or from any other lab VM (they use CoreDNS), or from a tailnet device (Split DNS routes them through CoreDNS).

## Next

- [`stage-2-step-7-ufw.md`](./stage-2-step-7-ufw.md) (planned): host firewall policy on every lab VM. Default-deny, allow specific ports (SSH from lab subnet + tailnet, HTTP/HTTPS on lab-gateway only, service-specific ports on their owning VMs).
