$ErrorActionPreference = 'Stop'
# Resolved from this file's own location, so the suite runs from any
# checkout rather than only from the one it was written in.
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'cmd\WsusOfflineRemote.psm1'
# Deliberately reproduce the hardening that broke a bare-name call, and a path
# with a space in it, which is the other thing the wrapper has to survive.
$env:NoDefaultCurrentDirectoryInExePath = '1'

$psm1 = $ModulePath
$text = [System.IO.File]::ReadAllText($psm1)

# Take the wrapper text from the module itself, so this test cannot drift away
# from what actually gets written to the target.
$m = [regex]::Match($text, '(?s)\$wrapper = @\((.*?)\r?\n {12}\)')
if (-not $m.Success) { throw 'Could not find the wrapper block in the module.' }
"wrapper block found, $($m.Groups[1].Value.Trim().Split("`n").Count) lines"
$cfg = @{ ResultName = 'result.txt' }
$sandbox = Join-Path $env:TEMP 'wou wrap 5'      # NOTE: spaces, on purpose
if (Test-Path $sandbox) { [System.IO.Directory]::Delete($sandbox, $true) }
New-Item -ItemType Directory -Path (Join-Path $sandbox 'cmd') -Force | Out-Null

$stub = @'
@echo off
rem mimic DoUpdate.cmd:32, which sets its own working directory first
cd /D "%~dp0"
setlocal
echo STUB args: %*
if /i "%1"=="/rc3010" (endlocal & exit /b 3010)
if /i "%1"=="/rc3011" (endlocal & exit /b 3011)
if /i "%1"=="/rc0" (endlocal & exit /b 0)
endlocal & exit /b 42
'@
foreach ($n in 'DoUpdate.cmd', 'ScanOnly.cmd') {
    [System.IO.File]::WriteAllText((Join-Path $sandbox "cmd\$n"), ($stub -replace "`r?`n", "`r`n"))
}

$resultPath = Join-Path $sandbox $cfg.ResultName
$pass = 0; $fail = 0

foreach ($case in @(
    @{ Cmd = 'cmd\DoUpdate.cmd'; Flags = '/rc0 /verify /updatecpp'; Want = '0' }
    @{ Cmd = 'cmd\DoUpdate.cmd'; Flags = '/rc3010';                 Want = '3010' }
    @{ Cmd = 'cmd\DoUpdate.cmd'; Flags = '/rc3011';                 Want = '3011' }
    @{ Cmd = 'cmd\DoUpdate.cmd'; Flags = '/rcBogus';                Want = '42' }
    @{ Cmd = 'cmd\ScanOnly.cmd'; Flags = '/rc0 /all /seconly';      Want = '0' }
    @{ Cmd = 'cmd\ScanOnly.cmd'; Flags = '';                        Want = '42' }
)) {
    $targetCmd = $case.Cmd
    $Flags     = $case.Flags
    $wrapper   = Invoke-Expression ('@(' + $m.Groups[1].Value + ')')

    # CRLF, ASCII: cmd.exe will not run a batch file with bare LF reliably.
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'RunRemoteUpdate.cmd'),
        (($wrapper -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    if (Test-Path $resultPath) { [System.IO.File]::Delete($resultPath) }

    # Start from an unrelated working directory, the way a scheduled task does.
    Push-Location $env:SystemRoot
    $out = & $env:ComSpec /D /C (Join-Path $sandbox 'RunRemoteUpdate.cmd')
    Pop-Location

    $rc = if (Test-Path $resultPath) { (Get-Content $resultPath -Raw).Trim() } else { '<missing>' }
    $sawFlags = ($out -join '|') -match [regex]::Escape($Flags.Trim())
    $ok = ($rc -eq $case.Want) -and ($rc -match '^-?\d+$') -and ($Flags -eq '' -or $sawFlags)
    if ($ok) { $pass++ } else { $fail++ }
    '{0} {1,-16} {2,-26} result.txt=[{3}] want [{4}] stub saw flags: {5}' -f `
        $(if ($ok) { 'ok  ' } else { 'FAIL' }), $targetCmd, "'$Flags'", $rc, $case.Want, $sawFlags
}

$w = [System.IO.File]::ReadAllText((Join-Path $sandbox 'RunRemoteUpdate.cmd'))
$crlf = $w.Contains("`r`n") -and -not ($w -match "(?<!`r)`n")
if ($crlf) { $pass++ } else { $fail++ }
'{0} wrapper is CRLF throughout' -f $(if ($crlf) { 'ok  ' } else { 'FAIL' })

$byPath = $w -match 'call "%~dp0cmd.(DoUpdate|ScanOnly)\.cmd"'
if ($byPath) { $pass++ } else { $fail++ }
'{0} target is called by full path, not by bare name' -f $(if ($byPath) { 'ok  ' } else { 'FAIL' })

''
'{0} passed, {1} failed' -f $pass, $fail
"RESULT pass=$pass fail=$fail"
[System.IO.Directory]::Delete($sandbox, $true)
