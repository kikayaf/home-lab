# Hyper-V Lab Setup Scripts

Numbered PowerShell scripts that build a 7-VM Ubuntu lab on Hyper-V from a single template, with zero console typing per clone. Lab VMs live on an isolated `192.168.100.0/24` network behind Windows NAT, separate from the home network.

## Layout

| File | What it does | Where it runs |
|---|---|---|
| `00-config.ps1` | All tunable settings (VM names, IPs, paths, SSH key, domain, IP range). **Edit first.** | Dot-sourced by the others |
| `00a-setup-lab-network.ps1` | Creates the `Lab` Hyper-V vSwitch and Windows NAT for `192.168.100.0/24`. One-time. | PowerShell (Admin) |
| `01-prepare-template.ps1` | Boots template VM, SSHes in, runs cleanup script, waits for shutdown | PowerShell (Admin) |
| `02-template-cleanup.sh` | Bash block that does the actual guest-side prep | Piped over SSH by step 01 |
| `03-export-template.ps1` | Exports the prepped template, names the folder `template` | PowerShell (Admin) |
| `04-setup-wsl-tools.ps1` | Installs Ubuntu WSL + genisoimage (one-time) | PowerShell (Admin) |
| `05-lab-functions.ps1` | Defines `New-LabVM` and `New-SeedIso`. Dot-source to load. | PowerShell (Admin) |
| `06-provision-all-vms.ps1` | Loops `New-LabVM` over everything in `LAB_VMS`. Idempotent. | PowerShell (Admin) |
| `07-configure-ssh.ps1` | Writes `~/.ssh/config` aliases and clears stale host keys | PowerShell (Admin) |
| `08-verify-lab.ps1` | SSHes into each VM and reports hostname/IP/machine-id | PowerShell (Admin) |
| `99-destroy-lab.ps1` | Nukes all provisioned VMs, keeps template | PowerShell (Admin) |
| `add-vm.ps1` | Add a single VM in one shot: edits config, provisions, configures SSH, verifies. Rolls back on failure. | PowerShell (Admin) |

## Network plan

- **Lab vSwitch**: Internal, `192.168.100.0/24`. Windows host is `.1`, acts as default gateway.
- **Windows NAT**: `Lab-NAT` rule forwards `192.168.100.0/24` to the internet.
- **Lab VM reservation**: IPs `192.168.100.201` through `.220` (20 slots, 7 in use). `06-provision-all-vms.ps1` validates this range up front.
- **Template**: stays on the External vSwitch at `192.168.1.200` so `01` and `03` can reach it on the home network. Clones are moved to the Lab switch at import time.
- **DNS suffix**: `lab.local` (configurable as `$LAB_DOMAIN`). Cloud-init sets FQDN on each VM and writes `/etc/hosts` with both FQDN and short name. Netplan `search` domain is set too, so `ssh lab-datastore` resolves from any lab VM without typing the suffix.

## First-time run

1. Open PowerShell as Administrator.
2. `cd C:\vmimages\scripts\`.
3. Open `00-config.ps1`. Verify names, IPs, paths, SSH key, and `$LAB_DOMAIN` match your setup.
4. Run in order:

   ```powershell
   .\00a-setup-lab-network.ps1    # one-time: creates Lab vSwitch + NAT
   .\01-prepare-template.ps1      # cleans template VM, shuts it down
   .\03-export-template.ps1       # exports template for cloning
   .\04-setup-wsl-tools.ps1       # one-time: installs WSL Ubuntu + genisoimage
   .\06-provision-all-vms.ps1     # builds all 7 VMs on the Lab switch
   .\07-configure-ssh.ps1         # writes SSH aliases
   .\08-verify-lab.ps1            # SSH roundtrip to each VM
   ```

Step 04 may require a reboot and a second run. Step 06 takes roughly 15 to 25 minutes total, hands-off.

## Stage 2: after first networking

Once all seven VMs are up on `192.168.100.x` and verified, the next phase turns `lab-gateway` into the real gateway for the lab. Not scripted yet, tracked as a to-do.

1. **Give `lab-gateway` a second NIC on the External switch.**
   Manually in Hyper-V Manager, or via PowerShell:

   ```powershell
   Stop-VM vm1-lab-gateway -Force
   Add-VMNetworkAdapter -VMName vm1-lab-gateway -SwitchName 'Default Switch'
   Start-VM vm1-lab-gateway
   ```

   The new `eth1` gets a home-network IP via DHCP.

2. **Install services on `lab-gateway`:**
   - **Tailscale** for remote access (`curl -fsSL https://tailscale.com/install.sh | sh`, then `tailscale up --advertise-routes=192.168.100.0/24 --accept-dns=false`).
   - **CoreDNS** for `*.lab.local` resolution (serves the same zone currently in `/etc/hosts`, plus any custom records).
   - **iptables NAT** so `192.168.100.0/24` can egress via `eth1` (home network) instead of via the Windows host.
   - **nginx reverse proxy** for lab services (`*.lab.local` → backend VMs on the internal network).
   - **ufw** firewall policy on `lab-gateway` plus per-VM hardening.

3. **Switch other lab VMs' default gateway from `.1` (Windows host) to `.201` (lab-gateway).**
   Either edit each `/etc/netplan/50-cloud-init.yaml` by hand and `netplan apply`, or update `$LAB_GATEWAY` in `00-config.ps1` and re-provision. Once this is done, all egress flows through lab-gateway.

4. **(Optional) Lock down to Private switch.**
   Change the Lab vSwitch from Internal to Private so only VMs (not the Windows host) can reach the subnet. Admin access is then Tailscale-only, through lab-gateway.

Stage 2 is additive. Stage 1 keeps working the whole time, so it's safe to pause between steps.

## Adding more VMs later

Easiest path, one command that does everything with rollback on failure:

```powershell
.\add-vm.ps1 -Hostname 'lab-monitoring'
```

That picks the next free IP in `.201-.220`, assigns `VMName = vmN-<hostname>` using the next free `vmN-` number, edits `00-config.ps1` to append the entry, then runs `06` + `07` + `08` in sequence. If provisioning fails before the VM is up, it reverts the config edit and cleans up the Hyper-V leftovers. Common overrides:

```powershell
.\add-vm.ps1 -Hostname 'lab-monitoring' -IPAddress '192.168.100.215'
.\add-vm.ps1 -Hostname 'lab-monitoring' -MemoryMB 8192 -CPUs 4
.\add-vm.ps1 -Hostname 'lab-monitoring' -SkipVerify
```

Manual path (if you want more control): edit `00-config.ps1` and append to `$LAB_VMS`, then:

```powershell
.\06-provision-all-vms.ps1     # skips existing, builds only the new one
.\07-configure-ssh.ps1         # refreshes the SSH config block
.\08-verify-lab.ps1            # SSH roundtrip across the whole fleet
```

For ad-hoc one-offs you don't want in `00-config.ps1`, call `New-LabVM` directly:

```powershell
. .\00-config.ps1
. .\05-lab-functions.ps1
New-LabVM -VMName 'vm9-lab-openshift' -Hostname 'lab-openshift' `
          -IPAddress '192.168.100.209' -MemoryMB 16384 -CPUs 6
.\07-configure-ssh.ps1
```

## Starting over

```powershell
.\99-destroy-lab.ps1 -Force
.\06-provision-all-vms.ps1
```

The template VM and its export are left alone, so provisioning is immediate (no re-prep needed). Lab vSwitch + NAT stay in place across destroy/rebuild cycles.

## What each lab VM gets

- Static IP on `eth0` on the Lab vSwitch, DHCP disabled
- Hostname + FQDN (`<host>.lab.local`) set via cloud-init
- `/etc/hosts` populated with every lab VM (FQDN and short name)
- Netplan `search: [lab.local]` so short names resolve via search-list
- Your SSH pubkey installed for `adminuser` with NOPASSWD sudo
- Hyper-V integration daemons enabled (KVP, fcopy, VSS)
- Base tools: curl, jq, htop, dnsutils, net-tools, ca-certificates, gnupg
- Swap disabled (Kubernetes prereq)
- Custom prompt + `ll` alias for adminuser
- Timezone set (default `America/Los_Angeles`, change in `00-config.ps1`)

## Idempotency notes

`New-LabVM` is safe to re-run. For each VM it decides:

- **Registered in Hyper-V and reachable on its IP**: skip with `[skip]`.
- **Registered but unreachable**: skip with a warning. Delete it manually (or `.\99-destroy-lab.ps1 -Force`) before re-running. `-Force` on `New-LabVM` overrides.
- **Not registered but files exist on disk** (aborted previous run): clean the orphaned files, then provision.
- **Not registered, no files**: provision normally.

`06-provision-all-vms.ps1` also validates up front that every IP in `$LAB_VMS` is on `192.168.100.0/24`, within `.201-.220`, and unique. Bad config aborts before any Hyper-V work.

## Troubleshooting

**`00a-setup-lab-network.ps1` errors about an existing `NetNat` or `VMSwitch`.**
Something else (Docker Desktop, a previous lab, WSL) already owns the network or subnet. `Get-NetNat` and `Get-VMSwitch` show what. Either remove the conflicting object or edit `$LAB_VSWITCH` / `$LAB_SUBNET` in `00-config.ps1`.

**`01-prepare-template.ps1` can't reach SSH at `192.168.1.200`.**
Template VM isn't at the expected IP. Open VMConnect, log in, check `ip -br a`. Confirm `/etc/netplan/50-cloud-init.yaml` has `192.168.1.200/24` static and `sudo netplan apply` has been run. SSH service: `sudo systemctl status ssh`; if it failed, `sudo ssh-keygen -A && sudo systemctl restart ssh`.

**`04-setup-wsl-tools.ps1` prompts you to restart or re-run.**
First-time WSL install needs a reboot and an Ubuntu first-run setup (create WSL user). After that, re-run the script and it'll install genisoimage.

**A clone boots but stays unreachable at its configured IP.**
Check `Get-VMDvdDrive -VMName <name>` shows the seed ISO path while booting. If absent, the ISO path is wrong or wasn't attached. Check `C:\vmimages\seeds\<name>\seed.iso` exists. Also check `Get-VMNetworkAdapter -VMName <name>` is connected to `Lab`, not some other switch.

**SSH says "REMOTE HOST IDENTIFICATION HAS CHANGED".**
Host keys were regenerated by cloud-init. Run `ssh-keygen -R <hostname>` and retry. Step 07 clears these automatically for all lab hosts.

**Re-provisioned VM doesn't take new config.**
Cloud-init's `instance-id` is timestamped so this shouldn't happen. If it does, on the VM: `sudo cloud-init clean --logs && sudo rm -rf /var/lib/cloud/instances/* && sudo reboot`.

**Lab VM has no internet.**
From the VM: `ip route` should show default via `192.168.100.201` (stage 2) or `192.168.100.1` (stage 1). From the Windows host: `Get-NetNat` should show `Lab-NAT` covering `192.168.100.0/24` (harmless after stage 2, still present as fallback). If both look right but DNS fails, confirm `1.1.1.1` is reachable from the VM (`dig @1.1.1.1 cloudflare.com`). For stage 2-specific issues see [`../runbooks/stage-2-lab-gateway.md`](../runbooks/stage-2-lab-gateway.md).
