// Reader for the two hook-chain logs behind the Tool health page.
//
//   hook-chain-skips.jsonl  one row per starvation incident (a skip or a fail-closed deny)
//   hook-runs.jsonl         one row per chain invocation: every member that ran, how it ended and how long it took
//
// Every row is audited before it counts. A row is accepted only when it says it is a production row and names the
// exact call it is about; a row marked as a test is excluded, and a row whose provenance cannot be shown is
// unverified. Unverified rows are never counted as incidents and never as zero: they make the roll-up partial.
// A missing source reads as unknown, never as 0.
import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const TAIL_BYTES = 16 * 1024 * 1024;
export const EVENT_CAP = 300;
export const MEMBER_EVENT_CAP = 20;
export const KINDS = ['rule', 'timeout', 'deadline', 'buffer', 'other'];
const KIND_OF = { RULE: 'rule', ETIMEDOUT: 'timeout', ENTRY_DEADLINE: 'deadline', ENOBUFS: 'buffer' };
// A run-record entry with one of these reasons names a guard the chain never started: it is a refusal or a skip, not a run.
const NEVER_STARTED = new Set(['INTEGRITY', 'ENTRY_DEADLINE', 'SPAWN']);
const DENY_LINE_MAX_CODE_POINTS = 240;
const CALL_ID = /^[A-Za-z0-9_.:-]{1,128}$/;
const INVOCATION = /^[0-9a-f]{12}$/;
const MEMBER = /^[A-Za-z0-9_.-]{1,120}$/;
const REASON = /^[A-Za-z0-9_=.:-]{1,40}$/;
const TOOL = /^[A-Za-z0-9_.:-]{1,160}$/;
const SESSION = /^[A-Za-z0-9_.:-]{1,128}$/;
// A control character or a line separator has no place in a one-line field; the renderer escapes the rest.
// eslint-disable-next-line no-control-regex
const NOT_PRINTABLE = new RegExp('[\\u0000-\\u001f\\u007f-\\u009f' + String.fromCharCode(0x2028, 0x2029) + ']', 'g');
const nonNegative = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
const count = (n) => Number.isSafeInteger(n) && n >= 0;
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// ----------------------------------------------------------------- reading

// Where the logs live: the one file an override names, else the checkout's own log plus every worktree's own log
// (a worktree session writes to its own .claude/logs, which the primary checkout's log never sees).
export function chainLogPaths(env, repoRoot) {
  const skipOverride = (env.RUN_HOOK_CHAIN_SKIP_LOG || '').trim();
  const runOverride = (env.RUN_HOOK_CHAIN_RUN_LOG || '').trim();
  const dirs = [];
  let worktreesUnreadable = false;
  if (repoRoot && (!skipOverride || !runOverride)) {
    dirs.push(join(repoRoot, '.claude', 'logs'));
    const worktrees = join(repoRoot, '.claude', 'worktrees');
    if (existsSync(worktrees)) {
      try {
        for (const name of readdirSync(worktrees)) {
          const dir = join(worktrees, name);
          try { if (statSync(dir).isDirectory()) dirs.push(join(dir, '.claude', 'logs')); } catch (e) { if (e?.code !== 'ENOENT') worktreesUnreadable = true; /* ENOENT: a vanished worktree */ }
        }
      } catch { worktreesUnreadable = true; }
    }
  }
  return {
    skip: skipOverride ? [skipOverride] : dirs.map((d) => join(d, 'hook-chain-skips.jsonl')),
    run: runOverride ? [runOverride] : dirs.map((d) => join(d, 'hook-runs.jsonl')),
    worktreesUnreadable,
  };
}

// The last TAIL_BYTES of one file as lines; a window that begins mid-row drops that row and says it was cut.
function readTail(file) {
  let fd;
  try { fd = openSync(file, 'r'); } catch (e) { return { state: e?.code === 'ENOENT' ? 'absent' : 'error' }; }
  try {
    const size = fstatSync(fd).size, start = Math.max(0, size - TAIL_BYTES);
    const from = Math.max(0, start - 1); // one byte early: tells a window that begins on a line start from one cut mid-row
    const buf = Buffer.alloc(size - from);
    readSync(fd, buf, 0, buf.length, from);
    let text = buf.toString('utf8');
    if (start > 0) text = text.slice(text.indexOf('\n') + 1);
    return { state: 'ok', lines: text.split('\n'), truncated: start > 0 };
  } catch { return { state: 'error' }; } finally { closeSync(fd); }
}

function readSource(files) {
  const rows = [];
  let malformed = 0, truncated = false, readable = 0, unreadable = 0;
  for (const file of files) {
    const t = readTail(file);
    if (t.state === 'error') unreadable++;
    if (t.state !== 'ok') continue;
    readable++; truncated ||= t.truncated;
    for (const line of t.lines) {
      if (!line.trim()) continue;
      try { rows.push(JSON.parse(line)); } catch { malformed++; }
    }
  }
  const state = unreadable ? 'error' : readable ? 'ok' : 'absent';
  return { state, rows, malformed, truncated, files: readable };
}

export function readChainLogs(env = process.env, repoRoot = null) {
  const paths = chainLogPaths(env, repoRoot);
  const skip = readSource(paths.skip), run = readSource(paths.run);
  return { skip, run, worktreesUnreadable: paths.worktreesUnreadable };
}

// ---------------------------------------------------------------- auditing

const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

// The skip-log row names one member and one action; null when it lacks any part of the call's identity.
function skipIdentity(r) {
  const ok = (r.action === 'deny' || r.action === 'skip') && MEMBER.test(r.member ?? '') && REASON.test(r.reason ?? '')
    && SESSION.test(r.sessionId ?? '') && CALL_ID.test(r.callId ?? '') && INVOCATION.test(r.invocation ?? '') && count(r.occurrence);
  return ok ? `${r.callId}\0${r.invocation}\0${r.member}\0${r.occurrence}` : null;
}

function runMembersValid(members) {
  return Array.isArray(members) && members.every((m) => isObject(m) && MEMBER.test(m.member ?? '') && count(m.occurrence)
    && ['allow', 'deny', 'skip', 'error'].includes(m.outcome) && (m.reason == null || REASON.test(m.reason)));
}

function runIdentity(r) {
  const ok = r.v === 1 && SESSION.test(r.session ?? '') && CALL_ID.test(r.callId ?? '') && INVOCATION.test(r.invocation ?? '') && runMembersValid(r.members);
  return ok ? `${r.session}\0${r.callId}\0${r.invocation}` : null;
}

// A lifecycle chain (session start, and the like) has no tool call to attribute anything to.
const nonToolRow = (r) => typeof r.event === 'string' && !/ToolUse|Permission/.test(r.event);

const clipLine = (v) => {
  if (typeof v !== 'string') return null;
  const line = v.replace(NOT_PRINTABLE, ' ').trim();
  return line ? Array.from(line).slice(0, DENY_LINE_MAX_CODE_POINTS).join('') : null;
};

function makeEvent(ts, base, entry) {
  const reason = entry.reason ?? 'RULE';
  const elapsed = nonNegative(entry.elapsed) ? entry.elapsed : null, budget = nonNegative(entry.budget) ? entry.budget : null;
  const notStarted = reason === 'ENTRY_DEADLINE' && elapsed === 0;
  return {
    ts, outcome: entry.outcome, reason, kind: KIND_OF[reason] ?? 'other', member: base.member, occurrence: base.occurrence,
    tool: TOOL.test(base.tool ?? '') ? base.tool : null, session: base.session, call_id: base.callId, invocation: base.invocation,
    deny_line: entry.outcome === 'deny' ? clipLine(entry.denyLine) : null, elapsed_ms: elapsed, budget_ms: budget, not_started: notStarted,
    // A ratio needs a recorded budget above zero and a call that started; it is never inferred from the member's name.
    ratio: elapsed !== null && budget !== null && budget > 0 && !notStarted ? elapsed / budget : null,
  };
}

const blankMember = (member) => ({ member, denials: 0, skips: 0, by_reason: Object.fromEntries(KINDS.map((k) => [k, 0])), runs: 0, errors: 0, run_ms: 0, max_ms: 0, events: [] });

// chain: {skip: {state, rows, malformed?, truncated?}, run: {...}} as readChainLogs returns it; absent = not read.
// firstDay/lastDay (YYYY-MM-DD, inclusive) bound the window; rows outside it are counted, not audited.
export function rollupChain(chain, { firstDay = null, lastDay = null } = {}) {
  if (!isObject(chain)) return { state: 'not-read' };
  const sources = {};
  for (const name of ['skip', 'run']) {
    const s = isObject(chain[name]) ? chain[name] : { state: 'absent' };
    sources[name] = { state: s.state === 'ok' || s.state === 'error' ? s.state : 'absent', rows: Array.isArray(s.rows) ? s.rows : [], malformed: count(s.malformed) ? s.malformed : 0, truncated: s.truncated === true, files: count(s.files) ? s.files : null };
  }
  const audit = { total: 0, accepted: 0, excluded_fixture: 0, unverified: 0, non_tool: 0, malformed: 0, duplicates: 0, outside_window: 0 };
  audit.total = sources.skip.malformed + sources.run.malformed; audit.malformed = audit.total;
  const events = new Map(), members = new Map(), seen = new Set();
  let invocations = 0, joined = 0;
  const member = (name) => { if (!members.has(name)) members.set(name, blankMember(name)); return members.get(name); };
  const addEvent = (ts, base, entry) => {
    const ev = makeEvent(ts, base, entry), key = `${base.callId}\0${base.invocation}\0${base.member}\0${base.occurrence}`, prev = events.get(key);
    if (!prev) { events.set(key, ev); return; }
    joined++; // the same incident seen in both logs counts once; the skip log's timing wins, the run log fills a missing deny line
    if (!prev.deny_line && ev.deny_line) prev.deny_line = ev.deny_line;
  };

  for (const name of ['skip', 'run']) {
    for (const r of sources[name].rows) {
      audit.total++;
      const ms = isObject(r) ? Date.parse(r.ts) : NaN;
      if (!isObject(r) || !Number.isFinite(ms) || Math.abs(ms) > 8640000000000000) { audit.malformed++; continue; }
      const day = dayOf(ms);
      if ((firstDay && day < firstDay) || (lastDay && day > lastDay)) { audit.outside_window++; continue; }
      if (r.origin === 'test') { audit.excluded_fixture++; continue; }
      if (r.origin !== 'production') { audit.unverified++; continue; }
      if (nonToolRow(r)) { audit.non_tool++; continue; }
      const identity = name === 'skip' ? skipIdentity(r) : runIdentity(r);
      if (identity === null) { audit.unverified++; continue; }
      const dedupe = `${name}\0${identity}`;
      if (seen.has(dedupe)) { audit.duplicates++; continue; }
      seen.add(dedupe); audit.accepted++;
      const ts = new Date(ms).toISOString();
      if (name === 'skip') {
        addEvent(ts, { member: r.member, occurrence: r.occurrence, tool: r.tool, session: r.sessionId, callId: r.callId, invocation: r.invocation },
          { outcome: r.action, reason: r.reason, elapsed: r.elapsed, budget: r.budget, denyLine: r.denyLine });
        continue;
      }
      invocations++;
      for (const m of r.members) {
        const stats = member(m.member);
        if (!NEVER_STARTED.has(m.reason)) {
          stats.runs++;
          if (m.outcome === 'error') stats.errors++;
          if (nonNegative(m.elapsed)) { stats.run_ms += m.elapsed; stats.max_ms = Math.max(stats.max_ms, m.elapsed); }
        }
        if (m.outcome === 'deny' || m.outcome === 'skip') {
          addEvent(ts, { member: m.member, occurrence: m.occurrence, tool: r.tool, session: r.session, callId: r.callId, invocation: r.invocation }, m);
        }
      }
    }
  }

  const ruleKnown = sources.run.state === 'ok', infraKnown = sources.skip.state === 'ok' || sources.run.state === 'ok';
  const list = [...events.values()].sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
  const byReason = Object.fromEntries(KINDS.map((k) => [k, 0]));
  const byAction = { deny: 0, skip: 0 };
  for (const ev of list) {
    byReason[ev.kind]++; byAction[ev.outcome]++;
    const m = member(ev.member);
    m.by_reason[ev.kind]++; if (ev.outcome === 'deny') m.denials++; else m.skips++;
    if (m.events.length < MEMBER_EVENT_CAP) m.events.push(ev);
  }
  const infra = byReason.timeout + byReason.deadline + byReason.buffer + byReason.other;
  const usable = sources.skip.state === 'ok' || sources.run.state === 'ok';
  // A worktree folder that could not be listed may hold logs this read never saw, so the counts cannot be called complete.
  const worktreesUnreadable = chain.worktreesUnreadable === true;
  const complete = sources.skip.state === 'ok' && sources.run.state === 'ok' && audit.unverified === 0 && audit.malformed === 0 && !sources.skip.truncated && !sources.run.truncated && !worktreesUnreadable;
  const state = !usable ? (sources.skip.state === 'error' || sources.run.state === 'error' ? 'error' : 'absent') : complete ? 'ok' : 'partial';
  const unknown = (n, known) => known ? n : null; // a count the sources cannot show is "—", never 0
  const reasonView = (r) => ({ ...r, rule: unknown(r.rule, ruleKnown), timeout: unknown(r.timeout, infraKnown), deadline: unknown(r.deadline, infraKnown), buffer: unknown(r.buffer, infraKnown), other: unknown(r.other, infraKnown) });
  return {
    state,
    sources: Object.fromEntries(Object.entries(sources).map(([k, s]) => [k, { state: s.state, files: s.files, malformed: s.malformed, truncated: s.truncated }])),
    audit, joined, rule_known: ruleKnown, infra_known: infraKnown, worktrees_unreadable: worktreesUnreadable,
    by_reason: reasonView(byReason), by_action: infraKnown ? byAction : { deny: null, skip: null },
    infra: unknown(infra, infraKnown), denials: unknown(byAction.deny, ruleKnown),
    invocations: unknown(invocations, ruleKnown),
    events: list.slice(0, EVENT_CAP), events_total: list.length,
    members: Object.fromEntries([...members].map(([k, m]) => [k, { ...m, by_reason: reasonView(m.by_reason), runs: unknown(m.runs, ruleKnown), errors: unknown(m.errors, ruleKnown), run_ms: unknown(m.run_ms, ruleKnown), max_ms: unknown(m.max_ms, ruleKnown) }])),
  };
}

export const memberOfGuardClass = (cls) => typeof cls === 'string' && cls.startsWith('denied/') ? `${cls.slice(7)}.sh` : null;
