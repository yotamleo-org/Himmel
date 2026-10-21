// the tracker sources the UI can read (trackerSources) and the GitHub issues source behind Roadmap and Kanban.
// gh is always a stub (GH_CMD) answering fake issues; nothing here reaches GitHub or Jira.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRoadmap } from "../roadmap";
import { renderKanban, renderRoadmap } from "../public/roadmap.js";
import { navLinks } from "../public/nav.js";
import { startServer } from "../server";
import { ISSUE_LIMIT, trackerSources } from "../tracker-sources";

const TOKEN = "a".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const ISSUES = [
  { number: 11, title: "Open and unlabelled", state: "OPEN", stateReason: "", labels: [], milestone: { number: 1, title: "v1" }, updatedAt: "2026-10-01T00:00:00Z" },
  { number: 12, title: "Being worked", state: "OPEN", stateReason: "", labels: [{ name: "in-progress" }, { name: "theme-search" }], milestone: { number: 1, title: "v1" }, updatedAt: "2026-10-02T00:00:00Z" },
  { number: 13, title: "Shipped", state: "CLOSED", stateReason: "COMPLETED", labels: [], milestone: { number: 2, title: "v2" }, updatedAt: "2026-10-03T00:00:00Z" },
  { number: 14, title: "Dropped", state: "CLOSED", stateReason: "NOT_PLANNED", labels: [], milestone: null, updatedAt: "2026-10-04T00:00:00Z" },
];

// A scratch home with an optional Jira mirror, a gh stub that logs its argv, and a Jira CLI stub that must stay unused.
function scratch(o: { mirror?: boolean; ghAuth?: boolean; issues?: unknown } = {}) {
  const d = mkdtempSync(join(tmpdir(), "tracker-sources-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const mirror = join(d, "mirror");
  mkdirSync(mirror);
  if (o.mirror) writeFileSync(join(mirror, "HIMMEL-1.md"), '---\nkey: "HIMMEL-1"\nstatus: "To Do"\nstatusCategory: "To Do"\nlabels: []\nfixVersions: ["v1.1.3"]\nupdated: "2026-10-01T00:00:00.000+0000"\nresolution: null\n---\n\n# HIMMEL-1: x\n');
  const ghLog = join(d, "gh.log"), jiraLog = join(d, "jira.log");
  const gh = join(d, "gh");
  writeFileSync(gh, `#!/bin/sh
echo "$*" >> "${ghLog}"
case "$1 $2" in
  "auth status") exit ${o.ghAuth === false ? 1 : 0} ;;
  "issue list") cat <<'EOF'
${JSON.stringify(o.issues ?? ISSUES)}
EOF
  ;;
esac
`);
  chmodSync(gh, 0o755);
  const env = { PATH: process.env.PATH, HOME: d, HIMMEL_JIRA_MIRROR: mirror, GH_CMD: gh, CONFIG_UI_JIRA_CLI: join(import.meta.dir, "stub-jira.js"), STUB_JIRA_LOG: jiraLog,
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } as Record<string, string>;
  return { d, env, ghCalls: () => (existsSync(ghLog) ? readFileSync(ghLog, "utf8").split("\n").filter(Boolean) : []), jiraCalls: () => existsSync(jiraLog) };
}
const serve = (env: Record<string, string>, root: string) => {
  const srv = startServer({ port: 0, token: TOKEN, root, env, legsScript: join(root, "no-legs.sh") });
  cleanups.push(() => srv.stop());
  const get = async (p: string) => (await fetch(`http://127.0.0.1:${srv.port}${p}`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  return { srv, get };
};

test("trackerSources: empty with no tracker source configured, and no gh call is made", async () => {
  const s = scratch();
  expect(await trackerSources(s.env, s.d)).toEqual([]);
  expect(s.ghCalls()).toEqual([]);
});

test("trackerSources: himmel.tracker is read from the supplied env's HOME, not the process's", async () => {
  const s = scratch();
  writeFileSync(join(s.d, ".gitconfig"), "[himmel]\n\ttracker = github\n");
  expect(await trackerSources(s.env, s.d)).toEqual(["github"]);
});

test("trackerSources: the Jira mirror, once it holds tickets, is a source", async () => {
  expect(await trackerSources(scratch({ mirror: true }).env, "/")).toEqual(["jira"]);
});

test("trackerSources: a configured source the UI cannot read is not listed (missing mirror, TRACKER=local, unauthenticated gh)", async () => {
  const s = scratch();
  expect(await trackerSources({ ...s.env, HIMMEL_JIRA_MIRROR: join(s.d, "nope") }, s.d)).toEqual([]);
  expect(await trackerSources({ ...s.env, TRACKER: "local" }, s.d)).toEqual([]);
  const unauth = scratch({ ghAuth: false });
  expect(await trackerSources({ ...unauth.env, TRACKER: "github" }, unauth.d)).toEqual([]);
  expect(unauth.ghCalls()).toEqual(["auth status"]);
});

test("trackerSources: TRACKER=github with gh authenticated lists github", async () => {
  const s = scratch();
  expect(await trackerSources({ ...s.env, TRACKER: "github" }, s.d)).toEqual(["github"]);
});

test("trackerSources: an explicit TRACKER=github comes before a Jira mirror that also exists, and the roadmap reads the issues", async () => {
  const s = scratch({ mirror: true });
  const env = { ...s.env, TRACKER: "github" };
  expect(await trackerSources(env, s.d)).toEqual(["github", "jira"]);
  const { get } = serve(env, s.d);
  const r = await get("/api/roadmap");
  expect(r.source).toBe("github");
  expect(r.tickets.map((t: { id: string }) => t.id)).toEqual(["#11", "#12", "#13", "#14"]);
});

test("GET /api/roadmap: a full page of issues is flagged truncated, a short one is not, and malformed entries are dropped", async () => {
  const many = Array.from({ length: ISSUE_LIMIT }, (_, i) => ({ number: i + 1, title: `t${i}`, state: "OPEN", labels: [], milestone: null }));
  const full = scratch({ issues: many });
  expect((await serve({ ...full.env, TRACKER: "github" }, full.d).get("/api/roadmap")).truncated).toBe(true);
  const short = scratch({ issues: [null, { title: "no state" }, ...ISSUES] });
  const r = await serve({ ...short.env, TRACKER: "github" }, short.d).get("/api/roadmap");
  expect(r.truncated).toBe(false);
  expect(r.tickets.length).toBe(4);
});

test("an inherited-property label name is no status, and a malformed entry cannot break the board", async () => {
  const odd = { number: 31, title: "odd", state: "OPEN", labels: [{ name: "constructor" }, { name: "toString" }], milestone: null };
  const bad = { number: 32, state: "OPEN", labels: "x", milestone: { title: 3 } };
  const s = scratch({ issues: [odd, bad] });
  const r = await serve({ ...s.env, TRACKER: "github" }, s.d).get("/api/roadmap");
  expect(r.state).toBe("ok");
  expect(r.tickets.map((t: { id: string; b: string }) => [t.id, t.b])).toEqual([["#31", "todo"], ["#32", "todo"]]);
});

test("the Roadmap page says when the issue list is truncated, as the Kanban does", () => {
  const r = { ...readRoadmap({ mirrorDir: "", github: ISSUES, legs: { state: "absent" } }), sync: [], truncated: true };
  expect(renderRoadmap(r, { writes: false })).toContain("older ones are missing");
  expect(renderRoadmap({ ...r, truncated: false }, { writes: false })).not.toContain("older ones are missing");
});

test("the rail hides Roadmap and Kanban when the sources are empty, keeps them otherwise or while unknown", () => {
  const labels = (sources?: string[]) => navLinks({ here: "console", token: TOKEN, current: "config", sources }).map((l: { label: string }) => l.label);
  expect(labels([])).toEqual(["Config", "Health", "Tool health", "Fleet", "Workflow", "Docs"]);
  expect(labels(["github"])).toContain("Kanban");
  expect(labels(["jira"])).toContain("Roadmap");
  expect(labels(undefined)).toContain("Roadmap");
});

test("GitHub issues map to the roadmap: state and labels to columns, milestone to version, theme- label to theme, #number ids", () => {
  const r = readRoadmap({ mirrorDir: "", github: ISSUES, legs: { state: "absent" } });
  expect(r.state).toBe("ok");
  expect(r.source).toBe("github");
  expect(r.versions.map((v) => v.n)).toEqual(["v1", "v2", "(no milestone)"]);
  const by = Object.fromEntries(r.tickets.map((t) => [t.k, t]));
  expect([by[11].b, by[12].b, by[13].b, by[14].b]).toEqual(["todo", "prog", "done", "wont"]);
  expect(by[12].id).toBe("#12");
  expect(r.versions[by[12].v].n).toBe("v1");
  expect(r.versions[by[14].v].n).toBe("(no milestone)");
  expect(r.themes[by[12].theme]).toBe("search");
});

test("GitHub cards render read-only, with their #number, and the page says so", () => {
  const r = { ...readRoadmap({ mirrorDir: "", github: ISSUES, legs: { state: "absent" } }), sync: [] };
  const html = renderKanban(r, { hideDone: false, writes: true });
  expect(html).toContain("#12");
  expect(html).toContain("read-only");
  expect(html).not.toContain("draggable");
  expect(html).not.toContain("HIMMEL-12");
});

test("GET /api/sources and /api/roadmap: a GitHub-issues project gets cards from gh, and no Jira CLI call is made", async () => {
  const s = scratch();
  const { srv, get } = serve({ ...s.env, TRACKER: "github" }, s.d);
  const url = `http://127.0.0.1:${srv.port}/api/sources`;
  expect((await fetch(url)).status).toBe(401);
  expect(await get("/api/sources")).toEqual({ sources: ["github"] });
  const r = await get("/api/roadmap");
  expect(r.state).toBe("ok");
  expect(r.source).toBe("github");
  expect(r.tickets.map((t: { id: string }) => t.id)).toEqual(["#11", "#12", "#13", "#14"]);
  expect(s.ghCalls().some((c) => c.startsWith("issue list"))).toBe(true);
  expect(s.jiraCalls()).toBe(false);
});

test("GET /api/roadmap: with gh unauthenticated there is no source and no board", async () => {
  const s = scratch({ ghAuth: false });
  const { get } = serve({ ...s.env, TRACKER: "github" }, s.d);
  expect(await get("/api/sources")).toEqual({ sources: [] });
  const r = await get("/api/roadmap");
  expect(r.state).toBe("absent");
  expect(r.tickets).toEqual([]);
  expect(s.ghCalls().some((c) => c.startsWith("issue list"))).toBe(false);
});
