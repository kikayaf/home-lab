#!/bin/bash
# =============================================================================
# 02 - Template Cleanup (runs inside the template VM via SSH)
# =============================================================================
# Installs Hyper-V integration daemons + cloud-init, pins datasource to
# NoCloud, wipes machine-id / cloud-init state / SSH host keys, regenerates
# host keys so the template itself stays SSH-able, and powers off.
#
# Pins the template to a static IP (192.168.1.200) so 01-prepare-template.ps1
# can SSH back in on every re-prep. Clones never run this script; their seed
# ISO overwrites /etc/netplan/50-cloud-init.yaml on first boot, so they take
# on whatever IP the seed ISO specifies.
# =============================================================================

set -e

echo "[02] Updating apt and installing prerequisites..."
sudo apt update
sudo apt install -y hyperv-daemons cloud-init openssh-server

echo "[02] Enabling Hyper-V integration daemons..."
sudo systemctl enable --now hv-kvp-daemon.service hv-fcopy-daemon.service hv-vss-daemon.service
sudo systemctl enable --now ssh

echo "[02] Setting template hostname to temp-host..."
sudo hostnamectl set-hostname temp-host
sudo sed -i 's/127\.0\.1\.1.*/127.0.1.1 temp-host/' /etc/hosts
grep -q '127.0.1.1' /etc/hosts || echo '127.0.1.1 temp-host' | sudo tee -a /etc/hosts

echo "[02] Writing static netplan (192.168.1.200/24)..."
sudo tee /etc/netplan/50-cloud-init.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses: [192.168.1.200/24]
      routes:
        - to: default
          via: 192.168.1.254
      nameservers:
        addresses: [192.168.1.254, 1.1.1.1]
EOF
sudo chmod 600 /etc/netplan/50-cloud-init.yaml

echo "[02] Locking cloud-init to NoCloud datasource..."
sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg > /dev/null <<'EOF'
datasource_list: [ NoCloud, None ]
EOF
sudo rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "[02] Wiping machine-id and cloud-init state..."
sudo cloud-init clean --logs
sudo rm -rf /var/lib/cloud/instances/*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

echo "[02] Regenerating SSH host keys..."
sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A

echo "[02] Clearing logs and history..."
sudo rm -f /var/log/*.log
sudo rm -rf /var/log/journal/*
rm -f ~/.bash_history
sudo rm -f /root/.bash_history

echo "[02] Template cleanup complete. Shutting down..."
sudo shutdown now
