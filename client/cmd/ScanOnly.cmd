@echo off
rem *** Author: T. Wittrock, Kiel ***
rem ***   - Community Edition -   ***
rem ***
rem *** Scan-only sibling of DoUpdate.cmd. Determines which updates apply to
rem *** this machine and which of them are present in the payload this script
rem *** was copied with - and installs nothing.
rem ***
rem *** Driven by cmd\Invoke-RemoteUpdate.ps1 -ScanOnly and by
rem *** cmd\Show-RemoteUpdateGui.ps1, but it also runs perfectly well by hand
rem *** from an elevated prompt in client\cmd.
rem ***
rem *** Every block below is a port of the DoUpdate.cmd lines named in its
rem *** comment, so that the two files can be read side by side. What is left
rem *** out is everything between DoUpdate.cmd lines 232 and 1394, which is the
rem *** installing part: servicing stack, build upgrades, WUA, IE, Edge, .NET,
rem *** WMF, Defender definitions and Office service packs.
rem ***
rem *** Results are written to ..\scan\ :
rem ***   MissingUpdateIds.txt - kbId,UpdateGUID per update this machine needs
rem ***   UpdatesToInstall.txt - the payload files that would be installed
rem ***   scan.log             - progress and warnings, in particular the
rem ***                          "Warning: Update ... not found" lines, each of
rem ***                          which means this machine needs an update that
rem ***                          has not been downloaded
rem ***   scanresult.txt       - this script's exit code, for callers polling
rem ***                          over the network
rem ***
rem *** Note that a scan is not completely without side effects: the Windows
rem *** Update Agent COM API needs the 'wuauserv' service to be startable, so
rem *** :EnableWUSvc and :AdjustWUSvc below temporarily enable and restart it
rem *** exactly as DoUpdate.cmd does, restoring the original settings again.
rem ***
rem *** Exit codes: 0 success
rem ***             1 error, see ..\scan\scan.log
rem ***             2 not running with administrative privileges
rem ***             3 unsupported operating system, architecture or language
rem ***             4 update catalogue ..\wsus\wsusscn2.cab is missing
rem ***             5 environment variable TEMP is unusable

verify other 2>nul
setlocal enableextensions
if errorlevel 1 goto NoExtensions

rem clear vars storing parameters
set LIST_MODE_IDS=
set LIST_MODE_UPDATES=
set IGNORE_BL=
set VERIFY_MODE=

if "%DIRCMD%" NEQ "" set DIRCMD=

cd /D "%~dp0"

set WSUSOFFLINE_VERSION=12.7 (b82)
title %~n0 %*
echo Starting WSUS Offline Update scan - Community Edition - v. %WSUSOFFLINE_VERSION% at %TIME%...

rem *** Prepare the result directory ***
rem Kept beside the payload rather than in %SystemRoot%, so that a caller can
rem read the results back over the admin share and so that /MIR clears them on
rem the next copy.
set SCAN_DIR=..\scan
if not exist %SCAN_DIR%\nul md %SCAN_DIR%
if not exist %SCAN_DIR%\nul goto NoScanDir

rem *** Log into the payload, not into %SystemRoot%\wsusofflineupdate.log ***
rem A scan then leaves the machine's installation history untouched, and the
rem caller gets one self-contained file. ListUpdatesToInstall.cmd and
rem ListUpdateFile.cmd both honour UPDATE_LOGFILE. The path stays relative
rem because those scripts expand it unquoted.
rem The one exception is ListMissingUpdateIds.vbs, which writes its own few
rem lines to %SystemRoot%\wsusofflineupdate.log directly (its line 15) - but only
rem when /all or /seconly makes it hide or reveal an update.
set UPDATE_LOGFILE=%SCAN_DIR%\scan.log
if exist %UPDATE_LOGFILE% del %UPDATE_LOGFILE%
goto Start

:Log
echo %DATE% %TIME% - %~1>>%UPDATE_LOGFILE%
goto :eof

:Start
call :Log "Info: Starting WSUS Offline Update scan - Community Edition - v. %WSUSOFFLINE_VERSION%"
call :Log "Info: Used path %~dp0 on %COMPUTERNAME% (user: %USERNAME%)"

:EvalParams
rem Only the switches that change what gets listed are accepted. Anything that
rem would install something is refused rather than quietly ignored, so that a
rem caller cannot turn a scan into an installation by accident.
if "%1"=="" goto NoMoreParams
set PARAM_OK=
if /i "%1"=="/all" (
  set LIST_MODE_IDS=/all
  set PARAM_OK=1
)
if /i "%1"=="/seconly" (
  set LIST_MODE_IDS=/seconly
  set PARAM_OK=1
)
if /i "%1"=="/excludestatics" (
  set LIST_MODE_UPDATES=/excludestatics
  set PARAM_OK=1
)
if /i "%1"=="/ignoreblacklist" (
  set IGNORE_BL=/ignoreblacklist
  set PARAM_OK=1
)
if /i "%1"=="/verify" (
  set VERIFY_MODE=/verify
  set PARAM_OK=1
)
if not defined PARAM_OK goto InvalidParams
call :Log "Info: Option %1 detected"
shift /1
goto EvalParams

:NoMoreParams
rem *** Check the TEMP directory (DoUpdate.cmd:94-97) ***
if "%TEMP%"=="" goto NoTemp
pushd "%TEMP%"
if errorlevel 1 goto NoTempDir
popd

rem *** Locate the tools, Sysnative aware (DoUpdate.cmd:99-116) ***
if exist %SystemRoot%\Sysnative\cscript.exe (
  set CSCRIPT_PATH=%SystemRoot%\Sysnative\cscript.exe
) else (
  set CSCRIPT_PATH=%SystemRoot%\System32\cscript.exe
)
if not exist %CSCRIPT_PATH% goto NoCScript
if exist %SystemRoot%\Sysnative\reg.exe (
  set REG_PATH=%SystemRoot%\Sysnative\reg.exe
) else (
  set REG_PATH=%SystemRoot%\System32\reg.exe
)
if not exist %REG_PATH% goto NoReg
if exist %SystemRoot%\Sysnative\sc.exe (
  set SC_PATH=%SystemRoot%\Sysnative\sc.exe
) else (
  set SC_PATH=%SystemRoot%\System32\sc.exe
)
if not exist %SC_PATH% goto NoSc

rem *** Check user's privileges (DoUpdate.cmd:118-122) ***
echo Checking user's privileges...
if not exist ..\bin\IfAdmin.exe goto NoIfAdmin
..\bin\IfAdmin.exe
if not errorlevel 1 goto NoAdmin

rem *** Determine system's properties (DoUpdate.cmd:124-139) ***
echo Determining system's properties...
%CSCRIPT_PATH% //Nologo //B //E:vbs DetermineSystemProperties.vbs /nodebug
if errorlevel 1 goto NoSysEnvVars
if not exist "%TEMP%\SetSystemEnvVars.cmd" goto NoSysEnvVars
call "%TEMP%\SetSystemEnvVars.cmd"
del "%TEMP%\SetSystemEnvVars.cmd"
if "%SystemDirectory%"=="" set SystemDirectory=%SystemRoot%\system32
if "%OS_ARCH%"=="" (
  if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (set OS_ARCH=x64) else (
    if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" (set OS_ARCH=x64) else (set OS_ARCH=x86)
  )
)
if /i "%OS_ARCH%"=="x64" (set HASHDEEP_PATH=..\bin\hashdeep64.exe) else (set HASHDEEP_PATH=..\bin\hashdeep.exe)

rem *** Set target environment variables (DoUpdate.cmd:141-157) ***
if "%OS_VER_MAJOR%"=="" goto UnsupOS
call SetTargetEnvVars.cmd
rem *** Check operating system, matching DoUpdate.cmd:144-153 name for name ***
if "%OS_NAME%"=="" goto UnsupOS
if "%OS_NAME%"=="w2k" goto UnsupOS
if "%OS_NAME%"=="wxp" goto UnsupOS
if "%OS_NAME%"=="w2k3" goto UnsupOS
if "%OS_NAME%"=="w60" goto UnsupOS
if "%OS_NAME%"=="w61" goto UnsupOS
if "%OS_NAME%"=="w62" goto UnsupOS
if "%OS_NAME%"=="w63" goto UnsupOS
for %%i in (x86 x64) do (if /i "%OS_ARCH%"=="%%i" goto ValidArch)
goto UnsupArch
:ValidArch
if "%OS_LANG%"=="" goto UnsupLang

echo Found Microsoft Windows version: %OS_VER_MAJOR%.%OS_VER_MINOR%.%OS_VER_BUILD%.%OS_VER_REVIS% (%OS_NAME% %OS_ARCH% %OS_LANG%)
call :Log "Info: Found Microsoft Windows version %OS_VER_MAJOR%.%OS_VER_MINOR%.%OS_VER_BUILD%.%OS_VER_REVIS% (%OS_NAME% %OS_ARCH% %OS_LANG%)"
if "%O2K16_VER_MAJOR%" NEQ "" (
  echo Found Microsoft Office 2016 version: %O2K16_VER_MAJOR%.%O2K16_VER_MINOR%.%O2K16_VER_BUILD%.%O2K16_VER_REVIS% ^(o2k16 %O2K16_ARCH% %O2K16_LANG%^)
  call :Log "Info: Found Microsoft Office 2016 version %O2K16_VER_MAJOR%.%O2K16_VER_MINOR%.%O2K16_VER_BUILD%.%O2K16_VER_REVIS% (o2k16 %O2K16_ARCH% %O2K16_LANG%)"
)

rem *** Determine WUA support for the SHA2 signed catalogue (DoUpdate.cmd:1581-1586) ***
set WUA_SHA2_SUPPORT=0
if %WUA_VER_MAJOR% GTR %WUA_VER_SHA2_MAJOR% set WUA_SHA2_SUPPORT=1
if %WUA_VER_MAJOR% EQU %WUA_VER_SHA2_MAJOR% if %WUA_VER_MINOR% GTR %WUA_VER_SHA2_MINOR% set WUA_SHA2_SUPPORT=1
if %WUA_VER_MAJOR% EQU %WUA_VER_SHA2_MAJOR% if %WUA_VER_MINOR% EQU %WUA_VER_SHA2_MINOR% if %WUA_VER_BUILD% GTR %WUA_VER_SHA2_BUILD% set WUA_SHA2_SUPPORT=1
if %WUA_VER_MAJOR% EQU %WUA_VER_SHA2_MAJOR% if %WUA_VER_MINOR% EQU %WUA_VER_SHA2_MINOR% if %WUA_VER_BUILD% EQU %WUA_VER_SHA2_BUILD% if %WUA_VER_REVIS% GEQ %WUA_VER_SHA2_REVIS% set WUA_SHA2_SUPPORT=1

rem *** Check for the catalogue before anything with a side effect ***
rem DoUpdate.cmd tests this at its line 1613, after adjusting the service. A
rem scan is expected to be cheap and inert when there is nothing to scan
rem against, so the test is pulled forward: a payload with no wsusscn2.cab now
rem exits 4 without having touched wuauserv at all.
if not exist ..\wsus\wsusscn2.cab goto NoCatalog

rem *** Adjust service 'Windows Update' (DoUpdate.cmd:1587-1591) ***
echo Adjusting service 'Windows Update'...
call :EnableWUSvc
call :AdjustWUSvc

rem *** Verify the catalogue if asked to (DoUpdate.cmd:1592-1612) ***
if "%VERIFY_MODE%" NEQ "/verify" goto SkipVerifyCatalog
if not exist %HASHDEEP_PATH% (
  echo Warning: Hash computing/auditing utility %HASHDEEP_PATH% not found.
  call :Log "Warning: Hash computing/auditing utility %HASHDEEP_PATH% not found"
  goto SkipVerifyCatalog
)
if not exist ..\md\hashes-wsus.txt (
  echo Warning: Hash file hashes-wsus.txt not found.
  call :Log "Warning: Hash file hashes-wsus.txt not found"
  goto SkipVerifyCatalog
)
echo Verifying integrity of Windows Update catalog file...
%SystemRoot%\System32\findstr.exe /L /I /C:%% /C:wsusscn2.cab ..\md\hashes-wsus.txt >"%TEMP%\hash-wsusscn2.txt"
%HASHDEEP_PATH% -a -b -k "%TEMP%\hash-wsusscn2.txt" ..\wsus\wsusscn2.cab
if errorlevel 1 (
  del "%TEMP%\hash-wsusscn2.txt"
  goto CatalogIntegrityError
)
del "%TEMP%\hash-wsusscn2.txt"

:SkipVerifyCatalog
if "%OS_SHA2_SUPPORT%" NEQ "1" (
  echo Warning: Support for SHA2 signed updates is missing.
  call :Log "Warning: Support for SHA2 signed updates is missing"
)
if "%WUA_SHA2_SUPPORT%" NEQ "1" (
  echo Warning: Support for a SHA2 signed catalog file is missing. Missing updates might not be found.
  call :Log "Warning: Support for a SHA2 signed catalog file is missing"
)

rem *** List ids of missing updates (DoUpdate.cmd:1613-1628) ***
rem Lists left over from an earlier run would be read as this run's results, and
rem SYSTEM's TEMP survives between runs (cf. DoUpdate.cmd:1325 and 1521).
if exist "%TEMP%\MissingUpdateIds.txt" del "%TEMP%\MissingUpdateIds.txt"
if exist "%TEMP%\InstalledUpdateIds.txt" del "%TEMP%\InstalledUpdateIds.txt"
if exist "%TEMP%\UpdatesToInstall.txt" del "%TEMP%\UpdatesToInstall.txt"
echo %TIME% - Listing ids of missing updates (please be patient, this will take a while)...
copy /Y ..\wsus\wsusscn2.cab "%TEMP%" >nul
%CSCRIPT_PATH% //Nologo //E:vbs ListMissingUpdateIds.vbs %LIST_MODE_IDS%
if exist "%TEMP%\wsusscn2.cab" del "%TEMP%\wsusscn2.cab"
echo %TIME% - Done.
call :Log "Info: Listed ids of missing updates"

rem *** Keep the missing-id list now ***
rem ListUpdatesToInstall.cmd deletes it at its line 251, so copying it out
rem after the call would be too late.
if exist "%TEMP%\MissingUpdateIds.txt" (
  copy /Y "%TEMP%\MissingUpdateIds.txt" %SCAN_DIR%\MissingUpdateIds.txt >nul
) else (
  echo Info: No missing updates were reported for this machine.
  call :Log "Info: No missing updates were reported for this machine"
  break>%SCAN_DIR%\MissingUpdateIds.txt
)

rem *** List ids of installed updates (DoUpdate.cmd:1630-1636) ***
if "%LIST_MODE_IDS%"=="/all" goto ListInstFiles
if "%LIST_MODE_UPDATES%"=="/excludestatics" goto ListInstFiles
echo Listing ids of installed updates...
%CSCRIPT_PATH% //Nologo //B //E:vbs ListInstalledUpdateIds.vbs
call :Log "Info: Listed ids of installed updates"

:ListInstFiles
rem *** List update files (DoUpdate.cmd:1638-1643) ***
rem This is the step that writes a "Warning: Update file <name> (id: {...})
rem not found" or "Warning: Update <name> (id: {...}) not found" line for every
rem update this machine needs that the payload does not contain, and an
rem "Info: Skipped update <name> due to matching black list entry" line for the
rem ones the exclude lists drop (ListUpdatesToInstall.cmd:147-176, 232-246).
echo Listing update files...
call ListUpdatesToInstall.cmd %LIST_MODE_IDS% %LIST_MODE_UPDATES% %IGNORE_BL%
if errorlevel 1 goto ListError
call :Log "Info: Listed update files"

if exist "%TEMP%\UpdatesToInstall.txt" (
  copy /Y "%TEMP%\UpdatesToInstall.txt" %SCAN_DIR%\UpdatesToInstall.txt >nul
  del "%TEMP%\UpdatesToInstall.txt"
) else (
  break>%SCAN_DIR%\UpdatesToInstall.txt
)
if exist "%TEMP%\InstalledUpdateIds.txt" del "%TEMP%\InstalledUpdateIds.txt"

rem *** Stop here. No servicing stack extraction, no :InstallUpdates. ***
echo Scan complete.
call :Log "Info: Scan complete"
set SCAN_RESULT=0
goto EoF

rem ---------------------------------------------------------------------------
rem Subroutines - verbatim ports of DoUpdate.cmd:1395-1500. wuauserv has to be
rem startable for the Windows Update Agent COM API to work, so there is no
rem read-only path around this. Note that the original Start value is written
rem straight back, so the registry ends up as it was while the service stays
rem usable for the rest of this run.
rem ---------------------------------------------------------------------------

:EnableWUSvc
if "%WUSVC_ENABLED%"=="1" goto :eof
for /F "tokens=3" %%i in ('%REG_PATH% QUERY HKLM\SYSTEM\CurrentControlSet\services\wuauserv /v Start 2^>nul ^| %SystemRoot%\System32\find.exe /I "Start"') do set WUSVC_STVAL=%%i
for /F "tokens=3" %%i in ('%REG_PATH% QUERY HKLM\SYSTEM\CurrentControlSet\services\wuauserv /v DelayedAutoStart 2^>nul ^| %SystemRoot%\System32\find.exe /I "DelayedAutoStart"') do set WUSVC_STDEL=%%i
if /i "%WU_START_MODE%"=="Disabled" (
  echo Enabling service 'Windows Update' ^(wuauserv^) - previous state will be recovered later...
  call :Log "Info: Enabling service 'Windows Update' (wuauserv)"
  %SC_PATH% config wuauserv start= demand >nul 2>&1
  if errorlevel 1 (
    echo Warning: Enabling of service 'Windows Update' ^(wuauserv^) failed.
    call :Log "Warning: Enabling of service 'Windows Update' (wuauserv) failed"
  ) else (
    call :Log "Info: Enabled service 'Windows Update' (wuauserv)"
    set WUSVC_ENABLED=1
    if "%WUSVC_STVAL%" NEQ "" (
      %REG_PATH% ADD HKLM\SYSTEM\CurrentControlSet\services\wuauserv /v Start /t REG_DWORD /d %WUSVC_STVAL% /f >nul 2>&1
    )
    if "%WUSVC_STDEL%" NEQ "" (
      %REG_PATH% ADD HKLM\SYSTEM\CurrentControlSet\services\wuauserv /v DelayedAutoStart /t REG_DWORD /d %WUSVC_STDEL% /f >nul 2>&1
    )
  )
)
set WUSVC_STVAL=
set WUSVC_STDEL=
goto :eof

:WaitService
echo Waiting for service '%1' to reach state '%2' (timeout: %3s)...
call :Log "Info: Waiting for service '%1' to reach state '%2' (timeout: %3s)"
echo WScript.Sleep(2000)>"%TEMP%\Sleep2Seconds.vbs"
for /L %%i in (2,2,%3) do (
  for /F %%j in ('%CSCRIPT_PATH% //Nologo //E:vbs DetermineServiceState.vbs %1') do (
    if /i "%%j"=="%2" (
      call :Log "Info: Service '%1' reached state '%2'"
      del "%TEMP%\Sleep2Seconds.vbs"
      goto :eof
    )
  )
  %CSCRIPT_PATH% //Nologo //B //E:vbs "%TEMP%\Sleep2Seconds.vbs"
)
echo Warning: Service '%1' did not reach state '%2' in time
call :Log "Warning: Service '%1' did not reach state '%2' in time"
del "%TEMP%\Sleep2Seconds.vbs"
verify other 2>nul
goto :eof

:StopWUSvc
for /F %%i in ('%CSCRIPT_PATH% //Nologo //E:vbs DetermineServiceState.vbs wuauserv') do (
  if /i "%%i"=="Stopped" goto :eof
)
echo Stopping service 'Windows Update' (wuauserv)...
call :Log "Info: Stopping service 'Windows Update' (wuauserv)"
%SC_PATH% stop wuauserv >nul 2>&1
if errorlevel 1 (
  echo Warning: Stopping of service 'Windows Update' ^(wuauserv^) failed.
  call :Log "Warning: Stopping of service 'Windows Update' (wuauserv) failed"
) else (
  call :WaitService wuauserv Stopped 180
  if not errorlevel 1 call :Log "Info: Stopped service 'Windows Update' (wuauserv)"
)
goto :eof

:StartWUSvc
for /F %%i in ('%CSCRIPT_PATH% //Nologo //E:vbs DetermineServiceState.vbs wuauserv') do (
  if /i "%%i"=="Running" goto :eof
)
echo Starting service 'Windows Update' (wuauserv)...
call :Log "Info: Starting service 'Windows Update' (wuauserv)"
%SC_PATH% start wuauserv >nul 2>&1
if errorlevel 1 (
  echo Warning: Starting of service 'Windows Update' ^(wuauserv^) failed.
  call :Log "Warning: Starting of service 'Windows Update' (wuauserv) failed"
) else (
  call :WaitService wuauserv Running 60
  if not errorlevel 1 call :Log "Info: Started service 'Windows Update' (wuauserv)"
)
goto :eof

:AdjustWUSvc
for /F "tokens=3" %%i in ('%REG_PATH% QUERY "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" /v AUOptions 2^>nul ^| %SystemRoot%\System32\find.exe /I "AUOptions"') do set WUPOL_AUOP=%%i
for /F "tokens=3" %%i in ('%REG_PATH% QUERY HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoRebootWithLoggedOnUsers 2^>nul ^| %SystemRoot%\System32\find.exe /I "NoAutoRebootWithLoggedOnUsers"') do set WUPOL_NOAR=%%i
for /F "tokens=3" %%i in ('%REG_PATH% QUERY HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoUpdate 2^>nul ^| %SystemRoot%\System32\find.exe /I "NoAutoUpdate"') do set WUPOL_NOAU=%%i
if "%WUPOL_AUOP%" NEQ "" (
  %REG_PATH% ADD "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" /v AUOptions /t REG_DWORD /d 1 /f >nul 2>&1
)
if "%WUPOL_NOAR%" NEQ "" (
  %REG_PATH% ADD HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f >nul 2>&1
)
if "%WUPOL_NOAU%" NEQ "" (
  %REG_PATH% ADD HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul 2>&1
)
call :StopWUSvc
call :StartWUSvc
if "%WUPOL_AUOP%" NEQ "" (
  %REG_PATH% ADD "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" /v AUOptions /t REG_DWORD /d %WUPOL_AUOP% /f >nul 2>&1
)
if "%WUPOL_NOAR%" NEQ "" (
  %REG_PATH% ADD HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d %WUPOL_NOAR% /f >nul 2>&1
)
if "%WUPOL_NOAU%" NEQ "" (
  %REG_PATH% ADD HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoUpdate /t REG_DWORD /d %WUPOL_NOAU% /f >nul 2>&1
)
set WUPOL_AUOP=
set WUPOL_NOAR=
set WUPOL_NOAU=
goto :eof

rem ---------------------------------------------------------------------------
rem Error exits. Each sets SCAN_RESULT and falls through to :EoF, so that the
rem result file is written on every path a caller might be waiting on.
rem ---------------------------------------------------------------------------

:NoExtensions
echo ERROR: No command extensions available.
exit /b 1

:NoScanDir
echo ERROR: Could not create the result directory "%~dp0..\scan".
exit /b 1

:InvalidParams
echo ERROR: Invalid parameter: %1
echo Usage: %~n0 [/all ^| /seconly] [/excludestatics] [/ignoreblacklist] [/verify]
echo        This script only lists updates, so the installation switches of
echo        DoUpdate.cmd are rejected rather than quietly ignored.
call :Log "Error: Invalid parameter: %1"
set SCAN_RESULT=1
goto EoF

:NoTemp
echo ERROR: Environment variable TEMP not set.
call :Log "Error: Environment variable TEMP not set"
set SCAN_RESULT=5
goto EoF

:NoTempDir
echo ERROR: Directory "%TEMP%" not found.
call :Log "Error: Directory %TEMP% not found"
set SCAN_RESULT=5
goto EoF

:NoCScript
echo ERROR: Utility %CSCRIPT_PATH% not found.
call :Log "Error: Utility %CSCRIPT_PATH% not found"
set SCAN_RESULT=1
goto EoF

:NoReg
echo ERROR: Utility %REG_PATH% not found.
call :Log "Error: Utility %REG_PATH% not found"
set SCAN_RESULT=1
goto EoF

:NoSc
echo ERROR: Utility %SC_PATH% not found.
call :Log "Error: Utility %SC_PATH% not found"
set SCAN_RESULT=1
goto EoF

:NoIfAdmin
echo ERROR: Utility ..\bin\IfAdmin.exe not found.
call :Log "Error: Utility ..\bin\IfAdmin.exe not found"
set SCAN_RESULT=1
goto EoF

:NoAdmin
echo ERROR: Administrative privileges are required to scan for updates.
call :Log "Error: Administrative privileges are required to scan for updates"
set SCAN_RESULT=2
goto EoF

:NoSysEnvVars
echo ERROR: Determination of the system's properties failed.
call :Log "Error: Determination of the system's properties failed"
set SCAN_RESULT=1
goto EoF

:UnsupOS
echo ERROR: Unsupported operating system.
call :Log "Error: Unsupported operating system"
set SCAN_RESULT=3
goto EoF

:UnsupArch
echo ERROR: Unsupported architecture "%OS_ARCH%".
call :Log "Error: Unsupported architecture %OS_ARCH%"
set SCAN_RESULT=3
goto EoF

:UnsupLang
echo ERROR: Unsupported language.
call :Log "Error: Unsupported language"
set SCAN_RESULT=3
goto EoF

:NoCatalog
echo ERROR: Windows Update catalog file ..\wsus\wsusscn2.cab not found.
echo        Run UpdateGenerator to download it first.
call :Log "Error: Windows Update catalog file ..\wsus\wsusscn2.cab not found"
set SCAN_RESULT=4
goto EoF

:CatalogIntegrityError
echo ERROR: Integrity check of the Windows Update catalog file failed.
call :Log "Error: Integrity check of the Windows Update catalog file failed"
set SCAN_RESULT=1
goto EoF

:ListError
echo ERROR: Listing of update files failed.
call :Log "Error: Listing of update files failed"
set SCAN_RESULT=1
goto EoF

:EoF
rem The result file is what a caller polling the admin share waits for, so it is
rem written last and on every path that gets here.
if "%SCAN_RESULT%"=="" set SCAN_RESULT=1
> %SCAN_DIR%\scanresult.txt echo %SCAN_RESULT%
title %ComSpec%
endlocal & exit /b %SCAN_RESULT%
