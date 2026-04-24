# nginx reverse proxy

Source-controlled config for the nginx instance that reverse-proxies `*.lab.local` services.

## Deployed on

`lab-gateway` (`192.168.100.201`) as a Docker container, listening on port 80 (host) from the `homenet` + `lab` + tailscale interfaces. The `conf.d/` directory is mounted read-only at `/etc/nginx/conf.d/`.

## How requests reach here

1. Client issues `curl http://grafana.lab.local`.
2. Client DNS (CoreDNS on lab-gateway, or Tailscale Split DNS from the tailnet) resolves `grafana.lab.local`. Specific VM records (lab-k3s-*) come from CoreDNS `hosts`; everything else falls through a CoreDNS `template` rule to `192.168.100.201` (lab-gateway).
3. Request hits nginx on lab-gateway:80.
4. nginx matches by `Host:` header to a `server { server_name grafana.lab.local; ... }` block.
5. `proxy_pass` forwards to the real backend (e.g., `http://192.168.100.206:3000`).

## Layout

```
services/nginx/
  README.md           You are here
  conf.d/             One file per logical service (or catch-all)
    default.conf      Catch-all 404 for unknown Host headers
    (whoami.conf)     Test backend (optional, see below)
    (arch.conf)       Structurizr Lite, when it goes live
    (grafana.conf)    Grafana, when observability stack lands
    (s3.conf)         MinIO, when data tier lands
```

Adding a new service is a new file in `conf.d/`. No `nginx.conf` edits needed (the default image config already `include /etc/nginx/conf.d/*.conf;`).

## Deploy / update

From Windows host:

```powershell
# Push the whole conf.d tree
scp -r C:\vmimages\services\nginx\conf.d\* lab-gateway:/tmp/nginx-conf.d/
ssh lab-gateway "sudo mkdir -p /opt/nginx/conf.d && sudo mv /tmp/nginx-conf.d/* /opt/nginx/conf.d/ && sudo chmod 644 /opt/nginx/conf.d/*.conf"

# Reload running container (no downtime)
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

`nginx -t` validates the config before we reload; `-s reload` is a graceful reload (existing connections finish on the old config, new ones use the new config).

## First-time container run

On `lab-gateway`, after the config is in place at `/opt/nginx/conf.d/`:

```bash
docker run -d \
    --name nginx \
    --restart unless-stopped \
    -p 80:80 \
    -v /opt/nginx/conf.d:/etc/nginx/conf.d:ro \
    nginx:1.27-alpine
```

Port 80 binds to all interfaces on lab-gateway (eth0 = lab, eth1 = home, tailscale0), so any client that routes here reaches nginx.

## Adding a new vhost

New file in `conf.d/`, example for a Grafana on `lab-ai-ops:3000`:

```nginx
# conf.d/grafana.conf
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

Then deploy + reload as in the section above.

## TLS note

Current stage: plain HTTP only. Good enough for a trusted lab behind Tailscale.

Future: either self-signed wildcard cert for `*.lab.local` trusted on managed devices, or Let's Encrypt DNS-01 with a real domain. Captured as a to-do in the stage 2 runbooks.
