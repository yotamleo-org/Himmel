// A versionless Done close whose stamp target is a frozen release is a placement
// the release manager rules on, never a silent write. With a merged PR the close
// files the INTAKE itself, the PR as its evidence, and then stamps; with none it
// writes no version and prints the exact request to file.
import { execFileSync } from 'node:child_process';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ctxFor, refuseRequest } from '../commands/release.js';
import { intakeRelease } from '../commands/create.js';
import { request as releaseRequest } from './engine.js';

export type MergedPr = { number: number; url: string };

/** The newest merged PR whose title names the key, asked of gh in this checkout; none when gh cannot answer. */
export function mergedPrOf(key: string): MergedPr | undefined {
  try {
    const out = execFileSync('gh', ['pr', 'list', '--state', 'merged', '--search', `${key} in:title`, '--json', 'number,url', '--limit', '1'], {
      cwd: dirname(fileURLToPath(import.meta.url)), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000,
    });
    const [pr] = JSON.parse(out) as MergedPr[];
    return pr && Number.isInteger(pr.number) && typeof pr.url === 'string' ? pr : undefined;
  } catch {
    // gh missing, offline or unauthenticated reads as no merged PR: the close then writes no version.
    return undefined;
  }
}

const whyOf = (key: string, version: string, pr?: MergedPr): string =>
  pr ? `closed with merged PR #${pr.number}; ${key} asks into frozen ${version}` : `closed into frozen ${version} with no version of its own`;

/** The release request a close with no merged PR leaves to its caller, as one line to run. */
export function requestLine(key: string, version: string): string {
  let release = '<release>';
  try {
    release = intakeRelease();
  } catch {
    // No single declared release: the line keeps the placeholder for the caller to fill.
  }
  return `jira release request ${release} --verb INTAKE --key ${key} --to ${version} --why "${whyOf(key, version)}"`;
}

/** Files the INTAKE for a close into frozen `version`, the merged PR as evidence; returns the request id. Throws when it cannot be queued. */
export function fileCloseIntake(key: string, version: string, pr: MergedPr): string {
  const release = intakeRelease();
  const ctx = ctxFor(release);
  const why = whyOf(key, version, pr);
  refuseRequest(ctx, { verb: 'INTAKE', key, from_v: null, why });
  const r = releaseRequest(ctx, {
    verb: 'INTAKE', key, from_v: null, to_v: version, why, evidence: { merged_pr: pr.url, pr_number: pr.number, closed_by: 'transition' }, from: 'console',
  });
  console.error(`jira: INTAKE queued for ${key} as REQ ${r.req} (release ${release}): a close into frozen ${version}, merged PR #${pr.number}`);
  return r.req;
}
