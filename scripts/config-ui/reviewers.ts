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

export function readReviewers(env: Env, opts: { crLedger?: string; now?: () => number } = {}): Promise<Reviewers> {
  if (env.REVIEW_PAGE_FILE) return Promise.resolve(readSnapshot(env.REVIEW_PAGE_FILE));
  const home = env.HOME || homedir();
  return runReport(env, REVIEW_PAGE_SCRIPT, REPORT_TIMEOUT_MS, ["--reviewers-json",
    "--ledger", env.HIMMEL_EVAL_RUNS_LEDGER || join(home, ".himmel", "eval-runs.jsonl"),
    "--changes", env.HIMMEL_EVAL_CHANGES_LEDGER || join(home, ".himmel", "eval-changes.jsonl"),
    "--cr-ledger", env.CR_LEDGER || opts.crLedger || "",
    "--now", new Date((opts.now ?? Date.now)()).toISOString()]);
}

export function runReport(env: Env, script: string, timeoutMs: number, args: string[]): Promise<Reviewers> {
  const fail = (reason: string): Reviewers => ({ state: "error", mode: "report", reason });
  return new Promise((resolve) => {
    execFile("python3", ["-I", script, ...args], { env: env as NodeJS.ProcessEnv, encoding: "utf8", shell: false, timeout: timeoutMs, maxBuffer: REPORT_MAX_BYTES, killSignal: "SIGKILL", windowsHide: true }, (err, stdout) => {
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
