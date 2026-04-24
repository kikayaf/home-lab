# Stage 3, Step 7: Redis on lab-datastore

## Goal

Stand up Redis on `lab-datastore` as the lab's in-memory data store. Completes the data-tier trio (Postgres relational + MinIO object + Redis in-memory).

## Architecture change

**Before (end of step 3.6):** apps needing a cache, session store, rate-limit counter, simple queue, or pub/sub had nothing to reach for.

**After:** Redis 7 reachable at `lab-datastore.lab.local:6379` with a shared password. Apps carve out DB indexes (0-15) as they land.

## Prerequisites

- Docker on `lab-datastore` (installed in step 3.5).
- Stage 2 DNS + ufw so other VMs can reach `lab-datastore:6379`.
- Stage 2 cloud-init disable already applied on every VM (so netplan doesn't get rewritten if we hot-add anything later).

## Step 3.7.1: Config file + directory layout

Non-secret Redis config lives in [`../services/redis/conf/redis.conf`](../services/redis/conf/redis.conf): bind to all interfaces (port is scoped via Docker binding), AOF + RDB persistence, 256 MB cache with LRU eviction, notice-level logging. Password is not in the file; it's injected at runtime via `--requirepass`.

Push config and create directories:

```powershell
ssh lab-datastore "sudo mkdir -p /srv/redis/{data,conf} && sudo chown -R 999:999 /srv/redis"
scp C:\vmimages\services\redis\conf\redis.conf lab-datastore:/tmp/redis.conf
ssh lab-datastore "sudo mv /tmp/redis.conf /srv/redis/conf/redis.conf && sudo chown 999:999 /srv/redis/conf/redis.conf && sudo chmod 644 /srv/redis/conf/redis.conf"
```

UID 999 is the `redis` user inside the alpine image.

## Step 3.7.2: Generate password and deploy

On lab-datastore:

```bash
REDIS_PASS=$(openssl rand -base64 32)
echo "REDIS_PASS=$REDIS_PASS"
# SAVE in password manager before running the container.

docker run -d \
    --name redis \
    --restart unless-stopped \
    -p 192.168.100.205:6379:6379 \
    -v /srv/redis/data:/data \
    -v /srv/redis/conf/redis.conf:/usr/local/etc/redis/redis.conf:ro \
    redis:7-alpine \
    redis-server /usr/local/etc/redis/redis.conf --requirepass "$REDIS_PASS"
```

### Design notes

- **Image**: `redis:7-alpine`. Tiny, OSS, current major. After first pull, pin to the exact tag shown by `docker inspect redis --format '{{.Config.Image}}'` (we're on `7.4.8` as of deploy).
- **Port binding** to `192.168.100.205:6379`: lab subnet only. Home network and internet can't reach Redis directly.
- **`--requirepass` on CLI, not in config file**: keeps the password out of the source-controlled config and out of the image. Rotations are one docker-run away; the committed config file is unchanged.
- **AOF enabled** (`appendonly yes`, `appendfsync everysec`): crash-consistent within 1 second, good balance for cache/session workloads. If an app truly needs zero data loss, use Postgres.
- **`maxmemory 256mb` + `allkeys-lru`**: eviction when full. Bump the limit if an app legitimately needs more.

## Step 3.7.3: Kernel tweak to silence the overcommit warning

Redis logs a warning about `vm.overcommit_memory` on boot. Fix once:

```bash
echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-redis.conf
sudo sysctl -p /etc/sysctl.d/99-redis.conf
```

Persistent across reboots. Redis's background saves and replication won't occasionally fail under memory pressure.

## Step 3.7.4: Verify

Locally:

```bash
docker exec -it redis redis-cli -a "$REDIS_PASS" --no-auth-warning PING
# PONG

docker exec -it redis redis-cli -a "$REDIS_PASS" --no-auth-warning SET hello "world from redis"
docker exec -it redis redis-cli -a "$REDIS_PASS" --no-auth-warning GET hello
# "world from redis"
```

From another lab VM:

```bash
ssh lab-automation
sudo apt install -y redis-tools
redis-cli --no-auth-warning -h lab-datastore.lab.local -p 6379 -a '<paste-password>' PING
# PONG
```

Remote PONG proves DNS resolution, lab-subnet routing, ufw allowance (baseline allows all lab-subnet traffic), and password auth are all working.

## Deployed configuration artifacts

- **Redis container** on lab-datastore: `redis:7-alpine` (7.4.8), `--restart unless-stopped`, port `192.168.100.205:6379`.
- **Config** at `/srv/redis/conf/redis.conf` (source at [`../services/redis/conf/redis.conf`](../services/redis/conf/redis.conf)).
- **Data** at `/srv/redis/data` (AOF + RDB files, mounted at `/data` in the container).
- **Kernel config** `/etc/sysctl.d/99-redis.conf` setting `vm.overcommit_memory = 1`.

## Common operations

### Interactive CLI

```bash
docker exec -it redis redis-cli -a '<password>' --no-auth-warning
```

Inside:

```
127.0.0.1:6379> INFO server
127.0.0.1:6379> DBSIZE
127.0.0.1:6379> KEYS *
127.0.0.1:6379> FLUSHDB    # wipe current db
127.0.0.1:6379> SELECT 1   # switch to db 1
```

### Connect from an app

```
redis://:<password>@lab-datastore.lab.local:6379/<db-number>
```

Python:

```python
import redis
r = redis.from_url("redis://:<password>@lab-datastore.lab.local:6379/0")
```

Go:

```go
rdb := redis.NewClient(&redis.Options{
    Addr:     "lab-datastore.lab.local:6379",
    Password: "<password>",
    DB:       0,
})
```

### Carve out a DB per app

Redis has 16 logical DBs (0-15) in one instance. Convention: assign each app its own DB number in the repo (e.g., `docs/redis-db-assignments.md`). They share memory and password but isolate keyspaces.

### Backup

RDB snapshots land at `/srv/redis/data/dump.rdb` automatically per the `save` directives. For an ad-hoc snapshot:

```bash
docker exec redis redis-cli -a '<password>' --no-auth-warning BGSAVE
# then copy /srv/redis/data/dump.rdb somewhere safe
```

Will be rolled into restic automation along with Postgres and MinIO when that lands.

## Gotchas

**A. `appendfsync everysec` loses up to 1s of writes on crash.** Fine for cache/session/queue workloads; not appropriate for primary system-of-record data (use Postgres for that).

**B. `maxmemory 256mb` evicts LRU keys when full.** If an app assumed Redis would hold all its data, it'll get surprises. Either bump the limit or accept that cache contents come and go.

**C. `redis-cli -a <password>` warns about command-line password.** Use `--no-auth-warning` or set `REDISCLI_AUTH` env var. Doesn't affect correctness.

**D. `vm.overcommit_memory = 1`** is recommended by Redis but relaxes the kernel's memory accounting. For a lab, this is fine; in production with mixed workloads, evaluate per host.

**E. No TLS.** In-lab traffic only. Password is the only auth. Add `tls-port` + cert material if a threat model requires it.

**F. DB index vs Redis Cluster.** The 16-DB convention works for small apps. If we ever need horizontal scale, Cluster mode forbids multi-DB. Use separate Redis instances per app by then.

## Next

From the remaining data-tier + near-term list in [`../BACKLOG.md`](../BACKLOG.md):

- **Vaultwarden** on lab-datastore (password vault backed by Postgres). Ends the "passwords in chat" problem.
- **restic backup automation** for Postgres + MinIO + Redis → MinIO (local) + offsite.
- **Structurizr Lite** on lab-platform-eng (closes self-documenting loop).
- **Observability stack** (Prometheus + Grafana + Loki) on k3s or lab-ai-ops.
