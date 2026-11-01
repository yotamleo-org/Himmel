// The one owner of "is this path core?". scripts/ci/core-paths.txt lists the ship-loop
// files; coreMatch reads a change against it and returns one verdict line per key.
// Nothing else reads core-paths.txt.
import { readFileSync } from 'node:fs';
import { posix } from 'node:path';
import type { IssueSnap, OperatorRow } from './types.js';

export type ChangeClass = 'rename' | 'bulk';

export const MAX_CORE_SHARE = 0.02;

export function parseCorePatterns(text: string): string[] {
  return text.split('\n').map((l) => l.trim()).filter((l) => l !== '' && !l.startsWith('#'));
}

// An empty list would read every path as NOT-CORE, so it refuses instead.
export function loadCorePatterns(file: string): string[] {
  const patterns = parseCorePatterns(readFileSync(file, 'utf8'));
  if (!patterns.length) throw new Error(`core-paths list ${file} has no patterns; an empty list would read every path as NOT-CORE`);
  return patterns;
}

// The one readable shape is prefix(a|b|...)suffix: one group, no nesting. Anything else
// throws, so the list stays in a form the alternatives test can fully read.
export function alternativesOf(line: string): string[] {
  const opens: number[] = [];
  const closes: number[] = [];
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '\\') { i++; continue; }
    if (c === '(') opens.push(i);
    else if (c === ')') closes.push(i);
  }
  if (opens.length === 0 && closes.length === 0) return [line];
  if (opens.length !== 1 || closes.length !== 1 || closes[0] < opens[0]) {
    throw new Error(`core-paths line is not the prefix(a|b)suffix shape: ${line}`);
  }
  const inner = line.slice(opens[0] + 1, closes[0]);
  if (/[()]/.test(inner.replace(/\\./g, ''))) throw new Error(`core-paths line is not the prefix(a|b)suffix shape: ${line}`);
  return inner.split('|').map((a) => line.slice(0, opens[0]) + a + line.slice(closes[0] + 1));
}

// Test suites and fixtures are never core, even under a whole-directory core line.
const TEST_PATH = /(^|\/)(test-[^/]*|[^/]*\.(test|spec)\.[a-z]+|tests?\/.*|fixtures?\/.*)$/;

const matchesAny =(res: RegExp[], p: string): boolean => res.some((re) => re.test(p));

// `<line> :: <alternative>` for each alternative no tracked non-test file matches: a core
// line kept alive only by a test file names nothing core.
export function deadAlternatives(patterns: string[], tracked: string[]): string[] {
  const live = tracked.filter((f) => !TEST_PATH.test(f));
  return patterns.flatMap((line) => alternativesOf(line)
    .filter((alt) => !live.some((f) => new RegExp(alt).test(f)))
    .map((alt) => `${line} :: ${alt}`));
}

// The paths core-check matches: a directory becomes the tracked files under it; a glob, an
// absolute path or one outside the repository is refused, since each would read NOT-CORE.
export function expandPaths(paths: string[], tracked: string[]): string[] {
  return paths.flatMap((raw) => {
    if (posix.isAbsolute(raw)) throw new Error(`release core-check: --paths takes repository-relative paths; ${raw} is absolute`);
    if (/[*?[\]{}]/.test(raw)) throw new Error(`release core-check: --paths takes file or directory paths; ${raw} is a glob`);
    const p = posix.normalize(raw);
    if (p === '..' || p.startsWith('../')) throw new Error(`release core-check: ${raw} is outside the repository`);
    const dir = p.replace(/\/+$/, '');
    const under = dir === '.' ? tracked : tracked.filter((f) => f.startsWith(`${dir}/`));
    return under.length ? under : [p];
  });
}

// Alert, not a wall: more than 2 % of tracked files matching stops the check, and an
// explicit reason lets a legitimate widening proceed with the reason on the record.
export function sizeGuard(
  patterns: string[], tracked: string[], reason?: string,
): { matched: number; total: number; line: string | null } {
  const res = patterns.map((p) => new RegExp(p));
  const matched = tracked.filter((f) => !TEST_PATH.test(f) && matchesAny(res, f)).length;
  const total = tracked.length;
  if (matched <= total * MAX_CORE_SHARE) return { matched, total, line: null };
  if (!reason) {
    throw new Error(
      `CORE-PATHS-TOO-WIDE ${matched}/${total}: core-paths.txt matches more than ${MAX_CORE_SHARE * 100} % of tracked files; `
      + 'pass --widen-reason <why> if core really has to grow',
    );
  }
  return { matched, total, line: `CORE-PATHS-WIDE ${matched}/${total} reason: ${reason}` };
}

export interface CoreCtx {
  patterns: string[];
  changeClass?: ChangeClass;
  // The caller's own docs-only test passed: a key core by its label alone is a design leg.
  docsOnly?: boolean;
  // The mirror's issues, null when no mirror is readable. Left out (jira create, before the
  // key exists), every key is decided by the paths alone.
  issues?: Map<string, IssueSnap> | null;
  // The verified core-bypass and core-snapshot records of every declared release.
  records?: OperatorRow[];
}

const EMERGENCY_LABELS = ['red-main', 'regression'];

// The spec §4 bypass table, for a key that is core: `<kind> <reason>`, or null.
function bypassOf(k: string, snap: IssueSnap, labelOnly: boolean, o: CoreCtx): string | null {
  if (labelOnly && o.docsOnly) return 'design core by label only, docs-only leg';
  if (snap.type === 'Bug' && (snap.priority === 'Highest' || snap.priority === 'Blocker')) return `emergency Bug at ${snap.priority}`;
  const label = EMERGENCY_LABELS.find((l) => snap.labels?.includes(l));
  if (label) return `emergency label ${label}`;
  if (snap.type === 'Bug') return 'bug issue type Bug';
  const newest = (kind: OperatorRow['kind']) => (o.records ?? []).filter((r) => r.kind === kind && r.keys?.includes(k)).at(-1);
  const op = newest('core-bypass');
  if (op) return `operator ${op.id} decision ${op.decision}`;
  const snapshot = newest('core-snapshot');
  if (snapshot) return `grandfathered ${snapshot.id} core-snapshot`;
  return null;
}

// Per key: CORE <K> <first matched path | label core> | REVIEW <K> <path> <class> |
// BYPASS <K> <kind> <reason> | UNKNOWN <K> (no mirror file) | NOT-CORE <K>.
// A path match makes every key core unless the key has its own bypass; the `core` label
// makes only its own key core. A rename or bulk-mechanical change that touches a core path
// is REVIEW: the chief or a judge rules it per slice (operator 10-31).
export function coreMatch(paths: string[], keys: string[], o: CoreCtx): string[] {
  const res = o.patterns.map((p) => new RegExp(p));
  const hit = paths.map((p) => posix.normalize(p)).find((p) => !TEST_PATH.test(p) && matchesAny(res, p));
  const byPath = (k: string) => (o.changeClass ? `REVIEW ${k} ${hit} ${o.changeClass}` : `CORE ${k} ${hit}`);
  return keys.map((k) => {
    if (o.issues === undefined) return hit === undefined ? `NOT-CORE ${k}` : byPath(k);
    const snap = o.issues?.get(k);
    if (!snap) return `UNKNOWN ${k}`;
    if (hit === undefined && !snap.labels?.includes('core')) return `NOT-CORE ${k}`;
    const bypass = bypassOf(k, snap, hit === undefined, o);
    if (bypass) return `BYPASS ${k} ${bypass}`;
    return hit === undefined ? `CORE ${k} label core` : byPath(k);
  });
}
