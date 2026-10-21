import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  apply, claim, declare, freeze, leaseAcquire, leaseRelease, operatorDecision, request, rule, state, takeover,
  type Ctx, type JiraPort,
} from './engine.js';
import { withLockAsync } from './ledger.js';

class FakeJira implements JiraPort {
  fv = new Map<string, string[]>();
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

function mirror(issues: Array<{ key: string; fixVersions: string[]; status?: string }>, lastSync = '2026-10-21T09:00:00.000Z') {
  const dir = join(root, 'mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync, total: issues.length }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, 'type: "Task"', `status: "${i.status ?? 'To Do'}"`, 'priority: "Medium"',
      `fixVersions: ${JSON.stringify(i.fixVersions)}`, 'resolution: null', '---', '', `# ${i.key}`, '',
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

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'release-engine-'));
  jira = new FakeJira();
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

  it('keeps operator acts and requests out of the RM and of console-spawned legs', () => {
    expect(() => declare(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' }))
      .toThrow(/console-spawned leg/);
    declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '1', verbatim: 'v', mode: 'observe' });
    expect(() => request(ctx(rmEnv), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'rm' }))
      .toThrow(/the console writes requests/);
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

  it('a frozen baseline is immutable: editing it breaks verification', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    expect(state(ctx()).burndown.v1.baseline).toBe(1);
    const p = join(root, 'release', 'R1', 'baseline-v1-g1.json');
    writeFileSync(p, readFileSync(p, 'utf8').replace('"K-1"', '"K-8"'));
    expect(state(ctx()).status).toBe('UNKNOWN');
  });
});
