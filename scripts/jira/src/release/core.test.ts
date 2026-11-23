import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

vi.mock('../client.js', () => ({ request: vi.fn(), projectKey: vi.fn(() => 'HIMMEL') }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { registerRelease } from '../commands/release.js';
import { alternativesOf, coreMatch, deadAlternatives, loadCorePatterns, pathIndependentBypass, sizeGuard } from './core.js';
import { readSignerState } from './engine-core.js';
import type { SignerState } from './signer.js';
import type { IssueSnap, OperatorRow } from './types.js';

// scripts/jira/src/release -> repo root
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
const corePathsFile = join(repoRoot, 'scripts', 'ci', 'core-paths.txt');
const tracked = execFileSync('git', ['ls-files'], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  .split('\n').filter(Boolean);

type Snap = { key: string; type?: string; priority?: string; labels?: string[] };

// A Jira mirror directory holding one file per issue.
function mirrorOf(issues: Snap[], cursor?: object | null): string {
  const dir = mkdtempSync(join(tmpdir(), 'core-mirror-'));
  const cur = cursor === undefined ? { lastSync: '2026-11-01T00:00:00.000Z' } : cursor;
  if (cur) writeFileSync(join(dir, '.cursor.json'), JSON.stringify(cur));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), [
      '---', `key: "${i.key}"`, `type: "${i.type ?? 'Story'}"`, `priority: "${i.priority ?? 'Medium'}"`,
      `labels: ${JSON.stringify(i.labels ?? [])}`, '---', '',
    ].join('\n'));
  }
  return dir;
}

let out: string[];

async function run(...args: string[]) {
  const p = new Command();
  p.exitOverride();
  registerRelease(p);
  await p.parseAsync(['node', 'jira', 'release', ...args]);
}

beforeEach(() => {
  out = [];
  vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
  // core-check reads the operator records of every declared release; none by default.
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', mkdtempSync(join(tmpdir(), 'core-no-release-')));
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe('coreMatch', () => {
  const patterns = loadCorePatterns(corePathsFile);

  it('core-check answers from the issue files when the cursor is absent or incomplete, never UNKNOWN', async () => {
    const path = 'scripts/handover/merge-on-green.sh';
    await run('core-check', '--paths', path, '--mirror', mirrorOf([{ key: 'K-1' }], null), '--key', 'K-1');
    await run('core-check', '--paths', path, '--mirror', mirrorOf([{ key: 'K-1' }], { lastSync: '2026-11-01T00:00:00.000Z', complete: false }), '--key', 'K-1');
    await run('core-check', '--paths', path, '--mirror', mirrorOf([{ key: 'K-1', type: 'Bug' }], null), '--key', 'K-1');
    expect(out).toEqual([`CORE K-1 ${path}`, `CORE K-1 ${path}`, 'BYPASS K-1 bug issue type Bug']);
  });

  it('core-check names a ship-loop path as CORE', async () => {
    await run('core-check', '--paths', 'scripts/handover/merge-on-green.sh', '--mirror', mirrorOf([{ key: 'K-1' }]), '--key', 'K-1');
    expect(out).toEqual(['CORE K-1 scripts/handover/merge-on-green.sh']);
  });

  it('core-check passes --change-class through and refuses any other class', async () => {
    await run('core-check', '--paths', 'scripts/handover/chief-kit/go.sh', '--change-class', 'rename',
      '--mirror', mirrorOf([{ key: 'K-1' }]), '--key', 'K-1');
    expect(out).toEqual(['REVIEW K-1 scripts/handover/chief-kit/go.sh rename']);
    await expect(run('core-check', '--paths', 'a', '--change-class', 'move', '--key', 'K-1'))
      .rejects.toThrow(/--change-class is rename or bulk/);
  });

  it('gives CORE for a ship-loop path and NOT-CORE for a docs path', () => {
    expect(coreMatch(['scripts/handover/chief-kit/gen-briefs.py'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/chief-kit/gen-briefs.py']);
    expect(coreMatch(['docs/internals/enforcement.md'], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
  });

  it('keeps test-*.sh suites and fixtures out of core, and puts minerva in', () => {
    expect(coreMatch(['scripts/handover/chief-kit/test-gen-briefs.sh'], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
    expect(coreMatch(['marketplace/plugins/himmel-ops/scripts/test-minerva-example.sh'], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
    expect(coreMatch(['marketplace/plugins/himmel-ops/skills/minerva/SKILL.md'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 marketplace/plugins/himmel-ops/skills/minerva/SKILL.md']);
  });

  it('gives REVIEW for a rename when the old core path is passed with the new one', () => {
    expect(coreMatch(['scripts/handover/chief-kit/go.sh', 'scripts/handover/chief-kit/go-v2.sh'], ['K-1'], { patterns, changeClass: 'rename' }))
      .toEqual(['REVIEW K-1 scripts/handover/chief-kit/go.sh rename']);
  });

  it('gives REVIEW, never CORE or NOT-CORE, for a rename or bulk change that touches a core path', () => {
    expect(coreMatch(['scripts/handover/merge-on-green.sh'], ['K-1'], { patterns, changeClass: 'rename' }))
      .toEqual(['REVIEW K-1 scripts/handover/merge-on-green.sh rename']);
    expect(coreMatch(['scripts/handover/merge-on-green.sh'], ['K-1'], { patterns, changeClass: 'bulk' }))
      .toEqual(['REVIEW K-1 scripts/handover/merge-on-green.sh bulk']);
    expect(coreMatch(['docs/a.md'], ['K-1'], { patterns, changeClass: 'rename' })).toEqual(['NOT-CORE K-1']);
  });

  it('reads a ./-prefixed path as the same repository path', () => {
    expect(coreMatch(['./scripts/handover/chief-kit/go.sh'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/chief-kit/go.sh']);
  });

  it('treats the core list itself as core', () => {
    expect(coreMatch(['scripts/ci/core-paths.txt'], ['K-1'], { patterns })).toEqual(['CORE K-1 scripts/ci/core-paths.txt']);
  });

  it('resolves .. segments before matching', () => {
    expect(coreMatch(['scripts/handover/../handover/chief-kit/go.sh'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/chief-kit/go.sh']);
  });

  it('keeps tests and fixtures out of core even under a whole-directory core line', () => {
    for (const p of [
      'marketplace/plugins/himmel-bus/tests/test-store.mjs',
      'scripts/jira/src/release/engine.test.ts',
      'scripts/jira/src/release/engine.spec.ts',
      'marketplace/plugins/himmel-bus/fixtures/a.json',
    ]) expect(coreMatch([p], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
    expect(coreMatch(['marketplace/plugins/himmel-bus/src/store.mjs'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 marketplace/plugins/himmel-bus/src/store.mjs']);
  });

  it('decides every key of the worker the same way', () => {
    expect(coreMatch(['scripts/handover/chief-kit/go.sh'], ['K-1', 'K-2'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/chief-kit/go.sh', 'CORE K-2 scripts/handover/chief-kit/go.sh']);
  });
});

describe('core-paths.txt', () => {
  const patterns = loadCorePatterns(corePathsFile);

  it('splits a prefix(a|b)suffix line into its alternatives and refuses any other shape', () => {
    expect(alternativesOf('^x/(a|b)\\.')).toEqual(['^x/a\\.', '^x/b\\.']);
    expect(alternativesOf('^x/y\\.sh$')).toEqual(['^x/y\\.sh$']);
    expect(() => alternativesOf('^x/(a|b)/(c|d)$')).toThrow(/shape/);
    expect(() => alternativesOf('^x/(a|(b|c))$')).toThrow(/shape/);
  });

  it('every alternative of every line matches at least one tracked file that is not a test', () => {
    expect(patterns.length).toBeGreaterThan(0);
    expect(deadAlternatives(patterns, tracked)).toEqual([]);
  });

  it('an alternative matched only by a test file or fixture is dead', () => {
    expect(deadAlternatives(['^x/(a|tests/|b\\.)'], ['x/a.sh', 'x/tests/t.sh', 'x/b.test.ts']))
      .toEqual(['^x/(a|tests/|b\\.) :: ^x/tests/', '^x/(a|tests/|b\\.) :: ^x/b\\.']);
  });

  it('refuses a core list with no patterns', async () => {
    const empty = join(mkdtempSync(join(tmpdir(), 'core-empty-')), 'core-paths.txt');
    writeFileSync(empty, '# only a comment\n\n');
    expect(() => loadCorePatterns(empty)).toThrow(/no patterns/);
    await expect(run('core-check', '--core-paths', empty, '--paths', 'scripts/handover/merge-on-green.sh',
      '--mirror', mirrorOf([{ key: 'K-1' }]), '--key', 'K-1')).rejects.toThrow(/no patterns/);
    expect(out).toEqual([]);
  });

  it('matches at most 2 % of the tracked files', () => {
    expect(() => sizeGuard(patterns, tracked)).not.toThrow();
  });
});

describe('core-paths size guard', () => {
  const files = Array.from({ length: 100 }, (_, i) => (i < 5 ? `core/f${i}` : `other/f${i}`));

  it('alerts when more than 2 % of tracked files match, naming the counts', () => {
    expect(() => sizeGuard(['^core/'], files)).toThrow(/CORE-PATHS-TOO-WIDE 5\/100/);
  });

  it('passes exactly 2 %', () => {
    expect(sizeGuard(['^core/f[01]$'], files)).toEqual({ matched: 2, total: 100, line: null });
  });

  it('does not count tests and fixtures toward the share', () => {
    const withTests = [...files.slice(0, 2), ...Array.from({ length: 10 }, (_, i) => `core/tests/test-${i}.sh`), ...files.slice(5)];
    expect(sizeGuard(['^core/'], withTests).matched).toBe(2);
  });

  it('proceeds with a recorded reason', () => {
    const r = sizeGuard(['^core/'], files, 'adds the new bus plugin');
    expect(r.line).toBe('CORE-PATHS-WIDE 5/100 reason: adds the new bus plugin');
  });

  it('core-check stops on a too-wide list and proceeds with --widen-reason', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'core-wide-'));
    const wide = join(dir, 'core-paths.txt');
    writeFileSync(wide, '^scripts/\n');
    await expect(run('core-check', '--core-paths', wide, '--paths', 'scripts/a.sh', '--key', 'K-1'))
      .rejects.toThrow(/CORE-PATHS-TOO-WIDE/);
    await run('core-check', '--core-paths', wide, '--widen-reason', 'tests a wide list', '--paths', 'scripts/a.sh',
      '--mirror', mirrorOf([{ key: 'K-1' }]), '--key', 'K-1');
    expect(out[0]).toMatch(/^CORE-PATHS-WIDE \d+\/\d+ reason: tests a wide list$/);
    expect(out[1]).toBe('CORE K-1 scripts/a.sh');
  });
});

describe('core-check decides each key on its own', () => {
  const MOG = 'scripts/handover/merge-on-green.sh';
  const m = () => mirrorOf([
    { key: 'K-1', type: 'Bug' },
    { key: 'K-2', type: 'Bug', priority: 'Highest' },
    { key: 'K-3', type: 'Task', labels: ['red-main'] },
    { key: 'K-4', labels: ['core'] },
    { key: 'K-5' },
    { key: 'K-6' },
  ]);

  // Release state in a temp dir, written from outside a worker.
  function releaseEnv(): string {
    const root = mkdtempSync(join(tmpdir(), 'core-release-'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    return root;
  }

  it('a Bug, an emergency and a label-only key with --docs-only each give their BYPASS', async () => {
    const dir = m();
    await run('core-check', '--paths', MOG, '--mirror', dir, '--key', 'K-1', 'K-2', 'K-3');
    await run('core-check', '--paths', 'docs/a.md', '--docs-only', '--mirror', dir, '--key', 'K-4');
    await run('core-check', '--paths', 'docs/a.md', '--mirror', dir, '--key', 'K-4', 'K-5');
    expect(out).toEqual([
      'BYPASS K-1 bug issue type Bug',
      'BYPASS K-2 emergency Bug at Highest',
      'BYPASS K-3 emergency label red-main',
      'BYPASS K-4 design core by label only, docs-only leg',
      'CORE K-4 label core',
      'NOT-CORE K-5',
    ]);
  });

  it('--docs-only with a core path is still CORE', async () => {
    await run('core-check', '--paths', `docs/a.md,${MOG}`, '--docs-only', '--mirror', m(), '--key', 'K-4', 'K-5');
    expect(out).toEqual([`CORE K-4 ${MOG}`, `CORE K-5 ${MOG}`]);
  });

  it('--docs-only with a non-core code path keeps a label-only key CORE', async () => {
    await run('core-check', '--paths', 'docs/a.md,src/main.py', '--docs-only', '--mirror', m(), '--key', 'K-4');
    expect(out).toEqual(['CORE K-4 label core']);
  });

  it('--docs-only with no path at all keeps a label-only key CORE', async () => {
    await run('core-check', '--paths', ',', '--docs-only', '--mirror', m(), '--key', 'K-4');
    expect(out).toEqual(['CORE K-4 label core']);
  });

  it('a key with no mirror file is UNKNOWN even when a path matched', async () => {
    const dir = m();
    await run('core-check', '--paths', MOG, '--mirror', dir, '--key', 'K-5', 'K-9');
    await run('core-check', '--paths', 'docs/a.md', '--mirror', dir, '--key', 'K-9');
    await run('core-check', '--paths', MOG, '--mirror', join(dir, 'absent'), '--key', 'K-5');
    expect(out).toEqual([`CORE K-5 ${MOG}`, 'UNKNOWN K-9', 'UNKNOWN K-9', 'UNKNOWN K-5']);
  });

  it('a path match with a Bug key and a Story key gives BYPASS for the Bug and CORE for the Story', async () => {
    await run('core-check', '--paths', MOG, '--mirror', m(), '--key', 'K-1', 'K-5');
    expect(out).toEqual(['BYPASS K-1 bug issue type Bug', `CORE K-5 ${MOG}`]);
  });

  it('core-bypass and core-snapshot records in a second declared release turn CORE into BYPASS operator and BYPASS grandfathered', async () => {
    const root = releaseEnv();
    const words = join(root, 'verbatim.txt');
    writeFileSync(words, 'let K-5 through\n');
    const keysFile = join(root, 'in-flight.txt');
    writeFileSync(keysFile, '# in progress at flag-on\nK-6\n');
    for (const r of ['R1', 'R2']) await run('operator', 'declare', r, '--versions', 'v1', '--decision', '1', '--verbatim-file', words);
    await run('operator', 'core-bypass', 'R2', '--keys', 'K-5', '--decision', '412', '--verbatim-file', words);
    await run('operator', 'core-snapshot', 'R2', '--keys-file', keysFile);
    out = [];
    await run('core-check', '--paths', MOG, '--mirror', m(), '--key', 'K-5', 'K-6', 'K-4');
    expect(out).toEqual([
      'BYPASS K-5 operator O-R2-0002 decision 412',
      'BYPASS K-6 grandfathered O-R2-0003 core-snapshot',
      `CORE K-4 ${MOG}`,
    ]);
  });

  it('core-bypass and core-snapshot are fenced, need keys, and the snapshot is written once', async () => {
    const root = releaseEnv();
    const words = join(root, 'verbatim.txt');
    writeFileSync(words, 'ok\n');
    const keysFile = join(root, 'keys.txt');
    writeFileSync(keysFile, 'K-6\n');
    const empty = join(root, 'empty.txt');
    writeFileSync(empty, '# none\n');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', words);
    await expect(run('operator', 'core-snapshot', 'R1', '--keys-file', empty)).rejects.toThrow(/no keys/);
    await expect(run('operator', 'core-bypass', 'R1', '--keys', 'not a key', '--decision', '9', '--verbatim-file', words))
      .rejects.toThrow(/not a ticket key/);
    await run('operator', 'core-snapshot', 'R1', '--keys-file', keysFile);
    await expect(run('operator', 'core-snapshot', 'R1', '--keys-file', keysFile)).rejects.toThrow(/already recorded/);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await expect(run('operator', 'core-bypass', 'R1', '--keys', 'K-5', '--decision', '9', '--verbatim-file', words))
      .rejects.toThrow(/chief-spawned worker/);
  });

  it('--mirror reads the named directory', async () => {
    await run('core-check', '--paths', MOG, '--mirror', mirrorOf([{ key: 'K-7', type: 'Bug' }]), '--key', 'K-7');
    await run('core-check', '--paths', MOG, '--mirror', mirrorOf([{ key: 'K-7' }]), '--key', 'K-7');
    expect(out).toEqual(['BYPASS K-7 bug issue type Bug', `CORE K-7 ${MOG}`]);
  });

  it('expands a directory to its tracked files and refuses a glob, an absolute path or a path outside the repository', async () => {
    const dir = m();
    await run('core-check', '--paths', 'scripts/handover/chief-kit', '--mirror', dir, '--key', 'K-5');
    await run('core-check', '--paths', 'scripts/handover/chief-kit/', '--mirror', dir, '--key', 'K-5');
    expect(out).toHaveLength(2);
    for (const l of out) expect(l).toMatch(/^CORE K-5 scripts\/handover\/chief-kit\/[^/]+$/);
    for (const [p, why] of [['scripts/handover/*.sh', /glob/], [`/abs/${MOG}`, /absolute/], ['../elsewhere/a.sh', /outside the repository/]] as const) {
      await expect(run('core-check', '--paths', p, '--mirror', dir, '--key', 'K-5')).rejects.toThrow(why);
    }
  });
});

describe('the core bypass reads who signs', () => {
  const MOG = 'scripts/handover/merge-on-green.sh';
  const T0 = '2026-11-01T00:00:00.000Z';
  const T1 = '2026-11-02T00:00:00.000Z';
  const T2 = '2026-11-03T00:00:00.000Z';
  const snap = (key: string, o: Partial<IssueSnap> = {}): IssueSnap => ({
    key, status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, ...o,
  });
  const issues = new Map<string, IssueSnap>([
    ['K-2', snap('K-2', { type: 'Bug', priority: 'Highest' })],
    ...['K-5', 'K-6', 'K-7', 'K-8', 'K-9'].map((k) => [k, snap(k)] as [string, IssueSnap]),
  ]);
  const bypass = (id: string, ts: string, key: string, decision = '412'): OperatorRow => ({ id, kind: 'core-bypass', ts, decision, keys: [key] });
  const snapshotRow = (id: string, key: string): OperatorRow => ({ id, kind: 'core-snapshot', ts: T0, decision: null, keys: [key] });
  const signerRec = (id: string, ts: string, signer: 'chief' | 'operator', keys?: string[]): OperatorRow => ({
    id, kind: 'spec-signer', ts, decision: '1170', signer, ...(keys ? { keys } : {}),
  });
  const ctxOf = (records: OperatorRow[], signer: SignerState) => ({ patterns: [`^${MOG}$`], issues, records, signer });
  const stateOf = (records: OperatorRow[], unreadable: string | null = null): SignerState => ({ records, unreadable, issues });

  it('with no spec-signer record, every fixture key keeps its core-check line (I9)', () => {
    const records = [bypass('O-1', T0, 'K-5'), snapshotRow('O-2', 'K-6')];
    expect(coreMatch([MOG], ['K-2', 'K-5', 'K-6', 'K-7', 'K-4'], ctxOf(records, { records: [], unreadable: null, issues: null }))).toEqual([
      'BYPASS K-2 emergency Bug at Highest', 'BYPASS K-5 operator O-1 decision 412', 'BYPASS K-6 grandfathered O-2 core-snapshot', `CORE K-7 ${MOG}`, 'UNKNOWN K-4',
    ]);
  });

  it('with CoreCtx.signer from readSignerState on that incomplete fixture mirror and no record, every core-check answer is kept (I9, I15)', async () => {
    const root = mkdtempSync(join(tmpdir(), 'core-release-'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    const words = join(root, 'verbatim.txt');
    writeFileSync(words, 'let K-5 through\n');
    const keysFile = join(root, 'in-flight.txt');
    writeFileSync(keysFile, 'K-6\n');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', words);
    await run('operator', 'core-bypass', 'R1', '--keys', 'K-5', '--decision', '412', '--verbatim-file', words);
    await run('operator', 'core-snapshot', 'R1', '--keys-file', keysFile);
    const dir = mirrorOf([{ key: 'K-5' }, { key: 'K-6' }, { key: 'K-1', type: 'Bug' }], { lastSync: '2026-11-01T00:00:00.000Z', complete: false });
    expect(readSignerState(process.env, dir)).toEqual({ records: [], unreadable: null, issues: null });
    out = [];
    await run('core-check', '--paths', MOG, '--mirror', dir, '--key', 'K-5', 'K-6', 'K-1');
    expect(out).toEqual(['BYPASS K-5 operator O-R1-0002 decision 412', 'BYPASS K-6 grandfathered O-R1-0003 core-snapshot', 'BYPASS K-1 bug issue type Bug']);
  });

  it('a marked key\'s operator core-bypass gives no BYPASS whatever its decision; under a station operator default a bypass written before it counts and one after does not; with both rows on one key, the earlier one still counts (filter, then newest) (I11, I13)', () => {
    const records = [
      bypass('O-1', T0, 'K-5', '99999'), bypass('O-2', T0, 'K-6'), bypass('O-3', T0, 'K-8'),
      bypass('O-4', T2, 'K-7'), bypass('O-5', T2, 'K-8'),
    ];
    const signer = stateOf([signerRec('M-5', T2, 'operator', ['K-5']), signerRec('ST', T1, 'operator')]);
    expect(coreMatch([MOG], ['K-5', 'K-6', 'K-7', 'K-8'], ctxOf(records, signer))).toEqual([
      `CORE K-5 ${MOG}`, 'BYPASS K-6 operator O-2 decision 412', `CORE K-7 ${MOG}`, 'BYPASS K-8 operator O-3 decision 412',
    ]);
  });

  it('an unreadable state drops every operator core-bypass and keeps a snapshot; an emergency still bypasses a marked key (I13)', () => {
    const records = [bypass('O-1', T0, 'K-5'), bypass('O-2', T0, 'K-2'), snapshotRow('O-3', 'K-6')];
    expect(coreMatch([MOG], ['K-5', 'K-6'], ctxOf(records, stateOf([], 'release R2: its key does not load')))).toEqual([
      `CORE K-5 ${MOG}`, 'BYPASS K-6 grandfathered O-3 core-snapshot',
    ]);
    expect(coreMatch([MOG], ['K-2'], ctxOf(records, stateOf([signerRec('M-2', T0, 'operator', ['K-2'])])))).toEqual(['BYPASS K-2 emergency Bug at Highest']);
  });

  it('a CoreCtx with records and no signer throws; a paths-only caller is unchanged (I13)', () => {
    expect(() => coreMatch([MOG], ['K-5'], { patterns: [`^${MOG}$`], issues, records: [] })).toThrow(/signer state/);
    expect(coreMatch([MOG], ['K-5'], { patterns: [`^${MOG}$`] })).toEqual([`CORE K-5 ${MOG}`]);
  });

  it('pathIndependentBypass gives the emergency, Bug and snapshot answers (I13)', () => {
    expect(pathIndependentBypass('K-2', issues.get('K-2') as IssueSnap, [])).toBe('emergency Bug at Highest');
    expect(pathIndependentBypass('K-1', snap('K-1', { labels: ['regression'] }), [])).toBe('emergency label regression');
    expect(pathIndependentBypass('K-1', snap('K-1', { type: 'Bug' }), [])).toBe('bug issue type Bug');
    expect(pathIndependentBypass('K-6', snap('K-6'), [snapshotRow('O-3', 'K-6'), bypass('O-1', T0, 'K-6')])).toBe('grandfathered O-3 core-snapshot');
    expect(pathIndependentBypass('K-5', snap('K-5'), [bypass('O-1', T0, 'K-5')])).toBeNull();
  });
});
