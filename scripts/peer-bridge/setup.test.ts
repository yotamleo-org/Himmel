// Host-impact: these rows create, replace and delete the state and config dirs,
// and run `uninstall`. They run only in a test VM (PEER_BRIDGE_VM_TEST=1, set by
// the VM driver). Every row points HOME at a temp dir, but the lifecycle is the
// thing under test, so the host never runs them.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { drainSpool } from "./chain";
import { loadAllowlist, readPeersFile } from "./config";
import { configDir, peerDir, peersFile, stateDir } from "./ids";
import { SetupError, add, allowSuite, confirm, denySuite, keygenCmd, kill, remove, runner, stationName, trust, unkill, uninstall, untrust, type Deps } from "./setup";
import { NEXT_KEY, STATION_KEY, currentSigningKey, fingerprint, keyId, publicKeyOf } from "./sign";
import { TelegramError } from "./telegram";

const VM = process.env.PEER_BRIDGE_VM_TEST === "1";
if (!VM) console.log("SKIP setup.test.ts: host-impact, test VM only (I14)");
const t = VM ? test : test.skip;

const DIR = import.meta.dir;
const REPO = join(DIR, "..", "..");
const TOKEN = "1234567890:" + "A".repeat(35);
const OUR_ID = "1234567890";
const PEER_ID = "555000111";
const CHAT = -1001234567890;

let home: string, aux: string;
const saved: Record<string, string | undefined> = {};
const KEYS = ["HOME", "TELEGRAM_ACCESS_PATH", "BRIDGE_ROOT"];

beforeEach(() => {
  if (!VM) return;
  for (const k of KEYS) saved[k] = process.env[k];
  home = fs.mkdtempSync(join(tmpdir(), "peer-setup-home-"));
  aux = fs.mkdtempSync(join(tmpdir(), "peer-setup-aux-"));
  fs.writeFileSync(join(aux, "access.json"), JSON.stringify({ allowFrom: ["4242"] }));
  process.env.HOME = home;
  process.env.TELEGRAM_ACCESS_PATH = join(aux, "access.json");
  process.env.BRIDGE_ROOT = join(aux, "bridge");
});
afterEach(() => {
  if (!VM) return;
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  fs.rmSync(home, { recursive: true, force: true });
  fs.rmSync(aux, { recursive: true, force: true });
});

type Over = Partial<Deps> & { answers?: string[] };
function mk(over: Over = {}): { deps: Deps; lines: string[] } {
  const lines: string[] = [];
  const answers = [...(over.answers ?? ["9876543210"])];
  const deps: Deps = {
    env: { HOME: home, PATH: process.env.PATH },
    tty: true,
    ask: async () => answers.shift() ?? "yes",
    out: l => lines.push(l),
    gitCwd: REPO,
    loadToken: () => TOKEN,
    stopUnit: () => {},
    ...over,
  };
  return { deps, lines };
}
async function refused(p: Promise<unknown>): Promise<string> {
  try { await p; } catch (e) { expect(e).toBeInstanceOf(SetupError); return (e as Error).message; }
  throw new Error("expected a SetupError");
}
const listing = (root: string): string[] => {
  const out: string[] = [];
  const walk = (d: string) => { for (const n of fs.readdirSync(d)) { const p = join(d, n); out.push(relative(root, p)); if (fs.lstatSync(p).isDirectory()) walk(p); } };
  walk(root);
  // A bun child writes its own package cache under HOME; that is not the bridge's.
  return out.filter(p => p !== ".bun" && !p.startsWith(".bun/")).sort();
};
const addGoomal = (over: Over = {}) => { const m = mk(over); return add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, m.deps).then(() => m); };

const member = (id: string, over: Record<string, unknown> = {}) => ({
  status: "administrator", is_anonymous: false, user: { id: Number(id), is_bot: true, username: `bot${id}` },
  can_be_edited: false, can_manage_chat: true, can_delete_messages: false, can_restrict_members: false, can_promote_members: false,
  can_change_info: false, can_invite_users: false, can_pin_messages: false, ...over,
});
function stub(o: { chat?: unknown; chatErr?: Error; members?: Record<string, unknown> } = {}) {
  const members = o.members ?? { [OUR_ID]: member(OUR_ID), [PEER_ID]: member(PEER_ID) };
  return {
    makeTg: () => ({
      getChat: async () => { if (o.chatErr) throw o.chatErr; return o.chat ?? { id: CHAT, type: "supergroup", title: "Bridge" }; },
      getChatMember: async (_c: number, uid: number) => {
        const m = members[String(uid)];
        if (m instanceof Error) throw m;
        return m;
      },
    }) as any,
  };
}
const peersBytes = () => fs.readFileSync(peersFile());
const spoolFiles = () => fs.readdirSync(join(peerDir("goomal"), "spool")).filter(n => n.endsWith(".json"));

const PUB_X = Buffer.alloc(32, 7).toString("base64");
const CLI: [string, string[]][] = [
  ["add", ["goomal", "--peer-bot-id", PEER_ID]], ["confirm", ["goomal", String(CHAT)]], ["remove", ["goomal"]], ["uninstall", []], ["runner", []],
  ["station-name", ["yotam"]], ["keygen", []], ["keygen", ["--rotate"]], ["keygen", ["--activate"]],
  ["trust", ["goomal", "goomal", PUB_X]], ["untrust", ["goomal"]], ["untrust", ["goomal", "--key", "0123abcd"]],
  ["allow-suite", ["goomal", "ledger", "scripts/ci/test-suite-ledger.sh"]], ["deny-suite", ["goomal", "ledger"]], ["kill", ["goomal"]], ["unkill", ["goomal"]],
];
for (const [cmd, args] of CLI) {
  t(`${cmd} ${args.filter(a => a.startsWith("--")).join(" ")}: a set CLAUDE_CODE_SESSION_ID refuses and writes nothing`, () => {
    const r = spawnSync("bun", [join(DIR, "setup.ts"), cmd, ...args], { env: { ...process.env, HOME: home, CLAUDE_CODE_SESSION_ID: "abc-123" }, encoding: "utf8" });
    expect(r.status).toBe(3);
    expect(r.stderr).toContain("not from a Claude session");
    expect(listing(home)).toEqual([]);
  });
  t(`${cmd} ${args.filter(a => a.startsWith("--")).join(" ")}: a set CLAUDECODE refuses`, () => {
    const r = spawnSync("bun", [join(DIR, "setup.ts"), cmd, ...args], { env: { ...process.env, HOME: home, CLAUDECODE: "1" }, encoding: "utf8" });
    expect(r.status).toBe(3);
    expect(listing(home)).toEqual([]);
  });
  t(`${cmd} ${args.filter(a => a.startsWith("--")).join(" ")}: no TTY refuses`, () => {
    const env = { ...process.env, HOME: home };
    delete env.CLAUDECODE; delete env.CLAUDE_CODE_SESSION_ID;
    const r = spawnSync("bun", [join(DIR, "setup.ts"), cmd, ...args], { env, encoding: "utf8", input: "" });
    expect(r.status).toBe(3);
    expect(r.stderr).toContain("terminal");
    expect(listing(home)).toEqual([]);
  });
}
t("a bad command is a usage error", () => {
  const r = spawnSync("bun", [join(DIR, "setup.ts"), "frobnicate"], { env: { ...process.env, HOME: home }, encoding: "utf8" });
  expect(r.status).toBe(2);
});
t("the functions refuse a Claude env and a missing TTY", async () => {
  expect(await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, mk({ env: { HOME: home, CLAUDE_CODE_SESSION_ID: "x" } }).deps))).toContain("Claude session");
  expect(await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, mk({ tty: false }).deps))).toContain("terminal");
  expect(listing(home)).toEqual([]);
});

t("add refuses without jq and writes nothing", async () => {
  const empty = fs.mkdtempSync(join(aux, "nopath-"));
  const msg = await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, mk({ env: { HOME: home, PATH: empty } }).deps));
  expect(msg).toContain("jq");
  expect(listing(home)).toEqual([]);
});
t("add refuses a bad peer name, bot id and username", async () => {
  const { deps } = mk();
  expect(await refused(add("Bad Name", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, deps))).toContain("peer name");
  expect(await refused(add("goomal", { peerBotId: "12ab", peerUsername: "goomal_bot" }, deps))).toContain("numeric id");
  expect(await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "no way\n#x" }, deps))).toContain("username");
  expect(listing(home)).toEqual([]);
});
t("add refuses an access.json with no operator chat", async () => {
  fs.writeFileSync(join(aux, "access.json"), JSON.stringify({ allowFrom: [] }));
  expect(await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, mk().deps))).toContain("operator chat id");
  expect(listing(home)).toEqual([]);
});
t("add writes a numeric operatorChatId, himmelRoot, bridgeRoot, and 0600/0700 files", async () => {
  await addGoomal();
  const raw = JSON.parse(peersBytes().toString());
  expect(raw.operatorChatId).toBe(4242);
  expect(typeof raw.operatorChatId).toBe("number");
  expect(raw.operatorBotId).toBe("9876543210");
  expect(raw.bridgeRoot).toBe(join(aux, "bridge"));
  expect(raw.himmelRoot).toBe(fs.realpathSync(REPO));
  expect(raw.peers.goomal.chatId).toBeNull();
  expect(raw.peers.goomal.theirs.username).toBe("goomal_bot");
  expect(readPeersFile(peersFile()).peers.goomal.peerBotId).toBe(PEER_ID);
  const mode = (p: string) => fs.statSync(p).mode & 0o777;
  for (const d of [stateDir(), configDir(), peerDir("goomal"), join(peerDir("goomal"), "spool")]) expect(mode(d)).toBe(0o700);
  for (const f of [peersFile(), join(configDir(), "hmac.key"), ...["inbox", "outbox", "threads", "digests"].map(n => join(peerDir("goomal"), `${n}.jsonl`))]) expect(mode(f)).toBe(0o600);
  expect(fs.statSync(join(configDir(), "hmac.key")).size).toBeGreaterThan(0);
});
t("add run from a worktree records the primary checkout as himmelRoot", async () => {
  const repo = fs.mkdtempSync(join(aux, "repo-"));
  const env = { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" };
  const g = (...a: string[]) => expect(spawnSync("git", a, { cwd: repo, env, encoding: "utf8" }).status).toBe(0);
  g("init", "-q"); g("commit", "-q", "--allow-empty", "-m", "x");
  const wt = join(aux, "wt");
  g("worktree", "add", "-q", wt);
  await addGoomal({ gitCwd: wt });
  expect(JSON.parse(peersBytes().toString()).himmelRoot).toBe(fs.realpathSync(repo));
});
t("add refuses a peer that exists, and a second peer keeps the key and the operator fields", async () => {
  await addGoomal();
  const key = fs.readFileSync(join(configDir(), "hmac.key"));
  expect(await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, mk().deps))).toContain("already set up");
  await add("other", { peerBotId: "777000222", peerUsername: "other_bot" }, mk().deps);
  expect(fs.readFileSync(join(configDir(), "hmac.key")).equals(key)).toBe(true);
  expect(Object.keys(readPeersFile(peersFile()).peers).sort()).toEqual(["goomal", "other"]);
});
t("add with --operator-bot-id asks nothing", async () => {
  const asked: string[] = [];
  const m = mk({ ask: async q => { asked.push(q); return "yes"; } });
  await add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot", operatorBotId: "222" }, m.deps);
  expect(asked).toEqual([]);
  expect(JSON.parse(peersBytes().toString()).operatorBotId).toBe("222");
});
t("add refuses a non-digit --operator-bot-id and writes nothing", async () => {
  const msg = await refused(add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot", operatorBotId: "12a" }, mk().deps));
  expect(msg).toMatch(/--operator-bot-id must be/);
  expect(fs.existsSync(peersFile())).toBe(false);
});
t("add without the flag still prompts", async () => {
  const asked: string[] = [];
  const m = mk({ ask: async q => { asked.push(q); return "333"; } });
  await add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot" }, m.deps);
  expect(asked).toEqual(["The operator bot's numeric id: "]);
  expect(JSON.parse(peersBytes().toString()).operatorBotId).toBe("333");
});
t("add refuses an --operator-bot-id that differs from peers.json", async () => {
  await add("goomal", { peerBotId: PEER_ID, peerUsername: "goomal_bot", operatorBotId: "222" }, mk().deps);
  const before = peersBytes();
  const msg = await refused(add("other", { peerBotId: "777000222", peerUsername: "other_bot", operatorBotId: "999" }, mk().deps));
  expect(msg).toMatch(/differs from the operator bot id already in peers.json/);
  expect(peersBytes().equals(before)).toBe(true);
});

t("confirm accepts two admins with only can_manage_chat, writes the chat id and queues a confirm", async () => {
  await addGoomal();
  const { deps, lines } = mk(stub({ chat: { id: CHAT, type: "supergroup", title: "Team‮<<<x\u0007 room" } }));
  await confirm("goomal", String(CHAT), deps);
  expect(readPeersFile(peersFile()).peers.goomal.chatId).toBe(CHAT);
  expect(fs.statSync(peersFile()).mode & 0o777).toBe(0o600);
  const drained = drainSpool(peerDir("goomal"));
  expect(drained.length).toBe(1);
  expect((drained[0] as any).rec).toEqual({ type: "confirm", chatId: CHAT });
  const shown = lines.join("\n");
  expect(shown).toContain("room");
  expect(shown).not.toContain("‮");
  expect(shown).not.toContain("\u0007");
  expect(shown).not.toContain("<<<");
  expect(shown).not.toContain(TOKEN);
});
async function confirmRefused(s: ReturnType<typeof stub>, want: string, chat = String(CHAT)) {
  await addGoomal();
  const before = peersBytes();
  const msg = await refused(confirm("goomal", chat, mk(s).deps));
  expect(msg).toContain(want);
  expect(peersBytes().equals(before)).toBe(true);
  expect(spoolFiles()).toEqual([]);
}
t("confirm refuses a chat that is not a supergroup", () => confirmRefused(stub({ chat: { id: CHAT, type: "group", title: "x" } }), "not a supergroup"));
t("confirm refuses a migrated basic group and names the new id", () =>
  confirmRefused(stub({ chatErr: new TelegramError("Bad Request: group chat was upgraded to a supergroup chat", 400, { migrate_to_chat_id: -1009876543210 }) }), "-1009876543210"));
t("confirm refuses a chat without the peer bot", () =>
  confirmRefused(stub({ members: { [OUR_ID]: member(OUR_ID), [PEER_ID]: new TelegramError("Bad Request: user not found", 400) } }), "not in the chat"));
t("confirm refuses a malformed chat id", () => confirmRefused(stub(), "negative number", "12345"));
for (const status of ["member", "left", "creator", "restricted", "kicked"]) {
  for (const who of ["ours", "peer"]) {
    t(`confirm refuses ${who} as ${status}`, () => {
      const id = who === "ours" ? OUR_ID : PEER_ID;
      const members: Record<string, unknown> = { [OUR_ID]: member(OUR_ID), [PEER_ID]: member(PEER_ID) };
      members[id] = member(id, { status });
      return confirmRefused(stub({ members }), "not an administrator");
    });
  }
}
const RIGHTS = [
  "can_be_edited", "can_delete_messages", "can_manage_video_chats", "can_restrict_members", "can_promote_members", "can_change_info",
  "can_invite_users", "can_post_stories", "can_edit_stories", "can_delete_stories", "can_post_messages", "can_edit_messages",
  "can_pin_messages", "can_manage_topics", "can_manage_direct_messages", "can_manage_tags",
];
for (const right of [...RIGHTS, "can_x"]) {
  for (const who of ["ours", "peer"]) {
    t(`confirm refuses ${who} with ${right} true`, () => {
      const id = who === "ours" ? OUR_ID : PEER_ID;
      const members: Record<string, unknown> = { [OUR_ID]: member(OUR_ID), [PEER_ID]: member(PEER_ID) };
      members[id] = member(id, { [right]: true });
      return confirmRefused(stub({ members }), `has the right ${right}`);
    });
  }
}
for (const who of ["ours", "peer"]) {
  t(`confirm refuses ${who} as an anonymous admin`, () => {
    const id = who === "ours" ? OUR_ID : PEER_ID;
    const members: Record<string, unknown> = { [OUR_ID]: member(OUR_ID), [PEER_ID]: member(PEER_ID) };
    members[id] = member(id, { is_anonymous: true });
    return confirmRefused(stub({ members }), "anonymous");
  });
  t(`confirm refuses ${who} answered as a different user`, async () => {
    const id = who === "ours" ? OUR_ID : PEER_ID;
    const mkMembers = (m: unknown) => ({ [OUR_ID]: member(OUR_ID), [PEER_ID]: member(PEER_ID), [id]: m });
    await confirmRefused(stub({ members: mkMembers({ ...member(id), user: { id: 1, is_bot: true } }) }), "different user id");
  });
}
t("confirm refuses a human where the bot should be", () =>
  confirmRefused(stub({ members: { [OUR_ID]: member(OUR_ID), [PEER_ID]: { ...member(PEER_ID), user: { id: Number(PEER_ID), is_bot: false } } } }), "is not a bot"));
t("confirm refuses an unknown peer and a token equal to the operator's", async () => {
  await addGoomal();
  expect(await refused(confirm("nobody", String(CHAT), mk(stub()).deps))).toContain("unknown peer");
  expect(await refused(confirm("goomal", String(CHAT), mk({ ...stub(), loadToken: () => "9876543210:" + "B".repeat(35) }).deps))).toContain("operator bot's token");
});

const trustedKeys = () => readPeersFile(peersFile()).peers.goomal.theirs.keys;
const peerKeyFor = (cfgDir: string) => { const k = publicKeyOf(join(cfgDir, STATION_KEY)); return { pub: k, id: keyId(k), fp: fingerprint(k) }; };

t("keygen writes a 0600 key, prints pub, id and fingerprint, never the private key, and a second keygen refuses", async () => {
  const { deps, lines } = mk();
  await keygenCmd("new", deps);
  const path = join(configDir(), STATION_KEY);
  expect(fs.statSync(path).mode & 0o777).toBe(0o600);
  const shown = lines.join("\n");
  const k = peerKeyFor(configDir());
  expect(shown).toContain(k.pub);
  expect(shown).toContain(k.id);
  expect(shown).toContain(k.fp);
  expect(shown).not.toContain("PRIVATE KEY");
  expect(shown).not.toContain(fs.readFileSync(path, "utf8").split("\n")[1]);
  const before = fs.readFileSync(path);
  expect(await refused(keygenCmd("new", mk().deps))).toContain("already exists");
  expect(fs.readFileSync(path).equals(before)).toBe(true);
});

t("keygen --rotate keeps the old key signing and --activate switches and deletes the old file", async () => {
  await keygenCmd("new", mk().deps);
  const first = peerKeyFor(configDir());
  expect(await refused(keygenCmd("activate", mk().deps))).toContain("no next key");
  await keygenCmd("rotate", mk().deps);
  expect(currentSigningKey().id).toBe(first.id);
  await keygenCmd("activate", mk().deps);
  expect(currentSigningKey().id).not.toBe(first.id);
  expect(fs.existsSync(join(configDir(), NEXT_KEY))).toBe(false);
});

t("station-name refuses a name egress would refuse, and writes ours into self", async () => {
  await addGoomal();
  const host = "box-one.lan";
  for (const bad of ["box-one", "localhost", "x.local", "Has Space", ""]) {
    const before = peersBytes();
    await refused(stationName(bad, mk({ hostname: host }).deps));
    expect(peersBytes().equals(before)).toBe(true);
  }
  await refused(stationName("box", mk({ hostname: "box.lan" }).deps));
  await stationName("goomal", mk({ hostname: host }).deps);
  expect(readPeersFile(peersFile()).self.stationName).toBe("goomal");
  expect(fs.statSync(peersFile()).mode & 0o777).toBe(0o600);
});

t("trust: a mistyped fingerprint writes nothing, the right one writes the name and the key", async () => {
  await addGoomal();
  await keygenCmd("new", mk().deps);
  const k = peerKeyFor(configDir());
  const before = peersBytes();
  const wrong = k.fp.slice(0, -1) + (k.fp.endsWith("0") ? "1" : "0");
  const msg = await refused(trust("goomal", "goomal", k.pub, mk({ answers: [wrong] }).deps));
  expect(msg).toContain("does not match");
  expect(peersBytes().equals(before)).toBe(true);

  await trust("goomal", "goomal", k.pub, mk({ answers: [k.fp.toUpperCase().replace(/ /g, "")] }).deps);
  const theirs = readPeersFile(peersFile()).peers.goomal.theirs;
  expect(theirs.stationName).toBe("goomal");
  expect(theirs.keys.map(x => x.id)).toEqual([k.id]);
  expect(fs.statSync(peersFile()).mode & 0o777).toBe(0o600);
});

t("trust refuses a bad key, a bad name, an unknown peer, a repeat, a third key and a changed name", async () => {
  await addGoomal();
  const pubs = [1, 2, 3].map(n => Buffer.alloc(32, n).toString("base64"));
  const ok = (pub: string, name = "goomal") => trust("goomal", name, pub, mk({ hostname: "box.lan", answers: [fingerprint(pub)] }).deps);
  const before = peersBytes();
  expect(await refused(ok("c2hvcnQ="))).toContain("32 bytes");
  expect(await refused(ok(pubs[0], "box"))).toContain("refused by egress");
  expect(await refused(trust("nobody", "goomal", pubs[0], mk({ answers: [fingerprint(pubs[0])] }).deps))).toContain("unknown peer");
  expect(peersBytes().equals(before)).toBe(true);
  await ok(pubs[0]);
  expect(await refused(ok(pubs[0]))).toContain("already trusted");
  expect(await refused(ok(pubs[1], "someone-else"))).toContain("already trusted as goomal");
  await ok(pubs[1]);
  expect(trustedKeys().length).toBe(2);
  expect(await refused(ok(pubs[2]))).toContain("two keys");
});

t("untrust --key removes one key; untrust alone removes all", async () => {
  await addGoomal();
  const pubs = [1, 2].map(n => Buffer.alloc(32, n).toString("base64"));
  for (const p of pubs) await trust("goomal", "goomal", p, mk({ answers: [fingerprint(p)] }).deps);
  expect(await refused(untrust("goomal", "deadbeef", mk().deps))).toContain("no trusted key");
  expect(await refused(untrust("goomal", "XYZ", mk().deps))).toContain("8-hex");
  await untrust("goomal", keyId(pubs[0]), mk().deps);
  expect(trustedKeys().map(k => k.id)).toEqual([keyId(pubs[1])]);
  await untrust("goomal", undefined, mk().deps);
  expect(trustedKeys()).toEqual([]);
  expect(readPeersFile(peersFile()).peers.goomal.theirs.stationName).toBe("goomal");
});

t("the new functions refuse a Claude env and a missing TTY", async () => {
  for (const over of [{ env: { HOME: home, CLAUDECODE: "1" } }, { tty: false }]) {
    const deps = mk(over).deps;
    await refused(keygenCmd("new", deps));
    await refused(stationName("yotam", deps));
    await refused(trust("goomal", "goomal", PUB_X, deps));
    await refused(untrust("goomal", undefined, deps));
    await refused(allowSuite("goomal", "ledger", "scripts/ci/test-suite-ledger.sh", deps));
    await refused(denySuite("goomal", "ledger", deps));
    await refused(kill("goomal", deps));
    await refused(unkill("goomal", deps));
  }
  expect(listing(home)).toEqual([]);
});

const SUITES = () => join(configDir(), "goomal.suites");
const KILLED = () => join(configDir(), "goomal.killed");

t("allow-suite writes a 0600 allowlist the runner side can read, deny-suite takes an entry out", async () => {
  await addGoomal();
  await allowSuite("goomal", "ledger", "scripts/ci/test-suite-ledger.sh", mk().deps);
  await allowSuite("goomal", "peer-taint", "scripts/hooks/test-peer-taint.sh", mk().deps);
  expect(fs.statSync(SUITES()).mode & 0o777).toBe(0o600);
  expect(fs.readFileSync(SUITES(), "utf8")).toBe("ledger scripts/ci/test-suite-ledger.sh\npeer-taint scripts/hooks/test-peer-taint.sh\n");
  expect(loadAllowlist("goomal")).toEqual([{ alias: "ledger", path: "scripts/ci/test-suite-ledger.sh" }, { alias: "peer-taint", path: "scripts/hooks/test-peer-taint.sh" }]);
  await denySuite("goomal", "ledger", mk().deps);
  expect(loadAllowlist("goomal")).toEqual([{ alias: "peer-taint", path: "scripts/hooks/test-peer-taint.sh" }]);
  expect(await refused(denySuite("goomal", "ledger", mk().deps))).toContain("no allowed suite");
});

t("allow-suite refuses a malformed alias or path, a duplicate and an unknown peer, and writes nothing", async () => {
  await addGoomal();
  for (const [alias, path, want] of [
    ["Bad", "scripts/x.sh", "alias"], ["", "scripts/x.sh", "alias"], ["a".repeat(33), "scripts/x.sh", "alias"],
    ["ok", "scripts/../x.sh", "suite path"], ["ok", "/etc/passwd", "suite path"], ["ok", "scripts/X.sh", "suite path"], ["ok", "scripts/x.py", "suite path"],
  ] as const) expect(await refused(allowSuite("goomal", alias, path, mk().deps))).toContain(want);
  expect(fs.existsSync(SUITES())).toBe(false);
  await allowSuite("goomal", "ok", "scripts/x.sh", mk().deps);
  const before = fs.readFileSync(SUITES());
  expect(await refused(allowSuite("goomal", "ok", "scripts/y.sh", mk().deps))).toContain("already in use");
  expect(await refused(allowSuite("goomal", "other", "scripts/x.sh", mk().deps))).toContain("already allowed");
  expect(await refused(allowSuite("nobody", "ok", "scripts/x.sh", mk().deps))).toContain("unknown peer");
  expect(fs.readFileSync(SUITES()).equals(before)).toBe(true);
});

t("kill writes the kill file, unkill removes it, and each refuses when there is nothing to do", async () => {
  await addGoomal();
  expect(await refused(unkill("goomal", mk().deps))).toContain("not killed");
  await kill("goomal", mk().deps);
  expect(fs.statSync(KILLED()).mode & 0o777).toBe(0o600);
  expect(await refused(kill("goomal", mk().deps))).toContain("already killed");
  expect(await refused(kill("nobody", mk().deps))).toContain("unknown peer");
  await unkill("goomal", mk().deps);
  expect(fs.existsSync(KILLED())).toBe(false);
});

t("remove takes the peer's allowlist and kill file with it", async () => {
  await addGoomal();
  await allowSuite("goomal", "ok", "scripts/x.sh", mk().deps);
  await kill("goomal", mk().deps);
  await remove("goomal", mk({ answers: ["yes"] }).deps);
  expect(fs.existsSync(SUITES())).toBe(false);
  expect(fs.existsSync(KILLED())).toBe(false);
});

t("add, remove and uninstall leave only the declared paths, then nothing", async () => {
  const unitDir = join(home, ".config", "systemd", "user");
  fs.mkdirSync(unitDir, { recursive: true });
  const before = listing(home);
  const declaredAfterAdd = [
    ".himmel", ".himmel/peer-bridge", ".himmel/peer-bridge/goomal", ".himmel/peer-bridge/goomal/spool",
    ...["inbox", "outbox", "threads", "digests"].map(n => `.himmel/peer-bridge/goomal/${n}.jsonl`),
    ".config/himmel", ".config/himmel/peer-bridge", ".config/himmel/peer-bridge/hmac.key", ".config/himmel/peer-bridge/peers.json",
  ];
  await addGoomal();
  expect(listing(home).filter(p => !before.includes(p))).toEqual([...declaredAfterAdd].sort());

  fs.writeFileSync(join(unitDir, "himmel-peer-bridge.service"), "[Service]\n");
  fs.mkdirSync(join(stateDir(), "desk", "goomal"), { recursive: true });
  await remove("goomal", mk({ answers: ["yes"] }).deps);
  expect(fs.existsSync(peerDir("goomal"))).toBe(false);
  expect(fs.existsSync(join(stateDir(), "desk", "goomal"))).toBe(false);
  expect(Object.keys(readPeersFile(peersFile()).peers)).toEqual([]);

  let stopped = 0;
  await uninstall(mk({ answers: ["yes"], stopUnit: () => { stopped++; } }).deps);
  expect(stopped).toBe(1);
  expect(listing(home)).toEqual(before);
});
const RUNNER_PATH = () => process.platform === "darwin"
  ? join(home, "Library", "LaunchAgents", "com.himmel.peer-runner.plist")
  : join(home, ".config", "systemd", "user", "himmel-peer-runner.service");
const setServes = (peer: string, serves: string[]) => {
  const raw = JSON.parse(fs.readFileSync(peersFile(), "utf8"));
  raw.peers[peer].serves = serves;
  fs.writeFileSync(peersFile(), JSON.stringify(raw, null, 2) + "\n", { mode: 0o600 });
};
t("runner: serves [] installs no unit; serves run-suite installs the OS unit; removing the peer removes it", async () => {
  const calls: string[] = [];
  const ctl = { runnerCtl: (verb: "start" | "stop", p: string) => { calls.push(`${verb} ${p}`); } };
  await addGoomal();
  await runner(mk(ctl).deps);
  expect(fs.existsSync(RUNNER_PATH())).toBe(false);
  expect(calls).toEqual([]);

  setServes("goomal", ["run-suite"]);
  await runner(mk(ctl).deps);
  const unit = fs.readFileSync(RUNNER_PATH(), "utf8");
  expect(unit).toContain(`${REPO}/scripts/peer-bridge/runner.ts`);
  expect(unit).not.toContain("@HIMMEL_ROOT@");
  expect(unit).not.toContain("@HOME@");
  expect(fs.statSync(RUNNER_PATH()).mode & 0o777).toBe(0o644);
  expect(calls).toEqual([`start ${RUNNER_PATH()}`]);

  await runner(mk(ctl).deps);
  expect(calls.length).toBe(1);

  await remove("goomal", mk({ answers: ["yes"], ...ctl }).deps);
  expect(fs.existsSync(RUNNER_PATH())).toBe(false);
  expect(calls).toEqual([`start ${RUNNER_PATH()}`, `stop ${RUNNER_PATH()}`]);
});
t("runner: dropping run-suite from serves stops and removes the unit", async () => {
  const calls: string[] = [];
  const ctl = { runnerCtl: (verb: "start" | "stop", p: string) => { calls.push(`${verb} ${p}`); } };
  await addGoomal();
  setServes("goomal", ["run-suite"]);
  await runner(mk(ctl).deps);
  setServes("goomal", []);
  await runner(mk(ctl).deps);
  expect(fs.existsSync(RUNNER_PATH())).toBe(false);
  expect(calls).toEqual([`start ${RUNNER_PATH()}`, `stop ${RUNNER_PATH()}`]);
});
t("remove and uninstall need a typed yes", async () => {
  await addGoomal();
  expect(await refused(remove("goomal", mk({ answers: ["no"] }).deps))).toContain("not removed");
  expect(fs.existsSync(peerDir("goomal"))).toBe(true);
  expect(await refused(remove("nobody", mk().deps))).toContain("unknown peer");
  expect(await refused(uninstall(mk({ answers: [""] }).deps))).toContain("not uninstalled");
  expect(fs.existsSync(stateDir())).toBe(true);
});

const sources = () => fs.readdirSync(DIR).filter(n => /\.(ts|sh)$/.test(n) && n !== "setup.test.ts");
t("no sudo under scripts/peer-bridge", () => {
  const files = [...sources(), ...fs.readdirSync(join(DIR, "units")).map(n => join("units", n))];
  for (const f of files) expect([f, /\bsudo\b/.test(fs.readFileSync(join(DIR, f), "utf8"))]).toEqual([f, false]);
});
t("no inbound module imports setup.ts", () => {
  for (const f of sources().filter(n => n !== "setup.ts")) {
    expect([f, /(from|import\()\s*["']\.\/setup(\.ts)?["']|require\(["']\.\/setup/.test(fs.readFileSync(join(DIR, f), "utf8"))]).toEqual([f, false]);
  }
});
t("the systemd unit carries RestartPreventExitStatus=78", () => {
  expect(fs.readFileSync(join(DIR, "units", "himmel-peer-bridge.service"), "utf8")).toMatch(/^RestartPreventExitStatus=78$/m);
});
function runSh(rc: string, withEnv: boolean) {
  const stub = join(aux, "bun-stub");
  fs.writeFileSync(stub, '#!/usr/bin/env bash\n[ -n "$PEER_BOT_TOKEN" ] || exit 9\nexit "${STUB_RC:-0}"\n', { mode: 0o755 });
  fs.rmSync(join(configDir(), "env"), { force: true });
  if (withEnv) {
    fs.mkdirSync(configDir(), { recursive: true });
    fs.writeFileSync(join(configDir(), "env"), `PEER_BOT_TOKEN=${TOKEN}\n`, { mode: 0o600 });
  }
  return spawnSync("bash", [join(DIR, "run.sh")], { env: { PATH: process.env.PATH, HOME: home, PEER_BRIDGE_BUN: stub, STUB_RC: rc }, encoding: "utf8" });
}
t("run.sh maps 78 to 0, loads the env file, and passes other codes through", () => {
  expect(runSh("78", true).status).toBe(0);
  expect(runSh("0", true).status).toBe(0);
  expect(runSh("3", true).status).toBe(3);
  expect(runSh("0", false).status).toBe(9);
});
t("test-peer-units.sh passes", () => {
  const r = spawnSync("bash", [join(DIR, "test-peer-units.sh")], { encoding: "utf8" });
  expect([r.status, r.stdout]).toEqual([0, r.stdout]);
});
