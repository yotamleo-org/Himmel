// The one owner of "is this path core?". scripts/ci/core-paths.txt lists the ship-loop
// files; coreMatch reads a change against it and returns one verdict line per key.
// Nothing else reads core-paths.txt.
import { readFileSync } from 'node:fs';
import { posix } from 'node:path';

export type ChangeClass = 'rename' | 'bulk';

export const MAX_CORE_SHARE = 0.02;

export function parseCorePatterns(text: string): string[] {
  return text.split('\n').map((l) => l.trim()).filter((l) => l !== '' && !l.startsWith('#'));
}

export const loadCorePatterns = (file: string): string[] => parseCorePatterns(readFileSync(file, 'utf8'));

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

// CORE <K> <first matched path> | REVIEW <K> <path> <class> | NOT-CORE <K>.
// A rename or bulk-mechanical change that touches a core path is REVIEW: the chief or a
// judge rules it per slice (operator 10-31). A match decides every key of the worker.
export function coreMatch(
  paths: string[], keys: string[], o: { patterns: string[]; changeClass?: ChangeClass },
): string[] {
  const res = o.patterns.map((p) => new RegExp(p));
  const hit = paths.map((p) => posix.normalize(p)).find((p) => !TEST_PATH.test(p) && matchesAny(res, p));
  return keys.map((k) => {
    if (hit === undefined) return `NOT-CORE ${k}`;
    return o.changeClass ? `REVIEW ${k} ${hit} ${o.changeClass}` : `CORE ${k} ${hit}`;
  });
}
