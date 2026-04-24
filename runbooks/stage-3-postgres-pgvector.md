# Stage 3, Step 5: PostgreSQL + pgvector on lab-datastore

## Goal

Stand up the lab's primary SQL database on `lab-datastore`. Single Postgres instance, pgvector extension available, data persisted in a bind-mounted volume. Every future app that needs relational state uses this one instance with its own logical database and dedicated user.

## Architecture change

**Before:** nothing stateful in the lab. Every future workload would have to bring its own embedded DB or refuse to run.

**After:** `lab-datastore` hosts Postgres 16 with pgvector 0.8.0. Reachable from every lab VM at `lab-datastore.lab.local:5432` (or `192.168.100.205:5432`). The data layer is ready for real workloads.

## Prerequisites

- Stage 2 complete (DNS, lab subnet routing, ufw baseline allowing all lab-subnet traffic).
- Stage 3 steps 1-4 and 8 done (not strictly required but that's the current state when we ran this).

## Step 3.5.1: Install Docker on lab-datastore

Same one-liner we used for lab-gateway and lab-platform-eng:

```bash
ssh lab-datastore
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker adminuser
exit
ssh lab-datastore    # reconnect so group membership applies

docker version
```

## Step 3.5.2: Prepare /srv/postgres layout

Bind-mount directories with UID 999 ownership (the `postgres` user inside the container). From the Windows host:

```powershell
ssh lab-datastore "sudo mkdir -p /srv/postgres/{data,init,backups} && sudo chown -R 999:999 /srv/postgres"

scp C:\vmimages\services\postgres\init\01-enable-pgvector.sql lab-datastore:/tmp/
ssh lab-datastore "sudo mv /tmp/01-enable-pgvector.sql /srv/postgres/init/ && sudo chown 999:999 /srv/postgres/init/01-enable-pgvector.sql && sudo chmod 644 /srv/postgres/init/01-enable-pgvector.sql"
```

### Design notes

- `/srv/postgres/data`: actual Postgres data directory. Gets mounted to `/var/lib/postgresql/data` in the container. This is the only directory that must survive upgrades/re-provisions.
- `/srv/postgres/init`: read-only SQL/shell scripts that run on **first** container boot when `PGDATA` is empty. Mounted at `/docker-entrypoint-initdb.d`. Used to bootstrap pgvector and (later) app databases.
- `/srv/postgres/backups`: destination for `pg_dump` output. Not mounted into the container; we `docker exec pg_dump` and redirect host-side.

## Step 3.5.3: Generate the superuser password

```bash
openssl rand -base64 32
```

Save in password manager immediately. This is the credential for the `postgres` superuser; every psql login from outside the container uses it.

## Step 3.5.4: Run the container

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

### Design notes

- **Image** `pgvector/pgvector:0.8.0-pg16`: upstream postgres:16 with the pgvector extension preinstalled. Pinning both extension version (0.8.0) and Postgres major version (16) for reproducibility.
- **Port binding** to `192.168.100.205:5432` (lab subnet interface) not `0.0.0.0:5432`. Lab VMs can reach it, home network and internet cannot.
- **`--restart unless-stopped`**: comes back after lab-datastore reboots; stays down only if an operator explicitly stops it.
- **No volume for init scripts** (`:ro`): container mustn't modify the source of truth.

### Verify

```bash
docker ps --filter name=postgres
docker logs postgres --tail 30
```

Expected log lines (among others):

```
PostgreSQL init process complete; ready for start up.
LOG:  database system is ready to accept connections
running /docker-entrypoint-initdb.d/01-enable-pgvector.sql
```

### Rollback

```bash
docker rm -f postgres
# If you want to wipe data too:
sudo rm -rf /srv/postgres/data
```

## Step 3.5.5: Verify from lab-datastore

```bash
docker exec -it postgres psql -U postgres -c "SELECT version();"
# PostgreSQL 16.x ...

docker exec -it postgres psql -U postgres -c "\dx"
# Lists installed extensions; vector 0.8.0 should be present
```

## Step 3.5.6: Verify from another lab VM

Proves DNS, routing, firewall, auth all work end-to-end from outside lab-datastore.

```bash
ssh lab-automation
sudo apt install -y postgresql-client
psql -h lab-datastore.lab.local -U postgres -d postgres -c 'SELECT 1;'
```

Expected:

```
 ?column?
----------
        1
(1 row)
```

## Deployed configuration artifacts

- **Postgres container** on `lab-datastore`, `pgvector/pgvector:0.8.0-pg16`, `--restart unless-stopped`, port `192.168.100.205:5432`.
- **Data** at `/srv/postgres/data` (owned by UID 999).
- **Init scripts** at `/srv/postgres/init` (source-controlled at [`../services/postgres/init/`](../services/postgres/init/)).
- **Backups** target at `/srv/postgres/backups` (no automation yet; see Backlog).

## Common operations

### Create a new app database and user

```bash
docker exec -it postgres psql -U postgres
```

Inside psql:

```sql
CREATE DATABASE myapp_db;
CREATE USER myapp_user WITH ENCRYPTED PASSWORD '<app-specific-password>';
GRANT ALL PRIVILEGES ON DATABASE myapp_db TO myapp_user;
\c myapp_db
GRANT ALL ON SCHEMA public TO myapp_user;
-- If the app uses vectors:
CREATE EXTENSION IF NOT EXISTS vector;
\q
```

### Manual backup

```bash
docker exec postgres pg_dumpall -U postgres | gzip > /srv/postgres/backups/dump-$(date -u +%Y%m%dT%H%M%SZ).sql.gz
```

### Restore from a backup

```bash
gunzip -c /srv/postgres/backups/dump-*.sql.gz | docker exec -i postgres psql -U postgres
```

## Gotchas

**A. pgvector is enabled per-database, not globally.** The init script enables `vector` in the default `postgres` database. When you create `myapp_db` later, you have to `CREATE EXTENSION vector` inside that database too. The `init/` scripts only run on first boot; they won't re-run for later-created databases.

**B. `apt install postgresql-client` on jammy (Ubuntu 22.04) installs client 14.x.** It connects to server 16.x fine (client-server protocol backward compatibility is good), but dumps from 16 and restores with 14 can lose features. For dumps from outside the container, use `pg_dump` from the container itself (`docker exec postgres pg_dump -U postgres ...`).

**C. Bind mount UID matters.** Postgres container's `postgres` user is UID 999. `/srv/postgres/data` has to be owned by 999 or the container refuses to start ("permission denied" on PGDATA). `chown -R 999:999 /srv/postgres` once during setup handles this.

**D. Postgres major version bumps require dump/restore or pg_upgrade.** Swapping the image tag from `:pg16` to `:pg17` and restarting won't work; Postgres refuses to open a `pg16` data dir with a `pg17` binary. For major-version upgrades, dump from the old container, spin up a new container on a different data directory, restore, cut over.

**E. Password is in your shell history if you typed it.** Every psql login you did with `-c` or interactive prompt recorded the password in bash history for that user. If that bothers you, `history -c && rm ~/.bash_history` on the VM, and consider setting up `.pgpass` so passwords aren't typed directly.

## Next

From the [`../BACKLOG.md`](../BACKLOG.md) data tier:

- **MinIO** on lab-datastore (`stage-3-minio.md`, planned). S3-compatible object storage for blobs, model artifacts, Loki chunk storage, backup target.
- **Redis** on lab-datastore (`stage-3-redis.md`, planned). Cache, session store, simple queue backend.
- **restic** + cron for automated `pg_dump` + offsite backup (`stage-3-backups.md`, planned).
