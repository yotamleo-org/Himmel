// GREEN: an error message that merely starts with the word git is not a spawn.
export function fail() {
  throw new Error('git ls-tree failed at origin/main and HEAD');
}
