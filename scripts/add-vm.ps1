# =============================================================================
# add-vm.ps1 - Add a single lab VM in one shot
# =============================================================================
# Appends a new entry to $LAB_VMS in 00-config.ps1, then runs:
#   06-provision-all-vms.ps1   (New-LabVM skips existing, builds just the new)
#   07-configure-ssh.ps1       (refreshes ~/.ssh/config managed block)
#   08-verify-lab.ps1          (SSH roundtrip to all VMs)
#
# Rolls back the config edit and Hyper-V state if provisioning fails before
# the VM is up and reachable.
#
# Usage:
#   .\add-vm.ps1 -Hostname 'lab-monitoring'
#   .\add-vm.ps1 -Hostname 'lab-monitoring' -IPAddress '192.168.100.215'
#   .\add-vm.ps1 -Hostname 'lab-monitoring' -MemoryMB 8192 -CPUs 4
#   .\add-vm.ps1 -Hostname 'lab-monitoring' -SkipVerify
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Hostname,
    [string]$VMName,
    [string]$IPAddress,
    [int]$MemoryMB,
    [int]$CPUs,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

# --- Sanity: must be admin to call Hyper-V cmdlets reliably -----------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated (Administrator) PowerShell. Non-admin sessions silently hide existing VMs, which makes orphan cleanup unsafe."
}

. "$PSScriptRoot\00-config.ps1"

$configPath = Join-Path $PSScriptRoot '00-config.ps1'

# --- Validate hostname -------------------------------------------------------
if ($Hostname -notmatch '^[a-z0-9][a-z0-9-]*[a-z0-9]$') {
    throw "Hostname '$Hostname' must be lowercase alphanumeric with internal hyphens only (e.g. 'lab-monitoring')."
}
if ($LAB_VMS.Hostname -contains $Hostname) {
    throw "Hostname '$Hostname' is already in LAB_VMS."
}

# --- Compute VMName (vm{next}-{hostname}) ------------------------------------
if (-not $VMName) {
    $maxN = 0
    foreach ($v in $LAB_VMS) {
        if ($v.VMName -match '^vm(\d+)-') {
            $n = [int]$Matches[1]
            if ($n -gt $maxN) { $maxN = $n }
        }
    }
    $VMName = "vm$($maxN + 1)-$Hostname"
}
if ($LAB_VMS.VMName -contains $VMName) {
    throw "VMName '$VMName' is already in LAB_VMS."
}

# --- Compute IPAddress (next free in reserved range) -------------------------
if (-not $IPAddress) {
    $used = @($LAB_VMS.IPAddress)
    for ($o = $LAB_IP_RANGE_START; $o -le $LAB_IP_RANGE_END; $o++) {
        $candidate = "192.168.100.$o"
        if ($candidate -notin $used) {
            $IPAddress = $candidate
            break
        }
    }
    if (-not $IPAddress) {
        throw "No free IPs in reserved range .$LAB_IP_RANGE_START-.$LAB_IP_RANGE_END. Expand the range in 00-config.ps1 or remove a VM."
    }
} else {
    if ($IPAddress -notmatch '^192\.168\.100\.(\d+)$') {
        throw "IP $IPAddress must be on the Lab subnet 192.168.100.0/24."
    }
    $octet = [int]$Matches[1]
    if ($octet -lt $LAB_IP_RANGE_START -or $octet -gt $LAB_IP_RANGE_END) {
        throw "IP $IPAddress is outside the reserved range .$LAB_IP_RANGE_START-.$LAB_IP_RANGE_END."
    }
    if ($LAB_VMS.IPAddress -contains $IPAddress) {
        throw "IP $IPAddress is already in LAB_VMS."
    }
}

Write-Host "`n[add-vm] Plan:" -ForegroundColor Cyan
Write-Host ("  VMName   : {0}" -f $VMName)
Write-Host ("  Hostname : {0}" -f $Hostname)
Write-Host ("  IPAddress: {0}" -f $IPAddress)
if ($MemoryMB) { Write-Host ("  MemoryMB : {0}" -f $MemoryMB) }
if ($CPUs)     { Write-Host ("  CPUs     : {0}" -f $CPUs) }

# --- Edit 00-config.ps1: insert new entry before closing ')' of $LAB_VMS ----
$backup = "$configPath.bak"
Copy-Item -Path $configPath -Destination $backup -Force

$lines    = Get-Content $configPath
$newEntry = "    @{{ VMName='{0}'; Hostname='{1}'; IPAddress='{2}' }}" -f $VMName, $Hostname, $IPAddress
$newLines = New-Object System.Collections.Generic.List[string]
$inArray  = $false
$inserted = $false

foreach ($line in $lines) {
    if (-not $inArray -and $line -match '\$global:LAB_VMS\s*=\s*@\(') {
        $inArray = $true
        $newLines.Add($line)
        continue
    }
    if ($inArray -and -not $inserted -and $line -match '^\s*\)\s*$') {
        $newLines.Add($newEntry)
        $newLines.Add($line)
        $inserted = $true
        $inArray  = $false
        continue
    }
    $newLines.Add($line)
}

if (-not $inserted) {
    Copy-Item -Path $backup -Destination $configPath -Force
    Remove-Item $backup -Force
    throw "Couldn't find the closing ')' of `$LAB_VMS in $configPath. File restored, no changes made."
}

Set-Content -Path $configPath -Value $newLines
Write-Host "`n[add-vm] 00-config.ps1 updated. Running provision + ssh + verify..." -ForegroundColor Cyan

# --- Run provision, ssh config, verify --------------------------------------
try {
    & "$PSScriptRoot\06-provision-all-vms.ps1"
    & "$PSScriptRoot\07-configure-ssh.ps1"
    if (-not $SkipVerify) {
        & "$PSScriptRoot\08-verify-lab.ps1"
    }
    Write-Host "`n[add-vm] $VMName added successfully." -ForegroundColor Green
    Remove-Item $backup -Force
}
catch {
    Write-Warning "Step failed: $_"

    # Decide whether to roll back. If the VM is up and reachable despite the
    # error (e.g. 08 verify failed on an unrelated VM), keep it.
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $up = Test-Connection $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue

    if ($vm -and $up) {
        Write-Warning "$VMName is running and reachable at $IPAddress. Leaving it in place and keeping the config edit. Investigate the error above."
        Remove-Item $backup -Force
        throw
    }

    Write-Warning "Rolling back: restoring 00-config.ps1 and removing $VMName state..."
    Copy-Item -Path $backup -Destination $configPath -Force
    Remove-Item $backup -Force

    if ($vm) {
        Stop-VM   $VMName -Force -ErrorAction SilentlyContinue
        Remove-VM $VMName -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $LAB_VMS_ROOT   $VMName) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $LAB_SEEDS_ROOT $VMName) -Recurse -Force -ErrorAction SilentlyContinue

    Write-Warning "Rollback complete. Fix the issue and retry .\add-vm.ps1 -Hostname $Hostname."
    throw
}
