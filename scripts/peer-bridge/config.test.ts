import { expect, spyOn, test } from "bun:test";
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
