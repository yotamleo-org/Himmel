import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open, readdir, readlink, realpath, stat, type FileHandle } from "node:fs/promises";
import type { Dirent } from "node:fs";
import { join, sep } from "node:path";
import { parseDocument } from "yaml";

export type DenyKind =
  | "bad-path"
  | "bad-uri"
  | "dot-segment"
  | "kernel"
  | "role-path"
  | "not-markdown"
  | "not-found"
  | "escape"
  | "symlink"
  | "salus"
  | "frontmatter"
  | "changed"
  | "unverifiable"
  | "too-large"
  | "not-text";

export class Denied extends Error {
  readonly kind: DenyKind;
  constructor(kind: DenyKind, message: string = kind) {
    super(message);
    this.kind = kind;
  }
}

export const READ_CAP_BYTES = 512 * 1024;
export const SCAN_BYTES = 64 * 1024;

export interface PolicyScope {
  vault: boolean;
  roles: readonly string[];
  allowHandoversRead: boolean;
}

export interface VerifyHooks {
  beforeOpen?: (abs: string) => void | Promise<void>;
  afterOpen?: (abs: string) => void | Promise<void>;
  afterRead?: (abs: string) => void | Promise<void>;
  fdPath?: (fd: number) => Promise<string>;
}

export interface VerifiedFile {
  text: string;
  size: number;
  mtimeMs: number;
  sha256: string;
}

const VAULT_KERNEL = new Set(["scripts", "marketplace", "graphify-out", "to_be_deleted"]);
const CONTROL = new RegExp(
  "[\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u200b-\\u200f\\u2028\\u2029\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u2069\\ufeff]",
  "u",
);
const COLLECTION_NAME = /^[A-Za-z0-9._-]{1,64}$/;
const MAX_PATH = 1024;
const MAX_SEGMENT = 255;
const MAX_DEPTH = 64;
const MISSING = new Set(["ENOENT", "ENOTDIR", "ELOOP", "EACCES", "EPERM", "ENAMETOOLONG"]);

export function isVaultCollection(name: string, corpora: readonly string[]): boolean {
  return name === "luna" || name.startsWith("luna-") || corpora.some((c) => c === "luna-personal" || c === "luna-clippings");
}

function validateSegment(seg: string): void {
  if (seg === "" || seg.length > MAX_SEGMENT) throw new Denied("bad-path");
  if (seg !== seg.normalize("NFC") || CONTROL.test(seg) || seg.includes("\\")) throw new Denied("bad-path");
  if (seg.startsWith(".")) throw new Denied("dot-segment");
  let decoded: string;
  try {
    decoded = decodeURIComponent(seg);
  } catch {
    return;
  }
  if (decoded === seg) return;
  if (decoded.includes("/") || decoded.includes("\\") || CONTROL.test(decoded) || decoded !== decoded.normalize("NFC")) {
    throw new Denied("bad-path");
  }
  if (decoded.startsWith(".")) throw new Denied("dot-segment");
}

function strictDecode(encoded: string): string {
  let out: string;
  try {
    out = decodeURIComponent(encoded);
  } catch {
    throw new Denied("bad-uri");
  }
  if (out.includes("/") || out.includes("\\") || out.includes("\u0000")) throw new Denied("bad-uri");
  return out;
}

export function decodeQmdUri(uri: string): { collection: string; segments: string[] } {
  const m = /^qmd:\/\/([^/]+)\/([\s\S]+)$/.exec(uri);
  if (!m) throw new Denied("bad-uri");
  const collection = strictDecode(m[1] ?? "");
  if (!COLLECTION_NAME.test(collection)) throw new Denied("bad-uri");
  const segments = (m[2] ?? "").split("/").map(strictDecode);
  if (segments.length > MAX_DEPTH) throw new Denied("bad-path");
  for (const s of segments) validateSegment(s);
  return { collection, segments };
}

export function parseRelPath(raw: string): string[] {
  if (raw.length === 0 || raw.length > MAX_PATH) throw new Denied("bad-path");
  const segments = raw.split("/");
  if (segments.length > MAX_DEPTH) throw new Denied("bad-path");
  for (const s of segments) validateSegment(s);
  return segments;
}

export function checkSegments(segments: readonly string[], scope: PolicyScope): void {
  for (const seg of segments) {
    if (seg.startsWith(".")) throw new Denied("dot-segment");
  }
  if (!scope.vault) return;
  const first = segments[0]?.toLowerCase();
  if (first === undefined) return;
  if (VAULT_KERNEL.has(first)) throw new Denied("kernel");
  const manager = scope.roles.includes("manager");
  if ((first === "sessions" || first === "chats") && !manager) throw new Denied("role-path");
  if (first === "handovers" && !(manager && scope.allowHandoversRead)) throw new Denied("role-path");
}

export type FrontmatterVerdict = "clean" | "salus" | "unreadable";

const MAX_YAML_ALIASES = 100;
const MAX_REPO_DEPTH = 8;

function repoVerdict(value: unknown, depth: number): FrontmatterVerdict {
  if (value === null || value === undefined) return "clean";
  if (typeof value === "string") return value.trim().toLowerCase() === "salus" ? "salus" : "clean";
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return "clean";
  if (Array.isArray(value) && depth < MAX_REPO_DEPTH) {
    let verdict: FrontmatterVerdict = "clean";
    for (const item of value) {
      const v = repoVerdict(item, depth + 1);
      if (v === "salus") return "salus";
      if (v === "unreadable") verdict = "unreadable";
    }
    return verdict;
  }
  return "unreadable";
}

export function frontmatterVerdict(text: string): FrontmatterVerdict {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const lines = src.split(/\r?\n/);
  if (lines[0]?.trimEnd() !== "---") return "clean";
  let close = -1;
  for (let i = 1; i < lines.length; i++) {
    const end = (lines[i] ?? "").trimEnd();
    if (end === "---" || end === "...") {
      close = i;
      break;
    }
  }
  if (close < 0) return "unreadable";
  let data: unknown;
  try {
    const doc = parseDocument(lines.slice(1, close).join("\n"), { uniqueKeys: true, merge: true });
    if (doc.errors.length > 0 || doc.warnings.length > 0) return "unreadable";
    data = doc.toJS({ maxAliasCount: MAX_YAML_ALIASES });
  } catch {
    return "unreadable";
  }
  if (data === null || data === undefined) return "clean";
  if (typeof data !== "object" || Array.isArray(data)) return "unreadable";
  let verdict: FrontmatterVerdict = "clean";
  for (const [key, value] of Object.entries(data)) {
    if (key.trim().toLowerCase() !== "repo") continue;
    const v = repoVerdict(value, 0);
    if (v === "salus") return "salus";
    if (v === "unreadable") verdict = "unreadable";
  }
  return verdict;
}

export function hasSalusFrontmatter(text: string): boolean {
  return frontmatterVerdict(text) !== "clean";
}

async function resolveRoot(root: string): Promise<string> {
  try {
    return await realpath(root);
  } catch (e) {
    if (MISSING.has((e as NodeJS.ErrnoException).code ?? "")) throw new Denied("not-found");
    throw e;
  }
}

function containedSegments(rootReal: string, real: string, scope: PolicyScope): string[] {
  let segments: string[];
  if (real === rootReal) segments = [];
  else if (real.startsWith(rootReal + sep)) segments = real.slice(rootReal.length + 1).split(sep);
  else throw new Denied("escape");
  checkSegments(segments, scope);
  return segments;
}

async function realSegmentsOf(rootReal: string, abs: string, scope: PolicyScope): Promise<string[]> {
  let real: string;
  try {
    real = await realpath(abs);
  } catch (e) {
    if (MISSING.has((e as NodeJS.ErrnoException).code ?? "")) throw new Denied("not-found");
    throw e;
  }
  return containedSegments(rootReal, real, scope);
}

const procFdPath = (fd: number): Promise<string> => readlink(`/proc/self/fd/${fd}`);

async function verifyOpened(fh: FileHandle, rootReal: string, scope: PolicyScope, hooks?: VerifyHooks): Promise<void> {
  let real: string;
  try {
    real = await (hooks?.fdPath ?? procFdPath)(fh.fd);
  } catch {
    throw new Denied("unverifiable");
  }
  if (real.endsWith(" (deleted)")) throw new Denied("changed");
  containedSegments(rootReal, real, scope);
}

async function readFully(fh: FileHandle, length: number, position: number): Promise<Buffer> {
  const buf = Buffer.alloc(length);
  let filled = 0;
  while (filled < length) {
    const { bytesRead } = await fh.read(buf, filled, length - filled, position + filled);
    if (bytesRead === 0) break;
    filled += bytesRead;
  }
  return filled === length ? buf : buf.subarray(0, filled);
}

export async function readVerified(
  root: string,
  segments: readonly string[],
  scope: PolicyScope,
  mode: "whole" | "prefix",
  hooks?: VerifyHooks,
): Promise<VerifiedFile> {
  checkSegments(segments, scope);
  const name = segments[segments.length - 1];
  if (name === undefined || !/\.md$/i.test(name)) throw new Denied("not-markdown");
  const rootReal = await resolveRoot(root);
  const abs = join(rootReal, ...segments);
  await realSegmentsOf(rootReal, abs, scope);
  await hooks?.beforeOpen?.(abs);
  let fh: FileHandle;
  try {
    fh = await open(abs, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code ?? "";
    if (code === "ELOOP") throw new Denied("symlink");
    if (MISSING.has(code)) throw new Denied("not-found");
    throw e;
  }
  try {
    await hooks?.afterOpen?.(abs);
    await verifyOpened(fh, rootReal, scope, hooks);
    const st = await fh.stat();
    if (!st.isFile()) throw new Denied("not-found");
    const prefixLength = Math.min(st.size, SCAN_BYTES);
    const prefix = await readFully(fh, prefixLength, 0);
    if (prefix.includes(0)) throw new Denied("not-text");
    const head = prefix.toString("utf8");
    const verdict = frontmatterVerdict(head);
    if (verdict === "salus") throw new Denied("salus");
    if (verdict === "unreadable") throw new Denied("frontmatter");
    if (mode === "prefix") return { text: head, size: st.size, mtimeMs: st.mtimeMs, sha256: "" };
    if (st.size > READ_CAP_BYTES) throw new Denied("too-large");
    const rest = st.size > prefixLength ? await readFully(fh, st.size - prefixLength, prefixLength) : Buffer.alloc(0);
    if (rest.includes(0)) throw new Denied("not-text");
    const all = rest.length > 0 ? Buffer.concat([prefix, rest]) : prefix;
    return { text: all.toString("utf8"), size: st.size, mtimeMs: st.mtimeMs, sha256: createHash("sha256").update(all).digest("hex") };
  } finally {
    await fh.close();
  }
}

export async function resolveDir(
  root: string,
  segments: readonly string[],
  scope: PolicyScope,
): Promise<{ real: string; rootReal: string; segments: string[] }> {
  checkSegments(segments, scope);
  const rootReal = await resolveRoot(root);
  const real = await realSegmentsOf(rootReal, join(rootReal, ...segments), scope);
  const realPath = join(rootReal, ...real);
  let st;
  try {
    st = await stat(realPath);
  } catch (e) {
    if (MISSING.has((e as NodeJS.ErrnoException).code ?? "")) throw new Denied("not-found");
    throw e;
  }
  if (!st.isDirectory()) throw new Denied("not-found");
  return { real: realPath, rootReal, segments: real };
}

export async function readDirVerified(
  root: string,
  segments: readonly string[],
  scope: PolicyScope,
  hooks?: VerifyHooks,
): Promise<{ real: string; segments: string[]; dirents: Dirent[] }> {
  const dir = await resolveDir(root, segments, scope);
  await hooks?.beforeOpen?.(dir.real);
  let fh: FileHandle;
  try {
    fh = await open(dir.real, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code ?? "";
    if (code === "ELOOP") throw new Denied("symlink");
    if (MISSING.has(code)) throw new Denied("not-found");
    throw e;
  }
  try {
    await hooks?.afterOpen?.(dir.real);
    await verifyOpened(fh, dir.rootReal, scope, hooks);
    const dirents = await readdir(`/proc/self/fd/${fh.fd}`, { withFileTypes: true });
    await hooks?.afterRead?.(dir.real);
    return { real: dir.real, segments: dir.segments, dirents };
  } finally {
    await fh.close();
  }
}
