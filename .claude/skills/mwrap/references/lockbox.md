# Testing a PSADT package in LockBox

LockBox (`sbx.cmd` in the LockBox folder) runs Windows Sandbox. Its `mwrap-*` commands wrap with mwrap on the
host and run the package in a fresh guest the way Intune would. Run them from the LockBox folder as
`.\sbx.cmd ...`. LockBox finds mwrap at `app\mwrap\mwrap.exe`, then `MWRAP_EXE` (data\lockbox.env), then PATH.

Only one sandbox can run at a time: check `.\sbx.cmd status` first, and don't stop a sandbox you didn't start
unless the user asks.

## mwrap-test

```
.\sbx.cmd mwrap-test <installer | spec.json | package folder> [options]
```

1. Wraps on the host (`mwrap wrap ... --json`; `build` for a spec; skipped for a package folder). A wrap error
   stops here, before any sandbox boots.
2. Boots a sandbox, turns Smart App Control off in the guest (otherwise unsigned installer stubs are blocked
   or stall ~2 minutes), copies the package to `C:\sbx-test\package\<Vendor>_<Name>_<Version>` and mwrap.exe
   to `C:\sbx-test\mwrap\mwrap.exe`, and snapshots the machine.
3. Runs `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode <mode>`, checks the detection key,
   snapshots, then the optional Repair and Uninstall runs (uninstall reports leftovers against the first snapshot).
4. Copies the PSADT and MSI logs out (from the package's `Toolkit.LogPath` / `MSI.LogPath` and
   `C:\Windows\Logs\Software`) and writes the report. The sandbox stays running unless `--no-keep`.

| Option | Meaning |
|---|---|
| `--mode silent` (default) | `-DeployMode Silent`: no dialogs, as Intune runs it. A run that waits for input is killed at the timeout and fails. |
| `--mode interactive` | `-DeployMode Interactive`: PSADT dialogs (close apps, defer, progress, prompts) show in the sandbox window. The user answers them; nothing is clicked automatically. |
| `--install-args "<args>"` | Installer arguments (MSI properties or the EXE silent switch), passed to mwrap. |
| `--uninstall-args`, `--repair-args`, `--transform`, `--spec` | Passed to mwrap. |
| `--mwrap "<options>"` | Any other mwrap wrap options as one string, e.g. `"--progress --remove-msi-name 'Old App' --process app=App"`. Double or single quotes group. |
| `--repair`, `--uninstall` | Also run those deployment types (only after a successful install). |
| `--timeout <sec>` | Per PSADT run. Default 900 silent, 3600 interactive. |
| `--no-keep`, `--network on\|firewall\|off`, `--offline`, `--memory`, `--no-gpu`, `--exclude`, `--max`, `--fail-on-leftovers`, `--json`, `--open` | As in install-test. |

PASS means every run exited 0 / 3010 / 1641, the detection key (when the package has one) was present after
install and repair and gone after uninstall, and nothing is still in Add/Remove Programs after uninstall.

## Where things land (host)

`.\sbx.cmd status` gives the run's `outDir` while it is running; the result JSON has it too.

```
<outDir>\
  package\<Vendor>_<Name>_<Version>\   the package that was tested, installer in Files\ (ready for IntuneWinAppUtil)
  logs\                                 PSADT logs (<App>_PSAppDeployToolkit_<Type>.log) and MSI verbose logs
  report.md / report.json               runs, exit codes, detection, main actions, log warnings/errors, diffs, screenshots
  mwrap-result.json                     mwrap's wrap result (DetectionKey, Processes, Signed, ...)
  mwrap-state.json                      what mwrap-run / mwrap-pull use
  screenshots\                          after each run (and on a timeout)
  files\package-from-sandbox-<stamp>\   after mwrap-pull
```

## Follow-up commands on the running sandbox

- `.\sbx.cmd mwrap-run install|uninstall|repair [--mode silent|interactive] [--timeout <sec>] [--json]` runs the
  package again (report `mwrap-<type>-report-<stamp>.md`; uninstall also diffs leftovers).
- `.\sbx.cmd mwrap-pull` copies `C:\sbx-test\package\...` back out, including anything changed inside the
  sandbox (e.g. the user edited the script or re-wrapped with `C:\sbx-test\mwrap\mwrap.exe`), and refreshes logs.
- `.\sbx.cmd exec "<powershell>"`, `.\sbx.cmd shot`, `.\sbx.cmd windows`, `.\sbx.cmd ui tree` to look around.
- `.\sbx.cmd stop` destroys the sandbox (artifacts stay on the host). Only when the user is done.

In the LockBox window the same thing is the **Wrap and test (PSADT)** workflow (Silent / Interactive choice,
Installer arguments, mwrap options; Test repair / Test uninstall under More options). Its session page has
**Uninstall test** (runs the package's uninstall) and **Copy package out**.

## Reading a failure

| Symptom | Likely cause |
|---|---|
| `mwrap wrap failed: ...` | Bad installer or option; fix and rerun (no sandbox was started). |
| Install timed out (silent) | Something waited for input: an EXE without its silent switch, or a prompt the package forces. Check the screenshot. |
| Exit 1602 | The user deferred or cancelled a dialog (interactive). |
| Exit 1618 | A PSADT dialog timed out, or another install was running. |
| Exit 60001 / 600xx | Script or toolkit error: read the PSADT log's error lines (also in the report). |
| Exit 1 (or another small code) within seconds | The installer aborted at startup, often over a missing prerequisite (git-lfs exits 1 without Git). Read its own log: rerun it in the kept sandbox with `.\sbx.cmd exec` and its log switch (Inno: `/LOG=C:\x.log`). To test with the prerequisite, install it in the kept sandbox, then `.\sbx.cmd exec "$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine'); & C:\sbx-test\package\<pkg>\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent"` (a plain `mwrap-run` keeps the stale PATH). |
| Exit is the installer's own code (e.g. 1603) | The installer failed; read the MSI log in `logs\`. |
| Detection key missing after install | The Post-Install phase didn't run or the key template is wrong; read the PSADT log. |
| Leftovers after uninstall | Usually Windows noise (.NET breadcrumbs, TrustedPublisher stores) plus the empty `HKLM\SOFTWARE\InstalledApps` parent key, which MasterWrapper also leaves; look for app folders and keys. |
