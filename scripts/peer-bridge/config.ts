import fs from "node:fs";
import { constants } from "node:fs";
import { isAbsolute } from "node:path";
import { STATION_NAME_RE } from "./envelope";
import { BOT_ID_RE, KINDS, PEER_NAME_RE, TOKEN_RE, botIdFromToken, type OpenKind } from "./ids";
import { keyId, type TheirKey } from "./sign";

export const EXIT_CONFIG = 78;

export class ConfigError extends Error {
  code = EXIT_CONFIG;
  constructor(message: string) { super(message); this.name = "ConfigError"; }
}

export type Theirs = { username: string; opens: OpenKind[]; maxOpenThreads: number; maxPerMinute: number; copiedAt: string; stationName?: string; keys: TheirKey[] };
export type Peer = {
  peerBotId: string;
  chatId: number | null;
  allowFrom: string[];
  opens: OpenKind[];
  maxOpenThreads: number;
  maxPerMinute: number;
  maxReaderRunsPerDay: number;
  maxReaderRunsPerKindPerDay: Record<OpenKind, number>;
  maxWakesPerDay: number;
  theirs: Theirs;
};
export type Config = {
  self: { stationName?: string };
  operatorBotId: string;
  operatorChatId: number;
  bridgeRoot: string;
  himmelRoot: string;
  peers: Record<string, Peer>;
  maxTextChars: number;
  addressing: "command";
};

function bad(message: string): never { throw new ConfigError(message); }
const posInt = (v: unknown, what: string): number =>
  typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : bad(`${what} must be a positive integer`);
const str = (v: unknown, what: string): string => typeof v === "string" && v !== "" ? v : bad(`${what} must be a non-empty string`);
const opens = (v: unknown, what: string): OpenKind[] => {
  if (!Array.isArray(v) || !v.every(k => (KINDS as readonly string[]).includes(k))) return bad(`${what} must list only ${KINDS.join(", ")}`);
  return v as OpenKind[];
};

function stationName(v: unknown, what: string): string | undefined {
  if (v === undefined) return undefined;
  return typeof v === "string" && STATION_NAME_RE.test(v) ? v : bad(`${what} must match ${STATION_NAME_RE.source}`);
}

// At most two keys (current and next), each naming itself correctly: the id is the
// first 8 hex of sha256 of the public key, so a hand-edited id cannot lie.
function theirKeys(v: unknown, what: string): TheirKey[] {
  if (v === undefined) return [];
  if (!Array.isArray(v) || v.length > 2) return bad(`${what} must be a list of at most two keys`);
  return v.map((k: any, i: number) => {
    const pub = k?.pub, at = k?.addedAt;
    if (typeof pub !== "string" || Buffer.from(pub, "base64").length !== 32 || Buffer.from(pub, "base64").toString("base64") !== pub) return bad(`${what}[${i}].pub must be a base64 32-byte key`);
    if (k.id !== keyId(pub)) return bad(`${what}[${i}].id is not the id of its pub`);
    if (typeof at !== "string" || Number.isNaN(Date.parse(at))) return bad(`${what}[${i}].addedAt must be a date`);
    return { id: k.id, pub, addedAt: at };
  });
}

function parsePeer(name: string, raw: any): Peer {
  if (!raw || typeof raw !== "object") bad(`peer ${name} must be an object`);
  const botId = str(raw.peerBotId, `peer ${name} peerBotId`);
  if (!BOT_ID_RE.test(botId)) bad(`peer ${name} peerBotId must be digits`);
  if (raw.chatId !== null && !(typeof raw.chatId === "number" && Number.isSafeInteger(raw.chatId))) bad(`peer ${name} chatId must be a number or null`);
  if (!Array.isArray(raw.allowFrom) || !raw.allowFrom.every((x: unknown) => typeof x === "string" && BOT_ID_RE.test(x))) bad(`peer ${name} allowFrom must be an array of digit ids`);
  const perKind = raw.maxReaderRunsPerKindPerDay ?? {};
  const t = raw.theirs ?? {};
  return {
    peerBotId: botId,
    chatId: raw.chatId,
    allowFrom: raw.allowFrom,
    opens: opens(raw.opens, `peer ${name} opens`),
    maxOpenThreads: posInt(raw.maxOpenThreads, `peer ${name} maxOpenThreads`),
    maxPerMinute: posInt(raw.maxPerMinute, `peer ${name} maxPerMinute`),
    maxReaderRunsPerDay: posInt(raw.maxReaderRunsPerDay, `peer ${name} maxReaderRunsPerDay`),
    maxReaderRunsPerKindPerDay: {
      question: posInt(perKind.question, `peer ${name} maxReaderRunsPerKindPerDay.question`),
      status: posInt(perKind.status, `peer ${name} maxReaderRunsPerKindPerDay.status`),
      info: posInt(perKind.info, `peer ${name} maxReaderRunsPerKindPerDay.info`),
    },
    maxWakesPerDay: posInt(raw.maxWakesPerDay, `peer ${name} maxWakesPerDay`),
    theirs: {
      username: str(t.username, `peer ${name} theirs.username`),
      opens: opens(t.opens, `peer ${name} theirs.opens`),
      maxOpenThreads: posInt(t.maxOpenThreads, `peer ${name} theirs.maxOpenThreads`),
      maxPerMinute: posInt(t.maxPerMinute, `peer ${name} theirs.maxPerMinute`),
      copiedAt: str(t.copiedAt, `peer ${name} theirs.copiedAt`),
      stationName: stationName(t.stationName, `peer ${name} theirs.stationName`),
      keys: theirKeys(t.keys, `peer ${name} theirs.keys`),
    },
  };
}

export function readPeersFile(path: string): Config {
  let text: string;
  try {
    const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile()) bad("peers.json is not a regular file");
      if (st.uid !== process.getuid!()) bad("peers.json is not owned by this user");
      if ((st.mode & 0o777) !== 0o600) bad("peers.json must be mode 0600");
      text = fs.readFileSync(fd, "utf8");
    } finally { fs.closeSync(fd); }
  } catch (e) {
    if (e instanceof ConfigError) throw e;
    throw new ConfigError(`cannot read peers.json: ${(e as NodeJS.ErrnoException).code ?? "error"}`);
  }
  let raw: any;
  try { raw = JSON.parse(text); } catch { return bad("peers.json is not valid JSON"); }
  if (!raw || typeof raw !== "object") bad("peers.json must be an object");

  const operatorBotId = str(raw.operatorBotId, "operatorBotId");
  if (!BOT_ID_RE.test(operatorBotId)) bad("operatorBotId must be digits");
  if (typeof raw.operatorChatId !== "number" || !Number.isSafeInteger(raw.operatorChatId)) bad("operatorChatId must be a number");
  const bridgeRoot = str(raw.bridgeRoot, "bridgeRoot");
  const himmelRoot = str(raw.himmelRoot, "himmelRoot");
  if (!isAbsolute(bridgeRoot) || !isAbsolute(himmelRoot)) bad("bridgeRoot and himmelRoot must be absolute paths");
  if (raw.addressing !== "command") bad('addressing must be "command"');
  const maxTextChars = posInt(raw.maxTextChars, "maxTextChars");
  if (maxTextChars > 4096) bad("maxTextChars is above Telegram's 4096 limit");
  if (!raw.peers || typeof raw.peers !== "object" || Array.isArray(raw.peers)) bad("peers must be an object");
  const peers: Record<string, Peer> = {};
  for (const [name, p] of Object.entries(raw.peers)) {
    if (!PEER_NAME_RE.test(name)) bad(`peer name ${JSON.stringify(name)} is not ^[a-z0-9][a-z0-9-]{0,31}$`);
    peers[name] = parsePeer(name, p);
  }
  const self = raw.self === undefined ? {} : raw.self;
  if (!self || typeof self !== "object" || Array.isArray(self)) bad("self must be an object");
  return { self: { stationName: stationName(self.stationName, "self.stationName") }, operatorBotId, operatorChatId: raw.operatorChatId, bridgeRoot, himmelRoot, peers, maxTextChars, addressing: "command" };
}

export function loadConfig(path: string, env: NodeJS.ProcessEnv = process.env): Config {
  const cfg = readPeersFile(path);
  const token = env.PEER_BOT_TOKEN;
  if (!token) bad("PEER_BOT_TOKEN is not set");
  if (!TOKEN_RE.test(token!)) bad("PEER_BOT_TOKEN is not a bot token");
  if (botIdFromToken(token!) === cfg.operatorBotId) bad("the peer bot token is the operator bot's token");
  return cfg;
}
