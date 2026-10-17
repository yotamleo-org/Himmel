// Tests for scripts/lib/result.mjs, the node twin of result.sh. Mirrors the
// case list of test-result.sh: 0 ok, 1 fail, anything else unknown.
// Run: node --test scripts/lib/result.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runOrUnknown, requireOk, resultRender } from './result.mjs';

const node = (code) => [process.execPath, ['-e', code]];
const run = (code, opts) => runOrUnknown(...node(code), opts);

test('exit 0 -> ok', () => {
  const r = run('process.exit(0)');
  assert.equal(r.state, 'ok');
  assert.equal(r.rc, 0);
  assert.equal(resultRender(r), 'OK');
});

test('exit 1 -> fail', () => {
  const r = run('process.exit(1)');
  assert.equal(r.state, 'fail');
  assert.equal(r.rc, 1);
  assert.equal(resultRender(r), 'FAIL');
});

for (const code of [2, 3, 124, 126, 127]) {
  test(`exit ${code} -> unknown, never OK or FAIL`, () => {
    const r = run(`process.exit(${code})`);
    assert.equal(r.state, 'unknown');
    assert.equal(r.rc, code);
    assert.equal(resultRender(r), 'UNKNOWN');
  });
}

test('ENOENT command -> unknown', () => {
  const r = runOrUnknown('/nonexistent/himmel-result-cmd', []);
  assert.equal(r.state, 'unknown');
  assert.equal(resultRender(r), 'UNKNOWN');
});

test('SIGKILLed child -> unknown', () => {
  const r = run("process.kill(process.pid, 'SIGKILL')");
  assert.equal(r.state, 'unknown');
  assert.equal(resultRender(r), 'UNKNOWN');
});

test('timeout -> unknown', () => {
  const r = run('setTimeout(() => {}, 30000)', { timeout: 200 });
  assert.equal(r.state, 'unknown');
  assert.equal(resultRender(r), 'UNKNOWN');
});

test('stdout captured, trailing newlines stripped', () => {
  const r = run("process.stdout.write('hello\\n\\n')");
  assert.equal(r.out, 'hello');
});

test('a caller encoding of null cannot turn stdout into a Buffer', () => {
  const r = run("process.stdout.write('hi\\n')", { encoding: null });
  assert.equal(r.state, 'ok');
  assert.equal(r.out, 'hi');
});

test('true/false map to ok/fail', () => {
  assert.equal(runOrUnknown('true', []).state, 'ok');
  assert.equal(runOrUnknown('false', []).state, 'fail');
});

test('requireOk writes the label line to stderr only when not ok', () => {
  const lines = [];
  const sink = (s) => lines.push(s);
  assert.equal(requireOk('good', ...node('process.exit(0)'), { stderr: sink }).state, 'ok');
  assert.deepEqual(lines, []);
  assert.equal(requireOk('bad', ...node('process.exit(1)'), { stderr: sink }).state, 'fail');
  assert.equal(requireOk('odd', ...node('process.exit(3)'), { stderr: sink }).state, 'unknown');
  assert.deepEqual(lines, ['bad: FAIL (rc=1)\n', 'odd: UNKNOWN (rc=3)\n']);
});

test('resultRender: unknown or missing state is never OK', () => {
  assert.equal(resultRender({ state: 'unknown' }), 'UNKNOWN');
  assert.equal(resultRender({}), 'UNKNOWN');
  assert.equal(resultRender(undefined), 'UNKNOWN');
});
