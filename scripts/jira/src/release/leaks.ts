import type { Admission } from '../commands/admissions-ledger.js';
import type { JiraPort } from './engine.js';
import { terminalOf } from './reducer.js';
import type { IssueSnap } from './types.js';

// A frozen version's leaks: the tickets open in it that are neither in its
// frozen set nor ruled in by a ledger row. Jira UI and MCP writes cannot be
// gated, so this diff is what catches them.

const KEY = /^[A-Z][A-Z0-9]*-\d+$/;

// The key's latest row decides: a deferral or removal after an admission withdraws it.
// A row keyed by a check id (a version-ready override) is not an admission.
const admits = (row: Admission | undefined): boolean =>
  row !== undefined && row.kind !== 'deferral' && row.kind !== 'rm-remove' && KEY.test(row.key);

/** Open tickets carrying `version`, minus the frozen keys and the keys the ledger admits. Sorted. */
export function leakDiff(
  version: string,
  frozenKeys: string[],
  issues: Map<string, IssueSnap>,
  ledger: Admission[],
): string[] {
  const frozen = new Set(frozenKeys);
  return [...issues.values()]
    .filter((i) => i.fixVersions.includes(version) && terminalOf(i) === null && !frozen.has(i.key))
    .filter((i) => !admits(ledger.filter((l) => l.version === version && l.key === i.key).pop()))
    .map((i) => i.key)
    .sort();
}

/** The `admission-budget:N` line of a version description; absent means the count is shown alone. */
export function admissionBudget(description: string | undefined): number | undefined {
  const m = /^[ \t]*admission-budget:[ \t]*(\d+)[ \t]*\r?$/m.exec(description ?? '');
  return m ? Number(m[1]) : undefined;
}

export const leakMarker = (version: string): string => `[intake-leak ${version}]`;

export const leakLine = (key: string, version: string, frozenOn: string): string =>
  `LEAK ${key}@${version} — carries ${version} (frozen ${frozenOn}) with no frozen-set membership and no admissions-ledger row`;

/** One comment per leak: a leak already carrying the marker is left alone, so a nightly run never repeats it. Returns the keys commented. */
export async function commentLeaks(
  jira: Pick<JiraPort, 'findComment' | 'addComment'>,
  keys: string[],
  version: string,
  frozenOn: string,
): Promise<string[]> {
  const marker = leakMarker(version);
  const posted: string[] = [];
  for (const key of keys) {
    if (await jira.findComment(key, marker)) continue;
    await jira.addComment(
      key,
      `${marker} ${key} carries ${version}, frozen ${frozenOn}, but is not in the frozen set and has no admissions-ledger row. ` +
        `Admit it with \`jira edit ${key} --gate critical|regression|must:<decision-ref>|receipt\`, or move it to a later version.`,
    );
    posted.push(key);
  }
  return posted;
}
