import { join, dirname, basename, resolve } from "node:path";
import { readdir, readFile, stat, mkdir, open, unlink } from "node:fs/promises";
import { appendIfExists, atomicWrite, defaultRoot } from "./bus";
import { loadAccess, operatorChatId } from "./gate";
import { BASH_BIN } from "./run";

// Operator Telegram message -> a named RUNNING chief.
//
// A chief runs without --channels on purpose (a second getUpdates consumer
// 409s the bridge), so nothing reaches it today. Instead the poller — the one
// getUpdates consumer, unchanged — appends one line to the chief's own file
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
// allowed chat, typed and not forwarded — gate.ts stays the sole sender gate.
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
// returns for it) — record the link in <inbox>.meta.json if that recurs.
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
// whitespace) — the path is built from this value. The router's charset already
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
  const text = route.verb === "status" ? "fleet status" : `${route.verb}${route.leg ? ` ${route.leg}` : ""}`;
  await routeToConsole(root, msg, { kind: "console", name: target.name, text, thread: true }, (chat, ack, name) => reply(chat, name ? `queued ${text} → chief ${name}${ack.includes(BUSY_NOTE) ? ` — ${BUSY_NOTE}` : ""}` : ack, name));
}

export async function routeToConsole(
  root: string,
  msg: { from: number; chat_id: number },
  route: ConsoleRoute,
  reply: ConsoleReplyFn,
): Promise<void> {
  // The append is the delivery. A failed ack after it must not throw out of
  // handleInbound: handleBatch would tell the operator "could not be queued —
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
  // check — no separate existsSync() step left to race.
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

// CLI: `bun chief-route.ts reply [--chief <name>] [--satellite <entity_id>] <chat_id> <text...>` — the chief's reply
// path. Appends to the same per-chat outbox every other bridge reply uses; the
// running poller flushes it. Dynamic import: poller.ts imports this module, so a
// static import back would be a cycle.
if (import.meta.main) {
  const [verb, ...args] = process.argv.slice(2);
  if (verb === "register" && args.length === 3) {
    await registerConsole(args[0], args[1], args[2]);
  } else if (verb === "announce" && args.length === 1) {
    await announceConsole(args[0]);
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
      console.error("usage: bun chief-route.ts reply [--chief <name>] [--satellite <assist_satellite.id>] <chat_id> <text> | register <inbox> <bucket> <project> | announce <inbox>");
      process.exit(1);
    }
  }
}
