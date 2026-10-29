// the config UI's read of the fleet cap (HIMMEL_FLEET_CAP). It is gate policy: the preflight reads ~/.himmel/config.json .policy,
// then the station checkout's legacy .env, then 4, and ignores the launching shell. The UI only shows it; there is no policy
// writer, so the operator edits config.json by hand.
import { readFileSync } from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";
import { parseDotEnv } from "../himmelctl/lib/probes.js";

type Env = Record<string, string | undefined>;
export type CapResult = { status: number; body: Record<string, unknown> };

const KEY = "HIMMEL_FLEET_CAP";
const DEFAULT_CAP = 4;
const HAND_EDIT = `~/.himmel/config.json .policy.${KEY}`;

// The preflight uses a value that is all digits and falls back to 4 otherwise.
const asCap = (v: unknown): number | null => {
  if (v === undefined || v === null || v === "") return null;
  const s = String(v);
  return /^[0-9]+$/.test(s) ? Number(s) : DEFAULT_CAP;
};

// load_policy's directory: the account's home, or HOME under the HIMMEL_POLICY_FOLLOWS_HOME test seam.
const configFileOf = (env: Env): string => join(env.HIMMEL_POLICY_FOLLOWS_HOME === "1" && env.HOME ? env.HOME : userInfo().homedir, ".himmel", "config.json");

export function readCap(envFile: string, env: Env): CapResult {
  const configFile = configFileOf(env);
  const body = { default: DEFAULT_CAP, configFile, envFile, edit: HAND_EDIT };
  // load_policy fails closed on a config.json it cannot read or parse, and the preflight keeps 4
  const failed: CapResult = { status: 200, body: { ...body, cap: DEFAULT_CAP, source: "default" } };
  let raw: string | null = null;
  try { raw = readFileSync(configFile, "utf8"); } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code !== "ENOENT" && code !== "EISDIR") return failed; // to load_policy's [ -f ] only a missing file or a directory is absent
  }
  if (raw !== null) {
    let fromConfig: number | null;
    try { fromConfig = asCap((JSON.parse(raw)?.policy ?? {})[KEY]); } catch { return failed; }
    if (fromConfig !== null) return { status: 200, body: { ...body, cap: fromConfig, source: "config.json" } };
  }
  let fromFile: number | null = null;
  try { fromFile = asCap(parseDotEnv(readFileSync(envFile, "utf8"))[KEY]); } catch { /* no .env */ }
  return { status: 200, body: { ...body, cap: fromFile ?? DEFAULT_CAP, source: fromFile !== null ? ".env" : "default" } };
}

export function writeCap(_envFile: string, _env: Env, _b: Record<string, unknown>): CapResult {
  return { status: 405, body: { error: `the fleet cap is gate policy and the UI does not write it; edit ${HAND_EDIT} by hand` } };
}

export const envFileOf = (root: string): string => join(root, ".env");
