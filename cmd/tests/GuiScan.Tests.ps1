$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$GuiPath    = Join-Path $RepoRoot 'cmd\Show-RemoteUpdateGui.ps1'
$src  = $GuiPath
$text = [System.IO.File]::ReadAllText($src)
$text = $text.Replace('#Requires -RunAsAdministrator', '# (removed for this test)')
$text = $text.Replace('$null = $win.ShowDialog()', '# window deliberately not shown')

# A scan directory shaped exactly the way ScanOnly.cmd leaves one behind, with
# the three log lines ListUpdatesToInstall.cmd actually writes.
$scan = Join-Path $env:TEMP 'wou-fake-scan'
if (Test-Path $scan) { Remove-Item $scan -Recurse -Force }
New-Item -ItemType Directory -Path $scan | Out-Null
Set-Content "$scan\MissingUpdateIds.txt" -Encoding Ascii -Value @(
    '5034441,{11111111-1111-1111-1111-111111111111}',
    '5041580,{22222222-2222-2222-2222-222222222222}',
    '890830,{33333333-3333-3333-3333-333333333333}',
    '5005463,{44444444-4444-4444-4444-444444444444}')
Set-Content "$scan\UpdatesToInstall.txt" -Encoding Ascii -Value @(
    '..\w100-x64\glb\windows10.0-kb5034441-x64.msu',
    '..\w100-x64\glb\windows10.0-kb890830-x64.exe')
Set-Content "$scan\scan.log" -Encoding Ascii -Value @(
    '2026-08-31 10:00:01 - Info: Starting scan',
    '2026-08-31 10:00:09 - Warning: Update kb5041580 (id: {2222}) not found',
    '2026-08-31 10:00:09 - Info: Skipped update kb5005463 (superseded) due to matching black list entry',
    '2026-08-31 10:00:10 - Warning: Update file w100-x64\glb\nothere.msu not found',
    '2026-08-31 10:00:11 - Info: Done')
Set-Content "$scan\scanresult.txt" -Encoding Ascii -Value '0'

$targets = Join-Path $env:TEMP 'wou-gui-targets3.txt'
Set-Content -LiteralPath $targets -Encoding Ascii -Value @('SRV01', 'SRV02')

$tmp = Join-Path (Split-Path -Parent $src) ('zz-wou-gui-harness-' + $MyInvocation.MyCommand.Name)
[System.IO.File]::WriteAllText($tmp, $text)
. $tmp -TargetFile $targets -Throttle 4 -StagingRoot 'C:\temp'
Remove-Item $tmp -Force

$pass = 0; $fail = 0
function Check($name, $cond, $got) {
    if ($cond) { $script:pass++; "  ok   $name" } else { $script:fail++; "  FAIL $name (got: $got)" }
}

'--- a scanned row feeds the lower grid ---'
$row = $script:Rows[0]
$row.ScanPath = $scan
$GridTargets.SelectedItem = $row

Check 'four update rows'   ($script:Updates.Count -eq 4) $script:Updates.Count
$byKb = @{}; foreach ($u in $script:Updates) { $byKb[$u.KB] = $u }
Check 'in payload -> Yes'  ($byKb['kb5034441'].State -eq 'Yes') $byKb['kb5034441'].State
Check 'file resolved'      ($byKb['kb5034441'].File -match 'kb5034441-x64.msu') $byKb['kb5034441'].File
Check 'missing -> No'      ($byKb['kb5041580'].State -eq 'No - not downloaded') $byKb['kb5041580'].State
Check 'missing has no file' ($byKb['kb5041580'].File -eq '') "[$($byKb['kb5041580'].File)]"
Check 'blacklisted'        ($byKb['kb5005463'].State -eq 'Excluded (superseded)') $byKb['kb5005463'].State
Check 'update id kept'     ($byKb['kb890830'].UpdateId -eq '{33333333-3333-3333-3333-333333333333}') $byKb['kb890830'].UpdateId
Check 'header counts'      ($LblDetail.Text -match '4 applicable, 1 not in the download, 1 excluded') $LblDetail.Text
Check 'file warning logged' ($TxtLog.Text -match 'nothere\.msu') 'not logged'

'--- Set-RowFromRun, scan mode ---'
$fakeScan = Get-ScanResult -Path $scan
Set-RowFromRun -Row $row -Result ([pscustomobject]@{
    Status = 'Scanned'; Detail = 'ok'; ScanPath = $scan; Scan = $fakeScan }) -Kind 'Scan'
Check 'needs column'   ($row.Needs -eq '4')   $row.Needs
Check 'missing column' ($row.Missing -eq '1') $row.Missing
Check 'scanned stamp'  ($row.Scanned -match '^\d\d:\d\d:\d\d$') $row.Scanned
Check 'status'         ($row.Status -eq 'Scanned') $row.Status

'--- Set-RowFromRun, install mode invalidates the scan ---'
Set-RowFromRun -Row $row -Result ([pscustomobject]@{
    Status = 'RebootRequired'; Detail = 'restart pending'; ScanPath = $null; Scan = $null }) -Kind 'Install'
Check 'needs invalidated'  ($row.Needs -eq '?')       $row.Needs
Check 'scan marked stale'  ($row.Scanned -eq 'stale') $row.Scanned
Check 'scan path dropped'  ($row.ScanPath -eq '')     "[$($row.ScanPath)]"
Check 'install status kept' ($row.Status -eq 'RebootRequired') $row.Status

'--- Set-RowFromStatus ---'
$r2 = $script:Rows[1]
Set-RowFromStatus -Row $r2 -Info ([pscustomobject]@{ AdminShare = $true; Reachable = $true
    FreeGB = 84.3; OsCaption = 'Microsoft Windows Server 2022 Standard'; Busy = $false
    BusyTask = $null; LastBootUpTime = (Get-Date '2026-08-20 06:12'); Note = $null })
Check 'conn SMB'      ($r2.Conn -eq 'SMB')      $r2.Conn
Check 'free rounded'  ($r2.Free -eq '84 GB')    $r2.Free
Check 'ready'         ($r2.Status -eq 'Ready')  $r2.Status
Check 'uptime shown'  ($r2.Detail -match '2026-08-20 06:12') $r2.Detail

Set-RowFromStatus -Row $r2 -Info ([pscustomobject]@{ AdminShare = $true; Reachable = $true
    FreeGB = 5; OsCaption = 'x'; Busy = $true; BusyTask = 'WOUOfflineUpdate'
    LastBootUpTime = $null; Note = $null })
Check 'busy reported' ($r2.Status -eq 'Busy' -and $r2.Detail -match 'WOUOfflineUpdate') $r2.Detail

Set-RowFromStatus -Row $r2 -Info ([pscustomobject]@{ AdminShare = $false; Reachable = $true
    FreeGB = $null; OsCaption = $null; Busy = $false; BusyTask = $null
    LastBootUpTime = $null; Note = 'Answers ping, but the share is not reachable' })
Check 'ping only'     ($r2.Conn -eq 'ping only' -and $r2.Status -eq 'NoAdminShare') "$($r2.Conn)/$($r2.Status)"
Check 'free unknown'  ($r2.Free -eq '-') $r2.Free

'--- staging root validation ---'
foreach ($bad in 'C:\my temp', 'temp', '\srv\share', '') {
    $TxtStaging.Text = $bad
    $ok = ($bad -notmatch '\s') -and ($bad -match '^[A-Za-z]:\\')
    Check "rejects '$bad'" (-not $ok) 'accepted'
}
$TxtStaging.Text = 'D:\stage'
Check "accepts 'D:\stage'" (('D:\stage' -notmatch '\s') -and ('D:\stage' -match '^[A-Za-z]:\\')) 'rejected'

'--- throttle and timeout coercion ---'
foreach ($t in 'abc', '0', '99', '') { $TxtThrottle.Text = $t; $null = Get-GuiThrottle }
Check 'bad throttle -> 8' ($TxtThrottle.Text -eq '8') $TxtThrottle.Text
$TxtThrottle.Text = '3'
Check 'good throttle kept' ((Get-GuiThrottle) -eq 3) (Get-GuiThrottle)
$TxtTimeout.Text = 'zzz'
Check 'bad timeout -> 180' ((Get-GuiTimeout) -eq 180) $TxtTimeout.Text

''
'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
Remove-Item $scan -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $targets -Force -ErrorAction SilentlyContinue
