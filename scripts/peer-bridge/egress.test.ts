import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import * as EG from "./egress";
import { runProc } from "./proc";
import { cardMessage } from "./config";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { mintRetaskNonce as briefNonce } from "../telegram/brief-blocks";
import { mintRetaskNonce as spawnNonce } from "../telegram/spawn-common";
import type { Peer } from "./config";
import { Chain, readChain } from "./chain";
import { loadMatrix } from "../guardrails/egress-matrix-eval.mjs";
import { checkEnvelopeOutbound, checkOutbound, refusalRecord, type EnvOutCtx, type OutCtx } from "./egress";
import { buildEnvelope, encodeCanonical, type Envelope, type Kind } from "./envelope";
import { sign } from "./sign";
import * as TE from "./testlib-envelope";

const ip = (...o: number[]) => o.join(".");
const HIMMEL_ROOT = join(import.meta.dir, "..", "..");

const peer = (over: Partial<Peer> = {}): Peer => ({
  peerBotId: "555000111", chatId: -1001234567890, allowFrom: ["555000111"], opens: ["question", "status", "info"],
  maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" },
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
  const closed = peer({ theirs: { username: "example_bot", opens: [], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
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
  const narrow = peer({ theirs: { username: "example_bot", opens: ["info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
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

test("operator-reply corpus is allowed to peer-telegram for peer-message and selected by OutCtx.corpus", async () => {
  const real = loadMatrix();
  const { evaluate } = await import("../guardrails/egress-matrix-eval.mjs");
  expect(evaluate(real, "operator-reply", "peer-telegram", "peer-message").verdict).toBe("allow");
  expect(evaluate(real, "operator-reply", "peer-telegram", "enrichment").verdict).toBe("deny");
  const onlyReply = { default: "deny", rules: [{ corpus: "operator-reply", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "test" }] };
  const onlyDesk = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "test" }] };
  await passes("hello", { matrix: onlyReply, corpus: "operator-reply" });
  expect(await refused("hello", { matrix: onlyReply })).toMatchObject({ rule: "egress-matrix" });
  expect(await refused("hello", { matrix: onlyDesk, corpus: "operator-reply" })).toMatchObject({ rule: "egress-matrix" });
  await passes("hello", { matrix: onlyDesk, corpus: "peer-desk" });
});

test("templates skip the opens check but not the content rules", async () => {
  const closed = peer({ theirs: { username: "example_bot", opens: [], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } });
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


const ourStation = TE.mkStation("yotam");
const otherStation = TE.mkStation("someone");
afterAll(() => { TE.dropStation(ourStation); TE.dropStation(otherStation); });

const ours = (kind: Kind, body: Record<string, unknown>, over: Record<string, unknown> = {}) =>
  ({ ...buildEnvelope(kind, body, { from: "yotam", to: "example", chat: -1001234567890, now: TE.NOW_S }), ...over }) as Envelope;
const outLines = (env: Envelope, st = ourStation, to = "example_bot"): string[] => TE.envLines(env, st, { to });
const envPeer = () => peer({ theirs: { username: "example_bot", opens: [], maxOpenThreads: 1, maxPerMinute: 1, copiedAt: "2026-11-20", stationName: "example", keys: [] } });
const ectx = (over: Partial<EnvOutCtx> = {}): EnvOutCtx => ({ peer: envPeer(), self: "yotam", keyDir: ourStation.dir, himmelRoot: HIMMEL_ROOT, hostname: "testbox", ...over });
async function envRefused(lines: string[], rule: string, over: Partial<EnvOutCtx> = {}) {
  expect(await checkEnvelopeOutbound(lines, ectx(over))).toMatchObject({ ok: false, rule });
}
const envPasses = async (lines: string[], over: Partial<EnvOutCtx> = {}) => expect(await checkEnvelopeOutbound(lines, ectx(over))).toEqual({ ok: true });

test("a signed envelope of every kind passes the envelope policy", async () => {
  for (const [name, kind, body] of TE.KIND_SAMPLES) {
    const lines = outLines(ours(kind, body));
    expect([name, await checkEnvelopeOutbound(lines, ectx())]).toEqual([name, { ok: true }]);
  }
});

test("a field the schema refuses is refused, even when the line is validly signed", async () => {
  const bad = ours("req", TE.REQ_BODY);
  const line2 = `#env:v1 k=${ourStation.key.id} id=${bad.msg}`;
  const signed = (line3: string) => ["/peer@example_bot", line2, line3, `sig=${sign(line2, line3, ourStation.keyPath)}`];
  const line3 = encodeCanonical(bad);
  await envRefused(signed(line3.replace("scripts/hooks/test-a.sh", "scripts/../x.sh")), "schema");
  await envRefused(signed(line3.replace("run-suite", "run-prompt")), "schema");
});

test("line 4 passes only as our signature over lines 2 and 3: another key, a token-shaped line, a bad shape and a changed byte all fail", async () => {
  const env = ours("halt", {});
  const good = outLines(env);
  await envRefused(outLines(env, otherStation).map((l, i) => (i === 1 ? good[1] : l)), "signature");
  await envRefused([good[0], good[1], good[2], "sig=" + "T".repeat(86)], "signature");
  await envRefused([good[0], good[1], good[2], "sig=" + "1234567890".repeat(8) + "abcdef"], "signature");
  await envRefused([good[0], good[1], good[2], good[3].slice(0, -1)], "signature");
  await envRefused([good[0], good[1], good[2], "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2"], "signature");
  await envRefused([good[0], good[1], good[2] + " ", good[3]], "signature");
});

test("line 3 meets every slice A content rule", async () => {
  const toHost = ours("halt", {}, { to: "testbox" });
  await envRefused(outLines(toHost), "host", { peer: { ...envPeer(), theirs: { ...envPeer().theirs, stationName: "testbox" } } as Peer, hostname: "testbox" });
  await envRefused(outLines(ours("req", { ...TE.REQ_BODY, suites: ["scripts/prod.env.sh"] })), "env-file");
});

test("the /peer@ line does not trip the path rule, though the whole text would", async () => {
  const lines = outLines(ours("halt", {}));
  expect(await checkOutbound(lines.join("\n"), ctx())).toMatchObject({ ok: false, rule: "path" });
  await envPasses(lines);
});

test("no thread or opens check runs: a peer that opens nothing and allows one thread still gets envelopes", async () => {
  expect(envPeer().theirs.opens).toEqual([]);
  await envPasses(outLines(ours("capacity-ask", {})), { peer: envPeer() });
});

test("the address line, line 2, the key id and the binding are checked against our config", async () => {
  const env = ours("halt", {});
  const [a, b, c, d] = outLines(env);
  await envRefused([a.replace("example_bot", "other_bot"), b, c, d], "address");
  await envRefused([a, b.replace(/k=[0-9a-f]{8}/, "k=00000000"), c, d], "key-id");
  await envRefused([a, b.toUpperCase(), c, d], "line-shape");
  await envRefused([a, b, c], "line-shape");
  await envRefused([a, b, c, d, "extra"], "line-shape");
  await envRefused(outLines(ours("halt", {}, { from: "intruder" })), "binding");
  await envRefused(outLines(ours("halt", {}, { to: "someone-else" })), "binding");
  await envRefused(outLines(ours("halt", {}, { chat: "-1009999999999" })), "binding");
  await envRefused(outLines(env), "binding", { self: "another-name" });
  await envRefused(outLines(env), "no-key", { keyDir: otherStation.dir + "-missing" });
});

test("the envelope is refused for an unknown or not-live peer, and past the text cap", async () => {
  const lines = outLines(ours("halt", {}));
  await envRefused(lines, "unknown-peer", { peer: undefined });
  await envRefused(lines, "peer-not-live", { peer: { ...envPeer(), chatId: null } });
  await envRefused(lines, "too-long", { maxTextChars: 100 });
});

test("the matrix row decides: peer-jobs to peer-telegram is allowed, and no rule means refused", async () => {
  await envPasses(outLines(ours("halt", {})), { matrix: loadMatrix() });
  const empty = { default: "deny", rules: [] };
  await envRefused(outLines(ours("halt", {})), "egress-matrix", { matrix: empty });
  const textOnly = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "allow" }] };
  await envRefused(outLines(ours("halt", {})), "egress-matrix", { matrix: textOnly });
});

const slashed = [TE.keyWithShape(/\+\//), TE.keyWithShape(/^\//)];
afterAll(() => { for (const s of slashed) TE.dropStation(s); });
const cardPeer = () => peer({ theirs: { ...peer().theirs, username: "their_bot" } });
const cardCtx = (st: TE.Station, over: Record<string, unknown> = {}) => ({ peer: cardPeer(), self: "yotam", keyDir: st.dir, himmelRoot: HIMMEL_ROOT, hostname: "box.lan", ...over }) as any;
const card = (st: TE.Station, station = "yotam") => cardMessage("their_bot", station, st.key.pub);
async function cardRefused(text: string, rule: string, st: TE.Station, over: Record<string, unknown> = {}) {
  expect(await EG.checkCardOutbound(text, cardCtx(st, over))).toMatchObject({ ok: false, rule });
}

test("the card gate passes the exact card for keys whose base64 holds slashes, which the free-text gate refuses", async () => {
  for (const st of slashed) {
    expect(await EG.checkCardOutbound(card(st), cardCtx(st))).toEqual({ ok: true });
    expect(await refused(card(st).split("\n")[1], { kind: "info" })).toMatchObject({ rule: "path" });
  }
});

test("the card gate refuses any other bytes, another key, a dead chat, a host name, no matrix row and any secret shape", async () => {
  const st = slashed[0];
  await cardRefused(card(st) + " ", "card-text", st);
  await cardRefused(card(st).replace("station=yotam", "station=yotan"), "card-text", st);
  await cardRefused(card(st) + "\nmore", "card-text", st);
  await cardRefused(card(slashed[1]), "card-text", st);
  await cardRefused(card(st), "unknown-peer", st, { peer: undefined });
  await cardRefused(card(st), "peer-not-live", st, { peer: { ...cardPeer(), chatId: null } });
  await cardRefused(card(st), "no-name", st, { self: undefined });
  await cardRefused(card(st), "no-key", st, { keyDir: st.dir + "-missing" });
  await cardRefused(card(st, "box"), "host", st, { self: "box" });
  await cardRefused(card(st), "egress-matrix", st, { matrix: { default: "deny", rules: [{ corpus: "peer-jobs", provider: "peer-telegram", purpose: "peer-message", verdict: "allow" }] } });
  const stubRoot = mkdtempSync(join(tmpdir(), "peer-redact-"));
  mkdirSync(join(stubRoot, "scripts", "lib"), { recursive: true });
  writeFileSync(join(stubRoot, "scripts", "lib", "redact.sh"), "redact_check() { cat >/dev/null; echo 'shape=gh precision=low'; return 10; }\n");
  await cardRefused(card(st), "secret-shape", st, { himmelRoot: stubRoot, allowShape: "gh", tty: true, claudecode: false });
});

test("the real redact_check passes fifty random cards in one run", async () => {
  const cards = Array.from({ length: 50 }, () => {
    const st = TE.mkStation("yotam");
    try { return card(st); } finally { TE.dropStation(st); }
  });
  const run = await runProc(["bash", "-c", `. ${HIMMEL_ROOT}/scripts/lib/redact.sh && redact_check`], { input: cards.join("\n"), env: { PATH: process.env.PATH ?? "/usr/bin:/bin" }, timeoutMs: 15_000 });
  expect([run.timedOut, run.code]).toEqual([false, 0]);
});
