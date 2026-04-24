# Stage 2, Step 5: CoreDNS on lab-gateway + Tailscale Split DNS

## Goal

Give the lab its own DNS authority for `*.lab.local` so every host (lab VMs plus tailnet devices) resolves lab names without per-machine `/etc/hosts` entries. Also set up the pattern for running stateful services as Docker containers on lab-gateway.

## Architecture change

**Before (end of step 4):**

```
Lab VM dig lab-datastore.lab.local  →  /etc/hosts lookup only (static)
Mac dig lab-datastore.lab.local     →  NXDOMAIN (Mac has no /etc/hosts entry)
```

Lab hostnames only work because cloud-init baked `/etc/hosts` on every VM. Your Mac or any tailnet device can't resolve them without manual hosts-file hacks.

**After (end of step 5):**

```
Lab VM dig lab-datastore.lab.local  →  192.168.100.201 (CoreDNS)  →  answer
Mac dig lab-datastore.lab.local     →  Tailscale Split DNS
                                    →  192.168.100.201 (CoreDNS via subnet route)
                                    →  answer
```

CoreDNS is authoritative for `lab.local` and forwards everything else upstream. `ssh lab-datastore.lab.local` works from any tailnet device with zero config.

## Prerequisites

- Steps 1-4 complete: lab-gateway dual-homed, NAT'ing, reachable via Tailscale, every lab VM's default gateway is `.201`.
- Tailscale admin access (you're signed in at https://login.tailscale.com/admin).

## Step 5.1: Install Docker on lab-gateway

### What we did

Installed the Docker CE stack on `lab-gateway`. First Docker install in the lab. Also sets up the container runtime for later services (nginx in step 6, Structurizr Lite eventually).

### Commands

On `lab-gateway`:

```bash
curl -fsSL https://get.docker.com | sudo sh

sudo usermod -aG docker adminuser
exit
ssh lab-gateway   # reconnect so the group membership takes effect
```

### Verify

```bash
docker version                         # both Client and Server should print
docker run --rm hello-world            # should pull and print the hello text
systemctl status docker --no-pager     # active (running)
```

### Rollback

```bash
sudo systemctl disable --now docker containerd
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
```

## Step 5.2: Write the Corefile

### What we did

Created a CoreDNS `Corefile` in the repo at [`../services/coredns/Corefile`](../services/coredns/Corefile). Two zones:

- **`lab.local`**: authoritative, populated by the `hosts` plugin with static A records for every lab VM.
- **`.`**: everything else, forwarded to `1.1.1.1` and `8.8.8.8`, cached 5 minutes.

`reload 5s` inside the `hosts` block means edits to the file are picked up without restarting the container.

### Deploy

From Windows PowerShell:

```powershell
scp C:\vmimages\services\coredns\Corefile lab-gateway:/tmp/Corefile
ssh lab-gateway "sudo mkdir -p /opt/coredns && sudo mv /tmp/Corefile /opt/coredns/Corefile && sudo chmod 644 /opt/coredns/Corefile"
```

Keeping the config source-controlled from day one: `services/coredns/Corefile` is the source of truth; `/opt/coredns/Corefile` on lab-gateway is the deployed copy.

## Step 5.3: Run CoreDNS as a Docker container

### What we did

Launched CoreDNS bound only to lab-gateway's lab-network IP (`192.168.100.201:53`) so we don't conflict with `systemd-resolved` which already owns `127.0.0.53:53` for the host's own lookups.

### Commands

```bash
docker run -d \
    --name coredns \
    --restart unless-stopped \
    -p 192.168.100.201:53:53/udp \
    -p 192.168.100.201:53:53/tcp \
    -v /opt/coredns:/etc/coredns:ro \
    coredns/coredns:1.11.3 \
    -conf /etc/coredns/Corefile
```

Flags:

- `--restart unless-stopped`: auto-start on host reboot unless explicitly stopped by operator.
- `-p 192.168.100.201:53:53/(udp|tcp)`: publish on the lab interface only.
- `-v /opt/coredns:/etc/coredns:ro`: mount the Corefile read-only so the container can't accidentally modify it.
- Image pinned to `1.11.3` for reproducibility; bump deliberately.

### Verify

```bash
docker ps --filter name=coredns           # Up N seconds
docker logs coredns --tail 20             # CoreDNS-1.11.3 ready, listening on .:53 and lab.local.:53
```

### Rollback

```bash
docker stop coredns
docker rm coredns
```

## Step 5.4: Verify resolution from lab-gateway

```bash
dig @192.168.100.201 lab-k3s-controlplane.lab.local +short
# expect: 192.168.100.202

dig @192.168.100.201 lab-datastore.lab.local +short
# expect: 192.168.100.205

dig @192.168.100.201 cloudflare.com +short
# expect: 104.x.x.x (via forward to upstream)
```

First two prove authoritative resolution for the lab zone; third proves upstream forwarding.

## Step 5.5: Point the other 7 VMs' DNS at lab-gateway

### What we did

Updated every lab VM (except lab-gateway itself) to use `192.168.100.201` as primary DNS with `1.1.1.1` as fallback. Done via a PowerShell loop with sed inside the `nameservers:` block of each VM's netplan.

### Commands

From Windows PowerShell in `scripts/`:

```powershell
. .\00-config.ps1

foreach ($v in $LAB_VMS) {
    if ($v.Hostname -eq 'lab-gateway') { continue }
    $h = $v.Hostname
    $cmd = @'
set -e
sudo sed -i '/nameservers:/,/search:/{s/- 1\.1\.1\.1$/- 192.168.100.201/;s/- 8\.8\.8\.8$/- 1.1.1.1/}' /etc/netplan/50-cloud-init.yaml
sudo netplan apply 2>/dev/null
'@
    ssh $h $cmd
}
```

Why keep `1.1.1.1` as fallback: if CoreDNS container is down for maintenance, lab VMs can still resolve public DNS and reach the internet. Lab-local names fail during that window; that's acceptable.

Why lab-gateway itself keeps its own DNS as `1.1.1.1 8.8.8.8`: we don't want lab-gateway to depend on a container running on itself for its own DNS. Avoids a lookup-loop if CoreDNS crashes.

### Verify

```bash
# On any lab VM:
resolvectl dns               # Link 2 (eth0): 192.168.100.201 1.1.1.1
dig lab-datastore.lab.local +short   # 192.168.100.205
```

### Rollback

```bash
sudo sed -i '/nameservers:/,/search:/{s/- 192\.168\.100\.201$/- 1.1.1.1/;s/- 1\.1\.1\.1$/- 8.8.8.8/}' /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

## Step 5.6: Verify from any lab VM

(Happens implicitly in the dig step above. If `dig lab-datastore.lab.local` returns `192.168.100.205` from the VM's default resolver, you're done here.)

## Step 5.7: Tailscale Split DNS

### What we did

Configured Tailscale so queries for `*.lab.local` from any tailnet device get forwarded to `lab-gateway` (via the subnet route advertised in step 1). Other DNS queries continue to use whatever resolver the client normally uses.

### Steps in the admin console

1. Go to https://login.tailscale.com/admin/dns.
2. Enable **MagicDNS** (required for Split DNS to work). Gives every tailnet device a `*.ts.net` name as a harmless side effect.
3. Under **Nameservers**, **Add nameserver → Custom**:
   - Nameserver: `192.168.100.201`
   - Check **Restrict to domain** and enter `lab.local`.
4. Save.

### Why Split DNS, not global MagicDNS

Pointing global MagicDNS at CoreDNS would force all tailnet DNS through lab-gateway, including non-lab queries. Split DNS keeps the scope tight: only `lab.local` lookups traverse the tailnet; everything else stays local on each client.

## Step 5.8: Verify from Mac

On the Mac (or any tailnet device):

```bash
dig lab-datastore.lab.local +short     # 192.168.100.205
ssh adminuser@lab-datastore.lab.local  # logs in directly
```

First time, DNS cache may need a flush. On macOS: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.

### Rollback

In the admin console: remove the custom nameserver for `lab.local`. Optionally disable MagicDNS. Tailnet clients fall back to whatever DNS they had before (no lab resolution from Mac, but everything else still works).

## Deployed configuration artifacts

**`services/coredns/Corefile`** (source of truth, mounted at `/etc/coredns/Corefile` in the container, see [the file itself](../services/coredns/Corefile) for the current version).

**Docker container on lab-gateway:**

```bash
docker ps --filter name=coredns
# CONTAINER ID   IMAGE                   COMMAND                  PORTS                                      NAMES
# abc123         coredns/coredns:1.11.3  "/coredns -conf /etc…"   192.168.100.201:53->53/tcp, :53/udp        coredns
```

**Netplan change on each non-gateway VM** (inside `/etc/netplan/50-cloud-init.yaml`):

```yaml
            nameservers:
                addresses:
                - 192.168.100.201
                - 1.1.1.1
                search:
                - lab.local
```

**Tailscale admin config**: MagicDNS enabled; custom nameserver `192.168.100.201` restricted to domain `lab.local`.

## Gotchas

**A. Port 53 bind conflict with systemd-resolved.** lab-gateway's own DNS stub listens on `127.0.0.53:53`. Binding CoreDNS to `0.0.0.0:53` in Docker can fight that on some setups. Fixed by binding specifically to `192.168.100.201:53:53` (and optionally to Tailscale IP if we ever want to query it from the tailnet directly without going through subnet routing). Clean separation, no conflict.

**B. `dig` on a lab VM returns its own `127.0.1.1` too.** Ubuntu conventionally maps the machine's hostname to `127.0.1.1` in `/etc/hosts`. When the VM queries its own `lab.local` FQDN, both `/etc/hosts` (127.0.1.1) and CoreDNS (real IP) respond. Harmless, since real-world use cases hit only one or the other.

**C. MagicDNS is required for Split DNS.** If MagicDNS is off, the "Restrict to domain" option doesn't do anything useful. Tailscale only runs Split DNS when MagicDNS is engaged.

**D. Mac DNS cache stickiness.** After enabling Split DNS, macOS may cache an old NXDOMAIN for `lab.local`. Flush with `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` or just restart the Terminal app.

**E. lab-gateway's own DNS is NOT pointed at itself.** Deliberate. lab-gateway keeps `1.1.1.1 / 8.8.8.8` as its resolvers so it can still look up names if CoreDNS container crashes. Prevents a lookup loop.

## Next

- [`stage-2-step-6-nginx.md`](./stage-2-step-6-nginx.md) (planned): nginx reverse proxy on lab-gateway for `*.lab.local` service routing (grafana.lab.local, s3.lab.local, arch.lab.local, etc.).
