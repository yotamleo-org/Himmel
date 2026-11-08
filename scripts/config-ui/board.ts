// The Board page's two reads beside GET /api/roadmap, and the one run that replaces the saved drift file (refreshDrift, below): the saved status-drift summary (drift-summary.mjs) and the
// chain read (chain-state.mjs). The reads are READ ONLY: each is a chief-kit script that prints JSON and writes nothing, run with an explicit
// argument list and a small environment, and never started unless its input is found: named in the environment
// (HIMMEL_FOCUS_DRIFT, TRACKER_HANDOVERS_DIR, HIMMEL_CHAIN_REGISTRY) or, on a real launch, the newest file of that name under
// <HANDOVER_DIR>/<slug>/himmel/. A test therefore reaches only the paths it sets: with none of these nothing is spawned and
// the page shows both as absent, with the reason, never as a count.
import { execFile, execFileSync } from "node:child_process";
import { readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { runChild } from "./lock";
import { readRoadmap } from "./roadmap";
import { decisionsOf } from "./shift";
import { jiraMirrorDir } from "./tracker-sources";

type Env = Record<string, string | undefined>;
export type Absent = { state: "absent"; reason: string };
// chains: every version, for the whole Board. versionChains: the picked version (else the running one), for the Chains tab alone, with its burn-down.
// prs: the open PRs and their CI per ticket, from the worker records the status sweep keeps (a local file read, no GitHub call).
export type BoardExtras = { drift: Record<string, unknown> | Absent; chains: Record<string, unknown> | Absent; versionChains: Record<string, unknown> | Absent; prs: PrRead | Absent; owed: Owed };
// seen: when each ticket's worker record last moved (its last_event_ts), for the age on the card's worker line.
export type PrRead = { state: "ok"; repo?: string; prs: Record<string, { pr: number; head: string; ci: string }[]>; seen: Record<string, string>; unread: string[] };

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

// The open PRs per ticket, from <state dir>/workers/<KEY>.json: the same records the roadmap tracker prefers for CI (a red latch or red reads red, pending reads
// running). The state dir is the status scripts' own: TICKET_STATUS_STATE_DIR, else $HOME/.himmel/state. No GitHub call, no write; an unreadable directory is
// absent, so a card is never flagged "no open PR" on a guess.
// ponytail: a PR no worker record names (a human's) is not listed, upgrade path: read the sweep's open-PR snapshot once focus-refresh keeps it.
function repoSlug(env: Env): string | undefined {
  const named = env.GH_REPO || env.GITHUB_REPOSITORY;
  if (named) return named;
  try {
    const url = execFileSync("git", ["config", "--get", "remote.origin.url"], { cwd: KIT, timeout: 2000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return url.match(/github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?$/)?.[1];
  } catch { return undefined; }
}
export function readPrs(env: Env): PrRead | Absent {
  const dir = join(env.TICKET_STATUS_STATE_DIR || join(env.HOME || "/tmp", ".himmel/state"), "workers");
  let names: string[];
  try { names = readdirSync(dir); } catch { return absent("no worker records: the directory is not there or not readable"); }
  const prs: PrRead["prs"] = {}, seen: PrRead["seen"] = {}, unread: string[] = [];
  for (const n of names) {
    const m = n.match(/^([A-Z][A-Z0-9]*-\d+)\.json$/);
    if (!m) continue;
    let rec: { last_event_ts?: string; prs?: Record<string, { head?: string; ci?: string; red_latch?: boolean; open?: boolean }> };
    try { rec = JSON.parse(readFileSync(join(dir, n), "utf8")); } catch { unread.push(m[1]); continue; } // a record that cannot be read is named, so its card never claims "no open PR"
    if (!rec || typeof rec !== "object") { unread.push(m[1]); continue; } // JSON null or a bare value holds no data either
    if (typeof rec?.last_event_ts === "string" && Number.isFinite(Date.parse(rec.last_event_ts))) seen[m[1]] = rec.last_event_ts;
    const open = Object.entries(rec?.prs && typeof rec.prs === "object" ? rec.prs : {}).filter(([k, p]) => p && p.open && /^\d+$/.test(k))
      .map(([k, p]) => ({ pr: Number(k), head: String(p.head || ""), ci: p.red_latch ? "red" : p.ci === "pending" ? "running" : p.ci === "red" || p.ci === "green" ? p.ci : "none" }))
      .sort((a, b) => a.pr - b.pr);
    if (open.length) prs[m[1]] = open;
  }
  return { state: "ok", repo: repoSlug(env), prs, seen, unread };
}

// The versions the Board lists and the one the cards call running. Without a running version the chain read covers every version, and a blocker outside the version cannot read as blocked.
// ponytail: this reads the mirror a second time beside GET /api/roadmap, upgrade path: hand the page's own read to this one if it ever shows in the Board's load time.
function boardVersions(mirror: string, env: Env, read: typeof readRoadmap): { running: string | undefined; names: string[] } | Absent {
  try {
    const r = read({ mirrorDir: mirror, projects: [{ key: env.JIRA_PROJECT_KEY || "HIMMEL", dir: mirror }], workers: { state: "absent" } });
    return { running: r.versions[r.cur]?.n, names: r.versions.map((v) => v.n) };
  } catch (e) { return absent(`the running version could not be read: ${(e as Error).message}`); } // a failed read, never "no running version"
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

// Tidy up's Refresh: status-drift.sh, the report-only check (it never writes Jira), and the saved file replaced through a temp file and a
// rename, as focus-refresh.sh publishes it. A run that does not end on a clean sdrift line leaves the saved file alone and says why.
// The check's own 90 s default is too short here: a real run without a snapshot took 121 s on the station. It gets DRIFT_BUDGET_S instead;
// the limit below catches only a hung child, and the server's idle guard covers it.
// ponytail: runs without the sweep's snapshot, at about 4 s per key, so past about 50 open tickets it hits the budget and reads unknown, upgrade path = keep focus-refresh's snapshot for --snapshot.
export const DRIFT_BUDGET_S = 200;
export const DRIFT_REFRESH_MS = 220_000;
export type DriftRefresh = { state: "ok"; sdrift: string } | { state: "failed"; reason: string };
export const driftCheck = (env: Env) => env.CONFIG_UI_DRIFT_CHECK || join(KIT, "status-drift.sh");
export async function refreshDrift(env: Env, cwd: string, timeoutMs = DRIFT_REFRESH_MS): Promise<DriftRefresh> {
  const failed = (reason: string): DriftRefresh => ({ state: "failed", reason });
  const file = driftFile(env);
  if (!file) return failed("nowhere to save the run: no saved drift file under the handover root, and HIMMEL_FOCUS_DRIFT is not set");
  let r;
  try { r = await runChild(["bash", driftCheck(env)], { cwd, env: { ...env, TICKET_STATUS_DRIFT_BUDGET: String(DRIFT_BUDGET_S) }, timeoutMs }); } catch (e) { return failed(`the check could not start: ${(e as Error).message}`); }
  if (r.timedOut) return failed(`the check ran past its ${Math.round(timeoutMs / 1000)} s limit`);
  if (r.rc !== 0) return failed(`the check failed with rc ${r.rc}: ${r.stderr.trim().split("\n").pop()?.slice(0, 200) ?? ""}`);
  const lines = r.stdout.split("\n").filter((l) => l.trim()), last = lines[lines.length - 1] ?? "";
  if (last === "sdrift=unknown") {
    const health = lines.filter((l) => l.startsWith("HEALTH ")).pop()?.split(" | ")[0];
    return failed(`the check could not read the open PRs or the Jira search in full${health ? ` (${health.slice(0, 200)})` : ""}`);
  }
  if (!/^sdrift=\d+:\S+$/.test(last)) return failed("the check printed no sdrift line");
  const stage = `${file}.${process.pid}.tmp`; // beside the target: a rename stays on one filesystem
  try {
    writeFileSync(stage, r.stdout);
    renameSync(stage, file);
  } catch (e) {
    rmSync(stage, { force: true });
    return failed(`the run could not be saved: ${(e as Error).message}`);
  }
  return { state: "ok", sdrift: last.slice("sdrift=".length) };
}

// What is owed to the operator beside the labels and chain holds: `release spec-check` over the open core tickets (a NO-SPEC or SPEC-STALE line is an
// owed signature) and the open decisions in the newest chief doc. Both are READ ONLY; a source that cannot be read is absent with its reason, never an empty list.
// ponytail: the newest chief doc by mtime stands for "the live chief", upgrade path: the live chiefs' docs by queue lock as Shift reads them.
export type Owed = { specs: { state: "ok"; checks: string[] } | Absent; decisions: { state: "ok"; items: string[] } | Absent };
const specCheckCli = (env: Env) => env.CONFIG_UI_SPEC_CHECK || resolve(KIT, "../../jira/dist/index.js");
const SPEC_KEEP = ["PATH", "HOME", "JIRA_PROJECT_KEY", "USER_SLUG", "HANDOVER_DIR", "HIMMEL_RELEASE_STATE_DIR", "HIMMEL_JIRA_MIRROR"];
function readSpecs(env: Env, mirror: string, read: typeof readRoadmap): Promise<Owed["specs"]> {
  const cli = specCheckCli(env);
  let keys: string[];
  try {
    const r = read({ mirrorDir: mirror, projects: [{ key: env.JIRA_PROJECT_KEY || "HIMMEL", dir: mirror }], workers: { state: "absent" } });
    keys = r.tickets.filter((t) => t.labels.includes("core") && t.b !== "done" && t.b !== "wont").map((t) => t.id ?? `${env.JIRA_PROJECT_KEY || "HIMMEL"}-${t.k}`);
  } catch (e) { return Promise.resolve(absent(`the core tickets could not be read: ${(e as Error).message}`)); }
  if (!keys.length) return Promise.resolve({ state: "ok", checks: [] });
  try { statSync(cli); } catch { return Promise.resolve(absent(`spec-check is not built: ${cli} is not there`)); }
  const cenv = Object.fromEntries(SPEC_KEEP.map((k) => [k, env[k] ?? (k === "PATH" ? process.env.PATH : undefined)]).filter(([, v]) => v !== undefined)) as NodeJS.ProcessEnv;
  return new Promise((done) => {
    // spec-check exits 1 while any key is unsigned, so the exit code is not the failure: no recognised line is
    execFile("node", [cli, "release", "spec-check", ...keys, "--mirror", mirror], { env: cenv, timeout: TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      const lines = String(stdout).split("\n").map((l) => l.trim()).filter((l) => /^(SPEC ok|SPEC-STALE|NO-SPEC) /.test(l));
      if (!lines.length) return done(absent(`spec-check failed: ${String(stderr || (err as Error | null)?.message || "it printed no result").trim().split("\n").pop()?.slice(0, 200)}`));
      done({ state: "ok", checks: lines.filter((l) => !l.startsWith("SPEC ok ")) });
    });
  });
}
function newestChiefDoc(env: Env): string | undefined {
  if (env.HIMMEL_CHIEF_DOC) return env.HIMMEL_CHIEF_DOC;
  if (!env.HANDOVER_DIR) return undefined;
  let best: { p: string; t: number } | undefined;
  try {
    for (const e of readdirSync(env.HANDOVER_DIR, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const dir = join(env.HANDOVER_DIR, e.name, "himmel");
      try {
        for (const f of readdirSync(dir)) {
          if (!/-chief\.md$/.test(f)) continue;
          const t = statSync(join(dir, f)).mtimeMs;
          if (!best || t > best.t) best = { p: join(dir, f), t };
        }
      } catch { /* no himmel dir under this slug */ }
    }
  } catch { /* an unreadable handover root reads as no doc */ }
  return best?.p;
}
function readDecisions(env: Env): Owed["decisions"] {
  const doc = newestChiefDoc(env);
  if (!doc) return absent("no chief doc: none found under the handover root, and HIMMEL_CHIEF_DOC is not set");
  try { return { state: "ok", items: decisionsOf(readFileSync(doc, "utf8")) }; } catch (e) { return absent(`the chief doc could not be read: ${(e as Error).message}`); }
}
export async function readOwed(env: Env, read: typeof readRoadmap = readRoadmap): Promise<Owed> {
  return { specs: await readSpecs(env, jiraMirrorDir(env), read), decisions: readDecisions(env) };
}

// `asked`: the version tile picked on the page. A known one is the version the tab reads; an unknown one reads as the running version and the answer says so (fellBack).
export async function readBoardExtras(env: Env, read: typeof readRoadmap = readRoadmap, asked?: string): Promise<BoardExtras> {
  const mirror = jiraMirrorDir(env);
  const file = driftFile(env);
  const registry = chainRegistry(env);
  const drift = file ? runReader(join(KIT, "drift-summary.mjs"), ["--json", "--drift", file, "--mirror-dir", mirror], env, "the drift summary")
    : Promise.resolve(absent("no saved drift run: none found under the handover root, and HIMMEL_FOCUS_DRIFT is not set"));
  // the chain read's state dir (hold and merge rows) is the script's own: TICKET_STATUS_STATE_DIR, else $HOME/.himmel/state
  if (!registry) {
    const none = absent("no chain registry: none found under the handover root, and HIMMEL_CHAIN_REGISTRY is not set");
    return { drift: await drift, chains: none, versionChains: none, prs: readPrs(env), owed: await readOwed(env, read) };
  }
  const chainRead = (extra: string[]) => runReader(join(KIT, "chain-state.mjs"), ["--json", "--registry", registry, "--mirror", mirror, ...extra], env, "the chain read");
  const withBurn = (r: Record<string, unknown> | Absent) => ("tickets" in r ? { ...r, burn: burnDown(r as Parameters<typeof burnDown>[0]) } : r);
  const whole = chainRead([]);
  const vs = boardVersions(mirror, env, read);
  // With two projects on the Board a tile reads "v1.1.4 (HIMMEL)"; the chain read is the one project's, so its own suffix names the same version.
  const bare = asked?.endsWith(` (${env.JIRA_PROJECT_KEY || "HIMMEL"})`) ? asked.slice(0, asked.lastIndexOf(" (")) : asked;
  const pick = "state" in vs ? undefined : bare && vs.names.includes(bare) ? bare : vs.running;
  const fell = !("state" in vs) && asked && pick !== bare ? { fellBack: { asked, to: vs.running ?? null } } : {};
  const forTab = "state" in vs ? Promise.resolve(vs) : (pick ? chainRead(["--version", pick]) : whole).then(withBurn).then((r) => ("tickets" in r ? { ...r, ...fell } : r));
  const [d, chains, versionChains, owed] = await Promise.all([drift, whole, forTab, readOwed(env, read)]);
  return { drift: d, chains, versionChains, prs: readPrs(env), owed };
}
