# =============================================================================
# 00a - Set up the Lab virtual network (one-time, idempotent)
# =============================================================================
# Creates:
#   - Internal Hyper-V vSwitch named $LAB_VSWITCH (default: 'Lab')
#   - IP $LAB_HOST_IP on the host's vEthernet adapter for that switch
#   - NAT network so VMs on 192.168.100.0/24 reach the internet through the
#     Windows host.
# Safe to re-run. Must be run as Administrator.
# =============================================================================

. "$PSScriptRoot\00-config.ps1"

$ErrorActionPreference = 'Stop'

# --- Sanity: must be admin ---------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated (Administrator) PowerShell."
}

# --- 1. Create or reuse the Internal vSwitch ---------------------------------
Write-Host "`n[00a] Ensuring Hyper-V vSwitch '$LAB_VSWITCH' exists..." -ForegroundColor Cyan
$vswitch = Get-VMSwitch -Name $LAB_VSWITCH -ErrorAction SilentlyContinue
if (-not $vswitch) {
    New-VMSwitch -Name $LAB_VSWITCH -SwitchType Internal | Out-Null
    Write-Host "[00a]   created '$LAB_VSWITCH' (Internal)" -ForegroundColor Green
} else {
    if ($vswitch.SwitchType -ne 'Internal') {
        throw "vSwitch '$LAB_VSWITCH' exists but is type $($vswitch.SwitchType). Expected Internal. Remove it (Remove-VMSwitch) or change `$LAB_VSWITCH."
    }
    Write-Host "[00a]   '$LAB_VSWITCH' already exists (Internal)." -ForegroundColor DarkGray
}

# --- 2. Assign the host IP on the vEthernet adapter for that switch ---------
Write-Host "[00a] Assigning $LAB_HOST_IP/$LAB_NETMASK_PREFIX to vEthernet ($LAB_VSWITCH)..." -ForegroundColor Cyan
$ifAlias = "vEthernet ($LAB_VSWITCH)"

# Wait for the vEthernet adapter to materialize (can take a second after New-VMSwitch)
$deadline = (Get-Date).AddSeconds(15)
do {
    $netAdapter = Get-NetAdapter -Name $ifAlias -ErrorAction SilentlyContinue
    if (-not $netAdapter) { Start-Sleep 1 }
} until ($netAdapter -or (Get-Date) -gt $deadline)

if (-not $netAdapter) { throw "vEthernet adapter for '$LAB_VSWITCH' never appeared." }

$existingIP = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $LAB_HOST_IP }

if (-not $existingIP) {
    # Remove any stray IPv4 that doesn't match; gives clean state on re-runs
    Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "[00a]   removing stale IP $($_.IPAddress) from $ifAlias" -ForegroundColor DarkGray
            Remove-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $LAB_HOST_IP -PrefixLength $LAB_NETMASK_PREFIX | Out-Null
    Write-Host "[00a]   assigned $LAB_HOST_IP/$LAB_NETMASK_PREFIX" -ForegroundColor Green
} else {
    Write-Host "[00a]   $LAB_HOST_IP already assigned." -ForegroundColor DarkGray
}

# --- 3. Create the NAT rule for the lab subnet ------------------------------
Write-Host "[00a] Ensuring NAT for $LAB_SUBNET..." -ForegroundColor Cyan
$natName = "Lab-NAT"
$existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue

if (-not $existingNat) {
    # Only one NetNat per internal prefix is allowed. Check the prefix too.
    $conflicting = Get-NetNat -ErrorAction SilentlyContinue |
        Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $LAB_SUBNET }
    if ($conflicting) {
        throw "Another NetNat already claims $LAB_SUBNET : '$($conflicting.Name)'. Remove it (Remove-NetNat) or change `$LAB_SUBNET."
    }
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $LAB_SUBNET | Out-Null
    Write-Host "[00a]   created NAT '$natName' for $LAB_SUBNET" -ForegroundColor Green
} else {
    if ($existingNat.InternalIPInterfaceAddressPrefix -ne $LAB_SUBNET) {
        throw "NAT '$natName' exists but covers $($existingNat.InternalIPInterfaceAddressPrefix). Remove it and re-run."
    }
    Write-Host "[00a]   NAT '$natName' already exists." -ForegroundColor DarkGray
}

# --- 4. Summary --------------------------------------------------------------
Write-Host "`n[00a] Lab network is ready." -ForegroundColor Green
Write-Host ("  vSwitch     : {0} (Internal)"          -f $LAB_VSWITCH)
Write-Host ("  Host IP     : {0}/{1} on {2}"          -f $LAB_HOST_IP, $LAB_NETMASK_PREFIX, $ifAlias)
Write-Host ("  NAT         : {0} -> internet"         -f $LAB_SUBNET)
Write-Host ("  Lab VM range: {0}.{1} - {0}.{2} (reserved, {3} currently in use)" `
    -f ($LAB_SUBNET -replace '\.0/24',''),
       $LAB_IP_RANGE_START,
       $LAB_IP_RANGE_END,
       $LAB_VMS.Count)
