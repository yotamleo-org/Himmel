#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { realpathSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import { createMcpHandler, McpServer, type AuthInfo } from "@modelcontextprotocol/server";
import { createAudit, defaultAuditFile, type Audit } from "./audit.js";
import { bearerGate, checkHostAndOrigin, defaultKeysFile, KeyStore, principalFrom, type AuthTrace, type Principal } from "./auth.js";
import { dispatch, fail, type DispatchResult } from "./core/dispatch.js";
import { OPERATIONS } from "./core/operations.js";
import { createEgress, PURPOSE, type Egress } from "./egress.js";
import { createQmdProxy, RateLimiter, type QmdProxy } from "./qmd-proxy.js";
import { loadRoots } from "./vault-fs.js";
import { join } from "node:path";
import { homedir } from "node:os";

export interface AppDeps {
  publicUrl: URL;
  keys: KeyStore;
  audit: Audit;
  egress: Egress;
  qmd: QmdProxy;
  roots: ReadonlyMap<string, string>;
  limiter: RateLimiter;
  newReqId: () => string;
  version: string;
}

export interface App {
  fetch(req: Request): Promise<Response>;
  close(): Promise<void>;
}

export interface Config {
  himmelRepo: string;
  publicUrl: URL;
  keysFile: string;
  auditFile: string;
  qmdUrl: string;
  qmdTokenFile: string;
  host: string;
  port: number;
  searchPerMinute: number;
  searchTimeoutMs: number;
}

export class ConfigError extends Error {}

const MCP_PATH = "/luna/mcp";
const HEALTH_PATH = "/luna/health";
const OPS_PREFIX = "/luna/v1/ops/";
const OP_NAME = /^[A-Za-z0-9_]{1,64}$/;
const SAFE_TOOL = /^[a-z_]{1,32}$/;
const MAX_BODY_BYTES = 256 * 1024;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost"]);

const json = (status: number, body: unknown, extra: Record<string, string> = {}): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } });

const fromDispatch = (r: DispatchResult): Response => json(r.status, r.body);

async function readLimited(req: Request, max: number): Promise<string | null> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export function createApp(deps: AppDeps): App {
  const audit = async (trace: AuthTrace, reqId: string, tool: string, reason: string): Promise<void> => {
    try {
      await deps.audit.write({
        reqId,
        principal: trace.principal?.principal ?? null,
        keyId: trace.principal?.keyId ?? null,
        role: trace.principal?.roles.join(",") ?? null,
        collection: null,
        corpus: null,
        provider: trace.principal?.provider ?? null,
        purpose: PURPOSE,
        path: null,
        tool,
        verdict: "deny",
        reason,
      });
    } catch {
      process.stderr.write("luna-mcp: audit write failed for a refused request\n");
    }
  };

  const dispatchDeps = { roots: deps.roots, egress: deps.egress, qmd: deps.qmd, limiter: deps.limiter, audit: deps.audit };

  const factory = ({ authInfo }: { authInfo?: AuthInfo }): McpServer => {
    const principal: Principal | null = authInfo ? principalFrom(authInfo) : null;
    const server = new McpServer({ name: "luna-mcp", version: deps.version });
    for (const op of OPERATIONS) {
      for (const name of [op.name, ...op.aliases]) {
        server.registerTool(name, { description: op.description, inputSchema: op.input }, async (args: unknown) => {
          const result = principal ? await dispatch(dispatchDeps, principal, name, args, deps.newReqId()) : fail(401, "unauthorized", "no verified principal");
          const text = result.body.ok ? JSON.stringify(result.body.result) : JSON.stringify({ error: result.body.error });
          return { content: [{ type: "text" as const, text }], ...(result.body.ok ? {} : { isError: true }) };
        });
      }
    }
    return server;
  };
  const mcp = createMcpHandler(factory, { maxRequestBodySize: MAX_BODY_BYTES });

  async function authenticate(req: Request, reqId: string, tool: string): Promise<{ info: AuthInfo } | { refusal: Response }> {
    const trace: AuthTrace = {};
    const out = await bearerGate(deps.keys, deps.publicUrl, trace)(req);
    if (out instanceof Response) {
      await audit(trace, reqId, tool, trace.reason ?? "auth");
      return { refusal: out };
    }
    return { info: out };
  }

  async function handle(req: Request): Promise<Response> {
    const reqId = deps.newReqId();
    const url = new URL(req.url);
    const path = url.pathname;
    const isOps = path.startsWith(OPS_PREFIX);
    const opName = isOps ? path.slice(OPS_PREFIX.length) : "";

    const bad = checkHostAndOrigin(req, deps.publicUrl);
    if (bad) {
      await audit({}, reqId, "http", bad);
      return json(403, { ok: false, error: { code: "forbidden_origin", message: `${bad} not allowed` } });
    }

    if (path === HEALTH_PATH) {
      if (req.method !== "GET") return json(405, { ok: false, error: { code: "method_not_allowed", message: "use GET" } }, { allow: "GET" });
      const up = await deps.qmd.health();
      return json(200, { status: up ? "ok" : "degraded", qmd: up ? "up" : "down" });
    }

    if (path === MCP_PATH) {
      if (req.method !== "POST") return json(405, { ok: false, error: { code: "method_not_allowed", message: "use POST" } }, { allow: "POST" });
      const auth = await authenticate(req, reqId, "mcp");
      if ("refusal" in auth) return auth.refusal;
      return mcp.fetch(req, { authInfo: auth.info });
    }

    if (isOps && OP_NAME.test(opName)) {
      if (req.method !== "POST") return json(405, { ok: false, error: { code: "method_not_allowed", message: "use POST" } }, { allow: "POST" });
      const tool = SAFE_TOOL.test(opName) ? opName : "invalid";
      const auth = await authenticate(req, reqId, tool);
      if ("refusal" in auth) return auth.refusal;
      const type = (req.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase();
      if (type !== "application/json") return json(415, { ok: false, error: { code: "unsupported_media_type", message: "send application/json" } });
      const text = await readLimited(req, MAX_BODY_BYTES);
      if (text === null) return json(413, { ok: false, error: { code: "payload_too_large", message: "request body too large" } });
      let args: unknown;
      try {
        args = text === "" ? {} : JSON.parse(text);
      } catch {
        return json(400, { ok: false, error: { code: "invalid_json", message: "body is not valid JSON" } });
      }
      return fromDispatch(await dispatch(dispatchDeps, principalFrom(auth.info), opName, args, reqId, req.signal));
    }

    return json(404, { ok: false, error: { code: "not_found", message: "no such route" } });
  }

  return {
    async fetch(req) {
      try {
        return await handle(req);
      } catch (e) {
        process.stderr.write(`luna-mcp: request failed: ${e instanceof Error ? e.name : "error"}\n`);
        return json(500, { ok: false, error: { code: "internal_error", message: "internal error" } });
      }
    },
    close: () => mcp.close(),
  };
}

function positiveInt(env: NodeJS.ProcessEnv, name: string, fallback: number, min: number, max: number): number {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!/^\d+$/.test(raw) || n < min || n > max) throw new ConfigError(`${name} must be an integer from ${min} to ${max}`);
  return n;
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const himmelRepo = env["HIMMEL_REPO"];
  if (!himmelRepo) throw new ConfigError("HIMMEL_REPO is required");
  const rawPublic = env["LUNA_MCP_PUBLIC_URL"];
  if (!rawPublic) throw new ConfigError("LUNA_MCP_PUBLIC_URL is required");
  let publicUrl: URL;
  try {
    publicUrl = new URL(rawPublic);
  } catch {
    throw new ConfigError("LUNA_MCP_PUBLIC_URL is not a URL");
  }
  if (publicUrl.protocol !== "https:" || publicUrl.pathname !== MCP_PATH || publicUrl.search !== "" || publicUrl.hash !== "") {
    throw new ConfigError(`LUNA_MCP_PUBLIC_URL must be an https URL ending in ${MCP_PATH}`);
  }
  const host = env["LUNA_MCP_HOST"] || "127.0.0.1";
  if (!LOOPBACK_HOSTS.has(host)) throw new ConfigError("LUNA_MCP_HOST must be a loopback address");
  const qmdUrl = env["QMD_URL"] || "http://localhost:8181";
  let qmdParsed: URL;
  try {
    qmdParsed = new URL(qmdUrl);
  } catch {
    throw new ConfigError("QMD_URL is not a URL");
  }
  if (qmdParsed.protocol !== "http:" && qmdParsed.protocol !== "https:") throw new ConfigError("QMD_URL must be http or https");
  const configHome = env["XDG_CONFIG_HOME"] || join(env["HOME"] || homedir(), ".config");
  return {
    himmelRepo,
    publicUrl,
    keysFile: env["LUNA_MCP_KEYS_FILE"] || defaultKeysFile(env),
    auditFile: env["LUNA_MCP_AUDIT_FILE"] || defaultAuditFile(env),
    qmdUrl,
    qmdTokenFile: env["QMD_HTTP_TOKEN_FILE"] || join(configHome, "qmd", "http-token"),
    host,
    port: positiveInt(env, "LUNA_MCP_PORT", 8190, 0, 65535),
    searchPerMinute: positiveInt(env, "LUNA_MCP_SEARCH_RATE_PER_MIN", 10, 1, 600),
    searchTimeoutMs: positiveInt(env, "LUNA_MCP_SEARCH_TIMEOUT_MS", 15000, 100, 120000),
  };
}

function toWebRequest(req: IncomingMessage, res: ServerResponse): Request {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  const abort = new AbortController();
  res.on("close", () => {
    if (!res.writableFinished) abort.abort();
  });
  const method = req.method ?? "GET";
  const hasBody = method !== "GET" && method !== "HEAD";
  const host = headers.get("host") ?? "localhost";
  return new Request(`http://${host.replace(/[^A-Za-z0-9.:\-[\]]/g, "")}${req.url ?? "/"}`, {
    method,
    headers,
    signal: abort.signal,
    ...(hasBody ? { body: req as unknown as BodyInit, duplex: "half" } : {}),
  } as RequestInit);
}

async function writeWebResponse(out: Response, res: ServerResponse): Promise<void> {
  res.writeHead(out.status, Object.fromEntries(out.headers));
  if (!out.body) {
    res.end();
    return;
  }
  for await (const chunk of out.body as unknown as AsyncIterable<Uint8Array>) {
    if (!res.write(chunk)) await new Promise<void>((resolve) => res.once("drain", resolve));
  }
  res.end();
}

export async function startServer(env: NodeJS.ProcessEnv): Promise<{ port: number; host: string; close(): Promise<void> }> {
  const config = loadConfig(env);
  const roots = await loadRoots(env);
  const app = createApp({
    publicUrl: config.publicUrl,
    keys: new KeyStore(config.keysFile, Date.now),
    audit: createAudit({ file: config.auditFile, now: Date.now }),
    egress: createEgress(config.himmelRepo),
    qmd: createQmdProxy({ url: config.qmdUrl, tokenFile: config.qmdTokenFile, timeoutMs: config.searchTimeoutMs }),
    roots,
    limiter: new RateLimiter(config.searchPerMinute, 60_000, Date.now),
    newReqId: randomUUID,
    version: "0.1.0",
  });
  const server = createServer((req, res) => {
    const target = req.url ?? "";
    if (!target.startsWith("/") || target.startsWith("//")) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: { code: "bad_request", message: "bad request target" } }));
      return;
    }
    void app
      .fetch(toWebRequest(req, res))
      .then((out) => writeWebResponse(out, res))
      .catch(() => {
        if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
        res.end();
      });
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.host, resolve);
  });
  const port = (server.address() as AddressInfo).port;
  return {
    port,
    host: config.host,
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await app.close();
    },
  };
}

function isMain(): boolean {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1] as string) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  startServer(process.env).then(
    (server) => {
      process.stderr.write(`luna-mcp: listening on ${server.host}:${server.port}\n`);
      const stop = (): void => {
        void server.close().finally(() => process.exit(0));
      };
      process.on("SIGTERM", stop);
      process.on("SIGINT", stop);
    },
    (e: unknown) => {
      process.stderr.write(`luna-mcp: cannot start: ${e instanceof Error ? e.message : "error"}\n`);
      process.exit(1);
    },
  );
}
