# Stage 2, Step 7: ufw firewall policy on every VM

## Goal

Harden every lab VM with a host firewall. Default deny incoming, allow outgoing, trust the lab subnet and the tailnet, plus edge openings (DNS, HTTP) on lab-gateway. Layer of defense on top of the network-level isolation already provided by the Lab vSwitch and Tailscale.

## Architecture change

**Before (end of step 6):** host firewall was installed but inactive on every VM. Any open port on any VM was reachable from anywhere that could route to it. Network-level barriers (NAT, lab subnet isolation) were doing the work alone.

**After (end of step 7):** every lab VM has ufw active with:

- Default deny inbound, allow outbound.
- Trust lab subnet (`192.168.100.0/24`) end to end.
- Trust the `tailscale0` interface (only present on `lab-gateway`).
- lab-gateway additionally accepts DNS (53) from the lab subnet and HTTP (80) from anywhere.

## Prerequisites

- Steps 1-6 complete.
- SSH access to every lab VM from the Windows host.

## Step 7.1: Write the baseline + gateway-extras scripts

### What we did

Added two scripts in the repo:

- [`../services/ufw/baseline.sh`](../services/ufw/baseline.sh): runs on every lab VM. Installs ufw if not present, sets defaults, allows the lab subnet and `tailscale0` (if the interface exists), then enables ufw.
- [`../services/ufw/lab-gateway.sh`](../services/ufw/lab-gateway.sh): runs only on `lab-gateway`. Adds DNS (53 udp + tcp from lab subnet) and HTTP (80 tcp from anywhere) openings.

Both idempotent. Safe to re-run.

## Step 7.2: Apply the baseline to one VM first

Tested the baseline on `lab-platform-eng` before rolling out, to catch any lockout before it happened everywhere:

```powershell
scp C:\vmimages\services\ufw\baseline.sh lab-platform-eng:/tmp/baseline.sh
ssh lab-platform-eng "sudo bash /tmp/baseline.sh"
```

Watched `ufw status verbose`, confirmed SSH from the Windows host still worked by running a follow-up SSH. Good, proceeded to the fleet.

## Step 7.3: Apply the baseline to the remaining 7 VMs

```powershell
. C:\vmimages\scripts\00-config.ps1

foreach ($v in $LAB_VMS) {
    if ($v.Hostname -eq 'lab-platform-eng') { continue }
    $h = $v.Hostname
    Write-Host "`n--- $h ---" -ForegroundColor Cyan
    scp C:\vmimages\services\ufw\baseline.sh "${h}:/tmp/baseline.sh"
    ssh $h "sudo bash /tmp/baseline.sh"
}
```

Every VM prints `Status: active` with the baseline rules. On `lab-gateway`, the script also adds `Anywhere on tailscale0 ALLOW IN Anywhere` because `tailscale0` is present there.

## Step 7.4: Apply lab-gateway extras

```powershell
scp C:\vmimages\services\ufw\lab-gateway.sh lab-gateway:/tmp/lab-gateway.sh
ssh lab-gateway "sudo bash /tmp/lab-gateway.sh"
```

Adds:

- `53/udp ALLOW IN 192.168.100.0/24` — CoreDNS from the lab subnet.
- `53/tcp ALLOW IN 192.168.100.0/24` — CoreDNS fallback (large responses, zone transfers).
- `80/tcp ALLOW IN Anywhere` — nginx reverse proxy.

443/tcp is reserved for when we turn on TLS; currently commented out.

## Step 7.5: Verify

From Windows host (lab subnet), SSH round-trip to every VM:

```powershell
. C:\vmimages\scripts\00-config.ps1
foreach ($v in $LAB_VMS) {
    $h = $v.Hostname
    $result = ssh -o ConnectTimeout=5 -o BatchMode=yes $h "hostname" 2>&1
    Write-Host ("{0,-22} {1}" -f $h, $result)
}
```

Expected: 8 rows echoing each VM's hostname.

From Mac (tailnet, subnet-routed through lab-gateway):

```bash
ssh adminuser@lab-gateway.lab.local hostname        # lab-gateway
ssh adminuser@lab-datastore.lab.local hostname      # lab-datastore
curl -s http://arch.lab.local/ | head -3            # nginx 404 text
dig lab-gateway.lab.local +short                    # 192.168.100.201
```

All passed after deploying the firewall. No lockouts.

## Deployed configuration artifacts

**`services/ufw/baseline.sh`** applied on every lab VM. Final rule set (baseline only):

```
Default: deny (incoming), allow (outgoing), allow (routed)

22/tcp        ALLOW IN    192.168.100.0/24           # SSH from lab
Anywhere      ALLOW IN    192.168.100.0/24           # lab subnet - full access
<on lab-gateway only>
Anywhere on tailscale0    ALLOW IN    Anywhere       # tailscale tailnet peers
```

**`services/ufw/lab-gateway.sh`** applied on lab-gateway only. Additional rules:

```
53/udp        ALLOW IN    192.168.100.0/24           # CoreDNS from lab
53/tcp        ALLOW IN    192.168.100.0/24           # CoreDNS from lab
80/tcp        ALLOW IN    Anywhere                   # nginx reverse proxy
```

## Gotchas

**A. Pre-existing ufw rules baked into the template.** Every lab VM came up with these rules already present (ufw installed but inactive):

```
22/tcp       ALLOW IN  Anywhere
10445        ALLOW IN  Anywhere
31403        ALLOW IN  Anywhere
11434/tcp    ALLOW IN  Anywhere     # Ollama default port
3000         ALLOW IN  Anywhere     # Grafana default port
```

Once ufw is enabled, those openings become active too. They were tolerable before because ufw wasn't enforcing; now they're the only "anywhere" rules other than HTTP on lab-gateway. Not dangerous given the lab sits behind home NAT and Tailscale, but a tightening pass is worth doing later (scope to lab subnet or tailnet, or remove entirely if the ports aren't being used). Tracked as tech debt.

**B. Docker-published ports bypass ufw.** `docker run -p 192.168.100.201:53:53` creates iptables DNAT rules that run before ufw's filter chains. So CoreDNS (53) and nginx (80) are reachable per Docker's binding regardless of ufw. In our design this is exactly what we want, but worth naming so no one is surprised later. The ufw rules we added for 53 and 80 are redundant while those services are Dockerized; they become meaningful if either service ever moves to a non-Docker binding on the host.

**C. `default allow routed`.** Added to baseline.sh because `lab-gateway` forwards lab traffic via iptables NAT (step 3). ufw's default for routed traffic is `deny` in some Ubuntu versions, which would silently break forwarding. Explicitly setting `allow` avoids that.

**D. Tailscale subnet routing preserves the lab source IP.** When Mac sends SSH to `192.168.100.202` over tailnet, Tailscale's subnet router on `lab-gateway` SNATs the connection so the target VM sees it as originating from `192.168.100.201` (or whatever lab IP lab-gateway presents). That makes our `allow from 192.168.100.0/24` rule sufficient for tailnet SSH; we didn't need a separate tailnet rule on the non-gateway VMs.

## Rollback

Per VM, reach via VMConnect or Tailscale (tailscale0 rule on lab-gateway always lets tailnet peers through) and:

```bash
sudo ufw disable        # keeps rules in /etc/ufw/, stops enforcement
sudo ufw reset          # wipes all rules, returns to factory defaults (still disabled)
```

## Stage 2 is complete

Every item from the stage 2 plan is implemented, verified, and documented:

| # | Step | Runbook |
|---|---|---|
| 1 | Tailscale on lab-gateway | [stage-2-lab-gateway.md](./stage-2-lab-gateway.md) |
| 2 | Second NIC on lab-gateway | [stage-2-lab-gateway.md](./stage-2-lab-gateway.md) |
| 3 | IP forwarding + iptables NAT | [stage-2-lab-gateway.md](./stage-2-lab-gateway.md) |
| 4 | Fleet default gateway flipped to `.201` | [stage-2-lab-gateway.md](./stage-2-lab-gateway.md) |
| 5 | CoreDNS + Tailscale Split DNS | [stage-2-step-5-coredns.md](./stage-2-step-5-coredns.md) |
| 6 | nginx reverse proxy + DNS wildcard | [stage-2-step-6-nginx.md](./stage-2-step-6-nginx.md) |
| 7 | ufw host firewall (this runbook) | you are here |

Lab is ready for stage 3: actually running workloads. k3s cluster on the three `lab-k3s-*` VMs, data services (PostgreSQL, MinIO) on `lab-datastore`, observability (Prometheus, Grafana, Loki) on `lab-ai-ops`, Structurizr Lite on `lab-platform-eng`, and so on. Each of those gets its own nginx vhost in `services/nginx/conf.d/` and a service-specific runbook.
