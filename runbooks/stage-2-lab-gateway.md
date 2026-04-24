# Stage 2, Steps 1-4: Promote lab-gateway to the real egress router

## Goal

Stop relying on Windows NAT for lab internet access. Make `lab-gateway` (vm1, `192.168.100.201`) the actual router: dual-homed on the lab subnet and the home network, NAT'ing lab egress out its home-network NIC, and reachable remotely via Tailscale subnet routing.

## Architecture change

**Before (end of stage 1):**

```
Lab VM → Windows host vEthernet (Lab) .1 → Windows NAT → home network → internet
```

Windows host is in the data path. Lab is only reachable while you're on the Windows host. Tailscale is not present on the lab.

**After (end of stage 2, step 4):**

```
Lab VM → lab-gateway (.201) eth0 → forward → eth1 MASQUERADE → home router → internet

Remote laptop → Tailscale tailnet → lab-gateway subnet router → any lab VM
```

Windows host is out of the data path. Lab is reachable from any tailnet device. `lab-gateway` is dual-homed.

## Prerequisites

- Stage 1 complete: 8 lab VMs running on the `Lab` Hyper-V vSwitch at `192.168.100.201` through `.208`.
- Tailscale account (free tier fine).
- `192.168.100.0/24` NOT advertised into Tailscale by anything else (no competing subnet routers).
- Windows host running Tailscale with `accept-routes=false` (see Gotcha A below).

## Step 1: Tailscale on lab-gateway

### What we did

Installed Tailscale as a subnet router on `lab-gateway` advertising `192.168.100.0/24`, so any tailnet device (your Mac, iPad, phone, other Windows boxes) can reach the lab subnet as if it were directly connected.

### Why

- Gives us remote admin from anywhere without opening home-network port-forwards.
- Establishes the emergency access path before we touch routing. If step 3 or 4 breaks something, Tailscale is the escape hatch.
- Doubles as the architectural role of `lab-gateway` as the edge of the lab.

### Commands

On `lab-gateway`:

```bash
curl -fsSL https://tailscale.com/install.sh | sh

sudo tailscale up \
    --advertise-routes=192.168.100.0/24 \
    --accept-dns=false \
    --ssh

echo 'net.ipv4.ip_forward = 1'        | sudo tee    /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

Then approve `192.168.100.0/24` in the Tailscale admin panel at https://login.tailscale.com/admin/machines (click `lab-gateway` → Edit route settings → toggle on `192.168.100.0/24`).

Flag meanings:

- `--advertise-routes=192.168.100.0/24`: offer this subnet to the tailnet.
- `--accept-dns=false`: don't let Tailscale manage `/etc/resolv.conf` on lab-gateway. We'll own DNS via CoreDNS in step 5.
- `--ssh`: enable Tailscale SSH so tailnet members (per ACL) can SSH without keys.

### Verify

On `lab-gateway`:

```bash
sudo tailscale status                                                # should show "Connected"
cat /proc/sys/net/ipv4/ip_forward                                    # should print 1
```

From any other tailnet device (Mac, phone, etc., with Tailscale client accepting routes):

```bash
ping 100.98.51.51                                                    # tailnet IP of lab-gateway
ping 192.168.100.202                                                 # any lab VM via the advertised route
```

### Rollback

```bash
sudo tailscale down
sudo tailscale logout
# optionally:
sudo apt-get purge -y tailscale
```

## Step 2: Second NIC on lab-gateway

### What we did

Added a second Hyper-V virtual NIC to `vm1-lab-gateway`, connected to the `homewifinet` external vSwitch, so the VM has a direct arm on the home network (DHCP-assigned `192.168.1.75` in our case).

### Why

Until now, lab-gateway's only path to the internet was via the Lab vSwitch to Windows NAT. For lab-gateway to NAT its own traffic, it needs a direct connection to the home network: that's eth1.

### Commands

On the Windows host (elevated PowerShell):

```powershell
Stop-VM -Name vm1-lab-gateway
Add-VMNetworkAdapter -VMName vm1-lab-gateway -SwitchName 'homewifinet' -Name 'eth1-home'
Start-VM -Name vm1-lab-gateway
```

On `lab-gateway` (via VMConnect or SSH once it's back up), rewrite `/etc/netplan/50-cloud-init.yaml` to match both NICs by MAC (robust against interface renaming):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: 00:15:5d:01:ba:1d
      set-name: eth0
      dhcp4: no
      addresses:
        - 192.168.100.201/24
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
        search: [lab.local]
    eth1:
      match:
        macaddress: 00:15:5d:01:ba:25
      set-name: eth1
      dhcp4: true
      dhcp-identifier: mac
```

Also pin cloud-init against future network-config rewrites (see Gotcha B):

```bash
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

sudo chmod 600 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

Note: no `routes: - to: default via: 192.168.100.1` on eth0 anymore. eth1's DHCP supplies the default route via `192.168.1.254`, which is what makes lab-gateway's own egress go through the home network rather than bouncing back to Windows NAT.

And apply the cloud-init disable to all other lab VMs too, from the Windows host:

```powershell
. .\scripts\00-config.ps1
foreach ($v in $LAB_VMS) {
    if ($v.Hostname -eq 'lab-gateway') { continue }
    ssh $v.Hostname "echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null && echo OK"
}
```

### Verify

On `lab-gateway`:

```bash
ip -br a
# expect:
#   eth0        UP   192.168.100.201/24 ...
#   eth1        UP   192.168.1.x/24 ...
#   tailscale0  UP   100.x.y.z/32 ...

ip route
# expect:
#   default via 192.168.1.254 dev eth1 proto dhcp src 192.168.1.75 metric 100
#   192.168.1.0/24   dev eth1 ...
#   192.168.100.0/24 dev eth0 ...

ping -c 2 192.168.1.254     # reach home router via eth1
ping -c 2 1.1.1.1           # reach internet
sudo tailscale status       # still Connected
```

### Rollback

```powershell
Stop-VM -Name vm1-lab-gateway
Remove-VMNetworkAdapter -VMName vm1-lab-gateway -Name 'eth1-home'
Start-VM -Name vm1-lab-gateway
```

And restore the single-NIC netplan (static lab IP with default via `192.168.100.1`).

## Step 3: IP forwarding + iptables NAT

### What we did

Turned `lab-gateway` into a functioning NAT router: installed `iptables-persistent`, added a `MASQUERADE` rule in the `nat/POSTROUTING` chain, and explicit `FORWARD` accepts in both directions.

### Why

Forwarding alone (step 1's sysctl) isn't enough. Return traffic from the internet destined for `192.168.100.x` wouldn't make it back through the home router because home has no idea about the lab subnet. MASQUERADE rewrites the source address on packets leaving eth1, so replies come back to lab-gateway's home-network IP instead of a lab IP. Connection-tracking reverses the mapping on the return leg.

The two FORWARD rules are needed because Ubuntu's default FORWARD policy is `DROP` (ufw installs the chain even when the service isn't active).

### Commands

On `lab-gateway`:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o eth1 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o eth1 -s 192.168.100.0/24 -j ACCEPT
sudo iptables -A FORWARD -i eth1 -o eth0 -d 192.168.100.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT

sudo netfilter-persistent save
```

Rule reading:

- MASQUERADE: for any packet leaving eth1 whose source is in the lab subnet, rewrite source to eth1's current IP. MASQUERADE (vs SNAT) auto-detects eth1's IP, which is good because it's DHCP-assigned.
- FORWARD out (eth0 → eth1): allow lab-to-home forwarding unconditionally (lab is trusted to initiate).
- FORWARD in (eth1 → eth0): only allow home-to-lab return traffic that belongs to an already-established connection. Blocks spontaneous inbound.

### Verify

On `lab-gateway`:

```bash
sudo iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE
sudo iptables -L FORWARD -n -v | head -20
```

Then from one lab VM, route a single destination through lab-gateway and ping it:

```bash
ssh adminuser@192.168.100.202
sudo ip route add 1.1.1.1 via 192.168.100.201
ping -c 3 1.1.1.1
sudo ip route del 1.1.1.1
exit
```

Back on lab-gateway, the MASQUERADE rule's packet counter should have moved from 0 to ~1. Only 1 because iptables MASQUERADEs the first packet of a connection; conntrack handles the rest on a fast path.

### Rollback

```bash
sudo iptables -F FORWARD
sudo iptables -t nat -F POSTROUTING
sudo netfilter-persistent save
```

## Step 4: Flip the fleet's default gateway to .201

### What we did

Updated every other lab VM (all except `lab-gateway` itself) to use `192.168.100.201` as the default gateway instead of `192.168.100.1`. Also updated `scripts/00-config.ps1` so future provisioned VMs inherit the new gateway.

### Why

After this flip, every internet-bound packet from the lab fleet flows through `lab-gateway`'s NAT rather than Windows host's NAT. Architecturally this is the moment the Windows host stops being in the data path.

We deliberately did this only after step 3 verified that lab-gateway's NAT actually works.

### Commands

Update the config first:

```powershell
# scripts/00-config.ps1
$global:LAB_GATEWAY = '192.168.100.201'
```

Then on the Windows host, loop over the lab VMs:

```powershell
. .\scripts\00-config.ps1

foreach ($v in $LAB_VMS) {
    if ($v.Hostname -eq 'lab-gateway') { continue }
    $h = $v.Hostname
    $cmd = @'
set -e
sudo sed -i 's/via: 192\.168\.100\.1$/via: 192.168.100.201/' /etc/netplan/50-cloud-init.yaml
sudo netplan apply 2>/dev/null
'@
    ssh $h $cmd
}
```

### Verify

```powershell
. .\scripts\00-config.ps1

foreach ($v in $LAB_VMS | Where-Object Hostname -ne 'lab-gateway') {
    $h = $v.Hostname
    $route = ssh $h "ip route | grep '^default' | tr -d '\n'"
    $ping  = ssh $h "ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1 && echo OK || echo FAIL"
    $ok    = ($route -like '*192.168.100.201*' -and $ping -eq 'OK')
    Write-Host ("{0,-22} {1}" -f $h, $(if ($ok) {'GOOD'} else {'CHECK'}))
}
```

All seven non-gateway VMs should report `GOOD` and show `default via 192.168.100.201 dev eth0 proto static`.

Then on lab-gateway, `sudo iptables -t nat -L POSTROUTING -n -v` should show the MASQUERADE counter climbing steadily, proving the fleet's traffic is flowing through.

### Rollback

Flip the sed back (`via: 192.168.100.201` → `via: 192.168.100.1`), `netplan apply`, change `$LAB_GATEWAY` back to `192.168.100.1`. Windows NAT is still in place (we deliberately didn't remove it), so reverting the fleet's default gateway cleanly falls back to Windows NAT.

## Deployed configuration artifacts

Reference copies of what's on lab-gateway after step 4.

**`/etc/netplan/50-cloud-init.yaml`** (lab-gateway):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: 00:15:5d:01:ba:1d
      set-name: eth0
      dhcp4: no
      addresses:
        - 192.168.100.201/24
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
        search: [lab.local]
    eth1:
      match:
        macaddress: 00:15:5d:01:ba:25
      set-name: eth1
      dhcp4: true
      dhcp-identifier: mac
```

**`/etc/sysctl.d/99-tailscale.conf`** (lab-gateway):

```
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

**`/etc/iptables/rules.v4`** (lab-gateway, abridged, show the NAT + FORWARD we added):

```
*nat
-A POSTROUTING -s 192.168.100.0/24 -o eth1 -j MASQUERADE
COMMIT

*filter
-A FORWARD -i eth0 -o eth1 -s 192.168.100.0/24 -j ACCEPT
-A FORWARD -i eth1 -o eth0 -d 192.168.100.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
COMMIT
```

**`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`** (every lab VM):

```
network: {config: disabled}
```

Keep these in mind when rebuilding a VM. They're what makes stage 2 work.

## Gotchas we hit

Logged so we don't rediscover them.

**A. Tailscale accept-routes loop on the Windows host.** The Windows host runs Tailscale too. When `lab-gateway` advertised `192.168.100.0/24`, the Windows host accepted that route at metric 0, overriding its own local route via `vEthernet (Lab)` (metric 256). Return traffic from NAT'd packets was sent via Tailscale instead of back out the Lab vSwitch, breaking the whole path. Windows `lab-gateway` then lost internet, which meant Tailscale coordination failed, which meant it went offline, which meant routing broke harder. Classic deadlock.

Fix: on the Windows host, `tailscale set --accept-routes=false`. Windows is directly on the Lab subnet via vEthernet, so it never needs the route from Tailscale anyway.

**B. Cloud-init rewrote netplan after the NIC hot-add.** Hot-adding the second NIC triggered cloud-init's NoCloud datasource to re-evaluate, couldn't find its seed ISO (we eject it after provisioning), and fell through to default-DHCP on all interfaces, wiping the static `.201` config on eth0.

Fix: `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` with `network: {config: disabled}`. Prevents cloud-init from touching netplan ever again. Applied across all 8 lab VMs as a preventive measure.

**C. VMConnect clipboard type corrupts long text.** Paste via Action → Clipboard → Type clipboard text drops and duplicates characters on long strings. Don't use it for anything beyond ~100 characters. Use nano inside the VM, or scp from Windows over SSH.

**D. SSH heredoc paste truncation.** Pasting a long `sudo tee <<'EOF' ... EOF` block through SSH can truncate mid-heredoc, leaving bash stuck in a multi-line continuation prompt. Later commands become heredoc content. Use `scp` for big configs, or nano inside the VM.

**E. Typeahead on SSH login.** Typing commands before the password prompt sends them to the prompt as part of the password string. Wait for the shell prompt before running anything.

**F. lab-gateway's own default route matters.** With eth0's static route `via: 192.168.100.1` still in place, `lab-gateway` was forwarding lab traffic right back out eth0 to Windows NAT and issuing ICMP redirects. Removing that `routes:` block from eth0 and letting eth1's DHCP install the default route fixed it: forwarded packets now egress via eth1 and MASQUERADE fires correctly.

## What's still on the Windows host

- The `Lab` Hyper-V Internal vSwitch (required, hosts the lab subnet).
- The `vEthernet (Lab)` adapter at `192.168.100.1/24` (required for Windows to reach lab VMs directly when not on tailnet).
- The `Lab-NAT` NetNat rule (no longer used, kept as a fallback. Remove with `Remove-NetNat -Name Lab-NAT -Confirm:$false` if you want the clean cut).

## Next

- [`stage-2-step-5-coredns.md`](./stage-2-step-5-coredns.md) (planned): CoreDNS on `lab-gateway` for `*.lab.local`; Tailscale Split DNS so the tailnet can resolve lab hosts by name.
