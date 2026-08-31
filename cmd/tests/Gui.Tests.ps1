$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$GuiPath    = Join-Path $RepoRoot 'cmd\Show-RemoteUpdateGui.ps1'
$src  = $GuiPath
$text = [System.IO.File]::ReadAllText($src)

# Strip the elevation requirement and stop before the window is actually shown,
# so the whole script can be exercised on an unelevated box with no display.
$text = $text.Replace('#Requires -RunAsAdministrator', '# (requirement removed for this test)')
$text = $text.Replace('$null = $win.ShowDialog()', @'
$script:Harness = @{
    Win = $win; Rows = $script:Rows; Updates = $script:Updates
    Grid = $GridTargets; UpGrid = $GridUpdates; Timer = $script:Timer
    Header = $GridTargets.Columns[0].Header
    Log = $TxtLog; Status = $LblStatus; Detail = $LblDetail
}
'@)

$targets = Join-Path $env:TEMP 'wou-gui-targets.txt'
Set-Content -LiteralPath $targets -Encoding Ascii -Value @(
    '# test list',
    'SRV01',
    'SRV01',
    '10.0.0.42',
    $env:COMPUTERNAME,
    '',
    'WS-07'
)

$tmp = Join-Path (Split-Path -Parent $src) ('zz-wou-gui-harness-' + $MyInvocation.MyCommand.Name)
[System.IO.File]::WriteAllText($tmp, $text)

. $tmp -TargetFile $targets -Throttle 2 -StagingRoot 'C:\temp'

$h = $script:Harness
$pass = 0; $fail = 0
function Check($name, $cond, $got) {
    if ($cond) { $script:pass++; "  ok   $name" }
    else { $script:fail++; "  FAIL $name (got: $got)" }
}

'--- window and controls ---'
Check 'window built'        ($null -ne $h.Win)                  $h.Win
Check 'title'               ($h.Win.Title -match 'fleet console') $h.Win.Title
Check 'targets grid found'  ($null -ne $h.Grid)                  $h.Grid
Check 'target columns = 10' ($h.Grid.Columns.Count -eq 10)       $h.Grid.Columns.Count
Check 'update columns = 4'  ($h.UpGrid.Columns.Count -eq 4)      $h.UpGrid.Columns.Count
Check 'header is checkbox'  ($h.Header -is [System.Windows.Controls.CheckBox]) $h.Header
Check 'timer 1s, stopped'   ($h.Timer.Interval.TotalSeconds -eq 1 -and -not $h.Timer.IsEnabled) $h.Timer.IsEnabled

'--- target list ---'
Check 'rows = 3 (dedup + self dropped)' ($h.Rows.Count -eq 3) $h.Rows.Count
Check 'row type'          ($h.Rows[0].GetType().Name -eq 'WouTargetRow') $h.Rows[0].GetType().Name
Check 'self not listed'   (@($h.Rows | Where-Object { $_.HostName -eq $env:COMPUTERNAME }).Count -eq 0) 'present'
Check 'initial status'    ($h.Rows[0].Status -eq 'Not checked') $h.Rows[0].Status
Check 'nothing ticked'    (@($h.Rows | Where-Object { $_.IsSelected }).Count -eq 0) 'ticked'
Check 'log mentions self' ($h.Log.Text -match 'that is this machine') 'no warning'
Check 'log mentions load' ($h.Log.Text -match 'Loaded 3 machine') 'no load line'

'--- select all ---'
$h.Header.IsChecked = $true
Check 'all ticked'   (@($h.Rows | Where-Object { $_.IsSelected }).Count -eq 3) 'not all'
$h.Header.IsChecked = $false
Check 'none ticked'  (@($h.Rows | Where-Object { $_.IsSelected }).Count -eq 0) 'still ticked'

'--- notification ---'
$fired = @()
$h.Rows[0].add_PropertyChanged({ param($s, $e) $script:fired += $e.PropertyName })
$h.Rows[0].Status = 'Scanning...'
$h.Rows[0].Needs  = '12'
Check 'PropertyChanged raised' ($fired -contains 'Status' -and $fired -contains 'Needs') ($fired -join ',')

'--- update grid for a row with no scan ---'
$h.Grid.SelectedItem = $h.Rows[0]
Check 'no-scan message' ($h.Detail.Text -match 'no scan yet') $h.Detail.Text

''
'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
Remove-Item $tmp, $targets -Force -ErrorAction SilentlyContinue
