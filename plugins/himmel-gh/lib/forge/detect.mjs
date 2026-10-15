// forge/detect.mjs — the plugin's forge answer, delegated to
// scripts/lib/project-mode.mjs (one owner decides the forge; this file does
// not read the origin host itself).
//
// Precedence is project-mode's: env.FORGE > git config himmel.forge > the
// origin HOST (github.com / bitbucket.org or a subdomain). The plugin drives
// only the github and bitbucket backends, so:
//   - bitbucket → 'bitbucket'
//   - github, local-git, none → 'github'
//   - an invalid or refused setting (FORGE=gitlab, local-git on a hosted
//     origin) is ignored, as an invalid FORGE always was here: the answer falls
//     back to the origin host alone (project-mode's --for-guard read).
//
// The ONE deliberate divergence from the shell seam stays: forge.sh returns
// non-zero on an undetermined forge, but the plugin DEFAULTS TO github. The
// existing github tests run in the himmel repo (github origin) and inject
// execGh; github must stay the safe fallback so they pass unchanged and so a
// detached/origin-less checkout keeps the legacy gh path.

import { projectModeForge } from '../../../../scripts/lib/project-mode.mjs';

export function detectForge(cwd = process.cwd(), env = process.env) {
  // FORGE comes from the caller's env (the test seam); git runs with the
  // process env, as the origin read always did.
  const o = { cwd, env: { ...process.env, FORGE: env.FORGE || '' } };
  let f;
  try {
    f = projectModeForge({ ...o, quiet: true });
  } catch {
    f = projectModeForge({ ...o, forGuard: true });
  }
  return f === 'bitbucket' ? 'bitbucket' : 'github';
}
