import assert from "node:assert/strict";
import { chmod, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, it } from "node:test";
import { createAudit, defaultAuditFile, type AuditInput } from "../src/audit.js";
import { makeClock, readAudit, scratch } from "./helpers.js";

const entry = (over: Partial<AuditInput> = {}): AuditInput => ({
  reqId: "req-1",
  principal: "grokbot",
  keyId: "key-1",
  role: "reader",
  collection: "luna",
  corpus: "luna-personal,luna-clippings",
  provider: "xai-grokbot",
  purpose: "luna-mcp-read",
  path: "CLAUDE.md",
  tool: "read_doc",
  verdict: "allow",
  reason: null,
  ...over,
});

describe("audit log", () => {
  it("creates the log with mode 0600 and writes one JSON line with exactly the schema fields", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock(Date.UTC(2026, 10, 26, 12, 0, 0));
    const file = join(dir, "state", "audit.jsonl");
    await createAudit({ file, now: clock.now }).write(entry());
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    assert.equal((await stat(join(dir, "state"))).mode & 0o777, 0o700);
    const lines = (await readFile(file, "utf8")).split("\n").filter(Boolean);
    assert.equal(lines.length, 1);
    const parsed = JSON.parse(lines[0]!);
    assert.deepEqual(Object.keys(parsed).sort(), [
      "collection",
      "corpus",
      "keyId",
      "path",
      "principal",
      "provider",
      "purpose",
      "reason",
      "reqId",
      "role",
      "tool",
      "ts",
      "verdict",
    ]);
    assert.equal(parsed.ts, "2026-11-26T12:00:00.000Z");
  });

  it("tightens a pre-existing wider mode to 0600 before appending", async (t) => {
    const dir = await scratch(t);
    const file = join(dir, "audit.jsonl");
    await writeFile(file, "", { mode: 0o644 });
    await chmod(file, 0o644);
    await createAudit({ file, now: makeClock().now }).write(entry());
    assert.equal((await stat(file)).mode & 0o777, 0o600);
  });

  it("drops any field outside the schema, so a token, hash or body cannot be logged", async (t) => {
    const dir = await scratch(t);
    const file = join(dir, "audit.jsonl");
    const sneaky = { ...entry(), token: "tok-plain", hash: "deadbeef", body: "document body text" } as AuditInput;
    await createAudit({ file, now: makeClock().now }).write(sneaky);
    const text = await readFile(file, "utf8");
    for (const word of ["tok-plain", "deadbeef", "document body text", "token", "hash", "body"]) assert.ok(!text.includes(word), word);
  });

  it("serialises concurrent writes into whole lines", async (t) => {
    const dir = await scratch(t);
    const file = join(dir, "audit.jsonl");
    const audit = createAudit({ file, now: makeClock().now });
    await Promise.all(Array.from({ length: 50 }, (_, i) => audit.write(entry({ reqId: `req-${i}` }))));
    const rows = await readAudit(file);
    assert.equal(rows.length, 50);
    assert.equal(new Set(rows.map((r) => r.reqId)).size, 50);
  });

  it("rotates at the size cap, keeps the newest files and writes the new file 0600", async (t) => {
    const dir = await scratch(t);
    const file = join(dir, "audit.jsonl");
    const audit = createAudit({ file, now: makeClock().now, maxBytes: 600, keep: 2 });
    for (let i = 0; i < 12; i++) await audit.write(entry({ reqId: `req-${i}` }));
    const names = (await readdir(dir)).sort();
    assert.deepEqual(names, ["audit.jsonl", "audit.jsonl.1", "audit.jsonl.2"]);
    for (const n of names) assert.equal((await stat(join(dir, n))).mode & 0o777, 0o600, n);
    const newest = await readAudit(file);
    assert.ok(newest.length >= 1);
    assert.equal(newest.at(-1)?.reqId, "req-11");
    for (const n of names) assert.ok((await stat(join(dir, n))).size <= 600, n);
  });

  it("rejects the write when the log cannot be written", async (t) => {
    const dir = await scratch(t);
    const blocker = join(dir, "blocker");
    await writeFile(blocker, "x");
    await assert.rejects(createAudit({ file: join(blocker, "audit.jsonl"), now: makeClock().now }).write(entry()));
  });

  it("derives the default file from XDG_STATE_HOME, then HOME", () => {
    assert.equal(defaultAuditFile({ XDG_STATE_HOME: "/srv/state" }), "/srv/state/himmel/luna-mcp-audit.jsonl");
    assert.equal(defaultAuditFile({ HOME: "/srv/user" }), "/srv/user/.local/state/himmel/luna-mcp-audit.jsonl");
  });
});
