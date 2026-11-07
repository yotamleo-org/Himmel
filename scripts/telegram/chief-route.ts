import { join, dirname, basename, resolve, isAbsolute } from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { hostname } from "node:os";
import { killTree, SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";
import { readdir, readFile, stat, mkdir, open, unlink, copyFile, rm, realpath } from "node:fs/promises";
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
  // Append only to an inbox a chief already armed; never create one, so a typo
  // cannot open a mailbox nobody reads. The append itself is the existence
  // check, no separate existsSync() step left to race.
  const delivered = await appendIfExists(file, `- ${hhmm()} [telegram from=${msg.from} chat=${msg.chat_id}] ${foldLine(text)}`);
  if (!delivered) { await say(`⚠️ no chief "${name}" is listening (it has not armed its inbox) — nothing was sent.`); return; }
  const busy = (await armedConsoles(root)).some(c => c.name === name && c.busy);
  await say(`→ chief ${name}${busy ? ` — queued, ${BUSY_NOTE}` : ""}`, name);
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
// being sent (operator decisions 700 and 701), or, once that kind of critic has had its three
// rounds (decision 763), with each open finding on the page. The critic files sit beside the spec as
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

// The critic rounds a spec has had, per kind (decision 763: three, then the operator). Judge files never
// match. `renamed` holds any other critic return that reads as this spec's: named after it, or sealing a
// file its own critics sealed. Each adds a round of its own, so a new critic name cannot restart the count.
// `also` is a return being sealed now, counted whatever its name. `count` is what the cap on another round reads: the top
// round number plus the renamed returns. `numbered` is what lets a page go with findings: how many numbered returns are on disk,
// so one file named for the third round cannot open a page early, though three planted files still can.
// ponytail: the count is read from the files on disk, so deleting or overwriting critic files lowers it, and a new
// spec file name starts a new count; upgrade path: an append-only ledger written at seal time, keyed on the ticket.
type Rounds = { count: number; numbered: number; renamed: string[] };
// Reads the last name segment only: the spec's own name comes first and may hold the word.
const isJudgeReturn = (name: string) => /(^|[.-])judge[^.]*\.md$/.test(name);
async function criticRounds(spec: string, also?: string): Promise<Record<Kind, Rounds>> {
  const base = basename(spec);
  const files = new Map<string, string>();
  for (const dir of criticDirs(spec)) {
    for (const n of await listDir(dir)) if (/\.critic.*\.md$/.test(n) && !isJudgeReturn(n)) files.set(join(dir, n), await readCritic(join(dir, n)));
  }
  if (also) files.set(also, await readCritic(also));
  const sealedBy = (file: string, text: string) => Promise.all(sealsOf(text).map(s => realpath(resolve(dirname(file), s.rel)).catch(() => "")));
  const isOwn = (file: string) => file === also || basename(file).startsWith(`${base}.critic`);
  const targets = new Set([await realpath(spec).catch(() => spec)]);
  for (const [file, text] of files) if (isOwn(file)) for (const t of await sealedBy(file, text)) if (t) targets.add(t);
  const numbers = { spec: new Set<number>(), plan: new Set<number>() };
  const renamed: Record<Kind, string[]> = { spec: [], plan: [] };
  for (const [file, text] of files) {
    const name = basename(file);
    const m = name.startsWith(`${base}.`) ? /^\.critic-(spec|plan)-r(\d+)\.md$/.exec(name.slice(base.length)) : null;
    if (m && (dirname(file) === dirname(spec) || (m[1] === "plan" && planDirs(spec).includes(dirname(file))))) { numbers[m[1] as Kind].add(Number(m[2])); continue; }
    const kind = verdictKind(lastLine(text));
    if (kind && (isOwn(file) || (await sealedBy(file, text)).some(t => targets.has(t)))) renamed[kind].push(file);
  }
  const rounds = (k: Kind): Rounds => ({ count: Math.max(0, ...numbers[k]) + renamed[k].length, numbered: numbers[k].size, renamed: renamed[k] });
  return { spec: rounds("spec"), plan: rounds("plan") };
}

// One operator record allows one round past the cap: `<spec>.operator-round-r<round>.md` with a line
// `decision <n>`, where specs/decisions/verbatim-decision-<n>-*.txt holds the operator's words.
// ponytail: a chief can write this file itself, so it records a ruling rather than proving one; upgrade path: a `jira release operator` kind.
async function operatorAllowsRound(spec: string, round: number): Promise<boolean> {
  const decision = /^decision (\d+)\s*$/m.exec(await readFile(`${spec}.operator-round-r${round}.md`, "utf8").catch(() => ""))?.[1];
  const parts = spec.split("/"); const specs = parts.lastIndexOf("specs");
  if (!decision || specs < 0) return false;
  return (await listDir([...parts.slice(0, specs + 1), "decisions"].join("/"))).some(n => n.startsWith(`verbatim-decision-${decision}-`));
}

// Refuses a critic return past the cap with no operator record for that round: `critic-seal.sh` runs this before it
// seals. The count is keyed on the spec the read file belongs to, and on the spec the return is named after; the higher wins.
export async function refuseRoundPastCap(verdict: string, readPath: string): Promise<void> {
  const v = await realpath(verdict); const page = await realpath(readPath);
  const kind = verdictKind(lastLine(await readCritic(v)));
  if (!kind || isJudgeReturn(basename(v))) return;
  const source = await markedSource(page);
  const md = siblingMd(page);
  const read = source ?? (await governingSpec(page))?.spec ?? (md && await isFile(md) ? md : page);
  const named = /^(.+?)\.critic/.exec(basename(v))?.[1];
  const specs = new Set([read]);
  if (named && await isFile(join(dirname(v), named))) specs.add(join(dirname(v), named));
  for (const spec of specs) {
    const round = (await criticRounds(spec, v))[kind].count;
    if (round <= CRITIC_ROUND_CAP || await operatorAllowsRound(spec, round)) continue;
    throw new Error(`${basename(spec)} already has ${round - 1} ${kind} critic rounds; round ${round} needs an operator record, ${spec}.operator-round-r${round}.md with a line "decision <n>" naming specs/decisions/verbatim-decision-<n>-*.txt. Send the page to the operator with its findings listed instead`);
  }
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
        if (!FINDINGS.plan.test(last) || (await criticRounds(spec)).plan.numbered < CRITIC_ROUND_CAP) throw new Error(`${file}: the latest plan critic that seals ${basename(page)} ended '${last}', not '${CLEAN.plan}'; the page is not sent`);
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
  const rounds = await criticRounds(spec);
  const mayGoOpen = (kind: Kind, line: string) => FINDINGS[kind].test(line) && rounds[kind].numbered >= CRITIC_ROUND_CAP;
  const verdicts: VerdictLine[] = [];
  for (const kind of ["spec", "plan"] as const) {
    const c = critics[kind];
    if (!c) throw new Error(`${basename(page)} is a spec or plan page and has no ${kind} critic file (${spec}.critic-${kind}-r<n>.md); run the ${kind} critic first`);
    const text = await readFile(c.path, "utf8");
    const last = lastLine(text);
    if (last !== CLEAN[kind] && !mayGoOpen(kind, last)) throw new Error(`${c.path}: the latest ${kind} critic ended '${last}', not '${CLEAN[kind]}'; the page is not sent`);
    if (last !== CLEAN[kind]) {
      open.add(c.path);
      for (const file of rounds[kind].renamed) if (FINDINGS[kind].test(lastLine(await readCritic(file)))) open.add(file);
    }
    for (const tied of c.tied) {
      const tiedLast = lastLine(await readCritic(tied));
      if (tiedLast !== CLEAN[kind] && !mayGoOpen(kind, tiedLast)) throw new Error(`${tied}: a ${kind} critic of the same round ended '${tiedLast}', not '${CLEAN[kind]}'; the page is not sent`);
      if (tiedLast !== CLEAN[kind]) open.add(tied);
    }
    const seals = sealsOf(text);
    if (!seals.length) throw new Error(`${c.path} has no CONTENT-SHA256 line, so it does not record the bytes it read (chief-kit/critic-seal.sh adds it); the page is not sent`);
    const sealed = new Set<string>();
    for (const seal of seals) {
      const file = await realpath(resolve(dirname(c.path), seal.rel)).catch(() => null);
      if (!file) throw new Error(`${c.path}: the file it seals (${seal.rel}) is missing; the page is not sent`);
      if (sha256(file === page ? bytes : await readFile(file)) !== seal.sha) throw new Error(`${c.path}: ${seal.rel} changed since the ${kind} critic read it; re-run the critic`);
      sealed.add(file);
    }
    if (kind === "spec" && !sealed.has(specReal)) throw new Error(`${c.path} does not seal ${basename(spec)}`);
    if (kind === "spec" && source && !seals.some(s => s.sha === sha256(bytes))) throw new Error(`${c.path} has no seal for the bytes of ${basename(page)}: the critic of the latest round never read this page`);
    if (kind === "spec" && role === "render" && !source && !sealed.has(page)) throw new Error(`${c.path} has no seal naming ${basename(page)}: the critic of the latest round never read this page`);
    if (kind === "plan" && role === "plan" && !sealed.has(page)) throw new Error(`${c.path} does not seal ${basename(page)}`);
    verdicts.push({ kind, round: c.round, file: basename(c.path), verdict: last });
  }
  return { verdicts, bytes, lead: open.size ? await openFindingsBlock(open, rounds) : "" };
}

// The operator rules on this page rather than signing it (decision 734), so it opens by saying so, and with the
// return of each critic that did not end clean, verbatim: a return is free prose, so no parser could list its findings one by one.
async function openFindingsBlock(open: Set<string>, rounds: Record<Kind, Rounds>): Promise<string> {
  const returns = await Promise.all([...open].map(async file => {
    const text = await readCritic(file);
    return `<h2>${esc(basename(file))}: ${esc(lastLine(text))}</h2>\n<pre style="white-space:pre-wrap">${esc(text.split("\n").filter(l => !l.startsWith("CONTENT-SHA256 ")).join("\n"))}</pre>\n`;
  }));
  return `<section class="open-findings">
<p><strong>Round count: spec ${rounds.spec.count}, plan ${rounds.plan.count}. ${open.size} critic${open.size === 1 ? "" : "s"} did not end clean.</strong></p>
<p><strong>Rule, don't just sign.</strong> These findings are still open. Rule on each one and add what is missing. One operator record allows one more critic round.</p>
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
    try { await refuseRoundPastCap(args[0], args[1]); }
    catch (e) { console.error(e instanceof Error ? e.message : e); process.exit(1); }
  } else {
    const name = args[0] === "--chief" ? args.splice(0, 2)[1] : verb === "reply" ? await currentConsoleName(defaultRoot()) : undefined;
    const satellite = verb === "reply" && args[0] === "--satellite" ? args.splice(0, 2)[1] : undefined;
    const [chat, ...rest] = args;
    const chatId = Number(chat);
    if (verb === "reply" && Number.isSafeInteger(chatId) && chatId !== 0 && rest.length && (!name || consoleInboxPath(defaultRoot(), name)) && (satellite === undefined || SATELLITE_ID.test(satellite))) {
      const { replyViaOutbox } = await import("./poller");
      await replyViaOutbox(defaultRoot(), chatId, rest.join(" "), name);
      if (satellite !== undefined) {
        try { await speakOnSatellite(satellite, rest.join(" ")); }
        catch (e) { console.error(`[chief-route] queued the Telegram reply but could not speak on ${satellite}: ${e instanceof Error ? e.message : e}`); process.exit(1); }
      }
    } else {
      console.error("usage: bun chief-route.ts reply [--chief <name>] [--satellite <assist_satellite.id>] <chat_id> <text> | send-file [--by-request <the operator's request>] <chat_id> <path> [caption] | critic-round-check <verdict-file> <file-the-critic-read> | register <inbox> <bucket> <project> | announce <inbox>");
      process.exit(1);
    }
  }
}
