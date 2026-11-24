import { afterEach, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { verify, type Check } from "./operator-words";

const FIX = join(import.meta.dir, "fixtures", "operator-words");
const ACCESS = join(FIX, "access.json");
const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });

function scratch(): string {
  const d = mkdtempSync(join(tmpdir(), "operator-words-"));
  dirs.push(d);
  return d;
}
function rootWithFixtureLog(): string {
  const d = scratch();
  copyFileSync(join(FIX, "inbound.jsonl"), join(d, "inbound.jsonl"));
  return d;
}
function accessFile(body: unknown): string {
  const p = join(scratch(), "access.json");
  writeFileSync(p, JSON.stringify(body));
  return p;
}
const refusal = async (id: number, o: Parameters<typeof verify>[1]): Promise<string> => {
  try { await verify(id, o); } catch (e) { return (e as Error).message; }
  return "NO REFUSAL";
};

test("T6: the operator's own DM line comes back with its text byte-equal", async () => {
  const got = await verify(900000001, { root: rootWithFixtureLog(), accessPath: ACCESS });
  expect(got).toEqual({
    update_id: 900000001, from: 111, chat_id: 111, ts: 1762817400, message_id: 71,
    text: "File it and give it to the chief for 1.1.3 as well, it is the lost-line bug",
  });
});

test("T6: a line with reply_to_text carries it, and the text stays the operator's alone", async () => {
  const got = await verify(900000010, { root: rootWithFixtureLog(), accessPath: ACCESS });
  expect(got.text).toBe("file it into 1.1.3");
  expect(got.reply_to_text).toBe("Want me to file it into 1.1.3?");
});

test("T6: a line a log rotation moved to inbound.jsonl.1 is found; a garbage line is skipped", async () => {
  const d = scratch();
  const line = JSON.stringify({ update_id: 900000100, from: 111, chat_id: 111, text: "older line", ts: 5, message_id: 1, forwarded: false, caption: false });
  writeFileSync(join(d, "inbound.jsonl.1"), `not json at all\n${line}\n`);
  writeFileSync(join(d, "inbound.jsonl"), "{broken\n");
  expect((await verify(900000100, { root: d, accessPath: ACCESS })).text).toBe("older line");
});

test("T6: the same line logged twice is not ambiguous", async () => {
  const d = scratch();
  const line = JSON.stringify({ update_id: 900000100, from: 111, chat_id: 111, text: "twice", ts: 5, message_id: 1, forwarded: false, caption: false });
  writeFileSync(join(d, "inbound.jsonl"), `${line}\n${line}\n`);
  expect((await verify(900000100, { root: d, accessPath: ACCESS })).text).toBe("twice");
});

const rows: { name: string; id: number; reason: string; check: Check }[] = [
  { name: "forwarded", id: 900000002, reason: "update 900000002 is forwarded", check: "forwarded" },
  { name: "caption or voice transcript", id: 900000003, reason: "update 900000003 is a caption or a voice transcript", check: "caption" },
  { name: "another sender", id: 900000004, reason: "update 900000004 is not the operator's DM", check: "operator" },
  { name: "the operator in a group chat", id: 900000005, reason: "update 900000005 is not the operator's DM", check: "operator" },
  { name: "an id below the floor", id: 42, reason: "update 42 is below the update-id floor", check: "floor" },
];

for (const r of rows) {
  test(`T6b: ${r.name} refuses with its own reason, and the same row passes with that one check disabled`, async () => {
    const root = rootWithFixtureLog();
    expect(await refusal(r.id, { root, accessPath: ACCESS })).toBe(r.reason);
    expect((await verify(r.id, { root, accessPath: ACCESS, disable: [r.check] })).update_id).toBe(r.id);
  });
}

test("T6b: an id that is not in the log refuses", async () => {
  expect(await refusal(900000999, { root: rootWithFixtureLog(), accessPath: ACCESS })).toBe("update 900000999 is not in the poller's log");
});

test("T6b: a missing log refuses as not in the log", async () => {
  expect(await refusal(900000001, { root: scratch(), accessPath: ACCESS })).toBe("update 900000001 is not in the poller's log");
});

test("T6b: two lines with one update_id and different text or ts refuse as ambiguous; disabled, the first is used", async () => {
  const d = scratch();
  const a = { update_id: 900000100, from: 111, chat_id: 111, text: "one", ts: 5, message_id: 1, forwarded: false, caption: false };
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify(a)}\n${JSON.stringify({ ...a, text: "two" })}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is ambiguous");
  expect((await verify(900000100, { root: d, accessPath: ACCESS, disable: ["ambiguous"] })).text).toBe("one");
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify(a)}\n${JSON.stringify({ ...a, ts: 6 })}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is ambiguous");
});

test("T6b: two lines with one update_id that differ in sender, chat, flags or message id refuse as ambiguous", async () => {
  const d = scratch();
  const a = { update_id: 900000100, from: 111, chat_id: 111, text: "one", ts: 5, message_id: 1, forwarded: false, caption: false };
  for (const change of [{ from: 222 }, { chat_id: -100500 }, { forwarded: true }, { caption: true }, { message_id: 2 }]) {
    writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify(a)}\n${JSON.stringify({ ...a, ...change })}\n`);
    expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is ambiguous");
  }
});

test("T6b: a log file that exists but cannot be read refuses, even when the other file holds the line", async () => {
  const d = scratch();
  const line = JSON.stringify({ update_id: 900000100, from: 111, chat_id: 111, text: "hello", ts: 5, message_id: 1, forwarded: false, caption: false });
  writeFileSync(join(d, "inbound.jsonl"), `${line}\n`);
  mkdirSync(join(d, "inbound.jsonl.1"));
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100: the poller's log cannot be read");
});

test("T6b: a ts or message_id that is missing or not a number refuses; disabled, the line passes", async () => {
  const d = scratch();
  const base = { update_id: 900000100, from: 111, chat_id: 111, text: "hello", forwarded: false, caption: false };
  for (const bad of [{ message_id: 1 }, { ts: 5 }, { ts: "5", message_id: 1 }, { ts: 5, message_id: "1" }]) {
    writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify({ ...base, ...bad })}\n`);
    expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 has no timestamp or message id");
  }
  expect((await verify(900000100, { root: d, accessPath: ACCESS, disable: ["metadata"] })).text).toBe("hello");
});

test("T6b: an access file with two allowFrom ids refuses 900000001; disabled, it passes", async () => {
  const root = rootWithFixtureLog();
  const accessPath = accessFile({ dmPolicy: "allowlist", allowFrom: ["111", "222"] });
  expect(await refusal(900000001, { root, accessPath })).toBe("the bridge's DMs are not limited to the operator");
  expect((await verify(900000001, { root, accessPath, disable: ["dm-policy"] })).update_id).toBe(900000001);
});

test.each([
  ["a dmPolicy that is not allowlist", { dmPolicy: "open", allowFrom: ["111"] }],
  ["an empty allowFrom", { dmPolicy: "allowlist", allowFrom: [] }],
  ["an allowFrom that is a bare string", { dmPolicy: "allowlist", allowFrom: "111" }],
  ["a negative allowFrom id", { dmPolicy: "allowlist", allowFrom: ["-100500"] }],
  ["no dmPolicy", { allowFrom: ["111"] }],
])("T6b: %s refuses", async (_n, body) => {
  expect(await refusal(900000001, { root: rootWithFixtureLog(), accessPath: accessFile(body) })).toBe("the bridge's DMs are not limited to the operator");
});

test("T6b: an unreadable access file refuses", async () => {
  expect(await refusal(900000001, { root: rootWithFixtureLog(), accessPath: join(scratch(), "nope.json") })).toBe("the bridge's DMs are not limited to the operator");
});

test("T6b: a text that is empty after trim refuses; disabled, it passes", async () => {
  const d = scratch();
  const rec = { update_id: 900000100, from: 111, chat_id: 111, text: "   \n ", ts: 5, message_id: 1, forwarded: false, caption: false };
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify(rec)}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 has no text");
  expect((await verify(900000100, { root: d, accessPath: ACCESS, disable: ["text"] })).text).toBe("   \n ");
});

test("T6b: forwarded and caption must be exactly false, a missing field refuses", async () => {
  const d = scratch();
  const base = { update_id: 900000100, from: 111, chat_id: 111, text: "hello", ts: 5, message_id: 1 };
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify({ ...base, caption: false })}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is forwarded");
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify({ ...base, forwarded: false })}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is a caption or a voice transcript");
});

test("T6b: from and chat_id must be numbers equal to the operator id, not strings", async () => {
  const d = scratch();
  const rec = { update_id: 900000100, from: "111", chat_id: "111", text: "hello", ts: 5, message_id: 1, forwarded: false, caption: false };
  writeFileSync(join(d, "inbound.jsonl"), `${JSON.stringify(rec)}\n`);
  expect(await refusal(900000100, { root: d, accessPath: ACCESS })).toBe("update 900000100 is not the operator's DM");
});

test("T6b: an update_id that is not a safe integer refuses at the floor", async () => {
  expect(await refusal(NaN, { root: rootWithFixtureLog(), accessPath: ACCESS })).toBe("update NaN is below the update-id floor");
  expect(await refusal(1.5e6 + 0.5, { root: rootWithFixtureLog(), accessPath: ACCESS })).toBe("update 1500000.5 is below the update-id floor");
});
