import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';
import { earliestUnreleased, fetchVersions, projectFromKey, setFixVersion } from './versions.js';

export function findTransition(
  transitions: JiraTransition[],
  name: string,
): JiraTransition | undefined {
  return transitions.find(
    (t) => t.name.toLowerCase() === name.toLowerCase(),
  );
}

export function registerTransition(program: Command): void {
  program
    .command('transition <key> <status>')
    .description('Transition a Jira issue to a new status')
    .option('--no-version', 'Do not stamp the current fixVersion on a versionless Done close')
    .action(async (key: string, status: string, options: { version: boolean }) => {
      const { transitions } = await request<{ transitions: JiraTransition[] }>(
        'GET',
        `/issue/${key}/transitions`,
      );
      const match = findTransition(transitions, status);
      if (!match) {
        console.error(`Transition "${status}" not found. Available:`);
        for (const t of transitions) console.error(`- ${t.name}`);
        process.exit(1);
      }
      // Stamp before the transition: a failed lookup or update then leaves the
      // issue open instead of Done-and-unstamped, and a workflow that locks
      // edits once Done cannot reject the stamp.
      // ponytail: only the `Done` status stamps; Closed / wont do / wont fix never do, and
      // another Done-category status would need statusCategory from the transition payload.
      if (options.version && match.name.toLowerCase() === 'done') {
        const fixVersions = (
          await request<{ fields: { fixVersions?: unknown[] } }>('GET', `/issue/${key}?fields=fixVersions`)
        ).fields.fixVersions;
        if (!fixVersions || fixVersions.length === 0) {
          const version = earliestUnreleased(await fetchVersions(projectFromKey(key)));
          if (version) {
            await setFixVersion(key, 'add', version);
            console.log(`${key} fixVersion +${version} (earliest unreleased; --no-version opts out)`);
          }
        }
      }
      await request('POST', `/issue/${key}/transitions`, {
        transition: { id: match.id },
      });
      writeJiraBreadcrumb(key);
      console.log(`${key} → ${match.name}`);
    });
}
