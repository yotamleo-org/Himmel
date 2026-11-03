// The Board page's two reads beside GET /api/roadmap: the saved status-drift summary (drift-summary.mjs) and the
// chain read (chain-state.mjs). READ ONLY: each is a chief-kit script that prints JSON and writes nothing, run with an explicit
// argument list and a small environment, and never started unless its input is found: named in the environment
// (HIMMEL_FOCUS_DRIFT, TRACKER_HANDOVERS_DIR, HIMMEL_CHAIN_REGISTRY) or, on a real launch, the newest file of that name under
// <HANDOVER_DIR>/<slug>/himmel/. A test therefore reaches only the paths it sets: with none of these nothing is spawned and
// the page shows both as absent, with the reason, never as a count.
import { execFile } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { readRoadmap } from "./roadmap";
import { jiraMirrorDir } from "./tracker-sources";

type Env = Record<string, string | undefined>;
export type Absent = { state: "absent"; reason: string };
export type BoardExtras = { drift: Record<string, unknown> | Absent; chains: Record<string, unknown> | Absent };

const KIT = resolve(import.meta.dir, "../handover/chief-kit");
export const TIMEOUT_MS = 10_000;
const absent = (reason: string): Absent => ({ state: "absent", reason });

// The child sees only what these readers use. HOME and HIMMEL_CONFIG_DIR matter: drift-summary reads the tracker mode from the config layers.
const KEEP = ["PATH", "HOME", "HIMMEL_CONFIG_DIR", "HIMMEL_TRACKER_TEAM_MODE", "DRIFT_SUMMARY_KNOWN", "JIRA_PROJECT_KEY", "TICKET_STATUS_STATE_DIR"];
const childEnv = (env: Env) => Object.fromEntries(KEEP.map((k) => [k, env[k] ?? (k === "PATH" ? process.env.PATH : undefined)]).filter(([, v]) => v !== undefined)) as NodeJS.ProcessEnv;

// Runs one reader script (an absolute path) with the small environment and a time limit; a failure or a non-JSON answer is absent, with the reason.
export function runReader(script: string, args: string[], env: Env, what: string, timeoutMs = TIMEOUT_MS): Promise<Record<string, unknown> | Absent> {
  return new Promise((done) => {
    execFile("node", [script, ...args], { env: childEnv(env), timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) return done(absent(`${what} failed: ${String(stderr || (err as Error).message).trim().split("\n").pop()?.slice(0, 200)}`));
      try { done(JSON.parse(stdout) as Record<string, unknown>); } catch { done(absent(`${what} printed no JSON`)); }
    });
  });
}

// The newest <HANDOVER_DIR>/<slug>/himmel/<name>: where the doctor reads focus-drift.txt and the focus refresh keeps chains.json.
function inHandoverRoot(env: Env, name: string): string | undefined {
  if (!env.HANDOVER_DIR) return undefined;
  let best: { p: string; t: number } | undefined;
  try {
    for (const e of readdirSync(env.HANDOVER_DIR, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const p = join(env.HANDOVER_DIR, e.name, "himmel", name);
      try { const t = statSync(p).mtimeMs; if (statSync(p).isFile() && (!best || t > best.t)) best = { p, t }; } catch { /* no such file under this slug */ }
    }
  } catch { /* an unreadable handover root reads as no file */ }
  return best?.p;
}

// An explicit setting wins; otherwise the handover root's own file.
export function driftFile(env: Env): string | undefined {
  return env.HIMMEL_FOCUS_DRIFT || (env.TRACKER_HANDOVERS_DIR ? join(env.TRACKER_HANDOVERS_DIR, "focus-drift.txt") : inHandoverRoot(env, "focus-drift.txt"));
}
export const chainRegistry = (env: Env) => env.HIMMEL_CHAIN_REGISTRY || inHandoverRoot(env, "chains.json");

// The version the cards call running. Without it the chain read covers every version, and a blocker outside the version cannot read as blocked.
// ponytail: this reads the mirror a second time beside GET /api/roadmap, upgrade path: hand the page's own read to this one if it ever shows in the Board's load time.
function runningVersion(mirror: string, env: Env): string | undefined {
  try {
    const r = readRoadmap({ mirrorDir: mirror, projects: [{ key: env.JIRA_PROJECT_KEY || "HIMMEL", dir: mirror }], workers: { state: "absent" } });
    return r.versions[r.cur]?.n;
  } catch { return undefined; }
}

type BurnTicket = { done?: boolean; check?: { merge?: { ts?: string } | null } | null };
// One point per day from the first merge to today. A done ticket with no merge row has no date: it leaves the total and is counted as undated.
export function burnDown(read: { now?: string; tickets?: Record<string, BurnTicket> }) {
  const all = Object.values(read.tickets ?? {});
  const dated = all.filter((t) => t.done && t.check?.merge?.ts).map((t) => t.check!.merge!.ts!.slice(0, 10)).sort();
  const undated = all.filter((t) => t.done).length - dated.length, total = all.length - undated;
  const points: { day: string; open: number; merged: number }[] = [];
  const last = Date.parse(`${(read.now ?? new Date().toISOString()).slice(0, 10)}T00:00:00Z`);
  let open = total;
  for (let at = dated.length ? Date.parse(`${dated[0]}T00:00:00Z`) : Infinity; at <= last; at += 86_400_000) {
    const day = new Date(at).toISOString().slice(0, 10), merged = dated.filter((d) => d === day).length;
    open -= merged;
    points.push({ day, open, merged });
  }
  return { total, undated, points };
}

export async function readBoardExtras(env: Env): Promise<BoardExtras> {
  const mirror = jiraMirrorDir(env);
  const file = driftFile(env);
  const registry = chainRegistry(env);
  const drift = file ? runReader(join(KIT, "drift-summary.mjs"), ["--json", "--drift", file, "--mirror-dir", mirror], env, "the drift summary")
    : Promise.resolve(absent("no saved drift run: none found under the handover root, and HIMMEL_FOCUS_DRIFT is not set"));
  // the chain read's state dir (hold and merge rows) is the script's own: TICKET_STATUS_STATE_DIR, else $HOME/.himmel/state
  const version = registry ? runningVersion(mirror, env) : undefined;
  const chains = registry ? runReader(join(KIT, "chain-state.mjs"), ["--json", "--registry", registry, "--mirror", mirror, ...(version ? ["--version", version] : [])], env, "the chain read")
      .then((r) => ("tickets" in r ? { ...r, burn: burnDown(r as Parameters<typeof burnDown>[0]) } : r))
    : Promise.resolve(absent("no chain registry: none found under the handover root, and HIMMEL_CHAIN_REGISTRY is not set"));
  const [d, c] = await Promise.all([drift, chains]);
  return { drift: d, chains: c };
}
