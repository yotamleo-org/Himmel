import { expect, test } from "bun:test";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeAfkSudoGate, parseAfkSudo, type AfkSudoDeps } from "./afk-sudo-route";
import { GROUP_ANONYMOUS_BOT_ID } from "./gate";
import { handleInbound, type AutoGate } from "./poller";
import { sessionDir } from "./bus";

const OP = 4242;
const access = { allowFrom: [String(OP)] };

function fake(installed = true) {
  const calls: { args: string[]; stdin: string }[] = [];
  const replies: string[] = [];
  const deps: AfkSudoDeps = {
    access: () => access,
    installed: () => installed,
    runHelper: async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: "result=ran id=abcdefgh exit=0 argv=/usr/bin/systemctl restart x.service\n" }; },
    reply: async (_chat, text) => { replies.push(text); },
    log: () => {},
  };
  return { deps, calls, replies };
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
