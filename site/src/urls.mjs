// The one place the docs site host and the repo URL are derived: GITHUB_REPOSITORY
// (set on every Actions run), else the checkout's git origin. No source, no site.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const NWO = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/;
const ORIGIN = /github\.com[:/]([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\/?$/;

function repoNwo() {
  const fromEnv = process.env.GITHUB_REPOSITORY;
  if (fromEnv && NWO.test(fromEnv)) return fromEnv;
  let origin = '';
  try {
    origin = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd: path.dirname(fileURLToPath(import.meta.url)),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    // no origin: fall through to the error below
  }
  const m = ORIGIN.exec(origin);
  if (m && NWO.test(m[1])) return m[1];
  throw new Error('site/src/urls.mjs: no GITHUB_REPOSITORY and no github.com git origin to derive the site URL from');
}

const nwo = repoNwo();
export const SITE_ORIGIN = `https://${nwo.split('/')[0].toLowerCase()}.github.io`;
export const REPO_URL = `https://github.com/${nwo}`;
