# =============================================================================
# Deploy node_exporter to every lab VM. Run from Windows host.
# =============================================================================
# Pushes services/node-exporter/install.sh to each VM via scp, runs it as
# adminuser via ssh, and reports the result. Idempotent: re-running on a VM
# that already has node_exporter active is a no-op.
# =============================================================================

$ErrorActionPreference = 'Stop'

$labHosts = @(
    'lab-gateway',
    'lab-k3s-controlplane',
    'lab-k3s-node01',
    'lab-k3s-node02',
    'lab-datastore',
    'lab-ai-ops',
    'lab-automation',
    'lab-platform-eng'
)

$script = 'C:\vmimages\services\node-exporter\install.sh'

foreach ($h in $labHosts) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host " $h"
    Write-Host "================================================================"

    try {
        scp $script "${h}:/tmp/install-node-exporter.sh"
        ssh $h 'bash /tmp/install-node-exporter.sh && rm -f /tmp/install-node-exporter.sh'
    }
    catch {
        Write-Host "[$h] FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Check Prometheus targets:"
Write-Host "  https://prom.lab.local/targets"
