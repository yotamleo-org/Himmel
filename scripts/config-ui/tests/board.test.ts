// GET /api/board: the Board page's saved status-drift summary and chain read. Both are read-only chief-kit
// scripts, started only when their input is named in the environment. Everything here lives in a scratch directory.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const TOKEN = "a".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const mirrorIssue = (n: number, status: string, cat: string, blockedBy: string[], title: string) =>
  ["---", `key: "HIMMEL-${n}"`, `type: "Task"`, `status: ${JSON.stringify(status)}`, `statusCategory: ${JSON.stringify(cat)}`, `priority: "Medium"`,
    `labels: []`, `fixVersions: ["v1.1.3"]`, `parent: null`, `created: "2026-10-01T00:00:00.000+0000"`, `updated: "2026-10-02T00:00:00.000+0000"`,
    `resolution: null`, "links:", "  blocks: []", `  blocked_by: ${JSON.stringify(blockedBy)}`, "  relates: []", "---", "", `# HIMMEL-${n}: ${title}`, "",
    "## Description", "", "x", "", "## Comments", "", "_(none)_", ""].join("\n");

function scratch() {
  const d = mkdtempSync(join(tmpdir(), "board-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const home = join(d, "home"), mirror = join(d, "state", "jira-mirror", "HIMMEL"), conf = join(d, "conf");
  for (const p of [home, mirror, conf]) mkdirSync(p, { recursive: true });
  writeFileSync(join(mirror, "HIMMEL-1.md"), mirrorIssue(1, "Done", "Done", [], "First step"));
  writeFileSync(join(mirror, "HIMMEL-2.md"), mirrorIssue(2, "To Do", "To Do", ["HIMMEL-1"], "Second step"));
  const registry = join(d, "registry.json");
  writeFileSync(registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2"] }] }));
  const drift = join(d, "focus-drift.txt");
  writeFileSync(drift, "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=jira release request v1.1.3\nsdrift=1:abc\n");
  const known = join(d, "known.tsv");
  writeFileSync(known, "# checker\tclass\tkey\tedited-at\n");
  return { d, home, mirror, conf, registry, drift, known };
}
const serve = (env: Record<string, string>, s: ReturnType<typeof scratch>) => {
  const srv = startServer({
    port: 0, token: TOKEN, legsScript: join(s.d, "no-workers.sh"),
    env: { PATH: process.env.PATH, HOME: s.home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_CONFIG_DIR: s.conf, DRIFT_SUMMARY_KNOWN: s.known, ...env },
  });
  cleanups.push(() => srv.stop());
  return `http://127.0.0.1:${srv.port}/api/board`;
};
const get = async (url: string) => (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
// every file under d with its size and mtime: a read must leave this unchanged
const snapshot = (dir: string): string[] => readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const p = join(dir, e.name);
  return e.isDirectory() ? snapshot(p) : [`${p} ${statSync(p).size} ${statSync(p).mtimeMs}`];
}).sort();

test("GET /api/board: token-gated, GET-only; with no input named both reads are absent with the reason and nothing is spawned", async () => {
  const s = scratch();
  const url = serve({}, s);
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r = await get(url);
  expect(r.drift.state).toBe("absent");
  expect(r.drift.reason).toContain("HIMMEL_FOCUS_DRIFT");
  expect(r.chains.state).toBe("absent");
  expect(r.chains.reason).toContain("HIMMEL_CHAIN_REGISTRY");
  expect(r.drift.counts).toBeUndefined(); // no count is invented
});

test("GET /api/board: the saved drift file and the chain registry named in the environment are read through the chief-kit scripts", async () => {
  const s = scratch();
  const r = await get(serve({ HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s));
  expect(r.drift.counts).toEqual({ real: 1, known: 0, transient: 0 });
  expect(r.drift.real[0]).toMatchObject({ class: "VERSION-DRIFT", key: "HIMMEL-6691" });
  expect(r.drift.mode).toBe("single-user");
  expect(r.chains.schema).toBe("himmel.chains/1");
  expect(r.chains.chains.map((c: { id: string }) => c.id)).toEqual(["memory"]);
  expect(r.chains.tickets["HIMMEL-2"].state).toBe("can launch"); // its only blocker, HIMMEL-1, is Done
  expect(r.chains.tickets["HIMMEL-1"].chains[0]).toMatchObject({ id: "memory", step: 1, steps: 2 });
});

test("GET /api/board: the drift file also comes from TRACKER_HANDOVERS_DIR/focus-drift.txt", async () => {
  const s = scratch();
  const r = await get(serve({ TRACKER_HANDOVERS_DIR: s.d }, s));
  expect(r.drift.counts.real).toBe(1);
});

test("GET /api/board: a missing drift file reports exists=false, and a bad registry is absent with the reason", async () => {
  const s = scratch();
  writeFileSync(join(s.d, "bad.json"), "{}");
  const r = await get(serve({ HIMMEL_FOCUS_DRIFT: join(s.d, "none.txt"), HIMMEL_CHAIN_REGISTRY: join(s.d, "bad.json") }, s));
  expect(r.drift.file.exists).toBe(false);
  expect(r.chains.state).toBe("absent");
  expect(r.chains.reason).toContain("the chain read failed");
});

test("GET /api/board is read-only: nothing under the scratch tree changes", async () => {
  const s = scratch();
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s);
  const before = snapshot(s.d);
  await get(url);
  await get(url);
  expect(snapshot(s.d)).toEqual(before);
  expect(readFileSync(s.drift, "utf8")).toContain("sdrift=1:abc");
});
