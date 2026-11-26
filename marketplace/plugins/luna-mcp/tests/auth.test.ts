import assert from "node:assert/strict";
import { chmod, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { AuthInfo } from "@modelcontextprotocol/server";
import {
  bearerGate,
  checkHostAndOrigin,
  defaultKeysFile,
  hashKey,
  KeyStore,
  principalFrom,
  readKeysFile,
  writeKeysFile,
  type AuthTrace,
} from "../src/auth.js";
import { HOST, keyRecord, makeClock, PUBLIC_URL, scratch, writeKeysRaw } from "./helpers.js";

const URL_ = new URL(PUBLIC_URL);

async function run(store: KeyStore, token: string | null, header?: string): Promise<{ out: AuthInfo | Response; trace: AuthTrace }> {
  const trace: AuthTrace = {};
  const gate = bearerGate(store, URL_, trace);
  const headers: Record<string, string> = {};
  if (header !== undefined) headers["authorization"] = header;
  else if (token !== null) headers["authorization"] = `Bearer ${token}`;
  const out = await gate(new Request(PUBLIC_URL, { method: "POST", headers }));
  return { out, trace };
}

function status(out: AuthInfo | Response): number {
  assert.ok(out instanceof Response, "expected a refusal");
  return out.status;
}

describe("KeyStore and bearerGate", () => {
  it("accepts a valid key and binds principal, provider, roles, collections and resource", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    const rec = keyRecord("tok-valid-1", clock);
    await writeKeysRaw(file, [rec]);
    const { out, trace } = await run(new KeyStore(file, clock.now), "tok-valid-1");
    assert.ok(!(out instanceof Response));
    const p = principalFrom(out);
    assert.deepEqual(p, {
      keyId: "key-test-1",
      principal: "grokbot",
      provider: "xai-grokbot",
      roles: ["reader"],
      allowedCollections: ["luna", "himmel"],
      allowHandoversRead: false,
    });
    assert.equal(out.resource?.href, PUBLIC_URL);
    assert.deepEqual(trace.principal, p);
  });

  it("never carries the plaintext token or the stored hash in the verified auth info", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    const rec = keyRecord("tok-secret-xyz", clock);
    await writeKeysRaw(file, [rec]);
    const { out } = await run(new KeyStore(file, clock.now), "tok-secret-xyz");
    assert.ok(!(out instanceof Response));
    const text = JSON.stringify(out);
    assert.ok(!text.includes("tok-secret-xyz"));
    assert.ok(!text.includes(rec.hash));
  });

  it("refuses a missing bearer, a non-bearer scheme and an empty token", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock)]);
    const store = new KeyStore(file, clock.now);
    assert.equal(status((await run(store, null)).out), 401);
    assert.equal(status((await run(store, null, "Basic dG9rLTE=")).out), 401);
    assert.equal(status((await run(store, null, "Bearer ")).out), 401);
  });

  it("refuses a wrong key", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock)]);
    const { out, trace } = await run(new KeyStore(file, clock.now), "tok-wrong");
    assert.equal(status(out), 401);
    assert.equal(trace.reason, "unknown-key");
    assert.equal(trace.principal, undefined);
  });

  it("refuses an expired key by the injected clock and names the reason", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock, { expiresAt: new Date(clock.now() + 3600_000).toISOString() })]);
    const store = new KeyStore(file, clock.now);
    assert.ok(!((await run(store, "tok-1")).out instanceof Response));
    clock.advance(3600_000 + 1);
    const { out, trace } = await run(store, "tok-1");
    assert.equal(status(out), 401);
    assert.equal(trace.reason, "expired");
  });

  it("refuses a revoked key at once when the key file changes", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    const rec = keyRecord("tok-1", clock);
    const t0 = Date.now() - 20_000;
    await writeKeysRaw(file, [rec], 0o600, t0);
    const store = new KeyStore(file, clock.now);
    assert.ok(!((await run(store, "tok-1")).out instanceof Response));
    await writeFile(file, JSON.stringify({ version: 1, keys: [{ ...rec, revoked: true }] }));
    await utimes(file, (t0 + 10_000) / 1000, (t0 + 10_000) / 1000);
    const { out, trace } = await run(store, "tok-1");
    assert.equal(status(out), 401);
    assert.equal(trace.reason, "revoked");
  });

  it("picks up a key added by an atomic replacement of the file", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock)]);
    const store = new KeyStore(file, clock.now);
    assert.equal(status((await run(store, "tok-2")).out), 401);
    await writeKeysFile(file, [keyRecord("tok-1", clock), keyRecord("tok-2", clock, { keyId: "key-test-2" })]);
    assert.ok(!((await run(store, "tok-2")).out instanceof Response));
  });

  it("fails closed with 500 when the key file is group or world readable, and recovers once fixed", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock)], 0o644);
    const store = new KeyStore(file, clock.now);
    const bad = await run(store, "tok-1");
    assert.equal(status(bad.out), 500);
    assert.equal(bad.trace.reason, "keystore-unavailable");
    await chmod(file, 0o600);
    assert.ok(!((await run(store, "tok-1")).out instanceof Response));
  });

  it("fails closed with 500 when the key file is missing or malformed", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    const store = new KeyStore(file, clock.now);
    assert.equal(status((await run(store, "tok-1")).out), 500);
    await writeFile(file, "{not json", { mode: 0o600 });
    assert.equal(status((await run(store, "tok-1")).out), 500);
    await writeFile(file, JSON.stringify({ version: 2, keys: [] }), { mode: 0o600 });
    await utimes(file, 1, 2);
    assert.equal(status((await run(store, "tok-1")).out), 500);
  });

  it("drops records with no expiry, a non-finite expiry, an unknown role, provider or empty collections, and keeps their valid sibling", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    const valid = keyRecord("tok-ok", clock, { keyId: "key-ok" });
    const base = (n: string, over: Record<string, unknown>) => ({ ...keyRecord(`tok-${n}`, clock, { keyId: `key-${n}` }), ...over });
    const noExpiry = base("noexp", {});
    delete (noExpiry as Partial<typeof noExpiry>).expiresAt;
    await writeKeysRaw(file, [
      valid,
      noExpiry,
      base("nan", { expiresAt: "never" }),
      base("null", { expiresAt: null }),
      base("number", { expiresAt: 4102444800 }),
      base("role", { roles: ["reader", "admin"] }),
      base("manager", { roles: ["manager"] }),
      base("provider", { egressProvider: "local-ollama" }),
      base("nocollections", { allowedCollections: [] }),
      base("norevoked", { revoked: undefined }),
      base("shorthash", { hash: "abc" }),
    ]);
    const store = new KeyStore(file, clock.now);
    assert.ok(!((await run(store, "tok-ok")).out instanceof Response));
    for (const n of ["noexp", "nan", "null", "number", "role", "manager", "provider", "nocollections", "norevoked"]) {
      assert.equal(status((await run(store, `tok-${n}`)).out), 401, n);
    }
    const parsed = await readKeysFile(file);
    assert.equal(parsed.keys.length, 1);
    assert.equal(parsed.invalid, 10);
  });

  it("keeps old and new keys valid together during overlap rotation until the old one expires", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [
      keyRecord("tok-old", clock, { keyId: "key-old", expiresAt: new Date(clock.now() + 3600_000).toISOString() }),
      keyRecord("tok-new", clock, { keyId: "key-new", expiresAt: new Date(clock.now() + 90 * 86400_000).toISOString() }),
    ]);
    const store = new KeyStore(file, clock.now);
    assert.ok(!((await run(store, "tok-old")).out instanceof Response));
    assert.ok(!((await run(store, "tok-new")).out instanceof Response));
    clock.advance(1800_000);
    assert.ok(!((await run(store, "tok-old")).out instanceof Response));
    assert.ok(!((await run(store, "tok-new")).out instanceof Response));
    clock.advance(1800_001);
    assert.equal(status((await run(store, "tok-old")).out), 401);
    assert.ok(!((await run(store, "tok-new")).out instanceof Response));
  });

  it("refuses a key bound to a different resource and names the reason", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock, { resource: "https://other-node.example-tailnet.ts.net/luna/mcp" })]);
    const { out, trace } = await run(new KeyStore(file, clock.now), "tok-1");
    assert.equal(status(out), 401);
    assert.equal(trace.reason, "resource-mismatch");
    assert.equal(trace.principal?.keyId, "key-test-1");
  });

  it("accepts a resource that differs only by one trailing slash or a fragment", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [
      keyRecord("tok-slash", clock, { keyId: "key-slash", resource: `${PUBLIC_URL}/` }),
      keyRecord("tok-frag", clock, { keyId: "key-frag", resource: `${PUBLIC_URL}#frag` }),
    ]);
    const store = new KeyStore(file, clock.now);
    assert.ok(!((await run(store, "tok-slash")).out instanceof Response));
    assert.ok(!((await run(store, "tok-frag")).out instanceof Response));
  });

  it("refuses a record whose resource is not an https URL", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "keys.json");
    await writeKeysRaw(file, [keyRecord("tok-1", clock, { resource: "http://example-node.example-tailnet.ts.net/luna/mcp" })]);
    assert.equal(status((await run(new KeyStore(file, clock.now), "tok-1")).out), 401);
  });
});

describe("keys file helpers", () => {
  it("writes the file with mode 0600 in a 0700 directory and reads it back", async (t) => {
    const dir = await scratch(t);
    const clock = makeClock();
    const file = join(dir, "nested", "keys.json");
    await writeKeysFile(file, [keyRecord("tok-1", clock)]);
    const { stat } = await import("node:fs/promises");
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    assert.equal((await stat(join(dir, "nested"))).mode & 0o777, 0o700);
    const read = await readKeysFile(file);
    assert.equal(read.keys[0]?.hash, hashKey("tok-1"));
  });

  it("hashes with SHA-256 hex", () => {
    assert.equal(hashKey("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });

  it("derives the default file from XDG_CONFIG_HOME, then HOME", () => {
    assert.equal(defaultKeysFile({ XDG_CONFIG_HOME: "/srv/xdg" }), "/srv/xdg/himmel/luna-mcp-keys.json");
    assert.equal(defaultKeysFile({ HOME: "/srv/user" }), "/srv/user/.config/himmel/luna-mcp-keys.json");
  });
});

describe("checkHostAndOrigin", () => {
  const req = (headers: Record<string, string>) => new Request(PUBLIC_URL, { method: "POST", headers });

  it("accepts the public host with or without a port, and a request with no Origin", () => {
    assert.equal(checkHostAndOrigin(req({ host: HOST }), URL_), null);
    assert.equal(checkHostAndOrigin(req({ host: `${HOST}:443` }), URL_), null);
    assert.equal(checkHostAndOrigin(req({ host: HOST, origin: `https://${HOST}` }), URL_), null);
  });

  it("refuses a disallowed or missing Host", () => {
    assert.equal(checkHostAndOrigin(req({ host: "evil.example" }), URL_), "host");
    assert.equal(checkHostAndOrigin(req({ host: "127.0.0.1:8190" }), URL_), "host");
    assert.equal(checkHostAndOrigin(req({}), URL_), "host");
  });

  it("refuses a forged or opaque Origin", () => {
    assert.equal(checkHostAndOrigin(req({ host: HOST, origin: "https://evil.example" }), URL_), "origin");
    assert.equal(checkHostAndOrigin(req({ host: HOST, origin: "null" }), URL_), "origin");
  });
});
