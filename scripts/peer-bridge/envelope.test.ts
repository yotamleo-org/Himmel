import { expect, test } from "bun:test";
import { ALLOWANCE_S, SUITE_PATH_RE, TIMEOUT_S_MAX, buildEnvelope, encodeCanonical, parseEnvelopeLine, type Envelope, type Kind } from "./envelope";

const NOW = 1_731_000_000;
const CTX = { from: "yotam", to: "goomal", chat: -1001234567890, now: NOW };
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

// A line built by hand from a sample object, so a test can break one rule at a time.
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

test("exp - iat is 86400 for every kind (R4-F6)", () => {
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
  expect(encodeCanonical(a)).toBe(`{"v":1,"msg":"${a.msg}","from":"yotam","to":"goomal","chat":"-1001234567890","iat":${NOW},"exp":${NOW + 86400},"kind":"halt"}`);
});

test("the canonical line is compact, in table order and plain ASCII", () => {
  const l = line("res done");
  expect(l).toMatch(/^\{"v":1,"msg":"[0-9a-f]{8}","from":"yotam","to":"goomal","chat":"-1001234567890","iat":\d+,"exp":\d+,"kind":"res","job":"0123456789abcdef","state":"done","results":\["pass","fail"\],"minutes":15,"image":"b{64}","log":\{"sha256":"b{64}","bytes":1234\}\}$/);
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
