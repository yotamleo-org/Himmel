// GET /api/agui/fleet load: the archived chief docs are lock-checked in a bounded pool (a queue-lock.sh process
// each; about 600 docs on the station), and concurrent polls share one run.
// The fake tree here is a stub census plus a slow queue-lock.sh that logs when each call starts and ends.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFleet } from "../agui/fleet.ts";
import { startServer } from "../server";
import { busRoot, append } from "../../../marketplace/plugins/himmel-bus/lib/store.mjs";

const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function tree(docs: number, censusSleep = "0.3") {
  const dir = mkdtempSync(join(tmpdir(), "agui-fleet-load-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const ui = join(dir, "ui"), handover = join(dir, "handover"), bucket = join(dir, "bucket");
  for (const d of [ui, handover, bucket]) mkdirSync(d, { recursive: true });
  const files = Array.from({ length: docs }, (_, i) => join(bucket, `LOAD${i}-console.md`));
  files.forEach((f, i) => writeFileSync(f, `# LOAD${i} console\n\n## Results\n\n- 09:00 LIVE — lock \`tok${i}\`\n`));
  const lockLog = join(dir, "lock.log"), censusLog = join(dir, "census.log");
  writeFileSync(join(ui, "fleet.sh"), `#!/bin/sh\necho run >> "${censusLog}"\nsleep ${censusSleep}\ncat <<'EOF'\n${JSON.stringify({ census: "ok", sessions: [], consoleDocs: files })}\nEOF\n`);
  writeFileSync(join(handover, "queue-lock.sh"), `#!/bin/sh\necho S >> "${lockLog}"\nsleep 0.2\necho E >> "${lockLog}"\necho free\n`);
  for (const f of [join(ui, "fleet.sh"), join(handover, "queue-lock.sh")]) chmodSync(f, 0o755);
  const calls = () => { try { return readFileSync(lockLog, "utf8").split("\n").filter(Boolean); } catch { return []; } };
  const runs = () => { try { return readFileSync(censusLog, "utf8").split("\n").filter(Boolean).length; } catch { return 0; } };
  const peak = () => { let n = 0, max = 0; for (const c of calls()) { n += c === "S" ? 1 : -1; max = Math.max(max, n); } return max; };
  return { dir, script: join(ui, "fleet.sh"), calls, runs, peak };
}

test("archived chief docs get their lock read in parallel, bounded, and none is dropped", async () => {
  const t = tree(24);
  const f = await readFleet({ script: t.script, env: { PATH: process.env.PATH }, home: t.dir, now: Date.now(), redact: (s) => s });
  expect(f.sessions.filter((r) => r.role === "console").length).toBe(24);
  expect(t.calls().filter((c) => c === "S").length).toBe(24);
  expect(t.peak()).toBeGreaterThan(1); // sequential = 1
  expect(t.peak()).toBeLessThanOrEqual(16); // never 600 bash processes at once
}, 30_000);

const BUS_LOGS = 1000;
async function busTree() {
  const t = tree(0, "0");
  const state = join(t.dir, "state");
  const root = await busRoot({ stateHome: state });
  const now = Date.now();
  const send = (k: number, i: string) => append(root, `S${k}`, { t: now, b: "x", c: 0, i, f: "S0", r: `S${k}` });
  await Promise.all(Array.from({ length: BUS_LOGS }, (_, k) => send(k, `M${k}`)));
  const read = (wait: string) => {
    const t0 = performance.now();
    return readFleet({ script: t.script, env: { PATH: process.env.PATH, XDG_STATE_HOME: state, HIMMEL_FLEET_BUS_WAIT_MS: wait }, home: t.dir, now: Date.now(), redact: (s) => s })
      .then((f) => ({ f, ms: performance.now() - t0 }));
  };
  const edgeN = (f: { edges: { from: string; to: string; n: number }[] }) => f.edges.reduce((n, e) => n + e.n, 0);
  return { send, read, edgeN };
}

test("a poll of an unchanged bus store does not replay it", async () => {
  const b = await busTree();
  const cold = await b.read("60000");
  expect(b.edgeN(cold.f)).toBe(BUS_LOGS);
  const warm = await b.read("60000");
  expect(b.edgeN(warm.f)).toBe(BUS_LOGS);
  expect(warm.ms).toBeLessThan(400);
}, 60_000);

test("a poll answers within the bus wait and the replay finishes in the background", async () => {
  const b = await busTree();
  const first = await b.read("100");
  expect(first.ms).toBeLessThan(600);
  let seen = b.edgeN(first.f);
  for (let i = 0; i < 100 && seen < BUS_LOGS; i++) { await new Promise((ok) => setTimeout(ok, 100)); seen = b.edgeN((await b.read("100")).f); }
  expect(seen).toBe(BUS_LOGS);
}, 60_000);

test("a message sent after the cached read shows on a later poll", async () => {
  const b = await busTree();
  await b.read("60000");
  await b.send(0, "LATE");
  let seen = 0;
  for (let i = 0; i < 100 && seen <= BUS_LOGS; i++) { seen = b.edgeN((await b.read("100")).f); if (seen <= BUS_LOGS) await new Promise((ok) => setTimeout(ok, 100)); }
  expect(seen).toBe(BUS_LOGS + 1);
}, 60_000);

test("requests that arrive while a fleet read is running share it: one census run", async () => {
  const t = tree(2);
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, fleetScript: t.script, env: { PATH: process.env.PATH, HOME: t.dir, CONFIG_UI_IDLE_MS: "60000" } });
  cleanups.push(() => s.stop());
  const get = () => fetch(`http://127.0.0.1:${s.port}/api/agui/fleet`, { headers: { "X-Himmel-Token": TOKEN } });
  const [a, b, c] = await Promise.all([get(), get(), get()]);
  expect([a.status, b.status, c.status]).toEqual([200, 200, 200]);
  expect(t.runs()).toBe(1);
  expect((await get()).status).toBe(200); // once the run ended the next request reads fresh, never a cached body
  expect(t.runs()).toBe(2);
});
