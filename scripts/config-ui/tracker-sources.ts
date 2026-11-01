// tracker-sources.ts — which trackers the UI can read for Roadmap and Kanban, and the GitHub issues reader.
// trackerSources() is the one predicate: the rail shows Roadmap and Kanban only when it lists something. A source
// the UI cannot read right now (no mirror, an empty local store, gh unauthenticated) is not listed; TRACKER=none is listed as
// "none" so both pages can say no tracker is configured. Read-only: gh is only ever asked to list issues, the local store is
// read through the tracker seam (local-tracker.ts), and the Jira CLI is never touched here.
import { execFile, execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readConfLayers } from "./conf-layers";
import { readLocalItems } from "./local-tracker";
// @ts-ignore -- plain ESM resolver shared with project-mode.sh, no type declarations
import { projectModeTracker } from "../lib/project-mode.mjs";

export type TrackerSource = "jira" | "github" | "local" | "none";
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
  const fromEnv = env.TRACKER || readConfLayers(env).TRACKER;
  if (fromEnv) return fromEnv;
  try { return execFileSync("git", ["-C", root, "config", "--get", "himmel.tracker"], { encoding: "utf8", timeout: 5000, env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return ""; }
}

// gh by argv, no shell; GH_CMD replaces the binary (the tests' stub). A failure is { ok: false }, never a throw.
function gh(env: Env, root: string, args: string[]): Promise<{ ok: boolean; out: string }> {
  return new Promise((done) => {
    execFile(env.GH_CMD || "gh", args, { cwd: root, env: env as NodeJS.ProcessEnv, timeout: GH_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => done({ ok: !err, out: String(stdout) }));
  });
}

// The backend the tracker seam would use (jira | local | none), from the same resolver; "" when it refuses (TRACKER=github is
// the forge's tracker, not a seam backend).
function seamBackend(env: Env, root: string): string {
  const conf = readConfLayers(env);
  const e = { ...env, TRACKER: env.TRACKER || conf.TRACKER || "", JIRA_PROJECT_KEY: env.JIRA_PROJECT_KEY || conf.JIRA_PROJECT_KEY || "" };
  try { return projectModeTracker({ cwd: root, env: e }); } catch { return ""; }
}

// github is listed only when the tracker setting names it, so it comes first: an explicit choice beats a mirror that merely exists.
// The local store and none come next, for the same reason; the Jira mirror is listed last whenever it holds tickets.
export async function trackerSources(env: Env, root: string): Promise<TrackerSource[]> {
  const out: TrackerSource[] = [];
  if (trackerSetting(env, root) === "github" && (await gh(env, root, ["auth", "status"])).ok) out.push("github");
  const backend = seamBackend(env, root);
  if (backend === "local" && (await readLocalItems(env, root))?.length) out.push("local");
  if (backend === "none") out.push("none");
  try { if (readdirSync(jiraMirrorDir(env)).some((f) => /^HIMMEL-\d+\.md$/.test(f))) out.push("jira"); } catch { /* no mirror */ }
  return out;
}

// the fields the mapping consumes, forced to their types so one malformed entry cannot break the whole board.
const clean = (i: GhIssue): GhIssue => ({
  ...i,
  title: String(i.title ?? ""),
  labels: Array.isArray(i.labels) ? i.labels.filter((l) => l && typeof l.name === "string") : [],
  milestone: i.milestone && typeof i.milestone.number === "number" && typeof i.milestone.title === "string" ? i.milestone : null,
});

// every issue of the repo gh resolves from root; null when gh fails or answers something other than a list.
export async function readGithubIssues(env: Env, root: string): Promise<GhIssue[] | null> {
  const r = await gh(env, root, ["issue", "list", "--state", "all", "--limit", String(ISSUE_LIMIT), "--json", ISSUE_FIELDS]);
  if (!r.ok) return null;
  try {
    const j = JSON.parse(r.out);
    return Array.isArray(j) ? j.filter((i) => i && typeof i.number === "number" && typeof i.state === "string").map(clean) : null;
  } catch { return null; }
}
