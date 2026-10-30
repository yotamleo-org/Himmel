// fleet.ts — every live session on one page, for GET /api/agui/fleet.
//
// The census is fleet.sh's (claude_sessions + each session's worker doc and its worker_tail_status); this joins each
// census pid to the harness's ~/.claude/sessions/<pid>.json (its sessionId and busy/idle status), finds the
// session's journal with sse.ts's resolveJournal, and folds the journal and its subagent transcripts through the
// same mapper and reducer the per-run page uses, so a row's subagents and failures are the counts that page shows.
// A session whose journal has not been written for RECENT_MS is not live and is left out; one with no journal
// yet is listed bare. Read-only: nothing here writes.
//
// a row also carries its place in the agent graph (graphOf: the parent chief its own handover doc
// names, and a chief's predecessor) with its in-process subagents, and its token usage (usageOf: the journal's
// API usage records, per call, priced with the worker-burn weights and filled against its --autocompact ceiling).
//
// cloud sessions join as rows of role "cloud" (fleet-cloud.ts: the chief bucket's cloud-route.jsonl
// plus one cached GitHub read), each under the chief its brief names, with its local shepherd worker under it.
//
// a row carries its lane and how it was found (laneOf: the launch record, never the model string), the
// backend model, a cost row (a claudex worker priced from the codex weekly bank delta, never at Claude weights) and an
// eval row (the per-lane quality measure); the fleet carries the one codex bank reading they were priced against.
//
// the himmel-bus traffic comes from the one collector (busEvents, metadata only): Fleet.edges counts the messages
// per from→to pair and a row's bus counts what is waiting on it (busOf). Read-only: no store is created.
//
// ponytail: each request re-folds every journal that grew since the last one (cached on the files' sizes), so a
// fleet of very long journals costs a full read per poll (measured 2026-10-07 on 9 live sessions: 278 ms cold,
// 202 ms warm); upgrade path: a per-file incremental fold (the SSE tail's offsets) once a fleet poll is slow.
import { execFile, spawn } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { agentState, initialView, reduce, type View } from "../agui-web/src/reducer.ts";
import { cloudRoutes, consoleOf, GH_WAIT_MS, readCloudPrs, type CloudPhase, type CloudRoute } from "./fleet-cloud.ts";
import { createJournalMapper } from "./journal-mapper.ts";
import { mergeJournalFiles, sessionFiles } from "./journal-merge.ts";
import { backendModelOf, codexStartOf, costRowOf, evalRowOf, laneOf, readCodexBank, W, type CodexBank, type CostRow, type EvalRow, type Lane, type LaneFrom } from "./lane.ts";
import { busRootOf, registerConfigRoot, resolveJournal } from "./sse.ts";
import { busEvents } from "../../../marketplace/plugins/himmel-bus/lib/agui.mjs";
import { loadPeers } from "../../../marketplace/plugins/himmel-bus/lib/identity.mjs";

export const RECENT_MS = 60 * 60 * 1000;
const SCRIPT_TIMEOUT_MS = 30_000;
const CONSOLE_DOC_CONCURRENCY = 16;

// fn over items with at most `limit` in flight; results keep the items' order.
async function mapLimit<T, R>(items: T[], limit: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) { const i = next++; out[i] = await fn(items[i]); }
  }));
  return out;
}

export type FleetState = "running" | "idle" | "waiting" | "waiting for GO" | "wrapped" | "unknown";
export type FleetRow = {
  run: string | null; pid: number | null; name: string; role: "console" | "leg" | "judge" | "consult" | "interactive" | "cloud"; model: string | null;
  ticket: string | null; pr: number | null; state: FleetState;
  activity: { tool: string; summary: string; at: number } | null; lastEventAt: number | null;
  subagents: { total: number; running: number }; failures: number;
  parent: string | null; predecessor: string | null; agents: { name: string; role: string; state: string }[];
  usage: Usage | null;
  cloud: { url: string | null; phase: CloudPhase } | null;
  runtime: { startedAt: number; endedAt: number | null; elapsedMs: number } | null;
  console: string | null; live: boolean; lock: "held" | "released" | "unknown";
  // the cadence an unattended scheduled session belongs to (cadenceOf), else null.
  cadence: string | null;
  lane: Lane; laneFrom: LaneFrom | null; backendModel: string | null; cost: CostRow | null; eval: EvalRow | null;
  // the doc's last Results marker (worker_tail_status), the doc's last write, and the PR's URL.
  marker: string | null; lastSeenAt: number | null; prUrl: string | null;
  bus: BusCounts;
  // worker_description (worker-identity.sh) for the row's doc, tabs and newlines folded; "" when it has no doc or the lookup failed.
  description: string;
};
// unacked: rulings (c=1) sent to the row that it has not answered; undelivered: messages it has not yet seen;
// unbound: registered with the bus but never bound to a process.
export type BusCounts = { unacked: number; undelivered: number; unbound: boolean };
export type BusEdge = { from: string; to: string; n: number; unacked: number; lastAt: number; kinds: Record<string, number> };
// kind: orphan = no live session owns it; wait = a live session's own long-running call; stuck = its pgrep -f wait matches itself.
export type ProcessOrphan = { pid: number; owner: string; ageMin: number; kind: "orphan" | "wait" | "stuck" };
export type Usage = {
  calls: number; input: number; output: number; cacheRead: number; cacheCreate: number; costEq: number | null;
  resident: number | null; ceiling: number; ceilingFrom: "autocompact" | "window"; fill: number | null;
};
// processOrphans: tick's stale shell-tool wrappers; null when the inventory could not be read.
export type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: FleetRow[]; edges: BusEdge[]; processOrphans: ProcessOrphan[] | null; banks: { codex: CodexBank | null } };
type CensusRow = { pid: string; name: string; model: string; doc: string; status: string; autocompact?: string; startedAt?: number | null };
type Census = { census: Fleet["census"]; sessions: CensusRow[]; cloudRoutes?: string[]; manifests?: string[]; consoleDocs?: string[] };

// A session name as the launchers write it; anything else in a doc is text, never a link.
const SESSION = /^[A-Za-z0-9._+-]{1,160}$/;
const plain = (s: string | undefined) => (s && SESSION.test(s) ? s : null);

// Where a session sits, read from its own doc only. A worker's chief is the one its brief names, or the newest
// chief it accepted in a `SUCCESSION accepted: <new> replaces <old>` bullet; a judge's is the chief that
// dispatched it; a chief hangs under the operator (parent null) and names the chief it succeeded.
export function graphOf(role: FleetRow["role"], doc: string): { parent: string | null; predecessor: string | null } {
  if (role === "console") return { parent: null, predecessor: plain(/successor to `?([^\s`]+?)(?:\.md)?`?[\s(]/.exec(doc)?.[1]) };
  let parent = plain(/your console is\W*`([^`]+)`/i.exec(doc)?.[1]);
  if (role === "judge" || role === "consult") parent ??= plain(/dispatched by\s*(?:>\s*)?`([^`]+)`/.exec(doc)?.[1]);
  if (role === "leg" || role === "judge" || role === "consult") {
    // canonical `accepted: <new> replaces <old>`, or the relay wording `accepted — relay from <old>, new chief <new>`
    for (const m of doc.matchAll(/^- (?:[\d:]+ )?(?:LIVE — )?SUCCESSION accepted(?:: `?([^\s`]+)`? replaces| — relay from \S+, new console `?([^\s`,]+))/gm)) parent = plain(m[1] ?? m[2]) ?? parent;
  }
  return { parent, predecessor: null };
}

// A chief's own wrap is the line chief.sh wrap writes (`WRAPPED — <text>`) under `## Results`, as the shell
// reader scopes it; `WRAPPED N2470 (#2951 → …)` is a note about a worker, and a quoted wrap above Results is prose.
const ownWrap = (doc: string) => {
  const at = doc.search(/^## Results/m);
  return at >= 0 && /^- (?:[\d:]+ )?WRAPPED —/m.test(doc.slice(at));
};

const WINDOW_1M = 1_000_000, WINDOW = 200_000;
type Tally = Omit<Usage, "costEq" | "ceiling" | "ceilingFrom" | "fill">;
const count = (x: unknown) => (Number.isSafeInteger(x) && (x as number) >= 0 ? (x as number) : 0);

// One API call writes one record per content block, all with its message id and usage: each id counts once.
// resident = the input side of the newest main-thread call (input + cache read + cache create), the tokens in
// the window on that turn (context-fill.sh's per-turn count); subagent calls run in their own windows.
function tallyOf(lines: string[]): Tally | null {
  const t: Tally = { calls: 0, input: 0, output: 0, cacheRead: 0, cacheCreate: 0, resident: null };
  const seen = new Set<string>();
  for (const line of lines) {
    let r: any;
    try { r = JSON.parse(line); } catch { continue; }
    const u = r?.type === "assistant" ? r.message?.usage : undefined, id = r?.message?.id;
    if (!u || typeof u !== "object" || typeof id !== "string" || seen.has(id)) continue;
    seen.add(id);
    t.calls++;
    t.input += count(u.input_tokens); t.output += count(u.output_tokens);
    t.cacheRead += count(u.cache_read_input_tokens); t.cacheCreate += count(u.cache_creation_input_tokens);
    if (r.isSidechain !== true) t.resident = count(u.input_tokens) + count(u.cache_read_input_tokens) + count(u.cache_creation_input_tokens);
  }
  return t.calls ? t : null;
}

// The ceiling is the window the launch declared (claude-codex's CLAUDE_CODE_MAX_CONTEXT_TOKENS, which a
// claudex session honours over --autocompact); else the session's numeric --autocompact; else a Claude model's window.
// A non-Claude model nobody declared a window for, or a fill past 100 % (so the ceiling is wrong), is not measured.
const num = (s: string | undefined) => (s && /^\d+$/.test(s) ? Number(s) : 0);
function finish(t: Tally | null, c: { autocompact: string; model: string; window?: string; priced?: boolean }): Usage | null {
  if (!t) return null;
  const declared = num(c.window), ac = num(c.autocompact);
  const claude = /claude|opus|sonnet|haiku|fable/i.test(c.model) || c.model === "";
  const ceiling = declared || ac || (/\[1m\]$/i.test(c.model) ? WINDOW_1M : WINDOW);
  const fill = t.resident === null || (!declared && !ac && !claude) ? null : Math.round((t.resident / ceiling) * 1000) / 10;
  return {
    ...t, costEq: c.priced === false ? null : Math.round(t.input * W.input + t.cacheRead * W.cacheRead + t.cacheCreate * W.cacheCreate + t.output * W.output),
    ceiling, ceilingFrom: !declared && ac ? "autocompact" : "window",
    fill: fill !== null && fill > 100 ? null : fill,
  };
}
export const usageOf = (lines: string[], c: { autocompact: string; model: string; window?: string; priced?: boolean }) => finish(tallyOf(lines), c);

function runScript(script: string, env: Record<string, string | undefined>): Promise<Census> {
  return new Promise((ok) => {
    execFile("bash", [script], { env: env as NodeJS.ProcessEnv, timeout: SCRIPT_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      try { if (!err) return ok(JSON.parse(stdout)); } catch { /* fall through */ }
      ok({ census: "unavailable", sessions: [] });
    });
  });
}

// the shell-tool wrappers tick reports as orphans, from the chief kit's own inventory (`--list`: one
// `pid=<pid> owner=<session> age=<n>m` row each); read-only, and null when it failed rather than an empty list.
// a wrapper owned by a live session is that session's own long-running call: a "wait", not an orphan.
// ponytail: a wait is stuck only when a `until ! pgrep -f` / `while pgrep -f` pattern matches the wrapper's own
// argv (the shape require-quiet-run.sh refuses, ERE read as a JS RegExp); other never-ending waits read as waits, upgrade path: add their shapes here.
const SELF_PGREP = /(?:until\s+!\s+|while\s+)pgrep\s+((?:-\w+\s+)*?-\w*f\w*(?:\s+-\w+)*)\s+(?:(?:'\\''|'|\\?")([^'"]*)|(\S+))/g;
async function selfMatches(pid: number, env: Record<string, string | undefined>): Promise<boolean> {
  try {
    const argv = (await readFile(join(env.CLAUDE_SESSIONS_PROC || "/proc", String(pid), "cmdline"), "utf8")).split("\0").join(" ");
    // -x anchors the pattern to the whole command line, -i ignores case, -v selects the wrapper when the pattern does not match it
    return [...argv.matchAll(SELF_PGREP)].some((m) => {
      const pat = (m[2] ?? m[3]).replace(/\\+$/, "");
      try { return new RegExp(/-\w*x/.test(m[1]) ? `^(?:${pat})$` : pat, /-\w*i/.test(m[1]) ? "i" : "").test(argv.trim()) !== /-\w*v/.test(m[1]); } catch { return false; }
    });
  } catch { return false; }
}
async function processOrphansOf(opts: { script: string; env: Record<string, string | undefined> }, live: Set<string> = new Set()): Promise<ProcessOrphan[] | null> {
  const script = opts.env.CONFIG_UI_ORPHAN_LOOPS || join(dirname(opts.script), "../handover/chief-kit/orphan-loops.sh");
  const listed = await new Promise<string | null>((ok) => {
    execFile("bash", [script, "--list"], { env: opts.env as NodeJS.ProcessEnv, timeout: 10_000, maxBuffer: 256 * 1024 }, (err, stdout) => ok(err ? null : stdout));
  });
  if (listed === null) return null;
  return Promise.all(listed.split("\n").flatMap((l) => {
    const m = /^pid=(\d+) owner=(\S+) age=(\d+)m$/.exec(l.trim());
    const owner = m && plain(m[2]);
    return m && owner ? [{ pid: Number(m[1]), owner, ageMin: Number(m[3]) }] : [];
  }).map(async (p): Promise<ProcessOrphan> => ({ ...p, kind: (await selfMatches(p.pid, opts.env)) ? "stuck" : live.has(p.owner) ? "wait" : "orphan" })));
}

// the GitHub repo a PR number belongs to — CONFIG_UI_GITHUB_REPO (owner/name), else this checkout's
// origin. ponytail: every worker's PR is linked into this checkout's repo; a worker working another repo's PR gets a wrong
// link, upgrade path: resolve the repo per handover bucket from the registry once workers routinely ship elsewhere.
const slugs = new Map<string, string | null>();
async function repoSlugOf(checkout: string, env: Record<string, string | undefined>): Promise<string | null> {
  const SLUG = /^[\w.-]+\/[\w.-]+$/;
  if (env.CONFIG_UI_GITHUB_REPO) return SLUG.test(env.CONFIG_UI_GITHUB_REPO) ? env.CONFIG_UI_GITHUB_REPO : null;
  if (!slugs.has(checkout)) slugs.set(checkout, await new Promise<string | null>((ok) => {
    execFile("git", ["-C", checkout, "remote", "get-url", "origin"], { timeout: 3000 }, (err, stdout) => {
      const s = !err && /github\.com[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?\s*$/.exec(stdout)?.[1];
      ok(s && SLUG.test(s) ? s : null);
    });
  }));
  return slugs.get(checkout) ?? null;
}
const prUrlOf = (slug: string | null, pr: number | null) => (slug && pr !== null ? `https://github.com/${slug}/pull/${pr}` : null);

// The cloud sessions the chief buckets' routing logs name, each a row under the chief its brief names; a GitHub
// read that failed leaves every one unknown (no PR, no URL) rather than failing the fleet.
const CLOUD_STATE: Record<CloudPhase, FleetState> = { working: "running", done: "idle", blocked: "idle", merged: "wrapped", closed: "wrapped", unknown: "unknown" };
async function cloudRows(logs: string[], env: Record<string, string | undefined>, now: number): Promise<FleetRow[]> {
  const read: { lines: string[]; bucket: string }[] = [];
  for (const log of logs) {
    try { read.push({ lines: (await readFile(log, "utf8")).split("\n"), bucket: dirname(log) }); } catch { /* unreadable: skip */ }
  }
  const routes: CloudRoute[] = cloudRoutes(read, now);
  if (!routes.length) return [];
  const prs = await readCloudPrs(routes.map((r) => r.ticket), { gh: env.CONFIG_UI_GH || "gh", env, now, waitMs: GH_WAIT_MS });
  return Promise.all(routes.map(async (r): Promise<FleetRow> => {
    const p = prs?.get(r.ticket) ?? { pr: null, phase: "unknown" as const, url: null };
    return {
      run: null, pid: null, name: `cloud-${r.ticket}`, role: "cloud", model: null, ticket: r.ticket, pr: p.pr, state: CLOUD_STATE[p.phase],
      activity: null, lastEventAt: null, subagents: { total: 0, running: 0 }, failures: 0,
      parent: await consoleOf(r), predecessor: null, agents: [], usage: null, cloud: { url: p.url, phase: p.phase },
      runtime: p.phase === "merged" || p.phase === "closed" ? null : { startedAt: r.at, endedAt: null, elapsedMs: Math.max(0, now - r.at) },
      console: await consoleOf(r), live: p.phase !== "merged" && p.phase !== "closed", lock: "unknown", cadence: null, lane: "cloud", laneFrom: null, backendModel: null, cost: null, eval: null,
      marker: null, lastSeenAt: null, prUrl: null, bus: NO_BUS, description: "",
    };
  }));
}

// A row's description is the resolver's (the doc's field, the ticket title, the PR title, the H1, the stem); never a
// second derivation here. The resolver can reach Jira and GitHub, so a lookup is one bash call per listed row, run in
// the background: it is killed with its process group after DESC_TIMEOUT_MS, a request waits at most DESC_WAIT_MS for
// the ones it started and starts at most DESC_BATCH, and the outcome (a failure is "") is cached on the doc's mtime read
// BEFORE the call, so a poll never repeats one. A row with no answer yet shows its name alone.
const DESC_TIMEOUT_MS = 10_000;
const DESC_WAIT_MS = 2_000;
const DESC_BATCH = 8;
const descs = new Map<string, { mtime: number; text: string }>();
const inflight = new Map<string, Promise<void>>();
function lookup(doc: string, mtime: number, lib: string, env: Record<string, string | undefined>): Promise<void> {
  return new Promise((done) => {
    // spawn, not execFile: execFile drops `detached`, so its child would share our process group and the group kill below would miss it
    const child = spawn("bash", ["-c", 'source "$1" || exit 1; worker_description "$2" | tr -s "\\t\\n" "  "', "bash", lib, doc],
      { env: env as NodeJS.ProcessEnv, detached: true, stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (b) => { if (out.length < 64 * 1024) out += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid!, "SIGKILL"); } catch { /* already gone */ } }, Number(env.HIMMEL_FLEET_DESC_TIMEOUT_MS) || DESC_TIMEOUT_MS);
    timer.unref();
    let settled = false;
    const finish = (text: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      descs.set(doc, { mtime, text });
      inflight.delete(doc);
      done();
    };
    child.on("error", () => finish(""));
    child.on("close", (code) => finish(code === 0 ? out.trim() : ""));
  });
}
async function describe(docs: string[], script: string, env: Record<string, string | undefined>): Promise<(doc: string) => string> {
  const wanted = new Set(docs.filter(Boolean));
  for (const f of descs.keys()) if (!wanted.has(f)) descs.delete(f);
  const lib = join(dirname(script), "../lib/worker-identity.sh");
  const waiting: Promise<void>[] = [];
  const mtimes = new Map<string, number>();
  let started = 0;
  for (const f of wanted) {
    const m = await stat(f).then((s) => s.mtimeMs, () => 0);
    mtimes.set(f, m);
    if (descs.get(f)?.mtime === m) continue;
    let p = inflight.get(f);
    if (!p) {
      if (started >= DESC_BATCH) continue;
      started++;
      p = lookup(f, m, lib, env);
      inflight.set(f, p);
    }
    waiting.push(p);
  }
  if (waiting.length) {
    let t: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([Promise.all(waiting), new Promise((ok) => { t = setTimeout(ok, DESC_WAIT_MS); })]);
    clearTimeout(t);
  }
  return (doc) => {
    const d = descs.get(doc);
    return d && d.mtime === mtimes.get(doc) ? d.text : "";
  };
}

const NO_BUS: BusCounts = { unacked: 0, undelivered: 0, unbound: false };
const BUS_KINDS = new Set(["ruling", "report", "proposal", "data"]);

// The bus's edges and each session's counts, from busEvents' metadata; an unreadable or absent store is no traffic.
async function busOf(root: string): Promise<{ edges: BusEdge[]; of: (name: string) => BusCounts }> {
  type Msg = { f?: string | null; r?: string | null; t?: number; c?: number; kind?: string; delivered?: boolean; acked?: boolean; expired?: boolean };
  const msgs = new Map<string, Msg>();
  try {
    for await (const e of busEvents(root)) {
      const d = e.delta[0], m = /^\/bus\/msgs\/([^/]+)(?:\/(delivered|acked|expired))?$/.exec(d.path);
      if (!m) continue;
      const msg = msgs.get(m[1]) ?? {};
      msgs.set(m[1], msg);
      if (m[2]) msg[m[2] as "delivered" | "acked" | "expired"] = true;
      else Object.assign(msg, { f: plain(d.value.f), r: plain(d.value.r), t: d.value.t, c: d.value.c, kind: d.value.kind });
    }
  } catch { return { edges: [], of: () => NO_BUS }; }
  let peers: Record<string, { pid?: number }> = {};
  try { peers = await loadPeers(root); } catch { /* no registry: nothing is unbound */ }
  const edges = new Map<string, BusEdge>(), rows = new Map<string, BusCounts>();
  for (const msg of msgs.values()) {
    if (!msg.f || !msg.r || msg.t === undefined) continue; // a follow-up whose send is gone
    const ruling = msg.c === 1 && !msg.acked && !msg.expired;
    const edge = edges.get(`${msg.f}\0${msg.r}`) ?? { from: msg.f, to: msg.r, n: 0, unacked: 0, lastAt: 0, kinds: {} };
    edges.set(`${msg.f}\0${msg.r}`, edge);
    const kind = BUS_KINDS.has(msg.kind ?? "") ? msg.kind! : "data";
    edge.n++; edge.unacked += ruling ? 1 : 0; edge.lastAt = Math.max(edge.lastAt, msg.t); edge.kinds[kind] = (edge.kinds[kind] ?? 0) + 1;
    const row = rows.get(msg.r) ?? { ...NO_BUS };
    rows.set(msg.r, row);
    row.undelivered += msg.delivered || msg.acked || msg.expired ? 0 : 1; row.unacked += ruling ? 1 : 0;
  }
  return { edges: [...edges.values()], of: (name) => ({ ...(rows.get(name) ?? NO_BUS), unbound: !!peers[name] && peers[name].pid === undefined }) };
}

// where a chief doc records its release token: a backticked lock bullet, or the fenced block ACTION ZERO fills in
// under "Its release token is:" (a block still reading `none yet — …` has spaces, so it is no token)
const RECORDED_LOCK = [/^- .*\b(?:lock|release-token)\b.*`[^`]+`/m, /release token is:\s*\n\s*```[^\n]*\n\s*[^\s`]+\s*\n\s*```/i];

const roleOf = (name: string, doc: string): FleetRow["role"] =>
  /-(console|chief)$/.test(name) ? "console" : /(^|-)consult(-|$)/i.test(name) ? "consult" : /(^|-)judge(-|$)|(^|-)J\d+(-|$)/i.test(name) ? "judge" : doc ? "leg" : "interactive";

// Scheduled sessions. The ids are scripts/himmelctl/lib/cadence-registry.json's, plus luna-fb (the luna capture loop); the
// runner basenames in scripts/lib/cadence-format.sh (CADENCE_RUNNER_BASENAMES) start with one of them. A cadence run is
// usually unnamed but carries its --settings cadence-settings.json fragment in its argv (pipeline-cadence.sh).
// ponytail: a name pattern plus one argv fragment, a cadence launched another way shows as another session; the upgrade is a launch-env marker the runners set.
export const CADENCE_IDS = ["pipeline", "qmd", "graphmap", "drift-fix", "upstream-watch", "doctor", "pull-cadence", "vault-stall", "luna-fb"];
const CADENCE_NAME = new RegExp("^(" + CADENCE_IDS.join("|") + ")(?:-cadence|-[a-z]+)?$");
export function cadenceOf(name: string, argv: string[]): string | null {
  const id = CADENCE_NAME.exec(name)?.[1];
  if (id) return id;
  return argv.some((a) => a.endsWith("cadence-settings.json")) ? "cadence" : null;
}

// The PR a worker doc names last: `READY <pr> ...` or `PR <n>` / `PR #<n>` in its bullets.
function prOf(text: string): number | null {
  let pr: number | null = null;
  for (const m of text.matchAll(/^- .*?\b(?:READY|PR) #?(\d+)\b/gm)) pr = Number(m[1]);
  return pr;
}

function runtimeOf(start: unknown, fallback: number | undefined, doc: string, wrapped: boolean, now: number, docAt: number): FleetRow["runtime"] {
  const parsed = typeof start === "string" ? Date.parse(start) : typeof start === "number" ? start : NaN;
  const startedAt = Number.isFinite(parsed) ? parsed : fallback;
  if (startedAt === undefined || !Number.isFinite(startedAt)) return null;
  let endedAt: number | null = null;
  if (wrapped) {
    const time = [...doc.matchAll(/^- (\d\d):(\d\d) WRAPPED\b/gm)].at(-1);
    if (!time) return null; // Unknown end is not a running clock.
    // ponytail: Results markers carry HH:MM only, so the doc's write-day supplies
    // the date; upgrade to an explicit WRAPPED timestamp when the writer records one.
    const end = new Date(docAt);
    end.setHours(Number(time[1]), Number(time[2]), 0, 0);
    endedAt = end.getTime();
    if (endedAt < startedAt || endedAt > now) return null;
  }
  return { startedAt, endedAt, elapsedMs: Math.max(0, (endedAt ?? now) - startedAt) };
}

function stateOf(status: string, sessionStatus: unknown): FleetState {
  if (status === "WRAPPED") return "wrapped";
  if (status === "READY") return "waiting for GO";
  if (sessionStatus === "shell") return "waiting";
  return sessionStatus === "busy" ? "running" : "idle";
}

// The one argument that says what a call is doing (App.tsx's summarize, on the server side).
function summarize(args: string): string {
  let a: Record<string, unknown> | null = null;
  try { const v = JSON.parse(args); a = v && typeof v === "object" ? v : null; } catch { /* streaming */ }
  if (!a) return args;
  for (const k of ["description", "command", "file_path", "pattern", "url", "query"]) if (typeof a[k] === "string") return a[k] as string;
  const first = Object.values(a).find((x) => typeof x === "string");
  return typeof first === "string" ? first : "";
}

type Folded = { view: View; tally: Tally | null; rounds: number[] };
const folds = new Map<string, { key: string } & Folded>();
async function fold(journal: string): Promise<Folded> {
  const { paths } = await sessionFiles(journal);
  const sizes = await Promise.all(paths.map((p) => stat(p).then((s) => s.size, () => -1)));
  const key = paths.map((p, i) => `${p}:${sizes[i]}`).join("|");
  const hit = folds.get(journal);
  if (hit?.key === key) return hit;
  const { lines } = await mergeJournalFiles(paths);
  const mapper = createJournalMapper();
  let view = initialView();
  const rounds: number[] = []; // the findings count of every critic-panel report, in order
  for (const l of lines) for (const e of mapper.pushLine(l)) {
    const review = e.type === "STATE_SNAPSHOT" ? (e.snapshot as { review?: { findings?: unknown[] } } | undefined)?.review : undefined;
    if (review) rounds.push(review.findings?.length ?? 0);
    view = reduce(view, e as never);
  }
  const out = { key, view, tally: tallyOf(lines), rounds };
  folds.set(journal, out);
  return out;
}

export async function readFleet(opts: { script: string; env: Record<string, string | undefined>; home: string; now: number; redact: (s: string) => string }): Promise<Fleet> {
  const census = await runScript(opts.script, opts.env);
  // the codex probe's cache, read once per request; unreadable, stale or reset is null.
  const ttl = Number(opts.env.CODEX_USAGE_CACHE_TTL_SECONDS);
  let codex: CodexBank | null = null;
  try {
    codex = readCodexBank(await readFile(opts.env.CODEX_USAGE_CACHE || join(opts.home, ".himmel", "cache", "codex-bank.json"), "utf8"), opts.now, ttl > 0 ? ttl : undefined);
  } catch { /* no probe cache: unmeasured */ }
  const banks = { codex };
  if (census.census === "unavailable") return { census: "unavailable", generatedAt: opts.now, sessions: [], edges: [], processOrphans: await processOrphansOf(opts), banks };
  const lockOf = (file: string, doc: string): Promise<FleetRow["lock"]> => {
    if (!RECORDED_LOCK.some((re) => re.test(doc))) return Promise.resolve("unknown");
    return new Promise((ok) => {
      // The lock owner resolves legacy keys and distinguishes free from corrupt or unreadable.
      execFile("bash", [join(dirname(opts.script), "../handover/queue-lock.sh"), "status", file],
        { env: opts.env as NodeJS.ProcessEnv, timeout: 3000, maxBuffer: 64 * 1024 }, (err, stdout) => {
          if (!err && stdout.trim() === "free") return ok("released");
          ok(/status: FRESH/.test(stdout) ? "held" : "unknown");
        });
    });
  };
  const edges = new Map<string, { console: string; at: number | undefined }>();
  for (const file of census.manifests ?? []) {
    const console = plain(basename(file, ".fleet.json"));
    if (!console) continue;
    try {
      const m = JSON.parse(await readFile(file, "utf8"));
      if (m.schema !== 1 || !Array.isArray(m.legs)) continue;
      for (const l of m.legs) if (typeof l.doc === "string") {
        const at = Date.parse(l.added);
        edges.set(l.doc, { console, at: Number.isFinite(at) ? at : undefined });
      }
    } catch { /* malformed or unreadable manifest: no edge */ }
  }
  const seen = new Set<string>();
  const rows = await Promise.all(census.sessions.map(async (c): Promise<FleetRow | null> => {
    let launch: Record<string, string> = {};
    try {
      const env = (await readFile(join(opts.env.CLAUDE_SESSIONS_PROC || "/proc", c.pid, "environ"), "utf8")).split("\0");
      launch = Object.fromEntries(env.filter((v) => v.includes("=")).map((v) => { const i = v.indexOf("="); return [v.slice(0, i), v.slice(i + 1)]; }));
    } catch { /* unavailable launch record: use doc or manifest */ }
    if (launch.CLAUDE_CONFIG_DIR) await registerConfigRoot(launch.CLAUDE_CONFIG_DIR);
    let argv: string[] = [];
    try { argv = (await readFile(join(opts.env.CLAUDE_SESSIONS_PROC || "/proc", c.pid, "cmdline"), "utf8")).split("\0"); } catch { /* unavailable: the name decides */ }
    let rec: { sessionId?: unknown; status?: unknown; name?: unknown; startedAt?: unknown } = {};
    const configs = launch.CLAUDE_CONFIG_DIR ? [launch.CLAUDE_CONFIG_DIR] : [join(opts.home, ".claude"), join(opts.home, ".claude-codex")];
    for (const config of configs) {
      try { rec = JSON.parse(await readFile(join(config, "sessions", `${c.pid}.json`), "utf8")); break; } catch { /* not yet written in this lane */ }
    }
    const run = typeof rec.sessionId === "string" ? rec.sessionId : null;
    const found = run ? await resolveJournal(opts.home, run) : null;
    const journal = found && "path" in found ? found.path : null;
    let view: View | null = null, tally: Tally | null = null, rounds: number[] = [];
    if (journal) {
      // Live if any of its files was written recently: a subagent can be busy while the main journal is quiet.
      const { paths } = await sessionFiles(journal);
      const mtimes = await Promise.all(paths.map((p) => stat(p).then((s) => s.mtimeMs, () => 0)));
      if (opts.now - Math.max(0, ...mtimes) > RECENT_MS && roleOf(c.name, c.doc) === "interactive") return null;
      // Only a listed session keeps its fold: a quiet one left off the page drops out of the cache below.
      seen.add(journal);
      ({ view, tally, rounds } = await fold(journal));
    }
    let doc = "", docAt = opts.now;
    if (c.doc) try { doc = await readFile(c.doc, "utf8"); docAt = (await stat(c.doc)).mtimeMs; } catch { /* moved or gone: no doc */ }
    // A session started without -n still has the name the harness gave it.
    const name = c.name || (typeof rec.name === "string" ? rec.name : "") || `pid ${c.pid}`;
    const role = roleOf(name, c.doc);
    // a chief's doc is its operating contract and names other lanes in prose: only its launch record says its lane
    const { lane, laneFrom } = laneOf(launch, role === "console" ? "" : doc);
    const backendModel = backendModelOf(lane, launch, c.model || null);
    const tools = view ? Object.values(view.tools).sort((a, b) => b.start - a.start) : [];
    const subs = view ? view.agentOrder.filter((id) => id !== "main") : [];
    const t0 = view?.t0;
    const ticket = /^([A-Z][A-Z0-9]+-\d+)\b/.exec(name)?.[1] ?? null;
    // A wrapped worker's window is closed: its codex price must not grow with later account usage (priced only while live).
    const ids = { session: run ?? `pid ${c.pid}`, leg: name, ticket, model: backendModel };
    const graph = graphOf(role, doc);
    // a chief is live only while its lock is held and wrapped only by its own wrap line once the lock is free (an
    // unreadable lock is neither); every other role's state is the last bullet's marker
    const lock = role === "console" ? await lockOf(c.doc, doc) : "unknown";
    const wrapped = role === "console" ? ownWrap(doc) && lock === "released" : c.status === "WRAPPED";
    const live = role === "console" ? lock === "held" : !wrapped;
    const status = role === "console" ? (wrapped ? "WRAPPED" : live && c.status !== "WRAPPED" ? c.status : "") : c.status;
    // Accepted succession in the doc overrides the original launch environment.
    const parent = role === "console" ? null : graph.parent ?? plain(launch.HIMMEL_CONSOLE_NAME) ?? edges.get(c.doc)?.console ?? null;
    return {
      run, pid: Number(c.pid), name, role, model: c.model || null,
      ticket, pr: role === "leg" ? prOf(doc) : null,
      state: role === "console" && !live && !wrapped ? "unknown" : stateOf(status, rec.status),
      activity: tools[0] && t0 !== undefined ? { tool: tools[0].name, summary: opts.redact(summarize(tools[0].args)).slice(0, 120), at: t0 + tools[0].start } : null,
      lastEventAt: view && t0 !== undefined ? t0 + view.elapsed : null,
      subagents: { total: subs.length, running: view ? subs.filter((id) => agentState(view!, id) === "running").length : 0 },
      failures: view?.failures.length ?? 0,
      ...graph, parent, console: role === "console" ? name : parent, live, lock, cadence: role === "interactive" ? cadenceOf(name, argv) : null,
      lane, laneFrom, backendModel, marker: status || null, lastSeenAt: c.doc && doc ? docAt : null, prUrl: null, bus: NO_BUS, description: "",
      agents: subs.map((id) => ({ name: opts.redact(view!.agents[id]?.name ?? id).slice(0, 80), role: view!.agents[id]?.role ?? "subagent", state: agentState(view!, id) })),
      usage: finish(tally, { autocompact: c.autocompact ?? "", model: c.model, window: launch.CLAUDE_CODE_MAX_CONTEXT_TOKENS, priced: lane === "native" }), cloud: null,
      cost: tally ? costRowOf({ ...ids, lane, tally, codexStart: codexStartOf(launch), codexNow: lane === "claudex" && !wrapped ? codex : null }) : null,
      eval: role === "leg" || role === "judge" ? evalRowOf({ ...ids, lane, rounds, view, doc }) : null,
      runtime: runtimeOf(rec.startedAt ?? c.startedAt, edges.get(c.doc)?.at ?? t0, doc, wrapped, opts.now, docAt),
    };
  }));
  // the rows that show a doc: only these get their description looked up
  const described: [FleetRow, string][] = [];
  census.sessions.forEach((c, i) => { const r = rows[i]; if (r && c.doc) described.push([r, c.doc]); });
  // The station keeps hundreds of archived chief docs, each read and lock-checked (a bash process): a bounded pool, never one at a time.
  const taken = new Set(rows.map((r) => r?.name));
  const archived: [string, string][] = [];
  for (const file of census.consoleDocs ?? []) {
    const name = plain(basename(file, ".md"));
    if (name && !taken.has(name)) archived.push([file, name]);
  }
  const built = await mapLimit(archived, CONSOLE_DOC_CONCURRENCY, async ([file, name]): Promise<FleetRow | null> => {
    try {
      const s = await stat(file);
      if (opts.now - s.mtimeMs > 72 * RECENT_MS) return null;
      const doc = await readFile(file, "utf8");
      const lock = await lockOf(file, doc);
      const wrapped = ownWrap(doc) && lock === "released";
      return {
        name, role: "console", pid: null, run: null, model: null, ticket: null, pr: null,
        state: wrapped ? "wrapped" : "unknown", activity: null, lastEventAt: null,
        subagents: { total: 0, running: 0 }, failures: 0, ...graphOf("console", doc),
        agents: [], usage: null, cloud: null, runtime: null, console: name, live: false,
        lock, cadence: null, lane: "native", laneFrom: null, backendModel: null, cost: null, eval: null,
        marker: wrapped ? "WRAPPED" : null, lastSeenAt: s.mtimeMs, prUrl: null, bus: NO_BUS, description: "",
      };
    } catch { return null; /* archived console moved or unreadable */ }
  });
  // the first readable doc of a name wins, in census order; an expired or unreadable one never hides a later one
  built.forEach((row, i) => { if (row && !taken.has(row.name)) { taken.add(row.name); rows.push(row); described.push([row, archived[i][0]]); } });
  const descOf = await describe(described.map(([, f]) => f), opts.script, opts.env);
  for (const [r, f] of described) {
    const text = descOf(f);
    // the stem is the doc's name, already shown unredacted; the redactor would mask a long stem as a token run
    r.description = text === basename(f, ".md") ? text : opts.redact(text);
  }
  const cloud = await cloudRows(census.cloudRoutes ?? [], opts.env, opts.now);
  // A local worker on a cloud session's ticket is its shepherd: it hangs under the cloud node, not the chief.
  for (const r of rows) {
    const c = r?.role === "leg" && cloud.find((x) => x.ticket === r.ticket);
    if (r && c && r.console === c.console) r.parent = c.name;
  }
  // Drop the folds of sessions that left the fleet, so the cache does not grow with every session ever seen.
  for (const journal of folds.keys()) if (!seen.has(journal)) folds.delete(journal);
  const sessions = [...rows.filter((r): r is FleetRow => r !== null), ...cloud];
  const slug = await repoSlugOf(join(dirname(opts.script), "../.."), opts.env);
  const bus = await busOf(busRootOf(opts.env, opts.home));
  for (const r of sessions) { r.prUrl = prUrlOf(slug, r.pr); r.bus = bus.of(r.name); }
  // orphan-loops.sh names an owner with every character outside [A-Za-z0-9_.-] turned into `_`
  const liveOwners = new Set(sessions.filter((r) => r.live && r.role !== "cloud").map((r) => r.name.replace(/[^A-Za-z0-9_.-]/g, "_")));
  return { census: census.census, generatedAt: opts.now, sessions, edges: bus.edges, processOrphans: await processOrphansOf(opts, liveOwners), banks };
}
