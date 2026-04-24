#!/usr/bin/env bash
# =============================================================================
# ufw additions for lab-gateway (edge host)
# =============================================================================
# Run AFTER baseline.sh on the same host. This adds rules needed only because
# lab-gateway is the edge of the lab:
#
#   - DNS (port 53 UDP + TCP) from the lab subnet, for CoreDNS
#     (Docker-published, so technically it's reachable already via Docker's
#     own iptables rules; we add the ufw rule for clarity and for any future
#     deployment that moves CoreDNS off Docker.)
#
#   - HTTP (port 80) from anywhere, for nginx reverse proxy. Same note as DNS
#     above re: Docker bypass.
#
#   - HTTPS (port 443) reserved for later.
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

LAB_SUBNET="192.168.100.0/24"

echo "[ufw/gw] Allowing DNS (53/udp + 53/tcp) from lab subnet..."
ufw allow from "$LAB_SUBNET" to any port 53 proto udp comment 'CoreDNS from lab'
ufw allow from "$LAB_SUBNET" to any port 53 proto tcp comment 'CoreDNS from lab'

echo "[ufw/gw] Allowing HTTP (80/tcp) from anywhere..."
ufw allow 80/tcp comment 'nginx reverse proxy'

echo "[ufw/gw] (reserved) HTTPS 443/tcp - add when TLS is configured"
# ufw allow 443/tcp comment 'nginx reverse proxy TLS'

echo "[ufw/gw] Current status:"
ufw status verbose
