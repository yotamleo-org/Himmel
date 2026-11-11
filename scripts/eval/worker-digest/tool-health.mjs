// Shared read-only rollup for the Tool health page and chief board.
// Denominators live in eval-runs metadata; class/recovery rows come from worker-failures.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { estimateProfileListing } from './profile-listing.mjs';
import { canonicalProfileName } from '../../lanes/plugin-profiles.mjs';
import { memberOfGuardClass, rollupChain } from './chain-incidents.mjs';

export const LANES = ['native', 'claudex', 'openrouter', 'cloud', 'unknown'];
const num = (n) => Number.isSafeInteger(n) && n >= 0;
const rate = (n, d) => d !== null && d > 0 ? n / d : null;
const dayOf = (t) => Number.isFinite(t) && Math.abs(t) <= 8640000000000000 ? new Date(t).toISOString().slice(0, 10) : null;
// A denial recorded before per-tool cohorts names no tool: it sits in this explicit bucket, never guessed as Bash.
export const UNKNOWN_TOOL = '(unknown)';
const inferredTool = (cls) => cls.startsWith('error/') ? cls.slice(6).split(':')[0] : cls.startsWith('suite/') ? 'Bash' : cls.startsWith('denied/') ? UNKNOWN_TOOL : null;
function readRows(path) {
  try { return readFileSync(path, 'utf8').split('\n').flatMap((l) => { try { const r = JSON.parse(l); return r && typeof r === 'object' ? [r] : []; } catch { return []; } }); }
  catch { return []; }
}
const strOrNull = (v) => v === null || typeof v === 'string';
// launch-refusals.jsonl: v1 rows are refusals only (legacy); v2 rows are attempts, an attempt-started row and one
// terminal row sharing an attempt_id (headed-arm-worker.sh's EXIT trap).
export const LAUNCH_OUTCOMES = ['attempt-started', 'refused', 'launched', 'already-running', 'indeterminate', 'postlaunch-error'];
const LAUNCH_PHASES = ['brief-validation', 'usage-preflight', 'bus-registration', 'handoff', 'manifest', 'unknown'];
const validLaunch = (r) => r && typeof r === 'object' && !Array.isArray(r) && typeof r.ts === 'string' && Number.isFinite(Date.parse(r.ts))
  && typeof r.cause === 'string' && strOrNull(r.name) && strOrNull(r.line)
  && ((r.v === 1 && Number.isSafeInteger(r.rc))
    || (r.v === 2 && typeof r.attempt_id === 'string' && /^[0-9A-Za-z-]{1,80}$/.test(r.attempt_id) && LAUNCH_OUTCOMES.includes(r.outcome)
      && LAUNCH_PHASES.includes(r.phase) && (r.rc === null || Number.isSafeInteger(r.rc))));
export function readLaunchRows(path) {
  let text;
  try { text = readFileSync(path, 'utf8'); } catch (e) { return e && e.code === 'ENOENT' ? { exists: false, rows: [], skipped: 0 } : null; }
  const rows = []; let skipped = 0;
  for (const l of text.split('\n')) {
    if (!l.trim()) continue;
    let r; try { r = JSON.parse(l); } catch { skipped++; continue; }
    if (validLaunch(r)) rows.push(r); else skipped++;
  }
  return { exists: true, rows, skipped };
}
const CAUSE_RE = /^[a-z][a-z0-9-]{0,40}$/;
function rollupLaunches(launches, firstDay, lastDay) {
  if (!launches) return { state: 'not-read' };
  if (!launches.exists) return { state: 'absent', total: 0, by_cause: [], recent: [], skipped: 0 };
  const inWindow = launches.rows.filter((r) => { const d = dayOf(Date.parse(r.ts)); return d !== null && d >= firstDay && d <= lastDay; });
  // One attempt per attempt_id: its last terminal row decides, a replayed row counts once, and an attempt with only
  // attempt-started (a killed launcher) is unknown. The refusals below are v1 rows plus refused attempts.
  const attempts = new Map();
  for (const r of inWindow.filter((x) => x.v === 2)) {
    const a = attempts.get(r.attempt_id) ?? { terminal: null };
    if (r.outcome !== 'attempt-started') a.terminal = r;
    attempts.set(r.attempt_id, a);
  }
  const byOutcome = { launched: 0, 'already-running': 0, refused: 0, indeterminate: 0, 'postlaunch-error': 0, unknown: 0 };
  for (const a of attempts.values()) byOutcome[a.terminal ? a.terminal.outcome : 'unknown']++;
  const legacy = inWindow.filter((r) => r.v === 1);
  const refusals = [...legacy, ...[...attempts.values()].filter((a) => a.terminal?.outcome === 'refused').map((a) => a.terminal)];
  const causes = new Map();
  for (const r of refusals) {
    const cause = CAUSE_RE.test(r.cause) ? r.cause : 'other';
    const c = causes.get(cause) ?? { cause, count: 0, rc: {} };
    c.count++; c.rc[String(r.rc)] = (c.rc[String(r.rc)] ?? 0) + 1; causes.set(cause, c);
  }
  const recent = refusals.map((r, i) => ({ r, i })).sort((a, b) => Date.parse(b.r.ts) - Date.parse(a.r.ts) || b.i - a.i).slice(0, 20)
    .map(({ r }) => ({ ts: r.ts, name: r.name, cause: CAUSE_RE.test(r.cause) ? r.cause : 'other', rc: r.rc, line: r.line }));
  return { state: 'ok', total: refusals.length, attempts: { total: attempts.size, by_outcome: byOutcome }, legacy_rows: legacy.length, by_cause: [...causes.values()].sort((a, b) => b.count - a.count || a.cause.localeCompare(b.cause)), recent, skipped: launches.skipped };
}
// Test override for the listing cost, {profile: {tool: tokens}}; absent or unreadable = none.
function readListing(path) {
  try { const j = JSON.parse(readFileSync(path, 'utf8')); return j && typeof j === 'object' && !Array.isArray(j) ? j : {}; }
  catch { return {}; }
}
// estimateListing: price each profile's Skill listing from the installed plugins (unbilled scan, cached in memory);
// callers that only want failure rates (the chief board) leave it off and skip the scan.
// rtk: (ids) => {state, byId: Map<id, {path: 'rtk'|'bash', deny}>, duplicates}, the rtk history.db join; absent = not read.
// eligible: {hook name without .sh: [PreToolUse matchers]}, the tools each guard is wired to check; absent = unknown.
// chain: the hook-chain logs as chain-incidents.mjs reads them ({skip, run}); absent = not read, and the chain section says so.
export function readToolHealth(env = process.env, query = new URLSearchParams(), now = Date.now(), { estimateListing = false, rtk, eligible, chain } = {}) {
  const home = env.HOME || homedir();
  const listing = env.HIMMEL_PROFILE_LISTING ? readListing(env.HIMMEL_PROFILE_LISTING)
    : estimateListing ? estimateProfileListing({ configDir: env.CLAUDE_CONFIG_DIR || join(home, '.claude') }) : {};
  return rollupToolHealth(readRows(env.HIMMEL_EVAL_RUNS_LEDGER || join(home, '.himmel', 'eval-runs.jsonl')),
    readRows(env.HIMMEL_WORKER_SESSION_FAILURES_LEDGER || join(home, '.himmel', 'leg-failures.jsonl')), query, now, listing, { rtk, eligible, chain, launches: readLaunchRows(join(home, '.himmel', 'launch-refusals.jsonl')) });
}

// Option B (spec 0.3 B1): a guard's denominator is the calls to the tools it is wired to check, not Bash alone.
// A matcher is an anchored pattern over tool names ('*' or '' = every tool); a wired tool nobody called reads 0 calls.
// ponytail: anchored regex over the matcher text, Claude Code's own matching of exotic matchers is not mirrored, a matcher that does not compile gives no denominator.
// The digest splits Skill and Agent calls into Skill:<plugin>:<skill> and Agent:<type>; a matcher names the tool, so both match on the part before the colon.
const matcherTool = (tool) => /^(?:Skill|Agent):/.test(tool) ? tool.slice(0, tool.indexOf(':')) : tool;
function eligibleCalls(eligible, name, rows, complete) {
  if (!eligible || typeof eligible !== 'object' || !Object.hasOwn(eligible, name) || !Array.isArray(eligible[name]) || !complete) return null;
  const parts = eligible[name].flatMap((m) => m === '*' || m === '' ? ['.*'] : String(m).split('|'));
  const by = Object.fromEntries(parts.filter((p) => /^[\w-]+$/.test(p)).map((p) => [p, 0]));
  let tests;
  try { tests = parts.map((p) => new RegExp(`^(?:${p})$`)); } catch { return null; }
  for (const [key, calls] of rows) {
    const tool = matcherTool(key);
    if (tool === UNKNOWN_TOOL || !tests.some((re) => re.test(tool))) continue;
    if (calls === null) return null;
    by[tool] = (by[tool] || 0) + calls;
  }
  return { by, calls: Object.values(by).reduce((n, v) => n + v, 0) };
}
// A short id of the wiring, so a changed wiring starts a new series rather than splicing two denominators.
const eligibleFingerprint = (eligible) => eligible && typeof eligible === 'object'
  ? createHash('sha256').update(JSON.stringify(Object.keys(eligible).sort().map((k) => [k, [...eligible[k]].sort()]))).digest('hex').slice(0, 12) : null;

// Launch profile → v9 role (spec 0.4 a). An unmapped or absent profile is "other", never guessed.
const ROLE_OF = { chief: 'chief', 'chief-relay': 'chief-relay', 'worker-impl': 'worker', 'worker-bus': 'worker', 'worker-vm': 'worker',
  'worker-e2e': 'worker', design: 'worker', 'lane-impl': 'worker', code: 'worker', 'code-ui': 'worker', 'lane-content': 'worker',
  'console-judge': 'judge', 'release-manager': 'release-manager', 'lane-review': 'critic', user: 'interactive',
  // the launcher's own names: a chief's launch line carries its role, and rows written before the rename carry the old ids
  console: 'chief', 'console-relay': 'chief-relay', 'leg-impl': 'worker', 'leg-bus': 'worker', 'worker-docs': 'worker', 'worker-eval': 'worker' };
export const TEAMS = ['chief', 'chief-relay', 'worker', 'judge', 'release-manager', 'critic', 'interactive', 'other'];
export const teamOf = (profile) => Object.hasOwn(ROLE_OF, profile) ? ROLE_OF[profile] : /^design-[a-z0-9-]+$/.test(profile) ? 'worker' : 'other';
// Time to result (RESULT time minus START time, includes waiting and hooks): kept per call by the digest. A call without a time is
// missing, and a digest written before the times were kept leaves its calls unknown, never fast. The headline is the calls that
// were alone in their API message; batched calls wait on each other and are kept apart.
function addTiming(raw, row) {
  const t = row.timing;
  if (!t || !Array.isArray(t.single) || !Array.isArray(t.batched) || !num(t.missing)) { raw.unknown_calls += num(row.calls) ? row.calls : 0; return; }
  raw.single.push(...t.single.filter(num)); raw.batched.push(...t.batched.filter(num)); raw.missing += t.missing;
  if (t.capped === true) raw.capped = true;
}
const nearest = (xs, p) => xs.length ? xs.slice().sort((a, b) => a - b)[Math.ceil(p * xs.length) - 1] : null;
const timingOf = (raw) => ({ n: raw.single.length, p50_ms: nearest(raw.single, 0.5), p95_ms: nearest(raw.single, 0.95), batched_n: raw.batched.length, batched_p50_ms: nearest(raw.batched, 0.5),
  missing: raw.missing, unknown_calls: raw.unknown_calls, capped: raw.capped });
const CAUSES = ['command', 'rtk_hook', 'guard', 'classifier', 'other'];
// The digest's per-call outcome partition (digest_v 3). A row without one, or whose counts do not sum to its calls, is
// legacy for comparison: its tool and the totals report outcomes as null, never as zeros.
export const OUTCOMES = ['ok', 'ok_blocked', 'error', 'denied', 'no_verdict', 'interrupted', 'unknown'];
const zeroOutcomes = () => Object.fromEntries(OUTCOMES.map((k) => [k, 0]));
const validOutcomes = (o, calls) => !!o && typeof o === 'object' && !Array.isArray(o) && OUTCOMES.every((k) => num(o[k]))
  && num(calls) && OUTCOMES.reduce((n, k) => n + o[k], 0) === calls;

const PROFILE = /^[a-z0-9][a-z0-9-]{0,40}$/;
// A row recorded before the rename carries the old profile id; it rolls up under the renamed one.
const profileOf = (...candidates) => {
  const c = candidates.find((x) => typeof x === 'string' && PROFILE.test(x));
  return c ? canonicalProfileName(c) : 'unknown';
};

// listing: {profile: {tool: listing tokens}} from profile-listing.mjs; absent = no drop candidates.
export function rollupToolHealth(evals, failures, query = new URLSearchParams(), now = Date.now(), listing = {}, { rtk, eligible, chain, launches } = {}) {
  const days = query.get('days') === '30' ? 30 : 7;
  const since = query.get('since');
  const lastDay = dayOf(now), firstDay = since ? dayOf(Date.parse(since)) : dayOf(Date.parse(lastDay) - (days - 1) * 86400000);
  // Effective window: since..today when given (inclusive, like the days switch), else the days switch itself.
  const windowDays = firstDay && firstDay <= lastDay ? (Date.parse(lastDay) - Date.parse(firstDay)) / 86400000 + 1 : days;
  // The per-day trend never spans more than a year, so an old since cannot size the arrays.
  const trendDays = Math.min(windowDays, 366), trendFirst = windowDays > trendDays ? dayOf(Date.parse(lastDay) - (trendDays - 1) * 86400000) : firstDay;
  const team = query.get('team') || '';
  const selected = { model: query.get('model') || '', lane: query.get('lane') || '', role: query.get('role') || '', profile: query.get('profile') || '', team: TEAMS.includes(team) ? team : '', days };
  const matches = (r, withLane = true, withTeam = true) => (!selected.model || r.model === selected.model) && (!selected.role || r.role === selected.role) && (!selected.profile || r.profile === selected.profile) && (!withLane || !selected.lane || r.lane === selected.lane) && (!withTeam || !selected.team || r.team === selected.team);
  const sessions = new Map();
  for (const r of evals) {
    if (r.eval !== 'leg-trajectory' || typeof r.run_id !== 'string' || !['ok', 'partial', 'inconclusive'].includes(r.status)) continue;
    const prev = sessions.get(r.run_id);
    if (!prev || prev.status !== 'ok' || r.status === 'ok') sessions.set(r.run_id, r);
  }
  const slots = new Map(), byAgent = new Map(), models = new Set(), roles = new Set(), profiles = new Set();
  for (const [session, r] of sessions) {
    const ts = typeof r.meta?.started_ts === 'number' ? r.meta.started_ts : Date.parse(r.ts);
    const day = dayOf(ts);
    if (!day) continue;
    const lane = LANES.includes(r.lane) ? r.lane : 'unknown';
    const role = r.meta?.leg ? 'leg' : 'console';
    const health = Array.isArray(r.meta?.tool_health) ? r.meta.tool_health : [];
    const addSlot = (agent, model, cohort = day, profile = profileOf(r.meta?.profile, r.config?.profile)) => {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(cohort) || cohort < firstDay || cohort > lastDay) return null;
      const key = `${session}\0${agent}\0${cohort}`;
      if (!slots.has(key)) {
        const slot = { session, agent, day: cohort, ts, lane, role, profile, defv: num(r.config?.digest_v) ? String(r.config.digest_v) : 'unknown', team: teamOf(profile), gap: typeof r.meta?.launch_gap === 'string' ? r.meta.launch_gap : null, model: model || 'unknown', known: Array.isArray(r.meta?.tool_health), incomplete: r.status !== 'ok' || (!!since && cohort === firstDay && Date.parse(since) !== Date.parse(firstDay)), tools: new Map(), failures: [] };
        slots.set(key, slot);
        const agentKey = `${session}\0${agent}`, cohorts = byAgent.get(agentKey) || [];
        cohorts.push(slot); byAgent.set(agentKey, cohorts);
      }
      const slot = slots.get(key); models.add(slot.model); roles.add(slot.role); profiles.add(slot.profile); return slot;
    };
    if (!health.length) addSlot('main', r.model);
    for (const h of health) {
      if (!h || typeof h.tool !== 'string' || !num(h.calls) || !num(h.failures) || !num(h.errors) || !num(h.denials) || typeof h.agent?.id !== 'string') continue;
      const slot = addSlot(h.agent.id, h.agent.model || (h.agent.id === 'main' ? r.model : null), h.day || day, profileOf(h.profile, r.meta?.profile, r.config?.profile));
      const blocked = h.classes && num(h.classes['blocked/-']) ? Math.min(h.classes['blocked/-'], h.failures) : 0;
      if (slot) slot.tools.set(h.tool, { ...h, failures: h.failures - blocked, blocked });
    }
  }
  // The paired snapshot: a selected eval row's meta.tool_failures is its session's failure set (an empty list means
  // none), so the failures shown always belong to the row counted; the ledger is the fallback for a row without it.
  const paired = new Map([...sessions].filter(([, r]) => Array.isArray(r.meta?.tool_failures)).map(([id, r]) => [id, r.meta.tool_failures]));
  const failureRows = [...failures.filter((r) => !(r && paired.has(r.session))),
    ...[...paired].flatMap(([session, list]) => list.filter((f) => f && typeof f === 'object').map((f) => ({ ...f, session })))];
  const seenFailures = new Set();
  for (const r of failureRows) {
    if (!r || typeof r.class !== 'string' || !num(r.count) || !r.agent || r.failure === 'traj' || r.failure === 'run_error') continue;
    const identity = `${r.session}\0${r.agent.id}\0${r.class}`;
    if (seenFailures.has(identity)) continue;
    seenFailures.add(identity);
    let candidates = byAgent.get(`${r.session}\0${r.agent.id}`) || [];
    // Legacy subagent failures still show with unknown denominators.
    if (!candidates.length) {
      const main = byAgent.get(`${r.session}\0main`)?.[0];
      if (main && !main.known) {
        const slot = { ...main, agent: r.agent.id, model: r.agent.model || 'unknown', known: false, tools: new Map(), failures: [] };
        models.add(slot.model); profiles.add(slot.profile); slots.set(`${r.session}\0${r.agent.id}\0${slot.day}`, slot); candidates = [slot]; byAgent.set(`${r.session}\0${r.agent.id}`, candidates);
      }
    }
    for (const slot of candidates) {
      const health = [...slot.tools.values()];
      const count = slot.known && health.every((h) => h.classes && typeof h.classes === 'object')
        ? health.reduce((n, h) => n + (num(h.classes[r.class]) ? h.classes[r.class] : 0), 0) : r.count;
      if (!count) continue;
      slot.failures.push({ ...r, count });
      const tool = inferredTool(r.class), h = slot.tools.get(tool);
      if (!slot.known && tool) {
        if (h) { h.failures += count; if (r.failure === 'error' || r.failure === 'suite') h.errors += count; if (r.failure === 'denied') h.denials += count; }
        else slot.tools.set(tool, { tool, calls: null, failures: count, errors: r.failure === 'error' || r.failure === 'suite' ? count : 0, denials: r.failure === 'denied' ? count : 0, legacy: true });
      }
    }
  }
  const blank = () => ({ calls: 0, failures: 0, errors: 0, denials: 0, blocked: 0, recovered: 0, known: 0, outcomes: zeroOutcomes(), outcome_gaps: 0, sessions: new Set(), classes: new Map(), ids: new Set() });
  // retry_known / retry_changed_or_stopped: refused calls whose next step is known, and those where the caller changed the
  // call or stopped (the router's old `recovered` field, kept for compatibility); not proof the task was completed.
  const finish = ({ outcome_gaps, ...r }) => ({ ...r, outcomes: outcome_gaps ? null : r.outcomes, rate: rate(r.failures, r.calls), error_rate: rate(r.errors, r.calls), recovery_rate: rate(r.recovered, r.known), retry_known: r.known, retry_changed_or_stopped: r.recovered, sessions: [...r.sessions], classes: [...r.classes].sort((a, b) => b[1] - a[1]).map(([className, count]) => ({ class: className, count })), tool_call_ids: [...r.ids].slice(0, 20) });
  const sumCalls = (a, b) => a === null || b === null ? null : a + b;
  function aggregate(list) {
    const tools = new Map(), daily = new Map(), hooks = new Map(), dailyHooks = new Map(), bashByGroup = new Map();
    let bashCalls = 0, totalCalls = 0;
    for (const s of list) {
      const group = `${s.day}\0${s.model}\0${s.lane}\0${s.role}`;
      const bash = s.tools.get('Bash'), calls = s.known && !s.incomplete ? bash ? bash.calls : 0 : null;
      bashCalls = sumCalls(bashCalls, calls);
      bashByGroup.set(group, sumCalls(bashByGroup.has(group) ? bashByGroup.get(group) : 0, calls));
      for (const h of s.tools.values()) {
        totalCalls = sumCalls(totalCalls, h.calls);
        const key = `${s.day}\0${s.model}\0${s.lane}\0${s.role}\0${h.tool}`;
        const t = tools.get(h.tool) || { ...blank(), tool: h.tool, timing_raw: { single: [], batched: [], missing: 0, unknown_calls: 0, capped: false } };
        addTiming(t.timing_raw, h);
        const d = daily.get(key) || { ...blank(), tool: h.tool, day: s.day, model: s.model, lane: s.lane, role: s.role };
        for (const target of [t, d]) {
          target.calls = sumCalls(target.calls, h.calls); target.failures += h.failures; target.errors += h.errors; target.denials += h.denials; target.blocked += h.blocked ?? 0; target.sessions.add(s.session);
          if (validOutcomes(h.outcomes, h.calls)) for (const k of OUTCOMES) target.outcomes[k] += h.outcomes[k]; else target.outcome_gaps++;
          for (const f of s.failures) {
            const count = h.classes ? h.classes[f.class] : inferredTool(f.class) === h.tool ? f.count : 0;
            if (!num(count) || count === 0) continue;
            target.classes.set(f.class, (target.classes.get(f.class) || 0) + count);
            for (const id of f.tool_call_ids || []) if (typeof id === 'string') target.ids.add(id);
            if (typeof f.recovered === 'boolean') { target.known += count; if (f.recovered) target.recovered += count; }
          }
        }
        tools.set(h.tool, t); daily.set(key, d);
      }
      for (const f of s.failures) {
        if (f.failure !== 'denied') continue;
        const h = hooks.get(f.class) || { ...blank(), class: f.class, refusals: [] };
        const key = `${group}\0${f.class}`;
        const d = dailyHooks.get(key) || { ...blank(), class: f.class, day: s.day, model: s.model, lane: s.lane, role: s.role, group };
        for (const target of [h, d]) {
          target.failures += f.count; target.sessions.add(s.session);
          for (const id of f.tool_call_ids || []) if (typeof id === 'string') target.ids.add(id);
          if (typeof f.recovered === 'boolean') { target.known += f.count; if (f.recovered) target.recovered += f.count; }
        }
        // The counted refusals themselves, so the chain can say which have a reason row; stripped before the result leaves.
        const dc = [...s.tools.values()].filter((t) => Array.isArray(t.denied_calls));
        const ids = dc.length ? [...new Set(dc.flatMap((t) => t.denied_calls.filter((c) => Array.isArray(c) && typeof c[0] === 'string' && c[1] === f.class).map((c) => c[0])))]
          : Array.isArray(f.tool_call_ids) ? f.tool_call_ids : [];
        h.refusals.push({ count: f.count, ids, session: s.session, first: f.first_ts, last: f.last_ts });
        hooks.set(f.class, h); dailyHooks.set(key, d);
      }
    }
    if (list.some((s) => !s.known || s.incomplete)) {
      for (const t of tools.values()) t.calls = null;
      bashCalls = null; totalCalls = null;
    }
    const unknownGroups = new Set(list.filter((s) => !s.known || s.incomplete).map((s) => `${s.day}\0${s.model}\0${s.lane}\0${s.role}`));
    for (const d of daily.values()) if (unknownGroups.has(`${d.day}\0${d.model}\0${d.lane}\0${d.role}`)) d.calls = null;
    // Per guard: refusals by the tool that was refused (by_tool), what no tool row accounts for (unattributed), and the option-B
    // rate over the calls to the tools the guard is wired to check. A refusal outside that set voids the rate (outside_eligible).
    const withEligible = (h, rows, complete) => {
      const by = {};
      for (const t of rows) { const n = t.classes.get(h.class); if (n) by[t.tool] = n; }
      const e = h.class.startsWith('denied/') ? eligibleCalls(eligible, h.class.slice(7), rows.map((t) => [t.tool, t.calls]), complete) : null;
      const outside = e ? h.failures - Object.entries(by).reduce((n, [tool, v]) => n + (Object.hasOwn(e.by, matcherTool(tool)) ? v : 0), 0) : null;
      return { ...h, by_tool: by, unattributed: h.failures - Object.values(by).reduce((n, v) => n + v, 0), eligible_calls: e ? e.calls : null, eligible_by_tool: e ? e.by : null, outside_eligible: outside, eligible_rate: e && outside === 0 ? rate(h.failures, e.calls) : null };
    };
    const allKnown = !list.some((s) => !s.known || s.incomplete);
    return { tools: [...tools.values()].map(finish).map(({ timing_raw, ...t }) => ({ ...t, timing: timingOf(timing_raw) })), daily: [...daily.values()].map(finish),
      hooks: [...hooks.values()].map((h) => finish(withEligible({ ...h, calls: bashCalls }, [...tools.values()], allKnown))),
      daily_hooks: [...dailyHooks.values()].map(({ group, ...h }) => finish(withEligible({ ...h, calls: bashByGroup.get(group) }, [...daily.values()].filter((d) => `${d.day}\0${d.model}\0${d.lane}\0${d.role}` === group), !unknownGroups.has(group)))), totalCalls };
  }
  // A session with no tool_health gives no denominator. While other sessions have one it is left out of every roll-up and counted
  // (coverage), so one missing session no longer turns the whole window into a dash. A window where none has data keeps its old view.
  const everySlot = [...slots.values()];
  const usable = everySlot.some((s) => s.known) ? everySlot.filter((s) => s.known) : everySlot;
  const all = usable.filter((s) => matches(s, false));
  const filtered = all.filter((s) => matches(s));
  const result = aggregate(filtered);
  const class_counts = Object.create(null);
  for (const s of filtered) for (const f of s.failures) class_counts[f.class] = (class_counts[f.class] || 0) + f.count;
  for (const t of result.tools) {
    t.trend = Array.from({ length: trendDays }, (_, i) => {
      const day = dayOf(Date.parse(trendFirst) + i * 86400000), rows = result.daily.filter((d) => d.tool === t.tool && d.day === day);
      const calls = rows.length ? rows.reduce((n, d) => sumCalls(n, d.calls), 0) : null;
      const value = rate(rows.reduce((n, d) => n + d.failures, 0), calls);
      return { day, calls, failures: rows.reduce((n, d) => n + d.failures, 0), rate: value, x: i * 118 / trendDays, height: value === null ? null : Math.min(26, value * 26) };
    });
  }
  const comparison = new Map();
  const compare = (metric, key, lane, value) => {
    const id = `${metric}\0${key}`, row = comparison.get(id) || { metric, key, values: {}, delta: {} };
    row.values[lane] = value; comparison.set(id, row);
  };
  for (const lane of LANES) {
    const a = aggregate(all.filter((s) => s.lane === lane));
    for (const t of a.tools) {
      compare('calls_per_100', t.tool, lane, rate(t.calls, a.totalCalls) === null ? null : 100 * rate(t.calls, a.totalCalls));
      compare('error_rate', t.tool, lane, t.error_rate); compare('recovery_rate', t.tool, lane, t.recovery_rate);
    }
    for (const h of a.hooks) compare('denial_rate', h.class, lane, h.rate);
  }
  for (const r of comparison.values()) for (const lane of LANES) r.delta[lane] = typeof r.values.native === 'number' && typeof r.values[lane] === 'number' ? r.values[lane] - r.values.native : null;
  const class_rates = new Map(result.hooks.map((h) => [h.class, h.rate]));
  for (const t of result.tools) for (const c of t.classes) {
    if (c.class.startsWith('denied/')) continue;
    const tool = inferredTool(c.class);
    const related = result.tools.filter((r) => tool === 'mcp' ? r.tool === 'mcp' || r.tool.startsWith('mcp__') : tool ? r.tool === tool : r.classes.some((x) => x.class === c.class));
    const calls = related.reduce((n, r) => sumCalls(n, r.calls), 0);
    const n = related.reduce((n, r) => n + (r.classes.find((x) => x.class === c.class)?.count || 0), 0);
    class_rates.set(c.class, rate(n, calls));
  }
  // Per profile: the same tool roll-up over that profile's sessions, joined to its listing cost. A listed tool no
  // session called reads 0 calls, but null when any session of the profile (also one left out of the roll-up for having
  // no tool_health) has unknown denominators: it may have called the tool. Cost over 0 and 0 calls is a drop-from-default
  // candidate. Proposal only, nothing here changes a profile.
  const byProfile = [...new Set(filtered.map((s) => s.profile))].sort().map((profile) => {
    const list = filtered.filter((s) => s.profile === profile), a = aggregate(list), costs = listing[profile] || {};
    const unknown = list.some((s) => !s.known || s.incomplete) || everySlot.some((s) => !s.known && s.profile === profile && matches(s)), seen = new Set(a.tools.map((t) => t.tool));
    const cost = (tool) => num(costs[tool]) ? costs[tool] : null;
    const verdict = (calls, tokens) => calls === 0 && tokens > 0 ? 'drop-candidate' : 'keep';
    const tools = [...a.tools.map((t) => ({ ...t, listing_tokens: cost(t.tool), verdict: verdict(t.calls, cost(t.tool)) })),
      ...Object.keys(costs).filter((tool) => !seen.has(tool) && cost(tool) !== null).sort().map((tool) => {
        const calls = unknown ? null : 0;
        return { ...finish({ ...blank(), tool, calls }), listing_tokens: cost(tool), verdict: verdict(calls, cost(tool)) };
      })];
    return { profile, sessions: new Set(list.map((s) => s.session)).size, tools };
  });
  const drop_candidates = byProfile.flatMap((p) => p.tools.filter((t) => t.verdict === 'drop-candidate')
    .map((t) => ({ profile: p.profile, tool: t.tool, listing_tokens: t.listing_tokens, calls: t.calls, window_days: windowDays, sessions: p.sessions })));
  // Per role, over every other filter but the role itself, so the role totals add up to that fleet.
  const teamSlots = usable.filter((s) => matches(s, true, false));
  const teams = TEAMS.filter((t) => teamSlots.some((s) => s.team === t)).map((t) => {
    const list = teamSlots.filter((s) => s.team === t), a = aggregate(list);
    return { team: t, sessions: new Set(list.map((s) => s.session)).size, calls: a.totalCalls, failures: a.tools.reduce((n, x) => n + x.failures, 0) };
  });
  // Role x lane x profile over every filter, one cell per combination that has a session. A cell's calls are null when any of
  // its sessions has unknown denominators.
  const cellKey = (s) => `${s.team}\0${s.lane}\0${s.profile}`;
  const cross_tab = [...new Set(filtered.map(cellKey))].sort().map((key) => {
    const list = filtered.filter((s) => cellKey(s) === key), a = aggregate(list);
    return { team: list[0].team, lane: list[0].lane, profile: list[0].profile, sessions: new Set(list.map((s) => s.session)).size,
      calls: a.totalCalls, failures: a.tools.reduce((n, x) => n + x.failures, 0), denials: a.tools.reduce((n, x) => n + x.denials, 0) };
  });
  // What the launch record leaves unnamed: the share of calls whose lane (or profile) reads unknown, and that remainder by
  // the kind of session it was. A session recorded before the kind was kept reads "not-restamped", never a guess.
  const callsOf = (list) => list.reduce((n, s) => n + [...s.tools.values()].reduce((m, h) => m + (num(h.calls) ? h.calls : 0), 0), 0);
  const totalCalls = callsOf(filtered), noLane = filtered.filter((s) => s.lane === 'unknown'), noProfile = filtered.filter((s) => s.profile === 'unknown');
  const remainder = [...new Set(noLane.map((s) => s.gap || 'not-restamped'))].sort().map((kind) => {
    const list = noLane.filter((s) => (s.gap || 'not-restamped') === kind);
    return { kind, sessions: new Set(list.map((s) => s.session)).size, calls: callsOf(list) };
  }).sort((a, b) => b.calls - a.calls || a.kind.localeCompare(b.kind));
  const attribution = { calls: totalCalls, lane_unknown_calls: callsOf(noLane), lane_unknown_share: rate(callsOf(noLane), totalCalls),
    profile_unknown_calls: callsOf(noProfile), profile_unknown_share: rate(callsOf(noProfile), totalCalls),
    lane_unknown_sessions: new Set(noLane.map((s) => s.session)).size, sessions: new Set(filtered.map((s) => s.session)).size, remainder };
  const refused = new Map(result.hooks.filter((h) => h.class.startsWith('denied/')).map((h) => [memberOfGuardClass(h.class), h.refusals]));
  const chainOut = rollupChain(chain, { firstDay, lastDay, refused });
  result.hooks = result.hooks.map(({ refusals, ...h }) => ({ ...h, reason_gap: chainOut.gaps?.[memberOfGuardClass(h.class)] ?? null }));
  const { gaps, ...chainShown } = chainOut ?? {};
  // The partition over the filtered window, and which digest meaning versions produced it: a window mixing versions, or
  // holding a session with no partition, is not a certified comparison.
  const withPartition = new Set(), withoutPartition = new Set(), digestV = {};
  for (const s of filtered) {
    const ok = [...s.tools.values()].every((h) => validOutcomes(h.outcomes, h.calls));
    (s.known && ok ? withPartition : withoutPartition).add(s.session);
  }
  for (const id of new Set(filtered.map((s) => s.session))) { const v = filtered.find((s) => s.session === id).defv; digestV[v] = (digestV[v] || 0) + 1; }
  for (const id of withPartition) if (withoutPartition.has(id)) withPartition.delete(id);
  const outcomesTotal = result.tools.length && result.tools.every((t) => t.outcomes)
    ? Object.fromEntries(OUTCOMES.map((k) => [k, result.tools.reduce((n, t) => n + t.outcomes[k], 0)])) : null;
  const outcome_coverage = { sessions: withPartition.size + withoutPartition.size, with_partition: withPartition.size, without_partition: withoutPartition.size,
    comparable: withoutPartition.size === 0 && Object.keys(digestV).length === 1 };
  return { state: slots.size ? 'ok' : 'absent', ...result, outcomes: outcomesTotal, outcome_coverage, definitions: { digest_v: digestV }, eligible_fingerprint: eligibleFingerprint(eligible), window_days: windowDays, first_day: firstDay, last_day: lastDay, profiles: byProfile, drop_candidates, class_rates: Object.fromEntries(class_rates), class_counts, comparison: [...comparison.values()], teams, cross_tab, attribution, bash: bashRollup(filtered, usable, rtk), coverage: coverageOf(everySlot.filter((s) => matches(s)), new Set(sessions.keys()), rtk, firstDay, lastDay), chain: chainOut.state === 'not-read' ? chainOut : chainShown, launches_refused: rollupLaunches(launches, firstDay, lastDay), filters: { models: [...models].sort(), lanes: LANES, roles: [...roles].sort(), profiles: [...profiles].sort(), teams: TEAMS.filter((t) => everySlot.some((s) => s.team === t)) }, selected };
}

// What the roll-up does not see: digested sessions that carry no tool_health (left out of the rates), and the sessions and
// Bash calls rtk's history.db saw in the window that have no digest at all. rtk.coverage(first, last) -> {state, sessions: Map<id, calls>}.
function coverageOf(window, digested, rtk, firstDay, lastDay) {
  const ids = (known) => new Set(window.filter((s) => s.known === known).map((s) => s.session));
  // What is measured: Claude Code journals the digest ingested. Native Codex and T3 sessions are not integrated, so their
  // counts are null (never zero), and the `native` lane is not native Codex coverage.
  const rows = window.flatMap((s) => [...s.tools.values()]);
  const sum = (k) => rows.reduce((n, h) => n + (num(h[k]) ? h[k] : 0), 0);
  const newest = window.reduce((t, s) => (Number.isFinite(s.ts) && (t === null || s.ts > t) ? s.ts : t), null);
  const cov = { sessions: ids(true).size, without_tool_health: ids(false).size, population: 'ingested Claude Code journal attempts',
    not_integrated: { codex: { calls: null, rate: null }, t3: { calls: null, rate: null } },
    newest_session_ts: newest === null ? null : new Date(newest).toISOString(),
    evidence: { denied_calls_captured: sum('denied_calls_captured'), denied_calls_omitted: sum('denied_calls_omitted'), rows_without_denied_calls: rows.filter((h) => num(h.denials) && h.denials > 0 && !Array.isArray(h.denied_calls)).length },
    rtk: { state: 'not-read', undigested_sessions: null, undigested_calls: null } };
  if (typeof rtk?.coverage !== 'function') return cov;
  let c;
  try { c = rtk.coverage(firstDay, lastDay); } catch { c = { state: 'error' }; }
  if (c?.state !== 'ok' || !(c.sessions instanceof Map)) { cov.rtk.state = c?.state === 'absent' ? 'absent' : 'error'; return cov; }
  const missing = [...c.sessions].filter(([id]) => !digested.has(id));
  cov.rtk = { state: 'ok', undigested_sessions: missing.length, undigested_calls: missing.reduce((n, [, calls]) => n + (num(calls) ? calls : 0), 0) };
  return cov;
}

// Bash by command head and cause (spec 0.4 d) from the digest's bash_calls, joined to rtk's history.db by call id.
// "fleet" (rtk vs bash) is computed over every window slot, unfiltered: v9 labels it "whole fleet".
function bashRollup(filtered, every, rtk) {
  const callsOf = (list) => list.flatMap((s) => { const b = s.tools.get('Bash'); return b && Array.isArray(b.bash_calls) ? b.bash_calls.filter((c) => Array.isArray(c) && typeof c[0] === 'string' && typeof c[1] === 'string') : []; });
  const bashTotal = (list) => list.reduce((n, s) => { const b = s.tools.get('Bash'); return n === null || !s.known || s.incomplete ? null : n + (b && num(b.calls) ? b.calls : 0); }, 0);
  const mine = callsOf(filtered), fleet = callsOf(every);
  let join = null;
  if (typeof rtk === 'function') {
    try { join = rtk([...new Set(fleet.map((c) => c[0]))]); } catch { join = { state: 'error' }; }
  }
  const ok = join?.state === 'ok';
  const pathOf = (id) => ok ? join.byId.get(id)?.path ?? null : null;
  const causeOf = (c) => {
    const cause = CAUSES.includes(c[2]) ? c[2] : c[2] === null ? null : 'other';
    // An rtk hook refusal reaches the journal as a denied call; history.db says it was rtk's.
    return (cause === 'guard' || cause === 'other') && ok && join.byId.get(c[0])?.deny ? 'rtk_hook' : cause;
  };
  const commands = new Map(), exits = new Map();
  for (const c of mine) {
    const r = commands.get(c[1]) || { head: c[1], calls: 0, failures: 0, cause: Object.fromEntries(CAUSES.map((k) => [k, 0])), exit: {}, rtk: ok ? 0 : null, bash: ok ? 0 : null };
    r.calls++;
    const cause = causeOf(c);
    if (cause) {
      r.failures++; r.cause[cause]++;
      // The exit code the command reported (the digest keeps it for command failures only), so a failure is more than "error".
      if (num(c[3])) { r.exit[c[3]] = (r.exit[c[3]] || 0) + 1; exits.set(c[3], (exits.get(c[3]) || 0) + 1); }
    }
    if (ok && pathOf(c[0]) === 'rtk') r.rtk++;
    if (ok && pathOf(c[0]) === 'bash') r.bash++;
    commands.set(c[1], r);
  }
  const total = bashTotal(filtered);
  const paths = { rtk: { calls: 0, failures: 0 }, bash: { calls: 0, failures: 0 }, unmatched: { calls: 0, failures: 0 } };
  for (const c of fleet) { const p = paths[pathOf(c[0]) ?? 'unmatched']; p.calls++; if (causeOf(c)) p.failures++; }
  return {
    commands: [...commands.values()].sort((a, b) => b.calls - a.calls || a.head.localeCompare(b.head)),
    exit_codes: [...exits].sort((a, b) => b[1] - a[1] || a[0] - b[0]).map(([code, count]) => ({ code, count })),
    recorded: mine.length, unrecorded: total === null ? null : Math.max(0, total - mine.length),
    rtk: ok ? { state: 'ok', matched: fleet.filter((c) => join.byId.has(c[0])).length, unmatched: fleet.filter((c) => !join.byId.has(c[0])).length, duplicates: num(join.duplicates) ? join.duplicates : 0 }
      : { state: join ? (join.state === 'absent' ? 'absent' : 'error') : 'not-read', matched: null, unmatched: null, duplicates: null },
    fleet: ok ? paths : null,
  };
}
