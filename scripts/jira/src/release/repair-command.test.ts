import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { createHash } from 'node:crypto';
import { appendFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Command } from 'commander';
import { declare, leaseAcquire, operatorDecision, request, type Ctx, type JiraPort } from './engine.js';
import { appendChain, loadKey } from './ledger.js';
import { passingPr, repairRun, type RepairReport, type RepairRunOptions } from './repair-run.js';
import { registerRelease, repairGetter } from '../commands/release.js';
import type { RulingRow } from './types.js';
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
    writeFileSync(versionsPath(), 'v1.1.2\ttrue\t\tfalse\nv1.1.3\tfalse\t\tfalse\n');
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
    expect(r.lanes!.bound).toEqual(['K-2']);
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

  it('--apply is refused', async () => {
    setup();
    await expect(run({ apply: true })).rejects.toThrow('--apply is not built yet');
    const program = new Command().exitOverride();
    registerRelease(program);
    await expect(program.parseAsync(['release', 'repair', 'R1', '--apply'], { from: 'user' })).rejects.toThrow('--apply is not built yet');
  });
});
