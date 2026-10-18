import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { requireSectorField, resolveSector, sectorOf, sectorOptions } from './sector.js';

const KEY_RE = /^[A-Z][A-Z0-9]*-\d+$/;

// Sets one row; returns the TSV result columns after key+sector.
async function applyRow(key: string, sectorArg: string): Promise<{ sector: string; result: string }> {
  let sector = sectorArg;
  try {
    const field = requireSectorField();
    sector = resolveSector(sectorArg, await sectorOptions());
    if (!KEY_RE.test(key)) throw new Error(`Invalid issue key '${key}'`);
    const cur = await request<{ fields?: Record<string, unknown> }>('GET', `/issue/${key}?fields=${field}`);
    if (sectorOf(cur.fields) === sector) return { sector, result: 'unchanged' };
    await request('PUT', `/issue/${key}`, { fields: { [field]: { value: sector } } });
    const got = await request<{ fields?: Record<string, unknown> }>('GET', `/issue/${key}?fields=${field}`);
    const actual = sectorOf(got.fields);
    if (actual !== sector) {
      throw new Error(`requested '${sector}' but the issue still reads '${actual ?? 'none'}' after the PUT`);
    }
    writeJiraBreadcrumb(key);
    return { sector, result: 'set' };
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).replace(/\s+/g, ' ');
    return { sector, result: `failed\t${msg}` };
  }
}

export function registerEditBatch(program: Command): void {
  program
    .command('edit-batch')
    .description(
      'Set the Sector field on many issues from a TSV file (columns: key, sector). Prints one ' +
        'result row per input row (key, sector, set|unchanged|failed[, reason]); a failed row never ' +
        'aborts the run (exit 1 at the end if any failed); re-running is idempotent',
    )
    .requiredOption('--file <tsv>', 'TSV file: key<TAB>sector per line (a "key<TAB>sector" header row is skipped)')
    .action(async (options: { file: string }) => {
      const lines = readFileSync(options.file, 'utf8').split('\n');
      let failed = 0;
      for (const raw of lines) {
        const line = raw.replace(/\r$/, '');
        if (line.trim() === '') continue;
        const cols = line.split('\t');
        const key = (cols[0] ?? '').trim();
        const sectorArg = (cols[1] ?? '').trim();
        if (cols.length === 2 && key.toLowerCase() === 'key' && sectorArg.toLowerCase() === 'sector') continue;
        const { sector, result } =
          cols.length === 2
            ? await applyRow(key, sectorArg)
            : { sector: sectorArg, result: `failed\texpected 2 columns (key, sector), got ${cols.length}` };
        if (result.startsWith('failed')) failed++;
        console.log(`${key}\t${sector}\t${result}`);
      }
      if (failed > 0) process.exitCode = 1;
    });
}
