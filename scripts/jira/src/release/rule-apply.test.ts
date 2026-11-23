import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  apply, claim, declare, freeze, leaseAcquire, leaseRelease, operatorDecision, request, rule, state, withdraw,
  rmRun,
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
import type { EventRow, IssueSnap, RequestRow, RulingRow } from './types.js';
import { loadKey, readChain } from './ledger.js';

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
