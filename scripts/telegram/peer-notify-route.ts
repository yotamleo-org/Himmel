import { randomBytes } from "node:crypto";
import fs from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { CODE_VERSION, readChain, signTap, startIdentity, submitSpool, verifyChain } from "../peer-bridge/chain";
import { readPeersFile } from "../peer-bridge/config";
import { PEER_NAME_RE, configDir, peersFile, stateDir } from "../peer-bridge/ids";
import { NOTIFY_LINE1_RE, notifyFile, renderChainAlert, renderFallback, renderHeld, renderNotify, type NotifyRec } from "../peer-bridge/notify";
import { atomicWrite } from "./bus";
import { operatorChatId, type Access } from "./gate";
import { lockdownEnabled } from "./lockdown";
import type { SendOpts, SendResult } from "./telegram-api";

export const POLL_FRESH_MS = 60_000;
export const CONFLICT_HOLD_MS = 10 * 60_000;
export const HELD_LINE_AFTER_MS = 10 * 60_000;
export const SENT_PRUNE_MS = 7 * 86_400_000;

export type ProcInfo = { pid: number; ownPoller: true | false | "unknown"; botIds: string[] };
export type PeersCfg = { operatorChatId: number | null; operatorBotId: string };
type Send = (token: string, chat: number, text: string, opts: SendOpts) => Promise<SendResult>;
export type FlusherDeps = {
  stateDir: string; himmelRoot: string; token: string;
  access(): Access | null; peersCfg(): PeersCfg | null;
  send: Send; procs(): ProcInfo[]; botPids(): number[];
  clock(): number; log(line: string): void;
};

const notifyDir = (S: string) => join(S, "notify");
export const cursorFile = (S: string) => join(notifyDir(S), "cursor");
export const sentDir = (S: string) => join(notifyDir(S), "sent");

export function readCursor(S: string): { n: number; h: string } {
  try {
    const c = JSON.parse(fs.readFileSync(cursorFile(S), "utf8"));
    if (Number.isSafeInteger(c.n) && c.n >= 0 && typeof c.h === "string") return { n: c.n, h: c.h };
  } catch {}
  return { n: 0, h: "" };
}

export function readSent(S: string, messageId: number): Record<string, unknown> | null {
  if (!Number.isSafeInteger(messageId) || messageId <= 0) return null;
  try { return JSON.parse(fs.readFileSync(join(sentDir(S), String(messageId)), "utf8")); } catch { return null; }
}

function keyboard(k: { peer: string; draft: string }) {
  return { inline_keyboard: [[{ text: "Approve", callback_data: `peer:ok:${k.peer}:${k.draft}` }, { text: "Reject", callback_data: `peer:no:${k.peer}:${k.draft}` }]] };
}

export function holdingProc(procs: ProcInfo[], botPids: number[], operatorBotId: string): boolean {
  return procs.some(p => {
    if (p.ownPoller === false) return false;
    if (p.ownPoller === "unknown") return botPids.includes(p.pid);
    const ids = new Set(p.botIds);
    return ids.size !== 1 || ids.has(operatorBotId);
  });
}

export function makePeerNotifyFlusher(deps: FlusherDeps) {
  const S = deps.stateDir;
  let lastGoodPoll: number | null = null, lastConflict: number | null = null;
  let heldSince: number | null = null, heldLineSent = false, stopped = false, mismatchLogged = false;

  function holdReason(): string | null {
    const now = deps.clock();
    if (lastConflict !== null && now - lastConflict < CONFLICT_HOLD_MS) return "409";
    if (lastGoodPoll === null || now - lastGoodPoll > POLL_FRESH_MS) return "stale-poll";
    const cfg = deps.peersCfg();
    if (cfg && holdingProc(deps.procs(), deps.botPids(), cfg.operatorBotId)) return "plugin-poller";
    return null;
  }

  function notePoll(ok: boolean, code?: number): void {
    if (ok) lastGoodPoll = deps.clock();
    else if (code === 409) lastConflict = deps.clock();
  }

  async function writeSent(messageId: number, rec: NotifyRec & { n: number }): Promise<void> {
    fs.mkdirSync(sentDir(S), { recursive: true, mode: 0o700 });
    const r = rec as any;
    await atomicWrite(join(sentDir(S), String(messageId)), JSON.stringify({ n: rec.n, type: rec.type, peer: rec.peer, ...(r.root !== undefined ? { root: r.root } : {}), ...(r.dir ? { dir: r.dir } : {}), ...(r.draft ? { draft: r.draft } : {}), ts: deps.clock() }));
  }

  function prune(): void {
    let names: string[];
    try { names = fs.readdirSync(sentDir(S)); } catch { return; }
    const now = deps.clock();
    for (const name of names) {
      const e = readSent(S, Number(name));
      if (!e || typeof e.ts !== "number" || now - e.ts > SENT_PRUNE_MS) fs.rmSync(join(sentDir(S), name), { force: true });
    }
  }

  async function flush(): Promise<void> {
    if (stopped) return;
    const cfg = deps.peersCfg();
    const chat = operatorChatId(deps.access());
    const botId = deps.token.split(":")[0];
    if (!cfg || chat === null || cfg.operatorChatId !== chat || cfg.operatorBotId !== botId) {
      if (!mismatchLogged) { deps.log("peer-notify: peers.json operator chat or bot differs from the bridge's; sending nothing"); mismatchLogged = true; }
      return;
    }
    mismatchLogged = false;
    const reason = holdReason();
    if (reason) {
      const now = deps.clock();
      heldSince ??= now;
      if (!heldLineSent && now - heldSince >= HELD_LINE_AFTER_MS) {
        heldLineSent = true;
        await deps.send(deps.token, chat, renderHeld(heldSince, reason), { noPreview: true });
      }
      return;
    }
    heldSince = null; heldLineSent = false;
    const file = notifyFile(S);
    const cursor = readCursor(S);
    const check = verifyChain(file, cursor);
    if (!check.ok) {
      stopped = true;
      deps.log(`peer-notify: chain failed verification at #${check.n + 1}`);
      await deps.send(deps.token, chat, renderChainAlert(check.n + 1), { noPreview: true });
      return;
    }
    for (const rec of readChain(file).slice(cursor.n, check.n) as unknown as (NotifyRec & { n: number; h: string })[]) {
      let rendered: ReturnType<typeof renderNotify> | null = null;
      try { rendered = renderNotify(rec, deps.himmelRoot); } catch { deps.log(`peer-notify: #${rec.n} does not render; skipped`); }
      if (rendered) {
        const res = await deps.send(deps.token, chat, rendered.text, { noPreview: true, ...(rendered.keyboard ? { replyMarkup: keyboard(rendered.keyboard) } : {}) });
        if (res.ok) await writeSent(res.messageId, rec);
        else if (res.kind === "transient" || res.kind === "not-sent") { deps.log(`peer-notify: #${rec.n} not sent (${res.code ?? res.kind}); retry next tick`); return; }
        else if (res.kind === "permanent") {
          deps.log(`peer-notify: #${rec.n} refused by Telegram ${res.code}`);
          await deps.send(deps.token, chat, renderFallback(rec.n, res.code ?? 0), { noPreview: true });
        } else deps.log(`peer-notify: #${rec.n} may have been sent`);
      }
      await atomicWrite(cursorFile(S), JSON.stringify({ n: rec.n, h: rec.h }));
    }
    prune();
  }

  return { flush, notePoll, holdReason };
}

export const botCodeFile = (S: string) => join(notifyDir(S), "bot.code");

export function writeBotCode(S: string, token: string, operatorBotId: string): boolean {
  if (token.split(":")[0] !== operatorBotId) return false;
  fs.mkdirSync(notifyDir(S), { recursive: true, mode: 0o700 });
  const path = botCodeFile(S), tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  const fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, start: startIdentity(process.pid), code: CODE_VERSION })); } finally { fs.closeSync(fd); }
  try { fs.renameSync(tmp, path); } catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
  return true;
}

export function startPeerNotify(d: { token: string; access(): Access | null; send: Send; log(line: string): void }): ReturnType<typeof makePeerNotifyFlusher> | null {
  const file = peersFile();
  if (!fs.existsSync(file)) return null;
  let cfg: PeersCfg | null = null, himmelRoot = "";
  try {
    const c = readPeersFile(file);
    cfg = { operatorChatId: c.operatorChatId, operatorBotId: c.operatorBotId };
    himmelRoot = c.himmelRoot;
    try { writeBotCode(stateDir(), d.token, c.operatorBotId); } catch (e) { d.log(`peer-notify: cannot write the code stamp: ${(e as Error).message}`); }
  } catch (e) { d.log(`peer-notify: ${(e as Error).message}`); }
  return makePeerNotifyFlusher({ stateDir: stateDir(), himmelRoot, token: d.token, access: d.access, peersCfg: () => cfg, send: d.send, procs: readProcs, botPids: () => readBotPids(), clock: Date.now, log: d.log });
}

export const DRAFTING_LINE = "drafted; approve or reject it with the buttons on the draft message";
export const OUTBOUND_REFUSAL_LINE = "a reply about our own outbound thread needs the peer desk's send.ts; nothing was sent";
export const OTHER_REFUSAL_LINE = "replies to this kind of message are not taken; nothing was sent";
export const UNRECORDED_REFUSAL_LINE = "that message is not on record; nothing was sent";
export const NO_DESK_LINE = "the peer bridge is not set up for this peer; nothing was sent";
export const LOCKED_LINE = "locked, reset at the station";
type ReplyMsg = { from: number; chat_id: number; text: string; caption?: boolean; reply_to_bot?: boolean; reply_to_message_id?: number; reply_to_text?: string };

const spoolDirOf = (S: string, peer: string) => join(S, peer);
const spoolReady = (S: string, peer: string) => PEER_NAME_RE.test(peer) && fs.existsSync(join(spoolDirOf(S, peer), "spool"));

export function makePeerReplyRoute(d: { stateDir?: string; root: string; access(): Access | null; reply(chat: number, text: string): Promise<void> }) {
  const S = d.stateDir ?? stateDir();
  return async (msg: ReplyMsg): Promise<boolean> => {
    if (msg.reply_to_bot !== true || msg.caption === true || msg.text.trimStart().startsWith("/")) return false;
    const chat = operatorChatId(d.access());
    if (chat === null || msg.chat_id !== chat || msg.from !== chat) return false;
    const entry = msg.reply_to_message_id !== undefined ? readSent(S, msg.reply_to_message_id) : null;
    if (entry === null && !(msg.reply_to_text !== undefined && NOTIFY_LINE1_RE.test(msg.reply_to_text))) return false;
    if (lockdownEnabled(d.root)) { await d.reply(chat, LOCKED_LINE); return true; }
    if (entry === null) { await d.reply(chat, UNRECORDED_REFUSAL_LINE); return true; }
    if (entry.type !== "escalate" && entry.type !== "wake") { await d.reply(chat, OTHER_REFUSAL_LINE); return true; }
    if (entry.dir !== "in") { await d.reply(chat, OUTBOUND_REFUSAL_LINE); return true; }
    const peer = String(entry.peer), root = entry.root;
    if (!Number.isSafeInteger(root) || (root as number) <= 0 || !spoolReady(S, peer)) { await d.reply(chat, NO_DESK_LINE); return true; }
    try {
      submitSpool(spoolDirOf(S, peer), { type: "draft", source: "telegram", kind: "answer", replyTo: root as number, text: msg.text });
    } catch { await d.reply(chat, NO_DESK_LINE); return true; }
    await d.reply(chat, DRAFTING_LINE);
    return true;
  };
}

export type PeerTap = { callback_id: string; from: number; chat_id: number; data: string };
const PEER_TAP_RE = /^peer:(ok|no):([a-z0-9][a-z0-9-]{0,31}):([0-9a-f]{8})$/;

export function makePeerTap(d: { stateDir?: string; configDir?: string; root: string; access(): Access | null; answer(callbackId: string, text: string): Promise<unknown>; clock?(): number }) {
  const S = d.stateDir ?? stateDir();
  const clock = d.clock ?? Date.now;
  const inflight = new Set<Promise<void>>();
  const handle = async (t: PeerTap, m: RegExpExecArray) => {
    const say = (text: string) => d.answer(t.callback_id, text).catch(() => {});
    const chat = operatorChatId(d.access());
    if (chat === null || t.chat_id !== chat || t.from !== chat) { await say("Not authorized."); return; }
    if (lockdownEnabled(d.root)) { await say(LOCKED_LINE); return; }
    if (!spoolReady(S, m[2])) { await say("Unknown peer."); return; }
    try {
      const rec = { verb: m[1] as "ok" | "no", draft: m[3], by: String(t.from), ts: clock() };
      submitSpool(spoolDirOf(S, m[2]), { type: "tap", ...rec, sig: signTap(d.configDir ?? configDir(), { ...rec, peer: m[2] }) });
    } catch { await say("Could not record the tap."); return; }
    await say("Received");
  };
  const tap = (t: PeerTap): boolean => {
    const m = PEER_TAP_RE.exec(t.data);
    if (!m) return false;
    const run: Promise<void> = handle(t, m).catch(e => console.error(`[peer-notify] tap failed: ${e}`)).finally(() => inflight.delete(run));
    inflight.add(run);
    return true;
  };
  return Object.assign(tap, { idle: async () => { while (inflight.size) await Promise.all([...inflight]); } });
}

const PLUGIN_NAME = "telegram-himmel";
const BOT_TOKEN_WORD = /^TELEGRAM_BOT_TOKEN=([0-9]{1,15}):/;

export function isPluginRoot(dir: string): boolean {
  try {
    if (!fs.statSync(join(dir, "server.ts")).isFile()) return false;
    return JSON.parse(fs.readFileSync(join(dir, ".claude-plugin", "plugin.json"), "utf8")).name === PLUGIN_NAME;
  } catch { return false; }
}

export function pluginStateDir(env: Record<string, string>, home = process.env.HOME || homedir()): string {
  return env.TELEGRAM_STATE_DIR ?? join(env.CLAUDE_CONFIG_DIR ?? join(home, ".claude"), "channels", "telegram");
}

function envFile(stateDir: string): { ownPoller: boolean; botId: string | null; missing: boolean; unreadable: boolean } {
  let ownPoller = false, botId: string | null = null;
  try {
    for (const raw of fs.readFileSync(join(stateDir, ".env"), "utf8").split("\n")) {
      const line = raw.trim();
      if (line === "TELEGRAM_OWN_POLLER=1") ownPoller = true;
      const m = BOT_TOKEN_WORD.exec(line);
      if (m) botId ??= m[1];
    }
  } catch (e) {
    const missing = (e as NodeJS.ErrnoException).code === "ENOENT";
    return { ownPoller, botId, missing, unreadable: !missing };
  }
  return { ownPoller, botId, missing: false, unreadable: false };
}

const SWITCH_KEYS = ["TELEGRAM_OWN_POLLER", "TELEGRAM_STATE_DIR", "CLAUDE_CONFIG_DIR"];

export function procFromEnv(pid: number, words: string[] | null, home = process.env.HOME || homedir(), exact = true): ProcInfo {
  if (words === null) return { pid, ownPoller: "unknown", botIds: [] };
  const values = new Map<string, string[]>();
  const botIds: string[] = [];
  for (const w of words) {
    const m = BOT_TOKEN_WORD.exec(w);
    if (m) botIds.push(m[1]);
    const eq = w.indexOf("=");
    if (eq > 0) values.set(w.slice(0, eq), [...(values.get(w.slice(0, eq)) ?? []), w.slice(eq + 1)]);
  }
  if (SWITCH_KEYS.some(k => (values.get(k)?.length ?? 0) > 1)) return { pid, ownPoller: true, botIds: [] };
  const env = Object.fromEntries([...values].map(([k, v]) => [k, v[0]]));
  const dirs = exact
    ? [pluginStateDir(env, home)]
    : [pluginStateDir({}, home), ...(values.get("TELEGRAM_STATE_DIR") ?? []), ...(values.get("CLAUDE_CONFIG_DIR") ?? []).map(c => pluginStateDir({ CLAUDE_CONFIG_DIR: c }, home))];
  const files = dirs.map(envFile);
  if (env.TELEGRAM_OWN_POLLER !== "1" && !files.some(f => f.ownPoller)) {
    const blind = files.some(f => f.unreadable || (!exact && f.missing));
    return { pid, ownPoller: blind ? "unknown" : false, botIds: [] };
  }
  for (const f of files) if (f.botId) botIds.push(f.botId);
  return { pid, ownPoller: true, botIds };
}

const isServerArg = (a: string) => a === "server.ts" || a.endsWith("/server.ts");

function linuxProcs(): ProcInfo[] {
  const out: ProcInfo[] = [];
  for (const name of fs.readdirSync("/proc")) {
    const pid = Number(name);
    if (!Number.isSafeInteger(pid) || pid <= 1 || pid === process.pid) continue;
    let argv: string[], cwd: string;
    try {
      argv = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0").filter(Boolean);
      if (!argv.some(isServerArg)) continue;
      cwd = fs.readlinkSync(`/proc/${pid}/cwd`);
    } catch { continue; }
    if (!isPluginRoot(cwd)) continue;
    let words: string[] | null = null;
    try { words = fs.readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").filter(Boolean); } catch {}
    out.push(procFromEnv(pid, words));
  }
  return out;
}

function run(cmd: string[]): string | null {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "ignore" });
  return r.exitCode === 0 ? r.stdout.toString() : null;
}

export function macProcsFrom(psList: string, cwdOf: (pid: number) => string | null, envOf: (pid: number) => string | null, home?: string): ProcInfo[] {
  const out: ProcInfo[] = [];
  for (const line of psList.split("\n")) {
    const m = /^\s*([0-9]+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const pid = Number(m[1]);
    if (pid === process.pid || !m[2].split(/\s+/).some(isServerArg)) continue;
    const cwd = cwdOf(pid);
    if (!cwd || !isPluginRoot(cwd)) continue;
    const words = envOf(pid)?.split(/\s+/).filter(Boolean) ?? [];
    out.push(procFromEnv(pid, words.some(w => w.startsWith("PATH=")) ? words : null, home, false));
  }
  return out;
}

function macProcs(): ProcInfo[] {
  const list = run(["ps", "-axww", "-o", "pid=,command="]);
  if (list === null) return [];
  return macProcsFrom(list,
    pid => { const o = run(["lsof", "-a", "-d", "cwd", "-p", String(pid), "-Fn"]); const l = o?.split("\n").find(x => x.startsWith("n")); return l ? l.slice(1) : null; },
    pid => { const o = run(["ps", "-E", "-ww", "-p", String(pid), "-o", "command="]); return o === null || o.trim() === "" ? null : o; });
}

export function readProcs(): ProcInfo[] {
  return process.platform === "linux" ? linuxProcs() : process.platform === "darwin" ? macProcs() : [];
}

export function readBotPids(home = process.env.HOME || homedir()): number[] {
  const pids: number[] = [];
  let entries: string[];
  try { entries = fs.readdirSync(home).filter(n => n.startsWith(".claude")); } catch { return pids; }
  for (const e of entries) {
    try {
      const pid = Number(fs.readFileSync(join(home, e, "channels", "telegram", "bot.pid"), "utf8").trim());
      if (Number.isSafeInteger(pid) && pid > 1) { process.kill(pid, 0); pids.push(pid); }
    } catch {}
  }
  return pids;
}
