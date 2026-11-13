// Test-only bun preload (test-real-state-guard.sh J3, K3, K4): the operator fence's ancestry
// walk takes its env-only (no /proc) path when given no seam, as vitest.setup.ts does for the
// vitest suites. The suite's fence row runs the same verb without it and asserts the refusal.
import { plugin } from 'bun';
import { join } from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';

const noProc = join(mkdtempSync(join(tmpdir(), 'fence-preload-')), 'absent');
const HEAD = 'export function walk(opts: WalkOpts = {}): WalkResult {';

plugin({
  name: 'fence-env-only',
  setup(build) {
    build.onLoad({ filter: /[/\\]release[/\\]fence-ancestry\.ts$/ }, async ({ path }) => {
      const src = await Bun.file(path).text();
      if (!src.includes(HEAD)) throw new Error(`fence-env-only-preload: ${path} no longer declares walk as expected`);
      const wrapped = src.replace(HEAD, 'function realWalk(opts: WalkOpts = {}): WalkResult {')
        + `\nexport function walk(o: WalkOpts = {}): WalkResult {\n  return realWalk(o.procRoot === undefined && o.hostNsPath === undefined ? { ...o, procRoot: ${JSON.stringify(noProc)} } : o);\n}\n`;
      return { contents: wrapped, loader: 'ts' };
    });
  },
});
