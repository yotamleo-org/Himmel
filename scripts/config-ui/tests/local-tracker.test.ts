// Roadmap and Kanban on the local tracker backend (no Jira): cards read from the local store keyed by their generated
// LOCAL-<n> id, and a drop or a Sector select written through the tracker seam (scripts/lib/tracker.sh). Both Jira CLIs are
// stubs that log any call (JIRA_CMD for the seam, CONFIG_UI_JIRA_CLI for jira-write.ts): a local card must reach neither.
import { test, expect, afterEach } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRoadmap } from "../roadmap";
import { renderKanban } from "../public/roadmap.js";
import { startServer } from "../server";
import { readLocalItems } from "../local-tracker";

const TOKEN = "c".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

// one store item in the format tracker-local.sh writes
const item = (n: number, status: string, title: string, o: { fv?: string; epic?: string; sector?: string } = {}) =>
  ["---", `id: LOCAL-${n}`, `title: ${JSON.stringify(title)}`, "type: Task", `status: ${status}`, `fix_version:${o.fv ? " " + o.fv : ""}`,
    `epic:${o.epic ? " " + o.epic : ""}`, "created: 2026-10-01T00:00:00Z", ...(o.sector ? [`sector: ${JSON.stringify(o.sector)}`] : []), "links:", "---", "", "", "## Log", ""].join("\n");

// a git repo named `name` under `base`, with the given git config set
function repo(base: string, name: string, cfg: Record<string, string> = {}) {
  const p = join(base, name);
  mkdirSync(p);
  execFileSync("git", ["init", "-q", p]);
  for (const [k, v] of Object.entries(cfg)) execFileSync("git", ["-C", p, "config", k, v]);
  return p;
}

// projectGit: the server's projectRoot is a git repo (under the scratch dir) carrying this git config, while root stays a plain dir
function scratch(o: { tracker?: string; items?: boolean; mirror?: boolean; failedRead?: boolean; projectGit?: Record<string, string> } = {}) {
  const d = mkdtempSync(join(tmpdir(), "local-tracker-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const store = join(d, "store");
  mkdirSync(store);
  if (o.items !== false) {
    writeFileSync(join(store, "LOCAL-1.md"), item(1, "To Do", "Write the docs", { fv: "v1" }));
    writeFileSync(join(store, "LOCAL-2.md"), item(2, "In Progress", "Search the store", { fv: "v1", epic: "LOCAL-1", sector: "Search" }));
    writeFileSync(join(store, "LOCAL-3.md"), item(3, "Done", "Shipped", { fv: "v2" }));
    writeFileSync(join(store, "LOCAL-4.md"), item(4, "To Do", "Unversioned"));
    writeFileSync(join(store, "next-id"), "5\n");
  }
  const mirror = join(d, "mirror");
  if (o.mirror) { mkdirSync(mirror); writeFileSync(join(mirror, "HIMMEL-1.md"), '---\nkey: "HIMMEL-1"\nstatus: "To Do"\nstatusCategory: "To Do"\nlabels: []\nfixVersions: ["v1.1.3"]\nupdated: "2026-10-01T00:00:00.000+0000"\nresolution: null\n---\n\n# HIMMEL-1: x\n'); }
  const seamLog = join(d, "seam-jira.log"), cliLog = join(d, "cli-jira.log"), seamJira = join(d, "jira-cmd");
  writeFileSync(seamJira, `#!/bin/sh\necho "$*" >> "${seamLog}"\nexit 1\n`);
  chmodSync(seamJira, 0o755);
  const env = { PATH: process.env.PATH, HOME: d, TRACKER: o.tracker ?? "local", ...(o.failedRead ? { HANDOVER_DIR: join(d, "missing-handover"), USER_SLUG: "x" } : { TRACKER_STORE: store }), JIRA_CMD: seamJira,
    HIMMEL_SECRETS_KEYRING: "off", HIMMEL_JIRA_MIRROR: o.mirror ? mirror : join(d, "no-mirror"), CONFIG_UI_JIRA_CLI: join(import.meta.dir, "stub-jira.js"), STUB_JIRA_LOG: cliLog,
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } as Record<string, string>;
  const projectRoot = o.projectGit ? repo(d, "proj", o.projectGit) : undefined;
  const srv = startServer({ port: 0, token: TOKEN, root: d, projectRoot, env, legsScript: join(d, "no-workers.sh") });
  cleanups.push(() => srv.stop());
  const base = `http://127.0.0.1:${srv.port}`;
  const get = async (p: string) => (await fetch(base + p, { headers: { "X-Himmel-Token": TOKEN } })).json();
  const post = (body: unknown, token: string | null = TOKEN) => fetch(base + "/api/roadmap/write", {
    method: "POST", headers: { "content-type": "application/json", origin: base, ...(token === null ? {} : { "x-himmel-token": token }) }, body: JSON.stringify(body),
  });
  const file = (n: number) => readFileSync(join(store, `LOCAL-${n}.md`), "utf8");
  const audit = () => { const f = join(d, ".himmel", "state", "config-ui", "actions.jsonl"); return existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []; };
  const jiraCalls = () => [seamLog, cliLog].filter((f) => existsSync(f));
  return { d, env, store, get, post, file, audit, jiraCalls };
}

test("local items map to the roadmap: LOCAL-<n> ids, the ladder to columns, fix_version to versions, epic and sector kept", async () => {
  const s = scratch();
  const items = await readLocalItems(s.env, s.d);
  const r = readRoadmap({ mirrorDir: "", local: items ?? [], workers: { state: "absent" } });
  expect(r.state).toBe("ok");
  expect(r.source).toBe("local");
  expect(r.tickets.map((t) => [t.k, t.id, t.b, t.backend])).toEqual([[1, "LOCAL-1", "todo", "local"], [2, "LOCAL-2", "prog", "local"], [3, "LOCAL-3", "done", "local"], [4, "LOCAL-4", "todo", "local"]]);
  expect(r.versions.map((v) => v.n)).toEqual(["v1", "v2", "(no version)"]);
  const by = Object.fromEntries(r.tickets.map((t) => [t.k, t]));
  expect(r.versions[by[4].v].n).toBe("(no version)");
  expect(by[2].epic).toBe("LOCAL-1");
  expect(r.themes[by[2].theme]).toBe("Search");
  expect(s.jiraCalls()).toEqual([]);
});

test("GET /api/sources and /api/roadmap: a local-backend project gets its cards from the store, no Jira call", async () => {
  const s = scratch();
  expect(await s.get("/api/sources")).toEqual({ sources: ["local"] });
  const r = await s.get("/api/roadmap");
  expect(r.source).toBe("local");
  expect(r.tickets.map((t: { id: string }) => t.id)).toEqual(["LOCAL-1", "LOCAL-2", "LOCAL-3", "LOCAL-4"]);
  expect(s.jiraCalls()).toEqual([]);
});

test("the Kanban draws local cards writable, with their id and their backend", async () => {
  const s = scratch();
  const r = { ...readRoadmap({ mirrorDir: "", local: (await readLocalItems(s.env, s.d)) ?? [], workers: { state: "absent" } }), sync: [] };
  const html = renderKanban(r, { hideDone: false, writes: true });
  expect(html).toContain('data-rm-id="LOCAL-2"');
  expect(html).toContain("<b>LOCAL-2</b>");
  expect(html).toContain('data-rm-backend="local"');
  expect(html).not.toContain("HIMMEL-2");
});

test("a drop on a local card moves it through the seam (back too), audited, and neither Jira CLI is run", async () => {
  const s = scratch();
  const r = await s.post({ key: "LOCAL-1", backend: "local", status: "prog" });
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ ok: true, key: "LOCAL-1", status: "prog", backend: "local" });
  expect(s.file(1)).toContain("\nstatus: In Progress\n");
  const back = await s.post({ key: "LOCAL-2", backend: "local", status: "todo" });
  expect(back.status).toBe(200);
  expect(s.file(2)).toContain("\nstatus: To Do\n");
  expect(s.audit()[0]).toMatchObject({ action: "tracker-transition", target: "LOCAL-1", value: "prog", rc: 0, before: { status: "To Do" }, after: { status: "In Progress" } });
  expect(s.audit()[0].argv).toContain("tracker_transition");
  expect(s.jiraCalls()).toEqual([]);
});

test("a Sector select on a local card writes the store's sector line through the seam, and the board reads it back", async () => {
  const s = scratch();
  const r = await s.post({ key: "LOCAL-1", backend: "local", sector: "Ship loop" });
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ ok: true, key: "LOCAL-1", sector: "Ship loop" });
  expect(s.file(1)).toContain('\nsector: "Ship loop"\n');
  const rm = await s.get("/api/roadmap");
  const t = rm.tickets.find((x: { id: string }) => x.id === "LOCAL-1");
  expect(rm.themes[t.theme]).toBe("Ship loop");
  expect(s.audit()[0]).toMatchObject({ action: "tracker-sector", target: "LOCAL-1", value: "Ship loop", rc: 0 });
  expect(s.jiraCalls()).toEqual([]);
});

test("a status outside the seam's ladder, or a move out of Done, is refused and the item is unchanged", async () => {
  const s = scratch();
  const wont = await s.post({ key: "LOCAL-1", backend: "local", status: "wont" });
  expect(wont.status).toBe(400);
  expect((await wont.json()).output).toContain("is not a tracker status");
  expect(s.file(1)).toContain("\nstatus: To Do\n");
  const done = await s.post({ key: "LOCAL-3", backend: "local", status: "todo" });
  expect(done.status).toBe(409);
  expect(s.file(3)).toContain("\nstatus: Done\n");
  expect(s.jiraCalls()).toEqual([]);
});

test("local writes are refused with no seam call: no token, a bad id, a bad Sector, an absent item, no local source", async () => {
  const s = scratch();
  expect((await s.post({ key: "LOCAL-1", backend: "local", status: "prog" }, null)).status).toBe(401);
  expect((await s.post({ key: "LOCAL-1; rm", backend: "local", status: "prog" })).status).toBe(400);
  expect((await s.post({ key: "LOCAL-1", backend: "local", sector: "-x" })).status).toBe(400);
  expect((await s.post({ key: "HIMMEL-1", backend: "nope", status: "prog" })).status).toBe(400);
  expect((await s.post({ key: "LOCAL-9", backend: "local", status: "prog" })).status).toBe(404);
  expect(s.file(1)).toContain("\nstatus: To Do\n");
  const none = scratch({ tracker: "none" });
  expect((await none.post({ key: "LOCAL-1", backend: "local", status: "prog" })).status).toBe(403);
  expect(none.file(1)).toContain("\nstatus: To Do\n");
  expect([...s.jiraCalls(), ...none.jiraCalls()]).toEqual([]);
});

test("a Jira write for a HIMMEL key is refused with 403 and no Jira call on a local or none project, whatever the store holds", async () => {
  for (const [name, o] of [["local with items", {}], ["local, store unreadable", { failedRead: true }], ["local, empty store", { items: false }], ["none", { tracker: "none" }], ["implicit local, no setting", { tracker: "" }], ["a malformed setting", { tracker: "Local" }], ["a typo", { tracker: "lokal" }]] as [string, Parameters<typeof scratch>[0]][]) {
    const s = scratch({ ...o, mirror: true });
    const r = await s.post({ key: "HIMMEL-1", status: "prog" });
    expect([name, r.status]).toEqual([name, 403]);
    expect([name, s.jiraCalls()]).toEqual([name, []]);
  }
});

test("the tracker is read from the project root, not the checkout root: a project that is local only by git config refuses a Jira write", async () => {
  const s = scratch({ tracker: "", mirror: true, items: false, projectGit: { "himmel.tracker": "local" } });
  const r = await s.post({ key: "HIMMEL-1", status: "prog" });
  expect(r.status).toBe(403);
  expect(s.jiraCalls()).toEqual([]);
});

test("the default-bucket store is the project's, not the checkout's: reads and writes both follow projectRoot", async () => {
  const d = mkdtempSync(join(tmpdir(), "local-tracker-bucket-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const H = join(d, "handovers");
  const root = repo(d, "rootrepo"), proj = repo(d, "projrepo");
  for (const [name, title] of [["rootrepo", "Root item"], ["projrepo", "Project item"]]) {
    const store = join(H, "u", name, "tracker");
    mkdirSync(store, { recursive: true });
    writeFileSync(join(store, "LOCAL-1.md"), item(1, "To Do", title));
    writeFileSync(join(store, "next-id"), "2\n");
  }
  const env = { PATH: process.env.PATH, HOME: d, TRACKER: "local", HANDOVER_DIR: H, USER_SLUG: "u", HIMMEL_SECRETS_KEYRING: "off", HIMMEL_JIRA_MIRROR: join(d, "no-mirror"),
    CONFIG_UI_JIRA_CLI: join(import.meta.dir, "stub-jira.js"), CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } as Record<string, string>;
  const srv = startServer({ port: 0, token: TOKEN, root, projectRoot: proj, env, legsScript: join(d, "no-workers.sh") });
  cleanups.push(() => srv.stop());
  const base = `http://127.0.0.1:${srv.port}`;
  const rm = await (await fetch(base + "/api/roadmap", { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(rm.tickets.map((t: { t: string }) => t.t)).toEqual(["Project item"]);
  const w = await fetch(base + "/api/roadmap/write", { method: "POST", headers: { "content-type": "application/json", origin: base, "x-himmel-token": TOKEN }, body: JSON.stringify({ key: "LOCAL-1", backend: "local", status: "prog" }) });
  expect(w.status).toBe(200);
  expect(readFileSync(join(H, "u", "projrepo", "tracker", "LOCAL-1.md"), "utf8")).toContain("\nstatus: In Progress\n");
  expect(readFileSync(join(H, "u", "rootrepo", "tracker", "LOCAL-1.md"), "utf8")).toContain("\nstatus: To Do\n");
});
