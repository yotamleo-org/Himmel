// GET /api/projects and GET /api/feed?project= — the Health page's picker and all-projects view.
// Nothing runs a doctor: each project answers from its own cached feed, or "not checked".
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer, projectFlags } from "../server";
import { readProjects } from "../projects";
import { stubKeyring } from "./keyring-stub";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const row = (id: string, health: string, scope: string, fix: object = { by: "chief" }) => ({ id, source: "doctor", health, scope, installed: { detail: `d-${id}` }, fix });
const shared = row("doctor:C12-gh-auth", "fail", "shared", { by: "operator", remedy: "gh auth login" });

function boot(extraEnv: Record<string, string> = {}) {
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
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1", ...extraEnv },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return Object.assign(s, { feeds, dir });
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

test("a malformed cache marks that project not checked and never fails the list", async () => {
  const { port, feeds } = boot();
  writeFileSync(join(feeds, "luna.json"), JSON.stringify({ rows: {} }));
  writeFileSync(join(feeds, "salus.json"), JSON.stringify({ rows: [null, 3, row("ok", "warn", "project")] }));
  const res = await get(port, "/api/projects");
  expect(res.status).toBe(200);
  const by = Object.fromEntries((await res.json()).projects.map((p: { name: string }) => [p.name, p]));
  expect(by.luna.checkedAt).toBeNull();
  expect(by.salus.counts.project).toEqual({ fail: 0, warn: 1 });
  const opened = await get(port, "/api/feed?project=luna"); // opening it answers as the picker does: not checked
  expect(opened.status).toBe(404);
  expect(await opened.json()).toMatchObject({ state: "not-checked" });
});

test("an unregistered checkout named like a registered project gets its own name and cache", () => {
  const dir = mkdtempSync(join(tmpdir(), "projects-name-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const reg = join(dir, "registry.json");
  writeFileSync(reg, JSON.stringify({ repos: { himmel: { path: "/elsewhere/himmel" } } }));
  const a = readProjects({ HANDOVER_REGISTRY: reg }, "/work/himmel"), b = readProjects({ HANDOVER_REGISTRY: reg }, "/other/himmel");
  expect(a.current).toMatch(/^himmel\.[0-9a-f]{6}$/);
  expect(b.current).not.toBe(a.current); // the same basename in another place is another project
  expect(a.list.map((p) => p.name)).toContain("himmel");
  expect(a.list.length).toBe(2);
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

test("a cached feed saved before a value was stored is masked when it is served", async () => {
  const kdir = mkdtempSync(join(tmpdir(), "projects-kr-"));
  cleanups.push(() => rmSync(kdir, { recursive: true, force: true }));
  const kr = "kr-only-" + "q7x2".repeat(2);
  const k = stubKeyring(kdir);
  k.put("JIRA_API_TOKEN", kr);
  const { port, feeds } = boot({ ...k.env, HIMMEL_SECRETS_KEYRING: "", JIRA_API_TOKEN: "" });
  writeFileSync(join(feeds, "luna.json"), JSON.stringify({ rows: [row("lunabad", "fail", "project")].map((r) => ({ ...r, installed: { detail: `d ${kr}` } })) }));
  const text = await (await get(port, "/api/feed?project=luna")).text();
  expect(text).toContain("lunabad");
  expect(text).not.toContain(kr);
});

// HIMMEL_SECRETS_KEYRING matches the secret-name pattern, but its value ("off") is a mode, not a credential: masking it
// would blank every "off" state the feed shows.
test("the keyring mode switch's value is not a redaction literal", async () => {
  const { port, feeds } = boot({ HIMMEL_SECRETS_KEYRING: "off" });
  writeFileSync(join(feeds, "luna.json"), JSON.stringify({ rows: [{ ...row("flag", "ok", "project"), installed: { detail: "48 off" } }] }));
  const text = await (await get(port, "/api/feed?project=luna")).text();
  expect(text).toContain("48 off");
});

test("/api/projects masks a cached feed's detail and remedy with the keyring's secrets", async () => {
  const kdir = mkdtempSync(join(tmpdir(), "projects-kr-"));
  cleanups.push(() => rmSync(kdir, { recursive: true, force: true }));
  const kr = "kr-only-" + "q7x2".repeat(2);
  const k = stubKeyring(kdir);
  k.put("FIRECRAWL_API_KEY", kr);
  const { port, feeds } = boot({ ...k.env, HIMMEL_SECRETS_KEYRING: "", FIRECRAWL_API_KEY: "" });
  writeFileSync(join(feeds, "luna.json"), JSON.stringify({ rows: [{ ...row("lunabad", "fail", "project"), installed: { detail: `d ${kr}` }, fix: { by: "operator", remedy: `run ${kr}` } }] }));
  const text = await (await get(port, "/api/projects")).text();
  expect(text).toContain("lunabad");
  expect(text).not.toContain(kr);
});

// ---- the Board default is every project with a mirror, wherever config-ui is launched ----
test("5494: the --project flag is read repeated and as --project=KEY, and a launch with none narrows nothing", () => {
  expect(projectFlags(["bun", "server.ts", "--project", "SALUS", "--port", "0", "--project=HIMMEL"])).toEqual(["SALUS", "HIMMEL"]);
  expect(projectFlags(["bun", "server.ts", "--port", "0"])).toEqual([]);
  expect(projectFlags(["bun", "server.ts", "--project"])).toEqual([]); // a flag with no value is dropped, not an empty project
});

test("5494 launch place: from an adopter repo cwd naming its own JIRA_PROJECT_KEY, /api/roadmap still lists every mirrored project", async () => {
  const dir = mkdtempSync(join(tmpdir(), "board-launch-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home"), adopter = join(dir, "adopter");
  mkdirSync(home); mkdirSync(adopter);
  writeFileSync(join(adopter, ".env"), "JIRA_PROJECT_KEY=ABC\n");
  const root = join(home, ".himmel", "state", "jira-mirror");
  for (const key of ["HIMMEL", "ABC"]) {
    mkdirSync(join(root, key), { recursive: true });
    writeFileSync(join(root, key, `${key}-1.md`), ["---", `key: "${key}-1"`, `status: "To Do"`, `statusCategory: "To Do"`, `labels: []`, `fixVersions: ["v1.1.2"]`, "---", "", `# ${key}-1: t`, ""].join("\n"));
    writeFileSync(join(root, `${key}.versions.tsv`), "v1.1.2\tfalse\t\n");
  }
  const s = startServer({ port: 0, token: TOKEN, root: adopter, projectRoot: adopter, legsScript: join(dir, "none.sh"),
    env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" } });
  cleanups.push(() => s.stop());
  const r = await (await get(s.port, "/api/roadmap")).json();
  expect(r.projects).toEqual(["ABC", "HIMMEL"]);
  expect(r.tickets.map((t: { id: string }) => t.id)).toEqual(["ABC-1", "HIMMEL-1"]);
  expect((await (await get(s.port, "/api/sources")).json()).sources).toEqual(["jira"]); // the rail link: without it the page is unreachable
});
