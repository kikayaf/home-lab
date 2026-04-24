# =============================================================================
# 03 - Export Template as Reusable Clone Source
# =============================================================================
# Exports the prepped template VM, renames the output folder to 'template'
# so New-LabVM picks it up by default.
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Stop'

Write-Host "`n[03] Verifying template VM is Off..." -ForegroundColor Cyan
$state = (Get-VM -Name $LAB_TEMPLATE_VM).State
if ($state -ne 'Off') {
    throw "Template VM '$LAB_TEMPLATE_VM' is $state, expected Off. Run 01-prepare-template.ps1 first."
}

Write-Host "[03] Removing any previous export..." -ForegroundColor Cyan
Remove-Item "$LAB_EXPORT_ROOT\$LAB_TEMPLATE_VM" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$LAB_EXPORT_ROOT\template"         -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "[03] Exporting $LAB_TEMPLATE_VM to $LAB_EXPORT_ROOT (this copies the full VHDX, a few minutes)..." -ForegroundColor Cyan
Export-VM -Name $LAB_TEMPLATE_VM -Path $LAB_EXPORT_ROOT

Write-Host "[03] Renaming exported folder to 'template'..." -ForegroundColor Cyan
Rename-Item "$LAB_EXPORT_ROOT\$LAB_TEMPLATE_VM" "$LAB_EXPORT_ROOT\template"

$vmcx = Get-ChildItem "$LAB_TEMPLATE_DIR\Virtual Machines\*.vmcx" | Select-Object -First 1
if (-not $vmcx) {
    throw "Export did not produce a .vmcx file under $LAB_TEMPLATE_DIR"
}

Write-Host "[03] Template exported: $($vmcx.FullName)" -ForegroundColor Green
