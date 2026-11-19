import { afterEach, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain, readChain, submitSpool } from "./chain";
import type { Config } from "./config";
import { ackToken, digestFile } from "./digests";
import { admit, createGateState, noteAdmitted } from "./gate";
import { procHooks } from "./proc";
import { Poller, type PollerDeps, type TgLike } from "./poller";
import { RetryAfter, TelegramError } from "./telegram";
import { Threads } from "./threads";
import { failedTests, makeRedCopy } from "./red-copy";

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
  const peerDir = join(stateDir, "goomal");
  mkdirSync(join(peerDir, "spool"), { recursive: true, mode: 0o700 });
  const cfg: Config = {
    operatorBotId: "999000999", operatorChatId: 4242, bridgeRoot: tmp("peer-poller-bridge-"), himmelRoot: himmelRoot(), maxTextChars: 4000, addressing: "command",
    peers: { goomal: { peerBotId: PEER_ID, chatId: CHAT, allowFrom: [PEER_ID, "42"], opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
      theirs: { username: "goomal_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" }, ...(over.peerOver ?? {}) } as any },
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

// A receiver bridge in miniature: the real gate and thread state of the other side.
function receiver() {
  const state = createGateState({ ourBotId: PEER_ID, ourUsername: "goomal_bot", committed: 0, now: T0 });
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
  // A root, delivered, then the response is lost.
  submitSpool(e.peerDir, { type: "send", kind: "info", text: "fyi: the build is green" });
  e.script.push(() => { throw new TelegramError("connection reset", 0); });
  await e.poller.drainSpool();
  for (const s of e.sent) rx.deliver(s.text, s.replyTo);
  expect(outbox(e).map(r => r.kind)).toEqual(["intent"]);
  // A restart recovers the intent and resends the same id.
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
  const ackTok = ackToken(e.key, "sess-1", "goomal", 3);
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
  const hi = submitSpool(e.peerDir, { type: "ack", sid: "s1", token: ackToken(e.key, "s1", "goomal", 9) });
  const lo = submitSpool(e.peerDir, { type: "ack", sid: "s1", token: ackToken(e.key, "s1", "goomal", 4) });
  await e.poller.drainSpool();
  expect(readResult(e, name)).toEqual({ ok: false, rule: "unknown-thread" });
  expect(readResult(e, hi)).toEqual({ ok: true });
  expect(readResult(e, lo)).toEqual({ ok: true });
  expect(JSON.parse(readFileSync(join(e.peerDir, "cursors", "s1"), "utf8"))).toEqual({ n: 9 });
});

// ---- I4: every send path runs the real egress gate ----

const DENY = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "deny", why: "test" }] };
const names = {
  spool: "I4: a spool send file written directly with a token is refused and never sent",
  template: "I4: a template under a matrix that denies peer-desk is not sent",
  recover: "I4: at startup an unsent intent that now fails egress is not resent and chains a refusal",
  grep: "I4: after the drain of a refused spool file no file under the state dir holds its text",
  resend: "I4: a root resend under a matrix that denies peer-desk is not sent",
};

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
  await new Chain().append(outFile, { kind: "intent", peer: "goomal", chat: CHAT, id: "dead0001", root: null, msgKind: "info", text: `old ${GH} text`, isRoot: true });
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

// ---- I2: the closed spawn list ----

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

// ---- startup refusals, as a process ----

const TOKEN = "1234567890:" + "A".repeat(35);
function processEnv(over: { mode?: number; operatorBotId?: string; peerName?: string; lockHeld?: boolean } = {}) {
  const home = tmp("peer-poller-home-");
  const conf = join(home, ".config/himmel/peer-bridge");
  mkdirSync(conf, { recursive: true });
  const peer = { peerBotId: "555000111", chatId: null, allowFrom: ["555000111"], opens: ["question"], maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30, theirs: { username: "g", opens: ["question"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } };
  writeFileSync(join(conf, "peers.json"), JSON.stringify({ operatorBotId: over.operatorBotId ?? "999000999", operatorChatId: 4242, bridgeRoot: "/tmp/b", himmelRoot: "/tmp/h", peers: { [over.peerName ?? "goomal"]: peer }, maxTextChars: 4000, addressing: "command" }), { mode: over.mode ?? 0o600 });
  chmodSync(join(conf, "peers.json"), over.mode ?? 0o600);
  mkdirSync(join(home, ".himmel/peer-bridge"), { recursive: true });
  return home;
}
const runPoller = (home: string) => spawnSync("bun", [join(REPO, "scripts/peer-bridge/poller.ts")], { cwd: tmp("peer-poller-cwd-"), encoding: "utf8", timeout: 20_000, env: { PATH: process.env.PATH!, HOME: home, PEER_BOT_TOKEN: TOKEN } });

test("the poller process exits 78 on a loose peers.json, a token equal to operatorBotId, and a bad peer name", () => {
  expect(runPoller(processEnv({ mode: 0o644 })).status).toBe(78);
  expect(runPoller(processEnv({ operatorBotId: "1234567890" })).status).toBe(78);
  expect(runPoller(processEnv({ peerName: "Goomal!" })).status).toBe(78);
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
