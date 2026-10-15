// per-kind cache hit rate and TTL pick from launches.jsonl.
// Usage: node cache-report.mjs [<launches.jsonl>]   (default: the account-home state dir's launches.jsonl)
// Groups are "<kind> | <model> | <organization_id>": each model has its own cache and a cache never crosses organizations.
// Gaps are between launch records (completion time), so a long call can make an expired prefix look reusable.
// Hit rate = cache_read / (input + cache_creation + cache_read), the same share docs/internals/prompt-cache.md uses.
// TTL pick, in base-input-token equivalents (write 5m 1.25x, write 1h 2x, read 0.1x): a run whose gap since the previous run
// of its kind is within the TTL reads its prefix P (cache_creation + cache_read) at 0.1x, otherwise it writes it again.
// ponytail: P is the prefix a run touched, not the share it re-sent, and the first run of a kind pays the write on both
// tiers; upgrade path: per-turn usage once claude-api.sh keeps more than the summed split.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const file = process.argv[2] ?? join(homedir(), '.himmel', 'state', 'api-credit', 'launches.jsonl');
const kinds = Object.create(null);
for (const line of readFileSync(file, 'utf8').split('\n')) {
  let r;
  try { r = JSON.parse(line); } catch { continue; }
  if (![r.input_tokens, r.cache_creation_tokens, r.cache_read_tokens].every(Number.isInteger)) continue;
  // Only runs of one kind on one model in one organization can read each other's prefix.
  (kinds[`${r.kind ?? 'other'} | ${r.model ?? '?'} | ${r.organization_id ?? '?'}`] ??= []).push({ ...r, t: Date.parse(r.ts) });
}

const out = Object.create(null);
for (const [kind, rows] of Object.entries(kinds)) {
  rows.sort((a, b) => a.t - b.t);
  let input = 0, create = 0, read = 0, cost5 = 0, cost1h = 0;
  const gaps = [];
  rows.forEach((r, i) => {
    input += r.input_tokens; create += r.cache_creation_tokens; read += r.cache_read_tokens;
    const p = r.cache_creation_tokens + r.cache_read_tokens;
    const gap = i === 0 ? Infinity : (r.t - rows[i - 1].t) / 1000;
    if (i > 0) gaps.push(gap);
    cost5 += gap <= 300 ? 0.1 * p : 1.25 * p;
    cost1h += gap <= 3600 ? 0.1 * p : 2 * p;
  });
  out[kind] = { runs: rows.length, input, cache_creation: create, cache_read: read,
    hit_rate: read / (input + create + read), gaps_s: gaps,
    cost_5m_eq: cost5, cost_1h_eq: cost1h, recommended_ttl: cost1h < cost5 ? '1h' : '5m' };
}
console.log(JSON.stringify(out, null, 2));
