import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { request as httpRequest } from "node:http";
import { join } from "node:path";
import { describe, it, type TestContext } from "node:test";
import { hashKey, type Principal } from "../src/auth.js";
import { mintKey } from "../src/cli/keys.js";
import { dispatch } from "../src/core/dispatch.js";
import { OPERATIONS } from "../src/core/operations.js";
import { ConfigError, loadConfig, outcomeOf, startServer } from "../src/server.js";
import {
  buildRepo,
  HOST,
  keyRecord,
  literalRule,
  makeClock,
  makeWorld,
  PHI,
  PUBLIC_URL,
  qmdHit,
  QMD_TOKEN,
  GMAIL_QMD_TOKEN,
  scratch,
  LEAK,
  writeKeysRaw,
  type World,
} from "./helpers.js";

const NOTE_ONE = { collection: "luna", path: "30-Resources/note one.md" };

async function get(world: World, path: string, headers: Record<string, string> = { host: HOST }) {
  const res = await world.app.fetch(new Request(`https://${HOST}${path}`, { method: "GET", headers }));
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null, headers: res.headers };
}

async function lines(world: World) {
  return world.audit();
}

describe("transport and routing", () => {
  it("serves /luna/health without a key and reports QMD reachability", async (t) => {
    const world = await makeWorld(t);
    const up = await get(world, "/luna/health");
    assert.equal(up.status, 200);
    assert.deepEqual(up.body, { status: "ok", qmd: "up" });
    await world.qmd.stop();
    const down = await get(world, "/luna/health");
    assert.equal(down.status, 200);
    assert.deepEqual(down.body, { status: "degraded", qmd: "down" });
  });

  it("refuses health, ops and mcp on a disallowed Host", async (t) => {
    const world = await makeWorld(t);
    assert.equal((await get(world, "/luna/health", { host: "evil.example" })).status, 403);
    assert.equal((await get(world, "/luna/health", {})).status, 403);
  });

  it("answers 404 for unknown paths and 405 for a wrong method on the ops route", async (t) => {
    const world = await makeWorld(t);
    assert.equal((await get(world, "/luna/nope")).status, 404);
    assert.equal((await get(world, "/")).status, 404);
    assert.equal((await get(world, "/luna/v1/ops/read_doc")).status, 405);
    assert.equal((await get(world, "/luna/v1/ops/")).status, 404);
  });

  it("rejects a non-JSON content type, malformed JSON and an oversized body on the ops route", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    assert.equal((await world.ops("list_collections", {}, token, { "content-type": "text/plain" })).status, 415);
    const bad = await world.app.fetch(new Request(`https://${HOST}/luna/v1/ops/list_collections`, { method: "POST", headers: { host: HOST, authorization: `Bearer ${token}`, "content-type": "application/json" }, body: "{nope" }));
    assert.equal(bad.status, 400);
    const big = await world.ops("read_doc", { path: "x".repeat(300 * 1024) }, token);
    assert.equal(big.status, 413);
  });

  it("answers 404 for an unknown operation and 400 for invalid arguments", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    const unknown = await world.ops("drop_tables", {}, token);
    assert.equal(unknown.status, 404);
    assert.equal(unknown.body.error.code, "unknown_operation");
    for (const [op, args] of [
      ["read_doc", {}],
      ["read_doc", { path: 5 }],
      ["read_doc", { path: "a.md", collection: "../etc" }],
      ["multi_read", { entries: [] }],
      ["multi_read", { entries: Array.from({ length: 11 }, () => ({ path: "CLAUDE.md" })) }],
      ["list_dir", { limit: 0 }],
      ["recent_docs", { limit: 51 }],
      ["qmd_search", { searches: [] }],
      ["qmd_search", { searches: [{ type: "sql", query: "x" }] }],
      ["qmd_search", { searches: [{ type: "lex", query: "x" }], limit: 26 }],
    ] as const) {
      const res = await world.ops(op, args, token);
      assert.equal(res.status, 400, `${op} ${JSON.stringify(args).slice(0, 60)}`);
      assert.equal(res.body.error.code, "invalid_arguments");
    }
    assert.equal(world.qmd.requests.length, 0);
  });
});

describe("authentication over the JSON API and MCP", () => {
  const surfaces = (world: World) => [
    { name: "ops", call: (token: string | null, headers?: Record<string, string>) => world.ops("list_collections", {}, token, headers) },
    { name: "mcp", call: (token: string | null, headers?: Record<string, string>) => world.mcp("tools/list", {}, token, headers) },
  ];

  it("refuses a missing, wrong, expired, revoked and wrong-resource bearer on both surfaces", async (t) => {
    const world = await makeWorld(t);
    const good = await world.mint();
    const { revokeKey } = await import("../src/cli/keys.js");
    const doomed = await world.mint({ principal: "doomed" });
    const shortLived = await world.mint({ principal: "short", ttlMs: 60_000 });
    const foreign = await world.mint({ principal: "foreign", resource: "https://other-node.example-tailnet.ts.net/luna/mcp" });
    await revokeKey(world.keysFile, doomed.keyId);
    world.clock.advance(61_000);
    for (const s of surfaces(world)) {
      assert.equal((await s.call(good.token)).status, 200, `${s.name} good`);
      assert.equal((await s.call(null)).status, 401, `${s.name} missing`);
      assert.equal((await s.call("not-a-real-key")).status, 401, `${s.name} wrong`);
      assert.equal((await s.call(shortLived.token)).status, 401, `${s.name} expired`);
      assert.equal((await s.call(doomed.token)).status, 401, `${s.name} revoked`);
      assert.equal((await s.call(foreign.token)).status, 401, `${s.name} wrong resource`);
    }
    const reasons = (await lines(world)).map((l) => l.reason);
    for (const r of ["auth", "unknown-key", "expired", "revoked", "resource-mismatch"]) assert.ok(reasons.includes(r), r);
    assert.equal(world.qmd.requests.length, 0);
  });

  it("refuses a disallowed Host and a forged Origin before authentication, even with a valid key", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    for (const s of surfaces(world)) {
      assert.equal((await s.call(token, { host: "evil.example" })).status, 403, `${s.name} host`);
      assert.equal((await s.call(token, { origin: "https://evil.example" })).status, 403, `${s.name} origin`);
      assert.equal((await s.call(token, { origin: `https://${HOST}` })).status, 200, `${s.name} same origin`);
    }
    const rows = await lines(world);
    assert.ok(rows.some((r) => r.reason === "host" && r.verdict === "deny" && r.principal === null));
    assert.ok(rows.some((r) => r.reason === "origin" && r.verdict === "deny"));
  });

  it("keeps old and new keys valid together during rotation until the old key expires", async (t) => {
    const world = await makeWorld(t);
    const old = await world.mint({ principal: "grokbot", ttlMs: 3600_000 });
    const next = await world.mint({ principal: "grokbot", ttlMs: 90 * 86400_000 });
    for (const s of surfaces(world)) {
      assert.equal((await s.call(old.token)).status, 200);
      assert.equal((await s.call(next.token)).status, 200);
    }
    world.clock.advance(3600_001);
    for (const s of surfaces(world)) {
      assert.equal((await s.call(old.token)).status, 401);
      assert.equal((await s.call(next.token)).status, 200);
    }
  });

  it("refuses a revoked key on the very next call", async (t) => {
    const world = await makeWorld(t);
    const { token, keyId } = await world.mint();
    assert.equal((await world.ops("list_collections", {}, token)).status, 200);
    const { revokeKey } = await import("../src/cli/keys.js");
    await revokeKey(world.keysFile, keyId);
    assert.equal((await world.ops("list_collections", {}, token)).status, 401);
  });
});

describe("collection scoping", () => {
  it("refuses a Luna-only key on himmel, jira-himmel and station-ops and serves it on luna-pa", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna-pa"] });
    const reads: [string, string][] = [["himmel", "docs/a.md"], ["jira-himmel", "HIM-1.md"], ["station-ops", "ops.md"], ["luna", "CLAUDE.md"]];
    for (const [collection, path] of reads) {
      const res = await world.ops("read_doc", { collection, path }, token);
      assert.equal(res.status, 403, collection);
      assert.equal(res.body.error.code, "collection_forbidden");
      assert.ok(!JSON.stringify(res.body).includes("body of"));
    }
    for (const collection of ["himmel", "jira-himmel", "station-ops"]) {
      const res = await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }], collections: [collection] }, token);
      assert.equal(res.status, 403, collection);
    }
    assert.equal(world.qmd.requests.length, 0);
    const ok = await world.ops("read_doc", { collection: "luna-pa", path: "CLAUDE.md" }, token);
    assert.equal(ok.status, 200);
    assert.match(ok.body.result.content, /Luna rules/);
    const listed = await world.ops("list_collections", {}, token);
    assert.deepEqual(listed.body.result, { collections: ["luna-pa"], default: "luna-pa" });
  });

  it("serves a full-QMD key across every allowed collection and lists exactly those", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    for (const [collection, path, needle] of [["luna", "CLAUDE.md", "Luna rules"], ["himmel", "docs/a.md", "Himmel A"], ["jira-himmel", "HIM-1.md", "Ticket one"], ["station-ops", "ops.md", "Station ops"]] as const) {
      const res = await world.ops("read_doc", { collection, path }, token);
      assert.equal(res.status, 200, collection);
      assert.match(res.body.result.content, new RegExp(needle));
    }
    const listed = await world.ops("list_collections", {}, token);
    assert.deepEqual(listed.body.result.collections, ["luna", "himmel", "jira-himmel", "station-ops"]);
  });

  it("defaults the collection to the first allowed one", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["himmel", "luna"] });
    const res = await world.ops("read_doc", { path: "docs/a.md" }, token);
    assert.equal(res.status, 200);
    assert.equal(res.body.result.collection, "himmel");
  });

  it("fails closed on a collection that is not mapped to an egress corpus", async (t) => {
    const world = await makeWorld(t);
    await writeKeysRaw(world.keysFile, [keyRecord("tok-mystery", world.clock, { allowedCollections: ["mystery", "himmel"] })]);
    const read = await world.ops("read_doc", { collection: "mystery", path: "ops.md" }, "tok-mystery");
    assert.equal(read.status, 403);
    assert.equal(read.body.error.code, "egress_denied");
    assert.ok(!JSON.stringify(read.body).includes("Station ops"));
    const search = await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }], collections: ["mystery"] }, "tok-mystery");
    assert.equal(search.status, 403);
    assert.equal(world.qmd.requests.length, 0);
    const rows = (await lines(world)).filter((l) => l.verdict === "deny");
    assert.ok(rows.some((r) => /unmapped/.test(r.reason ?? "")));
  });

  it("never reaches salus, even when a key file lists it", async (t) => {
    const world = await makeWorld(t);
    await writeKeysRaw(world.keysFile, [keyRecord("tok-salus", world.clock, { allowedCollections: ["luna", "salus"] })]);
    const read = await world.ops("read_doc", { collection: "salus", path: "x.md" }, "tok-salus");
    assert.equal(read.status, 403);
    const listed = await world.ops("list_collections", {}, "tok-salus");
    assert.deepEqual(listed.body.result.collections, ["luna"]);
    world.qmd.reply([]);
    const search = await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }] }, "tok-salus");
    assert.equal(search.status, 200);
    assert.deepEqual(world.qmd.requests[0]?.body?.["collections"], ["luna"]);
  });
});

describe("luna role-path gate across every surface", () => {
  const gated = ["sessions/2026/07/2026-07-15-0821-salus-master.md", "chats/c1.md", "handovers/h1.md"];

  it("refuses sessions, chats and handovers to a reader on read, multi_read, list, recent and search while docs stay readable", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    for (const path of gated) {
      const res = await world.ops("read_doc", { collection: "luna", path }, token);
      assert.equal(res.status, 403, path);
      assert.equal(res.body.error.code, "forbidden");
      assert.ok(!JSON.stringify(res.body).includes(PHI));
    }
    const multi = await world.ops("multi_read", { entries: [...gated.map((path) => ({ collection: "luna", path })), { collection: "luna", path: "CLAUDE.md" }] }, token);
    assert.equal(multi.status, 200);
    const results = multi.body.result.results;
    assert.deepEqual(results.map((r: { ok: boolean }) => r.ok), [false, false, false, true]);
    assert.ok(!JSON.stringify(multi.body).includes(PHI));
    for (const dir of ["sessions", "chats", "handovers", "sessions/2026"]) {
      assert.equal((await world.ops("list_dir", { collection: "luna", dir }, token)).status, 403, dir);
    }
    const root = await world.ops("list_dir", { collection: "luna" }, token);
    const names = root.body.result.entries.map((e: { name: string }) => e.name);
    for (const gone of ["sessions", "chats", "handovers"]) assert.ok(!names.includes(gone), gone);
    assert.ok(names.includes("CLAUDE.md") && names.includes("_Templates") && names.includes("docs"));
    const recent = await world.ops("recent_docs", { collection: "luna", limit: 50 }, token);
    assert.equal(recent.status, 200);
    for (const d of recent.body.result.docs) assert.ok(!/^(sessions|chats|handovers)\//.test(d.path), d.path);
    world.qmd.reply([...gated.map((p) => qmdHit("luna", p)), qmdHit("luna", "docs/guide.md")]);
    const search = await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }], collections: ["luna"] }, token);
    assert.equal(search.status, 200);
    assert.deepEqual(search.body.result.hits.map((h: { path: string }) => h.path), ["docs/guide.md"]);
    assert.ok(!JSON.stringify(search.body).includes(PHI));
    for (const path of ["CLAUDE.md", "_Templates/note.md", "docs/guide.md"]) {
      assert.equal((await world.ops("read_doc", { collection: "luna", path }, token)).status, 200, path);
    }
  });

  it("applies the same gate to a luna-pa key", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna-pa"] });
    for (const path of gated) assert.equal((await world.ops("read_doc", { collection: "luna-pa", path }, token)).status, 403, path);
  });
});

describe("dot-segment, kernel and path jail through the API", () => {
  const refused = [
    ".pre-commit-config.yaml",
    ".gitignore",
    ".gitleaks.toml",
    ".git/config",
    ".env",
    ".npmrc",
    ".obsidian/plugins/x",
    "30-Resources/sub/.claude/x.md",
    "30-Resources/sub/.config/x.md",
    "60-Maps/.obsidian/x.md",
    "scripts/vault-autosync.sh",
    "sessions/2026/07/2026-07-15-0821-salus-master.md",
    "../",
    "%2e%2e/%2e%2e/outside/secret.md",
    "a%2f..%2f..%2foutside%2fsecret.md",
    "a%5c..%5csecret.md",
    "a%00.md",
    "link-out.md",
    "linkdir/secret.md",
    "prefix.md",
    "alias-sessions/2026/07/2026-07-15-0821-salus-master.md",
    "é.md",
    "a\u0007b.md",
  ];

  it("refuses every dangerous read on read_doc and multi_read without leaking content", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    for (const path of refused) {
      const res = await world.ops("read_doc", { collection: "luna", path }, token);
      assert.ok(res.status === 403 || res.status === 404, `${path} -> ${res.status}`);
      const text = JSON.stringify(res.body);
      assert.ok(!text.includes(LEAK) && !text.includes(PHI), path);
    }
    const multi = await world.ops("multi_read", { entries: refused.slice(0, 10).map((path) => ({ collection: "luna", path })) }, token);
    assert.equal(multi.status, 200);
    for (const r of multi.body.result.results) assert.equal(r.ok, false);
    assert.ok(!JSON.stringify(multi.body).includes(LEAK));
  });

  it("answers a lexical refusal with 403 and every disk-state refusal with the same 404 as a missing file", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const dot = await world.ops("read_doc", { collection: "luna", path: ".env" }, token);
    assert.equal(dot.status, 403);
    const missing = await world.ops("read_doc", { collection: "luna", path: "30-Resources/missing.md" }, token);
    assert.equal(missing.status, 404);
    for (const path of ["30-Resources/salus-note.md", "link-out.md", "linkdir/secret.md", "alias-plain.md", "binary.md"]) {
      const res = await world.ops("read_doc", { collection: "luna", path }, token);
      assert.equal(res.status, 404, path);
      assert.deepEqual(res.body.error, missing.body.error, path);
    }
    const reasons = (await lines(world)).map((l) => l.reason);
    for (const r of ["salus", "escape", "symlink", "not-text", "dot-segment", "not-found"]) assert.ok(reasons.includes(r), r);
  });

  it("rejects an oversized note with 413", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    await writeFile(join(world.fx.roots.get("luna")!, "big.md"), Buffer.alloc(600 * 1024, 0x61));
    assert.equal((await world.ops("read_doc", { collection: "luna", path: "big.md" }, token)).status, 413);
  });

  it("caps multi_read at one MiB in aggregate", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const root = world.fx.roots.get("luna")!;
    for (const n of ["a", "b", "c"]) await writeFile(join(root, `${n}.md`), Buffer.alloc(400 * 1024, 0x61));
    const res = await world.ops("multi_read", { entries: ["a", "b", "c"].map((n) => ({ collection: "luna", path: `${n}.md` })) }, token);
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.result.results.map((r: { ok: boolean }) => r.ok), [true, true, false]);
    assert.equal(res.body.result.results[2].error.status, 413);
  });

  it("lists and paginates a directory through the API", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const first = await world.ops("list_dir", { collection: "luna", dir: "30-Resources", limit: 2 }, token);
    assert.equal(first.status, 200);
    assert.equal(first.body.result.entries.length, 2);
    assert.ok(first.body.result.nextCursor);
    const second = await world.ops("list_dir", { collection: "luna", dir: "30-Resources", limit: 2, cursor: first.body.result.nextCursor }, token);
    assert.equal(second.status, 200);
    const names = [...first.body.result.entries, ...second.body.result.entries].map((e: { name: string }) => e.name);
    assert.equal(new Set(names).size, names.length);
  });
});

describe("search contract", () => {
  const lex = [{ type: "lex", query: "needle" }];

  it("sends the key's non-empty allowed collections to QMD when none are requested", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    world.qmd.reply([]);
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 200);
    assert.equal(world.qmd.requests.length, 1);
    const sent = world.qmd.requests[0]!.body!;
    assert.deepEqual(sent["collections"], ["luna", "himmel", "jira-himmel", "station-ops"]);
    assert.equal(sent["searches"] instanceof Array, true);
    assert.equal(world.qmd.requests[0]!.headers["origin"], undefined);
    assert.equal(world.qmd.requests[0]!.headers["authorization"], `Bearer ${QMD_TOKEN}`);
  });

  it("never lets an empty collections list reach QMD", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    const res = await world.ops("qmd_search", { searches: lex, collections: [] }, token);
    assert.equal(res.status, 400);
    assert.equal(world.qmd.requests.length, 0);
  });

  it("intersects requested collections with the key and reports what it skipped", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna", "himmel"] });
    world.qmd.reply([]);
    const res = await world.ops("qmd_search", { searches: lex, collections: ["himmel", "jira-himmel", "salus"] }, token);
    assert.equal(res.status, 200);
    assert.deepEqual(world.qmd.requests[0]!.body!["collections"], ["himmel"]);
    assert.deepEqual(res.body.result.collections, ["himmel"]);
    assert.deepEqual(res.body.result.skipped, ["jira-himmel", "salus"]);
    const none = await world.ops("qmd_search", { searches: lex, collections: ["jira-himmel"] }, token);
    assert.equal(none.status, 403);
    assert.equal(world.qmd.requests.length, 1);
  });

  it("round-trips percent-encoded names with spaces and a literal percent from search to read", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([qmdHit("luna", "30-Resources/note one.md"), qmdHit("luna", "30-Resources/100% real.md")]);
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 200);
    const hits = res.body.result.hits as { collection: string; path: string; snippet: string }[];
    assert.deepEqual(hits.map((h) => h.path), ["30-Resources/note one.md", "30-Resources/100% real.md"]);
    for (const h of hits) {
      const read = await world.ops("read_doc", { collection: h.collection, path: h.path }, token);
      assert.equal(read.status, 200, h.path);
      assert.match(read.body.result.content, /needle in/);
    }
  });

  it("strips disallowed-collection hits, legacy slugs, salus notes and stale snippets, and forwards no QMD metadata", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([
      qmdHit("himmel", "docs/a.md"),
      qmdHit("luna", "30-Resources/sub/claude/x.md"),
      qmdHit("luna", "30-Resources/salus-note.md"),
      qmdHit("luna", "30-Resources/stale.md", { snippet: "clean stale snippet" }),
      qmdHit("luna", "30-Resources/sub/.claude/x.md"),
      qmdHit("luna", "scripts/vault-autosync.sh"),
      qmdHit("luna", "30-Resources/note one.md", { title: "FORGED", context: "FORGED CONTEXT", metadata: { repo: "FORGED META" }, snippet: "FORGED SNIPPET" }),
    ]);
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.result.hits.map((h: { path: string }) => h.path), ["30-Resources/note one.md"]);
    const text = JSON.stringify(res.body);
    for (const bad of [PHI, LEAK, "FORGED", "clean stale snippet", "Was clean", "docs/a.md", "abc123"]) assert.ok(!text.includes(bad), bad);
    assert.deepEqual(Object.keys(res.body.result.hits[0]).sort(), ["collection", "line", "path", "score", "snippet", "title"]);
  });

  it("answers luna_search and luna_read_note as aliases of the same operations", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([qmdHit("luna", "docs/guide.md")]);
    const search = await world.ops("luna_search", { searches: lex }, token);
    assert.equal(search.status, 200);
    assert.equal(search.body.result.hits.length, 1);
    const read = await world.ops("luna_read_note", { path: "docs/guide.md" }, token);
    assert.equal(read.status, 200);
    assert.match(read.body.result.content, /Guide/);
  });

  it("returns 503 when QMD is down while file reads keep working", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    await world.qmd.stop();
    const search = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(search.status, 503);
    assert.equal(search.body.error.code, "qmd_unavailable");
    assert.equal((await world.ops("read_doc", NOTE_ONE, token)).status, 200);
    assert.equal((await world.ops("list_dir", { collection: "luna" }, token)).status, 200);
    assert.equal((await world.ops("recent_docs", { collection: "luna" }, token)).status, 200);
    const denied = (await lines(world)).find((l) => l.reason === "qmd-down");
    assert.ok(denied);
  });

  it("trips the search rate limit at the cap and recovers when the window passes", async (t) => {
    const world = await makeWorld(t, { searchPerMinute: 2 });
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([]);
    assert.equal((await world.ops("qmd_search", { searches: lex }, token)).status, 200);
    assert.equal((await world.ops("qmd_search", { searches: lex }, token)).status, 200);
    const limited = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(limited.status, 429);
    assert.equal(limited.body.error.code, "rate_limited");
    assert.equal(world.qmd.requests.length, 2);
    assert.equal((await world.ops("read_doc", NOTE_ONE, token)).status, 200);
    world.clock.advance(61_000);
    assert.equal((await world.ops("qmd_search", { searches: lex }, token)).status, 200);
  });

  it("trips the search timeout when QMD never answers", async (t) => {
    const ac = new AbortController();
    const world = await makeWorld(t, { timeoutSignal: () => ac.signal });
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.setHandler(() => {
      ac.abort(new DOMException("timed out", "TimeoutError"));
    });
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 504);
    assert.equal(res.body.error.code, "qmd_timeout");
  });
});

describe("a named index searched on its own", () => {
  const lex = [{ type: "lex", query: "needle" }];
  const MAIL = "2026/11/invoice.md";

  it("sends a gmail-only search to the gmail daemon alone and returns verified hits", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna", "gmail"] });
    world.gmailQmd!.reply([qmdHit("gmail", MAIL), qmdHit("gmail", ".hidden/x.md"), qmdHit("luna", "CLAUDE.md"), qmdHit("gmail", "link-out.md")]);
    const res = await world.ops("qmd_search", { searches: lex, collections: ["gmail"] }, token);
    assert.equal(res.status, 200);
    assert.equal(world.qmd.requests.length, 0);
    assert.equal(world.gmailQmd!.requests.length, 1);
    assert.deepEqual(world.gmailQmd!.requests[0]!.body!["collections"], ["gmail"]);
    assert.equal(world.gmailQmd!.requests[0]!.headers["authorization"], `Bearer ${GMAIL_QMD_TOKEN}`);
    assert.ok(world.qmd.requests.every((r) => r.headers["authorization"] !== `Bearer ${GMAIL_QMD_TOKEN}`));
    assert.deepEqual(res.body.result.collections, ["gmail"]);
    assert.deepEqual(res.body.result.hits.map((h: { collection: string; path: string }) => [h.collection, h.path]), [["gmail", MAIL]]);
    assert.match(res.body.result.hits[0].snippet, /needle in mail/);
    assert.ok(!JSON.stringify(res.body).includes(LEAK));
  });

  it("keeps gmail out of a default search, on both backends", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna", "himmel", "gmail"] });
    world.qmd.reply([]);
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 200);
    assert.equal(world.gmailQmd!.requests.length, 0);
    assert.equal(world.qmd.requests.length, 1);
    assert.deepEqual(world.qmd.requests[0]!.body!["collections"], ["luna", "himmel"]);
    assert.equal(world.qmd.requests[0]!.headers["authorization"], `Bearer ${QMD_TOKEN}`);
    assert.deepEqual(res.body.result.collections, ["luna", "himmel"]);
  });

  it("tells a gmail-only key to name the collection instead of searching nothing", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["gmail"] });
    const res = await world.ops("qmd_search", { searches: lex }, token);
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, "isolated_collection");
    assert.equal(world.qmd.requests.length + world.gmailQmd!.requests.length, 0);
    assert.equal((await lines(world)).at(-1)!.reason, "isolated-default");
  });

  it("drops a gmail hit the shared daemon returns", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna", "gmail"] });
    world.qmd.reply([qmdHit("gmail", MAIL), qmdHit("luna", "docs/guide.md")]);
    const res = await world.ops("qmd_search", { searches: lex, collections: ["luna"] }, token);
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.result.hits.map((h: { path: string }) => h.path), ["docs/guide.md"]);
  });

  it("refuses gmail mixed with another collection before either daemon is called", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna", "gmail"] });
    const res = await world.ops("qmd_search", { searches: lex, collections: ["gmail", "luna"] }, token);
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, "isolated_collection");
    assert.match(res.body.error.message, /gmail/);
    assert.equal(world.qmd.requests.length, 0);
    assert.equal(world.gmailQmd!.requests.length, 0);
    const deny = (await lines(world)).filter((l) => l.verdict === "deny");
    assert.equal(deny.length, 1);
    assert.equal(deny[0]!.reason, "isolated-mixed");
    assert.equal(deny[0]!.tool, "qmd_search");
    assert.equal(deny[0]!.collection, "gmail,luna");
  });

  it("lets a key without gmail ask for gmail and luna and learn nothing about gmail", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([]);
    const res = await world.ops("qmd_search", { searches: lex, collections: ["gmail", "luna"] }, token);
    assert.equal(res.status, 200);
    assert.deepEqual(world.qmd.requests[0]!.body!["collections"], ["luna"]);
    assert.deepEqual(res.body.result.skipped, ["gmail"]);
    assert.equal(world.gmailQmd!.requests.length, 0);
    const alone = await world.ops("qmd_search", { searches: lex, collections: ["gmail"] }, token);
    assert.equal(alone.status, 403);
    assert.equal(alone.body.error.code, "collection_forbidden");
    assert.equal(world.gmailQmd!.requests.length, 0);
  });

  it("answers 503 for a gmail search when only the gmail daemon is down", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["luna", "gmail"] });
    await world.gmailQmd!.stop();
    const res = await world.ops("qmd_search", { searches: lex, collections: ["gmail"] }, token);
    assert.equal(res.status, 503);
    assert.equal(world.qmd.requests.length, 0);
  });

  it("denies gmail to a provider the matrix does not admit, on search and read", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ provider: "openai-chatgpt", collections: ["gmail"] });
    const search = await world.ops("qmd_search", { searches: lex, collections: ["gmail"] }, token);
    assert.equal(search.status, 403);
    assert.equal(search.body.error.code, "egress_denied");
    const read = await world.ops("read_doc", { collection: "gmail", path: MAIL }, token);
    assert.equal(read.status, 403);
    assert.ok(!JSON.stringify(read.body).includes("needle in mail"));
    assert.equal(world.gmailQmd!.requests.length, 0);
  });

  it("reads, lists and walks a gmail root under the same path jail", async (t) => {
    const world = await makeWorld(t, { gmail: true });
    const { token } = await world.mint({ collections: ["gmail"] });
    const read = await world.ops("read_doc", { path: MAIL }, token);
    assert.equal(read.status, 200);
    assert.equal(read.body.result.collection, "gmail");
    assert.match(read.body.result.content, /needle in mail/);
    const multi = await world.ops("multi_read", { entries: [{ collection: "gmail", path: MAIL }, { collection: "gmail", path: ".hidden/x.md" }] }, token);
    assert.equal(multi.body.result.results[0].ok, true);
    assert.equal(multi.body.result.results[1].ok, false);
    const listed = await world.ops("list_dir", { collection: "gmail", dir: "2026/11" }, token);
    assert.equal(listed.status, 200);
    assert.deepEqual(listed.body.result.entries.map((e: { name: string }) => e.name), ["invoice.md"]);
    const recent = await world.ops("recent_docs", { collection: "gmail" }, token);
    assert.equal(recent.status, 200);
    assert.deepEqual(recent.body.result.docs.map((d: { path: string }) => d.path), [MAIL]);
    for (const path of [".hidden/x.md", "link-out.md", "../", "%2e%2e/outside/secret.md"]) {
      const res = await world.ops("read_doc", { collection: "gmail", path }, token);
      assert.ok(res.status === 403 || res.status === 404, `${path} -> ${res.status}`);
      assert.ok(!JSON.stringify(res.body).includes(LEAK), path);
    }
    assert.equal(world.gmailQmd!.requests.length, 0);
    assert.equal(world.qmd.requests.length, 0);
  });
});

describe("egress end to end", () => {
  const corpus = { himmel: ["himmel-code"], luna: ["luna-personal", "luna-clippings"] };

  async function worldWith(t: TestContext, matrix: unknown) {
    const repo = await buildRepo(t, { corpus, matrix });
    const world = await makeWorld(t, { repo });
    const { token } = await world.mint({ collections: ["himmel", "luna"] });
    return { world, token };
  }

  it("fails closed on wildcard allow, wildcard allow+log and a shadowing deny, calling neither disk nor QMD", async (t) => {
    const cases: unknown[] = [
      { default: "deny", rules: [{ corpus: "*", provider: "*", purpose: "*", verdict: "allow" }] },
      { default: "deny", rules: [{ corpus: "himmel-code", provider: "*", purpose: "*", verdict: "allow+log" }] },
      { default: "deny", rules: [{ corpus: "himmel-code", provider: "xai-grokbot", purpose: "*", verdict: "deny" }, literalRule("himmel-code", "xai-grokbot")] },
    ];
    for (const matrix of cases) {
      const { world, token } = await worldWith(t, matrix);
      const read = await world.ops("read_doc", { collection: "himmel", path: "docs/a.md" }, token);
      assert.equal(read.status, 403);
      assert.equal(read.body.error.code, "egress_denied");
      assert.ok(!JSON.stringify(read.body).includes("Himmel A"));
      const search = await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }], collections: ["himmel"] }, token);
      assert.equal(search.status, 403);
      assert.equal(world.qmd.requests.length, 0);
    }
  });

  it("serves only the collections whose corpora are literally admitted", async (t) => {
    const { world, token } = await worldWith(t, { default: "deny", rules: [literalRule("himmel-code", "xai-grokbot")] });
    assert.equal((await world.ops("read_doc", { collection: "himmel", path: "docs/a.md" }, token)).status, 200);
    assert.equal((await world.ops("read_doc", { collection: "luna", path: "CLAUDE.md" }, token)).status, 403);
  });

  it("fails closed for every call when HIMMEL_REPO is unreadable", async (t) => {
    const base = await scratch(t);
    const world = await makeWorld(t, { repo: join(base, "missing-repo") });
    const { token } = await world.mint();
    const read = await world.ops("read_doc", { collection: "himmel", path: "docs/a.md" }, token);
    assert.equal(read.status, 403);
    assert.equal((await world.ops("list_dir", { collection: "luna" }, token)).status, 403);
    assert.equal((await world.ops("recent_docs", { collection: "luna" }, token)).status, 403);
    assert.equal((await world.ops("qmd_search", { searches: [{ type: "lex", query: "x" }] }, token)).status, 403);
    assert.equal(world.qmd.requests.length, 0);
    assert.ok((await lines(world)).some((l) => l.reason === "egress-unavailable"));
  });
});

describe("audit log", () => {
  it("writes one line per allowed and per denied call with the required fields and no secrets", async (t) => {
    const world = await makeWorld(t);
    const { token, keyId } = await world.mint({ collections: ["luna"] });
    world.qmd.reply([qmdHit("luna", "30-Resources/note one.md")]);
    const calls: [string, unknown, number][] = [
      ["read_doc", { collection: "luna", path: "CLAUDE.md" }, 200],
      ["read_doc", { collection: "luna", path: ".env" }, 403],
      ["read_doc", { collection: "luna", path: "sessions/2026/07/2026-07-15-0821-salus-master.md" }, 403],
      ["qmd_search", { searches: [{ type: "lex", query: "needle" }] }, 200],
      ["read_doc", { collection: "himmel", path: "docs/a.md" }, 403],
      ["list_collections", {}, 200],
      ["read_doc", { collection: "luna", path: "30-Resources/salus-note.md" }, 404],
    ];
    for (const [op, args, status] of calls) assert.equal((await world.ops(op, args, token)).status, status, `${op} ${JSON.stringify(args)}`);
    assert.equal((await world.ops("list_collections", {}, "wrong-token")).status, 401);
    const rows = await lines(world);
    assert.equal(rows.length, calls.length + 1);
    const required = ["ts", "reqId", "principal", "keyId", "role", "collection", "corpus", "provider", "purpose", "path", "tool", "verdict"];
    for (const row of rows) for (const f of required) assert.ok(f in row, `${f} in ${JSON.stringify(row)}`);
    assert.equal(new Set(rows.map((r) => r.reqId)).size, rows.length);
    const row = (i: number) => rows[i]!;
    const [ok, dot, role, search, other, list, salus, unauth] = [row(0), row(1), row(2), row(3), row(4), row(5), row(6), row(7)];
    assert.deepEqual([ok.tool, ok.verdict, ok.path, ok.collection, ok.corpus], ["read_doc", "allow", "CLAUDE.md", "luna", "luna-personal,luna-clippings"]);
    assert.deepEqual([ok.principal, ok.keyId, ok.role, ok.provider, ok.purpose], ["grokbot", keyId, "reader", "xai-grokbot", "luna-mcp-read"]);
    assert.deepEqual([dot.verdict, dot.reason, dot.path], ["deny", "dot-segment", ".env"]);
    assert.deepEqual([role.verdict, role.reason], ["deny", "role-path"]);
    assert.deepEqual([search.tool, search.verdict, search.collection, search.path], ["qmd_search", "allow", "luna", null]);
    assert.deepEqual([other.verdict, other.reason, other.collection], ["deny", "collection-not-allowed", "himmel"]);
    assert.deepEqual([list.tool, list.verdict], ["list_collections", "allow"]);
    assert.deepEqual([salus.verdict, salus.reason], ["deny", "salus"]);
    assert.deepEqual([unauth.verdict, unauth.principal, unauth.keyId, unauth.reason], ["deny", null, null, "unknown-key"]);
    assert.equal((await stat(world.auditFile)).mode & 0o777, 0o600);
    const raw = await readFile(world.auditFile, "utf8");
    for (const secret of [token, "wrong-token", hashKey(token), hashKey("wrong-token"), QMD_TOKEN, LEAK, PHI, "needle in spaced note", "Luna rules", "body of"]) {
      assert.ok(!raw.includes(secret), `audit leaked ${secret.slice(0, 12)}`);
    }
  });

  it("logs one line per entry of a multi_read", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const res = await world.ops("multi_read", { entries: [{ collection: "luna", path: "CLAUDE.md" }, { collection: "luna", path: ".env" }, { collection: "himmel", path: "docs/a.md" }] }, token);
    assert.equal(res.status, 200);
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict, r.path]), [["multi_read", "allow", "CLAUDE.md"], ["multi_read", "deny", ".env"], ["multi_read", "deny", "docs/a.md"]]);
  });

  it("returns 503 and no content when an allowed call cannot be logged", async (t) => {
    const base = await scratch(t);
    const blocker = join(base, "blocker");
    await writeFile(blocker, "x");
    const world = await makeWorld(t, { auditFile: join(blocker, "audit.jsonl") });
    const { token } = await world.mint({ collections: ["luna"] });
    const res = await world.ops("read_doc", { collection: "luna", path: "CLAUDE.md" }, token);
    assert.equal(res.status, 503);
    assert.equal(res.body.error.code, "audit_unavailable");
    assert.ok(!JSON.stringify(res.body).includes("Luna rules"));
    const denied = await world.ops("read_doc", { collection: "luna", path: ".env" }, token);
    assert.equal(denied.status, 403);
  });
});

describe("MCP surface", () => {
  const toolNames = ["list_collections", "qmd_search", "luna_search", "read_doc", "luna_read_note", "multi_read", "list_dir", "recent_docs"];

  it("exposes the operation table as tools", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    const res = await world.mcp("tools/list", {}, token);
    assert.equal(res.status, 200);
    const names = (res.body.result.tools as { name: string }[]).map((x) => x.name).sort();
    assert.deepEqual(names, [...toolNames].sort());
    assert.deepEqual([...OPERATIONS.flatMap((o) => [o.name, ...o.aliases])].sort(), [...toolNames].sort());
  });

  it("serves tools/call through the same dispatcher and audits it", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const ok = await world.mcp("tools/call", { name: "read_doc", arguments: { collection: "luna", path: "CLAUDE.md" } }, token);
    assert.equal(ok.status, 200);
    assert.notEqual(ok.body.result.isError, true);
    const payload = JSON.parse(ok.body.result.content[0].text);
    assert.match(payload.content, /Luna rules/);
    const denied = await world.mcp("tools/call", { name: "read_doc", arguments: { collection: "luna", path: ".env" } }, token);
    assert.equal(denied.status, 200);
    assert.equal(denied.body.result.isError, true);
    assert.equal(JSON.parse(denied.body.result.content[0].text).error.code, "forbidden");
    assert.ok(!denied.body.result.content[0].text.includes(LEAK));
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict]), [["read_doc", "allow"], ["read_doc", "deny"]]);
  });

  it("answers an invalid tool call with an error result, not a crash", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const res = await world.mcp("tools/call", { name: "read_doc", arguments: { path: 7 } }, token);
    assert.equal(res.status, 200);
    assert.equal(res.body.error !== undefined || res.body.result?.isError === true, true);
  });

  it("refuses an unauthenticated call and answers 405 to a GET on the MCP route", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint();
    assert.equal((await world.mcp("tools/list", {}, null)).status, 401);
    const res = await world.app.fetch(new Request(PUBLIC_URL, { method: "GET", headers: { host: HOST, authorization: `Bearer ${token}`, accept: "text/event-stream" } }));
    assert.equal(res.status, 405);
    const anon = await world.app.fetch(new Request(PUBLIC_URL, { method: "GET", headers: { host: HOST } }));
    assert.equal(anon.status, 405);
  });
});

describe("dispatch", () => {
  const principal = (roles: string[]): Principal => ({ keyId: "key-x", principal: "grokbot", provider: "xai-grokbot", roles, allowedCollections: ["luna"], allowHandoversRead: false });

  it("refuses a principal without the reader role and audits the denial", async (t) => {
    const world = await makeWorld(t);
    const res = await dispatch({ ...world.deps }, principal([]), "read_doc", { collection: "luna", path: "CLAUDE.md" }, "req-x");
    assert.equal(res.status, 403);
    assert.deepEqual((res.body as { error: { code: string } }).error.code, "role_required");
    const rows = await lines(world);
    assert.deepEqual([rows[0]?.verdict, rows[0]?.reason], ["deny", "role-required"]);
  });

  it("audits an unknown operation under a safe tool name", async (t) => {
    const world = await makeWorld(t);
    const res = await dispatch({ ...world.deps }, principal(["reader"]), "x".repeat(200), {}, "req-y");
    assert.equal(res.status, 404);
    assert.equal((await lines(world))[0]?.tool, "invalid");
  });
});

describe("configuration", () => {
  const base = { HIMMEL_REPO: "/srv/checkout", LUNA_MCP_PUBLIC_URL: PUBLIC_URL, XDG_CONFIG_HOME: "/srv/cfg", XDG_STATE_HOME: "/srv/state" };

  it("applies defaults for paths, QMD and limits", () => {
    const c = loadConfig(base);
    assert.equal(c.himmelRepo, "/srv/checkout");
    assert.equal(c.publicUrl.href, PUBLIC_URL);
    assert.equal(c.keysFile, "/srv/cfg/himmel/luna-mcp-keys.json");
    assert.equal(c.auditFile, "/srv/state/himmel/luna-mcp-audit.jsonl");
    assert.equal(c.qmdUrl, "http://localhost:8181");
    assert.equal(c.qmdTokenFile, "/srv/cfg/qmd/http-token");
    assert.deepEqual([c.host, c.port, c.searchPerMinute, c.searchTimeoutMs], ["127.0.0.1", 8190, 10, 45000]);
  });

  it("takes every path and limit from the environment", () => {
    const c = loadConfig({ ...base, LUNA_MCP_KEYS_FILE: "/k.json", LUNA_MCP_AUDIT_FILE: "/a.jsonl", QMD_URL: "http://127.0.0.1:9999", QMD_HTTP_TOKEN_FILE: "/t", LUNA_MCP_PORT: "9100", LUNA_MCP_SEARCH_RATE_PER_MIN: "3", LUNA_MCP_SEARCH_TIMEOUT_MS: "2500" });
    assert.deepEqual([c.keysFile, c.auditFile, c.qmdUrl, c.qmdTokenFile, c.port, c.searchPerMinute, c.searchTimeoutMs], ["/k.json", "/a.jsonl", "http://127.0.0.1:9999", "/t", 9100, 3, 2500]);
  });

  it("refuses missing required values, a non-https or misplaced public URL, a bad port and a non-loopback host", () => {
    assert.throws(() => loadConfig({ ...base, HIMMEL_REPO: "" }), (e: unknown) => e instanceof ConfigError && /HIMMEL_REPO/.test(e.message));
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PUBLIC_URL: "" }), (e: unknown) => e instanceof ConfigError && /LUNA_MCP_PUBLIC_URL/.test(e.message));
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PUBLIC_URL: "http://example-node.example-tailnet.ts.net/luna/mcp" }), ConfigError);
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PUBLIC_URL: `https://${HOST}/other` }), ConfigError);
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PUBLIC_URL: "not a url" }), ConfigError);
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PORT: "70000" }), ConfigError);
    assert.throws(() => loadConfig({ ...base, LUNA_MCP_PORT: "abc" }), ConfigError);
    for (const host of ["0.0.0.0", "203.0.113.5", "::", "example.com"]) {
      assert.throws(() => loadConfig({ ...base, LUNA_MCP_HOST: host }), ConfigError, host);
    }
    for (const host of ["127.0.0.1", "::1", "localhost"]) assert.equal(loadConfig({ ...base, LUNA_MCP_HOST: host }).host, host);
  });
});

function http(port: number, init: { method: string; path: string; headers: Record<string, string>; body?: string }): Promise<{ status: number; text: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, method: init.method, path: init.path, headers: init.headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c: Buffer) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, text: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(init.body);
  });
}

describe("node:http bridge", () => {
  it("serves health, the JSON API and MCP over a loopback socket from environment configuration", async (t) => {
    const base = await scratch(t);
    const world = await makeWorld(t);
    const repo = world.repo;
    const rootsFile = join(base, "roots.json");
    await writeFile(rootsFile, JSON.stringify(Object.fromEntries(world.fx.roots)));
    const keysFile = join(base, "cfg", "keys.json");
    await mkdir(join(base, "cfg"), { recursive: true });
    const clock = makeClock();
    const minted = await mintKey(keysFile, { principal: "grokbot", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna", "himmel"], ttlMs: 3600_000 }, { now: clock.now, randomBytes });
    const auditFile = join(base, "state", "audit.jsonl");
    const server = await startServer({
      HIMMEL_REPO: repo,
      LUNA_MCP_PUBLIC_URL: PUBLIC_URL,
      LUNA_MCP_COLLECTION_ROOTS: rootsFile,
      LUNA_MCP_KEYS_FILE: keysFile,
      LUNA_MCP_AUDIT_FILE: auditFile,
      QMD_URL: world.qmd.url,
      QMD_HTTP_TOKEN_FILE: world.tokenFile,
      LUNA_MCP_PORT: "0",
    });
    t.after(() => server.close());
    assert.equal(server.host, "127.0.0.1");
    assert.ok(server.port > 0);
    const auth = { host: HOST, authorization: `Bearer ${minted.token}` };

    const health = await http(server.port, { method: "GET", path: "/luna/health", headers: { host: HOST } });
    assert.equal(health.status, 200);
    assert.deepEqual(JSON.parse(health.text), { status: "ok", qmd: "up" });

    const badHost = await http(server.port, { method: "GET", path: "/luna/health", headers: { host: "evil.example" } });
    assert.equal(badHost.status, 403);

    const read = await http(server.port, { method: "POST", path: "/luna/v1/ops/read_doc", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ collection: "luna", path: "CLAUDE.md" }) });
    assert.equal(read.status, 200);
    assert.match(JSON.parse(read.text).result.content, /Luna rules/);

    const anon = await http(server.port, { method: "POST", path: "/luna/v1/ops/read_doc", headers: { host: HOST, "content-type": "application/json" }, body: "{}" });
    assert.equal(anon.status, 401);

    const mcp = await http(server.port, {
      method: "POST",
      path: "/luna/mcp",
      headers: { ...auth, "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
    assert.equal(mcp.status, 200);
    assert.match(mcp.text, /read_doc/);

    const unknown = await http(server.port, { method: "GET", path: "http://example.invalid/luna/health", headers: { host: HOST } });
    assert.ok(unknown.status === 400 || unknown.status === 404);

    const rows = (await readFile(auditFile, "utf8")).split("\n").filter(Boolean);
    assert.ok(rows.length >= 2);
    for (const row of rows) assert.ok(!row.includes(minted.token));
  });
});

describe("node:http bridge under hostile requests", () => {
  async function bridge(t: TestContext) {
    const base = await scratch(t);
    const world = await makeWorld(t);
    const rootsFile = join(base, "roots.json");
    await writeFile(rootsFile, JSON.stringify(Object.fromEntries(world.fx.roots)));
    const keysFile = join(base, "cfg", "keys.json");
    await mkdir(join(base, "cfg"), { recursive: true });
    const minted = await mintKey(keysFile, { principal: "grokbot", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: 3600_000 }, { now: makeClock().now, randomBytes });
    const server = await startServer({
      HIMMEL_REPO: world.repo,
      LUNA_MCP_PUBLIC_URL: PUBLIC_URL,
      LUNA_MCP_COLLECTION_ROOTS: rootsFile,
      LUNA_MCP_KEYS_FILE: keysFile,
      LUNA_MCP_AUDIT_FILE: join(base, "state", "audit.jsonl"),
      QMD_URL: world.qmd.url,
      QMD_HTTP_TOKEN_FILE: world.tokenFile,
      LUNA_MCP_PORT: "0",
    });
    t.after(() => server.close());
    return { server, token: minted.token };
  }

  it("answers 400 to a malformed Host header and keeps serving the next request", async (t) => {
    const { server, token } = await bridge(t);
    const bad = await http(server.port, { method: "GET", path: "/luna/health", headers: { host: "[" } });
    assert.equal(bad.status, 400);
    const health = await http(server.port, { method: "GET", path: "/luna/health", headers: { host: HOST } });
    assert.equal(health.status, 200);
    const read = await http(server.port, {
      method: "POST",
      path: "/luna/v1/ops/read_doc",
      headers: { host: HOST, authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ collection: "luna", path: "CLAUDE.md" }),
    });
    assert.equal(read.status, 200);
  });

  it("never crashes on other malformed Host values", async (t) => {
    const { server } = await bridge(t);
    for (const host of ["[::1", "][", "[]]", "%", "a b"]) {
      const res = await http(server.port, { method: "GET", path: "/luna/health", headers: { host } });
      assert.ok(res.status === 400 || res.status === 403, `${host} -> ${res.status}`);
    }
    assert.equal((await http(server.port, { method: "GET", path: "/luna/health", headers: { host: HOST } })).status, 200);
  });
});

describe("a frontmatter header that never closes inside the scan window", () => {
  it("is refused on read, multi_read, search hits, list_dir and recent_docs", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const root = world.fx.roots.get("luna")!;
    const path = "30-Resources/long-header.md";
    await writeFile(join(root, path), `---\n${"k: v\n".repeat(14_000)}repo: salus\n---\n# Long header\n${PHI}\n`);

    const read = await world.ops("read_doc", { collection: "luna", path }, token);
    assert.equal(read.status, 404);
    assert.ok(!JSON.stringify(read.body).includes(PHI));

    const multi = await world.ops("multi_read", { entries: [{ collection: "luna", path }, { collection: "luna", path: "CLAUDE.md" }] }, token);
    assert.deepEqual(multi.body.result.results.map((r: { ok: boolean }) => r.ok), [false, true]);
    assert.ok(!JSON.stringify(multi.body).includes(PHI));

    world.qmd.reply([qmdHit("luna", path), qmdHit("luna", "docs/guide.md")]);
    const search = await world.ops("qmd_search", { searches: [{ type: "lex", query: "header" }], collections: ["luna"] }, token);
    assert.deepEqual(search.body.result.hits.map((h: { path: string }) => h.path), ["docs/guide.md"]);

    const list = await world.ops("list_dir", { collection: "luna", dir: "30-Resources", limit: 100 }, token);
    assert.ok(!list.body.result.entries.some((e: { name: string }) => e.name === "long-header.md"));

    const recent = await world.ops("recent_docs", { collection: "luna", limit: 50 }, token);
    assert.ok(!recent.body.result.docs.some((d: { path: string }) => d.path === path));

    const reasons = (await lines(world)).filter((l) => l.path === path).map((l) => l.reason);
    assert.ok(reasons.length >= 2 && reasons.every((r) => r === "frontmatter"), reasons.join(","));
  });
});

describe("audit lines for refusals and protocol calls", () => {
  const initParams = { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } };

  it("writes exactly one line for an authenticated 415, 413 and 400 on the JSON API, with no body or token", async (t) => {
    const world = await makeWorld(t);
    const { token, keyId } = await world.mint({ collections: ["luna"] });
    assert.equal((await world.ops("list_collections", {}, token, { "content-type": "text/plain" })).status, 415);
    assert.equal((await world.ops("read_doc", { path: "x".repeat(300 * 1024) }, token)).status, 413);
    const bad = await world.app.fetch(new Request(`https://${HOST}/luna/v1/ops/read_doc`, { method: "POST", headers: { host: HOST, authorization: `Bearer ${token}`, "content-type": "application/json" }, body: "{nope" }));
    assert.equal(bad.status, 400);
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict, r.reason]), [
      ["list_collections", "deny", "unsupported-media-type"],
      ["read_doc", "deny", "payload-too-large"],
      ["read_doc", "deny", "invalid-json"],
    ]);
    for (const r of rows) assert.deepEqual([r.principal, r.keyId, r.role], ["grokbot", keyId, "reader"]);
    const raw = await readFile(world.auditFile, "utf8");
    for (const secret of [token, "xxxxxxxx", "{nope"]) assert.ok(!raw.includes(secret));
  });

  it("writes one line for MCP initialize and tools/list, and no extra line for a tool call dispatch already audits", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    assert.equal((await world.mcp("initialize", initParams, token)).status, 200);
    assert.equal((await world.mcp("tools/list", {}, token)).status, 200);
    assert.deepEqual((await lines(world)).map((r) => [r.tool, r.verdict]), [["initialize", "allow"], ["tools/list", "allow"]]);
    assert.equal((await world.mcp("tools/call", { name: "read_doc", arguments: { collection: "luna", path: "CLAUDE.md" } }, token)).status, 200);
    assert.equal((await world.mcp("tools/call", { name: "read_doc", arguments: { collection: "luna", path: ".env" } }, token)).status, 200);
    assert.deepEqual((await lines(world)).slice(2).map((r) => [r.tool, r.verdict]), [["read_doc", "allow"], ["read_doc", "deny"]]);
  });

  it("writes one line for an MCP tool call that schema validation rejects before the callback runs", async (t) => {
    const world = await makeWorld(t);
    const { token, keyId } = await world.mint({ collections: ["luna"] });
    await world.mcp("tools/call", { name: "read_doc", arguments: { path: 7 } }, token);
    await world.mcp("tools/call", { name: "drop_tables", arguments: {} }, token);
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict, r.reason]), [
      ["read_doc", "deny", "mcp-rejected"],
      ["drop_tables", "deny", "mcp-rejected"],
    ]);
    for (const r of rows) assert.equal(r.keyId, keyId);
  });

  it("writes one deny line for MCP bodies that are not usable JSON-RPC", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const post = (body: string, type = "application/json") =>
      world.app.fetch(new Request(PUBLIC_URL, { method: "POST", headers: { host: HOST, authorization: `Bearer ${token}`, "content-type": type, accept: "application/json, text/event-stream" }, body }));
    assert.equal((await post("{}", "text/plain")).status, 415);
    assert.equal((await post("{nope")).status, 400);
    assert.equal((await post(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: { pad: "x".repeat(300 * 1024) } }))).status, 413);
    assert.equal((await post(JSON.stringify([{ jsonrpc: "2.0", id: 1, method: "tools/list" }]))).status, 400);
    assert.equal((await post(JSON.stringify({ jsonrpc: "2.0", id: 1 }))).status, 400);
    assert.deepEqual((await lines(world)).map((r) => [r.tool, r.verdict, r.reason]), [
      ["mcp", "deny", "unsupported-media-type"],
      ["mcp", "deny", "invalid-json"],
      ["mcp", "deny", "payload-too-large"],
      ["mcp", "deny", "batch-unsupported"],
      ["mcp", "deny", "invalid-request"],
    ]);
  });

  it("refuses an MCP protocol call with 503 when its audit line cannot be written", async (t) => {
    const base = await scratch(t);
    const blocker = join(base, "blocker");
    await writeFile(blocker, "x");
    const world = await makeWorld(t, { auditFile: join(blocker, "audit.jsonl") });
    const { token } = await world.mint({ collections: ["luna"] });
    const res = await world.mcp("tools/list", {}, token);
    assert.equal(res.status, 503);
    assert.ok(!JSON.stringify(res.body).includes("read_doc"));
  });

  const rawMcp = (world: World, token: string, message: unknown) =>
    world.app.fetch(
      new Request(PUBLIC_URL, {
        method: "POST",
        headers: { host: HOST, authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
        body: JSON.stringify(message),
      }),
    );

  it("writes one allow line for each authenticated MCP notification", async (t) => {
    const world = await makeWorld(t);
    const { token, keyId } = await world.mint({ collections: ["luna"] });
    const first = await rawMcp(world, token, { jsonrpc: "2.0", method: "notifications/initialized" });
    const second = await rawMcp(world, token, { jsonrpc: "2.0", method: "notifications/anything-at-all", params: { x: 1 } });
    assert.ok(first.status >= 200 && first.status < 300, String(first.status));
    assert.ok(second.status >= 200 && second.status < 300, String(second.status));
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict]), [["notifications/initialized", "allow"], ["notifications/anything-at-all", "allow"]]);
    for (const r of rows) assert.equal(r.keyId, keyId);
  });

  it("refuses an MCP notification with 503 when its audit line cannot be written", async (t) => {
    const base = await scratch(t);
    const blocker = join(base, "blocker");
    await writeFile(blocker, "x");
    const world = await makeWorld(t, { auditFile: join(blocker, "audit.jsonl") });
    const { token } = await world.mint({ collections: ["luna"] });
    assert.equal((await rawMcp(world, token, { jsonrpc: "2.0", method: "notifications/initialized" })).status, 503);
  });

  it("records the verdict from what the MCP layer answered, one line per message", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    await rawMcp(world, token, { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
    await rawMcp(world, token, { jsonrpc: "2.0", id: 2, method: "nonexistent/method", params: {} });
    await rawMcp(world, token, { jsonrpc: "1.0", id: 3, method: "tools/list", params: {} });
    const rows = await lines(world);
    assert.deepEqual(rows.map((r) => [r.tool, r.verdict]), [["tools/list", "allow"], ["nonexistent/method", "deny"], ["tools/list", "deny"]]);
    assert.equal(rows[0]?.reason, null);
    for (const r of rows.slice(1)) assert.match(r.reason ?? "", /^mcp-/);
  });

  describe("outcomeOf", () => {
    const body = (text: string): ArrayBuffer => new TextEncoder().encode(text).buffer as ArrayBuffer;
    const result = JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} });
    const failure = JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32601, message: "Method not found" } });

    it("denies any non-2xx status, even with an empty body", () => {
      assert.deepEqual(outcomeOf(500, "application/json", body("")), { verdict: "deny", reason: "mcp-status-500" });
      assert.deepEqual(outcomeOf(404, "text/plain", body("")), { verdict: "deny", reason: "mcp-status-404" });
    });

    it("allows an accepted notification with no body", () => {
      assert.deepEqual(outcomeOf(202, "application/json", body("")), { verdict: "allow", reason: null });
    });

    it("denies a JSON-RPC error in a JSON body or in an event stream, and allows a result", () => {
      assert.deepEqual(outcomeOf(200, "application/json", body(failure)), { verdict: "deny", reason: "mcp-error" });
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(`event: message\ndata: ${failure}\n\n`)), { verdict: "deny", reason: "mcp-error" });
      assert.deepEqual(outcomeOf(200, "application/json", body(result)), { verdict: "allow", reason: null });
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(`data: \n\nevent: message\ndata: ${result}\n\n`)), { verdict: "allow", reason: null });
    });

    it("denies a body it cannot read", () => {
      assert.deepEqual(outcomeOf(200, "application/json", body("not json")), { verdict: "deny", reason: "mcp-unreadable" });
    });

    const spread = (message: unknown): string =>
      JSON.stringify(message, null, 1)
        .split("\n")
        .map((line) => `data: ${line}`)
        .join("\n");

    it("reads a JSON-RPC error split across several data lines of one event", () => {
      const event = `event: message\n${spread({ jsonrpc: "2.0", id: 1, error: { code: -32601, message: "Method not found" } })}\n\n`;
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(event)), { verdict: "deny", reason: "mcp-error" });
    });

    it("reads a JSON-RPC result split across several data lines of one event", () => {
      const event = `event: message\n${spread({ jsonrpc: "2.0", id: 1, result: { tools: [{ name: "read_doc" }] } })}\n\n`;
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(event)), { verdict: "allow", reason: null });
    });

    it("reads events with CRLF line endings and judges them all, one verdict for the message", () => {
      const first = spread({ jsonrpc: "2.0", id: 1, result: {} });
      const second = spread({ jsonrpc: "2.0", id: 2, error: { code: -32600, message: "Invalid Request" } });
      const stream = `${first}\n\n${second}\n\n`.replace(/\n/g, "\r\n");
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(stream)), { verdict: "deny", reason: "mcp-error" });
    });

    it("keeps data lines of different events apart, and denies a split event that is still not JSON", () => {
      const apart = `data: {"jsonrpc":"2.0",\n\ndata: "id":1,"result":{}}\n\n`;
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(apart)), { verdict: "deny", reason: "mcp-unreadable" });
      assert.deepEqual(outcomeOf(200, "text/event-stream", body(`data: {"jsonrpc":\ndata: "2.0"\n\n`)), { verdict: "deny", reason: "mcp-unreadable" });
    });
  });

  it("refuses a subscriptions/listen stream and says so in the audit log", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const res = await rawMcp(world, token, { jsonrpc: "2.0", id: 1, method: "subscriptions/listen", params: {} });
    assert.equal(res.status, 400);
    assert.deepEqual((await lines(world)).map((r) => [r.tool, r.verdict, r.reason]), [["subscriptions/listen", "deny", "listen-unsupported"]]);
  });
});

describe("path tools say what they expect and why a path was refused", () => {
  it("states in each path tool description that path is relative to the collection root", () => {
    for (const name of ["read_doc", "multi_read", "list_dir", "recent_docs"]) {
      const op = OPERATIONS.find((o) => o.name === name);
      assert.ok(op?.description.includes("relative to the collection root"), name);
    }
  });

  it("names the reason class in the client message and keeps code and audit reason", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const cases: Array<[string, RegExp, string]> = [
      ["/etc/hosts", /absolute paths are not allowed.*relative to the collection root/, "bad-path"],
      [".obsidian/app.json", /dot-folders are not readable/, "dot-segment"],
      ["sessions/2026/07/2026-07-15-0821-salus-master.md", /this folder is not readable with this key/, "role-path"],
      ["scripts/x.md", /this folder is not readable with this key/, "kernel"],
    ];
    for (const [path, message, reason] of cases) {
      const res = await world.ops("read_doc", { collection: "luna", path }, token);
      assert.equal(res.status, 403, path);
      assert.equal(res.body.error.code, "forbidden", path);
      assert.match(res.body.error.message, message, path);
      assert.ok((await lines(world)).some((r) => r.reason === reason), reason);
    }
  });

  it("gives the same message for a hidden folder that exists and one that does not", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const a = await world.ops("read_doc", { collection: "luna", path: "sessions/2026/07/2026-07-15-0821-salus-master.md" }, token);
    const b = await world.ops("read_doc", { collection: "luna", path: "sessions/none/none.md" }, token);
    assert.equal(a.body.error.message, b.body.error.message);
  });

  it("repeats the reason in a multi_read entry", async (t) => {
    const world = await makeWorld(t);
    const { token } = await world.mint({ collections: ["luna"] });
    const multi = await world.ops("multi_read", { entries: [{ collection: "luna", path: "/etc/hosts" }] }, token);
    assert.match(multi.body.result.results[0].error.message, /absolute paths are not allowed/);
  });
});
