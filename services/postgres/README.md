# PostgreSQL (+ pgvector)

Source-controlled artifacts for the Postgres instance on `lab-datastore`.

## Deployed on

`lab-datastore` (`192.168.100.205`) as a Docker container using the `pgvector/pgvector` image (Postgres 16 with the pgvector extension preinstalled). Data lives on the VM at `/srv/postgres/data`.

## What it serves

- Single Postgres instance, shared across apps.
- One logical database per app (`workflows_db`, `structurizr_db`, etc.), each with its own user/password.
- pgvector extension available for future RAG/embedding workloads. Enable per-database as needed.

Port `5432/tcp` is bound to `192.168.100.205:5432` (lab subnet interface only) so it's reachable from every lab VM but not from the home network or internet.

## Directory layout on `lab-datastore`

```
/srv/postgres/
  data/        Postgres data directory (mounted at /var/lib/postgresql/data inside container)
  init/        SQL/shell scripts run on first container boot (mounted read-only at /docker-entrypoint-initdb.d)
  backups/     pg_dump output (manual for now; automated in a later step)
```

All owned by UID 999 (Postgres user inside the container).

## Deploy / update

### Config in the repo

- `init/` directory mirrors what goes into `/srv/postgres/init/` on the VM. Currently contains `01-enable-pgvector.sql` which enables the pgvector extension in the default `postgres` database.

### First-time install

From the Windows host:

```powershell
# Push init scripts
ssh lab-datastore "sudo mkdir -p /srv/postgres/{data,init,backups} && sudo chown -R 999:999 /srv/postgres"
scp C:\vmimages\services\postgres\init\*.sql lab-datastore:/tmp/
ssh lab-datastore "sudo mv /tmp/*.sql /srv/postgres/init/ && sudo chown 999:999 /srv/postgres/init/*.sql && sudo chmod 644 /srv/postgres/init/*.sql"
```

On `lab-datastore`, generate a strong superuser password and save it to your password manager:

```bash
openssl rand -base64 32
```

Run the container (replace `<your-password>`):

```bash
docker run -d \
    --name postgres \
    --restart unless-stopped \
    -p 192.168.100.205:5432:5432 \
    -e POSTGRES_PASSWORD='<your-password>' \
    -e TZ=America/Los_Angeles \
    -v /srv/postgres/data:/var/lib/postgresql/data \
    -v /srv/postgres/init:/docker-entrypoint-initdb.d:ro \
    pgvector/pgvector:0.8.0-pg16
```

### Updating the image (minor version bump)

Version pin in the image tag. To bump:

```bash
docker pull pgvector/pgvector:0.8.0-pg16   # new tag
docker stop postgres
docker rm postgres
# re-run with the new tag
```

Data is in the bind mount so it survives.

For a major Postgres version bump (pg16 -> pg17), you need a dump/restore or pg_upgrade. Not a simple container swap. See [Postgres upgrade docs](https://www.postgresql.org/docs/current/upgrading.html).

## Common operations

### Create a new app database and user

```bash
docker exec -it postgres psql -U postgres
```

Then in psql:

```sql
CREATE DATABASE myapp_db;
CREATE USER myapp_user WITH ENCRYPTED PASSWORD 'strong-password-here';
GRANT ALL PRIVILEGES ON DATABASE myapp_db TO myapp_user;
\c myapp_db
GRANT ALL ON SCHEMA public TO myapp_user;
-- optional if the app uses vectors:
CREATE EXTENSION IF NOT EXISTS vector;
\q
```

### Manual backup

```bash
docker exec postgres pg_dumpall -U postgres | gzip > /srv/postgres/backups/dump-$(date -u +%Y%m%dT%H%M%SZ).sql.gz
```

### Connect from another lab VM

```bash
sudo apt install -y postgresql-client
psql -h lab-datastore.lab.local -U postgres -d postgres
```

The FQDN resolves via CoreDNS (stage 2 step 5).

## Security notes

- Superuser password is the only auth; store in password manager.
- Port binding is `192.168.100.205:5432` (lab subnet) not `0.0.0.0:5432` (all interfaces). Don't broaden it without a reason.
- ufw on lab-datastore already allows all traffic from `192.168.100.0/24`, so no additional firewall rule is needed.
- No TLS on the Postgres connection today. In-lab traffic is on a private subnet, and Tailscale SSH / subnet routing is encrypted at the network layer. Revisit if threat model changes.
