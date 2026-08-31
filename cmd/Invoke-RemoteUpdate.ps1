<#
.SYNOPSIS
    Installs the downloaded WSUS Offline updates on this machine and/or a list
    of remote machines, in parallel - or, with -ScanOnly, just reports what each
    machine needs without installing anything.

.DESCRIPTION
    Complements UpdateInstaller.exe, which only ever patches the machine it is
    run from. For each target this script:

        1. stages the client tree to C:\temp\wsusoffline over the admin share,
        2. runs cmd\DoUpdate.cmd there as SYSTEM via a scheduled task,
        3. collects the update log back to log\remote\,
        4. deletes the payload and the task again.

    Transport is SMB (robocopy) plus schtasks, so no WinRM configuration is
    needed on the targets - only the admin share and remote RPC, which is the
    default in a domain.

    With -ScanOnly, step 2 runs cmd\ScanOnly.cmd instead. That runs the same
    applicability search DoUpdate.cmd performs before installing - the Windows
    Update Agent against wsus\wsusscn2.cab - and stops there, so the run reports
    which updates the machine needs and which of those are missing from the
    download, without installing anything. Applicability can only be computed on
    the target itself, which is why a scan still needs the payload staged.

    Installation options come from client\UpdateInstaller.ini using the same
    key-to-switch mapping as the GUI, so a remote run behaves like a local one.
    Four switches are deliberately never passed: /showlog and /monitoron need an
    interactive desktop, and /autoreboot and /shutdown would restart the target.
    Instead the target's exit code is reported, so a machine needing a restart
    comes back as RebootRequired and is picked up by a later run once the
    operator has rebooted it.

    Note that DoUpdate.cmd exits 0 even when an installation failed, so the
    update log is also scanned and the status downgraded to
    CompletedWithErrors accordingly.

    The transport itself lives in WsusOfflineRemote.psm1 beside this script, so
    this script and Show-RemoteUpdateGui.ps1 drive the same implementation.

.PARAMETER ComputerName
    Target hostnames or IP addresses.

.PARAMETER TargetFile
    Text file of targets, one per line. Blank lines and lines starting with #
    are ignored. Combined with -ComputerName when both are given.

.PARAMETER IncludeLocalHost
    Also patch (or scan) the machine running this script. Runs in place from the
    repository - nothing is copied and nothing is deleted, because here the
    payload is the repository itself.

.PARAMETER ScanOnly
    Report what each target needs instead of installing. Nothing is installed;
    see the description for what a scan does touch.

.PARAMETER Throttle
    How many targets to work on at once. Defaults to 8.

.PARAMETER StagingRoot
    Directory on the target to stage into. Defaults to C:\temp. Created when
    absent, and in that case removed again afterwards; a directory that was
    already there is left alone.

.PARAMETER Credential
    Credentials for the targets. Omit to use the current user, which is the
    usual case for a domain admin.

.PARAMETER TimeoutMinutes
    How long to wait for one target to finish. Defaults to 180 for an install
    and 60 for a scan, which needs no more than the search takes.

.PARAMETER KeepPayload
    Leave the staged payload on the target. Makes repeat runs much faster,
    because robocopy then only transfers what changed - worth using between a
    scan and the install that follows it, since both stage the same tree.

.PARAMETER PayloadFilter
    Build a filtered payload with cmd\CopyToTarget.cmd instead of sending the
    whole client tree, e.g. w100-x64 or o2k16. Cuts transfer size when the
    download covers more than the targets need. Not useful with -ScanOnly: the
    "missing from the download" column is computed from what is staged, so a
    filtered payload would report the filtered-out updates as missing.

.EXAMPLE
    .\Invoke-RemoteUpdate.ps1 -ComputerName SRV01,10.0.0.42 -IncludeLocalHost

.EXAMPLE
    .\Invoke-RemoteUpdate.ps1 -TargetFile .\remote-targets.txt -ScanOnly

.EXAMPLE
    .\Invoke-RemoteUpdate.ps1 -TargetFile .\targets.txt -Throttle 4 -WhatIf
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]     $ComputerName,
    [string]       $TargetFile,
    [switch]       $IncludeLocalHost,
    [switch]       $ScanOnly,
    [ValidateRange(1, 64)]
    [int]          $Throttle = 8,
    [string]       $StagingRoot = 'C:\temp',
    [pscredential] $Credential,
    [ValidateRange(1, 1440)]
    [int]          $TimeoutMinutes,
    [switch]       $KeepPayload,
    [string]       $PayloadFilter
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WsusOfflineRemote.psm1') -Force

$cfg  = Get-WouRemoteConfig
$mode = if ($ScanOnly) { 'Scan' } else { 'Install' }
$verb = if ($ScanOnly) { 'Scanning' } else { 'Installing updates' }

# A scan is bounded by how long the WUA search takes, so it does not need the
# install timeout; -TimeoutMinutes still overrides either default.
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) {
    $TimeoutMinutes = if ($ScanOnly) { 60 } else { 180 }
}

# Start-Job cannot see this script's functions, so the worker imports the module
# the same way this script does. Everything else it needs arrives as one
# hashtable, splatted onto the shared entry point.
$HostWorker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Invoke-HostRun @Params
}

# ------------------------------------------------------------------- main --

$root      = Get-Root
$clientDir = Join-Path $root 'client'
$iniPath   = Join-Path $clientDir 'UpdateInstaller.ini'
$logDir    = Join-Path (Join-Path $root 'log') 'remote'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not (Test-Path -LiteralPath $clientDir)) {
    throw "Client tree not found at '$clientDir'. Run UpdateGenerator first."
}
$needCmd = if ($ScanOnly) { 'cmd\ScanOnly.cmd' } else { 'cmd\DoUpdate.cmd' }
if (-not (Test-Path -LiteralPath (Join-Path $clientDir $needCmd))) {
    throw "'$clientDir\$needCmd' not found - is this a complete WSUS Offline tree?"
}
if ($ScanOnly -and -not (Test-Path -LiteralPath (Join-Path $clientDir 'wsus\wsusscn2.cab'))) {
    throw "'$clientDir\wsus\wsusscn2.cab' not found, so there is nothing to scan against. Run a download first."
}

# schtasks /TR takes an unquoted path, and the project already rejects awkward
# characters in medium paths (PathValid() in UpdateInstaller.au3), so refuse a
# staging root that would need quoting rather than fail obscurely on the target.
if ($StagingRoot -match '\s') {
    throw "-StagingRoot must not contain spaces (got '$StagingRoot')."
}
if (-not ($StagingRoot -match '^[A-Za-z]:\')) {
    throw "-StagingRoot must be a local absolute path on the target, e.g. C:\temp (got '$StagingRoot')."
}

$targets = Resolve-TargetList -Names $ComputerName -File $TargetFile
if ($targets.Count -eq 0 -and -not $IncludeLocalHost) {
    throw 'No targets. Pass -ComputerName and/or -TargetFile, or -IncludeLocalHost.'
}

$flags = Get-UpdateFlags -IniPath $iniPath -ClientDir $clientDir -ScanOnly:$ScanOnly

# Optionally shrink the payload using the filter lists CopyToTarget.cmd already
# knows how to apply, rather than reimplementing that here.
$payloadSource = $clientDir
if ($PayloadFilter) {
    if ($ScanOnly) {
        Write-Warning ("-PayloadFilter with -ScanOnly will report every update the filter left out as " +
                       "missing from the download, because that column is computed from what is staged.")
    }
    $payloadSource = Join-Path ([System.IO.Path]::GetTempPath()) "wou-payload-$PayloadFilter"
    Write-Host "Building filtered payload ($PayloadFilter) in $payloadSource ..."
    if ($PSCmdlet.ShouldProcess($payloadSource, "Build filtered payload '$PayloadFilter'")) {
        $copyToTarget = Join-Path $PSScriptRoot 'CopyToTarget.cmd'
        & $env:ComSpec '/D' '/C' $copyToTarget $PayloadFilter $payloadSource
        if ($LASTEXITCODE -ne 0) { throw "CopyToTarget.cmd failed with exit code $LASTEXITCODE." }
    }
}

$payloadBytes = 0
if (Test-Path -LiteralPath $payloadSource) {
    $measured = Get-ChildItem -LiteralPath $payloadSource -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum
    if ($measured) { $payloadBytes = [double]$measured.Sum }
}

Write-Host ''
Write-Host $(if ($ScanOnly) {
    'WSUS Offline Update - remote scan (nothing will be installed)'
} else {
    'WSUS Offline Update - remote deployment'
})
Write-Host ('-' * 74)
Write-Host ("Payload      : {0} ({1:N1} GB)" -f $payloadSource, ($payloadBytes / 1GB))
Write-Host ("Options      : {0}" -f $(if ($flags) { $flags } else { '(none)' }))
Write-Host ("Staging      : {0}\{1} on each target" -f $StagingRoot, $cfg.PayloadDir)
Write-Host ("Targets      : {0}{1}" -f $targets.Count, $(if ($IncludeLocalHost) { ' (plus this machine)' } else { '' }))
Write-Host ("Concurrency  : {0}" -f $Throttle)
Write-Host ("Timeout      : {0} minutes per target" -f $TimeoutMinutes)
Write-Host ("Cleanup      : {0}" -f $(if ($KeepPayload) { 'payload kept on target' } else { 'payload removed afterwards' }))
Write-Host ('-' * 74)
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]

if ($targets.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $logDir)) {
        if ($PSCmdlet.ShouldProcess($logDir, 'Create log directory')) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
    }

    $whatFor = if ($ScanOnly) {
        'Stage payload, list applicable updates as SYSTEM, then remove payload'
    } else {
        'Stage payload, install updates as SYSTEM, then remove payload'
    }
    $queue = New-Object System.Collections.Queue
    foreach ($t in $targets) {
        if ($PSCmdlet.ShouldProcess($t, $whatFor)) { $queue.Enqueue($t) }
    }

    $modulePath = Join-Path $PSScriptRoot 'WsusOfflineRemote.psm1'
    $running    = New-Object System.Collections.Generic.List[object]
    $completed  = 0
    $total      = $queue.Count

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Throttle) {
            $next = $queue.Dequeue()
            Write-Host "[$next] starting"
            $job = Start-Job -Name $next -ScriptBlock $HostWorker -ArgumentList $modulePath, @{
                TargetHost     = $next
                Mode           = $mode
                PayloadSource  = $payloadSource
                StagingRoot    = $StagingRoot
                Flags          = $flags
                TimeoutMinutes = $TimeoutMinutes
                PollSeconds    = $cfg.PollSeconds
                KeepPayload    = [bool]$KeepPayload
                PayloadBytes   = $payloadBytes
                LogDir         = $logDir
                Stamp          = $stamp
                Credential     = $Credential
            }
            $running.Add($job)
        }

        if ($running.Count -eq 0) { break }

        Write-Progress -Activity $verb `
                       -Status "$completed of $total done, $($running.Count) running" `
                       -PercentComplete $(if ($total) { ($completed / $total) * 100 } else { 0 })

        $null = Wait-Job -Job $running.ToArray() -Any -Timeout 30

        # ToArray() rather than @($running): in PowerShell 5.1 the array
        # subexpression on a List[object] holding jobs throws "Argument types do
        # not match". It also gives us a snapshot, so removing from $running
        # inside the loop is safe.
        foreach ($job in $running.ToArray()) {
            if ($job.State -notin 'Completed', 'Failed', 'Stopped') { continue }

            $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
            $res = $out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Status'] } |
                       Select-Object -Last 1
            if (-not $res) {
                $res = [pscustomobject]@{
                    ComputerName = $job.Name; Status = 'Failed'; ExitCode = $null
                    Errors = $null; Duration = $null; Log = $null; Scan = $null
                    Detail = "The job ended without a result ($($job.State))."
                }
            }
            $results.Add($res)
            Write-Host ("[{0}] {1}{2}" -f $res.ComputerName, $res.Status,
                        $(if ($res.Detail) { " - $($res.Detail)" } else { '' }))

            Remove-Job -Job $job -Force
            $null = $running.Remove($job)
            $completed++
        }
    }
    Write-Progress -Activity $verb -Completed
}

# -- this machine, in place ---------------------------------------------------
if ($IncludeLocalHost) {
    $localName = $env:COMPUTERNAME
    $localWhat = if ($ScanOnly) {
        'List applicable updates in place from the repository'
    } else {
        'Install updates in place from the repository'
    }
    if ($PSCmdlet.ShouldProcess($localName, $localWhat)) {
        Write-Host "[$localName] starting (in place, no payload copy)"
        $started  = Get-Date
        $localLog = Join-Path $env:SystemRoot 'wsusofflineupdate.log'
        $preLines = Measure-LogLines $localLog
        $localScan = Join-Path $clientDir $cfg.ScanDir

        # A leftover scan directory would otherwise be read as this run's result.
        if ($ScanOnly -and (Test-Path -LiteralPath $localScan)) {
            Remove-Item -LiteralPath $localScan -Recurse -Force
        }

        # Called with a relative path from -WorkingDirectory rather than by bare
        # name: a host with NoDefaultCurrentDirectoryInExePath set will not
        # resolve the bare name even from the right directory.
        $localCmd = if ($ScanOnly) { '.\ScanOnly.cmd' } else { '.\DoUpdate.cmd' }
        $proc = Start-Process -FilePath $env:ComSpec `
                              -ArgumentList "/D /C $localCmd $flags" `
                              -WorkingDirectory (Join-Path $clientDir 'cmd') `
                              -Wait -PassThru -WindowStyle Hidden
        $exit = $proc.ExitCode

        $res = [pscustomobject]@{
            ComputerName = $localName
            Mode         = $mode
            Status       = Get-StatusFromExitCode -ExitCode $exit -Mode $mode
            ExitCode     = $exit
            Errors       = $null
            Duration     = (Get-Date) - $started
            Log          = $null
            ScanPath     = $null
            Scan         = $null
            Detail       = Get-ExitCodeDetail -ExitCode $exit -Mode $mode
        }

        if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }

        if ($ScanOnly) {
            if (Test-Path -LiteralPath $localScan) {
                $dest = Join-Path $logDir "$localName-$stamp-scan"
                $null = New-Item -ItemType Directory -Path $dest -Force
                Copy-Item -LiteralPath (Join-Path $localScan '*') -Destination $dest -Force
                $res.ScanPath = $dest
                $res.Log      = Join-Path $dest 'scan.log'
                $res.Scan     = Get-ScanResult -Path $dest

                $errors = @(Get-Content -LiteralPath $res.Log -ErrorAction SilentlyContinue |
                                Where-Object { $_ -match '-\s+Error:' })
                $res.Errors = $errors.Count
                if ($res.Status -eq 'Scanned' -and $errors.Count -gt 0) {
                    $res.Status = 'ScannedWithErrors'
                    $res.Detail = ($errors | Select-Object -First 1) -replace '^\s+', ''
                }
            } elseif ($res.Status -eq 'Scanned') {
                $res.Status = 'NoResult'
                $res.Detail = 'ScanOnly.cmd reported success but left no scan directory behind.'
            }
        } else {
            $lines = Get-NewLogLines -LogPath $localLog -SkipLines $preLines
            if ($lines.Count -gt 0) {
                $dest = Join-Path $logDir "$localName-$stamp.log"
                Set-Content -LiteralPath $dest -Value $lines
                $res.Log = $dest
                $errors  = @($lines | Where-Object { $_ -match '-\s+Error:' })
                $res.Errors = $errors.Count
                if ($res.Status -eq 'Complete' -and $errors.Count -gt 0) {
                    $res.Status = 'CompletedWithErrors'
                    $res.Detail = ($errors | Select-Object -First 1) -replace '^\s+', ''
                }
            }
        }
        $results.Add($res)
        Write-Host ("[{0}] {1}" -f $res.ComputerName, $res.Status)
    }
}

# -- report -------------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Host 'Nothing was done.'
    return
}

Write-Host ''
Write-Host ('-' * 74)
$columns = @(
    @{ Label = 'ComputerName'; Expression = { $_.ComputerName } }
    @{ Label = 'Status';       Expression = { $_.Status } }
    @{ Label = 'Exit';         Expression = { if ($null -eq $_.ExitCode) { '-' } else { $_.ExitCode } }; Align = 'Right' }
)
if ($ScanOnly) {
    $columns += @{ Label = 'Needs';   Expression = { if ($_.Scan) { $_.Scan.Applicable }   else { '-' } }; Align = 'Right' }
    $columns += @{ Label = 'Missing'; Expression = { if ($_.Scan) { $_.Scan.NotInPayload } else { '-' } }; Align = 'Right' }
}
$columns += @{ Label = 'Duration'; Expression = { Format-Duration $_.Duration }; Align = 'Right' }
$columns += @{ Label = 'Errors';   Expression = { if ($null -eq $_.Errors) { '-' } else { $_.Errors } }; Align = 'Right' }

$results | Sort-Object ComputerName | Format-Table -AutoSize $columns | Out-Host

# The updates themselves, per host: the point of a scan is this list, and the
# missing ones are what the operator has to act on.
if ($ScanOnly) {
    foreach ($res in ($results | Sort-Object ComputerName)) {
        if (-not $res.Scan -or $res.Scan.Applicable -eq 0) { continue }
        Write-Host ''
        Write-Host ("{0} - {1} applicable, {2} not in the download{3}" -f
                    $res.ComputerName, $res.Scan.Applicable, $res.Scan.NotInPayload,
                    $(if ($res.Scan.Excluded) { ", $($res.Scan.Excluded) excluded by black list" } else { '' }))
        $res.Scan.Updates |
            Sort-Object @{ Expression = { $_.InPayload } }, KB |
            Format-Table -AutoSize @(
                @{ Label = 'KB';       Expression = { $_.KB } }
                @{ Label = 'UpdateId'; Expression = { $_.UpdateId } }
                @{ Label = 'Have';     Expression = { if ($_.InPayload) { 'yes' } else { 'no' } } }
                @{ Label = 'Reason';   Expression = { $_.Reason } }
            ) | Out-Host
    }
    Write-Host ''
    Write-Host 'A scan reflects each machine as it is now. An install pass applies servicing'
    Write-Host 'stack, build upgrade and WUA updates first, which can make further updates'
    Write-Host 'applicable, so expect to scan again after installing.'
}

$summary = Join-Path $logDir "summary-$stamp.csv"
if (Test-Path -LiteralPath $logDir) {
    $csv = $results | Select-Object ComputerName, Mode, Status, ExitCode, Errors,
                          @{ Name = 'Duration';     Expression = { Format-Duration $_.Duration } },
                          @{ Name = 'Applicable';   Expression = { if ($_.Scan) { $_.Scan.Applicable }   else { $null } } },
                          @{ Name = 'NotInPayload'; Expression = { if ($_.Scan) { $_.Scan.NotInPayload } else { $null } } },
                          Log, ScanPath, Detail
    $csv | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8
    Write-Host "Summary : $summary"
    Write-Host "Logs    : $logDir"
}

if (-not $ScanOnly) {
    $needReboot = @($results | Where-Object { $_.Status -in 'RebootRequired', 'RecallRequired' })
    if ($needReboot.Count -gt 0) {
        Write-Host ''
        Write-Host ("{0} host(s) need a restart before the remaining updates can install:" -f $needReboot.Count)
        Write-Host ('  ' + (($needReboot.ComputerName) -join ', '))
        Write-Host '  Reboot them, then run this script again for those hosts.'
    }
}

$ok = if ($ScanOnly) { @('Scanned') } else { @('Complete', 'RebootRequired', 'RecallRequired') }
$notGood = @($results | Where-Object { $_.Status -notin $ok })
if ($notGood.Count -gt 0) {
    Write-Host ''
    Write-Warning ("{0} host(s) did not complete: {1}" -f $notGood.Count, (($notGood.ComputerName) -join ', '))
    exit 1
}
exit 0
