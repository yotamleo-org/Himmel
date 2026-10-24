// GET /api/rollup — the weekly roll-up (scripts/eval/weekly-rollup.py) as three trend cards, read-only; and the Health page's Trends section.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { renderHealth } from "../public/health.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

type Row = Record<string, unknown>;
const week = (key: string, v: Row, delta: Row, partial = false): Row => ({ kind: "week", key, partial, since: key, until: key, delta, ...v });
const version = (key: string, v: Row, delta: Row): Row => ({ kind: "version", key, partial: false, since: key, until: key, delta, ...v });
// four finished weeks, one still running, and two versions
const ROWS: Row[] = [
  week("2026-W40", { merges: 10, cost_eq_per_ticket: 100, red_main: 1 }, { merges: null, cost_eq_per_ticket: null, red_main: null }),
  week("2026-W41", { merges: 14, cost_eq_per_ticket: 100, red_main: 0 }, { merges: 4, cost_eq_per_ticket: 0, red_main: -1 }),
  week("2026-W42", { merges: 12, cost_eq_per_ticket: 120, red_main: 2 }, { merges: -2, cost_eq_per_ticket: 20, red_main: 2 }),
  week("2026-W43", { merges: 18, cost_eq_per_ticket: 150, red_main: 1 }, { merges: 6, cost_eq_per_ticket: 30, red_main: -1 }),
  week("2026-W44", { merges: 3, cost_eq_per_ticket: 10, red_main: 0 }, { merges: -15, cost_eq_per_ticket: -140, red_main: -1 }, true),
  version("v1.0.0", { merges: 40, cost_eq_per_ticket: 200, red_main: 3 }, { merges: null, cost_eq_per_ticket: null, red_main: null }),
  version("v1.1.0", { merges: 30, cost_eq_per_ticket: 150, red_main: 1 }, { merges: -10, cost_eq_per_ticket: -50, red_main: -2 }),
];

function boot(rows?: Row[]) {
  const dir = mkdtempSync(join(tmpdir(), "rollup-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const file = join(dir, "weekly.jsonl");
  if (rows) writeFileSync(file, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, WEEKLY_ROLLUP_FILE: file } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}/api/rollup`, { headers, method });

test("rollup: three cards with the by-week series, both deltas and one plain sentence, taken from the stored rows", async () => {
  const s = boot(ROWS);
  const r = await (await get(s.port)).json();
  expect(r.state).toBe("ok");
  const [velocity, cost, health] = r.cards;
  expect([velocity.id, cost.id, health.id]).toEqual(["velocity", "cost", "health"]);
  // the running week is not a data point: a partial week would read as a drop
  expect(velocity.spark.map((p: { value: number }) => p.value)).toEqual([10, 14, 12, 18]);
  expect(velocity.week).toMatchObject({ key: "2026-W43", value: 18, delta: 6 });
  expect(velocity.version).toMatchObject({ key: "v1.1.0", value: 30, delta: -10 });
  expect(velocity.sentence).toBe("Faster than last week and slower than last version");
  expect(cost.sentence).toBe("Costlier than last week and cheaper than last version");
  expect(cost.week.delta).toBe(30);
  expect(health.sentence).toBe("Healthier than last week and healthier than last version");
});

test("rollup: a card with no comparison says so; an empty series says no data yet", async () => {
  const s = boot([week("2026-W40", { merges: 10, cost_eq_per_ticket: null, red_main: 0 }, { merges: null, cost_eq_per_ticket: null, red_main: null })]);
  const r = await (await get(s.port)).json();
  expect(r.cards[0].sentence).toBe("No earlier week or version to compare with yet");
  expect(r.cards[1]).toMatchObject({ state: "nodata", sentence: "no data yet", spark: [] });
});

test("rollup: a running week alone is shown but never compared", async () => {
  const s = boot([week("2026-W44", { merges: 3, cost_eq_per_ticket: 10, red_main: 0 }, { merges: -15, cost_eq_per_ticket: -140, red_main: -1 }, true)]);
  const r = await (await get(s.port)).json();
  expect(r.cards[0].week).toMatchObject({ key: "2026-W44", value: 3, delta: null, partial: true });
  expect(r.cards[0].sentence).toBe("No earlier week or version to compare with yet");
});

test("rollup: an absent file is state absent; the route is token-gated and read-only", async () => {
  const s = boot();
  expect(await (await get(s.port)).json()).toMatchObject({ state: "absent" });
  expect((await get(s.port, {})).status).toBe(401);
  expect((await get(s.port, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
});

test("Health page: the Trends section shows the three cards, a sparkline and the sentence", async () => {
  const s = boot(ROWS);
  const rollup = await (await get(s.port)).json();
  const html = renderHealth(null, { bank: { state: "absent" }, legs: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, rollup });
  for (const t of ["Velocity", "Cost", "Health"]) expect(html).toContain(`<h3>${t}</h3>`);
  expect(html).toContain("Faster than last week and slower than last version");
  expect(html).toContain("<polyline");
  expect(html).toContain("+6 vs last week");
  expect(html).toContain("-10 vs last version");
});

test("Health page: no roll-up shows 'no data yet' in the Trends section; strings are escaped", () => {
  expect(renderHealth(null, null)).toContain("no data yet");
  const evil = `<img src=x onerror=alert(1)>`;
  const html = renderHealth(null, { bank: { state: "absent" }, legs: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, rollup: { state: "ok", cards: [{ id: "velocity", title: evil, metric: evil, unit: evil, state: "ok", spark: [], week: null, version: null, sentence: evil }] } });
  expect(html).not.toContain("<img");
});
