# Vaultwarden

Self-hosted Bitwarden-compatible password manager. Runs as a Docker container on `lab-datastore` with a dedicated database on the existing Postgres instance.

## Deployed on

- **Container**: `lab-datastore` (`192.168.100.205`), port `8222` (internal).
- **Database**: `vaultwarden_db` on the Postgres at `lab-datastore:5432`.
- **Internal URL**: `http://vault.lab.local` via nginx on lab-gateway.
- **External URL** (planned): `https://vault.example.com` via Cloudflare Tunnel + Access, once that migration lands. Tailscale Funnel is already tied up for code-server.

## Data

- **Structured data** (vaults, users, ciphers, folders) in `vaultwarden_db` on Postgres.
- **Unstructured data** (attachments, sends, RSA signing keys, icon cache) in `/srv/vaultwarden/data/` on the lab-datastore host.

Both get backed up by restic once automation lands.

## Deploy / update

See [`../../runbooks/stage-3-vaultwarden.md`](../../runbooks/stage-3-vaultwarden.md) for the full walkthrough.

Quick reference, after one-time setup:

```bash
# Upgrade
docker pull vaultwarden/server:latest
docker rm -f vaultwarden
docker run ...   # same flags with new tag
```

Data survives via the bind mount + Postgres.

## Security notes

- **Zero-knowledge**: master passwords never leave clients. Server stores only encrypted blobs. A compromised server still cannot read your vault.
- **ADMIN_TOKEN** gates the admin panel at `/admin`. Treat it like the SSH key to the lab. Rotate if ever shared.
- **DB password**: stored only in the container's env and in the password manager once Vaultwarden is running (chicken-and-egg: first password goes in the lab's password manager, i.e., this one).
- **No TLS on internal URL yet**. Works in desktop browsers. iOS/Android Bitwarden apps require HTTPS. Plan: wildcard `*.lab.local` cert or Cloudflare Tunnel with real cert.

## Gotchas

- **SIGNUPS_ALLOWED bootstrap**: a fresh Vaultwarden has zero users. Either allow signups briefly to create your first user, then flip off, or use the ADMIN_TOKEN to create an invite via `/admin`. The allow-then-disable pattern is simpler without SMTP.
- **WebSockets**: live sync between devices uses WebSockets. nginx vhost must upgrade the connection; modern Vaultwarden (1.25+) multiplexes WS through the main port 80.
- **Database URL format**: Postgres connection string is `postgresql://user:pass@host:5432/db`. Percent-encode special characters in the password if any.
- **`vaultwarden/server:latest` floats.** Pin to an explicit release tag after first pull for reproducibility.
