<#
.SYNOPSIS
    Demo for the Sandbox Launcher's "Run a PowerShell script" workflow: installs Chocolatey,
    then Google Chrome, Notepad++ and Firefox, and puts shortcuts on the desktop.

.DESCRIPTION
    Meant to run inside a throwaway Windows Sandbox with networking on. It changes the machine
    it runs on (installs software), so don't run it on your own PC.
    A log is written to C:\apps\install-choco-apps.log in the guest.
    Exit code: 0 when every package installed, 1 otherwise.

    Windows Sandbox enforces an Application Control policy that blocks unsigned executables, so
    packages that unzip with Chocolatey's bundled (unsigned) 7z.exe fail there. These three run
    their vendors' signed installers instead.

.PARAMETER Packages
    Chocolatey package ids to install. Default: googlechrome, notepadplusplus, firefox.
#>
[CmdletBinding()]
param(
    [string[]]$Packages = @('googlechrome', 'notepadplusplus', 'firefox')
)

$ErrorActionPreference = 'Stop'
$log = 'C:\apps\install-choco-apps.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
$started = Get-Date

function Step([string]$text) { Write-Host ("[{0:mm\:ss}] {1}" -f ((Get-Date) - $started), $text) }

# 1. Chocolatey
$choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
if (Test-Path $choco) {
    Step 'Chocolatey is already installed.'
} else {
    Step 'Installing Chocolatey...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-Host
    if (-not (Test-Path $choco)) { throw "Chocolatey did not install ($choco is missing)." }
}
$env:Path = "$env:Path;$(Split-Path $choco)"
Step ("Chocolatey " + (& $choco --version))

# 2. Packages, one at a time so one failure doesn't hide the others. Tool output goes to the host
#    (Out-Host) so only the result objects land in $results.
$results = foreach ($p in $Packages) {
    Step "Installing $p..."
    $chocoArgs = @('install', $p, '-y', '--no-progress', '--limit-output')
    # Google publishes Chrome at a fixed URL, so the package checksum goes stale with every Chrome
    # release. Acceptable in a throwaway sandbox; don't copy this onto a real machine.
    if ($p -eq 'googlechrome') { $chocoArgs += '--ignore-checksums' }
    & $choco @chocoArgs | Out-Host
    $code = $LASTEXITCODE
    # 0 = installed, 1641/3010 = installed, reboot pending (we never reboot a sandbox)
    [pscustomobject]@{ Package = $p; ExitCode = $code; Ok = ($code -in 0, 1641, 3010) }
}

# 3. Make the apps easy to find on the guest desktop
Step 'Adding desktop shortcuts...'
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$targets = [ordered]@{
    'Google Chrome' = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    'Notepad++'     = @("$env:ProgramFiles\Notepad++\notepad++.exe", "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe")
    'Firefox'       = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe")
}
foreach ($name in $targets.Keys) {
    $exe = $targets[$name] | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { Step "  $name - not found, no shortcut"; continue }
    # Chrome's and Firefox's installers already put one on the Public desktop
    if (Test-Path (Join-Path $publicDesktop "$name.lnk")) { Step "  $name - installer added a shortcut"; continue }
    $lnk = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
    $lnk.TargetPath = $exe
    $lnk.Save()
    Step "  $name -> $exe"
}

# 4. Summary
Write-Host ''
Write-Host ($results | Format-Table -AutoSize | Out-String).TrimEnd()
$failed = @($results | Where-Object { -not $_.Ok })
Step $(if ($failed.Count) { "Done with $($failed.Count) failure(s). Log: $log" } else { "All $($results.Count) packages installed. Log: $log" })
Stop-Transcript | Out-Null
exit $(if ($failed.Count) { 1 } else { 0 })
