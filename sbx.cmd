@echo off
REM ===========================================================================
REM  sbx - the sandbox-mcp CLI, run from this LockBox folder.
REM
REM      sbx doctor                          can this PC run Windows Sandbox?
REM      sbx run app.exe --network off       clean-machine test + report
REM      sbx install-test setup.msi          install and stop (sandbox kept)
REM      sbx uninstall-test                  later: uninstall + leftovers diff
REM      sbx detonate file.js                what does this file do (no network)
REM
REM  Uses app\node\node.exe, app\lockbox\sbx.mjs (LockBox's install/uninstall
REM  split) and app\sandbox-mcp. State goes to data\home
REM  (SANDBOX_MCP_HOME), shared with LockBox.cmd.
REM  Loads data\lockbox.env if present (an already-set variable wins).
REM  An MSI install (app\installed exists) is read-only for users, so there
REM  data\ is %LOCALAPPDATA%\LockBox instead.
REM  Nothing here records an absolute path; %~dp0 is resolved on every run.
REM ===========================================================================
setlocal EnableExtensions
set "_SBX_DATA=%~dp0data"
if exist "%~dp0app\installed" set "_SBX_DATA=%LOCALAPPDATA%\LockBox"
if exist "%_SBX_DATA%\lockbox.env" for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%_SBX_DATA%\lockbox.env") do if not defined %%A set "%%A=%%B"
if not defined SANDBOX_MCP_HOME set "SANDBOX_MCP_HOME=%_SBX_DATA%\home"
set "PATH=%~dp0app\node;%PATH%"
REM  wsb.exe is a Store app alias; hosts and MCP clients with a trimmed PATH miss it
where wsb.exe >nul 2>&1 || set "PATH=%PATH%;%LOCALAPPDATA%\Microsoft\WindowsApps"
set "_SBX_NODE=%~dp0app\node\node.exe"
if not exist "%_SBX_NODE%" set "_SBX_NODE=node"
"%_SBX_NODE%" "%~dp0app\lockbox\sbx.mjs" %*
exit /b %errorlevel%
