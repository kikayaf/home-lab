# Redis

Source-controlled artifacts for the Redis instance on `lab-datastore`.

## Deployed on

`lab-datastore` (`192.168.100.205`) as a Docker container. Data at `/srv/redis/data`, config at `/srv/redis/conf/redis.conf`.

## What it serves

- **Redis protocol (RESP)** on port `6379`. Apps connect directly to `lab-datastore.lab.local:6379` with the shared password.
- Not HTTP, so no nginx vhost. Apps use a Redis client library (or `redis-cli`) talking RESP over TCP.

## Use cases

- Application cache (sessions, computed results, rate-limit counters).
- Simple work queues (Sidekiq, BullMQ, RQ, Celery with Redis broker).
- Pub/sub between services.
- Distributed locks and leader election (RedLock).

Redis has 16 logical DBs (0-15) in the default instance. Convention: pick a DB index per app (`0 = default app`, `1 = sessions`, etc.). They share memory limits but namespace keys separately.

## Directory layout

```
/srv/redis/
  data/        AOF + RDB files (mounted at /data in the container)
  conf/        redis.conf (mounted read-only at /usr/local/etc/redis/redis.conf)
```

Ownership: UID 999 (the `redis` user inside the alpine image).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-datastore "sudo mkdir -p /srv/redis/{data,conf} && sudo chown -R 999:999 /srv/redis"

scp C:\vmimages\services\redis\conf\redis.conf lab-datastore:/tmp/redis.conf
ssh lab-datastore "sudo mv /tmp/redis.conf /srv/redis/conf/redis.conf && sudo chown 999:999 /srv/redis/conf/redis.conf && sudo chmod 644 /srv/redis/conf/redis.conf"
```

On `lab-datastore`, generate the password and run:

```bash
REDIS_PASS=$(openssl rand -base64 32)
echo "REDIS_PASS=$REDIS_PASS"
# SAVE in password manager before the next command.

docker run -d \
    --name redis \
    --restart unless-stopped \
    -p 192.168.100.205:6379:6379 \
    -v /srv/redis/data:/data \
    -v /srv/redis/conf/redis.conf:/usr/local/etc/redis/redis.conf:ro \
    redis:7-alpine \
    redis-server /usr/local/etc/redis/redis.conf --requirepass "$REDIS_PASS"
```

### Rotating the password

```bash
ssh lab-datastore

NEW_PASS=$(openssl rand -base64 32)
echo "save: $NEW_PASS"

# Update running instance (takes effect immediately for new connections)
docker exec redis redis-cli -a "$OLD_PASS" CONFIG SET requirepass "$NEW_PASS"

# Persist across container restarts by re-running with the new password
docker rm -f redis
docker run -d --name redis ... --requirepass "$NEW_PASS"
```

### Updating the image

```bash
docker pull redis:7-alpine
docker rm -f redis
docker run ...  # same command, fresh image
```

Data survives because it's in the bind mount.

## Connecting

### From the same host (lab-datastore)

```bash
docker exec -it redis redis-cli -a '<password>'
```

### From another lab VM

```bash
sudo apt install -y redis-tools
redis-cli -h lab-datastore.lab.local -p 6379 -a '<password>'
```

### From an app

Connection string shape:

```
redis://:<password>@lab-datastore.lab.local:6379/<db-number>
```

Pick a DB number per app (0-15). Python example:

```python
import redis
r = redis.from_url("redis://:<password>@lab-datastore.lab.local:6379/0")
r.set("foo", "bar")
```

## Security notes

- Single shared password. Use the password manager.
- Port binding `192.168.100.205:6379` (lab subnet only). Not exposed to home network or internet.
- `protected-mode yes` in the config refuses connections that try to bypass auth (belt-and-braces beyond the password).
- No TLS today; add if threat model changes (`tls-port`, etc.).
- ACLs (Redis 6+) let us carve out per-user permissions. Defer until more than one app uses Redis.

## Gotchas

- **`appendfsync everysec`** is a durability/latency tradeoff. Every second, Redis fsyncs the AOF. A crash can lose up to the last second of writes. Fine for cache/session workloads; not appropriate for primary-write-of-record data (use Postgres for that).
- **`maxmemory 256mb`** will evict old keys (LRU) when full. If an app expected Redis to hold all its data, it'll get surprises. Bump the limit or change the policy to `noeviction` (at which point writes start failing when full, which is its own surprise).
- **`redis-cli -a <password>` prints a warning** about password on command line. To silence: `redis-cli --no-auth-warning -a <password>`, or use `REDISCLI_AUTH` env var.
- **AOF rewrites** run in the background and briefly double the file's disk usage. Keep some headroom at `/srv/redis/data`.
