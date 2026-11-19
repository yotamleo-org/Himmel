// setup.ts add|confirm|remove|uninstall: host lifecycle for the peer bridge. It
// runs only from the station's own operator at a terminal. No inbound module
// imports it, and nothing a peer sends can reach it.
//
//   setup.ts add <peer> --peer-bot-id N [--peer-username U]
//   setup.ts confirm <peer> <chatId>
//   setup.ts remove <peer>
//   setup.ts uninstall
//
// Exit: 0 done, 2 usage, 3 refused (nothing written).
import { randomBytes } from "node:crypto";
import fs, { constants } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { defaultRoot } from "../telegram/bus";
import { loadAccess, operatorChatId, type Access } from "../telegram/gate";
import { submitSpool } from "./chain";
import { readPeersFile, ConfigError } from "./config";
import { BOT_ID_RE, PEER_NAME_RE, TOKEN_RE, botIdFromToken, configDir, peerDir, peersFile, stateDir } from "./ids";
import { sanitize } from "./sanitize";
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
};

const USERNAME_RE = /^[A-Za-z][A-Za-z0-9_]{2,31}$/;
const CHAIN_FILES = ["inbox.jsonl", "outbox.jsonl", "threads.jsonl", "digests.jsonl"];
const UNIT_NAME = "himmel-peer-bridge.service";
const PLIST_NAME = "com.himmel.peer-bridge.plist";

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
  return [join(h, ".config", "systemd", "user", UNIT_NAME), join(h, "Library", "LaunchAgents", PLIST_NAME)];
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

type AddOpts = { peerBotId?: string; peerUsername?: string };

export async function add(peer: string, opts: AddOpts, deps: Deps): Promise<void> {
  guard(deps);
  if (!PEER_NAME_RE.test(peer)) refuse("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  if (!opts.peerBotId || !BOT_ID_RE.test(opts.peerBotId)) refuse("--peer-bot-id must be the peer bot's numeric id");
  if (!hasJq(deps.env)) refuse("jq is required (desk.sh reads peers.json with it)");

  const existing = fs.existsSync(peersFile()) ? loadRaw() : null;
  if (existing?.peers?.[peer]) refuse(`peer ${peer} is already set up; remove it first`);

  let operatorBotId: string, chatId: number | null, bridgeRoot: string, himmelRoot: string;
  if (existing) {
    ({ operatorBotId, operatorChatId: chatId, bridgeRoot, himmelRoot } = existing);
  } else {
    operatorBotId = (await deps.ask("The operator bot's numeric id: ")).trim();
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
  deps.out(`removed ${peer}; restart the poller to drop it`);
}

function stopUnitDefault(): void {
  if (process.platform === "linux") spawnSync("systemctl", ["--user", "disable", "--now", UNIT_NAME], { stdio: "ignore", timeout: 15_000 });
  else if (process.platform === "darwin") spawnSync("launchctl", ["bootout", `gui/${process.getuid!()}`, join(homeDir(), "Library", "LaunchAgents", PLIST_NAME)], { stdio: "ignore", timeout: 15_000 });
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
    if (cmd === "add" && args[0]) await add(args[0], { peerBotId: flag(args, "--peer-bot-id"), peerUsername: flag(args, "--peer-username") }, deps);
    else if (cmd === "confirm" && args.length === 2) await confirm(args[0], args[1], deps);
    else if (cmd === "remove" && args.length === 1) await remove(args[0], deps);
    else if (cmd === "uninstall" && args.length === 0) await uninstall(deps);
    else { console.error("usage: setup.ts add <peer> --peer-bot-id N [--peer-username U] | confirm <peer> <chatId> | remove <peer> | uninstall"); process.exit(2); }
  } catch (e) {
    if (e instanceof SetupError) { console.error(`setup: ${e.message}`); process.exit(3); }
    throw e;
  } finally { rl.close(); }
}

if (import.meta.main) main();
