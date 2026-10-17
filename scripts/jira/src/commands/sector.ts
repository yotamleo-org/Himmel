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
  try {
    const cfg = JSON.parse(readFileSync(join(homedir(), '.himmel', 'config.json'), 'utf8')) as {
      jira?: { sectorField?: unknown };
    };
    const v = cfg.jira?.sectorField;
    return typeof v === 'string' ? v : '';
  } catch {
    return ''; // missing or unreadable config: sectors are off
  }
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
  const ctxs = await req<{ values?: Array<{ id: string }> }>('GET', `/field/${field}/context`);
  const options = new Set<string>();
  for (const c of ctxs.values ?? []) {
    const opts = await req<{ values?: Array<{ value: string; disabled?: boolean }> }>(
      'GET',
      `/field/${field}/context/${c.id}/option?maxResults=100`,
    );
    for (const o of opts.values ?? []) if (!o.disabled) options.add(o.value);
  }
  cache = { field, at: Date.now(), options: [...options] };
  return cache.options;
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
