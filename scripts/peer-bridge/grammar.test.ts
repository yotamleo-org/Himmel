import { expect, test } from "bun:test";
import { byStamp, mintId, parseControl } from "./grammar";

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
