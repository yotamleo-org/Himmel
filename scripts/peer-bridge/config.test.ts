import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as C from "./config";
import { startIdentity } from "./chain";
import fs from "node:fs";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigError, MAX_JOB_MINUTES_MAX, clampToSchema, loadAllowlist, loadConfig } from "./config";
import { ALLOWANCE_S, TIMEOUT_S_MAX } from "./envelope";
import { botIdFromToken, PEER_NAME_RE, SESSION_ID_RE } from "./ids";
import { keyId } from "./sign";

const TOKEN = "1234567890:" + "A".repeat(35);
const OP_TOKEN = "9876543210:" + "B".repeat(35);
const ENV = { PEER_BOT_TOKEN: TOKEN };

const peer = (over: Record<string, unknown> = {}) => ({
  peerBotId: "555000111", chatId: null, allowFrom: ["555000111", "42"],
  opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10,
  maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" },
  ...over,
});
const base = (over: Record<string, unknown> = {}) => ({
  operatorBotId: "9876543210", operatorChatId: 4242, bridgeRoot: "/tmp/bridge", himmelRoot: "/tmp/himmel",
  peers: { example: peer() }, maxTextChars: 4000, addressing: "command", ...over,
});

function write(obj: unknown, mode = 0o600): string {
  const dir = mkdtempSync(join(tmpdir(), "peer-config-"));
  const path = join(dir, "peers.json");
  writeFileSync(path, typeof obj === "string" ? obj : JSON.stringify(obj));
  chmodSync(path, mode);
  return path;
}
function refusal(fn: () => unknown): ConfigError {
  try { fn(); } catch (e) { expect(e).toBeInstanceOf(ConfigError); return e as ConfigError; }
  throw new Error("expected a ConfigError");
}

test("a well-formed config loads", () => {
  const cfg = loadConfig(write(base()), ENV);
  expect(cfg.operatorChatId).toBe(4242);
  expect(cfg.peers.example.peerBotId).toBe("555000111");
  expect(cfg.addressing).toBe("command");
  expect(JSON.stringify(cfg)).not.toContain(TOKEN);
});

test("mode 0644 refuses with code 78", () => {
  const e = refusal(() => loadConfig(write(base(), 0o644), ENV));
  expect(e.code).toBe(78);
  expect(e.message).toContain("0600");
});

test("another owner refuses with code 78", () => {
  const path = write(base());
  const real = fs.fstatSync;
  const spy = spyOn(fs, "fstatSync").mockImplementation(((fd: number) => ({ ...real(fd), isFile: () => true, uid: process.getuid!() + 1, mode: 0o100600 })) as any);
  const e = refusal(() => loadConfig(path, ENV));
  spy.mockRestore();
  expect(e.code).toBe(78);
  expect(e.message).toContain("owned");
});

test("a peer name outside the shape refuses", () => {
  expect(refusal(() => loadConfig(write(base({ peers: { "Example!": peer() } })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(base({ peers: { "-x": peer() } })), ENV)).code).toBe(78);
  expect(PEER_NAME_RE.test("a".repeat(33))).toBe(false);
});

test("a token whose prefix equals operatorBotId refuses", () => {
  const e = refusal(() => loadConfig(write(base()), { PEER_BOT_TOKEN: OP_TOKEN }));
  expect(e.code).toBe(78);
  expect(e.message).not.toContain(OP_TOKEN);
});

test("a missing or malformed token refuses, and the message never holds it", () => {
  expect(refusal(() => loadConfig(write(base()), {})).code).toBe(78);
  expect(refusal(() => loadConfig(write(base()), { PEER_BOT_TOKEN: "" })).code).toBe(78);
  const e = refusal(() => loadConfig(write(base()), { PEER_BOT_TOKEN: "not-a-token-secret" }));
  expect(e.message).not.toContain("not-a-token-secret");
});

test("a non-numeric operatorChatId refuses", () => {
  expect(refusal(() => loadConfig(write(base({ operatorChatId: "4242" })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(base({ operatorChatId: null })), ENV)).code).toBe(78);
});

test("the operator DM is unset on an older config, loads when it is the operator chat, and refuses any other chat", () => {
  expect(loadConfig(write(base()), ENV).operatorDmChatId).toBeNull();
  expect(loadConfig(write(base({ operatorDmChatId: 4242 })), ENV).operatorDmChatId).toBe(4242);
  for (const bad of [4243, -1001234567890, "4242"]) expect(refusal(() => loadConfig(write(base({ operatorDmChatId: bad })), ENV)).message).toBe("operatorDmChatId must be null or the operator chat id");
});

test("other fields refuse: addressing, text cap, kinds, bad json, missing file", () => {
  expect(refusal(() => loadConfig(write(base({ addressing: "admin" })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(base({ maxTextChars: 5000 })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(base({ peers: { example: peer({ opens: ["run"] }) } })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write("{nope"), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(join(tmpdir(), "peer-config-missing", "peers.json"), ENV)).code).toBe(78);
});

test("loading opens only peers.json, never the operator channel dir", () => {
  const path = write(base());
  const opened: string[] = [];
  const real = fs.openSync;
  const spy = spyOn(fs, "openSync").mockImplementation(((p: any, ...rest: any[]) => { opened.push(String(p)); return (real as any)(p, ...rest); }) as any);
  loadConfig(path, ENV);
  spy.mockRestore();
  expect(opened).toEqual([path]);
  expect(opened.some(p => p.includes(".claude/channels/telegram"))).toBe(false);
});

const PUB_A = Buffer.alloc(32, 1).toString("base64"), PUB_B = Buffer.alloc(32, 2).toString("base64");
const key = (pub: string, addedAt = "2026-11-10T00:00:00Z") => ({ id: keyId(pub), pub, addedAt });
const withTheirs = (over: Record<string, unknown>) => base({ peers: { example: peer({ theirs: { ...peer().theirs, ...over } }) } });

test("station names and peer keys load; an older config without them still loads", () => {
  const old = loadConfig(write(base()), ENV);
  expect(old.self).toEqual({});
  expect(old.peers.example.theirs.keys).toEqual([]);
  expect(old.peers.example.theirs.stationName).toBeUndefined();

  const cfg = loadConfig(write(base({ self: { stationName: "yotam" }, peers: { example: peer({ theirs: { ...peer().theirs, stationName: "example", keys: [key(PUB_A), key(PUB_B)] } }) } })), ENV);
  expect(cfg.self.stationName).toBe("yotam");
  expect(cfg.peers.example.theirs.stationName).toBe("example");
  expect(cfg.peers.example.theirs.keys.map(k => k.pub)).toEqual([PUB_A, PUB_B]);
});

test("a station name outside the shape, or a key that is not what it says, refuses", () => {
  expect(refusal(() => loadConfig(write(base({ self: { stationName: "Yo Tam" } })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ stationName: "x.local" })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ keys: [key(PUB_A), key(PUB_B), key(Buffer.alloc(32, 3).toString("base64"))] })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ keys: [{ ...key(PUB_A), id: "00000000" }] })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ keys: [key("c2hvcnQ=")] })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ keys: [key(PUB_A, "yesterday")] })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withTheirs({ keys: "none" })), ENV)).code).toBe(78);
});

const withPeer = (over: Record<string, unknown>) => base({ peers: { example: peer(over) } });
const BUDGETS = { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130 };
const MAX_JOB_MIN = TIMEOUT_S_MAX / 60 - ALLOWANCE_S / 60;

test("serving defaults: nothing served, approval at a TTY, the spec's budgets, no repo", () => {
  const p = loadConfig(write(base()), ENV).peers.example;
  expect(p.serves).toEqual([]);
  expect(p.approve).toEqual({ "run-suite": "tty" });
  expect(p.budgets).toEqual(BUDGETS);
  expect(p.repoUrl).toBeUndefined();
  expect(p.theirs.imageDigest).toBeUndefined();
});

test("serving fields load when set", () => {
  const p = loadConfig(write(withPeer({
    serves: ["run-suite"], approve: { "run-suite": "auto" }, budgets: { jobsPerDay: 1000, vmMinutesPerDay: 10000, queueMax: 1, maxJobMinutes: 30 },
    repoUrl: "https://example.org/x/y.git", theirs: { ...peer().theirs, imageDigest: "a".repeat(64) },
  })), ENV).peers.example;
  expect(p.serves).toEqual(["run-suite"]);
  expect(p.approve["run-suite"]).toBe("auto");
  expect(p.budgets).toEqual({ jobsPerDay: 1000, vmMinutesPerDay: 10000, queueMax: 1, maxJobMinutes: 30 });
  expect(p.repoUrl).toBe("https://example.org/x/y.git");
  expect(p.theirs.imageDigest).toBe("a".repeat(64));
});

test("each budget outside its bound is refused at load, and each bound itself loads", () => {
  const load = (b: Record<string, unknown>) => loadConfig(write(withPeer({ budgets: { ...BUDGETS, ...b } })), ENV);
  for (const [k, lo, hi] of [["jobsPerDay", 1, 1000], ["vmMinutesPerDay", 1, 10000], ["queueMax", 1, 3], ["maxJobMinutes", 30, MAX_JOB_MIN]] as const) {
    expect(load({ [k]: lo }).peers.example.budgets[k]).toBe(lo);
    expect(load({ [k]: hi }).peers.example.budgets[k]).toBe(hi);
    expect(refusal(() => load({ [k]: lo - 1 })).code).toBe(78);
    expect(refusal(() => load({ [k]: hi + 1 })).code).toBe(78);
    expect(refusal(() => load({ [k]: lo + 0.5 })).code).toBe(78);
    expect(refusal(() => load({ [k]: String(lo) })).code).toBe(78);
  }
  expect(refusal(() => loadConfig(write(withPeer({ budgets: { ...BUDGETS, extra: 1 } })), ENV)).code).toBe(78);
  expect(refusal(() => loadConfig(write(withPeer({ budgets: { jobsPerDay: 10 } })), ENV)).code).toBe(78);
});

test("the maxJobMinutes ceiling is derived from the two time constants, 150 today", () => {
  expect(MAX_JOB_MIN).toBe(150);
  expect(MAX_JOB_MINUTES_MAX).toBe(MAX_JOB_MIN);
  expect(MAX_JOB_MINUTES_MAX * 60 + ALLOWANCE_S).toBe(TIMEOUT_S_MAX);
});

test("serves, approve, repoUrl and imageDigest outside their shape are refused", () => {
  for (const over of [
    { serves: ["run-suite", "run-prompt"] }, { serves: "run-suite" }, { serves: [1] },
    { approve: { "run-suite": "yes" } }, { approve: { "run-suite": "tty", "run-prompt": "auto" } }, { approve: "tty" },
    { repoUrl: "" }, { repoUrl: "ftp://x/y" }, { repoUrl: "https://a b" }, { repoUrl: 5 },
    { theirs: { ...peer().theirs, imageDigest: "xyz" } }, { theirs: { ...peer().theirs, imageDigest: "A".repeat(64) } },
  ]) expect([JSON.stringify(over), refusal(() => loadConfig(write(withPeer(over)), ENV)).code]).toEqual([JSON.stringify(over), 78]);
});

test("a reported value is clamped to the schema's range, so our own egress re-check passes", () => {
  expect(clampToSchema("queue", 7)).toBe(3);
  expect(clampToSchema("queue", -2)).toBe(0);
  expect(clampToSchema("jobs_left", 5000)).toBe(1000);
  expect(clampToSchema("vm_minutes_left", 99_999)).toBe(10000);
  expect(clampToSchema("minutes", 181)).toBe(180);
  expect(clampToSchema("minutes", 12.9)).toBe(12);
  expect(clampToSchema("timeout_s", 5)).toBe(60);
  expect(clampToSchema("timeout_s", 99_999)).toBe(TIMEOUT_S_MAX);
  expect(clampToSchema("bytes", 6_000_000)).toBe(5_242_880);
  expect(clampToSchema("minutes", Number.NaN)).toBe(0);
  expect(() => clampToSchema("nope", 1)).toThrow();
});

function suitesFile(text: string, mode = 0o600): string {
  const dir = mkdtempSync(join(tmpdir(), "peer-suites-"));
  writeFileSync(join(dir, "example.suites"), text, { mode });
  chmodSync(join(dir, "example.suites"), mode);
  return dir;
}

test("loadAllowlist reads alias/path pairs from C/<peer>.suites", () => {
  expect(loadAllowlist("example", suitesFile("peer-taint scripts/hooks/test-peer-taint.sh\nledger scripts/ci/test-suite-ledger.sh\n"))).toEqual([
    { alias: "peer-taint", path: "scripts/hooks/test-peer-taint.sh" }, { alias: "ledger", path: "scripts/ci/test-suite-ledger.sh" },
  ]);
  expect(loadAllowlist("example", suitesFile(""))).toEqual([]);
  expect(loadAllowlist("example", suitesFile("\na scripts/x.sh\n\n"))).toEqual([{ alias: "a", path: "scripts/x.sh" }]);
  expect(loadAllowlist("example", mkdtempSync(join(tmpdir(), "peer-nosuites-")))).toEqual([]);
});

test("loadAllowlist refuses a bad alias, a path failing the suite regex, a bad line shape or a duplicate", () => {
  for (const line of [
    "Bad scripts/x.sh", "a_b scripts/x.sh", `${"a".repeat(33)} scripts/x.sh`, "a scripts/../x.sh", "a scripts/UP.sh", "a /etc/passwd", "a scripts/x.py",
    "a", "a scripts/x.sh extra", "a  scripts/x.sh", " a scripts/x.sh", "a\tscripts/x.sh", "a scripts/x.sh ", "# a scripts/x.sh",
  ]) {
    const e = refusal(() => loadAllowlist("example", suitesFile(line + "\n")));
    expect([line, e.code]).toEqual([line, 78]);
  }
  expect(refusal(() => loadAllowlist("example", suitesFile("a scripts/x.sh\na scripts/y.sh\n"))).message).toContain("duplicate");
  expect(refusal(() => loadAllowlist("example", suitesFile("a scripts/x.sh\nb scripts/x.sh\n"))).message).toContain("duplicate");
  expect(refusal(() => loadAllowlist("example", suitesFile("a scripts/x.sh\n", 0o644))).message).toContain("0600");
  expect(refusal(() => loadAllowlist("../x", suitesFile(""))).code).toBe(78);
});

test("config.ts holds no literal of the time constants: 1200, 150 or 10200", () => {
  const src = fs.readFileSync(join(import.meta.dir, "config.ts"), "utf8");
  expect(src.match(/\b(1200|150|10200)\b/g)).toBeNull();
});

test("ids: the bot id is the token prefix, and the session id shape is closed", () => {
  expect(botIdFromToken(TOKEN)).toBe("1234567890");
  expect(botIdFromToken("nocolon")).toBe("");
  expect(SESSION_ID_RE.test("abc-123")).toBe(true);
  for (const bad of ["../x", "", "a/b", "a".repeat(65), "a b"]) expect(SESSION_ID_RE.test(bad)).toBe(false);
});


const REAL_HOME = process.env.HOME;
const realStamp = () => { try { const s = fs.statSync(join(REAL_HOME!, ".himmel", "remote-setup", "pairing.json")); return [s.ino, s.size, s.mtimeMs].join(":"); } catch { return "absent"; } };
const REAL_STAMP = realStamp();
let testHome = "";
const children: { kill(): void }[] = [];
beforeEach(() => { testHome = mkdtempSync(join(tmpdir(), "peer-config-home-")); process.env.HOME = testHome; });
afterEach(() => {
  for (const c of children.splice(0)) c.kill();
  if (REAL_HOME === undefined) delete process.env.HOME; else process.env.HOME = REAL_HOME;
  fs.rmSync(testHome, { recursive: true, force: true });
});

const K1 = Buffer.alloc(32, 7).toString("base64"), K2 = Buffer.alloc(32, 9).toString("base64");

test("canonicalKey takes 32 canonical base64 bytes only", () => {
  expect(C.canonicalKey(K1)).toBe(true);
  for (const bad of [Buffer.alloc(31, 7).toString("base64"), Buffer.alloc(33, 7).toString("base64"), K1.slice(0, -2) + "d=", "x"]) expect([bad, C.canonicalKey(bad)]).toEqual([bad, false]);
});

test("parseCard reads the bare line and the two-line wire form, and nothing else", () => {
  const card = "#pair station=example key=" + K1;
  const want = { station: "example", pub: K1 };
  expect(C.parseCard(card)).toEqual(want);
  expect(C.parseCard("/peer@ours_bot\n" + card, "ours_bot")).toEqual(want);
  expect(C.parseCard("/peer@anybody_bot\n" + card)).toEqual(want);
  expect(C.parseCard(card, "ours_bot")).toEqual(want);
  const bads = [
    card + "\nmore", "/peer@ours_bot\n" + card + "\nmore", card + " ", card + "\r", "/peer@ours_bot\r\n" + card, "/peer@x\n" + card, "hello\n" + card,
    "#pair station=example key=" + Buffer.alloc(31, 1).toString("base64"), "#pair station=example key=" + K1.slice(0, -2) + "d=",
  ];
  for (const bad of bads) expect([bad, C.parseCard(bad)]).toEqual([bad, null]);
  expect(C.parseCard("/peer@other_bot\n" + card, "ours_bot")).toBeNull();
});

test("cardMessage addresses the peer the way the poller addresses a root, and parses back", () => {
  expect(C.cardMessage("example_bot", "yotam", K1)).toBe("/peer@example_bot\n#pair station=yotam key=" + K1);
  expect(C.parseCard(C.cardMessage("example_bot", "yotam", K1), "example_bot")).toEqual({ station: "yotam", pub: K1 });
});

const trustCfg = (keys: unknown[] = [], name?: string) => C.parsePeers(Buffer.from(JSON.stringify(withTheirs(name ? { keys, stationName: name } : { keys }))));
const rule = (cfg: any, over: Record<string, unknown> = {}) => {
  const a = { peer: "example", station: "example", pub: K1, host: "box.lan", firstOnly: false, ...over } as any;
  return C.trustRefusal(cfg, a.peer, a.station, a.pub, a.host, { firstOnly: a.firstOnly });
};

test("trustRefusal names the first rule that refuses", () => {
  const cfg = trustCfg();
  expect(rule(cfg)).toBeNull();
  expect(rule(cfg, { peer: "nobody" })).toBe("unknown-peer");
  expect(rule(trustCfg([key(K2)]), { firstOnly: true })).toBe("already-paired");
  expect(rule(trustCfg([key(K2)]))).toBeNull();
  expect(rule(cfg, { station: "Bad Name" })).toBe("name");
  expect(rule(cfg, { station: "box" })).toBe("host");
  expect(rule(cfg, { pub: "c2hvcnQ=" })).toBe("key-shape");
  expect(rule(trustCfg([key(K1)]))).toBe("already-trusted");
  expect(rule(trustCfg([key(K2), key(Buffer.alloc(32, 4).toString("base64"))]))).toBe("two-keys");
  expect(rule(trustCfg([], "someone-else"))).toBe("name-differs");
});

test("readPeersBytes then parsePeers equals readPeersFile", () => {
  for (const d of [base(), withTheirs({ stationName: "example", keys: [key(K1)] }), withPeer({ serves: ["run-suite"] })]) {
    const path = write(d);
    expect(C.parsePeers(C.readPeersBytes(path))).toEqual(C.readPeersFile(path));
  }
  expect(refusal(() => C.readPeersBytes(write(base(), 0o644))).message).toContain("0600");
});

function clock(onSleep?: () => unknown) {
  let offset = 0;
  const c = { sleeps: 0, now: () => Date.now() + offset, sleep: async (ms: number) => { c.sleeps++; offset += ms; if (onSleep) await onSleep(); } };
  return c;
}
const lockDir = () => mkdtempSync(join(tmpdir(), "peer-lock-"));
const LOCK = (d: string) => join(d, "peers.json.lock");
const lockHolder = (d: string) => JSON.parse(fs.readFileSync(LOCK(d), "utf8"));
const age = (path: string, ms: number) => { const t = new Date(Date.now() - ms); fs.utimesSync(path, t, t); };
const inoOf = (path: string) => fs.lstatSync(path).ino;
const gate = () => { let open!: () => void; const p = new Promise<void>(r => { open = r; }); return { p, open }; };
function liveChild() {
  const c = Bun.spawn(["cat"], { stdin: "pipe", stdout: "ignore" });
  children.push(c);
  return c;
}
const lockAs = (d: string, pid: number, start: string | null) => writeFileSync(LOCK(d), JSON.stringify({ pid, start }), { mode: 0o600 });
const liveLock = (d: string) => { const c = liveChild(); lockAs(d, c.pid, startIdentity(c.pid)); return c; };
const DEAD_PID = 2_000_000_000;
function holderChild(d: string) {
  const script = join(lockDir(), "holder.ts");
  writeFileSync(script, [
    "import { withPeersLock } from " + JSON.stringify(join(import.meta.dir, "config.ts")) + ";",
    "await withPeersLock(" + JSON.stringify(d) + ", async () => { console.log('held'); await new Promise(r => process.stdin.once('data', r)); }, { now: () => Date.now(), sleep: ms => new Promise(r => setTimeout(r, ms)) });",
    "console.log('released');",
    "process.exit(0);",
  ].join("\n"));
  const c = Bun.spawn(["bun", script], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
  children.push(c);
  const reader = c.stdout.getReader();
  let buf = "";
  const until = async (word: string) => { while (!buf.includes(word)) { const { value, done } = await reader.read(); if (done) throw new Error("holder ended before " + word); buf += new TextDecoder().decode(value); } };
  return { pid: c.pid, until, release: async () => { c.stdin.write("go\n"); c.stdin.flush(); await until("released"); } };
}

test("the lock appears with its holder already in it", async () => {
  const d = lockDir();
  let before = true;
  await C.withPeersLock(d, () => {
    expect(lockHolder(d)).toEqual({ pid: process.pid, start: startIdentity(process.pid) });
  }, { ...clock(), hooks: { beforeLink: () => { before = fs.existsSync(LOCK(d)); } } });
  expect(before).toBe(false);
  expect(fs.readdirSync(d)).toEqual([]);
});

test("a live holder's fresh lock gives busy once the clock passes 2 s", async () => {
  const d = lockDir();
  liveLock(d);
  const c = clock();
  await expect(C.withPeersLock(d, () => 1, c)).rejects.toThrow("busy");
  expect(c.sleeps).toBeGreaterThan(0);
  expect(fs.existsSync(LOCK(d))).toBe(true);
});

test("a dead holder, a reused pid or a lock older than 10 s is taken; a younger live one never is", async () => {
  for (const set of [
    (d: string) => lockAs(d, DEAD_PID, "1"),
    (d: string) => lockAs(d, liveChild().pid, "not-its-start"),
    (d: string) => { liveLock(d); age(LOCK(d), 11_000); },
    (d: string) => { writeFileSync(LOCK(d), "garbage"); age(LOCK(d), 11_000); },
  ]) {
    const d = lockDir(); set(d);
    const c = clock();
    expect(await C.withPeersLock(d, () => "took", c)).toBe("took");
    expect(c.sleeps).toBe(0);
    expect(fs.readdirSync(d)).toEqual([]);
  }
  const d = lockDir(); liveLock(d); age(LOCK(d), 7_000);
  await expect(C.withPeersLock(d, () => 1, clock())).rejects.toThrow("busy");
});

const seedPeers = (obj: unknown = base()) => {
  const d = lockDir(), path = join(d, "peers.json");
  writeFileSync(path, JSON.stringify(obj, null, 2) + "\n", { mode: 0o600 });
  chmodSync(path, 0o600);
  return { d, path };
};

test("two processes: the second writer waits for the child, then writes; past 2 s it is busy", async () => {
  const { d, path } = seedPeers();
  const child = holderChild(d);
  await child.until("held");
  let released = false;
  const c = clock(async () => { if (!released) { released = true; await child.release(); } });
  const bytes = fs.readFileSync(path);
  await C.replacePeersJson(path, bytes, { ...JSON.parse(bytes.toString()), maxTextChars: 3999 }, c);
  expect(c.sleeps).toBeGreaterThan(0);
  expect(JSON.parse(fs.readFileSync(path, "utf8")).maxTextChars).toBe(3999);

  const other = holderChild(d);
  await other.until("held");
  const now = fs.readFileSync(path);
  await expect(C.replacePeersJson(path, now, { ...JSON.parse(now.toString()), maxTextChars: 3998 }, clock())).rejects.toThrow("busy");
  expect(fs.readFileSync(path).equals(now)).toBe(true);
  await other.release();
});

test("break race: the breaker that ruled the dead lock stale never removes its successor's", async () => {
  const d = lockDir(); lockAs(d, DEAD_PID, "1");
  const ruled = gate(), resume = gate(), aHolds = gate(), aEnd = gate();
  let first = true;
  const b = C.withPeersLock(d, () => "b", { ...clock(), hooks: { afterRuledStale: async () => { if (!first) return; first = false; ruled.open(); await resume.p; } } });
  const bResult = b.then(() => "took", (e: Error) => e.message);
  await ruled.p;
  let aIno = 0;
  const a = C.withPeersLock(d, async () => { aIno = inoOf(LOCK(d)); aHolds.open(); await aEnd.p; }, clock());
  await aHolds.p;
  resume.open();
  expect(await bResult).toBe("busy");
  expect(inoOf(LOCK(d))).toBe(aIno);
  aEnd.open();
  await a;
});

test("put-back and J1: a moved newer lock is linked back; restored after its release, only age frees it", async () => {
  const d = lockDir(); lockAs(d, DEAD_PID, "1");
  const ruled = gate(), resume = gate(), moved = gate(), resume2 = gate(), aHolds = gate(), aEnd = gate();
  let r1 = true, r2 = true;
  const b = C.withPeersLock(d, () => "b", { ...clock(), hooks: {
    afterRuledStale: async () => { if (!r1) return; r1 = false; ruled.open(); await resume.p; },
    afterRename: async () => { if (!r2) return; r2 = false; moved.open(); await resume2.p; },
  } });
  const bResult = b.then(() => "took", (e: Error) => e.message);
  await ruled.p;
  let aIno = 0;
  const a = C.withPeersLock(d, async () => { aIno = inoOf(LOCK(d)); aHolds.open(); await aEnd.p; }, clock());
  await aHolds.p;
  resume.open();
  await moved.p;
  expect(fs.existsSync(LOCK(d))).toBe(false);
  aEnd.open();
  await a;
  resume2.open();
  expect(await bResult).toBe("busy");
  expect(inoOf(LOCK(d))).toBe(aIno);
  await expect(C.withPeersLock(d, () => "c", clock())).rejects.toThrow("busy");
  age(LOCK(d), 11_000);
  expect(await C.withPeersLock(d, () => "c", clock())).toBe("c");
});

test("same-file break: a lock ruled stale by age is deleted although it names a live process", async () => {
  const d = lockDir(); liveLock(d); age(LOCK(d), 11_000);
  const c = clock();
  let moved = 0;
  expect(await C.withPeersLock(d, () => "took", { ...c, hooks: { afterRename: () => { moved++; } } })).toBe("took");
  expect([moved, c.sleeps]).toEqual([1, 0]);
  expect(fs.readdirSync(d)).toEqual([]);
});

test("a writer displaced by the age rule releases and leaves its successor's lock", async () => {
  const d = lockDir();
  let child: ReturnType<typeof holderChild> | null = null;
  await C.withPeersLock(d, async () => {
    age(LOCK(d), 11_000);
    child = holderChild(d);
    await child.until("held");
  }, clock());
  expect(lockHolder(d).pid).toBe(child!.pid);
  await child!.release();
  expect(fs.existsSync(LOCK(d))).toBe(false);
});

const PAIRING = () => join(testHome, ".himmel", "remote-setup", "pairing.json");
const doc = (path: string) => JSON.parse(fs.readFileSync(path, "utf8"));
const writeOver = (path: string, mutate: (d: any) => void) => { const v = doc(path); mutate(v); writeFileSync(path, JSON.stringify(v, null, 2) + "\n"); };

test("replacePeersJson writes over the expected bytes and then rewrites pairing.json from them", async () => {
  const { path } = seedPeers();
  const bytes = fs.readFileSync(path);
  const next = JSON.parse(bytes.toString());
  next.peers.example.chatId = -100123;
  await C.replacePeersJson(path, bytes, next, clock());
  expect(doc(path).peers.example.chatId).toBe(-100123);
  expect(fs.statSync(path).mode & 0o777).toBe(0o600);
  expect(doc(PAIRING()).peers).toEqual([{ name: "example", ourStationName: false, ourStationKey: false, groupChat: true, operatorChat: false, theirKey: false }]);
});

test("replacePeersJson throws changed over a write made after the caller read, and leaves it", async () => {
  const { path } = seedPeers();
  const bytes = fs.readFileSync(path);
  await expect(C.replacePeersJson(path, bytes, JSON.parse(bytes.toString()), { ...clock(), hooks: { afterRead: () => writeOver(path, v => { v.maxTextChars = 3000; }) } })).rejects.toThrow("changed");
  expect(doc(path).maxTextChars).toBe(3000);
});

test("a pairing.json that cannot be written is logged and the peers.json write stands", async () => {
  const { path } = seedPeers();
  fs.mkdirSync(join(testHome, ".himmel"), { recursive: true });
  writeFileSync(join(testHome, ".himmel", "remote-setup"), "not a directory");
  const bytes = fs.readFileSync(path), lines: string[] = [];
  const next = JSON.parse(bytes.toString()); next.maxTextChars = 3000;
  await C.replacePeersJson(path, bytes, next, { ...clock(), log: (l: string) => lines.push(l) });
  expect(doc(path).maxTextChars).toBe(3000);
  expect(lines.join("\n")).toContain("pairing steps record could not be updated");
});

const addOpts = (over: Record<string, unknown> = {}) => ({ hostname: "box.lan", ...clock(), ...over }) as any;

test("addTrustedKey appends one key and the station name and changes nothing else in the raw document", async () => {
  const { path } = seedPeers();
  const before = doc(path);
  await C.addTrustedKey(path, "example", "their-box", K1, addOpts());
  const after = doc(path);
  const k = after.peers.example.theirs.keys[0];
  expect([after.peers.example.theirs.keys.length, k.id, k.pub, Number.isNaN(Date.parse(k.addedAt))]).toEqual([1, keyId(K1), K1, false]);
  expect(after.peers.example.theirs.stationName).toBe("their-box");
  delete after.peers.example.theirs.keys; delete after.peers.example.theirs.stationName;
  expect(after).toEqual(before);
});

test("addTrustedKey refuses each rule and leaves the bytes", async () => {
  const cases: [string, Record<string, unknown>, string, string, string, Record<string, unknown>][] = [
    ["already-paired", { keys: [key(K2)] }, "example", "their-box", K1, { firstOnly: true }],
    ["unknown-peer", {}, "nobody", "their-box", K1, {}],
    ["key-shape", {}, "example", "their-box", "c2hvcnQ=", {}],
    ["already-trusted", { keys: [key(K1)] }, "example", "their-box", K1, {}],
    ["two-keys", { keys: [key(K2), key(Buffer.alloc(32, 4).toString("base64"))] }, "example", "their-box", K1, {}],
    ["name-differs", { stationName: "other-name" }, "example", "their-box", K1, {}],
    ["name", {}, "example", "Bad Name", K1, {}],
    ["host", {}, "example", "localhost", K1, {}],
  ];
  for (const [want, theirs, name, station, pub, opts] of cases) {
    const { path } = seedPeers(withTheirs(theirs));
    const bytes = fs.readFileSync(path);
    await expect(C.addTrustedKey(path, name, station, pub, addOpts(opts))).rejects.toThrow(new RegExp("^" + want + "$"));
    expect([want, fs.readFileSync(path).equals(bytes)]).toEqual([want, true]);
  }
});

test("addTrustedKey's guard runs under the lock after the compare, and its refusal leaves the bytes", async () => {
  for (const want of ["lockdown", "killed"]) {
    const { d, path } = seedPeers();
    const flag = join(d, want), bytes = fs.readFileSync(path);
    await expect(C.addTrustedKey(path, "example", "their-box", K1, addOpts({
      hooks: { afterRead: () => writeFileSync(flag, "") },
      guard: () => { if (fs.existsSync(flag)) throw new ConfigError(want); },
    }))).rejects.toThrow(want);
    expect(fs.readFileSync(path).equals(bytes)).toBe(true);
  }
});

test("addTrustedKey retries one concurrent write on the fresh bytes; two report busy", async () => {
  const { path } = seedPeers();
  let n = 0;
  await C.addTrustedKey(path, "example", "their-box", K1, addOpts({ hooks: { afterRead: () => { if (n++ === 0) writeOver(path, v => { v.maxTextChars = 3000; }); } } }));
  expect([doc(path).maxTextChars, doc(path).peers.example.theirs.keys.length, n]).toEqual([3000, 1, 2]);
  const other = seedPeers();
  let m = 0;
  await expect(C.addTrustedKey(other.path, "example", "their-box", K1, addOpts({ hooks: { afterRead: () => writeOver(other.path, v => { v.maxTextChars = 3000 + ++m; }) } }))).rejects.toThrow("busy");
  expect(doc(other.path).peers.example.theirs.keys).toBeUndefined();
});

test("the operator's real pairing.json is untouched by this file", () => {
  expect(realStamp()).toBe(REAL_STAMP);
});
