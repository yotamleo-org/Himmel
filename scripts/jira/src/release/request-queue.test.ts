import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, claim, declare, decisionWords, freeze, leaseAcquire, leaseRelease, operatorDecision, operatorFence, recordRequestDecision, request, requestWithWords, rule, state, withdraw,
  pull, rmRun, standing,
  type Ctx, type JiraPort, type Judge,
} from './engine.js';
import { execFileSync, spawnSync } from 'node:child_process';
import * as pinned from './pinned.js';
import * as ledger from './ledger.js';

const afterMinerva = vi.hoisted(() => ({ fn: null as null | (() => void) }));
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
import type { IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';
import { appendChain, loadKey, readChain } from './ledger.js';

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
  writeFileSync(join(procRoot, '300', 'cmdline'), 'node\0vitest\0');
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

describe('a blocker of a current-version ticket is pulled into the current version', () => {
  const at = (iso: string): Ctx => ({ ...ctx(), now: () => new Date(iso) });
  const noJudge: Judge = async () => { throw new Error('the judge must not be called for a blocker pull'); };
  const declared = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
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

describe('a gated ask cites the operator record that already covers it', () => {
  const FILE = 'Operator, verbatim:\n\n"Approved one more round of the spike"\n\nAnswering the ask on K-5: stop and park.\n';
  const WORDS = 'Approved one more round';
  const OTHER_WORDS = 'Approved one more round of the spike';
  let clock = 0;
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
