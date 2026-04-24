# =============================================================================
# 07 - Configure SSH Aliases on Windows Host
# =============================================================================
# Appends a block of Host entries to ~/.ssh/config so you can 'ssh lab-gateway'
# instead of 'ssh adminuser@192.168.1.201 -i ~/.ssh/controlplane01'.
# Safe to re-run: existing lab block is removed before writing.
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Stop'

$sshDir = Join-Path $HOME '.ssh'
$configPath = Join-Path $sshDir 'config'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
if (-not (Test-Path $configPath)) { New-Item -ItemType File -Path $configPath | Out-Null }

$begin = '# --- lab cluster (managed by lab-setup scripts) ---'
$end   = '# --- end lab cluster ---'

# --- Build the new block first ----------------------------------------------
$homeForward = $HOME -replace '\\','/'
$keyForward  = $LAB_SSH_PRIVATE_KEY -replace '\\','/'
$privKeyForward = $keyForward -replace "^$([regex]::Escape($homeForward))", '~'

$entries = foreach ($v in $LAB_VMS) {
@"

Host $($v.Hostname)
    HostName $($v.IPAddress)
    User $LAB_TEMPLATE_USER
    IdentityFile $privKeyForward
    IdentitiesOnly yes
"@
}

# Normalize line endings inside entries to LF (SSH tolerates LF fine and it
# avoids the mixed CRLF/LF mess you get when editing on Windows).
$block = ($begin + ($entries -join '') + "`n" + $end + "`n") -replace "`r",''

# --- Rewrite the whole config atomically ------------------------------------
Write-Host "`n[07] Rewriting $configPath (stripping any previous lab block)..." -ForegroundColor Cyan
$content = Get-Content $configPath -Raw
if (-not $content) { $content = '' }

# Remove any previous managed lab block (handles both LF and CRLF markers)
$content = [regex]::Replace(
    $content,
    "(?ms)$([regex]::Escape($begin)).*?$([regex]::Escape($end))\r?\n?",
    ''
)

# Guarantee the existing content ends with a newline so the new block's
# '# --- lab cluster ...' marker can never concatenate onto a previous line.
if ($content.Length -gt 0 -and $content[-1] -ne "`n") { $content += "`n" }

Write-Host "[07] Writing $($LAB_VMS.Count) Host entries..." -ForegroundColor Cyan
Set-Content -Path $configPath -Value ($content + $block) -NoNewline

Write-Host "[07] Clearing stale known_hosts entries..." -ForegroundColor Cyan
foreach ($v in $LAB_VMS) {
    ssh-keygen -R $v.IPAddress 2>$null | Out-Null
    ssh-keygen -R $v.Hostname  2>$null | Out-Null
}

Write-Host "[07] Done. Try:  ssh $($LAB_VMS[0].Hostname)" -ForegroundColor Green
