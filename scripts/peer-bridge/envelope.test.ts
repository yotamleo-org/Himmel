import { afterAll, expect, spyOn, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ALLOWANCE_S, SUITE_PATH_RE, TIMEOUT_S_MAX, buildEnvelope, encodeCanonical, parseEnvelopeLine, type Envelope, type Kind } from "./envelope";
import { DedupWindow, admit, admitEnvelope, createGateState, looksLikeEnvelope, matchEnvelope, noteAdmitted, type MatchFn } from "./gate";
import type { JobRecord } from "./resolve";
import { sign } from "./sign";
import * as T from "./testlib-envelope";
import { inJob, outJob } from "./testlib-jobs";
import { failedTests, makeRedCopy } from "./testlib-red-copy";

const WIRE16 = "0123456789abcdef";

const NOW = 1_731_000_000;
const CTX = { from: "yotam", to: "example", chat: -1001234567890, now: NOW };
const HEX16 = "0123456789abcdef", SHA = "a".repeat(40), H64 = "b".repeat(64);
const SUITES = ["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"];

const BODIES: Record<string, [Kind, Record<string, unknown>]> = {
  req: ["req", { job: HEX16, op: "run-suite", sha: SHA, suites: SUITES }],
  "res accepted": ["res", { job: HEX16, state: "accepted" }],
  "res refused": ["res", { job: HEX16, state: "refused", refused: "not-allowed" }],
  "res running": ["res", { job: HEX16, state: "running", timeout_s: 3600 }],
  "res done": ["res", { job: HEX16, state: "done", results: ["pass", "fail"], minutes: 15, image: H64, log: { sha256: H64, bytes: 1234 } }],
  "res cancelled": ["res", { job: HEX16, state: "cancelled" }],
  "res expired": ["res", { job: HEX16, state: "expired" }],
  "capacity-ask": ["capacity-ask", {}],
  capacity: ["capacity", { re: "89abcdef", state: "idle", queue: 1, jobs_left: 9, vm_minutes_left: 100 }],
  cancel: ["cancel", { job: HEX16 }],
  halt: ["halt", {}],
};
const make = (name: string): Envelope => buildEnvelope(BODIES[name][0], BODIES[name][1] as any, CTX);
const line = (name: string) => encodeCanonical(make(name));

const reqObj = () => JSON.parse(line("req"));
const doneObj = () => JSON.parse(line("res done"));
const text = (o: unknown) => JSON.stringify(o);

test("every kind and res state builds, encodes and parses back to the same envelope", () => {
  for (const name of Object.keys(BODIES)) {
    const env = make(name);
    const l = encodeCanonical(env);
    const r = parseEnvelopeLine(l);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.env).toEqual(env);
    expect(l.length).toBeLessThanOrEqual(3000);
  }
});

test("exp - iat is 86400 for every kind", () => {
  for (const name of Object.keys(BODIES)) {
    const e = make(name);
    expect(e.exp - e.iat).toBe(86400);
    expect(e.iat).toBe(NOW);
  }
});

test("buildEnvelope mints a fresh 8-hex msg and carries the common fields in order", () => {
  const a = make("halt"), b = make("halt");
  expect(a.msg).toMatch(/^[0-9a-f]{8}$/);
  expect(a.msg).not.toBe(b.msg);
  expect(encodeCanonical(a)).toBe(`{"v":1,"msg":"${a.msg}","from":"yotam","to":"example","chat":"-1001234567890","iat":${NOW},"exp":${NOW + 86400},"kind":"halt"}`);
});

test("the canonical line is compact, in table order and plain ASCII", () => {
  const l = line("res done");
  expect(l).toMatch(/^\{"v":1,"msg":"[0-9a-f]{8}","from":"yotam","to":"example","chat":"-1001234567890","iat":\d+,"exp":\d+,"kind":"res","job":"0123456789abcdef","state":"done","results":\["pass","fail"\],"minutes":15,"image":"b{64}","log":\{"sha256":"b{64}","bytes":1234\}\}$/);
  expect(/^[\x20-\x7e]+$/.test(l)).toBe(true);
});

test("a worst-case res fits the 3000-byte cap", () => {
  const e = buildEnvelope("res", { job: HEX16, state: "done", results: Array(10).fill("error"), minutes: 180, image: H64, log: { sha256: H64, bytes: 5242880 } } as any, CTX);
  expect(encodeCanonical(e).length).toBeLessThan(1000);
});

function refused(l: string, reason?: string) {
  const r = parseEnvelopeLine(l);
  expect(r.ok).toBe(false);
  if (!r.ok && reason) expect(r.reason).toContain(reason);
}

test("a duplicate key is refused by the canonical re-encode", () => {
  const l = line("cancel");
  refused(l.replace(`"kind":"cancel"`, `"kind":"cancel","kind":"cancel"`), "canonical");
  refused(l.replace(`"v":1,`, `"v":1,"v":1,`), "canonical");
});

test("keys out of order are refused", () => {
  const o = JSON.parse(line("cancel"));
  refused(text({ msg: o.msg, v: 1, from: o.from, to: o.to, chat: o.chat, iat: o.iat, exp: o.exp, kind: o.kind, job: o.job }), "canonical");
  refused(text({ ...o, job: undefined, kind: "cancel", jobx: 1 }), "");
});

test("1.0, 1e3 and an exponent are refused", () => {
  const l = line("cancel");
  refused(l.replace(`"v":1`, `"v":1.0`), "canonical");
  refused(l.replace(`"exp":${NOW + 86400}`, `"exp":${(NOW + 86400) / 1000}e3`), "canonical");
  refused(l.replace(`"v":1`, `"v":1e0`), "canonical");
  refused(l.replace(`"iat":${NOW}`, `"iat":${NOW}.0`), "canonical");
});

test("whitespace anywhere is refused", () => {
  const l = line("capacity");
  refused(l.replace(`{"v"`, `{ "v"`), "canonical");
  refused(l.replace(`,"msg"`, `, "msg"`), "canonical");
  refused(l.replace(`"kind":`, `"kind": `), "canonical");
  refused(` ${l}`, "");
  refused(`${l} `, "");
});

test("an unknown key and a missing key are refused", () => {
  refused(text({ ...reqObj(), extra: 1 }), "");
  const o = reqObj(); delete o.sha;
  refused(text(o), "");
  const d = doneObj(); delete d.log;
  refused(text(d), "");
  const bad = doneObj(); bad.log = { sha256: H64, bytes: 1, more: 2 };
  refused(text(bad), "");
});

test("a non-ASCII byte is refused, escaped or not", () => {
  const l = line("cancel");
  refused(l.replace(`"yotam"`, `"yotamé"`), "ascii");
  refused(l.replace(`"yotam"`, `"yot\\u0061m"`), "canonical");
  refused(l.replace(`"yotam"`, `"yot\tam"`), "ascii");
  refused("{\"v\":1}\u0000", "ascii");
});

test("a line over 3000 bytes is refused", () => {
  refused(" ".repeat(3001), "length");
});

test("a suite with .. , a bad shape or a bad count is refused", () => {
  const withSuites = (s: unknown) => text({ ...reqObj(), suites: s });
  refused(withSuites(["scripts/../etc/x.sh"]));
  refused(withSuites(["scripts/a..b.sh"]));
  refused(withSuites(["/etc/passwd"]));
  refused(withSuites(["scripts/UPPER.sh"]));
  refused(withSuites(["scripts/x.py"]));
  refused(withSuites([]));
  refused(withSuites(Array.from({ length: 11 }, (_, i) => `scripts/t${i}.sh`)));
  expect(parseEnvelopeLine(withSuites(Array.from({ length: 10 }, (_, i) => `scripts/t${i}.sh`))).ok).toBe(true);
  refused(withSuites("scripts/a.sh"));
});

test("numeric bounds: minutes 181, timeout_s 10201 and the other ranges are refused", () => {
  const d = (over: Record<string, unknown>) => text({ ...doneObj(), ...over });
  expect(parseEnvelopeLine(d({ minutes: 180 })).ok).toBe(true);
  refused(d({ minutes: 181 }));
  refused(d({ minutes: -1 }));
  refused(d({ log: { sha256: H64, bytes: 5242881 } }));
  refused(d({ log: { sha256: H64, bytes: -1 } }));
  const base = JSON.parse(line("res running"));
  expect(TIMEOUT_S_MAX).toBe(10200);
  expect(ALLOWANCE_S).toBe(1200);
  expect(parseEnvelopeLine(text({ ...base, timeout_s: 10200 })).ok).toBe(true);
  expect(parseEnvelopeLine(text({ ...base, timeout_s: 60 })).ok).toBe(true);
  refused(text({ ...base, timeout_s: 10201 }));
  refused(text({ ...base, timeout_s: 59 }));
  const cap = JSON.parse(line("capacity"));
  refused(text({ ...cap, queue: 4 }));
  refused(text({ ...cap, jobs_left: 1001 }));
  refused(text({ ...cap, vm_minutes_left: 10001 }));
  expect(parseEnvelopeLine(text({ ...cap, queue: 3, jobs_left: 1000, vm_minutes_left: 10000 })).ok).toBe(true);
});

test("each field refuses a value outside its own shape", () => {
  const r = reqObj();
  for (const [k, v] of Object.entries({
    v: 2, msg: "ABCDEF01", from: "Yotam", to: "has space", chat: -1001234567890, iat: 1.5, exp: "x", kind: "nope",
    job: "0123", op: "rm", sha: "A".repeat(40),
  })) refused(text({ ...r, [k]: v }));
  refused(text({ ...r, chat: "-1" }));
  refused(text({ ...r, chat: "-100" }));
  refused(text({ ...r, exp: r.iat }));
  refused(text({ ...r, exp: r.iat + 86401 }));
  expect(parseEnvelopeLine(text({ ...r, exp: r.iat + 1 })).ok).toBe(true);
});

test("a res carries exactly the fields its state names", () => {
  const acc = JSON.parse(line("res accepted"));
  refused(text({ ...acc, timeout_s: 100 }));
  refused(text({ ...acc, state: "refused" }));
  refused(text({ ...acc, state: "refused", refused: "because" }));
  for (const why of ["not-served", "unknown-sha", "too-old", "not-allowed", "budget", "no-vm"]) {
    expect(parseEnvelopeLine(text({ ...acc, state: "refused", refused: why })).ok).toBe(true);
  }
  refused(text({ ...doneObj(), results: ["pass", "timeout"] }));
  refused(text({ ...doneObj(), results: [] }));
  refused(text({ ...doneObj(), results: Array(11).fill("pass") }));
});

test("the body of capacity-ask and halt is empty", () => {
  refused(text({ ...JSON.parse(line("halt")), job: HEX16 }));
  refused(text({ ...JSON.parse(line("capacity-ask")), re: "89abcdef" }));
});

test("encodeCanonical refuses an envelope the schema would refuse", () => {
  const e = make("req") as any;
  expect(() => encodeCanonical({ ...e, suites: ["scripts/../x.sh"] })).toThrow();
  expect(() => encodeCanonical({ ...e, extra: 1 })).toThrow();
  expect(() => encodeCanonical({ ...e, sha: "xyz" })).toThrow();
});

test("a body cannot choose the common fields: msg, from, to, chat, the times and the kind are the builder's", () => {
  const e = buildEnvelope("halt", { v: 2, msg: "00000000", from: "intruder", to: "someone", chat: "-1009", iat: 1, exp: 2, kind: "req" }, CTX);
  expect(e).toMatchObject({ v: 1, from: "yotam", to: "example", chat: "-1001234567890", iat: NOW, exp: NOW + 86400, kind: "halt" });
  expect(e.msg).not.toBe("00000000");
  expect(parseEnvelopeLine(encodeCanonical(e)).ok).toBe(true);
});

test("buildEnvelope refuses a body the schema refuses", () => {
  expect(() => buildEnvelope("res", { job: HEX16, state: "running", timeout_s: 10201 } as any, CTX)).toThrow();
  expect(() => buildEnvelope("cancel", { job: "nope" } as any, CTX)).toThrow();
});

test("the suite-path regex has the spec shape", () => {
  expect(SUITE_PATH_RE.source).toBe("^scripts\\/[a-z0-9_/.-]{1,120}\\.sh$");
  expect(SUITE_PATH_RE.test("scripts/ci/test-x.sh")).toBe(true);
  expect(SUITE_PATH_RE.test("scripts/ci/test-x.sh\n")).toBe(false);
  expect(SUITE_PATH_RE.test("scripts/" + "a".repeat(121) + ".sh")).toBe(false);
});


const peerSt = T.mkStation("example");
afterAll(() => T.dropStation(peerSt));

function world(over: { keys?: { id: string; pub: string; addedAt?: string }[]; peerOver?: Record<string, unknown> } = {}) {
  const cfg = T.envConfig(over.keys ?? [{ id: peerSt.key.id, pub: peerSt.key.pub }], over.peerOver);
  const state = createGateState({ ourBotId: T.OUR_BOT_ID, ourUsername: T.BOT_US, committed: 0, now: T.NOW_S * 1000 });
  return { cfg, state };
}
const good = (kind: Kind = "req", body: Record<string, unknown> = T.REQ_BODY, now = T.NOW_S) => T.fromPeer(kind, body, now);

function stepOf(r: ReturnType<typeof admitEnvelope>): number { return r.ok ? 0 : r.step; }

test("the happy path admits each kind and returns the parsed envelope and the raw record", () => {
  for (const [name, kind, body] of T.KIND_SAMPLES) {
    const { cfg, state } = world();
    const env = good(kind, body);
    const u = T.envUpdate(env, peerSt);
    const r = admitEnvelope(u, cfg, state);
    expect([name, r.ok]).toEqual([name, true]);
    if (!r.ok) continue;
    expect(r.env).toEqual(env);
    expect(r.peer).toBe("example");
    expect(r.rec).toMatchObject({ kind: "peer-env", untrusted: true, peer: "example", id: env.msg, chat_id: T.ENV_CHAT, text: u.message.text });
  }
});

test("only a line-2 #env message routes to the typed path", () => {
  const env = good();
  expect(looksLikeEnvelope(T.envUpdate(env, peerSt))).toBe(true);
  expect(looksLikeEnvelope(T.tgUpdate(`/peer@${T.BOT_US}\n#env:v2 k=x\n{}\nsig=x`))).toBe(true);
  expect(looksLikeEnvelope(T.tgUpdate(`/peer@${T.BOT_US}\n#info id=a1b2c3d4\nhello`))).toBe(false);
  expect(looksLikeEnvelope(T.tgUpdate(`#env:v1 k=0123abcd id=89abcdef`))).toBe(false);
  expect(looksLikeEnvelope({ message: {} })).toBe(false);
});

test("step 1: the text path's rules apply first, and the envelope window is rule 1's", () => {
  const { cfg, state } = world();
  const env = good();
  const wrongSender = T.envUpdate(env, peerSt); wrongSender.message.from.id = 42;
  expect(stepOf(admitEnvelope(wrongSender, cfg, state))).toBe(1);
  const wrongChat = T.envUpdate(env, peerSt); wrongChat.message.chat.id = -1009999999999;
  expect(stepOf(admitEnvelope(wrongChat, cfg, state))).toBe(1);
  const edited = T.envUpdate(env, peerSt); edited.message.edit_date = 5;
  expect(stepOf(admitEnvelope(edited, cfg, state))).toBe(1);
  const oldUpdate = T.envUpdate(env, peerSt); state.committed = oldUpdate.update_id;
  const r = admitEnvelope(oldUpdate, cfg, state);
  expect(r.ok).toBe(false);
  if (!r.ok) { expect(r.step).toBe(1); expect(r.log).toContain("rule=1"); }
});

test("step 2: not four lines, not addressed to us, or line 2 off-grammar", () => {
  const env = good();
  const base = T.envLines(env, peerSt);
  const cases: Record<string, [string, number]> = {
    "a fifth line": [[...base, "extra"].join("\n"), 2],
    "three lines": [base.slice(0, 3).join("\n"), 2],
    "a second address line": [[base[0], base[0], ...base.slice(1)].join("\n"), 2],
    "uppercase k": [[base[0], base[1].replace(/k=([0-9a-f]{8})/, (_, k) => `k=${k.toUpperCase().replace(/[0-9]/g, "A")}`), base[2], base[3]].join("\n"), 2],
    "a trailing space on line 2": [[base[0], base[1] + " ", base[2], base[3]].join("\n"), 2],
    "version v2": [[base[0], base[1].replace("v1", "v2"), base[2], base[3]].join("\n"), 2],
    "another bot's address": [T.envLines(env, peerSt, { to: "other_bot" }).join("\n"), 1],
    "an empty line 4 is a step 3 matter": [[...base.slice(0, 3), ""].join("\n"), 3],
  };
  for (const [name, [text, step]] of Object.entries(cases)) {
    const { cfg, state } = world();
    expect([name, stepOf(admitEnvelope(T.tgUpdate(text), cfg, state))]).toEqual([name, step]);
  }
});

test("step 3: line 3 not printable ASCII or over 3000 bytes, line 4 not a signature shape", () => {
  const { cfg } = world();
  const env = good();
  const [a, b, c, d] = T.envLines(env, peerSt);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, c.replace("yotam", "yotaé"), d].join("\n")), cfg, world().state))).toBe(3);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, "x".repeat(3001), d].join("\n")), cfg, world().state))).toBe(3);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, "", d].join("\n")), cfg, world().state))).toBe(3);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, c, d.slice(0, -1)].join("\n")), cfg, world().state))).toBe(3);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, c, d.replace("sig=", "SIG=")].join("\n")), cfg, world().state))).toBe(3);
});

test("step 4: an unknown k, no trusted key, or a killed peer is dropped before any verify", () => {
  const w = world();
  expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt, { kid: "00000000" }), w.cfg, w.state))).toBe(4);
  const none = world({ keys: [] });
  expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt), none.cfg, none.state))).toBe(4);
  const killed = world();
  killed.state.killed.add("example");
  const r = admitEnvelope(T.envUpdate(good(), peerSt), killed.cfg, killed.state);
  expect(stepOf(r)).toBe(4);
  if (!r.ok) expect(r.reason).toContain("killed");
  killed.state.killed.clear();
  expect(killed.state.envIds.size).toBe(0);
  expect(admitEnvelope(T.envUpdate(good(), peerSt), killed.cfg, killed.state).ok).toBe(true);
});

test("step 5: a flipped byte in line 2, 3 or 4 fails the signature, and the id is not burned", () => {
  const env = good();
  const [a, b, c, d] = T.envLines(env, peerSt);
  const flip = (s: string, at: number) => s.slice(0, at) + (s[at] === "a" ? "b" : "a") + s.slice(at + 1);
  const w = world();
  const idPos = b.lastIndexOf("id=") + 3;
  expect(stepOf(admitEnvelope(T.tgUpdate([a, flip(b, idPos), c, d].join("\n")), w.cfg, w.state))).toBe(5);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, flip(c, 20), d].join("\n")), w.cfg, w.state))).toBe(5);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, c, flip(d, 10)].join("\n")), w.cfg, w.state))).toBe(5);
  expect(stepOf(admitEnvelope(T.tgUpdate([a, b, c, "sig=" + "A".repeat(86)].join("\n")), w.cfg, w.state))).toBe(5);
  expect(admitEnvelope(T.tgUpdate([a, b, c, d].join("\n")), w.cfg, w.state).ok).toBe(true);
});

test("step 5 comes before any parse: a flipped byte in line 3 never reaches JSON.parse", () => {
  const env = good();
  const [a, b, c, d] = T.envLines(env, peerSt);
  const tampered = c.slice(0, 20) + (c[20] === "a" ? "b" : "a") + c.slice(21);
  const w = world();
  const parse = spyOn(JSON, "parse");
  try {
    const r = admitEnvelope(T.tgUpdate([a, b, tampered, d].join("\n")), w.cfg, w.state);
    expect(stepOf(r)).toBe(5);
    expect(parse.mock.calls.filter(args => args[0] === tampered)).toEqual([]);
  } finally { parse.mockRestore(); }
});

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: a gate that parses before it verifies fails the JSON.parse row", () => {
  const root = makeRedCopy(["scripts/telegram/bus.ts", "scripts/telegram/gate.ts"]);
  const run = () => spawnSync("bun", ["test", "./scripts/peer-bridge/envelope.test.ts"], { cwd: root, encoding: "utf8", env: { ...process.env, PEER_RED_COPY: "1" } });
  expect(run().status).toBe(0);
  const target = join(root, "scripts/peer-bridge/gate.ts");
  const src = readFileSync(target, "utf8");
  const verifyLine = "  if (!verify(line2, line3, line4.slice(4), key.pub)) return fail(5, \"bad signature\");\n";
  expect(src.split(verifyLine)).toHaveLength(2);
  writeFileSync(target, src.replace(verifyLine, `  try { JSON.parse(line3); } catch {}\n${verifyLine}`));
  const mutated = run();
  expect(mutated.status).not.toBe(0);
  expect(failedTests(mutated.stdout + mutated.stderr)).toEqual(["step 5 comes before any parse: a flipped byte in line 3 never reaches JSON.parse"]);
}, 60_000);

test("step 6: a validly signed line that is not canonical or not in the schema is refused", () => {
  const sendLine3 = (line3: string) => {
    const line2 = `#env:v1 k=${peerSt.key.id} id=89abcdef`;
    return T.tgUpdate([`/peer@${T.BOT_US}`, line2, line3, `sig=${sign(line2, line3, peerSt.keyPath)}`].join("\n"));
  };
  const canon = () => encodeCanonical({ ...good(), msg: "89abcdef" } as Envelope);
  const o = () => JSON.parse(canon());
  const cases: Record<string, string> = {
    "1.0 for v": canon().replace(`"v":1`, `"v":1.0`),
    "an unknown key": JSON.stringify({ ...o(), extra: 1 }),
    "a duplicate key": canon().replace(`"kind":"req"`, `"kind":"req","kind":"req"`),
    "keys out of order": JSON.stringify({ msg: "89abcdef", v: 1, ...Object.fromEntries(Object.entries(o()).slice(2)) }),
    "whitespace": JSON.stringify(o(), null, 1).replace(/\n/g, " "),
    "a suite with ..": JSON.stringify({ ...o(), suites: ["scripts/../x.sh"] }),
    "not JSON": "{nope",
  };
  for (const [name, line3] of Object.entries(cases)) {
    const w = world();
    expect([name, stepOf(admitEnvelope(sendLine3(line3), w.cfg, w.state))]).toEqual([name, 6]);
  }
});

test("step 7: a wrong msg, from, to or chat, an iat too far ahead, or an expired envelope is refused", () => {
  const fix = (over: Record<string, unknown>) => T.envUpdate({ ...good(), ...over } as Envelope, peerSt);
  const rows: [string, any][] = [
    ["wrong from", fix({ from: "intruder" })],
    ["wrong to", fix({ to: "someone" })],
    ["wrong chat", fix({ chat: "-1009999999999" })],
    ["iat 11 minutes ahead", T.envUpdate(good("req", T.REQ_BODY, T.NOW_S + 11 * 60), peerSt)],
    ["expired", T.envUpdate(good("req", T.REQ_BODY, T.NOW_S - 86400 - 1), peerSt)],
  ];
  for (const [name, u] of rows) {
    const w = world();
    expect([name, stepOf(admitEnvelope(u, w.cfg, w.state))]).toEqual([name, 7]);
  }
  const line2 = `#env:v1 k=${peerSt.key.id} id=00000000`;
  const line3 = encodeCanonical(good());
  const w = world();
  expect(stepOf(admitEnvelope(T.tgUpdate([`/peer@${T.BOT_US}`, line2, line3, `sig=${sign(line2, line3, peerSt.keyPath)}`].join("\n")), w.cfg, w.state))).toBe(7);
  const bare = world();
  (bare.cfg.peers.example.theirs as any).stationName = undefined;
  expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt), bare.cfg, bare.state))).toBe(7);
  const noSelf = world(); (noSelf.cfg as any).self = {};
  expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt), noSelf.cfg, noSelf.state))).toBe(7);
  expect(w.state.envIds.size).toBe(0);
});

test("step 7: iat 10 minutes ahead and 6 hours behind are accepted", () => {
  for (const delta of [10 * 60, -6 * 3600, -23 * 3600]) {
    const w = world();
    expect([delta, admitEnvelope(T.envUpdate(good("req", T.REQ_BODY, T.NOW_S + delta), peerSt), w.cfg, w.state).ok]).toEqual([delta, true]);
  }
});

test("a replay before exp is refused at the window; after exp it is refused as expired", () => {
  const w = world();
  const u = T.envUpdate(good(), peerSt);
  expect(admitEnvelope(u, w.cfg, w.state).ok).toBe(true);
  const r = admitEnvelope(T.tgUpdate(u.message.text), w.cfg, w.state);
  expect(stepOf(r)).toBe(1);
  if (!r.ok) expect(r.reason).toContain("duplicate envelope id");
  w.state.now = (T.NOW_S + 86400 + 1) * 1000;
  w.state.envIds.prune(T.NOW_S + 86400 + 1);
  expect(w.state.envIds.size).toBe(0);
  expect(stepOf(admitEnvelope(T.tgUpdate(u.message.text), w.cfg, w.state))).toBe(7);
});

test("1001 admitted text messages do not flush a replayable req", () => {
  const w = world({ peerOver: { maxPerMinute: 100_000 } });
  const first = T.envUpdate(good(), peerSt);
  expect(admitEnvelope(first, w.cfg, w.state).ok).toBe(true);
  for (let i = 0; i < 1001; i++) {
    const id = i.toString(16).padStart(8, "0");
    const r = admit(T.tgUpdate(`/peer@${T.BOT_US}\n#info id=${id}\nhi`), w.cfg, w.state);
    expect(r.ok).toBe(true);
    if (r.ok) noteAdmitted(w.state, r.rec);
  }
  expect(w.state.recent.has(`${T.ENV_CHAT}:${T.PEER_BOT_ID}:00000000`)).toBe(false);
  expect(stepOf(admitEnvelope(T.tgUpdate(first.message.text), w.cfg, w.state))).toBe(1);
  expect(DedupWindow.name).toBe("DedupWindow");
});

test("rotation admission: envelopes under the old and the new key are both admitted", () => {
  const next = T.mkStation("example-next");
  try {
    const keys = [{ id: peerSt.key.id, pub: peerSt.key.pub, addedAt: T.iso(T.NOW_S - 5 * 86400) }, { id: next.key.id, pub: next.key.pub, addedAt: T.iso(T.NOW_S - 86400) }];
    const w = world({ keys });
    expect(admitEnvelope(T.envUpdate(good(), peerSt), w.cfg, w.state).ok).toBe(true);
    expect(admitEnvelope(T.envUpdate(good(), next), w.cfg, w.state).ok).toBe(true);
    const after = world({ keys: [keys[1]] });
    expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt), after.cfg, after.state))).toBe(4);
    expect(admitEnvelope(T.envUpdate(good(), next), after.cfg, after.state).ok).toBe(true);
    const aged = world({ keys: [{ ...keys[0], addedAt: T.iso(T.NOW_S - 60 * 86400) }, { ...keys[1], addedAt: T.iso(T.NOW_S - 31 * 86400) }] });
    expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt), aged.cfg, aged.state))).toBe(4);
  } finally { T.dropStation(next); }
});

test("steps 8 and 9 come from the caller's match, after step 7, and the id is already in the window", () => {
  const calls: string[] = [];
  const match: MatchFn = (env, peer, _cfg, nowS) => { calls.push(`${env.kind}:${peer}:${nowS}`); return env.kind === "req" ? { ok: false, step: 8, reason: "not served" } : { ok: true }; };
  const w = world();
  const r = admitEnvelope(T.envUpdate(good(), peerSt), w.cfg, w.state, match);
  expect(r.ok).toBe(false);
  if (!r.ok) { expect(r.step).toBe(8); expect(r.env?.kind).toBe("req"); expect(r.rec?.kind).toBe("peer-env"); }
  expect(calls).toEqual([`req:example:${T.NOW_S}`]);
  expect(w.state.envIds.size).toBe(1);
  expect(admitEnvelope(T.envUpdate(good("halt", {}), peerSt), w.cfg, w.state, match).ok).toBe(true);
  expect(stepOf(admitEnvelope(T.envUpdate(good(), peerSt, { kid: "00000000" }), w.cfg, w.state, match))).toBe(4);
  expect(calls.length).toBe(2);
});


const SERVING = { serves: ["run-suite"], budgets: { jobsPerDay: 3, vmMinutesPerDay: 120, queueMax: 2, maxJobMinutes: 60 } };
function matched(kind: Kind, body: Record<string, unknown>, jobs: JobRecord[] = [], asks: [string, boolean][] = [], peerOver: Record<string, unknown> = SERVING) {
  const w = world({ peerOver });
  const match = matchEnvelope({ jobs: () => jobs, asks: () => new Map(asks) });
  const r = admitEnvelope(T.envUpdate(good(kind, body), peerSt), w.cfg, w.state, match);
  return r;
}
const inJobs = (n: number, over: Partial<JobRecord> = {}): JobRecord[] => Array.from({ length: n }, (_, i) => inJob({ jobNo: 10 + i, peer: "example", state: "RESOLVED", resolved_at: T.NOW_S - 60, ...over }));
const stepRefusal = (r: ReturnType<typeof admitEnvelope>) => (r.ok ? null : { step: r.step, refused: (r as any).refused });

test("step 8: a req for an op we do not serve is refused, and the refusal says not-served", () => {
  expect(stepRefusal(matched("req", T.REQ_BODY, [], [], { serves: [] }))).toEqual({ step: 8, refused: "not-served" });
  expect(matched("req", T.REQ_BODY).ok).toBe(true);
});

test("step 8: a cancel needs a job the peer sent us, a res a job we sent it, a capacity an ask we sent and nobody has answered", () => {
  expect(stepRefusal(matched("cancel", { job: WIRE16 }))).toEqual({ step: 8, refused: undefined });
  expect(matched("cancel", { job: WIRE16 }, [inJob({ peer_job: WIRE16 })]).ok).toBe(true);
  expect(stepRefusal(matched("cancel", { job: WIRE16 }, [inJob({ peer: "someone-else", peer_job: WIRE16 })]))?.step).toBe(8);
  expect(stepRefusal(matched("cancel", { job: WIRE16 }, [outJob({ wire_job: WIRE16 })]))?.step).toBe(8);

  expect(stepRefusal(matched("res", { job: WIRE16, state: "accepted" }))?.step).toBe(8);
  expect(matched("res", { job: WIRE16, state: "accepted" }, [outJob({ wire_job: WIRE16 })]).ok).toBe(true);
  expect(stepRefusal(matched("res", { job: WIRE16, state: "accepted" }, [inJob({ peer_job: WIRE16 })]))?.step).toBe(8);

  const cap = { re: "89abcdef", state: "idle", queue: 0, jobs_left: 3, vm_minutes_left: 60 };
  expect(stepRefusal(matched("capacity", cap))?.step).toBe(8);
  expect(stepRefusal(matched("capacity", cap, [], [["example:89abcdef", true]]))?.step).toBe(8);
  expect(matched("capacity", cap, [], [["example:89abcdef", false]]).ok).toBe(true);
});

test("halt and capacity-ask always pass, even for a station that serves nothing", () => {
  expect(matched("halt", {}, [], [], { serves: [] }).ok).toBe(true);
  expect(matched("capacity-ask", {}, [], [], { serves: [] }).ok).toBe(true);
});

test("step 9: a req over any budget is refused with budget", () => {
  expect(matched("req", T.REQ_BODY, inJobs(2, { state: "DONE", by: null })).ok).toBe(true);
  expect(stepRefusal(matched("req", T.REQ_BODY, inJobs(3, { state: "DONE", by: null })))).toEqual({ step: 9, refused: "budget" });
  expect(stepRefusal(matched("req", T.REQ_BODY, inJobs(2, { state: "RESOLVED" })))).toEqual({ step: 9, refused: "budget" });
  const used = inJobs(1, { state: "DONE", by: null, running_at: T.NOW_S - 7000, ended_at: T.NOW_S - 100, resolved_at: T.NOW_S - 7000 });
  expect(stepRefusal(matched("req", T.REQ_BODY, used))).toEqual({ step: 9, refused: "budget" });
  expect(matched("req", T.REQ_BODY, inJobs(1, { state: "DONE", by: null, running_at: T.NOW_S - 1800, ended_at: T.NOW_S - 100, resolved_at: T.NOW_S - 1800 })).ok).toBe(true);
});

test("a refusal at step 8 or 9 keeps the envelope and its raw record for the caller, and the id is spent", () => {
  const w = world({ peerOver: { serves: [] } });
  const match = matchEnvelope({ jobs: () => [], asks: () => new Map() });
  const r = admitEnvelope(T.envUpdate(good(), peerSt), w.cfg, w.state, match);
  expect(r.ok).toBe(false);
  if (!r.ok) { expect(r.env?.kind).toBe("req"); expect(r.rec?.kind).toBe("peer-env"); }
  expect(w.state.envIds.size).toBe(1);
});

test("a refusal at steps 2-7 logs the step, the msg id and a sha256, never the text", () => {
  const w = world();
  const [a, b, c, d] = T.envLines(good(), peerSt);
  const r = admitEnvelope(T.tgUpdate([a, b, c.replace("yotam", "yotaé"), d].join("\n")), w.cfg, w.state);
  expect(r.ok).toBe(false);
  if (r.ok) return;
  expect(r.log).toMatch(/^env-drop step=3 peer=example msg=[0-9a-f]{8} sha256=[0-9a-f]{64}$/);
  expect(r.log).not.toContain("yota");
  expect(r.log).not.toContain(d.slice(4));
});
