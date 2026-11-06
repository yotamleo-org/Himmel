// shift.ts — the shift helper: the cut rule, shifts.jsonl under one writer, the span-and-attribution function.
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULTS, appendShift, attribute, chiefSpans, iso, liveBoards, liveChiefs, mergedIn, nameOf, readLocks, readMerged, readShifts, redactShift, rowsOf, step, tick, viewOf, type Lock, type Row, type Span, type State, type View } from "../shift";
import { redactDeep } from "../../himmelctl/lib/redact.js";
import { applySection } from "../../handover/chief-kit/board-section.mjs";
import { renderShift } from "../public/shift.js";
import { startServer } from "../server";

const OFF = 60; // +01:00, the zone fixed when a shift opens
const T = (s: string) => Date.parse(s);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "shift-")); cleanups.push(() => rmSync(d, { recursive: true, force: true })); return d; };
const row = (id: string, extra: Partial<Row> = {}): Row => ({ id, name: "day", opened: id, closed: "2026-10-27T20:00+01:00", why: "cut", zone: "+01:00", chiefs: [], buckets: ["himmel"], gap: [], ...extra });

test("a fleet idle for 60 minutes closes the shift at the last lock release, not 60 minutes later", () => {
  let st: State = { open: { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T14:00+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  // 14:10: a worker lock is still held, so the shift stays open and the last release moves to now
  let r = step(st, { now: T("2026-10-27T14:10+01:00"), locks: [{ bucket: "himmel", role: "worker", at: T("2026-10-27T14:10+01:00") }], lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed).toBeUndefined();
  st = r.state;
  // 15:10: nothing held for 60 minutes: closed at 14:10, the last release
  r = step(st, { now: T("2026-10-27T15:10+01:00"), locks: [], lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed?.closed).toBe("2026-10-27T14:10+01:00");
  expect(r.closed?.why).toBe("idle");
  expect(r.state.open).toBeNull();
});

test("a shift is not closed before the 60 minutes have passed", () => {
  const st: State = { open: { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T14:10+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  const r = step(st, { now: T("2026-10-27T15:09+01:00"), locks: [], lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed).toBeUndefined();
});

test("a WRAPPED stamp newer than the last seen lock is the last release", () => {
  const st: State = { open: { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T13:00+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  const r = step(st, { now: T("2026-10-27T15:00+01:00"), locks: [], lastEnd: T("2026-10-27T13:40+01:00"), chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed?.closed).toBe("2026-10-27T13:40+01:00");
});

test("a voice-bucket chief opens a shift and holds off the idle close", () => {
  const dir = tmp();
  const lock = join(dir, ".locks", "queue", "yotamleo__himmel-voice__HIMMEL-nextleg-2026-10-27A-voice-chief.lock");
  mkdirSync(lock, { recursive: true });
  writeFileSync(join(lock, "owner.json"), JSON.stringify({ session: "s", handover: join(dir, "yotamleo", "himmel-voice", "HIMMEL-nextleg-2026-10-27A-voice-chief.md"), heartbeat: "2026-10-27T10:00:00Z" }));
  const locks = readLocks(dir);
  expect(locks).toEqual([{ bucket: "himmel-voice", role: "chief", doc: "HIMMEL-nextleg-2026-10-27A-voice-chief", at: T("2026-10-27T10:00:00Z") }]);
  let r = step({ open: null, closedAt: null }, { now: T("2026-10-27T10:05:00Z"), locks, lastEnd: null, chiefLiveAt: T("2026-10-27T10:00:00Z") }, DEFAULTS, OFF);
  expect(r.state.open?.buckets).toEqual(["himmel-voice"]);
  expect(r.state.open?.opened).toBe(T("2026-10-27T10:00:00Z"));
  r = step(r.state, { now: T("2026-10-27T13:00:00Z"), locks, lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed).toBeUndefined();
});

test("the same shift id appended twice leaves one row", async () => {
  const f = join(tmp(), "shifts.jsonl");
  expect(await appendShift(f, row("2026-10-27T08:00+01:00"))).toBe("added");
  expect(await appendShift(f, row("2026-10-27T08:00+01:00"))).toBe("exists");
  expect(readFileSync(f, "utf8").trim().split("\n")).toHaveLength(1);
});

test("two concurrent writers leave one row per id", async () => {
  const f = join(tmp(), "shifts.jsonl");
  const code = `import { appendShift } from ${JSON.stringify(join(import.meta.dir, "../shift"))};
for (const id of ["a", "b", "c", "d"]) await appendShift(${JSON.stringify(f)}, { id, name: "day", opened: id, closed: id, why: "idle", zone: "+01:00", chiefs: [], buckets: [], gap: [] });`;
  const run = () => Bun.spawn(["bun", "-e", code], { stdout: "pipe", stderr: "pipe" });
  const procs = [run(), run(), run()];
  for (const p of procs) expect(await p.exited).toBe(0);
  const ids = readFileSync(f, "utf8").trim().split("\n").map((l) => JSON.parse(l).id).sort();
  expect(ids).toEqual(["a", "b", "c", "d"]);
});

test("tick with readOnly returns the recorded state and writes no state file or shift row; without it the same poll writes the state file", async () => {
  const d = tmp(), f = join(d, "shifts.jsonl"), now = T("2026-10-27T12:00+01:00");
  const snap = await tick({ root: d, file: f, now, readOnly: true, merged: async () => { throw new Error("a read-only poll reads no PR list"); } });
  expect(snap.state).toEqual({ open: null, closedAt: null });
  expect(snap.closed).toEqual([]);
  expect(readdirSync(d)).toEqual([]);
  await tick({ root: d, file: f, now, merged: async () => [] });
  expect(existsSync(`${f}.state.json`)).toBe(true);
});

test("a shift that closes after midnight is returned once, with ISO times that carry an offset", async () => {
  const f = join(tmp(), "shifts.jsonl");
  const r = row("2026-10-27T23:00+01:00", { name: "night", closed: "2026-10-28T01:30+01:00", why: "idle" });
  await appendShift(f, r); await appendShift(f, r);
  const rows = readShifts(f);
  expect(rows).toHaveLength(1);
  expect(rows[0].opened).toMatch(/T\d\d:\d\d[+-]\d\d:\d\d$/);
  expect(rows[0].closed).toMatch(/T\d\d:\d\d[+-]\d\d:\d\d$/);
  expect(T(rows[0].closed)).toBeGreaterThan(T(rows[0].opened));
});

test("iso writes the offset and names the shift by when it opened", () => {
  expect(iso(T("2026-10-27T20:00+01:00"), 60)).toBe("2026-10-27T20:00+01:00");
  expect(iso(T("2026-10-27T20:00+01:00"), -330)).toBe("2026-10-27T13:30-05:30");
  expect(nameOf(T("2026-10-27T19:30+01:00"), 60, DEFAULTS)).toBe("day");
  expect(nameOf(T("2026-10-27T20:00+01:00"), 60, DEFAULTS)).toBe("night");
  expect(nameOf(T("2026-10-28T07:59+01:00"), 60, DEFAULTS)).toBe("night");
  expect(nameOf(T("2026-10-28T08:00+01:00"), 60, DEFAULTS)).toBe("day");
});

test("a PR merged exactly at the close time is in the next shift, not this one", () => {
  const prs = [{ number: 1, mergedAt: "2026-10-27T19:59:59Z" }, { number: 2, mergedAt: "2026-10-27T20:00:00Z" }, { number: 3, mergedAt: "2026-10-27T08:00:00Z" }];
  const open = T("2026-10-27T08:00:00Z"), cut = T("2026-10-27T20:00:00Z");
  expect(mergedIn(prs, open, cut, cut + 1).map((p) => p.number)).toEqual([1, 3]);
  expect(mergedIn(prs, cut, null, cut + 1000).map((p) => p.number)).toEqual([2]);
});

test("a clock cut closes a shift once it has run 4 hours, and the next one opens at that minute", () => {
  const st: State = { open: { opened: T("2026-10-27T10:00+01:00"), lastHeld: T("2026-10-27T20:00+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  const lock = [{ bucket: "himmel", role: "worker" as const, at: T("2026-10-27T20:05+01:00") }];
  const r = step(st, { now: T("2026-10-27T20:05+01:00"), locks: lock, lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed?.closed).toBe("2026-10-27T20:00+01:00");
  expect(r.closed?.why).toBe("cut");
  expect(r.state.open?.opened).toBe(T("2026-10-27T20:00+01:00"));
});

test("a shift younger than 4 hours at a cut time runs on to the next cut", () => {
  const st: State = { open: { opened: T("2026-10-27T19:30+01:00"), lastHeld: T("2026-10-27T20:05+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  const lock = [{ bucket: "himmel", role: "worker" as const, at: T("2026-10-27T20:05+01:00") }];
  expect(step(st, { now: T("2026-10-27T20:05+01:00"), locks: lock, lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF).closed).toBeUndefined();
  const r = step(st, { now: T("2026-10-28T08:05+01:00"), locks: lock, lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed?.closed).toBe("2026-10-28T08:00+01:00");
});

const doc = (date: string, bullets: string[], pred?: string) => `# X — CHIEF${pred ? ` — successor to ${pred}.md` : ""} (${date})\n\n## Results\n${bullets.join("\n")}\n`;

test("a chief's span runs from its first LIVE to its last WRAPPED, a doc with no LIVE bullet starts at its predecessor's WRAPPED (approx)", () => {
  const spans = chiefSpans([
    { name: "A-chief", bucket: "himmel", text: doc("x", ["- 08:00 LIVE — a", "- 08:50 WRAPPED — done"]) },
    { name: "B-chief", bucket: "himmel", text: doc("x", ["- 09:30 WRAPPED — done"], "A-chief-2026-10-27") },
  ].map((d) => ({ ...d, name: `${d.name}-2026-10-27` })), OFF);
  const a = spans.find((s) => s.name === "A-chief-2026-10-27")!;
  const b = spans.find((s) => s.name === "B-chief-2026-10-27")!;
  expect(iso(a.start, OFF)).toBe("2026-10-27T08:00+01:00");
  expect(iso(a.end!, OFF)).toBe("2026-10-27T08:50+01:00");
  expect(a.approx).toBe(false);
  expect(iso(b.start, OFF)).toBe("2026-10-27T08:50+01:00");
  expect(b.approx).toBe(true);
});

test("stamps roll over at midnight", () => {
  const [s] = chiefSpans([{ name: "C-chief-2026-10-27", bucket: "himmel", text: doc("x", ["- 23:30 LIVE — a", "- 00:20 WRAPPED — done"]) }], OFF);
  expect(iso(s.end!, OFF)).toBe("2026-10-28T00:20+01:00");
});

test("a PR counts under the chief whose span holds its merge, a merge in a hand-over gap is named for both and counted once", () => {
  const spans = [
    { name: "A", bucket: "himmel", start: T("2026-10-27T08:00Z"), end: T("2026-10-27T09:00Z"), approx: false },
    { name: "B", bucket: "himmel", start: T("2026-10-27T09:20Z"), end: T("2026-10-27T10:00Z"), approx: false },
  ];
  const prs = [{ number: 1, mergedAt: "2026-10-27T08:30:00Z" }, { number: 2, mergedAt: "2026-10-27T09:10:00Z" }, { number: 3, mergedAt: "2026-10-27T09:30:00Z" }];
  const a = attribute(spans, prs, T("2026-10-27T11:00Z"));
  expect(a.perChief).toEqual({ A: [1, 2], B: [2, 3] });
  expect(a.gap).toEqual([{ pr: 2, chiefs: ["A", "B"] }]);
  expect(a.total).toBe(3);
});

// ---- the read: viewOf / rowsOf, and the page drawn from them ----
const board = {
  console: { name: "chief-A" },
  needs_you: [{ leg: "L1", verb: "go", action: "GO #12", detail: "", since: "2026-10-27T10:00:00Z" }, { leg: "L2", verb: "unblock", action: "answer the finding", since: "2026-10-27T09:00:00Z" }],
  legs: [
    { leg: "L1", ticket: "HIMMEL-1", goal: "one", state: "ready-for-go", stage: "go", pr: { number: 12 } },
    { leg: "L2", ticket: "HIMMEL-2", goal: "two", state: "blocked", stage: "live" },
    { leg: "L3", ticket: "HIMMEL-3", goal: "three", state: "working", stage: "live", stages: { live: "2026-10-27T08:30:00Z" } },
    { leg: "L4", ticket: "HIMMEL-4", goal: "four", state: "working", stage: "pr", stages: { live: "2026-10-27T08:00:00Z" }, pr: { number: 14 } },
    { leg: "L5", ticket: "HIMMEL-5", goal: "five", state: "working", stage: "merged" },
  ],
};
const open = { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T12:00+01:00"), buckets: ["himmel"], offsetMin: OFF };
const snap = (o: typeof open | null) => ({ state: { open: o, closedAt: null } as State, spans: [{ name: "chief-A", bucket: "himmel", start: T("2026-10-27T08:05+01:00"), end: null, approx: false }], locks: [], offsetMin: OFF });
const NOW = T("2026-10-27T12:00+01:00");

test("rowsOf: Waiting is only what the data marks as the operator's, Running is live and PR-open work that is not waiting, oldest first", () => {
  const r = rowsOf([{ ...board, decisions: ["pick the v1.1.3 cut?", "approve the spend"] }]);
  expect(r.waiting.map((w) => [w.kind, w.ticket, w.pr, w.detail])).toEqual([["decision", null, null, "pick the v1.1.3 cut?"], ["decision", null, null, "approve the spend"]]);
  expect(r.running.map((x) => [x.ticket, x.stage])).toEqual([["HIMMEL-4", "in review"], ["HIMMEL-3", "building"]]);
});

test("rowsOf: a go, decide, unblock or act row addressed to the chief never lands in Waiting on you", () => {
  const legs = [1, 2, 3, 4].map((n) => ({ leg: `L${n}`, ticket: `HIMMEL-${n}`, goal: "g", state: "working", stage: "live" }));
  const needs_you = [{ leg: "L1", verb: "go", action: "judge and GO PR #12" }, { leg: "L2", verb: "decide", action: "rule on the FINDING" }, { leg: "L3", verb: "unblock", action: "clear the BLOCKED worker" }, { leg: "L4", verb: "act", action: "close the worker window" }];
  const r = rowsOf([{ console: { name: "chief-A" }, legs, needs_you }]);
  expect(r.waiting).toEqual([]);
  expect(r.running).toEqual([]); // a worker the chief owes a step is not Running either
});

test("viewOf: an open shift lists chiefs, Waiting, Running and the PRs merged inside it, named for the chief whose span holds the merge", () => {
  const merged = [{ number: 20, title: "feat: a", mergedAt: "2026-10-27T09:00:00Z" }, { number: 21, title: "fix: b", mergedAt: "2026-10-27T06:00:00Z" }];
  const v = viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged, boards: [board] });
  expect(v.state).toBe("open");
  expect(v.shift?.name).toBe("day");
  expect(v.shift?.id).toBe("2026-10-27T08:00+01:00");
  expect(v.waiting.length).toBe(0); // the fixture board's go and question rows are the chief's
  expect(v.shipped.map((s) => s.number)).toEqual([20]); // 21 merged at 07:00+01:00, before the shift opened
  expect(v.shipped[0].chief).toBe("chief-A");
});

test("viewOf: no open shift is the empty state with a last-shift line", () => {
  const rows = [row("2026-10-27T08:00+01:00", { chiefs: [{ name: "A", bucket: "himmel", span: { start: "x", end: null, approx: false }, prs: [1, 2] }] })];
  const v = viewOf({ now: T("2026-10-27T22:00+01:00"), rows, snap: snap(null), id: null, merged: [], boards: [] });
  expect(v.state).toBe("idle");
  expect(v.last).toMatchObject({ id: "2026-10-27T08:00+01:00", chiefs: 1, shipped: 2 });
  expect(v.waiting).toEqual([]);
});

test("viewOf: a closed shift by id carries its record, its merges are half-open at the close and its pager links the neighbours", () => {
  const rows = [row("2026-10-26T20:00+01:00", { name: "night", closed: "2026-10-27T08:00+01:00" }), row("2026-10-27T08:00+01:00"), row("2026-10-27T20:00+01:00", { name: "night", closed: "2026-10-28T08:00+01:00" })];
  const merged = [{ number: 1, title: "t", mergedAt: "2026-10-27T19:00:00Z" }, { number: 2, title: "t", mergedAt: "2026-10-27T07:00:00Z" }];
  const v = viewOf({ now: T("2026-10-29T00:00+01:00"), rows, snap: snap(null), id: "2026-10-27T08:00+01:00", merged, boards: [] });
  expect(v.shift?.closed).toBe("2026-10-27T20:00+01:00");
  expect(v.shipped.map((s) => s.number)).toEqual([2]); // 1 merged at exactly 20:00+01:00: the next shift's
  expect(v.pager).toEqual({ prev: "2026-10-26T20:00+01:00", next: "2026-10-27T20:00+01:00" });
});

const pageView = (over: Partial<View> = {}): View => ({ ...viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged: [{ number: 20, title: "feat: a", mergedAt: "2026-10-27T09:00:00Z" }], boards: [{ ...board, decisions: ["pick the v1.1.3 cut?"] }] }), ...over });

test("the Shift page draws Waiting, Running and Shipped over a mid-shift fixture, Waiting rows only link out", () => {
  const html = renderShift(pageView(), {});
  for (const id of ["sh-waiting", "sh-running", "sh-shipped"]) expect(html).toContain(`id="${id}"`);
  expect(html).toContain("pick the v1.1.3 cut?");
  expect(html).toContain('<h2 id="h-sh-waiting">Waiting on you <b>1</b></h2>'); // the operator-owned rows only; the fixture board's go and question rows are the chief's
  expect(html).not.toContain("judge and GO");
  expect(html).toContain("#20");
  expect(html).not.toContain("<button"); // Waiting rows link out; nothing here acts
  expect(html).not.toContain("No shift is open");
});

test("the Shift page with no open shift says so and names the last shift", () => {
  const rows = [row("2026-10-27T08:00+01:00")];
  const html = renderShift(viewOf({ now: T("2026-10-27T22:00+01:00"), rows, snap: snap(null), id: null, merged: [], boards: [] }), {});
  expect(html).toContain("No shift is open");
  expect(html).toContain("2026-10-27");
  expect(html).toContain("A shift opens when a chief goes live.");
  expect(html).not.toContain("takes a queue lock");
  expect(html).not.toContain('id="sh-waiting"');
});

test("the Shift page escapes what boards and PR titles carry", () => {
  const html = renderShift(pageView({ shipped: [{ number: 9, title: "<img src=x onerror=1>", mergedAt: "2026-10-27T09:00:00Z", chief: null }] }), {});
  expect(html).not.toContain("<img src=x");
  expect(html).toContain("&lt;img");
});

test("the Shift page escapes a persisted stamp and shipped count that carry markup", () => {
  const bad = "<img src=x onerror=1>";
  const rows = [row("2026-10-27T08:00+01:00", { closed: bad })];
  const closedHtml = renderShift(viewOf({ now: T("2026-10-29T00:00+01:00"), rows: [{ ...rows[0], opened: bad, closed: bad }], snap: snap(null), id: bad, merged: [], boards: [] }), {});
  const idle = viewOf({ now: T("2026-10-27T22:00+01:00"), rows: [row("2026-10-27T08:00+01:00")], snap: snap(null), id: null, merged: [], boards: [] });
  const idleHtml = renderShift({ ...idle, last: { ...idle.last!, shipped: bad as unknown as number } }, {});
  for (const html of [closedHtml, idleHtml]) expect(html).not.toContain("<img src=x");
  expect(idleHtml).toContain("&lt;img");
});

test("the Shift page links nowhere that does not exist yet", () => {
  expect(renderShift(pageView(), {})).not.toContain("morning-report");
});

test("a closed shift draws the pager and Carried to the next shift", () => {
  const v = viewOf({ now: T("2026-10-29T00:00+01:00"), rows: [row("2026-10-26T20:00+01:00"), row("2026-10-27T08:00+01:00", { carried: [{ ticket: "HIMMEL-7", title: "left over", stage: "in review", pr: 30 }] })], snap: snap(null), id: "2026-10-27T08:00+01:00", merged: [], boards: [] });
  const html = renderShift(v, {});
  expect(html).toContain('href="#/shift/2026-10-26T20%3A00%2B01%3A00"');
  expect(html).toContain('id="sh-carried"');
  expect(html).toContain("HIMMEL-7");
});

// ---- GET /api/shift ----
const TOKEN = "t".repeat(64);
const MIN_MS = 60_000;
const STUB = join(import.meta.dir, "stub-himmelctl.js");
// board: the chief's board file, written beside its doc as board.mjs does; none = the chief has not rendered one.
// boardScript is not a server option any more: the one row that passes it proves the server never runs it.
function boot(opts: { rows?: Row[]; chief?: boolean; prs?: unknown[]; ghFails?: boolean; board?: unknown; boardScript?: string }) {
  const dir = tmp();
  let name = "";
  const root = join(dir, "root"), home = join(dir, "home");
  mkdirSync(home); mkdirSync(root);
  const file = join(dir, "shifts.jsonl");
  if (opts.rows) writeFileSync(file, opts.rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  if (opts.chief) {
    // a chief doc dated today whose LIVE bullet is two minutes old, and the lock it holds
    const at = new Date(Date.now() - 2 * MIN_MS), p2 = (n: number) => String(n).padStart(2, "0");
    name = `HIMMEL-nextleg-${at.getFullYear()}-${p2(at.getMonth() + 1)}-${p2(at.getDate())}A-roadmap-chief`;
    mkdirSync(join(root, "yotamleo", "himmel"), { recursive: true });
    writeFileSync(join(root, "yotamleo", "himmel", `${name}.md`), doc("x", [`- ${p2(at.getHours())}:${p2(at.getMinutes())} LIVE — up`]));
    if (opts.board !== undefined) writeFileSync(join(root, "yotamleo", "himmel", `${name}.board.json`), JSON.stringify(opts.board));
    const lock = join(root, ".locks", "queue", `yotamleo__himmel__${name}.lock`);
    mkdirSync(lock, { recursive: true });
    writeFileSync(join(lock, "owner.json"), JSON.stringify({ session: "s", handover: join(root, "yotamleo", "himmel", `${name}.md`), heartbeat: new Date().toISOString() }));
  }
  writeFileSync(join(dir, "prs.json"), JSON.stringify(opts.prs ?? []));
  const gh = join(dir, "gh.sh");
  writeFileSync(gh, opts.ghFails ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\necho x >> " + join(dir, "gh-calls") + "\ncat " + join(dir, "prs.json") + "\n", { mode: 0o755 });
  const serverOpts = { onIdle: () => {}, port: 0, token: TOKEN, boardScript: opts.boardScript, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, SHIFTS_FILE: file, GH_CMD: gh } };
  const s = startServer(serverOpts);
  cleanups.push(() => s.stop());
  return { s, file, dir, root, name };
}
const getShift = (port: number, q = "", init: RequestInit = { headers: { "X-Himmel-Token": TOKEN } }) => fetch("http://127.0.0.1:" + port + "/api/shift" + q, init);

test("GET /api/shift: no token is 401, a POST is 405, a malformed id is 400", async () => {
  const { s } = boot({});
  expect((await getShift(s.port, "", {})).status).toBe(401);
  expect((await getShift(s.port, "", { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  expect((await getShift(s.port, "?id=../../etc")).status).toBe(400);
});

test("GET /api/shift: a chief holding a lock opens a shift and the PRs gh lists land in Shipped", async () => {
  const merged = new Date().toISOString();
  const { s, file } = boot({ chief: true, prs: [{ number: 77, title: "feat: x", mergedAt: merged, headRefName: "b" }] });
  const v = await (await getShift(s.port)).json();
  expect(v.state).toBe("open");
  expect(v.shipped.map((p: { number: number }) => p.number)).toEqual([77]);
  expect(v.buckets).toEqual(["himmel"]);
  expect(readShifts(file)).toEqual([]); // still open: nothing is written until it closes
});

test("GET /api/shift reads an already open shift's merged PRs once per request", async () => {
  const { s, dir } = boot({ chief: true, prs: [] });
  const calls = () => readFileSync(join(dir, "gh-calls"), "utf8").trim().split("\n").length;
  await (await getShift(s.port)).json(); // the first poll opens the shift
  const before = calls();
  await (await getShift(s.port)).json();
  expect(calls() - before).toBe(1);
});

test("GET /api/shift?id=: a closed shift comes back with its record and the merges inside its window only", async () => {
  const r = row("2026-10-27T08:00+01:00", { closed: "2026-10-27T20:00+01:00" });
  const prs = [{ number: 1, title: "in", mergedAt: "2026-10-27T10:00:00Z" }, { number: 2, title: "at the close", mergedAt: "2026-10-27T19:00:00Z" }];
  const { s } = boot({ rows: [r], prs });
  const v = await (await getShift(s.port, "?id=" + encodeURIComponent(r.id))).json();
  expect(v.shift.closed).toBe("2026-10-27T20:00+01:00");
  expect(v.shipped.map((p: { number: number }) => p.number)).toEqual([1]);
});

test("GET /api/shift with no open shift and no locks is the empty state naming the last shift", async () => {
  const { s } = boot({ rows: [row("2026-10-27T08:00+01:00")] });
  const v = await (await getShift(s.port)).json();
  expect(v.state).toBe("idle");
  expect(v.last.id).toBe("2026-10-27T08:00+01:00");
});

// ---- the poll under failure and overlap ----
const writeState = (file: string, open: { opened: number; lastHeld: number }, at?: number) =>
  writeFileSync(file + ".state.json", JSON.stringify({ open: { ...open, buckets: ["himmel"], offsetMin: OFF }, closedAt: null, at }));

test("a shift cut while the fleet is idle opens no successor, so nothing closes before it opened", () => {
  const st: State = { open: { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T19:30+01:00"), buckets: ["himmel"], offsetMin: OFF }, closedAt: null };
  const r = step(st, { now: T("2026-10-27T21:00+01:00"), locks: [], lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(r.closed?.closed).toBe("2026-10-27T20:00+01:00");
  expect(r.closed?.why).toBe("cut");
  expect(r.state.open).toBeNull();
  const again = step(r.state, { now: T("2026-10-27T22:00+01:00"), locks: [], lastEnd: null, chiefLiveAt: null }, DEFAULTS, OFF);
  expect(again.closed).toBeUndefined();
});

test("a failed merged-PR read closes no shift, and the next good read records its PRs", async () => {
  const dir = tmp(), file = join(dir, "shifts.jsonl");
  writeState(file, { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T10:00+01:00") });
  const now = T("2026-10-27T12:00+01:00"); // idle for two hours: the close is due
  await tick({ root: dir, file, now, merged: async () => null });
  expect(readShifts(file)).toEqual([]);
  const r = await tick({ root: dir, file, now, merged: async () => [{ number: 5, mergedAt: "2026-10-27T09:00:00Z" }] });
  expect(r.closed.length).toBe(1);
  expect(readShifts(file).length).toBe(1);
});

test("a poll older than the last one applied leaves the shift's last release where it was", async () => {
  const dir = tmp(), file = join(dir, "shifts.jsonl");
  const lock = join(dir, ".locks", "queue", "yotamleo__himmel__HIMMEL-9-w.lock");
  mkdirSync(lock, { recursive: true });
  writeFileSync(join(lock, "owner.json"), JSON.stringify({ session: "s", handover: join(dir, "yotamleo", "himmel", "HIMMEL-9-w.md"), heartbeat: "2026-10-27T10:00:00Z" }));
  const later = T("2026-10-27T12:00+01:00");
  writeState(file, { opened: T("2026-10-27T08:00+01:00"), lastHeld: later }, later);
  const r = await tick({ root: dir, file, now: T("2026-10-27T11:59+01:00"), merged: async () => [] });
  expect(r.state.open?.lastHeld).toBe(later);
});

test("the Shift page's PR and Fleet links go to the Fleet page it is given, not to a route that does not exist", () => {
  const html = renderShift(pageView(), { fleet: "/agui/#t=abc" });
  expect(html).toContain('href="/agui/#t=abc"');
  expect(html).not.toContain('href="#/fleet"');
});

test("a closed shift's continuing chief ends at the close, not at now", () => {
  const chief = { name: "HIMMEL-nextleg-2026-10-27A-roadmap-chief", bucket: "himmel", span: { start: "2026-10-27T08:00+01:00", end: null, approx: false }, prs: [] };
  const v = viewOf({ now: T("2026-10-29T00:00+01:00"), rows: [row("2026-10-27T08:00+01:00", { chiefs: [chief] })], snap: snap(null), id: "2026-10-27T08:00+01:00", merged: [], boards: [] });
  const html = renderShift(v, {});
  expect(html).not.toContain("to now");
  expect(html).toContain("to 20:00");
});

// ---- who is live, a full gh page, an unreadable PR list ----
test("only the chief doc that holds a lock is live: an older unwrapped doc in the same bucket is not", () => {
  const span = (name: string) => ({ name, bucket: "himmel", start: T("2026-10-27T08:00Z"), end: null, approx: false });
  const locks = [{ bucket: "himmel", role: "chief" as const, doc: "B-chief", at: T("2026-10-27T10:00Z") }];
  expect(liveChiefs([span("A-chief"), span("B-chief")], locks).map((s) => s.name)).toEqual(["B-chief"]);
  expect(liveChiefs([span("B-chief")], [{ ...locks[0], role: "worker" as const }])).toEqual([]);
});

test("a full gh page is split until every PR is read, so a busy shift is never recorded short", async () => {
  const dir = tmp();
  const base = T("2026-10-27T08:00:00Z"), N = 250;
  writeFileSync(join(dir, "prs.json"), JSON.stringify(Array.from({ length: N }, (_, i) => ({ number: i + 1, title: "t", mergedAt: new Date(base + i * MIN_MS).toISOString() }))));
  const gh = join(dir, "gh.js");
  writeFileSync(gh, `#!/usr/bin/env bun
import { readFileSync } from "node:fs";
const a = process.argv, m = /merged:(\\S+)\\.\\.(\\S+)/.exec(a[a.indexOf("--search") + 1]);
const lo = Date.parse(m[1]), hi = Date.parse(m[2]);
const all = JSON.parse(readFileSync(process.env.GH_PRS, "utf8"));
console.log(JSON.stringify(all.filter((p) => { const t = Date.parse(p.mergedAt); return t >= lo && t <= hi; }).slice(0, Number(a[a.indexOf("--limit") + 1]))));
`, { mode: 0o755 });
  const prs = await readMerged({ PATH: process.env.PATH, GH_CMD: gh, GH_PRS: join(dir, "prs.json") }, dir, base, base + N * MIN_MS);
  expect(prs?.map((p) => p.number).sort((x, y) => x - y)).toEqual(Array.from({ length: N }, (_, i) => i + 1));
});

test("a merged-PR list that could not be read is said so on the page, never shown as an empty shift", () => {
  const v = viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged: null, boards: [board] });
  expect(v.mergedUnread).toBe(true);
  const html = renderShift(v, {});
  expect(html).toContain("could not be read");
  expect(html).not.toContain("Nothing merged in this shift");
  expect(viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged: [], boards: [board] }).mergedUnread).toBe(false);
});

test("a chief doc that never wrapped and holds no lock ends at its last stamp, so it is not credited with later merges", () => {
  const d = { name: "A-chief-2026-10-27", bucket: "himmel", text: doc("x", ["- 08:00 LIVE — a", "- 09:00 progress"]) };
  expect(iso(chiefSpans([d], OFF, new Set())[0].end!, OFF)).toBe("2026-10-27T09:00+01:00");
  expect(chiefSpans([d], OFF, new Set(["A-chief-2026-10-27"]))[0].end).toBeNull();
  expect(chiefSpans([d], OFF)[0].end).toBeNull();
});

test("a closed shift records every PR merged in it, and the last-shift line counts them all", async () => {
  const dir = tmp(), file = join(dir, "shifts.jsonl");
  writeState(file, { opened: T("2026-10-27T08:00+01:00"), lastHeld: T("2026-10-27T10:00+01:00") });
  await tick({ root: dir, file, now: T("2026-10-27T12:00+01:00"), merged: async () => [{ number: 5, title: "t", mergedAt: "2026-10-27T08:30:00Z" }] });
  const [r] = readShifts(file);
  expect(r.shipped).toBe(1); // no chief span holds it, so no chief is credited
  expect(r.chiefs).toEqual([]);
  expect(viewOf({ now: T("2026-10-27T22:00+01:00"), rows: [r], snap: snap(null), id: null, merged: [], boards: [] }).last?.shipped).toBe(1);
});

test("refreshing a closed shift stays on that shift, and an unread PR list shows no count", () => {
  const closedView = viewOf({ now: T("2026-10-29T00:00+01:00"), rows: [row("2026-10-27T08:00+01:00")], snap: snap(null), id: "2026-10-27T08:00+01:00", merged: [], boards: [] });
  expect(renderShift(closedView, {})).toContain('href="#/shift/2026-10-27T08%3A00%2B01%3A00" data-act="refresh-shift"');
  expect(renderShift(pageView(), {})).toContain('href="#/shift" data-act="refresh-shift"');
  const unread = renderShift(pageView({ mergedUnread: true, shipped: [] }), {});
  expect(unread).not.toContain("Shipped this shift <b>0</b>");
  expect(unread).toContain("Shipped this shift</h2>");
});

test("GET /api/shift: a gh failure comes back as an unread PR list, not an empty one", async () => {
  const { s } = boot({ chief: true, ghFails: true });
  const v = await (await getShift(s.port)).json();
  expect(v.state).toBe("open");
  expect(v.mergedUnread).toBe(true);
});

// ---- the redactor keeps a chief's doc name readable and nothing else ----
const LONG_RUN36 = "aB3dE5gH7jK9".repeat(3); // 36 letters and digits, the redactor long-run shape
const chiefView = (chief: string): View => ({
  ...pageView(),
  chiefs: [{ name: chief, bucket: "himmel", span: { start: "2026-10-27T08:00+01:00", end: null, approx: false }, prs: [] }],
  waiting: [{ kind: "GO", ticket: null, title: "t", detail: "d", since: null, pr: null, chief }],
  shipped: [{ number: 1, title: "x", mergedAt: "2026-10-27T09:00:00Z", chief }],
  gap: [{ pr: 1, chiefs: [chief, chief] }],
});

test("GET /api/shift: a live chief's 40-character doc name comes back readable", async () => {
  const { s } = boot({ chief: true });
  const v = await (await getShift(s.port)).json();
  expect(v.chiefs[0].name).toMatch(/^HIMMEL-nextleg-\d{4}-\d{2}-\d{2}A-roadmap-chief$/);
  expect(v.chiefs[0].name.length).toBeGreaterThanOrEqual(32);
});

test("redactShift: a strict chief doc name passes in every chief-name field, a 32+ character random token in the same fields is still redacted", () => {
  const real = "HIMMEL-nextleg-2026-10-31LO-roadmap-chief";
  const ok = redactShift(chiefView(real), redactDeep);
  expect([ok.chiefs[0].name, ok.waiting[0].chief, ok.shipped[0].chief, ...ok.gap[0].chiefs]).toEqual([real, real, real, real, real]);
  for (const bad of ["HIMMEL-" + LONG_RUN36, "HIMMEL-nextleg-2026-10-31A-" + LONG_RUN36 + "-chief", real + "-" + LONG_RUN36]) {
    const out = redactShift(chiefView(bad), redactDeep);
    expect([out.chiefs[0].name, out.waiting[0].chief, out.shipped[0].chief, ...out.gap[0].chiefs]).toEqual(Array(5).fill("‹redacted›"));
  }
});

test("redactShift: a doc name in a free-text field stays readable", () => {
  const real = "HIMMEL-nextleg-2026-10-31LO-roadmap-chief";
  const v = chiefView(real);
  v.waiting[0].title = real;
  v.shipped[0].title = real;
  const out = redactShift(v, redactDeep);
  expect([out.waiting[0].title, out.shipped[0].title]).toEqual([real, real]);
});

test("redactShift: a doc name after a prefix stays readable, a doc-name shape that carries a token shape or a random run is still redacted", () => {
  const real = "HIMMEL-nextleg-2026-10-31LO-roadmap-chief";
  const aws = "AK" + "IA" + "ABCDEFGHIJKLMNOP"; // an access-key shape built at run time
  const fields = (v: View) => [v.chiefs[0].name, v.waiting[0].chief, v.shipped[0].chief, ...v.gap[0].chiefs];
  const viaToken = fields(redactShift(chiefView(aws + "-nextleg-2026-10-31A-roadmap-chief"), redactDeep));
  for (const f of viaToken) expect(f).not.toContain(aws);
  for (const f of fields(redactShift(chiefView("abc " + real), redactDeep))) expect(f).toContain(real);
  for (const bad of ["abc " + LONG_RUN36, "Zx-" + LONG_RUN36]) {
    for (const f of fields(redactShift(chiefView(bad), redactDeep))) expect(f).not.toContain(LONG_RUN36);
  }
});

// ---- the populated page reads like mockup v3 ----
const LONG_CHIEF = "HIMMEL-nextleg-2026-11-01AB-roadmap-chief";
const busyView = () => pageView({
  chiefs: [{ name: LONG_CHIEF, bucket: "himmel", span: { start: "2026-10-27T08:05+01:00", end: null, approx: false }, prs: [4507] }],
  shipped: [{ number: 4507, title: "fix(ui): [HIMMEL-8606] fixture PR 7", mergedAt: "2026-10-27T09:00:00Z", chief: LONG_CHIEF }],
});

test("a shipped row is the ticket link and the plain title, with the PR and merge time under it and no chief name", () => {
  const html = renderShift(busyView(), {});
  const shipped = html.slice(html.indexOf('id="sh-shipped"'));
  expect(shipped).toContain('<a href="#/roadmap">HIMMEL-8606</a>');
  expect(shipped).toContain("<b>fixture PR 7</b>");
  expect(shipped).not.toContain("fix(ui)");
  expect(shipped).not.toContain("[HIMMEL-8606]");
  expect(shipped).toContain("#4507");
  expect(shipped).toContain("merged 09:00");
  expect(shipped).not.toContain(LONG_CHIEF);
});

test("a shipped title with no commit prefix or key keeps its text and shows no key link", () => {
  const html = renderShift(pageView({ shipped: [{ number: 9, title: "just words", mergedAt: "2026-10-27T09:00:00Z", chief: null }] }), {});
  const from = html.indexOf('id="sh-shipped"');
  const shipped = html.slice(from, html.indexOf("</section>", from));
  expect(shipped).toContain("<b>just words</b>");
  expect(shipped).not.toContain('<a href="#/roadmap">');
});

test("a shipped title whose prefix is not a commit type keeps the whole prefix", () => {
  const html = renderShift(pageView({ shipped: [{ number: 9, title: "Authentication: reject expired tokens", mergedAt: "2026-10-27T09:00:00Z", chief: null }] }), {});
  const from = html.indexOf('id="sh-shipped"');
  expect(html.slice(from, html.indexOf("</section>", from))).toContain("<b>Authentication: reject expired tokens</b>");
});

test("the chief strip labels a segment with its doc's run letters, the full name stays in the hover", () => {
  const html = renderShift(busyView(), {});
  const chiefs = html.slice(html.indexOf('id="sh-chiefs"'), html.indexOf('id="sh-waiting"'));
  expect(chiefs).toMatch(/<td class="cseg[^"]*"[^>]*>AB<small>1<\/small><\/td>/);
  expect(chiefs).not.toMatch(/>[^<]*HIMMEL-nextleg[^<]*<small>/);
  expect(chiefs).toContain(`title="${LONG_CHIEF}:`);
});

test("an open shift draws the shift-open pill, the updated line and the Not here footer, and Running and Shipped share a two-column row", () => {
  const html = renderShift(busyView(), {});
  expect(html).toContain("shift open");
  expect(html).toContain("updated 12:00"); // opened 08:00+01:00 with 240 minutes in the pageView shift, in the shift's own zone
  expect(html).toContain("Not here, on purpose:");
  const cols = html.slice(html.indexOf('<div class="sh-cols">'));
  expect(cols.indexOf('id="sh-running"')).toBeGreaterThan(-1);
  expect(cols.indexOf('id="sh-shipped"')).toBeGreaterThan(cols.indexOf('id="sh-running"'));
  expect(html.slice(0, html.indexOf('<div class="sh-cols">'))).not.toContain('id="sh-shipped"');
});

test("a closed shift has no shift-open pill and no updated line", () => {
  const v = viewOf({ now: T("2026-10-29T00:00+01:00"), rows: [row("2026-10-27T08:00+01:00")], snap: snap(null), id: "2026-10-27T08:00+01:00", merged: [], boards: [] });
  const html = renderShift(v, {});
  expect(html).not.toContain("shift open");
  expect(html).not.toContain("updated ");
});

// ---- the Shift page reads the board through the Fleet route's reader: the chief's board file ----
// a board file with one live leg, as board.mjs writes it beside the chief doc
const fileBoard = { console: { name: "stub-chief" }, legs: [{ leg: "L1", ticket: "HIMMEL-1", goal: "one live leg", state: "working", stage: "live", stages: { live: "2026-10-27T08:00:00Z" } }], needs_you: [] };

test("GET /api/shift: a live chief with a board file shows the legs in it, not an empty Running list", async () => {
  const { s } = boot({ chief: true, board: fileBoard });
  const v = await (await getShift(s.port)).json();
  expect(v.running.length).toBe(1);
  expect(v.running[0].ticket).toBe("HIMMEL-1");
  expect(v.boardMissing).toEqual([]);
});

const chiefLocks = (name: string, at = Date.now()): Lock[] => [{ bucket: "himmel", role: "chief", doc: name, at }];
const chiefSpan = (name: string): Span[] => [{ name, bucket: "himmel", start: 0, end: null, approx: false }];
const liveLeg = { leg: "L1", ticket: "HIMMEL-1", goal: "one live leg", state: "working", stage: "live", stages: { live: "2026-10-27T08:00:00Z" } };
function chiefDocIn(root: string, name: string) {
  mkdirSync(join(root, "yotamleo", "himmel"), { recursive: true });
  writeFileSync(join(root, "yotamleo", "himmel", `${name}.md`), "x");
}

test("liveBoards: the injected reader decides: a board gives rows, null gives boardMissing, an error gives boardError", async () => {
  const root = tmp(), name = "HIMMEL-nextleg-2026-10-27A-roadmap-chief";
  chiefDocIn(root, name);
  const ok = await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => ({ legs: [liveLeg] }));
  expect(rowsOf(ok.boards).running.length).toBe(1);
  expect([ok.missing, ok.error]).toEqual([[], []]);
  const none = await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => null);
  expect([none.boards, none.missing]).toEqual([[], [name]]);
  const bad = await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => ({ error: "board.mjs: gh is down\nat line 2" }));
  expect([bad.boards, bad.missing, bad.error]).toEqual([[], [], [{ chief: name, error: "board.mjs: gh is down" }]]);
});

test("liveBoards: the chief doc's Live-state decisions: line is the operator's Waiting; a decisions file pointer and none are not", async () => {
  const root = tmp(), name = "HIMMEL-nextleg-2026-10-27A-roadmap-chief";
  const docWith = (line: string) => { chiefDocIn(root, name); writeFileSync(join(root, "yotamleo", "himmel", `${name}.md`), `# c\n\n## Live state\n\nepics: HIMMEL-1=2\n${line}\n\n## Results\n- 09:00 LIVE\n`); };
  const waiting = async () => rowsOf((await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => ({ legs: [liveLeg] }))).boards).waiting.map((w) => w.detail);
  docWith("decisions: first (x; y)?; second?");
  expect(await waiting()).toEqual(["first (x; y)?", "second?"]);
  docWith("decisions: none");
  expect(await waiting()).toEqual([]);
  docWith("decisions: carried verbatim in specs/decisions/console-decisions-2026-10-25.md (read it before ruling)");
  expect(await waiting()).toEqual([]);
  docWith("decisions: specs/decisions/console-decisions-2026-10-25.md; approve new spend?");
  expect(await waiting()).toEqual(["approve new spend?"]);
});

test("liveBoards: a chief doc that cannot be read is a boardError, never an empty decisions list", async () => {
  const root = tmp(), name = "HIMMEL-nextleg-2026-10-27A-roadmap-chief";
  chiefDocIn(root, name);
  const lv = await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => {
    rmSync(join(root, "yotamleo", "himmel", `${name}.md`)); // gone between the board read and the doc read
    return { legs: [liveLeg] };
  });
  expect(lv.error).toEqual([{ chief: name, error: "chief doc unreadable: its open decisions are not shown" }]);
  expect(rowsOf(lv.boards).running.length).toBe(1);
});

test("liveBoards: a chief whose lock heartbeat is past the queue-lock TTL is dead: its board and decisions are not shown, and it is not reported missing", async () => {
  const root = tmp(), name = "HIMMEL-nextleg-2026-10-27A-roadmap-chief";
  chiefDocIn(root, name);
  writeFileSync(join(root, "yotamleo", "himmel", `${name}.md`), "# c\n\n## Live state\n\ndecisions: a dead chief's question?\n");
  const dead = await liveBoards(root, chiefLocks(name, Date.now() - 2 * 24 * 3_600_000), chiefSpan(name), async () => ({ legs: [liveLeg] }));
  expect([dead.boards, dead.missing, dead.error]).toEqual([[], [], []]);
  const alive = await liveBoards(root, chiefLocks(name), chiefSpan(name), async () => ({ legs: [liveLeg] }));
  expect(rowsOf(alive.boards).waiting.map((w) => w.detail)).toEqual(["a dead chief's question?"]);
});

test("the Shift page says a board is missing or failed instead of Nothing is running", () => {
  const base = { now: NOW, rows: [], snap: snap(open), id: null, merged: [], boards: [] };
  const missing = renderShift(viewOf({ ...base, boardMissing: ["chief-A"] }), {});
  expect(missing).toContain("No board for chief-A yet: it has not rendered one.");
  expect(missing).not.toContain("Nothing is running.");
  const failed = renderShift(viewOf({ ...base, boardError: [{ chief: "chief-A", error: "gh is down" }] }), {});
  expect(failed).toContain("Board for chief-A failed to build: gh is down");
  expect(failed).not.toContain("Nothing is running.");
  expect(renderShift(viewOf(base), {})).toContain("Nothing is running."); // every board read, none running
  const mixed = renderShift(viewOf({ ...base, boards: [board], boardMissing: ["chief-B"] }), {});
  expect(mixed).toContain("No board for chief-B yet");
  expect(mixed).toContain("HIMMEL-3"); // the rows still show beside the note
});

test("a board note is escaped, and a 40-character chief doc name survives the redactor in the new fields", () => {
  const name = "HIMMEL-nextleg-2026-11-04PY-roadmap-chief";
  const v = redactShift(viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged: [], boards: [], boardMissing: [name], boardError: [{ chief: name, error: "<img src=x>" }] }), redactDeep);
  expect(v.boardMissing).toEqual([name]);
  expect(v.boardError[0].chief).toBe(name);
  expect(renderShift(v, {})).not.toContain("<img src=x>");
});

test("the CLI poll spawns no board build: a live chief without a board file is read from the file only", async () => {
  const dir = tmp();
  const { root } = boot({ chief: true });
  const gh = join(dir, "gh.sh");
  writeFileSync(gh, "#!/bin/sh\necho '[]'\n", { mode: 0o755 });
  const bin = join(dir, "bin");
  mkdirSync(bin); // a node shim first on PATH: any board.mjs spawn would run it and leave a mark
  writeFileSync(join(bin, "node"), `#!/bin/sh\necho spawn >> ${join(dir, "node-spawns")}\nexec ${process.execPath} "$@"\n`, { mode: 0o755 });
  const file = join(dir, "cli-shifts.jsonl");
  const p = Bun.spawn([process.execPath, join(import.meta.dir, "..", "shift-cli.ts")], { env: { PATH: `${bin}:${process.env.PATH}`, HOME: dir, HANDOVER_DIR: root, SHIFTS_FILE: file, GH_CMD: gh }, stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(0);
  expect(() => readFileSync(join(dir, "node-spawns"))).toThrow();
});

test("the Fleet board route and the Shift page serve the same board file", async () => {
  const { s, name } = boot({ chief: true, board: fileBoard });
  const shift = await (await getShift(s.port)).json();
  expect(shift.running.length).toBe(1);
  const fleet = await fetch(`http://127.0.0.1:${s.port}/api/agui/board?console=${name}`, { headers: { "X-Himmel-Token": TOKEN } });
  expect(fleet.status).toBe(200);
  expect((await fleet.json()).console.name).toBe("stub-chief");
});

test("a Shift payload carries no sections, whatever sits beside the chief's doc", async () => {
  const { s, root, name } = boot({ chief: true, board: fileBoard });
  await applySection(join(root, "yotamleo", "himmel", `${name}.md`), { kind: "set", id: "note", title: "Chief note", body: "SENTINEL-SECTION-BODY" });
  const fleet = await (await fetch(`http://127.0.0.1:${s.port}/api/agui/board?console=${name}`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(fleet.sections).toHaveLength(1); // the Fleet route serves it
  const text = JSON.stringify(await (await getShift(s.port)).json());
  expect(text).not.toContain("sections");
  expect(text).not.toContain("SENTINEL-SECTION-BODY");
});

test("a board file that does not parse shows on the page as a missing board, and the layout still has three tiles", async () => {
  const { s, root, name } = boot({ chief: true });
  writeFileSync(join(root, "yotamleo", "himmel", `${name}.board.json`), "{ not json");
  const v = await (await getShift(s.port)).json();
  expect(v.boardMissing).toEqual([name]);
  expect(v.boardError).toEqual([]);
  const html = renderShift(v, {});
  expect(html).toContain(`No board for ${name} yet`);
  expect(html.match(/class="tile /g)?.length).toBe(3);
  expect(html).toContain('id="sh-chiefs"');
});

// The Shift page reads the chief's board file and nothing else. RED control (pre-fix server): the missing file ran the boardScript stub, which left the marker.
test("a live chief with no board file shows no leg, a missing-board note, and runs no build", async () => {
  const dir = tmp(), marker = join(dir, "build-ran"), script = join(dir, "marker-board.mjs");
  writeFileSync(script, `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(marker)}, "x");\n`);
  const { s, name } = boot({ chief: true, boardScript: script });
  const v = await (await getShift(s.port)).json();
  expect(v.running).toEqual([]);
  expect(v.boardMissing).toEqual([name]);
  expect(existsSync(marker)).toBe(false);
});
