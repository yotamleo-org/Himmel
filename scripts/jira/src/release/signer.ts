import type { IssueSnap, OperatorRow } from './types.js';

/**
 * Every spec-signer record of every declared release, oldest first, and the mirror a parent
 * step reads. `unreadable` names why the records cannot be trusted; then no signer is known.
 */
export interface SignerState {
  records: OperatorRow[];
  unreadable: string | null;
  issues: Map<string, IssueSnap> | null;
}

export type Effective = { signer: 'chief' | 'operator'; governing: OperatorRow | 'default' } | { unreadable: string };

export function parentOf(snap: IssueSnap | undefined): string | null {
  return snap && /^sub-?task$/i.test(snap.type) && snap.parent ? snap.parent : null;
}

export function signerOf(row: OperatorRow, key: string): 'chief' | 'operator' {
  return row.signer === 'operator' && row.operator_keys?.includes(key) ? 'operator' : 'chief';
}

const isLift = (r: OperatorRow) => r.signer === 'chief';
const keyRecords = (key: string, s: SignerState) => s.records.filter((r) => r.keys?.includes(key));
const stationRecords = (s: SignerState) => s.records.filter((r) => !r.keys?.length);
const stationAt = (at: string, s: SignerState) => stationRecords(s).filter((r) => r.ts <= at).at(-1);

function parentStep(key: string, s: SignerState): { parent: string | null } | { unreadable: string } {
  if (!s.records.some((r) => r.keys?.length)) return { parent: null };
  const snap = s.issues?.get(key);
  if (!snap) return { unreadable: `${key} is not in the Jira mirror, so its parent's mark cannot be read` };
  return { parent: parentOf(snap) };
}

export function effectiveSigner(key: string, at: string, s: SignerState): Effective {
  if (s.unreadable) return { unreadable: s.unreadable };
  const own = keyRecords(key, s).at(-1);
  if (own && !isLift(own)) return { signer: 'operator', governing: own };
  if (!own) {
    const step = parentStep(key, s);
    if ('unreadable' in step) return step;
    const mark = step.parent ? keyRecords(step.parent, s).at(-1) : undefined;
    if (mark && !isLift(mark)) return { signer: 'operator', governing: mark };
  }
  const station = stationAt(at, s);
  if (station) return { signer: isLift(station) ? 'chief' : 'operator', governing: station };
  return { signer: 'chief', governing: 'default' };
}

/**
 * Whether a record or signature with this decision number outranks every record it must beat:
 * a lift K's own and its parent's records, a station record the newest station record, and a
 * signature K's own, its parent's and the station record in force at `at`.
 */
export function outranks(decision: string, scope: 'lift' | 'station' | 'signature', key: string | null, at: string, s: SignerState): boolean {
  const d = Number(decision);
  if (s.unreadable || !Number.isFinite(d)) return false;
  const beat: OperatorRow[] = [];
  if (scope === 'station') beat.push(...stationRecords(s).slice(-1));
  else {
    if (!key) return false;
    const snap = s.issues?.get(key);
    if (!snap && s.records.some((r) => r.keys?.length)) return false;
    const parent = parentOf(snap);
    beat.push(...keyRecords(key, s), ...(parent ? keyRecords(parent, s) : []));
    if (scope === 'signature') beat.push(...[stationAt(at, s)].filter((r): r is OperatorRow => !!r));
  }
  return beat.every((r) => Number.isFinite(Number(r.decision)) && d > Number(r.decision));
}

/**
 * The first covered ticket whose signer is the operator, that this row does not sign as the
 * operator and that signedForSpec does not sign: a chief row covering it does not count.
 */
export function voidingTicket(row: OperatorRow, tickets: string[], at: string, s: SignerState,
  signedForSpec: (ticket: string) => boolean): { ticket: string; governing: OperatorRow | 'default' } | { unreadable: string } | null {
  for (const t of tickets) {
    if (signerOf(row, t) === 'operator') continue;
    const e = effectiveSigner(t, at, s);
    if ('unreadable' in e) return e;
    if (e.signer === 'operator' && !signedForSpec(t)) return { ticket: t, governing: e.governing };
  }
  return null;
}
