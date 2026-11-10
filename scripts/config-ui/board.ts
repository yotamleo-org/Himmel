// The Board page's two reads beside GET /api/roadmap, and the one run that replaces the saved drift file (refreshDrift, below): the saved status-drift summary (drift-summary.mjs) and the
// chain read (chain-state.mjs). The reads are READ ONLY: each is a chief-kit script that prints JSON and writes nothing, run with an explicit
// argument list and a small environment, and never started unless its input is found: named in the environment
// (HIMMEL_FOCUS_DRIFT, TRACKER_HANDOVERS_DIR, HIMMEL_CHAIN_REGISTRY) or, on a real launch, the newest file of that name under
// <HANDOVER_DIR>/<slug>/himmel/. A test therefore reaches only the paths it sets: with none of these nothing is spawned and
// the page shows both as absent, with the reason, never as a count.
import { execFile, execFileSync } from "node:child_process";
import { readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { runChild } from "./lock";
import { readRoadmap } from "./roadmap";
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

// What is owed to the operator beside the labels and the chain holds, read from the records that hold it: the same three sources as the roadmap
// tracker's reader (tracker.py operator_owed), so the two views agree. All READ ONLY.
//   1. an unsigned spec: the latest critic verdict of a spec of an open ticket of the running version is SPEC CLEAN, or the ticket's spec round
//      in the round ledger (chief-route.ts round-status) is at the cap, and <bucket>/release/<version>/operator.jsonl has no `spec` row naming
//      that spec file; and an open ticket whose ledger holds an operator-critical finding the operator has not ruled on, at any round;
//   2. a `queue:` segment or `pool-disposition:` line of the newest chief doc's `## Live state` that names the operator;
//   3. the newest *HANDOFF.md of the bucket, its `## Open operator items` lines.
// A source that cannot be read is named in `unread`; when none can be read the whole read is absent with the reasons, never an empty list.
// ponytail: the newest chief doc by mtime stands for "the live chief" and its folder for the bucket, upgrade path: the live chiefs' docs by queue lock as Shift reads them.
export type OwedItem = { source: "unsigned spec" | "operator-critical finding" | "chief doc" | "handoff" | "owed undelivered" | "unclosed worker"; key: string | null; title: string; ctx: string; act: string; label?: string; since?: number };
export type Owed = { state: "ok"; items: OwedItem[]; unread: string[]; skipped?: string[] } | Absent;
const OWED_SOURCES = 3; // unsigned specs, handoff items, chief doc lines
type RoundKey = { spec?: unknown; critical_open?: { id: string; class: string; kind: string; round: number; verdict_path: string }[]; error?: string };
type RoundStatus = { cap: number; classes: string[]; keys: Record<string, RoundKey> };
const ROUTE = resolve(import.meta.dir, "../telegram/chief-route.ts"), ROUND_LEDGER = "round ledger";
function roundStatusAll(bucket: string, env: Env): RoundStatus | undefined {
  try {
    const s = JSON.parse(execFileSync(process.execPath, [ROUTE, "round-status", "--all", "--specs", join(bucket, "specs"), "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: childEnv(env), timeout: TIMEOUT_MS }));
    return s && Number.isInteger(s.cap) && Array.isArray(s.classes) && s.classes.length && s.keys && typeof s.keys === "object" ? s : undefined;
  } catch { return undefined; }
}
const OWED_RE = /operator[ -](?:sign-?off|runs?|words|signs?|decides?|on Telegram|only)|Telegram ask|operator-owed/i;
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
// The lines under `## <heading>` up to the next `## `; undefined when the file has no such section.
function mdSection(text: string, heading: string): string[] | undefined {
  const out: string[] = [];
  let on = false, found = false;
  for (const l of text.split("\n")) {
    if (l.startsWith("## ")) { if (on) break; on = l.slice(3).trim() === heading; found ||= on; } else if (on) out.push(l);
  }
  return found ? out : undefined;
}
const readText = (p: string) => readFileSync(p, "utf8");
const utf8 = (p: string) => new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(p)); // throws on bytes that are not UTF-8
// A record and a file name one spec through any symlink or `..`, with or without one trailing `.md`.
// A file that is not there still resolves through a symlinked folder, as Python's realpath does.
const specId = (p: string) => {
  let r: string;
  try { r = realpathSync(p); } catch { try { r = join(realpathSync(dirname(p)), basename(p)); } catch { r = resolve(p); } }
  return r.replace(/\.md$/, "");
};
// `skipped` takes the critic files of single specs that could not be read: the rest of the list still stands.
function specItems(bucket: string, version: string, open: Map<string, string>, skipped: string[], unread: string[], env: Env): OwedItem[] {
  const signed = new Set<string>();
  let ledger = "";
  try { ledger = readText(join(bucket, "release", version, "operator.jsonl")); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; } // a release with no record yet has signed nothing
  for (const l of ledger.split("\n")) {
    try { const r = JSON.parse(l); if (r && r.kind === "spec" && typeof r.spec_path === "string") signed.add(specId(r.spec_path)); } catch { /* a torn or blank line holds no record */ }
  }
  const dir = join(bucket, "specs", "designs"), latest = new Map<string, { n: number; f: string }>();
  for (const f of readdirSync(dir)) {
    const m = f.match(/^(.*)\.critic-spec-r(\d+)\.md$/);
    if (m && (!latest.has(m[1]) || Number(m[2]) > latest.get(m[1])!.n)) latest.set(m[1], { n: Number(m[2]), f });
  }
  const status = roundStatusAll(bucket, env), items: OwedItem[] = [];
  if (!status) unread.push(ROUND_LEDGER);
  for (const [spec, { f }] of [...latest].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
    const key = spec.match(/[A-Z][A-Z0-9]*-\d+/)?.[0];
    const st = status && key ? status.keys[key] : undefined;
    if (!status || st?.error !== undefined) { skipped.push(f); continue; }
    const n = Number.isInteger(st?.spec) ? Number(st!.spec) : 0;
    let last: string | undefined;
    try { last = utf8(join(dir, f)).split("\n").map((x) => x.trim()).filter(Boolean).pop(); } catch { /* named below */ }
    if (last === undefined) { skipped.push(f); continue; } // an empty, unreadable or non-UTF-8 critic file skips that one spec, and says so
    if (!key || !open.has(key) || signed.has(specId(join(dir, spec))) || !(last === "SPEC CLEAN" || n >= status.cap)) continue;
    items.push({ source: "unsigned spec", key, title: open.get(key)!, act: "sign the spec, or rule on its findings",
      ctx: `${spec}: latest critic round ${n} reads ${/^SPEC (?:CLEAN|FINDINGS \d+)$/.test(last) ? last : "no verdict line"}, no spec row in operator.jsonl` });
  }
  for (const [key, st] of Object.entries(status?.keys ?? {}).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
    if (!open.has(key) || !Array.isArray(st.critical_open) || !st.critical_open.length) continue;
    items.push({ source: "operator-critical finding", key, title: open.get(key)!, act: "rule on each finding; the chief records the ruling with chief-route.ts round-critical",
      ctx: st.critical_open.map((c) => `${c.id} (${c.class}) in ${c.kind} round ${c.round}, ${basename(String(c.verdict_path))}`).join("; ") });
  }
  return items;
}
function handoffItems(bucket: string): OwedItem[] | undefined {
  let best: { f: string; t: number } | undefined;
  for (const f of readdirSync(bucket)) {
    if (!f.endsWith("HANDOFF.md")) continue;
    const t = statSync(join(bucket, f)).mtimeMs;
    if (!best || t > best.t) best = { f, t };
  }
  const sec = best ? mdSection(readText(join(bucket, best.f)), "Open operator items") : undefined;
  return sec?.map((l) => l.trim()).filter((l) => l && !/^[-*\s]*none\.?$/i.test(l))
    .map((l) => ({ source: "handoff" as const, key: null, title: clip(l.replace(/^[-*]\s+/, ""), 140), ctx: best!.f, act: "answer the open item" }));
}
function chiefDocItems(doc: string, open: Map<string, string>): OwedItem[] | undefined {
  const live = mdSection(readText(doc), "Live state");
  if (!live) return undefined;
  const items: OwedItem[] = [];
  for (const l of live) {
    // what follows " || " on a queue line is history, not live
    const segs = l.startsWith("queue:") ? l.slice(6).split(" || ")[0].split(" | ") : l.startsWith("pool-disposition:") ? [l.slice(17)] : [];
    for (const s of segs.map((x) => x.trim()).filter((x) => OWED_RE.test(x))) {
      const key = s.match(/[A-Z][A-Z0-9]*-\d+/)?.[0];
      const known = !!key && open.has(key);
      items.push({ source: "chief doc", key: known ? key! : null, title: known ? open.get(key!)! : clip(s, 140), ctx: known ? clip(s, 160) : "from the chief doc's Live state", act: "the operator acts on what the line names" });
    }
  }
  return items;
}
function undeliveredItems(doc: string, open: Map<string, string>): OwedItem[] {
  const lines = readText(doc).split("\n");
  const items: OwedItem[] = [], seen = new Set<string>();
  for (const l of lines) {
    const m = l.match(/^- (?:\d{1,2}:\d{2} )?OWED ([A-Za-z0-9_.-]+)(?: (.*))?$/);
    if (!m || seen.has(m[1])) continue;
    seen.add(m[1]);
    if (lines.some((x) => new RegExp(`^- (?:\\d{1,2}:\\d{2} )?DELIVERED ${m[1].replace(/[.]/g, "\\.")} msg=\\d+ chat=-?\\d+(?: .*)?$`).test(x))) continue;
    const key = /^[A-Z][A-Z0-9]*-\d+$/.test(m[1]) && open.has(m[1]) ? m[1] : null;
    items.push({ source: "owed undelivered", key, title: key ? open.get(key)! : clip(`${m[1]}: ${m[2] ?? ""}`.replace(/: $/, ""), 140),
      ctx: `${key ? `${clip(m[2] ?? m[1], 120)}: ` : ""}OWED ${m[1]} has no DELIVERED receipt in ${basename(doc)}`, act: `the chief sends it with chief-route.ts reply --owed ${m[1]}` });
  }
  return items;
}
const HELD_OVER_A_TICK_S = 30;
const heldOverATick = (recordWrittenAt: number, firstSeen: number) => recordWrittenAt - firstSeen >= HELD_OVER_A_TICK_S;
function unclosedItems(doc: string, env: Env): OwedItem[] {
  const file = join(env.TICK_STATE_DIR ?? join(env.HOME ?? "", ".himmel", "state"), `tick-unclosed-${basename(doc, ".md")}`);
  let rec: string, wrote: number;
  try { rec = readText(file); wrote = statSync(file).mtimeMs / 1000; } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw e;
  }
  const text = readText(doc);
  const items: OwedItem[] = [];
  for (const l of rec.split("\n")) {
    const [label, first, base] = l.trim().split(/\s+/);
    if (!label || !/^\d+$/.test(first ?? "") || !heldOverATick(wrote, Number(first))) continue;
    const disp = new RegExp(`^- (?:\\d{1,2}:\\d{2} )?(?:\\*\\*)?DISPOSITION ${label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} (?:closed(?:[^A-Za-z]|$)|parked [^ \\n]|given-up [^ \\n])`, "gm");
    if ((text.match(disp)?.length ?? 0) > (/^\d+$/.test(base ?? "") ? Number(base) : 0)) continue;
    items.push({ source: "unclosed worker", key: null, label, since: Number(first), title: `${label} is finished and its window is still open`,
      ctx: `the tick has held it open since it was first seen, and ${basename(doc)} has no DISPOSITION bullet for it`,
      act: `the chief closes it, or records DISPOSITION ${label} closed, parked <wake> or given-up <reason>` });
  }
  return items;
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
export function readOwed(env: Env, read: typeof readRoadmap = readRoadmap): Owed {
  const mirror = jiraMirrorDir(env), proj = env.JIRA_PROJECT_KEY || "HIMMEL";
  const doc = newestChiefDoc(env), bucket = env.HIMMEL_BUCKET_DIR || (doc ? dirname(doc) : undefined);
  const items: OwedItem[] = [], unread: string[] = [], why: string[] = [], skipped: string[] = [];
  const miss = (what: string, reason: string) => { unread.push(what); why.push(`${what}: ${reason}`); };
  let running: string | undefined;
  const open = new Map<string, string>(); // the open tickets of the running version: id to title
  try {
    const r = read({ mirrorDir: mirror, projects: [{ key: proj, dir: mirror }], workers: { state: "absent" } });
    running = r.versions[r.cur]?.n.replace(new RegExp(` \\(${proj}\\)$`), "");
    for (const t of r.tickets) if (t.v === r.cur && (t.b === "todo" || t.b === "prog" || t.b === "rev" || t.b === "ci")) open.set(t.id ?? `${proj}-${t.k}`, t.t);
  } catch (e) { why.push(`the open tickets could not be read: ${(e as Error).message}`); }
  const tryRead = (what: string, f: () => OwedItem[] | undefined, none: string) => {
    try { const got = f(); if (got) items.push(...got); else miss(what, none); } catch (e) { miss(what, (e as Error).message); }
  };
  if (!bucket) { miss("unsigned specs", "no bucket: no chief doc under the handover root, and HIMMEL_BUCKET_DIR is not set"); miss("handoff items", "no bucket"); }
  else {
    if (!running) miss("unsigned specs", "no running version");
    else tryRead("unsigned specs", () => specItems(bucket, running!, open, skipped, unread, env), "none");
    tryRead("handoff items", () => handoffItems(bucket), `no Open operator items section in the newest HANDOFF under ${bucket}`);
  }
  if (!doc) miss("chief doc lines", "no chief doc: none found under the handover root, and HIMMEL_CHIEF_DOC is not set");
  else tryRead("chief doc lines", () => {
    const live = chiefDocItems(doc, open), more = [...undeliveredItems(doc, open), ...unclosedItems(doc, env)];
    if (live === undefined) miss("chief doc lines", "the chief doc has no Live state section");
    return [...(live ?? []), ...more];
  }, "");
  return unread.filter((u) => u !== ROUND_LEDGER).length >= OWED_SOURCES ? absent(why.join("; ")) : { state: "ok", items, unread, skipped };
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
    return { drift: await drift, chains: none, versionChains: none, prs: readPrs(env), owed: readOwed(env, read) };
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
