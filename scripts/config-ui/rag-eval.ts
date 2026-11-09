import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
const EVALS = new Set(["retrieval-eval", "answer-ab"]);
const FIELDS = ["eval", "ts", "run_id", "status", "n", "metrics"];
export const PILOT_PROTOCOL = "rag-pilot-r18";

type Schema = "num" | "str" | "bool" | "nums" | Schema[] | { [k: string]: Schema } | { "*": Schema };
const ARM: Schema = {
  supported: "num", cost_usd: "num", cost_mean_usd: "num", cash_usd: "num",
  route: { offered: "num", called: "num", returned: "num", read: "num", cited: "num" },
  qmd_only: "num", graph_only: "num", both: "num", skips: "num", errors: "num", timeouts: "num",
  unjudged: "num", paraphrase_candidates: "num", latency_ms_median: "num", tokens_mean: "num",
};
const CELLS: Schema = { "*": { V: "nums", S: "nums", Q: "nums" } };
const LIST: Schema = { fact_file_at5: "nums", by_stratum: { "*": "nums" } };
const PILOT: Schema = {
  protocol: "str", arms: ["str"], stop_kind: "str", reason: "str", finalization_status: "str", void: "bool",
  counts: { attempted: "num", completed: "num", common_scored: "num" }, common_cohort_hash: "str",
  judge: { completed_rounds: "num", discarded_verdicts: "num", unjudged: { V: "num", S: "num", Q: "num" }, ended: "str" },
  supported: { V: "num", S: "num", Q: "num" }, per_arm: { V: ARM, S: ARM, Q: ARM },
  comparisons: [{
    contrast: "str", confirmatory: "bool", family: "str", discordant: "nums", p_raw: "num", p_adjusted: "num",
    gain_pp: "num", interval_pp: "nums", interval_label: "str", real_half_gain_pp: "num", label: "str",
  }],
  cost_intervals: { "S-V": "nums", "Q-V": "nums", "S-Q": "nums" }, kinds: CELLS, halves: CELLS, strata: CELLS,
  lists: { complete: "bool", S: LIST, Q: LIST }, exposure: "str", coupling: "str",
  spend: { subscription_equivalent_usd: "num", cash_usd: "num", total_usd: "num" },
};

const SAFE_KEY = /^[A-Za-z0-9_ +().-]{1,48}$/;
export function pick(v: unknown, s: Schema): unknown {
  if (v === null || v === undefined) return null;
  if (s === "num") return typeof v === "number" && Number.isFinite(v) ? v : null;
  if (s === "str") return typeof v === "string" ? v.slice(0, 400) : null;
  if (s === "bool") return typeof v === "boolean" ? v : null;
  if (s === "nums") return Array.isArray(v) ? v.map((x) => (typeof x === "number" && Number.isFinite(x) ? x : null)) : null;
  if (Array.isArray(s)) return Array.isArray(v) ? v.map((x) => pick(x, s[0])) : null;
  if (typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if ("*" in s) {
    return Object.fromEntries(Object.entries(o).filter(([k]) => SAFE_KEY.test(k)).slice(0, 24).map(([k, x]) => [k, pick(x, (s as { "*": Schema })["*"])]));
  }
  return Object.fromEntries(Object.entries(s).map(([k, sub]) => [k, pick(o[k], sub)]));
}

export function readRagEvalRows(env: Env): { state: "ok" | "absent" | "unreadable"; reason?: string; rows: Record<string, unknown>[] } {
  let text: string;
  try { text = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER || join(env.HOME || homedir(), ".himmel", "eval-runs.jsonl"), "utf8"); }
  catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return { state: "absent", rows: [] };
    return { state: "unreadable", reason: "the eval-runs ledger could not be read", rows: [] };
  }
  const rows: Record<string, unknown>[] = [];
  for (const line of text.split("\n")) {
    if (!line.includes('"retrieval-eval"') && !line.includes('"answer-ab"')) continue;
    let r: unknown;
    try { r = JSON.parse(line); } catch { continue; }
    if (!r || typeof r !== "object" || !EVALS.has((r as { eval?: string }).eval ?? "")) continue;
    const row = r as Record<string, unknown>;
    const out = Object.fromEntries(FIELDS.map((k) => [k, row[k]]));
    if (row.protocol === PILOT_PROTOCOL) Object.assign(out, { protocol: PILOT_PROTOCOL, pilot: pick(row.pilot, PILOT) });
    rows.push(out);
  }
  return { state: "ok", rows };
}
