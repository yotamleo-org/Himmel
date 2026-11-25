import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ack, apply, claim, declare, freeze, leaseAcquire, operatorDecision, recordRequestDecision, request, requestWithWords, reviewed, rule, state, withdraw,
  readMirrorFilesUnverified, rmRun,
  type Ctx, type JiraPort, type Judge,
} from './engine.js';
import { doorJudge } from './door.js';
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
import type { IssueSnap, RequestRow, RulingRow } from './types.js';
import { loadKey, readChain, writeSigned } from './ledger.js';

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

describe('a ruled-away operator ask wakes the chief', () => {
  const GOLDEN = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'fixtures', 'state-golden.json');
  const WORDS = 'Approved one more round';
  let clock = 0;
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

    it('U3: a later ask that was withdrawn leaves the standing refusal listed; a live later ask still ends it', async () => {
      await setup();
      mirror([{ key: 'K-1', fixVersions: ['v1'] }, { key: 'K-6', fixVersions: [] }, { key: 'K-8', fixVersions: [] }, { key: 'K-9', fixVersions: [] }]);
      const six = await refuseAsk('K-6');
      await refuseAsk('K-8');
      await refuseAsk('K-9');
      const mistaken = ask('K-6', { to: 'v2' });
      expect(state(ctx()).refused_asks.map((a) => a.key)).toEqual(['K-8', 'K-9']);
      withdraw(at(), { req: mistaken.req, reason: 'filed by mistake' });
      ask('K-9', { to: 'v2' });
      claim(at(rmEnv));
      ask('K-8', { to: 'v2' });
      const got = state(ctx()).refused_asks;
      expect(got.map((a) => a.key)).toEqual(['K-6']);
      expect(got[0]).toMatchObject({ ruling: six.r.id, req: six.q.req });
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
    const got = `${JSON.stringify({ ...state(ctx()), heads: { rulings: '', operator: '', events: '', requests: '', mirror: null } }, null, 2)}\n`;
    if (process.env.UPDATE_GOLDEN === '1') {
      writeFileSync(GOLDEN, got);
      expect.fail('UPDATE_GOLDEN=1 regenerated state-golden.json; review its diff, then run again without UPDATE_GOLDEN');
    }
    expect(got).toBe(readFileSync(GOLDEN, 'utf8'));
  });
});

describe('T8 V3: state says when the lease owner is provably gone', () => {
  const leaseOf = () => state(ctx()).lease as Record<string, unknown> | null;
  const hold = (pid?: number) => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1', 'v2'], decision: '106', verbatim: 'R = v1 + v2', mode: 'observe' });
    return leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1', ...(pid === undefined ? {} : { pid }) });
  };
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
  const LISTED = ['door:serious:High', 'door:mild', 'door:mild-no-next', 'door:rest-of:K-1', 'door:operator-ask', 'door:operator-ask:v1', 'door:started', 'door:operator-undeclared:v9', 'door:label:regression'];
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
    expect(s.priority_review.at(-1)?.ground).toBe('door:label:regression');
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
    expect(state(ctx()).priority_review.map((e) => e.key)).toEqual(['K-10', 'K-12', 'K-13', 'K-14', 'K-15', 'K-16', 'K-17', 'K-18']);
    const row = reviewed(ctx(), { through: id('K-14'), reason: 'checked in bulk' });
    expect(row).toMatchObject({ kind: 'reviewed', key: 'K-14', from: null, to: null, ruling: id('K-14'), through: id('K-14'), reason: 'checked in bulk' });
    const s = state(ctx());
    expect(s.priority_review.map((e) => e.key)).toEqual(['K-15', 'K-16', 'K-17', 'K-18']);
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
