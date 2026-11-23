import { afterAll, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain } from "../peer-bridge/chain";
import { appendNotify, notifyFile, type NotifyRec } from "../peer-bridge/notify";
import { readNewLines } from "./bus";
import { holdingProc, LOCKED_LINE, macProcsFrom, makePeerNotifyFlusher, makePeerReplyRoute, pluginStateDir, PR1_REPLY_LINE, procFromEnv, readBotPids, readCursor, readProcs, readSent, sentDir, type ProcInfo } from "./peer-notify-route";
import { handleInbound, inboundToDelivered, ingestUpdates, type AutoGate } from "./poller";
import type { SendOpts, SendResult } from "./telegram-api";

const REPO = join(import.meta.dir, "..", "..");
const OP_BOT = "999000999", OTHER_BOT = "888000888", OP_CHAT = 4242;
const TOKEN = `${OP_BOT}:${"A".repeat(35)}`;
const MIN = 60_000;
const tmp = (p: string) => fs.mkdtempSync(join(tmpdir(), p));
const children: ChildProcess[] = [];
afterAll(() => { for (const c of children) try { process.kill(-c.pid!, "SIGKILL"); } catch {} });

const wake = (root: number, over: Partial<NotifyRec> = {}): NotifyRec => ({ kind: "notify", type: "wake", peer: "example", root, dir: "in", label: "new question", ts: 1, ...over } as NotifyRec);

function world(over: { procs?: ProcInfo[]; botPids?: number[]; peersChat?: number; peersBot?: string } = {}) {
  const S = tmp("peer-notify-S-");
  const c = { t: Date.UTC(2026, 10, 20, 12) };
  const sent: { text: string; opts: SendOpts }[] = [];
  const logs: string[] = [];
  let script: (SendResult | "throw")[] = [];
  let mid = 700;
  const send = async (_t: string, chat: number, text: string, opts: SendOpts): Promise<SendResult> => {
    expect(chat).toBe(OP_CHAT);
    sent.push({ text, opts });
    const next = script.shift();
    if (next === "throw") throw new Error("crash");
    return next ?? { ok: true, messageId: ++mid };
  };
  const procs = { list: over.procs ?? [] };
  const f = makePeerNotifyFlusher({
    stateDir: S, himmelRoot: "/opt/himmel", token: TOKEN,
    access: () => ({ allowFrom: [String(OP_CHAT)] }), peersCfg: () => ({ operatorChatId: over.peersChat ?? OP_CHAT, operatorBotId: over.peersBot ?? OP_BOT }),
    send, procs: () => procs.list, botPids: () => over.botPids ?? [], clock: () => c.t, log: l => logs.push(l),
  });
  const chain = new Chain();
  const add = (rec: NotifyRec) => appendNotify(chain, notifyFile(S), rec);
  const fresh = () => f.notePoll(true);
  return { S, c, f, sent, logs, add, fresh, procs, setScript: (s: (SendResult | "throw")[]) => { script = s; } };
}

const snapshot = (dir: string): string[] => {
  const out: string[] = [];
  const walk = (d: string) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = join(d, e.name); if (e.isDirectory()) walk(p); else out.push(`${p.slice(dir.length)}:${fs.readFileSync(p, "utf8")}`); } };
  walk(dir);
  return out.sort();
};

test("hold rules: stale poll", async () => {
  const w = world();
  await w.add(wake(1));
  await w.f.flush();
  expect(w.f.holdReason()).toBe("stale-poll");
  w.fresh();
  expect(w.f.holdReason()).toBeNull();
  w.c.t += MIN + 1;
  expect(w.f.holdReason()).toBe("stale-poll");
  w.fresh();
  await w.f.flush();
  expect(w.sent).toHaveLength(1);
});

test("hold rules: 409 window", () => {
  const w = world();
  w.fresh();
  w.f.notePoll(false, 409);
  expect(w.f.holdReason()).toBe("409");
  for (let i = 0; i < 4; i++) { w.c.t += 2 * MIN; w.f.notePoll(true); w.f.notePoll(false, 409); expect(w.f.holdReason()).toBe("409"); }
  w.c.t += 10 * MIN; w.f.notePoll(true);
  expect(w.f.holdReason()).toBeNull();
  w.f.notePoll(false, 502);
  expect(w.f.holdReason()).toBeNull();
});

test("hold rules: own poller for the operator bot", () => {
  const home = tmp("peer-notify-home-");
  const state = join(home, "custom-state");
  fs.mkdirSync(state, { recursive: true });
  fs.writeFileSync(join(state, ".env"), `TELEGRAM_BOT_TOKEN=${OP_BOT}:${"B".repeat(35)}\n`);
  const cfg = join(home, "cfgdir");
  fs.mkdirSync(join(cfg, "channels", "telegram"), { recursive: true });
  fs.writeFileSync(join(cfg, "channels", "telegram", ".env"), `TELEGRAM_BOT_TOKEN=${OP_BOT}:${"C".repeat(35)}\n`);
  const fromEnv = procFromEnv(10, ["TELEGRAM_OWN_POLLER=1", `TELEGRAM_BOT_TOKEN=${OP_BOT}:x`], home);
  const fromState = procFromEnv(11, ["TELEGRAM_OWN_POLLER=1", `TELEGRAM_STATE_DIR=${state}`], home);
  const fromCfg = procFromEnv(12, ["TELEGRAM_OWN_POLLER=1", `CLAUDE_CONFIG_DIR=${cfg}`], home);
  for (const p of [fromEnv, fromState, fromCfg]) {
    expect(p).toMatchObject({ ownPoller: true, botIds: [OP_BOT] });
    expect(holdingProc([p], [], OP_BOT)).toBe(true);
  }
});

test("hold rules: own poller with no bot id found holds", () => {
  const p = procFromEnv(10, ["TELEGRAM_OWN_POLLER=1"], tmp("peer-notify-home-"));
  expect(p.botIds).toEqual([]);
  expect(holdingProc([p], [], OP_BOT)).toBe(true);
});

test("hold rules: own poller whose ids disagree holds", () => {
  const home = tmp("peer-notify-home-");
  fs.mkdirSync(join(home, ".claude", "channels", "telegram"), { recursive: true });
  fs.writeFileSync(join(home, ".claude", "channels", "telegram", ".env"), `TELEGRAM_BOT_TOKEN=${OP_BOT}:x\n`);
  const a = procFromEnv(10, ["TELEGRAM_OWN_POLLER=1", `TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x`], home);
  expect(a.botIds.sort()).toEqual([OTHER_BOT, OP_BOT].sort());
  expect(holdingProc([a], [], OP_BOT)).toBe(true);
  const b = procFromEnv(11, ["TELEGRAM_OWN_POLLER=1", `TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x`, "TELEGRAM_BOT_TOKEN=777000777:y"], tmp("peer-notify-home-"));
  expect(holdingProc([b], [], OP_BOT)).toBe(true);
});

test("hold rules: send-only plugin process does not hold", () => {
  const home = tmp("peer-notify-home-");
  fs.mkdirSync(join(home, ".claude", "channels", "telegram"), { recursive: true });
  fs.writeFileSync(join(home, ".claude", "channels", "telegram", ".env"), `TELEGRAM_BOT_TOKEN=${OP_BOT}:x\n`);
  const p = procFromEnv(10, ["HIMMEL_MCP_TELEGRAM=1", `TELEGRAM_BOT_TOKEN=${OP_BOT}:x`], home);
  expect(p.ownPoller).toBe(false);
  expect(holdingProc([p], [10], OP_BOT)).toBe(false);
});

test("hold rules: own poller for another bot does not hold", () => {
  const p = procFromEnv(10, ["TELEGRAM_OWN_POLLER=1", `TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x`], tmp("peer-notify-home-"));
  expect(holdingProc([p], [], OP_BOT)).toBe(false);
});

test("hold rules: unknown env with a live bot.pid naming it holds; with a stale or absent bot.pid it does not", () => {
  const p = procFromEnv(process.pid, null);
  expect(p.ownPoller).toBe("unknown");
  const home = tmp("peer-notify-home-");
  expect(holdingProc([p], readBotPids(home), OP_BOT)).toBe(false);
  fs.mkdirSync(join(home, ".claude-alt", "channels", "telegram"), { recursive: true });
  fs.writeFileSync(join(home, ".claude-alt", "channels", "telegram", "bot.pid"), String(process.pid));
  expect(holdingProc([p], readBotPids(home), OP_BOT)).toBe(true);
  expect(holdingProc([{ ...p, pid: 4_000_000 }], readBotPids(home), OP_BOT)).toBe(false);
});

test("hold rules: a stale bot.pid with no live process does not hold", () => {
  const home = tmp("peer-notify-home-");
  fs.mkdirSync(join(home, ".claude", "channels", "telegram"), { recursive: true });
  fs.writeFileSync(join(home, ".claude", "channels", "telegram", "bot.pid"), "4000000");
  expect(readBotPids(home)).toEqual([]);
  expect(holdingProc([], readBotPids(home), OP_BOT)).toBe(false);
});

test("hold rules: one held line after 10 minutes, once per hold", async () => {
  const w = world({ procs: [{ pid: 5, ownPoller: true, botIds: [OP_BOT] }] });
  await w.add(wake(1));
  w.fresh();
  const since = w.c.t + MIN;
  for (let i = 0; i < 12; i++) { w.c.t += MIN; w.fresh(); await w.f.flush(); }
  const held = `peer notifications held since ${String(new Date(since).getHours()).padStart(2, "0")}:${String(new Date(since).getMinutes()).padStart(2, "0")} (plugin-poller)`;
  expect(w.sent.map(s => s.text)).toEqual([held]);
  w.procs.list = [];
  await w.f.flush();
  expect(w.sent).toHaveLength(2);
  w.procs.list = [{ pid: 5, ownPoller: true, botIds: [OP_BOT] }];
  for (let i = 0; i < 11; i++) { w.c.t += MIN; w.fresh(); await w.f.flush(); }
  expect(w.sent.filter(s => s.text.startsWith("peer notifications held"))).toHaveLength(2);
});

test("hold rules: macOS ps -E words", () => {
  const root = pluginFixture(join(tmp("peer-notify-mac-"), "plugins/cache/himmel/telegram-himmel/0.0.23"));
  const list = `  41 bun server.ts\n  42 /usr/bin/bun server.ts\n  43 vim notes.txt\n`;
  const env: Record<number, string | null> = {
    41: `bun server.ts TELEGRAM_OWN_POLLER=1 NOTE=see TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x HOME=/Users/x TELEGRAM_BOT_TOKEN=${OTHER_BOT}:y`,
    42: `bun server.ts TELEGRAM_OWN_POLLER=1 TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x NOTE=TELEGRAM_BOT_TOKEN=${OP_BOT}:z`,
  };
  const procs = macProcsFrom(list, () => root, pid => env[pid] ?? null);
  expect(procs.map(p => p.pid)).toEqual([41, 42]);
  expect(holdingProc([procs[0]], [], OP_BOT)).toBe(false);
  const embedded = macProcsFrom(`  44 bun server.ts\n`, () => root, () => `bun server.ts TELEGRAM_OWN_POLLER=1 TELEGRAM_BOT_TOKEN=${OTHER_BOT}:x NOTE=x TELEGRAM_BOT_TOKEN=${OP_BOT}:z`);
  expect(holdingProc(embedded, [], OP_BOT)).toBe(true);
  expect(macProcsFrom(`  45 bun server.ts\n`, () => root, () => null)[0].ownPoller).toBe("unknown");
});

function pluginFixture(root: string): string {
  fs.mkdirSync(join(root, ".claude-plugin"), { recursive: true });
  const src = join(REPO, "marketplace/plugins/telegram-himmel");
  fs.copyFileSync(join(src, ".claude-plugin/plugin.json"), join(root, ".claude-plugin/plugin.json"));
  fs.copyFileSync(join(src, "run-bun.sh"), join(root, "run-bun.sh"));
  const pkg = JSON.parse(fs.readFileSync(join(src, "package.json"), "utf8"));
  pkg.scripts.start = pkg.scripts.start.replace(/^bun install.*?&&\s*/, "");
  fs.writeFileSync(join(root, "package.json"), JSON.stringify(pkg));
  fs.writeFileSync(join(root, "server.ts"), "setInterval(() => {}, 1000);\n");
  return root;
}

async function launch(root: string, env: Record<string, string>): Promise<void> {
  const c = spawn("bash", [join(root, "run-bun.sh"), "run", "--cwd", root, "--shell=bun", "--silent", "start"], { cwd: tmpdir(), env: { PATH: process.env.PATH!, HOME: tmp("peer-notify-home-"), ...env }, detached: true, stdio: "ignore" });
  children.push(c);
  await waitFor(() => readProcs().some(p => isUnder(p.pid, root)));
}
async function waitFor(ready: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !ready(); i++) await Bun.sleep(50);
}
const isUnder = (pid: number, root: string) => { try { return fs.readlinkSync(`/proc/${pid}/cwd`) === root; } catch { return false; } };

test.skipIf(process.platform !== "linux")("procs reads a real plugin process", async () => {
  const root = pluginFixture(join(tmp("peer-notify-cache-"), "plugins/cache/himmel/telegram-himmel/0.0.23"));
  expect(JSON.parse(fs.readFileSync(join(root, "package.json"), "utf8")).scripts.start).toBe("bun server.ts");
  await launch(root, { TELEGRAM_OWN_POLLER: "1", TELEGRAM_BOT_TOKEN: `${OP_BOT}:${"D".repeat(35)}` });
  const mine = readProcs().filter(p => isUnder(p.pid, root));
  expect(mine).toHaveLength(1);
  expect(mine[0]).toMatchObject({ ownPoller: true, botIds: [OP_BOT] });
  expect(fs.readFileSync(`/proc/${mine[0].pid}/cmdline`, "utf8").split("\0")).toContain("server.ts");
});

test.skipIf(process.platform !== "linux")("procs ignores an unrelated bun server.ts", async () => {
  const root = tmp("peer-notify-other-");
  fs.writeFileSync(join(root, "server.ts"), "setInterval(() => {}, 1000);\n");
  const c = spawn("bun", ["server.ts"], { cwd: root, env: { PATH: process.env.PATH!, TELEGRAM_OWN_POLLER: "1", TELEGRAM_BOT_TOKEN: `${OP_BOT}:x` }, detached: true, stdio: "ignore" });
  children.push(c);
  await waitFor(() => isUnder(c.pid!, root));
  expect(isUnder(c.pid!, root)).toBe(true);
  expect(readProcs().filter(p => isUnder(p.pid, root))).toEqual([]);
});

test.skipIf(process.platform !== "linux")("procs reads a dev-checkout plugin root", async () => {
  const root = pluginFixture(join(tmp("peer-notify-dev-"), "marketplace/plugins/telegram-himmel"));
  await launch(root, { TELEGRAM_OWN_POLLER: "1", TELEGRAM_BOT_TOKEN: `${OP_BOT}:${"E".repeat(35)}` });
  expect(readProcs().filter(p => isUnder(p.pid, root))).toMatchObject([{ ownPoller: true, botIds: [OP_BOT] }]);
});

test("the plugin's state-dir and token rule matches fixtures copied from server.ts", () => {
  const server = fs.readFileSync(join(REPO, "marketplace/plugins/telegram-himmel/server.ts"), "utf8");
  expect(server).toContain("const STATE_DIR = process.env.TELEGRAM_STATE_DIR\n  ?? join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude'), 'channels', 'telegram')");
  expect(server).toContain("const ENV_FILE = join(STATE_DIR, '.env')");
  expect(server).toContain("if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2]");
  expect(server).toContain("const OWN_POLLER = process.env.TELEGRAM_OWN_POLLER === '1'");
  expect(pluginStateDir({}, "/h")).toBe("/h/.claude/channels/telegram");
  expect(pluginStateDir({ CLAUDE_CONFIG_DIR: "/c" }, "/h")).toBe("/c/channels/telegram");
  expect(pluginStateDir({ TELEGRAM_STATE_DIR: "/s", CLAUDE_CONFIG_DIR: "/c" }, "/h")).toBe("/s");
});

test("send, then sent map, then cursor; a crash after the send repeats once per crash", async () => {
  const w = world();
  await w.add(wake(1)); await w.add(wake(2));
  w.fresh();
  fs.mkdirSync(join(w.S, "notify"), { recursive: true });
  fs.writeFileSync(sentDir(w.S), "blocks the sent map");
  await expect(w.f.flush()).rejects.toThrow();
  expect(w.sent).toHaveLength(1);
  expect(readCursor(w.S).n).toBe(0);
  fs.rmSync(sentDir(w.S));
  await w.f.flush();
  expect(w.sent.map(s => s.text.split("\n")[0])).toEqual(["peer example · T1 · new question", "peer example · T1 · new question", "peer example · T2 · new question"]);
  expect(readCursor(w.S).n).toBe(2);
  expect(readSent(w.S, 702)).toMatchObject({ n: 1, type: "wake", peer: "example", root: 1, dir: "in" });
  expect(w.sent.every(s => s.opts.noPreview === true)).toBe(true);
  await w.f.flush();
  expect(w.sent).toHaveLength(3);
});

test("transient retries; maybe-sent advances with no map entry; permanent advances and sends the fallback line once", async () => {
  const w = world();
  for (let i = 1; i <= 4; i++) await w.add(wake(i));
  w.fresh();
  w.setScript([{ ok: false, code: 429, kind: "transient" }]);
  await w.f.flush();
  expect(readCursor(w.S).n).toBe(0);
  w.setScript([{ ok: false, code: null, kind: "not-sent" }]);
  await w.f.flush();
  expect(readCursor(w.S).n).toBe(0);
  w.setScript([{ ok: false, code: null, kind: "maybe-sent" }, { ok: false, code: 400, kind: "permanent" }, { ok: false, code: 400, kind: "permanent" }]);
  await w.f.flush();
  expect(readCursor(w.S).n).toBe(4);
  const texts = w.sent.map(s => s.text.split("\n")[0]);
  expect(texts.slice(2)).toEqual(["peer example · T1 · new question", "peer example · T2 · new question", "peer notify #2 could not be delivered (Telegram 400); read the desk", "peer example · T3 · new question", "peer example · T4 · new question"]);
  expect(fs.readdirSync(sentDir(w.S)).sort()).toHaveLength(2);
  expect(w.logs.some(l => l.includes("#2") && l.includes("400"))).toBe(true);
});

test("a broken chain sends one chain alert and stops", async () => {
  const w = world();
  for (let i = 1; i <= 3; i++) await w.add(wake(i));
  w.fresh();
  const file = notifyFile(w.S);
  const lines = fs.readFileSync(file, "utf8").split("\n");
  lines[1] = lines[1].replace('"root":2', '"root":9');
  fs.writeFileSync(file, lines.join("\n"));
  await w.f.flush();
  await w.f.flush();
  expect(w.sent.map(s => s.text)).toEqual(["peer notify chain failed verification at #2; nothing more is sent until it is checked"]);
});

test("a peers.json operatorChatId or operatorBotId differing from the bridge's sends nothing", async () => {
  for (const over of [{ peersChat: 5151 }, { peersBot: OTHER_BOT }]) {
    const w = world(over);
    await w.add(wake(1));
    w.fresh();
    await w.f.flush(); await w.f.flush();
    expect(w.sent).toEqual([]);
    expect(w.logs).toHaveLength(1);
  }
});

test("sent-map entries older than 7 days are pruned", async () => {
  const w = world();
  await w.add(wake(1));
  w.fresh();
  await w.f.flush();
  expect(fs.readdirSync(sentDir(w.S))).toHaveLength(1);
  w.c.t += 7 * 86_400_000 + 1;
  await w.add(wake(2));
  w.fresh();
  await w.f.flush();
  expect(fs.readdirSync(sentDir(w.S))).toEqual(["702"]);
});

test("flusher writes only cursor and sent map, and logs no text", async () => {
  const w = world();
  const CANARY = "CANARY-9c1e";
  await w.add({ kind: "notify", type: "escalate", peer: "example", root: 1, dir: "in", message_id: 1, label: "new question", summary: CANARY, asks: [CANARY], ts: 1 });
  await w.add({ kind: "notify", type: "escalate", peer: "example", root: 2, dir: "in", message_id: 2, label: "new question", summary: CANARY, asks: [], ts: 1 });
  w.fresh();
  const before = snapshot(w.S);
  w.setScript([{ ok: true, messageId: 801 }, { ok: false, code: 403, kind: "permanent" }]);
  await w.f.flush();
  const after = snapshot(w.S);
  const added = after.filter(x => !before.includes(x)).map(x => x.split(":")[0]);
  expect(added.sort()).toEqual(["/notify/cursor", "/notify/sent/801"]);
  expect(before.every(x => after.includes(x))).toBe(true);
  expect(w.logs.join("\n")).not.toContain(CANARY);
  expect(after.filter(x => x.startsWith("/notify/sent/") || x.startsWith("/notify/cursor")).join("\n")).not.toContain(CANARY);
  expect(w.sent[0].text).toContain(CANARY);
});

const NOTIFY_LINE1 = "peer example · #3 new question · 12:00Z";
const NOW_S = () => Math.floor(Date.now() / 1000);
const quoted = (message_id: number, text: string) => ({ message_id, from: { id: Number(OP_BOT), is_bot: true }, text });
const textUpdate = (text: string, reply: object) => ({ update_id: 1, message: { message_id: 90, date: NOW_S(), chat: { id: OP_CHAT, type: "private" }, from: { id: OP_CHAT }, text, reply_to_message: reply } });

function bridge() {
  const r = tmp("peer-reply-root-"), S = tmp("peer-reply-S-");
  fs.mkdirSync(sentDir(S), { recursive: true });
  fs.writeFileSync(join(sentDir(S), "701"), JSON.stringify({ n: 1, type: "escalate", peer: "example", root: 3, dir: "in", ts: Date.now() }));
  const peerReplies: string[] = [], ran: string[] = [], consoleAsked: number[] = [];
  const access = { allowFrom: [String(OP_CHAT)] };
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, peerReply: makePeerReplyRoute({ stateDir: S, root: r, access: () => access, reply: async (_c, t) => { peerReplies.push(t); } }) };
  const consoleGate = { authorize: (from: number) => { consoleAsked.push(from); return true; }, reply: async () => {} };
  async function deliver(update: object, fetchImage?: (id: string, uid: number) => Promise<string | null>) {
    await ingestUpdates(r, [update], () => true, fetchImage);
    const [rec] = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
    const before = snapshot(r);
    await handleInbound(r, inboundToDelivered(rec), async (s: string) => { ran.push(s); }, auto, async () => "spawn-low", () => true, async () => {}, () => false, null, consoleGate);
    return { rec, before, after: snapshot(r) };
  }
  return { r, S, peerReplies, ran, consoleAsked, deliver };
}

test("text reply to a notify message never reaches handleInbound's routing", async () => {
  for (const [name, reply] of [["sent map", quoted(701, "a bot line that is not line 1")], ["line 1", quoted(555, NOTIFY_LINE1)]] as const) {
    const b = bridge();
    const { before, after } = await b.deliver(textUpdate(`please answer ${name}`, reply));
    expect(b.peerReplies).toEqual([PR1_REPLY_LINE]);
    expect(b.ran).toEqual([]);
    expect(b.consoleAsked).toEqual([]);
    expect(after).toEqual(before);
    expect(fs.existsSync(join(b.r, "sessions"))).toBe(false);
  }
  const b = bridge();
  fs.writeFileSync(join(b.r, "lockdown"), "locked\n");
  await b.deliver(textUpdate("answer while locked", quoted(701, "x")));
  expect(b.peerReplies).toEqual([LOCKED_LINE]);
  expect(b.ran).toEqual([]);
});

test("a /lockdown reply to an escalation reaches lockdown", async () => {
  const b = bridge();
  await b.deliver(textUpdate("/lockdown", quoted(701, NOTIFY_LINE1)));
  expect(b.peerReplies).toEqual([]);
  expect(fs.existsSync(join(b.r, "lockdown"))).toBe(true);
});

test("media reply to an escalation reaches handleInbound unchanged and carries no reply_to_text", async () => {
  const b = bridge();
  const update = { update_id: 2, message: { message_id: 91, date: NOW_S(), chat: { id: OP_CHAT, type: "private" }, from: { id: OP_CHAT }, caption: "see this", photo: [{ file_id: "p1", width: 1, height: 1 }], reply_to_message: quoted(701, NOTIFY_LINE1) } };
  const { rec } = await b.deliver(update, async () => "/tmp/att/91.jpg");
  expect(rec.reply_to_text).toBeUndefined();
  expect(rec.reply_to_message_id).toBeUndefined();
  expect(rec.text).toBe("see this");
  expect(b.peerReplies).toEqual([]);
  expect(b.ran).toEqual(["__chat__"]);
});

test("a reply to a non-notify bot message routes as today", async () => {
  const b = bridge();
  await b.deliver(textUpdate("thanks", quoted(555, "build finished")));
  expect(b.peerReplies).toEqual([]);
  expect(b.ran).toEqual(["__chat__"]);
});
