#!/usr/bin/env node
// hook-probe.mjs — run the REAL wired PreToolUse chain against ONE planned tool
// call and say which hook would refuse it.
//
// WHY: a worker learns a command is refused only by being refused, or writes an
// ad-hoc probe. Static simulation (the removed /guardrail-sim, and
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
// Exit 0 = ALLOW, 1 = DENY (some hook refused), 2 = usage error or nothing to
// probe (no PreToolUse entry matches the tool: an unprobed call is not ALLOW).
// The probe fails CLOSED where the launcher's runChain does: a missing or
// duplicate chain member, an integrity mismatch, any member killed by a signal,
// and a must-run member that crashes, times out or overflows its buffer are all
// DENY. The pin check needs a session record: it runs only when the caller names
// a session (--session ID, or a --payload carrying session_id); otherwise the
// output says `integrity: not checked` rather than implying it passed.
// An `ask` row is shown as such but does not make the verdict DENY: PROBE ALLOW
// means no hook refused outright, so read the per-hook rows for a prompt.

import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, rmSync, statSync } from 'node:fs';
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
// The fail-closed policy lives in the launcher; read it from there, never copy it.
const {
  resolveBash,
  MUST_RUN_CHAIN_MEMBERS,
  MIN_MEMBER_TIMEOUT_MS,
  memberTimeoutMs,
  isRecoverableEpipe,
  verifyProjectHookIntegrity,
} = createRequire(import.meta.url)(join(HERE, '..', 'hooks', 'run-hook-with-bash.js'));

// The launcher's own member output ceiling (MEMBER_MAX_BUFFER there, not exported).
const MEMBER_MAX_BUFFER = 16 * 1024 * 1024;

// A session id nobody supplied: it names no integrity record, so it is never
// used to claim the pin check ran.
const DEFAULT_SESSION = 'hook-probe';

const USAGE = 'usage: hook-probe.mjs (--tool NAME --command CMD | --payload FILE [--tool NAME]) [--session ID] [--json] [--settings PATH]';

class UsageError extends Error {}

export function parseArgs(argv) {
  const opts = { tool: null, command: null, payload: null, settings: null, session: null, json: false };
  const takesValue = {
    '--tool': 'tool', '--command': 'command', '--payload': 'payload', '--settings': 'settings', '--session': 'session',
  };
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
    session_id: opts.session || DEFAULT_SESSION,
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

// Mirror of runChain's member verdict (run-hook-with-bash.js). Only a MUST_RUN
// member fails closed on a crash, a timeout or a buffer overflow
// an advisory member's failure is a non-blocking error row.
export function classifyMember(result, mustRun) {
  if (result && result.error && !isRecoverableEpipe(result)) {
    const code = result.error.code;
    if (code === 'ETIMEDOUT' || code === 'ENOBUFS') {
      return mustRun
        ? { decision: 'deny', rc: null, reason: `must-run guard did not evaluate this call (${code}); failing closed` }
        : { decision: 'error', rc: null, reason: `${code}: guard did not evaluate this call` };
    }
    return { decision: 'deny', rc: null, reason: `failed to start: ${result.error.message}` };
  }
  const status = result ? result.status : null;
  // runChain maps a non-number status (killed by a signal) to 2 for EVERY
  // member, advisory included, so it denies there too.
  if (status === null) {
    return { decision: 'deny', rc: null, reason: `guard did not decide (signal ${result && result.signal}); failing closed` };
  }
  const crashed = status !== 0 && status !== 2;
  if (mustRun && crashed) {
    return { decision: 'deny', rc: status, reason: `must-run guard crashed instead of deciding (rc=${status}); failing closed` };
  }
  return classify(result);
}

// runChain validates the WHOLE chain before running any member: a duplicate or a
// member that is not a regular file denies outright. Returns deny rows, or [].
function validateChain(members) {
  const rows = [];
  const seen = new Set();
  if (members.length === 0) rows.push({ hook: '(empty chain)', decision: 'deny', rc: null, reason: 'chain names no members' });
  for (const member of members) {
    const hook = basename(member);
    if (seen.has(member)) {
      rows.push({ hook, decision: 'deny', rc: null, reason: `duplicate chain member ${member}` });
      continue;
    }
    seen.add(member);
    let isFile = false;
    try {
      isFile = statSync(member).isFile();
    } catch {
      isFile = false;
    }
    if (!isFile) rows.push({ hook, decision: 'deny', rc: null, reason: `chain member not found: ${member}` });
  }
  return rows;
}

// One row per probed unit: each --chain member on its own (so the deny names the
// member), a non-chain entry as its whole command string.
// `payload.session_id` names the integrity record to check chain members against;
// the default id has none, so the pin check is skipped (see integrityChecked).
export function integrityChecked(payload) {
  return typeof payload.session_id === 'string' && payload.session_id !== DEFAULT_SESSION;
}

export function probe({ settings, settingsPath, payload, cwd, bash, scratch }) {
  const env = { ...process.env, ...benchEnv(scratch, cwd, pluginRootFor(settingsPath)) };
  const input = JSON.stringify(payload) + '\n';
  const rows = [];
  for (const entry of enumerateHooks(settings)) {
    if (entry.event !== 'PreToolUse' || !matcherMatches(entry.matcher, payload.tool_name)) continue;
    const members = chainMembers(entry.command, cwd);
    const entryMs = typeof entry.timeout === 'number' ? entry.timeout * 1000 : 60_000;
    if (members) {
      const invalid = validateChain(members);
      if (invalid.length) {
        for (const r of invalid) rows.push({ matcher: entry.matcher, ...r });
        continue;
      }
    }
    for (const member of members || [null]) {
      const hook = member ? basename(member) : singleLabel(entry.command);
      const skipped = SKIP.some((s) => (member || entry.command).includes(s));
      const row = { hook, matcher: entry.matcher };
      if (skipped) {
        rows.push({ ...row, decision: 'skipped', rc: null, reason: '' });
        continue;
      }
      if (member && integrityChecked(payload)) {
        const integrity = verifyProjectHookIntegrity(member, payload.session_id);
        if (!integrity.ok) {
          rows.push({ ...row, decision: 'deny', rc: null, reason: `integrity mismatch for ${integrity.relPath || member}: ${integrity.reason}` });
          continue;
        }
      }
      // A chain member gets the launcher's window (grows with the payload),
      // capped by the entry's own; a non-chain command runs on the entry's alone.
      const window = member
        ? Math.max(MIN_MEMBER_TIMEOUT_MS, Math.min(memberTimeoutMs(Buffer.byteLength(input)), entryMs))
        : entryMs;
      const result = spawnSync(bash, member ? [member] : ['-c', entry.command], {
        input, cwd, env, encoding: 'utf8', killSignal: 'SIGKILL', timeout: window, maxBuffer: MEMBER_MAX_BUFFER,
      });
      rows.push({ ...row, ...(member ? classifyMember(result, MUST_RUN_CHAIN_MEMBERS.has(hook)) : classify(result)) });
    }
  }
  return rows;
}

export function formatText(rows, verdict, integrity = 'checked') {
  const lines = [];
  for (const r of rows) {
    lines.push(`${r.hook} ${r.decision} rc=${r.rc === null ? '-' : r.rc}`);
    if (r.reason && (r.decision === 'deny' || r.decision === 'ask' || r.decision === 'error')) lines.push(`  reason: ${r.reason}`);
  }
  if (integrity !== 'checked') lines.push('integrity: not checked (no session record; pass --session ID or a --payload carrying session_id)');
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
    if (rows.length === 0) {
      process.stderr.write(`hook-probe: no PreToolUse entry in ${settingsPath} matches tool ${payload.tool_name}; nothing was probed, so no verdict\n`);
      return 2;
    }
    const verdict = rows.some((r) => r.decision === 'deny') ? 'DENY' : 'ALLOW';
    const integrity = integrityChecked(payload) ? 'checked' : 'not checked';
    process.stdout.write((opts.json
      ? JSON.stringify({ verdict, tool: payload.tool_name, settings: settingsPath, integrity, hooks: rows })
      : formatText(rows, verdict, integrity)) + '\n');
    return verdict === 'DENY' ? 1 : 0;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
