import { execFileSync } from 'node:child_process';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ctxFor, refuseRequest } from '../commands/release.js';
import { intakeRelease } from '../commands/create.js';
import { request as releaseRequest } from './engine.js';

export type MergedPr = { number: number; url: string };

export function mergedPrOf(key: string): MergedPr | undefined {
  try {
    const out = execFileSync('gh', ['pr', 'list', '--state', 'merged', '--search', `${key} in:title`, '--json', 'number,url,title', '--limit', '5'], {
      cwd: dirname(fileURLToPath(import.meta.url)), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000,
    });
    // GitHub search matches the key's words, not the key: keep only a title that names it whole.
    const named = new RegExp(`(^|[^A-Za-z0-9-])${key}(?![A-Za-z0-9-])`, 'i');
    const pr = (JSON.parse(out) as Array<MergedPr & { title?: unknown }>).find((p) => typeof p.title === 'string' && named.test(p.title));
    return pr && Number.isInteger(pr.number) && typeof pr.url === 'string' ? { number: pr.number, url: pr.url } : undefined;
  } catch {
    // gh missing, offline or unauthenticated reads as no merged PR: the close then writes no version.
    return undefined;
  }
}

const whyOf = (key: string, version: string, pr?: MergedPr): string =>
  pr ? `closed with merged PR #${pr.number}; ${key} asks into frozen ${version}` : `closed into frozen ${version} with no version of its own`;

export function requestLine(key: string, version: string): string {
  let release = '<release>';
  try {
    release = intakeRelease();
  } catch {
    // no single declared release: the placeholder stays
  }
  return `jira release request ${release} --verb INTAKE --key ${key} --to ${version} --why "${whyOf(key, version)}"`;
}

export function fileCloseIntake(key: string, version: string, pr: MergedPr): string {
  const release = intakeRelease();
  const ctx = ctxFor(release);
  const why = whyOf(key, version, pr);
  refuseRequest(ctx, { verb: 'INTAKE', key, from_v: null, why, evidence: { pr: pr.number } });
  const r = releaseRequest(ctx, {
    verb: 'INTAKE', key, from_v: null, to_v: version, why, evidence: { merged_pr: pr.url, pr_number: pr.number, closed_by: 'transition' }, from: 'console',
  });
  console.error(`jira: INTAKE queued for ${key} as REQ ${r.req} (release ${release}): a close into frozen ${version}, merged PR #${pr.number}`);
  return r.req;
}
