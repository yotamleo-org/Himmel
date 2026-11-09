import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Command } from 'commander';
import { declare, leaseAcquire, operatorDecision, request, rmRun, type Ctx, type Judge, type JiraPort } from './engine.js';
import { appendChain, loadKey, readChain } from './ledger.js';
import { passingPr, repairRun, RequestRefused, type RepairReport, type RepairRunOptions } from './repair-run.js';
import { refuseRequest, registerRelease, repairGetter } from '../commands/release.js';
import type { RequestRow, RulingRow } from './types.js';
import type { Getter } from './version-writes.js';

let root: string;
const DOC = '/abs/rm-doc.md';
const rmEnv = { HIMMEL_RELEASE_MANAGER: '1', HIMMEL_CONSOLE_LEG: '1', HIMMEL_RM_DOC: DOC, HIMMEL_RM_RELEASE: 'R1' };
// The dry run reads Jira through the getter only; any touch of the engine's write port fails the test.
const noJira = new Proxy({}, { get: () => { throw new Error('the dry run touched the Jira port'); } }) as JiraPort;

const ctx = (env: Record<string, string> = {}, mirrorRoot: string | null = join(root, 'mirror')): Ctx => ({
  release: 'R1', dir: join(root, 'release', 'R1'), keyPath: join(root, 'keys', 'R1.key'), env, now: () => new Date('2026-11-02T10:00:00.000Z'), jira: noJira, mirrorRoot,
});

interface Mi { key: string; fixVersions: string[]; status?: string; category?: string; resolution?: string }
function mirror(issues: Mi[], lastSync = '2026-11-02T09:00:00.000Z') {
  const dir = join(root, 'mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync, total: issues.length }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, 'type: "Task"', `status: "${i.status ?? 'To Do'}"`,
      ...(i.category ? [`statusCategory: "${i.category}"`] : []), 'priority: "Medium"',
      `fixVersions: ${JSON.stringify(i.fixVersions)}`, `resolution: ${i.resolution ? JSON.stringify(i.resolution) : 'null'}`,
      'links:', '  blocks: []', '  blocked_by: []', '  relates: []', '---', '', `# ${i.key}`, '',
    ].join('\n'));
  }
}
const done = (key: string, fixVersions: string[], resolution = 'Done'): Mi => ({ key, fixVersions, status: 'Closed', category: 'Done', resolution });

function setup() {
  declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
  leaseAcquire(ctx(rmEnv), { expectEpoch: 0, doc: DOC, session: 'rm-1' });
}

const ruling = (id: string, key: string, to_v: string): RulingRow => ({
  id, epoch: 1, req: `Q-${id}`, ts: '2026-10-30T10:00:00.000Z', verb: 'INTAKE', key, op: { kind: 'add', from_v: null, to_v }, outcome: 'ADMIT', class: 'current',
  sector: 's', ground: 'g', reason: 'r', supersedes: [], authority: { kind: 'rm', ref: null }, phase: 'applied',
});
const addRuling = (row: RulingRow) => appendChain<RulingRow>(join(root, 'release', 'R1', 'rulings.jsonl'), loadKey(join(root, 'keys', 'R1.key')), row);

const journalFile = () => join(root, 'version-writes.jsonl');
const writeJournal = (rows: Array<{ key: string; mechanism: string; from: string[]; to: string[]; entry: string }>) =>
  writeFileSync(journalFile(), rows.map((r) => JSON.stringify({ ts: '2026-11-02T08:00:00.000Z', ...r })).join('\n') + '\n');

// A Jira that answers the changelog read of each key in `entries`, and 404s the rest.
function jiraGetter(entries: Record<string, string>, log: string[] = []): Getter {
  return async <T>(path: string): Promise<T> => {
    const m = /^\/issue\/([^/]+)\/changelog/.exec(path);
    if (!m) throw new Error(`unexpected read ${path}`);
    log.push(m[1]!);
    const id = entries[m[1]!];
    if (id === undefined) throw new Error('HTTP 404');
    return { maxResults: 100, total: 1, values: [{ id, created: '2026-11-02T07:00:00.000Z', items: [{ field: 'Fix Version', toString: 'v1.1.4' }] }] } as T;
  };
}

const VERSIONS = 'v1.1.2\ttrue\t2026-10-11\tfalse\nv1.1.3\tfalse\t\tfalse\nv1.1.4\tfalse\t\tfalse\n';
const versionsPath = () => `${join(root, 'mirror')}.versions.tsv`;

const pr = (number: number, title: string, mergedAt: string) => ({ number, title, mergedAt });
function ghWith(prs: Record<string, ReturnType<typeof pr>[]>, calls: string[][] = []) {
  return (args: string[]): string => {
    calls.push(args);
    const key = /^(\S+) in:title$/.exec(args[args.indexOf('--search') + 1]!)?.[1] ?? '';
    return JSON.stringify(prs[key] ?? []);
  };
}

function opts(over: Partial<RepairRunOptions> = {}): RepairRunOptions {
  return { repo: 'o/r', get: jiraGetter({}), gh: ghWith({}), journal: journalFile(), ...over };
}
const run = (over: Partial<RepairRunOptions> = {}, c: Ctx = ctx()): Promise<RepairReport> => repairRun(c, opts(over));

const savedLedger = process.env.HIMMEL_ADMISSIONS_LEDGER;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'repair-command-'));
  process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
  writeFileSync(versionsPath(), VERSIONS);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  if (savedLedger === undefined) delete process.env.HIMMEL_ADMISSIONS_LEDGER;
  else process.env.HIMMEL_ADMISSIONS_LEDGER = savedLedger;
});

describe('test-version-repair dry run', () => {
  it('mirror UNKNOWN stops the run', async () => {
    setup();
    const r = await run({}, ctx({}, null));
    expect(r).toMatchObject({ status: 'stopped', why: 'mirror-unknown' });
  });

  it('empty list on UNKNOWN is not clean', async () => {
    setup();
    const r = await run({}, ctx({}, join(root, 'no-such-mirror')));
    expect(r.status).toBe('stopped');
    expect(r.lanes).toBeUndefined();
    expect(r.stale).toBeUndefined();
  });

  it('bad ledger stops the run', async () => {
    setup();
    mirror([]);
    appendFileSync(join(root, 'release', 'R1', 'rulings.jsonl'), 'not json at all\n');
    expect(await run()).toMatchObject({ status: 'stopped', why: 'bad-input' });
  });

  it('bad requests line stops the run', async () => {
    setup();
    mirror([]);
    request(ctx(), { verb: 'INTAKE', key: 'K-1', from_v: null, to_v: 'v1.1.3', why: 'found work', evidence: {}, from: 'console' });
    appendFileSync(join(root, 'release', 'R1', 'requests.jsonl'), `${JSON.stringify({ req: 'Q-R1-0009', mac: '00' })}\n`);
    expect(await run()).toMatchObject({ status: 'stopped', why: 'bad-input' });
  });

  it('key-level integrity line stops only that key', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }, { key: 'K-2', fixVersions: ['v1.1.3'] }]);
    addRuling(ruling('R-R1-0001', 'K-3', 'v1.1.3')); // ruled in, absent from the mirror
    addRuling(ruling('R-R1-0002', 'K-4', 'v1.1.3')); // two live rulings
    addRuling(ruling('R-R1-0003', 'K-4', 'v1.1.3'));
    const r = await run();
    expect(r.status).toBe('ok');
    expect(r.stale).toEqual(['K-3', 'K-4']);
    expect(r.lanes!.held).toEqual(['K-1', 'K-2']);
  });

  it('gh calls carry --repo', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    const calls: string[][] = [];
    await run({ gh: ghWith({}, calls) });
    expect(calls).toHaveLength(1);
    expect(calls[0]![calls[0]!.indexOf('--repo') + 1]).toBe('o/r');
  });

  it('missing repo stops with bad-input', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    const calls: string[][] = [];
    expect(await run({ repo: null, gh: ghWith({}, calls) })).toMatchObject({ status: 'stopped', why: 'bad-input' });
    expect(calls).toEqual([]);
  });

  it('previous release date comes from the versions file', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3']), done('K-2', ['v1.1.3'])]);
    const gh = ghWith({
      'K-1': [pr(11, '[K-1] fix', '2026-10-20T10:00:00Z')],
      'K-2': [pr(12, '[K-2] fix', '2026-10-05T10:00:00Z')],
    });
    const r = await run({ gh });
    expect(r.lanes!.fold).toEqual(['K-1', 'K-2']);
    expect(r.classes!.find((c) => c.class === 'done-no-pr')!.keys).toEqual(['K-2']);
  });

  it('previous release with no date gives done-no-pr', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    writeFileSync(versionsPath(), 'v1.1.1\ttrue\t2026-09-01\tfalse\nv1.1.2\ttrue\t\tfalse\nv1.1.3\tfalse\t\tfalse\n');
    const calls: string[][] = [];
    const r = await run({ gh: ghWith({ 'K-1': [pr(11, '[K-1] fix', '2026-10-20T10:00:00Z')] }, calls) });
    expect(r.classes!.find((c) => c.class === 'done-no-pr')!.keys).toEqual(['K-1']);
    expect(calls).toEqual([]);
  });

  it('PR naming the key second gives done-no-pr', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    const r = await run({ gh: ghWith({ 'K-1': [pr(11, '[K-9] also K-1', '2026-10-20T10:00:00Z')] }) });
    expect(r.classes!.find((c) => c.class === 'done-no-pr')!.keys).toEqual(['K-1']);
  });

  it('PR merged before the previous release gives done-no-pr', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    const r = await run({ gh: ghWith({ 'K-1': [pr(11, '[K-1] old', '2026-10-01T10:00:00Z')] }) });
    expect(r.classes!.find((c) => c.class === 'done-no-pr')!.keys).toEqual(['K-1']);
  });

  it('a full page of PRs proves nothing and leaves the key unresolved', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]);
    const page = Array.from({ length: 50 }, (_, i) => pr(100 + i, `[K-9] other ${i}`, '2026-10-20T10:00:00Z'));
    const r = await run({ gh: ghWith({ 'K-1': page }) });
    expect(r.classes!.find((c) => c.class === 'done-no-pr')).toBeUndefined();
    expect(r.capped).toBe(true);
  });

  it('of two passing PRs the newest folds', () => {
    const listing = [pr(11, '[K-1] first', '2026-10-20T10:00:00Z'), pr(12, '[K-1] second', '2026-10-25T10:00:00Z'), pr(13, '[K-9] other', '2026-10-30T10:00:00Z')];
    expect(passingPr(listing, 'K-1', Date.parse('2026-10-11'))).toBe(12);
    expect(passingPr([], 'K-1', 0)).toBeNull();
  });

  it('dry-run JSON lists keys per lane and the held classes', async () => {
    setup();
    mirror([
      { key: 'K-1', fixVersions: ['v1.1.4'] }, done('K-2', ['v1.1.3']), done('K-3', ['v1.1.3'], "Won't Do"),
    ]);
    const r = await run({ gh: ghWith({ 'K-2': [pr(11, '[K-2] fix', '2026-10-20T10:00:00Z')] }) });
    expect(r.status).toBe('ok');
    expect(r.lanes).toMatchObject({ held: ['K-1'], fold: ['K-2'], 'closed-undelivered': ['K-3'] });
    expect(r.classes!.map((c) => c.class)).toEqual(['closed-undelivered', 'unbound']);
    expect(r.classes!.find((c) => c.class === 'unbound')!.commands).toMatchObject([{ op: 'keep', from: 'v1.1.4', to: null, keys: ['K-1'] }]);
    expect(r.capped).toBe(false);
  });

  it('dry-run JSON lists the stale keys', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }]);
    addRuling(ruling('R-R1-0001', 'K-3', 'v1.1.3'));
    const r = await run();
    expect(r.stale).toEqual(['K-3']);
    expect(r.lanes!['in-flight']).toEqual([]);
  });

  it('caps stop at 20 and report capped', async () => {
    setup();
    const keys = Array.from({ length: 25 }, (_, i) => `K-${100 + i}`);
    mirror(keys.map((k) => done(k, ['v1.1.3'])));
    const calls: string[][] = [];
    const prs = Object.fromEntries(keys.map((k, i) => [k, [pr(i + 1, `[${k}] fix`, '2026-10-20T10:00:00Z')]]));
    const r = await run({ gh: ghWith(prs, calls) });
    expect(calls).toHaveLength(20);
    expect(r.capped).toBe(true);
    expect(r.lanes!.fold).toHaveLength(25);
  });

  it('progress counts resolved lookups', async () => {
    setup();
    mirror([done('K-1', ['v1.1.3']), done('K-2', ['v1.1.3']), done('K-3', ['v1.1.3'])]);
    expect((await run({ gh: ghWith({}) })).progress).toBe(3);
    let n = 0;
    const flaky = (): string => {
      if (n++ === 1) throw new Error('gh: rate limited');
      return '[]';
    };
    const r = await run({ gh: flaky });
    expect(r).toMatchObject({ status: 'error', progress: 1 });
    expect(n).toBe(2);
  });

  it('paste rows split by op, from and to', async () => {
    setup();
    mirror([
      ...Array.from({ length: 14 }, (_, i) => done(`K-${200 + i}`, ['v1.1.3'], "Won't Do")),
      ...Array.from({ length: 5 }, (_, i) => done(`K-${300 + i}`, ['v1.1.4'], "Won't Do")),
    ]);
    const cls = (await run()).classes!.find((c) => c.class === 'closed-undelivered')!;
    expect(cls.keys).toHaveLength(19);
    expect(cls.commands.map((c) => [c.op, c.from, c.to, c.keys.length])).toEqual([['remove', 'v1.1.3', null, 14], ['remove', 'v1.1.4', null, 5]]);
    expect(cls.commands[0]!.paste).toContain('jira release operator decision R1 --decision <n> --keys K-200,');
  });

  it('new-record offer emits no paste row', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.3'] }]);
    addRuling(ruling('R-R1-0001', 'K-1', 'v1.1.4')); // ruled into v1.1.4, also an unauthorized member of v1.1.3
    const unbound = (await run()).classes!.find((c) => c.class === 'unbound')!;
    expect(unbound.keys).toEqual(['K-1']);
    expect(unbound.question.length).toBeGreaterThan(0);
    expect(unbound.commands).toEqual([]);
  });

  it('a 404 on one key goes to stale and the run continues', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }, { key: 'K-2', fixVersions: ['v1.1.4'] }]);
    writeJournal([
      { key: 'K-1', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' },
      { key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' },
    ]);
    const r = await run({ get: jiraGetter({ 'K-2': '200' }) });
    expect(r.status).toBe('ok');
    expect(r.stale).toEqual(['K-1']);
    expect(r.lanes!['in-flight']).toEqual(['K-1']);
    expect(r.lanes!.bound).toEqual(['K-2']);
  });

  it('a read that times out on a key numbered 404 stops the run', async () => {
    setup();
    mirror([{ key: 'K-404', fixVersions: ['v1.1.4'] }]);
    writeJournal([{ key: 'K-404', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' }]);
    const get = (async () => { throw new Error('read of /issue/K-404/changelog timed out'); }) as unknown as Getter;
    const r = await run({ get });
    expect(r.status).toBe('error');
    expect(r.stale).toBeUndefined();
  });

  it.each([401, 429, 503])('%i stops the run as error', async (status) => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }]);
    writeJournal([{ key: 'K-1', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' }]);
    vi.stubEnv('JIRA_BASE_URL', 'https://jira.example.test');
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status })));
    const r = await run({ get: repairGetter() });
    expect(r.status).toBe('error');
    expect(r.error).toContain(`HTTP ${status}`);
    expect(r.lanes).toBeUndefined();
  });

  it('hung read ends the run as error', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }]);
    writeJournal([{ key: 'K-1', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' }]);
    vi.stubEnv('JIRA_BASE_URL', 'https://jira.example.test');
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(() => undefined)));
    vi.useFakeTimers();
    const pending = run({ get: repairGetter() });
    await vi.advanceTimersByTimeAsync(5001);
    const r = await pending;
    expect(r.status).toBe('error');
    expect(r.error).toContain('timed out');
  });

  it('reads run one at a time', async () => {
    setup();
    const keys = ['K-1', 'K-2', 'K-3', 'K-4'];
    mirror(keys.map((k) => ({ key: k, fixVersions: ['v1.1.4'] })));
    writeJournal(keys.map((k) => ({ key: k, mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' })));
    let inFlight = 0;
    let most = 0;
    const get = async <T>(): Promise<T> => {
      most = Math.max(most, ++inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
      return { maxResults: 100, total: 1, values: [{ id: '100', created: '2026-11-02T07:00:00.000Z', items: [{ field: 'Fix Version' }] }] } as T;
    };
    await run({ get });
    expect(most).toBe(1);
  });

  it('changelog reads only for keys with a row or a naming O- row', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }, { key: 'K-2', fixVersions: ['v1.1.4'] }, { key: 'K-3', fixVersions: ['v1.1.4'] }]);
    writeJournal([{ key: 'K-1', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' }]);
    operatorDecision(ctx(), { decision: '9', keys: ['K-2'], op: 'keep', from_v: 'v1.1.4', to_v: null, verbatim: 'x' });
    const log: string[] = [];
    await run({ get: jiraGetter({ 'K-1': '100', 'K-2': '5', 'K-3': '6' }, log) });
    expect(log.sort()).toEqual(['K-1', 'K-2']);
  });

  it('dry run writes nothing', async () => {
    setup();
    mirror([{ key: 'K-1', fixVersions: ['v1.1.4'] }, done('K-2', ['v1.1.3']), done('K-3', ['v1.1.3'], "Won't Do")]);
    writeJournal([{ key: 'K-1', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '100' }]);
    writeFileSync(process.env.HIMMEL_ADMISSIONS_LEDGER!, '');
    const snapshot = (): string => {
      const out: string[] = [];
      const walk = (d: string) => {
        for (const n of readdirSync(d).sort()) {
          const p = join(d, n);
          if (statSync(p).isDirectory()) walk(p);
          else out.push(`${p} ${createHash('sha256').update(readFileSync(p)).digest('hex')}`);
        }
      };
      walk(root);
      return out.join('\n');
    };
    const before = snapshot();
    const r = await run({ get: jiraGetter({ 'K-1': '100' }), gh: ghWith({ 'K-2': [pr(11, '[K-2] fix', '2026-10-20T10:00:00Z')] }) });
    expect(r.status).toBe('ok');
    expect(snapshot()).toBe(before);
  });

  it('the command routes --apply to the fence', async () => {
    setup();
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    const program = new Command().exitOverride();
    registerRelease(program);
    await expect(program.parseAsync(['release', 'repair', 'R1', '--repo', 'o/r', '--apply'], { from: 'user' })).rejects.toThrow('refused inside a chief-spawned worker');
  });
});

// --- --apply -------------------------------------------------------------------------------------

const releaseDir = () => join(root, 'release', 'R1');
const at = (iso: string, c: Ctx = ctx()): Ctx => ({ ...c, now: () => new Date(iso) });

/** Every file under the temp root, by relative path, with its hash. */
function treeOf(): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (d: string) => {
    for (const n of readdirSync(d).sort()) {
      const p = join(d, n);
      if (statSync(p).isDirectory()) walk(p);
      else out[p.slice(root.length + 1)] = createHash('sha256').update(readFileSync(p)).digest('hex');
    }
  };
  walk(root);
  return out;
}
const changedSince = (before: Record<string, string>): string[] => {
  const now = treeOf();
  return Object.keys({ ...before, ...now }).filter((k) => before[k] !== now[k]).sort();
};

/** A Jira that answers changelog reads (entries) and live reads (the issues, as the mirror holds them). */
function liveGetter(issues: Mi[], entries: Record<string, string>, log: string[] = []): Getter {
  return async <T>(path: string): Promise<T> => {
    log.push(path);
    const cl = /^\/issue\/([^/?]+)\/changelog/.exec(path);
    if (cl) {
      const id = entries[cl[1]!];
      if (id === undefined) throw new Error('HTTP 404');
      return { maxResults: 100, total: 1, values: [{ id, created: '2026-11-02T07:00:00.000Z', items: [{ field: 'Fix Version', toString: 'v1.1.4' }] }] } as T;
    }
    const live = /^\/issue\/([^/?]+)\?fields=/.exec(path);
    if (live) {
      const i = issues.find((x) => x.key === live[1]);
      if (!i) throw new Error('HTTP 404');
      return {
        fields: {
          fixVersions: i.fixVersions.map((name) => ({ name })),
          status: { name: i.status ?? 'To Do', statusCategory: { key: i.category === 'Done' ? 'done' : 'new' } },
          resolution: i.resolution ? { name: i.resolution } : null,
        },
      } as T;
    }
    throw new Error(`unexpected read ${path}`);
  };
}

const applyOpts = (over: Partial<RepairRunOptions> = {}): RepairRunOptions => opts({ apply: true, refuse: refuseRequest, ...over });
const applyRun = (over: Partial<RepairRunOptions> = {}, c: Ctx = ctx()): Promise<RepairReport> => repairRun(c, applyOpts(over));
const readRows = (name: string): Array<Record<string, unknown>> => {
  const p = join(releaseDir(), name);
  return existsSync(p) ? readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l) as Record<string, unknown>) : [];
};
const heldJson = (): { held: number; unfiled: number; held_signature: string; classes: Array<{ class: string; keys: string[] }> } =>
  JSON.parse(readFileSync(join(releaseDir(), 'repair-held.json'), 'utf8'));
const GOOD_PR = { 'K-3': [pr(11, '[K-3] fix', '2026-10-20T10:00:00Z')] };

// K-2: a machine write put it in v1.1.4 and no ruling places it there (one INTAKE request to file).
const filing = (): Mi[] => {
  setup();
  const issues = [{ key: 'K-2', fixVersions: ['v1.1.4'] }];
  mirror(issues);
  writeJournal([{ key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' }]);
  return issues;
};
// K-3: Done in v1.1.3 with a merged PR (one fold to write).
const folding = (): Mi[] => {
  setup();
  const issues = [done('K-3', ['v1.1.3'])];
  mirror(issues);
  return issues;
};

describe('test-version-repair apply', () => {
  it('apply path makes no Fix Version write', async () => {
    const issues = [...filing(), done('K-3', ['v1.1.3'])];
    mirror(issues);
    vi.stubEnv('JIRA_BASE_URL', 'https://jira.example.test');
    const inner = liveGetter(issues, { 'K-2': '200' });
    const methods: string[] = [];
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: { method?: string }) => {
      const method = init?.method ?? 'GET';
      methods.push(method);
      if (method !== 'GET') return new Response('{}', { status: 500 });
      try {
        return new Response(JSON.stringify(await inner(String(url).replace('https://jira.example.test/rest/api/3', ''))), { status: 200 });
      } catch {
        return new Response('{}', { status: 404 });
      }
    }));
    const r = await applyRun({ get: repairGetter(), gh: ghWith(GOOD_PR) }); // the context's port throws on any touch
    expect(r.status).toBe('ok');
    expect(methods.length).toBeGreaterThan(0);
    expect(methods.every((m) => m === 'GET')).toBe(true);
    expect(readRows('requests.jsonl')).toHaveLength(1);
    expect(readRows('events.jsonl')).toHaveLength(1);
  });

  it('apply changes only the allowed files', async () => {
    const issues = [...filing(), done('K-3', ['v1.1.3']), { key: 'K-1', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    const before = treeOf();
    const r = await applyRun({ get: liveGetter(issues, { 'K-2': '200' }), gh: ghWith(GOOD_PR) });
    expect(r.status).toBe('ok');
    const allowed = ['requests.jsonl', 'events.jsonl', 'repair-held.json', 'repair-pr-cache.json', 'repair-reviewed'].map((n) => `release/R1/${n}`);
    expect(changedSince(before)).toEqual([...allowed].sort());
  });

  it('fence set: apply writes no bytes', async () => {
    filing();
    const before = treeOf();
    await expect(repairRun(ctx(rmEnv), applyOpts())).rejects.toThrow('refused inside a chief-spawned worker');
    expect(changedSince(before)).toEqual([]);
  });

  it('busy lock exits 0 and touches nothing', async () => {
    const issues = filing();
    writeFileSync(join(releaseDir(), 'repair.lock'), `${process.pid}\n`);
    writeFileSync(join(releaseDir(), 'repair-status'), 'error\nold\n');
    writeFileSync(join(releaseDir(), 'repair-signature'), 'abc\n');
    const before = treeOf();
    expect(await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) })).toEqual({ status: 'busy' });
    expect(changedSince(before)).toEqual([]);
  });

  it('a lock held by another live pid is left alone', async () => {
    const issues = filing();
    writeFileSync(join(releaseDir(), 'repair.lock'), `${process.ppid}\n`);
    const before = treeOf();
    expect(await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) })).toEqual({ status: 'busy' });
    expect(changedSince(before)).toEqual([]);
  });

  it('a stale lock is taken and hand apply holds the lock while it runs', async () => {
    const issues = filing();
    const dead = spawnSync('true').pid!;
    writeFileSync(join(releaseDir(), 'repair.lock'), `${dead}\n`);
    const inner = liveGetter(issues, { 'K-2': '200' });
    const owners: string[] = [];
    const get = (async (path: string) => {
      owners.push(readFileSync(join(releaseDir(), 'repair.lock'), 'utf8').trim());
      return inner(path);
    }) as Getter;
    expect((await applyRun({ get })).status).toBe('ok');
    expect(new Set(owners)).toEqual(new Set([String(process.pid)]));
    expect(existsSync(join(releaseDir(), 'repair.lock'))).toBe(false);
  });

  it('apply refuses a disabled journal', async () => {
    filing();
    const before = treeOf();
    await expect(repairRun(ctx({ NODE_ENV: 'test' }), { ...applyOpts(), journal: undefined })).rejects.toThrow('needs the version-writes journal');
    expect(changedSince(before)).toEqual([]);
  });

  it('gh failure still finishes non-gh work and ends error', async () => {
    const issues = [...filing(), done('K-3', ['v1.1.3'])];
    mirror(issues);
    writeFileSync(join(releaseDir(), 'repair-signature'), 'abc\n');
    const r = await applyRun({ get: liveGetter(issues, { 'K-2': '200' }), gh: () => { throw new Error('gh: rate limited'); } });
    expect(r.status).toBe('error');
    expect(readRows('requests.jsonl')).toHaveLength(1);
    expect(readRows('events.jsonl')).toHaveLength(0);
    expect(readFileSync(join(releaseDir(), 'repair-status'), 'utf8').split('\n')[0]).toBe('error');
    expect(existsSync(join(releaseDir(), 'repair-signature'))).toBe(false);
    expect(existsSync(join(releaseDir(), 'repair-reviewed'))).toBe(false);
  });

  it('gh failure is not looked up yet and is not cached', async () => {
    const issues = folding();
    await applyRun({ get: liveGetter(issues, {}), gh: () => { throw new Error('gh down'); } });
    expect(existsSync(join(releaseDir(), 'repair-pr-cache.json'))).toBe(false);
    expect(heldJson().classes.map((c) => c.class)).not.toContain('done-no-pr');
  });

  it('move offer files through refuseRequest as INTAKE', () => {
    setup();
    mirror([done('K-1', ['v1.1.3'])]); // the 7804 shape: Done in v1.1.3, ruled into v1.1.4
    const row = { key: 'K-1', why: 'merge-stamp stripped K-1 from v1.1.4 and no ruling places it' };
    expect(() => refuseRequest(ctx(), { ...row, verb: 'INTAKE', from_v: 'v1.1.4' })).not.toThrow();
    expect(() => refuseRequest(ctx(), { ...row, verb: 'REVERSION', from_v: 'v1.1.4' })).toThrow('not v1.1.4');
  });

  it('a stop writes repair-status with its reason', async () => {
    setup();
    const r = await applyRun({}, ctx({}, null));
    expect(r).toMatchObject({ status: 'stopped', why: 'mirror-unknown' });
    expect(readFileSync(join(releaseDir(), 'repair-status'), 'utf8').split('\n')[0]).toBe('mirror-unknown');
    const r2 = await applyRun({ repo: null });
    expect(r2).toMatchObject({ status: 'stopped', why: 'bad-input' });
    expect(readFileSync(join(releaseDir(), 'repair-status'), 'utf8').split('\n')[0]).toBe('bad-input');
    expect(existsSync(join(releaseDir(), 'repair-reviewed'))).toBe(false); // a stopped first apply does not switch the tick on
    expect(existsSync(join(releaseDir(), 'repair.lock'))).toBe(false);
  });

  it('uncaught throw writes repair-status error and errored run clears the run signature', async () => {
    filing();
    writeFileSync(join(releaseDir(), 'repair-signature'), 'abc\n');
    mkdirSync(join(root, 'journal-is-a-dir'));
    const r = await applyRun({ journal: join(root, 'journal-is-a-dir') });
    expect(r.status).toBe('error');
    expect(readFileSync(join(releaseDir(), 'repair-status'), 'utf8')).toMatch(/^error\n.+/);
    expect(existsSync(join(releaseDir(), 'repair-signature'))).toBe(false);
    expect(existsSync(join(releaseDir(), 'repair.lock'))).toBe(false);
  });

  it('clean run clears repair-status and writes the review marker last', async () => {
    const issues = filing();
    writeFileSync(join(releaseDir(), 'repair-status'), 'error\nold\n');
    writeFileSync(join(releaseDir(), 'repair-signature'), 'abc\n');
    expect((await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) })).status).toBe('ok');
    expect(existsSync(join(releaseDir(), 'repair-status'))).toBe(false);
    expect(existsSync(join(releaseDir(), 'repair-reviewed'))).toBe(true);
    expect(existsSync(join(releaseDir(), 'repair-signature'))).toBe(true); // an uncapped clean run keeps it
  });

  it('no refile in a run whose Jira reads fail', async () => {
    const issues = filing();
    writeFileSync(join(releaseDir(), 'repair-signature'), 'abc\n');
    const down = (status: number, over: (path: string) => boolean): Getter => (async (path: string) => {
      if (over(path)) throw new Error(`HTTP ${status}`);
      return liveGetter(issues, { 'K-2': '200' })(path);
    }) as Getter;
    // the changelog read fails: nothing is classified, nothing filed
    expect((await applyRun({ get: down(503, (p) => p.includes('/changelog')) })).status).toBe('error');
    expect(readRows('requests.jsonl')).toHaveLength(0);
    // the live read fails: nothing is filed either
    const r = await applyRun({ get: down(429, (p) => p.includes('?fields=')) });
    expect(r.status).toBe('error');
    expect(r.error).toContain('HTTP 429');
    expect(readRows('requests.jsonl')).toHaveLength(0);
    expect(existsSync(join(releaseDir(), 'repair-signature'))).toBe(false);
  });

  it('apply folds with PR from gh, and a second run reuses the PR cache', async () => {
    const issues = folding();
    // the live read disagrees (the key is no longer Done there): the PR is cached, nothing is folded
    const notDone = [{ ...issues[0]!, category: 'To Do' }];
    expect((await applyRun({ get: liveGetter(notDone, {}), gh: ghWith(GOOD_PR) })).status).toBe('ok');
    expect(readRows('events.jsonl')).toHaveLength(0);
    expect(JSON.parse(readFileSync(join(releaseDir(), 'repair-pr-cache.json'), 'utf8'))['K-3']).toMatchObject({ pr: 11 });
    // the second run looks nothing up and folds
    const calls: string[][] = [];
    expect((await applyRun({ get: liveGetter(issues, {}), gh: ghWith({}, calls) })).status).toBe('ok');
    expect(calls).toEqual([]);
    expect(readRows('events.jsonl')).toMatchObject([{ kind: 'fold', key: 'K-3', to: 'v1.1.3', pr: 11 }]);
  });

  it('no PR lands in done-no-pr and a fresh no-PR is not looked up again', async () => {
    const issues = folding();
    const calls: string[][] = [];
    await applyRun({ get: liveGetter(issues, {}), gh: ghWith({}, calls) });
    expect(calls).toHaveLength(1);
    expect(heldJson().classes).toMatchObject([{ class: 'done-no-pr', keys: ['K-3'] }]);
    expect(JSON.parse(readFileSync(join(releaseDir(), 'repair-pr-cache.json'), 'utf8'))['K-3']).toMatchObject({ pr: null });
    await applyRun({ get: liveGetter(issues, {}), gh: ghWith({}, calls) });
    expect(calls).toHaveLength(1);
  });

  it('expired no-PR is looked up again', async () => {
    const issues = folding();
    writeFileSync(join(releaseDir(), 'repair-pr-cache.json'), JSON.stringify({ 'K-3': { pr: null, at: '2026-11-01T09:00:00.000Z', repo: 'o/r' } }));
    const calls: string[][] = [];
    await applyRun({ get: liveGetter(issues, {}), gh: ghWith(GOOD_PR, calls) });
    expect(calls).toHaveLength(1);
    expect(readRows('events.jsonl')).toMatchObject([{ kind: 'fold', key: 'K-3', pr: 11 }]);
  });

  it('a PR cached for another repo is looked up again', async () => {
    const issues = folding();
    writeFileSync(join(releaseDir(), 'repair-pr-cache.json'), JSON.stringify({ 'K-3': { pr: 99, at: '2026-11-02T09:00:00.000Z', repo: 'other/repo' } }));
    const calls: string[][] = [];
    await applyRun({ get: liveGetter(issues, {}), gh: ghWith(GOOD_PR, calls) });
    expect(calls).toHaveLength(1);
    expect(readRows('events.jsonl')).toMatchObject([{ kind: 'fold', key: 'K-3', pr: 11 }]);
    expect(JSON.parse(readFileSync(join(releaseDir(), 'repair-pr-cache.json'), 'utf8'))['K-3']).toMatchObject({ pr: 11, repo: 'o/r' });
  });

  it('25 expired no-PR entries keep the held signature stable', async () => {
    setup();
    const keys = Array.from({ length: 25 }, (_, i) => `K-${100 + i}`);
    const issues = keys.map((k) => done(k, ['v1.1.3']));
    mirror(issues);
    writeFileSync(join(releaseDir(), 'repair-pr-cache.json'), JSON.stringify(Object.fromEntries(keys.map((k) => [k, { pr: null, at: '2026-11-01T09:00:00.000Z', repo: 'o/r' }]))));
    const calls: string[][] = [];
    const get = liveGetter(issues, {});
    const r1 = await applyRun({ get, gh: ghWith({}, calls) });
    expect(calls).toHaveLength(20);
    expect(r1.capped).toBe(true); // five were not looked up again
    const first = heldJson();
    expect(first.classes).toMatchObject([{ class: 'done-no-pr' }]);
    expect(first.classes[0]!.keys).toHaveLength(25);
    await applyRun({ get, gh: ghWith({}, calls) });
    expect(heldJson().held_signature).toBe(first.held_signature);
    expect(heldJson().held).toBe(25);
  });

  it('capped run with progress clears the run signature, with no progress leaves it', async () => {
    setup();
    const keys = Array.from({ length: 25 }, (_, i) => `K-${100 + i}`);
    const issues = keys.map((k) => done(k, ['v1.1.3']));
    mirror(issues);
    const sig = join(releaseDir(), 'repair-signature');
    writeFileSync(sig, 'abc\n');
    const page = Array.from({ length: 50 }, (_, i) => pr(900 + i, `[K-9] other ${i}`, '2026-10-20T10:00:00Z'));
    const stuck = await applyRun({ get: liveGetter(issues, {}), gh: ghWith(Object.fromEntries(keys.map((k) => [k, page]))) });
    expect(stuck).toMatchObject({ status: 'ok', capped: true, progress: 0 });
    expect(existsSync(sig)).toBe(true);
    const prs = Object.fromEntries(keys.map((k, i) => [k, [pr(i + 1, `[${k}] fix`, '2026-10-20T10:00:00Z')]]));
    const moved = await applyRun({ get: liveGetter(issues, {}), gh: ghWith(prs) });
    expect(moved).toMatchObject({ status: 'ok', capped: true });
    expect(moved.progress).toBeGreaterThan(0);
    expect(existsSync(sig)).toBe(false);
  });

  it('second run appends nothing', async () => {
    const issues = [...filing(), done('K-3', ['v1.1.3'])];
    mirror(issues);
    const get = liveGetter(issues, { 'K-2': '200' });
    await applyRun({ get, gh: ghWith(GOOD_PR) });
    const bytes = (): string[] => ['requests.jsonl', 'events.jsonl', 'rulings.jsonl', 'operator.jsonl'].map((n) => (existsSync(join(releaseDir(), n)) ? readFileSync(join(releaseDir(), n), 'utf8') : ''));
    const before = bytes();
    expect(readRows('requests.jsonl')).toHaveLength(1);
    await applyRun({ get, gh: ghWith(GOOD_PR) });
    expect(bytes()).toEqual(before);
  });

  it('live read disagreeing skips the key, fold included', async () => {
    const issues = [...filing(), done('K-3', ['v1.1.3'])];
    mirror(issues);
    const moved = [{ key: 'K-2', fixVersions: ['v1.1.3'] }, { ...done('K-3', ['v1.1.3']), category: 'To Do' }];
    const r = await applyRun({ get: liveGetter(moved, { 'K-2': '200' }), gh: ghWith(GOOD_PR) });
    expect(r.status).toBe('ok');
    expect(readRows('requests.jsonl')).toHaveLength(0);
    expect(readRows('events.jsonl')).toHaveLength(0);
    // a newer Fix Version entry that lands between the plan and the action skips the request too
    const inner = liveGetter(issues, { 'K-2': '200' });
    let changelogReads = 0;
    const racing = (async (path: string) => (path.includes('/changelog') && ++changelogReads > 1
      ? liveGetter(issues, { 'K-2': '201' })(path)
      : inner(path))) as Getter;
    expect(await applyRun({ get: racing, gh: ghWith(GOOD_PR) })).toMatchObject({ status: 'ok' });
    expect(changelogReads).toBe(2);
    expect(readRows('requests.jsonl')).toHaveLength(0);
  });

  it('keys whose live read disagrees do not use up the cap, so a later key is still filed', async () => {
    setup();
    const keys = [...Array.from({ length: 20 }, (_, i) => `K-${10 + i}`), 'K-30'];
    const issues = keys.map((key) => ({ key, fixVersions: ['v1.1.4'] }));
    mirror(issues);
    writeJournal(keys.map((key, i) => ({ key, mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: String(100 + i) })));
    const entries = Object.fromEntries(keys.map((key, i) => [key, String(100 + i)]));
    const live = issues.map((i) => (i.key === 'K-30' ? i : { ...i, fixVersions: ['v1.1.3'] })); // the first 20 moved since the mirror
    const r = await applyRun({ get: liveGetter(live, entries) });
    expect(r.status).toBe('ok');
    expect(readRows('requests.jsonl').map((x) => x.key)).toEqual(['K-30']);
  });

  it('a fold is skipped when the mirror reads Done and live Jira reads Won\'t Do', async () => {
    const issues = folding();
    const r = await applyRun({ get: liveGetter([done('K-3', ['v1.1.3'], "Won't Do")], {}), gh: ghWith(GOOD_PR) });
    expect(r.status).toBe('ok');
    expect(readRows('events.jsonl')).toHaveLength(0);
    // the same key folds when live Jira still reads Done
    await applyRun({ get: liveGetter(issues, {}), gh: ghWith(GOOD_PR) });
    expect(readRows('events.jsonl')).toHaveLength(1);
  });

  it('a request is skipped when live Jira reads another status than the mirror', async () => {
    const issues = filing();
    const r = await applyRun({ get: liveGetter([{ key: 'K-2', fixVersions: ['v1.1.4'], status: 'In Progress' }], { 'K-2': '200' }) });
    expect(r.status).toBe('ok');
    expect(readRows('requests.jsonl')).toHaveLength(0);
    await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) });
    expect(readRows('requests.jsonl')).toHaveLength(1);
  });

  it('a held request whose entry moved is withdrawn, and the next run files a new one instead of reading it as asked', async () => {
    setup();
    const issues = [{ key: 'K-2', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    writeJournal([
      { key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' },
      { key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '201' },
    ]);
    const filed = request(at('2026-11-02T10:00:00.000Z'), { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1.1.4', why: 'create-residual put K-2 in v1.1.4', evidence: { rule: 'version-repair', entry: '200' }, from: 'repair' });
    const key = loadKey(join(root, 'keys', 'R1.key'));
    const { prev: _p, mac: _m, ...rest } = readChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), key).verified[0]!;
    appendChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), key, { ...rest, ts: '2026-11-02T10:00:00.000Z', state: 'held', reason: 'no sector' });
    const get = liveGetter(issues, { 'K-2': '201' });
    await applyRun({ get }, at('2026-11-02T12:00:00.000Z'));
    const mine = readRows('requests.jsonl').filter((q) => q.req === filed.req).at(-1)!;
    expect(mine).toMatchObject({ state: 'withdrawn:repair', reason: 'held-entry-moved' });
    await applyRun({ get }, at('2026-11-02T13:00:00.000Z'));
    const latest = new Map(readRows('requests.jsonl').map((q) => [q.req, q]));
    const open = [...latest.values()].filter((q) => q.state === 'open');
    expect(open.map((q) => (q.evidence as { entry: string }).entry)).toEqual(['201']);
    expect(heldJson().classes).toEqual([]);
  });

  it('files at most 20 requests in a run, the rest on the next', async () => {
    setup();
    const keys = Array.from({ length: 25 }, (_, i) => `K-${100 + i}`);
    const issues = keys.map((k) => ({ key: k, fixVersions: ['v1.1.4'] }));
    mirror(issues);
    writeJournal(keys.map((k, i) => ({ key: k, mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: String(300 + i) })));
    const get = liveGetter(issues, Object.fromEntries(keys.map((k, i) => [k, String(300 + i)])));
    const first = await applyRun({ get });
    expect(first.capped).toBe(true);
    expect(readRows('requests.jsonl')).toHaveLength(20);
    await applyRun({ get });
    expect(readRows('requests.jsonl')).toHaveLength(25);
  });

  it('folds at most 20 keys in a run, the rest on the next', async () => {
    setup();
    const keys = Array.from({ length: 25 }, (_, i) => `K-${100 + i}`);
    const issues = keys.map((k) => done(k, ['v1.1.3']));
    mirror(issues);
    writeFileSync(join(releaseDir(), 'repair-pr-cache.json'), JSON.stringify(Object.fromEntries(keys.map((k, i) => [k, { pr: 500 + i, at: '2026-11-02T09:00:00.000Z', repo: 'o/r' }]))));
    const get = liveGetter(issues, {});
    const first = await applyRun({ get });
    expect(first.capped).toBe(true);
    expect(readRows('events.jsonl')).toHaveLength(20);
    await applyRun({ get });
    expect(readRows('events.jsonl')).toHaveLength(25);
  });

  it('a read error inside the refuse check is an error, not a refusal', async () => {
    const issues = filing();
    const r = await applyRun({ get: liveGetter(issues, { 'K-2': '200' }), refuse: () => { throw new Error('mirror unreadable'); } });
    expect(r.status).toBe('error');
    expect(readRows('requests.jsonl')).toHaveLength(0);
  });

  it('unbound edit appears in repair-held.json as unbound', async () => {
    setup();
    const issues = [{ key: 'K-1', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    await applyRun({ get: liveGetter(issues, {}) });
    const h = heldJson();
    expect(h.classes).toMatchObject([{ class: 'unbound', keys: ['K-1'] }]);
    expect(h).toMatchObject({ held: 1, unfiled: 0 });
    expect(h.held_signature).toMatch(/^[0-9a-f]{64}$/);
  });

  it('refused filing falls through to held', async () => {
    const issues = filing();
    const r = await applyRun({ get: liveGetter(issues, { 'K-2': '200' }), refuse: () => { throw new RequestRefused('refused'); } });
    expect(r.status).toBe('ok');
    expect(readRows('requests.jsonl')).toHaveLength(0);
    expect(heldJson().classes).toMatchObject([{ class: 'unbound', keys: ['K-2'] }]);
    expect(r.lanes!.held).toEqual(['K-2']);
  });

  it('a closed displaced key reads its terminal from the mirror in the dry run and in apply', async () => {
    setup();
    const issues = [{ key: 'K-5', fixVersions: [], status: 'Closed', category: 'Done', resolution: "Won't Do" }];
    mirror(issues);
    writeJournal([{ key: 'K-5', mechanism: 'displace-residual', from: ['v1.1.3'], to: [], entry: '500' }]);
    const get = liveGetter(issues, { 'K-5': '500' });
    const dry = await run({ get });
    expect(dry.lanes!['closed-undelivered']).toEqual(['K-5']);
    const applied = await applyRun({ get });
    expect(applied.lanes).toEqual(dry.lanes);
    expect(readRows('requests.jsonl')).toHaveLength(0);
  });

  it('agreeing answer: operator is not asked again', async () => {
    const issues = filing();
    const asked = at('2026-11-02T10:00:00.000Z');
    const answered = at('2026-11-02T11:00:00.000Z');
    const filed = request(asked, { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1.1.4', why: 'create-residual put K-2 in v1.1.4', evidence: { rule: 'version-repair', entry: '200' }, from: 'repair' });
    const { prev: _p, mac: _m, ...rest } = readChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), loadKey(join(root, 'keys', 'R1.key'))).verified[0]!;
    appendChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), loadKey(join(root, 'keys', 'R1.key')), { ...rest, ts: asked.now().toISOString(), state: 'held', reason: 'no sector' });
    operatorDecision(answered, { decision: '300', keys: ['K-2'], op: 'add', from_v: null, to_v: 'v1.1.4', verbatim: 'yes, v1.1.4' });
    const r = await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) }, at('2026-11-02T12:00:00.000Z'));
    expect(r.status).toBe('ok');
    const states = readRows('requests.jsonl').filter((q) => q.req === filed.req).map((q) => q.state);
    expect(states.at(-1)).toBe('withdrawn:repair');
    expect(heldJson().classes).toEqual([]);
    expect(heldJson().unfiled).toBe(1);
  });

  it('agreeing answer: an unresolved request is not asked again either', async () => {
    const issues = filing();
    const asked = at('2026-11-02T10:00:00.000Z');
    const filed = request(asked, { verb: 'INTAKE', key: 'K-2', from_v: null, to_v: 'v1.1.4', why: 'create-residual put K-2 in v1.1.4', evidence: { rule: 'version-repair', entry: '200' }, from: 'repair' });
    const key = loadKey(join(root, 'keys', 'R1.key'));
    const { prev: _p, mac: _m, ...rest } = readChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), key).verified[0]!;
    appendChain<RequestRow>(join(releaseDir(), 'requests.jsonl'), key, { ...rest, ts: asked.now().toISOString(), state: 'refused:1', reason: 'the judge refused' });
    // before the answer the key is rm-unresolved: the operator is asked
    await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) }, at('2026-11-02T10:30:00.000Z'));
    expect(heldJson().classes).toMatchObject([{ class: 'rm-unresolved', keys: ['K-2'] }]);
    operatorDecision(at('2026-11-02T11:00:00.000Z'), { decision: '300', keys: ['K-2'], op: 'add', from_v: null, to_v: 'v1.1.4', verbatim: 'yes, v1.1.4' });
    await applyRun({ get: liveGetter(issues, { 'K-2': '200' }) }, at('2026-11-02T12:00:00.000Z'));
    expect(heldJson().classes).toEqual([]);
    expect(heldJson().unfiled).toBe(1);
    expect(readRows('requests.jsonl').filter((q) => q.req === filed.req).at(-1)!.state).toBe('refused:1');
  });
});

// --- the repair through the real release manager ------------------------------------------------

class Port implements JiraPort {
  fv = new Map<string, string[]>();
  entries = new Map<string, string>();
  down = false;
  posted = 0;
  bodies: string[] = [];
  writes: string[] = [];
  private up(): void { if (this.down) throw new Error('HTTP 503'); }
  async fixVersions(key: string) { this.up(); return [...(this.fv.get(key) ?? [])]; }
  async newestFixVersionEntry(key: string) { this.up(); return { id: this.entries.get(key) ?? 'create', ts: '' }; }
  async setFixVersion(key: string, op: 'add' | 'remove', version: string) {
    this.up();
    this.writes.push(`${op} ${key} ${version}`);
    const cur = this.fv.get(key) ?? [];
    this.fv.set(key, op === 'add' ? [...new Set([...cur, version])] : cur.filter((x) => x !== version));
  }
  async findComment() { return null; }
  async addComment(_key: string, body: string) { this.bodies.push(body); return String(++this.posted); }
  async labels() { return []; }
  async removeLabels() { }
}

// The release manager's stand-in: rules every request as the repair filed it, superseding the key's earlier rulings.
const rmJudge: Judge = async (input) => input.requests.map((q) => ({
  req: q.req, outcome: q.verb === 'REVERSION' ? 'MOVE' : 'ADMIT', op: q.verb === 'REVERSION' ? 'move' as const : 'add' as const, from: q.from_v, to: q.to_v,
  sector: 'Planning & tracking', ground: 'machine drift', reason: 'a machine write the ruling did not cover',
  supersedes: input.rulings.filter((r) => r.key === q.key && (r.phase === 'applied' || r.phase === 'receipted')).map((r) => r.id),
}));

const rmCtx = (port: Port): Ctx => ({ ...ctx(), jira: port });
const requestStates = (): string[] => readRows('requests.jsonl').map((q) => `${q.req}:${q.state}${q.reason ? `:${q.reason}` : ''}`);

describe('test-version-repair apply through the release manager', () => {
  it('machine drift through rmRun and apply', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    const issues = [{ key: 'K-2', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    writeJournal([{ key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' }]);
    const port = new Port();
    port.fv.set('K-2', ['v1.1.3']);
    port.entries.set('K-2', '200');
    const log = vi.spyOn(console, 'log').mockImplementation(() => undefined);
    const get = liveGetter(issues, { 'K-2': '200' });
    expect((await applyRun({ get }, rmCtx(port))).lanes!.bound).toEqual(['K-2']);
    const lines = await rmRun(rmCtx(port), rmJudge);
    expect(lines.join('\n')).toMatch(/R-R1-0001/);
    expect(port.writes).toEqual(['add K-2 v1.1.4']); // apply() writes through the port, the repair never does
    expect(port.bodies).toHaveLength(1); // the engine's receipt; the repair posted no comment
    expect(port.bodies[0]).toContain('[release-ruling R-R1-0001]');
    const after = await applyRun({ get }, rmCtx(port));
    expect(after.lanes!.bound).toEqual([]);
    expect(Object.values(after.lanes!).flat()).toEqual([]);
    expect(log).not.toHaveBeenCalled(); // no alert line
    log.mockRestore();
  });

  it('stripped RM-ruled key through rmRun is restored', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    const issues = [{ key: 'K-4', fixVersions: ['v1.1.3'] }];
    mirror(issues);
    addRuling({ ...ruling('R-R1-0001', 'K-4', 'v1.1.4'), phase: 'receipted' });
    writeJournal([{ key: 'K-4', mechanism: 'merge-stamp', from: ['v1.1.4'], to: ['v1.1.3'], entry: '400' }]);
    const port = new Port();
    port.fv.set('K-4', ['v1.1.3']);
    port.entries.set('K-4', '400');
    const get = liveGetter(issues, { 'K-4': '400' });
    expect((await applyRun({ get }, rmCtx(port))).lanes!['bound-ruled']).toEqual(['K-4']);
    expect(readRows('requests.jsonl')).toMatchObject([{ verb: 'REVERSION', key: 'K-4', from_v: 'v1.1.3', to_v: 'v1.1.4', evidence: { rule: 'version-repair', entry: '400' } }]);
    await rmRun(rmCtx(port), rmJudge);
    expect(port.fv.get('K-4')).toEqual(expect.arrayContaining(['v1.1.4']));
    expect(port.writes).toContain('add K-4 v1.1.4');
  });

  it('outage: no key reaches the operator until the cap is spent', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    const issues = [{ key: 'K-2', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    writeJournal([{ key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' }]);
    const port = new Port();
    port.entries.set('K-2', '200'); // Jira never got v1.1.4: every ruling is untouched until it lands
    const get = liveGetter(issues, { 'K-2': '200' });
    const withdrawals = (): number => requestStates().filter((s) => s.endsWith(':withdrawn:repair:never-landed')).length;
    const cycle = async () => {
      await applyRun({ get }, rmCtx(port)); // files, unless a refile is already open
      port.down = true;
      await rmRun(rmCtx(port), rmJudge); // the ruling reaches intent, the apply read fails
      port.down = false;
      await rmRun(rmCtx(port), rmJudge); // the next epoch finds the version untouched: never-landed
    };
    for (let n = 1; n <= 3; n++) {
      await cycle();
      expect(withdrawals()).toBe(n);
      await applyRun({ get }, rmCtx(port)); // a refile, not a question for the operator
      expect(heldJson().classes).toEqual([]);
    }
    await cycle(); // the fourth never-landed withdrawal
    expect(withdrawals()).toBe(4);
    await applyRun({ get }, rmCtx(port));
    expect(heldJson().classes).toMatchObject([{ class: 'rm-unresolved', keys: ['K-2'] }]);
  });

  it('outage: a recovery before the cap ends applied with no held entry', async () => {
    declare(ctx(), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '106', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    const issues = [{ key: 'K-2', fixVersions: ['v1.1.4'] }];
    mirror(issues);
    writeJournal([{ key: 'K-2', mechanism: 'create-residual', from: [], to: ['v1.1.4'], entry: '200' }]);
    const port = new Port();
    port.entries.set('K-2', '200');
    const get = liveGetter(issues, { 'K-2': '200' });
    await applyRun({ get }, rmCtx(port));
    port.down = true;
    await rmRun(rmCtx(port), rmJudge);
    port.down = false;
    await rmRun(rmCtx(port), rmJudge); // never-landed
    await applyRun({ get }, rmCtx(port)); // refiled
    await rmRun(rmCtx(port), rmJudge); // reads are back: it lands
    expect(port.writes).toEqual(['add K-2 v1.1.4']);
    await applyRun({ get }, rmCtx(port));
    expect(heldJson().classes).toEqual([]);
    expect(requestStates().some((s) => /:ruled:/.test(s))).toBe(true);
  });
});
