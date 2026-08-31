# Regression test for the schtasks stderr bug.
#
# Invoke-WouSchTasks redirects stderr with 2>&1 so it can report why a call
# failed. Under PowerShell 5.1 that wraps each stderr line in an ErrorRecord,
# and the module sets $ErrorActionPreference = 'Stop' - so the helper threw
# instead of returning. schtasks reports "the task does not exist" on stderr
# with exit code 1, which is the ordinary answer on any host that has not been
# run against, so Invoke-HostRun's AlreadyRunning guard threw on every clean
# target and the run reported Failed / "The system cannot find the file
# specified." before staging a single byte.
$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'cmd\WsusOfflineRemote.psm1'
$pass = 0; $fail = 0
function Check($name, $want, $got) {
    if ("$want" -eq "$got") { $script:pass++; "  ok   $name" }
    else { $script:fail++; "  FAIL $name : want [$want] got [$got]" }
}

Import-Module $ModulePath -Force
$m = Get-Module WsusOfflineRemote

Check 'module preference is still Stop' 'Stop' (& $m { $ErrorActionPreference })

# 1. The bug itself: an absent task must be an answer, not an exception.
$threw = $false; $r = $null
try { $r = & $m { Invoke-WouSchTasks @('/Query', '/TN', 'WOU-NoSuchTask-ZZZ', '/FO', 'CSV', '/NH') } }
catch { $threw = $true }
Check 'absent task does not throw' $false $threw
Check 'absent task reports non-zero' $true ($r.Code -ne 0)
Check 'absent task has a reason'    $true ([bool]$r.Output)

# 2. The ErrorRecord unwrap: a blank stderr line stringifies to its own type
#    name, which must not reach an operator-facing Detail column.
Check 'no RemoteException leak' $false ($r.Output -match 'RemoteException')
Check 'no empty trailing line'  $false ($r.Output -match '(\r?\n)\s*$')

# 3. The success path must be untouched.
$ok = & $m { Invoke-WouSchTasks @('/Query', '/FO', 'CSV', '/NH') }
Check 'local query succeeds'  0    $ok.Code
Check 'local query has rows' $true ($ok.Output.Length -gt 20)

# 4. Test-WouTarget: Note is the reachability reason and nothing else. A
#    scheduled-task query we are not allowed to make must not populate it.
$info = Test-WouTarget -ComputerName $env:COMPUTERNAME
Check 'self is reachable'     $true  $info.Reachable
Check 'self admin share'      $true  $info.AdminShare
Check 'Note stays empty'      $true  ([string]::IsNullOrEmpty($info.Note))
Check 'Busy is a real bool'   $true  ($info.Busy -is [bool])
Check 'no BusyTask claimed'   $true  ($null -eq $info.BusyTask)

# 5. And the guard's own predicate: a failed query must read as "not running",
#    never as running, whatever text came back with it.
Check 'failed query is not Running' $false ($r.Code -eq 0 -and $r.Output -match 'Running')

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
