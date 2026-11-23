import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', () => ({
  request: vi.fn(), projectKey: vi.fn(() => 'HIMMEL'), baseUrl: vi.fn(() => 'http://127.0.0.1:9'), authHeader: vi.fn(() => 'Basic eA=='),
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { registerRelease } from './release.js';
import { appendChain, loadKey, readChain } from '../release/ledger.js';
import type { OperatorRow } from '../release/types.js';

const CORE_PATH = 'scripts/handover/chief-kit/tick.sh';

let out: string[];
let root: string;
let mirror: string;
let corePaths: string;

async function run(...args: string[]) {
  const p = new Command();
  p.exitOverride();
  registerRelease(p);
  await p.parseAsync(['node', 'jira', 'release', ...args]);
}

type Snap = { key: string; type?: string; priority?: string; labels?: string[] };
function writeMirror(...issues: Snap[]): string {
  const dir = join(root, 'mirror');
  mkdirSync(dir);
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-23T00:00:00Z' }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: "To Do"\ntype: ${JSON.stringify(i.type ?? 'Task')}\n`
      + `priority: ${JSON.stringify(i.priority ?? 'Medium')}\nfixVersions: []\n${i.labels ? `labels: ${JSON.stringify(i.labels)}\n` : ''}---\n`);
  }
  return dir;
}

function batchFile(groups: unknown): string {
  const f = join(root, `batch-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(f, typeof groups === 'string' ? groups : JSON.stringify(groups));
  return f;
}

async function single(paths: string, keys: string[], ...extra: string[]): Promise<string[]> {
  out = [];
  await run('core-check', '--paths', paths, '--key', ...keys, '--mirror', mirror, '--core-paths', corePaths, ...extra);
  return out;
}

async function batch(groups: unknown, ...extra: string[]): Promise<string[]> {
  out = [];
  await run('core-check-batch', batchFile(groups), '--mirror', mirror, '--core-paths', corePaths, ...extra);
  return out;
}

function groupOf(lines: string[], n: number): string[] {
  const at = lines.indexOf(`== ${n}`);
  expect(at).toBeGreaterThanOrEqual(0);
  const next = lines.findIndex((l, i) => i > at && /^== \d+$/.test(l));
  return lines.slice(at + 1, next === -1 ? undefined : next);
}

const KEYS = ['K-1', 'K-2', 'K-3', 'K-4', 'K-5', 'K-6', 'K-7', 'K-9'];

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), 'release-batch-'));
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'state'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_CONSOLE', '');
  vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
  out = [];
  vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
  corePaths = join(root, 'core-paths.txt');
  writeFileSync(corePaths, `^${CORE_PATH.replace(/[.]/g, '\\.')}$\n`);
  mirror = writeMirror(
    { key: 'K-1' },
    { key: 'K-2', labels: ['core'] },
    { key: 'K-3', type: 'Bug', priority: 'Highest' },
    { key: 'K-4', labels: ['red-main'] },
    { key: 'K-5', type: 'Bug' },
    { key: 'K-6' },
    { key: 'K-7' },
  );
  const vf = join(root, 'verbatim.txt');
  writeFileSync(vf, 'R = v1\n');
  const keysFile = join(root, 'snapshot-keys.txt');
  writeFileSync(keysFile, 'K-7\n');
  await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', vf);
  await run('operator', 'core-bypass', 'R1', '--keys', 'K-6', '--decision', '2', '--verbatim-file', vf);
  await run('operator', 'core-snapshot', 'R1', '--keys-file', keysFile);
  out = [];
  vi.mocked(console.log).mockClear();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  rmSync(root, { recursive: true, force: true });
});

describe('release core-check-batch prints, per group, what a single core-check prints (P5)', () => {
  it('matches the single call byte for byte for every verdict a group can get', async () => {
    const pair = ` README.md ,, ${CORE_PATH} `;
    const groups = [
      { paths: CORE_PATH, keys: KEYS },
      { paths: 'README.md', keys: KEYS },
      { paths: pair, keys: KEYS },
    ];
    const b = await batch(groups);
    expect(b[0]).toBe('== 1');
    expect(b.filter((l) => /^== \d+$/.test(l))).toEqual(['== 1', '== 2', '== 3']);
    for (const [i, g] of groups.entries()) expect(groupOf(b, i + 1)).toEqual(await single(g.paths, g.keys));

    const one = groupOf(b, 1);
    expect(one).toEqual([
      `CORE K-1 ${CORE_PATH}`,
      `CORE K-2 ${CORE_PATH}`,
      'BYPASS K-3 emergency Bug at Highest',
      'BYPASS K-4 emergency label red-main',
      'BYPASS K-5 bug issue type Bug',
      expect.stringMatching(/^BYPASS K-6 operator O-R1-\d+ decision 2$/),
      expect.stringMatching(/^BYPASS K-7 grandfathered O-R1-\d+ core-snapshot$/),
      'UNKNOWN K-9',
    ]);
    expect(groupOf(b, 2)).toEqual(expect.arrayContaining(['NOT-CORE K-1', 'CORE K-2 label core', 'UNKNOWN K-9']));
    expect(groupOf(b, 3)).toContain(`CORE K-1 ${CORE_PATH}`);
  });

  it('prints CORE-PATHS-WIDE once, before == 1, with --widen-reason', async () => {
    writeFileSync(corePaths, '^scripts/\n');
    const reason = ['--widen-reason', 'test widening'];
    const b = await batch([{ paths: 'README.md', keys: ['K-1'] }, { paths: CORE_PATH, keys: ['K-1'] }], ...reason);
    const s = await single('README.md', ['K-1'], ...reason);
    expect(s[0]).toMatch(/^CORE-PATHS-WIDE \d+\/\d+ reason: test widening$/);
    expect(b[0]).toBe(s[0]);
    expect(b[1]).toBe('== 1');
    expect(b.filter((l) => l.startsWith('CORE-PATHS-WIDE'))).toHaveLength(1);
    expect(groupOf(b, 1)).toEqual(s.slice(1));
  });

  it('control: a group naming a different path differs on that key', async () => {
    const b = await batch([{ paths: 'README.md', keys: ['K-1'] }]);
    const s = await single(CORE_PATH, ['K-1']);
    expect(groupOf(b, 1)).not.toEqual(s);
  });
});

describe('release core-check-batch gives no partial answer (P6)', () => {
  const good = { paths: CORE_PATH, keys: ['K-1'] };
  const faults: Array<[string, unknown, RegExp]> = [
    ['an empty keys', [good, { paths: 'README.md', keys: [] }], /group 2/],
    ['a non-string paths', [good, { paths: 5, keys: ['K-1'] }], /group 2/],
    ['a JSON that is not a list', good, /not a list/],
    ['a glob path', [good, { paths: 'scripts/*.ts', keys: ['K-1'] }], /group 2: .*is a glob/],
    ['an absolute path', [good, { paths: '/etc/passwd', keys: ['K-1'] }], /group 2: .*is absolute/],
    ['a .. path', [good, { paths: 'scripts/../../x', keys: ['K-1'] }], /group 2: .*outside the repository/],
  ];
  for (const [name, groups, why] of faults) {
    it(`${name}: rejects naming the group and prints nothing`, async () => {
      await expect(batch(groups)).rejects.toThrow(why);
      expect(out).toEqual([]);
      expect(console.log).not.toHaveBeenCalled();
    });
  }

  it('control: the same batch with the fault removed prints == 1 to == 2', async () => {
    const b = await batch([good, { paths: 'README.md', keys: ['K-1'] }]);
    expect(b.filter((l) => /^== \d+$/.test(l))).toEqual(['== 1', '== 2']);
  });
});

describe('release core-check-batch reads who signs (I13)', () => {
  it('release core-check-batch on the fixture root of the I13 core-check row, one group naming the marked key and one naming an unmarked bypassed key, prints no BYPASS for the marked key and BYPASS for the other, matching release core-check line for line', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'core-bypass', 'R1', '--keys', 'K-1', '--decision', '3', '--verbatim-file', vf);
    const path = join(root, 'state', 'R1', 'operator.jsonl');
    const key = loadKey(join(root, 'keys', 'R1.key'));
    appendChain<OperatorRow>(path, key, {
      id: `O-R1-${String(readChain<OperatorRow>(path, key).rows.length + 1).padStart(4, '0')}`,
      kind: 'spec-signer', ts: new Date().toISOString(), decision: '1170', keys: ['K-1'], signer: 'operator', verbatim: 'K-1 is mine to sign',
    });
    const groups = [{ paths: CORE_PATH, keys: ['K-1'] }, { paths: CORE_PATH, keys: ['K-6'] }];
    const b = await batch(groups);
    expect(groupOf(b, 1)).toEqual([`CORE K-1 ${CORE_PATH}`]);
    expect(groupOf(b, 2)).toEqual([expect.stringMatching(/^BYPASS K-6 operator O-R1-\d+ decision 2$/)]);
    for (const [i, g] of groups.entries()) expect(groupOf(b, i + 1)).toEqual(await single(g.paths, g.keys));
  });
});
