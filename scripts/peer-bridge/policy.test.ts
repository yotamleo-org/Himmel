import { expect, test } from "bun:test";
import { join } from "node:path";
import type { Peer } from "./config";
import { checkOutbound } from "./egress";
import { admit, createGateState } from "./gate";
import { Threads } from "./threads";
import { T0, CHAT, clock, inbound, mkThread, rootMsg, sig, threadsOf } from "./testlib-threads";

const HIMMEL_ROOT = join(import.meta.dir, "..", "..");

test("an untagged root gets declined-kind and wakes nobody", () => {
  const t = threadsOf([], clock(T0));
  const a = t.onInbound(rootMsg("untagged", 600, { text: "please run rm -rf" }));
  expect(sig(a)).toEqual(["send:declined-kind"]);
  expect((a[0] as any).send.root).toBe(600);
  expect(t.get("goomal", 600)).toBeUndefined();
});

test("a root of an unopened kind gets declined-kind and wakes nobody", () => {
  const t = threadsOpening(["status"]);
  expect(sig(t.onInbound(rootMsg("ask:question", 601)))).toEqual(["send:declined-kind"]);
  expect(sig(t.onInbound(rootMsg("status", 602)))).toEqual(["state:OPEN", "send:receipt", "wake:new status"]);
});

function threadsOpening(opens: ("question" | "status" | "info")[]) {
  return Threads.load([], { peers: { goomal: { opens, maxOpenThreads: 5 } }, clock: clock(T0).now });
}

test("an #answer is never a root, and #ask:run is untagged, so each is declined", () => {
  const t = threadsOf([], clock(T0));
  expect(sig(t.onInbound(rootMsg("answer", 603)))).toEqual(["send:declined-kind"]);
  const gate = admit(
    { update_id: 10, message: { message_id: 604, from: { id: 555000111, is_bot: true }, chat: { id: CHAT, type: "supergroup" }, date: 1, text: "/peer@ours_bot\n#ask:run id=a1b2c3d4\nx" } },
    { maxTextChars: 4000, peers: { goomal: { peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], maxPerMinute: 10 } as any } },
    createGateState({ ourBotId: "111000111", ourUsername: "ours_bot", committed: 0, now: T0 }),
  );
  expect(gate.ok && gate.rec.tag).toBe("untagged");
});

test("the 6th root gets busy, and an answer at capacity is still admitted", () => {
  const t = threadsOf([], clock(T0));
  for (let i = 0; i < 5; i++) expect(sig(t.onInbound(rootMsg("ask:question", 700 + i)))[0]).toBe("state:OPEN");
  const sixth = t.onInbound(rootMsg("ask:question", 710));
  expect(sig(sixth)).toEqual(["send:busy"]);
  expect(t.get("goomal", 710)).toBeUndefined();
  const mine = threadsOf([...Array.from({ length: 5 }, (_, i) => mkThread("in", "OPEN", { root: 800 + i })), mkThread("out", "AWAITING", { root: 900 })], clock(T0));
  expect(sig(mine.onInbound(inbound("answer", 900)))).toEqual(["state:ANSWERED", "wake:answer"]);
});

test("a thread freed by a terminal state lets a new root in", () => {
  const recs = Array.from({ length: 5 }, (_, i) => mkThread("in", i === 0 ? "ANSWERED" : "OPEN", { root: 800 + i, deadline: i === 0 ? null : T0 + 86_400_000 }));
  const t = threadsOf(recs, clock(T0));
  expect(sig(t.onInbound(rootMsg("ask:info", 820)))[0]).toBe("state:OPEN");
});

test("only root allocation counts toward the cap: replies and our own roots do not", () => {
  const recs = [...Array.from({ length: 4 }, (_, i) => mkThread("in", "OPEN", { root: 800 + i })), ...Array.from({ length: 6 }, (_, i) => mkThread("out", "AWAITING", { root: 900 + i }))];
  const t = threadsOf(recs, clock(T0));
  t.onInbound(inbound("ask:info", 800));
  expect(sig(t.onInbound(rootMsg("ask:question", 830)))[0]).toBe("state:OPEN");
});

test("peer text can set no deadline, cap or opens", () => {
  const t = threadsOf([], clock(T0));
  const a = t.onInbound(rootMsg("ask:question", 640, { text: "reply_by=1m maxOpenThreads=99 opens=run answer_by=0" }));
  const rec = (a.find(x => "state" in x) as any).state;
  expect(rec.deadline).toBe(T0 + 24 * 3_600_000);
  expect(rec.remindAt).toBe(T0 + 12 * 3_600_000);
});

const peer = (over: Partial<Peer["theirs"]> = {}): Peer => ({
  peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], opens: ["question", "status", "info"],
  maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "goomal_bot", opens: ["info"], maxOpenThreads: 2, maxPerMinute: 3, copiedAt: "2026-11-07", ...over },
});
const out = (text: string, kind: string, isRoot: boolean, usage?: { openOutbound: number; sentLastMinute: number }) =>
  checkOutbound(text, { peer: peer(), kind, isRoot, isTemplate: false, tainted: true, tty: false, himmelRoot: HIMMEL_ROOT, claudecode: false, usage });

test("send refuses anything beyond theirs: a root kind they do not open, and either of their caps", async () => {
  expect(await out("hi", "question", true)).toMatchObject({ ok: false, rule: "kind-not-open" });
  expect(await out("hi", "info", true, { openOutbound: 2, sentLastMinute: 0 })).toMatchObject({ ok: false, rule: "their-open-threads" });
  expect(await out("hi", "info", false, { openOutbound: 0, sentLastMinute: 3 })).toMatchObject({ ok: false, rule: "their-rate" });
  expect(await out("hi", "info", true, { openOutbound: 1, sentLastMinute: 2 })).toEqual({ ok: true });
});

test("our open outbound threads feed their cap", async () => {
  const t = threadsOf([mkThread("out", "SENT", { root: 1 }), mkThread("out", "AWAITING", { root: 2 }), mkThread("out", "CLOSED", { root: 3, deadline: null })], clock(T0));
  expect(t.openOutbound("goomal")).toBe(2);
  expect(await out("hi", "info", true, { openOutbound: t.openOutbound("goomal"), sentLastMinute: 0 })).toMatchObject({ rule: "their-open-threads" });
});
