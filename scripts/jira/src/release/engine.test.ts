import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  apply, claim, declare, fold, freeze, leaseAcquire, reopen, leaseRelease, operatorDecision, request, rule, state, takeover, withdraw,
  JudgeReplyError, LIVE_LOOKUP_MS, pull, readMirror, readOperatorRecords, rmRun, signSpec, specCheck, standing,
  type Ctx, type JiraPort, type Judge,
} from './engine.js';
import { execFileSync } from 'node:child_process';
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
import type { IssueSnap, OperatorRow, RulingRow } from './types.js';
import { appendChain, breakStaleLock, loadKey, readChain, withLockAsync } from './ledger.js';

class FakeJira implements JiraPort {
  fv = new Map<string, string[]>();
  live = new Map<string, IssueSnap>();
  async issue(key: string) { return this.live.get(key) ?? null; }
  comments = new Map<string, Array<{ id: string; body: string }>>();
  posted = 0;
  async fixVersions(key: string) { return [...(this.fv.get(key) ?? [])]; }
  async setFixVersion(key: string, op: 'add' | 'remove', v: string) {
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

describe('release state admissions_today (HIMMEL-7153)', () => {
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

describe('release engine (HIMMEL-6796)', () => {
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

  it('an applied INTAKE ADMIT appends one rm-admit ledger row, and a replay adds no second (HIMMEL-6918)', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    await apply(ctx(rmEnv), r.id);
    await apply(ctx(rmEnv), r.id);
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows).toMatchObject([{ version: 'v1', key: 'K-2', kind: 'rm-admit', reason: 'regression: breaks the console', by: 'rm-1' }]);
  });

  it('a re-admission after a removal appends a second rm-admit row, and its replay adds no third (HIMMEL-6796)', async () => {
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
  ])('a REVERSION MOVE into a %s version appends the destination rm-admit and the source rm-remove, and an applied-phase replay adds none (HIMMEL-7059)', async (_kind, from, to) => {
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

  it('an INTAKE ADMIT replayed from the applied phase appends no second rm-admit row (HIMMEL-7059)', async () => {
    await setup();
    const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    expect((await applyThenReplay(r.id)).phase).toBe('receipted');
    const rows = readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    expect(rows.map((x) => [x.kind, x.key, x.version, x.ruling])).toEqual([['rm-admit', 'K-2', 'v1', r.id]]);
  });

  it('an INTAKE ADMIT with an unwritable ledger refuses before Jira is touched (HIMMEL-6918)', async () => {
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

  describe('a newer operator record supersedes an older operator-authority ruling (HIMMEL-8348)', () => {
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

describe('release fold (HIMMEL-7158)', () => {
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

describe('rm-run: the on-demand release manager (HIMMEL-7201)', () => {
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

  it('a failed judge rules nothing, releases the lease, and the next run reclaims', async () => {
    declared();
    ask('K-2');
    await expect(rmRun(ctx(), async () => { throw new Error('HOLD'); })).rejects.toThrow(/HOLD/);
    expect(state(ctx()).lease).toMatchObject({ epoch: 1, released: true });
    expect(state(ctx()).requests.claimed).toEqual(['Q-R1-0001']);
    expect(await rmRun(ctx(), admitAll)).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 /));
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

  it('a decision the engine refuses is reported, its request is closed, and a re-file opens a new qid (HIMMEL-8348)', async () => {
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

describe('release withdraw (HIMMEL-7434)', () => {
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

describe('rm-run bulk guard (HIMMEL-6778)', () => {
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

describe('a blocker of a current-version ticket is pulled into the current version (HIMMEL-8350)', () => {
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

describe('signed minerva specs (HIMMEL-8353 C1a)', () => {
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

  it('two unsuperseded records over one key: the newest decides', () => {
    declared();
    const a = spec('K-1-a.md');
    const b = spec('K-1-b.md', join(root, 'specs-b'));
    sign(sctx(), ['K-1'], a);
    const later = sign({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, ['K-1', 'K-2'], b);
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${b} ${later.id}`, `SPEC ok K-2 ${b} ${later.id}`]);
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
