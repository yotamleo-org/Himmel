import fs from "node:fs";
import { constants } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { alive, startIdentity } from "./chain";
import { ALLOWANCE_S, RANGES, STATION_NAME_RE, SUITE_PATH_RE, TIMEOUT_S_MAX } from "./envelope";
import { badHost } from "./host";
import { BOT_ID_RE, KINDS, PEER_NAME_RE, TOKEN_RE, botIdFromToken, configDir, type OpenKind } from "./ids";
import { STATION_KEY, keyId, type TheirKey } from "./sign";

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
export const cardMessage = (theirUsername: string, station: string, pub: string) => `/peer@${theirUsername}\n${pairCard(station, pub)}`;

export const canonicalKey = (pub: string): boolean => {
  const b = Buffer.from(pub, "base64");
  return b.length === 32 && b.toString("base64") === pub;
};

const ADDRESS_RE = /^\/peer@([A-Za-z][A-Za-z0-9_]{2,31})$/;

export function parseCard(text: string, addressedTo?: string): { station: string; pub: string } | null {
  const lines = text.split("\n");
  if (lines.length > 2) return null;
  if (lines.length === 2) {
    const a = ADDRESS_RE.exec(lines[0]);
    if (!a || (addressedTo !== undefined && a[1] !== addressedTo)) return null;
  }
  const m = PAIR_CARD_RE.exec(lines[lines.length - 1]);
  return m && canonicalKey(m[2]) ? { station: m[1], pub: m[2] } : null;
}

export function trustRefusal(cfg: Pick<Config, "peers">, peer: string, station: string, pub: string, host: string, opts: { firstOnly?: boolean }): string | null {
  if (!Object.hasOwn(cfg.peers, peer)) return "unknown-peer";
  const theirs = cfg.peers[peer].theirs;
  if (opts.firstOnly && theirs.keys.length > 0) return "already-paired";
  if (!STATION_NAME_RE.test(station)) return "name";
  if (badHost(station, host)) return "host";
  if (!canonicalKey(pub)) return "key-shape";
  if (theirs.keys.some(k => k.id === keyId(pub))) return "already-trusted";
  if (theirs.keys.length >= 2) return "two-keys";
  if (theirs.stationName !== undefined && theirs.stationName !== station) return "name-differs";
  return null;
}

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
    if (typeof pub !== "string" || !canonicalKey(pub)) return bad(`${what}[${i}].pub must be a base64 32-byte key`);
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

export function readPeersBytes(path: string): Buffer {
  try {
    const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile()) bad("peers.json is not a regular file");
      if (st.uid !== process.getuid!()) bad("peers.json is not owned by this user");
      if ((st.mode & 0o777) !== 0o600) bad("peers.json must be mode 0600");
      return fs.readFileSync(fd);
    } finally { fs.closeSync(fd); }
  } catch (e) {
    if (e instanceof ConfigError) throw e;
    throw new ConfigError(`cannot read peers.json: ${(e as NodeJS.ErrnoException).code ?? "error"}`);
  }
}

export const readPeersFile = (path: string): Config => parsePeers(readPeersBytes(path));

export function parsePeers(bytes: Buffer): Config {
  let raw: any;
  try { raw = JSON.parse(bytes.toString("utf8")); } catch { return bad("peers.json is not valid JSON"); }
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


const LOCK_WAIT_MS = 2000, LOCK_STALE_MS = 10_000, LOCK_POLL_MS = 50;

type Hook = () => void | Promise<void>;
export type LockOpts = { now: () => number; sleep: (ms: number) => Promise<unknown>; hooks?: { beforeLink?: Hook; afterRuledStale?: Hook; afterRename?: Hook } };

function lockStale(text: string, mtimeMs: number, now: number): boolean {
  if (now - mtimeMs > LOCK_STALE_MS) return true;
  let h: { pid?: number; start?: string | null } = {};
  try { h = JSON.parse(text) ?? {}; } catch { return false; }
  if (!Number.isSafeInteger(h.pid) || h.pid! <= 0) return false;
  return !alive(h.pid!) || startIdentity(h.pid!) !== h.start;
}

export async function withPeersLock<T>(dir: string, fn: () => T | Promise<T>, opts: LockOpts): Promise<T> {
  const lock = join(dir, "peers.json.lock");
  const deadline = opts.now() + LOCK_WAIT_MS;
  const wait = async () => {
    if (opts.now() >= deadline) bad("busy");
    await opts.sleep(LOCK_POLL_MS);
  };
  let mine: number | null = null;
  while (mine === null) {
    const tmp = `${lock}.${randomBytes(4).toString("hex")}.tmp`;
    const fd = fs.openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, start: startIdentity(process.pid) }));
      await opts.hooks?.beforeLink?.();
      fs.linkSync(tmp, lock);
      mine = fd;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    } finally {
      if (mine === null) fs.closeSync(fd);
      fs.rmSync(tmp, { force: true });
    }
    if (mine !== null) break;

    let held: number;
    try { held = fs.openSync(lock, constants.O_RDONLY | constants.O_NOFOLLOW); } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw e;
    }
    try {
      const seen = fs.fstatSync(held), text = fs.readFileSync(held, "utf8");
      if (!lockStale(text, seen.mtimeMs, opts.now())) { await wait(); continue; }
      await opts.hooks?.afterRuledStale?.();
      const aside = `${lock}.stale-${randomBytes(4).toString("hex")}`;
      try { fs.renameSync(lock, aside); } catch (e) {
        if ((e as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw e;
      }
      await opts.hooks?.afterRename?.();
      const moved = fs.lstatSync(aside);
      if (moved.dev === seen.dev && moved.ino === seen.ino && lockStale(text, moved.mtimeMs, opts.now())) {
        fs.rmSync(aside, { force: true });
        continue;
      }
      try { fs.linkSync(aside, lock); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
      fs.rmSync(aside, { force: true });
      await wait();
    } finally { fs.closeSync(held); }
  }
  try { return await fn(); } finally {
    try {
      const ours = fs.fstatSync(mine), now = fs.lstatSync(lock);
      if (now.dev === ours.dev && now.ino === ours.ino) fs.rmSync(lock, { force: true });
    } catch {}
    fs.closeSync(mine);
  }
}

export const pairingFile = (): string => {
  const h = process.env.HOME || homedir();
  if (!isAbsolute(h) || h === "/") bad("HOME is not a usable directory");
  return join(h, ".himmel", "remote-setup", "pairing.json");
};

function tmpWrite(path: string, data: string): string {
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  const fd = fs.openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, data); } finally { fs.closeSync(fd); }
  return tmp;
}

export function writePairingRecord(bytes: Buffer): void {
  parsePeers(bytes);
  const raw = JSON.parse(bytes.toString("utf8"));
  const stationKey = fs.existsSync(join(configDir(), STATION_KEY));
  const peers = Object.entries<any>(raw.peers ?? {}).map(([name, p]) => ({
    name,
    ourStationName: typeof raw.self?.stationName === "string",
    ourStationKey: stationKey,
    groupChat: typeof p.chatId === "number",
    operatorChat: typeof raw.operatorDmChatId === "number",
    theirKey: Array.isArray(p.theirs?.keys) && p.theirs.keys.length > 0,
  }));
  const path = pairingFile();
  fs.mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = tmpWrite(path, JSON.stringify({ peers }, null, 2) + "\n");
  try { fs.renameSync(tmp, path); } catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
}

export function dropPairingRecord(why: Error): string {
  let dropped = false;
  try { fs.rmSync(pairingFile(), { force: true }); dropped = !fs.existsSync(pairingFile()); } catch {}
  return `the pairing steps record could not be updated (${why.message}); ${dropped ? "the old record was dropped, the next pairing step writes it again" : "the old record is still there and may be out of date"}`;
}

export type ReplaceOpts = { guard?: () => void; hooks?: { afterRead?: () => void }; log?: (line: string) => void };

export function replacePeersJsonLocked(path: string, expected: Buffer, value: unknown, opts: ReplaceOpts = {}): void {
  readPeersBytes(path);
  opts.hooks?.afterRead?.();
  if (!readPeersBytes(path).equals(expected)) bad("changed");
  opts.guard?.();
  const text = JSON.stringify(value, null, 2) + "\n";
  const tmp = tmpWrite(path, text);
  try { fs.renameSync(tmp, path); } catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
  try { writePairingRecord(Buffer.from(text)); } catch (e) { (opts.log ?? console.error)(dropPairingRecord(e as Error)); }
}

type LockHooks = NonNullable<LockOpts["hooks"]> & NonNullable<ReplaceOpts["hooks"]>;
export type WriteOpts = Omit<ReplaceOpts, "hooks"> & Omit<LockOpts, "hooks"> & { hooks?: LockHooks };

export async function replacePeersJson(path: string, expected: Buffer, value: unknown, opts: WriteOpts): Promise<void> {
  await withPeersLock(dirname(path), () => replacePeersJsonLocked(path, expected, value, opts), opts);
}

export type AddKeyOpts = WriteOpts & { hostname: string; firstOnly?: boolean };

export async function addTrustedKey(path: string, peer: string, station: string, pub: string, opts: AddKeyOpts): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    const bytes = readPeersBytes(path);
    const rule = trustRefusal(parsePeers(bytes), peer, station, pub, opts.hostname, { firstOnly: opts.firstOnly });
    if (rule !== null) bad(rule);
    const raw = JSON.parse(bytes.toString("utf8"));
    const theirs = raw.peers[peer].theirs;
    theirs.stationName = station;
    theirs.keys = [...(theirs.keys ?? []), { id: keyId(pub), pub, addedAt: new Date(opts.now()).toISOString().replace(/\.\d{3}Z$/, "Z") }];
    try { return await replacePeersJson(path, bytes, raw, opts); } catch (e) {
      if (!(e instanceof ConfigError) || e.message !== "changed") throw e;
      if (attempt > 0) bad("busy");
    }
  }
}
