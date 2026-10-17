// scripts/lib/result.mjs. Node twin of result.sh: fail-closed tri-state results
// for gate and hook scripts. A read that cannot answer must not look like an
// answer.
//
// Exit-code contract of the command run (the grep/test convention):
//   0 -> ok        a definite yes
//   1 -> fail      a definite no
//   anything else (usage error, 124, 126/127, signal, spawn error, timeout)
//      -> unknown  the question was never answered
//
//   runOrUnknown(cmd, args, opts) -> { state, rc, out }
//       spawnSync, stdout captured with trailing newlines stripped, stderr left
//       on the terminal. rc is the real exit code, or null when the child never
//       exited normally (killed by a signal, timed out, could not spawn).
//   requireOk(label, cmd, args, opts) -> { state, rc, out }
//       runOrUnknown, then writes "<label>: FAIL|UNKNOWN (rc=N)" to stderr
//       unless ok. opts.stderr replaces the sink (a function taking a string).
//   resultRender(r) -> 'OK' | 'FAIL' | 'UNKNOWN'; unknown is never OK.
import { spawnSync } from 'node:child_process';

export function runOrUnknown(cmd, args = [], opts = {}) {
  const { stderr: _sink, ...spawnOpts } = opts;
  const p = spawnSync(cmd, args, {
    stdio: ['ignore', 'pipe', 'inherit'],
    ...spawnOpts,
    encoding: 'utf8', // after the spread: a caller encoding must not turn out into a Buffer
  });
  const out = (p.stdout ?? '').replace(/\n+$/, '');
  // p.error is set for ENOENT and for a timeout; p.status is null for a signal.
  if (p.error || p.status === null) return { state: 'unknown', rc: p.status, out };
  if (p.status === 0) return { state: 'ok', rc: 0, out };
  if (p.status === 1) return { state: 'fail', rc: 1, out };
  return { state: 'unknown', rc: p.status, out };
}

export function requireOk(label, cmd, args = [], opts = {}) {
  const r = runOrUnknown(cmd, args, opts);
  if (r.state !== 'ok') {
    const write = opts.stderr ?? ((s) => process.stderr.write(s));
    write(`${label}: ${resultRender(r)} (rc=${r.rc ?? ''})\n`);
  }
  return r;
}

export function resultRender(r) {
  switch (r?.state) {
    case 'ok': return 'OK';
    case 'fail': return 'FAIL';
    default: return 'UNKNOWN';
  }
}
