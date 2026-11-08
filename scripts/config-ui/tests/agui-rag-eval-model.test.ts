import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isRagEvalHash, NOT_MEASURED, ragEvalModel, wilson, type LedgerRow } from "../agui-web/src/rag-eval-model";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const re = (ts: string, status: string, metrics: Record<string, number>): LedgerRow =>
  ({ eval: "retrieval-eval", ts, run_id: `re-${ts}`, status, n: 75, metrics });
const ab = (ts: string, n: number, metrics: Record<string, number>): LedgerRow =>
  ({ eval: "answer-ab", ts, run_id: `ab-${ts}`, status: "ok", n, metrics });
const arm = (name: string, correct: number, n: number) => ({
  [`${name}.n`]: n, [`${name}.correct`]: correct, [`${name}.ms_median`]: 10000,
  [`${name}.input`]: 100, [`${name}.output`]: 900, [`${name}.cache_read`]: 6000 * n, [`${name}.cache_creation`]: 0,
});
const ROWS: LedgerRow[] = [
  re("2026-10-20T18:26:34Z", "ok", { "combined.recall@5": 0.8133, "grep.recall@5": 0.32 }),
  re("2026-11-05T13:15:18Z", "ok", {
    "combined.hit@5": 0.72, "combined.tokens_mean": 7161, "combined.ms_median": 8618,
    "combined.heldout.hit@5": 0.84, "combined.heldout.n": 25, "combined.insample.hit@5": 0.66, "combined.insample.n": 50,
    "qmd-hybrid.hit@5": 0.4933, "qmd-hybrid.tokens_mean": 471, "qmd-hybrid.ms_median": 4145,
    "graphify.hit@5": 0.52, "graphify.tokens_mean": 5369, "graphify.ms_median": 4315,
    "grep.hit@5": 0.3333, "grep.tokens_mean": 1320, "grep.ms_median": 207,
  }),
  re("2026-11-06T09:00:00Z", "error", { "combined.hit@5": 0 }),
  ab("2026-11-05T18:11:55Z", 12, { ...arm("vanilla", 11, 12), ...arm("fused-cached", 11, 12) }),
  ab("2026-11-05T19:20:03Z", 75, { ...arm("vanilla", 69, 75), ...arm("fused-cached", 70, 75), ...arm("vec-rerank", 70, 75), ...arm("bm25-rerank", 67, 75) }),
];

test("ragEvalModel: each route shows its newest ok measure, with its date and sample size", () => {
  const m = ragEvalModel(ROWS);
  const combined = m.routes.find((r) => r.key === "combined")!;
  expect(combined.finds).toMatchObject({ count: 54, n: 75, rate: 0.72, tokens: 7161, ms: 8618, ts: "2026-11-05T13:15:18Z" });
  expect(combined.answers).toMatchObject({ count: 70, n: 75, ms: 10000, ts: "2026-11-05T19:20:03Z" });
  expect(combined.answers!.tokens).toBe(6000 + 1000 / 75);
  expect(m.newest).toBe("2026-11-05T19:20:03Z");
  expect(m.routes.map((r) => r.key)).toEqual(["combined", "qmd-hybrid", "qmd-vec", "qmd-lex", "graphify", "grep", "vanilla"]);
});

test("ragEvalModel: a route the eval has not measured says so and carries no number", () => {
  const m = ragEvalModel(ROWS);
  const by = (k: string) => m.routes.find((r) => r.key === k)!;
  expect(by("graphify").answers).toBeNull();
  expect(by("graphify").answersGap).toBe(NOT_MEASURED);
  expect(by("qmd-vec").finds).toBeNull();
  expect(by("qmd-vec").answers).toMatchObject({ count: 70, n: 75 });
  expect(by("vanilla").finds).toBeNull();
  expect(by("vanilla").findsGap).toBe("no ranked list to score");
  const empty = ragEvalModel([]);
  expect(empty.routes.every((r) => r.finds === null && r.answers === null)).toBe(true);
  expect(empty.newest).toBeNull();
  expect(empty.bottomLine).toBe("Nothing has been measured yet, so no route can be compared.");
});

test("ragEvalModel: the bottom line leads with finds against grep, then answers against vanilla, a tie when the ranges overlap", () => {
  expect(ragEvalModel(ROWS).bottomLine).toBe("Combined search finds the right file on 72% of agent questions (54 of 75), plain grep on 33% (25 of 75); "
    + "on naming a gold file among up to 3 guesses in a Claude session, which does not check the answer, it ties vanilla Claude, 70 of 75 against 69 of 75, with overlapping 95% ranges.");
  const apart = ragEvalModel([ab("2026-11-05T19:20:03Z", 75, { ...arm("vanilla", 30, 75), ...arm("fused-cached", 70, 75) })]);
  expect(apart.bottomLine).toBe("On naming a gold file among up to 3 guesses in a Claude session, which does not check the answer, combined search beats vanilla Claude, 70 of 75 against 30 of 75.");
});

test("ragEvalModel: held-out and in-sample split, and the note that most questions are in-sample", () => {
  const m = ragEvalModel([...ROWS.slice(0, 4), ab("2026-11-05T19:20:03Z", 75, {
    ...arm("vanilla", 69, 75), ...arm("fused-cached", 70, 75),
    "fused-cached.heldout.correct": 24, "fused-cached.heldout.n": 25, "fused-cached.insample.correct": 46, "fused-cached.insample.n": 50,
  })]);
  const combined = m.routes.find((r) => r.key === "combined")!;
  expect(combined.finds).toMatchObject({ heldout: { count: 21, n: 25 }, insample: { count: 33, n: 50 } });
  expect(combined.answers).toMatchObject({ heldout: { count: 24, n: 25 }, insample: { count: 46, n: 50 } });
  expect(m.routes.find((r) => r.key === "grep")!.finds).toMatchObject({ heldout: null, insample: null });
  expect(m.sampleNote).toBe("50 of the 75 questions are in-sample: the routes were tuned on them, so the held-out questions are the fairer test.");
  expect(ragEvalModel([]).sampleNote).toBeNull();
});

test("ragEvalModel: the bottom line compares two routes only inside one run", () => {
  const split = ragEvalModel([
    re("2026-11-05T13:15:18Z", "ok", { "combined.hit@5": 0.72 }), re("2026-11-06T13:15:18Z", "ok", { "grep.hit@5": 0.33 }),
    ab("2026-11-05T19:20:03Z", 75, arm("fused-cached", 70, 75)), ab("2026-11-06T19:20:03Z", 75, arm("vanilla", 30, 75)),
  ]);
  expect(split.routes.find((r) => r.key === "grep")!.finds).toMatchObject({ ts: "2026-11-06T13:15:18Z" });
  expect(split.bottomLine).toBe("Not enough has been measured yet to compare combined search with grep or vanilla Claude.");
});

test("ragEvalModel: a row with no sample (n 0) is skipped for an older one with a sample", () => {
  const m = ragEvalModel([
    re("2026-11-05T13:15:18Z", "ok", { "grep.hit@5": 0.3333 }),
    { ...re("2026-11-06T13:15:18Z", "ok", { "grep.hit@5": 0 }), n: 0 },
    ab("2026-11-05T19:20:03Z", 75, arm("vanilla", 69, 75)), ab("2026-11-06T19:20:03Z", 0, arm("vanilla", 0, 0)),
  ]);
  expect(m.routes.find((r) => r.key === "grep")!.finds).toMatchObject({ count: 25, n: 75 });
  expect(m.routes.find((r) => r.key === "vanilla")!.answers).toMatchObject({ count: 69, n: 75 });
});

test("wilson: the 95% range the audit quotes for 69 of 75", () => {
  const [lo, hi] = wilson(69, 75);
  expect(lo).toBeCloseTo(0.836, 3);
  expect(hi).toBeCloseTo(0.963, 3);
});

test("isRagEvalHash: the agui fragment page=rag-eval opens the page", () => {
  expect(isRagEvalHash("#t=abc&page=rag-eval")).toBe(true);
  expect(isRagEvalHash("#t=abc")).toBe(false);
  expect(isRagEvalHash("#t=abc&run=x")).toBe(false);
});

test("GET /api/rag-eval: token-gated, GET only, serves the retrieval-eval and answer-ab rows without their cases", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rag-eval-"));
  const ledger = join(dir, "eval-runs.jsonl");
  const lines = [...ROWS.map((r) => ({ ...r, cases: { q01: { "combined.hit": true } }, host: "station", config: { arms: ["combined"] } })), { eval: "leg-trajectory", ts: "2026-11-07T00:00:00Z", status: "ok" }];
  writeFileSync(ledger, lines.map((r) => JSON.stringify(r)).join("\n") + "\nnot json\n");
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: dir, HIMMEL_EVAL_RUNS_LEDGER: ledger } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const url = `http://127.0.0.1:${s.port}/api/rag-eval`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const body = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(body.state).toBe("ok");
  expect(body.rows.map((r: LedgerRow) => r.eval)).toEqual(["retrieval-eval", "retrieval-eval", "retrieval-eval", "answer-ab", "answer-ab"]);
  for (const r of body.rows) expect(Object.keys(r).sort()).toEqual(["eval", "metrics", "n", "run_id", "status", "ts"]);
  expect(ragEvalModel(body.rows).bottomLine).toBe(ragEvalModel(ROWS).bottomLine);
  rmSync(ledger);
  expect(await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json()).toEqual({ state: "absent", rows: [] });
  mkdirSync(ledger);
  const bad = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(bad).toEqual({ state: "unreadable", reason: "the eval-runs ledger could not be read", rows: [] });
});
