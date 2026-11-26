import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { checkSegments, Denied, parseRelPath, readVerified, resolveDir, type PolicyScope } from "./paths.js";

export interface DocResult {
  collection: string;
  path: string;
  content: string;
  sha256: string;
  size: number;
  mtime: string;
}

export interface DirEntry {
  name: string;
  type: "file" | "dir";
  size: number | null;
  mtime: string | null;
}

export interface DirPage {
  dir: string;
  entries: DirEntry[];
  nextCursor: string | null;
}

export interface RecentDoc {
  path: string;
  title: string;
  size: number;
  mtime: string;
}

const SNIPPET_CHARS = 300;
const TITLE_CHARS = 200;
const COLLECTION_KEY = /^[A-Za-z0-9._-]+$/;
const isMarkdown = (name: string): boolean => /\.md$/i.test(name);
const iso = (ms: number): string => new Date(ms).toISOString();
const unquote = (s: string): string => s.replace(/^(["'])(.*)\1$/, "$2");

interface Split {
  front: string[];
  body: string[];
  bodyStart: number;
}

function splitFrontmatter(text: string): Split {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/);
  if (lines[0]?.trimEnd() === "---") {
    for (let i = 1; i < lines.length; i++) {
      const end = (lines[i] ?? "").trimEnd();
      if (end === "---" || end === "...") return { front: lines.slice(1, i), body: lines.slice(i + 1), bodyStart: i + 2 };
    }
  }
  return { front: [], body: lines, bodyStart: 1 };
}

export function titleOf(text: string, fileName: string): string {
  const { front, body } = splitFrontmatter(text);
  for (const line of body) {
    const h = /^#\s+(.+?)\s*#*\s*$/.exec(line);
    if (h) return (h[1] ?? "").slice(0, TITLE_CHARS);
  }
  for (const line of front) {
    const t = /^title\s*:\s*(.+)$/i.exec(line);
    if (t) return unquote((t[1] ?? "").trim()).slice(0, TITLE_CHARS);
  }
  return fileName.replace(/\.md$/i, "");
}

export function buildSnippet(text: string, terms: readonly string[]): { line: number; snippet: string } {
  const { body, bodyStart } = splitFrontmatter(text);
  const needles = terms.map((t) => t.toLowerCase()).filter((t) => t.length >= 2);
  let index = body.findIndex((l) => {
    const lower = l.toLowerCase();
    return needles.some((n) => lower.includes(n));
  });
  let from: number;
  if (index >= 0) {
    from = Math.max(0, index - 1);
  } else {
    index = body.findIndex((l) => l.trim() !== "");
    if (index < 0) return { line: bodyStart, snippet: "" };
    from = index;
  }
  const snippet = body.slice(from, index + 2).join("\n").slice(0, SNIPPET_CHARS);
  return { line: bodyStart + index, snippet };
}

export function parseQmdConfigRoots(yaml: string, home: string): Map<string, string> {
  const roots = new Map<string, string>();
  const names = new Set<string>();
  let inCollections = false;
  let current: string | null = null;
  const lines = yaml.split("\n");
  for (let n = 0; n < lines.length; n++) {
    const line = lines[n] ?? "";
    const where = `line ${n + 1}`;
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    if (line.includes("\t") || line.includes("\r")) throw new Error(`${where}: tab or carriage return`);
    const body = line.trimStart();
    const indent = line.length - body.length;
    if (indent === 0) {
      inCollections = body === "collections:";
      current = null;
      continue;
    }
    if (!inCollections) continue;
    if (indent === 2) {
      const name = body.endsWith(":") ? body.slice(0, -1) : "";
      if (!COLLECTION_KEY.test(name)) throw new Error(`${where}: expected a collection name`);
      if (names.has(name)) throw new Error(`${where}: collection ${name} defined twice`);
      names.add(name);
      current = name;
      continue;
    }
    if (indent === 4 && current !== null && body.startsWith("path:")) {
      let value = body.slice("path:".length).replace(/\s+#.*$/, "").trim();
      if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.endsWith(value[0] as string)) value = value.slice(1, -1);
      if (value === "~") value = home;
      else if (value.startsWith("~/")) value = join(home, value.slice(2));
      if (!value.startsWith("/")) throw new Error(`${where}: path is not absolute`);
      roots.set(current, value);
    }
  }
  for (const name of names) {
    if (!roots.has(name)) throw new Error(`collection ${name} has no path`);
  }
  return roots;
}

export async function loadRoots(env: NodeJS.ProcessEnv): Promise<Map<string, string>> {
  const mapFile = env["LUNA_MCP_COLLECTION_ROOTS"];
  if (mapFile) {
    const parsed = JSON.parse(await readFile(mapFile, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("collection roots map must be an object");
    const roots = new Map<string, string>();
    for (const [name, root] of Object.entries(parsed)) {
      if (!COLLECTION_KEY.test(name) || typeof root !== "string" || !root.startsWith("/")) {
        throw new Error(`collection roots map entry ${name} is not an absolute path`);
      }
      roots.set(name, root);
    }
    return roots;
  }
  const home = env["HOME"] || homedir();
  const file = env["QMD_CONFIG_FILE"] || join(env["XDG_CONFIG_HOME"] || join(home, ".config"), "qmd", "index.yml");
  return parseQmdConfigRoots(await readFile(file, "utf8"), home);
}

export async function readDoc(root: string, collection: string, rawPath: string, scope: PolicyScope): Promise<DocResult> {
  const segments = parseRelPath(rawPath);
  const file = await readVerified(root, segments, scope, "whole");
  return { collection, path: segments.join("/"), content: file.text, sha256: file.sha256, size: file.size, mtime: iso(file.mtimeMs) };
}

const encodeCursor = (name: string): string => Buffer.from(name, "utf8").toString("base64url");
const decodeCursor = (cursor: string): string => Buffer.from(cursor, "base64url").toString("utf8");

export async function listDir(
  root: string,
  rawDir: string | undefined,
  scope: PolicyScope,
  page: { cursor?: string | undefined; limit: number },
): Promise<DirPage> {
  const trimmed = (rawDir ?? "").replace(/\/+$/, "");
  const requested = trimmed === "" ? [] : parseRelPath(trimmed);
  const { real, segments } = await resolveDir(root, requested, scope);
  const dirents = await readdir(real, { withFileTypes: true });
  dirents.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const after = page.cursor ? decodeCursor(page.cursor) : null;
  const entries: DirEntry[] = [];
  let more = false;
  for (const d of dirents) {
    if (after !== null && !(d.name > after)) continue;
    if (entries.length >= page.limit) {
      more = true;
      break;
    }
    if (d.isSymbolicLink()) continue;
    const child = [...segments, d.name];
    try {
      parseRelPath(d.name);
      checkSegments(child, scope);
      if (d.isDirectory()) {
        entries.push({ name: d.name, type: "dir", size: null, mtime: null });
      } else if (d.isFile() && isMarkdown(d.name)) {
        const file = await readVerified(root, child, scope, "prefix");
        entries.push({ name: d.name, type: "file", size: file.size, mtime: iso(file.mtimeMs) });
      }
    } catch (e) {
      if (!(e instanceof Denied)) throw e;
    }
  }
  const last = entries[entries.length - 1];
  return { dir: segments.join("/"), entries, nextCursor: more && last ? encodeCursor(last.name) : null };
}

export async function recentDocs(
  root: string,
  scope: PolicyScope,
  limit: number,
  maxVisited: number,
): Promise<{ docs: RecentDoc[]; truncated: boolean }> {
  const { real: rootReal } = await resolveDir(root, [], scope);
  const stack: string[][] = [[]];
  const found: { segments: string[]; mtimeMs: number }[] = [];
  let visited = 0;
  let truncated = false;
  walk: while (stack.length > 0) {
    const dir = stack.pop() ?? [];
    let dirents;
    try {
      dirents = await readdir(join(rootReal, ...dir), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const d of dirents) {
      if (++visited > maxVisited) {
        truncated = true;
        break walk;
      }
      if (d.isSymbolicLink()) continue;
      const child = [...dir, d.name];
      try {
        parseRelPath(d.name);
        checkSegments(child, scope);
      } catch (e) {
        if (e instanceof Denied) continue;
        throw e;
      }
      if (d.isDirectory()) stack.push(child);
      else if (d.isFile() && isMarkdown(d.name)) found.push({ segments: child, mtimeMs: (await stat(join(rootReal, ...child))).mtimeMs });
    }
  }
  found.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const docs: RecentDoc[] = [];
  for (const f of found) {
    if (docs.length >= limit) break;
    try {
      const file = await readVerified(root, f.segments, scope, "prefix");
      docs.push({ path: f.segments.join("/"), title: titleOf(file.text, f.segments[f.segments.length - 1] ?? ""), size: file.size, mtime: iso(file.mtimeMs) });
    } catch (e) {
      if (!(e instanceof Denied)) throw e;
    }
  }
  return { docs, truncated };
}
