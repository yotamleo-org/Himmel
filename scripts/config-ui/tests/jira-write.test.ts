// POST /api/roadmap/write — a Kanban drop transitions the ticket in Jira, a Sector select sets its Sector
// (`edit --sector`). The Jira CLI is a stub (stub-jira.js) that records argv; nothing here reaches live Jira.
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer, jiraBin } from "../server";
import { readRoadmap } from "../roadmap";
import { renderKanban } from "../public/roadmap.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const JIRA = join(import.meta.dir, "stub-jira.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(extra: Record<string, string> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "jira-write-"));
  const home = join(dir, "home"), root = join(dir, "root"), log = join(dir, "jira.log");
  mkdirSync(home); mkdirSync(root);
  const s = startServer({
    port: 0, token: TOKEN,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_JIRA_CLI: JIRA, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root,
      STUB_JIRA_LOG: log, ...extra },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as string[]) : []);
  const audit = () => { const f = join(home, ".himmel", "state", "config-ui", "actions.jsonl"); return existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []; };
  const post = (body: unknown, o: { token?: string | null; origin?: string } = {}) => fetch(`http://127.0.0.1:${s.port}/api/roadmap/write`, {
    method: "POST",
    headers: { "content-type": "application/json", origin: o.origin ?? `http://127.0.0.1:${s.port}`, ...(o.token === null ? {} : { "x-himmel-token": o.token ?? TOKEN }) },
    body: JSON.stringify(body),
  });
  return { s, calls, audit, post };
}

test("a drop transitions the ticket with the mapped Jira status name", async () => {
  const b = boot();
  const r = await b.post({ key: "HIMMEL-5491", status: "rev" });
  expect(r.status).toBe(200);
  expect(b.calls().find((c) => c[0] === "transition")).toEqual(["transition", "HIMMEL-5491", "In Review"]);
  expect(await r.json()).toMatchObject({ ok: true, key: "HIMMEL-5491", status: "rev" });
  expect(b.audit()[0]).toMatchObject({ action: "jira-transition", target: "HIMMEL-5491", value: "rev", rc: 0 });
});

test("a Sector select sets the Sector with `edit --sector` and touches no label", async () => {
  const b = boot();
  const r = await b.post({ key: "HIMMEL-12", sector: "Ship loop" });
  expect(r.status).toBe(200);
  expect(b.calls().map((c) => c[0])).toEqual(["edit", "mirror"]);
  expect(b.calls()[0]).toEqual(["edit", "HIMMEL-12", "--sector", "Ship loop"]);
  expect(await r.json()).toMatchObject({ ok: true, key: "HIMMEL-12", sector: "Ship loop" });
  expect(b.audit()[0]).toMatchObject({ action: "jira-sector", target: "HIMMEL-12", value: "Ship loop", rc: 0 });
});

test("the old {theme} body is refused: the page no longer writes theme labels", async () => {
  const b = boot();
  expect((await b.post({ key: "HIMMEL-12", theme: "tracker" })).status).toBe(400);
  expect(b.calls()).toEqual([]);
});

test("a Jira refusal of the Sector is an error, audited with its rc, with no mirror refresh", async () => {
  const b = boot({ STUB_JIRA_FAIL: "edit" });
  const r = await b.post({ key: "HIMMEL-12", sector: "Nope" });
  expect(r.status).toBe(502);
  expect(b.calls().map((c) => c[0])).toEqual(["edit"]);
  expect(b.audit()[0]).toMatchObject({ action: "jira-sector", rc: 1 });
});

test("refused with no CLI call: missing token, bad key, unknown status, bad Sector, both or neither field", async () => {
  const b = boot();
  expect((await b.post({ key: "HIMMEL-1", status: "done" }, { token: null })).status).toBe(401);
  expect((await b.post({ key: "HIMMEL-1", status: "done" }, { token: "x".repeat(64) })).status).toBe(401);
  expect((await b.post({ key: "HIMMEL-1; rm", status: "done" })).status).toBe(400);
  expect((await b.post({ key: "SALUS-1", status: "done" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", status: "Done" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", status: "nope" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", sector: "" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", sector: null })).status).toBe(400); // the CLI cannot clear a Sector
  expect((await b.post({ key: "HIMMEL-1", sector: "-x" })).status).toBe(400); // would read as a CLI option
  expect((await b.post({ key: "HIMMEL-1", sector: "a\nb" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", sector: "a".repeat(61) })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", status: "done", sector: "x" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1" })).status).toBe(400);
  expect((await b.post({ key: "HIMMEL-1", status: "done" }, { origin: "http://evil.example" })).status).toBe(403);
  expect(b.calls()).toEqual([]);
  expect(b.audit()).toEqual([]);
});


test("a Jira refusal comes back as an error, is audited with its rc, and the mirror is not refreshed", async () => {
  const b = boot({ STUB_JIRA_FAIL: "transition" });
  const r = await b.post({ key: "HIMMEL-1", status: "done" });
  expect(r.status).toBe(502);
  expect((await r.json()).error).toMatch(/refused/);
  expect(b.calls().map((c) => c[0])).toEqual(["transition"]);
  expect(b.audit()[0]).toMatchObject({ action: "jira-transition", rc: 1 });
});

test("after a write the mirror is refreshed for the board", async () => {
  const b = boot();
  const r = await b.post({ key: "HIMMEL-1", status: "prog" });
  expect(b.calls().map((c) => c[0])).toEqual(["transition", "mirror"]);
  expect((await r.json()).mirror).toBe("refreshed");
});

// --- the read side: with no Sector, the retired Jira theme label beats the plan overlay -------------------------------
const issue = (n: number, labels: string[]) =>
  ["---", `key: "HIMMEL-${n}"`, `type: "Story"`, `status: "To Do"`, `statusCategory: "To Do"`, `labels: ${JSON.stringify(labels)}`,
    `fixVersions: ["v1.1.2"]`, `updated: "2026-10-09T10:00:00.000+0000"`, "---", "", `# HIMMEL-${n}: t${n}`, ""].join("\n");

test("roadmap.ts falls back to the Jira theme label over the plan theme, and maps a matching slug to the plan's name", () => {
  const d = mkdtempSync(join(tmpdir(), "jira-theme-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const mirror = join(d, "m"), plan = join(d, "plan");
  mkdirSync(mirror); mkdirSync(join(plan, "stage1"), { recursive: true });
  writeFileSync(join(mirror, "HIMMEL-1.md"), issue(1, ["theme-fleet-ops"]));
  writeFileSync(join(mirror, "HIMMEL-2.md"), issue(2, ["theme-brand-new"]));
  writeFileSync(join(mirror, "HIMMEL-3.md"), issue(3, []));
  writeFileSync(join(mirror, "..", "m.versions.tsv"), "v1.1.2\tfalse\t\n");
  writeFileSync(join(plan, "stage1", "C01.tsv"), "key\ttheme\nHIMMEL-1\ttracker\nHIMMEL-3\ttracker\nHIMMEL-9\tFleet Ops\n");
  const r = readRoadmap({ mirrorDir: mirror, planDir: plan, workers: { state: "absent" } as never });
  const t = Object.fromEntries(r.tickets.map((x) => [x.k, r.themes[x.theme]]));
  expect(t).toEqual({ 1: "Fleet Ops", 2: "brand-new", 3: "tracker" });
});

test("the Kanban card carries a Sector select and a draggable card; columns are drop targets", () => {
  const data = { state: "ok", versions: [{ n: "v1.1.2", rel: false, date: "", counts: {}, open: [] }], themes: ["(no sector)", "Visibility"],
    tickets: [{ k: 7, t: "x", s: "To Do", b: "todo", v: 0, theme: 1, pv: null, drift: 0, labels: [], worker: null }], mirror: { count: 1, newest: "" } };
  const html = renderKanban(data, { writes: true });
  expect(html).toContain('draggable="true"');
  expect(html).toContain('data-rm-drop="prog"');
  expect(html).toMatch(/data-rm-theme-key="7"/);
  expect(html).toContain('aria-label="Sector of HIMMEL-7"');
  expect(html).toContain('<option value="Visibility" selected>');
  expect(renderKanban(data, {})).not.toContain('draggable="true"');
});

test("the no-sector bucket is offered disabled unless it is the card's group: the CLI cannot clear a Sector", () => {
  const data = { state: "ok", versions: [{ n: "v1.1.2", rel: false, date: "", counts: {}, open: [] }], themes: ["(no sector)", "Visibility"],
    tickets: [{ k: 7, t: "x", s: "To Do", b: "todo", v: 0, theme: 1, pv: null, drift: 0, labels: [], worker: null },
      { k: 8, t: "y", s: "To Do", b: "todo", v: 0, theme: 0, pv: null, drift: 0, labels: [], worker: null }], mirror: { count: 2, newest: "" } };
  const html = renderKanban(data, { writes: true });
  expect(html).toContain('<option value="" disabled>(no sector)</option>');
  expect(html).toContain('<option value="" selected>(no sector)</option>');
});

test("jiraBin: the checkout's own dist/ wins, then HIMMEL_REPO, then the worktrees-layout primary; the test override beats all", () => {
  const base = mkdtempSync(join(tmpdir(), "jira-bin-"));
  cleanups.push(() => rmSync(base, { recursive: true, force: true }));
  const rel = "scripts/jira/dist/index.js";
  const touch = (root: string) => { mkdirSync(join(root, "scripts/jira/dist"), { recursive: true }); writeFileSync(join(root, rel), ""); return root; };
  const primary = touch(join(base, "primary"));
  const wt = join(primary, ".claude", "worktrees", "feat+x");
  const plain = join(base, "elsewhere", "wt");
  const repo = touch(join(base, "repo"));
  mkdirSync(wt, { recursive: true }); mkdirSync(plain, { recursive: true });
  expect(jiraBin({}, wt)).toBe(join(primary, rel));
  expect(jiraBin({ HIMMEL_REPO: repo }, plain)).toBe(join(repo, rel));
  expect(jiraBin({ HIMMEL_REPO: join(base, "missing") }, plain)).toBe(join(plain, rel));
  expect(jiraBin({ HIMMEL_REPO: repo }, touch(join(base, "own")))).toBe(join(base, "own", rel));
  expect(jiraBin({ CONFIG_UI_JIRA_CLI: "/x/stub.js", HIMMEL_REPO: repo }, plain)).toBe("/x/stub.js");
});
