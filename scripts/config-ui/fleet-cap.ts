// the config UI's read and write of the fleet cap (HIMMEL_FLEET_CAP). The preflight reads the launching shell first, then the
// station checkout's .env, then 4; the only thing written here is that one line of that .env, replaced in place or appended.
import { chmodSync, lstatSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
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

function fileValue(path: string): number | null {
  try { return whole(parseDotEnv(readFileSync(path, "utf8"))[KEY]); } catch { return null; }
}

export function readCap(envFile: string, env: Env): CapResult {
  const fromFile = fileValue(envFile);
  // The preflight takes any non-empty shell value over .env, uses it when it is all digits (range unchecked) and falls back to 4 otherwise.
  const shell = env[KEY] ?? "";
  const fromEnv = shell !== "" ? (/^[0-9]+$/.test(shell) ? Number(shell) : DEFAULT_CAP) : null;
  const cap = fromEnv ?? fromFile ?? DEFAULT_CAP;
  return { status: 200, body: { cap, default: DEFAULT_CAP, min: MIN_CAP, max: MAX_CAP, source: fromEnv !== null ? "env" : fromFile !== null ? ".env" : "default", fileValue: fromFile, envFile } };
}

export function writeCap(envFile: string, env: Env, b: Record<string, unknown>): CapResult {
  const cap = whole(b.cap);
  if (cap === null) return { status: 400, body: { error: `the fleet cap must be a whole number from ${MIN_CAP} to ${MAX_CAP}` } };
  if (lstatSync(envFile, { throwIfNoEntry: false })?.isSymbolicLink()) return { status: 400, body: { error: ".env is a symlink; refusing to replace it" } };
  let raw = "";
  let mode = 0o600;
  try {
    const st = lstatSync(envFile, { throwIfNoEntry: false });
    if (st) { raw = readFileSync(envFile, "utf8"); mode = st.mode & 0o777; }
  } catch (e) { return { status: 422, body: { error: `could not read ${envFile}: ${(e as Error).message}` } }; }
  const nl = raw.includes("\r\n") ? "\r\n" : "\n";
  const out: string[] = [];
  let placed = false;
  for (const l of raw.split(/\r?\n/)) {
    if (!LINE.test(l)) { out.push(l); continue; }
    if (!placed) { out.push(`${KEY}=${cap}`); placed = true; } // a second line for the key would be dead weight
  }
  if (!placed) { if (out.length && out[out.length - 1] === "") out.pop(); out.push(`${KEY}=${cap}`); out.push(""); }
  const tmp = `${envFile}.tmp-${process.pid}`;
  try {
    try { unlinkSync(tmp); } catch { /* no stale file at the temporary name */ }
    writeFileSync(tmp, out.join(nl), { mode, flag: "wx" }); // wx never follows a symlink planted at the name
    chmodSync(tmp, mode);
    renameSync(tmp, envFile);
  } catch (e) {
    return { status: 422, body: { error: `could not write ${envFile}: ${(e as Error).message}` } };
  } finally {
    try { unlinkSync(tmp); } catch { /* renamed into place, or never written */ }
  }
  return readCap(envFile, env);
}

export const envFileOf = (root: string): string => join(root, ".env");
