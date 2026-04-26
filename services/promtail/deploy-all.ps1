# =============================================================================
# Deploy Promtail to every lab VM. Run from Windows host.
# =============================================================================
# Pushes services/promtail/install.sh + promtail-config.yml to each VM, then
# runs install.sh (which scp-stages the config to /etc/promtail/).
# Idempotent: re-running on a VM that already has Promtail active reinstalls
# config and restarts.
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

$installScript = 'C:\vmimages\services\promtail\install.sh'
$config        = 'C:\vmimages\services\promtail\promtail-config.yml'

foreach ($h in $labHosts) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host " $h"
    Write-Host "================================================================"

    try {
        scp $config        "${h}:/tmp/promtail-config.yml"
        scp $installScript "${h}:/tmp/install-promtail.sh"
        ssh $h 'bash /tmp/install-promtail.sh && rm -f /tmp/install-promtail.sh'
    }
    catch {
        Write-Host "[$h] FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Verify in Grafana > Explore > Loki:"
Write-Host '  {job="systemd-journal"}'
