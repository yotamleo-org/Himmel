import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, copyFileSync, cpSync, closeSync as closeFd, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, truncateSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ack, apply, bucketCheck, operatorWords, poolCurrent, claim, coreBypass, declare, decisionWords, fold, freeze, leaseAcquire, reopen, leaseRelease, operatorDecision, operatorFence, recordRequestDecision, releaseForProject, request, requestWithWords, reviewed, rule, state, takeover, withdraw,
  JudgeReplyError, LIVE_LOOKUP_MS, coreSnapshot, pull, readMirror, readMirrorFilesUnverified, readOperatorRecords, rmRun, rmRunSummary, pinnedSha, signSpec, specCheck, specReview, standing,
  type Ctx, type Decision, type DoorJiraPort, type JiraPort, type Judge, type JudgeInput, type RuledDecision,
} from './engine.js';
import { judgeOperatorRows } from './judge-input.js';
import { declsFor, leaveGate, type Leave } from './leave.js';
import { doorJudge } from './door.js';
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
    expect(s.requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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

  it('every claimed key is read live, and a non-empty live field wins over the mirror (Live facts)', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [], sector: 'Visibility' }]);
    ask('K-2');
    jira.live.set('K-2', { key: 'K-2', status: 'In Progress', type: 'Task', priority: 'High', fixVersions: [], resolution: null, sector: 'Ship loop' });
    let seen: unknown;
    await rmRun(ctx(), async (input) => { seen = input.issues; return admitAll(input); });
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Ship loop', priority: 'High', status: 'In Progress' })]);
  });

  it('a live read that fails falls back to the mirror, and a refusal on those facts says so (Live facts)', async () => {
    declared();
    mirror([{ key: 'K-2', fixVersions: [], sector: 'Visibility' }]);
    ask('K-2');
    jira.issue = async () => { throw new Error('jira down'); };
    let seen: unknown;
    const refuseAll: Judge = async (input) => { seen = input.issues; return input.requests.map((q) => ({ req: q.req, outcome: 'REFUSE' as const, ground: 'door:closed', reason: 'K-2 is closed' })); };
    expect(await rmRun(ctx(), refuseAll)).toEqual(['REFUSED Q-R1-0001: door:closed: K-2 is closed (mirror facts)']);
    expect(seen).toEqual([expect.objectContaining({ key: 'K-2', sector: 'Visibility' })]);
  });

  it('live reads run at most eight at a time and every key is read once', async () => {
    declared();
    for (let i = 1; i <= 12; i++) ask(`K-${100 + i}`);
    let open = 0;
    let most = 0;
    const read: string[] = [];
    jira.issue = async (key: string) => {
      read.push(key);
      most = Math.max(most, ++open);
      await new Promise((r) => setTimeout(r, 5));
      open--;
      return null;
    };
    await rmRun(ctx(), admitAll);
    expect(most).toBe(8);
    expect([...read].sort()).toEqual(Array.from({ length: 12 }, (_, i) => `K-${101 + i}`).sort());
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
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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

describe('rm-run has no count cap (I15)', () => {
  const askMany = (n: number) => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    for (let i = 1; i <= n; i++) request(ctx(), { verb: 'INTAKE', key: `K-${100 + i}`, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  };
  const admitAll: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const rulings = (lines: string[]) => lines.filter((l) => l.startsWith('RULING '));

  it('21 new High tickets into the current version are all ruled in one run, with no override row', async () => {
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'admissions-ledger.jsonl'));
    askMany(21);
    mirror(Array.from({ length: 21 }, (_, i) => ({ key: `K-${101 + i}`, fixVersions: [], priority: 'High' })));
    const lines = await rmRun(ctx(), admitAll);
    expect(rulings(lines)).toHaveLength(21);
    expect(lines.filter((l) => /bulk|PENDING/.test(l))).toEqual([]);
    expect(jira.fv.get('K-121')).toEqual(['v1']);
    expect(state(ctx()).requests).toMatchObject({ open: [], claimed: [] });
    const ledger = join(root, 'admissions-ledger.jsonl');
    expect(existsSync(ledger) ? readFileSync(ledger, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l).kind).filter((k) => k === 'override') : []).toEqual([]);
  });

  it('a replay of 21 unfinished rulings voids them and re-rules all 21 in the next run', async () => {
    askMany(21);
    const set = jira.setFixVersion;
    jira.setFixVersion = async () => { throw new Error('jira down'); };
    await rmRun(ctx(), admitAll);
    jira.setFixVersion = set;
    const lines = await rmRun(ctx(), admitAll);
    expect(lines.filter((l) => l.startsWith('VOID '))).toHaveLength(21);
    expect(rulings(lines)).toHaveLength(21);
    expect(state(ctx()).requests).toMatchObject({ claimed: [] });
  });

  it('an unreadable mirror aborts the run without leaving the lease held', async () => {
    askMany(2);
    mirror([]);
    mkdirSync(join(root, 'mirror', 'bad.md'));
    await expect(rmRun(ctx(), admitAll)).rejects.toThrow();
    rmSync(join(root, 'mirror', 'bad.md'), { recursive: true });
    expect(rulings(await rmRun(ctx(), admitAll))).toHaveLength(2);
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
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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
    expect(state(ctx()).requests).toEqual({ open: [], claimed: [], oldest_open: null, pending_keys: [] });
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

describe('the release state carries the version lines', () => {
  it('a re-freeze on disk keeps came in from falling and lists the dropped key as left by the operator', async () => {
    await setup();
    freeze({ ...ctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, { version: 'v1', keys: ['K-2'], decision: '105', verbatim: 'frozen at 2' });
    mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1'] }], '2026-10-22T09:00:00.000Z');
    const l = state(ctx()).version_lines.v1;
    if (l?.status !== 'OK') throw new Error(JSON.stringify(l));
    expect(l.days.map((x) => [x.day, x.came_in, x.left, x.open])).toEqual([['2026-10-21', 1, 0, 1], ['2026-10-22', 2, 1, 1]]);
    expect(l.days[0].arrived).toEqual({ baseline: 1 });
    expect(l.left).toEqual([{ key: 'K-1', day: '2026-10-22', authority: 'operator' }]);
  });

  it('reads a mirror file\'s resolved date into the snapshot', () => {
    const dir = join(root, 'mirror-resolved');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'K-9.md'), '---\nkey: "K-9"\ntype: "Task"\nstatus: "Done"\npriority: "Medium"\nfixVersions: []\nresolution: "Done"\nresolved: "2026-10-20T08:00:00.000+0000"\n---\n');
    writeFileSync(join(dir, 'K-8.md'), '---\nkey: "K-8"\ntype: "Task"\nstatus: "To Do"\npriority: "Medium"\nfixVersions: []\nresolution: null\n---\n');
    const issues = readMirrorFilesUnverified(dir).issues;
    expect(issues?.get('K-9')?.resolved).toBe('2026-10-20T08:00:00.000+0000');
    expect(issues?.get('K-8')?.resolved).toBeNull();
  });

  it('a release that does not verify carries no lines', () => {
    expect(state(ctx()).version_lines).toEqual({});
  });
});

describe('the door rules every request; no model is asked', () => {
  beforeEach(() => {
    vi.stubEnv('HIMMEL_API_CREDIT_STATE', join(mkdtempSync(join(tmpdir(), 'door-credit-')), 'credit.json'));
    judgeChild.on = true;
    judgeChild.spawns = [];
    judgeChild.reply = JSON.stringify([{ req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1.1.3', sector: 'Planning & tracking', ground: 'model', reason: 'a model ruled', supersedes: [] }]);
  });
  afterEach(() => { judgeChild.on = false; });

  it('judgeFor places a Medium INTAKE in the next version and an operator ask in current, with zero model spawns', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    mirror([
      { key: 'K-2', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking' },
      { key: 'K-3', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking', labels: ['operator-directed'] },
    ]);
    request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1.1.3', why: 'found work', evidence: {}, from: 'console' });
    request(ctx(), { verb: 'INTAKE', key: 'K-3', from_v: null, to_v: 'v1.1.3', why: 'the operator asked', evidence: {}, from: 'console' });
    const { judgeFor } = await import('../commands/release.js');
    const lines = await rmRun(ctx(), judgeFor(ctx()));
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-\d+ Q-R1-0001 INTAKE K-2 add backlog→v1\.1\.4 ADMIT next sector=Planning & tracking — door:mild: /));
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-\d+ Q-R1-0002 INTAKE K-3 add backlog→v1\.1\.3 ADMIT current sector=Planning & tracking — door:operator-ask: /));
    expect(judgeChild.spawns.filter((s) => s === 'claude' || s === 'claude-api.sh')).toEqual([]);
  });
});

describe('rmRun with the door', () => {
  const declared2 = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  const ask = (key: string, o: Partial<RequestRow> = {}) =>
    request(ctx(), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console', ...o });
  const rows = <T>(file: string): T[] => {
    const p = join(ctx().dir, `${file}.jsonl`);
    return existsSync(p) ? readChain<T>(p, loadKey(ctx().keyPath)).verified : [];
  };
  const kind = (v: unknown): string => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);
  const shape = (r: Record<string, unknown>): Record<string, string> => Object.fromEntries(Object.keys(r).sort().map((k) => [k, kind(r[k])]));
  const seen: Decision[] = [];
  const door: Judge = async (input) => { const d = await doorJudge(input); seen.push(...d); return d; };
  beforeEach(() => { seen.length = 0; });

  it('writes rows of the shape the base writer wrote, and the tick parses its receipt (I10)', async () => {
    const golden = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'engine.i10-baseline.a070e4432.jsonl'), 'utf8').trim().split('\n')
      .map((l) => JSON.parse(l) as { file: string; row: Record<string, unknown> });
    declared2();
    mirror([
      { key: 'K-2', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking' },
      { key: 'K-3', fixVersions: [], priority: 'High', sector: 'Planning & tracking' },
      { key: 'K-4', fixVersions: ['v2'], status: 'In Progress', category: 'In Progress', sector: 'Planning & tracking' },
    ]);
    jira.fv.set('K-4', ['v2']);
    ask('K-2');
    ask('K-3');
    ask('K-4', { verb: 'REVERSION', from_v: 'v2', to_v: 'v1', why: 'started' });
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    ask('K-5', { evidence: {} });
    ask('K-5', { evidence: { chief_placement: { reason: 'the release needs it', ts: '2026-10-21T10:00:00.000Z' } } });
    const lines = await rmRun(ctx(), door);
    expect(lines.filter((l) => l.startsWith('RULING '))).toHaveLength(4);
    const fresh = [
      ...['requests', 'rulings', 'events'].flatMap((file) => rows<Record<string, unknown>>(file).map((row) => ({ file, row }))),
      ...readFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, 'utf8').split('\n').filter(Boolean).map((l) => ({ file: 'admissions', row: JSON.parse(l) as Record<string, unknown> })),
    ];
    const kindOf = (x: { file: string; row: Record<string, unknown> }) =>
      `${x.file}:${String(x.row.state ?? x.row.phase ?? x.row.kind ?? '').replace(/:.*/, '')}`;
    const goldenShapes = new Map<string, Record<string, string[]>>();
    for (const g of golden) {
      const acc = goldenShapes.get(kindOf(g)) ?? {};
      for (const [f, t] of Object.entries(shape(g.row))) acc[f] = [...new Set([...(acc[f] ?? []), t])];
      goldenShapes.set(kindOf(g), acc);
    }
    expect([...goldenShapes.keys()].sort()).toEqual(['admissions:rm-admit', 'admissions:rm-remove', 'events:ruled', 'requests:claimed', 'requests:open', 'requests:ruled', 'rulings:applied', 'rulings:intent', 'rulings:receipted']);
    for (const [k, want] of goldenShapes) {
      const mine = fresh.filter((x) => kindOf(x) === k);
      expect(mine.length, k).toBeGreaterThan(0);
      for (const x of mine) {
        const got = shape(x.row);
        for (const [f, t] of Object.entries(got)) expect(want[f], `${k}.${f}`).toContain(t);
      }
      expect(Object.keys(shape(mine[0].row)).sort(), k).toEqual(Object.keys(shape(golden.find((g) => kindOf(g) === k)!.row)).sort());
    }
    const tick = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'tick.sh'), 'utf8');
    const parse = /rm = (re\.match\(r"\\\[release-ruling .*?", rl\[-1\]\))/.exec(tick)?.[1];
    expect(parse).toBeDefined();
    const receipt = jira.comments.get('K-2')![0].body.split('\n')[0];
    const py = spawnSync('python3', ['-c', `import re,sys\nrl=[sys.argv[1]]\nrm=${parse}\nprint(rm[1], rm[2], rm[3])`, receipt], { encoding: 'utf8' });
    expect(py.stdout.trim(), py.stderr).toBe('K-2 v2 ADMIT');
  });

  it('a door REFUSE closes the request as refused, with no ruling and no HELD line, and files the request its rule O row queues (T1)', async () => {
    declared2();
    mirror([{ key: 'K-2', fixVersions: ['v1'] }]);
    jira.fv.set('K-2', ['v1']);
    const o = operatorDecision(ctx(), { decision: '243', keys: ['K-2'], op: 'discharge', from_v: 'v1', to_v: 'v1', verbatim: 'x' });
    const q = ask('K-2', { verb: 'REVERSION', from_v: 'v1', to_v: 'v2', why: 'later' });
    const lines = await rmRun(ctx(), door);
    expect(lines).toEqual([
      expect.stringMatching(new RegExp(`^REFUSED ${q.req}: door:operator:${o.id}: `)),
      expect.stringMatching(new RegExp(`^QUEUED Q-R1-0002: DISCHARGE K-2 for ${o.id}$`)),
    ]);
    expect(rows<RulingRow>('rulings')).toEqual([]);
    const reqs = rows<RequestRow>('requests');
    const queued = reqs.filter((r) => r.req === 'Q-R1-0002');
    expect(queued.at(-1)).toMatchObject({ verb: 'DISCHARGE', key: 'K-2', from: 'rm', evidence: { operator_record: o.id }, state: 'open' });
    expect(Object.keys(queued[0]).sort()).toEqual(Object.keys(reqs[0]).sort());
    expect(reqs.filter((r) => r.req === q.req).at(-1)?.state).toMatch(/^refused/);
  });

  it('a key with two waiting requests is ruled once per run; the later request waits for the next', async () => {
    declared2();
    mirror([{ key: 'K-2', fixVersions: [] }]);
    const a = ask('K-2');
    const b = ask('K-2', { to_v: 'v2', why: 'found more work' });
    const lines = await rmRun(ctx(), door);
    expect(lines.filter((l) => l.startsWith('RULING '))).toEqual([expect.stringContaining(` ${a.req} INTAKE K-2 `)]);
    expect(state(ctx()).requests).toMatchObject({ open: [b.req], claimed: [] });
  });

  it('a door ruling that leaves no version puts the backlog label on, an ADMIT takes it off, and a port that cannot add labels is PENDING (I6)', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1'], decision: '106', verbatim: 'R = v1', mode: 'observe' });
    mirror([{ key: 'K-2', fixVersions: [] }, { key: 'K-3', fixVersions: [], priority: 'High' }]);
    jira.lbl.set('K-3', ['backlog']);
    ask('K-2');
    ask('K-3');
    const added: Array<[string, string[]]> = [];
    (jira as unknown as DoorJiraPort).addLabels = async (key, labels) => { added.push([key, labels]); };
    const lines = await rmRun(ctx(), door);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-\d+ Q-R1-0001 INTAKE K-2 none backlog→backlog BACKLOG .* door:mild-no-next: /));
    expect(added).toEqual([['K-2', ['backlog']]]);
    expect(jira.labelPuts).toContainEqual({ key: 'K-3', labels: ['backlog'] });
    delete (jira as unknown as DoorJiraPort).addLabels;
    mirror([{ key: 'K-4', fixVersions: [] }]);
    ask('K-4');
    expect(await rmRun(ctx(), door)).toContainEqual(expect.stringMatching(/^PENDING R-R1-\d+: the backlog label on K-4: this Jira port cannot add labels$/));
  });

  it('a rule O remove sends the key to the backlog with the label (I6)', async () => {
    declared2();
    mirror([{ key: 'K-2', fixVersions: ['v1'] }]);
    jira.fv.set('K-2', ['v1']);
    ask('K-2', { to_v: 'v2' });
    operatorDecision(ctx(), { decision: '243', keys: ['K-2'], op: 'remove', from_v: 'v1', to_v: null, verbatim: 'x' });
    const added: string[] = [];
    (jira as unknown as DoorJiraPort).addLabels = async (key) => { added.push(key); };
    expect(await rmRun(ctx(), door)).toContainEqual(expect.stringMatching(/^RULING .* INTAKE K-2 remove v1→backlog BACKLOG /));
    expect(jira.fv.get('K-2')).toEqual([]);
    expect(added).toEqual(['K-2']);
  });

  it('rule() writes the door\'s op, outcome, authority and supersedes, but for the named exception (I14)', async () => {
    declared2();
    mirror([{ key: 'K-2', fixVersions: [] }, { key: 'K-3', fixVersions: [] }]);
    const intentOf = (req: string) => rows<RulingRow>('rulings').find((r) => r.req === req && r.phase === 'intent')!;
    const same = (req: string) => {
      const d = seen.find((x) => x.req === req) as RuledDecision;
      const r = intentOf(req);
      expect({ op: r.op.kind, outcome: r.outcome, authority: r.authority.kind, supersedes: r.supersedes })
        .toEqual({ op: d.op, outcome: d.outcome, authority: d.authority ?? 'rm', supersedes: d.supersedes ?? [] });
    };
    const placedBy = operatorDecision(ctx(), { decision: '243', keys: ['K-2'], op: 'add', from_v: null, to_v: 'v2', verbatim: 'x' });
    const first = ask('K-2', { to_v: 'v2' });
    await rmRun(ctx(), door);
    same(first.req);
    expect(intentOf(first.req).authority).toEqual({ kind: 'operator', ref: placedBy.id });
    mirror([{ key: 'K-2', fixVersions: ['v2'], priority: 'High' }, { key: 'K-3', fixVersions: [] }]);
    const again = ask('K-2');
    const lines = await rmRun(ctx(), door);
    expect(lines).toContainEqual(expect.stringMatching(new RegExp(`^RULING R-R1-\\d+ ${again.req} INTAKE K-2 none .* AD-HOC .* door:operator-standing:`)));
    same(again.req);
    const o3 = operatorDecision(ctx(), { decision: '244', keys: ['K-3'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'x' });
    const rev = ask('K-3', { verb: 'REVERSION', from_v: null, to_v: 'v1', why: 'the operator placed it' });
    await rmRun(ctx(), door);
    expect(seen.find((x) => x.req === rev.req)).toMatchObject({ outcome: 'MOVE', op: 'move', from: null, to: 'v1', ref: o3.id });
    expect(intentOf(rev.req)).toMatchObject({ op: { kind: 'add', from_v: null, to_v: 'v1' }, authority: { kind: 'operator', ref: o3.id } });
  });

  it('the live read wins field by field: labels place rule A, In Progress places rule W, a null sector keeps the mirror\'s (Live facts)', async () => {
    declared2();
    mirror([{ key: 'K-2', fixVersions: [], sector: 'Visibility' }, { key: 'K-3', fixVersions: [], sector: 'Visibility' }]);
    const live = (key: string, o: Partial<IssueSnap>): IssueSnap => ({ key, status: 'To Do', statusCategory: 'To Do', type: 'Task', priority: '', fixVersions: [], resolution: null, sector: null, labels: [], ...o });
    jira.live.set('K-2', live('K-2', { labels: ['operator-directed'] }));
    jira.live.set('K-3', live('K-3', { status: 'In Progress', statusCategory: 'In Progress' }));
    ask('K-2', { to_v: 'v1' });
    ask('K-3', { to_v: 'v2' });
    const lines = await rmRun(ctx(), door);
    expect(lines).toContainEqual(expect.stringMatching(/^RULING .* INTAKE K-2 add backlog→v1 ADMIT current sector=Visibility — door:operator-ask: /));
    expect(lines).toContainEqual(expect.stringMatching(/^RULING .* INTAKE K-3 add backlog→v1 ADMIT current sector=Visibility — door:started: /));
  });
});

describe('the chief\'s lists: priority review, chief placements and asks apart (S1b)', () => {
  const declared2 = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  const ask = (key: string, o: Partial<RequestRow> = {}) =>
    request(ctx(), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console', ...o });
  const at = (iso: string): Ctx => ({ ...ctx(), now: () => new Date(iso) });
  const receipted = (key: string): RulingRow[] => {
    const p = join(ctx().dir, 'rulings.jsonl');
    return readChain<RulingRow>(p, loadKey(ctx().keyPath)).verified.filter((r) => r.key === key && r.phase === 'receipted');
  };
  const stub = (grounds: Record<string, string>): Judge => async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Planning & tracking', ground: grounds[q.key], reason: `placed by ${grounds[q.key]}`,
  }));
  const LISTED = ['door:serious:High', 'door:mild', 'door:mild-no-next', 'door:rest-of:K-1', 'door:operator-ask', 'door:operator-ask:v1', 'door:started', 'door:operator-undeclared:v9'];
  const UNLISTED = ['door:operator:O-R1-0001', 'door:done', 'door:chief', 'door:operator-ask-apart:K-1@v2', 'door:operator-apart:K-1@v2', 'door:repair', 'door:repair-keeps', 'door:operator-standing:R-R1-0001', 'door:stays:v1'];
  const keyed = (grounds: string[], from: number) => Object.fromEntries(grounds.map((g, i) => [`K-${from + i}`, g]));

  it('a receipted door:chief ruling is in chief_placements until a reviewed row covers it, read from a ledger row that carries no list field', async () => {
    declared2();
    mirror([{ key: 'K-5', fixVersions: [], sector: 'Planning & tracking' }]);
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    ask('K-5', { evidence: { chief_placement: { reason: 'the release needs it', ts: '2026-10-21T10:00:00.000Z' } } });
    await rmRun(ctx(), doorJudge);
    const [r] = receipted('K-5');
    expect(r.ground).toBe('door:chief');
    expect(Object.keys(r)).not.toContain('chief_placements');
    expect(state(ctx()).chief_placements).toEqual([{ key: 'K-5', ruling: r.id, reason: 'the release needs it' }]);
    reviewed(ctx(), { ruling: r.id, reason: 'relayed to the operator' });
    expect(state(ctx()).chief_placements).toEqual([]);
  });

  it('priority_review holds one entry per ruling of each self-settable ground and none for the others (P7, X11)', async () => {
    declared2();
    const grounds = { ...keyed(LISTED, 10), ...keyed(UNLISTED, 30) };
    mirror(Object.keys(grounds).map((key) => ({ key, fixVersions: [], sector: 'Planning & tracking' })));
    for (const key of Object.keys(grounds)) ask(key);
    await rmRun(ctx(), stub(grounds));
    const s = state(ctx());
    expect(s.priority_review.map((e) => e.ground)).toEqual(LISTED);
    expect(s.priority_review.map((e) => e.key)).toEqual(Object.keys(keyed(LISTED, 10)));
    expect(s.priority_review[3]).toEqual({ key: 'K-13', ruling: receipted('K-13')[0].id, ground: 'door:rest-of:K-1' });
    expect(s.priority_review.some((e) => e.ground === 'door:repair-keeps')).toBe(false);
    expect(s.chief_placements.map((e) => e.key)).toEqual(['K-32']);
    expect(s.asks_apart.map((e) => e.key)).toEqual(['K-33', 'K-34']);
    expect(s.asks_apart[1]).toEqual({ key: 'K-34', ruling: receipted('K-34')[0].id, version: 'v1', parent: 'K-1', parent_version: 'v2' });
  });

  it('reviewed --ruling clears one entry, --through clears every listed entry of that list up to the named ruling', async () => {
    declared2();
    const grounds = { ...keyed(LISTED, 10), 'K-40': 'door:chief' };
    mirror(Object.keys(grounds).map((key) => ({ key, fixVersions: [], sector: 'Planning & tracking' })));
    for (const key of Object.keys(grounds)) ask(key);
    await rmRun(ctx(), stub(grounds));
    const id = (k: string) => receipted(k)[0].id;
    reviewed(ctx(), { ruling: id('K-11'), reason: 'the priority is right' });
    expect(state(ctx()).priority_review.map((e) => e.key)).toEqual(['K-10', 'K-12', 'K-13', 'K-14', 'K-15', 'K-16', 'K-17']);
    const row = reviewed(ctx(), { through: id('K-14'), reason: 'checked in bulk' });
    expect(row).toMatchObject({ kind: 'reviewed', key: 'K-14', from: null, to: null, ruling: id('K-14'), through: id('K-14'), reason: 'checked in bulk' });
    const s = state(ctx());
    expect(s.priority_review.map((e) => e.key)).toEqual(['K-15', 'K-16', 'K-17']);
    expect(s.chief_placements.map((e) => e.key)).toEqual(['K-40']);
    expect(s.integrity).toEqual([]);
    expect(() => reviewed(ctx(), { ruling: id('K-11'), reason: 'again' })).toThrow(/no listed entry/);
    expect(() => reviewed(ctx(), { ruling: id('K-15'), reason: ' ' })).toThrow(/--reason/);
  });

  it('asks_apart holds one entry per tuple from its newest ruling; a reviewed tuple stays off, a moved parent is listed fresh, a remainder: false ask is not apart (A1)', async () => {
    declared2();
    const parentIn = (fixVersions: string[], child: string[]) => mirror([
      { key: 'K-1', fixVersions, sector: 'Planning & tracking' },
      { key: 'K-3', fixVersions: child, sector: 'Planning & tracking', labels: ['operator-directed'] },
    ]);
    const rest = { evidence: { follow_up_of: 'K-1', remainder: true } };
    parentIn(['v2'], []);
    ask('K-3', rest);
    await rmRun(ctx(), doorJudge);
    expect(receipted('K-3')[0].ground).toBe('door:operator-ask-apart:K-1@v2');
    parentIn(['v2'], ['v1']);
    ask('K-3', rest);
    await rmRun(ctx(), doorJudge);
    const [first, second] = receipted('K-3');
    expect(second.ground).toBe(first.ground);
    let s = state(ctx());
    expect(s.asks_apart).toEqual([{ key: 'K-3', ruling: second.id, version: 'v1', parent: 'K-1', parent_version: 'v2' }]);
    expect(s.priority_review).toEqual([]);
    reviewed(ctx(), { ruling: first.id, reason: 'relayed: the ask and its parent sit apart' });
    expect(state(ctx()).asks_apart).toEqual([]);
    ask('K-3', rest);
    await rmRun(ctx(), doorJudge);
    expect(receipted('K-3')).toHaveLength(3);
    expect(state(ctx()).asks_apart).toEqual([]);
    parentIn([], ['v1']);
    ask('K-3', rest);
    await rmRun(ctx(), doorJudge);
    s = state(ctx());
    expect(s.asks_apart).toEqual([{ key: 'K-3', ruling: receipted('K-3')[3].id, version: 'v1', parent: 'K-1', parent_version: 'none' }]);
    ask('K-3', { evidence: { follow_up_of: 'K-1', remainder: false } });
    await rmRun(ctx(), doorJudge);
    expect(receipted('K-3')[4].ground).not.toMatch(/apart/);
    expect(state(ctx()).asks_apart).toEqual(s.asks_apart);
  });

  it('state carries the declaration\'s current and versions, and the key of each open and claimed request (U8)', async () => {
    await setup();
    ask('K-2');
    ask('K-3');
    claim(ctx(rmEnv));
    ask('K-4');
    const s = state(ctx());
    expect(s.current).toBe('v1');
    expect(s.versions).toEqual(['v1', 'v2']);
    expect(s.requests.claimed).toHaveLength(2);
    expect(s.requests.pending_keys).toEqual(['K-2', 'K-3', 'K-4']);
  });

  it('a reviewed row written after the mirror sync leaves the mirror FRESH and the key\'s membership as it was (T2)', async () => {
    declared2();
    mirror([{ key: 'K-10', fixVersions: [], sector: 'Planning & tracking' }]);
    ask('K-10');
    await rmRun(ctx(), stub({ 'K-10': 'door:mild' }));
    mirror([{ key: 'K-10', fixVersions: ['v1'], sector: 'Planning & tracking' }], '2026-10-21T10:00:00.000Z');
    const before = state(ctx());
    expect(before.inputs.mirror).toBe('FRESH');
    reviewed(at('2026-10-21T10:05:00.000Z'), { ruling: before.priority_review[0].ruling, reason: 'the priority is right' });
    const after = state(ctx());
    expect(after.inputs.mirror).toBe('FRESH');
    expect(after.records.find((r) => r.key === 'K-10')?.actual_member).toBe(before.records.find((r) => r.key === 'K-10')?.actual_member);
    expect(after.priority_review).toEqual([]);
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
