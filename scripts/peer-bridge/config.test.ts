import { expect, spyOn, test } from "bun:test";
import fs from "node:fs";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigError, loadConfig } from "./config";
import { botIdFromToken, PEER_NAME_RE, SESSION_ID_RE } from "./ids";
import { keyId } from "./sign";

const TOKEN = "1234567890:" + "A".repeat(35);
const OP_TOKEN = "9876543210:" + "B".repeat(35);
const ENV = { PEER_BOT_TOKEN: TOKEN };

const peer = (over: Record<string, unknown> = {}) => ({
  peerBotId: "555000111", chatId: null, allowFrom: ["555000111", "42"],
  opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10,
  maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "goomal_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" },
  ...over,
});
const base = (over: Record<string, unknown> = {}) => ({
  operatorBotId: "9876543210", operatorChatId: 4242, bridgeRoot: "/tmp/bridge", himmelRoot: "/tmp/himmel",
  peers: { goomal: peer() }, maxTextChars: 4000, addressing: "command", ...over,
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
  expect(cfg.peers.goomal.peerBotId).toBe("555000111");
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
  expect(refusal(() => loadConfig(write(base({ peers: { "Goomal!": peer() } })), ENV)).code).toBe(78);
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
  expect(refusal(() => loadConfig(write(base({ peers: { goomal: peer({ opens: ["run"] }) } })), ENV)).code).toBe(78);
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
const withTheirs = (over: Record<string, unknown>) => base({ peers: { goomal: peer({ theirs: { ...peer().theirs, ...over } }) } });

test("station names and peer keys load; an older config without them still loads", () => {
  const old = loadConfig(write(base()), ENV);
  expect(old.self).toEqual({});
  expect(old.peers.goomal.theirs.keys).toEqual([]);
  expect(old.peers.goomal.theirs.stationName).toBeUndefined();

  const cfg = loadConfig(write(base({ self: { stationName: "yotam" }, peers: { goomal: peer({ theirs: { ...peer().theirs, stationName: "goomal", keys: [key(PUB_A), key(PUB_B)] } }) } })), ENV);
  expect(cfg.self.stationName).toBe("yotam");
  expect(cfg.peers.goomal.theirs.stationName).toBe("goomal");
  expect(cfg.peers.goomal.theirs.keys.map(k => k.pub)).toEqual([PUB_A, PUB_B]);
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

test("ids: the bot id is the token prefix, and the session id shape is closed", () => {
  expect(botIdFromToken(TOKEN)).toBe("1234567890");
  expect(botIdFromToken("nocolon")).toBe("");
  expect(SESSION_ID_RE.test("abc-123")).toBe(true);
  for (const bad of ["../x", "", "a/b", "a".repeat(65), "a b"]) expect(SESSION_ID_RE.test(bad)).toBe(false);
});
