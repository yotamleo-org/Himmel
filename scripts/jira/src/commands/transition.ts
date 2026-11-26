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
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { renderIssue, type MirrorIssue } from './mirror.js';

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
  options: { version: boolean; recover?: boolean },
  req: typeof request = request,
): Promise<TransitionResult> {
  // `recover` is set only by `jira transition --proof`: the chief's decision settles after the status is actually where it asked,
  // so a ticket already there (a lost response, a restart, a KEEP on a To Do ticket) is not transitioned again. Every other caller
  // keeps the original behavior: a status the transitions list lacks is TransitionNotFound and a POST error is the error.
  const before = options.recover
    ? await req<{ fields?: { status?: { name?: string } } }>('GET', `/issue/${key}?fields=status`)
    : undefined;
  const already = before?.fields?.status?.name?.toLowerCase() === status.toLowerCase();
  const { transitions } = await req<{ transitions: JiraTransition[] }>('GET', `/issue/${key}/transitions`);
  const match = findTransition(transitions, status) ?? (already ? { id: '', name: before?.fields?.status?.name ?? status } : undefined);
  if (!match) throw new TransitionNotFound(status, transitions.map((t) => t.name));
  let unstamped: string | undefined;
  if (options.version && match.name.toLowerCase() === 'done') {
    const fixVersions = (
      await req<{ fields: { fixVersions?: Array<{ name?: string }> } }>('GET', `/issue/${key}?fields=fixVersions`)
    ).fields.fixVersions;
    if (fixVersions && fixVersions.length > 0) {
      let versions: ProjectVersion[] | undefined;
      try {
        versions = await fetchVersions(projectFromKey(key));
      } catch (e) {
        console.error(`WARN ${key} keeps ${fixVersions.map((v) => v.name ?? '').join(', ')}: the version list could not be read (${(e as Error).message}); no fold`);
      }
      if (versions) await foldIntoCurrent(key, fixVersions.map((v) => v.name ?? ''), versions);
    } else {
      const versions = await fetchVersions(projectFromKey(key));
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
    }
  }
  // Read first on recovery; a status already confirmed is never transitioned twice.
  let lost: Error | undefined;
  if (!already) {
    try {
      await req('POST', `/issue/${key}/transitions`, { transition: { id: match.id } });
    } catch (e) {
      // Only a transport failure is ambiguous (the POST may have landed); the readback below decides. A server answer
      // (HTTP 4xx/5xx, a refused token) is definite and surfaces unchanged.
      if (!options.recover || !isAmbiguous(e)) throw e;
      lost = e as Error;
    }
  }
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
    throw new Error(`Transition ${key}: the POST was sent but the status read-back failed (${(e as Error).message}); the outcome is unconfirmed.${lost ? ` The POST itself failed first: ${lost.message}.` : ''}`);
  }
  if (actual?.toLowerCase() !== target.toLowerCase()) {
    throw new Error(
      `Transition ${key}: status was not changed — requested '${target}' but the issue ` +
        `still reads '${actual || 'none'}' after the POST.${lost ? ` The POST failed: ${lost.message}.` : ''}`,
    );
  }
  writeJiraBreadcrumb(key);
  const phaseLeft = category === 'done' ? await clearPhase(key, labels, req) : undefined;
  return { name: match.name, unstamped, phaseLeft };
}

// A POST that got no answer: a deadline, a dropped connection. An HTTP status, a refused token or a refused write is an answer.
function isAmbiguous(e: unknown): boolean {
  const message = (e as Error)?.message ?? '';
  if (/^HTTP \d{3}\b|did not accept the API token|refused, nothing was posted/.test(message)) return false;
  return /timed out after|fetch failed|terminated|socket|ECONNRESET|EPIPE|other side closed|network/i.test(`${message} ${(e as { cause?: { message?: string } })?.cause?.message ?? ''}`);
}

type Placement = { write: true; note: string } | { write: false; why: string };

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

function currentVersion(versions: ProjectVersion[]): string | undefined {
  const live = versions.filter((v) => !v.released && !v.archived);
  const dated = live
    .filter((v) => v.releaseDate)
    .sort((a, b) => (a.releaseDate! < b.releaseDate! ? -1 : a.releaseDate! > b.releaseDate! ? 1 : 0));
  return (dated[0] ?? live[0])?.name;
}

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
    .option('--proof <id>', 'Bind a chief proof decision to an existing owed validation action')
    .option('--proof-bucket <path>', 'Existing owed bucket for --proof')
    .option('--proof-decision <path>', 'Explicit chief evidence decision JSON; grants no permission')
    .action(async (key: string, status: string, options: { version: boolean; proof?: string; proofBucket?: string; proofDecision?: string }) => {
      const proofArgs = [options.proof, options.proofBucket, options.proofDecision];
      if (proofArgs.some(Boolean) && !proofArgs.every(Boolean)) throw new Error('--proof, --proof-bucket and --proof-decision are required together');
      const proof = async (mode: '--check' | '--settle', unstamped?: string, decisionHash?: string) => {
        const issue = await request<MirrorIssue & { fields: { status?: { name?: string; statusCategory?: { key?: string } } } }>(
          'GET', `/issue/${key}?fields=description,status`);
        if (issue.fields.description === undefined) throw new Error('proof: current requirements unreadable');
        const mirror = renderIssue(issue, []);
        const output = execFileSync('python3', [fileURLToPath(new URL('../../../handover/chief-kit/proof-validate.py', import.meta.url)),
          '--bucket', options.proofBucket!, mode, options.proof!, '--decision', options.proofDecision!, '--current-stdin',
          ...(decisionHash ? ['--decision-hash', decisionHash] : [])],
          { input: JSON.stringify({ key, mirror, status: issue.fields.status?.name, category: issue.fields.status?.statusCategory?.key, unstamped }), encoding: 'utf8', timeout: 100_000 }); // the validator's remainder read has one 90 s budget (PROOF_REMAINDER_BUDGET_SECS); it refuses inside it, so the wait must outlast it
        return JSON.parse(output) as { closed?: boolean; verdict?: string; decision_hash?: string; reconciliation?: string | null; remainder?: string[] };
      };
      let checkedHash: string | undefined;
      if (options.proof) {
        const checked = await proof('--check');
        if (checked.closed) { console.log(`${key} proof action ${options.proof} already discharged`); return; }
        if (!/^[0-9a-f]{64}$/.test(checked.decision_hash ?? '')) throw new Error('proof: the check returned no decision hash');
        checkedHash = checked.decision_hash;
        if (status.toLowerCase() !== (checked.verdict === 'CLOSE' ? 'done' : 'to do')) throw new Error('proof decision requires Done for CLOSE or To Do for KEEP');
      }
      let result: TransitionResult;
      try {
        result = await transitionIssue(key, status, { version: options.version, recover: Boolean(options.proof) });
      } catch (e) {
        if (!(e instanceof TransitionNotFound)) throw e;
        console.error(`Transition "${e.status}" not found. Available:`);
        for (const name of e.available) console.error(`- ${name}`);
        process.exit(1);
      }
      console.log(`${key} → ${result.name}`);
      if (options.proof) {
        let settled: Awaited<ReturnType<typeof proof>>;
        try {
          settled = await proof('--settle', result.unstamped, checkedHash);
        } catch (e) {
          // The move already happened and nothing moves back: say where the ticket stands, why the validation did not settle, and the command that finishes it.
          const why = String((e as { stderr?: unknown }).stderr || (e as Error).message).trim();
          const quote = (arg: string) => (/^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, `'\\''`)}'`);
          const again = ['node', process.argv[1] ?? 'jira', 'transition', key, status, ...(options.version ? [] : ['--no-version']),
            '--proof', options.proof!, '--proof-bucket', options.proofBucket!, '--proof-decision', options.proofDecision!].map(quote).join(' ');
          console.error(`FAIL ${key} is now ${result.name} in Jira but validation ${options.proof} is NOT settled: ${why}\nNothing was moved back. Run it again: ${again}\nIf a tool with its own time limit runs it, give it 300000 ms or more: a slow read can take its whole budget in the check and again in the settle.`);
          process.exitCode = 1;
          return;
        }
        if (settled.reconciliation !== undefined) {
          console.error(settled.remainder
            ? `FAIL ${key} is Done but ${settled.remainder.join('; ')} still blocks the CLOSE; validation ${options.proof} stays pending and remainder reconciliation ${settled.reconciliation} is the chief's owned next action: clear it, close that step, then record the decision again`
            : `FAIL ${key} is Done but its DoD/Proof changed after the evidence was bound; validation ${options.proof} stays pending and requirements-reconciliation ${settled.reconciliation} is the chief's owned next action`);
          process.exitCode = 3;
        }
      }
      const browse = browseLine(key);
      if (browse) console.log(browse);
      if (result.unstamped) {
        console.error(`FAIL ${key} closed with no fixVersion: ${result.unstamped}; place it with version-defer --to or edit --fix-version`);
        process.exitCode = 3;
      }
    });
}
