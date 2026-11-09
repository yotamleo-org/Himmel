import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isRagEvalHash, NOT_MEASURED, ragEvalModel, pilotModel, wilson, type LedgerRow } from "../agui-web/src/rag-eval-model";
import { readFileSync } from "node:fs";
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

test("ragEvalModel: a row that records file_hit, not correct, is read and picked as newest", () => {
  const renamed = Object.fromEntries(Object.entries({
    ...arm("vanilla", 60, 75), "vanilla.heldout.correct": 20, "vanilla.heldout.n": 25,
  }).map(([k, v]) => [k.replace(/\.correct$/, ".file_hit"), v]));
  const m = ragEvalModel([ab("2026-11-05T19:20:03Z", 75, arm("vanilla", 69, 75)), ab("2026-11-09T10:00:00Z", 75, renamed)]);
  expect(m.routes.find((r) => r.key === "vanilla")!.answers).toMatchObject({ count: 60, n: 75, ts: "2026-11-09T10:00:00Z", heldout: { count: 20, n: 25 } });
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

// ---------------------------------------------------------------------------------------------
// The three-answer pilot rows: report.py emits them, the real server reader allowlists them,
// the model draws them. Generated fresh from report.py on every run (the committed copy is the
// same bytes; test-score.sh proves that), never hand-written.
const REPORT = join(import.meta.dir, "..", "..", "eval", "retrieval-eval", "pilot", "report.py");
function pilotRows(): Record<string, unknown>[] {
  const dir = mkdtempSync(join(tmpdir(), "rag-pilot-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const out = join(dir, "rows.jsonl");
  const p = Bun.spawnSync(["python3", "-I", REPORT, "fixtures", "--out", out]);
  expect(p.exitCode).toBe(0);
  return readFileSync(out, "utf8").trim().split("\n").map((l) => JSON.parse(l));
}
async function served(lines: Record<string, unknown>[]): Promise<LedgerRow[]> {
  const dir = mkdtempSync(join(tmpdir(), "rag-served-"));
  const ledger = join(dir, "eval-runs.jsonl");
  writeFileSync(ledger, lines.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: dir, HIMMEL_EVAL_RUNS_LEDGER: ledger } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const body = await (await fetch(`http://127.0.0.1:${s.port}/api/rag-eval`, { headers: { "X-Himmel-Token": TOKEN } })).json();
  return body.rows;
}
const only = (rows: Record<string, unknown>[], id: string) => rows.filter((r) => r.run_id === id || !r.protocol);
const pilotOf = (id: string) => only(pilotRows(), id).filter((r) => r.protocol)[0];
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x));

test("pilot: report.py rows round-trip through the real reader into the model", async () => {
  const rows = await served(only(pilotRows(), "fixture-rag-pilot-r18-short"));
  const pilotRow = rows.find((r) => r.protocol === "rag-pilot-r18")!;
  expect(Object.keys(pilotRow).sort()).toEqual(["eval", "metrics", "n", "pilot", "protocol", "run_id", "status", "ts"]);
  const p = pilotModel(rows)!;
  expect(p.status).toBe("short");
  expect(p.n).toBe(37);
  expect(p.stopNote).toBe("Short pilot: 37 of 40 tasks scored in all three setups");
  expect(p.clauses!.map((c) => c.arm)).toEqual(["S", "Q"]);
  expect(p.clauses![0].answer).toContain("Station search (S): S gave far more supported answers.");
  expect(p.clauses![1].answer).toContain("Local search (Q): Q: no family-adjusted answer improvement established; not far better.");
  expect(p.clauses![0].answer).toMatch(/raw p <0\.001, Holm-adjusted p 0\.002; pointwise 95% Tango score interval, not simultaneous 17\.5 to 45\.8 points/);
  expect(p.judge).toContain("4 complete rounds applied, 1 partial-round verdicts discarded; unjudged V 1, S 1, Q 0");
  expect(p.cells.map((c) => c.title)).toEqual(["By kind", "Real and harder halves", "Doc, code and mixed sources"]);
  expect(p.cells[2].rows.length).toBeGreaterThan(0);
  expect(p.disclosures.join(" ")).toContain("eval-only-reachable");
  expect(p.disclosures.join(" ")).toContain("Q can stop or void the S-V measurement");
  expect(p.lists[0]).toBe("Retrieval lists are incomplete: no full 40-task list comparison.");
  expect(p.spend).toBe("Spend on every attempted task: $9.12 (subscription equivalent $8.81, search cash $0.31).");
  // the old file-hit row is its own protocol group: the pilot never feeds the routes table
  expect(ragEvalModel(rows).routes.find((r) => r.key === "vanilla")!.answers).toMatchObject({ count: 69, n: 75 });
});

test("pilot: the safe allowlist drops every field it does not name, at every depth", async () => {
  const t = clone(pilotOf("fixture-rag-pilot-r18-short")) as Record<string, any>;
  t.pilot.task_ids = ["t01", "t02"];
  t.pilot.per_arm.S.private_path = "/somewhere/private/tasks.jsonl";
  t.pilot.comparisons[0].question = "a private question";
  t.cases = { t01: { "S.supported": true } };
  t.meta = { identity: { harness_commit: "x" } };
  const text = JSON.stringify(await served([t]));
  for (const leak of ["t01", "private/tasks", "a private question", "harness_commit", "cases"]) expect(text).not.toContain(leak);
  expect(text).toContain("S gave far more supported answers.");
});

test("pilot: S and Q results stay attached to their arm whatever the comparison order", async () => {
  const f = clone(pilotOf("fixture-rag-pilot-r18-short")) as Record<string, any>;
  f.pilot.comparisons.reverse();
  const p = pilotModel(await served([f]))!;
  expect(p.clauses!.map((c) => [c.arm, c.comparison.contrast])).toEqual([["S", "S-V"], ["Q", "Q-V"]]);
  expect(p.clauses![0].answer).toContain("S gave far more supported answers.");
});

test("pilot: a void or hard-stopped run exposes no answer comparison", async () => {
  const p = pilotModel(await served(only(pilotRows(), "fixture-rag-pilot-r18-void")))!;
  expect(p.status).toBe("void");
  expect(p.clauses).toBeNull();
  expect(p.exploratory).toBeNull();
  expect(p.noComparison).toBe("No answer comparison: the run hard-stopped (insufficient_common_cohort) with 0 common tasks. Only spend and service state are shown.");
  expect(p.headline).toBe("The pilot gives no answer comparison.");
  expect(p.lists).toEqual(["Retrieval lists: not run."]);
});

test("pilot: a missing Q result or common task set refuses the comparison", async () => {
  const noQ = clone(pilotOf("fixture-rag-pilot-r18-mixed")) as Record<string, any>;
  noQ.pilot.comparisons = noQ.pilot.comparisons.filter((c: { contrast: string }) => c.contrast !== "Q-V");
  const noCohort = clone(pilotOf("fixture-rag-pilot-r18-mixed")) as Record<string, any>;
  noCohort.pilot.common_cohort_hash = null;
  for (const r of [noQ, noCohort]) {
    const p = pilotModel(await served([r]))!;
    expect(p.clauses).toBeNull();
    expect(p.noComparison).toBe("No answer comparison: the row lacks the S and Q results against V on one common task set.");
  }
});

test("pilot: exploratory S-Q never becomes a primary result, even if a row marks it confirmatory", async () => {
  const forged = clone(pilotOf("fixture-rag-pilot-r18-mixed")) as Record<string, any>;
  const sq = forged.pilot.comparisons.find((c: { contrast: string }) => c.contrast === "S-Q");
  Object.assign(sq, { confirmatory: true, family: "baseline-holm2", p_adjusted: 0.001, label: "S gave far more supported answers than Q." });
  const p = pilotModel(await served([forged]))!;
  expect(p.clauses!.map((c) => c.comparison.contrast)).toEqual(["S-V", "Q-V"]);
  expect(p.exploratory).toMatchObject({ contrast: "S-Q", confirmatory: false, label: null, pAdjusted: null });
  expect(p.headline).not.toContain("than Q");
});

test("pilot: the real-half qualifier names only its own arm; a loss is never hidden by the other arm's win", async () => {
  const mixed = pilotModel(await served(only(pilotRows(), "fixture-rag-pilot-r18-mixed")))!;
  expect(mixed.headline).toBe("Station search (S): S: far better only on tasks built to need search; not shown on real questions. "
    + "Local search (Q): Q: no family-adjusted answer improvement established; not far better.");
  const loss = pilotModel(await served(only(pilotRows(), "fixture-rag-pilot-r18-all-loss")))!;
  expect(loss.clauses!.map((c) => c.loss)).toEqual([true, true]);
  expect(loss.headline).toBe("Station search (S): Plain Claude Code beat S here. Local search (Q): Plain Claude Code beat Q here.");
  const qLoses = clone(pilotOf("fixture-rag-pilot-r18-short")) as Record<string, any>;
  Object.assign(qLoses.pilot.comparisons.find((c: { contrast: string }) => c.contrast === "Q-V"), { gain_pp: -20, p_adjusted: 0.01, label: "Plain Claude Code beat Q here." });
  const p = pilotModel(await served([qLoses]))!;
  expect(p.headline).toContain("Plain Claude Code beat Q here.");
  expect(p.headline).toContain("S gave far more supported answers.");
});

test("pilot: every cost clause is drawn with the same prominence as its answer clause", async () => {
  for (const id of ["fixture-rag-pilot-r18-short", "fixture-rag-pilot-r18-mixed", "fixture-rag-pilot-r18-all-loss"]) {
    const p = pilotModel(await served(only(pilotRows(), id)))!;
    for (const c of p.clauses!) {
      expect(c.costClass).toBe(c.answerClass);
      expect(c.cost.length).toBeGreaterThan(40);
      expect(c.cost).toMatch(/cost: \$\d+\.\d\d for the run against \$\d+\.\d\d for plain Claude Code; per task/);
    }
  }
});

test("pilot: unavailable evidence stays visible as unavailable, never dropped", async () => {
  const thin = clone(pilotOf("fixture-rag-pilot-r18-short")) as Record<string, any>;
  delete thin.pilot.per_arm.S.route;
  thin.pilot.lists.S.fact_file_at5 = null;
  const p = pilotModel(await served([thin]))!;
  expect(p.arms.find((a) => a.arm === "S")!.route).toBe("unavailable");
  expect(p.lists.join(" ")).toContain("Station search (S) fixed lists: a file holding a required fact in the top five on unavailable");
});

test("pilot: no ticket id appears in the page copy", async () => {
  for (const r of pilotRows().filter((x) => x.protocol)) {
    expect(JSON.stringify(pilotModel(await served([r])))).not.toMatch(/HIMMEL-\d+/);
  }
  const src = readFileSync(join(import.meta.dir, "..", "agui-web", "src", "RagEval.tsx"), "utf8") + readFileSync(join(import.meta.dir, "..", "agui-web", "src", "rag-eval-model.ts"), "utf8");
  expect(src).not.toMatch(/HIMMEL-\d+/);
});
