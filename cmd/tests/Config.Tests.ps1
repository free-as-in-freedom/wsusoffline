# Configuration, target-file parsing and staging rules.
#
# Two of these drive Invoke-HostRun against a name that resolves nowhere, to
# prove the preflight refuses before it stages anything. Each costs an SMB
# connect timeout, so this suite sits at about twenty seconds - that is the
# test waiting, not the test hanging.
$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'cmd\WsusOfflineRemote.psm1'
$modulePath = $ModulePath
Import-Module $modulePath -Force

$pass = 0; $fail = 0
function Check($name, $expected, $actual) {
    $ok = ($expected -eq $actual)
    if ($ok) { $script:pass++ } else { $script:fail++ }
    '{0} {1}: expected [{2}] got [{3}]' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $expected, $actual
}

$sandbox = Join-Path $env:TEMP 'wou-mod-test4'
if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
$null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'payload\cmd') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'log') -Force
Set-Content (Join-Path $sandbox 'payload\cmd\DoUpdate.cmd') -Value '@exit /b 0' -Encoding Ascii

$common = @{
    PayloadSource = Join-Path $sandbox 'payload'
    LogDir        = Join-Path $sandbox 'log'
    Stamp         = '20260831-120000'
    PollSeconds   = 1
    TimeoutMinutes = 1
}

# An unreachable host must be classified without a task being created anywhere,
# and must still come back with a populated Duration - the summary table formats
# that column for every row.
foreach ($mode in 'Install', 'Scan') {
    $r = Invoke-HostRun -TargetHost 'wou-no-such-host-31aug' -Mode $mode @common
    Check "$mode unreachable status"   'Unreachable' $r.Status
    Check "$mode unreachable name"     'wou-no-such-host-31aug' $r.ComputerName
    Check "$mode unreachable mode"     $mode $r.Mode
    Check "$mode unreachable duration" $true ($null -ne $r.Duration)
    Check "$mode unreachable detail"   $true ([bool]$r.Detail)
    Check "$mode unreachable no log"   $null $r.Log
}

# The same call through Start-Job, which is how both front ends run it: proves
# the module import and the splatted hashtable survive job serialisation.
$worker = {
    param([string] $ModulePath, [hashtable] $Params)
    Import-Module $ModulePath -Force -ErrorAction Stop
    Invoke-HostRun @Params
}
$params = $common.Clone()
$params.TargetHost = 'wou-no-such-host-31aug'
$params.Mode       = 'Scan'
$params.Credential = $null
$job = Start-Job -Name 'wou-job-test' -ScriptBlock $worker -ArgumentList $modulePath, $params
$null = Wait-Job -Job $job -Timeout 180
$out  = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
Remove-Job -Job $job -Force
$res  = $out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Status'] } | Select-Object -Last 1
Check 'job returned a result'  $true ($null -ne $res)
Check 'job result status'      'Unreachable' $res.Status
Check 'job result mode'        'Scan' $res.Mode
Check 'job result duration'    $true ($null -ne $res.Duration)
Check 'job left no log dir entries' 0 @(Get-ChildItem (Join-Path $sandbox 'log') -Force).Count

# The config the front ends display must match what the worker actually uses.
$cfg = Get-WouRemoteConfig
Check 'install task name' 'WOUOfflineUpdate' $cfg.InstallTaskName
Check 'scan task name'    'WOUOfflineScan'   $cfg.ScanTaskName
Check 'payload dir'       'wsusoffline'      $cfg.PayloadDir
Check 'scan dir'          'scan'             $cfg.ScanDir
$cfg.PayloadDir = 'tampered'
Check 'config is a copy'  'wsusoffline' (Get-WouRemoteConfig).PayloadDir

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
