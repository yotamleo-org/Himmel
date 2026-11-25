import type { Judge, JudgeInput, RefuseDecision, RuledDecision, QueuedRequest } from './engine.js';
import { operatorAsk } from './operator-work.js';
import { isResidual, placeByRules, type Placement, type Rule, type TicketIn } from './filing-rules.js';
import { effectOn, terminalOf } from './reducer.js';
import type { IssueSnap, Op, OperatorRow, RequestRow, RulingRow, Verb } from './types.js';


export type DoorResult = RuledDecision | RefuseDecision;

type Decl = { current: string; versions: string[] };
interface Placed { rule: Rule; target: string | null; ground: string; reason: string }

const idx = (decl: Decl, v: string | null): number => {
  const i = v === null ? -1 : decl.versions.indexOf(v);
  return i < 0 ? Number.POSITIVE_INFINITY : i;
};

export function earlierThan(decl: Pick<Decl, 'versions'>, a: string | null, b: string | null): boolean {
  return idx(decl as Decl, a) < idx(decl as Decl, b);
}

const vName = (v: string | null): string => v ?? 'backlog';
const ev = (q: RequestRow): Record<string, unknown> => (q.evidence && typeof q.evidence === 'object' ? q.evidence as Record<string, unknown> : {});
const snapOf = (input: JudgeInput, key: string): IssueSnap | undefined => input.issues.find((i) => i.key === key);
const heldOf = (input: JudgeInput, snap: IssueSnap | undefined): string[] =>
  input.versions.filter((v) => snap?.fixVersions.includes(v));

export function parentVersion(input: JudgeInput, parent: string): string | null {
  return heldOf(input, snapOf(input, parent))[0] ?? null;
}

function supersedes(input: JudgeInput, key: string, op: Op): string[] {
  if (op.kind === 'none') return [];
  return [...new Set(input.records.filter((r) => r.key === key && r.ruling && effectOn(op, r.version)).map((r) => r.ruling as string))];
}

const ruledAt = (input: JudgeInput, r: RulingRow): number => Date.parse(input.ruled_at?.[r.id] ?? r.ts);

function newestRuling(input: JudgeInput, key: string): RulingRow | undefined {
  return input.rulings.filter((r) => r.key === key).sort((a, b) => ruledAt(input, a) - ruledAt(input, b)).pop();
}

function newestDecision(input: JudgeInput, key: string): OperatorRow | undefined {
  return input.operator.filter((o) => o.kind === 'decision' && (o.keys ?? []).includes(key))
    .sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts)).pop();
}

function operatorRecord(input: JudgeInput, q: RequestRow): OperatorRow | undefined {
  const rec = newestDecision(input, q.key);
  if (!rec || !rec.op || rec.op === 'none') return undefined;
  if (ev(q).operator_record === rec.id) return rec;
  const last = newestRuling(input, q.key);
  return !last || Date.parse(rec.ts) > ruledAt(input, last) ? rec : undefined;
}

interface Base { input: JudgeInput; q: RequestRow; snap: IssueSnap | undefined; held: string[] }

function decision(b: Base, outcome: string, op: Op, ground: string, reason: string, extra: Partial<RuledDecision> = {}): RuledDecision {
  return {
    req: b.q.req, outcome, op: op.kind, from: op.from_v, to: op.to_v, sector: b.snap?.sector ?? null, ground, reason,
    supersedes: supersedes(b.input, b.q.key, op), ...extra,
  };
}

function noChange(b: Base, ground: string, reason: string, extra: Partial<RuledDecision> = {}): DoorResult {
  const { q } = b;
  if (q.verb === 'DISCHARGE') return decision(b, 'REJECT', { kind: 'none', from_v: q.from_v, to_v: q.to_v }, ground, reason, extra);
  if (q.verb === 'REVERSION') {
    if (q.from_v === null || !b.input.versions.includes(q.from_v)) return { req: q.req, outcome: 'REFUSE', ground, reason, ...(extra.queue ? { queue: extra.queue } : {}) };
    return decision(b, 'KEEP', { kind: 'keep', from_v: q.from_v, to_v: q.from_v }, ground, reason, extra);
  }
  const holds = (b.snap?.fixVersions.length ?? 0) > 0;
  return decision(b, holds ? 'AD-HOC' : 'BACKLOG', { kind: 'none', from_v: q.from_v, to_v: q.to_v }, ground, reason, extra);
}

function ruleO(b: Base, rec: OperatorRow): DoorResult {
  const { q } = b;
  const op: Op = { kind: rec.op as Op['kind'], from_v: rec.from_v ?? null, to_v: rec.to_v ?? null };
  const ground = `door:operator:${rec.id}`;
  const said = `the operator's record ${rec.id} says ${op.kind} ${vName(op.from_v)}→${vName(op.to_v)}`;
  const operator = { authority: 'operator' as const, ref: rec.id };
  const queue = (verb: Verb): { queue: QueuedRequest } => ({ queue: { verb, from_v: op.from_v, to_v: op.to_v, operator_record: rec.id } });
  if (q.verb === 'INTAKE') {
    if (op.kind === 'add' || (op.kind === 'move' && op.to_v !== null)) return decision(b, 'ADMIT', op, ground, said, operator);
    if (op.kind === 'remove' || op.kind === 'move') return decision(b, 'BACKLOG', op, ground, said, operator);
    if (op.kind === 'keep') return noChange(b, ground, `${said}; a REVERSION is queued under it`, queue('REVERSION'));
    return noChange(b, ground, `${said}; a DISCHARGE is queued under it`, queue('DISCHARGE'));
  }
  if (q.verb === 'REVERSION') {
    if (op.kind === 'add') return decision(b, 'MOVE', { kind: 'move', from_v: null, to_v: op.to_v }, ground, said, operator);
    if (op.kind === 'move' || op.kind === 'remove') return decision(b, 'MOVE', op, ground, said, operator);
    if (op.kind === 'keep') return decision(b, 'KEEP', op, ground, said, operator);
    return { req: q.req, outcome: 'REFUSE', ground, reason: `${said}; a DISCHARGE is queued under it`, ...queue('DISCHARGE') };
  }
  if (op.kind === 'discharge') return decision(b, 'ACCEPT', op, ground, said, operator);
  if (op.kind === 'add') return noChange(b, ground, `${said}; an INTAKE is queued under it`, queue('INTAKE'));
  return noChange(b, ground, `${said}; a REVERSION is queued under it`, queue('REVERSION'));
}

const PR_FIELDS = ['pr', 'pr_number', 'merged_pr'];
const GATE_RULE = /label:gate-(critical|regression)$/;

function parentOf(b: Base): TicketIn['parent'] {
  const { input, q } = b;
  const required = input.required_parent?.[q.key];
  const followed = ev(q).follow_up_of;
  const key = required ?? (typeof followed === 'string' && followed ? followed : null);
  return key ? { key, versions: heldOf(input, snapOf(input, key)), remainder: required === key } : null;
}

function ticketOf(b: Base): TicketIn {
  const { input, q, snap } = b;
  const e = ev(q);
  const C = input.current;
  const declared = (v: string | null): v is string => v !== null && input.versions.includes(v);
  const chief = e.chief_placement as { reason?: unknown } | undefined;
  const marked = typeof e.rule === 'string' && e.rule.includes('residual-label:');
  const held = snap?.labels ?? [];
  const labels = marked && !isResidual(held) ? [...held, 'residual-depth-0'] : held;
  const gate = typeof e.rule === 'string' ? GATE_RULE.exec(e.rule)?.[1] : undefined;
  return {
    priority: snap?.priority ?? '', labels, type: snap?.type ?? '', statusCategory: snap?.statusCategory ?? null,
    ask: operatorAsk({ labels, priority: snap?.priority ?? '', open: true, evidence: q.evidence })
      ? { named: q.to_v, by: labels.includes('operator-directed') ? 'label' : 'pointer' } : null,
    parent: parentOf(b),
    chief: chief && typeof chief === 'object' ? { target: q.to_v, reason: String(chief.reason ?? 'the chief placed it') } : null,
    finished: terminalOf(snap) !== null && PR_FIELDS.some((k) => e[k] !== undefined && e[k] !== null)
      ? { target: declared(q.to_v) ? q.to_v : C, status: snap?.status ?? 'closed' } : null,
    gate: gate === 'critical' || gate === 'regression' ? gate : null,
  };
}

/** What `placeByRules` says for this INTAKE, before the door turns it into a ground. A missing `frozen` reads as frozen. */
export function doorPlacement(input: JudgeInput, q: RequestRow, only?: ReadonlySet<Rule>): Placement | null {
  const snap = snapOf(input, q.key);
  return placeByRules(ticketOf({ input, q, snap, held: heldOf(input, snap) }), { current: input.current, versions: input.versions, frozen: input.frozen ?? true }, only);
}

function place(b: Base, only?: ReadonlySet<Rule>): Placed | null {
  const { input, q } = b;
  const p = doorPlacement(input, q, only);
  if (!p) return null;
  const C = input.current;
  const prio = b.snap?.priority || 'no';
  if (p.propose) {
    return { rule: 'M', target: null, ground: 'door:mild', reason: `${prio} priority goes to the backlog; it proposes ${p.propose}, which only the chief or the operator's words place` };
  }
  switch (p.rule) {
    case 'Ch': return { rule: 'Ch', target: p.target, ground: 'door:chief', reason: p.reason };
    case 'F': return { rule: 'F', target: p.target, ground: 'door:done', reason: `${q.key} is ${p.reason}` };
    case 'A':
      if (p.ask === 'default') return { rule: 'A', target: p.target, ground: 'door:operator-ask', reason: p.reason };
      return { rule: 'A', target: p.target, ground: p.ask === 'undeclared' ? `door:operator-undeclared:${p.arg}` : `door:operator-ask:${p.arg}`, reason: p.reason };
    case 'S': return { rule: 'S', target: p.target, ground: `door:rest-of:${p.arg}`, reason: p.reason };
    case 'W': return { rule: 'W', target: p.target, ground: 'door:started', reason: `${q.key} is In Progress` };
    case 'H': return { rule: 'H', target: p.target, ground: `door:serious:${p.arg}`, reason: p.reason };
    case 'L': return { rule: 'L', target: p.target, ground: `door:label:${p.arg}`, reason: `${p.arg} places ${q.key} in ${C}` };
    default: return { rule: 'M', target: null, ground: 'door:mild', reason: p.reason };
  }
}

const TOWARD = new Set<Rule>(['Ch', 'F', 'A', 'S', 'W']);

function clamp(b: Base, p: Placed): DoorResult {
  const W = b.held[0] ?? null;
  if (p.ground.startsWith('door:operator-undeclared:')) return noChange(b, p.ground, p.reason);
  if (W === null) {
    if (p.target === null) return decision(b, 'BACKLOG', { kind: 'none', from_v: null, to_v: null }, p.ground, p.reason);
    return decision(b, 'ADMIT', { kind: 'add', from_v: null, to_v: p.target }, p.ground, p.reason);
  }
  if (p.target !== null && TOWARD.has(p.rule) && earlierThan(b.input, p.target, W)) {
    return decision(b, 'ADMIT', { kind: 'move', from_v: W, to_v: p.target }, p.ground, `${p.reason}; moves toward current from ${W}`);
  }
  return decision(b, 'ADMIT', { kind: 'add', from_v: null, to_v: W }, `door:stays:${W}`, `stays in ${W}; ${p.reason}`, { rule: p.rule } as Partial<RuledDecision>);
}

function operatorStanding(b: Base, d: DoorResult): string | null {
  if (d.outcome === 'REFUSE') return null;
  const r = d as RuledDecision;
  if (r.op === 'none' || r.authority === 'operator') return null;
  const op: Op = { kind: r.op, from_v: r.from, to_v: r.to };
  const touched = new Set([op.from_v, op.to_v, b.held[0] ?? null].filter((v): v is string => v !== null && b.input.versions.includes(v)));
  for (const v of touched) {
    if (!effectOn(op, v)) continue;
    const id = b.input.records.find((x) => x.key === b.q.key && x.version === v)?.ruling;
    const prior = id ? b.input.rulings.find((x) => x.id === id) : undefined;
    if (prior?.authority.kind !== 'operator') continue;
    const since = ruledAt(b.input, prior);
    const newer = b.input.operator.some((o) => o.kind === 'decision' && (o.keys ?? []).includes(b.q.key)
      && [o.from_v, o.to_v].includes(v) && Date.parse(o.ts) > since);
    if (!newer) return prior.id;
  }
  return null;
}

export function apartFrom(input: JudgeInput, q: RequestRow, d: RuledDecision): { parent: string; parent_version: string } | null {
  const parent = input.required_parent?.[q.key];
  if (!parent || d.op === 'none') return null;
  const held = new Set(heldOf(input, snapOf(input, q.key)));
  if (d.op === 'move' || d.op === 'remove') { if (d.from) held.delete(d.from); }
  if ((d.op === 'add' || d.op === 'move') && d.to) held.add(d.to);
  const mine = input.versions.find((v) => held.has(v)) ?? null;
  const psnap = snapOf(input, parent);
  const pv = psnap ? parentVersion(input, parent) : null;
  if (psnap && pv !== null && pv === mine) return null;
  return { parent, parent_version: !psnap ? 'unknown' : pv ?? 'none' };
}

function withApart(b: Base, d: DoorResult, kind: 'A' | 'O'): DoorResult {
  if (d.outcome === 'REFUSE') return d;
  const r = d as RuledDecision & { rule?: Rule };
  const apart = apartFrom(b.input, b.q, r);
  const { rule: _r, ...rest } = r;
  if (!apart) return rest;
  const ground = `door:${kind === 'A' ? 'operator-ask' : 'operator'}-apart:${apart.parent}@${apart.parent_version}`;
  return { ...rest, ground, reason: `${r.reason}; the key ends in ${r.to ?? r.from ?? 'backlog'}, its parent ${apart.parent} in ${apart.parent_version}` };
}

function strip(d: DoorResult): DoorResult {
  if (d.outcome === 'REFUSE') return d;
  const { rule: _r, ...rest } = d as RuledDecision & { rule?: Rule };
  return rest;
}

function repair(b: Base): DoorResult {
  const { q, input } = b;
  const keeps = (why: string) => noChange(b, 'door:repair-keeps', why);
  if (q.verb === 'INTAKE') {
    if (q.to_v === null || !input.versions.includes(q.to_v)) return keeps(`repair names ${vName(q.to_v)}, outside the release`);
    return decision(b, 'ADMIT', { kind: 'add', from_v: null, to_v: q.to_v }, 'door:repair', `records ${q.to_v} as Jira shows it`);
  }
  if (q.verb !== 'REVERSION' || q.to_v === null) return keeps('a repair never moves a key to a later version or the backlog');
  const vr = q.to_v;
  if (q.from_v === null) return decision(b, 'MOVE', { kind: 'move', from_v: null, to_v: vr }, 'door:repair', `restores ${vr}`);
  if (earlierThan(input, vr, q.from_v)) return decision(b, 'MOVE', { kind: 'move', from_v: q.from_v, to_v: vr }, 'door:repair', `restores ${vr} from ${q.from_v}`);
  return decision(b, 'MOVE', { kind: 'move', from_v: vr, to_v: q.from_v }, 'door:repair-keeps', `the key stays in ${q.from_v}, nearer current than ${vr}`);
}

function reversion(b: Base): DoorResult {
  const { q, input } = b;
  if (q.to_v !== null && earlierThan(input, q.to_v, q.from_v)) {
    const p = place(b, TOWARD);
    if (p && p.target !== null && !earlierThan(input, q.to_v, p.target)) {
      return decision(b, 'MOVE', { kind: 'move', from_v: q.from_v, to_v: q.to_v }, p.ground, p.reason);
    }
    const T = p && p.target !== null && earlierThan(input, p.target, q.from_v) ? p.target : q.from_v;
    return noChange(b, `door:target:${vName(T)}`, `the rules keep ${q.key} at ${vName(T)}, not ${q.to_v}`);
  }
  return noChange(b, 'door:only-operator-moves-out', `only the operator moves ${q.key} out of ${vName(q.from_v)}`);
}

function discharge(b: Base): DoorResult {
  const t = terminalOf(b.snap);
  if (t === null || b.q.from_v === null) return noChange(b, 'door:not-resolved', `${b.q.key} is ${b.snap?.status ?? 'unknown'}, not resolved`);
  return decision(b, 'ACCEPT', { kind: 'discharge', from_v: b.q.from_v, to_v: b.q.from_v }, `door:resolved:${b.snap?.status ?? t}`, `${b.q.key} is ${t}`);
}

export function doorDecide(input: JudgeInput, q: RequestRow): DoorResult {
  const snap = snapOf(input, q.key);
  const b: Base = { input, q, snap, held: heldOf(input, snap) };
  if (ev(q).rule === 'version-repair' && q.from === 'repair') return standing(b, repair(b));
  const rec = operatorRecord(input, q);
  if (rec) return withApart(b, ruleO(b, rec), 'O');
  if (q.verb === 'REVERSION') return standing(b, reversion(b));
  if (q.verb === 'DISCHARGE') return standing(b, discharge(b));
  const p = place(b) as Placed;
  const d = standing(b, clamp(b, p));
  return p.rule === 'A' && !d.ground.startsWith('door:operator-standing:') ? withApart(b, d, 'A') : strip(d);
}

function standing(b: Base, d: DoorResult): DoorResult {
  const id = operatorStanding(b, d);
  if (!id) return d;
  const ground = `door:operator-standing:${id}`;
  const reason = `${id} placed ${b.q.key} on the operator's word; only a newer operator record changes it`;
  return b.q.verb === 'REVERSION' ? { req: b.q.req, outcome: 'REFUSE', ground, reason } : noChange(b, ground, reason);
}

export const doorJudge: Judge = async (input) => input.requests.map((q) => doorDecide(input, q));
