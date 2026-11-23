import { describe, it, expect } from 'vitest';
import { effectiveSigner, outranks, parentOf, signerOf, voidingTicket, type SignerState } from './signer.js';
import type { IssueSnap, OperatorRow } from './types.js';

const snap = (key: string, type = 'Task', parent?: string): IssueSnap => ({
  key, status: 'To Do', type, priority: 'Medium', fixVersions: [], resolution: null, ...(parent ? { parent } : {}),
});

const rec = (id: string, ts: string, signer: 'chief' | 'operator', decision: string, keys?: string[]): OperatorRow => ({
  id, kind: 'spec-signer', ts, decision, signer, ...(keys ? { keys } : {}),
});

const sig = (id: string, ts: string, keys: string[], o: Partial<OperatorRow> = {}): OperatorRow => ({
  id, kind: 'spec', ts, decision: '387', keys, ...o,
});

const issues = new Map<string, IssueSnap>([
  ['P-1', snap('P-1')],
  ['S-1', snap('S-1', 'Sub-task', 'P-1')],
  ['S-2', snap('S-2', 'Subtask', 'P-1')],
  ['K-1', snap('K-1')],
]);

const state = (records: OperatorRow[]): SignerState => ({ records, unreadable: null, issues });

const T0 = '2026-11-01T00:00:00.000Z';
const T1 = '2026-11-02T00:00:00.000Z';
const T2 = '2026-11-03T00:00:00.000Z';

describe('signer precedence (I5, I7, I11, I12, I18)', () => {
  it('parentOf gives a sub-task its parent and every other type null', () => {
    expect(parentOf(issues.get('S-1'))).toBe('P-1');
    expect(parentOf(issues.get('S-2'))).toBe('P-1');
    expect(parentOf(issues.get('K-1'))).toBeNull();
    expect(parentOf(undefined)).toBeNull();
  });

  it('signerOf reads operator only for a key in operator_keys of an operator row', () => {
    expect(signerOf(sig('O-1', T0, ['K-1', 'K-2'], { signer: 'operator', operator_keys: ['K-1'] }), 'K-1')).toBe('operator');
    expect(signerOf(sig('O-1', T0, ['K-1', 'K-2'], { signer: 'operator', operator_keys: ['K-1'] }), 'K-2')).toBe('chief');
    expect(signerOf(sig('O-1', T0, ['K-1'], { signer: 'chief' }), 'K-1')).toBe('chief');
    expect(signerOf(sig('O-1', T0, ['K-1']), 'K-1')).toBe('chief');
  });

  it('own key record beats the parent\'s; a parent mark applies to a sub-task with none', () => {
    const mark = rec('M-P', T0, 'operator', '1170', ['P-1']);
    const lift = rec('L-S', T1, 'chief', '1171', ['S-1']);
    const s = state([mark, lift]);
    expect(effectiveSigner('S-1', T2, s)).toEqual({ signer: 'chief', governing: 'default' });
    expect(effectiveSigner('S-2', T2, s)).toEqual({ signer: 'operator', governing: mark });
    expect(effectiveSigner('P-1', T2, s)).toEqual({ signer: 'operator', governing: mark });
    expect(effectiveSigner('K-1', T2, s)).toEqual({ signer: 'chief', governing: 'default' });
  });

  it('a lift returns to the station default and never exempts from a station operator default', () => {
    const station = rec('ST', T0, 'operator', '1100');
    const lift = rec('L-K', T1, 'chief', '1172', ['K-1']);
    expect(effectiveSigner('K-1', T2, state([station, lift]))).toEqual({ signer: 'operator', governing: station });
  });

  it('a station record governs only rows at or after it', () => {
    const station = rec('ST', T1, 'operator', '1100');
    const s = state([station]);
    expect(effectiveSigner('K-1', T0, s)).toEqual({ signer: 'chief', governing: 'default' });
    expect(effectiveSigner('K-1', T1, s)).toEqual({ signer: 'operator', governing: station });
    expect(effectiveSigner('K-1', T2, s)).toEqual({ signer: 'operator', governing: station });
  });

  it('a mark governs earlier rows of its ticket too', () => {
    const mark = rec('M-K', T2, 'operator', '1170', ['K-1']);
    expect(effectiveSigner('K-1', T0, state([mark]))).toEqual({ signer: 'operator', governing: mark });
  });

  it('an unreadable state, or a key absent from the mirror while a key record exists, reads unreadable', () => {
    expect(effectiveSigner('K-1', T0, { records: [], unreadable: 'release R2: broken chain', issues: null }))
      .toEqual({ unreadable: 'release R2: broken chain' });
    const mark = rec('M-P', T0, 'operator', '1170', ['P-1']);
    expect(effectiveSigner('X-9', T1, state([mark]))).toEqual({ unreadable: expect.stringMatching(/X-9 is not in the Jira mirror/) });
    expect(effectiveSigner('X-9', T1, state([rec('ST', T0, 'operator', '1100')]))).toEqual({ signer: 'operator', governing: expect.objectContaining({ id: 'ST' }) });
  });

  it('outranks compares a lift with K\'s own and parent\'s records, a station record with the newest station record, and a signature with K\'s own, its parent\'s and the station\'s records', () => {
    const parentMark = rec('M-P', T0, 'operator', '1170', ['P-1']);
    const ownMark = rec('M-S', T0, 'operator', '1180', ['S-1']);
    const station = rec('ST', T0, 'operator', '1190');
    const s = state([parentMark, ownMark, station]);
    expect(outranks('1175', 'lift', 'S-1', T1, s)).toBe(false);
    expect(outranks('1181', 'lift', 'S-1', T1, s)).toBe(true);
    expect(outranks('1185', 'lift', 'S-1', T1, s)).toBe(true);
    expect(outranks('1171', 'lift', 'S-2', T1, s)).toBe(true);
    expect(outranks('1170', 'lift', 'S-2', T1, s)).toBe(false);
    expect(outranks('1189', 'station', null, T1, s)).toBe(false);
    expect(outranks('1191', 'station', null, T1, s)).toBe(true);
    expect(outranks('1185', 'signature', 'S-1', T1, s)).toBe(false);
    expect(outranks('1191', 'signature', 'S-1', T1, s)).toBe(true);
    expect(outranks('1189', 'signature', 'S-1', '2026-10-01T00:00:00.000Z', s)).toBe(true);
    expect(outranks('1191', 'signature', 'S-1', T1, { ...s, unreadable: 'broken' })).toBe(false);
    expect(outranks('not-a-number', 'station', null, T1, s)).toBe(false);
  });

  it('words from a newer parent mark that name the sub-task do not outrank for the sub-task\'s operator signature', () => {
    const ownMark = rec('M-S', T0, 'operator', '1170', ['S-1']);
    const newerParentMark = rec('M-P', T1, 'operator', '1200', ['P-1']);
    const s = state([ownMark, newerParentMark]);
    expect(outranks('1200', 'signature', 'S-1', T2, s)).toBe(false);
    expect(outranks('1201', 'signature', 'S-1', T2, s)).toBe(true);
  });

  it('voidingTicket gives the first covered ticket at operator that the row and signedForSpec do not sign, and null when signedForSpec signs it', () => {
    const mark = rec('M-V', T0, 'operator', '1170', ['V-1']);
    const s: SignerState = { records: [mark], unreadable: null, issues: new Map([['V-1', snap('V-1')], ['K-3', snap('K-3')]]) };
    const row = sig('O-2', T1, ['K-3']);
    expect(voidingTicket(row, ['K-3', 'V-1'], T1, s, () => false)).toEqual({ ticket: 'V-1', governing: mark });
    expect(voidingTicket(row, ['K-3', 'V-1'], T1, s, (t) => t === 'V-1')).toBeNull();
    const signed = sig('O-3', T1, ['V-1', 'K-3'], { signer: 'operator', operator_keys: ['V-1'] });
    expect(voidingTicket(signed, ['V-1', 'K-3'], T1, s, () => false)).toBeNull();
    expect(voidingTicket(row, ['K-3', 'X-9'], T1, s, () => false)).toEqual({ unreadable: expect.stringMatching(/X-9/) });
  });
});
