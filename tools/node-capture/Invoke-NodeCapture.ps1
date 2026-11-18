<#
.SYNOPSIS
    Pull a read-only snapshot of the Azure monitoring VM through an Azure
    managed Run Command, without SSH, NSG changes or Bastion file transfer.

.DESCRIPTION
    For each VM:
      1. Runs capture-monitoring.sh on the VM as root through a managed Run Command.
      2. The VM agent writes the script's stdout (the base64 tarball) and stderr
         (its log) to append blobs in a private container, through a container
         SAS that expires after two hours.
      3. Downloads both blobs with your own Entra login, checks the BEGIN/END
         markers and the sha256, and writes <vm>-<ts>.tgz and <vm>-<ts>.log
         to -OutDir.
      4. Deletes the Run Command resource and both blobs, whatever happened.

    The SAS is a user-delegation SAS signed with your login. It is never put on
    a command line: it goes to az only inside a JSON body file in %TEMP% that is
    deleted in the finally block.

    -FromFile skips Azure and only decodes and checks an output blob you have
    already downloaded (for example with Storage Explorer).

.NOTES
    Needs: az CLI logged in (az login), rights to create Run Commands on the VMs
    (Virtual Machine Contributor or Contributor), and Storage Blob Data
    Contributor on the storage account. The VMs need outbound HTTPS to the
    storage account; if the account's firewall is set to selected networks,
    allow the nodes' egress IPs.

.EXAMPLE
    pwsh -NoProfile -File tools\node-capture\Invoke-NodeCapture.ps1 -ResourceGroup RG_INFRASTRUCTURE -VmName Monitoring-VM-001 -StorageAccount 1streaminfrafiles

.EXAMPLE
    pwsh -NoProfile -File tools\node-capture\Invoke-NodeCapture.ps1 -FromFile C:\Downloads\Monitoring-VM-001.out
#>
[CmdletBinding(DefaultParameterSetName = 'Azure')]
param(
    [Parameter(ParameterSetName = 'Azure', Mandatory)] [string]   $ResourceGroup,
    [Parameter(ParameterSetName = 'Azure', Mandatory)] [string[]] $VmName,
    [Parameter(ParameterSetName = 'Azure', Mandatory)] [string]   $StorageAccount,
    [Parameter(ParameterSetName = 'Azure')]            [string]   $Container = 'monitoring-capture',
    [Parameter(ParameterSetName = 'Azure')]            [string]   $Subscription,
    [Parameter(ParameterSetName = 'Azure')]            [int]      $TimeoutMinutes = 15,
    [Parameter(ParameterSetName = 'File', Mandatory)]  [string]   $FromFile,
    [string] $OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) {
    $repo   = Resolve-Path (Join-Path $here '..\..')
    $OutDir = Join-Path $repo ("source-material\node-capture-" + (Get-Date -Format 'yyyyMMdd'))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Invoke-Az {
    # Runs az, returns stdout, throws on a non-zero exit.
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed:`n$($out -join "`n")" }
    return ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
}

function Expand-CaptureBlob {
    # Turns the Run Command output blob back into the tarball, refusing anything
    # truncated, padded or not matching the sha256 the node computed.
    param([string] $BlobFile, [string] $Destination)

    $text  = Get-Content -Raw -LiteralPath $BlobFile
    $begin = [regex]::Match($text, '-----BEGIN NODECAP host=(\S+) ts=(\S+) bytes=(\d+) sha256=([0-9a-f]{64})-----')
    if (-not $begin.Success)                      { throw "$BlobFile has no BEGIN NODECAP marker" }
    $endAt = $text.IndexOf('-----END NODECAP-----', $begin.Index)
    if ($endAt -lt 0)                             { throw "$BlobFile has no END NODECAP marker (truncated?)" }

    $node, $ts, $bytes, $sum = $begin.Groups[1..4].Value
    $b64  = $text.Substring($begin.Index + $begin.Length, $endAt - $begin.Index - $begin.Length) -replace '\s', ''
    $data = [Convert]::FromBase64String($b64)
    if ($data.Length -ne [int64]$bytes)           { throw "$node : got $($data.Length) bytes, node said $bytes" }

    $got = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($data)).ToLower()
    if ($got -ne $sum)                            { throw "$node : sha256 mismatch (node $sum, here $got)" }

    $tgz = Join-Path $Destination "$node-$ts.tgz"
    [System.IO.File]::WriteAllBytes($tgz, $data)
    Write-Host "  OK  $tgz  ($bytes bytes, sha256 verified)"
    return $tgz
}

# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'File') {
    Expand-CaptureBlob -BlobFile $FromFile -Destination $OutDir | Out-Null
    return
}
# ---------------------------------------------------------------------------

# pwsh -File passes "a,b" as one string, so split it here.
$VmName = $VmName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if ($Subscription) { Invoke-Az account set --subscription $Subscription | Out-Null }
$acct = Invoke-Az account show --query '{sub:name, user:user.name}' -o tsv
Write-Host "Azure context: $acct"

# The node script travels base64-encoded inside a tiny POSIX sh wrapper, so it
# runs under bash whatever shell the Run Command handler uses, and needs no
# JSON escaping. LF endings forced in case the checkout has CRLF.
$nodeScript = (Get-Content -Raw -LiteralPath (Join-Path $here 'capture-monitoring.sh')) -replace "`r`n", "`n"
$nodeB64    = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodeScript))
$wrapper    = "f=`$(mktemp) && printf '%s' '$nodeB64' | base64 -d > `"`$f`" && bash `"`$f`"; rc=`$?; rm -f `"`$f`"; exit `$rc"

Invoke-Az storage container create --account-name $StorageAccount --name $Container `
    --auth-mode login --public-access off -o none | Out-Null

$expiry = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm'Z'")
$sas    = Invoke-Az storage container generate-sas --account-name $StorageAccount --name $Container `
    --permissions acrw --expiry $expiry --https-only --as-user --auth-mode login -o tsv
$blobBase = "https://$StorageAccount.blob.core.windows.net/$Container"

$failed = @()
foreach ($vm in $VmName) {
    $ts       = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $rcName   = "nodecap-$ts"
    $outBlob  = "$vm/$ts.out"
    $errBlob  = "$vm/$ts.err"
    $bodyFile = Join-Path $env:TEMP "nodecap-$vm-$ts.json"
    $created  = $false
    Write-Host "`n== $vm"

    try {
        $vmInfo = Invoke-Az vm show -g $ResourceGroup -n $vm --query '{id:id, loc:location}' -o json | ConvertFrom-Json

        @{
            location   = $vmInfo.loc
            properties = @{
                source                          = @{ script = $wrapper }
                outputBlobUri                   = "$blobBase/$($outBlob)?$sas"
                errorBlobUri                    = "$blobBase/$($errBlob)?$sas"
                timeoutInSeconds                = $TimeoutMinutes * 60
                asyncExecution                  = $false
                treatFailureAsDeploymentFailure = $false
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM

        $url = "https://management.azure.com$($vmInfo.id)/runCommands/$($rcName)?api-version=2023-03-01"
        Invoke-Az rest --method put --url $url --body "@$bodyFile" -o none | Out-Null
        $created = $true
        Remove-Item -LiteralPath $bodyFile -Force
        Write-Host "  Run Command $rcName started"

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes + 2)
        do {
            Start-Sleep -Seconds 10
            $iv = Invoke-Az vm run-command show -g $ResourceGroup --vm-name $vm --name $rcName --instance-view `
                --query 'instanceView.{state:executionState, exit:exitCode, msg:executionMessage}' -o json | ConvertFrom-Json
            Write-Host "  state: $($iv.state)"
        } while ($iv.state -in @($null, 'Unknown', 'Pending', 'Running') -and (Get-Date) -lt $deadline)

        $outFile = Join-Path $OutDir "$vm-$ts.out"
        $logFile = Join-Path $OutDir "$vm-$ts.log"
        Invoke-Az storage blob download --account-name $StorageAccount -c $Container -n $errBlob -f $logFile --auth-mode login -o none | Out-Null
        Write-Host "  node log: $logFile"

        if ($iv.state -ne 'Succeeded' -or $iv.exit -ne 0) {
            throw "Run Command ended state=$($iv.state) exit=$($iv.exit) msg=$($iv.msg). See $logFile"
        }

        Invoke-Az storage blob download --account-name $StorageAccount -c $Container -n $outBlob -f $outFile --auth-mode login -o none | Out-Null
        Expand-CaptureBlob -BlobFile $outFile -Destination $OutDir | Out-Null
        Remove-Item -LiteralPath $outFile -Force
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed += $vm
    }
    finally {
        if (Test-Path -LiteralPath $bodyFile) { Remove-Item -LiteralPath $bodyFile -Force }
        if ($created) {
            & az vm run-command delete -g $ResourceGroup --vm-name $vm --name $rcName --yes -o none 2>$null
            Write-Host "  Run Command deleted (exit $LASTEXITCODE)"
        }
        foreach ($b in $outBlob, $errBlob) {
            & az storage blob delete --account-name $StorageAccount -c $Container -n $b --auth-mode login -o none 2>$null
        }
        Write-Host "  blobs deleted"
    }
}

Write-Host "`nOutput: $OutDir"
if ($failed) { Write-Host "Failed: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
