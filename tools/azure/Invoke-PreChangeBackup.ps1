<#
.SYNOPSIS
    On-demand Azure Backup of Monitoring-VM-001 before a change, waiting until
    it has an instant-restore point.

.DESCRIPTION
    Starts an Azure Backup "backup now" job for Monitoring-VM-001 in its
    Recovery Services vault (cx-nginx-vm-001-backup, shared with
    CX-Nginx-VM-001). It then polls the job until its "Take Snapshot" task
    completes. Copied from the nginx repo with the target changed. At that
    point an instant-restore recovery point exists, and the VM can be put
    back with Restore VM, Replace existing (portal: vault > Backup items >
    the VM > Restore VM).

    The "Transfer data to vault" task carries on for about 3 hours afterwards.
    That doesn't block the change: the instant snapshot is the restore point.

    Exit 0 means the VM has a completed snapshot. Anything else means do
    NOT proceed with the change.

    This is the get-out-of-jail option. The first-line undo for a monitoring
    config problem is still `sync.sh --restore-full`, which takes seconds.

.EXAMPLE
    pwsh -NoProfile -File tools\azure\Invoke-PreChangeBackup.ps1 -RetainDays 30
#>
param(
    [string] $ResourceGroup = 'RG_Infrastructure',
    [int]    $RetainDays    = 30,
    [int]    $TimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targets = @(
    @{ Vm = 'Monitoring-VM-001'; Vault = 'cx-nginx-vm-001-backup' }
)
$retain = (Get-Date).AddDays($RetainDays).ToString('dd-MM-yyyy')

function Invoke-Az {
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed:`n$($out -join "`n")" }
    return ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
}

Write-Host "Azure context: $(Invoke-Az account show --query '{s:name,u:user.name}' -o tsv)"
Write-Host "Retain until: $retain`n"

foreach ($t in $targets) {
    # Friendly names (the VM name) for container and item; the long
    # iaasvmcontainerv2;... ids are rejected by backup-now.
    $t.Job = Invoke-Az backup protection backup-now -g $ResourceGroup -v $t.Vault -c $t.Vm -i $t.Vm `
        --backup-management-type AzureIaasVM --retain-until $retain --query name -o tsv
    $t.Started = Get-Date
    Write-Host "$($t.Vm): backup job $($t.Job) started in vault $($t.Vault)"
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 30
    $pending = 0
    foreach ($t in $targets) {
        if ($t.ContainsKey('Done')) { continue }
        $j = Invoke-Az backup job show -g $ResourceGroup -v $t.Vault -n $t.Job `
            --query '{status:properties.status, tasks:properties.extendedInfo.tasksList[].{task:taskId, status:status}}' -o json |
            ConvertFrom-Json
        $snap = @($j.tasks | Where-Object { $_.task -eq 'Take Snapshot' })[0]
        $snapStatus = if ($snap) { $snap.status } else { 'not started' }
        $mins = [int]((Get-Date) - $t.Started).TotalMinutes
        Write-Host ("  {0}: job {1}, Take Snapshot {2} ({3} min)" -f $t.Vm, $j.status, $snapStatus, $mins)
        if ($j.status -in @('Failed', 'Cancelled', 'CompletedWithWarnings')) { $t.Done = "FAILED: job $($j.status)" }
        elseif ($snapStatus -eq 'Completed') { $t.Done = 'OK' }
        elseif ($snapStatus -eq 'Failed') { $t.Done = 'FAILED: snapshot failed' }
        else { $pending++ }
    }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)

Write-Host ''
$ok = $true
foreach ($t in $targets) {
    $state = if ($t.ContainsKey('Done')) { $t.Done } else { "TIMED OUT after $TimeoutMinutes min" }
    if ($state -ne 'OK') { $ok = $false }
    $rp = if ($state -eq 'OK') {
        Invoke-Az backup recoverypoint list -g $ResourceGroup -v $t.Vault --backup-management-type AzureIaasVM `
            -c $t.Vm -i $t.Vm --query '[0].properties.recoveryPointTime' -o tsv
    } else { '-' }
    Write-Host ("{0}: {1}   newest recovery point {2}" -f $t.Vm, $state, $rp)
}

if ($ok) {
    Write-Host "`nThe VM has an instant-restore point. Safe to proceed with the change."
    exit 0
}
Write-Host "`nDO NOT PROCEED: the VM has no completed snapshot." -ForegroundColor Red
exit 1
