import { appendChain, type Chain } from './ledger.js';
import { type Admission } from '../commands/admissions-ledger.js';
import { terminalOf, unknownState, type ReleaseState } from './reducer.js';
import { asksOperator } from './operator-work.js';
import type { EventRow, IssueSnap, Lease, OperatorRow, RequestRow, RulingRow } from './types.js';
import { factsOf, latestOrEmpty, ownerGone, type RefusedAsk, refusedAsks } from './request-queue.js';
import { boundAdd, boundRemoval, holdsBoth, keyNewestDecision, landed, newerElsewhere, observedOf, reached, repairOf, routeOf, untouched, type VoidRow } from './rule-apply.js';
import { admissionsOrNull, type Ctx, f, load, type Loaded, loadOrThrow, locked, operatorFence, readLease, readMirror, reduceLoaded, ts, vName } from './engine-core.js';

export interface StateOut extends ReleaseState {
  /** Per version: the keys of today's (UTC) operator decisions that add or move into it. */
  admissions_today: Record<string, number>;
  /** owner_gone is present (true) only for a held lease whose recorded owner pid is absent on this host: the proof rm-run's own reclaim uses. */
  lease: (Omit<Lease, 'mac'> & { owner_pid?: number; owner_host?: string; owner_gone?: true }) | null;
  requests: { open: string[]; claimed: string[]; /** ts of the oldest open request, null with none. */ oldest_open: string | null; pending_keys: string[] };
  current: string | null;
  heads: { rulings: string; operator: string; events: string; requests: string; mirror: string | null };
  priority_review: PriorityReview[];
  chief_placements: ChiefPlacement[];
  asks_apart: AskApart[];
  refused_asks: RefusedAsk[];
  /** Every verified `words: 1` O- row: the records a hold line may cite. */
  words_records: WordsRecord[];
  /** Open mirror keys labelled operator-directed or of priority High or Highest. */
  asks_operator_keys: string[];
  /** Rulings whose newest phase is intent or applied: the Jira write, the admissions row or the receipt may still be owed. A normal rm-run replays each. */
  unfinished_rulings: UnfinishedRuling[];
  /** Required-remainder children (request evidence `remainder: true`) of an open current-version parent that are open outside the version. A read of existing evidence: it admits nothing. */
  remainder_conflicts: RemainderConflict[];
}

export interface PriorityReview { key: string; ruling: string; ground: string }
export interface ChiefPlacement { key: string; ruling: string; reason: string }
export interface AskApart { key: string; ruling: string; version: string; parent: string; parent_version: string }

export interface UnfinishedRuling {
  ruling: string; req: string; key: string; phase: 'intent' | 'applied' | 'void'; op: string;
  /** replay: a normal rm-run finishes it. blocked: a move the key's mirror shows in neither end state with no journalled proof it is this ruling's own, or with an operator record newer than the ruling that puts the key elsewhere; the chief repairs it by hand. */
  status: 'replay' | 'blocked'; owner: 'release-manager' | 'chief'; next: string;
  /** What the mirror shows of a blocked move; null otherwise. */
  observed: string | null;
}

/** A current-version parent whose recorded remainder sits outside the version: the contradiction, who owns it and the next command. */
export interface RemainderConflict {
  parent: string; child: string; req: string; ruling: string | null;
  phase: 'open' | 'claimed' | 'held' | 'refused' | 'ruled'; owner: 'chief' | 'release-manager'; next: string;
  /** What the mirror cannot say (the parent's or the child's state, or anything when it is unreadable); null when both are read. */
  unknown: 'parent' | 'child' | 'mirror' | null;
}

export interface WordsRecord { id: string; decision: string | null; keys: string[]; op: string | null; verbatim: string }

function wordsRecords(l: Loaded): WordsRecord[] {
  return l.operator.verified.filter((o) => o.words === 1)
    .map((o) => ({ id: o.id, decision: o.decision, keys: o.keys ?? [], op: o.op ?? null, verbatim: o.verbatim ?? '' }));
}

const asksOperatorKeys = (issues: Map<string, IssueSnap> | null): string[] =>
  [...(issues?.values() ?? [])].filter((i) => terminalOf(i) === null && asksOperator(factsOf(i))).map((i) => i.key).sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));

export function ack(ctx: Ctx, o: { ruling: string; reason: string }): EventRow {
  operatorFence(ctx);
  if (!o.reason.trim()) throw new Error('release ack: --reason says why the refusal is right');
  return locked(ctx, (l) => {
    if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
    const { issues } = readMirror(ctx.mirrorRoot);
    if (!issues) throw new Error('release ack: the Jira mirror is unreadable, so whether the key is operator-asked is unknown; sync it first');
    const a = refusedAsks(l, issues).find((x) => x.ruling === o.ruling);
    if (!a) throw new Error(`release ack: ${o.ruling} is no open refused ask of ${ctx.release}`);
    if (a.asks_operator === null) throw new Error(`release ack: ${a.key} is not in the Jira mirror, so whether it is operator-asked is unknown; sync it first`);
    if (a.asks_operator) {
      throw new Error(`release ack: ${a.key} is operator-asked (labelled operator-directed, or High or Highest); its refusal ends only by a new request, an O- record of the operator's words, or the ticket closing`);
    }
    return appendChain<EventRow>(f(ctx, 'events.jsonl'), l.k, { ts: ts(ctx), kind: 'ack', key: a.key, from: null, to: null, ruling: a.ruling, reason: o.reason.trim() });
  });
}

type ReviewList = 'priority' | 'chief' | 'apart';
const PRIORITY_GROUND = /^door:(serious:.+|mild|mild-no-next|rest-of:.+|operator-ask|operator-ask:.+|started|operator-undeclared:.+)$/;
const APART_GROUND = /^door:(?:operator-ask-apart|operator-apart):(.+)@([^@]+)$/;
const listOf = (ground: string): ReviewList | null =>
  (ground === 'door:chief' ? 'chief' : APART_GROUND.test(ground) ? 'apart' : PRIORITY_GROUND.test(ground) ? 'priority' : null);

interface ReviewLists { priority_review: PriorityReview[]; chief_placements: ChiefPlacement[]; asks_apart: AskApart[]; listed: Map<string, string> }

function reviewLists(l: Loaded): ReviewLists {
  const receipts: RulingRow[] = [];
  const order = new Map<string, number>();
  for (const r of l.rulings.verified) {
    if (r.phase !== 'receipted' || order.has(r.id) || listOf(r.ground) === null) continue;
    order.set(r.id, receipts.length);
    receipts.push(r);
  }
  const reviews = l.events.verified.filter((e) => e.kind === 'reviewed');
  const covered = (r: RulingRow): boolean => reviews.some((e) => {
    if (e.through === undefined) return e.ruling === r.id;
    const upTo = order.get(e.through);
    return upTo !== undefined && listOf(receipts[upTo].ground) === listOf(r.ground) && order.get(r.id)! <= upTo;
  });
  const out: ReviewLists = { priority_review: [], chief_placements: [], asks_apart: [], listed: new Map() };
  const tuples = new Map<string, RulingRow[]>();
  for (const r of receipts) {
    const m = APART_GROUND.exec(r.ground);
    if (m) {
      const t = JSON.stringify([r.key, r.op.to_v ?? r.op.from_v ?? 'backlog', m[1], m[2]]);
      tuples.set(t, [...(tuples.get(t) ?? []), r]);
    } else if (!covered(r)) {
      if (listOf(r.ground) === 'chief') out.chief_placements.push({ key: r.key, ruling: r.id, reason: r.reason });
      else out.priority_review.push({ key: r.key, ruling: r.id, ground: r.ground });
      out.listed.set(r.id, r.key);
    }
  }
  const open = [...tuples].filter(([, rs]) => !rs.some(covered)).sort(([, a], [, b]) => order.get(a.at(-1)!.id)! - order.get(b.at(-1)!.id)!);
  for (const [t, rs] of open) {
    const [key, version, parent, parentVersion] = JSON.parse(t) as string[];
    out.asks_apart.push({ key, ruling: rs.at(-1)!.id, version, parent, parent_version: parentVersion });
    for (const r of rs) out.listed.set(r.id, r.key);
  }
  return out;
}

export function reviewed(ctx: Ctx, o: { ruling?: string; through?: string; reason: string }): EventRow {
  operatorFence(ctx);
  if (!o.reason.trim()) throw new Error('release reviewed: --reason says what was checked or relayed');
  if ((o.ruling === undefined) === (o.through === undefined)) throw new Error('release reviewed: name exactly one of --ruling and --through');
  const id = (o.ruling ?? o.through)!;
  return locked(ctx, (l) => {
    if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
    const key = reviewLists(l).listed.get(id);
    if (key === undefined) throw new Error(`release reviewed: ${id} is no listed entry of ${ctx.release}'s priority review, chief placements or asks apart`);
    return appendChain<EventRow>(f(ctx, 'events.jsonl'), l.k, {
      ts: ts(ctx), kind: 'reviewed', key, from: null, to: null, ruling: id, ...(o.through === undefined ? {} : { through: id }), reason: o.reason.trim(),
    });
  });
}

function admissionsToday(ctx: Ctx, l: Loaded): Record<string, number> {
  const today = ts(ctx).slice(0, 10);
  const counts: Record<string, number> = Object.fromEntries(l.decl.versions.map((v) => [v, 0]));
  for (const o of l.operator.verified) {
    if (o.kind !== 'decision' || (o.op !== 'add' && o.op !== 'move') || !o.to_v || !(o.to_v in counts) || !o.ts.startsWith(today)) continue;
    counts[o.to_v] += o.keys?.length ?? 0;
  }
  return counts;
}

export function state(ctx: Ctx): StateOut {
  const l = load(ctx);
  const empty = {
    admissions_today: {}, lease: null, requests: { open: [], claimed: [], oldest_open: null, pending_keys: [] }, current: null,
    heads: { rulings: '', operator: '', events: '', requests: '', mirror: null }, priority_review: [], chief_placements: [], asks_apart: [],
    refused_asks: [], words_records: [], asks_operator_keys: [], unfinished_rulings: [], remainder_conflicts: [],
  };
  if ('unknown' in l) return { ...unknownState(ctx.release, l.unknown), ...empty };
  const mirror = readMirror(ctx.mirrorRoot);
  const s = reduceLoaded(l, mirror);
  let lease: Lease | null = null;
  try {
    lease = readLease(ctx, l.k);
  } catch (e) {
    s.integrity.push((e as Error).message);
  }
  const open: string[] = [];
  const claimed: string[] = [];
  let oldestOpen: string | null = null;
  const pendingKeys = new Set<string>();
  if (l.requests.bad.length) s.integrity.push(...l.requests.bad.map((b) => `requests.jsonl ${b}`));
  for (const r of latestOrEmpty(l.requests).values()) {
    if (r.state === 'open') {
      open.push(r.req);
      pendingKeys.add(r.key);
      if (oldestOpen === null || r.ts < oldestOpen) oldestOpen = r.ts;
    } else if (r.state.startsWith('claimed:')) {
      claimed.push(r.req);
      pendingKeys.add(r.key);
    }
  }
  const { listed: _listed, ...lists } = reviewLists(l);
  const { mac: _m, ...leaseOut } = lease ?? ({} as Lease);
  const unfinished = unfinishedOf(l.rulings, l.events.verified, l.operator.verified, ctx, mirror.issues, lease, l.decl.versions);
  return {
    ...s,
    status: lease ? s.status : 'UNKNOWN',
    admissions_today: admissionsToday(ctx, l),
    lease: lease ? { ...leaseOut, ...(!lease.released && ownerGone(lease) ? { owner_gone: true as const } : {}) } : null,
    requests: { open, claimed, oldest_open: oldestOpen, pending_keys: [...pendingKeys].sort((a, b) => a.localeCompare(b, 'en', { numeric: true })) },
    current: l.decl.current,
    heads: { rulings: l.rulings.head, operator: l.operator.head, events: l.events.head, requests: l.requests.head, mirror: mirror.sync },
    ...lists,
    refused_asks: refusedAsks(l, mirror.issues),
    words_records: wordsRecords(l),
    asks_operator_keys: asksOperatorKeys(mirror.issues),
    unfinished_rulings: unfinished,
    remainder_conflicts: remainderConflicts(l, mirror.issues, ctx.release, unfinished),
  };
}

function remainderConflicts(l: Loaded, issues: Map<string, IssueSnap> | null, release: string, unfinished: UnfinishedRuling[]): RemainderConflict[] {
  const current = l.decl.current;
  const pending = new Map(unfinished.map((r) => [r.ruling, r]));
  const rulingOf = new Map<string, RulingRow>();
  for (const r of l.rulings.verified) rulingOf.set(r.req, r);
  const newest = new Map<string, RequestRow>();
  for (const q of [...latestOrEmpty(l.requests).values()].sort((a, b) => a.ts.localeCompare(b.ts))) {
    if (q.verb === 'INTAKE' && q.to_v === current && !q.state.startsWith('withdrawn:')) newest.set(q.key, q);
  }
  const out: RemainderConflict[] = [];
  for (const q of newest.values()) {
    const ev = (q.evidence ?? {}) as { follow_up_of?: unknown; remainder?: unknown };
    if (ev.remainder !== true || typeof ev.follow_up_of !== 'string') continue;
    const parentKey = ev.follow_up_of;
    const parent = issues?.get(parentKey);
    const child = issues?.get(q.key);
    if (issues && parent && (terminalOf(parent) !== null || !parent.fixVersions.includes(current))) continue;
    if (issues && child && (terminalOf(child) !== null || child.fixVersions.includes(current))) continue;
    const ruling = rulingOf.get(q.req) ?? null;
    const base = { parent: parentKey, child: q.key, req: q.req, ruling: ruling?.id ?? null };
    const remedy = conflictRemedy(release, q, parentKey, child ? asksOperator(factsOf(child)) : null);
    const unknown = !issues ? 'mirror' : !parent ? 'parent' : !child ? 'child' : null;
    const rm = (phase: 'open' | 'claimed' | 'ruled'): RemainderConflict => ({ ...base, phase, owner: 'release-manager', next: 'jira release rm-run ' + release, unknown });
    const chief = (phase: RemainderConflict['phase'], next: string): RemainderConflict => ({ ...base, phase, owner: 'chief', next, unknown });
    const unread = unknown === null ? '' : (unknown === 'mirror' ? 'both tickets' : unknown === 'parent' ? parentKey : q.key);
    const refresh = 'the Jira mirror cannot say ' + unread + ': run `jira mirror`, then read `jira release state ' + release + ' --json` again';
    const closed = q.state === 'held' ? 'held' : q.state.startsWith('ruled:') && ruling?.outcome === 'ADMIT' ? 'ruled' : 'refused';
    if (q.state === 'open') out.push(rm('open'));
    else if (q.state.startsWith('claimed:')) out.push(rm('claimed'));
    else if (q.state.startsWith('ruled:') && ruling && (ruling.phase === 'intent' || ruling.phase === 'applied')) {
      const action = pending.get(ruling.id);
      out.push(action?.status === 'blocked' ? chief('ruled', action.next) : rm('ruled'));
    }
    else if (unknown !== null) out.push(chief(closed, refresh));
    else if (q.state.startsWith('ruled:') && ruling?.outcome === 'ADMIT') {
      out.push(chief('ruled', 'the ruling admitted ' + q.key + ' but the mirror still shows it outside ' + current + ': run `jira mirror`; if it still sits outside, ' + remedy));
    } else out.push(chief(q.state === 'held' ? 'held' : 'refused', remedy));
  }
  return out.sort((a, b) => a.child.localeCompare(b.child, 'en', { numeric: true }));
}

function conflictRemedy(release: string, q: RequestRow, parent: string, asksOperator: boolean | null): string {
  const base = `jira release request ${release} --verb ${q.verb} --key ${q.key} --from ${vName(q.from_v)} --to ${vName(q.to_v)} --required-by ${parent}`;
  if (asksOperator !== false) return `${base} --why "<why>" --decision <n> --words "<the operator's exact words>"`;
  return `new facts: ${base} --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or, if ${parent} can close without ${q.key}, file the ask again without --required-by`;
}

function unfinishedOf(rulings: Chain<RulingRow>, events: EventRow[], operator: OperatorRow[], ctx: Ctx, issues: Map<string, IssueSnap> | null, lease: Lease | null, declared: string[]): UnfinishedRuling[] {
  const last = new Map<string, VoidRow>();
  for (const r of rulings.verified) last.set(r.id, r);
  const superseded = (r: VoidRow): boolean => (keyNewestDecision(operator, r.key)?.id ?? null) !== (r.repair?.basis ?? null);
  const snapOf = (key: string): string[] | undefined => issues?.get(key)?.fixVersions;
  const listed = (r: VoidRow): boolean => r.phase === 'intent' || r.phase === 'applied'
    || (r.phase === 'void' && !!r.repair && !superseded(r) && !(snapOf(r.key) && reached(r.repair, snapOf(r.key) as string[])));
  return [...last.values()].filter(listed).map((r) => {
    const base = { ruling: r.id, req: r.req, key: r.key, phase: r.phase as UnfinishedRuling['phase'], op: `${r.op.kind} ${vName(r.op.from_v)}→${vName(r.op.to_v)}` };
    const snap = issues?.get(r.key);
    if (r.phase === 'void' && r.repair) {
      return { ...base, status: 'blocked', owner: 'chief', next: r.repair.line, observed: snap ? observedOf(r, snap.fixVersions, 'mirror') : null };
    }
    const replay: UnfinishedRuling = { ...base, status: 'replay', owner: 'release-manager', next: `jira release rm-run ${ctx.release}`, observed: null };
    if (r.phase !== 'intent' || !snap || (lease && !lease.released && lease.epoch === r.epoch)) return replay;
    if (landed(r.op, snap.fixVersions) || untouched(r.op, snap.fixVersions)) return replay;
    const refused = events.some((e) => e.kind === 'ruled' && e.ruling === r.id && e.readback === 'mismatch');
    const newer = newerElsewhere(operator, r);
    const both = holdsBoth(r, snap.fixVersions);
    if (!refused && !newer && (both ? boundAdd : boundRemoval)(ctx.env, r, snap.fixVersions)) return replay;
    const route = routeOf(ctx.release, r, snap.fixVersions, newer, declared);
    const next = route?.void ? (route.repair?.line ?? `${route.why}; the replay voids it and writes nothing`) : route ? route.why : repairOf(ctx.release, r, false, snap.fixVersions);
    return { ...base, status: 'blocked', owner: 'chief', next, observed: observedOf(r, snap.fixVersions, 'mirror') };
  });
}

export function repairInputs(ctx: Ctx): {
  operator: OperatorRow[]; rulings: RulingRow[]; requests: RequestRow[]; admissions: Admission[]; requestsBad: boolean;
} {
  const l = loadOrThrow(ctx);
  return {
    operator: l.operator.verified,
    rulings: l.rulings.verified,
    requests: [...latestOrEmpty(l.requests).values()],
    admissions: (admissionsOrNull() ?? []).filter((a) => typeof a === 'object' && a !== null),
    requestsBad: l.requests.bad.length > 0,
  };
}
