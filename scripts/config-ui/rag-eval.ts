import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
const EVALS = new Set(["retrieval-eval", "answer-ab"]);
const FIELDS = ["eval", "ts", "run_id", "status", "n", "metrics"];

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
    rows.push(Object.fromEntries(FIELDS.map((k) => [k, row[k]])));
  }
  return { state: "ok", rows };
}
