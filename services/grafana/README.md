# Grafana

Source-controlled artifacts for the Grafana instance on `lab-platform-eng`.

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on `labnet`. Data at `/srv/grafana/data`, provisioning at `/srv/grafana/provisioning`, dashboard JSON at `/srv/grafana/dashboards`. Reached via nginx at `https://grafana.lab.local`.

## What it does

Queries Prometheus (and Loki, once it lands in step 3.12.6) and renders dashboards. Hosts the alert UI for Prometheus rules. The thing you actually open every day to see how the lab is doing.

## Directory layout

```
/srv/grafana/
  data/                            grafana.db (SQLite), plugins, sessions
  provisioning/
    datasources/prometheus.yml     Auto-creates Prometheus data source
    dashboards/dashboards.yml      Tells Grafana to scan ./dashboards/
  dashboards/                      Drop .json here, Grafana picks them up
```

Ownership: UID 472 (the `grafana` user inside the official image).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/grafana/{data,dashboards} /srv/grafana/provisioning/{datasources,dashboards} && sudo chown -R 472:472 /srv/grafana"

scp -r C:\vmimages\services\grafana\provisioning\* lab-platform-eng:/tmp/provisioning/
ssh lab-platform-eng "sudo cp -r /tmp/provisioning/* /srv/grafana/provisioning/ && sudo chown -R 472:472 /srv/grafana/provisioning && rm -rf /tmp/provisioning"
```

On `lab-platform-eng`, generate the admin password and run:

```bash
GRAFANA_ADMIN_PASS=$(openssl rand -base64 32)
echo "GRAFANA_ADMIN_PASS=$GRAFANA_ADMIN_PASS"
# SAVE in Vaultwarden before the next command.

docker run -d \
    --name grafana \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:3000:3000 \
    -v /srv/grafana/data:/var/lib/grafana \
    -v /srv/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v /srv/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    -e GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASS" \
    -e GF_USERS_ALLOW_SIGN_UP=false \
    -e GF_AUTH_ANONYMOUS_ENABLED=false \
    -e GF_SERVER_ROOT_URL=https://grafana.lab.local \
    -e GF_SERVER_DOMAIN=grafana.lab.local \
    -e GF_ANALYTICS_REPORTING_ENABLED=false \
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e TZ=America/Los_Angeles \
    --user 472:472 \
    --memory 512m \
    grafana/grafana:11.3.0
```

### Login

Username: `admin`, password: whatever was in `$GRAFANA_ADMIN_PASS` (now in Vaultwarden).

### Adding a dashboard

Drop the `.json` into `C:\vmimages\services\grafana\dashboards\`, scp it to `/srv/grafana/dashboards/`, Grafana picks it up within 30 seconds (controlled by `updateIntervalSeconds` in `provisioning/dashboards/dashboards.yml`).

```powershell
scp C:\vmimages\services\grafana\dashboards\node-exporter-full-1860.json lab-platform-eng:/tmp/
ssh lab-platform-eng "sudo mv /tmp/node-exporter-full-1860.json /srv/grafana/dashboards/ && sudo chown 472:472 /srv/grafana/dashboards/*.json"
```

### Updating the image

```bash
docker pull grafana/grafana:11.3.0
docker rm -f grafana
docker run ...   # same command, fresh image
```

Data survives because `/var/lib/grafana` is a bind mount.

## Security notes

- Admin password generated at deploy time, stored in Vaultwarden. Rotate by setting `GF_SECURITY_ADMIN_PASSWORD` and restarting; on next boot Grafana updates the admin user's hash.
- Anonymous access disabled. Sign-up disabled. Single admin user.
- `editable: false` on the Prometheus data source means dashboard authors can't break the URL via the UI; they can only change what the source-controlled file says.
- Internal-only via wildcard `*.lab.local` TLS at lab-gateway nginx. Public access deferred to Cloudflare Tunnel + Access (next stage's pivot).

## Gotchas

- **Provisioned data sources can't be deleted in the UI** (they re-appear on next reload). Edit the YAML and re-deploy if you need a different URL.
- **Dashboard JSON imported from grafana.com sometimes hard-codes a data source UID** that won't match ours. Either swap it in the JSON before saving (find `"datasource"` keys), or use the `${DS_PROMETHEUS}` variable form.
- **The first boot creates `/var/lib/grafana/grafana.db` as 472:472**. If you `sudo rm` and re-deploy without re-chowning, container fails with permission errors.
- **`GF_SERVER_ROOT_URL` matters for OAuth callbacks and embedded panel URLs**. Set it to the public-facing URL, not `localhost:3000`.
