# =============================================================================
# 04 - Set Up WSL + genisoimage (one time only)
# =============================================================================
# Needed to create cloud-init seed ISOs for each clone. Skips steps already
# complete.
# =============================================================================

$ErrorActionPreference = 'Stop'

Write-Host "`n[04] Checking WSL status..." -ForegroundColor Cyan
$distros = (wsl --list --quiet 2>$null) -replace "`0","" | Where-Object { $_ -and $_.Trim() -ne 'docker-desktop' }

if (-not ($distros -match '^Ubuntu$')) {
    Write-Host "[04] Installing Ubuntu WSL distro..." -ForegroundColor Yellow
    wsl --install -d Ubuntu
    Write-Host "`n[04] Ubuntu was just installed. Finish its first-run setup (username + password)" -ForegroundColor Yellow
    Write-Host "     in the Ubuntu window, then re-run this script." -ForegroundColor Yellow
    return
}

Write-Host "[04] Setting Ubuntu as default WSL distro..." -ForegroundColor Cyan
wsl --set-default Ubuntu | Out-Null

Write-Host "[04] Checking for genisoimage..." -ForegroundColor Cyan
$hasGeniso = $false
try {
    $v = wsl -e genisoimage --version 2>$null
    if ($v) { $hasGeniso = $true }
} catch { }

if (-not $hasGeniso) {
    Write-Host "[04] Installing genisoimage in WSL..." -ForegroundColor Yellow
    wsl -e bash -c "sudo apt update && sudo apt install -y genisoimage"
}

$ver = (wsl -e genisoimage --version 2>$null | Select-Object -First 1)
Write-Host "[04] Ready. $ver" -ForegroundColor Green
