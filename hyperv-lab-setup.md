# Hyper-V Lab Setup Runbook

Rebuild the whole 7-VM lab from a clean template using a single PowerShell function call per VM. No VMConnect typing, no IP collisions, no manual hostname wrangling.

**Lab layout**

| VM name (Hyper-V)           | Hostname              | IP              | Purpose                 |
|-----------------------------|-----------------------|-----------------|-------------------------|
| vm1-lab-gateway             | lab-gateway           | 192.168.1.201   | Network gateway/jumpbox |
| vm2-lab-k3s-controlplane    | lab-k3s-controlplane  | 192.168.1.202   | k3s control plane       |
| vm3-lab-k3s-node01          | lab-k3s-node01        | 192.168.1.203   | k3s worker              |
| vm4-lab-k3s-node02          | lab-k3s-node02        | 192.168.1.204   | k3s worker              |
| vm5-lab-datastore           | lab-datastore         | 192.168.1.205   | DB / object store       |
| vm6-lab-ai-ops              | lab-ai-ops            | 192.168.1.206   | AI / observability      |
| vm7-lab-automation          | lab-automation        | 192.168.1.207   | Automation stack        |

Gateway: 192.168.1.254. DNS: 192.168.1.254 + 1.1.1.1.

---

## Prerequisites

* Windows host with Hyper-V role enabled.
* PowerShell running as Administrator.
* SSH keypair in `%USERPROFILE%\.ssh\`:
  * Private key: `controlplane01`
  * Public key:  `controlplane01.pub`
* One Ubuntu Server VM already installed and reachable, used as the template source. (Named `ubuntu_template` in these steps, adjust if yours differs.)

Verify your keypair exists:

```powershell
Get-ChildItem $HOME\.ssh\controlplane01*
```

---

## Step 1 — Prepare the template (run once)

The template is a clean Ubuntu VM with Hyper-V integration daemons, cloud-init locked to the NoCloud datasource, and wiped identity so cloud-init re-runs on first boot of every clone.

### 1a. Start the template VM (PowerShell)

```powershell
Start-VM -Name ubuntu_template
Start-Sleep 30
```

### 1b. Clear old host key and SSH in (PowerShell)

```powershell
ssh-keygen -R 192.168.1.200
ssh -o StrictHostKeyChecking=accept-new adminuser@192.168.1.200
```

### 1c. Template prep block (paste into SSH session)

```bash
sudo apt update
sudo apt install -y hyperv-daemons cloud-init openssh-server

sudo systemctl enable --now hv-kvp-daemon.service hv-fcopy-daemon.service hv-vss-daemon.service
sudo systemctl enable --now ssh

sudo hostnamectl set-hostname temp-host
sudo sed -i 's/127\.0\.1\.1.*/127.0.1.1 temp-host/' /etc/hosts
grep -q '127.0.1.1' /etc/hosts || echo '127.0.1.1 temp-host' | sudo tee -a /etc/hosts

sudo tee /etc/netplan/50-cloud-init.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp-identifier: mac
EOF
sudo chmod 600 /etc/netplan/50-cloud-init.yaml

sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg > /dev/null <<'EOF'
datasource_list: [ NoCloud, None ]
EOF

sudo rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

sudo cloud-init clean --logs
sudo rm -rf /var/lib/cloud/instances/*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A

sudo rm -f /var/log/*.log
sudo rm -rf /var/log/journal/*
rm -f ~/.bash_history
sudo rm -f /root/.bash_history

sudo shutdown now
```

What each section does:

* Package install and integration daemons so Hyper-V can talk to the guest.
* Default netplan set to DHCP with MAC-based client ID, used as a safety net if the cloud-init seed is missing.
* Cloud-init pinned to NoCloud so it only consumes the seed ISO we attach at provision time.
* Identity wipe: machine-id, cloud-init state, SSH host keys. `ssh-keygen -A` immediately regenerates host keys so the template itself remains SSH-able.
* Log and history cleanup for hygiene.

SSH session drops when the VM shuts down. That is expected.

---

## Step 2 — Export the template (PowerShell)

```powershell
do { Start-Sleep 3; $s = (Get-VM -Name ubuntu_template).State } until ($s -eq 'Off')

Remove-Item 'C:\vmimages\Exports\HyperV\ubuntu_template' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\vmimages\Exports\HyperV\template'        -Recurse -Force -ErrorAction SilentlyContinue

Export-VM -Name ubuntu_template -Path 'C:\vmimages\Exports\HyperV'

# rename the exported folder so the default template path in New-LabVM works
Rename-Item 'C:\vmimages\Exports\HyperV\ubuntu_template' 'C:\vmimages\Exports\HyperV\template'

Get-ChildItem 'C:\vmimages\Exports\HyperV\template\Virtual Machines\*.vmcx' | Select-Object FullName
```

Export takes a few minutes (copies the full VHDX). The output `.vmcx` path confirms the template is ready.

---

## Step 3 — Install WSL + genisoimage (PowerShell, one time)

`genisoimage` generates the cloud-init seed ISO for each clone. Easiest way to get it on Windows is via WSL Ubuntu.

```powershell
wsl --install -d Ubuntu
```

When the Ubuntu window opens, set a username and password. At the Ubuntu shell:

```bash
sudo apt update
sudo apt install -y genisoimage
exit
```

Back in PowerShell:

```powershell
wsl --set-default Ubuntu
wsl -e genisoimage --version
```

Last command should print a version string.

---

## Step 4 — Load the provisioning function (PowerShell)

Paste this full block into PowerShell. It defines two functions: `New-SeedIso` (creates the cloud-init seed ISO) and `New-LabVM` (imports, configures, boots, verifies).

To make it permanent, drop it into your `$PROFILE`.

```powershell
function New-SeedIso {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $wslSource = (wsl wslpath -a $SourceDir).Trim()
    $wslOut    = (wsl wslpath -a $OutputPath).Trim()
    wsl -e bash -c "genisoimage -quiet -output '$wslOut' -volid CIDATA -joliet -rock '$wslSource/user-data' '$wslSource/meta-data' '$wslSource/network-config'"
    if (-not (Test-Path $OutputPath)) { throw "Seed ISO creation failed" }
}

function New-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Gateway = '192.168.1.254',
        [int]   $Prefix  = 24,
        [string[]]$DNS   = @('192.168.1.254','1.1.1.1'),
        [string]$SSHKeyFile  = "$HOME\.ssh\controlplane01.pub",
        [string]$TemplateDir = 'C:\vmimages\Exports\HyperV\template',
        [string]$VMRoot      = 'C:\vmimages\VMs',
        [string]$SeedRoot    = 'C:\vmimages\seeds',
        [int]   $MemoryMB    = 4096,
        [int]   $CPUs        = 2
    )

    $ErrorActionPreference = 'Stop'
    $pubkey = (Get-Content $SSHKeyFile -Raw).Trim()

    # Import the template as a new VM
    $vmcx = (Get-ChildItem "$TemplateDir\Virtual Machines\*.vmcx" | Select-Object -First 1).FullName
    $dest = Join-Path $VMRoot $VMName

    Write-Host "[1/5] Importing $VMName from template..." -ForegroundColor Cyan
    Import-VM -Path $vmcx -Copy -GenerateNewId `
        -VirtualMachinePath  $dest `
        -VhdDestinationPath  (Join-Path $dest 'Virtual Hard Disks') `
        -SnapshotFilePath    (Join-Path $dest 'Snapshots') `
        -SmartPagingFilePath $dest |
        Rename-VM -NewName $VMName

    Set-VMNetworkAdapter -VMName $VMName -DynamicMacAddress
    Set-VMMemory    -VMName $VMName -StartupBytes ($MemoryMB * 1MB)
    Set-VMProcessor -VMName $VMName -Count $CPUs
    Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'

    # Build cloud-init seed
    Write-Host "[2/5] Building cloud-init seed for $Hostname..." -ForegroundColor Cyan
    $seedDir = Join-Path $SeedRoot $VMName
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null

    $metadata = @"
instance-id: $Hostname-$(Get-Date -Format 'yyyyMMddHHmmss')
local-hostname: $Hostname
"@

    $networkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: no
    addresses:
      - $IPAddress/$Prefix
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [$($DNS -join ', ')]
"@

    $hostsBlock = @'
192.168.1.201 lab-gateway
192.168.1.202 lab-k3s-controlplane
192.168.1.203 lab-k3s-node01
192.168.1.204 lab-k3s-node02
192.168.1.205 lab-datastore
192.168.1.206 lab-ai-ops
192.168.1.207 lab-automation
'@

    $userdata = @"
#cloud-config
hostname: $Hostname
fqdn: $Hostname.lab.local
manage_etc_hosts: localhost
preserve_hostname: false
timezone: America/Los_Angeles

users:
  - name: adminuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $pubkey

ssh_pwauth: true
disable_root: true

packages:
  - hyperv-daemons
  - curl
  - jq
  - htop
  - dnsutils
  - net-tools
  - ca-certificates
  - gnupg

write_files:
  - path: /etc/hosts.lab
    content: |
$(($hostsBlock -split "`n") | ForEach-Object { "        $_" } | Out-String)
  - path: /etc/profile.d/lab.sh
    content: |
      alias ll='ls -lah'
      export PS1='\[\e[36m\]\u@\h\[\e[0m\]:\[\e[33m\]\w\[\e[0m\]\$ '
    permissions: '0644'

runcmd:
  - [ bash, -c, "cat /etc/hosts.lab >> /etc/hosts" ]
  - [ systemctl, enable, --now, hv-fcopy-daemon.service ]
  - [ systemctl, enable, --now, hv-kvp-daemon.service ]
  - [ systemctl, enable, --now, hv-vss-daemon.service ]
  - [ swapoff, -a ]
  - [ sed, -i, '/ swap / s/^/#/', /etc/fstab ]

final_message: "Lab VM $Hostname is up at $IPAddress after \$UPTIME seconds"
"@

    [IO.File]::WriteAllText("$seedDir\meta-data",      ($metadata      -replace "`r`n","`n"))
    [IO.File]::WriteAllText("$seedDir\network-config", ($networkConfig -replace "`r`n","`n"))
    [IO.File]::WriteAllText("$seedDir\user-data",      ($userdata      -replace "`r`n","`n"))

    Write-Host "[3/5] Creating seed ISO..." -ForegroundColor Cyan
    $isoPath = Join-Path $seedDir 'seed.iso'
    New-SeedIso -SourceDir $seedDir -OutputPath $isoPath
    Add-VMDvdDrive -VMName $VMName -Path $isoPath

    Write-Host "[4/5] Booting $VMName..." -ForegroundColor Cyan
    Start-VM -Name $VMName

    Write-Host "[5/5] Waiting for $IPAddress to respond..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep 5
        $up = Test-Connection $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    } until ($up -or (Get-Date) -gt $deadline)

    if ($up) {
        Write-Host "$VMName is up at $IPAddress. Detaching seed ISO." -ForegroundColor Green
        Get-VMDvdDrive -VMName $VMName | Where-Object Path -eq $isoPath | Remove-VMDvdDrive
        ssh-keygen -R $IPAddress 2>$null | Out-Null
    } else {
        Write-Warning "$VMName did not respond at $IPAddress within 5 minutes. Check the console."
    }
}
```

### What the function does, step by step

1. Import the template VHDX as a fresh VM with a new Hyper-V ID.
2. Assign a unique dynamic MAC address, custom memory, and CPU count.
3. Build a `meta-data`, `network-config`, and `user-data` triplet in a per-VM seed folder.
4. Pack those into a CIDATA-labeled ISO using WSL's genisoimage.
5. Attach the ISO as a DVD drive and start the VM.
6. Cloud-init in the guest reads the seed on first boot and applies: hostname, static network, SSH key for `adminuser`, package installs, Hyper-V daemon enablement, swap off, hosts file injection, custom prompt.
7. Host waits up to 5 minutes for the configured IP to respond, then detaches the ISO.

---

## Step 5 — Provision all VMs (PowerShell)

```powershell
$batch = @(
    @{ VMName='vm1-lab-gateway';           Hostname='lab-gateway';           IPAddress='192.168.1.201' }
    @{ VMName='vm2-lab-k3s-controlplane';  Hostname='lab-k3s-controlplane';  IPAddress='192.168.1.202' }
    @{ VMName='vm3-lab-k3s-node01';        Hostname='lab-k3s-node01';        IPAddress='192.168.1.203' }
    @{ VMName='vm4-lab-k3s-node02';        Hostname='lab-k3s-node02';        IPAddress='192.168.1.204' }
    @{ VMName='vm5-lab-datastore';         Hostname='lab-datastore';         IPAddress='192.168.1.205' }
    @{ VMName='vm6-lab-ai-ops';            Hostname='lab-ai-ops';            IPAddress='192.168.1.206' }
    @{ VMName='vm7-lab-automation';        Hostname='lab-automation';        IPAddress='192.168.1.207' }
)
$batch | ForEach-Object { New-LabVM @_ }
```

Each call takes 2 to 4 minutes. Total for the seven: roughly 15 to 25 minutes hands-off.

To add more VMs later, call `New-LabVM` directly:

```powershell
New-LabVM -VMName 'vm8-lab-monitoring' -Hostname 'lab-monitoring' -IPAddress '192.168.1.208'
```

For memory-hungry workloads, override the defaults:

```powershell
New-LabVM -VMName 'vm9-lab-openshift' -Hostname 'lab-openshift' -IPAddress '192.168.1.209' -MemoryMB 16384 -CPUs 6
```

---

## Step 6 — Add SSH aliases on Windows (PowerShell)

```powershell
$sshConfig = @"

# --- lab cluster ---
Host lab-gateway
    HostName 192.168.1.201
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-k3s-controlplane
    HostName 192.168.1.202
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-k3s-node01
    HostName 192.168.1.203
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-k3s-node02
    HostName 192.168.1.204
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-datastore
    HostName 192.168.1.205
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-ai-ops
    HostName 192.168.1.206
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes

Host lab-automation
    HostName 192.168.1.207
    User adminuser
    IdentityFile ~/.ssh/controlplane01
    IdentitiesOnly yes
"@

Add-Content -Path "$HOME\.ssh\config" -Value $sshConfig
```

Clear any stale `known_hosts` entries before first connection:

```powershell
201..207 | ForEach-Object { ssh-keygen -R "192.168.1.$_" }
'lab-gateway','lab-k3s-controlplane','lab-k3s-node01','lab-k3s-node02','lab-datastore','lab-ai-ops','lab-automation' |
    ForEach-Object { ssh-keygen -R $_ }
```

---

## Step 7 — Verify (PowerShell)

```powershell
'lab-gateway','lab-k3s-controlplane','lab-k3s-node01','lab-k3s-node02','lab-datastore','lab-ai-ops','lab-automation' |
    ForEach-Object {
        Write-Host "`n--- $_ ---" -ForegroundColor Cyan
        ssh -o StrictHostKeyChecking=accept-new $_ "hostname; ip -br a; cat /etc/machine-id"
    }
```

Each VM should report:

* Unique hostname
* Its assigned IP
* A unique `/etc/machine-id`

If any report the same machine-id, cloud-init didn't re-run. Check that `/var/lib/cloud/instances/` was empty on the template before export, and that the seed ISO attached cleanly.

---

## Troubleshooting

**VM boots but stays at DHCP, not static IP.**
Seed ISO wasn't consumed. Check `Get-VMDvdDrive -VMName <vm>` shows the ISO path while the VM is booting. If empty, the `Add-VMDvdDrive` step failed silently. Check that `C:\vmimages\seeds\<vm>\seed.iso` exists.

**`systemctl is-active ssh` reports failed on the template.**
Host keys were deleted but not regenerated. Run `sudo ssh-keygen -A` then `sudo systemctl restart ssh`. The prep block in Step 1c now does this automatically.

**`Copy-VMFile` is unused in this runbook, but if you try it later and get 0x80004005.**
`hv-fcopy-daemon.service` is inactive in the guest. `sudo systemctl enable --now hv-fcopy-daemon.service` fixes it. The template includes hyperv-daemons, so clones have it enabled via the cloud-init runcmd block.

**Host key verification failed when SSHing after a re-provision.**
Expected, host keys were regenerated. `ssh-keygen -R <hostname>` and `ssh-keygen -R <ip>` clear the stale entry.

**Cloud-init doesn't re-run on a rebuilt clone.**
The `instance-id` in `meta-data` is timestamped so every provision is unique. If for some reason you need to force a re-run on an already-provisioned VM: `sudo cloud-init clean --logs && sudo rm -rf /var/lib/cloud/instances/* && sudo reboot`.

---

## Summary of what each VM gets out of the box

* Static IP on `eth0`, DHCP disabled.
* Hostname + FQDN set.
* SSH with your public key installed, `adminuser` with NOPASSWD sudo.
* Hyper-V integration daemons enabled (KVP, fcopy, VSS).
* Base tools installed: curl, jq, htop, dnsutils, net-tools, ca-certificates, gnupg.
* Timezone set (default America/Los_Angeles, change in `New-LabVM` if needed).
* `/etc/hosts` populated with every lab VM so cross-node name resolution works.
* Swap disabled (Kubernetes prereq).
* Custom shell prompt and `ll` alias for `adminuser`.
