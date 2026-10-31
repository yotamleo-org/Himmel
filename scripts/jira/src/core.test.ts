import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

vi.mock('./client.js', () => ({ request: vi.fn(), projectKey: vi.fn(() => 'HIMMEL') }));
vi.mock('./breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { registerRelease } from './commands/release.js';
import { alternativesOf, coreMatch, loadCorePatterns, sizeGuard } from './core.js';

// scripts/jira/src -> repo root
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const corePathsFile = join(repoRoot, 'scripts', 'ci', 'core-paths.txt');
const tracked = execFileSync('git', ['ls-files'], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  .split('\n').filter(Boolean);

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
});

describe('coreMatch (HIMMEL-8353 C1b)', () => {
  const patterns = loadCorePatterns(corePathsFile);

  it('core-check names a ship-loop path as CORE', async () => {
    await run('core-check', '--paths', 'scripts/handover/merge-on-green.sh', '--key', 'K-1');
    expect(out).toEqual(['CORE K-1 scripts/handover/merge-on-green.sh']);
  });

  it('core-check passes --change-class through and refuses any other class', async () => {
    await run('core-check', '--paths', 'scripts/handover/queue-lock.sh', '--change-class', 'rename', '--key', 'K-1');
    expect(out).toEqual(['REVIEW K-1 scripts/handover/queue-lock.sh rename']);
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
    expect(coreMatch(['marketplace/plugins/himmel-ops/scripts/test-minerva-spec-gate.sh'], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
    expect(coreMatch(['marketplace/plugins/himmel-ops/skills/minerva/SKILL.md'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 marketplace/plugins/himmel-ops/skills/minerva/SKILL.md']);
  });

  it('gives REVIEW, never CORE or NOT-CORE, for a rename or bulk change that touches a core path', () => {
    expect(coreMatch(['scripts/handover/merge-on-green.sh'], ['K-1'], { patterns, changeClass: 'rename' }))
      .toEqual(['REVIEW K-1 scripts/handover/merge-on-green.sh rename']);
    expect(coreMatch(['scripts/handover/merge-on-green.sh'], ['K-1'], { patterns, changeClass: 'bulk' }))
      .toEqual(['REVIEW K-1 scripts/handover/merge-on-green.sh bulk']);
    expect(coreMatch(['docs/a.md'], ['K-1'], { patterns, changeClass: 'rename' })).toEqual(['NOT-CORE K-1']);
  });

  it('reads a ./-prefixed path as the same repository path', () => {
    expect(coreMatch(['./scripts/handover/queue-lock.sh'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/queue-lock.sh']);
  });

  it('treats the core list itself as core', () => {
    expect(coreMatch(['scripts/ci/core-paths.txt'], ['K-1'], { patterns })).toEqual(['CORE K-1 scripts/ci/core-paths.txt']);
  });

  it('resolves .. segments before matching', () => {
    expect(coreMatch(['scripts/handover/../handover/queue-lock.sh'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/queue-lock.sh']);
  });

  it('keeps tests and fixtures out of core even under a whole-directory core line', () => {
    for (const p of [
      'marketplace/plugins/himmel-bus/tests/test-store.mjs',
      'scripts/jira/src/release/engine.test.ts',
      'marketplace/plugins/himmel-bus/fixtures/a.json',
    ]) expect(coreMatch([p], ['K-1'], { patterns })).toEqual(['NOT-CORE K-1']);
    expect(coreMatch(['marketplace/plugins/himmel-bus/src/store.mjs'], ['K-1'], { patterns }))
      .toEqual(['CORE K-1 marketplace/plugins/himmel-bus/src/store.mjs']);
  });

  it('decides every key of the worker the same way', () => {
    expect(coreMatch(['scripts/handover/queue-lock.sh'], ['K-1', 'K-2'], { patterns }))
      .toEqual(['CORE K-1 scripts/handover/queue-lock.sh', 'CORE K-2 scripts/handover/queue-lock.sh']);
  });
});

describe('core-paths.txt (HIMMEL-8353 C1b)', () => {
  const patterns = loadCorePatterns(corePathsFile);

  it('splits a prefix(a|b)suffix line into its alternatives and refuses any other shape', () => {
    expect(alternativesOf('^x/(a|b)\\.')).toEqual(['^x/a\\.', '^x/b\\.']);
    expect(alternativesOf('^x/y\\.sh$')).toEqual(['^x/y\\.sh$']);
    expect(() => alternativesOf('^x/(a|b)/(c|d)$')).toThrow(/shape/);
    expect(() => alternativesOf('^x/(a|(b|c))$')).toThrow(/shape/);
  });

  it('every alternative of every line matches at least one tracked file', () => {
    expect(patterns.length).toBeGreaterThan(0);
    const dead: string[] = [];
    for (const line of patterns) {
      for (const alt of alternativesOf(line)) {
        const re = new RegExp(alt);
        if (!tracked.some((f) => re.test(f))) dead.push(`${line} :: ${alt}`);
      }
    }
    expect(dead).toEqual([]);
  });

  it('matches at most 2 % of the tracked files', () => {
    expect(() => sizeGuard(patterns, tracked)).not.toThrow();
  });
});

describe('core-paths size guard (HIMMEL-8353 C1b)', () => {
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
    await run('core-check', '--core-paths', wide, '--widen-reason', 'tests a wide list', '--paths', 'scripts/a.sh', '--key', 'K-1');
    expect(out[0]).toMatch(/^CORE-PATHS-WIDE \d+\/\d+ reason: tests a wide list$/);
    expect(out[1]).toBe('CORE K-1 scripts/a.sh');
  });
});
