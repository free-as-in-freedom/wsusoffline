# Regression test for the admin-share diagnosis in Test-WouTarget.
#
# Test-Path answers $false identically for a dropped TCP 445, a machine that is
# switched off, and a wrong password. Those are three different fixes, so the
# preflight now reads the Win32 error out of the exception's HResult and names
# the fix that error implies. Verified live against a workgroup VM that answered
# with 1326 while its firewall was wide open - the old wording sent the operator
# to check the firewall.
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

# Unresolvable on any network, so every machine gets the same answer.
$script:DeadHost = 'wou-no-such-host-zzz'
$modulePath = $ModulePath
Import-Module $modulePath -Force
$m = Get-Module WsusOfflineRemote

# -- the helper --------------------------------------------------------------
$ok = & $m { Test-WouAdminShare "\\$env:COMPUTERNAME\C$" }
Check 'own share reads'        $true $ok.Ok
Check 'own share has no error' 0     $ok.Win32

# A name that resolves nowhere, rather than an address out of one particular
# lab subnet - this has to fail identically on any machine that runs the suite.
# Both forms were measured at error 53, but the assertion takes the whole
# network-unreachable class so that a differently configured resolver handing
# back 67 cannot fail the suite over a distinction that does not matter here.
#
# Expect anywhere from a few seconds to twenty: a name that has already failed
# to resolve is answered from the negative DNS cache, while a cold cache pays
# the full SMB connect timeout. Either way the code class is the same, which is
# the reason the assertion tests the class and not the wall clock.
$dead = & $m { param($SharePath) Test-WouAdminShare $SharePath } "\\$script:DeadHost\C$"
Check 'dead host is not ok'        $false $dead.Ok
Check 'dead host is network-class'  $true ($dead.Win32 -in 53, 64, 67, 1231)
Check 'dead host keeps the text'    $true ([bool]$dead.Message)

# A path that cannot be a share at all must still classify, not throw.
$bogus = & $m { Test-WouAdminShare 'Q:\no\such\place' }
Check 'bad local path is not ok' $false $bogus.Ok
Check 'bad local path classified' $true ($bogus.Win32 -ne 0)

# -- the object ---------------------------------------------------------------
$self = Test-WouTarget -ComputerName $env:COMPUTERNAME
Check 'self admin share'        $true $self.AdminShare
Check 'self error is zero'      0     $self.AdminShareError
Check 'self Note empty'         $true ([string]::IsNullOrEmpty($self.Note))

$off = Test-WouTarget -ComputerName $script:DeadHost
Check 'off: not reachable'         $false $off.Reachable
Check 'off: network-class error'    $true ($off.AdminShareError -in 53, 64, 67, 1231)
Check 'off: says no response'       $true ($off.Note -eq "No response from $script:DeadHost.")
# A machine that does not answer ping must not be blamed on the firewall or on
# credentials - that is the misdirection this whole change is about.
Check 'off: no firewall advice' $false ($off.Note -match 'firewall')
Check 'off: no credential advice' $false ($off.Note -match 'Credential')

# -- the mapping is unambiguous ---------------------------------------------
# PowerShell's switch runs every matching clause, so two clauses listing the
# same Win32 code would emit two concatenated messages. Read the code sets back
# out of the source and require them to be disjoint.
$src = [System.IO.File]::ReadAllText($modulePath)
$sets = @()
foreach ($match in [regex]::Matches($src, '\{\s*\$_\s+-in\s+([\d,\s]+)\s*\}')) {
    $sets += ,@($match.Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() })
}
Check 'found both -in code sets' 2 $sets.Count
$overlap = @()
if ($sets.Count -ge 2) { $overlap = @($sets[0] | Where-Object { $sets[1] -contains $_ }) }
Check 'code sets are disjoint'  0 $overlap.Count
$all = @($sets | ForEach-Object { $_ }) + 1219
Check 'no duplicate codes overall' $all.Count (($all | Sort-Object -Unique).Count)
# The codes that actually matter, so a future tidy-up cannot silently drop them.
foreach ($code in 5, 1326, 1385) {
    Check "credential code $code is classified" $true ($sets[0] -contains $code)
}
foreach ($code in 53, 67) {
    Check "network code $code is classified"    $true ($sets[1] -contains $code)
}

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
