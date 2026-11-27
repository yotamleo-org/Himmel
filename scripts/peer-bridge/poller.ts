// The peer bridge poller: the one process that writes every chain file. It
// takes Telegram updates through the admission gate, keeps thread state and
// deadlines, runs the tool-less reader, sends through the egress gate with an
// intent record before every Telegram call, and drains the spool that send.ts,
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import { hostname as osHostname } from "node:os";
import { join } from "node:path";
import { atomicWrite } from "../telegram/bus";
import { CODE_VERSION, Chain, PidLockError, acquirePidLock, drainSpool, readChain, signTap, startIdentity, submitSpool, sweepResults, tapSigOk, verifyChain, writeResult, type IntentRec, type SpoolRec } from "./chain";
import { ConfigError, DEFAULT_BUDGETS, EXIT_CONFIG, addTrustedKey, cardMessage, clampToSchema,loadAllowlist, loadConfig, trustRefusal, type AllowEntry, type Config } from "./config";
import { digestFile, parseAck, writeCursor, type DigestRec, type EffectRec, type JobRec } from "./digests";
import { checkCardOutbound, checkEnvelopeOutbound, checkOutbound, refusalRecord, type OutCtx, type Outcome, type Refusal } from "./egress";
import { OUTCOMES, buildEnvelope, encodeCanonical, type Envelope } from "./envelope";
import { admit, admitCard, admitEnvelope, appendUnknownChat, createGateState, looksLikeCard, looksLikeEnvelope,matchEnvelope, noteAdmitted, noteRate, rebuildFromInbox, type GateState, type PeerCardRec, type PeerEnvRec, type PeerMsgRec } from "./gate";
import { ENV_LINE_RE, mintId } from "./grammar";
import { botIdFromToken, configDir, peersFile, stateDir, utcDay } from "./ids";
import { dueJobs, isTerminal, newInJob, newOutJob, queueDepth, remaining, step, type JobEvent, type SendSpec } from "./jobstate";
import { ReaderLedger, runReader, type Digest, type ModelRoute, type ReaderKind } from "./reader";
import { resolveCapacity, resolveReq, resolveRes, type JobRecord } from "./resolve";
import { currentSigningKey, keyId, publicKeyOf, sign } from "./sign";
import { MAX_OFFERS_PER_DAY, PAIR_OFFER_TTL_MS, offerState, offersOf, offersToday, resultOf, type CardOffer, type OfferResult, type OfferState, type PairRec } from "./pairing";
import { PeerTelegram, RetryAfter, TelegramError } from "./telegram";
import { MAX_AUTO_PER_HOUR, Threads, effectiveRoute, templateLine, type Action, type Route, type ThreadRec, type Transition, type WakeEvent, type WakeLabel } from "./threads";
import { appendNotify, notifyFile, renderChainAlert, renderFallback, renderNotify, type DailyNotify, type Keyboard, type NotifyRec,type ResultNotify, type UnpairedNotify } from "./notify";
import { DRAFT_TTL_MS, MAX_CHIEF_PER_DAY, MAX_DRAFTS_PER_DAY, MAX_PENDING_CHIEF, MAX_PENDING_DRAFTS, badChars, draftState, draftsToday, pendingCount, reviewTooLong } from "./drafts";
import { lockdownEnabled } from "../telegram/lockdown";
import { Tripwire, Waker } from "./wake";

export type TgLike = Pick<PeerTelegram, "getUpdates" | "sendMessage" | "getChatMember"> & Partial<Pick<PeerTelegram, "answerCallbackQuery">>;
export type PollerDeps = {
  cfg: Config;
  tg: TgLike;
  ourBotId: string;
  stateDir: string;
  configDir: string;
  peersPath: string;
  clock?: () => number;
  reloadConfig?: () => Config;
  matrix?: OutCtx["matrix"];
  hostname?: string;
  checkEnvelope?: typeof checkEnvelopeOutbound;
  checkCard?: typeof checkCardOutbound;
  lockSleep?: (ms: number) => Promise<unknown>;
  peersHooks?: { afterRead?: () => void };
  readerRun?: typeof runReader;
  readerTimeoutMs?: number;
  log?: (line: string) => void;
  sleep?: (ms: number) => Promise<void>;
};

export class StartLookupError extends Error {
  constructor(message: string) { super(message); this.name = "StartLookupError"; }
}

const START_LOOKUP_TRIES = 6;
const START_LOOKUP_FIRST_WAIT_MS = 2_000;
const START_LOOKUP_MAX_WAIT_MS = 30_000;

type Pending = IntentRec & { n: number };
type Item = { peer: string; msgKind: string; isRoot: boolean; isTemplate: boolean; replyTo: number | null; text: string; id?: string; spool?: string; resend?: boolean; allowShape?: string; corpus?: OutCtx["corpus"]; source?: string; checkUsage: boolean };

const TRIPWIRE_COUNT = 3;
const DAILY_DAYS = 7;
const READ_TAGS = new Set(["ask:question", "status", "info", "answer", "untagged"]);
type ReadJob = { rec: PeerMsgRec; kind: ReaderKind; transition: Transition; held: WakeEvent };
const kindLine = (k: string) => (k === "question" ? "ask:question" : k);
const PERMANENT = [400, 403, 404];
const SENT_PRUNE_MS = 7 * 86_400_000;
const MAX_CARDS_PER_DAY = 3;
const PAIR_TAP_RE = /^pair:(ok|no):([a-z0-9][a-z0-9-]{0,31}):([0-9a-f]{8})$/;
const CLOSING_RULES = ["unknown-peer", "already-paired", "name", "host", "key-shape", "already-trusted", "two-keys", "name-differs", "killed"];

export function operatorTap(cq: any, cfg: Pick<Config, "operatorChatId" | "operatorDmChatId">): boolean {
  const dm = cfg.operatorDmChatId ?? null;
  return dm !== null && cq.from?.id === cfg.operatorChatId && cq.message !== undefined && cq.message?.chat?.id === dm;
}

const PEER_TAP_RE = /^peer:(ok|no):([a-z0-9][a-z0-9-]{0,31}):([0-9a-f]{8})$/;

export const DRAFTING_LINE = "drafted; approve or reject it with the buttons on the draft message";
export const OUTBOUND_REFUSAL_LINE = "a reply about our own outbound thread needs the peer desk's send.ts; nothing was sent";
export const OTHER_REFUSAL_LINE = "replies to this kind of message are not taken; nothing was sent";
export const UNRECORDED_REFUSAL_LINE = "that message is not on record; nothing was sent";
export const REPLY_HINT_LINE = "reply to a peer message to draft an answer; nothing was sent";
export const NO_DESK_LINE = "the peer bridge is not set up for this peer; nothing was sent";
export const LOCKED_LINE = "locked, reset at the station";
export const COMMANDS_LINE = "commands are not taken in this chat, /lockdown included: send them to your operator bot; nothing was done";

export const notifyCursorFile = (S: string) => join(S, "notify", "cursor");
export const dmSentDir = (S: string) => join(S, "notify", "sent");

export function readNotifyCursor(S: string): { n: number; h: string } {
  try {
    const c = JSON.parse(fs.readFileSync(notifyCursorFile(S), "utf8"));
    if (Number.isSafeInteger(c.n) && c.n >= 0 && typeof c.h === "string") return { n: c.n, h: c.h };
  } catch {}
  return { n: 0, h: "" };
}

export function readDmSent(S: string, messageId: number, chat?: number): Record<string, unknown> | null {
  if (!Number.isSafeInteger(messageId) || messageId <= 0) return null;
  try {
    const e = JSON.parse(fs.readFileSync(join(dmSentDir(S), String(messageId)), "utf8"));
    return chat === undefined || e?.chat === chat ? e : null;
  } catch { return null; }
}

const tapKeyboard = (k: Keyboard) => ({ inline_keyboard: [[{ text: "Approve", callback_data: `${k.prefix}:ok:${k.peer}:${k.id}` }, { text: "Reject", callback_data: `${k.prefix}:no:${k.peer}:${k.id}` }]] });

export function sendRule(threads: Threads, peers: Config["peers"], peer: string, rec: { replyTo?: number }): { ok: true } | { ok: false; rule: string } {
  if (!peers[peer]) return { ok: false, rule: "unknown-peer" };
  if (rec.replyTo !== undefined && threads.get(peer, rec.replyTo)?.dir !== "in") return { ok: false, rule: "unknown-thread" };
  return { ok: true };
}

export class Poller {
  offset = 0;
  threads!: Threads;
  gate!: GateState;
  private cfg: Config;
  private chain = new Chain();
  private waker: Waker;
  private pending = new Map<string, Pending>();
  private jobs = new Map<number, JobRecord>();
  private capAsks = new Map<string, boolean>();
  private match = matchEnvelope({ jobs: () => [...this.jobs.values()], asks: () => this.capAsks });
  private tripwire = new Tripwire();
  private dailyChecked = new Map<string, string>();
  private answers = new Map<string, number[]>();
  private rootIntents = new Map<string, Pending>();
  private spoolDone = new Map<string, number>();
  private sentTimes = new Map<string, number[]>();
  private retryAt = 0;
  private failures = 0;
  private notifyStopped = false;
  private noDmLogged = false;
  private unpairedSeen: Set<string> | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private now: () => number;
  private log: (line: string) => void;

  private constructor(private deps: PollerDeps) {
    this.cfg = deps.cfg;
    this.now = deps.clock ?? Date.now;
    this.log = deps.log ?? ((l: string) => console.error(l));
    this.waker = new Waker(this.cfg, this.chain, notifyFile(this.deps.stateDir), this.now);
  }

  static async create(deps: PollerDeps): Promise<Poller> {
    const p = new Poller(deps);
    p.offset = p.readOffset();
    p.load();
    return p;
  }

  private dir = (peer: string) => join(this.deps.stateDir, peer);
  private file = (peer: string, name: string) => join(this.dir(peer), name);
  private ts = () => Math.floor(this.now() / 1000);

  private readOffset(): number {
    try { const n = Number(fs.readFileSync(join(this.deps.stateDir, "offset"), "utf8")); return Number.isSafeInteger(n) && n > 0 ? n : 0; } catch { return 0; }
  }

  private threadOpts() {
    return { peers: this.cfg.peers, clock: this.now };
  }

  private load() {
    const threadRecs: ThreadRec[] = [], inbox: Pick<PeerMsgRec, "peer" | "chat_id" | "from_id" | "id" | "ts">[] = [], envIds: { chat: number; from: string; id: string; exp: number; void?: true }[] = [];
    for (const peer of Object.keys(this.cfg.peers)) {
      for (const r of readChain(this.file(peer, "threads.jsonl"))) if (r.kind === "thread") threadRecs.push(r as unknown as ThreadRec);
      for (const r of readChain(this.file(peer, "inbox.jsonl"))) {
        if (r.kind === "peer-msg") inbox.push(r as unknown as PeerMsgRec);
        else if (r.kind === "peer-env" || r.kind === "peer-card") inbox.push({ peer: r.peer, chat_id: r.chat_id, from_id: r.from_id, ts: r.ts });
      }
      for (const r of readChain(this.file(peer, "envelope-ids.jsonl"))) {
        if (r.kind === "env-id-done" || (r.kind === "env-id" && !r.open)) envIds.push(r as any);
        else if (r.kind === "env-id-void") envIds.push({ ...(r as any), void: true });
      }
      const hourAgo = this.now() - 3_600_000;
      const answered = readChain(this.file(peer, "answers.jsonl")).filter(r => r.kind === "answered" && typeof r.at === "number" && r.at > hourAgo).map(r => r.at as number);
      if (answered.length) this.answers.set(peer, answered);
      for (const r of readChain(this.file(peer, "sig-fails.jsonl"))) if (r.kind === "sig-fail" && typeof r.at === "number" && r.at > hourAgo) this.tripwire.note(peer, r.at);
      for (const r of readChain(this.file(peer, "jobs.jsonl"))) {
        if (r.kind === "cap-ask") this.capAsks.set(`${peer}:${r.msg}`, this.capAsks.get(`${peer}:${r.msg}`) ?? false);
        else if (r.kind === "capacity") this.capAsks.set(`${peer}:${r.re}`, true);
        else if (r.kind === "job") {
          const { n: _n, h: _h, ...job } = r as any;
          this.jobs.set(job.jobNo, job as JobRecord);
        }
      }
      this.loadOutbox(peer);
    }
    this.threads = Threads.load(threadRecs, this.threadOpts());
    this.gate = createGateState({ ourBotId: this.deps.ourBotId, ourUsername: "", committed: this.offset - 1, now: this.now() });
    for (const r of this.threads.roots()) this.gate.roots.add(r);
    rebuildFromInbox(this.gate, inbox);
    for (const r of envIds) { if (r.void) this.gate.envIds.delete(r.chat, r.from, r.id); else this.gate.envIds.add(r.chat, r.from, r.id, r.exp); }
    this.gate.envIds.prune(this.ts());
    this.refreshKilled();
  }

  private refreshKilled() {
    this.gate.killed.clear();
    for (const peer of Object.keys(this.cfg.peers)) if (fs.existsSync(join(this.deps.configDir, `${peer}.killed`))) this.gate.killed.add(peer);
  }

  private loadOutbox(peer: string) {
    const intents = new Map<number, Pending>();
    for (const r of readChain(this.file(peer, "outbox.jsonl"))) {
      if (r.kind === "intent") intents.set(r.n, r as unknown as Pending);
      else if (r.kind === "sent") {
        const i = intents.get(r.intent);
        intents.delete(r.intent);
        if (i) {
          if (i.spool) this.spoolDone.set(`${peer}/${i.spool}`, r.message_id);
          if (i.isRoot && !i.resend && !i.tpl) this.rootIntents.set(`${peer}:${r.message_id}`, i);
        }
        const l = this.sentTimes.get(peer) ?? []; l.push(r.ts * 1000); this.sentTimes.set(peer, l);
      } else if ((r.kind === "failed" || r.kind === "refused") && typeof r.intent === "number") intents.delete(r.intent);
    }
    for (const [n, i] of intents) this.pending.set(`${peer}:${n}`, i);
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.then(fn);
    this.queue = run.catch(() => {});
    return run;
  }

  private async lookupUsername() {
    if (this.gate.ourUsername) return;
    const peer = Object.values(this.cfg.peers).find(p => p.chatId !== null);
    if (!peer) return;
    const m = await this.deps.tg.getChatMember(peer.chatId!, Number(this.deps.ourBotId));
    if (typeof m?.user?.username === "string") this.gate.ourUsername = m.user.username;
  }

  private async ensureUsername() {
    try { await this.lookupUsername(); } catch (e) { this.log(`username lookup failed: ${(e as Error).message}`); }
  }

  private async startLookup() {
    const wait = this.deps.sleep ?? ((ms: number) => new Promise<void>(r => setTimeout(r, ms)));
    for (let n = 1, delay = START_LOOKUP_FIRST_WAIT_MS; ; n++) {
      try { await this.lookupUsername(); return; } catch (e) {
        if (e instanceof TelegramError && e.code === 401) throw e;
        this.log(`username lookup failed (try ${n} of ${START_LOOKUP_TRIES}): ${(e as Error).message}`);
        if (n >= START_LOOKUP_TRIES) throw new StartLookupError(`start lookup failed after ${n} tries: ${(e as Error).message}`);
        await wait(e instanceof RetryAfter ? Math.min(e.seconds * 1000, START_LOOKUP_MAX_WAIT_MS) : delay);
        delay = Math.min(delay * 2, START_LOOKUP_MAX_WAIT_MS);
      }
    }
  }

  jobsSnapshot(): Map<number, JobRecord> { return new Map(this.jobs); }
  nextJobNo(): number { return Math.max(0, ...this.jobs.keys()) + 1; }

  async start(): Promise<void> {
    await this.startLookup();
    await this.recover();
    await this.drainBacklog();
    await this.tick();
  }

  private async drainBacklog(): Promise<void> {
    for (let rounds = 0, failures = 0; rounds < 50;) {
      let updates: any[];
      try { updates = await this.deps.tg.getUpdates(this.offset, 0); } catch (e) {
        if (e instanceof TelegramError && e.code === 401) throw e;
        if (++failures > 12) throw e;
        await sleep(e instanceof RetryAfter ? e.seconds * 1000 : 5000);
        continue;
      }
      if (updates.length === 0) return;
      rounds += 1;
      await this.processBatch(updates);
    }
  }

  async recover(): Promise<void> {
    await this.serial(async () => {
      await this.ensureUsername();
      for (const i of [...this.pending.values()]) {
        if (i.env) {              // an envelope is re-checked against the envelope policy, not the text one
          const ok = await this.checkEnv(i.peer, i.text.split("\n"));
          if (ok.ok) continue;
          await this.chain.append(this.file(i.peer, "outbox.jsonl"), { ...refusalRecord(i.text, ok, this.ts()), intent: i.n });
          this.pending.delete(`${i.peer}:${i.n}`);
          continue;
        }
        if (i.msgKind === "card") {
          const ok = await this.checkCard(i.peer, i.text);
          if (!ok.ok) await this.refuseCard(i, ok);
          continue;
        }
        const res = await this.egress(i.text, this.ctxFor({ peer: i.peer, msgKind: i.msgKind, isRoot: i.isRoot, isTemplate: !!i.tpl, replyTo: i.root, text: i.text, corpus: this.corpusOf(i.source ?? "send.ts"), checkUsage: false }));
        if (res.ok) continue;
        await this.chain.append(this.file(i.peer, "outbox.jsonl"), { ...refusalRecord(i.text, res, this.ts()), intent: i.n });
        this.pending.delete(`${i.peer}:${i.n}`);
        if (i.spool) writeResult(this.dir(i.peer), i.spool, { ok: false, rule: res.rule, ...(res.shape ? { shape: res.shape } : {}) });
      }
      for (const peer of Object.keys(this.cfg.peers)) await this.replayEffects(peer);
      await this.settleDrafts();
      await this.settleOffers();
      await this.flush();
    });
  }

  private async replayEffects(peer: string): Promise<void> {
    const recs = readChain(digestFile(this.dir(peer)));
    const by = (kind: string) => new Map(recs.filter(r => r.kind === kind).map(r => [r.message_id as number, r]));
    const digests = by("digest"), effects = by("effect");
    const inbox = new Map(readChain(this.file(peer, "inbox.jsonl")).filter(r => r.kind === "peer-msg").map(r => [r.message_id as number, r as unknown as PeerMsgRec]));
    for (const job of recs.filter(r => r.kind === "job") as unknown as JobRec[]) {
      if (effects.has(job.message_id)) continue;
      const thread = this.threads.get(peer, job.root);
      const rec = inbox.get(job.message_id);
      if (!thread || !rec) continue;
      const held = this.heldFor(peer, job, thread);
      const digest = digests.get(job.message_id);
      if (!digest) {
        const kind: ReaderKind = job.transition === "opened" ? thread.msgKind as ReaderKind : job.transition === "answered-now" ? "answer" : "other";
        const route = effectiveRoute(kind, job.transition, null);
        const out: Omit<DigestRec, "n" | "h"> = { kind: "digest", peer, message_id: rec.message_id, root_id: rec.root_id, tag: rec.tag, from_id: rec.from_id, ts: this.ts(), summary: null, asks: [], ...(rec.id ? { id: rec.id } : {}), reason: "restart", route, model_route: null };
        await this.chain.append(digestFile(this.dir(peer)), out);
        await this.applyRoute(rec, route, job.transition, held, { route: null, summary: null, asks: [], reason: "restart" });
        continue;
      }
      const route = digest.route as Route | undefined;
      if (!route) continue;
      const d: Digest = { route: digest.model_route ?? null, summary: digest.summary, asks: digest.asks, ...(digest.reason ? { reason: digest.reason } : {}) };
      const settled = route === "ack" ? thread.state === "ACKED" : route === "drop" && job.transition === "opened" ? thread.state === "DROPPED" : false;
      if (!settled) { await this.applyRoute(rec, route, job.transition, held, d); continue; }
      if (route === "ack" && !readChain(this.file(peer, "outbox.jsonl")).some(r => r.kind === "intent" && r.tpl && r.msgKind === "closing" && r.root === job.root)) {
        await this.apply([{ send: { peer, tpl: "closing", root: job.root } }]);
      }
      const effect: Omit<EffectRec, "n" | "h"> = { kind: "effect", peer, message_id: job.message_id, outcome: route === "ack" ? "acked" : "dropped", ts: this.ts() };
      await this.chain.append(digestFile(this.dir(peer)), effect);
    }
  }

  private async writeDailies(peer: string): Promise<void> {
    const file = notifyFile(this.deps.stateDir);
    const now = this.now(), today = utcDay(now);
    if (this.dailyChecked.get(peer) === today) return;
    const marker = (readChain(file) as unknown as NotifyRec[]).filter(r => r.kind === "notify" && r.type === "daily" && r.peer === peer).at(-1) as DailyNotify | undefined;
    const days: string[] = [];
    for (let i = DAILY_DAYS; i >= 1; i--) { const d = utcDay(now - i * 86_400_000); if (d < today && (!marker || d > marker.day)) days.push(d); }
    if (!days.length) { this.dailyChecked.set(peer, today); return; }
    const recs = readChain(digestFile(this.dir(peer)));
    const outcome = new Map(recs.filter(r => r.kind === "effect").map(r => [r.message_id as number, r.outcome as string]));
    for (const day of days) {
      const routed = recs.filter(r => r.kind === "digest" && typeof r.route === "string" && utcDay(r.ts * 1000) === day);
      if (!routed.length) continue;
      const esc = routed.filter(r => r.route === "escalate");
      const skipped: Record<string, number> = {};
      for (const r of esc) if (r.summary === null && typeof r.reason === "string") skipped[r.reason] = (skipped[r.reason] ?? 0) + 1;
      await appendNotify(this.chain, file, {
        kind: "notify", type: "daily", peer, day, ts: now, skipped,
        escalated: esc.length,
        digests: esc.filter(r => outcome.get(r.message_id) === "escalated").length,
        wakes: esc.filter(r => outcome.get(r.message_id) === "fallback-wake").length,
        acked: routed.filter(r => r.route === "ack").length,
        dropped: routed.filter(r => r.route === "drop").length,
      });
    }
    this.dailyChecked.set(peer, today);
  }

  private heldFor(peer: string, job: JobRec, thread: ThreadRec): WakeEvent {
    const label: WakeLabel = job.transition === "opened" ? `new ${thread.msgKind}` as WakeLabel : job.transition === "answered-now" ? "answer" : thread.deadline === null ? "message on a closed thread" : "peer message";
    return { peer, root: job.root, dir: job.dir, label, ...(job.transition === "opened" && thread.deadline ? { replyBy: thread.deadline } : {}) };
  }

  private commitOffset(next: number): Promise<void> {
    this.offset = next;
    return atomicWrite(join(this.deps.stateDir, "offset"), String(next));
  }

  // One batch of updates. The offset moves only after every record of the batch
  // is on disk, so a failed append replays the batch.
  async processBatch(updates: any[]): Promise<void> {
    const jobs: ReadJob[] = [];
    await this.serial(async () => {
      let max = this.offset - 1;
      this.refreshKilled();
      for (const u of [...updates].sort((a, b) => a.update_id - b.update_id)) {
        this.gate.now = this.now();
        if (u?.callback_query || (u?.message ?? u?.edited_message)?.chat?.type === "private") {
          if (Number.isSafeInteger(u.update_id) && u.update_id > this.gate.committed) await this.onOperator(u);
          if (Number.isSafeInteger(u.update_id)) max = Math.max(max, u.update_id);
          continue;
        }
        if (looksLikeEnvelope(u)) {
          await this.onEnvelope(u);
          if (Number.isSafeInteger(u.update_id)) max = Math.max(max, u.update_id);
          continue;
        }
        if (looksLikeCard(u)) {
          await this.onCard(u);
          if (Number.isSafeInteger(u.update_id)) max = Math.max(max, u.update_id);
          continue;
        }
        const r = admit(u, this.cfg, this.gate);
        if (Number.isSafeInteger(u.update_id)) max = Math.max(max, u.update_id);
        if (!r.ok) {
          this.log(r.log);
          if (r.unknownChat) appendUnknownChat(join(this.deps.stateDir, "unknown-chats.jsonl"), r.unknownChat);
          continue;
        }
        await this.chain.append(this.file(r.peer, "inbox.jsonl"), r.rec);
        noteAdmitted(this.gate, r.rec);
        const { actions, transition } = this.threads.onInbound(r.rec);
        const thread = this.threads.get(r.peer, r.rec.root_id);
        if (!READ_TAGS.has(r.rec.tag) || !thread || (r.rec.root_id === r.rec.message_id && transition !== "opened")) { await this.apply(actions); continue; }
        const kind: ReaderKind = transition === "opened" ? thread.msgKind as ReaderKind : transition === "answered-now" ? "answer" : "other";
        const job: Omit<JobRec, "n" | "h"> = { kind: "job", peer: r.peer, message_id: r.rec.message_id, root: r.rec.root_id, dir: thread.dir, transition, ts: this.ts() };
        await this.chain.append(digestFile(this.dir(r.peer)), job);
        const held = actions.flatMap(a => ("wake" in a && a.wake.label !== "cap hit" ? [a.wake] : []));
        await this.apply(actions.filter(a => !("wake" in a) || a.wake.label === "cap hit"));
        jobs.push({ rec: r.rec, kind, transition, held: held[0] ?? { peer: r.peer, root: r.rec.root_id, dir: thread.dir, label: thread.deadline === null ? "message on a closed thread" : "peer message" } });
      }
      if (max >= this.offset) {
        await this.commitOffset(max + 1);
        this.gate.committed = max;
      }
      await this.flush();
    });
    for (const rec of jobs) await this.readAndDigest(rec);
  }

  private async onOperator(u: any): Promise<void> {
    const dm = this.cfg.operatorDmChatId ?? null;
    if (u.callback_query) return this.onTap(u.callback_query, u.update_id);
    const msg = u.message ?? u.edited_message;
    if (!u.message || dm === null || msg.chat?.id !== dm || msg.from?.id !== this.cfg.operatorChatId || msg.from?.is_bot !== false) {
      this.log(`dm-drop update=${u.update_id} chat=${msg?.chat?.id} from=${msg?.from?.id}`);
      return;
    }
    if (typeof msg.text !== "string") return;
    const say = async (text: string) => { await this.dmSend(dm, text); };
    if (msg.text.trimStart().startsWith("/")) return /^\/start(@\w+)?$/.test(msg.text.trim()) ? undefined : say(COMMANDS_LINE);
    const replyTo = msg.reply_to_message;
    if (!replyTo || String(replyTo.from?.id) !== this.deps.ourBotId) return say(REPLY_HINT_LINE);
    if (lockdownEnabled(this.cfg.bridgeRoot)) return say(LOCKED_LINE);
    const entry = readDmSent(this.deps.stateDir, replyTo.message_id, dm);
    if (entry === null) return say(UNRECORDED_REFUSAL_LINE);
    if (entry.type !== "escalate" && entry.type !== "wake") return say(OTHER_REFUSAL_LINE);
    if (entry.dir !== "in") return say(OUTBOUND_REFUSAL_LINE);
    const peer = String(entry.peer), root = entry.root as number;
    if (!this.cfg.peers[peer] || !Number.isSafeInteger(root) || root <= 0 || !fs.existsSync(join(this.dir(peer), "spool"))) return say(NO_DESK_LINE);
    try {
      submitSpool(this.dir(peer), { type: "draft", source: "telegram", kind: "answer", replyTo: root, text: msg.text });
    } catch { return say(NO_DESK_LINE); }
    await say(DRAFTING_LINE);
  }

  private async onTap(cq: any, update: number): Promise<void> {
    const data = typeof cq.data === "string" ? cq.data : "";
    const pair = PAIR_TAP_RE.exec(data);
    const m = PEER_TAP_RE.exec(data);
    const what = pair ? `peer=${pair[2]} offer=${pair[3]} verb=${pair[1]} ` : m ? `peer=${m[2]} draft=${m[3]} verb=${m[1]} ` : "";
    const answer = async (text: string) => {
      this.log(`tap update=${update} cb=${cq.id} from=${cq.from?.id} chat=${cq.message?.chat?.id} ${what}answer="${text}"`);
      try { await this.deps.tg.answerCallbackQuery?.(String(cq.id), text); } catch (e) { this.log(`tap-answer-failed update=${update} cb=${cq.id} error=${(e as Error).message}`); }
    };
    if (pair) return answer(await this.pairTap(cq, pair[1] as "ok" | "no", pair[2], pair[3]));
    if (!m) return answer("Unknown button.");
    if (!operatorTap(cq, this.cfg)) return answer("Not authorized.");
    if (lockdownEnabled(this.cfg.bridgeRoot)) return answer(LOCKED_LINE);
    if (!this.cfg.peers[m[2]] || !fs.existsSync(join(this.dir(m[2]), "spool"))) return answer("Unknown peer.");
    try {
      const rec = { verb: m[1] as "ok" | "no", draft: m[3], by: String(cq.from.id), ts: this.now() };
      submitSpool(this.dir(m[2]), { type: "tap", ...rec, sig: signTap(this.deps.configDir, { ...rec, peer: m[2] }) });
    } catch { return answer("Could not record the tap."); }
    await answer("Received");
  }

  private async pairTap(cq: any, verb: "ok" | "no", peer: string, id: string): Promise<string> {
    if (!operatorTap(cq, this.cfg)) return "Not authorized.";
    const sent = readDmSent(this.deps.stateDir, cq.message.message_id, this.cfg.operatorDmChatId!);
    if (sent?.type !== "pair-offer" || sent.peer !== peer || sent.offer !== id) return "Unknown offer.";
    const recs = this.pairRecs(peer);
    const offer = offersOf(recs).find(o => o.offer === id);
    if (!offer || !this.cfg.peers[peer]) return "Unknown offer.";
    const state = offerState(recs, offer, this.now());
    if (state !== "OPEN") {
      if (!resultOf(recs, id)) await this.closeOffer(offer, "EXPIRED");
      return `Already ${state.toLowerCase()}.`;
    }
    if (verb === "no") { await this.closeOffer(offer, "REJECTED"); return "Rejected."; }
    if (lockdownEnabled(this.cfg.bridgeRoot)) return LOCKED_LINE;
    const refused = async (rule: string) => { await this.closeOffer(offer, "REFUSED", { rule }); return `Refused (${rule}).`; };
    this.refreshKilled();
    if (this.gate.killed.has(peer)) return refused("killed");
    if (this.cfg.peers[peer].theirs.keys.length > 0) return refused("already-paired");
    try {
      await addTrustedKey(this.deps.peersPath, peer, offer.station, offer.key, {
        hostname: this.hostName(), now: this.now, sleep: this.deps.lockSleep ?? sleep, firstOnly: true, hooks: this.deps.peersHooks, log: this.log,
        guard: () => {
          if (this.now() > offer.exp) throw new ConfigError("expired");
          if (lockdownEnabled(this.cfg.bridgeRoot)) throw new ConfigError("lockdown");
          if (fs.existsSync(join(this.deps.configDir, `${peer}.killed`))) throw new ConfigError("killed");
        },
      });
    } catch (e) {
      const why = (e as Error).message;
      if (e instanceof ConfigError && why === "expired") { await this.closeOffer(offer, "EXPIRED"); return "Already expired."; }
      if (e instanceof ConfigError && why === "lockdown") return LOCKED_LINE;
      if (e instanceof ConfigError && why === "busy") return "Busy, tap again.";
      if (e instanceof ConfigError && CLOSING_RULES.includes(why)) return refused(why);
      this.log(`pair-tap peer=${peer} offer=${id} not recorded: ${why}`);
      return "Could not record the tap.";
    }
    await this.closeOffer(offer, "APPROVED", { by: String(cq.from.id) });
    await this.reloadNow();
    return "Trusted.";
  }

  private async dmSend(chat: number, text: string): Promise<void> {
    try { await this.deps.tg.sendMessage(chat, text); } catch (e) { this.log(`peer-notify: a line to the operator was not sent: ${(e as Error).message}`); }
  }

  private async deliverNotify(): Promise<void> {
    const chat = this.cfg.operatorDmChatId ?? null;
    if (chat === null) {
      if (!this.noDmLogged) { this.log("peer-notify: peers.json has no operator DM; run setup.ts dm"); this.noDmLogged = true; }
      return;
    }
    if (this.notifyStopped || this.now() < this.retryAt) return;
    const S = this.deps.stateDir, file = notifyFile(S), cursor = readNotifyCursor(S);
    let check: ReturnType<typeof verifyChain>;
    try { check = verifyChain(file, cursor); } catch { check = { ok: false, n: cursor.n, h: "" }; }
    if (!check.ok) {
      this.notifyStopped = true;
      this.log(`peer-notify: chain failed verification at #${check.n + 1}`);
      await this.dmSend(chat, renderChainAlert(check.n + 1));
      return;
    }
    for (const rec of readChain(file).slice(cursor.n, check.n) as unknown as (NotifyRec & { n: number; h: string })[]) {
      let rendered: ReturnType<typeof renderNotify> | null = null;
      try { rendered = renderNotify(rec, this.cfg.himmelRoot); } catch { this.log(`peer-notify: #${rec.n} does not render; skipped`); }
      if (rendered) {
        try {
          const { message_id } = await this.deps.tg.sendMessage(chat, rendered.text, undefined, rendered.keyboard ? tapKeyboard(rendered.keyboard) : undefined);
          const r = rec as any;
          fs.mkdirSync(dmSentDir(S), { recursive: true, mode: 0o700 });
          await atomicWrite(join(dmSentDir(S), String(message_id)), JSON.stringify({ n: rec.n, chat, type: rec.type, peer: rec.peer, ...(r.root !== undefined ? { root: r.root } : {}), ...(r.dir ? { dir: r.dir } : {}), ...(r.draft ? { draft: r.draft } : {}), ...(r.offer ? { offer: r.offer } : {}), ts: this.now() }));
        } catch (e) {
          if (e instanceof RetryAfter) { this.retryAt = this.now() + e.seconds * 1000; return; }
          if (!(e instanceof TelegramError && PERMANENT.includes(e.code))) { this.log(`peer-notify: #${rec.n} not sent (${(e as Error).message}); retry next tick`); return; }
          this.log(`peer-notify: #${rec.n} refused by Telegram ${e.code}`);
          await this.dmSend(chat, renderFallback(rec.n, e.code));
        }
      }
      await atomicWrite(notifyCursorFile(S), JSON.stringify({ n: rec.n, h: rec.h }));
    }
    this.pruneDmSent();
  }

  private pruneDmSent(): void {
    let names: string[];
    try { names = fs.readdirSync(dmSentDir(this.deps.stateDir)); } catch { return; }
    for (const name of names) {
      const e = readDmSent(this.deps.stateDir, Number(name));
      if (!e || typeof e.ts !== "number" || this.now() - e.ts > SENT_PRUNE_MS) fs.rmSync(join(dmSentDir(this.deps.stateDir), name), { force: true });
    }
  }

  private chainedCard(m: any): PeerCardRec | undefined {
    const peer = Object.entries(this.cfg.peers).find(([, p]) => p.chatId === m?.chat?.id)?.[0];
    if (!peer) return undefined;
    return readChain(this.file(peer, "inbox.jsonl")).find(r => r.kind === "peer-card" && r.chat_id === m.chat.id && r.message_id === m.message_id) as unknown as PeerCardRec | undefined;
  }

  private async onCard(u: any): Promise<void> {
    const chained = this.chainedCard(u?.message);
    const r = admitCard(u, this.cfg, chained ? { ...this.gate, rate: new Map() } : this.gate);
    if (r.ok && chained) return this.offerCard(r.peer, r.rec);
    if (!r.ok) {
      this.log(r.log);
      if (r.unknownChat) appendUnknownChat(join(this.deps.stateDir, "unknown-chats.jsonl"), r.unknownChat);
      return;
    }
    await this.chain.append(this.file(r.peer, "inbox.jsonl"), r.rec);
    noteAdmitted(this.gate, r.rec);
    await this.offerCard(r.peer, r.rec);
  }

  private pairRecs = (peer: string) => readChain(this.file(peer, "pairing.jsonl")) as unknown as PairRec[];

  private notified(type: string, offer: string): boolean {
    return (readChain(notifyFile(this.deps.stateDir)) as Record<string, any>[]).some(r => r.type === type && r.offer === offer);
  }

  private async offerNotify(o: CardOffer): Promise<void> {
    if (!this.notified("pair-offer", o.offer)) await appendNotify(this.chain, notifyFile(this.deps.stateDir), { kind: "notify", type: "pair-offer", peer: o.peer, offer: o.offer, station: o.station, key: o.key, exp: o.exp, ts: this.now() });
  }

  private async closeNotify(o: CardOffer, res: OfferResult): Promise<void> {
    const file = notifyFile(this.deps.stateDir);
    if (!this.notified("pair-result", o.offer)) await appendNotify(this.chain, file, { kind: "notify", type: "pair-result", peer: o.peer, offer: o.offer, state: res.state, key: o.key, ...(res.rule ? { rule: res.rule } : {}), ts: this.now() });
    if (res.rule === "two-cards" && !this.notified("pair-alert", o.offer)) await appendNotify(this.chain, file, { kind: "notify", type: "pair-alert", peer: o.peer, offer: o.offer, ts: this.now() });
  }

  private async closeOffer(o: CardOffer, state: OfferState, extra: { rule?: string; by?: string } = {}): Promise<void> {
    const res: OfferResult = { kind: "offer-result", offer: o.offer, state, ...extra, ts: this.ts() };
    await this.chain.append(this.file(o.peer, "pairing.jsonl"), res);
    await this.closeNotify(o, res);
  }

  private hostName = () => this.deps.hostname ?? osHostname();

  private async offerCard(peer: string, card: PeerCardRec): Promise<void> {
    const recs = this.pairRecs(peer);
    const offers = offersOf(recs);
    const now = this.now();
    const open = offers.filter(o => offerState(recs, o, now) === "OPEN");
    const closedToday = (o: CardOffer, pred: (r: OfferResult) => boolean) => {
      const r = resultOf(recs, o.offer);
      return r !== undefined && pred(r) && utcDay(r.ts * 1000) === utcDay(now);
    };
    const no = (why: string) => this.log(`card-no-offer peer=${peer} key=${keyId(card.key)} why=${why}`);
    if ((this.cfg.operatorDmChatId ?? null) === null) return no("no-dm");
    if (this.gate.killed.has(peer)) return no("killed");
    const rule = trustRefusal(this.cfg, peer, card.station, card.key, this.hostName(), { firstOnly: true });
    if (rule !== null) return no(rule);
    if (offers.some(o => closedToday(o, r => r.rule === "two-cards"))) return no("two-cards-today");
    const other = open.find(o => o.key !== card.key);
    if (other) {
      await this.closeOffer(other, "REFUSED", { rule: "two-cards" });
      return no("two-cards");
    }
    if (open.length) return no("already-offered");
    if (offers.some(o => o.chat_id === card.chat_id && o.message_id === card.message_id)) return no("same-message");
    if (offers.some(o => o.key === card.key && closedToday(o, r => r.state === "REJECTED"))) return no("rejected-today");
    if (offersToday(recs, peer, now) >= MAX_OFFERS_PER_DAY) return no("daily-offers");
    const offer: CardOffer = { kind: "card-offer", peer, offer: mintId(), station: card.station, key: card.key, chat_id: card.chat_id, message_id: card.message_id, ts: this.ts(), exp: now + PAIR_OFFER_TTL_MS };
    await this.chain.append(this.file(peer, "pairing.jsonl"), offer);
    await this.offerNotify(offer);
  }

  private async settleOffers(): Promise<void> {
    for (const peer of Object.keys(this.cfg.peers)) {
      const recs = this.pairRecs(peer);
      const keys = this.cfg.peers[peer].theirs.keys ?? [];
      for (const o of offersOf(recs)) {
        const res = resultOf(recs, o.offer);
        if (res) { await this.closeNotify(o, res); continue; }
        const own = keys.find(k => k.pub === o.key);
        if (own) await (Date.parse(own.addedAt) <= o.exp ? this.closeOffer(o, "APPROVED", { by: "terminal-or-replay" }) : this.closeOffer(o, "EXPIRED"));
        else if (keys.length) await this.closeOffer(o, "REFUSED", { rule: "already-paired" });
        else if (this.now() > o.exp) await this.closeOffer(o, "EXPIRED");
        else await this.offerNotify(o);
      }
    }
  }

  private async onEnvelope(u: any): Promise<void> {
    const r = admitEnvelope(u, this.cfg, this.gate, this.match);
    if (!r.ok) {
      this.log(r.log);
      if (r.unknownChat) appendUnknownChat(join(this.deps.stateDir, "unknown-chats.jsonl"), r.unknownChat);
      if (r.step === 1 || !r.peer) return;
      noteRate(this.gate, r.peer, this.ts());
      await this.noteUnpaired(r.peer, r.step, r.reason, u.message.text);
      if (r.step === 5) {
        await this.chain.append(this.file(r.peer, "sig-fails.jsonl"), { kind: "sig-fail", at: this.now() });
        if (this.tripwire.note(r.peer, this.now())) await this.waker.alert(r.peer, TRIPWIRE_COUNT);
      }
      if (!r.rec || !r.env) return;
      const { peer, env } = r;
      await this.chain.append(this.file(peer, "inbox.jsonl"), r.rec);
      await this.withEnvId(r.rec, env.exp, async () => {
        if (env.kind === "req" && r.refused) await this.answer(peer, { kind: "res", body: { job: env.job, state: "refused", refused: r.refused } });
      });
      return;
    }
    noteRate(this.gate, r.peer, this.ts());
    await this.chain.append(this.file(r.peer, "inbox.jsonl"), r.rec);
    await this.withEnvId(r.rec, r.env.exp, () => this.handleEnvelope(r.peer, r.env));
  }

  private async noteUnpaired(peer: string, step: number, reason: string, text: string): Promise<void> {
    const p = this.cfg.peers[peer];
    const missing: UnpairedNotify["missing"] | null =
      step === 4 && reason === "no trusted key with that id" ? "their-key"
      : step === 7 && reason === "to is not our station name" && this.cfg.self?.stationName === undefined ? "our-name"
      : step === 7 && reason === "from is not the trusted station name" && p?.theirs.stationName === undefined ? "their-name"
      : null;
    const key = ENV_LINE_RE.exec(text.split("\n")[1] ?? "")?.[1];
    if (!missing || !key) return;
    const file = notifyFile(this.deps.stateDir);
    this.unpairedSeen ??= new Set((readChain(file) as unknown as NotifyRec[]).filter(r => r.type === "unpaired").map(r => `${r.peer}:${(r as UnpairedNotify).missing}:${(r as UnpairedNotify).key}`));
    const id = `${peer}:${missing}:${key}`;
    if (this.unpairedSeen.has(id)) return;
    await appendNotify(this.chain, file, { kind: "notify", type: "unpaired", peer, missing, key, ts: this.now() });
    this.unpairedSeen.add(id);
  }

  private async withEnvId(rec: PeerEnvRec, exp: number, handle: () => Promise<void>): Promise<void> {
    try {
      await this.recordId(rec, exp);
      await handle();
      await this.chain.append(this.file(rec.peer, "envelope-ids.jsonl"), { kind: "env-id-done", chat: rec.chat_id, from: rec.from_id, id: rec.id, exp });
    } catch (e) {
      this.gate.envIds.delete(rec.chat_id, rec.from_id, rec.id);
      await this.chain.append(this.file(rec.peer, "envelope-ids.jsonl"), { kind: "env-id-void", chat: rec.chat_id, from: rec.from_id, id: rec.id }).catch(() => {});
      throw e;
    }
  }

  private async recordId(rec: PeerEnvRec, exp: number): Promise<void> {
    await this.chain.append(this.file(rec.peer, "envelope-ids.jsonl"), { kind: "env-id", chat: rec.chat_id, from: rec.from_id, id: rec.id, exp, open: true });
  }

  private async handleEnvelope(peer: string, env: Envelope): Promise<void> {
    const drop = (why: string) => this.log(`env-drop step=8 peer=${peer} msg=${env.msg} ${why}`);
    const mine = (dir: "in" | "out") => [...this.jobs.values()].filter(j => j.peer === peer && j.dir === dir);
    if (env.kind === "res") {
      const job = mine("out").filter(j => j.wire_job === env.job).pop();
      const patch = resolveRes(env, job, { imageDigest: this.cfg.peers[peer].theirs.imageDigest });
      if (!job || !patch) return drop("res for a job we did not send");
      await this.applyJobEvent(job, { type: `res-${env.state}`, patch });
    } else if (env.kind === "cancel") {
      const job = mine("in").filter(j => j.peer_job === env.job).pop();
      if (!job) return drop("cancel for a job the peer did not send");
      await this.applyJobEvent(job, { type: "cancel" });
    } else if (env.kind === "halt") {
      for (const job of mine("in")) await this.applyJobEvent(job, { type: "halt" });
    } else if (env.kind === "capacity-ask") {
      await this.answer(peer, { kind: "capacity", body: this.capacityBody(peer, env.msg) });
    } else if (env.kind === "capacity") {
      const key = `${peer}:${env.re}`;
      if (this.capAsks.get(key) !== false) return drop("capacity for an ask we did not send, or one already answered");
      this.capAsks.set(key, true);
      await this.chain.append(this.file(peer, "jobs.jsonl"), { kind: "capacity", peer, re: env.re, ts: this.ts(), ...resolveCapacity(env) });
    } else if (env.kind === "req") {
      let allow: AllowEntry[] = [];
      try { allow = loadAllowlist(peer, this.deps.configDir); } catch (e) { this.log(`env-drop step=8 peer=${peer} msg=${env.msg} suite allowlist unreadable: ${(e as Error).message}`); }
      const resolved = resolveReq(env, allow);
      const job = newInJob({ jobNo: this.nextJobNo(), peer, now: this.ts(), fields: resolved.record });
      await this.putJob(job);
      if (!resolved.ok) await this.applyJobEvent(job, { type: "resolve-fail", refused: resolved.refused }, true);
    }
  }

  private async applyEnvOut(peer: string, name: string, rec: Extract<SpoolRec, { type: "env-out" }>): Promise<void> {
    const dir = this.dir(peer);
    const refuse = (rule: string) => writeResult(dir, name, { ok: false, rule });
    const outJob = typeof rec.body.jobNo === "number" ? this.peerJobs(peer).find(j => j.dir === "out" && j.jobNo === rec.body.jobNo) : undefined;
    let spec: SendSpec;
    if (rec.kind === "req") {
      const wire = randomBytes(8).toString("hex");
      spec = { kind: "req", body: { job: wire, op: "run-suite", sha: rec.body.sha, suites: rec.body.suites } };
    } else if (rec.kind === "cancel") {
      if (!outJob || isTerminal(outJob)) return refuse("unknown-job");
      spec = { kind: "cancel", body: { job: outJob.wire_job } };
    } else spec = { kind: rec.kind, body: {} };
    let made: ReturnType<Poller["makeEnvelope"]>;
    try { made = this.makeEnvelope(peer, spec); } catch (e) { return refuse((e as Error).message.startsWith("no usable station key") ? "no-key" : "bad-request"); }
    if (!made) return refuse("not-set-up");
    if (rec.kind === "req") {
      const b = made.env as Extract<Envelope, { kind: "req" }>;
      const job = newOutJob({ jobNo: this.nextJobNo(), peer, wireJob: b.job, sha: b.sha, suites: b.suites, reqExp: b.exp, now: this.ts() });
      if (!(await this.queueEnvelope(peer, made, () => this.putJob(job)))) return refuse("egress");
      writeResult(dir, name, { ok: true, job: job.jobNo });
      return;
    }
    if (rec.kind === "capacity-ask") {
      await this.chain.append(this.file(peer, "jobs.jsonl"), { kind: "cap-ask", peer, msg: made.env.msg, ts: this.ts() });
      this.capAsks.set(`${peer}:${made.env.msg}`, false);
    }
    if (!(await this.queueEnvelope(peer, made))) return refuse("egress");
    writeResult(dir, name, { ok: true });
  }

  private async applyJobSpool(peer: string, name: string, rec: Extract<SpoolRec, { type: "job-event" }>): Promise<void> {
    const dir = this.dir(peer);
    const job = this.jobs.get(rec.job);
    if (!job || job.peer !== peer || job.dir !== "in") return writeResult(dir, name, { ok: false, rule: "unknown-job" });
    this.refreshKilled();
    if (this.gate.killed.has(peer)) { await this.fireKills(); return writeResult(dir, name, { ok: false, rule: "killed" }); }
    const e: any = rec.event, p = this.cfg.peers[peer];
    const isHex = (v: unknown, n: number) => typeof v === "string" && new RegExp(`^[0-9a-f]{${n}}$`).test(v);
    let ev: JobEvent;
    switch (e.type) {
      case "resolve-ok":
        if (!isHex(e.sha, 40)) return writeResult(dir, name, { ok: false, rule: "bad-event" });
        ev = { type: "resolve-ok", sha: e.sha };
        break;
      case "resolve-fail":
        if (e.refused !== "unknown-sha" && e.refused !== "too-old") return writeResult(dir, name, { ok: false, rule: "bad-event" });
        ev = { type: "resolve-fail", refused: e.refused };
        break;
      case "approve":
        ev = { type: "approve" };
        break;
      case "vm-start": {
        const left = remaining(this.peerJobs(peer), p.budgets ?? DEFAULT_BUDGETS, this.ts());
        ev = { type: "vm-start", backstop_s: Math.min((p.budgets ?? DEFAULT_BUDGETS).maxJobMinutes * 60, left.vmMinutes * 60) };
        break;
      }
      default: {
        const ok = (e.results === undefined || (Array.isArray(e.results) && e.results.every((o: unknown) => OUTCOMES.includes(o as any))))
          && (e.golden === undefined || isHex(e.golden, 64)) && (e.log_sha256 === undefined || isHex(e.log_sha256, 64))
          && (e.log_bytes === undefined || Number.isSafeInteger(e.log_bytes)) && (e.runner_minutes === undefined || Number.isSafeInteger(e.runner_minutes));
        if (!ok) return writeResult(dir, name, { ok: false, rule: "bad-event" });
        ev = { type: "vm-done", results: e.results, golden: e.golden, log_sha256: e.log_sha256, log_bytes: e.log_bytes, runner_minutes: e.runner_minutes };
      }
    }
    await this.applyJobEvent(job, ev);
    const after = this.jobs.get(job.jobNo)!;
    if (ev.type === "resolve-ok" && after.state === "RESOLVED" && p.approve?.["run-suite"] === "auto") await this.applyJobEvent(after, { type: "approve" });
    writeResult(dir, name, { ok: true });
  }

  private async applyJobEvent(job: JobRecord, event: JobEvent, capped = false): Promise<void> {
    const r = step(job, event, this.ts());
    if (r.record !== job) await this.putJob(r.record);
    if (r.send) await (capped ? this.answer(job.peer, r.send) : this.sendEnvelope(job.peer, r.send));
  }

  private async fireDeadlines(): Promise<void> {
    for (const job of dueJobs([...this.jobs.values()], this.ts())) await this.applyJobEvent(job, { type: "deadline" });
  }

  private async fireKills(): Promise<void> {
    for (const job of [...this.jobs.values()]) {
      if (job.dir === "in" && this.gate.killed.has(job.peer) && !isTerminal(job)) await this.applyJobEvent(job, { type: "kill" });
    }
  }

  private checkEnv(peer: string, lines: string[]): Promise<Outcome> {
    return (this.deps.checkEnvelope ?? checkEnvelopeOutbound)(lines, {
      peer: this.cfg.peers[peer], self: this.cfg.self?.stationName, keyDir: this.deps.configDir, himmelRoot: this.cfg.himmelRoot,
      maxTextChars: this.cfg.maxTextChars, hostname: this.deps.hostname, matrix: this.deps.matrix,
    });
  }

  private makeEnvelope(peer: string, spec: SendSpec): { env: Envelope; lines: string[] } | null {
    const p = this.cfg.peers[peer];
    const from = this.cfg.self?.stationName, to = p?.theirs.stationName;
    if (!p || p.chatId === null || !from || !to) { this.log(`env-send peer=${peer} not sent: station names or chat are not set`); return null; }
    const key = currentSigningKey(this.deps.configDir);
    const env = buildEnvelope(spec.kind, spec.body, { from, to, chat: p.chatId, now: this.ts() });
    const line2 = `#env:v1 k=${key.id} id=${env.msg}`, line3 = encodeCanonical(env);
    return { env, lines: [`/peer@${p.theirs.username}`, line2, line3, `sig=${sign(line2, line3, key.path)}`] };
  }

  private async queueEnvelope(peer: string, made: { env: Envelope; lines: string[] }, afterEgress?: () => Promise<void>): Promise<boolean> {
    const ok = await this.checkEnv(peer, made.lines);
    if (!ok.ok) {
      await this.chain.append(this.file(peer, "outbox.jsonl"), refusalRecord(made.lines[2], ok, this.ts()));
      this.log(`env-send peer=${peer} refused: ${ok.rule}`);
      return false;
    }
    await afterEgress?.();
    const rec = await this.chain.append(this.file(peer, "outbox.jsonl"), { kind: "intent", peer, chat: this.cfg.peers[peer].chatId, id: made.env.msg, root: null, msgKind: "env", text: made.lines.join("\n"), isRoot: false, env: true });
    this.pending.set(`${peer}:${rec.n}`, rec as unknown as Pending);
    return true;
  }

  private async answer(peer: string, spec: SendSpec): Promise<void> {
    const now = this.now();
    const recent = (this.answers.get(peer) ?? []).filter(t => now - t < 3_600_000);
    if (recent.length >= MAX_AUTO_PER_HOUR) { this.log(`env-drop peer=${peer} not answered: the hourly cap on answers is reached`); return; }
    await this.chain.append(this.file(peer, "answers.jsonl"), { kind: "answered", at: now });
    recent.push(now);
    this.answers.set(peer, recent);
    await this.sendEnvelope(peer, spec);
  }

  private async sendEnvelope(peer: string, spec: SendSpec): Promise<void> {
    let made: ReturnType<Poller["makeEnvelope"]>;
    try { made = this.makeEnvelope(peer, spec); } catch (e) { this.log(`env-send peer=${peer} not sent: ${(e as Error).message}`); return; }
    if (made) await this.queueEnvelope(peer, made);
  }

  private async putJob(rec: JobRecord): Promise<void> {
    await this.chain.append(this.file(rec.peer, "jobs.jsonl"), rec);
    this.jobs.set(rec.jobNo, rec);
  }

  private peerJobs(peer: string): JobRecord[] { return [...this.jobs.values()].filter(j => j.peer === peer); }

  private capacityBody(peer: string, re: string): Record<string, unknown> {
    const p = this.cfg.peers[peer];
    if ((p.serves ?? []).length === 0) return { re, state: "not-served", queue: 0, jobs_left: 0, vm_minutes_left: 0 };
    const mine = this.peerJobs(peer);
    const left = remaining(mine, p.budgets ?? DEFAULT_BUDGETS, this.ts());
    return {
      re, state: mine.some(j => j.dir === "in" && j.state === "RUNNING") ? "busy" : "idle",
      queue: clampToSchema("queue", queueDepth(mine)), jobs_left: clampToSchema("jobs_left", left.jobs), vm_minutes_left: clampToSchema("vm_minutes_left", left.vmMinutes),
    };
  }

  private async readAndDigest(job: ReadJob): Promise<void> {
    const { rec, kind, transition, held } = job;
    const peer = this.cfg.peers[rec.peer];
    if (!peer) return;
    const ledger = new ReaderLedger(this.file(rec.peer, "reader-ledger.json"), peer, this.now);
    const run = this.deps.readerRun ?? runReader;
    const d = await run(rec.text, kind, { himmelRoot: this.cfg.himmelRoot, ledger, timeoutMs: this.deps.readerTimeoutMs });
    const model: ModelRoute = d.route === "escalate" || d.route === "ack" || d.route === "drop" ? d.route : null;
    const route = effectiveRoute(kind, transition, model);
    await this.serial(async () => {
      const out: Omit<DigestRec, "n" | "h"> = { kind: "digest", peer: rec.peer, message_id: rec.message_id, root_id: rec.root_id, tag: rec.tag, from_id: rec.from_id, ts: this.ts(), summary: d.summary, asks: d.asks, ...(rec.id ? { id: rec.id } : {}), ...(d.reason ? { reason: d.reason } : {}), route, model_route: model };
      await this.chain.append(digestFile(this.dir(rec.peer)), out);
      await this.applyRoute(rec, route, transition, held, { ...d, route: model });
      await this.flush();
    });
  }

  private async applyRoute(rec: PeerMsgRec, route: Route, transition: Transition, held: WakeEvent, d: Digest): Promise<void> {
    let outcome: EffectRec["outcome"];
    if (route === "escalate") outcome = await this.waker.escalate({ ...held, message_id: rec.message_id, digest: d });
    else if (transition !== "opened") outcome = "dropped";
    else {
      const acts = route === "ack" ? this.threads.ack(rec.peer, rec.root_id) : this.threads.drop(rec.peer, rec.root_id);
      if (!acts.length) return;
      await this.apply(acts);
      outcome = route === "ack" ? "acked" : "dropped";
    }
    const effect: Omit<EffectRec, "n" | "h"> = { kind: "effect", peer: rec.peer, message_id: rec.message_id, outcome, ts: this.ts() };
    await this.chain.append(digestFile(this.dir(rec.peer)), effect);
  }

  async tick(): Promise<void> {
    await this.serial(async () => {
      await this.ensureUsername();
      this.refreshKilled();
      this.gate.envIds.prune(this.ts());
      await this.apply(this.threads.tick(this.now()));
      await this.fireKills();
      await this.fireDeadlines();
      await this.settleDrafts();
      await this.settleOffers();
      await this.flush();
      for (const peer of Object.keys(this.cfg.peers)) sweepResults(this.dir(peer), 86_400_000, this.now());
      for (const peer of Object.keys(this.cfg.peers)) await this.writeDailies(peer);
    });
  }

  async drainSpool(): Promise<void> {
    await this.serial(async () => {
      for (const peer of Object.keys(this.cfg.peers)) {
        if (!fs.existsSync(join(this.dir(peer), "spool"))) continue;
        for (const d of drainSpool(this.dir(peer))) {
          if ("malformed" in d) { this.log(`malformed spool file ${peer}/${d.name}: ${d.why}`); writeResult(this.dir(peer), d.name, { ok: false, rule: "malformed", why: d.why }); continue; }
          await this.applySpool(peer, d.name, d.rec);
        }
      }
      await this.flush();
    });
  }

  private async applySpool(peer: string, name: string, rec: SpoolRec): Promise<void> {
    const dir = this.dir(peer);
    if (rec.type === "env-out") return this.applyEnvOut(peer, name, rec);
    if (rec.type === "job-event") return this.applyJobSpool(peer, name, rec);
    if (rec.type === "ack") {
      let key: Buffer;
      try { key = fs.readFileSync(join(this.deps.configDir, "hmac.key")); } catch { writeResult(dir, name, { ok: false, rule: "no-key" }); return; }
      const n = parseAck(key, rec.sid, peer, rec.token);
      if (n === null) { writeResult(dir, name, { ok: false, rule: "bad-ack" }); return; }
      await writeCursor(dir, rec.sid, n);
      writeResult(dir, name, { ok: true });
      return;
    }
    if (rec.type === "confirm") {
      if (!(await this.reloadNow())) { writeResult(dir, name, { ok: false, rule: "config" }); return; }
      await this.chain.append(this.file(peer, "outbox.jsonl"), { kind: "confirmed", chat_id: rec.chatId, ts: this.ts() });
      writeResult(dir, name, { ok: true });
      return;
    }
    if (rec.type === "draft") return this.applyDraft(peer, name, rec);
    if (rec.type === "card") return this.applyCard(peer, name);
    return this.applyTap(peer, name, rec);
  }

  private checkCard(peer: string, text: string): Promise<Outcome> {
    return (this.deps.checkCard ?? checkCardOutbound)(text, {
      peer: this.cfg.peers[peer], self: this.cfg.self?.stationName, keyDir: this.deps.configDir, himmelRoot: this.cfg.himmelRoot,
      hostname: this.deps.hostname, matrix: this.deps.matrix,
    });
  }

  private async applyCard(peer: string, name: string): Promise<void> {
    const dir = this.dir(peer);
    const out = this.outbox(peer);
    if (out.some(r => r.kind === "intent" && r.msgKind === "card" && r.spool === name)) return writeResult(dir, name, { ok: true });
    const no = (rule: string) => writeResult(dir, name, { ok: false, rule });
    const self = this.cfg.self?.stationName;
    if (self === undefined) return no("no-name");
    let key: { id: string; path: string };
    try { key = currentSigningKey(this.deps.configDir); } catch { return no("no-key"); }
    const p = this.cfg.peers[peer];
    if (!p || p.chatId === null) return no("not-set-up");
    const dead = new Set(out.filter(r => (r.kind === "failed" || r.kind === "refused") && typeof r.intent === "number").map(r => r.intent));
    const today = out.filter(r => r.kind === "intent" && r.msgKind === "card" && r.card === key.id && !dead.has(r.n) && utcDay(r.ts * 1000) === utcDay(this.now()));
    if (today.length >= MAX_CARDS_PER_DAY) return no("card-daily");
    const text = cardMessage(p.theirs.username, self, publicKeyOf(key.path));
    const res = await this.checkCard(peer, text);
    if (!res.ok) {
      await this.chain.append(this.file(peer, "outbox.jsonl"), refusalRecord(text, res, this.ts()));
      return no(res.rule);
    }
    const rec = await this.chain.append(this.file(peer, "outbox.jsonl"), { kind: "intent", peer, chat: p.chatId, id: mintId(), root: null, msgKind: "card", text, isRoot: false, card: key.id, spool: name, ts: this.ts() });
    this.pending.set(`${peer}:${rec.n}`, rec as unknown as Pending);
    writeResult(dir, name, { ok: true });
  }

  private async reloadNow(): Promise<boolean> {
    try {
      this.cfg = this.deps.reloadConfig ? this.deps.reloadConfig() : this.cfg;
    } catch (e) {
      if (!(e instanceof ConfigError)) throw e;
      this.log(`peer-bridge: peers.json not reloaded: ${e.message}`);
      return false;
    }
    this.threads = Threads.load(this.threads.all(), this.threadOpts());
    this.waker = new Waker(this.cfg, this.chain, notifyFile(this.deps.stateDir), this.now);
    this.noDmLogged = false;
    await this.ensureUsername();
    return true;
  }

  reload(): Promise<boolean> {
    return this.serial(async () => { const ok = await this.reloadNow(); await this.flush(); return ok; });
  }

  private outbox = (peer: string) => readChain(this.file(peer, "outbox.jsonl")) as Record<string, any>[];
  private allOutboxes = () => Object.keys(this.cfg.peers).map(p => this.outbox(p));
  private corpusOf = (source: string): OutCtx["corpus"] => (source === "telegram" ? "operator-reply" : source === "send.ts" ? "peer-desk" : source === "chief" ? "chief-tell" : "unknown-source");

  private async resultNotify(peer: string, draft: string, state: ResultNotify["state"], root: number, extra: { message_id?: number; rule?: string } = {}) {
    const file = notifyFile(this.deps.stateDir);
    if ((readChain(file) as Record<string, any>[]).some(r => r.type === "result" && r.draft === draft)) return;
    await appendNotify(this.chain, file, { kind: "notify", type: "result", peer, root, draft, state, ts: this.now(), ...extra });
  }

  private async draftNotify(peer: string, d: Record<string, any>) {
    await appendNotify(this.chain, notifyFile(this.deps.stateDir), { kind: "notify", type: "draft", peer, root: d.replyTo ?? 0, draft: d.id, source: d.source, ...(d.session ? { session: d.session } : {}), deadline: d.deadline, text: d.text, ts: this.now() });
  }

  private async finishDraft(peer: string, d: Record<string, any>, state: "REJECTED" | "EXPIRED" | "REFUSED", rule?: string) {
    await this.chain.append(this.file(peer, "outbox.jsonl"), { kind: "draft-result", draft: d.id, state, ...(rule ? { rule } : {}), ts: this.ts() });
    await this.resultNotify(peer, d.id, state, d.replyTo ?? 0, rule ? { rule } : {});
  }

  private async applyDraft(peer: string, name: string, rec: Extract<SpoolRec, { type: "draft" }>): Promise<void> {
    const dir = this.dir(peer);
    const seen = this.outbox(peer).find(r => r.kind === "draft" && r.spool === name);
    if (seen) { writeResult(dir, name, { ok: true, draft: seen.id, deadline: seen.deadline }); return; }
    const refuse = async (rule: string, shape?: string) => {
      await this.chain.append(this.file(peer, "outbox.jsonl"), refusalRecord(rec.text, { ok: false, rule, ...(shape ? { shape } : {}) }, this.ts()));
      if (rec.source === "telegram") await this.resultNotify(peer, mintId(), "REFUSED", rec.replyTo ?? 0, { rule });
      writeResult(dir, name, { ok: false, rule, ...(shape ? { shape } : {}) });
    };
    const rule = sendRule(this.threads, this.cfg.peers, peer, rec);
    if (!rule.ok) return refuse(rule.rule);
    if (badChars(rec.text)) return refuse("characters");
    const res = await this.egress(rec.text, this.ctxFor({ peer, msgKind: rec.kind, isRoot: rec.replyTo === undefined, isTemplate: false, replyTo: rec.replyTo ?? null, text: rec.text, allowShape: rec.allowShape, corpus: this.corpusOf(rec.source), checkUsage: true }));
    if (!res.ok) return refuse(res.rule, res.shape);
    const id = mintId(), deadline = this.now() + DRAFT_TTL_MS;
    if (reviewTooLong({ peer, root: rec.replyTo ?? 0, draft: id, source: rec.source, session: rec.session, deadline, text: rec.text }, this.cfg.himmelRoot)) return refuse("review-length");
    const all = this.allOutboxes(), chief = rec.source === "chief";
    if (pendingCount(all, chief) >= (chief ? MAX_PENDING_CHIEF : MAX_PENDING_DRAFTS)) return refuse(chief ? "chief-pending" : "too-many-pending");
    if (draftsToday(all, this.now(), chief) >= (chief ? MAX_CHIEF_PER_DAY : MAX_DRAFTS_PER_DAY)) return refuse(chief ? "chief-daily" : "daily-drafts");
    const d = { kind: "draft", id, source: rec.source, ...(rec.session ? { session: rec.session } : {}), msgKind: rec.kind, replyTo: rec.replyTo ?? null, text: rec.text, ...(rec.allowShape ? { allowShape: rec.allowShape } : {}), spool: name, deadline, ts: this.ts() };
    await this.chain.append(this.file(peer, "outbox.jsonl"), d);
    await this.draftNotify(peer, d);
    writeResult(dir, name, { ok: true, draft: id, deadline });
  }

  private async applyTap(peer: string, name: string, rec: Extract<SpoolRec, { type: "tap" }>): Promise<void> {
    const dir = this.dir(peer);
    const no = (rule: string) => { this.log(`tap-refused peer=${peer} draft=${rec.draft} rule=${rule}`); writeResult(dir, name, { ok: false, rule }); };
    const result = (what: string) => this.log(`tap-result peer=${peer} draft=${rec.draft} result=${what}`);
    if (rec.sig === undefined) return no("tap-unsigned");
    if (!tapSigOk(this.deps.configDir, { ...rec, peer }, rec.sig)) return no("tap-bad-sig");
    if (rec.by !== String(this.cfg.operatorChatId)) return no("not-operator");
    const out = this.outbox(peer);
    const d = out.find(r => r.kind === "draft" && r.id === rec.draft);
    if (!d) return no("unknown-draft");
    const state = draftState(out, d.id);
    if (state !== "PENDING") return no(state === "SENDING" ? "already-sending" : `already-${state!.toLowerCase()}`);
    const done = async (s: "REJECTED" | "EXPIRED" | "REFUSED", rule?: string) => { await this.finishDraft(peer, d, s, rule); result(`${s.toLowerCase()}${rule ? ` rule=${rule}` : ""}`); writeResult(dir, name, s === "REJECTED" ? { ok: true } : { ok: false, rule: rule ?? s.toLowerCase() }); };
    if (rec.verb === "no") return done("REJECTED");
    if (this.now() > d.deadline) return done("EXPIRED");
    if (lockdownEnabled(this.cfg.bridgeRoot)) return done("REFUSED", "lockdown");
    const rule = sendRule(this.threads, this.cfg.peers, peer, { replyTo: d.replyTo ?? undefined });
    if (!rule.ok) return done("REFUSED", rule.rule);
    if (badChars(d.text)) return done("REFUSED", "characters");
    const isRoot = d.replyTo === null;
    const res = await this.egress(d.text, this.ctxFor({ peer, msgKind: d.msgKind, isRoot, isTemplate: false, replyTo: d.replyTo, text: d.text, allowShape: d.allowShape, corpus: this.corpusOf(d.source), checkUsage: true }));
    if (!res.ok) return done("REFUSED", res.rule);
    const intent = await this.chain.append(this.file(peer, "outbox.jsonl"), {
      kind: "intent", peer, chat: this.cfg.peers[peer].chatId, id: d.id, root: d.replyTo, msgKind: d.msgKind, text: d.text, isRoot, draft: d.id, by: rec.by, source: d.source,
    });
    this.pending.set(`${peer}:${intent.n}`, intent as unknown as Pending);
    result("approved");
    writeResult(dir, name, { ok: true, draft: d.id });
  }

  private async settleDrafts(): Promise<void> {
    for (const peer of Object.keys(this.cfg.peers)) {
      const out = this.outbox(peer);
      for (const d of out.filter(r => r.kind === "draft")) {
        const state = draftState(out, d.id)!;
        const noted = (type: string) => (readChain(notifyFile(this.deps.stateDir)) as Record<string, any>[]).some(r => r.type === type && r.draft === d.id);
        if (state === "PENDING" && this.now() > d.deadline) { await this.finishDraft(peer, d, "EXPIRED"); continue; }
        if (state === "PENDING") { if (!noted("draft")) await this.draftNotify(peer, d); continue; }
        if (state === "SENDING" || state === "REJECTED" || state === "EXPIRED") { if (state !== "SENDING") await this.resultNotify(peer, d.id, state, d.replyTo ?? 0); continue; }
        const intent = out.find(r => r.kind === "intent" && r.draft === d.id)!;
        if (state === "SENT") { const sent = out.find(r => r.kind === "sent" && r.intent === intent.n)!; await this.resultNotify(peer, d.id, "SENT", d.replyTo ?? sent.message_id, { message_id: sent.message_id }); }
        else if (state === "FAILED") await this.resultNotify(peer, d.id, "FAILED", d.replyTo ?? 0);
        else {
          const why = out.find(r => (r.kind === "refused" && r.intent === intent?.n) || (r.kind === "draft-result" && r.draft === d.id));
          await this.resultNotify(peer, d.id, "REFUSED", d.replyTo ?? 0, { rule: String(why?.reason ?? why?.rule ?? "refused") });
        }
      }
    }
  }

  private async apply(actions: Action[]): Promise<void> {
    for (const a of actions) {
      if ("state" in a) {
        await this.chain.append(this.file(a.state.peer, "threads.jsonl"), a.state);
        this.gate.roots.add(`${a.state.chat}:${a.state.root}`);
      } else if ("send" in a) {
        const { peer, tpl, root, by } = a.send;
        const id = mintId();
        await this.enqueue({ peer, msgKind: tpl, isRoot: false, isTemplate: true, replyTo: root, text: templateLine(tpl, root, id, by), id, checkUsage: false });
      } else if ("resend" in a) {
        const orig = this.rootIntents.get(`${a.resend.peer}:${a.resend.root}`);
        if (!orig) { this.log(`resend: no original for ${a.resend.peer} ${a.resend.root}`); continue; }
        await this.enqueue({ peer: orig.peer, msgKind: orig.msgKind, isRoot: true, isTemplate: false, replyTo: null, text: orig.text, id: orig.id, resend: true, corpus: this.corpusOf(orig.source ?? "send.ts"), source: orig.source, checkUsage: false });
      } else {
        await this.waker.wake(a.wake);
      }
    }
  }

  private ctxFor(item: Item): OutCtx {
    const queued = [...this.pending.values()].filter(i => i.peer === item.peer);
    const sent = (this.sentTimes.get(item.peer) ?? []).filter(t => this.now() - t < 60_000).length + queued.length;
    const open = this.threads.openOutbound(item.peer) + queued.filter(i => i.isRoot && !i.resend && !i.tpl).length;
    return {
      peer: this.cfg.peers[item.peer], kind: item.msgKind, isRoot: item.isRoot, isTemplate: item.isTemplate,
      corpus: item.corpus, tainted: !item.allowShape, tty: Boolean(item.allowShape), claudecode: false, allowShape: item.allowShape,
      himmelRoot: this.cfg.himmelRoot, maxTextChars: this.cfg.maxTextChars, matrix: this.deps.matrix, hostname: this.deps.hostname,
      usage: item.checkUsage ? { openOutbound: open, sentLastMinute: sent } : undefined,
    };
  }

  private egress(text: string, ctx: OutCtx): Promise<Outcome> {
    return checkOutbound(text, ctx);
  }

  private async enqueue(item: Item): Promise<{ ok: true } | Refusal> {
    const res = await this.egress(item.text, this.ctxFor(item));
    if (!res.ok) {
      await this.chain.append(this.file(item.peer, "outbox.jsonl"), refusalRecord(item.text, res, this.ts()));
      return res;
    }
    const peer = this.cfg.peers[item.peer];
    const rec = await this.chain.append(this.file(item.peer, "outbox.jsonl"), {
      kind: "intent", peer: item.peer, chat: peer.chatId, id: item.id ?? mintId(), root: item.replyTo, msgKind: item.msgKind, text: item.text,
      isRoot: item.isRoot, ...(item.isTemplate ? { tpl: true } : {}), ...(item.resend ? { resend: true } : {}), ...(item.spool ? { spool: item.spool } : {}), ...(item.source ? { source: item.source } : {}),
    });
    this.pending.set(`${item.peer}:${rec.n}`, rec as unknown as Pending);
    return { ok: true };
  }

  private wire(i: Pending): string {
    if (i.tpl || i.env || i.msgKind === "card") return i.text;
    const address = i.isRoot ? `/peer@${this.cfg.peers[i.peer].theirs.username}\n` : "";
    return `${address}#${kindLine(i.msgKind)} id=${i.id}\n${i.text}`;
  }

  async flushIntents(): Promise<void> {
    await this.serial(() => this.flush());
  }

  private async flush(): Promise<void> {
    await this.flushPeer();
    await this.deliverNotify();
  }

  private async refuseCard(i: Pending, res: Refusal): Promise<void> {
    await this.chain.append(this.file(i.peer, "outbox.jsonl"), { ...refusalRecord(i.text, res, this.ts()), intent: i.n });
    this.pending.delete(`${i.peer}:${i.n}`);
    this.log(`card-send peer=${i.peer} refused: ${res.rule}`);
  }

  private async flushPeer(): Promise<void> {
    if (this.now() < this.retryAt) return;
    for (const i of [...this.pending.values()].sort((a, b) => a.n - b.n || (a.peer < b.peer ? -1 : 1))) {
      const peer = this.cfg.peers[i.peer];
      if (!peer || peer.chatId === null) continue;
      if (i.msgKind === "card") {
        const ok = await this.checkCard(i.peer, i.text);
        if (!ok.ok) { await this.refuseCard(i, ok); continue; }
      }
      let messageId: number;
      try {
        messageId = (await this.deps.tg.sendMessage(peer.chatId, this.wire(i), i.root ?? undefined)).message_id;
      } catch (e) {
        if (e instanceof RetryAfter) { this.retryAt = this.now() + e.seconds * 1000; return; }
        if (e instanceof TelegramError && PERMANENT.includes(e.code)) {
          await this.chain.append(this.file(i.peer, "outbox.jsonl"), { kind: "failed", intent: i.n, id: i.id, code: e.code, ts: this.ts() });
          this.pending.delete(`${i.peer}:${i.n}`);
          if (i.spool) writeResult(this.dir(i.peer), i.spool, { ok: false, rule: `telegram-${e.code}` });
          if (i.draft) await this.resultNotify(i.peer, i.draft, "FAILED", i.root ?? 0);
          continue;
        }
        this.failures += 1;
        this.retryAt = this.now() + Math.min(60_000, 1000 * 2 ** Math.min(this.failures, 6));
        this.log(`send failed: ${(e as Error).message}`);
        return;
      }
      this.failures = 0;
      await this.chain.append(this.file(i.peer, "outbox.jsonl"), { kind: "sent", id: i.id, intent: i.n, message_id: messageId, ts: this.ts() });
      this.pending.delete(`${i.peer}:${i.n}`);
      const times = this.sentTimes.get(i.peer) ?? []; times.push(this.now()); this.sentTimes.set(i.peer, times);
      if (i.isRoot && !i.resend && !i.tpl) this.rootIntents.set(`${i.peer}:${messageId}`, i);
      if (i.draft) await this.resultNotify(i.peer, i.draft, "SENT", i.root ?? messageId, { message_id: messageId });
      if (i.spool) { this.spoolDone.set(`${i.peer}/${i.spool}`, messageId); writeResult(this.dir(i.peer), i.spool, { ok: true, message_id: messageId }); }
      if (i.tpl || i.resend || i.env || i.msgKind === "card") continue;
      if (i.isRoot) await this.apply(this.threads.onOutbound({ peer: i.peer, chat: peer.chatId, root: messageId, kind: i.msgKind, isRoot: true }));
      else if (i.msgKind === "answer" && i.root !== null) await this.apply(this.threads.onOutbound({ peer: i.peer, chat: peer.chatId, root: i.root, kind: "answer", isRoot: false }));
    }
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function writeCodeStamp(S: string): Promise<void> {
  fs.mkdirSync(join(S, "notify"), { recursive: true, mode: 0o700 });
  await atomicWrite(join(S, "notify", "bot.code"), JSON.stringify({ pid: process.pid, start: startIdentity(process.pid), code: CODE_VERSION }));
}

const fileStamp = (path: string) => { try { const st = fs.statSync(path); return `${st.ino}:${st.size}:${st.mtimeMs}:${st.ctimeMs}`; } catch { return ""; } };

export async function main(): Promise<void> {
  let seen = fileStamp(peersFile());
  let cfg: Config;
  try { cfg = loadConfig(peersFile()); } catch (e) {
    if (e instanceof ConfigError) { console.error(`peer-bridge: ${e.message}`); process.exit(EXIT_CONFIG); }
    throw e;
  }
  const token = process.env.PEER_BOT_TOKEN!;
  if (!fs.existsSync(stateDir())) { console.error("peer-bridge: no state dir; run setup first"); process.exit(EXIT_CONFIG); }
  let release: () => void;
  try { release = acquirePidLock(join(stateDir(), "poller.pid")); } catch (e) {
    if (e instanceof PidLockError) { console.error(`peer-bridge: ${e.message}`); process.exit(1); }
    throw e;
  }
  let stop = false;
  const done = () => { stop = true; release(); process.exit(0); };
  process.on("SIGTERM", done);
  process.on("SIGINT", done);

  try { await writeCodeStamp(stateDir()); } catch (e) { console.error(`peer-bridge: cannot write the code stamp: ${(e as Error).message}`); }
  const tg = new PeerTelegram(token);
  const poller = await Poller.create({
    cfg, tg, ourBotId: botIdFromToken(token), stateDir: stateDir(), configDir: configDir(), peersPath: peersFile(),
    reloadConfig: () => loadConfig(peersFile()),
  });
  try { await poller.start(); } catch (e) {
    if (e instanceof TelegramError && e.code === 401) { console.error("peer-bridge: the bot token was refused"); release(); process.exit(EXIT_CONFIG); }
    if (e instanceof StartLookupError) { console.error(`peer-bridge: ${e.message}`); release(); process.exit(1); }
    throw e;
  }
  const guard = (fn: () => Promise<void>) => () => fn().catch(e => { console.error(`peer-bridge: ${(e as Error).message}`); process.exit(1); });
  setInterval(guard(() => poller.tick()), 30_000); // t13b-ok: the poller's own deadline tick
  setInterval(guard(() => poller.drainSpool()), 1_000); // t13b-ok: the poller's own spool drain
  setInterval(guard(async () => { const now = fileStamp(peersFile()); if (now !== seen) { seen = now; await poller.reload(); } }), 2_000); // t13b-ok: the poller's own peers.json watch

  while (!stop) {
    try {
      await poller.processBatch(await tg.getUpdates(poller.offset, 25));
    } catch (e) {
      if (e instanceof RetryAfter) { await sleep(e.seconds * 1000); continue; }
      if (e instanceof TelegramError) {
        if (e.code === 401) { console.error("peer-bridge: the bot token was refused"); release(); process.exit(EXIT_CONFIG); }
        console.error(`peer-bridge: ${e.message}`);
        await sleep(5000);
        continue;
      }
      throw e;
    }
  }
}

if (import.meta.main) main();
