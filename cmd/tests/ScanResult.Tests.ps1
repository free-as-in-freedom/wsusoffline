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

$scan = Join-Path $env:TEMP 'wou-mod-test3\scan'
if (Test-Path (Split-Path $scan)) { Remove-Item (Split-Path $scan) -Recurse -Force }
$null = New-Item -ItemType Directory -Path $scan -Force

# Formats taken from the real producers: ListMissingUpdateIds.vbs:91 writes
# "<bare kb id>,<UpdateID>", ListUpdateFile.cmd writes "<dir>\<file>", and
# ListUpdatesToInstall.cmd:233/243 write the log lines without a trailing period.
Set-Content (Join-Path $scan 'scanresult.txt') -Value '0'
Set-Content (Join-Path $scan 'MissingUpdateIds.txt') -Value @(
    '5034441,11111111-1111-1111-1111-111111111111'
    '5041580,22222222-2222-2222-2222-222222222222'
    '2267602,33333333-3333-3333-3333-333333333333'
    '5039211,44444444-4444-4444-4444-444444444444'
)
Set-Content (Join-Path $scan 'UpdatesToInstall.txt') -Value @(
    '..\w100-x64\glb\windows10.0-kb5034441-x64.msu'
    '..\w100-x64\glb\windows10.0-kb5039211-x64.msu'
)
Set-Content (Join-Path $scan 'scan.log') -Value @(
    '08/31/2026 10:00:00,00 - Info: Starting scan for w100 x64 enu'
    '08/31/2026 10:01:00,00 - Warning: Update kb5041580 (id: 22222222-2222-2222-2222-222222222222) not found'
    '08/31/2026 10:01:01,00 - Info: Skipped update kb2267602 due to matching black list entry'
    '08/31/2026 10:01:02,00 - Warning: Update file win10.0-kb9999999-x64.cab (id: 55555555) not found'
    '08/31/2026 10:02:00,00 - Info: Ending scan'
)

$r = Get-ScanResult -Path $scan
Check 'exit code parsed'  0 $r.ExitCode
Check 'scanned at set'    $true ($null -ne $r.ScannedAt)
Check 'applicable count'  4 $r.Applicable
Check 'not in payload'    1 $r.NotInPayload
Check 'excluded count'    1 $r.Excluded
Check 'payload file count' 2 $r.PayloadFiles.Count
Check 'file warnings'     1 $r.Warnings.Count

$byKb = @{}
foreach ($u in $r.Updates) { $byKb[$u.KB] = $u }
Check 'kb prefix added'   $true $byKb.ContainsKey('kb5034441')
Check 'have kb5034441'    $true $byKb['kb5034441'].InPayload
Check 'file for kb5034441' $true ($byKb['kb5034441'].File -like '*windows10.0-kb5034441-x64.msu')
Check 'kb5034441 no reason' $null $byKb['kb5034441'].Reason
Check 'updateid kept'     '11111111-1111-1111-1111-111111111111' $byKb['kb5034441'].UpdateId
Check 'missing kb5041580' $false $byKb['kb5041580'].InPayload
Check 'missing reason'    'not downloaded' $byKb['kb5041580'].Reason
Check 'missing has no file' $null $byKb['kb5041580'].File
Check 'excluded kb2267602' $true $byKb['kb2267602'].Excluded
Check 'excluded not counted as missing' $false $byKb['kb2267602'].InPayload
Check 'excluded reason'   'black list' $byKb['kb2267602'].Reason

# A directory that is not there at all must come back empty, not throw: that is
# how "the task died before writing anything" reaches the caller.
$empty = Get-ScanResult -Path (Join-Path $env:TEMP 'wou-mod-test3\nope')
Check 'absent scan dir'   0 $empty.Applicable
Check 'absent exit code'  $null $empty.ExitCode

# A reason in parentheses is carried through verbatim.
Add-Content (Join-Path $scan 'scan.log') -Value '08/31/2026 10:03:00,00 - Info: Skipped update kb5039211 (ExcludeList-superseded.txt) due to matching black list entry'
$r2 = Get-ScanResult -Path $scan
$u2 = @($r2.Updates | Where-Object { $_.KB -eq 'kb5039211' })[0]
Check 'reason in brackets' 'ExcludeList-superseded.txt' $u2.Reason
Check 'excluded wins over payload' $false $u2.InPayload

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
