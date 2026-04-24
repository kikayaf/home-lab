# Stage 3, Step 9: Vaultwarden on lab-datastore

## Goal

Stand up a self-hosted password manager on `lab-datastore`, backed by the existing Postgres. Unifies the per-service credentials we've been generating into one place, accessible via Bitwarden-compatible browser/mobile/desktop/CLI clients.

## Architecture change

**Before:** credentials for code-server, Postgres, MinIO, Redis, etc. were scattered across chat transcripts, local notes, and password managers ad-hoc. Each new service meant another loose credential.

**After:** Vaultwarden at `https://vault.lab.local` stores every lab credential. Browser extension autofills on login pages. Mobile apps, desktop apps, and the `bw` CLI all point at the same server.

## Prerequisites

- Postgres running on lab-datastore (step 3.5).
- nginx reverse proxy + wildcard DNS (`*.lab.local`) (step 3.6).
- Wildcard TLS for `*.lab.local` (step 3.10). Vaultwarden's `DOMAIN` must be HTTPS; Bitwarden clients refuse HTTP.

## Step 3.9.1: Database on existing Postgres

Create a dedicated DB and user:

```bash
ssh lab-datastore

VW_DB_PASS=$(openssl rand -base64 24)
echo "VW_DB_PASS=$VW_DB_PASS"   # save in your password manager (temporarily outside Vaultwarden)

docker exec -i postgres psql -U postgres <<EOF
CREATE DATABASE vaultwarden_db;
CREATE USER vaultwarden_user WITH ENCRYPTED PASSWORD '$VW_DB_PASS';
GRANT ALL PRIVILEGES ON DATABASE vaultwarden_db TO vaultwarden_user;
\c vaultwarden_db
GRANT ALL ON SCHEMA public TO vaultwarden_user;
EOF
```

If the psql here-doc loses the `$VW_DB_PASS` variable (common when pasting into a fresh shell), you'll see a "password cleared" notice and Vaultwarden can't auth. Recovery: `ALTER USER vaultwarden_user WITH ENCRYPTED PASSWORD '<value>';` while the value is actually set.

## Step 3.9.2: Admin token

```bash
VW_ADMIN_TOKEN=$(openssl rand -base64 48)
echo "VW_ADMIN_TOKEN=$VW_ADMIN_TOKEN"   # save in password manager
```

Gates the admin panel at `https://vault.lab.local/admin`. Treat as root credential.

## Step 3.9.3: Shared Docker network

Vaultwarden and Postgres both run on lab-datastore. The container-to-container path via the host's external IP (`192.168.100.205`) hairpins and times out. Put them on a shared Docker network; use container names as hostnames.

```bash
docker network create labnet
docker network connect labnet postgres
```

Postgres already exists and gets attached to the new network without restart.

## Step 3.9.4: Run Vaultwarden

```bash
sudo mkdir -p /srv/vaultwarden/data

# Single-line form avoids paste mangling that corrupted multi-line backslash-continuations
docker run -d --name vaultwarden --network labnet --restart unless-stopped -p 192.168.100.205:8222:80 -e DATABASE_URL="postgresql://vaultwarden_user:$VW_DB_PASS@postgres:5432/vaultwarden_db" -e DOMAIN='https://vault.lab.local' -e ADMIN_TOKEN="$VW_ADMIN_TOKEN" -e SIGNUPS_ALLOWED=true -e WEBSOCKET_ENABLED=true -e TZ=America/Los_Angeles -v /srv/vaultwarden/data:/data vaultwarden/server:latest
```

### Design notes

- **`--network labnet`** and **`postgres`** as DB host: resolves to Postgres's container IP on the shared network. No hairpin.
- **`-p 192.168.100.205:8222:80`**: exposes container port 80 on lab-datastore's lab-subnet IP at port 8222 for nginx to reach.
- **`DOMAIN='https://vault.lab.local'`**: Bitwarden clients enforce HTTPS here. Set after step 3.10 (TLS) is in place.
- **`SIGNUPS_ALLOWED=true`** temporarily: allows creating your first user, then flip to `false`.
- **Bind mount** `/srv/vaultwarden/data`: stores RSA signing keys, attachments, sends, icons. Structured data is in Postgres.

### Verify

```bash
docker ps --filter name=vaultwarden
docker logs vaultwarden --tail 20
# Expect: "Rocket has launched from http://0.0.0.0:80"
```

## Step 3.9.5: nginx vhost

Config at [`../services/nginx/conf.d/vault.conf`](../services/nginx/conf.d/vault.conf) (HTTPS on 443 after step 3.10). Deploy:

```powershell
scp C:\vmimages\services\nginx\conf.d\vault.conf lab-gateway:/tmp/vault.conf
ssh lab-gateway "sudo mv /tmp/vault.conf /opt/nginx/conf.d/vault.conf && sudo chmod 644 /opt/nginx/conf.d/vault.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

### Config highlights

- Redirect `http://vault.lab.local` → `https://vault.lab.local`.
- WebSocket upgrade for live sync between clients.
- `client_max_body_size 128M` for file attachments.

## Step 3.9.6: Sign up your first user

```bash
open https://vault.lab.local/
```

Create account with a real email (used for password reset reminders) and a strong master password.

**Critical:** write the master password down somewhere physical. Zero-knowledge design means neither you nor the server can recover a lost master password; all stored secrets become unreadable.

## Step 3.9.7: Disable further signups

```bash
docker rm -f vaultwarden

docker run -d --name vaultwarden --network labnet --restart unless-stopped -p 192.168.100.205:8222:80 -e DATABASE_URL="postgresql://vaultwarden_user:$VW_DB_PASS@postgres:5432/vaultwarden_db" -e DOMAIN='https://vault.lab.local' -e ADMIN_TOKEN="$VW_ADMIN_TOKEN" -e SIGNUPS_ALLOWED=false -e WEBSOCKET_ENABLED=true -e TZ=America/Los_Angeles -v /srv/vaultwarden/data:/data vaultwarden/server:latest
```

Only diff from 3.9.4: `SIGNUPS_ALLOWED=false`. Test by visiting the registration page in a private browser; it should reject new signups.

## Step 3.9.8: Import the lab's existing credentials

We generated several lab-service passwords across stages 3.5 to 3.10; all got dropped into Vaultwarden's "Lab" folder via Bitwarden's JSON import format. One-time bootstrap.

Steps (from the Mac):

1. Create `~/Downloads/lab-passwords.json` with the six lab items (code-server, Postgres superuser, MinIO root, Redis, Vaultwarden DB user, Vaultwarden admin token).
2. In the Vaultwarden web vault: **Tools → Import data → Bitwarden (json)** → select the file → **Import data**.
3. Verify the "Lab" folder shows all six items with correct URIs and usernames.
4. Shred the file: `rm -P ~/Downloads/lab-passwords.json && pbcopy < /dev/null`.

## Step 3.9.9: Install clients

- **Browser extension** (every browser you use): `https://bitwarden.com/download/` → install → settings → Self-hosted Environment → server URL `https://vault.lab.local` → log in. Autofill on matching URIs, `Cmd+Shift+L` (Mac) or `Ctrl+Shift+L` to autofill.
- **Mobile apps** (iOS/Android): install Bitwarden app → self-hosted URL → enable autofill in OS settings. Requires Tailscale on the device (so `vault.lab.local` resolves and HTTPS cert is trusted) OR future Cloudflare Tunnel migration for public access.
- **Desktop app** (optional): `https://bitwarden.com/download/` → Mac/Windows/Linux install.
- **CLI** (`bw`, optional): `brew install bitwarden-cli` or `npm install -g @bitwarden/cli`. Useful for scripting.

## Deployed configuration artifacts

- **Database**: `vaultwarden_db` on the existing Postgres, user `vaultwarden_user`.
- **Docker network**: `labnet` with postgres + vaultwarden attached.
- **Vaultwarden container**: `vaultwarden/server:1.35.7`, port `192.168.100.205:8222`.
- **Data**: `/srv/vaultwarden/data` (RSA keys, attachments, sends).
- **nginx vhost**: `vault.lab.local` HTTPS-only with wildcard cert.

## Gotchas

**A. DATABASE_URL env var expansion from empty shell vars.** If `$VW_DB_PASS` is empty when `docker run` fires, the container's DATABASE_URL has a blank password and Postgres returns `fe_sendauth: no password supplied`. Always `echo ${#VAR}` before a run to confirm non-zero length.

**B. Hairpin routing between two containers on the same host via the host's external IP.** Postgres on `192.168.100.205:5432` is reachable from other lab VMs but times out from a co-located container via the lab IP. Fix: put both containers on a shared Docker network; use container names.

**C. Paste corruption on multi-line `docker run`.** Backslash-continuation lines sometimes mangle during paste (lines fuse together). Single-line form is uglier but reliable. For complex commands, use `--env-file` to offload env vars to a separate file.

**D. Bitwarden clients enforce HTTPS on `DOMAIN`.** Not just the browser. The Bitwarden browser extension, mobile apps, and web vault all refuse to operate against an HTTP server. Solved by step 3.10 (wildcard TLS).

**E. Plain-text `ADMIN_TOKEN` triggers a notice.** Vaultwarden prefers an Argon2-hashed token. Convert later with `docker run --rm vaultwarden/server hash -p '<token>'` and replace the env var with the hash. Non-blocking.

**F. First-user bootstrap.** With `SIGNUPS_ALLOWED=false` from the start, there's a chicken-and-egg for creating the first account. Either flip `true → false` once (what we did) or use the `/admin` panel (with `ADMIN_TOKEN`) to invite yourself.

## Next

- **restic backup automation** covering `/srv/vaultwarden/data/` + `pg_dump` of `vaultwarden_db`. Master password is non-recoverable, but the encrypted vault blobs are recoverable if backed up. Critical to land before the vault has significant contents.
- **Cloudflare Tunnel + Access** for public access from work PC (currently Vaultwarden is tailnet-only; we can't hit it from the work Mac Studio).
- **Rotate `ADMIN_TOKEN`** to an Argon2 hash.
