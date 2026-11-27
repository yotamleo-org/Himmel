// Host-safe rows for setup.ts and the peers.json lock: HOME is a temp dir, every
// host-impact seam is stubbed, and uninstall and runner are never called.
import { afterEach, beforeEach, expect, test } from "bun:test";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { drainSpool, startIdentity, writeResult } from "./chain";
import { cardMessage, readPeersFile } from "./config";
import { configDir, peerDir, peersFile, stateDir } from "./ids";
import { SetupError, add, confirm, dm, keygenCmd, pair, remove, stationName, trust, untrust, type Deps } from "./setup";
import { STATION_KEY, fingerprint, keyId, publicKeyOf } from "./sign";

const DIR = import.meta.dir;
const REPO = join(DIR, "..", "..");
const TOKEN = "1234567890:" + "A".repeat(35);
const OUR_ID = "1234567890", PEER_ID = "555000111", CHAT = -1001234567890;
const PUB_X = Buffer.alloc(32, 1).toString("base64"), PUB_Y = Buffer.alloc(32, 2).toString("base64");
const CHANGED = "peers.json changed while you were at the prompt; run it again";

let home: string, aux: string;
const saved: Record<string, string | undefined> = {};
const KEYS = ["HOME", "BRIDGE_ROOT"];
const children: { kill(): void }[] = [];
beforeEach(() => {
  for (const k of KEYS) saved[k] = process.env[k];
  home = fs.mkdtempSync(join(tmpdir(), "peer-lock-home-"));
  aux = fs.mkdtempSync(join(tmpdir(), "peer-lock-aux-"));
  process.env.HOME = home;
  process.env.BRIDGE_ROOT = join(aux, "bridge");
});
afterEach(() => {
  for (const c of children.splice(0)) c.kill();
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  fs.rmSync(home, { recursive: true, force: true });
  fs.rmSync(aux, { recursive: true, force: true });
});

const member = (id: string) => ({ status: "administrator", is_anonymous: false, user: { id: Number(id), is_bot: true, username: "bot" + id }, can_manage_chat: true });
const tg = (chat: unknown = { type: "supergroup", title: "bridge" }) => ({
  getChat: async () => chat as any,
  getChatMember: async (_c: number, id: number) => member(String(id)) as any,
});

type Over = Partial<Deps> & { answers?: string[] };
function mk(over: Over = {}): { deps: Deps; lines: string[] } {
  const lines: string[] = [];
  const answers = [...(over.answers ?? ["9876543210"])];
  let t = 0;
  const deps: Deps = {
    env: { PATH: process.env.PATH },
    tty: true,
    ask: async () => answers.shift() ?? "yes",
    out: l => lines.push(l),
    gitCwd: REPO,
    access: { allowFrom: ["4242"] } as any,
    loadToken: () => TOKEN,
    makeTg: () => tg(),
    runnerCtl: () => true,
    stopUnit: () => {},
    hostname: "box.lan",
    cardWait: { timeoutMs: 0, sleep: async () => {}, now: () => t++ },
    ...over,
  };
  return { deps, lines };
}
async function refused(p: Promise<unknown>): Promise<string> {
  try { await p; } catch (e) { expect(e).toBeInstanceOf(SetupError); return (e as Error).message; }
  throw new Error("expected a SetupError");
}
const addExample = () => add("example", { peerBotId: PEER_ID, peerUsername: "example_bot" }, mk().deps);
const doc = () => JSON.parse(fs.readFileSync(peersFile(), "utf8"));
const bytes = () => fs.readFileSync(peersFile());
const rewrite = (mutate: (d: any) => void) => { const d = doc(); mutate(d); fs.writeFileSync(peersFile(), JSON.stringify(d, null, 2) + "\n"); };
let bumps = 4000;
const bump = () => rewrite(d => { d.maxTextChars = --bumps; });
const pairingRow = () => JSON.parse(fs.readFileSync(join(home, ".himmel", "remote-setup", "pairing.json"), "utf8")).peers.find((p: any) => p.name === "example");
const agrees = () => {
  const raw = doc(), p = raw.peers.example;
  expect(pairingRow()).toEqual({
    name: "example", ourStationName: typeof raw.self?.stationName === "string", ourStationKey: fs.existsSync(join(configDir(), STATION_KEY)),
    groupChat: typeof p.chatId === "number", operatorChat: typeof raw.operatorDmChatId === "number", theirKey: (p.theirs.keys ?? []).length > 0,
  });
};
function liveLock() {
  const c = Bun.spawn(["cat"], { stdin: "pipe", stdout: "ignore" });
  children.push(c);
  fs.writeFileSync(join(configDir(), "peers.json.lock"), JSON.stringify({ pid: c.pid, start: startIdentity(c.pid) }), { mode: 0o600 });
}
const unlock = () => fs.rmSync(join(configDir(), "peers.json.lock"), { force: true });

const VERBS: [string, (d: Over) => Promise<unknown>, (() => Promise<unknown>)?][] = [
  ["add of a second peer", o => add("second", { peerBotId: "555000222", peerUsername: "second_bot" }, mk(o).deps)],
  ["confirm", o => confirm("example", String(CHAT), mk(o).deps)],
  ["dm", o => dm(mk({ makeTg: () => tg({ type: "private", id: 4242 }), ...o }).deps)],
  ["remove", o => remove("example", mk({ answers: ["yes"], ...o }).deps)],
  ["station-name", o => stationName("yotam", mk(o).deps)],
  ["pair's station-name step", o => pair("example", "yotam", undefined, mk(o).deps)],
  ["untrust", o => untrust("example", undefined, mk(o).deps), () => trust("example", "example", PUB_X, mk({ answers: [fingerprint(PUB_X)] }).deps)],
];
for (const [verb, run, setup] of VERBS) {
  test(`${verb}: a peers.json changed while you were at the prompt refuses and keeps the other write`, async () => {
    await addExample();
    await setup?.();
    let last = Buffer.alloc(0);
    const msg = await refused(run({ afterLoad: () => { bump(); last = bytes(); } }));
    expect(msg).toBe(CHANGED);
    expect(bytes().equals(last)).toBe(true);
    expect(fs.existsSync(peerDir("second"))).toBe(false);
    expect(fs.existsSync(peerDir("example"))).toBe(true);
    expect(fs.existsSync(join(configDir(), "peers.json.lock"))).toBe(false);
  });
}

test("add of a second peer succeeds under the real lock, and pairing.json follows", async () => {
  await addExample();
  await add("second", { peerBotId: "555000222", peerUsername: "second_bot" }, mk().deps);
  expect(Object.keys(readPeersFile(peersFile()).peers).sort()).toEqual(["example", "second"]);
  agrees();
  expect(fs.readdirSync(configDir()).filter(n => n.includes("lock") || n.endsWith(".tmp"))).toEqual([]);
});

test("trust: an unrelated edit during the typed prompt is kept and the key is still trusted", async () => {
  await addExample();
  await trust("example", "example", PUB_X, mk({ ask: async () => { bump(); return fingerprint(PUB_X); } }).deps);
  expect(readPeersFile(peersFile()).peers.example.theirs.keys.map(k => k.pub)).toEqual([PUB_X]);
  expect(doc().maxTextChars).toBe(bumps);
});

test("trust: the same key added during the prompt refuses already trusted and writes nothing", async () => {
  await addExample();
  let after = Buffer.alloc(0);
  const msg = await refused(trust("example", "example", PUB_X, mk({ ask: async () => {
    rewrite(d => { d.peers.example.theirs.keys = [{ id: keyId(PUB_X), pub: PUB_X, addedAt: "2026-11-27T00:00:00Z" }]; });
    after = bytes();
    return fingerprint(PUB_X);
  } }).deps));
  expect(msg).toContain("already trusted");
  expect(bytes().equals(after)).toBe(true);
});

const ourPub = () => publicKeyOf(join(configDir(), STATION_KEY));

function poller(answer: { ok: true } | { ok: false; rule: string } | null) {
  const seen: unknown[] = [];
  let t = 0;
  return { seen, wait: { timeoutMs: 1000, now: () => t, sleep: async () => {
    const drained = drainSpool(peerDir("example"));
    for (const d of drained) { seen.push("rec" in d ? d.rec : d); if (answer) writeResult(peerDir("example"), d.name, answer); }
    t += answer ? 100 : 2000;
  } } };
}

test("pair submits one card record after printing our card, and prints the poller's answer", async () => {
  await addExample();
  for (const [answer, want] of [
    [{ ok: true }, "queued; it appears in the group within a minute"],
    [{ ok: false, rule: "card-daily" }, "asked 3 times today for this key"],
    [{ ok: false, rule: "not-set-up" }, "not-set-up"],
    [null, "the poller did not answer; is it running?"],
  ] as const) {
    fs.rmSync(join(peerDir("example"), "spool"), { recursive: true, force: true });
    fs.mkdirSync(join(peerDir("example"), "spool"), { mode: 0o700 });
    const p = poller(answer as any);
    const { deps, lines } = mk({ cardWait: p.wait });
    await pair("example", "yotam", undefined, deps);
    expect(p.seen).toEqual([{ type: "card" }]);
    const text = lines.join("\n");
    expect(text).toContain(want);
    expect(text).toContain("fingerprint: " + fingerprint(ourPub()));
    expect(text).toContain("#pair station=yotam key=" + ourPub());
    expect(text).toContain("if the tap does not reach them, give this line to example's operator for their `setup.ts pair <peer> --card`");
  }
});

test("pair --card submits the card record before the typed step: a wrong fingerprint still submitted it and trusted nothing", async () => {
  await addExample();
  const p = poller({ ok: true });
  const msg = await refused(pair("example", "yotam", `#pair station=example key=${PUB_X}`, mk({ cardWait: p.wait, answers: ["0000"] }).deps));
  expect(msg).toContain("does not match");
  expect(p.seen).toEqual([{ type: "card" }]);
  expect(readPeersFile(peersFile()).peers.example.theirs.keys).toEqual([]);
});

test("pair --card takes the two-line Telegram copy, and a terminal trust of a second key still works", async () => {
  await addExample();
  await pair("example", "yotam", cardMessage("ours_bot", "example", PUB_X) + "\n", mk({ answers: [fingerprint(PUB_X)] }).deps);
  await trust("example", "example", PUB_Y, mk({ answers: [fingerprint(PUB_Y)] }).deps);
  expect(readPeersFile(peersFile()).peers.example.theirs.keys.map(k => k.pub)).toEqual([PUB_X, PUB_Y]);
});

test("competing first adds leave one peers.json, and the loser creates no peer dir, chain files or hmac.key of its own", async () => {
  fs.mkdirSync(configDir(), { recursive: true, mode: 0o700 });
  liveLock();
  let ran = false;
  const loser = mk({ lockClock: { now: () => Date.now(), sleep: async () => {
    if (ran) return;
    ran = true;
    unlock();
    await addExample();
  } } });
  expect(await refused(add("second", { peerBotId: "555000222", peerUsername: "second_bot" }, loser.deps))).toBe(CHANGED);
  expect(Object.keys(readPeersFile(peersFile()).peers)).toEqual(["example"]);
  expect(fs.existsSync(peerDir("second"))).toBe(false);
  expect(fs.readdirSync(stateDir())).toEqual(["example"]);
  agrees();
});

test("first add, pair run twice and keygen under contention each leave a pairing.json that agrees with peers.json", async () => {
  await addExample();
  agrees();
  await pair("example", "yotam", undefined, mk().deps);
  agrees();
  await pair("example", undefined, undefined, mk().deps);
  agrees();
  fs.rmSync(join(configDir(), STATION_KEY));
  liveLock();
  let ran = false;
  await keygenCmd("new", mk({ lockClock: { now: () => Date.now(), sleep: async () => {
    if (ran) return;
    ran = true;
    rewrite(d => { d.operatorDmChatId = 4242; });
    unlock();
  } } }).deps);
  expect(ran).toBe(true);
  expect(pairingRow().operatorChat).toBe(true);
  agrees();
});
