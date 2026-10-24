import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { request } from '../client.js';

// Sector is an opt-in single-select custom field. Its id is non-secret config:
// `jira.sectorField` in ~/.himmel/config.json (the JIRA_SECTOR_FIELD env var
// overrides it). Unset or `none` means the project does not use sectors, so
// nothing requires or sends one. `jira sector setup` creates the field and
// prints the config line; it never writes the file.

/** The suggested default set, offered by `sector setup`; the live option list is the authority. */
export const SECTORS = [
  'Fleet orchestration',
  'Ship loop',
  'Safety & enforcement',
  'Cost & efficiency',
  'Visibility',
  'Quality & proof',
  'Deployment',
  'Knowledge & steering',
  'Planning & tracking',
] as const;

export const SECTOR_OPT_OUT = 'none';

function configSectorField(): string {
  const path = join(homedir(), '.himmel', 'config.json');
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return ''; // no config file: sectors are off
    throw new Error(`${path} is unreadable: ${(e as Error).message}`);
  }
  let cfg: { jira?: { sectorField?: unknown } } | null;
  try {
    cfg = JSON.parse(text);
  } catch (e) {
    throw new Error(`${path} is not valid JSON, so jira.sectorField cannot be read: ${(e as Error).message}`);
  }
  const v = cfg?.jira?.sectorField;
  if (v === undefined) return '';
  if (typeof v !== 'string') throw new Error(`${path}: jira.sectorField must be a string (a custom field id or "none")`);
  return v;
}

/** The configured custom field id, or undefined when sectors are not in use. */
export function sectorField(): string | undefined {
  const v = (process.env.JIRA_SECTOR_FIELD || configSectorField()).trim();
  return v === '' || v.toLowerCase() === SECTOR_OPT_OUT ? undefined : v;
}

const OPTIONS_TTL_MS = 5 * 60_000;
let cache: { field: string; at: number; options: string[] } | undefined;

/** The field's option labels, read live from its Jira contexts (cached for a few minutes). */
export async function sectorOptions(req: typeof request = request): Promise<string[]> {
  const field = sectorField();
  if (!field) return [];
  if (cache && cache.field === field && Date.now() - cache.at < OPTIONS_TTL_MS) return cache.options;
  const options = new Set<string>();
  try {
    for (const c of await pages<{ id: string }>(req, `/field/${field}/context`)) {
      for (const o of await pages<{ value: string; disabled?: boolean }>(req, `/field/${field}/context/${c.id}/option`)) {
        if (!o.disabled) options.add(o.value);
      }
    }
  } catch {
    // The context API needs Administer Jira. Without it the list is unknown, so
    // return it empty and uncached: resolveSector passes the typed name through
    // and Jira itself validates it.
    return [];
  }
  cache = { field, at: Date.now(), options: [...options] };
  return cache.options;
}

/** Every value of a paginated Jira list endpoint. */
async function pages<T>(req: typeof request, path: string): Promise<T[]> {
  const out: T[] = [];
  for (let startAt = 0; ; ) {
    const page = await req<{ values?: T[]; isLast?: boolean }>('GET', `${path}?startAt=${startAt}&maxResults=100`);
    const values = page.values ?? [];
    out.push(...values);
    if (page.isLast !== false || values.length === 0) return out;
    startAt += values.length;
  }
}

/** Drops the cached option list (tests). */
export function resetSectorCache(): void {
  cache = undefined;
}

export function sectorHint(options: readonly string[]): string {
  return (
    `valid sectors: ${options.join(', ')}. ` +
    `To stop using sectors run \`jira sector setup --opt-out\` (it prints the config line).`
  );
}

// Case-insensitive match to the canonical option label; an unknown option is
// refused here so a typo never reaches Jira (which would answer a bare 400).
export function resolveSector(name: string, options: readonly string[]): string {
  if (options.length === 0) return name.trim(); // option list unreadable: Jira validates
  const want = name.trim().toLowerCase();
  const hit = options.find((s) => s.toLowerCase() === want);
  if (!hit) {
    throw new Error(`Unknown sector '${name}'. ${sectorHint(options)}`);
  }
  return hit;
}

/** The configured field id; throws when --sector is used but sectors are not configured. */
export function requireSectorField(): string {
  const f = sectorField();
  if (!f) {
    throw new Error(
      'Sector is not configured (jira.sectorField in ~/.himmel/config.json is unset or none). ' +
        'Run `jira sector setup` to create the field, or drop --sector.',
    );
  }
  return f;
}

export function sectorOf(fields: Record<string, unknown> | undefined): string | undefined {
  const f = sectorField();
  return f ? (fields?.[f] as { value?: string } | null | undefined)?.value : undefined;
}
