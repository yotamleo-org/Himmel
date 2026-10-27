// Coverage for scripts/lib/kill-tree.mjs: the shared process-TREE stop
// for the JS/TS side.
//
// THE POINT OF THIS SUITE: the defect it pins shipped because the only test
// that existed asserted the DIRECT child died. It did, on every platform --
// while its descendants kept running and holding the output pipes. So the
// cases below spawn a real grandchild that outlives its parent and assert the
// GRANDCHILD is gone.
//
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { killTree, SPAWN_OWN_GROUP } from "../../lib/kill-tree.mjs";

// alive(pid) -- signal 0 probes existence without delivering anything. A
// not-yet-reaped zombie would answer 0 here, which is why the fixtures below
// let the grandchild be reparented to init (its parent shell is gone, so
// nothing of ours holds a zombie entry for it).
function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e?.code === "EPERM"; }
}

// spawnFixture -- a child shell that prints the pid of a background grandchild.
// The grandchild outlives its parent, which is the shape every caller of this
// helper is trying to clean up: a worker that spawned something of its own
// before it overran its deadline. `parentTail` decides whether the parent
// shell then hangs around (the timeout case) or exits immediately (the
// already-exited case).
//
// A fixture that fails AFTER spawning must not leak what it spawned: the
// caller's cleanup only ever sees a fixture that was
// returned, so the throw path cleans up here before it rethrows.
async function spawnFixture({ ownGroup = true, parentTail = "sleep 300" } = {}) {
  const child = spawn("sh", ["-c", `sleep 300 & echo $!; ${parentTail}`], {
    ...(ownGroup ? SPAWN_OWN_GROUP : {}),
    stdio: ["ignore", "pipe", "ignore"],
  });
  try {
    const grandchild = await new Promise((resolve, reject) => {
      let buf = "";
      const t = setTimeout(() => reject(new Error("fixture never printed its grandchild pid")), 10_000);
      child.stdout.on("data", (d) => {
        buf += String(d);
        const m = buf.match(/(\d+)/);
        if (m) { clearTimeout(t); resolve(Number(m[1])); }
      });
      child.on("error", (e) => { clearTimeout(t); reject(e); });
    });
    return { child, grandchild };
  } catch (e) {
    hardCleanup({ child });
    throw e;
  }
}

// Nothing may leak out of this suite even when an assertion fails -- or when
// the fixture itself does, before it ever learned the grandchild's pid.
function hardCleanup({ child, grandchild }) {
  for (const pid of [grandchild, child?.pid]) {
    if (!pid) continue;
    try { process.kill(pid, "SIGKILL"); } catch { /* gone */ }
  }
  // Covers the grandchild even when its pid was never captured.
  if (child?.pid) { try { process.kill(-child.pid, "SIGKILL"); } catch { /* no group */ } }
}

test("POSIX: the whole group dies, grandchild included (the defect this ticket exists for)", async () => {
  const fx = await spawnFixture();
  try {
    assert.equal(alive(fx.grandchild), true, "fixture grandchild should be alive before the stop");
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s));
    assert.equal(r.ok, true, `expected a clean stop, got ${r.detail}`);
    await sleep(1500);
    assert.equal(alive(fx.grandchild), false, "the GRANDCHILD survived -- signalling the direct pid only is the bug");
    assert.equal(alive(fx.child.pid), false, "the direct child survived");
  } finally {
    hardCleanup(fx);
  }
});

test("POSIX: a child spawned WITHOUT its own group still gets the direct signal (legacy callers keep working)", async () => {
  const fx = await spawnFixture({ ownGroup: false });
  try {
    // No group to signal -> the kernel answers ESRCH, which the helper treats
    // as "nothing to do" rather than an error. The direct child must still die
    // (this is the pre-1956 behaviour, deliberately preserved).
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s));
    assert.equal(r.ok, true, `ESRCH on a groupless child must not be reported as a failure: ${r.detail}`);
    await sleep(1000);
    assert.equal(alive(fx.child.pid), false, "the direct child must die even with no group");
  } finally {
    hardCleanup(fx);
  }
});

test("POSIX: descendants are reaped even after the direct child has already exited (HIMMEL-1835 hole 2)", async () => {
  // The child exits immediately; its background grandchild does not. The old
  // shape returned early on `exitCode !== null` and cleaned up nothing --
  // exactly the case where the MCP fleet is left running. A pgid stays
  // reserved while the group has members, so the group signal is still
  // precisely aimed here, never at a recycled pid.
  const fx = await spawnFixture({ parentTail: "exit 0" });
  try {
    await new Promise((r) => fx.child.on("exit", r));
    assert.notEqual(fx.child.exitCode, null, "fixture child should have exited on its own");
    assert.equal(alive(fx.grandchild), true, "the grandchild should outlive its parent shell");
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s), { exited: true });
    assert.equal(r.ok, true, `expected a clean stop, got ${r.detail}`);
    await sleep(1500);
    assert.equal(alive(fx.grandchild), false, "an already-exited child must not skip reaping its descendants");
  } finally {
    hardCleanup(fx);
  }
});

test("a pid that does not exist is a no-op, not a thrown error", () => {
  // 2^31-ish: never a live pid. The group branch answers ESRCH, which is
  // accepted; it may neither throw nor report failure.
  const r = killTree(2147483646, () => { throw new Error("no such handle"); });
  assert.equal(r.ok, true, `a missing target must not be reported as a failure: ${r.detail}`);
});

test("SPAWN_OWN_GROUP asks for a dedicated process group", () => {
  // The two halves of the fix live on opposite sides of the spawn, so the
  // spawn-side half is worth pinning: an empty object here would make every
  // group signal above a silent ESRCH no-op.
  assert.deepEqual(SPAWN_OWN_GROUP, { detached: true });
});
