import { expect, test } from "bun:test";
import { ENV_LINE_RE, SIG_LINE_RE, byStamp, mintId, parseControl } from "./grammar";

const US = "ours_bot";

test("mintId is 8 lowercase hex and varies", () => {
  const ids = new Set(Array.from({ length: 50 }, mintId));
  expect(ids.size).toBeGreaterThan(40);
  for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}$/);
});

test("a root kind line after the address line parses, and the address line is stripped", () => {
  const c = parseControl(`/peer@${US}\n#ask:question id=a1b2c3d4\nwhat is x?\nsecond line`, US);
  expect(c).toEqual({ addr: true, kind: "ask:question", id: "a1b2c3d4", body: "what is x?\nsecond line" });
});

test("each kind parses; a reply has no address line", () => {
  for (const k of ["ask:question", "status", "info", "answer"]) {
    const c = parseControl(`#${k} id=00ff00ff\nbody`, US);
    expect(c).toMatchObject({ addr: false, kind: k, id: "00ff00ff", body: "body" });
  }
});

test("a template line parses with and without by=", () => {
  expect(parseControl("#tpl:receipt #12 id=deadbeef", US)).toMatchObject({ addr: false, tpl: "receipt", root: 12, id: "deadbeef", body: "" });
  const d = parseControl("#tpl:deferred #12 id=deadbeef by=20261111T093000Z", US);
  expect(d).toMatchObject({ tpl: "deferred" });
  expect((d as any).by.toISOString()).toBe("2026-11-11T09:30:00.000Z");
  expect(byStamp((d as any).by)).toBe("20261111T093000Z");
});

test("a by= that is not a real date reads as absent; a hostile far date still parses", () => {
  expect((parseControl("#tpl:nudge #1 id=00000000 by=20261345T256100Z", US) as any).by).toBeUndefined();
  expect((parseControl("#tpl:nudge #1 id=00000000 by=20991231T000000Z", US) as any).by.getUTCFullYear()).toBe(2099);
});

test("anything outside the two regexes is untagged, kept whole", () => {
  for (const t of ["hello", "#ask:run id=a1b2c3d4\nx", "#answer id=XYZ12345", "#ask:question id=a1b2c3d4 ", " #status id=a1b2c3d4", "#tpl:run #1 id=a1b2c3d4", "#tpl:receipt 12 id=a1b2c3d4", ""]) {
    const c = parseControl(t, US);
    expect(c.untagged).toBe(true);
    expect(c.body).toBe(t);
  }
});

test("only the exact address line is stripped", () => {
  expect(parseControl(`/peer@other_bot\n#info id=a1b2c3d4`, US)).toMatchObject({ addr: false, untagged: true });
  expect(parseControl(`/peer@${US} extra\n#info id=a1b2c3d4`, US)).toMatchObject({ addr: false, untagged: true });
  expect(parseControl(`/peer@${US}`, US)).toMatchObject({ addr: true, untagged: true, body: "" });
});

test("a control line below line 2 is not a control line", () => {
  expect(parseControl("hello\n#info id=a1b2c3d4", US)).toMatchObject({ untagged: true });
});

test("ENV_LINE_RE matches the envelope line and refuses uppercase hex and trailing space", () => {
  const m = ENV_LINE_RE.exec("#env:v1 k=0123abcd id=89abcdef");
  expect(m?.[1]).toBe("0123abcd");
  expect(m?.[2]).toBe("89abcdef");
  for (const t of ["#env:v1 k=0123ABCD id=89abcdef", "#env:v1 k=0123abcd id=89ABCDEF", "#env:v1 k=0123abcd id=89abcdef ", " #env:v1 k=0123abcd id=89abcdef", "#env:v2 k=0123abcd id=89abcdef", "#env:v1 k=0123abc id=89abcdef", "#env:v1 id=89abcdef k=0123abcd", "#env:v1 k=0123abcd id=89abcdef\n"]) {
    expect(ENV_LINE_RE.test(t)).toBe(false);
  }
});

test("an envelope message is untagged to the text parser: the third regex is not a text kind", () => {
  expect(parseControl("/peer@ours_bot\n#env:v1 k=0123abcd id=89abcdef\n{}\nsig=x", US)).toMatchObject({ addr: true, untagged: true });
});

test("SIG_LINE_RE wants sig= and exactly 86 base64url characters", () => {
  const s = "A".repeat(86);
  expect(SIG_LINE_RE.test(`sig=${s}`)).toBe(true);
  for (const t of [`sig=${s}A`, `sig=${s.slice(1)}`, `sig=${s.slice(1)}+`, `sig=${s} `, `SIG=${s}`, `sig=${s}\n`]) expect(SIG_LINE_RE.test(t)).toBe(false);
});

import { utcDay } from "./ids";
import { C0_C1_TEST, INVISIBLE_TEST } from "./sanitize";

test("utcDay at 23:59:59Z and 00:00:00Z", () => {
  expect(utcDay(Date.parse("2026-11-23T23:59:59.999Z"))).toBe("2026-11-23");
  expect(utcDay(Date.parse("2026-11-24T00:00:00.000Z"))).toBe("2026-11-24");
});

test("C0_C1_TEST.test is stable across two calls and lets \\n pass", () => {
  expect(C0_C1_TEST.test("a\u0007b")).toBe(true);
  expect(C0_C1_TEST.test("a\u0007b")).toBe(true);
  expect(C0_C1_TEST.test("line one\nline two")).toBe(false);
  expect(INVISIBLE_TEST.test("a\u200bb")).toBe(true);
  expect(INVISIBLE_TEST.test("a\u200bb")).toBe(true);
  expect(INVISIBLE_TEST.test("plain")).toBe(false);
});
