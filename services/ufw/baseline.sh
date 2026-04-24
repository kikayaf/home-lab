#!/usr/bin/env bash
# =============================================================================
# ufw baseline policy for every lab VM
# =============================================================================
# Idempotent. Safe to re-run.
#
# Policy:
#   default deny incoming, default allow outgoing
#   allow all traffic from the lab subnet (192.168.100.0/24)
#   allow all traffic on the tailscale0 interface (tailnet peers)
#   allow SSH (port 22) explicitly from the lab subnet as a belt-and-braces
#     rule (the "allow from 192.168.100.0/24" rule above covers it too)
#
# Usage:
#   scp this script to the VM, then:
#     sudo bash /tmp/baseline.sh
#
# Rollback (if needed):
#   sudo ufw disable     (keeps rules, just doesn't enforce)
#   sudo ufw reset       (wipes all rules)
# =============================================================================

set -euo pipefail

# Re-exec with sudo if not already root
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

LAB_SUBNET="192.168.100.0/24"

echo "[ufw] Installing ufw if not present..."
if ! command -v ufw >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
fi

echo "[ufw] Setting defaults..."
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed    # lets lab-gateway forward packets (important for gateway)

echo "[ufw] Allowing lab subnet ($LAB_SUBNET) for all traffic..."
ufw allow from "$LAB_SUBNET" comment 'lab subnet - full access'

echo "[ufw] Allowing SSH from lab subnet explicitly..."
ufw allow from "$LAB_SUBNET" to any port 22 proto tcp comment 'SSH from lab'

echo "[ufw] Allowing all traffic on tailscale0 (if the interface exists)..."
if ip link show tailscale0 >/dev/null 2>&1; then
    ufw allow in on tailscale0 comment 'tailscale tailnet peers'
else
    echo "[ufw]   tailscale0 not present on this host, skipping."
fi

echo "[ufw] Enabling ufw..."
ufw --force enable

echo "[ufw] Current status:"
ufw status verbose
