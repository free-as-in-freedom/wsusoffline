$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'cmd\WsusOfflineRemote.psm1'
Import-Module $ModulePath -Force

$pass = 0; $fail = 0
function Check($name, $expected, $actual) {
    $ok = ($expected -eq $actual)
    if ($ok) { $script:pass++ } else { $script:fail++ }
    '{0} {1}: expected [{2}] got [{3}]' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $expected, $actual
}

$sandbox = Join-Path $env:TEMP 'wou-mod-test2'
if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
$null = New-Item -ItemType Directory -Path $sandbox -Force

# --- target list -------------------------------------------------------------
$tf = Join-Path $sandbox 'targets.txt'
Set-Content $tf -Value @(
    '# a comment', '', '   ', 'SRV01', 'srv02  ', 'SRV01', $env:COMPUTERNAME, 'localhost', '10.0.0.42'
)
$t = Resolve-TargetList -Names @('SRV01', ' SRV03 ', '') -File $tf -WarningAction SilentlyContinue
Check 'target count'      4 $t.Count
Check 'targets in order'  'SRV01, SRV03, srv02, 10.0.0.42' (($t | Select-Object -First 4) -join ', ')
Check 'self excluded'     $false ($t -contains $env:COMPUTERNAME)
Check 'localhost excluded' $false ($t -contains 'localhost')
Check 'empty list is empty' 0 (Resolve-TargetList -Names @() -File $null).Count
$threw = $false
try { $null = Resolve-TargetList -Names @() -File (Join-Path $sandbox 'missing.txt') } catch { $threw = $true }
Check 'missing target file throws' $true $threw

# --- status classification ---------------------------------------------------
foreach ($case in @(
    @{ Code = 0;    Mode = 'Install'; Want = 'Complete' }
    @{ Code = 3010; Mode = 'Install'; Want = 'RebootRequired' }
    @{ Code = 3011; Mode = 'Install'; Want = 'RecallRequired' }
    @{ Code = 1;    Mode = 'Install'; Want = 'Failed' }
    @{ Code = 42;   Mode = 'Install'; Want = 'Failed' }
    @{ Code = -1;   Mode = 'Install'; Want = 'Failed' }
    @{ Code = 0;    Mode = 'Scan';    Want = 'Scanned' }
    @{ Code = 1;    Mode = 'Scan';    Want = 'Failed' }
    @{ Code = 2;    Mode = 'Scan';    Want = 'NotAdmin' }
    @{ Code = 3;    Mode = 'Scan';    Want = 'Unsupported' }
    @{ Code = 4;    Mode = 'Scan';    Want = 'NoCatalog' }
)) {
    Check ("status {0}/{1}" -f $case.Mode, $case.Code) $case.Want (Get-StatusFromExitCode -ExitCode $case.Code -Mode $case.Mode)
}
Check 'status null is Timeout' 'Timeout' (Get-StatusFromExitCode -ExitCode $null -Mode 'Install')
Check 'detail 0 is null'       $null    (Get-ExitCodeDetail -ExitCode 0 -Mode 'Install')
Check 'detail 42 explains'     'DoUpdate.cmd exited 42.' (Get-ExitCodeDetail -ExitCode 42 -Mode 'Install')
Check 'detail scan 4 explains' $true    ((Get-ExitCodeDetail -ExitCode 4 -Mode 'Scan') -match 'wsusscn2.cab')

# --- duration formatting -----------------------------------------------------
Check 'duration null'   '-'        (Format-Duration $null)
Check 'duration 0'      '00:00:00' (Format-Duration ([TimeSpan]::Zero))
Check 'duration 31m12s' '00:31:12' (Format-Duration (New-TimeSpan -Minutes 31 -Seconds 12))
Check 'duration 91m'    '01:31:00' (Format-Duration (New-TimeSpan -Minutes 91))
Check 'duration 26h'    '26:00:05' (Format-Duration (New-TimeSpan -Hours 26 -Seconds 5))

# --- log helpers -------------------------------------------------------------
$lf = Join-Path $sandbox 'update.log'
Set-Content $lf -Value @('one','two','three')
Check 'measure lines'       3 (Measure-LogLines $lf)
Check 'measure missing'     0 (Measure-LogLines (Join-Path $sandbox 'nope.log'))
Add-Content $lf -Value @('four','five')
Check 'delta lines'         'four, five' ((Get-NewLogLines -LogPath $lf -SkipLines 3) -join ', ')
Check 'delta of missing'    0 (Get-NewLogLines -LogPath (Join-Path $sandbox 'nope.log') -SkipLines 0).Count

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
