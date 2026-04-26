# =============================================================================
# Generate Mermaid views from architecture/workspace.dsl
# =============================================================================
# Runs Structurizr CLI on lab-platform-eng (which has Docker) to export the
# DSL as one .mmd file per view, then pulls the results back into
# architecture/views/ for committing.
#
# Run this whenever workspace.dsl changes. Then commit the new .mmd files
# alongside the DSL edit so GitHub renders fresh diagrams.
# =============================================================================

$ErrorActionPreference = 'Stop'

$workdir = 'C:\vmimages\architecture'
$dsl     = Join-Path $workdir 'workspace.dsl'
$views   = Join-Path $workdir 'views'
$image   = 'structurizr/structurizr:latest'
$remote  = 'lab-platform-eng'

if (-not (Test-Path $dsl)) {
    Write-Error "workspace.dsl not found at $dsl"
    exit 1
}

if (-not (Test-Path $views)) {
    New-Item -ItemType Directory -Path $views | Out-Null
}

Write-Host "==> Pushing workspace.dsl to ${remote}:/tmp/structurizr-export/"
ssh $remote "rm -rf /tmp/structurizr-export && mkdir -p /tmp/structurizr-export"
scp $dsl "${remote}:/tmp/structurizr-export/workspace.dsl"

Write-Host "==> Running structurizr/cli export -format mermaid"
ssh $remote @"
docker run --rm \
    -v /tmp/structurizr-export:/usr/local/structurizr \
    -u 0:0 \
    $image \
    export \
    -workspace /usr/local/structurizr/workspace.dsl \
    -format mermaid
"@

Write-Host "==> Listing generated views"
ssh $remote 'ls -1 /tmp/structurizr-export/*.mmd'

Write-Host "==> Pulling .mmd files back to $views"
# Wipe stale views so we don't keep deleted ones
Get-ChildItem -Path $views -Filter '*.mmd' -ErrorAction SilentlyContinue | Remove-Item -Force
scp "${remote}:/tmp/structurizr-export/*.mmd" "$views\"

Write-Host "==> Cleaning up remote temp dir"
ssh $remote 'rm -rf /tmp/structurizr-export'

Write-Host "==> Injecting Mermaid init block + restyling layer subgraphs"

# Mermaid init directive: prepended to every .mmd. Sets:
#   - ELK layout engine (much better than default dagre for layered graphs;
#     supported by Mermaid 10.4+ which GitHub renders with).
#   - Smaller font and tighter rank/node spacing for narrow web columns.
#   - Curve style for cleaner edges.
$initBlock = @"
%%{init: {
  "theme": "default",
  "themeVariables": {"fontSize": "12px", "fontFamily": "arial"},
  "flowchart": {
    "defaultRenderer": "elk",
    "rankSpacing": 50,
    "nodeSpacing": 30,
    "padding": 8,
    "curve": "basis"
  }
}}%%

"@

# Layer-specific subgraph styling. Structurizr's default is light grey on
# white, dashed - basically invisible. We replace it with a tinted
# background + saturated border in the layer's color, so groups pop.
# Each entry is the literal subgraph label as Structurizr emits it.
$layerStyles = @{
    'Edge and Access layer'              = 'fill:#fff3e0,stroke:#f57c00,color:#bf360c,stroke-width:2px'
    'Application layer'                  = 'fill:#e3f2fd,stroke:#1976d2,color:#0d47a1,stroke-width:2px'
    'Platform layer'                     = 'fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c,stroke-width:2px'
    'Data layer'                         = 'fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px'
    'Security layer (cross-cutting)'     = 'fill:#ffebee,stroke:#c62828,color:#b71c1c,stroke-width:2px'
    'Observability layer (cross-cutting)' = 'fill:#e0f7fa,stroke:#00838f,color:#006064,stroke-width:2px'
}

Get-ChildItem -Path $views -Filter '*.mmd' | ForEach-Object {
    $lines = Get-Content -LiteralPath $_.FullName
    $output = New-Object System.Collections.Generic.List[string]
    $pendingGroup = $null

    foreach ($line in $lines) {
        # Detect: `      subgraph groupN ["Label"]`
        if ($line -match '^(\s*)subgraph\s+(group\d+)\s+\["(.+?)"\]') {
            $output.Add($line)
            $pendingGroup = @{
                Indent = $matches[1]
                Id     = $matches[2]
                Label  = $matches[3]
            }
            continue
        }

        # Replace the next `style groupN fill:...` line that matches the
        # pending subgraph, if its label is in our layer map.
        if ($pendingGroup -and $line -match "^\s*style\s+$($pendingGroup.Id)\s+fill:") {
            if ($layerStyles.ContainsKey($pendingGroup.Label)) {
                $newStyle = $layerStyles[$pendingGroup.Label]
                $output.Add("$($pendingGroup.Indent)  style $($pendingGroup.Id) $newStyle")
            } else {
                $output.Add($line)
            }
            $pendingGroup = $null
            continue
        }

        $output.Add($line)
    }

    $body = ($output -join "`n")
    Set-Content -LiteralPath $_.FullName -Value ($initBlock + $body) -NoNewline
}

Write-Host ""
Write-Host "Done. Generated views:"
Get-ChildItem -Path $views -Filter '*.mmd' | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length/1KB, 1)) KB)" }
Write-Host ""
Write-Host "Commit the new files alongside your DSL change."
