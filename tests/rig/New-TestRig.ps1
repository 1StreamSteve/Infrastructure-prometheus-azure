<#
.SYNOPSIS
    Create (or refresh) the monitoring test rig: a WSL Ubuntu 24.04 distro
    running the same Prometheus, blackbox_exporter and Grafana as
    Monitoring-VM-001, with fake targets and an SMTP sink.

.DESCRIPTION
    First run installs a fresh distro named -Name (your own Ubuntu is not
    touched), switches systemd on, restarts it, then runs provision.sh.
    Later runs re-run provision.sh, which is idempotent and redeploys the
    repo's files. -Recreate unregisters the distro first.

    While the rig runs, the production 10.x addresses sit on the shared WSL
    loopback, so other WSL distros also reach the rig's fakes on them.
    Remove-TestRig.ps1 takes them away again.

.EXAMPLE
    pwsh -NoProfile -File tests\rig\New-TestRig.ps1
.EXAMPLE
    wsl -d monitoring-synctest -- rig status
#>
param(
    [string] $Name = 'monitoring-synctest',
    [switch] $Recreate
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')

function Get-Distros {
    # wsl.exe writes UTF-16; strip NULs and blank lines.
    (wsl.exe --list --quiet) -replace "`0", '' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
}

if ($Recreate -and (Get-Distros) -contains $Name) {
    Write-Host "Unregistering $Name"
    wsl.exe --unregister $Name | Out-Null
}

if ((Get-Distros) -notcontains $Name) {
    Write-Host "Installing Ubuntu-24.04 as $Name"
    wsl.exe --install Ubuntu-24.04 --name $Name --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install failed ($LASTEXITCODE)" }
}

# Forward slashes: the shell inside WSL would eat backslashes.
$wslRepo = (wsl.exe -d $Name -u root -- wslpath -a ("$repo" -replace '\\', '/'))
if (-not $wslRepo) { throw "wslpath could not translate $repo" }
$wslRepo = "$wslRepo".Trim()
Write-Host "Repo inside the rig: $wslRepo"

wsl.exe -d $Name -u root -- bash "$wslRepo/tests/rig/provision.sh" stage1
if ($LASTEXITCODE -ne 0) { throw "provision stage1 failed ($LASTEXITCODE)" }
wsl.exe --terminate $Name | Out-Null

wsl.exe -d $Name -u root -- bash "$wslRepo/tests/rig/provision.sh"
if ($LASTEXITCODE -ne 0) { throw "provision failed ($LASTEXITCODE)" }

Write-Host "`nRig ready. Try:  wsl -d $Name -- rig status"
