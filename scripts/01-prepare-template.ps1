# =============================================================================
# 01 - Prepare Template VM
# =============================================================================
# Starts the Ubuntu VM that will serve as the template, SSHes in, and runs
# 02-template-cleanup.sh to strip identity, install prerequisites, and shut
# down. Assumes the template VM has a static IP of $LAB_TEMPLATE_IP baked
# into its netplan config. If it doesn't, run this once inside the VM first:
#
#   sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null <<'EOF'
#   network:
#     version: 2
#     ethernets:
#       eth0:
#         addresses: [192.168.1.200/24]
#         routes:
#           - to: default
#             via: 192.168.1.254
#         nameservers:
#           addresses: [192.168.1.254, 1.1.1.1]
#   EOF
#   sudo chmod 600 /etc/netplan/50-cloud-init.yaml
#   sudo netplan apply
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Stop'

Write-Host "`n[01] Starting template VM '$LAB_TEMPLATE_VM'..." -ForegroundColor Cyan
if ((Get-VM -Name $LAB_TEMPLATE_VM).State -ne 'Running') {
    Start-VM -Name $LAB_TEMPLATE_VM
}

Write-Host "[01] Waiting for SSH on $LAB_TEMPLATE_IP..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep 5
    $up = Test-NetConnection -ComputerName $LAB_TEMPLATE_IP -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
} until ($up -or (Get-Date) -gt $deadline)

if (-not $up) {
    throw "SSH on $LAB_TEMPLATE_IP did not come up within 3 minutes. Confirm the template VM has a static IP of $LAB_TEMPLATE_IP in its netplan config."
}

Write-Host "[01] Clearing stale host keys..." -ForegroundColor Cyan
ssh-keygen -R $LAB_TEMPLATE_IP 2>$null | Out-Null

Write-Host "[01] Running cleanup script on template via SSH..." -ForegroundColor Cyan
$cleanup = Join-Path $PSScriptRoot '02-template-cleanup.sh'
if (-not (Test-Path $cleanup)) { throw "Missing $cleanup" }

# Pipe the bash script over SSH and run it. VM shuts down at the end, which
# causes the SSH session to terminate. That error is swallowed below.
try {
    Get-Content $cleanup -Raw | ssh -o StrictHostKeyChecking=accept-new `
        -i $LAB_SSH_PRIVATE_KEY "$LAB_TEMPLATE_USER@$LAB_TEMPLATE_IP" 'bash -s'
} catch {
    Write-Host "[01] SSH closed (expected on shutdown)." -ForegroundColor DarkGray
}

Write-Host "[01] Waiting for template VM to power off..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep 5
    $state = (Get-VM -Name $LAB_TEMPLATE_VM).State
} until ($state -eq 'Off' -or (Get-Date) -gt $deadline)

if ($state -ne 'Off') {
    throw "Template VM did not shut down cleanly. Current state: $state"
}

Write-Host "[01] Template is ready to export." -ForegroundColor Green
