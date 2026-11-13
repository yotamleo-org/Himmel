import type { Command } from 'commander';
import { request } from '../client.js';
import { browseLine } from '../browse-line.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';
import { readAdmissions } from './admissions-ledger.js';
import { parseFrozen } from './version-freeze.js';
import { earliestUnreleased, fetchVersions, projectFromKey, setFixVersion } from './versions.js';
import { admits } from '../release/admits.js';
import { fileCloseIntake, mergedPrOf, requestLine } from '../release/close-placement.js';
import { isPhaseLabel, phaseSwap } from '../phase.js';

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
  /** The phase label(s) a Done-category close could not remove; the WARN is already printed. */
  phaseLeft?: string;
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
      await req<{ fields: { fixVersions?: Array<{ name?: string }> } }>('GET', `/issue/${key}?fields=fixVersions`)
    ).fields.fixVersions;
    const versions = await fetchVersions(projectFromKey(key));
    if (!fixVersions || fixVersions.length === 0) {
      const version = earliestUnreleased(versions);
      if (version) {
        const placement = await placeInto(key, version, versions, 'earliest unreleased; --no-version opts out');
        if (placement.write) {
          await setFixVersion(key, 'add', version, 'transition-stamp');
          console.log(`${key} fixVersion +${version} (${placement.note})`);
        } else {
          unstamped = placement.why;
        }
      }
    } else {
      await foldIntoCurrent(key, fixVersions.map((v) => v.name ?? ''), versions);
    }
  }
  await req('POST', `/issue/${key}/transitions`, { transition: { id: match.id } });
  const target = (match as TargetedTransition).to?.name ?? match.name;
  let actual: string | undefined;
  let category: string | undefined;
  let labels: string[] = [];
  try {
    const f = (await req<{ fields?: { status?: { name?: string; statusCategory?: { key?: string } }; labels?: string[] } }>('GET', `/issue/${key}?fields=status,labels`)).fields;
    actual = f?.status?.name;
    category = f?.status?.statusCategory?.key;
    labels = Array.isArray(f?.labels) ? f.labels : [];
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
  const phaseLeft = category === 'done' ? await clearPhase(key, labels, req) : undefined;
  return { name: match.name, unstamped, phaseLeft };
}

type Placement = { write: true; note: string } | { write: false; why: string };

/**
 * May `key` be written into `version`? A frozen version takes a key in its frozen set or one the
 * admissions ledger admits; one the ledger shows as deferred or removed is ruled out; any other key is
 * a placement for the release manager, so its INTAKE is filed with the merged PR as evidence first.
 */
async function placeInto(
  key: string,
  version: string,
  versions: Array<{ name: string; description?: string }>,
  plainNote: string,
): Promise<Placement> {
  const frozen = parseFrozen(versions.find((v) => v.name === version)?.description);
  if (frozen === undefined || frozen.keys.includes(key)) return { write: true, note: plainNote };
  const latest = readAdmissions(version).filter((r) => r.key === key).pop();
  if (latest?.kind === 'deferral' || latest?.kind === 'rm-remove') {
    return { write: false, why: `${version} is frozen and the latest ledger row for ${key} is a ${latest.kind}` };
  }
  if (admits(latest)) return { write: true, note: plainNote };
  const pr = mergedPrOf(key);
  if (!pr) {
    return { write: false, why: `${version} is frozen and ${key} has no merged PR to file its INTAKE with; run: ${requestLine(key, version)}` };
  }
  try {
    fileCloseIntake(key, version, pr);
  } catch (e) {
    return {
      write: false,
      why: `${version} is frozen and the INTAKE for ${key} with merged PR #${pr.number} could not be filed (${(e as Error).message}); run: ${requestLine(key, version)}`,
    };
  }
  return { write: true, note: `frozen: INTAKE filed with merged PR #${pr.number}` };
}

interface ProjectVersion {
  name: string;
  released?: boolean;
  archived?: boolean;
  releaseDate?: string;
  description?: string;
}

// The current version: the earliest unreleased by release date (archived never), else the first live one
// in list order. merge-on-green.sh folds into the same version.
function currentVersion(versions: ProjectVersion[]): string | undefined {
  const live = versions.filter((v) => !v.released && !v.archived);
  const dated = live
    .filter((v) => v.releaseDate)
    .sort((a, b) => (a.releaseDate! < b.releaseDate! ? -1 : a.releaseDate! > b.releaseDate! ? 1 : 0));
  return (dated[0] ?? live[0])?.name;
}

/**
 * A Done close of a ticket that holds an unreleased version later than the current one moves it into the
 * current version: add the current, then remove each later one. Released and archived versions it holds
 * stay. A refusal or a failed write leaves the held versions as they were and prints one line; the close
 * itself still lands and the exit code is unchanged.
 */
async function foldIntoCurrent(key: string, held: string[], versions: ProjectVersion[]): Promise<void> {
  const cur = currentVersion(versions);
  if (!cur) return;
  const open = new Set(versions.filter((v) => !v.released && !v.archived).map((v) => v.name));
  const later = held.filter((n) => open.has(n) && n !== cur);
  if (later.length === 0) return;
  const placement = await placeInto(key, cur, versions, 'current');
  if (!placement.write) {
    console.log(`${key} keeps ${later.join(', ')}: ${placement.why}`);
    return;
  }
  try {
    if (!held.includes(cur)) await setFixVersion(key, 'add', cur, 'transition-stamp');
    for (const n of later) await setFixVersion(key, 'remove', n, 'transition-stamp');
  } catch (e) {
    console.error(`WARN ${key} fold from ${later.join(', ')} to ${cur} did not finish (${(e as Error).message}); check its fixVersions`);
    return;
  }
  console.log(`${key} fixVersion +${cur} -${later.join(', -')} (folded into the current version; --no-version opts out)`);
}

async function clearPhase(key: string, labels: string[], req: typeof request): Promise<string | undefined> {
  const had = labels.filter(isPhaseLabel);
  if (had.length === 0) return undefined;
  let left = had;
  let why = 'the read-back still holds it';
  try {
    await req('PUT', `/issue/${key}`, { update: phaseSwap(labels, 'none') });
    const back = (await req<{ fields?: { labels?: unknown } }>('GET', `/issue/${key}?fields=labels`)).fields?.labels;
    if (Array.isArray(back)) left = (back as string[]).filter(isPhaseLabel);
    else why = 'the read-back carried no labels';
  } catch (e) {
    why = (e as Error).message;
  }
  if (left.length === 0) return undefined;
  console.error(`WARN ${key} closed with ${left.join(', ')} still on it (${why})`);
  return left.join(', ');
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
      const browse = browseLine(key);
      if (browse) console.log(browse);
      if (result.unstamped) {
        console.error(`FAIL ${key} closed with no fixVersion: ${result.unstamped}; place it with version-defer --to or edit --fix-version`);
        process.exitCode = 3;
      }
    });
}
