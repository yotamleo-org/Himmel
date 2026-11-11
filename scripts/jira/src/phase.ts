import { PHASES, isPhaseLabel } from '../../../marketplace/plugins/himmel-ops/scripts/ticket-policy.mjs';

export { PHASES, isPhaseLabel };

export type Phase = (typeof PHASES)[number];

/** Jira's atomic `update.labels` that leaves exactly `phase:<p>` (or no phase label for `none`), other labels untouched. */
export function phaseSwap(current: readonly string[], p: Phase | 'none'): { labels: Array<{ remove: string } | { add: string }> } {
  const want = p === 'none' ? undefined : `phase:${p}`;
  const ops: Array<{ remove: string } | { add: string }> = current
    .filter((l) => isPhaseLabel(l) && l !== want)
    .map((l) => ({ remove: l }));
  if (want !== undefined && !current.includes(want)) ops.push({ add: want });
  return { labels: ops };
}
