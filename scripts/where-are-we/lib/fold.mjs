// scripts/where-are-we/lib/fold.mjs
import { hasField, isClear, validateRecord } from './schema.mjs';

export const TERMINAL = new Set(['done', 'merged']);
const MERGEABLE = ['status', 'status_category', 'pr', 'branch', 'next_action', 'blockers', 'awaiting_operator', 'lock'];

export function isTerminal(item) {
  if (item.kind === 'ticket' && item.status_category) return item.status_category === 'done';
  return TERMINAL.has(item.status) || (item.kind === 'pr' && item.status === 'closed');
}

function authoritative(field, source, kind) {
  switch (field) {
    case 'status_category': return kind === 'ticket' && source === 'jira';
    case 'status': case 'pr': case 'branch':
      if (kind === 'ticket') return source === 'jira';
      if (kind === 'pr') return source === 'pr' || source === 'git';
      return true; // handover-item
    case 'next_action': case 'blockers':
      return source === 'handover';
    case 'lock': case 'awaiting_operator':
      return true;
    default:
      return true;
  }
}

export function fold(records) {
  const items = {};
  const sources = {};
  // Sort stably by ts; equal-ts → last-in-input wins (stable sort preserves input order)
  const sorted = [...records].sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  for (const r of sorted) {
    if (!validateRecord(r).ok) continue;        // skip malformed (validateRecord wired in here)
    if (r.kind === 'collection') {
      const previous = sources[r.source] ?? {};
      sources[r.source] = { ...previous, attempted_at: r.ts, errors: r.errors ?? [],
        ...(r.observed_at ? { observed_at: r.observed_at } : {}) };
      continue;
    }
    const it = items[r.key] || (items[r.key] = { key: r.key, kind: r.kind });
    it.kind = r.kind; // kind is stable; last wins harmlessly
    if (r.source === 'jira' && r.kind === 'ticket' && hasField(r, 'status')) {
      delete it.status_category; // category belongs to this observation, never an older status
    }
    for (const f of MERGEABLE) {
      if (!hasField(r, f)) continue;            // omitted = no-op
      if (!authoritative(f, r.source, it.kind)) continue;
      if (isClear(r, f)) { delete it[f]; continue; } // explicit-empty clears
      it[f] = r[f];                              // newest-replace
    }
  }
  const awaiting_operator = Object.values(items)
    .filter((it) => Array.isArray(it.awaiting_operator) && it.awaiting_operator.length)
    .map((it) => ({ key: it.key, items: it.awaiting_operator }));
  const locks = Object.values(items)
    .filter((it) => it.lock != null)
    .map((it) => ({ key: it.key, lock: it.lock }));
  return { items, awaiting_operator, locks, ...(Object.keys(sources).length ? { sources } : {}) };
}

export function inFlight(state) {
  return Object.values(state.items).filter((it) => !isTerminal(it));
}
