# =============================================================================
# Lab Configuration (edit this file first, then run scripts in order)
# =============================================================================
# All other scripts dot-source this file to pick up these settings.
# =============================================================================

# --- Template source VM (Ubuntu already installed on this one) ---------------
# Template stays on the External switch at 192.168.1.200 so 01/03 can reach
# it on the home network. Clones get moved to the Lab switch at import time.
$global:LAB_TEMPLATE_VM       = 'ubuntu_template'
$global:LAB_TEMPLATE_IP       = '192.168.1.200'
$global:LAB_TEMPLATE_USER     = 'adminuser'

# --- Export destination -------------------------------------------------------
$global:LAB_EXPORT_ROOT       = 'C:\vmimages\Exports\HyperV'
$global:LAB_VMS_ROOT          = 'C:\vmimages\VMs'
$global:LAB_SEEDS_ROOT        = 'C:\vmimages\seeds'
$global:LAB_TEMPLATE_DIR      = "$LAB_EXPORT_ROOT\template"

# --- Lab network (isolated from 192.168.1.x home network) --------------------
# Internal Hyper-V vSwitch + Windows NAT. The Windows host is the gateway
# (192.168.100.1). See 00a-setup-lab-network.ps1 to create it.
#
# Lab VM IP reservation: 192.168.100.201 through 192.168.100.220 (20 slots).
# To add a VM later, append to $LAB_VMS below using the next free IP in
# that range. The range is validated by 06-provision-all-vms.ps1.
$global:LAB_VSWITCH           = 'Lab'
$global:LAB_SUBNET            = '192.168.100.0/24'
$global:LAB_HOST_IP           = '192.168.100.1'        # Windows host's IP on the Lab vSwitch
$global:LAB_GATEWAY           = '192.168.100.201'      # default gateway for lab VMs (lab-gateway VM, stage 2)
$global:LAB_NETMASK_PREFIX    = 24
$global:LAB_DNS               = @('1.1.1.1','8.8.8.8') # external DNS (goes out through host NAT)
$global:LAB_TIMEZONE          = 'America/Los_Angeles'
$global:LAB_IP_RANGE_START    = 201                    # first IP reserved for lab VMs
$global:LAB_IP_RANGE_END      = 220                    # last IP reserved for lab VMs
$global:LAB_DOMAIN            = 'lab.local'            # DNS suffix for lab VMs (used in FQDN + /etc/hosts + search)

# --- SSH key used for lab VMs -------------------------------------------------
$global:LAB_SSH_PRIVATE_KEY   = "$HOME\.ssh\controlplane01"
$global:LAB_SSH_PUBLIC_KEY    = "$HOME\.ssh\controlplane01.pub"

# --- VM sizing defaults -------------------------------------------------------
$global:LAB_DEFAULT_MEMORY_MB = 4096
$global:LAB_DEFAULT_CPUS      = 2

# --- The lab fleet -----------------------------------------------------------
# Each entry: Hyper-V VM name, Linux hostname, static IP on the Lab switch.
$global:LAB_VMS = @(
    @{ VMName='vm1-lab-gateway';          Hostname='lab-gateway';          IPAddress='192.168.100.201' }
    @{ VMName='vm2-lab-k3s-controlplane'; Hostname='lab-k3s-controlplane'; IPAddress='192.168.100.202' }
    @{ VMName='vm3-lab-k3s-node01';       Hostname='lab-k3s-node01';       IPAddress='192.168.100.203' }
    @{ VMName='vm4-lab-k3s-node02';       Hostname='lab-k3s-node02';       IPAddress='192.168.100.204' }
    @{ VMName='vm5-lab-datastore';        Hostname='lab-datastore';        IPAddress='192.168.100.205' }
    @{ VMName='vm6-lab-ai-ops';           Hostname='lab-ai-ops';           IPAddress='192.168.100.206' }
    @{ VMName='vm7-lab-automation';       Hostname='lab-automation';       IPAddress='192.168.100.207' }
    @{ VMName='vm8-lab-platform-eng'; Hostname='lab-platform-eng'; IPAddress='192.168.100.208' }
)

Write-Host "Lab config loaded: $($LAB_VMS.Count) VMs planned, template = $LAB_TEMPLATE_VM, switch = $LAB_VSWITCH" -ForegroundColor DarkGray
