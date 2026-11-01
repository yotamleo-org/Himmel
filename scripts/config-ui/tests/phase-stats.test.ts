// GET /api/phase-stats — the Eval tab's per-phase 7-day numbers, read from the ticket status records and the review-round
// files. A phase with nothing behind it says "no source yet"; the cost per ticket says "no data yet".
import { test, expect, afterEach } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readPhaseStats } from "../phase-stats";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const NOW = Date.parse("2026-11-01T09:30:00Z"); // the window is 25 Oct 00:00 to 1 Nov 00:00 UTC
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

type Ev = { ts: string; event: string; key: string; pr?: string };
const ev = (event: string, key: string, ts: string, pr = ""): Ev => ({ ts, event, key, pr });
const EVENTS: Ev[] = [
  // A: LIVE 10:00, PR 10:20, CI 10:21, merge 11:21, WRAPPED 11:22
  ev("live", "HIMMEL-1", "2026-10-26T10:00:00Z"), ev("pr-open", "HIMMEL-1", "2026-10-26T10:20:00Z", "11"),
  ev("ci-start", "HIMMEL-1", "2026-10-26T10:21:00Z", "11"), ev("ci-start", "HIMMEL-1", "2026-10-26T10:50:00Z", "11"),
  ev("merge", "HIMMEL-1", "2026-10-26T11:21:00Z", "11"), ev("wrapped", "HIMMEL-1", "2026-10-26T11:22:00Z"),
  // B: build 40 min, check 2 h, wrap 2 min
  ev("live", "HIMMEL-2", "2026-10-27T08:00:00Z"), ev("pr-open", "HIMMEL-2", "2026-10-27T08:40:00Z", "12"),
  ev("ci-start", "HIMMEL-2", "2026-10-27T08:41:00Z", "12"), ev("merge", "HIMMEL-2", "2026-10-27T10:41:00Z", "12"),
  ev("wrapped", "HIMMEL-2", "2026-10-27T10:43:00Z"),
  // C: build took 30 h (a parked ticket), never merged
  ev("live", "HIMMEL-3", "2026-10-28T00:00:00Z"), ev("pr-open", "HIMMEL-3", "2026-10-29T06:00:00Z", "13"),
  // D: entered Build before the window: not counted
  ev("live", "HIMMEL-4", "2026-10-20T00:00:00Z"), ev("pr-open", "HIMMEL-4", "2026-10-20T00:10:00Z", "14"),
  // E: today, after the window closed: not counted
  ev("live", "HIMMEL-5", "2026-11-01T01:00:00Z"),
];

function fixture(events: Ev[] = EVENTS, rounds: Record<string, [number, string]> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "phase-stats-"));
  const state = join(dir, "state"), roundsDir = join(dir, "rounds");
  mkdirSync(state); mkdirSync(roundsDir);
  writeFileSync(join(state, "status-events.jsonl"), events.map((e) => JSON.stringify(e)).join("\n") + "\n{torn\n");
  for (const [branch, [n, day]] of Object.entries(rounds)) {
    const f = join(roundsDir, `${branch}.round`);
    mkdirSync(join(f, ".."), { recursive: true });
    writeFileSync(f, `${n}\n`);
    const t = Date.parse(`${day}T12:00:00Z`) / 1000;
    utimesSync(f, t, t);
  }
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return { dir, env: { TICKET_STATUS_STATE_DIR: state }, roundsDir };
}

const phase = (s: ReturnType<typeof readPhaseStats>, id: string) => s.phases.find((p) => p.id === id)!;

test("phase-stats: seven phases in order; Start, Plan and design and Assign have no source yet", () => {
  const { env, roundsDir } = fixture();
  const s = readPhaseStats(env, roundsDir, NOW);
  expect(s.phases.map((p) => p.id)).toEqual(["start", "plan", "assign", "build", "review", "check", "merge"]);
  for (const id of ["start", "plan", "assign"]) expect(phase(s, id).state).toBe("nosource");
  expect(s.from).toBe("2026-10-25T00:00:00.000Z");
  expect(s.to).toBe("2026-11-01T00:00:00.000Z");
  expect(s.days).toEqual(["2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31"]);
  expect(s.cost).toEqual({ state: "nodata", say: "no data yet" });
});

test("phase-stats: Build runs from LIVE to the PR opening, counted when the ticket entered Build in the window", () => {
  const { env, roundsDir } = fixture();
  const b = phase(readPhaseStats(env, roundsDir, NOW), "build");
  expect(b.state).toBe("ok");
  expect(b.n).toBe(3);
  expect(b.median).toBe(40);
  expect(b.perDay).toEqual([0, 1, 1, 1, 0, 0, 0]);
});

test("phase-stats: Check and approve runs from the first CI run to the merge; Merge and wrap up from the merge to WRAPPED", () => {
  const { env, roundsDir } = fixture();
  const s = readPhaseStats(env, roundsDir, NOW);
  expect(phase(s, "check")).toMatchObject({ state: "ok", n: 2, median: 90 });
  expect(phase(s, "merge")).toMatchObject({ state: "ok", n: 2, median: 1.5 });
});

test("phase-stats: Review counts each branch's highest round, split merged or not; a far outlier is named by its PR", () => {
  const { env, roundsDir } = fixture(EVENTS, {
    "feat/himmel-1-a": [1, "2026-10-26"], "feat/himmel-2-b": [3, "2026-10-27"], "fix/himmel-3-c": [6, "2026-10-29"],
    "docs/himmel-9-old": [2, "2026-10-01"],
  });
  const s = readPhaseStats(env, roundsDir, NOW);
  expect(phase(s, "review")).toMatchObject({ state: "ok", unit: "rounds", n: 3, median: 3 });
  expect(s.review).toEqual({ threeUp: { merged: 1, notMerged: 1 }, under: { merged: 1, notMerged: 0 } });
  const build = s.outliers.filter((o) => o.phase === "build");
  expect(build.map((o) => o.pr)).toEqual(["13"]);
  expect(JSON.stringify(s.outliers)).not.toContain("HIMMEL-");
});

test("phase-stats: Review's entries per day are the same branches it counts, and an unreadable round file is skipped", () => {
  const { env, roundsDir } = fixture(EVENTS, { "feat/himmel-1-a": [2, "2026-10-30"], "feat/himmel-2-b": [4, "2026-10-30"] });
  const locked = join(roundsDir, "feat", "himmel-2-b.round");
  chmodSync(locked, 0o000);
  const s = readPhaseStats(env, roundsDir, NOW);
  expect(phase(s, "review")).toMatchObject({ n: 1, perDay: [0, 0, 0, 0, 0, 1, 0] });
});

test("phase-stats: an outlier against an 8-in-10 line of zero minutes still reads as a finite multiple", () => {
  const quick = [1, 2, 3, 4, 5, 6].flatMap((i) => [ev("live", `HIMMEL-${i}`, "2026-10-26T10:00:00Z"), ev("pr-open", `HIMMEL-${i}`, "2026-10-26T10:00:00Z", String(i))]);
  const { env } = fixture([...quick, ev("live", "HIMMEL-7", "2026-10-26T10:00:00Z"), ev("pr-open", "HIMMEL-7", "2026-10-26T10:30:00Z", "7")]);
  const s = readPhaseStats(env, "", NOW);
  expect(phase(s, "build")).toMatchObject({ median: 0, p80: 0 });
  expect(s.outliers.map((o) => [o.pr, o.times])).toEqual([["7", 30]]);
});

test("phase-stats: no records at all reads as no data yet, never an error", () => {
  const dir = mkdtempSync(join(tmpdir(), "phase-stats-none-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const s = readPhaseStats({ TICKET_STATUS_STATE_DIR: join(dir, "absent") }, join(dir, "absent-rounds"), NOW);
  for (const id of ["build", "review", "check", "merge"]) expect(phase(s, id)).toMatchObject({ state: "nodata", n: 0, median: null });
});

test("phase-stats route: GET only, behind the token, read from the status records", async () => {
  const { dir } = fixture();
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  execFileSync("git", ["init", "-q", root]);
  const s = startServer({ port: 0, root, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, TICKET_STATUS_STATE_DIR: join(dir, "state") } });
  cleanups.push(() => s.stop());
  const url = `http://127.0.0.1:${s.port}/api/phase-stats`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r.phases).toHaveLength(7);
  expect(r.phases.find((p: { id: string }) => p.id === "start").state).toBe("nosource");
});
