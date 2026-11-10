import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, bucketCheck, operatorWords, poolCurrent, claim, coreBypass, declare, fold, freeze, leaseAcquire, reopen, leaseRelease, operatorDecision, request, rule, state, takeover, withdraw,
  JudgeReplyError, LIVE_LOOKUP_MS, coreSnapshot, pull, readMirror, readOperatorRecords, rmRun, rmRunSummary, signSpec, specCheck, standing,
  type Ctx, type JiraPort, type Judge,
} from './engine.js';
import { execFileSync, spawnSync } from 'node:child_process';
import { Command } from 'commander';

// A hook that runs after a minerva script returns, to edit the spec mid-sign.
const afterMinerva = vi.hoisted(() => ({ fn: null as null | (() => void) }));
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const execFileSync = ((...a: Parameters<typeof m.execFileSync>) => {
    const r = m.execFileSync(...a);
    if (String((a[1] as string[] | undefined)?.[0] ?? '').endsWith('minerva-trace-lint.sh')) afterMinerva.fn?.();
    return r;
  }) as typeof m.execFileSync;
  return { ...m, execFileSync };
});
import type { EventRow, IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';
import type { Getter } from './version-writes.js';
import { appendAdmission, readAdmissions } from '../commands/admissions-ledger.js';
import { appendChain, breakStaleLock, loadKey, readChain, withLockAsync, writeSigned } from './ledger.js';

class FakeJira implements JiraPort {
  fv = new Map<string, string[]>();
  live = new Map<string, IssueSnap>();
  async issue(key: string) { return this.live.get(key) ?? null; }
  comments = new Map<string, Array<{ id: string; body: string }>>();
  posted = 0;
  entries = new Map<string, string>();
  entryCalls = 0;
  entryFails = false;
  async newestFixVersionEntry(key: string) {
    this.entryCalls++;
    if (this.entryFails) throw new Error('entry read down');
    return { id: this.entries.get(key) ?? 'create', ts: '' };
  }
  writes = 0;
  lbl = new Map<string, string[]>();
  labelPuts: Array<{ key: string; labels: string[] }> = [];
  stuck = new Set<string>();
  async labels(key: string) { return [...(this.lbl.get(key) ?? [])]; }
  async removeLabels(key: string, labels: string[]) {
    this.labelPuts.push({ key, labels: [...labels] });
    this.lbl.set(key, (this.lbl.get(key) ?? []).filter((x) => !labels.includes(x) || this.stuck.has(x)));
  }
  async fixVersions(key: string) { return [...(this.fv.get(key) ?? [])]; }
  async setFixVersion(key: string, op: 'add' | 'remove', v: string) {
    this.writes++;
    const cur = this.fv.get(key) ?? [];
    this.fv.set(key, op === 'add' ? [...new Set([...cur, v])] : cur.filter((x) => x !== v));
  }
  async findComment(key: string, marker: string) {
    return this.comments.get(key)?.find((c) => c.body.includes(marker))?.id ?? null;
  }
  async addComment(key: string, body: string) {
    this.posted++;
    const id = String(1000 + this.posted);
    this.comments.set(key, [...(this.comments.get(key) ?? []), { id, body }]);
    return id;
  }
}

let root: string;
let jira: FakeJira;
const DOC = '/abs/rm-doc.md';
const consoleEnv = {};
const rmEnv = { HIMMEL_RELEASE_MANAGER: '1', HIMMEL_CONSOLE_LEG: '1', HIMMEL_RM_DOC: DOC, HIMMEL_RM_RELEASE: 'R1' };

function ctx(env: Record<string, string> = consoleEnv): Ctx {
  return {
    release: 'R1', dir: join(root, 'release', 'R1'), keyPath: join(root, 'keys', 'R1.key'),
    env, now: () => new Date('2026-10-21T10:00:00.000Z'), jira, mirrorRoot: join(root, 'mirror'),
  };
}

function mirror(issues: Array<{ key: string; fixVersions: string[]; status?: string; category?: string; resolution?: string; sector?: string; type?: string; blockedBy?: string[] }>, lastSync = '2026-10-21T09:00:00.000Z') {
  const dir = join(root, 'mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync, total: issues.length }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, `type: "${i.type ?? 'Task'}"`, `status: "${i.status ?? 'To Do'}"`,
      ...(i.category ? [`statusCategory: "${i.category}"`] : []), 'priority: "Medium"',
      ...(i.sector ? [`sector: "${i.sector}"`] : []),
      `fixVersions: ${JSON.stringify(i.fixVersions)}`, `resolution: ${i.resolution ? JSON.stringify(i.resolution) : 'null'}`,
      'links:', '  blocks: []', `  blocked_by: ${JSON.stringify(i.blockedBy ?? [])}`, '  relates: []',
      '---', '', `# ${i.key}`, '',
    ].join('\n'));
  }
}

async function setup() {
  declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  freeze(ctx(), { version: 'v1', keys: ['K-1'], decision: '104', verbatim: 'frozen at 1' });
  leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
}

const admit = (req: string, extra: Partial<Parameters<typeof rule>[1]> = {}) => rule(ctx(rmEnv), {
  req, outcome: 'ADMIT', op: { kind: 'add', from_v: null, to_v: 'v1' }, sector: 'Planning & tracking',
  ground: 'regression', reason: 'breaks the console', supersedes: [], authority: { kind: 'rm', ref: null }, ...extra,
});

// Applies a ruling with Jira failing before the receipt, then replays it from the applied phase.
async function applyThenReplay(id: string) {
  const post = jira.addComment.bind(jira);
  jira.addComment = async () => { throw new Error('jira down before the receipt'); };
  await expect(apply(ctx(rmEnv), id)).rejects.toThrow('jira down');
  jira.addComment = post;
  return apply(ctx(rmEnv), id);
}

const savedLedger = process.env.HIMMEL_ADMISSIONS_LEDGER;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'release-engine-'));
  jira = new FakeJira();
  process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
});

afterEach(() => {
  vi.unstubAllEnvs();
  if (savedLedger === undefined) delete process.env.HIMMEL_ADMISSIONS_LEDGER;
  else process.env.HIMMEL_ADMISSIONS_LEDGER = savedLedger;
});

describe('release state admissions_today', () => {
  const decide = (c: Ctx, decision: string, keys: string[], op: string, from_v: string | null, to_v: string | null) =>
    operatorDecision(c, { decision, keys, op, from_v, to_v, verbatim: 'x' });

  it('counts the keys of today\'s operator decisions that add or move into each version', async () => {
    await setup();
    expect(state(ctx()).admissions_today).toEqual({ v1: 0, v2: 0 });
    decide({ ...ctx(), now: () => new Date('2026-10-20T10:00:00.000Z') }, '100', ['K-7'], 'add', null, 'v1');
    decide(ctx(), '101', ['K-8', 'K-9'], 'add', null, 'v1');
    decide(ctx(), '102', ['K-6'], 'move', 'v1', 'v2');
    decide(ctx(), '103', ['K-5'], 'remove', 'v1', null);
    decide(ctx(), '104', ['K-4'], 'keep', 'v1', 'v1');
    expect(state(ctx()).admissions_today).toEqual({ v1: 2, v2: 1 });
  });

  it('is empty for a release that does not verify', () => {
    expect(state(ctx()).admissions_today).toEqual({});
  });
});

describe('release engine', () => {
  it('runs request → claim → rule → apply to a receipted RULING line and an applied membership', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    expect(q.req).toBe('Q-R1-0001');
    expect(claim(ctx(rmEnv)).map((r) => r.req)).toEqual(['Q-R1-0001']);
    const r = admit(q.req);
    expect(r).toMatchObject({ id: 'R-R1-0001', phase: 'intent', class: 'current' });
    const out = await apply(ctx(rmEnv), r.id);
    expect(out.line).toBe('RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=Planning & tracking — regression: breaks the console');
    expect(out.phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual(['v1']);

    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1'] }], '2026-10-21T11:00:00.000Z');
    const s = state(ctx());
    expect(s.records.find((x) => x.key === 'K-2' && x.version === 'v1')).toMatchObject({ placement: 'in', ruling: 'R-R1-0001' });
    expect(s.leaks).toEqual({ unauthorized: [], ruled_in_non_member: [] });
    expect(s.trend['2026-10-21']).toEqual({ ruled: 1 });
  });

  it('an applied INTAKE ADMIT appends one rm-admit ledger row, and a replay adds no second', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    await apply(ctx(rmEnv), r.id);
    await apply(ctx(rmEnv), r.id);
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows).toMatchObject([{ version: 'v1', key: 'K-2', kind: 'rm-admit', reason: 'regression: breaks the console', by: 'rm-1' }]);
  });

  it('apply goes on past a bad line in the admissions ledger and still receipts', async () => {
    await setup();
    writeFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'not json\n');
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean);
    expect(rows.filter((l) => l.includes('"rm-admit"'))).toHaveLength(1);
  });

  it('a re-admission after a removal appends a second rm-admit row, and its replay adds no third', async () => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    await apply(ctx(rmEnv), r1.id);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    await apply(ctx(rmEnv), r2.id);
    expect(jira.fv.get('K-2')).toEqual([]);
    const q3 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r3 = admit(q3.req, { supersedes: [r2.id] });
    await apply(ctx(rmEnv), r3.id);
    await apply(ctx(rmEnv), r3.id);
    await apply(ctx(rmEnv), r2.id);
    expect(rows().map((r) => [r.kind, r.key, r.version, r.ruling])).toEqual([
      ['rm-admit', 'K-2', 'v1', r1.id],
      ['rm-remove', 'K-2', 'v1', r2.id],
      ['rm-admit', 'K-2', 'v1', r3.id],
    ]);
  });

  it.each([
    ['frozen', 'v2', 'v1'],
    ['unfrozen', 'v1', 'v2'],
  ])('a REVERSION MOVE into a %s version appends the destination rm-admit and the source rm-remove, and an applied-phase replay adds none', async (_kind, from, to) => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    jira.fv.set('K-2', [from]);
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: from, to_v: to, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: from, to_v: to } });
    expect((await applyThenReplay(r.id)).phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual([to]);
    expect(rows().map((x) => [x.kind, x.key, x.version, x.ruling])).toEqual([
      ['rm-admit', 'K-2', to, r.id],
      ['rm-remove', 'K-2', from, r.id],
    ]);
  });

  it('an INTAKE ADMIT replayed from the applied phase appends no second rm-admit row', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    expect((await applyThenReplay(r.id)).phase).toBe('receipted');
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows.map((x) => [x.kind, x.key, x.version, x.ruling])).toEqual([['rm-admit', 'K-2', 'v1', r.id]]);
  });

  describe('proposed-* labels close with their ruling', () => {
    const intake = (key = 'K-2') => {
      const q = request(ctx(), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      return q;
    };

    it('an applied INTAKE ADMIT removes every proposed-* label and keeps backlog and the rest', async () => {
      await setup();
      jira.lbl.set('K-2', ['backlog', 'proposed-v1.2', 'proposed-v2', 'phase:build', 'held', 'scope-v1']);
      const r = admit(intake().req);
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.labelPuts).toEqual([{ key: 'K-2', labels: ['proposed-v1.2', 'proposed-v2'] }]);
      expect(jira.lbl.get('K-2')).toEqual(['backlog', 'phase:build', 'held', 'scope-v1']);
    });

    it.each([
      ['BACKLOG', { kind: 'none' as const, from_v: null, to_v: null }],
      ['AD-HOC', { kind: 'none' as const, from_v: null, to_v: null }],
    ])('an applied INTAKE %s ruling clears the label too', async (outcome, op) => {
      await setup();
      jira.lbl.set('K-2', ['backlog', 'proposed-backlog']);
      const r = admit(intake().req, { outcome, op });
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.lbl.get('K-2')).toEqual(['backlog']);
    });

    it('a replay and an already-clean ticket make no label write', async () => {
      await setup();
      jira.lbl.set('K-2', ['proposed-v1.2']);
      const r = admit(intake().req);
      expect((await applyThenReplay(r.id)).phase).toBe('receipted');
      await apply(ctx(rmEnv), r.id);
      expect(jira.labelPuts).toHaveLength(1);

      const r3 = admit(intake('K-3').req);
      jira.lbl.set('K-3', ['backlog']);
      await apply(ctx(rmEnv), r3.id);
      expect(jira.labelPuts).toHaveLength(1);
    });

    it('a label Jira still reports after the remove fails the apply, names it, and posts no receipt', async () => {
      await setup();
      jira.lbl.set('K-2', ['proposed-v1.2']);
      jira.stuck.add('proposed-v1.2');
      const r = admit(intake().req);
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/K-2.*proposed-v1\.2/);
      expect(jira.posted).toBe(0);
      jira.stuck.clear();
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.lbl.get('K-2')).toEqual([]);
    });

    it('a non-INTAKE verb leaves every label alone', async () => {
      await setup();
      jira.lbl.set('K-1', ['proposed-v1', 'backlog']);
      const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.labelPuts).toEqual([]);
      expect(jira.lbl.get('K-1')).toEqual(['proposed-v1', 'backlog']);
    });
  });

  it('an INTAKE ADMIT with an unwritable ledger refuses before Jira is touched', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    writeFileSync(join(root, 'not-a-dir'), 'a file where the ledger directory should be');
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'not-a-dir', 'ledger.jsonl');
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow();
    expect(jira.fv.get('K-2')).toBeUndefined();
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('a REMOVE ruling with an unwritable ledger refuses before Jira is touched', async () => {
    await setup();
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    await apply(ctx(rmEnv), r1.id);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    writeFileSync(join(root, 'not-a-dir'), 'a file where the ledger directory should be');
    process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'not-a-dir', 'ledger.jsonl');
    await expect(apply(ctx(rmEnv), r2.id)).rejects.toThrow();
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('replaying an applied ruling that a later applied ruling superseded appends no ledger row', async () => {
    await setup();
    const rows = () => readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const q1 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r1 = admit(q1.req);
    const post = jira.addComment.bind(jira);
    jira.addComment = async () => { throw new Error('jira down before the receipt'); };
    await expect(apply(ctx(rmEnv), r1.id)).rejects.toThrow('jira down');
    jira.addComment = post;
    unlinkSync(process.env.HIMMEL_ADMISSIONS_LEDGER!);
    const q2 = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: null, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r2 = admit(q2.req, { outcome: 'MOVE', op: { kind: 'remove', from_v: 'v1', to_v: null }, supersedes: [r1.id] });
    await apply(ctx(rmEnv), r2.id);
    expect((await apply(ctx(rmEnv), r1.id)).phase).toBe('receipted');
    expect(rows().map((r) => [r.kind, r.key, r.version, r.ruling])).toEqual([['rm-remove', 'K-2', 'v1', r2.id]]);
  });

  it('a replayed apply never posts a second comment', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    await apply(ctx(rmEnv), r.id);
    await apply(ctx(rmEnv), r.id);
    expect(jira.posted).toBe(1);
  });

  it('refuses a reused request id', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    admit(q.req);
    expect(() => admit(q.req)).toThrow(/Q-R1-0001 is ruled:R-R1-0001/);
  });

  it('collapses a duplicate open request into the open one', async () => {
    await setup();
    const a = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    const b = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'again', evidence: {}, from: 'console' });
    expect(b.req).toBe(a.req);
  });

  it('refuses a ruling with no lease owner', () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'v', mode: 'observe' });
    expect(() => claim(ctx(rmEnv))).toThrow(/no lease owner/);
  });

  it('refuses a ruling from a session that is not the lease owner', async () => {
    await setup();
    expect(() => claim(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/other.md' }))).toThrow(/not the lease owner/);
    expect(() => claim(ctx({ HIMMEL_RM_DOC: DOC }))).toThrow(/HIMMEL_RELEASE_MANAGER/);
  });

  it('refuses a new ruling on a key while its intent is pending', async () => {
    await setup();
    const a = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    admit(a.req);
    const b = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'again', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(b.req)).toThrow(/K-2@v1 has a pending intent/);
  });

  it('refuses to freeze a baseline over a pending intent on a key it lists', async () => {
    await setup();
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
    const refreeze = () => freeze(ctx(), { version: 'v1', keys: ['K-1'], decision: '107', verbatim: 'refrozen' });
    expect(refreeze).toThrow(/R-R1-0001 is a pending intent on K-1@v1; apply or void it first/);
    expect(() => freeze(ctx(), { version: 'v2', keys: ['K-9'], decision: '107', verbatim: 'other key' })).not.toThrow();
    await apply(ctx(rmEnv), r.id);
    expect(refreeze().gen).toBe(2);
  });

  it('requires supersedes when a ruling is already in effect, baseline included', async () => {
    await setup();
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const move = { req: q.req, outcome: 'MOVE', op: { kind: 'move' as const, from_v: 'v1', to_v: 'v2' } };
    expect(() => admit(q.req, move)).toThrow(/supersedes must name baseline-v1-g1/);
    expect(admit(q.req, { ...move, supersedes: ['baseline-v1-g1'] }).class).toBe('next');
  });

  it('refuses an operator authority whose record does not cover the key', async () => {
    await setup();
    const o = operatorDecision(ctx(), { decision: '101', keys: ['K-9'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { authority: { kind: 'operator', ref: o.id } })).toThrow(/does not cover K-2/);
  });

  describe('a newer operator record supersedes an older operator-authority ruling', () => {
    const at = (iso: string): Ctx => ({ ...ctx(), now: () => new Date(iso) });
    const decide = (iso: string, op: string, from_v: string | null, to_v: string | null) =>
      operatorDecision(at(iso), { decision: '383', keys: ['K-2'], op, from_v, to_v, verbatim: 'pull it in' });
    const pull = { outcome: 'ADMIT', op: { kind: 'move' as const, from_v: 'v2', to_v: 'v1' } };

    // K-2 sits in v2 under an operator ruling made at 10:00; the pull request into v1 is claimed.
    async function placedInV2(decisions: () => void = () => {}) {
      await setup();
      const o = decide('2026-10-21T09:00:00.000Z', 'add', null, 'v2');
      const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req, { op: { kind: 'add', from_v: null, to_v: 'v2' }, authority: { kind: 'operator', ref: o.id } });
      await apply(ctx(rmEnv), r.id);
      decisions();
      const q2 = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: 'v2', to_v: 'v1', why: 'operator pulls it', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      return { prior: r.id, req: q2.req };
    }

    it('an INTAKE an RM ruling makes is admitted under the newer operator move, and Jira moves', async () => {
      const { prior, req } = await placedInV2();
      const o = decide('2026-10-21T11:00:00.000Z', 'move', 'v2', 'v1');
      const r = admit(req, { ...pull, supersedes: [prior] });
      expect(r.authority).toEqual({ kind: 'operator', ref: o.id });
      await apply(ctx(rmEnv), r.id);
      expect(jira.fv.get('K-2')).toEqual(['v1']);
    });

    it('with no newer operator record the RM ruling is still refused', async () => {
      const { prior, req } = await placedInV2();
      expect(() => admit(req, { ...pull, supersedes: [prior] })).toThrow(/carries operator authority; only an operator record supersedes it/);
    });

    it('an older operator record never supersedes a newer ruling, cited or not', async () => {
      const { prior, req } = await placedInV2();
      const old = decide('2026-10-21T08:00:00.000Z', 'move', 'v2', 'v1');
      expect(() => admit(req, { ...pull, supersedes: [prior] })).toThrow(/carries operator authority/);
      expect(() => admit(req, { ...pull, supersedes: [prior], authority: { kind: 'operator', ref: old.id } }))
        .toThrow(new RegExp(`${old.id} predates ${prior}`));
    });

    it('of two newer operator moves the newest by timestamp governs, whatever order they were written in', async () => {
      const { prior, req } = await placedInV2();
      const late = decide('2026-10-21T12:00:00.000Z', 'move', 'v2', 'v1');
      decide('2026-10-21T11:00:00.000Z', 'move', 'v2', 'v1');
      expect(admit(req, { ...pull, supersedes: [prior] }).authority).toEqual({ kind: 'operator', ref: late.id });
    });

    it('a newer operator decision that keeps the key wins over an older move, cited or not (CONFLICT)', async () => {
      let move!: OperatorRow;
      let keep!: OperatorRow;
      const { prior, req } = await placedInV2(() => {
        move = decide('2026-10-21T11:00:00.000Z', 'move', 'v2', 'v1');
        keep = decide('2026-10-21T12:00:00.000Z', 'keep', 'v2', 'v2');
      });
      const conflict = new RegExp(`CONFLICT K-2: ${keep.id} \\(newer\\) keep v2→v2`);
      expect(() => admit(req, { ...pull, supersedes: [prior] })).toThrow(conflict);
      expect(() => admit(req, { ...pull, supersedes: [prior], authority: { kind: 'operator', ref: move.id } })).toThrow(conflict);
    });

    describe('an operator restore of a key held under an older operator record', () => {
      const restoreTo = (to_v: string, from_v: string | null = null) => ({ outcome: 'MOVE', op: { kind: 'move' as const, from_v, to_v } });
      const restore = restoreTo('v2');
      const T = (hh: number) => `2026-10-21T${String(hh).padStart(2, '0')}:00:00.000Z`;

      // K-2 is placed in `v` under an operator ruling, then Jira drifts; a REVERSION to restore it is claimed.
      async function drifted(decisions: () => void, v = 'v2', verb: 'REVERSION' | 'INTAKE' = 'REVERSION', from_v: string | null = null) {
        await setup();
        const o = decide(T(9), 'add', null, v);
        const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: v, why: 'w', evidence: {}, from: 'console' });
        claim(ctx(rmEnv));
        const r = admit(q.req, { op: { kind: 'add', from_v: null, to_v: v }, authority: { kind: 'operator', ref: o.id } });
        await apply(ctx(rmEnv), r.id);
        jira.fv.set('K-2', []);
        decisions();
        const q2 = request(ctx(), { verb, key: 'K-2', from_v, to_v: v, why: 'operator restored it', evidence: {}, from: 'console' });
        claim(ctx(rmEnv));
        return { prior: r.id, req: q2.req };
      }

      const lastAdmission = () => readAdmissions('v2').filter((a) => a.key === 'K-2').at(-1);

      it('lands under the newest operator record that places the key, and the ruling reads in', async () => {
        let newest!: OperatorRow;
        const { prior, req } = await drifted(() => { newest = decide(T(11), 'add', null, 'v2'); });
        const r = admit(req, { ...restore, supersedes: [prior] });
        expect(r.authority).toEqual({ kind: 'operator', ref: newest.id });
        expect(r.op).toEqual({ kind: 'add', from_v: null, to_v: 'v2' });
        await apply(ctx(rmEnv), r.id);
        expect(jira.fv.get('K-2')).toEqual(['v2']);
        const s = state(ctx());
        expect(s.integrity).toEqual([]);
        expect(s.records.find((x) => x.key === 'K-2' && x.version === 'v2')).toMatchObject({ placement: 'in', ruling: r.id });
      });

      it('lands the same when the request cites the newest record', async () => {
        let newest!: OperatorRow;
        const { prior, req } = await drifted(() => { newest = decide(T(11), 'add', null, 'v2'); });
        const r = admit(req, { ...restore, supersedes: [prior], authority: { kind: 'operator', ref: newest.id } });
        expect(r.authority).toEqual({ kind: 'operator', ref: newest.id });
        expect(r.op).toEqual({ kind: 'add', from_v: null, to_v: 'v2' });
      });

      it('lands when a newer decision names another key', async () => {
        let newest!: OperatorRow;
        const { prior, req } = await drifted(() => {
          newest = decide(T(11), 'add', null, 'v2');
          operatorDecision(at(T(12)), { decision: '383', keys: ['K-9'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'another key' });
        });
        expect(admit(req, { ...restore, supersedes: [prior] }).authority).toEqual({ kind: 'operator', ref: newest.id });
      });

      it('lands when a newer core-bypass names the key, which places nothing', async () => {
        let newest!: OperatorRow;
        const { prior, req } = await drifted(() => {
          newest = decide(T(11), 'add', null, 'v2');
          coreBypass(at(T(12)), { keys: ['K-2'], decision: '451', verbatim: 'core bypass' });
        });
        expect(admit(req, { ...restore, supersedes: [prior] }).authority).toEqual({ kind: 'operator', ref: newest.id });
      });

      it('is still refused when the newest record contradicts the restore', async () => {
        let newest!: OperatorRow;
        const { prior, req } = await drifted(() => { newest = decide(T(11), 'remove', 'v2', null); });
        expect(() => admit(req, { ...restore, supersedes: [prior] })).toThrow(new RegExp(`CONFLICT K-2: ${newest.id} \\(newer\\) remove v2→backlog`));
      });

      it.each([
        ['an add to another version', 'add', null, 'v1'],
        ['a keep with no version', 'keep', null, null],
        ['a keep in another version', 'keep', 'v1', 'v1'],
      ])('is refused when %s is the operator\'s newer word on the key', async (_name, op, from_v, to_v) => {
        let placing!: OperatorRow;
        const { prior, req } = await drifted(() => { placing = decide(T(11), 'add', null, 'v2'); decide(T(12), op, from_v, to_v); });
        const conflict = new RegExp(`CONFLICT K-2: ${placing.id} \\(newer\\) add backlog→v2`);
        expect(() => admit(req, { ...restore, supersedes: [prior] })).toThrow(conflict);
        expect(() => admit(req, { ...restore, supersedes: [prior], authority: { kind: 'operator', ref: placing.id } })).toThrow(/does not cover K-2 move/);
        expect(jira.fv.get('K-2')).toEqual([]);
      });

      it('rewrites only a REVERSION: an INTAKE move under the same record is still refused', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'add', null, 'v2'); }, 'v2', 'INTAKE');
        expect(() => admit(req, { ...restore, outcome: 'ADMIT', supersedes: [prior] })).toThrow(/CONFLICT K-2: /);
      });

      it('rewrites only a move from backlog: a move from another version is still refused', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'add', null, 'v2'); }, 'v2', 'REVERSION', 'v1');
        expect(() => admit(req, { ...restoreTo('v2', 'v1'), supersedes: [prior] })).toThrow(/CONFLICT K-2: /);
      });

      it('keeps the op of a record that is not an add: a move record covers the move as it is', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'move', null, 'v2'); });
        expect(admit(req, { ...restore, supersedes: [prior] }).op).toEqual({ kind: 'move', from_v: null, to_v: 'v2' });
      });

      it('never lands under the standing emergency record: citing it stays refused', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'add', null, 'v1'); }, 'v1');
        expect(() => admit(req, { ...restoreTo('v1'), supersedes: [prior], authority: { kind: 'operator', ref: 'O-R1-emergency' } }))
          .toThrow(/O-R1-emergency does not cover K-2 move/);
      });

      it('records an rm-admit after an rm-remove, so the latest ledger row reads the key in', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'add', null, 'v2'); });
        appendAdmission({ version: 'v2', key: 'K-2', kind: 'rm-remove', reason: 'earlier removal', by: 'rm', ruling: 'R-R1-0099' });
        expect(lastAdmission()?.kind).toBe('rm-remove');
        const r = admit(req, { ...restore, supersedes: [prior] });
        await apply(ctx(rmEnv), r.id);
        expect(lastAdmission()).toMatchObject({ kind: 'rm-admit', ruling: r.id });
      });

      it('writes no Jira field when the admissions ledger cannot take the restore row', async () => {
        const { prior, req } = await drifted(() => { decide(T(11), 'add', null, 'v2'); });
        const r = admit(req, { ...restore, supersedes: [prior] });
        vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'a-dir-not-a-file'));
        mkdirSync(join(root, 'a-dir-not-a-file'));
        await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow();
        expect(jira.fv.get('K-2')).toEqual([]);
      });
    });
  });

  it('keeps operator acts and requests out of the RM and of chief-spawned workers', () => {
    expect(() => declare(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' }))
      .toThrow(/chief-spawned worker/);
    declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' });
    expect(() => request(ctx(rmEnv), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'rm' }))
      .toThrow(/the chief writes requests/);
  });

  it('fences the lease: wrong epoch, held lease and takeover', async () => {
    await setup();
    expect(() => leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 0, doc: '/abs/b.md', session: 'b' }))
      .toThrow(/epoch is 1, expected 0/);
    expect(() => leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' }))
      .toThrow(/held by \/abs\/rm-doc.md/);
    takeover(ctx(), { epoch: 1, doc: '/abs/b.md' });
    expect(leaseAcquire(ctx({ ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' }), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' }).epoch).toBe(2);
  });

  it('a successor voids an old-epoch intent Jira never saw and reopens its request', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    leaseRelease(ctx(rmEnv));
    const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/not the lease owner/);
    const out = await apply(ctx(next), r.id);
    expect(out.phase).toBe('void');
    expect(jira.fv.get('K-2')).toBeUndefined();
    expect(claim(ctx(next)).map((x) => x.req)).toEqual([q.req]);
  });

  it('a requests chain that does not verify leaves no void row', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    leaseRelease(ctx(rmEnv));
    const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
    const reqs = join(ctx().dir, 'requests.jsonl');
    writeFileSync(reqs, readFileSync(reqs, 'utf8').replaceAll('"why":"w"', '"why":"x"'));
    const rulings = join(ctx().dir, 'rulings.jsonl');
    const before = readFileSync(rulings, 'utf8');
    await expect(apply(ctx(next), r.id)).rejects.toThrow(/requests.jsonl does not verify/);
    expect(readFileSync(rulings, 'utf8')).toBe(before);
  });

  it('a tampered declaration makes the state UNKNOWN and refuses rulings', async () => {
    await setup();
    const p = join(root, 'release', 'R1', 'release.json');
    writeFileSync(p, readFileSync(p, 'utf8').replace('"v2"', '"v9"'));
    expect(state(ctx()).status).toBe('UNKNOWN');
    expect(() => claim(ctx(rmEnv))).toThrow(/UNKNOWN/);
  });

  it('an applied DISCHARGE keeps the fixVersion it discharges', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'ACCEPT', op: { kind: 'discharge', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] });
    await apply(ctx(rmEnv), r.id);
    expect(jira.fv.get('K-1')).toEqual(['v1']);
  });

  it('a DISCHARGE whose fixVersion is absent from Jira fails its readback', async () => {
    await setup();
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'ACCEPT', op: { kind: 'discharge', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] });
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/readback does not match/);
  });

  it('a rejected DISCHARGE supersedes nothing and leaves the baseline in', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    const q = request(ctx(), { verb: 'DISCHARGE', key: 'K-1', from_v: 'v1', to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { outcome: 'REJECT', op: { kind: 'none', from_v: 'v1', to_v: 'v1' }, supersedes: ['baseline-v1-g1'] }))
      .toThrow(/supersedes nothing/);
    const r = admit(q.req, { outcome: 'REJECT', op: { kind: 'none', from_v: 'v1', to_v: 'v1' } });
    await apply(ctx(rmEnv), r.id);
    const s = state(ctx());
    expect(s.leaks.unauthorized).toEqual([]);
    expect(s.burndown.v1.baseline).toBe(1);
  });

  it('a successor never voids an old-epoch move Jira half applied', async () => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
    jira.fv.set('K-1', []);
    leaseRelease(ctx(rmEnv));
    const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
    await expect(apply(ctx(next), r.id)).rejects.toThrow(/partly applied/);
    expect(claim(ctx(next))).toEqual([]);
  });

  it('an emergency ruling may cite the standing emergency record', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'red main', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(admit(q.req, { authority: { kind: 'operator', ref: 'O-R1-emergency' } }).id).toBe('R-R1-0001');
  });

  it('declares observe only: live waits for the activation barrier', () => {
    expect(() => declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'live' }))
      .toThrow(/activation barrier/);
  });

  it('a long async lock holder keeps its lock fresh and never unlinks a successor', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    await withLockAsync(dir, async () => {
      await new Promise((r) => setTimeout(r, 300));
      expect(Date.now() - statSync(lock).mtimeMs).toBeLessThan(200);
      unlinkSync(lock);
      writeFileSync(lock, 'another writer');
    }, 1000, 200);
    expect(readFileSync(lock, 'utf8')).toBe('another writer');
  });

  it('a second breaker never unlinks the successor\'s fresh lock', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    let successorIno = 0;
    breakStaleLock(lock, 60_000, () => {
      // another breaker wins the race: it breaks the stale lock and takes a fresh one
      unlinkSync(lock);
      closeFd(openSync(lock, 'wx'));
      successorIno = statSync(lock).ino;
    });
    expect(statSync(lock).ino).toBe(successorIno);
  });

  it('a breaker leaves the lock in place while another breaker holds the break mutex', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    writeFileSync(`${lock}.break`, 'another breaker');
    const ino = statSync(lock).ino;
    breakStaleLock(lock, 60_000);
    expect(statSync(lock).ino).toBe(ino);
  });

  it('a break removes the stale lock and leaves no mutex or tombstone behind', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-lock-'));
    const lock = join(dir, '.lock');
    writeFileSync(lock, 'crashed writer');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lock, old, old);
    breakStaleLock(lock, 60_000);
    expect(readdirSync(dir)).toEqual([]);
  });

  it.skipIf(process.getuid?.() === 0)('a crash between the applied row and its event is repaired by the retry', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    const events = join(root, 'release', 'R1', 'events.jsonl');
    writeFileSync(events, '', { mode: 0o444 });
    chmodSync(events, 0o444);
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow();
    chmodSync(events, 0o644);
    const out = await apply(ctx(rmEnv), r.id);
    expect(out.phase).toBe('receipted');
    const ruled = readFileSync(events, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
      .filter((e) => e.kind === 'ruled' && e.ruling === r.id);
    expect(ruled).toHaveLength(1);
  });

  it('a frozen baseline is immutable: editing it breaks verification', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    expect(state(ctx()).burndown.v1.baseline).toBe(1);
    const p = join(root, 'release', 'R1', 'baseline-v1-g1.json');
    writeFileSync(p, readFileSync(p, 'utf8').replace('"K-1"', '"K-8"'));
    expect(state(ctx()).status).toBe('UNKNOWN');
  });
});

describe('release fold', () => {
  const events = () => readFileSync(join(root, 'release', 'R1', 'events.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const closedDone = { status: 'Closed', category: 'Done', resolution: 'Done' };
  const resync = '2026-10-21T11:00:00.000Z';

  it('reads a Closed key as terminal Done, so it leaves the open burn-down', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'], ...closedDone }], resync);
    const s = state(ctx());
    expect(s.records.find((x) => x.key === 'K-1')).toMatchObject({ terminal: 'Done' });
    expect(s.burndown.v1.baseline_open).toBe(0);
  });

  it('writes one verifying events row per key, and a folded Closed key is bookkeeping, not a leak', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    expect(state(ctx()).leaks.unauthorized).toEqual(['K-3@v1']);
    const out = fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(out.skipped).toEqual([]);
    expect(events()).toMatchObject([{ kind: 'fold', key: 'K-3', from: null, to: 'v1', pr: 12 }]);
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'], ...closedDone }], resync);
    const s = state(ctx());
    expect(s.inputs.events).toBe('FRESH');
    expect(s.records.find((x) => x.key === 'K-3')).toMatchObject({ terminal: 'Done', bookkeeping: 'fold:12' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('skips a key that cannot fold and names its terminal and resolution; it stays a leak', async () => {
    await setup();
    const all = [
      { key: 'K-3', fixVersions: ['v1'], ...closedDone },
      { key: 'K-4', fixVersions: ['v1'], status: 'Closed', category: 'Done', resolution: "Won't Do" },
      { key: 'K-5', fixVersions: ['v1'], status: 'Closed', category: 'Done', resolution: 'Cannot Reproduce' },
      { key: 'K-6', fixVersions: ['v1'] },
    ];
    mirror(all);
    const out = fold(ctx(), { to: 'v1', items: ['K-3', 'K-4', 'K-5', 'K-6', 'K-9'].map((key) => ({ key, pr: 7 })) });
    expect(out.folded.map((e) => e.key)).toEqual(['K-3']);
    expect(out.skipped).toEqual([
      { key: 'K-4', terminal: "Won't Do", resolution: "Won't Do" },
      { key: 'K-5', terminal: 'Other', resolution: 'Cannot Reproduce' },
      { key: 'K-6', terminal: 'open', resolution: 'none' },
      { key: 'K-9', terminal: 'not-in-mirror', resolution: 'none' },
    ]);
    expect(events().map((e) => e.key)).toEqual(['K-3']);
    mirror(all, resync);
    expect(state(ctx()).leaks.unauthorized).toEqual(['K-4@v1', 'K-5@v1', 'K-6@v1']);
  });

  it('a re-run folds nothing twice', async () => {
    await setup();
    mirror([{ key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    const again = fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(again).toMatchObject({ folded: [], already: ['K-3'], skipped: [] });
    expect(events()).toHaveLength(1);
  });

  it('reopen reverses a fold and refuses a key with no fold to reverse', async () => {
    await setup();
    const all = [{ key: 'K-3', fixVersions: ['v1'], ...closedDone }];
    mirror(all);
    expect(() => reopen(ctx(), { key: 'K-3', from: 'v1' })).toThrow(/no fold into v1/);
    fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] });
    expect(reopen(ctx(), { key: 'K-3', from: 'v1' })).toMatchObject({ kind: 'reopen', key: 'K-3', from: 'v1', to: null });
    mirror(all, resync);
    const s = state(ctx());
    expect(s.inputs.events).toBe('FRESH');
    expect(s.leaks.unauthorized).toEqual(['K-3@v1']);
  });

  it('is a console act on a declared version with a real PR number', async () => {
    await setup();
    mirror([{ key: 'K-3', fixVersions: ['v1'], ...closedDone }]);
    expect(() => fold(ctx(rmEnv), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] })).toThrow(/chief act/);
    expect(() => fold(ctx(), { to: 'v9', items: [{ key: 'K-3', pr: 12 }] })).toThrow(/not a version/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 0 }] })).toThrow(/positive PR/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 2 ** 60 }] })).toThrow(/positive PR/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'bad key', pr: 1 }] })).toThrow(/not an issue key/);
    expect(() => fold(ctx(), { to: 'v1', items: [{ key: 'K-3', pr: 12 }] })).not.toThrow();
  });
});

describe('rm-run: the on-demand release manager', () => {
  const declared = () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  };
  const ask = (k: string) => request(ctx(), { verb: 'INTAKE', key: k, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  const admitAll: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const snapshot = (dir: string): Record<string, string> => Object.fromEntries(
    readdirSync(dir, { recursive: true, withFileTypes: true }).filter((e) => e.isFile())
      .map((e) => { const p = join(e.parentPath, e.name); return [p, readFileSync(p, 'utf8')]; }),
  );

  it('rules a pending request with no standing session and releases the lease', async () => {
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), admitAll);
    expect(lines).toContain('RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=Ship loop — regression: breaks the console');
    expect(jira.fv.get('K-2')).toEqual(['v1']);
    const s = state(ctx());
    expect(s.lease).toMatchObject({ epoch: 1, released: true });
    expect(s.requests).toEqual({ open: [], claimed: [], oldest_open: null });
  });

  it('refuses a concurrent batch by the lease and rules nothing in it', async () => {
    declared();
    ask('K-2');
    let inner: unknown;
    await rmRun(ctx(), async (input) => {
      inner = await rmRun(ctx(), admitAll).catch((e: Error) => e);
      return admitAll(input);
    });
    expect(String(inner)).toMatch(/release lease: held by/);
    expect(readFileSync(join(ctx().dir, 'rulings.jsonl'), 'utf8').match(/"phase":"intent"/g)).toHaveLength(1);
  });

  it('exits on an empty queue with nothing written and no judge call', async () => {
    declared();
    const before = snapshot(ctx().dir);
    let called = false;
    expect(await rmRun(ctx(), async () => { called = true; return []; })).toEqual(['RM-RUN R1: nothing pending']);
    expect(called).toBe(false);
    expect(snapshot(ctx().dir)).toEqual(before);
  });

  const failsClean = async (run: Promise<string[]>, cause: RegExp, doc: string) => {
    await expect(run).rejects.toThrow(cause);
    const s = state(ctx());
    expect(s.lease).toMatchObject({ epoch: 1, released: true });
    expect(s.requests).toMatchObject({ open: ['Q-R1-0001'], claimed: [] });
    expect(readFileSync(doc, 'utf8')).toMatch(new RegExp(`^- FAILED: .*${cause.source}`, 'm'));
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
    expect(state(ctx()).lease).toMatchObject({ epoch: 2, released: true });
  };
  const hangs: Judge = (_input, o) => new Promise((_, reject) => {
    const killed = () => reject(new Error('The operation was aborted'));
    if (o?.signal?.aborted) killed();
    else o?.signal?.addEventListener('abort', killed, { once: true });
  });

  it('a stopped run waits for its killed judge to finish its own cleanup before it fails', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'settle.md');
    let cleaned = false;
    const slow: Judge = (_input, o) => new Promise((_, reject) => {
      o?.signal?.addEventListener('abort', () => setTimeout(() => { cleaned = true; reject(new Error('killed')); }, 100), { once: true });
    });
    await failsClean(rmRun(ctx(), slow, { doc, judgeTimeoutMs: 50 }).finally(() => expect(cleaned).toBe(true)), /did not answer within/, doc);
  }, 4000);

  it('a judge that throws returns its claims to open, frees the lease and the next run rules them', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'threw.md');
    await failsClean(rmRun(ctx(), async () => { throw new Error('HOLD'); }, { doc }), /HOLD/, doc);
  });

  it('a judge that never answers is stopped at the deadline, with its signal aborted, and fails the same way', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'hung.md');
    let seen: AbortSignal | undefined;
    const hung: Judge = (_input, o) => { seen = o?.signal; return hangs(_input, o); };
    await failsClean(rmRun(ctx(), hung, { doc, judgeTimeoutMs: 50 }), /did not answer within/, doc);
    expect(seen?.aborted).toBe(true);
  }, 2000);

  it('a stop signal during the judge call fails the same way', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'stopped.md');
    const stop = new AbortController();
    const hung: Judge = (input, o) => { stop.abort(new Error('rm-run: stopped by SIGTERM')); return hangs(input, o); };
    await failsClean(rmRun(ctx(), hung, { doc, signal: stop.signal }), /stopped by SIGTERM/, doc);
  }, 2000);

  it('a run that died after its claim does not hold the lease for the next run', async () => {
    declared();
    ask('K-2');
    const dead = spawnSync('true').pid as number;
    const left = new AbortController();
    const died = rmRun(ctx(), hangs, { pid: dead, signal: left.signal }).catch((e: Error) => e);
    await vi.waitFor(() => expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']));
    expect(() => leaseAcquire(ctx(rmEnv), { expectEpoch: 1, doc: DOC, session: 'standing' })).toThrow(/release lease: held by/);
    const lines = await rmRun(ctx(), admitAll);
    expect(lines).toContainEqual(expect.stringMatching(new RegExp(`^RECLAIMED lease epoch 1: rm-run pid ${dead} on \\S+ is gone$`)));
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
    expect(state(ctx()).lease).toMatchObject({ epoch: 2, released: true });
    expect(readFileSync(join(ctx().dir, 'operator.jsonl'), 'utf8')).not.toMatch(/"kind":"takeover"/);
    left.abort(new Error('test over'));
    await died;
    expect(state(ctx()).lease).toMatchObject({ epoch: 2, released: true });
  }, 4000);

  it.each([
    ['a live pid', () => ({ owner_pid: process.pid })],
    ['another host', () => ({ owner_host: 'another-host' })],
    ['no pid, as a standing session holds it', () => ({ owner_pid: undefined, owner_host: undefined })],
  ])('a held lease naming %s is never reclaimed', async (_name, patch) => {
    declared();
    ask('K-2');
    const left = new AbortController();
    const held = rmRun(ctx(), hangs, { pid: spawnSync('true').pid as number, signal: left.signal }).catch((e: Error) => e);
    await vi.waitFor(() => expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']));
    const path = join(ctx().dir, 'lease.json');
    const { mac: _m, ...cur } = JSON.parse(readFileSync(path, 'utf8'));
    writeSigned(path, loadKey(ctx().keyPath), { ...cur, ...patch() });
    await expect(rmRun(ctx(), admitAll)).rejects.toThrow(/release lease: held by/);
    left.abort(new Error('test over'));
    await held;
  }, 4000);

  it('a stop between two applies keeps the first applied, returns the second, and the next run writes the first no second time', async () => {
    declared();
    ask('K-2');
    ask('K-3');
    const stop = new AbortController();
    const set = jira.setFixVersion.bind(jira);
    jira.setFixVersion = async (...a) => { await set(...a); stop.abort(new Error('rm-run: stopped by SIGTERM; nothing more ruled')); };
    await expect(rmRun(ctx(), admitAll, { signal: stop.signal })).rejects.toThrow(/stopped by SIGTERM/);
    expect(jira.writes).toBe(1);
    expect(jira.fv.get('K-2')).toEqual(['v1']);
    const phases = readFileSync(join(ctx().dir, 'rulings.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as RulingRow);
    expect(phases.filter((r) => r.id === 'R-R1-0001').at(-1)?.phase).toBe('receipted');
    expect(state(ctx()).requests).toMatchObject({ open: ['Q-R1-0002'], claimed: [] });
    jira.setFixVersion = set;
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0002 Q-R1-0002 INTAKE K-3 /));
    expect(jira.writes).toBe(2);
    expect(jira.fv.get('K-3')).toEqual(['v1']);
  });

  it('a judge reply the check refused is kept in the run doc with the failing field', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'rm-runs', 'refused.md');
    await expect(rmRun(ctx(), async () => { throw new JudgeReplyError('decision 0 field sector', '[{"req":"x"}]'); }, { doc }))
      .rejects.toThrow(/decision 0 field sector/);
    const text = readFileSync(doc, 'utf8');
    expect(text).toMatch(/decision 0 field sector/);
    expect(text).toContain('[{"req":"x"}]');
  });

  it('the judge sees the sector the mirror holds for a ticket', () => {
    const mirror = join(root, 'mirror-sector');
    mkdirSync(mirror, { recursive: true });
    writeFileSync(join(mirror, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T15:00:55.697Z' }));
    writeFileSync(join(mirror, 'K-9.md'), '---\nkey: "K-9"\ntype: "Task"\nstatus: "To Do"\npriority: "Medium"\nfixVersions: []\nresolution: null\nsector: "Ship loop"\n---\n');
    expect(readMirror(mirror).issues?.get('K-9')?.sector).toBe('Ship loop');
  });

  it('a decision the engine refuses is reported, its request is closed, and a re-file opens a new qid', async () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'customfield_10500');
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: '', ground: 'regression', reason: 'x',
    })));
    expect(lines).toEqual([expect.stringMatching(/^REFUSED Q-R1-0001: release rule: a ruling without a sector/)]);
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null });
    expect(ask('K-2').req).toBe('Q-R1-0002');
  });

  it('the run summary counts the refused requests, and a run with no refusal prints none', async () => {
    declared();
    ask('K-2');
    const refused = await rmRun(ctx(), async () => []);
    expect(rmRunSummary('R1', refused)).toBe('RM-RUN R1 summary: 1 refused');
    ask('K-3');
    const ruled = await rmRun(ctx(), admitAll);
    expect(ruled).toContainEqual(expect.stringMatching(/^RULING /));
    expect(rmRunSummary('R1', ruled)).toBeNull();
    expect(rmRunSummary('R1', ['PENDING R-R1-0002: release rule: REFUSED upstream'])).toBeNull();
  });

  it('a request the judge leaves out is reported and stays claimed for the next run', async () => {
    declared();
    ask('K-2');
    expect(await rmRun(ctx(), async () => [])).toEqual(['REFUSED Q-R1-0001: the judge returned no decision']);
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
  });

  it('with a Sector field configured the opt-out value is not a sector and the ruling refuses', async () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'customfield_10500');
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'none', ground: 'regression', reason: 'x',
    })));
    expect(lines).toEqual([expect.stringMatching(/^REFUSED Q-R1-0001: release rule: a ruling without a sector/)]);
    expect(state(ctx()).requests.claimed).toEqual([]);
  });

  it('with no Sector field configured a ruling without a sector carries sector=none and applies', async () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'none');
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: '', ground: 'regression', reason: 'x',
    })));
    expect(lines[0]).toMatch(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT current sector=none — regression: x/);
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('a HOLD decision is reported as HELD, rules nothing and leaves the request claimed', async () => {
    declared();
    ask('K-2');
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'HOLD', reason: 'no sector for K-2',
    })));
    expect(lines).toEqual(['HELD Q-R1-0001: no sector for K-2']);
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
    expect(existsSync(join(ctx().dir, 'rulings.jsonl'))).toBe(false);
  });

  it('offers the judge the live Jira snapshot of a claimed key the mirror lacks', async () => {
    declared();
    mirror([{ key: 'K-9', fixVersions: [] }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Ship loop' })]);
  });

  it('a mirror row without a sector is replaced by the live Jira snapshot', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [] }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Ship loop' })]);
  });

  it('a live lookup that never answers falls back to the mirror row once its deadline passes', async () => {
    vi.useFakeTimers();
    try {
      declared();
      mirror([{ key: 'K-2', fixVersions: [] }]);
      ask('K-2');
      jira.issue = () => new Promise<IssueSnap | null>(() => {});
      let seen: unknown;
      const run = rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
      await vi.advanceTimersByTimeAsync(LIVE_LOOKUP_MS);
      await run;
      expect(seen).toEqual([expect.objectContaining({ key: 'K-2' })]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('a mirror row with a sector is not re-read from Jira', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [], sector: 'Visibility' }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Visibility' })]);
  });

  it('a ruling Jira did not take is PENDING, and the next run applies it', async () => {
    declared();
    ask('K-2');
    const post = jira.addComment;
    jira.addComment = async () => { throw new Error('jira down'); };
    expect(await rmRun(ctx(), admitAll)).toEqual(['PENDING R-R1-0001: jira down']);
    jira.addComment = post;
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
  });

  it('writes the run record under a --doc parent that does not exist yet', async () => {
    declared();
    ask('K-2');
    const doc = join(ctx().dir, 'elsewhere', 'run.md');
    expect(await rmRun(ctx(), admitAll, { doc })).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 /));
    expect(readFileSync(doc, 'utf8')).toMatch(/^- RULING R-R1-0001 /m);
  });
});

describe('release withdraw', () => {
  const ask = (key: string, verb: 'INTAKE' | 'REVERSION', from_v: string | null, to_v: string | null) =>
    request(ctx(), { verb, key, from_v, to_v, why: 'found work', evidence: {}, from: 'console' });
  const decide = (keys: string[], op: string, from_v: string | null, to_v: string | null) =>
    operatorDecision(ctx(), { decision: '243', keys, op, from_v, to_v, verbatim: 'x' });

  it('withdraws an open request with a reason, and claim skips it', async () => {
    await setup();
    const q = ask('K-2', 'INTAKE', null, 'v1');
    expect(withdraw(ctx(), { req: q.req, reason: 'junk from a test run' }).state).toBe('withdrawn:console');
    expect(claim(ctx(rmEnv))).toEqual([]);
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null });
  });

  it('a withdrawn request does not swallow a fresh one for the same move', async () => {
    await setup();
    const q = ask('K-2', 'INTAKE', null, 'v1');
    withdraw(ctx(), { req: q.req, reason: 'junk from a test run' });
    expect(ask('K-2', 'INTAKE', null, 'v1').req).not.toBe(q.req);
  });

  it('--by needs a decision row covering the key', async () => {
    await setup();
    const q = ask('K-2', 'REVERSION', 'v1', null);
    const other = decide(['K-9'], 'keep', 'v1', 'v1');
    expect(() => withdraw(ctx(), { req: q.req, reason: 'stays', by: other.id })).toThrow(/does not cover K-2/);
    expect(() => withdraw(ctx(), { req: q.req, reason: 'stays', by: 'O-R1-9999' })).toThrow(/no verified decision/);
    const o = decide(['K-2'], 'remove', 'v1', null);
    expect(withdraw(ctx(), { req: q.req, reason: 'already removed', by: o.id }).state).toBe(`withdrawn:${o.id}`);
  });

  it('refuses a ruled request, a missing reason, the release manager and a console worker', async () => {
    await setup();
    const q = ask('K-2', 'INTAKE', null, 'v1');
    expect(() => withdraw(ctx(), { req: q.req, reason: ' ' })).toThrow(/--reason/);
    expect(() => withdraw(ctx(rmEnv), { req: q.req, reason: 'x' })).toThrow(/refused/);
    expect(() => withdraw(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { req: q.req, reason: 'x' })).toThrow(/refused/);
    claim(ctx(rmEnv));
    await apply(ctx(rmEnv), admit(q.req).id);
    expect(() => withdraw(ctx(), { req: q.req, reason: 'x' })).toThrow(/is ruled/);
  });

  it('an operator decision withdraws the open requests on its keys that contradict its placement', async () => {
    await setup();
    const out = ask('K-2', 'REVERSION', 'v1', null);
    const agrees = ask('K-3', 'INTAKE', null, 'v1');
    const elsewhere = ask('K-4', 'REVERSION', 'v1', null);
    const o = decide(['K-2', 'K-3'], 'keep', 'v1', 'v1');
    const claimed = claim(ctx(rmEnv)).map((r) => r.req);
    expect(claimed).toEqual([agrees.req, elsewhere.req]);
    expect(() => withdraw(ctx(), { req: out.req, reason: 'again' })).toThrow(new RegExp(`withdrawn:${o.id}`));
  });

  it('a requests chain that does not verify refuses the decision before its row is written', async () => {
    await setup();
    ask('K-2', 'REVERSION', 'v1', null);
    const reqs = join(ctx().dir, 'requests.jsonl');
    writeFileSync(reqs, readFileSync(reqs, 'utf8').replace('found work', 'found wark'));
    const ops = join(ctx().dir, 'operator.jsonl');
    const before = readFileSync(ops, 'utf8');
    expect(() => decide(['K-2'], 'keep', 'v1', 'v1')).toThrow(/requests.jsonl does not verify/);
    expect(readFileSync(ops, 'utf8')).toBe(before);
  });

  it('a decision on one version leaves a request that names only another version open', async () => {
    await setup();
    const other = ask('K-2', 'INTAKE', null, 'v2');
    const same = ask('K-2', 'REVERSION', 'v1', 'v2');
    const o = decide(['K-2'], 'remove', 'v1', null);
    expect(claim(ctx(rmEnv)).map((r) => r.req)).toEqual([other.req]);
    expect(() => withdraw(ctx(), { req: same.req, reason: 'again' })).toThrow(new RegExp(`withdrawn:${o.id}`));
  });
});

describe('rm-run bulk guard', () => {
  const overrideRows = () => {
    const p = process.env.HIMMEL_ADMISSIONS_LEDGER as string;
    return existsSync(p) ? readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l) as Record<string, string>).filter((r) => r.kind === 'override') : [];
  };
  const askMany = (n: number) => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    for (let i = 1; i <= n; i++) request(ctx(), { verb: 'INTAKE', key: `K-${100 + i}`, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  };
  const admitAll: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const rulings = (lines: string[]) => lines.filter((l) => l.startsWith('RULING '));

  it('refuses the 21st open move into the current version, unclaimed and pending for the next run', async () => {
    askMany(21);
    const lines = await rmRun(ctx(), admitAll);
    expect(rulings(lines)).toHaveLength(20);
    expect(lines).toContainEqual(expect.stringMatching(/^PENDING Q-R1-0021: bulk guard/));
    expect(jira.fv.get('K-121')).toBeUndefined();
    expect(state(ctx()).requests).toMatchObject({ open: ['Q-R1-0021'], claimed: [] });
    expect(overrideRows()).toEqual([]);
  });

  it('a run of exactly 20 passes unchanged', async () => {
    askMany(20);
    const lines = await rmRun(ctx(), admitAll);
    expect(rulings(lines)).toHaveLength(20);
    expect(lines.some((l) => /bulk guard/.test(l))).toBe(false);
    expect(state(ctx()).requests).toMatchObject({ open: [], claimed: [] });
  });

  it('closed tickets do not count toward the 20', async () => {
    askMany(21);
    mirror([{ key: 'K-121', fixVersions: [], status: 'Done', category: 'Done', resolution: 'Done' }]);
    expect(rulings(await rmRun(ctx(), admitAll))).toHaveLength(21);
  });

  it('--ruling passes the 21st and records the ref in the run output and in one ledger row', async () => {
    askMany(21);
    const lines = await rmRun(ctx(), admitAll, { ruling: '98' });
    expect(rulings(lines)).toHaveLength(21);
    expect(lines).toContain('bulk 21 lifted by ruling 98');
    expect(overrideRows()).toEqual([expect.objectContaining({ version: 'v1', key: 'rm-run:R1', ruling: '98', reason: expect.stringMatching(/21 .*lifted by ruling 98/) })]);
  });

  it('--ruling on a run of 20 lifts nothing, so it records nothing', async () => {
    askMany(20);
    const lines = await rmRun(ctx(), admitAll, { ruling: '98' });
    expect(rulings(lines)).toHaveLength(20);
    expect(lines.some((l) => /lifted by ruling/.test(l))).toBe(false);
    expect(overrideRows()).toEqual([]);
  });

  it('a chief override with the marker and a reason passes and writes one override row with the count', async () => {
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    askMany(21);
    const lines = await rmRun(ctx(), admitAll, { chiefOverride: 'operator ordered the reshuffle' });
    expect(rulings(lines)).toHaveLength(21);
    expect(overrideRows()).toEqual([expect.objectContaining({ version: 'v1', kind: 'override', reason: expect.stringMatching(/21 .*operator ordered the reshuffle/) })]);
  });

  it('a chief override without a reason or without the marker refuses before anything is claimed', async () => {
    askMany(21);
    await expect(rmRun(ctx(), admitAll, { chiefOverride: 'because' })).rejects.toThrow(/HIMMEL_CONSOLE=1/);
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    await expect(rmRun(ctx(), admitAll, { chiefOverride: '  ' })).rejects.toThrow(/needs a reason/);
    expect(state(ctx()).requests).toMatchObject({ claimed: [] });
    expect(overrideRows()).toEqual([]);
  });

  it('a replay of older unfinished rulings is not a move: the voided requests are counted once, when re-ruled', async () => {
    askMany(21);
    const set = jira.setFixVersion;
    jira.setFixVersion = async () => { throw new Error('jira down'); };
    await rmRun(ctx(), admitAll, { ruling: '98' });
    jira.setFixVersion = set;
    const lines = await rmRun(ctx(), admitAll);
    expect(lines.filter((l) => l.startsWith('VOID '))).toHaveLength(21);
    expect(rulings(lines)).toHaveLength(20);
    expect(lines).toContainEqual(expect.stringMatching(/^PENDING Q-R1-00\d\d: bulk guard/));
    expect(state(ctx()).requests).toMatchObject({ claimed: [] });
    expect(overrideRows()).toHaveLength(1);
  });

  it('an unreadable mirror aborts the run without leaving the lease held', async () => {
    askMany(2);
    mirror([]);
    mkdirSync(join(root, 'mirror', 'bad.md'));
    await expect(rmRun(ctx(), admitAll)).rejects.toThrow();
    rmSync(join(root, 'mirror', 'bad.md'), { recursive: true });
    expect(rulings(await rmRun(ctx(), admitAll))).toHaveLength(2);
  });

  it('operator-authority rulings with a ref are covered and do not count', async () => {
    askMany(21);
    const keys = Array.from({ length: 21 }, (_, i) => `K-${101 + i}`);
    const o = operatorDecision(ctx(), { decision: '243', keys, op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
    const viaOperator: Judge = async (input) => (await admitAll(input)).map((d) => ({ ...d, authority: 'operator' as const, ref: o.id }));
    expect(rulings(await rmRun(ctx(), viaOperator))).toHaveLength(21);
  });
});

describe('a blocker of a current-version ticket is pulled into the current version', () => {
  const at = (iso: string): Ctx => ({ ...ctx(), now: () => new Date(iso) });
  const noJudge: Judge = async () => { throw new Error('the judge must not be called for a blocker pull'); };
  const declared = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  // K-1 sits in v1 (the current version) and waits on K-2, which lives in v2.
  const scene = (extra: Parameters<typeof mirror>[0] = [], blocker: string[] = ['v2'], lastSync?: string) => {
    mirror([{ key: 'K-1', fixVersions: ['v1'], blockedBy: ['K-2'] }, { key: 'K-2', fixVersions: blocker, sector: 'Ship loop' }, ...extra], lastSync);
    jira.fv.set('K-1', ['v1']);
    jira.fv.set('K-2', blocker);
  };
  const rulingRows = () => readChain<RulingRow>(join(ctx().dir, 'rulings.jsonl'), loadKey(ctx().keyPath)).verified;

  it('queues one INTAKE for a v-next blocker, and a second run queues none', () => {
    declared();
    scene();
    const out = pull(ctx());
    expect(out.current).toBe('v1');
    expect(out.filed).toHaveLength(1);
    expect(out.filed[0]).toMatchObject({ key: 'K-2', verb: 'INTAKE', from_v: 'v2', to_v: 'v1', evidence: { blocks: ['K-1'], rule: 'blocker-pull' } });
    expect(out.filed[0].why).toContain('O-R1-blocker-pull');
    expect(pull(ctx()).filed).toEqual([]);
    expect(state(ctx()).requests.open).toEqual(['Q-R1-0001']);
  });

  it('the RM admits it under the standing rule with no model call, and Jira moves the blocker', async () => {
    declared();
    scene();
    pull(ctx());
    const lines = await rmRun(ctx(), noJudge);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-2 move v2→v1 ADMIT current sector=Ship loop — blocker-pull: /));
    expect(jira.fv.get('K-2')).toEqual(['v1']);
    expect(rulingRows().at(-1)?.authority).toEqual({ kind: 'operator', ref: 'O-R1-blocker-pull', blocks: ['K-1'] });
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null });
  });

  it('a blocker in the backlog is added, not moved', async () => {
    declared();
    scene([], []);
    expect(pull(ctx()).filed[0]).toMatchObject({ key: 'K-2', from_v: null, to_v: 'v1' });
    expect(await rmRun(ctx(), noJudge)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-2 add backlog→v1 ADMIT /));
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('two blocked tickets that share a blocker file one request naming both', () => {
    declared();
    scene([{ key: 'K-3', fixVersions: ['v1'], status: 'In Progress', blockedBy: ['K-2'] }]);
    const out = pull(ctx());
    expect(out.filed).toHaveLength(1);
    expect(out.filed[0].evidence).toEqual({ blocks: ['K-1', 'K-3'], rule: 'blocker-pull' });
  });

  it('files nothing for a blocker already in the version, a Done or Epic blocker, or a blocked ticket outside the version', () => {
    declared();
    mirror([
      { key: 'K-1', fixVersions: ['v1'], blockedBy: ['K-4', 'K-5', 'K-6'] },
      { key: 'K-4', fixVersions: ['v1'] },
      { key: 'K-5', fixVersions: ['v2'], status: 'Done', category: 'Done', resolution: 'Done' },
      { key: 'K-6', fixVersions: ['v2'], type: 'Epic' },
      { key: 'K-7', fixVersions: ['v2'], blockedBy: ['K-8'] },
      { key: 'K-8', fixVersions: ['v2'] },
      { key: 'K-9', fixVersions: ['v1'], status: 'Done', category: 'Done', resolution: 'Done', blockedBy: ['K-8'] },
    ]);
    const out = pull(ctx());
    expect(out.filed).toEqual([]);
    expect(out.skipped).toEqual(['K-6']);
  });

  it('files at most max requests per run and defers the rest to the next', () => {
    declared();
    mirror([
      { key: 'K-1', fixVersions: ['v1'], blockedBy: ['K-2', 'K-3'] },
      { key: 'K-2', fixVersions: ['v2'] },
      { key: 'K-3', fixVersions: ['v2'] },
    ]);
    const first = pull(ctx(), { max: 1 });
    expect(first.filed.map((r) => r.key)).toEqual(['K-2']);
    expect(first.deferred.map((r) => r.key)).toEqual(['K-3']);
    expect(pull(ctx(), { max: 1 }).filed.map((r) => r.key)).toEqual(['K-3']);
  });

  it('the lock-held filing check stops a pull request already asked for, even after it was closed', () => {
    declared();
    scene();
    const first = pull(ctx()).filed[0];
    withdraw(ctx(), { req: first.req, reason: 'settled elsewhere' });
    const raced = request(ctx(), {
      verb: 'INTAKE', key: 'K-2', from_v: 'v2', to_v: 'v1', why: 'blocks K-1 in v1', evidence: { blocks: ['K-1'], rule: 'blocker-pull' }, from: 'blocker-pull',
    });
    expect(raced.req).toBe(first.req);
    expect(request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: 'v2', to_v: 'v1', why: 'the chief asks again', evidence: {}, from: 'console' }).req).not.toBe(first.req);
  });

  it('a dry run lists the rows and files nothing', () => {
    declared();
    scene();
    expect(pull(ctx(), { dryRun: true })).toMatchObject({ filed: [], rows: [{ key: 'K-2', blocks: ['K-1'], from_v: 'v2', to_v: 'v1' }] });
    expect(state(ctx()).requests.open).toEqual([]);
  });

  it('a blocker that reached the version before the ruling is a no-op, not a ruling', async () => {
    declared();
    scene();
    pull(ctx());
    scene([], ['v1']);
    const lines = await rmRun(ctx(), noJudge);
    expect(lines).toEqual([expect.stringMatching(/^NOOP Q-R1-0001: K-2 is already in v1/)]);
    expect(rulingRows()).toEqual([]);
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null });
  });

  it('refuses when a blocked ticket no longer waits on the blocker, and does not re-file it', async () => {
    declared();
    scene();
    pull(ctx());
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v2'], sector: 'Ship loop' }]);
    expect(await rmRun(ctx(), noJudge)).toEqual([expect.stringMatching(/^REFUSED Q-R1-0001: .*blocker-pull: K-1 .*K-2/)]);
    scene();
    expect(pull(ctx()).filed).toEqual([]);
  });

  it('a newer operator record that keeps the blocker where it is wins (CONFLICT), and the refusal is not re-asked', async () => {
    declared();
    scene();
    const keep = operatorDecision(at('2026-10-21T11:00:00.000Z'), { decision: '390', keys: ['K-2'], op: 'keep', from_v: 'v2', to_v: 'v2', verbatim: 'K-2 stays in v2' });
    pull(ctx());
    expect(await rmRun(ctx(), noJudge)).toEqual([expect.stringMatching(new RegExp(`^REFUSED Q-R1-0001: .*CONFLICT K-2: ${keep.id} \\(newer\\) .*K-1`))]);
    expect(jira.fv.get('K-2')).toEqual(['v2']);
    expect(pull(ctx()).filed).toEqual([]);
  });

  it('supersedes an older operator-authority ruling of the blocker', async () => {
    declared();
    scene();
    const old = operatorDecision(at('2026-10-21T09:00:00.000Z'), { decision: '300', keys: ['K-2'], op: 'add', from_v: null, to_v: 'v2', verbatim: 'K-2 to v2' });
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v2', why: 'operator placement', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const prior = admit(q.req, { op: { kind: 'add', from_v: null, to_v: 'v2' }, authority: { kind: 'operator', ref: old.id } });
    await apply(ctx(rmEnv), prior.id);
    leaseRelease(ctx(rmEnv));
    scene([], ['v2'], '2026-10-21T11:00:00.000Z');
    pull(ctx());
    const lines = await rmRun(ctx(), noJudge);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0002 Q-R1-0002 INTAKE K-2 move v2→v1 ADMIT /));
    expect(rulingRows().find((r) => r.id === 'R-R1-0002')?.supersedes).toEqual([prior.id]);
    expect(jira.fv.get('K-2')).toEqual(['v1']);
  });

  it('the emergency path is untouched: an emergency INTAKE goes to the judge and is ruled under O-R1-emergency', async () => {
    declared();
    scene([{ key: 'K-9', fixVersions: [], type: 'Bug' }]);
    pull(ctx());
    request(ctx(), { verb: 'INTAKE', key: 'K-9', from_v: null, to_v: 'v1', why: 'red main', evidence: {}, from: 'console' });
    const seen: string[] = [];
    const judge: Judge = async (input) => {
      seen.push(...input.requests.map((q) => q.key));
      return input.requests.map((q) => ({
        req: q.req, outcome: 'ADMIT', op: 'add' as const, from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'red main',
        authority: 'operator' as const, ref: 'O-R1-emergency',
      }));
    };
    const lines = await rmRun(ctx(), judge);
    expect(seen).toEqual(['K-9']);
    expect(lines.filter((l) => l.startsWith('RULING '))).toHaveLength(2);
    expect(rulingRows().find((r) => r.key === 'K-9')?.authority).toEqual({ kind: 'operator', ref: 'O-R1-emergency' });
  });

  it('a Highest bug blocking nothing is not a pull row', () => {
    declared();
    mirror([{ key: 'K-9', fixVersions: [], type: 'Bug' }]);
    expect(pull(ctx())).toMatchObject({ rows: [], filed: [] });
  });

  it('a judge cannot cite the standing record without blocks, or for a version other than the current one', () => {
    declared();
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { authority: { kind: 'operator', ref: 'O-R1-blocker-pull' } })).toThrow(/does not cover K-2/);
    expect(() => admit(q.req, { op: { kind: 'add', from_v: null, to_v: 'v2' }, authority: { kind: 'operator', ref: 'O-R1-blocker-pull', blocks: ['K-1'] } }))
      .toThrow(/does not cover K-2/);
  });

  it('a release without the standing record files nothing until the chief records it', () => {
    declared();
    scene();
    const c = ctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.filter((r) => r.id !== 'O-R1-blocker-pull').map(({ prev: _p, mac: _m, ...r }) => r);
    rmSync(path);
    for (const r of kept) appendChain(path, k, r);
    expect(() => pull(ctx())).toThrow(/no standing blocker-pull record/);

    const row = standing(ctx(), { kind: 'blocker-pull', decision: '385', verbatim: 'blockers are fixed in the current version' });
    expect(row).toMatchObject({ id: 'O-R1-blocker-pull', kind: 'blocker-pull', decision: '385' });
    expect(() => standing(ctx(), { kind: 'blocker-pull', decision: '385', verbatim: 'again' })).toThrow(/already recorded/);
    expect(pull(ctx()).filed).toHaveLength(1);
  });

  it('the standing record is a chief act', () => {
    declared();
    expect(() => standing(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { kind: 'blocker-pull', decision: '385', verbatim: 'x' })).toThrow(/chief-spawned worker/);
  });
});

describe('signed minerva specs', () => {
  const specEnv = () => ({ HIMMEL_RELEASE_STATE_DIR: join(root, 'release'), HIMMEL_RELEASE_KEY_DIR: join(root, 'keys') });
  const sctx = (env: Record<string, string> = specEnv()) => ctx(env);
  const r2 = (): Ctx => ({ ...sctx(), release: 'R2', dir: join(root, 'release', 'R2'), keyPath: join(root, 'keys', 'R2.key') });
  const declared = (c: Ctx = sctx()) => declare(c, { project: 'HIMMEL', versions: ['v1'], decision: '106', verbatim: 'R', mode: 'observe' });

  // A spec minerva-spec-gate and minerva-trace-lint pass, with its estimate record beside it.
  function spec(name = 'K-1-fixture-2026-10-31.md', dir = join(root, 'specs'), body: string[] = []): string {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'est.json'), JSON.stringify({ median_seq: 1, sigma: 0.1, dod: { passed: true } }));
    const p = join(dir, name);
    writeFileSync(p, [
      body[0] ?? '# K-1: a fixture design', '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture signs.', '',
      '## Invariants', '', 'none', '', ...body.slice(1), '',
    ].join('\n'));
    return p;
  }
  function verdict(specPath: string, kind: 'spec' | 'plan', last: string): string {
    const p = `${specPath}.critic-${kind}-r1.md`;
    writeFileSync(p, `the critic's return\n\n${last}\n`);
    return p;
  }
  const sign = (c: Ctx, keys: string[], p: string, extra: Partial<Parameters<typeof signSpec>[1]> = {}) => signSpec(c, {
    keys, spec: p, decision: '387', verbatim: 'approve', ...extra,
    verdicts: extra.verdicts ?? [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')],
  });
  const check = (keys: string[], mirrorRoot: string | null = null) => specCheck(specEnv(), keys, mirrorRoot).lines;

  async function cli(...args: string[]) {
    const { registerRelease } = await import('../commands/release.js');
    const p = new Command();
    p.exitOverride();
    registerRelease(p);
    await p.parseAsync(['node', 'jira', 'release', ...args]);
  }

  it('spec-check K-1 gives SPEC ok K-1 after a spec record over a fixture spec and two CLEAN verdicts', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    const p = spec();
    writeFileSync(join(root, 'verbatim.txt'), 'approve 1-5\n');
    const out: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    try {
      await cli('operator', 'spec', 'R1', '--keys', 'K-1', '--spec', p, '--verdict', verdict(p, 'spec', 'SPEC CLEAN'),
        '--verdict', verdict(p, 'plan', 'PLAN CLEAN'), '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      await cli('spec-check', 'K-1');
    } finally {
      log.mockRestore();
    }
    expect(out.at(-1)).toBe(`SPEC ok K-1 ${p} O-R1-0002`);
  });

  it('a spec edited while the minerva checks run refuses to sign', () => {
    declared();
    const p = spec();
    afterMinerva.fn = () => writeFileSync(p, readFileSync(p, 'utf8').replace('fixture', 'fixturE'));
    try {
      expect(() => sign(sctx(), ['K-1'], p)).toThrow(/changed while it was checked/);
    } finally {
      afterMinerva.fn = null;
    }
    expect(check(['K-1'])).toEqual(['NO-SPEC K-1']);
  });

  it('a plan edited while the minerva checks run refuses to sign', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    afterMinerva.fn = () => writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: added mid-sign.\n`);
    try {
      expect(() => sign(sctx(), ['K-1'], p, { plan })).toThrow(/changed while it was checked/);
    } finally {
      afterMinerva.fn = null;
    }
    expect(check(['K-1'])).toEqual(['NO-SPEC K-1']);
  });

  it('a --supersedes re-sign that drops a key of the record it replaces is refused', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1', 'K-2'], p);
    expect(() => sign(sctx(), ['K-1'], p, { supersedes: r.id })).toThrow(/K-2/);
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`, `SPEC ok K-2 ${p} ${r.id}`]);
  });

  it('one changed byte of the signed spec gives SPEC-STALE', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    writeFileSync(p, readFileSync(p, 'utf8').replace('fixture', 'fixturE'));
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).ok).toBe(false);
  });

  it('a --supersedes re-sign clears SPEC-STALE with the new id', () => {
    declared();
    const p = spec();
    const old = sign(sctx(), ['K-1'], p);
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Notes\n\nedited after review\n`);
    const fresh = sign(sctx(), ['K-1'], p, { supersedes: old.id });
    expect(fresh.supersedes).toBe(old.id);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${fresh.id}`]);
    expect(() => sign(sctx(), ['K-1'], p, { supersedes: 'O-R1-0999' })).toThrow(/O-R1-0999 is no verified spec record/);
  });

  it('a re-sign of an already-signed key without --supersedes is refused, naming the record to supersede', () => {
    declared();
    const a = spec('K-1-a.md');
    const b = spec('K-1-b.md', join(root, 'specs-b'));
    const first = sign(sctx(), ['K-1'], a);
    expect(() => sign(sctx(), ['K-2', 'K-1'], b)).toThrow(/K-1 is already signed in O-R1-0002; re-sign with --supersedes O-R1-0002/);
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${a} ${first.id}`, 'NO-SPEC K-2']);
    const later = sign({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, ['K-1', 'K-2'], b, { supersedes: first.id });
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${b} ${later.id}`, `SPEC ok K-2 ${b} ${later.id}`]);
  });

  it('signing a spec and writing the core snapshot wait on the release root lock, not only the release lock', () => {
    declared();
    const p = spec();
    const rootLock = join(root, 'release', '.lock');
    writeFileSync(rootLock, 'another writer');
    // Each read of the clock moves 4 s on, so the 10 s lock wait ends in a few polls and the fresh lock never turns stale.
    let t = Date.now();
    const clock = vi.spyOn(Date, 'now').mockImplementation(() => (t += 4000));
    try {
      expect(() => sign(sctx(), ['K-1'], p)).toThrow(/release\/\.lock is held/);
      expect(() => coreSnapshot(sctx(), { keys: ['K-1'] })).toThrow(/release\/\.lock is held/);
    } finally {
      clock.mockRestore();
      unlinkSync(rootLock);
    }
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  // A spec kept outside the checkout (the state repo bucket) with a Fact ownership matrix and invariants.
  function bucketSpec(cited: string): { spec: string; plan: string } {
    const p = spec('K-1-bucket-2026-11-02.md', join(root, 'bucket', 'designs'));
    writeFileSync(p, [
      '# K-1: a status feed', '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture signs.', '',
      '## Fact ownership', '',
      '| Fact | Existing surfaces | Owner after | Non-owners |', '|---|---|---|---|',
      `| item status | \`${cited}\` (\`--held\`, \`ROW_REGISTRIES\`) | the feed | n/a |`, '',
      '## Invariants', '', '- I1 — one fact is one row.', '',
    ].join('\n'));
    const plan = join(root, 'bucket', 'plans', 'K-1-bucket-plan-2026-11-02.md');
    mkdirSync(join(root, 'bucket', 'plans'), { recursive: true });
    writeFileSync(plan, 'plan\n\n- Task 1: I1 — Test: `scripts/test-feed.sh` feeds a fact from two real sources.\n');
    return { spec: p, plan };
  }

  it('signs a bucket spec with invariants: the lint reads its paths from the checkout and its invariants from the plan', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    expect(r.keys).toEqual(['K-1']);
    expect(readOperatorRecords('spec', specEnv())[0].plan_path).toBe(plan);
    expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
  });

  it('the signature binds the plan bytes: one changed byte of the signed plan gives SPEC-STALE', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    expect(r.plan_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).warnings).toEqual([]);
    writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: an unsigned addition.\n`);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).ok).toBe(false);
    unlinkSync(plan);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('a record signed before the plan hash existed still reads SPEC ok, with a plan-unbound warning', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    const c = sctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.map(({ prev: _p, mac: _m, plan_sha256: _s, ...row }) => row);
    rmSync(path);
    for (const row of kept) appendChain(path, k, row);
    writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: an addition after the old signature.\n`);
    const out = specCheck(specEnv(), ['K-1'], null);
    expect(out.lines).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(out.ok).toBe(true);
    expect(out.warnings).toEqual([expect.stringMatching(/K-1.*plan unbound/)]);
  });

  it('spec-check prints the plan-unbound warning on stderr and still exits ok', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    const c = sctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.map(({ prev: _p, mac: _m, plan_sha256: _s, ...row }) => row);
    rmSync(path);
    for (const row of kept) appendChain(path, k, row);
    const out: string[] = [];
    const err: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    const errSpy = vi.spyOn(console, 'error').mockImplementation((s: string) => { err.push(s); });
    const code = process.exitCode;
    try {
      await cli('spec-check', 'K-1');
    } finally {
      log.mockRestore();
      errSpy.mockRestore();
    }
    expect(out).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(err).toEqual([expect.stringMatching(/^WARN K-1 plan unbound/)]);
    expect(process.exitCode).toBe(code);
  });

  it('a spec signed with no separate plan has no plan to bind and warns of nothing', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    expect(r.plan_sha256 ?? null).toBeNull();
    expect(specCheck(specEnv(), ['K-1'], null).warnings).toEqual([]);
  });

  it('a spec with invariants cannot be signed without its plan, nor with itself as the plan', () => {
    declared();
    const { spec: p } = bucketSpec('docs/handover/running-a-chief.md');
    expect(() => sign(sctx(), ['K-1'], p)).toThrow(/the plan is the spec/);
    expect(() => sign(sctx(), ['K-1'], p, { plan: p })).toThrow(/the plan is the spec/);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a bucket spec naming a truly missing path is still refused, and so is one whose plan names no test', () => {
    declared();
    const bad = bucketSpec('scripts/no-such-file.sh');
    expect(() => sign(sctx(), ['K-1'], bad.spec, { plan: bad.plan })).toThrow(/cites scripts\/no-such-file\.sh, which does not exist/);
    const ok = bucketSpec('docs/handover/running-a-chief.md');
    writeFileSync(ok.plan, 'plan\n\n- Task 1: I1 is covered somewhere.\n');
    expect(() => sign(sctx(), ['K-1'], ok.spec, { plan: ok.plan })).toThrow(/I1 has no plan line naming its acceptance test/);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a missing plan file is refused at signing', () => {
    declared();
    const { spec: p } = bucketSpec('docs/handover/running-a-chief.md');
    expect(() => sign(sctx(), ['K-1'], p, { plan: join(root, 'bucket', 'plans', 'absent.md') }))
      .toThrow(/release operator spec: plan not found: .*absent\.md/);
  });

  it('a missing spec file is refused at signing and reads SPEC-STALE once signed', () => {
    declared();
    expect(() => sign(sctx(), ['K-1'], join(root, 'specs', 'absent.md'), { verdicts: [] }))
      .toThrow(/release operator spec: spec not found: .*absent\.md/);
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    unlinkSync(p);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('a missing verdict file is refused at signing and reads SPEC-STALE once signed', () => {
    declared();
    const p = spec();
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: [verdict(p, 'spec', 'SPEC CLEAN'), `${p}.critic-plan-r9.md`] }))
      .toThrow(/release operator spec: verdict file not found: .*critic-plan-r9\.md/);
    const r = sign(sctx(), ['K-1'], p);
    unlinkSync(`${p}.critic-plan-r1.md`);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('an uncovered key gives NO-SPEC and a non-zero result', () => {
    declared();
    sign(sctx(), ['K-1'], spec());
    expect(check(['K-1', 'K-9'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /), 'NO-SPEC K-9']);
    expect(specCheck(specEnv(), ['K-9'], null).ok).toBe(false);
  });

  it('a sub-task with no record of its own is covered by its parent\'s record, one hop', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    const m = join(root, 'mirror');
    mkdirSync(m, { recursive: true });
    writeFileSync(join(m, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-21T09:00:00.000Z' }));
    writeFileSync(join(m, 'K-2.md'), ['---', 'key: "K-2"', 'type: "Subtask"', 'parent: "K-1"', '---', ''].join('\n'));
    writeFileSync(join(m, 'K-3.md'), ['---', 'key: "K-3"', 'type: "Subtask"', 'parent: "K-2"', '---', ''].join('\n'));
    writeFileSync(join(m, 'K-4.md'), ['---', 'key: "K-4"', 'type: "Task"', 'parent: "K-1"', '---', ''].join('\n'));
    expect(check(['K-2', 'K-3', 'K-4'], m)).toEqual([`SPEC ok K-2 ${p} ${r.id}`, 'NO-SPEC K-3', 'NO-SPEC K-4']);
    expect(check(['K-2'])).toEqual(['NO-SPEC K-2']);
  });

  it('a record in a second declared release is found', () => {
    declared();
    declared(r2());
    const p = spec();
    const r = sign(r2(), ['K-1'], p);
    expect(r.id).toMatch(/^O-R2-/);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(readOperatorRecords('spec', specEnv()).map((o) => o.release)).toEqual(['R2']);
  });

  it('a tampered chain row gives NO-SPEC', () => {
    declared();
    sign(sctx(), ['K-1'], spec());
    const chain = join(root, 'release', 'R1', 'operator.jsonl');
    writeFileSync(chain, readFileSync(chain, 'utf8').replace('"keys":["K-1"]', '"keys":["K-1","K-2"]'));
    expect(check(['K-1', 'K-2'])).toEqual(['NO-SPEC K-1', 'NO-SPEC K-2']);
  });

  it('a worker context is refused by the fence', () => {
    declared();
    expect(() => sign(sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' }), ['K-1'], spec())).toThrow(/chief-spawned worker/);
  });

  it('a spec failing minerva-spec-gate is refused and records nothing', () => {
    declared();
    const p = spec();
    writeFileSync(p, readFileSync(p, 'utf8').replace('Estimate record: est.json', ''));
    expect(() => sign(sctx(), ['K-1'], p)).toThrow(/minerva-spec-gate.*estimate record/s);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a SPEC FINDINGS 2 verdict signs only with a critic-rounds section dispositioning both residuals', () => {
    declared();
    const p = spec();
    const findings = () => [verdict(p, 'spec', 'SPEC FINDINGS 2'), verdict(p, 'plan', 'PLAN CLEAN')];
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() })).toThrow(/2 residual findings.*Critic rounds/s);
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Critic rounds\n\n- R1: fixed in §1\n`);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() })).toThrow(/2 residual findings.*1 dispositioned/s);
    writeFileSync(p, `${readFileSync(p, 'utf8')}- R2: deferred → HIMMEL-9000\n`);
    expect(sign(sctx(), ['K-1'], p, { verdicts: findings() }).residuals).toBe(2);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: [verdict(p, 'spec', 'looks fine'), verdict(p, 'plan', 'PLAN CLEAN')] }))
      .toThrow(/last line/);
  });

  it('a ceiling disposition signs a residual, the retired word still reads as its alias, and an unknown word is refused', () => {
    declared();
    const p = spec();
    const findings = () => [verdict(p, 'spec', 'SPEC FINDINGS 2'), verdict(p, 'plan', 'PLAN CLEAN')];
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Critic rounds\n\n- R1: ceiling\n- R2: accepted\n`);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() }))
      .toThrow(/2 residual findings.*1 dispositioned.*fixed\|ASSUMPTION\|ceiling\|deferred/s);
    writeFileSync(p, readFileSync(p, 'utf8').replace('- R2: accepted', '- R2: ponytail'));
    expect(sign(sctx(), ['K-1'], p, { verdicts: findings() }).residuals).toBe(2);
  });

  it('run from a non-himmel cwd, the verb finds the minerva scripts in the primary checkout and lints the spec in its own repository', () => {
    declared();
    const repo = join(root, 'state-repo');
    mkdirSync(join(repo, 'notes'), { recursive: true });
    execFileSync('git', ['init', '-q', repo]);
    writeFileSync(join(repo, 'notes', 'only-here.md'), 'x\n');
    const p = spec('K-1-check.md', join(repo, 'specs'), ['# K-1: a status check design',
      '## Fact ownership', '', '| fact | existing surfaces | owner |', '|---|---|---|', '| a | `notes/only-here.md` | `notes/only-here.md` |']);
    const away = mkdtempSync(join(tmpdir(), 'not-himmel-'));
    const was = process.cwd();
    process.chdir(away);
    try {
      expect(sign(sctx(), ['K-1'], p).spec_path).toBe(p);
    } finally {
      process.chdir(was);
    }
  });
});

describe('admission rows enter the reducer through reduceLoaded', () => {
  // HIMMEL_ADMISSIONS_LEDGER is a temp path (beforeEach), so none of these reads the operator's ledger.
  const ledger = () => process.env.HIMMEL_ADMISSIONS_LEDGER!;
  const row = (key: string, kind: string) => JSON.stringify({ ts: '2026-10-21T09:30:00.000Z', version: 'v1', key, kind, actor: 'someone' });
  const admitAllRows: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));

  it('an override row in the ledger clears the unauthorized flag through state()', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'] }, { key: 'K-4', fixVersions: ['v1'] }]);
    expect(state(ctx()).leaks.unauthorized).toEqual(['K-3@v1', 'K-4@v1']);
    writeFileSync(ledger(), [row('K-3', 'override'), row('K-4', 'rm-admit')].join('\n') + '\n');
    const s = state(ctx());
    expect(s.inputs.admissions).toBe('FRESH');
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('bad admissions line reads UNKNOWN and status stays OK', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'] }]);
    writeFileSync(ledger(), [row('K-3', 'override'), 'not json at all'].join('\n') + '\n');
    const s = state(ctx());
    expect(s.inputs.admissions).toBe('UNKNOWN');
    expect(s.status).toBe('OK');
    expect(s.leaks.unauthorized).toEqual(['K-3@v1']);
  });

  it('bad admissions line: rule() and rmRun still run', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    writeFileSync(ledger(), 'not json at all\n');
    request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    // rmRun's own reduceLoaded and rule()'s did not throw on the bad line: the run completes and the intent row is on disk.
    // (apply()'s separate ledger read is unchanged by S1 and still reports the ruling PENDING.)
    const lines = await rmRun(ctx(), admitAllRows);
    expect(lines.join('\n')).toContain('R-R1-0001');
    expect(readFileSync(join(ctx().dir, 'rulings.jsonl'), 'utf8')).toContain('"phase":"intent"');
  });
});

describe('version-repair entry check and held state', () => {
  const rulings = () => readChain<RulingRow>(join(ctx().dir, 'rulings.jsonl'), loadKey(ctx().keyPath)).verified;
  const requests = () => readChain<RequestRow>(join(ctx().dir, 'requests.jsonl'), loadKey(ctx().keyPath)).verified;
  const latestReq = (req: string) => requests().filter((r) => r.req === req).at(-1);
  const phases = () => rulings().map((r) => r.phase);
  const mismatches = () => readChain<EventRow>(join(ctx().dir, 'events.jsonl'), loadKey(ctx().keyPath)).verified.filter((e) => e.readback === 'mismatch').length;
  const placementAt = (version: string) => state(ctx()).records.find((x) => x.key === 'K-1' && x.version === version)?.placement;
  const next = { ...rmEnv, HIMMEL_RM_DOC: '/abs/b.md' };
  const newEpoch = () => {
    leaseRelease(ctx(rmEnv));
    leaseAcquire(ctx(next), { expectEpoch: 1, doc: '/abs/b.md', session: 'b' });
  };
  // A repair move v1→v2 on K-1, ruled to intent and not yet applied.
  const repairEvidence = { rule: 'version-repair', entry: '99' };
  const ruledMove = async (evidence: Record<string, unknown> = repairEvidence) => {
    await setup();
    jira.fv.set('K-1', ['v1']);
    const q = request(ctx(), { verb: 'REVERSION', key: 'K-1', from_v: 'v1', to_v: 'v2', why: 'w', evidence, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, supersedes: ['baseline-v1-g1'] });
    return { q, r };
  };

  it('entry-moved goes to withdrawn', async () => {
    const { q, r } = await ruledMove();
    jira.entries.set('K-1', '100');
    expect(placementAt('v2')).toBe('pending');
    const got = await apply(ctx(rmEnv), r.id);
    expect(got.phase).toBe('void');
    expect(jira.writes).toBe(0);
    expect(jira.posted).toBe(0);
    expect(phases()).toContain('void');
    expect(latestReq(q.req)?.state).toBe('withdrawn:repair');
    expect(latestReq(q.req)?.reason).toBe('entry-moved');
    // A second run finds nothing to claim or apply, and the key reads settled, not pending or reopened.
    expect(claim(ctx(rmEnv))).toEqual([]);
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('void');
    expect(placementAt('v2')).not.toBe('pending');
    expect(state(ctx()).requests.open).toEqual([]);
    expect(jira.writes).toBe(0);
  });

  it('older epoch untouched withdraws, never reopens', async () => {
    const { q, r } = await ruledMove();
    newEpoch();
    expect(placementAt('v2')).toBe('pending');
    const got = await apply(ctx(next), r.id);
    expect(got.phase).toBe('void');
    expect(latestReq(q.req)?.state).toBe('withdrawn:repair');
    expect(latestReq(q.req)?.reason).toBe('never-landed');
    expect(jira.entryCalls).toBe(0);
    expect(claim(ctx(next))).toEqual([]);
    expect((await apply(ctx(next), r.id)).phase).toBe('void');
    expect(placementAt('v2')).not.toBe('pending');
    expect(state(ctx()).requests.open).toEqual([]);
  });

  it('own partial write stays mismatch and throws, ruling not voided', async () => {
    const { r } = await ruledMove();
    jira.fv.set('K-1', []);
    newEpoch();
    await expect(apply(ctx(next), r.id)).rejects.toThrow(/partly applied/);
    expect(phases()).toEqual(['intent']);
    expect(mismatches()).toBe(1);
    expect(jira.entryCalls).toBe(0);
  });

  it('own landed write goes applied', async () => {
    const { r } = await ruledMove();
    jira.fv.set('K-1', ['v2']);
    jira.entries.set('K-1', '101');
    newEpoch();
    expect((await apply(ctx(next), r.id)).phase).toBe('receipted');
    expect(jira.writes).toBe(0);
    expect(jira.entryCalls).toBe(0);
  });

  it('own landed write goes applied in the current epoch though the entry moved', async () => {
    const { r } = await ruledMove();
    jira.fv.set('K-1', ['v2']);
    jira.entries.set('K-1', '101');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect(jira.writes).toBe(0);
  });

  it('same-epoch retry after a partial is not entry-moved', async () => {
    const { r } = await ruledMove();
    jira.fv.set('K-1', []);
    jira.entries.set('K-1', '100');
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/partly applied/);
    expect(jira.writes).toBe(0);
    expect(phases()).toEqual(['intent']);
    expect(mismatches()).toBe(1);
  });

  // A repair request is filed with the entry it was built for (`create` when the key has none). One that names none
  // cannot be shown current, so it writes nothing and is withdrawn like a moved entry; a refile names the entry.
  it.each([
    ['absent', { rule: 'version-repair' }],
    ['non-string', { rule: 'version-repair', entry: 99 }],
  ])('a request whose entry is %s withdraws with no write', async (_name, evidence) => {
    const { q, r } = await ruledMove(evidence);
    jira.entries.set('K-1', '99');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('void');
    expect(jira.writes).toBe(0);
    expect(latestReq(q.req)?.state).toBe('withdrawn:repair');
    expect(latestReq(q.req)?.reason).toBe('entry-moved');
  });

  it('a matching entry applies as today', async () => {
    const { r } = await ruledMove();
    jira.entries.set('K-1', '99');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect(jira.fv.get('K-1')).toEqual(['v2']);
  });

  it('a port with no entry method refuses a version-repair request', async () => {
    const { r } = await ruledMove();
    const bare = {
      ...ctx(rmEnv),
      jira: { fixVersions: (k: string) => jira.fixVersions(k), setFixVersion: jira.setFixVersion.bind(jira), findComment: jira.findComment.bind(jira), addComment: jira.addComment.bind(jira) },
    } as unknown as Ctx;
    await expect(apply(bare, r.id)).rejects.toThrow(/has no newestFixVersionEntry/);
    expect(jira.writes).toBe(0);
    expect(phases()).toEqual(['intent']);
  });

  it('entry read failure makes no write and stays intent', async () => {
    const { r } = await ruledMove();
    jira.entryFails = true;
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow('entry read down');
    expect(jira.writes).toBe(0);
    expect(phases()).toEqual(['intent']);
  });

  it('after an entry read failure the next run withdraws it as never-landed', async () => {
    const { q, r } = await ruledMove();
    jira.entryFails = true;
    await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow('entry read down');
    newEpoch();
    expect((await apply(ctx(next), r.id)).phase).toBe('void');
    expect(latestReq(q.req)?.reason).toBe('never-landed');
  });

  describe('offered keep, add and move each land at read-back', () => {
    const rule1 = async (verb: 'INTAKE' | 'REVERSION', from_v: string | null, to_v: string | null, outcome: string, op: { kind: 'keep' | 'add' | 'move'; from_v: string | null; to_v: string | null }) => {
      await setup();
      const q = request(ctx(), { verb, key: 'K-1', from_v, to_v, why: 'w', evidence: repairEvidence, from: 'console' });
      claim(ctx(rmEnv));
      jira.entries.set('K-1', '99');
      return admit(q.req, { outcome, op, supersedes: ['baseline-v1-g1'] });
    };

    it('keep on a member goes applied with no PUT', async () => {
      const r = await rule1('REVERSION', 'v1', 'v1', 'KEEP', { kind: 'keep', from_v: 'v1', to_v: 'v1' });
      jira.fv.set('K-1', ['v1']);
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.writes).toBe(0);
    });

    it('move on a key already in the target goes applied with no PUT', async () => {
      const r = await rule1('REVERSION', 'v1', 'v2', 'MOVE', { kind: 'move', from_v: 'v1', to_v: 'v2' });
      jira.fv.set('K-1', ['v2']);
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.writes).toBe(0);
    });

    it('add on a stripped key makes one PUT and goes applied', async () => {
      const r = await rule1('INTAKE', null, 'v1', 'ADMIT', { kind: 'add', from_v: null, to_v: 'v1' });
      jira.fv.set('K-1', []);
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(jira.writes).toBe(1);
      expect(jira.fv.get('K-1')).toEqual(['v1']);
    });
  });

  it('chief-filed request behaves as today', async () => {
    const { q, r } = await ruledMove({});
    jira.entries.set('K-1', '100');
    expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
    expect(jira.entryCalls).toBe(0);
    expect(latestReq(q.req)?.state).toMatch(/^ruled:/);
  });

  describe('held', () => {
    const repairAsk = (evidence: Record<string, unknown>) => {
      declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
      return request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence, from: 'console' });
    };
    const holdAll: Judge = async (input) => input.requests.map((q) => ({ req: q.req, outcome: 'HOLD', reason: 'no sector' }));

    it('HOLD on a version-repair request writes held and claim skips it', async () => {
      const q = repairAsk({ rule: 'version-repair', entry: '5' });
      await rmRun(ctx(), holdAll);
      expect(latestReq(q.req)?.state).toBe('held');
      // A second run reaches claim() because a sibling is open, and asks the judge about the sibling only.
      const sibling = request(ctx(), { verb: 'INTAKE', key: 'K-3', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      const asked: string[] = [];
      await rmRun(ctx(), async (input) => { asked.push(...input.requests.map((x) => x.req)); return holdAll(input); });
      expect(asked).toEqual([sibling.req]);
      expect(latestReq(q.req)?.state).toBe('held');
    });

    it('HOLD on a chief-filed request stays claimed', async () => {
      const q = repairAsk({});
      await rmRun(ctx(), holdAll);
      expect(latestReq(q.req)?.state).toMatch(/^claimed:/);
    });

    it('withdraw moves a held request out', async () => {
      const q = repairAsk({ rule: 'version-repair', entry: '5' });
      await rmRun(ctx(), holdAll);
      withdraw(ctx(), { req: q.req, reason: 'entry moved' });
      expect(latestReq(q.req)?.state).toBe('withdrawn:console');
    });

    it('contradicting operator decision withdraws a held request', async () => {
      const q = repairAsk({ rule: 'version-repair', entry: '5' });
      await rmRun(ctx(), holdAll);
      operatorDecision(ctx(), { decision: '200', keys: ['K-2'], op: 'remove', from_v: 'v1', to_v: null, verbatim: 'x' });
      expect(latestReq(q.req)?.state).toMatch(/^withdrawn:/);
    });
  });
});

describe('release bucket-check verdict', () => {
  const env = () => ({ HIMMEL_RELEASE_STATE_DIR: join(root, 'release'), HIMMEL_RELEASE_KEY_DIR: join(root, 'keys') });
  const NOW = new Date('2026-11-08T12:00:00.000Z');
  const mir = () => join(root, 'mirror');
  const declared = () => declare(ctx(env()), { project: 'BKT', versions: ['v1.1.9', 'v1.1.10'], decision: '106', verbatim: 'R', mode: 'observe' });
  const versions = (text = 'v1.1.8\ttrue\t2026-10-01\tfalse\nv1.1.10\tfalse\t\tfalse\nv1.1.9\tfalse\t\tfalse\n') => writeFileSync(`${mir()}.versions.tsv`, text);
  function world(issues: Parameters<typeof mirror>[0] = []) {
    declared();
    mirror(issues);
    versions();
  }
  function stub(answer: Record<string, string[]> | 'fail' | 'hang' = 'fail') {
    const calls: string[] = [];
    const get = (<T>(path: string): Promise<T> => {
      calls.push(path);
      if (answer === 'hang') return new Promise<T>(() => undefined);
      if (answer === 'fail') return Promise.reject(new Error('HTTP 503'));
      const key = /^\/issue\/([^?]+)\?/.exec(path)?.[1] ?? '';
      return Promise.resolve({ fields: { fixVersions: (answer[key] ?? []).map((name) => ({ name })) } } as T);
    }) as Getter;
    return { get, calls };
  }
  const check = (keys: string[], s = stub(), deadlineMs = 5000) => bucketCheck(env(), keys, mir(), { get: s.get, deadlineMs, now: NOW });
  const approve = (key: string, decision: string, ageDays: number) => appendChain(join(root, 'release', 'R1', 'operator.jsonl'), loadKey(join(root, 'keys', 'R1.key')), {
    id: `O-R1-ov-${decision}`, kind: 'out-of-version', decision, keys: [key], ts: new Date(NOW.getTime() - ageDays * 86_400_000).toISOString(),
  });

  it('row 0, no readable mirror: FAILED by name', async () => {
    declared();
    versions();
    mkdirSync(mir(), { recursive: true });
    expect(await check(['BKT-1'])).toEqual([`FAILED BKT-1 no readable mirror at ${mir()}`]);
  });

  it('row 0, no versions file while a release.json names the project: FAILED, not NONE', async () => {
    declared();
    mirror([{ key: 'BKT-1', fixVersions: ['v1.1.9'] }]);
    expect(await check(['BKT-1'])).toEqual([`FAILED BKT-1 no versions file at ${mir()}.versions.tsv while ${join(root, 'release', 'R1', 'release.json')} names BKT`]);
  });

  it('row 0, the release.json names the project, its key will not load and there is no versions file: FAILED, not NONE', async () => {
    declared();
    mirror([]);
    chmodSync(join(root, 'keys', 'R1.key'), 0o644);
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 no versions file at .* names BKT$/);
  });

  it('row 0, a release.json that does not parse counts as naming the project: FAILED, not NONE', async () => {
    mkdirSync(join(root, 'release', 'R9'), { recursive: true });
    writeFileSync(join(root, 'release', 'R9', 'release.json'), '{ not json');
    mirror([]);
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 no versions file at .* while .*\/R9\/release\.json names BKT$/);
  });

  it.each(['null', '[]', '"BKT"'])('row 0, a release.json that parses to %s is no declaration and counts as naming the project', async (body) => {
    mkdirSync(join(root, 'release', 'R9'), { recursive: true });
    writeFileSync(join(root, 'release', 'R9', 'release.json'), body);
    mirror([]);
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 no versions file at .* while .*\/R9\/release\.json names BKT$/);
    versions();
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 .*\/R9\/release\.json does not parse, so the declared current cannot be read$/);
  });

  it('row 0, an argument that is not a ticket key: FAILED by name', async () => {
    world([]);
    expect(await check(['not-a-key'])).toEqual(['FAILED not-a-key is not a ticket key']);
  });

  it('row 0, a release root that cannot be read: FAILED by name', async () => {
    mirror([]);
    versions();
    writeFileSync(join(root, 'not-a-dir'), 'x');
    const lines = await bucketCheck({ ...env(), HIMMEL_RELEASE_STATE_DIR: join(root, 'not-a-dir') }, ['BKT-1'], mir(), { get: stub().get, deadlineMs: 5000, now: NOW });
    expect(lines[0]).toMatch(/^FAILED BKT-1 the release root cannot be read: ENOTDIR/);
  });

  it('row 0, a versions file that cannot be read: FAILED by name', async () => {
    declared();
    mirror([]);
    mkdirSync(`${mir()}.versions.tsv`);
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 the versions file .*mirror\.versions\.tsv cannot be read: EISDIR/);
  });

  it('row 0, a release.json that does not parse while a versions file exists: FAILED, the declared current unreadable', async () => {
    world([{ key: 'BKT-1', fixVersions: ['v1.1.9'] }]);
    mkdirSync(join(root, 'release', 'R9'), { recursive: true });
    writeFileSync(join(root, 'release', 'R9', 'release.json'), '{ not json');
    expect(await check(['BKT-1'])).toEqual([`FAILED BKT-1 ${join(root, 'release', 'R9', 'release.json')} does not parse, so the declared current cannot be read`]);
  });

  it('row 0, a versions file with no current version: FAILED by name', async () => {
    world([{ key: 'BKT-1', fixVersions: ['v1.1.9'] }]);
    versions('v1.1.9\ttrue\t2026-11-01\tfalse\nv1.1.10\tfalse\t\ttrue\nzz-tmp\tfalse\t\tfalse\n');
    expect(await check(['BKT-1'])).toEqual([`FAILED BKT-1 the versions file ${mir()}.versions.tsv has no current version`]);
  });

  it('row 0, the declared current differs from the versions-file current: FAILED naming both', async () => {
    world([{ key: 'BKT-1', fixVersions: ['v1.1.10'] }]);
    versions('v1.1.9\ttrue\t2026-11-01\tfalse\nv1.1.10\tfalse\t\tfalse\n');
    expect((await check(['BKT-1']))[0]).toMatch(/^FAILED BKT-1 the declared current v1\.1\.9 \(.*R1\/release\.json\) differs from the versions-file current v1\.1\.10$/);
  });

  it('row 0, a failed live read: FAILED by name', async () => {
    world([{ key: 'BKT-1', fixVersions: ['v1.1.10'] }]);
    expect(await check(['BKT-1'], stub('fail'))).toEqual(['FAILED BKT-1 the live read of BKT-1 failed: HTTP 503']);
  });

  it('row 0, a hung live read is FAILED inside the deadline', async () => {
    world([{ key: 'BKT-1', fixVersions: ['v1.1.10'] }]);
    const started = Date.now();
    expect(await check(['BKT-1'], stub('hang'), 50)).toEqual(['FAILED BKT-1 the live read of BKT-1 failed: no answer within 50 ms']);
    expect(Date.now() - started).toBeLessThan(2000);
  });

  it('row 1, a readable mirror, no versions file and no release naming the project: NONE with the mirror, and no fetch', async () => {
    const other = { ...ctx(env()), release: 'S1', dir: join(root, 'release', 'S1'), keyPath: join(root, 'keys', 'S1.key') };
    declare(other, { project: 'SALUS', versions: ['v2'], decision: '1', verbatim: 'S', mode: 'observe' });
    mirror([{ key: 'ADOPT-1', fixVersions: [] }]);
    const s = stub('fail');
    expect(await check(['ADOPT-1'], s)).toEqual([`NONE ADOPT-1 ${mir()}`]);
    expect(s.calls).toEqual([]);
  });

  it('row 2, an approval under 14 days: APPROVED with its decision, and a failing fetch is never asked', async () => {
    world([{ key: 'BKT-2', fixVersions: ['v1.1.10'] }]);
    approve('BKT-2', '901', 1);
    const s = stub('fail');
    expect(await check(['BKT-2'], s)).toEqual(['APPROVED BKT-2 decision=901 record=O-R1-ov-901']);
    expect(s.calls).toEqual([]);
  });

  it('row 3, the mirror says Done: DONE, ahead of a key the mirror holds in current, and a failing fetch is never asked', async () => {
    world([{ key: 'BKT-3', fixVersions: ['v1.1.9'], category: 'Done' }, { key: 'BKT-4', fixVersions: ['v1.1.4'], category: 'Done' }]);
    const s = stub('fail');
    expect(await check(['BKT-3', 'BKT-4'], s)).toEqual(['DONE BKT-3', 'DONE BKT-4']);
    expect(s.calls).toEqual([]);
  });

  it('row 4, the mirror holds it in current: IN with no fetch; a key the mirror lacks that Jira holds in current: IN', async () => {
    world([{ key: 'BKT-5', fixVersions: ['v1.1.9'] }]);
    const s = stub({ 'BKT-6': ['v1.1.9'] });
    expect(await check(['BKT-5'], s)).toEqual(['IN BKT-5 current=v1.1.9 via=mirror']);
    expect(s.calls).toEqual([]);
    expect(await check(['BKT-6'], s)).toEqual(['IN BKT-6 current=v1.1.9 via=jira']);
    expect(s.calls).toEqual(['/issue/BKT-6?fields=fixVersions']);
  });

  it('row 5, anything else: OUTSIDE with the version, current and the open count, after exactly one fetch', async () => {
    world([
      { key: 'BKT-7', fixVersions: ['v1.1.10'] }, { key: 'BKT-8', fixVersions: ['v1.1.9'] }, { key: 'BKT-9', fixVersions: ['v1.1.9'], status: 'In Progress' },
      { key: 'BKT-10', fixVersions: ['v1.1.9'], category: 'Done' }, { key: 'BKT-11', fixVersions: [] },
    ]);
    const s = stub({ 'BKT-7': ['v1.1.10'] });
    expect(await check(['BKT-7', 'BKT-11'], s)).toEqual(['OUTSIDE BKT-7 v1.1.10 current=v1.1.9 open=2', 'OUTSIDE BKT-11 none current=v1.1.9 open=2']);
    expect(s.calls).toEqual(['/issue/BKT-7?fields=fixVersions', '/issue/BKT-11?fields=fixVersions']);
  });

  it('no ledger IN: an add record into current on a key neither the mirror nor Jira holds there reads OUTSIDE', async () => {
    world([{ key: 'BKT-12', fixVersions: [] }]);
    operatorDecision(ctx(env()), { decision: '500', keys: ['BKT-12'], op: 'add', from_v: null, to_v: 'v1.1.9', verbatim: 'add it' });
    expect(await check(['BKT-12'], stub({}))).toEqual(['OUTSIDE BKT-12 none current=v1.1.9 open=0']);
  });

  it('an approval 15 days old reads OUTSIDE; one 13 days old on a Done key reads APPROVED', async () => {
    world([{ key: 'BKT-13', fixVersions: ['v1.1.10'] }, { key: 'BKT-14', fixVersions: ['v1.1.10'], category: 'Done' }]);
    approve('BKT-13', '902', 15);
    approve('BKT-14', '903', 13);
    expect(await check(['BKT-13', 'BKT-14'], stub({ 'BKT-13': ['v1.1.10'] })))
      .toEqual(['OUTSIDE BKT-13 v1.1.10 current=v1.1.9 open=0', 'APPROVED BKT-14 decision=903 record=O-R1-ov-903']);
  });

  it('an approval past a broken chain reads OUTSIDE', async () => {
    world([{ key: 'BKT-15', fixVersions: ['v1.1.10'] }]);
    approve('BKT-15', '904', 1);
    const ledger = join(root, 'release', 'R1', 'operator.jsonl');
    writeFileSync(ledger, readFileSync(ledger, 'utf8').replace('standing record: an evidenced', 'standing record: an edited'));
    expect(await check(['BKT-15'], stub({ 'BKT-15': ['v1.1.10'] }))).toEqual(['OUTSIDE BKT-15 v1.1.10 current=v1.1.9 open=0']);
  });

  it('current is the pool\'s rule: next-dispatchable.sh and the verdict pick v1.1.9 over v1.1.10, an archived and a zz- version', () => {
    const tsv = 'v1.1.10\tfalse\t\tfalse\nzz-scratch\tfalse\t\tfalse\nv1.1.8\tfalse\t\ttrue\nv1.1.9\tfalse\t\tfalse\nv1.1.7\ttrue\t2026-01-01\tfalse\n';
    const m = join(root, 'jira-mirror', 'HIMMEL');
    mkdirSync(m, { recursive: true });
    writeFileSync(`${m}.versions.tsv`, tsv);
    writeFileSync(join(m, 'HIMMEL-1.md'), '---\nkey: "HIMMEL-1"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "To Do"\npriority: "Medium"\nlabels: []\n'
      + 'fixVersions: ["v1.1.9"]\nparent: null\n---\n\n# HIMMEL-1: x\n');
    const git = join(root, 'git');
    mkdirSync(git);
    execFileSync('git', ['-C', git, 'init', '-q', '-b', 'main']);
    execFileSync('git', ['-C', git, '-c', 'user.name=t', '-c', 'user.email=t@e', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '--allow-empty', '-m', 'init']);
    writeFileSync(join(root, 'gh'), '#!/bin/sh\necho "[]"\n', { mode: 0o755 });
    writeFileSync(join(root, 'jira.js'), "const a = process.argv.slice(2);\nfor (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);\n");
    mkdirSync(join(root, 'home'));
    const nd = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'next-dispatchable.sh');
    const r = spawnSync('bash', [nd, '--mirror', m, '--no-classify', '--top', '5'], {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH, HOME: join(root, 'home'), HANDOVER_DIR: join(root, 'home'), TICKET_STATUS_STATE_DIR: join(root, 'ts'),
        HIMMEL_ADMISSIONS_LEDGER: join(root, 'none.jsonl'), NEXT_DISPATCH_GIT_DIR: git, NEXT_DISPATCH_MAIN_REF: 'main',
        NEXT_DISPATCH_BODY_CACHE: 'off', NEXT_DISPATCH_GH_CMD: join(root, 'gh'), NEXT_DISPATCH_JIRA_CLI: join(root, 'jira.js'),
      },
    });
    const pool = /^# dropped from (\S+):/m.exec(r.stdout)?.[1];
    expect(pool, r.stdout + r.stderr).toBe('v1.1.9');
    expect(poolCurrent(tsv)).toBe(pool);
  });
});

describe('operatorWords', () => {
  it('a Verbatim: line with the words below it, under a chief header (699): the block, quotes dropped', () => {
    const f = 'Decision 699, operator, 2026-11-06, relayed by the bridge chat to chief TA.\n\nVerbatim:\n"9001 signed"\n\nReading is the bridge\'s, unconfirmed: signs HIMMEL-9001 v2.\n';
    expect(operatorWords(f)).toBe('9001 signed');
  });

  it('the words on the Verbatim: line itself, chief text straight below (662): that line only', () => {
    const f = 'Operator, 2026-11-06, SM window, answering SM\'s two questions.\nVerbatim: "1 ok 2. yes"\nDecision 662 is the "1 ok" part.\nRead, unconfirmed: the paid run is approved.\n';
    expect(operatorWords(f)).toBe('1 ok 2. yes');
  });

  it('a file with no Verbatim: line (684) is refused, naming the fix', () => {
    expect(() => operatorWords('when fallback is enabled, in general we don\'t auto move things to api\n')).toThrow(/no line starting 'Verbatim:'; add one/);
  });

  it('two Verbatim: lines (545): the first block only', () => {
    const f = 'Decision 545 — operator, 2026-11-04, QX console\n\nVerbatim: "HIMMEL-8967 A"\n\nChief then listed 25 keys.\n\nVerbatim: "ok but 2 and 3 needs to be in 1.1.3"\n';
    expect(operatorWords(f)).toBe('HIMMEL-8967 A');
  });
});
