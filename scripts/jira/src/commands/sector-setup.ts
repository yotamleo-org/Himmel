import { createInterface } from 'node:readline/promises';
import type { Command } from 'commander';
import { request } from '../client.js';
import { SECTORS, SECTOR_OPT_OUT } from './sector.js';

export const SECTOR_EXPLANATION = `A sector is a stable, coarse product area: the "where in the system" axis of a
ticket. It is orthogonal to epics (the "what goal" axis) and versions (the
"when" axis).

Tagging every ticket with one lets a board, a tracker or a report answer "where
is our effort going, and which area is starved?" without hand-tagging, and the
home rule (a sector plus an epic or the standalone label) stops orphan tickets.
Sectors are optional: \`jira sector setup --opt-out\` turns them off.`;

const FIELD_TYPE = 'com.atlassian.jira.plugin.system.customfieldtypes:select';
const FIELD_SEARCHER = 'com.atlassian.jira.plugin.system.customfieldtypes:multiselectsearcher';

export type Call = { method: string; path: string; body?: unknown };

/** The exact Jira calls setup makes; `<field id>` and `<context id>` are filled from earlier responses. */
export function setupCalls(sectors: readonly string[]): Call[] {
  return [
    {
      method: 'POST',
      path: '/field',
      body: {
        name: 'Sector',
        description: 'Coarse product area of the ticket (himmel sector)',
        type: FIELD_TYPE,
        searcherKey: FIELD_SEARCHER,
      },
    },
    { method: 'GET', path: '/field/<field id>/context' },
    {
      method: 'POST',
      path: '/field/<field id>/context/<context id>/option',
      body: { options: sectors.map((value) => ({ value })) },
    },
    { method: 'POST', path: '/screens/addToDefault/<field id>' },
  ];
}

/** The config.json snippet for ~/.himmel/config.json; setup prints it and never writes that file. */
export function configSnippet(value: string): string {
  const note = 'merge into any existing "jira" object; setup never writes this file';
  return `Add this to ~/.himmel/config.json (${note}):\n${JSON.stringify({ jira: { sectorField: value } }, null, 2)}`;
}

export type SetupOptions = { dryRun?: boolean; yes?: boolean; optOut?: boolean; sectors?: string };

export async function runSetup(o: SetupOptions, ask: (q: string) => Promise<string> = promptLine): Promise<void> {
  if (o.optOut) {
    console.log(
      `Opting out of sectors. Lost: create no longer requires or sends a Sector, \`edit --sector\` and\n` +
        `\`edit-batch\` refuse, and \`get\` stops showing it. The Jira field itself is untouched.`,
    );
    console.log(configSnippet(SECTOR_OPT_OUT));
    return;
  }
  const sectors = o.sectors
    ? o.sectors.split(',').map((s) => s.trim()).filter(Boolean)
    : [...SECTORS];
  if (sectors.length === 0) throw new Error('--sectors needs at least one name');
  console.log(SECTOR_EXPLANATION + '\n');
  console.log(`Proposed sectors${o.sectors ? '' : ' (default set; change with --sectors "A,B,C")'}:`);
  for (const s of sectors) console.log(`  - ${s}`);
  console.log('\nJira calls:');
  for (const c of setupCalls(sectors)) {
    console.log(`  ${c.method} ${c.path}${c.body ? ' ' + JSON.stringify(c.body) : ''}`);
  }
  if (o.dryRun) {
    console.log('\ndry run: nothing was created.');
    return;
  }
  if (!o.yes && !/^y(es)?$/i.test((await ask('\nCreate the Sector field now? [y/N] ')).trim())) {
    console.log('Aborted; nothing was created.');
    return;
  }
  const [create, , options, screen] = setupCalls(sectors) as [Call, Call, Call, Call];
  const field = await request<{ id: string }>(create.method, create.path, create.body);
  const ctxs = await request<{ values?: Array<{ id: string }> }>('GET', `/field/${field.id}/context`);
  const ctx = ctxs.values?.[0]?.id;
  if (!ctx) throw new Error(`created ${field.id} but it has no context to add options to`);
  await request(options.method, options.path.replace('<field id>', field.id).replace('<context id>', ctx), options.body);
  try {
    await request(screen.method, screen.path.replace('<field id>', field.id));
  } catch (e) {
    console.error(`jira: warning: could not add ${field.id} to the default screen (${(e as Error).message}); add it to your create screen by hand`);
  }
  console.log(`\nCreated ${field.id} with ${sectors.length} options.\n${configSnippet(field.id)}`);
}

async function promptLine(q: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return await rl.question(q);
  } finally {
    rl.close();
  }
}

export function registerSector(program: Command): void {
  program
    .command('sector')
    .description('Sector custom field: `sector setup` explains sectors, creates the field and its options, or opts out')
    .command('setup')
    .description('Create the single-select Sector field with a suggested option set, or --opt-out')
    .option('--dry-run', 'print the explanation, the proposed set and the exact Jira calls; create nothing')
    .option('--yes', 'skip the confirmation prompt')
    .option('--opt-out', `print the config line ("${SECTOR_OPT_OUT}") that stops requiring sectors`)
    .option('--sectors <list>', 'comma-separated option names instead of the default set')
    .action((options: SetupOptions) => runSetup(options));
}
