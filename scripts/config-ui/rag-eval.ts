// GET /api/rag-eval: the retrieval-eval and answer-ab rows of the eval-runs ledger, for the RAG eval page. Read-only: it never runs an eval.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
const EVALS = new Set(["retrieval-eval", "answer-ab"]);

export function readRagEvalRows(env: Env): { state: "ok" | "absent"; rows: Record<string, unknown>[] } {
  let text: string;
  try { text = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER || join(env.HOME || homedir(), ".himmel", "eval-runs.jsonl"), "utf8"); }
  catch { return { state: "absent", rows: [] }; }
  const rows: Record<string, unknown>[] = [];
  for (const line of text.split("\n")) {
    if (!line.includes('"retrieval-eval"') && !line.includes('"answer-ab"')) continue; // most of the ledger is other evals: skip them unparsed
    let r: unknown;
    try { r = JSON.parse(line); } catch { continue; }
    if (!r || typeof r !== "object" || !EVALS.has((r as { eval?: string }).eval ?? "")) continue;
    const { cases: _cases, ...row } = r as Record<string, unknown>; // per-question detail the page does not draw
    rows.push(row);
  }
  return { state: "ok", rows };
}
