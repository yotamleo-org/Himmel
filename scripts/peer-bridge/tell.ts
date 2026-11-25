// tell.ts <peer> --kind status|info --text '...'   |   tell.ts <peer> --status <draft>
// Exit: 0 drafted or a status line, 2 refused (names the rule), 3 refused before
// any check of the text, 4 queued but unconfirmed: do not resend.
import fs from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { codeState, readChain, submitSpool } from "./chain";
import { readPeersFile, type Config } from "./config";
import { badChars, draftState } from "./drafts";
import { checkOutbound } from "./egress";
import { PEER_NAME_RE, SESSION_ID_RE } from "./ids";
import { procHooks, runProc } from "./proc";
import { Threads, type ThreadRec } from "./threads";

export type Result = { code: number; line: string };
export type Opts = { matrix?: { default: string; rules: unknown[] }; now?: number; maxTranscriptBytes?: number };

const KINDS = ["status", "info"];
const MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024;
const SHOWN_WITHIN_MS = 60_000;
const DRAFT_RE = /^[0-9a-f]{8}$/;
const R = (code: number, line: string): Result => ({ code, line });
const NOT_SET_UP = R(3, "peer bridge is not set up");
const LAUNCH_UNKNOWN = R(3, "refused: launch-root-unknown: this session's transcript cannot be found or proven");
const PHI = R(3, "refused: phi-root: this session's transcript names a salus or PHI path, or could not be read whole");
const PHI_MARKED = R(3, "refused: phi-root: this session touched a path under a salus or PHI root (phi-read-mark.sh)");

export const slugOf = (p: string): string => p.replace(/[^A-Za-z0-9]/g, "-");
const hhmm = (ms: number) => { const d = new Date(ms); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };

type Args = { peer: string; kind?: string; text?: string; status?: string };
function parseArgs(argv: string[]): Args | null {
  const a: Args = { peer: argv[0] ?? "" };
  for (let i = 1; i < argv.length; i += 2) {
    const v = argv[i + 1];
    if (v === undefined) return null;
    if (argv[i] === "--kind" && a.kind === undefined) a.kind = v;
    else if (argv[i] === "--text" && a.text === undefined) a.text = v;
    else if (argv[i] === "--status" && a.status === undefined) a.status = v;
    else return null;
  }
  if (a.status !== undefined && (a.kind !== undefined || a.text !== undefined)) return null;
  return a;
}

function restricted(S: string, sid: string, env: Record<string, string | undefined>): boolean {
  if (env.PEER_DESK) return true;
  const dir = join(S, "taint");
  if (!fs.existsSync(dir)) return false;
  try { return fs.readdirSync(dir).some(n => n === sid || n.startsWith(`${sid}.pending.`)); } catch { return true; }
}

function phiMarked(home: string, sid: string): boolean {
  try { fs.statSync(join(home, ".himmel", "phi-taint", sid)); return true; }
  catch (e) { return (e as NodeJS.ErrnoException).code !== "ENOENT"; }
}

type Found = { slug: string; dir: string; file: string };
function findTranscript(home: string, sid: string, env: Record<string, string | undefined>): Found | null {
  let cfgDirs: string[];
  if (env.CLAUDE_CONFIG_DIR) cfgDirs = [env.CLAUDE_CONFIG_DIR];
  else { try { cfgDirs = fs.readdirSync(home).filter(n => n.startsWith(".claude")).map(n => join(home, n)); } catch { return null; } }
  const found: Found[] = [];
  for (const cfg of cfgDirs) {
    let slugs: string[];
    try { slugs = fs.readdirSync(join(cfg, "projects")); } catch { continue; }
    for (const slug of slugs) {
      const file = join(cfg, "projects", slug, `${sid}.jsonl`);
      if (fs.existsSync(file)) found.push({ slug, dir: join(cfg, "projects", slug), file });
    }
  }
  return found.length === 1 ? found[0] : null;
}

function records(file: string): Record<string, any>[] | null {
  let text: string;
  try { text = fs.readFileSync(file, "utf8"); } catch { return null; }
  const lines = text.split("\n");
  const last = lines.pop()!;
  const out: Record<string, any>[] = [];
  for (const l of lines) {
    if (l === "") continue;
    try { const r = JSON.parse(l); if (r && typeof r === "object") out.push(r); } catch { return null; }
  }
  try { const r = JSON.parse(last); if (r && typeof r === "object") out.push(r); } catch {}
  return out;
}

const TOKEN_RE = /(?:^|[\s'"`=:(;|&<>])((?:\/|~\/)[^\s'"`;|&<>()]+)/g;
const QUOTED_RE = /'((?:\/|~\/)[^']*)'|"((?:\/|~\/)[^"]*)"/g;
function pathsOf(r: Record<string, any>, home: string, add: (p: string) => void): boolean {
  const abs = (p: string, base?: string) => (p.startsWith("~/") ? join(home, p.slice(2)) : isAbsolute(p) ? p : base && isAbsolute(base) ? resolve(base, p) : null);
  const put = (p: unknown, base?: string) => { if (typeof p === "string" && p !== "") { const a = abs(p, base); if (a) add(a); } };
  put(r.cwd);
  const content = r.message?.content;
  if (!Array.isArray(content)) return true;
  for (const item of content) {
    if (!item || item.type !== "tool_use" || !item.input || typeof item.input !== "object") continue;
    const input = item.input;
    for (const k of ["file_path", "path", "notebook_path"]) put(input[k], r.cwd);
    if (typeof input.pattern === "string" && (item.name === "Glob" || input.pattern.startsWith("/") || input.pattern.startsWith("~/"))) put(input.pattern.split(/[*?[{]/)[0], typeof input.path === "string" && input.path !== "" ? abs(input.path, r.cwd) ?? undefined : r.cwd);
    if ((item.name === "Bash" || item.name === "Monitor") && typeof input.command === "string") {
      if (/\\[ \t]/.test(input.command)) return false;
      for (const m of input.command.matchAll(TOKEN_RE)) put(m[1]);
      for (const m of input.command.matchAll(QUOTED_RE)) put(m[1] ?? m[2]);
      relativeWords(input.command, r.cwd, home, put);
    }
  }
  return true;
}

const WORD_RE = /'([^']*)'|"([^"]*)"|([^\s'"`;|&<>()]+)/g;
function relativeWords(command: string, cwd: unknown, home: string, put: (p: unknown, base?: string) => void): void {
  let dir = typeof cwd === "string" && isAbsolute(cwd) ? cwd : null, prev = "";
  for (const m of command.matchAll(WORD_RE)) {
    const word = m[1] ?? m[2] ?? m[3];
    if (prev === "cd" && word.startsWith("-") && word !== "-") continue;
    if (prev === "cd" && dir !== null && word !== "-") {
      dir = word.startsWith("~/") ? join(home, word.slice(2)) : word === "~" ? home : resolve(dir, word);
      put(dir);
    } else if (dir !== null && word !== "" && !word.startsWith("-") && !word.startsWith("~") && !isAbsolute(word)) put(word, dir);
    prev = word;
  }
}

const MARKERS = [".salus", ".salus-profile"];
const FIND_DEPTH = "6", FIND_TIMEOUT_MS = 10_000, FIND_BUDGET_MS = 60_000;
function markerBelow(dirs: string[]): boolean {
  const until = Date.now() + FIND_BUDGET_MS;
  for (const d of dirs) {
    if (Date.now() > until) return true;
    const r = procHooks.spawnSync("find", [d, "-maxdepth", FIND_DEPTH, "(", "-name", MARKERS[0], "-o", "-name", MARKERS[1], ")", "-print", "-quit"], { encoding: "utf8", timeout: FIND_TIMEOUT_MS });
    if (r.error || r.status !== 0 || (r.stdout ?? "").trim() !== "") return true;
  }
  return false;
}

function canon(p: string): string {
  let d = p;
  const tail: string[] = [];
  while (!fs.existsSync(d)) {
    const up = dirname(d);
    if (up === d) return p;
    tail.unshift(basename(d));
    d = up;
  }
  try { return join(fs.realpathSync(d), ...tail); } catch { return p; }
}

function salusMarked(p: string, cache: Map<string, boolean>): boolean {
  let d = p;
  for (;;) {
    let hit = cache.get(d);
    if (hit === undefined) { hit = MARKERS.some(m => fs.existsSync(join(d, m))); cache.set(d, hit); }
    if (hit) return true;
    const up = dirname(d);
    if (up === d) return false;
    d = up;
  }
}

const PHI_SCRIPT = `. "$1/scripts/guardrails/phi-egress-lib.sh" || exit 9
while IFS= read -r -d '' p; do rc=0; _guard_phi_decision "$p" || rc=$?; printf '%s\\n' "$rc"; done`;
async function phiListed(paths: string[], himmelRoot: string, env: Record<string, string | undefined>, home: string): Promise<boolean> {
  if (!isAbsolute(himmelRoot) || !fs.existsSync(join(himmelRoot, "scripts/guardrails/phi-egress-lib.sh"))) return true;
  const run = await runProc(["bash", "-c", PHI_SCRIPT, "tell-phi", himmelRoot], {
    input: paths.join("\0") + "\0", timeoutMs: 60_000, maxBytes: 1 << 20,
    env: { PATH: env.PATH ?? "/usr/bin:/bin", HOME: home, ...(env.CLAUDE_GLM_CONFIG_DIR ? { CLAUDE_GLM_CONFIG_DIR: env.CLAUDE_GLM_CONFIG_DIR } : {}) },
  });
  if (run.timedOut || run.code !== 0) return true;
  const rcs = run.stdout.split("\n").filter(Boolean);
  return rcs.length !== paths.length || rcs.some(rc => rc !== "0" && rc !== "3");
}

async function scan(home: string, sid: string, env: Record<string, string | undefined>, himmelRoot: string, maxBytes: number): Promise<Result | null> {
  const t = findTranscript(home, sid, env);
  if (!t) return LAUNCH_UNKNOWN;
  const files = [t.file];
  const subs = join(t.dir, sid, "subagents");
  try { for (const n of fs.readdirSync(subs).sort()) if (n.endsWith(".jsonl")) files.push(join(subs, n)); }
  catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") return PHI; }
  let total = 0;
  for (const f of files) { try { total += fs.statSync(f).size; } catch { return PHI; } }
  if (total > maxBytes) return PHI;
  const all: Record<string, any>[][] = [];
  for (const f of files) { const recs = records(f); if (!recs) return PHI; all.push(recs); }
  const launch = all[0].find(r => typeof r.cwd === "string")?.cwd;
  if (typeof launch !== "string" || slugOf(launch) !== t.slug) return LAUNCH_UNKNOWN;
  const seen = new Set<string>();
  for (const recs of all) for (const r of recs) if (!pathsOf(r, home, p => { seen.add(p); seen.add(canon(p)); })) return PHI;
  const cache = new Map<string, boolean>();
  for (const p of seen) if (salusMarked(p, cache)) return PHI;
  const dirs = [...seen].filter(p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } });
  if (markerBelow([...new Set(dirs)])) return PHI;
  return (await phiListed([...seen], himmelRoot, env, home)) ? PHI : null;
}

function usage(peerDir: string, peer: string, cfg: Config, now: number) {
  const threads = Threads.load(readChain(join(peerDir, "threads.jsonl")).filter(r => r.kind === "thread") as unknown as ThreadRec[], { peers: cfg.peers, clock: () => now });
  const recent = readChain(join(peerDir, "outbox.jsonl")).filter(r => r.kind === "sent" && now - r.ts * 1000 < 60_000).length;
  return { openOutbound: threads.openOutbound(peer), sentLastMinute: recent };
}

function status(S: string, peerDir: string, id: string, now: number): Result {
  const outbox = readChain(join(peerDir, "outbox.jsonl")) as Record<string, any>[];
  const d = outbox.find(r => r.kind === "draft" && r.id === id && r.source === "chief");
  if (!d) return R(2, "refused: unknown-draft");
  const state = draftState(outbox, id);
  if (state !== "PENDING") return R(0, `${id} ${state}`);
  const sentDir = join(S, "notify", "sent");
  let shown = false;
  try {
    for (const n of fs.readdirSync(sentDir)) {
      try { const e = JSON.parse(fs.readFileSync(join(sentDir, n), "utf8")); if (e?.type === "draft" && e.draft === id) { shown = true; break; } } catch {}
    }
  } catch {}
  if (shown) return R(0, `${id} PENDING shown`);
  return R(0, now - d.ts * 1000 > SHOWN_WITHIN_MS ? `${id} PENDING review-not-shown` : `${id} PENDING`);
}

export async function run(argv: string[], env: Record<string, string | undefined>, opts: Opts = {}): Promise<Result> {
  const now = () => opts.now ?? Date.now();
  const sid = env.CLAUDE_CODE_SESSION_ID ?? "";
  if (!SESSION_ID_RE.test(sid)) return R(3, "refused: no-session: tell.ts runs only inside a Claude session");
  const home = env.HOME || homedir();
  const S = join(home, ".himmel", "peer-bridge"), C = join(home, ".config", "himmel", "peer-bridge");
  if (restricted(S, sid, env)) return R(3, "refused: tell.ts never runs in a peer desk or a session that read peer text");
  if (phiMarked(home, sid)) return PHI_MARKED;
  const a = parseArgs(argv);
  if (!a) return R(2, "refused: unknown or malformed argument");
  let cfg: Config;
  try { cfg = readPeersFile(join(C, "peers.json")); } catch { return NOT_SET_UP; }
  const peerOk = PEER_NAME_RE.test(a.peer) && Object.hasOwn(cfg.peers, a.peer);
  const peerDir = join(S, a.peer);

  if (a.status !== undefined) {
    if (!DRAFT_RE.test(a.status)) return R(2, "refused: bad-draft-id");
    if (!peerOk) return R(2, "refused: unknown-peer");
    return status(S, peerDir, a.status, now());
  }

  const scanned = await scan(home, sid, env, cfg.himmelRoot, opts.maxTranscriptBytes ?? MAX_TRANSCRIPT_BYTES);
  if (scanned) return scanned;
  if (!peerOk) return R(2, "refused: unknown-peer");
  if (!fs.existsSync(join(peerDir, "spool"))) return R(3, "peer bridge is not set up for this peer");
  if (codeState(join(S, "poller.pid")) !== "fresh") return R(3, "refused: poller-stale: the peer poller runs older or unknown peer-bridge code; restart himmel-peer-bridge, nothing was queued");
  if (codeState(join(S, "notify", "bot.code")) !== "fresh") return R(3, "refused: operator-bot-stale: the operator bot runs older or unknown peer-bridge code and could not show the review; restart it, nothing was queued");
  if (!a.kind || !KINDS.includes(a.kind)) return R(2, "refused: unknown-kind");
  if (!a.text) return R(2, "refused: empty");
  if (/[\r\n]/.test(a.text) || badChars(a.text)) return R(2, "refused: characters");

  const res = await checkOutbound(a.text, {
    peer: cfg.peers[a.peer], kind: a.kind, isRoot: true, isTemplate: false, tainted: true, tty: false, claudecode: true,
    himmelRoot: cfg.himmelRoot, maxTextChars: cfg.maxTextChars, corpus: "chief-tell", matrix: opts.matrix, usage: usage(peerDir, a.peer, cfg, now()),
  });
  if (!res.ok) return R(2, `refused: ${res.rule}${res.shape ? ` (${res.shape})` : ""}`);

  const name = submitSpool(peerDir, { type: "draft", source: "chief", kind: a.kind as "status" | "info", text: a.text, session: sid });
  const resultFile = join(peerDir, "spool", "results", name);
  const waitMs = Number(env.PEER_SEND_WAIT_MS ?? 10_000);
  const deadline = Date.now() + (Number.isFinite(waitMs) && waitMs >= 0 ? waitMs : 10_000);
  while (Date.now() < deadline) {
    try {
      const r = JSON.parse(fs.readFileSync(resultFile, "utf8"));
      fs.rmSync(resultFile, { force: true });
      if (r.ok) return R(0, `drafted ${r.draft}; approve it on Telegram by ${hhmm(r.deadline)}`);
      return R(2, `refused: ${r.rule}${r.shape ? ` (${r.shape})` : ""}${r.why ? `: ${r.why}` : ""}`);
    } catch (e) { if (!(e instanceof SyntaxError) && (e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    await new Promise(r => setTimeout(r, 100));
  }
  return R(4, `queued as ${name}; the poller will draft it; do not resend`);
}

if (import.meta.main) {
  run(process.argv.slice(2), process.env).then(r => {
    (r.code === 0 ? process.stdout : process.stderr).write(r.line + "\n");
    process.exit(r.code);
  });
}
