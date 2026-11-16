// scripts/where-are-we/lib/dock.mjs — L2 dock: staleness + freshness + scoped
// render. PURE (no I/O): all time/mtime values are passed in as milliseconds so
// the debounce + render logic is unit-testable. Reuses the L1 contract
// (fold/query/render/renderItem) — adds no new relevance rule beyond the one
// display-routing rule: a terminal (done/merged) ticket-branch shows the global
// digest, not the item card.
import { fold, isTerminal } from './fold.mjs';
import { query } from './query.mjs';
import { render, renderItem } from './render.mjs';

const HOUR_MS = 3600 * 1000;

// True when the marker is missing (null) or older than staleHours.
export function isStale(markerMtimeMs, nowMs, staleHours) {
  if (markerMtimeMs == null) return true;
  return (nowMs - markerMtimeMs) > staleHours * HOUR_MS;
}

// Human freshness line shown as the dock's first line.
export function freshnessLine(markerMtimeMs, nowMs) {
  if (markerMtimeMs == null) return '_where-are-we · never refreshed_';
  const hours = Math.floor((nowMs - markerMtimeMs) / HOUR_MS);
  return `_where-are-we · refreshed ${hours}h ago_`;
}

// Render the relevant slice: an ACTIVE ticket-branch → its item card; otherwise
// (global, no-key branch, OR a terminal-ticket branch) → the global digest.
export function renderDock(records, scope, nowMs, markerMtimeMs) {
  const state = fold(records);
  const r = query(state, scope);
  const body = (r.item && !isTerminal(r.item))
    ? renderItem(r.item, r.locks)
    : render(state);
  const sources = Object.entries(state.sources ?? {}).map(([source, health]) =>
    `- ${source}: ${health.errors.length ? 'stale / unknown' : 'observed'}; last success ${health.observed_at ?? 'never'}${health.errors.length ? `; ${health.errors.join('; ')}` : ''}`);
  const failed = Object.entries(state.sources ?? {}).filter(([, h]) => h.errors.length).map(([s]) => s).sort();
  const freshness = freshnessLine(markerMtimeMs, nowMs);
  const header = failed.length ? freshness.slice(0, -1) + ` · stale sources: ${failed.join(', ')}_` : freshness;
  return header + '\n\n' +
    (sources.length ? sources.join('\n') + '\n\n' : '') + body;
}
