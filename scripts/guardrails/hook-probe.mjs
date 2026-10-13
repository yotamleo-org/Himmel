#!/usr/bin/env node
// hook-probe.mjs — run the REAL wired PreToolUse chain against ONE planned tool
// call and say which hook would refuse it (HIMMEL-4425).
//
// WHY: a leg learns a command is refused only by being refused, or writes an
// ad-hoc probe. Static simulation (the removed /guardrail-sim, HIMMEL-4381, and
// any future successor) PLANS: it predicts from the hook source what should
// happen. This probe PROVES: it feeds the real PreToolUse payload to each hook
// the settings file wires for that tool and reports what the hook actually
// printed, so false positives a static read cannot predict (a quoted pathspec,
// a grep regex beside a gate-script mention) show up before the call is made.
//
// It NEVER executes the probed command: the command only ever appears as a
// string inside the payload on a hook's stdin. Hooks still run for real, so
// state-writing hooks are redirected to a scratch dir through bench-hook-stack's
// own seams (benchEnv) and outbound hooks are skipped (SKIP), exactly as the
// latency bench does; nothing here is copied from it.
//
// Usage:
//   node scripts/guardrails/hook-probe.mjs --tool Bash --command '<cmd>' [--json] [--settings PATH]
//   node scripts/guardrails/hook-probe.mjs --payload <json-file> [--tool NAME] [--json] [--settings PATH]
//
// --payload takes either a full hook payload (has tool_name) or just a
// tool_input object (then --tool is required). Output, one line per hook:
//   <hook> allow|deny|ask|passthrough|error|skipped rc=<n>
//     reason: <first line of the deny/ask reason>
//   PROBE ALLOW|DENY
// Exit 0 = ALLOW, 1 = DENY (some hook refused), 2 = usage error.
// An `ask` row is shown as such but does not make the verdict DENY: PROBE ALLOW
// means no hook refused outright, so read the per-hook rows for a prompt.

import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

import {
  enumerateHooks,
  matcherMatches,
  chainMembers,
  benchEnv,
  pluginRootFor,
  labelFor,
  SKIP,
} from '../hooks/bench-hook-stack.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const { resolveBash } = createRequire(import.meta.url)(join(HERE, '..', 'hooks', 'run-hook-with-bash.js'));

const USAGE = 'usage: hook-probe.mjs (--tool NAME --command CMD | --payload FILE [--tool NAME]) [--json] [--settings PATH]';

class UsageError extends Error {}

export function parseArgs(argv) {
  const opts = { tool: null, command: null, payload: null, settings: null, json: false };
  const takesValue = { '--tool': 'tool', '--command': 'command', '--payload': 'payload', '--settings': 'settings' };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') { opts.json = true; continue; }
    if (Object.hasOwn(takesValue, arg)) {
      if (argv[i + 1] === undefined) throw new UsageError(`${arg} needs a value`);
      opts[takesValue[arg]] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new UsageError(`unknown argument: ${arg}`);
  }
  if (opts.payload === null && (!opts.tool || opts.command === null)) {
    throw new UsageError('need --tool NAME --command CMD, or --payload FILE');
  }
  return opts;
}

// Build the one PreToolUse payload every hook will see.
export function buildPayload(opts, cwd) {
  const base = {
    session_id: 'hook-probe',
    transcript_path: join(cwd, '.claude', 'hook-probe-transcript.jsonl'),
    cwd,
    hook_event_name: 'PreToolUse',
  };
  if (opts.payload === null) {
    return { ...base, tool_name: opts.tool, tool_input: { command: opts.command } };
  }
  let body;
  try {
    body = JSON.parse(readFileSync(opts.payload, 'utf8'));
  } catch (e) {
    throw new UsageError(`cannot read --payload ${opts.payload}: ${e.message}`);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new UsageError('--payload must be a JSON object');
  if (typeof body.tool_name === 'string') return { ...base, ...body, hook_event_name: 'PreToolUse' };
  if (!opts.tool) throw new UsageError('--payload holds a bare tool_input: pass --tool NAME');
  return { ...base, tool_name: opts.tool, tool_input: body };
}

const firstLine = (text) => String(text || '').split('\n').map((l) => l.trim()).find(Boolean) || '';

// Reduce one hook's rc/stdout/stderr to a decision. Claude Code reads exit 2 as
// block, exit 0 + a JSON envelope as the envelope's decision, any other exit as
// a non-blocking ERROR (not a deny — it is shown, and the call goes ahead).
export function classify(result) {
  if (!result || result.error || result.signal) {
    const why = result && (result.error ? result.error.message : `signal ${result.signal}`);
    return { decision: 'error', rc: result && result.status !== null ? result.status : null, reason: why || 'no result' };
  }
  const rc = result.status;
  if (rc === 2) return { decision: 'deny', rc, reason: firstLine(result.stderr) || firstLine(result.stdout) };
  if (rc !== 0) return { decision: 'error', rc, reason: firstLine(result.stderr) };
  let out = null;
  try {
    out = JSON.parse(String(result.stdout || '').trim());
  } catch {
    out = null;
  }
  // continue=false stops execution whatever permission verdict rides beside it.
  if (out && out.continue === false) return { decision: 'deny', rc, reason: firstLine(out.stopReason) || 'continue=false' };
  const specific = out && out.hookSpecificOutput;
  const verdict = specific && specific.permissionDecision;
  if (verdict === 'deny' || verdict === 'ask' || verdict === 'allow') {
    return { decision: verdict, rc, reason: firstLine(specific.permissionDecisionReason) };
  }
  if (out && out.decision === 'block') return { decision: 'deny', rc, reason: firstLine(out.reason) };
  return { decision: 'passthrough', rc, reason: '' };
}

// A non-chain entry is wrapped in the launcher's `if …; then …; else …; fi`, so
// name the script it runs, not the launcher or run-node shim around it.
const LAUNCHERS = new Set(['run-hook-with-bash.js', 'run-node.sh']);
function singleLabel(command) {
  const names = String(command).match(/[A-Za-z0-9_.-]+\.(?:sh|mjs|js|ts)/g) || [];
  return names.find((n) => !LAUNCHERS.has(n)) || labelFor(command);
}

// One row per probed unit: each --chain member on its own (so the deny names the
// member), a non-chain entry as its whole command string.
export function probe({ settings, settingsPath, payload, cwd, bash, scratch }) {
  const env = { ...process.env, ...benchEnv(scratch, cwd, pluginRootFor(settingsPath)) };
  const input = JSON.stringify(payload) + '\n';
  const rows = [];
  for (const entry of enumerateHooks(settings)) {
    if (entry.event !== 'PreToolUse' || !matcherMatches(entry.matcher, payload.tool_name)) continue;
    const members = chainMembers(entry.command, cwd);
    const units = members || [null];
    for (const member of units) {
      const hook = member ? basename(member) : singleLabel(entry.command);
      const skipped = SKIP.some((s) => (member || entry.command).includes(s));
      const row = { hook, matcher: entry.matcher };
      if (skipped) {
        rows.push({ ...row, decision: 'skipped', rc: null, reason: '' });
        continue;
      }
      const result = spawnSync(bash, member ? [member] : ['-c', entry.command], {
        input, cwd, env, encoding: 'utf8', killSignal: 'SIGKILL',
        timeout: typeof entry.timeout === 'number' ? entry.timeout * 1000 : 60_000,
      });
      rows.push({ ...row, ...classify(result) });
    }
  }
  return rows;
}

export function formatText(rows, verdict) {
  const lines = [];
  for (const r of rows) {
    lines.push(`${r.hook} ${r.decision} rc=${r.rc === null ? '-' : r.rc}`);
    if (r.reason && (r.decision === 'deny' || r.decision === 'ask' || r.decision === 'error')) lines.push(`  reason: ${r.reason}`);
  }
  lines.push(`PROBE ${verdict}`);
  return lines.join('\n');
}

function main(argv) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    process.stderr.write(`${e.message}\n${USAGE}\n`);
    return 2;
  }
  const cwd = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const settingsPath = opts.settings || join(cwd, '.claude', 'settings.json');
  let settings;
  let payload;
  try {
    payload = buildPayload(opts, cwd);
    settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    process.stderr.write(`hook-probe: ${e.message}\n`);
    return 2;
  }
  const bash = resolveBash();
  if (!bash) {
    process.stderr.write('hook-probe: no usable bash found (same resolver the wired hooks use)\n');
    return 2;
  }
  const scratch = mkdtempSync(join(tmpdir(), 'hook-probe-'));
  try {
    const rows = probe({ settings, settingsPath, payload, cwd, bash, scratch });
    const verdict = rows.some((r) => r.decision === 'deny') ? 'DENY' : 'ALLOW';
    process.stdout.write((opts.json
      ? JSON.stringify({ verdict, tool: payload.tool_name, settings: settingsPath, hooks: rows })
      : formatText(rows, verdict)) + '\n');
    return verdict === 'DENY' ? 1 : 0;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
