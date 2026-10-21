import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { releaseRoot } from './paths.js';

// The repo segment is the checkout's directory name (CI checks out as Himmel,
// a local worktree as himmel), so derive it the same way paths.ts does.
const repoName = (): string =>
  basename(dirname(execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim()));

describe('releaseRoot resolves through handoverRoot (HIMMEL-6917)', () => {
  it('uses an explicit HANDOVER_DIR from the env record', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-root-'));
    try {
      expect(releaseRoot({ HANDOVER_DIR: dir, USER_SLUG: 'yotamleo' })).toBe(
        join(dir, 'yotamleo', repoName(), 'release'),
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
