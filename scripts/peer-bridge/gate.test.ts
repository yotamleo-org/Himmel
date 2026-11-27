import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readChain } from "./chain";
import type { Config } from "./config";
import { EnvelopeWindow, admit, appendUnknownChat, createGateState, noteAdmitted, rebuildFromInbox, type GateState } from "./gate";
import { failedTests, makeRedCopy } from "./testlib-red-copy";
import * as G from "./gate";

const OUR_ID = "111000111", OUR_NAME = "ours_bot", PEER_ID = "555000111", HUMAN = "42";
const CHAT = -1001234567890;
const NOW = 1_731_000_000_000;

function cfg(over: Record<string, unknown> = {}): Pick<Config, "peers" | "maxTextChars"> {
  return {
    maxTextChars: 4000,
    peers: {
      example: {
        peerBotId: PEER_ID, chatId: CHAT, allowFrom: [PEER_ID, HUMAN], opens: ["question", "status", "info"],
        maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
        theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" },
        ...over,
      } as any,
    },
  };
}
const fresh = (): GateState => createGateState({ ourBotId: OUR_ID, ourUsername: OUR_NAME, committed: 0, now: NOW });

let uid = 100;
let mid = 1000;
function msg(over: Record<string, unknown> = {}, text = `/peer@${OUR_NAME}\n#ask:question id=a1b2c3d4\nhow do I x?`) {
  return { message_id: ++mid, from: { id: Number(PEER_ID), is_bot: true, username: "example_bot" }, chat: { id: CHAT, type: "supergroup", title: "bridge" }, date: NOW / 1000, text, ...over };
}
const upd = (message: Record<string, unknown>, over: Record<string, unknown> = {}) => ({ update_id: ++uid, message, ...over });
const rootUpd = (over: Record<string, unknown> = {}, text?: string) => upd(msg(over, text));

function accept(state: GateState, u: any, c = cfg()) {
  const r = admit(u, c, state);
  if (r.ok) noteAdmitted(state, r.rec);
  return r;
}
function dropped(r: ReturnType<typeof admit>, rule: number, reason?: string) {
  expect(r.ok).toBe(false);
  if (!r.ok) {
    expect(r.rule).toBe(rule);
    if (reason) expect(r.reason).toContain(reason);
    expect(r.log).toContain(`rule=${rule}`);
  }
}

test("the happy path admits a root, strips the address line and keeps the body", () => {
  const r = admit(rootUpd(), cfg(), fresh());
  expect(r.ok).toBe(true);
  if (!r.ok) return;
  expect(r.peer).toBe("example");
  expect(r.truncated).toBe(false);
  expect(r.rec).toMatchObject({ kind: "peer-msg", untrusted: true, peer: "example", from_id: PEER_ID, from_is_bot: true, chat_id: CHAT, id: "a1b2c3d4", tag: "ask:question", text: "how do I x?", ts: NOW / 1000 });
  expect(r.rec.root_id).toBe(r.rec.message_id);
  expect(r.rec.text).not.toContain("/peer@");
});

test("rule 1: a replayed update_id is dropped", () => {
  const s = createGateState({ ourBotId: OUR_ID, ourUsername: OUR_NAME, committed: 500, now: NOW });
  dropped(admit({ update_id: 500, message: msg() }, cfg(), s), 1, "update_id");
  dropped(admit({ update_id: 499, message: msg() }, cfg(), s), 1);
  expect(admit({ update_id: 501, message: msg() }, cfg(), s).ok).toBe(true);
});

test("rule 1: a duplicate (chat, from, id) is dropped, a resend with the same id too", () => {
  const s = fresh();
  expect(accept(s, rootUpd()).ok).toBe(true);
  dropped(accept(s, rootUpd()), 1, "duplicate");
});

test("rule 1: a message with no control line is deduped by update_id only", () => {
  const s = fresh();
  const u = rootUpd({}, `/peer@${OUR_NAME}\nplain words`);
  const first = accept(s, u);
  expect(first.ok && first.rec.tag).toBe("untagged");
  const again = accept(s, rootUpd({}, `/peer@${OUR_NAME}\nplain words`));
  expect(again.ok).toBe(true);
  const s2 = createGateState({ ourBotId: OUR_ID, ourUsername: OUR_NAME, committed: u.update_id, now: NOW });
  dropped(admit(u, cfg(), s2), 1);
});

test("rule 2: a basic group is dropped", () => {
  dropped(admit(rootUpd({ chat: { id: CHAT, type: "group" } }), cfg(), fresh()), 2, "supergroup");
  dropped(admit(rootUpd({ chat: { id: CHAT, type: "private" } }), cfg(), fresh()), 2);
});

test("rule 2: a migration from a configured old id logs MIGRATED and adds an unknown-chats row", () => {
  const u = upd({ message_id: 1, from: { id: 1, is_bot: false }, chat: { id: CHAT, type: "group", title: "old" }, date: 1, migrate_to_chat_id: -1009876543210 });
  const r = admit(u, cfg(), fresh());
  dropped(r, 2);
  if (!r.ok) {
    expect(r.log).toContain("MIGRATED");
    expect(r.unknownChat).toMatchObject({ chat_id: -1009876543210, migrated_from: CHAT });
  }
});

test("rule 3: an unknown supergroup is dropped and described for unknown-chats.jsonl", () => {
  const r = admit(rootUpd({ chat: { id: -1005555555555, type: "supergroup", title: "stranger" } }), cfg(), fresh());
  dropped(r, 3, "unknown chat");
  if (!r.ok) expect(r.unknownChat).toMatchObject({ chat_id: -1005555555555, type: "supergroup", title: "stranger" });
});

test("appendUnknownChat writes one 0600 line per chat id", () => {
  const file = join(mkdtempSync(join(tmpdir(), "peer-unknown-")), "unknown-chats.jsonl");
  appendUnknownChat(file, { chat_id: -1005, type: "supergroup", title: "a" });
  appendUnknownChat(file, { chat_id: -1005, type: "supergroup", title: "a" });
  appendUnknownChat(file, { chat_id: -1006, type: "supergroup", title: "b" });
  const lines = readFileSync(file, "utf8").trim().split("\n").map(l => JSON.parse(l));
  expect(lines.map(l => l.chat_id)).toEqual([-1005, -1006]);
  expect(statSync(file).mode & 0o777).toBe(0o600);
});

test("appendUnknownChat survives a torn trailing row and still dedups", () => {
  const file = join(mkdtempSync(join(tmpdir(), "peer-unknown-")), "unknown-chats.jsonl");
  writeFileSync(file, JSON.stringify({ chat_id: -1005, type: "supergroup", title: "a", ts: 1 }) + "\n" + '{"chat_id":');
  expect(() => appendUnknownChat(file, { chat_id: -1006, type: "supergroup", title: "b" })).not.toThrow();
  expect(() => appendUnknownChat(file, { chat_id: -1005, type: "supergroup", title: "a" })).not.toThrow();
  expect(() => appendUnknownChat(file, { chat_id: -1007, type: "supergroup", title: "c" })).not.toThrow();
  const text = readFileSync(file, "utf8");
  expect(text.endsWith("\n")).toBe(true);
  expect(text.trimEnd().split("\n").map(l => JSON.parse(l).chat_id)).toEqual([-1005, -1006, -1007]);
  expect(readChain(file).length).toBe(3);
});

test("rule 4: a sender not in allowFrom is dropped", () => {
  dropped(admit(rootUpd({ from: { id: 999, is_bot: false } }), cfg(), fresh()), 4, "not in allowFrom");
  dropped(admit(rootUpd({ from: undefined }), cfg(), fresh()), 4);
});

test("rule 4: empty allowFrom admits nobody", () => {
  dropped(admit(rootUpd(), cfg({ allowFrom: [] }), fresh()), 4, "empty allowFrom");
});

test("rule 5: sender_chat, the anonymous admin id and our own bot are dropped", () => {
  const c = cfg({ allowFrom: [PEER_ID, "1087968824", OUR_ID] });
  dropped(admit(rootUpd({ sender_chat: { id: -100777, type: "channel" } }), c, fresh()), 5, "sender_chat");
  dropped(admit(rootUpd({ from: { id: 1087968824, is_bot: true } }), c, fresh()), 5, "anonymous");
  dropped(admit(rootUpd({ from: { id: Number(OUR_ID), is_bot: true } }), c, fresh()), 5, "own bot");
});

test("rule 6: an edit, a forward, via_bot, external_reply, quote, a photo and a document are dropped", () => {
  const cases: [string, Record<string, unknown>][] = [
    ["edit", { edit_date: 5 }],
    ["forward", { forward_origin: { type: "user" } }],
    ["forward", { forward_from: { id: 1 } }],
    ["via_bot", { via_bot: { id: 9 } }],
    ["external_reply", { external_reply: { origin: {} } }],
    ["quote", { quote: { text: "x" } }],
    ["not plain text", { text: undefined, photo: [{ file_id: "x" }], caption: `/peer@${OUR_NAME}` }],
    ["not plain text", { text: undefined, document: { file_id: "x" } }],
  ];
  for (const [why, over] of cases) dropped(admit(rootUpd(over), cfg(), fresh()), 6, why);
  dropped(admit({ update_id: ++uid, edited_message: msg() }, cfg(), fresh()), 6, "edit");
  dropped(admit({ update_id: ++uid, my_chat_member: {} }, cfg(), fresh()), 6);
});

test("rule 6 addressing: chatter with no /peer@ line is dropped (the admin bot sees all of it)", () => {
  const s = fresh();
  dropped(admit(rootUpd({ from: { id: Number(HUMAN), is_bot: false } }, "hello everyone"), cfg(), s), 6, "unaddressed");
  dropped(admit(rootUpd({}, "#ask:question id=a1b2c3d4\nno address line"), cfg(), s), 6, "unaddressed");
});

test("rule 6 addressing: a root addressed to another bot is dropped", () => {
  dropped(admit(rootUpd({}, "/peer@other_bot\n#ask:question id=a1b2c3d4\nx"), cfg(), fresh()), 6, "unaddressed");
});

test("rule 6 addressing: a reply to a message that is neither ours nor an admitted root is dropped", () => {
  const s = fresh();
  dropped(admit(upd(msg({ reply_to_message: { message_id: 7, from: { id: 31337, is_bot: false } } }, "#answer id=a1b2c3d4\nx")), cfg(), s), 6, "reply");
});

test("rule 6 addressing: a reply to one of our non-root messages is dropped before anything is queued", () => {
  const s = fresh();
  s.roots.add(`${CHAT}:120`);
  dropped(admit(upd(msg({ reply_to_message: { message_id: 555, from: { id: Number(OUR_ID), is_bot: true } } }, "#answer id=a1b2c3d4\nx")), cfg(), s), 6, "reply");
});

test("rule 6 addressing: a reply to an admitted root passes, ours or the peer's own", () => {
  const s = fresh();
  s.roots.add(`${CHAT}:120`);
  const r = accept(s, upd(msg({ reply_to_message: { message_id: 120, from: { id: Number(OUR_ID), is_bot: true } } }, "#answer id=a1b2c3d4\nthe answer")));
  expect(r.ok && r.rec).toMatchObject({ tag: "answer", root_id: 120, text: "the answer" });
  s.roots.add(`${CHAT}:130`);
  const nudge = accept(s, upd(msg({ reply_to_message: { message_id: 130, from: { id: Number(PEER_ID), is_bot: true } } }, "#tpl:nudge #130 id=0a0b0c0d")));
  expect(nudge.ok && nudge.rec).toMatchObject({ tag: "tpl:nudge", root_id: 130, tpl_root: 130 });
});

test("rule 6: roots are keyed by chat, so the same message id in another chat is not a root", () => {
  const s = fresh();
  s.roots.add(`-100999:120`);
  dropped(admit(upd(msg({ reply_to_message: { message_id: 120, from: { id: Number(PEER_ID), is_bot: true } } }, "#answer id=a1b2c3d4\nx")), cfg(), s), 6);
});

test("rule 7: the 11th message in a minute is dropped, templates counted", () => {
  const s = fresh();
  s.roots.add(`${CHAT}:120`);
  for (let i = 0; i < 10; i++) {
    const id = (0x10000000 + i).toString(16);
    const text = i % 2 ? `#tpl:nudge #120 id=${id}` : `#answer id=${id}\nx`;
    const r = accept(s, upd(msg({ reply_to_message: { message_id: 120, from: { id: Number(PEER_ID), is_bot: true } } }, text)));
    expect(r.ok).toBe(true);
  }
  dropped(accept(s, upd(msg({ reply_to_message: { message_id: 120, from: { id: Number(PEER_ID), is_bot: true } } }, "#answer id=99999999\nx"))), 7, "rate");
  s.now += 61_000;
  expect(accept(s, upd(msg({ reply_to_message: { message_id: 120, from: { id: Number(PEER_ID), is_bot: true } } }, "#answer id=99999999\nx"))).ok).toBe(true);
});

test("rule 7: the rate window survives a rebuild from the inbox", () => {
  const s = fresh();
  const inbox = Array.from({ length: 10 }, (_, i) => ({ peer: "example", chat_id: CHAT, from_id: PEER_ID, id: `0000000${i}`, ts: NOW / 1000 - 5 }));
  rebuildFromInbox(s, inbox);
  dropped(admit(rootUpd(), cfg(), s), 7);
  const old = fresh();
  rebuildFromInbox(old, inbox.map(r => ({ ...r, ts: NOW / 1000 - 120 })));
  expect(admit(rootUpd(), cfg(), old).ok).toBe(true);
});

test("rule 8: 5000 UTF-16 units are cut to 4000 and admitted, never split mid-pair", () => {
  const long = "x".repeat(5000);
  const r = admit(rootUpd({}, `/peer@${OUR_NAME}\n#ask:question id=a1b2c3d4\n${long}`), cfg(), fresh());
  expect(r.ok && r.truncated).toBe(true);
  expect(r.ok && r.rec.text.length).toBe(4000);
  const pairs = "😀".repeat(3000);
  const r2 = admit(rootUpd({}, `/peer@${OUR_NAME}\n#ask:question id=a1b2c3d5\n${pairs}`), cfg({}), fresh());
  expect(r2.ok && r2.truncated).toBe(true);
  expect(r2.ok && r2.rec.text.length).toBe(4000);
  expect(r2.ok && r2.rec.text.endsWith("😀")).toBe(true);
  const odd = admit(rootUpd({}, `/peer@${OUR_NAME}\n#ask:question id=a1b2c3d6\nx${"😀".repeat(3000)}`), cfg(), fresh());
  expect(odd.ok && odd.rec.text.length).toBe(3999);
});

test("two #answers on one root with different ids are both admitted", () => {
  const s = fresh();
  s.roots.add(`${CHAT}:120`);
  const reply = { reply_to_message: { message_id: 120, from: { id: Number(OUR_ID), is_bot: true } } };
  expect(accept(s, upd(msg(reply, "#answer id=aaaaaaaa\none"))).ok).toBe(true);
  expect(accept(s, upd(msg(reply, "#answer id=bbbbbbbb\ntwo"))).ok).toBe(true);
});

test("a #tpl: line from a human id is untagged, from the peer bot it is a template", () => {
  const s = fresh();
  s.roots.add(`${CHAT}:120`);
  const reply = (id: number) => ({ from: { id, is_bot: id === Number(PEER_ID) }, reply_to_message: { message_id: 120, from: { id: Number(OUR_ID), is_bot: true } } });
  const human = accept(s, upd(msg(reply(Number(HUMAN)), "#tpl:receipt #120 id=cccccccc")));
  expect(human.ok && human.rec.tag).toBe("untagged");
  expect(human.ok && "id" in human.rec).toBe(false);
  const bot = accept(s, upd(msg(reply(Number(PEER_ID)), "#tpl:receipt #120 id=dddddddd")));
  expect(bot.ok && bot.rec.tag).toBe("tpl:receipt");
});

test("#ask:run is untagged", () => {
  const r = admit(rootUpd({}, `/peer@${OUR_NAME}\n#ask:run id=a1b2c3d4\nrm -rf x`), cfg(), fresh());
  expect(r.ok && r.rec.tag).toBe("untagged");
});

test("a human in allowFrom may send a kind line", () => {
  const r = admit(rootUpd({ from: { id: Number(HUMAN), is_bot: false } }), cfg(), fresh());
  expect(r.ok && r.rec).toMatchObject({ from_id: HUMAN, from_is_bot: false, tag: "ask:question" });
});

test("every drop is one log line with no message text", () => {
  const r = admit(rootUpd({ from: { id: 999, is_bot: false } }, "SECRET-CANARY-TEXT"), cfg(), fresh());
  expect(r.ok).toBe(false);
  if (!r.ok) { expect(r.log.includes("\n")).toBe(false); expect(r.log).not.toContain("SECRET-CANARY"); }
});

test("the envelope window keeps an id until its exp, with no count eviction, and is separate from the text window", () => {
  const w = new EnvelopeWindow();
  for (let i = 0; i < 5000; i++) w.add(CHAT, 1, i.toString(16).padStart(8, "0"), 2000 + i);
  expect(w.size).toBe(5000);
  expect(w.has(CHAT, 1, "00000000")).toBe(true);
  expect(w.has(CHAT, 2, "00000000")).toBe(false);
  expect(w.has(CHAT - 1, 1, "00000000")).toBe(false);
  w.prune(2000);
  expect(w.has(CHAT, 1, "00000000")).toBe(false);
  expect(w.has(CHAT, 1, "00000001")).toBe(true);
  const state = fresh();
  state.recent.add(`${CHAT}:1:00000001`);
  expect(state.envIds.has(CHAT, 1, "00000001")).toBe(false);
});

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: removing the empty-allowFrom check fails the empty allowFrom row and no other", () => {
  const root = makeRedCopy(["scripts/telegram/bus.ts", "scripts/telegram/gate.ts"]);
  const run = () => spawnSync("bun", ["test", "./scripts/peer-bridge/gate.test.ts"], { cwd: root, encoding: "utf8", env: { ...process.env, PEER_RED_COPY: "1" } });
  const clean = run();
  expect(clean.status).toBe(0);
  const target = join(root, "scripts/peer-bridge/gate.ts");
  const src = readFileSync(target, "utf8");
  expect(src.split("\n").filter(l => l.includes("empty allowFrom"))).toHaveLength(1);
  writeFileSync(target, src.split("\n").filter(l => !l.includes("empty allowFrom")).join("\n"));
  const mutated = run();
  expect(mutated.status).not.toBe(0);
  expect(failedTests(mutated.stdout + mutated.stderr)).toEqual(["rule 4: empty allowFrom admits nobody"]);
}, 60_000);

test("an id taken back out of the envelope window is no longer a duplicate, and only that id", () => {
  const w = new EnvelopeWindow();
  w.add(CHAT, 1, "00000001", 2000);
  w.add(CHAT, 1, "00000002", 2000);
  w.delete(CHAT, 1, "00000001");
  expect(w.has(CHAT, 1, "00000001")).toBe(false);
  expect(w.has(CHAT, 1, "00000002")).toBe(true);
  expect(w.size).toBe(1);
});

const CARD_PUB = Buffer.alloc(32, 5).toString("base64");
const CARD_TEXT = `/peer@${OUR_NAME}\n#pair station=example key=${CARD_PUB}`;
const cardUpd = (over: Record<string, unknown> = {}, text = CARD_TEXT) => rootUpd(over, text);

test("admitCard admits the peer bot's fresh two-line card in the configured supergroup", () => {
  const u = cardUpd();
  expect(G.looksLikeCard(u)).toBe(true);
  const r = G.admitCard(u, cfg(), fresh());
  expect(r.ok).toBe(true);
  if (r.ok) expect(r.rec).toEqual({ kind: "peer-card", untrusted: true, peer: "example", from_id: PEER_ID, chat_id: CHAT, message_id: u.message.message_id, ts: NOW / 1000, station: "example", key: CARD_PUB } as any);
});

test("admitCard refuses every other sender, chat and shape, and logs only the text's sha", () => {
  const who = (id: number, bot = true) => ({ from: { id, is_bot: bot, username: "x" } });
  const cases: [string, any][] = [
    ["another allowFrom id", cardUpd(who(Number(HUMAN)))],
    ["a human peer id", cardUpd(who(Number(PEER_ID), false))],
    ["another chat", cardUpd({ chat: { id: -100555, type: "supergroup" } })],
    ["a basic group", cardUpd({ chat: { id: CHAT, type: "group" } })],
    ["an edit", cardUpd({ edit_date: 5 })],
    ["a forward", cardUpd({ forward_date: 5 })],
    ["via_bot", cardUpd({ via_bot: { id: 1 } })],
    ["a quote", cardUpd({ quote: { text: "x" } })],
    ["a reply", cardUpd({ reply_to_message: { message_id: 1 } })],
    ["a sender_chat", cardUpd({ sender_chat: { id: 1 } })],
    ["the anonymous admin", cardUpd(who(1087968824))],
    ["our own bot", cardUpd(who(Number(OUR_ID)))],
    ["a third line", cardUpd({}, CARD_TEXT + "\nmore")],
    ["another bot's address", cardUpd({}, CARD_TEXT.replace(OUR_NAME, "other_bot"))],
    ["a bad key", cardUpd({}, `/peer@${OUR_NAME}\n#pair station=example key=${CARD_PUB.slice(0, -2)}d=`)],
  ];
  for (const [why, u] of cases) {
    const state = fresh();
    const c = why === "another chat" ? cfg() : cfg();
    if (why === "a reply") state.roots.add(`${CHAT}:1`);
    const r = G.admitCard(u, c, state);
    expect([why, r.ok]).toEqual([why, false]);
    if (!r.ok) {
      expect(r.log).toMatch(/^card-drop rule=\d reason=.+ peer=(example|-) sha256=[0-9a-f]{64}$/);
      expect(r.log).not.toContain(CARD_PUB);
    }
  }
  const state = fresh();
  const u = cardUpd();
  state.committed = u.update_id;
  expect(G.admitCard(u, cfg(), state).ok).toBe(false);
});

test("admitCard keeps the unknown-chat row of a rule 3 drop", () => {
  const r = G.admitCard(cardUpd({ chat: { id: -100555, type: "supergroup", title: "t" } }), cfg(), fresh());
  expect(r.ok === false && r.unknownChat).toEqual({ chat_id: -100555, type: "supergroup", title: "t" });
});
