# install-skills.ps1 - OPTIONAL. Junction this LockBox's windows-sandbox-* skills into
# %USERPROFILE%\.claude\skills so Claude Code sees them in every folder. Not needed for Claude started
# in the LockBox folder or from the Open Claude button: those get the skills as project skills.
#
# Never takes over a skill another install owns: an existing folder or junction that points anywhere
# other than this LockBox is left alone and reported. /uninstall removes only junctions into this
# LockBox. Junctions need no admin rights. ASCII only (Windows PowerShell 5.1).
#
#   setup\install-skills.cmd [/uninstall]
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src  = Join-Path $root 'app\sandbox-mcp\skills'
$dest = Join-Path $env:USERPROFILE '.claude\skills'
New-Item -ItemType Directory -Force $dest | Out-Null

function Get-JunctionTarget([string]$path) {
    $item = Get-Item -LiteralPath $path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $t = @($item.Target)[0]
    if ($t) { $t -replace '^\\\\\?\\', '' }
}

$skipped = 0
$skills = @(Get-ChildItem -LiteralPath $src -Directory -Filter 'windows-sandbox-*')
foreach ($s in $skills) {
    $link = Join-Path $dest $s.Name
    $exists = Test-Path -LiteralPath $link
    $target = if ($exists) { Get-JunctionTarget $link }
    $ours = $target -and ([IO.Path]::GetFullPath($target).TrimEnd('\') -ieq $s.FullName.TrimEnd('\'))

    if ($Uninstall) {
        if ($ours) { [IO.Directory]::Delete($link); Write-Host "removed  $($s.Name)" }
        elseif ($exists) { Write-Host "kept     $($s.Name)  - not this LockBox's ($(if ($target) { $target } else { 'real folder' }))" }
        continue
    }
    if ($ours) { Write-Host "ok       $($s.Name)  - already linked here"; continue }
    if ($exists) {
        Write-Host "skip     $($s.Name)  - already provided by $(if ($target) { $target } else { 'a real folder' })"
        $skipped++
        continue
    }
    New-Item -ItemType Junction -Path $link -Target $s.FullName | Out-Null
    Write-Host "linked   $($s.Name)  -> $($s.FullName)"
}
if ($skipped) { Write-Host "$skipped skill(s) left alone: another install already provides them, and they work with LockBox's sbx too." }
if (-not $Uninstall) { Write-Host 'Restart Claude Code (or start a new session) to load them.' }
