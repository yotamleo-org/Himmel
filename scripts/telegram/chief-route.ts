import { join, dirname, basename, resolve, isAbsolute } from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { hostname, homedir } from "node:os";
import { briefTextCounted, protectedRanges, findDo } from "./key-brief";
import { killTree, SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";
import { readdir, readFile, stat, mkdir, open, unlink, copyFile, rm, rmdir, realpath, appendFile, writeFile } from "node:fs/promises";
import { appendIfExists, atomicWrite, defaultRoot } from "./bus";
import { loadAccess, operatorChatId } from "./gate";
import { BASH_BIN } from "./run";

// Operator Telegram message -> a named RUNNING chief.
//
// A chief runs without --channels on purpose (a second getUpdates consumer
// 409s the bridge), so nothing reaches it today. Instead the poller (the one
// getUpdates consumer, unchanged) appends one line to the chief's own file
// inbox and the chief Monitors that file (docs/handover/chief-template.md,
// ACTION ZERO). Bare `/chief <text>` discovers a single fresh heartbeat;
// explicit `/chief <name> <text>` and Telegram reply receipts pin a chief;
// `/chief` is a quiet alias of the same verb.
//
// The inbox lives in the bridge's own non-git state dir (<bridge root>/consoles/),
// NOT under the handover root: that root is a git repo that auto-commits and
// pushes, which would publish Telegram text and stall its gitleaks pre-commit.
// It is also NOT <handover root>/inbox/<name>.md: the name-keyed claudex-inbox
// hook fires on native sessions too and would deliver every line twice.
//
// Authority (operator-equal, but not unbounded): the caller (poller.ts
// handleInbound) only reaches this for the global-allowFrom operator in an
// allowed chat, typed and not forwarded, gate.ts stays the sole sender gate.
// The line is tagged `[telegram from=<id> chat=<chat_id>]` so the chief can
// tell it from a terminal message. It carries no RETASK token: it is operator
// -> chief, never chief -> worker (docs/internals/retask-channel.md).
//
// ponytail: explicit named/thread routes preserve armed-inbox delivery even
// without a fresh heartbeat; use /chiefs before addressing an old identity,
// or require liveness on named routes if silent old-inbox queues recur.

export type ConsoleReplyFn = (chat_id: number, text: string, consoleName?: string, replyToMessageId?: number) => Promise<void>;
export type ConsoleRouteGate = {
  authorize: (from: number, chat_id: number) => boolean;
  reply: ConsoleReplyFn;
};
export type ConsoleRoute = { kind: "console"; name: string; text: string; thread?: boolean } | { kind: "consoles" };

export type LiveConsole = { name: string; hb: number; bucket: string; project: string };

export type ArmedConsole = LiveConsole & { busy: boolean };

// A chief mid-turn has no fresh waiter heartbeat, but its armed
// inbox is still read: the next waiter resumes from <inbox>.cursor. Past this
// age (or after a non-wake exit) the chief is treated as released or dead.
const LIVE_MAX_AGE_MS = 300_000;
const BUSY_MAX_AGE_MS = 1_800_000;
export const BUSY_NOTE = "chief is busy, will pick up on next wait";

export async function liveConsoles(root: string, now = Date.now()): Promise<LiveConsole[]> {
  return (await armedConsoles(root, now)).filter(c => !c.busy).map(({ busy: _busy, ...c }) => c);
}

// Armed chiefs that can take a queued line: a fresh waiter, or a busy one (a
// stale waiter heartbeat, or an exit on a chief-wait.sh `wake-*` reason).
export async function armedConsoles(root: string, now = Date.now()): Promise<ArmedConsole[]> {
  const dir = join(root, "consoles");
  let files: string[];
  try { files = await readdir(dir); } catch { return []; }
  const live: ArmedConsole[] = [];
  for (const f of files.sort()) {
    if (!f.endsWith(".md.wait")) continue;
    const name = f.slice(0, -8);
    const inbox = consoleInboxPath(root, name);
    if (!inbox) continue;
    let raw: string;
    try { raw = await readFile(inbox + ".wait", "utf8"); } catch { continue; }
    const match = /^hb=(\d+) pid=\d+ key=\S+ tick=(?:ok|fail|-) state=(waiting|sampling|exited)(?: exit=(\S+))?$/.exec(raw.trim());
    if (!match) continue;
    const hb = Number(match[1]);
    const age = now - hb * 1000;
    if (!Number.isSafeInteger(hb) || age < 0 || age >= BUSY_MAX_AGE_MS) continue;
    const exited = match[2] === "exited";
    if (exited && !match[3]?.startsWith("wake-")) continue;
    try { if (!(await stat(inbox)).isFile()) continue; } catch { continue; }
    let meta: { bucket?: string; project?: string } = {};
    try { meta = JSON.parse(await readFile(inbox + ".meta.json", "utf8")); } catch {}
    live.push({ name, hb, busy: exited || age >= LIVE_MAX_AGE_MS, bucket: typeof meta?.bucket === "string" ? meta.bucket : "unknown", project: typeof meta?.project === "string" ? meta.project : "unknown" });
  }
  return live;
}

// A chief's session name is <PREFIX>-nextleg-<date><letters>-<name> (chief.sh); a
// handover keeps PREFIX and name and advances date/letters, so those chiefs share
// one lineage and the newest rank owns the operator's messages. A name outside the
// convention is a lineage of one.
// ponytail: lineage is read from the name, not chief.sh's recorded predecessor link;
// a renamed chain splits into two lineages (the "more than one chief" refusal
// returns for it). Record the link in <inbox>.meta.json if that recurs.
export function chiefLineage(name: string): { prefix: string; key: string; rank: string } {
  const m = /^([A-Za-z0-9]+)-nextleg-(\d{4}-\d{2}-\d{2})([A-Z]{1,2})-(.+)$/.exec(name);
  if (!m) return { prefix: "", key: `singleton:${name}`, rank: "" };
  return { prefix: m[1], key: `lineage:${m[1]}-${m[4]}`, rank: `${m[2]}${m[3].length}${m[3]}` };
}

// The newest chief, only when every given chief belongs to one lineage.
export function newestChief<T extends { name: string }>(chiefs: T[]): T | undefined {
  if (new Set(chiefs.map(c => chiefLineage(c.name).key)).size !== 1) return undefined;
  return chiefs.reduce((a, b) => chiefLineage(b.name).rank > chiefLineage(a.name).rank ? b : a);
}

// `chief:<project>` always reaches the newest live chief of that project.
const CHIEF_ALIAS = /^chief:([A-Za-z0-9_.-]+)$/i;

const describeConsoles = (live: (LiveConsole & { busy?: boolean })[]) => live.map(c => `${c.name} — hb=${c.hb} (${new Date(c.hb * 1000).toISOString()}) bucket=${c.bucket} project=${c.project}${c.busy ? " (busy)" : ""}`).join("\n");

// Same refusals as chief-kit/inbox-send.sh (empty, path separator, `..`,
// whitespace). The path is built from this value. The router's charset already
// excludes `/` and whitespace; `..` and empty are what reach here.
export function consoleInboxPath(root: string, name: string): string | null {
  if (name === "" || /[\\/\s]/.test(name) || name.includes("..")) return null;
  return join(root, "consoles", `${name}.md`);
}

// First line of <inbox>.handover (chief.sh next), or null when unreadable.
async function handoverMarker(inbox: string): Promise<string | null> {
  try { return (await readFile(inbox + ".handover", "utf8")).split("\n", 1)[0].trim(); } catch { return null; }
}

// A chief that handed over leaves <inbox>.handover naming its successor. Follow
// that chain to the last inbox that exists, so a line addressed to an old chief
// reaches the one reading now. An unreadable, empty or unsafe marker, a
// successor with no inbox yet, a loop or the hop cap stops the walk where it
// is: the line then lands in the inbox reached so far, never nowhere.
const HANDOVER_MAX_HOPS = 1000;
export async function handoverSuccessor(root: string, name: string): Promise<string> {
  const seen = new Set([name]);
  for (let hop = 0; hop < HANDOVER_MAX_HOPS; hop++) {
    const inbox = consoleInboxPath(root, name);
    const next = inbox ? await handoverMarker(inbox) : null;
    const nextInbox = next ? consoleInboxPath(root, next) : null;
    if (!next || !nextInbox || seen.has(next) || !(await isFile(nextInbox))) break;
    seen.add(next);
    name = next;
  }
  return name;
}

// A line can still reach an inbox after its marker: a route that raced
// `chief.sh next`, or one sent while the successor had no inbox yet. Its unread
// tail (past inbox-follow.sh's byte cursor, complete lines only) moves to the
// successor the marker names: appended there, then the old cursor skips it, so
// it moves once and the old chief's waiter does not also wake on it. Only an
// inbox written after its marker counts.
export async function forwardAfterHandover(root: string, to: string): Promise<void> {
  const target = consoleInboxPath(root, to);
  if (!target) return;
  let files: string[];
  try { files = await readdir(join(root, "consoles")); } catch { return; }
  for (const f of files) {
    if (!f.endsWith(".md.handover")) continue;
    const from = f.slice(0, -".md.handover".length);
    const inbox = consoleInboxPath(root, from);
    if (!inbox || from === to || await handoverMarker(inbox) !== to) continue;
    try {
      const [marker, box] = await Promise.all([stat(inbox + ".handover"), stat(inbox)]);
      if (!box.isFile() || box.mtimeMs < marker.mtimeMs) continue;
      const buf = await readFile(inbox);
      let cursor = 0;
      try {
        const raw = (await readFile(inbox + ".cursor", "utf8")).trim();
        if (/^(0|[1-9][0-9]{0,14})$/.test(raw)) cursor = Number(raw);
      } catch {}
      if (cursor > buf.length) cursor = 0;
      const end = buf.lastIndexOf(0x0a) + 1;
      if (end <= cursor) continue;
      if (!(await appendIfExists(target, buf.subarray(cursor, end - 1).toString("utf8")))) return;
      await atomicWrite(inbox + ".cursor", `${end}\n`);
    } catch (e) { console.error(`[chief-route] could not forward ${from}'s unread lines to ${to}: ${e}`); }
  }
}

// One message = one line, so a `tail -F` Monitor emits one event per message.
export const foldLine = (text: string): string => text.trim().replace(/\r?\n/g, " ⏎ ");

const hhmm = (d = new Date()) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

export function staleConsoleCommand(ts?: number): boolean {
  const configured = Number(process.env.TELEGRAM_VERB_MAX_AGE_S ?? 300);
  const maxAge = Number.isSafeInteger(configured) && configured > 0 ? configured : 300;
  const age = Date.now() / 1000 - (ts ?? 0);
  return !Number.isSafeInteger(ts) || age < -5 || age > maxAge;
}

export async function routeFleetCommand(
  root: string,
  msg: { from: number; chat_id: number; ts?: number; message_id?: number; reply_to_message_id?: number },
  route: Extract<import("./router").Route, { kind: "fleet" }>,
  gate: ConsoleRouteGate,
): Promise<void> {
  if (!gate.authorize(msg.from, msg.chat_id)) return;
  const reply: ConsoleReplyFn = (chat, text, name) => gate.reply(chat, text, name, msg.message_id);
  if (staleConsoleCommand(msg.ts)) {
    await reply(msg.chat_id, "⚠️ stale, resend — nothing was queued.");
    return;
  }
  const pinned = msg.reply_to_message_id == null ? null : await consoleReplyTarget(root, msg.chat_id, msg.reply_to_message_id);
  const live = await armedConsoles(root);
  const target = pinned ? live.find(c => c.name === pinned) : live.length === 1 ? live[0] : undefined;
  if (!target) {
    await reply(msg.chat_id, pinned ? `⚠️ chief ${pinned} is stale or not live — nothing was queued.` : live.length > 1 ? `More than one chief is live; reply to its announcement or answer:\n${describeConsoles(live)}` : "⚠️ no live chief — nothing was queued.");
    return;
  }
  const text = route.verb === "status" ? "fleet status" : `${route.verb}${route.worker ? ` ${route.worker}` : ""}`;
  await routeToConsole(root, msg, { kind: "console", name: target.name, text, thread: true }, (chat, ack, name) => reply(chat, name ? `queued ${text} → chief ${name}${ack.includes(BUSY_NOTE) ? ` — ${BUSY_NOTE}` : ""}` : ack, name));
}

// ponytail: no lock around the read-check-append in routeApprove, safe only because the poller dispatches one message at a time; upgrade path = an atomic append-if-absent helper.
// ponytail: the reader checks neither `from` nor `chat`, and a same-uid process can append a row itself (the
// tamper-evident approval store is a separate ticket); this verb does not make the reader check them, upgrade path = a MAC per row.
// ponytail: `is_bot` means any bot, so the operator-chat requirement (a DM, where only this bridge's bot writes) is what makes "bot-authored" mean ours; upgrade path = compare the replied-to sender id with the bridge bot's id.
export type ApproveRoute = Extract<import("./router").Route, { kind: "approve" }>;
export type ApproveMsg = { from: number; chat_id: number; message_id?: number; reply_to_message_id?: number; reply_to_bot?: boolean; reply_to_text?: string; forwarded?: boolean; caption?: boolean };
const APPROVE_REQUEST = /^outside-approve-request ([1-9][0-9]{0,5}) ([0-9a-f]{40})$/;
export const APPROVE_GH_TIMEOUT_MS = 20_000;
const APPROVALS_FILE = "outside-pr-approvals.jsonl";

async function livePr(pr: number, timeoutMs: number): Promise<{ state: string; head: string } | null> {
  try {
    const p = Bun.spawn(["gh", "pr", "view", String(pr), "--json", "state,headRefOid"], { ...SPAWN_OWN_GROUP, cwd: join(import.meta.dir, "../.."), stdin: "ignore", stdout: "pipe", stderr: "ignore" });
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timedOut = new Promise<null>(done => { timer = setTimeout(() => { killTree(p.pid, (s: string) => p.kill(s as any)); done(null); }, timeoutMs); });
    const out = await Promise.race([Promise.all([new Response(p.stdout).text(), p.exited]), timedOut]).finally(() => clearTimeout(timer));
    if (!out || out[1] !== 0) return null;
    const j = JSON.parse(out[0]);
    return j && typeof j === "object" && typeof j.state === "string" && typeof j.headRefOid === "string" && /^[0-9a-f]{40}$/.test(j.headRefOid) ? { state: j.state, head: j.headRefOid } : null;
  } catch { return null; }
}

export async function routeApprove(msg: ApproveMsg, route: ApproveRoute, gate: ConsoleRouteGate, opts: { ghTimeoutMs?: number } = {}): Promise<void> {
  if (!gate.authorize(msg.from, msg.chat_id)) return;
  if (msg.forwarded === true || msg.caption !== false) return;
  const say = async (text: string) => {
    try { await gate.reply(msg.chat_id, text, undefined, msg.message_id); }
    catch (e) { console.error(`[chief-route] approve reply could not be delivered for chat ${msg.chat_id}: ${e}`); }
  };
  const refuse = (why: string) => say(`⚠️ approve: ${why} — nothing stored.`);
  if (msg.chat_id !== operatorChatId(await loadAccess())) return refuse("it works only in the operator's own chat");
  const asked = typeof msg.reply_to_text === "string" ? APPROVE_REQUEST.exec(msg.reply_to_text.split("\n", 1)[0]) : null;
  if (msg.reply_to_message_id == null || msg.reply_to_bot !== true || !asked) return refuse("reply to the outside-approve-request message from the bot");
  const [, askedPr, sha] = asked;
  if (Number(askedPr) !== route.pr) return refuse(`that request is for PR ${askedPr}, not PR ${route.pr}`);
  if (route.prefix.length < 7) return refuse("the sha prefix must be at least 7 hex");
  if (!sha.startsWith(route.prefix)) return refuse(`${route.prefix} is not a prefix of the requested sha ${sha.slice(0, 7)}`);
  if (!Number.isSafeInteger(msg.message_id) || (msg.message_id as number) <= 0) return refuse("this message has no message id, so the approval cannot be recorded");
  const live = await livePr(route.pr, opts.ghTimeoutMs ?? APPROVE_GH_TIMEOUT_MS);
  if (!live) return say(`⚠️ approve: cannot read PR ${route.pr}; nothing stored`);
  if (live.state !== "OPEN") return refuse(`PR ${route.pr} is not open (${live.state})`);
  if (live.head !== sha) return refuse(`PR ${route.pr}'s head changed since the request (now ${live.head.slice(0, 7)}, requested ${sha.slice(0, 7)}); ask the chief for a new request`);
  const home = process.env.HOME;
  if (!home || !isAbsolute(home)) return refuse("HOME is not set");
  const store = join(home, ".himmel", APPROVALS_FILE);
  let prior = "";
  try { prior = await readFile(store, "utf8"); }
  catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") { console.error(`[chief-route] approve could not read ${store}: ${e}`); return refuse("cannot read the approval file"); } }
  for (const line of prior.split("\n")) {
    let row: any; try { row = JSON.parse(line); } catch { continue; }
    if (row && row.pr === route.pr && row.head === sha && row.stage === "review" && row.message_id != null) return say(`PR ${route.pr} at ${sha.slice(0, 7)} is already approved (message ${row.message_id}); nothing new stored.`);
  }
  const row = { v: 1, ts: new Date().toISOString(), host: hostname(), source: "telegram-approve", kind: "approval", pr: route.pr, head: sha, stage: "review", from: msg.from, chat: msg.chat_id, message_id: msg.message_id };
  try {
    await mkdir(dirname(store), { recursive: true, mode: 0o700 });
    const fh = await open(store, "a", 0o600);
    try { await fh.write(JSON.stringify(row) + "\n"); } finally { await fh.close(); }
  } catch (e) { console.error(`[chief-route] approve could not write ${store}: ${e}`); return refuse("the approval could not be written"); }
  await say(`✅ approved PR ${route.pr} at ${sha.slice(0, 7)} (review stage); the review may now run at this exact head.`);
}

export async function routeToConsole(
  root: string,
  msg: { from: number; chat_id: number },
  route: ConsoleRoute,
  reply: ConsoleReplyFn,
): Promise<void> {
  // The append is the delivery. A failed ack after it must not throw out of
  // handleInbound: handleBatch would tell the operator "could not be queued,
  // please resend" for a message that WAS queued, manufacturing a duplicate.
  const say = async (text: string, name?: string) => {
    try { await reply(msg.chat_id, text, name); }
    catch (e) { console.error(`[poller] console reply could not be delivered for chat ${msg.chat_id}: ${e}`); }
  };
  if (route.kind === "consoles") {
    const live = await liveConsoles(root);
    await say(live.length ? describeConsoles(live) : "⚠️ no live chief — nothing was sent.");
    return;
  }
  let name = route.name;
  let text = route.text;
  let file = name ? consoleInboxPath(root, name) : null;
  // Preserve explicit addressing of an armed inbox. Otherwise the first word
  // is part of the bare command, not an invented session name.
  const named = file && await stat(file).then(s => s.isFile(), () => false);
  if (!named) {
    if (route.thread) { await say(`⚠️ no chief "${name}" has an armed inbox — nothing was sent.`); return; }
    const live = await armedConsoles(root);
    // The router's name charset has no `:`, so `/chief chief:himmel go` arrives as
    // a bare message whose text starts with the alias.
    const alias = CHIEF_ALIAS.exec(name || text.split(/\s/, 1)[0]);
    if (alias) {
      if (!name) { name = alias[0]; text = text.slice(alias[0].length).trim(); }
      if (!text) { await say(`⚠️ no message after "${name}" — nothing was sent.`); return; }
      const want = alias[1].toLowerCase();
      const hits = live.filter(c => c.bucket.toLowerCase() === want || chiefLineage(c.name).prefix.toLowerCase() === want);
      const newest = newestChief(hits);
      if (!newest) {
        await say(hits.length ? `More than one chief lineage matches "${name}"; choose /chief <name> <text>:\n${describeConsoles(hits)}` : `⚠️ no live chief for "${name}" — nothing was sent.`);
        return;
      }
      name = newest.name;
    } else if (live.length === 1) {
      text = name ? `${name} ${text}` : text;
      name = live[0].name;
    } else {
      // With several armed chiefs, a unique case-insensitive
      // fragment (prefix, suffix or substring) of one name routes there and is
      // stripped from the text, as a full name is.
      // The narrowest tier with a hit decides, so "CO" finds `...10CO-roadmap-
      // chief` rather than every name containing "console".
      const frag = name && name.length >= 2 ? name.toLowerCase() : "";
      const tiers = frag ? [
        (c: ArmedConsole) => c.name.includes(name!),
        (c: ArmedConsole) => c.name.toLowerCase().startsWith(frag) || c.name.toLowerCase().endsWith(frag),
        (c: ArmedConsole) => c.name.toLowerCase().includes(frag),
      ] : [];
      const hits = tiers.map(t => live.filter(t)).find(h => h.length) ?? [];
      const pinned = hits.length > 1 ? newestChief(hits) : hits[0];
      const newest = newestChief(live);
      if (pinned) {
        // A fragment that names several chiefs picks none of them, so it stays in the text.
        if (hits.length > 1) text = name ? `${name} ${text}` : text;
        name = pinned.name;
      } else if (!hits.length && newest) {
        // Several chiefs of ONE lineage are live: the first word names none of them,
        // so the whole text goes to the newest.
        text = name ? `${name} ${text}` : text;
        name = newest.name;
      } else {
        await say(hits.length > 1 ? `More than one chief matches "${name}"; choose /chief <name> <text>:\n${describeConsoles(hits)}` : live.length ? `More than one chief is live; choose /chief <name> <text>:\n${describeConsoles(live)}` : `⚠️ no live chief${name ? ` (requested "${name}")` : ""} — nothing was sent.`);
        return;
      }
    }
    file = consoleInboxPath(root, name);
  }
  if (!file) return;
  const addressed = name;
  name = await handoverSuccessor(root, name);
  file = consoleInboxPath(root, name)!;
  await forwardAfterHandover(root, name);
  // Append only to an inbox a chief already armed; never create one, so a typo
  // cannot open a mailbox nobody reads. The append itself is the existence
  // check, no separate existsSync() step left to race.
  const delivered = await appendIfExists(file, `- ${hhmm()} [telegram from=${msg.from} chat=${msg.chat_id}] ${foldLine(text)}`);
  if (!delivered) { await say(`⚠️ no chief "${name}" is listening (it has not armed its inbox) — nothing was sent.`); return; }
  const busy = (await armedConsoles(root)).some(c => c.name === name && c.busy);
  await say(`→ chief ${name}${name !== addressed ? ` (${addressed} handed over)` : ""}${busy ? ` — queued, ${BUSY_NOTE}` : ""}`, name);
}

function replyPath(root: string, chat: number, message: number): string | null {
  if (!Number.isSafeInteger(chat) || chat === 0 || !Number.isSafeInteger(message) || message <= 0) return null;
  return join(root, "consoles", "replies", `${chat}_${message}.json`);
}

// Only the bridge's send receipt writes these mappings; reply text and quoted
// Telegram message bodies never supply a chief identity.
export async function rememberConsoleReply(root: string, chat: number, message: number, name: string): Promise<void> {
  const file = replyPath(root, chat, message);
  if (!file || typeof name !== "string" || !consoleInboxPath(root, name)) return;
  await mkdir(dirname(file), { recursive: true });
  await atomicWrite(file, JSON.stringify({ name }));
}

export async function consoleReplyTarget(root: string, chat: number, message: number): Promise<string | null> {
  const file = replyPath(root, chat, message);
  if (!file) return null;
  try {
    const { name } = JSON.parse(await readFile(file, "utf8"));
    return typeof name === "string" && consoleInboxPath(root, name) ? name : null;
  } catch { return null; }
}

// Inline buttons: "Send to chief" (the newest chief) and "Choose chief" (a picker,
// newest first). A tap never carries text: it asks for a message with a ForceReply
// prompt pinned to the chosen chief, and the operator's reply then rides the same
// reply-receipt route as any chief answer (consoleReplyTarget).
export const CHIEF_KEYBOARD = { inline_keyboard: [[{ text: "Send to chief", callback_data: "chief:send" }, { text: "Choose chief", callback_data: "chief:pick" }]] };

const CHIEF_BUTTON = /^chief:(send|pick|to:([A-Za-z0-9_.-]{1,55}))$/;

export type ChiefTap = { callback_id: string; from: number; chat_id: number; data: string };
export type ChiefTapDeps = {
  root: string;
  authorize: (from: number, chat_id: number) => boolean;
  prompt: (chat_id: number, text: string) => Promise<number | null>;
  picker: (chat_id: number, text: string, markup: object) => Promise<boolean>;
  answer: (callback_id: string, text: string) => Promise<void>;
};

// The inline-button gate poller.ts chains after the AFK sudo one: true = consumed.
// authorize is the same sender-and-chat gate as a typed /chief, so a tap from
// outside allowFrom is answered "Not authorized." and touches nothing.
export function makeChiefTap(deps: ChiefTapDeps): ((tap: ChiefTap) => boolean) & { idle: () => Promise<void> } {
  const inflight = new Set<Promise<void>>();
  const answer = (id: string, text: string) => deps.answer(id, text).catch(() => {});
  const ask = async (tap: ChiefTap, name: string) => {
    const mid = await deps.prompt(tap.chat_id, `Message for chief ${name}:`);
    if (mid != null) await rememberConsoleReply(deps.root, tap.chat_id, mid, name);
    await answer(tap.callback_id, mid != null ? "Reply with your message" : "Could not ask for the message");
  };
  const handle = async (tap: ChiefTap, m: RegExpExecArray) => {
    if (!deps.authorize(tap.from, tap.chat_id)) { await answer(tap.callback_id, "Not authorized."); return; }
    const live = (await armedConsoles(deps.root)).sort((a, b) => chiefLineage(b.name).rank.localeCompare(chiefLineage(a.name).rank) || a.name.localeCompare(b.name));
    if (!live.length) { await answer(tap.callback_id, "No live chief."); return; }
    if (m[1] === "send" && newestChief(live)) { await ask(tap, newestChief(live)!.name); return; }
    if (m[1].startsWith("to:")) {
      if (!live.some(c => c.name === m[2])) { await answer(tap.callback_id, "That chief is no longer live."); return; }
      await ask(tap, m[2]);
      return;
    }
    const buttons = live.filter(c => CHIEF_BUTTON.test(`chief:to:${c.name}`)).map(c => [{ text: c.name, callback_data: `chief:to:${c.name}` }]);
    const ok = buttons.length > 0 && await deps.picker(tap.chat_id, "Which chief? Newest first.", { inline_keyboard: buttons });
    await answer(tap.callback_id, ok ? "Pick a chief" : "Could not list the chiefs");
  };
  const tap = (t: ChiefTap): boolean => {
    const m = CHIEF_BUTTON.exec(t.data);
    if (!m) return false;
    const run: Promise<void> = handle(t, m).catch(e => console.error(`[chief-route] chief button failed: ${e}`)).finally(() => inflight.delete(run));
    inflight.add(run);
    return true;
  };
  return Object.assign(tap, { idle: async () => { while (inflight.size) await Promise.all([...inflight]); } });
}

function inboxIdentity(inbox: string): { root: string; name: string } {
  const path = resolve(inbox);
  const root = dirname(dirname(path));
  const name = basename(path).replace(/\.md$/, "");
  if (consoleInboxPath(root, name) !== path) throw new Error("not a console inbox path");
  return { root, name };
}

export async function registerConsole(inbox: string, bucket: string, project: string): Promise<void> {
  inboxIdentity(inbox);
  await mkdir(dirname(inbox), { recursive: true });
  await atomicWrite(inbox + ".meta.json", JSON.stringify({ bucket, project }));
}

export async function announceConsole(inbox: string): Promise<void> {
  const { root, name } = inboxIdentity(inbox);
  if (!(await liveConsoles(root)).some(c => c.name === name)) return;
  const chat = operatorChatId(await loadAccess());
  if (chat === null) return;
  const marker = inbox + ".announced";
  let claim;
  try { claim = await open(marker, "wx"); }
  catch (e: any) { if (e.code === "EEXIST") return; throw e; }
  await claim.close();
  // ponytail: a kill between claim and enqueue can lose this one announcement;
  // use transactional outbox dedupe if crash-loss is observed. Re-arms never spam.
  try {
    const { replyViaOutbox } = await import("./poller");
    await replyViaOutbox(root, chat, `Chief ${name} is live — just send /chief <text>`, name, undefined, CHIEF_KEYBOARD);
  } catch (e) { await unlink(marker); throw e; }
}

async function currentConsoleName(root: string): Promise<string | undefined> {
  try {
    const p = Bun.spawn([BASH_BIN, "-c", '. "$1"; current_session_name', "chief-reply", join(import.meta.dir, "../lib/session-name.sh")], { stdout: "pipe", stderr: "ignore" });
    const name = (await new Response(p.stdout).text()).trim();
    const file = consoleInboxPath(root, name);
    if (await p.exited === 0 && file && await stat(file).then(s => s.isFile(), () => false)) return name;
  } catch {}
  return undefined;
}

// A voice line's tag names the asking satellite (`[voice satellite=<entity_id> ...]`).
// `reply --satellite <entity_id>` also speaks the answer there through Home Assistant's
// assist_satellite.announce; HA_URL and HA_TOKEN come from the caller's environment
// (himmel-secrets exec --keys HA_URL,HA_TOKEN), never from a file.
export const SATELLITE_ID = /^assist_satellite\.[a-z0-9_]+$/;

export async function speakOnSatellite(satellite: string, text: string, env: Record<string, string | undefined> = process.env, fetchFn: typeof fetch = fetch): Promise<void> {
  if (!SATELLITE_ID.test(satellite)) throw new Error(`not an assist_satellite entity id: ${satellite}`);
  const base = env.HA_URL?.replace(/\/+$/, "");
  if (!base || !env.HA_TOKEN) throw new Error("HA_URL and HA_TOKEN are required to speak on a satellite");
  const res = await fetchFn(`${base}/api/services/assist_satellite/announce`, {
    method: "POST",
    headers: { authorization: `Bearer ${env.HA_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ entity_id: satellite, message: foldLine(text) }),
  });
  if (!res.ok) throw new Error(`Home Assistant announce failed: HTTP ${res.status}`);
}

// `send-file`. Hand a local file to the operator's Telegram chat.
// Validates here (missing / not a file / over the Bot API's 50 MB cap are refused with
// a clear error and a non-zero exit, nothing queued), renders a markdown spec or plan
// to a standalone phone-readable HTML file first, then queues one `document_path`
// outbox line that the poller uploads with sendDocument. The chief never holds the
// bot token. The queued copy lives in <bridge root>/outgoing/<id>/ (not git, not pruned); the poller ships only from there.
export const MAX_SEND_BYTES = 50 * 1024 * 1024;
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// A spec or plan page goes to the operator to be signed, so it goes only after its latest-round
// spec critic and plan critic ended in a clean line AND quoted the sha256 of the exact bytes
// being sent (operator decisions 700 and 701), or, once the ticket's round ledger holds three
// rounds of that kind (decision 763), with each open finding on the page. The critic files sit beside the spec as
// `<spec>.critic-spec-r<n>.md` / `<spec>.critic-plan-r<n>.md`; `critic-seal.sh` adds the
// `CONTENT-SHA256 <sha> <path relative to the verdict file>` line above the verdict line.
// A file is a signature page when it lives under `specs/{design,designs,spec,plan,plans}/` or
// `specs/HIMMEL-<n>/`, or a plan critic file names it; every other file sends as before.
const NOT_FOR_SIGNATURE = "Not for signature";
const CLEAN = { spec: "SPEC CLEAN", plan: "PLAN CLEAN" } as const;
const FINDINGS = { spec: /^SPEC FINDINGS \d+$/, plan: /^PLAN FINDINGS \d+$/ } as const;
export const CRITIC_ROUND_CAP = 3;
type Kind = "spec" | "plan";
const verdictKind = (line: string): Kind | undefined => /^(SPEC|PLAN) (CLEAN|FINDINGS \d+)$/.exec(line)?.[1].toLowerCase() as Kind | undefined;
const SIGNATURE_DIRS = new Set(["design", "designs", "spec", "plan", "plans"]);
const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
const lastLine = (text: string) => text.split("\n").map(l => l.trim()).filter(Boolean).at(-1) ?? "";
const sealsOf = (text: string) => [...text.matchAll(/^CONTENT-SHA256 ([0-9a-f]{64}) (\S.*)$/gm)].map(m => ({ sha: m[1], rel: m[2] }));

const underSignaturePath = (p: string) => {
  const parts = p.split("/");
  return parts.some((d, i) => d === "specs" && i + 2 < parts.length && (SIGNATURE_DIRS.has(parts[i + 1]) || /^HIMMEL-\d+$/.test(parts[i + 1])));
};

// A missing folder reads as empty; any other failure (a folder we may not read) refuses, naming the folder.
async function listDir(dir: string): Promise<string[]> {
  try { return (await readdir(dir)).sort(); }
  catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || code === "ENOTDIR") return [];
    throw new Error(`${dir}: cannot read the folder (${e instanceof Error ? e.message : e}); the page is not sent`);
  }
}

// The plan and plans folders of every specs root above `path`.
function planDirs(path: string): string[] {
  const parts = path.split("/");
  const dirs = new Set<string>();
  parts.forEach((d, i) => { if (d === "specs") for (const s of ["plan", "plans"]) dirs.add([...parts.slice(0, i + 1), s].join("/")); });
  return [...dirs];
}

// The newest round of each critic kind for `spec`: spec and plan critics beside it, plus same-named plan
// critics (`<spec name>.critic-plan-r<n>.md`) saved beside the plan in a plan or plans folder of the specs root.
// The highest round wins; other files of the same round (`tied`) must be clean too.
type CriticFile = { path: string; round: number; tied: string[] };
async function latestCritics(spec: string): Promise<Record<"spec" | "plan", CriticFile | null>> {
  const out: Record<"spec" | "plan", CriticFile | null> = { spec: null, plan: null };
  const base = basename(spec);
  const scan = async (dir: string, kinds: string[]) => {
    for (const n of await listDir(dir)) {
      const m = n.startsWith(base + ".") ? /^\.critic-(spec|plan)-r(\d+)\.md$/.exec(n.slice(base.length)) : null;
      if (!m || !kinds.includes(m[1])) continue;
      const kind = m[1] as "spec" | "plan"; const round = Number(m[2]);
      if (!out[kind] || round > out[kind]!.round) out[kind] = { path: join(dir, n), round, tied: [] };
      else if (round === out[kind]!.round) out[kind]!.tied.push(join(dir, n));
    }
  };
  await scan(dirname(spec), ["spec", "plan"]);
  for (const d of planDirs(spec)) if (d !== dirname(spec)) await scan(d, ["plan"]);
  return out;
}

// Folders a critic file for `page` may sit in: its own, and the design and plan folders of any specs
// root above it (a plan critic may be saved beside the SPEC, while the plan itself lives in the plans folder).
function criticDirs(page: string): string[] {
  const parts = page.split("/");
  const dirs = new Set([dirname(page)]);
  parts.forEach((d, i) => { if (d === "specs") for (const s of SIGNATURE_DIRS) dirs.add([...parts.slice(0, i + 1), s].join("/")); });
  return [...dirs];
}

// How a page relates to the spec whose critic files govern it: the spec itself, a rendering of it
// (`<stem>.html` beside `<stem>.md`), or its plan (the same-named file in a plans folder, or sealed by some plan critic round of that spec).
type Role = "spec" | "render" | "plan";
const siblingMd = (page: string) => (/\.html?$/i.test(page) ? page.replace(/\.html?$/i, ".md") : null);
const isFile = (p: string) => stat(p).then(s => s.isFile(), () => false);

const readCritic = (file: string) => readFile(file, "utf8").catch((e) => { throw new Error(`${file}: cannot read the critic file (${e instanceof Error ? e.message : e}); the page is not sent`); });

// Reads the last name segment only: the spec's own name comes first and may hold the word.
const isJudgeReturn = (name: string) => /(^|[.-])judge[^.]*\.md$/.test(name);

async function sealSpecs(v: string, page: string): Promise<{ read: string; named?: string; namedExists: boolean }> {
  const source = await markedSource(page);
  const md = siblingMd(page);
  const read = source ?? (await governingSpec(page))?.spec ?? (md && await isFile(md) ? md : page);
  const name = /^(.+?)\.critic/.exec(basename(v))?.[1];
  const named = name ? join(dirname(v), name) : undefined;
  return { read, named, namedExists: named ? await isFile(named) : false };
}

export const OPERATOR_CRITICAL_CLASSES = ["spend-grant", "account-or-terms", "public-policy", "reverses-ruling"] as const;
type Finding = { id: string; severity: "major" | "medium" | "minor"; critical?: string; critical_refused?: string; reopens?: string; regression?: boolean; class?: "reopens" | "regression" | "out-of-closure" };
type SeededReturn = { return_sha: string; verdict_path: string; seals: { read_path: string; read_sha: string }[]; findings: Finding[]; unrated_ids: string[]; verdict: string };
type LedgerRow = { row: string; [field: string]: any };

const FINDING_LINE = /^[-*] \*\*([A-Za-z][\w.-]*)\*\* \(([^)]*)\)/;
const KEY_FOLDER = /^[A-Z][A-Z0-9]+-[0-9]+$/;
const ledgerDir = (specs: string) => join(specs, "ledgers", "spec-rounds");
const specsRootOf = (p: string) => { const parts = p.split("/"); const i = parts.lastIndexOf("specs"); return i < 0 ? null : parts.slice(0, i + 1).join("/"); };

export function returnSha(text: string): string {
  const lines = text.split("\n").filter(l => !l.startsWith("CONTENT-SHA256 ")).map(l => l.trimEnd());
  while (lines.length && lines.at(-1) === "") lines.pop();
  return sha256(Buffer.from(lines.length ? `${lines.join("\n")}\n` : ""));
}

export function keyOf(specPath: string): string | null {
  const parts = specPath.split("/");
  const folder = parts.at(-2);
  if (folder && KEY_FOLDER.test(folder) && parts.at(-3) === "specs") return folder;
  return /^([A-Z][A-Z0-9]+-[0-9]+)(?=[-.])/.exec(parts.at(-1) ?? "")?.[1] ?? null;
}

export function parseFindings(returnText: string, kind: Kind, round: number): { findings: Finding[]; unrated_ids: string[] } {
  const findings: Finding[] = [];
  for (const line of returnText.split("\n")) {
    const m = FINDING_LINE.exec(line);
    if (!m) continue;
    const [severity, ...tags] = m[2].split(";").map(s => s.trim());
    if (severity !== "major" && severity !== "medium" && severity !== "minor") continue;
    const f: Finding = { id: m[1], severity };
    for (const tag of tags) {
      const cls = /^operator-critical:\s*(.*)$/.exec(tag)?.[1];
      if (cls !== undefined) { if ((OPERATOR_CRITICAL_CLASSES as readonly string[]).includes(cls)) f.critical = cls; else f.critical_refused = cls; }
      const reopens = /^reopens\s+(\S+)$/.exec(tag)?.[1];
      if (reopens) f.reopens = reopens;
      if (tag === "regression") f.regression = true;
    }
    findings.push(f);
  }
  const counted = Number(/^(?:SPEC|PLAN) FINDINGS (\d+)$/.exec(lastLine(returnText))?.[1] ?? 0);
  return { findings, unrated_ids: Array.from({ length: Math.max(0, counted - findings.length) }, (_, i) => `${kind}-r${round}-U${i + 1}`) };
}

const isCount = (n: unknown, min: number) => Number.isInteger(n) && (n as number) >= min;
const isText = (s: unknown) => typeof s === "string" && s !== "";
const hasFindings = (r: Record<string, unknown>) => Array.isArray(r.findings) && Array.isArray(r.unrated_ids);
function wellFormed(r: Record<string, unknown>): boolean {
  if (r.row === "round") return KINDS.includes(r.critic as Kind) && isCount(r.round, 1) && isText(r.return_sha) && isText(r.verdict_path) && isText(r.read_path) && isText(r.read_sha) && hasFindings(r);
  if (r.row === "seal") return isText(r.return_sha) && isText(r.read_path) && isText(r.read_sha);
  if (r.row === "seed") {
    const latest = r.latest as Record<string, unknown> | undefined;
    return isCount(r.spec, 0) && isCount(r.plan, 0) && !!latest && KINDS.every(k => Array.isArray(latest[k])
      && (latest[k] as Record<string, unknown>[]).every(x => isText(x?.return_sha) && isText(x?.verdict_path) && Array.isArray(x?.seals) && hasFindings(x)));
  }
  return isText(r.row);
}

async function readLedger(specs: string, key: string): Promise<LedgerRow[] | null> {
  const text = await readFile(join(ledgerDir(specs), `${key}.jsonl`), "utf8").catch((e: NodeJS.ErrnoException) => {
    if (e.code === "ENOENT") return null;
    throw new Error(`${key} ledger cannot be read (${e.message}); restore it from the state repo history`);
  });
  if (text === null) return null;
  return text.split("\n").flatMap((line, i) => {
    if (line === "") return [];
    let row: unknown;
    try { row = JSON.parse(line); } catch { row = null; }
    if (!row || typeof row !== "object" || Array.isArray(row) || !wellFormed(row as Record<string, unknown>)) throw new Error(`${key} ledger line ${i + 1} does not parse; restore it from the state repo history`);
    return [row as LedgerRow];
  });
}

const manifestFile = (specs: string) => join(ledgerDir(specs), "manifest.json");
async function readManifest(specs: string): Promise<{ keys: Record<string, unknown> }> {
  const text = await readFile(manifestFile(specs), "utf8").catch((e: NodeJS.ErrnoException) => {
    if (e.code === "ENOENT") throw new Error(`no round manifest under ${specs}; run round-seed --all once`);
    throw new Error(`${manifestFile(specs)}: cannot read the round manifest (${e.message}); restore it from the state repo history`);
  });
  let m: { keys?: unknown } | null = null;
  try { m = JSON.parse(text); } catch {}
  if (!m || typeof m.keys !== "object" || m.keys === null || Array.isArray(m.keys)) throw new Error(`${manifestFile(specs)}: the round manifest does not parse; restore it from the state repo history`);
  return m as { keys: Record<string, unknown> };
}

async function loadLedger(specs: string, key: string): Promise<Rows> {
  const manifest = await readManifest(specs);
  const rows = await readLedger(specs, key) ?? [];
  const snapshots = await stat(join(ledgerDir(specs), key)).then(() => true, (e: NodeJS.ErrnoException) => {
    if (e.code === "ENOENT") return false;
    throw new Error(`${key}: cannot read its snapshot folder (${e.message}); restore it from the state repo history`);
  });
  const seeded = rows.some(r => r.row === "seed");
  if ((Object.hasOwn(manifest.keys, key) && !seeded) || (snapshots && !seeded && !rows.some(r => r.row === "round"))) throw new Error(`${key} is in the round manifest but has no ledger; restore it from the state repo history`);
  return Object.assign(rows, { checked: await checkRecords(specs, key, rows) });
}

// One writer at a time per ticket: flock(2) on a persistent lock file beside the ledger, released when the file closes.
// The kernel call blocks the thread, so callers in this process take turns here first: a second one asking for the lock
// while the first still awaits its own file work would otherwise never let the first finish.
let ledgerTurn: Promise<unknown> = Promise.resolve();
function withLedgerLock<T>(specs: string, key: string, fn: () => Promise<T>): Promise<T> {
  const run = ledgerTurn.then(() => flockedLedger(specs, key, fn));
  ledgerTurn = run.catch(() => {});
  return run;
}
async function flockedLedger<T>(specs: string, key: string, fn: () => Promise<T>): Promise<T> {
  await mkdir(ledgerDir(specs), { recursive: true });
  const { dlopen } = await import("bun:ffi");
  const libc = dlopen(process.platform === "darwin" ? "libSystem.B.dylib" : "libc.so.6", { flock: { args: ["i32", "i32"], returns: "i32" } });
  const lock = await open(join(ledgerDir(specs), `${key}.jsonl.lock`), "a");
  try {
    if (libc.symbols.flock(lock.fd, 2) !== 0) throw new Error(`${key}: cannot lock its round ledger`);
    return await fn();
  } finally { await lock.close(); libc.close(); }
}

async function createNew(path: string, data: string | Uint8Array, made: string[]): Promise<boolean> {
  const file = await open(path, "wx").catch((e: NodeJS.ErrnoException) => { if (e.code === "EEXIST") return null; throw e; });
  if (!file) return false;
  made.push(path);
  try { await file.writeFile(data); } finally { await file.close(); }
  return true;
}

async function snapshotBytes(specs: string, key: string, bytes: Uint8Array, sum: string, made: string[] = []): Promise<void> {
  const path = join(ledgerDir(specs), key, sum);
  await mkdir(dirname(path), { recursive: true });
  await createNew(path, bytes, made);
}

const namesTicket = (specText: string, key: string) => {
  const front = /^---\n([\s\S]*?)\n---(?:\n|$)/.exec(specText.replace(/\r\n/g, "\n"))?.[1] ?? "";
  return front.split("\n").some(l => /^tickets:/.test(l) && new RegExp(`(?<![A-Za-z0-9])${key}(?![A-Za-z0-9])`).test(l));
};

export type RoundState = {
  key: string; epoch: number; spec: number; plan: number; writer: number; next: "full" | "closure" | "none"; why: string;
  latest: Record<Kind, LedgerRow | SeededReturn[] | null>; overrideUsed: boolean; invalid: string[]; cap: number;
  critical_open: { id: string; class: string; kind: Kind; round: number; verdict_path: string }[];
};
const KINDS = ["spec", "plan"] as const;
type Checked = { epoch: number; override: LedgerRow | null; criticals: LedgerRow[]; invalid: string[] };
type Rows = LedgerRow[] & { checked: Checked };
const epochNow = (rows: LedgerRow[]) => (rows as Partial<Rows>).checked?.epoch ?? 0;
const seedOf = (rows: LedgerRow[]) => rows.find(r => r.row === "seed");
const seededReturns = (rows: LedgerRow[], kind: Kind): SeededReturn[] => epochNow(rows) > 0 ? [] : (seedOf(rows)?.latest?.[kind] as SeededReturn[] | undefined) ?? [];
const roundRows = (rows: LedgerRow[], kind: Kind) => rows.filter(r => r.row === "round" && r.critic === kind && (Number(r.epoch) || 0) === epochNow(rows));
const kindRound = (rows: LedgerRow[], kind: Kind) => Math.max(epochNow(rows) > 0 ? 0 : Number(seedOf(rows)?.[kind]) || 0, ...roundRows(rows, kind).map(r => Number(r.round) || 0));
const latestRow = (rows: LedgerRow[], kind: Kind) => roundRows(rows, kind).reduce<LedgerRow | null>((top, r) => (!top || Number(r.round) >= Number(top.round) ? r : top), null);
type Returned = { findings?: Finding[]; unrated_ids?: string[]; mode?: string; return_sha?: string };
const isBlocking = (f: Finding, mode?: string) => mode === "closure" ? f.class === "reopens" || f.class === "regression" : f.severity === "major" || !!f.reopens || !!f.regression;
const blockingOf = (r: Returned) => [...(r.findings ?? []).filter(f => isBlocking(f, r.mode)).map(f => ({ id: f.id, severity: String(f.severity) })), ...(r.unrated_ids ?? []).map(id => ({ id, severity: "unrated" }))];
const leftBlocking = (r: Returned) => blockingOf(r).length > 0;
function blockedAt(rows: LedgerRow[], kind: Kind, round: number): boolean {
  const row = roundRows(rows, kind).filter(r => Number(r.round) === round).at(-1);
  if (row) return leftBlocking(row);
  return Number(seedOf(rows)?.[kind]) === round && seededReturns(rows, kind).some(leftBlocking);
}
type Latest = Returned & { kind: Kind; round: number; return_sha: string; verdict_path: string };
function latestReturns(rows: LedgerRow[], kind: Kind): Latest[] {
  const row = latestRow(rows, kind);
  if (row) return [{ ...row, kind, round: Number(row.round), return_sha: String(row.return_sha), verdict_path: String(row.verdict_path) }];
  return seededReturns(rows, kind).map(s => ({ ...s, kind, round: Number(seedOf(rows)?.[kind]) || 0 }));
}
const openBlocking = (rows: LedgerRow[]) => KINDS.flatMap(kind => latestReturns(rows, kind).flatMap(l => blockingOf(l).map(b => ({ ...b, kind, round: l.round, return_sha: l.return_sha, verdict_path: l.verdict_path }))));
const writerRound = (rows: LedgerRow[]) => Math.max(kindRound(rows, "spec"), kindRound(rows, "plan"));
const latestRoundTs = (rows: LedgerRow[]) => Number(rows.filter(r => r.row === "round").at(-1)?.ts) || 0;

const findingKey = (id: unknown, returnSha: unknown) => `${id}|${returnSha}`;
function criticalOpenOf(rows: Rows): RoundState["critical_open"] {
  const closed = new Set(rows.checked.criticals.map(r => findingKey(r.id, r.return_sha)));
  const out: RoundState["critical_open"] = [];
  const listed = new Set<string>();
  for (const kind of KINDS) {
    const seen = [...seededReturns(rows, kind).map(s => ({ round: Number(seedOf(rows)?.[kind]) || 0, verdict_path: s.verdict_path, return_sha: s.return_sha, findings: s.findings })), ...roundRows(rows, kind).map(r => ({ round: Number(r.round), verdict_path: String(r.verdict_path), return_sha: String(r.return_sha), findings: r.findings as Finding[] }))];
    for (const s of seen) for (const f of s.findings ?? []) {
      const k = findingKey(f.id, s.return_sha);
      if (f.critical && !closed.has(k) && !listed.has(k)) { listed.add(k); out.push({ id: f.id, class: f.critical, kind, round: s.round, verdict_path: s.verdict_path }); }
    }
  }
  return out;
}
function findingOf(rows: Rows, id: string): { f: Finding; return_sha: string; verdict_path: string } | null {
  const ruled = new Set(rows.checked.criticals.map(r => findingKey(r.id, r.return_sha)));
  const all = KINDS.flatMap(kind => [...seededReturns(rows, kind), ...roundRows(rows, kind)]
    .flatMap(r => ((r.findings as Finding[] | undefined) ?? []).filter(x => x.id === id).map(f => ({ f, return_sha: String(r.return_sha), verdict_path: String(r.verdict_path) }))));
  return all.find(h => h.f.critical && !ruled.has(findingKey(id, h.return_sha))) ?? all[0] ?? null;
}

const normText = (s: string) => s.replace(/\s+/g, " ").trim();
async function quoteRule(specs: string, key: string, d: string, quote: string, used: boolean, sinceTs: number): Promise<{ error: string } | { path: string; sha: string }> {
  if (!/^[0-9]+$/.test(d)) return { error: `'${d}' is not a decision number` };
  const names = (await listDir(join(specs, "decisions"))).filter(n => new RegExp(`^verbatim-decision-${d}-.*\\.txt$`).test(n));
  if (names.length !== 1) return { error: `${names.length} files match specs/decisions/verbatim-decision-${d}-*.txt, expected exactly one` };
  const path = join(specs, "decisions", names[0]); const bytes = await readFile(path); const text = normText(bytes.toString("utf8"));
  if (!new RegExp(`(?<![A-Za-z0-9])${key}(?![A-Za-z0-9])`).test(text)) return { error: `decision ${d} does not name ${key}` };
  if (used) return { error: `decision ${d} was already used for ${key}` };
  if (normText(quote).length < 20 || !text.includes(normText(quote))) return { error: `decision ${d} does not hold the quote (20 characters or more, whitespace-normalised)` };
  if ((await stat(path)).mtimeMs <= sinceTs) return { error: `decision ${d} is not newer than the latest round of ${key}` };
  return { path, sha: sha256(bytes) };
}

async function checkRecords(specs: string, key: string, rows: LedgerRow[]): Promise<Checked> {
  let epoch = 0; let roundTs = 0; let sawReset = false; let sawOverride = false;
  const blocking: Record<Kind, string[]> = { spec: [], plan: [] }; const maxRound: Record<Kind, number> = { spec: 0, plan: 0 }; const classOf = new Map<string, string>();
  const usedCritical = new Set<string>(); const usedReset = new Set<string>(); const ruled = new Set<string>();
  const criticals: { row: LedgerRow; epoch: number }[] = []; let override: { row: LedgerRow; epoch: number } | null = null; const invalid: string[] = [];
  const take = (kind: Kind, round: number, r: Returned[]) => { maxRound[kind] = round; blocking[kind] = r.flatMap(x => blockingOf(x).map(b => b.id)); for (const x of r) for (const f of x.findings ?? []) if (f.critical) classOf.set(findingKey(f.id, x.return_sha), f.critical); };
  const label = (r: LedgerRow) => r.decision === undefined ? r.row : `${r.row} ${r.decision}`;
  for (const r of rows) {
    if (r.row === "seed") for (const k of KINDS) take(k, Number(r[k]) || 0, (r.latest?.[k] as Returned[] | undefined) ?? []);
    else if (r.row === "round" && (Number(r.epoch) || 0) === epoch) { roundTs = Number(r.ts) || 0; take(r.critic as Kind, Number(r.round) || 0, [r]); }
    else if (r.row === "reset") {
      const d = String(r.decision); const q = sawReset ? null : await quoteRule(specs, key, d, String(r.quote), usedReset.has(d), roundTs);
      sawReset = true; usedReset.add(d);
      if (q && !("error" in q) && q.path === r.decision_path && q.sha === r.decision_sha) { epoch++; blocking.spec = []; blocking.plan = []; maxRound.spec = 0; maxRound.plan = 0; classOf.clear(); ruled.clear(); }
      else invalid.push(label(r));
    } else if (r.row === "critical") {
      const d = String(r.decision); const q = await quoteRule(specs, key, d, String(r.quote), usedCritical.has(d), roundTs); usedCritical.add(d);
      if (!("error" in q) && q.path === r.decision_path && q.sha === r.decision_sha && classOf.get(findingKey(r.id, r.return_sha)) === r.class && !ruled.has(findingKey(r.id, r.return_sha)) && (r.epoch === undefined || Number(r.epoch) === epoch) && [0, Math.max(maxRound.spec, maxRound.plan) + 1].includes(Number(r.opens))) { criticals.push({ row: r, epoch }); ruled.add(findingKey(r.id, r.return_sha)); }
      else invalid.push(label(r));
    } else if (r.row === "override") {
      const ids = Array.isArray(r.findings) ? r.findings.map((f: { id?: unknown }) => String(f?.id)) : [];
      const open = new Set([...blocking.spec, ...blocking.plan]);
      const ok = !sawOverride && ids.length > 0 && ids.every(id => open.has(id)) && isText(r.why) && isText(r.chief) && Math.max(maxRound.spec, maxRound.plan) >= CRITIC_ROUND_CAP + 1 && Number(r.round_opened) === Math.max(maxRound.spec, maxRound.plan) + 1;
      sawOverride = true;
      if (ok) override = { row: r, epoch }; else invalid.push(label(r));
    }
  }
  return { epoch, override: override && override.epoch === epoch ? override.row : null, criticals: criticals.filter(c => c.epoch === epoch).map(c => c.row), invalid };
}

function capRefusal(key: string, rows: LedgerRow[], kind: Kind, round: number): string | null {
  if (round <= CRITIC_ROUND_CAP) return null;
  const c = (rows as Rows).checked;
  const critical = c.criticals.some(r => Number(r.opens) === round);
  if (round === CRITIC_ROUND_CAP + 1) return critical || KINDS.some(k => blockedAt(rows, k, CRITIC_ROUND_CAP)) ? null : `${key} ${kind} round ${round} needs a blocking finding in round ${CRITIC_ROUND_CAP} of either kind; sign it under 848, its minors go to the build`;
  const override = !!c.override && Number(c.override.round_opened) === round && openBlocking(rows).length > 0;
  return critical || override ? null : `${key} writer round ${round} needs a round-override or round-critical record`;
}

function stateOf(key: string, rows: Rows): RoundState {
  const spec = kindRound(rows, "spec"); const plan = kindRound(rows, "plan");
  const latest = (kind: Kind) => latestRow(rows, kind) ?? (seededReturns(rows, kind).length ? seededReturns(rows, kind) : null);
  const modes = KINDS.map(kind => {
    const r = kindRound(rows, kind) + 1; const refusal = capRefusal(key, rows, kind, r);
    return { kind, r, mode: refusal ? "none" : r > CRITIC_ROUND_CAP ? "closure" : "full", refusal };
  });
  const next = modes.some(m => m.mode === "full") ? "full" : modes.some(m => m.mode === "closure") ? "closure" : "none";
  return {
    key, epoch: rows.checked.epoch, spec, plan, writer: Math.max(spec, plan), next, why: modes.map(m => `${m.kind} round ${m.r}: ${m.refusal ?? m.mode}`).join("; "),
    latest: { spec: latest("spec"), plan: latest("plan") }, overrideUsed: rows.some(r => r.row === "override"),
    invalid: rows.checked.invalid, cap: CRITIC_ROUND_CAP, critical_open: criticalOpenOf(rows),
  };
}

// The round state of `key` from its ledger alone; throws when the ledger cannot be trusted (T10, T11, T12).
export async function roundState(specsRoot: string, key: string): Promise<RoundState> {
  return stateOf(key, await loadLedger(specsRoot, key));
}

// The read-only snapshot of one kind's round budget for `specPath`, from its ledger: `allowed` says whether round
// `requestedRound` (the next one when omitted) may be sealed now. An unreadable ledger throws: unknown history is never an empty one.
export type CriticBudget = { count: number; requestedRound: number; allowed: boolean; why: string | null; cap: number; rounds: { round: number; path: string }[] };
export async function readCriticBudget(specPath: string, kind: Kind, requestedRound?: number): Promise<CriticBudget> {
  const spec = await realpath(specPath); const key = keyOf(spec); const specs = specsRootOf(spec);
  if (!key || !specs) throw new Error(`${spec}: has no ticket key under a specs folder; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
  const rows = await loadLedger(specs, key);
  const count = kindRound(rows, kind); const requested = requestedRound ?? count + 1;
  const why = requested === count + 1 ? capRefusal(key, rows, kind, requested) : `${key} ${kind} round ${requested} is not the next round (${count + 1})`;
  const seeded = seededReturns(rows, kind).map(x => ({ round: Number(seedOf(rows)?.[kind]) || 0, path: x.verdict_path }));
  const rounds = [...seeded, ...roundRows(rows, kind).map(r => ({ round: Number(r.round), path: String(r.verdict_path) }))]
    .sort((a, b) => a.round - b.round || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return { count, requestedRound: requested, allowed: why === null, why, cap: CRITIC_ROUND_CAP, rounds };
}

type SealTarget = { v: string; page: string; text: string; kind: Kind; governing: string; specs: string; key: string };
async function sealTarget(verdict: string, readPath: string): Promise<SealTarget | null> {
  const v = await realpath(verdict); const page = await realpath(readPath);
  const text = await readCritic(v);
  const kind = verdictKind(lastLine(text));
  if (!kind || isJudgeReturn(basename(v))) return null;
  const { read, named, namedExists } = await sealSpecs(v, page);
  const governing = named && namedExists ? named : read;
  const specs = specsRootOf(governing);
  if (!specs) throw new Error(`${governing}: sits under no specs folder, so it has no round ledger; the seal is refused`);
  await readManifest(specs);
  const namedKey = named ? keyOf(named) : null; const readKey = keyOf(read);
  if (namedKey && readKey && namedKey !== readKey) throw new Error(`${basename(v)} is named for ${namedKey} but the file it read belongs to ${readKey}; the seal is refused`);
  const key = namedKey ?? readKey;
  if (!key) throw new Error(`${governing}: has no ticket key; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
  return { v, page, text, kind, governing, specs, key };
}

type SealedFile = { read_path: string; read_sha: string; seeded: boolean };
const sealedFileOf = (x: { read_path: unknown; read_sha: unknown }, seeded: boolean): SealedFile => ({ read_path: String(x.read_path), read_sha: String(x.read_sha), seeded });
const distinctFiles = (files: SealedFile[]) => files.filter((s, i) => files.findIndex(o => o.read_path === s.read_path && o.read_sha === s.read_sha) === i);
function roundBefore(rows: LedgerRow[], kind: Kind, r: number): { returns: { return_sha: string }[]; sealed: SealedFile[] } {
  const row = roundRows(rows, kind).filter(x => Number(x.round) === r - 1).at(-1);
  const returns: { return_sha: string }[] = row ? [row as { return_sha: string }] : Number(seedOf(rows)?.[kind]) === r - 1 ? seededReturns(rows, kind) : [];
  const own = row ? [sealedFileOf(row, false)] : seededReturns(rows, kind).flatMap(s => s.seals.map(x => sealedFileOf(x, true)));
  const later = rows.filter(x => x.row === "seal" && returns.some(y => y.return_sha === x.return_sha)).map(x => sealedFileOf(x, false));
  return { returns, sealed: distinctFiles([...own, ...later]) };
}
const closureMarker = (key: string, kind: Kind, r: number, returnSha: string) => `CLOSURE-CHECK ${key} ${kind} r${r - 1} ${returnSha.slice(0, 12)}`;

async function snapshotsOf(specs: string, key: string, sealed: SealedFile[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const s of sealed) {
    const path = join(ledgerDir(specs), key, s.read_sha);
    const bytes = await readFile(path).catch((e: NodeJS.ErrnoException) => { if (e.code === "ENOENT") return null; throw e; });
    if (bytes === null) { if (s.seeded) continue; throw new Error(`snapshot ${s.read_sha} was edited`); }
    if (sha256(bytes) !== s.read_sha) throw new Error(`snapshot ${s.read_sha} was edited`);
    out.set(s.read_path, path);
  }
  return out;
}
async function diffOf(snapshot: string, now: string, label: string): Promise<string> {
  const exists = await isFile(now);
  const p = Bun.spawn(["diff", "-u", "-L", `a/${label}`, "-L", `b/${label}`, snapshot, exists ? now : "/dev/null"], { stdout: "pipe", stderr: "pipe" });
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  const code = await p.exited;
  if (code > 1) throw new Error(`diff of ${label} failed (exit ${code}): ${err.trim()}`);
  return out;
}
const changedLines = (diff: string) => {
  const lines = diff.split("\n");
  const body = lines[0]?.startsWith("--- ") && lines[1]?.startsWith("+++ ") ? lines.slice(2) : lines;
  return body.filter(l => l.startsWith("+") || l.startsWith("-")).map(l => l.slice(1));
};

async function closureCheck(specs: string, key: string, kind: Kind, r: number, rows: LedgerRow[], text: string | null, page: string): Promise<string[]> {
  const prev = roundBefore(rows, kind, r);
  if (text !== null) {
    const markers = prev.returns.map(x => closureMarker(key, kind, r, x.return_sha));
    if (!text.split("\n").map(l => l.trim()).some(l => markers.includes(l))) throw new Error(`${key} ${kind} round ${r} is a closure check of round ${r - 1}; build its input with closure-pack`);
  }
  if (!prev.sealed.some(s => s.read_path === page)) throw new Error(`${key} ${kind} round ${r} is a closure check of the files round ${r - 1} read: ${[...new Set(prev.sealed.map(s => s.read_path))].join(", ")}`);
  const snaps = await snapshotsOf(specs, key, prev.sealed);
  const changed: string[] = [];
  for (const [path, snap] of snaps) changed.push(...changedLines(await diffOf(snap, path, basename(path))));
  return changed;
}

function sortClosure(text: string, findings: Finding[], openIds: Set<string>, changed: string[]): Finding[] {
  const lines = text.split("\n");
  return findings.map(f => {
    const line = lines.find(l => FINDING_LINE.exec(l)?.[1] === f.id) ?? "";
    const quoted = [...line.matchAll(/`([^`]{12,})`/g)].map(m => m[1]);
    const cls = f.reopens && openIds.has(f.reopens) ? "reopens" : f.regression && quoted.some(q => changed.some(l => l.includes(q))) ? "regression" : "out-of-closure";
    return { ...f, class: cls };
  });
}

type Admission = { round: number; mode: "full" | "closure"; findings?: Finding[] };
async function admit(t: SealTarget, rows: Rows): Promise<Admission | null> {
  const sum = returnSha(t.text);
  const prior = rows.find(r => r.row === "round" && r.return_sha === sum && (Number(r.epoch) || 0) === rows.checked.epoch);
  if (prior || KINDS.some(k => seededReturns(rows, k).some(x => x.return_sha === sum))) {
    if (prior?.mode === "closure") await closureCheck(t.specs, t.key, prior.critic, Number(prior.round), rows, null, t.page);
    return null;
  }
  const round = kindRound(rows, t.kind) + 1;
  const refusal = capRefusal(t.key, rows, t.kind, round);
  if (refusal) throw new Error(refusal);
  if (round <= CRITIC_ROUND_CAP) return { round, mode: "full" };
  const changed = await closureCheck(t.specs, t.key, t.kind, round, rows, t.text, t.page);
  return { round, mode: "closure", findings: sortClosure(t.text, parseFindings(t.text, t.kind, round).findings, new Set(openBlocking(rows).map(b => b.id)), changed) };
}

export async function refuseRoundPastCap(verdict: string, readPath: string): Promise<void> {
  const t = await sealTarget(verdict, readPath);
  if (t) await admit(t, await loadLedger(t.specs, t.key));
}

// What `critic-seal.sh` runs before it seals: the cap decision and the ledger row it allows, under one lock,
// so two seals cannot both claim a round.
export async function sealRound(verdict: string, readPath: string): Promise<void> {
  const t = await sealTarget(verdict, readPath);
  if (!t) return;
  const bytes = await readFile(t.page); const readSha = sha256(bytes); const sum = returnSha(t.text);
  await withLedgerLock(t.specs, t.key, async () => {
    const rows = await loadLedger(t.specs, t.key);
    const admitted = await admit(t, rows);
    const file = join(ledgerDir(t.specs), `${t.key}.jsonl`);
    if (admitted === null) {
      await snapshotBytes(t.specs, t.key, bytes, readSha);
      await appendFile(file, `${JSON.stringify({ v: 1, ts: Date.now(), key: t.key, row: "seal", return_sha: sum, read_path: t.page, read_sha: readSha })}\n`);
      return;
    }
    if (!seedOf(rows) && !rows.some(r => r.row === "round") && !namesTicket(await readFile(t.governing, "utf8"), t.key)) throw new Error(`${t.governing}: front matter has no tickets: line naming ${t.key}`);
    const row = { v: 1, ts: Date.now(), key: t.key, row: "round", critic: t.kind, round: admitted.round, epoch: rows.checked.epoch, return_sha: sum, verdict_path: t.v, read_path: t.page, read_sha: readSha, verdict: lastLine(t.text), mode: admitted.mode, ...parseFindings(t.text, t.kind, admitted.round), ...(admitted.findings ? { findings: admitted.findings } : {}) };
    await snapshotBytes(t.specs, t.key, bytes, readSha);
    await appendFile(file, `${JSON.stringify(row)}\n`);
  });
}

export type LedgerVerdict = { key: string; kind: Kind; round: number; mode: string };
// Spec D10: a critic file counts only when its return is the ledger's latest sealed round of its kind (or the seed's
// latest while no round of its kind followed), and every seal line it carries is one the ledger recorded.
export async function ledgerVerify(file: string, opts: { spec?: string; sign?: boolean } = {}): Promise<LedgerVerdict> {
  const abs = await realpath(file).catch(() => { throw new Error(`${file}: not found`); });
  return verifyReturn(abs, await readCritic(abs), opts);
}
async function verifyReturn(abs: string, text: string, opts: { spec?: string; sign?: boolean }): Promise<LedgerVerdict> {
  const spec = opts.spec === undefined ? undefined : await realpath(opts.spec).catch(() => resolve(opts.spec!));
  const specKey = spec ? keyOf(spec) : null;
  if (spec && !specKey) throw new Error(`${spec}: has no ticket key; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
  const stem = /^(.+?)\.critic/.exec(basename(abs))?.[1];
  const key = (stem ? keyOf(join(dirname(abs), stem)) : null) ?? specKey;
  if (!key) throw new Error(`${abs}: names no ticket key; pass --spec <the spec it belongs to>`);
  if (specKey && specKey !== key) throw new Error(`${abs} is named for ${key} but ${spec} belongs to ${specKey}`);
  const specs = specsRootOf(spec ?? abs);
  if (!specs) throw new Error(`${abs}: sits under no specs folder, so it has no round ledger`);
  const rows = await loadLedger(specs, key);
  const sum = returnSha(text);
  const row = rows.filter(r => r.row === "round" && r.return_sha === sum).at(-1);
  let kind: Kind; let round: number; let mode: string; let sealed: { read_path: string; read_sha: string }[];
  if (row) {
    kind = row.critic; round = Number(row.round); mode = String(row.mode); sealed = [{ read_path: row.read_path, read_sha: row.read_sha }];
  } else {
    const k = KINDS.find(x => seededReturns(rows, x).some(s => s.return_sha === sum));
    if (!k) throw new Error(`${abs}: its return is not in ${key}'s ledger`);
    kind = k; round = Number(seedOf(rows)?.[k]) || 0; mode = "seed"; sealed = [...seededReturns(rows, k).find(s => s.return_sha === sum)!.seals];
  }
  const top = latestRow(rows, kind);
  if ((top && top.return_sha !== sum) || (row && !top)) throw new Error(`${abs} is not ${key}'s latest ${kind} round (round ${top?.round ?? 0} is ${top?.verdict_path ?? "not sealed yet"})`);
  for (const r of rows) if (r.row === "seal" && r.return_sha === sum) sealed.push({ read_path: r.read_path, read_sha: r.read_sha });
  for (const s of sealsOf(text)) {
    const p = await realpath(resolve(dirname(abs), s.rel)).catch(() => resolve(dirname(abs), s.rel));
    if (!sealed.some(x => x.read_path === p && x.read_sha === s.sha)) throw new Error(`${abs}: the CONTENT-SHA256 line for ${p} is not in ${key}'s ledger`);
  }
  const open = criticalOpenOf(rows);
  if (opts.sign && open.length) throw new Error(`${key} has open operator-critical findings: ${open.map(o => `${o.id} (${o.class})`).join(", ")}; the operator rules on them first (round-critical)`);
  return { key, kind, round, mode };
}

const appendRow = (specs: string, key: string, row: Record<string, unknown>) => appendFile(join(ledgerDir(specs), `${key}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key, ...row })}\n`);
const needConsole = (verb: string) => { if (process.env.HIMMEL_CONSOLE !== "1") throw new Error(`${verb}: needs HIMMEL_CONSOLE=1, the chief's marker; a worker never writes a record`); };

export async function roundOverride(specs: string, key: string, o: { findings: string[]; why: string; chief: string }): Promise<void> {
  needConsole("round-override");
  await withLedgerLock(specs, key, async () => {
    const rows = await loadLedger(specs, key);
    if (rows.some(r => r.row === "override")) throw new Error(`round-override: ${key} already used its one override`);
    if (!o.findings.length || !o.why.trim() || !o.chief.trim()) throw new Error("round-override: --findings, --why and --chief are all required");
    const open = openBlocking(rows);
    const named = o.findings.map(id => {
      const f = open.find(x => x.id === id);
      if (!f) throw new Error(`round-override: ${id} is not an open blocking finding of ${key}'s latest round`);
      return { id, severity: f.severity, critic: f.kind, return_sha: f.return_sha };
    });
    const writer = writerRound(rows);
    if (writer < CRITIC_ROUND_CAP + 1) throw new Error(`round-override: ${key} is at writer round ${writer}; rounds 1 to ${CRITIC_ROUND_CAP} are free and round ${CRITIC_ROUND_CAP + 1} opens on its own`);
    await appendRow(specs, key, { row: "override", epoch: rows.checked.epoch, round_opened: writer + 1, findings: named, why: o.why, chief: o.chief });
  });
}

export async function roundCritical(specs: string, key: string, o: { finding: string; decision: string; quote: string; noRound: boolean }): Promise<void> {
  needConsole("round-critical");
  await withLedgerLock(specs, key, async () => {
    const rows = await loadLedger(specs, key);
    const hit = findingOf(rows, o.finding);
    if (!hit) throw new Error(`round-critical: ${o.finding} is not a finding of ${key}'s rounds`);
    if (!hit.f.critical) throw new Error(hit.f.critical_refused !== undefined ? `round-critical: '${hit.f.critical_refused}' is not an operator-critical class (${OPERATOR_CRITICAL_CLASSES.join(", ")})` : `round-critical: ${o.finding} carries no operator-critical class`);
    const q = await quoteRule(specs, key, o.decision, o.quote, rows.some(r => r.row === "critical" && String(r.decision) === o.decision), latestRoundTs(rows));
    if ("error" in q) throw new Error(`round-critical: ${q.error}`);
    if (rows.checked.criticals.some(r => r.id === o.finding && r.return_sha === hit.return_sha)) throw new Error(`round-critical: ${o.finding} was already ruled on`);
    await appendRow(specs, key, { row: "critical", epoch: rows.checked.epoch, opens: o.noRound ? 0 : writerRound(rows) + 1, id: o.finding, class: hit.f.critical, decision: o.decision, quote: o.quote, decision_path: q.path, decision_sha: q.sha, return_sha: hit.return_sha });
  });
}

export async function roundReset(specs: string, key: string, o: { decision: string; quote: string }): Promise<void> {
  needConsole("round-reset");
  await withLedgerLock(specs, key, async () => {
    const rows = await loadLedger(specs, key);
    if (rows.some(r => r.row === "reset")) throw new Error(`round-reset: ${key} already used its one reset`);
    const q = await quoteRule(specs, key, o.decision, o.quote, false, latestRoundTs(rows));
    if ("error" in q) throw new Error(`round-reset: ${q.error}`);
    await appendRow(specs, key, { row: "reset", epoch: rows.checked.epoch + 1, decision: o.decision, quote: o.quote, decision_path: q.path, decision_sha: q.sha });
  });
}

const headingOf = async (verdictPath: string, id: string) => (await readFile(verdictPath, "utf8").catch(() => "")).split("\n").find(l => FINDING_LINE.exec(l)?.[1] === id);

export async function closurePack(specs: string, key: string, kind: Kind): Promise<string> {
  const rows = await loadLedger(specs, key);
  const r = kindRound(rows, kind) + 1;
  const refusal = capRefusal(key, rows, kind, r);
  if (refusal) throw new Error(refusal);
  if (r <= CRITIC_ROUND_CAP) throw new Error(`closure-pack: ${key} ${kind} round ${r} is a full round, not a closure check`);
  const prev = roundBefore(rows, kind, r);
  const snaps = await snapshotsOf(specs, key, prev.sealed);
  const out = [closureMarker(key, kind, r, prev.returns[0].return_sha), "", "## open blocking findings"];
  const named = new Set<string>();
  for (const b of openBlocking(rows)) { named.add(b.id); out.push((await headingOf(b.verdict_path, b.id)) ?? `- **${b.id}** (${b.severity})`); }
  for (const c of rows.checked.criticals.filter(x => Number(x.opens) === r)) {
    const f = findingOf(rows, String(c.id));
    if (!named.has(String(c.id)) && f) out.push((await headingOf(f.verdict_path, String(c.id))) ?? `- **${c.id}** (${f.f.severity}; operator-critical: ${f.f.critical})`);
  }
  out.push("", `## files round ${r - 1} read (sha256)`, ...prev.sealed.map(s => `${s.read_sha}  ${s.read_path}`), "", `## diff against the round ${r - 1} snapshots`);
  for (const s of prev.sealed) {
    const snap = snaps.get(s.read_path);
    out.push(snap ? (await diffOf(snap, s.read_path, basename(s.read_path))).trimEnd() || `(${basename(s.read_path)} is unchanged)` : `(no snapshot of ${s.read_path}; no diff)`);
  }
  return `${out.join("\n")}\n`;
}

export async function foldList(specArg: string, specsArg?: string): Promise<string[]> {
  const spec = await realpath(specArg).catch(() => resolve(specArg));
  const key = keyOf(spec);
  if (!key) throw new Error(`${spec}: has no ticket key; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
  const specs = specsArg ? await realpath(specsArg) : specsRootOf(spec);
  if (!specs) throw new Error(`${spec}: sits under no specs folder, so it has no round ledger`);
  const rows = await loadLedger(specs, key);
  const out: string[] = []; const seen = new Set<string>();
  const add = (f: { id: string; severity: string; tag?: string }, kind: Kind, round: number, path: string) => {
    if (seen.has(f.id)) return;
    seen.add(f.id); out.push(`- ${f.id} (${f.severity}${f.tag ? `; ${f.tag}` : ""}) ${kind} r${round} ${path}`);
  };
  const tagOf = (f: Finding) => [f.class === "out-of-closure" ? "out-of-closure" : "", f.reopens ? `reopens ${f.reopens}` : "", f.regression ? "regression" : "", f.critical ? `operator-critical: ${f.critical}` : ""].filter(Boolean).join("; ");
  for (const kind of KINDS) {
    const rounds = [...seededReturns(rows, kind).map(s => ({ ...s, round: Number(seedOf(rows)?.[kind]) || 0 })), ...roundRows(rows, kind).map(r => ({ ...r, round: Number(r.round), verdict_path: String(r.verdict_path), findings: r.findings as Finding[], unrated_ids: r.unrated_ids as string[], mode: String(r.mode) }))]
      .sort((a, b) => a.round - b.round);
    const full = rounds.filter(r => r.mode !== "closure").at(-1);
    for (const f of full?.findings ?? []) if (!isBlocking(f)) add({ ...f, tag: tagOf(f) }, kind, full!.round, full!.verdict_path);
    for (const c of rounds.filter(r => r.mode === "closure" && (!full || r.round > full.round))) {
      for (const f of c.findings ?? []) add({ ...f, tag: tagOf(f) }, kind, c.round, c.verdict_path);
      for (const id of c.unrated_ids ?? []) add({ id, severity: "unrated" }, kind, c.round, c.verdict_path);
    }
    const last = rounds.at(-1);
    if (last) for (const b of blockingOf(last)) { const f = (last.findings ?? []).find(x => x.id === b.id); add({ id: b.id, severity: b.severity, tag: f ? tagOf(f) : "" }, kind, last.round, last.verdict_path); }
  }
  return out;
}

const CRITIC_NAME = /^(.+?)\.critic-(?:(spec|plan)-)?r(\d+)[a-z]?\.md$/;
type SeedResult = { keys: Record<string, { spec: number; plan: number }>; skipped: string[] };
export async function roundSeed(rootArg: string): Promise<SeedResult> {
  const given = resolve(rootArg);
  if (!await stat(given).then(s => s.isDirectory(), () => false)) throw new Error(`round-seed: ${given} is not a folder`);
  const specs = await realpath(given);
  if (basename(specs) !== "specs") throw new Error(`round-seed: ${specs} is not a specs root; seals look for the ledger under the last folder named specs`);
  return withLedgerLock(specs, "round-seed", () => seedRoot(specs));
}
async function seedRoot(specs: string): Promise<SeedResult> {
  const dir = ledgerDir(specs);
  for (const n of await listDir(dir)) if (n === "manifest.json" || n.endsWith(".jsonl") || await stat(join(dir, n)).then(s => s.isDirectory(), () => false)) throw new Error(`round-seed: ${dir} already holds a ledger, snapshot or manifest`);
  const folders = [...SIGNATURE_DIRS].map(d => join(specs, d));
  for (const n of await listDir(specs)) if (KEY_FOLDER.test(n) && await stat(join(specs, n)).then(s => s.isDirectory(), () => false)) folders.push(join(specs, n));
  const found = new Map<string, Record<Kind, { round: number; path: string; text: string }[]>>();
  const skipped: string[] = [];
  for (const folder of folders) {
    for (const name of await listDir(folder)) {
      const m = CRITIC_NAME.exec(name);
      if (!m || !await isFile(join(folder, name))) continue;
      const path = join(folder, name); const key = keyOf(join(folder, m[1]));
      if (!key) { skipped.push(`${path} (no ticket key in its name)`); continue; }
      const text = await readFile(path, "utf8");
      const kind = verdictKind(lastLine(text)) ?? (m[2] as Kind | undefined);
      if (!kind) { skipped.push(`${path} (no verdict line, so no kind)`); continue; }
      const k = found.get(key) ?? { spec: [], plan: [] }; found.set(key, k);
      k[kind].push({ round: Number(m[3]), path, text });
    }
  }
  const keys: Record<string, { spec: number; plan: number }> = {}; const seeds = new Map<string, LedgerRow>();
  const snapshots: { key: string; sum: string; bytes: Uint8Array }[] = [];
  for (const [key, byKind] of [...found].sort(([a], [b]) => (a < b ? -1 : 1))) {
    const row: LedgerRow = { v: 1, ts: Date.now(), key, row: "seed", spec: 0, plan: 0, latest: { spec: [], plan: [] } };
    for (const kind of ["spec", "plan"] as const) {
      const top = Math.max(0, ...byKind[kind].map(f => f.round));
      row[kind] = top;
      for (const f of byKind[kind].filter(x => x.round === top).sort((a, b) => (a.path < b.path ? -1 : 1))) {
        const seals: SeededReturn["seals"] = [];
        for (const s of sealsOf(f.text)) {
          const abs = resolve(dirname(f.path), s.rel);
          const read_path = await realpath(abs).catch(() => abs);
          seals.push({ read_path, read_sha: s.sha });
          const bytes = await readFile(read_path).catch(() => null);
          if (bytes && sha256(bytes) === s.sha) snapshots.push({ key, sum: s.sha, bytes });
        }
        const { findings, unrated_ids } = parseFindings(f.text, kind, top);
        row.latest[kind].push({ return_sha: returnSha(f.text), verdict_path: f.path, seals, findings, unrated_ids, verdict: lastLine(f.text) } satisfies SeededReturn);
      }
    }
    keys[key] = { spec: row.spec, plan: row.plan }; seeds.set(key, row);
  }
  const made: string[] = [];
  const write = async (path: string, data: string) => { if (!await createNew(path, data, made)) throw new Error(`round-seed: ${path} appeared while seeding`); };
  try {
    await mkdir(dir, { recursive: true });
    for (const s of snapshots) await snapshotBytes(specs, s.key, s.bytes, s.sum, made);
    for (const [key, row] of seeds) await write(join(dir, `${key}.jsonl`), `${JSON.stringify(row)}\n`);
    await write(join(dir, "manifest.json"), `${JSON.stringify({ v: 1, ts: Date.now(), keys })}\n`);
  } catch (e) {
    for (const path of made.reverse()) await rm(path, { force: true });
    for (const key of found.keys()) await rmdir(join(dir, key)).catch(() => {});
    throw e;
  }
  return { keys, skipped };
}

// Whichever spec governs the page, the latest plan critic of ANY spec that seals it must be clean: a
// failed one refuses the send, so the file name of a spec cannot decide which critic is heard. Past that
// spec's plan rounds it does not refuse: its return is handed back, to go on the page.
async function refuseIfPlanCriticFailed(page: string): Promise<string[]> {
  const open: string[] = [];
  const latest = new Map<string, { round: number; files: string[] }>();
  for (const dir of criticDirs(page)) {
    for (const n of await listDir(dir)) {
      const m = /^(.+)\.critic-plan-r(\d+)\.md$/.exec(n);
      if (!m) continue;
      const round = Number(m[2]); const cur = latest.get(m[1]);
      if (!cur || round > cur.round) latest.set(m[1], { round, files: [join(dir, n)] });
      else if (round === cur.round) cur.files.push(join(dir, n));
    }
  }
  for (const { files } of latest.values()) {
    for (const file of files) {
      const text = await readCritic(file);
      const last = lastLine(text);
      if (last === CLEAN.plan) continue;
      for (const seal of sealsOf(text)) {
        if (await realpath(resolve(dirname(file), seal.rel)).catch(() => "") !== page) continue;
        const spec = join(dirname(file), basename(file).replace(/\.critic-plan-r\d+\.md$/, ""));
        const key = keyOf(spec); const specs = specsRootOf(spec);
        const planRound = key && specs ? (await roundState(specs, key)).plan : 0;
        if (!FINDINGS.plan.test(last) || planRound < CRITIC_ROUND_CAP) throw new Error(`${file}: the latest plan critic that seals ${basename(page)} ended '${last}', not '${CLEAN.plan}'; the page is not sent`);
        open.push(file);
        break;
      }
    }
  }
  return open;
}

// null = nothing is filed for the page. An unreadable critic file or folder throws.
async function governingSpec(page: string): Promise<{ spec: string; role: Role } | null> {
  // A rendering is governed by the .md beside it, before any critic file of its own: a critic file beside the
  // .html cannot stand in for an .md that has none (a plain report.html beside a critic-less report.md stays no signature page).
  const md = siblingMd(page);
  if (md && await isFile(md)) {
    const c = await latestCritics(md);
    if (c.spec || c.plan) return { spec: md, role: "render" };
    const own = await latestCritics(page);
    if (own.spec || own.plan) return { spec: md, role: "render" };
  }
  // A plan in a plans folder is governed by the same-named spec in a sibling design folder, when that spec has critic files.
  if (["plan", "plans"].includes(basename(dirname(page)))) {
    for (const d of ["design", "designs", "spec"]) {
      const spec = join(dirname(dirname(page)), d, basename(page));
      if (await isFile(spec) && (await latestCritics(spec)).spec) return { spec, role: "plan" };
    }
  }
  const own = await latestCritics(page);
  if (own.spec || own.plan) return { spec: page, role: "spec" };
  for (const dir of criticDirs(page)) {
    for (const n of await listDir(dir)) {
      const m = /^(.+)\.critic-plan-r\d+\.md$/.exec(n);
      if (!m) continue;
      const file = join(dir, n);
      const text = await readCritic(file);
      for (const seal of sealsOf(text)) if (await realpath(resolve(dir, seal.rel)).catch(() => "") === page) return { spec: join(dir, m[1]), role: "plan" };
    }
  }
  return null;
}

// The .md a page names as its source, or null for a page that names none. A marker that is not an absolute path, or names a file that is not there, refuses.
async function markedSource(page: string): Promise<string | null> {
  if (!/\.html?$/i.test(page)) return null;
  let named: string | null = null;
  for (const tag of (await readFile(page)).toString("utf8").matchAll(/<meta\b[^>]*>/gi)) {
    const attrs = new Map<string, string>();
    for (const a of tag[0].matchAll(/([a-z][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/gi)) attrs.set(a[1].toLowerCase(), a[2] ?? a[3] ?? a[4]);
    if (attrs.get("name")?.toLowerCase() === "spec-source") { named = (attrs.get("content") ?? "").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"); break; }
  }
  if (named === null) return null;
  if (!isAbsolute(named)) throw new Error(`${basename(page)} names its source as '${named}', which is not an absolute path; the page is not sent`);
  const real = await realpath(named).catch(() => null);
  if (!real || !await isFile(real)) throw new Error(`${basename(page)} names its source as ${named}, which is not there; the page is not sent`);
  return real;
}

export type VerdictLine = { kind: "spec" | "plan"; round: number; file: string; verdict: string };

// null = not a signature page (sends as before); throws, naming the verdict file, when the page may not be sent.
// `bytes` are the page's bytes as read once here: the caller sends THOSE, so an edit after the check cannot slip through.
// `lead` is the block of open findings a page past its critic rounds opens with, empty otherwise.
export async function checkSignaturePage(abs: string): Promise<{ verdicts: VerdictLine[]; bytes: Buffer; lead: string } | null> {
  const page = await realpath(abs).catch(() => abs);
  const open = new Set(await refuseIfPlanCriticFailed(page));
  // A page that names its source (`<meta name="spec-source" content="<abs path of the .md>">`) is governed by that spec wherever the copy sits.
  // ponytail: a hand-built page with no marker, outside the registered folders, reads as a report, upgrade path: one shared spec page generator writes the marker
  const source = await markedSource(page);
  let g = source ? { spec: source, role: "render" as Role } : await governingSpec(page);
  if (!g) {
    if (![abs, page].some(underSignaturePath)) return null;
    const md = siblingMd(page);
    g = md && await isFile(md) ? { spec: md, role: "render" } : { spec: page, role: "spec" };
  }
  const { spec, role } = g;
  const specReal = await realpath(spec).catch(() => spec);
  const bytes = await readFile(page);
  if (new RegExp(NOT_FOR_SIGNATURE, "i").test(bytes.toString("utf8"))) throw new Error(`${basename(page)} still says "Not for signature"; a page a critic passed must not, and the critic must read the final bytes; the page is not sent`);
  const critics = await latestCritics(spec);
  for (const kind of KINDS) if (!critics[kind]) throw new Error(`${basename(page)} is a spec or plan page and has no ${kind} critic file (${spec}.critic-${kind}-r<n>.md); run the ${kind} critic first`);
  const key = keyOf(specReal); const specs = specsRootOf(specReal);
  if (!key || !specs) throw new Error(`${spec}: has no ticket key under a specs folder, so its rounds cannot be read from a ledger; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/; the page is not sent`);
  const state = await roundState(specs, key);
  const mayGoOpen = (kind: Kind, line: string) => FINDINGS[kind].test(line) && state[kind] >= CRITIC_ROUND_CAP;
  const verdicts: VerdictLine[] = []; const verified = new Map<string, string>();
  for (const kind of KINDS) {
    const c = critics[kind]!;
    let governing: { path: string; text: string; lv: LedgerVerdict } | null = null; let refusal: unknown = null;
    for (const path of [c.path, ...c.tied]) {
      try {
        const text = await readCritic(path);
        if (!sealsOf(text).length) throw new Error(`${path} has no CONTENT-SHA256 line, so it does not record the bytes it read (chief-kit/critic-seal.sh adds it); the page is not sent`);
        governing = { path, text, lv: await verifyReturn(await realpath(path), text, { spec: specReal }) };
        break;
      } catch (e) { refusal ??= e; }
    }
    if (!governing) throw refusal;
    const text = governing.text;
    const last = lastLine(text);
    if (last !== CLEAN[kind] && !mayGoOpen(kind, last)) throw new Error(`${governing.path}: the latest ${kind} critic ended '${last}', not '${CLEAN[kind]}'; the page is not sent`);
    if (last !== CLEAN[kind]) { open.add(governing.path); verified.set(governing.path, text); }
    for (const other of [c.path, ...c.tied]) if (other !== governing.path && lastLine(await readCritic(other)) !== CLEAN[kind]) open.add(other);
    const seals = sealsOf(text);
    const sealed = new Set<string>();
    for (const seal of seals) {
      const file = await realpath(resolve(dirname(governing.path), seal.rel)).catch(() => null);
      if (!file) throw new Error(`${governing.path}: the file it seals (${seal.rel}) is missing; the page is not sent`);
      if (sha256(file === page ? bytes : await readFile(file)) !== seal.sha) throw new Error(`${governing.path}: ${seal.rel} changed since the ${kind} critic read it; re-run the critic`);
      sealed.add(file);
    }
    if (kind === "spec" && !sealed.has(specReal)) throw new Error(`${governing.path} does not seal ${basename(spec)}`);
    if (kind === "spec" && source && !seals.some(s => s.sha === sha256(bytes))) throw new Error(`${governing.path} has no seal for the bytes of ${basename(page)}: the critic of the latest round never read this page`);
    if (kind === "spec" && role === "render" && !source && !sealed.has(page)) throw new Error(`${governing.path} has no seal naming ${basename(page)}: the critic of the latest round never read this page`);
    if (kind === "plan" && role === "plan" && !sealed.has(page)) throw new Error(`${governing.path} does not seal ${basename(page)}`);
    verdicts.push({ kind, round: governing.lv.round, file: basename(governing.path), verdict: last });
  }
  return { verdicts, bytes, lead: open.size || state.critical_open.length ? await openFindingsBlock(open, state, verified, state.critical_open) : "" };
}

// The operator rules on this page rather than signing it (decision 734), so it opens by saying so, and with the
// return of each critic that did not end clean, verbatim: a return is free prose, so no parser could list its findings one by one.
async function openFindingsBlock(open: Set<string>, rounds: Record<Kind, number>, verified: Map<string, string>, critical: RoundState["critical_open"] = []): Promise<string> {
  const returns = await Promise.all([...open].map(async file => {
    const text = verified.get(file) ?? await readCritic(file);
    return `<h2>${esc(basename(file))}: ${esc(lastLine(text))}</h2>\n<pre style="white-space:pre-wrap">${esc(text.split("\n").filter(l => !l.startsWith("CONTENT-SHA256 ")).join("\n"))}</pre>\n`;
  }));
  return `<section class="open-findings">
<p><strong>Round count: spec ${rounds.spec}, plan ${rounds.plan}. ${open.size} critic${open.size === 1 ? "" : "s"} did not end clean.</strong></p>
${critical.length ? `<p><strong>Open operator-critical findings:</strong> ${critical.map(c => esc(`${c.id} (${c.class})`)).join(", ")}. The signature is refused until you rule on each.</p>\n` : ""}<p><strong>Rule, don't just sign.</strong> These findings are still open. Rule on each one and add what is missing. Minors and mediums go to the build; a critic round past the cap needs a blocking finding in round 3, then a chief override or an operator-critical ruling.</p>
${returns.join("")}</section>
`;
}

// The tokens a head may hold before <body>, read as a browser reads them: a comment, a doctype or end tag, the text of a raw element, a start tag whose quoted attributes may hold anything.
// A quote opens a value only right after "=": elsewhere it is an ordinary character, as it is in a browser.
const ATTRS = `(?:=\\s*(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\\s>]*)|[^>=])*(?:>|$)`;
const HEAD_TOKENS = new RegExp(`<!--[\\s\\S]*?(?:-->|$)|<[!?][^>]*(?:>|$)|</${ATTRS}|<(title|style|script|noscript)(?=[\\s/>])${ATTRS}[\\s\\S]*?(?:</\\1(?=[\\s/>])${ATTRS}|$)|<([a-z][^\\s/>]*)${ATTRS}`, "gi");

// Where the page's real <body> start tag ends, or null when that cannot be told: a start tag no head holds comes first
// (it may hide what follows), the tag never closes, or a script holds "<!--" (what looks like its end tag may not be one).
function bodyTagEnd(html: string): number | null {
  for (const t of html.matchAll(HEAD_TOKENS)) {
    if (t[1]?.toLowerCase() === "script" && t[0].includes("<!--")) return null;
    const tag = t[2]?.toLowerCase();
    if (!tag) continue;
    if (tag === "body") { const end = t.index + t[0].length; return end < html.length ? end : null; }
    if (!["html", "head", "meta", "link", "base"].includes(tag)) return null;
  }
  return null;
}

// A sealed .html page goes as its sealed bytes with the block right after <body>; a page with nowhere to put the block does not go.
function withLead(page: Buffer, lead: string, name: string): Buffer {
  const html = page.toString("utf8");
  const end = bodyTagEnd(html);
  if (end === null) throw new Error(`${name} has no <body> tag that can be told apart to carry its open findings; the page is not sent`);
  const at = end + /^\r?\n?/.exec(html.slice(end))![0].length;
  return Buffer.from(html.slice(0, at) + lead + html.slice(at));
}

export function renderMarkdownHtml(md: string, title: string, verdicts?: VerdictLine[], lead = ""): string {
  const banner = verdicts?.length
    ? `<p class="verdict">${verdicts.map(v => `<strong>${esc(v.verdict)}</strong> (round ${v.round}, <code>${esc(v.file)}</code>)`).join("<br>")}</p>\n`
    : "";
  const body = lead + banner + Bun.markdown.html(md, { noHtmlBlocks: true, noHtmlSpans: true });   // raw HTML in the source is shown as text
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<title>${esc(title)}</title>
<style>:root{--bg:#0C1319;--ink:#E1E8EE;--mute:#9DADBA;--code:#121B23;--rule:#60727F;color-scheme:dark}body{background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:0 auto;padding:1rem;overflow-wrap:anywhere}pre{background:var(--code);padding:.75rem;overflow-x:auto}code{font-family:ui-monospace,monospace;font-size:.9em}table{border-collapse:collapse;display:block;overflow-x:auto}th,td{border:1px solid var(--rule);padding:.3rem .5rem}blockquote{border-left:4px solid var(--rule);margin-left:0;padding-left:1rem;color:var(--mute)}@media print{:root{--bg:#fff;--ink:#000;--mute:#555;--code:#f4f4f4;--rule:#bbb;color-scheme:light}}</style>
</head><body>
${body}</body></html>
`;
}

const EARLY_CAPTION = "NOT PASSED - not for signature (sent on request)";
function notPassedBlock(abs: string, request: string): string {
  const asked = request.trim();
  if (!asked) throw new Error("--by-request names no request; give the operator's request in words, or send without it (a page that has not passed is then refused)");
  if (!/\.(md|markdown|html?)$/i.test(abs)) throw new Error(`--by-request carries its mark only on a .md or .html page; ${basename(abs)} is neither, send it without --by-request`);
  return `<section class="not-passed"><p><strong>NOT PASSED. ${NOT_FOR_SIGNATURE}.</strong> Critic approval was not checked for this delivery. It is sent early because the operator asked: ${esc(asked)}</p></section>\n`;
}

export async function queueFile(root: string, chat: number, path: string, caption?: string, byRequest?: string): Promise<string> {
  const abs = resolve(path);
  const tooBig = (size: number) => new Error(`file is ${(size / 1048576).toFixed(1)} MB, over the Telegram 50 MB upload limit: ${path}`);
  const st = await stat(abs).catch(() => null);
  if (!st) throw new Error(`file not found: ${path}`);
  if (!st.isFile()) throw new Error(`not a regular file: ${path}`);
  if (st.size > MAX_SEND_BYTES) throw tooBig(st.size);
  const early = byRequest === undefined ? null : notPassedBlock(abs, byRequest);
  const signed = early ? null : await checkSignaturePage(abs);
  // The caption opens with the verdicts read from the critic files; the caller's words follow, never replace them.
  const verdictCaption = early ? EARLY_CAPTION : signed?.verdicts.map(v => `${v.verdict} r${v.round}`).join(" | ");
  if (verdictCaption) caption = caption ? `${verdictCaption} - ${caption}` : verdictCaption;
  const isMd = /\.(md|markdown)$/i.test(abs);
  if (signed?.lead && !isMd && !/\.html?$/i.test(abs)) throw new Error(`${basename(abs)} cannot carry its open findings (only .md and .html can); the page is not sent`);
  const sealedPage = signed && !isMd ? (signed.lead ? withLead(signed.bytes, signed.lead, basename(abs)) : signed.bytes) : early && !isMd ? withLead(await readFile(abs), early, basename(abs)) : null;
  // Every file is COPIED (or rendered) into <bridge root>/outgoing/<id>/: the poller ships only from there.
  const dir = join(root, "outgoing", randomUUID());
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const send = join(dir, isMd ? `${basename(abs).replace(/\.(md|markdown)$/i, "")}.html` : basename(abs));
  if (isMd) await Bun.write(send, renderMarkdownHtml(signed ? signed.bytes.toString("utf8") : await readFile(abs, "utf8"), basename(abs), signed?.verdicts, signed?.lead ?? early ?? ""));
  else if (sealedPage) await Bun.write(send, sealedPage);
  else await copyFile(abs, send);
  const size = (await stat(send)).size;
  if (size > MAX_SEND_BYTES) { await rm(dir, { recursive: true, force: true }); throw tooBig(size); }
  const { sendFileViaOutbox } = await import("./poller");
  await sendFileViaOutbox(root, chat, send, caption);
  return send;
}

export type MsgClass = "escalate" | "monitor" | "silent";
type ClassRow = { kind: string; class: MsgClass; cap?: number | "none"; "ref-word"?: string };
type ClassTable = { cap: number; rows: ClassRow[] };
const KIND_RE = /^[a-z0-9][a-zA-Z0-9:._-]{0,95}$/;
const FAMILY_RE = /^cadence:[a-z0-9]+-[a-z0-9]+-/;

const classTablePath = () => (process.env.HIMMEL_TEST_FIXTURE === "1" && process.env.HIMMEL_MESSAGE_CLASSES) || join(import.meta.dir, "message-classes.json");
const mirrorRoot = () => (process.env.HIMMEL_JIRA_MIRROR ? dirname(process.env.HIMMEL_JIRA_MIRROR) : join(homedir(), ".himmel", "state", "jira-mirror"));

export async function loadClassTable(path = classTablePath()): Promise<ClassTable | null> {
  try {
    const t = JSON.parse(await readFile(path, "utf8"));
    if (!t || !Array.isArray(t.kinds)) return null;
    const rows = t.kinds.filter((r: ClassRow) => r && typeof r.kind === "string" && (r.class === "escalate" || r.class === "monitor" || r.class === "silent"));
    return { cap: Number.isSafeInteger(t.cap) && t.cap > 0 ? t.cap : 400, rows };
  } catch { return null; }
}

export function resolveKind(table: ClassTable | null, kind: string | undefined): ClassRow | null {
  if (!table || kind === undefined || !KIND_RE.test(kind)) return null;
  const exact = table.rows.find((r) => r.kind === kind);
  if (exact) return exact;
  return table.rows.find((r) => r.kind.endsWith("*") && r.kind.indexOf("*") === r.kind.length - 1 && FAMILY_RE.test(r.kind) && kind.startsWith(r.kind.slice(0, -1))) ?? null;
}

async function capText(text: string, kind: string, cap: number, root: string): Promise<{ text: string; state: "ok" | "cut" | "over-cap-uncut" }> {
  if (text.length <= cap) return { text, state: "ok" };
  const uncut = { text, state: "over-cap-uncut" as const };
  const doAt = findDo(text);
  if (doAt < 0) return uncut;
  const pre = text.slice(0, doAt); const doSeg = text.slice(doAt);
  const dir = join(root, "route-cut");
  const file = join(dir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${kind.replace(/[^A-Za-z0-9_-]/g, "_")}.txt`);
  const suffix = `... (full text on the station: ${file})`;
  let i = Math.min(cap - suffix.length - doSeg.length, pre.length);
  const spans = protectedRanges(pre);
  for (;;) {
    while (i > 0 && pre[i] !== " " && pre[i] !== "\n") i--;
    if (i <= 0) return uncut;
    const span = spans.find(([s, e]) => i > s && i < e);
    if (!span) break;
    i = span[0];
  }
  await mkdir(dir, { recursive: true });
  await writeFile(file, text, { mode: 0o600, flag: "wx" });
  return { text: `${pre.slice(0, i).trimEnd()}${suffix}${doSeg}`, state: "cut" };
}

export async function routeReply(root: string, chatId: number, text: string, o: { kind?: string; consoleName?: string; dest: string }): Promise<MsgClass> {
  const { replyViaOutbox } = await import("./poller");
  const kind = o.kind !== undefined && KIND_RE.test(o.kind) ? o.kind : undefined;
  let cls: MsgClass = "escalate"; let logClass: string = "escalate"; let sent = text; let capState = "ok"; let keys = 0;
  try {
    const table = await loadClassTable();
    const row = resolveKind(table, kind);
    cls = row?.class ?? "escalate";
    if (cls !== "silent") {
      const b = briefTextCounted(text, mirrorRoot(), row?.["ref-word"] ?? "PR");
      sent = b.text; keys = b.keys;
    }
    // ponytail: a word match, upgrade path = run scripts/handover/chief-kit/salus_marked.py on every path the text names
    if (cls === "monitor" && /salus/i.test(sent)) cls = "escalate";
    if (cls === "escalate" && row && row.cap !== "none") {
      const c = await capText(sent, kind!, table!.cap, root);
      sent = c.text; capState = c.state;
    }
    if (cls === "monitor") {
      await mkdir(join(root, "monitor"), { recursive: true });
      await appendFile(join(root, "monitor", "outbox.jsonl"), `${JSON.stringify({ text: sent, kind, at: new Date().toISOString() })}\n`, { mode: 0o600 });
    }
    logClass = cls;
  } catch (e) {
    console.error(`[chief-route] routing failed, sending the raw text to the operator: ${e instanceof Error ? e.message : e}`);
    cls = "escalate"; logClass = "escalate-fallback"; sent = text; capState = "ok";
  }
  if (cls === "escalate") await replyViaOutbox(root, chatId, sent, o.consoleName);
  const dest = cls === "escalate" ? o.dest : cls === "monitor" ? "monitor" : "none";
  try {
    await mkdir(root, { recursive: true });
    await appendFile(join(root, "route.log"), `${new Date().toISOString()} ${kind ?? "unclassified"} ${logClass} ${dest} ${sent.length} ${keys} ${capState}\n`);
  } catch (e) { console.error(`[chief-route] route log not written: ${e instanceof Error ? e.message : e}`); }
  return cls;
}

export async function latestReceiptId(root: string, chat: number, name: string): Promise<number> {
  let best = 0;
  for (const f of await readdir(join(root, "consoles", "replies")).catch(() => [] as string[])) {
    const m = /^(-?\d+)_(\d+)\.json$/.exec(f);
    if (m && Number(m[1]) === chat && Number(m[2]) > best && await consoleReplyTarget(root, chat, Number(m[2])) === name) best = Number(m[2]);
  }
  return best;
}

export async function awaitSendReceipt(root: string, chat: number, name: string, afterId: number, waitSec: number): Promise<number | null> {
  const deadline = Date.now() + waitSec * 1000;
  for (;;) {
    const id = await latestReceiptId(root, chat, name);
    if (id > afterId) return id;
    if (Date.now() >= deadline) return null;
    await new Promise(r => setTimeout(r, 200));
  }
}

export async function writeOwedReceipt(doc: string, key: string, messageId: number, chat: number): Promise<void> {
  const cur = await readFile(doc, "utf8");
  await appendFile(doc, `${cur === "" || cur.endsWith("\n") ? "" : "\n"}- ${hhmm()} DELIVERED ${key} msg=${messageId} chat=${chat}\n`);
}

const VERB_FLAGS: Record<string, { valued: string[]; bare: string[] }> = {
  "closure-pack": { valued: ["--specs"], bare: [] },
  "round-override": { valued: ["--findings", "--why", "--chief", "--specs"], bare: [] },
  "round-critical": { valued: ["--finding", "--decision", "--quote", "--specs"], bare: ["--no-round"] },
  "round-reset": { valued: ["--decision", "--quote", "--specs"], bare: [] },
  "fold-list": { valued: ["--spec", "--specs"], bare: [] },
};
function verbArgs(args: string[], valued: string[], bare: string[], positionals: number): { opts: Record<string, string>; on: Set<string>; pos: string[] } | null {
  const opts: Record<string, string> = {}; const on = new Set<string>(); const pos: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (valued.includes(a) && i + 1 < args.length && opts[a] === undefined) opts[a] = args[++i];
    else if (bare.includes(a) && !on.has(a)) on.add(a);
    else pos.push(a);
  }
  return pos.length === positionals ? { opts, on, pos } : null;
}

function roundStatusArgs(args: string[]): { key: string | null; specs: string; json: boolean } | null {
  const rest = [...args]; let specs: string | undefined; let json = false; let all = false; const words: string[] = [];
  while (rest.length) {
    const a = rest.shift()!;
    if (a === "--specs" && rest.length && specs === undefined) specs = rest.shift()!;
    else if (a === "--json" && !json) json = true;
    else if (a === "--all" && !all) all = true;
    else words.push(a);
  }
  if (all) return words.length === 0 && specs !== undefined && json ? { key: null, specs, json } : null;
  if (words.length !== 1 || !KEY_FOLDER.test(words[0])) return null;
  const root = specs ?? specsRootOf(process.cwd());
  return root ? { key: words[0], specs: root, json } : null;
}

// CLI: `bun chief-route.ts send-file <chat_id> <path> [caption...]` queues a file (above).
// CLI: `bun chief-route.ts reply [--chief <name>] [--satellite <entity_id>] <chat_id> <text...>`, the chief's reply
// path. Appends to the same per-chat outbox every other bridge reply uses; the
// running poller flushes it. Dynamic import: poller.ts imports this module, so a
// static import back would be a cycle.
if (import.meta.main) {
  const [verb, ...args] = process.argv.slice(2);
  const byRequest = verb === "send-file" && args[0] === "--by-request" && args.length >= 4 ? args.splice(0, 2)[1] : undefined;
  if (verb === "register" && args.length === 3) {
    await registerConsole(args[0], args[1], args[2]);
  } else if (verb === "announce" && args.length === 1) {
    await announceConsole(args[0]);
  } else if (verb === "send-file" && args.length >= 2 && Number.isSafeInteger(Number(args[0])) && Number(args[0]) !== 0) {
    try { console.log(`queued ${await queueFile(defaultRoot(), Number(args[0]), args[1], args.slice(2).join(" ") || undefined, byRequest)}`); }
    catch (e) { console.error(`[chief-route] send-file refused: ${e instanceof Error ? e.message : e}`); process.exit(1); }
  } else if (verb === "critic-round-check" && args.length === 2) {
    try { await sealRound(args[0], args[1]); }
    catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else if (verb === "ledger-verify" && verbArgs(args, ["--spec"], ["--sign"], 1)) {
    const a = verbArgs(args, ["--spec"], ["--sign"], 1)!;
    try { const r = await ledgerVerify(a.pos[0], { spec: a.opts["--spec"], sign: a.on.has("--sign") }); console.log(`${r.key} ${r.kind} round ${r.round} ${r.mode}`); }
    catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else if (["closure-pack", "round-override", "round-critical", "round-reset", "fold-list"].includes(verb ?? "") && verbArgs(args, VERB_FLAGS[verb!].valued, VERB_FLAGS[verb!].bare, verb === "fold-list" ? 0 : verb === "closure-pack" ? 2 : 1)) {
    const f = VERB_FLAGS[verb!]; const a = verbArgs(args, f.valued, f.bare, verb === "fold-list" ? 0 : verb === "closure-pack" ? 2 : 1)!;
    const need = (flag: string) => { const v = a.opts[flag]; if (v === undefined) throw new Error(`${verb}: ${flag} is required`); return v; };
    try {
      if (verb === "fold-list") { for (const l of await foldList(need("--spec"), a.opts["--specs"])) console.log(l); }
      else {
        const key = a.pos[0]; if (!KEY_FOLDER.test(key)) throw new Error(`${verb}: '${key}' is not a ticket key`);
        const given = a.opts["--specs"] ?? specsRootOf(process.cwd()); if (!given) throw new Error(`${verb}: pass --specs <specs root>`);
        const specs = await realpath(given);
        if (verb === "closure-pack") { if (a.pos[1] !== "spec" && a.pos[1] !== "plan") throw new Error("closure-pack: the kind is spec or plan"); process.stdout.write(await closurePack(specs, key, a.pos[1])); }
        else if (verb === "round-override") await roundOverride(specs, key, { findings: need("--findings").split(",").map(s => s.trim()).filter(Boolean), why: need("--why"), chief: need("--chief") });
        else if (verb === "round-critical") await roundCritical(specs, key, { finding: need("--finding"), decision: need("--decision"), quote: need("--quote"), noRound: a.on.has("--no-round") });
        else await roundReset(specs, key, { decision: need("--decision"), quote: need("--quote") });
      }
    } catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else if (verb === "round-status" && roundStatusArgs(args)) {
    const a = roundStatusArgs(args)!;
    try {
      const specs = await realpath(a.specs);
      if (a.key === null) {
        const manifest = await readManifest(specs);
        const keys = new Set([...Object.keys(manifest.keys), ...(await listDir(ledgerDir(specs))).filter(n => n.endsWith(".jsonl")).map(n => n.slice(0, -".jsonl".length))]);
        const out: Record<string, RoundState | { key: string; error: string }> = {};
        for (const key of [...keys].sort()) out[key] = await roundState(specs, key).catch((e: Error) => ({ key, error: e.message }));
        console.log(JSON.stringify({ cap: CRITIC_ROUND_CAP, classes: OPERATOR_CRITICAL_CLASSES, keys: out }));
      } else {
        const s = await roundState(specs, a.key);
        console.log(a.json ? JSON.stringify(s) : `${s.key} spec=${s.spec} plan=${s.plan} writer=${s.writer} next=${s.next} cap=${s.cap}: ${s.why}${s.invalid.length ? `; invalid: ${s.invalid.join(", ")}` : ""}`);
      }
    } catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else if (verb === "round-seed" && args.length === 2 && args[0] === "--all") {
    try {
      const { keys, skipped } = await roundSeed(args[1]);
      for (const [key, n] of Object.entries(keys)) console.log(`seeded ${key} spec=${n.spec} plan=${n.plan}`);
      for (const s of skipped) console.log(`skipped ${s}`);
    } catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else {
    const flags: { chief?: string; satellite?: string; kind?: string; owed?: string; doc?: string } = {};
    if (verb === "reply") while (args.length >= 2 && (args[0] === "--chief" || args[0] === "--satellite" || args[0] === "--kind" || args[0] === "--owed" || args[0] === "--doc")) flags[args.shift()!.slice(2) as keyof typeof flags] = args.shift()!;
    const owedOk = (flags.owed === undefined && flags.doc === undefined) || (/^[A-Za-z0-9_.-]+$/.test(flags.owed ?? "") && isAbsolute(flags.doc ?? "") && await stat(flags.doc!).then(s => s.isFile(), () => false));
    const name = flags.chief ?? (verb === "reply" ? await currentConsoleName(defaultRoot()) : undefined);
    const satellite = flags.satellite;
    const [chat, ...rest] = args;
    const chatId = chat === "operator" ? (operatorChatId(await loadAccess()) ?? NaN) : Number(chat);
    if (verb === "reply" && Number.isSafeInteger(chatId) && chatId !== 0 && rest.length && owedOk && (flags.owed === undefined || name) && (!name || consoleInboxPath(defaultRoot(), name)) && (satellite === undefined || SATELLITE_ID.test(satellite))) {
      const seenBefore = flags.owed !== undefined && name ? await latestReceiptId(defaultRoot(), chatId, name) : 0;
      const cls = await routeReply(defaultRoot(), chatId, rest.join(" "), { kind: flags.kind, consoleName: name, dest: chat === "operator" ? "operator" : `chat:${chatId}` });
      console.log(cls);
      if (flags.owed !== undefined) {
        if (cls !== "escalate") { console.error(`[chief-route] owed item ${flags.owed}: the text was class ${cls}, not sent to Telegram, so there is no receipt`); process.exit(1); }
        const id = await awaitSendReceipt(defaultRoot(), chatId, name!, seenBefore, Number(process.env.CHIEF_ROUTE_RECEIPT_WAIT_SEC) || 30);
        if (id === null) { console.error(`[chief-route] owed item ${flags.owed}: queued, but the poller recorded no send receipt in time (poller down or Telegram refused); nothing marked delivered`); process.exit(1); }
        await writeOwedReceipt(flags.doc!, flags.owed, id, chatId);
        console.log(`delivered msg=${id}`);
      }
      if (satellite !== undefined && cls !== "silent") {
        try { await speakOnSatellite(satellite, rest.join(" ")); }
        catch (e) { console.error(`[chief-route] queued the Telegram reply but could not speak on ${satellite}: ${e instanceof Error ? e.message : e}`); process.exit(1); }
      }
    } else {
      console.error("usage: bun chief-route.ts reply [--chief <name>] [--satellite <assist_satellite.id>] [--kind <kind>] [--owed <key> --doc <absolute chief doc>] <chat_id | operator> <text> | send-file [--by-request <the operator's request>] <chat_id> <path> [caption] | critic-round-check <verdict-file> <file-the-critic-read> | round-seed --all <specs root> | ledger-verify <verdict-file> [--spec <spec>] [--sign] | closure-pack <KEY> <spec|plan> [--specs <root>] | round-override <KEY> --findings <id,...> --why <line> --chief <session> [--specs <root>] | round-critical <KEY> --finding <id> --decision <d> --quote <words> [--no-round] [--specs <root>] | round-reset <KEY> --decision <d> --quote <words> [--specs <root>] | fold-list --spec <spec> [--specs <root>] | round-status <KEY> [--specs <root>] [--json] | round-status --all --specs <root> --json | register <inbox> <bucket> <project> | announce <inbox>");
      process.exit(1);
    }
  }
}
