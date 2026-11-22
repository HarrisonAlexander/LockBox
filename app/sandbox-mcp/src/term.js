// sbx term: an interactive PowerShell session inside the running sandbox (agent/termhost.cs keeps it alive).
// --json speaks one JSON object per line on stdin/stdout for the launcher window:
//   in:  {t:'run',command,cols} {t:'input',text} {t:'break'} {t:'complete',id,input,cursor} {t:'reset',cols}
//   out: {t:'ready',prompt,busy,reattached} {t:'out',text} {t:'prompt',text} {t:'input',secret}
//        {t:'complete',id,matches,replacementIndex,replacementLength} {t:'error',message} {t:'closed',message}
// Without --json it is a plain line-mode shell for a real console (Ctrl+C stops the running command).
import readline from 'node:readline';
import * as sbx from './core.js';

const GONE = /No sandbox is running|no longer running|restarted\/replaced/;

export async function term({ json = false, cols, reset = false } = {}) {
  const emit = json ? (o) => process.stdout.write(JSON.stringify(o) + '\n') : null;
  let busy = false, awaiting = false, inputSeq = 0, pumping = false, prompt = 'PS> ', closing = false;
  let onIdle = () => {}, onAwait = () => {};

  const close = (message) => {
    if (closing) return;
    closing = true;
    if (json) emit({ t: 'closed', message });
    else console.error(`\nsbx: ${message}`);
    process.exit(0);
  };
  const fail = (e) => {
    if (GONE.test(e.message)) close(e.message);
    if (json) emit({ t: 'error', message: e.message }); else console.error(`sbx: ${e.message}`);
  };
  const write = (text) => { if (text) json ? emit({ t: 'out', text }) : process.stdout.write(text.replace(/\u001b\[2J/g, '\u001b[2J\u001b[H')); };
  const showPrompt = (text) => { prompt = text ?? prompt; busy = false; awaiting = false; json ? emit({ t: 'prompt', text: prompt }) : onIdle(); };

  async function pump() {
    if (pumping) return;
    pumping = true;
    try {
      while (busy) {
        let r;
        try { r = await sbx.termRead(300); } catch (e) { fail(e); showPrompt(); break; }
        write(r.output);
        if (r.awaitingInput && r.inputSeq !== inputSeq) { inputSeq = r.inputSeq; awaiting = true; json ? emit({ t: 'input', secret: !!r.secret }) : onAwait(!!r.secret); }
        if (r.busy || r.more) continue;
        if (r.exited) {
          write('Session ended; starting a new one.\n');
          try { const o = await sbx.termOpen({ cols, reset: true }); inputSeq = 0; showPrompt(o.prompt); } catch (e) { fail(e); showPrompt(); }
        } else showPrompt(r.prompt);
      }
    } finally { pumping = false; }
  }

  async function run(command, width) {
    if (busy) return;
    if (width) cols = width;
    busy = true;
    try { await sbx.termRun(command, cols); } catch (e) { fail(e); showPrompt(); return; }
    pump();
  }

  let opened;
  try { opened = await sbx.termOpen({ cols, reset }); } catch (e) { fail(e); close(e.message); }
  prompt = opened.prompt;
  busy = !!opened.busy;
  if (json) emit({ t: 'ready', prompt, busy, reattached: opened.reattached });
  if (busy) pump();

  if (json) {
    const rl = readline.createInterface({ input: process.stdin, terminal: false });
    rl.on('line', async (line) => {
      let m;
      try { m = JSON.parse(line); } catch { return; }
      try {
        if (m.t === 'run') await run(String(m.command ?? ''), m.cols);
        else if (m.t === 'input') { awaiting = false; await sbx.termInput(String(m.text ?? '')); }
        else if (m.t === 'break') { if (busy) await sbx.termBreak(); }
        else if (m.t === 'complete') emit({ t: 'complete', id: m.id, ...(await sbx.termComplete(String(m.input ?? ''), m.cursor ?? 0)) });
        else if (m.t === 'reset') {
          if (m.cols) cols = m.cols;
          busy = false;
          const o = await sbx.termOpen({ cols, reset: true });
          inputSeq = 0;
          showPrompt(o.prompt);
        }
      } catch (e) { fail(e); }
    });
    // The window went away: leave the guest session running so the next window reattaches to it.
    rl.on('close', () => process.exit(0));
    return new Promise(() => {});
  }

  // Line mode for a real console.
  const rl = readline.createInterface({
    input: process.stdin, output: process.stdout, historySize: 500,
    completer: (line, cb) => {
      if (busy) return cb(null, [[], line]);
      sbx.termComplete(line, line.length).then((c) => cb(null, [c.matches ?? [], line.slice(c.replacementIndex ?? line.length)]), () => cb(null, [[], line]));
    },
  });
  console.log(`Connected to the sandbox${opened.reattached ? ' (reattached to the running session)' : ''}. "exit" starts a fresh session; Ctrl+D leaves.`);
  onIdle = () => { rl.setPrompt(prompt); rl.prompt(); };
  onAwait = () => { rl.setPrompt(''); rl.prompt(); };
  rl.on('line', (line) => {
    if (awaiting) { awaiting = false; sbx.termInput(line).catch(fail); return; }
    if (busy) return;
    if (!line.trim()) return onIdle();
    run(line);
  });
  rl.on('SIGINT', () => { if (busy) { process.stdout.write('^C\n'); sbx.termBreak().catch(fail); } else { rl.write('', { ctrl: true, name: 'u' }); onIdle(); } });
  rl.on('close', () => process.exit(0));
  if (!busy) onIdle();
  return new Promise(() => {});
}
