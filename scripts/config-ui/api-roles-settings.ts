// the config UI's read and write of the API account role map (decision 526). This module holds no role list, path or
// validator: it only calls the two owner CLIs, scripts/lib/api-roles.mjs (check, write) and scripts/lib/api-credit-state.mjs
// (accounts). The page POSTs the bare role map; it is wrapped as {"version":1,"roles":...} here so the page never builds the document.
import { spawn } from "node:child_process";
import { resolve } from "node:path";
// @ts-ignore plain ES module, no types
import { ACCOUNTS } from "../lib/api-credit-state.mjs";

type Env = Record<string, string | undefined>;
export type RolesResult = { status: number; body: Record<string, any> };
export type RolesOpts = { rolesCli?: string; creditCli?: string; timeoutMs?: number };

export const ACCOUNTS_TIMEOUT_MS = 5000;
const WRITE_TIMEOUT_MS = 10_000;
const ROLES_CLI = resolve(import.meta.dir, "../lib/api-roles.mjs");
const CREDIT_CLI = resolve(import.meta.dir, "../lib/api-credit-state.mjs");
const CADENCE_ALERT = resolve(import.meta.dir, "../luna/cadence-alert.sh");

type Ran = { code: number | null; stdout: string; timedOut: boolean };

// One bounded child run: stdout is the answer, a kill at the bound is reported as timedOut.
function run(cli: string, args: string[], env: Env, timeoutMs: number, input = ""): Promise<Ran> {
  const clean: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) clean[k] = v;
  return new Promise((done) => {
    let out = "", timedOut = false, settled = false;
    const child = spawn("node", [cli, ...args], { env: clean, stdio: ["pipe", "pipe", "ignore"] });
    const finish = (code: number | null) => { if (settled) return; settled = true; clearTimeout(timer); done({ code, stdout: out, timedOut }); };
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, timeoutMs);
    child.stdout.on("data", (d) => { out += d; });
    child.stdin.on("error", () => {}); // a child that exits before reading its stdin
    child.on("error", () => finish(null));
    child.on("close", (code) => finish(code));
    child.stdin.end(input);
  });
}

const parse = (text: string): any => { try { return JSON.parse(text); } catch { return undefined; } };
const unknownRows = (reason: string) => ACCOUNTS.map((account: string) => ({ account, configured: null, cap_usd: null, tag: "unknown", reason }));

// GET: the map state with ROLES (check) and one row per account (accounts). A slow or failed accounts read gives unknown rows,
// never an error: the map and the editor still show.
export async function readRoles(env: Env, opts: RolesOpts = {}): Promise<RolesResult> {
  const bound = opts.timeoutMs ?? ACCOUNTS_TIMEOUT_MS;
  const [check, accounts] = await Promise.all([
    run(opts.rolesCli ?? ROLES_CLI, ["check"], env, bound),
    run(opts.creditCli ?? CREDIT_CLI, ["accounts"], env, bound),
  ]);
  const map = check.code === 0 ? parse(check.stdout) : undefined;
  if (!map || typeof map !== "object" || !map.roleMap || !Array.isArray(map.ROLES)) return { status: 500, body: { error: "the role map could not be read" } };
  const body: Record<string, any> = { ...map, letters: ACCOUNTS };
  const rows = accounts.timedOut ? unknownRows("timeout") : accounts.code === 0 ? parse(accounts.stdout) : undefined;
  if (Array.isArray(rows)) body.rows = rows;
  else if (rows && typeof rows === "object" && rows.accounts === "unreadable") { body.rows = null; body.accountsReason = String(rows.reason ?? ""); }
  else body.rows = unknownRows("accounts-failed");
  return { status: 200, body };
}

// The graph walk's letters (walk graphify), or none when it refuses or fails.
async function walkLetters(cli: string, env: Env, timeoutMs: number): Promise<string[]> {
  const r = await run(cli, ["walk", "graphify"], env, timeoutMs);
  return r.code === 0 ? r.stdout.trim().split(",").filter((l) => (ACCOUNTS as string[]).includes(l)) : [];
}

// A save that takes letter L out of the graph walk clears the graph-key-L alert's dedupe sentinel, so the next real
// rejection on L alerts again. It never clears the key-rejected tag: the key is still wrong.
function clearGraphKey(letter: string, env: Env, timeoutMs: number): Promise<void> {
  const clean: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) clean[k] = v;
  return new Promise((done) => {
    const child = spawn("bash", [CADENCE_ALERT, "clear", `graph-key-${letter}`], { env: clean, stdio: "ignore" });
    const timer = setTimeout(() => { child.kill("SIGKILL"); done(); }, timeoutMs);
    const finish = () => { clearTimeout(timer); done(); };
    child.on("error", finish);
    child.on("close", finish);
  });
}

// POST: the CLI validates and writes (atomic, mode 600); its exit 3 is the page's 422 carrying its errors.
export async function saveRoles(draft: Record<string, unknown>, env: Env, opts: RolesOpts = {}): Promise<RolesResult> {
  const rolesCli = opts.rolesCli ?? ROLES_CLI;
  const bound = opts.timeoutMs ?? WRITE_TIMEOUT_MS;
  const before = await walkLetters(rolesCli, env, bound);
  const r = await run(rolesCli, ["write"], env, bound, JSON.stringify({ version: 1, roles: draft }));
  const out = r.code === 0 || r.code === 3 ? parse(r.stdout) : undefined;
  if (r.code === 0 && out && out.ok === true) {
    const after = await walkLetters(rolesCli, env, bound);
    for (const letter of before.filter((l) => !after.includes(l))) await clearGraphKey(letter, env, bound);
    return { status: 200, body: { ok: true, errors: [] } };
  }
  if (r.code === 3 && out && Array.isArray(out.errors)) return { status: 422, body: { ok: false, errors: out.errors } };
  return { status: 500, body: { error: "the role map could not be saved" } };
}
