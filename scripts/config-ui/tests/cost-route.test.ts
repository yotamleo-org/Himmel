import { test, expect, afterEach } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PAGES, navLinks, parseLanding } from "../public/nav.js";
import { renderCost } from "../public/cost.js";
import { startServer } from "../server";
import type { PhaseCostRow } from "../cost";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const DAY = "2026-11-04";
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const row = (o: Partial<PhaseCostRow> & { phase: string; usd: number | null }): PhaseCostRow => ({
  kind: "phase-cost", day: DAY, session: "s", parent: null, lane: "claude", class: "worker", model: "claude-sonnet-5-5",
  phase_rule: "v1", calls: 1, in: 100, out: 10, cache_read: 1000, cc_5m: 0, cc_1h: 0, mark: "derived", ...o,
});
const ROWS = [
  row({ session: "w1", phase: "build", usd: 10 }),
  row({ session: "c1", phase: "chief-turns", class: "chief", usd: 20, mark: "counted" }),
  row({ session: "w1", phase: "review", usd: 4, model: "claude-opus-5-5,HIMMEL-9260-x" }),
];

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "cost-route-"));
  const store = join(dir, "usage"), home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(store); mkdirSync(home); mkdirSync(root);
  writeFileSync(join(store, "records.jsonl"), ROWS.map((r) => JSON.stringify(r)).join("\n") + "\n");
  execFileSync("git", ["init", "-q", root]);
  const s = startServer({ onIdle: () => {}, port: 0, root, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HIMMEL_USAGE_STORE: store } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return `http://127.0.0.1:${s.port}`;
}

test("cost route: GET only, behind the token, answers the page model read from the phase-cost rows", async () => {
  const base = boot();
  const url = `${base}/api/cost`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r).toMatchObject({ state: "ok", day: DAY, usd: 34, calls: 3 });
  expect(r.phases.map((p: { id: string }) => p.id)).toEqual(["chief", "build", "review"]);
  expect(JSON.stringify(r)).not.toMatch(/HIMMEL-/);
});

test("cost route: the page's browser half is served, and what a visitor sees carries no ticket key", async () => {
  const base = boot();
  const js = await fetch(`${base}/cost.js`);
  expect(js.status).toBe(200);
  expect(js.headers.get("content-type")).toContain("javascript");
  const model = await (await fetch(`${base}/api/cost`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  const html = renderCost(model, { open: model.phases.map((p: { id: string }) => p.id) });
  expect(html).toContain("Cost by phase");
  expect(html).not.toMatch(/HIMMEL-/);
});

test("cost route: route-authorization: 401 without a token, 405 on POST, 200 on an authenticated GET, and nothing is written", async () => {
  const base = boot();
  const url = `${base}/api/cost`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  expect((await fetch(url, { method: "PUT", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  expect((await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).status).toBe(200);
});

test("cost route: partial source is never all-provider or invoices", async () => {
  const base = boot();
  const model = await (await fetch(`${base}/api/cost`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  const basis = "Claude transcript usage at list prices; not invoices. Native Codex and other provider stores are not included.";
  expect(model.basis).toBe(basis);
  expect(model.coverageNote).toBe("Collection freshness and completeness unknown");
  const html = renderCost(model, { open: [] });
  expect(html).toContain(basis);
  expect(html).not.toMatch(/all[- ]provider|every provider/i);
});

test("cost nav: the rail lists Cost on both documents and the chief's landing opens it", () => {
  expect(PAGES.map((p: { id: string }) => p.id)).toContain("cost");
  for (const here of ["console", "agui"] as const)
    expect(navLinks({ here, token: TOKEN, current: "cost" }).filter((l: { current: boolean }) => l.current).map((l: { label: string }) => l.label)).toEqual(["Cost"]);
  expect(parseLanding(`#t=${"a".repeat(8)}&page=cost`)).toEqual({ token: "a".repeat(8), page: "cost" });
});
