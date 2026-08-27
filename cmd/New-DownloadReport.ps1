<#
.SYNOPSIS
    Summarises what the last UpdateGenerator run downloaded and which systems
    that content targets.

.DESCRIPTION
    Reads the repository's own state - the version ini files, the client tree,
    the build-upgrade table and download.log - and writes a single plain-text
    report. Intended to be fired automatically from
    cmd\custom\FinalizationHook.cmd, but it is safe to run by hand at any time.

    Nothing here modifies the repository; it only reads and writes the report.

.PARAMETER Path
    Where to write the report. Defaults to log\DownloadReport.txt.

.PARAMETER Json
    Also emit a machine-readable sidecar next to the text report. Useful for
    feeding the deployment tooling.

.EXAMPLE
    .\New-DownloadReport.ps1
.EXAMPLE
    .\New-DownloadReport.ps1 -Json
#>
[CmdletBinding()]
param(
    [string] $Path,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$ReportWidth = 74   # report width

# ---------------------------------------------------------------- helpers --
function Get-Root {
    # this script lives in <root>\cmd
    Split-Path -Parent $PSScriptRoot
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -le 0) { return '-' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $Bytes, $units[$i]) }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function Read-IniFile {
    param([string] $File)
    $ini = @{}
    if (-not (Test-Path -LiteralPath $File)) { return $ini }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $File)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            continue
        }
        if ($t -match '^([^=]+)=(.*)$' -and $section) {
            $ini[$section][$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $ini
}

function Add-Line { param([string] $Text = '') ; $null = $script:sb.AppendLine($Text) }
function Add-Rule { Add-Line ('-' * $ReportWidth) }
function Add-Head {
    param([string] $Title)
    Add-Line
    Add-Line $Title.ToUpper()
    Add-Rule
}

# Friendly names for the builds this repository still supports.
$BuildNames = @{
    '17763' = 'Windows Server 2019'
    '20348' = 'Windows Server 2022'
    '22000' = 'Windows 11 21H2'
    '22621' = 'Windows 11 22H2'
    '22631' = 'Windows 11 23H2'
    '26100' = 'Windows 11 24H2'
    '26200' = 'Windows 11 25H2'
}

# --------------------------------------------------------------- gathering --
$root = Get-Root
$client = Join-Path $root 'client'
if (-not $Path) { $Path = Join-Path $root 'log\DownloadReport.txt' }

$genIni = Read-IniFile (Join-Path $root 'UpdateGenerator.ini')
$verIni = Read-IniFile (Join-Path $root 'Windows10Versions.ini')

# version string straight from the downloader, so it can never drift
$version = 'unknown'
$dl = Join-Path $root 'cmd\DownloadUpdates.cmd'
if (Test-Path -LiteralPath $dl) {
    $m = Select-String -LiteralPath $dl -Pattern '^set WSUSOFFLINE_VERSION=(.+)$' |
         Select-Object -First 1
    if ($m) { $version = $m.Matches[0].Groups[1].Value.Trim() }
}

function Get-Stamp {
    param([string] $File)
    $p = Join-Path $client $File
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw).Trim() }
    return 'n/a'
}

# ---- target systems -------------------------------------------------------
$targets = New-Object System.Collections.ArrayList
foreach ($section in @('Windows 11', 'Windows 10')) {
    if (-not $verIni.ContainsKey($section)) { continue }
    foreach ($key in ($verIni[$section].Keys | Sort-Object)) {
        if ($verIni[$section][$key] -ne 'Enabled') { continue }
        $build, $arch = $key -split '_', 2
        $name = $BuildNames[$build]
        if (-not $name) { $name = "Build $build" }
        $null = $targets.Add([pscustomobject]@{
            Name = $name; Build = $build; Arch = $arch; Platform = 'Windows'
        })
    }
}
if ($genIni.ContainsKey('Office 2016') -and $genIni['Office 2016']['glb'] -eq 'Enabled') {
    $null = $targets.Add([pscustomobject]@{
        Name = 'Office 2016'; Build = '-'; Arch = 'glb'; Platform = 'Office'
    })
}

# ---- downloaded content ---------------------------------------------------
$contentDirs = @(
    @{ Label = 'client\w100-x64\glb'; Rel = 'w100-x64\glb'; Updates = $true },
    @{ Label = 'client\o2k16\glb';    Rel = 'o2k16\glb';    Updates = $true },
    @{ Label = 'client\win\glb';      Rel = 'win\glb';      Updates = $false },
    @{ Label = 'client\dotnet';       Rel = 'dotnet';       Updates = $false },
    @{ Label = 'client\cpp';          Rel = 'cpp';          Updates = $false },
    @{ Label = 'client\msedge';       Rel = 'msedge';       Updates = $false },
    @{ Label = 'client\wddefs';       Rel = 'wddefs';       Updates = $false },
    @{ Label = 'client\wsus';         Rel = 'wsus';         Updates = $false }
)

$content = New-Object System.Collections.ArrayList
$updateFiles = New-Object System.Collections.ArrayList
$totalBytes = 0
$totalFiles = 0

foreach ($d in $contentDirs) {
    $full = Join-Path $client $d.Rel
    $files = @()
    if (Test-Path -LiteralPath $full) {
        $files = @(Get-ChildItem -LiteralPath $full -File -Recurse -ErrorAction SilentlyContinue)
    }
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    $totalBytes += $bytes
    $totalFiles += $files.Count
    $null = $content.Add([pscustomobject]@{
        Label = $d.Label; Count = $files.Count; Bytes = $bytes
        Exists = (Test-Path -LiteralPath $full)
    })
    if ($d.Updates) {
        foreach ($f in ($files | Sort-Object Name)) {
            $kb = ''
            if ($f.Name -match '(?i)(kb\d{6,7})') { $kb = $Matches[1].ToUpper() }
            $null = $updateFiles.Add([pscustomobject]@{
                KB = $kb; Name = $f.Name; Bytes = $f.Length; Dir = $d.Label
            })
        }
    }
}

# ---- feature upgrades (driven by the build-upgrade table, not hard-coded) --
$upgrades = New-Object System.Collections.ArrayList
$buTable = Join-Path $client 'static\StaticUpdateIds-BuildUpgrades.txt'
if (Test-Path -LiteralPath $buTable) {
    $glbDir = Join-Path $client 'w100-x64\glb'

    function Find-Package {
        param([string] $Kb, [string] $Dir)
        if (-not $Kb -or -not (Test-Path -LiteralPath $Dir)) { return $null }
        Get-ChildItem -LiteralPath $Dir -File -Filter "*$Kb*" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    foreach ($row in (Get-Content -LiteralPath $buTable)) {
        $r = $row.Trim()
        if (-not $r) { continue }
        $c = $r -split ','
        if ($c.Count -lt 5) { continue }
        $oldBuild = $c[0].Trim()
        $minUbr   = $c[1].Trim()
        $prereqKb = $c[2].Trim()
        $newBuild = $c[3].Trim()
        $epkgKb   = $c[4].Trim()
        # only report upgrades whose source build we actually target
        if (-not ($targets | Where-Object { $_.Build -eq $oldBuild })) { continue }
        $epkgFile   = Find-Package -Kb $epkgKb   -Dir $glbDir
        $prereqFile = Find-Package -Kb $prereqKb -Dir $glbDir
        $null = $upgrades.Add([pscustomobject]@{
            From = $oldBuild; To = $newBuild; MinUbr = $minUbr
            EpkgKb = $epkgKb.ToUpper(); EpkgFile = $epkgFile
            PrereqKb = $prereqKb.ToUpper(); PrereqFile = $prereqFile
            Ready = [bool]$epkgFile
        })
    }
}

# ---- last download run ----------------------------------------------------
$runStart = $null; $runEnd = $null
$warnings = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList
$logFile = Join-Path $root 'log\download.log'
if (Test-Path -LiteralPath $logFile) {
    $log = @(Get-Content -LiteralPath $logFile)
    # walk back to the last "Starting" line
    $startIdx = -1
    for ($i = $log.Count - 1; $i -ge 0; $i--) {
        if ($log[$i] -match 'Info: Starting WSUS Offline Update') { $startIdx = $i; break }
    }
    if ($startIdx -ge 0) {
        $slice = $log[$startIdx..($log.Count - 1)]
        $runStart = ($slice[0] -split ' - ')[0]
        $endLine = $slice | Where-Object { $_ -match 'Info: Ending WSUS Offline Update' } |
                   Select-Object -Last 1
        if ($endLine) { $runEnd = ($endLine -split ' - ')[0] }
        foreach ($l in $slice) {
            if ($l -match ' - Warning: (.+)$') { $null = $warnings.Add($Matches[1].Trim()) }
            elseif ($l -match ' - Error: (.+)$') { $null = $errors.Add($Matches[1].Trim()) }
        }
    }
}

# --------------------------------------------------------------- rendering --
$script:sb = New-Object System.Text.StringBuilder

Add-Line ('=' * $ReportWidth)
Add-Line ' WSUS Offline Update - Download Report'
Add-Line ('=' * $ReportWidth)
Add-Line (' Generated   : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line (' Repository  : {0}' -f $root)
Add-Line (' Version     : {0}' -f $version)
Add-Line (' Build date  : {0}' -f (Get-Stamp 'builddate.txt'))
Add-Line (' Catalog date: {0}' -f (Get-Stamp 'catalogdate.txt'))

Add-Head 'Target systems'
if ($targets.Count -eq 0) {
    Add-Line ' (none selected - check Windows10Versions.ini / UpdateGenerator.ini)'
} else {
    foreach ($t in $targets) {
        Add-Line ('  {0,-24} {1,-7} {2}' -f $t.Name, $t.Build, $t.Arch)
    }
}

# options actually in effect
$opts = New-Object System.Collections.ArrayList
$optMap = [ordered]@{
    'includedotnet' = '.NET Frameworks'; 'seconly' = 'security-only updates'
    'includewddefs' = 'Defender definitions'; 'verifydownloads' = 'verify downloads'
    'cleanupdownloads' = 'cleanup'; 'includewinglb' = 'shared Windows files'
}
foreach ($k in $optMap.Keys) {
    if ($genIni.ContainsKey('Options') -and $genIni['Options'][$k] -eq 'Enabled') {
        $null = $opts.Add($optMap[$k])
    }
}
if ($opts.Count) {
    Add-Line
    Add-Line ('  Options: {0}' -f ($opts -join ', '))
}
if ($genIni.ContainsKey('Miscellaneous')) {
    $wsus = $genIni['Miscellaneous']['wsus']
    if ($wsus) { Add-Line ('  WSUS   : {0}' -f $wsus) }
}

Add-Head 'Downloaded content'
Add-Line ('  {0,-24} {1,7}  {2,12}' -f 'Location', 'Files', 'Size')
foreach ($c in $content) {
    if (-not $c.Exists -and $c.Count -eq 0) { continue }
    Add-Line ('  {0,-24} {1,7}  {2,12}' -f $c.Label, $c.Count, (Format-Size $c.Bytes))
}
Add-Line ('  {0}' -f ('-' * ($ReportWidth - 4)))
Add-Line ('  {0,-24} {1,7}  {2,12}' -f 'TOTAL', $totalFiles, (Format-Size $totalBytes))

if ($upgrades.Count) {
    Add-Head 'Feature upgrades'
    foreach ($u in $upgrades) {
        $fromName = $BuildNames[$u.From]; if (-not $fromName) { $fromName = $u.From }
        $toName = $BuildNames[$u.To];     if (-not $toName)   { $toName = $u.To }
        Add-Line ('  {0} -> {1}   (requires UBR >= {2})' -f $fromName, $toName, $u.MinUbr)
        $eTxt = 'MISSING'
        if ($u.EpkgFile) { $eTxt = 'present  ' + (Format-Size $u.EpkgFile.Length) }
        $pTxt = 'not downloaded (relies on the machine already being patched)'
        if ($u.PrereqFile) { $pTxt = 'present  ' + (Format-Size $u.PrereqFile.Length) }
        Add-Line ('    enablement  {0,-11} {1}' -f $u.EpkgKb, $eTxt)
        Add-Line ('    prerequisite {0,-10} {1}' -f $u.PrereqKb, $pTxt)
        if ($u.Ready) { Add-Line '    status: ready to deploy' }
        else { Add-Line '    status: NOT ready - enablement package missing' }
    }
}

if ($updateFiles.Count) {
    Add-Head ('Update files ({0})' -f $updateFiles.Count)
    foreach ($f in $updateFiles) {
        $name = $f.Name
        if ($name.Length -gt 52) { $name = $name.Substring(0, 49) + '...' }
        Add-Line ('  {0,-10} {1,-52} {2,10}' -f $f.KB, $name, (Format-Size $f.Bytes))
    }
}

Add-Head 'Last download run'
if ($runStart) {
    Add-Line ('  Started : {0}' -f $runStart)
    if ($runEnd) { Add-Line ('  Ended   : {0}' -f $runEnd) }
    else { Add-Line '  Ended   : (no completion line - run may have failed)' }
} else {
    Add-Line '  (no download.log found)'
}
Add-Line ('  Warnings: {0}' -f $warnings.Count)
foreach ($warnLine in ($warnings | Select-Object -Unique -First 10)) { Add-Line ('    - {0}' -f $warnLine) }
if ($warnings.Count -gt 10) { Add-Line ('    ... and {0} more' -f ($warnings.Count - 10)) }
Add-Line ('  Errors  : {0}' -f $errors.Count)
foreach ($errLine in ($errors | Select-Object -Unique -First 10)) { Add-Line ('    - {0}' -f $errLine) }

Add-Line
Add-Line ('=' * $ReportWidth)

# ----------------------------------------------------------------- output --
$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    $null = New-Item -ItemType Directory -Path $dir -Force
}
$script:sb.ToString() | Set-Content -LiteralPath $Path -Encoding UTF8
Write-Host ("Download report written to {0}" -f $Path)

if ($Json) {
    $jsonPath = [System.IO.Path]::ChangeExtension($Path, '.json')
    [pscustomobject]@{
        generated    = (Get-Date -Format 's')
        repository   = $root
        version      = $version
        buildDate    = (Get-Stamp 'builddate.txt')
        catalogDate  = (Get-Stamp 'catalogdate.txt')
        targets      = @($targets)
        content      = @($content | Select-Object Label, Count, Bytes)
        totalFiles   = $totalFiles
        totalBytes   = $totalBytes
        featureUpgrades = @($upgrades | Select-Object From, To, MinUbr, EpkgKb, PrereqKb, Ready)
        updateFiles  = @($updateFiles | Select-Object KB, Name, Bytes, Dir)
        lastRun      = [pscustomobject]@{
            started = $runStart; ended = $runEnd
            warnings = $warnings.Count; errors = $errors.Count
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Host ("JSON sidecar written to {0}" -f $jsonPath)
}
