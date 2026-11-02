// The Board page's two reads beside GET /api/roadmap: the saved status-drift summary (drift-summary.mjs) and the
// chain read (chain-state.mjs). READ ONLY: each is a chief-kit script that prints JSON and writes nothing, run with an explicit
// argument list and a small environment, and never started unless its input is found: named in the environment
// (HIMMEL_FOCUS_DRIFT, TRACKER_HANDOVERS_DIR, HIMMEL_CHAIN_REGISTRY) or, on a real launch, the newest file of that name under
// <HANDOVER_DIR>/<slug>/himmel/. A test therefore reaches only the paths it sets: with none of these nothing is spawned and
// the page shows both as absent, with the reason, never as a count.
import { execFile } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
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

export async function readBoardExtras(env: Env): Promise<BoardExtras> {
  const mirror = jiraMirrorDir(env);
  const file = driftFile(env);
  const registry = chainRegistry(env);
  const drift = file ? runReader(join(KIT, "drift-summary.mjs"), ["--json", "--drift", file, "--mirror-dir", mirror], env, "the drift summary")
    : Promise.resolve(absent("no saved drift run: none found under the handover root, and HIMMEL_FOCUS_DRIFT is not set"));
  // the chain read's state dir (hold and merge rows) is the script's own: TICKET_STATUS_STATE_DIR, else $HOME/.himmel/state
  const chains = registry ? runReader(join(KIT, "chain-state.mjs"), ["--json", "--registry", registry, "--mirror", mirror], env, "the chain read")
    : Promise.resolve(absent("no chain registry: none found under the handover root, and HIMMEL_CHAIN_REGISTRY is not set"));
  const [d, c] = await Promise.all([drift, chains]);
  return { drift: d, chains: c };
}
