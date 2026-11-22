# PSADT package to Chocolatey package (`mwrap choco`)

`mwrap choco` wraps a PSAppDeployToolkit package folder in a Chocolatey package. It uses the templates from
chocolatey-community's PSAdt-Webinar repo, which are embedded in mwrap.exe, so you don't need the repo,
`Copy-Template.ps1` or `choco new`. Chocolatey itself is optional: without it, mwrap packs the `.nupkg` itself.

## The usual flow

```cmd
mwrap wrap setup.msi -o C:\Pkg\Vendor_App_1.2.3          :: the PSADT package (Path in the output)
mwrap choco C:\Pkg\Vendor_App_1.2.3 -o C:\Choco\app        :: the Chocolatey package + app.1.2.3.nupkg
```

When the user says "build it into a chocolatey package" after a wrap, the input is the wrap's output folder
(`Path`). For a package built earlier, run `mwrap info <dir>` first to confirm that it is a PSADT package.

The result (`--json` for an object) lists `Id`, `Version`, `Template`, `Path` (the Chocolatey source folder), `Nuspec`,
`Nupkg`, `Packer` (`choco` or `builtin`), `Zip`/`Location` (large template only) and `InstallCommand`
(`choco install <id> --source "<folder>" -y`).

## What it builds

```
<output>\<id>.nuspec
<output>\tools\chocolateyinstall.ps1      runs Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode <mode>
<output>\tools\chocolateyuninstall.ps1    runs -DeploymentType Uninstall (with --uninstall psadt, the default)
<output>\tools\.skipAutoUninstall         so Chocolatey's AutoUninstaller doesn't also run
<output>\tools\<id>\                      the PSADT package, copied as-is
<output>\<id>.<version>.nupkg
```

The install script finds the PSADT folder by `$env:ChocolateyPackageName`, so the folder always gets the package id.
After a successful install, it writes `.ignore` files so Chocolatey doesn't shim the package's exes.

## Options

| Option | Default | Notes |
|---|---|---|
| `--id` | AppName lowercased, non-alphanumerics to `-` (`Notepad++` becomes `notepadplusplus`) | lowercase letters, digits, `.`, `-` |
| `--version` | AppVersion (the numeric part is taken from values like `24.08 build 3`) | 1-4 numeric parts, optional `-prerelease` |
| `--title` / `--organization` / `--description` / `--tag` | AppName / AppVendor / template text / `psadt` | nuspec `title` (shown with " (PSADT)" after it), `authors`, extra description, extra tags |
| `--template` | `psadtv4` (`psadtv3` for a v3 package) | `psadtv4-large` for packages over 2 GB |
| `--location` | none | psadtv4-large: UNC path or URL the zip will be hosted at; implies psadtv4-large |
| `--deploy-mode` | `Interactive` | Default when no `/DeployMode` package parameter is given |
| `--uninstall` | `psadt` | `auto` leaves the uninstall to Chocolatey's AutoUninstaller (webinar default) |
| `-o, --output` | `.\<id>` | `--force` replaces a non-empty folder |
| `--packer` | `auto` | `auto`: choco pack if installed, else builtin (also used if choco pack fails, e.g. paths over 260 chars); `choco`; `builtin` |
| `--no-pack` | | Only write the nuspec + tools (run `choco pack` later) |

At install time the deploy mode can be overridden with a package parameter:
`choco install <id> -y --package-parameters="/DeployMode='Silent'"` (`Interactive`, `Silent`, `NonInteractive`).

### Choosing the deploy mode

- `Interactive` (default): PSADT shows its dialogs and allows deferrals. A deferral **fails** the choco install
  (PSADT exit 1602) until the deferral count is used up. This is the webinar's intended behaviour.
- `Silent`: nothing asks the user and the install can't be deferred. Use this for unattended runs (SYSTEM, RMM, CI).

## Large packages (over 2 GB)

A nupkg can't go past about 2 GB. With `--location`, mwrap zips the PSADT folder to `<output>\..\<id>.<version>.psadt.zip`
(the zip holds a top-level `<id>\` folder) and builds a small nupkg. That nupkg downloads the zip from the location,
checks it against the SHA-256 written into `chocolateyinstall.ps1`, and unpacks it with .NET. It doesn't use Chocolatey's
unsigned `7z.exe`, which Smart App Control and WDAC block. Copy the zip to that location before anyone installs. A
rebuilt zip gets a new checksum, so republish the nupkg as well.

## Testing in a sandbox

Windows Sandbox has no Chocolatey, so install it in the guest first (network on, official script). Then push the
`.nupkg` to a feed folder (for example `C:\feed`) and run `choco install <id> --source C:\feed -y`. Put the commands
in a script and run it with `sbx exec ... -File <script>`: `sbx exec` mangles quoted arguments that contain spaces,
and `$var =` in an inline `-Command`. The sandbox enforces Smart App Control, so unsigned .NET custom actions in an
MSI (DTF `Microsoft.Deployment.WindowsInstaller.dll`) can fail with 1603 (CodeIntegrity event 3077). That failure
comes from the MSI, not from the Chocolatey package; running `Invoke-AppDeployToolkit.exe` directly fails the same way.

```cmd
mwrap choco C:\Pkg\Big_App_5.0 --location \\fileserver\choco\big-app.5.0.psadt.zip
```

## Exit codes

| Code | Result |
|---|---|
| 0 | Success |
| 1641, 3010 | Success with a restart required. It is passed on to Chocolatey, which treats it as success and reports the reboot (mwrap change; the original templates failed here). |
| 1602 | The user deferred or cancelled (PSADT v4). The install fails. |
| 1618 | A dialog timed out, or another installation was running. The install fails. |
| 60000-69999 | PSADT errors; read the PSADT log. |

## Templates on their own

`mwrap choco-templates` lists the templates. `mwrap choco-templates export [dir] [--template psadtv4] [--force]`
copies them to `dir`; without `dir` they go to `$env:ChocolateyInstall\templates`, which usually needs admin. You can
then use `choco new <id> --template psadtv4 ...` directly. The PSADT uninstall script is saved in each v4 template as
`tools\chocolateyuninstall.ps1.txt`; rename it to use it.

## Rules

- Build from the PSADT package folder, not the installer. Wrap first, then run `choco`.
- Don't `choco install` on the host, and don't `choco push` to any feed, unless the user asks. Test in a sandbox.
- If AppVersion isn't a valid NuGet version (for example `2.47.1.windows.2`), mwrap uses the numeric prefix. If there
  isn't one, it stops and asks for `--version`.
