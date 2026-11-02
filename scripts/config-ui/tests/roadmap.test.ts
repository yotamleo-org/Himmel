// the Roadmap page. GET /api/roadmap reads the Jira mirror, the plan dir and the workers live (no static
// render, no republish); the page draws the kanban by version and theme, the release panels and the drift trend, the
// worker -> Jira sync plan the chief kit writes, and the librarian's ready-to-approve lists. Read-only throughout.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { legSync, readRoadmap, SYNC_LABEL } from "../roadmap";
import { renderBoard, renderKanban, renderRoadmap } from "../public/roadmap.js";
import { navLinks, parseLanding } from "../public/nav.js";
import { startServer } from "../server";

const TOKEN = "a".repeat(64); // hex: parseLanding only accepts a hex token
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const issue = (n: number, status: string, cat: string, fv: string[], title: string, labels: string[] = [], body = "", res: string | null = null) =>
  ["---", `key: "HIMMEL-${n}"`, `type: "Story"`, `status: ${JSON.stringify(status)}`, `statusCategory: ${JSON.stringify(cat)}`,
    `priority: "Medium"`, `labels: ${JSON.stringify(labels)}`, `fixVersions: ${JSON.stringify(fv)}`, `parent: null`,
    `created: "2026-10-01T00:00:00.000+0000"`, `updated: "2026-10-0${Math.min(n, 9)}T10:00:00.000+0000"`, `resolution: ${JSON.stringify(res)}`,
    "links:", "  blocks: []", "  blocked_by: []", "  relates: []", "---", "", `# HIMMEL-${n}: ${title}`, "", "## Description", "", "x", "",
    "## Comments", "", body || "_(none)_", ""].join("\n");

// A scratch station: mirror + versions snapshot, a plan dir, a drift log and two worker docs.
function station() {
  const d = mkdtempSync(join(tmpdir(), "roadmap-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const mirror = join(d, "jira-mirror", "HIMMEL");
  mkdirSync(mirror, { recursive: true });
  const put = (n: number, s: string) => writeFileSync(join(mirror, `HIMMEL-${n}.md`), s);
  put(1, issue(1, "In Progress", "In Progress", ["v1.1.2"], "Roadmap in the ui"));
  put(2, issue(2, "In Progress", "In Progress", ["v1.1.2"], "Orphaned work"));
  put(3, issue(3, "Done", "Done", ["v1.1.1"], "Shipped thing"));
  put(4, issue(4, "To Do", "To Do", ["v1.1.1"], "Left behind"));
  put(5, issue(5, "To Do", "To Do", ["v1.1.2"], "Resumed work", ["product", SYNC_LABEL]));
  put(6, issue(6, "To Do", "To Do", ["v1.1.3"], "Roadmap in the UI!"));
  put(7, issue(7, "In Review", "In Progress", ["v1.1.2"], "Ready work", [], "### bot — 2026-10-08\n\n[leg-sync] N3 READY: PR #9\n"));
  writeFileSync(join(d, "jira-mirror", "HIMMEL.versions.tsv"), "v1.1.1\ttrue\t2026-10-01\nv1.1.2\tfalse\t\nv1.1.3\tfalse\t\n");
  const plan = join(d, "plan");
  mkdirSync(join(plan, "stage3"), { recursive: true }); mkdirSync(join(plan, "stage1"), { recursive: true });
  writeFileSync(join(plan, "stage3", "placement.tsv"), "key\tversion\tlayer\nHIMMEL-1\tv1.1.2\tfeatures\nHIMMEL-6\tv1.1.2\tfeatures\nHIMMEL-7\tv1.1.2\tbugs\n");
  writeFileSync(join(plan, "stage1", "C01.tsv"), "key\ttheme\timpact\nHIMMEL-1\ttracker\t3\nHIMMEL-6\ttracker\t2\nHIMMEL-7\tfleet\t1\n");
  const drift = join(d, "roadmap-drift.tsv");
  writeFileSync(drift, "utc\tdrift\tunplanned\tunthemed\n2026-10-07T00:00:00Z\t4\t3\t2\n2026-10-08T00:00:00Z\t1\t2\t2\n");
  const legsDir = join(d, "handovers");
  mkdirSync(legsDir);
  const blocked = join(legsDir, "HIMMEL-1-N1466b-roadmap-RESUME.md");
  writeFileSync(blocked, "# worker\n\n## Results\n- 03:00 LIVE — started\n- 04:32 BLOCKED — classifier permission hold\n");
  const live = join(legsDir, "HIMMEL-5-N2-resumed-RESUME.md");
  writeFileSync(live, "## Results\n- 03:00 BLOCKED — waiting\n- 05:00 RESUMED — going again\n");
  const ready = join(legsDir, "HIMMEL-7-N3-ready-RESUME.md");
  writeFileSync(ready, "## Results\n- 06:00 READY: PR #9\n");
  const workers = { state: "ok" as const, manifest: join(legsDir, "x.fleet.json"), workers: [
    { doc: blocked, status: "BLOCKED" }, { doc: live, status: "RESUMED" }, { doc: ready, status: "READY" }] };
  return { d, mirror, plan, drift, workers };
}
const read = (s: ReturnType<typeof station>, o: Record<string, unknown> = {}) =>
  readRoadmap({ mirrorDir: s.mirror, planDir: s.plan, driftLog: s.drift, workers: s.workers, ...o });
const byKey = (r: ReturnType<typeof readRoadmap>) => Object.fromEntries(r.tickets.map((t) => [t.k, t]));

test("the kanban: every train ticket sits in its Jira version and its status column, themed from the plan", () => {
  const r = read(station());
  expect(r.state).toBe("ok");
  expect(r.versions.map((v) => v.n)).toEqual(["v1.1.1", "v1.1.2", "v1.1.3"]);
  expect(r.releaseUnknown).toBe(false);
  const t = byKey(r);
  expect(r.versions[t[1].v].n).toBe("v1.1.2");
  expect(t[1].b).toBe("prog");
  expect(t[7].b).toBe("rev");
  expect(t[3].b).toBe("done");
  expect(r.themes[t[1].theme]).toBe("tracker");
  expect(r.themes[t[2].theme]).toBe("(no sector)");
  // the running version is the earliest unreleased one with open work; the release panel counts its columns
  expect(r.versions[r.cur].n).toBe("v1.1.2");
  expect(r.versions[1].counts).toEqual({ todo: 1, prog: 2, rev: 1, ci: 0, done: 0, wont: 0 });
});

test("buckets follow tracker.py: Closed, wont do and Done with a non-shipping resolution are wont, not done", () => {
  const s = station();
  const put = (n: number, st: string, cat: string, res: string | null) =>
    writeFileSync(join(s.mirror, `HIMMEL-${n}.md`), issue(n, st, cat, ["v1.1.2"], `Closed case ${n}`, [], "", res));
  put(20, "Closed", "Done", "Done");
  put(21, "wont do", "Done", null);
  put(22, "Done", "Done", "Wont Do");
  put(23, "Done", "Done", "Duplicate");
  put(24, "Done", "Done", "Fixed");
  put(25, "Done", "Done", null);
  const r = read(s);
  const t = byKey(r);
  expect([20, 21, 22, 23].map((k) => t[k].b)).toEqual(["wont", "wont", "wont", "wont"]);
  expect([24, 25].map((k) => t[k].b)).toEqual(["done", "done"]);
  expect(r.versions[1].counts.done).toBe(2);
  expect(r.versions[1].counts.wont).toBe(4);
});

test("release panels: a released version lists its still-open tickets", () => {
  const r = read(station());
  expect(r.versions[0].rel).toBe(true);
  expect(r.versions[0].date).toBe("2026-10-01");
  expect(r.versions[0].open).toEqual([4]);
});

test("drift: live counts from mirror vs plan, and the trend from the tracker's drift log (read, never written)", () => {
  const s = station();
  const r = read(s);
  const t = byKey(r);
  expect(t[6].drift).toBe(1); // planned v1.1.2, Jira says v1.1.3
  expect(t[2].drift).toBe(2); // in a train version, not in the plan
  expect(t[1].drift).toBe(0);
  expect(r.drift.now).toEqual({ drift: 1, unplanned: 3, unthemed: 3 });
  expect(r.drift.trend.map((x) => x[1])).toEqual([4, 1]);
});

test("no plan dir: the kanban still renders from Jira, and the plan says why it is missing", () => {
  const r = read(station(), { planDir: undefined });
  expect(r.state).toBe("ok");
  expect(r.plan.state).toBe("absent");
  expect(r.tickets.every((t) => t.drift === 0)).toBe(true);
});

test("no mirror: absent, with the command that makes one", () => {
  const r = readRoadmap({ mirrorDir: "/nonexistent/mirror", workers: { state: "absent" } });
  expect(r.state).toBe("absent");
  expect(r.reason).toContain("mirror");
});

test("workers join their tickets with the marker and the reason line", () => {
  const t = byKey(read(station()));
  expect(t[1].worker).toEqual({ label: "N1466b", marker: "BLOCKED", reason: "classifier permission hold" });
  expect(t[2].worker).toBeNull();
});

test("worker -> Jira sync: flag a stuck worker with the reason, clear the flag on resume, note READY once", () => {
  const ops = legSync(read(station()).tickets);
  const of = (k: number) => ops.filter((o) => o.k === k);
  expect(of(1).map((o) => o.argv)).toEqual([
    ["edit", "HIMMEL-1", "--add-labels", SYNC_LABEL],
    ["comment", "HIMMEL-1", "[worker-sync] N1466b BLOCKED: classifier permission hold"],
  ]);
  // resume: only the sync flag goes (--remove-labels), every other label stays
  expect(of(5).map((o) => o.argv)).toEqual([["edit", "HIMMEL-5", "--remove-labels", "worker-blocked,leg-blocked"]]);
  // READY was already noted on the ticket: nothing to write
  expect(of(7)).toEqual([]);
  // the planner never moves a status
  expect(ops.some((o) => o.argv.includes("transition"))).toBe(false);
});

test("worker -> Jira sync: a parked worker is stuck under either marker name", () => {
  for (const marker of ["PARKED-USAGE", "PARKED-BANK"]) {
    const ops = legSync([{ k: 1, labels: [], noted: "", worker: { label: "N1", marker, reason: "" } } as any]);
    expect(ops.map((o) => o.argv)[0]).toEqual(["edit", "HIMMEL-1", "--add-labels", SYNC_LABEL]);
  }
});

test("worker -> Jira sync: a ticket flagged and noted under the pre-rename names is not flagged or noted twice", () => {
  const tk = (labels: string[], noted: string, marker: string) => ({ k: 1, labels, noted, worker: { label: "N1", marker, reason: "hold" } }) as any;
  // stuck: the old label and the old comment line already say it
  expect(legSync([tk(["product", "leg-blocked"], "[leg-sync] N1 BLOCKED: hold", "BLOCKED")])).toEqual([]);
  // resume: the old label is cleared too
  expect(legSync([tk(["product", "leg-blocked"], "", "LIVE")]).map((o) => o.argv)).toEqual([["edit", "HIMMEL-1", "--remove-labels", "worker-blocked,leg-blocked"]]);
  // READY was noted under the old prefix: no second comment
  expect(legSync([tk([], "[leg-sync] N1 READY: hold", "READY")])).toEqual([]);
  // the new names are what gets written
  expect(legSync([tk([], "", "BLOCKED")]).map((o) => o.argv)).toEqual([
    ["edit", "HIMMEL-1", "--add-labels", "worker-blocked"],
    ["comment", "HIMMEL-1", "[worker-sync] N1 BLOCKED: hold"],
  ]);
});

test("worker -> Jira sync: a ticket whose only labels are sync labels is cleared with --remove-labels, never an empty --labels", () => {
  const tk = (labels: string[]) => ({ k: 1, labels, noted: "", worker: { label: "N1", marker: "LIVE", reason: "" } }) as any;
  for (const labels of [["worker-blocked"], ["leg-blocked"], ["worker-blocked", "leg-blocked"]]) {
    const argv = legSync([tk(labels)]).map((o) => o.argv);
    expect(argv).toEqual([["edit", "HIMMEL-1", "--remove-labels", "worker-blocked,leg-blocked"]]);
    expect(argv[0]).not.toContain("--labels");
  }
});

test("librarian: stale In Progress, drift, unthemed, released-but-open and duplicate titles, as proposals", () => {
  const l = read(station()).librarian;
  expect(l.staleInProgress.map((p) => p.k)).toEqual([2]);
  expect(l.drift.map((p) => p.k)).toEqual([6]);
  expect(l.drift[0].proposal).toContain("v1.1.2");
  expect(l.unthemed.map((p) => p.k)).toEqual([2, 4, 5]);
  expect(l.releasedOpen.map((p) => p.k)).toEqual([4]);
  expect(l.releasedOpen[0].proposal).toContain("v1.1.2");
  expect(l.duplicates.map((p) => p.keys)).toEqual([[1, 6]]);
  for (const list of Object.values(l)) for (const p of list) expect(p.needsApproval).toBe(true);
});

test("the page renders every section and escapes ticket text", () => {
  const r = read(station());
  r.tickets[0].t = "<script>x</script>";
  const html = renderRoadmap(r, { version: null, theme: null });
  for (const id of ["rm-releases", "rm-drift", "rm-sync", "rm-librarian"]) expect(html).toContain(`id="${id}"`);
  // the long inline board is gone from the overview; each version links to its own drill-in page
  expect(html).not.toContain('id="rm-kanban"');
  expect(html).not.toContain("rm-board");
  expect(html).toContain('href="#/roadmap/v1.1.2"');
  expect(html).not.toContain("<script>x");
  // the boards are where ticket titles render, so escaping is asserted there
  const drill = renderRoadmap(r, { version: null, theme: null, ver: r.versions[r.tickets[0].v].n });
  expect(drill).not.toContain("<script>x");
  expect(drill).toContain("&lt;script&gt;x");
  const board = renderKanban(r, { version: null, theme: null });
  expect(board).not.toContain("<script>x");
  expect(board).toContain("&lt;script&gt;x");
  // a theme filter narrows the drill-in board
  const tracker = renderRoadmap(r, { version: null, theme: r.themes.indexOf("tracker"), ver: "v1.1.2" });
  expect(tracker).not.toContain("Orphaned work");
  expect(renderRoadmap(null, {})).toContain("loading");
  expect(renderRoadmap({ state: "absent", reason: "no Jira mirror" }, {})).toContain("no Jira mirror");
});

// This test pinned the two entries "Roadmap" and "Kanban"; the rail now has the one Board entry and the old
// landings resolve to it (a deliberate change of the pinned assertion, named in the PR body).
test("the rail lists one Board entry after Configure, and Board is a console route; the old landings resolve to it", () => {
  const labels = navLinks({ here: "console", token: TOKEN, current: "board" }).map((l) => l.label);
  expect(labels.slice(labels.indexOf("Fleet"))).toEqual(["Fleet", "Health", "Tool health", "Configure", "Board", "Workflow", "Docs"]);
  expect(parseLanding(`#t=${TOKEN}&page=board`)).toEqual({ token: TOKEN, page: "board" });
  expect(parseLanding(`#t=${TOKEN}&page=roadmap`)).toEqual({ token: TOKEN, page: "board" });
  expect(parseLanding(`#t=${TOKEN}&page=kanban`)).toEqual({ token: TOKEN, page: "board", q: "v=all" });
});

const driftOk = (real: { class: string; key: string; line: string }[] = [], known = 0, transient = 0) => ({
  file: { exists: true, writtenHm: "03:08" }, sdrift: "3:abc", unknown: false, stale: false, mode: "single-user", modeSource: "default",
  real, known: [], transient: [], checkers: [], counts: { real: real.length, known, transient } });
const chainsOk = () => ({ schema: "himmel.chains/1", chains: [{ id: "memory", name: "Memory guard rework", total: 2, done: 1, steps: 2, next: { step: 2, keys: ["HIMMEL-5"] } }],
  tickets: {
    "HIMMEL-1": { key: "HIMMEL-1", state: "in flight", chains: [{ id: "memory", step: 1, steps: 2, state: "in flight" }], badges: ["memory"], more: 0 },
    "HIMMEL-5": { key: "HIMMEL-5", state: "waits on you", chains: [{ id: "memory", step: 2, steps: 2, state: "waits on you" }], badges: ["memory"], more: 0 },
  } });

test("Board: one page with the header, the version strip, the three tabs and the running version's lanes", () => {
  const r = read(station());
  const html = renderBoard(r, { version: null, theme: null }, null);
  expect(html).toContain("<h1>Board</h1>");
  for (const v of ["v1.1.1", "v1.1.2", "v1.1.3"]) expect(html).toContain(`href="#/board?v=${v}"`); // the strip: one tile per version
  expect(html).toMatch(/released 2026-10-01/);
  for (const tab of ["roadmap", "chains", "tidy"]) expect(html).toContain(`href="#/board?tab=${tab}`);
  expect(html).toMatch(/aria-selected="true"[^>]*>Roadmap|>Roadmap[^<]*<\/a>/);
  // no version asked: the running version (v1.1.2) is the board
  for (const col of ["To do", "In progress", "In review", "Done"]) expect(html).toContain(col);
  expect(html).toContain("Roadmap in the ui");
  expect(html).not.toContain("Shipped thing"); // v1.1.1
  // v=all: every version on the lanes; v=<name> narrows to that one
  const all = renderBoard(r, { version: null, theme: null, v: "all" }, null);
  for (const t of ["Roadmap in the ui", "Shipped thing", "Left behind", "Resumed work"]) expect(all).toContain(t);
  expect(renderBoard(r, { version: null, theme: null, v: "v1.1.1" }, null)).not.toContain("Roadmap in the ui");
  // drag and the Sector select keep working on the lanes
  const w = renderBoard(r, { version: null, theme: null, writes: true }, null);
  expect(w).toContain('data-rm-drop="prog"');
  expect(w).toContain('draggable="true" data-rm-card="1"');
  expect(w).toContain('data-rm-theme-key="1"');
  // hide Done and the Sector filter still narrow the lanes
  expect(renderBoard(r, { version: null, theme: null, v: "all", hideDone: true }, null)).not.toContain("Shipped thing");
  expect(renderBoard(r, { version: null, theme: r.themes.indexOf("tracker"), v: "all" }, null)).not.toContain("Orphaned work");
});

test("Board: one filter bar and refresh above every tab, a version tile keeps the tab, an unknown version says so, and the mirror date is escaped", () => {
  const r = read(station());
  for (const tab of ["roadmap", "chains", "tidy"]) {
    const html = renderBoard(r, { version: null, theme: null, tab }, { drift: driftOk(), chains: chainsOk() });
    expect(html.match(/class="rm-bar fields"/g)?.length).toBe(1);
    expect(html).toContain('data-act="refresh-roadmap"');
    expect(html).toContain("data-rm-hide-done");
  }
  const tidy = renderBoard(r, { version: null, theme: null, tab: "tidy" }, { drift: driftOk(), chains: null });
  expect(tidy).toContain('href="#/board?tab=tidy&amp;v=v1.1.1"'); // the tile keeps Tidy up; the Roadmap tab's tiles carry no tab
  expect(renderBoard(r, { version: null, theme: null }, null)).toContain('href="#/board?v=v1.1.1"');
  expect(renderBoard(r, { version: null, theme: null, v: "no-such" }, null)).toContain("no such version in the mirror");
  const evil = renderBoard({ ...r, mirror: { ...r.mirror, newest: "<img src=x onerror=1>" } }, { version: null, theme: null }, null);
  expect(evil).not.toContain("<img src=x");
  expect(evil).toContain("&lt;img src=x");
  // a released version with open tickets is drawn in the failing look, not as muted text
  expect(renderBoard(r, { version: null, theme: null }, null)).toMatch(/class="ro pill fail">\d+ still open: HIMMEL-4/);
});

test("Board: a chain badge keeps the selected version in its link, and has none when no version is selected", () => {
  const r = read(station());
  const withV = renderBoard(r, { version: null, theme: null, v: "all" }, { drift: null, chains: chainsOk() });
  expect(withV).toMatch(/class="rm-chain" href="#\/board\?tab=chains&amp;v=all&amp;at=HIMMEL-1"/);
  expect(renderBoard(r, { version: null, theme: null }, { drift: null, chains: chainsOk() })).toMatch(/class="rm-chain" href="#\/board\?tab=chains&amp;at=HIMMEL-1"/);
});

test("Board: Tidy up covers every version by default and narrows only when the route names one", () => {
  const r = read(station());
  const sections = (html: string) => html.slice(html.indexOf('id="rm-sync"'));
  const dflt = renderBoard(r, { version: null, theme: null, tab: "tidy" }, { drift: driftOk(), chains: null });
  const all = renderBoard(r, { version: null, theme: null, tab: "tidy", v: "all" }, { drift: driftOk(), chains: null });
  expect(sections(dflt)).toBe(sections(all));
  expect(dflt).toContain("is released but this is still open"); // the Released-but-open proposal lives on a version other than the running one
  const named = renderBoard(r, { version: null, theme: null, tab: "tidy", v: "v1.1.3" }, { drift: driftOk(), chains: null });
  expect(sections(named)).not.toBe(sections(all));
});

test("Board: the Tidy up tab carries the Drift, Worker to Jira sync and Librarian sections unchanged", () => {
  const html = renderBoard(read(station()), { version: null, theme: null, tab: "tidy", v: "all" }, { drift: driftOk(), chains: null });
  for (const id of ["rm-drift", "rm-sync", "rm-librarian"]) expect(html).toContain(`id="${id}"`);
  expect(html).toContain("Worker to Jira sync");
  expect(html).toContain("Librarian");
  expect(html).toMatch(/<table class="[^"]*\bdata\b/);
  expect(html).not.toContain("rm-board"); // the lanes belong to the Roadmap tab
});

test("Board: the drift banner and the Tidy up table come from the saved drift run; absent says so, with no made-up count", () => {
  const r = read(station());
  const real = [{ class: "VERSION-DRIFT", key: "HIMMEL-6691", line: "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=jira release request v1.1.3" }];
  const banner = renderBoard(r, { version: null, theme: null }, { drift: driftOk(real, 4, 1), chains: null });
  expect(banner).toContain("1 drift row");
  expect(banner).toContain("4 known checker bug");
  expect(banner).toContain("1 transient");
  expect(banner).toContain("single-user");
  const tidy = renderBoard(r, { version: null, theme: null, tab: "tidy" }, { drift: driftOk(real), chains: null });
  expect(tidy).toContain("VERSION-DRIFT");
  expect(tidy).toContain("HIMMEL-6691");
  expect(tidy).toContain("release-manager");
  expect(tidy).toContain("jira release request v1.1.3");
  for (const extras of [null, { drift: { state: "absent", reason: "no saved drift run configured" }, chains: null }]) {
    const none = renderBoard(r, { version: null, theme: null }, extras);
    expect(none).toContain("drift: not read");
    expect(none).not.toContain("drift row");
  }
  const stale = renderBoard(r, { version: null, theme: null }, { drift: { ...driftOk(), stale: true }, chains: null });
  expect(stale).toContain("older than");
  for (const bad of [{ ...driftOk(), unknown: true }, { ...driftOk(), file: { exists: false } }]) {
    expect(renderBoard(r, { version: null, theme: null }, { drift: bad, chains: null })).not.toMatch(/\d+ drift</);
  }
});

test("Board: chain badges, the waits-for-you card and the Chains tab come from the chain read; absent shows a notice, never a count", () => {
  const r = read(station());
  const html = renderBoard(r, { version: null, theme: null }, { drift: null, chains: chainsOk() });
  expect(html).toContain("memory 1/2");
  expect(html).toContain("in flight");
  expect(html).toContain('href="#/board?tab=chains&amp;at=HIMMEL-1"');
  expect(html).toContain("1 waits for you");
  const chains = renderBoard(r, { version: null, theme: null, tab: "chains" }, { drift: null, chains: chainsOk() });
  expect(chains).toContain("Memory guard rework");
  expect(chains).toContain("1/2");
  expect(chains).toContain('id="cn-HIMMEL-1"');
  for (const extras of [null, { drift: null, chains: { state: "absent", reason: "no chain registry (HIMMEL_CHAIN_REGISTRY is not set)" } }]) {
    const none = renderBoard(r, { version: null, theme: null }, extras);
    expect(none).not.toContain("rm-chain");
    expect(none).not.toMatch(/\d+ waits? for you/);
    expect(none).toContain("waits for you: not read");
    expect(renderBoard(r, { version: null, theme: null, tab: "chains" }, extras)).toContain("no chain registry");
  }
  // the Chain filter narrows the lanes to one chain's tickets
  const one = renderBoard(r, { version: null, theme: null, chain: "memory" }, { drift: null, chains: chainsOk() });
  expect(one).toContain("Roadmap in the ui"); // HIMMEL-1
  expect(one).not.toContain("Orphaned work"); // HIMMEL-2, in no chain
});

test("Board: loading, no tracker, unavailable and GitHub read-only states, and ticket text is escaped", () => {
  const r = read(station());
  r.tickets[0].t = "<script>x</script>";
  const html = renderBoard(r, { version: null, theme: null, v: "all" }, null);
  expect(html).not.toContain("<script>x");
  expect(html).toContain("&lt;script&gt;x");
  expect(renderBoard(null, {}, null)).toContain("<h1>Board</h1>");
  expect(renderBoard(null, {}, null)).toContain("loading");
  expect(renderBoard({ state: "absent", reason: "no Jira mirror" }, {}, null)).toContain("no Jira mirror");
  const none = renderBoard({ ...r, source: "none" }, {}, null);
  expect(none).toContain("No tracker is configured");
  expect(none).toContain("this is not an empty board");
  const gh = renderBoard({ ...r, source: "github" }, { writes: true, v: "all" }, null);
  expect(gh).toContain("read-only");
  expect(gh).not.toContain("draggable");
});

test("#/roadmap/<version>: one version's board, four status columns, ticket links, the other versions absent", () => {
  const r = read(station());
  const html = renderRoadmap(r, { version: null, theme: null, ver: "v1.1.2" });
  expect(html).toContain("v1.1.2");
  for (const col of ["To do", "In progress", "In review", "Done"]) expect(html).toContain(col);
  expect(html).toContain("Roadmap in the ui"); // HIMMEL-1, v1.1.2
  expect(html).toContain("Resumed work");      // HIMMEL-5, v1.1.2
  expect(html).not.toContain("Shipped thing"); // HIMMEL-3, v1.1.1
  expect(html).not.toContain("Left behind");   // HIMMEL-4, v1.1.1
  expect(html).toContain('href="#/roadmap"');  // back to the overview
  expect(html).not.toContain('id="rm-sync"');  // the overview's panels do not repeat here
  expect(html).toContain("<b>HIMMEL-1</b>");
  expect(html).toContain("classifier permission hold"); // the worker marker rides the card
  // an unknown version says so instead of drawing an empty board
  const none = renderRoadmap(r, { version: null, theme: null, ver: "v9.9.9" });
  expect(none).toContain("v9.9.9");
  expect(none).toContain("no such version");
});

test("#/kanban: every version's tickets on one board, no version filter, Done hideable", () => {
  const r = read(station());
  const all = renderKanban(r, { version: null, theme: null, hideDone: false });
  for (const t of ["Roadmap in the ui", "Shipped thing", "Left behind", "Resumed work", "Roadmap in the UI!"]) expect(all).toContain(t);
  expect(all).not.toContain('data-rm-filter="version"');
  expect(all).toContain('data-rm-filter="theme"');
  const hidden = renderKanban(r, { version: null, theme: null, hideDone: true });
  expect(hidden).not.toContain("Shipped thing");
  expect(hidden).toContain("Left behind");
  // the theme filter still narrows it
  expect(renderKanban(r, { version: null, theme: r.themes.indexOf("tracker"), hideDone: false })).not.toContain("Orphaned work");
});

// Tickets group by the mirror's `sector:` line; a theme- label is the fallback, "no sector" the bucket for neither.
test("a ticket with a sector and no theme label groups under its Sector; the old theme label is the fallback", () => {
  const d = mkdtempSync(join(tmpdir(), "roadmap-sector-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const mirror = join(d, "m");
  mkdirSync(mirror);
  const put = (n: number, sector: string | null, labels: string[]) => writeFileSync(join(mirror, `HIMMEL-${n}.md`),
    ["---", `key: "HIMMEL-${n}"`, `status: "To Do"`, `statusCategory: "To Do"`, `labels: ${JSON.stringify(labels)}`, `fixVersions: ["v1.1.3"]`,
      `updated: "2026-10-09T10:00:00.000+0000"`, `sector: ${JSON.stringify(sector)}`, "---", "", `# HIMMEL-${n}: t${n}`, ""].join("\n"));
  put(1, "Visibility", []);
  put(2, "Visibility", ["theme-old"]); // the sector beats the retired label
  put(3, null, ["theme-old"]);
  put(4, null, []);
  writeFileSync(join(d, "m.versions.tsv"), "v1.1.3\tfalse\t\n");
  const r = readRoadmap({ mirrorDir: mirror, workers: { state: "absent" } as never });
  expect(Object.fromEntries(r.tickets.map((t) => [t.k, r.themes[t.theme]]))).toEqual({ 1: "Visibility", 2: "Visibility", 3: "old", 4: "(no sector)" });
  expect(r.themes).not.toContain("(no theme)");
  expect(r.librarian.unthemed.map((p) => p.k)).toEqual([4]);
  expect(r.librarian.unthemed[0].proposal).toContain("--sector");
});

test("a GitHub issue with no theme gets the plan proposal, not a Jira edit of the same number", () => {
  const r = readRoadmap({ mirrorDir: "", github: [{ number: 7, title: "t", state: "OPEN", labels: [], milestone: null }], workers: { state: "absent" } });
  expect(r.librarian.unthemed.map((p) => p.k)).toEqual([7]);
  expect(r.librarian.unthemed[0].proposal).not.toContain("jira edit");
});

test("kanban pages: an empty mirror shows the empty state, not a blank board", () => {
  const r = readRoadmap({ mirrorDir: "/nonexistent/mirror", workers: { state: "absent" } });
  expect(renderKanban(r, { hideDone: false })).toContain("no Jira mirror");
  expect(renderRoadmap(r, { ver: "v1.1.2" })).toContain("no Jira mirror");
  expect(renderKanban(null, {})).toContain("loading");
  const none = { ...read(station()), tickets: [] };
  expect(renderKanban(none, { hideDone: false })).toContain("No tickets");
});

test("GET /api/roadmap: token-gated, GET-only, served live from the mirror the env names", async () => {
  const s = station();
  const home = join(s.d, "home"); mkdirSync(home);
  const srv = startServer({
    port: 0, token: TOKEN, legsScript: join(s.d, "no-workers.sh"),
    env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_ROADMAP_PLAN_DIR: s.plan, HIMMEL_ROADMAP_DRIFT_LOG: s.drift },
  });
  cleanups.push(() => srv.stop());
  const url = `http://127.0.0.1:${srv.port}/api/roadmap`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r1 = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r1.state).toBe("ok");
  expect(r1.tickets.length).toBe(7);
  // live: a mirror refresh shows on the next read, with no render step
  writeFileSync(join(s.mirror, "HIMMEL-8.md"), issue(8, "To Do", "To Do", ["v1.1.3"], "New ticket"));
  const r2 = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r2.tickets.length).toBe(8);
  expect((await fetch(`http://127.0.0.1:${srv.port}/roadmap.js`)).status).toBe(200);
});

test("local-store items render as cards keyed by their generated LOCAL-<n> id, never as HIMMEL-<n>", () => {
  const local = [
    { id: "LOCAL-1", title: "First", status: "To Do", type: "Task", fix_version: "", epic: "", sector: "" },
    { id: "LOCAL-7", title: "Seventh", status: "In Review", type: "Task", fix_version: "", epic: "LOCAL-1", sector: "" },
  ];
  const r = { ...readRoadmap({ mirrorDir: "", local, workers: { state: "absent" } }), sync: [] };
  expect(r.tickets.map((t) => [t.k, t.id, t.b])).toEqual([[1, "LOCAL-1", "todo"], [7, "LOCAL-7", "rev"]]);
  const html = renderKanban(r, { hideDone: false, writes: true });
  expect(html).toContain("<b>LOCAL-7</b>");
  expect(html).not.toContain("HIMMEL-7");
});

// ---- the Board's No version lane, folded Done column, Jira line per column, find box, and Project, Theme and Only filters ----
const withNoVersion = (s: ReturnType<typeof station>) => { writeFileSync(join(s.mirror, "HIMMEL-8.md"), issue(8, "To Do", "To Do", [], "Loose ticket")); return s; };
// the columns of the Board's version lanes (before the No version lane): [bucket, the number in the heading, the cards drawn, the Jira line]
const cols = (html: string) => {
  const main = html.split('id="rm-nv"')[0], parts = main.split('data-rm-col="').slice(1);
  return parts.map((p) => [p.slice(0, p.indexOf('"')), Number(/class="ro rm-n">(\d+)</.exec(p)?.[1]), (p.match(/class="rm-card"/g) || []).length, /class="ro rm-jira">([^<]*)</.exec(p)?.[1]] as const);
};
const optIdx = (html: string, name: string, label: string) => {
  const sel = html.match(new RegExp(`data-rm-filter="${name}">([\\s\\S]*?)</select>`))![1];
  return Number([...sel.matchAll(/<option value="(\d*)"[^>]*>([^<]*)</g)].find((x) => x[2].startsWith(label))![1]);
};
const board = (r: ReturnType<typeof readRoadmap>, ui: Record<string, unknown> = {}, extras: unknown = null) => renderBoard(r, { version: null, theme: null, v: "all", ...ui }, extras);

test("a ticket with no fixVersion stays in the read, marked, and no version counts it; a versioned ticket is not marked", () => {
  const r = read(withNoVersion(station()));
  const t = byKey(r);
  expect(t[8].noVersion).toBe(true);
  expect(t[8].v).toBe(-1);
  expect(t[1].noVersion).toBeUndefined();
  expect(r.versions[1].counts).toEqual({ todo: 1, prog: 2, rev: 1, ci: 0, done: 0, wont: 0 });
  expect(r.librarian.releasedOpen.some((p) => p.k === 8)).toBe(false);
});

test("open tickets with no fixVersion stay out of the Tidy up counts and lists (no sector, stale In Progress, duplicates); the lane still draws them", () => {
  const s = withNoVersion(station());
  writeFileSync(join(s.mirror, "HIMMEL-9.md"), issue(9, "In Progress", "In Progress", [], "Loose ticket"));
  const before = read(station());
  const r = read(s);
  expect(r.drift.now.unthemed).toBe(before.drift.now.unthemed);
  expect(r.librarian.unthemed.map((p) => p.k)).toEqual(before.librarian.unthemed.map((p) => p.k));
  expect(r.librarian.staleInProgress.map((p) => p.k)).toEqual(before.librarian.staleInProgress.map((p) => p.k));
  expect(r.librarian.duplicates).toEqual(before.librarian.duplicates);
  expect(board(r).split('id="rm-nv"')[1]).toContain("2 active tickets with no fixVersion");
});

test("Board: a ticket with no fixVersion is in the No version lane and in no version's column; a versioned ticket is not in the lane", () => {
  const r = read(withNoVersion(station()));
  for (const v of ["all", "v1.1.2"]) {
    const [main, nv] = board(r, { v }).split('id="rm-nv"');
    expect(nv).toContain("Loose ticket");
    expect(nv).toContain("1 active ticket with no fixVersion");
    expect(nv).not.toContain("Roadmap in the ui"); // negative control: HIMMEL-1 has a fixVersion
    expect(main).not.toContain("Loose ticket");
  }
  expect(board(read(station()))).not.toContain('id="rm-nv"'); // no such ticket, no lane
  expect(renderKanban(r, { version: null, theme: null })).not.toContain("Loose ticket"); // the old pages are unchanged
});

test("Board: Done is a folded column, open while a find is set, and each column's number is the cards drawn with a Jira line that says so", () => {
  const r = read(station());
  const html = board(r);
  expect(html).toMatch(/<details class="rm-col rm-done"(?![^>]*\sopen)[^>]*data-rm-col="done"/);
  const c = cols(html);
  expect(c.map((x) => x[0])).toEqual(["todo", "prog", "rev", "ci", "done"]);
  for (const [, n, cards] of c) expect(n).toBe(cards);
  expect(c.map((x) => x[1])).toEqual([3, 2, 1, 0, 1]);
  expect(c.map((x) => x[3])).toEqual(["Jira 3 matches", "Jira 2 matches", "Jira 1 matches", "Jira 0 matches", "Jira 1 matches"]);
  // a filter narrows the cards and the number, and the Jira line keeps Jira's full count
  const f = cols(board(r, { theme: r.themes.indexOf("tracker") }));
  for (const [, n, cards] of f) expect(n).toBe(cards);
  expect(f[0].slice(1)).toEqual([1, 1, "Jira 3 · 1 shown"]);
  expect(board(r, { find: "shipped" })).toMatch(/<details class="rm-col rm-done"[^>]*\sopen/);
});

test("Board: the find box matches a title or a ticket id, ignoring case, and its text is escaped", () => {
  const r = read(station());
  expect(board(r)).toContain("data-rm-find");
  const shown = (ui: Record<string, unknown>) => cols(board(r, ui)).reduce((a, x) => a + x[2], 0);
  expect(shown({ find: "RESUMED" })).toBe(1);
  expect(board(r, { find: "RESUMED" })).toContain("Resumed work");
  expect(board(r, { find: "himmel-7" })).toContain("Ready work");
  expect(shown({ find: "himmel-7" })).toBe(1);
  expect(shown({ find: "no such ticket" })).toBe(0);
  expect(board(r, { find: '"><img src=x>' })).not.toContain("<img src=x>");
  expect(shown({ find: "  " })).toBe(shown({}));
});

test("Board: the Project, Theme and Only filters narrow the lanes, and are on the Roadmap tab only", () => {
  const r = read(station());
  const moved = { ...r, tickets: r.tickets.map((t) => (t.k === 1 ? { ...t, id: "LOC-1" } : t)) };
  const proj = board(moved);
  expect(proj).toContain('data-rm-filter="project"');
  const p = optIdx(proj, "project", "LOC");
  expect(board(moved, { project: p })).toContain("Roadmap in the ui");
  expect(board(moved, { project: p })).not.toContain("Orphaned work");
  expect(board(moved, { project: optIdx(proj, "project", "HIMMEL") })).not.toContain("Roadmap in the ui");
  // Theme: the plan's theme, apart from the Sector
  expect(r.planThemes).toEqual(["(no theme)", "fleet", "tracker"]);
  const fleet = board(r, { planTheme: optIdx(board(r), "planTheme", "fleet") });
  expect(fleet).toContain("Ready work");
  expect(fleet).not.toContain("Roadmap in the ui");
  // Only: the chain read's states and the plan drift
  const ex = { drift: null, chains: chainsOk() };
  const wait = board(r, { only: optIdx(board(r, {}, ex), "only", "waits on you") }, ex);
  expect(wait).toContain("Resumed work");
  expect(wait).not.toContain("Roadmap in the ui");
  const drifted = board(r, { only: optIdx(board(r), "only", "drift") });
  expect(drifted).toContain("Roadmap in the UI!");
  expect(drifted).not.toContain("Resumed work");
  expect(board(r, { tab: "chains" }, ex)).not.toContain('data-rm-filter="only"');
});
