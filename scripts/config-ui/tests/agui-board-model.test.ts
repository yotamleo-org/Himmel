// The Fleet page's board model: the join of himmel.board/1 legs to /api/agui/fleet rows, the drawer's keyboard
// reducer, the deep-link fragment, and the stage segments the drill-in strip draws.
import { test, expect } from "bun:test";
import { applyKey, joinBoard, openAt, parseView, STAGES, stageSegments, viewHash, type Board, type BoardLeg, type Drawer } from "../agui-web/src/board-model";
import type { Row } from "../agui-web/src/fleet-model";

const leg = (name: string, o: Partial<BoardLeg> = {}): BoardLeg => ({
  leg: name, ticket: "HIMMEL-1", goal: "do it", state: "building", stage: "live",
  stages: { dispatch: null, live: "2026-10-16T10:00+02:00", pr: null, ready: null, go: null, merged: null },
  pr: null, links: { ticket: null, brief: null }, timeline: [], ...o,
});
const board = (legs: BoardLeg[], needs: Board["needs_you"] = []): Board => ({ schema: "himmel.board/1", generated_at: "2026-10-16T12:00+02:00", console: { name: "c" }, legs, needs_you: needs, legend: {}, cards: {}, trends: {} } as unknown as Board);
const row = (name: string): Row => ({ name, role: "leg", state: "running" } as Row);

test("joinBoard: a board leg meets the fleet row of the same label; unmatched legs and rows stay apart", () => {
  const j = joinBoard([row("a"), row("z")], board([leg("a"), leg("b")]));
  expect(j.find((x) => x.leg.leg === "a")!.row?.name).toBe("a");
  expect(j.find((x) => x.leg.leg === "b")!.row).toBeNull();
  expect(j).toHaveLength(2); // a fleet row with no board leg is not a board card
});

test("joinBoard: the board's short label (N2339) meets the fleet row whose doc name carries it, a resume hop included", () => {
  const rows = [row("HIMMEL-5945-N2339-station-follows-main-2026-10-16"), row("HIMMEL-5946-N2340-other-2026-10-16")];
  expect(joinBoard(rows, board([leg("N2339")]))[0].row?.name).toBe(rows[0].name);
  expect(joinBoard(rows, board([leg("N23")]))[0].row).toBeNull(); // a prefix of a number is not the label
  expect(joinBoard([row("HIMMEL-5945-N2339b-station-RESUME")], board([leg("N2339")]))[0].row?.name).toBe("HIMMEL-5945-N2339b-station-RESUME");
});

test("joinBoard: a leg needing you carries its verb and action", () => {
  const j = joinBoard([], board([leg("a")], [{ leg: "a", verb: "go", action: "judge and GO PR #1", detail: "", command: "bash go.sh 1 abc", since: null }]));
  expect(j[0].need).toMatchObject({ verb: "go", command: "bash go.sh 1 abc" });
});

test("applyKey: left/right move between stages, up/down between legs, Esc closes", () => {
  const legs = ["a", "b", "c"];
  const d: Drawer = { leg: "b", stage: "pr", back: [] };
  expect(applyKey(d, "ArrowRight", legs)).toMatchObject({ leg: "b", stage: "ready" });
  expect(applyKey(d, "ArrowLeft", legs)).toMatchObject({ leg: "b", stage: "live" });
  expect(applyKey(d, "ArrowDown", legs)).toMatchObject({ leg: "c", stage: "pr" });
  expect(applyKey(d, "ArrowUp", legs)).toMatchObject({ leg: "a", stage: "pr" });
  expect(applyKey(d, "Escape", legs)).toBeNull();
});

test("applyKey: stops at the ends instead of wrapping, and ignores other keys", () => {
  const legs = ["a", "b"];
  expect(applyKey({ leg: "a", stage: "dispatch", back: [] }, "ArrowLeft", legs)).toMatchObject({ stage: "dispatch" });
  expect(applyKey({ leg: "a", stage: "merged", back: [] }, "ArrowRight", legs)).toMatchObject({ stage: "merged" });
  expect(applyKey({ leg: "a", stage: "pr", back: [] }, "ArrowUp", legs)).toMatchObject({ leg: "a" });
  expect(applyKey({ leg: "b", stage: "pr", back: [] }, "ArrowDown", legs)).toMatchObject({ leg: "b" });
  const d: Drawer = { leg: "a", stage: "pr", back: [] };
  expect(applyKey(d, "x", legs)).toBe(d);
});

test("drawer history: a move pushes the place it left, Back pops it", () => {
  const legs = ["a", "b"];
  let d: Drawer | null = openAt(null, "a", "live");
  d = applyKey(d, "ArrowDown", legs)!;
  expect(d).toMatchObject({ leg: "b", back: [{ leg: "a", stage: "live" }] });
  d = applyKey(d, "Backspace", legs)!;
  expect(d).toMatchObject({ leg: "a", stage: "live", back: [] });
  expect(applyKey(d, "Backspace", legs)).toBe(d); // nothing to go back to
});

test("deep links: tab=trends and k=s.<leg>.<stage> round-trip through the fragment", () => {
  const h = viewHash("tok", "console-x", "trends", { leg: "HIMMEL-5-N1-x-2026-10-16", stage: "ready" });
  expect(parseView(h)).toEqual({ tab: "trends", k: { leg: "HIMMEL-5-N1-x-2026-10-16", stage: "ready" } });
  expect(parseView("#t=tok")).toEqual({ tab: "fleet", k: null });
  expect(parseView("#t=tok&k=s.a.nonsense")).toEqual({ tab: "fleet", k: null });
  expect(new URLSearchParams(h.slice(1)).get("console")).toBe("console-x");
});

test("stageSegments: one band per stage reached, each ending where the next stage starts", () => {
  const l = leg("a", { stage: "ready", stages: { dispatch: null, live: "2026-10-16T10:00+02:00", pr: "2026-10-16T10:30+02:00", ready: "2026-10-16T11:00+02:00", go: null, merged: null } });
  const s = stageSegments(l, Date.parse("2026-10-16T11:30+02:00"));
  expect(s.map((x) => x.stage)).toEqual(["live", "pr", "ready"]);
  expect(s.map((x) => Math.round((x.to - x.from) / 60000))).toEqual([30, 30, 30]); // the last runs to now
  expect(STAGES).toEqual(["dispatch", "live", "pr", "ready", "go", "merged"]);
});
