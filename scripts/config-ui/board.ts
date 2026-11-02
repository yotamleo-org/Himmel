// The Board page's two reads beside GET /api/roadmap: the saved status-drift summary (drift-summary.mjs) and the
// chain read (chain-state.mjs). READ ONLY: each is a chief-kit script that prints JSON and writes nothing, run with an explicit
// argument list and a small environment, and never started unless its input is named. A test therefore reaches only the
// paths it sets: with no HIMMEL_FOCUS_DRIFT (or TRACKER_HANDOVERS_DIR) and no HIMMEL_CHAIN_REGISTRY nothing is spawned and
// the page shows both as absent, with the reason, never as a count.
import { execFile } from "node:child_process";
import { join, resolve } from "node:path";
import { jiraMirrorDir } from "./tracker-sources";

type Env = Record<string, string | undefined>;
export type Absent = { state: "absent"; reason: string };
export type BoardExtras = { drift: Record<string, unknown> | Absent; chains: Record<string, unknown> | Absent };

const KIT = resolve(import.meta.dir, "../handover/chief-kit");
const TIMEOUT_MS = 10_000;
const absent = (reason: string): Absent => ({ state: "absent", reason });

// The child sees only what these readers use. HOME and HIMMEL_CONFIG_DIR matter: drift-summary reads the tracker mode from the config layers.
const KEEP = ["PATH", "HOME", "HIMMEL_CONFIG_DIR", "HIMMEL_TRACKER_TEAM_MODE", "DRIFT_SUMMARY_KNOWN", "JIRA_PROJECT_KEY", "TICKET_STATUS_STATE_DIR"];
const childEnv = (env: Env) => Object.fromEntries(KEEP.map((k) => [k, env[k] ?? (k === "PATH" ? process.env.PATH : undefined)]).filter(([, v]) => v !== undefined)) as NodeJS.ProcessEnv;

function readJson(script: string, args: string[], env: Env, what: string): Promise<Record<string, unknown> | Absent> {
  return new Promise((done) => {
    execFile("node", [join(KIT, script), ...args], { env: childEnv(env), timeout: TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) return done(absent(`${what} failed: ${String(stderr || (err as Error).message).trim().split("\n").pop()?.slice(0, 200)}`));
      try { done(JSON.parse(stdout) as Record<string, unknown>); } catch { done(absent(`${what} printed no JSON`)); }
    });
  });
}

export function driftFile(env: Env): string | undefined {
  return env.HIMMEL_FOCUS_DRIFT || (env.TRACKER_HANDOVERS_DIR ? join(env.TRACKER_HANDOVERS_DIR, "focus-drift.txt") : undefined);
}

export async function readBoardExtras(env: Env): Promise<BoardExtras> {
  const mirror = jiraMirrorDir(env);
  const file = driftFile(env);
  const registry = env.HIMMEL_CHAIN_REGISTRY;
  const drift = file ? readJson("drift-summary.mjs", ["--json", "--drift", file, "--mirror-dir", mirror], env, "the drift summary")
    : Promise.resolve(absent("no saved drift run is configured (set HIMMEL_FOCUS_DRIFT or TRACKER_HANDOVERS_DIR)"));
  // the chain read's state dir (hold and merge rows) is the script's own: TICKET_STATUS_STATE_DIR, else $HOME/.himmel/state
  const chains = registry ? readJson("chain-state.mjs", ["--json", "--registry", registry, "--mirror", mirror], env, "the chain read")
    : Promise.resolve(absent("no chain registry: set HIMMEL_CHAIN_REGISTRY to a himmel.chain-registry/1 file"));
  const [d, c] = await Promise.all([drift, chains]);
  return { drift: d, chains: c };
}
