# =============================================================================
# 99 - Destroy Lab (nuke all provisioned VMs, keep template)
# =============================================================================
# Stops and removes every VM listed in LAB_VMS, plus their disk folders and
# seed ISOs. Does NOT touch the template VM or its export.
# Prompts for confirmation unless -Force is passed.
# =============================================================================

param([switch]$Force)

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Continue'

if (-not $Force) {
    $answer = Read-Host "This will delete $($LAB_VMS.Count) VMs and their disks. Type YES to continue"
    if ($answer -ne 'YES') { Write-Host "Aborted." -ForegroundColor Yellow; return }
}

foreach ($v in $LAB_VMS) {
    $name = $v.VMName
    Write-Host "`n[99] Removing $name..." -ForegroundColor Yellow
    Stop-VM   -Name $name -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $name -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $LAB_VMS_ROOT   $name) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $LAB_SEEDS_ROOT $name) -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n[99] Remaining Hyper-V VMs:" -ForegroundColor Cyan
Get-VM | Select-Object Name, State | Format-Table -AutoSize

Write-Host "[99] Done." -ForegroundColor Green
