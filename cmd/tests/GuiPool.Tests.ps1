# TestTag: slow
# Drives the GUI's worker pool end to end against hosts that cannot answer.
#
# This is the suite that covers the GUI's chief risk. The pool runs Start-Job
# workers behind a DispatcherTimer, and the failure modes are the ones that do
# not show up in a unit test: more jobs in flight than the throttle allows, a
# timer that never stops, buttons left disabled after the run, or Receive-Job
# leaving jobs behind to accumulate over an operator's afternoon.
#
# The targets are names that resolve nowhere, so the run is self-contained and
# every row must come back Unreachable. It takes over a minute - five hosts at
# an 18-second SMB timeout, two at a time - hence the slow tag.
$ErrorActionPreference = 'Stop'

# Resolved from this file's own location, so the suite runs from any checkout
# rather than only from the one it was written in.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$GuiPath  = Join-Path $RepoRoot 'cmd\Show-RemoteUpdateGui.ps1'

$pass = 0; $fail = 0
function Check($name, $want, $got) {
    if ("$want" -eq "$got") { $script:pass++; "  ok   $name" }
    else { $script:fail++; "  FAIL $name : want [$want] got [$got]" }
}

$text = [System.IO.File]::ReadAllText($GuiPath)
# Elevation is only needed to actually stage and run; the pool itself can be
# exercised unelevated. Stopping short of ShowDialog keeps this headless - the
# dispatcher is pumped by hand below instead.
$text = $text.Replace('#Requires -RunAsAdministrator', '# (requirement removed for this test)')
$text = $text.Replace('$null = $win.ShowDialog()',      '# window deliberately not shown')

$targets = Join-Path $env:TEMP 'wou-gui-pool-targets.txt'
$hosts   = 'wou-nosuch-a1', 'wou-nosuch-b2', 'wou-nosuch-c3', 'wou-nosuch-d4', 'wou-nosuch-e5'
Set-Content -LiteralPath $targets -Encoding Ascii -Value $hosts

# The harness has to sit beside the real script: the GUI resolves the payload
# and the module relative to its own $PSScriptRoot, so running it from anywhere
# else would test a path layout no operator has.
$harness = Join-Path (Split-Path -Parent $GuiPath) 'zz-wou-gui-harness-pool.ps1'
try {
    [System.IO.File]::WriteAllText($harness, $text)
    . $harness -TargetFile $targets -Throttle 2 -StagingRoot 'C:\temp'
} finally {
    Remove-Item -LiteralPath $harness -Force -ErrorAction SilentlyContinue
}

function Pump {
    # One pass of the message loop. ShowDialog is what normally does this, and
    # without it the DispatcherTimer never ticks, so the pool would sit at zero
    # done forever and the suite would look like a hang rather than a failure.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action] { $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

Check 'rows loaded from the target file' $hosts.Count $script:Rows.Count
foreach ($r in $script:Rows) { $r.IsSelected = $true }

'--- pool run ---'
# Raise the click rather than calling the handler, so the wiring is under test
# too and not just the body.
$BtnStatus.RaiseEvent(
    (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))

Check 'cancel enabled while working'  $true $BtnCancel.IsEnabled
Check 'scan disabled while working'   $true (-not $BtnScan.IsEnabled)

$maxRunning = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (($script:Running.Count -gt 0 -or $script:Queue.Count -gt 0) -and
       $sw.Elapsed.TotalSeconds -lt 240) {
    Pump
    if ($script:Running.Count -gt $maxRunning) { $maxRunning = $script:Running.Count }
    Start-Sleep -Milliseconds 150
}
Pump
$sw.Stop()
'  elapsed {0:N1}s, peak concurrency {1}' -f $sw.Elapsed.TotalSeconds, $maxRunning

Check 'run finished inside the guard'  $true ($sw.Elapsed.TotalSeconds -lt 240)
# The throttle is the whole point of the pool: exceeding it would let an
# operator with a hundred targets open a hundred SMB sessions at once.
Check 'throttle was never exceeded'    $true ($maxRunning -le 2)
Check 'more than one ran at a time'    $true ($maxRunning -gt 1)
Check 'every host was accounted for'   $script:Total $script:Done
Check 'progress bar reached the end'   $true ($Bar.Value -eq $Bar.Maximum -and $Bar.Maximum -gt 0)

'--- state afterwards ---'
# A timer left running keeps waking up forever; buttons left disabled make the
# window look wedged after a perfectly successful run.
Check 'timer stopped'                  $true (-not $script:Timer.IsEnabled)
Check 'scan re-enabled'                $true $BtnScan.IsEnabled
Check 'cancel disabled again'          $true (-not $BtnCancel.IsEnabled)
Check 'no jobs left behind'            0     (@(Get-Job).Count)
Check 'status line says something'     $true ([bool]$LblStatus.Text)

$script:Rows | Format-Table HostName, Conn, Status, Busy, @{n='Detail'; e={
    if ($_.Detail.Length -gt 58) { $_.Detail.Substring(0, 58) + '...' } else { $_.Detail }
}} -AutoSize | Out-String -Width 160

# None of these names resolve, so anything other than Unreachable means the
# preflight reported a state it cannot possibly have established.
$bad = @($script:Rows | Where-Object { $_.Status -ne 'Unreachable' -or $_.Busy })
Check 'all rows Unreachable, none busy' 0 $bad.Count
$blank = @($script:Rows | Where-Object { -not $_.Detail })
Check 'every row explains itself'       0 $blank.Count

Remove-Item -LiteralPath $targets -Force -ErrorAction SilentlyContinue

''
'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
