# Build.ps1 - build the LockBox MSI with Master Packager Dev (mpdev).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File installer\Build.ps1 -Version 1.0.0
#
# Ships what is committed: the payload is git HEAD (with git's line endings), minus the repo-only files
# (README images, this installer folder, git config). Commit first; uncommitted edits are not included.
# Adds app\installed, which tells LockBox it runs from Program Files and keeps each user's state in
# %LOCALAPPDATA%\LockBox. Output: installer\output\LockBox_<version>_x64.msi
param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path $here
$stage = Join-Path $here 'build'

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
$tar = Join-Path $here 'build.tar'
& git -C $repo archive --format=tar -o $tar HEAD
if ($LASTEXITCODE) { throw "git archive failed (exit $LASTEXITCODE)" }
& "$env:SystemRoot\System32\tar.exe" -xf $tar -C $stage
if ($LASTEXITCODE) { throw "tar failed (exit $LASTEXITCODE)" }
Remove-Item -LiteralPath $tar
foreach ($p in 'assets', 'installer', '.gitignore', '.gitattributes') {
    $t = Join-Path $stage $p
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
}
Set-Content -LiteralPath (Join-Path $stage 'app\installed') -Encoding Ascii -Value @(
    'This LockBox was installed by its MSI. Its folder is read-only for users, so LockBox keeps each',
    'user''s state (runs, reports, recipes, lockbox.env) in %LOCALAPPDATA%\LockBox instead of data\.')

Push-Location $here
try {
    & mpdev build package.json --properties "`$.version=$Version"
    if ($LASTEXITCODE) { throw "mpdev build failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }
