// The daily tool-health record: one UTC day of the Tool health page's counts as the body of an eval-run row.
//
// The counts are the page's own (rollupToolHealth over a one-day window), so the page and the eval share one counting
// implementation. This module is pure: it reads nothing and writes nothing. tool_health_record.py wraps the body in the
// validated eval-runs envelope and appends it once per day. Record first, audit read-only: no rule reads this eval, so
// nothing changes because of it.
import { rollupToolHealth } from './tool-health.mjs';

export const RECORD_VERSION = 1;
const num = (n) => typeof n === 'number' && Number.isFinite(n);
const ratio = (n, d) => num(n) && num(d) && d > 0 ? n / d : null;
const GUARD = /^denied\/(?!classifier|other$|permission-prompt$)(.+)$/;
const REASONS = ['rule', 'timeout', 'deadline', 'buffer', 'other'];

// The page's roll-up over exactly one UTC day: window = [day, day].
export function recordRollup(evals, failures, day, { eligible, chain } = {}) {
  return rollupToolHealth(evals, failures, new URLSearchParams({ since: day }), Date.parse(`${day}T23:59:59.999Z`), {}, { eligible, chain });
}

// Pooled rate over several days: sum the counts, then divide. Zero or an unknown denominator, or an unknown count, gives null.
export function poolRate(pairs) {
  if (!pairs.length || pairs.some(([n, d]) => !num(n) || !num(d))) return null;
  return ratio(pairs.reduce((s, [n]) => s + n, 0), pairs.reduce((s, [, d]) => s + d, 0));
}

// The same over daily records of one series. Only an ok record enters the pool: a partial day is not a count to sum.
export function poolRecords(records, caseId, numField, denField) {
  const rows = records.filter((r) => r && r.status === 'ok' && r.cases && r.cases[caseId]);
  return poolRate(rows.map((r) => [r.cases[caseId][numField], r.cases[caseId][denField]]));
}

// rollup: recordRollup's result. Returns the record body, or null when nobody ran that day.
export function buildRecord(rollup, { day }) {
  if (!rollup || rollup.state !== 'ok') return null;
  const chain = rollup.chain || {}, tools = rollup.tools || [];
  const guards = (rollup.hooks || []).flatMap((h) => { const m = GUARD.exec(h.class); return m ? [[m[1], h]] : []; });
  const cases = {}, metrics = {};
  const problems = [];
  const totalKnown = num(rollup.totalCalls);

  for (const t of tools) {
    cases[`tool:${t.tool}`] = { calls: num(t.calls) ? t.calls : null, failures: t.failures, errors: t.errors, denials: t.denials, recovered: t.recovered, known: t.known };
    metrics[`tool.${t.tool}.calls`] = num(t.calls) ? t.calls : null;
    metrics[`tool.${t.tool}.fail_rate`] = ratio(t.failures, t.calls);
    if (t.denials > t.failures || (num(t.calls) && t.failures > t.calls)) problems.push(`tool ${t.tool}: denials <= failures <= calls does not hold`);
  }
  for (const [name, h] of guards) {
    const gap = h.reason_gap;
    const reasons = Object.fromEntries(REASONS.map((k) => [`reason_${k}`, gap ? gap.by_reason[k] : null]));
    cases[`guard:${name}`] = { denials: h.failures, eligible_calls: num(h.eligible_calls) ? h.eligible_calls : null, unattributed: h.unattributed, outside_eligible: num(h.outside_eligible) ? h.outside_eligible : null,
      ...reasons, reason_before_logging: gap ? gap.before_reasons_logged : null, reason_not_established: gap ? gap.not_established : null };
    metrics[`guard.${name}.denials`] = h.failures;
    metrics[`guard.${name}.eligible_calls`] = num(h.eligible_calls) ? h.eligible_calls : null;
    metrics[`guard.${name}.deny_rate`] = num(h.eligible_rate) ? h.eligible_rate : null;
    metrics[`guard.${name}.timeout_rate`] = gap ? ratio(gap.by_reason.timeout, h.eligible_calls) : null;
    if (gap && REASONS.reduce((s, k) => s + gap.by_reason[k], gap.before_reasons_logged + gap.not_established) !== h.failures) problems.push(`guard ${name}: reason rows and residuals do not add up to the denials`);
  }
  metrics.calls = totalKnown ? rollup.totalCalls : (rollup.totalCalls === 0 ? 0 : null);
  metrics.failures = tools.reduce((s, t) => s + t.failures, 0);
  metrics.denials = tools.reduce((s, t) => s + t.denials, 0);

  const missing = [];
  if (rollup.eligible_fingerprint == null) missing.push('wiring');
  if (chain.state !== 'ok') missing.push('hook-chain log');
  if (!totalKnown) missing.push('call denominators');
  if (guards.some(([, h]) => !num(h.eligible_calls))) missing.push('guard denominators');
  const status = missing.length || problems.length ? 'partial' : rollup.totalCalls === 0 ? 'inconclusive' : 'ok';
  const a = chain.audit || {};
  return {
    day, status, n: totalKnown ? rollup.totalCalls : null,
    // What a count MEANS, never the day or a measured count: a changed wiring starts a new series.
    config: { count_definition_version: RECORD_VERSION, day_window: 'utc-day', population: 'all-production-sessions', selection: { model: '', lane: '', role: '', profile: '', team: '' }, denominator_policy: 'option-b-effective-matchers', wiring: rollup.eligible_fingerprint ?? null },
    metrics, cases,
    meta: { day, record_version: RECORD_VERSION, n_is: 'scored tool-call attempts',
      audit: { window: [rollup.first_day, rollup.last_day], missing_sources: missing, reconciliation: problems.length ? problems : 'pass', chain_state: chain.state ?? 'not-read', run_log_start: chain.run_log_start ?? null,
        chain_rows: { total: a.total ?? null, accepted: a.accepted ?? null, excluded_fixture: a.excluded_fixture ?? null, unverified: a.unverified ?? null, malformed: a.malformed ?? null, duplicates: a.duplicates ?? null } } },
  };
}
