@echo off
rem *** Custom finalization hook ***
rem Called by DownloadUpdates.cmd once a download run completes.
rem Regenerates ..\..\log\DownloadReport.txt so the report always reflects
rem the current state of the repository.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\New-DownloadReport.ps1"
exit /b 0
