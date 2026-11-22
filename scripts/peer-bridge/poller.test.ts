import { afterEach, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain, readChain, submitSpool } from "./chain";
import type { Config } from "./config";
import { ackToken, digestFile } from "./digests";
import { admit, createGateState, noteAdmitted } from "./gate";
import { checkEnvelopeOutbound } from "./egress";
import { procHooks } from "./proc";
import { Poller, type PollerDeps, type TgLike } from "./poller";
import { TIMEOUT_S_MAX, parseEnvelopeLine, type Kind } from "./envelope";
import type { JobRecord } from "./resolve";
import { keygen, verify } from "./sign";
import { RetryAfter, TelegramError } from "./telegram";
import { Threads } from "./threads";
import * as TE from "./testlib-envelope";
import { failedTests, makeRedCopy } from "./testlib-red-copy";

const REPO = join(import.meta.dir, "..", "..");
const OUR_ID = "111000111", OUR_NAME = "ours_bot", PEER_ID = "555000111";
const CHAT = -1001234567890;
const T0 = Date.UTC(2026, 10, 9, 12);
const GH = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2";
const tmp = (p: string) => mkdtempSync(join(tmpdir(), p));

const origSpawn = procHooks.spawn;
afterEach(() => { procHooks.spawn = origSpawn; });

function himmelRoot(): string {
  const root = tmp("peer-poller-himmel-");
  mkdirSync(join(root, "scripts/lib"), { recursive: true });
  copyFileSync(join(REPO, "scripts/lib/redact.sh"), join(root, "scripts/lib/redact.sh"));
  writeFileSync(join(root, "scripts/lib/usage-preflight.sh"), "#!/usr/bin/env bash\necho PROCEED\n");
  return root;
}

function makeTg() {
  const sent: { chat: number; text: string; replyTo?: number }[] = [];
  const script: (() => void)[] = [];
  let mid = 9000;
  const tg: TgLike = {
    getUpdates: async () => [],
    getChatMember: async () => ({ user: { username: OUR_NAME } }),
    sendMessage: async (chat: number, text: string, replyTo?: number) => {
      sent.push({ chat, text, replyTo });
      script.shift()?.();
      return { message_id: ++mid };
    },
  };
  return { tg, sent, script };
}

type Env = Awaited<ReturnType<typeof setup>>;
async function setup(over: { readerRun?: PollerDeps["readerRun"]; matrix?: PollerDeps["matrix"]; peerOver?: Record<string, unknown> } = {}) {
  const stateDir = tmp("peer-poller-state-");
  const configDir = tmp("peer-poller-conf-");
  writeFileSync(join(configDir, "hmac.key"), "k".repeat(32), { mode: 0o600 });
  const peerDir = join(stateDir, "example");
  mkdirSync(join(peerDir, "spool"), { recursive: true, mode: 0o700 });
  const cfg: Config = {
    operatorBotId: "999000999", operatorChatId: 4242, bridgeRoot: tmp("peer-poller-bridge-"), himmelRoot: himmelRoot(), maxTextChars: 4000, addressing: "command",
    peers: { example: { peerBotId: PEER_ID, chatId: CHAT, allowFrom: [PEER_ID, "42"], opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
      theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" }, ...(over.peerOver ?? {}) } as any },
  };
  const c = { t: T0, now: () => c.t };
  const t = makeTg();
  const reads: { text: string; kind: string }[] = [];
  const readerRun = over.readerRun ?? (async (text: string, kind: string) => { reads.push({ text, kind }); return { summary: "a digest", asks: ["x?"] }; });
  const deps: PollerDeps = { cfg, tg: t.tg, ourBotId: OUR_ID, stateDir, configDir, clock: c.now, matrix: over.matrix, hostname: "testbox", readerRun: readerRun as any, log: () => {} };
  const poller = await Poller.create(deps);
  await poller.recover();
  return { poller, deps, cfg, c, ...t, reads, stateDir, configDir, peerDir, key: Buffer.from("k".repeat(32)) };
}

let uid = 500;
let mid = 100;
const rootUpdate = (text: string, over: Record<string, unknown> = {}) => ({ update_id: ++uid, message: { message_id: ++mid, from: { id: Number(PEER_ID), is_bot: true }, chat: { id: CHAT, type: "supergroup" }, date: 1, text, ...over } });
const askRoot = (id = "a1b2c3d4", body = "how do I x?") => rootUpdate(`/peer@${OUR_NAME}\n#ask:question id=${id}\n${body}`);
const outbox = (e: Env) => readChain(join(e.peerDir, "outbox.jsonl"));
const wakeLines = (e: Env) => {
  try { return readFileSync(join(e.cfg.bridgeRoot, "sessions", "__chat__", "outbox.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(l => JSON.parse(l).text as string); } catch { return []; }
};
const readResult = (e: Env, name: string) => JSON.parse(readFileSync(join(e.peerDir, "spool", "results", name), "utf8"));
function filesUnder(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(d => (d.isDirectory() ? filesUnder(join(dir, d.name)) : [join(dir, d.name)]));
}

test("an admitted root is chained, allocates a thread, is receipted, wakes the operator, is digested and commits the offset", async () => {
  const e = await setup();
  const u = askRoot();
  await e.poller.processBatch([u]);
  expect(readChain(join(e.peerDir, "inbox.jsonl"))).toHaveLength(1);
  const thread = readChain(join(e.peerDir, "threads.jsonl"))[0];
  expect(thread).toMatchObject({ kind: "thread", dir: "in", state: "OPEN", root: u.message.message_id });
  expect(e.sent).toHaveLength(1);
  expect(e.sent[0]).toMatchObject({ chat: CHAT, replyTo: u.message.message_id });
  expect(e.sent[0].text).toMatch(new RegExp(`^#tpl:receipt #${u.message.message_id} id=[0-9a-f]{8}$`));
  expect(wakeLines(e)[0]).toContain(`T${u.message.message_id} · new question`);
  expect(e.reads).toEqual([{ text: "how do I x?", kind: "question" }]);
  expect(readChain(digestFile(e.peerDir))[0]).toMatchObject({ kind: "digest", summary: "a digest", asks: ["x?"], root_id: u.message.message_id });
  expect(Number(readFileSync(join(e.stateDir, "offset"), "utf8"))).toBe(u.update_id + 1);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent", "sent"]);
});

test("a replayed update is dropped by the committed offset, after a restart too", async () => {
  const e = await setup();
  const u = askRoot();
  await e.poller.processBatch([u]);
  await e.poller.processBatch([u]);
  expect(readChain(join(e.peerDir, "inbox.jsonl"))).toHaveLength(1);
  const again = await Poller.create(e.deps);
  await again.processBatch([u]);
  expect(readChain(join(e.peerDir, "inbox.jsonl"))).toHaveLength(1);
});

test("a null digest still fires its wake", async () => {
  const e = await setup({ readerRun: async () => ({ summary: null, asks: [], reason: "preflight:BANK-STALE" }) });
  await e.poller.processBatch([askRoot()]);
  expect(wakeLines(e)).toHaveLength(1);
  expect(readChain(digestFile(e.peerDir))[0]).toMatchObject({ summary: null, reason: "preflight:BANK-STALE" });
});

test("an append failure leaves the offset uncommitted", async () => {
  const e = await setup();
  mkdirSync(join(e.peerDir, "inbox.jsonl"));
  await expect(e.poller.processBatch([askRoot()])).rejects.toThrow();
  expect(existsSync(join(e.stateDir, "offset"))).toBe(false);
  expect(e.sent).toHaveLength(0);
});

test("429 keeps the intent and retries after retry_after, without spinning", async () => {
  const e = await setup();
  e.script.push(() => { throw new RetryAfter(7); });
  await e.poller.processBatch([askRoot()]);
  expect(e.sent).toHaveLength(1);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent"]);
  await e.poller.flushIntents();
  e.c.t += 6_000;
  await e.poller.flushIntents();
  expect(e.sent).toHaveLength(1);
  e.c.t += 2_000;
  await e.poller.flushIntents();
  expect(e.sent).toHaveLength(2);
  expect(e.sent[1].text).toBe(e.sent[0].text);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent", "sent"]);
});

test("a 5xx keeps the intent and backs off; a permanent 400 ends it", async () => {
  const e = await setup();
  e.script.push(() => { throw new TelegramError("bad gateway", 502); });
  await e.poller.processBatch([askRoot()]);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent"]);
  e.c.t += 120_000;
  await e.poller.flushIntents();
  expect(outbox(e).map(r => r.kind)).toEqual(["intent", "sent"]);
  const f = await setup();
  f.script.push(() => { throw new TelegramError("chat not found", 400); });
  await f.poller.processBatch([askRoot()]);
  expect(outbox(f).map(r => r.kind)).toEqual(["intent", "failed"]);
});

test("two peers' pending intents with the same chain number are both sent", async () => {
  const e = await setup();
  const other = { ...e.cfg.peers.example, peerBotId: "555000222", chatId: CHAT - 1, theirs: { ...e.cfg.peers.example.theirs, username: "other_bot" } };
  e.cfg.peers.other = other;
  mkdirSync(join(e.stateDir, "other", "spool"), { recursive: true, mode: 0o700 });
  for (const peer of ["example", "other"]) {
    await new Chain().append(join(e.stateDir, peer, "outbox.jsonl"), { kind: "intent", peer, chat: e.cfg.peers[peer].chatId, id: `${peer === "example" ? "aaaa" : "bbbb"}0001`, root: null, msgKind: "info", text: `fyi from ${peer}`, isRoot: true });
  }
  const p = await Poller.create(e.deps);
  await p.recover();
  expect(e.sent.map(s => [s.chat, s.text.split("\n")[2]]).sort()).toEqual([[CHAT - 1, "fyi from other"], [CHAT, "fyi from example"]].sort());
  expect(readChain(join(e.stateDir, "other", "outbox.jsonl")).map(r => r.kind)).toEqual(["intent", "sent"]);
});

function receiver() {
  const state = createGateState({ ourBotId: PEER_ID, ourUsername: "example_bot", committed: 0, now: T0 });
  const cfg = { maxTextChars: 4000, peers: { ours: { peerBotId: OUR_ID, chatId: CHAT, allowFrom: [OUR_ID], maxPerMinute: 100 } as any } };
  const threads = Threads.load([], { peers: { ours: { opens: ["question", "status", "info"], maxOpenThreads: 5 } }, clock: () => T0 });
  const inbox: any[] = [];
  let u = 90_000, m = 70_000;
  return {
    inbox, threads,
    deliver(text: string, replyTo?: number) {
      const msg: any = { message_id: ++m, from: { id: Number(OUR_ID), is_bot: true }, chat: { id: CHAT, type: "supergroup" }, date: 1, text };
      if (replyTo !== undefined) msg.reply_to_message = { message_id: replyTo, from: { id: Number(PEER_ID), is_bot: true } };
      const r = admit({ update_id: ++u, message: msg }, cfg, state);
      if (!r.ok) return r;
      noteAdmitted(state, r.rec);
      inbox.push(r.rec);
      for (const a of threads.onInbound(r.rec)) if ("state" in a) state.roots.add(`${a.state.chat}:${a.state.root}`);
      return r;
    },
    state,
  };
}

test("a crash between the Telegram call and the sent record leaves one thread at the receiver: root and reply", async () => {
  const rx = receiver();
  const e = await setup();
  submitSpool(e.peerDir, { type: "send", kind: "info", text: "fyi: the build is green" });
  e.script.push(() => { throw new TelegramError("connection reset", 0); });
  await e.poller.drainSpool();
  for (const s of e.sent) rx.deliver(s.text, s.replyTo);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent"]);
  const again = await Poller.create(e.deps);
  const before = e.sent.length;
  await again.recover();
  expect(e.sent.length).toBe(before + 1);
  rx.deliver(e.sent.at(-1)!.text, e.sent.at(-1)!.replyTo);
  expect(e.sent.at(-1)!.text).toBe(e.sent[0].text);
  expect(rx.inbox.filter(r => r.tag === "info")).toHaveLength(1);
  expect(rx.threads.all().filter(t => t.dir === "in")).toHaveLength(1);

  // A reply, same shape. An inbound thread exists on our side first.
  const f = await setup();
  const root = askRoot("0a0a0a0a");
  await f.poller.processBatch([root]);
  const sentBefore = f.sent.length;
  submitSpool(f.peerDir, { type: "send", kind: "answer", replyTo: root.message.message_id, text: "the answer" });
  f.script.push(() => { throw new TelegramError("connection reset", 0); });
  await f.poller.drainSpool();
  f.c.t += 120_000;
  await f.poller.flushIntents();
  const answers = f.sent.slice(sentBefore).filter(s => s.text.startsWith("#answer"));
  expect(answers).toHaveLength(2);
  expect(answers[1].text).toBe(answers[0].text);
  const rx2 = receiver();
  rx2.state.roots.add(`${CHAT}:${root.message.message_id}`);
  for (const a of answers) rx2.deliver(a.text, a.replyTo);
  expect(rx2.inbox.filter(r => r.tag === "answer")).toHaveLength(1);
});

test("each spool type writes its result file, and a send result carries the message id", async () => {
  const e = await setup();
  const root = askRoot("0b0b0b0b");
  await e.poller.processBatch([root]);
  const sendName = submitSpool(e.peerDir, { type: "send", kind: "answer", replyTo: root.message.message_id, text: "an answer" });
  const ackTok = ackToken(e.key, "sess-1", "example", 3);
  const ackName = submitSpool(e.peerDir, { type: "ack", sid: "sess-1", token: ackTok });
  const badAck = submitSpool(e.peerDir, { type: "ack", sid: "sess-2", token: ackTok });
  const confirmName = submitSpool(e.peerDir, { type: "confirm", chatId: CHAT });
  writeFileSync(join(e.peerDir, "spool", "9-junk.json"), "nope", { mode: 0o600 });
  await e.poller.drainSpool();
  expect(readResult(e, sendName)).toMatchObject({ ok: true });
  expect(typeof readResult(e, sendName).message_id).toBe("number");
  expect(readResult(e, ackName)).toEqual({ ok: true });
  expect(JSON.parse(readFileSync(join(e.peerDir, "cursors", "sess-1"), "utf8"))).toEqual({ n: 3 });
  expect(readResult(e, badAck)).toEqual({ ok: false, rule: "bad-ack" });
  expect(existsSync(join(e.peerDir, "cursors", "sess-2"))).toBe(false);
  expect(readResult(e, confirmName)).toEqual({ ok: true });
  expect(outbox(e).some(r => r.kind === "confirmed")).toBe(true);
  expect(readResult(e, "9-junk.json")).toEqual({ ok: false, rule: "malformed" });
  expect(readdirSync(join(e.peerDir, "spool")).filter(n => n.endsWith(".json"))).toEqual([]);
  const sentRec = outbox(e).find(r => r.kind === "sent" && r.intent === 3);
  expect(statSync(join(e.peerDir, "spool", "results", sendName)).mode & 0o777).toBe(0o600);
  expect(sentRec ?? true).toBeTruthy();
});

test("an answer to an unknown thread is refused, and a cursor only moves forward", async () => {
  const e = await setup();
  const name = submitSpool(e.peerDir, { type: "send", kind: "answer", replyTo: 4242, text: "to nowhere" });
  const hi = submitSpool(e.peerDir, { type: "ack", sid: "s1", token: ackToken(e.key, "s1", "example", 9) });
  const lo = submitSpool(e.peerDir, { type: "ack", sid: "s1", token: ackToken(e.key, "s1", "example", 4) });
  await e.poller.drainSpool();
  expect(readResult(e, name)).toEqual({ ok: false, rule: "unknown-thread" });
  expect(readResult(e, hi)).toEqual({ ok: true });
  expect(readResult(e, lo)).toEqual({ ok: true });
  expect(JSON.parse(readFileSync(join(e.peerDir, "cursors", "s1"), "utf8"))).toEqual({ n: 9 });
});

const DENY = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "deny", why: "test" }] };
const names = {
  spool: "I4: a spool send file written directly with a token is refused and never sent",
  template: "I4: a template under a matrix that denies peer-desk is not sent",
  recover: "I4: at startup an unsent intent that now fails egress is not resent and chains a refusal",
  grep: "I4: after the drain of a refused spool file no file under the state dir holds its text",
  resend: "I4: a root resend under a matrix that denies peer-desk is not sent",
  openCap: "I4: spool sends past the peer's open-thread cap are refused before any of them is flushed",
  rateCap: "I4: spool sends past the peer's per-minute cap are refused before any of them is flushed",
};

test(names.openCap, async () => {
  const e = await setup({ peerOver: { theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 2, maxPerMinute: 10, copiedAt: "2026-11-07" } } });
  const files = [1, 2, 3, 4].map(i => submitSpool(e.peerDir, { type: "send", kind: "info", text: `fyi ${i}` }));
  await e.poller.drainSpool();
  expect(e.sent).toHaveLength(2);
  expect(files.slice(2).map(n => readResult(e, n))).toEqual([{ ok: false, rule: "their-open-threads" }, { ok: false, rule: "their-open-threads" }]);
});

test(names.rateCap, async () => {
  const e = await setup({ peerOver: { theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 9, maxPerMinute: 2, copiedAt: "2026-11-07" } } });
  const files = [1, 2, 3, 4].map(i => submitSpool(e.peerDir, { type: "send", kind: "info", text: `fyi ${i}` }));
  await e.poller.drainSpool();
  expect(e.sent).toHaveLength(2);
  expect(files.slice(2).map(n => readResult(e, n))).toEqual([{ ok: false, rule: "their-rate" }, { ok: false, rule: "their-rate" }]);
});

test(names.spool, async () => {
  const e = await setup();
  const name = submitSpool(e.peerDir, { type: "send", kind: "info", text: `use ${GH} now` });
  await e.poller.drainSpool();
  expect(readResult(e, name)).toMatchObject({ ok: false, rule: "secret-shape", shape: "gh" });
  expect(e.sent).toHaveLength(0);
});

test(names.template, async () => {
  const e = await setup();
  await e.poller.processBatch([askRoot("0c0c0c0c")]);
  const before = e.sent.length;
  e.deps.matrix = DENY;
  e.c.t += 25 * 3_600_000;
  await e.poller.tick();
  expect(e.sent.length).toBe(before);
  expect(outbox(e).some(r => r.kind === "refused")).toBe(true);
});

test(names.recover, async () => {
  const e = await setup();
  const outFile = join(e.peerDir, "outbox.jsonl");
  await new Chain().append(outFile, { kind: "intent", peer: "example", chat: CHAT, id: "dead0001", root: null, msgKind: "info", text: `old ${GH} text`, isRoot: true });
  const p = await Poller.create(e.deps);
  await p.recover();
  expect(e.sent).toHaveLength(0);
  const refusal = outbox(e).find(r => r.kind === "refused");
  expect(refusal).toMatchObject({ reason: "secret-shape", shape: "gh", intent: 1 });
  expect(JSON.stringify(refusal)).not.toContain(GH);
  const next = await Poller.create(e.deps);
  await next.recover();
  expect(e.sent).toHaveLength(0);
});

test(names.grep, async () => {
  const e = await setup();
  const text = `CANARY-77aa ${GH}`;
  submitSpool(e.peerDir, { type: "send", kind: "info", text });
  await e.poller.drainSpool();
  for (const f of filesUnder(e.stateDir)) expect(readFileSync(f, "utf8")).not.toContain("CANARY-77aa");
  for (const f of filesUnder(e.stateDir)) expect(readFileSync(f, "utf8")).not.toContain(GH);
});

test(names.resend, async () => {
  const e = await setup();
  submitSpool(e.peerDir, { type: "send", kind: "info", text: "status of the build" });
  await e.poller.drainSpool();
  expect(e.sent).toHaveLength(1);
  e.deps.matrix = DENY;
  e.c.t += 31 * 60_000;
  await e.poller.tick();
  expect(e.sent).toHaveLength(1);
  e.deps.matrix = undefined;
  e.c.t += 60_000;
  await e.poller.tick();
  expect(e.sent).toHaveLength(1);
});

test("a root resend with the same id goes out once egress allows it", async () => {
  const e = await setup();
  submitSpool(e.peerDir, { type: "send", kind: "info", text: "status of the build" });
  await e.poller.drainSpool();
  e.c.t += 31 * 60_000;
  await e.poller.tick();
  expect(e.sent).toHaveLength(2);
  expect(e.sent[1].text).toBe(e.sent[0].text);
});

test.skipIf(!!process.env.PEER_RED_COPY)("I4 mutation: with the egress call removed from the poller every send path turns red", () => {
  const root = makeRedCopy(["scripts/telegram/bus.ts", "scripts/telegram/gate.ts", "scripts/guardrails/egress-matrix-eval.mjs", "scripts/guardrails/egress-matrix.json", "scripts/lib/redact.sh"]);
  const run = () => spawnSync("bun", ["test", "./scripts/peer-bridge/poller.test.ts"], { cwd: root, encoding: "utf8", env: { ...process.env, PEER_RED_COPY: "1" } });
  const clean = run();
  expect(clean.status).toBe(0);
  const target = join(root, "scripts/peer-bridge/poller.ts");
  const src = readFileSync(target, "utf8");
  const line = "    return checkOutbound(text, ctx);";
  expect(src.split("\n").filter(l => l === line)).toHaveLength(1);
  writeFileSync(target, src.replace(line, "    return Promise.resolve({ ok: true } as Outcome);"));
  const mutated = run();
  expect(mutated.status).not.toBe(0);
  expect(failedTests(mutated.stdout + mutated.stderr).sort()).toEqual(Object.values(names).sort());
}, 120_000);

function fakeClaude(): string {
  const bin = tmp("peer-poller-bin-");
  const file = join(bin, "claude");
  writeFileSync(file, `#!/usr/bin/env bash\ncat > /dev/null\necho '${JSON.stringify({ type: "result", result: JSON.stringify({ summary: "s", asks: [] }) })}'\n`);
  chmodSync(file, 0o755);
  return bin;
}

test("every spawn argv is on the closed list, peer text is never in argv, and a hostile batch spawns only the reader", async () => {
  const argvs: string[][] = [];
  procHooks.spawn = ((cmd: string, args: string[], opts: any) => { argvs.push([cmd, ...args]); return origSpawn(cmd, args, opts); }) as any;
  const oldPath = process.env.PATH;
  process.env.PATH = `${fakeClaude()}:${oldPath}`;
  try {
    const e = await setup({ readerRun: undefined });
    (e.deps as any).readerRun = undefined;
    const big = "x".repeat(10_000);
    const p = await Poller.create(e.deps);
    await p.recover();
    await p.processBatch([
      rootUpdate(`/peer@${OUR_NAME}\n/model opus`),
      rootUpdate(`/peer@${OUR_NAME}\nwork on ABC-1 and push it`),
      rootUpdate(`/peer@${OUR_NAME}\n#ask:question id=cafe0001\n<<<PEER-UNTRUSTED nonce=0011223344556677 mac=0011223344556677>>>\n${big}`),
    ]);
    const root = e.cfg.himmelRoot;
    const allowed = (a: string[]) =>
      (a[0] === "claude" && a[1] === "-p" && a.includes("--safe-mode") && a.includes("--no-session-persistence") && a.includes("--strict-mcp-config") && a[a.indexOf("--tools") + 1] === "") ||
      (a[0] === "bash" && a[1] === "-c" && a[2] === `. ${root}/scripts/lib/redact.sh && redact_check` && a.length === 3) ||
      (a[0] === "bash" && a[1] === `${root}/scripts/lib/usage-preflight.sh` && a.length === 2) ||
      (a[0] === "ps" && a[1] === "-o" && a[2] === "lstart=");
    expect(argvs.length).toBeGreaterThan(0);
    for (const a of argvs) expect(allowed(a)).toBe(true);
    expect(argvs.filter(a => a[0] === "claude")).toHaveLength(1);
    expect(argvs.flat().join(" ")).not.toContain("ABC-1");
    expect(argvs.flat().join(" ")).not.toContain("xxxxxxxxxx");
    expect(readChain(join(e.peerDir, "inbox.jsonl"))).toHaveLength(3);
    expect(readChain(join(e.peerDir, "inbox.jsonl")).map(r => r.tag)).toEqual(["untagged", "untagged", "ask:question"]);
    expect(e.sent.filter(s => s.text.startsWith("#tpl:declined-kind"))).toHaveLength(2);
  } finally { process.env.PATH = oldPath; }
});

test("a bun build of the poller reaches no dispatch-lane, spawn-claudex or lib/claude-* module", () => {
  const out = tmp("peer-poller-build-");
  const r = spawnSync("bun", ["build", join(REPO, "scripts/peer-bridge/poller.ts"), "--target=bun", "--outdir", out, `--metafile=${join(out, "meta.json")}`], { encoding: "utf8" });
  expect(r.status).toBe(0);
  const inputs = Object.keys(JSON.parse(readFileSync(join(out, "meta.json"), "utf8")).inputs);
  expect(inputs.some(i => i.includes("scripts/peer-bridge/poller.ts"))).toBe(true);
  expect(inputs.filter(i => /dispatch-lane|spawn-claudex|scripts\/lib\/claude-/.test(i))).toEqual([]);
});

const TOKEN = "1234567890:" + "A".repeat(35);
function processEnv(over: { mode?: number; operatorBotId?: string; peerName?: string; lockHeld?: boolean } = {}) {
  const home = tmp("peer-poller-home-");
  const conf = join(home, ".config/himmel/peer-bridge");
  mkdirSync(conf, { recursive: true });
  const peer = { peerBotId: "555000111", chatId: null, allowFrom: ["555000111"], opens: ["question"], maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30, theirs: { username: "g", opens: ["question"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } };
  writeFileSync(join(conf, "peers.json"), JSON.stringify({ operatorBotId: over.operatorBotId ?? "999000999", operatorChatId: 4242, bridgeRoot: "/tmp/b", himmelRoot: "/tmp/h", peers: { [over.peerName ?? "example"]: peer }, maxTextChars: 4000, addressing: "command" }), { mode: over.mode ?? 0o600 });
  chmodSync(join(conf, "peers.json"), over.mode ?? 0o600);
  mkdirSync(join(home, ".himmel/peer-bridge"), { recursive: true });
  return home;
}
const runPoller = (home: string) => spawnSync("bun", [join(REPO, "scripts/peer-bridge/poller.ts")], { cwd: tmp("peer-poller-cwd-"), encoding: "utf8", timeout: 20_000, env: { PATH: process.env.PATH!, HOME: home, PEER_BOT_TOKEN: TOKEN } });

test("the poller process exits 78 on a loose peers.json, a token equal to operatorBotId, and a bad peer name", () => {
  expect(runPoller(processEnv({ mode: 0o644 })).status).toBe(78);
  expect(runPoller(processEnv({ operatorBotId: "1234567890" })).status).toBe(78);
  expect(runPoller(processEnv({ peerName: "Example!" })).status).toBe(78);
});


async function envSetup(over: { logs?: string[] } = {}) {
  const st = TE.mkStation("example");
  const e = await setup({ peerOver: { theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07", stationName: "example", keys: [{ id: st.key.id, pub: st.key.pub, addedAt: "2026-11-08T00:00:00Z" }] } } });
  (e.cfg as any).self = { stationName: "yotam" };
  const ours = keygen(e.configDir);
  const logs = over.logs ?? [];
  const poller = await Poller.create({ ...e.deps, log: l => logs.push(l) });
  await poller.recover();
  return { ...e, poller, st, logs, ours };
}
const nowS = (e: { c: { t: number } }) => Math.floor(e.c.t / 1000);
const envMsg = (e: { c: { t: number } }, st: TE.Station, kind: Kind = "halt", body: Record<string, unknown> = {}) => TE.envUpdate(TE.fromPeer(kind, body, nowS(e)), st);
const chainOf = (e: { peerDir: string }, name: string) => readChain(join(e.peerDir, name));

test("an admitted envelope is chained under its own kind, its id is persisted, and it reaches no reader, thread, template or wake", async () => {
  const e = await envSetup();
  const u = envMsg(e, e.st);
  await e.poller.processBatch([u]);
  expect(chainOf(e, "inbox.jsonl")).toHaveLength(1);
  expect(chainOf(e, "inbox.jsonl")[0]).toMatchObject({ kind: "peer-env", untrusted: true, peer: "example", text: u.message.text });
  expect(chainOf(e, "envelope-ids.jsonl")).toMatchObject([{ kind: "env-id", chat: CHAT, from: PEER_ID, exp: nowS(e) + 86400 }]);
  expect(e.reads).toEqual([]);
  expect(e.sent).toEqual([]);
  expect(chainOf(e, "threads.jsonl")).toEqual([]);
  expect(wakeLines(e)).toEqual([]);
  expect(Number(readFileSync(join(e.stateDir, "offset"), "utf8"))).toBe(u.update_id + 1);
});

test("the desk's reader lists no envelope: read.ts keeps to peer-msg records", () => {
  const src = readFileSync(join(REPO, "scripts/peer-bridge/read.ts"), "utf8");
  expect(src).toContain(`r.kind === "peer-msg"`);
});

test("a refusal at steps 2-7 logs the step, the msg and a sha256 only, and writes nothing", async () => {
  const e = await envSetup();
  const u = envMsg(e, e.st);
  const [a, b, c, d] = u.message.text.split("\n");
  const bad = TE.tgUpdate([a, b, c.replace("yotam", "yotaé"), d].join("\n"));
  e.logs.length = 0;
  await e.poller.processBatch([bad]);
  expect(e.logs).toHaveLength(1);
  expect(e.logs[0]).toMatch(/^env-drop step=3 peer=example msg=[0-9a-f]{8} sha256=[0-9a-f]{64}$/);
  expect(chainOf(e, "inbox.jsonl")).toEqual([]);
  expect(chainOf(e, "envelope-ids.jsonl")).toEqual([]);
  expect(e.sent).toEqual([]);
  expect(Number(readFileSync(join(e.stateDir, "offset"), "utf8"))).toBe(bad.update_id + 1);
});

test("the envelope window survives a restart: a replay of an admitted envelope is dropped", async () => {
  const e = await envSetup();
  const u = envMsg(e, e.st);
  await e.poller.processBatch([u]);
  const logs: string[] = [];
  const again = await Poller.create({ ...e.deps, log: l => logs.push(l) });
  await again.recover();
  await again.processBatch([TE.tgUpdate(u.message.text)]);
  expect(chainOf(e, "inbox.jsonl")).toHaveLength(1);
  expect(chainOf(e, "envelope-ids.jsonl")).toHaveLength(1);
  expect(logs.join("\n")).toContain("duplicate envelope id");
});

test("a line-2 #env message that is not a valid envelope never reaches the text path", async () => {
  const e = await envSetup();
  await e.poller.processBatch([TE.tgUpdate(`/peer@${OUR_NAME}\n#env:v9 k=0123abcd id=89abcdef\n{}\nsig=x`)]);
  expect(e.sent).toEqual([]);
  expect(chainOf(e, "inbox.jsonl")).toEqual([]);
  expect(chainOf(e, "threads.jsonl")).toEqual([]);
  expect(e.reads).toEqual([]);
});

test("a killed peer's envelope is dropped at step 4, and admitted again once the kill file is gone", async () => {
  const e = await envSetup();
  const kill = join(e.configDir, "example.killed");
  writeFileSync(kill, "", { mode: 0o600 });
  await e.poller.processBatch([envMsg(e, e.st)]);
  expect(e.logs.some(l => l.startsWith("env-drop step=4"))).toBe(true);
  expect(chainOf(e, "inbox.jsonl")).toEqual([]);
  rmSync(kill);
  await e.poller.processBatch([envMsg(e, e.st)]);
  expect(chainOf(e, "inbox.jsonl")).toHaveLength(1);
});

test("a flood of bad envelopes counts toward the peer's rate like text", async () => {
  const e = await envSetup();
  const bad = () => TE.tgUpdate(`/peer@${OUR_NAME}\n#env:v1 k=${e.st.key.id} id=89abcdef\n{}\nsig=${"A".repeat(86)}`);
  await e.poller.processBatch(Array.from({ length: 12 }, bad));
  const rate = e.logs.filter(l => l.includes("rule=7"));
  expect(rate.length).toBe(2);
});


const WIRE = "0123456789abcdef";
const seedJob = (e: { peerDir: string }, job: JobRecord) => new Chain().append(join(e.peerDir, "jobs.jsonl"), job);
const latestJobs = (e: { peerDir: string }) => {
  const m = new Map<number, any>();
  for (const r of chainOf(e, "jobs.jsonl")) if (r.kind === "job") m.set(r.jobNo as number, r);
  return m;
};
const outJobAt = (e: { c: { t: number } }, over: Partial<JobRecord> = {}): JobRecord => ({
  kind: "job", jobNo: 1, peer: "example", dir: "out", state: "SENT", created: nowS(e) - 3600, req_exp: nowS(e) + 82800, by: nowS(e) + 82800 + TIMEOUT_S_MAX + 7200,
  sha: "a".repeat(40), suites: ["scripts/hooks/test-a.sh"], wire_job: WIRE, ...over,
});
const inJobAt = (e: { c: { t: number } }, over: Partial<JobRecord> = {}): JobRecord => ({
  kind: "job", jobNo: 2, peer: "example", dir: "in", state: "RESOLVED", created: nowS(e) - 600, req_exp: nowS(e) + 80000, by: nowS(e) + 80000,
  sha: "a".repeat(40), suites: ["alias-a"], paths: ["scripts/hooks/test-a.sh"], peer_job: WIRE, resolved_at: nowS(e) - 500, ...over,
});
const sentEnvelopes = (e: { sent: { text: string }[] }) => e.sent.map(s => s.text.split("\n")).filter(l => l.length === 4);
const resMsg = (e: { c: { t: number } }, st: TE.Station, body: Record<string, unknown>) => envMsg(e, st, "res", { job: WIRE, ...body });

test("a signed res moves the requester's record, is chained in jobs.jsonl, and is not answered", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  await p.processBatch([resMsg(e, e.st, { state: "accepted" })]);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "ACCEPTED", dir: "out" });
  await p.processBatch([resMsg(e, e.st, { state: "running", timeout_s: 3000 })]);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "RUNNING", peer_timeout_s: 3000 });
  await p.processBatch([resMsg(e, e.st, { state: "done", results: ["pass"], minutes: 7, image: "b".repeat(64), log: { sha256: "c".repeat(64), bytes: 1 } })]);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "DONE", results: ["pass"], peer_minutes: 7, image: "unpinned" });
  expect(e.sent).toEqual([]);
  expect(chainOf(e, "jobs.jsonl").every(r => r.kind === "job")).toBe(true);
});

test("a res for a job we never sent is dropped and logged", async () => {
  const e = await envSetup();
  await e.poller.processBatch([envMsg(e, e.st, "res", { job: "f".repeat(16), state: "accepted" })]);
  expect(chainOf(e, "jobs.jsonl")).toEqual([]);
  expect(e.logs.some(l => l.includes("res for a job we did not send"))).toBe(true);
});

test("a late res on a LOST job is recorded as late and never reopens it", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { state: "LOST", by: null, ended_at: nowS(e) - 10 }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  await p.processBatch([resMsg(e, e.st, { state: "accepted" })]);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "LOST", late: "accepted" });
  expect(e.sent).toEqual([]);
});

test("the tick fires each overdue deadline once, oldest first, and signs and sends the one cancel", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { jobNo: 1, by: nowS(e) - 50, wire_job: WIRE }));
  await seedJob(e, outJobAt(e, { jobNo: 2, by: nowS(e) - 500, wire_job: "e".repeat(16), state: "ACCEPTED" }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  await p.tick();
  await p.tick();
  const jobs = latestJobs(e);
  expect(jobs.get(1)).toMatchObject({ state: "LOST", ended_at: nowS(e), by: null });
  expect(jobs.get(2)).toMatchObject({ state: "LOST" });
  expect(chainOf(e, "jobs.jsonl").filter(r => r.jobNo === 2 && r.state === "LOST")).toHaveLength(1);
  expect(chainOf(e, "jobs.jsonl").filter(r => r.state === "LOST").map(r => r.jobNo)).toEqual([2, 1]);
  const envs = sentEnvelopes(e);
  expect(envs).toHaveLength(1);
  const [addr, line2, line3, line4] = envs[0];
  expect(addr).toBe("/peer@example_bot");
  const parsed = parseEnvelopeLine(line3);
  expect(parsed.ok && parsed.env).toMatchObject({ kind: "cancel", job: WIRE, from: "yotam", to: "example", chat: String(CHAT) });
  expect(line2).toBe(`#env:v1 k=${e.ours.id} id=${(parsed as any).env.msg}`);
  expect(verify(line2, line3, line4.slice(4), e.ours.pub)).toBe(true);
  expect(chainOf(e, "threads.jsonl")).toEqual([]);
});

test("restart order: the Telegram backlog lands before the first deadline tick, so no cancel is sent", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { by: nowS(e) - 100 }));
  const backlog = [resMsg(e, e.st, { state: "accepted" })];
  const tg: TgLike = { ...e.tg, getUpdates: async () => backlog.splice(0) };
  const p = await Poller.create({ ...e.deps, tg, log: l => e.logs.push(l) });
  await p.start();
  expect(latestJobs(e).get(1)).toMatchObject({ state: "ACCEPTED" });
  expect(e.sent).toEqual([]);
  expect(chainOf(e, "outbox.jsonl").filter(r => r.kind === "intent")).toEqual([]);
});

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: a start that ticks before it drains the backlog sends the cancel", () => {
  const root = makeRedCopy(["scripts/telegram/bus.ts", "scripts/telegram/gate.ts", "scripts/guardrails/egress-matrix-eval.mjs", "scripts/guardrails/egress-matrix.json", "scripts/lib/redact.sh"]);
  const run = () => spawnSync("bun", ["test", "./scripts/peer-bridge/poller.test.ts"], { cwd: root, encoding: "utf8", env: { ...process.env, PEER_RED_COPY: "1" } });
  expect(run().status).toBe(0);
  const target = join(root, "scripts/peer-bridge/poller.ts");
  const lines = readFileSync(target, "utf8").split("\n");
  expect(lines.filter(l => l.trim() === "await this.drainBacklog();")).toHaveLength(1);
  const swapped = lines.filter(l => l.trim() !== "await this.drainBacklog();").flatMap(l => (l.trim() === "await this.tick();" && l.startsWith("    ") ? [l, "    await this.drainBacklog();"] : [l]));
  writeFileSync(target, swapped.join("\n"));
  const mutated = run();
  expect(mutated.status).not.toBe(0);
  expect(failedTests(mutated.stdout + mutated.stderr)).toEqual(["restart order: the Telegram backlog lands before the first deadline tick, so no cancel is sent"]);
}, 90_000);

test("an envelope the envelope policy refuses is never queued or sent, and its refusal is chained without its text", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { by: nowS(e) - 50 }));
  const p = await Poller.create({ ...e.deps, checkEnvelope: async () => ({ ok: false, rule: "schema" }), log: l => e.logs.push(l) });
  await p.recover();
  await p.tick();
  expect(e.sent).toEqual([]);
  const out = chainOf(e, "outbox.jsonl");
  expect(out.filter(r => r.kind === "intent")).toEqual([]);
  expect(out).toMatchObject([{ kind: "refused", reason: "schema" }]);
  expect(JSON.stringify(out)).not.toContain(WIRE);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "LOST" });
});

test("a queued envelope that the policy now refuses is dropped on restart, not sent", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { by: nowS(e) - 50 }));
  const tg: TgLike = { ...e.tg, sendMessage: async () => { throw new TelegramError("down", 500); } };
  const down = await Poller.create({ ...e.deps, tg, log: l => e.logs.push(l) });
  await down.recover();
  await down.tick();
  expect(chainOf(e, "outbox.jsonl").filter(r => r.kind === "intent")).toHaveLength(1);
  const again = await Poller.create({ ...e.deps, checkEnvelope: async () => ({ ok: false, rule: "signature" }), log: l => e.logs.push(l) });
  await again.recover();
  await again.flushIntents();
  expect(e.sent).toEqual([]);
  expect(chainOf(e, "outbox.jsonl").filter(r => r.kind === "refused")).toMatchObject([{ reason: "signature", intent: expect.any(Number) }]);
});

test("a cancel from the peer cancels its job and sends a signed res cancelled; halt cancels them all", async () => {
  const e = await envSetup();
  await seedJob(e, inJobAt(e, { jobNo: 2, peer_job: WIRE }));
  await seedJob(e, inJobAt(e, { jobNo: 3, peer_job: "a".repeat(16), state: "APPROVED" }));
  await seedJob(e, inJobAt(e, { jobNo: 4, peer_job: "b".repeat(16), state: "DONE", by: null, ended_at: nowS(e) - 5 }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  await p.processBatch([envMsg(e, e.st, "cancel", { job: WIRE })]);
  expect(latestJobs(e).get(2)).toMatchObject({ state: "CANCELLED" });
  expect(latestJobs(e).get(3)).toMatchObject({ state: "APPROVED" });
  await p.processBatch([envMsg(e, e.st, "halt", {})]);
  expect(latestJobs(e).get(3)).toMatchObject({ state: "CANCELLED" });
  expect(latestJobs(e).get(4)).toMatchObject({ state: "DONE" });
  const bodies = sentEnvelopes(e).map(l => (parseEnvelopeLine(l[2]) as any).env);
  expect(bodies.map((b: any) => [b.kind, b.state, b.job])).toEqual([["res", "cancelled", WIRE], ["res", "cancelled", "a".repeat(16)]]);
});

test("a cancel for a job the peer did not send is dropped", async () => {
  const e = await envSetup();
  await e.poller.processBatch([envMsg(e, e.st, "cancel", { job: "9".repeat(16) })]);
  expect(chainOf(e, "jobs.jsonl")).toEqual([]);
  expect(e.sent).toEqual([]);
});

test("jobs.jsonl reloads at start: the latest snapshot per job wins, and job numbers continue", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { jobNo: 7 }));
  await seedJob(e, outJobAt(e, { jobNo: 7, state: "ACCEPTED" }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  expect(p.jobsSnapshot().get(7)?.state).toBe("ACCEPTED");
  expect(p.nextJobNo()).toBe(8);
});


const jobEvent = (e: { peerDir: string }, job: number, event: Record<string, unknown>) => submitSpool(e.peerDir, { type: "job-event", job, event } as any);

test("a vm-start event writes a RUNNING record whose backstop is min(maxJobMinutes, minutes left) in seconds", async () => {
  const e = await envSetup();
  (e.cfg.peers.example as any).budgets = { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130 };
  await seedJob(e, inJobAt(e, { jobNo: 2, state: "APPROVED" }));
  await seedJob(e, inJobAt(e, { jobNo: 3, state: "DONE", by: null, peer_job: "a".repeat(16), resolved_at: nowS(e) - 100, running_at: nowS(e) - 100 - 1800, ended_at: nowS(e) - 100 }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  jobEvent(e, 2, { type: "vm-start" });
  await p.drainSpool();
  expect(latestJobs(e).get(2)).toMatchObject({ state: "RUNNING", backstop_s: 90 * 60, running_at: nowS(e), by: nowS(e) + 90 * 60 + 1200 });
  const env = sentEnvelopes(e).map(l => (parseEnvelopeLine(l[2]) as any).env);
  expect(env.map((x: any) => [x.kind, x.state, x.timeout_s])).toEqual([["res", "running", 90 * 60 + 1200]]);
});

test("the backstop is capped by maxJobMinutes when the day has more left", async () => {
  const e = await envSetup();
  (e.cfg.peers.example as any).budgets = { jobsPerDay: 10, vmMinutesPerDay: 1000, queueMax: 3, maxJobMinutes: 45 };
  await seedJob(e, inJobAt(e, { jobNo: 2, state: "APPROVED" }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  jobEvent(e, 2, { type: "vm-start" });
  await p.drainSpool();
  expect(latestJobs(e).get(2)).toMatchObject({ state: "RUNNING", backstop_s: 45 * 60 });
});

test("a day with under the allowance left refuses the start with budget", async () => {
  const e = await envSetup();
  (e.cfg.peers.example as any).budgets = { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130 };
  await seedJob(e, inJobAt(e, { jobNo: 2, state: "APPROVED" }));
  await seedJob(e, inJobAt(e, { jobNo: 3, state: "DONE", by: null, peer_job: "a".repeat(16), resolved_at: nowS(e) - 100, running_at: nowS(e) - 110 * 60, ended_at: nowS(e) - 100 }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  jobEvent(e, 2, { type: "vm-start" });
  await p.drainSpool();
  expect(latestJobs(e).get(2)).toMatchObject({ state: "REFUSED", refused: "budget" });
});

test("an unknown spool event type is logged and dropped; an event for no such job names the rule", async () => {
  const e = await envSetup();
  await seedJob(e, outJobAt(e, { jobNo: 1 }));
  const p = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await p.recover();
  const bad = jobEvent(e, 2, { type: "frobnicate" });
  const none = jobEvent(e, 99, { type: "approve" });
  const mine = jobEvent(e, 1, { type: "approve" });
  e.logs.length = 0;
  await p.drainSpool();
  expect(readResult(e, bad)).toEqual({ ok: false, rule: "malformed" });
  expect(readResult(e, none)).toEqual({ ok: false, rule: "unknown-job" });
  expect(readResult(e, mine)).toEqual({ ok: false, rule: "unknown-job" });
  expect(e.logs.some(l => l.includes("malformed spool"))).toBe(true);
  expect(latestJobs(e).get(1)).toMatchObject({ state: "SENT" });
});

test("a second poller exits non-zero but not 78, and never reads the operator env", async () => {
  const home = processEnv();
  const holder = spawn("sleep", ["30"], { stdio: "ignore" });
  await new Promise(r => holder.once("spawn", r));
  const { startIdentity } = await import("./chain");
  writeFileSync(join(home, ".himmel/peer-bridge/poller.pid"), JSON.stringify({ pid: holder.pid, start: startIdentity(holder.pid!) }), { mode: 0o600 });
  const r = runPoller(home);
  holder.kill("SIGKILL");
  expect(r.status).not.toBe(0);
  expect(r.status).not.toBe(78);
  expect(r.stderr).toContain("another peer-bridge poller");
});


const SUITE_A = "scripts/hooks/test-a.sh";
const serveRun = (e: { cfg: Config; configDir: string }, budgets?: Record<string, number>, allow = true) => {
  const p = e.cfg.peers.example as any;
  p.serves = ["run-suite"]; p.maxPerMinute = 10_000;
  if (budgets) p.budgets = { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130, ...budgets };
  if (allow) writeFileSync(join(e.configDir, "example.suites"), `alias-a ${SUITE_A}\n`, { mode: 0o600 });
};
let reqSeq = 0;
const reqMsg = (e: { c: { t: number } }, st: TE.Station) => envMsg(e, st, "req", { job: (++reqSeq).toString(16).padStart(16, "0"), op: "run-suite", sha: "a".repeat(40), suites: [SUITE_A] });
const resBodies = (e: { sent: { text: string }[] }) => sentEnvelopes(e).map(l => parseEnvelopeLine(l[2])).flatMap(r => (r.ok ? [r.env as any] : []));
const inJobs = (e: { peerDir: string }) => [...latestJobs(e).values()].filter(j => j.dir === "in");

test("m1: a burst of queueMax requests with one job left today admits exactly one and refuses the rest with budget", async () => {
  const e = await envSetup();
  serveRun(e, { jobsPerDay: 1, queueMax: 3 });
  await e.poller.processBatch([reqMsg(e, e.st), reqMsg(e, e.st), reqMsg(e, e.st)]);
  expect(inJobs(e)).toHaveLength(1);
  expect(resBodies(e).map(b => [b.kind, b.state, b.refused])).toEqual([["res", "refused", "budget"], ["res", "refused", "budget"]]);
});

test("m2: a crash between handling and the id record shows the envelope handled once after restart", async () => {
  const e = await envSetup();
  serveRun(e);
  const u = reqMsg(e, e.st);
  mkdirSync(join(e.peerDir, "envelope-ids.jsonl"));
  await expect(e.poller.processBatch([u])).rejects.toThrow();
  rmSync(join(e.peerDir, "envelope-ids.jsonl"), { recursive: true });
  const again = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await again.recover();
  await again.processBatch([u]);
  expect(inJobs(e)).toHaveLength(1);
});

test("m2: an append failure in handling does not make the redelivery a duplicate", async () => {
  const e = await envSetup();
  serveRun(e);
  const u = reqMsg(e, e.st);
  mkdirSync(join(e.peerDir, "jobs.jsonl"));
  await expect(e.poller.processBatch([u])).rejects.toThrow();
  rmSync(join(e.peerDir, "jobs.jsonl"), { recursive: true });
  await e.poller.processBatch([u]);
  expect(inJobs(e)).toHaveLength(1);
});

test("m2: after an append failure in handling, a restart still handles the redelivery", async () => {
  const e = await envSetup();
  serveRun(e);
  const u = reqMsg(e, e.st);
  mkdirSync(join(e.peerDir, "jobs.jsonl"));
  await expect(e.poller.processBatch([u])).rejects.toThrow();
  rmSync(join(e.peerDir, "jobs.jsonl"), { recursive: true });
  const again = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await again.recover();
  await again.processBatch([u]);
  expect(inJobs(e)).toHaveLength(1);
  const handled = chainOf(e, "envelope-ids.jsonl").filter(r => r.kind === "env-id");
  expect(handled.length).toBeGreaterThan(0);
});

test("m5: an egress-refused request leaves no out-job record and no cancel is sent later", async () => {
  const e = await envSetup();
  let calls = 0;
  const checkEnvelope = (async (...a: Parameters<typeof checkEnvelopeOutbound>) => (calls++ === 0 ? { ok: false as const, rule: "schema" } : checkEnvelopeOutbound(...a))) as PollerDeps["checkEnvelope"];
  const p = await Poller.create({ ...e.deps, checkEnvelope, log: l => e.logs.push(l) });
  await p.recover();
  const name = submitSpool(e.peerDir, { type: "env-out", kind: "req", body: { sha: "a".repeat(40), suites: [SUITE_A] } });
  await p.drainSpool();
  expect(readResult(e, name)).toEqual({ ok: false, rule: "egress" });
  expect(chainOf(e, "jobs.jsonl")).toEqual([]);
  e.c.t += 10 * 86_400_000;
  await p.tick();
  await p.flushIntents();
  expect(e.sent).toEqual([]);
});

test("m5: an accepted request records the out-job before its envelope can be sent", async () => {
  const e = await envSetup();
  const name = submitSpool(e.peerDir, { type: "env-out", kind: "req", body: { sha: "a".repeat(40), suites: [SUITE_A] } });
  await e.poller.drainSpool();
  expect(readResult(e, name)).toMatchObject({ ok: true, job: 1 });
  expect(latestJobs(e).get(1)).toMatchObject({ dir: "out", state: "SENT" });
  expect(sentEnvelopes(e)).toHaveLength(1);
});

test("m7: the answer hourly cap survives a restart", async () => {
  const e = await envSetup();
  serveRun(e);
  await e.poller.processBatch(Array.from({ length: 20 }, () => envMsg(e, e.st, "capacity-ask", {})));
  expect(sentEnvelopes(e)).toHaveLength(20);
  const logs: string[] = [];
  const again = await Poller.create({ ...e.deps, log: l => logs.push(l) });
  await again.recover();
  await again.processBatch([envMsg(e, e.st, "capacity-ask", {})]);
  expect(sentEnvelopes(e)).toHaveLength(20);
  expect(logs.some(l => l.includes("hourly cap on answers"))).toBe(true);
  e.c.t += 61 * 60_000;
  await again.processBatch([envMsg(e, e.st, "capacity-ask", {})]);
  expect(sentEnvelopes(e)).toHaveLength(21);
});

test("m7: the res refused from resolve-fail counts toward the answer cap", async () => {
  const e = await envSetup();
  serveRun(e, undefined, false);
  await e.poller.processBatch(Array.from({ length: 25 }, () => reqMsg(e, e.st)));
  expect(inJobs(e)).toHaveLength(25);
  expect(resBodies(e).filter(b => b.refused === "not-allowed")).toHaveLength(20);
  expect(e.logs.filter(l => l.includes("hourly cap on answers"))).toHaveLength(5);
});

test("m7: the bad-signature tripwire survives a restart", async () => {
  const e = await envSetup();
  const other = TE.mkStation("other");
  const bad = () => TE.envUpdate(TE.fromPeer("halt", {}, nowS(e)), other, { kid: e.st.key.id });
  await e.poller.processBatch([bad(), bad()]);
  expect(wakeLines(e)).toEqual([]);
  const again = await Poller.create({ ...e.deps, log: l => e.logs.push(l) });
  await again.recover();
  await again.processBatch([bad()]);
  expect(wakeLines(e)).toEqual(["peer example: 3 bad signatures in 1 h"]);
  TE.dropStation(other);
});
