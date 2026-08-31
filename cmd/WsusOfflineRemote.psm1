<#
.SYNOPSIS
    Shared transport and reporting code for the WSUS Offline Update remote
    deployment tools.

.DESCRIPTION
    Invoke-RemoteUpdate.ps1 (command line) and Show-RemoteUpdateGui.ps1 (WPF
    front end) both drive the same three things: an SMB copy of the client tree
    to C:\temp\wsusoffline on a target, a scheduled task running as SYSTEM
    there, and the collection of what came back. That code lives here so there
    is exactly one implementation of it.

    Invoke-HostRun does the whole per-target sequence and is written to be
    callable from inside Start-Job. A job shares nothing with the session that
    started it, so it must Import-Module this file first:

        Start-Job -ScriptBlock {
            param($ModulePath, $HostName, ...)
            Import-Module $ModulePath -Force
            Invoke-HostRun -TargetHost $HostName -Mode Install ...
        } -ArgumentList (Join-Path $PSScriptRoot 'WsusOfflineRemote.psm1'), ...

    Nothing here reboots, shuts down or logs on to a target. Invoke-HostRun
    never emits /autoreboot, /shutdown, /showlog or /monitoron, so the
    WOUTempAdmin autologon account that PrepareRecall.cmd would otherwise create
    is never created. A target that needs a restart is reported as
    RebootRequired or RecallRequired and left alone.

    Remove-WouStaging and Stop-WouRun are the two operations the GUI needs and
    the command line does not: removing a payload that -KeepPayload deliberately
    left behind, and ending a run the operator has cancelled. Stop-WouRun ends
    the scheduled task, not the machine - the promise above still holds.
#>
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# Module-wide constants. Get-WouRemoteConfig hands these to callers that want to
# show them (the CLI banner, the GUI status bar) so the strings are not
# duplicated there.
$script:WouConfig = @{
    InstallTaskName = 'WOUOfflineUpdate'
    ScanTaskName    = 'WOUOfflineScan'
    PayloadDir      = 'wsusoffline'
    WrapperName     = 'RunRemoteUpdate.cmd'
    ResultName      = 'result.txt'
    PollSeconds     = 15
    ScanDir         = 'scan'
}

function Get-WouRemoteConfig {
    <#
        A copy, so a caller cannot reach in and change the module's own values.
    #>
    return $script:WouConfig.Clone()
}

# ---------------------------------------------------------------- helpers --

function Get-Root {
    # This module lives in <root>\cmd, the same place the scripts do, so the
    # parent of $PSScriptRoot is the repository root either way.
    Split-Path -Parent $PSScriptRoot
}

function Read-IniFile {
    # Mirrors the reader in New-DownloadReport.ps1.
    param([string] $File)
    $ini = @{}
    if (-not (Test-Path -LiteralPath $File)) { return $ini }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $File)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1]
            continue
        }
        if ($t -match '^([^=]+)=(.*)$') {
            $ini["$section\$($Matches[1].Trim())"] = $Matches[2].Trim()
        }
    }
    return $ini
}

function Test-IniFlag {
    param([hashtable] $Ini, [string] $Section, [string] $Key, [string] $Default)
    $value = $Ini["$Section\$Key"]
    if ($null -eq $value -or $value -eq '') { $value = $Default }
    return ($value -eq 'Enabled')
}

function Get-UpdateFlags {
    <#
        Builds the DoUpdate.cmd command line from UpdateInstaller.ini using the
        same keys, defaults and order as UpdateInstaller.au3 does when the Start
        button is pressed.

        /autoreboot, /shutdown, /showlog and /monitoron are never emitted - see
        the .DESCRIPTION at the top of this module.

        -ScanOnly narrows the result to the four switches ScanOnly.cmd accepts.
        That is not cosmetic: ScanOnly.cmd rejects install switches with exit
        code 1 rather than ignoring them, so handing it the install flag list
        would fail the scan outright.
    #>
    [CmdletBinding()]
    param(
        [string] $IniPath,
        [string] $ClientDir,
        [switch] $ScanOnly
    )

    $ini = Read-IniFile $IniPath

    $map = @(
        @{ Section = 'Installation'; Key = 'upgradebuilds';    Default = 'Enabled'  }
        @{ Section = 'Installation'; Key = 'updatercerts';     Default = 'Enabled'  }
        @{ Section = 'Installation'; Key = 'instdotnet35';     Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'instdotnet4';      Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'instwmf';          Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'updatedotnet5';    Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'updatecpp';        Default = 'Enabled'  }
        @{ Section = 'Installation'; Key = 'skipieinst';       Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'skipdefs';         Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'skipdynamic';      Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'all';              Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'excludestatics';   Default = 'Disabled' }
        @{ Section = 'Installation'; Key = 'seconly';          Default = 'Disabled' }
        @{ Section = 'Control';      Key = 'verify';           Default = 'Enabled'  }
        @{ Section = 'Messaging';    Key = 'showdismprogress'; Default = 'Disabled' }
    )

    # The listing-relevant subset, matching ScanOnly.cmd's :EvalParams.
    # /ignoreblacklist is accepted there too but has no ini key, so it is only
    # ever passed explicitly.
    $scanKeys = @('all', 'excludestatics', 'seconly', 'verify')

    $flags = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $map) {
        if ($ScanOnly -and $entry.Key -notin $scanKeys) { continue }
        if (-not (Test-IniFlag $ini $entry.Section $entry.Key $entry.Default)) { continue }

        # hashdeep has nothing to check against without the md tree - the same
        # test HashFilesPresent() makes in UpdateInstaller.au3.
        if ($entry.Key -eq 'verify' -and -not (Test-Path -LiteralPath (Join-Path $ClientDir 'md'))) {
            Write-Warning "Dropping /verify: '$ClientDir\md' not found, so there are no hashes to verify against."
            continue
        }
        $flags.Add("/$($entry.Key)")
    }
    return ($flags -join ' ')
}

function Resolve-TargetList {
    [CmdletBinding()]
    param([string[]] $Names, [string] $File)

    $all = New-Object System.Collections.Generic.List[string]
    if ($Names) { foreach ($n in $Names) { if ($n.Trim()) { $all.Add($n.Trim()) } } }
    if ($File) {
        if (-not (Test-Path -LiteralPath $File)) { throw "Target file not found: $File" }
        foreach ($line in (Get-Content -LiteralPath $File)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $all.Add($t)
        }
    }

    # Drop anything naming this machine. The local box is handled by
    # -IncludeLocalHost, which runs in place instead of staging over the admin
    # share (you cannot robocopy a tree over itself).
    $self = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '::1', '.')) { $self.Add($n) }
    try { $self.Add([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName) } catch { }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($name in $all) {
        if ($self -contains $name) {
            Write-Warning "Skipping '$name': that is this machine. Use -IncludeLocalHost to patch it."
            continue
        }
        if ($out -notcontains $name) { $out.Add($name) }
    }
    return $out.ToArray()
}

function Format-Duration {
    param($Span)
    if ($null -eq $Span) { return '-' }
    # [int] rounds, so cast via Floor or 31m12s formats as 01:31:12.
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Get-NewLogLines {
    <#
        DoUpdate.cmd appends to wsusofflineupdate.log rather than replacing it,
        so only the lines added past $SkipLines belong to this run.
    #>
    param([string] $LogPath, [int] $SkipLines)
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    return @(Get-Content -LiteralPath $LogPath | Select-Object -Skip $SkipLines)
}

function Measure-LogLines {
    param([string] $LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { return 0 }
    return (Get-Content -LiteralPath $LogPath | Measure-Object -Line).Lines
}

function Get-StatusFromExitCode {
    <#
        Install mode follows the contract at the end of DoUpdate.cmd: 3011 means
        another pass is needed after a reboot, 3010 means a reboot is pending,
        anything non-zero is a failure.

        Scan mode follows ScanOnly.cmd's own codes, which are deliberately small
        and specific so a caller can say why rather than just "failed".
    #>
    param(
        $ExitCode,
        [ValidateSet('Install', 'Scan')]
        [string] $Mode = 'Install'
    )
    if ($null -eq $ExitCode) { return 'Timeout' }

    if ($Mode -eq 'Scan') {
        switch ([int]$ExitCode) {
            0       { return 'Scanned' }
            2       { return 'NotAdmin' }
            3       { return 'Unsupported' }
            4       { return 'NoCatalog' }
            default { return 'Failed' }
        }
    }

    switch ([int]$ExitCode) {
        0       { return 'Complete' }
        3010    { return 'RebootRequired' }
        3011    { return 'RecallRequired' }
        default { return 'Failed' }
    }
}

function Get-ExitCodeDetail {
    <#
        The human-readable half of Get-StatusFromExitCode, kept separate so the
        status vocabulary stays machine-readable.
    #>
    param(
        $ExitCode,
        [ValidateSet('Install', 'Scan')]
        [string] $Mode = 'Install'
    )
    if ($null -eq $ExitCode) { return $null }

    if ($Mode -eq 'Scan') {
        switch ([int]$ExitCode) {
            0       { return $null }
            1       { return 'ScanOnly.cmd reported an error; see the collected scan log.' }
            2       { return 'The task did not run with administrative privileges.' }
            3       { return 'Unsupported operating system, architecture or language.' }
            4       { return 'The payload has no wsus\wsusscn2.cab, so there was nothing to scan against.' }
            5       { return 'The target has no usable TEMP directory.' }
            default { return "ScanOnly.cmd exited $ExitCode." }
        }
    }

    if ([int]$ExitCode -notin 0, 3010, 3011) { return "DoUpdate.cmd exited $ExitCode." }
    return $null
}

function Test-WouAdminShare {
    # Private. Answers "could we read this admin share, and if not, why".
    #
    # Test-Path returns $false for "the firewall dropped us", "that machine is
    # switched off" and "your password is wrong" alike - three failures with
    # three completely different fixes, which is the whole point of a preflight.
    # .NET keeps the underlying Win32 code in the exception's HResult, and for a
    # code in the 0x8007xxxx range the low word is that Win32 error. That is
    # locale-independent, unlike the message text, which matters for a project
    # that ships to German-language sites.
    param([string] $Path)

    $out = [pscustomobject]@{ Ok = $false; Win32 = 0; Message = '' }
    try {
        [void] [System.IO.Directory]::GetDirectories($Path)
        $out.Ok = $true
    } catch {
        # PowerShell wraps a .NET method call's exception in a
        # MethodInvocationException, so unwrap to the real one first.
        $ex = $_.Exception
        while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
        $out.Message = "$($ex.Message)".Trim()
        # 0xFFFF0000 and 0x80070000 as signed Int32, which is how .NET stores
        # HResult. Anything outside that facility gets -1 rather than a number
        # masked out of an unrelated bit pattern.
        $out.Win32 = if (($ex.HResult -band -65536) -eq -2147024896) {
            $ex.HResult -band 0xFFFF
        } else {
            -1
        }
    }
    return $out
}

function Test-WouTarget {
    <#
    .SYNOPSIS
        Answers "is this machine online, connectable, and free to work on".

    .DESCRIPTION
        This is the preflight Invoke-HostRun performs, promoted to a first-class
        call because the GUI's reachability columns are exactly this answer. It
        is read-only: nothing is created, copied or started on the target.

        The admin share is tested before ICMP on purpose - plenty of hardened
        hosts drop ping while SMB still answers, so pinging first would write
        them off wrongly. ICMP is only consulted to tell "switched off" apart
        from "up, but the admin share is unavailable".

        WMI/DCOM is often blocked where SMB works, so FreeGB, OsCaption and
        LastBootUpTime are advisory: they come back $null rather than failing
        the host.

        A failed admin-share test reports the Win32 error behind it in
        AdminShareError, and Note names the fix that error implies - a refused
        logon, a firewall that is dropping TCP 445 and a machine that is switched
        off are three different problems and must not read alike.

        Busy means "no running WSUS Offline task was found", not "the machine is
        idle" - the scheduled-task query can fail on a host that is otherwise
        perfectly connectable. Note carries the reason the host is not usable
        and nothing else, so a populated Note always means reachability or WMI.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $ComputerName,
        [string] $StagingRoot = 'C:\temp',
        $Credential
    )

    $qualifier = Split-Path -Path $StagingRoot -Qualifier
    $share     = $qualifier.TrimEnd(':') + '$'

    $info = [pscustomobject]@{
        ComputerName   = $ComputerName
        Reachable      = $false
        AdminShare     = $false
        AdminShareError = 0
        FreeGB         = $null
        OsCaption      = $null
        LastBootUpTime = $null
        Busy           = $false
        BusyTask       = $null
        Note           = $null
        CheckedAt      = Get-Date
    }

    if ($null -ne $Credential -and $Credential -isnot [System.Management.Automation.PSCredential]) {
        $Credential = New-Object System.Management.Automation.PSCredential(
            $Credential.UserName, $Credential.Password)
    }

    $mapped = $false
    try {
        if ($null -ne $Credential) {
            $null = & net.exe use "\\$ComputerName\$share" /user:$($Credential.UserName) `
                        $($Credential.GetNetworkCredential().Password) 2>&1
            if ($LASTEXITCODE -eq 0) { $mapped = $true }
        }

        $probe = Test-WouAdminShare "\\$ComputerName\$share"
        $info.AdminShare      = $probe.Ok
        $info.AdminShareError = $probe.Win32
        if ($info.AdminShare) {
            $info.Reachable = $true
        } else {
            try { $info.Reachable = Test-Connection -ComputerName $ComputerName -Count 2 -Quiet } catch { }

            # Name the fix, not just the symptom. Saying "check the admin share
            # and the firewall" to someone whose firewall is open and whose
            # password is wrong costs them the afternoon.
            $info.Note = switch ($probe.Win32) {
                # ACCESS_DENIED, INVALID_PASSWORD, LOGON_FAILURE,
                # ACCOUNT_RESTRICTION, ACCOUNT_DISABLED, LOGON_TYPE_NOT_GRANTED.
                { $_ -in 5, 86, 1326, 1327, 1331, 1385 } {
                    "\\$ComputerName\$share answered but refused the logon (error $_). Pass -Credential naming a local administrator of that machine. A workgroup target also needs LocalAccountTokenFilterPolicy=1, or its admin share hands back a filtered token."
                }
                # SESSION_CREDENTIAL_CONFLICT: Windows allows one identity per
                # server at a time, so an earlier connection wins over -Credential.
                { $_ -eq 1219 } {
                    "\\$ComputerName\$share is already connected as a different user (error 1219). Drop the existing session with: net use \\$ComputerName\$share /delete"
                }
                # BAD_NETPATH, NETNAME_DELETED, BAD_NET_NAME, NETWORK_UNREACHABLE.
                { $_ -in 53, 64, 67, 1231 } {
                    if ($info.Reachable) {
                        "Answers ping, but \\$ComputerName\$share did not answer (error $_). Allow File and Printer Sharing (TCP 445) through its firewall."
                    } else {
                        "No response from $ComputerName."
                    }
                }
                default {
                    if ($info.Reachable) {
                        "Answers ping, but \\$ComputerName\$share is not reachable (error $($probe.Win32)): $($probe.Message)"
                    } else {
                        "No response from $ComputerName."
                    }
                }
            }
            return $info
        }

        try {
            $cimCommon = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
            if ($null -ne $Credential) { $cimCommon.Credential = $Credential }

            $disk = Get-CimInstance @cimCommon -ClassName Win32_LogicalDisk -Filter "DeviceID='$qualifier'"
            if ($disk) { $info.FreeGB = [Math]::Round($disk.FreeSpace / 1GB, 1) }

            $os = Get-CimInstance @cimCommon -ClassName Win32_OperatingSystem
            if ($os) {
                $info.OsCaption      = ($os.Caption -replace '^Microsoft\s+', '').Trim()
                $info.LastBootUpTime = $os.LastBootUpTime
            }
        } catch {
            $info.Note = "Connected, but WMI is unavailable: $($_.Exception.Message)"
        }

        # Two operators, or an earlier run, may still be working here. This sits
        # in its own try/catch because it must not be able to reach $info.Note:
        # a task query that fails says nothing about whether the host is
        # connectable, and reporting "Access is denied" against a machine whose
        # admin share we just read would send the operator hunting the wrong
        # problem. A query we cannot complete leaves Busy $false, which is what
        # the field claims - no running task was found - and the run itself will
        # report the real permission error from /Create, where it belongs.
        try {
            $credArgs = @()
            if ($null -ne $Credential) {
                $credArgs = @('/U', $Credential.UserName, '/P', $Credential.GetNetworkCredential().Password)
            }
            foreach ($task in @($script:WouConfig.InstallTaskName, $script:WouConfig.ScanTaskName)) {
                # An array passed as a single argument would reach schtasks as one
                # space-joined string, so it goes through the same splatting helper
                # the worker uses.
                $state = Invoke-WouSchTasks (@('/S', $ComputerName) + $credArgs +
                                             @('/Query', '/TN', $task, '/FO', 'CSV', '/NH'))
                if ($state.Code -eq 0 -and $state.Output -match 'Running') {
                    $info.Busy     = $true
                    $info.BusyTask = $task
                    break
                }
            }
        } catch { }
    } catch {
        $info.Note = $_.Exception.Message
    } finally {
        try { if ($mapped) { $null = & net.exe use "\\$ComputerName\$share" /delete /y 2>&1 } } catch { }
    }

    return $info
}

function Get-ScanResult {
    <#
    .SYNOPSIS
        Parses a scan directory collected from a target into update objects.

    .DESCRIPTION
        Reads the four files ScanOnly.cmd leaves in the payload's scan\
        directory:

            MissingUpdateIds.txt  one "kbId,UpdateGUID" line per update the
                                  Windows Update Agent found applicable
            UpdatesToInstall.txt  the payload files that would be installed
            scan.log              progress, plus the two lines that matter here
            scanresult.txt        ScanOnly.cmd's exit code

        InPayload is taken from the log rather than guessed, because
        ListUpdatesToInstall.cmd already answers the question: it writes
        "Warning: Update kbNNNNNNN (id: {...}) not found" for a KB it could find
        no file for at all. Note the distinct "Warning: Update file <name> ..."
        line, which is only one candidate location missing and is NOT the same
        claim - a later language directory often satisfies it - so those lines
        are collected separately and never set InPayload to false.

        File is best effort. UpdatesToInstall.txt is a flat list of paths with no
        KB column, so a file is attributed to a KB when its name contains the KB
        number - which is how ListUpdateFile.cmd searched for it in the first
        place. Updates resolved through UpdateTable\*.csv are named after the
        file rather than the KB, so File can be $null for an update that really
        is present; InPayload is the reliable field, File is a convenience.

    .PARAMETER Path
        The collected scan directory.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $summary = [pscustomobject]@{
        Path         = $Path
        ExitCode     = $null
        ScannedAt    = $null
        Applicable   = 0
        NotInPayload = 0
        Excluded     = 0
        Updates      = @()
        PayloadFiles = @()
        Warnings     = @()
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $summary }

    $resultFile = Join-Path $Path 'scanresult.txt'
    if (Test-Path -LiteralPath $resultFile) {
        $raw = (Get-Content -LiteralPath $resultFile -Raw).Trim()
        if ($raw -match '^-?\d+$') { $summary.ExitCode = [int]$raw }
        $summary.ScannedAt = (Get-Item -LiteralPath $resultFile).LastWriteTime
    }

    $payloadFiles = @()
    $updatesFile  = Join-Path $Path 'UpdatesToInstall.txt'
    if (Test-Path -LiteralPath $updatesFile) {
        $payloadFiles = @(Get-Content -LiteralPath $updatesFile |
                            ForEach-Object { $_.Trim() } |
                            Where-Object { $_ -ne '' })
    }
    $summary.PayloadFiles = $payloadFiles

    # -- what the log says ----------------------------------------------------
    $notFound     = @{}   # normalised kb -> $true, the authoritative misses
    $fileWarnings = New-Object System.Collections.Generic.List[string]
    $excluded     = @{}   # normalised kb -> reason
    $logFile      = Join-Path $Path 'scan.log'
    if (Test-Path -LiteralPath $logFile) {
        foreach ($line in (Get-Content -LiteralPath $logFile)) {
            if ($line -match '-\s+Warning:\s+Update\s+file\s+(?<name>.+?)\s+not found\s*$') {
                $fileWarnings.Add($Matches['name'])
                continue
            }
            if ($line -match '-\s+Warning:\s+Update\s+(?<name>\S+?)(?:\s+\(id:\s*(?<id>[^)]*)\))?\s+not found\s*$') {
                $notFound[($Matches['name'] -replace '^kb', '').ToLowerInvariant()] = $true
                continue
            }
            if ($line -match '-\s+Info:\s+Skipped update\s+(?<kb>\S+?)(?:\s+\((?<why>[^)]*)\))?\s+due to matching black list entry\s*$') {
                $key = ($Matches['kb'] -replace '^kb', '').ToLowerInvariant()
                $excluded[$key] = if ($Matches['why']) { $Matches['why'] } else { 'black list' }
            }
        }
    }
    $summary.Warnings = $fileWarnings.ToArray()

    # -- one object per applicable update -------------------------------------
    $updates = New-Object System.Collections.Generic.List[object]
    $idsFile = Join-Path $Path 'MissingUpdateIds.txt'
    if (Test-Path -LiteralPath $idsFile) {
        foreach ($line in (Get-Content -LiteralPath $idsFile)) {
            $t = $line.Trim()
            if ($t -eq '') { continue }
            $parts = $t.Split(',')
            $kbRaw = $parts[0].Trim()
            if ($kbRaw -eq '') { continue }
            $key   = ($kbRaw -replace '^kb', '').ToLowerInvariant()

            $isExcluded = $excluded.ContainsKey($key)
            $inPayload  = -not ($notFound.ContainsKey($key) -or $isExcluded)

            # Best effort, as described above.
            $file = $null
            if ($inPayload -and $key -match '^\d+$') {
                $file = @($payloadFiles | Where-Object { $_ -like "*$key*" }) -join '; '
                if ($file -eq '') { $file = $null }
            }

            $updates.Add([pscustomobject]@{
                KB        = if ($kbRaw -match '^\d') { "kb$kbRaw" } else { $kbRaw }
                UpdateId  = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }
                InPayload = $inPayload
                File      = $file
                Excluded  = $isExcluded
                Reason    = if ($isExcluded) { $excluded[$key] } elseif (-not $inPayload) { 'not downloaded' } else { $null }
            })
        }
    }

    $summary.Updates      = $updates.ToArray()
    $summary.Applicable   = $updates.Count
    $summary.NotInPayload = @($updates | Where-Object { -not $_.InPayload -and -not $_.Excluded }).Count
    $summary.Excluded     = @($updates | Where-Object { $_.Excluded }).Count
    return $summary
}

# ------------------------------------------------------------ host worker --

function Invoke-WouSchTasks {
    # Private. Runs schtasks.exe and hands back its exit code and its text. It
    # never throws: every caller is a state check that has to be able to say
    # "no" without unwinding the run around it.
    #
    # schtasks writes its diagnostics to stderr, so 2>&1 is needed to report why
    # a call failed. Under PowerShell 5.1 that redirection wraps each stderr
    # line in an ErrorRecord, which this module's $ErrorActionPreference = Stop
    # turns into a terminating error. That is not an edge case: schtasks reports
    # "the task does not exist" on stderr with exit code 1, which is the
    # ordinary answer on a host that has never been run against, so the throw
    # fired on the happy path. The preference is therefore relaxed for the
    # length of the call, and the records are unwrapped back into plain text -
    # an ErrorRecord whose message is empty stringifies to its own type name,
    # which would otherwise leak "System.Management.Automation.RemoteException"
    # into an operator-facing Detail column.
    param([string[]] $Arguments)

    $ErrorActionPreference = 'Continue'
    $raw  = & schtasks.exe @Arguments 2>&1
    $code = $LASTEXITCODE

    $lines = foreach ($item in $raw) {
        $line = if ($item -is [System.Management.Automation.ErrorRecord]) {
            $item.Exception.Message
        } else {
            [string] $item
        }
        if ($line -and $line.Trim()) { $line.Trim() }
    }

    return [pscustomobject]@{
        Code   = $code
        Output = (@($lines) -join [Environment]::NewLine)
    }
}

function Invoke-HostRun {
    <#
    .SYNOPSIS
        Stages the payload on one target, runs it as SYSTEM, collects the
        results and cleans up.

    .DESCRIPTION
        The whole per-target sequence, for one host, in one call. Designed to run
        inside Start-Job; see the module .DESCRIPTION for the Import-Module
        pattern a job needs.

        -Mode Install runs cmd\DoUpdate.cmd and collects the delta of
        %SystemRoot%\wsusofflineupdate.log. -Mode Scan runs cmd\ScanOnly.cmd and
        collects the payload's scan\ directory instead, which installs nothing.
        Everything else - authentication, preflight, staging, robocopy, the
        wrapper, the scheduled task, the timeout and the cleanup rules - is
        shared, so the two modes cannot drift apart.

        Both modes stage into the same <StagingRoot>\wsusoffline, so with
        -KeepPayload a scan followed by an install is one transfer: the install's
        robocopy /MIR finds the tree already there.

    .PARAMETER Mode
        Install (default) or Scan.

    .PARAMETER PayloadSource
        Local directory to mirror to the target - normally <root>\client.

    .PARAMETER KeepPayload
        Leave the staged payload behind. Faster repeat runs, at the cost of
        several gigabytes per target until Clean up is run.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $TargetHost,

        [ValidateSet('Install', 'Scan')]
        [string] $Mode = 'Install',

        [Parameter(Mandatory)]
        [string] $PayloadSource,

        [string] $StagingRoot = 'C:\temp',
        [string] $Flags = '',
        [int]    $TimeoutMinutes = 180,
        [int]    $PollSeconds = 15,
        [bool]   $KeepPayload = $false,
        [double] $PayloadBytes = 0,

        [Parameter(Mandatory)]
        [string] $LogDir,

        [Parameter(Mandatory)]
        [string] $Stamp,

        $Credential
    )

    $ErrorActionPreference = 'Stop'
    $started = Get-Date

    $cfg        = $script:WouConfig
    $isScan     = ($Mode -eq 'Scan')
    $taskName   = if ($isScan) { $cfg.ScanTaskName } else { $cfg.InstallTaskName }
    $targetCmd  = if ($isScan) { 'cmd\ScanOnly.cmd' } else { 'cmd\DoUpdate.cmd' }
    $safeName   = $TargetHost -replace '[^\w\.\-]', '_'

    $result = [pscustomobject]@{
        ComputerName = $TargetHost
        Mode         = $Mode
        Status       = 'Failed'
        ExitCode     = $null
        Errors       = $null
        Duration     = $null
        Log          = $null
        ScanPath     = $null
        Scan         = $null
        Detail       = $null
    }

    # Start-Job serialisation can hand back a PSCredential as a plain object.
    if ($null -ne $Credential -and $Credential -isnot [System.Management.Automation.PSCredential]) {
        $Credential = New-Object System.Management.Automation.PSCredential(
            $Credential.UserName, $Credential.Password)
    }

    # Build the UNC equivalents of the target-local staging paths. Splitting off
    # the qualifier keeps a nested -StagingRoot such as D:\build\temp working.
    $qualifier   = Split-Path -Path $StagingRoot -Qualifier
    $relative    = $StagingRoot.Substring($qualifier.Length).TrimStart('\')
    $share       = $qualifier.TrimEnd(':') + '$'
    $uncRoot     = "\\$TargetHost\$share\$relative"
    $uncPayload  = Join-Path $uncRoot $cfg.PayloadDir
    $uncScanDir  = Join-Path $uncPayload $cfg.ScanDir
    # ADMIN$ maps to %SystemRoot%, so this finds the log even when Windows is
    # not on the same drive as the staging root.
    $uncUpdateLog = "\\$TargetHost\ADMIN`$\wsusofflineupdate.log"

    $localPayload = Join-Path $StagingRoot $cfg.PayloadDir
    $localWrapper = Join-Path $localPayload $cfg.WrapperName

    $credArgs = @()
    if ($null -ne $Credential) {
        $credArgs = @('/U', $Credential.UserName, '/P', $Credential.GetNetworkCredential().Password)
    }

    $mapped      = $false
    $createdRoot = $false
    $taskCreated = $false
    $preLines    = 0

    # do/while($false) so every exit path is a break: the result object must be
    # emitted after the finally has run, otherwise Start-Job serialises it before
    # Duration and any cleanup note are recorded and they are silently lost.
    do {
        try {
            # -- authenticate --------------------------------------------------
            if ($null -ne $Credential) {
                $netOut = & net.exe use "\\$TargetHost\$share" /user:$($Credential.UserName) `
                              $($Credential.GetNetworkCredential().Password) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $result.Status = 'AuthFailed'
                    $result.Detail = ($netOut -join ' ').Trim()
                    break
                }
                $mapped = $true
            }

            # -- preflight -----------------------------------------------------
            # SMB is tested before ICMP, because plenty of hardened hosts drop
            # ping while the admin share still answers.
            if (-not (Test-Path -LiteralPath "\\$TargetHost\$share")) {
                $reachable = $false
                try { $reachable = Test-Connection -ComputerName $TargetHost -Count 2 -Quiet } catch { }
                if ($reachable) {
                    $result.Status = 'NoAdminShare'
                    $result.Detail = "\\$TargetHost\$share is not reachable; check the admin share and the firewall."
                } else {
                    $result.Status = 'Unreachable'
                    $result.Detail = "No response from $TargetHost."
                }
                break
            }

            # Advisory only: WMI/DCOM is often blocked even where SMB works, and
            # a missing free-space reading is not a reason to skip a host.
            try {
                $cimArgs = @{ ComputerName = $TargetHost
                              ClassName    = 'Win32_LogicalDisk'
                              Filter       = "DeviceID='$qualifier'" }
                if ($null -ne $Credential) { $cimArgs.Credential = $Credential }
                $disk = Get-CimInstance @cimArgs -ErrorAction Stop
                if ($disk -and $disk.FreeSpace -gt 0 -and $disk.FreeSpace -lt ($PayloadBytes * 1.1)) {
                    $result.Status = 'InsufficientSpace'
                    $result.Detail = ('Needs about {0:N1} GB on {1}, only {2:N1} GB free.' -f
                                      ($PayloadBytes / 1GB), $qualifier, ($disk.FreeSpace / 1GB))
                    break
                }
            } catch {
                Write-Verbose "Free-space check skipped for ${TargetHost}: $($_.Exception.Message)"
            }

            # Guard against two operators, or an earlier run, still working here.
            # Both task names are checked: a scan must not start on top of an
            # install, nor the other way round, because they share the payload.
            foreach ($other in @($cfg.InstallTaskName, $cfg.ScanTaskName)) {
                $query = Invoke-WouSchTasks (@('/S', $TargetHost) + $credArgs +
                                             @('/Query', '/TN', $other, '/FO', 'CSV', '/NH'))
                if ($query.Code -eq 0 -and $query.Output -match 'Running') {
                    $result.Status = 'AlreadyRunning'
                    $result.Detail = "Scheduled task '$other' is already running on this host."
                    break
                }
            }
            if ($result.Status -eq 'AlreadyRunning') { break }

            # -- stage ---------------------------------------------------------
            # Remember whether the staging root was ours to create; that is the
            # only thing that entitles us to delete it again at the end.
            $createdRoot = -not (Test-Path -LiteralPath $uncRoot)
            $null = New-Item -ItemType Directory -Path $uncPayload -Force

            $preLines = 0
            if (-not $isScan -and (Test-Path -LiteralPath $uncUpdateLog)) {
                $preLines = (Get-Content -LiteralPath $uncUpdateLog | Measure-Object -Line).Lines
            }

            # -- copy ----------------------------------------------------------
            # /MIR also clears any result.txt, wrapper and scan\ directory left
            # by an earlier run, since none of them exist in the source tree.
            # That is what keeps a stale scan from being read as a fresh one.
            $roboOut = & robocopy.exe $PayloadSource $uncPayload /MIR /XJ /R:2 /W:5 /MT:16 /NFL /NDL /NP /NJH 2>&1
            $roboCode = $LASTEXITCODE
            # robocopy packs its result into bits; 0-7 are success, 8 and up are not.
            if ($roboCode -ge 8) {
                $result.Status = 'CopyFailed'
                $result.Detail = "robocopy exited $roboCode. " + (($roboOut | Select-Object -Last 6) -join ' ')
                break
            }

            # -- wrapper -------------------------------------------------------
            # Written after the copy so /MIR cannot delete it. It exists because
            # schtasks /TR is limited to about 261 characters (the flag list can
            # be longer), and because polling for a file the wrapper writes is
            # far more reliable than polling the task's LastTaskResult.
            # Built as an array so Set-Content joins the lines with CRLF; cmd.exe
            # is not reliable on LF-only batch files.
            #
            # The target script is called by full path on purpose: a scheduled
            # task starts in system32, and a host with
            # NoDefaultCurrentDirectoryInExePath set will not resolve a bare
            # "DoUpdate.cmd" even from the right directory. No cd is needed -
            # both DoUpdate.cmd and ScanOnly.cmd do cd /D "%~dp0" themselves.
            $wrapper = @(
                '@echo off'
                'rem *** Generated by cmd\WsusOfflineRemote.psm1 - do not edit. ***'
                'setlocal'
                "call `"%~dp0$targetCmd`" $Flags"
                'set RC=%errorlevel%'
                "> `"%~dp0$($cfg.ResultName)`" echo %RC%"
                'endlocal'
            )
            Set-Content -LiteralPath (Join-Path $uncPayload $cfg.WrapperName) -Value $wrapper -Encoding Ascii
            Remove-Item -LiteralPath (Join-Path $uncPayload $cfg.ResultName) -Force -ErrorAction SilentlyContinue

            # -- run -----------------------------------------------------------
            $create = Invoke-WouSchTasks (@('/S', $TargetHost) + $credArgs +
                                          @('/Create', '/TN', $taskName, '/RU', 'SYSTEM', '/RL', 'HIGHEST',
                                            '/SC', 'ONCE', '/ST', '23:59', '/TR', $localWrapper, '/F'))
            if ($create.Code -ne 0) {
                $result.Status = 'TaskCreateFailed'
                $result.Detail = $create.Output
                break
            }
            $taskCreated = $true

            $run = Invoke-WouSchTasks (@('/S', $TargetHost) + $credArgs + @('/Run', '/TN', $taskName))
            if ($run.Code -ne 0) {
                $result.Status = 'TaskRunFailed'
                $result.Detail = $run.Output
                break
            }

            # -- wait ----------------------------------------------------------
            $resultFile = Join-Path $uncPayload $cfg.ResultName
            $deadline   = (Get-Date).AddMinutes($TimeoutMinutes)
            $exitCode   = $null
            # A task reports Ready both before it has spun up and after it has
            # gone. Requiring three consecutive Ready readings avoids mistaking
            # the former for the latter.
            $readyStrikes = 0

            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds $PollSeconds

                if (Test-Path -LiteralPath $resultFile) {
                    $raw = (Get-Content -LiteralPath $resultFile -Raw).Trim()
                    if ($raw -match '^-?\d+$') { $exitCode = [int]$raw; break }
                }

                $state = Invoke-WouSchTasks (@('/S', $TargetHost) + $credArgs +
                                             @('/Query', '/TN', $taskName, '/FO', 'CSV', '/NH'))
                if ($state.Code -ne 0 -or $state.Output -notmatch 'Running') {
                    $readyStrikes++
                    if ($readyStrikes -ge 3) { break }
                } else {
                    $readyStrikes = 0
                }
            }

            # One last look: the task may have finished during the final sleep.
            if ($null -eq $exitCode -and (Test-Path -LiteralPath $resultFile)) {
                $raw = (Get-Content -LiteralPath $resultFile -Raw).Trim()
                if ($raw -match '^-?\d+$') { $exitCode = [int]$raw }
            }

            $result.ExitCode = $exitCode
            if ($null -eq $exitCode) {
                $result.Status = if ((Get-Date) -ge $deadline) { 'Timeout' } else { 'NoResult' }
                $result.Detail = if ($result.Status -eq 'Timeout') {
                    "Gave up after $TimeoutMinutes minutes."
                } else {
                    'The task stopped without writing a result; see the collected log.'
                }
            } else {
                $result.Status = Get-StatusFromExitCode -ExitCode $exitCode -Mode $Mode
                $result.Detail = Get-ExitCodeDetail    -ExitCode $exitCode -Mode $Mode
            }

            # -- collect -------------------------------------------------------
            if ($isScan) {
                # The whole scan\ directory comes back, not a delta: ScanOnly.cmd
                # writes a fresh scan.log each run and /MIR removed the previous
                # one, so everything present belongs to this run.
                if (Test-Path -LiteralPath $uncScanDir) {
                    $dest = Join-Path $LogDir "$safeName-$Stamp-scan"
                    $null = New-Item -ItemType Directory -Path $dest -Force
                    Copy-Item -LiteralPath $uncScanDir -Destination $dest -Recurse -Force `
                              -Container:$false -ErrorAction SilentlyContinue
                    foreach ($f in @('MissingUpdateIds.txt', 'UpdatesToInstall.txt', 'scan.log', 'scanresult.txt')) {
                        $src = Join-Path $uncScanDir $f
                        if (Test-Path -LiteralPath $src) {
                            Copy-Item -LiteralPath $src -Destination (Join-Path $dest $f) -Force
                        }
                    }
                    $result.ScanPath = $dest
                    $result.Log      = Join-Path $dest 'scan.log'
                    $scan            = Get-ScanResult -Path $dest
                    $result.Scan     = $scan

                    # Warning: lines are normal in a scan - they are how a
                    # missing download is reported - so only Error: lines count.
                    $errors = @(Get-Content -LiteralPath $result.Log -ErrorAction SilentlyContinue |
                                    Where-Object { $_ -match '-\s+Error:' })
                    $result.Errors = $errors.Count
                    if ($result.Status -eq 'Scanned' -and $errors.Count -gt 0) {
                        $result.Status = 'ScannedWithErrors'
                        $result.Detail = ($errors | Select-Object -First 1) -replace '^\s+', ''
                    }
                } elseif ($result.Status -eq 'Scanned') {
                    $result.Status = 'NoResult'
                    $result.Detail = 'ScanOnly.cmd reported success but left no scan directory behind.'
                }
            } elseif (Test-Path -LiteralPath $uncUpdateLog) {
                $dest  = Join-Path $LogDir "$safeName-$Stamp.log"
                $lines = @(Get-Content -LiteralPath $uncUpdateLog | Select-Object -Skip $preLines)
                Set-Content -LiteralPath $dest -Value $lines
                $result.Log = $dest

                # DoUpdate.cmd sets ERROR_OCCURRED on failure but never reads it,
                # so it exits 0 even when an install failed. The log is the only
                # place the failure actually shows up.
                $errors = @($lines | Where-Object { $_ -match '-\s+Error:' })
                $result.Errors = $errors.Count
                if ($result.Status -eq 'Complete' -and $errors.Count -gt 0) {
                    $result.Status = 'CompletedWithErrors'
                    $result.Detail = ($errors | Select-Object -First 1) -replace '^\s+', ''
                }
            }

            break
        } catch {
            $result.Status = 'Failed'
            $result.Detail = $_.Exception.Message
        } finally {
            # Cleanup runs even when the run failed - leaving a multi-gigabyte
            # payload and a scheduled task behind on a fleet is worse than the
            # original error.
            try {
                if ($taskCreated) {
                    $null = Invoke-WouSchTasks (@('/S', $TargetHost) + $credArgs +
                                                @('/Delete', '/TN', $taskName, '/F'))
                }
            } catch { }

            try {
                if (-not $KeepPayload -and (Test-Path -LiteralPath $uncPayload)) {
                    Remove-Item -LiteralPath $uncPayload -Recurse -Force -ErrorAction Stop
                } elseif ($KeepPayload -and $isScan -and (Test-Path -LiteralPath $uncScanDir)) {
                    # The results are collected by now, and leaving them on the
                    # target would only invite a later run to read them as fresh.
                    Remove-Item -LiteralPath $uncScanDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                # Only remove the staging root if we made it and left it empty; a
                # pre-existing C:\temp with the operator's files stays untouched.
                if (-not $KeepPayload -and $createdRoot -and (Test-Path -LiteralPath $uncRoot)) {
                    if (-not (Get-ChildItem -LiteralPath $uncRoot -Force)) {
                        Remove-Item -LiteralPath $uncRoot -Force -ErrorAction Stop
                    }
                }
            } catch {
                $note = "Cleanup failed: $($_.Exception.Message)"
                $result.Detail = if ($result.Detail) { "$($result.Detail) $note" } else { $note }
            }

            try {
                if ($mapped) { $null = & net.exe use "\\$TargetHost\$share" /delete /y 2>&1 }
            } catch { }
        }
    } while ($false)

    $result.Duration = (Get-Date) - $started
    $result
}

# ----------------------------------------------------------------- cleanup --

function Remove-WouStaging {
    <#
    .SYNOPSIS
        Removes a staged payload and any leftover scheduled task from one target.

    .DESCRIPTION
        The counterpart to -KeepPayload: what that leaves behind, this takes
        away. Several gigabytes per target is not something to forget about, so
        the GUI offers it as a button and this is the implementation behind it.

        The staging root itself is never removed here, only <root>\wsusoffline
        inside it. Invoke-HostRun may remove the root because it knows whether it
        created it; called on its own, this function does not, and deleting an
        operator's C:\temp on that guess would be worse than leaving an empty
        directory behind.

        Both task names are deleted if present, but a task that is still running
        is left alone and reported instead - ending an installation halfway
        through is how a machine reaches a state nobody can explain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ComputerName,

        [string] $StagingRoot = 'C:\temp',
        $Credential
    )

    $cfg    = $script:WouConfig
    $result = [pscustomobject]@{
        ComputerName = $ComputerName
        Status       = 'Failed'
        Removed      = $false
        TasksDeleted = 0
        Detail       = $null
    }

    if ($null -ne $Credential -and $Credential -isnot [System.Management.Automation.PSCredential]) {
        $Credential = New-Object System.Management.Automation.PSCredential(
            $Credential.UserName, $Credential.Password)
    }

    $qualifier  = Split-Path -Path $StagingRoot -Qualifier
    $relative   = $StagingRoot.Substring($qualifier.Length).TrimStart('\')
    $share      = $qualifier.TrimEnd(':') + '$'
    $uncShare   = "\\$ComputerName\$share"
    $uncPayload = Join-Path (Join-Path $uncShare $relative) $cfg.PayloadDir

    $credArgs = @()
    $plain    = $null
    if ($null -ne $Credential) {
        $plain    = $Credential.GetNetworkCredential().Password
        $credArgs = @('/U', $Credential.UserName, '/P', $plain)
    }

    $mapped = $false
    try {
        if ($null -ne $Credential) {
            $null = & net.exe use $uncShare /user:$($Credential.UserName) $plain 2>&1
            if ($LASTEXITCODE -eq 0) { $mapped = $true }
        }

        if (-not (Test-Path -LiteralPath $uncShare)) {
            $result.Status = 'Unreachable'
            $result.Detail = "$uncShare is not reachable."
            return $result
        }

        foreach ($task in @($cfg.InstallTaskName, $cfg.ScanTaskName)) {
            $state = Invoke-WouSchTasks (@('/S', $ComputerName) + $credArgs +
                                         @('/Query', '/TN', $task, '/FO', 'CSV', '/NH'))
            if ($state.Code -ne 0) { continue }
            if ($state.Output -match 'Running') {
                $result.Status = 'Busy'
                $result.Detail = "$task is still running; nothing was removed."
                return $result
            }
            $del = Invoke-WouSchTasks (@('/S', $ComputerName) + $credArgs +
                                       @('/Delete', '/TN', $task, '/F'))
            if ($del.Code -eq 0) { $result.TasksDeleted++ }
        }

        if (Test-Path -LiteralPath $uncPayload) {
            Remove-Item -LiteralPath $uncPayload -Recurse -Force -ErrorAction Stop
            $result.Removed = $true
            $result.Status  = 'Cleaned'
            $result.Detail  = "Removed $StagingRoot\$($cfg.PayloadDir)."
        } else {
            $result.Status = 'Cleaned'
            $result.Detail = 'Nothing was staged.'
        }
    } catch {
        $result.Status = 'Failed'
        $result.Detail = $_.Exception.Message
    } finally {
        try { if ($mapped) { $null = & net.exe use $uncShare /delete /y 2>&1 } } catch { }
    }

    return $result
}

function Stop-WouRun {
    <#
    .SYNOPSIS
        Ends a run in progress on one target and deletes its task.

    .DESCRIPTION
        Cancelling on the operator's side only stops the polling; the task on the
        target carries on regardless. This is the other half: /End then /Delete,
        both best effort, because the point of cancelling is not to be blocked
        further by the thing being cancelled.

        DoUpdate.cmd cannot be interrupted safely once it has begun installing, so
        /End stops the wrapper and whatever it happens to be running at that
        moment. That is a deliberately blunt instrument, and a machine cancelled
        mid-install should be scanned again before it is trusted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ComputerName,

        [ValidateSet('Install', 'Scan', 'Both')]
        [string] $Mode = 'Both',
        $Credential
    )

    $cfg = $script:WouConfig
    if ($null -ne $Credential -and $Credential -isnot [System.Management.Automation.PSCredential]) {
        $Credential = New-Object System.Management.Automation.PSCredential(
            $Credential.UserName, $Credential.Password)
    }
    $credArgs = @()
    if ($null -ne $Credential) {
        $credArgs = @('/U', $Credential.UserName, '/P', $Credential.GetNetworkCredential().Password)
    }

    $tasks = switch ($Mode) {
        'Install' { @($cfg.InstallTaskName) }
        'Scan'    { @($cfg.ScanTaskName) }
        default   { @($cfg.InstallTaskName, $cfg.ScanTaskName) }
    }

    $ended = 0
    foreach ($task in $tasks) {
        try {
            $null = Invoke-WouSchTasks (@('/S', $ComputerName) + $credArgs + @('/End', '/TN', $task))
            $del  = Invoke-WouSchTasks (@('/S', $ComputerName) + $credArgs + @('/Delete', '/TN', $task, '/F'))
            if ($del.Code -eq 0) { $ended++ }
        } catch { }
    }
    return [pscustomobject]@{ ComputerName = $ComputerName; TasksEnded = $ended }
}


Export-ModuleMember -Function @(
    'Get-WouRemoteConfig'
    'Get-Root'
    'Read-IniFile'
    'Test-IniFlag'
    'Get-UpdateFlags'
    'Resolve-TargetList'
    'Format-Duration'
    'Get-NewLogLines'
    'Measure-LogLines'
    'Get-StatusFromExitCode'
    'Get-ExitCodeDetail'
    'Test-WouTarget'
    'Get-ScanResult'
    'Invoke-HostRun'
    'Remove-WouStaging'
    'Stop-WouRun'
)
