#!/usr/bin/env node
import { randomBytes as nodeRandomBytes, randomUUID } from "node:crypto";
import { realpathSync } from "node:fs";
import { link, mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import {
  COLLECTION_NAME,
  defaultKeysFile,
  hashKey,
  KeysFileError,
  parseRecord,
  PROVIDERS,
  readKeysRaw,
  SUPPORTED_ROLES,
  writeKeysFile,
  type KeyRecord,
  type Provider,
} from "../auth.js";
import { loadRoots } from "../vault-fs.js";

export interface LockOptions {
  sleep?: (ms: number) => Promise<void>;
  isAlive?: (pid: number) => boolean;
  retries?: number;
  backoffMs?: number;
  staleMs?: number;
}

export interface KeysDeps extends LockOptions {
  now: () => number;
  randomBytes: (n: number) => Buffer;
  afterRead?: () => Promise<void>;
}

export interface MintParams {
  principal: string;
  provider: Provider;
  resource: string;
  roles: string[];
  collections: string[];
  ttlMs: number;
}

export interface Minted {
  keyId: string;
  token: string;
  expiresAt: string;
}

export interface Rotated extends Minted {
  oldKeyId: string;
  oldExpiresAt: string;
}

export type KeySummary = Omit<KeyRecord, "hash"> & { status: "active" | "expired" | "revoked" };

export interface KeysIo {
  env: NodeJS.ProcessEnv;
  stdout: (text: string) => void;
  stderr: (text: string) => void;
  now: () => number;
  randomBytes: (n: number) => Buffer;
  listCollections?: () => Promise<string[]>;
}

const DAY_MS = 86_400_000;
const MAX_TTL_MS = 365 * DAY_MS;
const UNIT_MS: Record<string, number> = { m: 60_000, h: 3_600_000, d: DAY_MS };
const PRINCIPAL = /^[A-Za-z0-9._-]{1,64}$/;
const USAGE = [
  "usage: luna-mcp-keys <command>",
  "  mint   --principal <name> --provider xai-grokbot|openai-chatgpt --collections all|<a,b,...> --ttl <90d|12h|30m> [--resource <https-url>] [--roles reader]",
  "  list   [--json]",
  "  revoke <keyId>",
  "  rotate <keyId> --ttl <90d> [--overlap 24h]",
  "The key file is LUNA_MCP_KEYS_FILE; the default resource is LUNA_MCP_PUBLIC_URL.",
].join("\n");

class UsageError extends Error {}

export function parseDuration(text: string, label: string): number {
  const m = /^(\d{1,6})([mhd])$/.exec(text);
  const ms = m ? Number(m[1]) * (UNIT_MS[m[2] as string] as number) : 0;
  if (!m || ms <= 0 || ms > MAX_TTL_MS) throw new UsageError(`${label} must look like 90d, 12h or 30m and be at most 365d`);
  return ms;
}

function validate(p: MintParams): void {
  if (!PRINCIPAL.test(p.principal)) throw new UsageError("principal must be 1-64 characters of letters, digits, dot, dash or underscore");
  if (!(PROVIDERS as readonly string[]).includes(p.provider)) throw new UsageError(`provider must be one of ${PROVIDERS.join(", ")}`);
  let url: URL;
  try {
    url = new URL(p.resource);
  } catch {
    throw new UsageError("resource is not a URL");
  }
  if (url.protocol !== "https:") throw new UsageError("resource must be an https URL");
  if (p.roles.length === 0 || !p.roles.every((r) => (SUPPORTED_ROLES as readonly string[]).includes(r))) {
    throw new UsageError(`roles must be a subset of ${SUPPORTED_ROLES.join(", ")} (writer, manager, admin and salus are not available yet)`);
  }
  if (p.collections.length === 0 || !p.collections.every((c) => COLLECTION_NAME.test(c))) throw new UsageError("collections must be a list of collection names");
  if (p.collections.includes("salus")) throw new UsageError("salus cannot be granted to a key at this stage");
  if (!Number.isFinite(p.ttlMs) || p.ttlMs <= 0 || p.ttlMs > MAX_TTL_MS) throw new UsageError("ttl must be positive and at most 365d");
}

function newToken(deps: KeysDeps): string {
  return `lmk_${deps.randomBytes(32).toString("base64url")}`;
}

function newKeyId(deps: KeysDeps, taken: ReadonlySet<string>): string {
  for (let i = 0; i < 8; i++) {
    const id = `lk_${deps.randomBytes(6).toString("hex")}`;
    if (!taken.has(id)) return id;
  }
  throw new Error("could not generate a unique key id");
}

const idsOf = (raw: readonly unknown[]): Set<string> =>
  new Set(raw.map((r) => (r && typeof r === "object" ? (r as { keyId?: unknown }).keyId : undefined)).filter((x): x is string => typeof x === "string"));

const LOCK_RETRIES = 40;
const LOCK_BACKOFF_MS = 25;
const LOCK_BACKOFF_CAP_MS = 2000;
const LOCK_STALE_MS = 30_000;

const pidAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
};

async function reclaimStaleLock(lock: string, now: number, staleMs: number, isAlive: (pid: number) => boolean, token: string): Promise<boolean> {
  let raw: string;
  let mtimeMs: number;
  try {
    raw = await readFile(lock, "utf8");
    mtimeMs = (await stat(lock)).mtimeMs;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ENOENT";
  }
  let info: { pid?: unknown; at?: unknown } = {};
  try {
    info = JSON.parse(raw) as typeof info;
  } catch {
    info = {};
  }
  const pid = typeof info.pid === "number" && Number.isInteger(info.pid) && info.pid > 0 ? info.pid : undefined;
  const at = typeof info.at === "number" && Number.isFinite(info.at) ? info.at : mtimeMs;
  if (!((pid !== undefined && !isAlive(pid)) || now - at > staleMs)) return false;
  const grave = `${lock}.${token}.stale`;
  try {
    await rename(lock, grave);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ENOENT";
  }
  let moved = "";
  try {
    moved = await readFile(grave, "utf8");
  } catch {
    moved = "";
  }
  if (moved !== raw) {
    await link(grave, lock).catch(() => undefined);
    await rm(grave, { force: true });
    return false;
  }
  await rm(grave, { force: true });
  return true;
}

async function withKeysLock<T>(file: string, deps: Partial<KeysDeps>, fn: () => Promise<T>): Promise<T> {
  const lock = `${file}.lock`;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const retries = deps.retries ?? LOCK_RETRIES;
  const backoff = deps.backoffMs ?? LOCK_BACKOFF_MS;
  const token = randomUUID();
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  for (let attempt = 0; ; attempt++) {
    try {
      const fh = await open(lock, "wx", 0o600);
      try {
        await fh.writeFile(JSON.stringify({ pid: process.pid, at: now(), token }));
      } finally {
        await fh.close();
      }
      break;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    }
    if (await reclaimStaleLock(lock, now(), deps.staleMs ?? LOCK_STALE_MS, deps.isAlive ?? pidAlive, token)) continue;
    if (attempt >= retries) throw new Error(`key file is locked by another luna-mcp-keys run (${lock})`);
    await sleep(Math.min(backoff * 2 ** attempt, LOCK_BACKOFF_CAP_MS));
  }
  const release = async (): Promise<void> => {
    const held = JSON.parse(await readFile(lock, "utf8")) as { token?: unknown };
    if (held.token === token) await rm(lock, { force: true });
  };
  try {
    return await fn();
  } finally {
    await release().catch(() => undefined);
  }
}

export async function mintKey(file: string, p: MintParams, deps: KeysDeps): Promise<Minted> {
  validate(p);
  return withKeysLock(file, deps, async () => {
    const raw = await readKeysRaw(file, true);
    await deps.afterRead?.();
    const token = newToken(deps);
    const keyId = newKeyId(deps, idsOf(raw));
    const now = deps.now();
    const record: KeyRecord = {
      keyId,
      hash: hashKey(token),
      principal: p.principal,
      egressProvider: p.provider,
      resource: p.resource,
      roles: p.roles as KeyRecord["roles"],
      allowedCollections: [...p.collections],
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + p.ttlMs).toISOString(),
      revoked: false,
    };
    await writeKeysFile(file, [...raw, record]);
    return { keyId, token, expiresAt: record.expiresAt };
  });
}

export async function revokeKey(file: string, keyId: string, deps: Partial<KeysDeps> = {}): Promise<void> {
  await withKeysLock(file, deps, async () => {
    const raw = await readKeysRaw(file);
    await deps.afterRead?.();
    let found = false;
    const next = raw.map((r) => {
      if (r && typeof r === "object" && (r as { keyId?: unknown }).keyId === keyId) {
        found = true;
        return { ...(r as object), revoked: true };
      }
      return r;
    });
    if (!found) throw new UsageError(`no key ${keyId}`);
    await writeKeysFile(file, next);
  });
}

export async function rotateKey(
  file: string,
  keyId: string,
  opts: { ttlMs: number; overlapMs: number },
  deps: KeysDeps,
): Promise<Rotated> {
  return withKeysLock(file, deps, async () => {
    const raw = await readKeysRaw(file);
    await deps.afterRead?.();
    const index = raw.findIndex((r) => r && typeof r === "object" && (r as { keyId?: unknown }).keyId === keyId);
    const old = index < 0 ? undefined : parseRecord(raw[index]);
    if (!old) throw new UsageError(`no valid key ${keyId}`);
    if (old.revoked) throw new UsageError(`key ${keyId} is revoked`);
    if (!(opts.overlapMs > 0 && opts.overlapMs <= MAX_TTL_MS)) throw new UsageError("overlap must be positive and at most 365d");
    validate({ principal: old.principal, provider: old.egressProvider, resource: old.resource, roles: old.roles, collections: old.allowedCollections, ttlMs: opts.ttlMs });
    const now = deps.now();
    const token = newToken(deps);
    const newId = newKeyId(deps, idsOf(raw));
    const oldExpires = Math.min(Date.parse(old.expiresAt), now + opts.overlapMs);
    const oldExpiresAt = oldExpires === Date.parse(old.expiresAt) ? old.expiresAt : new Date(oldExpires).toISOString();
    const successor: KeyRecord = {
      ...old,
      keyId: newId,
      hash: hashKey(token),
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + opts.ttlMs).toISOString(),
      revoked: false,
    };
    const next = raw.map((r, i) => (i === index ? { ...(r as object), expiresAt: oldExpiresAt } : r));
    await writeKeysFile(file, [...next, successor]);
    return { keyId: newId, token, expiresAt: successor.expiresAt, oldKeyId: keyId, oldExpiresAt };
  });
}

export async function listKeys(file: string, now: () => number): Promise<KeySummary[]> {
  const raw = await readKeysRaw(file, true);
  const t = now();
  const out: KeySummary[] = [];
  for (const r of raw) {
    const rec = parseRecord(r);
    if (!rec) continue;
    const { hash: _hash, ...rest } = rec;
    out.push({ ...rest, status: rec.revoked ? "revoked" : Date.parse(rec.expiresAt) <= t ? "expired" : "active" });
  }
  return out;
}

function printMinted(io: KeysIo, minted: Minted, lines: string[]): void {
  io.stdout(
    [
      `keyId: ${minted.keyId}`,
      ...lines,
      `expiresAt: ${minted.expiresAt}`,
      `key: ${minted.token}`,
      "This key is shown once and is not stored. Copy it now.",
      "",
    ].join("\n"),
  );
}

export async function runKeys(argv: string[], io: KeysIo): Promise<number> {
  const file = io.env["LUNA_MCP_KEYS_FILE"] || defaultKeysFile(io.env);
  const deps: KeysDeps = { now: io.now, randomBytes: io.randomBytes };
  const [command, ...rest] = argv;
  try {
    switch (command) {
      case "mint": {
        const { values } = parseArgs({
          args: rest,
          strict: true,
          options: {
            principal: { type: "string" },
            provider: { type: "string" },
            resource: { type: "string" },
            roles: { type: "string" },
            collections: { type: "string" },
            ttl: { type: "string" },
          },
        });
        const resource = values.resource ?? io.env["LUNA_MCP_PUBLIC_URL"];
        if (!values.principal || !values.provider || !values.collections || !values.ttl || !resource) {
          throw new UsageError("mint needs --principal, --provider, --collections, --ttl and a resource (--resource or LUNA_MCP_PUBLIC_URL)");
        }
        const known = (await (io.listCollections ?? (async () => [...(await loadRoots(io.env)).keys()]))()).filter((c) => c !== "salus");
        const requested = values.collections === "all" ? known : values.collections.split(",").map((c) => c.trim()).filter((c) => c !== "");
        const unknown = requested.filter((c) => c !== "salus" && !known.includes(c));
        if (unknown.length > 0) throw new UsageError(`unknown collection ${unknown.join(", ")}: define it in the QMD config first`);
        const params: MintParams = {
          principal: values.principal,
          provider: values.provider as Provider,
          resource,
          roles: (values.roles ?? "reader").split(",").map((r) => r.trim()),
          collections: requested,
          ttlMs: parseDuration(values.ttl, "ttl"),
        };
        const minted = await mintKey(file, params, deps);
        printMinted(io, minted, [`principal: ${params.principal}`, `provider: ${params.provider}`, `resource: ${params.resource}`, `roles: ${params.roles.join(",")}`, `collections: ${params.collections.join(",")}`]);
        return 0;
      }
      case "list": {
        const { values } = parseArgs({ args: rest, strict: true, options: { json: { type: "boolean" } } });
        const rows = await listKeys(file, io.now);
        if (values.json) io.stdout(`${JSON.stringify(rows, null, 2)}\n`);
        else for (const r of rows) io.stdout(`${r.keyId}  ${r.principal}  ${r.egressProvider}  ${r.status}  expires ${r.expiresAt}  ${r.allowedCollections.join(",")}\n`);
        return 0;
      }
      case "revoke": {
        const { positionals } = parseArgs({ args: rest, strict: true, allowPositionals: true, options: {} });
        if (positionals.length !== 1 || !positionals[0]) throw new UsageError("revoke needs exactly one keyId");
        await revokeKey(file, positionals[0], deps);
        io.stdout(`revoked ${positionals[0]}\n`);
        return 0;
      }
      case "rotate": {
        const { values, positionals } = parseArgs({ args: rest, strict: true, allowPositionals: true, options: { ttl: { type: "string" }, overlap: { type: "string" } } });
        if (positionals.length !== 1 || !positionals[0] || !values.ttl) throw new UsageError("rotate needs one keyId and --ttl");
        const rotated = await rotateKey(file, positionals[0], { ttlMs: parseDuration(values.ttl, "ttl"), overlapMs: parseDuration(values.overlap ?? "24h", "overlap") }, deps);
        printMinted(io, rotated, [`replaces: ${rotated.oldKeyId}`, `oldKeyId: ${rotated.oldKeyId}`, `oldExpiresAt: ${rotated.oldExpiresAt}`]);
        return 0;
      }
      default:
        io.stderr(`${USAGE}\n`);
        return 2;
    }
  } catch (e) {
    const message = e instanceof UsageError || e instanceof KeysFileError ? e.message : e instanceof Error ? e.message : "failed";
    io.stderr(`luna-mcp-keys: ${message}\n`);
    if (e instanceof UsageError && command === undefined) io.stderr(`${USAGE}\n`);
    return e instanceof UsageError ? 2 : 1;
  }
}

function isMain(): boolean {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1] as string) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  void runKeys(process.argv.slice(2), {
    env: process.env,
    stdout: (s) => void process.stdout.write(s),
    stderr: (s) => void process.stderr.write(s),
    now: Date.now,
    randomBytes: nodeRandomBytes,
  }).then((code) => {
    process.exitCode = code;
  });
}
