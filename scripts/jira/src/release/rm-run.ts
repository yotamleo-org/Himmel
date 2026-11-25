import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { appendChain, readChain, type Chain } from './ledger.js';
import { effectOn, recordOf, terminalOf, type ReleaseState } from './reducer.js';
import { judgeOperatorRows } from './judge-input.js';
import { currentFrozen } from './filing-rules.js';
import type { Authority, IssueSnap, Op, OperatorRow, RequestRow, RulingRow, Verb } from './types.js';
import { BLOCKER_PULL_DECISION, DELIVERED_DECISION, isRepair } from './operator-acts.js';
import { fileRequest, isPullRequest, leaseAcquire, leaseRelease, ownerGone, requiredParentOf, rmFence, type RunLease } from './request-queue.js';
import { apply, claim, type DoorJiraPort, mergeEvidenceFor, rule } from './rule-apply.js';
import { type Ctx, f, latestRequests, type Loaded, loadOrThrow, locked, readLease, readMirror, reduceLoaded, ts } from './engine-core.js';

export interface HoldDecision {
  req: string;
  outcome: 'HOLD';
  reason: string;
}

export interface RuledDecision {
  req: string;
  outcome: string;
  op: Op['kind'];
  from: string | null;
  to: string | null;
  sector: string | null;
  ground: string;
  reason: string;
  supersedes?: string[];
  authority?: Authority['kind'];
  ref?: string | null;
  blocks?: string[];
  delivered?: string;
  queue?: QueuedRequest;
}

export interface QueuedRequest { verb: Verb; from_v: string | null; to_v: string | null; operator_record: string }

export interface RefuseDecision {
  req: string;
  outcome: 'REFUSE';
  ground: string;
  reason: string;
  queue?: QueuedRequest;
}

export type Decision = HoldDecision | RuledDecision | RefuseDecision;

function pullDecision(now: Loaded, mirror: ReturnType<typeof readMirror>, q: RequestRow): RuledDecision | { noop: string } {
  const release = now.decl.release;
  const id = `O-${release}-blocker-pull`;
  if (!now.operator.verified.some((x) => x.id === id && x.kind === 'blocker-pull')) throw new Error(`blocker-pull: ${id} is not recorded`);
  const given = (q.evidence as { blocks?: unknown } | null)?.blocks;
  const blocks = Array.isArray(given) ? given.filter((k): k is string => typeof k === 'string') : [];
  if (!blocks.length || q.to_v !== now.decl.current) throw new Error(`blocker-pull: ${q.req} does not name the tickets it unblocks in ${now.decl.current}`);
  const snap = mirror.issues?.get(q.key);
  if (snap?.fixVersions.includes(q.to_v)) return { noop: `${q.key} is already in ${q.to_v}; nothing to pull` };
  const op: Op = { kind: q.from_v ? 'move' : 'add', from_v: q.from_v, to_v: q.to_v };
  return {
    req: q.req, outcome: 'ADMIT', op: op.kind, from: q.from_v, to: q.to_v, sector: snap?.sector ?? null, ground: 'blocker-pull',
    reason: `blocks ${blocks.join(', ')} in ${now.decl.current}; standing rule ${id} (decision ${BLOCKER_PULL_DECISION})`,
    supersedes: supersedesOf(now, mirror, q.key, op), authority: 'operator', ref: id, blocks,
  };
}

function supersedesOf(now: Loaded, mirror: ReturnType<typeof readMirror>, key: string, op: Op): string[] {
  const s = reduceLoaded(now, mirror);
  return [...new Set(now.decl.versions.filter((v) => effectOn(op, v)).flatMap((v) => recordOf(s, key, v)?.ruling ?? []))];
}

function deliveredDecision(now: Loaded, mirror: ReturnType<typeof readMirror>, q: RequestRow, lookup?: (key: string) => number | undefined): RuledDecision | null {
  const id = `O-${now.decl.release}-delivered-follows-merge`;
  if (!now.operator.verified.some((x) => x.id === id && x.kind === 'delivered-follows-merge')) return null;
  const { current, versions } = now.decl;
  if (q.verb !== 'INTAKE' || q.to_v !== current) return null;
  const snap = mirror.issues?.get(q.key);
  if (!snap || snap.fixVersions.includes(current)) return null;
  const t = terminalOf(snap);
  if (t !== 'Done' && t !== 'Duplicate') return null;
  const from = versions.find((v) => v !== current && snap.fixVersions.includes(v));
  if (!from || q.from_v !== from) return null;
  const evidence = mergeEvidenceFor(q, t, lookup);
  if (!evidence) return null;
  const op: Op = { kind: 'move', from_v: from, to_v: current };
  return {
    req: q.req, outcome: 'ADMIT', op: op.kind, from, to: current, sector: snap.sector ?? null, ground: 'delivered-follows-merge',
    reason: `${q.key} is ${t} with ${evidence}; merged work follows its merge version ${current}; standing rule ${id} (decision ${DELIVERED_DECISION})`,
    supersedes: supersedesOf(now, mirror, q.key, op), authority: 'operator', ref: id, delivered: evidence,
  };
}

const isHold = (d: Decision): d is HoldDecision => d.outcome === 'HOLD';
const isRefuse = (d: Decision): d is RefuseDecision => d.outcome === 'REFUSE';

const authorityOf = (d: RuledDecision): Authority =>
  ({ kind: d.authority ?? 'rm', ref: d.ref ?? null, ...(d.blocks ? { blocks: d.blocks } : {}), ...(d.delivered ? { delivered: d.delivered } : {}) });

function deliveredDecisions(now: Loaded, mirror: ReturnType<typeof readMirror>, claimed: RequestRow[], lookup?: (key: string) => number | undefined): Map<string, RuledDecision> {
  const out = new Map<string, RuledDecision>();
  for (const q of claimed) {
    const got = isPullRequest(q) ? null : deliveredDecision(now, mirror, q, lookup);
    if (got) out.set(q.req, got);
  }
  return out;
}

export interface JudgeInput {
  release: string;
  current: string;
  versions: string[];
  requests: RequestRow[];
  records: ReleaseState['records'];
  operator: OperatorRow[];
  rulings: RulingRow[];
  issues: IssueSnap[];
  ruled_at?: Record<string, string>;
  required_parent?: Record<string, string>;
  /** True when current is frozen (a verified freeze row holds it); a caller that leaves it out is read as frozen. */
  frozen?: boolean;
}

export type Judge = (input: JudgeInput, opts?: { signal?: AbortSignal }) => Promise<Decision[]>;

export class JudgeReplyError extends Error {
  constructor(message: string, readonly raw: string) {
    super(message);
    this.name = 'JudgeReplyError';
  }
}

function unfinishedRulings(rulings: Chain<RulingRow>): string[] {
  const last = new Map<string, RulingRow>();
  for (const r of rulings.verified) last.set(r.id, r);
  return [...last.values()].filter((r) => r.phase === 'intent' || r.phase === 'applied').map((r) => r.id);
}

export const LIVE_LOOKUP_MS = 15_000;
export const LIVE_POOL_MS = 60_000;
export const LIVE_READS = 8;

function overlay(mirrored: IssueSnap | undefined, live: IssueSnap): IssueSnap {
  if (!mirrored) return live;
  const out: Record<string, unknown> = { ...mirrored };
  for (const [k, v] of Object.entries(live)) if (v !== null && v !== undefined && v !== '') out[k] = v;
  return out as unknown as IssueSnap;
}

async function liveIssues(ctx: Ctx, keys: string[], mirrored: Map<string, IssueSnap> | null): Promise<{ issues: IssueSnap[]; fallback: Set<string> }> {
  const jira = ctx.jira as DoorJiraPort;
  const fallback = new Set<string>();
  let open = 0;
  let first: number | undefined;
  const waiters: Array<() => void> = [];
  const left = () => (first === undefined ? LIVE_POOL_MS : LIVE_POOL_MS - (Date.now() - first));
  const slot = async (): Promise<boolean> => {
    for (;;) {
      if (open < LIVE_READS) break;
      if (left() <= 0) return false;
      const freed = await new Promise<boolean>((resolve) => {
        const wake = () => { clearTimeout(timer); resolve(true); };
        const timer = setTimeout(() => { waiters.splice(waiters.indexOf(wake), 1); resolve(false); }, left());
        waiters.push(wake);
      });
      if (!freed) return false;
    }
    if (left() <= 0) return false;
    first ??= Date.now();
    open++;
    return true;
  };
  const one = async (key: string): Promise<IssueSnap | undefined> => {
    const m = mirrored?.get(key);
    if (!jira.issue) return m;
    if (!(await slot())) { fallback.add(key); return m; }
    const stop = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const read = Promise.resolve().then(() => jira.issue!(key, { signal: stop.signal })).finally(() => { open--; waiters.shift()?.(); });
    try {
      const live = await Promise.race([read, new Promise<undefined>((resolve) => { timer = setTimeout(() => { stop.abort(); resolve(undefined); }, LIVE_LOOKUP_MS); })]);
      if (live === undefined) { fallback.add(key); return m; }
      return live ? overlay(m, live) : m;
    } catch {
      fallback.add(key);
      return m;
    } finally {
      clearTimeout(timer);
      read.catch(() => undefined);
    }
  };
  const got = await Promise.all(keys.map(one));
  return { issues: got.flatMap((i) => i ?? []), fallback };
}

function unclaim(ctx: Ctx, req: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
  });
}

function hold(ctx: Ctx, req: string, reason: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'held', reason });
  });
}

function refuse(ctx: Ctx, req: string, reason: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: `refused:${lease.epoch}`, reason });
  });
}

function returnClaims(ctx: Ctx): number {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const mine = [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()].filter((r) => r.state === `claimed:${lease.epoch}`);
    for (const r of mine) {
      const { prev: _p, mac: _m, ...rest } = r;
      appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
    }
    return mine.length;
  });
}

const stopReason = (signal: AbortSignal): Error => (signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason)));

function linkStop(signal?: AbortSignal): { stop: AbortController; unlink: () => void } {
  const stop = new AbortController();
  const onStop = () => stop.abort(signal?.reason);
  if (signal?.aborted) onStop();
  else signal?.addEventListener('abort', onStop, { once: true });
  return { stop, unlink: () => signal?.removeEventListener('abort', onStop) };
}

function reclaimNote(prior: RunLease): string[] {
  if (!prior.owner_doc || prior.released || !ownerGone(prior)) return [];
  return [`RECLAIMED lease epoch ${prior.epoch}: rm-run pid ${prior.owner_pid} on ${prior.owner_host} is gone`];
}

function failNote(ctx: Ctx, failed: Error, lines: string[]): void {
  lines.push(`FAILED: ${failed.message}`);
  try {
    const n = returnClaims(ctx);
    if (n) lines.push(`RETURNED ${n} claimed requests to open`);
  } catch (e) {
    lines.push(`PENDING claims: ${(e as Error).message}`);
  }
}

export const JUDGE_SETTLE_MS = 6000;

function startDeadline(stop: AbortController, ms: number | undefined): () => void {
  if (ms === undefined) return () => undefined;
  const timer = setTimeout(() => stop.abort(new Error(`rm-run: the judge did not answer within ${ms / 1000}s; nothing ruled`)), ms);
  return () => clearTimeout(timer);
}

async function settleWithin(answer: Promise<unknown>, ms: number): Promise<void> {
  let grace: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([answer.then(() => undefined, () => undefined), new Promise((r) => { grace = setTimeout(r, ms); })]);
  clearTimeout(grace);
}

function answerBeforeStop<T>(answer: Promise<T>, stop: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const stopped = () => void settleWithin(answer, JUDGE_SETTLE_MS).then(() => reject(stopReason(stop)));
    if (stop.aborted) return stopped();
    stop.addEventListener('abort', stopped, { once: true });
    answer.then((v) => { if (!stop.aborted) resolve(v); }, (e) => { if (!stop.aborted) reject(e); });
  });
}

async function judged<T>(answer: Promise<T>, stop: AbortController, ms: number | undefined): Promise<T> {
  const clearDeadline = startDeadline(stop, ms);
  try {
    return await answerBeforeStop(answer, stop.signal);
  } finally {
    clearDeadline();
  }
}

export interface RmRunOptions {
  doc?: string;
  session?: string;
  /** The caller's stop (the CLI wires SIGTERM, SIGINT and SIGHUP to it): the run fails cleanly at the next step. */
  signal?: AbortSignal;
  /** How long the judge may take before the run fails (default: no deadline of the run's own). */
  judgeTimeoutMs?: number;
  /** The process the lease names (default this one), so the next run can free the lease if it dies. */
  pid?: number;
  /** Called once the judge answers or fails: how many requests it was asked and how long it took (decision 815). */
  onJudge?: (requests: number, ms: number) => void;
}

export function rmRunSummary(release: string, lines: string[]): string | null {
  const n = lines.filter((x) => /^REFUSED /.test(x)).length;
  return n ? `RM-RUN ${release} summary: ${n} refused` : null;
}

function queueRequest(ctx: Ctx, q: RequestRow, queue: QueuedRequest): string {
  return locked(ctx, (l) => {
    rmFence(ctx, l);
    return fileRequest(ctx, l, {
      from: 'rm', verb: queue.verb, key: q.key, from_v: queue.from_v, to_v: queue.to_v,
      why: `the operator's ${queue.operator_record} still owes this ${queue.verb}`, evidence: { operator_record: queue.operator_record },
    }).req;
  });
}

export async function rmRun(ctx: Ctx, judge: Judge, o: RmRunOptions = {}): Promise<string[]> {
  const l = loadOrThrow(ctx);
  const pending = [...latestRequests(l.requests).values()].filter((r) => r.state === 'open' || r.state.startsWith('claimed:'));
  if (!pending.length && !unfinishedRulings(l.rulings).length) return [`RM-RUN ${ctx.release}: nothing pending`];

  const doc = o.doc ?? join(ctx.dir, 'rm-runs', `run-${ts(ctx).replace(/[:.]/g, '-')}.md`);
  const rctx: Ctx = { ...ctx, env: { ...ctx.env, HIMMEL_RELEASE_MANAGER: '1', HIMMEL_RM_DOC: doc, HIMMEL_RM_RELEASE: ctx.release } };
  const prior: RunLease = readLease(ctx, l.k);
  const lease = leaseAcquire(rctx, { expectEpoch: prior.epoch, doc, session: o.session ?? 'rm-run', pid: o.pid ?? process.pid, reclaim: true });
  const lines: string[] = reclaimNote(prior);
  const { stop, unlink } = linkStop(o.signal);
  const halt = () => { if (stop.signal.aborted) throw stopReason(stop.signal); };
  let failed: Error | undefined;
  let refused: JudgeReplyError | undefined;
  const queue = (q: RequestRow, d: { queue?: QueuedRequest }) => {
    if (!d.queue) return;
    try {
      lines.push(`QUEUED ${queueRequest(rctx, q, d.queue)}: ${d.queue.verb} ${q.key} for ${d.queue.operator_record}`);
    } catch (e) {
      lines.push(`PENDING queue ${q.req}: ${(e as Error).message}`);
    }
  };
  try {
    halt();
    for (const id of unfinishedRulings(loadOrThrow(ctx).rulings)) {
      halt();
      try {
        const got = await apply(rctx, id);
        lines.push(got.line);
        if (got.note) lines.push(`PENDING ${id}: ${got.note}`);
      } catch (e) {
        lines.push(`PENDING ${id}: ${(e as Error).message}`);
      }
    }
    const seen = new Set<string>();
    const claimed: RequestRow[] = [];
    for (const q of claim(rctx)) {
      if (seen.has(q.key)) unclaim(rctx, q.req);
      else { seen.add(q.key); claimed.push(q); }
    }
    if (claimed.length) {
      const now = loadOrThrow(ctx);
      const mirror = readMirror(ctx.mirrorRoot);
      const delivered = deliveredDecisions(now, mirror, claimed, ctx.deliveredPr);
      const asked = claimed.filter((q) => !isPullRequest(q) && !delivered.has(q.req));
      const history = now.requests.verified;
      const required_parent = requiredParentOf(history);
      const keys = new Set(asked.map((r) => r.key));
      const followUpOf = (q: RequestRow): string[] => {
        const p = (q.evidence && typeof q.evidence === 'object' ? (q.evidence as { follow_up_of?: unknown }).follow_up_of : undefined);
        return typeof p === 'string' && p ? [p] : [];
      };
      const parents = [...keys].flatMap((k) => required_parent[k] ? [required_parent[k]] : []).concat(asked.flatMap(followUpOf));
      const ruled_at: Record<string, string> = {};
      const newest = new Map<string, RulingRow>();
      for (const r of now.rulings.verified) {
        ruled_at[r.id] ??= r.ts;
        newest.set(r.id, r);
      }
      const settled = [...newest.values()].filter((r) => r.phase === 'applied' || r.phase === 'receipted');
      const receipted = settled.filter((r) => r.phase === 'receipted');
      const live = await liveIssues(ctx, [...new Set([...keys, ...parents])], mirror.issues);
      const issues = live.issues;
      halt();
      let decisions: Decision[];
      const judgeStart = Date.now();
      try {
        decisions = !asked.length ? [] : await judged(judge({
          release: ctx.release, current: now.decl.current, versions: now.decl.versions, requests: asked,
          records: reduceLoaded(now, mirror).records.filter((r) => keys.has(r.key)),
          operator: judgeOperatorRows(ctx.release, now.operator.verified, asked, issues, receipted),
          rulings: [...new Set([...settled.filter((r) => keys.has(r.key)), ...receipted.slice(-40)])],
          issues, ruled_at, required_parent, frozen: currentFrozen(now),
        }, { signal: stop.signal }), stop, o.judgeTimeoutMs);
      } catch (e) {
        if (e instanceof JudgeReplyError) {
          refused = e;
          lines.push(`JUDGE-REFUSED: ${e.message}`);
        }
        throw e;
      } finally {
        if (asked.length) o.onJudge?.(asked.length, Date.now() - judgeStart);
      }
      for (const q of claimed) {
        halt();
        let id: string;
        let d = delivered.get(q.req) ?? decisions.find((x) => x?.req === q.req);
        const pulled = isPullRequest(q);
        const facts = live.fallback.has(q.key) ? ' (mirror facts)' : '';
        try {
          if (pulled) {
            const got = pullDecision(now, mirror, q);
            if ('noop' in got) {
              lines.push(`NOOP ${q.req}: ${got.noop}`);
              refuse(rctx, q.req, got.noop);
              continue;
            }
            d = got;
          }
          if (!d) throw new Error('the judge returned no decision');
          if (isRefuse(d)) {
            lines.push(`REFUSED ${q.req}: ${d.ground}: ${d.reason}${facts}`);
            refuse(rctx, q.req, `${d.ground}: ${d.reason}${facts}`);
            queue(q, d);
            continue;
          }
          if (isHold(d)) {
            lines.push(`HELD ${q.req}: ${d.reason}`);
            if (isRepair(q)) hold(rctx, q.req, d.reason);
            continue;
          }
          id = rule(rctx, {
            req: q.req, outcome: d.outcome, op: { kind: d.op, from_v: d.from ?? null, to_v: d.to ?? null }, sector: d.sector ?? '',
            ground: d.ground ?? '', reason: `${d.reason ?? ''}${facts}`, supersedes: d.supersedes ?? [],
            authority: authorityOf(d),
          }).id;
        } catch (e) {
          lines.push(`REFUSED ${q.req}: ${(e as Error).message}`);
          if (d || pulled) refuse(rctx, q.req, (e as Error).message);
          continue;
        }
        queue(q, d);
        try {
          const got = await apply(rctx, id);
          lines.push(got.line);
          if (got.note) lines.push(`PENDING ${id}: ${got.note}`);
        } catch (e) {
          lines.push(`PENDING ${id}: ${(e as Error).message}`);
        }
      }
    }
  } catch (e) {
    failed = e as Error;
    throw e;
  } finally {
    unlink();
    if (failed) failNote(rctx, failed, lines);
    try {
      leaseRelease(rctx);
    } catch (e) {
      lines.push(`PENDING lease: ${(e as Error).message}`);
    }
    try {
      mkdirSync(dirname(doc), { recursive: true });
      const raw = refused ? `\n## Raw judge reply\n\n~~~~\n${refused.raw}\n~~~~\n` : '';
      writeFileSync(doc, `# rm-run ${ctx.release} epoch ${lease.epoch}\n\n${lines.map((x) => `- ${x}`).join('\n')}\n${raw}`);
    } catch (e) {
      lines.push(`PENDING run record: ${(e as Error).message}`);
    }
    if (failed) Object.assign(failed, { runLines: lines, runDoc: doc } satisfies RunRecord);
  }
  return lines;
}

/** What a failed rmRun's error carries: the lines it wrote and its run doc, so the caller can print them. */
export interface RunRecord { runLines: string[]; runDoc: string }
