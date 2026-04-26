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

Write-Host "==> Injecting Mermaid init block (ELK layout + tighter spacing)"
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

Get-ChildItem -Path $views -Filter '*.mmd' | ForEach-Object {
    $body = Get-Content -LiteralPath $_.FullName -Raw
    Set-Content -LiteralPath $_.FullName -Value ($initBlock + $body) -NoNewline
}

Write-Host ""
Write-Host "Done. Generated views:"
Get-ChildItem -Path $views -Filter '*.mmd' | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length/1KB, 1)) KB)" }
Write-Host ""
Write-Host "Commit the new files alongside your DSL change."
