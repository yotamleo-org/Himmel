import type { Command } from 'commander';
import { request } from '../client.js';
import { printJson } from '../output.js';

interface ChangelogItem { field: string; fromString: string | null; toString: string | null }
interface ChangelogEntry { created: string; author?: { displayName?: string }; items: ChangelogItem[] }
interface ChangelogPage { startAt: number; maxResults: number; isLast?: boolean; total?: number; values: ChangelogEntry[] }

const PAGE = 100;

export async function fetchChangelog(key: string): Promise<ChangelogEntry[]> {
  const all: ChangelogEntry[] = [];
  for (let startAt = 0; ; ) {
    const page = await request<ChangelogPage>('GET', `/issue/${key}/changelog?startAt=${startAt}&maxResults=${PAGE}`);
    all.push(...page.values);
    startAt += page.values.length;
    const done = page.isLast ?? (page.total === undefined || startAt >= page.total);
    if (done || page.values.length === 0) return all;
  }
}

export function registerHistory(program: Command): void {
  program
    .command('history <key>')
    .description('Print an issue changelog: who changed which field, from what to what, oldest first')
    .option('--field <name>', 'Only items on this field (case-insensitive, e.g. "Fix Version", status)')
    .option('--json', 'Output the raw changelog entries (ignores --field)')
    .action(async (key: string, options: { field?: string; json?: boolean }) => {
      let entries: ChangelogEntry[];
      try {
        entries = await fetchChangelog(key);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        process.stderr.write(`jira: history ${key} failed: ${msg}\n`);
        process.exit(1);
      }
      if (options.json) {
        printJson(entries);
        return;
      }
      const want = options.field?.toLowerCase();
      for (const e of entries) {
        for (const i of e.items) {
          if (want && i.field.toLowerCase() !== want) continue;
          console.log(`${e.created}  ${e.author?.displayName ?? '?'}  ${i.field}: ${i.fromString ?? '(none)'} → ${i.toString ?? '(none)'}`);
        }
      }
    });
}
