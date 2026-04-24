# =============================================================================
# 08 - Verify Lab
# =============================================================================
# SSHes into each VM and prints hostname, IP, and machine-id.
# Each VM should report a distinct machine-id.
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Continue'

Write-Host "`n[08] Verifying lab VMs..." -ForegroundColor Cyan

$results = foreach ($v in $LAB_VMS) {
    $host_ = $v.Hostname
    Write-Host "`n--- $host_ ($($v.IPAddress)) ---" -ForegroundColor Cyan
    try {
        $output = ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 $host_ `
                      "hostname; ip -br a | grep -v ^lo; cat /etc/machine-id" 2>&1
        Write-Host $output
        [PSCustomObject]@{
            Host = $host_
            IP   = $v.IPAddress
            Status = 'OK'
        }
    } catch {
        Write-Warning "Failed to reach ${host_}: $_"
        [PSCustomObject]@{
            Host = $host_
            IP   = $v.IPAddress
            Status = 'FAILED'
        }
    }
}

Write-Host "`n[08] Summary:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failed = $results | Where-Object Status -eq 'FAILED'
if ($failed) {
    Write-Warning "$($failed.Count) VM(s) did not respond."
} else {
    Write-Host "[08] All VMs responded." -ForegroundColor Green
}
