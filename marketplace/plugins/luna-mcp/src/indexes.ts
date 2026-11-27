import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute } from "node:path";
import { parseQmdConfigRoots } from "./vault-fs.js";

export interface NamedIndex {
  name: string;
  url: string;
  tokenFile: string;
  roots: Map<string, string>;
}

const INDEX_NAME = /^[A-Za-z0-9._-]{1,64}$/;
const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]"]);

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function loopbackUrl(name: string, raw: unknown): string {
  if (typeof raw !== "string") throw new Error(`index ${name}: url must be a string`);
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`index ${name}: url is not a URL`);
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || !LOOPBACK.has(url.hostname) || url.username !== "" || url.password !== "") {
    throw new Error(`index ${name}: url must be http(s) on a loopback host`);
  }
  return raw;
}

function absolute(name: string, field: string, raw: unknown): string {
  if (typeof raw !== "string" || !isAbsolute(raw)) throw new Error(`index ${name}: ${field} must be an absolute path`);
  return raw;
}

/**
 * Named qmd indexes from the JSON file in LUNA_MCP_INDEXES:
 * `{ "<index>": { "url": "http://localhost:<port>", "tokenFile": "/abs", "config": "/abs/<index>.yml" } }`.
 * Each index has its own daemon, so its collections are searched alone and never as part of "all".
 */
export async function loadNamedIndexes(env: NodeJS.ProcessEnv): Promise<NamedIndex[]> {
  const file = env["LUNA_MCP_INDEXES"];
  if (!file) return [];
  const parsed = JSON.parse(await readFile(file, "utf8")) as unknown;
  if (!isRecord(parsed)) throw new Error("named indexes file must be an object");
  const home = env["HOME"] || homedir();
  const out: NamedIndex[] = [];
  for (const [name, entry] of Object.entries(parsed)) {
    if (!INDEX_NAME.test(name) || !isRecord(entry)) throw new Error(`named index ${name} is not a valid entry`);
    const url = loopbackUrl(name, entry["url"]);
    const tokenFile = absolute(name, "tokenFile", entry["tokenFile"]);
    const config = absolute(name, "config", entry["config"]);
    const roots = parseQmdConfigRoots(await readFile(config, "utf8"), home);
    if (roots.size === 0) throw new Error(`index ${name}: its config defines no collection`);
    out.push({ name, url, tokenFile, roots });
  }
  return out;
}

/** Collection name -> owning named index; a collection defined twice anywhere is refused. */
export function isolatedCollections(indexes: readonly NamedIndex[], shared: Iterable<string>): Map<string, NamedIndex> {
  const taken = new Set(shared);
  const owner = new Map<string, NamedIndex>();
  for (const index of indexes) {
    for (const collection of index.roots.keys()) {
      if (taken.has(collection) || owner.has(collection)) throw new Error(`collection ${collection} is defined in more than one qmd index`);
      owner.set(collection, index);
    }
  }
  return owner;
}
