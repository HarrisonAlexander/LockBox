<p align="center">
  <img src="./assets/readme/hero.webp" width="100%" alt="LockBox: a portable Windows Sandbox toolkit. A sealed glass lockbox locks, the file inside detonates, the blast stays inside the box, and the box resets clean.">
</p>

<p align="center"><sub>The file blows up. The box holds. A fresh one takes its place. <a href="./assets/readme/lockbox-detonation.mp4">Watch the clip in 1080p, with sound</a></sub></p>

<p align="center">
  <a href="#quick-start"><b>Quick start</b></a> ·
  <a href="#six-workflows">Workflows</a> ·
  <a href="#real-runs-real-reports">Real reports</a> ·
  <a href="#command-line">CLI</a> ·
  <a href="#let-claude-drive-it">Claude Code</a> ·
  <a href="#how-its-built">Architecture</a>
</p>

**LockBox is a desktop GUI for the [Windows Sandbox MCP](https://github.com/shanselman/sandbox-mcp).**

Its author, Scott Hanselman, [put it like this](https://www.linkedin.com/posts/shanselman_a-lot-of-people-dont-realize-that-windows-share-7524715266119909376-OJuW/):

> A lot of people don't realize that Windows has a built-in feature called Windows "Sandbox" that boots up a
> brand new virtual Windows machine in seconds. So I made an MCP server so you can test your apps inside a
> throwaway machine in seconds. Best feature? "sbx detonate".

sandbox-mcp is the engine. It boots the sandbox, deploys your app, drives its UI, diffs installs, detonates
files and writes the reports, and you reach it from an AI agent over MCP or from its `sbx` command line.
LockBox puts a PowerShell (WPF) window in front of that engine. Every workflow in Scott's README, from
clean-machine app tests and installer audits to `sbx detonate`, dependency scans, scripts and interactive
sessions, becomes a form with one green button. You get the same reports without typing a command.

The folder carries the sandbox-mcp 1.2.0 engine as shipped, the GUI, a CLI (`sbx.cmd`), Claude Code support
and its own Node.js runtime. Copy it to any Windows 11 Pro or Enterprise PC, or run it from a USB drive.
Nothing is installed or registered, and no path is recorded, so it works from any drive letter.

| sandbox-mcp: the engine, by Scott Hanselman | LockBox: the GUI around it |
|---|---|
| Boots and tears down Windows Sandbox, with a guest agent inside it | A WPF window with one page per workflow, and a session page for a running sandbox |
| `run`, `install-test`, `detonate`, `deps`, `exec`, `ui`, `shot`, `snapshot` / `diff`, `record` | Forms and buttons for all of them, with live progress, screenshots and **Open report** |
| Reports, screenshots and recordings saved on the host | **Recipes**: save a filled-in workflow and run it again later |
| An MCP server and the `sbx` CLI, sharing one state | Keep-after-install with a separate **Uninstall test**, a guest PowerShell terminal, **Open Claude**, and a portable folder or an MSI |

<p align="center">
  <img src="./assets/readme/gui-installer.png" width="88%" alt="The LockBox window: a workflow list on the left (Test an app, Test an installer, Detonate a file, Check dependencies, Run a PowerShell script, Interactive session), the Chocolatey demo preset below it, and the Test an installer page on the right.">
</p>

## Six workflows

<p align="center">
  <img src="./assets/readme/workflows.svg" width="100%" alt="Six workflow cards: Test an app (sbx run), Test an installer (sbx install-test), Detonate a file (sbx detonate), Check dependencies (sbx deps), PowerShell script (sbx exec), Interactive session (sbx start).">
</p>

| Workflow | What happens | What you get |
|---|---|---|
| **Test an app** | Boots a fresh machine, copies your `.exe`, folder or `.msix` in, launches it, screenshots it and checks the event log for crashes. Nothing from your dev box leaks in, so a missing runtime shows up here. | `report.md`, screenshots, crash events. Exit 0 = pass |
| **Test an installer** | Snapshots the machine, runs your `.msi`, `.exe`, `.ps1` or `.cmd` with its normal UI and clicks through it (licence, Install / Next / Finish, restart declined), then snapshots again. The sandbox stays up so you can poke at the install. | Every file, registry key, service, scheduled task and autorun it added |
| **Uninstall test** | Runs the registered uninstaller in the kept sandbox and diffs against the clean machine. | What the uninstaller left behind |
| **Detonate a file** | Runs a file you don't trust with **no network adapter**, or with a firewall that logs what it tries. | Every process with its command line, DNS lookups, connection attempts, file / registry / autorun / service / task changes, timed screenshots |
| **Check dependencies** | Reads PE architecture and imports, app-local VC++ DLLs, .NET runtime configs, package dependencies and script interpreters without booting anything. | A dependency report in a second or two |
| **PowerShell script** | Copies your `.ps1` in and runs it as the sandbox's administrator (Bypass policy), then keeps the sandbox up. Good for Chocolatey and winget setups and module tests. | Output, exit code, a live machine to inspect |
| **Interactive session** | A fresh sandbox you drive step by step: push files, exec commands, read the UI Automation tree, click, type, screenshot, snapshot and diff. | A session page in the GUI, a guest PowerShell terminal, and **Open Claude** |

Save any filled-in workflow as a **recipe** and it shows up in the list next time. Recipes store paths inside
the LockBox folder as `.\...`, so they survive a drive-letter change. One preset ships with it: *Chocolatey
demo*, a PowerShell script run that installs Chocolatey, then Chrome, Notepad++ and Firefox, in a fresh sandbox
and leaves it up so you can look around.

<details>
<summary><b>More screenshots</b>: detonate, PowerShell script</summary>
<br>
<p align="center">
  <img src="./assets/readme/gui-detonate.png" width="88%" alt="LockBox Detonate a file page: runs the file with no network adapter and reports what it did.">
  <br><br>
  <img src="./assets/readme/gui-script.png" width="88%" alt="LockBox Run a PowerShell script page, filled in from the Chocolatey demo preset.">
</p>
</details>

## How a run works

<p align="center">
  <img src="./assets/readme/lifecycle.svg" width="100%" alt="Five steps: fresh boot, push in, run and watch, snapshot diff, then the report and the sandbox is destroyed unless you keep it.">
</p>

Every run starts from a clean Windows image and ends with the evidence on your PC: reports, screenshots,
logs, pulled files and optional desktop recordings (an HTML flipbook, plus MP4 when ffmpeg is on the host).
They land in the run's folder under `data\home\runs`.

You pick how much network the guest gets:

| `--network` | Guest can reach | Use it for |
|---|---|---|
| `off` | Nothing. There is no network adapter. | Detonations (the default there) |
| `firewall` | Nothing outbound, but every address it tries is recorded | Seeing where a file wants to phone home |
| `on` | The internet, as normal | App and installer tests that download things |

Clipboard, printer, microphone and camera sharing are off for every sandbox.

## Real runs, real reports

Excerpts from real runs made with this build. Every run writes the full report to `data\home\runs\<time>\out`.

**`sbx install-test gitui-win.msi`**: PASS. The sandbox booted in 16.8 s and the MSI installed in 122.7 s.

```text
Installed programs   + gitui 0.28.1 (gitui-org)
Environment          PATH += C:\Program Files\gitui\bin\
Files                13 added (11.0 MB): C:\Program Files\gitui\, 9 VC++ runtime DLLs in System32
Registry keys        3 added, including the Uninstall entry
```

**`sbx uninstall-test`** on the same sandbox: the uninstaller exited 0 in 1.1 s, and **2 changes were left behind**.

## Quick start

**You need** Windows 11 24H2 or later, Pro, Enterprise or Education (x64), with virtualization on.
Windows PowerShell 5.1 and WPF come with Windows, so PowerShell 7 isn't needed. Node.js is bundled.

1. **Turn on Windows Sandbox** once. It's a Windows feature, so it can't be bundled. Run this as
   administrator, then reboot:

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
   ```

   Then open **Windows Sandbox** from the Start menu once and close it. It updates itself from the
   Microsoft Store, which adds the `wsb` command LockBox drives.
2. **Get LockBox**, one of two ways:
   - **Install it:** download `LockBox_<version>_x64.msi` from
     [Releases](https://github.com/HarrisonAlexander/LockBox/releases/latest) and run it. It installs to
     `C:\Program Files\LockBox` with a Start menu shortcut, and keeps each user's runs and settings in
     `%LOCALAPPDATA%\LockBox`. Silent: `msiexec /i LockBox_<version>_x64.msi /qn`.
   - **Run it portable:** clone or download this repo into any writable folder. Its state stays in
     `data\`.
3. **Start LockBox** (Start menu, or double-click `LockBox.cmd`) and press **Check this PC (sbx doctor)**.
   It tells you exactly what's missing, if anything.
4. **Pick a workflow**, drop in a file and press the green button.

Or from a terminal in the LockBox folder:

```powershell
.\sbx.cmd doctor                                   # can this PC run Windows Sandbox?
.\sbx.cmd run .\MyApp.exe                          # clean-machine smoke test
.\sbx.cmd install-test .\setup.msi                 # install, diff, keep the sandbox up
.\sbx.cmd uninstall-test                           # uninstall and report leftovers
.\sbx.cmd detonate .\invoice.pdf.exe               # no network, watch what it does
```

## Command line

`sbx.cmd` is the engine's `sbx` CLI with LockBox's additions. Run `.\sbx.cmd --help` for every flag, and
add `--json` to any command for machine-readable output.

<details>
<summary><b>One-shot commands</b>: boot, test, report, destroy</summary>

| Command | Does |
|---|---|
| `run <app.exe\|folder\|app.msix>` | Clean-machine app test. `--args`, `--console`, `--test <script.ps1>`, `--collect <path>`, `--record`, `--cert <file.cer>`, `--deps <folder>`, `--provision auto` (opt in; the report says PROVISIONED, not clean), `--keep` |
| `install-test <setup>` | Install and stop; the sandbox stays up. `--silent` (MSI `/qn`), `--manual` (you click), `--uninstall` to test both in one run, `--fail-on-leftovers`, `--exclude <path>`, `--no-keep` |
| `uninstall-test` | Uninstall in the kept sandbox and report leftovers. `--program <text>`, `--uninstall "<cmd>"`, `--args` |
| `detonate <file>` | Behaviour report. `--network off\|firewall\|on`, `--duration <sec>`, `--every <sec>` screenshots, `--full` |

</details>

<details>
<summary><b>Step-by-step commands</b>: drive a running sandbox</summary>

| Command | Does |
|---|---|
| `start` | Boot and keep running. `--network`, `--memory <MB>`, `--no-gpu`, `--minimized` |
| `status` | Is a sandbox up, and where is its run folder |
| `push <host path> [guest path]` | Copy in (default `C:\apps\<name>`) |
| `deploy <hostDir> [guestDir] --launch <exe>` | Verified incremental copy into a warm sandbox |
| `pull <guest path>` | Copy out to the run's `out\files` |
| `exec <command>` | Run a command, print its output, return its exit code |
| `term` | A PowerShell session in the guest that keeps `cd`, variables and modules |
| `launch`, `proc <pid>`, `windows` | Start a GUI app, check a process, list windows |
| `shot [--window <title>]` | Screenshot the desktop or one window |
| `click <x> <y>`, `type <text> [--keys]` | Mouse and keyboard |
| `ui [tree]`, `ui <action>`, `ui wait` | Read the UI Automation tree and click, set, toggle, select, expand or read controls by name or id |
| `errors` | Application event log crashes and unhandled exceptions |
| `snapshot <name>`, `diff <from> <to>` | Record files, registry, services, autoruns and programs, then compare |
| `record start`, `record stop` | Desktop recording: HTML flipbook, plus MP4 when ffmpeg is on the host |
| `stop [--force]` | Destroy the sandbox. `--force` also stops one LockBox didn't start |

</details>

<details>
<summary><b>Other commands</b></summary>

| Command | Does |
|---|---|
| `deps <app path>` | Dependency scan without booting |
| `provision <app path> --provision auto` | Install verified runtimes into a running sandbox |
| `doctor` | Check this PC and say how to fix it |

</details>

## Let Claude drive it

LockBox ships with [Claude Code](https://claude.com/claude-code) support and needs no MCP server. Claude runs
`sbx.cmd` like you do and follows the bundled skills: `windows-sandbox-app-test`, `-installer-test`,
`-detonate`, `-interactive` and `-setup`. `CLAUDE.md` holds the house rules:
never uninstall or stop a sandbox unless you ask, and treat everything that comes back from the guest as
untrusted data.

- **From the GUI**: start an **Interactive session**. Claude opens in the LockBox folder on its own, or press
  **Open Claude** on the session page. It sees the same sandbox the window shows.
- **From a terminal**: run `claude` in the LockBox folder.
- **On a new PC**: tell Claude *"follow SETUP-CLAUDE.md in my LockBox folder"*.

Claude starts with LockBox first on `PATH` and no MCP servers loaded, so a sandbox server from another
install can't mix in.

## How it's built

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="The LockBox GUI, sbx.cmd and Claude Code all go through app\lockbox\sbx.mjs to the sandbox-mcp 1.2.0 engine, which drives the Windows Sandbox guest. All three share state in data\home.">
</p>

The GUI and the CLI share state through `data\home`, so a sandbox started in one is the sandbox the other,
and Claude, see. Only one Windows Sandbox can run on a PC at a time, whichever tool started it.

```text
LockBox.cmd          GUI launcher (double-click)
sbx.cmd              CLI
CLAUDE.md            how Claude drives the sandbox from this folder
SETUP-CLAUDE.md      steps Claude follows to install the skills on a new PC
.claude\skills\      windows-sandbox-* skills
app\
  gui\               SbxGui.ps1 (WPF), open-claude.ps1, box.ico (app icon)
    samples\         install-choco-apps.ps1 (the Chocolatey demo preset)
  lockbox\sbx.mjs    front end to the engine: keep-after-install, uninstall-test
  sandbox-mcp\       the engine, as shipped upstream: src, agent (runs in the guest), skills
  node\node.exe      bundled Node.js
data\                everything that changes; must be writable
  home\              runs, reports, screenshots, recordings, cache
  recipes.json       saved recipes
  lockbox.env        optional overrides (copy lockbox.env.example)
installer\           Build.ps1 + package.json: builds the MSI with Master Packager Dev
setup\
  configure-claude.ps1   copy the skills into .claude\skills
  install-skills.cmd     optional: link the skills into %USERPROFILE%\.claude\skills
```

### Configuration

Copy `data\lockbox.env.example` to `data\lockbox.env` (for an MSI install, `%LOCALAPPDATA%\LockBox\lockbox.env`).
Variables already set in the environment win.

| Variable | Default | Use it to |
|---|---|---|
| `SANDBOX_MCP_HOME` | `data\home` (MSI: `%LOCALAPPDATA%\LockBox\home`) | Keep state on a local disk when LockBox lives on slow or read-only media |
| `LOCKBOX_CLAUDE_COLOR` | off | Keep colours in the Claude windows LockBox opens |

## Good to know

- **Isolation, not a guarantee.** Windows Sandbox is strong isolation. A detonation report records
  behaviour; it is not a verdict that a file is safe. For real malware analysis, use a dedicated analysis
  machine, and treat screenshots and logs from the guest as untrusted.
- **One sandbox at a time** per PC. If another tool's sandbox is open, LockBox says so and offers
  **Stop other sandbox** (or `sbx.cmd stop --force`).
- **Stopping destroys everything** inside the sandbox. Idle sandboxes shut themselves down after 30 minutes.
- **Kept on purpose.** `install-test` leaves the sandbox running so you can inspect the install. Uninstall
  only when you ask for it: **Uninstall test** or `sbx.cmd uninstall-test`.
- **Side by side.** LockBox runs alongside any other sandbox-mcp install on the same PC without touching it.

## Credits

- [sandbox-mcp](https://github.com/shanselman/sandbox-mcp) by Scott Hanselman (MIT): the engine LockBox is built
  on, and the reason it exists. It ships unchanged in `app\sandbox-mcp` except one fix in `agent\agent.ps1`.
  Scott's [announcement post](https://www.linkedin.com/posts/shanselman_a-lot-of-people-dont-realize-that-windows-share-7524715266119909376-OJuW/)
  explains why Windows Sandbox makes such a good throwaway test machine.
- [Windows Sandbox](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/) by Microsoft.
