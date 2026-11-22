import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, copyFileSync, cpSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, truncateSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ack, apply, bucketCheck, operatorWords, poolCurrent, claim, coreBypass, declare, decisionWords, fold, freeze, leaseAcquire, reopen, leaseRelease, operatorDecision, operatorFence, recordRequestDecision, request, requestWithWords, rule, state, takeover, withdraw,
  JudgeReplyError, LIVE_LOOKUP_MS, coreSnapshot, pull, readMirror, readMirrorFilesUnverified, readOperatorRecords, rmRun, rmRunSummary, pinnedSha, signSpec, specCheck, specReview, standing,
  type Ctx, type JiraPort, type Judge, type JudgeInput,
} from './engine.js';
import { judgeOperatorRows } from './judge-input.js';
import { execFileSync, spawnSync } from 'node:child_process';
import { Command } from 'commander';
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
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const execFileSync = ((...a: Parameters<typeof m.execFileSync>) => {
    const args = a[1] as string[] | undefined;
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

function fakeProc(marker: Record<string, string> = {}): { procRoot: string; hostNsPath: string } {
  const procRoot = mkdtempSync(join(tmpdir(), 'engine-proc-'));
  for (const [pid, ppid, uid, env] of [[300, 200, 1000, {}], [200, 100, 1000, marker], [100, 1, 1000, {}], [1, 0, 0, null]] as const) {
    mkdirSync(join(procRoot, String(pid)));
    writeFileSync(join(procRoot, String(pid), 'status'), `Name:\tp\nPPid:\t${ppid}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nNSpid:\t${pid}\n`);
    if (env) writeFileSync(join(procRoot, String(pid), 'environ'), Object.entries({ PATH: '/usr/bin', ...env }).map(([k, v]) => `${k}=${v}\0`).join(''));
  }
  mkdirSync(join(procRoot, '300', 'ns'));
  symlinkSync('pid:[4026531836]', join(procRoot, '300', 'ns', 'pid'));
  symlinkSync('user:[4026531837]', join(procRoot, '300', 'ns', 'user'));
  symlinkSync('300', join(procRoot, 'self'));
  const hostNsPath = join(procRoot, 'host-ns-ref');
  writeFileSync(hostNsPath, 'pid:[4026531836] user:[4026531837]\n');
  return { procRoot, hostNsPath };
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
        if (op === 'add') throw new Error('crash before the destination add');
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

    it('suggests removing the other membership when an interrupted move holds both versions', async () => {
      const { r } = await interrupted();
      jira.fv.set('K-2', ['v1', 'v2']);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1', 'v2'] }]);
      const unfinished = state(ctx()).unfinished_rulings[0];
      expect(unfinished).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
      expect(unfinished.next).toContain('jira fix-version K-2 --remove v1');
      expect(unfinished.next).toContain('jira fix-version K-2 --remove v2');
      expect(unfinished.next).not.toMatch(/--add v[12]/);
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

    it('an operator record newer than the ruling that takes the key out of the destination stops the new-epoch replay: nothing is written and the record is named', async () => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], 'remove', 'v2', null);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(lines.join('\n')).toMatch(new RegExp(`PENDING ${r.id}: .*${newer.id}`));
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      expect(jira.posted).toBe(0);
      const mismatches = () => readChain<EventRow>(join(ctx().dir, 'events.jsonl'), loadKey(ctx().keyPath)).verified.filter((e) => e.kind === 'ruled' && e.ruling === r.id && e.readback === 'mismatch');
      expect(mismatches()).toHaveLength(1);
      for (let i = 0; i < 3; i += 1) expect(await rmRun(withJournal(ctx()), noJudge)).toEqual(expect.arrayContaining([expect.stringContaining(`PENDING ${r.id}`)]));
      expect(mismatches()).toHaveLength(1);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
    });

    it('state reads that replay as blocked to the chief with the newer record named, before a run refuses it and after', async () => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], 'remove', 'v2', null);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const unfinished = () => state(withJournal(ctx())).unfinished_rulings;
      expect(unfinished()).toMatchObject([{ ruling: r.id, key: 'K-2', phase: 'intent', status: 'blocked', owner: 'chief', observed: 'K-2 is in no version (mirror); the move wants v1 -> v2' }]);
      expect(unfinished()[0].next).toContain(newer.id);
      expect(unfinished()[0].next).toContain('jira fix-version K-2 --add v1');
      expect(unfinished()[0].next).toContain('jira release rm-run R1');
      await rmRun(withJournal(ctx()), noJudge);
      expect(unfinished()).toMatchObject([{ ruling: r.id, status: 'blocked', owner: 'chief' }]);
      expect(unfinished()[0].next).toContain(newer.id);
    });

    it.each([
      ['puts it in a third version', 'add', null, 'v3'],
      ['moves it out of the destination into a third version', 'move', 'v2', 'v3'],
      ['keeps it in the source', 'keep', 'v1', 'v1'],
      ['takes it out of the source', 'remove', 'v1', null],
    ] as Array<[string, string, string | null, string | null]>)('an operator record newer than the ruling that %s also stops the replay and writes nothing', async (_name, op, from, to) => {
      const { r } = await interrupted({ operator: true });
      const newer = decide('2026-10-21T10:00:05.000Z', ['K-2'], op, from, to);
      jira.entries.set('K-2', '5001');
      journal(rmWrite());
      const writes = jira.writes;
      const lines = await rmRun(withJournal(ctx()), noJudge);
      expect(jira.writes).toBe(writes);
      expect(jira.fv.get('K-2')).toEqual([]);
      expect(lines.join('\n')).toMatch(new RegExp(`PENDING ${r.id}: .*${newer.id}`));
      expect(rows().filter((x) => x.key === 'K-2')).toEqual([]);
      expect(jira.posted).toBe(0);
      expect(state(withJournal(ctx())).unfinished_rulings[0]).toMatchObject({ ruling: r.id, status: 'blocked', owner: 'chief' });
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

  it('rm-run hands the judge only the operator rows its batch can use', async () => {
    declared();
    ask('K-3');
    await rmRun(ctx(), admitAll);
    const wide = operatorDecision(ctx(), { decision: '900', keys: ['K-900'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x'.repeat(160_000) });
    for (let n = 0; n < 30; n++) operatorDecision(ctx(), { decision: String(901 + n), keys: [`K-${901 + n}`], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
    ask('K-2');
    const lines = (f: string) => readFileSync(join(ctx().dir, f), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    const receipted = (lines('rulings.jsonl') as RulingRow[]).filter((r) => r.phase === 'receipted');
    expect(receipted.length).toBeGreaterThan(0);
    let seen: JudgeInput | undefined;
    await rmRun(ctx(), async (input) => { seen = input; return admitAll(input); });
    const all = lines('operator.jsonl') as OperatorRow[];
    const got = seen!.operator.map((o) => o.id);
    expect(got).not.toContain(wide.id);
    expect(got).toEqual(judgeOperatorRows('R1', all, seen!.requests, seen!.issues, receipted).map((o) => o.id));
    expect(got.length).toBeGreaterThan(30);
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

  it('readMirror refuses a mirror with no cursor or a complete:false one, and readMirrorFilesUnverified still reads the files', () => {
    const file = '---\nkey: "K-9"\ntype: "Task"\nstatus: "To Do"\npriority: "Medium"\nfixVersions: []\nresolution: null\n---\n';
    const bare = join(root, 'mirror-nocursor');
    mkdirSync(bare, { recursive: true });
    writeFileSync(join(bare, 'K-9.md'), file);
    expect(readMirror(bare).issues).toBeNull();
    expect(readMirrorFilesUnverified(bare).issues?.has('K-9')).toBe(true);
    expect(readMirrorFilesUnverified(bare).sync).toBeNull();
    const part = join(root, 'mirror-incomplete');
    mkdirSync(part, { recursive: true });
    writeFileSync(join(part, 'K-9.md'), file);
    writeFileSync(join(part, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T15:00:55.697Z', complete: false }));
    expect(readMirror(part)).toEqual({ issues: null, sync: null });
    expect(readMirrorFilesUnverified(part).issues?.has('K-9')).toBe(true);
    expect(readMirrorFilesUnverified(part)).toMatchObject({ sync: '2026-10-23T15:00:55.697Z', complete: false });
    expect(readMirror(join(root, 'mirror-absent')).issues).toBeNull();
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

describe('a delivered ticket in a later version follows its merge (decision 929)', () => {
  const declared = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  const id = 'O-R1-delivered-follows-merge';
  const rulingRows = () => readChain<RulingRow>(join(ctx().dir, 'rulings.jsonl'), loadKey(ctx().keyPath)).verified;
  const operatorRows = () => readChain<OperatorRow>(join(ctx().dir, 'operator.jsonl'), loadKey(ctx().keyPath)).verified;
  const evidence = { merged_pr: 'https://github.com/o/r/pull/5', pr_number: 5 };
  const wired = (pr = 5): Ctx => ({ ...ctx(), deliveredPr: () => pr });
  // K-1 is Done and still sits in v2 while v1 is the current version.
  const scene = (snap: Partial<Parameters<typeof mirror>[0][number]> = {}, extra: Parameters<typeof mirror>[0] = []) => {
    const fixVersions = snap.fixVersions ?? ['v2'];
    mirror([{ key: 'K-1', fixVersions, status: 'Done', category: 'Done', resolution: 'Done', sector: 'Ship loop', ...snap }, ...extra]);
    jira.fv.set('K-1', fixVersions);
  };
  const ask = (ev: Record<string, unknown> = evidence, from_v: string | null = 'v2') =>
    request(ctx(), { verb: 'INTAKE', key: 'K-1', from_v, to_v: 'v1', why: 'worked ticket held in a later version', evidence: ev, from: 'console' });
  const judged: string[] = [];
  const holdAll: Judge = async (input) => {
    judged.push(...input.requests.map((q) => q.key));
    return input.requests.map((q) => ({ req: q.req, outcome: 'HOLD' as const, reason: 'no standing delivery' }));
  };
  const noJudge: Judge = async () => { throw new Error('the judge must not be called for a delivered ticket'); };
  const dropStanding = () => {
    const c = ctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.filter((r) => r.id !== id).map(({ prev: _p, mac: _m, ...r }) => r);
    rmSync(path);
    for (const r of kept) appendChain(path, k, r);
  };
  beforeEach(() => { judged.length = 0; });

  it('a declare writes the standing record with decision 929 and the operator\'s words', () => {
    declared();
    expect(operatorRows().find((r) => r.id === id)).toMatchObject({ kind: 'delivered-follows-merge', decision: '929', verbatim: expect.stringContaining('merge') });
  });

  it('standing records it once on a release declared before it existed, and refuses a second', () => {
    declared();
    dropStanding();
    expect(operatorRows().some((r) => r.id === id)).toBe(false);
    expect(standing(ctx(), { kind: 'delivered-follows-merge', decision: '929', verbatim: 'x' })).toMatchObject({ id, kind: 'delivered-follows-merge', decision: '929' });
    expect(() => standing(ctx(), { kind: 'delivered-follows-merge', decision: '929', verbatim: 'again' })).toThrow(/already recorded/);
  });

  it('the RM admits a Done key in a later version with merge evidence at once, with no model call, and Jira moves it', async () => {
    declared();
    scene();
    ask();
    const lines = await rmRun(wired(), noJudge);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-1 move v2→v1 ADMIT current sector=Ship loop — delivered-follows-merge: .*decision 929/));
    expect(jira.fv.get('K-1')).toEqual(['v1']);
    expect(rulingRows().at(-1)?.authority).toMatchObject({ kind: 'operator', ref: id, delivered: expect.stringContaining('5') });
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null });
  });

  it('the merged PR the caller looks up counts as evidence when the request carries none', async () => {
    declared();
    scene();
    ask({});
    const lines = await rmRun({ ...ctx(), deliveredPr: (key) => (key === 'K-1' ? 7 : undefined) }, noJudge);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-1 move v2→v1 ADMIT /));
    expect(rulingRows().at(-1)?.authority).toMatchObject({ ref: id, delivered: expect.stringContaining('7') });
  });

  it('control: a ctx with no merged-PR lookup admits nothing mechanically, whatever evidence the request carries', async () => {
    declared();
    scene();
    ask({ merged_pr: 'https://github.com/o/r/pull/5', pr_number: 5, pr: 5, duplicate_pr: 5 });
    await rmRun(ctx(), holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
    leaseAcquire(ctx(rmEnv), { expectEpoch: 1, doc: DOC, session: 'rm-2' });
    claim(ctx(rmEnv));
    expect(() => rule(ctx(rmEnv), {
      req: 'Q-R1-0001', outcome: 'ADMIT', op: { kind: 'move', from_v: 'v2', to_v: 'v1' }, sector: 'Ship loop', ground: 'g', reason: 'r', supersedes: [],
      authority: { kind: 'operator', ref: id, delivered: 'PR #5' },
    })).toThrow(/no verifiable merge evidence/);
  });

  it('a duplicate is delivered when a merged PR names its original, found through the lookup', async () => {
    declared();
    scene({ status: 'Duplicate', resolution: 'Duplicate' });
    ask({ duplicate_of: 'K-5' });
    const lines = await rmRun({ ...ctx(), deliveredPr: (key) => (key === 'K-5' ? 12 : undefined) }, noJudge);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-0001 Q-R1-0001 INTAKE K-1 move v2→v1 ADMIT /));
    expect(rulingRows().at(-1)?.authority).toMatchObject({ delivered: 'PR #12' });
  });

  it('control: under the production wiring a duplicate with an unmerged PR number is not admitted', async () => {
    declared();
    scene({ status: 'Duplicate', resolution: 'Duplicate' });
    ask({ duplicate_pr: 9, duplicate_of: 'K-5' });
    await rmRun({ ...ctx(), deliveredPr: () => undefined }, holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
  });

  it('control: a judge decision citing the record with a made-up delivered string is refused when no merged PR names the key', () => {
    declared();
    scene();
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    const q = ask({});
    claim(ctx(rmEnv));
    const cite = (c: Ctx) => rule(c, {
      req: q.req, outcome: 'ADMIT', op: { kind: 'move', from_v: 'v2', to_v: 'v1' }, sector: 'Ship loop', ground: 'g', reason: 'r', supersedes: [],
      authority: { kind: 'operator', ref: id, delivered: 'PR #999' },
    });
    expect(() => cite({ ...ctx(rmEnv), deliveredPr: () => undefined })).toThrow(/no verifiable merge evidence/);
    expect(() => cite(ctx(rmEnv))).toThrow(/no verifiable merge evidence/);
    expect(cite({ ...ctx(rmEnv), deliveredPr: () => 999 }).authority).toMatchObject({ delivered: 'PR #999' });
  });

  it('control: with no merge evidence nothing is admitted mechanically; the judge is asked', async () => {
    declared();
    scene();
    ask({});
    expect(await rmRun({ ...ctx(), deliveredPr: () => undefined }, holdAll)).toEqual([expect.stringMatching(/^HELD Q-R1-0001: /)]);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
    expect(jira.fv.get('K-1')).toEqual(['v2']);
  });

  it('control: with a lookup wired, a PR the request names is not enough when no merged PR names the key', async () => {
    declared();
    scene();
    ask();
    await rmRun({ ...ctx(), deliveredPr: () => undefined }, holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
  });

  it('control: a judge cannot cite the record for a key that is not closed', () => {
    declared();
    scene({ status: 'In Progress', category: 'In Progress', resolution: undefined });
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    const q = ask();
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { op: { kind: 'move', from_v: 'v2', to_v: 'v1' }, authority: { kind: 'operator', ref: id, delivered: 'PR #5' } })).toThrow(/not closed, not delivered/);
  });

  it('control: a Won\'t Do key with a merged PR is not admitted mechanically', async () => {
    declared();
    scene({ status: "Won't Do", resolution: "Won't Do" });
    ask();
    await rmRun(wired(), holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
  });

  it('control: a key already in the current version is not admitted mechanically', async () => {
    declared();
    scene({ fixVersions: ['v1'] });
    ask(evidence, null);
    await rmRun(wired(), holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
  });

  it('control: a key in a released version (not one of the release\'s) is not admitted mechanically', async () => {
    declared();
    scene({ fixVersions: ['v0'] });
    ask(evidence, 'v0');
    await rmRun(wired(), holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
    expect(jira.fv.get('K-1')).toEqual(['v0']);
  });

  it('control: a release without the standing record sends the request to the judge', async () => {
    declared();
    dropStanding();
    scene();
    ask();
    await rmRun(wired(), holdAll);
    expect(judged).toEqual(['K-1']);
    expect(rulingRows()).toEqual([]);
  });

  it('a judge cannot cite the record without the evidence it names, or for a version other than the current one', () => {
    declared();
    scene();
    leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
    const q = ask();
    claim(ctx(rmEnv));
    expect(() => admit(q.req, { op: { kind: 'move', from_v: 'v2', to_v: 'v1' }, authority: { kind: 'operator', ref: id } })).toThrow(/does not cover K-1/);
    expect(() => admit(q.req, { op: { kind: 'move', from_v: 'v1', to_v: 'v2' }, authority: { kind: 'operator', ref: id, delivered: 'PR #5' } })).toThrow(/does not cover K-1/);
  });

  it('a newer operator record that keeps the key where it is wins (CONFLICT)', async () => {
    declared();
    scene();
    const keep = operatorDecision({ ...ctx(), now: () => new Date('2099-01-01T00:00:00.000Z') }, { decision: '390', keys: ['K-1'], op: 'keep', from_v: 'v2', to_v: 'v2', verbatim: 'K-1 stays in v2' });
    ask();
    expect(await rmRun(wired(), noJudge)).toEqual([expect.stringMatching(new RegExp(`^REFUSED Q-R1-0001: .*CONFLICT K-1: ${keep.id} \\(newer\\)`))]);
    expect(jira.fv.get('K-1')).toEqual(['v2']);
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

  describe('explicit source-root normal signing', () => {
    let primary: string;
    let linked: string;
    const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd,
      '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
      '-c', 'core.hooksPath=/dev/null', ...args], { encoding: 'utf8' }).trim();
    beforeEach(() => {
      const common = git(dirname(fileURLToPath(import.meta.url)), 'rev-parse', '--path-format=absolute', '--git-common-dir');
      primary = join(root, 'primary');
      linked = join(root, 'linked');
      mkdirSync(primary);
      git(primary, 'init', '-q');
      git(primary, 'commit', '-q', '--allow-empty', '-m', 'fixture');
      const scripts = 'marketplace/plugins/himmel-ops/scripts';
      mkdirSync(join(primary, scripts), { recursive: true });
      for (const name of ['minerva-spec-gate.sh', 'minerva-trace-lint.sh']) {
        copyFileSync(join(dirname(common), scripts, name), join(primary, scripts, name));
      }
      git(primary, 'worktree', 'add', '-q', '--detach', linked);
      mkdirSync(join(linked, 'branch-only'));
      writeFileSync(join(linked, 'branch-only', 'source.ts'), 'export const source = true;\n');
      git(linked, 'add', '.');
      git(linked, 'commit', '-q', '-m', 'branch-only source');
      sourceFixture.primary = primary;
      declared();
      for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
      writeFileSync(join(root, 'verbatim.txt'), 'fixture approval');
    });
    afterEach(() => { sourceFixture.primary = null; afterMinerva.fn = null; signingLock.fn = null; });

    async function normalSign(sourceRoot?: string, citation = 'branch-only/source.ts') {
      const { spec: p, plan } = bucketSpec(citation);
      await cli('operator', 'spec', 'R1', '--keys', 'K-1', '--spec', p, '--plan', plan,
        '--verdict', verdict(p, 'spec', 'SPEC CLEAN'), '--verdict', verdict(p, 'plan', 'PLAN CLEAN'),
        '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'),
        ...(sourceRoot === undefined ? [] : ['--source-root', sourceRoot]));
      return readOperatorRecords('spec', specEnv())[0];
    }

    async function normalCappedSign(f: CappedFixture, sourceRoot: string) {
      await cli('operator', 'spec', 'R1', '--keys', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
        '--verdict', f.verdicts[0], '--verdict', f.verdicts[1], '--source-root', sourceRoot,
        '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      return readOperatorRecords('spec', specEnv())[0];
    }

    it('combines capped carry and source provenance through normal signing and spec-check', async () => {
      const f = cappedFixture(undefined, false, 3, 'branch-only/source.ts');
      const frozen = fixtureHashes(f.specsRoot);
      const row = await normalCappedSign(f, linked);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD'),
        residuals: 2, capped_carry: { mode: 'capped-carry', key: 'HIMMEL-10205', carried: [
          expect.objectContaining({ kind: 'spec', finding_id: 'F1' }),
          expect.objectContaining({ kind: 'plan', finding_id: 'F1' }),
        ] } });
      expect(fixtureHashes(f.specsRoot)).toEqual(frozen);
      const out = vi.spyOn(console, 'log').mockImplementation(() => {});
      try {
        await cli('spec-check', 'HIMMEL-10205');
        expect(out).toHaveBeenCalledWith(`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`);
      } finally { out.mockRestore(); }
      writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      expect(specCheck(specEnv(), ['HIMMEL-10205'], null).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    });

    it('refuses capped signing when the verified source root lacks the branch citation', async () => {
      const f = cappedFixture(undefined, false, 3, 'branch-only/source.ts');
      await expect(normalCappedSign(f, primary)).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('rechecks capped proof before append with a verified source root', async () => {
      const f = cappedFixture(undefined, false, 3, 'branch-only/source.ts');
      signingLock.fn = () => writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      await expect(normalCappedSign(f, linked)).rejects.toThrow(/capped evidence changed/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('signs branch-only citations in a live same-repo linked root with canonical root/head provenance', async () => {
      const alias = join(root, 'alias');
      symlinkSync(linked, alias);
      // Untrusted worktree validators cannot replace the unchanged primary validators.
      const scripts = join(linked, 'marketplace/plugins/himmel-ops/scripts');
      mkdirSync(scripts, { recursive: true });
      writeFileSync(join(scripts, 'minerva-spec-gate.sh'), 'exit 99\n');
      writeFileSync(join(scripts, 'minerva-trace-lint.sh'), 'exit 99\n');
      const row = await normalSign(alias);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD') });
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
      // Provenance is historical; later HEAD changes do not confer or revoke spec authority.
      git(linked, 'commit', '-q', '--allow-empty', '-m', 'later source');
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
    });

    it('keeps default primary citation behavior and old records without provenance', async () => {
      await expect(normalSign()).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalSign(undefined, 'marketplace/plugins/himmel-ops/scripts/minerva-trace-lint.sh');
      expect(row).not.toHaveProperty('source_root');
      expect(row).not.toHaveProperty('source_head');
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
    });

    it('accepts explicit primary and preserves the state repository as alternate citation root', async () => {
      const stateRepo = join(root, 'bucket');
      mkdirSync(stateRepo);
      git(stateRepo, 'init', '-q');
      mkdirSync(join(stateRepo, 'notes'));
      writeFileSync(join(stateRepo, 'notes', 'state.md'), 'state');
      const row = await normalSign(primary, 'notes/state.md');
      expect(row).toMatchObject({ source_root: realpathSync(primary), source_head: git(primary, 'rev-parse', 'HEAD') });
    });

    it.each(['missing', 'foreign', 'unregistered', 'subdir'])('refuses %s roots before appending any spec record', async (kind) => {
      let candidate = join(root, kind);
      if (kind === 'foreign') {
        mkdirSync(candidate);
        git(candidate, 'init', '-q');
        git(candidate, 'commit', '-q', '--allow-empty', '-m', 'foreign');
      } else if (kind === 'unregistered') {
        mkdirSync(candidate);
        copyFileSync(join(linked, '.git'), join(candidate, '.git'));
      } else if (kind === 'subdir') candidate = join(linked, 'branch-only');
      await expect(normalSign(candidate, 'marketplace/plugins/himmel-ops/scripts/minerva-trace-lint.sh')).rejects.toThrow(/source.root/i);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['HEAD', 'symlink', 'directory', 'registration'])('refuses a %s swap during validation before appending', async (kind) => {
      const alias = join(root, 'alias');
      symlinkSync(linked, alias);
      afterMinerva.fn = () => {
        if (kind === 'HEAD') git(linked, 'commit', '-q', '--allow-empty', '-m', 'changed');
        if (kind === 'symlink') { unlinkSync(alias); symlinkSync(primary, alias); }
        if (kind === 'directory') {
          renameSync(linked, `${linked}-old`);
          mkdirSync(linked);
          copyFileSync(join(`${linked}-old`, '.git'), join(linked, '.git'));
        }
        if (kind === 'registration') rmSync(git(linked, 'rev-parse', '--absolute-git-dir'), { recursive: true });
      };
      await expect(normalSign(alias)).rejects.toThrow(/source.root/i);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['spec', 'plan', 'verdict'])('keeps the %s hash-race refusal with an explicit root', async (kind) => {
      afterMinerva.fn = () => {
        const p = join(root, 'bucket/designs/K-1-bucket-2026-11-02.md');
        const target = kind === 'spec' ? p : kind === 'plan'
          ? join(root, 'bucket/plans/K-1-bucket-plan-2026-11-02.md') : `${p}.critic-spec-r1.md`;
        writeFileSync(target, `${readFileSync(target, 'utf8')}\nchanged\n`);
      };
      await expect(normalSign(linked)).rejects.toThrow(/changed while it was checked/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['source', 'document'])('rechecks %s after acquiring the append lock', async (kind) => {
      signingLock.fn = () => {
        if (kind === 'source') git(linked, 'commit', '-q', '--allow-empty', '-m', 'changed before append');
        else writeFileSync(join(root, 'bucket/designs/K-1-bucket-2026-11-02.md'), 'changed before append');
      };
      await expect(normalSign(linked)).rejects.toThrow(/changed while it was checked/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('keeps normal operator fencing with an explicit root', async () => {
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
      await expect(normalSign(linked)).rejects.toThrow(/chief-spawned worker/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    async function normalGroupSign(f: V2Fixture, sourceRoot?: string) {
      await cli('operator', 'spec', 'R1', '--keys', f.keys!.join(','), '--spec', f.spec, '--plan', f.plan,
        '--verdict', f.verdicts[0], '--verdict', f.verdicts[1], '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'),
        ...(sourceRoot === undefined ? [] : ['--source-root', sourceRoot]));
      return readOperatorRecords('spec', specEnv())[0];
    }

    it('capped carry v2 group signing takes a citation only from the root it names: a candidate-only citation signs with --source-root and not by default, and the candidate scripts never run (E23)', async () => {
      spawnReset();
      const scripts = join(linked, 'marketplace/plugins/himmel-ops/scripts');
      mkdirSync(scripts, { recursive: true });
      writeFileSync(join(scripts, 'minerva-spec-gate.sh'), 'exit 99\n');
      writeFileSync(join(scripts, 'minerva-trace-lint.sh'), 'exit 99\n');
      const f = v2Build({ builder: 'group', citation: 'branch-only/source.ts' });
      const before = fixtureHashes(f.specsRoot);
      await expect(normalGroupSign(f)).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalGroupSign(f, linked);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD'), capped_carry: { schema: 2, mode: 'capped-carry-ledger' } });
      expect(check(f.keys!)).toEqual(f.keys!.map(k => `SPEC ok ${k} ${f.spec} ${row.id}`));
      expect(fixtureHashes(f.specsRoot)).toEqual(before);
      expect(cappedSpawn.attempts.map(a => a[2])).toEqual(['--keys', '--keys']);
      spawnReset();
    });

    it('capped carry v2 group signing: a primary-only citation signs by default and is refused through --source-root (E23)', async () => {
      spawnReset();
      mkdirSync(join(primary, 'primary-only'));
      writeFileSync(join(primary, 'primary-only', 'source.ts'), 'export const only = true;\n');
      const f = v2Build({ builder: 'group', citation: 'primary-only/source.ts' });
      await expect(normalGroupSign(f, linked)).rejects.toThrow(/cites primary-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalGroupSign(f);
      expect(row).not.toHaveProperty('source_root');
      expect(row.capped_carry).toMatchObject({ schema: 2, mode: 'capped-carry-ledger' });
      expect(check(f.keys!)).toEqual(f.keys!.map(k => `SPEC ok ${k} ${f.spec} ${row.id}`));
      spawnReset();
    });

    it('capped carry v2 docs: each chief doc holds exactly one signing-hash-check marker and the same fenced command after it; the command is silent on equal lint scripts and stops on a changed candidate copy (X1)', () => {
      const blocks = CHIEF_DOCS.map(rel => {
        const text = chiefDoc(rel);
        expect(occurrences(text, SIGNING_MARKER), `${rel}: exactly one marker`).toBe(1);
        const block = markedBlock(text);
        expect(block, `${rel}: a fenced block follows the marker`).not.toBeNull();
        return block as string;
      });
      expect(blocks[1], 'the two blocks are byte-equal').toBe(blocks[0]);
      const scripts = 'marketplace/plugins/himmel-ops/scripts'; const names = ['minerva-spec-gate.sh', 'minerva-trace-lint.sh'];
      mkdirSync(join(linked, scripts), { recursive: true });
      for (const name of names) copyFileSync(join(primary, scripts, name), join(linked, scripts, name));
      const run = (block: string, sentinel: string) => spawnSync('bash', ['-c', `${block}\n: > "$SENTINEL"`], {
        cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, CAND: linked, SENTINEL: sentinel } });
      blocks.forEach((block, i) => {
        const equal = join(root, `sentinel-equal-${i}`); const changed = join(root, `sentinel-changed-${i}`);
        const ok = run(block, equal);
        expect([ok.status, ok.stdout, ok.stderr], 'equal copies: silent, exit 0').toEqual([0, '', '']);
        expect(existsSync(equal), 'equal copies: the sentinel step ran').toBe(true);
        writeFileSync(join(linked, scripts, names[1]), 'exit 99\n');
        const stop = run(block, changed);
        expect(stop.status, 'a changed candidate copy: non-zero exit').not.toBe(0);
        expect(stop.stderr, 'a changed candidate copy: STOP on stderr').toContain('STOP');
        expect(existsSync(changed), 'a changed candidate copy: the abort is proved, no sentinel').toBe(false);
        copyFileSync(join(primary, scripts, names[1]), join(linked, scripts, names[1]));
      });
    });

    it('capped carry v2 docs: both chief docs hold every finite token, each marker or sentence exactly once, and no other display-only or per-family filter text (X2)', () => {
      const tokens = ['--keys', '--source-root', 'tickets:', 'spec-review', 'jira release spec-check', 'jira roadmap get', 'next-dispatchable.sh', 'gen-briefs.py', 'brief-lint.sh',
        'roadmap.ts', 'tracker.py', 'board.ts', 'full pause', 'snapshot folder', 'manifest entry'];
      for (const rel of CHIEF_DOCS) {
        const text = chiefDoc(rel);
        for (const token of tokens) expect(occurrences(text, token), `${rel}: ${token}`).toBeGreaterThanOrEqual(1);
        expect(/--key\b/.test(text), `${rel}: the flag --key by itself`).toBe(true);
        for (const once of [SIGNING_MARKER, 'none is accepted as display-only', 'not a per-family filter']) expect(occurrences(text, once), `${rel}: ${once}`).toBe(1);
        expect(occurrences(text, 'display-only'), `${rel}: no other display-only`).toBe(1);
        expect(occurrences(text, 'per-family filter'), `${rel}: no other per-family filter`).toBe(1);
      }
    });

    it('capped carry v2 docs: a changed spec-gate copy on the candidate stops the marked command as well (X1, the spec-gate copy)', () => {
      const scripts = 'marketplace/plugins/himmel-ops/scripts'; const names = ['minerva-spec-gate.sh', 'minerva-trace-lint.sh'];
      mkdirSync(join(linked, scripts), { recursive: true });
      for (const name of names) copyFileSync(join(primary, scripts, name), join(linked, scripts, name));
      CHIEF_DOCS.forEach((rel, i) => {
        const block = markedBlock(chiefDoc(rel)) as string; const sentinel = join(root, `sentinel-spec-gate-${i}`);
        writeFileSync(join(linked, scripts, names[0]), 'exit 99\n');
        const stop = spawnSync('bash', ['-c', `${block}\n: > "$SENTINEL"`], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, CAND: linked, SENTINEL: sentinel } });
        expect(stop.status, `${rel}: a changed spec-gate copy: non-zero exit`).not.toBe(0);
        expect(stop.stderr, `${rel}: a changed spec-gate copy: STOP on stderr`).toContain('STOP');
        expect(existsSync(sentinel), `${rel}: a changed spec-gate copy: no sentinel`).toBe(false);
        copyFileSync(join(primary, scripts, names[0]), join(linked, scripts, names[0]));
      });
    });

    it('capped carry v2 docs: the section of each chief doc exists once and the two sections are byte-equal (a driver-ruled row beyond the frozen matrix)', () => {
      const sections = CHIEF_DOCS.map(rel => {
        const text = chiefDoc(rel);
        expect(text.split('\n').filter(l => l === SECTION_HEADING), `${rel}: one section heading`).toHaveLength(1);
        return docSection(text) as string;
      });
      expect(sections[1], 'the two sections are byte-equal').toBe(sections[0]);
    });

    it('capped carry v2 docs: each chief doc section opens with the imperative not-yet sentence, in its first paragraph (a driver-ruled row beyond the frozen matrix)', () => {
      const notYet = '**Do not use this route for any real signing until the operator has approved live issuance (item 6); until then every command below is for fixtures only.**';
      for (const rel of CHIEF_DOCS) {
        const lines = (docSection(chiefDoc(rel)) as string).split('\n');
        const first = lines.slice(2, lines.findIndex((l, i) => i > 2 && l === '')).join(' ');
        expect(first.startsWith(notYet), `${rel}: the first paragraph of the section opens with the sentence`).toBe(true);
      }
    });
  });

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

  const sha = (p: string) => createHash('sha256').update(readFileSync(p)).digest('hex');
  const both = { kinds: ['spec', 'spec-review'] as OperatorRow['kind'][] };

  function rspec(dir = join(root, 'rs'), head = '- Ticket: K-2', title = '# K-2: a reviewed design'): { spec: string; plan: string } {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'est.json'), JSON.stringify({ median_seq: 1, sigma: 0.1, dod: { passed: true } }));
    const p = join(dir, 'K-2-review.md');
    writeFileSync(p, [
      title, '', head, '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture records.', '',
      '## Invariants', '', 'none', '',
    ].join('\n'));
    const plan = join(dir, 'K-2-review-plan.md');
    writeFileSync(plan, 'plan\n\n- Task 1: build it.\n');
    return { spec: p, plan };
  }
  function critic(specPath: string, last: string, o: { kind?: 'spec' | 'plan'; round?: number; key?: string | null; reviewed?: string[]; body?: string[] } = {}): string {
    const kind = o.kind ?? 'spec';
    const p = `${specPath}.critic-${kind}-r${o.round ?? 1}.md`;
    const reviewed = o.reviewed ?? (kind === 'spec' ? [`Reviewed: spec ${sha(specPath)}`] : []);
    writeFileSync(p, [...(o.key === null ? [] : [`Key: ${o.key ?? 'K-2'}`]), ...reviewed, '', 'the critic\'s return', ...(o.body ?? []), '', last, ''].join('\n'));
    return p;
  }
  const review = (c: Ctx, f: { spec: string; plan?: string }, verdicts: string[], extra: Partial<Parameters<typeof specReview>[1]> = {}) => specReview(c, {
    keys: ['K-2'], spec: f.spec, plan: f.plan, verdicts, ...extra,
  });
  const candidateRoot = fileURLToPath(new URL('../../../../', import.meta.url));
  const expectedVerifier = join(candidateRoot, 'scripts/telegram/chief-route.ts');
  const bunLookup = spawnSync('which', ['bun'], { encoding: 'utf8' });
  const realBun = bunLookup.status === 0 ? bunLookup.stdout.trim() : '';
  type CappedFixture = { spec: string; plan: string; verdicts: string[]; ledgerPath: string; specsRoot: string };
  function cappedFixture(cleanKind?: 'spec' | 'plan', invalidLint = false, rounds = 3, citation?: string): CappedFixture {
    if (!realBun) throw new Error('capped fixture requires Bun on PATH; install the pinned .bun-version');
    const scratchRoot = mkdtempSync(join(root, 'capped-'));
    const specText = '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nKey: HIMMEL-10205\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n'
      + (citation ? `\n## Fact ownership\n\n| Fact | Existing surfaces | Owner after | Non-owners |\n|---|---|---|---|\n| source | \`${citation}\` | source | n/a |\n` : '');
    const request = { scratchRoot, key: 'HIMMEL-10205', specText: invalidLint ? specText.replace('Estimate record: estimate.json', '') : specText,
      planText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 plan\n\n- Ticket: HIMMEL-10205\n\n- Task 1: build the fixture.\n',
      returns: [1, 2, 3].slice(0, rounds).flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
        text: kind === cleanKind ? `${kind.toUpperCase()} CLEAN\n` : `- **F1** (${kind === 'spec' ? 'minor' : 'medium'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
        reads: ['spec', 'plan', { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' },
          { path: 'specs/designs/page.html', text: '<p>fixture</p>\n' }],
      }))),
    };
    const f = JSON.parse(execFileSync(realBun, [join(candidateRoot, 'scripts/telegram/testlib-capped-fold.ts')], {
      input: JSON.stringify(request), encoding: 'utf8', timeout: 15000,
    })) as CappedFixture;
    f.verdicts = f.verdicts.slice(-2);
    return f;
  }
  const cappedSign = (api: 'spec' | 'spec-review', f: CappedFixture, extra: Record<string, unknown> = {}) => {
    const o = { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts, ...extra };
    return api === 'spec' ? signSpec(sctx(), { ...o, decision: '387', verbatim: 'approve' }) : specReview(sctx(), o);
  };
  const fixtureHashes = (dir: string): Record<string, string> => Object.fromEntries(readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const p = join(dir, e.name);
    return e.isDirectory() ? Object.entries(fixtureHashes(p)) : [[p, sha(p)]];
  }));

  const cappedCheck = (api: 'spec' | 'spec-review', keys = ['HIMMEL-10205'], issues?: Map<string, IssueSnap>) =>
    specCheck(specEnv(), keys, null, { kinds: [api], ...(issues ? { issues } : {}) });

  function externalCappedFixture(location: string): CappedFixture {
    if (!['spec-return', 'plan-return', 'plan-document'].includes(location)) return cappedFixture();
    const f = cappedFixture(undefined, false, 2);
    const runner = join(dirname(f.specsRoot), 'external-fixture.ts');
    writeFileSync(runner, `
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { ledgerVerify, sealRound } from ${JSON.stringify(expectedVerifier)};
const f = ${JSON.stringify(f)}, location = ${JSON.stringify(location)};
const external = join(dirname(f.specsRoot), 'external'); mkdirSync(external);
const oldPlan = f.plan;
if (location === 'plan-document') { f.plan = join(external, basename(f.plan)); copyFileSync(oldPlan, f.plan); }
for (const [i, kind] of ['spec', 'plan'].entries()) {
  const previous = f.verdicts[i];
  const next = join(location === kind+'-return' ? external : dirname(previous), basename(previous).replace('r2.md', 'r3.md'));
  const text = readFileSync(previous, 'utf8').replace('Fixture: '+kind+' round 2', 'Fixture: '+kind+' round 3')
    .replace(/^((?:READ(?:-SHA256)?|CONTENT-SHA256) [0-9a-f]{64}) (.+)$/gm, (_line, prefix, rel) => {
      const path = resolve(dirname(previous), rel); return prefix+' '+(path === oldPlan ? f.plan : path);
    });
  writeFileSync(next, text);
  for (const m of text.matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(next, m[1]);
  await ledgerVerify(next, { spec: f.spec }); f.verdicts[i] = next;
}
console.log(JSON.stringify(f));
`);
    return JSON.parse(execFileSync(realBun, [runner], { encoding: 'utf8', timeout: 15000 })) as CappedFixture;
  }

  function returnDirectory(f: CappedFixture, location: string): string {
    if (location === 'spec-return') return dirname(f.verdicts[0]);
    if (location === 'plan-return') return dirname(f.verdicts[1]);
    if (location === 'plan-document') return dirname(f.plan);
    return join(f.specsRoot, location === 'key' ? 'HIMMEL-10205' : location);
  }

  function addUnaccountedReturn(f: CappedFixture, directory: string, round: number): void {
    mkdirSync(directory, { recursive: true });
    cpSync(f.verdicts[0], join(directory, basename(f.verdicts[0]).replace('r3.md', `r${round}a.md`)));
  }

  function unchangedProofFiles(proof: pinned.CappedFoldProof): void {
    for (const pin of proof.pins) if (pin.role !== 'decision-selection') expect(sha(pin.path)).toBe(pin.sha256);
  }

  it.each(['spec', 'spec-review'] as const)('capped carry return selection irrelevant files remain fresh: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(existsSync(join(f.specsRoot, 'design'))).toBe(false);
    expect(cappedCheck(api).ok).toBe(true);
    writeFileSync(join(f.specsRoot, 'design'), 'optional non-directory lookup');
    expect(cappedCheck(api).ok).toBe(true);
    unlinkSync(join(f.specsRoot, 'design'));
    for (const directory of ['design', 'spec', 'plan', 'HIMMEL-10205']) {
      const path = join(f.specsRoot, directory); mkdirSync(path);
      for (const name of ['HIMMEL-10205-other.md.critic-spec-r2.md', 'HIMMEL-10205-other.md.critic-r1-plan.md', 'HIMMEL-10205-other.md.critic-r2a.md',
        'unrelated.txt', ...(directory === 'HIMMEL-10205' ? [] : ['HIMMEL-99999-other.md.critic-plan-r99.md'])]) cpSync(f.verdicts[0], join(path, name));
    }
    unchangedProofFiles(row.capped_carry!);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const proof = JSON.parse(execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 })) as pinned.CappedFoldProof;
    expect(proof.returns.map(r => r.round)).toEqual([3, 3]);
  });

  const directoryStale = (api: 'spec' | 'spec-review', fault: string) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const directory = join(f.specsRoot, 'design');
    if (fault === 'alias') {
      const elsewhere = join(dirname(f.specsRoot), 'alias-target'); mkdirSync(elsewhere); symlinkSync(elsewhere, directory);
    }
    if (fault === 'overflow') { mkdirSync(directory); for (let i = 0; i < 4097; i++) writeFileSync(join(directory, `irrelevant-${i}`), ''); }
    if (fault === 'unreadable') { mkdirSync(directory); chmodSync(directory, 0); }
    try {
      unchangedProofFiles(row.capped_carry!);
      expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    } finally { if (fault === 'unreadable') chmodSync(directory, 0o700); }
  };
  const directoryFaults = (faults: string[]) => (['spec', 'spec-review'] as const).flatMap(api => faults.map(fault => [api, fault] as const));
  it.each(directoryFaults(['alias', 'overflow']))('capped carry return selection directory stale: %s %s', directoryStale);
  it.skipIf(RUNS_AS_ROOT).each(directoryFaults(['unreadable']))('capped carry return selection directory stale: %s %s', directoryStale);

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec-return', 'plan-return', 'plan-document', 'design', 'designs', 'spec', 'plan', 'plans', 'key'].flatMap(location =>
      [3, 4].map(round => [api, location, round] as const))))('capped carry return selection later stale: %s %s r%s', (api, location, round) => {
    declared();
    const f = externalCappedFixture(location);
    const row = cappedSign(api, f);
    expect(readOperatorRecords(api, specEnv()).map(r => r.id)).toEqual([row.id]);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    addUnaccountedReturn(f, returnDirectory(f, location), round);
    unchangedProofFiles(row.capped_carry!);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [3, 4].map(round => [api, round] as const)))('capped carry return selection preappend: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    const before = fixtureHashes(f.specsRoot);
    const actual = ledger.withLock;
    let changed = false;
    cappedCalls.length = 0;
    const spy = vi.spyOn(ledger, 'withLock').mockImplementation((dir, fn, ...rest) => actual(dir, () => {
      if (dir === sctx().dir && !changed) {
        expect(cappedCalls).toHaveLength(1);
        expect(existsSync(join(sctx().dir, '.lock')) && existsSync(join(root, 'release', '.lock'))).toBe(true);
        changed = true;
        addUnaccountedReturn(f, join(f.specsRoot, 'spec'), round);
        for (const [path, hash] of Object.entries(before)) expect(sha(path)).toBe(hash);
      }
      return fn();
    }, ...rest));
    try {
      expect(() => cappedSign(api, f)).toThrow(/unaccounted latest return/);
      expect(changed).toBe(true);
      noCappedRows();
    } finally { spy.mockRestore(); }
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [3, 4].map(round => [api, round] as const)))('capped carry return selection persisted stale: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    let changed = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((path, key, fields) => {
      const persisted = actual(path, key, fields);
      if (!changed && path === join(sctx().dir, 'operator.jsonl') && (fields as OperatorRow).kind === api) {
        changed = true;
        addUnaccountedReturn(f, join(f.specsRoot, 'HIMMEL-10205'), round);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(changed).toBe(true);
    unchangedProofFiles(rows[0].capped_carry!);
    expect(error).toBe(`persisted-but-stale ${rows[0].id}: capped-fold: ambiguous or unaccounted latest return: ${join(f.specsRoot, 'HIMMEL-10205', basename(f.verdicts[0]).replace('r3.md', `r${round}a.md`))}; inspect this record before retrying`);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${rows[0].id}`]);
  });

  function resetFixture(f: CappedFixture, reseal = true): CappedFixture & { decision: string } {
    const runner = join(dirname(f.specsRoot), 'reset-fixture.ts');
    writeFileSync(runner, `
import { mkdirSync, readFileSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { roundReset, sealRound } from ${JSON.stringify(expectedVerifier)};
const f = ${JSON.stringify(f)};
const decision = join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt');
mkdirSync(dirname(decision));
const quote = 'start this ticket over from scratch';
writeFileSync(decision, 'HIMMEL-10205 '+quote+'\\n');
const seconds = Math.floor(Date.now()/1000)+2.140625;
utimesSync(decision, seconds, seconds);
process.env.HIMMEL_CONSOLE='1';
await roundReset(f.specsRoot, 'HIMMEL-10205', { decision:'990', quote });
for (const name of ${reseal} ? readdirSync(dirname(f.spec)).filter(n => /critic-(spec|plan)-r[123]\\.md$/.test(n)).sort() : []) {
  const p=join(dirname(f.spec), name);
  writeFileSync(p, readFileSync(p,'utf8').replace('Fixture:', 'New epoch Fixture:'));
  for (const m of readFileSync(p,'utf8').matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(p, join(dirname(p),m[1]));
}
`);
    execFileSync(realBun, [runner], { timeout: 15000, stdio: ['ignore', 'pipe', 'pipe'] });
    return { ...f, decision: join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt') };
  }
  const decisionFixture = () => resetFixture(cappedFixture());
  const keepMtime = (path: string, mtime: number) => {
    utimesSync(path, mtime / 1000, mtime / 1000);
    expect(statSync(path).mtimeMs, 'the bytes fault keeps the pinned mtime').toBe(mtime);
  };

  function evidencePath(f: CappedFixture, role: string): string {
    const paths: Record<string, string> = { spec: f.spec, plan: f.plan, page: join(dirname(f.spec), 'page.html'),
      estimate: join(dirname(f.spec), 'estimate.json'), return: f.verdicts[0], ledger: f.ledgerPath,
      manifest: join(dirname(f.ledgerPath), 'manifest.json'), snapshot: join(dirname(f.ledgerPath), 'HIMMEL-10205', sha(f.spec)),
      decision: join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt') };
    return paths[role];
  }

  it('capped fixture requires bun', () => {
    const bin = join(root, 'ordinary-tools');
    mkdirSync(bin);
    for (const name of ['which', 'git', 'bash', 'dirname', 'cat', 'sed', 'awk', 'rg', 'head', 'tr', 'grep', 'sort', 'tail', 'wc', 'date']) {
      const found = spawnSync('which', [name], { encoding: 'utf8' });
      if (found.status === 0) symlinkSync(found.stdout.trim(), join(bin, name));
    }
    symlinkSync(process.execPath, join(bin, 'node'));
    const result = spawnSync(process.execPath, [join(candidateRoot, 'scripts/jira/node_modules/vitest/vitest.mjs'), 'run',
      'src/release/engine.test.ts', '-t', '^signed minerva specs > capped carry signs frozen findings:'], {
      cwd: join(candidateRoot, 'scripts/jira'), env: { ...process.env, PATH: bin }, timeout: 15000, encoding: 'utf8',
    });
    expect(result.signal).toBeNull();
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain('capped fixture requires Bun on PATH');
    expect(`${result.stdout}${result.stderr}`).toMatch(/2 failed/);
  }, 20000);

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'snapshot', 'return', 'ledger', 'manifest'].map(role => [api, role] as const)))('capped carry extra pins stale: %s %s', (api, role) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const path = evidencePath(f, role);
    writeFileSync(path, `${readFileSync(path, 'utf8')}\n`);
    const out = cappedCheck(api);
    expect(out.lines, role).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    const ordinary: Record<string, string> = { spec: 'spec', plan: 'plan', return: 'verdict' };
    expect(out.answer.get('HIMMEL-10205'), role).toEqual({ missing: role in ordinary
      ? `${ordinary[role]} ${path} changed since ${row.id}`
      : `capped proof stale since ${row.id}: capped evidence changed or unreadable: ${path}` });
  });

  it.each(['spec', 'spec-review'] as const)('capped carry later ledger append stale: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    const paths = [f.spec, f.plan, ...f.verdicts];
    const hashes = paths.map(sha);
    const ledgerBefore = readFileSync(f.ledgerPath, 'utf8');
    expect(cappedCheck(api).ok).toBe(true);
    resetFixture(f, false);
    expect(readFileSync(f.ledgerPath, 'utf8').startsWith(ledgerBefore)).toBe(true);
    expect(JSON.parse(readFileSync(f.ledgerPath, 'utf8').trim().split('\n').at(-1)!)).toMatchObject({ row: 'reset', epoch: 1 });
    expect(paths.map(sha)).toEqual(hashes);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['bytes', 'selection', 'mtime', 'file-alias', 'directory-alias'].map(fault => [api, fault] as const)))('capped carry decision selection/mtime/alias stale: %s %s', (api, fault) => {
    declared();
    const f = decisionFixture();
    const row = cappedSign(api, f);
    const proof = row.capped_carry!;
    expect(proof.epoch).toBe(1);
    const mtime = statSync(f.decision).mtimeMs;
    expect(mtime % 1).not.toBe(0);
    expect(proof.pins.find(p => p.role === 'decision')).toMatchObject({ path: f.decision, mtime_ms: mtime });
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const bytes = readFileSync(f.decision);
    if (fault === 'bytes') { writeFileSync(f.decision, `${bytes.toString()}changed\n`); keepMtime(f.decision, mtime); }
    if (fault === 'selection') writeFileSync(join(dirname(f.decision), 'verbatim-decision-990-second.txt'), bytes);
    if (fault === 'mtime') { utimesSync(f.decision, mtime / 1000 + 10, mtime / 1000 + 10); expect(readFileSync(f.decision)).toEqual(bytes); }
    if (fault === 'file-alias') { const moved = join(dirname(f.specsRoot), 'same-decision'); renameSync(f.decision, moved); symlinkSync(moved, f.decision); }
    if (fault === 'directory-alias') { const moved = join(dirname(f.specsRoot), 'same-decisions'); renameSync(dirname(f.decision), moved); symlinkSync(moved, dirname(f.decision)); }
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry recording checkout removed: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const elsewhere = join(root, 'retained-copy');
    cpSync(f.specsRoot, elsewhere, { recursive: true });
    expect(sha(join(elsewhere, 'designs', basename(f.spec)))).toBe(sha(f.spec));
    rmSync(dirname(f.specsRoot), { recursive: true });
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['null', 'unknown-field', 'schema', 'reader-version', 'missing-pin', 'key', 'proof-key', 'spec', 'plan', 'returns', 'count'].map(fault => [api, fault] as const)))('capped carry persisted malformed or unbound proof stale: %s %s', (api, fault) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const proof = JSON.parse(JSON.stringify(row.capped_carry));
    const copy = { ...row, id: 'O-R1-9000', supersedes: row.id, capped_carry: proof };
    if (fault === 'null') copy.capped_carry = null;
    if (fault === 'unknown-field') proof.unknown = true;
    if (fault === 'schema') proof.schema = 2;
    if (fault === 'reader-version') proof.reader_version = 2;
    if (fault === 'missing-pin') proof.pins = proof.pins.filter((p: { role: string }) => p.role !== 'ledger');
    if (fault === 'key') copy.keys = ['HIMMEL-10205', 'HIMMEL-8888'];
    if (fault === 'proof-key') { proof.key = 'HIMMEL-8888'; for (const c of proof.carried) c.key = proof.key; }
    if (fault === 'spec') { copy.spec_path = join(root, 'same-spec.md'); cpSync(f.spec, copy.spec_path); }
    if (fault === 'plan') { copy.plan_path = join(root, 'same-plan.md'); cpSync(f.plan, copy.plan_path); }
    if (fault === 'returns') { const path = join(root, 'same-return.md'); cpSync(f.verdicts[0], path); copy.verdicts = [{ path, sha256: sha(path) }, row.verdicts![1]]; }
    if (fault === 'count') copy.residuals = 0;
    appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy);
    expect(readOperatorRecords(api, specEnv()).at(-1)?.id).toBe(copy.id);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${copy.spec_path} ${copy.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry parent proof remains fresh for an inheriting child: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    const issues = new Map([['HIMMEL-8888', { type: 'Sub-task', parent: 'HIMMEL-10205' } as IssueSnap]]);
    expect(cappedCheck(api, ['HIMMEL-8888'], issues).lines).toEqual([`SPEC ok HIMMEL-8888 ${f.spec} ${row.id}`]);
    writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
    expect(cappedCheck(api, ['HIMMEL-8888'], issues).lines).toEqual([`SPEC-STALE HIMMEL-8888 ${f.spec} ${row.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry signs frozen findings: %s', api => {
    declared();
    const f = cappedFixture();
    const before = fixtureHashes(f.specsRoot);
    const row = cappedSign(api, f);
    expect(row.residuals).toBe(2);
    expect(row.capped_carry).toMatchObject({ schema: 1, mode: 'capped-carry', key: 'HIMMEL-10205' });
    expect(row.capped_carry?.carried.map(c => [c.kind, c.finding_id, c.status])).toEqual([
      ['spec', 'F1', 'open-carried'], ['plan', 'F1', 'open-carried'],
    ]);
    expect(readOperatorRecords(api, specEnv()).find(r => r.id === row.id)?.capped_carry).toEqual(row.capped_carry);
    expect(fixtureHashes(f.specsRoot)).toEqual(before);
  });

  it.each([['spec', 'plan'], ['spec-review', 'plan'], ['spec', 'spec'], ['spec-review', 'spec']] as const)('capped carry preserves scoped IDs and CLEAN companion: %s %s', (api, cleanKind) => {
    declared();
    const f = cappedFixture(cleanKind);
    const before = fixtureHashes(f.specsRoot);
    const row = cappedSign(api, f);
    expect(row.residuals).toBe(1);
    expect(row.capped_carry?.returns.map(r => [r.kind, r.residuals])).toEqual(cleanKind === 'plan' ? [['spec', 1], ['plan', 0]] : [['spec', 0], ['plan', 1]]);
    expect(row.capped_carry?.carried.map(c => [c.kind, c.finding_id])).toEqual([[cleanKind === 'plan' ? 'spec' : 'plan', 'F1']]);
    expect(fixtureHashes(f.specsRoot)).toEqual(before);
  });

  function rejectingBun(mode: string, run: (log: string) => void): void {
    const bin = mkdtempSync(join(root, 'bun-bin-'));
    const log = join(bin, 'real-success.jsonl');
    const path = join(bin, 'bun');
    writeFileSync(path, `#!${process.execPath}
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const {createHash} = require('node:crypto');
const args = process.argv.slice(2), mode = ${JSON.stringify(mode)};
if(args[0] !== ${JSON.stringify(expectedVerifier)} || args[1] !== 'capped-fold') throw Error('unexpected verifier argv');
if(mode === 'missing-verifier') args[0] += '.missing';
if(mode === 'unknown-verb') args[1] = 'unknown-capped-fold';
let output;
try { output = execFileSync(${JSON.stringify(realBun)}, args, {encoding:'utf8', stdio:['ignore','pipe','pipe']}); }
catch(e) { process.stderr.write(String(e.stderr || e.message)); process.exit(e.status || 1); }
const p = JSON.parse(output);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({args, digest:createHash('sha256').update(output).digest('hex')})+'\\n');
const h = 'f'.repeat(64);
function changeHash(pin) { const old=pin.sha256; pin.sha256=h; for(const x of p.pins) if(x.path===pin.path && x.sha256===old) x.sha256=h; }
if(mode==='key') { p.key='HIMMEL-99999'; for(const c of p.carried)c.key=p.key; }
if(mode==='spec-hash') changeHash(p.spec);
if(mode==='plan-hash') changeHash(p.plan);
if(mode==='return-full') changeHash(p.returns[1]);
if(mode==='return-normalized') { p.returns[1].return_sha=h; for(const c of p.carried)if(c.kind==='plan')c.return_sha=h; }
if(mode==='count') { p.returns[1].residuals++; p.carried.push({...p.carried.find(c=>c.kind==='plan'), finding_id:'F2'}); }
if(mode==='reader-version')p.reader_version=2;
if(mode==='schema')p.schema=2;
if(mode==='malformed') { process.stdout.write('not JSON'); process.exit(0); }
if(mode==='nonzero') { process.stderr.write('rejecting verifier exit'); process.exit(7); }
if(mode==='returned-drift') { const path=p.returns[1].path; fs.writeFileSync(path,fs.readFileSync(path,'utf8').replace(/Reviewed: spec [0-9a-f]{64}/,'Reviewed: spec '+h)); }
if(mode.startsWith('latest-return-')) {
  const path=p.returns[0].path; fs.copyFileSync(path,path.replace('r3.md','r'+mode.slice('latest-return-'.length)+'a.md'));
  for(const pin of p.pins) if(pin.role!=='decision-selection' && createHash('sha256').update(fs.readFileSync(pin.path)).digest('hex')!==pin.sha256) throw Error('original pin changed');
}
if(mode==='timeout') Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,32000);
process.stdout.write(JSON.stringify(p));
if(mode==='output')process.stdout.write(' '.repeat(4*1024*1024+1));
`);
    chmodSync(path, 0o755);
    const old = process.env.PATH;
    process.env.PATH = `${bin}:${old}`;
    try { run(log); } finally { process.env.PATH = old; rmSync(bin, { recursive: true, force: true }); }
  }

  function noCappedRows(): void {
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  }

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [3, 4].map(round => [api, round] as const)))('capped carry return selection initial consumption: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    rejectingBun(`latest-return-${round}`, log => {
      expect(() => cappedSign(api, f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*unaccounted latest return/);
      expect(readFileSync(log, 'utf8').trim().split('\n')).toHaveLength(1);
      noCappedRows();
    });
  });

  it.each(['key', 'spec-hash', 'plan-hash', 'return-full', 'return-normalized', 'count'])('capped carry rejects mismatched proof binding: %s', mode => {
    declared();
    const f = cappedFixture();
    rejectingBun(mode, log => {
      for (const api of ['spec', 'spec-review'] as const) {
        expect(() => cappedSign(api, f)).toThrow(/residual findings.*capped verifier unavailable\/refused: capped proof .*binding disagrees/);
        noCappedRows();
      }
      expect(readFileSync(log, 'utf8').trim().split('\n')).toHaveLength(2);
    });
  });

  it('capped carry rejects returned-byte drift', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('returned-drift', log => {
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped evidence changed/);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it.each(['reader-version', 'schema', 'malformed', 'nonzero', 'missing-verifier', 'unknown-verb'])('capped carry verifier refuses unavailable or incompatible evidence: %s', mode => {
    declared();
    const f = cappedFixture();
    rejectingBun(mode, log => {
      expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:/);
      if (!['missing-verifier', 'unknown-verb'].includes(mode)) expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it('capped carry refuses absent Bun', () => {
    declared();
    const f = cappedFixture();
    const old = process.env.PATH;
    process.env.PATH = join(root, 'absent-bun');
    try { expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOENT/); }
    finally { process.env.PATH = old; }
    noCappedRows();
  });

  it('capped carry bounds verifier output', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('output', log => {
      expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOBUFS/);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it('capped carry bounds verifier time', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('timeout', log => {
      const start = Date.now();
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ETIMEDOUT/);
      expect(Date.now() - start).toBeGreaterThanOrEqual(29000);
      expect(Date.now() - start).toBeLessThan(40000);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  }, 45000);

  it('capped carry Node Reviewed crosscheck', () => {
    declared();
    const f = cappedFixture();
    const actual = pinned.reviewedSpecHashes;
    let planAfterVerifier = false;
    cappedCalls.length = 0;
    const spy = vi.spyOn(pinned, 'reviewedSpecHashes').mockImplementation(text => {
      const hashes = actual(text);
      if (text.includes('Fixture: plan round 3')) {
        planAfterVerifier = cappedCalls.length > 0;
        return ['a'.repeat(64)];
      }
      return hashes;
    });
    try {
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped plan Reviewed binding disagrees/);
      expect(planAfterVerifier).toBe(true);
      noCappedRows();
    } finally { spy.mockRestore(); }
    expect(cappedSign('spec-review', f).capped_carry?.carried).toHaveLength(2);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry uses candidate verifier source: %s', api => {
    declared();
    const f = cappedFixture();
    cappedCalls.length = 0;
    const old = process.cwd();
    process.chdir(root);
    try { expect(cappedSign(api, f).capped_carry?.carried).toHaveLength(2); }
    finally { process.chdir(old); }
    expect(cappedCalls).toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry uses candidate verifier built-dist: %s', api => {
    declared();
    const f = cappedFixture();
    const preload = join(root, 'observe-child.mjs');
    const log = join(root, 'child-calls.jsonl');
    writeFileSync(preload, `import cp from 'node:child_process'; import {syncBuiltinESMExports} from 'node:module'; import {appendFileSync} from 'node:fs';
const actual=cp.execFileSync; cp.execFileSync=(...a)=>{if(a[1]?.[1]==='capped-fold')appendFileSync(${JSON.stringify(log)},JSON.stringify(a[1])+'\\n');return actual(...a);}; syncBuiltinESMExports();`);
    const engine = new URL('../../dist/release/engine.js', import.meta.url).href;
    const c = sctx();
    Object.assign(c, fakeProc());
    const input = { engine, api, ctx: { release: c.release, dir: c.dir, keyPath: c.keyPath, env: c.env, procRoot: c.procRoot, hostNsPath: c.hostNsPath },
      args: { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts, decision: '387', verbatim: 'approve' } };
    const script = `const i=JSON.parse(process.argv[1]); const m=await import(i.engine); const row=m[i.api==='spec'?'signSpec':'specReview']({...i.ctx,now:()=>new Date('2026-10-21T10:00:00.000Z'),jira:{},mirrorRoot:null},i.args); console.log(JSON.stringify({engine:i.engine,row}));`;
    const child = spawnSync(process.execPath, ['--import', preload, '--input-type=module', '-e', script, JSON.stringify(input)], { cwd: root, encoding: 'utf8', timeout: 15000 });
    expect(child.status, child.stderr).toBe(0);
    const result = JSON.parse(child.stdout);
    expect(result.row.capped_carry.carried).toHaveLength(2);
    expect(readFileSync(log, 'utf8').trim().split('\n'), 'one attempt, logged before it ran').toHaveLength(1);
    expect(JSON.parse(readFileSync(log, 'utf8').trim())).toEqual([expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]);
    const beforeRows = readFileSync(join(c.dir, 'operator.jsonl'), 'utf8');
    const beforeCalls = readFileSync(log, 'utf8');
    const wrongNs = fakeProc();
    writeFileSync(wrongNs.hostNsPath, 'pid:[999] user:[999]\n');
    for (const [ancestry, reason] of [
      [fakeProc({ HIMMEL_BRIDGE_SESSION: '1' }), /HIMMEL_BRIDGE_SESSION=1/],
      [wrongNs, /other namespaces/],
    ] as const) {
      const deniedInput = { ...input, ctx: { ...input.ctx, ...ancestry } };
      const denied = spawnSync(process.execPath, ['--import', preload, '--input-type=module', '-e', script, JSON.stringify(deniedInput)], { cwd: root, encoding: 'utf8', timeout: 15000 });
      expect(denied.status).toBe(1);
      expect(denied.stderr).toMatch(reason);
      expect(readFileSync(join(c.dir, 'operator.jsonl'), 'utf8')).toBe(beforeRows);
      expect(readFileSync(log, 'utf8')).toBe(beforeCalls);
    }
  });

  it('shared return hash preserves normalization compatibility', () => {
    const hash = (text: string) => createHash('sha256').update(text).digest('hex');
    expect(pinned.returnSha('line  \nCONTENT-SHA256 dead ignored\nnext\t\n\n')).toBe(hash('line\nnext\n'));
    expect(pinned.returnSha('\n\t\n')).toBe(hash(''));
    expect(pinned.returnSha(' CONTENT-SHA256 retained\r\n\n')).toBe(hash(' CONTENT-SHA256 retained\n'));
  });

  it.each(['spec', 'spec-review'] as const)('capped carry does not bypass gates: %s', api => {
    declared();
    const f = cappedFixture();
    expect(() => cappedSign(api, f, { plan: undefined })).toThrow(api === 'spec' ? /residual findings.*explicit distinct plan/ : /--plan names the plan/);
    expect(() => cappedSign(api, f, { plan: f.spec })).toThrow(api === 'spec' ? /residual findings.*explicit distinct plan/ : /--plan is the spec/);
    const alias = join(root, 'plan-alias.md');
    symlinkSync(f.spec, alias);
    expect(() => cappedSign(api, f, { plan: alias })).toThrow(api === 'spec' ? /residual findings.*capped verifier unavailable\/refused/ : /--plan is the spec/);
    expect(() => cappedSign(api, f, { keys: ['HIMMEL-10205', 'HIMMEL-10206'] })).toThrow(api === 'spec' ? /residual findings.*one key/ : /names HIMMEL-10205, not --keys/);
    expect(() => cappedSign(api, f, { verdicts: [f.verdicts[0]] })).toThrow(api === 'spec' ? /exactly two --verdict/ : /residual findings.*paired SPEC\/PLAN/);
    expect(() => cappedSign(api, f, { supersedes: 'O-R1-9999' })).toThrow(api === 'spec' ? /no verified spec record/ : /no live spec-review record/);
    noCappedRows();
    const gated = cappedFixture(undefined, true);
    cappedCalls.length = 0;
    expect(() => cappedSign(api, gated)).toThrow(/minerva-spec-gate.sh refused/);
    expect(cappedCalls).toHaveLength(1);
    noCappedRows();
    const o = { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts };
    const fenced = sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' });
    cappedCalls.length = 0;
    expect(() => api === 'spec' ? signSpec(fenced, { ...o, decision: '387', verbatim: 'approve' }) : specReview(fenced, o)).toThrow(/chief-spawned worker/);
    expect(cappedCalls).toEqual([]);
    noCappedRows();
  });

  it.each(['spec', 'spec-review'] as const)('capped carry requires normal declared authority: %s', api => {
    const f = cappedFixture();
    expect(() => cappedSign(api, f)).toThrow(/release R1 is UNKNOWN/);
    expect(existsSync(join(sctx().dir, 'operator.jsonl'))).toBe(false);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry does not bypass key or Reviewed bindings: %s', api => {
    declared();
    const f = cappedFixture();
    for (const path of f.verdicts) {
      const original = readFileSync(path, 'utf8');
      for (const changed of [original.replace(/^Reviewed:.*\n/m, ''), original.replace(/Reviewed: spec [0-9a-f]{64}/, `Reviewed: spec ${'a'.repeat(64)}`),
        original.replace('Key: HIMMEL-10205', 'Key: HIMMEL-10206')]) {
        writeFileSync(path, changed);
        expect(() => cappedSign(api, f)).toThrow(/Reviewed|review|latest|Key:|names|header/);
        noCappedRows();
      }
      writeFileSync(path, original);
    }
    expect(cappedSign(api, f).capped_carry?.carried).toHaveLength(2);
  });

  it('legacy inline and CLEAN success never requests capped fallback', () => {
    declared();
    cappedCalls.length = 0;
    cappedSpawn.attempts.length = 0;
    const clean = spec();
    expect(sign(sctx(), ['K-1'], clean).capped_carry).toBeUndefined();
    const inline = spec('K-3.md', join(root, 'inline'), ['# K-3: inline', '## Critic rounds', '- R1: fixed in the spec']);
    expect(sign(sctx(), ['K-3'], inline, { verdicts: [verdict(inline, 'spec', 'SPEC FINDINGS 1'), verdict(inline, 'plan', 'PLAN CLEAN')] }).capped_carry).toBeUndefined();
    const f = rspec();
    expect(review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]).capped_carry).toBeUndefined();
    const v = critic(f.spec, 'SPEC FINDINGS 1', { reviewed: [`Reviewed: spec ${'a'.repeat(64)}`] });
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: file ${basename(v)}\n  - R1: fixed in §1\n`);
    expect(review(sctx(), f, [v]).capped_carry).toBeUndefined();
    expect(cappedCalls).toEqual([]);
    expect(cappedSpawn.attempts, 'no capped-fold spawn was attempted, a failed one included').toEqual([]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'return', 'ledger', 'manifest', 'snapshot', 'decision', 'selection', 'mtime'].map(role => [api, role] as const)))('capped carry preappend drift: %s %s', (api, role) => {
    declared();
    const f = ['decision', 'selection', 'mtime'].includes(role) ? decisionFixture() : cappedFixture();
    const actual = ledger.withLock;
    let changedUnderLocks = 0;
    cappedCalls.length = 0;
    const spy = vi.spyOn(ledger, 'withLock').mockImplementation((dir, fn, ...rest) => {
      return actual(dir, () => {
        if (dir === sctx().dir && !changedUnderLocks) {
          expect(cappedCalls).toHaveLength(1);
          expect(existsSync(join(sctx().dir, '.lock')) && existsSync(join(root, 'release', '.lock'))).toBe(true);
          changedUnderLocks++;
          const path = evidencePath(f, ['selection', 'mtime'].includes(role) ? 'decision' : role);
          if (role === 'selection') writeFileSync(join(dirname(path), 'verbatim-decision-990-second.txt'), readFileSync(path));
          else if (role === 'mtime') { const seconds = statSync(path).mtimeMs / 1000 + 10; utimesSync(path, seconds, seconds); }
          else writeFileSync(path, `${readFileSync(path, 'utf8')}\n`);
        }
        return fn();
      }, ...rest);
    });
    try {
      const refusal = api === 'spec' && ['spec', 'plan', 'return'].includes(role)
        ? /the spec, plan or a verdict file changed while it was checked/
        : /capped evidence (changed|selection changed)/;
      expect(() => cappedSign(api, f)).toThrow(refusal);
      expect(changedUnderLocks).toBe(1);
      noCappedRows();
    } finally { spy.mockRestore(); }
  });

  it.each(['spec', 'spec-review'] as const)('capped carry persisted stale on postappend drift: %s', api => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    const authorityPath = join(sctx().dir, 'operator.jsonl');
    let changedAfterPersistence = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((path, key, fields) => {
      const persisted = actual(path, key, fields);
      if (!changedAfterPersistence && path === authorityPath && (fields as OperatorRow).kind === api) {
        changedAfterPersistence = true;
        writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(changedAfterPersistence).toBe(true);
    expect(error).toMatch(new RegExp(`persisted-but-stale ${rows[0].id}:.*inspect this record before retrying`));
  });

  it.each(['spec', 'spec-review'] as const)('capped carry reports exact persisted row when verified readback fails: %s', api => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    const path = join(sctx().dir, 'operator.jsonl');
    const saved = `${path}.saved`;
    let refusedReadback = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((target, key, fields) => {
      const persisted = actual(target, key, fields);
      if (!refusedReadback && target === path && (fields as OperatorRow).kind === api) {
        refusedReadback = true;
        renameSync(path, saved);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); if (existsSync(saved)) renameSync(saved, path); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(refusedReadback).toBe(true);
    expect(error).toBe(`persisted-but-stale ${rows[0].id}: signed row did not verify on readback; inspect this record before retrying`);
  });

  const CHILD = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'pinned-read-child.mjs');
  const child = (mode: 'check' | 'review', input: Record<string, unknown>) => {
    const r = spawnSync(process.execPath, [CHILD, JSON.stringify({ env: specEnv(), ...input }), mode], { timeout: 5000, encoding: 'utf8' });
    return { status: r.status, signal: r.signal, out: r.stdout ? JSON.parse(r.stdout) as Record<string, unknown> : null };
  };

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'return', 'ledger', 'manifest', 'snapshot', 'decision'].flatMap(role =>
      ['fifo', 'directory', 'oversized', 'missing', 'device'].map(fault => [api, role, fault] as const))))('capped carry stale unreadable pin: %s %s %s', (api, role, fault) => {
    declared();
    const f = role === 'decision' ? decisionFixture() : cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const path = evidencePath(f, role);
    unlinkSync(path);
    if (fault === 'fifo') execFileSync('mkfifo', [path]);
    if (fault === 'directory') mkdirSync(path);
    if (fault === 'oversized') { writeFileSync(path, ''); truncateSync(path, 16 * 1024 * 1024 + 1); }
    if (fault === 'device') symlinkSync('/dev/null', path);
    const out = child('check', { keys: ['HIMMEL-10205'], kinds: [api] });
    expect(out.signal).toBeNull();
    expect(out.status).toBe(0);
    expect(out.out?.lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });
  function signedPair(): { p: string; id: string; good: string; goodId: string } {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    const good = spec('K-3-good.md', join(root, 'specs3'));
    const g = sign(sctx(), ['K-3'], good);
    return { p, id: r.id, good, goodId: g.id };
  }

  it('spec-check never accepts a spec-review record', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    expect(r.kind).toBe('spec-review');
    expect(check(['K-2'])).toEqual(['NO-SPEC K-2']);
    expect(specCheck(specEnv(), ['K-2'], null).answer.get('K-2')).toEqual({ missing: 'no spec-review record for K-2' });
    const out = specCheck(specEnv(), ['K-2'], null, both);
    expect(out.lines).toEqual([`SPEC ok K-2 ${f.spec} ${r.id}`]);
    expect(out.answer.get('K-2')).toEqual({ ok: true });
  });

  it('spec-check --kinds reads spec-review records for the chief', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    const f = rspec();
    const out: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    const code = process.exitCode;
    const codes: Array<typeof code> = [];
    try {
      await cli('operator', 'spec-review', 'R1', '--keys', 'K-2', '--spec', f.spec, '--plan', f.plan, '--verdict', critic(f.spec, 'SPEC CLEAN'));
      await cli('spec-check', 'K-2');
      codes.push(process.exitCode);
      process.exitCode = code;
      await cli('spec-check', '--kinds', 'spec,spec-review', 'K-2');
      codes.push(process.exitCode);
    } finally {
      log.mockRestore();
      process.exitCode = code;
    }
    expect(out).toEqual([`O-R1-0002 spec-review ${f.spec} for K-2`, 'NO-SPEC K-2', `SPEC ok K-2 ${f.spec} O-R1-0002`]);
    expect(codes).toEqual([1, code]);
    const row = readOperatorRecords('spec-review', specEnv())[0];
    expect([row.spec_sha256, row.plan_sha256, ...(row.verdicts ?? []).map((v) => v.sha256)]).toHaveLength(3);
    const four = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN'), critic(f.spec, 'PLAN CLEAN', { kind: 'plan' })]);
    expect([four.spec_sha256, four.plan_sha256, ...(four.verdicts ?? []).map((v) => v.sha256)]).toHaveLength(4);
  });

  it('a FIFO at a pinned path names that key only and does not block', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-spec-r1.md`;
    unlinkSync(pinned);
    execFileSync('mkfifo', [pinned]);
    const r = child('check', { keys: ['K-1', 'K-3'] });
    expect(r.signal).toBeNull();
    expect(r.status).toBe(0);
    expect(r.out).toEqual({
      lines: [`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`],
      answer: { 'K-1': { missing: `${pinned} is unreadable (${id})` }, 'K-3': { ok: true } },
    });
  });

  it('a FIFO at a spec-review row\'s pinned path is unreadable too', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    const pinned = `${f.spec}.critic-spec-r1.md`;
    unlinkSync(pinned);
    execFileSync('mkfifo', [pinned]);
    const out = child('check', { keys: ['K-2'], kinds: ['spec', 'spec-review'] });
    expect(out.signal).toBeNull();
    expect(out.out).toEqual({ lines: [`SPEC-STALE K-2 ${f.spec} ${r.id}`], answer: { 'K-2': { missing: `${pinned} is unreadable (${r.id})` } } });
  });

  it('a device at a pinned path is unreadable', () => {
    const { p, id, good, goodId } = signedPair();
    unlinkSync(p);
    symlinkSync('/dev/zero', p);
    const r = child('check', { keys: ['K-1', 'K-3'] });
    expect(r.signal).toBeNull();
    expect(r.status).toBe(0);
    expect(r.out).toEqual({
      lines: [`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`],
      answer: { 'K-1': { missing: `${p} is unreadable (${id})` }, 'K-3': { ok: true } },
    });
  });

  it('a directory at a pinned path names that key only', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-plan-r1.md`;
    unlinkSync(pinned);
    mkdirSync(pinned);
    const out = specCheck(specEnv(), ['K-1', 'K-3'], null);
    expect(out.lines).toEqual([`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`]);
    expect(out.answer.get('K-1')).toEqual({ missing: `${pinned} is unreadable (${id})` });
  });

  it('a pinned file over 16 MiB is unreadable', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-spec-r1.md`;
    truncateSync(pinned, 17 * 1024 * 1024);
    const out = specCheck(specEnv(), ['K-1', 'K-3'], null);
    expect(out.lines).toEqual([`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`]);
    expect(out.answer.get('K-1')).toEqual({ missing: `${pinned} is unreadable (${id})` });
    expect(out.answer.get('K-3')).toEqual({ ok: true });
  });

  it.skipIf(process.platform !== 'linux')('a pinned file that yields more bytes than fstat reported is unreadable', () => {
    expect(pinnedSha('/proc/self/status')).toEqual({ unreadable: true });
  });

  it('the bounded reader refuses a device by its file type: /dev/null is canonical and empty, so neither the alias check nor a digest is the cause', () => {
    expect(realpathSync('/dev/null')).toBe('/dev/null');
    expect(pinned.pinnedRead('/dev/null')).toEqual({ unreadable: true });
  });

  it('a missing or changed pinned file names its path in the answer', () => {
    const { p, id } = signedPair();
    writeFileSync(p, `${readFileSync(p, 'utf8')}\nedited\n`);
    expect(specCheck(specEnv(), ['K-1'], null).answer.get('K-1')).toEqual({ missing: `spec ${p} changed since ${id}` });
    unlinkSync(p);
    expect(specCheck(specEnv(), ['K-1'], null).answer.get('K-1')).toEqual({ missing: `${p} is missing (${id})` });
  });

  it('a newer row of another kind never hides a spec-review row', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    coreBypass({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, { keys: ['K-2'], decision: '804', verbatim: 'bypass' });
    const records = readOperatorRecords(['spec-review', 'core-bypass'], specEnv());
    expect(records.map((x) => x.kind)).toEqual(['spec-review', 'core-bypass']);
    const out = specCheck(specEnv(), ['K-2'], null, { ...both, records, issues: null });
    expect(out.answer.get('K-2')).toEqual({ ok: true });
    expect(out.lines).toEqual([`SPEC ok K-2 ${f.spec} ${r.id}`]);
  });

  it('a stale spec-review row never hides a fresh signed spec', () => {
    declared();
    const p = spec();
    const signed = sign(sctx(), ['K-2'], p);
    const f = rspec();
    review({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, f, [critic(f.spec, 'SPEC CLEAN')]);
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\nedited\n`);
    const out = specCheck(specEnv(), ['K-2'], null, both);
    expect(out.answer.get('K-2')).toEqual({ ok: true });
    expect(out.lines).toEqual([`SPEC ok K-2 ${p} ${signed.id}`]);
  });

  it('spec-review refuses a missing or self plan, a wrong verdict set, a refused spec, a worker and a spec-row supersede', () => {
    declared();
    const f = rspec();
    const clean = () => critic(f.spec, 'SPEC CLEAN');
    expect(() => review(sctx(), { spec: f.spec }, [clean()])).toThrow(/release operator spec-review: --plan names the plan/);
    expect(() => review(sctx(), { spec: f.spec, plan: f.spec }, [clean()])).toThrow(/--plan is the spec/);
    expect(() => review(sctx(), f, [critic(f.spec, 'PLAN CLEAN', { kind: 'plan' })])).toThrow(/exactly one SPEC verdict/);
    expect(() => review(sctx(), f, [clean(), critic(f.spec, 'SPEC CLEAN', { round: 2 })])).toThrow(/exactly one SPEC verdict/);
    expect(() => review(sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' }), f, [clean()])).toThrow(/chief-spawned worker/);
    const signed = sign(sctx(), ['K-2'], spec());
    expect(() => review(sctx(), f, [clean()], { supersedes: signed.id })).toThrow(new RegExp(`${signed.id} is no live spec-review record`));
    writeFileSync(f.spec, readFileSync(f.spec, 'utf8').replace('Estimate record: est.json', ''));
    expect(() => review(sctx(), f, [clean()])).toThrow(/minerva-spec-gate/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review refuses a FIFO --spec as unreadable within the deadline', () => {
    declared();
    const f = rspec();
    const v = critic(f.spec, 'SPEC CLEAN');
    unlinkSync(f.spec);
    execFileSync('mkfifo', [f.spec]);
    const c = sctx();
    const r = child('review', {
      ctx: { release: c.release, dir: c.dir, keyPath: c.keyPath, now: '2026-10-21T10:00:00.000Z', ...fakeProc() },
      review: { keys: ['K-2'], spec: f.spec, plan: f.plan, verdicts: [v] },
    });
    expect(r.signal).toBeNull();
    expect(r.out).toEqual({ error: `release operator spec-review: spec ${f.spec} is unreadable` });
  });

  it('shared Reviewed extractor preserves legacy specReview', () => {
    declared();
    const f = rspec();
    const s = sha(f.spec);
    const other = 'a'.repeat(64);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [] })])).toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: spec ${s}`, `Reviewed: spec ${s}`] })]))
      .toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: design ${s}`] })])).toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: spec ${other}`] })]))
      .toThrow(new RegExp(`SPEC CLEAN reviewed ${other}, not the spec's bytes ${s}`));
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC FINDINGS 0', { reviewed: [`Reviewed: spec ${other}`] })]))
      .toThrow(new RegExp(`SPEC FINDINGS 0 reviewed ${other}, not the spec's bytes ${s}`));
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);

    const v = critic(f.spec, 'SPEC FINDINGS 1', { reviewed: [`Reviewed: spec ${other}`] });
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: one finding, file ${basename(v)}\n  - R1: fixed in §1\n`);
    const r = review(sctx(), f, [v]);
    expect(r.reviewed_sha256).toBe(other);
    expect(r.spec_sha256).toBe(sha(f.spec));
    expect(r.spec_sha256).not.toBe(other);
    expect(r.residuals).toBe(1);
  });

  it('spec-review refuses a Key: line that is missing, empty of keys, another key set or only in the body, and an unnamed spec', () => {
    declared();
    const f = rspec();
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: null })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'see the spec' })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'K-2, K-3' })])).toThrow(/names K-2, K-3, not --keys K-2/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: null, body: ['this reviews K-2'] })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN'), critic(f.spec, 'PLAN CLEAN', { kind: 'plan', key: null })]))
      .toThrow(/critic-plan-r1\.md needs exactly one 'Key: <keys>' line/);
    const unnamed = rspec(join(root, 'rs-unnamed'), '- Ticket: K-7');
    expect(() => review(sctx(), unnamed, [critic(unnamed.spec, 'SPEC CLEAN')])).toThrow(/the spec's header does not name K-2/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review refuses a key that is a prefix of the reviewed key, and a cross-ticket record', () => {
    declared();
    const h = rspec(join(root, 'rs-h'), '- Ticket: HIMMEL-9564', '# HIMMEL-9564: a reviewed design');
    expect(() => review(sctx(), h, [critic(h.spec, 'SPEC CLEAN', { key: 'HIMMEL-9564' })], { keys: ['HIMMEL-956'] }))
      .toThrow(/names HIMMEL-9564, not --keys HIMMEL-956/);
    const f = rspec();
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')], { keys: ['K-9'] })).toThrow(/names K-2, not --keys K-9/);
    writeFileSync(`${h.spec}.critic-spec-r1.md`, readFileSync(`${h.spec}.critic-spec-r1.md`, 'utf8').replace('Key: HIMMEL-9564', 'Key: HIMMEL-956'));
    expect(() => review(sctx(), h, [`${h.spec}.critic-spec-r1.md`], { keys: ['HIMMEL-956'] })).toThrow(/the spec's header does not name HIMMEL-956/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review reads the keys on a Key: line with trailing prose', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'K-2 (spec)' })]);
    expect(r.keys).toEqual(['K-2']);
  });

  it('spec-review refuses a FINDINGS fold whose own round block lacks its dispositions', () => {
    declared();
    const f = rspec();
    const v = critic(f.spec, 'SPEC FINDINGS 2');
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: two findings, file ${basename(v)}\n  - R1: fixed in §1\n`);
    expect(() => review(sctx(), f, [v])).toThrow(/2 residual findings and their round blocks hold 1 dispositioned/);
    const g = rspec(join(root, 'rs-r2'));
    const v1 = critic(g.spec, 'SPEC FINDINGS 5');
    writeFileSync(g.spec, `${readFileSync(g.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: five findings, file ${basename(v1)}\n`
      + [1, 2, 3, 4, 5].map((n) => `  - R${n}: fixed\n`).join('')
      + `- Round 2: three findings, file ${basename(`${g.spec}.critic-spec-r2.md`)}\n`);
    const v2 = critic(g.spec, 'SPEC FINDINGS 3', { round: 2 });
    expect(() => review(sctx(), g, [v2])).toThrow(/3 residual findings and their round blocks hold 0 dispositioned/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review pins the reviewed and the folded spec hash', () => {
    declared();
    const f = rspec();
    const reviewedSha = sha(f.spec);
    const v = critic(f.spec, 'SPEC FINDINGS 3');
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: three findings, file ${basename(v)}\n`
      + '  - R1: fixed in §1\n  - R2: ASSUMPTION A1\n  - R3: deferred → HIMMEL-9000\n');
    const r = review(sctx(), f, [v]);
    expect(r.reviewed_sha256).toBe(reviewedSha);
    expect(r.spec_sha256).toBe(sha(f.spec));
    expect(r.spec_sha256).not.toBe(reviewedSha);
    expect(r.residuals).toBe(3);
  });

  // ---- capped carry v2: the producer route and the readback by schema (step 4a). Every signing below is in the temporary release root with the synthetic key and a scratch HOME;
  // each fixture is built by the real builders in its own scratch root inside it, and the artifact tree is never the release root.
  type V2Fixture = CappedFixture & { keys?: string[]; anchor?: string; members?: string[]; earlier?: string[]; decision?: string | null; all: string[] };
  const v2Build = (request: Record<string, unknown>): V2Fixture => {
    if (!realBun) throw new Error('capped fixture requires Bun on PATH; install the pinned .bun-version');
    const f = JSON.parse(execFileSync(realBun, [join(candidateRoot, 'scripts/telegram/testlib-capped-fold.ts')], {
      input: JSON.stringify({ scratchRoot: mkdtempSync(join(root, 'v2-')), ...request }), encoding: 'utf8', timeout: 15000,
    })) as V2Fixture;
    f.all = f.verdicts;
    f.verdicts = (['spec', 'plan'] as const).map(kind => f.all.filter(p => p.includes(`.critic-${kind}-r`)).at(-1) as string);
    return f;
  };
  const v2Keys = (f: V2Fixture) => f.keys ?? [/(HIMMEL-\d+)/.exec(basename(f.spec))![1]];
  const v2Sign = (f: V2Fixture, extra: Record<string, unknown> = {}, c: Ctx = sctx()) => signSpec(c, {
    keys: v2Keys(f), spec: f.spec, plan: f.plan, verdicts: f.verdicts, decision: '387', verbatim: 'approve', ...extra,
  });
  const spawnReset = () => { cappedSpawn.fn = null; cappedSpawn.options.length = 0; cappedSpawn.attempts.length = 0; };
  const attemptFlags = () => cappedSpawn.attempts.map(a => a[2]);
  const releaseRows = () => existsSync(join(sctx().dir, 'operator.jsonl')) ? readFileSync(join(sctx().dir, 'operator.jsonl'), 'utf8').trim().split('\n').filter(Boolean).length : 0;
  const v2Tree = (f: V2Fixture) => {
    const decisions: Record<string, number> = {};
    const dir = join(f.specsRoot, 'decisions');
    if (existsSync(dir)) for (const name of readdirSync(dir)) decisions[name] = statSync(join(dir, name)).mtimeMs;
    return { files: fixtureHashes(f.specsRoot), decisions, rows: readFileSync(f.ledgerPath, 'utf8').trim().split('\n').map(l => (JSON.parse(l) as { row: string }).row) };
  };
  const within = (path: string, dir: string) => path === dir || path.startsWith(`${dir}/`);
  function v2Hermetic(f: V2Fixture): () => void {
    const home = process.env.HOME as string;
    const before = readdirSync(home, { recursive: true }).sort();
    return () => {
      const env = specEnv();
      expect(within(env.HIMMEL_RELEASE_STATE_DIR, root) && within(env.HIMMEL_RELEASE_KEY_DIR, root), 'the release root and the key are inside the temporary root').toBe(true);
      expect(within(home, root) && within(f.specsRoot, root), 'HOME and the fixture are scratch directories inside the temporary root').toBe(true);
      expect(within(f.specsRoot, env.HIMMEL_RELEASE_STATE_DIR) || within(env.HIMMEL_RELEASE_STATE_DIR, f.specsRoot), 'the release root and the artifact tree share no path').toBe(false);
      expect(readdirSync(home, { recursive: true }).sort(), 'nothing under HOME changed').toEqual(before);
    };
  }
  // The same fixture the v1 route refuses and the v2 route accepts, with every declaration spec-review reads: a finding heading with a context tag after its severity.
  function v2OnlyFixture(): V2Fixture {
    return v2Build({ key: 'HIMMEL-10205',
      specText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nKey: HIMMEL-10205\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n',
      planText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 plan\n\n- Ticket: HIMMEL-10205\n\n- Task 1: build the fixture.\n',
      returns: [1, 2, 3].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
        text: `- **F1** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
        reads: ['spec', 'plan', { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' }, { path: 'specs/designs/page.html', text: '<p>fixture</p>\n' }] }))) });
  }
  // The armed `--keys` spawn answers with the real verifier's proof, rewritten by `mutate` (the verifier is never edited); a refusal of the real verifier is thrown as the child would.
  const armProof = (mutate: (proof: any, args: string[]) => void, argv: (args: string[]) => string[] = args => args) => {
    cappedSpawn.fn = args => {
      const run = spawnSync(realBun, argv(args), { encoding: 'utf8', timeout: 15000 });
      if (run.status !== 0) throw Object.assign(new Error(run.stderr), { status: run.status, stderr: run.stderr });
      const proof = JSON.parse(run.stdout);
      mutate(proof, args);
      return JSON.stringify(proof);
    };
  };
  const OTHER = 'f'.repeat(64);

  // ---- the two chief docs of the v2 route, read in the finite format the plan defines (a marker line, the next fenced block, the lines between); no shell is parsed.
  const CHIEF_DOCS = ['docs/handover/chief-sections/telegram-files.md', 'docs/handover/running-a-chief.md'] as const;
  const SIGNING_MARKER = '<!-- signing-hash-check -->';
  const chiefDoc = (rel: string) => readFileSync(join(candidateRoot, rel), 'utf8');
  const occurrences = (text: string, needle: string) => text.split(needle).length - 1;
  // The lines between the fence that follows the marker line and the next fence, verbatim; null when no marker line is followed by a closed fence.
  function markedBlock(text: string): string | null {
    const lines = text.split('\n'); const marker = lines.indexOf(SIGNING_MARKER);
    const open = marker < 0 ? -1 : lines.findIndex((l, i) => i > marker && l.startsWith('```'));
    const close = open < 0 ? -1 : lines.findIndex((l, i) => i > open && l.startsWith('```'));
    return close < 0 ? null : lines.slice(open + 1, close).join('\n');
  }
  // The section of a chief doc: its heading line up to the line before the next heading of the same level (or the end of the file), without trailing blank lines.
  const SECTION_HEADING = '## Ledger-bound capped carry (proof v2)';
  function docSection(text: string): string | null {
    const lines = text.split('\n'); const start = lines.indexOf(SECTION_HEADING);
    if (start < 0) return null;
    const next = lines.findIndex((l, i) => i > start && /^## /.test(l));
    return lines.slice(start, next < 0 ? lines.length : next).join('\n').trimEnd();
  }

  describe('capped carry v2 producer route', () => {
    beforeEach(() => {
      spawnReset();
      for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
      vi.stubEnv('HOME', mkdtempSync(join(root, 'home-')));
      declared();
    });
    afterEach(() => spawnReset());

    async function cliSign(f: V2Fixture, keys = v2Keys(f)) {
      writeFileSync(join(root, 'verbatim.txt'), 'approve 1-5\n');
      const out: string[] = [];
      const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
      try {
        await cli('operator', 'spec', 'R1', '--keys', keys.join(','), '--spec', f.spec, '--plan', f.plan, '--verdict', f.verdicts[0], '--verdict', f.verdicts[1],
          '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      } finally { log.mockRestore(); }
      return out;
    }
    const okLines = (keys: string[], f: V2Fixture, id: string) => keys.map(k => `SPEC ok ${k} ${f.spec} ${id}`);
    const staleLines = (keys: string[], f: V2Fixture, id: string) => keys.map(k => `SPEC-STALE ${k} ${f.spec} ${id}`);
    const GROUP_REFUSAL = /residual findings.*capped verifier unavailable\/refused: v1 route: capped carry requires one key, an explicit distinct plan and paired SPEC\/PLAN returns; v2: /;

    it('capped carry v2 signs a seven-key group through the real release operator spec: one schema-2 record, seven SPEC ok, the artifact tree unchanged (E1, R1, R2, E19)', async () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const done = v2Hermetic(f); const before = v2Tree(f); const rowsBefore = releaseRows();
      const releaseDir = sctx().dir;
      const releaseFiles = () => existsSync(releaseDir) ? Object.fromEntries(readdirSync(releaseDir, { recursive: true }).map(String).sort()
        .filter(n => statSync(join(releaseDir, n)).isFile()).map(n => [n, sha(join(releaseDir, n))])) : {};
      const releaseBefore = releaseFiles();
      await cliSign(f);
      const rows = readOperatorRecords('spec', specEnv());
      expect(rows).toHaveLength(1);
      const row = rows[0];
      const releaseAfter = releaseFiles();
      expect(Object.keys(releaseAfter).filter(n => releaseAfter[n] !== releaseBefore[n]), 'E19: the release directory changes in operator.jsonl only').toEqual(['operator.jsonl']);
      expect(Object.keys(releaseBefore).filter(n => !(n in releaseAfter)), 'E19: no release file is removed').toEqual([]);
      expect(row.capped_carry).toMatchObject({ schema: 2, reader_version: 2, mode: 'capped-carry-ledger', anchor: f.anchor, keys: [...keys].sort(), epoch: 1 });
      expect([...(row.keys ?? [])].sort()).toEqual([...keys].sort());
      expect(row.residuals).toBe(2);
      expect(row.capped_carry!.carried.map(c => [c.kind, c.finding_id, c.status]), 'R2: every carried entry is open-carried').toEqual([['spec', 'F1', 'open-carried'], ['plan', 'P1', 'open-carried']]);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      expect(v2Tree(f), 'R1: the artifact tree, every decision mtime and the ledger rows are unchanged').toEqual(before);
      expect(releaseRows(), 'the release root gains exactly one signed row').toBe(rowsBefore + 1);
      expect(cappedSpawn.attempts).toEqual([[expectedVerifier, 'capped-fold', '--keys', [...keys].sort().join(','), '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      done();
    }, 60000);

    it('capped carry v2 refuses six of the seven keys and eight keys: no record (E2)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const done = v2Hermetic(f);
      expect(() => v2Sign(f, { keys: keys.slice(0, 6) })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: tickets must declare only ${keys.slice(0, 6).join(', ')}`));
      expect(() => v2Sign(f, { keys: [...keys, 'HIMMEL-9808'] })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: tickets must declare only ${[...keys, 'HIMMEL-9808'].join(', ')}`));
      noCappedRows();
      expect(attemptFlags(), 'a group goes to the v2 route only').toEqual(['--keys', '--keys']);
      done();
    });

    it('capped carry v2 group record is stale after each pinned file edit, a ledger append, a history file edited or removed and an unsealed or foreign file (E3)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      const ok = okLines(keys, f, row.id); const stale = staleLines(keys, f, row.id);
      expect(check(keys)).toEqual(ok);
      const files = row.capped_carry!.pins.filter((p): p is pinned.EvidenceFilePin | pinned.HistoryPin => 'path' in p);
      expect(new Set(files.map(p => p.role))).toEqual(new Set(['ledger', 'manifest', 'return', 'artifact', 'snapshot', 'decision', 'history']));
      expect(files.filter(p => p.role === 'history').map(p => p.path).sort()).toEqual([...f.earlier!].sort());
      for (const pin of files.filter(p => p.role !== 'decision')) {
        const kept = readFileSync(pin.path);
        writeFileSync(pin.path, `${kept.toString()}\n`);
        expect(check(keys), `${pin.role} ${pin.path} edited`).toEqual(stale);
        writeFileSync(pin.path, kept);
        expect(check(keys), `${pin.role} ${pin.path} restored`).toEqual(ok);
      }
      const ledger = readFileSync(f.ledgerPath, 'utf8');
      writeFileSync(f.ledgerPath, `${ledger}${ledger.trim().split('\n').at(-1)}\n`);
      expect(check(keys), 'a ledger row appended').toEqual(stale);
      writeFileSync(f.ledgerPath, ledger);
      const history = f.earlier![0]; const kept = readFileSync(history);
      unlinkSync(history);
      expect(check(keys), 'a history file removed').toEqual(stale);
      writeFileSync(history, kept);
      expect(check(keys)).toEqual(ok);
      const unsealed = f.verdicts[0].replace('r3.md', 'r4.md');
      cpSync(f.verdicts[0], unsealed);
      expect(check(keys), 'a new unsealed return').toEqual(stale);
      unlinkSync(unsealed);
      const foreign = join(dirname(f.spec), 'HIMMEL-9801-foreign.md.critic-spec-r3.md');
      writeFileSync(foreign, 'a foreign return of the same key');
      expect(check(keys), 'a foreign file of the key at the signed round').toEqual(stale);
      unlinkSync(foreign);
      expect(check(keys)).toEqual(ok);
    }, 60000);

    it.each(['bytes', 'selection', 'mtime', 'file-alias', 'directory-alias'])('capped carry v2 group decision selection, mtime and alias fault is the only cause of the stale read: %s (E3)', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const decisionTime = Math.floor(Date.now() / 1000) + 2.140625;
      utimesSync(f.decision!, decisionTime, decisionTime);
      const row = v2Sign(f);
      const proof = row.capped_carry!; const mtime = statSync(f.decision!).mtimeMs;
      expect(proof.pins.find(p => p.role === 'decision')).toMatchObject({ path: f.decision, mtime_ms: mtime });
      expect(proof.pins.some(p => p.role === 'decision-selection')).toBe(true);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      const ledger = readFileSync(f.ledgerPath, 'utf8'); const bytes = readFileSync(f.decision!);
      if (fault === 'bytes') { writeFileSync(f.decision!, `${bytes.toString()}changed\n`); keepMtime(f.decision!, mtime); }
      if (fault === 'selection') writeFileSync(join(dirname(f.decision!), 'verbatim-decision-990-second.txt'), bytes);
      if (fault === 'mtime') { utimesSync(f.decision!, mtime / 1000 + 10, mtime / 1000 + 10); expect(readFileSync(f.decision!)).toEqual(bytes); }
      if (fault === 'file-alias') { const moved = join(dirname(f.specsRoot), 'same-decision'); renameSync(f.decision!, moved); symlinkSync(moved, f.decision!); }
      if (fault === 'directory-alias') { const moved = join(dirname(f.specsRoot), 'same-decisions'); renameSync(dirname(f.decision!), moved); symlinkSync(moved, dirname(f.decision!)); }
      for (const pin of proof.pins) if ('path' in pin && pin.role !== 'decision') expect(sha(pin.path), `${pin.role} unchanged`).toBe(pin.sha256);
      expect(readFileSync(f.ledgerPath, 'utf8')).toBe(ledger);
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
    });

    it('capped carry v2 re-signs a schema-2 group record only by superseding it and keeping every key (E4)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const first = v2Sign(f);
      expect(() => v2Sign(f)).toThrow(new RegExp(`${keys[0]} is already signed in ${first.id}; re-sign with --supersedes ${first.id}`));
      expect(() => v2Sign(f, { keys: keys.slice(0, 6), supersedes: first.id }), 'the verifier refuses six of the seven before the engine reaches its own check').toThrow(GROUP_REFUSAL);
      expect(() => sign(sctx(), keys.slice(0, 6), spec('HIMMEL-9801-clean.md'), { supersedes: first.id }), 'an ordinary signing that drops a key').toThrow(new RegExp(`--keys must keep every key of ${first.id}; missing ${keys[6]}`));
      expect(check(keys)).toEqual(okLines(keys, f, first.id));
      const later = v2Sign(f, { supersedes: first.id }, { ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') });
      expect(later.capped_carry).toMatchObject({ schema: 2 });
      expect(check(keys)).toEqual(okLines(keys, f, later.id));
    });

    it('capped carry v2 refuses a group-shaped spec without its Estimate record line through the real release operator spec: no record (E5)', async () => {
      const keys = ['HIMMEL-9801', 'HIMMEL-9802'];
      const f = v2Build({ key: keys[0], declarations: false,
        specText: `---\ntickets: [${keys.join(', ')}]\n---\n# HIMMEL-9801 group\n\nThe contract names every member.\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`,
        planText: '# HIMMEL-9801 plan\n\n- Task 1: build the fixture.\n',
        returns: [1, 2, 3].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
          text: `- **F1** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`, reads: ['spec', 'plan'] }))) });
      await expect(cliSign(f, keys)).rejects.toThrow(/release operator spec: minerva-spec-gate.sh refused the spec:/);
      expect(attemptFlags(), 'the artifact reached the verifier and the lint refused after it').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 proof fails the unchanged v1 shape validator and passes the v2 one, and the pinned reader version is still 1 (E8: the validator contract)', () => {
      const f = v2Build({ builder: 'group' }); const row = v2Sign(f);
      expect(() => pinned.validateCappedFoldProofShape(row.capped_carry)).toThrow('invalid capped-fold proof');
      expect(pinned.validateCappedProofShape(row.capped_carry)).toEqual(row.capped_carry);
      expect(pinned.PINNED_READ_VERSION).toBe(1);
    });

    it('capped carry v2 group refusal names the v1 route before the v2 reason: the verifier refuses a member that holds a ledger, and a mocked v2 spawn throws its timeout (E9; a real child timeout is pinned for v1 only)', () => {
      const f = v2Build({ builder: 'group', reset: 'none' }); const keys = f.keys!;
      writeFileSync(join(pinned.ledgerDirOf(f.specsRoot), `${f.members![0]}.jsonl`), '');
      expect(() => v2Sign(f)).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: group member holds ledger state: ${f.members![0]}`));
      expect(() => v2Sign(f)).toThrow(/residual findings.*one key/);
      noCappedRows();
      expect(attemptFlags()).toEqual(['--keys', '--keys']);
      spawnReset();
      cappedSpawn.fn = () => { throw Object.assign(new Error('spawnSync bun ETIMEDOUT'), { code: 'ETIMEDOUT' }); };
      expect(() => v2Sign(f)).toThrow(new RegExp(`${GROUP_REFUSAL.source}spawnSync bun ETIMEDOUT$`));
      expect(cappedSpawn.options).toEqual([expect.objectContaining({ timeout: 30000, maxBuffer: 4194304 })]);
      expect(cappedSpawn.attempts).toEqual([[expectedVerifier, 'capped-fold', '--keys', [...keys].sort().join(','), '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      noCappedRows();
    });

    it('capped carry v2 one key a v1 verifier accepts is stored as schema 1, byte for byte what the verifier printed, with one --key attempt and no --keys (E11, E15)', () => {
      const f = cappedFixture(); const done = v2Hermetic(f as V2Fixture);
      const row = cappedSign('spec', f);
      const attempts = cappedSpawn.attempts.map(a => [...a]);
      expect(attempts, 'the whole attempt list of the signing, before the comparison child runs').toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      expect(row.capped_carry).toMatchObject({ schema: 1, mode: 'capped-carry', key: 'HIMMEL-10205' });
      const printed = execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 });
      expect(JSON.stringify(row.capped_carry)).toBe(printed.trim());
      expect(cappedSpawn.attempts.slice(0, 1)).toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      expect(attemptFlags().slice(0, 1)).toEqual(['--key']);
      expect(attemptFlags().includes('--keys')).toBe(false);
      expect(check(['HIMMEL-10205'])).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
      done();
    });

    it('capped carry v2 known-single refusedCap: v1 refuses, v2 accepts, one schema-2 record, SPEC ok, the artifact tree unchanged (E12, R1, R2)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'refusedCap' }); const key = v2Keys(f)[0];
      const done = v2Hermetic(f); const before = v2Tree(f); const rowsBefore = releaseRows();
      const row = v2Sign(f);
      expect(row.capped_carry).toMatchObject({ schema: 2, mode: 'capped-carry-ledger', anchor: key, keys: [key], epoch: 0 });
      expect(attemptFlags(), 'the shipped route first, then v2 with the one key').toEqual(['--key', '--keys']);
      expect(cappedSpawn.attempts[1].slice(2, 4)).toEqual(['--keys', key]);
      expect(row.capped_carry!.carried.map(c => [c.kind, c.finding_id, c.status]), 'R2').toEqual([['plan', 'P4', 'open-carried'], ['plan', 'P5', 'open-carried']]);
      expect(readOperatorRecords('spec', specEnv()).find(r => r.id === row.id)?.capped_carry).toEqual(row.capped_carry);
      expect(check([key])).toEqual([`SPEC ok ${key} ${f.spec} ${row.id}`]);
      expect(v2Tree(f), 'R1').toEqual(before);
      expect(releaseRows()).toBe(rowsBefore + 1);
      done();
    });

    it('capped carry v2 admittedNextRound: both routes refuse and the message holds the first route reason, then the v2 reason (E13)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'admittedNextRound' }); const key = v2Keys(f)[0];
      expect(() => v2Sign(f)).toThrow(new RegExp(`residual findings.*capped verifier unavailable/refused: capped-fold: capped-fold: header must declare only ${key}; v2: capped-fold: capped-fold: findings have not reached the refused round cap$`));
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      noCappedRows();
    });

    it('capped carry v2 never runs for spec-review: a v2-only artifact is refused by the v1 route alone and signs through release operator spec (E14)', () => {
      const f = v2OnlyFixture();
      let refusal = '';
      try { cappedSign('spec-review', f); } catch (e) { refusal = (e as Error).message; }
      expect(refusal).toMatch(/residual findings.*capped verifier unavailable\/refused: capped-fold: capped-fold: ineligible finding heading/);
      expect(refusal, 'the shipped refusal alone, no v2 reason').not.toContain('; v2:');
      expect(attemptFlags(), 'no --keys spawn from spec-review').toEqual(['--key']);
      noCappedRows();
      spawnReset();
      const row = cappedSign('spec', f);
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor: 'HIMMEL-10205' });
      expect(attemptFlags()).toEqual(['--key', '--keys']);
    });

    it.each(['malformed', 'output', 'reader-version', 'schema', 'key', 'returned-drift', 'latest-return-3'])('capped carry v2 never retries a final failure of the v1 route on v2: %s (P3-2)', mode => {
      const f = cappedFixture();
      rejectingBun(mode, () => {
        expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:/);
        expect(attemptFlags(), 'exactly one --key attempt and no --keys').toEqual(['--key']);
        noCappedRows();
      });
    }, 60000);

    it('capped carry v2 never retries after an absent Bun, and goes to v2 only after a non-zero exit of the v1 verifier (P3-2)', () => {
      const f = cappedFixture();
      const old = process.env.PATH;
      process.env.PATH = join(root, 'absent-bun');
      try { expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOENT/); } finally { process.env.PATH = old; }
      expect(attemptFlags()).toEqual(['--key']);
      spawnReset();
      rejectingBun('nonzero', () => {
        expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused: rejecting verifier exit; v2: rejecting verifier exit$/);
        expect(attemptFlags()).toEqual(['--key', '--keys']);
        spawnReset();
        expect(() => cappedSign('spec-review', f)).toThrow(/capped verifier unavailable\/refused: rejecting verifier exit$/);
        expect(attemptFlags(), 'spec-review stops after the one --key attempt').toEqual(['--key']);
      });
      noCappedRows();
    });

    // A forged answer to the v2 spawn is the engine's to refuse, and a refusal on the v2 leg is final: the spawn is made once.
    const FORGED = ['anchor', 'keys', 'spec-hash', 'plan-hash', 'return-full', 'return-normalized', 'residuals', 'declared-tickets'] as const;
    it.each(FORGED)('capped carry v2 binds the proof to the signing input: %s', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const message = {
        anchor: /capped proof anchor disagrees$/, keys: /capped proof input binding disagrees$/, 'spec-hash': /capped proof input binding disagrees$/, 'plan-hash': /capped proof input binding disagrees$/,
        'return-full': /capped proof plan return binding disagrees$/, 'return-normalized': /capped proof plan return binding disagrees$/, residuals: /capped proof plan return binding disagrees$/,
        'declared-tickets': /capped proof declared tickets disagree$/,
      }[fault];
      const requested = fault === 'declared-tickets' ? keys.slice(0, 6) : keys;
      armProof(p => {
        const absence = (members: string[]) => { for (const pin of p.pins) if (pin.role === 'member-absence') pin.keys = members; };
        const rehash = (artifact: { path: string; sha256: string }) => { artifact.sha256 = OTHER; for (const pin of p.pins) if (pin.path === artifact.path) pin.sha256 = OTHER; };
        if (fault === 'anchor') { p.anchor = p.keys[1]; for (const c of p.carried) c.key = p.keys[1]; absence(p.keys.filter((k: string) => k !== p.keys[1])); }
        if (fault === 'keys') { p.keys = p.keys.slice(0, 6); absence(p.keys.slice(1)); }
        if (fault === 'declared-tickets') { p.keys = p.keys.slice(0, 6); absence(p.keys.slice(1)); }
        if (fault === 'spec-hash') rehash(p.spec);
        if (fault === 'plan-hash') rehash(p.plan);
        if (fault === 'return-full') rehash(p.returns[1]);
        if (fault === 'return-normalized') { p.returns[1].return_sha = OTHER; for (const c of p.carried) if (c.kind === 'plan') c.return_sha = OTHER; }
        if (fault === 'residuals') { p.returns[1].residuals++; p.carried.push({ ...p.carried.find((c: any) => c.kind === 'plan'), finding_id: 'P2' }); }
      }, args => args.map((a, i) => i === 3 ? keys.join(',') : a));
      expect(() => v2Sign(f, { keys: requested })).toThrow(message);
      expect(attemptFlags(), 'the v2 spawn is made once').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 refuses an answer that is not a schema-2 proof, and never asks again: schema 1, unparseable, an invalid shape (P3-2)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'refusedCap' }); const other = cappedFixture();
      const v1 = execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', other.spec, '--plan', other.plan, '--spec-return', other.verdicts[0], '--plan-return', other.verdicts[1]], { encoding: 'utf8', timeout: 15000 });
      spawnReset();
      cappedSpawn.fn = () => v1;
      expect(() => v2Sign(f)).toThrow(/; v2: capped proof schema disagrees: a --keys call was answered with schema 1$/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      spawnReset();
      cappedSpawn.fn = () => 'not JSON';
      expect(() => v2Sign(f)).toThrow(/; v2: Unexpected token/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      spawnReset();
      armProof(p => { p.reader_version = 1; });
      expect(() => v2Sign(f)).toThrow(/; v2: invalid capped-fold proof$/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      noCappedRows();
    });

    it.each(['history-edit', 'history-removed', 'return-edit', 'unaccounted-return'])('capped carry v2 checks every pin of the proof before it is stored: %s', fault => {
      const f = v2Build({ builder: 'group' });
      armProof(p => {
        const history = p.pins.find((pin: any) => pin.role === 'history').path;
        if (fault === 'history-edit') writeFileSync(history, `${readFileSync(history, 'utf8')}\n`);
        if (fault === 'history-removed') unlinkSync(history);
        if (fault === 'return-edit') writeFileSync(p.returns[0].path, `${readFileSync(p.returns[0].path, 'utf8')}\n`);
        if (fault === 'unaccounted-return') cpSync(p.returns[0].path, p.returns[0].path.replace('r3.md', 'r4.md'));
      });
      const expected = fault === 'unaccounted-return' ? /; v2: capped-fold: ambiguous or unaccounted latest return: .*r4\.md$/ : /; v2: capped evidence changed or unreadable: /;
      expect(() => v2Sign(f)).toThrow(expected);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 reads schema-1 and schema-2 records by their own code, and an unknown schema reads stale (E16)', () => {
      const single = cappedFixture(); const v1Row = cappedSign('spec', single);
      const g = v2Build({ builder: 'group' }); const keys = g.keys!; const v2Row = v2Sign(g);
      expect([v1Row.capped_carry!.schema, v2Row.capped_carry!.schema]).toEqual([1, 2]);
      const lines = () => check(['HIMMEL-10205', ...keys]);
      expect(lines()).toEqual([`SPEC ok HIMMEL-10205 ${single.spec} ${v1Row.id}`, ...okLines(keys, g, v2Row.id)]);
      const copy = (row: typeof v2Row, id: string, schema: number) => ({ ...row, id, supersedes: row.id, capped_carry: { ...JSON.parse(JSON.stringify(row.capped_carry)), schema } });
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy(v2Row, 'O-R1-9001', 3));
      expect(lines()).toEqual([`SPEC ok HIMMEL-10205 ${single.spec} ${v1Row.id}`, ...staleLines(keys, g, 'O-R1-9001')]);
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy(v1Row, 'O-R1-9002', 3));
      expect(lines()).toEqual([`SPEC-STALE HIMMEL-10205 ${single.spec} O-R1-9002`, ...staleLines(keys, g, 'O-R1-9001')]);
    });

    it('capped carry v2 CLEAN spec and CLEAN plan sign ordinarily: no verifier is spawned and no capped proof is stored (E18)', () => {
      const p = spec();
      const row = sign(sctx(), ['K-1'], p);
      expect(row).not.toHaveProperty('capped_carry');
      expect(cappedSpawn.attempts).toEqual([]);
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${row.id}`]);
    });

    it.each(['null', 'unknown-field', 'schema-1', 'reader-version', 'missing-pin', 'keys', 'anchor', 'spec', 'plan', 'returns', 'count', 'declared-tickets'])('capped carry v2 persisted malformed or unbound proof stale: %s', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const copy: any = { ...row, id: 'O-R1-9000', supersedes: row.id, capped_carry: proof };
      if (fault === 'null') copy.capped_carry = null;
      if (fault === 'unknown-field') proof.unknown = true;
      if (fault === 'schema-1') proof.schema = 1;
      if (fault === 'reader-version') proof.reader_version = 1;
      if (fault === 'missing-pin') proof.pins = proof.pins.filter((p: { role: string }) => p.role !== 'ledger');
      if (fault === 'keys') copy.keys = [...keys, 'HIMMEL-8888'];
      if (fault === 'anchor') { proof.anchor = keys[1]; for (const c of proof.carried) c.key = keys[1]; for (const pin of proof.pins) if (pin.role === 'member-absence') pin.keys = keys.filter(k => k !== keys[1]); }
      if (fault === 'spec') { copy.spec_path = join(root, 'same-spec.md'); cpSync(f.spec, copy.spec_path); }
      if (fault === 'plan') { copy.plan_path = join(root, 'same-plan.md'); cpSync(f.plan, copy.plan_path); }
      if (fault === 'returns') { const path = join(root, 'same-return.md'); cpSync(f.verdicts[0], path); copy.verdicts = [{ path, sha256: sha(path) }, row.verdicts![1]]; }
      if (fault === 'count') copy.residuals = 0;
      if (fault === 'declared-tickets') { copy.keys = keys.slice(0, 6); proof.keys = keys.slice(0, 6); for (const pin of proof.pins) if (pin.role === 'member-absence') pin.keys = keys.slice(1, 6); }
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy);
      expect(readOperatorRecords('spec', specEnv()).at(-1)?.id).toBe(copy.id);
      expect(check([keys[0]])).toEqual([`SPEC-STALE ${keys[0]} ${copy.spec_path} ${copy.id}`]);
    });

    it('capped carry v2 stored member-absence pin on another folder reads stale: a scratch folder, another specs root, other keys (E26)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      const withAbsence = (id: string, supersedes: string, change: (pin: any) => void) => {
        const proof = JSON.parse(JSON.stringify(row.capped_carry));
        for (const pin of proof.pins) if (pin.role === 'member-absence') change(pin);
        appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), { ...row, id, supersedes, capped_carry: proof });
      };
      withAbsence('O-R1-9001', row.id, () => {});
      expect(check(keys), 'control: an unchanged copy reads fresh').toEqual(okLines(keys, f, 'O-R1-9001'));
      withAbsence('O-R1-9002', 'O-R1-9001', pin => { pin.directory = join(root, 'scratch-ledgers'); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9002'));
      withAbsence('O-R1-9003', 'O-R1-9002', pin => { pin.directory = join(mkdtempSync(join(root, 'other-specs-')), 'specs', 'ledgers', 'spec-rounds'); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9003'));
      withAbsence('O-R1-9004', 'O-R1-9003', pin => { pin.keys = pin.keys.slice(1); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9004'));
    });

    it('capped carry v2 a guard that refuses before any spawn refuses once with its shipped words, for a group too (P3-2)', () => {
      const f = v2Build({ builder: 'group' });
      const guard = /residual findings.*capped verifier unavailable\/refused: capped carry requires one key, an explicit distinct plan and paired SPEC\/PLAN returns$/;
      expect(() => v2Sign(f, { plan: undefined })).toThrow(guard);
      expect(() => v2Sign(f, { plan: f.spec })).toThrow(guard);
      expect(cappedSpawn.attempts, 'no spawn and no v2 reason').toEqual([]);
      noCappedRows();
    });

    it('capped carry v2 refuses a spec edited after the verifier answered, at the bind, before any pin is read', () => {
      const f = v2Build({ builder: 'group' });
      armProof(() => { writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n`); });
      expect(() => v2Sign(f)).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 spawns with the keys sorted whatever order they were requested in, and keeps the requested order on the record (E1)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const reversed = [...keys].reverse();
      const row = v2Sign(f, { keys: reversed });
      expect(cappedSpawn.attempts[0].slice(2, 4)).toEqual(['--keys', [...keys].sort().join(',')]);
      expect(row.keys).toEqual(reversed);
      expect(row.capped_carry).toMatchObject({ keys: [...keys].sort() });
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    });

    // A group whose anchor does not sort first, the shape of the real family (its anchor sorts last). The group builder fixes its anchor as the first key,
    // so the fixture is built by the real round builder with the group's declarations, as the verifier's own anchor-last row is.
    const ANCHORS = [['last', 'HIMMEL-9899', ['HIMMEL-9801', 'HIMMEL-9802', 'HIMMEL-9803', 'HIMMEL-9899']], ['in the middle', 'HIMMEL-9830', ['HIMMEL-9801', 'HIMMEL-9830', 'HIMMEL-9899']]] as const;
    function v2AnchorFixture(anchor: string, keys: readonly string[]): V2Fixture {
      const estimate = { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
      const f = v2Build({ key: anchor, declarations: false,
        specText: `---\ntickets: [${keys.join(', ')}]\n---\n# ${anchor} group\n\nEstimate record: estimate.json\n\nThe contract names every member.\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`,
        planText: `# ${anchor} plan\n\n- Task 1: build the fixture.\n`,
        returns: [1, 2, 3].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
          text: `- **${kind === 'spec' ? 'F1' : 'P1'}** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
          reads: kind === 'spec' ? ['spec', estimate] : ['spec', 'plan', estimate] }))) });
      f.keys = [...keys];
      f.anchor = anchor;
      return f;
    }

    it.each(ANCHORS)('capped carry v2 uses the anchor and not the first key in a group whose anchor sorts %s: signing, the stored record and the readback', (_where, anchor, keys) => {
      const f = v2AnchorFixture(anchor, keys); const sorted = [...keys].sort(); const done = v2Hermetic(f);
      expect(sorted[0], 'the anchor is not the first key').not.toBe(anchor);
      const unsealed = f.verdicts[0].replace('r3.md', 'r4.md');
      armProof(p => { cpSync(p.returns[0].path, unsealed); });
      expect(() => v2Sign(f, { keys }), 'signing: an unaccounted return of the anchor that appears after the verifier answered').toThrow(/; v2: capped-fold: ambiguous or unaccounted latest return: .*r4\.md$/);
      noCappedRows();
      unlinkSync(unsealed);
      spawnReset();
      const row = v2Sign(f, { keys });
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor, keys: sorted });
      expect(row.capped_carry!.carried.every(c => c.key === anchor), 'every carried finding belongs to the anchor').toBe(true);
      expect(readOperatorRecords('spec', specEnv()).find(r => r.id === row.id)?.capped_carry, 'the stored record').toEqual(row.capped_carry);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      cpSync(f.verdicts[0], unsealed);
      expect(check(keys), 'the readback: a return of the anchor above the signed round copied in later').toEqual(staleLines(keys, f, row.id));
      unlinkSync(unsealed);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      done();
    });

    // The key-set check of the bind has two halves; the verifier is always asked for the real keys and the signing input differs from them.
    const realKeys = (keys: string[]) => (args: string[]) => args.map((a, i) => i === 3 ? keys.join(',') : a);
    it('capped carry v2 refuses a proof whose keys are a strict superset of the signing input, the input being a prefix of them', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      armProof(() => {}, realKeys(keys));
      expect(() => v2Sign(f, { keys: keys.slice(0, 6) })).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 refuses a proof whose keys have the signing input\'s count and one different key', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      armProof(() => {}, realKeys(keys));
      expect(() => v2Sign(f, { keys: [...keys.slice(0, 6), 'HIMMEL-9808'] })).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    // A bun that kills itself with a signal: its parent sees no exit status and no error code, the case that is final and never retried on v2.
    function signalBun(signal: string, run: () => void): void {
      const bin = mkdtempSync(join(root, 'bun-bin-'));
      writeFileSync(join(bin, 'bun'), `#!${process.execPath}\nprocess.kill(process.pid, ${JSON.stringify(signal)});\nsetTimeout(() => {}, 5000);\n`);
      chmodSync(join(bin, 'bun'), 0o755);
      const old = process.env.PATH;
      process.env.PATH = `${bin}:${old}`;
      try { run(); } finally { process.env.PATH = old; rmSync(bin, { recursive: true, force: true }); }
    }
    it.each(['SIGKILL', 'SIGTERM'])('capped carry v2 a v1 child killed by %s is final: one --key attempt, no --keys, the shipped refusal words', signal => {
      const f = cappedFixture();
      signalBun(signal, () => {
        let refusal = '';
        try { cappedSign('spec', f); } catch (e) { refusal = (e as Error).message; }
        expect(refusal).toMatch(/residual findings.*capped verifier unavailable\/refused: Command failed: bun /);
        expect(refusal, 'no v2 reason').not.toContain('; v2:');
      });
      expect(attemptFlags()).toEqual(['--key']);
      noCappedRows();
    });

    // ---- step 4b: member state at signing and on every read. One predicate over a fresh listing of the pinned ledger folder and the manifest bytes the record pins.
    const signedOnly = (row: { id: string }) => expect(readOperatorRecords('spec', specEnv()).map(r => r.id)).toEqual([row.id]);

    it.each(['ledger-file', 'snapshot-folder', 'manifest-entry'])('capped carry v2 group record is stale for every key once a member gains a %s after signing, and a fresh signing of the same group then refuses (E17)', kind => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const member = f.members![1]; const row = v2Sign(f);
      const dir = pinned.ledgerDirOf(f.specsRoot); const manifest = join(dir, 'manifest.json'); const kept = readFileSync(manifest);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      if (kind === 'ledger-file') writeFileSync(join(dir, `${member}.jsonl`), '');
      if (kind === 'snapshot-folder') mkdirSync(join(dir, member));
      if (kind === 'manifest-entry') { const m = JSON.parse(kept.toString()); m.keys[member] = { spec: 1, plan: 1 }; writeFileSync(manifest, JSON.stringify(m)); }
      expect(check(keys), 'every key, the anchor included').toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(f.anchor!), 'the reason').toEqual({ missing: expect.stringContaining(kind === 'manifest-entry'
        ? 'capped evidence changed or unreadable' : `capped evidence selection changed: ${dir}`) });
      spawnReset();
      expect(() => v2Sign(f, { supersedes: row.id })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: group member holds ledger state: ${member}`));
      expect(attemptFlags()).toEqual(['--keys']);
      signedOnly(row);
      if (kind === 'ledger-file') unlinkSync(join(dir, `${member}.jsonl`));
      if (kind === 'snapshot-folder') rmSync(join(dir, member), { recursive: true });
      if (kind === 'manifest-entry') writeFileSync(manifest, kept);
      expect(check(keys), 'the fault was the only cause').toEqual(okLines(keys, f, row.id));
    });

    it.each(['ledger-file', 'snapshot-folder'])('capped carry v2 a member %s created after the verifier answered and before the append refuses at the signing recheck under the lock, naming the shared ledger folder, and writes no record (E25)', kind => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot);
      const made = join(dir, kind === 'ledger-file' ? `${f.members![0]}.jsonl` : f.members![0]);
      signingLock.fn = () => { if (kind === 'ledger-file') writeFileSync(made, ''); else mkdirSync(made); };
      try { expect(() => v2Sign(f)).toThrow(new Error(`capped evidence selection changed: ${dir}`)); } finally { signingLock.fn = null; }
      expect(existsSync(made), 'the lock seam ran').toBe(true);
      expect(attemptFlags(), 'the verifier answered once, before the member existed').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 a listing over the bound is stale for the group and is never read as absence (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot);
      for (let i = 0; i < 4097; i++) writeFileSync(join(dir, `junk-${i}`), '');
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
      for (let i = 0; i < 4097; i++) unlinkSync(join(dir, `junk-${i}`));
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    }, 60000);

    it('capped carry v2 a member lock file and an unrelated name are no ledger state, a dangling link under a member name is (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const member = f.members![0]; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot);
      writeFileSync(join(dir, `${member}.jsonl.lock`), '');
      writeFileSync(join(dir, 'notes.txt'), '');
      expect(check(keys), 'a lock file and an unrelated name').toEqual(okLines(keys, f, row.id));
      symlinkSync(join(dir, 'gone'), join(dir, `${member}.jsonl`));
      expect(check(keys), 'a dangling link is present, never absent').toEqual(staleLines(keys, f, row.id));
    });

    it.each(['names-a-member', 'is-malformed'])('capped carry v2 the member check reads the manifest bytes the record pins: a manifest that %s is stale by the member words, not by a hash (E17)', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const manifest = join(dir, 'manifest.json');
      const original = JSON.parse(readFileSync(manifest, 'utf8'));
      const record = (bytes: string | null) => {
        const proof = JSON.parse(JSON.stringify(row.capped_carry));
        if (bytes !== null) { writeFileSync(manifest, bytes); for (const pin of proof.pins) if (pin.role === 'manifest') pin.sha256 = sha(manifest); }
        return { ...row, release: 'R1', capped_carry: proof };
      };
      expect(specCheck(specEnv(), keys, null, { records: [record(null)] }).lines, 'control: the record as signed').toEqual(okLines(keys, f, row.id));
      const out = specCheck(specEnv(), keys, null, { records: [record(fault === 'is-malformed' ? '{ not json' : JSON.stringify({ ...original, keys: { ...original.keys, [f.members![2]]: { spec: 1, plan: 1 } } }))] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
    });

    it('capped carry v2 the member check needs the pinned ledger folder itself: an alias of it is stale although every pinned file still reads (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      for (const pin of proof.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
      renameSync(dir, moved);
      symlinkSync(moved, dir);
      const out = specCheck(specEnv(), keys, null, { records: [{ ...row, release: 'R1', capped_carry: proof }] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
    });

    // ---- step 4c: the `Keys?:` and `Reviewed:` agreement of a return is one call, shared by the signing bind and the readback.
    const REVIEWED_WORDS = 'capped return Reviewed declaration disagrees with the current spec';
    const KEYS_WORDS = 'capped return Keys? declaration disagrees with the declared keys';
    const AGREEMENT = [['reviewed-wrong', REVIEWED_WORDS], ['keys-other', KEYS_WORDS], ['reviewed-doubled', REVIEWED_WORDS], ['keys-doubled', KEYS_WORDS]] as const;
    const AGREEMENT_CASES = (['spec', 'plan'] as const).flatMap(which => AGREEMENT.map(([fault, words]) => [which, fault, words] as const));
    const agreementLines = (fault: string, keys: string[], specSha: string): string[] => {
      const list = [...keys].sort().join(', ');
      return ({ 'reviewed-wrong': [`Reviewed: spec ${'e'.repeat(64)}`], 'keys-other': [`Keys: ${keys[0]}, HIMMEL-9999`], 'reviewed-doubled': [`Reviewed: spec ${specSha}`, `Reviewed: spec ${specSha}`],
        'keys-doubled': [`Keys: ${list}`, `Keys: ${list}`], control: [`Keys: ${list}`, `Reviewed: spec ${specSha}`] } as Record<string, string[]>)[fault];
    };
    const realProof = (f: V2Fixture) => JSON.parse(spawnSync(realBun, [expectedVerifier, 'capped-fold', '--keys', [...f.keys!].sort().join(','), '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 }).stdout);
    // The return file gains the lines, and the proof is rewritten consistently to the edited bytes (the return hash, its normalized hash, its pin and its carried entries),
    // so that every provenance check other than the agreement passes.
    function editReturn(f: V2Fixture, which: 'spec' | 'plan', lines: string[], proof: any): string {
      const i = which === 'spec' ? 0 : 1; const path = f.verdicts[i];
      writeFileSync(path, `${lines.join('\n')}\n${readFileSync(path, 'utf8')}`);
      proof.returns[i].sha256 = sha(path);
      proof.returns[i].return_sha = pinned.returnSha(readFileSync(path, 'utf8'));
      for (const pin of proof.pins) if (pin.path === path) pin.sha256 = sha(path);
      for (const c of proof.carried) if (c.kind === which) c.return_sha = proof.returns[i].return_sha;
      return path;
    }
    const refusalMessage = (run: () => unknown) => { try { run(); } catch (e) { return (e as Error).message; } return ''; };

    it.each(AGREEMENT_CASES)('capped carry v2 the bind refuses a %s return that disagrees with the declared keys or the spec at signing, with the agreement reason: %s (E10)', (which, fault, words) => {
      const f = v2Build({ builder: 'group' }); const proof = realProof(f);
      editReturn(f, which, agreementLines(fault, f.keys!, sha(f.spec)), proof);
      cappedSpawn.fn = () => JSON.stringify(proof);
      const message = refusalMessage(() => v2Sign(f));
      expect(message.endsWith(`; v2: ${words}`), message).toBe(true);
      expect(message, 'not a hash reason').not.toMatch(/binding disagrees|changed or unreadable/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it.each(['spec', 'plan'] as const)('capped carry v2 the bind signs a %s return whose Keys? and Reviewed lines agree, the control of E10', which => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const proof = realProof(f);
      editReturn(f, which, agreementLines('control', keys, sha(f.spec)), proof);
      cappedSpawn.fn = () => JSON.stringify(proof);
      const row = v2Sign(f);
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor: f.anchor });
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    });

    it.each(AGREEMENT_CASES)('capped carry v2 the readback reads a %s return that disagrees with the declared keys or the spec stale, with the agreement reason: %s (E22)', (which, fault, words) => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const path = editReturn(f, which, agreementLines(fault, keys, sha(f.spec)), proof);
      const record = { ...row, release: 'R1', verdicts: row.verdicts!.map(v => v.path === path ? { path, sha256: sha(path) } : v), capped_carry: proof };
      const out = specCheck(specEnv(), keys, null, { records: [record] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      const why = (out.answer.get(keys[0]) as { missing: string }).missing;
      expect(why.endsWith(words), why).toBe(true);
      expect(why, 'not a hash reason').not.toMatch(/binding disagrees|changed or unreadable/);
    });

    it.each(['spec', 'plan'] as const)('capped carry v2 the readback reads a %s return whose Keys? and Reviewed lines agree as fresh, the control of E22', which => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const path = editReturn(f, which, agreementLines('control', keys, sha(f.spec)), proof);
      const record = { ...row, release: 'R1', verdicts: row.verdicts!.map(v => v.path === path ? { path, sha256: sha(path) } : v), capped_carry: proof };
      expect(specCheck(specEnv(), keys, null, { records: [record] }).lines).toEqual(okLines(keys, f, row.id));
    });

    // ---- follow-ups of the 4b and 4c review: the member check must not depend on another check having run before it.
    // The shapes of the pinned ledger folder: every pinned file is moved with the real folder, so the file pins read, and a member ledger sits in the moved copy; only the member check stands in the way.
    const memberFolder = (shape: string) => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      for (const pin of proof.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
      renameSync(dir, moved);
      writeFileSync(join(moved, `${f.members![0]}.jsonl`), '');
      if (shape === 'a plain file') writeFileSync(dir, '');
      if (shape === 'a symlink to a file') { const target = join(dirname(f.specsRoot), 'a-file'); writeFileSync(target, ''); symlinkSync(target, dir); }
      if (shape === 'a dangling symlink') symlinkSync(join(dirname(f.specsRoot), 'nowhere'), dir);
      if (shape === 'a directory that cannot be listed') { mkdirSync(dir); chmodSync(dir, 0o311); }
      try {
        const out = specCheck(specEnv(), keys, null, { records: [{ ...row, release: 'R1', capped_carry: proof }] });
        expect(out.lines).toEqual(staleLines(keys, f, row.id));
        expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
      } finally { if (shape === 'a directory that cannot be listed') chmodSync(dir, 0o755); }
    };
    const memberTitle = 'capped carry v2 the member check refuses a pinned ledger folder that is %s, although every pinned file lives elsewhere and reads (E17)';
    it.each(['a plain file', 'a symlink to a file', 'a dangling symlink'])(memberTitle, memberFolder);
    it.skipIf(RUNS_AS_ROOT).each(['a directory that cannot be listed'])(memberTitle, memberFolder);

    it('capped carry v2 a doctored verifier answer whose pinned files moved with the ledger folder, now a plain file, is refused when the answer is checked, naming the folder (E17, the signing side)', () => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      armProof(p => {
        cpSync(dir, moved, { recursive: true });
        for (const pin of p.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
        rmSync(dir, { recursive: true });
        writeFileSync(dir, '');
        writeFileSync(join(moved, `${f.members![0]}.jsonl`), '');
      });
      expect(() => v2Sign(f)).toThrow(new RegExp(`; v2: capped evidence selection changed: ${dir}$`));
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    // The last key of the group sorts last among the members: the engine must hand the predicate the whole pinned key list.
    it('capped carry v2 a member ledger for the last key of the group makes the record stale and refuses at the signing recheck under the lock (E17, E25)', () => {
      const lock = v2Build({ builder: 'group' }); const last = lock.members!.at(-1) as string; const dir = pinned.ledgerDirOf(lock.specsRoot);
      expect(last, 'the last member sorts last').toBe([...lock.keys!].sort().at(-1));
      signingLock.fn = () => writeFileSync(join(dir, `${last}.jsonl`), '');
      try { expect(() => v2Sign(lock)).toThrow(new Error(`capped evidence selection changed: ${dir}`)); } finally { signingLock.fn = null; }
      noCappedRows();
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const ledgers = pinned.ledgerDirOf(f.specsRoot);
      writeFileSync(join(ledgers, `${last}.jsonl`), '');
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${ledgers}`) });
    });

    // The verifier answer is one of the places the plan names: a member that exists then is refused there, so the signing lock is never taken.
    it('capped carry v2 a member that exists when the verifier answer is checked is refused there, before the signing lock is taken (E17)', () => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot); let locked = false;
      armProof(() => { writeFileSync(join(dir, `${f.members![0]}.jsonl`), ''); });
      signingLock.fn = () => { locked = true; };
      try { expect(() => v2Sign(f)).toThrow(new RegExp(`; v2: capped evidence selection changed: ${dir}$`)); } finally { signingLock.fn = null; }
      expect(locked, 'the signing lock was never taken').toBe(false);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });
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

describe('a request names the operator\'s words', () => {
  const FILE = 'Operator, verbatim:\n\n"Approved one more round"\n\nAnswering the ask on HIMMEL-1: stop and park.\n';
  const WORDS = 'Approved one more round';
  const decisionFile = () => {
    const dir = join(root, 'specs', 'decisions');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'verbatim-decision-9-op.txt'), FILE);
    return join(dir, 'verbatim-decision-9-op.txt');
  };
  const decisionRows = () => readFileSync(join(root, 'release', 'R1', 'operator.jsonl'), 'utf8').trim().split('\n')
    .map((l) => JSON.parse(l) as OperatorRow).filter((o) => o.kind === 'decision');
  const latestOf = () => {
    const m = new Map<string, RequestRow>();
    for (const l of readFileSync(join(root, 'release', 'R1', 'requests.jsonl'), 'utf8').trim().split('\n')) {
      const r = JSON.parse(l) as RequestRow;
      m.set(r.req, r);
    }
    return [...m.values()];
  };
  const ask = { verb: 'INTAKE' as const, key: 'HIMMEL-1', from_v: null, to_v: 'v1', why: 'the operator asked for one more round', evidence: {}, from: 'console' };

  it('recordRequestDecision writes a words-only O- row', async () => {
    await setup();
    const path = decisionFile();
    const o = recordRequestDecision(ctx(), { decision: '9', words: WORDS, key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1' });
    expect(o).toMatchObject({
      kind: 'decision', decision: '9', keys: ['HIMMEL-1'], op: 'add', from_v: null, to_v: 'v1', verbatim: WORDS, words: 1,
      decision_file: 'specs/decisions/verbatim-decision-9-op.txt', decision_sha256: createHash('sha256').update(readFileSync(path)).digest('hex'),
    });
    expect(decisionRows()).toHaveLength(1);
  });

  it('words from a gloss are refused and write no row', async () => {
    await setup();
    decisionFile();
    expect(() => recordRequestDecision(ctx(), { decision: '9', words: 'stop and park', key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1' }))
      .toThrow(/not the operator's/);
    expect(decisionRows()).toHaveLength(0);
  });

  it('the request cites it', async () => {
    await setup();
    decisionFile();
    const got = requestWithWords(ctx(), ask, { decision: '9', words: WORDS });
    expect(got.withdrawn).toBeNull();
    expect(got.request.evidence).toMatchObject({ operator: got.operator.id });
    expect(got.request.why).toBe(`the operator asked for one more round (operator words: ${got.operator.id})`);
  });

  it('a retry reuses the O- row', async () => {
    await setup();
    decisionFile();
    const first = requestWithWords(ctx(), ask, { decision: '9', words: WORDS });
    const again = requestWithWords(ctx(), ask, { decision: '9', words: WORDS });
    expect(again.operator.id).toBe(first.operator.id);
    expect(again.request.req).toBe(first.request.req);
    expect(decisionRows()).toHaveLength(1);
    expect(latestOf().filter((r) => r.state === 'open')).toHaveLength(1);
  });

  it('other words from the same file are a new O- row, never the earlier quotation', async () => {
    await setup();
    const dir = join(root, 'specs', 'decisions');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'verbatim-decision-9-op.txt'), 'Operator:\n\nApproved one more round of the spike\n');
    const rec = (words: string) => recordRequestDecision(ctx(), { decision: '9', words, key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1' });
    const first = rec('Approved one more round');
    const other = rec('Approved one more round of the spike');
    expect(other.id).not.toBe(first.id);
    expect(other.verbatim).toBe('Approved one more round of the spike');
    expect(decisionRows()).toHaveLength(2);
  });

  it('a pending duplicate without evidence.operator is withdrawn and refiled', async () => {
    await setup();
    decisionFile();
    const plain = request(ctx(), ask);
    const got = requestWithWords(ctx(), ask, { decision: '9', words: WORDS });
    expect(got.withdrawn?.req).toBe(plain.req);
    expect(got.request.req).not.toBe(plain.req);
    const rows = latestOf();
    expect(rows.find((r) => r.req === plain.req)?.state).toBe(`withdrawn:${got.operator.id}`);
    expect(rows.find((r) => r.req === got.request.req)?.state).toBe('open');
  });

  it('the op mapping', async () => {
    await setup();
    decisionFile();
    const rec = (verb: 'INTAKE' | 'REVERSION', from_v: string | null, to_v: string) =>
      recordRequestDecision(ctx(), { decision: '9', words: WORDS, key: 'HIMMEL-1', verb, from_v, to_v });
    expect(rec('REVERSION', 'v1', 'v2')).toMatchObject({ op: 'move', from_v: 'v1', to_v: 'v2' });
    expect(rec('REVERSION', null, 'v1')).toMatchObject({ op: 'move', from_v: null, to_v: 'v1' });
    expect(rec('INTAKE', 'v2', 'v1')).toMatchObject({ op: 'move', from_v: 'v2', to_v: 'v1' });
    expect(rec('INTAKE', null, 'v2')).toMatchObject({ op: 'add', from_v: null, to_v: 'v2' });
  });

  it('the writer refuses inside a chief-spawned worker', async () => {
    await setup();
    decisionFile();
    expect(() => recordRequestDecision(ctx({ HIMMEL_CONSOLE_LEG: '1' }), { decision: '9', words: WORDS, key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1' }))
      .toThrow(/chief-spawned worker/);
  });

  it('T1: the fence refuses HIMMEL_BRIDGE_SESSION=1 in its own env', () => {
    expect(() => operatorFence(ctx({ HIMMEL_BRIDGE_SESSION: '1' })))
      .toThrow('release operator: a chief act on an operator decision; refused inside a Telegram bridge session or a process it started (the bridge names the operator\'s update, the chief\'s tick records it)');
  });

  it('T3: operator decision --words with the bridge marker in the ancestry is refused and writes no row; a clean tree records', async () => {
    await setup();
    decisionFile();
    const opRows = () => readFileSync(join(root, 'release', 'R1', 'operator.jsonl'), 'utf8').trim().split('\n').length;
    const before = opRows();
    const decide = (c: Ctx) => operatorDecision(c, { decision: '9', keys: ['HIMMEL-1'], op: 'add', from_v: null, to_v: 'v1', verbatim: WORDS, ...decisionWords(c, '9', WORDS) });
    expect(() => decide({ ...ctx(), ...fakeProc({ HIMMEL_BRIDGE_SESSION: '1' }) }))
      .toThrow(/refused inside a Telegram bridge session or a process it started.*ancestor 200/);
    expect(opRows()).toBe(before);
    expect(decide({ ...ctx(), ...fakeProc() })).toMatchObject({ kind: 'decision', words: 1 });
    expect(opRows()).toBe(before + 1);
  });

  it('load() does not verify decision_file', async () => {
    await setup();
    const path = decisionFile();
    recordRequestDecision(ctx(), { decision: '9', words: WORDS, key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1' });
    rmSync(path);
    expect(state(ctx()).status).toBe('OK');
  });
});

import { requestOnRecord, coveringRecord } from './engine.js';
import { chainFault } from './engine.js';
import { withLock } from './ledger.js';

// Decision 2026-11-19, item 8: a gated ask is filed citing an operator record that already names the key and the exact
// placement, with no words typed again and no new operator row. Each way the analysis says it could go wrong has its own rows.
describe('a gated ask cites the operator record that already covers it', () => {
  const FILE = 'Operator, verbatim:\n\n"Approved one more round of the spike"\n\nAnswering the ask on K-5: stop and park.\n';
  const WORDS = 'Approved one more round';
  const OTHER_WORDS = 'Approved one more round of the spike';
  let clock = 0;
  // Each write lands a minute after the last, so "newer" is a real order.
  const at = (env: Record<string, string> = consoleEnv): Ctx => {
    clock += 60_000;
    const d = new Date(Date.parse('2026-10-21T10:00:00.000Z') + clock);
    return { ...ctx(env), now: () => d };
  };
  const atTs = (t: number): Ctx => ({ ...ctx(), now: () => new Date(t) });
  beforeEach(() => { clock = 0; });
  type Placement = [op: string, from_v: string | null, to_v: string | null];
  type Ask = Omit<RequestRow, 'req' | 'ts' | 'state'>;
  const ADD_V1: Placement = ['add', null, 'v1'];
  const decisionFile = () => {
    const dir = join(root, 'specs', 'decisions');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'verbatim-decision-9-op.txt'), FILE);
  };
  const words = (c: Ctx, keys: string[], [op, from_v, to_v]: Placement, text = WORDS) =>
    operatorDecision(c, { decision: '9', keys, op, from_v, to_v, verbatim: text, ...decisionWords(c, '9', text) });
  const legacy = (c: Ctx, keys: string[], [op, from_v, to_v]: Placement) =>
    operatorDecision(c, { decision: '120', keys, op, from_v, to_v, verbatim: 'legacy, no words' });
  const ask = (o?: Partial<Ask>): Ask => ({ verb: 'INTAKE', key: 'K-5', from_v: null, to_v: 'v1', why: 'the operator asked for one more round', evidence: {}, from: 'console', ...o });
  const lines = (file: string) => (existsSync(file) ? readFileSync(file, 'utf8').trim().split('\n') : []);
  const operatorFile = () => join(root, 'release', 'R1', 'operator.jsonl');
  const queue = () => lines(join(root, 'release', 'R1', 'requests.jsonl')).map((l) => JSON.parse(l) as RequestRow);
  const forge = (fields: Record<string, unknown>, c: Ctx) =>
    appendChain<OperatorRow>(operatorFile(), loadKey(join(root, 'keys', 'R1.key')), { ts: c.now().toISOString(), ...fields });
  const tamper = (nth: number, edit: (row: Record<string, unknown>) => void) => {
    const rows = lines(operatorFile());
    const row = JSON.parse(rows[nth < 0 ? rows.length + nth : nth]) as Record<string, unknown>;
    edit(row);
    rows[nth < 0 ? rows.length + nth : nth] = JSON.stringify(row);
    writeFileSync(operatorFile(), `${rows.join('\n')}\n`);
  };
  const flip = (hex: unknown) => `${String(hex).startsWith('0') ? '1' : '0'}${String(hex).slice(1)}`;
  const mirrorOf = (...keys: Array<{ key: string; labels?: string[] }>) => mirror([{ key: 'K-1', fixVersions: ['v1'] }, ...keys.map((k) => ({ fixVersions: [] as string[], ...k }))]);
  const refuse = async (key: string) => {
    const q = request(at(), ask({ key }));
    claim(at(rmEnv));
    const r = rule(at(rmEnv), {
      req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'no operator words',
      reason: `name the operator's words for ${key}`, supersedes: [], authority: { kind: 'rm', ref: null },
    });
    await apply(at(rmEnv), r.id);
    return r;
  };

  it('files a gated ask with a covering words record and no --decision, cites that record, and writes no operator row', async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], ADD_V1);
    const before = lines(operatorFile());
    const got = requestOnRecord(at(), ask());
    expect(got?.operator.id).toBe(rec.id);
    expect(got?.request).toMatchObject({ key: 'K-5', verb: 'INTAKE', from_v: null, to_v: 'v1', state: 'open', why: 'the operator asked for one more round', evidence: { operator: rec.id } });
    expect(lines(operatorFile())).toEqual(before);
    expect(queue()).toHaveLength(1);
  });

  it.each([
    ['an INTAKE from backlog (an add)', ['add', null, 'v1'], {}],
    ['a REVERSION from backlog (a move)', ['move', null, 'v1'], { verb: 'REVERSION' }],
    ['a REVERSION out of v2 (a move)', ['move', 'v2', 'v1'], { verb: 'REVERSION', from_v: 'v2' }],
    ['an INTAKE from v2 (a move)', ['move', 'v2', 'v1'], { from_v: 'v2' }],
  ] as Array<[string, Placement, Partial<Ask>]>)('%s is placed by exactly its own record', async (_name, placement, change) => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], placement);
    expect(requestOnRecord(at(), ask(change))?.request.evidence).toEqual({ operator: rec.id });
  });

  it('keeps the chief\'s other evidence, and the record it cites always overrides an operator claim in the evidence', async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask({ evidence: { pr: 7, operator: 'O-R1-9999' } }))?.request.evidence).toEqual({ pr: 7, operator: rec.id });
  });

  it('a repeat of the ask returns the same open request, still citing the record, and files and records nothing more', async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], ADD_V1);
    const first = requestOnRecord(at(), ask());
    const again = requestOnRecord(at(), ask());
    expect(again?.request.req).toBe(first?.request.req);
    expect(again?.request.evidence).toEqual({ operator: rec.id });
    expect(queue()).toHaveLength(1);
    expect(lines(operatorFile()).filter((l) => (JSON.parse(l) as OperatorRow).kind === 'decision')).toHaveLength(1);
  });

  it('with two words records for the same placement it cites the newer, the one the RM reads as governing', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    const newer = words(at(), ['K-5'], ADD_V1, OTHER_WORDS);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(newer.id);
  });

  it('a newer record for another version, and an older legacy row, do not hide the record that governs this one', async () => {
    await setup();
    decisionFile();
    legacy(at(), ['K-5'], ['keep', 'v1', 'v1']);
    const rec = words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-5'], ['add', null, 'v2'], OTHER_WORDS);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(rec.id);
  });

  it('a release with no record of the key, the standing declare records only, files nothing and answers no record', async () => {
    await setup();
    expect(coveringRecord(at(), ask())).toBeUndefined();
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('a release that is not declared answers no record and creates no state', () => {
    const c9: Ctx = { ...ctx(), release: 'R9', dir: join(root, 'release', 'R9'), keyPath: join(root, 'keys', 'R9.key') };
    expect(requestOnRecord(c9, ask())).toBeUndefined();
    expect(existsSync(c9.dir)).toBe(false);
  });

  it('only INTAKE and REVERSION into a version are placed by a record: a DISCHARGE, or a move to backlog, never', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ['discharge', 'v1', null]);
    words(at(), ['K-5'], ['move', 'v1', null], OTHER_WORDS);
    expect(requestOnRecord(at(), ask({ verb: 'DISCHARGE', from_v: 'v1', to_v: null }))).toBeUndefined();
    expect(requestOnRecord(at(), ask({ verb: 'REVERSION', from_v: 'v1', to_v: null }))).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  const KINDS = ['declare', 'takeover', 'emergency', 'blocker-pull', 'delivered-follows-merge', 'spec', 'spec-review', 'core-bypass', 'core-snapshot', 'out-of-version'];
  it.each(KINDS)('way 1: a signed %s row that names the key and the placement never places it', async (kind) => {
    await setup();
    decisionFile();
    forge({ id: `O-R1-forged-${kind}`, kind, decision: '9', keys: ['K-5'], op: 'add', from_v: null, to_v: 'v1', verbatim: WORDS, words: 1, version: 'v1', reason: 'forged' }, at());
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 1: a live 14-day out-of-version approval alone never places the key, and does not hide a decision newer than it', async () => {
    await setup();
    decisionFile();
    forge({ id: 'O-R1-ov-K-5', kind: 'out-of-version', decision: '518', keys: ['K-5'], version: 'v1', reason: 'work permission' }, at());
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    const rec = words(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(rec.id);
  });

  it.each([
    ['another key', ['K-6']],
    ['a longer key that starts with it', ['K-50']],
    ['a multi-key row without it', ['K-6', 'K-7']],
  ])('way 2: a words record naming %s does not place the key', async (_name, keys) => {
    await setup();
    decisionFile();
    words(at(), keys, ADD_V1);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it.each([
    ['a move from backlog does not place an INTAKE (an add)', ['move', null, 'v1'], {}],
    ['an add from backlog does not place a REVERSION from backlog (a move)', ['add', null, 'v1'], { verb: 'REVERSION' }],
    ['a move from v2 does not place an INTAKE from backlog (a version versus backlog)', ['move', 'v2', 'v1'], {}],
    ['an add from backlog does not place a move out of v2 (backlog versus a version)', ['add', null, 'v1'], { verb: 'REVERSION', from_v: 'v2' }],
    ['a move from v3 does not place a move from v2 (the wrong from)', ['move', 'v3', 'v1'], { verb: 'REVERSION', from_v: 'v2' }],
    ['a move to v3 does not place a move to v1 (the wrong to)', ['move', 'v2', 'v3'], { verb: 'REVERSION', from_v: 'v2' }],
    ['an add to v2 does not place an INTAKE into v1', ['add', null, 'v2'], {}],
    ['a keep in v1 places nothing', ['keep', 'v1', 'v1'], {}],
    ['a remove from v1 places nothing', ['remove', 'v1', null], {}],
    ['a discharge in v1 places nothing', ['discharge', 'v1', null], {}],
  ] as Array<[string, Placement, Partial<Ask>]>)('way 3: %s', async (_name, placement, change) => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], placement);
    expect(requestOnRecord(at(), ask(change))).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 4: a legacy decision row (no words:1) for exactly this placement never places the key', async () => {
    await setup();
    legacy(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 4: a legacy row newer than the words record governs the key and refuses; an older one does not', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    legacy(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  it('way 5: a record older than the key\'s standing refusal is not cited, and the refused ask stays listed with its remedy', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    words(at(), ['K-5'], ADD_V1);
    const r = await refuse('K-5');
    const before = queue().length;
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toHaveLength(before);
    expect(state(ctx()).refused_asks).toMatchObject([{ key: 'K-5', ruling: r.id, remedy: expect.stringContaining('--decision <n> --words') }]);
  });

  it('way 5: a record newer than the standing refusal is cited, and the refusal leaves refused_asks', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    await refuse('K-5');
    const rec = words(at(), ['K-5'], ADD_V1);
    expect(state(ctx()).refused_asks).toEqual([]);
    const got = requestOnRecord(at(), ask());
    expect(got?.operator.id).toBe(rec.id);
    expect(got?.request.state).toBe('open');
  });

  it('way 5: a record in the same millisecond as the key\'s last ruling row is a tie and is not cited; one millisecond later it is', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    await refuse('K-5');
    const last = Math.max(...lines(join(root, 'release', 'R1', 'rulings.jsonl')).map((l) => Date.parse((JSON.parse(l) as RulingRow).ts)));
    words(atTs(last), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    const later = words(atTs(last + 1), ['K-5'], ADD_V1, OTHER_WORDS);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(later.id);
  });

  it('way 5: two records for the same placement in the same millisecond are a tie and neither is cited', async () => {
    await setup();
    decisionFile();
    const t = Date.parse('2026-10-21T12:00:00.000Z');
    words(atTs(t), ['K-5'], ADD_V1);
    words(atTs(t), ['K-5'], ADD_V1, OTHER_WORDS);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 5: of two records at one instant that disagree, none is cited', async () => {
    await setup();
    decisionFile();
    const t = Date.parse('2026-10-21T12:00:00.000Z');
    words(atTs(t), ['K-5'], ADD_V1);
    words(atTs(t), ['K-5'], ['remove', 'v1', null], OTHER_WORDS);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  it('way 6: an add followed by a later remove: only the governing remove counts, so the add is not cited', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-5'], ['remove', 'v1', null], OTHER_WORDS);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 6: an add followed by a later legacy keep: the governing legacy row refuses the add', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    legacy(at(), ['K-5'], ['keep', 'v1', 'v1']);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  it('way 6: a later words record that places it again governs again, and is the one cited', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-5'], ['remove', 'v1', null], OTHER_WORDS);
    const again = words(at(), ['K-5'], ADD_V1, 'Approved one more round of');
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(again.id);
  });

  // way 6, review F1: a newer decision that names no version still retracts an older placement
  const NO_VERSION = [
    ['legacy keep in backlog', 'legacy', ['keep', null, null]],
    ['words keep in backlog', 'words', ['keep', null, null]],
    ['legacy none', 'legacy', ['none', null, null]],
  ] as Array<[string, 'legacy' | 'words', Placement]>;
  const recordOf = (kind: 'legacy' | 'words', placement: Placement) => (kind === 'legacy' ? legacy(at(), ['K-5'], placement) : words(at(), ['K-5'], placement, OTHER_WORDS));
  it.each(NO_VERSION)('way 6: a newer %s, naming no version, supersedes the older add: the add is not cited', async (_name, kind, placement) => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    recordOf(kind, placement);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it.each(NO_VERSION)('way 6: an OLDER %s, naming no version, does not hide the add that follows it', async (_name, kind, placement) => {
    await setup();
    decisionFile();
    recordOf(kind, placement);
    const add = words(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  const SOURCE_SIDE = [
    ['legacy keep of the source', 'legacy', ['keep', 'v2', 'v2']],
    ['words keep of the source', 'words', ['keep', 'v2', 'v2']],
    ['legacy remove from the source', 'legacy', ['remove', 'v2', null]],
    ['words remove from the source', 'words', ['remove', 'v2', null]],
  ] as Array<[string, 'legacy' | 'words', Placement]>;
  it.each(SOURCE_SIDE)('way 6: a newer %s supersedes the older move v2 to v1: the move is not cited', async (_name, kind, placement) => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ['move', 'v2', 'v1']);
    recordOf(kind, placement);
    expect(requestOnRecord(at(), ask({ verb: 'REVERSION', from_v: 'v2' }))).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 6: an older keep of the source does not hide the newer move that follows it', async () => {
    await setup();
    decisionFile();
    legacy(at(), ['K-5'], ['keep', 'v2', 'v2']);
    const move = words(at(), ['K-5'], ['move', 'v2', 'v1']);
    expect(requestOnRecord(at(), ask({ verb: 'REVERSION', from_v: 'v2' }))?.operator.id).toBe(move.id);
  });

  // way 6, review 2 F3: a newer keep that names no source version retracts the older add whatever its --to says
  const KEEP_ELSEWHERE = [
    ['legacy keep in backlog naming v2', 'legacy', ['keep', null, 'v2']],
    ['words keep in backlog naming v2', 'words', ['keep', null, 'v2']],
  ] as Array<[string, 'legacy' | 'words', Placement]>;
  it.each(KEEP_ELSEWHERE)('way 6: a newer %s supersedes the older add: the add is not cited', async (_name, kind, placement) => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    recordOf(kind, placement);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it.each(KEEP_ELSEWHERE)('way 6: an OLDER %s does not hide the add that follows it', async (_name, kind, placement) => {
    await setup();
    decisionFile();
    recordOf(kind, placement);
    const add = words(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  it('way 6: a newer keep naming v2 for ANOTHER key never governs this key', async () => {
    await setup();
    decisionFile();
    const add = words(at(), ['K-5'], ADD_V1);
    legacy(at(), ['K-6'], ['keep', null, 'v2']);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  it.each(['out-of-version', 'core-bypass', 'emergency'])('way 6: a newer signed %s row naming the key and a keep in backlog is no decision and never governs', async (kind) => {
    await setup();
    decisionFile();
    const add = words(at(), ['K-5'], ADD_V1);
    forge({ id: `O-R1-forged-keep-${kind}`, kind, decision: '9', keys: ['K-5'], op: 'keep', from_v: null, to_v: 'v2', verbatim: WORDS, words: 1, version: 'v2', reason: 'forged' }, at());
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  it.each([
    ['keep in v2', ['keep', 'v2', 'v2']],
    ['remove from v2', ['remove', 'v2', null]],
  ] as Array<[string, Placement]>)('way 6: a newer %s, a version the ask does not touch, does not retract the add: a key may hold two versions', async (_name, placement) => {
    await setup();
    decisionFile();
    const add = words(at(), ['K-5'], ADD_V1);
    legacy(at(), ['K-5'], placement);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  it('the ordinary case: one covering add and nothing newer is cited', async () => {
    await setup();
    decisionFile();
    const add = words(at(), ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(add.id);
  });

  // way 10, one lock section: the match and the filing are one hold of the release lock, so whatever lands as the filing takes
  // its lock is seen by the match. The rows land a row through the signing-lock hook, which runs as a lock is taken.
  const opensOf = <T>(call: () => T, landOn?: number, land?: () => void): { got: T; opens: number; landed: boolean } => {
    let opens = 0;
    let landed = false;
    const hook = () => {
      opens += 1;
      signingLock.fn = hook;
      if (opens === landOn) {
        landed = true;
        land?.();
      }
    };
    signingLock.fn = hook;
    try {
      return { got: call(), opens, landed };
    } finally {
      signingLock.fn = null;
    }
  };
  // K-5 and K-7 each hold a covering record; K-7 is asked first, only to learn how many holds one covered ask takes, so a row lands
  // as the LAST of them takes the lock (the filing's) whatever that number is.
  const twoCovered = async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-7'], ADD_V1);
    return rec;
  };
  const filingOpen = () => opensOf(() => requestOnRecord(at(), ask({ key: 'K-7' }))).opens;
  const SHA9 = () => createHash('sha256').update(FILE).digest('hex');
  const REVERSAL = { id: 'O-R1-landed', kind: 'decision', decision: '120', keys: ['K-5'], op: 'remove', from_v: 'v1', to_v: null, verbatim: 'legacy, no words' };
  const landed = (fields: Record<string, unknown>) => () => { forge(fields, at()); };
  const k5 = () => queue().filter((q) => q.key === 'K-5');

  it('way 10 (one lock section): a decision that reverses the covering record lands as the filing takes its lock: nothing is filed on the reversed record', async () => {
    await twoCovered();
    const { got, landed: fired } = opensOf(() => requestOnRecord(at(), ask()), filingOpen(), landed(REVERSAL));
    expect(fired).toBe(true);
    expect(lines(operatorFile()).map((l) => (JSON.parse(l) as OperatorRow).id)).toContain('O-R1-landed');
    expect(got).toBeUndefined();
    expect(k5()).toEqual([]);
  });

  it('way 10 (one lock section): with no decision in between, the request is filed citing the record, as before', async () => {
    const rec = await twoCovered();
    const { got } = opensOf(() => requestOnRecord(at(), ask()));
    expect(got?.operator.id).toBe(rec.id);
    expect(got?.request.evidence).toEqual({ operator: rec.id });
    expect(k5()).toHaveLength(1);
  });

  it('way 10 (one lock section): a covered ask takes the release lock once, and so does an ask no record covers', async () => {
    await twoCovered();
    expect(opensOf(() => requestOnRecord(at(), ask())).opens).toBe(1);
    expect(opensOf(() => requestOnRecord(at(), ask({ key: 'K-9' }))).opens).toBe(1);
  });

  it('way 10 (one lock section): request() files under the release lock: an identical ask a second writer lands as the lock is taken is returned, not duplicated', async () => {
    await setup();
    const rival = { req: 'Q-R1-9001', from: 'console', verb: 'INTAKE', key: 'K-5', from_v: null, to_v: 'v1', why: 'the same ask, filed by a second writer', evidence: {}, state: 'open' };
    const land = () => { appendChain(join(root, 'release', 'R1', 'requests.jsonl'), loadKey(join(root, 'keys', 'R1.key')), { ts: at().now().toISOString(), ...rival }); };
    const { got, landed: fired } = opensOf(() => request(at(), ask()), 1, land);
    expect(fired).toBe(true);
    expect(got.req).toBe('Q-R1-9001');
    expect(queue().filter((q) => q.key === 'K-5')).toHaveLength(1);
  });

  // review 2 F2: the filing's own unchanged-refusal check reads the state under the lock. The refused ask below carries the evidence the
  // new request will carry (operator: the id of the record that lands), so a stale reading would hand back the refused request.
  it('way 10 (one lock section): a record that lands as the lock is taken ends the standing refusal for the filing too: a new request is filed, not the refused one returned', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    const refusedAsk = request(at(), ask({ evidence: { operator: 'O-R1-landed' } }));
    claim(at(rmEnv));
    const r = rule(at(rmEnv), {
      req: refusedAsk.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'no operator words',
      reason: 'name the words', supersedes: [], authority: { kind: 'rm', ref: null },
    });
    await apply(at(rmEnv), r.id);
    expect(state(ctx()).refused_asks.map((a) => a.key)).toEqual(['K-5']);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    const record = { id: 'O-R1-landed', kind: 'decision', decision: '9', keys: ['K-5'], op: 'add', from_v: null, to_v: 'v1', verbatim: OTHER_WORDS, decision_file: 'specs/decisions/verbatim-decision-9-op.txt', decision_sha256: SHA9(), words: 1 };
    const { got, landed: fired } = opensOf(() => requestOnRecord(at(), ask()), 1, landed(record));
    expect(fired).toBe(true);
    expect(got?.operator.id).toBe('O-R1-landed');
    expect(got?.request.req).not.toBe(refusedAsk.req);
    expect(got?.request.state).toBe('open');
  });

  it('way 10 (one lock section): the release lock is not re-entrant, so the filing must run under the hold the match has', async () => {
    await setup();
    expect(() => withLock(ctx().dir, () => withLock(ctx().dir, () => 1, 100, 60_000), 100, 60_000)).toThrow(/is held; retry/);
  });

  it('way 5 (one lock section): a ruling on the key that lands as the filing takes its lock floors the record: nothing is filed', async () => {
    await twoCovered();
    const ruling = {
      id: 'R-R1-landed', epoch: 1, req: 'Q-R1-landed', verb: 'INTAKE', key: 'K-5', op: { kind: 'none', from_v: null, to_v: null }, outcome: 'BACKLOG',
      class: 'none', sector: 'Planning & tracking', ground: 'no operator words', reason: 'landed', supersedes: [], authority: { kind: 'rm', ref: null }, phase: 'intent',
    };
    const land = () => { appendChain(join(root, 'release', 'R1', 'rulings.jsonl'), loadKey(join(root, 'keys', 'R1.key')), { ts: at().now().toISOString(), ...ruling }); };
    const { got, landed: fired } = opensOf(() => requestOnRecord(at(), ask()), filingOpen(), land);
    expect(fired).toBe(true);
    expect(lines(join(root, 'release', 'R1', 'rulings.jsonl')).map((l) => (JSON.parse(l) as RulingRow).id)).toContain('R-R1-landed');
    expect(got).toBeUndefined();
    expect(k5()).toEqual([]);
  });

  it('way 6 (one lock section): a newer covering decision that lands as the filing takes its lock is the record cited, not the older one', async () => {
    const older = await twoCovered();
    const newer = {
      id: 'O-R1-landed2', kind: 'decision', decision: '9', keys: ['K-5'], op: 'add', from_v: null, to_v: 'v1', verbatim: OTHER_WORDS,
      decision_file: 'specs/decisions/verbatim-decision-9-op.txt', decision_sha256: SHA9(), words: 1,
    };
    const { got, landed: fired } = opensOf(() => requestOnRecord(at(), ask()), filingOpen(), landed(newer));
    expect(fired).toBe(true);
    expect(got?.operator.id).toBe('O-R1-landed2');
    expect(got?.operator.id).not.toBe(older.id);
    expect(got?.request.evidence).toEqual({ operator: 'O-R1-landed2' });
  });

  it('way 7 (one lock section): a row that does not verify landing as the filing takes its lock makes the chain unreadable: nothing is filed', async () => {
    await twoCovered();
    const land = () => {
      forge(REVERSAL, at());
      tamper(-1, (row) => { row.mac = flip(row.mac); });
    };
    const { got, landed: fired } = opensOf(() => requestOnRecord(at(), ask()), filingOpen(), land);
    expect(fired).toBe(true);
    expect(got).toBeUndefined();
    expect(k5()).toEqual([]);
    expect(chainFault(ctx())).toMatch(/^the operator chain of R1 could not be verified to its end/);
  });

  it('way 7: a words row whose signature does not verify is never cited', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    tamper(-1, (row) => { row.mac = flip(row.mac); });
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it('way 7: a row edited after signing to name the key is never cited', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-6'], ADD_V1);
    tamper(-1, (row) => { row.keys = ['K-5']; });
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  it('way 7: a valid record that follows a row that does not verify is unverified with it', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-6'], ADD_V1);
    words(at(), ['K-5'], ADD_V1, OTHER_WORDS);
    tamper(-2, (row) => { row.mac = flip(row.mac); });
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  // way 7, review F4: a row after the verified prefix is invisible, so the new path fails closed and names the fault
  it('way 7: a newer remove whose signature does not verify hides itself, so the older add is not cited and the chain fault is named', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-5'], ['remove', 'v1', null], OTHER_WORDS);
    tamper(-1, (row) => { row.mac = flip(row.mac); });
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
    expect(chainFault(ctx())).toMatch(/^the operator chain of R1 could not be verified to its end \(line \d+ \(O-R1-\d{4}\): bad signature\)$/);
  });

  it('way 7: a ruling row that does not verify hides a newer refusal, so the older record is not cited and the fault names the rulings chain', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    await refuse('K-5');
    words(at(), ['K-5'], ADD_V1);
    const again = request(at(), ask({ why: 'asked again after the operator\'s words' }));
    claim(at(rmEnv));
    rule(at(rmEnv), {
      req: again.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'no operator words',
      reason: 'refused again', supersedes: [], authority: { kind: 'rm', ref: null },
    });
    const rulings = join(root, 'release', 'R1', 'rulings.jsonl');
    const rows = lines(rulings);
    const last = JSON.parse(rows.at(-1) as string) as Record<string, unknown>;
    last.mac = flip(last.mac);
    rows[rows.length - 1] = JSON.stringify(last);
    writeFileSync(rulings, `${rows.join('\n')}\n`);
    const before = queue().length;
    expect(requestOnRecord(at(), ask({ why: 'a third ask' }))).toBeUndefined();
    expect(queue()).toHaveLength(before);
    expect(chainFault(ctx())).toMatch(/^the rulings chain of R1 could not be verified to its end \(line \d+/);
  });

  it('way 7: a chain that verifies to its end, and a release that is not declared, have no fault', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    expect(chainFault(ctx())).toBeUndefined();
    expect(chainFault({ ...ctx(), release: 'R9', dir: join(root, 'release', 'R9'), keyPath: join(root, 'keys', 'R9.key') })).toBeUndefined();
  });

  it('way 8: a row that covers several keys is cited for each of them and for no other', async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5', 'K-6', 'K-7'], ADD_V1);
    expect(requestOnRecord(at(), ask({ key: 'K-5' }))?.request.evidence).toEqual({ operator: rec.id });
    expect(requestOnRecord(at(), ask({ key: 'K-7' }))?.request.evidence).toEqual({ operator: rec.id });
    expect(requestOnRecord(at(), ask({ key: 'K-8' }))).toBeUndefined();
    expect(queue().map((q) => q.key)).toEqual(['K-5', 'K-7']);
  });

  // review F3: behaviours the first rows left unpinned
  it('way 2: a newer words record of ANOTHER key on the same version does not hide this key\'s record', async () => {
    await setup();
    decisionFile();
    const mine = words(at(), ['K-5'], ADD_V1);
    words(at(), ['K-6'], ADD_V1, OTHER_WORDS);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(mine.id);
  });

  it('way 5: a refusal ruled but not yet applied (intent only) floors the older record', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    const q = request(at(), ask({ to_v: 'v2', why: 'an earlier ask of the same key' }));
    claim(at(rmEnv));
    rule(at(rmEnv), {
      req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'no operator words',
      reason: 'name the words', supersedes: [], authority: { kind: 'rm', ref: null },
    });
    expect(lines(join(root, 'release', 'R1', 'rulings.jsonl')).map((l) => (JSON.parse(l) as RulingRow).phase)).toEqual(['intent']);
    const before = queue().length;
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toHaveLength(before);
  });

  it('way 5: a refusal applied but not yet receipted floors the older record', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    words(at(), ['K-5'], ADD_V1);
    const q = request(at(), ask({ to_v: 'v2', why: 'an earlier ask of the same key' }));
    claim(at(rmEnv));
    const r = rule(at(rmEnv), {
      req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'no operator words',
      reason: 'name the words', supersedes: [], authority: { kind: 'rm', ref: null },
    });
    const post = jira.addComment.bind(jira);
    jira.addComment = async () => { throw new Error('jira down before the receipt'); };
    await expect(apply(at(rmEnv), r.id)).rejects.toThrow('jira down');
    jira.addComment = post;
    expect(lines(join(root, 'release', 'R1', 'rulings.jsonl')).map((l) => (JSON.parse(l) as RulingRow).phase).at(-1)).toBe('applied');
    expect(requestOnRecord(at(), ask())).toBeUndefined();
  });

  it('only INTAKE and REVERSION are placed by a record: a DISCHARGE that carries a target version and a move record is not', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ['move', 'v2', 'v1']);
    expect(coveringRecord(at(), ask({ verb: 'DISCHARGE', from_v: 'v2', to_v: 'v1' }))).toBeUndefined();
    expect(requestOnRecord(at(), ask({ verb: 'DISCHARGE', from_v: 'v2', to_v: 'v1' }))).toBeUndefined();
    expect(queue()).toEqual([]);
  });

  it.each([
    ['the release manager', { HIMMEL_RELEASE_MANAGER: '1' }, /chief-spawned worker/],
    ['a console leg or worker', { HIMMEL_CONSOLE_LEG: '1' }, /chief-spawned worker/],
    ['a bridge session', { HIMMEL_BRIDGE_SESSION: '1' }, /Telegram bridge session/],
  ])('way 9: %s cannot file a request on a record', async (_name, env, message) => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    expect(() => requestOnRecord(at(env), ask())).toThrow(message);
    expect(queue()).toEqual([]);
  });

  it('way 9: a process with a bridge session in its ancestry cannot file a request on a record', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    expect(() => requestOnRecord({ ...ctx(), ...fakeProc({ HIMMEL_BRIDGE_SESSION: '1' }) }, ask())).toThrow(/Telegram bridge session.*ancestor 200/);
    expect(queue()).toEqual([]);
    expect(requestOnRecord({ ...ctx(), ...fakeProc() }, ask())).toBeDefined();
  });

  it('way 9: the release manager still cannot file even a plain request', async () => {
    await setup();
    expect(() => request(ctx(rmEnv), ask())).toThrow(/the chief writes requests/);
  });

  it('way 10: citing an existing record does not run the withdrawal a NEW record runs: a pending ask for another placement stays open', async () => {
    await setup();
    decisionFile();
    const rec = words(at(), ['K-5'], ADD_V1);
    const other = request(at(), ask({ verb: 'REVERSION', from_v: 'v1', to_v: 'v2', why: 'the chief moved it by mistake' }));
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(rec.id);
    expect(queue().filter((q) => q.req === other.req).map((q) => q.state)).toEqual(['open']);
    words(at(), ['K-5'], ADD_V1, OTHER_WORDS);
    expect(queue().filter((q) => q.req === other.req).map((q) => q.state)).toEqual(['open', expect.stringMatching(/^withdrawn:/)]);
  });

  it('way 10: a pending ask that cites nothing is returned as it stands by the plain dedupe: no second request, no citation added', async () => {
    await setup();
    decisionFile();
    words(at(), ['K-5'], ADD_V1);
    const plain = request(at(), ask());
    const got = requestOnRecord(at(), ask());
    expect(got?.request.req).toBe(plain.req);
    expect(got?.request.evidence).toEqual({});
    expect(queue()).toHaveLength(1);
  });

  it('way 11: a refused ask the state lists is never covered by a record, so its remedy (record the words) is the only accepted path', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] }, { key: 'K-6', labels: ['operator-directed'] });
    words(at(), ['K-5'], ADD_V1);
    await refuse('K-5');
    await refuse('K-6');
    words(at(), ['K-6'], ['add', null, 'v2'], OTHER_WORDS);
    const listed = state(ctx()).refused_asks;
    expect(listed.map((a) => a.key)).toEqual(['K-5']);
    for (const a of listed) {
      expect(a.remedy).toContain('--decision <n> --words');
      expect(coveringRecord(at(), ask({ key: a.key }))).toBeUndefined();
    }
  });

  it('way 11: a key leaves refused_asks only when a record names it, and the record it needs is the one this path cites', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    await refuse('K-5');
    expect(state(ctx()).refused_asks.map((a) => a.key)).toEqual(['K-5']);
    expect(coveringRecord(at(), ask())).toBeUndefined();
    const rec = words(at(), ['K-5'], ADD_V1);
    expect(state(ctx()).refused_asks).toEqual([]);
    expect(coveringRecord(at(), ask())?.id).toBe(rec.id);
  });

  it('way 12: a record of another release is never cited', async () => {
    await setup();
    decisionFile();
    const c2: Ctx = { ...ctx(), release: 'R2', dir: join(root, 'release', 'R2'), keyPath: join(root, 'keys', 'R2.key') };
    declare(c2, { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    const rec = words({ ...c2, now: () => new Date('2026-10-21T10:30:00.000Z') }, ['K-5'], ADD_V1);
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    expect(queue()).toEqual([]);
    expect(coveringRecord(c2, ask())?.id).toBe(rec.id);
  });

  it('way 12: a record from before a ruling of a closed lease epoch is not cited in the next epoch either', async () => {
    await setup();
    decisionFile();
    mirrorOf({ key: 'K-5', labels: ['operator-directed'] });
    words(at(), ['K-5'], ADD_V1);
    await refuse('K-5');
    leaseRelease(at(rmEnv));
    leaseAcquire(at(rmEnv), { expectEpoch: 1, doc: DOC, session: 'rm-2' });
    expect(requestOnRecord(at(), ask())).toBeUndefined();
    const fresh = words(at(), ['K-5'], ADD_V1, OTHER_WORDS);
    expect(requestOnRecord(at(), ask())?.operator.id).toBe(fresh.id);
  });
});

describe('a ruled-away operator ask wakes the chief', () => {
  const GOLDEN = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'fixtures', 'state-golden.json');
  const WORDS = 'Approved one more round';
  let clock = 0;
  // Each write lands a minute after the last, so "after the ruling" is a real order.
  const at = (env: Record<string, string> = consoleEnv): Ctx => {
    clock += 60_000;
    const d = new Date(Date.parse('2026-10-21T10:00:00.000Z') + clock);
    return { ...ctx(env), now: () => d };
  };
  beforeEach(() => { clock = 0; });
  const ruleOn = async (key: string, verb: 'INTAKE' | 'REVERSION', from_v: string | null, to_v: string | null, outcome: string,
    op: { kind: 'none' | 'keep'; from_v: string | null; to_v: string | null }) => {
    const q = request(at(), { verb, key, from_v, to_v, why: 'w', evidence: {}, from: 'console' });
    claim(at(rmEnv));
    const r = rule(at(rmEnv), {
      req: q.req, outcome, op, sector: 'Planning & tracking', ground: 'no operator words', reason: `name the operator's words for ${key}`,
      supersedes: [], authority: { kind: 'rm', ref: null },
    });
    await apply(at(rmEnv), r.id);
    return r;
  };
  const refuseIntake = (key: string) => ruleOn(key, 'INTAKE', null, 'v1', 'BACKLOG', { kind: 'none', from_v: null, to_v: null });
  const decisionFile = () => {
    const dir = join(root, 'specs', 'decisions');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'verbatim-decision-9-op.txt'), `Operator, verbatim:\n\n"${WORDS}"\n\nAnswering the ask on HIMMEL-1: stop and park.\n`);
  };

  it('a BACKLOG ruling of a backlog-to-version request is a refused ask', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-5', fixVersions: [], labels: ['operator-directed'] }, { key: 'K-6', fixVersions: [] }]);
    const r5 = await refuseIntake('K-5');
    const r6 = await refuseIntake('K-6');
    expect(state(ctx()).refused_asks).toEqual([
      { key: 'K-5', ruling: r5.id, req: r5.req, reason: "name the operator's words for K-5", ground: 'no operator words', remedy: expect.stringContaining('--decision <n> --words'), asks_operator: true },
      { key: 'K-6', ruling: r6.id, req: r6.req, reason: "name the operator's words for K-6", ground: 'no operator words', remedy: expect.stringContaining('jira release ack R1 --ruling '), asks_operator: false },
    ]);
  });

  it('KEEP on a backlog-to-version REVERSION counts, a demotion never does', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-7', fixVersions: [] }, { key: 'K-8', fixVersions: ['v1'] }, { key: 'K-9', fixVersions: [] }]);
    jira.fv.set('K-7', ['v2']);
    jira.fv.set('K-8', ['v1']);
    const r7 = await ruleOn('K-7', 'REVERSION', null, 'v1', 'KEEP', { kind: 'keep', from_v: 'v2', to_v: 'v2' });
    await ruleOn('K-8', 'REVERSION', 'v1', null, 'KEEP', { kind: 'keep', from_v: 'v1', to_v: 'v1' });
    await ruleOn('K-9', 'INTAKE', null, null, 'BACKLOG', { kind: 'none', from_v: null, to_v: null });
    expect(state(ctx()).refused_asks.map((x) => `${x.key}@${x.ruling}`)).toEqual([`K-7@${r7.id}`]);
  });

  it('a newer request, a later O- row naming the key, Done, or an ack each ends it', async () => {
    await setup();
    const keys = ['K-10', 'K-11', 'K-12', 'K-13', 'K-14'];
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, ...keys.map((key) => ({ key, fixVersions: [] }))]);
    const rulings = new Map<string, RulingRow>();
    for (const k of keys) rulings.set(k, await refuseIntake(k));
    request(at(), { verb: 'INTAKE', key: 'K-10', from_v: null, to_v: 'v2', why: 'asked again', evidence: {}, from: 'console' });
    operatorDecision(at(), { decision: '120', keys: ['K-11'], op: 'add', from_v: null, to_v: 'v2', verbatim: 'x' });
    const acked = ack(at(), { ruling: rulings.get('K-13')?.id ?? '', reason: 'the refusal is right: a duplicate' });
    expect(acked).toMatchObject({ kind: 'ack', key: 'K-13', ruling: rulings.get('K-13')?.id, reason: 'the refusal is right: a duplicate' });
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, ...keys.map((key) => ({ key, fixVersions: [], ...(key === 'K-12' ? { status: 'Done', category: 'Done' } : {}) }))],
      '2026-10-21T12:00:00.000Z');
    expect(state(ctx()).refused_asks.map((x) => x.key)).toEqual(['K-14']);
  });

  it('ack is refused for an asks_operator key', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-5', fixVersions: [], priority: 'High' }]);
    const r = await refuseIntake('K-5');
    expect(() => ack(at(), { ruling: r.id, reason: 'right' })).toThrow(/K-5 is operator-asked/);
    expect(state(ctx()).refused_asks.map((x) => x.key)).toEqual(['K-5']);
  });

  it('an unreadable mirror leaves asks_operator unknown, never false', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-5', fixVersions: [], labels: ['operator-directed'] }]);
    const r = await refuseIntake('K-5');
    writeFileSync(join(root, 'mirror', '.cursor.json'), JSON.stringify({ lastSync: '2026-10-21T09:00:00.000Z', complete: false }));
    const s = state(ctx());
    expect(s.inputs.mirror).toBe('UNKNOWN');
    expect(s.refused_asks).toEqual([{ key: 'K-5', ruling: r.id, req: r.req, reason: "name the operator's words for K-5", ground: 'no operator words', remedy: expect.stringContaining('--decision <n> --words'), asks_operator: null }]);
  });

  it('a key the mirror does not hold is unknown, not a non-operator ask', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    await refuseIntake('K-6');
    expect(state(ctx()).refused_asks.map((x) => x.asks_operator)).toEqual([null]);
  });

  it('ack refuses a key the mirror does not hold', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }]);
    const r = await refuseIntake('K-6');
    expect(() => ack(at(), { ruling: r.id, reason: 'right' })).toThrow(/K-6 is not in the Jira mirror/);
  });

  it('ack refuses inside a chief-spawned worker', async () => {
    await setup();
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }]);
    const r = await refuseIntake('K-6');
    expect(() => ack(at({ HIMMEL_CONSOLE_LEG: '1' }), { ruling: r.id, reason: 'right' })).toThrow(/chief-spawned worker/);
  });

  it('words_records lists only verified words:1 rows', async () => {
    await setup();
    decisionFile();
    const words = recordRequestDecision(ctx(), { decision: '9', words: WORDS, key: 'ABC-1', verb: 'INTAKE', from_v: null, to_v: 'v1' });
    operatorDecision(ctx(), { decision: '120', keys: ['ABC-2'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'legacy, no words' });
    expect(state(ctx()).words_records).toEqual([{ id: words.id, decision: '9', keys: ['ABC-1'], op: 'add', verbatim: WORDS }]);
  });

  it('asks_operator_keys lists open labelled or High keys', async () => {
    await setup();
    mirror([
      { key: 'K-1', fixVersions: ['v1'] }, { key: 'K-20', fixVersions: [], labels: ['operator-directed'] }, { key: 'K-21', fixVersions: [], priority: 'High' },
      { key: 'K-22', fixVersions: [], priority: 'Highest', status: 'Done', category: 'Done' }, { key: 'K-23', fixVersions: [] },
    ]);
    expect(state(ctx()).asks_operator_keys).toEqual(['K-20', 'K-21']);
  });

  it('an unknown state serializes the three fields empty', () => {
    expect(state(ctx())).toMatchObject({ status: 'UNKNOWN', refused_asks: [], words_records: [], asks_operator_keys: [] });
  });

  describe('8674 refused asks name their remedy and an unchanged ask is not requeued', () => {
    const ask = (key: string, o: { why?: string; evidence?: Record<string, unknown>; to?: string } = {}) =>
      request(at(), { verb: 'INTAKE', key, from_v: null, to_v: o.to ?? 'v1', why: o.why ?? 'w', evidence: o.evidence ?? {}, from: 'console' });
    const refuseAsk = async (key: string, o: Parameters<typeof ask>[1] = {}) => {
      const q = ask(key, o);
      claim(at(rmEnv));
      const r = rule(at(rmEnv), {
        req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'defer',
        reason: `no operator record names ${key}`, supersedes: [], authority: { kind: 'rm', ref: null },
      });
      await apply(at(rmEnv), r.id);
      return { q, r };
    };
    const reqCount = () => readChain<RequestRow>(join(ctx().dir, 'requests.jsonl'), loadKey(ctx().keyPath)).verified.length;

    it('names the ground and the exact remedy for an operator-asked key, an ordinary key and an unknown key', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-5', fixVersions: [], priority: 'High' }, { key: 'K-6', fixVersions: [] }]);
      const a = await refuseAsk('K-5');
      const b = await refuseAsk('K-6');
      const c = await refuseAsk('K-7');
      const got = Object.fromEntries(state(ctx()).refused_asks.map((x) => [x.key, x]));
      expect(got['K-5']).toMatchObject({ ground: 'defer', ruling: a.r.id });
      expect(got['K-5'].remedy).toBe('jira release request R1 --verb INTAKE --key K-5 --from backlog --to v1 --why "<why>" --decision <n> --words "<the operator\'s exact words>"');
      expect(got['K-6'].remedy).toBe(`new facts: jira release request R1 --verb INTAKE --key K-6 --from backlog --to v1 --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or if the refusal is right: jira release ack R1 --ruling ${b.r.id} --reason "<why>"`);
      expect(got['K-7'].remedy).toBe(got['K-5'].remedy.replace('K-5', 'K-7'));
      expect(got['K-7'], 'the unknown key\'s notice carries its own ruling and an unknown operator status').toMatchObject({ ruling: c.r.id, req: c.q.req, asks_operator: null });
    });

    it('an identical re-request of an open refused ask returns the refused request and files no new Q', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }]);
      const { q } = await refuseAsk('K-6', { evidence: { follow_up_of: 'K-1' } });
      const before = reqCount();
      expect(request(at(), { verb: 'INTAKE', key: 'K-6', from_v: null, to_v: 'v1', why: 'w', evidence: { follow_up_of: 'K-1' }, from: 'console' }).req).toBe(q.req);
      expect(reqCount()).toBe(before);
      expect(state(ctx()).requests.open).toEqual([]);
    });

    it.each([
      ['changed evidence', (r: { why: string; evidence: Record<string, unknown> }) => ({ ...r, evidence: { ...r.evidence, remainder: true } })],
      ['a different why', (r: { why: string; evidence: Record<string, unknown> }) => ({ ...r, why: 'new facts: it blocks K-1' })],
    ])('%s reopens reconsideration with a new Q', async (_n, change) => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }]);
      const { q } = await refuseAsk('K-6', { evidence: { follow_up_of: 'K-1' } });
      const next = request(at(), { verb: 'INTAKE', key: 'K-6', from_v: null, to_v: 'v1', ...change({ why: 'w', evidence: { follow_up_of: 'K-1' } }), from: 'console' });
      expect(next.req).not.toBe(q.req);
    });

    it('a newer operator row, an ack, or Done reopens it too', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }, { key: 'K-8', fixVersions: [] }]);
      const six = await refuseAsk('K-6');
      const eight = await refuseAsk('K-8');
      operatorDecision(at(), { decision: '120', keys: ['K-6'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
      expect(ask('K-6').req).not.toBe(six.q.req);
      ack(at(), { ruling: eight.r.id, reason: 'the refusal is right: a duplicate' });
      expect(ask('K-8').req).not.toBe(eight.q.req);
    });

    // 8674 U3 (review F4): a later ask that was withdrawn is not an ask that stands, so it must not hide the refusal.
    it('U3: a later ask that was withdrawn leaves the standing refusal listed; a live later ask still ends it', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }, { key: 'K-8', fixVersions: [] }, { key: 'K-9', fixVersions: [] }]);
      const six = await refuseAsk('K-6');
      await refuseAsk('K-8');
      await refuseAsk('K-9');
      const mistaken = ask('K-6', { to: 'v2' });
      expect(state(ctx()).refused_asks.map((a) => a.key)).toEqual(['K-8', 'K-9']);
      withdraw(at(), { req: mistaken.req, reason: 'filed by mistake' });
      // a later ask the RM has claimed still stands, so it still hides the refusal; so does one still open
      ask('K-9', { to: 'v2' });
      claim(at(rmEnv));
      ask('K-8', { to: 'v2' });
      const got = state(ctx()).refused_asks;
      expect(got.map((a) => a.key)).toEqual(['K-6']);
      expect(got[0]).toMatchObject({ ruling: six.r.id, req: six.q.req });
      // the identical ask still files nothing while the refusal stands
      const before = reqCount();
      expect(ask('K-6').req).toBe(six.q.req);
      expect(reqCount()).toBe(before);
    });

    it('the first ask of a key and an ask for another version are never blocked', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }]);
      const { q } = await refuseAsk('K-6');
      expect(ask('K-6', { to: 'v2' }).req).not.toBe(q.req);
      expect(ask('K-9').req).toMatch(/^Q-R1-/);
    });
  });

  // The required-parent remainder: evidence recorded at intake is read back, never promoted to a placement.
  describe('required parent remainder conflicts', () => {
    const REQ_EVIDENCE = { follow_up_of: 'P-1', parent_status: 'In Progress', parent_version: 'v1', remainder: true };
    const refuseWith = async (key: string, evidence: Record<string, unknown>) => {
      const q = request(at(), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'follow-up of P-1 (In Progress), which is in v1', evidence, from: 'console' });
      claim(at(rmEnv));
      const r = rule(at(rmEnv), {
        req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'defer',
        reason: `no operator record names ${key}`, supersedes: [], authority: { kind: 'rm', ref: null },
      });
      await apply(at(rmEnv), r.id);
      return { q, r };
    };

    it('lists a required out-of-version child of an open current parent with its owner and next action, and writes nothing', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const { q, r } = await refuseWith('C-1', REQ_EVIDENCE);
      const writes = jira.writes;
      const s = state(ctx());
      expect(s.remainder_conflicts).toEqual([{
        parent: 'P-1', child: 'C-1', req: q.req, ruling: r.id, phase: 'refused', owner: 'chief', unknown: null,
        next: `new facts: jira release request R1 --verb INTAKE --key C-1 --from backlog --to v1 --required-by P-1 --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or, if P-1 can close without C-1, file the ask again without --required-by`,
      }]);
      expect(s.refused_asks.map((a) => a.key)).toEqual(['C-1']);
      expect(jira.writes).toBe(writes);
      expect(s.requests.open).toEqual([]);
    });

    it('optional hardening (no remainder flag), a Done parent, and an already-placed child are not conflicts', async () => {
      await setup();
      mirror([
        { key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'P-2', fixVersions: ['v1'], status: 'Done', category: 'Done' },
        { key: 'C-1', fixVersions: [] }, { key: 'C-2', fixVersions: [] }, { key: 'C-3', fixVersions: ['v1'] },
      ]);
      await refuseWith('C-1', { follow_up_of: 'P-1', remainder: false });
      await refuseWith('C-2', { follow_up_of: 'P-2', remainder: true });
      await refuseWith('C-3', REQ_EVIDENCE);
      expect(state(ctx()).remainder_conflicts).toEqual([]);
    });

    it('an open request awaiting the RM names rm-run as the next action', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const q = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: REQ_EVIDENCE, from: 'console' });
      expect(state(ctx()).remainder_conflicts).toEqual([{ parent: 'P-1', child: 'C-1', req: q.req, ruling: null, phase: 'open', owner: 'release-manager', next: 'jira release rm-run R1', unknown: null }]);
    });

    // The effective relation is the child's newest live INTAKE evidence, never an older request's.
    const conflictsOf = () => state(ctx()).remainder_conflicts.map((c) => `${c.parent}>${c.child}:${c.phase}`);

    it('A2: --required-by on an already-open request updates its evidence by a signed append of the same request, once', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const first = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      expect(conflictsOf()).toEqual([]);
      const rel = { follow_up_of: 'P-1', remainder: true };
      const second = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: rel, from: 'console' });
      expect(second.req).toBe(first.req);
      expect(second.evidence).toEqual(rel);
      expect(conflictsOf()).toEqual(['P-1>C-1:open']);
      const rows = () => readChain<RequestRow>(join(ctx().dir, 'requests.jsonl'), loadKey(ctx().keyPath)).verified.length;
      const n = rows();
      expect(request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: rel, from: 'console' }).req).toBe(first.req);
      expect(rows()).toBe(n);
    });

    it('A2: a claimed request keeps its claim and epoch when the relation is added or the parent changes', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'P-2', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const q = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
      const [claimed] = claim(at(rmEnv));
      const stored = () => readChain<RequestRow>(join(ctx().dir, 'requests.jsonl'), loadKey(ctx().keyPath)).verified.filter((r) => r.key === 'C-1').at(-1);
      const got = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: { follow_up_of: 'P-1', remainder: true }, from: 'console' });
      expect(got.req).toBe(q.req);
      expect(got.state).toBe(claimed.state);
      expect(stored()).toMatchObject({ req: q.req, state: claimed.state });
      expect(conflictsOf()).toEqual(['P-1>C-1:claimed']);
      const moved = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: { follow_up_of: 'P-2', remainder: true }, from: 'console' });
      expect(moved).toMatchObject({ req: q.req, state: claimed.state });
      expect(stored(), 'the parent change keeps the same request and the exact claim').toMatchObject({ req: q.req, state: claimed.state });
      expect(conflictsOf()).toEqual(['P-2>C-1:claimed']);
    });

    it('A3: a later request that drops the relation, or names another parent, leaves no obsolete conflict', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'P-2', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      await refuseWith('C-1', REQ_EVIDENCE);
      expect(conflictsOf()).toEqual(['P-1>C-1:refused']);
      const q2 = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'the remainder moved to P-2', evidence: { follow_up_of: 'P-2', remainder: true }, from: 'console' });
      expect(conflictsOf()).toEqual(['P-2>C-1:open']);
      claim(at(rmEnv));
      const r2 = rule(at(rmEnv), { req: q2.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'defer', reason: 'still no record', supersedes: [], authority: { kind: 'rm', ref: null } });
      expect(conflictsOf()).toEqual(['P-2>C-1:ruled']);
      await apply(at(rmEnv), r2.id);
      expect(conflictsOf()).toEqual(['P-2>C-1:refused']);
      request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'optional hardening only', evidence: {}, from: 'console' });
      expect(conflictsOf()).toEqual([]);
    });

    it('A3: a withdrawn newest request does not erase the relation of the one before it; Done and terminal parents still end it', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      await refuseWith('C-1', REQ_EVIDENCE);
      const q2 = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'a plain re-ask', evidence: {}, from: 'console' });
      expect(conflictsOf()).toEqual([]);
      withdraw(at(), { req: q2.req, reason: 'filed by mistake' });
      expect(conflictsOf()).toEqual(['P-1>C-1:refused']);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'], status: 'Done', category: 'Done' }, { key: 'C-1', fixVersions: [] }]);
      expect(conflictsOf()).toEqual([]);
      for (const status of ["Won't Do", 'Duplicate']) {
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'], status }, { key: 'C-1', fixVersions: [] }]);
        expect(conflictsOf(), `a ${status} parent`).toEqual([]);
      }
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'], status: 'Done', category: 'Done', resolution: 'Obsolete' }, { key: 'C-1', fixVersions: [] }]);
      expect(conflictsOf(), 'a Done parent resolved Obsolete (terminal, not delivered)').toEqual([]);
    });

    it('A4: an ack of the refusal ends the notice, not the contradiction: the child stays chief-owned with a refile remedy, never rm-run', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const { r } = await refuseWith('C-1', REQ_EVIDENCE);
      ack(at(), { ruling: r.id, reason: 'the refusal is right for now' });
      const s = state(ctx());
      expect(s.refused_asks).toEqual([]);
      expect(s.requests.open).toEqual([]);
      const [c] = s.remainder_conflicts;
      expect(c).toMatchObject({ parent: 'P-1', child: 'C-1', phase: 'refused', owner: 'chief', ruling: r.id });
      expect(c.next).not.toContain('rm-run');
      expect(c.next).toContain('jira release request R1 --verb INTAKE --key C-1 --from backlog --to v1 --required-by P-1 --why "<what changed>"');
    });

    it('A4: a refused move from another version (not a backlog ask) is chief-owned too, and a receipted ADMIT whose child the mirror still shows outside is chief-owned with a mirror remedy', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-2', fixVersions: ['v2'] }, { key: 'C-3', fixVersions: [] }]);
      const q = request(at(), { verb: 'INTAKE', key: 'C-2', from_v: 'v2', to_v: 'v1', why: 'w', evidence: REQ_EVIDENCE, from: 'console' });
      claim(at(rmEnv));
      const r2 = rule(at(rmEnv), { req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'defer', reason: 'no record', supersedes: [], authority: { kind: 'rm', ref: null } });
      await apply(at(rmEnv), r2.id);
      const q3 = request(at(), { verb: 'INTAKE', key: 'C-3', from_v: null, to_v: 'v1', why: 'w', evidence: REQ_EVIDENCE, from: 'console' });
      claim(at(rmEnv));
      const r3 = admit(q3.req, {});
      await apply(at(rmEnv), r3.id);
      const byChild = Object.fromEntries(state(ctx()).remainder_conflicts.map((c) => [c.child, c]));
      expect(byChild['C-2']).toMatchObject({ phase: 'refused', owner: 'chief' });
      expect(byChild['C-2'].next).not.toContain('rm-run');
      expect(byChild['C-3']).toMatchObject({ phase: 'ruled', owner: 'chief' });
      expect(byChild['C-3'].next).toContain('jira mirror');
      expect(byChild['C-3'].next).not.toContain('rm-run');
    });

    // Offline seed from the recorded relations of the 2026-11-16 RM placement audit (9953 required by 9914, 9932 by 9915). The raw ledger and
    // mirror of that day are not retained, so the membership snapshot is the audit's stated one, not a replay of the live ledgers.
    it('seed 9953>9914 and 9932>9915: requests filed without the relation take it once, surface as conflicts, and clear only when the children are placed', async () => {
      await setup();
      mirror([
        { key: 'K-1', fixVersions: ['v1'] }, { key: 'HIMMEL-9914', fixVersions: ['v1'] }, { key: 'HIMMEL-9915', fixVersions: ['v1'] },
        { key: 'HIMMEL-9953', fixVersions: [] }, { key: 'HIMMEL-9932', fixVersions: [] },
      ]);
      const ask = (key: string, evidence: Record<string, unknown>) => request(at(), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'required remainder of the parent', evidence, from: 'console' });
      const q53 = ask('HIMMEL-9953', {});
      const q32 = ask('HIMMEL-9932', {});
      expect(conflictsOf()).toEqual([]);
      expect(ask('HIMMEL-9953', { follow_up_of: 'HIMMEL-9914', remainder: true }).req).toBe(q53.req);
      expect(ask('HIMMEL-9932', { follow_up_of: 'HIMMEL-9915', remainder: true }).req).toBe(q32.req);
      expect(conflictsOf()).toEqual(['HIMMEL-9915>HIMMEL-9932:open', 'HIMMEL-9914>HIMMEL-9953:open']);
      claim(at(rmEnv));
      const r = rule(at(rmEnv), { req: q53.req, outcome: 'ADMIT', op: { kind: 'add', from_v: null, to_v: 'v1' }, sector: 'Planning & tracking', ground: 'required remainder', reason: 'parent 9914 cannot close without it', supersedes: [], authority: { kind: 'rm', ref: null } });
      await apply(at(rmEnv), r.id);
      mirror([
        { key: 'K-1', fixVersions: ['v1'] }, { key: 'HIMMEL-9914', fixVersions: ['v1'] }, { key: 'HIMMEL-9915', fixVersions: ['v1'] },
        { key: 'HIMMEL-9953', fixVersions: ['v1'] }, { key: 'HIMMEL-9932', fixVersions: [] },
      ]);
      expect(conflictsOf()).toEqual(['HIMMEL-9915>HIMMEL-9932:claimed']);
    });

    describe('U1: a words re-ask keeps the required-remainder relation', () => {
      const REL = { follow_up_of: 'P-1', remainder: true };
      const row = (evidence: Record<string, unknown>) => ({ verb: 'INTAKE' as const, key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence, from: 'console' });
      const words = (evidence: Record<string, unknown> = {}) => requestWithWords(at(), row(evidence), { decision: '9', words: WORDS });
      const mirrorOf = (child: Record<string, unknown> = {}) => mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [], ...child }]);
      const openRows = () => state(ctx()).requests.open;

      it('a pending request that carries the relation is withdrawn and refiled carrying it, and the contradiction stays listed', async () => {
        await setup();
        decisionFile();
        mirrorOf();
        const first = request(at(), row(REL));
        expect(conflictsOf()).toEqual(['P-1>C-1:open']);
        const got = words();
        expect(got.withdrawn?.req).toBe(first.req);
        expect(got.request.evidence).toEqual({ ...REL, operator: got.operator.id });
        expect(conflictsOf()).toEqual(['P-1>C-1:open']);
        expect(openRows()).toEqual([got.request.req]);
      });

      it('the relation survives a second re-ask and a plain repeat', async () => {
        await setup();
        decisionFile();
        mirrorOf();
        request(at(), row(REL));
        const first = words();
        const second = words();
        expect(second.request.req).toBe(first.request.req);
        expect(second.request.evidence).toEqual({ ...REL, operator: first.operator.id });
        expect(request(at(), row({})).req).toBe(first.request.req);
        expect(conflictsOf()).toEqual(['P-1>C-1:open']);
        expect(openRows()).toEqual([first.request.req]);
      });

      it('a relation is never invented for an ask that never had one', async () => {
        await setup();
        decisionFile();
        mirrorOf();
        request(at(), row({}));
        const got = words();
        expect(got.request.evidence).toEqual({ operator: got.operator.id });
        expect(conflictsOf()).toEqual([]);
        const fresh = requestWithWords(at(), { ...row({}), key: 'C-2' }, { decision: '9', words: WORDS });
        expect(fresh.request.evidence).toEqual({ operator: fresh.operator.id });
      });

      // A re-ask that states any part of a relation states the relation: the old one is not carried onto it (no invented requirement).
      it.each([
        [{ follow_up_of: 'P-2' }],
        [{ remainder: true }],
      ])('a partial relation %j on the re-ask is used as stated; the old relation is not carried onto it', async (stated) => {
        await setup();
        decisionFile();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'P-2', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
        request(at(), row(REL));
        const got = words(stated);
        expect(got.withdrawn).not.toBeNull();
        expect(got.request.evidence).toEqual({ ...stated, operator: got.operator.id });
        expect(conflictsOf()).toEqual([]);
      });

      it('a relation the re-ask states wins, and an explicit remainder:false removes it', async () => {
        await setup();
        decisionFile();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'P-2', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
        request(at(), row(REL));
        expect(words({ follow_up_of: 'P-2', remainder: true }).request.evidence).toMatchObject({ follow_up_of: 'P-2', remainder: true });
        expect(conflictsOf()).toEqual(['P-2>C-1:open']);
        withdraw(at(), { req: openRows()[0], reason: 'again' });
        request(at(), row(REL));
        expect(words({ remainder: false }).request.evidence).toMatchObject({ remainder: false });
        expect(conflictsOf()).toEqual([]);
      });
    });

    describe('U1: the refused-ask remedy keeps --required-by', () => {
      it('an operator-asked child: refused_asks[].remedy equals remainder_conflicts[].next and names --required-by', async () => {
        await setup();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [], labels: ['operator-directed'] }]);
        await refuseWith('C-1', REQ_EVIDENCE);
        const s = state(ctx());
        expect(s.refused_asks[0].remedy).toBe('jira release request R1 --verb INTAKE --key C-1 --from backlog --to v1 --required-by P-1 --why "<why>" --decision <n> --words "<the operator\'s exact words>"');
        expect(s.refused_asks[0].remedy).toBe(s.remainder_conflicts[0].next);
      });

      it('an ordinary child keeps the ack branch and gains --required-by in the new-facts command', async () => {
        await setup();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
        const { r } = await refuseWith('C-1', REQ_EVIDENCE);
        expect(state(ctx()).refused_asks[0].remedy).toBe(`new facts: jira release request R1 --verb INTAKE --key C-1 --from backlog --to v1 --required-by P-1 --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or if the refusal is right: jira release ack R1 --ruling ${r.id} --reason "<why>"`);
      });

      it('the relation a later signed update gave the request counts, not only its first row', async () => {
        await setup();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [], labels: ['operator-directed'] }]);
        const q = request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' });
        request(at(), { verb: 'INTAKE', key: 'C-1', from_v: null, to_v: 'v1', why: 'w', evidence: { follow_up_of: 'P-1', remainder: true }, from: 'console' });
        claim(at(rmEnv));
        const r = rule(at(rmEnv), { req: q.req, outcome: 'BACKLOG', op: { kind: 'none', from_v: null, to_v: null }, sector: 'Planning & tracking', ground: 'defer', reason: 'no record', supersedes: [], authority: { kind: 'rm', ref: null } });
        await apply(at(rmEnv), r.id);
        expect(state(ctx()).refused_asks[0].remedy).toContain('--to v1 --required-by P-1 --why "<why>" --decision <n>');
      });

      it('a refused ask that never had the relation prints none (a remainder:false or a plain ask)', async () => {
        await setup();
        mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [], labels: ['operator-directed'] }, { key: 'C-2', fixVersions: [], labels: ['operator-directed'] }]);
        await refuseWith('C-1', { follow_up_of: 'P-1', remainder: false });
        await refuseWith('C-2', {});
        const asks = state(ctx()).refused_asks;
        expect(asks.map((a) => a.key).sort()).toEqual(['C-1', 'C-2']);
        for (const a of asks) expect(a.remedy).not.toContain('--required-by');
      });
    });

    it('A4 negative: a child that really is in the version, or closed, is no conflict whatever its history says', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      const { r } = await refuseWith('C-1', REQ_EVIDENCE);
      ack(at(), { ruling: r.id, reason: 'fine' });
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: ['v1'] }]);
      expect(conflictsOf()).toEqual([]);
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [], status: 'Done', category: 'Done' }]);
      expect(conflictsOf()).toEqual([]);
    });

    it('unknowns stay visible: a parent or child the mirror does not hold is listed as unknown with the mirror remedy, and an unreadable mirror too', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'C-1', fixVersions: [] }]);
      await refuseWith('C-1', REQ_EVIDENCE);
      const [c] = state(ctx()).remainder_conflicts;
      expect(c).toMatchObject({ parent: 'P-1', child: 'C-1', unknown: 'parent', owner: 'chief', phase: 'refused' });
      expect(c.next).toContain('jira mirror');
      expect(c.next).not.toContain('rm-run');
      rmSync(join(root, 'mirror'), { recursive: true, force: true });
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'P-1', fixVersions: ['v1'] }]);
      const [missingChild] = state(ctx()).remainder_conflicts;
      expect(missingChild, 'a fresh mirror that holds the parent and not the child').toMatchObject({ parent: 'P-1', child: 'C-1', unknown: 'child', owner: 'chief', phase: 'refused' });
      expect(missingChild.next).toContain('jira mirror');
      rmSync(join(root, 'mirror'), { recursive: true, force: true });
      expect(state(ctx()).remainder_conflicts).toMatchObject([{ parent: 'P-1', child: 'C-1', unknown: 'mirror', owner: 'chief' }]);
    });
  });

  it('state-golden.json matches the producer', async () => {
    await setup();
    decisionFile();
    mirror([
      { key: 'K-1', fixVersions: ['v1'] }, { key: 'ABC-1', fixVersions: [] }, { key: 'ABC-2', fixVersions: [], labels: ['operator-directed'] },
      { key: 'ABC-3', fixVersions: [] }, { key: 'ABC-4', fixVersions: [] },
    ]);
    recordRequestDecision(at(), { decision: '9', words: WORDS, key: 'ABC-1', verb: 'INTAKE', from_v: null, to_v: 'v1' });
    for (const k of ['ABC-2', 'ABC-3', 'ABC-4']) await refuseIntake(k);
    // The chain heads hash rows signed with a key minted per run; every other field is fixed by the fixture and the clock.
    const got = `${JSON.stringify({ ...state(ctx()), heads: { rulings: '', operator: '', events: '', requests: '', mirror: null } }, null, 2)}\n`;
    if (process.env.UPDATE_GOLDEN === '1') {
      writeFileSync(GOLDEN, got);
      expect.fail('UPDATE_GOLDEN=1 regenerated state-golden.json; review its diff, then run again without UPDATE_GOLDEN');
    }
    expect(got).toBe(readFileSync(GOLDEN, 'utf8'));
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
    expect(s.requests).toEqual({ open: [], claimed: [], oldest_open: null });
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

// 8731 (fix review F1): a hard-killed rm-run leaves its lease held. The state reports when the lease's owner process is provably gone, through
// the helper rm-run's own reclaim uses (the pid on this host answers ESRCH), so the tick can start the replay exactly when rm-run would reclaim.
describe('T8 V3: state says when the lease owner is provably gone', () => {
  const leaseOf = () => state(ctx()).lease as Record<string, unknown> | null;
  const hold = (pid?: number) => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    return leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1', ...(pid === undefined ? {} : { pid }) });
  };
  // a pid that was real and is gone: a child that has been waited for
  const deadPid = () => {
    const r = spawnSync(process.execPath, ['-e', '0']);
    return r.pid;
  };

  it('a held lease whose recorded owner pid is gone on this host says owner_gone', () => {
    hold(deadPid());
    expect(leaseOf()).toMatchObject({ released: false, owner_gone: true });
  });

  it.each([
    ['a live owner (this process)', () => hold(process.pid)],
    ['a pid that answers to another process, as a reused pid does (cannot be told from the owner, so the lease stays held)', () => hold(process.ppid)],
    ['no recorded pid (a standing session)', () => hold()],
  ])('never says owner_gone for %s', (_name, make) => {
    make();
    expect(leaseOf()).toMatchObject({ released: false });
    expect(leaseOf()).not.toHaveProperty('owner_gone');
  });

  it('never says owner_gone for a pid recorded on another host, nor for a released lease', () => {
    const held = hold(deadPid());
    const k = loadKey(ctx().keyPath);
    writeSigned(join(ctx().dir, 'lease.json'), k, { ...held, owner_host: 'another-host.invalid' });
    expect(leaseOf()).not.toHaveProperty('owner_gone');
    writeSigned(join(ctx().dir, 'lease.json'), k, { ...held, released: true });
    expect(leaseOf()).toMatchObject({ released: true });
    expect(leaseOf()).not.toHaveProperty('owner_gone');
  });

  it('rm-run reclaims exactly that lease and rules the request (so a tick that launches it is never refused by the lease)', async () => {
    hold(deadPid());
    request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
    const lines = await rmRun(ctx(), async (input) => input.requests.map((q) => ({
      req: q.req, outcome: 'ADMIT', op: 'add' as const, from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
    })));
    expect(lines.join('\n')).toMatch(/^RECLAIMED lease epoch 1: rm-run pid \d+ on .* is gone$/m);
    expect(lines.join('\n')).toContain('RULING R-R1-0001');
    expect(state(ctx()).lease).toMatchObject({ epoch: 2, released: true });
  });
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
    expect(before.requests).toEqual({ open: [], claimed: [], oldest_open: null });
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
    expect(after.requests).toEqual({ open: [], claimed: [], oldest_open: null });
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
