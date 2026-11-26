import { randomBytes } from "node:crypto";
import { copyFile, mkdir, mkdtemp, readFile, realpath, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { createServer, type IncomingHttpHeaders, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { createAudit, type AuditEntry } from "../src/audit.js";
import { hashKey, KeyStore, type KeyRecord, type Provider } from "../src/auth.js";
import { mintKey, type MintParams } from "../src/cli/keys.js";
import { createEgress } from "../src/egress.js";
import { createQmdProxy, RateLimiter } from "../src/qmd-proxy.js";
import { createApp, type App, type AppDeps } from "../src/server.js";

export const HOST = "example-node.example-tailnet.ts.net";
export const PUBLIC_URL = `https://${HOST}/luna/mcp`;
export const REPO_ROOT = fileURLToPath(new URL("../../../../../", import.meta.url));
export const PHI = "PHI-MARKER-7f3a91";
export const LEAK = "LEAK-MARKER-b41c07";
export const QMD_TOKEN = "fake-qmd-token-5d2e";

export interface Clock {
  now(): number;
  advance(ms: number): void;
}

export function makeClock(start: number = Date.now()): Clock {
  let t = start;
  return {
    now: () => t,
    advance: (ms) => {
      t += ms;
    },
  };
}

export async function scratch(t: TestContext): Promise<string> {
  const dir = await realpath(await mkdtemp(join(tmpdir(), "luna-mcp-")));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

export async function put(root: string, rel: string, content: string | Buffer, mtime?: number): Promise<void> {
  const file = join(root, rel);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, content);
  if (mtime !== undefined) await utimes(file, mtime / 1000, mtime / 1000);
}

export const note = (title: string, extra = ""): string => `# ${title}\n\nbody of ${title}\n${extra}`;
export const salusNote = (title: string): string =>
  `---\nrepo: salus\ntitle: ${title}\n---\n# ${title}\n\n${PHI}\n`;

export interface Fixture {
  base: string;
  roots: Map<string, string>;
  outside: string;
}

export async function buildFixture(t: TestContext): Promise<Fixture> {
  const base = await scratch(t);
  const luna = join(base, "luna");
  const lunaEvil = join(base, "luna-evil");
  const himmel = join(base, "himmel");
  const jira = join(base, "jira-himmel");
  const station = join(base, "station-ops");
  const outside = join(base, "outside");
  await put(outside, "secret.md", `${LEAK}\n`);
  await put(lunaEvil, "secret.md", `${LEAK}\n`);

  await put(luna, "CLAUDE.md", note("Luna rules"));
  await put(luna, "_Templates/note.md", note("Template"));
  await put(luna, "docs/guide.md", note("Guide"));
  await put(luna, "docs/deep/nested.md", note("Nested"));
  await put(luna, "30-Resources/note one.md", note("Note One", "needle in spaced note\n"));
  await put(luna, "30-Resources/100% real.md", note("Percent Real", "needle in percent note\n"));
  await put(luna, "30-Resources/plain.md", note("Plain"));
  await put(luna, "30-Resources/salus-note.md", salusNote("Clinical"));
  await put(luna, "30-Resources/stale.md", salusNote("Was clean"));
  await put(luna, "30-Resources/claude/x.md", note("Real claude dir"));
  await put(luna, "30-Resources/sub/.claude/x.md", `${LEAK}\n`);
  await put(luna, "30-Resources/sub/.config/x.md", `${LEAK}\n`);
  await put(luna, "60-Maps/.obsidian/x.md", `${LEAK}\n`);
  await put(luna, ".obsidian/plugins/x", `${LEAK}\n`);
  await put(luna, ".git/config", `${LEAK}\n`);
  await put(luna, ".env", `${LEAK}\n`);
  await put(luna, ".npmrc", `${LEAK}\n`);
  await put(luna, ".gitignore", `${LEAK}\n`);
  await put(luna, ".pre-commit-config.yaml", `${LEAK}\n`);
  await put(luna, ".gitleaks.toml", `${LEAK}\n`);
  await put(luna, "sessions/2026/07/2026-07-15-0821-salus-master.md", note("Session", PHI));
  await put(luna, "chats/c1.md", note("Chat", PHI));
  await put(luna, "handovers/h1.md", note("Handover", PHI));
  await put(luna, "scripts/vault-autosync.sh", `#!/bin/sh\n${LEAK}\n`);
  await put(luna, "marketplace/m.md", note("Market"));
  await put(luna, "graphify-out/g.md", note("Graph"));
  await put(luna, "to_be_deleted/d.md", note("Deleted"));
  await put(luna, "notes.txt", `${LEAK}\n`);
  await put(luna, "binary.md", Buffer.from([0x23, 0x20, 0x61, 0x00, 0x62]));
  await symlink(join(outside, "secret.md"), join(luna, "link-out.md"));
  await symlink(outside, join(luna, "linkdir"));
  await symlink(join(luna, "sessions"), join(luna, "alias-sessions"));
  await symlink(join(luna, "30-Resources", "plain.md"), join(luna, "alias-plain.md"));
  await symlink(join(lunaEvil, "secret.md"), join(luna, "prefix.md"));

  await put(himmel, "CLAUDE.md", note("Himmel rules"));
  await put(himmel, "docs/a.md", note("Himmel A"));
  await put(himmel, "scripts/foo.md", note("Scripts doc"));
  await put(jira, "HIM-1.md", note("Ticket one"));
  await put(station, "ops.md", note("Station ops"));

  const roots = new Map<string, string>([
    ["luna", luna],
    ["luna-pa", luna],
    ["himmel", himmel],
    ["jira-himmel", jira],
    ["station-ops", station],
    ["mystery", station],
  ]);
  return { base, roots, outside };
}

export interface RepoOptions {
  matrix?: unknown;
  corpus?: Record<string, unknown>;
  evalSource?: string;
  skip?: ("eval" | "matrix" | "corpus")[];
}

export async function buildRepo(t: TestContext, opts: RepoOptions = {}): Promise<string> {
  const repo = await scratch(t);
  const guard = join(repo, "scripts", "guardrails");
  await mkdir(guard, { recursive: true });
  await mkdir(join(repo, "scripts", "qmd"), { recursive: true });
  const skip = opts.skip ?? [];
  if (!skip.includes("eval")) {
    if (opts.evalSource !== undefined) await writeFile(join(guard, "egress-matrix-eval.mjs"), opts.evalSource);
    else await copyFile(join(REPO_ROOT, "scripts/guardrails/egress-matrix-eval.mjs"), join(guard, "egress-matrix-eval.mjs"));
  }
  if (!skip.includes("matrix")) {
    if (opts.matrix !== undefined) await writeFile(join(guard, "egress-matrix.json"), typeof opts.matrix === "string" ? opts.matrix : JSON.stringify(opts.matrix));
    else await copyFile(join(REPO_ROOT, "scripts/guardrails/egress-matrix.json"), join(guard, "egress-matrix.json"));
  }
  if (!skip.includes("corpus")) {
    if (opts.corpus !== undefined) await writeFile(join(repo, "scripts/qmd/qmd-collection-corpus.json"), JSON.stringify({ collections: opts.corpus }));
    else await copyFile(join(REPO_ROOT, "scripts/qmd/qmd-collection-corpus.json"), join(repo, "scripts/qmd/qmd-collection-corpus.json"));
  }
  return repo;
}

export function literalRule(corpus: string, provider: string, verdict = "allow+log"): Record<string, string> {
  return { corpus, provider, purpose: "luna-mcp-read", verdict, why: "test" };
}

export interface FakeRequest {
  method: string;
  url: string;
  headers: IncomingHttpHeaders;
  body: Record<string, unknown> | null;
}

export type FakeHandler = (req: FakeRequest, res: ServerResponse) => void;

export interface FakeQmd {
  url: string;
  requests: FakeRequest[];
  setHandler(handler: FakeHandler): void;
  reply(results: unknown[]): void;
  stop(): Promise<void>;
}

export async function startFakeQmd(t: TestContext): Promise<FakeQmd> {
  const requests: FakeRequest[] = [];
  let handler: FakeHandler = (_req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ results: [] }));
  };
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      let body: Record<string, unknown> | null = null;
      try {
        body = text ? (JSON.parse(text) as Record<string, unknown>) : null;
      } catch {
        body = null;
      }
      const fake: FakeRequest = { method: req.method ?? "", url: req.url ?? "", headers: req.headers, body };
      if (fake.url !== "/health") requests.push(fake);
      if (fake.url === "/health") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ status: "ok" }));
        return;
      }
      handler(fake, res);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  let stopped = false;
  const stop = async (): Promise<void> => {
    if (stopped) return;
    stopped = true;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  };
  t.after(stop);
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    setHandler: (h) => {
      handler = h;
    },
    reply: (results) => {
      handler = (_req, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ results }));
      };
    },
    stop,
  };
}

export function qmdHit(collection: string, path: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  return { docid: "#abc123", file: `qmd://${collection}/${encoded}`, title: "qmd title", score: 0.9, context: "qmd context", line: 1, snippet: "qmd snippet", ...extra };
}

export function keyRecord(token: string, clock: Clock, over: Partial<KeyRecord> = {}): KeyRecord {
  return {
    keyId: "key-test-1",
    hash: hashKey(token),
    principal: "grokbot",
    egressProvider: "xai-grokbot",
    resource: PUBLIC_URL,
    roles: ["reader"],
    allowedCollections: ["luna", "himmel"],
    createdAt: new Date(clock.now()).toISOString(),
    expiresAt: new Date(clock.now() + 24 * 3600_000).toISOString(),
    revoked: false,
    ...over,
  };
}

export async function writeKeysRaw(file: string, keys: unknown[], mode = 0o600, mtime?: number): Promise<void> {
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify({ version: 1, keys }), { mode });
  if (mtime !== undefined) await utimes(file, mtime / 1000, mtime / 1000);
}

export async function readAudit(file: string): Promise<AuditEntry[]> {
  let text = "";
  try {
    text = await readFile(file, "utf8");
  } catch {
    return [];
  }
  return text
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l) as AuditEntry);
}

export interface WorldOptions {
  searchPerMinute?: number;
  timeoutSignal?: (ms: number) => AbortSignal;
  repo?: string;
  auditFile?: string;
  roots?: Map<string, string>;
}

export interface Reply {
  status: number;
  body: any;
  headers: Headers;
}

export interface World {
  fx: Fixture;
  clock: Clock;
  repo: string;
  keysFile: string;
  auditFile: string;
  tokenFile: string;
  qmd: FakeQmd;
  app: App;
  deps: AppDeps;
  mint(over?: Partial<MintParams> & { ttlMs?: number }): Promise<{ token: string; keyId: string }>;
  ops(op: string, args: unknown, token: string | null, headers?: Record<string, string>): Promise<Reply>;
  mcp(method: string, params: unknown, token: string | null, headers?: Record<string, string>): Promise<Reply>;
  audit(): Promise<AuditEntry[]>;
}

export async function makeWorld(t: TestContext, opts: WorldOptions = {}): Promise<World> {
  const fx = await buildFixture(t);
  const clock = makeClock();
  const repo = opts.repo ?? (await buildRepo(t));
  const keysFile = join(fx.base, "config", "luna-mcp-keys.json");
  const auditFile = opts.auditFile ?? join(fx.base, "state", "luna-mcp-audit.jsonl");
  const tokenFile = join(fx.base, "qmd-http-token");
  await writeFile(tokenFile, QMD_TOKEN, { mode: 0o600 });
  const qmd = await startFakeQmd(t);
  const deps: AppDeps = {
    publicUrl: new URL(PUBLIC_URL),
    keys: new KeyStore(keysFile, clock.now),
    audit: createAudit({ file: auditFile, now: clock.now }),
    egress: createEgress(repo),
    qmd: createQmdProxy({
      url: qmd.url,
      tokenFile,
      timeoutMs: 5000,
      ...(opts.timeoutSignal ? { timeoutSignal: opts.timeoutSignal } : {}),
    }),
    roots: opts.roots ?? fx.roots,
    limiter: new RateLimiter(opts.searchPerMinute ?? 100, 60_000, clock.now),
    newReqId: (() => {
      let n = 0;
      return () => `req-${++n}`;
    })(),
    version: "0.0.0-test",
  };
  const app = createApp(deps);
  t.after(() => app.close());

  const send = async (path: string, init: { method: string; token: string | null; body?: string; headers?: Record<string, string> }): Promise<Reply> => {
    const headers: Record<string, string> = { host: HOST, ...(init.headers ?? {}) };
    if (init.token !== null) headers["authorization"] = `Bearer ${init.token}`;
    const res = await app.fetch(new Request(`https://${HOST}${path}`, { method: init.method, headers, ...(init.body !== undefined ? { body: init.body } : {}) }));
    const text = await res.text();
    let body: unknown = text;
    const ct = res.headers.get("content-type") ?? "";
    if (ct.includes("event-stream")) {
      const data = text.split("\n").find((l) => l.startsWith("data:"));
      body = data ? JSON.parse(data.slice(5)) : text;
    } else {
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = text;
      }
    }
    return { status: res.status, body, headers: res.headers };
  };

  return {
    fx,
    clock,
    repo,
    keysFile,
    auditFile,
    tokenFile,
    qmd,
    app,
    deps,
    mint: async (over = {}) => {
      const { ttlMs, ...rest } = over;
      const params: MintParams = {
        principal: "grokbot",
        provider: "xai-grokbot" as Provider,
        resource: PUBLIC_URL,
        roles: ["reader"],
        collections: ["luna", "himmel", "jira-himmel", "station-ops"],
        ttlMs: ttlMs ?? 24 * 3600_000,
        ...rest,
      };
      const minted = await mintKey(keysFile, params, { now: clock.now, randomBytes });
      return { token: minted.token, keyId: minted.keyId };
    },
    ops: (op, args, token, headers) =>
      send(`/luna/v1/ops/${op}`, { method: "POST", token, body: JSON.stringify(args), headers: { "content-type": "application/json", ...(headers ?? {}) } }),
    mcp: (method, params, token, headers) =>
      send("/luna/mcp", {
        method: "POST",
        token,
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...(headers ?? {}) },
      }),
    audit: () => readAudit(auditFile),
  };
}
