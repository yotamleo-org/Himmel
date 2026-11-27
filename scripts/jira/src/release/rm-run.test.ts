import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, claim, declare, freeze, leaseAcquire, operatorDecision, request, rule, state,
  JudgeReplyError, LIVE_LOOKUP_MS, readMirror, readMirrorFilesUnverified, rmRun, rmRunSummary, standing,
  type Ctx, type Decision, type DoorJiraPort, type JiraPort, type Judge, type JudgeInput, type RuledDecision,
} from './engine.js';
import { judgeOperatorRows } from './judge-input.js';
import { doorJudge } from './door.js';
import { ctxFor } from '../commands/release.js';
import { makeNdStub } from '../operations/readiness-stub.test-helper.js';
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
import { appendChain, loadKey, readChain, writeSigned } from './ledger.js';

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

  it('one ruling is one row per phase and a replay adds none', async () => {
    declared();
    ask('K-2');
    await rmRun(ctx(), admitAll);
    const rows = () => readChain<RulingRow>(join(ctx().dir, 'rulings.jsonl'), loadKey(ctx().keyPath)).verified;
    expect([...new Set(rows().map((r) => r.id))]).toEqual(['R-R1-0001']);
    expect(rows().map((r) => r.phase)).toEqual(['intent', 'applied', 'receipted']);
    const before = rows().length;
    expect(await rmRun(ctx(), admitAll)).toEqual(['RM-RUN R1: nothing pending']);
    leaseAcquire(ctx(rmEnv), { expectEpoch: 1, doc: DOC, session: 'rm-1' });
    expect((await apply(ctx(rmEnv), 'R-R1-0001')).phase).toBe('receipted');
    expect(rows().length).toBe(before);
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

describe('a delivered ticket in a later version follows its merge (decision 929)', () => {
  const declared = () => declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
  const id = 'O-R1-delivered-follows-merge';
  const rulingRows = () => readChain<RulingRow>(join(ctx().dir, 'rulings.jsonl'), loadKey(ctx().keyPath)).verified;
  const operatorRows = () => readChain<OperatorRow>(join(ctx().dir, 'operator.jsonl'), loadKey(ctx().keyPath)).verified;
  const evidence = { merged_pr: 'https://github.com/o/r/pull/5', pr_number: 5 };
  const wired = (pr = 5): Ctx => ({ ...ctx(), deliveredPr: () => pr });
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

describe('the door rules every request; no model is asked', () => {
  beforeEach(() => {
    vi.stubEnv('HIMMEL_API_CREDIT_STATE', join(mkdtempSync(join(tmpdir(), 'door-credit-')), 'credit.json'));
    judgeChild.on = true;
    judgeChild.spawns = [];
    judgeChild.reply = JSON.stringify([{ req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1.1.3', sector: 'Planning & tracking', ground: 'model', reason: 'a model ruled', supersedes: [] }]);
  });
  afterEach(() => { judgeChild.on = false; });

  it('judgeFor places a Medium INTAKE in the backlog and an operator ask in current, with zero model spawns', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    mirror([
      { key: 'K-2', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking' },
      { key: 'K-3', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking', labels: ['operator-directed'] },
    ]);
    request(ctx(), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1.1.3', why: 'found work', evidence: {}, from: 'console' });
    request(ctx(), { verb: 'INTAKE', key: 'K-3', from_v: null, to_v: 'v1.1.3', why: 'the operator asked', evidence: {}, from: 'console' });
    const { judgeFor } = await import('../commands/release.js');
    const lines = await rmRun(ctx(), judgeFor(ctx()));
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-\d+ Q-R1-0001 INTAKE K-2 none backlog→backlog BACKLOG .* door:mild: /));
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
      { key: 'K-2', fixVersions: [], priority: 'Medium', sector: 'Planning & tracking', labels: ['operator-directed'] },
      { key: 'K-3', fixVersions: [], priority: 'High', sector: 'Planning & tracking' },
      { key: 'K-4', fixVersions: ['v2'], status: 'In Progress', category: 'In Progress', sector: 'Planning & tracking' },
    ]);
    jira.fv.set('K-4', ['v2']);
    ask('K-2', { to_v: 'v2' });
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

  it('the door gets whether current is frozen from the verified freeze rows, and the parent of a follow-up is read live (R42)', async () => {
    declared2();
    mirror([
      { key: 'K-1', fixVersions: ['v1'] },
      { key: 'K-2', fixVersions: [], priority: 'Low', labels: ['regression'], sector: 'Planning & tracking' },
      { key: 'K-3', fixVersions: [], priority: 'Low', labels: ['regression'], sector: 'Planning & tracking' },
      { key: 'K-4', fixVersions: [], priority: 'Low', sector: 'Planning & tracking' },
    ]);
    const inputs: JudgeInput[] = [];
    const spy: Judge = async (input) => { inputs.push(input); return door(input); };
    ask('K-2');
    expect(await rmRun(ctx(), spy)).toContainEqual(expect.stringMatching(/INTAKE K-2 add backlog→v1 ADMIT current .* door:label:regression: /));
    expect(inputs.at(-1)?.frozen).toBe(false);
    freeze(ctx(), { version: 'v1', keys: [], decision: '106', verbatim: 'v1 frozen' });
    ask('K-3');
    expect(await rmRun(ctx(), spy)).toContainEqual(expect.stringMatching(/INTAKE K-3 none backlog→backlog BACKLOG .* door:mild: /));
    expect(inputs.at(-1)?.frozen).toBe(true);
    ask('K-4', { evidence: { follow_up_of: 'K-1' } });
    await rmRun(ctx(), spy);
    expect(inputs.at(-1)?.issues.map((i) => i.key)).toContain('K-1');
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
    expect(lines).toContainEqual(expect.stringMatching(/^RULING R-R1-\d+ Q-R1-0001 INTAKE K-2 none backlog→backlog BACKLOG .* door:mild: /));
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

describe('10944 rm-run and the readiness check at admission', () => {
  const KEY = 'HIMMEL-2';
  const admitCurrent: Judge = async (input) => input.requests.map((q) => ({
    req: q.req, outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 'Ship loop', ground: 'regression', reason: 'breaks the console',
  }));
  const phaseOf = (id: string) => readFileSync(join(ctx().dir, 'rulings.jsonl'), 'utf8').trim().split('\n')
    .map((l) => JSON.parse(l) as RulingRow).filter((r) => r.id === id).at(-1)?.phase;
  const queued = () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    request(ctx(), { verb: 'INTAKE', key: KEY, from_v: null, to_v: 'v1', why: 'found work', evidence: {}, from: 'console' });
  };

  beforeEach(() => {
    const conf = join(root, 'conf');
    mkdirSync(conf, { recursive: true });
    writeFileSync(join(conf, 'himmel.conf'), 'JIRA_PROJECT_KEY=HIMMEL\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', conf);
  });

  it('10944 A7 a run stopped while the check runs leaves no check process, and the ruling is as without the check', async () => {
    queued();
    const stub = makeNdStub({ sleepMs: 20_000 });
    vi.stubEnv('JIRA_READINESS_CHECK', stub.path);
    const stop = new AbortController();
    const run = rmRun(ctx(), admitCurrent, { signal: stop.signal });
    await vi.waitFor(() => expect(stub.calls()).toHaveLength(1), { timeout: 5000 });
    stop.abort(new Error('rm-run: stopped by SIGTERM'));
    const lines = await run;
    expect(lines).toContain(`PENDING R-R1-0001: readiness check not run on ${KEY} (the caller stopped it)`);
    expect(phaseOf('R-R1-0001')).toBe('receipted');
    await vi.waitFor(() => expect(stub.alive()).toBe(false));
  });

  it('10944 A7.mirror the check reads the dispatcher\'s mirror, not the one the release ctx holds', async () => {
    queued();
    const stub = makeNdStub();
    vi.stubEnv('JIRA_READINESS_CHECK', stub.path);
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
    vi.stubEnv('HIMMEL_JIRA_MIRROR', join(root, 'moved-mirror'));
    const built = ctxFor('R1', join(root, 'other-mirror'));
    await rmRun({ ...built, env: {}, jira }, admitCurrent);
    const [call] = stub.calls();
    expect(call!.argv[call!.argv.indexOf('--mirror') + 1]).toBe(join(root, 'moved-mirror'));
  });
});
