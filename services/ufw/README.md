# ufw firewall policy

Source-controlled host firewall rules for every lab VM.

## Files

- `baseline.sh` — runs on every lab VM. Default deny incoming, allow outgoing, allow lab subnet (`192.168.100.0/24`), allow the `tailscale0` interface if present.
- `lab-gateway.sh` — runs additionally on `lab-gateway` only. Adds DNS (53) and HTTP (80) openings.

Both are idempotent: safe to re-run any time.

## Deploy / update

### Apply baseline to one VM

```powershell
scp C:\vmimages\services\ufw\baseline.sh <hostname>:/tmp/baseline.sh
ssh <hostname> "sudo bash /tmp/baseline.sh"
```

### Apply baseline to the whole fleet

```powershell
. C:\vmimages\scripts\00-config.ps1
foreach ($v in $LAB_VMS) {
    $h = $v.Hostname
    Write-Host "--- $h ---" -ForegroundColor Cyan
    scp C:\vmimages\services\ufw\baseline.sh "${h}:/tmp/baseline.sh"
    ssh $h "sudo bash /tmp/baseline.sh"
}
```

### Apply lab-gateway extras (edge openings)

```powershell
scp C:\vmimages\services\ufw\lab-gateway.sh lab-gateway:/tmp/lab-gateway.sh
ssh lab-gateway "sudo bash /tmp/lab-gateway.sh"
```

## What the policy does (and doesn't)

**Does:**

- Denies any inbound connection that isn't explicitly allowed.
- Trusts the lab subnet (`192.168.100.0/24`) and the tailnet end-to-end (any traffic on `tailscale0`).
- On lab-gateway, allows DNS and HTTP from outside the lab so the edge actually functions as an edge.

**Doesn't:**

- Firewall traffic between containers on the same host (Docker has its own iptables chains that sit before ufw).
- Firewall ports published by `docker run -p host:container` (same reason). These are intentional; ufw still protects the host's own listeners.
- Do egress filtering. Outbound is allowed to everywhere. If you want to restrict where the lab can reach on the public internet, that belongs on `lab-gateway` as iptables rules on eth1, not ufw on individual VMs.

## Rollback

If you get locked out, reach the VM via VMConnect or Tailscale (tailscale0 is explicitly allowed, so tailnet peers can always reach). Then:

```bash
sudo ufw disable        # keeps the rules in /etc/ufw/, just stops enforcement
sudo ufw reset          # wipes all rules and goes back to ufw's default state (still disabled)
```

## Adding a new exposed port

If you later want, say, Prometheus on `lab-ai-ops:9090` to be reachable from the tailnet directly (not via nginx proxy), the baseline already covers it: `allow in on tailscale0` lets tailnet traffic reach any port. No edit needed.

To expose a port to the whole home network, that would be a new rule on `lab-gateway.sh` with `proxy_pass` on nginx. Don't open host-level ports to the home network unless you have a specific reason.
