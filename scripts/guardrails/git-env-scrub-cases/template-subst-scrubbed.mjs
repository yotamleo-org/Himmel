// GREEN control for template-subst-unscrubbed.mjs: same template shape, the
// spawn goes through the shared gitClean() helper.
import { gitClean } from '../../lanes/git-clean.mjs';

export function describe(repoRoot) {
  return `head is ${gitClean(['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' })}`;
}
