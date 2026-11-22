# Set up Claude Code for LockBox

Instructions for Claude Code. Point it at this file ("follow SETUP-CLAUDE.md in my LockBox folder"). LockBox
is CLI-only: Claude drives the sandbox by running `sbx.cmd` and follows the `windows-sandbox-*` skills.
Don't register an MCP server.

Below, `<LockBox>` is the folder that contains this file. Use its absolute path, quoted.

## 1. Check the host

Run `"<LockBox>\sbx.cmd" doctor`. If it reports a problem, pass the `Fix:` lines to the user and stop.
They need an administrator and a restart, so don't run them yourself. Don't install Node.js or anything
from npm: LockBox bundles everything it needs.

## 2. Install the skills into the LockBox folder

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<LockBox>\setup\configure-claude.ps1"
```

This copies the five `windows-sandbox-*` skills and LockBox's `mwrap` skill (PSADT wrap and test) into `<LockBox>\.claude\skills`. Claude Code loads them when started in
`<LockBox>`. Nothing outside the folder changes, and nothing records a path, so this never needs re-running
after the folder moves. LockBox also does this itself every time it opens Claude.

## 3. Optional: skills in every folder

Only if the user asks for it:

```powershell
& "<LockBox>\setup\install-skills.cmd"
```

This creates junctions in `%USERPROFILE%\.claude\skills`. Skills another install already provides are left
alone and reported, so it never takes over an existing setup. In other folders, the skills' `sbx` commands
run whichever `sbx` is on PATH, which may not be LockBox's.

## 4. Verify

1. Run `"<LockBox>\sbx.cmd" status --json`. It should print JSON with a `running` field and exit 0.
2. Tell the user to start Claude Code in `<LockBox>` and check `/skills`. The five `windows-sandbox-*`
   skills and `mwrap` should be listed.
3. Optional end-to-end check, which takes about a minute and boots a real guest. Only run it when
   `status` shows no sandbox running:
   `"<LockBox>\sbx.cmd" run C:\Windows\System32\charmap.exe --network off` should report PASS.

## Undo

- Step 2: delete `<LockBox>\.claude\skills\windows-sandbox-*`.
- Step 3: `"<LockBox>\setup\install-skills.cmd" /uninstall`. It removes only junctions into this LockBox.
