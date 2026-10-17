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

test('a caller stdio cannot silence the stdout capture', () => {
  const r = run("process.stdout.write('hi\\n')", { stdio: 'inherit' });
  assert.equal(r.out, 'hi');
});

test('true/false map to ok/fail', () => {
  assert.equal(runOrUnknown('true', []).state, 'ok');
  assert.equal(runOrUnknown('false', []).state, 'fail');
});

test('requireOk writes the label line to stderr only when not ok', () => {
  const lines = [];
  const sink = (s) => lines.push(s);
  assert.equal(requireOk('good', ...node('process.exit(0)'), { stderr: sink }), true);
  assert.deepEqual(lines, []);
  assert.equal(requireOk('bad', ...node('process.exit(1)'), { stderr: sink }), false);
  assert.equal(requireOk('odd', ...node('process.exit(3)'), { stderr: sink }), false);
  assert.deepEqual(lines, ['bad: FAIL (rc=1)\n', 'odd: UNKNOWN (rc=3)\n']);
});

test('requireOk is true only for a definite ok, like require_ok in result.sh', () => {
  const sink = () => {};
  for (const [code, want] of [[0, true], [1, false], [2, false], [127, false]]) {
    assert.strictEqual(requireOk('x', ...node(`process.exit(${code})`), { stderr: sink }), want);
  }
  assert.strictEqual(requireOk('x', '/nonexistent/himmel-result-cmd', [], { stderr: sink }), false);
});

test('a child that traps SIGTERM and exits 0 under a timeout -> unknown', () => {
  // 2 s leaves the child time to install its handler before the kill arrives.
  const r = run("process.on('SIGTERM', () => process.exit(0)); setTimeout(() => {}, 30000)", { timeout: 2000 });
  assert.equal(r.state, 'unknown');
  assert.equal(resultRender(r), 'UNKNOWN');
});

test('output past the default 1 MiB maxBuffer, exit 0 -> unknown', () => {
  // The child traps the maxBuffer SIGTERM and exits 0, so only p.error says unknown.
  const r = run("process.on('SIGTERM', () => process.exit(0)); process.stdout.on('error', () => {}); process.stdout.write('x'.repeat(2 * 1024 * 1024))");
  assert.equal(r.state, 'unknown');
  assert.equal(r.rc, 0);
  assert.equal(resultRender(r), 'UNKNOWN');
});

test('resultRender: unknown or missing state is never OK', () => {
  assert.equal(resultRender({ state: 'unknown' }), 'UNKNOWN');
  assert.equal(resultRender({}), 'UNKNOWN');
  assert.equal(resultRender(undefined), 'UNKNOWN');
});
