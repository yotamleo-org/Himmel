import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain, readChain, submitSpool } from "./chain";
import type { Config } from "./config";
import { DRAFT_TTL_MS, MAX_DRAFTS_PER_DAY, MAX_PENDING_DRAFTS, REVIEW_MAX, badChars, draftState } from "./drafts";
import { notifyFile, renderNotify } from "./notify";
import { Poller, type PollerDeps, type TgLike } from "./poller";

const REPO = join(import.meta.dir, "..", "..");
const CHAT = -1001234567890, T0 = Date.UTC(2026, 10, 9, 12), OP = "4242";
const tmp = (p: string) => mkdtempSync(join(tmpdir(), p));

async function setup(over: { lockdown?: boolean } = {}) {
  const stateDir = tmp("drafts-state-"), configDir = tmp("drafts-conf-"), bridgeRoot = tmp("drafts-bridge-"), root = tmp("drafts-himmel-");
  mkdirSync(join(root, "scripts/lib"), { recursive: true });
  copyFileSync(join(REPO, "scripts/lib/redact.sh"), join(root, "scripts/lib/redact.sh"));
  writeFileSync(join(configDir, "hmac.key"), "k".repeat(32), { mode: 0o600 });
  const peerDir = join(stateDir, "example");
  mkdirSync(join(peerDir, "spool"), { recursive: true, mode: 0o700 });
  if (over.lockdown) writeFileSync(join(bridgeRoot, "lockdown"), "");
  const cfg: Config = {
    operatorBotId: "999000999", operatorChatId: Number(OP), bridgeRoot, himmelRoot: root, maxTextChars: 8000, addressing: "command",
    peers: { example: { peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], opens: ["question", "status", "info"], maxOpenThreads: 50, maxPerMinute: 50, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
      theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 50, maxPerMinute: 50, copiedAt: "2026-11-07" } } as any },
  };
  const c = { t: T0 };
  const sent: { text: string }[] = [];
  let mid = 9000;
  const tg: TgLike = { getUpdates: async () => [], getChatMember: async () => ({ user: { username: "ours_bot" } }), sendMessage: async (_c: number, text: string) => { sent.push({ text }); return { message_id: ++mid }; } };
  const deps: PollerDeps = { cfg, tg, ourBotId: "111000111", stateDir, configDir, clock: () => c.t, hostname: "testbox", log: () => {} };
  const poller = await Poller.create(deps);
  await poller.recover();
  return { poller, cfg, c, sent, stateDir, peerDir };
}
type Env = Awaited<ReturnType<typeof setup>>;
const result = (e: Env, name: string) => JSON.parse(readFileSync(join(e.peerDir, "spool", "results", name), "utf8"));
const outbox = (e: Env) => readChain(join(e.peerDir, "outbox.jsonl")) as Record<string, any>[];
const draft = async (e: Env, text: string, source: "send.ts" | "telegram" = "send.ts", kind = "info") => {
  const name = submitSpool(e.peerDir, { type: "draft", source, kind, text } as any);
  await e.poller.drainSpool();
  return result(e, name);
};
const tap = async (e: Env, id: string, verb: "ok" | "no" = "ok") => {
  const name = submitSpool(e.peerDir, { type: "tap", verb, draft: id, by: OP, ts: e.c.t });
  await e.poller.drainSpool();
  return result(e, name);
};
const states = (e: Env, id: string) => draftState(outbox(e), id);

test("only an intent with an approved draft id sends; replay and expiry send nothing", async () => {
  const e = await setup();
  const a = await draft(e, "hello one");
  expect(a.ok).toBe(true);
  expect(e.sent).toHaveLength(0);
  expect(states(e, a.draft)).toBe("PENDING");
  expect(await tap(e, a.draft)).toEqual({ ok: true, draft: a.draft });
  expect(e.sent).toHaveLength(1);
  expect(states(e, a.draft)).toBe("SENT");
  expect(await tap(e, a.draft)).toEqual({ ok: false, rule: "already-sent" });
  expect(e.sent).toHaveLength(1);

  const b = await draft(e, "hello two");
  e.c.t += DRAFT_TTL_MS + 1000;
  expect(await tap(e, b.draft)).toEqual({ ok: false, rule: "expired" });
  expect(states(e, b.draft)).toBe("EXPIRED");
  expect(await tap(e, b.draft)).toEqual({ ok: false, rule: "already-expired" });

  const c = await draft(e, "hello three");
  expect(await tap(e, c.draft, "no")).toEqual({ ok: true });
  expect(states(e, c.draft)).toBe("REJECTED");
  expect(await tap(e, c.draft)).toEqual({ ok: false, rule: "already-rejected" });
  expect(e.sent).toHaveLength(1);
  const sentIntents = outbox(e).filter(r => r.kind === "intent");
  expect(sentIntents).toHaveLength(1);
  expect(sentIntents[0].draft).toBe(a.draft);
});

test("a tap that is not from the operator, or names no draft, sends nothing", async () => {
  const e = await setup();
  const a = await draft(e, "hello");
  const name = submitSpool(e.peerDir, { type: "tap", verb: "ok", draft: a.draft, by: "777", ts: e.c.t });
  const unknown = submitSpool(e.peerDir, { type: "tap", verb: "ok", draft: "deadbeef", by: OP, ts: e.c.t });
  await e.poller.drainSpool();
  expect(result(e, name)).toEqual({ ok: false, rule: "not-operator" });
  expect(result(e, unknown)).toEqual({ ok: false, rule: "unknown-draft" });
  expect(e.sent).toHaveLength(0);
  expect(states(e, a.draft)).toBe("PENDING");
});

test("approve sends exactly the stored draft text; editing or replacing the spool file after drafting changes nothing sent", async () => {
  const e = await setup();
  const a = await draft(e, "the stored text");
  const spoolName = outbox(e).find(r => r.kind === "draft")!.spool;
  writeFileSync(join(e.peerDir, "spool", spoolName), JSON.stringify({ type: "draft", source: "send.ts", kind: "info", text: "REPLACED" }));
  submitSpool(e.peerDir, { type: "draft", source: "send.ts", kind: "info", text: "ANOTHER" });
  await tap(e, a.draft);
  expect(e.sent).toHaveLength(1);
  expect(e.sent[0].text.split("\n").slice(2).join("\n")).toBe("the stored text");
  expect(e.sent[0].text).not.toContain("REPLACED");
});

test("character and review-length refusals", async () => {
  const e = await setup();
  for (const bad of ["tab\there", "bidi ‮ mark", "zero​width"]) {
    expect(await draft(e, bad)).toEqual({ ok: false, rule: "characters" });
    expect(await draft(e, bad)).toEqual({ ok: false, rule: "characters" });
  }
  expect(badChars("two\nlines")).toBe(false);
  expect((await draft(e, "two\nlines")).ok).toBe(true);
  const big = await draft(e, "x".repeat(4050));
  expect(big).toMatchObject({ ok: false, rule: "review-length" });
  expect(outbox(e).filter(r => r.kind === "draft")).toHaveLength(1);
});

test("review length counts UTF-16 units; a pair at the boundary is refused whole", async () => {
  const e = await setup();
  const head = renderNotify({ kind: "notify", type: "draft", peer: "example", ts: 0, root: 0, draft: "00000000", source: "send.ts", deadline: e.c.t + DRAFT_TTL_MS, text: "" }, e.cfg.himmelRoot).text.length;
  const room = REVIEW_MAX - head;
  expect((await draft(e, "y".repeat(room))).ok).toBe(true);
  expect(await draft(e, "y".repeat(room - 1) + "😀")).toMatchObject({ ok: false, rule: "review-length" });
  expect(await draft(e, "😀".repeat(room / 2 + 1))).toMatchObject({ ok: false, rule: "review-length" });
  expect(outbox(e).filter(r => r.kind === "draft")).toHaveLength(1);
});

test("a 4th PENDING and a 21st draft in a UTC day are refused", async () => {
  const e = await setup();
  const ids: string[] = [];
  for (let i = 0; i < MAX_PENDING_DRAFTS; i++) ids.push((await draft(e, `d${i}`)).draft);
  expect(await draft(e, "fourth")).toEqual({ ok: false, rule: "too-many-pending" });
  for (const id of ids) await tap(e, id, "no");
  for (let i = MAX_PENDING_DRAFTS; i < MAX_DRAFTS_PER_DAY; i++) await tap(e, (await draft(e, `d${i}`)).draft, "no");
  expect(outbox(e).filter(r => r.kind === "draft")).toHaveLength(MAX_DRAFTS_PER_DAY);
  expect(await draft(e, "twenty-first")).toEqual({ ok: false, rule: "daily-drafts" });
  e.c.t += 86_400_000;
  expect((await draft(e, "next day")).ok).toBe(true);
});

test("a refused telegram draft writes a REFUSED result notify; a refused send.ts draft writes none", async () => {
  const e = await setup();
  const notes = () => (readChain(notifyFile(e.stateDir)) as Record<string, any>[]).filter(r => r.type === "result");
  expect(await draft(e, "tab\there", "send.ts")).toMatchObject({ ok: false });
  expect(notes()).toHaveLength(0);
  expect(await draft(e, "tab\there", "telegram")).toMatchObject({ ok: false, rule: "characters" });
  expect(notes()).toHaveLength(1);
  expect(notes()[0]).toMatchObject({ state: "REFUSED", rule: "characters" });
});

test("approval under lockdown sends nothing", async () => {
  const e = await setup();
  const a = await draft(e, "hello");
  writeFileSync(join(e.cfg.bridgeRoot, "lockdown"), "");
  expect(await tap(e, a.draft)).toEqual({ ok: false, rule: "lockdown" });
  expect(e.sent).toHaveLength(0);
  expect(states(e, a.draft)).toBe("REFUSED");
});

test("recovery re-derives the corpus from the intent's source", async () => {
  const onlyDesk = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "t" }] };
  const e = await setup();
  const a = await draft(e, "from send", "send.ts");
  const b = await draft(e, "from telegram", "telegram");
  const intent = (id: string, text: string, source: string) => new Chain().append(join(e.peerDir, "outbox.jsonl"), { kind: "intent", peer: "example", chat: CHAT, id, root: null, msgKind: "info", text, isRoot: true, draft: id, by: OP, source });
  await intent(a.draft, "from send", "send.ts");
  await intent(b.draft, "from telegram", "telegram");
  const again = await Poller.create({ ...(e.poller as any).deps, matrix: onlyDesk });
  await again.recover();
  expect(e.sent).toHaveLength(1);
  expect(e.sent[0].text).toContain("id=" + a.draft);
  expect(states(e, b.draft)).toBe("REFUSED");
});

test("approval re-derives the corpus from source", async () => {
  const e = await setup();
  const a = await draft(e, "from send", "send.ts");
  const b = await draft(e, "from telegram", "telegram");
  const onlyDesk = { default: "deny", rules: [{ corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "t" }] };
  (e.poller as any).deps.matrix = onlyDesk;
  expect(await tap(e, b.draft)).toEqual({ ok: false, rule: "egress-matrix" });
  expect(states(e, b.draft)).toBe("REFUSED");
  expect(await tap(e, a.draft)).toEqual({ ok: true, draft: a.draft });
  expect(e.sent).toHaveLength(1);
});
