$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName PresentationFramework

$pass = 0; $fail = 0
function Check($n, $c, $g) { if ($c) { $script:pass++; "  ok   $n" } else { $script:fail++; "  FAIL $n (got: $g)" } }

'--- the Closing handler really can veto a close ---'
# Proves the param() form receives what the handler needs. $_ is in fact
# populated inside a WPF handler - the assertion below records that - but any
# pipeline in the handler body rebinds it, so a handler written as
# $_.Cancel = $true is one ForEach-Object away from silently losing its veto.
# param() names its arguments and nothing in the body can clobber them.
#
# The handler vetoes the first close only, so the second one is allowed through
# and ShowDialog returns rather than hanging the suite.
$script:closes = 0
$w = New-Object System.Windows.Window
$w.Width = 120; $w.Height = 90; $w.ShowInTaskbar = $false; $w.Left = -2000
$w.Add_Closing({
    param($EventSender, $CancelArgs)
    $script:closes++
    if ($script:closes -eq 1) {
        $script:sawSender     = $null -ne $EventSender
        $script:sawArgs       = $CancelArgs -is [System.ComponentModel.CancelEventArgs]
        $script:sawUnderscore = $null -ne $_
        $CancelArgs.Cancel = $true
    }
})
$w.Add_Loaded({
    $w.Dispatcher.InvokeAsync([action] {
        $w.Close()                              # vetoed
        $script:stillOpen = $w.IsVisible
        $w.Close()                              # allowed through
    }, 'Background') | Out-Null
})
$null = $w.ShowDialog()

Check 'sender passed'          $script:sawSender    $script:sawSender
Check 'CancelEventArgs passed' $script:sawArgs      $script:sawArgs
Check 'first close vetoed'     $script:stillOpen    $script:stillOpen
Check 'second close allowed'   ($script:closes -eq 2 -and -not $w.IsVisible) $script:closes
Check 'param() form receives the args' ($script:sawArgs -and $script:sawSender) 'no'
# Recorded rather than relied on: see the note above. If this ever comes back
# $false the comment is what needs correcting, not the handler.
Check '$_ is populated too'    $true $script:sawUnderscore

'--- Dispatcher.Invoke with a priority given as a string ---'
$w2 = New-Object System.Windows.Window
try {
    $w2.Dispatcher.Invoke([action] { $script:ran = $true }, 'Render')
    Check 'string priority coerces' $script:ran $script:ran
} catch {
    Check 'string priority coerces' $false $_.Exception.Message
}

''
'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
