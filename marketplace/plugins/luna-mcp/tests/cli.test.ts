import assert from "node:assert/strict";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { describe, it, type TestContext } from "node:test";
import { createAudit } from "../src/audit.js";
import { bearerGate, hashKey, KeyStore, readKeysFile } from "../src/auth.js";
import { listKeys, mintKey, revokeKey, rotateKey, runKeys, type KeysIo } from "../src/cli/keys.js";
import { runAudit } from "../src/cli/audit.js";
import { makeClock, PUBLIC_URL, scratch, type Clock } from "./helpers.js";

const DAY = 86400_000;

function counter(): (n: number) => Buffer {
  let c = 0;
  return (n) => Buffer.alloc(n, ++c);
}

interface Rig {
  file: string;
  clock: Clock;
  out: string[];
  err: string[];
  io: KeysIo;
}

async function rig(t: TestContext, collections: string[] = ["luna", "luna-pa", "himmel", "salus", "jira-himmel"]): Promise<Rig> {
  const dir = await scratch(t);
  const file = join(dir, "cfg", "luna-mcp-keys.json");
  const clock = makeClock();
  const out: string[] = [];
  const err: string[] = [];
  const io: KeysIo = {
    env: { LUNA_MCP_KEYS_FILE: file, LUNA_MCP_PUBLIC_URL: PUBLIC_URL },
    stdout: (s) => out.push(s),
    stderr: (s) => err.push(s),
    now: clock.now,
    randomBytes: counter(),
    listCollections: async () => collections,
  };
  return { file, clock, out, err, io };
}

const mintArgs = ["mint", "--principal", "grokbot", "--provider", "xai-grokbot", "--roles", "reader", "--collections", "luna,himmel", "--ttl", "90d"];
const tokenOf = (out: string[]): string => /key: (lmk_[A-Za-z0-9_-]+)/.exec(out.join("\n"))?.[1] ?? assert.fail("no key printed");
const idOf = (out: string[]): string => /keyId: (lk_[0-9a-f]+)/.exec(out.join("\n"))?.[1] ?? assert.fail("no keyId printed");

async function gate(file: string, clock: Clock, token: string): Promise<number> {
  const out = await bearerGate(new KeyStore(file, clock.now), new URL(PUBLIC_URL), {})(new Request(PUBLIC_URL, { method: "POST", headers: { authorization: `Bearer ${token}` } }));
  return out instanceof Response ? out.status : 200;
}

describe("luna-mcp-keys mint", () => {
  it("stores only the hash, writes the file 0600 and prints the plaintext key once", async (t) => {
    const r = await rig(t);
    assert.equal(await runKeys(mintArgs, r.io), 0);
    const token = tokenOf(r.out);
    const id = idOf(r.out);
    const raw = await readFile(r.file, "utf8");
    assert.ok(!raw.includes(token), "plaintext must not be stored");
    assert.ok(raw.includes(hashKey(token)));
    assert.equal((await stat(r.file)).mode & 0o777, 0o600);
    assert.equal((await stat(join(r.file, ".."))).mode & 0o777, 0o700);
    const { keys } = await readKeysFile(r.file);
    assert.equal(keys.length, 1);
    const k = keys[0]!;
    assert.deepEqual([k.keyId, k.principal, k.egressProvider, k.resource, k.roles, k.allowedCollections, k.revoked], [id, "grokbot", "xai-grokbot", PUBLIC_URL, ["reader"], ["luna", "himmel"], false]);
    assert.equal(Date.parse(k.expiresAt), r.clock.now() + 90 * DAY);
    assert.equal(await gate(r.file, r.clock, token), 200);

    r.out.length = 0;
    assert.equal(await runKeys(["list"], r.io), 0);
    const listing = r.out.join("\n");
    assert.ok(listing.includes(id) && listing.includes("grokbot") && listing.includes("active"));
    assert.ok(!listing.includes(token) && !listing.includes(hashKey(token)));
  });

  it("expands --collections all to the configured collections without salus", async (t) => {
    const r = await rig(t);
    assert.equal(await runKeys(["mint", "--principal", "grokbot", "--provider", "openai-chatgpt", "--collections", "all", "--ttl", "30d"], r.io), 0);
    const { keys } = await readKeysFile(r.file);
    assert.deepEqual(keys[0]!.allowedCollections, ["luna", "luna-pa", "himmel", "jira-himmel"]);
    assert.deepEqual(keys[0]!.roles, ["reader"]);
    assert.equal(keys[0]!.resource, PUBLIC_URL);
  });

  it("accepts a Luna-only key", async (t) => {
    const r = await rig(t);
    assert.equal(await runKeys(["mint", "--principal", "dots", "--provider", "openai-chatgpt", "--collections", "luna-pa", "--ttl", "7d"], r.io), 0);
    assert.deepEqual((await readKeysFile(r.file)).keys[0]!.allowedCollections, ["luna-pa"]);
  });

  it("refuses salus, an unsupported role, an unknown provider or collection, a non-https resource and a bad ttl", async (t) => {
    const cases: [string, string[]][] = [
      ["salus", ["--collections", "salus"]],
      ["salus via luna list", ["--collections", "luna,salus"]],
      ["manager role", ["--roles", "manager"]],
      ["admin role", ["--roles", "reader,admin"]],
      ["provider", ["--provider", "local-ollama"]],
      ["unknown collection", ["--collections", "nonesuch"]],
      ["http resource", ["--resource", "http://example-node.example-tailnet.ts.net/luna/mcp"]],
      ["bad resource", ["--resource", "not a url"]],
      ["ttl too long", ["--ttl", "400d"]],
      ["ttl zero", ["--ttl", "0d"]],
      ["ttl bad unit", ["--ttl", "90y"]],
      ["ttl bare number", ["--ttl", "90"]],
      ["principal with spaces", ["--principal", "gro kbot"]],
    ];
    for (const [label, over] of cases) {
      const r = await rig(t);
      const args = [...mintArgs];
      for (let i = 0; i < over.length; i += 2) {
        const at = args.indexOf(over[i]!);
        if (at >= 0) args[at + 1] = over[i + 1]!;
        else args.push(over[i]!, over[i + 1]!);
      }
      assert.notEqual(await runKeys(args, r.io), 0, label);
      assert.ok(r.err.join("").length > 0, label);
      await assert.rejects(stat(r.file), label);
      assert.ok(!/lmk_/.test(r.out.join("")), label);
    }
  });

  it("requires a principal, provider, collections and ttl", async (t) => {
    for (const drop of ["--principal", "--provider", "--collections", "--ttl"]) {
      const r = await rig(t);
      const args = [...mintArgs];
      const at = args.indexOf(drop);
      args.splice(at, 2);
      assert.notEqual(await runKeys(args, r.io), 0, drop);
    }
  });

  it("refuses an unknown command and prints usage", async (t) => {
    const r = await rig(t);
    assert.notEqual(await runKeys(["frobnicate"], r.io), 0);
    assert.notEqual(await runKeys([], r.io), 0);
    assert.match(r.err.join(""), /usage/i);
  });
});

describe("luna-mcp-keys revoke, list and rotate", () => {
  it("revokes a key so that a live store refuses it on the next call", async (t) => {
    const r = await rig(t);
    await runKeys(mintArgs, r.io);
    const token = tokenOf(r.out);
    const id = idOf(r.out);
    const store = new KeyStore(r.file, r.clock.now);
    const call = async () => {
      const out = await bearerGate(store, new URL(PUBLIC_URL), {})(new Request(PUBLIC_URL, { method: "POST", headers: { authorization: `Bearer ${token}` } }));
      return out instanceof Response ? out.status : 200;
    };
    assert.equal(await call(), 200);
    assert.equal(await runKeys(["revoke", id], r.io), 0);
    assert.equal(await call(), 401);
    assert.equal((await stat(r.file)).mode & 0o777, 0o600);
    assert.notEqual(await runKeys(["revoke", "lk_nonesuch"], r.io), 0);
  });

  it("lists active, expired and revoked keys by status", async (t) => {
    const r = await rig(t);
    const a = await mintKey(r.file, { principal: "a", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: DAY }, r.io);
    const b = await mintKey(r.file, { principal: "b", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: 3 * DAY }, r.io);
    const c = await mintKey(r.file, { principal: "c", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: 3 * DAY }, r.io);
    await revokeKey(r.file, c.keyId);
    r.clock.advance(2 * DAY);
    const rows = await listKeys(r.file, r.clock.now);
    const status = Object.fromEntries(rows.map((x) => [x.keyId, x.status]));
    assert.deepEqual(status, { [a.keyId]: "expired", [b.keyId]: "active", [c.keyId]: "revoked" });
    assert.ok(rows.every((x) => !("hash" in x)));
  });

  it("rotates with overlap: the successor works at once, the old key until its shortened expiry", async (t) => {
    const r = await rig(t);
    await runKeys(mintArgs, r.io);
    const oldToken = tokenOf(r.out);
    const oldId = idOf(r.out);
    r.out.length = 0;
    assert.equal(await runKeys(["rotate", oldId, "--ttl", "90d", "--overlap", "24h"], r.io), 0);
    const newToken = tokenOf(r.out);
    assert.notEqual(newToken, oldToken);
    assert.ok(r.out.join("\n").includes(oldId));
    const { keys } = await readKeysFile(r.file);
    assert.equal(keys.length, 2);
    const [oldKey, newKey] = [keys.find((k) => k.keyId === oldId)!, keys.find((k) => k.keyId !== oldId)!];
    assert.equal(Date.parse(oldKey.expiresAt), r.clock.now() + DAY);
    assert.equal(Date.parse(newKey.expiresAt), r.clock.now() + 90 * DAY);
    assert.deepEqual([newKey.principal, newKey.egressProvider, newKey.resource, newKey.roles, newKey.allowedCollections], [oldKey.principal, oldKey.egressProvider, oldKey.resource, oldKey.roles, oldKey.allowedCollections]);
    assert.equal(await gate(r.file, r.clock, oldToken), 200);
    assert.equal(await gate(r.file, r.clock, newToken), 200);
    r.clock.advance(DAY + 1);
    assert.equal(await gate(r.file, r.clock, oldToken), 401);
    assert.equal(await gate(r.file, r.clock, newToken), 200);
  });

  it("never lengthens the old key and refuses to rotate an unknown or revoked key", async (t) => {
    const r = await rig(t);
    const short = await mintKey(r.file, { principal: "a", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: 3600_000 }, r.io);
    const rotated = await rotateKey(r.file, short.keyId, { ttlMs: 30 * DAY, overlapMs: DAY }, r.io);
    assert.equal(rotated.oldExpiresAt, short.expiresAt);
    const gone = await mintKey(r.file, { principal: "b", provider: "xai-grokbot", resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: DAY }, r.io);
    await revokeKey(r.file, gone.keyId);
    await assert.rejects(rotateKey(r.file, gone.keyId, { ttlMs: DAY, overlapMs: DAY }, r.io));
    await assert.rejects(rotateKey(r.file, "lk_nonesuch", { ttlMs: DAY, overlapMs: DAY }, r.io));
  });

  it("refuses an unreadable or group-readable key file instead of overwriting it", async (t) => {
    const r = await rig(t);
    await runKeys(mintArgs, r.io);
    await writeFile(r.file, "{broken", { mode: 0o600 });
    assert.notEqual(await runKeys(mintArgs, r.io), 0);
    assert.equal(await readFile(r.file, "utf8"), "{broken");
  });
});

describe("luna-mcp-audit", () => {
  async function seeded(t: TestContext) {
    const dir = await scratch(t);
    const file = join(dir, "audit.jsonl");
    const clock = makeClock(Date.UTC(2026, 10, 26, 12, 0, 0));
    const audit = createAudit({ file, now: clock.now });
    const base = { reqId: "r", principal: "grokbot", keyId: "k", role: "reader", collection: "luna", corpus: "luna-personal", provider: "xai-grokbot", purpose: "luna-mcp-read", reason: null };
    await audit.write({ ...base, reqId: "r1", tool: "read_doc", path: "CLAUDE.md", verdict: "allow" });
    clock.advance(1000);
    await audit.write({ ...base, reqId: "r2", tool: "read_doc", path: ".env", verdict: "deny", reason: "dot-segment" });
    clock.advance(1000);
    await audit.write({ ...base, reqId: "r3", principal: "dots", tool: "qmd_search", path: null, verdict: "allow" });
    clock.advance(1000);
    await audit.write({ ...base, reqId: "r4", tool: "read_doc", path: "sessions/x.md", verdict: "deny", reason: "role-path" });
    const out: string[] = [];
    const err: string[] = [];
    return { file, out, err, io: { env: { LUNA_MCP_AUDIT_FILE: file }, stdout: (s: string) => out.push(s), stderr: (s: string) => err.push(s) } };
  }

  it("prints the last N entries, oldest first", async (t) => {
    const s = await seeded(t);
    assert.equal(await runAudit(["--tail", "2"], s.io), 0);
    const text = s.out.join("");
    assert.ok(!text.includes("CLAUDE.md") && !text.includes(".env"));
    assert.ok(text.indexOf("qmd_search") < text.indexOf("sessions/x.md"));
  });

  it("filters by verdict, principal and tool", async (t) => {
    const s = await seeded(t);
    assert.equal(await runAudit(["--verdict", "deny"], s.io), 0);
    assert.match(s.out.join(""), /\.env/);
    assert.ok(!/CLAUDE\.md/.test(s.out.join("")));
    s.out.length = 0;
    await runAudit(["--principal", "dots"], s.io);
    assert.equal(s.out.join("").trim().split("\n").length, 1);
    s.out.length = 0;
    await runAudit(["--tool", "qmd_search"], s.io);
    assert.equal(s.out.join("").trim().split("\n").length, 1);
  });

  it("prints raw JSON lines with --json and skips unreadable lines with a notice", async (t) => {
    const s = await seeded(t);
    await writeFile(s.file, `${await readFile(s.file, "utf8")}garbage line\n`, { mode: 0o600 });
    assert.equal(await runAudit(["--json"], s.io), 0);
    const rows = s.out.join("").trim().split("\n").map((l) => JSON.parse(l) as { reqId: string });
    assert.deepEqual(rows.map((r) => r.reqId), ["r1", "r2", "r3", "r4"]);
    assert.match(s.err.join(""), /skipped 1/);
  });

  it("fails on a missing file and on bad flags", async (t) => {
    const s = await seeded(t);
    assert.notEqual(await runAudit(["--file", join(s.file, "..", "absent.jsonl")], s.io), 0);
    assert.notEqual(await runAudit(["--tail", "abc"], s.io), 0);
    assert.notEqual(await runAudit(["--verdict", "maybe"], s.io), 0);
    assert.notEqual(await runAudit(["--bogus"], s.io), 0);
  });
});

describe("key file locking", () => {
  const params = { principal: "a", provider: "xai-grokbot" as const, resource: PUBLIC_URL, roles: ["reader"], collections: ["luna"], ttlMs: DAY };
  const exists = (path: string): Promise<boolean> => stat(path).then(() => true, () => false);

  it("keeps a revocation when a mint is in flight on the same key file", async (t) => {
    const r = await rig(t);
    const first = await mintKey(r.file, params, r.io);
    let mintPaused!: () => void;
    const mintIsPaused = new Promise<void>((resolve) => (mintPaused = resolve));
    let revokerWaiting!: () => void;
    const revokerIsWaiting = new Promise<void>((resolve) => (revokerWaiting = resolve));
    let revokerDone!: () => void;
    const revokerFinished = new Promise<void>((resolve) => (revokerDone = resolve));
    const minting = mintKey(r.file, { ...params, principal: "b" }, {
      ...r.io,
      afterRead: async () => {
        mintPaused();
        await Promise.race([revokerIsWaiting, revokerFinished]);
      },
    });
    await mintIsPaused;
    const revoking = revokeKey(r.file, first.keyId, {
      ...r.io,
      sleep: async () => {
        revokerWaiting();
        await minting;
      },
    }).finally(revokerDone);
    await Promise.all([minting, revoking]);
    const { keys } = await readKeysFile(r.file);
    assert.equal(keys.length, 2);
    assert.equal(keys.find((k) => k.keyId === first.keyId)?.revoked, true);
    assert.equal((await stat(r.file)).mode & 0o777, 0o600);
  });

  it("keeps a revocation when a rotation is in flight on the same key file", async (t) => {
    const r = await rig(t);
    const first = await mintKey(r.file, params, r.io);
    const other = await mintKey(r.file, { ...params, principal: "c" }, r.io);
    let rotatePaused!: () => void;
    const rotateIsPaused = new Promise<void>((resolve) => (rotatePaused = resolve));
    let revokerWaiting!: () => void;
    const revokerIsWaiting = new Promise<void>((resolve) => (revokerWaiting = resolve));
    let revokerDone!: () => void;
    const revokerFinished = new Promise<void>((resolve) => (revokerDone = resolve));
    const rotating = rotateKey(r.file, first.keyId, { ttlMs: DAY, overlapMs: DAY / 2 }, {
      ...r.io,
      afterRead: async () => {
        rotatePaused();
        await Promise.race([revokerIsWaiting, revokerFinished]);
      },
    });
    await rotateIsPaused;
    const revoking = revokeKey(r.file, other.keyId, {
      ...r.io,
      sleep: async () => {
        revokerWaiting();
        await rotating;
      },
    }).finally(revokerDone);
    await Promise.all([rotating, revoking]);
    const { keys } = await readKeysFile(r.file);
    assert.equal(keys.length, 3);
    assert.equal(keys.find((k) => k.keyId === other.keyId)?.revoked, true);
  });

  it("holds a lock file while it works and removes it afterwards, also when the operation fails", async (t) => {
    const r = await rig(t);
    const lock = `${r.file}.lock`;
    const seen: boolean[] = [];
    await mintKey(r.file, params, { ...r.io, afterRead: async () => void seen.push(await exists(lock)) });
    assert.deepEqual(seen, [true]);
    assert.equal(await exists(lock), false);
    await assert.rejects(revokeKey(r.file, "lk_nonesuch", r.io));
    assert.equal(await exists(lock), false);
    assert.equal((await stat(r.file)).mode & 0o777, 0o600);
  });

  it("takes over a lock whose process is gone", async (t) => {
    const r = await rig(t);
    const lock = `${r.file}.lock`;
    await mkdir(dirname(r.file), { recursive: true });
    await writeFile(lock, JSON.stringify({ pid: 424242, at: r.clock.now(), token: "dead" }), { mode: 0o600 });
    const owners: number[] = [];
    await mintKey(r.file, params, {
      ...r.io,
      isAlive: () => false,
      afterRead: async () => void owners.push((JSON.parse(await readFile(lock, "utf8")) as { pid: number }).pid),
    });
    assert.deepEqual(owners, [process.pid]);
    assert.equal(await exists(lock), false);
  });

  it("takes over a lock older than the stale age even when its pid looks alive", async (t) => {
    const r = await rig(t);
    const lock = `${r.file}.lock`;
    await mkdir(dirname(r.file), { recursive: true });
    await writeFile(lock, JSON.stringify({ pid: 424242, at: r.clock.now() - 10 * 60_000, token: "old" }), { mode: 0o600 });
    const owners: number[] = [];
    await mintKey(r.file, params, {
      ...r.io,
      isAlive: () => true,
      staleMs: 60_000,
      afterRead: async () => void owners.push((JSON.parse(await readFile(lock, "utf8")) as { pid: number }).pid),
    });
    assert.deepEqual(owners, [process.pid]);
  });

  it("gives up after the bounded retries on a live fresh lock, backing off between tries, and leaves that lock alone", async (t) => {
    const r = await rig(t);
    const lock = `${r.file}.lock`;
    await mkdir(dirname(r.file), { recursive: true });
    await writeFile(lock, JSON.stringify({ pid: 424242, at: r.clock.now(), token: "live" }), { mode: 0o600 });
    const sleeps: number[] = [];
    await assert.rejects(
      mintKey(r.file, params, { ...r.io, isAlive: () => true, retries: 3, backoffMs: 20, sleep: async (ms) => void sleeps.push(ms) }),
      /locked/,
    );
    assert.deepEqual(sleeps, [20, 40, 80]);
    assert.equal(await exists(r.file), false);
    assert.match(await readFile(lock, "utf8"), /"token":"live"/);
  });
});
