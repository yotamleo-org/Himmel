// GREEN control: 'git' as a first argument is not a spawn when the callee is
// not one.
import assert from 'node:assert';

export function check(tools, name) {
  assert.strictEqual(name, 'git');
  console.log('git');
  return tools.includes('git') || tools.has('git');
}
