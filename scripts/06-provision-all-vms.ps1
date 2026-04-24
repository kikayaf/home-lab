# =============================================================================
# 06 - Provision All Lab VMs
# =============================================================================
# Loads the config and functions, then provisions every VM in LAB_VMS.
# Safe to re-run: New-LabVM skips any VM that already exists and is reachable
# at its configured IP. If a VM exists but is unreachable, it prints a warning
# and skips so you can fix it by hand (or run 99-destroy-lab.ps1 first).
# Each new VM takes 2 to 4 minutes.
# =============================================================================

. "$PSScriptRoot\00-config.ps1"
. "$PSScriptRoot\05-lab-functions.ps1"

$ErrorActionPreference = 'Stop'

# --- Sanity: must be admin to call Hyper-V cmdlets reliably -----------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated (Administrator) PowerShell. Non-admin sessions silently hide existing VMs from Get-VM, which causes the plan to mis-classify running VMs as missing."
}

# --- Validate all lab VM IPs fall inside the reserved range ------------------
# Catches accidental edits like assigning .225 when the range is .201-.220.
foreach ($v in $LAB_VMS) {
    if ($v.IPAddress -notmatch '^192\.168\.100\.(\d+)$') {
        throw "$($v.VMName): IP $($v.IPAddress) is not on the Lab subnet 192.168.100.0/24."
    }
    $octet = [int]$Matches[1]
    if ($octet -lt $LAB_IP_RANGE_START -or $octet -gt $LAB_IP_RANGE_END) {
        throw "$($v.VMName): IP $($v.IPAddress) is outside the reserved lab range .$LAB_IP_RANGE_START-.$LAB_IP_RANGE_END. Edit 00-config.ps1."
    }
}
# Catch duplicate IPs too
$dup = $LAB_VMS | Group-Object IPAddress | Where-Object Count -gt 1
if ($dup) { throw "Duplicate IPs in LAB_VMS: $(($dup.Name) -join ', ')" }

# --- Pre-flight summary -------------------------------------------------------
$existingVMs = (Get-VM -ErrorAction SilentlyContinue | Where-Object Name -like 'vm*-lab-*').Name

$already     = @()
$pending     = @()
$unreachable = @()

foreach ($v in $LAB_VMS) {
    if ($v.VMName -in $existingVMs) {
        $up = Test-Connection $v.IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($up) { $already += $v } else { $unreachable += $v }
    } else {
        $pending += $v
    }
}

Write-Host "`n[06] Plan:" -ForegroundColor Cyan
Write-Host ("  Already provisioned : {0}" -f $already.Count)     -ForegroundColor DarkGray
Write-Host ("  To provision        : {0}" -f $pending.Count)     -ForegroundColor Cyan
if ($unreachable.Count -gt 0) {
    Write-Host ("  Exists but unreachable : {0}" -f $unreachable.Count) -ForegroundColor Yellow
    foreach ($v in $unreachable) {
        Write-Host ("    - {0} ({1})" -f $v.VMName, $v.IPAddress) -ForegroundColor Yellow
    }
    Write-Host "  These will be skipped. Remove them manually (or run 99-destroy-lab.ps1) then re-run 06." -ForegroundColor Yellow
}

if ($pending.Count -eq 0 -and $unreachable.Count -eq 0) {
    Write-Host "`n[06] Nothing to do. All VMs are provisioned." -ForegroundColor Green
    return
}

# --- Provision missing VMs ----------------------------------------------------
$start = Get-Date
if ($pending.Count -gt 0) {
    Write-Host "`n[06] Provisioning $($pending.Count) VM(s)..." -ForegroundColor Cyan
}

foreach ($vm in $LAB_VMS) {
    # New-LabVM is idempotent, so passing the full list is fine. It skips
    # what's already up and only does work for the pending ones.
    New-LabVM @vm
}

$elapsed = (Get-Date) - $start
Write-Host ("`n[06] Done. Total time: {0:N1} minutes." -f $elapsed.TotalMinutes) -ForegroundColor Green

Write-Host "`n[06] Lab inventory:" -ForegroundColor Cyan
Get-VM | Where-Object Name -like 'vm*-lab-*' |
    Select-Object Name, State,
        @{N='Uptime';  E={$_.Uptime}},
        @{N='MemoryGB';E={[math]::Round($_.MemoryStartup/1GB,1)}},
        @{N='CPU';     E={$_.ProcessorCount}} |
    Sort-Object Name |
    Format-Table -AutoSize
