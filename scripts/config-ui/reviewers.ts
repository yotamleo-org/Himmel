// reviewers.ts — the read-only source behind GET /api/reviewers: the typed code-reviewer report, computed on each GET by
// the trusted scripts/eval/review-page.py --reviewers-json over the eval-runs, eval-changes and CR ledgers, so a new
// ledger record shows at the next GET. An explicit REVIEW_PAGE_FILE keeps the stored-snapshot mode: that Markdown file as
// text, a missing file absent, any other read failure an error. Nothing is recomputed here or in the browser.
import { execFile } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
type State = "ok" | "partial" | "absent" | "error";
export type CodeReviewers = { v: 1; state: State; [k: string]: unknown };
export type Reviewers =
  | { state: "ok"; mode: "snapshot"; text: string; writtenAt: string }
  | { state: "absent" | "error"; mode: "snapshot" | "report"; reason: string; codeReviewers?: CodeReviewers }
  | { state: "ok" | "partial"; mode: "report"; codeReviewers: CodeReviewers };

export const REVIEW_PAGE_SCRIPT = join(import.meta.dir, "..", "eval", "review-page.py");
export const REPORT_TIMEOUT_MS = 10_000;
export const REPORT_MAX_BYTES = 2 * 1024 * 1024;
const STATES = new Set<string>(["ok", "partial", "absent", "error"]);

function readSnapshot(file: string): Reviewers {
  try {
    return { state: "ok", mode: "snapshot", text: readFileSync(file, "utf8"), writtenAt: statSync(file).mtime.toISOString() };
  } catch (e) {
    const code = String((e as NodeJS.ErrnoException).code || "EIO");
    return code === "ENOENT" ? { state: "absent", mode: "snapshot", reason: "no stored review page" } : { state: "error", mode: "snapshot", reason: code };
  }
}

export type ReadOpts = { crLedger?: string; now?: () => number; script?: string; timeoutMs?: number };

// script and timeoutMs are test seams set in code, never from env: the route always runs the checkout's own script.
export function readReviewers(env: Env, opts: ReadOpts = {}): Promise<Reviewers> {
  if (env.REVIEW_PAGE_FILE) return Promise.resolve(readSnapshot(env.REVIEW_PAGE_FILE));
  const home = env.HOME || homedir();
  const argv = ["-I", opts.script ?? REVIEW_PAGE_SCRIPT, "--reviewers-json",
    "--ledger", env.HIMMEL_EVAL_RUNS_LEDGER || join(home, ".himmel", "eval-runs.jsonl"),
    "--changes", env.HIMMEL_EVAL_CHANGES_LEDGER || join(home, ".himmel", "eval-changes.jsonl"),
    "--cr-ledger", env.CR_LEDGER || opts.crLedger || "",
    "--now", new Date((opts.now ?? Date.now)()).toISOString()];
  const fail = (reason: string): Reviewers => ({ state: "error", mode: "report", reason });
  return new Promise((resolve) => {
    execFile("python3", argv, { env: env as NodeJS.ProcessEnv, encoding: "utf8", shell: false, timeout: opts.timeoutMs ?? REPORT_TIMEOUT_MS, maxBuffer: REPORT_MAX_BYTES, killSignal: "SIGKILL", windowsHide: true }, (err, stdout) => {
      if (err) {
        const e = err as NodeJS.ErrnoException & { killed?: boolean; signal?: string | null; code?: unknown };
        if (e.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return resolve(fail("output over 2 MiB"));
        if (e.killed || e.signal) return resolve(fail("timed out"));
        return resolve(fail(typeof e.code === "number" ? `exit ${e.code}` : "could not run"));
      }
      let report: CodeReviewers;
      try { report = JSON.parse(stdout); } catch { return resolve(fail("invalid output")); }
      if (!report || typeof report !== "object" || report.v !== 1 || !STATES.has(report.state) || !Array.isArray(report.metrics) || !Array.isArray(report.sources)) return resolve(fail("invalid output"));
      if (report.state === "absent" || report.state === "error") return resolve({ state: report.state, mode: "report", reason: report.state === "absent" ? "no reviewer evidence yet" : "no source could be read", codeReviewers: report });
      resolve({ state: report.state as "ok" | "partial", mode: "report", codeReviewers: report });
    });
  });
}
