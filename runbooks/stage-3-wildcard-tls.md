# Stage 3, Step 10: Wildcard TLS for `*.lab.local` via mkcert

## Goal

Serve every `*.lab.local` host over HTTPS with a trusted certificate, so browsers treat the lab as a secure context and Bitwarden clients (and any future service with similar requirements) accept it. Side benefit: every future HTTPS service gets TLS for free.

## Architecture change

**Before:** internal lab services were HTTP-only. Bitwarden/Vaultwarden refused to operate because the web-vault and clients require HTTPS.

**After:** a local CA (created by mkcert on `lab-gateway`) issues a wildcard cert for `*.lab.local` + `lab.local`. nginx on lab-gateway terminates TLS on port 443 for the lab interface and redirects HTTP to HTTPS per-vhost. Client devices (Mac, iPad, phone) trust the lab CA in their system keychains.

## Prerequisites

- nginx reverse proxy on lab-gateway (from stage 2 step 6).
- CoreDNS wildcard DNS for `*.lab.local` (stage 2 step 6).
- Admin access on every client device that needs to trust the CA.

## Step 3.10.1: Install mkcert on lab-gateway

```bash
ssh lab-gateway

sudo apt install -y libnss3-tools   # enables Firefox/Chromium trust stores
curl -L -o /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
sudo install -m 0755 /tmp/mkcert /usr/local/bin/mkcert
rm /tmp/mkcert
```

## Step 3.10.2: Create the local CA and issue a wildcard cert

```bash
# Create the local CA (stored in ~/.local/share/mkcert/)
mkcert -install

# Confirm location
CAROOT=$(mkcert -CAROOT)
ls "$CAROOT"
# rootCA.pem  rootCA-key.pem

# Issue the wildcard cert for *.lab.local plus the bare domain
cd ~
mkcert '*.lab.local' 'lab.local'
# outputs:
# ./_wildcard.lab.local+1.pem       (cert)
# ./_wildcard.lab.local+1-key.pem   (key)
```

Move to the location nginx will mount:

```bash
sudo mkdir -p /srv/nginx/tls
sudo mv ~/_wildcard.lab.local+1.pem     /srv/nginx/tls/lab.local.crt
sudo mv ~/_wildcard.lab.local+1-key.pem /srv/nginx/tls/lab.local.key
sudo chmod 644 /srv/nginx/tls/lab.local.crt
sudo chmod 600 /srv/nginx/tls/lab.local.key
ls -l /srv/nginx/tls/
```

## Step 3.10.3: Mount TLS dir into nginx, bind to lab IP only

Tailscale Funnel (from step 3.8) listens on `tailscale0:443`. Binding nginx to `0.0.0.0:443` collides. Fix: bind nginx specifically to the lab interface IP (`192.168.100.201`) for both 80 and 443.

```bash
docker rm -f nginx

docker run -d \
    --name nginx \
    --restart unless-stopped \
    -p 192.168.100.201:80:80 \
    -p 192.168.100.201:443:443 \
    -v /opt/nginx/conf.d:/etc/nginx/conf.d:ro \
    -v /srv/nginx/tls:/etc/nginx/tls:ro \
    nginx:1.27-alpine

docker ps --filter name=nginx
```

Key changes vs step 2 version:

- `-p 192.168.100.201:80:80` (was `-p 80:80` → `0.0.0.0:80`, which conflicts if Tailscale ever binds 80).
- `-p 192.168.100.201:443:443` (new; was no 443 binding).
- `-v /srv/nginx/tls:/etc/nginx/tls:ro` (new; makes cert available inside the container).

## Step 3.10.4: Update vhosts to use HTTPS

Pattern for every `*.lab.local` vhost:

```nginx
# HTTP redirect
server {
    listen 80;
    server_name <service>.lab.local;
    return 301 https://$host$request_uri;
}

# HTTPS vhost
server {
    listen 443 ssl;
    http2 on;
    server_name <service>.lab.local;

    ssl_certificate     /etc/nginx/tls/lab.local.crt;
    ssl_certificate_key /etc/nginx/tls/lab.local.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # ... existing proxy config ...
}
```

Updated the Vaultwarden vhost (`services/nginx/conf.d/vault.conf`) to this shape. Other vhosts (`code.conf`, `s3.conf`, `minio.conf`, `hello.conf`) still run HTTP-only. Convert them as needed; the wildcard cert covers all `*.lab.local` names so no new cert work per vhost.

Deploy changes + reload:

```powershell
scp C:\vmimages\services\nginx\conf.d\vault.conf lab-gateway:/tmp/vault.conf
ssh lab-gateway "sudo mv /tmp/vault.conf /opt/nginx/conf.d/vault.conf && sudo chmod 644 /opt/nginx/conf.d/vault.conf && docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

## Step 3.10.5: Trust the lab CA on each client device

### Mac

```bash
# On the Mac
scp adminuser@lab-gateway.lab.local:~/.local/share/mkcert/rootCA.pem ~/Downloads/lab-ca.pem

sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    ~/Downloads/lab-ca.pem

rm ~/Downloads/lab-ca.pem
```

After the trust, every `*.lab.local` URL validates cleanly.

### iOS / iPad

1. AirDrop or email the `rootCA.pem` to the device.
2. Open the file; iOS prompts to add a "Configuration Profile".
3. Settings → General → VPN & Device Management → install the profile.
4. Settings → General → About → Certificate Trust Settings → toggle the lab CA to "Enable Full Trust for Root Certificates".

### Windows

1. Copy `rootCA.pem` to the Windows host.
2. Double-click, "Install Certificate" → Local Machine → Trusted Root Certification Authorities.

### Android

Settings → Security → Encryption & credentials → Install a certificate → CA certificate. Point at the `.pem` file.

## Step 3.10.6: Verify

From any trusted-CA client:

```
https://vault.lab.local/
```

Expected: green padlock, no warning. Cert subject says `*.lab.local`, issuer says your mkcert CA.

```bash
# Mac terminal
openssl s_client -connect vault.lab.local:443 -servername vault.lab.local </dev/null 2>&1 | grep -E 'subject|issuer|Verification'
```

Expected:

```
Verification: OK
subject=CN=_wildcard.lab.local
issuer=O=mkcert development CA, OU=adminuser@lab-gateway, CN=mkcert adminuser@lab-gateway
```

## Deployed configuration artifacts

- **Local CA**: `~/.local/share/mkcert/rootCA.pem` + `rootCA-key.pem` on lab-gateway (keep the key file secure; anyone with it can forge certs for `*.lab.local`).
- **Wildcard cert**: `/srv/nginx/tls/lab.local.crt` + `.key`, mounted into nginx as `/etc/nginx/tls/`.
- **nginx container**: rebuilt with lab-IP-scoped port bindings + TLS volume mount.
- **Trust stores** on each client device.

## Gotchas

**A. Tailscale Funnel binds `tailscale0:443`.** Docker binding to `0.0.0.0:443` conflicts even though the interfaces are different. Fix: bind nginx to the lab IP specifically (`-p 192.168.100.201:443:443`). `ss -tlnp | grep ':443'` confirms what's listening on which interface.

**B. mkcert cert lifespan is 825 days by default.** Good for now. Set a calendar reminder to regenerate before expiry; we can automate this with cert-manager + step-ca later (see BACKLOG.md).

**C. CA private key.** `~/.local/share/mkcert/rootCA-key.pem` is the crown jewel. Anyone with it can issue certs for any domain. Don't commit or share. If ever leaked, rotate the entire CA (regen, reissue, redistribute trust).

**D. Wildcard only goes one level deep.** `*.lab.local` matches `foo.lab.local` but NOT `sub.foo.lab.local`. If we ever need nested subdomains, issue additional certs or redesign the naming.

**E. iOS requires Profile install AND Trust Settings toggle.** Just installing the profile isn't enough; the "Enable Full Trust" toggle in Certificate Trust Settings is the second step. Easy to miss.

**F. Docker networking dependency.** Vaultwarden must reach Postgres via the `postgres` container name on the shared `labnet` network (step 3.9). If the network is torn down or containers re-created without rejoining, connections fail silently until you notice.

## Next

- **cert-manager** on k3s (add when first k3s workload wants an Ingress with TLS). Replaces mkcert for cluster workloads.
- **step-ca** as an internal ACME CA companion to cert-manager.
- **Cloudflare Tunnel** handles external TLS entirely; pairs with the Cloudflare migration already in BACKLOG.md.
