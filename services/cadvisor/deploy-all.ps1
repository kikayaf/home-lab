# =============================================================================
# Deploy cAdvisor to every Docker host. Run from Windows host.
# =============================================================================
# cAdvisor exposes container-level metrics on /metrics. Prometheus scrapes
# each host's cAdvisor (see services/prometheus/prometheus.yml).
#
# Bound to :8088 instead of the default :8080 to avoid colliding with
# code-server on lab-platform-eng.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Map host -> lab IP. cAdvisor must bind to the lab IP specifically (not
# 0.0.0.0) on lab-gateway because Tailscale Funnel is bound to tailscale0:443
# and we want predictable interface binding everywhere.
$dockerHosts = @{
    'lab-gateway'      = '192.168.100.201'
    'lab-datastore'    = '192.168.100.205'
    'lab-platform-eng' = '192.168.100.208'
}

$image = 'gcr.io/cadvisor/cadvisor:v0.51.0'

foreach ($entry in $dockerHosts.GetEnumerator()) {
    $h  = $entry.Key
    $ip = $entry.Value

    Write-Host ""
    Write-Host "================================================================"
    Write-Host " $h ($ip)"
    Write-Host "================================================================"

    $script = @"
set -e
docker rm -f cadvisor 2>/dev/null || true
docker run -d \
    --name cadvisor \
    --restart unless-stopped \
    --privileged \
    --device=/dev/kmsg \
    -p ${ip}:8088:8080 \
    -v /:/rootfs:ro \
    -v /var/run:/var/run:ro \
    -v /sys:/sys:ro \
    -v /var/lib/docker/:/var/lib/docker:ro \
    -v /dev/disk/:/dev/disk:ro \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    --memory 256m \
    $image \
    --housekeeping_interval=10s \
    --store_container_labels=false \
    --whitelisted_container_labels=io.kubernetes.container.name,io.kubernetes.pod.name,io.kubernetes.pod.namespace
sleep 2
if curl -fsS http://${ip}:8088/metrics > /dev/null; then
    echo "[$h] cadvisor OK on :8088"
else
    echo "[$h] cadvisor NOT responding on :8088" >&2
    docker logs cadvisor --tail 20
    exit 1
fi
"@

    try {
        ssh $h $script
    }
    catch {
        Write-Host "[$h] FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done. Reload Prometheus to pick up the updated targets:"
Write-Host '  ssh lab-platform-eng "curl -X POST http://localhost:9090/-/reload"'
