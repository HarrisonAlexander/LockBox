# Test-Install.ps1 - runs in a Windows Sandbox guest after the LockBox MSI is installed (see the mpdev
# skill's Test-MsiInSandbox.ps1). Throws on the first failure.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramFiles 'LockBox'

foreach ($f in 'LockBox.cmd', 'sbx.cmd', 'CLAUDE.md', 'app\installed', 'app\gui\SbxGui.ps1', 'app\gui\box.ico',
               'app\node\node.exe', 'app\lockbox\sbx.mjs', 'app\sandbox-mcp\src\cli.js',
               '.claude\skills\windows-sandbox-setup\SKILL.md', 'setup\configure-claude.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { throw "missing: $f" }
}
foreach ($f in 'assets', 'installer', '.gitignore') {
    if (Test-Path -LiteralPath (Join-Path $dir $f)) { throw "repo-only file shipped: $f" }
}
Write-Output "files ok ($((Get-ChildItem $dir -Recurse -File -Force).Count) files)"

$lnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\LockBox.lnk'
if (-not (Test-Path -LiteralPath $lnk)) { throw "missing Start menu shortcut: $lnk" }
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
if ($sc.TargetPath -ne (Join-Path $dir 'LockBox.cmd')) { throw "shortcut target: $($sc.TargetPath)" }
Write-Output "shortcut ok -> $($sc.TargetPath) (icon $($sc.IconLocation))"

# The CLI from Program Files, with the bundled Node. A guest can't run a nested sandbox (no wsb), so use
# commands that don't need one: deps scans PE imports on the host side.
$ErrorActionPreference = 'Continue'   # native stderr is not a failure; exit codes are checked
$out = & cmd /c "`"$dir\sbx.cmd`" deps `"$dir\app\node\node.exe`"" 2>&1
if ($LASTEXITCODE) { throw "sbx deps exit $LASTEXITCODE`: $out" }
Write-Output "sbx deps ok ($(@($out).Count) lines)"
$doc = & cmd /c "`"$dir\sbx.cmd`" doctor" 2>&1
Write-Output "sbx doctor (inside a sandbox, so the Sandbox checks fail):"
$doc | ForEach-Object { Write-Output "  $_" }
if (-not ($doc -match 'Node\.js')) { throw 'doctor did not run the bundled Node.js' }

# State must go to %LOCALAPPDATA%\LockBox, never into the install folder.
& cmd /c "`"$dir\sbx.cmd`" status --json" 2>&1 | Out-Null
$state = Join-Path $env:LOCALAPPDATA 'LockBox'
Write-Output "state dir $state exists: $(Test-Path -LiteralPath $state)"
Get-ChildItem -LiteralPath $state -Recurse -Name -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Output "  $_" }
if (Test-Path -LiteralPath (Join-Path $dir 'data\home')) { throw 'state written into Program Files\LockBox\data\home' }
Write-Output 'nothing written into Program Files\LockBox\data'

# The GUI script parses on this guest's Windows PowerShell 5.1.
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $dir 'app\gui\SbxGui.ps1'), [ref]$null, [ref]$errs)
if ($errs) { throw "SbxGui.ps1 parse errors: $($errs[0])" }
Write-Output "SbxGui.ps1 parses on PowerShell $($PSVersionTable.PSVersion)"
