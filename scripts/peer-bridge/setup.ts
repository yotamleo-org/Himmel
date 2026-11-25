// setup.ts add|confirm|remove|uninstall: host lifecycle for the peer bridge. It
// runs only from the station's own operator at a terminal. No inbound module
// imports it, and nothing a peer sends can reach it.
//
//   setup.ts add <peer> --peer-bot-id N [--operator-bot-id N] [--peer-username U]
//   setup.ts confirm <peer> <chatId>
//   setup.ts remove <peer>
//   setup.ts uninstall
//   setup.ts runner          install the runner unit while a peer serves run-suite, remove it otherwise
//   setup.ts dm              record the operator's own chat with the peer bridge bot
//   setup.ts station-name <name>
//   setup.ts keygen [--rotate | --activate | --show]
//   setup.ts pair <peer> [<station-name>] [--card '<their card>']
//   setup.ts trust <peer> <station-name> <pubkey-b64>
//   setup.ts untrust <peer> [--key <id>]
//   setup.ts allow-suite <peer> <alias> <path> | deny-suite <peer> <alias>
//   setup.ts kill <peer> | unkill <peer>
//
// Exit: 0 done, 2 usage, 3 refused (nothing written).
import { randomBytes } from "node:crypto";
import fs, { constants } from "node:fs";
import { homedir, hostname as osHostname } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { defaultRoot } from "../telegram/bus";
import { loadAccess, operatorChatId, type Access } from "../telegram/gate";
import { submitSpool } from "./chain";
import { ALIAS_RE, ConfigError, PAIR_CARD_RE, loadAllowlist, pairCard, readPeersFile, type AllowEntry } from "./config";
import { badHost } from "./egress";
import { STATION_NAME_RE, SUITE_PATH_RE } from "./envelope";
import { BOT_ID_RE, PEER_NAME_RE, TOKEN_RE, botIdFromToken, configDir, peerDir, peersFile, stateDir } from "./ids";
import { sanitize } from "./sanitize";
import { currentSigningKey, fingerprint, keyId, keygen, keygenActivate, keygenRotate, publicKeyOf, type KeyInfo } from "./sign";
import { PeerTelegram, TelegramError } from "./telegram";

export class SetupError extends Error {
  constructor(message: string) { super(message); this.name = "SetupError"; }
}

export type Deps = {
  env: NodeJS.ProcessEnv;
  tty: boolean;
  ask: (question: string) => Promise<string>;
  out: (line: string) => void;
  gitCwd?: string;
  access?: Access;
  loadToken?: () => string;
  makeTg?: (token: string) => Pick<PeerTelegram, "getChat" | "getChatMember">;
  stopUnit?: () => void;
  runnerCtl?: (verb: "start" | "stop", path: string) => boolean;
  hostname?: string;
};

const USERNAME_RE = /^[A-Za-z][A-Za-z0-9_]{2,31}$/;
const CHAIN_FILES = ["inbox.jsonl", "outbox.jsonl", "threads.jsonl", "digests.jsonl"];
const UNIT_NAME = "himmel-peer-bridge.service";
const PLIST_NAME = "com.himmel.peer-bridge.plist";
const RUNNER_UNIT = "himmel-peer-runner.service";
const RUNNER_PLIST = "com.himmel.peer-runner.plist";
const UNIT_PATH_RE = /^\/[A-Za-z0-9._\/-]+$/;

function refuse(message: string): never { throw new SetupError(message); }

function guard(deps: Deps): void {
  if (deps.env.CLAUDECODE || deps.env.CLAUDE_CODE_SESSION_ID) refuse("run this yourself in a terminal, not from a Claude session");
  if (!deps.tty) refuse("needs a human at a terminal");
}

function homeDir(): string {
  const h = process.env.HOME || homedir();
  if (!isAbsolute(h) || h === "/") refuse("HOME is not a usable directory");
  return h;
}

function unitPaths(): string[] {
  const h = homeDir();
  return [
    join(h, ".config", "systemd", "user", UNIT_NAME), join(h, "Library", "LaunchAgents", PLIST_NAME),
    join(h, ".config", "systemd", "user", RUNNER_UNIT), join(h, "Library", "LaunchAgents", RUNNER_PLIST),
  ];
}

function runnerUnitPath(): string | null {
  const h = homeDir();
  if (process.platform === "linux") return join(h, ".config", "systemd", "user", RUNNER_UNIT);
  if (process.platform === "darwin") return join(h, "Library", "LaunchAgents", RUNNER_PLIST);
  return null;
}

function runnerCtlDefault(verb: "start" | "stop", path: string): boolean {
  const opts = { stdio: "ignore" as const, timeout: 15_000 };
  if (process.platform === "linux") {
    if (spawnSync("systemctl", ["--user", "daemon-reload"], opts).status !== 0) return false; // t13b-ok: systemctl daemon-reload re-reads unit files and starts nothing
    return spawnSync("systemctl", ["--user", verb === "start" ? "enable" : "disable", "--now", RUNNER_UNIT], opts).status === 0;
  }
  const st = spawnSync("launchctl", [verb === "start" ? "bootstrap" : "bootout", `gui/${process.getuid!()}`, path], opts).status;
  return st === 0 || (verb === "stop" && st === 3);
}

function syncRunner(raw: any, deps: Deps): void {
  const serving = Object.values(raw.peers ?? {}).some((p: any) => Array.isArray(p?.serves) && p.serves.includes("run-suite"));
  const path = runnerUnitPath();
  if (path === null) {
    if (serving) refuse(`no runner unit for ${process.platform}`);
    return;
  }
  const ctl = deps.runnerCtl ?? runnerCtlDefault;
  if (serving && !fs.existsSync(path)) {
    const h = homeDir();
    if (!UNIT_PATH_RE.test(raw.himmelRoot) || !UNIT_PATH_RE.test(h)) refuse("himmelRoot and HOME must be plain absolute paths to go into a unit file");
    const text = fs.readFileSync(join(import.meta.dir, "units", basename(path)), "utf8").replaceAll("@HIMMEL_ROOT@", raw.himmelRoot).replaceAll("@HOME@", h);
    fs.mkdirSync(dirname(path), { recursive: true });
    writeNew(path, text, 0o644);
    if (!ctl("start", path)) {
      fs.rmSync(path, { force: true });
      refuse(`could not start the runner unit ${path}; it was removed, run setup.ts runner again`);
    }
    deps.out(`installed and started the runner unit ${path}`);
  } else if (!serving && fs.existsSync(path)) {
    if (!ctl("stop", path)) refuse(`could not stop the runner unit ${path}; it stays installed, run setup.ts runner again`);
    fs.rmSync(path, { force: true });
    deps.out(`no peer serves run-suite; stopped and removed the runner unit ${path}`);
  }
}

export async function runner(deps: Deps): Promise<void> {
  guard(deps);
  const raw = loadRaw();
  const path = runnerUnitPath();
  const before = path !== null && fs.existsSync(path);
  syncRunner(raw, deps);
  if (path !== null && fs.existsSync(path) === before) deps.out(`the runner unit is ${before ? "installed" : "not installed"}, as serves asks`);
}

function writeNew(path: string, data: string | Buffer, mode: number): void {
  const fd = fs.openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, mode);
  try { fs.writeFileSync(fd, data); } finally { fs.closeSync(fd); }
}

function mkdir0700(path: string): void {
  fs.mkdirSync(path, { recursive: true, mode: 0o700 });
  fs.chmodSync(path, 0o700);
}

function replaceJson(path: string, value: unknown): void {
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  writeNew(tmp, JSON.stringify(value, null, 2) + "\n", 0o600);
  try { fs.renameSync(tmp, path); } catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
}

function loadRaw(): any {
  try { readPeersFile(peersFile()); } catch (e) {
    if (e instanceof ConfigError) refuse(`peers.json: ${e.message}`);
    throw e;
  }
  return JSON.parse(fs.readFileSync(peersFile(), "utf8"));
}

function hasJq(env: NodeJS.ProcessEnv): boolean {
  return spawnSync("jq", ["--version"], { env, stdio: "ignore" }).status === 0;
}

export function primaryCheckout(cwd: string): string {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, encoding: "utf8" });
  const common = (r.stdout ?? "").trim();
  if (r.status !== 0 || !isAbsolute(common)) refuse("cannot find the primary himmel checkout (git rev-parse failed)");
  return dirname(common);
}

type AddOpts = { peerBotId?: string; peerUsername?: string; operatorBotId?: string };

export async function add(peer: string, opts: AddOpts, deps: Deps): Promise<void> {
  guard(deps);
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  if (!opts.peerBotId || !BOT_ID_RE.test(opts.peerBotId)) refuse("--peer-bot-id must be the peer bot's numeric id");
  if (opts.operatorBotId !== undefined && !BOT_ID_RE.test(opts.operatorBotId)) refuse("--operator-bot-id must be the operator bot's numeric id");
  if (!hasJq(deps.env)) refuse("jq is required (desk.sh reads peers.json with it)");

  const existing = fs.existsSync(peersFile()) ? loadRaw() : null;
  if (existing?.peers?.[peer]) refuse(`peer ${peer} is already set up; remove it first`);
  if (existing && opts.operatorBotId !== undefined && opts.operatorBotId !== existing.operatorBotId) refuse("--operator-bot-id differs from the operator bot id already in peers.json");

  let operatorBotId: string, chatId: number | null, bridgeRoot: string, himmelRoot: string;
  if (existing) {
    ({ operatorBotId, operatorChatId: chatId, bridgeRoot, himmelRoot } = existing);
  } else {
    operatorBotId = opts.operatorBotId ?? (await deps.ask("The operator bot's numeric id: ")).trim();
    if (!BOT_ID_RE.test(operatorBotId)) refuse("the operator bot id must be digits");
    chatId = operatorChatId(deps.access ?? await loadAccess());
    if (chatId === null) refuse("no operator chat id: the operator bot's access.json has no usable allowFrom entry");
    bridgeRoot = defaultRoot();
    himmelRoot = primaryCheckout(deps.gitCwd ?? import.meta.dir);
  }
  const username = (opts.peerUsername ?? (await deps.ask("The peer bot's username: "))).trim().replace(/^@/, "");
  if (!USERNAME_RE.test(username)) refuse("the peer bot's username is not a Telegram username");

  const S = stateDir(), C = configDir(), dir = peerDir(peer);
  mkdir0700(S);
  mkdir0700(C);
  mkdir0700(dir);
  mkdir0700(join(dir, "spool"));
  for (const f of CHAIN_FILES) writeNew(join(dir, f), "", 0o600);
  if (!fs.existsSync(join(C, "hmac.key"))) writeNew(join(C, "hmac.key"), randomBytes(32).toString("hex"), 0o600);

  const caps = { opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10 };
  const entry = {
    peerBotId: opts.peerBotId, chatId: null, allowFrom: [opts.peerBotId], ...caps,
    maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
    theirs: { username, ...caps, copiedAt: new Date().toISOString().slice(0, 10) },
  };
  const doc = existing ?? { operatorBotId, operatorChatId: chatId, bridgeRoot, himmelRoot, peers: {}, maxTextChars: 4000, addressing: "command" };
  doc.peers[peer] = entry;
  if (existing) replaceJson(peersFile(), doc); else writeNew(peersFile(), JSON.stringify(doc, null, 2) + "\n", 0o600);
  deps.out(`added ${peer}; next: put PEER_BOT_TOKEN=<token> in ${join(C, "env")} (mode 0600), then follow the setup steps in docs/internals/peer-bridge.md and run: setup.ts confirm ${peer} <chatId>`);
}

function readToken(): string {
  const path = join(configDir(), "env");
  let text: string;
  try {
    const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o600) refuse(`${path} must be a regular file owned by you, mode 0600`);
      text = fs.readFileSync(fd, "utf8");
    } finally { fs.closeSync(fd); }
  } catch (e) {
    if (e instanceof SetupError) throw e;
    return refuse(`cannot read ${path}`);
  }
  const m = /^PEER_BOT_TOKEN=["']?([^"'\n]+)["']?$/m.exec(text);
  if (!m || !TOKEN_RE.test(m[1])) refuse(`${path} holds no PEER_BOT_TOKEN in the bot-token shape`);
  return m[1];
}

// Every `can_` right must be off, except can_manage_chat, which Telegram implies
// for any admin. A right the list does not name counts the same.
export function adminProblem(m: any, queried: string): string | null {
  if (!m || m.status !== "administrator") return `is ${m?.status ?? "not in the chat"}, not an administrator`;
  if (m.is_anonymous !== false) return "is an anonymous administrator";
  if (String(m.user?.id) !== queried) return "answered for a different user id";
  if (m.user?.is_bot !== true) return "is not a bot";
  for (const [k, v] of Object.entries(m)) {
    if (k.startsWith("can_") && k !== "can_manage_chat" && v !== false && v !== undefined) return `has the right ${sanitize(k, 40)}`;
  }
  return null;
}

export async function confirm(peer: string, chatArg: string, deps: Deps): Promise<void> {
  guard(deps);
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  const raw = loadRaw();
  const p = raw.peers[peer];
  if (!p) refuse(`unknown peer ${peer}; run setup.ts add first`);
  if (!/^-[0-9]{1,15}$/.test(chatArg)) refuse("the chat id must be a negative number such as -1001234567890");
  const chatId = Number(chatArg);
  if (!Number.isSafeInteger(chatId)) refuse("the chat id is not a safe integer");
  if (!fs.existsSync(join(peerDir(peer), "spool"))) refuse(`no spool dir for ${peer}; run setup.ts add first`);

  const token = (deps.loadToken ?? readToken)();
  const ourId = botIdFromToken(token);
  if (ourId === raw.operatorBotId) refuse("the peer bot token is the operator bot's token");
  const tg = (deps.makeTg ?? (t => new PeerTelegram(t)))(token);

  let chat: any;
  try { chat = await tg.getChat(chatId); } catch (e) {
    const moved = e instanceof TelegramError ? e.parameters?.migrate_to_chat_id : undefined;
    if (moved !== undefined) refuse(`chat ${chatId} was migrated to a supergroup; use ${Number(moved)}`);
    refuse(`getChat failed: ${(e as Error).message}`);
  }
  if (chat?.type !== "supergroup") refuse(`chat ${chatId} is a ${sanitize(String(chat?.type), 20)}, not a supergroup`);

  for (const [who, id] of [["our bot", ourId], ["the peer bot", p.peerBotId]] as const) {
    let m: any;
    try { m = await tg.getChatMember(chatId, Number(id)); } catch (e) { refuse(`${who} (${id}) is not in the chat: ${(e as Error).message}`); }
    const problem = adminProblem(m, id);
    if (problem) refuse(`${who} (${id}) ${problem}; promote it to administrator with every right off first`);
  }

  deps.out(`chat: ${sanitize(String(chat.title ?? ""), 80)} (${chatId})`);
  p.chatId = chatId;
  replaceJson(peersFile(), raw);
  submitSpool(peerDir(peer), { type: "confirm", chatId });
  deps.out(`confirmed ${peer}; the poller picks it up on its next tick`);
}

export async function dm(deps: Deps): Promise<void> {
  guard(deps);
  const raw = loadRaw();
  const token = (deps.loadToken ?? readToken)();
  const tg = (deps.makeTg ?? (t => new PeerTelegram(t)))(token);
  await deps.ask("In Telegram, open a chat with the peer bridge bot and press Start, then press Enter here: ");
  let chat: any;
  try { chat = await tg.getChat(raw.operatorChatId); } catch (e) {
    refuse(`the peer bridge bot has no chat with you yet (${(e as Error).message}); press Start in its chat and run setup.ts dm again`);
  }
  if (chat?.type !== "private" || chat?.id !== raw.operatorChatId) refuse("that chat is not your private chat with the peer bridge bot");
  raw.operatorDmChatId = raw.operatorChatId;
  replaceJson(peersFile(), raw);
  deps.out("peer escalations, drafts and their buttons now arrive in your chat with the peer bridge bot; the running poller picks this up by itself");
}

export async function remove(peer: string, deps: Deps): Promise<void> {
  guard(deps);
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  const raw = loadRaw();
  if (!raw.peers[peer]) refuse(`unknown peer ${peer}`);
  if ((await deps.ask(`Remove ${peer} and its chain files? Type yes: `)).trim() !== "yes") refuse("not removed");
  delete raw.peers[peer];
  replaceJson(peersFile(), raw);
  fs.rmSync(peerDir(peer), { recursive: true, force: true });
  fs.rmSync(join(stateDir(), "desk", peer), { recursive: true, force: true });
  fs.rmSync(suitesFile(peer), { force: true });
  fs.rmSync(killedFile(peer), { force: true });
  syncRunner(raw, deps);
  deps.out(`removed ${peer}; restart the poller to drop it`);
}

function checkStationName(name: string, deps: Deps): void {
  if (!STATION_NAME_RE.test(name)) refuse("a station name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  if (badHost(name, deps.hostname ?? osHostname())) refuse(`the station name ${name} is refused by egress (it names this host or a private address)`);
}

export async function stationName(name: string, deps: Deps): Promise<void> {
  guard(deps);
  checkStationName(name, deps);
  const raw = loadRaw();
  raw.self = { ...(raw.self ?? {}), stationName: name };
  replaceJson(peersFile(), raw);
  deps.out(`our station name is ${name}`);
}

const showKey = (what: string, k: KeyInfo, deps: Deps) =>
  deps.out(`${what}\n  public key:  ${k.pub}\n  key id:      ${k.id}\n  fingerprint: ${k.fingerprint}\nGive the public key to the peer's operator; read the fingerprint to them by call or another messenger, never over the group.`);

function currentKey(): KeyInfo {
  const k = currentSigningKey();
  const pub = publicKeyOf(k.path);
  return { id: k.id, pub, fingerprint: fingerprint(pub) };
}

export async function keygenCmd(mode: "new" | "rotate" | "activate" | "show", deps: Deps): Promise<void> {
  guard(deps);
  mkdir0700(configDir());
  try {
    if (mode === "show") showKey("the station key (public part only)", currentKey(), deps);
    else if (mode === "new") showKey("created the station key", keygen(), deps);
    else if (mode === "rotate") showKey("created the next key; we keep signing with the current one until --activate", keygenRotate(), deps);
    else showKey("the next key is now the station key; the old key is deleted", keygenActivate(), deps);
  } catch (e) {
    refuse(`keygen: ${(e as NodeJS.ErrnoException).code === "EEXIST" ? "that key already exists" : (e as Error).message}`);
  }
}

export async function trust(peer: string, name: string, pub: string, deps: Deps): Promise<void> {
  guard(deps);
  await trustKey(peer, name, pub, deps);
}

async function trustKey(peer: string, name: string, pub: string, deps: Deps): Promise<void> {
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  checkStationName(name, deps);
  const raw = loadRaw();
  const p = raw.peers[peer];
  if (!p) refuse(`unknown peer ${peer}; run setup.ts add first`);
  const bytes = Buffer.from(pub, "base64");
  if (bytes.length !== 32 || bytes.toString("base64") !== pub) refuse("the public key must be 32 bytes in base64");
  const theirs = p.theirs;
  const keys: { id: string; pub: string; addedAt: string }[] = theirs.keys ?? [];
  const id = keyId(pub);
  if (keys.some(k => k.id === id)) refuse(`key ${id} is already trusted`);
  if (keys.length >= 2) refuse("two keys are already trusted; untrust one first");
  if (theirs.stationName !== undefined && theirs.stationName !== name) refuse(`${peer} is already trusted as ${theirs.stationName}; untrust it first to change the name`);
  deps.out(`fingerprint of this key: ${fingerprint(pub)}`);
  const typed = (await deps.ask("Type the fingerprint the peer's operator read to you out of band: ")).toLowerCase().replace(/\s+/g, "");
  if (typed !== fingerprint(pub).replace(/ /g, "")) refuse("the fingerprint does not match; nothing was written");
  theirs.stationName = name;
  theirs.keys = [...keys, { id, pub, addedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") }];
  replaceJson(peersFile(), raw);
  deps.out(`trusted ${peer} as ${name} with key ${id}; the running poller picks this up by itself`);
}

export async function pair(peer: string, name: string | undefined, card: string | undefined, deps: Deps): Promise<void> {
  guard(deps);
  knownPeer(peer);
  const raw = loadRaw();
  let station: string | undefined = raw.self?.stationName;
  if (station === undefined) {
    station = (name ?? (await deps.ask("Our station name (lowercase letters, digits and dashes): "))).trim();
    checkStationName(station, deps);
    raw.self = { ...(raw.self ?? {}), stationName: station };
    replaceJson(peersFile(), raw);
    deps.out(`our station name is ${station}`);
  } else if (name !== undefined && name !== station) refuse(`our station name is already ${station}`);
  mkdir0700(configDir());
  let k: KeyInfo;
  try { k = currentKey(); } catch { k = keygen(); deps.out("created the station key"); }
  deps.out(`pairing card: post this one line in the group you share with ${peer}:\n${pairCard(station, k.pub)}`);
  deps.out(`fingerprint: ${k.fingerprint}\nRead the fingerprint to the peer's operator by call or another messenger, never over the group.`);
  if (card === undefined) {
    deps.out(`next: when their card is in the group, run setup.ts pair ${peer} --card '<their card>'`);
    return;
  }
  const m = PAIR_CARD_RE.exec(card.trim());
  if (!m) refuse("their card must be one line: #pair station=<name> key=<public key>");
  await trustKey(peer, m[1], m[2], deps);
}

export async function untrust(peer: string, key: string | undefined, deps: Deps): Promise<void> {
  guard(deps);
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  const raw = loadRaw();
  const p = raw.peers[peer];
  if (!p) refuse(`unknown peer ${peer}`);
  const keys: { id: string }[] = p.theirs.keys ?? [];
  if (key !== undefined) {
    if (!/^[0-9a-f]{8}$/.test(key)) refuse("--key must be an 8-hex key id");
    if (!keys.some(k => k.id === key)) refuse(`${peer} has no trusted key ${key}`);
    p.theirs.keys = keys.filter(k => k.id !== key);
  } else {
    p.theirs.keys = [];
  }
  replaceJson(peersFile(), raw);
  deps.out(`${peer} now has ${p.theirs.keys.length} trusted key(s)`);
}

function replaceText(path: string, text: string): void {
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  writeNew(tmp, text, 0o600);
  try { fs.renameSync(tmp, path); } catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
}

function knownPeer(peer: string): void {
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  if (!loadRaw().peers[peer]) refuse(`unknown peer ${peer}`);
}

const suitesFile = (peer: string) => join(configDir(), `${peer}.suites`);
const killedFile = (peer: string) => join(configDir(), `${peer}.killed`);

function currentAllowlist(peer: string): AllowEntry[] {
  try { return loadAllowlist(peer); } catch (e) {
    if (e instanceof ConfigError) refuse(e.message);
    throw e;
  }
}
const writeAllowlist = (peer: string, entries: AllowEntry[]) => replaceText(suitesFile(peer), entries.map(e => `${e.alias} ${e.path}\n`).join(""));

export async function allowSuite(peer: string, alias: string, path: string, deps: Deps): Promise<void> {
  guard(deps);
  knownPeer(peer);
  if (!ALIAS_RE.test(alias)) refuse("the alias must match ^[a-z0-9-]{1,32}$");
  if (!SUITE_PATH_RE.test(path) || path.includes("..")) refuse("the suite path must match ^scripts/[a-z0-9_/.-]{1,120}\\.sh$ and hold no ..");
  const entries = currentAllowlist(peer);
  if (entries.some(e => e.alias === alias)) refuse(`the alias ${alias} is already in use`);
  if (entries.some(e => e.path === path)) refuse(`${path} is already allowed`);
  mkdir0700(configDir());
  writeAllowlist(peer, [...entries, { alias, path }]);
  deps.out(`${peer} may now be asked to run ${path} as ${alias}`);
}

export async function denySuite(peer: string, alias: string, deps: Deps): Promise<void> {
  guard(deps);
  knownPeer(peer);
  if (!ALIAS_RE.test(alias)) refuse("the alias must match ^[a-z0-9-]{1,32}$");
  const entries = currentAllowlist(peer);
  if (!entries.some(e => e.alias === alias)) refuse(`${peer} has no allowed suite ${alias}`);
  writeAllowlist(peer, entries.filter(e => e.alias !== alias));
  deps.out(`${alias} is no longer allowed for ${peer}`);
}

export async function kill(peer: string, deps: Deps): Promise<void> {
  guard(deps);
  knownPeer(peer);
  mkdir0700(configDir());
  try { writeNew(killedFile(peer), "", 0o600); } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "EEXIST") refuse(`${peer} is already killed`);
    throw e;
  }
  deps.out(`${peer} is killed: its envelopes are dropped and its running job is cancelled`);
}

export async function unkill(peer: string, deps: Deps): Promise<void> {
  guard(deps);
  knownPeer(peer);
  if (!fs.existsSync(killedFile(peer))) refuse(`${peer} is not killed`);
  fs.rmSync(killedFile(peer), { force: true });
  deps.out(`${peer} may send again`);
}

function stopUnitDefault(): void {
  if (process.platform === "linux") spawnSync("systemctl", ["--user", "disable", "--now", UNIT_NAME, RUNNER_UNIT], { stdio: "ignore", timeout: 15_000 });
  else if (process.platform === "darwin") {
    for (const p of [PLIST_NAME, RUNNER_PLIST]) spawnSync("launchctl", ["bootout", `gui/${process.getuid!()}`, join(homeDir(), "Library", "LaunchAgents", p)], { stdio: "ignore", timeout: 15_000 });
  }
}

export async function uninstall(deps: Deps): Promise<void> {
  guard(deps);
  const h = homeDir();
  if ((await deps.ask("Delete the whole peer bridge: state, config, key and unit? Type yes: ")).trim() !== "yes") refuse("not uninstalled");
  const units = unitPaths().filter(p => fs.existsSync(p));
  if (units.length) (deps.stopUnit ?? stopUnitDefault)();
  for (const u of units) fs.rmSync(u, { force: true });
  fs.rmSync(stateDir(), { recursive: true, force: true });
  fs.rmSync(configDir(), { recursive: true, force: true });
  for (const d of [join(h, ".himmel"), join(h, ".config", "himmel")]) { try { fs.rmdirSync(d); } catch {} }
  deps.out("uninstalled the peer bridge");
}

function flag(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  const [cmd, ...args] = process.argv.slice(2);
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const deps: Deps = {
    env: process.env,
    tty: Boolean(process.stdin.isTTY && process.stdout.isTTY),
    ask: q => new Promise(res => rl.question(q, res)),
    out: l => console.log(l),
  };
  try {
    if (cmd === "add" && args[0]) await add(args[0], { peerBotId: flag(args, "--peer-bot-id"), operatorBotId: flag(args, "--operator-bot-id"), peerUsername: flag(args, "--peer-username") }, deps);
    else if (cmd === "confirm" && args.length === 2) await confirm(args[0], args[1], deps);
    else if (cmd === "remove" && args.length === 1) await remove(args[0], deps);
    else if (cmd === "uninstall" && args.length === 0) await uninstall(deps);
    else if (cmd === "runner" && args.length === 0) await runner(deps);
    else if (cmd === "station-name" && args.length === 1) await stationName(args[0], deps);
    else if (cmd === "keygen" && args.length === 0) await keygenCmd("new", deps);
    else if (cmd === "keygen" && args.length === 1 && args[0] === "--rotate") await keygenCmd("rotate", deps);
    else if (cmd === "keygen" && args.length === 1 && args[0] === "--activate") await keygenCmd("activate", deps);
    else if (cmd === "keygen" && args.length === 1 && args[0] === "--show") await keygenCmd("show", deps);
    else if (cmd === "dm" && args.length === 0) await dm(deps);
    else if (cmd === "pair" && args[0] && args.length <= 4) await pair(args[0], args[1] !== undefined && args[1] !== "--card" ? args[1] : undefined, flag(args, "--card"), deps);
    else if (cmd === "trust" && args.length === 3) await trust(args[0], args[1], args[2], deps);
    else if (cmd === "untrust" && args.length === 1) await untrust(args[0], undefined, deps);
    else if (cmd === "untrust" && args.length === 3 && args[1] === "--key") await untrust(args[0], args[2], deps);
    else if (cmd === "allow-suite" && args.length === 3) await allowSuite(args[0], args[1], args[2], deps);
    else if (cmd === "deny-suite" && args.length === 2) await denySuite(args[0], args[1], deps);
    else if (cmd === "kill" && args.length === 1) await kill(args[0], deps);
    else if (cmd === "unkill" && args.length === 1) await unkill(args[0], deps);
    else { console.error("usage: setup.ts add <peer> --peer-bot-id N [--operator-bot-id N] [--peer-username U] | confirm <peer> <chatId> | remove <peer> | uninstall | runner | dm | station-name <name> | keygen [--rotate|--activate|--show] | pair <peer> [<station-name>] [--card '<card>'] | trust <peer> <station-name> <pubkey-b64> | untrust <peer> [--key <id>] | allow-suite <peer> <alias> <path> | deny-suite <peer> <alias> | kill <peer> | unkill <peer>"); process.exit(2); }
  } catch (e) {
    if (e instanceof SetupError) { console.error(`setup: ${e.message}`); process.exit(3); }
    throw e;
  } finally { rl.close(); }
}

if (import.meta.main) main();
