// sbx.mjs - LockBox's front end to the sandbox-mcp CLI (app\sandbox-mcp\src\cli.js, left as shipped).
//
// Everything is passed straight through, except:
//   install-test    LockBox's own. Runs the installer with its normal UI and clicks through it over UI
//                   Automation (accept the licence, Install/Next, Finish), screenshotting each step;
//                   --manual leaves the clicking to you, --silent does the unattended /qn run. Then it
//                   stops: the sandbox is kept (--no-keep to destroy it) and nothing is uninstalled unless
//                   you pass --uninstall, which runs the uninstall step below in the same run.
//   uninstall-test  a separate step, run when you're done inspecting: uninstalls what install-test put
//                   into the running sandbox and reports what was left behind. The sandbox stays running.
//   mwrap-test      wraps an installer into a PSAppDeployToolkit v4 package with mwrap.exe on this PC, then
//                   runs Invoke-AppDeployToolkit.exe in a fresh sandbox (silent or interactive), the way
//                   Intune would. mwrap-run reruns a deployment type there; mwrap-pull copies the package out.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const engine = path.join(here, '..', 'sandbox-mcp', 'src');
const load = (name) => import(pathToFileURL(path.join(engine, name)).href);

const HELP = `
LockBox:
  install-test <setup> [options]     Install and stop. The installer's own UI shows in the sandbox window and
                                     sbx clicks through it (licence, Install/Next, Finish; restarts declined).
                                     The sandbox stays running with the app installed.
      --manual                       Show the setup UI but leave the clicking to you
      --silent                       Unattended install instead (MSI /qn), timing out after 600s
      --uninstall [auto|"<cmd>"]     Also test the uninstall in the same run (default: no uninstall)
      --uninstall-args "<args>"      Added to the registered UninstallString, e.g. /S
      --timeout <sec>                Give up waiting for the installer (default 3600, --silent 600)
      --no-keep                      Destroy the sandbox afterwards
      --args, --test, --network, --offline, --memory, --no-gpu, --fail-on-leftovers, --exclude, --max,
      --json, --open                 As upstream
  uninstall-test [options]           Uninstall what install-test installed in the running sandbox,
                                     then report what it left behind. The sandbox stays running.
      --program <text>               Only programs whose name contains this
      --uninstall "<cmd>"            Run this command line instead of the registered uninstaller
      --args "<args>"                Added to the registered UninstallString, e.g. /S
      --timeout <sec>                Per uninstaller (default 600)
      --max <n>, --json
  mwrap-test <installer> [options]   Wrap the installer (.msi/.mst/.msp/.exe/.msix) into a PSADT v4 package with
                                     mwrap on this PC, then run it in a fresh sandbox the way Intune would:
                                     Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode <mode>.
                                     Also takes an mwrap spec (.json) or an existing package folder.
      --mode silent|interactive      Silent (default) or Interactive: PSADT dialogs show in the sandbox window
      --install-args "<args>"        Installer arguments (MSI properties, or the EXE's silent switch)
      --uninstall-args, --repair-args, --transform <x.mst>, --spec <file.json>
      --mwrap "<mwrap options>"      Any other mwrap wrap options, e.g. "--progress --remove-msi-name Foo"
      --repair, --uninstall          Also run DeploymentType Repair / Uninstall (uninstall reports leftovers)
      --timeout <sec>                Per PSADT run (default 900, interactive 3600)
      --no-keep, --network, --offline, --memory, --no-gpu, --exclude, --max, --fail-on-leftovers, --json, --open
                                     The package (installer in Files\), logs and report land in the run's out
                                     folder; the package also stays in the guest at C:\sbx-test\package.
  mwrap-run <install|uninstall|repair> [--mode silent|interactive] [--timeout <sec>] [--json]
                                     Run the mwrap-test package again in the running sandbox
  mwrap-pull [--json]                Copy the package back out of the running sandbox (with any edits made
                                     there) and refresh the logs
  stop --force                       Also stops a sandbox LockBox did not start (another sbx install,
                                     the Windows Sandbox app). Only one sandbox can run at a time.`;

const OK_CODES = [0, 1641, 3010];
const step = (x) => x.timedOut ? `timed out after ${x.seconds.toFixed(0)}s` : `exit ${x.exitCode} in ${x.seconds.toFixed(1)}s`;
const psq = (s) => `'${String(s).replace(/'/g, "''")}'`;
const regPath = (k) => k.replace(/^HKLM\\/i, 'Registry::HKEY_LOCAL_MACHINE\\').replace(/^HKCU\\/i, 'Registry::HKEY_CURRENT_USER\\');
const noPreviews = (r) => ({ ...r, shots: r.shots.map(({ previewBase64, ...s }) => s) });

/** --name value / --name=value / --flag. `optional` options take a value only if the next arg isn't an option. */
function parse(args, { values = [], flags = [], repeat = [], optional = {} }, usage) {
  const pos = [], opt = {};
  for (const k of repeat) opt[k] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!a.startsWith('--')) { pos.push(a); continue; }
    const [k, inline] = a.slice(2).split(/=(.*)/s);
    if (flags.includes(k)) { opt[k] = true; continue; }
    if (k in optional) {
      opt[k] = inline ?? (args[i + 1] !== undefined && !args[i + 1].startsWith('--') ? args[++i] : optional[k]);
      continue;
    }
    if (!values.includes(k) && !repeat.includes(k)) throw new Error(`Unknown option --${k}. Try: sbx help`);
    const v = inline ?? args[++i];
    if (v === undefined) throw new Error(`--${k} needs a value`);
    if (repeat.includes(k)) opt[k].push(v); else opt[k] = v;
  }
  if (usage && !pos.length) throw new Error(`usage: sbx ${usage}`);
  return { pos, opt };
}

const num = (v, what) => {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`${what} must be a positive number`);
  return n;
};

function msiErrors(file) {
  if (!fs.existsSync(file)) return [];
  const buf = fs.readFileSync(file);
  const text = buf[0] === 0xff && buf[1] === 0xfe ? buf.toString('utf16le') : buf.toString('utf8');
  return text.split(/\r?\n/).filter((l) => /\bError \d{4}\b|Return value 3\b|SFXCA: Failed/.test(l)).slice(0, 20);
}

/** The installer as a person would run it: full UI, nothing silent. MSIs still get a verbose log. */
function interactiveCommand(guestPath, args = '', log) {
  const ext = path.extname(guestPath).toLowerCase();
  if (ext === '.msi') return { file: 'msiexec.exe', args: `/i "${guestPath}" /l*v "${log}" ${args}`.trim() };
  if (ext === '.ps1') return { file: 'powershell.exe', args: `-NoProfile -ExecutionPolicy Bypass -NoExit -File "${guestPath}" ${args}`.trim() };
  if (ext === '.cmd' || ext === '.bat') return { file: 'cmd.exe', args: `/d /s /k ""${guestPath}" ${args}"`.trim() };
  if (ext === '.exe') return { file: guestPath, args };
  throw new Error(`Don't know how to run ${ext || 'this file'}: use an .msi, .exe, .ps1, .cmd or .bat installer.`);
}

/**
 * Smart App Control ships in evaluation mode in the guest and asks the cloud about every new exe/msi. That
 * lookup stalls each installer ~120s at "SOFTWARE RESTRICTION POLICY: Verifying package" even with the
 * network on (upstream turns SAC off only for offline sandboxes). Off in this throwaway guest.
 */
async function smartAppControlOff(sbx) {
  const cmd = 'reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy /v VerifiedAndReputablePolicyState /t REG_DWORD /d 0 /f | Out-Null; CiTool.exe --refresh --json';
  const res = await sbx.exec({ command: cmd, timeoutSec: 60 }).catch((e) => ({ exitCode: -1, stdout: e.message }));
  if (res.exitCode !== 0) sbx.log(`could not turn Smart App Control off (installers may stall ~2 min): ${String(res.stdout || res.stderr).trim()}`);
}

/** UI input needs the sandbox window open. If it was closed (session disconnected), reopen it. */
async function ensureDesktop(sbx) {
  const s = await sbx.status();
  if (!s.running || s.desktop?.ready) return !!s.running;
  sbx.log('the sandbox window is closed or locked; reopening it so setup can be clicked through');
  spawn('wsb.exe', ['connect', '--id', s.id], { detached: true, stdio: 'ignore' }).unref();
  for (let i = 0; i < 30; i++) {
    await sbx.sleep(2000);
    if ((await sbx.status()).desktop?.ready) return true;
  }
  return false;
}

// ---------- setup click-through ----------

const norm = (s) => String(s || '').replace(/&/g, '').replace(/[<>.…:]+/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();
// Buttons that move setup forward, best first. Anything else (Cancel, Back, Browse, Repair, Remove...) is never clicked.
const FORWARD = ['install', 'install now', /^install (for|just|only)\b/, 'upgrade', 'next', 'i agree', 'agree', 'i accept', 'accept',
  'accept and install', 'continue', 'yes', 'ok', 'finish', 'close', 'done'];
const AFTER_RESTART = ['no', 'later', 'restart later', 'not now', 'finish', 'close', 'ok', 'done'];
const ACCEPT = /\b(accept|agree)\b/;
const DECLINE = /\b(do not|don't|dont|not accept|decline|disagree)\b/;
const RESTART = /\b(restart|reboot)\b/;
const RESTART_LATER = /\b(later|manually|not now|no,|do not|don't)\b/;
// Shell and browser windows that may pop up mid-install; never drive those.
const NOT_SETUP = /^(explorer|shellexperiencehost|startmenuexperiencehost|searchhost|textinputhost|applicationframehost|systemsettings|msedge|msedgewebview2|widgets|notepad)$/i;
const MAX_STEP_SHOTS = 15;

const rank = (list, name) => list.findIndex((w) => (w instanceof RegExp ? w.test(name) : w === name));

/** The one control to act on in this window, or null. Restart prompts are always answered "later". */
function nextControl(nodes) {
  const live = nodes.filter((n) => n.enabled !== false && n.name && n.rect?.[2] > 0 && n.rect?.[3] > 0);
  const restart = live.some((n) => RESTART.test(norm(n.name)));
  for (const n of live) {
    const name = norm(n.name);
    if (restart) {
      if (n.type === 'RadioButton' && RESTART_LATER.test(name) && !n.selected) return { node: n, action: 'select' };
      if (n.type === 'CheckBox' && RESTART.test(name) && !RESTART_LATER.test(name) && n.toggled) return { node: n, action: 'toggle' };
    } else {
      if (n.type === 'CheckBox' && ACCEPT.test(name) && !DECLINE.test(name) && n.toggled === false) return { node: n, action: 'toggle' };
      if (n.type === 'RadioButton' && ACCEPT.test(name) && !DECLINE.test(name) && !n.selected) return { node: n, action: 'select' };
    }
  }
  const list = restart ? AFTER_RESTART : FORWARD;
  let best = null;
  for (const n of live) {
    if (n.type !== 'Button' || !n.actions?.includes('invoke')) continue;
    const name = norm(n.name);
    if (restart && /\b(yes|restart now|reboot now)\b/.test(name)) continue;
    const r = rank(list, name);
    if (r >= 0 && (!best || r < best.r)) best = { node: n, action: 'click', r };
  }
  return best;
}

/**
 * Drives the setup UI while the installer runs: each tick looks at the windows of the installer and of any
 * process started since, and clicks the control that moves setup forward. A screen it can't answer (or a
 * control that doesn't react after 3 clicks) is left for a person, and logged once.
 */
function setupDriver(sbx, shot, { pid, before, r, t0 }) {
  const steps = [];
  const tries = new Map();
  const stuck = new Set();
  let lastAct = null, idleTicks = 0;
  const describe = (n) => `${n.type} "${n.name}"`;
  return {
    steps,
    async tick() {
      await sbx.sleep(1000);
      const wins = (await sbx.windows().catch(() => [])).filter((w) => (w.pid === pid || !before.has(w.pid)) && !NOT_SETUP.test(w.process || ''));
      const pids = [...new Set([pid, ...wins.map((w) => w.pid)])];
      let waiting = null;
      for (const p of pids) {
        const tree = await sbx.uiTree({ pid: p, depth: 30, maxNodes: 600 }).catch(() => null);
        const nodes = [].concat(tree?.nodes ?? []);
        if (!nodes.length) continue;
        const title = nodes[0].name || wins.find((w) => w.pid === p)?.title || `pid ${p}`;
        const screen = nodes.map((n) => `${n.type}:${n.name}:${n.enabled}:${n.toggled}:${n.selected}`).join('|');
        const pick = nextControl(nodes);
        if (!pick) {
          if (!nodes.some((x) => x.type === 'ProgressBar')) waiting = { title, screen };
          continue;
        }
        const key = `${p}|${screen}|${describe(pick.node)}`;
        // Give a click time to take effect before repeating it on an unchanged screen.
        if (lastAct?.key === key && Date.now() - lastAct.at < 5000) return;
        const n = (tries.get(key) || 0) + 1;
        tries.set(key, n);
        if (n > 3) { waiting = { title, screen, why: `${describe(pick.node)} did not react` }; continue; }
        if (steps.length < MAX_STEP_SHOTS) {
          const s = await shot({ name: `setup-${String(steps.length + 1).padStart(2, '0')}` }).catch(() => null);
          if (s) r.shots.push(s);
        }
        const same = nodes.filter((x) => x.type === pick.node.type && String(x.name).toLowerCase() === String(pick.node.name).toLowerCase());
        const index = Math.max(0, same.indexOf(pick.node));
        let res;
        try {
          res = await sbx.uiAction({ pid: p, name: pick.node.name, controlType: pick.node.type, index, action: pick.action });
        } catch (e) {
          if (!(await ensureDesktop(sbx))) sbx.log(`could not click ${describe(pick.node)}: ${e.message}`);
          return;
        }
        sbx.log(`setup: ${pick.action} ${describe(pick.node)} in "${title}"`);
        steps.push({ seconds: +((Date.now() - t0) / 1000).toFixed(1), window: title, control: describe(pick.node), did: res?.did || pick.action });
        lastAct = { key, at: Date.now() };
        idleTicks = 0;
        return;
      }
      if (!waiting) { idleTicks = 0; return; }
      if (!stuck.has(waiting.screen) && ++idleTicks >= 20) {
        stuck.add(waiting.screen);
        sbx.log(`setup: nothing sbx can answer on "${waiting.title}"${waiting.why ? ` (${waiting.why})` : ''}; still waiting. If it needs input, click through it in the sandbox window`);
      }
    },
  };
}

/** Launch, poll until exit or timeout (driving the setup UI if asked). On timeout, capture the screen; kill the tree only if asked to. */
async function runWatched(sbx, shot, cmd, timeoutSec, r, { label, kill, drive }) {
  const t0 = Date.now();
  const l = await sbx.launch({ path: cmd.file, args: cmd.args, waitForWindowSec: 0 });
  const driver = drive ? setupDriver(sbx, shot, { pid: l.pid, before: drive.before, r, t0 }) : null;
  let p;
  for (;;) {
    p = await sbx.processInfo(l.pid);
    if (p.hasExited || Date.now() - t0 > timeoutSec * 1000) break;
    if (driver) await driver.tick(); else await sbx.sleep(1000);
  }
  const res = { command: `${cmd.file} ${cmd.args || ''}`.trim(), pid: l.pid, exitCode: p.hasExited ? p.exitCode : null, timedOut: !p.hasExited, seconds: (Date.now() - t0) / 1000 };
  if (driver) res.steps = driver.steps;
  if (res.timedOut) {
    sbx.log(`${label} still running after ${timeoutSec}s; capturing the screen`);
    res.stuckWindows = await sbx.windows();
    r.shots.push(await shot({ name: `${label}-stuck` }));
    if (kill) await sbx.exec({ command: `taskkill.exe /T /F /PID ${l.pid}`, timeoutSec: 30 }).catch(() => {});
  }
  return res;
}

// ---------- install-test ----------

async function installTest(args) {
  const { pos, opt } = parse(args, {
    values: ['args', 'test', 'timeout', 'network', 'memory', 'uninstall-args', 'max'],
    flags: ['silent', 'manual', 'keep', 'no-keep', 'offline', 'no-gpu', 'minimized', 'fail-on-leftovers', 'json', 'open'],
    repeat: ['exclude'],
    optional: { uninstall: 'auto' },
  }, 'install-test <setup.msi|.exe|.ps1|.cmd> [--manual|--silent] [--uninstall] [--args "..."] [--no-keep]');
  if (opt.silent && opt.manual) throw new Error('--silent and --manual don\'t go together: --silent shows no setup UI');
  const sbx = await load('core.js');
  const { installCommand, countChanges, installSummary, renderInstallReport } = await load('install.js');
  const { shot, runTestScript } = await load('run.js');

  const src = path.resolve(pos[0]);
  if (!fs.existsSync(src) || !fs.statSync(src).isFile()) throw new Error(`Installer not found: ${src}`);
  if (opt.test && !fs.existsSync(opt.test)) throw new Error(`Test script not found: ${opt.test}`);
  const name = path.basename(src);
  installCommand(name); // validate the extension before booting
  const silent = !!opt.silent;
  const auto = !silent && !opt.manual;
  const uninstall = opt.uninstall && opt.uninstall !== 'none' ? opt.uninstall : null;
  const keep = !opt['no-keep'];
  const timeoutSec = num(opt.timeout, '--timeout') ?? (silent ? 600 : 3600);
  const max = num(opt.max, '--max') ?? 200;
  const r = { installer: name, hostPath: src, args: opt.args || '', interactive: !silent, mode: silent ? 'silent' : auto ? 'auto' : 'manual', startedAt: new Date().toISOString(), shots: [], uninstalls: [] };
  const t0 = Date.now();
  let booted = false;
  try {
    const boot = await sbx.startSandbox({
      network: opt.offline ? 'off' : opt.network ?? 'on', memoryMB: num(opt.memory, '--memory'),
      vGpu: !opt['no-gpu'], window: opt.minimized ? 'minimized' : 'normal',
    });
    booted = true;
    r.sandbox = { id: boot.id, epoch: boot.epoch, network: boot.network, bootSeconds: boot.bootSeconds };
    r.runDir = boot.runDir; r.outDir = boot.outDir;
    await smartAppControlOff(sbx);
    const guest = `C:\\sbx-test\\installer\\${name}`;
    await sbx.copyIn(src, guest);

    sbx.log('snapshot before install');
    await sbx.snapshot('before', opt.exclude);
    const procsBefore = await sbx.processes();

    const msiLog = path.extname(name).toLowerCase() === '.msi' ? `${sbx.GUEST.out}\\msi-install.log` : null;
    const cmd = silent ? installCommand(guest, opt.args, msiLog) : interactiveCommand(guest, opt.args, msiLog);
    if (silent) sbx.log(`installing ${name} silently`);
    else if (auto) {
      sbx.log(`installing ${name}: sbx clicks through its setup UI in the sandbox window (waiting up to ${Math.round(timeoutSec / 60)} min)`);
      await ensureDesktop(sbx);
    } else sbx.log(`installing ${name}: its setup UI is in the sandbox window. Click through it there (waiting up to ${Math.round(timeoutSec / 60)} min)`);
    r.install = await runWatched(sbx, shot, cmd, timeoutSec, r, { label: 'install', kill: silent, drive: auto && { before: new Set(procsBefore.map((p) => p.pid)) } });
    if (msiLog) { r.install.log = path.join(r.outDir, 'msi-install.log'); r.install.logErrors = msiErrors(r.install.log); }
    await sbx.sleep(2000);

    r.leftRunning = (await sbx.processes()).filter((p) => !procsBefore.some((b) => b.pid === p.pid) && p.path && !/^c:\\windows\\/i.test(p.path));
    r.shots.push(await shot({ name: 'after-install' }));
    sbx.log('snapshot after install');
    await sbx.snapshot('installed', opt.exclude);
    r.installDiff = await sbx.diffSnapshots('before', 'installed', max);

    if (opt.test) {
      sbx.log(`running test ${path.basename(opt.test)}`);
      const p = r.installDiff.programsAdded[0];
      r.test = await runTestScript(opt.test, { SBX_INSTALL_DIR: p?.installLocation || '', SBX_PROGRAM: p?.displayName || '' });
    }

    if (uninstall && !r.install.timedOut) {
      const u = await uninstallInSandbox(sbx, { uninstall: uninstall === 'auto' ? undefined : uninstall, args: opt['uninstall-args'], timeoutSec, max, report: false });
      r.uninstalls = u.uninstalls;
      if (u.failures.length && !u.uninstalls.length) r.uninstallSkipped = u.failures.join('; ');
      r.leftovers = u.leftovers;
      r.shots.push(...u.shots);
    }
  } catch (e) {
    r.error = e.message;
  } finally {
    if (booted && !keep) {
      sbx.log('destroying the sandbox');
      const st = await sbx.stopSandbox({ target: r.sandbox }).catch((e) => ({ error: e.message }));
      if (st.error) r.stopError = st.error;
    }
    r.kept = booted && keep;
  }
  r.seconds = (Date.now() - t0) / 1000;

  r.leftoverCount = r.leftovers ? countChanges(r.leftovers) : null;
  r.failures = [];
  if (r.error) r.failures.push(r.error);
  if (r.install?.timedOut) r.failures.push(silent ? `installer still running after ${timeoutSec}s (waiting for input?)`
    : auto ? `setup still open after ${timeoutSec}s; sbx could not click it through (see the screenshots); left running in the sandbox`
      : `setup still open after ${timeoutSec}s; left running in the sandbox`);
  else if (r.install?.exitCode === 1602) r.failures.push('setup was cancelled (exit 1602)');
  else if (r.install && !OK_CODES.includes(r.install.exitCode)) r.failures.push(`installer exited with code ${r.install.exitCode}`);
  if (r.test && r.test.exitCode !== 0) r.failures.push(`test script ${r.test.timedOut ? 'timed out' : `exited with code ${r.test.exitCode}`}`);
  for (const u of r.uninstalls) {
    if (u.timedOut) r.failures.push(`uninstaller for ${u.program} still running after ${timeoutSec}s`);
    else if (!OK_CODES.includes(u.exitCode)) r.failures.push(`uninstaller for ${u.program} exited with code ${u.exitCode}`);
  }
  if (r.uninstallSkipped) r.failures.push(`uninstall: ${r.uninstallSkipped}`);
  if (r.leftovers?.programsAdded.length) r.failures.push(`still listed in Add/Remove Programs after uninstall: ${r.leftovers.programsAdded.map((p) => p.displayName).join(', ')}`);
  if (opt['fail-on-leftovers'] && r.leftoverCount) r.failures.push(`${r.leftoverCount} leftover change(s) after uninstall`);
  r.pass = r.failures.length === 0;

  if (r.outDir) {
    fs.mkdirSync(r.outDir, { recursive: true });
    r.reportPath = path.join(r.outDir, 'report.md');
    fs.writeFileSync(r.reportPath, renderInstallReport(r) + renderSetupSteps(r));
    fs.writeFileSync(path.join(r.outDir, 'report.json'), JSON.stringify(noPreviews(r), null, 2));
  }

  if (opt.json) console.log(JSON.stringify(noPreviews(r), null, 2));
  else {
    console.log(installSummary(r));
    if (r.install?.steps) {
      const s = r.install.steps;
      console.log(s.length ? `--- setup clicked through by sbx ---\n${s.map((x) => `  ${String(x.seconds).padStart(6)}s  ${x.did} ${x.control} in "${x.window}"`).join('\n')}`
        : '--- sbx found nothing to click in the setup UI ---');
    }
    if (r.install?.logErrors?.length) console.log(`--- Windows Installer errors ---\n${r.install.logErrors.join('\n')}`);
    if (r.test && r.test.exitCode !== 0) console.log(`--- test ${r.test.script} ---\n${[r.test.stdout, r.test.stderr].filter(Boolean).join('\n').trimEnd()}`);
    if (r.kept) console.log(`Sandbox left running for you to inspect.${uninstall ? '' : ' `sbx uninstall-test` uninstalls;'} \`sbx stop\` when done.`);
  }
  if (opt.open && r.reportPath) spawn('cmd.exe', ['/c', 'start', '', r.reportPath], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  return r.pass ? 0 : 1;
}

function renderSetupSteps(r) {
  const steps = r.install?.steps;
  if (!steps) return '';
  const lines = ['', '## Setup UI, clicked through by sbx', ''];
  if (!steps.length) lines.push('sbx found nothing to click: setup ran without asking, or needed input sbx does not answer.');
  else lines.push('| At | Window | Did |', '|---|---|---|', ...steps.map((x) => `| ${x.seconds}s | ${x.window} | ${x.did} ${x.control} |`));
  return lines.join('\n') + '\n';
}

// ---------- uninstall-test ----------

async function uninstallTest(args) {
  const { opt } = parse(args, { values: ['program', 'uninstall', 'args', 'timeout', 'max'], flags: ['json'] });
  const sbx = await load('core.js');
  const r = await uninstallInSandbox(sbx, {
    program: opt.program, uninstall: opt.uninstall, args: opt.args,
    timeoutSec: num(opt.timeout, '--timeout') ?? 600, max: num(opt.max, '--max') ?? 200, report: true,
  });
  if (opt.json) console.log(JSON.stringify(noPreviews(r), null, 2));
  else {
    const lines = [`${r.pass ? 'PASS' : 'FAIL'}  uninstall in sandbox ${r.sandbox} (${r.seconds.toFixed(1)}s)`];
    const row = (k, v) => lines.push(`  ${k.padEnd(10)} ${v}`);
    if (!r.pass) row('why', r.failures.join('; '));
    for (const u of r.uninstalls) row('uninstall', `${u.program}: ${step(u)}`);
    if (r.leftovers) row('leftovers', r.leftoverCount ? `${r.leftoverCount} change(s) left behind` : 'none, clean uninstall');
    if (r.stillRegistered?.length) row('still ARP', r.stillRegistered.join(', '));
    row('report', r.reportPath);
    lines.push('Sandbox still running; `sbx stop` when done.');
    console.log(lines.join('\n'));
  }
  return r.pass ? 0 : 1;
}

/** Uninstall what was installed since the 'before' snapshot, in the running sandbox, and diff what's left. */
async function uninstallInSandbox(sbx, o) {
  const { uninstallCommands, splitCommand, countChanges } = await load('install.js');
  const { shot } = await load('run.js');
  const t0 = Date.now();
  const s = await sbx.status();
  if (!s.running) throw new Error('No sbx sandbox running. Run install-test first; it keeps the sandbox for this step.');
  const r = { sandbox: s.id, outDir: s.outDir, uninstalls: [], shots: [], failures: [] };

  sbx.log('snapshot before uninstall');
  await sbx.snapshot('pre-uninstall');
  try {
    r.installed = await sbx.diffSnapshots('before', 'pre-uninstall', o.max);
  } catch (e) {
    throw new Error(`This sandbox has no 'before' snapshot, so there is no install to undo (${e.message}). uninstall-test works on a sandbox kept by install-test.`);
  }

  let programs = r.installed.programsAdded;
  if (o.program) programs = programs.filter((p) => String(p.displayName || '').toLowerCase().includes(o.program.toLowerCase()));
  const cmds = o.uninstall ? [{ ...splitCommand(o.uninstall), program: '(custom)' }] : uninstallCommands(programs, o.args);

  if (!cmds.length) {
    r.failures.push(o.program ? `no installed program matches '${o.program}'`
      : 'nothing new is registered in Add/Remove Programs, so there is no uninstaller to run (use --uninstall "<cmd>")');
  } else {
    // Programs still running from their install folder would block the uninstaller.
    const dirs = programs.map((p) => p.installLocation).filter(Boolean);
    if (dirs.length) {
      const stop = `Get-Process | Where-Object { $p = [string]$_.Path; $p -and (@(${dirs.map(psq).join(',')}) | Where-Object { $p.StartsWith($_.TrimEnd('\\') + '\\', 'OrdinalIgnoreCase') }) } | Stop-Process -Force -PassThru | ForEach-Object { $_.ProcessName }`;
      const stopped = (await sbx.exec({ command: stop, timeoutSec: 30 })).stdout.trim();
      if (stopped) { r.stopped = stopped.split(/\r?\n/); sbx.log(`stopped ${r.stopped.join(', ')} so the uninstaller can run`); }
    }
    for (const c of cmds) {
      sbx.log(`uninstalling ${c.program}: ${c.file} ${c.args}`);
      const u = await runWatched(sbx, shot, c, o.timeoutSec, r, { label: 'uninstall', kill: true });
      u.program = c.program;
      // Self-copying uninstallers (NSIS, Inno) return at once and keep working from %TEMP%: wait for the ARP entry to go.
      if (c.key && !u.timedOut) {
        for (let i = 0; i < 60; i++) {
          if ((await sbx.exec({ command: `Test-Path -LiteralPath ${psq(regPath(c.key))}`, timeoutSec: 30 })).stdout.trim() !== 'True') break;
          await sbx.sleep(1000);
        }
        await sbx.sleep(2000);
      }
      if (u.timedOut) r.failures.push(`${c.program}: uninstaller timed out`);
      else if (!OK_CODES.includes(u.exitCode)) r.failures.push(`${c.program}: uninstaller exited with code ${u.exitCode}`);
      r.uninstalls.push(u);
    }
    sbx.log('snapshot after uninstall');
    await sbx.snapshot('uninstalled');
    r.leftovers = await sbx.diffSnapshots('before', 'uninstalled', o.max);
    r.leftoverCount = countChanges(r.leftovers);
    r.stillRegistered = r.leftovers.programsAdded.map((p) => p.displayName);
    r.shots.push(await shot({ name: 'after-uninstall' }));
  }

  r.pass = !r.failures.length;
  r.seconds = (Date.now() - t0) / 1000;
  if (o.report) {
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
    r.reportPath = path.join(r.outDir, `uninstall-report-${stamp}.md`);
    fs.writeFileSync(r.reportPath, renderUninstallReport(sbx, r));
    fs.writeFileSync(r.reportPath.replace(/\.md$/, '.json'), JSON.stringify(noPreviews(r), null, 2));
  }
  return r;
}

function renderUninstallReport(sbx, r) {
  const rel = (p) => path.relative(r.outDir, p).split(path.sep).join('/');
  const lines = [
    '# sbx uninstall-test', '',
    r.pass ? '**PASS**' : `**FAIL**: ${r.failures.join('; ')}`, '',
    '| | |', '|---|---|',
    `| Sandbox | ${r.sandbox} (still running) |`,
  ];
  if (r.stopped?.length) lines.push(`| Stopped first | ${r.stopped.join(', ')} |`);
  for (const u of r.uninstalls) lines.push(`| Uninstall | ${u.program}: \`${u.command}\`: ${step(u)} |`);
  if (r.leftovers) lines.push(`| Leftovers | ${r.leftoverCount ? `**${r.leftoverCount}** change(s) remain after uninstall` : 'none, clean uninstall'} |`);
  lines.push(`| Time | ${r.seconds.toFixed(1)}s |`, '');
  if (r.leftovers) lines.push('## Left behind after uninstall', '', sbx.formatDiff(r.leftovers, { title: 'before install -> after uninstall' }), '');
  if (r.installed) lines.push('## What was installed before the uninstall', '', sbx.formatDiff(r.installed, { title: 'before install -> before uninstall' }), '');
  for (const s of r.shots) lines.push(`**${s.name}**`, '', `![${s.name}](${rel(s.path)})`, '');
  return lines.join('\n') + '\n';
}

// ---------- mwrap-test / mwrap-run / mwrap-pull ----------
//
// mwrap (app\mwrap\mwrap.exe, or MWRAP_EXE in data\lockbox.env) wraps an installer into a PSAppDeployToolkit
// v4 package on this PC. mwrap-test copies that package into a fresh sandbox and runs Invoke-AppDeployToolkit.exe
// there the way Intune would, silent or interactive. The package (installer in Files\), mwrap's result, the PSADT
// and MSI logs and the report land in the run's out folder; the package and mwrap.exe also stay in the guest.

const MW_GUEST = 'C:\\sbx-test';
const MW_STATE = 'mwrap-state.json';
const MW_INPUT = /\.(msi|mst|msp|exe|msix|msixbundle|appx|appxbundle)$/i;
const MW_MODES = { silent: 'Silent', interactive: 'Interactive', noninteractive: 'NonInteractive', auto: 'Auto' };
const MW_TYPES = { install: 'Install', uninstall: 'Uninstall', repair: 'Repair' };
// PSADT v4 config: UI.DeferExitCode 1602, UI.DefaultExitCode 1618 (a dialog timed out); 60000-69999 are toolkit errors.
const PSADT_CODES = { 0: 'success', 1641: 'success, restart started', 3010: 'success, restart needed', 1602: 'deferred or cancelled by the user',
  1618: 'a dialog timed out, or another install was running', 60001: 'script error (see the PSADT log)' };
const psadtMeaning = (c) => PSADT_CODES[c] ?? (c >= 60000 && c < 70000 ? 'PSAppDeployToolkit error (see the PSADT log)' : 'failed');
const isInteractive = (mode) => mode === 'interactive' || mode === 'auto';
const stampNow = () => new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);

function findMwrap() {
  const dirs = String(process.env.PATH || '').split(';').filter(Boolean).map((d) => path.join(d.replace(/"/g, ''), 'mwrap.exe'));
  const hit = [process.env.MWRAP_EXE, path.join(here, '..', 'mwrap', 'mwrap.exe'), ...dirs].find((p) => p && fs.existsSync(p));
  if (!hit) throw new Error('mwrap.exe not found: put it in app\\mwrap\\, on PATH, or set MWRAP_EXE in data\\lockbox.env');
  return hit;
}

/** "--a 1 --b \"two words\" --c 'x y'" -> argv, as a shell would split it (double or single quotes group). */
function splitArgs(s) {
  const out = [];
  let cur = '', q = null, quoted = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) {
      if (ch === q) q = null;
      else if (q === '"' && ch === '\\' && s[i + 1] === '"') { cur += '"'; i++; }
      else cur += ch;
    } else if (ch === '"' || ch === "'") { q = ch; quoted = true; }
    else if (/\s/.test(ch)) { if (cur || quoted) out.push(cur); cur = ''; quoted = false; }
    else cur += ch;
  }
  if (q) throw new Error(`unbalanced ${q} in --mwrap ${s}`);
  if (cur || quoted) out.push(cur);
  return out;
}

function runMwrap(exe, args) {
  return new Promise((resolve, reject) => {
    const p = spawn(exe, args, { windowsHide: true });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', reject);
    p.on('close', (code) => resolve({ code, out, err }));
  });
}

/** mwrap prints progress (e.g. "Signing ...") before its --json result; take the JSON object. */
function mwrapJson(res, what) {
  const a = res.out.indexOf('{'), b = res.out.lastIndexOf('}');
  if (res.code !== 0 || a < 0) throw new Error(`mwrap ${what} failed: ${(res.err || res.out).trim() || `exit ${res.code}`}`);
  return JSON.parse(res.out.slice(a, b + 1));
}

/** The lines mwrap put in each main phase (Install / Uninstall / Repair) of Invoke-AppDeployToolkit.ps1. */
function psadtActions(script) {
  if (!fs.existsSync(script)) return {};
  const text = fs.readFileSync(script, 'utf8').replace(/^\uFEFF/, '');
  const out = {};
  for (const t of Object.values(MW_TYPES)) {
    const fn = text.indexOf(`function ${t}-ADTDeployment`);
    const start = fn < 0 ? -1 : text.indexOf('$adtSession.InstallPhase = $adtSession.DeploymentType', fn);
    if (start < 0) continue;
    const end = text.indexOf('##===', start);
    out[t] = text.slice(start, end < 0 ? undefined : end).split(/\r?\n/).slice(1).map((l) => l.trim()).filter(Boolean).join('\n');
  }
  return out;
}

/** Copies every .log from the package's Toolkit/MSI LogPath (and PSADT's default) into the guest out folder. */
async function collectPsadtLogs(sbx, st) {
  const dest = `${sbx.GUEST.out}\\logs`;
  const cmd = `$ErrorActionPreference = 'SilentlyContinue'
$vars = @{ envWinDir = $env:windir; envSystemRoot = $env:SystemRoot; envSystemDrive = $env:SystemDrive; envProgramData = $env:ProgramData
  envProgramFiles = $env:ProgramFiles; envProgramFilesX86 = \${env:ProgramFiles(x86)}; envCommonProgramFiles = $env:CommonProgramFiles
  envAllUsersProfile = $env:ALLUSERSPROFILE; envPublic = $env:PUBLIC; envTemp = $env:TEMP }
$dirs = @("$env:windir\\Logs\\Software")
foreach ($f in @(${psq(`${st.guestPackage}\\Config\\config.psd1`)}, ${psq(`${st.guestPackage}\\PSAppDeployToolkit\\Config\\config.psd1`)})) {
  if (-not (Test-Path -LiteralPath $f)) { continue }
  $c = Import-PowerShellDataFile -LiteralPath $f
  foreach ($p in @($c.Toolkit.LogPath, $c.MSI.LogPath)) {
    if (-not $p) { continue }
    foreach ($k in ($vars.Keys | Sort-Object Length -Descending)) { $p = $p.Replace('$' + $k, $vars[$k]) }
    $dirs += $p
  }
}
New-Item -ItemType Directory -Force -Path ${psq(dest)} | Out-Null
foreach ($d in ($dirs | Select-Object -Unique)) { Get-ChildItem -LiteralPath $d -File -Filter *.log | Copy-Item -Destination ${psq(dest)} -Force -PassThru | ForEach-Object { $_.Name } }`;
  const res = await sbx.exec({ command: cmd, timeoutSec: 120 }).catch((e) => ({ exitCode: -1, stdout: '', stderr: e.message }));
  const dir = path.join(st.outDir, 'logs');
  const files = fs.existsSync(dir) ? fs.readdirSync(dir).map((n) => path.join(dir, n)) : [];
  return { dir, files, issues: psadtLogIssues(files), error: res.exitCode ? String(res.stderr || res.stdout).trim() : undefined };
}

/** Warnings (type 2) and errors (type 3) from CMTrace-format PSADT logs. */
function psadtLogIssues(files) {
  const issues = [];
  for (const f of files) {
    const buf = fs.readFileSync(f);
    const text = buf[0] === 0xff && buf[1] === 0xfe ? buf.toString('utf16le') : buf.toString('utf8');
    if (!text.includes('<![LOG[')) continue;
    for (const m of text.matchAll(/<!\[LOG\[([\s\S]*?)\]LOG\]!><[^>]*?component="([^"]*)"[^>]*?type="([23])"/g)) {
      issues.push({ log: path.basename(f), level: m[3] === '3' ? 'error' : 'warning', component: m[2], message: m[1].trim().slice(0, 500) });
    }
  }
  return issues.slice(0, 40);
}

/** One Invoke-AppDeployToolkit.exe run in the guest, watched like an installer, plus the detection-key check. */
async function runPsadt(sbx, shot, st, type, mode, timeoutSec, r) {
  const cmd = { file: `${st.guestPackage}\\Invoke-AppDeployToolkit.exe`, args: `-DeploymentType ${MW_TYPES[type]} -DeployMode ${MW_MODES[mode]}` };
  if (isInteractive(mode)) {
    await ensureDesktop(sbx);
    sbx.log(`${MW_TYPES[type]} (${MW_MODES[mode]}): answer the PSADT dialogs in the sandbox window (waiting up to ${Math.round(timeoutSec / 60)} min)`);
  } else sbx.log(`${MW_TYPES[type]} (${MW_MODES[mode]}): ${cmd.file} ${cmd.args}`);
  const res = await runWatched(sbx, shot, cmd, timeoutSec, r, { label: type, kill: !isInteractive(mode) });
  res.type = MW_TYPES[type];
  res.mode = MW_MODES[mode];
  res.meaning = res.timedOut ? `still running after ${timeoutSec}s` : psadtMeaning(res.exitCode);
  await sbx.sleep(2000);
  if (st.detectionKey) {
    const t = await sbx.exec({ command: `Test-Path -LiteralPath ${psq(regPath(st.detectionKey))}`, timeoutSec: 30 });
    res.detectionKeyPresent = t.stdout.trim() === 'True';
  }
  r.shots.push(await shot({ name: `after-${type}` }));
  return res;
}

function psadtFailures(runs, st) {
  const f = [];
  for (const x of runs) {
    if (x.timedOut) f.push(`${x.type} still running after ${x.seconds.toFixed(0)}s${x.mode === 'Silent' ? ' (waiting for input that silent mode cannot give?)' : '; left running in the sandbox'}`);
    else if (!OK_CODES.includes(x.exitCode)) f.push(`${x.type} exited with ${x.exitCode}: ${x.meaning}`);
    else if (st.detectionKey && x.detectionKeyPresent === (x.type === 'Uninstall')) {
      f.push(`${x.type}: detection key ${x.type === 'Uninstall' ? 'still present' : 'missing'} (${st.detectionKey})`);
    }
  }
  return f;
}

const runLine = (x) => x.timedOut ? x.meaning : `exit ${x.exitCode} (${x.meaning}) in ${x.seconds.toFixed(0)}s` +
  (x.detectionKeyPresent === undefined ? '' : `, detection key ${x.detectionKeyPresent ? 'present' : 'absent'}`);

function readMwrapState(s) {
  const f = path.join(s.outDir, MW_STATE);
  if (!fs.existsSync(f)) throw new Error('This sandbox has no mwrap-test package. Run `sbx mwrap-test <installer>` first; it keeps the sandbox for this step.');
  return JSON.parse(fs.readFileSync(f, 'utf8'));
}

async function mwrapTest(args) {
  const { pos, opt } = parse(args, {
    values: ['mode', 'spec', 'transform', 'install-args', 'uninstall-args', 'repair-args', 'timeout', 'network', 'memory', 'max'],
    flags: ['repair', 'uninstall', 'keep', 'no-keep', 'offline', 'no-gpu', 'minimized', 'fail-on-leftovers', 'json', 'open'],
    repeat: ['mwrap', 'exclude'],
  });
  if (!pos.length && !opt.spec) throw new Error('usage: sbx mwrap-test <installer | spec.json | package folder> [--mode silent|interactive] [--uninstall] [--repair] [--mwrap "<mwrap options>"]');
  const mode = String(opt.mode || 'silent').toLowerCase();
  if (!MW_MODES[mode]) throw new Error(`--mode must be one of ${Object.keys(MW_MODES).join(', ')}`);
  const sbx = await load('core.js');
  const { countChanges } = await load('install.js');
  const { shot } = await load('run.js');
  const keep = !opt['no-keep'];
  const timeoutSec = num(opt.timeout, '--timeout') ?? (isInteractive(mode) ? 3600 : 900);
  const max = num(opt.max, '--max') ?? 200;
  const t0 = Date.now();
  const r = { kind: 'mwrap-test', mode: MW_MODES[mode], startedAt: new Date().toISOString(), runs: [], shots: [], failures: [] };

  // 1. Wrap on this PC first, so a bad installer or option fails before a sandbox boots.
  const target = pos[0] ? path.resolve(pos[0]) : null;
  if (target && !fs.existsSync(target)) throw new Error(`Not found: ${target}`);
  const isPackage = !!target && fs.statSync(target).isDirectory();
  const isSpec = !!target && /\.json$/i.test(target);
  if (isPackage && !fs.existsSync(path.join(target, 'Invoke-AppDeployToolkit.exe'))) throw new Error(`${target} is a folder but not a PSADT v4 package (no Invoke-AppDeployToolkit.exe)`);
  if (target && !isPackage && !isSpec && !MW_INPUT.test(target)) throw new Error('mwrap-test takes an .msi, .mst, .msp, .exe, .msix/.appx(bundle), an mwrap spec (.json) or a package folder');
  const mwrap = findMwrap();
  r.mwrap = mwrap;
  let stage = null, built;
  if (isPackage) {
    r.installer = '(existing package)';
    const info = await runMwrap(mwrap, ['info', target, '--json']).then((x) => mwrapJson(x, 'info')).catch(() => null);
    built = { Path: target, DetectionKey: info?.DetectionKey || null, Toolkit: info?.ToolkitVersion || null };
    if (info?.Session) Object.assign(built, { Vendor: info.Session.AppVendor, Name: info.Session.AppName, Version: info.Session.AppVersion, Architecture: info.Session.AppArch });
  } else {
    stage = path.join(sbx.HOME, 'mwrap-staging', `${stampNow()}-${process.pid}`);
    const out = path.join(stage, 'package');
    const extra = [];
    if (opt.transform) extra.push('--transform', path.resolve(opt.transform));
    for (const [o, f] of [['install-args', '--install-args'], ['uninstall-args', '--uninstall-args'], ['repair-args', '--repair-args']]) if (opt[o] !== undefined) extra.push(f, opt[o]);
    for (const m of opt.mwrap) extra.push(...splitArgs(m));
    const spec = opt.spec ? path.resolve(opt.spec) : isSpec ? target : null;
    const wrapArgs = target && !isSpec
      ? ['wrap', target, ...(spec ? ['--spec', spec] : []), '-o', out, '--force', '--json', ...extra]
      : ['build', spec, '-o', out, '--force', '--json', ...extra];
    r.installer = target && !isSpec ? path.basename(target) : `(from ${path.basename(spec)})`;
    r.mwrapCommand = `mwrap ${wrapArgs.map((a) => (/[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a)).join(' ')}`;
    sbx.log(`wrapping: ${r.mwrapCommand}`);
    try {
      built = mwrapJson(await runMwrap(mwrap, wrapArgs), 'wrap');
    } catch (e) {
      fs.rmSync(stage, { recursive: true, force: true });
      throw e;
    }
  }
  r.app = { vendor: built.Vendor, name: built.Name, version: built.Version, arch: built.Architecture };
  r.toolkit = built.Toolkit;
  r.signed = built.Signed;
  const leaf = [built.Vendor, built.Name, built.Version].filter(Boolean).join('_').replace(/[\\/:*?"<>|]+/g, '_').replace(/\s+/g, '') || 'package';

  let booted = false, st = null;
  try {
    // 2. Boot, then move the package into this run's out folder: the tested bits are the ones you keep.
    const boot = await sbx.startSandbox({
      network: opt.offline ? 'off' : opt.network ?? 'on', memoryMB: num(opt.memory, '--memory'),
      vGpu: !opt['no-gpu'], window: opt.minimized ? 'minimized' : 'normal',
    });
    booted = true;
    r.sandbox = { id: boot.id, epoch: boot.epoch, network: boot.network, bootSeconds: boot.bootSeconds };
    r.runDir = boot.runDir; r.outDir = boot.outDir;
    let hostPackage = built.Path;
    if (stage) {
      hostPackage = path.join(boot.outDir, 'package', leaf);
      fs.mkdirSync(path.dirname(hostPackage), { recursive: true });
      try { fs.renameSync(path.join(stage, 'package'), hostPackage); } catch {
        fs.cpSync(path.join(stage, 'package'), hostPackage, { recursive: true });
      }
      fs.rmSync(stage, { recursive: true, force: true });
      stage = null;
      fs.writeFileSync(path.join(boot.outDir, 'mwrap-result.json'), JSON.stringify({ ...built, Path: hostPackage, Script: path.join(hostPackage, 'Invoke-AppDeployToolkit.ps1') }, null, 2));
    }
    st = { guestPackage: `${MW_GUEST}\\package\\${leaf}`, guestMwrap: `${MW_GUEST}\\mwrap\\mwrap.exe`, hostPackage, detectionKey: built.DetectionKey || null,
      outDir: boot.outDir, app: r.app, installer: r.installer };
    r.package = st;
    r.actions = psadtActions(path.join(hostPackage, 'Invoke-AppDeployToolkit.ps1'));
    fs.writeFileSync(path.join(boot.outDir, MW_STATE), JSON.stringify(st, null, 2));

    await smartAppControlOff(sbx);
    sbx.log(`copying the package into ${st.guestPackage}`);
    await sbx.copyIn(hostPackage, st.guestPackage);
    await sbx.copyIn(mwrap, st.guestMwrap);

    sbx.log('snapshot before install');
    await sbx.snapshot('before', opt.exclude);

    // 3. Install, then the optional repair and uninstall, each a full PSADT run.
    const install = await runPsadt(sbx, shot, st, 'install', mode, timeoutSec, r);
    r.runs.push(install);
    sbx.log('snapshot after install');
    await sbx.snapshot('installed', opt.exclude);
    r.installDiff = await sbx.diffSnapshots('before', 'installed', max);
    const installed = !install.timedOut && OK_CODES.includes(install.exitCode);
    if (opt.repair && installed) r.runs.push(await runPsadt(sbx, shot, st, 'repair', mode, timeoutSec, r));
    if (opt.uninstall && installed) {
      r.runs.push(await runPsadt(sbx, shot, st, 'uninstall', mode, timeoutSec, r));
      sbx.log('snapshot after uninstall');
      await sbx.snapshot('uninstalled', opt.exclude);
      r.leftovers = await sbx.diffSnapshots('before', 'uninstalled', max);
      r.leftoverCount = countChanges(r.leftovers);
    }
    r.logs = await collectPsadtLogs(sbx, st);
  } catch (e) {
    r.error = e.message;
  } finally {
    if (stage) fs.rmSync(stage, { recursive: true, force: true });
    if (booted && !keep) {
      sbx.log('destroying the sandbox');
      const s = await sbx.stopSandbox({ target: r.sandbox }).catch((e) => ({ error: e.message }));
      if (s.error) r.stopError = s.error;
    }
    r.kept = booted && keep;
  }
  r.seconds = (Date.now() - t0) / 1000;

  if (r.error) r.failures.push(r.error);
  if (st) r.failures.push(...psadtFailures(r.runs, st));
  if (r.leftovers?.programsAdded.length) r.failures.push(`still listed in Add/Remove Programs after uninstall: ${r.leftovers.programsAdded.map((p) => p.displayName).join(', ')}`);
  if (opt['fail-on-leftovers'] && r.leftoverCount) r.failures.push(`${r.leftoverCount} leftover change(s) after uninstall`);
  r.pass = r.failures.length === 0;

  if (r.outDir) {
    r.reportPath = path.join(r.outDir, 'report.md');
    fs.writeFileSync(r.reportPath, renderMwrapReport(sbx, r, 'sbx mwrap-test'));
    fs.writeFileSync(path.join(r.outDir, 'report.json'), JSON.stringify(noPreviews(r), null, 2));
  }
  if (opt.json) console.log(JSON.stringify(noPreviews(r), null, 2));
  else console.log(mwrapSummary(r));
  if (opt.open && r.reportPath) spawn('cmd.exe', ['/c', 'start', '', r.reportPath], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  return r.pass ? 0 : 1;
}

async function mwrapRun(args) {
  const { pos, opt } = parse(args, { values: ['mode', 'timeout', 'max'], flags: ['json'] }, 'mwrap-run <install|uninstall|repair> [--mode silent|interactive]');
  const type = String(pos[0]).toLowerCase();
  if (!MW_TYPES[type]) throw new Error('mwrap-run takes install, uninstall or repair');
  const mode = String(opt.mode || 'silent').toLowerCase();
  if (!MW_MODES[mode]) throw new Error(`--mode must be one of ${Object.keys(MW_MODES).join(', ')}`);
  const sbx = await load('core.js');
  const { countChanges } = await load('install.js');
  const { shot } = await load('run.js');
  const s = await sbx.status();
  if (!s.running) throw new Error('No sbx sandbox running. Run `sbx mwrap-test <installer>` first; it keeps the sandbox for this step.');
  const st = readMwrapState(s);
  const t0 = Date.now();
  const timeoutSec = num(opt.timeout, '--timeout') ?? (isInteractive(mode) ? 3600 : 900);
  const r = { kind: 'mwrap-run', mode: MW_MODES[mode], sandbox: { id: s.id }, outDir: s.outDir, package: st, app: st.app, installer: st.installer, runs: [], shots: [], failures: [], kept: true };
  r.actions = psadtActions(path.join(st.hostPackage, 'Invoke-AppDeployToolkit.ps1'));
  try {
    r.runs.push(await runPsadt(sbx, shot, st, type, mode, timeoutSec, r));
    if (type === 'uninstall') {
      await sbx.snapshot('uninstalled');
      r.leftovers = await sbx.diffSnapshots('before', 'uninstalled', num(opt.max, '--max') ?? 200).catch(() => undefined);
      if (r.leftovers) r.leftoverCount = countChanges(r.leftovers);
    }
    r.logs = await collectPsadtLogs(sbx, st);
  } catch (e) {
    r.error = e.message;
  }
  r.seconds = (Date.now() - t0) / 1000;
  if (r.error) r.failures.push(r.error);
  r.failures.push(...psadtFailures(r.runs, st));
  if (r.leftovers?.programsAdded.length) r.failures.push(`still listed in Add/Remove Programs after uninstall: ${r.leftovers.programsAdded.map((p) => p.displayName).join(', ')}`);
  r.pass = r.failures.length === 0;
  r.reportPath = path.join(s.outDir, `mwrap-${type}-report-${stampNow()}.md`);
  fs.writeFileSync(r.reportPath, renderMwrapReport(sbx, r, `sbx mwrap-run ${type}`));
  fs.writeFileSync(r.reportPath.replace(/\.md$/, '.json'), JSON.stringify(noPreviews(r), null, 2));
  if (opt.json) console.log(JSON.stringify(noPreviews(r), null, 2));
  else console.log(mwrapSummary(r));
  return r.pass ? 0 : 1;
}

/** Copies the package back out of the running sandbox (with any changes made there) and refreshes the logs. */
async function mwrapPull(args) {
  const { opt } = parse(args, { flags: ['json'] });
  const sbx = await load('core.js');
  const s = await sbx.status();
  if (!s.running) throw new Error('No sbx sandbox running.');
  const st = readMwrapState(s);
  sbx.log(`copying ${st.guestPackage} out of the sandbox`);
  const c = await sbx.copyOut(st.guestPackage, `package-from-sandbox-${stampNow()}`);
  const logs = await collectPsadtLogs(sbx, st);
  const r = { pass: true, package: c.hostPath, files: c.files, bytes: c.bytes, logs: logs.dir, outDir: s.outDir };
  if (opt.json) console.log(JSON.stringify(r, null, 2));
  else console.log(`Package copied out of the sandbox to ${c.hostPath} (${c.files} files)\nLogs refreshed in ${logs.dir}`);
  return 0;
}

function mwrapSummary(r) {
  const lines = [`${r.pass ? 'PASS' : 'FAIL'}  ${r.kind} ${[r.app?.vendor, r.app?.name, r.app?.version].filter(Boolean).join(' ')} (${r.mode}, ${r.seconds.toFixed(0)}s)`];
  const row = (k, v) => lines.push(`  ${k.padEnd(10)} ${v}`);
  if (!r.pass) row('why', r.failures.join('; '));
  if (r.package) row('package', r.package.hostPackage);
  for (const x of r.runs) row(x.type.toLowerCase(), runLine(x));
  if (r.leftovers) row('leftovers', r.leftoverCount ? `${r.leftoverCount} change(s) left behind` : 'none, clean uninstall');
  if (r.logs) row('logs', `${r.logs.dir} (${r.logs.files.length} file(s), ${r.logs.issues.filter((i) => i.level === 'error').length} PSADT error(s))`);
  if (r.reportPath) row('report', r.reportPath);
  if (r.kept && r.package) {
    lines.push(`Sandbox left running: the package is at ${r.package.guestPackage} and mwrap at ${r.package.guestMwrap}.`,
      '`sbx mwrap-run install|repair|uninstall [--mode interactive]` runs it again, `sbx mwrap-pull` copies the package back out, `sbx stop` when done.');
  }
  return lines.join('\n');
}

function renderMwrapReport(sbx, r, title) {
  const rel = (p) => path.relative(r.outDir, p).split(path.sep).join('/');
  const cell = (v) => String(v ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, '<br>');
  const L = [`# ${title}`, '', r.pass ? '**PASS**' : `**FAIL**: ${r.failures.join('; ')}`, '', '| | |', '|---|---|'];
  const row = (k, v) => L.push(`| ${k} | ${cell(v)} |`);
  if (r.app) row('App', `${[r.app.vendor, r.app.name, r.app.version].filter(Boolean).join(' ')}${r.app.arch ? ` (${r.app.arch})` : ''}`);
  row('Installer', r.installer);
  if (r.mwrapCommand) row('Wrapped with', `\`${r.mwrapCommand}\``);
  if (r.package) {
    row('Package (host)', r.package.hostPackage);
    row('Package (sandbox)', r.package.guestPackage);
    if (r.package.guestMwrap) row('mwrap (sandbox)', r.package.guestMwrap);
    row('Detection key', r.package.detectionKey || '(none: detection rules are in SupportFiles\\PackageInfo.json)');
  }
  if (r.toolkit) row('PSADT', r.toolkit);
  if (r.signed !== undefined) row('Signed', r.signed ? 'yes' : 'no');
  row('Deploy mode', r.mode);
  if (r.sandbox) row('Sandbox', `${r.sandbox.id}${r.sandbox.network ? `, network ${r.sandbox.network}` : ''}${r.kept ? ' (still running)' : ' (destroyed)'}`);
  row('Time', `${r.seconds.toFixed(1)}s`);
  L.push('');
  if (r.runs.length) {
    L.push('## PSADT runs', '', '| Deployment | Command | Result |', '|---|---|---|');
    for (const x of r.runs) L.push(`| ${x.type} | \`${cell(x.command)}\` | ${cell(runLine(x))} |`);
    L.push('');
  }
  if (Object.keys(r.actions || {}).length) {
    L.push('## Main actions in the package', '');
    for (const [t, text] of Object.entries(r.actions)) L.push(`**${t}**`, '', '```powershell', text || '# (empty)', '```', '');
  }
  if (r.logs) {
    L.push('## Logs', '');
    if (r.logs.files.length) for (const f of r.logs.files) L.push(`- [${path.basename(f)}](${rel(f)})`);
    else L.push(`No logs were found${r.logs.error ? `: ${r.logs.error}` : ''}.`);
    L.push('');
    if (r.logs.issues.length) {
      L.push('### PSADT warnings and errors', '', '| Level | Log | Component | Message |', '|---|---|---|---|');
      for (const i of r.logs.issues) L.push(`| ${i.level} | ${cell(i.log)} | ${cell(i.component)} | ${cell(i.message)} |`);
      L.push('');
    }
  }
  if (r.installDiff) L.push('## What the install changed', '', sbx.formatDiff(r.installDiff, { title: 'before install -> after install' }), '');
  if (r.leftovers) L.push('## Left behind after uninstall', '', sbx.formatDiff(r.leftovers, { title: 'before install -> after uninstall' }), '');
  for (const s of r.shots) if (s?.path) L.push(`**${s.name}**`, '', `![${s.name}](${rel(s.path)})`, '');
  return L.join('\n') + '\n';
}

// ---------- dispatch ----------
const argv = process.argv.slice(2);
const own = { 'install-test': installTest, 'uninstall-test': uninstallTest, 'mwrap-test': mwrapTest, 'mwrap-run': mwrapRun, 'mwrap-pull': mwrapPull };
if (own[argv[0]]) {
  try {
    process.exitCode = await own[argv[0]](argv.slice(1));
  } catch (e) {
    console.error(`sbx: ${e.message}`);
    process.exitCode = 1;
  }
} else {
  process.argv = [process.argv[0], path.join(engine, 'cli.js'), ...argv];
  await load('cli.js');
  if ([undefined, 'help', '-h', '--help'].includes(argv[0])) console.log(HELP);
}
