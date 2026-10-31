import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dispatchAfkCallbacks, makeAfkSudoCallback, makeAfkSudoGate, makeAfkSudoPrompts, parseAfkSudo, type AfkSudoCallbackDeps, type AfkSudoDeps } from "./afk-sudo-route";
import { GROUP_ANONYMOUS_BOT_ID, isOperatorIdentity } from "./gate";
import { afkTapUnlessLocked, handleInbound, ingestBatch, ingestUpdates, inboundToDelivered, type AutoGate } from "./poller";
import { sessionDir } from "./bus";

const OP = 4242;
const access = { allowFrom: [String(OP)] };

function fake(installed = true) {
  const calls: { args: string[]; stdin: string }[] = [];
  const replies: string[] = [];
  const logs: string[] = [];
  const deps: AfkSudoDeps = {
    access: () => access,
    installed: () => installed,
    runHelper: async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=ran id=abcdefgh exit=0 argv=/usr/bin/systemctl restart x.service\n" }; },
    reply: async (_chat, text) => { replies.push(text); },
    log: (l) => { logs.push(l); },
  };
  return { deps, calls, replies, logs };
}
const dm = (text: string, extra: Record<string, unknown> = {}) => ({ from: OP, chat_id: OP, text, forwarded: false, caption: false, ...extra });
const settle = () => new Promise((r) => setTimeout(r, 5));

test("parse: approve with a code, deny, a spaced code and an uppercase verb", () => {
  expect(parseAfkSudo("approve abcdefgh 123456")).toEqual({ verb: "approve", id: "abcdefgh", code: "123456" });
  expect(parseAfkSudo("Approve ABCDEFGH 123 456")).toEqual({ verb: "approve", id: "abcdefgh", code: "123456" });
  expect(parseAfkSudo("deny abcdefgh")).toEqual({ verb: "deny", id: "abcdefgh", code: "" });
  expect(parseAfkSudo("approve abcdefgh")).toEqual({ verb: "approve", id: "abcdefgh", code: "" });
  expect(parseAfkSudo("please approve the PR")).toBeNull();
  expect(parseAfkSudo("approve abc 123456")).toBeNull();
});

test("the operator's typed DM approve reaches the helper with the code on stdin, never in argv", async () => {
  const { deps, calls, replies } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh 123456"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "123456\n" }]);
  expect(calls[0].args.join(" ")).not.toContain("123456");
  expect(replies[0]).toContain("result=ran");
});

test("an approve line with trailing words is consumed, so the code never reaches a session", async () => {
  const { deps, calls } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh 123456 please"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "123456please\n" }]);
});

test("an approve line with a mistyped id and a code is consumed, and never reaches the helper or a session", async () => {
  for (const text of ["approve abcdefg 123456", "approve abcdefghi 123 456", "approve abc-defgh 123456"]) {
    const { deps, calls, replies } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies[0]).toContain("nothing ran");
  }
  expect(makeAfkSudoGate(fake().deps)(dm("approve PR 4204"))).toBe(false);
});

test("deny reaches the helper with an empty stdin", async () => {
  const { deps, calls } = fake();
  expect(makeAfkSudoGate(deps)(dm("deny abcdefgh"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["deny", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "" }]);
});

test("forwarded, caption or voice, non-operator, group and anonymous-admin lines are consumed but never reach the helper", async () => {
  const cases = [
    dm("approve abcdefgh 123456", { forwarded: true }),
    dm("approve abcdefgh 123456", { caption: true }),
    dm("approve abcdefgh 123456", { forwarded: undefined }),
    dm("approve abcdefgh 123456", { from: 999, chat_id: 999 }),
    dm("approve abcdefgh 123456", { chat_id: -100123 }),
    dm("approve abcdefgh 123456", { from: GROUP_ANONYMOUS_BOT_ID, chat_id: -100123 }),
  ];
  for (const msg of cases) {
    const { deps, calls } = fake();
    expect(makeAfkSudoGate(deps)(msg)).toBe(true);
    await settle();
    expect(calls).toEqual([]);
  }
});

test("off by default: with no installed helper an approve line is not consumed", async () => {
  const { deps, calls } = fake(false);
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh 123456"))).toBe(false);
  await settle();
  expect(calls).toEqual([]);
});

test("ordinary text is not consumed", () => {
  const { deps } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve the release notes"))).toBe(false);
});

test("handleInbound: a consumed approve line is never appended to an inbox or run", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const { deps, calls } = fake();
  const ran: string[] = [];
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps) };
  await handleInbound(r, dm("approve abcdefgh 123456"), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
  await settle();
  expect(calls.length).toBe(1);
  expect(ran).toEqual([]);
  expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
});

test("handleInbound: a bare six-digit message with no reply or live prompt is held, never reaches an inbox or run", async () => {
  for (const text of ["123456", " 123456 ", "\t123456\n"]) {
    const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
    const { deps, calls, replies, logs } = fake();
    const ran: string[] = [];
    const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
    await handleInbound(r, dm(text), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
    await settle();
    expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
    expect(ran).toEqual([]);
    expect(calls).toEqual([]);
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain("held");
    expect(replies[0]).toContain("text:");
    expect([...replies, ...logs].join("\n")).not.toContain("123456");
  }
});

test("handleInbound: operator and trusted anonymous-admin bare codes in a group never reach an inbox or run", async () => {
  for (const from of [OP, GROUP_ANONYMOUS_BOT_ID]) {
    const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
    const { deps, calls, replies, logs } = fake();
    const groupAccess = { ...access, groups: { "-100123": { trustAnonymousAdmins: true } } };
    deps.access = () => groupAccess;
    const ran: string[] = [];
    const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
    await handleInbound(r, dm("123456", { from, chat_id: -100123, sender_chat: -100123 }), async (s) => { ran.push(s); }, auto, async () => "spawn-high", (sender, chat, senderChat) => isOperatorIdentity(groupAccess, sender, chat, senderChat));
    await settle();
    expect(existsSync(join(sessionDir(r, "group_-100123"), "inbox.jsonl"))).toBe(false);
    expect(ran).toEqual([]);
    expect(calls).toEqual([]);
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain("held");
    expect([...replies, ...logs].join("\n")).not.toContain("123456");
  }
});

test("handleInbound: operator and trusted anonymous-admin bare replies to the bot in a group are held", async () => {
  for (const from of [OP, GROUP_ANONYMOUS_BOT_ID]) {
    const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
    const { deps, calls, replies, logs } = fake();
    const groupAccess = { ...access, groups: { "-100123": { trustAnonymousAdmins: true } } };
    deps.access = () => groupAccess;
    const ran: string[] = [];
    const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
    await handleInbound(r, dm("123456", { from, chat_id: -100123, sender_chat: -100123, reply_to_message_id: 42, reply_to_bot: true }), async (s) => { ran.push(s); }, auto, async () => "spawn-high", (sender, chat, senderChat) => isOperatorIdentity(groupAccess, sender, chat, senderChat));
    await settle();
    expect(existsSync(join(sessionDir(r, "group_-100123"), "inbox.jsonl"))).toBe(false);
    expect(ran).toEqual([]);
    expect(calls).toEqual([]);
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain("held");
    expect([...replies, ...logs].join("\n")).not.toContain("123456");
  }
});

test("handleInbound: non-operator group numbers stay forwarded", async () => {
  for (const [from, trusted, senderChat] of [[999, true, -100123], [GROUP_ANONYMOUS_BOT_ID, false, -100123], [GROUP_ANONYMOUS_BOT_ID, true, -100999]] as const) {
    const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
    const { deps, calls, replies } = fake();
    const groupAccess = { ...access, groups: { "-100123": { trustAnonymousAdmins: trusted } } };
    deps.access = () => groupAccess;
    const ran: string[] = [];
    const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
    await handleInbound(r, dm("123456", { from, chat_id: -100123, sender_chat: senderChat }), async (s) => { ran.push(s); }, auto, async () => "spawn-high", (sender, chat, senderChat) => isOperatorIdentity(groupAccess, sender, chat, senderChat));
    expect(existsSync(join(sessionDir(r, "group_-100123"), "inbox.jsonl"))).toBe(true);
    expect(ran).toEqual(["group_-100123"]);
    expect(calls).toEqual([]);
    expect(replies).toEqual([]);
  }
});

test("a failed hold notice is logged without leaking the code or reopening delivery", async () => {
  const { deps, calls, logs } = fake();
  deps.reply = async () => { throw new Error("outbox refused 123456"); };
  expect(makeAfkSudoGate(deps)(dm("123456"))).toBe(true);
  await settle();
  expect(calls).toEqual([]);
  expect(logs).toHaveLength(1);
  expect(logs[0]).toContain("hold notice failed");
  expect(logs.join("\n")).not.toContain("123456");
});

test("off by default: a bare six-digit message stays ordinary text without the helper", () => {
  const { deps, calls, replies, logs } = fake(false);
  expect(makeAfkSudoGate(deps, makeAfkSudoPrompts())(dm(" 123456 "))).toBe(false);
  expect(calls).toEqual([]);
  expect(replies).toEqual([]);
  expect(logs).toEqual([]);
});

test("bare-code hold does not consume ordinary numbers or numbers sent as text", () => {
  const { deps } = fake();
  const gate = makeAfkSudoGate(deps);
  for (const text of ["12345", "1234567", "123 456", "123-456", "text: 123456", "number 123456"]) {
    expect(gate(dm(text))).toBe(false);
  }
});

test("handleInbound: under lockdown an approve line never reaches the helper", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  writeFileSync(join(r, "lockdown"), "locked\n");
  const { deps, calls } = fake();
  const ran: string[] = [];
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps) };
  await handleInbound(r, dm("approve abcdefgh 123456"), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
  await settle();
  expect(calls.length).toBe(0);
  expect(ran).toEqual([]);
  expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
});

// --- Approve / Deny buttons, then a ForceReply code prompt ---

function buttons(opts: { operator?: number | null; promptId?: number | null; allowFrom?: string[] } = {}) {
  const base = fake();
  if (opts.allowFrom) base.deps.access = () => ({ allowFrom: opts.allowFrom! });
  const sent: { chat: number; text: string }[] = [];
  const answers: string[] = [];
  let clock = 1_000_000;
  const deps: AfkSudoCallbackDeps = {
    ...base.deps,
    operatorId: () => (opts.operator === undefined ? OP : opts.operator),
    prompt: async (chat, text) => { sent.push({ chat, text }); return opts.promptId === undefined ? 77 : opts.promptId; },
    answer: async (_cb, text) => { answers.push(text); },
  };
  const prompts = makeAfkSudoPrompts(() => clock, 150_000);
  return {
    ...base, sent, answers, prompts, tick: (ms: number) => { clock += ms; },
    gate: makeAfkSudoGate(deps, prompts), tap: makeAfkSudoCallback(deps, prompts),
  };
}
const tapOf = (data: string, extra: Record<string, unknown> = {}) => ({ callback_id: "cb1", from: OP, chat_id: OP, data, ...extra });
const reply = (text: string, to: number, extra: Record<string, unknown> = {}) => dm(text, { reply_to_message_id: to, ...extra });

test("button: an Approve tap asks for the code with a prompt and never reaches the helper", async () => {
  const b = buttons();
  expect(b.tap(tapOf("afk:approve:abcdefgh"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.sent).toEqual([{ chat: OP, text: "Code for abcdefgh:" }]);
  expect(b.answers.length).toBe(1);
});

test("button: the six-digit reply to that prompt approves with the code on stdin, never in argv or logs", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(reply("123456", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "123456\n" }]);
  expect([...b.replies, ...b.sent.map((s) => s.text), ...b.answers, ...b.logs].join("\n")).not.toContain("123456");
});

test("button: a prompt is single use", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.gate(reply("123456", 77));
  await settle();
  expect(b.gate(reply("654321", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
  expect(b.replies.at(-1)).toContain("already used");
  expect([...b.replies, ...b.logs].join("\n")).not.toContain("654321");
});

test("button: a Deny tap denies at once and asks for no code", async () => {
  const b = buttons();
  expect(b.tap(tapOf("afk:deny:abcdefgh"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["deny", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "" }]);
  expect(b.sent).toEqual([]);
});

test("button: a tap from a stranger, a non-operator allowFrom id, or a group chat does nothing", async () => {
  for (const [tap, operator] of [
    [tapOf("afk:approve:abcdefgh", { from: 999, chat_id: 999 }), OP],
    [tapOf("afk:deny:abcdefgh", { from: 999, chat_id: 999 }), OP],
    [tapOf("afk:approve:abcdefgh"), 5151],
    [tapOf("afk:approve:abcdefgh"), null],
    [tapOf("afk:deny:abcdefgh", { chat_id: -100123 }), OP],
  ] as const) {
    const b = buttons({ operator });
    expect(b.tap(tap)).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.sent).toEqual([]);
    expect(b.answers).toEqual(["Not authorized."]);
  }
});

test("button: a tap from the helper's operator id is refused when that id is outside allowFrom", async () => {
  for (const data of ["afk:approve:abcdefgh", "afk:deny:abcdefgh"]) {
    const b = buttons({ allowFrom: ["999"] });
    expect(b.tap(tapOf(data))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.sent).toEqual([]);
    expect(b.answers).toEqual(["Not authorized."]);
  }
});

test("poller: a button tap under lockdown never reaches the tap gate", () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const updates = [{ update_id: 1, callback_query: { id: "c1", from: { id: OP }, data: "afk:deny:abcdefgh", message: { chat: { id: OP } } } }];
  const seen: unknown[] = [];
  dispatchAfkCallbacks(updates, afkTapUnlessLocked(r, (t) => { seen.push(t); return true; }));
  expect(seen.length).toBe(1);
  writeFileSync(join(r, "lockdown"), "locked\n");
  dispatchAfkCallbacks(updates, afkTapUnlessLocked(r, (t) => { seen.push(t); return true; }));
  expect(seen.length).toBe(1);
});

test("button: data that is not an afk button is not consumed", () => {
  const b = buttons();
  for (const data of ["perm:allow:abcde", "afk:approve:abc", "afk:run:abcdefgh", "afk:approve:abcdefgh;x"]) expect(b.tap(tapOf(data))).toBe(false);
});

test("button: with no installed helper a tap is not consumed", () => {
  const base = buttons();
  const off = makeAfkSudoCallback({ ...fake(false).deps, operatorId: () => OP, prompt: async () => 1, answer: async () => {} }, base.prompts);
  expect(off(tapOf("afk:approve:abcdefgh"))).toBe(false);
});

test("button: a six-digit reply to an unknown message is ordinary text, not consumed", async () => {
  const b = buttons();
  expect(b.gate(reply("123456", 77))).toBe(false);
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(reply("hello", 78))).toBe(false);
  expect(b.calls).toEqual([]);
});

test("button: a reply to a bot message with no known prompt holding a standalone six-digit token, or only a spaced code, is consumed", async () => {
  for (const text of [" 123456 ", "code 123456", "123456 thanks", "ship 123456 and 654321 today", "123 456", "123-456", "12 34 56", "1234567", "10-31 08"]) {
    const b = buttons();
    expect(b.gate(reply(text, 99, { reply_to_bot: true }))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies).toEqual(["⚠️ afk-sudo: that code prompt expired, tap Approve again"]);
  }
});

test("button: HIMMEL-8365 a reply to a non-sudo bot message whose six digits exist only split by spaces or hyphens inside words is ordinary text", async () => {
  for (const text of ["do 8276 8277 next", "ticket 123-456 is done"]) {
    const b = buttons();
    expect(b.gate(reply(text, 99, { reply_to_bot: true }))).toBe(false);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies).toEqual([]);
  }
});

test("button: while a code prompt is live, a code-shaped message sent without replying is consumed, not forwarded", async () => {
  for (const text of ["123456", "123 456", "123-456"]) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(b.gate(dm(text))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies.at(-1)).toContain("abcdefgh");
    expect([...b.replies, ...b.logs].join("\n")).not.toContain("456");
  }
  // Without a live prompt, a bare code is held rather than forwarded.
  const none = buttons();
  expect(none.gate(dm("123456"))).toBe(true);
  expect(none.replies.at(-1)).toContain("held");
  const late = buttons();
  late.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  late.tick(151_000);
  expect(late.gate(dm("123456"))).toBe(true);
  expect(late.replies.at(-1)).toContain("held");
  const live = buttons();
  live.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  for (const msg of [dm("123456", { from: 999, chat_id: 999 }), dm("123456", { forwarded: true }), dm("hello"), dm("42")]) {
    expect(live.gate(msg)).toBe(false);
  }
});

test("button: a code buried in words or punctuation is consumed while a prompt is live, and on a reply to a bot message when it is a standalone six-digit token", async () => {
  const texts = ["123456.", "code 123456", "123456 thanks", "approve 123456", "my code is 123 456, ok", "(123-456)"];
  for (const text of texts) {
    // a reply to a bot message with no known prompt is held only for a contiguous six-digit token
    const gone = buttons();
    expect(gone.gate(reply(text, 99, { reply_to_bot: true }))).toBe(/(?<!\d)\d{6}(?!\d)/.test(text));
    const live = buttons();
    live.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(live.gate(dm(text))).toBe(true);
    await settle();
    expect(gone.calls).toEqual([]);
    expect(live.calls).toEqual([]);
  }
  // control: a five-digit run is not a code
  for (const text of ["12345", "call 12345 now", "12 345", "see 1234 and 56 tomorrow"]) {
    const gone = buttons();
    expect(gone.gate(reply(text, 99, { reply_to_bot: true }))).toBe(false);
    const live = buttons();
    live.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(live.gate(dm(text))).toBe(false);
  }
});

test("button: the typed approve line still reaches the helper while a prompt is live", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(dm("approve ijklmnop 123456"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "ijklmnop", "--from", String(OP), "--chat", String(OP)], stdin: "123456\n" }]);
});

test("poller: ingest then the real delivery mapping carries reply_to_bot into the gate", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const { deps, calls } = fake();
  const ran: string[] = [];
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
  await ingestUpdates(r, [{ update_id: 1, message: { message_id: 5, chat: { id: OP }, from: { id: OP }, text: "123 456", reply_to_message: { message_id: 40, from: { id: 99, is_bot: true } } } }]);
  await ingestBatch(r, (i) => handleInbound(r, inboundToDelivered(i), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true));
  await settle();
  expect(calls.length).toBe(0);
  expect(ran).toEqual([]);
  expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
});

test("button: a six-digit reply to a bot message with no known prompt is consumed and never forwarded", async () => {
  const b = buttons();
  expect(b.gate(reply("123456", 99, { reply_to_bot: true }))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies).toEqual(["⚠️ afk-sudo: that code prompt expired, tap Approve again"]);
  expect(b.logs.join("\n")).not.toContain("123456");
  // other shapes of a reply to the bot stay ordinary text
  for (const msg of [reply("hello", 99, { reply_to_bot: true }), reply("123456", 99), reply("123456", 99, { reply_to_bot: true, forwarded: true }), reply("123456", 99, { reply_to_bot: true, from: 999, chat_id: 999 })]) {
    expect(buttons().gate(msg)).toBe(false);
  }
});

test("handleInbound: a six-digit reply to a bot message after a restart never lands in an inbox or run", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const { deps, calls } = fake();
  const ran: string[] = [];
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps, makeAfkSudoPrompts()) };
  await handleInbound(r, reply("123456", 99, { reply_to_bot: true }), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
  await settle();
  expect(calls.length).toBe(0);
  expect(ran).toEqual([]);
  expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
});

test("button: a reply that is not exactly six digits is consumed, tells the operator, and keeps the prompt alive", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  for (const t of ["12345", "1234567", "hello", "123 456 ok"]) {
    expect(b.gate(reply(t, 77))).toBe(true);
  }
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies.length).toBe(4);
  expect(b.gate(reply("123456", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
});

test("button: a reply after the prompt window is consumed but never reaches the helper", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.tick(151_000);
  expect(b.gate(reply("123456", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies[0]).toContain("expired");
  expect(b.gate(reply("654321", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
});

test("button: a reply that is forwarded, from another chat or from another sender never reaches the helper", async () => {
  for (const extra of [{ forwarded: true }, { from: 999, chat_id: 999 }, { chat_id: -100123 }]) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    b.gate(reply("123456", 77, extra));
    await settle();
    expect(b.calls).toEqual([]);
  }
});

test("button: when the prompt cannot be sent nothing is remembered", async () => {
  const b = buttons({ promptId: null });
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(reply("123456", 77))).toBe(false);
  expect(b.calls).toEqual([]);
});

test("button: the typed approve line keeps working beside the buttons", async () => {
  const b = buttons();
  expect(b.gate(dm("approve abcdefgh 123456"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "123456\n" }]);
});

test("dispatch: callback_query updates reach the tap gate with the sender and chat; malformed ones are skipped", () => {
  const seen: unknown[] = [];
  const updates = [
    { update_id: 1, callback_query: { id: "c1", from: { id: OP }, data: "afk:deny:abcdefgh", message: { chat: { id: OP } } } },
    { update_id: 2, message: { text: "hi" } },
    { update_id: 3, callback_query: { id: "c3", from: { id: OP }, data: "afk:deny:abcdefgh" } },
    { update_id: 4, callback_query: { id: "c4", from: { id: "x" }, data: "afk:deny:abcdefgh", message: { chat: { id: OP } } } },
    { update_id: 5, callback_query: { id: "c5", from: { id: OP }, message: { chat: { id: OP } } } },
  ];
  dispatchAfkCallbacks(updates, (tap) => { seen.push(tap); return true; });
  expect(seen).toEqual([{ callback_id: "c1", from: OP, chat_id: OP, data: "afk:deny:abcdefgh" }]);
});
