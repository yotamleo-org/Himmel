// the Roadmap page. GET /api/roadmap reads the Jira mirror, the plan dir and the workers live (no static
// render, no republish); the page draws the kanban by version and theme, the release panels and the drift trend, the
// worker -> Jira sync plan the chief kit writes, and the librarian's ready-to-approve lists. Read-only throughout.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { legSync, readRoadmap, SYNC_LABEL } from "../roadmap";
import { BOARD_REFRESH_MS, boardRefreshDue, driftSince, renderBoard, renderKanban, renderRoadmap, pinsFromSearch, searchWithPins, togglePin } from "../public/roadmap.js";
import { navLinks, parseLanding } from "../public/nav.js";
import { startServer } from "../server";

const K = (n: number) => "HIMMEL-" + n;

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
  expect(labels.slice(labels.indexOf("Fleet"))).toEqual(["Fleet", "Health", "Tool health", "Configure", "Board", "Workflow", "Cost", "Docs"]);
  expect(parseLanding(`#t=${TOKEN}&page=board`)).toEqual({ token: TOKEN, page: "board" });
  expect(parseLanding(`#t=${TOKEN}&page=roadmap`)).toEqual({ token: TOKEN, page: "board" });
  expect(parseLanding(`#t=${TOKEN}&page=kanban`)).toEqual({ token: TOKEN, page: "board", q: "v=all" });
});

const driftOk = (real: { class: string; key: string; line: string }[] = [], known = 0, transient = 0) => ({
  file: { exists: true, writtenHm: "03:08" }, sdrift: "3:abc", unknown: false, stale: false, mode: "single-user", modeSource: "default",
  real, known: [], transient: [], checkers: [], counts: { real: real.length, known, transient } });
// Tidy up (mockup v4 frames 5, 6): the Refresh control in its three states, where a row came from, the mode with its link.
const driftRows = (over: Record<string, unknown> = {}) => ({ ...driftOk([{ class: "VERSION-DRIFT", key: "HIMMEL-6691", line: "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4 | writer=release-manager | fix=none" }]), ...over });
const tidy = (ui: Record<string, unknown>, dr: unknown = driftRows()) => renderBoard(read(station()), { version: null, theme: null, tab: "tidy", ...ui }, { drift: dr });
const cellText = (html: string) => html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

test("Tidy up: Refresh starts nothing on open, marks the kept rows while running, and says why a run failed", () => {
  const saved = tidy({});
  expect(saved).toContain('data-act="drift-refresh"');
  expect(cellText(saved)).toContain("drift: saved run · written 03:08 · sdrift=3:abc");
  const running = tidy({ driftRun: { state: "running", started: "05:44:39" } });
  expect(cellText(running)).toContain("re-running the check · started 05:44:39 · usually about 2 min, at most 3 min 20 s");
  expect(cellText(running)).toContain("from 03:08");
  expect(running).toContain("HIMMEL-6691"); // the saved rows stay on screen
  expect(running).toMatch(/data-act="drift-refresh"[^>]*disabled/);
  const failed = tidy({ driftRun: { state: "failed", reason: "the check said <unknown>" } });
  expect(failed).toContain('role="alert"');
  expect(failed).toContain("the check said &lt;unknown&gt;");
  expect(cellText(failed)).toContain("the saved run from 03:08 is kept");
  const done = cellText(tidy({ driftRun: { state: "done", since: { added: ["UNOWNED HIMMEL-9 x", "VERSION-DRIFT HIMMEL-8 z"], counted: ["VERSION-DRIFT HIMMEL-8 z"], healed: ["WORKER-COMMENT HIMMEL-4 y"], same: 2 } } }));
  expect(done).toContain("drift: re-run · written 03:08");
  expect(done).toContain("new UNOWNED HIMMEL-9 x");
  expect(done).toContain("new · counted VERSION-DRIFT HIMMEL-8 z");
  for (const part of ["UNOWNED HIMMEL-9 x", "healed", "WORKER-COMMENT HIMMEL-4 y", "same", "2 rows"]) expect(done).toContain(part);
  // a missing or unknown run still offers Refresh, and never a count
  for (const dr of [{ file: { exists: false }, counts: { real: 0, known: 0, transient: 0 } }, driftRows({ unknown: true, sdrift: "unknown" }), { state: "absent", reason: "none found" }]) expect(tidy({}, dr)).toContain('data-act="drift-refresh"');
});

test("Tidy up: the origin column says who moved the ticket, and a read that failed never reads as nobody", () => {
  const row = (h: unknown) => cellText(tidy({ driftOrigins: { [K(6691)]: h } }));
  expect(tidy({})).toContain("<th>origin</th>");
  expect(tidy({})).toContain('colspan="6"');
  const ev = (who: string, himmel?: boolean) => ({ at: "2026-10-01T10:00", who, from: "To Do", to: "Done", ...(himmel ? { himmel } : {}) });
  expect(row({ events: [ev("Hima", true), ev("Ana")] })).toContain("moved in Jira by Ana");
  expect(tidy({ driftOrigins: { [K(6691)]: { events: [ev("Ana <x>")] } } })).toContain("Ana &lt;x&gt;");
  const mine = row({ events: [ev("Ana"), ev("Hima", true)] }); // the newest move decides
  expect(mine).not.toContain("moved in Jira by");
  expect(mine).toMatch(/himmel(&#39;|')s Jira account/);
  expect(mine).toContain("shared"); // a person on the same login reads the same
  expect(row({ error: "history unavailable" })).toContain("origin not read");
  expect(row({ events: [] })).toContain("no status move");
  expect(cellText(tidy({}))).toContain("reading");
});

test("driftSince: what a re-run added, healed and kept, by the row's text", () => {
  const rows = (...l: string[]) => ({ ...driftOk(), real: l.map((line) => ({ class: "X", key: "K", line: `${line} | writer=a | fix=b` })) });
  expect(driftSince(rows("a", "b"), rows("b", "c"))).toEqual({ from: "03:08", added: ["c"], counted: ["c"], healed: ["a"], same: 1 });
  expect(driftSince(rows(), { ...rows(), known: [{ class: "X", key: "K", line: "k | writer=a | fix=b" }] }).counted).toEqual([]);
});

test("Tidy up: the mode shows read-only and links to the Team mode switch on Configure", () => {
  const off = tidy({});
  expect(off).toContain('href="#/config?tile=tracker"');
  expect(cellText(off)).toContain("team mode is off");
  expect(cellText(off)).toContain("a real drift = a himmel bug");
  const on = cellText(tidy({}, driftRows({ mode: "team" })));
  expect(on).toContain("team mode is on");
  expect(on).toContain("ordinary tidy-up");
});

test("Board lanes: a card with a known-checker-bug row carries the tag naming the checker, in words; a card without has none", () => {
  const r = read(station());
  const t = r.tickets.find((x: { v: number; b: string }) => x.v === r.cur && x.b !== "done")!;
  const key = t.id ?? `HIMMEL-${t.k}`;
  const dr = { ...driftOk(), known: [{ class: "UNOWNED", key, line: `UNOWNED ${key} x`, checker: "HIMMEL-7980", checkerStatus: "In Progress" }], counts: { real: 0, known: 1, transient: 0 } };
  const html = renderBoard(r, { version: null, theme: null }, { drift: dr });
  expect(cellText(html)).toContain("≠ checker bug HIMMEL-7980");
  expect((html.match(/rm-kb/g) || []).length).toBe(1);
  expect(renderBoard(r, { version: null, theme: null }, { drift: driftOk() })).not.toContain("rm-kb");
});

const chainsOk = () => ({ schema: "himmel.chains/1", chains: [{ id: "memory", name: "Memory guard rework", total: 2, done: 1, steps: 2, next: { step: 2, keys: ["HIMMEL-5"] } }],
  tickets: {
    [K(1)]: { key: K(1), state: "in flight", chains: [{ id: "memory", step: 1, steps: 2, state: "in flight" }], badges: ["memory"], more: 0 },
    [K(5)]: { key: K(5), state: "waits on you", chains: [{ id: "memory", step: 2, steps: 2, state: "waits on you" }], badges: ["memory"], more: 0 },
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
  for (const col of ["To do", "In progress", "Review / CI", "Done"]) expect(html).toContain(col);
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
    // 9488: the Chains tab has its own aside (refresh, no lane filters); the other tabs keep the one bar
    expect(html.match(/class="rm-bar fields"/g)?.length).toBe(tab === "chains" ? undefined : 1);
    expect(html).toContain('data-act="refresh-roadmap"');
    expect(html.includes("data-rm-hide-done")).toBe(tab !== "chains");
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
  expect(html).toContain("memory step 1 of 2");
  expect(html).toContain("in flight");
  expect(html).toContain('href="#/board?tab=chains&amp;at=HIMMEL-1"');
  expect(html).toContain("1 waits for you");
  const chains = renderBoard(r, { version: null, theme: null, tab: "chains" }, { drift: null, chains: chainsOk() });
  expect(chains).toContain("Memory guard rework");
  expect(chains).toContain("1 of 2 tickets done");
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
  expect(one).toContain("Roadmap in the ui"); // ticket 1
  expect(one).not.toContain("Orphaned work"); // ticket 2, in no chain
});

test("Board: a Waiting on you section above the lanes lists each ticket that waits on you, from the chain read alone", () => {
  const r = read(station());
  const ch = chainsOk();
  ch.tickets[K(5)].title = "Decide <b>the</b> guard rework";
  const html = renderBoard(r, { version: null, theme: null }, { drift: null, chains: ch });
  const sec = html.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)![0];
  expect(sec).toContain("Waiting on you");
  expect(sec).toContain('href="#/board?tab=chains&amp;at=HIMMEL-5"'); // the key opens its chain
  expect(sec).toContain("Decide &lt;b&gt;the&lt;/b&gt; guard rework"); // title, escaped
  expect(sec).toContain("memory 2/2"); // the chain and step it waits at
  expect(sec).not.toContain("HIMMEL-1"); // an in-flight ticket is not listed
  expect(html.indexOf('id="rm-waiting"')).toBeLessThan(html.indexOf('id="rm-lanes"')); // above the lanes
  // nothing waits, no chain read, or another tab: no section (the "0 wait for you" link beside the tabs carries the count)
  ch.tickets[K(5)].state = "in flight";
  const none = renderBoard(r, { version: null, theme: null }, { drift: null, chains: ch });
  expect(none).not.toContain("rm-waiting");
  expect(none).toContain("0 wait for you");
  for (const extras of [null, { drift: null, chains: { state: "absent", reason: "no chain registry" } }]) expect(renderBoard(r, { version: null, theme: null }, extras)).not.toContain("rm-waiting");
  expect(renderBoard(r, { version: null, theme: null, tab: "chains" }, { drift: null, chains: chainsOk() })).not.toContain("rm-waiting");
});

test("Board: Waiting on you also lists open tickets carrying an operator label, in any version and in no chain, as the tracker does", () => {
  const r = read(station());
  const label = (k: number, l: string) => { r.tickets.find((t) => t.k === k)!.labels = [l]; };
  label(4, "operator-gated"); // To Do in v1.1.1, in no chain
  label(3, "operator"); // Done: nothing is owed
  label(1, "product"); // not an operator label
  const ui = { version: null, theme: null }; // the running version is selected: the section still spans every version
  const html = renderBoard(r, ui, { drift: null, chains: chainsOk() });
  const sec = html.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)![0];
  expect(sec).toContain("HIMMEL-4");
  expect(sec).toContain("Left behind");
  expect(sec).toContain("operator-gated");
  expect(sec).toContain("HIMMEL-5"); // the chain hold is still there
  expect(sec).not.toContain("HIMMEL-3");
  expect(sec).not.toContain("HIMMEL-1");
  expect(sec).toContain("across every version");
  expect(sec).not.toContain("at=HIMMEL-4"); // the Chains tab does not hold it: plain key, no link to "not in a chain"
  expect(sec).toContain("at=HIMMEL-5");
  expect(html).toContain("2 wait for you");
  // a ticket that is both labelled and on hold is one row
  label(5, "operator-decision");
  expect(renderBoard(r, ui, { drift: null, chains: chainsOk() }).match(/<li>/g)).toHaveLength(2);
  // no chain read: the labelled tickets still show, and the section says the holds were not read, never that nobody waits
  const noChain = renderBoard(r, ui, { drift: null, chains: { state: "absent", reason: "no chain registry" } });
  expect(noChain).toContain("chain holds not read");
  expect(noChain).toContain("HIMMEL-4");
  expect(noChain).not.toMatch(/\b0 wait for you/);
  // a chain read that carries no chains at all is not usable either
  expect(renderBoard(r, ui, { drift: null, chains: { chains: [], tickets: undefined } })).toContain("chain holds not read");
});

test("Board: Waiting on you lists the open operator-labelled tickets with no version once the No version read is in, and counts them", () => {
  const s = station();
  writeFileSync(join(s.mirror, "HIMMEL-8.md"), issue(8, "To Do", "To Do", [], "Pick the colour", ["operator-decision"]));
  writeFileSync(join(s.mirror, "HIMMEL-9.md"), issue(9, "Done", "Done", [], "Settled already", ["operator"]));
  writeFileSync(join(s.mirror, "HIMMEL-10.md"), issue(10, "To Do", "To Do", [], "Loose, nobody owed", ["product"]));
  const r = read(s), nv = nvRead(s), ui = { version: null, theme: null };
  const quiet = { drift: null, chains: { chains: [], tickets: {}, version: "v1.1.2" } };
  const link = (html: string) => html.match(/<div class="rm-link">[\s\S]*?<\/div>/)![0];
  // before the No version read arrives: nothing listed, the count says it is not counting them
  expect(renderBoard(r, ui, quiet)).not.toContain("rm-waiting");
  expect(link(renderBoard(r, ui, quiet))).toContain("3 not counted");
  // with it: the one open labelled ticket is a row, linked to the No version tab, tagged "no version", and the count includes it
  const html = renderBoard(r, { ...ui, nv }, quiet);
  const sec = html.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)![0];
  expect(sec).toContain("HIMMEL-8");
  expect(sec).toContain("Pick the colour");
  expect(sec).toContain("operator-decision");
  expect(sec).toContain("no version");
  expect(sec).toContain('href="#/board?tab=nv"');
  expect(sec).not.toContain("HIMMEL-9"); // Done: nothing is owed
  expect(sec).not.toContain("HIMMEL-10"); // no operator label
  expect(link(html)).toContain("1 waits for you");
  expect(link(html)).not.toContain("not counted");
  // a failed No version read leaves the old words in place, never a plain 0
  expect(link(renderBoard(r, { ...ui, nv: { state: "error", reason: "roadmap failed (500)" } }, quiet))).toContain("3 not counted");
});

test("Board: the waits-for-you count names its scope and points at the No version tab while tickets there are unread", () => {
  const r = read(station());
  const ui = { version: null, theme: null };
  const quiet = { drift: null, chains: { chains: [], tickets: {}, version: "v1.1.2" } }; // a chain read that holds nobody
  const link = (html: string) => html.match(/<div class="rm-link">[\s\S]*?<\/div>/)![0];
  // nobody waits among the versioned tickets, three tickets have no version: the default read does not carry them, so the count must not read as a plain 0
  r.noVersionCount = 3;
  const none = link(renderBoard(r, ui, quiet));
  expect(none).toContain("0 wait for you");
  expect(none).toContain("3 not counted");
  expect(none).toContain('<a href="#/board?tab=nv">no version</a>');
  // with rows it keeps the pointer too: the rows are a count of the versioned tickets only
  r.noVersionCount = 1;
  const some = link(renderBoard(r, ui, { drift: null, chains: chainsOk() }));
  expect(some).toContain("1 not counted");
  expect(some).toContain('<a href="#/board?tab=nv">no version</a>');
  // nothing without a version: a plain 0 is true, and no pointer is drawn
  r.noVersionCount = 0;
  const clean = link(renderBoard(r, ui, quiet));
  expect(clean).toContain("0 wait for you");
  expect(clean).not.toContain("not counted");
  expect(clean).not.toContain("tab=nv");
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
  for (const col of ["To do", "In progress", "Review / CI", "Done"]) expect(html).toContain(col);
  expect(html).toContain("Roadmap in the ui"); // ticket 1, v1.1.2
  expect(html).toContain("Resumed work");      // ticket 5, v1.1.2
  expect(html).not.toContain("Shipped thing"); // ticket 3, v1.1.1
  expect(html).not.toContain("Left behind");   // ticket 4, v1.1.1
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
  const srv = startServer({ onIdle: () => {},
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

test("GET /api/roadmap: the default payload has no ticket with no fixVersion; ?nv=1 serves those tickets only, with no sync row even for a ticket that has a worker", async () => {
  const s = withNoVersion(station());
  const home = join(s.d, "home"); mkdirSync(home);
  // a BLOCKED worker on the no-version ticket: planned over its ticket, legSync would flag it in Jira
  const doc = join(s.d, "HIMMEL-8-N9-loose-RESUME.md");
  writeFileSync(doc, "## Results\n- 04:00 BLOCKED — stuck on the loose ticket\n");
  const legs = join(s.d, "workers-8.sh");
  writeFileSync(legs, `#!/usr/bin/env bash\nprintf '%s' '${JSON.stringify({ manifest: join(s.d, "x.fleet.json"), workers: [{ doc, status: "BLOCKED" }] })}'\n`);
  const srv = startServer({ onIdle: () => {},
    port: 0, token: TOKEN, legsScript: legs,
    env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_ROADMAP_PLAN_DIR: s.plan, HIMMEL_ROADMAP_DRIFT_LOG: s.drift },
  });
  cleanups.push(() => srv.stop());
  const get = async (q: string) => (await fetch(`http://127.0.0.1:${srv.port}/api/roadmap${q}`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  const d = await get(""), n = await get("?nv=1");
  expect(d.tickets.length).toBe(7);
  expect(d.noVersionCount).toBe(1);
  expect(JSON.stringify(d)).not.toContain("Loose ticket");
  expect(n.tickets.map((t: { k: number }) => t.k)).toEqual([8]);
  expect(n.tickets[0].worker).toMatchObject({ label: "N9", marker: "BLOCKED" }); // the worker is on the ticket, so legSync over it is not empty:
  expect(legSync(n.tickets).length).toBeGreaterThan(0);
  expect(n.sync).toEqual([]); // the nv read plans nothing; a sync planned over it would flag ticket 8 in Jira
  expect(d.sync.some((o: { k: number }) => o.k === 8)).toBe(false); // and the default read's plan never names it
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

// ---- the Board's folded Done column, Jira line per column, find box, and Project, Theme and Only filters ----
const withNoVersion = (s: ReturnType<typeof station>) => { writeFileSync(join(s.mirror, "HIMMEL-8.md"), issue(8, "To Do", "To Do", [], "Loose ticket")); return s; };
// the columns of a Board tab: [bucket, the number in the heading, the cards drawn, the Jira line]
const cols = (html: string) => {
  const parts = html.split('data-rm-col="').slice(1);
  return parts.map((p) => [p.slice(0, p.indexOf('"')), Number(/class="ro rm-n">(\d+)</.exec(p)?.[1]), (p.match(/class="rm-card"/g) || []).length, /class="ro rm-jira">([^<]*)</.exec(p)?.[1]] as const);
};
const optIdx = (html: string, name: string, label: string) => {
  const sel = html.match(new RegExp(`data-rm-filter="${name}">([\\s\\S]*?)</select>`))![1];
  return Number([...sel.matchAll(/<option value="(\d*)"[^>]*>([^<]*)</g)].find((x) => x[2].startsWith(label))![1]);
};
const board = (r: ReturnType<typeof readRoadmap>, ui: Record<string, unknown> = {}, extras: unknown = null) => renderBoard(r, { version: null, theme: null, v: "all", ...ui }, extras);

// ---- the No version board: its tickets are left out of the default read and fetched only when that board opens ----
const withNv = (s: ReturnType<typeof station>) => { // adds ticket 9, In Progress with no fixVersion, to withNoVersion's ticket 8
  writeFileSync(join(s.mirror, "HIMMEL-9.md"), issue(9, "In Progress", "In Progress", [], "Loose ticket"));
  return s;
};
const nvRead = (s: ReturnType<typeof station>) => read(s, { noVersion: true });

test("the default read carries no ticket with no fixVersion, only their count, and changes no version, count or Tidy up list", () => {
  const before = read(station());
  const r = read(withNv(withNoVersion(station())));
  expect(r.tickets.map((t) => t.k)).toEqual(before.tickets.map((t) => t.k));
  expect(JSON.stringify(r)).not.toContain("Loose ticket");
  expect(r.noVersionCount).toBe(2);
  expect(before.noVersionCount).toBe(0);
  expect(r.versions).toEqual(before.versions);
  expect(r.drift).toEqual(before.drift);
  expect(r.librarian).toEqual(before.librarian);
  expect([r.cur, r.next]).toEqual([before.cur, before.next]);
});

test("the No version read carries those tickets only, marked, and no versioned ticket", () => {
  const r = nvRead(withNv(withNoVersion(station())));
  expect(r.tickets.map((t) => t.k)).toEqual([8, 9]);
  for (const t of r.tickets) { expect(t.noVersion).toBe(true); expect(t.v).toBe(-1); }
  expect(r.noVersionCount).toBe(2);
  expect(JSON.stringify(r)).not.toContain("Roadmap in the ui"); // negative control: ticket 1 has a fixVersion
  expect(r.librarian).toEqual({ staleInProgress: [], drift: [], unthemed: [], releasedOpen: [], duplicates: [] });
  expect(nvRead(station()).tickets).toEqual([]); // nothing without a version: nothing to fetch
});

test("a ticket with no fixVersion that the plan placed reads in both modes without throwing, and drifts nowhere", () => {
  const s = withNoVersion(station());
  writeFileSync(join(s.plan, "stage3", "placement.tsv"), "key\tversion\tlayer\nHIMMEL-1\tv1.1.2\tfeatures\nHIMMEL-8\tv1.1.2\tfeatures\n");
  const r = read(s), n = nvRead(s);
  expect(r.tickets.some((t) => t.k === 8)).toBe(false);
  expect(r.librarian.drift.some((p) => p.k === 8)).toBe(false);
  expect(n.tickets.map((t) => [t.k, t.drift])).toEqual([[8, 0]]);
  expect(n.drift.now).toEqual({ drift: 0, unplanned: 0, unthemed: 0 });
});

test("Board: the default page has no No version lane and no ticket for it; its tab says how many, and fetches nothing", () => {
  const r = read(withNoVersion(station()));
  const html = board(r);
  expect(html).not.toContain('id="rm-nv"');
  expect(html).not.toContain("Loose ticket");
  expect(html).toMatch(/>No version <span class="ro">1 ticket<\/span><\/a>/);
  expect(board(read(station()))).not.toContain(">No version"); // no such ticket, no tab
  // the tab with nothing read yet says so, and draws nothing even from a default read that held those tickets
  const wait = board(r, { tab: "nv" });
  expect(wait).toContain("loading");
  const leaked = { ...r, tickets: [...r.tickets, ...nvRead(withNoVersion(station())).tickets] };
  expect(board(leaked)).toContain("Loose ticket"); // the version board draws whatever the default read carries, so this proves the leak is real
  expect(board(leaked, { tab: "nv" })).not.toContain("Loose ticket");
  expect(renderKanban(r, { version: null, theme: null })).not.toContain("Loose ticket"); // the old pages are unchanged
});

test("Board: the No version tab draws the fetched tickets in columns with a Jira line, and finds and filters work there; a versioned ticket is not drawn", () => {
  const s = withNv(withNoVersion(station()));
  const r = read(s), nv = nvRead(s);
  const html = board(r, { tab: "nv", nv });
  expect(html).toContain('id="rm-nv"');
  expect(html).toContain("Loose ticket");
  expect(html).not.toContain("Roadmap in the ui");
  const c = cols(html);
  expect(c.map((x) => [x[0], x[1], x[2], x[3]])).toEqual([["todo", 1, 1, "Jira 1 matches"], ["prog", 1, 1, "Jira 1 matches"], ["rev", 0, 0, "Jira 0 matches"], ["done", 0, 0, "Jira 0 matches"]]);
  expect(html).toContain("data-rm-find");
  const found = board(r, { tab: "nv", nv, find: "himmel-9" });
  expect(cols(found).reduce((a, x) => a + x[2], 0)).toBe(1);
  expect(cols(found).map((x) => x[3])).toEqual(["Jira 1 · 0 shown", "Jira 1 matches", "Jira 0 matches", "Jira 0 matches"]);
  expect(board(r, { tab: "nv", nv, find: "no such ticket" })).toContain("No tickets match");
  expect(board(r, { tab: "nv", nv: { state: "error", reason: "roadmap failed (500)" } })).toContain("roadmap failed (500)");
});

test("Board: the Sector filter on the No version tab is the Sector's name, not the index it has in the default read", () => {
  const s = withNv(withNoVersion(station()));
  const r = read(s), nv = nvRead(s);
  const name = nv.themes[nv.tickets[0].theme], shown = (ui: Record<string, unknown>, p: typeof nv) => cols(board(r, { tab: "nv", nv: p, ...ui })).reduce((a, x) => a + x[2], 0);
  // the second read lists the Sectors in another order, as two reads that completed apart can
  const turned = { ...nv, themes: [...nv.themes].reverse(), tickets: nv.tickets.map((t) => ({ ...t, theme: nv.themes.length - 1 - t.theme })) };
  expect(turned.themes[turned.tickets[0].theme]).toBe(name);
  expect(shown({ theme: r.themes.indexOf(name) }, turned)).toBe(2); // RED: compared as an index it shows none
  expect(shown({ theme: r.themes.indexOf(name) }, nv)).toBe(2);
  expect(shown({ theme: r.themes.indexOf("tracker") }, turned)).toBe(0); // negative control: a Sector they are not in
  expect(shown({ theme: 99 }, turned)).toBe(0); // a Sector the default read no longer lists matches none
});

test("Board: Done is a folded column, open while a find is set, and each column's number is the cards drawn with a Jira line that says so", () => {
  const r = read(station());
  const html = board(r);
  expect(html).toMatch(/<details class="rm-col rm-done"(?![^>]*\sopen)[^>]*data-rm-col="done"/);
  const c = cols(html);
  expect(c.map((x) => x[0])).toEqual(["todo", "prog", "rev", "done"]);
  for (const [, n, cards] of c) expect(n).toBe(cards);
  expect(c.map((x) => x[1])).toEqual([3, 2, 1, 1]);
  expect(c.map((x) => x[3])).toEqual(["Jira 3 matches", "Jira 2 matches", "Jira 1 matches", "Jira 1 matches"]);
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

test("Board: the Project, Theme and Only filters narrow the lanes, and are on the Roadmap and No version tabs only", () => {
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

// ---- the Board covers every project with a mirror under the mirror root; --project / HIMMEL_BOARD_PROJECTS narrow it ----
const issueOf = (key: string, n: number, fv: string[], title: string) => issue(n, "To Do", "To Do", fv, title).replaceAll(`HIMMEL-${n}`, `${key}-${n}`);
// a HOME with two mirrors (HIMMEL, SALUS) whose tickets share the number 1 and the version name v1.1.2
function twoMirrors() {
  const d = mkdtempSync(join(tmpdir(), "roadmap-multi-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const root = join(d, "home", ".himmel", "state", "jira-mirror");
  for (const [key, title] of [["HIMMEL", "himmel work"], ["SALUS", "salus work"]]) {
    mkdirSync(join(root, key), { recursive: true });
    writeFileSync(join(root, key, `${key}-1.md`), issueOf(key, 1, ["v1.1.2"], title));
    writeFileSync(join(root, `${key}.versions.tsv`), "v1.1.2\tfalse\t\n");
  }
  return { d, home: join(d, "home"), root };
}
function serveBoard(home: string, extraEnv: Record<string, string> = {}, projects?: string[]) {
  const srv = startServer({ onIdle: () => {},
    port: 0, token: TOKEN, legsScript: join(home, "no-workers.sh"), ...(projects ? { projects } : {}),
    env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000", ...extraEnv },
  });
  cleanups.push(() => srv.stop());
  return async () => (await fetch(`http://127.0.0.1:${srv.port}/api/roadmap`, { headers: { "X-Himmel-Token": TOKEN } })).json();
}

test("5494 row 1: two mirror dirs give cards from both projects by default, each with its project key", async () => {
  const m = twoMirrors();
  const r = await serveBoard(m.home)();
  expect(r.state).toBe("ok");
  expect(r.projects).toEqual(["HIMMEL", "SALUS"]);
  expect(r.tickets.map((t: { id: string; project: string }) => [t.id, t.project])).toEqual([["HIMMEL-1", "HIMMEL"], ["SALUS-1", "SALUS"]]);
});

test("5494 row 2: --project (the startServer option) and HIMMEL_BOARD_PROJECTS (its env twin) narrow the Board", async () => {
  const m = twoMirrors();
  const flag = await serveBoard(m.home, {}, ["SALUS"])();
  expect(flag.projects).toEqual(["SALUS"]);
  expect(flag.tickets.map((t: { id: string }) => t.id)).toEqual(["SALUS-1"]);
  const env = await serveBoard(m.home, { HIMMEL_BOARD_PROJECTS: "HIMMEL" })();
  expect(env.tickets.map((t: { id: string }) => t.id)).toEqual(["HIMMEL-1"]);
});

test("5494 row 3: a version name present in both projects stays two entries, each ticket in its own project's", async () => {
  const m = twoMirrors();
  const r = await serveBoard(m.home)();
  expect(r.versions.length).toBe(2);
  expect(r.versions.map((v: { project: string }) => v.project)).toEqual(["HIMMEL", "SALUS"]);
  expect(new Set(r.versions.map((v: { n: string }) => v.n)).size).toBe(2); // the shown names differ, so the strip and the plan can tell them apart
  const own = r.tickets.map((t: { id: string; v: number }) => [t.id, r.versions[t.v].project]);
  expect(own).toEqual([["HIMMEL-1", "HIMMEL"], ["SALUS-1", "SALUS"]]);
});

test("5494: with one mirror the version names stay unqualified, as before", async () => {
  const m = twoMirrors();
  const r = await serveBoard(m.home, { HIMMEL_BOARD_PROJECTS: "HIMMEL" })();
  expect(r.versions.map((v: { n: string }) => v.n)).toEqual(["v1.1.2"]);
});

test("5494: the page draws each card with its own project's key, and two same-number cards do not collide", async () => {
  const m = twoMirrors();
  const r = await serveBoard(m.home)();
  const html = renderBoard(r, { v: "all" }, {});
  expect(html).toContain("<b>HIMMEL-1</b>");
  expect(html).toContain("<b>SALUS-1</b>");
});

test("5494: each project runs its own version, and a Sector select offers only its own project's Sectors", async () => {
  const m = twoMirrors();
  // SALUS's version is released with a ticket still open; HIMMEL's is running
  writeFileSync(join(m.root, "SALUS.versions.tsv"), "v1.1.1\ttrue\t2026-10-01\nv1.1.2\tfalse\t\n");
  writeFileSync(join(m.root, "SALUS", "SALUS-2.md"), issueOf("SALUS", 2, ["v1.1.1"], "left behind"));
  writeFileSync(join(m.root, "HIMMEL", "HIMMEL-1.md"), issueOf("HIMMEL", 1, ["v1.1.2"], "himmel work").replace("labels:", 'sector: "Visibility"\nlabels:'));
  writeFileSync(join(m.root, "SALUS", "SALUS-1.md"), issueOf("SALUS", 1, ["v1.1.2"], "salus work").replace("labels:", 'sector: "Intake"\nlabels:'));
  const r = await serveBoard(m.home)();
  expect(r.versions.map((v: { n: string; run?: string }) => [v.n, v.run ?? null])).toEqual([["v1.1.2 (HIMMEL)", "running"], ["v1.1.1 (SALUS)", null], ["v1.1.2 (SALUS)", "running"]]);
  expect(r.librarian.releasedOpen[0].proposal).toContain("move to v1.1.2 (SALUS)"); // never HIMMEL's running version
  const html = renderBoard(r, { v: "all", writes: true }, {});
  const select = (id: string) => new RegExp(`aria-label="Sector of ${id}">([\\s\\S]*?)</select>`).exec(html)![1];
  expect(select("SALUS-1")).toContain("Intake");
  expect(select("SALUS-1")).not.toContain("Visibility");
  expect(select("HIMMEL-1")).toContain("Visibility");
  expect(select("HIMMEL-1")).not.toContain("Intake");
  expect(html).toContain('data-rm-theme-key="1" data-rm-project="SALUS"'); // the Sector write names the card's project: two projects share the number
  expect(html).toContain('data-rm-theme-key="1" data-rm-project="HIMMEL"');
});

test("5494: two projects with one ticket number keep their own plan version and plan theme", () => {
  const m = twoMirrors();
  const plan = join(m.d, "plan");
  mkdirSync(join(plan, "stage1"), { recursive: true }); mkdirSync(join(plan, "stage3"), { recursive: true });
  writeFileSync(join(plan, "stage3", "placement.tsv"), "key\tversion\tlayer\nHIMMEL-1\tv1.1.2\tfeatures\nSALUS-1\tv1.1.3\tfeatures\n");
  writeFileSync(join(plan, "stage1", "C01.tsv"), "key\ttheme\nHIMMEL-1\tAlpha\nSALUS-1\tBeta\n");
  const projects = [{ key: "HIMMEL", dir: join(m.root, "HIMMEL") }, { key: "SALUS", dir: join(m.root, "SALUS") }];
  const r = readRoadmap({ mirrorDir: "", projects, planDir: plan, workers: { state: "absent" } as never });
  const by = Object.fromEntries(r.tickets.map((t) => [t.id, t]));
  expect([by["HIMMEL-1"].pv, r.planThemes[by["HIMMEL-1"].pt]]).toEqual(["v1.1.2", "Alpha"]);
  expect([by["SALUS-1"].pv, r.planThemes[by["SALUS-1"].pt]]).toEqual(["v1.1.3", "Beta"]); // a project-blind key would give the SALUS ticket HIMMEL's row
});

test("5494: a card on the No version tab still offers the Sectors its project's versioned tickets use", () => {
  const m = twoMirrors();
  writeFileSync(join(m.root, "SALUS", "SALUS-1.md"), issueOf("SALUS", 1, ["v1.1.2"], "salus work").replace("labels:", 'sector: "Intake"\nlabels:'));
  writeFileSync(join(m.root, "SALUS", "SALUS-3.md"), issueOf("SALUS", 3, [], "loose salus work"));
  const projects = [{ key: "HIMMEL", dir: join(m.root, "HIMMEL") }, { key: "SALUS", dir: join(m.root, "SALUS") }];
  const nv = readRoadmap({ mirrorDir: "", projects, noVersion: true, workers: { state: "absent" } as never });
  expect(nv.tickets.map((t) => t.id)).toEqual(["SALUS-3"]); // only the unversioned ticket is in this read ...
  const html = renderBoard({ ...readRoadmap({ mirrorDir: "", projects, workers: { state: "absent" } as never }) }, { tab: "nv", v: "all", writes: true, nv }, {});
  expect(new RegExp('aria-label="Sector of SALUS-3">([\\s\\S]*?)</select>').exec(html)![1]).toContain("Intake"); // ... yet it can take its project's Sector
});

// ---- 8832: the ticket drawer (mockup v4 frame 3): the card's CLI argv, its stage history, and a board that holds still while it is open ----
const EVENTS = [
  { at: "2026-10-27T09:00:00.000+0000", who: "Bot", from: "To Do", to: "In Progress" },
  { at: "2026-10-28T08:00:00.000+0000", who: "Bot", from: "In Progress", to: "In Review" },
];
const drawerOf = (html: string) => /<aside class="drawer"[\s\S]*?<\/aside>/.exec(html)?.[0] ?? "";

test("8832 drawer: a card opens it, and it shows the card's CLI argv and its stage history", () => {
  const r = read(station());
  const closed = renderBoard(r, { version: null, theme: null, writes: true, v: "all" }, null);
  expect(closed).toContain('data-rm-open="1"'); // every card carries the hook that opens it
  expect(drawerOf(closed)).toBe("");
  const html = renderBoard(r, { version: null, theme: null, writes: true, v: "all", drawer: { k: 1, project: "HIMMEL", history: { events: EVENTS } } }, null);
  const d = drawerOf(html);
  expect(d).toContain('aria-label="Ticket HIMMEL-1"');
  expect(d).toContain("Roadmap in the ui");
  expect(d).toContain("jira transition HIMMEL-1 &quot;To Do&quot;"); // the argv a move to To do runs
  expect(d).not.toContain("transition HIMMEL-1 &quot;In Progress&quot;"); // the card is in progress already: no move there
  expect(d).toContain('jira edit HIMMEL-1 --sector'); // and the Sector write
  expect(d).toContain("To Do → In Progress");
  expect(d).toContain("In Progress → In Review");
  expect(d).toContain("2026-10-27");
  expect(html).toMatch(/class="rm-under" inert/); // the board under the drawer takes no drag, select or key
});

test("8832 drawer: history that did not load says it is unavailable, never an empty history", () => {
  const r = read(station());
  const ui = (history: unknown) => renderBoard(r, { version: null, theme: null, writes: true, v: "all", drawer: { k: 1, project: "HIMMEL", history } }, null);
  expect(drawerOf(ui({ error: "history unavailable" }))).toContain("history unavailable");
  expect(drawerOf(ui({ error: "history unavailable" }))).not.toContain("No status moves");
  expect(drawerOf(ui(null))).toContain("loading");
  expect(drawerOf(ui({ events: [] }))).toContain("No status moves");
});

test("8832 drawer: a card of a second project shows that project's own key in the argv, and escapes ticket text", () => {
  const m = twoMirrors();
  const projects = [{ key: "HIMMEL", dir: join(m.root, "HIMMEL") }, { key: "SALUS", dir: join(m.root, "SALUS") }];
  writeFileSync(join(m.root, "SALUS", "SALUS-1.md"), issueOf("SALUS", 1, ["v1.1.2"], "salus <b>work</b>"));
  const r = readRoadmap({ mirrorDir: "", projects, workers: { state: "absent" } as never });
  const html = renderBoard(r, { version: null, theme: null, v: "all", writes: true, drawer: { k: 1, project: "SALUS", history: { events: [] } } }, {});
  const d = drawerOf(html);
  expect(d).toContain('aria-label="Ticket SALUS-1"');
  expect(d).toContain("jira transition SALUS-1");
  expect(d).not.toContain("HIMMEL-1");
  expect(d).toContain("salus &lt;b&gt;work&lt;/b&gt;");
});

// A local card: the drawer shows the seam's real argv (what applyLocalWrite runs), a Sector named with a command substitution
// is quoted the way the jira() rows quote it, and "wont do" is not offered (tracker_transition exits 2 on it).
const SECTOR = 'a$(id)"><x';
const localDrawer = (history: unknown = null) => {
  const r = read(station());
  const themes = [...r.themes, SECTOR];
  const tickets = r.tickets.map((t) => (t.k === 1 ? { ...t, backend: "local", id: "LOCAL-1", theme: themes.length - 1 } : t));
  return drawerOf(renderBoard({ ...r, themes, tickets } as typeof r, { version: null, theme: null, writes: true, v: "all", drawer: { k: 1, project: "HIMMEL", history } }, null));
};

test("8832 drawer: a local card shows the tracker seam's real calls, quoted, and offers no wont do", () => {
  const d = localDrawer();
  expect(d).toContain("tracker_transition LOCAL-1 &quot;To Do&quot; --allow-back"); // the real write passes --allow-back
  expect(d).not.toContain("tracker_edit"); // no such verb
  expect(d).not.toContain("tracker_transition LOCAL-1 &quot;wont do&quot;"); // the seam exits 2 on it
  expect(d).not.toContain("wont do");
  expect(d).toContain("tracker_sector LOCAL-1 &quot;a\\$(id)\\&quot;&gt;&lt;x&quot;"); // $ and the quote are escaped, so a paste does not run the substitution
  expect(d).not.toContain("tracker_sector LOCAL-1 &quot;a$(id)");
});

test("8832 drawer: the history fields and the copy command are escaped", () => {
  const r = read(station());
  const history = { events: [{ at: "2026-10-27T09:00:00.000+0000", who: "<i>Bot</i>", from: "<b>a</b>", to: "<u>b</u>" }] };
  const d = drawerOf(renderBoard(r, { version: null, theme: null, writes: true, v: "all", drawer: { k: 1, project: "HIMMEL", history } }, null));
  expect(d).toContain("&lt;i&gt;Bot&lt;/i&gt;");
  expect(d).toContain("&lt;b&gt;a&lt;/b&gt; → &lt;u&gt;b&lt;/u&gt;");
  expect(d).not.toMatch(/<(i|b|u)>(Bot|a|b)<\/\1>/);
  expect(localDrawer()).toMatch(/data-cmd="tracker_sector LOCAL-1 &quot;a\\\$\(id\)\\&quot;&gt;&lt;x&quot;"/); // the attribute cannot be broken out of
});

test("8832 drawer: the Done lane stays open while a Done card's drawer is open, so closing it can focus the card", () => {
  const r = read(station());
  const html = (drawer: unknown) => renderBoard(r, { version: null, theme: null, writes: true, v: "all", drawer }, null);
  expect(html(null)).toMatch(/<details class="rm-col rm-done"(?! open)/); // folded by default
  expect(html({ k: 3, project: "HIMMEL", history: null })).toMatch(/<details class="rm-col rm-done" open/); // ticket 3 is Done
  expect(html({ k: 1, project: "HIMMEL", history: null })).toMatch(/<details class="rm-col rm-done"(?! open)/); // another card's drawer leaves it folded
});

// The Chains tab: two linked chains and one blocked ticket, as chain-state.mjs prints them with --version, plus the burn-down board.ts adds.
const linkOf = (on: string, status = "open") => ({ on, kind: "jira-link", source: "jira", added: null, reason: null, owner: null, until: null, clears: `${on} completes`, status, at: null });
const chainsLinked = () => ({ schema: "himmel.chains/1", now: "2026-11-03T08:00:00.000Z", version: "v1.1.3",
  chains: [
    { id: "memory", name: "Memory guard rework", total: 2, done: 1, steps: 2, next: { step: 2, keys: ["HIMMEL-2"] }, across: [{ dir: "holds-up", key: "HIMMEL-6", on: "HIMMEL-2", kind: "jira-link", status: "open", chains: ["ops"] }], log: [] },
    { id: "ops", name: "Ops cleanup", total: 2, done: 0, steps: 1, next: null,
      across: [{ dir: "waits-on", key: "HIMMEL-6", on: "HIMMEL-2", kind: "jira-link", status: "open", chains: ["memory"] }, { dir: "waits-on", key: "HIMMEL-7", on: "HIMMEL-21", kind: "jira-link", status: "open", chains: [] }],
      log: [{ ts: "2026-11-01T09:00:00.000Z", change: "hold", key: "HIMMEL-6", kind: "operator", who: "chief", reason: "waiting on the freeze" }, { ts: "2026-11-02T09:00:00.000Z", change: "release", key: "HIMMEL-6", who: "chief" }] },
  ],
  tickets: {
    [K(1)]: { key: K(1), title: "First", state: "done", done: true, chains: [{ id: "memory", step: 1, steps: 2, state: "done" }], links: [] },
    [K(2)]: { key: K(2), title: "Second", state: "can launch", done: false, chains: [{ id: "memory", step: 2, steps: 2, state: "can launch" }], links: [linkOf("HIMMEL-1", "cleared")] },
    [K(6)]: { key: K(6), title: "Linked", state: "waits on HIMMEL-2", done: false, chains: [{ id: "ops", step: 1, steps: 1, state: "waits on HIMMEL-2" }], links: [linkOf("HIMMEL-2")] },
    [K(7)]: { key: K(7), title: "Stuck", state: "blocked", done: false, chains: [{ id: "ops", step: 1, steps: 1, state: "blocked" }], links: [linkOf("HIMMEL-21")] },
  },
  burn: { total: 4, undated: 1, points: [{ day: "2026-11-01", open: 3, merged: 1 }, { day: "2026-11-02", open: 3, merged: 0 }, { day: "2026-11-03", open: 3, merged: 0 }] } });
const chainsHtml = (ui: object = {}, ch: object = chainsLinked(), r = read(station())) => renderBoard(r, { version: null, theme: null, tab: "chains", ...ui }, { drift: null, chains: ch });

test("Chains tab, words: an open chain says what is next or blocked, a finished chain is one line, and every count has its unit", () => {
  const html = chainsHtml();
  expect(html).toContain("0 of 2 tickets done");
  expect(html).toContain("1 of 2 tickets done");
  expect(html).toContain("<small>step 1 of 2</small>");
  expect(html).toContain("<em>NEXT</em><b>HIMMEL-2</b>");
  expect(html).toContain("<em>BLOCKED</em><b>HIMMEL-7</b>");
  expect(html).not.toContain("no step left");
  const finished = chainsLinked();
  Object.assign(finished.chains[1], { done: 2 });
  const fin = chainsHtml({}, finished);
  expect(fin).toContain("Finished in v1.1.3 · 1 chain");
  expect(fin).toMatch(/<details id="rm-chain-ops" class="fin"><summary>/);
  expect(fin).toContain("2 of 2 tickets done");
});

test("Chains tab, links: no map; a link strip appears only for a link between two chains, and the list names both tickets and both chains", () => {
  const html = chainsHtml();
  expect(html).not.toContain("rm-map");
  expect(readFileSync(new URL("../public/app.css", import.meta.url), "utf8")).not.toContain(".rm-map");
  expect(html.match(/class="lmap"/g)).toHaveLength(1); // ops waits on memory; the link to a ticket in no chain draws no strip
  expect(html).toContain('class="lk open"');
  const strip = html.slice(html.indexOf('class="lmap"'), html.indexOf('class="gh"'));
  for (const x of ["HIMMEL-6 waits on HIMMEL-2", "Ops cleanup", "Memory guard rework"]) expect(strip).toContain(x);
  expect(html).toContain("HIMMEL-21"); // the across list of its own chain still names the blocker in no chain
});

test("Chains tab, change log: only a chain with rows has one, folded, counted, with each row's words", () => {
  const html = chainsHtml();
  expect(html).toMatch(/<details class="rm-log fold" data-log="ops"><summary>Change log · 2 rows · last [^<]*release<\/summary>/);
  expect(html.match(/Change log/g)).toHaveLength(1); // the memory chain has no rows: no empty log, no "No changes logged."
  expect(html).not.toContain("No changes logged.");
  expect(html).toContain("waiting on the freeze");
  expect(chainsHtml({ logOpen: ["ops"] })).toContain(`<details class="rm-log fold" data-log="ops" open>`); // a repaint keeps it open
});

test("Chains tab, Why: an open link offers it, and the panel names the blocker with the link's fields", () => {
  const closed = chainsHtml();
  expect(closed).toContain(`data-why-open="HIMMEL-7.HIMMEL-21"`);
  expect(closed).not.toContain(`data-why-open="HIMMEL-2.HIMMEL-1"`); // a cleared link holds nothing up
  expect(closed).not.toContain("rm-why\"");
  const html = chainsHtml({ why: "HIMMEL-7.HIMMEL-21" });
  const panel = html.slice(html.indexOf(`<aside class="drawer rm-why"`));
  expect(panel).toContain("Why HIMMEL-7 waits on HIMMEL-21");
  for (const f of ["Kind", "jira-link", "Source", "Added", "Status", "open", "What clears it", "HIMMEL-21 completes"]) expect(panel).toContain(f);
  expect(panel).toContain("blocked");
  expect(html).toContain(`<div class="rm-under" inert>`);
  expect(chainsHtml({ why: "HIMMEL-404.HIMMEL-1" })).toContain("not in this chain read"); // a stale link says so, never an empty panel
});

test("Chains tab, burn-down: one point per day, the words match the last point, undated tickets are named, and a pace needs a version date", () => {
  const r = read(station());
  const html = chainsHtml({}, chainsLinked(), r);
  const burn = html.slice(html.indexOf(`<details class="burn"`));
  expect(burn.match(/<circle /g)).toHaveLength(3);
  expect(burn).toContain("3 of 4 tickets open");
  expect(burn).toContain("1 done ticket has no recorded date");
  expect(burn).not.toContain("rm-burn-pace");
  const dated = { ...r, versions: r.versions.map((v) => ({ ...v, date: v.date || "2026-11-20" })) };
  expect(chainsHtml({}, { ...chainsLinked(), version: dated.versions[dated.cur].n }, dated)).toContain("rm-burn-pace");
  const none = chainsHtml({}, { ...chainsLinked(), burn: { total: 2, undated: 0, points: [] } });
  expect(none).toContain("No merge recorded yet");
});

test("Chains tab, motion: an open link and the panel move, and reduced motion stops every animation", () => {
  expect(chainsHtml()).toContain(`class="lk open"`);
  const css = readFileSync(join(import.meta.dir, "../public/app.css"), "utf8");
  expect(css).toMatch(/\.lk\.open[^{]*\{[^}]*animation:/);
  expect(css).toMatch(/@media \(prefers-reduced-motion:reduce\)\{\*,\*::before,\*::after\{animation:none!important;transition:none!important\}\}/);
});

test("Chains tab: with no running version the tab says so and shows no blocked count; with no registry it is words and no count", () => {
  const { version: _v, ...noVersion } = chainsLinked();
  const html = chainsHtml({}, noVersion);
  expect(html).toContain("no running version");
  expect(html).not.toMatch(/tickets? blocked/);
  expect(chainsHtml()).toContain("1 ticket blocked");
  const gone = chainsHtml({}, { state: "absent", reason: "no chain registry: none found" });
  expect(gone).toContain("no chain registry");
  for (const x of ['class="burn"', "rm-log", "rm-why", "Change log", 'class="cc']) expect(gone).not.toContain(x);
});

test("Chains tab: the ticket drawer is unchanged, and a Why panel never draws off the Chains tab", () => {
  const r = read(station());
  const k = r.tickets[0].k;
  const html = renderBoard(r, { version: null, theme: null, drawer: { k, project: r.tickets[0].project || "", history: null }, why: "HIMMEL-7.HIMMEL-21" }, { drift: null, chains: chainsLinked() });
  expect(html).toContain(`<aside class="drawer" role="dialog"`);
  expect(html).not.toContain("rm-why\"");
});

const tile = (html: string, name: string) => html.split(`<a class="rm-vt`).find((x) => x.includes(`<b>${name}</b>`)) ?? "";
const selected = (html: string) => html.split(`<a class="rm-vt`).filter((x) => x.startsWith(` sel"`)).map((x) => /<b>([^<]*)<\/b>/.exec(x)?.[1]);

test("Chains tab, a version with no chains: it names the version and never says the registry is empty", () => {
  const empty = { ...chainsLinked(), chains: [], tickets: {}, burn: { total: 0, undated: 0, points: [] } };
  const html = chainsHtml({}, empty);
  expect(html).toContain("No chain has a ticket in v1.1.3.");
  expect(html).not.toContain("No chains in the registry");
  const { version: _v, ...noVersion } = empty;
  expect(chainsHtml({}, noVersion)).toContain("No chains in the registry.");
});

// The whole-Board consumers read every version; only the Chains tab reads the running one.
const twoReads = () => {
  const c = chainsLinked();
  const narrowed = { ...c, chains: [c.chains[1]], tickets: { [K(6)]: c.tickets[K(6)], [K(7)]: c.tickets[K(7)] } };
  return { drift: null, chains: { ...chainsOk(), version: null }, versionChains: narrowed };
};

test("Two chain reads: tiles, badges, lane filters, the Chain select and waits-for-you read every version, also for a version other than the running one", () => {
  const r = read(station());
  const html = renderBoard(r, { version: null, theme: null, v: "v1.1.2" }, twoReads());
  expect(tile(html, "v1.1.2")).not.toContain("in chains"); // 9488: no tile counts tickets in chains, in any read
  expect(html).toContain("1 waits for you");
  expect(html).toContain('href="#/board?tab=chains&amp;v=v1.1.2&amp;at=HIMMEL-1"');
  expect(html).toContain(`<option value="memory"`);
  expect(html).toContain("waits on you 1</option>");
});

test("Two chain reads: the Chains tab's members, totals, blocked count and Why panel read the running version only", () => {
  const r = read(station());
  const html = renderBoard(r, { version: null, theme: null, tab: "chains" }, twoReads());
  expect(html).toContain(`id="rm-chain-ops"`);
  expect(html).not.toContain(`id="rm-chain-memory"`);
  expect(html).toContain("1 chain in v1.1.3");
  expect(html).toContain("1 ticket blocked");
  expect(html).not.toContain("in chains");
  const why = renderBoard(r, { version: null, theme: null, tab: "chains", why: "HIMMEL-7.HIMMEL-21" }, twoReads());
  expect(why).toContain("Why HIMMEL-7 waits on HIMMEL-21");
  expect(renderBoard(r, { version: null, theme: null, tab: "chains", why: "HIMMEL-1.HIMMEL-9" }, twoReads())).toContain("not in this chain read");
});

test("Chains tab, its version: printed on the tab and in the burn-down, and a tile never highlights another version over those totals", () => {
  const html = chainsHtml({ v: "v1.1.2" });
  expect(chipsSelected(html)).toEqual(["v1.1.3"]);
  expect(chainsHtml({ v: "all" })).toContain("“all versions” shows the running version, v1.1.3.");
  expect(chainsHtml()).not.toContain("shows the running version");
  const burn = html.slice(html.indexOf(`<details class="burn"`));
  expect(burn).toContain("3 of 4 tickets open in v1.1.3");
  expect(chainsHtml({}, { ...chainsLinked(), burn: { total: 2, undated: 0, points: [] } })).toContain("No merge recorded yet in v1.1.3: 2 tickets open.");
  const fell = chainsHtml({ v: "nope<" }, { ...chainsLinked(), fellBack: { asked: "nope<", to: "v1.1.3" } });
  expect(fell).not.toContain("nope<");
  expect(fell).toContain("nope&lt; is not a version in the mirror, so this tab shows the running version, v1.1.3.");
  const { version: _v, ...noVersion } = chainsLinked();
  expect(chipsSelected(chainsHtml({ v: "v1.1.2" }, noVersion))).toEqual([]); // that read covers every version, so no one tile is its version
  expect(chainsHtml({}, noVersion)).toContain("No running version, so there is no pace line.");
  expect(selected(renderBoard(read(station()), { version: null, theme: null, v: "v1.1.2" }, { drift: null, chains: chainsLinked() }))).toEqual(["v1.1.2"]); // off the tab a tile follows the ask
});

test("Chains tab, across wording: a blocker outside the version is in no chain of that version, and a tab with no link between its chains says which version", () => {
  const html = chainsHtml();
  expect(html).toContain("in no chain of v1.1.3");
  expect(html).not.toMatch(/in no chain ·/);
  const { version: _v, ...noVersion } = chainsLinked();
  expect(chainsHtml({}, noVersion)).toMatch(/in no chain ·/);
  expect(chainsHtml({ why: "HIMMEL-7.HIMMEL-21" }, noVersion)).toContain("HIMMEL-21 (in no version)");
  expect(chainsHtml({ why: "HIMMEL-7.HIMMEL-21" })).toContain("HIMMEL-21 (in no version; in no chain of v1.1.3)");
  const c = chainsLinked();
  const unlinked = { ...c, chains: c.chains.map((x) => ({ ...x, across: x.across.filter((a) => !a.chains.length) })) };
  expect(chainsHtml({}, unlinked)).not.toContain('class="lmap"'); // no link between two chains: no strip, and no sentence saying there is none
  expect(chainsHtml({}, unlinked)).toContain("in no chain of v1.1.3"); // the link to work outside it still shows under its chain
});

test("Chains tab, a card's link to a ticket outside the version: the tab says so instead of highlighting nothing", () => {
  expect(chainsHtml({ at: "HIMMEL-99" })).toContain("HIMMEL-99 is not in a chain of v1.1.3.");
  expect(chainsHtml({ at: "HIMMEL-7" })).not.toContain("is not in a chain of");
});

test("Why panel: a live link wins over an earlier released one with the same blocker, and a released one still opens when nothing else matches", () => {
  const c = chainsLinked();
  c.tickets["HIMMEL-6"].links = [linkOf("HIMMEL-2", "released"), linkOf("HIMMEL-2", "open")];
  expect(chainsHtml({ why: "HIMMEL-6.HIMMEL-2" }, c)).toContain("<dt>Status</dt><dd>open</dd>");
  c.tickets["HIMMEL-6"].links = [linkOf("HIMMEL-2", "released")];
  expect(chainsHtml({ why: "HIMMEL-6.HIMMEL-2" }, c)).toContain("<dt>Status</dt><dd>released</dd>");
});

test("Chains tab with several Board projects: a version name carrying its project suffix still finds its date and its tile", () => {
  const r = read(station());
  const named = { ...r, versions: r.versions.map((v) => ({ ...v, n: `${v.n} (HIMMEL)`, date: "2026-11-20" })) };
  const html = chainsHtml({}, chainsLinked(), named);
  expect(html).toContain("rm-burn-pace");
  expect(chipsSelected(html)).toEqual(["v1.1.3 (HIMMEL)"]);
  for (const v of ["v1.1.3", "v1.1.3 (HIMMEL)", "v1.1.2 (HIMMEL)"]) expect(chipsSelected(chainsHtml({ v }, chainsLinked(), named))).toEqual(["v1.1.3 (HIMMEL)"]); // the chip follows the read, not the ask
});

// ---- The compact Chains tab. Every number below is seeded here, never copied from a live read. ----
const tkt = (key: string, state: string, chain: string, step: number, steps: number, links: object[] = []) =>
  ({ key, title: `${key} full title`, state, done: state === "done", chains: [{ id: chain, step, steps, state }], links });
const lnk = (on: string, onVersions: string[] | null, status = "open") => ({ ...linkOf(on, status), onVersions });
// the tab's read (version v1.1.3: two chains, three tickets) and the whole read (more tickets, one more chain)
const narrow3 = () => ({ schema: "himmel.chains/1", now: "2026-11-03T08:00:00.000Z", version: "v1.1.3",
  chains: [{ id: "alpha", name: "Alpha chain", members: [K(1), K(2)], total: 2, done: 1, steps: 2, next: { step: 2, keys: [K(2)] }, across: [], log: [] },
    { id: "beta", name: "Beta chain", members: [K(6)], total: 1, done: 0, steps: 1, next: null, across: [], log: [] }],
  tickets: { [K(1)]: tkt(K(1), "done", "alpha", 1, 2), [K(2)]: tkt(K(2), "can launch", "alpha", 2, 2), [K(6)]: tkt(K(6), "in flight", "beta", 1, 1) },
  burn: { total: 3, undated: 0, points: [{ day: "2026-11-01", open: 2, merged: 1 }] } });
const whole6 = () => ({ schema: "himmel.chains/1", version: null,
  chains: [{ id: "alpha", name: "Alpha chain", members: [K(1), K(2), K(5)], total: 3, done: 1, steps: 2, next: null, across: [], log: [] },
    { id: "beta", name: "Beta chain", members: [K(6), K(7)], total: 2, done: 0, steps: 1, next: null, across: [], log: [] },
    { id: "gamma", name: "Gamma chain", members: [K(3), K(4)], total: 2, done: 1, steps: 1, next: null, across: [], log: [] }],
  tickets: { [K(1)]: tkt(K(1), "done", "alpha", 1, 2), [K(2)]: tkt(K(2), "can launch", "alpha", 2, 2), [K(5)]: tkt(K(5), "can launch", "alpha", 2, 2),
    [K(6)]: tkt(K(6), "in flight", "beta", 1, 1), [K(7)]: tkt(K(7), "blocked", "beta", 1, 1), [K(3)]: tkt(K(3), "done", "gamma", 1, 1) } });
const two = (ui: object = {}, narrowed: object = narrow3(), whole: object = whole6(), r = read(station())) =>
  renderBoard(r, { version: null, theme: null, tab: "chains", ...ui }, { drift: null, chains: whole, versionChains: narrowed });
const panelOf = (html: string) => html.slice(html.indexOf('id="rm-chains"'));
const chipsSelected = (html: string) => html.split('<a class="vc').filter((x) => x.startsWith(' sel"')).map((x) => /<b>([^<]*)<\/b>/.exec(x)?.[1]);

test("9488 counts agree: the tab's chains and tickets come from one read and no version tile counts 'in chains'", () => {
  const html = two();
  expect(html).toMatch(/Chains\s*<span class="cnt">2<\/span>/);
  expect(panelOf(html)).toContain("<b>3 tickets</b>");
  expect(html).not.toContain("in chains"); // the unit-less tile number is gone from every tile
  expect(html).not.toContain("6 tickets"); // the whole read's 6 are not the tab's
  // the number on the tab is the sum of the chain rows drawn, also when the whole read is bigger than the version's
  const drawn = (panelOf(html).match(/<article id="rm-chain-/g) || []).length + (panelOf(html).match(/<details id="rm-chain-/g) || []).length;
  expect(drawn).toBe(2);
});

test("9488 tiles drive the tab: a picked version names itself, selects its tile and names the key of every outside ticket", () => {
  const n = narrow3();
  const picked = { ...n, version: "v1.1.2", chains: [{ ...n.chains[0], members: [K(1), K(2)] }], tickets: { [K(1)]: n.tickets[K(1)], [K(2)]: n.tickets[K(2)] } };
  const wh = whole6();
  wh.chains[0].members = [K(1), K(2), K(6)]; // the sixth ticket is in v1.1.3
  const html = two({ v: "v1.1.2" }, picked, wh);
  expect(chipsSelected(html)).toEqual(["v1.1.2"]);
  expect(panelOf(html)).toContain("1 chain in v1.1.2");
  expect(panelOf(html)).toContain("+1 ticket outside v1.1.2");
  expect(panelOf(html)).toContain("HIMMEL-6 in v1.1.3"); // the key is in the text, never only in a hover bubble
  expect(panelOf(html)).not.toContain("rm-tip");
});

// Call 4: a ticket is blocked only when nothing lands its blocker before the version.
const waitCase = (sel: string, onVersions: string[] | null) => {
  const n = narrow3();
  const v = { ...n, version: sel, chains: [n.chains[1]], tickets: { [K(6)]: tkt(K(6), "blocked", "beta", 1, 1, [lnk("HIMMEL-21", onVersions)]) } };
  return two({ v: sel }, v);
};
test("9488 call 4: a blocker in an earlier open version is a wait, not a block; later, no version and released-open are blocked", () => {
  const earlier = waitCase("v1.1.3", ["v1.1.2"]);
  expect(panelOf(earlier)).toContain("waits on v1.1.2");
  expect(panelOf(earlier)).not.toMatch(/class="tk bd/);
  expect(panelOf(earlier)).not.toMatch(/class="cc red/);
  expect(earlier).not.toContain("blocked</span>"); // no blocked chip on the tab
  expect(panelOf(earlier)).toContain("0 tickets blocked");
  for (const [sel, on] of [["v1.1.2", ["v1.1.3"]], ["v1.1.3", []], ["v1.1.3", ["v1.1.1"]]] as [string, string[]][]) {
    const html = waitCase(sel, on);
    expect(panelOf(html)).toMatch(/class="tk bd/);
    expect(panelOf(html)).toMatch(/class="cc red/);
    expect(panelOf(html)).toContain("1 ticket blocked");
    expect(html).toContain("⛔ 1 ticket blocked"); // the tab's chip
  }
  expect(panelOf(waitCase("v1.1.3", []))).toContain("in no version");
  expect(panelOf(waitCase("v1.1.3", ["v1.1.1"]))).toContain("a released version, and still open");
  expect(panelOf(waitCase("v1.1.2", ["v1.1.3"]))).toContain("a later version");
});

test("9488 call 4 does not fail open: with no versions snapshot an earlier version is not trusted to be unreleased, so the wait stays blocked", () => {
  const n = narrow3();
  const v = { ...n, version: "v1.1.3", chains: [n.chains[1]], tickets: { [K(6)]: tkt(K(6), "blocked", "beta", 1, 1, [lnk("HIMMEL-21", ["v1.1.2"])]) } };
  const html = two({ v: "v1.1.3" }, v, whole6(), { ...read(station()), releaseUnknown: true });
  expect(panelOf(html)).toMatch(/class="tk bd/);
  expect(panelOf(html)).toContain("1 ticket blocked");
  expect(panelOf(html)).not.toContain("waits on v1.1.2");
  expect(html).toContain("no versions snapshot says whether it is released");
});

test("9488 the No version tab keeps the whole chain read: its tickets are in no version, so the picked version's read cannot hold them", () => {
  const s = withNoVersion(station());
  const wh = whole6();
  wh.chains[0].members.push(K(8));
  Object.assign(wh.tickets, { [K(8)]: { ...tkt(K(8), "can launch", "alpha", 2, 2), badges: ["alpha"] } });
  const html = renderBoard(read(s), { version: null, theme: null, tab: "nv", nv: nvRead(s) }, { drift: null, chains: wh, versionChains: { ...narrow3(), version: "v1.1.2" } }); // v1.1.2 is the selected tile, so the narrowed read would be the one drawn from
  expect(html).toContain("Loose ticket");
  expect(html).toMatch(/class="rm-chain" href="#\/board\?tab=chains&amp;at=HIMMEL-8"/); // its badge
  expect(html).toContain("in a chain 1"); // and the Only filter counts it
});

test("9488 the header spark says no second ticket total, and a finished chain opens when the ticket asked for is in it", () => {
  const lone = { ...chainsLinked(), burn: { total: 3, undated: 1, points: [{ day: "2026-11-01", open: 2, merged: 1 }] } }; // the burn-down leaves out the undated done ticket
  const spark = /class="spark">(?:<svg.*?<\/svg>)?([^<]*)<\/div>/.exec(chainsHtml({}, lone))![1];
  expect(spark).toBe("2 tickets open");
  expect(chainsHtml({}, lone)).toContain("<b>4 tickets</b> in them");
  const finished = chainsLinked();
  Object.assign(finished.chains[1], { done: 2 });
  expect(chainsHtml({ at: K(6) }, finished)).toMatch(/<details id="rm-chain-ops" class="fin" open>/);
  expect(chainsHtml({ at: K(1) }, finished)).toMatch(/<details id="rm-chain-ops" class="fin"><summary>/);
});

test("9488 the Tidy up and No version tabs name their unit", () => {
  const r = read(withNoVersion(station()));
  const real = [{ class: "VERSION-DRIFT", key: "HIMMEL-6691", line: "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=jira release request v1.1.3" }];
  const html = renderBoard(r, { version: null, theme: null, tab: "roadmap" }, { drift: driftOk(real, 4, 1), chains: null });
  expect(html).toContain('Tidy up <span class="ro">1 drift row</span>');
  expect(html).toContain('No version <span class="ro">1 ticket</span>');
});

test("9488 critic minors: no wording that says a later-version blocker is unplanned, full count keys, the 8430 state, the foot line and the phone's named ticket", () => {
  const html = two({ v: "v1.1.2" }, (() => { const n = narrow3(); return { ...n, version: "v1.1.2", chains: [{ ...n.chains[0], members: [K(1), K(2)] }], tickets: { [K(1)]: n.tickets[K(1)], [K(2)]: n.tickets[K(2)] } }; })(),
    (() => { const w = whole6(); w.chains[0].members = [K(1), K(2), K(6)]; return w; })());
  // m1
  for (const bad of ["nothing plans the ticket", "Giving 8430 a version clears this", "is about to do"]) expect(html).not.toContain(bad);
  // m2
  expect(panelOf(html).replace(/<a class="tk[^]*?<\/a>/g, "")).not.toMatch(/\b\d+ (blocked|can launch|in flight|waiting|done)\b/); // a ticket chip's "2 can launch" is a key and a state
  expect(panelOf(html)).toContain("1 ticket can launch");
  // m5: the ticket that can launch shows that state in its box
  expect(panelOf(html)).toMatch(/class="tk go[^"]*"[^>]*>[^<]*<span class="gl" aria-hidden="true">▷<\/span> 2 can launch/);
  // m3: the foot line names the chain with no ticket in this version and where to pick it; the refresh control and the versions menu are real
  expect(panelOf(html)).toContain("2 more chains, beta, gamma, have no ticket in v1.1.2.");
  expect(panelOf(html)).toContain('href="#/board?tab=chains&amp;v=v1.1.1">v1.1.1</a> to see gamma.'); // only gamma has a ticket in the first other version, so only gamma is named
  expect(panelOf(two())).toContain("1 more chain, gamma, has no ticket in v1.1.3. Pick");
  expect(html).toContain('data-act="refresh-roadmap"');
  expect(html).toMatch(/<details class="vmenu"[^>]*><summary>\d of 3 versions/);
  expect(html).toContain("Tickets and titles · 2 tickets"); // full titles on the phone's fold
  expect(panelOf(html)).toContain("HIMMEL-2 full title");
});

test("9488 the Chains tab has no Chain select, Hide Done, Sector or 'all versions'; the Roadmap tab keeps them", () => {
  const html = two();
  for (const x of ["data-rm-chain", "data-rm-hide-done", 'data-rm-filter="theme"', "all versions"]) expect(html).not.toContain(x);
  expect(html).not.toContain("drift"); // no drift banner on this tab
  const road = renderBoard(read(station()), { version: null, theme: null, tab: "roadmap" }, { drift: null, chains: whole6(), versionChains: narrow3() });
  for (const x of ["data-rm-chain", "data-rm-hide-done", 'data-rm-filter="theme"', "all versions"]) expect(road).toContain(x);
});

test("9488 v=all on the Chains tab shows the running version and says so in one line; the link strip shows only when a link exists", () => {
  const html = two({ v: "all" });
  expect(panelOf(html)).toContain("“all versions” shows the running version, v1.1.3.");
  expect(html).not.toContain('class="lmap"');
  const n = narrow3();
  n.chains[1].across = [{ dir: "waits-on", key: K(6), on: K(2), kind: "jira-link", status: "open", chains: ["alpha"] }] as never;
  const linked = two({}, n);
  expect(linked).toContain('class="lmap"');
  expect(linked).toContain("HIMMEL-6 waits on HIMMEL-2");
});

test("9488 an open chain is one compact rail: one rail, one NOW or NEXT line, its folds in one closed row, and a chip with its Why link is one unit", () => {
  const panel = panelOf(chainsHtml());
  const cards = panel.split('<article id="rm-chain-').slice(1);
  expect(cards).toHaveLength(2);
  for (const card of cards) {
    expect(card.match(/class="rl"/g) || []).toHaveLength(1);
    expect(card.match(/class="now"/g) || []).toHaveLength(1);
    const folds = /<div class="folds">(.*?)<\/div>(?=<\/article>)/s.exec(card);
    expect(folds).not.toBeNull();
    expect(folds![1]).toContain('<details class="fold"><summary>Tickets and titles');
    expect(card).not.toMatch(/<details[^>]* open/);
  }
  expect(cards[1]).toContain("<summary>Change log · 2 rows");
  expect(cards[1]).toMatch(/<span class="tw"><a class="tk [^>]*>.*?<\/a> <a class="rm-whylink"[^>]*>Why<\/a><\/span>/s);
});

test("9488 the burn-down is folded, says the cut date passed, and draws no pace line when the date is before the first merge", () => {
  const r = read(station());
  const dated = { ...r, versions: r.versions.map((v) => ({ ...v, date: "2026-10-22" })) };
  const html = two({}, narrow3(), whole6(), dated);
  expect(panelOf(html)).toMatch(/<details class="burn"><summary>Burn-down<\/summary>/);
  expect(panelOf(html)).toContain("The cut date, 2026-10-22, has passed, so no pace line is drawn.");
  expect(panelOf(html)).not.toContain("rm-burn-pace");
  const future = { ...r, versions: r.versions.map((v) => ({ ...v, date: "2026-11-20" })) };
  expect(panelOf(two({}, narrow3(), whole6(), future))).toContain("rm-burn-pace");
});

// ---- the dense Board. Review and CI share a column, Won't is a lane that takes drops, and every clamped text keeps its full text ----
test("9100 Board: a writable board has a Won't drop target and a Review / CI drop target and no separate CI target; a ci card sits in Review / CI with a CI pill", () => {
  const r = read(station());
  const w = renderBoard(r, { version: null, theme: null, v: "all", writes: true }, null);
  expect(w).toContain('data-rm-drop="wont"');
  expect(w).toContain('data-rm-drop="rev"');
  expect(w).not.toContain('data-rm-drop="ci"');
  expect(w).not.toContain('data-rm-col="ci"');
  expect(cols(board(r)).map((x) => x[0])).toEqual(["todo", "prog", "rev", "done"]); // read-only and no Won't card: no lane
  const ci = { ...r, tickets: r.tickets.map((t, i) => (i === 0 ? { ...t, b: "ci", s: "IN CI" } : t)) };
  const rev = cols(board(ci)).find((x) => x[0] === "rev")!;
  expect(rev.slice(1, 3)).toEqual([2, 2]); // ticket 7 in review and ticket 1 in CI
  expect(board(ci)).toMatch(/class="[^"]*\bpill\b[^"]*">CI<\/span>/);
  const wont = { ...r, tickets: r.tickets.map((t, i) => (i === 0 ? { ...t, b: "wont", s: "wont do" } : t)) };
  expect(cols(board(wont)).map((x) => x[0])).toEqual(["todo", "prog", "rev", "done", "wont"]);
});

test("9100 Board: a 200-character title and a 60-character chain name keep their full text in data-tip, the card is a button named with the full title, and no native title duplicates a tip", () => {
  const r = read(station());
  const LONG = "T".repeat(199) + "!", CHAIN = "c".repeat(60);
  const tickets = r.tickets.map((t) => (t.k === 1 ? { ...t, t: LONG } : t));
  const ch = { schema: "himmel.chains/1", chains: [{ id: CHAIN, name: CHAIN, total: 1, done: 0, steps: 1, next: null }],
    tickets: { [K(1)]: { key: K(1), state: "in flight", chains: [{ id: CHAIN, step: 1, steps: 1, state: "in flight" }], badges: [CHAIN], more: 0 } } };
  const html = renderBoard({ ...r, tickets }, { version: null, theme: null }, { chains: ch });
  expect(html).toContain(`<div class="rm-tip rm-title" data-tip="${LONG}">`);
  expect(html).toContain(`data-tip="● ${CHAIN} step 1 of 1 · in flight"`); // the badge's visible text, glyph included
  const card = [...html.matchAll(/<div class="rm-card"[^>]*>/g)].map((m) => m[0]).find((c) => c.includes(LONG))!;
  expect(card).toContain('role="button"');
  expect(card).toContain(`aria-label="${K(1)}: ${LONG}"`);
  expect(html).not.toMatch(/<[^>]*\bdata-tip="[^>]*\btitle="|<[^>]*\btitle="[^>]*\bdata-tip="/);
  expect(html).not.toContain('title="Open the'); // the link's action is its accessible name now, not a second bubble
  expect(html).toMatch(/<a class="rm-chain"[^>]*aria-label="Open the c{60} chain on the Chains tab[^"]*"/);
});

// ---- the Board shows at most 5 versions ----------------------------------------------------------------------------------
// 12 versions v2.0 .. v2.11; v2.0 to v2.4 are released, v2.5 is the running one.
const many = () => {
  const r = read(station());
  const zero = { todo: 0, prog: 0, rev: 0, ci: 0, done: 0, wont: 0 };
  const versions = Array.from({ length: 12 }, (_, i) => ({ n: `v2.${i}`, rel: i < 5, date: i < 5 ? "2026-09-01" : "", counts: { ...zero }, open: [] as string[] }));
  return { ...r, versions, cur: 5, next: 6, tickets: [], noVersionCount: 0 } as typeof r;
};
const tiles = (html: string) => [...html.matchAll(/class="rm-vt(?: sel)?" href="[^"]*v=(v2\.\d+)/g)].map((m) => m[1]);

test("Board versions: no pins show the running version and 2 on each side, and the page says what it shows", () => {
  const html = renderBoard(many(), { version: null, theme: null }, null);
  expect(tiles(html)).toEqual(["v2.3", "v2.4", "v2.5", "v2.6", "v2.7"]);
  expect(html).toContain("showing 5 of 12 versions");
  expect(html).toContain("data-rm-show-all");
});

test("Board versions: pinned versions fill the slots, and a sixth pin is refused with a message that states the cap", () => {
  const three = renderBoard(many(), { version: null, theme: null, pins: ["v2.0", "v2.9", "v2.11"] }, null);
  expect(tiles(three)).toEqual(["v2.0", "v2.9", "v2.11"]);
  expect(three).toContain("showing 3 of 12 versions");
  const six = renderBoard(many(), { version: null, theme: null, pins: ["v2.0", "v2.1", "v2.2", "v2.3", "v2.4", "v2.5"] }, null);
  expect(tiles(six).length).toBe(5);
  expect(six).toContain("at most 5 versions");
  const full = ["v2.0", "v2.1", "v2.2", "v2.3", "v2.4"];
  const refused = togglePin(full, "v2.9");
  expect(refused.pins).toEqual(full);
  expect(refused.msg).toContain("at most 5 versions");
  expect(togglePin(full, "v2.4").pins).toEqual(["v2.0", "v2.1", "v2.2", "v2.3"]);
  expect(togglePin(["v2.0"], "v2.9")).toEqual({ pins: ["v2.0", "v2.9"], msg: "" });
});

test("Board versions: show all renders all 12, and hide previous and hide far future remove those versions", () => {
  const d = many();
  expect(tiles(renderBoard(d, { version: null, theme: null, showAll: true }, null)).length).toBe(12);
  expect(renderBoard(d, { version: null, theme: null, showAll: true }, null)).toContain("showing 12 of 12 versions");
  const noPrev = tiles(renderBoard(d, { version: null, theme: null, showAll: true, hidePrev: true }, null));
  expect(noPrev).toEqual(["v2.5", "v2.6", "v2.7", "v2.8", "v2.9", "v2.10", "v2.11"]);
  const noFar = tiles(renderBoard(d, { version: null, theme: null, showAll: true, hideFuture: true }, null));
  expect(noFar).toEqual(["v2.0", "v2.1", "v2.2", "v2.3", "v2.4", "v2.5", "v2.6", "v2.7"]);
  expect(tiles(renderBoard(d, { version: null, theme: null, hidePrev: true }, null))).toEqual(["v2.5", "v2.6", "v2.7"]);
});

test("Board versions: the controls and the pin buttons make no write call", () => {
  const real = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; return Promise.reject(new Error("write")); }) as unknown as typeof fetch;
  try {
    const html = renderBoard(many(), { version: null, theme: null, writes: true, pins: ["v2.1"] }, null);
    togglePin(["v2.1"], "v2.2");
    expect(html).toContain("data-rm-pin");
  } finally { globalThis.fetch = real; }
  expect(calls).toBe(0);
});

test("Board versions: the pins ride in the URL's query string, and roadmap.js stores nothing in the browser", () => {
  expect(pinsFromSearch("?pins=v2.0,v2.9")).toEqual(["v2.0", "v2.9"]);
  expect(pinsFromSearch("")).toEqual([]);
  expect(searchWithPins("?a=1", ["v2.0", "v2.9"])).toBe("?a=1&pins=v2.0%2Cv2.9");
  expect(searchWithPins("?pins=v2.0&a=1", [])).toBe("?a=1");
  expect(searchWithPins("?pins=v2.0", [])).toBe("");
  const src = readFileSync(join(import.meta.dir, "../public/roadmap.js"), "utf8").replace(/\/\/.*$/gm, "");
  expect(/\b(localStorage|sessionStorage|indexedDB|document\.cookie)\b/.test(src)).toBe(false);
});

test("Board versions: with a pin set, Show all exposes the unpinned versions so a second pin is possible", () => {
  const html = renderBoard(many(), { version: null, theme: null, pins: ["v2.1"], showAll: true }, null);
  expect(tiles(html).length).toBe(12);
  expect(html).toContain("showing 12 of 12 versions");
  expect(html).toContain('data-rm-pin="v2.1" aria-pressed="true"');
  expect(html).toContain('data-rm-pin="v2.2" aria-pressed="false"');
});

test("Board: the worker line on a card shows how long ago its worker last moved, from the worker record, and nothing when no record says", () => {
  const s = station();
  const absent = { state: "absent", reason: "none" };
  const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString();
  const prs = (seen: Record<string, string>) => ({ state: "ok", repo: "acme/widgets", prs: {}, seen });
  const card = (html: string, k: string) => html.match(new RegExp(`<div class="rm-card"[^>]*aria-label="${k}:[\\s\\S]*?</div></div>`))![0];
  const r = read(s);
  const withAge = board(r, {}, { drift: absent, chains: absent, prs: prs({ [K(1)]: ago(180) }) });
  expect(card(withAge, K(1))).toMatch(/<div class="rm-worker">[\s\S]*classifier permission hold[\s\S]*3 h ago/); // ticket 1 has the worker
  expect(card(board(r, {}, { drift: absent, chains: absent, prs: prs({ [K(1)]: ago(50) }) }), K(1))).toContain("50 min ago");
  expect(card(board(r, {}, { drift: absent, chains: absent, prs: prs({ [K(1)]: ago(60 * 60) }) }), K(1))).toContain("2 d ago");
  const noRecord = card(board(r, {}, { drift: absent, chains: absent, prs: prs({}) }), K(1));
  expect(noRecord).toContain("classifier permission hold");
  expect(noRecord).not.toContain(" ago");
  expect(card(board(r, {}, { drift: absent, chains: absent, prs: absent }), K(1))).not.toContain(" ago");
  expect(card(board(r, {}, { drift: absent, chains: absent, prs: prs({ [K(2)]: ago(180) }) }), K(1))).not.toContain(" ago"); // an age belongs to its own ticket's line
});

test("Board: the read line says when the Board last read and how often it reads again, beside the newest Jira update", () => {
  const absent = { state: "absent", reason: "none" };
  const r = read(station());
  const html = board(r, { readAt: Date.parse("2026-11-07T14:05:09") }, { drift: absent, chains: absent });
  expect(html).toMatch(/newest update [^,)]+[^]*read \d\d:\d\d:\d\d/); // the Jira mirror's newest update stays, the Board's own read time joins it
  expect(html).toContain(`refreshes every ${BOARD_REFRESH_MS / 1000} s`);
  expect(board(r, {}, { drift: absent, chains: absent })).not.toMatch(/read \d\d:\d\d:\d\d/); // no read yet: no time is claimed
});

test("Board: it refreshes itself only when it is on screen, nothing is being edited or dragged, and a whole interval has passed since the last read", () => {
  const base = { page: "board", visible: true, modal: false, editing: false, dragging: false, busy: false, readAt: 1_000_000, now: 1_000_000 + BOARD_REFRESH_MS };
  expect(BOARD_REFRESH_MS).toBeGreaterThanOrEqual(30_000); // bounded below: it never polls fast
  expect(boardRefreshDue(base)).toBe(true);
  expect(boardRefreshDue({ ...base, now: base.now - 1 })).toBe(false); // not yet
  for (const off of [{ page: "health" }, { visible: false }, { modal: true }, { editing: true }, { dragging: true }, { busy: true }, { readAt: 0 }]) expect(boardRefreshDue({ ...base, ...off })).toBe(false);
});

test("Board: an open ticket's card names the tickets it waits on, with their state: a shut one as 'after', an open one as 'blocked by open'", () => {
  const s = station();
  const put = (n: number, status: string, cat: string, by: string[]) => writeFileSync(join(s.mirror, `HIMMEL-${n}.md`),
    issue(n, status, cat, ["v1.1.2"], `Step ${n}`).replace("blocked_by: []", `blocked_by: ${JSON.stringify(by)}`));
  put(20, "To Do", "To Do", [K(21), K(22), K(99)]);
  put(21, "In Progress", "In Progress", []);
  put(22, "Done", "Done", []);
  put(23, "Done", "Done", [K(22)]);
  const r = read(s);
  const t = (n: number) => r.tickets.find((x) => x.k === n)!;
  expect(t(20).after).toEqual([{ id: K(21), b: "prog" }, { id: K(22), b: "done" }, { id: K(99), b: "unknown" }]); // 99 is in no mirror: its state is not guessed
  expect(t(21).after).toBeUndefined();
  expect(t(23).after).toBeUndefined(); // a ticket that is done waits on nothing
  const absent = { state: "absent", reason: "none" };
  const card = (k: string) => board(r, {}, { drift: absent, chains: absent }).match(new RegExp(`<div class="rm-card"[^>]*aria-label="${k}:[\\s\\S]*?</div></div>`))![0];
  expect(card(K(20))).toContain(`blocked by open ${K(21)}`);
  expect(card(K(20))).toContain(`after ${K(22)} (done)`);
  expect(card(K(20))).toContain(`${K(99)} (state unknown)`);
  expect(card(K(21))).not.toContain("after ");
});

test("Board: the lanes carry a sector legend: each sector of the version's open tickets with its count, the largest first, done tickets not counted", () => {
  const s = station();
  const put = (n: number, status: string, cat: string, labels: string[]) => writeFileSync(join(s.mirror, `HIMMEL-${n}.md`), issue(n, status, cat, ["v1.1.3"], `Work ${n}`, labels));
  put(30, "To Do", "To Do", ["theme-alpha"]);
  put(31, "In Progress", "In Progress", ["theme-alpha"]);
  put(32, "To Do", "To Do", ["theme-beta"]);
  put(33, "Done", "Done", ["theme-beta"]);
  const html = board(read(s), { v: "v1.1.3" }, null);
  const legend = html.match(/<div class="seclegend"[^>]*>([\s\S]*?)<\/div>/);
  expect(legend).not.toBeNull();
  const items = [...legend![1].matchAll(/<span class="sec">([^<]*)<\/span>/g)].map((m) => m[1].replace(/\s+/g, " ").trim());
  expect(items.slice(0, 2)).toEqual(["alpha 2", "beta 1"]);
  expect(items.join("|")).not.toContain("beta 2"); // the done ticket is not counted
});

test("Board: a card in a chain says FAST-TRACK with the chain's name and its step, and the lanes carry a drain line counting the open tickets in and out of a chain", () => {
  const r = read(station());
  const html = board(r, { v: "v1.1.2" }, { drift: null, chains: chainsOk() });
  const card = (k: string) => html.match(new RegExp(`<div class="rm-card"[^>]*aria-label="${k}:[\\s\\S]*?</div></div>`))![0];
  expect(card(K(1))).toContain(`<div class="rm-ft">FAST-TRACK · Memory guard rework · step 1</div>`);
  expect(card(K(2))).not.toContain("FAST-TRACK"); // in no chain
  expect(board(r, { v: "v1.1.2" }, null)).not.toContain("FAST-TRACK"); // no chain read: nothing is guessed
  // v1.1.2 holds tickets 1, 2, 5, 7 open; 1 and 5 are in the memory chain
  expect(html).toContain(`<div class="rm-drain">v1.1.2 drain: open 4 · in-chain 2 · in no chain 2</div>`);
  expect(board(r, { v: "v1.1.2" }, null)).not.toContain("rm-drain"); // without the chain read it cannot split
});

// ---- Waiting on you lists what is owed to the operator: unsigned specs, chief doc lines, the HANDOFF's open items and operator holds on a ticket with a PR ----
const owedUi = { version: null, theme: null };
const waitingSec = (html: string) => html.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)?.[0] ?? "";
const noChains = { state: "absent", reason: "no chain registry" };

test("Board: an unsigned spec is a Waiting on you row with the ticket's title, a context line and the action, and leaves once its record lands", () => {
  const r = read(station());
  const spec = { source: "unsigned spec", key: K(2), title: "Orphaned work", ctx: "HIMMEL-2-orphans.md: latest critic round 1 reads SPEC CLEAN, no spec row in operator.jsonl", act: "sign the spec, or rule on its findings" };
  const sec = waitingSec(renderBoard(r, owedUi, { drift: null, chains: noChains, owed: { state: "ok", items: [spec], unread: [] } }));
  expect(sec).toContain("Orphaned work"); // the title, never a bare key
  expect(sec).toContain("latest critic round 1 reads SPEC CLEAN");
  expect(sec).toContain("Action: sign the spec, or rule on its findings");
  // recording the signature removes the row
  expect(renderBoard(r, owedUi, { drift: null, chains: noChains, owed: { state: "ok", items: [], unread: [] } })).not.toContain("rm-waiting");
  // a read that failed is said, never shown as nobody owing the operator anything
  const bad = renderBoard(r, owedUi, { drift: null, chains: noChains, owed: { state: "absent", reason: "no bucket" } });
  expect(bad).not.toContain("rm-waiting");
  expect(bad).toContain("the operator-owed sources not read");
  const part = renderBoard(r, owedUi, { drift: null, chains: noChains, owed: { state: "ok", items: [], unread: ["handoff items"] } });
  expect(part).toContain("handoff items not read");
});

test("Board: an operator hold on a ticket with an open PR is a Waiting on you row with the PR, the hold's reason and the action", () => {
  const r = read(station());
  const ch = chainsOk();
  ch.tickets[K(2)] = { key: K(2), state: "waits on you", chains: [], badges: [], more: 0, links: [{ on: null, kind: "operator", status: "open", reason: "pick the budget for the paid run", owner: "chief" }] } as never;
  ch.tickets[K(5)] = { ...ch.tickets[K(5)], links: [{ on: null, kind: "chain-order", status: "open", reason: "waits for step 1", owner: "chief" }] } as never; // not the operator's
  const prs = { state: "ok", prs: { [K(2)]: [{ pr: 4958, head: "a".repeat(40), ci: "green" }] }, seen: {}, unread: [] };
  const sec = waitingSec(renderBoard(r, owedUi, { drift: null, chains: ch, prs }));
  expect(sec).toContain("Orphaned work"); // the held ticket's title
  expect(sec).toContain("PR #4958");
  expect(sec).toContain("pick the budget for the paid run");
  expect(sec).toContain("Action:");
  expect(sec).not.toContain("waits for step 1");
});

test("Board: a chief doc line naming a ticket joins that ticket's row, and a HANDOFF item naming none is a row of its own, each with the action", () => {
  const r = read(station());
  const items = [
    { source: "chief doc", key: K(5), title: "Resumed work", ctx: "HIMMEL-5 operator sign-off before the merge", act: "the operator acts on what the line names" },
    { source: "handoff", key: null, title: "9271: run the apply at the station", ctx: "VE-HANDOFF.md", act: "answer the open item" },
  ];
  const sec = waitingSec(renderBoard(r, owedUi, { drift: null, chains: noChains, owed: { state: "ok", items, unread: [] } }));
  expect(sec).toContain("Resumed work");
  expect(sec).toContain("operator sign-off before the merge");
  expect(sec).toContain("9271: run the apply at the station");
  expect(sec).toContain("Action: answer the open item");
  expect(sec.match(/<li>/g)!.length).toBe(2);
});

test("readOwed: reads the unsigned specs, the newest chief doc's lines naming the operator and the newest HANDOFF's open items; an unreadable source is named, none readable is absent", async () => {
  const { readOwed } = await import("../board");
  const s = station();
  // the running version is v1.1.2: tickets 1, 2, 5 and 7 are open there, 3 is Done in v1.1.1
  const bucket = join(s.d, "ho", "u", "himmel");
  const designs = join(bucket, "specs", "designs"), rel = join(bucket, "release", "v1.1.2");
  mkdirSync(designs, { recursive: true }); mkdirSync(rel, { recursive: true });
  const critic = (name: string, n: number, last: string) => writeFileSync(join(designs, `${name}.critic-spec-r${n}.md`), `# round ${n}\n\nnotes\n\n${last}\n`);
  critic("HIMMEL-1-clean-unsigned.md", 1, "SPEC CLEAN");          // owed
  critic("HIMMEL-2-signed.md", 1, "SPEC CLEAN");                  // signed below
  critic("HIMMEL-5-still-in-review", 1, "SPEC FINDINGS 2");       // the critics are not done: not yet the operator's
  critic("HIMMEL-7-capped", 3, "SPEC FINDINGS 1");                // past the round cap: owed
  critic("HIMMEL-3-shipped.md", 1, "SPEC CLEAN");                 // its ticket is Done
  writeFileSync(join(rel, "operator.jsonl"), `${JSON.stringify({ kind: "spec", keys: [K(2)], spec_path: join(designs, "HIMMEL-2-signed.md") })}\nnot json\n`);
  writeFileSync(join(bucket, "HIMMEL-nextleg-2026-11-08VE-roadmap-chief.md"),
    "# VE\n\n## Live state\n\nworkers: x\nqueue: HIMMEL-5 merge waits for operator sign-off | HIMMEL-9 runs by itself\npool-disposition: HIMMEL-4 parked until the operator words arrive\n\n## Current direction\n");
  writeFileSync(join(bucket, "HIMMEL-nextleg-2026-11-08VE-roadmap-chief-HANDOFF.md"), "# h\n\n## Open operator items\n\n- 9271: run the apply at the station\n- none\n\n## Next\n");
  const env = { PATH: process.env.PATH, HOME: s.d, HIMMEL_JIRA_MIRROR: s.mirror, HANDOVER_DIR: join(s.d, "ho"), JIRA_PROJECT_KEY: "HIMMEL" };
  const o = readOwed(env);
  if (o.state !== "ok") throw new Error(o.reason);
  expect(o.unread).toEqual([]);
  expect(o.items.filter((i) => i.source === "unsigned spec").map((i) => [i.key, i.title])).toEqual([[K(1), "Roadmap in the ui"], [K(7), "Ready work"]]);
  expect(o.items.find((i) => i.key === K(1))!.ctx).toContain("latest critic round 1 reads SPEC CLEAN");
  expect(o.items.find((i) => i.key === K(7))!.ctx).toContain("latest critic round 3 reads SPEC FINDINGS 1");
  const chief = o.items.filter((i) => i.source === "chief doc");
  expect(chief.map((i) => i.key)).toEqual([K(5), null]); // 4 is Done in v1.1.1, so its title is the line itself
  expect(chief[0].title).toBe("Resumed work");
  expect(o.items.filter((i) => i.source === "handoff").map((i) => i.title)).toEqual(["9271: run the apply at the station"]);
  // no HANDOFF: that source is named, the others still read
  rmSync(join(bucket, "HIMMEL-nextleg-2026-11-08VE-roadmap-chief-HANDOFF.md"));
  const part = readOwed(env);
  expect(part.state === "ok" && part.unread).toEqual(["handoff items"]);
  // no handover root and no chief doc: nothing is readable, so the answer is absent with the reasons
  const none = readOwed({ ...env, HANDOVER_DIR: join(s.d, "no-ho") });
  expect(none.state).toBe("absent");
});
