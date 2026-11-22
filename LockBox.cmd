@echo off
REM ===========================================================================
REM  LockBox - portable Windows Sandbox launcher (sandbox-mcp + Sandbox Launcher).
REM  Double-click this file, or run it from any shell. Returns immediately; the
REM  window runs on its own.
REM
REM  Runs on Windows PowerShell 5.1 + WPF (inbox on Windows 10/11) and the
REM  bundled app\node\node.exe, so nothing is installed on the host. State
REM  (runs, reports, recipes, job logs) stays in data\ next to this file.
REM  The host still needs the Windows Sandbox feature: use "Check this PC".
REM ===========================================================================
setlocal
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\gui\SbxGui.ps1" %*
exit /b 0
