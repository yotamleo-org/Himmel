import { describe, it, expect } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { releaseRoot } from './paths.js';

describe('releaseRoot resolves through handoverRoot (HIMMEL-6917)', () => {
  it('uses an explicit HANDOVER_DIR from the env record', () => {
    const dir = mkdtempSync(join(tmpdir(), 'release-root-'));
    try {
      expect(releaseRoot({ HANDOVER_DIR: dir, USER_SLUG: 'yotamleo' })).toMatch(
        new RegExp(`^${dir}/yotamleo/[^/]+/release$`),
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
