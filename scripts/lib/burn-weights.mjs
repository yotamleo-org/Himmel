// burn-weights.mjs - the cache-read price per model for the JS/TS cost code.
// Reads scripts/lanes/lib/cache-read-weights.tsv, the one table scripts/lanes/lib/burn-weights.sh also
// reads. A model with no row, or none given, reads at the default (0.1);
// WORKER_SESSION_BURN_W_CACHE_READ set in the environment prices every model flat.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const flat = process.env.WORKER_SESSION_BURN_W_CACHE_READ;
export const DEFAULT_CACHE_READ = flat !== undefined && flat !== '' ? Number(flat) : 0.1;
const rows = readFileSync(fileURLToPath(new URL('../lanes/lib/cache-read-weights.tsv', import.meta.url)), 'utf8')
  .split('\n').map((l) => l.split('\t')).filter((p) => p.length === 2 && !p[0].startsWith('#'))
  .map(([prefix, w]) => [prefix, Number(w)]);

export function cacheReadWeight(model) {
  if (flat !== undefined && flat !== '') return DEFAULT_CACHE_READ;
  const row = typeof model === 'string' ? rows.find(([prefix]) => model.startsWith(prefix)) : undefined;
  return row ? row[1] : DEFAULT_CACHE_READ;
}
