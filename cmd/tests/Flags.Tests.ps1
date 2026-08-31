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

$sandbox = Join-Path $env:TEMP 'wou-mod-test'
if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
$null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'md') -Force

$keys = @(
    'upgradebuilds','updatercerts','instdotnet35','instdotnet4','instwmf','updatedotnet5',
    'updatecpp','skipieinst','skipdefs','skipdynamic','all','excludestatics','seconly'
)
$stripped = @('autoreboot','shutdown','showlog','monitoron')

# --- all switches on -> all 15 flags, nothing stripped leaking ---------------
$allOn = @('[Installation]') + ($keys | ForEach-Object { "$_=Enabled" }) +
         @('[Control]','verify=Enabled','autoreboot=Enabled','shutdown=Enabled',
           '[Messaging]','showdismprogress=Enabled','showlog=Enabled','monitoron=Enabled')
$iniAllOn = Join-Path $sandbox 'all-on.ini'
Set-Content $iniAllOn -Value $allOn
$f = Get-UpdateFlags -IniPath $iniAllOn -ClientDir $sandbox
Check 'all-on flag count' 15 (@($f -split ' ').Count)
Check 'all-on has no stripped flag' 0 @($stripped | Where-Object { $f -match "/$_" }).Count

# --- all switches off -> nothing --------------------------------------------
$allOff = @('[Installation]') + ($keys | ForEach-Object { "$_=Disabled" }) +
          @('[Control]','verify=Disabled','[Messaging]','showdismprogress=Disabled')
$iniAllOff = Join-Path $sandbox 'all-off.ini'
Set-Content $iniAllOff -Value $allOff
Check 'all-off is empty' '' (Get-UpdateFlags -IniPath $iniAllOff -ClientDir $sandbox)

# --- empty/absent ini -> the UpdateInstaller.au3 defaults -------------------
$expectDefault = '/upgradebuilds /updatercerts /updatecpp /verify'
Check 'absent ini uses defaults' $expectDefault (Get-UpdateFlags -IniPath (Join-Path $sandbox 'nope.ini') -ClientDir $sandbox)
$iniEmpty = Join-Path $sandbox 'empty.ini'
Set-Content $iniEmpty -Value ''
Check 'empty ini uses defaults' $expectDefault (Get-UpdateFlags -IniPath $iniEmpty -ClientDir $sandbox)

# --- the repository's real ini ----------------------------------------------
$realIni = (Join-Path $RepoRoot 'client\UpdateInstaller.ini')
if (Test-Path $realIni) {
    $rf = Get-UpdateFlags -IniPath $realIni -ClientDir $sandbox
    Check 'real ini flag count' 4 (@($rf -split ' ').Count)
    Check 'real ini has no stripped flag' 0 @($stripped | Where-Object { $rf -match "/$_" }).Count
}

# --- /verify dropped, with a warning, when md\ is absent --------------------
$noMd = Join-Path $sandbox 'nomd'
$null = New-Item -ItemType Directory -Path $noMd -Force
$warn = @()
$vf = Get-UpdateFlags -IniPath $iniAllOn -ClientDir $noMd -WarningVariable warn -WarningAction SilentlyContinue
Check 'verify dropped without md' $false ($vf -match '/verify')
Check 'verify drop warned' $true ($warn.Count -ge 1)
Check 'other flags survive verify drop' 14 (@($vf -split ' ').Count)

# --- scan mode narrows to the four listing switches ------------------------
$sf = Get-UpdateFlags -IniPath $iniAllOn -ClientDir $sandbox -ScanOnly
Check 'scan flag count' 4 (@($sf -split ' ').Count)
Check 'scan flags exact' '/all /excludestatics /seconly /verify' $sf
Check 'scan drops install flags' $false ($sf -match 'updatecpp|upgradebuilds|instdotnet')

'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
