import fs from "node:fs";
import { constants } from "node:fs";
import { isAbsolute, join } from "node:path";
import { ALLOWANCE_S, RANGES, STATION_NAME_RE, SUITE_PATH_RE, TIMEOUT_S_MAX } from "./envelope";
import { BOT_ID_RE, KINDS, PEER_NAME_RE, TOKEN_RE, botIdFromToken, configDir, type OpenKind } from "./ids";
import { keyId, type TheirKey } from "./sign";

export const EXIT_CONFIG = 78;

export class ConfigError extends Error {
  code = EXIT_CONFIG;
  constructor(message: string) { super(message); this.name = "ConfigError"; }
}

export const SERVED_OPS = ["run-suite"] as const;
export type Op = (typeof SERVED_OPS)[number];
export type Approve = "tty" | "auto";
export type Budgets = { jobsPerDay: number; vmMinutesPerDay: number; queueMax: number; maxJobMinutes: number };
export type AllowEntry = { alias: string; path: string };

export const MAX_JOB_MINUTES_MAX = TIMEOUT_S_MAX / 60 - ALLOWANCE_S / 60;
const BUDGET_BOUNDS: Record<keyof Budgets, [number, number]> = {
  jobsPerDay: [1, 1000], vmMinutesPerDay: [1, 10000], queueMax: [1, 3], maxJobMinutes: [30, MAX_JOB_MINUTES_MAX],
};
export const DEFAULT_BUDGETS: Budgets = { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130 };
export const ALIAS_RE = /^[a-z0-9-]{1,32}$/;
export const PAIR_CARD_RE = /^#pair station=([a-z0-9][a-z0-9-]{0,31}) key=([A-Za-z0-9+/]{43}=)$/;
export const pairCard = (station: string, pub: string) => `#pair station=${station} key=${pub}`;

export type Theirs = { username: string; opens: OpenKind[]; maxOpenThreads: number; maxPerMinute: number; copiedAt: string; stationName?: string; keys: TheirKey[]; imageDigest?: string };
export type Peer = {
  serves: Op[];
  approve: Record<Op, Approve>;
  budgets: Budgets;
  repoUrl?: string;
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
  operatorDmChatId: number | null;
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

function serves(v: unknown, what: string): Op[] {
  if (v === undefined) return [];
  if (!Array.isArray(v) || !v.every(o => (SERVED_OPS as readonly string[]).includes(o))) return bad(`${what} must list only ${SERVED_OPS.join(", ")}`);
  return v as Op[];
}

function approve(v: unknown, what: string): Record<Op, Approve> {
  if (v === undefined) return { "run-suite": "tty" };
  if (!v || typeof v !== "object" || Array.isArray(v)) return bad(`${what} must be an object`);
  const o = v as Record<string, unknown>;
  if (Object.keys(o).some(k => !(SERVED_OPS as readonly string[]).includes(k))) return bad(`${what} names an operation that is not served`);
  const mode = o["run-suite"] ?? "tty";
  return mode === "tty" || mode === "auto" ? { "run-suite": mode } : bad(`${what}.run-suite must be tty or auto`);
}

function budgets(v: unknown, what: string): Budgets {
  if (v === undefined) return { ...DEFAULT_BUDGETS };
  if (!v || typeof v !== "object" || Array.isArray(v)) return bad(`${what} must be an object`);
  const o = v as Record<string, unknown>;
  const keys = Object.keys(BUDGET_BOUNDS) as (keyof Budgets)[];
  if (Object.keys(o).length !== keys.length || !keys.every(k => Object.hasOwn(o, k))) return bad(`${what} must hold exactly ${keys.join(", ")}`);
  const out = {} as Budgets;
  for (const k of keys) {
    const [lo, hi] = BUDGET_BOUNDS[k];
    const n = o[k];
    if (typeof n !== "number" || !Number.isSafeInteger(n) || n < lo || n > hi) return bad(`${what}.${k} must be an integer from ${lo} to ${hi}`);
    out[k] = n;
  }
  return out;
}

function repoUrl(v: unknown, what: string): string | undefined {
  if (v === undefined) return undefined;
  return typeof v === "string" && /^(https:\/\/|file:\/\/\/)\S+$/.test(v) ? v : bad(`${what} must be an https:// or file:/// URL`);
}

function imageDigest(v: unknown, what: string): string | undefined {
  if (v === undefined) return undefined;
  return typeof v === "string" && /^[0-9a-f]{64}$/.test(v) ? v : bad(`${what} must be 64 lowercase hex`);
}

export function loadAllowlist(peer: string, dir: string = configDir()): AllowEntry[] {
  if (!PEER_NAME_RE.test(peer)) bad("peer name must match ^[a-z0-9][a-z0-9-]{0,31}$");
  const path = join(dir, `${peer}.suites`);
  let text: string;
  try {
    const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== process.getuid!()) bad(`${peer}.suites is not a regular file owned by this user`);
      if ((st.mode & 0o777) !== 0o600) bad(`${peer}.suites must be mode 0600`);
      text = fs.readFileSync(fd, "utf8");
    } finally { fs.closeSync(fd); }
  } catch (e) {
    if (e instanceof ConfigError) throw e;
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw new ConfigError(`cannot read ${peer}.suites: ${(e as NodeJS.ErrnoException).code ?? "error"}`);
  }
  const out: AllowEntry[] = [];
  for (const [i, line] of text.split("\n").entries()) {
    if (line === "") continue;
    const m = /^(\S+) (\S+)$/.exec(line);
    if (!m || !ALIAS_RE.test(m[1]) || !SUITE_PATH_RE.test(m[2]) || m[2].includes("..")) bad(`${peer}.suites line ${i + 1} is not "<alias> <suite path>"`);
    if (out.some(e => e.alias === m![1] || e.path === m![2])) bad(`${peer}.suites line ${i + 1} is a duplicate alias or path`);
    out.push({ alias: m[1], path: m[2] });
  }
  return out;
}

export function clampToSchema(field: string, n: number): number {
  const r = (RANGES as Record<string, readonly [number, number]>)[field];
  if (!r) throw new Error(`no schema range for ${field}`);
  if (Number.isNaN(n)) return r[0];
  return Math.floor(Math.min(r[1], Math.max(r[0], n)));
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
    serves: serves(raw.serves, `peer ${name} serves`),
    approve: approve(raw.approve, `peer ${name} approve`),
    budgets: budgets(raw.budgets, `peer ${name} budgets`),
    repoUrl: repoUrl(raw.repoUrl, `peer ${name} repoUrl`),
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
      imageDigest: imageDigest(t.imageDigest, `peer ${name} theirs.imageDigest`),
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
  const operatorDmChatId = raw.operatorDmChatId ?? null;
  if (operatorDmChatId !== null && operatorDmChatId !== raw.operatorChatId) bad("operatorDmChatId must be null or the operator chat id");
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
  return { self: { stationName: stationName(self.stationName, "self.stationName") }, operatorBotId, operatorChatId: raw.operatorChatId, operatorDmChatId, bridgeRoot, himmelRoot, peers, maxTextChars, addressing: "command" };
}

export function loadConfig(path: string, env: NodeJS.ProcessEnv = process.env): Config {
  const cfg = readPeersFile(path);
  const token = env.PEER_BOT_TOKEN;
  if (!token) bad("PEER_BOT_TOKEN is not set");
  if (!TOKEN_RE.test(token!)) bad("PEER_BOT_TOKEN is not a bot token");
  if (botIdFromToken(token!) === cfg.operatorBotId) bad("the peer bot token is the operator bot's token");
  return cfg;
}
