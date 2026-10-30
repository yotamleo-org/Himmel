// The Fleet page's board model: the join of himmel.board/1 workers to /api/agui/fleet rows, the drawer's keyboard
// reducer, the deep-link fragment, and the stage segments the drill-in strip draws.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { applyKey, briefNext, BRIEF_IDLE, joinBoard, needsShown, normalizeBoard, openAt, parseView, STAGES, stageSegments, viewHash, type Board, type BoardWorker, type Drawer } from "../agui-web/src/board-model";
import type { Row } from "../agui-web/src/fleet-model";

const worker = (name: string, o: Partial<BoardWorker> = {}): BoardWorker => ({
  worker: name, ticket: "HIMMEL-1", goal: "do it", state: "building", stage: "live",
  stages: { dispatch: null, live: "2026-10-16T10:00+02:00", pr: null, ready: null, go: null, merged: null },
  pr: null, links: { ticket: null, brief: null }, timeline: [], ...o,
});
const board = (workers: BoardWorker[], needs: Board["needs_you"] = []): Board => ({ schema: "himmel.board/1", generated_at: "2026-10-16T12:00+02:00", console: { name: "c" }, workers, needs_you: needs, legend: {}, cards: {}, trends: {} } as unknown as Board);
const row = (name: string): Row => ({ name, role: "worker", state: "running" } as Row);

test("joinBoard: a board worker meets the fleet row of the same label; unmatched workers and rows stay apart", () => {
  const j = joinBoard([row("a"), row("z")], board([worker("a"), worker("b")]));
  expect(j.find((x) => x.worker.worker === "a")!.row?.name).toBe("a");
  expect(j.find((x) => x.worker.worker === "b")!.row).toBeNull();
  expect(j).toHaveLength(2); // a fleet row with no board worker is not a board card
});

test("joinBoard: the board's short label (N2339) meets the fleet row whose doc name carries it, a resume hop included", () => {
  const rows = [row("HIMMEL-5945-N2339-station-follows-main-2026-10-16"), row("HIMMEL-5946-N2340-other-2026-10-16")];
  expect(joinBoard(rows, board([worker("N2339")]))[0].row?.name).toBe(rows[0].name);
  expect(joinBoard(rows, board([worker("N23")]))[0].row).toBeNull(); // a prefix of a number is not the label
  expect(joinBoard([row("HIMMEL-5945-N2339b-station-RESUME")], board([worker("N2339")]))[0].row?.name).toBe("HIMMEL-5945-N2339b-station-RESUME");
});

test("joinBoard: a worker needing you carries its verb and action", () => {
  const j = joinBoard([], board([worker("a")], [{ worker: "a", verb: "go", action: "judge and GO PR #1", detail: "", command: "bash go.sh 1 abc", since: null }]));
  expect(j[0].need).toMatchObject({ verb: "go", command: "bash go.sh 1 abc" });
});

test("applyKey: left/right move between stages, up/down between workers, Esc closes", () => {
  const workers = ["a", "b", "c"];
  const d: Drawer = { worker: "b", stage: "pr", back: [] };
  expect(applyKey(d, "ArrowRight", workers)).toMatchObject({ worker: "b", stage: "ready" });
  expect(applyKey(d, "ArrowLeft", workers)).toMatchObject({ worker: "b", stage: "live" });
  expect(applyKey(d, "ArrowDown", workers)).toMatchObject({ worker: "c", stage: "pr" });
  expect(applyKey(d, "ArrowUp", workers)).toMatchObject({ worker: "a", stage: "pr" });
  expect(applyKey(d, "Escape", workers)).toBeNull();
});

test("applyKey: stops at the ends instead of wrapping, and ignores other keys", () => {
  const workers = ["a", "b"];
  expect(applyKey({ worker: "a", stage: "dispatch", back: [] }, "ArrowLeft", workers)).toMatchObject({ stage: "dispatch" });
  expect(applyKey({ worker: "a", stage: "merged", back: [] }, "ArrowRight", workers)).toMatchObject({ stage: "merged" });
  expect(applyKey({ worker: "a", stage: "pr", back: [] }, "ArrowUp", workers)).toMatchObject({ worker: "a" });
  expect(applyKey({ worker: "b", stage: "pr", back: [] }, "ArrowDown", workers)).toMatchObject({ worker: "b" });
  const d: Drawer = { worker: "a", stage: "pr", back: [] };
  expect(applyKey(d, "x", workers)).toBe(d);
});

test("drawer history: a move pushes the place it left, Back pops it", () => {
  const workers = ["a", "b"];
  let d: Drawer | null = openAt(null, "a", "live");
  d = applyKey(d, "ArrowDown", workers)!;
  expect(d).toMatchObject({ worker: "b", back: [{ worker: "a", stage: "live" }] });
  d = applyKey(d, "Backspace", workers)!;
  expect(d).toMatchObject({ worker: "a", stage: "live", back: [] });
  expect(applyKey(d, "Backspace", workers)).toBe(d); // nothing to go back to
});

test("deep links: tab=trends and k=s.<worker>.<stage> round-trip through the fragment", () => {
  const h = viewHash("tok", "chief-x", "trends", { worker: "HIMMEL-5-N1-x-2026-10-16", stage: "ready" });
  expect(parseView(h)).toEqual({ tab: "trends", k: { worker: "HIMMEL-5-N1-x-2026-10-16", stage: "ready" } });
  expect(parseView("#t=tok")).toEqual({ tab: "fleet", k: null });
  expect(parseView("#t=tok&k=s.a.nonsense")).toEqual({ tab: "fleet", k: null });
  expect(new URLSearchParams(h.slice(1)).get("console")).toBe("chief-x");
});

test("stageSegments: one band per stage reached, each ending where the next stage starts", () => {
  const l = worker("a", { stage: "ready", stages: { dispatch: null, live: "2026-10-16T10:00+02:00", pr: "2026-10-16T10:30+02:00", ready: "2026-10-16T11:00+02:00", go: null, merged: null } });
  const s = stageSegments(l, Date.parse("2026-10-16T11:30+02:00"));
  expect(s.map((x) => x.stage)).toEqual(["live", "pr", "ready"]);
  expect(s.map((x) => Math.round((x.to - x.from) / 60000))).toEqual([30, 30, 30]); // the last runs to now
  expect(STAGES).toEqual(["dispatch", "live", "pr", "ready", "go", "merged"]);
});

test("joinBoard: of several live hops sharing a worker label the newest start wins, whatever the input order", () => {
  const hop = (name: string, startedAt: number) => ({ ...row(name), runtime: { startedAt, endedAt: null, elapsedMs: 0 } }) as Row;
  const newer = hop("HIMMEL-1-N7b-x-RESUME", 2000), older = hop("HIMMEL-1-N7-x", 1000);
  expect(joinBoard([newer, older], board([worker("N7")]))[0].row?.name).toBe(newer.name);
  expect(joinBoard([older, newer], board([worker("N7")]))[0].row?.name).toBe(newer.name);
  const dead = { ...hop("HIMMEL-1-N7c-x-RESUME", 3000), live: false } as Row; // a finished hop never beats a live one
  expect(joinBoard([older, dead], board([worker("N7")]))[0].row?.name).toBe(older.name);
});

test("needsShown: the needs-you list honours the rail's filters; with none every needing worker stays", () => {
  const need = (l: string) => ({ worker: l, verb: "go", action: "GO", detail: "", command: null, since: null });
  const rows = [{ ...row("HIMMEL-1-N1-a"), lane: "claudex" } as Row, row("HIMMEL-2-N2-b")];
  const j = joinBoard(rows, board([worker("N1"), worker("N2"), worker("N3")], [need("N1"), need("N2"), need("N3")]));
  const none = { lanes: [], states: [], text: "" };
  expect(needsShown(j, rows, none).map((x) => x.worker.worker)).toEqual(["N1", "N2", "N3"]);
  expect(needsShown(j, rows, { ...none, lanes: ["native"] }).map((x) => x.worker.worker)).toEqual(["N2"]);
});

// board.mjs still emits the old wire keys until its writer flips: the page must show the same board from either shape.
test("normalizeBoard: the old wire shape from board.mjs yields the same board as the new one", () => {
  const old = JSON.parse(readFileSync(join(import.meta.dir, "fixtures", "agui", "board-old-wire.json"), "utf8"));
  const want = {
    ...board([worker("N1"), worker("N2")], [{ worker: "N1", verb: "go", action: "GO", detail: "", command: null, since: null }]),
    trends: { worker_time: { unit: "min", today: [{ worker: "N1", live_at: null, merged_at: null, live_to_merged_min: null, to_pr_min: null, ready_to_merged_min: null }] } },
  };
  expect(normalizeBoard(old)).toEqual(want);
  expect(normalizeBoard(want)).toEqual(want); // the new shape passes through untouched
});

test("briefNext: a new request clears the previous text and error", () => {
  const withText = briefNext(BRIEF_IDLE, { kind: "text", text: "old" });
  expect(withText.text).toBe("old");
  expect(briefNext(withText, { kind: "start" })).toEqual(BRIEF_IDLE);
  const withErr = briefNext(withText, { kind: "error", err: "boom" });
  expect(briefNext(withErr, { kind: "start" })).toEqual(BRIEF_IDLE);
});
