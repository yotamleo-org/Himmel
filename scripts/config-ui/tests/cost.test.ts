// The Cost page's data module (cost.ts) and browser half (public/cost.js): phase-cost rows in, one page model out, each
// phase row opening to the parts it is made of. A part no record splits says "not countable yet"; it never gets a number.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildCostModel, readPhaseCostRows, type PhaseCostRow } from "../cost";
import { mountCost, renderCost } from "../public/cost.js";

const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const DAY = "2026-11-04";
const row = (o: Partial<PhaseCostRow> & { phase: string; usd: number | null }): PhaseCostRow => ({
  kind: "phase-cost", day: DAY, session: "s", parent: null, lane: "claude", class: "worker", model: "claude-sonnet-5-5",
  phase_rule: "v1", calls: 1, in: 100, out: 10, cache_read: 1000, cc_5m: 0, cc_1h: 0, mark: "derived", ...o,
});
// a worker (build, a subagent, boot), a chief with a brief-drafter and a helper, a judge, a review step whose model text carries a
// ticket key, a tests row with no price, and a row from the day before
const ROWS: PhaseCostRow[] = [
  row({ session: "w1", phase: "build", usd: 10 }), row({ session: "w1", phase: "agent", class: "subagent", usd: 4 }),
  row({ session: "w1", phase: "boot", usd: 1, model: "claude-opus-5-5" }),
  row({ session: "c1", phase: "chief-turns", class: "chief", usd: 20, mark: "counted" }),
  row({ session: "b1", phase: "chief-turns", class: "brief-drafter", usd: 5, mark: "counted" }),
  row({ session: "h1", phase: "chief-turns", class: "subagent", parent: "c1", usd: 3, mark: "counted" }),
  row({ session: "j1", phase: "judge", class: "judge", usd: 6, mark: "counted" }),
  row({ session: "w1", phase: "review", usd: 4, model: "claude-opus-5-5,HIMMEL-9260-x" }),
  row({ session: "w1", phase: "tests", usd: null, mark: "unpriced", model: "gpt-9-unknown" }),
  row({ session: "w0", phase: "build", usd: 99, day: "2026-11-03" }),
];

test("cost: phases come out biggest first with their share of the day, and the day's total is counted", () => {
  const m = buildCostModel(ROWS, DAY);
  expect(m.state).toBe("ok");
  expect(m.day).toBe(DAY);
  expect(m.days).toEqual(["2026-11-04", "2026-11-03"]);
  expect(m.usd).toBe(53);
  expect(m.phases.map((p) => [p.id, p.usd, p.share, p.mark])).toEqual([
    ["chief", 28, 52.8, "counted"], ["build", 15, 28.3, "derived"], ["judge", 6, 11.3, "counted"], ["review", 4, 7.5, "derived"], ["tests", null, null, "unpriced"],
  ]);
});

test("cost: a phase row opens to its parts; a part no record splits is 'not countable yet' with no number", () => {
  const m = buildCostModel(ROWS, DAY);
  const chief = m.phases.find((p) => p.id === "chief")!;
  expect(chief.parts.map((p) => [p.id, p.usd, p.share, p.mark])).toEqual([
    ["chief-sessions", 20, 71.4, "counted"], ["brief-drafting", 5, 17.9, "counted"], ["chief-helpers", 3, 10.7, "counted"], ["chief-steps", null, null, "nocount"],
  ]);
  expect(chief.made).toBe("chief sessions 20.0 · brief drafting 5.0 · chief helpers 3.0");
  expect(buildCostModel(ROWS, DAY).phases.find((p) => p.id === "build")!.parts.map((p) => [p.id, p.usd])).toEqual([["build-edit", 10], ["build-agent", 4], ["build-boot", 1]]);
  // a phase the records keep as one figure opens to one not-countable-yet row holding the whole phase
  const judge = m.phases.find((p) => p.id === "judge")!;
  expect(judge.parts).toMatchObject([{ id: "judge-pr", usd: 6, share: 100, mark: "nocount" }]);
});

test("cost: a row with no price keeps its phase and says so; no dollar is invented for it", () => {
  const tests = buildCostModel(ROWS, DAY).phases.find((p) => p.id === "tests")!;
  expect(tests).toMatchObject({ usd: null, share: null, mark: "unpriced" });
  expect(tests.parts.every((p) => p.usd === null || p.mark === "nocount")).toBe(true);
});

test("cost: no ticket key reaches the page model or the rendered page", () => {
  const m = buildCostModel(ROWS, DAY);
  expect(JSON.stringify(m)).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
  expect(m.models.map((x) => x.model)).toContain("claude-opus-5-5");
  const html = renderCost(m, { open: ["chief", "review"] });
  expect(html).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
  expect(html).not.toMatch(/mockup/i);
});

test("cost: the rendered table has every phase closed, and an open phase shows its parts", () => {
  const m = buildCostModel(ROWS, DAY);
  const closed = renderCost(m, { open: [] });
  expect(closed.match(/aria-expanded="false"/g)).toHaveLength(5);
  expect(closed).not.toContain("brief-drafter subagents");
  const open = renderCost(m, { open: ["chief"] });
  expect(open.match(/aria-expanded="true"/g)).toHaveLength(1);
  expect(open).toContain("brief-drafter subagents");
  expect(open).toContain("not countable yet");
});

test("cost: a click on a phase row opens it, a second click closes it", () => {
  const m = buildCostModel(ROWS, DAY);
  let click: (e: unknown) => void = () => {};
  const root = { innerHTML: "", addEventListener: (_t: string, f: (e: unknown) => void) => { click = f; } };
  mountCost(root, m);
  const on = (id: string) => click({ target: { closest: () => ({ getAttribute: () => id }) } });
  expect(root.innerHTML).not.toContain("brief-drafter subagents");
  on("chief");
  expect(root.innerHTML).toContain("brief-drafter subagents");
  on("chief");
  expect(root.innerHTML).not.toContain("brief-drafter subagents");
});

test("cost: a row with a script tag in its model is shown as text", () => {
  const m = buildCostModel([row({ phase: "build", usd: 1, model: "<script>alert(1)</script>" })], DAY);
  expect(renderCost(m, { open: [] })).not.toContain("<script>");
});

test("cost: no rows is no data yet, never zeros", () => {
  const m = buildCostModel([], undefined);
  expect(m).toMatchObject({ state: "nodata", day: null, days: [], phases: [] });
  expect(renderCost(m, { open: [] })).toContain("no data yet");
});

test("cost: usage-read hands over the latest row per day, session and phase, and drops a closed (zero-call) one", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const store = join(dir, "usage");
  mkdirSync(store);
  const lines = [
    row({ session: "w1", phase: "build", usd: 1, calls: 1 }), row({ session: "w1", phase: "build", usd: 3, calls: 2 }),
    row({ session: "w1", phase: "boot", usd: 0, calls: 0 }), row({ session: "w2", phase: "build", usd: 5 }),
  ].map((r) => JSON.stringify(r));
  lines.splice(1, 0, JSON.stringify({ schema: 1, ticket: "HIMMEL-1", totals: {} })); // a ticket record in the same store
  writeFileSync(join(store, "records.jsonl"), lines.join("\n") + "\n");
  const rows = readPhaseCostRows({ HIMMEL_USAGE_STORE: store, PATH: process.env.PATH });
  expect(rows.map((r) => [r.session, r.phase, r.usd])).toEqual([["w1", "build", 3], ["w2", "build", 5]]);
  expect(readPhaseCostRows({ HIMMEL_USAGE_STORE: join(dir, "absent"), PATH: process.env.PATH })).toEqual([]);
});
