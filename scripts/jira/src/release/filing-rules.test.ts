import { describe, it, expect } from 'vitest';
import { currentFrozen, placeByRules, ticketFromCreate, type CreateFacts, type ReleaseIn, type TicketIn } from './filing-rules.js';

const C = 'v1.1.3';
const N = 'v1.1.4';
const rel = (o: Partial<ReleaseIn> = {}): ReleaseIn => ({ current: C, versions: [C, N], frozen: false, ...o });
const facts = (o: Partial<CreateFacts> = {}): CreateFacts => ({ priority: 'Medium', labels: [], type: 'Task', ...o });
const place = (o: Partial<CreateFacts> = {}, r: Partial<ReleaseIn> = {}) => placeByRules(ticketFromCreate(facts(o)), rel(r));
const core = (o: Partial<CreateFacts> = {}, r: Partial<ReleaseIn> = {}) => {
  const p = place(o, r);
  return p && { rule: p.rule, target: p.target, propose: p.propose, arg: p.arg };
};

describe('placeByRules: the rules in order, first match wins (D1)', () => {
  it('M: a mild ticket goes to the backlog, whatever the next version is (Q1)', () => {
    for (const priority of ['Medium', 'Low', 'Lowest', '']) {
      expect(core({ priority })).toEqual({ rule: 'M', target: null, propose: undefined, arg: priority || 'no' });
    }
  });

  it('H: High and Highest go to current', () => {
    for (const priority of ['High', 'Highest']) expect(core({ priority })).toMatchObject({ rule: 'H', target: C, arg: priority });
  });

  it('A: an operator ask names none (current), a declared version, or an undeclared one', () => {
    expect(core({ labels: ['operator-directed'] })).toMatchObject({ rule: 'A', target: C, arg: 'label' });
    expect(core({ labels: ['operator-directed'], proposedVersion: N })).toMatchObject({ rule: 'A', target: N, arg: N });
    expect(core({ labels: ['operator-directed'], proposedVersion: C })).toMatchObject({ rule: 'A', target: C, arg: 'label' });
    expect(core({ labels: ['operator-directed'], proposedVersion: 'v9.9.9' })).toMatchObject({ rule: 'A', target: null, arg: 'v9.9.9' });
    expect(place({ labels: ['operator-directed'], proposedVersion: 'v9.9.9' })?.ask).toBe('undeclared');
    expect(place({ labels: ['operator-directed'], proposedVersion: N })?.ask).toBe('named');
    expect(place({ labels: ['operator-directed'] })?.ask).toBe('default');
  });

  it('A: the bridge pointer and the verified words are asks too; proposedVersion backlog is never a named version (I8)', () => {
    expect(core({ pointer: true })).toMatchObject({ rule: 'A', target: C, arg: 'pointer' });
    expect(core({ words: true })).toMatchObject({ rule: 'A', target: C, arg: 'words' });
    expect(core({ labels: ['operator-directed'], proposedVersion: 'backlog' })).toMatchObject({ rule: 'A', target: C, arg: 'label' });
    expect(core({ proposedVersion: N })).toMatchObject({ rule: 'M' });
  });

  it('S: a remainder follow-up goes with its parent, when the parent holds a declared version', () => {
    const parent = { key: 'K-1', versions: [N], remainder: true };
    expect(core({ parent })).toMatchObject({ rule: 'S', target: N, arg: 'K-1' });
    expect(core({ parent: { ...parent, versions: [] } })).toMatchObject({ rule: 'M' });
    expect(core({ parent: { ...parent, versions: ['v0.9'] } })).toMatchObject({ rule: 'M' });
  });

  it('S beats H and L: a remainder of a parent in v1.1.4 is placed there', () => {
    expect(core({ priority: 'High', labels: ['regression'], parent: { key: 'K-1', versions: [N], remainder: true } })).toMatchObject({ rule: 'S', target: N });
  });

  it('W: In Progress goes to current', () => {
    const t: TicketIn = { ...ticketFromCreate(facts()), statusCategory: 'In Progress' };
    expect(placeByRules(t, rel())).toMatchObject({ rule: 'W', target: C });
  });

  it('L: a label or a gate places a mild ticket in an unfrozen current', () => {
    for (const label of ['red-main', 'regression', 'update-item']) {
      expect(core({ labels: [label] })).toEqual({ rule: 'L', target: C, propose: undefined, arg: label });
    }
    expect(core({ gate: 'critical' })).toMatchObject({ rule: 'L', target: C, arg: 'gate-critical' });
    expect(core({ gate: 'regression' })).toMatchObject({ rule: 'L', target: C, arg: 'gate-regression' });
    expect(core({ type: 'Bug', labels: ['user-facing'] })).toMatchObject({ rule: 'L', target: C, arg: 'user-facing' });
    expect(core({ type: 'Task', labels: ['user-facing'] })).toMatchObject({ rule: 'M' });
  });

  it('L: in a frozen current it only proposes', () => {
    expect(core({ labels: ['regression'] }, { frozen: true })).toEqual({ rule: 'L', target: null, propose: C, arg: 'regression' });
    expect(core({ gate: 'critical' }, { frozen: true })).toMatchObject({ rule: 'L', target: null, propose: C });
  });

  it('L on a residual only proposes, frozen or not (MA); the plain residual label does not make a residual', () => {
    const residual = ['residual', 'residual-depth-1'];
    expect(core({ labels: [...residual, 'regression'] })).toMatchObject({ rule: 'L', target: null, propose: C });
    expect(place({ labels: [...residual, 'regression'] })?.residual).toBe(true);
    expect(core({ labels: ['residual', 'regression'] })).toMatchObject({ rule: 'L', target: C, propose: undefined });
    expect(core({ gate: 'critical', labels: residual }, { frozen: true })).toMatchObject({ rule: 'L', target: null, propose: C });
  });

  it('A and H still place a residual (the grounds the door writes rm-admit for)', () => {
    expect(core({ priority: 'High', labels: ['residual-depth-1'] })).toMatchObject({ rule: 'H', target: C });
    expect(core({ labels: ['residual-depth-1', 'operator-directed'] })).toMatchObject({ rule: 'A', target: C });
  });

  it('P: a non-remainder follow-up of a parent holding current proposes current', () => {
    const parent = { key: 'K-1', versions: [C], remainder: false };
    expect(core({ parent })).toEqual({ rule: 'P', target: null, propose: C, arg: 'K-1' });
    expect(core({ parent: { ...parent, versions: [N] } })).toMatchObject({ rule: 'M' });
    expect(core({ parent, priority: 'High' })).toMatchObject({ rule: 'H' });
  });

  it('L comes before P (MB): a labelled follow-up of a current parent goes to an unfrozen current, and proposes in a frozen one', () => {
    const parent = { key: 'K-1', versions: [C], remainder: false };
    expect(core({ parent, labels: ['residual', 'regression'] })).toMatchObject({ rule: 'L', target: C, propose: undefined });
    expect(core({ parent, labels: ['regression'] }, { frozen: true })).toMatchObject({ rule: 'L', target: null, propose: C });
  });

  it('a Ch or F input wins over everything, and only= restricts the rules that run', () => {
    const base = ticketFromCreate(facts({ priority: 'High' }));
    expect(placeByRules({ ...base, chief: { target: N, reason: 'because' } }, rel())).toMatchObject({ rule: 'Ch', target: N, reason: 'because' });
    expect(placeByRules({ ...base, finished: { target: C, status: 'Done' } }, rel())).toMatchObject({ rule: 'F', target: C });
    expect(placeByRules(base, rel(), new Set(['Ch', 'F', 'A', 'S', 'W']))).toBeNull();
    expect(placeByRules(base, rel(), new Set(['H']))).toMatchObject({ rule: 'H' });
  });
});

describe('currentFrozen', () => {
  it('is true when a verified baseline holds the declaration current', () => {
    const l = { decl: { current: C }, baselines: [{ version: C }] };
    expect(currentFrozen(l)).toBe(true);
    expect(currentFrozen({ decl: { current: N }, baselines: [{ version: C }] })).toBe(false);
    expect(currentFrozen({ decl: { current: C }, baselines: [] })).toBe(false);
  });
});
