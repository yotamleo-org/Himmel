import { isSerious } from './operator-work.js';

export type Rule = 'Ch' | 'F' | 'A' | 'S' | 'W' | 'H' | 'L' | 'P' | 'M';

export interface TicketIn {
  priority: string;
  labels: string[];
  type: string;
  statusCategory: string | null;
  /** An operator ask: `named` is the version the operator named (never `backlog`), `by` how the ask was made. */
  ask: { named: string | null; by: 'label' | 'pointer' | 'words' } | null;
  /** The parent of a follow-up; a `--residual-of` is not a parent here. */
  parent: { key: string; versions: string[]; remainder: boolean } | null;
  /** The door's Ch and F inputs; create passes null for both. */
  chief: { target: string | null; reason: string } | null;
  finished: { target: string | null; status: string } | null;
  gate: 'critical' | 'regression' | null;
}

export interface ReleaseIn {
  current: string;
  versions: string[];
  frozen: boolean;
}

export interface Placement {
  rule: Rule;
  /** A declared version, or null for the backlog. */
  target: string | null;
  /** Set when the rules only propose current and never place the ticket there: a label or gate in a frozen current or on a residual (rule L), or a follow-up of a current parent (rule P). Only the chief or the operator's words place it. */
  propose?: string;
  /** The rule's argument: a version, a priority, a parent key, a label or `gate-<g>`, or the ask's `by`. */
  arg: string;
  reason: string;
  /** Rule A only: no version named, a declared one, or one the release does not declare. */
  ask?: 'default' | 'named' | 'undeclared';
  /** Rule L only: the ticket is a residual, so the label or gate only proposes. */
  residual?: boolean;
}

const L_LABELS = ['red-main', 'regression', 'update-item'];
const RESIDUAL_DEPTH = /^residual-depth-\d+$/;

/** A residual is a ticket carrying `residual-depth-<n>`; the plain `residual` label is on every follow-up too. */
export const isResidual = (labels: string[]): boolean => labels.some((l) => RESIDUAL_DEPTH.test(l));

/** The one pure function that places a ticket by the standing rules, first match wins; each caller turns `rule` and `arg` into its own ground string. */
export function placeByRules(t: TicketIn, rel: ReleaseIn, only?: ReadonlySet<Rule>): Placement | null {
  const C = rel.current;
  const try_ = (r: Rule): boolean => !only || only.has(r);
  const declared = (v: string | null): v is string => v !== null && rel.versions.includes(v);
  if (try_('Ch') && t.chief) return { rule: 'Ch', target: t.chief.target, arg: 'chief', reason: t.chief.reason };
  if (try_('F') && t.finished) {
    return { rule: 'F', target: t.finished.target, arg: 'done', reason: `${t.finished.status} with a merged PR` };
  }
  if (try_('A') && t.ask) {
    const named = t.ask.named !== null && t.ask.named !== C ? t.ask.named : null;
    if (named === null) return { rule: 'A', target: C, arg: t.ask.by, ask: 'default', reason: `an operator ask that names no version goes to ${C}` };
    if (!declared(named)) {
      return { rule: 'A', target: null, arg: named, ask: 'undeclared', reason: `the operator named ${named}, which the release does not declare` };
    }
    return { rule: 'A', target: named, arg: named, ask: 'named', reason: `the operator named ${named}` };
  }
  const pv = t.parent?.remainder ? rel.versions.find((v) => t.parent?.versions.includes(v)) ?? null : null;
  if (try_('S') && t.parent && pv) {
    return { rule: 'S', target: pv, arg: t.parent.key, reason: `the rest of ${t.parent.key}, which is in ${pv}` };
  }
  if (try_('W') && t.statusCategory === 'In Progress') return { rule: 'W', target: C, arg: 'started', reason: 'it is In Progress' };
  if (try_('H') && isSerious(t.priority)) return { rule: 'H', target: C, arg: t.priority, reason: `${t.priority} priority goes to ${C}` };
  const label = L_LABELS.find((l) => t.labels.includes(l)) ?? (t.type === 'Bug' && t.labels.includes('user-facing') ? 'user-facing' : null);
  const lArg = label ?? (t.gate ? `gate-${t.gate}` : null);
  if (try_('L') && lArg) {
    if (isResidual(t.labels)) {
      return { rule: 'L', target: null, propose: C, arg: lArg, residual: true, reason: `${lArg} on a residual proposes ${C}; it never places one` };
    }
    if (rel.frozen) return { rule: 'L', target: null, propose: C, arg: lArg, reason: `${lArg} proposes ${C}, which is frozen` };
    return { rule: 'L', target: C, arg: lArg, reason: `${lArg} goes to ${C}` };
  }
  if (try_('P') && t.parent && !t.parent.remainder && t.parent.versions.includes(C)) {
    return { rule: 'P', target: null, propose: C, arg: t.parent.key, reason: `a follow-up of ${t.parent.key}, which is in ${C}, proposes ${C}` };
  }
  if (try_('M')) return { rule: 'M', target: null, arg: t.priority || 'no', reason: `${t.priority || 'no'} priority goes to the backlog` };
  return null;
}

export interface CreateFacts {
  priority: string;
  labels: string[];
  type: string;
  gate?: 'critical' | 'regression' | null;
  /** `--proposed-version`; `backlog` is never read as a named version. */
  proposedVersion?: string | null;
  /** The bridge's operator-update pointer. */
  pointer?: boolean;
  /** Verified `--decision` and `--words`. */
  words?: boolean;
  parent?: { key: string; versions: string[]; remainder: boolean } | null;
}

/** Create's input builder: a new ticket is To Do, never chief-placed and never finished. */
export function ticketFromCreate(f: CreateFacts): TicketIn {
  const by = f.labels.includes('operator-directed') ? 'label' : f.pointer ? 'pointer' : f.words ? 'words' : null;
  const named = f.proposedVersion && f.proposedVersion !== 'backlog' ? f.proposedVersion : null;
  return {
    priority: f.priority, labels: f.labels, type: f.type, statusCategory: 'To Do',
    ask: by ? { named, by } : null, parent: f.parent ?? null, chief: null, finished: null, gate: f.gate ?? null,
  };
}

/** Whether the declaration's current version is frozen: a verified baseline holds it. The one freeze reader for create and the door. */
export function currentFrozen(l: { decl: { current: string }; baselines: Array<{ version: string }> }): boolean {
  return l.baselines.some((b) => b.version === l.decl.current);
}
