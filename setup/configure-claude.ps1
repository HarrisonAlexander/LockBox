# configure-claude.ps1 - give Claude Code this LockBox's windows-sandbox-* skills as project skills.
#
# LockBox is CLI-only: Claude drives the sandbox with sbx.cmd (shell commands), not an MCP server. The
# skills cover both and fall back to the CLI. This mirrors app\sandbox-mcp\skills\windows-sandbox-* into
# <Workspace>\.claude\skills. Nothing outside the LockBox folder is touched. Idempotent, no absolute paths
# recorded, so it never needs re-running after a move. ASCII only (Windows PowerShell 5.1).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup\configure-claude.ps1               (LockBox root)
param([string]$Workspace)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Workspace) { $Workspace = $root }
if (-not [System.IO.Path]::IsPathRooted($Workspace)) { $Workspace = Join-Path $root $Workspace }

# One mirror per skill folder, so other project skills there are left alone.
$skillDst = Join-Path $Workspace '.claude\skills'
$skills = @(Get-ChildItem -LiteralPath (Join-Path $root 'app\sandbox-mcp\skills') -Directory -Filter 'windows-sandbox-*')
foreach ($s in $skills) {
    & robocopy.exe $s.FullName (Join-Path $skillDst $s.Name) /MIR /NJH /NJS /NFL /NDL /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $($s.Name) (exit $LASTEXITCODE)" }
    Write-Host "skill    $($s.Name)"
}
Write-Host "Done. Start (or restart) Claude Code in $Workspace to load them."
