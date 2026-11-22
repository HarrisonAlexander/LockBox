@echo off
REM ===========================================================================
REM  OPTIONAL. Junction this LockBox's windows-sandbox-* skills into
REM  %USERPROFILE%\.claude\skills (every Claude session on this PC). Skills
REM  another install already provides are left alone. See install-skills.ps1.
REM
REM      setup\install-skills.cmd
REM      setup\install-skills.cmd /uninstall     (only this LockBox's junctions)
REM ===========================================================================
setlocal
set "_LB_UNINSTALL="
if /i "%~1"=="/uninstall" set "_LB_UNINSTALL=-Uninstall"
if /i "%~1"=="--uninstall" set "_LB_UNINSTALL=-Uninstall"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-skills.ps1" %_LB_UNINSTALL%
exit /b %errorlevel%
