// the config UI's read and write of the fleet cap (HIMMEL_FLEET_CAP), a behaviour key (docs/internals/config-layers.md).
// The preflight reads the launching shell first, then ~/.himmel/himmel.conf.local, ~/.himmel/himmel.conf, the station
// checkout's legacy .env, then 4; the only thing written here is that one line of himmel.conf (or himmel.conf.local when
// that file already sets the cap, since it would otherwise win), replaced in place or appended.
import { chmodSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseDotEnv } from "../himmelctl/lib/probes.js";

type Env = Record<string, string | undefined>;
export type CapResult = { status: number; body: Record<string, unknown> };

const KEY = "HIMMEL_FLEET_CAP";
const DEFAULT_CAP = 4;
const MIN_CAP = 1;
const MAX_CAP = 50;
const LINE = new RegExp(`^\\s*(?:export\\s+)?${KEY}\\s*=`);
const WHOLE = /^[0-9]{1,3}$/;

const whole = (v: unknown): number | null => {
  const s = typeof v === "number" && Number.isInteger(v) ? String(v) : typeof v === "string" ? v : "";
  return WHOLE.test(s) && Number(s) >= MIN_CAP && Number(s) <= MAX_CAP ? Number(s) : null;
};

const confFile = (env: Env): string => join(env.HOME || homedir(), ".himmel", "himmel.conf");
const localFile = (env: Env): string => confFile(env) + ".local";

// the raw non-empty value a file sets for the cap (an empty value reads as unset), else undefined
function rawValue(path: string): string | undefined {
  try { return parseDotEnv(readFileSync(path, "utf8"))[KEY] || undefined; } catch { return undefined; }
}

// the first file layer that sets the cap non-empty, in load_dotenv order
function fileLayer(envFile: string, env: Env): { source: string; raw: string } | null {
  for (const [source, file] of [["himmel.conf.local", localFile(env)], ["himmel.conf", confFile(env)], [".env", envFile]] as const) {
    const raw = rawValue(file);
    if (raw !== undefined) return { source, raw };
  }
  return null;
}

// where a write has to land to take effect: the local override when it sets the cap, else himmel.conf
const writeTarget = (env: Env): string => (rawValue(localFile(env)) !== undefined ? localFile(env) : confFile(env));

export function readCap(envFile: string, env: Env): CapResult {
  const layer = fileLayer(envFile, env);
  const fromFile = layer ? whole(layer.raw) : null;
  // The preflight takes any non-empty shell value over the files, uses it when it is all digits (range unchecked) and falls back to 4 otherwise.
  const shell = env[KEY] ?? "";
  const fromEnv = shell !== "" ? (/^[0-9]+$/.test(shell) ? Number(shell) : DEFAULT_CAP) : null;
  const cap = fromEnv ?? fromFile ?? DEFAULT_CAP;
  const source = fromEnv !== null ? "env" : layer ? layer.source : "default";
  return { status: 200, body: { cap, default: DEFAULT_CAP, min: MIN_CAP, max: MAX_CAP, source, fileValue: fromFile, file: writeTarget(env) } };
}

export function writeCap(envFile: string, env: Env, b: Record<string, unknown>): CapResult {
  const cap = whole(b.cap);
  if (cap === null) return { status: 400, body: { error: `the fleet cap must be a whole number from ${MIN_CAP} to ${MAX_CAP}` } };
  let file = writeTarget(env);
  try {
    // himmel.conf is a link into the vault after a luna install: write the file it points at, so the link stays
    if (lstatSync(file, { throwIfNoEntry: false })?.isSymbolicLink()) file = realpathSync(file);
  } catch (e) { return { status: 422, body: { error: `could not resolve ${file}: ${(e as Error).message}` } }; }
  let raw = "";
  let mode = 0o600;
  try {
    const st = lstatSync(file, { throwIfNoEntry: false });
    if (st) { raw = readFileSync(file, "utf8"); mode = st.mode & 0o777; }
  } catch (e) { return { status: 422, body: { error: `could not read ${file}: ${(e as Error).message}` } }; }
  const nl = raw.includes("\r\n") ? "\r\n" : "\n";
  const out: string[] = [];
  let placed = false;
  for (const l of raw.split(/\r?\n/)) {
    if (!LINE.test(l)) { out.push(l); continue; }
    if (!placed) { out.push(`${KEY}=${cap}`); placed = true; } // a second line for the key would be dead weight
  }
  if (!placed) { if (out.length && out[out.length - 1] === "") out.pop(); out.push(`${KEY}=${cap}`); out.push(""); }
  const tmp = `${file}.tmp-${process.pid}`;
  try {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    try { unlinkSync(tmp); } catch { /* no stale file at the temporary name */ }
    writeFileSync(tmp, out.join(nl), { mode, flag: "wx" }); // wx never follows a symlink planted at the name
    chmodSync(tmp, mode);
    renameSync(tmp, file);
  } catch (e) {
    return { status: 422, body: { error: `could not write ${file}: ${(e as Error).message}` } };
  } finally {
    try { unlinkSync(tmp); } catch { /* renamed into place, or never written */ }
  }
  return readCap(envFile, env);
}

export const envFileOf = (root: string): string => join(root, ".env");
