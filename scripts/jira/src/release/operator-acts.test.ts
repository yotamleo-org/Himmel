import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, bucketCheck, operatorWords, poolCurrent, claim, declare, fold, freeze, leaseAcquire, reopen, operatorDecision, request, rule, state, withdraw,
  type Ctx, type JiraPort,
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
import type { IssueSnap } from './types.js';
import type { Getter } from './version-writes.js';
import { appendChain, loadKey } from './ledger.js';

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

  describe('an incomplete mirror (BC1)', () => {
    const SYNC = '2026-11-26T16:33:57.000Z';
    const cursor = (c: Record<string, unknown>, dir = mir()) => writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: SYNC, total: 1, project: 'BKT', ...c }));
    const checkCli = (keys: string[], cli?: string, dir = mir()) => bucketCheck(env(), keys, dir, { get: stub().get, deadlineMs: 5000, now: NOW, ...(cli ? { cli } : {}) });
    const key1 = [{ key: 'BKT-1', fixVersions: ['v1.1.9'] }];

    it('BC1: a cursor complete:false names the cause, lastSync, root, repair kind and the heal command', async () => {
      world(key1);
      cursor({ complete: false, repair: 'incremental' });
      expect(await checkCli(['BKT-1'], '/x/index.js')).toEqual([
        `FAILED BKT-1 mirror sync incomplete since ${SYNC} at ${mir()} (cursor complete: false, repair: incremental); heal: JIRA_PROJECT_KEY=BKT node /x/index.js mirror --root ${mir()}`,
      ]);
    });

    it('BC1b: no cli and a cursor with no repair field reads repair incremental and jira mirror', async () => {
      world(key1);
      cursor({ complete: false });
      expect(await checkCli(['BKT-1'])).toEqual([
        `FAILED BKT-1 mirror sync incomplete since ${SYNC} at ${mir()} (cursor complete: false, repair: incremental); heal: JIRA_PROJECT_KEY=BKT jira mirror --root ${mir()}`,
      ]);
    });

    it('BC1c (control): the same mirror with a complete cursor answers IN', async () => {
      world(key1);
      cursor({});
      expect(await checkCli(['BKT-1'], '/x/index.js')).toEqual(['IN BKT-1 current=v1.1.9 via=mirror']);
    });

    it('BC1d (control): no cursor and no files keeps no readable mirror', async () => {
      declared();
      versions();
      mkdirSync(mir(), { recursive: true });
      expect(await checkCli(['BKT-1'], '/x/index.js')).toEqual([`FAILED BKT-1 no readable mirror at ${mir()}`]);
    });

    it('BC1e: an incomplete mirror never passes a key, Done included', async () => {
      world([{ key: 'BKT-1', fixVersions: ['v1.1.9'], status: 'Done', category: 'Done' }]);
      cursor({ complete: false, repair: 'incremental' });
      const [line] = await checkCli(['BKT-1'], '/x/index.js');
      expect(line).toMatch(/^FAILED BKT-1 mirror sync incomplete since /);
    });

    it('BC1g: a cursor whose complete field is anything but absent never passes a key', async () => {
      world(key1);
      cursor({ complete: true });
      const [line] = await checkCli(['BKT-1'], '/x/index.js');
      expect(line).toMatch(/^FAILED BKT-1 mirror sync incomplete since /);
    });

    it('BC1f: a root with a space is single-quoted in the heal command and the repair kind is named', async () => {
      const dir = join(root, 'my mirror', 'BKT');
      mkdirSync(dir, { recursive: true });
      cursor({ complete: false, repair: 'full' }, dir);
      const [line] = await checkCli(['BKT-1'], '/x/index.js', dir);
      expect(line).toContain('(cursor complete: false, repair: full)');
      expect(line).toContain(`mirror --root '${dir}'`);
    });
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
