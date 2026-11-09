import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';
import { readAdmissions } from './admissions-ledger.js';
import { parseFrozen } from './version-freeze.js';
import { earliestUnreleased, fetchVersions, projectFromKey, setFixVersion } from './versions.js';
import { admits } from '../release/admits.js';
import { fileCloseIntake, mergedPrOf, requestLine } from '../release/close-placement.js';

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

export class TransitionNotFound extends Error {
  constructor(readonly status: string, readonly available: string[]) {
    super(`Transition "${status}" not found. Available:\n${available.map((n) => `- ${n}`).join('\n')}`);
  }
}

export interface TransitionResult {
  name: string;
  /** Set when a Done close was left unstamped on purpose (a ruled-out frozen key): the caller fails with exit 3. */
  unstamped?: string;
}

/**
 * The one transition operation, shared by `jira transition`, `jira move` (its
 * source close) and the MCP bridge (which runs this CLI verb). A Done close of a
 * versionless ticket is stamped first (see below); then the POST; then the
 * status is read back. A 2xx POST does not prove the status moved (a validator
 * or post function can swallow it), so the read-back always runs: against the
 * transition's `to` status, or its name when the payload carries no `to`.
 */
export async function transitionIssue(
  key: string,
  status: string,
  options: { version: boolean },
  req: typeof request = request,
): Promise<TransitionResult> {
  const { transitions } = await req<{ transitions: JiraTransition[] }>('GET', `/issue/${key}/transitions`);
  const match = findTransition(transitions, status);
  if (!match) throw new TransitionNotFound(status, transitions.map((t) => t.name));
  // ponytail: only the `Done` status stamps; Closed / wont do / wont fix never do, and
  // another Done-category status would need statusCategory from the transition payload.
  let unstamped: string | undefined;
  if (options.version && match.name.toLowerCase() === 'done') {
    const fixVersions = (
      await req<{ fields: { fixVersions?: unknown[] } }>('GET', `/issue/${key}?fields=fixVersions`)
    ).fields.fixVersions;
    if (!fixVersions || fixVersions.length === 0) {
      const versions = await fetchVersions(projectFromKey(key));
      const version = earliestUnreleased(versions);
      const frozen = parseFrozen(versions.find((v) => v.name === version)?.description);
      const latest = frozen ? readAdmissions(version).filter((r) => r.key === key).pop() : undefined;
      const ruledOut =
        frozen !== undefined && !frozen.keys.includes(key) && (latest?.kind === 'deferral' || latest?.kind === 'rm-remove');
      if (version && ruledOut) {
        unstamped = `${version} is frozen and the latest ledger row for ${key} is a ${latest?.kind}`;
      } else if (version && frozen !== undefined && !frozen.keys.includes(key) && !admits(latest)) {
        const pr = mergedPrOf(key);
        if (pr) {
          let failure: string | undefined;
          try {
            fileCloseIntake(key, version, pr);
          } catch (e) {
            failure = (e as Error).message;
          }
          if (failure === undefined) {
            await setFixVersion(key, 'add', version, 'transition-stamp');
            console.log(`${key} fixVersion +${version} (frozen: INTAKE filed with merged PR #${pr.number})`);
          } else {
            unstamped = `${version} is frozen and the INTAKE for ${key} with merged PR #${pr.number} could not be filed (${failure}); run: ${requestLine(key, version)}`;
          }
        } else {
          unstamped = `${version} is frozen and ${key} has no merged PR to file its INTAKE with; run: ${requestLine(key, version)}`;
        }
      } else if (version) {
        await setFixVersion(key, 'add', version, 'transition-stamp');
        console.log(`${key} fixVersion +${version} (earliest unreleased; --no-version opts out)`);
      }
    }
  }
  await req('POST', `/issue/${key}/transitions`, { transition: { id: match.id } });
  const target = (match as TargetedTransition).to?.name ?? match.name;
  let actual: string | undefined;
  try {
    actual = (await req<{ fields?: { status?: { name?: string } } }>('GET', `/issue/${key}?fields=status`)).fields?.status?.name;
  } catch (e) {
    throw new Error(`Transition ${key}: the POST was sent but the status read-back failed (${(e as Error).message}); the outcome is unconfirmed.`);
  }
  if (actual?.toLowerCase() !== target.toLowerCase()) {
    throw new Error(
      `Transition ${key}: status was not changed — requested '${target}' but the issue ` +
        `still reads '${actual || 'none'}' after the POST.`,
    );
  }
  writeJiraBreadcrumb(key);
  return { name: match.name, unstamped };
}

export function registerTransition(program: Command): void {
  program
    .command('transition <key> <status>')
    .description('Transition a Jira issue to a new status')
    .option('--no-version', 'Do not stamp the current fixVersion on a versionless Done close')
    .action(async (key: string, status: string, options: { version: boolean }) => {
      let result: TransitionResult;
      try {
        result = await transitionIssue(key, status, options);
      } catch (e) {
        if (!(e instanceof TransitionNotFound)) throw e;
        console.error(`Transition "${e.status}" not found. Available:`);
        for (const name of e.available) console.error(`- ${name}`);
        process.exit(1);
      }
      console.log(`${key} → ${result.name}`);
      if (result.unstamped) {
        console.error(`FAIL ${key} closed with no fixVersion: ${result.unstamped}; place it with version-defer --to or edit --fix-version`);
        process.exitCode = 3;
      }
    });
}
