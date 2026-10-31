import { existsSync, readFileSync } from "node:fs";
import { GROUP_ANONYMOUS_BOT_ID, isAllowed, isOperatorIdentity, type Access } from "./gate";

// Operator `approve <id> <code>` / `deny <id>` -> the root afk-sudo helper.
// The helper (scripts/lib/afk-sudo/afk_sudo.py, installed
// root-owned by install.sh) checks the TOTP code and runs the one allowlisted
// command; this route only decides whether a line may reach it.
//
// Off by default: while the helper is not installed, nothing is consumed and the
// bridge behaves as before. Once installed, every afk-sudo-shaped line is
// CONSUMED, eligible or not, so a code never lands in a session inbox or a run
// prompt. Only a whole typed (not forwarded, not a caption or voice transcript)
// message from the global allowFrom operator in the operator's private chat
// reaches the helper. The code goes to the helper on stdin, never argv, so a
// same-uid process cannot read it from /proc/<pid>/cmdline. The helper runs up
// to its own timeout, so the call is fired, not awaited, like autoFire.
//
// Buttons: the request DM carries Approve / Deny inline buttons
// (callback data `afk:approve:<id>` / `afk:deny:<id>`). A Deny tap runs the same
// deny call at once. An Approve tap NEVER reaches the helper: it only sends a
// ForceReply prompt and remembers prompt-message -> id; the six-digit reply to
// that prompt is the same helper approve call as the typed line, so the TOTP
// check stays the helper's. A tap needs the sender in allowFrom, in their own
// private chat, AND equal to the helper's operator id.

export const AFK_SUDO_HELPER = "/usr/local/libexec/himmel/afk-sudo";
const LINE = /^\s*(approve|deny)\s+([a-z2-7]{8})\b(.*)$/is;
// An approve with a malformed id but a code-shaped run of six digits.
const MALFORMED = /^\s*approve\s+\S+\s.*(?<!\d)\d{3}[ -]?\d{3}(?!\d)/is;

export type AfkSudoLine = { verb: "approve" | "deny"; id: string; code: string };
export type AfkSudoMsg = { from: number; chat_id: number; text: string; sender_chat?: number; forwarded?: boolean; caption?: boolean; reply_to_message_id?: number; reply_to_bot?: boolean };
export type AfkSudoTap = { callback_id: string; from: number; chat_id: number; data: string };
export type HelperRun = (args: string[], stdin: string) => Promise<{ code: number; stdout: string }>;
export type AfkSudoDeps = {
  access: () => Access;
  installed: () => boolean;
  runHelper: HelperRun;
  reply: (chat_id: number, text: string) => Promise<void>;
  log: (line: string) => void;
};
export type AfkSudoCallbackDeps = AfkSudoDeps & {
  operatorId: () => number | null;
  // Sends a ForceReply prompt; the sent message id, or null when it failed.
  prompt: (chat_id: number, text: string) => Promise<number | null>;
  answer: (callback_id: string, text: string) => Promise<void>;
};

// prompt message -> request id. An entry outlives its window as a tombstone so a
// late code reply is still consumed (and refused) instead of reaching a session.
const TOMBSTONE_MS = 3_600_000;
export type AfkSudoPrompts = {
  add: (chat_id: number, message_id: number, id: string) => void;
  get: (chat_id: number, message_id: number) => { id: string; expired: boolean; used: boolean } | null;
  use: (chat_id: number, message_id: number) => void;
  // The id of an unused, unexpired prompt waiting for a code in this chat, or null.
  live: (chat_id: number) => string | null;
};
export function makeAfkSudoPrompts(now: () => number = Date.now, ttlMs = 150_000): AfkSudoPrompts {
  const m = new Map<string, { id: string; at: number; used: boolean }>();
  const key = (c: number, p: number) => `${c}:${p}`;
  return {
    add(c, p, id) {
      for (const [k, v] of m) if (now() - v.at > TOMBSTONE_MS) m.delete(k);
      m.set(key(c, p), { id, at: now(), used: false });
    },
    get(c, p) {
      const v = m.get(key(c, p));
      return v ? { id: v.id, expired: now() - v.at > ttlMs, used: v.used } : null;
    },
    use(c, p) { const v = m.get(key(c, p)); if (v) v.used = true; },
    live(c) {
      for (const [k, v] of m) if (k.startsWith(`${c}:`) && !v.used && now() - v.at <= ttlMs) return v.id;
      return null;
    },
  };
}

export function parseAfkSudo(text: string): AfkSudoLine | null {
  const m = LINE.exec(text);
  if (!m) return null;
  // Anything after the id is the code; the helper refuses one that is not six digits.
  const rest = m[3].replace(/\s+/g, "");
  return { verb: m[1].toLowerCase() as "approve" | "deny", id: m[2].toLowerCase(), code: m[1].toLowerCase() === "approve" ? rest : "" };
}

function eligible(access: Access, msg: AfkSudoMsg): boolean {
  return msg.forwarded === false && msg.caption === false
    && String(msg.from) !== String(GROUP_ANONYMOUS_BOT_ID)
    && msg.chat_id === msg.from && isAllowed(access, msg.from);
}

// One helper call, fired not awaited; the code goes on stdin only.
function runVerb(deps: AfkSudoDeps, verb: "approve" | "deny", id: string, code: string, from: number, chat_id: number): void {
  const args = [verb, id, "--from", String(from), "--chat", String(chat_id)];
  void deps.runHelper(args, verb === "approve" ? `${code}\n` : "")
    .then((res) => {
      const first = res.stdout.split("\n")[0]?.trim() || `exit ${res.code}`;
      return deps.reply(chat_id, `${res.code === 0 ? "✅" : "⚠️"} afk-sudo ${verb} ${id}: ${first}`);
    })
    .catch((e) => deps.log(`[afk-sudo] ${verb} ${id} failed: ${e}`));
}

const CODE_REPLY = /^\s*(\d{6})\s*$/;
// Six digits in a row, spaces or hyphens allowed between them ("123 456", "123-456"),
// anywhere in the text. Used only to decide a message must not be forwarded.
const CODE_RUN = /(?<!\d)\d(?:[\s-]*\d){5}/u;
// A reply to a bot message is held for six contiguous digits standing alone
// (CODE_TOKEN) and for a text that is nothing but digits, spaces and hyphens
// totalling six or seven ("123 456", "12 34 56", "1234567"). Numbers inside words
// that are six digits only once spaces or hyphens are ignored ("do 8276 8277 next",
// "ticket 123-456 is done") are ordinary text.
const CODE_TOKEN = /(?<!\d)\d{6}(?!\d)/u;
const CODE_ONLY = /^\d{6,7}$/u;
const heldAsCode = (text: string): boolean => CODE_TOKEN.test(text) || CODE_ONLY.test(text.replace(/[\s-]/gu, ""));

// A reply to a prompt this bridge issued. Always consumed, so a code (or a
// mistyped one) never lands in a session inbox or a run prompt.
function codeReply(deps: AfkSudoDeps, prompts: AfkSudoPrompts, msg: AfkSudoMsg, p: { id: string; expired: boolean; used: boolean }): true {
  if (!eligible(deps.access(), msg)) {
    deps.log(`[afk-sudo] code reply for ${p.id} refused: not a typed message in the operator's private chat`);
    return true;
  }
  const say = (text: string) => void deps.reply(msg.chat_id, text).catch(() => {});
  if (p.used) {
    say(`⚠️ afk-sudo: the prompt for ${p.id} was already used, nothing ran`);
    return true;
  }
  if (p.expired) {
    say(`⚠️ afk-sudo: the prompt for ${p.id} expired, nothing ran`);
    return true;
  }
  const m = CODE_REPLY.exec(msg.text);
  if (!m) {
    say(`⚠️ afk-sudo: reply with the 6-digit code only, nothing ran`);
    return true;
  }
  prompts.use(msg.chat_id, msg.reply_to_message_id!);
  runVerb(deps, "approve", p.id, m[1], msg.from, msg.chat_id);
  return true;
}

// The gate poller.ts calls first in handleInbound: true = consumed.
export function makeAfkSudoGate(deps: AfkSudoDeps, prompts?: AfkSudoPrompts): (msg: AfkSudoMsg) => boolean {
  return (msg) => {
    if (!deps.installed()) return false;
    const prompt = prompts && msg.reply_to_message_id != null ? prompts.get(msg.chat_id, msg.reply_to_message_id) : null;
    if (prompt) return codeReply(deps, prompts!, msg, prompt);
    const line = parseAfkSudo(msg.text);
    if (!line) {
      if (MALFORMED.test(msg.text)) {
        deps.log("[afk-sudo] approve with a malformed id consumed");
        if (eligible(deps.access(), msg)) {
          void deps.reply(msg.chat_id, "⚠️ afk-sudo: the id is not 8 letters, nothing ran").catch(() => {});
        }
        return true;
      }
      // A message holding a code is still a code, wherever it sits in the text, and an
      // inbox is readable by the sessions that can run the helper. Consume it, never
      // pass it on: a reply to a bot message whose prompt is gone (the map is in
      // memory, so a restart forgets it) when it holds a standalone six-digit token,
      // whatever words surround it, or is only a spaced or hyphenated code, or any
      // message sent while a prompt waits.
      if (CODE_RUN.test(msg.text) && eligible(deps.access(), msg)) {
        const waiting = prompts?.live(msg.chat_id) ?? null;
        if ((msg.reply_to_bot === true && heldAsCode(msg.text)) || waiting) {
          void deps.reply(msg.chat_id, waiting
            ? `⚠️ afk-sudo: reply to the "Code for ${waiting}:" message with the code, nothing ran`
            : "⚠️ afk-sudo: that code prompt expired, tap Approve again").catch(() => {});
          return true;
        }
      }
      // Holding is not helper authorization: operator group messages, including
      // trusted anonymous admins, must not carry a bare code into an inbox either.
      // ponytail: ordinary bare six-digit numbers are held too; prefix with "text:".
      // Upgrade path: an explicit non-code message mode instead of guessing intent.
      if ((msg.reply_to_message_id == null || msg.reply_to_bot === true) && CODE_REPLY.test(msg.text)
        && msg.forwarded === false && msg.caption === false
        && isOperatorIdentity(deps.access(), msg.from, msg.chat_id, msg.sender_chat)) {
        void deps.reply(msg.chat_id, '⚠️ afk-sudo: held a code-shaped message; nothing ran. To send a number as text, prefix it with "text:".').catch(() => deps.log("[afk-sudo] hold notice failed"));
        return true;
      }
      return false;
    }
    if (!eligible(deps.access(), msg)) {
      deps.log(`[afk-sudo] ${line.verb} ${line.id} refused: not a typed message in the operator's private chat`);
      return true;
    }
    runVerb(deps, line.verb, line.id, line.code, msg.from, msg.chat_id);
    return true;
  };
}

const BUTTON = /^afk:(approve|deny):([a-z2-7]{8})$/;

// The inline-button gate poller.ts calls for a callback_query: true = consumed.
export function makeAfkSudoCallback(deps: AfkSudoCallbackDeps, prompts: AfkSudoPrompts): (tap: AfkSudoTap) => boolean {
  const answer = (id: string, text: string) => void deps.answer(id, text).catch(() => {});
  return (tap) => {
    if (!deps.installed()) return false;
    const m = BUTTON.exec(tap.data);
    if (!m) return false;
    const verb = m[1] as "approve" | "deny";
    const id = m[2];
    const op = deps.operatorId();
    if (tap.chat_id !== tap.from || !isAllowed(deps.access(), tap.from) || op === null || op !== tap.from) {
      deps.log(`[afk-sudo] ${verb} ${id} button refused: not the operator in their private chat`);
      answer(tap.callback_id, "Not authorized.");
      return true;
    }
    if (verb === "deny") {
      answer(tap.callback_id, "Denying");
      runVerb(deps, "deny", id, "", tap.from, tap.chat_id);
      return true;
    }
    void deps.prompt(tap.chat_id, `Code for ${id}:`)
      .then((mid) => {
        if (mid != null) prompts.add(tap.chat_id, mid, id);
        answer(tap.callback_id, mid != null ? "Reply with the code" : "Could not ask for the code");
      })
      .catch((e) => { deps.log(`[afk-sudo] approve ${id} prompt failed: ${e}`); answer(tap.callback_id, "Could not ask for the code"); });
    return true;
  };
}

// Feeds each well-formed callback_query of a getUpdates batch to the tap gate.
// A tap with no chat message (an inline-mode message) or non-numeric ids is skipped.
export function dispatchAfkCallbacks(updates: any[], tap: (t: AfkSudoTap) => boolean): void {
  for (const u of updates) {
    const cq = u?.callback_query;
    if (!cq || typeof cq.data !== "string" || typeof cq.id !== "string") continue;
    const from = cq.from?.id, chat_id = cq.message?.chat?.id;
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(chat_id)) continue;
    tap({ callback_id: cq.id, from, chat_id, data: cq.data });
  }
}

export const AFK_SUDO_CONFIG ="/etc/himmel/afk-sudo.json";
// The helper's operator id, from its world-readable config; null when unreadable.
export function operatorIdFromConfig(path = AFK_SUDO_CONFIG): number | null {
  try {
    const n = Number(JSON.parse(readFileSync(path, "utf8")).operator_id);
    return Number.isSafeInteger(n) ? n : null;
  } catch { return null; }
}

// Production helper call: `sudo -n` to the installed copy, a minimal env.
export const spawnHelper: HelperRun = async (args, stdin) => {
  const p = Bun.spawn(["sudo", "-n", AFK_SUDO_HELPER, ...args], {
    stdin: new Blob([stdin]), stdout: "pipe", stderr: "pipe", env: { PATH: "/usr/bin:/bin" },
  });
  const [stdout, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  return { code, stdout };
};

export const helperInstalled = (): boolean => existsSync(AFK_SUDO_HELPER);
