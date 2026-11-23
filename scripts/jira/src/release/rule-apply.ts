import { journalPath, readVersionWrites, type VersionWriteRow } from './version-writes.js';
import { appendChain, readChain, withLockAsync } from './ledger.js';
import { SECTOR_OPT_OUT, sectorField } from '../commands/sector.js';
import { appendAdmission, assertAdmissionsWritable, readAdmissionsTolerant } from '../commands/admissions-ledger.js';
import { baselineId, effectOn, recordOf, scopeOk, terminalOf } from './reducer.js';
import type { Leave } from './leave.js';
import type { Authority, Declaration, EventRow, IssueSnap, Op, OperatorRow, PlacementClass, RequestRow, RulingRow, Verb } from './types.js';
import { appendWithdrawal, isRepair, ISSUE_KEY, placementOf } from './operator-acts.js';
import { pointerOf, rmFence } from './request-queue.js';
import { type Ctx, f, type JiraPort, latestRequests, type Loaded, loadOrThrow, locked, readMirror, reduceLoaded, seq, ts, vName } from './engine-core.js';

const OUTCOMES: Record<Verb, Record<string, Op['kind'][]>> = {
  INTAKE: { ADMIT: ['add', 'move'], BACKLOG: ['remove', 'move', 'none'], 'AD-HOC': ['none'] },
  REVERSION: { MOVE: ['move', 'remove'], KEEP: ['keep'] },
  DISCHARGE: { ACCEPT: ['discharge'], REJECT: ['none'] },
};

export async function clearProposedLabels(jira: Pick<JiraPort, 'labels' | 'removeLabels'>, key: string): Promise<string[]> {
  const proposed = (await jira.labels(key)).filter((l) => /^proposed-/.test(l));
  if (!proposed.length) return [];
  await jira.removeLabels(key, proposed);
  const left = (await jira.labels(key)).filter((l) => /^proposed-/.test(l));
  if (left.length) throw new Error(`release: ${key} still carries ${left.join(', ')} after the removal; clear it by hand (jira edit ${key} --labels)`);
  return proposed;
}

function lockedAsync<T>(ctx: Ctx, fn: (l: Loaded) => Promise<T>): Promise<T> {
  loadOrThrow(ctx);
  return withLockAsync(ctx.dir, () => fn(loadOrThrow(ctx)));
}

export function claim(ctx: Ctx): RequestRow[] {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const mine = `claimed:${lease.epoch}`;
    const out: RequestRow[] = [];
    for (const r of latest.values()) {
      const claimedEpoch = /^claimed:(\d+)$/.exec(r.state)?.[1];
      if (r.state === mine) out.push(r);
      else if (r.state === 'open' || (claimedEpoch !== undefined && Number(claimedEpoch) < lease.epoch)) {
        const { prev: _p, mac: _m, ...rest } = r;
        out.push(appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: mine }));
      }
    }
    const byKey = new Map<string, RequestRow[]>();
    for (const r of out) byKey.set(r.key, [...(byKey.get(r.key) ?? []), r]);
    return [...byKey.values()].flatMap((rs) => [...rs.filter((r) => pointerOf(r) !== undefined), ...rs.filter((r) => pointerOf(r) === undefined)]);
  });
}

function classOf(decl: Declaration, op: Op): PlacementClass {
  const target = op.kind === 'keep' || op.kind === 'discharge' ? op.from_v : op.kind === 'remove' || op.kind === 'none' ? null : op.to_v;
  if (target === decl.current) return 'current';
  return target && decl.versions.includes(target) ? 'next' : 'backlog';
}

function checkOp(decl: Declaration, op: Op): void {
  const inR = (v: string | null) => v !== null && decl.versions.includes(v);
  const ok = {
    add: inR(op.to_v),
    remove: inR(op.from_v) && op.to_v === null,
    move: op.from_v !== op.to_v && (inR(op.from_v) || inR(op.to_v)),
    keep: inR(op.from_v) && op.to_v === op.from_v,
    discharge: inR(op.from_v) && op.to_v === op.from_v,
    none: true,
  }[op.kind];
  if (!ok) throw new Error(`release rule: ${op.kind} ${op.from_v ?? 'backlog'}→${op.to_v ?? 'backlog'} is not a valid operation on ${decl.release}`);
}

export interface RuleOptions {
  req: string;
  outcome: string;
  op: Op;
  sector: string;
  ground: string;
  reason: string;
  supersedes: string[];
  authority: Authority;
}

function checkBlockerPull(ctx: Ctx, p: {
  decl: Declaration; ops: Map<string, OperatorRow>; governing: OperatorRow | undefined; key: string; op: Op; authority: Authority;
}): boolean {
  const standingRow = p.authority.kind === 'operator' && p.authority.ref ? p.ops.get(p.authority.ref) : undefined;
  if (standingRow?.kind !== 'blocker-pull') return false;
  if (!scopeOk({ authority: p.authority, key: p.key, op: p.op }, p.ops, p.decl.current)) {
    throw new Error(`release rule: ${p.authority.ref} does not cover ${p.key} ${p.op.kind} ${p.op.from_v}→${p.op.to_v}`);
  }
  const blocks = p.authority.blocks ?? [];
  const { issues } = readMirror(ctx.mirrorRoot);
  for (const b of blocks) {
    const snap = issues?.get(b);
    if (!snap || terminalOf(snap) !== null || !snap.fixVersions.includes(p.decl.current) || !snap.blockedBy?.includes(p.key)) {
      throw new Error(`release rule: blocker-pull: ${b} is no longer an open ${p.decl.current} ticket blocked by ${p.key}`);
    }
  }
  const g = p.governing;
  if (g && Date.parse(g.ts) > Date.parse(standingRow.ts)) {
    throw new Error(`release rule: CONFLICT ${p.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${p.key}; ${blocks.join(', ')} blocked by it`);
  }
  return true;
}

function checkDelivered(ctx: Ctx, p: {
  decl: Declaration; ops: Map<string, OperatorRow>; governing: OperatorRow | undefined; key: string; op: Op; authority: Authority; req: RequestRow;
}): boolean {
  const standingRow = p.authority.kind === 'operator' && p.authority.ref ? p.ops.get(p.authority.ref) : undefined;
  if (standingRow?.kind !== 'delivered-follows-merge') return false;
  if (!scopeOk({ authority: p.authority, key: p.key, op: p.op }, p.ops, p.decl.current)) {
    throw new Error(`release rule: ${p.authority.ref} does not cover ${p.key} ${p.op.kind} ${p.op.from_v}→${p.op.to_v}`);
  }
  const snap = readMirror(ctx.mirrorRoot).issues?.get(p.key);
  const from = p.op.from_v;
  if (!snap || !from || !snap.fixVersions.includes(from) || snap.fixVersions.includes(p.decl.current)) {
    throw new Error(`release rule: delivered-follows-merge: ${p.key} no longer sits in ${from ?? 'a later version'} outside ${p.decl.current}`);
  }
  const t = terminalOf(snap);
  if (t !== 'Done' && t !== 'Duplicate') throw new Error(`release rule: delivered-follows-merge: ${p.key} is ${t ?? 'not closed'}, not delivered`);
  const evidence = mergeEvidenceFor(p.req, t, ctx.deliveredPr);
  if (!evidence || evidence !== p.authority.delivered) {
    throw new Error(`release rule: delivered-follows-merge: ${p.key} has no verifiable merge evidence (${p.authority.delivered ?? 'none'})`);
  }
  const g = p.governing;
  if (g && Date.parse(g.ts) > Date.parse(standingRow.ts)) {
    throw new Error(`release rule: CONFLICT ${p.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${p.key}; its work merged`);
  }
  return true;
}

export const keyNewestDecision = (rows: OperatorRow[], key: string): OperatorRow | undefined =>
  rows.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(key)).sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts)).pop();

function restoreAsAdd(verb: Verb, op: Op, governing: OperatorRow | undefined, newest: OperatorRow | undefined): Op {
  const same = verb === 'REVERSION' && op.kind === 'move' && op.from_v === null && governing?.op === 'add'
    && (governing.from_v ?? null) === null && (governing.to_v ?? null) === op.to_v && newest?.id === governing.id;
  return same ? { kind: 'add', from_v: null, to_v: op.to_v } : op;
}

function replacedByGoverning(prior: RulingRow | undefined, governing: OperatorRow | undefined, rulings: RulingRow[]): boolean {
  if (prior?.authority.kind !== 'operator' || !governing) return false;
  return Date.parse(governing.ts) > Date.parse(rulings.find((r) => r.id === prior.id)?.ts ?? prior.ts);
}

const citesGoverning = (authority: RulingRow['authority'], governing: OperatorRow | undefined): boolean =>
  authority.kind === 'operator' && governing !== undefined && authority.ref === governing.id;

export function rule(ctx: Ctx, o: RuleOptions): RulingRow {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const req = latest.get(o.req);
    if (!req) throw new Error(`release rule: no request ${o.req}`);
    if (req.state !== `claimed:${lease.epoch}`) throw new Error(`release rule: ${o.req} is ${req.state}, not claimed:${lease.epoch}`);
    const kinds = OUTCOMES[req.verb][o.outcome];
    if (!kinds) throw new Error(`release rule: ${req.verb} outcomes are ${Object.keys(OUTCOMES[req.verb]).join(', ')}`);
    if (!kinds.includes(o.op.kind)) throw new Error(`release rule: ${o.outcome} takes --op ${kinds.join('|')}`);
    checkOp(l.decl, o.op);
    const given = o.sector.trim();
    const sector = sectorField() ? (given.toLowerCase() === SECTOR_OPT_OUT ? '' : given) : given || SECTOR_OPT_OUT;
    if (!sector) throw new Error('release rule: a ruling without a sector refuses; ask the chief to set it');
    if (!o.ground.trim() || !o.reason.trim()) throw new Error('release rule: --ground and --reason are required');

    const s = reduceLoaded(l, { issues: null, sync: null });
    if (s.status !== 'OK') throw new Error(`release ${ctx.release} is UNKNOWN: ${s.integrity[0]}`);
    const rulings = l.rulings.verified;
    const applied = new Map(rulings.filter((r) => r.phase === 'applied' || r.phase === 'receipted').map((r) => [r.id, r]));
    const baselineIds = new Set(l.baselines.map(baselineId));
    for (const id of o.supersedes) {
      if (!applied.has(id) && !baselineIds.has(id)) throw new Error(`release rule: supersedes names ${id}, which is not an effective ruling`);
    }
    if (o.op.kind === 'none' && o.supersedes.length) throw new Error('release rule: a ruling that changes nothing supersedes nothing');
    const ops = new Map(l.operator.verified.map((x) => [x.id, x]));
    const touched = [o.op.from_v, o.op.to_v].filter((v) => v !== null);
    const governing = l.operator.verified.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(req.key)
      && [x.from_v, x.to_v].some((v) => v != null && touched.includes(v)))
      .sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts)).pop();
    let authority = o.authority;
    let op = o.op;
    let supersedes = o.supersedes;
    const restored = restoreAsAdd(req.verb, o.op, governing, keyNewestDecision(l.operator.verified, req.key));
    const checked = { decl: l.decl, ops, governing, key: req.key, op: o.op, authority, req };
    const pulling = checkBlockerPull(ctx, checked) || checkDelivered(ctx, checked);
    for (const v of l.decl.versions) {
      if (!effectOn(o.op, v) && !(o.op.kind === 'none' && (o.op.from_v === v || o.op.to_v === v))) continue;
      const rec = recordOf(s, req.key, v);
      if (rec?.placement === 'unknown') throw new Error(`release rule: ${req.key}@${v} is UNKNOWN`);
      if (rec?.placement === 'pending') throw new Error(`release rule: ${req.key}@${v} has a pending intent; apply or void it first`);
      if (o.op.kind === 'none') continue;
      const prior = rec?.ruling ? applied.get(rec.ruling) : undefined;
      if (rec?.ruling && !supersedes.includes(rec.ruling)) {
        if (!replacedByGoverning(prior, governing, rulings)) throw new Error(`release rule: supersedes must name ${rec.ruling} (in effect for ${req.key}@${v})`);
        supersedes = [...supersedes, rec.ruling];
      }
      if (prior?.authority.kind !== 'operator') continue;
      if (pulling) continue;
      const since = Date.parse(rulings.find((r) => r.id === prior.id)?.ts ?? prior.ts);
      const cited = authority.kind === 'operator' && authority.ref ? ops.get(authority.ref) : undefined;
      if (cited?.kind === 'decision' && Date.parse(cited.ts) <= since) {
        throw new Error(`release rule: ${cited.id} predates ${prior.id}; an older operator record never supersedes a newer ruling`);
      }
      const conflict = (g: OperatorRow) => new Error(`release rule: CONFLICT ${req.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${req.key}; rule under it`);
      if (cited?.kind === 'decision') {
        if (governing && governing.id !== cited.id) throw conflict(governing);
        op = restored;
        continue;
      }
      if (authority.kind === 'operator') continue;
      if (!governing || Date.parse(governing.ts) <= since) throw new Error(`release rule: ${prior.id} carries operator authority; only an operator record supersedes it`);
      if (!scopeOk({ authority: { kind: 'operator', ref: governing.id }, key: req.key, op: restored }, ops, l.decl.current)) throw conflict(governing);
      op = restored;
      authority = { kind: 'operator', ref: governing.id };
    }
    if (citesGoverning(authority, governing)) op = restored;
    if (authority.kind === 'operator') {
      if (!scopeOk({ authority, key: req.key, op }, ops, l.decl.current)) throw new Error(`release rule: ${authority.ref ?? '(no ref)'} does not cover ${req.key} ${op.kind} ${op.from_v}→${op.to_v}`);
    }
    if (authority.kind === 'import' && !authority.ref) throw new Error('release rule: an import names its source in --ref');

    const id = seq(`R-${ctx.release}`, l.rulings.rows.map((r) => r.id));
    const row = appendChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k, {
      id, epoch: lease.epoch, req: req.req, ts: ts(ctx), verb: req.verb, key: req.key, op, outcome: o.outcome,
      class: classOf(l.decl, op), sector, ground: o.ground, reason: o.reason, supersedes,
      authority, phase: 'intent',
    });
    const { prev: _p, mac: _m, ...rest } = req;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: `ruled:${id}` });
    return row;
  });
}

export const rulingLine = (r: RulingRow): string =>
  `RULING ${r.id} ${r.req} ${r.verb} ${r.key} ${r.op.kind} ${vName(r.op.from_v)}→${vName(r.op.to_v)} ${r.outcome} ${r.class} sector=${r.sector} — ${r.ground}: ${r.reason}`;

export function landed(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  switch (op.kind) {
    case 'add': return has(op.to_v);
    case 'remove': return !has(op.from_v);
    case 'move': return (op.to_v === null || has(op.to_v)) && !has(op.from_v);
    case 'keep':
    case 'discharge': return has(op.from_v);
    default: return true;
  }
}

export function untouched(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  return op.kind !== 'move' || ((op.from_v === null || has(op.from_v)) && !has(op.to_v));
}

const sameSet = (a: string[], b: string[]): boolean => [...a].sort().join('\n') === [...b].sort().join('\n');

export function boundRemoval(env: Record<string, string | undefined>, r: RulingRow, cur: string[]): VersionWriteRow | null {
  const from = r.op.from_v;
  const to = r.op.to_v;
  if (r.op.kind !== 'move' || !from || !to) return null;
  try {
    const path = journalPath(env);
    if (!path) return null;
    return readVersionWrites(path).filter((w) => w.key === r.key && w.mechanism === 'rm-apply' && w.from.includes(from) && !w.to.includes(from)
      && !w.to.includes(to) && w.ts >= r.ts && sameSet(w.to, cur)).sort((a, b) => a.ts.localeCompare(b.ts)).at(-1) ?? null;
  } catch {
    return null;
  }
}

export function boundAdd(env: Record<string, string | undefined>, r: RulingRow, cur: string[]): VersionWriteRow | null {
  const from = r.op.from_v;
  const to = r.op.to_v;
  if (r.op.kind !== 'move' || !from || !to) return null;
  try {
    const path = journalPath(env);
    if (!path) return null;
    return readVersionWrites(path).filter((w) => w.key === r.key && w.mechanism === 'rm-apply' && !w.from.includes(to) && w.to.includes(to)
      && w.from.includes(from) && w.to.includes(from) && w.ts >= r.ts && sameSet(w.to, cur)).sort((a, b) => a.ts.localeCompare(b.ts)).at(-1) ?? null;
  } catch {
    return null;
  }
}

export const holdsBoth = (r: RulingRow, cur: string[]): boolean => r.op.from_v !== null && r.op.to_v !== null && cur.includes(r.op.from_v) && cur.includes(r.op.to_v);

const leaveOf = (r: RulingRow): Leave | undefined => (r.authority.kind === 'operator' && r.authority.ref ? { by: r.authority.ref, op: r.op } : undefined);

async function ownedHalf(ctx: Ctx, r: RulingRow, cur: string[]): Promise<boolean> {
  const row = holdsBoth(r, cur) ? boundAdd(ctx.env, r, cur) : boundRemoval(ctx.env, r, cur);
  if (!row || typeof ctx.jira.newestFixVersionEntry !== 'function') return false;
  try {
    return (await ctx.jira.newestFixVersionEntry(r.key)).id === row.entry;
  } catch {
    return false;
  }
}

export function newerElsewhere(operator: OperatorRow[], r: RulingRow): OperatorRow | undefined {
  const latest = keyNewestDecision(operator.filter((x) => placementOf(x) !== undefined), r.key);
  return latest && Date.parse(latest.ts) > Date.parse(r.ts) && placementOf(latest) !== r.op.to_v ? latest : undefined;
}

const againstOf = (g: OperatorRow, r: RulingRow): string =>
  `${g.id} (newer than ${r.id}) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} places ${r.key} outside ${vName(r.op.to_v)}`;

export const observedOf = (r: RulingRow, cur: string[], source: 'Jira' | 'mirror'): string =>
  `${r.key} is in ${cur.length ? cur.join(', ') : 'no version'} (${source}); the ${r.op.kind} wants ${vName(r.op.from_v)} -> ${vName(r.op.to_v)}`;

export function repairOf(release: string, r: RulingRow, live: boolean, cur: string[]): string {
  const first = live ? '' : 'run `jira mirror` and read this again; if it still holds, ';
  if (holdsBoth(r, cur)) {
    return `${first}the chief completes it with \`jira fix-version ${r.key} --remove ${r.op.from_v} --by ${r.authority.ref}\`, then \`jira release rm-run ${release}\` replays the row and receipt once`;
  }
  const finish = `jira fix-version ${r.key} --add ${vName(r.op.to_v)}`;
  const restore = `jira fix-version ${r.key} --add ${vName(r.op.from_v)}`;
  return `${first}the chief completes it with \`${finish}\` (add --gate <reason> when ${vName(r.op.to_v)} is frozen) or restores the source with \`${restore}\`, then \`jira release rm-run ${release}\` replays the row and receipt once`;
}

type Repair = { line: string; holds: string[]; lacks: string[]; basis?: string | null };
export type VoidRow = RulingRow & { repair?: Repair };

type Route = { void: true; repair: Repair | null; why: string } | { void: false; why: string };

export function routeOf(release: string, r: RulingRow, cur: string[], newer: OperatorRow | undefined, declared: string[]): Route | null {
  if (newer) {
    const to = placementOf(newer);
    const against = againstOf(newer, r);
    if (to) {
      return { void: true, why: against, repair: cur.includes(to) ? null : { line: `jira fix-version ${r.key} --add ${to} --by ${newer.id}`, holds: [to], lacks: [] } };
    }
    const from = newer.from_v ?? null;
    if (from === null || !cur.includes(from)) return { void: true, why: against, repair: null };
    if (cur.some((v) => v !== from && declared.includes(v))) {
      return { void: false, why: `${against}, and ${r.key} also holds ${cur.filter((v) => v !== from && declared.includes(v)).join(', ')}, so no line ${newer.id} covers can end it: the chief places ${r.key} by hand` };
    }
    return { void: true, why: against, repair: { line: `jira fix-version ${r.key} --remove ${from} --by ${newer.id}`, holds: [], lacks: [from] } };
  }
  if (!holdsBoth(r, cur) || r.authority.kind === 'operator') return null;
  const why = `${r.key} holds both ${r.op.from_v} and ${r.op.to_v} and nothing proves the add was this ruling's own`;
  const line = `jira release request ${release} --verb REVERSION --key ${r.key} --from ${r.op.from_v} --to ${r.op.to_v}`
    + ` --why "finish ${r.id}: ${r.key} holds both ${r.op.from_v} and ${r.op.to_v}" --chief-reason "repair of ${r.id}, interrupted between its add and its remove"`;
  return { void: true, why, repair: { line, holds: [r.op.to_v as string], lacks: [r.op.from_v as string] } };
}

export const reached = (p: Repair, cur: string[]): boolean => p.holds.every((v) => cur.includes(v)) && p.lacks.every((v) => !cur.includes(v));

function phaseRow(ctx: Ctx, r: RulingRow, phase: RulingRow['phase'], extra: Partial<RulingRow>): Omit<RulingRow, 'prev' | 'mac'> {
  const { prev: _p, mac: _m, ...rest } = r;
  return { ...rest, ...extra, phase, ts: ts(ctx) };
}

async function finishHalf(ctx: Ctx, l: Loaded, epoch: number, last: RulingRow, cur: string[], event: (readback: 'ok' | 'mismatch') => void)
  : Promise<RulingRow | { phase: 'void'; line: string }> {
  const id = last.id;
  const rulingsPath = f(ctx, 'rulings.jsonl');
  const newer = newerElsewhere(l.operator.verified, last);
  const owned = !newer && await ownedHalf(ctx, last, cur);
  const route = owned ? null : routeOf(ctx.release, last, cur, newer, l.decl.versions);
  if (route?.void) {
    const req = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(last.req);
    appendChain<VoidRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', { epoch, ...(route.repair ? { repair: { ...route.repair, basis: keyNewestDecision(l.operator.verified, last.key)?.id ?? null } } : {}) } as Partial<VoidRow>));
    if (req) appendWithdrawal(ctx, l.k, req, 'repair', route.why);
    return { phase: 'void', line: `VOID ${id} (${route.why}; ${last.req} withdrawn${route.repair ? `; next: ${route.repair.line}` : ''})` };
  }
  if (!owned) {
    event('mismatch');
    throw new Error(route
      ? `release apply: ${id} is partly applied in Jira and ${route.why}, so nothing was written: ${observedOf(last, cur, 'Jira')}`
      : `release apply: ${id} is partly applied in Jira and nothing proves its first write was this ruling's own, so nothing was written: ${observedOf(last, cur, 'Jira')}; ${repairOf(ctx.release, last, true, cur)}`);
  }
  assertAdmissionsWritable();
  if (holdsBoth(last, cur)) await ctx.jira.setFixVersion(last.key, 'remove', last.op.from_v as string, leaveOf(last));
  else await ctx.jira.setFixVersion(last.key, 'add', last.op.to_v as string);
  if (!landed(last.op, await ctx.jira.fixVersions(last.key))) {
    event('mismatch');
    throw new Error(`release apply: ${id} readback does not match ${last.op.kind} ${vName(last.op.from_v)}→${vName(last.op.to_v)}`);
  }
  return appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { epoch, readback: 'ok' }));
}

export async function apply(ctx: Ctx, id: string): Promise<{ phase: RulingRow['phase']; line: string; note?: string }> {
  let note: string | undefined;
  return lockedAsync(ctx, async (l) => {
    const lease = rmFence(ctx, l);
    const rows = readChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k);
    if (rows.bad.length) throw new Error(`release: rulings.jsonl does not verify (${rows.bad[0]})`);
    const mine = rows.verified.filter((r) => r.id === id);
    if (!mine.length) throw new Error(`release apply: no ruling ${id}`);
    let last = mine[mine.length - 1];
    if (last.phase === 'void') return { phase: 'void', line: `VOID ${id}` };
    const rulingsPath = f(ctx, 'rulings.jsonl');
    const membership = ['add', 'remove', 'move'].includes(last.op.kind);
    const event = (readback: 'ok' | 'mismatch') => {
      if (!membership) return;
      const eventsPath = f(ctx, 'events.jsonl');
      if (readChain<EventRow>(eventsPath, l.k).verified.some((e) => e.kind === 'ruled' && e.ruling === id && e.readback === readback)) return;
      appendChain<EventRow>(eventsPath, l.k, {
        ts: ts(ctx), kind: 'ruled', key: last.key, from: last.op.from_v, to: last.op.to_v, ruling: id, readback,
      });
    };

    if (last.phase === 'intent' && last.epoch !== lease.epoch) {
      const cur = await ctx.jira.fixVersions(last.key);
      if (!landed(last.op, cur) && !untouched(last.op, cur)) {
        const half = await finishHalf(ctx, l, lease.epoch, last, cur, event);
        if ('line' in half) return half;
        last = half;
      } else if (!landed(last.op, cur)) {
        const req = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(last.req);
        appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', { epoch: lease.epoch }));
        if (req && isRepair(req)) {
          appendWithdrawal(ctx, l.k, req, 'repair', 'never-landed');
          return { phase: 'void', line: `VOID ${id} (epoch ${last.epoch} intent never reached Jira; ${last.req} withdrawn)` };
        }
        if (req) {
          const { prev: _p, mac: _m, ...rest } = req;
          appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
        }
        return { phase: 'void', line: `VOID ${id} (epoch ${last.epoch} intent never reached Jira; ${last.req} reopened)` };
      } else {
        last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { epoch: lease.epoch, readback: 'ok' }));
      }
    } else if (last.phase === 'intent') {
      const { op, key: k } = last;
      if ((last.verb === 'INTAKE' && last.outcome === 'ADMIT') || (last.verb === 'REVERSION' && op.kind === 'add')
        || ((op.kind === 'remove' || op.kind === 'move') && op.from_v)) assertAdmissionsWritable();
      const cur = await ctx.jira.fixVersions(k);
      const req = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(last.req);
      if (req && isRepair(req)) {
        if (typeof ctx.jira.newestFixVersionEntry !== 'function') throw new Error(`release apply: the Jira port has no newestFixVersionEntry; ${last.req} is a version-repair request`);
        const newest = await ctx.jira.newestFixVersionEntry(k);
        if (newest.id !== (req.evidence as { entry?: unknown }).entry && !landed(op, cur)) {
          if (!untouched(op, cur)) {
            event('mismatch');
            throw new Error(`release apply: ${id} is partly applied in Jira; ${k} needs a hand fix before it is re-ruled`);
          }
          appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', {}));
          appendWithdrawal(ctx, l.k, req, 'repair', 'entry-moved');
          return { phase: 'void', line: `VOID ${id} (${k} Fix Version entry moved since ${last.req} was filed; ${last.req} withdrawn)` };
        }
      }
      if ((op.kind === 'add' || op.kind === 'move') && op.to_v && !cur.includes(op.to_v)) await ctx.jira.setFixVersion(k, 'add', op.to_v);
      if ((op.kind === 'remove' || op.kind === 'move') && op.from_v && cur.includes(op.from_v)) await ctx.jira.setFixVersion(k, 'remove', op.from_v, leaveOf(last));
      if (!landed(op, await ctx.jira.fixVersions(k))) {
        event('mismatch');
        throw new Error(`release apply: ${id} readback does not match ${op.kind} ${vName(op.from_v)}→${vName(op.to_v)}`);
      }
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { readback: 'ok' }));
    }

    if (last.phase === 'applied') {
      event('ok');
      const phaseOf = new Map(rows.verified.map((r) => [r.id, r.phase]));
      const superseded = rows.verified.some((s) => s.supersedes.includes(id) && ['applied', 'receipted'].includes(phaseOf.get(s.id) ?? ''));
      const admitted = last.verb === 'INTAKE' && last.outcome === 'ADMIT'
        || last.verb === 'REVERSION' && (last.op.kind === 'move' || last.op.kind === 'add');
      if (!superseded && admitted && last.op.to_v) {
        const version = last.op.to_v;
        const key = last.key;
        if (!readAdmissionsTolerant(version).some((r) => r.kind === 'rm-admit' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-admit', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      if (!superseded && (last.op.kind === 'remove' || last.op.kind === 'move') && last.op.from_v) {
        const version = last.op.from_v;
        const key = last.key;
        if (!readAdmissionsTolerant(version).some((r) => r.kind === 'rm-remove' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-remove', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      if (last.verb === 'INTAKE') await clearProposedLabels(ctx.jira, last.key);
      note = await backlogLabel(ctx.jira as DoorJiraPort, last);
      const marker = `[release-ruling ${id}]`;
      const authority = last.authority.kind === 'rm' ? 'rm' : `${last.authority.kind} ${last.authority.ref}`;
      const commentId = await ctx.jira.findComment(last.key, marker)
        ?? await ctx.jira.addComment(last.key, `${marker} ${rulingLine(last)}\n\nAuthority: ${authority}. Audit copy; the release ledger is the record.`);
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'receipted', { comment_id: commentId }));
    }
    return { phase: last.phase, line: rulingLine(last), ...(note ? { note } : {}) };
  });
}

export type DoorJiraPort = JiraPort & {
  addLabels?(key: string, labels: string[]): Promise<void>;
  issue?(key: string, opts?: { signal?: AbortSignal }): Promise<IssueSnap | null>;
};

async function backlogLabel(jira: DoorJiraPort, r: RulingRow): Promise<string | undefined> {
  if (!r.ground.startsWith('door:')) return undefined;
  const cur = await jira.fixVersions(r.key);
  if (cur.length) {
    if ((r.op.kind === 'add' || r.op.kind === 'move') && r.op.to_v && (await jira.labels(r.key)).includes('backlog')) await jira.removeLabels(r.key, ['backlog']);
    return undefined;
  }
  if (!jira.addLabels) return `the backlog label on ${r.key}: this Jira port cannot add labels`;
  await jira.addLabels(r.key, ['backlog']);
  return undefined;
}

function duplicateOf(evidence: unknown): string | undefined {
  const original = (evidence as { duplicate_of?: unknown } | null)?.duplicate_of;
  return typeof original === 'string' && ISSUE_KEY.test(original) ? original : undefined;
}

export function mergeEvidenceFor(q: RequestRow, t: 'Done' | 'Duplicate', lookup?: (key: string) => number | undefined): string | undefined {
  if (!lookup) return undefined;
  const original = t === 'Duplicate' ? duplicateOf(q.evidence) : undefined;
  const found = lookup(q.key) ?? (original ? lookup(original) : undefined);
  return found !== undefined ? `PR #${found}` : undefined;
}
