import { readFile, stat } from "node:fs/promises";
import * as z from "zod";
import { decodeQmdUri, Denied, readVerified, type PolicyScope } from "./paths.js";
import { buildSnippet, titleOf } from "./vault-fs.js";

export interface QmdSearchInput {
  searches: { type: "lex" | "vec" | "hyde"; query: string }[];
  collections: string[];
  limit: number;
  minScore?: number | undefined;
}

export interface QmdRawHit {
  file: string;
  title?: string | undefined;
  score?: number | undefined;
}

export type QmdFailure = "down" | "timeout" | "bad-response" | "token";

export class QmdUnavailable extends Error {
  readonly kind: QmdFailure;
  constructor(kind: QmdFailure, message: string = kind) {
    super(message);
    this.kind = kind;
  }
}

export interface QmdProxy {
  search(input: QmdSearchInput, signal?: AbortSignal): Promise<QmdRawHit[]>;
  health(): Promise<boolean>;
}

export interface QmdProxyOptions {
  url: string;
  tokenFile: string;
  timeoutMs: number;
  fetch?: typeof fetch;
  timeoutSignal?: (ms: number) => AbortSignal;
}

export interface SearchHit {
  collection: string;
  path: string;
  title: string;
  score: number | null;
  line: number;
  snippet: string;
}

export interface VerifyContext {
  collections: ReadonlyMap<string, { root: string; scope: PolicyScope }>;
  terms: readonly string[];
  limit: number;
}

const MAX_RESPONSE_CHARS = 8 * 1024 * 1024;
const HEALTH_TIMEOUT_MS = 2000;
const ResponseSchema = z.object({ results: z.array(z.unknown()) });
const FileSchema = z.object({ file: z.string() });

async function readToken(file: string): Promise<string> {
  let st;
  try {
    st = await stat(file);
  } catch {
    throw new QmdUnavailable("token", "QMD token file is not readable");
  }
  if (!st.isFile() || (st.mode & 0o077) !== 0) throw new QmdUnavailable("token", "QMD token file must be mode 0600 or 0400");
  const token = (await readFile(file, "utf8")).trim();
  if (token === "") throw new QmdUnavailable("token", "QMD token file is empty");
  return token;
}

export function createQmdProxy(opts: QmdProxyOptions): QmdProxy {
  const doFetch = opts.fetch ?? fetch;
  const timeoutSignal = opts.timeoutSignal ?? ((ms: number) => AbortSignal.timeout(ms));
  const base = opts.url.replace(/\/+$/, "");

  return {
    async search(input, signal) {
      if (input.collections.length === 0) throw new Error("refusing to send an empty collections list to QMD");
      const token = await readToken(opts.tokenFile);
      const timer = timeoutSignal(opts.timeoutMs);
      const combined = signal ? AbortSignal.any([timer, signal]) : timer;
      const body = JSON.stringify({
        searches: input.searches,
        collections: input.collections,
        limit: input.limit,
        ...(input.minScore !== undefined ? { minScore: input.minScore } : {}),
      });
      let text: string;
      try {
        const res = await doFetch(`${base}/query`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
          body,
          signal: combined,
          redirect: "error",
        });
        if (!res.ok) {
          await res.body?.cancel();
          throw new QmdUnavailable("bad-response", `QMD answered ${res.status}`);
        }
        text = await res.text();
      } catch (e) {
        if (e instanceof QmdUnavailable) throw e;
        throw new QmdUnavailable(timer.aborted ? "timeout" : "down");
      }
      if (text.length > MAX_RESPONSE_CHARS) throw new QmdUnavailable("bad-response", "QMD answer is too large");
      let json: unknown;
      try {
        json = JSON.parse(text);
      } catch {
        throw new QmdUnavailable("bad-response", "QMD answer is not JSON");
      }
      const parsed = ResponseSchema.safeParse(json);
      if (!parsed.success) throw new QmdUnavailable("bad-response", "QMD answer has an unexpected shape");
      const hits: QmdRawHit[] = [];
      for (const row of parsed.data.results) {
        const file = FileSchema.safeParse(row);
        if (!file.success) continue;
        const extra = row as Record<string, unknown>;
        hits.push({
          file: file.data.file,
          ...(typeof extra["title"] === "string" ? { title: extra["title"] } : {}),
          ...(typeof extra["score"] === "number" ? { score: extra["score"] } : {}),
        });
      }
      return hits;
    },

    async health() {
      try {
        const res = await doFetch(`${base}/health`, { signal: timeoutSignal(Math.min(opts.timeoutMs, HEALTH_TIMEOUT_MS)), redirect: "error" });
        await res.body?.cancel();
        return res.ok;
      } catch {
        return false;
      }
    },
  };
}

export class RateLimiter {
  readonly #max: number;
  readonly #windowMs: number;
  readonly #now: () => number;
  readonly #hits = new Map<string, number[]>();

  constructor(max: number, windowMs: number, now: () => number) {
    this.#max = max;
    this.#windowMs = windowMs;
    this.#now = now;
  }

  take(key: string): boolean {
    const t = this.#now();
    const recent = (this.#hits.get(key) ?? []).filter((at) => at > t - this.#windowMs);
    if (recent.length >= this.#max) {
      this.#hits.set(key, recent);
      return false;
    }
    recent.push(t);
    this.#hits.set(key, recent);
    return true;
  }
}

export async function verifyHits(raw: readonly QmdRawHit[], ctx: VerifyContext): Promise<{ hits: SearchHit[]; dropped: number }> {
  const hits: SearchHit[] = [];
  const seen = new Set<string>();
  let dropped = 0;
  for (const hit of raw) {
    if (hits.length >= ctx.limit) break;
    try {
      const { collection, segments } = decodeQmdUri(hit.file);
      const target = ctx.collections.get(collection);
      if (!target) throw new Denied("not-found");
      const path = segments.join("/");
      if (seen.has(`${collection}/${path}`)) continue;
      const file = await readVerified(target.root, segments, target.scope, "prefix");
      seen.add(`${collection}/${path}`);
      const { line, snippet } = buildSnippet(file.text, ctx.terms);
      hits.push({
        collection,
        path,
        title: titleOf(file.text, segments[segments.length - 1] ?? ""),
        score: typeof hit.score === "number" ? hit.score : null,
        line,
        snippet,
      });
    } catch (e) {
      if (!(e instanceof Denied)) throw e;
      dropped++;
    }
  }
  return { hits, dropped };
}
