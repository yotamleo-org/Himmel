// shift.ts — the shift helper: the cut rule, shifts.jsonl under one writer, the span-and-attribution function.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULTS, appendShift, attribute, chiefSpans, iso, liveChiefs, mergedIn, nameOf, readLocks, readMerged, readShifts, redactShift, rowsOf, step, tick, viewOf, type Row, type State, type View } from "../shift";
import { redactDeep } from "../../himmelctl/lib/redact.js";
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

test("rowsOf: Waiting is the board's needs_you, Running is live and PR-open work that is not waiting, oldest first", () => {
  const r = rowsOf([board]);
  expect(r.waiting.map((w) => [w.kind, w.ticket, w.pr])).toEqual([["question", "HIMMEL-2", null], ["GO", "HIMMEL-1", 12]]);
  expect(r.running.map((x) => [x.ticket, x.stage])).toEqual([["HIMMEL-4", "in review"], ["HIMMEL-3", "building"]]);
});

test("viewOf: an open shift lists chiefs, Waiting, Running and the PRs merged inside it, named for the chief whose span holds the merge", () => {
  const merged = [{ number: 20, title: "feat: a", mergedAt: "2026-10-27T09:00:00Z" }, { number: 21, title: "fix: b", mergedAt: "2026-10-27T06:00:00Z" }];
  const v = viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged, boards: [board] });
  expect(v.state).toBe("open");
  expect(v.shift?.name).toBe("day");
  expect(v.shift?.id).toBe("2026-10-27T08:00+01:00");
  expect(v.waiting.length).toBe(2);
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

const pageView = (over: Partial<View> = {}): View => ({ ...viewOf({ now: NOW, rows: [], snap: snap(open), id: null, merged: [{ number: 20, title: "feat: a", mergedAt: "2026-10-27T09:00:00Z" }], boards: [board] }), ...over });

test("the Shift page draws Waiting, Running and Shipped over a mid-shift fixture, Waiting rows only link out", () => {
  const html = renderShift(pageView(), {});
  for (const id of ["sh-waiting", "sh-running", "sh-shipped"]) expect(html).toContain(`id="${id}"`);
  expect(html).toContain("HIMMEL-2");
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
function boot(opts: { rows?: Row[]; chief?: boolean; prs?: unknown[]; ghFails?: boolean }) {
  const dir = tmp();
  const root = join(dir, "root"), home = join(dir, "home");
  mkdirSync(home); mkdirSync(root);
  const file = join(dir, "shifts.jsonl");
  if (opts.rows) writeFileSync(file, opts.rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  if (opts.chief) {
    // a chief doc dated today whose LIVE bullet is two minutes old, and the lock it holds
    const at = new Date(Date.now() - 2 * MIN_MS), p2 = (n: number) => String(n).padStart(2, "0");
    const name = `HIMMEL-nextleg-${at.getFullYear()}-${p2(at.getMonth() + 1)}-${p2(at.getDate())}A-roadmap-chief`;
    mkdirSync(join(root, "yotamleo", "himmel"), { recursive: true });
    writeFileSync(join(root, "yotamleo", "himmel", `${name}.md`), doc("x", [`- ${p2(at.getHours())}:${p2(at.getMinutes())} LIVE — up`]));
    const lock = join(root, ".locks", "queue", `yotamleo__himmel__${name}.lock`);
    mkdirSync(lock, { recursive: true });
    writeFileSync(join(lock, "owner.json"), JSON.stringify({ session: "s", handover: join(root, "yotamleo", "himmel", `${name}.md`), heartbeat: new Date().toISOString() }));
  }
  writeFileSync(join(dir, "prs.json"), JSON.stringify(opts.prs ?? []));
  const gh = join(dir, "gh.sh");
  writeFileSync(gh, opts.ghFails ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\ncat " + join(dir, "prs.json") + "\n", { mode: 0o755 });
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, SHIFTS_FILE: file, GH_CMD: gh } });
  cleanups.push(() => s.stop());
  return { s, file };
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
  expect(unread).not.toContain('Shipped this shift <span class="ro">0</span>');
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

test("redactShift: a doc name in a free-text field stays redacted", () => {
  const real = "HIMMEL-nextleg-2026-10-31LO-roadmap-chief";
  const v = chiefView(real);
  v.waiting[0].title = real;
  v.shipped[0].title = real;
  const out = redactShift(v, redactDeep);
  expect([out.waiting[0].title, out.shipped[0].title]).toEqual(["‹redacted›", "‹redacted›"]);
});

test("redactShift: a doc-name shape that also carries a token shape, a prefix before a valid name, or more than 80 characters stays redacted", () => {
  const real = "HIMMEL-nextleg-2026-10-31LO-roadmap-chief";
  const aws = "AK" + "IA" + "ABCDEFGHIJKLMNOP"; // an access-key shape built at run time
  const fields = (v: View) => [v.chiefs[0].name, v.waiting[0].chief, v.shipped[0].chief, ...v.gap[0].chiefs];
  const viaToken = fields(redactShift(chiefView(aws + "-nextleg-2026-10-31A-roadmap-chief"), redactDeep));
  for (const f of viaToken) expect(f).not.toContain(aws);
  for (const bad of ["abc " + real, "Zx-" + real, "HIMMEL-nextleg-2026-10-31A-" + "roadmap-".repeat(10) + "chief"]) {
    for (const f of fields(redactShift(chiefView(bad), redactDeep))) expect(f).not.toContain("roadmap-chief");
  }
});
