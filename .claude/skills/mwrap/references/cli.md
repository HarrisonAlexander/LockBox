# mwrap CLI reference

`mwrap help` prints the same list. Options are `--name value` (or `--name=value`); repeatable ones say so.
A script option takes inline text or `@path\to\file.ps1`.

## Commands

| Command | Does |
|---|---|
| `mwrap inspect <installer> [--transform x.mst] [--json]` | What would be prefilled, plus the generated Install/Uninstall/Repair lines. Writes nothing. |
| `mwrap wrap <installer> [options]` | Builds a package (default output `.\<Vendor>_<Name>_<Version>`). `--json` prints the result object. |
| `mwrap init <installer> [-o spec.json] [--transform x.mst]` | Writes a prefilled spec file to edit. |
| `mwrap build <spec.json> [options]` | Builds from a spec; options given here override the spec. |
| `mwrap info <package> [--json]` | App values, detection key, files in `Files\`, signature status, PackageInfo.json. |
| `mwrap sign <package> <signing options> [--force]` | Signs `Invoke-AppDeployToolkit.ps1`, `SupportFiles\AppDetectionScript.ps1` and the module `.psm1` files not already validly signed (`--force`: all). |
| `mwrap upgrade <package> [--toolkit <dir>]` | Moves the package to the cached toolkit version, keeping your phase code. |
| `mwrap toolkit info` / `import <dir>` / `download [tag]` | Show, replace or download the PSADT v4 template new packages start from. |
| `mwrap reg <file.reg> [--remove-keys-on-uninstall]` | Prints `Set-ADTRegistryKey` (install) and `Remove-ADTRegistryKey` (uninstall) lines; HKCU goes through `Invoke-ADTAllUsersRegistryAction`. |
| `mwrap firewall --name N --program P [--direction Inbound\|Outbound\|Both] [--protocol TCP\|UDP\|Any] [--profile Domain,Private,Public]` | Prints `New-NetFirewallRule` / `Remove-NetFirewallRule` lines. |
| `mwrap version [--json]` | mwrap, PowerShell host and PSADT template versions. |

The `wrap`/`build` result (`--json`): `Path, Script, Toolkit, Installer, Transform, Vendor, Name, Version,
Architecture, Processes, DetectionKey, DetectionRules, Signed`.

## Wrap / build options

**Output:** `-o, --output <dir>`, `--force` (overwrite a non-empty folder), `--no-copy` (don't copy installers
into `Files\`), `--support-file <path>` (repeatable, into `SupportFiles\`), `--toolkit <dir>`, `--spec <file>`
(wrap only), `--transform <x.mst>`, `--add-installer <path>[::args]` (repeatable; appended to all three actions),
`--skip-syntax-check`, `--json`.

**App (`$adtSession`):** `--vendor --name --version --arch x86|x64|arm64 --lang --revision --author
--script-version --install-name --install-title --success-codes 0,3010 --reboot-codes 1641,3010`.

**Session:** `--deploy-mode Auto|Interactive|Silent|NonInteractive` (the script's default; the command line
`-DeployMode` wins), `--suppress-reboot-passthru`, `--terminal-server`, `--disable-logging`, `--no-require-admin`,
`--no-oobe-detection`, `--no-session-detection`, `--force-wim-detection`.

**Processes to close:** `--process <name>[=<description>]` (repeatable), `--no-processes`. Default: the
executables the MSI/MSIX shortcuts target, minus java, cmd, msiexec, explorer.

**Pre-actions** (all three Pre phases): `--welcome` / `--no-welcome` (on by default when there are processes),
`--countdown <sec>` (1800), `--force-countdown`, `--allow-defer [Allow|IfProcessesRunning]`, `--defer-times <n>` (3),
`--minimize-windows`, `--block-execution`, `--progress`, `--prompt <text>`.

**Main actions:** `--install-args`, `--uninstall-args`, `--repair-args` (MSI: AdditionalArgumentList; EXE:
ArgumentList; an EXE repair line is only written when `--repair-args` is given), `--no-exe-detection` (don't
auto-detect EXE silent switches), `--install-script`, `--uninstall-script`, `--repair-script` (replace the
generated line).

**Custom code:** `--pre-install-script`, `--post-install-script`, `--pre-uninstall-script`,
`--post-uninstall-script`, `--pre-repair-script`, `--post-repair-script` (`<text|@file>`).

**Post-actions:** `--post-prompt <text>`, `--restart-prompt`, `--restart-countdown <sec>[,<nohide sec>]`.

**Upgrade** (Pre-Install `#region`s): `--remove-msi <{ProductCode}>[::<name>::<version>]` (repeatable),
`--remove-msi-name <display name>` (repeatable) with `--name-match Contains|Exact|Wildcard|Regex` and
`--remove-filter '<{ scriptblock }>'`, `--remove-exe <uninstaller path>[::<arguments>]`, `--upgrade-params <msi args>`,
`--continue-on-error`.

**Detection:** `--detection-key <template>` (default `HKLM\SOFTWARE\InstalledApps\{AppVendor}_{AppName}_{AppVersion}`),
`--no-detection-key`, `--detect-msi [--detect-msi-version GreaterThanOrEqualTo]`,
`--detect-registry <key>[::<value name>]`, `--detect-file <path>::<file>[::<version>]`, `--detection-script <file.ps1>`.

**Package info:** `--description`, `--notes`, `--info-url`, `--category "<Intune category>"` (repeatable).

**config.psd1:** `--config Section.Key=Value` (repeatable), shortcuts `--log-path`, `--company-name`,
`--dialog-style Fluent|Classic`, `--accent-color FF0078D7`.

**Branding:** `--logo <png>`, `--logo-dark <png>`, `--banner <png>`, `--app-logo <png|ico|exe>`, `--use-app-logo`.

**Signing:** `--sign-method pfx|thumbprint|azure|authenticode`, `--cert <pfx>`, `--cert-password <pw>` (or
`MWRAP_PFX_PASSWORD`), `--thumbprint <sha1>`, `--timestamp <url|none>` (default http://timestamp.acs.microsoft.com),
`--signtool <exe>`, `--azure-endpoint`, `--azure-account`, `--azure-profile`. `authenticode` needs no Windows SDK.

## Environment

| Variable | Effect |
|---|---|
| `MWRAP_TOOLKIT` | PSADT template folder to use instead of the cached one |
| `MWRAP_DATA` | Where the exe unpacks its engine and keeps downloaded toolkits (default `%LOCALAPPDATA%\mwrap`) |
| `MWRAP_POWERSHELL` | PowerShell to run the engine with (default: pwsh on PATH, else Windows PowerShell 5.1) |
| `MWRAP_PFX_PASSWORD` | PFX password for signing |
| `MWRAP_DEBUG=1` | Stack traces on errors |

## Spec file

`mwrap init` writes one with every section and the prefilled values; `examples\full.mwrap.json` (in the mwrap
source, and inside the exe's engine folder) uses every section. Relative paths resolve against the spec file;
script fields take text or `@file.ps1`.

```jsonc
{
  "installer": "app.msi", "transform": null, "output": "out\\App_1.0", "copyInstallers": true,
  "additionalInstallers": [ { "path": "addon.msi", "arguments": "ADDLOCAL=ALL" } ],
  "supportFiles": [ "settings.json" ],
  "app": { "vendor": "", "name": "", "version": "", "arch": "x64", "lang": "EN", "revision": "01",
           "scriptVersion": "1.0.0", "author": "", "successExitCodes": [0], "rebootExitCodes": [1641, 3010] },
  "session": { "deployMode": "Auto", "requireAdmin": true },
  "processes": [ { "name": "app", "description": "App" } ],
  "preActions": {          // install | uninstall | repair
    "install": { "prompt": null, "progress": true, "script": null,
                 "welcome": { "enabled": true, "closeProcesses": true, "countdown": 1800, "forceCountdown": false,
                              "allowDefer": "Allow", "deferTimes": 3, "minimizeWindows": true, "blockExecution": true } } },
  "mainActions": { "install": { "arguments": "ALLUSERS=1", "script": null, "append": null },
                   "uninstall": { "arguments": null }, "repair": { "arguments": null } },
  "postActions": { "install": { "prompt": "Done.", "script": null,
                   "restartPrompt": { "enabled": false, "countdown": true, "countdownSeconds": 1800, "countdownNoHideSeconds": 300 } } },
  "upgrade": [
    { "type": "msiProductCode", "productCode": "{...}", "productName": "Old", "productVersion": "1.0", "continueOnError": true },
    { "type": "msiProductName", "productName": "App", "nameMatch": "Contains",
      "filters": [ { "property": "Publisher", "operator": "Equals", "value": "Contoso" } ] },
    { "type": "exe", "productName": "Old", "uninstallExePath": "%ProgramFiles%\\Old\\unins000.exe", "parameters": "/VERYSILENT" } ],
  "detection": { "registryKey": true, "keyTemplate": "HKLM\\SOFTWARE\\InstalledApps\\{AppVendor}_{AppName}_{AppVersion}",
                 "rules": [ { "type": "Registry", "keyPath": "HKLM\\SOFTWARE\\App", "valueName": null, "detectionMethod": "KeyExists" },
                            { "type": "File", "path": "%ProgramFiles%\\App", "fileOrFolder": "app.exe", "detectionMethod": "FileOrFolderExists" },
                            { "type": "Msi", "productCode": "{...}", "shouldCheckVersion": false } ],
                 "script": null },
  "packageInfo": { "description": "", "notes": "", "informationUrl": "", "intuneAppCategories": [ "Productivity" ] },
  "config": { "Toolkit": { "CompanyName": "Contoso IT", "LogPath": "$envProgramData\\Logs" }, "UI": { "DialogStyle": "Fluent" } },
  "assets": { "logo": null, "logoDark": null, "banner": null, "appLogo": "auto", "useAppLogoAsDialogLogo": false },
  "signing": { "method": "none" }   // pfx: certificatePath, certificatePassword; thumbprint: thumbprint;
                                    // azure: endpoint, accountName, certificateProfile; all: timestampServer, signtool
}
```

Intune categories: Business, Collaboration & Social, Computer Management, Data Management, Development & Design,
Books & Reference, Photos & Media, Productivity, Other apps.
