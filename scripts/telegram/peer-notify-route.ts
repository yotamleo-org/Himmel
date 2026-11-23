import fs from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readChain, verifyChain } from "../peer-bridge/chain";
import { readPeersFile } from "../peer-bridge/config";
import { peersFile, stateDir } from "../peer-bridge/ids";
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

export function startPeerNotify(d: { token: string; access(): Access | null; send: Send; log(line: string): void }): ReturnType<typeof makePeerNotifyFlusher> | null {
  const file = peersFile();
  if (!fs.existsSync(file)) return null;
  let cfg: PeersCfg | null = null, himmelRoot = "";
  try {
    const c = readPeersFile(file);
    cfg = { operatorChatId: c.operatorChatId, operatorBotId: c.operatorBotId };
    himmelRoot = c.himmelRoot;
  } catch (e) { d.log(`peer-notify: ${(e as Error).message}`); }
  return makePeerNotifyFlusher({ stateDir: stateDir(), himmelRoot, token: d.token, access: d.access, peersCfg: () => cfg, send: d.send, procs: readProcs, botPids: () => readBotPids(), clock: Date.now, log: d.log });
}

export const PR1_REPLY_LINE = "drafts arrive with the next update; nothing was sent";
export const LOCKED_LINE = "locked, reset at the station";
type ReplyMsg = { from: number; chat_id: number; text: string; caption?: boolean; reply_to_bot?: boolean; reply_to_message_id?: number; reply_to_text?: string };

export function makePeerReplyRoute(d: { stateDir?: string; root: string; access(): Access | null; reply(chat: number, text: string): Promise<void> }) {
  const S = d.stateDir ?? stateDir();
  return async (msg: ReplyMsg): Promise<boolean> => {
    if (msg.reply_to_bot !== true || msg.caption === true || msg.text.trimStart().startsWith("/")) return false;
    const chat = operatorChatId(d.access());
    if (chat === null || msg.chat_id !== chat || msg.from !== chat) return false;
    const onRecord = msg.reply_to_message_id !== undefined && readSent(S, msg.reply_to_message_id) !== null;
    if (!onRecord && !(msg.reply_to_text !== undefined && NOTIFY_LINE1_RE.test(msg.reply_to_text))) return false;
    await d.reply(chat, lockdownEnabled(d.root) ? LOCKED_LINE : PR1_REPLY_LINE);
    return true;
  };
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

function envFileBotId(stateDir: string): string | null {
  try {
    for (const line of fs.readFileSync(join(stateDir, ".env"), "utf8").split("\n")) {
      const m = BOT_TOKEN_WORD.exec(line.trim());
      if (m) return m[1];
    }
  } catch {}
  return null;
}

export function procFromEnv(pid: number, words: string[] | null, home?: string): ProcInfo {
  if (words === null) return { pid, ownPoller: "unknown", botIds: [] };
  if (!words.includes("TELEGRAM_OWN_POLLER=1")) return { pid, ownPoller: false, botIds: [] };
  const env: Record<string, string> = {};
  const botIds: string[] = [];
  for (const w of words) {
    const m = BOT_TOKEN_WORD.exec(w);
    if (m) botIds.push(m[1]);
    const eq = w.indexOf("=");
    if (eq > 0) env[w.slice(0, eq)] ??= w.slice(eq + 1);
  }
  const fromFile = envFileBotId(pluginStateDir(env, home));
  if (fromFile) botIds.push(fromFile);
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

export function macProcsFrom(psList: string, cwdOf: (pid: number) => string | null, envOf: (pid: number) => string | null): ProcInfo[] {
  const out: ProcInfo[] = [];
  for (const line of psList.split("\n")) {
    const m = /^\s*([0-9]+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const pid = Number(m[1]);
    if (pid === process.pid || !m[2].split(/\s+/).some(isServerArg)) continue;
    const cwd = cwdOf(pid);
    if (!cwd || !isPluginRoot(cwd)) continue;
    const env = envOf(pid);
    out.push(procFromEnv(pid, env === null ? null : env.split(/\s+/).filter(Boolean)));
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
