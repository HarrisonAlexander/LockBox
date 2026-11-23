# SbxGui.ps1 - a Hyper-V Quick Create-style launcher for sandbox-mcp (sbx).
#
# Pick a workflow (or a saved recipe) on the left, fill in the target on the right, press the
# big button. The job runs "sbx <workflow> ... --json" on the drive's Node, streams its progress
# log, then shows pass/fail, screenshots and links to the report and run folder. While a sandbox
# is running, the session page is a live PowerShell terminal inside it (sbx term) plus buttons for
# screenshots, window/UI-tree listings, pushing files in and stopping it - the same shared state
# the sbx CLI uses.
#
# Runs on Windows PowerShell 5.1 + WPF, both inbox on every Windows 10/11 machine, so nothing
# extra travels on the drive. ASCII only on purpose: 5.1 reads BOM-less scripts as ANSI.
# Every path is derived from this script's location; nothing records a drive letter.
# LockBox layout: <root>\app\{gui,sandbox-mcp,node} is code, <root>\data is state.
#
#   LockBox.cmd                   (at the LockBox root)
#   powershell -STA -File app\gui\SbxGui.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$Root      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$AppDir    = Join-Path $Root 'app'
$ConfigDir = Join-Path $Root 'data'
# An MSI install marks itself with app\installed. Program Files is read-only for users, so each user's
# state (runs, recipes, lockbox.env) goes to %LOCALAPPDATA%\LockBox instead.
if (Test-Path -LiteralPath (Join-Path $AppDir 'installed')) { $ConfigDir = Join-Path $env:LOCALAPPDATA 'LockBox' }
$Recipes   = Join-Path $ConfigDir 'recipes.json'
$CliJs     = Join-Path $AppDir 'lockbox\sbx.mjs'   # passes through to sandbox-mcp\src\cli.js; adds uninstall-test
if (-not (Test-Path -LiteralPath $CliJs) -or -not (Test-Path -LiteralPath (Join-Path $AppDir 'sandbox-mcp\src\cli.js'))) {
    [System.Windows.MessageBox]::Show("sandbox-mcp not found under $AppDir\sandbox-mcp", 'LockBox') | Out-Null
    exit 1
}

# The window runs node + cli.js directly instead of going through sbx.cmd, so user text (guest
# commands, installer arguments) never passes through cmd.exe's parser. That means doing here
# what the shim does: load data\lockbox.env (an already-set variable wins), default
# SANDBOX_MCP_HOME, prefer the bundled Node, and find the wsb.exe Store alias on a trimmed PATH.
$envFile = Join-Path $ConfigDir 'lockbox.env'
if (Test-Path -LiteralPath $envFile) {
    foreach ($envLine in [System.IO.File]::ReadAllLines($envFile)) {
        if ($envLine -match '^\s*#' -or $envLine -notmatch '^([^=\s]+)=(.+)$') { continue }
        if (-not [Environment]::GetEnvironmentVariable($Matches[1])) { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) }
    }
}
if (-not $env:SANDBOX_MCP_HOME) { $env:SANDBOX_MCP_HOME = Join-Path $ConfigDir 'home' }
$JobsDir = Join-Path $env:SANDBOX_MCP_HOME 'gui-jobs'
New-Item -ItemType Directory -Force $JobsDir | Out-Null
$NodeDir = Join-Path $AppDir 'node'
$NodeExe = Join-Path $NodeDir 'node.exe'
if (Test-Path -LiteralPath $NodeExe) { $env:PATH = "$NodeDir;$env:PATH" } else { $NodeExe = 'node.exe' }
if (-not (Get-Command wsb.exe -ErrorAction SilentlyContinue)) { $env:PATH = "$env:PATH;$env:LOCALAPPDATA\Microsoft\WindowsApps" }
# Inherited by open-claude.ps1, which puts this LockBox's sbx first on PATH for Claude Code.
$env:LOCKBOX_ROOT = $Root

# ---------------------------------------------------------------------------------------------
# Workflows. 'fields' says which inputs the form shows; 'opts' which "More options" rows.
# ---------------------------------------------------------------------------------------------
$Workflows = @(
    @{ key = 'run'; title = 'Test an app'; glyph = [char]0xE768; color = '#0067C0'
       button = 'Run on a clean machine'; targetLabel = 'App (.exe, folder or .msix)'; folderOk = $true
       filter = 'Apps (*.exe;*.msix;*.appx;*.msixbundle)|*.exe;*.msix;*.appx;*.msixbundle|All files (*.*)|*.*'
       fields = @('target', 'args', 'test'); opts = @('network', 'memory', 'nogpu', 'wait', 'exe', 'console', 'record', 'provision', 'keep')
       defaultNetwork = 'on'
       about = @(
         'Boots a brand-new Windows Sandbox, copies your app in, launches it, screenshots it, checks the event log for crashes, runs an optional test script, writes a report and destroys the machine.',
         'Nothing from your dev box leaks in: if the app needs a runtime you forgot to bundle, this is where you find out.',
         'Runtimes are never installed unless you opt in under More options > Provision. A provisioned pass is marked PROVISIONED, not a clean-machine pass.')
       details = @(@('Command', 'sbx run'), @('Typical time', '40-50 seconds'), @('Result', 'report.md, screenshots, crash events')) },

    @{ key = 'install-test'; title = 'Test an installer'; glyph = [char]0xE896; color = '#107C10'
       button = 'Install and stop'; targetLabel = 'Installer (.msi, .exe, .ps1, .cmd)'; folderOk = $false
       filter = 'Installers (*.msi;*.exe;*.ps1;*.cmd)|*.msi;*.exe;*.ps1;*.cmd|All files (*.*)|*.*'
       fields = @('target', 'args', 'test'); opts = @('network', 'memory', 'nogpu', 'manual', 'silent', 'testuninstall', 'uninstall', 'uninstallargs', 'timeout', 'leftovers', 'keep')
       defaultNetwork = 'on'
       about = @(
         'Snapshots a fresh machine, then runs the installer with its normal setup UI in the sandbox window and clicks through it for you: accepts the licence, presses Install / Next / Finish, declines any restart, and screenshots each step. When setup closes it snapshots again and stops. The sandbox stays running with the app installed so you can inspect it.',
         'To test the uninstall, press Uninstall test on the session page when you are done, or tick Test uninstall too under More options to do it in the same run. Stop sandbox throws the sandbox away.',
         'The report lists every file, registry key, service, scheduled task and autorun the installer added, and what the uninstaller left behind. Under More options, Click through setup myself leaves the clicking to you, and Silent install runs it unattended instead: MSI packages get /qn; for other installers put their silent switch (for example /S or /VERYSILENT) in Arguments.')
       details = @(@('Command', 'sbx install-test'), @('Typical time', '~2 minutes + installer'), @('Result', 'added / left-behind diff')) },

    @{ key = 'detonate'; title = 'Detonate a file'; glyph = [char]0xE7BA; color = '#C42B1C'
       button = 'Detonate with no network'; targetLabel = 'File you do not trust'; folderOk = $false
       filter = 'All files (*.*)|*.*'
       fields = @('target', 'args'); opts = @('network', 'memory', 'nogpu', 'duration', 'every', 'full', 'keep')
       defaultNetwork = 'off'
       about = @(
         'Runs a file you do not trust in a throwaway machine with NO network adapter and reports what it did: every process with its command line, names it looked up, addresses it tried, and the files, registry keys, autoruns, services and scheduled tasks it changed.',
         'Choose network "firewall" to see the addresses it tries while they are blocked.',
         'Windows Sandbox is strong isolation, not a guarantee. Treat everything that comes back (screenshots, logs) as untrusted. For real malware analysis use a dedicated analysis machine.')
       details = @(@('Command', 'sbx detonate'), @('Network', 'off by default'), @('Result', 'behaviour report (not a verdict)')) },

    @{ key = 'deps'; title = 'Check dependencies'; glyph = [char]0xE71D; color = '#8764B8'
       button = 'Scan dependencies'; targetLabel = 'App (.exe or folder)'; folderOk = $true
       filter = 'Apps (*.exe;*.dll)|*.exe;*.dll|All files (*.*)|*.*'
       fields = @('target'); opts = @()
       about = @(
         'Inspects the app on this PC without running, booting or installing anything: PE architecture and imports, app-local VC++ DLLs, .NET and .NET Framework runtime configs, package dependencies and script interpreters.',
         'A quick, conservative first look before a full clean-machine run. Optional guest components such as WebView2 can only be confirmed in a real sandbox.')
       details = @(@('Command', 'sbx deps'), @('Typical time', 'a second or two'), @('Boots a sandbox', 'no')) },

    @{ key = 'script'; title = 'Run a PowerShell script'; glyph = [char]0xE756; color = '#012456'
       button = 'Run script and keep the sandbox'; targetLabel = 'PowerShell script (.ps1)'; folderOk = $false
       filter = 'PowerShell scripts (*.ps1)|*.ps1|All files (*.*)|*.*'
       fields = @('target', 'args'); opts = @('network', 'memory', 'nogpu', 'timeout')
       defaultNetwork = 'on'
       about = @(
         'Boots a fresh sandbox, copies your script to C:\apps, runs it with Windows PowerShell 5.1 (execution policy Bypass) as the sandbox''s administrator, and shows its output and exit code.',
         'The sandbox is left running afterwards, pass or fail, so you can look at what the script did: open apps it installed, poke around, or keep going from the session page. Press Stop sandbox when you are done.',
         'Good for setup scripts, Chocolatey or winget installs, and module tests. Network is on by default so the script can download things. The default time limit is 20 minutes (More options > Timeout).')
       details = @(@('Commands', 'sbx start, push, exec'), @('Runs as', 'powershell -ExecutionPolicy Bypass -File'), @('Typical time', '~40 s boot + your script'), @('Ends with', 'Stop sandbox')) },

    @{ key = 'start'; title = 'Interactive session'; glyph = [char]0xE7F4; color = '#CA5010'
       button = 'Start a sandbox'; targetLabel = ''; folderOk = $false; filter = ''
       fields = @(); opts = @('network', 'memory', 'nogpu')
       defaultNetwork = 'on'
       about = @(
         'Boots a fresh sandbox and leaves it running so you, the sbx CLI or an AI agent (with the sbx CLI) can drive it step by step: push files, exec commands, read the UI Automation tree, click, type, snapshot and diff.',
         'Only one Windows Sandbox can run at a time. It shuts itself down after 30 idle minutes; press Stop sandbox when you are done.')
       details = @(@('Command', 'sbx start'), @('Then', 'sbx exec / ui / shot / push / pull'), @('Ends with', 'sbx stop')) }
)

# ---------------------------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------------------------
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LockBox" Width="980" Height="640" MinWidth="820" MinHeight="540"
        WindowStartupLocation="CenterScreen" Background="#FFFFFF"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#0067C0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="4" BorderThickness="1" BorderBrush="#005BA8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1975C5"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#005A9E"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Background" Value="#9DBDDF"/><Setter TargetName="b" Property="BorderBrush" Value="#9DBDDF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="#1B1B1B"/>
      <Setter Property="Background" Value="#E5E5E5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="4" BorderThickness="1" BorderBrush="#CFCFCF" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#DADADA"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#CCCCCC"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#A0A0A0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#1B1B1B"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="4,2"><ContentPresenter/></Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="6,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="#C8C8C8"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#5C5C5C"/>
      <Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F0F0F0"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#E3E3E3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="12,8,12,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="300"/>
      <ColumnDefinition Width="12"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <TextBlock Grid.Row="0" Grid.Column="0" Text="Select a workflow" Foreground="#0067C0" FontSize="18" Margin="0,0,0,4"/>
    <DockPanel Grid.Row="0" Grid.Column="2" LastChildFill="False" VerticalAlignment="Bottom" Margin="0,0,0,4">
      <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#9E9E9E" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBlock x:Name="StatusText" Text="Checking Windows Sandbox..." Foreground="#5C5C5C" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Button x:Name="StopBtn" DockPanel.Dock="Right" Style="{StaticResource Secondary}" Height="26" Content="Stop sandbox" Visibility="Collapsed"/>
      <Button x:Name="OpenSessionBtn" DockPanel.Dock="Right" Style="{StaticResource Secondary}" Height="26" Margin="0,0,6,0" Content="Open session" Visibility="Collapsed"
              ToolTip="Commands, screenshots, windows and files for the running sandbox"/>
    </DockPanel>

    <!-- left: workflow list + doctor row, like the image list + "Local installation source" -->
    <Border Grid.Row="1" Grid.Column="0" BorderBrush="#BDBDBD" BorderThickness="1">
      <DockPanel>
        <Border DockPanel.Dock="Bottom" BorderBrush="#BDBDBD" BorderThickness="0,1,0,0">
          <Button x:Name="DoctorBtn" Style="{StaticResource Link}" HorizontalAlignment="Stretch" HorizontalContentAlignment="Left" Padding="0">
            <StackPanel Orientation="Horizontal" Margin="6,6">
              <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE9D9;" FontSize="20" Foreground="#0067C0" VerticalAlignment="Center" Width="28"/>
              <TextBlock Text="Check this PC (sbx doctor)" FontSize="15" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </StackPanel>
          </Button>
        </Border>
        <ListBox x:Name="List" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </DockPanel>
    </Border>

    <!-- right: details page / results page -->
    <Border Grid.Row="1" Grid.Column="2" BorderBrush="#E0E0E0" BorderThickness="0">
      <Grid>
        <ScrollViewer x:Name="DetailsPage" VerticalScrollBarVisibility="Auto" Padding="0,0,8,0">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="HeroGlyph" FontFamily="{StaticResource Icons}" FontSize="34" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock x:Name="HeroTitle" FontSize="26" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                  <TextBlock x:Name="HeroSub" Foreground="#5C5C5C" Text="Windows Sandbox  -  sandbox-mcp"/>
                </StackPanel>
              </StackPanel>
            </Grid>

            <Grid Margin="0,10,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="190"/></Grid.ColumnDefinitions>
              <StackPanel x:Name="AboutPanel" Grid.Column="0"/>
              <Border Grid.Column="2" x:Name="HeroTile" CornerRadius="6" Height="120" VerticalAlignment="Top">
                <Grid>
                  <TextBlock x:Name="TileGlyph" FontFamily="{StaticResource Icons}" FontSize="54" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <TextBlock Text="fresh  -  throwaway  -  local" Foreground="#E6FFFFFF" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,8"/>
                </Grid>
              </Border>
            </Grid>

            <StackPanel x:Name="TargetRow">
              <TextBlock x:Name="TargetLabel" Style="{StaticResource FieldLabel}"/>
              <DockPanel>
                <Button x:Name="BrowseFolder" DockPanel.Dock="Right" Style="{StaticResource Secondary}" Height="30" Margin="6,0,0,0" Content="Folder..."/>
                <Button x:Name="BrowseFile" DockPanel.Dock="Right" Style="{StaticResource Secondary}" Height="30" Margin="6,0,0,0" Content="File..."/>
                <TextBox x:Name="TargetBox" AllowDrop="True"/>
              </DockPanel>
            </StackPanel>
            <StackPanel x:Name="ArgsRow">
              <TextBlock x:Name="ArgsLabel" Text="Arguments (optional)" Style="{StaticResource FieldLabel}"/>
              <TextBox x:Name="ArgsBox"/>
            </StackPanel>
            <StackPanel x:Name="TestRow">
              <TextBlock Text="Test script run inside afterwards (optional .ps1)" Style="{StaticResource FieldLabel}"/>
              <DockPanel>
                <Button x:Name="BrowseTest" DockPanel.Dock="Right" Style="{StaticResource Secondary}" Height="30" Margin="6,0,0,0" Content="File..."/>
                <TextBox x:Name="TestBox"/>
              </DockPanel>
            </StackPanel>

            <!-- More options -->
            <Border x:Name="OptionsPanel" Visibility="Collapsed" Margin="0,14,0,0" Padding="12" Background="#F7F7F7" CornerRadius="4">
              <WrapPanel x:Name="OptionsWrap" Orientation="Horizontal">
                <StackPanel x:Name="opt_network" Width="170" Margin="0,0,16,8">
                  <TextBlock Text="Network" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <ComboBox x:Name="NetworkBox" Height="30" VerticalContentAlignment="Center">
                    <ComboBoxItem Content="on" ToolTip="Normal NAT internet"/>
                    <ComboBoxItem Content="firewall" ToolTip="Guest firewall blocks outbound traffic"/>
                    <ComboBoxItem Content="off" ToolTip="No network adapter at all"/>
                  </ComboBox>
                </StackPanel>
                <StackPanel x:Name="opt_memory" Width="120" Margin="0,0,16,8">
                  <TextBlock Text="Memory (MB)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="MemoryBox" ToolTip="Blank = Windows Sandbox default"/>
                </StackPanel>
                <StackPanel x:Name="opt_wait" Width="120" Margin="0,0,16,8">
                  <TextBlock Text="Settle wait (s)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="WaitBox" ToolTip="Let a GUI app settle before observing (default 5)"/>
                </StackPanel>
                <StackPanel x:Name="opt_exe" Width="170" Margin="0,0,16,8">
                  <TextBlock Text="Exe in folder" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="ExeBox" ToolTip="Which exe, when the folder has several"/>
                </StackPanel>
                <StackPanel x:Name="opt_provision" Width="250" Margin="0,0,16,8">
                  <TextBlock Text="Provision runtimes (opt in)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="ProvisionBox" ToolTip="auto, or a list like desktop:8.0:x64,vcredist:x64. Report is then marked PROVISIONED."/>
                </StackPanel>
                <StackPanel x:Name="opt_uninstall" Width="170" Margin="0,0,16,8">
                  <TextBlock Text="Uninstall command" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="UninstallBox" ToolTip="Used with Test uninstall too. Blank: the uninstaller the app registered"/>
                </StackPanel>
                <StackPanel x:Name="opt_uninstallargs" Width="140" Margin="0,0,16,8">
                  <TextBlock Text="Uninstall args" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="UninstallArgsBox" ToolTip="Added to the registered UninstallString, e.g. /S"/>
                </StackPanel>
                <StackPanel x:Name="opt_timeout" Width="120" Margin="0,0,16,8">
                  <TextBlock Text="Timeout (s)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="TimeoutBox" ToolTip="Per installer/uninstaller (default 600)"/>
                </StackPanel>
                <StackPanel x:Name="opt_duration" Width="120" Margin="0,0,16,8">
                  <TextBlock Text="Watch for (s)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="DurationBox" ToolTip="Default 60"/>
                </StackPanel>
                <StackPanel x:Name="opt_every" Width="140" Margin="0,0,16,8">
                  <TextBlock Text="Screenshot every (s)" Foreground="#5C5C5C" Margin="0,0,0,4"/>
                  <TextBox x:Name="EveryBox" ToolTip="Default 15"/>
                </StackPanel>
                <CheckBox x:Name="opt_nogpu" Content="No vGPU" Margin="0,24,16,8" VerticalAlignment="Center"/>
                <CheckBox x:Name="opt_console" Content="Console app" Margin="0,24,16,8" ToolTip="Run to completion and capture output"/>
                <CheckBox x:Name="opt_record" Content="Record desktop" Margin="0,24,16,8" ToolTip="HTML flipbook, plus MP4 if ffmpeg is on PATH"/>
                <CheckBox x:Name="opt_full" Content="Watch full duration" Margin="0,24,16,8"/>
                <CheckBox x:Name="opt_leftovers" Content="Fail on leftovers" Margin="0,24,16,8"/>
                <CheckBox x:Name="opt_manual" Content="Click through setup myself" Margin="0,24,16,8" ToolTip="Show the setup UI but do not click it: you click through it in the sandbox window"/>
                <CheckBox x:Name="opt_silent" Content="Silent install (no setup UI)" Margin="0,24,16,8" ToolTip="Unattended: MSI gets /qn; other installers need their silent switch in Arguments"/>
                <CheckBox x:Name="opt_testuninstall" Content="Test uninstall too" Margin="0,24,16,8" ToolTip="Uninstall right after the install and report leftovers. Off: use Uninstall test on the session page when you are done"/>
                <CheckBox x:Name="opt_keep" Content="Keep sandbox running" Margin="0,24,16,8"/>
              </WrapPanel>
            </Border>

            <Border BorderBrush="#E5E5E5" BorderThickness="0,1,0,0" Margin="0,16,0,0" Padding="0,10,0,0">
              <Grid x:Name="DetailsGrid">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- results page -->
        <Grid x:Name="ResultsPage" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0">
            <Image x:Name="ResIcon" Width="32" Height="32" VerticalAlignment="Center" Margin="0,0,12,0" Visibility="Collapsed"/>
            <TextBlock x:Name="ResGlyph" FontFamily="{StaticResource Icons}" FontSize="30" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock x:Name="ResElapsed" DockPanel.Dock="Right" Foreground="#5C5C5C" VerticalAlignment="Center"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="ResTitle" FontSize="22" FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock x:Name="ResSub" Foreground="#5C5C5C" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </DockPanel>
          <ProgressBar x:Name="ResProgress" Grid.Row="1" Height="3" IsIndeterminate="True" Margin="0,10,0,6" BorderThickness="0" Foreground="#0067C0" Background="#E5E5E5"/>
          <Grid Grid.Row="2">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBox x:Name="LogBox" Height="Auto" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                     VerticalContentAlignment="Top" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FAFAFA" Padding="6"/>
            <ScrollViewer Grid.Row="1" x:Name="ShotsScroll" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" Visibility="Collapsed" Margin="0,8,0,0">
              <StackPanel x:Name="ShotsPanel" Orientation="Horizontal"/>
            </ScrollViewer>
          </Grid>
          <WrapPanel Grid.Row="3" Margin="0,8,0,0">
            <Button x:Name="OpenReportBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,0" Content="Open report" Visibility="Collapsed"/>
            <Button x:Name="OpenFolderBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,0" Content="Open run folder" Visibility="Collapsed"/>
            <Button x:Name="ShotBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,0" Content="Open session" Visibility="Collapsed"/>
            <Button x:Name="CopyLogBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,0" Content="Copy log"/>
          </WrapPanel>
        </Grid>

        <!-- session page: the running sandbox, from Interactive session, a kept run, or one started elsewhere -->
        <Grid x:Name="SessionPage" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0">
            <TextBlock x:Name="SessGlyph" FontFamily="{StaticResource Icons}" Text="&#xE7F4;" FontSize="30" Foreground="#CA5010" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="SessTitle" Text="Running sandbox" FontSize="22" FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock x:Name="SessSub" Foreground="#5C5C5C" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </DockPanel>
          <ProgressBar x:Name="SessProgress" Grid.Row="1" Height="3" IsIndeterminate="True" Margin="0,8,0,4" BorderThickness="0" Foreground="#CA5010" Background="#E5E5E5" Visibility="Hidden"/>
          <!-- terminal: a persistent PowerShell session in the guest (sbx term); the prompt and input live inline -->
          <Border Grid.Row="3" Background="#0C0C0C" CornerRadius="4" Margin="0,4,0,0">
            <TextBox x:Name="SessLog" Height="Auto" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="13"
                     Background="Transparent" Foreground="#CCCCCC" CaretBrush="#E0E0E0" SelectionBrush="#3A6EA5" BorderThickness="0"
                     VerticalContentAlignment="Top" TextWrapping="Wrap" AcceptsReturn="True" AcceptsTab="False" IsUndoEnabled="False"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="8,6"
                     AutomationProperties.Name="Sandbox terminal">
              <TextBox.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="TermCopyItem" Header="Copy" InputGestureText="Ctrl+C"/>
                  <MenuItem x:Name="TermPasteItem" Header="Paste" InputGestureText="Ctrl+V"/>
                  <Separator/>
                  <MenuItem x:Name="TermBreakItem" Header="Stop running command" InputGestureText="Ctrl+C"/>
                  <MenuItem x:Name="TermClearItem" Header="Clear" InputGestureText="Ctrl+L"/>
                  <MenuItem x:Name="TermResetItem" Header="New PowerShell session"/>
                </ContextMenu>
              </TextBox.ContextMenu>
            </TextBox>
          </Border>
          <ScrollViewer Grid.Row="4" x:Name="SessShotsScroll" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" Visibility="Collapsed" Margin="0,8,0,0">
            <StackPanel x:Name="SessShotsPanel" Orientation="Horizontal"/>
          </ScrollViewer>
          <WrapPanel Grid.Row="5" Margin="0,8,0,0">
            <Button x:Name="SessClaudeBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Open Claude"
                    ToolTip="Claude Code on this PC, in its own window, driving this sandbox with the sbx CLI and skills"/>
            <Button x:Name="SessShotBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Take screenshot"/>
            <Button x:Name="SessWindowsBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="List windows"/>
            <Button x:Name="SessUiBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="UI tree" ToolTip="UI Automation tree of the foreground window"/>
            <Button x:Name="SessPushBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Push file..." ToolTip="Copy a host file in (lands in C:\apps\&lt;name&gt;)"/>
            <Button x:Name="SessPushDirBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Push folder..."/>
            <Button x:Name="SessFolderBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Open artifacts"/>
            <Button x:Name="SessUninstallBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Uninstall test"
                    ToolTip="Uninstall what the install test installed, then report what it left behind. The sandbox stays running"/>
            <Button x:Name="SessStopBtn" Style="{StaticResource Secondary}" Height="30" Margin="0,0,8,6" Content="Stop sandbox"/>
          </WrapPanel>
        </Grid>
      </Grid>
    </Border>

    <!-- bottom-right "More options" + save recipe -->
    <DockPanel Grid.Row="2" Grid.Column="2" Margin="0,6,0,0" LastChildFill="False">
      <Button x:Name="MoreBtn" DockPanel.Dock="Right" Style="{StaticResource Link}">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="More options" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <Border Width="20" Height="20" CornerRadius="10" BorderBrush="#1B1B1B" BorderThickness="1">
            <TextBlock x:Name="MoreChevron" FontFamily="{StaticResource Icons}" Text="&#xE70D;" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>
      </Button>
      <Button x:Name="SaveRecipeBtn" DockPanel.Dock="Left" Style="{StaticResource Link}" Foreground="#0067C0" Content="Save as recipe..."/>
    </DockPanel>

    <Grid Grid.Row="3" Grid.ColumnSpan="3" Margin="0,12,0,0" Height="44">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="CloseBtn" Grid.Column="0" Style="{StaticResource Secondary}" FontSize="15" Content="Close"/>
      <Button x:Name="GoBtn" Grid.Column="2" Style="{StaticResource Primary}" Content="Run"/>
    </Grid>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
$Xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    $ui[$n.Value] = $Window.FindName($n.Value)
}
$IconFont = $Window.Resources['Icons']

# App icon: title bar and taskbar, and the results page header while a run is in progress.
$IconFile = Join-Path $PSScriptRoot 'box.ico'
if (Test-Path -LiteralPath $IconFile) {
    $iconUri = New-Object System.Uri($IconFile)
    $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
    $iconDecoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create($iconUri, 'None', 'OnLoad')
    $ui.ResIcon.Source = $iconDecoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
}

# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------
$script:Current    = $null    # workflow hashtable on screen
$script:Job        = $null    # running workflow job: sbx handle, workflow, dir, cancelled
$script:LastResult = $null
$script:Running    = $false   # a sandbox is running (from sbx status)
$script:Status     = $null    # last sbx status --json result
$script:Busy       = $false   # a workflow job is in flight
$script:SessJob    = $null    # running session command (exec, shot, windows, ui, push)

function Get-Brush([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

function Quote-Arg([string]$s) {
    # Node parses argv with MSVCRT rules: \" is a literal quote. cmd sees everything inside "...".
    '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# ---------------------------------------------------------------------------------------------
# Running sbx: node.exe cli.js <args>, both streams read in chunks by pending ReadAsync tasks
# that timers poll on the UI thread. No PowerShell callbacks on other threads, and both pipes
# keep draining, so a chatty child can never block on a full pipe.
# ---------------------------------------------------------------------------------------------
function Start-Sbx([string[]]$sbxArgs, [switch]$Stdin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NodeExe
    $psi.Arguments = (Quote-Arg $CliJs) + ' ' + ($sbxArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = [bool]$Stdin
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $env:SANDBOX_MCP_HOME
    $p = [System.Diagnostics.Process]::Start($psi)
    $h = @{ process = $p; args = $sbxArgs; started = Get-Date
            out = New-Object System.Text.StringBuilder; err = New-Object System.Text.StringBuilder
            streams = @() }
    foreach ($pair in @(@($p.StandardOutput, 'out'), @($p.StandardError, 'err'))) {
        $buf = New-Object char[] 8192
        $h.streams += @{ reader = $pair[0]; target = $pair[1]; buf = $buf; task = $pair[0].ReadAsync($buf, 0, $buf.Length); eof = $false }
    }
    $h
}

# Moves whatever the child has written so far into out/err; returns the new stderr text.
function Read-Sbx($h) {
    $newErr = ''
    foreach ($s in $h.streams) {
        while (-not $s.eof -and $s.task.IsCompleted) {
            $n = $s.task.Result
            if ($n -le 0) { $s.eof = $true; break }
            $chunk = New-Object string($s.buf, 0, $n)
            [void]$h[$s.target].Append($chunk)
            if ($s.target -eq 'err') { $newErr += $chunk }
            $s.task = $s.reader.ReadAsync($s.buf, 0, $s.buf.Length)
        }
    }
    $newErr
}

function Test-SbxDone($h) {
    $h.process.HasExited -and -not ($h.streams | Where-Object { -not $_.eof })
}

# For short calls (stop, status): wait, keeping both pipes drained.
function Invoke-SbxSync([string[]]$sbxArgs, [int]$timeoutSec = 120) {
    $h = Start-Sbx $sbxArgs
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while (-not (Test-SbxDone $h) -and (Get-Date) -lt $deadline) {
        [void](Read-Sbx $h)
        Start-Sleep -Milliseconds 50
    }
    [void](Read-Sbx $h)
    $h
}

function Stop-SbxTree($h) {
    if ($h -and -not $h.process.HasExited) {
        & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $h.process.Id 2>$null | Out-Null
    }
}

# ---------------------------------------------------------------------------------------------
# Left list: workflows, then saved recipes
# ---------------------------------------------------------------------------------------------
function New-ListRow([string]$glyph, [string]$color, [string]$text, [string]$sub) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $g = New-Object System.Windows.Controls.TextBlock
    $g.FontFamily = $IconFont; $g.Text = $glyph; $g.FontSize = 20; $g.Width = 28
    $g.Foreground = Get-Brush $color; $g.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.StackPanel
    $t.Margin = '6,0,0,0'; $t.VerticalAlignment = 'Center'
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $text; $a.FontSize = 15; $a.TextTrimming = 'CharacterEllipsis'
    [void]$t.Children.Add($a)
    if ($sub) {
        $b = New-Object System.Windows.Controls.TextBlock
        $b.Text = $sub; $b.FontSize = 11; $b.Foreground = Get-Brush '#707070'; $b.TextTrimming = 'CharacterEllipsis'
        [void]$t.Children.Add($b)
    }
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($t)
    $sp
}

function Read-Recipes {
    if (-not (Test-Path $Recipes)) { return @() }
    try { @(Get-Content $Recipes -Raw | ConvertFrom-Json) } catch { @() }
}

# Recipe paths inside the LockBox folder are saved as ".\..." relative to its root, so a recipe
# survives the LockBox moving or the drive letter changing. Paths elsewhere stay absolute.
function ConvertTo-RecipePath([string]$path) {
    if (-not $path -or -not [System.IO.Path]::IsPathRooted($path)) { return $path }
    $full = [System.IO.Path]::GetFullPath($path)
    $rootSlash = $Root.TrimEnd('\') + '\'
    if ($full.StartsWith($rootSlash, [StringComparison]::OrdinalIgnoreCase)) { return '.\' + $full.Substring($rootSlash.Length) }
    $path
}
function Resolve-RecipePath([string]$path) {
    if ($path -and $path.StartsWith('.\')) { return [System.IO.Path]::Combine($Root, $path.Substring(2)) }
    $path
}

# Built-in presets: ready-made recipes listed above the saved ones (they can't be deleted).
$Presets = @(
    [pscustomobject]@{ name = 'Chocolatey demo'; workflow = 'script'; glyph = [char]0xE7B8
                       target = (Join-Path $PSScriptRoot 'samples\install-choco-apps.ps1')
                       options = [pscustomobject]@{ network = 'on' } }
)

function Add-ListHeader([string]$text) {
    $hdr = New-Object System.Windows.Controls.ListBoxItem
    $hdr.IsEnabled = $false; $hdr.Focusable = $false
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $text; $h.FontSize = 11; $h.Foreground = Get-Brush '#707070'; $h.Margin = '2,10,0,0'
    $hdr.Content = $h
    [void]$ui.List.Items.Add($hdr)
}

function Fill-List {
    $ui.List.Items.Clear()
    foreach ($w in $Workflows) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = New-ListRow $w.glyph $w.color $w.title ''
        $item.Tag = @{ kind = 'workflow'; wf = $w }
        [void]$ui.List.Items.Add($item)
    }
    Add-ListHeader 'PRESETS'
    foreach ($p in $Presets) {
        $w = $Workflows | Where-Object { $_.key -eq $p.workflow } | Select-Object -First 1
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = New-ListRow $p.glyph $w.color $p.name "$($w.title)  -  $(Split-Path -Leaf $p.target)"
        $item.Tag = @{ kind = 'recipe'; wf = $w; recipe = $p }
        [void]$ui.List.Items.Add($item)
    }
    $recipes = Read-Recipes
    if ($recipes.Count) {
        Add-ListHeader 'SAVED RECIPES'
        foreach ($r in $recipes) {
            $w = $Workflows | Where-Object { $_.key -eq $r.workflow } | Select-Object -First 1
            if (-not $w) { continue }
            $item = New-Object System.Windows.Controls.ListBoxItem
            $sub = $w.title
            if ($r.target) { $sub = "$($w.title)  -  $(Split-Path $r.target -Leaf)" }
            $item.Content = New-ListRow ([char]0xE734) $w.color $r.name $sub
            $item.Tag = @{ kind = 'recipe'; wf = $w; recipe = $r }
            $menu = New-Object System.Windows.Controls.ContextMenu
            $del = New-Object System.Windows.Controls.MenuItem
            $del.Header = 'Delete recipe'; $del.Tag = $r.name
            $del.Add_Click({ param($s, $e) Remove-Recipe $s.Tag })
            [void]$menu.Items.Add($del)
            $item.ContextMenu = $menu
            [void]$ui.List.Items.Add($item)
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Right pane: show a workflow (optionally pre-filled from a recipe)
# ---------------------------------------------------------------------------------------------
$OptionNames = 'network', 'memory', 'wait', 'exe', 'provision', 'uninstall', 'uninstallargs', 'timeout', 'duration', 'every', 'nogpu', 'console', 'record', 'full', 'leftovers', 'keep', 'manual', 'silent', 'testuninstall'

function Set-Network([string]$value) {
    foreach ($i in $ui.NetworkBox.Items) { if ($i.Content -eq $value) { $ui.NetworkBox.SelectedItem = $i } }
}

function Show-Workflow($w, $recipe) {
    $script:Current = $w
    $ui.ResultsPage.Visibility = 'Collapsed'
    $ui.SessionPage.Visibility = 'Collapsed'
    $ui.DetailsPage.Visibility = 'Visible'
    $ui.HeroGlyph.Text = $w.glyph; $ui.HeroGlyph.Foreground = Get-Brush $w.color
    $ui.HeroTitle.Text = $w.title
    $ui.HeroTile.Background = Get-Brush $w.color
    $ui.TileGlyph.Text = $w.glyph
    if ($recipe) { $ui.HeroSub.Text = "Recipe: $($recipe.name)  -  Windows Sandbox  -  sandbox-mcp" }
    else { $ui.HeroSub.Text = 'Windows Sandbox  -  sandbox-mcp' }

    $ui.AboutPanel.Children.Clear()
    foreach ($p in $w.about) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $p; $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,10'; $t.LineHeight = 19
        [void]$ui.AboutPanel.Children.Add($t)
    }

    $ui.DetailsGrid.Children.Clear(); $ui.DetailsGrid.RowDefinitions.Clear()
    $row = 0
    foreach ($d in $w.details) {
        $ui.DetailsGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
        $k = New-Object System.Windows.Controls.TextBlock
        $k.Text = $d[0]; $k.FontWeight = 'SemiBold'; $k.HorizontalAlignment = 'Right'; $k.Margin = '0,2,14,2'
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = $d[1]; $v.Margin = '0,2,0,2'; $v.TextWrapping = 'Wrap'
        [System.Windows.Controls.Grid]::SetRow($k, $row); [System.Windows.Controls.Grid]::SetRow($v, $row)
        [System.Windows.Controls.Grid]::SetColumn($v, 1)
        [void]$ui.DetailsGrid.Children.Add($k); [void]$ui.DetailsGrid.Children.Add($v)
        $row++
    }

    $ui.TargetRow.Visibility = if ($w.fields -contains 'target') { 'Visible' } else { 'Collapsed' }
    $ui.ArgsRow.Visibility   = if ($w.fields -contains 'args')   { 'Visible' } else { 'Collapsed' }
    $ui.TestRow.Visibility   = if ($w.fields -contains 'test')   { 'Visible' } else { 'Collapsed' }
    $ui.TargetLabel.Text = $w.targetLabel
    $ui.BrowseFolder.Visibility = if ($w.folderOk) { 'Visible' } else { 'Collapsed' }
    foreach ($o in $OptionNames) {
        $ui["opt_$o"].Visibility = if ($w.opts -contains $o) { 'Visible' } else { 'Collapsed' }
    }
    $ui.MoreBtn.Visibility = if ($w.opts.Count) { 'Visible' } else { 'Hidden' }
    if (-not $w.opts.Count) { $ui.OptionsPanel.Visibility = 'Collapsed' }
    $ui.SaveRecipeBtn.Visibility = if ($w.fields.Count -or $w.opts.Count) { 'Visible' } else { 'Hidden' }

    # reset, then apply the recipe's values
    if ($w.defaultNetwork) { Set-Network $w.defaultNetwork }
    foreach ($b in 'MemoryBox', 'WaitBox', 'ExeBox', 'ProvisionBox', 'UninstallArgsBox', 'TimeoutBox', 'DurationBox', 'EveryBox') { $ui[$b].Text = '' }
    # Defaults: install and stop. The sandbox stays up and the app stays installed until you say otherwise.
    $ui.UninstallBox.Text = ''
    foreach ($c in 'nogpu', 'console', 'record', 'full', 'leftovers', 'manual', 'silent', 'testuninstall') { $ui["opt_$c"].IsChecked = $false }
    $ui.opt_keep.IsChecked = $true
    if ($recipe) {
        $ui.TargetBox.Text = Resolve-RecipePath ([string]$recipe.target)
        $ui.ArgsBox.Text   = [string]$recipe.args
        $ui.TestBox.Text   = Resolve-RecipePath ([string]$recipe.test)
        $o = $recipe.options
        if ($o) {
            if ($o.network) { Set-Network $o.network }
            foreach ($pair in @(@('memory', 'MemoryBox'), @('wait', 'WaitBox'), @('exe', 'ExeBox'), @('provision', 'ProvisionBox'), @('uninstall', 'UninstallBox'),
                                @('uninstallargs', 'UninstallArgsBox'), @('timeout', 'TimeoutBox'), @('duration', 'DurationBox'), @('every', 'EveryBox'))) {
                if ($o.($pair[0])) { $ui[$pair[1]].Text = [string]$o.($pair[0]) }
            }
            foreach ($c in 'nogpu', 'console', 'record', 'full', 'leftovers', 'manual', 'silent', 'testuninstall') { if ($o.$c) { $ui["opt_$c"].IsChecked = $true } }
            if ($null -ne $o.keep) { $ui.opt_keep.IsChecked = [bool]$o.keep }
        }
    }
    Update-GoButton
}

function Update-GoButton {
    if ($script:Busy) {
        $ui.GoBtn.Content = 'Cancel'
        $ui.GoBtn.IsEnabled = $true
        return
    }
    if ($ui.ResultsPage.Visibility -eq 'Visible' -or $ui.SessionPage.Visibility -eq 'Visible') {
        $ui.GoBtn.Content = 'Back'
        $ui.GoBtn.IsEnabled = $true
        return
    }
    $script:GoOpensSession = $false
    if (-not $script:Current) { $ui.GoBtn.IsEnabled = $false; return }
    $ui.GoBtn.Content = $script:Current.button
    $ui.GoBtn.IsEnabled = $true
    if ($script:Current.key -ne 'deps' -and $script:Running) {
        if ($script:Status -and $script:Status.running) {
            # Ours (sbx state): every workflow page offers the way into it instead of a dead button.
            $ui.GoBtn.Content = 'Open the running session'
            $script:GoOpensSession = $true
        } else {
            $ui.GoBtn.Content = 'Another sandbox is open'
            $ui.GoBtn.IsEnabled = $false
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Build the sbx command line from the form
# ---------------------------------------------------------------------------------------------
function Get-FormValues {
    @{
        target = $ui.TargetBox.Text.Trim().Trim('"'); args = $ui.ArgsBox.Text; test = $ui.TestBox.Text.Trim().Trim('"')
        options = [ordered]@{
            network = $ui.NetworkBox.SelectedItem.Content; memory = $ui.MemoryBox.Text.Trim(); wait = $ui.WaitBox.Text.Trim()
            exe = $ui.ExeBox.Text.Trim(); provision = $ui.ProvisionBox.Text.Trim(); uninstall = $ui.UninstallBox.Text.Trim()
            uninstallargs = $ui.UninstallArgsBox.Text; timeout = $ui.TimeoutBox.Text.Trim(); duration = $ui.DurationBox.Text.Trim()
            every = $ui.EveryBox.Text.Trim(); nogpu = [bool]$ui.opt_nogpu.IsChecked; console = [bool]$ui.opt_console.IsChecked
            record = [bool]$ui.opt_record.IsChecked; full = [bool]$ui.opt_full.IsChecked; leftovers = [bool]$ui.opt_leftovers.IsChecked
            keep = [bool]$ui.opt_keep.IsChecked
            manual = [bool]$ui.opt_manual.IsChecked; silent = [bool]$ui.opt_silent.IsChecked; testuninstall = [bool]$ui.opt_testuninstall.IsChecked
        }
    }
}

function Build-Args($w, $v) {
    $a = New-Object System.Collections.Generic.List[string]
    if ($w.key -eq 'script') {
        # Only boots here; the script and its arguments go in through Get-ScriptSteps.
        $a.Add('start')
        $o = $v.options
        if ($o.network) { $a.Add('--network'); $a.Add($o.network) }
        if ($o.memory) { $a.Add('--memory'); $a.Add((Quote-Arg $o.memory)) }
        if ($o.nogpu) { $a.Add('--no-gpu') }
        $a.Add('--json')
        return $a
    } else { $a.Add($w.key) }
    if ($w.fields -contains 'target') { $a.Add((Quote-Arg $v.target)) }
    $o = $v.options
    $has = { param($name) $w.opts -contains $name }
    if (($w.fields -contains 'args') -and $v.args) { $a.Add('--args'); $a.Add((Quote-Arg $v.args)) }
    if (($w.fields -contains 'test') -and $v.test) { $a.Add('--test'); $a.Add((Quote-Arg $v.test)) }
    if ((& $has 'network') -and $o.network) { $a.Add('--network'); $a.Add($o.network) }
    $valueOpts = @(@('memory', '--memory'), @('wait', '--wait'), @('exe', '--exe'), @('provision', '--provision'), @('uninstallargs', '--uninstall-args'),
                   @('timeout', '--timeout'), @('duration', '--duration'), @('every', '--every'))
    foreach ($p in $valueOpts) {
        if ((& $has $p[0]) -and $o.($p[0])) { $a.Add($p[1]); $a.Add((Quote-Arg $o.($p[0]))) }
    }
    # LockBox's install-test (app\lockbox\sbx.mjs) shows the setup UI, keeps the sandbox and uninstalls
    # nothing unless told otherwise.
    if ($w.key -eq 'install-test') {
        if ($o.silent) { $a.Add('--silent') } elseif ($o.manual) { $a.Add('--manual') }
        if ($o.testuninstall) {
            $a.Add('--uninstall')
            if ($o.uninstall -and $o.uninstall -notin 'auto', 'none') { $a.Add((Quote-Arg $o.uninstall)) }
        }
        if (-not $o.keep) { $a.Add('--no-keep') }
    }
    $flags = @(@('nogpu', '--no-gpu'), @('console', '--console'), @('record', '--record'), @('full', '--full'), @('leftovers', '--fail-on-leftovers'), @('keep', '--keep'))
    foreach ($p in $flags) { if ((& $has $p[0]) -and $o.($p[0])) { $a.Add($p[1]) } }
    if ($w.key -ne 'deps') { $a.Add('--json') }
    $a
}

# "Run a PowerShell script": after "sbx start", copy the script in and run it. exec waits for it
# (up to the timeout) and returns its output and exit code; the sandbox stays up either way.
function Get-ScriptSteps($v) {
    $leaf = Split-Path -Leaf $v.target
    $guestPath = "C:\apps\$leaf"
    $guestCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File '" + $guestPath.Replace("'", "''") + "'"
    if ($v.args) { $guestCmd += ' ' + $v.args }
    $timeout = if ($v.options.timeout) { $v.options.timeout } else { '1200' }
    ,@(
        ,@('push', (Quote-Arg $v.target), (Quote-Arg $guestPath))
        ,@('exec', '--timeout', $timeout, (Quote-Arg $guestCmd))
    )
}

function Test-Form($w, $v) {
    if ($w.fields -contains 'target') {
        if (-not $v.target) { return 'Choose a file first.' }
        if (-not (Test-Path -LiteralPath $v.target)) { return "Not found: $($v.target)" }
        if ($w.key -eq 'script' -and $v.target -notmatch '\.ps1$') { return 'Choose a PowerShell script (.ps1).' }
    }
    if (($w.fields -contains 'test') -and $v.test -and -not (Test-Path -LiteralPath $v.test)) { return "Test script not found: $($v.test)" }
    foreach ($n in 'memory', 'wait', 'timeout', 'duration', 'every') {
        $x = $v.options.$n
        if (($w.opts -contains $n) -and $x -and -not ($x -match '^\d+$')) { return "$n must be a whole number." }
    }
    $null
}


# ---------------------------------------------------------------------------------------------
# Workflow jobs: progress (stderr) streams into the log; the --json result (stdout) is read at the
# end. A copy of the command and both streams is kept in home\gui-jobs\<stamp>\.
# ---------------------------------------------------------------------------------------------
# $steps: more sbx commands to run after this one, in order, each only if the previous exited 0
# (the first command's stdout is kept as the job's result).
function Start-SbxJob($w, [string[]]$sbxArgs, [string]$title, [string]$subtitle, $steps = @()) {
    $dir = Join-Path $JobsDir (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    New-Item -ItemType Directory -Force $dir | Out-Null
    $cmds = @('sbx ' + ($sbxArgs -join ' ')) + @(foreach ($s in $steps) { 'sbx ' + ($s -join ' ') })
    Set-Content -LiteralPath (Join-Path $dir 'command.txt') -Value $cmds -Encoding UTF8

    $script:Job = @{ sbx = (Start-Sbx $sbxArgs); wf = $w; started = Get-Date; dir = $dir; cancelled = $false
                     steps = $steps; stepIndex = 0; firstOut = $null; stepLog = New-Object System.Text.StringBuilder }
    $script:Busy = $true
    $script:LastResult = $null

    $ui.DetailsPage.Visibility = 'Collapsed'
    $ui.SessionPage.Visibility = 'Collapsed'
    $ui.ResultsPage.Visibility = 'Visible'
    $ui.ResGlyph.Text = $w.glyph; $ui.ResGlyph.Foreground = Get-Brush $w.color
    if ($ui.ResIcon.Source) { $ui.ResIcon.Visibility = 'Visible'; $ui.ResGlyph.Visibility = 'Collapsed' }
    $ui.ResTitle.Text = $title
    $ui.ResSub.Text = $subtitle
    $ui.ResProgress.Visibility = 'Visible'
    $ui.ResElapsed.Text = ''
    $ui.LogBox.Text = "> sbx $($sbxArgs -join ' ')`r`n"
    $ui.ShotsPanel.Children.Clear(); $ui.ShotsScroll.Visibility = 'Collapsed'
    foreach ($b in 'OpenReportBtn', 'OpenFolderBtn', 'ShotBtn') { $ui[$b].Visibility = 'Collapsed' }
    $ui.List.IsEnabled = $false; $ui.DoctorBtn.IsEnabled = $false; $ui.SaveRecipeBtn.Visibility = 'Hidden'; $ui.MoreBtn.Visibility = 'Hidden'
    $ui.OpenSessionBtn.Visibility = 'Collapsed'
    Update-GoButton
    $JobTimer.Start()
}

function Add-Log([string]$text) {
    if (-not $text) { return }
    $ui.LogBox.AppendText(($text -replace "`r?`n", "`r`n"))
    $ui.LogBox.ScrollToEnd()
}

function Add-Shot([string]$path, [string]$label, $panel = $ui.ShotsPanel, $scroll = $ui.ShotsScroll) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.DecodePixelHeight = 360; $bmp.UriSource = New-Object System.Uri($path); $bmp.EndInit()
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $bmp; $img.Height = 150; $img.Stretch = 'Uniform'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '0,0,10,0'; $sp.Cursor = 'Hand'; $sp.ToolTip = "$path`r`nClick to open"; $sp.Tag = $path
    [void]$sp.Children.Add($img)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $label; $t.FontSize = 11; $t.Foreground = Get-Brush '#5C5C5C'; $t.HorizontalAlignment = 'Center'
    [void]$sp.Children.Add($t)
    $sp.Add_MouseLeftButtonUp({ param($s, $e) Start-Process -FilePath $s.Tag })
    [void]$panel.Children.Add($sp)
    $scroll.Visibility = 'Visible'
    $scroll.ScrollToRightEnd()
}

function Complete-Job {
    $JobTimer.Stop()
    $j = $script:Job
    Add-Log (Read-Sbx $j.sbx)
    $code = $j.sbx.process.ExitCode
    $stepOut = $j.sbx.out.ToString()
    [void]$j.stepLog.AppendLine("> sbx $($j.sbx.args)").AppendLine($stepOut).AppendLine($j.sbx.err.ToString())
    if ($null -eq $j.firstOut) { $j.firstOut = $stepOut } elseif ($stepOut.Trim()) { Add-Log $stepOut }
    if ($code -eq 0 -and -not $j.cancelled -and $j.stepIndex -lt @($j.steps).Count) {
        # Chain the next step into the same job and log.
        $next = [string[]]$j.steps[$j.stepIndex]
        $j.stepIndex++
        Add-Log "`r`n> sbx $($next -join ' ')`r`n"
        $j.sbx = Start-Sbx $next
        $JobTimer.Start()
        return
    }
    $elapsed = (Get-Date) - $j.started
    $ui.ResElapsed.Text = '{0:mm\:ss}' -f $elapsed
    $ui.ResProgress.Visibility = 'Collapsed'
    $ui.ResIcon.Visibility = 'Collapsed'; $ui.ResGlyph.Visibility = 'Visible'
    $raw = $j.firstOut
    try {
        [System.IO.File]::WriteAllText((Join-Path $j.dir 'stdout.txt'), $raw)
        [System.IO.File]::WriteAllText((Join-Path $j.dir 'stderr.txt'), $j.sbx.err.ToString())
        if (@($j.steps).Count) { [System.IO.File]::WriteAllText((Join-Path $j.dir 'steps.txt'), $j.stepLog.ToString()) }
    } catch { }
    $r = $null
    if ($j.wf.key -ne 'deps' -and $raw.Trim()) {
        try { $r = $raw | ConvertFrom-Json } catch { }
    }
    $script:LastResult = $r
    $openSession = $false
    $stayOnResults = $false   # seed the session but keep the log on screen (script output)

    if ($j.cancelled) {
        $ui.ResTitle.Text = 'Cancelled'
        $ui.ResGlyph.Text = [char]0xE711; $ui.ResGlyph.Foreground = Get-Brush '#707070'
    } elseif ($j.wf.key -eq 'deps') {
        Add-Log ("`r`n" + $raw)
        $ui.ResTitle.Text = if ($code -eq 0) { 'Dependency scan' } else { 'Dependency scan failed' }
        $ui.ResGlyph.Text = if ($code -eq 0) { [char]0xE73E } else { [char]0xEA39 }
        $ui.ResGlyph.Foreground = Get-Brush $(if ($code -eq 0) { '#107C10' } else { '#C42B1C' })
    } elseif ($j.wf.key -eq 'doctor') {
        $ok = $r -and $r.ok
        $ui.ResTitle.Text = if ($ok) { 'This PC can run Windows Sandbox' } else { 'This PC is not ready' }
        $ui.ResGlyph.Text = if ($ok) { [char]0xE73E } else { [char]0xEA39 }
        $ui.ResGlyph.Foreground = Get-Brush $(if ($ok) { '#107C10' } else { '#C42B1C' })
        if ($r) {
            foreach ($c in @($r.checks)) {
                $mark = if ($c.ok) { '[ok]  ' } else { '[!!]  ' }
                Add-Log "$mark$($c.detail)`r`n"
                if ($c.fix) { Add-Log "      fix: $($c.fix)`r`n" }
            }
        } else { Add-Log $raw }
    } elseif ($j.wf.key -eq 'script' -and $j.stepIndex -gt 0) {
        # Booted: whatever the script did, the sandbox stays up so it can be inspected.
        $ok = ($code -eq 0)
        $ui.ResTitle.Text = if ($j.stepIndex -eq 1) { 'Could not copy the script in' }
                            elseif ($ok) { 'Script finished (exit 0)' }
                            elseif ($code -eq 124) { 'Script timed out and was stopped' }
                            else { "Script failed (exit $code)" }
        $ui.ResSub.Text = "$($ui.ResSub.Text)  -  sandbox left running"
        $ui.ResGlyph.Text = if ($ok) { [char]0xE73E } else { [char]0xEA39 }
        $ui.ResGlyph.Foreground = Get-Brush $(if ($ok) { '#107C10' } else { '#C42B1C' })
        Add-Log "`r`nThe sandbox is still running. Use Open session to keep working in it, or Stop sandbox to throw it away.`r`n"
        $ui.ShotBtn.Visibility = 'Visible'
        $openSession = $true; $stayOnResults = $true
    } elseif ($j.wf.key -eq 'start' -or $j.wf.key -eq 'script') {
        if ($code -eq 0) {
            $ui.ResTitle.Text = 'Sandbox is running'
            $ui.ResGlyph.Text = [char]0xE73E; $ui.ResGlyph.Foreground = Get-Brush '#107C10'
            $openSession = $true
        } else {
            $ui.ResTitle.Text = 'Sandbox did not start'
            $ui.ResGlyph.Text = [char]0xEA39; $ui.ResGlyph.Foreground = Get-Brush '#C42B1C'
            Add-Log ("`r`n" + $raw)
        }
    } else {
        $pass = $false
        if ($r) {
            if ($j.wf.key -eq 'detonate') { $pass = -not $r.error } else { $pass = [bool]$r.pass }
        }
        if ($j.wf.key -eq 'detonate') {
            $ui.ResTitle.Text = if ($pass) { 'Observed (this is not a "safe" verdict)' } else { 'Detonation failed' }
        } elseif ($r -and $r.provisioned -and $pass) {
            $ui.ResTitle.Text = 'PASS (PROVISIONED - not a clean-machine test)'
        } else {
            $ui.ResTitle.Text = if ($pass) { 'PASS' } else { 'FAIL' }
        }
        $ui.ResGlyph.Text = if ($pass) { [char]0xE73E } else { [char]0xEA39 }
        $ui.ResGlyph.Foreground = Get-Brush $(if ($pass) { '#107C10' } else { '#C42B1C' })
        if ($r) {
            if ($r.error) { Add-Log "`r`nError: $($r.error)`r`n" }
            if ($r.failures) { foreach ($f in $r.failures) { Add-Log "Failure: $f`r`n" } }
            if ($r.console -and $r.console.stdout) { Add-Log ("`r`n--- app output ---`r`n" + $r.console.stdout) }
            foreach ($s in @($r.shots)) { if ($s) { Add-Shot $s.path $s.name } }
            if ($r.reportPath) { Add-Log "`r`nReport: $($r.reportPath)`r`n"; $ui.OpenReportBtn.Visibility = 'Visible' }
            if ($r.kept) { Add-Log "Sandbox left running (Keep sandbox running).`r`n"; $ui.ShotBtn.Visibility = 'Visible' }
        } else { Add-Log ("`r`n" + $raw) }
    }
    if ($r -and ($r.outDir -or $r.runDir)) { $ui.OpenFolderBtn.Visibility = 'Visible' }
    Add-Log "`r`n[exit code $code, $('{0:mm\:ss}' -f $elapsed)]`r`n"

    $script:Busy = $false
    $script:Job = $null
    $ui.List.IsEnabled = $true; $ui.DoctorBtn.IsEnabled = $true
    Update-Status
    if ($openSession) {
        # Seed the session page from the start result until the next status poll lands.
        $script:Status = [pscustomobject]@{ running = $true; id = $r.id; network = $r.network; startedAt = (Get-Date).ToUniversalTime().ToString('o')
                                            outDir = $r.outDir; provisioning = $null }
        $script:Running = $true
        Stop-Term $null
        $ui.SessLog.Clear(); $ui.SessShotsPanel.Children.Clear(); $ui.SessShotsScroll.Visibility = 'Collapsed'
        Add-SessLog "Sandbox started in $('{0:mm\:ss}' -f $elapsed). The PowerShell below is running inside it (files you push land in C:\apps). It can also be driven from a terminal (sbx term / exec / shot) or an agent (Open Claude).`r`n"
        if ($stayOnResults) { Add-SessLog "Script run finished: $($ui.ResTitle.Text). Its output is on the results page and in $($j.dir).`r`n" }
        else { Show-Session }
        # An interactive session is for driving the guest, so Claude Code comes up beside it.
        if ($j.wf.key -eq 'start') { Open-Claude }
    }
    Update-GoButton
}

# ---------------------------------------------------------------------------------------------
# Status line: sbx status --json every ~8 s while idle
# ---------------------------------------------------------------------------------------------
$script:StatusJob = $null
function Update-Status {
    if ($script:StatusJob) { return }
    $script:StatusJob = Start-Sbx @('status', '--json')
}

function Apply-Status {
    if (-not $script:StatusJob) { return }
    [void](Read-Sbx $script:StatusJob)
    if (-not (Test-SbxDone $script:StatusJob)) { return }
    $raw = $script:StatusJob.out.ToString()
    $script:StatusJob = $null
    try { $s = $raw | ConvertFrom-Json } catch { return }
    if (-not $s) { return }
    $script:Status = $s
    $script:Running = [bool]$s.running
    $stopping = $script:SessJob -and $script:SessJob.kind -eq 'stop'
    if ($s.running) {
        $ui.StatusDot.Fill = Get-Brush '#107C10'
        $extra = ''
        if ($s.provisioning) { $extra = '  -  PROVISIONED' }
        $ui.StatusText.Text = "Sandbox running  -  network $($s.network)$(Format-Since $s.startedAt)$extra"
        $ui.StopBtn.Content = 'Stop sandbox'; $ui.StopBtn.Visibility = 'Visible'
        $ui.OpenSessionBtn.Visibility = if ($script:Busy -or $ui.SessionPage.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    } elseif ($s.otherSandboxes -and @($s.otherSandboxes).Count) {
        $script:Running = $true
        $ui.StatusDot.Fill = Get-Brush '#CA5010'
        $ui.StatusText.Text = 'Another Windows Sandbox is open (not started by LockBox). Stop it to run.'
        $ui.StopBtn.Content = 'Stop other sandbox'; $ui.StopBtn.Visibility = 'Visible'; $ui.OpenSessionBtn.Visibility = 'Collapsed'
    } else {
        $ui.StatusDot.Fill = Get-Brush '#9E9E9E'
        $ui.StatusText.Text = 'No sandbox running  -  ready'
        $ui.StopBtn.Visibility = 'Collapsed'; $ui.OpenSessionBtn.Visibility = 'Collapsed'
    }
    if ($stopping) { $ui.StatusText.Text = 'Stopping sandbox...' }
    $ui.StopBtn.IsEnabled = -not $stopping
    if ($ui.SessionPage.Visibility -eq 'Visible') { Update-SessionHeader }
    Update-GoButton
}

function Format-Since($startedAt) {
    try { '  -  since ' + ([datetime]$startedAt).ToLocalTime().ToString('HH:mm') } catch { '' }
}

# ---------------------------------------------------------------------------------------------
# Session page: the running sandbox. The big box is a live PowerShell session inside the guest
# (sbx term --json, kept alive by the guest agent); the buttons below run one sbx call at a time
# and print their results into the terminal above the prompt.
# ---------------------------------------------------------------------------------------------
$script:SessHistory = New-Object System.Collections.Generic.List[string]
$script:SessHistIdx = 0
$SessControls = 'SessShotBtn', 'SessWindowsBtn', 'SessUiBtn', 'SessPushBtn', 'SessPushDirBtn', 'SessUninstallBtn', 'SessStopBtn'
$script:Term = $null      # the sbx term bridge: process, parse state, prompt/input positions in SessLog
$script:TermCharW = 0

function Add-SessLog([string]$text) { Write-Term $text }

# Text from anything but the shell itself (button results, notices): above the prompt when one is showing.
function Write-Term([string]$text) {
    if (-not $text) { return }
    $tb = $ui.SessLog
    $text = $text -replace "`r`n", "`n" -replace "`r", '' -replace "`n", "`r`n"
    $t = $script:Term
    if ($t -and $t.promptStart -ge 0) {
        if (-not $text.EndsWith("`n")) { $text += "`r`n" }
        $fromEnd = $tb.Text.Length - $tb.CaretIndex
        $tb.Select($t.promptStart, 0); $tb.SelectedText = $text
        $t.promptStart += $text.Length; $t.inputStart += $text.Length
        $tb.Select([math]::Max(0, $tb.Text.Length - $fromEnd), 0)
    } else {
        if ($tb.Text.Length -and -not $tb.Text.EndsWith("`n")) { $text = "`r`n" + $text }
        $tb.AppendText($text)
    }
    Limit-Term
    $tb.ScrollToEnd()
}

# Output from the shell: always at the end (no prompt is showing while a command runs).
function Write-TermOutput([string]$text) {
    if (-not $text) { return }
    $parts = $text -split [regex]::Escape("$([char]27)[2J")
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { Clear-Term }
        $p = $parts[$i] -replace "`r`n", "`n" -replace "`r", '' -replace "`n", "`r`n"
        if ($p) { $ui.SessLog.AppendText($p) }
    }
    Limit-Term
    $ui.SessLog.ScrollToEnd()
}

function Clear-Term {
    $ui.SessLog.Clear()
    if ($script:Term) { $script:Term.promptStart = -1; $script:Term.inputStart = 0 }
}

function Limit-Term {
    $tb = $ui.SessLog
    if ($tb.Text.Length -lt 400000) { return }
    $cut = $tb.Text.IndexOf("`n", 150000) + 1
    if ($cut -le 0) { return }
    $tb.Select(0, $cut); $tb.SelectedText = ''
    if ($script:Term) {
        if ($script:Term.promptStart -ge 0) { $script:Term.promptStart -= $cut }
        $script:Term.inputStart = [math]::Max(0, $script:Term.inputStart - $cut)
    }
    $tb.Select($tb.Text.Length, 0)
}

function Get-TermCols {
    $tb = $ui.SessLog
    if (-not $script:TermCharW) {
        $face = New-Object System.Windows.Media.Typeface($tb.FontFamily, $tb.FontStyle, $tb.FontWeight, $tb.FontStretch)
        $ft = New-Object System.Windows.Media.FormattedText('MMMMMMMMMMMMMMMMMMMM', [Globalization.CultureInfo]::InvariantCulture,
            [System.Windows.FlowDirection]::LeftToRight, $face, $tb.FontSize, [System.Windows.Media.Brushes]::White)
        $script:TermCharW = $ft.WidthIncludingTrailingWhitespace / 20
    }
    $w = $tb.ActualWidth - 40   # padding + vertical scrollbar
    if ($w -le 0) { return 120 }
    [math]::Max(40, [int][math]::Floor($w / $script:TermCharW))
}

function Start-Term {
    if ($script:Term -or -not ($script:Status -and $script:Status.running)) { return }
    $h = Start-Sbx @('term', '--json', '--cols', (Get-TermCols)) -Stdin
    $script:Term = @{ sbx = $h; partial = ''; busy = $true; awaiting = $false; secret = $false; secretBuf = ''
                      promptStart = -1; inputStart = $ui.SessLog.Text.Length; prompt = 'PS> '; compId = 0; comp = $null; compReq = $null; typeahead = '' }
    Write-Term "PowerShell inside the sandbox. Tab completes, Up/Down recall history, Ctrl+C stops a command (or copies a selection), Ctrl+L clears, Shift+Enter adds a line.`r`n"
    $ui.SessLog.IsReadOnly = $false
    $TermTimer.Start()
}

function Stop-Term([string]$why) {
    $t = $script:Term
    if (-not $t) { return }
    $TermTimer.Stop()
    $script:Term = $null
    try { $t.sbx.process.StandardInput.Close() } catch { }
    Stop-SbxTree $t.sbx
    $ui.SessLog.IsReadOnly = $true
    if ($why) { Write-TermOutput "`r`n[$why]`r`n" }
}

function Send-Term($msg) {
    $t = $script:Term
    if (-not $t) { return }
    # .NET Framework writes child stdin in the console code page, so keep the JSON pure ASCII.
    $json = [regex]::Replace((ConvertTo-Json $msg -Compress), '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    try { $t.sbx.process.StandardInput.WriteLine($json); $t.sbx.process.StandardInput.Flush() }
    catch { Stop-Term 'terminal connection lost' }
}

function Read-Term {
    $t = $script:Term
    if (-not $t) { $TermTimer.Stop(); return }
    $err = Read-Sbx $t.sbx
    if ($err) { Write-TermOutput $err }
    $sb = $t.sbx.out
    if ($sb.Length) {
        $lines = ($t.partial + $sb.ToString()) -split "`n"
        [void]$sb.Clear()
        $t.partial = $lines[-1]
        foreach ($line in @($lines | Select-Object -SkipLast 1)) {
            if (-not $line.Trim()) { continue }
            try { $m = $line | ConvertFrom-Json } catch { Write-TermOutput "$line`n"; continue }
            Invoke-TermEvent $m
            if (-not $script:Term) { return }
        }
    }
    if (Test-SbxDone $t.sbx) { Stop-Term 'terminal disconnected' }
}

function Invoke-TermEvent($m) {
    $t = $script:Term
    switch ($m.t) {
        'ready'    { if ($m.reattached) { Write-TermOutput "(reattached to the PowerShell session that was already running)`r`n" }
                     if (-not $m.busy) { Show-TermPrompt $m.prompt } }
        'out'      { Write-TermOutput $m.text }
        'prompt'   { Show-TermPrompt $m.text }
        'input'    { $t.awaiting = $true; $t.secret = [bool]$m.secret; $t.secretBuf = ''
                     $t.inputStart = $ui.SessLog.Text.Length; $t.promptStart = $t.inputStart
                     $ui.SessLog.Select($t.inputStart, 0); $ui.SessLog.ScrollToEnd(); Send-TermTypeahead }
        'complete' { Set-TermCompletion $m }
        'error'    { Write-TermOutput "[sbx] $($m.message)`r`n" }
        'closed'   { Write-TermOutput "`r`n[$($m.message)]`r`n" }
    }
}

function Show-TermPrompt([string]$prompt) {
    $t = $script:Term
    $tb = $ui.SessLog
    if ($prompt) { $t.prompt = $prompt }
    if ($tb.Text.Length -and -not $tb.Text.EndsWith("`n")) { $tb.AppendText("`r`n") }
    $t.promptStart = $tb.Text.Length
    $tb.AppendText($t.prompt)
    $t.inputStart = $tb.Text.Length
    $t.busy = $false; $t.awaiting = $false; $t.comp = $null
    $tb.Select($tb.Text.Length, 0)
    $tb.ScrollToEnd()
    if ($ui.SessionPage.Visibility -eq 'Visible') { [void]$tb.Focus() }
    Send-TermTypeahead
}

# Keys typed while the last command was finishing, like a console's type-ahead buffer.
function Send-TermTypeahead {
    $t = $script:Term
    if (-not $t.typeahead) { return }
    $tb = $ui.SessLog
    $ahead = $t.typeahead; $t.typeahead = ''
    $nl = $ahead.IndexOf("`n")
    $now = if ($nl -lt 0) { $ahead } else { $ahead.Substring(0, $nl) }
    if ($t.secret -and $t.awaiting) { $t.secretBuf += $now; $tb.AppendText('*' * $now.Length) } else { $tb.AppendText($now) }
    $tb.Select($tb.Text.Length, 0)
    if ($nl -ge 0) { $t.typeahead = $ahead.Substring($nl + 1); Submit-TermLine }
}

function Get-TermInput { $ui.SessLog.Text.Substring($script:Term.inputStart) }

function Set-TermInput([string]$text, [int]$caret = -1) {
    $t = $script:Term
    $tb = $ui.SessLog
    $tb.Select($t.inputStart, $tb.Text.Length - $t.inputStart); $tb.SelectedText = $text
    $tb.Select($(if ($caret -ge 0) { $t.inputStart + $caret } else { $tb.Text.Length }), 0)
}

function Submit-TermLine {
    $t = $script:Term
    $tb = $ui.SessLog
    if ($t.awaiting) {
        $line = if ($t.secret) { $t.secretBuf } else { Get-TermInput }
        $tb.AppendText("`r`n"); $tb.Select($tb.Text.Length, 0)
        $t.awaiting = $false; $t.promptStart = -1
        Send-Term @{ t = 'input'; text = $line }
        return
    }
    $cmd = (Get-TermInput) -replace "`r`n", "`n"
    $tb.AppendText("`r`n")
    if (-not $cmd.Trim()) { Show-TermPrompt $null; return }
    if ($script:SessHistory.Count -eq 0 -or $script:SessHistory[$script:SessHistory.Count - 1] -ne $cmd) { $script:SessHistory.Add($cmd) }
    $script:SessHistIdx = $script:SessHistory.Count
    $t.busy = $true; $t.promptStart = -1; $t.comp = $null
    $tb.Select($tb.Text.Length, 0)
    Send-Term @{ t = 'run'; command = $cmd; cols = (Get-TermCols) }
}

function Stop-TermCommand {
    $t = $script:Term
    if (-not $t) { return }
    $t.typeahead = ''
    if ($t.busy) { Write-TermOutput '^C'; Send-Term @{ t = 'break' } }
    else { $ui.SessLog.AppendText('^C'); Show-TermPrompt $null }
}

function Clear-TermScreen {
    $t = $script:Term
    if (-not $t -or ($t.busy -and -not $t.awaiting)) { Clear-Term; return }
    $keep = Get-TermInput
    Clear-Term
    if ($t.awaiting) { $t.inputStart = 0; $t.promptStart = 0; $ui.SessLog.AppendText($keep) }
    else { Show-TermPrompt $null; Set-TermInput $keep }
}

function Reset-Term {
    if (-not $script:Term) { Start-Term; return }
    $script:Term.busy = $true; $script:Term.promptStart = -1
    Write-TermOutput "`r`n[new PowerShell session]`r`n"
    Send-Term @{ t = 'reset'; cols = (Get-TermCols) }
}

function Paste-Term {
    $t = $script:Term
    if (-not $t -or ($t.busy -and -not $t.awaiting)) { return }
    $text = [System.Windows.Clipboard]::GetText()
    if (-not $text) { return }
    $tb = $ui.SessLog
    if ($t.secret -and $t.awaiting) { $t.secretBuf += $text; $tb.Select($tb.Text.Length, 0); $tb.SelectedText = '*' * $text.Length; $tb.Select($tb.Text.Length, 0); return }
    if ($tb.SelectionStart -lt $t.inputStart) { $tb.Select($tb.Text.Length, 0) }
    $tb.SelectedText = ($text -replace "`r`n", "`n" -replace "`n", "`r`n").TrimEnd()
    $tb.Select($tb.SelectionStart + $tb.SelectionLength, 0)
}

# Tab: ask the guest for completions once, then cycle through them on repeated Tab (Shift+Tab goes back).
function Invoke-TermTab([bool]$back) {
    $t = $script:Term
    $line = Get-TermInput
    if ($t.comp -and $t.comp.applied -eq $line) {
        $n = @($t.comp.matches).Count
        $t.comp.i = ($t.comp.i + $(if ($back) { -1 } else { 1 }) + $n) % $n
        Set-TermCompletionText
        return
    }
    $t.compId++
    $t.compReq = @{ id = $t.compId; input = $line }
    Send-Term @{ t = 'complete'; id = $t.compId; input = $line; cursor = ($ui.SessLog.CaretIndex - $t.inputStart) }
}

function Set-TermCompletion($m) {
    $t = $script:Term
    if (-not $t.compReq -or $m.id -ne $t.compReq.id -or $t.busy -or (Get-TermInput) -ne $t.compReq.input) { return }
    $found = @($m.matches | Where-Object { $_ })
    if (-not $found.Count) { [System.Media.SystemSounds]::Beep.Play(); return }
    $t.comp = @{ base = $t.compReq.input; index = [int]$m.replacementIndex; length = [int]$m.replacementLength; matches = $found; i = 0; applied = $null }
    Set-TermCompletionText
}

function Set-TermCompletionText {
    $c = $script:Term.comp
    $pick = [string]$c.matches[$c.i]
    $text = $c.base.Substring(0, $c.index) + $pick + $c.base.Substring([math]::Min($c.base.Length, $c.index + $c.length))
    Set-TermInput $text ($c.index + $pick.Length)
    $c.applied = $text
}

function Show-Session {
    $ui.DetailsPage.Visibility = 'Collapsed'
    $ui.ResultsPage.Visibility = 'Collapsed'
    $ui.SessionPage.Visibility = 'Visible'
    $ui.MoreBtn.Visibility = 'Hidden'; $ui.SaveRecipeBtn.Visibility = 'Hidden'
    $ui.OpenSessionBtn.Visibility = 'Collapsed'
    Update-SessionHeader
    Update-GoButton
    Start-Term
    [void]$ui.SessLog.Focus()
}

function Update-SessionHeader {
    $s = $script:Status
    $live = $s -and $s.running
    if ($live) {
        $ui.SessTitle.Text = 'Running sandbox'
        $ui.SessGlyph.Foreground = Get-Brush '#CA5010'
        $sub = "network $($s.network)$(Format-Since $s.startedAt)"
        if ($s.provisioning) { $sub += '  -  PROVISIONED (not a clean machine)' }
        if ($s.id) { $sub += "  -  $($s.id)" }
        $ui.SessSub.Text = $sub
    } else {
        $ui.SessTitle.Text = 'Sandbox stopped'
        $ui.SessGlyph.Foreground = Get-Brush '#9E9E9E'
        $ui.SessSub.Text = 'Everything inside was destroyed; artifacts stay on the host. Start another from Interactive session.'
        Stop-Term 'sandbox stopped'
    }
    $enable = $live -and -not $script:SessJob
    foreach ($c in $SessControls) { $ui[$c].IsEnabled = $enable }
    $ui.SessFolderBtn.IsEnabled = [bool]($s -and $s.outDir)
}

function Start-SessCmd([string[]]$sbxArgs, [string]$kind, [string]$echo) {
    if ($script:SessJob) { return }
    Write-Term "> $echo`r`n"
    $script:SessJob = @{ sbx = (Start-Sbx $sbxArgs); kind = $kind }
    $ui.SessProgress.Visibility = 'Visible'
    if ($kind -eq 'stop') { $ui.StopBtn.IsEnabled = $false; $ui.StatusText.Text = 'Stopping sandbox...' }
    Update-SessionHeader
    $SessTimer.Start()
}

function Complete-SessCmd {
    $SessTimer.Stop()
    $j = $script:SessJob
    $text = (Read-Sbx $j.sbx)
    $out = $j.sbx.out.ToString()
    $code = $j.sbx.process.ExitCode
    if ($j.kind -eq 'shot') {
        try {
            $r = $out | ConvertFrom-Json
            Add-Shot $r.path ('shot ' + (Get-Date -Format 'HH:mm:ss')) $ui.SessShotsPanel $ui.SessShotsScroll
            $text += "$($r.path) ($($r.width)x$($r.height))`r`n"
        } catch { $text += $out }
    } else {
        $text += $out
    }
    if ($code -ne 0) { $text += "[exit code $code]`r`n" }
    Write-Term $text
    $script:SessJob = $null
    $ui.SessProgress.Visibility = 'Hidden'
    $ui.StopBtn.IsEnabled = $true
    Update-SessionHeader
    Update-Status
    if ($ui.SessionPage.Visibility -eq 'Visible') { [void]$ui.SessLog.Focus() }
}

# Claude Code runs on the host, not in the guest: the sbx CLI drives Windows Sandbox from
# outside, and shares state with this window, so Claude works on the same sandbox. It opens in the
# LockBox folder, whose CLAUDE.md and .claude\skills tell it how. Called automatically when an
# interactive session starts, and by the session page's Open Claude button.
function Open-Claude {
    $ws = $Root
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psArgs = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg (Join-Path $PSScriptRoot 'open-claude.ps1')), '-Workspace', (Quote-Arg $ws))
    # A plain new console: Windows 11 puts it in Windows Terminal when that is the default terminal app.
    Start-Process -FilePath $ps -WorkingDirectory $ws -ArgumentList $psArgs
    Write-Term "> Open Claude`r`nClaude Code opened in its own window, controlling this sandbox with the sbx CLI.`r`n"
}

function Push-ToSession([string]$path) {
    if (-not $path) { return }
    Start-SessCmd @('push', (Quote-Arg $path)) 'push' "push $path"
}

function Stop-Sandbox {
    # From the status line or the session page: asynchronous, output goes to the session log.
    if ($script:SessJob) { return }
    Start-SessCmd @('stop') 'stop' 'sbx stop'
}

# A sandbox LockBox didn't start (another sbx install, the Windows Sandbox app) blocks every run, since
# only one can run at a time. sbx stop --force stops it; whatever was inside it is lost.
function Stop-OtherSandbox {
    if ($script:SessJob) { return }
    $ids = @($script:Status.otherSandboxes) -join ', '
    $a = [System.Windows.MessageBox]::Show("Stop the Windows Sandbox that LockBox didn't start ($ids)?`r`n`r`nEverything inside it is lost. It may belong to another sbx install or the Windows Sandbox app.", 'LockBox', 'OKCancel', 'Warning')
    if ($a -ne 'OK') { return }
    Start-SessCmd @('stop', '--force') 'stop' 'sbx stop --force'
}
# ---------------------------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------------------------
function Save-Recipe {
    if (-not $script:Current) { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $v = Get-FormValues
    $suggest = $script:Current.title
    if ($v.target) { $suggest = "$($script:Current.title): $(Split-Path $v.target -Leaf)" }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Name this recipe:', 'Save recipe', $suggest)
    if (-not $name) { return }
    $list = @(Read-Recipes | Where-Object { $_.name -ne $name })
    $opts = [ordered]@{}
    foreach ($k in $v.options.Keys) { if (($script:Current.opts -contains $k -or $script:Current.fields -contains $k) -and $v.options[$k]) { $opts[$k] = $v.options[$k] } }
    $list += [pscustomobject]@{ name = $name; workflow = $script:Current.key; target = (ConvertTo-RecipePath $v.target); args = $v.args; test = (ConvertTo-RecipePath $v.test); options = $opts }
    New-Item -ItemType Directory -Force $ConfigDir | Out-Null
    ConvertTo-Json -InputObject @($list) -Depth 5 | Set-Content -LiteralPath $Recipes -Encoding UTF8
    Fill-List
}

function Remove-Recipe([string]$name) {
    $list = @(Read-Recipes | Where-Object { $_.name -ne $name })
    ConvertTo-Json -InputObject @($list) -Depth 5 | Set-Content -LiteralPath $Recipes -Encoding UTF8
    Fill-List
    $ui.List.SelectedIndex = 0
}

# ---------------------------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------------------------
$JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$JobTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$JobTimer.Add_Tick({
    if (-not $script:Job) { $JobTimer.Stop(); return }
    Add-Log (Read-Sbx $script:Job.sbx)
    $ui.ResElapsed.Text = '{0:mm\:ss}' -f ((Get-Date) - $script:Job.started)
    if (Test-SbxDone $script:Job.sbx) { Complete-Job }
})

$SessTimer = New-Object System.Windows.Threading.DispatcherTimer
$SessTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$SessTimer.Add_Tick({
    if (-not $script:SessJob) { $SessTimer.Stop(); return }
    Add-SessLog (Read-Sbx $script:SessJob.sbx)
    if (Test-SbxDone $script:SessJob.sbx) { Complete-SessCmd }
})

$TermTimer = New-Object System.Windows.Threading.DispatcherTimer
$TermTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$TermTimer.Add_Tick({ Read-Term })

$StatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$StatusTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:StatusTick = 0
$StatusTimer.Add_Tick({
    Apply-Status
    $script:StatusTick++
    if ($script:StatusTick % 8 -eq 0 -and -not $script:Busy) { Update-Status }
})

$ui.List.Add_SelectionChanged({
    $item = $ui.List.SelectedItem
    if (-not $item -or -not $item.Tag) { return }
    if ($item.Tag.kind -eq 'recipe') { Show-Workflow $item.Tag.wf $item.Tag.recipe }
    else { Show-Workflow $item.Tag.wf $null; $ui.TargetBox.Text = ''; $ui.ArgsBox.Text = ''; $ui.TestBox.Text = '' }
})

$ui.BrowseFile.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = $script:Current.filter
    if ($d.ShowDialog($Window)) { $ui.TargetBox.Text = $d.FileName }
})
$ui.BrowseFolder.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose the app folder (sbx copies the whole folder in)'
    if ($d.ShowDialog() -eq 'OK') { $ui.TargetBox.Text = $d.SelectedPath }
})
$ui.BrowseTest.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'PowerShell scripts (*.ps1)|*.ps1'
    if ($d.ShowDialog($Window)) { $ui.TestBox.Text = $d.FileName }
})
$ui.TargetBox.Add_PreviewDragOver({ param($s, $e) $e.Effects = 'Copy'; $e.Handled = $true })
$ui.TargetBox.Add_Drop({
    param($s, $e)
    $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
    if ($files) { $ui.TargetBox.Text = $files[0] }
})

$ui.MoreBtn.Add_Click({
    if ($ui.OptionsPanel.Visibility -eq 'Visible') {
        $ui.OptionsPanel.Visibility = 'Collapsed'; $ui.MoreChevron.Text = [char]0xE70D
    } else {
        $ui.OptionsPanel.Visibility = 'Visible'; $ui.MoreChevron.Text = [char]0xE70E
        $ui.DetailsPage.ScrollToEnd()
    }
})
$ui.SaveRecipeBtn.Add_Click({ Save-Recipe })

$ui.GoBtn.Add_Click({
    if ($script:Busy) {
        # Cancel: kill the sbx process tree, then make sure no orphaned guest is left behind.
        $script:Job.cancelled = $true
        Stop-SbxTree $script:Job.sbx
        Add-Log "`r`nCancelled. Stopping the sandbox (see Open session for its log)...`r`n"
        Stop-Sandbox
        return
    }
    if ($ui.ResultsPage.Visibility -eq 'Visible' -or $ui.SessionPage.Visibility -eq 'Visible') {
        if (-not $script:Current -or $script:Current.key -eq 'doctor') { $ui.List.SelectedIndex = -1; $ui.List.SelectedIndex = 0; return }
        $ui.ResultsPage.Visibility = 'Collapsed'; $ui.SessionPage.Visibility = 'Collapsed'; $ui.DetailsPage.Visibility = 'Visible'
        if ($script:Current.opts.Count) { $ui.MoreBtn.Visibility = 'Visible' }
        $ui.SaveRecipeBtn.Visibility = 'Visible'
        if ($script:Status -and $script:Status.running) { $ui.OpenSessionBtn.Visibility = 'Visible' }
        Update-GoButton
        return
    }
    if ($script:GoOpensSession) { Show-Session; return }
    $w = $script:Current
    $v = Get-FormValues
    $err = Test-Form $w $v
    if ($err) { [System.Windows.MessageBox]::Show($Window, $err, 'LockBox', 'OK', 'Warning') | Out-Null; return }
    if ($w.key -eq 'detonate') {
        $msg = "Run this file inside Windows Sandbox?`r`n`r`n$($v.target)`r`n`r`nNetwork: $($v.options.network). Isolation is strong but not a guarantee."
        if ([System.Windows.MessageBox]::Show($Window, $msg, 'Detonate', 'OKCancel', 'Warning') -ne 'OK') { return }
    }
    $sub = $w.title
    if ($v.target) { $sub = $v.target }
    $title = switch ($w.key) { 'run' { 'Testing on a clean machine...' } 'install-test' { 'Testing installer...' } 'detonate' { 'Detonating...' }
                               'deps' { 'Scanning dependencies...' } 'start' { 'Starting a sandbox...' }
                               'script' { 'Running the script in a fresh sandbox...' } }
    $steps = @()
    if ($w.key -eq 'script') { $steps = Get-ScriptSteps $v }
    Start-SbxJob $w (Build-Args $w $v) $title $sub $steps
})

$ui.DoctorBtn.Add_Click({
    $ui.List.SelectedIndex = -1
    $w = @{ key = 'doctor'; title = 'Check this PC'; glyph = [char]0xE9D9; color = '#0067C0'; opts = @(); fields = @() }
    $script:Current = $w
    Start-SbxJob $w @('doctor', '--json') 'Checking this PC...' 'Can this machine run Windows Sandbox? (read-only)'
})

$ui.StopBtn.Add_Click({ if ($script:Status -and -not $script:Status.running -and @($script:Status.otherSandboxes).Count) { Stop-OtherSandbox } else { Stop-Sandbox } })
$ui.OpenSessionBtn.Add_Click({ Show-Session })
$ui.ShotBtn.Add_Click({ Show-Session })

# session page: the terminal. Everything before inputStart is history and can be selected and copied
# but not edited; typing anywhere jumps to the input at the end.
$ui.SessLog.Add_PreviewKeyDown({
    param($s, $e)
    $t = $script:Term
    if (-not $t) { return }
    $tb = $ui.SessLog
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $shift = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
    $editable = -not $t.busy -or $t.awaiting
    $inInput = $tb.SelectionStart -ge $t.inputStart
    if ($key -ne 'Tab' -and $key -notin 'LeftShift', 'RightShift', 'LeftCtrl', 'RightCtrl') { $t.comp = $null }
    if ($ctrl) {
        switch ($key) {
            'C' { if ($tb.SelectionLength -eq 0) { Stop-TermCommand; $e.Handled = $true } }
            'L' { Clear-TermScreen; $e.Handled = $true }
            'V' { Paste-Term; $e.Handled = $true }
            'X' { if (-not ($editable -and $inInput) -or $t.secret) { $e.Handled = $true } }
            'Back' { if (-not ($editable -and $tb.CaretIndex -gt $t.inputStart -and $inInput)) { $e.Handled = $true } }
            'Delete' { if (-not ($editable -and $inInput)) { $e.Handled = $true } }
            { $_ -in 'Z', 'Y', 'Return', 'Tab' } { $e.Handled = $true }
        }
        return
    }
    switch ($key) {
        'Return' {
            $e.Handled = $true
            if (-not $editable) { if ($t.typeahead) { $t.typeahead += "`n" }; return }
            if ($shift -and -not $t.awaiting) {
                if (-not $inInput) { $tb.Select($tb.Text.Length, 0) }
                $tb.SelectedText = "`r`n"; $tb.Select($tb.SelectionStart + 2, 0)
            } else { Submit-TermLine }
        }
        'Tab' { $e.Handled = $true; if (-not $t.busy) { Invoke-TermTab $shift } }
        'Escape' { $e.Handled = $true; if (-not $t.busy) { Set-TermInput '' } }
        { $_ -in 'Up', 'Down' } {
            if ($t.busy -or $shift) { return }
            $e.Handled = $true
            if ($key -eq 'Up' -and $script:SessHistIdx -gt 0) { $script:SessHistIdx-- }
            elseif ($key -eq 'Down' -and $script:SessHistIdx -lt $script:SessHistory.Count) { $script:SessHistIdx++ }
            else { return }
            Set-TermInput $(if ($script:SessHistIdx -lt $script:SessHistory.Count) { $script:SessHistory[$script:SessHistIdx] -replace "`n", "`r`n" } else { '' })
        }
        'Home' {
            if (-not $editable -or $tb.CaretIndex -lt $t.inputStart) { return }
            $e.Handled = $true
            if ($shift) { $tb.Select($t.inputStart, $tb.SelectionStart + $tb.SelectionLength - $t.inputStart) } else { $tb.Select($t.inputStart, 0) }
        }
        'Back' {
            if (-not $editable -or -not $inInput -or ($tb.SelectionLength -eq 0 -and $tb.CaretIndex -le $t.inputStart)) { $e.Handled = $true; return }
            if ($t.secret -and $t.awaiting) {
                $e.Handled = $true
                if ($t.secretBuf.Length) { $t.secretBuf = $t.secretBuf.Substring(0, $t.secretBuf.Length - 1); $tb.Select($tb.Text.Length - 1, 1); $tb.SelectedText = '' }
            }
        }
        'Delete' { if (-not $editable -or -not $inInput -or ($t.secret -and $t.awaiting)) { $e.Handled = $true } }
        'Left' { if (-not $shift -and $tb.SelectionLength -eq 0 -and $tb.CaretIndex -le $t.inputStart -and $tb.CaretIndex -ge $t.promptStart) { $e.Handled = $true } }
        'Space' {
            # Space arrives as a key, not always as TextInput; route it the same way as typed text.
            if (-not $editable) { $t.typeahead += ' '; $e.Handled = $true; return }
            if (-not $inInput) { $tb.Select($tb.Text.Length, 0) }
            if ($t.secret -and $t.awaiting) { $t.secretBuf += ' '; $tb.SelectedText = '*'; $tb.Select($tb.Text.Length, 0); $e.Handled = $true }
        }
    }
})
$ui.SessLog.Add_PreviewTextInput({
    param($s, $e)
    $t = $script:Term
    if (-not $t) { return }
    $tb = $ui.SessLog
    if ($t.busy -and -not $t.awaiting) { $t.typeahead += $e.Text; $e.Handled = $true; return }
    if ($tb.SelectionStart -lt $t.inputStart) { $tb.Select($tb.Text.Length, 0) }
    if ($t.secret -and $t.awaiting) {
        $t.secretBuf += $e.Text
        $tb.Select($tb.Text.Length, 0); $tb.SelectedText = '*' * $e.Text.Length; $tb.Select($tb.Text.Length, 0)
        $e.Handled = $true
    }
})
# Drag-and-drop text, cut/paste from the built-in commands: keep them out of the history part.
[System.Windows.DataObject]::AddPastingHandler($ui.SessLog, [System.Windows.DataObjectPastingEventHandler]{
    param($s, $e)
    $e.CancelCommand()
    if (-not $e.IsDragDrop) { Paste-Term }
})
foreach ($mi in $ui.SessLog.ContextMenu.Items) { if ($mi.Name) { $ui[$mi.Name] = $mi } }
$ui.SessLog.Add_ContextMenuOpening({
    $t = $script:Term
    $ui.TermCopyItem.IsEnabled = $ui.SessLog.SelectionLength -gt 0
    $ui.TermPasteItem.IsEnabled = [bool]($t -and (-not $t.busy -or $t.awaiting))
    $ui.TermBreakItem.IsEnabled = [bool]($t -and $t.busy)
    $ui.TermResetItem.IsEnabled = [bool]($script:Status -and $script:Status.running)
})
$ui.TermCopyItem.Add_Click({ if ($ui.SessLog.SelectionLength) { [System.Windows.Clipboard]::SetText($ui.SessLog.SelectedText) } })
$ui.TermPasteItem.Add_Click({ Paste-Term; [void]$ui.SessLog.Focus() })
$ui.TermBreakItem.Add_Click({ Stop-TermCommand })
$ui.TermClearItem.Add_Click({ Clear-TermScreen })
$ui.TermResetItem.Add_Click({ Reset-Term })
$ui.SessClaudeBtn.Add_Click({ Open-Claude })
$ui.SessShotBtn.Add_Click({ Start-SessCmd @('shot', '--json') 'shot' 'sbx shot' })
$ui.SessWindowsBtn.Add_Click({ Start-SessCmd @('windows') 'text' 'sbx windows' })
$ui.SessUiBtn.Add_Click({ Start-SessCmd @('ui', 'tree', '--depth', '6', '--max', '300') 'text' 'sbx ui tree' })
$ui.SessPushBtn.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = 'Copy a file into the sandbox (C:\apps\<name>)'
    if ($d.ShowDialog($Window)) { Push-ToSession $d.FileName }
})
$ui.SessPushDirBtn.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Copy a folder into the sandbox (C:\apps\<name>)'
    if ($d.ShowDialog() -eq 'OK') { Push-ToSession $d.SelectedPath }
})
$ui.SessFolderBtn.Add_Click({
    if ($script:Status -and $script:Status.outDir) { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $script:Status.outDir + '"') }
})
$ui.SessUninstallBtn.Add_Click({ Start-SessCmd @('uninstall-test') 'text' 'sbx uninstall-test' })
$ui.SessStopBtn.Add_Click({ Stop-Sandbox })
$ui.SessionPage.AllowDrop = $true
$ui.SessionPage.Add_PreviewDragOver({ param($s, $e) $e.Effects = 'Copy'; $e.Handled = $true })
$ui.SessionPage.Add_PreviewDrop({
    param($s, $e)
    $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
    if ($files -and $ui.SessPushBtn.IsEnabled) { Push-ToSession $files[0] }
    $e.Handled = $true
})

$ui.OpenReportBtn.Add_Click({ if ($script:LastResult.reportPath) { Start-Process -FilePath $script:LastResult.reportPath } })
$ui.OpenFolderBtn.Add_Click({
    $d = $script:LastResult.outDir
    if (-not $d) { $d = $script:LastResult.runDir }
    if ($d) { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $d + '"') }
})
$ui.CopyLogBtn.Add_Click({ [System.Windows.Clipboard]::SetText($ui.LogBox.Text) })
$ui.CloseBtn.Add_Click({ $Window.Close() })

$Window.Add_Closing({
    param($s, $e)
    if ($script:Busy) {
        $ans = [System.Windows.MessageBox]::Show($Window, 'A sandbox job is still running. Cancel it and close?', 'LockBox', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { $e.Cancel = $true; return }
        Stop-SbxTree $script:Job.sbx
        [void](Invoke-SbxSync @('stop') 60)
    }
    # A running interactive sandbox is left alone: the CLI or an agent may be using it, and its
    # idle watchdog stops it after SANDBOX_MCP_IDLE_MINUTES (30) with no calls.
    # The guest's PowerShell session stays alive too; the next window reattaches to it.
    Stop-Term $null
    $JobTimer.Stop(); $StatusTimer.Stop(); $SessTimer.Stop()
})

Fill-List
$ui.List.SelectedIndex = 0
Update-Status
$StatusTimer.Start()
[void]$Window.ShowDialog()
