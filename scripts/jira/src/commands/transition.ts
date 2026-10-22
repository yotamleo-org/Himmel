import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';
import { readAdmissions } from './admissions-ledger.js';
import { parseFrozen } from './version-freeze.js';
import { earliestUnreleased, fetchVersions, projectFromKey, setFixVersion } from './versions.js';

// Jira's transitions list names the status each one lands on; the shared
// JiraTransition type does not declare it.
type TargetedTransition = JiraTransition & { to?: { name?: string } };

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
          const versions = await fetchVersions(projectFromKey(key));
          const version = earliestUnreleased(versions);
          // A frozen version takes only a ruled-in ticket: a frozen-set key or one with a
          // non-deferral ledger row; any other is closed unstamped, never leaked in.
          const frozen = parseFrozen(versions.find((v) => v.name === version)?.description);
          const ruledIn =
            !frozen ||
            frozen.keys.includes(key) ||
            readAdmissions(version).some((r) => r.key === key && r.kind !== 'deferral');
          if (version && !ruledIn) {
            console.log(`${key} not stamped: ${version} is frozen and ${key} has no intake ruling`);
          } else if (version) {
            await setFixVersion(key, 'add', version);
            console.log(`${key} fixVersion +${version} (earliest unreleased; --no-version opts out)`);
          }
        }
      }
      await request('POST', `/issue/${key}/transitions`, {
        transition: { id: match.id },
      });
      // A 2xx POST does not prove the status moved (a validator or post
      // function can swallow it), so read the status back and fail loud.
      const target = (match as TargetedTransition).to?.name;
      if (target) {
        const got = await request<{ fields?: { status?: { name?: string } } }>(
          'GET',
          `/issue/${key}?fields=status`,
        );
        const actual = got.fields?.status?.name;
        if (actual?.toLowerCase() !== target.toLowerCase()) {
          throw new Error(
            `Transition ${key}: status was not changed — requested '${target}' but the issue ` +
              `still reads '${actual || 'none'}' after the POST.`,
          );
        }
      }
      writeJiraBreadcrumb(key);
      console.log(`${key} → ${match.name}`);
    });
}
