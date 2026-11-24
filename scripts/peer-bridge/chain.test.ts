import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { CODE_VERSION, Chain, PidLockError, acquirePidLock, drainSpool, pollerStale, readChain, startIdentity, signTap, submitSpool, sweepResults, tapKey, tapSigOk, verifyChain, writeResult } from "./chain";
import { writeSpoolEvent } from "./spool-events";

const tmp = (p = "peer-chain-") => mkdtempSync(join(tmpdir(), p));
const peerDirWithSpool = () => { const d = tmp(); mkdirSync(join(d, "spool"), { mode: 0o700 }); return d; };
const mode = (p: string) => statSync(p).mode & 0o777;
const lastH = (file: string) => readChain(file).at(-1)?.h ?? "";

test("200 concurrent appends produce one verifying chain at 0600", async () => {
  const dir = tmp();
  const file = join(dir, "inbox.jsonl");
  const chain = new Chain();
  const out = await Promise.all(Array.from({ length: 200 }, (_, i) => chain.append(file, { kind: "peer-msg", i })));
  expect(new Set(out.map(r => r.n)).size).toBe(200);
  expect(verifyChain(file)).toEqual({ ok: true, n: 200, h: lastH(file) });
  expect(mode(file)).toBe(0o600);
  expect(readChain(file)).toHaveLength(200);
});

test("a second Chain on the same file continues the chain from disk", async () => {
  const file = join(tmp(), "outbox.jsonl");
  await new Chain().append(file, { a: 1 });
  const r = await new Chain().append(file, { a: 2 });
  expect(r.n).toBe(2);
  expect(verifyChain(file).ok).toBe(true);
});

test("a tampered record fails verification", async () => {
  const file = join(tmp(), "inbox.jsonl");
  const chain = new Chain();
  await chain.append(file, { text: "one" });
  await chain.append(file, { text: "two" });
  writeFileSync(file, readFileSync(file, "utf8").replace("one", "ONE"));
  expect(verifyChain(file).ok).toBe(false);
});

test("a torn trailing line from a crash is cut off, not fatal", async () => {
  const file = join(tmp(), "outbox.jsonl");
  await new Chain().append(file, { a: 1 });
  writeFileSync(file, readFileSync(file, "utf8") + '{"half":', { mode: 0o600 });
  const r = await new Chain().append(file, { a: 2 });
  expect(r.n).toBe(2);
  expect(verifyChain(file)).toEqual({ ok: true, n: 2, h: lastH(file) });
});

test("readChain ignores a torn trailing line and a later append still verifies", async () => {
  const file = join(tmp(), "outbox.jsonl");
  await new Chain().append(file, { a: 1 });
  writeFileSync(file, readFileSync(file, "utf8") + '{"half":', { mode: 0o600 });
  expect(readChain(file)).toHaveLength(1);
  await new Chain().append(file, { a: 2 });
  expect(readChain(file)).toHaveLength(2);
  expect(verifyChain(file)).toEqual({ ok: true, n: 2, h: lastH(file) });
  writeFileSync(file, '{"bad":\n' + readFileSync(file, "utf8"));
  expect(() => readChain(file)).toThrow();
});

test("an append failure leaves the offset uncommitted and the chain intact", async () => {
  const file = join(tmp(), "inbox.jsonl");
  let calls = 0;
  const { openChainFile } = await import("../telegram/bus");
  const chain = new Chain({ open: (f, flags) => { if (++calls === 2) throw Object.assign(new Error("EIO: i/o error"), { code: "EIO" }); return openChainFile(f, flags); } });
  let committed = 0;
  const batch = [{ file, rec: { i: 1 } }, { file, rec: { i: 2 } }, { file, rec: { i: 3 } }];
  await expect(chain.appendThenCommit(batch, async () => { committed++; })).rejects.toThrow("EIO");
  expect(committed).toBe(0);
  expect(verifyChain(file)).toEqual({ ok: true, n: 1, h: lastH(file) });
  // the failed batch can be replayed in full, and only then does the commit run
  await chain.appendThenCommit(batch.slice(1), async () => { committed++; });
  expect(committed).toBe(1);
  expect(verifyChain(file)).toEqual({ ok: true, n: 3, h: lastH(file) });
});

function holder(): Promise<{ pid: number; kill: () => Promise<void> }> {
  const child = spawn("sleep", ["30"], { stdio: "ignore" });
  return new Promise(res => child.once("spawn", () => res({
    pid: child.pid!,
    kill: () => new Promise<void>(done => { child.once("exit", () => done()); child.kill("SIGKILL"); }),
  })));
}

test("a second acquirePidLock throws while the holder is live and succeeds once it is dead", async () => {
  const lock = join(tmp(), "poller.pid");
  const h = await holder();
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start: startIdentity(h.pid) }), { mode: 0o600 });
  expect(() => acquirePidLock(lock)).toThrow(PidLockError);
  await h.kill();
  const release = acquirePidLock(lock);
  expect(JSON.parse(readFileSync(lock, "utf8")).pid).toBe(process.pid);
  expect(() => acquirePidLock(lock)).toThrow(PidLockError);
  release();
  expect(existsSync(lock)).toBe(false);
});

test("a lock file holding JSON null is stale, never a crash", () => {
  const lock = join(tmp(), "poller.pid");
  writeFileSync(lock, "null", { mode: 0o600 });
  const release = acquirePidLock(lock);
  expect(JSON.parse(readFileSync(lock, "utf8")).pid).toBe(process.pid);
  release();
});

test("a live pid whose start identity differs is a reused pid, so the lock is stale", async () => {
  const lock = join(tmp(), "poller.pid");
  const h = await holder();
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start: "not-its-start" }), { mode: 0o600 });
  const release = acquirePidLock(lock);
  release();
  await h.kill();
});

test("the macOS identity is ps lstart under LC_ALL=C TZ=UTC, so the caller's TZ never changes it", async () => {
  const bin = tmp("peer-ps-");
  const stub = join(bin, "ps");
  // GNU date takes -d @N, BSD date takes -r N; both honour TZ.
  writeFileSync(stub, '#!/bin/sh\nF="+%a %b %e %T %Y"\nTZ="$TZ" LC_ALL=C date -d @1700000000 "$F" 2>/dev/null || TZ="$TZ" LC_ALL=C date -r 1700000000 "$F"\n');
  chmodSync(stub, 0o755);
  const oldPath = process.env.PATH, oldTz = process.env.TZ;
  try {
    process.env.PATH = `${bin}:${oldPath}`;
    process.env.TZ = "Asia/Jerusalem";
    const written = startIdentity(process.pid, "darwin");
    process.env.TZ = "America/New_York";
    const checked = startIdentity(process.pid, "darwin");
    expect(written).toBe("Tue Nov 14 22:13:20 2023");
    expect(checked).toBe(written);
  } finally {
    process.env.PATH = oldPath;
    if (oldTz === undefined) delete process.env.TZ; else process.env.TZ = oldTz;
  }
});

test("the linux identity is /proc starttime and stable for a live pid", () => {
  if (process.platform !== "linux") return;
  const a = startIdentity(process.pid);
  expect(a).toMatch(/^[0-9]+$/);
  expect(startIdentity(process.pid)).toBe(a);
  expect(startIdentity(2 ** 22 + 12345)).toBeNull();
});

test("spool: each record type round-trips through drainSpool oldest first, 0600", () => {
  const dir = peerDirWithSpool();
  const recs = [
    { type: "draft", source: "send.ts", kind: "answer", replyTo: 12, text: "hi" },
    { type: "ack", sid: "abc-1", token: "T0K3N" },
    { type: "confirm", chatId: -100123 },
    { type: "draft", source: "telegram", kind: "status", text: "root" },
    { type: "tap", verb: "ok", draft: "0a1b2c3d", by: "42", ts: 1731000000 },
  ] as const;
  const names = recs.map(r => submitSpool(dir, r as any));
  for (const n of names) expect(mode(join(dir, "spool", n))).toBe(0o600);
  const drained = drainSpool(dir);
  expect(drained.map(d => d.rec)).toEqual(recs as any);
  expect(drained.map(d => d.name)).toEqual([...names].sort());
});

test("spool: the typed path's records round-trip through writeSpoolEvent, and an unknown kind, event or shape is malformed", () => {
  const dir = peerDirWithSpool();
  const good = [
    { t: "env-out", peer: "example", kind: "req", body: { sha: "a".repeat(40), suites: ["scripts/x.sh"] } },
    { t: "env-out", peer: "example", kind: "capacity-ask", body: {} },
    { t: "env-out", peer: "example", kind: "cancel", body: { jobNo: 3 } },
    { t: "env-out", peer: "example", kind: "halt", body: {} },
    ...["resolve-ok", "resolve-fail", "approve", "vm-start", "vm-done"].map(type => ({ t: "job-event", peer: "example", job: 4, event: { type } })),
  ] as const;
  const names = good.map(e => writeSpoolEvent(e as any, dir));
  for (const n of names) expect(mode(join(dir, "spool", n))).toBe(0o600);
  expect(drainSpool(dir).map(d => ("rec" in d ? d.rec.type : "malformed"))).toEqual(good.map(e => e.t));
  for (const d of drainSpool(dir)) writeResult(dir, d.name, { ok: true });

  const bad: unknown[] = [
    { type: "env-out", kind: "res", body: {} }, { type: "env-out", kind: "req" }, { type: "env-out", kind: "req", body: [] }, { type: "env-out", kind: "req", body: null },
    { type: "job-event", job: 0, event: { type: "approve" } }, { type: "job-event", job: 1.5, event: { type: "approve" } }, { type: "job-event", job: 1 },
    { type: "job-event", job: 1, event: { type: "kill" } }, { type: "job-event", job: 1, event: { type: "deadline" } }, { type: "job-event", job: 1, event: { type: "res-done" } },
  ];
  bad.forEach((b, i) => writeFileSync(join(dir, "spool", `${i}-bad.json`), JSON.stringify(b), { mode: 0o600 }));
  expect(drainSpool(dir).every(d => "malformed" in d && d.malformed)).toBe(true);
  expect(drainSpool(dir)).toHaveLength(bad.length);
});

test("a send spool record is malformed; draft and tap validate", () => {
  const dir = peerDirWithSpool();
  const bad: unknown[] = [
    { type: "send", kind: "info", text: "x" },
    { type: "draft", source: "other", kind: "info", text: "x" }, { type: "draft", kind: "info", text: "x" },
    { type: "draft", source: "send.ts", kind: "run", text: "x" }, { type: "draft", source: "send.ts", kind: "info" },
    { type: "draft", source: "send.ts", kind: "info", text: "x", replyTo: 0 }, { type: "draft", source: "send.ts", kind: "info", text: "x", allowShape: "A B" },
    { type: "tap", verb: "maybe", draft: "0a1b2c3d", by: "42", ts: 1 }, { type: "tap", verb: "ok", draft: "XYZ", by: "42", ts: 1 },
    { type: "tap", verb: "ok", draft: "0a1b2c3d", by: "", ts: 1 }, { type: "tap", verb: "no", draft: "0a1b2c3d", by: "42", ts: 1.5 }, { type: "tap", verb: "no", draft: "0a1b2c3d", by: 42, ts: 1 }, { type: "tap", verb: "ok", draft: "0a1b2c3d", by: "42", ts: 1, sig: 7 }, { type: "tap", verb: "ok", draft: "0a1b2c3d", by: "42", ts: 1, sig: "a".repeat(129) },
  ];
  bad.forEach((b, i) => writeFileSync(join(dir, "spool", `${String(i).padStart(2, "0")}-bad.json`), JSON.stringify(b), { mode: 0o600 }));
  const drained = drainSpool(dir);
  expect(drained).toHaveLength(bad.length);
  expect(drained.every(d => "malformed" in d && d.malformed)).toBe(true);
  const good = [
    { type: "draft", source: "telegram", kind: "answer", replyTo: 7, text: "ok", allowShape: "gh" },
    { type: "tap", verb: "no", draft: "ffffffff", by: "999000999", ts: 1731000000 },
  ];
  const dir2 = peerDirWithSpool();
  good.forEach(g => submitSpool(dir2, g as any));
  expect(drainSpool(dir2).map(d => ("rec" in d ? d.rec : "malformed"))).toEqual(good as any);
});

test("a malformed spool file names why, in fixed words and never with its content", () => {
  const dir = peerDirWithSpool();
  const cases: [string, string, string][] = [
    ["01-json.json", "not json SECRET", "not valid json"],
    ["02-array.json", "[1]", "not a json object"],
    ["03-type.json", JSON.stringify({ type: "frob" }), "unknown type"],
    ["04-kind.json", JSON.stringify({ type: "draft", source: "send.ts", kind: "run", text: "SECRET" }), "draft: bad kind"],
    ["05-text.json", JSON.stringify({ type: "draft", source: "send.ts", kind: "info" }), "draft: bad text"],
    ["06-tap.json", JSON.stringify({ type: "tap", verb: "ok", draft: "XYZ", by: "42", ts: 1 }), "tap: bad draft"],
    ["07-event.json", JSON.stringify({ type: "job-event", job: 1, event: { type: "frobnicate" } }), "job-event: bad event"],
  ];
  cases.forEach(([n, body]) => writeFileSync(join(dir, "spool", n), body, { mode: 0o600 }));
  const why = drainSpool(dir).map(d => ("malformed" in d ? d.why : "ok"));
  expect(why).toEqual(cases.map(c => c[2]));
  expect(JSON.stringify(why)).not.toContain("SECRET");
});

test("the pid lock records the code version, and a live holder on another version is a stale poller", async () => {
  expect(CODE_VERSION).toMatch(/^[0-9a-f]{16}$/);
  const lock = join(tmp(), "poller.pid");
  expect(pollerStale(lock)).toBe(false);
  const release = acquirePidLock(lock);
  expect(JSON.parse(readFileSync(lock, "utf8")).code).toBe(CODE_VERSION);
  expect(pollerStale(lock)).toBe(false);
  release();
  const h = await holder();
  const start = startIdentity(h.pid);
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start }), { mode: 0o600 });
  expect(pollerStale(lock)).toBe(true);
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start, code: "0000000000000000" }), { mode: 0o600 });
  expect(pollerStale(lock)).toBe(true);
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start, code: CODE_VERSION }), { mode: 0o600 });
  expect(pollerStale(lock)).toBe(false);
  await h.kill();
  writeFileSync(lock, JSON.stringify({ pid: h.pid, start }), { mode: 0o600 });
  expect(pollerStale(lock)).toBe(false);
  writeFileSync(lock, "null", { mode: 0o600 });
  expect(pollerStale(lock)).toBe(false);
});

test("spool: an O_EXCL name collision is refused", () => {
  const dir = peerDirWithSpool();
  submitSpool(dir, { type: "confirm", chatId: 1 }, () => "fixed.json");
  expect(() => submitSpool(dir, { type: "confirm", chatId: 2 }, () => "fixed.json")).toThrow(/EEXIST/);
  expect(JSON.parse(readFileSync(join(dir, "spool", "fixed.json"), "utf8")).chatId).toBe(1);
});

test("spool: a missing spool dir is an error, and nothing is created", () => {
  const dir = tmp();
  expect(() => submitSpool(dir, { type: "confirm", chatId: 1 })).toThrow();
  expect(existsSync(join(dir, "spool"))).toBe(false);
});

test("spool: a half-written or malformed file is skipped or reported, never applied", () => {
  const dir = peerDirWithSpool();
  writeFileSync(join(dir, "spool", ".partial.tmp"), "{", { mode: 0o600 });
  writeFileSync(join(dir, "spool", "1-bad.json"), JSON.stringify({ type: "draft", source: "send.ts", kind: "run", text: "x" }), { mode: 0o600 });
  writeFileSync(join(dir, "spool", "2-junk.json"), "not json", { mode: 0o600 });
  const drained = drainSpool(dir);
  expect(drained.map(d => [d.name, "malformed" in d && d.malformed])).toEqual([["1-bad.json", true], ["2-junk.json", true]]);
});

test("result files are 0600, atomic, hold no text, and remove the spool file", () => {
  const dir = peerDirWithSpool();
  const name = submitSpool(dir, { type: "draft", source: "send.ts", kind: "answer", replyTo: 1, text: "secret text" });
  writeResult(dir, name, { ok: false, rule: "secret-shape", shape: "gh" });
  const res = join(dir, "spool", "results", name);
  expect(mode(res)).toBe(0o600);
  expect(JSON.parse(readFileSync(res, "utf8"))).toEqual({ ok: false, rule: "secret-shape", shape: "gh" });
  expect(existsSync(join(dir, "spool", name))).toBe(false);
  expect(readdirSync(join(dir, "spool", "results")).filter(n => n.includes("tmp"))).toEqual([]);
  expect(readFileSync(res, "utf8")).not.toContain("secret text");
  expect(drainSpool(dir)).toEqual([]);
});

test("sweepResults removes only results older than the age", () => {
  const dir = peerDirWithSpool();
  const a = submitSpool(dir, { type: "confirm", chatId: 1 });
  const b = submitSpool(dir, { type: "confirm", chatId: 2 });
  writeResult(dir, a, { ok: true });
  writeResult(dir, b, { ok: true });
  const old = new Date(Date.now() - 3 * 86400_000);
  require("node:fs").utimesSync(join(dir, "spool", "results", a), old, old);
  sweepResults(dir, 86400_000);
  expect(readdirSync(join(dir, "spool", "results"))).toEqual([b]);
});

test("verifyChain from a seed checks only later records and returns the last hash", async () => {
  const file = join(tmp(), "c.jsonl");
  const c = new Chain();
  for (let i = 0; i < 5; i++) await c.append(file, { i });
  const recs = readChain(file);
  const seed = { n: recs[2].n, h: recs[2].h };
  const lines = readFileSync(file, "utf8").split("\n");
  lines[0] = JSON.stringify({ ...recs[0], i: 99 });
  writeFileSync(file, lines.join("\n"));
  expect(verifyChain(file).ok).toBe(false);
  expect(verifyChain(file, seed)).toEqual({ ok: true, n: 5, h: recs[4].h });
  expect(verifyChain(file, { n: 5, h: recs[4].h })).toEqual({ ok: true, n: 5, h: recs[4].h });
});

test("a bad record after the seed fails with its number", async () => {
  const file = join(tmp(), "c.jsonl");
  const c = new Chain();
  for (let i = 0; i < 5; i++) await c.append(file, { i });
  const recs = readChain(file);
  const lines = readFileSync(file, "utf8").split("\n");
  lines[3] = JSON.stringify({ ...recs[3], i: 99 });
  writeFileSync(file, lines.join("\n"));
  expect(verifyChain(file, { n: recs[1].n, h: recs[1].h })).toEqual({ ok: false, n: 3, h: recs[2].h });
  expect(verifyChain(file, { n: recs[1].n, h: "0".repeat(64) }).ok).toBe(false);
});

test("the tap key is created 0600 once, signs deterministically, and a signature checks only for its own fields", () => {
  const c = tmp("peer-tapkey-");
  const t = { peer: "example", verb: "ok", draft: "0a1b2c3d", by: "42", ts: 1 };
  const sig = signTap(c, t);
  expect(mode(join(c, "tap.key"))).toBe(0o600);
  expect(signTap(c, t)).toBe(sig);
  expect(tapKey(c).equals(tapKey(c))).toBe(true);
  expect(tapSigOk(c, t, sig)).toBe(true);
  for (const other of [{ ...t, verb: "no" }, { ...t, draft: "ffffffff" }, { ...t, by: "43" }, { ...t, ts: 2 }, { ...t, peer: "other" }]) expect(tapSigOk(c, other, sig)).toBe(false);
  expect(tapSigOk(c, t, sig.slice(1))).toBe(false);
  expect(tapSigOk(c, t, "z".repeat(64))).toBe(false);
  chmodSync(join(c, "tap.key"), 0o644);
  expect(tapSigOk(c, t, sig)).toBe(false);
  expect(() => signTap(c, t)).toThrow();
});
