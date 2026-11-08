import { existsSync, readFileSync } from "node:fs";
import { GROUP_ANONYMOUS_BOT_ID, isAllowed, isOperatorIdentity, type Access } from "./gate";
import { classify } from "./router";

// Operator `approve <id> <nonce> <code>` / `deny <id> <nonce>` -> the root afk-sudo helper.
// The helper (scripts/lib/afk-sudo/afk_sudo.py, installed
// root-owned by install.sh) checks the request's nonce (sent only through root's
// notice bot) and the TOTP code, then runs the one approved command; this route
// only decides whether a line may reach it.
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
// (callback data `afk:approve:<id>` / `afk:deny:<id>`). A tap NEVER reaches the helper:
// it only sends a ForceReply prompt and remembers prompt-message -> id and verb; the
// `NONCE CODE` reply to an Approve prompt (the `NONCE` reply to a Deny prompt) is the same
// helper call as the typed line, so the nonce and TOTP checks stay the helper's. A deny
// needs the nonce because every session runs as the operator's uid and can call the
// helper itself. A tap needs the sender in allowFrom, in their own
// private chat, AND equal to the helper's operator id.

export const AFK_SUDO_HELPER = "/usr/local/libexec/himmel/afk-sudo";
const LINE = /^\s*(approve|deny)\s+([a-z2-7]{8})\b(.*)$/is;
// An approve with a malformed id but a code-shaped run of six digits.
const MALFORMED = /^\s*approve\s+\S+\s.*(?<!\d)\d{3}[ -]?\d{3}(?!\d)/is;

// `code` holds everything after the id, spaces removed: for approve the nonce and the code run
// together ("K7QF123456"), the helper splitting the last six characters off as the code; for deny the nonce.
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
export type PromptVerb = "approve" | "deny";
export type AfkSudoPrompt = { id: string; verb: PromptVerb; expired: boolean; used: boolean };
export type AfkSudoPrompts = {
  add: (chat_id: number, message_id: number, id: string, verb?: PromptVerb) => void;
  get: (chat_id: number, message_id: number) => AfkSudoPrompt | null;
  use: (chat_id: number, message_id: number) => void;
  // The ids of the unused, unexpired Approve prompts waiting for a code in this chat (several requests can wait at once).
  live: (chat_id: number) => string[];
};
export function makeAfkSudoPrompts(now: () => number = Date.now, ttlMs = 150_000): AfkSudoPrompts {
  const m = new Map<string, { id: string; verb: PromptVerb; at: number; used: boolean }>();
  const key = (c: number, p: number) => `${c}:${p}`;
  return {
    add(c, p, id, verb = "approve") {
      for (const [k, v] of m) if (now() - v.at > TOMBSTONE_MS) m.delete(k);
      m.set(key(c, p), { id, verb, at: now(), used: false });
    },
    get(c, p) {
      const v = m.get(key(c, p));
      return v ? { id: v.id, verb: v.verb, expired: now() - v.at > ttlMs, used: v.used } : null;
    },
    use(c, p) { const v = m.get(key(c, p)); if (v) v.used = true; },
    live(c) {
      const ids = new Set<string>();
      for (const [k, v] of m) if (k.startsWith(`${c}:`) && v.verb === "approve" && !v.used && now() - v.at <= ttlMs) ids.add(v.id);
      return [...ids];
    },
  };
}

export function parseAfkSudo(text: string): AfkSudoLine | null {
  const m = LINE.exec(text);
  if (!m) return null;
  // Anything after the id is the nonce (and for approve the code); the helper refuses a wrong one.
  return { verb: m[1].toLowerCase() as "approve" | "deny", id: m[2].toLowerCase(), code: m[3].replace(/\s+/g, "") };
}

function eligible(access: Access, msg: AfkSudoMsg): boolean {
  return msg.forwarded === false && msg.caption === false
    && String(msg.from) !== String(GROUP_ANONYMOUS_BOT_ID)
    && msg.chat_id === msg.from && isAllowed(access, msg.from);
}

// One helper call, fired not awaited; the nonce and code go on stdin only. A ran
// approve is acknowledged without the helper's argv line: the command and its
// redacted output come from root's notice bot, which no session can drive.
function runVerb(deps: AfkSudoDeps, verb: "approve" | "deny" | "lockdown", id: string, code: string, from: number, chat_id: number): void {
  const who = ["--from", String(from), "--chat", String(chat_id)];
  const args = verb === "lockdown" ? [verb, ...who, ...(code ? ["--with-nonce"] : [])] : [verb, id, ...who];
  void deps.runHelper(args, code ? `${code}\n` : "")
    .then((res) => {
      const first = res.stdout.split("\n")[0]?.trim() || `exit ${res.code}`;
      // A replay leaves the request pending (the broker spends the step, not the request), so say what to do next.
      const said = verb === "approve" && res.code === 0 && first.startsWith("result=ran ")
        ? "approved; the result comes from the notice bot"
        : verb === "approve" && first.startsWith("result=replay")
          ? "that code was already used, so nothing ran and the request is still pending. Wait for the next code (it changes every 30 seconds), tap Approve again and reply with the nonce and the new code."
          : verb === "lockdown" && res.code === 0 && first.startsWith("result=lockdown-nonce-sent")
            ? "nothing is switched off yet. The notice bot sent a lockdown nonce: send /afk-lockdown <that nonce> within 2 minutes."
            : first;
      return deps.reply(chat_id, `${res.code === 0 ? "✅" : "⚠️"} afk-sudo ${verb}${id && ` ${id}`}: ${said}`);
    })
    .catch((e) => deps.log(`[afk-sudo] ${verb} ${id} failed: ${e}`));
}

// `/afk-lockdown`: the one verb that only narrows, in two steps. Bare, it makes root send
// an 8-character lockdown nonce through the notice bot; `/afk-lockdown <nonce>` then locks down. The nonce
// goes to the helper on stdin; no other text after the command is taken, so nothing typed can reach a flag.
const LOCKDOWN = /^\s*\/afk-lockdown(?:@\w+)?(?=\s|$)(.*)$/is;
const LOCKDOWN_NONCE = /^[0-9A-Za-z]{8}$/;

function lockdown(deps: AfkSudoDeps, msg: AfkSudoMsg, rest: string): true {
  if (!eligible(deps.access(), msg)) {
    deps.log("[afk-sudo] lockdown refused: not a typed message in the operator's private chat");
    return true;
  }
  const nonce = rest.trim();
  if (nonce !== "" && !LOCKDOWN_NONCE.test(nonce)) {
    void deps.reply(msg.chat_id, "⚠️ afk-sudo: /afk-lockdown takes nothing, or the 8-character lockdown nonce from the notice bot; nothing ran").catch(() => {});
    return true;
  }
  runVerb(deps, "lockdown", "", nonce, msg.from, msg.chat_id);
  return true;
}

// `/op <name> key=value ...`: the operator asks root to run one named, versioned station op. The helper
// validates the name and every parameter against the installed schema and sends the notice (name, version, params,
// effect, nonce) through root's notice bot; the approval is the usual `NONCE CODE`. A value with spaces is double-quoted:
// `/op cron-entry action=set tag=ping schedule="0 5 * * *" command=/usr/local/bin/open-session`.
// A last word of six digits is the operator's current TOTP code: it goes to the helper on stdin (`--proof`), is spent
// there, and lets the request take the slot and the hourly budget no session can fill; the approval
// then needs the next code.
const OPCMD = /^\s*\/op(?:@\w+)?(?=\s|$)(.*)$/is;
const OP_NAME = /^[a-z][a-z0-9-]{0,30}$/;
const OP_PAIR = /^[a-z_]{1,20}=[^"]*$/;
const OP_MAX_PAIRS = 8;
const OP_MAX_LEN = 800;

// The op name and its `key=value` words, or the reason the line is refused (the helper checks the values).
export function parseOp(rest: string): { name: string; args: string[]; code?: string } | string {
  const text = rest.trim();
  if (text.length === 0) return "usage: /op <name> key=value ...";
  if (text.length > OP_MAX_LEN) return "the op line is too long";
  if ((text.match(/"/g)?.length ?? 0) % 2 !== 0) return "an unbalanced double quote";
  const words = (text.match(/(?:[^\s"]+|"[^"]*")+/g) ?? []).map((w) => w.replace(/"/g, ""));
  const code = words.length > 1 && /^\d{6}$/.test(words[words.length - 1]) ? words.pop() : undefined;
  const [name, ...args] = words;
  if (!OP_NAME.test(name ?? "")) return "the op name is not a-z, 0-9 and -";
  if (args.length > OP_MAX_PAIRS) return "too many parameters";
  const bad = args.find((a) => !OP_PAIR.test(a));
  if (bad !== undefined) return `"${bad.slice(0, 30)}" is not key=value`;
  return code === undefined ? { name, args } : { name, args, code };
}

function opRequest(deps: AfkSudoDeps, msg: AfkSudoMsg, rest: string): true {
  if (!eligible(deps.access(), msg)) {
    deps.log("[afk-sudo] op refused: not a typed message in the operator's private chat");
    return true;
  }
  const p = parseOp(rest);
  if (typeof p === "string") {
    void deps.reply(msg.chat_id, `⚠️ afk-sudo op: ${p}, nothing ran`).catch(() => {});
    return true;
  }
  const proof = p.code === undefined ? [] : ["--proof"];
  void deps.runHelper(["op-request", "--session", "telegram-op", "--ticket", "operator", ...proof, "--", p.name, ...p.args],
    p.code === undefined ? "" : `${p.code}\n`)
    .then((res) => {
      const first = res.stdout.split("\n")[0]?.trim() || `exit ${res.code}`;
      return deps.reply(msg.chat_id, `${res.code === 0 ? "✅" : "⚠️"} afk-sudo op ${p.name}: ${first}`);
    })
    .catch((e) => deps.log(`[afk-sudo] op ${p.name} failed: ${e}`));
  return true;
}

// The prompt reply: the notice's four-character nonce, then the six-digit code.
const CODE_REPLY = /^\s*([0-9A-Za-z]{4})\s*(\d{3})[\s-]?(\d{3})\s*$/;
// The Deny prompt reply, and what follows the id in a typed deny: the nonce alone.
const NONCE_REPLY = /^\s*([0-9A-Za-z]{4})\s*$/;
const BARE_CODE = /^\s*\d{6}\s*$/;
const NONCE_HINT = "4-character nonce from the notice bot's message";
// This request's own id standing as a word in a reply: the operator typed it where the nonce goes.
// Only the exact id counts, so an ordinary 8-letter word ("approved") is not mistaken for it.
const holdsId = (text: string, id: string): boolean => text.toLowerCase().split(/[^0-9a-z]+/).includes(id);
// The spaces-removed rest of a typed approve ending in the request id again and six digits (a valid nonce is 4 characters).
const idThenCode = (rest: string, id: string): boolean => new RegExp(`${id}\\d{6}$`, "i").test(rest);
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
// Fold a text to ASCII digits before any code test: NFKC (fullwidth), every other Unicode decimal digit
// (Arabic-Indic and the like, counted from its block's zero) and no format characters (zero-width).
const asciiDigit = (d: string): string => {
  let n = 0, cp = d.codePointAt(0)!;
  while (/\p{Nd}/u.test(String.fromCodePoint(cp - 1))) { cp--; n++; }
  return String(n % 10);
};
const fold = (text: string): string => text.normalize("NFKC").replace(/\p{Cf}/gu, "").replace(/\p{Nd}/gu, asciiDigit);
// The whole text is only a code once whitespace, punctuation, dashes, the minus sign and other separators are removed.
const wholeCode = (text: string): boolean => CODE_ONLY.test(fold(text).replace(/[\s\p{Z}\p{P}−]/gu, ""));
// A NONCE CODE pair, ignoring trailing punctuation.
const pairCode = (text: string): boolean => CODE_REPLY.test(fold(text).replace(/[\s\p{P}]+$/u, ""));
const heldAsCode = (text: string): boolean => CODE_TOKEN.test(fold(text)) || wholeCode(text);

// A reply to a prompt this bridge issued. Always consumed, so a code (or a
// mistyped one) never lands in a session inbox or a run prompt.
function codeReply(deps: AfkSudoDeps, prompts: AfkSudoPrompts, msg: AfkSudoMsg, p: AfkSudoPrompt): true {
  if (!eligible(deps.access(), msg)) {
    deps.log(`[afk-sudo] code reply for ${p.id} refused: not a typed message in the operator's private chat`);
    return true;
  }
  const say = (text: string) => void deps.reply(msg.chat_id, text).catch(() => {});
  const tap = p.verb === "deny" ? "Deny" : "Approve";
  if (p.used) {
    say(`⚠️ afk-sudo: the prompt for ${p.id} was already used, nothing ran. If that request is still pending, tap ${tap} on it again for a new prompt; if it already ran or ended, nothing more is needed.`);
    return true;
  }
  if (p.expired) {
    say(`⚠️ afk-sudo: the prompt for ${p.id} expired, nothing ran. If that request is still pending, tap ${tap} on it again for a new prompt; if it already ran or ended, nothing more is needed.`);
    return true;
  }
  if (p.verb === "deny") {
    const n = NONCE_REPLY.exec(msg.text);
    if (!n) {
      say(`⚠️ afk-sudo: a deny takes only the ${NONCE_HINT}, no code. Nothing ran; the prompt still waits.`);
      return true;
    }
    prompts.use(msg.chat_id, msg.reply_to_message_id!);
    runVerb(deps, "deny", p.id, n[1], msg.from, msg.chat_id);
    return true;
  }
  const m = CODE_REPLY.exec(msg.text);
  if (!m) {
    // Name the cause from the shape alone; the refusal never repeats any of the text.
    const cause = wholeCode(msg.text)
      ? `that is the 6-digit code alone. Reply with the ${NONCE_HINT} first, then the code (<nonce> <code>)`
      : holdsId(msg.text, p.id)
        ? `that holds the request id. Reply with only the ${NONCE_HINT} and the 6-digit code (<nonce> <code>)`
        : `could not read that as a nonce and a code. Reply with the ${NONCE_HINT}, then the 6-digit code (<nonce> <code>)`;
    say(`⚠️ afk-sudo: ${cause}. Nothing ran; the prompt still waits.`);
    return true;
  }
  prompts.use(msg.chat_id, msg.reply_to_message_id!);
  runVerb(deps, "approve", p.id, `${m[1]} ${m[2]}${m[3]}`, msg.from, msg.chat_id);
  return true;
}

const isOutsidePrApprove = (text: string): boolean => classify(text).kind === "approve";

// The gate poller.ts calls first in handleInbound: true = consumed.
export function makeAfkSudoGate(deps: AfkSudoDeps, prompts?: AfkSudoPrompts): (msg: AfkSudoMsg) => boolean {
  return (msg) => {
    if (!deps.installed()) return false;
    const lock = LOCKDOWN.exec(msg.text);
    if (lock) return lockdown(deps, msg, lock[1]);
    const opc = OPCMD.exec(msg.text);
    if (opc) return opRequest(deps, msg, opc[1]);
    const prompt = prompts && msg.reply_to_message_id != null ? prompts.get(msg.chat_id, msg.reply_to_message_id) : null;
    if (prompt) return codeReply(deps, prompts!, msg, prompt);
    const line = parseAfkSudo(msg.text);
    if (!line) {
      if (isOutsidePrApprove(msg.text)) return false;
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
      if (CODE_RUN.test(fold(msg.text)) && eligible(deps.access(), msg)) {
        const waiting = prompts?.live(msg.chat_id) ?? [];
        if ((msg.reply_to_bot === true && heldAsCode(msg.text)) || waiting.length > 0) {
          void deps.reply(msg.chat_id, waiting.length > 0
            ? `⚠️ afk-sudo: a code sent as a plain message is not taken, nothing ran. Reply to the "Approve ${waiting.join('" or "Approve ')}" prompt, or send: approve ${waiting.length === 1 ? waiting[0] : "<request id>"} <nonce> <code>`
            : "⚠️ afk-sudo: that code prompt expired or is not known, nothing ran. If the request is still pending, tap Approve on it again; if it already ran or ended, nothing more is needed.").catch(() => {});
          return true;
        }
      }
      // Holding is not helper authorization: operator group messages, including
      // trusted anonymous admins, must not carry a bare code into an inbox either.
      // A `NONCE CODE` pair is held the same way: a session can call the helper's
      // approve itself, so the pair must never reach an inbox. A text that is only six or
      // seven digits once spaces and hyphens are removed ("123 456") is held too, whether
      // or not it is a reply (a reply to a live prompt was answered above).
      // ponytail: ordinary bare six-digit numbers are held too; prefix with "text:".
      // Upgrade path: an explicit non-code message mode instead of guessing intent.
      // A caption, a forward and a reply to a message that is not the bot's are held the same way.
      if ((wholeCode(msg.text) || pairCode(msg.text))
        && isOperatorIdentity(deps.access(), msg.from, msg.chat_id, msg.sender_chat)) {
        void deps.reply(msg.chat_id, '⚠️ afk-sudo: held a code-shaped message; nothing ran. To approve, in your private chat with this bot (never in a group) send "approve <request id> <nonce> <code>" as one message, or tap Approve on the request there and reply to that prompt. To send a number as text, prefix it with "text:".').catch(() => deps.log("[afk-sudo] hold notice failed"));
        return true;
      }
      return false;
    }
    if (!eligible(deps.access(), msg)) {
      deps.log(`[afk-sudo] ${line.verb} ${line.id} refused: not a typed message in the operator's private chat`);
      return true;
    }
    // The helper would end the request on a missing or wrong nonce and spend the code, so a typed approve
    // that visibly lacks the nonce (the code alone) or repeats the id in its place is refused here.
    if (line.verb === "approve" && (/^\d{6}$/.test(fold(line.code)) || idThenCode(line.code, line.id))) {
      const form = `approve ${line.id} <nonce> <code>`;
      void deps.reply(msg.chat_id, /^\d{6}$/.test(fold(line.code))
        ? `⚠️ afk-sudo: approve needs the ${NONCE_HINT} before the code: ${form}. Nothing ran.`
        : `⚠️ afk-sudo: the request id is already in "approve ${line.id}"; after it send only the ${NONCE_HINT} and the code: ${form}. Nothing ran.`).catch(() => {});
      return true;
    }
    if (line.verb === "deny" && !NONCE_REPLY.test(line.code)) {
      void deps.reply(msg.chat_id, `⚠️ afk-sudo: deny needs the ${NONCE_HINT}, no code: deny ${line.id} <nonce>. Nothing ran.`).catch(() => {});
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
    const text = verb === "deny"
      ? `Deny ${id}: reply to this message with the ${NONCE_HINT} alone, no code. A wrong nonce leaves the request pending.`
      : `Approve ${id}: reply to this message with the ${NONCE_HINT}, then the 6-digit code (<nonce> <code>), not the request id. A wrong code with the right nonce ends the request; a wrong nonce leaves it pending.`;
    const want = verb === "deny" ? "the nonce" : "the code";
    void deps.prompt(tap.chat_id, text)
      .then((mid) => {
        if (mid != null) prompts.add(tap.chat_id, mid, id, verb);
        answer(tap.callback_id, mid != null ? `Reply with ${want}` : `Could not ask for ${want}`);
      })
      .catch((e) => { deps.log(`[afk-sudo] ${verb} ${id} prompt failed: ${e}`); answer(tap.callback_id, `Could not ask for ${want}`); });
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
