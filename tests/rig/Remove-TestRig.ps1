<#
.SYNOPSIS
    Stop the monitoring test rig and take the production 10.x addresses and
    the NAT rules back off the shared WSL network. -Unregister also deletes
    the distro.
#>
param(
    [string] $Name = 'monitoring-synctest',
    [switch] $Unregister
)
$ErrorActionPreference = 'Stop'

wsl.exe -d $Name -u root -- bash -c 'systemctl stop rig-fakes; /usr/local/sbin/rig-net down'
wsl.exe --terminate $Name | Out-Null
if ($Unregister) { wsl.exe --unregister $Name | Out-Null; Write-Host "$Name unregistered" }
else { Write-Host "$Name stopped; New-TestRig.ps1 brings it back" }
