import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, claim, coreBypass, declare, freeze, leaseAcquire, leaseRelease, operatorDecision, releaseForProject, request, requestWithWords, rule, state, takeover,
  pull, rmRun,
  type Ctx, type JiraPort, type Judge,
} from './engine.js';
import { declsFor, leaveGate, type Leave } from './leave.js';
import { doorJudge } from './door.js';
import { execFileSync, spawnSync } from 'node:child_process';
import * as pinned from './pinned.js';
import * as ledger from './ledger.js';

// A hook that runs after a minerva script returns, to edit the spec mid-sign.
const afterMinerva = vi.hoisted(() => ({ fn: null as null | (() => void) }));
// Relocate only the module's anchor lookup into a disposable primary. Every Git identity/registration
// query still executes Git, and both validator files are copied byte-for-byte from the real primary.
const sourceFixture = vi.hoisted(() => ({ primary: null as string | null }));
const signingLock = vi.hoisted(() => ({ fn: null as null | (() => void) }));
vi.mock('node:fs', async (orig) => {
  const m = await orig<typeof import('node:fs')>();
  return { ...m, openSync: ((...a: Parameters<typeof m.openSync>) => {
    const fd = m.openSync(...a);
    if (String(a[0]).endsWith('/release/R1/.lock')) {
      const fn = signingLock.fn;
      signingLock.fn = null;
      fn?.();
    }
    return fd;
  }) as typeof m.openSync };
});
const cappedCalls = vi.hoisted(() => [] as string[][]);
// The capped carry v2 hook: every capped-fold spawn attempt is recorded before the real call; armed, a `--keys` spawn is answered by `fn` instead of a child.
const cappedSpawn = vi.hoisted(() => ({ fn: null as null | ((args: string[], options: unknown) => string), options: [] as unknown[], attempts: [] as string[][] }));
const judgeChild = vi.hoisted(() => ({ on: false, reply: '[]', spawns: [] as string[] }));
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const execFileSync = ((...a: Parameters<typeof m.execFileSync>) => {
    const args = a[1] as string[] | undefined;
    const script = String(args?.[0] ?? '');
    if (judgeChild.on && /(usage-preflight|profile-settings|launch-record|claude-api)\.sh$/.test(script)) {
      judgeChild.spawns.push(basename(script));
      if (script.endsWith('claude-api.sh')) throw Object.assign(new Error('claude-api: refused in a test'), { status: 2 });
      return (script.endsWith('usage-preflight.sh') ? 'PROCEED\n' : script.endsWith('profile-settings.sh') ? '/dev/null\n' : '') as never;
    }
    if (sourceFixture.primary && a[0] === 'git' && args?.[0] === '-C'
      && args[1] === dirname(fileURLToPath(import.meta.url)) && args.at(-1) === '--git-common-dir') {
      return m.execFileSync('git', ['-C', sourceFixture.primary, ...args.slice(2)], a[2]);
    }
    if (args?.[1] === 'capped-fold') cappedSpawn.attempts.push([...args]);
    if (cappedSpawn.fn && args?.[1] === 'capped-fold' && args.includes('--keys')) { cappedSpawn.options.push(a[2]); cappedCalls.push([...args]); return cappedSpawn.fn([...args], a[2]) as never; }
    const r = m.execFileSync(...a);
    if ((a[1] as string[] | undefined)?.[1] === 'capped-fold') cappedCalls.push([...(a[1] as string[])]);
    if (String((a[1] as string[] | undefined)?.[0] ?? '').endsWith('minerva-trace-lint.sh')) afterMinerva.fn?.();
    return r;
  }) as typeof m.execFileSync;
  const execFile = ((...a: unknown[]) => {
    if (!judgeChild.on || a[0] !== 'claude') return (m.execFile as (...x: unknown[]) => unknown)(...a);
    judgeChild.spawns.push('claude');
    const done = a[3] as (err: Error | null, out: string, errOut: string) => void;
    setImmediate(() => done(null, JSON.stringify({ is_error: false, result: judgeChild.reply }), ''));
    return { stdin: { on: () => undefined, end: () => undefined } };
  }) as typeof m.execFile;
  const spawnSync = ((...a: Parameters<typeof m.spawnSync>) => {
    if (judgeChild.on && String((a[1] as string[] | undefined)?.[0] ?? '').endsWith('api-roles.mjs')) {
      judgeChild.spawns.push('api-roles.mjs');
      return { status: 1, stdout: '', stderr: '', signal: null, pid: 0, output: [] } as never;
    }
    return m.spawnSync(...a);
  }) as typeof m.spawnSync;
  return { ...m, execFileSync, execFile, spawnSync };
});
import type { EventRow, IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';
import { appendAdmission, readAdmissions } from '../commands/admissions-ledger.js';
import { breakStaleLock, loadKey, readChain, withLockAsync } from './ledger.js';

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

function mirror(issues: Array<{ key: string; fixVersions: string[]; status?: string; category?: string; resolution?: string; sector?: string; type?: string; blockedBy?: string[]; priority?: string; labels?: string[] }>, lastSync = '2026-10-21T09:00:00.000Z') {
  const dir = join(root, 'mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync, total: issues.length }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, `type: "${i.type ?? 'Task'}"`, `status: "${i.status ?? 'To Do'}"`,
      ...(i.category ? [`statusCategory: "${i.category}"`] : []), `priority: "${i.priority ?? 'Medium'}"`,
      ...(i.labels ? [`labels: ${JSON.stringify(i.labels)}`] : []),
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
const RUNS_AS_ROOT = process.getuid?.() === 0;

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

  // 8731: the Jira write lands, then the admissions ledger refuses the row. The ruling stays `applied`, state names the
  // unfinished action and its owner, and the next normal run writes the missing row and receipt exactly once.
  describe('8731 interruption between the Jira write and the admissions row', () => {
    const ledger = () => process.env.HIMMEL_ADMISSIONS_LEDGER!;
    const rows = () => (existsSync(ledger()) ? readFileSync(ledger(), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    const lockLedgerAfterJiraWrite = () => {
      const write = jira.setFixVersion.bind(jira);
      jira.setFixVersion = async (k, op, v) => {
        await write(k, op, v);
        chmodSync(ledger(), 0o444);
      };
    };
    const noJudge: Judge = async () => { throw new Error('no request is claimed, so the judge is never asked'); };

    it.skipIf(RUNS_AS_ROOT)('INTAKE: partial state is visible with an empty queue and a fresh mirror, and the next run converges once', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1'] }]);
      const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req);
      lockLedgerAfterJiraWrite();
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/EACCES/);
      leaseRelease(ctx(rmEnv));
      expect(jira.fv.get('K-2')).toEqual(['v1']);
      expect(rows().filter((x) => x.kind === 'rm-admit' && x.key === 'K-2')).toEqual([]);
      const s = state(ctx());
      expect(s.requests.open).toEqual([]);
      expect(s.unfinished_rulings).toEqual([{
        ruling: r.id, req: q.req, key: 'K-2', phase: 'applied', op: 'add backlog→v1', status: 'replay', owner: 'release-manager', next: 'jira release rm-run R1', observed: null,
      }]);
      chmodSync(ledger(), 0o644);
      const lines = await rmRun(ctx(), noJudge);
      expect(lines.join('\n')).toContain(`RULING ${r.id}`);
      expect(rows().filter((x) => x.kind === 'rm-admit' && x.key === 'K-2')).toHaveLength(1);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
      expect(jira.posted).toBe(1);
      expect(await rmRun(ctx(), noJudge)).toEqual(['RM-RUN R1: nothing pending']);
      expect(rows().filter((x) => x.kind === 'rm-admit' && x.key === 'K-2')).toHaveLength(1);
      expect(jira.posted).toBe(1);
    });

    it.skipIf(RUNS_AS_ROOT).each(['the destination row', 'the source row', 'neither row'] as const)('MOVE across versions: either half of the two rows may be missing and each is written once (%s landed)', async (landedRow) => {
      await setup();
      jira.fv.set('K-2', ['v1']);
      const q = request(ctx(), { verb: 'REVERSION', key: 'K-2', from_v: 'v1', to_v: 'v2', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req, { outcome: 'MOVE', op: { kind: 'move', from_v: 'v1', to_v: 'v2' } });
      lockLedgerAfterJiraWrite();
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/EACCES/);
      leaseRelease(ctx(rmEnv));
      expect(jira.fv.get('K-2')).toEqual(['v2']);
      expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'applied', op: 'move v1→v2' }]);
      chmodSync(ledger(), 0o644);
      if (landedRow === 'the destination row') appendAdmission({ version: 'v2', key: 'K-2', kind: 'rm-admit', reason: 'regression: breaks the console', by: 'rm-1', ruling: r.id });
      if (landedRow === 'the source row') appendAdmission({ version: 'v1', key: 'K-2', kind: 'rm-remove', reason: 'regression: breaks the console', by: 'rm-1', ruling: r.id });
      await rmRun(ctx(), noJudge);
      const mine = rows().filter((x) => x.key === 'K-2').map((x) => [x.kind, x.version, x.ruling]);
      expect([...mine].sort()).toEqual([['rm-admit', 'v2', r.id], ['rm-remove', 'v1', r.id]]);
      await rmRun(ctx(), noJudge);
      expect(rows().filter((x) => x.key === 'K-2')).toHaveLength(2);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
    });

    it.skipIf(RUNS_AS_ROOT)('an already-member no-op write still gets its row and receipt on replay, with no further Jira write', async () => {
      await setup();
      jira.fv.set('K-2', ['v1']);
      const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req);
      const read = jira.fixVersions.bind(jira);
      let reads = 0;
      jira.fixVersions = async (k) => { const got = await read(k); if (++reads === 2) chmodSync(ledger(), 0o444); return got; };
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow(/EACCES/);
      leaseRelease(ctx(rmEnv));
      chmodSync(ledger(), 0o644);
      expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'applied' }]);
      await rmRun(ctx(), noJudge);
      expect(jira.writes).toBe(0);
      expect(rows().filter((x) => x.kind === 'rm-admit' && x.key === 'K-2')).toHaveLength(1);
      expect(jira.posted).toBe(1);
      expect(jira.comments.get('K-2')?.map((c) => c.body.startsWith(`[release-ruling ${r.id}] `))).toEqual([true]);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
    });

    it('an intent whose Jira write never landed is listed too', async () => {
      await setup();
      const q = request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req);
      expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'intent', op: 'add backlog→v1' }]);
    });
  });

  // B (8731): the cross-version move writes the source removal and then the destination add; a crash between them leaves the key in neither.
  describe('8731 B: a move interrupted after the source removal', () => {
    const ledger = () => process.env.HIMMEL_ADMISSIONS_LEDGER!;
    const rows = () => (existsSync(ledger()) ? readFileSync(ledger(), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    const noJudge: Judge = async () => { throw new Error('no request is claimed, so the judge is never asked'); };
    const journalFile = () => join(root, 'version-writes.jsonl');
    const withJournal = (c: Ctx): Ctx => ({ ...c, env: { ...c.env, HIMMEL_VERSION_WRITES: journalFile() } });
    const journal = (row: Record<string, unknown>) => writeFileSync(journalFile(), `${JSON.stringify(row)}\n`, { flag: 'a' });
    const rmWrite = (extra: Record<string, unknown> = {}) => ({ ts: '2026-10-21T10:00:01.000Z', key: 'K-2', from: ['v1'], to: [], mechanism: 'rm-apply', entry: '5001', ...extra });

    const decide = (at: string, keys: string[], op: string, from_v: string | null, to_v: string | null) =>
      operatorDecision({ ...ctx(), now: () => new Date(at) }, { decision: '151', keys, op, from_v, to_v, verbatim: 'x' });

    async function interrupted(opts: { release?: boolean; required?: boolean; operator?: boolean } = {}) {
      await setup();
      const source = opts.required ? 'v2' : 'v1';
      const destination = opts.required ? 'v1' : 'v2';
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: [source] }]);
      jira.fv.set('K-2', [source]);
      const cited = opts.operator ? decide('2026-10-21T09:00:00.000Z', ['K-2'], 'move', source, destination) : undefined;
      const q = request(ctx(), { verb: opts.required ? 'INTAKE' : 'REVERSION', key: 'K-2', from_v: source, to_v: destination,
        why: 'w', evidence: opts.required ? { follow_up_of: 'K-1', remainder: true } : {}, from: 'console' });
      claim(ctx(rmEnv));
      const r = admit(q.req, { outcome: opts.required ? 'ADMIT' : 'MOVE', op: { kind: 'move', from_v: source, to_v: destination },
        ...(cited ? { authority: { kind: 'operator' as const, ref: cited.id } } : {}) });
      const write = jira.setFixVersion.bind(jira);
      jira.setFixVersion = async (k, op, v) => {
        if (op === 'add') {
          await write(k, 'remove', source);
          throw new Error('crash before the destination add');
        }
        await write(k, op, v);
      };
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow('crash before the destination add');
      jira.setFixVersion = write;
      if (opts.release !== false) leaseRelease(ctx(rmEnv));
      expect(jira.fv.get('K-2')).toEqual([]);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: [] }]);
      return { q, r };
    }

    it('keeps required-parent and unfinished blocked-move actions consistent', async () => {
      const { r } = await interrupted({ required: true });
      const result = state(ctx());
      const unfinished = result.unfinished_rulings[0];
      expect(unfinished).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
      expect(result.remainder_conflicts).toMatchObject([{ parent: 'K-1', child: 'K-2', ruling: r.id,
        owner: 'chief', next: unfinished.next }]);
    });

    it('a door ruling whose key holds both versions names the one --chief-reason request, never a hand --remove or rm-run (P1)', async () => {
      const { r } = await interrupted();
      jira.fv.set('K-2', ['v1', 'v2']);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1', 'v2'] }]);
      const unfinished = state(ctx()).unfinished_rulings[0];
      expect(unfinished).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
      expect(unfinished.next).toBe(`jira release request R1 --verb REVERSION --key K-2 --from v1 --to v2 --why "finish ${r.id}: K-2 holds both v1 and v2" --chief-reason "repair of ${r.id}, interrupted between its add and its remove"`);
      expect(unfinished.next).not.toMatch(/--remove|rm-run/);
    });

    it.skipIf(RUNS_AS_ROOT)('checks admissions writability before completing an attributable new-epoch move', async () => {
      const { r } = await interrupted();
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      chmodSync(ledger(), 0o444);
      const writes = jira.writes;
      const result = await rmRun(withJournal(ctx()), noJudge);
      expect(result.join('\n')).toContain(`PENDING ${r.id}`);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      chmodSync(ledger(), 0o644);
      await rmRun(withJournal(ctx()), noJudge);
      expect(jira.fv.get('K-2')).toEqual(['v2']);
    });

    it('RED: with no proof the removal was this ruling\'s own, state is BLOCKED with the observed state, the owner and a concrete repair, and rm-run writes nothing', async () => {
      const { r } = await interrupted();
      const [u] = state(ctx()).unfinished_rulings;
      expect(u).toMatchObject({ ruling: r.id, key: 'K-2', phase: 'intent', status: 'blocked', owner: 'chief' });
      expect(u.observed).toBe('K-2 is in no version (mirror); the move wants v1 -> v2');
      expect(u.next).toContain('jira fix-version K-2 --add v2');
      expect(u.next).toContain('jira fix-version K-2 --add v1');
      expect(u.next).toContain('jira release rm-run R1');
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(lines.join('\n')).toMatch(new RegExp(`PENDING ${r.id}: .*partly applied.*K-2 is in no version.*jira fix-version K-2 --add v2`));
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      // The same state reads the same on the next run: a recorded failure, never a rollback and never an endless rm-run.
      expect(state(ctx()).unfinished_rulings[0]).toMatchObject({ status: 'blocked', owner: 'chief' });
    });

    it('U5: repeated rm-runs on an unchanged blocked move record the mismatch once; the lease still advances and the later replay is not suppressed', async () => {
      const { r } = await interrupted();
      const events = () => readChain<EventRow>(join(ctx().dir, 'events.jsonl'), loadKey(ctx().keyPath)).verified.filter((e) => e.kind === 'ruled' && e.ruling === r.id);
      const mismatches = () => events().filter((e) => e.readback === 'mismatch').length;
      expect(await rmRun(withJournal(ctx()), noJudge)).toEqual(expect.arrayContaining([expect.stringContaining(`PENDING ${r.id}`)]));
      expect(mismatches()).toBe(1);
      const epoch = state(ctx()).lease?.epoch ?? 0;
      const total = events().length;
      for (let i = 0; i < 3; i += 1) expect(await rmRun(withJournal(ctx()), noJudge)).toEqual(expect.arrayContaining([expect.stringContaining(`PENDING ${r.id}`)]));
      expect(mismatches()).toBe(1);
      expect(events()).toHaveLength(total);
      expect(state(ctx()).lease?.epoch).toBeGreaterThan(epoch);
      expect(state(ctx()).unfinished_rulings[0]).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
      // the chief's hand repair is a change: the replay then writes its own ok event once, whatever the earlier mismatch
      await jira.setFixVersion('K-2', 'add', 'v2');
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v2'] }]);
      await rmRun(withJournal(ctx()), noJudge);
      expect(events().filter((e) => e.readback === 'ok')).toHaveLength(1);
      expect(mismatches()).toBe(1);
    });

    it('RED: when the journal binds the removal to this ruling and it is still the newest entry, the new epoch finishes the add once', async () => {
      const { r } = await interrupted();
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      expect(state(withJournal(ctx())).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'replay', owner: 'release-manager', next: 'jira release rm-run R1' }]);
      const epoch = state(ctx()).lease?.epoch ?? 0;
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(lines.join('\n')).toContain(`RULING ${r.id}`);
      expect(state(ctx()).lease?.epoch).toBeGreaterThan(epoch);
      expect(jira.writes - writes, 'the one write left is the destination add').toBe(1);
      expect(jira.fv.get('K-2')).toEqual(['v2']);
      expect(rows().filter((x) => x.key === 'K-2').map((x) => [x.kind, x.version, x.ruling])).toEqual([['rm-admit', 'v2', r.id], ['rm-remove', 'v1', r.id]]);
      expect(jira.posted).toBe(1);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
      expect(await rmRun(withJournal(ctx()), noJudge)).toEqual(['RM-RUN R1: nothing pending']);
      expect(rows().filter((x) => x.key === 'K-2')).toHaveLength(2);
      expect(jira.posted).toBe(1);
    });

    // The replay's destination add is a write against the operator's latest placing record when that record is newer than the ruling and puts the key elsewhere.
    const finishes = async (id: string) => {
      expect(state(withJournal(ctx())).unfinished_rulings).toMatchObject([{ ruling: id, status: 'replay', owner: 'release-manager' }]);
      expect((await rmRun(withJournal(ctx()), noJudge)).join('\n')).toContain(`RULING ${id}`);
      expect(jira.fv.get('K-2')).toEqual(['v2']);
      expect(rows().filter((x) => x.key === 'K-2').map((x) => [x.kind, x.version, x.ruling])).toEqual([['rm-admit', 'v2', id], ['rm-remove', 'v1', id]]);
      expect(jira.posted).toBe(1);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
    };

    it('an operator record newer than the ruling that takes the key out of the destination voids the replay: nothing is written, the record is named and no line is owed (X1)', async () => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], 'remove', 'v2', null);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(lines.join('\n')).toMatch(new RegExp(`VOID ${r.id} .*${newer.id}`));
      expect(lines.join('\n')).not.toMatch(/--remove/);
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      expect(jira.posted).toBe(0);
      expect(state(withJournal(ctx())).unfinished_rulings).toEqual([]);
      expect((await rmRun(withJournal(ctx()), noJudge)).join('\n')).not.toContain('K-2');
      expect(jira.writes).toBe(writes);
    });

    it('state reads that replay as blocked to the chief with the newer record named before the run voids it', async () => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], 'remove', 'v2', null);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const unfinished = () => state(withJournal(ctx())).unfinished_rulings;
      expect(unfinished()).toMatchObject([{ ruling: r.id, key: 'K-2', phase: 'intent', status: 'blocked', owner: 'chief', observed: 'K-2 is in no version (mirror); the move wants v1 -> v2' }]);
      expect(unfinished()[0].next).toContain(newer.id);
      expect(unfinished()[0].next).not.toMatch(/--remove|--add/);
      await rmRun(withJournal(ctx()), noJudge);
      expect(unfinished()).toEqual([]);
    });

    it.each([
      ['puts it in a third version', 'add', null, 'v3', 'v3'],
      ['moves it out of the destination into a third version', 'move', 'v2', 'v3', 'v3'],
      ['keeps it in the source', 'keep', 'v1', 'v1', 'v1'],
      ['takes it out of the source', 'remove', 'v1', null, null],
    ] as Array<[string, string, string | null, string | null, string | null]>)('an operator record newer than the ruling that %s voids the replay, writes nothing and prints at most its one add line (X1, X2)', async (_name, op, from, to, lands) => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], op, from, to);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const writes = jira.writes;
      const lines = (await rmRun(withJournal(ctx()), noJudge)).join('\n');
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(lines).toMatch(new RegExp(`VOID ${r.id} .*${newer.id}`));
      expect(lines).not.toMatch(/--remove/);
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      expect(jira.posted).toBe(0);
      if (lands === null) {
        expect(lines).not.toMatch(/--add/);
        expect(state(withJournal(ctx())).unfinished_rulings).toEqual([]);
        return;
      }
      const line = `jira fix-version K-2 --add ${lands} --by ${newer.id}`;
      expect(lines).toContain(line);
      expect(state(withJournal(ctx())).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'blocked', owner: 'chief', next: line }]);
      await jira.setFixVersion('K-2', 'add', lands, { by: newer.id });
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: [lands] }]);
      expect(jira.fv.get('K-2')).toEqual([lands]);
      expect(state(withJournal(ctx())).unfinished_rulings).toEqual([]);
      expect((await rmRun(withJournal(ctx()), noJudge)).join('\n')).not.toContain('K-2');
    });

    it.each([
      ['no operator record newer than the ruling', () => undefined],
      ['a newer operator record about another key', () => decide('2026-10-21T10:00:05.000Z', ['K-1'], 'remove', 'v2', null)],
      ['a newer operator record that puts the key in the destination', () => decide('2026-10-21T10:00:05.000Z', ['K-2'], 'add', null, 'v2')],
      ['a newer operator record that places nothing', () => decide('2026-10-21T10:00:05.000Z', ['K-2'], 'none', null, null)],
      ['an operator record at the ruling\'s own instant that takes the key out of the destination', () => decide('2026-10-21T10:00:00.000Z', ['K-2'], 'remove', 'v2', null)],
      ['a last operator word that puts the key back in the destination after one that took it out', () => {
        decide('2026-10-21T10:00:05.000Z', ['K-2'], 'remove', 'v2', null);
        return decide('2026-10-21T10:00:06.000Z', ['K-2'], 'add', null, 'v2');
      }],
    ] as Array<[string, () => unknown]>)('an operator-decided move still finishes its add once with %s', async (_name, record) => {
      const { r } = await interrupted({ operator: true });
      record();
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      await finishes(r.id);
    });

    it('an operator record older than the ruling that places the key elsewhere does not stop the replay', async () => {
      const { r } = await interrupted();
      decide('2026-10-21T09:00:00.000Z', ['K-2'], 'remove', 'v2', null);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      await finishes(r.id);
    });

    it.each([
      ['a later Fix Version entry by someone else (known only live: state reads replay until a run refuses it)', () => { jira.entries.set('K-2', '5002'); journal(rmWrite()); }, 'replay'],
      ['a journal row from before the ruling', () => { jira.entries.set('K-2', '5001'); journal(rmWrite({ ts: '2026-10-21T09:00:00.000Z' })); }],
      ['a hand write in the journal, not the RM\'s', () => { jira.entries.set('K-2', '5001'); journal(rmWrite({ mechanism: 'hand' })); }],
      ['a journal row for another key', () => { jira.entries.set('K-2', '5001'); journal(rmWrite({ key: 'K-9' })); }],
      ['a journal row whose resulting set is not the one Jira shows', () => { jira.entries.set('K-2', '5001'); journal(rmWrite({ to: ['v3'] })); }],
      ['no journal at all (a lost response never reached the hook)', () => { jira.entries.set('K-2', '5001'); }],
    ] as Array<[string, () => void, ('replay' | undefined)?]>)('conflicting or missing evidence stays BLOCKED and writes nothing: %s', async (_name, evidence, before) => {
      const { r } = await interrupted();
      evidence();
      expect(state(withJournal(ctx())).unfinished_rulings[0]).toMatchObject({ ruling: r.id, status: before ?? 'blocked' });
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(lines.join('\n')).toMatch(/PENDING .*partly applied/);
      // The refusal is recorded (a mismatch event), so the next read is blocked and names the chief, never rm-run alone.
      expect(state(withJournal(ctx())).unfinished_rulings[0]).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      expect(jira.posted).toBe(0);
    });

    it('external membership in the destination alone reads as landed: the replay writes the rows and the receipt and no Jira write', async () => {
      const { r } = await interrupted();
      jira.fv.set('K-2', ['v2']);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v2'] }]);
      const writes = jira.writes;
      await rmRun(ctx(), noJudge);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual(['v2']);
      expect(rows().filter((x) => x.key === 'K-2').map((x) => [x.kind, x.version, x.ruling])).toEqual([['rm-admit', 'v2', r.id], ['rm-remove', 'v1', r.id]]);
      expect(jira.posted).toBe(1);
    });

    it('external membership in a third version is never completed over: Jira shows a set the ruling did not write', async () => {
      const { r } = await interrupted();
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      jira.fv.set('K-2', ['v3']);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v3'] }]);
      expect(state(withJournal(ctx())).unfinished_rulings[0]).toMatchObject({ ruling: r.id, status: 'blocked', observed: 'K-2 is in v3 (mirror); the move wants v1 -> v2' });
      const writes = jira.writes;
      await rmRun(withJournal(ctx()), noJudge);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual(['v3']);
    });

    it('while the writing run still holds its lease the gap is in flight, not blocked', async () => {
      const { r } = await interrupted({ release: false });
      expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'replay', owner: 'release-manager' }]);
    });

    it.each([
      ['the source is already gone, so its remove is not sent again', [] as string[], ['add v2']],
      ['the destination is already held, so its add is not sent again', ['v1', 'v2'], ['remove v1']],
    ] as Array<[string, string[], string[]]>)('characterization (a disproven assumption): the SAME epoch\'s replay already completes the add, each write guarded by the version it names: %s', async (_name, held, sent) => {
      const { r } = await interrupted({ release: false });
      if (held.length) jira.fv.set('K-2', held);
      const calls: string[] = [];
      const write = jira.setFixVersion.bind(jira);
      jira.setFixVersion = async (k, op, v) => { calls.push(`${op} ${v}`); return write(k, op, v); };
      expect((await apply(ctx(rmEnv), r.id)).phase).toBe('receipted');
      expect(calls).toEqual(sent);
      expect(jira.fv.get('K-2')).toEqual(['v2']);
      expect(rows().filter((x) => x.key === 'K-2').map((x) => x.kind)).toEqual(['rm-admit', 'rm-remove']);
    });

    it('a hand repair the blocked next command names ends it: the replay finds the move landed and writes the row and receipt once', async () => {
      const { r } = await interrupted();
      await jira.setFixVersion('K-2', 'add', 'v2');
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v2'] }]);
      expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'replay', owner: 'release-manager' }]);
      await rmRun(ctx(), noJudge);
      expect(rows().filter((x) => x.key === 'K-2').map((x) => [x.kind, x.version])).toEqual([['rm-admit', 'v2'], ['rm-remove', 'v1']]);
      expect(jira.posted).toBe(1);
      expect(state(ctx()).unfinished_rulings).toEqual([]);
    });
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

    it('a move the operator governs admits without the RM naming supersedes, and the ruling records it', async () => {
      const { prior, req } = await placedInV2();
      const o = decide('2026-10-21T11:00:00.000Z', 'move', 'v2', 'v1');
      const r = admit(req, pull);
      expect(r.supersedes).toEqual([prior]);
      expect(r.authority).toEqual({ kind: 'operator', ref: o.id });
      await apply(ctx(rmEnv), r.id);
      expect(jira.fv.get('K-2')).toEqual(['v1']);
    });

    it('with no operator record a move that omits supersedes still refuses', async () => {
      const { prior, req } = await placedInV2();
      expect(() => admit(req, pull)).toThrow(new RegExp(`supersedes must name ${prior}`));
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

  it.skipIf(RUNS_AS_ROOT)('a crash between the applied row and its event is repaired by the retry', async () => {
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

// 8731 (trace T8-de73eed2 clause 5): the whole request -> ruling -> apply -> readback path, with the process failing at each seam. After the
// failure the state reports the partial work and its owner, and one normal replay (a new lease epoch) finishes it exactly once: one Jira
// write at most, one admissions row, one ok event, one receipt comment, one receipted ruling, nothing left owed, and a further run does nothing.
describe('T8 U7: request, ruling, apply and readback converge once from every failure window', () => {
  const ledger = () => process.env.HIMMEL_ADMISSIONS_LEDGER!;
  const rows = () => (existsSync(ledger()) ? readFileSync(ledger(), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l) as { kind: string; key: string; version: string }) : []);
  const eventsFile = () => join(ctx().dir, 'events.jsonl');
  const chain = <T>(file: string) => readChain<T>(join(ctx().dir, file), loadKey(ctx().keyPath)).verified;
  const okEvents = () => chain<EventRow>('events.jsonl').filter((e) => e.kind === 'ruled' && e.key === 'K-2' && e.readback === 'ok').length;
  const receipted = () => chain<RulingRow>('rulings.jsonl').filter((r) => r.key === 'K-2' && r.phase === 'receipted').length;
  const admitAll: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const noJudge: Judge = async () => { throw new Error('the judge is never asked with nothing claimed'); };
  const declared = (member: boolean) => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    if (member) jira.fv.set('K-2', ['v1']);
    return request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  };

  type Window = 'write refused' | 'readback fails after the write' | 'event append refused' | 'ledger refused after the write' | 'receipt refused' | 'receipt posted, response lost';
  // Installs one fault; returns whether it fired and how to lift it.
  function inject(w: Window, member: boolean) {
    let fired = false;
    let armed = true;
    let wrote = false;
    let reads = 0;
    const set = jira.setFixVersion.bind(jira);
    const read = jira.fixVersions.bind(jira);
    const add = jira.addComment.bind(jira);
    jira.setFixVersion = async (k, op, v) => {
      if (armed && w === 'write refused') { fired = true; throw new Error('jira refused the write'); }
      await set(k, op, v);
      wrote = true;
    };
    jira.fixVersions = async (k) => {
      // the readback is the read after the write; an already-member key is not written, so its readback is the second read
      const readback = member ? ++reads === 2 : wrote;
      if (armed && !fired && readback && w === 'readback fails after the write') { fired = true; throw new Error('jira readback down'); }
      const got = await read(k);
      if (armed && !fired && readback && w === 'ledger refused after the write') { chmodSync(ledger(), 0o444); fired = true; }
      return got;
    };
    jira.addComment = async (k, body) => {
      if (armed && w === 'receipt refused') { fired = true; throw new Error('jira down before the receipt'); }
      const id = await add(k, body);
      if (armed && w === 'receipt posted, response lost') { fired = true; throw new Error('the response was lost'); }
      return id;
    };
    if (w === 'event append refused') {
      writeFileSync(eventsFile(), '', { flag: 'a' });
      chmodSync(eventsFile(), 0o444);
      fired = true;
    }
    return {
      fired: () => fired,
      lift: () => {
        armed = false;
        for (const f of [ledger(), eventsFile()]) if (existsSync(f)) chmodSync(f, 0o644);
      },
    };
  }

  const converged = async (member: boolean) => {
    expect(jira.fv.get('K-2')).toEqual(['v1']);
    expect(jira.writes).toBe(member ? 0 : 1);
    expect(rows().filter((x) => x.key === 'K-2')).toMatchObject([{ kind: 'rm-admit', version: 'v1' }]);
    expect(okEvents()).toBe(1);
    expect(chain<EventRow>('events.jsonl').filter((e) => e.readback === 'mismatch')).toEqual([]);
    expect(receipted()).toBe(1);
    expect(jira.posted).toBe(1);
    const s = state(ctx());
    expect(s.unfinished_rulings).toEqual([]);
    expect(s.requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
    const before = { writes: jira.writes, posted: jira.posted, rows: rows().length, events: chain<EventRow>('events.jsonl').length, rulings: chain<RulingRow>('rulings.jsonl').length };
    expect(await rmRun(ctx(), noJudge)).toEqual(['RM-RUN R1: nothing pending']);
    expect({ writes: jira.writes, posted: jira.posted, rows: rows().length, events: chain<EventRow>('events.jsonl').length, rulings: chain<RulingRow>('rulings.jsonl').length }).toEqual(before);
  };

  it('a request filed and never claimed is not lost: the next run rules it', async () => {
    declared(false);
    expect(state(ctx()).requests.open).toEqual(['Q-R1-0001']);
    await rmRun(ctx(), admitAll);
    await converged(false);
  });

  it('a claim whose judge dies returns to open and the next run rules it', async () => {
    declared(false);
    await expect(rmRun(ctx(), async () => { throw new Error('judge down'); })).rejects.toThrow(/judge down/);
    expect(state(ctx()).requests).toMatchObject({ open: ['Q-R1-0001'], claimed: [] });
    await rmRun(ctx(), admitAll);
    await converged(false);
  });

  it('a crash inside rule (the ruling row written, the request row not) is reopened by the replay and ruled once', async () => {
    const q = declared(false);
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    claim(ctx(rmEnv));
    const r = admit(q.req);
    const file = join(ctx().dir, 'requests.jsonl');
    writeFileSync(file, `${readFileSync(file, 'utf8').trimEnd().split('\n').slice(0, -1).join('\n')}\n`);
    expect(state(ctx()).requests.claimed).toEqual([q.req]);
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'intent', status: 'replay', owner: 'release-manager' }]);
    leaseRelease(ctx(rmEnv));
    await rmRun(ctx(), admitAll);
    await converged(false);
  });

  const windows: Array<[Window, boolean, 'intent' | 'applied']> = [
    ['write refused', false, 'intent'],
    ['readback fails after the write', false, 'intent'],
    ['event append refused', false, 'applied'],
    ['ledger refused after the write', false, 'applied'],
    ['receipt refused', false, 'applied'],
    ['receipt posted, response lost', false, 'applied'],
    ['readback fails after the write', true, 'intent'],
    ['event append refused', true, 'applied'],
    ['ledger refused after the write', true, 'applied'],
    ['receipt refused', true, 'applied'],
    ['receipt posted, response lost', true, 'applied'],
  ];
  // Two windows are made by a read-only file (chmod), which a superuser ignores: those rows skip as the older chmod row of this file does.
  const DIAGNOSTIC: Record<Window, RegExp> = {
    'write refused': /jira refused the write/,
    'readback fails after the write': /jira readback down/,
    'event append refused': /EACCES[^\n]*events\.jsonl/,
    'ledger refused after the write': /EACCES[^\n]*admissions-ledger\.jsonl/,
    'receipt refused': /jira down before the receipt/,
    'receipt posted, response lost': /the response was lost/,
  };
  const usesChmod = ([w]: [Window, boolean, string]) => w === 'event append refused' || w === 'ledger refused after the write';
  const windowRow = async (w: Window, member: boolean, phase: 'intent' | 'applied') => {
    declared(member);
    if (w === 'ledger refused after the write') writeFileSync(ledger(), '', { flag: 'a' });
    const fault = inject(w, member);
    const lines = await rmRun(ctx(), admitAll).catch((e: Error) => [`THREW ${e.message}`]);
    expect(fault.fired()).toBe(true);
    expect(lines.join('\n')).toMatch(/PENDING R-R1-0001|THREW/);
    expect(lines.join('\n'), w).toMatch(DIAGNOSTIC[w]);
    if (w === 'event append refused') {
      expect(rows().filter((x) => x.key === 'K-2'), 'nothing after the event is written').toEqual([]);
      expect(jira.posted, 'no receipt before the event').toBe(0);
    }
    const s = state(ctx());
    expect(s.unfinished_rulings).toMatchObject([{ ruling: 'R-R1-0001', key: 'K-2', phase, status: 'replay', owner: 'release-manager', next: 'jira release rm-run R1' }]);
    expect(s.lease).toMatchObject({ released: true });
    fault.lift();
    await rmRun(ctx(), admitAll);
    await converged(member);
  };
  const rowName = '%s (already a member: %s): the state reports the partial work, then one replay finishes it once';
  it.each(windows.filter((r) => !usesChmod(r)))(rowName, windowRow);
  it.skipIf(RUNS_AS_ROOT).each(windows.filter(usesChmod))(rowName, windowRow);
});

// 8674 / 9818 / 8731 (trace T8-de73eed2 clause 6): the 2026-11-16 correction audit as an offline seed. The fixture holds its ticket keys and
// record numbers; the operator words are synthetic text in a scratch decision file. 20 actual members had no matching signed placement
// while the mirror was fresh and the queue empty; one request per key with the operator's words, one normal RM run, then Jira = signed.
describe('T8 U7: seed from the 2026-11-16 correction audit', () => {
  type Seed = {
    decision: string; mismatch_before_correction: string[]; later_version_move: string; recovery_keys: string[]; required_by: Record<string, string>;
  };
  const seed = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'correction-audit-2026-11-16.json'), 'utf8')) as Seed;
  const WORDS = 'Correct the identified placement discrepancies into the release.';
  const ledgerRows = () => (existsSync(process.env.HIMMEL_ADMISSIONS_LEDGER!)
    ? readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l) as { kind: string; key: string; version: string })
    : []);
  const parents = Object.values(seed.required_by);
  const originals = seed.mismatch_before_correction;
  const plain = originals.filter((k) => k !== seed.later_version_move);
  const refreshMirror = () => mirror([
    ...parents.map((key) => ({ key, fixVersions: ['v1'] })),
    ...[...originals, ...seed.recovery_keys].map((key) => ({ key, fixVersions: jira.fv.get(key) ?? [] })),
  ]);
  const byKey = (list: string[]) => [...list].sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));

  it('the fixture holds the audit as recorded: 20 divergent keys, 9 recovery keys and the two required parents', () => {
    expect(seed.mismatch_before_correction).toHaveLength(20);
    expect(new Set(seed.mismatch_before_correction).size).toBe(20);
    expect(seed.mismatch_before_correction).toContain(seed.later_version_move);
    expect(seed.recovery_keys).toHaveLength(9);
    expect(seed.required_by).toEqual(Object.fromEntries([['HIMMEL-9953', 'HIMMEL-9914'], ['HIMMEL-9932', 'HIMMEL-9915']]));
  });

  it('the divergence is visible with a fresh mirror and an empty queue, and one normal path per key makes Jira equal the signed placement', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    mkdirSync(join(root, 'specs', 'decisions'), { recursive: true });
    writeFileSync(join(root, 'specs', 'decisions', `verbatim-decision-${seed.decision}-synthetic.txt`), `Synthetic words for this scratch fixture, not the operator's:\n\n"${WORDS}"\n`);
    for (const k of originals) jira.fv.set(k, ['v1']);
    // the later-version placement the audit names for 8474: signed in v2, while Jira shows it in v1
    appendAdmission({ version: 'v2', key: seed.later_version_move, kind: 'rm-admit', reason: 'an earlier ruling', by: 'rm-0', ruling: 'R-R1-9000' });
    // the current parents are already admitted members, as in the audit's 68 admitted open tickets
    for (const parent of parents) appendAdmission({ version: 'v1', key: parent, kind: 'rm-admit', reason: 'an earlier ruling', by: 'rm-0', ruling: 'R-R1-9001' });
    refreshMirror();

    // 1. Before correction: 20 actual members with no matching effective placement; nothing queued, nothing stale.
    const before = state(ctx());
    expect(byKey(before.leaks.unauthorized)).toEqual(byKey(originals.map((k) => `${k}@v1`)));
    expect(before.requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
    expect(before.inputs.mirror).not.toBe('UNKNOWN');
    expect(before.unfinished_rulings).toEqual([]);

    // 2. One request per key, each with its own words record; 9953 and 9932 carry their parents (never promoted to a placement).
    const ask = (key: string, verb: 'INTAKE' | 'REVERSION', from_v: string | null) => requestWithWords(ctx(), {
      verb, key, from_v, to_v: 'v1', why: 'the operator asked for this correction', from: 'console',
      evidence: seed.required_by[key] === undefined ? {} : { follow_up_of: seed.required_by[key], remainder: true },
    }, { decision: seed.decision, words: WORDS });
    for (const k of [...plain, ...seed.recovery_keys]) ask(k, 'INTAKE', null);
    ask(seed.later_version_move, 'REVERSION', 'v2');
    const queued = state(ctx());
    expect(queued.requests.open).toHaveLength(originals.length + seed.recovery_keys.length);
    expect(queued.words_records).toHaveLength(originals.length + seed.recovery_keys.length);
    expect(queued.words_records.every((w) => w.keys.length === 1 && w.verbatim === WORDS)).toBe(true);
    expect(queued.remainder_conflicts.map((c) => `${c.parent}>${c.child}:${c.phase}:${c.owner}`).sort())
      .toEqual(Object.entries(seed.required_by).map(([child, parent]) => `${parent}>${child}:open:release-manager`).sort());

    const judge: Judge = async (input) => input.requests.map((q) => {
      const ref = (q.evidence as { operator?: string } | null)?.operator ?? null;
      return q.verb === 'REVERSION'
        ? { req: q.req, outcome: 'MOVE', op: 'move' as const, from: q.from_v, to: q.to_v, sector: 'Ship loop', ground: 'operator record', reason: 'the superseding move', authority: 'operator' as const, ref }
        : { req: q.req, outcome: 'ADMIT', op: 'add' as const, from: null, to: 'v1', sector: 'Ship loop', ground: 'operator record', reason: 'the correction', authority: 'operator' as const, ref };
    });
    await rmRun(ctx(), judge);

    // 4. Verify both destinations: Jira, the admissions ledger and the signed state agree, and nothing is owed.
    refreshMirror();
    const after = state(ctx());
    expect(after.leaks).toEqual({ unauthorized: [], ruled_in_non_member: [] });
    expect(after.unfinished_rulings).toEqual([]);
    expect(after.requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
    expect(after.remainder_conflicts).toEqual([]);
    expect(after.refused_asks).toEqual([]);
    for (const k of [...originals, ...seed.recovery_keys]) expect(jira.fv.get(k)).toEqual(['v1']);
    expect(jira.writes).toBe(seed.recovery_keys.length);
    const inV1 = byKey(ledgerRows().filter((r) => r.kind === 'rm-admit' && r.version === 'v1').map((r) => r.key));
    expect(inV1).toEqual(byKey([...parents, ...originals, ...seed.recovery_keys]));
    expect(ledgerRows().filter((r) => r.key === seed.later_version_move).map((r) => `${r.kind}@${r.version}`)).toEqual(['rm-admit@v2', 'rm-admit@v1', 'rm-remove@v2']);
    expect(await rmRun(ctx(), judge)).toEqual(['RM-RUN R1: nothing pending']);
  });
});

describe('nothing leaves a version (S2)', () => {
  class CheckedJira extends FakeJira {
    order: string[] = [];
    refusals: string[] = [];
    own = new Set<string>();
    async setFixVersion(key: string, op: 'add' | 'remove', v: string, leave?: Leave) {
      const before = [...(this.fv.get(key) ?? [])];
      const after = op === 'add' ? [...new Set([...before, v])] : before.filter((x) => x !== v);
      const env = leaveEnv();
      const verdict = leaveGate({ key, before, after, mechanism: 'rm-apply', leave, ownAdds: this.own }, declsFor(key, env), env);
      if (!verdict.ok) {
        this.refusals.push(verdict.reason);
        throw new Error(verdict.reason);
      }
      this.order.push(`${op} ${v}`);
      await super.setFixVersion(key, op, v);
    }
  }
  const leaveEnv = () => ({ HIMMEL_RELEASE_STATE_DIR: join(root, 'release'), HIMMEL_RELEASE_KEY_DIR: join(root, 'keys') });
  const noJudge: Judge = async (input) => { throw new Error(`no request is claimed, so the judge is never asked: ${JSON.stringify(input.requests)}`); };
  const journalFile = () => join(root, 'version-writes.jsonl');
  const withJournal = (c: Ctx): Ctx => ({ ...c, env: { ...c.env, HIMMEL_VERSION_WRITES: journalFile() } });
  const journal = (row: Record<string, unknown>) => writeFileSync(journalFile(), `${JSON.stringify(row)}\n`, { flag: 'a' });
  let checked: CheckedJira;

  beforeEach(() => {
    checked = new CheckedJira();
    jira = checked;
    vi.stubEnv('HOME', join(root, 'home'));
    mkdirSync(join(root, 'home', '.himmel', 'state', 'jira-mirror'), { recursive: true });
    writeFileSync(join(root, 'home', '.himmel', 'state', 'jira-mirror', 'K.versions.tsv'), 'v0\ttrue\t\tfalse\nv1\tfalse\t\tfalse\nv2\tfalse\t\tfalse\nv3\tfalse\t\tfalse\n');
    declare(ctx(), { project: 'K', versions: ['v1', 'v2', 'v3'], decision: '106', verbatim: 'R = v1 + v2 + v3', mode: 'observe' });
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
  });

  const decide = (at: string, key: string, op: string, from_v: string | null, to_v: string | null) =>
    operatorDecision({ ...ctx(), now: () => new Date(at) }, { decision: '151', keys: [key], op, from_v, to_v, verbatim: 'x' });

  async function ruled(key: string, from: string, to: string | null, o: { operator?: boolean; crashOnRemove?: boolean } = {}) {
    checked.fv.set(key, [from]);
    mirror([{ key, fixVersions: [from] }]);
    const cited = o.operator ? decide('2026-10-21T09:00:00.000Z', key, 'move', from, to) : undefined;
    const q = request(ctx(), { verb: 'REVERSION', key, from_v: from, to_v: to, why: 'w', evidence: {}, from: 'console' });
    claim(ctx(rmEnv));
    const r = rule(ctx(rmEnv), {
      req: q.req, outcome: 'MOVE', op: { kind: 'move', from_v: from, to_v: to }, sector: 'Planning & tracking', ground: 'g', reason: 'r', supersedes: [],
      authority: cited ? { kind: 'operator', ref: cited.id } : { kind: 'rm', ref: null },
    });
    if (o.crashOnRemove) {
      const write = checked.setFixVersion.bind(checked);
      checked.setFixVersion = async (k, op, v, leave) => {
        if (op === 'remove') throw new Error('crash before the source remove');
        await write(k, op, v, leave);
      };
      await expect(apply(ctx(rmEnv), r.id)).rejects.toThrow('crash before the source remove');
      checked.setFixVersion = write;
      leaseRelease(ctx(rmEnv));
      mirror([{ key, fixVersions: [...(checked.fv.get(key) ?? [])].sort() }]);
    }
    return { q, r, cited };
  }

  it('a door move v2→v1 writes the add, then the remove, and passes under rule (1)', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1');
    await apply(ctx(rmEnv), r.id);
    expect(checked.order).toEqual(['add v1', 'remove v2']);
    expect(checked.fv.get('K-4')).toEqual(['v1']);
    expect(checked.refusals).toEqual([]);
  });

  it('a rule O move v1→v2 writes add-first and passes on the ruling\'s op', async () => {
    const { r } = await ruled('K-6', 'v1', 'v2', { operator: true });
    await apply(ctx(rmEnv), r.id);
    expect(checked.order).toEqual(['add v2', 'remove v1']);
    expect(checked.fv.get('K-6')).toEqual(['v2']);
  });

  it('a rule O move v1→null is one remove and passes on the ruling\'s op', async () => {
    const { r } = await ruled('K-7', 'v1', null, { operator: true });
    await apply(ctx(rmEnv), r.id);
    expect(checked.order).toEqual(['remove v1']);
    expect(checked.fv.get('K-7')).toEqual([]);
  });

  it('both operator moves are refused without the ruling\'s record', async () => {
    checked.fv.set('K-6', ['v1', 'v2']);
    await expect(checked.setFixVersion('K-6', 'remove', 'v1')).rejects.toThrow(/K-6: .*open version v1 with no operator record/);
    checked.fv.set('K-7', ['v1']);
    await expect(checked.setFixVersion('K-7', 'remove', 'v1')).rejects.toThrow(/K-7: .*open version v1/);
    expect(checked.fv.get('K-6')).toEqual(['v1', 'v2']);
    expect(checked.fv.get('K-7')).toEqual(['v1']);
  });

  it('an intent interrupted after the add reads as replay for the release manager, and the replay finishes with the remove (P2)', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    expect([...(checked.fv.get('K-4') ?? [])].sort()).toEqual(['v1', 'v2']);
    journal({ ts: '2026-10-21T10:00:01.000Z', key: 'K-4', from: ['v2'], to: ['v1', 'v2'], mechanism: 'rm-apply', entry: '5002' });
    checked.entries.set('K-4', '5002');
    expect(state(withJournal(ctx())).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'replay', owner: 'release-manager', next: 'jira release rm-run R1' }]);
    expect(state(withJournal(ctx())).unfinished_rulings.filter((u) => u.status === 'blocked')).toEqual([]);
    await rmRun(withJournal(ctx()), noJudge);
    expect(checked.fv.get('K-4')).toEqual(['v1']);
    expect(checked.order.at(-1)).toBe('remove v2');
    mirror([{ key: 'K-4', fixVersions: ['v1'] }]);
    expect(state(withJournal(ctx())).unfinished_rulings).toEqual([]);
  });

  it('the repair route of a door ruling holding both ends: VOID and the one --chief-reason request, which the door then finishes add-first (P1, X2, T5)', async () => {
    const { r, q } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    const line = `jira release request R1 --verb REVERSION --key K-4 --from v2 --to v1 --why "finish ${r.id}: K-4 holds both v2 and v1" --chief-reason "repair of ${r.id}, interrupted between its add and its remove"`;
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'blocked', owner: 'chief', next: line }]);
    const out = (await rmRun(ctx(), noJudge)).join('\n');
    expect(out).toContain(`VOID ${r.id}`);
    expect(out).toContain(line);
    expect(out).not.toMatch(/rm-run|--remove/);
    expect([...(checked.fv.get('K-4') ?? [])].sort()).toEqual(['v1', 'v2']);
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'void', status: 'blocked', owner: 'chief', next: line }]);
    expect(readChain<RequestRow>(join(ctx().dir, 'requests.jsonl'), loadKey(ctx().keyPath)).verified.filter((x) => x.req === q.req).at(-1)?.state).toBe('withdrawn:repair');
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    request(ctx(), { verb: 'REVERSION', key: 'K-4', from_v: 'v2', to_v: 'v1', why: `finish ${r.id}: K-4 holds both v2 and v1`,
      evidence: { chief_placement: { reason: `repair of ${r.id}, interrupted between its add and its remove`, ts: '2026-10-21T10:00:00.000Z' } }, from: 'console' });
    await rmRun(ctx(), doorJudge);
    expect(checked.fv.get('K-4')).toEqual(['v1']);
    expect(checked.refusals).toEqual([]);
    mirror([{ key: 'K-4', fixVersions: ['v1'] }]);
    expect(state(ctx()).unfinished_rulings).toEqual([]);
    expect((await rmRun(ctx(), doorJudge)).join('\n')).not.toContain('K-4');
  });

  it('the repair route of an operator ruling holding both ends: the printed --remove --by line passes the check and rm-run replays once (P1, T5)', async () => {
    const { r, cited } = await ruled('K-6', 'v1', 'v2', { operator: true, crashOnRemove: true });
    const out = (await rmRun(ctx(), noJudge)).join('\n');
    const printed = `jira fix-version K-6 --remove v1 --by ${cited?.id}`;
    expect(out).toContain(`PENDING ${r.id}`);
    expect(out).toContain(printed);
    expect(out).not.toMatch(/--remove v2/);
    await checked.setFixVersion('K-6', 'remove', 'v1', { by: cited?.id as string });
    mirror([{ key: 'K-6', fixVersions: ['v2'] }]);
    const replay = (await rmRun(ctx(), noJudge)).filter((l) => l.includes(r.id));
    expect(replay.filter((l) => l.startsWith('RULING '))).toHaveLength(1);
    expect(checked.fv.get('K-6')).toEqual(['v2']);
    expect(state(ctx()).unfinished_rulings).toEqual([]);
    expect(checked.posted).toBe(1);
  });

  it('a newer operator record placing the key elsewhere voids a door ruling and prints only its add line (X1)', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    checked.fv.set('K-4', []);
    mirror([{ key: 'K-4', fixVersions: [] }]);
    const newer = decide('2026-10-21T10:00:05.000Z', 'K-4', 'add', null, 'v3');
    const out = (await rmRun(ctx(), noJudge)).join('\n');
    expect(out).toContain(`VOID ${r.id}`);
    expect(out).toContain(`jira fix-version K-4 --add v3 --by ${newer.id}`);
    expect(out).not.toMatch(/--remove/);
    await checked.setFixVersion('K-4', 'add', 'v3', { by: newer.id });
    mirror([{ key: 'K-4', fixVersions: ['v3'] }]);
    expect(checked.fv.get('K-4')).toEqual(['v3']);
    expect(state(ctx()).unfinished_rulings).toEqual([]);
    expect((await rmRun(ctx(), noJudge)).join('\n')).not.toContain('K-4');
  });

  it('a newer operator remove prints its --remove --by line only while the key holds that version alone, and the line passes rule (2) (X1, X2)', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    checked.fv.set('K-4', ['v3']);
    mirror([{ key: 'K-4', fixVersions: ['v3'] }]);
    const newer = decide('2026-10-21T10:00:05.000Z', 'K-4', 'remove', 'v3', null);
    const out = (await rmRun(ctx(), async () => [])).join('\n');
    const line = `jira fix-version K-4 --remove v3 --by ${newer.id}`;
    expect(out).toContain(`VOID ${r.id}`);
    expect(out).toContain(line);
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, status: 'blocked', owner: 'chief', next: line }]);
    await checked.setFixVersion('K-4', 'remove', 'v3', { by: newer.id });
    mirror([{ key: 'K-4', fixVersions: [] }]);
    expect(checked.refusals).toEqual([]);
    expect(state(ctx()).unfinished_rulings).toEqual([]);
  });

  it('a voided ruling\'s line leaves the list once a later operator decision on the key replaces it', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    await rmRun(ctx(), noJudge);
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'void', status: 'blocked' }]);
    decide('2026-10-21T10:00:30.000Z', 'K-4', 'move', 'v2', 'v3');
    expect(state(ctx()).unfinished_rulings).toEqual([]);
  });

  it('a removal-only line stays listed while the mirror does not show the key', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    checked.fv.set('K-4', ['v3']);
    mirror([{ key: 'K-4', fixVersions: ['v3'] }]);
    decide('2026-10-21T10:00:05.000Z', 'K-4', 'remove', 'v3', null);
    await rmRun(ctx(), async () => []);
    rmSync(join(root, 'mirror', 'K-4.md'));
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'void', status: 'blocked' }]);
  });

  it('a newer operator remove while the key holds another declared version prints no line and stays blocked for the chief (X2)', async () => {
    const { r } = await ruled('K-4', 'v2', 'v1', { crashOnRemove: true });
    checked.fv.set('K-4', ['v1', 'v2', 'v3']);
    mirror([{ key: 'K-4', fixVersions: ['v1', 'v2', 'v3'] }]);
    decide('2026-10-21T10:00:05.000Z', 'K-4', 'remove', 'v3', null);
    const out = (await rmRun(ctx(), async () => [])).join('\n');
    expect(out).toContain(`PENDING ${r.id}`);
    expect(out).not.toMatch(/--remove|--add/);
    expect(state(ctx()).unfinished_rulings).toMatchObject([{ ruling: r.id, phase: 'intent', status: 'blocked', owner: 'chief' }]);
    expect(checked.fv.get('K-4')).toEqual(['v1', 'v2', 'v3']);
  });

  describe('releaseForProject on fixture roots (T4)', () => {
    const env = () => leaveEnv();
    const releaseJson = () => join(root, 'release', 'R1', 'release.json');

    it('names the verified declaration of the project, with its versions', () => {
      expect(releaseForProject(env(), 'K')).toEqual([{ release: 'R1', project: 'K', current: 'v1', versions: ['v1', 'v2', 'v3'] }]);
      expect(releaseForProject(env(), 'SALUS')).toEqual([]);
    });

    it('a release.json whose mac does not verify reads unreadable', () => {
      const d = JSON.parse(readFileSync(releaseJson(), 'utf8')) as Record<string, unknown>;
      writeFileSync(releaseJson(), JSON.stringify({ ...d, current: 'v2' }));
      expect(releaseForProject(env(), 'K')).toBe('unreadable');
    });

    it('a release.json that is not JSON reads unreadable for every project', () => {
      writeFileSync(releaseJson(), 'not json');
      expect(releaseForProject(env(), 'K')).toBe('unreadable');
      expect(releaseForProject(env(), 'SALUS')).toBe('unreadable');
    });

    it('two declarations naming the project are both returned', () => {
      declare({ ...ctx(), release: 'R2', dir: join(root, 'release', 'R2'), keyPath: join(root, 'keys', 'R2.key') },
        { project: 'K', versions: ['v4'], decision: '107', verbatim: 'R2 = v4', mode: 'observe' });
      expect((releaseForProject(env(), 'K') as Array<{ release: string }>).map((d) => d.release)).toEqual(['R1', 'R2']);
    });

    it('a missing root reads as no declaration', () => {
      expect(releaseForProject({ ...env(), HIMMEL_RELEASE_STATE_DIR: join(root, 'absent') }, 'K')).toEqual([]);
    });
  });
});
