// stopChild() must not remove the temp dir while the server, or a process it started, can still write into it.
// A write landing during the rmSync fails the teardown with `ENOTEMPTY, Directory not empty: /tmp/cfgui-e2e-...`.
// Stub children stand in for the server: they print "ready" once their SIGTERM handling is in place, then write into the dir.
// The last test boots the real AG-UI server through bootAgui, whose stop() shares stopChild.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ChildProcess } from "node:child_process";
import { spawnServer, stopChild } from "./fixtures";
import { aguiBuilt, bootAgui } from "./agui-fixtures";

const GRACE_MS = 300;
// ignore SIGTERM, then create new files in the dir without pause (what a server's late log or state write does)
const WRITER = `const fs = require("fs"); let i = 0; process.on("SIGTERM", () => {}); setImmediate(() => {
  for (;;) try { fs.writeFileSync(process.argv[1] + "/late-" + i++, "x"); } catch {} });`;
const STUBS: Record<string, string> = {
  // (a) never honours SIGTERM, so stopChild has to escalate to SIGKILL
  stubborn: `${WRITER} console.log("ready");`,
  // (b) exits on SIGTERM at once but leaves a grandchild that also ignores SIGTERM and keeps writing
  "grandchild": `const { spawn } = require("child_process");
    const g = spawn("node", ["-e", ${JSON.stringify(WRITER + ' console.log("ready");')}, process.argv[1]], { stdio: ["ignore", "pipe", "ignore"] });
    g.stdout.once("data", () => console.log("ready " + g.pid)); setInterval(() => {}, 1000);`,
  // (c) control: exits promptly on SIGTERM
  prompt: `process.on("SIGTERM", () => process.exit(0)); console.log("ready"); setInterval(() => {}, 1000);`,
};

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const exited = (c: ChildProcess) => c.exitCode !== null || c.signalCode !== null;

async function run(kind: string) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-e2e-teardown-"));
  mkdirSync(join(dir, "home"));
  writeFileSync(join(dir, "home", "seed"), "x");
  const child = spawnServer(["-e", STUBS[kind], join(dir, "home")], process.env);
  try {
    const grandchild = await new Promise<number | undefined>((ok, fail) => {
      child.stdout!.on("data", (d) => { const m = /ready(?: (\d+))?/.exec(String(d)); if (m) ok(m[1] ? Number(m[1]) : undefined); });
      child.once("exit", () => fail(new Error("stub exited before ready")));
      setTimeout(() => fail(new Error("stub not ready in 10 s")), 10_000).unref();
    });
    const t0 = Date.now();
    await stopChild(child, dir, GRACE_MS);
    return { gone: !existsSync(dir), exited: exited(child), grandchildAlive: grandchild !== undefined && alive(grandchild), ms: Date.now() - t0 };
  } finally {
    // never leak a stub past a failing run: the whole group, grandchild included
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* the group is already gone */ }
  }
}

test("a child that ignores SIGTERM is gone, and the dir with it, when stop resolves", async () => {
  const r = await run("stubborn");
  expect(r).toMatchObject({ gone: true, exited: true });
  expect(r.ms).toBeGreaterThanOrEqual(GRACE_MS);
});

test("a grandchild that keeps writing after the parent exits does not survive stop", async () => {
  const r = await run("grandchild");
  expect(r).toMatchObject({ gone: true, exited: true, grandchildAlive: false });
});

test("control: a child that exits promptly on SIGTERM leaves the dir gone without waiting for the grace", async () => {
  const r = await run("prompt");
  expect(r).toMatchObject({ gone: true, exited: true });
  expect(r.ms).toBeLessThan(GRACE_MS);
});

test("the AG-UI harness stop() leaves no temp dir behind", async () => {
  test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
  const agui = () => new Set(readdirSync(tmpdir()).filter((n) => n.startsWith("agui-e2e-")));
  const before = agui();
  const h = await bootAgui();
  expect([...agui()].filter((n) => !before.has(n))).toHaveLength(1);
  await h.stop();
  expect([...agui()].filter((n) => !before.has(n))).toEqual([]);
});
