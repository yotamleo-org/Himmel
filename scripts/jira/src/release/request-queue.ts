import { hostname } from 'node:os';
import { isAbsolute } from 'node:path';
import { appendChain, readChain, writeSigned, type Chain } from './ledger.js';
import { scopeOk, terminalOf } from './reducer.js';
import { asksOperator, type TicketFacts } from './operator-work.js';
import type { IssueSnap, Lease, Op, OperatorRow, RequestRow, RulingRow, Verb } from './types.js';
import { BLOCKER_PULL_DECISION, decisionWords, operatorDecision, pending, withdraw } from './operator-acts.js';
import { type Ctx, f, latestRequests, load, type Loaded, loadOrThrow, locked, operatorFence, readLease, readMirror, seq, ts, vName } from './engine-core.js';

const sameMove = (a: Pick<RequestRow, 'verb' | 'from_v' | 'to_v'>, b: Pick<RequestRow, 'verb' | 'from_v' | 'to_v'>): boolean =>
  a.verb === b.verb && a.from_v === b.from_v && a.to_v === b.to_v;

export function request(ctx: Ctx, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  if (ctx.env.HIMMEL_RELEASE_MANAGER === '1') throw new Error('release request: the chief writes requests; the RM claims them');
  return locked(ctx, (l) => {
    const placement = ((o.evidence ?? {}) as Record<string, unknown>).chief_placement;
    if (placement !== undefined) {
      const waiting = [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()]
        .find((r) => r.key === o.key && (r.state === 'open' || r.state.startsWith('claimed:')));
      if (waiting?.state.startsWith('claimed:')) throw new Error(`release request: ${waiting.req} on ${o.key} is claimed; ask again after the run`);
      if (waiting && !sameMove(waiting, o)) {
        throw new Error(`release request: ${waiting.req} on ${o.key} waits for ${waiting.verb} ${waiting.from_v ?? 'backlog'} to ${waiting.to_v ?? 'backlog'}; withdraw it to place the key elsewhere`);
      }
      if (waiting) {
        const { prev: _p, mac: _m, ...rest } = waiting;
        return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, evidence: { ...((waiting.evidence ?? {}) as Record<string, unknown>), chief_placement: placement } });
      }
    }
    return fileRequest(ctx, l, o);
  });
}

export function fileRequest(ctx: Ctx, l: Loaded, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
  const pullAgain = (r: RequestRow) => isPullRequest(r) && isPullRequest(o as RequestRow);
  const dup = [...latest.values()].find((r) => (pending(r) || pullAgain(r)) && r.key === o.key && r.verb === o.verb
    && r.from_v === o.from_v && r.to_v === o.to_v);
  if (dup) return pending(dup) ? withRelation(ctx, l.k, dup, o) : dup;
  const same = unchangedRefusal(l, o);
  if (same) return same;
  const req = seq(`Q-${ctx.release}`, latest.keys());
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...o, req, ts: ts(ctx), state: 'open' });
}

const RELATION = ['follow_up_of', 'remainder'] as const;
const relationOf = (r: { evidence?: unknown }): string => canon(Object.fromEntries(RELATION.flatMap((k) => {
  const v = ((r.evidence ?? {}) as Record<string, unknown>)[k];
  return v === undefined ? [] : [[k, v]];
})));

export const pointerOf = (r: { evidence?: unknown }): unknown => ((r.evidence ?? {}) as Record<string, unknown>).operator_record;

function withRelation(ctx: Ctx, k: Buffer, dup: RequestRow, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  const want = relationOf(o);
  const relation = want !== '{}' && want !== relationOf(dup);
  const pointer = pointerOf(o) !== undefined && pointerOf(o) !== pointerOf(dup);
  if (!relation && !pointer) return dup;
  const { prev: _p, mac: _m, ...rest } = dup;
  const evidence = { ...((dup.evidence ?? {}) as Record<string, unknown>) };
  if (relation) {
    for (const key of RELATION) delete evidence[key];
    Object.assign(evidence, JSON.parse(want));
  }
  if (pointer) evidence.operator_record = pointerOf(o);
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), k, { ...rest, evidence });
}

export function requiredParentOf(history: RequestRow[]): Record<string, string> {
  const latest = new Map<string, RequestRow>();
  for (const r of history) latest.set(r.req, r);
  const out: Record<string, string> = {};
  for (const r of latest.values()) {
    if (r.state.startsWith('withdrawn')) continue;
    if (relationOf(r) === '{}') continue;
    const e = r.evidence as { follow_up_of?: unknown; remainder?: unknown };
    if (e.remainder === true && typeof e.follow_up_of === 'string') out[r.key] = e.follow_up_of;
    else delete out[r.key];
  }
  return out;
}

const askOp = (verb: Verb, from_v: string | null): 'add' | 'move' => (verb === 'INTAKE' && from_v === null ? 'add' : 'move');

export function recordRequestDecision(ctx: Ctx, o: { decision: string; words: string; key: string; verb: Verb; from_v: string | null; to_v: string | null }): OperatorRow {
  operatorFence(ctx);
  if (o.to_v === null) throw new Error('release request: --decision records the operator\'s words for a request into a version');
  const op = askOp(o.verb, o.from_v);
  return operatorDecision(ctx, {
    decision: o.decision, keys: [o.key], op, from_v: o.from_v, to_v: o.to_v, verbatim: o.words, ...decisionWords(ctx, o.decision, o.words),
  });
}

const citedOperator = (r: RequestRow): unknown => (r.evidence as { operator?: unknown } | null)?.operator;

export function requestWithWords(ctx: Ctx, row: Omit<RequestRow, 'req' | 'ts' | 'state'>, o: { decision: string; words: string }): {
  operator: OperatorRow; withdrawn: RequestRow | null; request: RequestRow;
} {
  const operator = recordRequestDecision(ctx, { decision: o.decision, words: o.words, key: row.key, verb: row.verb, from_v: row.from_v, to_v: row.to_v });
  const dup = locked(ctx, (l) => [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()]
    .find((r) => pending(r) && r.key === row.key && r.verb === row.verb && r.from_v === row.from_v && r.to_v === row.to_v));
  const withdrawn = dup && citedOperator(dup) === undefined
    ? withdraw(ctx, { req: dup.req, reason: `refiled citing the operator's words (${operator.id})`, by: operator.id })
    : null;
  const carried = withdrawn && dup && relationOf(row) === '{}' ? JSON.parse(relationOf(dup)) as Record<string, unknown> : {};
  const evidence = { ...carried, ...((row.evidence ?? {}) as Record<string, unknown>), operator: operator.id };
  return { operator, withdrawn, request: request(ctx, { ...row, why: `${row.why} (operator words: ${operator.id})`, evidence }) };
}

function chainFaultOf(l: Loaded): string | undefined {
  const [which, why] = l.operator.bad.length ? ['operator', l.operator.bad[0]] : l.rulings.bad.length ? ['rulings', l.rulings.bad[0]] : [];
  return which === undefined ? undefined : `the ${which} chain of ${l.decl.release} could not be verified to its end (${why})`;
}

export function chainFault(ctx: Ctx): string | undefined {
  const l = load(ctx);
  return 'unknown' in l ? undefined : chainFaultOf(l);
}

function coveringDecision(l: Loaded, ask: Pick<RequestRow, 'verb' | 'key' | 'from_v' | 'to_v'>): OperatorRow | undefined {
  if ((ask.verb !== 'INTAKE' && ask.verb !== 'REVERSION') || ask.to_v === null) return undefined;
  if (chainFaultOf(l) !== undefined) return undefined;
  const touched = [ask.from_v, ask.to_v].filter((v) => v !== null);
  const named = l.operator.verified.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(ask.key)
    && ([x.from_v, x.to_v].some((v) => v != null && touched.includes(v)) || (x.from_v == null && x.to_v == null) || (x.op === 'keep' && x.from_v == null)));
  const newest = Math.max(...named.map((x) => Date.parse(x.ts)));
  const top = named.filter((x) => Date.parse(x.ts) === newest);
  if (top.length !== 1 || top[0].words !== 1) return undefined;
  const [rec] = top;
  const op: Op = { kind: askOp(ask.verb, ask.from_v), from_v: ask.from_v, to_v: ask.to_v };
  if (!scopeOk({ authority: { kind: 'operator', ref: rec.id }, key: ask.key, op }, new Map([[rec.id, rec]]), l.decl.current)) return undefined;
  const ruled = Math.max(-Infinity, ...l.rulings.verified.filter((r) => r.key === ask.key).map((r) => Date.parse(r.ts)));
  return newest > ruled ? rec : undefined;
}

export function coveringRecord(ctx: Ctx, ask: Pick<RequestRow, 'verb' | 'key' | 'from_v' | 'to_v'>): OperatorRow | undefined {
  if ('unknown' in load(ctx)) return undefined;
  return locked(ctx, (l) => coveringDecision(l, ask));
}

export function requestOnRecord(ctx: Ctx, row: Omit<RequestRow, 'req' | 'ts' | 'state'>): { operator: OperatorRow; request: RequestRow } | undefined {
  operatorFence(ctx);
  if ('unknown' in load(ctx)) return undefined;
  return locked(ctx, (l) => {
    const operator = coveringDecision(l, row);
    if (!operator) return undefined;
    const evidence = { ...((row.evidence ?? {}) as Record<string, unknown>), operator: operator.id };
    return { operator, request: fileRequest(ctx, l, { ...row, evidence }) };
  });
}

export const PULL_MAX = 5;

export interface PullRow {
  key: string;
  blocks: string[];
  from_v: string | null;
  to_v: string;
}

export interface PullOut {
  current: string;
  rows: PullRow[];
  filed: RequestRow[];
  deferred: PullRow[];
  /** Epic blockers: an Epic is not worked, so the chief decides. */
  skipped: string[];
  /** Blockers the mirror does not hold. */
  unknown: string[];
}

export const isPullRequest = (q: RequestRow): boolean => (q.evidence as { rule?: unknown } | null)?.rule === 'blocker-pull';

export function pull(ctx: Ctx, o: { max?: number; dryRun?: boolean } = {}): PullOut {
  const l = loadOrThrow(ctx);
  const standingId = `O-${ctx.release}-blocker-pull`;
  if (!l.operator.verified.some((x) => x.id === standingId && x.kind === 'blocker-pull')) {
    throw new Error(`release pull: ${ctx.release} has no standing blocker-pull record; the chief records it with release operator standing`);
  }
  const { issues } = readMirror(ctx.mirrorRoot);
  if (!issues) throw new Error('release pull: the Jira mirror is missing or unreadable, so no pull');
  const current = l.decl.current;
  const waiting = new Map<string, Set<string>>();
  for (const i of issues.values()) {
    if (!i.fixVersions.includes(current) || terminalOf(i) !== null || i.type === 'Epic' || i.type === 'Sub-task') continue;
    for (const b of i.blockedBy ?? []) waiting.set(b, (waiting.get(b) ?? new Set()).add(i.key));
  }
  const asked = [...latestRequests(l.requests).values()].filter((r) => isPullRequest(r));
  const out: PullOut = { current, rows: [], filed: [], deferred: [], skipped: [], unknown: [] };
  for (const key of [...waiting.keys()].sort()) {
    const snap = issues.get(key);
    if (!snap) {
      out.unknown.push(key);
      continue;
    }
    if (terminalOf(snap) !== null || snap.fixVersions.includes(current)) continue;
    if (snap.type === 'Epic') {
      out.skipped.push(key);
      continue;
    }
    const from_v = l.decl.versions.find((v) => snap.fixVersions.includes(v)) ?? null;
    if (asked.some((r) => r.key === key && r.from_v === from_v && r.to_v === current)) continue;
    out.rows.push({ key, blocks: [...(waiting.get(key) ?? [])].sort(), from_v, to_v: current });
  }
  const max = o.max ?? PULL_MAX;
  const todo = out.rows.slice(0, max);
  out.deferred = out.rows.slice(max);
  if (o.dryRun) return out;
  for (const r of todo) {
    out.filed.push(request(ctx, {
      verb: 'INTAKE', key: r.key, from_v: r.from_v, to_v: r.to_v, from: 'blocker-pull',
      why: `blocks ${r.blocks.join(', ')} in ${current}; standing rule ${standingId} (decision ${BLOCKER_PULL_DECISION})`,
      evidence: { blocks: r.blocks, rule: 'blocker-pull' },
    }));
  }
  return out;
}

export function rmFence(ctx: Ctx, l: Loaded): Lease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) may do this');
  if (ctx.env.HIMMEL_RM_RELEASE && ctx.env.HIMMEL_RM_RELEASE !== ctx.release) {
    throw new Error(`release: this session is bound to ${ctx.env.HIMMEL_RM_RELEASE}, not ${ctx.release}`);
  }
  const lease = readLease(ctx, l.k);
  if (!lease.owner_doc || lease.released) throw new Error(`release ${ctx.release}: no lease owner; run release lease acquire first`);
  if (ctx.env.HIMMEL_RM_DOC !== lease.owner_doc) {
    throw new Error(`release ${ctx.release}: ${ctx.env.HIMMEL_RM_DOC ?? '(no HIMMEL_RM_DOC)'} is not the lease owner (${lease.owner_doc}, epoch ${lease.epoch})`);
  }
  return lease;
}

export type RunLease = Lease & { owner_pid?: number; owner_host?: string };

export function ownerGone(lease: RunLease): boolean {
  if (!lease.owner_pid || lease.owner_host !== hostname()) return false;
  try {
    process.kill(lease.owner_pid, 0);
    return false;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ESRCH';
  }
}

export function leaseAcquire(ctx: Ctx, o: { expectEpoch: number; doc: string; session: string; pid?: number; reclaim?: boolean }): RunLease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release lease: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) holds the lease');
  if (!isAbsolute(o.doc) || ctx.env.HIMMEL_RM_DOC !== o.doc) throw new Error('release lease acquire: --doc must be this session\'s absolute HIMMEL_RM_DOC');
  return locked(ctx, (l) => {
    const cur: RunLease = readLease(ctx, l.k);
    if (cur.epoch !== o.expectEpoch) throw new Error(`release lease: epoch is ${cur.epoch}, expected ${o.expectEpoch}`);
    const takeoverRow = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), l.k).verified
      .some((x) => x.kind === 'takeover' && x.epoch === cur.epoch && x.doc === o.doc);
    if (cur.owner_doc && !cur.released && !takeoverRow && !(o.reclaim && ownerGone(cur))) {
      throw new Error(`release lease: held by ${cur.owner_doc} at epoch ${cur.epoch}; it needs a release or a chief takeover row`);
    }
    const next: RunLease = {
      release: ctx.release, epoch: cur.epoch + 1, owner_session: o.session, owner_doc: o.doc, acquired: ts(ctx),
      released: false, prev_epoch: cur.epoch, ...(o.pid ? { owner_pid: o.pid, owner_host: hostname() } : {}),
    };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

export function leaseRelease(ctx: Ctx): Lease {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const next = { ...lease, released: true };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

/** asks_operator is null when the mirror cannot say: it is unreadable, or does not hold the key. */
export interface RefusedAsk { key: string; ruling: string; req: string; reason: string; ground: string; remedy: string; asks_operator: boolean | null }

function requiredParent(q: RequestRow | undefined): string | null {
  const ev = (q?.evidence ?? {}) as { follow_up_of?: unknown; remainder?: unknown };
  return ev.remainder === true && typeof ev.follow_up_of === 'string' ? ev.follow_up_of : null;
}

function remedyOf(release: string, q: RequestRow, ruling: string, asksOperator: boolean | null, parent: string | null): string {
  const base = `jira release request ${release} --verb ${q.verb} --key ${q.key} --from ${vName(q.from_v)} --to ${vName(q.to_v)}${parent === null ? '' : ` --required-by ${parent}`}`;
  if (asksOperator !== false) return `${base} --why "<why>" --decision <n> --words "<the operator's exact words>"`;
  return `new facts: ${base} --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or if the refusal is right: jira release ack ${release} --ruling ${ruling} --reason "<why>"`;
}

const canon = (v: unknown): string => JSON.stringify(v, (_k, x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? Object.fromEntries(Object.entries(x as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : x));

function unchangedRefusal(l: Loaded, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow | undefined {
  const a = refusedAsks(l, null).find((x) => x.key === o.key);
  const first = a ? l.requests.verified.find((x) => x.req === a.req) : undefined;
  const now = first ? latestRequests(l.requests).get(first.req) : undefined;
  if (!first || !now || first.verb !== o.verb || first.from_v !== o.from_v || first.to_v !== o.to_v || first.why !== o.why || canon(now.evidence ?? {}) !== canon(o.evidence ?? {})) return undefined;
  return now;
}

export const factsOf = (i: IssueSnap | undefined): TicketFacts | null =>
  (i ? { labels: i.labels ?? [], priority: i.priority, open: terminalOf(i) === null } : null);

export function refusedAsks(l: Loaded, issues: Map<string, IssueSnap> | null): RefusedAsk[] {
  const firstOf = new Map<string, RequestRow>();
  for (const q of l.requests.verified) if (!firstOf.has(q.req)) firstOf.set(q.req, q);
  const now = latestOrEmpty(l.requests);
  const ruledAt = new Map<string, string>();
  const latest = new Map<string, RulingRow>();
  for (const r of l.rulings.verified) {
    if (!ruledAt.has(r.id)) ruledAt.set(r.id, r.ts);
    if (r.phase === 'receipted') latest.set(r.key, r);
  }
  const newest = (into: Map<string, number>, key: string, t: string) => into.set(key, Math.max(into.get(key) ?? -Infinity, Date.parse(t)));
  const asksOf = new Map<string, RequestRow[]>();
  for (const q of firstOf.values()) asksOf.set(q.key, [...(asksOf.get(q.key) ?? []), q]);
  const named = new Map<string, number>();
  for (const o of l.operator.verified) for (const k of o.keys ?? []) newest(named, k, o.ts);
  const acked = new Set(l.events.verified.filter((e) => e.kind === 'ack').map((e) => e.ruling));
  const out: RefusedAsk[] = [];
  for (const [key, r] of latest) {
    const q = firstOf.get(r.req);
    if (!q || q.from_v !== null || q.to_v === null) continue;
    if (r.outcome !== 'BACKLOG' && !(r.verb === 'REVERSION' && r.outcome === 'KEEP')) continue;
    const since = Date.parse(ruledAt.get(r.id) ?? r.ts);
    const askedAgain = (asksOf.get(key) ?? []).some((x) => x.req !== r.req && Date.parse(x.ts) > since && !now.get(x.req)?.state.startsWith('withdrawn:'));
    if (acked.has(r.id) || askedAgain || (named.get(key) ?? -Infinity) > since) continue;
    const issue = issues?.get(key);
    if (issue && terminalOf(issue) !== null) continue;
    const asks = issue ? asksOperator(factsOf(issue)) : null;
    out.push({ key, ruling: r.id, req: r.req, reason: r.reason, ground: r.ground, remedy: remedyOf(l.decl.release, q, r.id, asks, requiredParent(now.get(r.req))), asks_operator: asks });
  }
  return out.sort((a, b) => a.key.localeCompare(b.key, 'en', { numeric: true }));
}

export function latestOrEmpty(requests: Chain<RequestRow>): Map<string, RequestRow> {
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}
