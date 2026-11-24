import { expect, test } from "bun:test";
import fs from "node:fs";
import { Tripwire } from "./wake";
import { makeWorld, wakeLines } from "./testlib-bridge";

const H = 3_600_000;

test("three bad signatures in an hour send one wake line, kill nothing, and a later valid envelope is admitted", async () => {
  const w = await makeWorld();
  for (let i = 0; i < 3; i++) w.inject("alpha", "halt", {}, { tamper: true });
  await w.step("bravo");
  expect(wakeLines(w.bravo)).toEqual(["peer alpha · 3 bad signatures in 1 h"]);
  expect(w.bravo.logs.filter(l => l.startsWith("env-drop step=5")).length).toBe(3);
  expect(fs.readdirSync(w.bravo.configDir).some(n => n.endsWith(".killed"))).toBe(false);
  w.inject("alpha", "capacity-ask", {});
  await w.step("bravo");
  expect(w.wire.map(m => m.from)).toEqual(["bravo"]);
  expect(wakeLines(w.bravo)).toHaveLength(1);
});

test("two bad signatures are no alert, and more than three in the same hour are still one line", async () => {
  const two = await makeWorld();
  for (let i = 0; i < 2; i++) two.inject("alpha", "halt", {}, { tamper: true });
  await two.step("bravo");
  expect(wakeLines(two.bravo)).toEqual([]);

  const six = await makeWorld();
  for (let i = 0; i < 6; i++) six.inject("alpha", "halt", {}, { tamper: true });
  await six.step("bravo");
  expect(wakeLines(six.bravo)).toEqual(["peer alpha · 3 bad signatures in 1 h"]);
});

test("failures spread over more than an hour do not add up", async () => {
  const w = await makeWorld();
  for (let i = 0; i < 4; i++) {
    w.inject("alpha", "halt", {}, { tamper: true });
    await w.step("bravo");
    w.clock.t += 40 * 60_000;
  }
  expect(wakeLines(w.bravo)).toEqual([]);
});

test("the alert comes again for a second burst after an hour", async () => {
  const w = await makeWorld();
  for (let burst = 0; burst < 2; burst++) {
    for (let i = 0; i < 3; i++) w.inject("alpha", "halt", {}, { tamper: true });
    await w.step("bravo");
    w.clock.t += 2 * H;
  }
  expect(wakeLines(w.bravo)).toHaveLength(2);
});

test("a wake line holds the peer's name and a count, never a byte of the message", async () => {
  const w = await makeWorld();
  for (let i = 0; i < 3; i++) w.inject("alpha", "halt", {}, { text: `/peer@bravo_bot\n#env:v1 k=${w.alpha.key.id} id=0123abcd\n{"v":1,"x":"CANARY-9f3a"}\nsig=${"A".repeat(86)}` });
  await w.step("bravo");
  expect(wakeLines(w.bravo).join("\n")).not.toContain("CANARY");
  expect(wakeLines(w.bravo)).toEqual(["peer alpha · 3 bad signatures in 1 h"]);
});

test("the tripwire counts per peer and says so once per window", () => {
  const t = new Tripwire(3, H);
  expect([t.note("a", 0), t.note("a", 1), t.note("a", 2), t.note("a", 3)]).toEqual([false, false, true, false]);
  expect(t.note("b", 3)).toBe(false);
  expect(t.note("a", 2 * H)).toBe(false);
  expect([t.note("a", 2 * H + 1), t.note("a", 2 * H + 2)]).toEqual([false, true]);
});

test("the wake budget of the day still applies to the alert", async () => {
  const w = await makeWorld({ bravoPeer: { maxWakesPerDay: 1 } });
  for (let burst = 0; burst < 2; burst++) {
    for (let i = 0; i < 3; i++) w.inject("alpha", "halt", {}, { tamper: true });
    await w.step("bravo");
    w.clock.t += 2 * H;
  }
  const lines = wakeLines(w.bravo);
  expect(lines[0]).toBe("peer alpha · 3 bad signatures in 1 h");
  expect(lines.length).toBeLessThanOrEqual(2);
  expect(lines.slice(1).every(l => l.includes("wake budget reached"))).toBe(true);
});
