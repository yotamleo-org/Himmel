import * as z from "zod";
import { COLLECTION_NAME, type Principal } from "../auth.js";
import type { Egress } from "../egress.js";
import { isVaultCollection, Denied, type PolicyScope } from "../paths.js";
import { QmdUnavailable, verifyHits, type QmdProxy, type RateLimiter } from "../qmd-proxy.js";
import { listDir, readDoc, recentDocs, type DocResult } from "../vault-fs.js";

export interface Access {
  collection: string | null;
  corpus: string | null;
  path: string | null;
  verdict: "allow" | "deny";
  reason: string | null;
}

export interface OpOutcome {
  data: unknown;
  accesses: Access[];
}

export interface OpDeps {
  roots: ReadonlyMap<string, string>;
  egress: Egress;
  qmd: QmdProxy;
  limiter: RateLimiter;
}

export class OpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly access: Partial<Access>;
  constructor(status: number, code: string, message: string, access: Partial<Access> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.access = access;
  }
}

export interface OperationDef {
  name: string;
  aliases: readonly string[];
  description: string;
  input: z.ZodObject;
  run(deps: OpDeps, principal: Principal, args: unknown, signal?: AbortSignal): Promise<OpOutcome>;
}

const MULTI_READ_CAP_BYTES = 1024 * 1024;
const RECENT_WALK_BUDGET = 50_000;
const SEARCH_OVERFETCH_CAP = 50;

const CollectionName = z.string().regex(COLLECTION_NAME);
const DocPath = z.string().min(1).max(1024);

function defineOp<S extends z.ZodObject>(def: {
  name: string;
  aliases?: readonly string[];
  description: string;
  input: S;
  run: (deps: OpDeps, principal: Principal, args: z.output<S>, signal?: AbortSignal) => Promise<OpOutcome>;
}): OperationDef {
  return {
    name: def.name,
    aliases: def.aliases ?? [],
    description: def.description,
    input: def.input,
    run: (deps, principal, args, signal) => def.run(deps, principal, args as z.output<S>, signal),
  };
}

const usableOf = (principal: Principal): string[] => principal.allowedCollections.filter((c) => c !== "salus");
const unique = <T>(items: readonly T[]): T[] => [...new Set(items)];
const clip = (s: string): string => s.slice(0, 512);

function collectionOrDefault(principal: Principal, collection: string | undefined, path: string | null): string {
  const chosen = collection ?? usableOf(principal)[0];
  if (chosen === undefined) throw new OpError(403, "collection_forbidden", "no collection is permitted for this key", { path, reason: "collection-not-allowed" });
  return chosen;
}

interface Authorized {
  collection: string;
  root: string;
  corpora: string[];
  corpusLabel: string;
  scope: PolicyScope;
}

async function authorize(deps: OpDeps, principal: Principal, collection: string, path: string | null): Promise<Authorized> {
  const shown = path === null ? null : clip(path);
  if (!usableOf(principal).includes(collection)) {
    throw new OpError(403, "collection_forbidden", "collection not permitted for this key", { collection, path: shown, reason: "collection-not-allowed" });
  }
  const root = deps.roots.get(collection);
  if (root === undefined) {
    throw new OpError(403, "egress_denied", "collection is not available", { collection, path: shown, reason: `no-root:${collection}` });
  }
  const decision = await deps.egress.check(collection, principal.provider);
  if (!decision.allow) {
    throw new OpError(403, "egress_denied", "egress policy denies this collection", {
      collection,
      corpus: decision.corpora.join(",") || null,
      path: shown,
      reason: decision.reason ?? "egress-denied",
    });
  }
  return {
    collection,
    root,
    corpora: decision.corpora,
    corpusLabel: decision.corpora.join(","),
    scope: { vault: isVaultCollection(collection, decision.corpora), roles: principal.roles, allowHandoversRead: principal.allowHandoversRead },
  };
}

function deniedToOpError(e: unknown, access: Partial<Access>): OpError {
  if (!(e instanceof Denied)) throw e;
  switch (e.kind) {
    case "bad-path":
    case "bad-uri":
    case "dot-segment":
    case "kernel":
    case "role-path":
    case "not-markdown":
      return new OpError(403, "forbidden", "path not permitted", { ...access, reason: e.kind });
    case "too-large":
      return new OpError(413, "too_large", "document exceeds the read cap", { ...access, reason: e.kind });
    default:
      return new OpError(404, "not_found", "no such document", { ...access, reason: e.kind });
  }
}

const allow = (a: Authorized, path: string | null): Access => ({ collection: a.collection, corpus: a.corpusLabel, path, verdict: "allow", reason: null });

const listCollections = defineOp({
  name: "list_collections",
  description: "List the collections this key may search and read. Other collections are never revealed.",
  input: z.object({}),
  run: async (_deps, principal) => {
    const collections = usableOf(principal);
    return {
      data: { collections, default: collections[0] ?? null },
      accesses: [{ collection: collections.join(",") || null, corpus: null, path: null, verdict: "allow", reason: null }],
    };
  },
});

const qmdSearch = defineOp({
  name: "qmd_search",
  aliases: ["luna_search"],
  description:
    "Search the indexed collections with typed sub-queries (lex = keywords, vec = meaning, hyde = a hypothetical answer). Results carry collection, path, title, score, line and a snippet taken from the file itself.",
  input: z.object({
    searches: z.array(z.object({ type: z.enum(["lex", "vec", "hyde"]), query: z.string().min(1).max(1000) })).min(1).max(5),
    collections: z.array(CollectionName).min(1).max(20).optional(),
    limit: z.number().int().min(1).max(25).default(10),
    minScore: z.number().min(0).max(1).optional(),
  }),
  run: async (deps, principal, args, signal) => {
    const usable = usableOf(principal);
    const requested = unique(args.collections ?? usable);
    const skipped = requested.filter((c) => !usable.includes(c));
    const effective: Authorized[] = [];
    let firstReason: string | null = null;
    for (const collection of requested.filter((c) => usable.includes(c))) {
      try {
        effective.push(await authorize(deps, principal, collection, null));
      } catch (e) {
        if (!(e instanceof OpError)) throw e;
        skipped.push(collection);
        firstReason ??= e.access.reason ?? e.code;
      }
    }
    if (effective.length === 0) {
      const none = skipped.every((c) => !usable.includes(c));
      throw new OpError(403, none ? "collection_forbidden" : "egress_denied", "no requested collection is available to this key", {
        collection: skipped.join(",") || null,
        reason: none ? "collection-not-allowed" : (firstReason ?? "egress-denied"),
      });
    }
    const names = effective.map((a) => a.collection);
    const corpus = unique(effective.flatMap((a) => a.corpora)).join(",");
    const denyAccess = { collection: names.join(","), corpus };
    if (!deps.limiter.take(principal.keyId)) {
      throw new OpError(429, "rate_limited", "search rate limit reached", { ...denyAccess, reason: "rate-limit" });
    }
    let raw;
    try {
      raw = await deps.qmd.search(
        { searches: args.searches, collections: names, limit: Math.min(args.limit * 2, SEARCH_OVERFETCH_CAP), minScore: args.minScore },
        signal,
      );
    } catch (e) {
      if (!(e instanceof QmdUnavailable)) throw e;
      const timeout = e.kind === "timeout";
      throw new OpError(timeout ? 504 : 503, timeout ? "qmd_timeout" : "qmd_unavailable", "search backend is unavailable", { ...denyAccess, reason: `qmd-${e.kind}` });
    }
    const terms = unique(args.searches.flatMap((s) => s.query.split(/[^\p{L}\p{N}_-]+/u))).slice(0, 12);
    const { hits } = await verifyHits(raw, {
      collections: new Map(effective.map((a) => [a.collection, { root: a.root, scope: a.scope }])),
      terms,
      limit: args.limit,
    });
    return {
      data: { collections: names, skipped, hits },
      accesses: [{ ...denyAccess, path: null, verdict: "allow", reason: skipped.length > 0 ? `skipped:${skipped.join(",")}` : null }],
    };
  },
});

const readDocOp = defineOp({
  name: "read_doc",
  aliases: ["luna_read_note"],
  description: "Read one markdown note by collection and path. Returns content, sha256, size and mtime. Capped at 512 KiB.",
  input: z.object({ collection: CollectionName.optional(), path: DocPath }),
  run: async (deps, principal, args) => {
    const collection = collectionOrDefault(principal, args.collection, args.path);
    const az = await authorize(deps, principal, collection, args.path);
    try {
      const doc = await readDoc(az.root, collection, args.path, az.scope);
      return { data: doc, accesses: [allow(az, doc.path)] };
    } catch (e) {
      throw deniedToOpError(e, { collection, corpus: az.corpusLabel, path: clip(args.path) });
    }
  },
});

const multiRead = defineOp({
  name: "multi_read",
  description: "Read up to 10 notes in one call, 1 MiB in total. Each entry succeeds or fails on its own.",
  input: z.object({ entries: z.array(z.object({ collection: CollectionName.optional(), path: DocPath })).min(1).max(10) }),
  run: async (deps, principal, args) => {
    let total = 0;
    const results: unknown[] = [];
    const accesses: Access[] = [];
    for (const entry of args.entries) {
      let collection: string | undefined = entry.collection;
      let az: Authorized | undefined;
      try {
        collection = collectionOrDefault(principal, entry.collection, entry.path);
        az = await authorize(deps, principal, collection, entry.path);
        let doc: DocResult;
        try {
          doc = await readDoc(az.root, collection, entry.path, az.scope);
        } catch (e) {
          throw deniedToOpError(e, { collection, corpus: az.corpusLabel, path: clip(entry.path) });
        }
        if (total + doc.size > MULTI_READ_CAP_BYTES) {
          throw new OpError(413, "aggregate_cap", "aggregate read cap reached", { collection, corpus: az.corpusLabel, path: doc.path, reason: "aggregate-cap" });
        }
        total += doc.size;
        results.push({ ok: true, ...doc });
        accesses.push(allow(az, doc.path));
      } catch (e) {
        if (!(e instanceof OpError)) throw e;
        results.push({ ok: false, collection: collection ?? null, path: entry.path, error: { status: e.status, code: e.code } });
        accesses.push({
          collection: e.access.collection ?? collection ?? null,
          corpus: e.access.corpus ?? az?.corpusLabel ?? null,
          path: e.access.path ?? clip(entry.path),
          verdict: "deny",
          reason: e.access.reason ?? e.code,
        });
      }
    }
    return { data: { results }, accesses };
  },
});

const listDirOp = defineOp({
  name: "list_dir",
  description: "List one directory of a collection, paginated. Pass the returned nextCursor to continue.",
  input: z.object({
    collection: CollectionName.optional(),
    dir: z.string().max(1024).optional(),
    cursor: z.string().regex(/^[A-Za-z0-9_-]{1,512}$/).optional(),
    limit: z.number().int().min(1).max(100).default(50),
  }),
  run: async (deps, principal, args) => {
    const collection = collectionOrDefault(principal, args.collection, args.dir ?? "");
    const az = await authorize(deps, principal, collection, args.dir ?? "");
    try {
      const page = await listDir(az.root, args.dir, az.scope, { cursor: args.cursor, limit: args.limit });
      return { data: { collection, ...page }, accesses: [allow(az, page.dir)] };
    } catch (e) {
      throw deniedToOpError(e, { collection, corpus: az.corpusLabel, path: clip(args.dir ?? "") });
    }
  },
});

const recentDocsOp = defineOp({
  name: "recent_docs",
  description: "List the most recently modified markdown notes of a collection, newest first.",
  input: z.object({ collection: CollectionName.optional(), limit: z.number().int().min(1).max(50).default(20) }),
  run: async (deps, principal, args) => {
    const collection = collectionOrDefault(principal, args.collection, null);
    const az = await authorize(deps, principal, collection, null);
    try {
      const out = await recentDocs(az.root, az.scope, args.limit, RECENT_WALK_BUDGET);
      return { data: { collection, ...out }, accesses: [allow(az, null)] };
    } catch (e) {
      throw deniedToOpError(e, { collection, corpus: az.corpusLabel });
    }
  },
});

export const OPERATIONS: readonly OperationDef[] = [listCollections, qmdSearch, readDocOp, multiRead, listDirOp, recentDocsOp];

export function findOperation(name: string): OperationDef | undefined {
  return OPERATIONS.find((op) => op.name === name || op.aliases.includes(name));
}
