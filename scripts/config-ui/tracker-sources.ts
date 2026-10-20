// tracker-sources.ts — which trackers the UI can read for Roadmap and Kanban, and the GitHub issues reader.
// trackerSources() is the one predicate: the rail shows Roadmap and Kanban only when it lists something. A source
// the UI has no reader for (TRACKER=local) or cannot read right now (no mirror, gh unauthenticated) is not listed.
// Read-only: gh is only ever asked to list issues, and the Jira CLI is never touched here.
import { execFile, execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type TrackerSource = "jira" | "github";
type Env = Record<string, string | undefined>;
export type GhIssue = {
  number: number; title: string; state: string; stateReason?: string | null; updatedAt?: string;
  labels?: { name: string }[]; milestone?: { number: number; title: string } | null;
};

const GH_TIMEOUT_MS = 20_000;
// gh issue list stops at the limit with no marker, so a full page is how the board knows it may be partial.
export const ISSUE_LIMIT = 1000;
const ISSUE_FIELDS = "number,title,state,stateReason,labels,milestone,updatedAt";

export const jiraMirrorDir = (env: Env) => env.HIMMEL_JIRA_MIRROR || join(env.HOME || homedir(), ".himmel", "state", "jira-mirror", env.JIRA_PROJECT_KEY || "HIMMEL");

function trackerSetting(env: Env, root: string): string {
  if (env.TRACKER) return env.TRACKER;
  try { return execFileSync("git", ["-C", root, "config", "--get", "himmel.tracker"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return ""; }
}

// gh by argv, no shell; GH_CMD replaces the binary (the tests' stub). A failure is { ok: false }, never a throw.
function gh(env: Env, root: string, args: string[]): Promise<{ ok: boolean; out: string }> {
  return new Promise((done) => {
    execFile(env.GH_CMD || "gh", args, { cwd: root, env: env as NodeJS.ProcessEnv, timeout: GH_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => done({ ok: !err, out: String(stdout) }));
  });
}

// github is listed only when the tracker setting names it, so it comes first: an explicit choice beats a mirror that merely exists.
export async function trackerSources(env: Env, root: string): Promise<TrackerSource[]> {
  const out: TrackerSource[] = [];
  if (trackerSetting(env, root) === "github" && (await gh(env, root, ["auth", "status"])).ok) out.push("github");
  try { if (readdirSync(jiraMirrorDir(env)).some((f) => /^HIMMEL-\d+\.md$/.test(f))) out.push("jira"); } catch { /* no mirror */ }
  return out;
}

// every issue of the repo gh resolves from root; null when gh fails or answers something other than a list.
export async function readGithubIssues(env: Env, root: string): Promise<GhIssue[] | null> {
  const r = await gh(env, root, ["issue", "list", "--state", "all", "--limit", String(ISSUE_LIMIT), "--json", ISSUE_FIELDS]);
  if (!r.ok) return null;
  try {
    const j = JSON.parse(r.out);
    return Array.isArray(j) ? j.filter((i) => i && typeof i.number === "number" && typeof i.state === "string") : null;
  } catch { return null; }
}
