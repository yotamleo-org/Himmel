import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { mintRetaskNonce as briefNonce } from "../telegram/brief-blocks";
import { mintRetaskNonce as spawnNonce } from "../telegram/spawn-common";
import type { Peer } from "./config";
import { Chain, readChain } from "./chain";
import { checkOutbound, refusalRecord, type OutCtx } from "./egress";

// Addresses are built, not written, so the leak-class gate sees no literal LAN address.
const ip = (...o: number[]) => o.join(".");
const HIMMEL_ROOT = join(import.meta.dir, "..", "..");

const peer = (over: Partial<Peer> = {}): Peer => ({
  peerBotId: "555000111", chatId: -1001234567890, allowFrom: ["555000111"], opens: ["question", "status", "info"],
  maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "goomal_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" },
  ...over,
});
const ctx = (over: Partial<OutCtx> = {}): OutCtx => ({ peer: peer(), kind: "answer", isRoot: false, isTemplate: false, tainted: true, tty: false, himmelRoot: HIMMEL_ROOT, claudecode: false, ...over });

async function refused(text: string, over: Partial<OutCtx> = {}) {
  const r = await checkOutbound(text, ctx(over));
  expect(r.ok).toBe(false);
  return r as Extract<typeof r, { ok: false }>;
}
const passes = async (text: string, over: Partial<OutCtx> = {}) => expect(await checkOutbound(text, ctx(over))).toEqual({ ok: true });

test("secret shapes are refused and named", async () => {
  const gh = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2";
  expect(await refused(`token ${gh}`)).toMatchObject({ rule: "secret-shape", shape: "gh" });
  const tg = "1234567890:" + "T".repeat(35);
  expect(await refused(`bot ${tg}`)).toMatchObject({ rule: "secret-shape", shape: "bot_token" });
  expect(await refused("-----BEGIN OPENSSH PRIVATE KEY-----\nabc")).toMatchObject({ shape: "pem" });
});

test("absolute paths are refused, in every spelling the spec lists", async () => {
  for (const t of ["see /home/x/notes", "in /Users/x", "at C:/Users/x", "at C:\\Users\\x", "/tmp/claude-1000/foo", "edit /etc/x", "~/work/repo", "go to /var"]) {
    expect(await refused(t)).toMatchObject({ rule: "path" });
  }
});

test("hosts: private ranges, loopback, link-local, this hostname and internal suffixes are refused", async () => {
  for (const t of ["ssh " + ip(10, 0, 0, 5), "db at " + ip(192, 168, 1, 20), ip(172, 16, 4, 4) + " is it", ip(172, 31, 0, 1), ip(127, 0, 0, 1) + ":8080", ip(169, 254, 10, 10), "localhost:3000", "nas.local", "printer.lan", "svc.internal", "box.home.arpa", `my box ${hostname()} is up`]) {
    expect(await refused(t, { hostname: hostname() })).toMatchObject({ rule: "host" });
  }
  await passes("8.8.8.8 and " + ip(172, 32, 0, 1) + " are public", {});
  await passes("version 1.2.3.4 shipped");
});

test("a URL host still goes through the host rule", async () => {
  expect(await refused("http://" + ip(192, 168, 0, 9) + "/admin")).toMatchObject({ rule: "host" });
  expect(await refused("https://nas.local/x")).toMatchObject({ rule: "host" });
});

test("*.env filenames are refused", async () => {
  expect(await refused("copy prod.env over")).toMatchObject({ rule: "env-file" });
  expect(await refused("cat .env please")).toMatchObject({ rule: "env-file" });
  await passes("the environment is fine");
});

test("authority tokens: every minter shape is refused", async () => {
  const samples = [
    briefNonce(), spawnNonce(), "R-" + briefNonce(), "RETASK nonce " + spawnNonce(),
    "BZ-N901-1a2b3c4d", "BZ-RM-R1-1a2b3c4d", "pb9567-s3-e8b0", "x7-p1-ab12",
  ];
  for (const s of samples) expect(await refused(`here: ${s}`)).toMatchObject({ rule: "authority-token" });
  expect(await refused("nonce=abc")).toMatchObject({ rule: "authority-token" });
  expect(await refused("nonce: abc")).toMatchObject({ rule: "authority-token" });
  expect(await refused("Security reviewed: manual")).toMatchObject({ rule: "authority-token" });
  expect(await refused("approve\n123456")).toMatchObject({ rule: "authority-token" });
  expect(await refused("deny 654321")).toMatchObject({ rule: "authority-token" });
});

test("the spec's pass list passes", async () => {
  await passes("https://github.com/yotamleo-org/Himmel/pull/4940");
  await passes("commit " + "a".repeat(40));
  await passes("due 08-11-2026");
  await passes("track it in slice-b-9569");
  await passes("מה שלומך ".repeat(300).slice(0, 3000));
  await passes("and/or w/ TCP/IP, I/O");
});

test("an answer passes when every root kind is disabled", async () => {
  const closed = peer({ theirs: { username: "goomal_bot", opens: [], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
  await passes("here you go", { peer: closed, kind: "answer", isRoot: false });
});

test("size: 4001 characters are refused; 4000 pass; 4000 emoji are 8000 units and refused", async () => {
  expect(await refused("x".repeat(4001))).toMatchObject({ rule: "too-long" });
  await passes("x".repeat(4000));
  expect(await refused("😀".repeat(4000))).toMatchObject({ rule: "too-long" });
});

test("empty text is refused", async () => {
  expect(await refused("   ")).toMatchObject({ rule: "empty" });
});

test("policy: unknown or not-live peer, root kind outside theirs.opens, answer as root, unknown kind", async () => {
  expect(await refused("hi", { peer: undefined })).toMatchObject({ rule: "unknown-peer" });
  expect(await refused("hi", { peer: peer({ chatId: null }) })).toMatchObject({ rule: "peer-not-live" });
  const narrow = peer({ theirs: { username: "goomal_bot", opens: ["info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
  expect(await refused("hi", { peer: narrow, kind: "status", isRoot: true })).toMatchObject({ rule: "kind-not-open" });
  await passes("hi", { peer: narrow, kind: "info", isRoot: true });
  expect(await refused("hi", { kind: "answer", isRoot: true })).toMatchObject({ rule: "answer-needs-thread" });
  expect(await refused("hi", { kind: "run", isRoot: true })).toMatchObject({ rule: "unknown-kind" });
});

test("policy: a send beyond their caps is refused", async () => {
  expect(await refused("hi", { kind: "info", isRoot: true, usage: { openOutbound: 5, sentLastMinute: 0 } })).toMatchObject({ rule: "their-open-threads" });
  expect(await refused("hi", { kind: "info", isRoot: true, usage: { openOutbound: 0, sentLastMinute: 10 } })).toMatchObject({ rule: "their-rate" });
  await passes("hi", { kind: "info", isRoot: true, usage: { openOutbound: 4, sentLastMinute: 9 } });
  await passes("reply", { kind: "answer", usage: { openOutbound: 5, sentLastMinute: 0 } });
});

test("a matrix deny for peer-desk to peer-telegram refuses", async () => {
  const deny = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "deny", why: "test" }] };
  expect(await refused("hi", { matrix: deny })).toMatchObject({ rule: "egress-matrix" });
  const missing = { default: "deny", rules: [] };
  expect(await refused("hi", { matrix: missing })).toMatchObject({ rule: "egress-matrix" });
});

test("the real matrix allows a peer-desk message", async () => {
  await passes("hello");
});

test("templates skip the opens check but not the content rules", async () => {
  const closed = peer({ theirs: { username: "goomal_bot", opens: [], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
  await passes("#tpl:receipt #12 id=deadbeef", { peer: closed, kind: "receipt", isRoot: false, isTemplate: true });
  expect(await refused("see /home/x", { kind: "receipt", isTemplate: true })).toMatchObject({ rule: "path" });
});

test("--allow-shape waives one low-precision shape only with a tty and no CLAUDECODE", async () => {
  const text = "Tests pass: 12 fail: 0";
  expect(await refused(text)).toMatchObject({ shape: "pass_bare" });
  await passes(text, { allowShape: "pass_bare", tty: true, claudecode: false, tainted: false });
  expect(await refused(text, { allowShape: "pass_bare", tty: true, claudecode: true })).toMatchObject({ shape: "pass_bare" });
  expect(await refused(text, { allowShape: "pass_bare", tty: false })).toMatchObject({ shape: "pass_bare" });
  expect(await refused(text, { allowShape: "pass_bare", tty: true, tainted: true })).toMatchObject({ shape: "pass_bare" });
  expect(await refused(text, { allowShape: "dash_p", tty: true })).toMatchObject({ shape: "pass_bare" });
});

test("--allow-shape is refused for a high-precision shape, and a waived low shape cannot hide a key block", async () => {
  const gh = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2";
  expect(await refused(`token ${gh}`, { allowShape: "gh", tty: true })).toMatchObject({ shape: "gh" });
  const both = "Tests pass: 12 fail: 0\n-----BEGIN RSA PRIVATE KEY-----\nabc";
  expect(await refused(both, { allowShape: "pass_bare", tty: true, tainted: false })).toMatchObject({ shape: "pem" });
});

test("a redact_check failure to run refuses rather than passes", async () => {
  expect(await refused("hello", { himmelRoot: "/nonexistent/root" })).toMatchObject({ rule: "redact-check-failed" });
});

test("a refused send chains only reason, shape, sha256, length and ts", async () => {
  const dir = mkdtempSync(join(tmpdir(), "peer-egress-"));
  const text = "CANARY-9f3a7 token ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2";
  const res = await refused(text);
  const rec = refusalRecord(text, res, 1_731_000_000);
  expect(Object.keys(rec).sort()).toEqual(["kind", "length", "reason", "sha256", "shape", "ts"]);
  expect(rec).toMatchObject({ kind: "refused", reason: "secret-shape", shape: "gh", length: text.length, ts: 1_731_000_000 });
  const file = join(dir, "outbox.jsonl");
  await new Chain().append(file, rec);
  expect(readFileSync(file, "utf8")).not.toContain("CANARY");
  expect(readFileSync(file, "utf8")).not.toContain("ghp_");
  expect(readChain(file)).toHaveLength(1);
  expect(readdirSync(dir)).toEqual(["outbox.jsonl"]);
});
