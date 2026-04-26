#!/usr/bin/env bash
# =============================================================================
# Install node_exporter as a systemd service on a lab VM.
# =============================================================================
# Idempotent. Safe to re-run.
#
# Listens on :9100 over the lab interface. Prometheus on lab-platform-eng
# scrapes every VM's node_exporter (see services/prometheus/prometheus.yml).
# =============================================================================

set -euo pipefail

NE_VERSION="1.8.2"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

if systemctl is-active --quiet node_exporter; then
    echo "[$(hostname)] node_exporter already active. Skipping install."
    exit 0
fi

echo "[$(hostname)] Installing node_exporter v${NE_VERSION} for ${ARCH}"

# System user. Idempotent: the || true swallows "already exists".
sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true

# Download release tarball, extract binary
cd /tmp
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-${ARCH}.tar.gz" -o node_exporter.tar.gz
tar xzf node_exporter.tar.gz
sudo install -o node_exporter -g node_exporter -m 0755 \
    "node_exporter-${NE_VERSION}.linux-${ARCH}/node_exporter" \
    /usr/local/bin/node_exporter
rm -rf "node_exporter-${NE_VERSION}.linux-${ARCH}" node_exporter.tar.gz

# Systemd unit (heredoc to /etc/systemd/system/)
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOF'
[Unit]
Description=Prometheus node_exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address=:9100 \
    --collector.systemd \
    --collector.processes
Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# Smoke test
sleep 1
if curl -fsS http://127.0.0.1:9100/metrics > /dev/null; then
    echo "[$(hostname)] node_exporter OK on :9100"
else
    echo "[$(hostname)] node_exporter NOT responding on :9100" >&2
    sudo systemctl status node_exporter --no-pager
    exit 1
fi
