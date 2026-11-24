import fs from "node:fs";
import { constants } from "node:fs";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { join } from "node:path";
import { chainHash, openChainFile, type ChainRecord } from "../telegram/bus";
import { SESSION_ID_RE } from "./ids";
import { procHooks } from "./proc";

type Handle = Awaited<ReturnType<typeof openChainFile>>;
type Opener = (file: string, flags: number) => Promise<Handle> | Handle;

export class Chain {
  private tails = new Map<string, { n: number; h: string }>();
  private queue: Promise<unknown> = Promise.resolve();
  private open: Opener;
  constructor(opts: { open?: Opener } = {}) { this.open = opts.open ?? openChainFile; }

  append(file: string, rec: Record<string, any>): Promise<ChainRecord> {
    const run = this.queue.then(() => this.appendNow(file, rec));
    this.queue = run.catch(() => {});
    return run;
  }

  // Appends in order, then commits. A failed append throws before the commit
  // runs, so a caller's offset never moves past a record that was not written.
  async appendThenCommit(items: { file: string; rec: Record<string, any> }[], commit: () => Promise<void>): Promise<void> {
    for (const it of items) await this.append(it.file, it.rec);
    await commit();
  }

  private async appendNow(file: string, rec: Record<string, any>): Promise<ChainRecord> {
    const handle = await this.open(file, constants.O_RDWR | constants.O_CREAT | constants.O_APPEND);
    try {
      let tail = this.tails.get(file);
      if (!tail) tail = await this.readTail(handle);
      const plain = { ...rec, n: tail.n + 1 };
      const stamped = { ...plain, h: chainHash(tail.h, plain) };
      const line = Buffer.from(JSON.stringify(stamped) + "\n");
      const { bytesWritten } = await handle.write(line);
      if (bytesWritten !== line.length) throw new Error("short chained append");
      this.tails.set(file, { n: stamped.n, h: stamped.h });
      return stamped;
    } catch (e) {
      this.tails.delete(file);
      throw e;
    } finally { await handle.close(); }
  }

  // A trailing line with no newline is a write the crash cut short. Nothing
  // downstream saw it (offsets and intents commit only after an append), so it
  // is cut off rather than left to wedge every later append.
  private async readTail(handle: Handle): Promise<{ n: number; h: string }> {
    const buf = await handle.readFile();
    if (buf.length === 0) return { n: 0, h: "" };
    let end = buf.length;
    if (buf[end - 1] !== 10) {
      end = buf.lastIndexOf(10) + 1;
      await handle.truncate(end);
      if (end === 0) return { n: 0, h: "" };
    }
    const last = JSON.parse(buf.subarray(buf.lastIndexOf(10, end - 2) + 1, end - 1).toString("utf8"));
    return { n: last.n, h: last.h };
  }
}

export function readChain(file: string): ChainRecord[] {
  let text: string;
  try { text = fs.readFileSync(file, "utf8"); } catch (e: any) { if (e.code === "ENOENT") return []; throw e; }
  const complete = text.slice(0, text.lastIndexOf("\n") + 1);
  return complete.split("\n").filter(Boolean).map(l => JSON.parse(l));
}

export function verifyChain(file: string, from?: { n: number; h: string }): { ok: boolean; n: number; h: string } {
  let prev = "", n = 0;
  const recs = readChain(file);
  if (from && from.n > 0) {
    const seed = recs[from.n - 1];
    if (!seed || seed.n !== from.n || seed.h !== from.h) return { ok: false, n: 0, h: "" };
    prev = from.h; n = from.n;
  }
  for (const rec of recs.slice(n)) {
    if (rec.n !== n + 1 || rec.h !== chainHash(prev, rec)) return { ok: false, n, h: prev };
    prev = rec.h; n = rec.n;
  }
  return { ok: true, n, h: prev };
}

export type SpoolRec =
  | { type: "draft"; source: "send.ts" | "telegram"; kind: "question" | "status" | "info" | "answer"; replyTo?: number; text: string; allowShape?: string }
  | { type: "tap"; verb: "ok" | "no"; draft: string; by: string; ts: number; sig?: string }
  | { type: "ack"; sid: string; token: string }
  | { type: "confirm"; chatId: number }
  | { type: "env-out"; kind: (typeof SPOOL_ENV_KINDS)[number]; body: Record<string, unknown> }
  | { type: "job-event"; job: number; event: { type: (typeof SPOOL_JOB_EVENTS)[number]; [k: string]: unknown } };
export type SendResult = { ok: true; message_id?: number; job?: number; draft?: string; deadline?: number } | { ok: false; rule: string; shape?: string; why?: string };
export type Drained = { name: string; rec: SpoolRec } | { name: string; malformed: true; why: string };

export const SPOOL_ENV_KINDS = ["req", "capacity-ask", "cancel", "halt"] as const;
export const SPOOL_JOB_EVENTS = ["resolve-ok", "resolve-fail", "approve", "vm-start", "vm-done"] as const;

const SEND_KINDS = ["question", "status", "info", "answer"];
function spoolFault(r: any): string | null {
  if (!r || typeof r !== "object" || Array.isArray(r)) return "not a json object";
  if (r.type === "env-out") {
    if (!(SPOOL_ENV_KINDS as readonly string[]).includes(r.kind)) return "env-out: bad kind";
    return r.body && typeof r.body === "object" && !Array.isArray(r.body) ? null : "env-out: bad body";
  }
  if (r.type === "job-event") {
    if (!(Number.isSafeInteger(r.job) && r.job > 0)) return "job-event: bad job";
    return r.event && typeof r.event === "object" && (SPOOL_JOB_EVENTS as readonly string[]).includes(r.event.type) ? null : "job-event: bad event";
  }
  if (r.type === "draft") {
    if (r.source !== "send.ts" && r.source !== "telegram") return "draft: bad source";
    if (!SEND_KINDS.includes(r.kind)) return "draft: bad kind";
    if (typeof r.text !== "string") return "draft: bad text";
    if (!(r.replyTo === undefined || (Number.isSafeInteger(r.replyTo) && r.replyTo > 0))) return "draft: bad replyTo";
    return r.allowShape === undefined || /^[a-z_]{1,20}$/.test(r.allowShape) ? null : "draft: bad allowShape";
  }
  if (r.type === "tap") {
    if (r.verb !== "ok" && r.verb !== "no") return "tap: bad verb";
    if (!(typeof r.draft === "string" && /^[0-9a-f]{8}$/.test(r.draft))) return "tap: bad draft";
    if (!(typeof r.by === "string" && /^[0-9]{1,15}$/.test(r.by))) return "tap: bad by";
    if (!Number.isSafeInteger(r.ts)) return "tap: bad ts";
    return r.sig === undefined || (typeof r.sig === "string" && r.sig.length <= 128) ? null : "tap: bad sig";
  }
  if (r.type === "ack") {
    if (!(typeof r.sid === "string" && SESSION_ID_RE.test(r.sid))) return "ack: bad sid";
    return typeof r.token === "string" && /^[A-Za-z0-9]+$/.test(r.token) ? null : "ack: bad token";
  }
  if (r.type === "confirm") return Number.isSafeInteger(r.chatId) ? null : "confirm: bad chatId";
  return "unknown type";
}

export const TAP_KEY = "tap.key";
const TAP_DOMAIN = "himmel-peer-tap-v1\n";

function readTapKey(path: string): Buffer {
  const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o600) throw new Error("the tap key must be a regular file owned by you, mode 0600");
    const key = fs.readFileSync(fd);
    if (key.length < 32) throw new Error("the tap key is too short");
    return key;
  } finally { fs.closeSync(fd); }
}

export function tapKey(confDir: string): Buffer {
  const path = join(confDir, TAP_KEY);
  try { return readTapKey(path); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
  fs.mkdirSync(confDir, { recursive: true, mode: 0o700 });
  const tmp = join(confDir, `.${TAP_KEY}.${randomBytes(4).toString("hex")}.tmp`);
  const fd = fs.openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try { fs.writeFileSync(fd, randomBytes(32).toString("hex")); } finally { fs.closeSync(fd); }
    try { fs.linkSync(tmp, path); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
  } finally { fs.rmSync(tmp, { force: true }); }
  return readTapKey(path);
}

type TapFields = { peer: string; verb: string; draft: string; by: string; ts: number };
const tapMac = (key: Buffer, t: TapFields): string => createHmac("sha256", key).update(TAP_DOMAIN + [t.peer, t.draft, t.verb, t.by, t.ts].join("\n")).digest("hex");

export function signTap(confDir: string, t: TapFields): string {
  return tapMac(tapKey(confDir), t);
}

export function tapSigOk(confDir: string, t: TapFields, sig: string): boolean {
  try {
    if (!/^[0-9a-f]{64}$/.test(sig)) return false;
    return timingSafeEqual(Buffer.from(tapMac(tapKey(confDir), t), "hex"), Buffer.from(sig, "hex"));
  } catch { return false; }
}

let spoolSeq = 0;
const defaultSpoolName = () => `${Date.now()}-${String(spoolSeq++ % 1e6).padStart(6, "0")}-${randomBytes(4).toString("hex")}.json`;

// The file appears under its final name only once complete, and an existing
// name is refused (link fails with EEXIST), so the poller never reads a half
// record and a submission never overwrites another.
export function submitSpool(peerDir: string, rec: SpoolRec, nameFn: () => string = defaultSpoolName): string {
  const name = nameFn();
  const dir = join(peerDir, "spool");
  const tmp = join(dir, `.${name}.${randomBytes(4).toString("hex")}.tmp`);
  const fd = fs.openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try { fs.writeFileSync(fd, JSON.stringify(rec)); } finally { fs.closeSync(fd); }
    fs.linkSync(tmp, join(dir, name));
  } finally { fs.rmSync(tmp, { force: true }); }
  return name;
}

export function drainSpool(peerDir: string): Drained[] {
  const dir = join(peerDir, "spool");
  const out: Drained[] = [];
  for (const name of fs.readdirSync(dir).filter(n => n.endsWith(".json") && !n.startsWith(".")).sort()) {
    try {
      const fd = fs.openSync(join(dir, name), constants.O_RDONLY | constants.O_NOFOLLOW);
      let rec: unknown;
      try {
        if (!fs.fstatSync(fd).isFile()) throw new Error("not a file");
        rec = JSON.parse(fs.readFileSync(fd, "utf8"));
      } finally { fs.closeSync(fd); }
      const why = spoolFault(rec);
      out.push(why === null ? { name, rec: rec as SpoolRec } : { name, malformed: true, why });
    } catch (e) { out.push({ name, malformed: true, why: e instanceof SyntaxError ? "not valid json" : "not a regular file" }); }
  }
  return out;
}

export function writeResult(peerDir: string, name: string, res: SendResult): void {
  const dir = join(peerDir, "spool", "results");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = join(dir, `.${name}.${randomBytes(4).toString("hex")}.tmp`);
  const fd = fs.openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try { fs.writeFileSync(fd, JSON.stringify(res)); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, join(dir, name));
  } finally { fs.rmSync(tmp, { force: true }); }
  fs.rmSync(join(peerDir, "spool", name), { force: true });
}

export function sweepResults(peerDir: string, maxAgeMs: number, now = Date.now()): void {
  const dir = join(peerDir, "spool", "results");
  let names: string[];
  try { names = fs.readdirSync(dir); } catch { return; }
  for (const n of names) {
    try { if (now - fs.statSync(join(dir, n)).mtimeMs > maxAgeMs) fs.rmSync(join(dir, n), { force: true }); } catch {}
  }
}

export type IntentRec = { kind: "intent"; peer: string; chat: number; id: string; root: number | null; msgKind: string; text: string; isRoot: boolean; tpl?: boolean; resend?: boolean; spool?: string; env?: boolean; draft?: string; by?: string; source?: string };
export type SentRec = { kind: "sent"; id: string; intent: number; message_id: number; ts: number };

export class PidLockError extends Error {
  constructor(public pid: number) { super(`another peer-bridge poller is running (pid ${pid})`); this.name = "PidLockError"; }
}

// A process's start identity: with the pid it tells a live holder from a reused
// pid. Linux: /proc/<pid>/stat field 22. macOS: ps lstart, pinned to the C
// locale and UTC so the caller's TZ never changes the string.
export function startIdentity(pid: number, platform: string = process.platform): string | null {
  if (platform === "linux") {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19] ?? null;
    } catch { return null; }
  }
  const r = procHooks.spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], { env: { ...process.env, LC_ALL: "C", TZ: "UTC" }, encoding: "utf8" });
  const out = (r.stdout ?? "").trim();
  return r.status === 0 && out ? out : null;
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e: any) { return e.code === "EPERM"; }
}

function computeCodeVersion(): string {
  const dir = import.meta.dir, h = createHash("sha256");
  for (const n of fs.readdirSync(dir).filter(n => n.endsWith(".ts") && !n.endsWith(".test.ts") && !n.startsWith("testlib-")).sort()) h.update(n + "\0").update(fs.readFileSync(join(dir, n))).update("\0");
  return h.digest("hex").slice(0, 16);
}
export const CODE_VERSION = computeCodeVersion();

export function pollerStale(path: string): boolean {
  let holder: { pid?: number; start?: string | null; code?: string } = {};
  try { holder = JSON.parse(fs.readFileSync(path, "utf8")); } catch { return false; }
  if (!Number.isSafeInteger(holder.pid) || !alive(holder.pid!) || startIdentity(holder.pid!) !== holder.start) return false;
  return holder.code !== CODE_VERSION;
}

export function acquirePidLock(path: string): () => void {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try { fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, start: startIdentity(process.pid), code: CODE_VERSION })); } finally { fs.closeSync(fd); }
      return () => {
        try { if (JSON.parse(fs.readFileSync(path, "utf8")).pid === process.pid) fs.rmSync(path, { force: true }); } catch {}
      };
    } catch (e: any) {
      if (e.code !== "EEXIST") throw e;
    }
    let holder: { pid?: number; start?: string | null } = {};
    try { holder = JSON.parse(fs.readFileSync(path, "utf8")); } catch {}
    if (Number.isSafeInteger(holder.pid) && alive(holder.pid!) && startIdentity(holder.pid!) === holder.start) throw new PidLockError(holder.pid!);
    fs.rmSync(path, { force: true });
  }
  throw new Error("could not take the poller pid lock");
}
