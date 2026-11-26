import assert from "node:assert/strict";
import { chmod, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, it } from "node:test";
import { type PolicyScope } from "../src/paths.js";
import { createQmdProxy, QmdUnavailable, RateLimiter, verifyHits, type QmdRawHit, type VerifyContext } from "../src/qmd-proxy.js";
import { buildFixture, makeClock, PHI, qmdHit, QMD_TOKEN, scratch, LEAK, startFakeQmd } from "./helpers.js";

const searches = [{ type: "lex" as const, query: "needle" }];

async function proxyFor(t: import("node:test").TestContext, over: { timeoutSignal?: (ms: number) => AbortSignal; mode?: number } = {}) {
  const dir = await scratch(t);
  const tokenFile = join(dir, "qmd-http-token");
  await writeFile(tokenFile, QMD_TOKEN, { mode: over.mode ?? 0o600 });
  await chmod(tokenFile, over.mode ?? 0o600);
  const qmd = await startFakeQmd(t);
  const proxy = createQmdProxy({ url: qmd.url, tokenFile, timeoutMs: 5000, ...(over.timeoutSignal ? { timeoutSignal: over.timeoutSignal } : {}) });
  return { dir, tokenFile, qmd, proxy };
}

describe("QMD proxy request", () => {
  it("posts typed searches with explicit collections, the bearer token and no Origin header", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    qmd.reply([{ file: "qmd://luna/a.md", title: "A", score: 0.5 }]);
    const hits = await proxy.search({ searches, collections: ["luna", "himmel"], limit: 7, minScore: 0.2 });
    assert.deepEqual(hits, [{ file: "qmd://luna/a.md", title: "A", score: 0.5 }]);
    assert.equal(qmd.requests.length, 1);
    const req = qmd.requests[0]!;
    assert.equal(req.method, "POST");
    assert.equal(req.url, "/query");
    assert.equal(req.headers["authorization"], `Bearer ${QMD_TOKEN}`);
    assert.equal(req.headers["origin"], undefined);
    assert.deepEqual(req.body, { searches, collections: ["luna", "himmel"], limit: 7, minScore: 0.2 });
  });

  it("refuses to forward an empty collections list", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    await assert.rejects(proxy.search({ searches, collections: [], limit: 5 }));
    assert.equal(qmd.requests.length, 0);
  });

  it("does not forward fields outside the typed request", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    await proxy.search({ searches, collections: ["luna"], limit: 3, filter: { x: 1 }, intent: "x", rerank: true } as never);
    assert.deepEqual(Object.keys(qmd.requests[0]!.body ?? {}).sort(), ["collections", "limit", "searches"]);
  });

  it("refuses a group-readable or missing token file without calling QMD", async (t) => {
    const loose = await proxyFor(t, { mode: 0o644 });
    await assert.rejects(loose.proxy.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "token");
    assert.equal(loose.qmd.requests.length, 0);
    const qmd = await startFakeQmd(t);
    const missing = createQmdProxy({ url: qmd.url, tokenFile: join(await scratch(t), "absent"), timeoutMs: 1000 });
    await assert.rejects(missing.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "token");
    assert.equal(qmd.requests.length, 0);
  });

  it("maps a refused connection to down", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    await qmd.stop();
    await assert.rejects(proxy.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "down");
  });

  it("maps a hung QMD to timeout through the injected signal", async (t) => {
    const ac = new AbortController();
    const { qmd, proxy } = await proxyFor(t, { timeoutSignal: () => ac.signal });
    qmd.setHandler(() => {
      ac.abort(new DOMException("timed out", "TimeoutError"));
    });
    await assert.rejects(proxy.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "timeout");
  });

  it("maps a non-200 answer and a malformed body to bad-response", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    qmd.setHandler((_req, res) => {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "boom" }));
    });
    await assert.rejects(proxy.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "bad-response");
    for (const body of ["not json", JSON.stringify({ nope: 1 }), JSON.stringify({ results: "x" })]) {
      qmd.setHandler((_req, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(body);
      });
      await assert.rejects(proxy.search({ searches, collections: ["luna"], limit: 5 }), (e: unknown) => e instanceof QmdUnavailable && e.kind === "bad-response", body);
    }
  });

  it("keeps only the file, title and score of each hit and skips malformed rows", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    qmd.reply([qmdHit("luna", "a.md", { metadata: { repo: "x" } }), { nofile: true }, "junk", null]);
    const hits = await proxy.search({ searches, collections: ["luna"], limit: 5 });
    assert.equal(hits.length, 1);
    assert.deepEqual(Object.keys(hits[0]!).sort(), ["file", "score", "title"]);
  });

  it("reports QMD reachability", async (t) => {
    const { qmd, proxy } = await proxyFor(t);
    assert.equal(await proxy.health(), true);
    await qmd.stop();
    assert.equal(await proxy.health(), false);
  });
});

describe("QMD proxy response cap", () => {
  it("stops reading and drops the connection once the answer passes the size cap", async (t) => {
    const dir = await scratch(t);
    const tokenFile = join(dir, "qmd-http-token");
    await writeFile(tokenFile, QMD_TOKEN, { mode: 0o600 });
    const qmd = await startFakeQmd(t);
    const total = 200;
    const chunk = Buffer.alloc(64 * 1024, 0x61);
    let written = 0;
    let finished = false;
    let closed!: () => void;
    const connectionClosed = new Promise<void>((resolve) => (closed = resolve));
    qmd.setHandler((_req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.on("close", closed);
      const pump = (): void => {
        while (written < total) {
          written++;
          if (!res.write(chunk)) {
            res.once("drain", pump);
            return;
          }
        }
        finished = true;
        res.end();
      };
      pump();
    });
    const proxy = createQmdProxy({ url: qmd.url, tokenFile, timeoutMs: 5000, maxResponseBytes: 1024 });
    await assert.rejects(
      proxy.search({ searches, collections: ["luna"], limit: 5 }),
      (e: unknown) => e instanceof QmdUnavailable && e.kind === "bad-response",
    );
    await connectionClosed;
    assert.equal(finished, false);
    assert.ok(written < total, `server wrote ${written} of ${total} chunks`);
  });

  it("refuses at once when the declared length is already over the cap", async (t) => {
    const dir = await scratch(t);
    const tokenFile = join(dir, "qmd-http-token");
    await writeFile(tokenFile, QMD_TOKEN, { mode: 0o600 });
    const qmd = await startFakeQmd(t);
    qmd.setHandler((_req, res) => {
      res.writeHead(200, { "content-type": "application/json", "content-length": String(10_000_000) });
      res.write("{");
    });
    const proxy = createQmdProxy({ url: qmd.url, tokenFile, timeoutMs: 5000, maxResponseBytes: 1024 });
    await assert.rejects(
      proxy.search({ searches, collections: ["luna"], limit: 5 }),
      (e: unknown) => e instanceof QmdUnavailable && e.kind === "bad-response",
    );
  });

  it("still reads an answer that fits under the cap", async (t) => {
    const dir = await scratch(t);
    const tokenFile = join(dir, "qmd-http-token");
    await writeFile(tokenFile, QMD_TOKEN, { mode: 0o600 });
    const qmd = await startFakeQmd(t);
    qmd.reply([qmdHit("luna", "a.md")]);
    const proxy = createQmdProxy({ url: qmd.url, tokenFile, timeoutMs: 5000, maxResponseBytes: 4096 });
    assert.equal((await proxy.search({ searches, collections: ["luna"], limit: 5 })).length, 1);
  });
});

describe("RateLimiter", () => {
  it("admits up to the cap per window per key and recovers when the clock advances", () => {
    const clock = makeClock(1_000_000);
    const limiter = new RateLimiter(2, 60_000, clock.now);
    assert.equal(limiter.take("k1"), true);
    assert.equal(limiter.take("k1"), true);
    assert.equal(limiter.take("k1"), false);
    assert.equal(limiter.take("k2"), true);
    clock.advance(59_999);
    assert.equal(limiter.take("k1"), false);
    clock.advance(2);
    assert.equal(limiter.take("k1"), true);
  });
});

describe("verifyHits", () => {
  const reader: PolicyScope = { vault: true, roles: ["reader"], allowHandoversRead: false };
  const plain: PolicyScope = { vault: false, roles: ["reader"], allowHandoversRead: false };

  async function ctx(t: import("node:test").TestContext, over: Partial<VerifyContext> = {}): Promise<VerifyContext> {
    const fx = await buildFixture(t);
    return {
      collections: new Map([
        ["luna", { root: fx.roots.get("luna")!, scope: reader }],
        ["himmel", { root: fx.roots.get("himmel")!, scope: plain }],
      ]),
      terms: ["needle"],
      limit: 10,
      ...over,
    };
  }

  const hit = (collection: string, path: string, extra: Record<string, unknown> = {}): QmdRawHit => qmdHit(collection, path, extra) as unknown as QmdRawHit;

  it("returns title and snippet generated from the verified file, never QMD's own", async (t) => {
    const out = await verifyHits([hit("luna", "30-Resources/note one.md", { title: "FORGED TITLE", snippet: "FORGED SNIPPET", context: "FORGED CONTEXT", metadata: { x: "FORGED META" } })], await ctx(t));
    assert.equal(out.hits.length, 1);
    const h = out.hits[0]!;
    assert.equal(h.collection, "luna");
    assert.equal(h.path, "30-Resources/note one.md");
    assert.equal(h.title, "Note One");
    assert.match(h.snippet, /needle in spaced note/);
    assert.ok(h.line >= 1);
    const text = JSON.stringify(out);
    for (const forged of ["FORGED", "qmd title", "qmd snippet", "qmd context", "abc123"]) assert.ok(!text.includes(forged), forged);
  });

  it("round-trips percent-encoded names with spaces and a literal percent", async (t) => {
    const out = await verifyHits([hit("luna", "30-Resources/note one.md"), hit("luna", "30-Resources/100% real.md")], await ctx(t));
    assert.deepEqual(out.hits.map((h) => h.path), ["30-Resources/note one.md", "30-Resources/100% real.md"]);
  });

  it("drops a hit from a collection outside the effective set", async (t) => {
    const out = await verifyHits([hit("jira-himmel", "HIM-1.md"), hit("salus", "x.md"), hit("luna", "docs/guide.md")], await ctx(t));
    assert.deepEqual(out.hits.map((h) => `${h.collection}/${h.path}`), ["luna/docs/guide.md"]);
    assert.equal(out.dropped, 2);
  });

  it("drops an unresolved legacy handelize slug without guessing the dotted path", async (t) => {
    const out = await verifyHits([hit("luna", "30-Resources/sub/claude/x.md"), hit("luna", "30-Resources/claude/x.md")], await ctx(t));
    assert.deepEqual(out.hits.map((h) => h.path), ["30-Resources/claude/x.md"]);
    assert.ok(!JSON.stringify(out).includes(LEAK));
  });

  it("drops dot-segment, kernel and role-path hits", async (t) => {
    const raw = [
      hit("luna", "30-Resources/sub/.claude/x.md"),
      hit("luna", "30-Resources/sub/.config/x.md"),
      hit("luna", "60-Maps/.obsidian/x.md"),
      hit("luna", "scripts/vault-autosync.sh"),
      hit("luna", "sessions/2026/07/2026-07-15-0821-salus-master.md"),
      hit("luna", "chats/c1.md"),
      hit("luna", "handovers/h1.md"),
      hit("luna", "CLAUDE.md"),
    ];
    const out = await verifyHits(raw, await ctx(t));
    assert.deepEqual(out.hits.map((h) => h.path), ["CLAUDE.md"]);
    assert.equal(out.dropped, 7);
    const text = JSON.stringify(out);
    assert.ok(!text.includes(LEAK) && !text.includes(PHI));
  });

  it("drops a repo: salus note and a stale hit whose disk file now carries repo: salus", async (t) => {
    const out = await verifyHits([hit("luna", "30-Resources/salus-note.md"), hit("luna", "30-Resources/stale.md", { snippet: "a perfectly clean stale snippet" }), hit("luna", "30-Resources/plain.md")], await ctx(t));
    assert.deepEqual(out.hits.map((h) => h.path), ["30-Resources/plain.md"]);
    const text = JSON.stringify(out);
    assert.ok(!text.includes(PHI) && !text.includes("clean stale snippet") && !text.includes("Was clean"));
  });

  it("drops forged URIs with encoded traversal, separators and NUL", async (t) => {
    const forged = ["qmd://luna/%2e%2e/outside/secret.md", "qmd://luna/a%2f..%2f..%2foutside%2fsecret.md", "qmd://luna/a%5cb.md", "qmd://luna/a%00.md", "qmd://luna/%252e%252e/x.md", "file:///etc/passwd", "qmd://luna"].map((file) => ({ file }) as QmdRawHit);
    const out = await verifyHits(forged, await ctx(t));
    assert.equal(out.hits.length, 0);
    assert.equal(out.dropped, forged.length);
  });

  it("stops at the limit and does not read past it", async (t) => {
    const out = await verifyHits([hit("luna", "docs/guide.md"), hit("luna", "CLAUDE.md"), hit("luna", "30-Resources/plain.md")], await ctx(t, { limit: 2 }));
    assert.equal(out.hits.length, 2);
  });
});
