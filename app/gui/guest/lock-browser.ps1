# lock-browser.ps1 - runs INSIDE the sandbox. Locks the guest down to one website.
#
# Expects a sandbox started with "sbx start --network firewall" (outbound blocked, every built-in
# outbound allow rule disabled). This script then:
#   - allows DNS to the guest's resolvers, and TCP 80/443 to the addresses of the allowed hosts only
#     (re-resolved every -RefreshSeconds, since sites rotate CDN addresses)
#   - sets Edge policies: every URL blocked except the allowed hosts, file:// blocked, downloads,
#     file pickers, printing, extensions, dev tools, sign-in and QUIC turned off
#   - opens Edge on the URL. With -Kiosk (the launcher's default): full-screen Edge covering the
#     taskbar and desktop, and Edge reopened on the URL if it gets closed: the site is the only
#     thing on screen. Without -Kiosk: an app window.
#
#   lock-browser.ps1 -Url https://example.com [-Allow cdn.example.net,fonts.gstatic.com] [-Kiosk]
#   lock-browser.ps1 -Refresh -Url ... -Hosts a.com,b.net [-Kiosk]   (the background loop)
param(
    [string]$Url,
    [string[]]$Allow = @(),
    [switch]$Kiosk,
    [int]$RefreshSeconds = 60,
    [switch]$Refresh,
    [string[]]$Hosts = @()
)
$ErrorActionPreference = 'Stop'
$RuleName = 'sbx-browse-allow'

function Split-List([string[]]$items) {
    @($items | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() } | Select-Object -Unique)
}

function Resolve-Hosts([string[]]$names) {
    $ips = foreach ($n in $names) {
        foreach ($type in 'A', 'AAAA') {
            try {
                Resolve-DnsName -Name $n -Type $type -DnsOnly -QuickTimeout -ErrorAction Stop |
                    Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }
            } catch { }
        }
    }
    @($ips | Select-Object -Unique)
}

# Is this DNS name one of the allowed domains, or a subdomain of one?
function Test-Allowed([string]$name, [string[]]$domains) {
    $name = $name.TrimEnd('.').ToLower()
    foreach ($d in $domains) { if ($name -eq $d -or $name.EndsWith(".$d")) { return $true } }
    $false
}

# Addresses Edge has just looked up for allowed domains, from the Windows DNS cache. This is how
# sites that stream from changing hosts (YouTube's *.googlevideo.com) work: the name is looked up,
# its address is allowed here within a couple of seconds, and the browser's retry gets through.
function Get-CachedAllowedIps([string[]]$domains) {
    @(Get-DnsClientCache -ErrorAction SilentlyContinue |
        Where-Object { ($_.Type -eq 1 -or $_.Type -eq 28) -and $_.Data -and (Test-Allowed $_.Entry $domains) } |
        ForEach-Object { $_.Data } | Select-Object -Unique)
}

function Set-AllowRule([string[]]$ips) {
    if (-not $ips.Count) { return $false }
    if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress $ips
    } else {
        New-NetFirewallRule -DisplayName $RuleName -Direction Outbound -Action Allow -Protocol TCP `
            -RemotePort 80, 443 -RemoteAddress $ips | Out-Null
    }
    $true
}

function Start-Edge([string]$target, [bool]$fullScreen) {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Edge not found in the guest' }
    $edgeArgs = if ($fullScreen) { @('--kiosk', $target, '--edge-kiosk-type=fullscreen', '--no-first-run') }
                else { @("--app=$target", '--no-first-run', '--start-maximized') }
    Start-Process $edge -ArgumentList $edgeArgs
}

if ($Refresh) {
    # Background loop. Every 2 s: allow addresses Edge looked up for allowed domains (DNS cache), and
    # in kiosk mode reopen Edge if it was closed. Every RefreshSeconds: re-resolve the names directly.
    # Allowed addresses only accumulate, so a rotating CDN never cuts off an open connection.
    $names = Split-List $Hosts
    $known = New-Object 'System.Collections.Generic.HashSet[string]'
    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($rule) { foreach ($a in ($rule | Get-NetFirewallAddressFilter).RemoteAddress) { [void]$known.Add($a) } }
    $tick = 0; $kioskTick = 0
    while ($true) {
        Start-Sleep -Seconds 2
        $tick += 2; $kioskTick += 2
        $fresh = @(Get-CachedAllowedIps $names)
        if ($tick -ge $RefreshSeconds) { $tick = 0; $fresh += @(Resolve-Hosts $names) }
        $added = $false
        foreach ($ip in $fresh) { if ($known.Add($ip)) { $added = $true } }
        if ($added) { try { Set-AllowRule @($known) | Out-Null } catch { } }
        if ($Kiosk -and $kioskTick -ge 4) {
            $kioskTick = 0
            if (-not (Get-Process msedge -ErrorAction SilentlyContinue)) { try { Start-Edge $Url $true } catch { } }
        }
    }
}

if (-not $Url) { throw 'Give -Url' }
if ($Url -notmatch '^[a-z]+://') { $Url = "https://$Url" }
$uri = [Uri]$Url
if ($uri.Scheme -notin 'http', 'https') { throw "Only http/https URLs: $Url" }
$siteHost = $uri.Host.ToLower()
if ($siteHost.StartsWith('www.')) { $siteHost = $siteHost.Substring(4) }   # www.youtube.com -> youtube.com and its subdomains
$names = Split-List (@($siteHost, $uri.Host) + $Allow)

# Running again (a new URL): stop the previous background loop first, or it reopens the old site.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -match 'lock-browser\.ps1.*-Refresh' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 1. Network: DNS to this guest's resolvers, web ports to the allowed hosts' addresses.
$dns = @(Get-DnsClientServerAddress | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ } | Select-Object -Unique)
if (-not $dns.Count) { throw 'No DNS server configured in the guest' }
Get-NetFirewallRule -DisplayName 'sbx-browse-dns*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'sbx-browse-dns-udp' -Direction Outbound -Action Allow -Protocol UDP -RemotePort 53 -RemoteAddress $dns | Out-Null
New-NetFirewallRule -DisplayName 'sbx-browse-dns-tcp' -Direction Outbound -Action Allow -Protocol TCP -RemotePort 53 -RemoteAddress $dns | Out-Null
$ips = Resolve-Hosts $names
if (-not (Set-AllowRule $ips)) { throw "Could not resolve $($names -join ', ')" }

# 2. Edge policies (machine-wide, read at Edge start).
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Remove-Item $pol -Recurse -Force -ErrorAction SilentlyContinue
New-Item $pol -Force | Out-Null
$dwords = @{
    DownloadRestrictions = 3; AllowFileSelectionDialogs = 0; PrintingEnabled = 0; QuicAllowed = 0
    DeveloperToolsAvailability = 2; BrowserSignin = 0; SyncDisabled = 1; PasswordManagerEnabled = 0
    AutofillAddressEnabled = 0; AutofillCreditCardEnabled = 0; HideFirstRunExperience = 1
    HubsSidebarEnabled = 0; EdgeCollectionsEnabled = 0; ShowRecommendationsEnabled = 0
    BrowserAddProfileEnabled = 0; BrowserGuestModeEnabled = 0; InPrivateModeAvailability = 1
    SmartScreenEnabled = 0; DefaultBrowserSettingEnabled = 0; ImportOnEachLaunch = 0; TranslateEnabled = 0
    BuiltInDnsClientEnabled = 0   # resolve through Windows, so lookups land in the DNS cache the loop reads
}
foreach ($k in $dwords.Keys) { New-ItemProperty $pol -Name $k -PropertyType DWord -Value $dwords[$k] -Force | Out-Null }
New-ItemProperty $pol -Name DnsOverHttpsMode -PropertyType String -Value 'off' -Force | Out-Null
New-Item "$pol\URLBlocklist" -Force | Out-Null
New-ItemProperty "$pol\URLBlocklist" -Name 1 -Value '*' -Force | Out-Null
New-ItemProperty "$pol\URLBlocklist" -Name 2 -Value 'file://*' -Force | Out-Null
New-Item "$pol\URLAllowlist" -Force | Out-Null
$i = 1; foreach ($n in $names) { New-ItemProperty "$pol\URLAllowlist" -Name ($i++) -Value $n -Force | Out-Null }
New-Item "$pol\ExtensionInstallBlocklist" -Force | Out-Null
New-ItemProperty "$pol\ExtensionInstallBlocklist" -Name 1 -Value '*' -Force | Out-Null

# 3. Kiosk: full-screen Edge covers the taskbar and desktop. The shell is deliberately left alone:
#    sbx screenshots and UI automation need it, and restarting explorer in a fresh sandbox can end
#    the whole sandbox a few seconds later. The Windows key reaches the guest only while the sandbox
#    window itself is full screen (remote-desktop default).

# 4. Open Edge, then keep the addresses fresh (and Edge open) in the background.
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Edge $uri.AbsoluteUri ([bool]$Kiosk)
$loopArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Refresh', '-RefreshSeconds', $RefreshSeconds,
              '-Url', $uri.AbsoluteUri, '-Hosts', ($names -join ','))
if ($Kiosk) { $loopArgs += '-Kiosk' }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $loopArgs

[pscustomobject]@{ url = $uri.AbsoluteUri; hosts = $names; addresses = $ips; dns = $dns; kiosk = [bool]$Kiosk } | ConvertTo-Json -Compress
