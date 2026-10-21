// `himmelctl ui` — config UI server.
// Loopback only (hostname hard-coded), per-launch token on /api/*, Host check,
// feed shelled from `himmelctl report --json` (execFile, no shell) and redacted.
// P4 adds the two-step writes (spec A12-A14b): POST /api/preview runs an
// action's dry-run and binds a single-use preview id; POST /api/run runs only
// that bound argv under the machine-wide write lock, re-probes the row and
// appends one audit line.
import { execFile, execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve, sep } from "node:path";
import { scrubProviderKeys } from "../fleet-control/server";
// redact.js is the shared CommonJS redactor (P2); imported, not copied.
import { redactDeep, envValues } from "../himmelctl/lib/redact.js";
import { parseDotEnv } from "../himmelctl/lib/probes.js";
import { ActionError, buildTable, loadRegistries, resolveAction, type Resolved } from "./actions";
import { acquireLock, runChild, type Lock } from "./lock";
import { readBank, readLegs, readMode, readMonitoring, readToolHealth } from "./health-sources";
import { readQuota } from "./quota-sources";
import { appendAudit } from "./audit";
import { busRootOf, journalStream, resolveJournal } from "./agui/sse";
import { readFleet } from "./agui/fleet";
import { findDoc, readBoard, readBoardFile, scrub, validName } from "./agui/board";
import { readOrCreateToken } from "./token-file";
import { legSync, readRoadmap } from "./roadmap";
import { ISSUE_LIMIT, jiraMirrorDir, readGithubIssues, trackerSources } from "./tracker-sources";
import { readVm, writeVm } from "./vm-config";
import { applyWrite, parseWrite, type WriteResult } from "./jira-write";
import { secretWrite, setupState } from "./setup";

const LOOPBACK = "127.0.0.1";
const DEFAULT_IDLE_MS = 30 * 60 * 1000;
// Bun cuts any request idle past 10 s. The feed runs in the
// background (FEED_TIMEOUT_MS, the station took 124 s) and a request waits at
// most FEED_WAIT_MS (under 10 s) before answering 202 for the page to poll.
// The routes that really hold a request: /api/run = re-probe + action + re-probe
// (60 + 120 + 60 = 240 s with today's table); /api/preview = one action.
// startServer refuses to start unless IDLE_TIMEOUT_S covers the worst route
// (computed from the live table) plus IDLE_MARGIN_S; Bun's maximum is 255 s.
const FEED_TIMEOUT_MS = 300_000;
const FEED_WAIT_MS = 8_000;
const FEED_CACHE_MS = 30_000;
// with backgroundFeed the report starts at boot and is refreshed every FEED_REFRESH_MS, but only
// while the console is in use (an authenticated request within the last FEED_REFRESH_MS), so a closed UI idles out.
const FEED_REFRESH_MS = 10 * 60 * 1000;
// The progress line probe-progress.cjs writes; anything else on the report's stderr is ignored.
const PROBE_LINE = "himmel-probe ";
const PROBE_SOURCE = /^[\w ,.:@-]{1,80}$/;
const MAX_STDERR_LINE = 4096;
export const IDLE_TIMEOUT_S = 255;
const IDLE_MARGIN_S = 10;
const PREVIEW_TTL_MS = 5 * 60 * 1000;
export const REPROBE_BUDGET_MS = 60_000;
const MAX_BODY = 16 * 1024;
// GET /api/agui/<run>: poll the journal for appends every 500 ms;
// end 2 min after a finished run's file stops growing, and after 4 h regardless.
const AGUI_POLL_MS = 500;
const AGUI_IDLE_MS = 2 * 60 * 1000;
const AGUI_MAX_MS = 4 * 60 * 60 * 1000;
const CHECKOUT = resolve(import.meta.dir, "../..");
const SECURITY_HEADERS: Record<string, string> = { "content-security-policy": "default-src 'self'", "x-frame-options": "DENY" };
const STATIC: Record<string, [string, string]> = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "application/javascript; charset=utf-8"],
  "/render.js": ["render.js", "application/javascript; charset=utf-8"],
  "/health.js": ["health.js", "application/javascript; charset=utf-8"],
  "/tool-health.js": ["tool-health.js", "application/javascript; charset=utf-8"],
  "/roadmap.js": ["roadmap.js", "application/javascript; charset=utf-8"],
  "/workflow.js": ["workflow.js", "application/javascript; charset=utf-8"],
  "/setup.js": ["setup.js", "application/javascript; charset=utf-8"],
  "/app.css": ["app.css", "text/css; charset=utf-8"],
  // the rail and theme the AG-UI pages share (agui-web bundles its own copy at build time).
  "/nav.js": ["nav.js", "application/javascript; charset=utf-8"],
  "/theme.css": ["theme.css", "text/css; charset=utf-8"],
  "/tokens.css": ["tokens.css", "text/css; charset=utf-8"],
};
// GET /agui/: the built AG-UI page, agui-web/dist (bun build, untracked).
// Not token-gated: the page is static and the token rides the URL fragment; /api/agui/<run> stays gated.
const AGUI_WEB = join(import.meta.dir, "agui-web");
const AGUI_DIST = join(AGUI_WEB, "dist");
const AGUI_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".map": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2",
};
const AGUI_MISSING = `<!doctype html><meta charset="utf-8"><title>AG-UI page not built</title>
<h1>The AG-UI page is not built</h1>
<p>Build it once from your himmel checkout, then reload this page:</p>
<pre>cd scripts/config-ui/agui-web
bun install
bun run build</pre>
`;

// dist is untracked and nothing rebuilds it, so a page built before the source last changed is served
// as is, but says so: on the launcher's stderr and in a banner the server puts into index.html (the stale bundle
// cannot know it is stale). Detect and say, never rebuild: a rebuild on start would run bun under the operator's server.
const BUILD_STEP = "cd scripts/config-ui/agui-web && bun run build";
function aguiSourceGone(dist: string, web: string): boolean {
  let listed: unknown;
  try { listed = JSON.parse(readFileSync(join(dist, ".agui-sources"), "utf8")); } catch { return false; } // an older build, or no evidence
  return Array.isArray(listed) && listed.some((f) => typeof f === "string" && !existsSync(join(web, "src", f)));
}
function aguiStale(dist: string, web: string): { built: Date; changed: Date } | null {
  let built: Date;
  try { built = statSync(join(dist, "index.html")).mtime; } catch { return null; } // no dist is AGUI_MISSING's case
  // the manifest is read before src is listed, so a deleted src directory still reads as stale.
  const gone = aguiSourceGone(dist, web);
  try {
    const src = readdirSync(join(web, "src"), { recursive: true }).map((f) => join(web, "src", String(f)));
    // the page also bundles the console's rail and theme from public/.
    const shared = ["nav.js", "theme.css", "tokens.css"].map((f) => join(web, "..", "public", f)).filter((f) => existsSync(f));
    const stats = [join(web, "index.html"), ...src, ...shared].map((f) => statSync(f));
    const newest = (sts: typeof stats) => sts.map((st) => st.mtime).reduce((a, b) => (b > a ? b : a));
    // a deleted or renamed source leaves no newer mtime, so the build lists its sources in
    // dist/.agui-sources and a listed file that is gone is stale; then the newest directory mtime dates the delete.
    if (gone) return { built, changed: newest(stats) > built ? newest(stats) : new Date() };
    const changed = newest(stats.filter((st) => st.isFile())); // a directory's mtime moves on any add, not an edit
    return changed > built ? { built, changed } : null;
  } catch { return gone ? { built, changed: new Date() } : null; } // unreadable source is no evidence unless a built one is gone
}
const stamp = (d: Date) => d.toISOString().replace("T", " ").slice(0, 16) + " UTC";
export function aguiStaleWarning(dist = AGUI_DIST, web = AGUI_WEB): string | null {
  const s = aguiStale(dist, web);
  return s && `himmelctl: ui: the AG-UI page is an old build (dist ${stamp(s.built)}, source changed ${stamp(s.changed)}); rebuild: ${BUILD_STEP}`;
}
function staleBanner(html: string, dist: string, web: string): string {
  const s = aguiStale(dist, web);
  if (!s) return html;
  const banner = `<p id="agui-stale" role="alert">This page is an old build: it was built ${stamp(s.built)}, and its source changed ${stamp(s.changed)}. `
    + `Rebuild it with <code>${BUILD_STEP}</code>, then reload.</p>`;
  if (/<body[^>]*>/i.test(html)) return html.replace(/<body[^>]*>/i, (b) => b + banner);
  return html.replace(/^(\s*<!doctype[^>]*>)?/i, (d) => d + banner); // the doctype stays first, or the page drops to quirks mode
}

// Only a regular file whose real path stays inside dist; anything else (traversal, a symlink out, a directory) is a 404.
function aguiFile(dist: string, path: string, web = AGUI_WEB): Response {
  let root: string;
  try { root = realpathSync(dist); statSync(join(root, "index.html")); }
  catch { return new Response(AGUI_MISSING, { status: 404, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }); }
  let rel: string;
  try { rel = decodeURIComponent(path.slice("/agui/".length)) || "index.html"; } catch { return new Response("not found", { status: 404 }); }
  let real: string;
  try { real = realpathSync(join(root, rel)); } catch { return new Response("not found", { status: 404 }); }
  const type = AGUI_TYPES[extname(real)];
  if (!real.startsWith(root + sep) || !type) return new Response("not found", { status: 404 });
  // A rebuild can remove the file between realpath and read: that is a 404 too, never a thrown 500.
  try {
    if (statSync(real).isFile()) {
      const body = real === join(root, "index.html") ? staleBanner(readFileSync(real, "utf8"), root, web) : readFileSync(real);
      return new Response(body, { headers: { "content-type": type, "cache-control": "no-store" } });
    }
  } catch { /* gone */ }
  return new Response("not found", { status: 404 });
}

// GET /dev-graph/<file>: the development graph's data, script and style, read-only from docs/guide/dev-graph, the
// files the docs page loads. Not token-gated (static, like /agui/). Only a regular .json/.js/.css file whose real
// path stays inside the directory; anything else (traversal, a symlink out, a directory) is a 404.
const DEV_GRAPH_DIR = join(CHECKOUT, "docs/guide/dev-graph");
const DEV_GRAPH_TYPES: Record<string, string> = {
  ".json": "application/json", ".js": "application/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
};
function devGraphFile(dir: string, path: string): Response {
  const gone = () => new Response("not found", { status: 404 });
  let root: string, rel: string, real: string;
  try {
    root = realpathSync(dir);
    rel = decodeURIComponent(path.slice("/dev-graph/".length));
    real = realpathSync(join(root, rel));
  } catch { return gone(); }
  const type = DEV_GRAPH_TYPES[extname(real)];
  if (!rel || !real.startsWith(root + sep) || !type) return gone();
  try {
    if (statSync(real).isFile()) return new Response(readFileSync(real), { headers: { "content-type": type, "cache-control": "no-store" } });
  } catch { /* gone between realpath and read */ }
  return gone();
}

type Env = Record<string, string | undefined>;
// root, now, actionTimeoutMs and reprobeBudgetMs are test seams on the function
// only; the CLI entry below never sets them.
export type ServerOpts = {
  port?: number; token?: string; hostname?: string; env?: Env; onIdle?: () => void;
  root?: string; projectRoot?: string; now?: () => number; actionTimeoutMs?: number; reprobeBudgetMs?: number; feedWaitMs?: number; feedTimeoutMs?: number;
  backgroundFeed?: boolean; feedRefreshMs?: number; noIdle?: boolean;
  legsScript?: string; legsTimeoutMs?: number; fleetScript?: string; boardScript?: string; aguiPollMs?: number; aguiIdleMs?: number; aguiMaxMs?: number; aguiDist?: string; aguiWeb?: string;
};
type Preview = Resolved & { expires: number };
type Probe = Record<string, { installed: string; health: string }>;

export function newToken(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
}

function sameToken(a: string | null, b: string): boolean {
  if (a === null || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Operator override CONFIG_UI_HIMMELCTL: replaces the himmelctl
// entry the server shells for the feed, the re-probe and every himmelctl action.
// Deliberately read from the production env, not gated: ci.yml and the
// subprocess tests (ui-verb, idle) launch the real server and can only pass env.
function himmelctlBin(env: Env): string {
  return env.CONFIG_UI_HIMMELCTL ?? resolve(import.meta.dir, "../himmelctl/bin.js");
}

// the Jira CLI the Kanban writes shell to, by absolute path. CONFIG_UI_JIRA_CLI replaces it (the tests' stub);
// a worktree has no untracked dist/, so a checkout without one falls back to HIMMEL_REPO, then to the primary of a
// checkout under .claude/worktrees/.
export function jiraBin(env: Env, checkout: string = CHECKOUT): string {
  if (env.CONFIG_UI_JIRA_CLI) return env.CONFIG_UI_JIRA_CLI;
  const rel = "scripts/jira/dist/index.js";
  const own = join(checkout, rel);
  const i = checkout.indexOf(`${sep}.claude${sep}worktrees${sep}`);
  const fallbacks = [env.HIMMEL_REPO ? join(env.HIMMEL_REPO, rel) : "", i < 0 ? "" : join(checkout.slice(0, i), rel)];
  return [own, ...fallbacks].find((p) => p && existsSync(p)) ?? own;
}

// The station anchor the feed judges (config-feed.js repoRoot): the primary checkout behind a worktree
// (git-common-dir), else the checkout itself.
export function stationRoot(checkout: string): string {
  try {
    const common = execFileSync("git", ["-C", checkout, "rev-parse", "--path-format=absolute", "--git-common-dir"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }).trim();
    return common && basename(common) === ".git" ? dirname(common) : checkout;
  } catch { return checkout; }
}

export type Progress = { i: number; n: number; source: string };
// one `himmel-probe {"i","n","source"}` line, validated; null for anything else.
export function parseProbeLine(line: string): Progress | null {
  if (!line.startsWith(PROBE_LINE)) return null;
  let o: unknown;
  try { o = JSON.parse(line.slice(PROBE_LINE.length)); } catch { return null; }
  if (!o || typeof o !== "object") return null;
  const { i, n, source } = o as Record<string, unknown>;
  if (!Number.isInteger(i) || !Number.isInteger(n) || (i as number) < 1 || (i as number) > (n as number) || (n as number) > 64) return null;
  if (typeof source !== "string" || !PROBE_SOURCE.test(source)) return null;
  return { i: i as number, n: n as number, source };
}

// the report runs under probe-progress.cjs, whose stderr steps reach onProgress.
function runFeed(env: Env, timeoutMs: number, onProgress: (p: Progress) => void): Promise<string> {
  return new Promise((ok, fail) => {
    const argv = ["--require", join(import.meta.dir, "probe-progress.cjs"), himmelctlBin(env), "report", "--json"];
    const child = execFile("node", argv, { env: env as NodeJS.ProcessEnv, timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => {
      if (err) return fail(err);
      try { ok(JSON.stringify(redactDeep(JSON.parse(stdout)))); } catch (e) { fail(e); }
    });
    let buf = "";
    child.stderr?.on("data", (d: Buffer | string) => {
      buf += String(d);
      const lines = buf.split("\n");
      buf = lines.pop()!.slice(-MAX_STDERR_LINE); // a runaway line without a newline cannot grow the buffer
      for (const l of lines) { const p = parseProbeLine(l.replace(/\r$/, "")); if (p) onProgress(p); }
    });
  });
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function startServer(opts: ServerOpts = {}): { server: import("bun").Server; port: number; token: string; stop: () => void } {
  if (opts.hostname !== undefined && opts.hostname !== LOOPBACK) throw new Error(`config-ui binds ${LOOPBACK} only (got ${opts.hostname})`);
  const env = opts.env ?? process.env;
  scrubProviderKeys(env);
  const token = opts.token ?? newToken();
  const idleMs = Number(env.CONFIG_UI_IDLE_MS) > 0 ? Number(env.CONFIG_UI_IDLE_MS) : DEFAULT_IDLE_MS;
  const now = opts.now ?? Date.now;
  const root = opts.root ?? CHECKOUT;
  // the project whose .env holds the project-scoped secrets; the directory the server was started in by default.
  const projectRoot = opts.projectRoot ?? process.cwd();
  const setupOpts = { env, home: env.HOME || homedir(), himmelRoot: root, projectRoot };
  const himmelctl = himmelctlBin(env);
  const stateDir = join(env.HOME || homedir(), ".himmel", "state", "config-ui");
  const lockPath = join(stateDir, "write.lock");
  const auditPath = join(stateDir, "actions.jsonl");
  const reprobeMs = opts.reprobeBudgetMs ?? REPROBE_BUDGET_MS;
  // Operator override HIMMEL_REPORT_CADENCE_ROOT (shared with
  // `report`, so the feed and the actions agree): the tree the cadence scripts
  // run from, the checkout by default. Read from the production env, not gated:
  // the action tests and ci.yml rely on it (a stub tree).
  const table = buildTable({ root, cadenceRoot: env.HIMMEL_REPORT_CADENCE_ROOT ?? root, himmelctl, platform: process.platform, ...loadRegistries(root) });
  const previews = new Map<string, Preview>();
  const publicRoot = join(import.meta.dir, "public");
  let actionWorst = 0;
  for (const [, spec] of table) actionWorst = Math.max(actionWorst, opts.actionTimeoutMs ?? spec.timeoutMs);
  const worstRouteMs = 2 * reprobeMs + actionWorst;
  if (IDLE_TIMEOUT_S * 1000 < worstRouteMs + IDLE_MARGIN_S * 1000) {
    throw new Error(`config-ui: idleTimeout ${IDLE_TIMEOUT_S}s does not cover the worst route budget ${worstRouteMs}ms plus ${IDLE_MARGIN_S}s`);
  }

  // Every child output passes the same redactor as the feed, with the
  // checkout's .env values and the server env's secret values as literals.
  const redactOut = <T>(v: T): T => {
    let raw = "";
    try { raw = readFileSync(join(root, ".env"), "utf8"); } catch { /* no .env */ }
    return redactDeep(v, { literals: envValues(raw, parseDotEnv, env) });
  };
  // The child's process group is recorded in the lock, so the lock outlives a server crash while it runs.
  // `config set` writes .env and lanes.local.json under himmelctl's repo root; the feed and the live hooks read the
  // station anchor, so a worktree-served console points the config children there (an operator override wins).
  const stationEnv = env.HIMMELCTL_REPO_ROOT ? env : { ...env, HIMMELCTL_REPO_ROOT: stationRoot(root) };
  const childOpts = (p: Resolved, lock: Lock) => ({ cwd: p.cwd, env: p.action.startsWith("config.") ? stationEnv : env, timeoutMs: opts.actionTimeoutMs ?? p.timeoutMs, onSpawn: lock.setGroup });

  async function reprobe(rowIds: string[]): Promise<{ probe: Probe | null; state: string }> {
    if (rowIds.length === 0) return { probe: {}, state: "ok" };
    const r = await runChild(["node", himmelctl, "report", "--json", "--items", rowIds.join(",")], { cwd: root, env, timeoutMs: reprobeMs });
    if (r.timedOut) return { probe: null, state: "re-probe timed out" };
    if (r.rc !== 0) return { probe: null, state: "re-probe failed" };
    try {
      const probe: Probe = {};
      for (const row of JSON.parse(r.stdout).rows || []) if (rowIds.includes(row.id)) probe[row.id] = { installed: String(row.installed?.state ?? ""), health: String(row.health ?? "") };
      return { probe, state: rowIds.every((id) => id in probe) ? "ok" : "re-probe incomplete" };
    } catch { return { probe: null, state: "re-probe failed" }; }
  }
  const healthOf = (p: Probe | null) => p && Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v.health]));

  async function previewRoute(b: Record<string, unknown>): Promise<Response> {
    let p: Resolved;
    try { p = resolveAction(table, b.action, b.target, b.value); }
    catch (e) { if (e instanceof ActionError) return json({ error: e.message }, 400); throw e; }
    const lock = acquireLock(lockPath);
    if ("busy" in lock) return json({ error: lock.busy }, 409);
    let r;
    try { r = await runChild(p.dryArgv, childOpts(p, lock)); } finally { lock.release(); }
    const output = r.stdout + r.stderr;
    if (r.rc !== 0) return json(redactOut({ error: r.timedOut ? "dry-run timed out" : "dry-run failed", rc: r.rc, output }), 422);
    for (const [k, v] of previews) if (v.expires <= now()) previews.delete(k);
    const previewId = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex");
    previews.set(previewId, { ...p, expires: now() + PREVIEW_TTL_MS });
    return json({ previewId, ...redactOut({ command: p.dryArgv.join(" "), output, consent: p.consent, effect: p.effect, bank: p.bank }), expiresInMs: PREVIEW_TTL_MS });
  }

  async function runRoute(b: Record<string, unknown>, onStart: () => void): Promise<Response> {
    const id = typeof b.previewId === "string" ? b.previewId : "";
    const p = previews.get(id);
    if (!p || p.expires <= now()) { previews.delete(id); return json({ error: "preview id missing, expired or used" }, 409); }
    if (b.action !== p.action || b.target !== p.target || (b.value ?? null) !== p.value) return json({ error: "preview id is bound to a different action" }, 409);
    if (p.consent.kind === "typed" && b.consent !== p.consent.expect) return json({ error: "typed consent does not match" }, 403);
    const lock = acquireLock(lockPath);
    if ("busy" in lock) return json({ error: lock.busy }, 409);
    previews.delete(id); // single-use from here on
    let before, r, after, failed = false;
    try {
      before = await reprobe(p.rowIds);
      onStart(); // the station is about to change; a request rejected earlier leaves the feed alone
      r = await runChild(p.argv, childOpts(p, lock));
      after = await reprobe(p.rowIds);
    } catch { failed = true; } finally { lock.release(); }
    // The action has already run (or was started): a failed append must not hide that behind a 500.
    let audit = "ok";
    try { appendAudit(auditPath, { time: new Date(now()).toISOString(), action: p.action, target: p.target, value: p.value, argv: p.argv, rc: r?.rc ?? null, before: healthOf(before?.probe ?? null), after: healthOf(after?.probe ?? null), ...(failed ? { outcome: "error" as const } : {}) }); }
    catch { audit = "failed"; }
    if (failed || !r || !before || !after) return json({ error: "internal error", audit }, 500);
    const reprobeState = before.state !== "ok" ? before.state : after.state;
    return json(redactOut({ rc: r.rc, timedOut: r.timedOut, command: p.argv.join(" "), output: r.stdout + r.stderr, before: before.probe, after: after.probe, reprobe: reprobeState, audit }));
  }

  // a Kanban drop or theme select, written to Jira by the CLI under the same write lock and audit as an action.
  async function roadmapWriteRoute(b: Record<string, unknown>): Promise<Response> {
    const req = parseWrite(b);
    if ("error" in req) return json({ error: req.error }, 400);
    const lock = acquireLock(lockPath);
    if ("busy" in lock) return json({ error: lock.busy }, 409);
    const mirrorDir = env.HIMMEL_JIRA_MIRROR || join(env.HOME || homedir(), ".himmel", "state", "jira-mirror", env.JIRA_PROJECT_KEY || "HIMMEL");
    const childEnv = { ...env, JIRA_PROJECT_KEY: env.JIRA_PROJECT_KEY || "HIMMEL" };
    let res: WriteResult | undefined;
    try {
      res = await applyWrite(req, { bin: jiraBin(env), mirrorDir,
        run: (argv, timeoutMs) => runChild(argv, { cwd: root, env: childEnv, timeoutMs, onSpawn: lock.setGroup }) });
    } catch { /* audited below as an error */ } finally { lock.release(); }
    let audit = "ok";
    try {
      appendAudit(auditPath, { time: new Date(now()).toISOString(), action: req.action, target: req.key, value: req.value, argv: res?.argv ?? [], rc: res?.rc ?? null,
        before: res?.before ?? null, after: res?.after ?? null, ...(!res || res.outcome ? { outcome: "error" as const } : {}) });
    } catch { audit = "failed"; }
    if (!res) return json({ error: "internal error", audit }, 500);
    return json(redactOut({ ...res.body, audit }), res.status);
  }

  // The value is in `b` only until secretWrite returns: the audit line and the answer carry the name and the outcome.
  function setupSecretRoute(b: Record<string, unknown>): Response {
    const lock = acquireLock(lockPath);
    if ("busy" in lock) return json({ error: lock.busy }, 409);
    let r;
    try { r = secretWrite(b, { ...setupOpts, serviceMode: !!opts.noIdle }); } finally { lock.release(); }
    if (r.audit) {
      try {
        appendAudit(auditPath, { time: new Date(now()).toISOString(), action: r.audit.action, target: r.audit.target, value: null, argv: [], rc: r.audit.ok ? 0 : 1,
          before: null, after: null, ...(r.audit.ok ? {} : { outcome: "error" as const }) });
      } catch { /* the answer below still carries the outcome */ }
    }
    if (r.status === 200) { feedRun = null; feedLast = null; feedEpoch++; }
    return json(r.body, r.status);
  }

  let idle: ReturnType<typeof setTimeout> | undefined;
  // the idle window never shuts the server down mid-request; the
  // timer re-arms once the last in-flight request ends.
  let active = 0, deferred = false;
  const bump = () => {
    if (opts.noIdle) return; // service mode: the server stays up until it is stopped
    clearTimeout(idle);
    idle = setTimeout(() => {
      if (active > 0) { deferred = true; return; }
      (opts.onIdle ?? (() => process.exit(0)))();
    }, idleMs);
  };

  // The feed: ONE background report shared by every request, cached briefly.
  // A failure is terminal for that run and never cached, so the next request retries.
  // feedLast is the newest good report, answered at once even while a newer one runs
  // (stale-while-revalidate). An action clears it and bumps feedEpoch: a run started before that never becomes it.
  type FeedRun = {
    startedAt: number; done: boolean; body?: string; error?: string; at: number; promise: Promise<void>;
    epoch: number; progress: Progress | null; waiters: (() => void)[];
  };
  let feedRun: FeedRun | null = null;
  let feedLast: { body: string; at: number } | null = null;
  let feedEpoch = 0;
  const wake = (run: FeedRun) => { for (const w of run.waiters.splice(0)) w(); };
  // The run in flight, else a new one; null when the cached report is fresh (force skips that check).
  function feedStart(force = false): FeedRun | null {
    if (feedRun && !feedRun.done) return feedRun;
    if (!force && feedLast && now() - feedLast.at < FEED_CACHE_MS) return null;
    const run: FeedRun = { startedAt: now(), done: false, at: 0, promise: Promise.resolve(), epoch: feedEpoch, progress: null, waiters: [] };
    active++; // a running report keeps the idle timer from shutting the server down
    const onProgress = (p: Progress) => { if (!run.progress || p.i > run.progress.i) { run.progress = p; wake(run); } };
    run.promise = runFeed(env, opts.feedTimeoutMs ?? FEED_TIMEOUT_MS, onProgress)
      .then((b) => { run.body = b; if (run.epoch === feedEpoch) feedLast = { body: b, at: now() }; }, () => { run.error = "himmelctl report --json failed or timed out"; })
      .finally(() => { run.done = true; run.at = now(); wake(run); active--; if (deferred && active === 0) { deferred = false; bump(); } });
    return feedRun = run;
  }
  const feedBody = (body: string) => new Response(body, { headers: { "content-type": "application/json", "cache-control": "no-store" } });
  async function feedRoute(): Promise<Response> {
    const last = feedLast;
    const run = feedStart(); // an expired cache starts a refresh here
    if (last) return feedBody(last.body);
    if (!run) return json({ state: "error", reason: "no report" }, 502); // unreachable: no cached report always starts a run
    // answer as soon as the report lands, the step changes, or the wait runs out.
    let t: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([run.promise, new Promise<void>((r) => { run.waiters.push(r); }), new Promise((r) => { t = setTimeout(r, opts.feedWaitMs ?? FEED_WAIT_MS); })]);
    clearTimeout(t);
    if (!run.done) return json({ state: "running", startedAt: run.startedAt, elapsedMs: now() - run.startedAt, progress: run.progress }, 202);
    if (run.body !== undefined) return feedBody(run.body);
    return json({ state: "error", reason: run.error }, 502);
  }
  // background loading (backgroundFeed): refresh on each tick while the console is in use.
  let lastSeen = -Infinity;
  const refreshMs = opts.feedRefreshMs ?? FEED_REFRESH_MS;
  const refresher = opts.backgroundFeed ? setInterval(() => { if (now() - lastSeen < refreshMs) feedStart(true); }, refreshMs) : undefined;
  async function route(req: Request): Promise<Response> {
    const origin = `http://${LOOPBACK}:${server.port}`;
    if (req.headers.get("host") !== `${LOOPBACK}:${server.port}`) return new Response("bad host", { status: 403 });
    const path = new URL(req.url).pathname;
    if (path.startsWith("/api/")) {
      if (!sameToken(req.headers.get("x-himmel-token"), token)) return new Response("unauthorized", { status: 401 });
      bump(); // only an authenticated request keeps the server alive
      lastSeen = now(); // and only one keeps the background refresh going
      if (req.method === "GET" && path === "/api/feed") {
        return feedRoute();
      }
      if (path === "/api/tool-health") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        return json(redactOut(readToolHealth(env, new URL(req.url).searchParams, now())));
      }
      if (path === "/api/health") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        const [bank, legs, monitoring] = await Promise.all([
          Promise.resolve(readBank(env)),
          readLegs(opts.legsScript ?? join(CHECKOUT, "scripts/config-ui/legs.sh"), env, opts.legsTimeoutMs),
          readMonitoring(env),
        ]);
        return json(redactOut({ bank, legs, monitoring, mode: readMode(root, env) }));
      }
      // the Claude and Codex bank windows, read from the two cache files bank-preflight reads. Never probes.
      if (path === "/api/bank") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        return json(redactOut(readQuota(env, now())));
      }
      // the tracker sources the rail gates Roadmap and Kanban on.
      if (path === "/api/sources") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        return json({ sources: await trackerSources(env, root) });
      }
      // the roadmap, read live from the Jira mirror, the plan dir, the drift log and the legs on every request, or from the
      // GitHub issues when that is the only source. Read-only: the sync list is a plan the console kit executes, never run here.
      if (path === "/api/roadmap") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        const mirrorDir = jiraMirrorDir(env);
        if ((await trackerSources(env, root))[0] === "github") {
          const issues = await readGithubIssues(env, root);
          const r = readRoadmap({ mirrorDir, github: issues ?? [], legs: { state: "absent" } });
          return json(redactOut({ ...r, ...(issues ? {} : { reason: "gh issue list failed" }), truncated: (issues?.length ?? 0) >= ISSUE_LIMIT, sync: [] }));
        }
        const legs = await readLegs(opts.legsScript ?? join(CHECKOUT, "scripts/config-ui/legs.sh"), env, opts.legsTimeoutMs);
        const driftLog = env.HIMMEL_ROADMAP_DRIFT_LOG || (env.TRACKER_HANDOVERS_DIR ? join(env.TRACKER_HANDOVERS_DIR, "roadmap-drift.tsv") : undefined);
        const r = readRoadmap({ mirrorDir, planDir: env.HIMMEL_ROADMAP_PLAN_DIR || undefined, driftLog, legs });
        return json(redactOut({ ...r, sync: legSync(r.tickets) }));
      }
      // every live session, for the fleet landing at /agui/ with no run. Read-only.
      if (path === "/api/agui/fleet") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        let raw = "";
        try { raw = readFileSync(join(root, ".env"), "utf8"); } catch { /* no .env */ }
        const literals = envValues(raw, parseDotEnv, env);
        return json(await readFleet({
          script: opts.fleetScript ?? join(CHECKOUT, "scripts/config-ui/fleet.sh"), env, home: env.HOME || homedir(), now: now(),
          redact: (v) => String(redactDeep(v, { literals })),
        }));
      }
      // the console board (board.mjs --json, schema himmel.board/1) for the Fleet page, and a leg's doc for its brief link.
      if (path === "/api/agui/board" || path === "/api/agui/brief") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        const q = new URL(req.url).searchParams, board = path.endsWith("board");
        const name = q.get(board ? "console" : "leg");
        if (!validName(name)) return new Response(board ? "bad console" : "bad leg", { status: 400 });
        const doc = await findDoc(env.HANDOVER_DIR || "", name);
        if (!doc) return new Response("no such doc", { status: 404 });
        if (!board) return new Response(String(scrub(readFileSync(doc, "utf8").slice(0, 200_000), (v) => redactOut(v))), { headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
        const r = (await readBoardFile(doc)) ?? await readBoard({ script: opts.boardScript ?? join(CHECKOUT, "scripts/handover/console-kit/board.mjs"), doc, checkout: CHECKOUT, env: { ...env }, now: now() });
        return "error" in r ? json({ error: "the board could not be built", detail: String(scrub(r.error)) }, 502) : json(scrub(r.body, (v) => redactOut(v)));
      }
      if (path.startsWith("/api/agui/")) {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        const run = path.slice("/api/agui/".length);
        const found = await resolveJournal(env.HOME || homedir(), run);
        if ("status" in found) return new Response(found.status === 400 ? "bad run id" : found.status === 404 ? "no such run" : "run id is ambiguous", { status: found.status });
        // Secrets in the transcript pass the same redactor as every other output; literals read once per stream.
        let raw = "";
        try { raw = readFileSync(join(root, ".env"), "utf8"); } catch { /* no .env */ }
        const literals = envValues(raw, parseDotEnv, env);
        active++; // an open stream keeps the idle timer from shutting the server down
        const body = journalStream(found.path, {
          threadId: run, pollMs: opts.aguiPollMs ?? AGUI_POLL_MS, idleMs: opts.aguiIdleMs ?? AGUI_IDLE_MS, maxMs: opts.aguiMaxMs ?? AGUI_MAX_MS,
          redact: (v) => redactDeep(v, { literals }),
          busRoot: busRootOf(env, env.HOME || homedir()),
          onClose: () => { active--; if (deferred && active === 0) { deferred = false; bump(); } },
        });
        return new Response(body, { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
      }
      // which secrets are set (presence only) and the commit rules in effect, for the Setup page.
      if (path === "/api/setup") {
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        return json(setupState(setupOpts));
      }
      // the vm section of the himmel config, validated and saved through luna-config.js.
      if (path === "/api/vm" && req.method === "GET") { const v = readVm(); return json(redactOut(v.body), v.status); }
      if (path !== "/api/preview" && path !== "/api/run" && path !== "/api/vm" && path !== "/api/roadmap/write" && path !== "/api/setup/secret") return new Response("not found", { status: 404 });
      if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
      if (req.headers.get("origin") !== origin) return new Response("bad origin", { status: 403 });
      if ((req.headers.get("content-type") || "").split(";")[0].trim().toLowerCase() !== "application/json") return new Response("json only", { status: 415 });
      const text = await req.text();
      if (text.length > MAX_BODY) return json({ error: "body too large" }, 413);
      let b: unknown;
      try { b = JSON.parse(text); } catch { return json({ error: "bad json" }, 400); }
      if (!b || typeof b !== "object" || Array.isArray(b)) return json({ error: "bad json" }, 400);
      if (path === "/api/vm") { const v = writeVm(b as Record<string, unknown>); return json(redactOut(v.body), v.status); }
      if (path === "/api/roadmap/write") return roadmapWriteRoute(b as Record<string, unknown>);
      if (path === "/api/setup/secret") return setupSecretRoute(b as Record<string, unknown>);
      if (path === "/api/preview") return previewRoute(b as Record<string, unknown>);
      let started = false;
      const res = await runRoute(b as Record<string, unknown>, () => { started = true; });
      // An action ran: the next feed re-probes, never reusing a cached or in-flight (pre-action) report.
      if (started) { feedRun = null; feedLast = null; feedEpoch++; }
      return res;
    }
    if (req.method === "GET" && path === "/agui") return new Response(null, { status: 308, headers: { location: "/agui/" } });
    if (req.method === "GET" && path.startsWith("/agui/")) return aguiFile(opts.aguiDist ?? AGUI_DIST, path, opts.aguiWeb ?? AGUI_WEB);
    if (req.method === "GET" && path.startsWith("/dev-graph/")) return devGraphFile(DEV_GRAPH_DIR, path);
    const file = STATIC[path];
    if (req.method === "GET" && file) return new Response(readFileSync(join(publicRoot, file[0])), { headers: { "content-type": file[1], "cache-control": "no-store" } });
    return new Response("not found", { status: 404 });
  }
  const server = Bun.serve({
    hostname: LOOPBACK, // hard-coded: never configurable
    idleTimeout: IDLE_TIMEOUT_S,
    port: opts.port ?? 0,
    maxRequestBodySize: MAX_BODY, // bounds buffering before req.text(); the length check below stays
    async fetch(req) {
      let res: Response;
      active++;
      try { res = await route(req); } catch { res = json({ error: "internal error" }, 500); }
      finally { active--; if (deferred && active === 0) { deferred = false; bump(); } }
      for (const [k, v] of Object.entries(SECURITY_HEADERS)) res.headers.set(k, v);
      return res;
    },
  });
  bump();
  if (opts.backgroundFeed) feedStart(true); // prewarm, so the report is there when the console opens
  return { server, port: server.port, token, stop: () => { clearTimeout(idle); clearInterval(refresher); server.stop(true); } };
}

// `himmelctl ui` prints ONE URL. LANDING is the operator's switch: "fleet" lands on the fleet
// (Config and Health one click away in the rail), "config" on the config page. The fleet is the landing only
// when agui-web/dist is built; else the console, whose Fleet link answers with the build steps.
export const LANDING: "fleet" | "config" = "fleet";
export function launchUrl(base: string, token: string, o: { landing: "fleet" | "config"; built: boolean; agui?: string }): string {
  if (o.agui && o.agui !== "fleet") return `${base}/agui/#t=${token}&run=${o.agui}`;
  return o.agui === "fleet" || (o.landing === "fleet" && o.built) ? `${base}/agui/#t=${token}` : `${base}/#t=${token}`;
}

// Service mode starts with the page built from the current sources: a missing, old or source-orphaned dist is rebuilt.
export function rebuildAguiIfStale(log: (m: string) => void, dist = AGUI_DIST, web = AGUI_WEB): void {
  if (existsSync(join(dist, "index.html")) && !aguiStale(dist, web)) return;
  log("himmelctl: ui: rebuilding the AG-UI page");
  if (!existsSync(join(web, "node_modules"))) execFileSync("bun", ["install"], { cwd: web, stdio: ["ignore", 2, 2] });
  execFileSync("bun", ["run", "build"], { cwd: web, stdio: ["ignore", 2, 2] });
}

if (import.meta.main) {
  const i = process.argv.indexOf("--port");
  const a = process.argv.indexOf("--agui");
  // --service (himmelctl ui --service, a systemd user unit): a token that outlives the process, no idle exit.
  const service = process.argv.includes("--service");
  let fixed: string | undefined;
  if (service) {
    try {
      fixed = readOrCreateToken(join(process.env.HOME || homedir(), ".himmel", "state", "ui-token"), newToken);
      rebuildAguiIfStale((m) => console.error(m));
    } catch (e) {
      console.error(`himmelctl: ui: ${(e as Error).message}`);
      process.exit(1);
    }
  }
  // the operator lands on Fleet (another page); the config report loads meanwhile.
  const { port, token } = startServer({ port: i > 0 ? Number(process.argv[i + 1]) : 0, backgroundFeed: true, noIdle: service, token: fixed });
  // himmelctl ui --agui [<run>]: the launcher has already resolved and validated the run id; with none, the
  // fleet landing.
  const run = a > 0 ? process.argv[a + 1] : undefined;
  const agui = a > 0 ? (run && !run.startsWith("--") ? run : "fleet") : undefined;
  const url = launchUrl(`http://${LOOPBACK}:${port}`, token, { landing: LANDING, built: existsSync(join(AGUI_DIST, "index.html")), agui });
  console.log(url);
  const stale = url.includes("/agui/") ? aguiStaleWarning() : null;
  if (stale) console.error(stale);
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
}
