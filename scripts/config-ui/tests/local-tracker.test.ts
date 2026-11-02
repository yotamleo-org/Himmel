// Roadmap and Kanban on the local tracker backend (no Jira): cards read from the local store keyed by their generated
// LOCAL-<n> id, and a drop or a Sector select written through the tracker seam (scripts/lib/tracker.sh). Both Jira CLIs are
// stubs that log any call (JIRA_CMD for the seam, CONFIG_UI_JIRA_CLI for jira-write.ts): a local card must reach neither.
import { test, expect, afterEach } from "bun:test";
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

function scratch(o: { tracker?: string; items?: boolean } = {}) {
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
  const seamLog = join(d, "seam-jira.log"), cliLog = join(d, "cli-jira.log"), seamJira = join(d, "jira-cmd");
  writeFileSync(seamJira, `#!/bin/sh\necho "$*" >> "${seamLog}"\nexit 1\n`);
  chmodSync(seamJira, 0o755);
  const env = { PATH: process.env.PATH, HOME: d, TRACKER: o.tracker ?? "local", TRACKER_STORE: store, JIRA_CMD: seamJira,
    HIMMEL_JIRA_MIRROR: join(d, "no-mirror"), CONFIG_UI_JIRA_CLI: join(import.meta.dir, "stub-jira.js"), STUB_JIRA_LOG: cliLog,
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } as Record<string, string>;
  const srv = startServer({ port: 0, token: TOKEN, root: d, env, legsScript: join(d, "no-workers.sh") });
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
