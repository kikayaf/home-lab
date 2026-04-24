# =============================================================================
# 05 - Lab Provisioning Functions
# =============================================================================
# Defines two functions:
#   New-SeedIso  -> builds a cloud-init NoCloud ISO for a single VM
#   New-LabVM    -> imports template, attaches to Lab vSwitch, seed-boots, waits
#
# New-LabVM is idempotent:
#   - VM registered and reachable        -> skip.
#   - VM registered but not reachable    -> skip with warning.
#   - VM not registered, files on disk   -> clean orphans then provision.
#   - VM not registered, no files        -> provision normally.
#
# Dot-source this file to load the functions:
#   . .\05-lab-functions.ps1
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
    }
    return $p
}

function New-SeedIso {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $wslSource = ConvertTo-WslPath $SourceDir
    $wslOut    = ConvertTo-WslPath $OutputPath
    $cmd = "genisoimage -quiet -output '$wslOut' -volid CIDATA -joliet -rock '$wslSource/user-data' '$wslSource/meta-data' '$wslSource/network-config'"
    wsl -e bash -c $cmd
    if (-not (Test-Path $OutputPath)) { throw "Seed ISO creation failed at $OutputPath" }
}

function New-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Gateway     = $LAB_GATEWAY,
        [int]   $Prefix      = $LAB_NETMASK_PREFIX,
        [string[]]$DNS       = $LAB_DNS,
        [string]$VSwitch     = $LAB_VSWITCH,
        [string]$Domain      = $LAB_DOMAIN,
        [string]$SSHKeyFile  = $LAB_SSH_PUBLIC_KEY,
        [string]$TemplateDir = $LAB_TEMPLATE_DIR,
        [string]$VMRoot      = $LAB_VMS_ROOT,
        [string]$SeedRoot    = $LAB_SEEDS_ROOT,
        [string]$Timezone    = $LAB_TIMEZONE,
        [int]   $MemoryMB    = $LAB_DEFAULT_MEMORY_MB,
        [int]   $CPUs        = $LAB_DEFAULT_CPUS,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'

    $dest    = Join-Path $VMRoot   $VMName
    $seedDir = Join-Path $SeedRoot $VMName

    # --- Idempotency checks --------------------------------------------------
    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        $reachable = Test-Connection $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($reachable) {
            Write-Host "[skip] $VMName already provisioned and reachable at $IPAddress" -ForegroundColor DarkGray
            return
        } else {
            Write-Warning "[skip] $VMName exists but is NOT reachable at $IPAddress. State: $($existing.State). Remove it manually (or run 99-destroy-lab.ps1) then re-run 06. Use -Force on New-LabVM to override."
            return
        }
    }

    # --- Orphan cleanup (only when VM is NOT registered) --------------------
    # Safety check: if files exist AND key files are locked, Hyper-V is
    # holding them. That means Get-VM lied (permissions? transient?) and the
    # VM is actually live. Abort rather than trash a running VM.
    if (-not $existing) {
        $orphans = @()
        if (Test-Path $dest)    { $orphans += $dest }
        if (Test-Path $seedDir) { $orphans += $seedDir }
        if ($orphans.Count -gt 0) {
            $locked = @()
            Get-ChildItem -Path $dest -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.vmcx','.vmrs','.vmgs','.vhdx','.avhdx' } |
                ForEach-Object {
                    try {
                        $fs = [System.IO.File]::Open($_.FullName, 'Open', 'Read', 'None')
                        $fs.Close()
                    } catch {
                        $locked += $_.FullName
                    }
                }
            if ($locked.Count -gt 0) {
                throw @"
Files at $dest are locked by Hyper-V, but Get-VM says '$VMName' is not registered.
This is almost always a permissions issue: run PowerShell as Administrator.
Locked files (sample):
  $($locked | Select-Object -First 3 -join "`n  ")
Aborting before damaging a live VM.
"@
            }

            Write-Warning "[cleanup] $VMName has orphaned files from a previous run (VM not registered in Hyper-V). Removing:"
            foreach ($p in $orphans) {
                Write-Warning "           $p"
                Remove-Item $p -Recurse -Force
            }
        }
    }

    # --- Verify the Lab vSwitch exists --------------------------------------
    if (-not (Get-VMSwitch -Name $VSwitch -ErrorAction SilentlyContinue)) {
        throw "Hyper-V vSwitch '$VSwitch' not found. Run 00a-setup-lab-network.ps1 first."
    }

    $pubkey = (Get-Content $SSHKeyFile -Raw).Trim()

    # --- Import VM -----------------------------------------------------------
    $vmcx = (Get-ChildItem "$TemplateDir\Virtual Machines\*.vmcx" | Select-Object -First 1).FullName
    if (-not $vmcx) { throw "No .vmcx in $TemplateDir. Run 03-export-template.ps1 first." }

    Write-Host "[1/5] Importing $VMName from template..." -ForegroundColor Cyan
    Import-VM -Path $vmcx -Copy -GenerateNewId `
        -VirtualMachinePath  $dest `
        -VhdDestinationPath  (Join-Path $dest 'Virtual Hard Disks') `
        -SnapshotFilePath    (Join-Path $dest 'Snapshots') `
        -SmartPagingFilePath $dest |
        Rename-VM -NewName $VMName

    # Move the clone onto the Lab vSwitch and give it a fresh MAC
    Connect-VMNetworkAdapter -VMName $VMName -SwitchName $VSwitch
    Set-VMNetworkAdapter     -VMName $VMName -DynamicMacAddress

    Set-VMMemory    -VMName $VMName -StartupBytes ($MemoryMB * 1MB)
    Set-VMProcessor -VMName $VMName -Count $CPUs
    Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'

    # --- Build cloud-init seed -----------------------------------------------
    Write-Host "[2/5] Building cloud-init seed for $Hostname..." -ForegroundColor Cyan
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
      search: [$Domain]
"@

    # /etc/hosts entries include both FQDN and short name per convention:
    #   192.168.100.201 lab-gateway.lab.local lab-gateway
    $hostsLines = foreach ($v in $LAB_VMS) {
        "$($v.IPAddress) $($v.Hostname).$Domain $($v.Hostname)"
    }
    $hostsBlock = ($hostsLines -join "`n")

    $userdata = @"
#cloud-config
hostname: $Hostname
fqdn: $Hostname.$Domain
manage_etc_hosts: localhost
preserve_hostname: false
timezone: $Timezone

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

    # --- Make seed ISO and attach --------------------------------------------
    Write-Host "[3/5] Creating seed ISO..." -ForegroundColor Cyan
    $isoPath = Join-Path $seedDir 'seed.iso'
    New-SeedIso -SourceDir $seedDir -OutputPath $isoPath
    Add-VMDvdDrive -VMName $VMName -Path $isoPath

    # --- Boot and wait -------------------------------------------------------
    Write-Host "[4/5] Booting $VMName..." -ForegroundColor Cyan
    Start-VM -Name $VMName

    Write-Host "[5/5] Waiting for $IPAddress to respond..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep 5
        $up = Test-Connection $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    } until ($up -or (Get-Date) -gt $deadline)

    if ($up) {
        Write-Host "$VMName is up at $IPAddress. Ejecting seed ISO..." -ForegroundColor Green
        try {
            $dvd = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $isoPath }
            if ($dvd) {
                Set-VMDvdDrive -VMName $VMName `
                    -ControllerNumber   $dvd.ControllerNumber `
                    -ControllerLocation $dvd.ControllerLocation `
                    -Path $null
            }
        } catch {
            Write-Warning "$VMName seed ISO eject failed (non-fatal): $_"
        }
        ssh-keygen -R $IPAddress 2>$null | Out-Null
    } else {
        Write-Warning "$VMName did not respond at $IPAddress within 5 minutes. Check Hyper-V console."
    }
}

Write-Host "Lab functions loaded: New-LabVM, New-SeedIso" -ForegroundColor DarkGray
