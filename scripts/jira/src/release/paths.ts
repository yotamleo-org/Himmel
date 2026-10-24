import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { behaviourKey, handoverRoot } from '../handover-root.js';

// <handover root>/<user>/<repo>/release/<R>/ (design §5.1). The launcher
// exports HANDOVER_DIR and USER_SLUG; HIMMEL_RELEASE_STATE_DIR replaces the
// whole root for tests and for a session outside a launcher.

function primaryRepoName(): string {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  return basename(dirname(common));
}

export function releaseRoot(env: Record<string, string | undefined> = process.env): string {
  if (env.HIMMEL_RELEASE_STATE_DIR) return env.HIMMEL_RELEASE_STATE_DIR;
  const userSlug = behaviourKey('USER_SLUG', env);
  if (!userSlug) {
    throw new Error('release: set USER_SLUG (as the launcher does) or HIMMEL_RELEASE_STATE_DIR');
  }
  return join(handoverRoot(env), userSlug, primaryRepoName(), 'release');
}

export const releaseDir = (release: string, env: Record<string, string | undefined> = process.env): string =>
  join(releaseRoot(env), release);

export const releaseKeyPath = (release: string, env: Record<string, string | undefined> = process.env): string =>
  join(env.HIMMEL_RELEASE_KEY_DIR ?? join(homedir(), '.config', 'himmel', 'release'), `${release}.key`);
