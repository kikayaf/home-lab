#!/usr/bin/env bash
# =============================================================================
# Install Promtail as a systemd service on a lab VM.
# =============================================================================
# Idempotent. Safe to re-run.
#
# Promtail runs as root because it reads journald, /var/log/*, and
# /var/lib/docker/containers/*/*-json.log. Each path needs root or a
# specific systemd group; running as root keeps the install simple.
# =============================================================================

set -euo pipefail

PROMTAIL_VERSION="3.4.1"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

if systemctl is-active --quiet promtail; then
    echo "[$(hostname)] promtail already active. Reinstalling config + restarting."
    sudo systemctl stop promtail
fi

echo "[$(hostname)] Installing Promtail v${PROMTAIL_VERSION} for ${ARCH}"

# Download release zip, extract binary
cd /tmp
curl -fsSL "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip" -o promtail.zip
sudo apt-get install -y unzip > /dev/null 2>&1 || true
unzip -o promtail.zip > /dev/null
sudo install -o root -g root -m 0755 promtail-linux-${ARCH} /usr/local/bin/promtail
rm -f promtail.zip promtail-linux-${ARCH}

# Directories
sudo mkdir -p /etc/promtail /var/lib/promtail
sudo chown root:root /etc/promtail /var/lib/promtail

# Push config: the install.sh is run with the config in the same dir
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -f "$SCRIPT_DIR/promtail-config.yml" ]; then
    sudo cp "$SCRIPT_DIR/promtail-config.yml" /etc/promtail/promtail-config.yml
    sudo chown root:root /etc/promtail/promtail-config.yml
    sudo chmod 644 /etc/promtail/promtail-config.yml
elif [ -f /tmp/promtail-config.yml ]; then
    sudo mv /tmp/promtail-config.yml /etc/promtail/promtail-config.yml
    sudo chown root:root /etc/promtail/promtail-config.yml
    sudo chmod 644 /etc/promtail/promtail-config.yml
else
    echo "[$(hostname)] ERROR: promtail-config.yml not found in script dir or /tmp" >&2
    exit 1
fi

# Systemd unit
sudo tee /etc/systemd/system/promtail.service > /dev/null <<'EOF'
[Unit]
Description=Promtail (Loki log shipper)
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment="HOSTNAME=%H"
ExecStart=/usr/local/bin/promtail \
    -config.file=/etc/promtail/promtail-config.yml \
    -config.expand-env=true
Restart=on-failure
RestartSec=5s

# Hardening (kept loose because Promtail needs to read /var/log and journald)
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now promtail

# Smoke test
sleep 2
if curl -fsS http://127.0.0.1:9080/ready > /dev/null; then
    echo "[$(hostname)] promtail OK on :9080"
else
    echo "[$(hostname)] promtail NOT ready on :9080" >&2
    sudo systemctl status promtail --no-pager | tail -20
    exit 1
fi
