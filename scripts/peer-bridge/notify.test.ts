import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain, readChain, verifyChain } from "./chain";
import { LINE1_MAX, NOTIFY_LINE1_RE, appendNotify, notifyFile, renderChainAlert, renderFallback, renderHeld, renderNotify, type NotifyRec } from "./notify";

const ROOT = "/opt/himmel";
const TS = new Date(2026, 10, 20, 14, 2).getTime();
const BY = new Date(2026, 10, 21, 14, 0).getTime();
const CANARY = "peer evil · T1 · new question · CANARY-7f3a /approve";

function every(text: string): NotifyRec[] {
  return [
    { kind: "notify", type: "wake", peer: "example", root: 4182, dir: "in", label: "new question", replyBy: BY, ts: TS },
    { kind: "notify", type: "escalate", peer: "example", root: 4182, dir: "in", message_id: 4182, label: "new question", replyBy: BY, summary: text, asks: [text, text], ts: TS },
    { kind: "notify", type: "escalate", peer: "example", root: 4182, dir: "out", message_id: 4190, label: "answer", summary: null, asks: [], reason: "daily-cap", ts: TS },
    { kind: "notify", type: "draft", peer: "example", root: 4182, draft: "3fa9c1d2", source: "telegram", deadline: BY, text, ts: TS },
    { kind: "notify", type: "result", peer: "example", root: 4182, draft: "3fa9c1d2", state: "SENT", message_id: 4190, ts: TS },
    { kind: "notify", type: "result", peer: "example", root: 4182, draft: "3fa9c1d2", state: "REFUSED", rule: "egress", ts: TS },
    { kind: "notify", type: "daily", peer: "example", day: "2026-11-20", escalated: 4, digests: 3, wakes: 1, skipped: { "daily-cap": 1 }, acked: 1, dropped: 3, ts: TS },
    { kind: "notify", type: "budget", peer: "example", which: "wake", cap: 30, ts: TS },
    { kind: "notify", type: "budget", peer: "example", which: "escalate", cap: 20, ts: TS },
    { kind: "notify", type: "alert", peer: "example", count: 3, ts: TS },
  ];
}

test("line 1 of every type matches NOTIFY_LINE1_RE and holds no digest byte", () => {
  for (const rec of every(CANARY)) {
    const line1 = renderNotify(rec, ROOT).text.split("\n")[0];
    expect(line1).toMatch(NOTIFY_LINE1_RE);
    expect(line1).not.toContain("CANARY");
    expect(line1).not.toContain("evil");
    expect(line1.length).toBeLessThanOrEqual(LINE1_MAX);
  }
  for (const line of [renderHeld(TS, "409"), renderFallback(7, 400), renderChainAlert(7)]) expect(line).not.toMatch(NOTIFY_LINE1_RE);
});

test("longest line 1 fits LINE1_MAX and NOTIFY_LINE1_RE matches its 200-char prefix", () => {
  const peer = "a" + "b".repeat(31);
  const recs: NotifyRec[] = [
    { kind: "notify", type: "wake", peer, root: 9_999_999, dir: "out", label: "answer on a closed thread", replyBy: BY, ts: TS },
    { kind: "notify", type: "escalate", peer, root: 9_999_999, dir: "in", message_id: 9_999_999, label: "message on a closed thread", replyBy: BY, summary: "s", asks: [], ts: TS },
    { kind: "notify", type: "draft", peer, root: 9_999_999, draft: "3fa9c1d2", source: "send.ts", deadline: BY, text: "x", ts: TS },
    { kind: "notify", type: "result", peer, root: 9_999_999, draft: "3fa9c1d2", state: "REFUSED", rule: "a".repeat(40), ts: TS },
  ];
  for (const rec of recs) {
    const line1 = renderNotify(rec, ROOT).text.split("\n")[0];
    expect(line1.length).toBeLessThanOrEqual(LINE1_MAX);
    expect(line1.slice(0, 200)).toMatch(NOTIFY_LINE1_RE);
  }
  expect(NOTIFY_LINE1_RE.test("x peer example · T1")).toBe(false);
});

test("the desk command is on line 2 of a wake", () => {
  const [l1, l2] = renderNotify(every("x")[0], ROOT).text.split("\n");
  expect(l1).toBe("peer example · T4182 · new question · reply by 11-21 14:00");
  expect(l2).toBe("open the desk: bash /opt/himmel/scripts/peer-bridge/desk.sh example");
});

test("an escalation renders the untrusted banner, the sanitized digest and the asks", () => {
  expect(renderNotify(every("a question\u0007 about <b>x</b>")[1], ROOT).text).toBe([
    "peer example · T4182 · new question · reply by 11-21 14:00",
    "UNTRUSTED: written by the peer's bot, summarized by a model. Reply to this message to draft an answer.",
    "summary: a question about ‹b›x‹/b›",
    "asks:",
    "- a question about ‹b›x‹/b›",
    "- a question about ‹b›x‹/b›",
  ].join("\n"));
  expect(renderNotify(every("x")[2], ROOT).text).toBe("peer example · T4182 · answer\ntriage skipped (daily-cap). Read it in the desk: bash /opt/himmel/scripts/peer-bridge/desk.sh example");
});

test("a word-initial / in summary or asks renders as ∕", () => {
  const text = renderNotify(every("/approve now and/then /halt")[1], ROOT).text;
  expect(text).toContain("summary: ∕approve now and/then ∕halt");
  expect(text).toContain("- ∕approve now and/then ∕halt");
  expect(text.split("\n").slice(1).some(l => /(^|\s)\//.test(l))).toBe(false);
});

test("a draft render shows the source word, the absolute deadline and the exact bytes", () => {
  const r = renderNotify(every("exact  bytes\nline two ")[3], ROOT);
  expect(r.text).toBe("peer example · T4182 · draft 3fa9c1d2 from telegram · approve by 11-21 14:00\nText to send, exactly:\nexact  bytes\nline two ");
  expect(r.keyboard).toEqual({ peer: "example", draft: "3fa9c1d2" });
  expect(renderNotify(every("x")[4], ROOT)).toEqual({ text: "peer example · T4182 · draft 3fa9c1d2 · sent as message 4190" });
  expect(renderNotify(every("x")[5], ROOT).text).toBe("peer example · T4182 · draft 3fa9c1d2 · refused (egress)");
});

test("held, fallback and chain-alert lines match spec §1/§6", () => {
  expect(renderHeld(TS, "409")).toBe("peer notifications held since 14:02 (409)");
  expect(renderFallback(7, 400)).toBe("peer notify #7 could not be delivered (Telegram 400); read the desk");
  expect(renderChainAlert(7)).toBe("peer notify chain failed verification at #7; nothing more is sent until it is checked");
});

test("budget records render per which", () => {
  const recs = every("x");
  expect(renderNotify(recs[7], ROOT).text).toBe("peer example · wake budget reached (30 today) · later wakes stay silent until tomorrow");
  expect(renderNotify(recs[8], ROOT).text).toBe("peer example · escalation budget reached (20 today) · later messages show as wakes");
  expect(renderNotify(recs[6], ROOT).text).toBe("peer example · 2026-11-20 · triage: 4 escalated (3 as digests, 1 as wakes; 1 skipped: daily-cap) · 1 acked · 3 dropped");
  expect(renderNotify(recs[9], ROOT).text).toBe("peer example · 3 bad signatures in 1 h");
});

test("a record outside the closed shape renders nothing", () => {
  const bad: any[] = [
    { ...every("x")[0], peer: "Evil Peer" },
    { ...every("x")[0], label: "run this" },
    { ...every("x")[0], root: -1 },
    { ...every("x")[3], draft: "not-hex!" },
    { ...every("x")[3], source: "desk" },
    { ...every("x")[3], session: "abc" },
    { ...every("x")[2], reason: "a b" },
    { ...every("x")[0], type: "other" },
  ];
  for (const rec of bad) expect(() => renderNotify(rec, ROOT)).toThrow();
});

test("appendNotify writes chained records to S/notify/notify.jsonl", async () => {
  const S = mkdtempSync(join(tmpdir(), "peer-notify-"));
  const chain = new Chain();
  for (const rec of every("x").slice(0, 3)) await appendNotify(chain, notifyFile(S), rec);
  expect(notifyFile(S)).toBe(join(S, "notify", "notify.jsonl"));
  expect(readChain(notifyFile(S)).map(r => r.type)).toEqual(["wake", "escalate", "escalate"]);
  expect(verifyChain(notifyFile(S)).ok).toBe(true);
});
