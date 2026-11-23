# open-claude.ps1 - opens Claude Code in its own terminal window, in the LockBox folder. LockBox runs it
# when an interactive session starts, and from the session page's Open Claude button. Claude runs on this
# PC (not in the sandbox). The folder's CLAUDE.md tells it a sandbox is running and to drive it with the
# sbx CLI and the windows-sandbox-* skills. sbx shares state with the launcher, so Claude works on the
# same sandbox the window shows.
#
# CLI-only and portable: LockBox's root goes first on PATH, so "sbx" in the skills runs this LockBox's
# sbx.cmd, even on a PC with another sbx install. --strict-mcp-config with no config loads no MCP
# servers, so a sandbox MCP server registered on the host (a different install with its own state) can't
# be picked up by mistake. The skills are mirrored into .claude\skills on every launch.
# Loads the normal PowerShell profile on purpose, so claude resolves exactly as in your own shells.
param([string]$Workspace)

# No ErrorActionPreference Stop: 5.1 would turn claude's stderr notices into terminating errors.
$host.UI.RawUI.WindowTitle = 'Claude - LockBox'

$root = $env:LOCKBOX_ROOT
if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if (-not $Workspace) { $Workspace = $root }
Set-Location -LiteralPath $Workspace

$claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $claude -and (Test-Path "$env:USERPROFILE\.local\bin\claude.cmd")) { $claude = "$env:USERPROFILE\.local\bin\claude.cmd" }
if (-not $claude -and (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")) { $claude = "$env:USERPROFILE\.local\bin\claude.exe" }
if (-not $claude) {
    Write-Host 'Claude Code (claude) was not found on this PC. Install it, then press Open Claude again.' -ForegroundColor Red
    Write-Host '  irm https://claude.ai/install.ps1 | iex' -ForegroundColor DarkGray
    return
}

$env:PATH = "$root;$env:PATH"

# Display: the plain monochrome look (NO_COLOR) on a true-colour xterm terminal type, the same in every
# Claude window LockBox opens. LOCKBOX_CLAUDE_COLOR=1 in data\lockbox.env keeps Claude's colours instead.
if ($env:LOCKBOX_CLAUDE_COLOR -eq '1') { Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue }
else { $env:NO_COLOR = '1' }
$env:COLORTERM = 'truecolor'
$env:TERM = 'xterm-256color'
# A LockBox started from inside another Claude Code session must not hand that session's identity on.
Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' -or $_.Name -in 'CLAUDECODE', 'CLAUDE_PID' } |
    ForEach-Object { Remove-Item "Env:$($_.Name)" }
# An MSI install ships the skills already and its folder is read-only, so only a portable copy syncs them.
if (-not (Test-Path -LiteralPath (Join-Path $root 'app\installed'))) {
    & (Join-Path $root 'setup\configure-claude.ps1') -Workspace $Workspace | Out-Null
}

Write-Host 'Claude Code on this PC, driving the running sandbox with the sbx CLI.' -ForegroundColor Cyan
Write-Host 'Try: "take a screenshot of the sandbox", "install 7-Zip in the sandbox and test it", "what windows are open?"' -ForegroundColor DarkGray
Write-Host ''
& $claude --strict-mcp-config
