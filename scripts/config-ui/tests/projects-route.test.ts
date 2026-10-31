// GET /api/projects and GET /api/feed?project= — the Health page's picker and all-projects view.
// Nothing runs a doctor: each project answers from its own cached feed, or "not checked".
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const row = (id: string, health: string, scope: string, fix: object = { by: "chief" }) => ({ id, source: "doctor", health, scope, installed: { detail: `d-${id}` }, fix });
const shared = row("doctor:C12-gh-auth", "fail", "shared", { by: "operator", remedy: "gh auth login" });

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "projects-route-"));
  const home = join(dir, "home"), root = join(dir, "root"), here = join(dir, "himmel");
  for (const d of [home, root, here]) mkdirSync(d, { recursive: true });
  mkdirSync(join(home, ".claude", "handover"), { recursive: true });
  const repos = { himmel: { path: here }, luna: { path: join(dir, "luna") }, salus: { path: join(dir, "salus") } };
  writeFileSync(join(home, ".claude", "handover", "registry.json"), JSON.stringify({ repos }));
  const feeds = join(home, ".himmel", "state", "config-ui", "feeds");
  mkdirSync(feeds, { recursive: true });
  const cache = (name: string, rows: object[]) => writeFileSync(join(feeds, `${name}.json`), JSON.stringify({ rows }));
  cache("himmel", [shared, row("mine", "warn", "project"), row("fine", "ok", "project")]);
  cache("luna", [shared, row("lunabad", "fail", "project", { by: "configure", tile: "tracker" })]);
  const s = startServer({
    port: 0, token: TOKEN, projectRoot: here,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1" },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = (port: number, path: string, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }) => fetch(`http://127.0.0.1:${port}${path}`, { headers });

test("no token is 401", async () => {
  const { port } = boot();
  expect((await get(port, "/api/projects", {})).status).toBe(401);
});

test("a shared failure sits in each cache but is counted in no project's own verdict", async () => {
  const { port } = boot();
  const j = await (await get(port, "/api/projects")).json();
  expect(j.current).toBe("himmel");
  const by = Object.fromEntries(j.projects.map((p: { name: string }) => [p.name, p]));
  expect(by.himmel.counts).toEqual({ project: { fail: 0, warn: 1 }, shared: { fail: 1, warn: 0 } });
  expect(by.luna.counts).toEqual({ project: { fail: 1, warn: 0 }, shared: { fail: 1, warn: 0 } });
  expect(by.himmel.broken.map((r: { id: string }) => r.id)).toEqual(["mine"]);
  expect(by.luna.broken[0].fix).toMatchObject({ by: "configure", tile: "tracker" });
  expect(by.himmel.current).toBe(true);
});

test("a project nobody ran a check in is not checked, never guessed", async () => {
  const { port } = boot();
  const salus = (await (await get(port, "/api/projects")).json()).projects.find((p: { name: string }) => p.name === "salus");
  expect(salus.checkedAt).toBeNull();
  expect(salus.counts.project).toEqual({ fail: 0, warn: 0 });
});

test("/api/feed?project= answers another project from its cache, else not-checked; names never reach the filesystem unchecked", async () => {
  const { port } = boot();
  const luna = await get(port, "/api/feed?project=luna");
  expect(luna.status).toBe(200);
  expect((await luna.json()).rows.map((r: { id: string }) => r.id)).toContain("lunabad");
  const salus = await get(port, "/api/feed?project=salus");
  expect(salus.status).toBe(404);
  expect(await salus.json()).toMatchObject({ state: "not-checked" });
  expect((await get(port, "/api/feed?project=" + encodeURIComponent("../../../etc/passwd"))).status).toBe(404);
});
