# CoreDNS

Source-controlled config for the CoreDNS instance that serves `*.lab.local` resolution across the lab.

## Deployed on

`lab-gateway` (`192.168.100.201`), as a Docker container, bound to the lab interface. Config file `Corefile` is mounted read-only at `/etc/coredns/Corefile`.

## What it does

- **`lab.local` zone**: authoritative, loaded from [`zones/lab.local`](./zones/lab.local) via the `file` plugin. Contains specific A records for every VM plus a DNS wildcard (`*`) that catches everything else and points at `lab-gateway` (where nginx dispatches by Host header). Per RFC 1034, more specific records override the wildcard, so lab VM names still resolve correctly.
- **Everything else**: forwarded upstream to `1.1.1.1` and `8.8.8.8`, cached 5 minutes.

Adding a new VM: edit `zones/lab.local`, add a specific A record, bump the serial number. Redeploy.

Adding a new service behind nginx: no DNS change needed. Add an nginx vhost in `../nginx/conf.d/` and redeploy nginx.

## Deploy / update

From the Windows host:

```powershell
# Ensure the target directory tree exists
ssh lab-gateway "sudo mkdir -p /opt/coredns/zones"

# Push both the Corefile and the zone file
scp C:\vmimages\services\coredns\Corefile       lab-gateway:/tmp/Corefile
scp C:\vmimages\services\coredns\zones\lab.local lab-gateway:/tmp/lab.local

ssh lab-gateway @"
sudo mv /tmp/Corefile        /opt/coredns/Corefile
sudo mv /tmp/lab.local       /opt/coredns/zones/lab.local
sudo chmod 644 /opt/coredns/Corefile /opt/coredns/zones/lab.local
"@

# file plugin watches for serial bumps and reloads automatically within a
# few seconds. For structural Corefile changes, restart to be safe.
ssh lab-gateway "docker restart coredns && sleep 2 && docker logs coredns --tail 10"
```

## First-time container run

On `lab-gateway`:

```bash
docker run -d \
    --name coredns \
    --restart unless-stopped \
    -p 192.168.100.201:53:53/udp \
    -p 192.168.100.201:53:53/tcp \
    -v /opt/coredns:/etc/coredns:ro \
    coredns/coredns:1.11.3 \
    -conf /etc/coredns/Corefile
```

The `/opt/coredns` mount contains both the `Corefile` and the `zones/` subdirectory. Port binding is scoped to `192.168.100.201:53` so we don't conflict with `systemd-resolved` on `127.0.0.53:53` (lab-gateway's own stub resolver).

## Adding a new VM

1. Edit `zones/lab.local`, add a specific A record:

   ```
   lab-newvm               IN A 192.168.100.209
   ```

2. Bump the `serial` in the SOA record (e.g., `2026042301` → `2026042302`).
3. Commit, `scp` to lab-gateway, CoreDNS's `file` plugin picks up the serial bump and reloads automatically within seconds.
