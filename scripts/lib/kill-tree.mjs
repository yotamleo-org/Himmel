// scripts/lib/kill-tree.mjs -- the ONE process-tree kill for the JS/TS side of
// the harness.
//
// WHY THIS FILE EXISTS: two copies of a killTree lived here (telegram/run.ts
// for the worker timeout paths, lanes/codex-usage-probe.ts for the codex
// app-server), and both carried the same defect -- the name promises a TREE
// kill but on POSIX they signalled the direct child only, so anything the
// child spawned survived. Every caller is a TIMEOUT path, so a survivor keeps
// spending a provider bank unsupervised and can hold the output pipes open,
// which means the parent's stream consumers never see EOF.
//
// THE PRIMITIVE, MEASURED not assumed (bun 1.4.0, Linux 6.18 WSL2, 2026-08-20):
//
//   spawn         kill                                   grandchild
//   bare          child.kill(SIGKILL)                    SURVIVED  (pgid = the parent's)
//   detached      child.kill(SIGKILL)                    SURVIVED  (leader dies alone)
//   detached      process.kill(-pid, SIGKILL)            reaped
//   bare          process.kill(-pid, SIGKILL)            ESRCH, nothing signalled
//
// Both halves are required, and they live on opposite sides of the spawn: the
// GROUP has to exist before it can be signalled. Hence SPAWN_OWN_GROUP below,
// which every spawn site whose child may be killTree'd must spread into its
// options. This mirrors scripts/lib/proc-tree.sh, the shell-side equivalent,
// whose callers spawn under `set -m` for exactly the same reason.
//
// The bare+group row is why the group signal is safe to attempt unconditionally:
// a pgid always equals the pid of its leader, so if this pid never led a group
// there is no group to hit and the kernel answers ESRCH. It cannot land on a
// bystander.

// Spread into spawn options so the child leads its own process group:
//   spawn(cmd, { ...SPAWN_OWN_GROUP, stdout: "pipe", ... })
//
// THE TRADEOFF, stated rather than discovered later: a child in its own group
// no longer receives the SIGINT a terminal delivers to the parent's foreground
// group, so on POSIX an operator Ctrl-C'ing a spawner leaves the worker running
// where it previously died along with the shell. That is the same property
// that makes the deadline kill work at all -- the group is ours to signal, so
// the stop must be explicit. Every caller here already stops explicitly on its
// deadline, and codex-bank-probe additionally reaps on SIGINT/SIGTERM/exit.
export const SPAWN_OWN_GROUP = { detached: true };

// killTree(pid, kill, opts) -- kill the process and everything under it.
//   pid   the direct child's pid
//   kill  signal the direct child (e.g. (s) => child.kill(s)); injected so the
//         caller's own process handle is used, which no-ops safely once the
//         child has been reaped instead of signalling a recycled pid
//   opts.exited  accepted from callers, no longer read: the group signal is
//                aimed the same whether or not the direct child has exited
//
// Returns { ok, detail } rather than swallowing everything: a tree kill that
// silently failed is indistinguishable from one that worked, which is the
// third hole this helper closes. Callers that verify the outcome another way
// (awaiting p.exited) may ignore it; callers that cannot should log detail
// when ok is false.
export function killTree(pid, kill, opts = {}) {
  const problems = [];
  // Signal the GROUP. This stays correct after the direct child has exited,
  // which is what closes the second hole -- a child that died on
  // its own while its descendants are still up is exactly when reaping
  // matters. The kernel keeps a pgid reserved while the group still has
  // members, so as long as there is anything here to reap, this pid still
  // names OUR group and nothing else.
  //
  // The boundary (panel codex-1), stated precisely rather than glossed: once
  // the group is EMPTY the pid is released, and a pid that is later recycled
  // BY A NEW GROUP LEADER would receive this signal. That requires the pid
  // space to wrap between the child's exit and this call, so the invariant
  // callers owe is simply not to sit on a stale pid: signal within your own
  // teardown (codex-bank-probe reaps in its finally / signal / exit
  // handlers), and cancel a deadline timer the moment the child is reaped
  // (runSession's clearTimeout-in-finally, whose comment already names this
  // recycled-pid hazard for the direct signal below -- the group signal
  // widens that same blast radius, it does not introduce it).
  try {
    process.kill(-pid, "SIGKILL");
  } catch (e) {
    if (e?.code !== "ESRCH") problems.push(`group kill failed: ${e?.code ?? String(e)}`);
  }
  // The direct child last, and through the caller's own handle: it covers a
  // child spawned without SPAWN_OWN_GROUP (no group to signal) and is a no-op
  // once that handle has been reaped.
  try { kill("SIGKILL"); } catch { /* already gone */ }
  if (problems.length) return { ok: false, detail: problems.join("; ") };
  return { ok: true };
}
