# Alertmanager

Source-controlled artifacts for the Alertmanager instance on `lab-platform-eng`.

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on `labnet`. Data at `/srv/alertmanager/data`, config at `/srv/alertmanager/conf/alertmanager.yml`. Reached via nginx at `https://alerts.lab.local`.

## What it does

Receives alert events from Prometheus, deduplicates and groups them, and routes to receivers (email, Slack, PagerDuty, webhook). Today it routes to a "log only" receiver: alerts appear in Alertmanager's UI, in Prometheus's `/alerts` page, and in Grafana's Alerting view, but no external notification fires. Once the rules have settled and we know what's noisy, we'll wire in Slack or email.

## Directory layout

```
/srv/alertmanager/
  data/                          Notification log + silence store
  conf/
    alertmanager.yml             Source from services/alertmanager/alertmanager.yml
```

Ownership: UID 65534 (the `nobody` user the prom/alertmanager image runs as).

## Deploy / update

### First-time install

From Windows host:

```powershell
ssh lab-platform-eng "sudo mkdir -p /srv/alertmanager/{data,conf} && sudo chown -R 65534:65534 /srv/alertmanager"

scp C:\vmimages\services\alertmanager\alertmanager.yml lab-platform-eng:/tmp/alertmanager.yml
ssh lab-platform-eng "sudo mv /tmp/alertmanager.yml /srv/alertmanager/conf/alertmanager.yml && sudo chown 65534:65534 /srv/alertmanager/conf/alertmanager.yml"
```

On `lab-platform-eng`:

```bash
docker run -d \
    --name alertmanager \
    --restart unless-stopped \
    --network labnet \
    -p 192.168.100.208:9093:9093 \
    -v /srv/alertmanager/data:/alertmanager \
    -v /srv/alertmanager/conf:/etc/alertmanager:ro \
    --user 65534:65534 \
    --memory 128m \
    prom/alertmanager:v0.27.0 \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/alertmanager \
    --web.external-url=https://alerts.lab.local
```

### Reloading config

```bash
docker exec alertmanager kill -HUP 1
```

Or curl:

```bash
curl -X POST http://192.168.100.208:9093/-/reload
```

### Adding a Slack receiver (when ready)

Edit [`./alertmanager.yml`](./alertmanager.yml):

```yaml
receivers:
  - name: log
  - name: slack
    slack_configs:
      - api_url: '<webhook-url>'
        channel: '#lab-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}'

route:
  receiver: log
  routes:
    - matchers: ['severity="critical"']
      receiver: slack
      continue: true
```

Then push + reload.

## Security notes

- No auth on Alertmanager itself. The vhost is behind nginx with wildcard `*.lab.local` TLS, lab-subnet only. If we want stronger gating, add nginx basic auth or Cloudflare Access.
- The Slack webhook URL (when added) is a secret. Store it in Vaultwarden and pass via env, not in the source-controlled config. Alertmanager supports `api_url_file:` to point at a file path; mount that from `/srv/alertmanager/conf/secrets/`.

## Gotchas

- **Inhibit rules silence one alert when another fires**. Our config inhibits per-service alerts when InstanceDown for the host fires. This is to avoid the "datastore is down AND postgres is down AND redis is down" cascade.
- **Group_wait + group_interval matter**. `group_wait: 30s` waits up to 30s after the first alert in a group to send the notification. Useful so multiple correlated alerts batch into one message. `group_interval: 5m` is the cadence of follow-ups for the same group while still firing.
- **The "log" receiver is a no-op receiver**. Alerts still appear in the Alertmanager UI; nothing is sent externally. This is intentional during initial tuning.
- **Persistent silences live in `/alertmanager/silences`** under the data volume. Don't `sudo rm -rf /srv/alertmanager/data` casually; you'll lose the silence history.
- **Web-external-url must match the public URL** so emailed/Slacked alert links work. We pass `https://alerts.lab.local` at runtime.
