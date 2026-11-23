// `release core-check` and `release core-check-batch` share one input load and one per-group
// compute, so a batch group prints exactly the lines a single call of that group prints.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { coreMatch, expandPaths, loadCorePatterns, sizeGuard, type ChangeClass } from '../release/core.js';
import { readMirrorFilesUnverified, readOperatorRecords } from '../release/engine.js';
import type { IssueSnap, OperatorRow } from '../release/types.js';
import { defaultRoot } from './mirror.js';
import { list } from './release.js';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');

export interface CoreInputOpts { corePaths?: string; widenReason?: string; mirror?: string }

export interface CoreInputs {
  patterns: string[];
  tracked: string[];
  guardLine: string | null;
  issues: Map<string, IssueSnap> | null;
  records: OperatorRow[];
}

export function loadCoreInputs(o: CoreInputOpts): CoreInputs {
  const patterns = loadCorePatterns(o.corePaths ?? join(repoRoot, 'scripts', 'ci', 'core-paths.txt'));
  const tracked = execFileSync('git', ['ls-files'], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    .split('\n').filter(Boolean);
  const guard = sizeGuard(patterns, tracked, o.widenReason);
  const mirror = o.mirror ?? (process.env.JIRA_PROJECT_KEY ? defaultRoot(process.env.JIRA_PROJECT_KEY) : null);
  const records = [...readOperatorRecords('core-bypass'), ...readOperatorRecords('core-snapshot')]
    .sort((a, b) => a.ts.localeCompare(b.ts));
  const issues = mirror ? readMirrorFilesUnverified(mirror).issues : null;
  return { patterns, tracked, guardLine: guard.line, issues, records };
}

export function coreGroupLines(
  inputs: CoreInputs, paths: string, keys: string[], o: { changeClass?: ChangeClass; docsOnly?: boolean } = {},
): string[] {
  const { patterns, tracked, issues, records } = inputs;
  return coreMatch(expandPaths(list(paths), tracked), keys, { patterns, changeClass: o.changeClass, docsOnly: !!o.docsOnly, issues, records });
}

const BATCH = 'release core-check-batch';

function parseGroups(text: string): Array<{ paths: string; keys: string[] }> {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch (e) {
    throw new Error(`${BATCH}: the batch file is not JSON: ${(e as Error).message}`);
  }
  if (!Array.isArray(data)) throw new Error(`${BATCH}: the batch file is not a list of groups`);
  return data.map((g: unknown, i) => {
    const n = i + 1;
    if (typeof g !== 'object' || g === null || Array.isArray(g)) throw new Error(`${BATCH}: group ${n} is not an object`);
    const extra = Object.keys(g).filter((k) => k !== 'paths' && k !== 'keys');
    if (extra.length) throw new Error(`${BATCH}: group ${n} takes only paths and keys, not ${extra.join(', ')}`);
    const { paths, keys } = g as { paths?: unknown; keys?: unknown };
    if (typeof paths !== 'string') throw new Error(`${BATCH}: group ${n}: paths is not a string`);
    if (!Array.isArray(keys) || !keys.length || !keys.every((k) => typeof k === 'string' && k !== '')) {
      throw new Error(`${BATCH}: group ${n}: keys is not a non-empty list of keys`);
    }
    return { paths, keys: keys as string[] };
  });
}

export function coreCheckBatch(file: string, o: CoreInputOpts): void {
  const groups = parseGroups(readFileSync(file, 'utf8'));
  const inputs = loadCoreInputs(o);
  const lines: string[] = inputs.guardLine ? [inputs.guardLine] : [];
  groups.forEach((g, i) => {
    try {
      lines.push(`== ${i + 1}`, ...coreGroupLines(inputs, g.paths, g.keys));
    } catch (e) {
      throw new Error(`${BATCH}: group ${i + 1}: ${(e as Error).message}`);
    }
  });
  for (const l of lines) console.log(l);
}
