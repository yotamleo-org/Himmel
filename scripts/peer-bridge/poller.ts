// The peer bridge poller: the one process that writes every chain file. It
// takes Telegram updates through the admission gate, keeps thread state and
// deadlines, runs the tool-less reader, sends through the egress gate with an
// intent record before every Telegram call, and drains the spool that send.ts,
// read.ts and setup.ts fill. It parses peer text only with the two control-line
// regexes and starts only the processes proc.ts lists.
import fs from "node:fs";
import { join } from "node:path";
import { atomicWrite } from "../telegram/bus";
import { Chain, PidLockError, acquirePidLock, drainSpool, readChain, sweepResults, writeResult, type IntentRec, type SpoolRec } from "./chain";
import { ConfigError, EXIT_CONFIG, loadConfig, type Config } from "./config";
import { digestFile, parseAck, writeCursor, type DigestRec } from "./digests";
import { checkOutbound, refusalRecord, type OutCtx, type Outcome, type Refusal } from "./egress";
import { admit, appendUnknownChat, createGateState, noteAdmitted, rebuildFromInbox, type GateState, type PeerMsgRec } from "./gate";
import { mintId } from "./grammar";
import { botIdFromToken, configDir, peersFile, stateDir } from "./ids";
import { ReaderLedger, runReader } from "./reader";
import { PeerTelegram, RetryAfter, TelegramError } from "./telegram";
import { Threads, templateLine, type Action, type ThreadRec } from "./threads";
import { Waker } from "./wake";

export type TgLike = Pick<PeerTelegram, "getUpdates" | "sendMessage" | "getChatMember">;
export type PollerDeps = {
  cfg: Config;
  tg: TgLike;
  ourBotId: string;
  stateDir: string;
  configDir: string;
  clock?: () => number;
  reloadConfig?: () => Config;
  matrix?: OutCtx["matrix"];
  hostname?: string;
  readerRun?: typeof runReader;
  readerTimeoutMs?: number;
  log?: (line: string) => void;
};

type Pending = IntentRec & { n: number };
type Item = { peer: string; msgKind: string; isRoot: boolean; isTemplate: boolean; replyTo: number | null; text: string; id?: string; spool?: string; resend?: boolean; allowShape?: string; checkUsage: boolean };

const kindLine = (k: string) => (k === "question" ? "ask:question" : k);
const PERMANENT = [400, 403, 404];

export class Poller {
  offset = 0;
  threads!: Threads;
  gate!: GateState;
  private cfg: Config;
  private chain = new Chain();
  private waker: Waker;
  private pending = new Map<string, Pending>();
  private rootIntents = new Map<string, Pending>();
  private spoolDone = new Map<string, number>();
  private sentTimes = new Map<string, number[]>();
  private retryAt = 0;
  private failures = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private now: () => number;
  private log: (line: string) => void;

  private constructor(private deps: PollerDeps) {
    this.cfg = deps.cfg;
    this.now = deps.clock ?? Date.now;
    this.log = deps.log ?? ((l: string) => console.error(l));
    this.waker = new Waker(this.cfg, this.now);
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
    const threadRecs: ThreadRec[] = [], inbox: PeerMsgRec[] = [];
    for (const peer of Object.keys(this.cfg.peers)) {
      for (const r of readChain(this.file(peer, "threads.jsonl"))) if (r.kind === "thread") threadRecs.push(r as unknown as ThreadRec);
      for (const r of readChain(this.file(peer, "inbox.jsonl"))) if (r.kind === "peer-msg") inbox.push(r as unknown as PeerMsgRec);
      this.loadOutbox(peer);
    }
    this.threads = Threads.load(threadRecs, this.threadOpts());
    this.gate = createGateState({ ourBotId: this.deps.ourBotId, ourUsername: "", committed: this.offset - 1, now: this.now() });
    for (const r of this.threads.roots()) this.gate.roots.add(r);
    rebuildFromInbox(this.gate, inbox);
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

  private async ensureUsername() {
    if (this.gate.ourUsername) return;
    const peer = Object.values(this.cfg.peers).find(p => p.chatId !== null);
    if (!peer) return;
    try {
      const m = await this.deps.tg.getChatMember(peer.chatId!, Number(this.deps.ourBotId));
      if (typeof m?.user?.username === "string") this.gate.ourUsername = m.user.username;
    } catch (e) { this.log(`username lookup failed: ${(e as Error).message}`); }
  }

  async recover(): Promise<void> {
    await this.serial(async () => {
      await this.ensureUsername();
      for (const i of [...this.pending.values()]) {
        const res = await this.egress(i.text, this.ctxFor({ peer: i.peer, msgKind: i.msgKind, isRoot: i.isRoot, isTemplate: !!i.tpl, replyTo: i.root, text: i.text, checkUsage: false }));
        if (res.ok) continue;
        await this.chain.append(this.file(i.peer, "outbox.jsonl"), { ...refusalRecord(i.text, res, this.ts()), intent: i.n });
        this.pending.delete(`${i.peer}:${i.n}`);
        if (i.spool) writeResult(this.dir(i.peer), i.spool, { ok: false, rule: res.rule, ...(res.shape ? { shape: res.shape } : {}) });
      }
      await this.flush();
    });
  }

  private commitOffset(next: number): Promise<void> {
    this.offset = next;
    return atomicWrite(join(this.deps.stateDir, "offset"), String(next));
  }

  // One batch of updates. The offset moves only after every record of the batch
  // is on disk, so a failed append replays the batch.
  async processBatch(updates: any[]): Promise<void> {
    const jobs: PeerMsgRec[] = [];
    await this.serial(async () => {
      let max = this.offset - 1;
      for (const u of [...updates].sort((a, b) => a.update_id - b.update_id)) {
        this.gate.now = this.now();
        const r = admit(u, this.cfg, this.gate);
        if (Number.isSafeInteger(u.update_id)) max = Math.max(max, u.update_id);
        if (!r.ok) {
          this.log(r.log);
          if (r.unknownChat) appendUnknownChat(join(this.deps.stateDir, "unknown-chats.jsonl"), r.unknownChat);
          continue;
        }
        await this.chain.append(this.file(r.peer, "inbox.jsonl"), r.rec);
        noteAdmitted(this.gate, r.rec);
        const actions = this.threads.onInbound(r.rec);
        await this.apply(actions);
        const opened = actions.some(a => "state" in a && a.state.dir === "in" && a.state.root === r.rec.message_id);
        const answered = r.rec.tag === "answer" && this.threads.get(r.peer, r.rec.root_id) !== undefined;
        if (opened || answered) jobs.push(r.rec);
      }
      if (max >= this.offset) {
        await this.commitOffset(max + 1);
        this.gate.committed = max;
      }
      await this.flush();
    });
    for (const rec of jobs) await this.readAndDigest(rec);
  }

  private async readAndDigest(rec: PeerMsgRec): Promise<void> {
    const peer = this.cfg.peers[rec.peer];
    if (!peer) return;
    const ledger = new ReaderLedger(this.file(rec.peer, "reader-ledger.json"), peer, this.now);
    const run = this.deps.readerRun ?? runReader;
    const kind = rec.tag === "answer" ? "answer" : rec.tag.replace("ask:", "");
    const d = await run(rec.text, kind, { himmelRoot: this.cfg.himmelRoot, ledger, timeoutMs: this.deps.readerTimeoutMs });
    const out: Omit<DigestRec, "n" | "h"> = { kind: "digest", peer: rec.peer, message_id: rec.message_id, root_id: rec.root_id, tag: rec.tag, from_id: rec.from_id, ts: this.ts(), summary: d.summary, asks: d.asks, ...(rec.id ? { id: rec.id } : {}), ...(d.reason ? { reason: d.reason } : {}) };
    await this.chain.append(digestFile(this.dir(rec.peer)), out);
  }

  async tick(): Promise<void> {
    await this.serial(async () => {
      await this.ensureUsername();
      await this.apply(this.threads.tick(this.now()));
      await this.flush();
      for (const peer of Object.keys(this.cfg.peers)) sweepResults(this.dir(peer), 86_400_000, this.now());
    });
  }

  async drainSpool(): Promise<void> {
    await this.serial(async () => {
      for (const peer of Object.keys(this.cfg.peers)) {
        if (!fs.existsSync(join(this.dir(peer), "spool"))) continue;
        for (const d of drainSpool(this.dir(peer))) {
          if ("malformed" in d) { writeResult(this.dir(peer), d.name, { ok: false, rule: "malformed" }); continue; }
          await this.applySpool(peer, d.name, d.rec);
        }
      }
      await this.flush();
    });
  }

  private async applySpool(peer: string, name: string, rec: SpoolRec): Promise<void> {
    const dir = this.dir(peer);
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
      try {
        this.cfg = this.deps.reloadConfig ? this.deps.reloadConfig() : this.cfg;
      } catch (e) {
        if (!(e instanceof ConfigError)) throw e;
        writeResult(dir, name, { ok: false, rule: "config" });
        return;
      }
      this.threads = Threads.load(this.threads.all(), this.threadOpts());
      this.waker = new Waker(this.cfg, this.now);
      await this.chain.append(this.file(peer, "outbox.jsonl"), { kind: "confirmed", chat_id: rec.chatId, ts: this.ts() });
      await this.ensureUsername();
      writeResult(dir, name, { ok: true });
      return;
    }
    // A send. The result is written once Telegram has the message; until then the
    // spool file stays, and a replay finds the pending intent by its spool name.
    if (this.spoolDone.has(`${peer}/${name}`)) { writeResult(dir, name, { ok: true, message_id: this.spoolDone.get(`${peer}/${name}`)! }); return; }
    if ([...this.pending.values()].some(i => i.peer === peer && i.spool === name)) return;
    const isRoot = rec.replyTo === undefined;
    if (!isRoot && this.threads.get(peer, rec.replyTo!)?.dir !== "in") { writeResult(dir, name, { ok: false, rule: "unknown-thread" }); return; }
    const res = await this.enqueue({ peer, msgKind: rec.kind, isRoot, isTemplate: false, replyTo: rec.replyTo ?? null, text: rec.text, spool: name, allowShape: rec.allowShape, checkUsage: true });
    if (!res.ok) writeResult(dir, name, { ok: false, rule: res.rule, ...(res.shape ? { shape: res.shape } : {}) });
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
        await this.enqueue({ peer: orig.peer, msgKind: orig.msgKind, isRoot: true, isTemplate: false, replyTo: null, text: orig.text, id: orig.id, resend: true, checkUsage: false });
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
      tainted: !item.allowShape, tty: Boolean(item.allowShape), claudecode: false, allowShape: item.allowShape,
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
      isRoot: item.isRoot, ...(item.isTemplate ? { tpl: true } : {}), ...(item.resend ? { resend: true } : {}), ...(item.spool ? { spool: item.spool } : {}),
    });
    this.pending.set(`${item.peer}:${rec.n}`, rec as unknown as Pending);
    return { ok: true };
  }

  private wire(i: Pending): string {
    if (i.tpl) return i.text;
    const address = i.isRoot ? `/peer@${this.cfg.peers[i.peer].theirs.username}\n` : "";
    return `${address}#${kindLine(i.msgKind)} id=${i.id}\n${i.text}`;
  }

  async flushIntents(): Promise<void> {
    await this.serial(() => this.flush());
  }

  private async flush(): Promise<void> {
    if (this.now() < this.retryAt) return;
    for (const i of [...this.pending.values()].sort((a, b) => a.n - b.n || (a.peer < b.peer ? -1 : 1))) {
      const peer = this.cfg.peers[i.peer];
      if (!peer || peer.chatId === null) continue;
      let messageId: number;
      try {
        messageId = (await this.deps.tg.sendMessage(peer.chatId, this.wire(i), i.root ?? undefined)).message_id;
      } catch (e) {
        if (e instanceof RetryAfter) { this.retryAt = this.now() + e.seconds * 1000; return; }
        if (e instanceof TelegramError && PERMANENT.includes(e.code)) {
          await this.chain.append(this.file(i.peer, "outbox.jsonl"), { kind: "failed", intent: i.n, id: i.id, code: e.code, ts: this.ts() });
          this.pending.delete(`${i.peer}:${i.n}`);
          if (i.spool) writeResult(this.dir(i.peer), i.spool, { ok: false, rule: `telegram-${e.code}` });
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
      if (i.spool) { this.spoolDone.set(`${i.peer}/${i.spool}`, messageId); writeResult(this.dir(i.peer), i.spool, { ok: true, message_id: messageId }); }
      if (i.tpl || i.resend) continue;
      if (i.isRoot) await this.apply(this.threads.onOutbound({ peer: i.peer, chat: peer.chatId, root: messageId, kind: i.msgKind, isRoot: true }));
      else if (i.msgKind === "answer" && i.root !== null) await this.apply(this.threads.onOutbound({ peer: i.peer, chat: peer.chatId, root: i.root, kind: "answer", isRoot: false }));
    }
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

export async function main(): Promise<void> {
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

  const tg = new PeerTelegram(token);
  const poller = await Poller.create({
    cfg, tg, ourBotId: botIdFromToken(token), stateDir: stateDir(), configDir: configDir(),
    reloadConfig: () => loadConfig(peersFile()),
  });
  await poller.recover();
  const guard = (fn: () => Promise<void>) => () => fn().catch(e => { console.error(`peer-bridge: ${(e as Error).message}`); process.exit(1); });
  setInterval(guard(() => poller.tick()), 30_000); // t13b-ok: the poller's own deadline tick
  setInterval(guard(() => poller.drainSpool()), 1_000); // t13b-ok: the poller's own spool drain

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
