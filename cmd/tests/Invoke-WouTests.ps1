<#
.SYNOPSIS
    Runs the WsusOfflineRemote test suites and reports one verdict.

.DESCRIPTION
    Discovers every *.Tests.ps1 beside this script and runs each in its own
    powershell.exe. A separate process per suite is deliberate: the suites
    import the module with -Force, set their own preference variables, and
    several of them create WPF windows and pump a dispatcher. Sharing one
    session would let one suite's leftovers decide the next suite's result,
    which is the one thing a test runner must not do. It also means a suite
    that dies outright is reported as a failure instead of taking the run
    with it.

    Every suite ends with a "RESULT pass=<n> fail=<n>" line. A suite that
    exits without one is treated as a failure, not as an empty pass - a
    crash before the first assertion would otherwise read as success.

    None of this needs elevation or a network. The suites tagged slow spend
    their time in SMB connect timeouts against names that resolve nowhere;
    -SkipSlow leaves them out for a quick check, at the cost of the two
    suites that cover the connectivity diagnosis and the GUI worker pool.

.PARAMETER Name
    Wildcard over suite names, without the .Tests.ps1 suffix. Default *.

.PARAMETER SkipSlow
    Skip suites marked "# TestTag: slow" in their header.

.PARAMETER Detail
    Show each suite's full output, including the individual ok lines. By
    default only failures are shown in full.

.EXAMPLE
    .\Invoke-WouTests.ps1
    The whole suite. Takes a few minutes, most of it in deliberate timeouts.

.EXAMPLE
    .\Invoke-WouTests.ps1 -SkipSlow
    Everything that runs in seconds.

.EXAMPLE
    .\Invoke-WouTests.ps1 -Name Gui* -Detail
    Just the GUI suites, showing every assertion.
#>
[CmdletBinding()]
param(
    [string] $Name = '*',
    [switch] $SkipSlow,
    [switch] $Detail
)

$ErrorActionPreference = 'Stop'

$suites = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' |
            Where-Object { $_.BaseName -replace '\.Tests$', '' -like $Name } |
            Sort-Object Name)

if (-not $suites) {
    Write-Warning "No suite in $PSScriptRoot matches '$Name'."
    exit 2
}

# A GUI suite that dies mid-run can leave its harness copy in cmd\. Clear any
# before starting so a stale one cannot be dot-sourced by mistake.
Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) `
    -Filter 'zz-wou-gui-harness*.ps1' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$results = @()
$total   = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($suite in $suites) {
    $short = $suite.BaseName -replace '\.Tests$', ''
    $head  = Get-Content -LiteralPath $suite.FullName -TotalCount 20
    $slow  = [bool]($head -match 'TestTag:\s*slow')

    if ($slow -and $SkipSlow) {
        $results += [pscustomobject]@{
            Name = $short; Pass = 0; Fail = 0; Seconds = 0; Slow = $true
            State = 'skipped'; Output = @()
        }
        continue
    }

    Write-Host ('running {0}{1} ...' -f $short, $(if ($slow) { ' (slow)' } else { '' })) `
        -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # 2>&1 is safe here: the child is powershell.exe, and its stderr is worth
    # keeping - a suite that throws says why on stderr and nowhere else.
    $out  = & powershell.exe -NoProfile -File $suite.FullName 2>&1 |
                ForEach-Object { [string] $_ }
    $code = $LASTEXITCODE
    $sw.Stop()

    $marker = @($out) -match '^RESULT pass=(\d+) fail=(\d+)$' | Select-Object -Last 1
    if ($marker) {
        $m     = [regex]::Match($marker, '^RESULT pass=(\d+) fail=(\d+)$')
        $p     = [int] $m.Groups[1].Value
        $f     = [int] $m.Groups[2].Value
        $state = if ($f -eq 0) { 'passed' } else { 'failed' }
    } else {
        # No marker means the suite never reached its own last line.
        $p = 0; $f = 0
        $state = 'crashed'
    }

    $results += [pscustomobject]@{
        Name = $short; Pass = $p; Fail = $f; Seconds = $sw.Elapsed.TotalSeconds
        Slow = $slow; State = $state; Output = @($out); ExitCode = $code
    }
}

$total.Stop()

''
'{0,-16} {1,-8} {2,7} {3,7} {4,8}' -f 'suite', 'state', 'pass', 'fail', 'seconds'
'-' * 50
foreach ($r in $results) {
    $line = '{0,-16} {1,-8} {2,7} {3,7} {4,8:N1}' -f
        $r.Name, $r.State, $r.Pass, $r.Fail, $r.Seconds
    $colour = switch ($r.State) {
        'passed'  { 'Green' }
        'skipped' { 'DarkGray' }
        default   { 'Red' }
    }
    Write-Host $line -ForegroundColor $colour
}
'-' * 50

foreach ($r in $results) {
    if ($Detail -and $r.State -ne 'skipped') {
        ''
        "==== $($r.Name) ===="
        $r.Output
    } elseif ($r.State -eq 'failed') {
        ''
        "==== $($r.Name): failures ===="
        $r.Output | Where-Object { $_ -match 'FAIL' }
    } elseif ($r.State -eq 'crashed') {
        ''
        "==== $($r.Name): no RESULT line, exit code $($r.ExitCode) ===="
        # The tail is where the reason is: the throw that ended the suite.
        $r.Output | Select-Object -Last 15
    }
}

$ran     = @($results | Where-Object { $_.State -ne 'skipped' })
$broken  = @($results | Where-Object { $_.State -in 'failed', 'crashed' })
$skipped = @($results | Where-Object { $_.State -eq 'skipped' })

''
'{0} suites, {1} assertions, {2} failed{3} - {4:N0}s' -f
    $ran.Count,
    (($ran | Measure-Object -Property Pass -Sum).Sum + ($ran | Measure-Object -Property Fail -Sum).Sum),
    ($ran | Measure-Object -Property Fail -Sum).Sum,
    $(if ($skipped) { ", $($skipped.Count) skipped" } else { '' }),
    $total.Elapsed.TotalSeconds

if ($broken) {
    Write-Host ('FAILED: {0}' -f (($broken | ForEach-Object { $_.Name }) -join ', ')) `
        -ForegroundColor Red
    exit 1
}

Write-Host 'all suites passed' -ForegroundColor Green
exit 0
