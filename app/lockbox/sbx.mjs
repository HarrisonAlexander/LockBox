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

// ---------- dispatch ----------
const argv = process.argv.slice(2);
const own = { 'install-test': installTest, 'uninstall-test': uninstallTest };
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
