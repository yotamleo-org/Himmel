import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makeTmpDir } from '../lib/test-tmpdir.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WIRER = join(HERE, 'wire-plugin-hook-bash.mjs');
const PLUGIN_HOOKS = join(HERE, '..', '..', 'marketplace', 'plugins', 'himmel-ops', 'hooks', 'hooks.json');

// an independent restatement of
// wire-plugin-hook-bash.mjs's own wired-form prefix, not imported from it —
// so this spec pins the expected output rather than circularly re-running the
// generator it is meant to check. The launcher RUNS (via `command -p sh`, not
// sourced via `.` — dash drops `.`'s operands) run-node.sh VENDORED into the
// plugin itself (${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh, byte-identical to
// scripts/lib/run-node.sh — see test-plugin-hook-bash-wiring.sh's drift
// check), never $CLAUDE_PROJECT_DIR — see wiredCommand()'s own header
// comment for why.
const WIRED_PREFIX = 'command -p sh "${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js" ';

// The two SUPERSEDED launcher tokens. A command in either shape must still be
// recognised as owned (unwired) and MIGRATED to the current form on the next
// rewrite, exactly like the bare-`node` legacyWiredCommand()
// already migrates.
//
//   `.`   dash drops its operands.
//   `sh`  an earlier shape: a
//         bare `sh` is a PATH lookup, so a host whose PATH excludes the
//         shell's directory killed the whole chain at rc=127.
const LEGACY_LAUNCHER_TOKENS = ['.', 'sh'];
function legacyPrefix(token) {
  return `${token} "\${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh" "\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js" `;
}

// FULL dot-wired command for one project-source hook script (no
// --fail-closed-when) — the shape wire-plugin-hook-bash.mjs's
// legacyDotWiredCommand() recognises as owned/unwired and migrates.
function legacyDotWiredCommand(script, token = '.') {
  return `${legacyPrefix(token)}--optional "$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"`;
}

function commands(pluginHooks) {
  return Object.values(pluginHooks.hooks).flatMap((groups) =>
    groups.flatMap((group) => group.hooks.map((hook) => hook.command))
  );
}

function unwire(text) {
  const pluginHooks = JSON.parse(text);
  for (const commandHook of Object.values(pluginHooks.hooks).flatMap((groups) =>
    groups.flatMap((group) => group.hooks)
  )) {
    const command = commandHook.command;
    if (command.includes('/hooks/inject-minerva-critic.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/inject-minerva-critic.sh"';
      continue;
    }
    if (command.includes('/hooks/block-agent-native-egress.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/block-agent-native-egress.sh"';
      continue;
    }
    if (command.includes('/hooks/guard-judge-writes.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-judge-writes.sh"';
      continue;
    }
    if (command.includes('/hooks/guard-rm-writes.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-rm-writes.sh"';
      continue;
    }
    if (command.includes('/hooks/block-busy-loop.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/block-busy-loop.sh"';
      continue;
    }
    if (command.includes('/hooks/block-vault-sweep.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/block-vault-sweep.sh"';
      continue;
    }
    if (command.includes('/hooks/redirect-webfetch-walled-hosts.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/redirect-webfetch-walled-hosts.sh"';
      continue;
    }
    if (command.includes('/hooks/steer-t3-tool-calls.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/steer-t3-tool-calls.sh"';
      continue;
    }
    const peer = command.match(/\/hooks\/(peer-taint-(?:gate|mark|resume)\.sh|phi-read-mark\.sh|suggest-missing-path\.sh)"$/);
    if (peer) {
      commandHook.command = `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${peer[1]}"`;
      continue;
    }
    const match = command.match(/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"/);
    assert.ok(match, `could not extract project hook script from ${command}`);
    const script = match[1];
    if (script === 'block-lesson-enforcement-writes.sh') {
      commandHook.command = 'bash -c \'h="$CLAUDE_PROJECT_DIR/scripts/hooks/block-lesson-enforcement-writes.sh"; if [ -f "$h" ]; then exec bash "$h"; elif [ "${HIMMEL_LESSON_LOOP:-0}" = "1" ]; then echo "block-lesson-enforcement-writes: hook script missing while HIMMEL_LESSON_LOOP=1 (stale checkout?) - failing closed" >&2; exit 2; fi\'';
    } else if (script === 'block-worker-write-fence.sh') {
      // Second fail-closed entry. Spelled
      // out here rather than derived from the wirer, so this stays an
      // INDEPENDENT restatement of the expected output instead of a circular
      // re-run of the generator it is meant to pin.
      commandHook.command = 'bash -c \'h="$CLAUDE_PROJECT_DIR/scripts/hooks/block-worker-write-fence.sh"; if [ -f "$h" ]; then exec bash "$h"; elif [ "${HIMMEL_WORKER:-0}" = "1" ]; then echo "block-worker-write-fence: hook script missing while HIMMEL_WORKER=1 (stale checkout?) - failing closed" >&2; exit 2; fi\'';
    } else if (script === 'guard-readiness-tools.sh' || script === 'readiness-session.sh') {
      // Fail-closed on the readiness role marker; the session script also carries its fixed verb. Spelled out here, not
      // derived from the wirer, so this stays an independent restatement of the expected output.
      const hookName = script.replace(/\.sh$/, '');
      const verb = command.match(/"\s+(startup|cleanup)$/)?.[1];
      const tail = verb ? ` ${verb}` : '';
      commandHook.command = `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"; if [ -f "$h" ]; then exec bash "$h"${tail}; elif [ "\${HIMMEL_READINESS:-0}" = "1" ]; then echo "${hookName}: hook script missing while HIMMEL_READINESS=1 (stale checkout?) - failing closed" >&2; exit 2; fi'`;
    } else if (script === 'guard-chief-dispatch.sh' || script === 'guard-chief-foreground.sh') {
      const hookName = script.replace(/\.sh$/, '');
      commandHook.command = `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"; if [ -f "$h" ]; then exec bash "$h"; elif [ "\${HIMMEL_CONSOLE:-0}" = "1" ]; then echo "${hookName}: hook script missing while HIMMEL_CONSOLE=1 (stale checkout?) - failing closed" >&2; exit 2; fi'`;
    } else {
      commandHook.command = `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"; if [ -f "$h" ]; then exec bash "$h"; fi'`;
    }
  }
  return `${JSON.stringify(pluginHooks, null, 2)}\n`;
}

// Derived from the live hooks.json, never hardcoded (scripts/hooks/CLAUDE.md:
// a frozen count is a wall the next hook addition has to climb). The wirer's
// own EXPECTED_HOOKS check pins the live file, so this stays honest.
const LIVE_COUNT = commands(JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8'))).length;

function withFixture(run, { wired = false } = {}) {
  const dir = makeTmpDir('wire-plugin-hook-bash-');
  const fixture = join(dir, 'hooks.json');
  try {
    const source = readFileSync(PLUGIN_HOOKS, 'utf8');
    writeFileSync(fixture, wired ? source : unwire(source));
    return run(fixture);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function invoke(...args) {
  return spawnSync(process.execPath, [WIRER, ...args], { encoding: 'utf8' });
}

test('rewrites the exact plugin inventory through the installed launcher', () => {
  withFixture((fixture) => {
    const before = JSON.parse(readFileSync(fixture, 'utf8'));
    const result = invoke(fixture);
    const after = JSON.parse(readFileSync(fixture, 'utf8'));

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`rewrote ${LIVE_COUNT} hook command\\(s\\)`));
    assert.equal(commands(after).length, LIVE_COUNT);
    for (const command of commands(after)) {
      assert.ok(command.startsWith(WIRED_PREFIX));
      assert.doesNotMatch(command, /(^|\s)bash(\s|$)/);
    }

    const scrub = (value) => {
      const copy = structuredClone(value);
      for (const hook of Object.values(copy.hooks).flatMap((groups) => groups.flatMap((group) => group.hooks))) {
        hook.command = '__COMMAND__';
      }
      return copy;
    };
    assert.deepEqual(scrub(after), scrub(before));
  });
});

// Migration: a command still wired by either superseded launcher
// token must be recognised as owned (not refused as an inventory mismatch) and
// rewritten to the current form on the next pass.
for (const token of LEGACY_LAUNCHER_TOKENS) {
  test(`migrates a superseded \`${token}\`-wired plugin command to the command -p sh form`, () => {
    withFixture((fixture) => {
      const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
      // PreToolUse[1] is block-docker-privesc.sh (EXPECTED_HOOKS[1]): project-
      // source, no --fail-closed-when — the plain legacyDotWiredCommand shape.
      const group = pluginHooks.hooks.PreToolUse[1];
      group.hooks[0].command = legacyDotWiredCommand('block-docker-privesc.sh', token);
      writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);

      const result = invoke(fixture);
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, new RegExp(`rewrote ${LIVE_COUNT} hook command\\(s\\)`));

      const after = JSON.parse(readFileSync(fixture, 'utf8'));
      const rewritten = after.hooks.PreToolUse[1].hooks[0].command;
      assert.ok(rewritten.startsWith(WIRED_PREFIX), `\`${token}\`-wired plugin entry migrated to the command -p sh form`);
      assert.ok(rewritten.includes('block-docker-privesc.sh'));
    });
  });
}

// the live plugin hooks.json must never carry either superseded
// launcher — the dot form dash drops operands from, nor the bare `sh` form
// that dies at rc=127 under a restricted PATH.
test('no hook command in the live plugin hooks.json matches a superseded launcher prefix', () => {
  const live = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8'));
  for (const token of LEGACY_LAUNCHER_TOKENS) {
    const stale = commands(live).filter((c) => c.startsWith(legacyPrefix(token)));
    assert.deepEqual(stale, [], `every run-node.sh launch must use \`command -p sh\`, not \`${token}\` (HIMMEL-2758)`);
  }
});

test('is idempotent after the first plugin rewrite', () => {
  withFixture((fixture) => {
    const first = invoke(fixture);
    assert.equal(first.status, 0, first.stderr);
    const afterFirst = readFileSync(fixture, 'utf8');

    const second = invoke(fixture);
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stdout, /already wired; no change made/);
    assert.equal(readFileSync(fixture, 'utf8'), afterFirst);
  });
});

test('refuses an added plugin hook without writing', () => {
  withFixture((fixture) => {
    const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
    pluginHooks.hooks.Notification.push({
      hooks: [{ type: 'command', command: 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/new-guard.sh"' }],
    });
    writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /inventory mismatch for Notification: expected 1, found 2/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses a command in the wrong inventory slot without writing', () => {
  withFixture((fixture) => {
    const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
    const hooks = pluginHooks.hooks.PreToolUse;
    [hooks[1].hooks[0].command, hooks[2].hooks[0].command] = [hooks[2].hooks[0].command, hooks[1].hooks[0].command];
    writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /command inventory mismatch: expected block-docker-privesc\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('--check validates the live plugin inventory and writes nothing', () => {
  const before = readFileSync(PLUGIN_HOOKS, 'utf8');
  const result = invoke('--check', PLUGIN_HOOKS);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /already wired; no change needed.*wrote nothing/);
  assert.equal(readFileSync(PLUGIN_HOOKS, 'utf8'), before);
});

test('guard-rm-writes.sh is the 16th PreToolUse entry, plugin-sourced, right after guard-judge-writes.sh', () => {
  const pre = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks.PreToolUse;
  const scripts = pre.flatMap((g) => g.hooks.map((h) => h.command.match(/([A-Za-z0-9._-]+\.sh)"$/)[1]));
  assert.equal(scripts.indexOf('guard-rm-writes.sh'), 15);
  assert.equal(scripts.indexOf('guard-rm-writes.sh'), scripts.indexOf('guard-judge-writes.sh') + 1);
  const entry = pre.find((g) => g.hooks.some((h) => h.command.endsWith('/hooks/guard-rm-writes.sh"')));
  assert.equal(entry.matcher, 'Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*');
  assert.equal(entry.hooks[0].command, `${WIRED_PREFIX}"\${CLAUDE_PLUGIN_ROOT}/hooks/guard-rm-writes.sh"`);
});

test('block-busy-loop.sh is a plugin-sourced Bash entry, never a $CLAUDE_PROJECT_DIR one', () => {
  const pre = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks.PreToolUse;
  const entries = pre.filter((g) => g.hooks.some((h) => h.command.includes('block-busy-loop.sh')));
  assert.equal(entries.length, 1);
  assert.equal(entries[0].matcher, 'Bash');
  assert.equal(entries[0].hooks[0].command, `${WIRED_PREFIX}"\${CLAUDE_PLUGIN_ROOT}/hooks/block-busy-loop.sh"`);
});

test('redirect-webfetch-walled-hosts.sh is a plugin-sourced WebFetch entry, never a $CLAUDE_PROJECT_DIR one', () => {
  const pre = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks.PreToolUse;
  const entries = pre.filter((g) => g.hooks.some((h) => h.command.includes('redirect-webfetch-walled-hosts.sh')));
  assert.equal(entries.length, 1);
  assert.equal(entries[0].matcher, 'WebFetch');
  assert.equal(entries[0].hooks[0].command, `${WIRED_PREFIX}"\${CLAUDE_PLUGIN_ROOT}/hooks/redirect-webfetch-walled-hosts.sh"`);
});

// ---- the readiness role's delivery (C0s cycle 5): the exact-tool guard through the normal plugin inventory -------------
// Independent restatements of the expected output, not imported from the wirer. The SESSION script (readiness-session.sh)
// is registered below too: its queue library is a static source, so the dispatched-closure walk resolves it.
const REPO_ROOT = join(HERE, '..', '..');
const PLUGIN_ROOT = join(REPO_ROOT, 'marketplace', 'plugins', 'himmel-ops');
const GUARD = 'guard-readiness-tools.sh';
const GUARD_COMMAND = `${WIRED_PREFIX}--optional --fail-closed-when "HIMMEL_READINESS=1" "$CLAUDE_PROJECT_DIR/scripts/hooks/${GUARD}"`;

function groupsWith(event, script) {
  return JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks[event].filter((g) => g.hooks.some((h) => h.command.includes(`/${script}"`)));
}

test('the readiness guard is ONE PreToolUse entry: every tool matcher, project-delivered, fail-closed on exactly HIMMEL_READINESS=1, just before the last peer-taint group', () => {
  const entries = groupsWith('PreToolUse', GUARD);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].matcher, '*');
  assert.equal(entries[0].hooks.length, 1);
  assert.equal(entries[0].hooks[0].command, GUARD_COMMAND);
  assert.equal(entries[0].hooks[0].timeout, 15);
  const pre = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks.PreToolUse;
  const index = pre.indexOf(pre.find((g) => g.hooks[0].command.includes(GUARD)));
  assert.equal(pre[index + 1].hooks[0].command.includes('peer-taint-gate.sh'), true, 'the peer taint gate stays the last PreToolUse group');
  assert.equal(index, pre.length - 2);
  for (const event of Object.keys(JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8')).hooks)) {
    if (event !== 'PreToolUse') assert.equal(groupsWith(event, GUARD).length, 0, `${event} must not register the guard`);
  }
});

test('no project-lane double registration, no second copy location, and the plugin policy copy equals the source', () => {
  const project = readFileSync(join(REPO_ROOT, '.claude', 'settings.json'), 'utf8');
  const projectWirer = readFileSync(join(HERE, 'wire-hook-bash.mjs'), 'utf8');
  assert.ok(!project.includes(GUARD), 'the guard is not in the project settings');
  assert.ok(!projectWirer.includes(GUARD), 'the guard is not in the project wirer inventory');
  assert.equal(existsSync(join(PLUGIN_ROOT, 'hooks', GUARD)), false, 'the guard has no new plugin hooks/ copy');
  assert.equal(readFileSync(join(HERE, GUARD), 'utf8'), readFileSync(join(PLUGIN_ROOT, 'scripts', GUARD), 'utf8'), 'the plugin policy copy is byte-identical');
  assert.equal(statSync(join(HERE, GUARD)).mode & 0o777, statSync(join(PLUGIN_ROOT, 'scripts', GUARD)).mode & 0o777, 'same mode');
});

// The registered command, run through the REAL runner with the REAL guard, exactly as Claude Code runs it (sh -c).
function runGuard({ marker, project, payload }) {
  const command = groupsWith('PreToolUse', GUARD)[0].hooks[0].command;
  const env = { PATH: process.env.PATH, HOME: project, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, CLAUDE_PROJECT_DIR: project };
  if (marker !== undefined) env.HIMMEL_READINESS = marker;
  return spawnSync('sh', ['-c', command], { env, input: payload, encoding: 'utf8', timeout: 30000 });
}
const toolCall = (tool_name) => JSON.stringify({ session_id: 's', hook_event_name: 'PreToolUse', tool_name, tool_input: {} });

test('the registered guard command, through the real runner: marker 1 allows only the two readiness tools; any other marker value is the silent generic context', () => {
  for (const tool of ['mcp__readiness__inspect', 'mcp__readiness__act']) {
    const r = runGuard({ marker: '1', project: REPO_ROOT, payload: toolCall(tool) });
    assert.equal(r.status, 0, `${tool}: ${r.stderr}`);
    assert.equal(r.stdout, '');
  }
  for (const tool of ['Bash', 'Read', 'Write', 'Edit', 'mcp__readiness__finish', 'mcp__readiness__act ', 'mcp__other__inspect', 'Agent']) {
    const r = runGuard({ marker: '1', project: REPO_ROOT, payload: toolCall(tool) });
    assert.equal(r.status, 2, `${tool} must be denied`);
    assert.match(r.stdout + r.stderr, /readiness tool-deny/);
  }
  for (const marker of [undefined, '', '0', 'yes', '01', '1 ', 'true']) {
    const r = runGuard({ marker, project: REPO_ROOT, payload: toolCall('Bash') });
    assert.equal(r.status, 0, `marker ${JSON.stringify(marker)} is the generic context`);
    assert.equal(r.stdout, '');
  }
});

test('the registered guard command fails CLOSED when its script is missing under the marker, and is silent without it', () => {
  const empty = makeTmpDir('wire-readiness-empty-');
  const closed = runGuard({ marker: '1', project: empty, payload: toolCall('mcp__readiness__inspect') });
  assert.equal(closed.status, 2);
  assert.match(closed.stderr, /failing closed/);
  for (const marker of [undefined, '', '0', 'yes']) {
    const open = runGuard({ marker, project: empty, payload: toolCall('Bash') });
    assert.equal(open.status, 0, `marker ${JSON.stringify(marker)} with no script is a plain skip`);
  }
});

// ---- the readiness role's session hooks (cycle 5 review F1): the lease adoption at SessionStart, the release at SessionEnd ----
const SESSION = 'readiness-session.sh';
const sessionCommand = (verb) => `${WIRED_PREFIX}--optional --fail-closed-when "HIMMEL_READINESS=1" "$CLAUDE_PROJECT_DIR/scripts/hooks/${SESSION}" ${verb}`;

test('the readiness session script is registered once per verb: startup at SessionStart, cleanup at SessionEnd, each project-delivered with its fixed argument, last in its event', () => {
  const doc = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8'));
  for (const [event, verb, timeout] of [['SessionStart', 'startup', 15], ['SessionEnd', 'cleanup', 3]]) {
    const entries = groupsWith(event, SESSION);
    assert.equal(entries.length, 1, `${event} registers the session script once`);
    assert.equal(entries[0].hooks.length, 1);
    assert.equal(entries[0].hooks[0].command, sessionCommand(verb));
    assert.equal(entries[0].hooks[0].timeout, timeout);
    assert.deepEqual(doc.hooks[event].at(-1), entries[0], `${event}: the session group is the last, after every existing hook`);
  }
  for (const event of Object.keys(doc.hooks)) {
    if (event !== 'SessionStart' && event !== 'SessionEnd') assert.equal(groupsWith(event, SESSION).length, 0, `${event} must not register the session script`);
  }
});

test('the session script has no project-lane registration, no plugin hooks/ copy, and its plugin copy equals the source', () => {
  const project = readFileSync(join(REPO_ROOT, '.claude', 'settings.json'), 'utf8');
  const projectWirer = readFileSync(join(HERE, 'wire-hook-bash.mjs'), 'utf8');
  assert.ok(!project.includes(SESSION), 'the session script is not in the project settings');
  assert.ok(!projectWirer.includes(SESSION), 'the session script is not in the project wirer inventory');
  assert.equal(existsSync(join(PLUGIN_ROOT, 'hooks', SESSION)), false, 'the session script has no new plugin hooks/ copy');
  assert.equal(readFileSync(join(HERE, SESSION), 'utf8'), readFileSync(join(PLUGIN_ROOT, 'scripts', SESSION), 'utf8'), 'the plugin copy is byte-identical');
  assert.equal(statSync(join(HERE, SESSION)).mode & 0o777, statSync(join(PLUGIN_ROOT, 'scripts', SESSION)).mode & 0o777, 'same mode');
});

test('the wirer refuses a session entry with the wrong verb, a swapped verb, no verb, an extra word, another marker or a plugin-directory source, without writing', () => {
  const mutations = [
    ['SessionStart', 'a startup entry carrying the cleanup verb', (c) => c.replace(/ startup$/, ' cleanup')],
    ['SessionEnd', 'a cleanup entry carrying the startup verb', (c) => c.replace(/ cleanup$/, ' startup')],
    ['SessionStart', 'a startup entry with no verb', (c) => c.replace(/ startup$/, '')],
    ['SessionStart', 'a startup entry with an extra word', (c) => `${c} verify`],
    ['SessionEnd', 'a cleanup entry that drops the marker flag', (c) => c.replace(' --fail-closed-when "HIMMEL_READINESS=1"', '')],
    ['SessionStart', 'a startup entry with another marker', (c) => c.replace('HIMMEL_READINESS=1', 'HIMMEL_WORKER=1')],
    ['SessionEnd', 'a cleanup entry registered from the plugin hooks directory', () => `${WIRED_PREFIX}"\${CLAUDE_PLUGIN_ROOT}/hooks/${SESSION}" cleanup`],
  ];
  for (const [event, label, change] of mutations) {
    withFixture((fixture) => {
      const doc = JSON.parse(readFileSync(fixture, 'utf8'));
      const hook = doc.hooks[event].flatMap((g) => g.hooks).find((h) => h.command.includes(SESSION));
      assert.ok(hook, label);
      hook.command = change(hook.command);
      writeFileSync(fixture, `${JSON.stringify(doc, null, 2)}\n`);
      const before = readFileSync(fixture, 'utf8');
      const result = invoke(fixture);
      assert.equal(result.status, 1, label);
      assert.match(result.stderr, /command inventory mismatch/, label);
      assert.equal(readFileSync(fixture, 'utf8'), before, label);
    }, { wired: true });
  }
});

test('the wirer migrates an unwired session entry to the wired command with its verb kept', () => {
  withFixture((fixture) => {
    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    const doc = JSON.parse(readFileSync(fixture, 'utf8'));
    const verbs = ['SessionStart', 'SessionEnd'].map((e) => doc.hooks[e].flatMap((g) => g.hooks).find((h) => h.command.includes(SESSION))?.command);
    assert.deepEqual(verbs, [sessionCommand('startup'), sessionCommand('cleanup')]);
  });
});

test('the wirer refuses a guard entry that drops its marker flag, uses another marker or moves to the plugin hooks directory, without writing', () => {
  const mutations = [
    ['a guard without the fail-closed flag', (c) => c.replace(' --fail-closed-when "HIMMEL_READINESS=1"', '')],
    ['a guard with another marker', (c) => c.replace('HIMMEL_READINESS=1', 'HIMMEL_WORKER=1')],
    ['a guard registered from the plugin hooks directory', () => `${WIRED_PREFIX}"\${CLAUDE_PLUGIN_ROOT}/hooks/${GUARD}"`],
  ];
  for (const [label, change] of mutations) {
    withFixture((fixture) => {
      const doc = JSON.parse(readFileSync(fixture, 'utf8'));
      const hook = Object.values(doc.hooks).flatMap((groups) => groups.flatMap((g) => g.hooks)).find((h) => h.command.includes(GUARD));
      assert.ok(hook, label);
      hook.command = change(hook.command);
      writeFileSync(fixture, `${JSON.stringify(doc, null, 2)}\n`);
      const before = readFileSync(fixture, 'utf8');
      const result = invoke(fixture);
      assert.equal(result.status, 1, label);
      assert.match(result.stderr, /command inventory mismatch/, label);
      assert.equal(readFileSync(fixture, 'utf8'), before, label);
    }, { wired: true });
  }
});
