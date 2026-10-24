// reviewers.ts — the read-only source behind GET /api/reviewers: the review page (scripts/eval/review-page.py,
// written weekly by scripts/eval/judge-accuracy/judge-accuracy-cadence.sh) as Markdown text. Nothing is
// recomputed here or in the browser. A missing file is state absent, never an error.
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
export type Reviewers = { state: "ok"; text: string; writtenAt: string } | { state: "absent"; reason: string };

export const reviewPageFile = (env: Env) => env.REVIEW_PAGE_FILE || join(env.HOME || homedir(), ".himmel", "state", "review-page", "review-page.md");

export function readReviewers(env: Env): Reviewers {
  const file = reviewPageFile(env);
  try {
    return { state: "ok", text: readFileSync(file, "utf8"), writtenAt: statSync(file).mtime.toISOString() };
  } catch {
    return { state: "absent", reason: "no review page yet (arm scripts/eval/judge-accuracy/judge-accuracy-cadence.sh)" };
  }
}
