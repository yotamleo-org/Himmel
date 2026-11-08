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

test("parse: approve with a nonce and a code, deny, a spaced code and an uppercase verb", () => {
  expect(parseAfkSudo("approve abcdefgh K7QF 123456")).toEqual({ verb: "approve", id: "abcdefgh", code: "K7QF123456" });
  expect(parseAfkSudo("Approve ABCDEFGH k7qf 123 456")).toEqual({ verb: "approve", id: "abcdefgh", code: "k7qf123456" });
  expect(parseAfkSudo("deny abcdefgh")).toEqual({ verb: "deny", id: "abcdefgh", code: "" });
  expect(parseAfkSudo("approve abcdefgh")).toEqual({ verb: "approve", id: "abcdefgh", code: "" });
  expect(parseAfkSudo("please approve the PR")).toBeNull();
  expect(parseAfkSudo("approve abc 123456")).toBeNull();
});

test("the operator's typed DM approve reaches the helper with the nonce and code on stdin, never in argv", async () => {
  const { deps, calls, replies } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh K7QF 123456"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF123456\n" }]);
  expect(calls[0].args.join(" ")).not.toContain("123456");
  expect(calls[0].args.join(" ")).not.toContain("K7QF");
  expect(replies[0]).toContain("approved; the result comes from the notice bot");
});

test("a ran approve is acknowledged without the helper's argv; a refusal shows its result line", async () => {
  const ran = fake();
  makeAfkSudoGate(ran.deps)(dm("approve abcdefgh K7QF 123456"));
  await settle();
  expect(ran.replies[0]).not.toContain("argv=");
  expect(ran.replies[0]).not.toContain("systemctl");
  const bad = fake();
  bad.deps.runHelper = async () => ({ code: 5, stdout: "result=bad-nonce id=abcdefgh\n" });
  makeAfkSudoGate(bad.deps)(dm("approve abcdefgh ZZZZ 123456"));
  await settle();
  expect(bad.replies[0]).toBe("⚠️ afk-sudo approve abcdefgh: result=bad-nonce id=abcdefgh");
});

test("an approve line with trailing words is consumed, so the code never reaches a session", async () => {
  const { deps, calls } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh K7QF 123456 please"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF123456please\n" }]);
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

test("handleInbound: with afk-sudo installed, an outside-PR approve whose prefix holds a six-digit run reaches routeApprove", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const accessFile = join(r, "access.json");
  writeFileSync(accessFile, JSON.stringify({ allowFrom: [String(OP)] }));
  const saved = process.env.TELEGRAM_ACCESS_PATH;
  process.env.TELEGRAM_ACCESS_PATH = accessFile;
  try {
    for (const prefix of ["a123456", "1234567", "abc123456def", "123456"]) {
      const { deps, calls, replies } = fake();
      const approveReplies: string[] = [];
      const ran: string[] = [];
      const consoleRoute = { authorize: (from: number, chat: number) => from === OP && chat === OP, reply: async (_chat: number, text: string) => { approveReplies.push(text); } };
      const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps) };
      await handleInbound(r, { ...dm(`approve 7 ${prefix}`), ts: Math.floor(Date.now() / 1000), message_id: 123 } as never, async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true, undefined, undefined, undefined, consoleRoute);
      await settle();
      expect(replies).toEqual([]);
      expect(calls).toEqual([]);
      expect(ran).toEqual([]);
      expect(approveReplies.join("\n")).toContain("⚠️ approve: reply to the outside-approve-request message from the bot");
    }
  } finally { if (saved === undefined) delete process.env.TELEGRAM_ACCESS_PATH; else process.env.TELEGRAM_ACCESS_PATH = saved; }
});

test("a real malformed afk-sudo id with a code still gets the afk-sudo reply and never reaches routeApprove", async () => {
  for (const text of ["approve abcdefg 123456", "approve abcdefghi K7QF 123456", "approve 7 K7QF 123456", "approve 7 a123456 please"]) {
    const { deps, calls, replies } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies[0]).toBe("⚠️ afk-sudo: the id is not 8 letters, nothing ran");
  }
});

test("a typed deny reaches the helper with the request's nonce on stdin, never in argv", async () => {
  const { deps, calls } = fake();
  expect(makeAfkSudoGate(deps)(dm("deny abcdefgh K7QF"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["deny", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF\n" }]);
});

test("a typed deny without the nonce, or with a code, never reaches the helper and says what to type", async () => {
  for (const text of ["deny abcdefgh", "deny abcdefgh K7QF 123456", "deny abcdefgh 123456"]) {
    const { deps, calls, replies } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies[0]).toContain("deny abcdefgh <nonce>");
    expect(replies[0]).not.toContain("123456");
  }
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
  await handleInbound(r, dm("approve abcdefgh K7QF 123456"), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
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
  for (const text of ["12345", "12345678", "text: 123456", "number 123456", "do 8276 8277 next", "ticket 123-456 is done"]) {
    expect(gate(dm(text))).toBe(false);
  }
});

test("a spaced or hyphenated six or seven digit code sent as a new message with no prompt is held, never forwarded", () => {
  for (const text of ["123 456", "123-456", " 12 34 56 ", "123 - 456", "1234 567", "123-4567", "1234567", "\t123\n456\n", "123‐456", "123‑456"]) {
    const { deps, calls, replies, logs } = fake();
    expect(makeAfkSudoGate(deps, makeAfkSudoPrompts())(dm(text))).toBe(true);
    expect(calls).toEqual([]);
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain("held");
    expect([...replies, ...logs].join("\n")).not.toContain("456");
  }
  // Fail closed only on what is wholly a code: words, other characters or a different digit count pass.
  for (const text of ["123 45", "123 456 78 9", "do 123 456", "123 456 ok", "text: 123456", "number 123456"]) {
    const { deps } = fake();
    expect(makeAfkSudoGate(deps, makeAfkSudoPrompts())(dm(text))).toBe(false);
  }
});

// Every shape below is an obviously fake code; each is held, never forwarded.
const held = (msg: ReturnType<typeof dm>) => {
  const { deps, calls, replies, logs } = fake();
  expect(makeAfkSudoGate(deps, makeAfkSudoPrompts())(msg)).toBe(true);
  expect(calls).toEqual([]);
  expect(replies).toHaveLength(1);
  expect(replies[0]).toContain("held");
  expect([...replies, ...logs].join("\n")).not.toContain("456");
};
const shapes: Record<string, string> = {
  dot: "123.456", underscore: "123_456", slash: "123/456", comma: "123,456", "en dash": "123–456", "em dash": "123—456",
  "minus sign": "123−456", "no-break space": "123 456", "em space": "123 456", "ideographic space": "123　456",
  "zero-width space": "123​456", "zero-width joiner": "123‍456", "word joiner": "123⁠456", "BOM": "123﻿456",
  "fullwidth digits": "１２３４５６", "fullwidth with space": "１２３ ４５６", "arabic-indic digits": "١٢٣٤٥٦",
  "extended arabic-indic digits": "۱۲۳۴۵۶", "trailing period": "123 456.", "trailing bang": "123456!", "leading and trailing": "(123 456)",
};
for (const [name, text] of Object.entries(shapes)) {
  test(`${name} code is held`, () => held(dm(text)));
}
test("a code sent as a caption is held", () => held(dm("123456", { caption: true })));
test("a forwarded code is held", () => held(dm("123456", { forwarded: true })));
test("a NONCE CODE pair as a reply to a message that is not the bot's, no prompt live, is held", () => {
  held(dm("K7QF 123456", { reply_to_message_id: 77, reply_to_bot: false }));
  held(dm("K7QF 123456.", { reply_to_message_id: 77 }));
});
test("controls stay ordinary text", () => {
  for (const text of ["ticket 123-456 is done", "do 8276 8277 next", "12345", "text: 123456", "number 123456.", "hello"]) {
    const { deps } = fake();
    expect(makeAfkSudoGate(deps, makeAfkSudoPrompts())(dm(text))).toBe(false);
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

function buttons(opts: { operator?: number | null; promptId?: number | null; promptIds?: number[]; allowFrom?: string[]; helper?: { code: number; stdout: string } } = {}) {
  const base = fake();
  if (opts.helper) base.deps.runHelper = async (args, stdin) => { base.calls.push({ args, stdin }); return opts.helper!; };
  if (opts.allowFrom) base.deps.access = () => ({ allowFrom: opts.allowFrom! });
  const sent: { chat: number; text: string }[] = [];
  const answers: string[] = [];
  let clock = 1_000_000;
  const deps: AfkSudoCallbackDeps = {
    ...base.deps,
    operatorId: () => (opts.operator === undefined ? OP : opts.operator),
    prompt: async (chat, text) => { sent.push({ chat, text }); return opts.promptIds?.shift() ?? (opts.promptId === undefined ? 77 : opts.promptId); },
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

test("button: an Approve tap asks for the nonce and code with a prompt and never reaches the helper", async () => {
  const b = buttons();
  expect(b.tap(tapOf("afk:approve:abcdefgh"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.sent).toEqual([{ chat: OP, text: "Approve abcdefgh: reply to this message with the 4-character nonce from the notice bot's message, then the 6-digit code (<nonce> <code>), not the request id. A wrong code with the right nonce ends the request; a wrong nonce leaves it pending." }]);
  expect(b.answers.length).toBe(1);
});

test("button: the nonce-and-code reply to that prompt approves with both on stdin, never in argv or logs", async () => {
  for (const text of ["K7QF 123456", " k7qf123 456 ", "K7QF 123-456"]) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(b.gate(reply(text, 77))).toBe(true);
    await settle();
    expect(b.calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: `${text.trim().slice(0, 4)} 123456\n` }]);
    expect([...b.replies, ...b.sent.map((s) => s.text), ...b.answers, ...b.logs].join("\n")).not.toContain("123456");
  }
});

test("button: a bare six-digit reply to the prompt (no nonce) never reaches the helper and keeps the prompt alive", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(reply("123456", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies.at(-1)).toContain("nonce");
  expect(b.gate(reply("K7QF 123456", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
});

test("button: a prompt is single use", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.gate(reply("K7QF 123456", 77));
  await settle();
  expect(b.gate(reply("K7QF 654321", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
  expect(b.replies.at(-1)).toContain("already used");
  expect([...b.replies, ...b.logs].join("\n")).not.toContain("654321");
});

test("two waiting requests get their own prompts and each reply approves its own id", async () => {
  const b = buttons({ promptIds: [77, 78] });
  b.tap(tapOf("afk:approve:aaaaaaaa"));
  b.tap(tapOf("afk:approve:bbbbbbbb"));
  await settle();
  expect(b.gate(reply("K7QF 123456", 78))).toBe(true);
  await settle();
  expect(b.gate(reply("M2PX 654321", 77))).toBe(true);
  await settle();
  expect(b.calls.map((c) => c.args[1])).toEqual(["bbbbbbbb", "aaaaaaaa"]);
  expect(b.calls.map((c) => c.stdin)).toEqual(["K7QF 123456\n", "M2PX 654321\n"]);
});

test("a code sent without replying while two prompts wait names both requests", async () => {
  const b = buttons({ promptIds: [77, 78] });
  b.tap(tapOf("afk:approve:aaaaaaaa"));
  b.tap(tapOf("afk:approve:bbbbbbbb"));
  await settle();
  expect(b.gate(dm("123456"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies.at(-1)).toContain("aaaaaaaa");
  expect(b.replies.at(-1)).toContain("bbbbbbbb");
});

test("button: a Deny tap asks for the nonce with a prompt and never reaches the helper", async () => {
  const b = buttons();
  expect(b.tap(tapOf("afk:deny:abcdefgh"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.sent).toEqual([{ chat: OP, text: "Deny abcdefgh: reply to this message with the 4-character nonce from the notice bot's message alone, no code. A wrong nonce leaves the request pending." }]);
  expect(b.answers).toEqual(["Reply with the nonce"]);
});

test("button: the nonce reply to a Deny prompt denies with the nonce on stdin, once", async () => {
  const b = buttons();
  b.tap(tapOf("afk:deny:abcdefgh"));
  await settle();
  expect(b.gate(reply(" k7qf ", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["deny", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "k7qf\n" }]);
  expect(b.gate(reply("K7QF", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
  expect(b.replies.at(-1)).toContain("tap Deny on it again");
});

test("button: a code or a nonce-and-code reply to a Deny prompt never reaches the helper and keeps the prompt alive", async () => {
  const b = buttons();
  b.tap(tapOf("afk:deny:abcdefgh"));
  await settle();
  for (const text of ["123456", "K7QF 123456"]) {
    expect(b.gate(reply(text, 77))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies.at(-1)).toContain("a deny takes only the");
    expect(b.replies.at(-1)).not.toContain("123456");
  }
  expect(b.gate(reply("K7QF", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
});

test("button: a waiting Deny prompt is not named as a code prompt", async () => {
  const b = buttons();
  b.tap(tapOf("afk:deny:abcdefgh"));
  await settle();
  expect(b.prompts.live(OP)).toEqual([]);
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

test("button: HIMMEL-8375 a code-only reply to a message that is not the bot's is held, not forwarded; other replies stay ordinary text", async () => {
  for (const text of ["123456", "123 456", "123-456"]) {
    const none = buttons();
    expect(none.gate(reply(text, 77))).toBe(true);
    expect(none.replies.at(-1)).toContain("held");
    expect([...none.replies, ...none.logs].join("\n")).not.toContain("456");
  }
  const b = buttons();
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
    expect(b.replies).toEqual(["⚠️ afk-sudo: that code prompt expired or is not known, nothing ran. If the request is still pending, tap Approve on it again; if it already ran or ended, nothing more is needed."]);
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
  for (const text of ["123456", "123 456", "123-456", "K7QF 123456"]) {
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
  for (const text of ["123456", "K7QF 123456", "k7qf123456"]) {
    const none = buttons();
    expect(none.gate(dm(text))).toBe(true);
    expect(none.replies.at(-1)).toContain("held");
  }
  const late = buttons();
  late.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  late.tick(151_000);
  expect(late.gate(dm("123456"))).toBe(true);
  expect(late.replies.at(-1)).toContain("held");
  const live = buttons();
  live.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  for (const msg of [dm("123456", { from: 999, chat_id: 999 }), dm("hello"), dm("42")]) {
    expect(live.gate(msg)).toBe(false);
  }
});

test("button: a code buried in words or punctuation is consumed while a prompt is live, and on a reply to a bot message when it is a standalone six-digit token", async () => {
  const texts = ["123456.", "code 123456", "123456 thanks", "approve 123456", "my code is 123 456, ok", "(123-456)"];
  for (const text of texts) {
    // a reply to a bot message with no known prompt is held for a contiguous six-digit token or a text that is wholly a code
    const gone = buttons();
    expect(gone.gate(reply(text, 99, { reply_to_bot: true }))).toBe(/(?<!\d)\d{6}(?!\d)/.test(text) || text === "(123-456)");
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
  expect(b.gate(dm("approve ijklmnop K7QF 123456"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "ijklmnop", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF123456\n" }]);
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
  expect(b.replies).toEqual(["⚠️ afk-sudo: that code prompt expired or is not known, nothing ran. If the request is still pending, tap Approve on it again; if it already ran or ended, nothing more is needed."]);
  expect(b.logs.join("\n")).not.toContain("123456");
  // other shapes of a reply to the bot stay ordinary text
  for (const msg of [reply("hello", 99, { reply_to_bot: true }), reply("123456", 99, { reply_to_bot: true, from: 999, chat_id: 999 })]) {
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

test("button: a reply that is not a nonce and six digits is consumed, tells the operator, and keeps the prompt alive", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  for (const t of ["12345", "1234567", "hello", "123 456 ok", "K7Q 123456", "K7QF 12345"]) {
    expect(b.gate(reply(t, 77))).toBe(true);
  }
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies.length).toBe(6);
  expect(b.gate(reply("K7QF 123456", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
});

test("button: a reply after the prompt window is consumed but never reaches the helper", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.tick(151_000);
  expect(b.gate(reply("K7QF 123456", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies[0]).toContain("expired");
  expect(b.gate(reply("K7QF 654321", 77))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
});

test("button: a reply that is forwarded, from another chat or from another sender never reaches the helper", async () => {
  for (const extra of [{ forwarded: true }, { from: 999, chat_id: 999 }, { chat_id: -100123 }]) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    b.gate(reply("K7QF 123456", 77, extra));
    await settle();
    expect(b.calls).toEqual([]);
  }
});

test("button: HIMMEL-8375 a spaced or hyphenated code replying to a live prompt is still answered by the prompt, never held", async () => {
  for (const text of ["123 456", "123-456"]) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(b.gate(reply(text, 77))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies.at(-1)).toContain("nonce");
    expect(b.replies.at(-1)).not.toContain("held");
  }
});

test("button: when the prompt cannot be sent nothing is remembered", async () => {
  const b = buttons({ promptId: null });
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.gate(reply("123456", 77))).toBe(true);
  expect(b.replies.at(-1)).toContain("held");
  expect(b.calls).toEqual([]);
});

test("button: the typed approve line keeps working beside the buttons", async () => {
  const b = buttons();
  expect(b.gate(dm("approve abcdefgh K7QF 123456"))).toBe(true);
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF123456\n" }]);
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

test("slice 4: the operator's typed /afk-lockdown reaches the helper with no argument but the sender and chat", async () => {
  for (const text of ["/afk-lockdown", "  /afk-lockdown  ", "/AFK-Lockdown", "/afk-lockdown@himmel_bot"]) {
    const { deps, calls, replies } = fake();
    deps.runHelper = async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=locked denied=abcdefgh\n" }; };
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([{ args: ["lockdown", "--from", String(OP), "--chat", String(OP)], stdin: "" }]);
    expect(replies).toEqual(["✅ afk-sudo lockdown: result=locked denied=abcdefgh"]);
  }
});

test("slice 4: /afk-lockdown with anything but a lockdown nonce after it never reaches the helper, so no argument can turn anything on", async () => {
  for (const text of ["/afk-lockdown --enable", "/afk-lockdown enable", "/afk-lockdown all", "/afk-lockdown\n--mode=all", "/afk-lockdown true", "/afk-lockdown K7QF2345 --enable", "/afk-lockdown K7QF-2345"]) {
    const { deps, calls, replies } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies[0]).toContain("takes nothing, or the 8-character lockdown nonce");
  }
});

test("lockdown: a bare /afk-lockdown says a nonce was sent and that nothing is off yet", async () => {
  const { deps, replies } = fake();
  deps.runHelper = async () => ({ code: 0, stdout: "result=lockdown-nonce-sent expires=1700000120\n" });
  makeAfkSudoGate(deps)(dm("/afk-lockdown"));
  await settle();
  expect(replies).toEqual(["✅ afk-sudo lockdown: nothing is switched off yet. The notice bot sent a lockdown nonce: send /afk-lockdown <that nonce> within 2 minutes."]);
});

test("lockdown: /afk-lockdown <nonce> reaches the helper with --with-nonce and the nonce on stdin, never in argv", async () => {
  for (const [text, nonce] of [["/afk-lockdown K7QF2345", "K7QF2345"], ["/afk-lockdown@himmel_bot  k7qf2345 ", "k7qf2345"]]) {
    const { deps, calls, replies } = fake();
    deps.runHelper = async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=locked denied=abcdefgh\n" }; };
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([{ args: ["lockdown", "--from", String(OP), "--chat", String(OP), "--with-nonce"], stdin: `${nonce}\n` }]);
    expect(calls[0].args.join(" ")).not.toContain(nonce);
    expect(replies).toEqual(["✅ afk-sudo lockdown: result=locked denied=abcdefgh"]);
  }
});

test("slice 4: /afk-lockdown from a forwarded message, a group or another sender is consumed and runs nothing", async () => {
  for (const extra of [{ forwarded: true }, { caption: true }, { from: 999, chat_id: 999 }, { chat_id: -100123 }]) {
    const { deps, calls, logs } = fake();
    expect(makeAfkSudoGate(deps)(dm("/afk-lockdown", extra))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(logs[0]).toContain("lockdown refused");
  }
});

test("slice 4: a refused lockdown shows the helper's result line", async () => {
  const { deps, replies } = fake();
  deps.runHelper = async () => ({ code: 5, stdout: "result=not-operator\n" });
  makeAfkSudoGate(deps)(dm("/afk-lockdown"));
  await settle();
  expect(replies).toEqual(["⚠️ afk-sudo lockdown: result=not-operator"]);
});

test("slice 4: with no installed helper /afk-lockdown is not consumed, and similar text is left alone", async () => {
  const off = fake(false);
  expect(makeAfkSudoGate(off.deps)(dm("/afk-lockdown"))).toBe(false);
  const on = fake();
  for (const text of ["/afk-lockdowns", "/afk-lockdown-now", "please /afk-lockdown", "afk-lockdown"]) {
    expect(makeAfkSudoGate(on.deps)(dm(text))).toBe(false);
  }
  await settle();
  expect(on.calls).toEqual([]);
});

test("slice 4: handleInbound consumes /afk-lockdown, so it never reaches an inbox or run", async () => {
  const r = mkdtempSync(join(tmpdir(), "afk-sudo-route-"));
  const { deps, calls } = fake();
  const ran: string[] = [];
  const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, afkSudo: makeAfkSudoGate(deps) };
  await handleInbound(r, dm("/afk-lockdown"), async (s) => { ran.push(s); }, auto, async () => ({ verdict: "spawn" }) as never, () => true);
  await settle();
  expect(calls.length).toBe(1);
  expect(ran).toEqual([]);
  expect(existsSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"))).toBe(false);
});

test("the operator's /op reaches the helper as op-request with the name and key=value words, quotes kept as one word", async () => {
  const { deps, calls, replies } = fake();
  deps.runHelper = async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=pending id=abcdefgh expires=1 operator=4242\n" }; };
  expect(makeAfkSudoGate(deps)(dm('/op cron-entry action=set tag=ping schedule="0 5 * * *" command=/usr/local/libexec/himmel/bin/open-session'))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["op-request", "--session", "telegram-op", "--ticket", "operator", "--", "cron-entry", "action=set", "tag=ping", "schedule=0 5 * * *", "command=/usr/local/libexec/himmel/bin/open-session"], stdin: "" }]);
  expect(replies).toEqual(["✅ afk-sudo op cron-entry: result=pending id=abcdefgh expires=1 operator=4242"]);
});

test("an /op ending in the operator's six-digit code files it with --proof and the code on stdin, never in argv", async () => {
  const { deps, calls, replies } = fake();
  deps.runHelper = async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=pending id=abcdefgh expires=1 operator=4242\n" }; };
  expect(makeAfkSudoGate(deps)(dm("/op size-approval key=HIMMEL-1 files=300 482913"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["op-request", "--session", "telegram-op", "--ticket", "operator", "--proof", "--", "size-approval", "key=HIMMEL-1", "files=300"], stdin: "482913\n" }]);
  expect(calls[0].args.join(" ")).not.toContain("482913");
  expect(replies.join("\n")).not.toContain("482913");
});

test("a lone six-digit word after /op is read as the op name, never as a code", async () => {
  const { deps, calls, replies } = fake();
  expect(makeAfkSudoGate(deps)(dm("/op 482913"))).toBe(true);
  await settle();
  expect(calls).toEqual([]);
  expect(replies[0]).toContain("op name");
});

test("a malformed /op line is refused before the helper, with the reason", async () => {
  for (const [text, why] of [["/op", "usage"], ["/op Bad_Name", "op name"], ["/op cron-entry tag", "not key=value"], ['/op cron-entry tag="a', "unbalanced"], ["/op cron-entry a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9", "too many"]] as const) {
    const { deps, calls, replies } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies[0]).toContain(why);
  }
});

test("/op from a forwarded message, a group or another sender is consumed and runs nothing; an uninstalled helper leaves it alone", async () => {
  for (const extra of [{ forwarded: true }, { caption: true }, { from: 999, chat_id: 999 }, { chat_id: -100123 }]) {
    const { deps, calls, logs } = fake();
    expect(makeAfkSudoGate(deps)(dm("/op system-update", extra))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(logs[0]).toContain("op refused");
  }
  expect(makeAfkSudoGate(fake(false).deps)(dm("/op system-update"))).toBe(false);
  const on = fake();
  for (const text of ["/ops system-update", "please /op system-update", "op system-update"]) expect(makeAfkSudoGate(on.deps)(dm(text))).toBe(false);
});

// --- the prompt and every refusal say what to type and why a reply was refused ---

const NONCE_HINT = "4-character nonce from the notice bot's message";

test("prompt: names the nonce and the notice bot, says the request id is not what to type and which wrong reply ends the request", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(b.sent).toEqual([{ chat: OP, text: `Approve abcdefgh: reply to this message with the ${NONCE_HINT}, then the 6-digit code (<nonce> <code>), not the request id. A wrong code with the right nonce ends the request; a wrong nonce leaves it pending.` }]);
});

test("refusal: a reply to the prompt names its cause per shape, runs no verb and keeps the prompt alive", async () => {
  const cases: [string, string][] = [
    ["123456", `⚠️ afk-sudo: that is the 6-digit code alone. Reply with the ${NONCE_HINT} first, then the code (<nonce> <code>). Nothing ran; the prompt still waits.`],
    ["abcdefgh 123456", `⚠️ afk-sudo: that holds the request id. Reply with only the ${NONCE_HINT} and the 6-digit code (<nonce> <code>). Nothing ran; the prompt still waits.`],
    ["K7QF abcdefgh 123456", `⚠️ afk-sudo: that holds the request id. Reply with only the ${NONCE_HINT} and the 6-digit code (<nonce> <code>). Nothing ran; the prompt still waits.`],
    ["hello", `⚠️ afk-sudo: could not read that as a nonce and a code. Reply with the ${NONCE_HINT}, then the 6-digit code (<nonce> <code>). Nothing ran; the prompt still waits.`],
  ];
  for (const [text, said] of cases) {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    expect(b.gate(reply(text, 77))).toBe(true);
    await settle();
    expect(b.calls).toEqual([]);
    expect(b.replies).toEqual([said]);
    expect([...b.replies, ...b.logs].join("\n")).not.toContain("123456");
    expect(b.gate(reply("K7QF 123456", 77))).toBe(true);
    await settle();
    expect(b.calls.length).toBe(1);
  }
});

test("refusal: a typed approve with the request id and a code, or the id twice, is refused before the helper", async () => {
  const cases: [string, string][] = [
    ["approve abcdefgh 123456", `⚠️ afk-sudo: approve needs the ${NONCE_HINT} before the code: approve abcdefgh <nonce> <code>. Nothing ran.`],
    ["approve abcdefgh abcdefgh 123456", `⚠️ afk-sudo: the request id is already in "approve abcdefgh"; after it send only the ${NONCE_HINT} and the code: approve abcdefgh <nonce> <code>. Nothing ran.`],
    ["approve abcdefgh K7QF abcdefgh 123456", `⚠️ afk-sudo: the request id is already in "approve abcdefgh"; after it send only the ${NONCE_HINT} and the code: approve abcdefgh <nonce> <code>. Nothing ran.`],
  ];
  for (const [text, said] of cases) {
    const { deps, calls, replies, logs } = fake();
    expect(makeAfkSudoGate(deps)(dm(text))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies).toEqual([said]);
    expect([...replies, ...logs].join("\n")).not.toContain("123456");
  }
});

test("plain message holding a nonce and code: never taken, the typed form is offered, no verb runs", async () => {
  const none = buttons();
  expect(none.gate(dm("K7QF 123456"))).toBe(true);
  await settle();
  expect(none.calls).toEqual([]);
  expect(none.replies).toEqual(['⚠️ afk-sudo: held a code-shaped message; nothing ran. To approve, in your private chat with this bot (never in a group) send "approve <request id> <nonce> <code>" as one message, or tap Approve on the request there and reply to that prompt. To send a number as text, prefix it with "text:".']);
  const one = buttons();
  one.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  expect(one.gate(dm("K7QF 123456"))).toBe(true);
  await settle();
  expect(one.calls).toEqual([]);
  expect(one.replies).toEqual(['⚠️ afk-sudo: a code sent as a plain message is not taken, nothing ran. Reply to the "Approve abcdefgh" prompt, or send: approve abcdefgh <nonce> <code>']);
  const two = buttons({ promptIds: [77, 78] });
  two.tap(tapOf("afk:approve:aaaaaaaa"));
  two.tap(tapOf("afk:approve:bbbbbbbb"));
  await settle();
  expect(two.gate(dm("K7QF 123456"))).toBe(true);
  await settle();
  expect(two.calls).toEqual([]);
  expect(two.replies).toEqual(['⚠️ afk-sudo: a code sent as a plain message is not taken, nothing ran. Reply to the "Approve aaaaaaaa" or "Approve bbbbbbbb" prompt, or send: approve <request id> <nonce> <code>']);
  for (const b of [none, one, two]) expect([...b.replies, ...b.logs].join("\n")).not.toContain("123456");
});

test("a nonce and code sent as a message in a group is held and the notice sends the operator to the private chat, never to the group", async () => {
  const b = buttons();
  const groupAccess = { ...access, groups: { "-100123": { trustAnonymousAdmins: true } } };
  const gate = makeAfkSudoGate({ ...b.deps, access: () => groupAccess }, b.prompts);
  expect(gate(dm("K7QF 123456", { chat_id: -100123, sender_chat: -100123 }))).toBe(true);
  expect(gate(dm("K7QF 123456", { from: GROUP_ANONYMOUS_BOT_ID, chat_id: -100123, sender_chat: -100123 }))).toBe(true);
  await settle();
  expect(b.calls).toEqual([]);
  expect(b.replies).toHaveLength(2);
  for (const r of b.replies) {
    expect(r).toContain("held");
    expect(r).toContain("in your private chat with this bot (never in a group)");
  }
});

test("a reply holding an ordinary 8-letter word is not taken for the request id; only this request's id is", async () => {
  const mk = async (text: string) => {
    const b = buttons();
    b.tap(tapOf("afk:approve:abcdefgh"));
    await settle();
    b.gate(reply(text, 77));
    await settle();
    expect(b.calls).toEqual([]);
    return b.replies[0];
  };
  expect(await mk("approved 123456")).toContain("could not read that as a nonce and a code");
  expect(await mk("approve abcdefgh")).toContain("that holds the request id");
  expect(await mk("ABCDEFGH 123456")).toContain("that holds the request id");
  const { deps, calls, replies } = fake();
  expect(makeAfkSudoGate(deps)(dm("approve abcdefgh K7QF approved 123456"))).toBe(true);
  await settle();
  expect(replies.filter((r) => r.includes("Nothing ran"))).toEqual([]);
  expect(calls).toHaveLength(1);
});

test("replay: a code from an already spent step says to wait for the next code; the used prompt says to tap Approve again", async () => {
  const b = buttons({ helper: { code: 5, stdout: "result=replay id=abcdefgh\n" } });
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.gate(reply("K7QF 123456", 77));
  await settle();
  expect(b.calls.length).toBe(1);
  expect(b.replies).toEqual(["⚠️ afk-sudo approve abcdefgh: that code was already used, so nothing ran and the request is still pending. Wait for the next code (it changes every 30 seconds), tap Approve again and reply with the nonce and the new code."]);
  expect(b.gate(reply("K7QF 654321", 77))).toBe(true);
  await settle();
  expect(b.calls.length).toBe(1);
  expect(b.replies.at(-1)).toBe("⚠️ afk-sudo: the prompt for abcdefgh was already used, nothing ran. If that request is still pending, tap Approve on it again for a new prompt; if it already ran or ended, nothing more is needed.");
  expect([...b.replies, ...b.logs].join("\n")).not.toMatch(/123456|654321/);
});

test("a valid reply to the prompt still runs the helper exactly once", async () => {
  const b = buttons();
  b.tap(tapOf("afk:approve:abcdefgh"));
  await settle();
  b.gate(reply("K7QF 123456", 77));
  b.gate(reply("K7QF 123456", 77));
  await settle();
  expect(b.calls).toEqual([{ args: ["approve", "abcdefgh", "--from", String(OP), "--chat", String(OP)], stdin: "K7QF 123456\n" }]);
  expect(b.replies.filter((r) => r.includes("approved"))).toHaveLength(1);
});
