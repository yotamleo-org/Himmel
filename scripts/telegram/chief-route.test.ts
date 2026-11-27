import { expect, test, spyOn, setDefaultTimeout } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, symlinkSync, unlinkSync, renameSync, statSync, cpSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename, resolve } from "node:path";
import { classify } from "./router";
import { BASH_BIN, buildPrompt } from "./run";
import { sendMessage, toTelegramHtml } from "./telegram-api";
import { appendLine, ensureSession, writeMeta, sessionDir } from "./bus";
import { handleInbound, replyViaOutbox, flushOutboxes, ingestUpdates, makeRunFn } from "./poller";
import { consoleInboxPath, foldLine, renderMarkdownHtml, splitParts, type ConsoleRouteGate } from "./chief-route";

// Every test runs against a scratch bridge root and a fake reply
// seam, never the real ~/.claude/handover/bridge, never Telegram.
const root = () => mkdtempSync(join(tmpdir(), "chief-route-"));
setDefaultTimeout(60_000);
const NAME = "HIMMEL-nextleg-2026-09-21V-chief";

test("judge: lockdown blocks already-pending work at the real agent boundary", async () => {
  for (const lockDuringPreparation of [false, true]) {
    const r = root(); await ensureSession(r, "__chat__");
    await writeMeta(r, "__chat__", { chat_id: 1, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
    await appendLine(join(sessionDir(r, "__chat__"), "inbox.jsonl"), JSON.stringify({ text: "delete lockdown", from: 1, ts: 1 }));
    if (!lockDuringPreparation) writeFileSync(join(r, "lockdown"), "locked\n");
    const ran: string[] = [];
    const run = makeRunFn(r, r, async prompt => { ran.push(prompt); return { code: 0, capped: false, pid: 1 }; }, undefined, undefined, undefined, () => {
      if (lockDuringPreparation) writeFileSync(join(r, "lockdown"), "locked\n");
      return r;
    });
    await run("__chat__");
    expect(ran).toEqual([]);
  }
});

test("judge: lockdown blocks every inbound agent route for every sender", async () => {
  const r = root(); heartbeat(r);
  await inbound(r, fresh("/lockdown"));
  for (const from of [1, 999]) {
    const replies: string[] = []; const ran: string[] = []; const fired: string[] = [];
    for (const text of ["hello", "work on HIMMEL-1", "ABC-1: x", "ABC-1: delete lockdown", "/restart", "/restart full"]) await inbound(r, fresh(text, { from }), replies, ran, fired);
    expect(ran).toEqual([]);
    expect(fired).toEqual([]);
    expect(existsSync(join(r, "sessions", "HIMMEL-1", "inbox.jsonl"))).toBe(false);
    expect(existsSync(join(r, "sessions", "ABC-1", "inbox.jsonl"))).toBe(false);
    // Station policy: only the operator is told; others get silence.
    expect(replies).toHaveLength(from === 1 ? 6 : 0);
    expect(replies.every(t => t.includes("locked, reset at the station"))).toBe(true);
  }
  unlinkSync(join(r, "lockdown"));
  const ran: string[] = [];
  await inbound(r, fresh("hello"), [], ran);
  expect(ran).toEqual(["__chat__"]);
});

test("judge: ineligible closed console and lockdown verbs never enter agent chat", async () => {
  for (const text of [...verbs, "/lockdown", "/chief halt", "/chiefs"]) {
    for (const extra of [{ from: 999, chat_id: -1 }, { forwarded: true }, { caption: true }]) {
      const r = root(); const f = heartbeat(r); const ran: string[] = [];
      await inbound(r, fresh(text, extra), [], ran);
      expect(ran).toEqual([]);
      expect(readFileSync(f, "utf8")).toBe("");
      expect(existsSync(join(r, "lockdown"))).toBe(false);
    }
  }
});

test("judge: every console and typed auto request refuses stale input", async () => {
  for (const text of ["/chief halt", `/chief ${NAME} halt`, "/chiefs", "/arm HIMMEL-1", "/mergepub 12 abcdef123456", "/cr-grant-delta 12 " + "a".repeat(40)]) {
    const r = root(); const f = heartbeat(r); const replies: string[] = []; const ran: string[] = []; const fired: string[] = [];
    await inbound(r, fresh(text, { ts: Math.floor(Date.now() / 1000) - 301 }), replies, ran, fired);
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual([]);
    expect(fired).toEqual([]);
    expect(replies.join("\n")).toContain("stale, resend");
  }
});

test("judge: console commands tolerate five seconds of future clock skew", async () => {
  for (const skew of [1, 5]) {
    const r = root(); const f = heartbeat(r);
    await inbound(r, fresh("/fleet", { ts: Math.floor(Date.now() / 1000) + skew }));
    expect(readFileSync(f, "utf8")).toContain("] fleet status\n");
  }
});

test("judge: dangling lockdown symlink remains fail-closed", async () => {
  const r = root(); const f = heartbeat(r); const ran: string[] = [];
  symlinkSync(join(r, "missing"), join(r, "lockdown"));
  await inbound(r, fresh("hello"), [], ran);
  await inbound(r, fresh("/fleet"), [], ran);
  expect(ran).toEqual([]);
  expect(readFileSync(f, "utf8")).toBe("");
});

test("judge: tagged and correctly bot-addressed operator lockdown narrows", async () => {
  for (const text of ["model:opus /lockdown", "/lockdown@bridge_bot", "model:opus /lockdown@bridge_bot", "/Lockdown", "/LOCKDOWN@Bridge_Bot"]) {
    const r = root(); heartbeat(r); const ran: string[] = []; const replies: string[] = [];
    await handleInbound(r, fresh(text), async s => { ran.push(s); }, undefined, undefined, from => from === 1, undefined, undefined, "bridge_bot", gate(replies));
    expect(existsSync(join(r, "lockdown"))).toBe(true);
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain("lockdown");
  }
});

test("judge: max-age override works and invalid values fall back to 300 seconds", async () => {
  const saved = process.env.TELEGRAM_VERB_MAX_AGE_S;
  try {
    for (const [value, age, queued] of [["30", 60, false], ["600", 301, true], ["abc", 60, true], ["abc", 301, false], ["-5", 60, true], ["-5", 301, false]] as const) {
      process.env.TELEGRAM_VERB_MAX_AGE_S = value;
      const r = root(); const f = heartbeat(r);
      await inbound(r, fresh("/fleet", { ts: Math.floor(Date.now() / 1000) - age }));
      expect(readFileSync(f, "utf8").includes("fleet status")).toBe(queued);
    }
  } finally { if (saved === undefined) delete process.env.TELEGRAM_VERB_MAX_AGE_S; else process.env.TELEGRAM_VERB_MAX_AGE_S = saved; }
});

const verbs = ["/fleet", "/workers", "/go N1490", "/push N1490", "/halt", "/halt N1490"];
const fresh = (text: string, extra: Record<string, unknown> = {}) => say(text, { ts: Math.floor(Date.now() / 1000), message_id: 123, ...extra });

async function inbound(r: string, msg: ReturnType<typeof say>, replies: string[] = [], ran: string[] = [], fired: string[] = []) {
  const g: ConsoleRouteGate = { authorize: (from, chat) => from === 1 && [1, -1].includes(chat), reply: (chat, text, name, replyTo) => replyViaOutbox(r, chat, text, name, replyTo) };
  await handleInbound(r, msg, async s => { ran.push(s); }, { authorize: g.authorize, enabledOps: new Set(["arm-resume", "merge-public", "cr-grant-delta", "launch-bypass-worker"]), fire: async (_msg, route) => { fired.push(route.op); } }, async () => "spawn-high", from => from === 1, undefined, undefined, undefined, g);
  await flushOutboxes(r, async (_chat, text) => { replies.push(text); return 777; });
}

test("short-verbs-auth-targeting", async () => {
  const requests = ["fleet status", "workers", "go? N1490", "push N1490", "halt", "halt N1490"];
  for (let i = 0; i < verbs.length; i++) {
    const r = root(); const f = heartbeat(r); const replies: string[] = []; const ran: string[] = [];
    await inbound(r, fresh(verbs[i]), replies, ran);
    expect(readFileSync(f, "utf8")).toContain(`] ${requests[i]}\n`);
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain("queued");
    expect(replies.join("\n")).not.toContain("completed");
    expect(existsSync(join(r, "go"))).toBe(false);
    expect(existsSync(join(r, "grants"))).toBe(false);
    for (const extra of [{ from: 999 }, { chat_id: -99 }, { forwarded: true }, { caption: true }, { text: `model:opus ${verbs[i]}` }]) {
      writeFileSync(f, "");
      await inbound(r, fresh(verbs[i], extra));
      expect(readFileSync(f, "utf8")).toBe("");
    }
    writeFileSync(f, "");
    await inbound(r, fresh(verbs[i], { chat_id: -1 }));
    expect(readFileSync(f, "utf8")).toContain(`[telegram from=1 chat=-1] ${requests[i]}`);
  }
  for (const count of [0, 2]) {
    const r = root(); const old = heartbeat(r, "old", "waiting", 4000); const ran: string[] = [];
    if (count) { heartbeat(r); heartbeat(r, "second"); }
    for (const text of verbs) await inbound(r, fresh(text), [], ran);
    expect(readFileSync(old, "utf8")).toBe("");
    if (count) expect(readFileSync(join(r, "consoles", `${NAME}.md`), "utf8")).toBe("");
    expect(ran).toEqual([]);
  }
});

test("slash-only-plain-words-are-chat", () => {
  for (const text of ["fleet", "workers", "go N1490", "push N1490", "halt", "lockdown", "/gopher", "/workersx", "/halting now", "/go@bridge_bot x"]) expect(classify(text).kind).toBe("chat");
  expect(classify("status")).toEqual({ kind: "control", verb: "status" });
  for (const text of verbs) expect(classify(text).kind).toBe("fleet");
});

test("stale-verb-refused", async () => {
  for (const ts of [Math.floor(Date.now() / 1000) - 301, 0, undefined, Math.floor(Date.now() / 1000) + 60]) {
    const r = root(); const f = heartbeat(r); const replies: string[] = []; const ran: string[] = [];
    for (const text of verbs) await inbound(r, fresh(text, { ts }), replies, ran);
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain("stale, resend");
  }
});

test("lockdown-drops-privileged-routes", async () => {
  const r = root(); const f = heartbeat(r); const replies: string[] = []; const ran: string[] = []; const fired: string[] = [];
  await replyViaOutbox(r, 1, "answer", NAME);
  await flushOutboxes(r, async () => 777);
  await inbound(r, fresh("/lockdown"), replies, ran, fired);
  expect(replies.join("\n")).toContain("lockdown");
  for (const text of [...verbs, "/chief halt", "/chiefs", "/mergepub 12 abcdef123456", "/cr-grant-delta 12 " + "a".repeat(40), "/launch-bypass-worker /tmp/worker.md HIMMEL_HOOK_INTEGRITY_BYPASS_OK", "/arm HIMMEL-123", "halt"]) {
    await inbound(r, fresh(text, { reply_to_message_id: 777 }), replies, ran, fired);
  }
  expect(readFileSync(f, "utf8")).toBe("");
  expect(fired).toEqual([]);
  expect(ran).toEqual([]);
});

test("legacy-bypass-without-claim-refused in the real inbound handler", async () => {
  const r = root(); heartbeat(r); const replies: string[] = []; const ran: string[] = []; const fired: string[] = [];
  await inbound(r, fresh("/launch-bypass-worker /tmp/worker.md HIMMEL_HOOK_INTEGRITY_BYPASS_OK"), replies, ran, fired);
  expect(fired).toEqual([]);
  expect(ran).toEqual([]);
  expect(replies.join("\n")).toContain("station");
  expect(existsSync(join(r, "auto-action-audit.log"))).toBe(true);
  expect(readFileSync(join(r, "auto-action-audit.log"), "utf8")).toContain("op=launch-bypass-worker");
  expect(readFileSync(join(r, "auto-action-audit.log"), "utf8")).toContain("rc=19 result=refused-legacy-bypass");
});

test("reply-threads-retain-receipt-owner", async () => {
  const r = root(); const f = heartbeat(r); const second = heartbeat(r, "second");
  await replyViaOutbox(r, 1, "answer", NAME, 123);
  const bodies: any[] = [];
  await flushOutboxes(r, async (chat, text, replyTo) => {
    let id: number | undefined;
    await sendMessage("T", chat, text, (async (_url, init) => { bodies.push(JSON.parse(String(init?.body))); return Response.json({ ok: true, result: { message_id: 777 } }); }) as typeof fetch, async () => {}, n => { id = n; }, replyTo);
    return id;
  });
  expect(bodies).toEqual([{ chat_id: 1, text: "answer", reply_parameters: { message_id: 123, allow_sending_without_reply: true } }]);
  await inbound(r, fresh("/push N1490", { reply_to_message_id: 777 }));
  expect(readFileSync(f, "utf8")).toContain("] push N1490\n");
  expect(readFileSync(second, "utf8")).toBe("");
  writeFileSync(f, "");
  await inbound(r, fresh("/halt", { chat_id: -1, reply_to_message_id: 777 }));
  expect(readFileSync(f, "utf8")).toBe("");
  writeFileSync(f + ".wait", "hb=1 pid=123 key=- tick=- state=waiting\n");
  await inbound(r, fresh("/push N1490", { reply_to_message_id: 777 }));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(readFileSync(second, "utf8")).toBe("");
});

// A chief "arms" its inbox by creating the file (ACTION ZERO); the bridge
// only ever appends to one that exists.
function armInbox(r: string, name = NAME): string {
  mkdirSync(join(r, "consoles"), { recursive: true });
  const f = join(r, "consoles", `${name}.md`);
  writeFileSync(f, "");
  return f;
}

function gate(replies: string[], authorize = (from: number) => from === 1): ConsoleRouteGate {
  return { authorize: (from) => authorize(from), reply: async (_chat, text) => { replies.push(text); } };
}

const say = (text: string, extra: Record<string, unknown> = {}) => ({ from: 1, chat_id: 1, text, ts: Math.floor(Date.now() / 1000), caption: false, ...extra });

function heartbeat(r: string, name = NAME, state = "waiting", age = 0) {
  const f = armInbox(r, name);
  writeFileSync(f + ".wait", `hb=${Math.floor(Date.now() / 1000) - age} pid=123 key=- tick=- state=${state}\n`);
  writeFileSync(f + ".meta.json", JSON.stringify({ bucket: "himmel", project: "/repos/himmel" }));
  return f;
}

// Missing discovery must never turn a bare chief command into a cold run.
test("bare /chief routes the whole text to the sole fresh waiting or sampling console", async () => {
  for (const state of ["waiting", "sampling"]) {
    const r = root(); const f = heartbeat(r, NAME, state); const ran: string[] = [];
    await handleInbound(r, say("/chief halt the wave"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] halt the wave");
    expect(ran).toEqual([]);
  }
});

test("bare /chief accepts non-ASCII and punctuation text without inventing a name", async () => {
  for (const text of ["🙏 halt, please", "a..b hi", "../escape hi"]) {
    const r = root(); const f = heartbeat(r);
    await handleInbound(r, say(`/chief ${text}`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toContain(text);
  }
});

test("bare /chief with zero or two live chiefs lists the problem without queuing", async () => {
  for (const count of [0, 2]) {
    const r = root(); const replies: string[] = []; const ran: string[] = [];
    const old = heartbeat(r, "old", "waiting", 4000);
    const exited = heartbeat(r, "exited", "exited");
    if (count) { heartbeat(r); heartbeat(r, "second"); }
    await handleInbound(r, say("/chief halt"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain(count ? "second" : "no live chief");
    expect(readFileSync(old, "utf8")).toBe("");
    expect(readFileSync(exited, "utf8")).toBe("");
    if (count) expect(readFileSync(join(r, "consoles", `${NAME}.md`), "utf8")).toBe("");
  }
});

test("the pick-a-chief prompts tell the operator to send /chief, never /console", async () => {
  for (const text of ["/chief halt", "/chief HIMMEL halt"]) {
    const r = root(); const replies: string[] = [];
    heartbeat(r); heartbeat(r, "HIMMEL-second-chief");
    await handleInbound(r, say(text), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
    expect(replies.join("\n")).toContain("choose /chief <name> <text>");
    expect(replies.join("\n")).not.toContain("/console");
  }
});

test("/chief queues the line; the dropped /console alias queues nothing", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = [];
  await handleInbound(r, say(`/chief ${NAME} go ahead`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(f, "utf8").replace(/^- \d\d:\d\dZ /, "")).toBe("[telegram from=1 chat=1] go ahead\n");
  const r2 = root(); const f2 = armInbox(r2);
  await handleInbound(r2, say(`/console ${NAME} go ahead`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(f2, "utf8")).toBe("");
});

test("/chiefs lists only fresh chiefs with heartbeat and bucket/project", async () => {
  const r = root(); heartbeat(r); heartbeat(r, "old", "waiting", 300); heartbeat(r, "exited", "exited");
  const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say("/chiefs"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(ran).toEqual([]);
  expect(replies.join("\n")).toContain(NAME);
  expect(replies.join("\n")).toContain("hb=");
  expect(replies.join("\n")).toContain("himmel");
  expect(replies.join("\n")).toContain("/repos/himmel");
  expect(replies.join("\n")).not.toContain("old");
  expect(replies.join("\n")).not.toContain("exited");
});

test("bare /chief and /chiefs retain typed, sender and allowed-chat authority gates", async () => {
  for (const text of ["/chief halt", "/chiefs"]) {
    for (const extra of [{ forwarded: true }, { caption: true }, { from: 999 }, { chat_id: -99 }]) {
      const r = root(); const f = heartbeat(r); const replies: string[] = [];
      const g: ConsoleRouteGate = { authorize: (from, chat) => from === 1 && chat === 1, reply: async (_chat, t) => { replies.push(t); } };
      await handleInbound(r, say(text, extra), async () => {}, undefined, async () => "spawn-high", undefined, undefined, undefined, undefined, g);
      expect(readFileSync(f, "utf8")).toBe("");
      expect(replies).toEqual([]);
    }
  }
});

test("router: /chief <name> <text> classifies; prose and partial shapes stay chat", () => {
  expect(classify(`/chief ${NAME} halt the wave`)).toEqual({ kind: "console", name: NAME, text: "halt the wave" });
  expect(classify(`/chief ${NAME} line one\nline two`)).toEqual({ kind: "console", name: NAME, text: "line one\nline two" });
  expect(classify("chief output: foo").kind).toBe("chat");
  expect(classify("/chief").kind).toBe("chat");
  expect(classify(`/chief ${NAME}`)).toEqual({ kind: "console", name: "", text: NAME });
  expect(classify(`please /chief ${NAME} hi`).kind).toBe("chat");
});

test("allowlisted /chief message lands one line in the console inbox and spawns NO cold session", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/chief ${NAME} go ahead with PR 12`), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  const lines = readFileSync(f, "utf8").split("\n").filter(Boolean);
  expect(lines.length).toBe(1);
  expect(lines[0]).toMatch(/^- \d\d:\d\dZ \[telegram from=1 chat=1\] go ahead with PR 12$/);
  expect(ran).toEqual([]);
  expect(existsSync(join(r, "sessions"))).toBe(false);
  expect(replies).toEqual([`→ chief ${NAME}`]);
});

test("control: a non-allowlisted sender's console verb drops without a cold spawn", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/chief ${NAME} halt everything`, { from: 999 }), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual([]);
  expect(replies).toEqual([]);
});

test("control: an unaddressed message keeps today's cold-spawn behaviour", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say("hello there"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
  expect(replies).toEqual([]);
});

test("control: with no console gate wired, /chief drops without spawning", async () => {
  const r = root(); const f = armInbox(r); const ran: string[] = [];
  await handleInbound(r, say(`/chief ${NAME} hi`), async (s: string) => { ran.push(s); });
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual([]);
});

test("forwarded or caption /chief messages drop without spawning", async () => {
  for (const extra of [{ forwarded: true }, { caption: true }]) {
    const r = root(); const f = armInbox(r); const ran: string[] = [];
    await handleInbound(r, say(`/chief ${NAME} halt`, extra), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual([]);
  }
});

// routeToConsole never creates an inbox (appendIfExists is
// O_CREAT-free, see bus.test.ts for the TOCTOU-race regression at the
// primitive level).
test("a console with no armed inbox gets an error reply, no file, and no cold session", async () => {
  const r = root(); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/chief ${NAME} hi`), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(existsSync(join(r, "consoles", `${NAME}.md`))).toBe(false);
  expect(ran).toEqual([]);
  expect(existsSync(join(r, "sessions"))).toBe(false);
  expect(replies.length).toBe(1);
  expect(replies[0]).toContain("no live chief");
  expect(replies[0]).toContain(NAME);
});

test("a traversal-shaped console name is refused: nothing written outside consoles/, no cold session", async () => {
  const r = root(); const replies: string[] = []; const ran: string[] = [];
  mkdirSync(join(r, "consoles"), { recursive: true });
  writeFileSync(join(r, "escape.md"), "");
  // Invalid first words are bare text, never paths; with no live chief
  // they queue nothing.
  await handleInbound(r, say("/chief ../escape hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(ran).toEqual([]);
  replies.length = 0;
  await handleInbound(r, say("/chief a..b hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(join(r, "escape.md"), "utf8")).toBe("");
  expect(ran).toEqual([]);
  expect(replies.length).toBe(1);
  expect(replies[0]).toContain("no live chief");
  expect(consoleInboxPath(r, "../escape")).toBeNull();
  expect(consoleInboxPath(r, "a..b")).toBeNull();
  expect(consoleInboxPath(r, "")).toBeNull();
});

test("a multi-line message is folded onto ONE line so a tail -F monitor emits one event", async () => {
  const r = root(); const f = armInbox(r);
  await handleInbound(r, say(`/chief ${NAME} first\nsecond\r\nthird`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  const raw = readFileSync(f, "utf8");
  expect(raw.endsWith("\n")).toBe(true);
  expect(raw.split("\n").filter(Boolean).length).toBe(1);
  expect(raw).toContain("first ⏎ second ⏎ third");
  expect(foldLine("a\nb")).toBe("a ⏎ b");
});

test("a reply-seam failure after the append does not throw (handleBatch would tell the operator to resend a duplicate)", async () => {
  const r = root(); const f = armInbox(r);
  const g: ConsoleRouteGate = { authorize: () => true, reply: async () => { throw new Error("outbox down"); } };
  await handleInbound(r, say(`/chief ${NAME} hi`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, g);
  expect(readFileSync(f, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

test("first waiter arm queues one announcement per identity, including successor, never on restart", async () => {
  const r = root(); const f = heartbeat(r); const successor = heartbeat(r, "successor");
  const access = join(r, "access.json");
  writeFileSync(access, JSON.stringify({ allowFrom: ["1"] }));
  const tick = join(r, "tick.sh"); const bank = join(r, "bank.sh");
  writeFileSync(tick, "#!/usr/bin/env bash\nexit 1\n");
  writeFileSync(bank, "#!/usr/bin/env bash\nprintf 'PROCEED\\n'\n");
  for (const inbox of [f, f, successor]) {
    // A pending inbox line makes the real waiter exit immediately, not an idle
    // timing probe. First-arm announcement must happen before its first wake.
    writeFileSync(inbox, "wake\n");
    writeFileSync(inbox + ".cursor", "0");
    const p = Bun.spawn([BASH_BIN, join(import.meta.dir, "../handover/chief-kit/chief-wait.sh"), inbox], {
      env: { ...process.env, BRIDGE_ROOT: r, TELEGRAM_ACCESS_PATH: access, CHIEF_WAIT_TICK: tick, CHIEF_WAIT_USAGE: bank }, stdout: "pipe", stderr: "pipe",
    });
    await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    expect(await p.exited).toBe(0);
  }
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").trim().split("\n").map(l => JSON.parse(l));
  expect(out.map(m => m.console)).toEqual([NAME, "successor"]);
  expect(out[0].text).toContain(`/chief <text>`);
  expect(out.map(m => m.text).join("\n")).not.toContain("/console");
  expect(out[1].text).toContain("successor");
});

test("trusted console outbox receipt routes a Telegram reply to that console, even with two live chiefs", async () => {
  for (const text of ["thanks, halt", "ABC-123: halt"]) {
    const r = root(); const f = heartbeat(r); heartbeat(r, "second");
    await replyViaOutbox(r, 1, "chief answer", NAME);
    await flushOutboxes(r, async () => 777);
    await ingestUpdates(r, [{ update_id: 1, message: { from: { id: 1 }, chat: { id: 1 }, text, reply_to_message: { message_id: 777 }, date: Math.floor(Date.now() / 1000) } }]);
    const msg = JSON.parse(readFileSync(join(r, "inbound.jsonl"), "utf8").trim());
    const ran: string[] = [];
    await handleInbound(r, msg, async s => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toContain(`[telegram from=1 chat=1 reply_to=777] ${text}`);
    expect(readFileSync(join(r, "consoles", "second.md"), "utf8")).toBe("");
    expect(ran).toEqual([]);
  }
});

test("explicit control, dispatch and slash commands retain their routing in a console reply thread", async () => {
  for (const text of ["status", "work on HIMMEL-123", "/restart", "/chief", " /unknown command"]) {
    const r = root(); const f = heartbeat(r);
    await replyViaOutbox(r, 1, "chief answer", NAME);
    await flushOutboxes(r, async () => 777);
    await handleInbound(r, say(text, { reply_to_message_id: 777 }), async () => {}, undefined, async () => "spawn-high", undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toBe("");
  }
});

test("reply mapping is chat-scoped and never bypasses sender, caption, forwarded or chat gates", async () => {
  for (const extra of [{ from: 999 }, { caption: true }, { forwarded: true }, { chat_id: -99 }]) {
    const r = root(); const f = heartbeat(r);
    await replyViaOutbox(r, 1, "answer", NAME);
    await flushOutboxes(r, async () => 777);
    const replies: string[] = [];
    const g: ConsoleRouteGate = { authorize: (from, chat) => from === 1 && chat === 1, reply: async (_chat, text) => { replies.push(text); } };
    await handleInbound(r, say("halt", { reply_to_message_id: 777, ...extra }), async () => {}, undefined, async () => "spawn-high", undefined, undefined, undefined, undefined, g);
    expect(readFileSync(f, "utf8")).toBe("");
    expect(replies).toEqual([]);
  }
});

test("an unrelated bot message or a forged reply label stays ordinary chat", async () => {
  const r = root(); const f = heartbeat(r); const ran: string[] = [];
  await replyViaOutbox(r, 1, "ordinary answer");
  await flushOutboxes(r, async () => 777);
  await handleInbound(r, say(`Chief ${NAME} is live`, { reply_to_message_id: 777 }), async s => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
});

test("reply CLI tags a running console's answer using the established session-name resolver", async () => {
  const r = root(); heartbeat(r);
  const cmdline = join(r, "cmdline");
  writeFileSync(cmdline, `claude\0-n\0${NAME}\0`);
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", "1", "answer"], {
    env: { ...process.env, BRIDGE_ROOT: r, CLAUDE_PID: "123", SESSION_NAME_CMDLINE_FILE: cmdline }, stdout: "pipe", stderr: "pipe",
  });
  await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  expect(await p.exited).toBe(0);
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").trim();
  expect(JSON.parse(out)).toEqual({ text: "answer", console: NAME, format: true });
});

test("reply CLI appends one line to the chat's outbox under a scratch BRIDGE_ROOT", async () => {
  const r = root();
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", "1", "done", "with", "PR 12"], { env: { ...process.env, BRIDGE_ROOT: r }, stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(0);
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").split("\n").filter(Boolean);
  expect(out.map((l) => JSON.parse(l))).toEqual([{ text: "done with PR 12", format: true }]);
  const meta = JSON.parse(readFileSync(join(r, "sessions", "__chat__", "meta.json"), "utf8"));
  expect(meta.chat_id).toBe(1);
});

test("reply CLI: the old --console is refused even with HIMMEL_LEGACY_NAMES=1; only --chief names the chief", async () => {
  const reply = async (flag: string, env: Record<string, string> = {}) => {
    const r = root();
    const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", flag, NAME, "1", "answer"], {
      env: { ...process.env, BRIDGE_ROOT: r, ...env }, stdout: "pipe", stderr: "pipe",
    });
    const err = await new Response(p.stderr).text();
    const code = await p.exited;
    const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
    return { code, err, line: existsSync(outbox) ? readFileSync(outbox, "utf8").trim() : null };
  };
  const fresh = await reply("--chief", { HIMMEL_LEGACY_NAMES: "1" });
  const old = await reply("--console", { HIMMEL_LEGACY_NAMES: "1" });
  expect(fresh.code).toBe(0);
  expect(JSON.parse(fresh.line!)).toEqual({ text: "answer", console: NAME, format: true });
  expect(old.code).toBe(1);
  expect(old.line).toBeNull();
  expect(old.err).toContain("usage: bun chief-route.ts reply");
});

async function owedReply(r: string, doc: string, flush: boolean, extra: string[] = ["--owed", "sig-1", "--doc", doc], o: { text?: string; parts?: number; send?: () => Promise<number | undefined>; waitSec?: string } = {}) {
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", "--chief", NAME, ...extra, "1", o.text ?? "please sign"], {
    env: { ...process.env, BRIDGE_ROOT: r, CHIEF_ROUTE_RECEIPT_WAIT_SEC: o.waitSec ?? (flush ? "20" : "1") }, stdout: "pipe", stderr: "pipe",
  });
  const out = new Response(p.stdout).text(); const err = new Response(p.stderr).text();
  const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
  if (flush) {
    const queued = () => existsSync(outbox) && readFileSync(outbox, "utf8").split("\n").filter(Boolean).length >= (o.parts ?? 1);
    for (let i = 0; i < 100 && !queued(); i++) await new Promise(res => setTimeout(res, 100));
    await flushOutboxes(r, o.send ?? (async () => 4242));
  }
  return { code: await p.exited, out: await out, err: await err };
}

test("HIMMEL-9974 reply --owed on a split reply writes DELIVERED only after every part has a send receipt, naming the last part's message id", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n- 10:00 OWED sig-1 sign it\n");
  let id = 5000;
  const send = async () => { await new Promise(res => setTimeout(res, 600)); return ++id; };
  const res = await owedReply(r, doc, true, undefined, { text: filler(7000), parts: 3, send });
  expect(res.code).toBe(0);
  expect(res.out).toContain("delivered msg=5003");
  expect(readFileSync(doc, "utf8")).toMatch(/\n- \d\d:\d\dZ DELIVERED sig-1 msg=5003 chat=1\n$/);
});

test("HIMMEL-9974 reply --owed on a split reply whose last part gets no receipt exits non-zero, names 2 of 3, and marks nothing delivered", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n- 10:00 OWED sig-1 sign it\n");
  let id = 6000;
  const send = async () => { await new Promise(res => setTimeout(res, 600)); return id < 6002 ? ++id : undefined; };
  const res = await owedReply(r, doc, true, undefined, { text: filler(7000), parts: 3, send, waitSec: "4" });
  expect(res.code).toBe(1);
  expect(res.err).toContain("2 of 3");
  expect(readFileSync(doc, "utf8")).not.toContain("DELIVERED");
});

test("reply --owed prints the Telegram message id from the poller's send receipt and writes the DELIVERED bullet", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n- 10:00 OWED sig-1 sign it\n");
  mkdirSync(join(r, "consoles", "replies"), { recursive: true });
  writeFileSync(join(r, "consoles", "replies", "1_100.json"), JSON.stringify({ name: NAME }));
  const res = await owedReply(r, doc, true);
  expect(res.code).toBe(0);
  expect(res.out).toContain("delivered msg=4242");
  expect(readFileSync(doc, "utf8")).toMatch(/\n- \d\d:\d\dZ DELIVERED sig-1 msg=4242 chat=1\n$/);
});

test("reply --owed exits non-zero and marks nothing delivered when no send receipt arrives; a receipt written just before the reply was queued does not count", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n- 10:00 OWED sig-1 sign it\n");
  mkdirSync(join(r, "consoles", "replies"), { recursive: true });
  writeFileSync(join(r, "consoles", "replies", "1_100.json"), JSON.stringify({ name: NAME }));
  const res = await owedReply(r, doc, false);
  expect(res.code).toBe(1);
  expect(res.err).toContain("no send receipt");
  expect(readFileSync(doc, "utf8")).not.toContain("DELIVERED");
});

test("reply --owed without a usable key and chief doc is refused and queues nothing", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n");
  for (const extra of [["--owed", "sig-1"], ["--owed", "bad key", "--doc", doc], ["--owed", "sig-1", "--doc", join(r, "missing.md")]]) {
    const res = await owedReply(r, doc, false, extra);
    expect(res.code).toBe(1);
    expect(res.err).toContain("usage: bun chief-route.ts reply");
  }
  expect(existsSync(join(r, "sessions", "__chat__", "outbox.jsonl"))).toBe(false);
});

test("owed outage retries reuse one queued identity, ignore unrelated receipts and reconcile after restart", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n");
  const args = ["--owed", "sig-1", "--doc", doc];
  const started = Date.now();
  const first = await owedReply(r, doc, false, args, { waitSec: "0" });
  expect(first.code).toBe(1);
  expect(Date.now() - started).toBeLessThan(2000);
  const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
  const queued = readFileSync(outbox, "utf8");
  expect(queued.trim().split("\n")).toHaveLength(1);
  await replyViaOutbox(r, 1, "unrelated", NAME);
  let id = 7000;
  // Fail the owed row while the unrelated send remains a separate receipt.
  await flushOutboxes(r, async (_chat, text) => {
    if (text === "please sign") throw new Error("offline");
    return ++id;
  });
  const { rememberConsoleReply } = await import("./chief-route");
  await rememberConsoleReply(r, 1, 7999, NAME);
  const second = await owedReply(r, doc, false, args);
  expect(second.code).toBe(1);
  expect(readFileSync(outbox, "utf8").split("\n").filter(Boolean)).toHaveLength(2);
  expect(readFileSync(doc, "utf8")).not.toContain("DELIVERED");
  // A new CLI process after an outage still checks the original request.
  // Make the persisted poller backoff due, then deliver it and reconcile.
  const { readdirSync } = await import("node:fs");
  for (const f of readdirSync(join(r, "sessions", "__chat__"))) {
    if (f.includes(".retry-")) writeFileSync(join(r, "sessions", "__chat__", f), '{"next":0,"attempts":1}');
  }
  await flushOutboxes(r, async () => ++id);
  const third = await owedReply(r, doc, false, args);
  expect(third.code).toBe(0);
  expect(readFileSync(doc, "utf8")).toContain("DELIVERED sig-1 msg=7002 chat=1");
  expect(readFileSync(outbox, "utf8").split("\n").filter(Boolean)).toHaveLength(2);
});

test("a permanently refused owed row permits a later owed row and receipts never cross identities", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n");
  for (const key of ["bad", "good"]) {
    const queued = await owedReply(r, doc, false, ["--owed", key, "--doc", doc], { text: key });
    expect(queued.code).toBe(1);
  }
  const attempts: string[] = [];
  const send = async (_chat: number, text: string) => {
    attempts.push(text);
    if (text === "bad") throw new Error("permanent refusal");
    return 8000;
  };
  await flushOutboxes(r, send);
  await flushOutboxes(r, send);
  expect(attempts).toEqual(["bad", "good"]);
  const bad = await owedReply(r, doc, false, ["--owed", "bad", "--doc", doc], { text: "bad" });
  const good = await owedReply(r, doc, false, ["--owed", "good", "--doc", doc], { text: "good" });
  expect(bad.code).toBe(1);
  expect(good.code).toBe(0);
  expect(readFileSync(doc, "utf8")).toContain("DELIVERED good msg=8000 chat=1");
  expect(readFileSync(doc, "utf8")).not.toContain("DELIVERED bad");
});

test("an owed key with changed content refuses a conflicting second message", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n");
  await owedReply(r, doc, false);
  const conflict = await owedReply(r, doc, false, undefined, { text: "changed action" });
  expect(conflict.code).toBe(1);
  const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
  expect(readFileSync(outbox, "utf8").trim().split("\n")).toHaveLength(1);
  expect(conflict.err).toContain("owed content changed");
});

const TABLE = join(import.meta.dir, "message-classes.json");
const FIX = join(import.meta.dir, "fixtures");
const FIX_MIRROR = join(FIX, "jira-mirror", "HIMMEL");
const CLI = join(import.meta.dir, "chief-route.ts");
const DO_STEP = " Do: ask a reviewer for the one approval GitHub still wants";
type Ran = { code: number; out: string; err: string; r: string; home: string };
async function route(args: string[], o: { r?: string; env?: Record<string, string>; table?: string; access?: object } = {}): Promise<Ran> {
  const r = o.r ?? root(); const home = mkdtempSync(join(tmpdir(), "chief-route-home-"));
  const access = join(home, "access.json"); writeFileSync(access, JSON.stringify(o.access ?? { allowFrom: ["7"] }));
  const p = Bun.spawn(["bun", CLI, "reply", ...args], {
    env: { ...process.env, BRIDGE_ROOT: r, HOME: home, HIMMEL_TEST_FIXTURE: "1", HIMMEL_JIRA_MIRROR: FIX_MIRROR, HIMMEL_MESSAGE_CLASSES: o.table ?? TABLE, TELEGRAM_ACCESS_PATH: access, ...o.env },
    stdout: "pipe", stderr: "pipe",
  });
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  return { code: await p.exited, out, err, r, home };
}
const lines = (f: string): string[] => (existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean) : []);
const operatorOutbox = (r: string): { text: string; console?: string }[] => lines(join(r, "sessions", "__chat__", "outbox.jsonl")).map((l) => JSON.parse(l));
const spool = (r: string): { text: string; kind: string; at: string }[] => lines(join(r, "monitor", "outbox.jsonl")).map((l) => JSON.parse(l));
const routeLog = (r: string): string[] => lines(join(r, "route.log"));
const filler = (n: number) => "blocked word ".repeat(Math.ceil(n / 13)).slice(0, n);
const longMerge = (total: number) => `Merge refused. Blocks: ${filler(total - 23 - DO_STEP.length)}${DO_STEP}`;
function plainWords(text: string): void {
  expect(text).not.toMatch(/(?<!worker )(?<![A-Za-z0-9-])N[0-9]+[a-z]*(?![A-Za-z0-9])/i);
  expect(text).not.toMatch(/(^|[ (])[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+/);
  for (const key of new Set(text.match(/HIMMEL-[0-9]+(?![0-9-])/g) ?? [])) expect(text.includes(`${key} (`) || text.includes(`${key}: `)).toBe(true);
}

test("R1.1 a worker-silent kind queues nothing for the operator, prints silent and exits 0", async () => {
  const x = await route(["--kind", "worker-silent", "operator", "WORKER-SILENT N4992b signal=succession-partial"]);
  expect(x.code).toBe(0);
  expect(x.out.trim()).toBe("silent");
  expect(operatorOutbox(x.r)).toEqual([]);
  expect(spool(x.r)).toEqual([]);
});

test("R1.2 an unknown kind, a malformed kind, an unknown cadence worker and an unreadable table each land in the operator outbox uncapped", async () => {
  const text = `Something happened. Blocks: nothing. ${filler(900)}${DO_STEP}`;
  const cases: [string[], string | undefined][] = [
    [["--kind", "no-such-kind"], undefined], [["--kind", "Bad Kind"], undefined], [["--kind", "cadence:new-thing"], undefined],
    [["--kind", "merge-blocked"], join(tmpdir(), "chief-route-no-such-table.json")], [[], undefined],
  ];
  for (const [flags, table] of cases) {
    const x = await route([...flags, "operator", text], { table });
    expect(x.code).toBe(0);
    expect(x.out.trim()).toBe("escalate");
    expect(operatorOutbox(x.r).map((m) => m.text)).toEqual([text]);
    expect(spool(x.r)).toEqual([]);
  }
});

test("R1.4 replay 11-07: the operator gets the 4 controls, the spool the 3 monitor lines, the 6 silent lines nothing", async () => {
  const replay = readFileSync(join(FIX, "replay-11-07.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { time: string; kind?: string; expect: string; text: string });
  expect(replay).toHaveLength(13);
  const real = JSON.parse(readFileSync(TABLE, "utf8"));
  expect(real.kinds.find((k: { kind: string }) => k.kind === "hold-ask-chief").class).toBe("silent");
  expect(real.kinds.find((k: { kind: string }) => k.kind === "denial-page").class).toBe("silent");
  const r = root();
  for (const l of replay) {
    const x = await route([...(l.kind ? ["--kind", l.kind] : []), "operator", l.text], { r });
    expect(x.code).toBe(0);
    expect(x.out.trim()).toBe(l.expect);
  }
  const queued = operatorOutbox(r).map((m) => m.text);
  expect(queued).toHaveLength(4);
  expect(spool(r)).toHaveLength(3);
  expect(spool(r).map((m) => m.kind)).toEqual(["cadence:vault-stall", "cadence:vm-maintain-login-himmel-claudex", "cache-health"]);
  for (const t of [...queued, ...spool(r).map((m) => m.text)]) plainWords(t);
  expect(routeLog(r)).toHaveLength(13);
  const before = JSON.parse(JSON.stringify(real));
  for (const row of before.kinds) { if (row.kind === "hold-ask-chief" || row.kind === "denial-page") row.class = "escalate"; }
  const dir = mkdtempSync(join(tmpdir(), "chief-route-table-")); const s1Table = join(dir, "s1.json"); writeFileSync(s1Table, JSON.stringify(before));
  const s1 = root();
  for (const l of replay) await route([...(l.kind ? ["--kind", l.kind] : []), "operator", l.text], { r: s1, table: s1Table });
  expect(operatorOutbox(s1)).toHaveLength(6);
  expect(spool(s1)).toHaveLength(3);
});

test("R1.5 the cap: 900 characters of merge-blocked go out whole, over the cap and never cut; a long Do: step and chief-reply go uncut", async () => {
  const text = longMerge(900);
  const x = await route(["--kind", "merge-blocked", "operator", text]);
  expect(operatorOutbox(x.r).map((m) => m.text)).toEqual([text]);
  expect(existsSync(join(x.r, "route-cut"))).toBe(false);
  expect(routeLog(x.r)[0].endsWith(" over-cap-uncut")).toBe(true);

  const bigDo = `Merge refused. Blocks: the merge. Do: ${"x".repeat(450)}`;
  const y = await route(["--kind", "merge-blocked", "operator", bigDo]);
  expect(operatorOutbox(y.r).map((m) => m.text)).toEqual([bigDo]);
  expect(routeLog(y.r)[0].endsWith(" over-cap-uncut")).toBe(true);
  expect(existsSync(join(y.r, "route-cut"))).toBe(false);

  const reply = `${filler(900)} Do: read it`;
  const z = await route(["--kind", "chief-reply", "operator", reply]);
  expect(operatorOutbox(z.r).map((m) => m.text)).toEqual([reply]);
  expect(existsSync(join(z.r, "route-cut"))).toBe(false);
  expect(routeLog(z.r)[0].endsWith(" ok")).toBe(true);
});

const PART_LIMIT = 3000;
function unmarked(parts: string[]): string[] {
  expect(parts.length).toBeGreaterThan(1);
  return parts.map((p, i) => {
    expect(p.length).toBeLessThanOrEqual(PART_LIMIT);
    const m = /^\((\d+)\/(\d+)\) /.exec(p);
    expect(m && [Number(m[1]), Number(m[2])]).toEqual([i + 1, parts.length]);
    return p.slice(m![0].length);
  });
}

test("HIMMEL-9974 (a) a reply about three times the part limit goes out as three ordered parts whose text, markers removed, is the input; a capped kind splits the same way", async () => {
  const text = [filler(2900), filler(2900), filler(2900)].join("\n\n") + DO_STEP;
  for (const flags of [[], ["--kind", "merge-blocked"]]) {
    const x = await route([...flags, "operator", text]);
    expect(x.out.trim()).toBe("escalate");
    const parts = operatorOutbox(x.r).map((m) => m.text);
    expect(parts).toHaveLength(3);
    const body = unmarked(parts);
    expect(body.join("")).toBe(text);
    expect(body[2].endsWith(DO_STEP)).toBe(true);
    expect(existsSync(join(x.r, "route-cut"))).toBe(false);
    expect(routeLog(x.r)).toHaveLength(1);
    expect(routeLog(x.r)[0].endsWith(" split")).toBe(true);
  }
});

test("HIMMEL-9974 (b) no part ends mid-word, every part is under the limit, and a backtick command near the break stays in one part", async () => {
  const cmd = "`bash scripts/handover/chief-kit/go.sh grant the-ticket now`";
  const text = `${filler(2970)} ${cmd} ${filler(4000)}`;
  const x = await route(["operator", text]);
  const body = unmarked(operatorOutbox(x.r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  for (const b of body.slice(0, -1)) expect(b).toMatch(/\s$/);
  expect(body.some((b) => b.includes(cmd))).toBe(true);
});

test("HIMMEL-9974 (c) control: a short reply is one message with no part marker and the same route-log row as before", async () => {
  const text = "Merged the PR. Blocks: nothing. Do: nothing";
  const x = await route(["operator", text]);
  expect(operatorOutbox(x.r).map((m) => m.text)).toEqual([text]);
  const f = routeLog(x.r)[0].split(" ");
  expect(f.slice(1)).toEqual(["unclassified", "escalate", "operator", String(text.length), "0", "ok"]);
});

test("HIMMEL-9974 (d) control: a long monitor-class reply goes whole to the spool, unsplit, as before", async () => {
  const text = `stalled. Blocks: nothing. ${filler(8000)} Do: read the log`;
  const x = await route(["--kind", "cadence:vault-stall", "operator", text]);
  expect(x.out.trim()).toBe("monitor");
  expect(operatorOutbox(x.r)).toEqual([]);
  expect(spool(x.r).map((m) => m.text)).toEqual([text]);
  expect(routeLog(x.r)[0].endsWith(" ok")).toBe(true);
});

test("HIMMEL-9974 (e) with no paragraph break a reply splits at lines, then sentences; only a word longer than the limit is split inside the word", async () => {
  const byLine = Array.from({ length: 60 }, (_, i) => `line ${i} ${filler(110)}`).join("\n");
  const l = unmarked(operatorOutbox((await route(["operator", byLine])).r).map((m) => m.text));
  expect(l.join("")).toBe(byLine);
  for (const b of l.slice(0, -1)) expect(b.endsWith("\n")).toBe(true);

  const bySentence = Array.from({ length: 120 }, (_, i) => `Sentence ${i} of the reply says one plain thing here.`).join(" ");
  const s = unmarked(operatorOutbox((await route(["operator", bySentence])).r).map((m) => m.text));
  expect(s.join("")).toBe(bySentence);
  for (const b of s.slice(0, -1)) expect(b).toMatch(/\. $/);

  const word = "x".repeat(7000);
  const w = unmarked(operatorOutbox((await route(["operator", word])).r).map((m) => m.text));
  expect(w).toHaveLength(3);
  expect(w.join("")).toBe(word);
  for (const b of w.slice(0, -1)) expect(b).toMatch(/x$/);
});

test("HIMMEL-10730 (f) mid-word: a word that fits in a part is never cut, even with no sentence break near the limit", async () => {
  const text = Array.from({ length: 900 }, (_, i) => `word${i}`).join(" ");
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  for (const b of body.slice(0, -1)) expect(b).toMatch(/ $/);
});

test("HIMMEL-10730 (g) mid-code: with no free break before it, a backtick span that crosses the limit moves whole to the next part", async () => {
  const cmd = "`bash scripts/handover/chief-kit/go.sh grant the ticket now and then check it twice`";
  const text = `${"x".repeat(2960)}${cmd} ${filler(400)}`;
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  expect(body.some((b) => b.includes(cmd))).toBe(true);
});

test("HIMMEL-10730 (h) mid-URL: with no free break before it, a link that crosses the limit moves whole to the next part", async () => {
  const url = `https://github.com/login/device?code=${"q".repeat(80)}`;
  const text = `${"x".repeat(2960)}${url} ${filler(400)}`;
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  expect(body.some((b) => b.includes(url))).toBe(true);
});

const longUrl = `https://github.com/login/device?code=${"q".repeat(3500)}`;
const longCode = `\`${"y".repeat(3500)}\``;

for (const [name, span] of [["link", longUrl], ["code span", longCode]] as const) {
  test(`HIMMEL-10730 (i) a ${name} longer than the part limit at the start of a reply is cut at the limit, and the split finishes`, async () => {
    const text = `${span} ${filler(200)}`;
    const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
    expect(body.join("")).toBe(text);
  });

  test(`HIMMEL-10730 (j) a ${name} longer than the part limit after a run with no breaks starts the second part, and the split finishes`, async () => {
    const text = `${"x".repeat(2960)}${span} ${filler(200)}`;
    const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
    expect(body.join("")).toBe(text);
    expect(body[0]).toBe("x".repeat(2960));
  });
}

test("HIMMEL-10730 (k) a link that starts past the part limit never makes a part longer than the limit", async () => {
  const url = `https://github.com/login/device?code=${"q".repeat(80)}`;
  const text = `${"x".repeat(3100)}${url} ${filler(200)}`;
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
});

test("HIMMEL-10730 (l) a code span that ends inside the first part stays in the first part", async () => {
  const text = `${"x".repeat(100)}\`short\`${"x".repeat(3000)}`;
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  expect(body[0]).toContain("`short`");
});

test("HIMMEL-10730 (m) two crossing spans, a link inside a code span, move whole to the next part from the earlier start", async () => {
  const code = `\`see https://github.com/login/device?code=${"q".repeat(100)}\``;
  const text = `${"x".repeat(2950)}${code} ${filler(300)}`;
  const body = unmarked(operatorOutbox((await route(["operator", text])).r).map((m) => m.text));
  expect(body.join("")).toBe(text);
  expect(body[0]).toBe("x".repeat(2950));
  expect(body.some((b) => b.includes(code))).toBe(true);
});

test("a silent kind with --satellite speaks nothing, queues nothing and exits 0", async () => {
  const x = await route(["--kind", "worker-silent", "--satellite", "assist_satellite.kitchen", "operator", "x"], { env: { HA_URL: "", HA_TOKEN: "" } });
  expect(x.code).toBe(0);
  expect(x.out.trim()).toBe("silent");
  expect(x.err).not.toContain("could not speak");
  expect(operatorOutbox(x.r)).toEqual([]);
});

test("R1.6 one route-log line per call for each class, written after the append, with no message text in it", async () => {
  const r = root();
  for (const [kind, cls] of [["merge-blocked", "escalate"], ["cadence:vault-stall", "monitor"], ["worker-silent", "silent"]]) {
    const before = routeLog(r).length;
    const x = await route(["--kind", kind, "operator", `ZEBRA-MARKER is the text. Blocks: nothing. Do: read it`], { r });
    expect(x.code).toBe(0);
    const log = routeLog(r);
    expect(log).toHaveLength(before + 1);
    const f = log[log.length - 1].split(" ");
    expect(f).toHaveLength(7);
    expect(f[1]).toBe(kind); expect(f[2]).toBe(cls);
    expect(log.join("\n")).not.toContain("ZEBRA");
  }
  const outbox = statSync(join(r, "sessions", "__chat__", "outbox.jsonl"), { bigint: true }).mtimeNs;
  expect(statSync(join(r, "route.log"), { bigint: true }).mtimeNs >= outbox).toBe(true);
});

test("R1.7 monitor and silent kinds create nothing under sessions/", async () => {
  const r = root();
  await route(["--kind", "cadence:vault-stall", "operator", "stalled. Blocks: nothing. Do: read the log"], { r });
  await route(["--kind", "worker-silent", "operator", "quiet"], { r });
  expect(existsSync(join(r, "sessions"))).toBe(false);
  expect(spool(r)).toHaveLength(1);
});

test("R1.9 a monitor kind whose text names salus lands in the operator outbox and not in the spool", async () => {
  const x = await route(["--kind", "cadence:vault-stall", "operator", "SALUS vault stalled. Blocks: nothing. Do: read the log"]);
  expect(x.out.trim()).toBe("escalate");
  expect(operatorOutbox(x.r)).toHaveLength(1);
  expect(spool(x.r)).toEqual([]);
});

test("R1.10 --chief X --kind Y and --kind Y --satellite Z both parse; operator resolves through the fixture access.json; no operator exits 1", async () => {
  const a = await route(["--chief", NAME, "--kind", "merge-blocked", "operator", "Merge refused. Blocks: x. Do: y"]);
  expect(a.code).toBe(0);
  expect(operatorOutbox(a.r)).toEqual([{ text: "Merge refused. Blocks: x. Do: y", console: NAME, format: true }]);
  const b = await route(["--kind", "merge-blocked", "--satellite", "assist_satellite.kitchen", "operator", "Merge refused. Blocks: x. Do: y"], { env: { HA_URL: "", HA_TOKEN: "" } });
  expect(b.err).not.toContain("usage:");
  expect(b.err).toContain("could not speak");
  expect(operatorOutbox(b.r)).toHaveLength(1);
  const c = await route(["--kind", "merge-blocked", "operator", "x"], { access: { allowFrom: [] } });
  expect(c.code).toBe(1);
  expect(c.err).toContain("usage: bun chief-route.ts reply");
  expect(operatorOutbox(c.r)).toEqual([]);
  const d = await route(["--kind", "merge-blocked", "7", "Merge refused. Blocks: x. Do: y"]);
  expect(d.code).toBe(0);
  expect(operatorOutbox(d.r)).toHaveLength(1);
});

test("R1.11 an internal error puts the raw uncut text in the operator outbox, prints escalate and exits 0", async () => {
  if (process.getuid?.() !== 0) {
    const mirror = mkdtempSync(join(tmpdir(), "chief-route-mirror-")); cpSync(FIX_MIRROR, join(mirror, "HIMMEL"), { recursive: true });
    chmodSync(join(mirror, "HIMMEL", "HIMMEL-9012.md"), 0);
    const raw = "A worker on HIMMEL-9012 needs a file. Blocks: that worker. Do: run it";
    const x = await route(["--kind", "merge-blocked", "operator", raw], { env: { HIMMEL_JIRA_MIRROR: join(mirror, "HIMMEL") } });
    expect(x.code).toBe(0); expect(x.out.trim()).toBe("escalate");
    expect(operatorOutbox(x.r).map((m) => m.text)).toEqual([raw]);
    expect(routeLog(x.r)[0]).toContain(" escalate-fallback ");
  }
  const r3 = root(); writeFileSync(join(r3, "monitor"), "a file, so mkdir fails");
  const raw3 = "stalled. Blocks: nothing. Do: read the log";
  const z = await route(["--kind", "cadence:vault-stall", "operator", raw3], { r: r3 });
  expect(z.code).toBe(0); expect(z.out.trim()).toBe("escalate");
  expect(operatorOutbox(r3).map((m) => m.text)).toEqual([raw3]);
  const r4 = root(); mkdirSync(join(r4, "route.log"));
  const w = await route(["--kind", "merge-blocked", "operator", "Merge refused. Blocks: x. Do: y"], { r: r4 });
  expect(w.code).toBe(0); expect(w.out.trim()).toBe("escalate");
  expect(operatorOutbox(r4)).toHaveLength(1);
  expect(w.err).toContain("route log");
});

test("R1.12 a CLI reply with a sandbox BRIDGE_ROOT and HOME writes route.log under the bridge root and no telegram-route anywhere under HOME", async () => {
  const x = await route(["--kind", "merge-blocked", "operator", "Merge refused. Blocks: x. Do: y"]);
  expect(existsSync(join(x.r, "route.log"))).toBe(true);
  const walk = (d: string): string[] => readdirSync(d, { withFileTypes: true }).flatMap((e) => [join(d, e.name), ...(e.isDirectory() ? walk(join(d, e.name)) : [])]);
  expect(walk(x.home).filter((p) => p.includes("telegram-route"))).toEqual([]);
  expect(walk(x.home).filter((p) => p.endsWith("route.log"))).toEqual([]);
});

const cliStub = (name: string, body: string): string => { const f = join(mkdtempSync(join(tmpdir(), "chief-route-cli-")), name); writeFileSync(f, body); return f; };
const DEAD_CLI = cliStub("dead.js", `process.stderr.write("jira: 401\\n"); process.exit(1);`);
const HANG_CLI = cliStub("hang.js", `setInterval(() => {}, 1000);`);
const reports = (r: string) => spool(r).filter((m) => m.kind === "title-unresolved");

test("HIMMEL-10583 a line whose ticket title cannot be read goes out with the bare key and one title-unresolved report names the key", async () => {
  for (const cli of [DEAD_CLI, HANG_CLI]) {
    const x = await route(["operator", "HIMMEL-7002 is stuck"], { env: { HIMMEL_JIRA_CLI: cli } });
    expect(x.code).toBe(0);
    expect(operatorOutbox(x.r).map((m) => m.text)).toEqual(["HIMMEL-7002 is stuck"]);
    const rep = reports(x.r);
    expect(rep).toHaveLength(1);
    expect(rep[0].text).toContain("HIMMEL-7002");
    expect(rep[0].text).not.toMatch(/not readable on the station/);
  }
});

test("HIMMEL-10583 controls: resolved keys report nothing, two unresolved keys make one report, a failed report send never blocks the line", async () => {
  const ok = await route(["operator", "HIMMEL-9503 is stuck"], { env: { HIMMEL_JIRA_CLI: DEAD_CLI } });
  expect(operatorOutbox(ok.r)).toHaveLength(1);
  expect(reports(ok.r)).toEqual([]);

  const two = await route(["operator", "HIMMEL-7002 and HIMMEL-7003 are stuck"], { env: { HIMMEL_JIRA_CLI: DEAD_CLI } });
  expect(operatorOutbox(two.r).map((m) => m.text)).toEqual(["HIMMEL-7002 and HIMMEL-7003 are stuck"]);
  const rep = reports(two.r);
  expect(rep).toHaveLength(1);
  expect(rep[0].text).toContain("HIMMEL-7002, HIMMEL-7003");

  const many = Array.from({ length: 300 }, (_, i) => `HIMMEL-${7100 + i}`);
  const big = await route(["operator", `${many.join(" ")} are stuck`], { env: { HIMMEL_JIRA_CLI: DEAD_CLI } });
  const bigRep = reports(big.r);
  expect(bigRep).toHaveLength(1);
  expect(bigRep[0].text).toContain(`${many.slice(0, 10).join(", ")} and 290 more`);
  expect(bigRep[0].text.length).toBeLessThan(1000);

  const r = root(); writeFileSync(join(r, "monitor"), "a file, so mkdir fails");
  const bad = await route(["operator", "HIMMEL-7002 is stuck"], { r, env: { HIMMEL_JIRA_CLI: DEAD_CLI } });
  expect(bad.code).toBe(0); expect(bad.out.trim()).toBe("escalate");
  expect(operatorOutbox(r).map((m) => m.text)).toEqual(["HIMMEL-7002 is stuck"]);
  expect(routeLog(r).some((l) => / title-unresolved report-failed /.test(l))).toBe(true);
});

test("HIMMEL-10583 a report that names a salus key goes to the operator chat, never the monitoring group", async () => {
  const x = await route(["operator", "SALUS-1 is stuck"], { env: { HIMMEL_JIRA_CLI: DEAD_CLI, JIRA_PROJECT_KEY: "SALUS" } });
  expect(x.code).toBe(0);
  expect(spool(x.r)).toEqual([]);
  const sent = operatorOutbox(x.r).map((m) => m.text);
  expect(sent[0]).toBe("SALUS-1 is stuck");
  expect(sent).toHaveLength(2);
  expect(sent[1]).toContain("SALUS-1");
});

// Every malformed reserved fleet shape is a terminal refusal.
const malformed = ["/go foo..bar", "/go ../escape", "/push a..b", "/halt a/b", "/go a\\b", `/go ${"a".repeat(65)}`, "/push a\u0000b", "/halt a\nb", "/go", "/push", "/go a b", "/halt a b", "/fleet now", "/workers x", "/go  foo", "/push foo‮"];

test("malformed-fleet-shapes-classify-terminal", () => {
  for (const text of malformed) expect(classify(text).kind).toBe("fleet-malformed");
  for (const text of ["/go a.b-c_1", "/push " + "a".repeat(64), "/halt", "/fleet", "/workers"]) expect(classify(text).kind).toBe("fleet");
});

test("malformed-fleet-inbound-refused-no-queue-no-spawn", async () => {
  for (const text of malformed) {
    const r = root(); const f = heartbeat(r); const replies: string[] = []; const ran: string[] = []; const fired: string[] = [];
    await inbound(r, fresh(text), replies, ran, fired);
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual([]);
    expect(fired).toEqual([]);
    expect(existsSync(join(r, "sessions", "__chat__", "inbox.jsonl"))).toBe(false);
    expect(replies.join("\n")).toContain("malformed fleet command");
    for (const extra of [{ from: 999 }, { chat_id: -99 }, { forwarded: true }, { caption: true }, { text: `model:opus ${text}` }]) {
      const quiet: string[] = [];
      await inbound(r, fresh(text, extra), quiet, ran, fired);
      expect(quiet).toEqual([]);
    }
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual([]);
  }
});

test("lockdown-arriving-in-settlement-gap-is-not-a-content-filter-block", async () => {
  const r = root(); await ensureSession(r, "__chat__");
  await writeMeta(r, "__chat__", { chat_id: 1, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  await appendLine(join(sessionDir(r, "__chat__"), "inbox.jsonl"), JSON.stringify({ text: "hello", from: 1, ts: 1 }));
  const ran: string[] = []; const notices: string[] = [];
  // runAndSettle stamps last_run_at via now() -> toISOString() AFTER makeRunFn's
  // last lockdown check and BEFORE the spawn closure: lock exactly there.
  const real = Date.prototype.toISOString;
  const stderr = spyOn(console, "error").mockImplementation(() => {});
  const spy = spyOn(Date.prototype, "toISOString").mockImplementation(function (this: Date) {
    if (new Error().stack?.includes("runAndSettle") && !existsSync(join(r, "lockdown"))) writeFileSync(join(r, "lockdown"), "locked\n");
    return real.call(this);
  });
  try {
    const run = makeRunFn(r, r, async prompt => { ran.push(prompt); return { code: 0, capped: false, pid: 1 }; }, undefined, async (_s, _t, kind) => { notices.push(kind); }, undefined, undefined, undefined, () => r);
    await run("__chat__");
  } finally { spy.mockRestore(); stderr.mockRestore(); }
  expect(existsSync(join(r, "lockdown"))).toBe(true);
  expect(ran).toEqual([]);
  expect(notices).toEqual([]);
  const meta = JSON.parse(readFileSync(join(sessionDir(r, "__chat__"), "meta.json"), "utf8"));
  expect(meta.status).toBe("idle");
  expect(readFileSync(join(sessionDir(r, "__chat__"), "inbox.jsonl"), "utf8")).toContain("hello");
});

// A chief mid-turn has no fresh waiter heartbeat; its inbox is
// still armed and the waiter resumes from <inbox>.cursor, so the line is queued.
const BUSY_SAY = "chief is busy, will pick up on next wait";
async function routeText(r: string, text: string) {
  const replies: string[] = [];
  await handleInbound(r, say(text), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  return replies.join("\n");
}

test("bare /chief queues to the only armed console whose waiter is stale within the busy TTL", async () => {
  const r = root(); const f = heartbeat(r, NAME, "waiting", 900);
  const reply = await routeText(r, "/chief halt the wave");
  expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] halt the wave");
  expect(reply).toContain("queued");
  expect(reply).toContain(BUSY_SAY);
});

test("a waiter that exited on a wake reason is busy, not released", async () => {
  const r = root(); const f = armInbox(r);
  writeFileSync(f + ".wait", `hb=${Math.floor(Date.now() / 1000) - 60} pid=123 key=- tick=ok state=exited exit=wake-tick\n`);
  const reply = await routeText(r, "/chief halt the wave");
  expect(readFileSync(f, "utf8")).toContain("halt the wave");
  expect(reply).toContain(BUSY_SAY);
});

test("a fleet verb queues to a busy console", async () => {
  const r = root(); const f = heartbeat(r, NAME, "sampling", 900); const replies: string[] = [];
  await inbound(r, fresh("/fleet"), replies);
  expect(readFileSync(f, "utf8")).toContain("] fleet status\n");
  expect(replies.join("\n")).toContain(BUSY_SAY);
});

test("a unique name fragment routes to its console and is stripped from the text", async () => {
  const r = root(); const a = heartbeat(r, "HIMMEL-nextleg-2026-10-10CO-roadmap-chief"); const b = heartbeat(r, "HIMMEL-nextleg-2026-10-10V-other-chief", "waiting", 900);
  for (const frag of ["CO", "roadmap-chi", "ROADMAP"]) {
    writeFileSync(a, ""); writeFileSync(b, "");
    const reply = await routeText(r, `/chief ${frag} do the thing`);
    expect(readFileSync(a, "utf8")).toContain("] do the thing");
    expect(readFileSync(a, "utf8")).not.toContain(frag + " do");
    expect(readFileSync(b, "utf8")).toBe("");
    expect(reply).toContain("roadmap-chief");
  }
});

test("an ambiguous fragment lists the candidates and sends nothing", async () => {
  const r = root(); const a = heartbeat(r, "x-chief-aa"); const b = heartbeat(r, "x-chief-bb");
  const reply = await routeText(r, "/chief console do it");
  expect(readFileSync(a, "utf8")).toBe("");
  expect(readFileSync(b, "utf8")).toBe("");
  expect(reply).toContain("x-chief-aa");
  expect(reply).toContain("x-chief-bb");
});

test("a dead or released console still bounces", async () => {
  const stale = (r: string) => heartbeat(r, NAME, "waiting", 4000);
  const released = (r: string) => { const f = armInbox(r); writeFileSync(f + ".wait", `hb=${Math.floor(Date.now() / 1000) - 60} pid=123 key=- tick=- state=exited exit=signal-TERM\n`); return f; };
  for (const mk of [stale, released]) {
    const r = root(); const f = mk(r); const replies: string[] = [];
    expect(await routeText(r, "/chief halt")).toContain("no live chief");
    await inbound(r, fresh("/fleet"), replies);
    expect(replies.join("\n")).toContain("no live chief");
    expect(readFileSync(f, "utf8")).toBe("");
  }
  const r = root();
  expect(await routeText(r, "/chief halt")).toContain("no live chief");
});

// A chief reply to a voice line is also spoken on the asking satellite.
const SAT = "assist_satellite.esp32_s3_box_3_a8c48c_assist_satellite";
const replyToSatellite = async (args: string[], env: Record<string, string> = {}) => {
  const seen: { url: string; auth: string | null; body: unknown }[] = [];
  const ha = Bun.serve({ port: 0, async fetch(req) { seen.push({ url: new URL(req.url).pathname, auth: req.headers.get("authorization"), body: await req.json() }); return Response.json([]); } });
  const r = root();
  try {
    const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", ...args], {
      env: { ...process.env, BRIDGE_ROOT: r, HA_URL: `http://127.0.0.1:${ha.port}`, HA_TOKEN: "t0k", ...env }, stdout: "pipe", stderr: "pipe",
    });
    const err = await new Response(p.stderr).text();
    const code = await p.exited;
    const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
    return { code, err, seen, line: existsSync(outbox) ? readFileSync(outbox, "utf8").trim() : null };
  } finally { ha.stop(true); }
};

test("reply --satellite: the answer goes to Telegram AND is announced on the asking satellite", async () => {
  const { code, seen, line } = await replyToSatellite(["--satellite", SAT, "1", "two", "PRs", "open"]);
  expect(code).toBe(0);
  expect(JSON.parse(line!)).toEqual({ text: "two PRs open", format: true });
  expect(seen).toEqual([{ url: "/api/services/assist_satellite/announce", auth: "Bearer t0k", body: { entity_id: SAT, message: "two PRs open" } }]);
});

test("reply --satellite: a non-satellite id is refused and nothing is announced", async () => {
  for (const bad of ["light.kitchen", "assist_satellite.x/../y", "../etc"]) {
    const { code, seen } = await replyToSatellite(["--satellite", bad, "1", "hi"]);
    expect(code).not.toBe(0);
    expect(seen).toEqual([]);
  }
});

test("reply --satellite: no HA token is an error after the Telegram reply is queued, never a silent drop", async () => {
  const { code, err, seen, line } = await replyToSatellite(["--satellite", SAT, "1", "hi"], { HA_TOKEN: "" });
  expect(code).not.toBe(0);
  expect(err).toContain("HA_TOKEN");
  expect(seen).toEqual([]);
  expect(JSON.parse(line!)).toEqual({ text: "hi", format: true });
});

test("reply without --satellite never calls Home Assistant", async () => {
  const { code, seen } = await replyToSatellite(["1", "plain"]);
  expect(code).toBe(0);
  expect(seen).toEqual([]);
});

// A project's chiefs share a lineage (<PREFIX>-nextleg-<date><letters>-<name>);
// the newest owns the operator's messages, so a handover never needs a typed session name.
const OLD = "HIMMEL-nextleg-2026-10-30KE-roadmap-chief";
const NEWEST = "HIMMEL-nextleg-2026-10-30KH-roadmap-chief";

test("bare /chief with two live chiefs of one lineage reaches the newest", async () => {
  for (const [older, newer] of [[OLD, NEWEST], ["HIMMEL-nextleg-2026-10-29Z-roadmap-chief", "HIMMEL-nextleg-2026-10-30A-roadmap-chief"], ["HIMMEL-nextleg-2026-10-30Z-roadmap-chief", "HIMMEL-nextleg-2026-10-30AA-roadmap-chief"]]) {
    for (const order of [[older, newer], [newer, older]]) {
      const r = root(); for (const n of order) heartbeat(r, n);
      for (const text of ["/chief halt the wave", "/chief halt"]) {
        for (const n of [older, newer]) writeFileSync(join(r, "consoles", `${n}.md`), "");
        const reply = await routeText(r, text);
        expect(readFileSync(join(r, "consoles", `${newer}.md`), "utf8")).toContain(`[telegram from=1 chat=1] ${text.slice(7)}`);
        expect(readFileSync(join(r, "consoles", `${older}.md`), "utf8")).toBe("");
        expect(reply).toContain(newer);
      }
    }
  }
});

test("two live chiefs of different lineages are still refused", async () => {
  const r = root(); heartbeat(r, NEWEST); heartbeat(r, "HIMMEL-nextleg-2026-10-30B-other-chief");
  const reply = await routeText(r, "/chief halt");
  expect(reply).toContain("More than one chief is live");
  expect(readFileSync(join(r, "consoles", `${NEWEST}.md`), "utf8")).toBe("");
});

test("an explicit name or unique fragment still pins the older chief", async () => {
  const r = root(); const old = heartbeat(r, OLD); heartbeat(r, NEWEST);
  await routeText(r, `/chief ${OLD} keep it`);
  expect(readFileSync(old, "utf8")).toContain("] keep it");
  writeFileSync(old, "");
  await routeText(r, "/chief KE keep it");
  expect(readFileSync(old, "utf8")).toContain("] keep it");
  expect(readFileSync(join(r, "consoles", `${NEWEST}.md`), "utf8")).toBe("");
});

test("the alias chief:himmel resolves to the newest chief across a simulated handover", async () => {
  const r = root(); const old = heartbeat(r, OLD);
  await routeText(r, "/chief chief:himmel before the handover");
  expect(readFileSync(old, "utf8")).toContain("[telegram from=1 chat=1] before the handover\n");
  writeFileSync(old, "");
  const next = heartbeat(r, NEWEST);
  const reply = await routeText(r, "/chief chief:HIMMEL after the handover");
  expect(readFileSync(next, "utf8")).toContain("[telegram from=1 chat=1] after the handover\n");
  expect(readFileSync(old, "utf8")).toBe("");
  expect(reply).toContain(NEWEST);
});

test("an alias with no live chief, or two lineages, queues nothing", async () => {
  const r = root(); const a = heartbeat(r, NEWEST); const b = heartbeat(r, "HIMMEL-nextleg-2026-10-30B-other-chief");
  expect(await routeText(r, "/chief chief:nobody hi")).toContain("no live chief");
  expect(await routeText(r, "/chief chief:himmel hi")).toContain("More than one chief");
  expect(readFileSync(a, "utf8")).toBe("");
  expect(readFileSync(b, "utf8")).toBe("");
});

async function tapHarness(r: string) {
  const { makeChiefTap } = await import("./chief-route");
  const answers: string[] = []; const prompts: { chat: number; text: string }[] = []; const pickers: { chat: number; markup: any }[] = [];
  const tap = makeChiefTap({
    root: r,
    authorize: (from, chat) => from === 1 && chat === 1,
    prompt: async (chat, text) => { prompts.push({ chat, text }); return 900 + prompts.length; },
    picker: async (chat, _text, markup) => { pickers.push({ chat, markup }); return true; },
    answer: async (_id, text) => { answers.push(text); },
  });
  return { tap, answers, prompts, pickers };
}
const tapOf = (data: string, extra: Record<string, unknown> = {}) => ({ callback_id: "cb1", from: 1, chat_id: 1, data, ...extra });

test("a Send-to-chief tap from outside allowFrom is refused and writes nothing", async () => {
  const r = root(); const old = heartbeat(r, OLD); const next = heartbeat(r, NEWEST);
  const { tap, answers, prompts, pickers } = await tapHarness(r);
  for (const extra of [{ from: 999 }, { chat_id: -99 }]) {
    expect(tap(tapOf("chief:send", extra))).toBe(true);
    expect(tap(tapOf("chief:pick", extra))).toBe(true);
    expect(tap(tapOf(`chief:to:${OLD}`, extra))).toBe(true);
  }
  await tap.idle();
  expect(answers).toEqual(Array(6).fill("Not authorized."));
  expect(prompts).toEqual([]);
  expect(pickers).toEqual([]);
  expect(readFileSync(old, "utf8")).toBe("");
  expect(readFileSync(next, "utf8")).toBe("");
});

test("an allowed Send-to-chief tap prompts for the text and the reply lands in the newest chief's inbox", async () => {
  const r = root(); const old = heartbeat(r, OLD); const next = heartbeat(r, NEWEST);
  const { tap, prompts } = await tapHarness(r);
  expect(tap(tapOf("chief:send"))).toBe(true);
  await tap.idle();
  expect(prompts).toHaveLength(1);
  expect(prompts[0].text).toContain(NEWEST);
  const replies: string[] = [];
  await handleInbound(r, fresh("status please", { reply_to_message_id: 901 }), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(next, "utf8")).toContain("[telegram from=1 chat=1 reply_to=901] status please\n");
  expect(readFileSync(old, "utf8")).toBe("");
});

test("the picker lists the newest chief first and a pick pins that chief", async () => {
  const r = root(); const old = heartbeat(r, OLD); heartbeat(r, NEWEST);
  const { tap, prompts, pickers } = await tapHarness(r);
  expect(tap(tapOf("chief:pick"))).toBe(true);
  await tap.idle();
  expect(pickers[0].markup.inline_keyboard.map((row: any[]) => row[0].callback_data)).toEqual([`chief:to:${NEWEST}`, `chief:to:${OLD}`]);
  expect(tap(tapOf(`chief:to:${OLD}`))).toBe(true);
  await tap.idle();
  expect(prompts[0].text).toContain(OLD);
  await handleInbound(r, fresh("old context please", { reply_to_message_id: 901 }), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(old, "utf8")).toContain("] old context please\n");
});

test("a tap that is not a chief button falls through, and with no live chief nothing is prompted", async () => {
  const r = root();
  const { tap, answers, prompts } = await tapHarness(r);
  expect(tap(tapOf("afk:approve:abcdefgh"))).toBe(false);
  expect(tap(tapOf("chief:send"))).toBe(true);
  await tap.idle();
  expect(answers).toEqual(["No live chief."]);
  expect(prompts).toEqual([]);
});

test("a first word matching several chiefs of one lineage stays in the text sent to the newest", async () => {
  const r = root(); const old = heartbeat(r, OLD); const next = heartbeat(r, NEWEST);
  await routeText(r, "/chief me first, then merge");
  expect(readFileSync(next, "utf8")).toContain("[telegram from=1 chat=1] me first, then merge\n");
  expect(readFileSync(old, "utf8")).toBe("");
});

test("an alias with no text after it queues nothing", async () => {
  const r = root(); const next = heartbeat(r, NEWEST);
  expect(await routeText(r, "/chief chief:himmel")).toContain("nothing was sent");
  expect(readFileSync(next, "utf8")).toBe("");
});

test("an allowed tap on a chief that is not live, or on a traversal name, is refused and appends nothing", async () => {
  const r = root(); const next = heartbeat(r, NEWEST); const dead = heartbeat(r, OLD, "waiting", 100000);
  const { tap, answers, prompts } = await tapHarness(r);
  expect(tap(tapOf(`chief:to:${OLD}`))).toBe(true);
  expect(tap(tapOf("chief:to:.."))).toBe(true);
  await tap.idle();
  expect(answers).toEqual(Array(2).fill("That chief is no longer live."));
  expect(prompts).toEqual([]);
  expect(readFileSync(dead, "utf8")).toBe("");
  expect(readFileSync(next, "utf8")).toBe("");
  expect(existsSync(join(r, "consoles", "replies"))).toBe(false);
});

test("a name outside the convention is its own lineage, never merged into a convention lineage", async () => {
  const r = root(); const a = heartbeat(r, "HIMMEL-roadmap-chief"); const b = heartbeat(r, "HIMMEL-nextleg-2026-10-30A-roadmap-chief");
  expect(await routeText(r, "/chief halt")).toContain("More than one chief is live");
  expect(readFileSync(a, "utf8")).toBe("");
  expect(readFileSync(b, "utf8")).toBe("");
});

test("an alias matches the chief's bucket, so a hyphenated project resolves", async () => {
  const r = root(); const f = heartbeat(r, "MYP-nextleg-2026-10-30A-roadmap-chief");
  writeFileSync(f + ".meta.json", JSON.stringify({ bucket: "my-project", project: "/repos/my-project" }));
  await routeText(r, "/chief chief:my-project hello");
  expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] hello\n");
});

// ---- send a file to Telegram (specs/plans as HTML) --------------
// All mocked: no real Bot API, no real bot token (the token below is a fake literal).
import { sendDocument } from "./telegram-api";
import { truncateSync } from "node:fs";

const seedIfNeeded = async (specs: string) => {
  if (!existsSync(specs) || existsSync(join(specs, "ledgers", "spec-rounds", "manifest.json"))) return;
  const { roundSeed } = await import("./chief-route");
  await roundSeed(specs).catch(() => {});
};
const sendFile = (r: string, ...args: string[]) => readSend(r, ...(args[0] === "--by-request" || args[0] === "--sign" ? args : ["--sign", ...args]));
const readSend = async (r: string, ...args: string[]) => {
  await seedIfNeeded(join(r, "specs"));
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "send-file", ...args], { env: { ...process.env, BRIDGE_ROOT: r }, stdout: "pipe", stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  const code = await p.exited;
  const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
  const lines = existsSync(outbox) ? readFileSync(outbox, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  return { code, err, lines };
};

test("sendDocument posts multipart sendDocument with chat_id, caption and the file bytes", async () => {
  const r = root(); const f = join(r, "plan.txt"); writeFileSync(f, "hello file");
  const seen: { url: string; method?: string; body?: any }[] = [];
  const fake = (async (url: string, init: any) => { seen.push({ url, method: init.method, body: init.body }); return new Response(JSON.stringify({ ok: true, result: { message_id: 9 } })); }) as unknown as typeof fetch;
  let mid = 0;
  expect(await sendDocument("123:FAKE", 42, f, "the caption", fake, async () => {}, (id) => { mid = id; })).toBe(true);
  expect(mid).toBe(9);
  expect(seen[0].url).toBe("https://api.telegram.org/bot123:FAKE/sendDocument");
  expect(seen[0].method).toBe("POST");
  expect(seen[0].body).toBeInstanceOf(FormData);
  expect(seen[0].body.get("chat_id")).toBe("42");
  expect(seen[0].body.get("caption")).toBe("the caption");
  const doc = seen[0].body.get("document") as File;
  expect(doc.name).toBe("plan.txt");
  expect(await doc.text()).toBe("hello file");
});

test("sendDocument drops a permanent 4xx (false, no retry) and omits an absent caption", async () => {
  const r = root(); const f = join(r, "a.bin"); writeFileSync(f, "x");
  let calls = 0; let cap: unknown = "unset";
  const fake = (async (_u: string, init: any) => { calls++; cap = init.body.get("caption"); return new Response(JSON.stringify({ ok: false, description: "bad" }), { status: 400 }); }) as unknown as typeof fetch;
  const errs = spyOn(console, "error").mockImplementation(() => {});
  expect(await sendDocument("123:FAKE", 42, f, undefined, fake, async () => {})).toBe(false);
  errs.mockRestore();
  expect(calls).toBe(1);
  expect(cap).toBeNull();
});

test("sendDocument returns false, never throws, for a file that vanished after the caller's check", async () => {
  let calls = 0;
  const fake = (async () => { calls++; return new Response("{}"); }) as unknown as typeof fetch;
  const errs = spyOn(console, "error").mockImplementation(() => {});
  expect(await sendDocument("123:FAKE", 42, join(root(), "gone.txt"), undefined, fake, async () => {})).toBe(false);
  errs.mockRestore();
  expect(calls).toBe(0);
});

test("an outbox line with document_path is delivered via the document sender; text lines are unchanged", async () => {
  const r = root(); await ensureSession(r, "__chat__");
  await writeMeta(r, "__chat__", { chat_id: 5, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  const out = join(sessionDir(r, "__chat__"), "outbox.jsonl");
  await appendLine(out, JSON.stringify({ text: "plain" }));
  await appendLine(out, JSON.stringify({ document_path: "/x/spec.txt", caption: "the spec" }));
  const texts: any[] = []; const docs: any[] = [];
  await flushOutboxes(r, async (chat, text) => { texts.push([chat, text]); }, async (chat, path, caption) => { docs.push([chat, path, caption]); return true; });
  expect(texts).toEqual([[5, "plain"]]);
  expect(docs).toEqual([[5, "/x/spec.txt", "the spec"]]);
});

test("a document the sender could not deliver tells the chat instead of vanishing", async () => {
  const r = root(); await ensureSession(r, "__chat__");
  await writeMeta(r, "__chat__", { chat_id: 5, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  await appendLine(join(sessionDir(r, "__chat__"), "outbox.jsonl"), JSON.stringify({ document_path: "/x/spec.html" }));
  const texts: string[] = [];
  await flushOutboxes(r, async (_c, text) => { texts.push(text); }, async () => false);
  expect(texts.length).toBe(1);
  expect(texts[0]).toContain("spec.html");
});

test("the poller's document sender uploads only a regular file inside <bridge root>/outgoing within 50 MB", async () => {
  const { makeSendDoc } = await import("./poller");
  const r = root(); const out = join(r, "outgoing"); mkdirSync(out);
  const ok = join(out, "a.txt"); writeFileSync(ok, "a");
  const big = join(out, "big.bin"); writeFileSync(big, ""); truncateSync(big, 50 * 1024 * 1024 + 1);
  const uploads: any[] = [];
  const send = makeSendDoc("123:FAKE", r, 7, (async (...a: any[]) => { uploads.push(a); return true; }) as any);
  expect(await send(7, ok, "cap")).toBe(true);
  expect(await send(8, ok, "cap")).toBe(false);   // not the operator's chat
  expect(await makeSendDoc("123:FAKE", r, null, (async () => true) as any)(7, ok)).toBe(false);   // no operator chat known
  expect(uploads.length).toBe(1);
  expect(uploads[0].slice(0, 2)).toEqual(["123:FAKE", 7]);
  expect(uploads[0][3]).toBe("cap");
  for (const bad of ["relative/a.txt", out, big, join(out, "gone.txt")]) expect(await send(7, bad)).toBe(false);
  expect(uploads.length).toBe(1);
});

test("the poller's document sender refuses a path outside the root and a symlink that points out of it", async () => {
  const { makeSendDoc } = await import("./poller");
  const r = root(); const out = join(r, "outgoing"); mkdirSync(out);
  const secret = join(r, "secret.env"); writeFileSync(secret, "TOKEN=x");
  const link = join(out, "link.txt"); symlinkSync(secret, link);
  const dirLink = join(out, "dir"); symlinkSync(r, dirLink);
  const sibling = join(r, "outgoing-evil"); mkdirSync(sibling); writeFileSync(join(sibling, "a.txt"), "a");
  const uploads: any[] = [];
  const send = makeSendDoc("123:FAKE", r, 7, (async (...a: any[]) => { uploads.push(a); return true; }) as any);
  for (const bad of [secret, link, join(dirLink, "secret.env"), join(sibling, "a.txt"), join(out, "..", "secret.env")]) expect(await send(7, bad)).toBe(false);
  expect(uploads).toEqual([]);
});

test("the poller's document sender uploads the bytes it validated, even if the path is swapped for a symlink afterwards", async () => {
  const { makeSendDoc } = await import("./poller");
  const r = root(); const out = join(r, "outgoing"); mkdirSync(out);
  const f = join(out, "a.txt"); writeFileSync(f, "validated");
  const secret = join(r, "secret.env"); writeFileSync(secret, "TOKEN=x");
  let got = "";
  const send = makeSendDoc("123:FAKE", r, 7, (async (_t: string, _c: number, src: any) => {
    unlinkSync(f); symlinkSync(secret, f);   // the swap lands after the checks, before the upload reads anything
    got = typeof src === "string" ? readFileSync(src, "utf8") : Buffer.from(src.bytes).toString("utf8");
    return true;
  }) as any);
  expect(await send(7, f)).toBe(true);
  expect(got).toBe("validated");
});

test("a parent directory swapped for a symlink between the check and the open uploads nothing", async () => {
  const { makeSendDoc } = await import("./poller");
  const r = root(); const out = join(r, "outgoing"); mkdirSync(join(out, "sub"), { recursive: true });
  writeFileSync(join(out, "sub", "a.txt"), "inside");
  const elsewhere = join(r, "elsewhere"); mkdirSync(elsewhere); writeFileSync(join(elsewhere, "a.txt"), "OUTSIDE");
  const uploads: any[] = [];
  const swap = async () => { renameSync(join(out, "sub"), join(out, "sub.moved")); symlinkSync(elsewhere, join(out, "sub")); };
  const send = makeSendDoc("123:FAKE", r, 7, (async (...a: any[]) => { uploads.push(a); return true; }) as any, swap);
  expect(await send(7, join(out, "sub", "a.txt"))).toBe(false);
  expect(uploads).toEqual([]);
});

test("a ticket session running in a group chat (negative chat id, ordinary name) never sends a file", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-5");
  await writeMeta(r, "HIMMEL-5", { chat_id: -50, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  await appendLine(join(sessionDir(r, "HIMMEL-5"), "outbox.jsonl"), JSON.stringify({ document_path: join(r, "outgoing", "a.txt") }));
  const texts: string[] = []; let docs = 0;
  await flushOutboxes(r, async (_c, text) => { texts.push(text); }, async () => { docs++; return true; });
  expect(docs).toBe(0);
  expect(texts.length).toBe(1);
});

test("a document line in a group session is refused and never reaches the document sender", async () => {
  const r = root(); await ensureSession(r, "group_-50");
  await writeMeta(r, "group_-50", { chat_id: -50, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  await appendLine(join(sessionDir(r, "group_-50"), "outbox.jsonl"), JSON.stringify({ document_path: join(r, "outgoing", "a.txt") }));
  const texts: string[] = []; let docs = 0;
  await flushOutboxes(r, async (_c, text) => { texts.push(text); }, async () => { docs++; return true; });
  expect(docs).toBe(0);
  expect(texts.length).toBe(1);
});

test("a line carrying both text and document_path sends the text and the document", async () => {
  const r = root(); await ensureSession(r, "__chat__");
  await writeMeta(r, "__chat__", { chat_id: 5, status: "idle", last_run_pid: null, last_run_at: null, task_name: null });
  await appendLine(join(sessionDir(r, "__chat__"), "outbox.jsonl"), JSON.stringify({ text: "here it is", document_path: "/x/spec.txt" }));
  const texts: string[] = []; const docs: string[] = [];
  await flushOutboxes(r, async (_c, text) => { texts.push(text); }, async (_c, path) => { docs.push(path); return true; });
  expect(texts).toEqual(["here it is"]);
  expect(docs).toEqual(["/x/spec.txt"]);
});

test("the bridge prompt offers the document channel to a private chat and not to a group", () => {
  const paths = { inbox: "/b/sessions/s/in.jsonl", outbox: "/b/sessions/s/outbox.jsonl", context: "c", cwd: "/r" };
  expect(buildPrompt("__chat__", paths)).toContain("/b/outgoing");
  expect(buildPrompt("group_-50", paths)).not.toContain("outgoing");
  expect(buildPrompt("HIMMEL-5", paths, null, false, -50)).not.toContain("outgoing");   // a ticket session in a group
  expect(buildPrompt("HIMMEL-5", paths, null, false, 5)).toContain("outgoing");
});

test("send-file copies a plain file into <bridge root>/outgoing and queues the copy", async () => {
  const r = root(); const f = join(r, "notes.txt"); writeFileSync(f, "n");
  const res = await sendFile(r, "1", f, "see", "this");
  expect(res.code).toBe(0);
  expect(res.lines.length).toBe(1);
  const queued = res.lines[0].document_path as string;
  expect(res.lines[0].caption).toBe("see this");
  expect(queued.startsWith(join(r, "outgoing") + "/")).toBe(true);
  expect(basename(queued)).toBe("notes.txt");
  expect(readFileSync(queued, "utf8")).toBe("n");
});

test("send-file renders a markdown spec to a standalone HTML file and queues that", async () => {
  const r = root(); const f = join(r, "spec.md"); writeFileSync(f, "# Title <b>\n\n| a | b |\n|---|---|\n| 1 | 2 |\n");
  const res = await sendFile(r, "1", f);
  expect(res.code).toBe(0);
  const path = res.lines[0].document_path as string;
  expect(path.endsWith(".html")).toBe(true);
  const html = readFileSync(path, "utf8");
  expect(html).toContain("<!doctype html>");
  expect(html).toContain("<h1>");
  expect(html).toContain("<table>");
  expect(html).toContain('name="viewport"');
  expect(html).not.toContain("<b>");   // raw html in the markdown is not passed through
});

test("send-file refuses a missing file, a directory and an oversize file before queuing anything", async () => {
  const r = root(); const big = join(r, "big.bin"); writeFileSync(big, ""); truncateSync(big, 50 * 1024 * 1024 + 1);
  const missing = await sendFile(r, "1", join(r, "nope.txt"));
  const dir = await sendFile(r, "1", r);
  const over = await sendFile(r, "1", big);
  for (const x of [missing, dir, over]) { expect(x.code).not.toBe(0); expect(x.lines).toEqual([]); }
  expect(missing.err).toContain("not found");
  expect(over.err).toContain("50 MB");
});

// ---- a spec or plan page reaches the operator only after its latest critics passed those exact bytes ----
import { createHash } from "node:crypto";

const sha = (s: string) => createHash("sha256").update(s).digest("hex");
const critic = (spec: string, kind: "spec" | "plan", round: number, verdict: string, sealed?: { text: string; file: string }) =>
  writeFileSync(`${spec}.critic-${kind}-r${round}.md`, `critic return, round ${round}\n${sealed ? `CONTENT-SHA256 ${sha(sealed.text)} ${sealed.file}\n` : ""}${verdict}\n`);

const bundle = (r: string) => {
  const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const spec = join(dir, "HIMMEL-1-design.md"); const plan = join(dir, "HIMMEL-1-design.plan.md");
  writeFileSync(spec, "# Design\n\nthe spec\n"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(spec, "spec", 1, "SPEC CLEAN", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });
  critic(spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "HIMMEL-1-design.plan.md" });
  return { dir, spec, plan };
};

test("send-file refuses a spec whose latest spec critic is NO-GO, names that verdict file and queues nothing", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 3", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

test("send-file reads the highest round numerically: r10 findings beat a clean r9", async () => {
  const r = root(); const b = bundle(r);
  const sealed = { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" };
  critic(b.spec, "spec", 9, "SPEC CLEAN", sealed); critic(b.spec, "spec", 10, "SPEC FINDINGS 1", sealed);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);   // past the three rounds the page goes with its findings on it, and r10 is the one it shows
  expect(res.lines[0].caption).toContain("SPEC FINDINGS 1 r10");
  expect(readFileSync(res.lines[0].document_path as string, "utf8")).toContain("design.md.critic-spec-r10.md");
});

test("send-file refuses a plan whose latest plan critic is NO-GO, naming the plan verdict file", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "plan", 2, "PLAN FINDINGS 2", { text: "# Plan\n\nthe plan\n", file: "HIMMEL-1-design.plan.md" });
  for (const f of [b.spec, b.plan]) {
    const res = await sendFile(r, "1", f);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain("design.md.critic-plan-r2.md");
    expect(res.lines).toEqual([]);
  }
});

test("send-file refuses a spec under specs/ with no critic file, and one with no plan critic", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const spec = join(dir, "x.md"); writeFileSync(spec, "# X\n");
  const none = await sendFile(r, "1", spec);
  expect(none.code).not.toBe(0);
  expect(none.err).toContain("critic-spec");
  critic(spec, "spec", 1, "SPEC CLEAN", { text: "# X\n", file: "x.md" });
  const noPlan = await sendFile(r, "1", spec);
  expect(noPlan.code).not.toBe(0);
  expect(noPlan.err).toContain("critic-plan");
  expect(none.lines.concat(noPlan.lines)).toEqual([]);
});

const DRAFT_CAPTION = "DRAFT, not for signing";
const signSend = (r: string, ...args: string[]) => sendFile(r, "--sign", ...args);

test("read send: a plain report under specs/ sends as it is, with no mark and no verdict", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  for (const [name, text] of [["weekly-report.txt", "the report\n"], ["status-report.md", "# Status\n\nplain\n"]]) {
    const f = join(dir, name); writeFileSync(f, text);
    const res = await readSend(r, "1", f, "the report you asked for");
    expect(res.err).toBe("");
    expect(res.code).toBe(0);
    expect(res.lines.at(-1)!.caption).toBe("the report you asked for");
    expect(readFileSync(res.lines.at(-1)!.document_path as string, "utf8")).not.toContain("DRAFT");
  }
});

test("read send: an unsealed spec goes marked DRAFT in the caption and on the page, for .md and .html", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const md = join(dir, "HIMMEL-2-notes.md"); writeFileSync(md, "# Notes\n\nunsealed\n");
  const html = join(dir, "HIMMEL-2-notes.exec-brief.html"); writeFileSync(html, BRIEF);
  const a = await readSend(r, "1", md, "to read");
  expect(a.err).toBe(""); expect(a.code).toBe(0);
  expect(a.lines[0].caption).toBe(`${DRAFT_CAPTION} - to read`);
  expect(readFileSync(a.lines[0].document_path as string, "utf8")).toContain(DRAFT_CAPTION);
  const b = await readSend(r, "1", html);
  expect(b.err).toBe(""); expect(b.code).toBe(0);
  expect(b.lines[1].caption).toBe(DRAFT_CAPTION);
  const sent = readFileSync(b.lines[1].document_path as string, "utf8");
  expect(sent).toContain(DRAFT_CAPTION);
  expect(sent).toContain("the executive brief");
});

test("sign ask: an unsealed spec refuses and queues nothing, and a sealed spec sends with its verdicts", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const md = join(dir, "HIMMEL-2-notes.md"); writeFileSync(md, "# Notes\n\nunsealed\n");
  const no = await signSend(r, "1", md);
  expect(no.code).not.toBe(0);
  expect(no.err).toContain("has no spec critic file");
  expect(no.lines).toEqual([]);
  expect(existsSync(join(r, "outgoing"))).toBe(false);
  const r2 = root(); const b = bundle(r2);
  const yes = await signSend(r2, "1", b.spec, "to sign");
  expect(yes.err).toBe(""); expect(yes.code).toBe(0);
  expect(yes.lines[0].caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1 - to sign");
  expect(readFileSync(yes.lines[0].document_path as string, "utf8")).not.toContain(DRAFT_CAPTION);
  const read = await readSend(r2, "1", b.spec);
  expect(read.lines.at(-1)!.caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1");
});

test("read send: a spec edited after its clean critic goes marked DRAFT in the caption and on the page, while the sign ask on it refuses", async () => {
  const r = root(); const b = bundle(r);
  writeFileSync(b.spec, "# Design\n\nthe spec, edited after the critic\n");
  const read = await readSend(r, "1", b.spec);
  expect(read.err).toBe(""); expect(read.code).toBe(0);
  expect(read.lines[0].caption).toBe(DRAFT_CAPTION);
  expect(readFileSync(read.lines[0].document_path as string, "utf8")).toContain(DRAFT_CAPTION);
  const sign = await signSend(r, "1", b.spec);
  expect(sign.code).not.toBe(0);
  expect(sign.err).toContain("changed since the spec critic read it");
  expect(sign.lines.length).toBe(1);
});

test("read send: a spec whose critic ended in findings goes marked DRAFT; --sign and --by-request together are refused", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });
  const open = await readSend(r, "1", b.spec);
  expect(open.err).toBe(""); expect(open.code).toBe(0);
  expect(open.lines[0].caption).toBe(DRAFT_CAPTION);
  const both = await sendFile(r, "--sign", "--by-request", "he asked", "1", b.spec);
  expect(both.code).not.toBe(0);
  expect(both.err).toContain("--sign and --by-request");
  expect(both.lines.length).toBe(1);
});

test("send-file refuses a spec or plan edited after a clean critic read", async () => {
  const r = root(); const b = bundle(r);
  writeFileSync(b.spec, "# Design\n\nthe spec, edited\n");
  const s = await sendFile(r, "1", b.spec);
  expect(s.code).not.toBe(0);
  expect(s.err).toContain("design.md.critic-spec-r1.md");
  writeFileSync(b.spec, "# Design\n\nthe spec\n");
  writeFileSync(b.plan, "# Plan\n\nthe plan, edited\n");
  const p = await sendFile(r, "1", b.plan);
  expect(p.code).not.toBe(0);
  expect(p.err).toContain("design.md.critic-plan-r1.md");
  expect(s.lines.concat(p.lines)).toEqual([]);
});

test("send-file refuses a verdict file with no CONTENT-SHA256 line", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC CLEAN");
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("CONTENT-SHA256");
  expect(res.err).toContain("critic-spec-r2.md");
  expect(res.lines).toEqual([]);
});

test("send-file sends a clean spec and plan; the rendered page shows the verdict lines read from the files", async () => {
  const r = root(); const b = bundle(r);
  for (const f of [b.spec, b.plan]) {
    const res = await sendFile(r, "1", f, "a caption that says SPEC CLEAN");
    expect(res.code).toBe(0);
  }
  const outbox = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  expect(outbox.length).toBe(2);
  const html = readFileSync(outbox[0].document_path, "utf8");
  expect(html).toContain("SPEC CLEAN");
  expect(html).toContain("PLAN CLEAN");
  expect(html).toContain("design.md.critic-spec-r1.md");
  expect(html).toContain("design.md.critic-plan-r1.md");
  expect(html.indexOf("SPEC CLEAN")).toBeLessThan(html.indexOf("<h1>"));   // the verdict line sits above the page body
});

test("send-file still sends a report, a log and a specs/ audit with no critic files, and adds no verdict line", async () => {
  const r = root();
  const files = [join(r, "reports", "r.md"), join(r, "logs", "run.log"), join(r, "specs", "audits", "a.md")];
  for (const f of files) { mkdirSync(join(f, ".."), { recursive: true }); writeFileSync(f, "# Report\n"); }
  for (const f of files) {
    const res = await sendFile(r, "1", f);
    expect(res.code).toBe(0);
    const q = res.lines.at(-1)!.document_path as string;
    expect(readFileSync(q, "utf8")).not.toContain("CLEAN");
  }
});

test("send-file treats a symlink into a specs/ design path as a spec", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });
  const link = join(r, "innocent.md"); symlinkSync(b.spec, link);
  const res = await sendFile(r, "1", link);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
});

test("send-file finds the plan critic beside the spec when the plan lives in specs/plans/, and refuses it on a NO-GO", async () => {
  const r = root(); const b = bundle(r);
  const plans = join(r, "specs", "plans"); mkdirSync(plans);
  const plan = join(plans, "HIMMEL-1-design.plan.md"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(b.spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "../plans/HIMMEL-1-design.plan.md" });
  const ok = await sendFile(r, "1", plan);
  expect(ok.code).toBe(0);
  critic(b.spec, "plan", 2, "PLAN FINDINGS 1", { text: "# Plan\n\nthe plan\n", file: "../plans/HIMMEL-1-design.plan.md" });
  const no = await sendFile(r, "1", plan);
  expect(no.code).not.toBe(0);
  expect(no.err).toContain("design.md.critic-plan-r2.md");
  expect(no.lines.length).toBe(1);   // only the first send queued
});

test("checkSignaturePage hands back the exact bytes it hashed, so the page sent is the page the critic read", async () => {
  const { checkSignaturePage } = await import("./chief-route");
  const r = root(); const b = bundle(r); await seedIfNeeded(join(r, "specs"));
  const res = await checkSignaturePage(b.spec);
  expect(res!.bytes.toString("utf8")).toBe("# Design\n\nthe spec\n");
  expect(await checkSignaturePage(join(r, "elsewhere.txt"))).toBeNull();
});

const SEAL_SH =join(import.meta.dir, "..", "handover", "chief-kit", "critic-seal.sh");
const seal = async (...args: string[]) => {
  const p = Bun.spawn([BASH_BIN, SEAL_SH, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: await p.exited, err: await new Response(p.stderr).text() };
};

const D_FM = "---\ntickets: HIMMEL-1\n---\n# D\n";
const sealSpec = async (r: string) => {
  const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const spec = join(dir, "HIMMEL-1-d.md"); writeFileSync(spec, D_FM);
  await seedIfNeeded(join(r, "specs"));
  return { dir, spec };
};

test("critic-seal.sh adds the CONTENT-SHA256 line above the verdict line, and refuses a file that no longer hashes to the quoted sha", async () => {
  const r = root(); const { spec } = await sealSpec(r);
  const v = `${spec}.critic-spec-r1.md`; writeFileSync(v, `the critic's return, which read ${sha(D_FM)}\nSPEC CLEAN\n`);
  const ok = await seal(v, spec, sha(D_FM));
  expect(ok.code).toBe(0);
  expect(readFileSync(v, "utf8")).toBe(`the critic's return, which read ${sha(D_FM)}\nCONTENT-SHA256 ${sha(D_FM)} HIMMEL-1-d.md\nSPEC CLEAN\n`);
  expect((await seal(v, spec, sha(D_FM))).code).not.toBe(0);   // the same file sealed twice is refused, not stacked
  const staleSha = sha("# D, as the critic read it\n");
  const v2 = `${spec}.critic-spec-r2.md`; writeFileSync(v2, `return quoting ${staleSha}\nSPEC CLEAN\n`);
  const stale = await seal(v2, spec, staleSha);
  expect(stale.code).not.toBe(0);
  expect(readFileSync(v2, "utf8")).toBe(`return quoting ${staleSha}\nSPEC CLEAN\n`);   // nothing written
  const v3 = `${spec}.critic-spec-r3.md`; writeFileSync(v3, `return with no verdict line ${sha(D_FM)}\n`);
  expect((await seal(v3, spec, sha(D_FM))).code).not.toBe(0);
});

test("critic-seal.sh refuses a sha the critic's return never quoted, even when the file on disk hashes to it", async () => {
  const r = root(); const spec = join(r, "specs", "designs", "d.md"); mkdirSync(join(r, "specs", "designs"), { recursive: true });
  writeFileSync(spec, "# D, edited after the critic read it\n");
  const v = `${spec}.critic-spec-r1.md`; writeFileSync(v, `return quoting ${sha("# D\n")}\nSPEC CLEAN\n`);
  const res = await seal(v, spec, sha("# D, edited after the critic read it\n"));
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("does not quote");
  expect(readFileSync(v, "utf8")).toBe(`return quoting ${sha("# D\n")}\nSPEC CLEAN\n`);
});

test("critic-seal.sh seals a verdict file larger than a pipe buffer whose quoted sha sits on its first line", async () => {
  const r = root(); const { spec } = await sealSpec(r);
  const v = `${spec}.critic-spec-r1.md`;
  writeFileSync(v, `read ${sha(D_FM)}\n${"a long finding line\n".repeat(20000)}SPEC CLEAN\n`);   // about 400 KB
  const res = await seal(v, spec, sha(D_FM));
  expect(res.err).toBe("");
  expect(res.code).toBe(0);
  expect(readFileSync(v, "utf8")).toContain(`CONTENT-SHA256 ${sha(D_FM)} HIMMEL-1-d.md\nSPEC CLEAN\n`);
});

test("critic-seal.sh seals each distinct file a critic read, and refuses only the same file twice", async () => {
  const r = root(); const { dir, spec: md } = await sealSpec(r);
  const html = join(dir, "HIMMEL-1-d.html"); writeFileSync(html, "<h1>D</h1>\n");
  const v = `${md}.critic-spec-r1.md`; writeFileSync(v, `read ${sha(D_FM)} and ${sha("<h1>D</h1>\n")}\nSPEC CLEAN\n`);
  expect((await seal(v, md, sha(D_FM))).code).toBe(0);
  expect((await seal(v, html, sha("<h1>D</h1>\n"))).code).toBe(0);
  expect((await seal(v, html, sha("<h1>D</h1>\n"))).code).not.toBe(0);
  const lines = readFileSync(v, "utf8").split("\n");
  expect(lines.filter((l) => l.startsWith("CONTENT-SHA256 "))).toEqual([`CONTENT-SHA256 ${sha(D_FM)} HIMMEL-1-d.md`, `CONTENT-SHA256 ${sha("<h1>D</h1>\n")} HIMMEL-1-d.html`]);
  expect(lines.at(-2)).toBe("SPEC CLEAN");
});

const BRIEF = "<!doctype html><html><head><title>brief</title></head><body>\n<p>the executive brief</p>\n</body></html>\n";
const companion = (dir: string, text = BRIEF, verdict = "PAGE CLEAN") => {
  const page = join(dir, "HIMMEL-1-design.exec-brief.html"); writeFileSync(page, text);
  writeFileSync(`${page}.critic-page-r1.md`, `page critic return, read ${sha(text)}\nCONTENT-SHA256 ${sha(text)} HIMMEL-1-design.exec-brief.html\n${verdict}\n`);
  return page;
};

test("send-file sends a companion page of a sealed spec once a page critic passed its bytes, with both verdicts in the caption", async () => {
  const r = root(); const b = bundle(r); const page = companion(b.dir);
  const res = await sendFile(r, "1", page);
  expect(res.err).toBe("");
  expect(res.code).toBe(0);
  expect(res.lines[0].caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1 | PAGE CLEAN r1");
  expect(readFileSync(res.lines[0].document_path as string, "utf8")).toBe(BRIEF);
});

test("send-file refuses a companion page of a sealed spec that has no page critic, naming the page critic file and the command that seals it", async () => {
  const r = root(); const b = bundle(r);
  const page = join(b.dir, "HIMMEL-1-design.exec-brief.html"); writeFileSync(page, BRIEF);
  const res = await sendFile(r, "1", page);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
  expect(res.err).toContain("companion page of HIMMEL-1-design.md and has no page critic file (");
  expect(res.err).toContain("HIMMEL-1-design.exec-brief.html.critic-page-r<n>.md");
  expect(res.err).toContain("bash scripts/handover/chief-kit/critic-seal.sh");
  expect(res.err).not.toContain("spec critic file");
});

test("send-file refuses a companion page whose parent spec has no sealed critic, naming the parent's critic file even when the page critic passed", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "HIMMEL-1-design.md"), "# Design\n\nthe spec\n");
  const page = companion(dir);
  const res = await sendFile(r, "1", page);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
  expect(res.err).toContain("companion page of HIMMEL-1-design.md, and its parent seal is missing");
  expect(res.err).toContain("HIMMEL-1-design.md.critic-spec-r<n>.md");
});

test("send-file refuses a companion page edited after its page critic read it, and one whose page critic did not end PAGE CLEAN", async () => {
  const r = root(); const b = bundle(r); const page = companion(b.dir);
  writeFileSync(page, BRIEF.replace("executive brief", "executive brief, edited"));
  const edited = await sendFile(r, "1", page);
  expect(edited.code).not.toBe(0);
  expect(edited.err).toContain("HIMMEL-1-design.exec-brief.html changed since the page critic read it");
  companion(b.dir, BRIEF, "PAGE FINDINGS 1");
  const findings = await sendFile(r, "1", page);
  expect(findings.code).not.toBe(0);
  expect(findings.err).toContain("critic-page-r1.md: the latest page critic ended 'PAGE FINDINGS 1', not 'PAGE CLEAN'");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

const pageCritic = (page: string, round: string, verdict: string, sealed = [{ text: BRIEF, file: basename(page) }]) =>
  writeFileSync(`${page}.critic-page-${round}.md`, `page critic return\n${sealed.map((s) => `CONTENT-SHA256 ${sha(s.text)} ${s.file}\n`).join("")}${verdict}\n`);

test("send-file refuses a companion page whose PAGE CLEAN page critic seals another file, or seals nothing", async () => {
  const r = root(); const b = bundle(r); const page = companion(b.dir);
  pageCritic(page, "r1", "PAGE CLEAN", [{ text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" }]);
  const other = await sendFile(r, "1", page);
  expect(other.code).not.toBe(0);
  expect(other.err).toContain("critic-page-r1.md has no CONTENT-SHA256 line naming HIMMEL-1-design.exec-brief.html");
  pageCritic(page, "r1", "PAGE CLEAN", []);
  const none = await sendFile(r, "1", page);
  expect(none.code).not.toBe(0);
  expect(none.err).toContain("critic-page-r1.md has no CONTENT-SHA256 line naming HIMMEL-1-design.exec-brief.html");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

test("send-file reads the highest page critic round: an r2 PAGE FINDINGS beats a clean r1", async () => {
  const r = root(); const b = bundle(r); const page = companion(b.dir);
  pageCritic(page, "r2", "PAGE FINDINGS 1");
  const res = await sendFile(r, "1", page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("critic-page-r2.md: the latest page critic ended 'PAGE FINDINGS 1', not 'PAGE CLEAN'");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

test("send-file refuses two page critic files of one round", async () => {
  const r = root(); const b = bundle(r); const page = companion(b.dir);
  pageCritic(page, "r01", "PAGE CLEAN");
  const res = await sendFile(r, "1", page);
  expect(res.code).not.toBe(0);
  const name = basename(page);
  expect(res.err).toContain(`${name} has 2 page critic files of round 1 (${name}.critic-page-r01.md, ${name}.critic-page-r1.md)`);
});

for (const round of ["r0", "r01", "r02"]) {
  test(`send-file refuses a page critic file named ${round}, a round name the canonical-verdict-names fixture refuses`, async () => {
    const r = root(); const b = bundle(r); const page = companion(b.dir);
    rmSync(`${page}.critic-page-r1.md`);
    pageCritic(page, round, "PAGE CLEAN");
    const res = await sendFile(r, "1", page);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(`critic-page-${round}.md: is not a page critic name send-file reads`);
    expect(existsSync(join(r, "outgoing"))).toBe(false);
  });
}

test("critic-seal.sh seals a PAGE CLEAN page critic return and never moves the parent spec's round ledger, and refuses a page critic file that ends in a spec verdict", async () => {
  const r = root(); const { dir, spec } = await sealSpec(r);
  const v = `${spec}.critic-spec-r1.md`; writeFileSync(v, `read ${sha(D_FM)}\nSPEC CLEAN\n`);
  expect((await seal(v, spec, sha(D_FM))).code).toBe(0);
  const { readdirSync } = await import("node:fs");
  const ledgerRoot = join(r, "specs", "ledgers");
  const ledger = () => (readdirSync(ledgerRoot, { recursive: true }) as string[]).sort().filter((n) => statSync(join(ledgerRoot, n)).isFile()).map((n) => [n, readFileSync(join(ledgerRoot, n), "utf8")]);
  const before = { status: (await routeCli("round-status", "HIMMEL-1", "--specs", join(r, "specs"))).out, ledger: ledger() };
  expect(before.status).not.toBe("");
  const page = join(dir, "HIMMEL-1-d.exec-brief.html"); writeFileSync(page, BRIEF);
  const pv = `${page}.critic-page-r1.md`; writeFileSync(pv, `page critic return, read ${sha(BRIEF)}\nPAGE CLEAN\n`);
  const ok = await seal(pv, page, sha(BRIEF));
  expect(ok.err).toBe("");
  expect(ok.code).toBe(0);
  expect(readFileSync(pv, "utf8")).toBe(`page critic return, read ${sha(BRIEF)}\nCONTENT-SHA256 ${sha(BRIEF)} HIMMEL-1-d.exec-brief.html\nPAGE CLEAN\n`);
  const pv2 = `${page}.critic-page-r2.md`; writeFileSync(pv2, `page critic return, read ${sha(BRIEF)}\nSPEC CLEAN\n`);
  const wrong = await seal(pv2, page, sha(BRIEF));
  expect(wrong.code).not.toBe(0);
  expect(wrong.err).toContain("not PAGE CLEAN or PAGE FINDINGS <n>");
  const sv = `${spec}.critic-spec-r2.md`; writeFileSync(sv, `read ${sha(D_FM)}\nPAGE CLEAN\n`);
  expect((await seal(sv, spec, sha(D_FM))).code).not.toBe(0);
  rmSync(sv);
  expect({ status: (await routeCli("round-status", "HIMMEL-1", "--specs", join(r, "specs"))).out, ledger: ledger() }).toEqual(before);
});

// A spec critic that read several files seals each one.
const criticSeals = (spec: string, kind: "spec" | "plan", round: number, verdict: string, sealed: { text: string; file: string }[]) =>
  writeFileSync(`${spec}.critic-${kind}-r${round}.md`, `critic return, round ${round}\n${sealed.map((s) => `CONTENT-SHA256 ${sha(s.text)} ${s.file}\n`).join("")}${verdict}\n`);
const ledgerSeals = async (r: string, spec: string, kind: "spec" | "plan", round: number, verdict: string, sealed: { text: string; file: string }[]) => {
  await seedIfNeeded(join(r, "specs"));
  criticSeals(spec, kind, round, verdict, sealed);
  const { sealRound } = await import("./chief-route");
  const v = `${spec}.critic-${kind}-r${round}.md`;
  for (const s of sealed) await sealRound(v, join(spec, "..", s.file));
};

test("send-file refuses a spec critic that seals another path than the spec", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC CLEAN", { text: "# Plan\n\nthe plan\n", file: "HIMMEL-1-design.plan.md" });
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(res.err).toContain("does not seal HIMMEL-1-design.md");
  expect(res.lines).toEqual([]);
});

test("send-file refuses a plan page while the spec critic failed", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });
  const res = await sendFile(r, "1", b.plan);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(res.lines).toEqual([]);
});

test("send-file matches a plan page named by an OLDER plan critic round, even outside the listed folders", async () => {
  const r = root(); const b = bundle(r);
  const other = join(r, "specs", "other"); mkdirSync(other);   // not one of the listed folders
  const plan = join(other, "plan.md"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(b.spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "../other/plan.md" });
  critic(b.spec, "plan", 2, "PLAN FINDINGS 1");   // the newest round seals nothing
  const res = await sendFile(r, "1", plan);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-plan-r2.md");
  expect(res.lines).toEqual([]);
});

test("send-file refuses, naming the file, when a critic file it must read is unreadable", async () => {
  if (process.getuid?.() === 0) return;   // root reads a mode-000 file, so the row cannot make it unreadable
  const { chmodSync } = await import("node:fs");
  const r = root(); const b = bundle(r);
  const other = join(b.dir, "notes.md"); writeFileSync(other, "# Notes\n");
  const unreadable = `${b.spec}.critic-plan-r1.md`; chmodSync(unreadable, 0o000);
  try {
    const res = await sendFile(r, "1", other);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain("critic-plan-r1.md");
    expect(res.err).toContain("cannot read");
    expect(res.lines).toEqual([]);
  } finally { chmodSync(unreadable, 0o644); }
});

test("send-file treats specs/spec/ as a signature folder", async () => {
  const r = root(); const dir = join(r, "specs", "spec"); mkdirSync(dir, { recursive: true });
  const f = join(dir, "a.md"); writeFileSync(f, "# A\n");
  const res = await sendFile(r, "1", f);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("critic-spec");
});

// The sign page is a hand-built or generated .html beside its .md; the critic must have read that very page.
const htmlBundle = (r: string, html = "<!doctype html><h1>Design</h1>\n") => {
  const b = bundle(r); const page = join(b.dir, "HIMMEL-1-design.html"); writeFileSync(page, html);
  const sealed = [{ text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" }, { text: html, file: "HIMMEL-1-design.html" }];
  return { ...b, page, html, sealed };
};

test("send-file sends an .html sign page the latest spec critic read, with the verdicts as its caption", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  const res = await sendFile(r, "1", b.page, "for the operator");
  expect(res.code).toBe(0);
  expect(res.lines.at(-1)!.caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1 - for the operator");
  expect(readFileSync(res.lines.at(-1)!.document_path, "utf8")).toBe(b.html);   // the bytes the critic read, untouched
});

test("send-file refuses an .html beside a clean .md when no seal names it, naming the spec verdict file", async () => {
  const r = root(); const b = htmlBundle(r);   // the bundle's spec critic seals design.md only
  const res = await sendFile(r, "1", b.page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r1.md");
  expect(res.err).toContain("HIMMEL-1-design.html");
  expect(res.lines).toEqual([]);
});

test("send-file refuses an .html edited after the critic read it", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  writeFileSync(b.page, b.html + "<p>edited</p>\n");
  const res = await sendFile(r, "1", b.page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r1.md");
  expect(res.err).toContain("changed since");
  expect(res.lines).toEqual([]);
});

test("send-file refuses a clean .md whose .html was read only by an older round's critic", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  critic(b.spec, "spec", 2, "SPEC CLEAN", { text: "# Design\n\nthe spec\n", file: "HIMMEL-1-design.md" });   // round 2 read the .md only
  const res = await sendFile(r, "1", b.page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(res.lines).toEqual([]);
});

test("send-file refuses an .html while the .md beside it failed its latest spec critic, even when the .html has clean critic files of its own", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  criticSeals(b.spec, "spec", 2, "SPEC FINDINGS 1", b.sealed);
  const bare = await sendFile(r, "1", b.page);
  expect(bare.code).not.toBe(0);
  expect(bare.err).toContain("design.md.critic-spec-r2.md");
  const own = [{ text: b.html, file: "HIMMEL-1-design.html" }];
  criticSeals(b.page, "spec", 1, "SPEC CLEAN", own); criticSeals(b.page, "plan", 1, "PLAN CLEAN", own);
  const withOwn = await sendFile(r, "1", b.page);
  expect(withOwn.code).not.toBe(0);
  expect(withOwn.err).toContain("design.md.critic-spec-r2.md");
  expect(bare.lines.concat(withOwn.lines)).toEqual([]);
});

test("send-file refuses an .html with clean critic files of its own beside an .md that has none, and still sends report.html beside a critic-less report.md", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const page = join(dir, "x.html"); const html = "<h1>X</h1>\n";
  writeFileSync(join(dir, "x.md"), "# X\n"); writeFileSync(page, html);
  const own = [{ text: html, file: "x.html" }];
  criticSeals(page, "spec", 1, "SPEC CLEAN", own); criticSeals(page, "plan", 1, "PLAN CLEAN", own);
  const res = await sendFile(r, "1", page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("x.md");
  expect(res.err).toContain("critic");
  expect(res.lines).toEqual([]);
  const rep = join(r, "reports"); mkdirSync(rep);
  writeFileSync(join(rep, "report.md"), "# R\n"); writeFileSync(join(rep, "report.html"), "<h1>R</h1>\n");
  const ok = await sendFile(r, "1", join(rep, "report.html"));
  expect(ok.code).toBe(0);
  expect(ok.lines.at(-1)!.caption).toBeUndefined();
});

test("send-file compares plan critic rounds across folders: a newer FINDINGS in plans/ beats an older clean one beside the spec, and a same-round tie the ledger never recorded goes on the lead block only", async () => {
  const r = root(); const l = planLayout(r);
  critic(l.spec, "plan", 1, "PLAN CLEAN", { text: "# X plan\n", file: "../plans/HIMMEL-2-X.md" });   // r1 beside the spec; plans/ also holds r1 (clean)
  const bothClean = await sendFile(r, "1", l.spec);
  expect(bothClean.err).toBe(""); expect(bothClean.code).toBe(0);
  critic(l.plan, "plan", 1, "PLAN FINDINGS 1", { text: "# X plan\n", file: "HIMMEL-2-X.md" });
  const tieSpec = await sendFile(r, "1", l.spec);
  expect(tieSpec.err).toBe("");
  expect(readFileSync(tieSpec.lines.at(-1)!.document_path, "utf8")).toContain("HIMMEL-2-X.md.critic-plan-r1.md: PLAN FINDINGS 1");
  const tiePlan = await sendFile(r, "1", l.plan);
  expect(tiePlan.code).not.toBe(0);
  expect(tiePlan.err).toContain(join("plans", "HIMMEL-2-X.md.critic-plan-r1.md"));
  critic(l.plan, "plan", 2, "PLAN FINDINGS 2", { text: "# X plan\n", file: "HIMMEL-2-X.md" });       // newer round in plans/
  const newer = await sendFile(r, "1", l.spec);
  expect(newer.code).not.toBe(0);
  expect(newer.err).toContain(join("plans", "HIMMEL-2-X.md.critic-plan-r2.md"));
});

test("send-file refuses an .html when only the .md was edited after the critic read both", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  writeFileSync(b.spec, "# Design\n\nthe spec, edited\n");
  const res = await sendFile(r, "1", b.page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("changed since");
  expect(res.lines).toEqual([]);
});

test("send-file refuses an .html when the spec critic sealed only the .html and not the .md", async () => {
  const r = root(); const b = htmlBundle(r);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", [b.sealed[1]]);
  const res = await sendFile(r, "1", b.page);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r1.md");
  expect(res.err).toContain("does not seal HIMMEL-1-design.md");
  expect(res.lines).toEqual([]);
});

test("send-file captions a clean page with exactly the verdict lines when the caller gives no caption", async () => {
  const r = root(); const b = bundle(r);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  expect(res.lines.at(-1)!.caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1");
});

test("send-file refuses a plan page when its latest clean plan critic sealed another existing file", async () => {
  const r = root(); const b = bundle(r);
  const plans = join(r, "specs", "plans"); mkdirSync(plans);
  const plan = join(plans, "HIMMEL-1-design.plan.md"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(b.spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "../plans/HIMMEL-1-design.plan.md" });
  critic(b.spec, "plan", 2, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "HIMMEL-1-design.plan.md" });   // round 2 read the copy beside the spec
  const res = await sendFile(r, "1", plan);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-plan-r2.md");
  expect(res.err).toContain("does not seal HIMMEL-1-design.plan.md");
  expect(res.lines).toEqual([]);
});

const planLayout = (r: string) => {
  const designs = join(r, "specs", "designs"); const plans = join(r, "specs", "plans");
  mkdirSync(designs, { recursive: true }); mkdirSync(plans, { recursive: true });
  const spec = join(designs, "HIMMEL-2-X.md"); const plan = join(plans, "HIMMEL-2-X.md");
  writeFileSync(spec, "# X spec\n"); writeFileSync(plan, "# X plan\n");
  critic(spec, "spec", 1, "SPEC CLEAN", { text: "# X spec\n", file: "HIMMEL-2-X.md" });
  critic(plan, "plan", 1, "PLAN CLEAN", { text: "# X plan\n", file: "HIMMEL-2-X.md" });
  return { spec, plan };
};

test("send-file sends both pages of the real layout: a spec in designs/ and the same-named plan in plans/ with its plan critic beside it", async () => {
  const r = root(); const l = planLayout(r);
  const s = await sendFile(r, "1", l.spec);
  const p = await sendFile(r, "1", l.plan);
  expect(s.err).toBe(""); expect(p.err).toBe("");
  expect(s.code).toBe(0); expect(p.code).toBe(0);
  expect(p.lines.at(-1)!.caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1");
});

test("send-file refuses the plan page of the real layout when the plan critic in plans/ ends FINDINGS, naming that file", async () => {
  const r = root(); const l = planLayout(r);
  critic(l.plan, "plan", 2, "PLAN FINDINGS 2", { text: "# X plan\n", file: "HIMMEL-2-X.md" });
  for (const f of [l.plan, l.spec]) {
    const res = await sendFile(r, "1", f);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(join("plans", "HIMMEL-2-X.md.critic-plan-r2.md"));
    expect(res.lines).toEqual([]);
  }
});

test("send-file refuses a plan page when the latest plan critic of any spec that seals it is not clean, whatever the spec's file name", async () => {
  for (const name of ["zzz", "aaa"]) {   // the name must not decide: it sorts after and before design.md
    const r = root(); const b = bundle(r);
    const other = join(r, "specs", "other"); mkdirSync(other);
    const plan = join(other, "p.md"); writeFileSync(plan, "# P\n");
    const second = join(b.dir, `${name}.md`); writeFileSync(second, "# Z\n");
    critic(second, "spec", 1, "SPEC CLEAN", { text: "# Z\n", file: `${name}.md` });
    critic(second, "plan", 1, "PLAN FINDINGS 1", { text: "# P\n", file: "../other/p.md" });
    critic(b.spec, "plan", 2, "PLAN CLEAN", { text: "# P\n", file: "../other/p.md" });
    const res = await sendFile(r, "1", plan);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(`${name}.md.critic-plan-r1.md`);
    expect(res.lines).toEqual([]);
  }
});

test("send-file refuses a plan page in plans/ whose same-name spec is clean when another spec's latest plan critic sealing it failed", async () => {
  const r = root(); const l = planLayout(r);
  const second = join(r, "specs", "designs", "other.md"); writeFileSync(second, "# O\n");
  critic(second, "spec", 1, "SPEC CLEAN", { text: "# O\n", file: "other.md" });
  critic(second, "plan", 1, "PLAN FINDINGS 1", { text: "# X plan\n", file: "../plans/HIMMEL-2-X.md" });
  const res = await sendFile(r, "1", l.plan);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("other.md.critic-plan-r1.md");
  expect(res.lines).toEqual([]);
});

test("send-file refuses, naming the folder, when a folder it must list is unreadable", async () => {
  if (process.getuid?.() === 0) return;
  const { chmodSync } = await import("node:fs");
  const r = root(); const b = bundle(r);
  const plans = join(r, "specs", "plans"); mkdirSync(plans); chmodSync(plans, 0o000);
  try {
    const res = await sendFile(r, "1", b.spec);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(plans);
    expect(res.err).toContain("cannot read the folder");
    expect(res.lines).toEqual([]);
  } finally { chmodSync(plans, 0o755); }
});

test("critic-seal.sh does not accept a sha that only sits inside a longer hex run", async () => {
  const r = root(); const spec = join(r, "specs", "designs", "d.md"); mkdirSync(join(r, "specs", "designs"), { recursive: true });
  writeFileSync(spec, "# D\n");
  const v = `${spec}.critic-spec-r1.md`; writeFileSync(v, `return quoting 0${sha("# D\n")}\nSPEC CLEAN\n`);
  const res = await seal(v, spec, sha("# D\n"));
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("does not quote");
});

// ---- a spec page carries its source, so a copy outside the registered folders is still checked ----
const marked = (r: string, extra = "") => `<!doctype html><meta name="spec-source" content="${join(r, "specs", "designs", "HIMMEL-1-design.md")}"><h1>Design</h1>\n${extra}`;
const copyOf = (r: string, html: string, name = "elsewhere.html") => { const d = join(r, "copies"); mkdirSync(d, { recursive: true }); const f = join(d, name); writeFileSync(f, html); return f; };

test("send-file checks a marked page copied outside the registered folders under another stem, and sends it only when a critic sealed its bytes", async () => {
  const r = root(); const html = marked(r); const b = htmlBundle(r, html);
  const copy = copyOf(r, html);
  criticSeals(b.spec, "spec", 1, "SPEC FINDINGS 2", b.sealed);
  const refused = await sendFile(r, "1", copy);
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("design.md.critic-spec-r1.md");
  expect(refused.lines).toEqual([]);
  await ledgerSeals(r, b.spec, "spec", 2, "SPEC CLEAN", b.sealed);
  const sent = await sendFile(r, "1", copy);
  expect(sent.code).toBe(0);
  expect(sent.lines.at(-1)!.caption).toBe("SPEC CLEAN r2 | PLAN CLEAN r1");
  expect(readFileSync(sent.lines.at(-1)!.document_path, "utf8")).toBe(html);
});

test("send-file refuses a marked copy whose bytes no critic sealed, and a marker naming a file that is not there", async () => {
  const r = root(); const html = marked(r); const b = htmlBundle(r, html);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  const edited = await sendFile(r, "1", copyOf(r, html + "<p>edited</p>\n"));
  expect(edited.code).not.toBe(0);
  expect(edited.err).toContain("design.md.critic-spec-r1.md");
  const gone = await sendFile(r, "1", copyOf(r, html.replace("HIMMEL-1-design.md", "gone.md"), "gone.html"));
  expect(gone.code).not.toBe(0);
  expect(gone.err).toContain("gone.md");
  expect(edited.lines.concat(gone.lines)).toEqual([]);
});

test("send-file reads the marker whatever the attribute order or quote style, and still checks the copy", async () => {
  const r = root(); const md = join(r, "specs", "designs", "HIMMEL-1-design.md");
  const variants = [`<meta content="${md}" name="spec-source">`, `<meta name='spec-source' content='${md}'>`, `<META CONTENT=${md} NAME=spec-source />`];
  for (const [i, tag] of variants.entries()) {
    const html = `<!doctype html>${tag}<h1>Design${i}</h1>\n`;
    const b = htmlBundle(r, html);
    criticSeals(b.spec, "spec", 1, "SPEC FINDINGS 1", b.sealed);
    const res = await sendFile(r, "1", copyOf(r, html, `v${i}.html`));
    expect(res.code).not.toBe(0);
    expect(res.err).toContain("design.md.critic-spec-r1.md");
    expect(res.lines).toEqual([]);
  }
});

test("send-file still sends a report page with no marker from outside the registered folders", async () => {
  const r = root(); const html = "<!doctype html><h1>Report</h1>\n";
  const res = await sendFile(r, "1", copyOf(r, html, "report.html"));
  expect(res.code).toBe(0);
  expect(readFileSync(res.lines.at(-1)!.document_path, "utf8")).toBe(html);
  expect(res.lines.at(-1)!.caption).toBeUndefined();
});

test("send-file refuses a spec page that still says Not for signature, and sends the same page without it with the bytes the critic read", async () => {
  const r = root(); const banner = "<!doctype html><h1>Design</h1><p>DRAFT, no critic has read this revision. Not for signature.</p>\n";
  const b = htmlBundle(r, banner);
  criticSeals(b.spec, "spec", 1, "SPEC CLEAN", b.sealed);
  const refused = await sendFile(r, "1", b.page);
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("Not for signature");
  expect(refused.lines).toEqual([]);
  const clean = "<!doctype html><h1>Design</h1>\n";
  writeFileSync(b.page, clean);
  await ledgerSeals(r, b.spec, "spec", 2, "SPEC CLEAN", [b.sealed[0], { text: clean, file: "HIMMEL-1-design.html" }]);
  const sent = await sendFile(r, "1", b.page);
  expect(sent.code).toBe(0);
  const bytes = readFileSync(sent.lines.at(-1)!.document_path);
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(sha(clean));
});

const REQ = "operator asked to see it early";
const earlySpec = (r: string, name = "early.md", text = "# Early\n\nbody\n") => {
  const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const spec = join(dir, name); writeFileSync(spec, text);
  return spec;
};

test("send-file --by-request queues a spec page with no clean critics, marked not passed on the page and in the caption; plain send-file still refuses it", async () => {
  const r = root(); const spec = earlySpec(r);
  const before = await sendFile(r, "1", spec);
  expect(before.code).not.toBe(0);
  expect(before.lines).toEqual([]);
  const res = await sendFile(r, "--by-request", REQ, "1", spec, "my words");
  expect(res.err).toBe("");
  expect(res.code).toBe(0);
  expect(res.lines.length).toBe(1);
  expect(res.lines[0].caption).toMatch(/^NOT PASSED - not for signature/);
  expect(res.lines[0].caption).toContain("my words");
  const html = readFileSync(res.lines[0].document_path as string, "utf8");
  expect(html).toContain("NOT PASSED");
  expect(html).toContain("Not for signature");
  expect(html).toContain(`asked: ${REQ}</p>`);
  expect(html.indexOf("NOT PASSED")).toBeLessThan(html.indexOf("<h1>"));
  const after = await sendFile(r, "1", spec);
  expect(after.code).not.toBe(0);
  expect(after.lines.length).toBe(1);
});

test("send-file --by-request puts the mark right after <body> of an .html page and leaves the rest of its bytes alone", async () => {
  const r = root(); const page = earlySpec(r, "early.html", "<!doctype html><html><head><title>x</title></head><body><h1>Early</h1></body></html>\n");
  const res = await sendFile(r, "--by-request", REQ, "1", page);
  expect(res.code).toBe(0);
  const html = readFileSync(res.lines[0].document_path as string, "utf8");
  expect(html).toMatch(/<body><section class="not-passed">/);
  expect(html).toContain("<h1>Early</h1></body></html>");
  expect(html).toContain(REQ);
});

test("send-file --by-request names no request: refused, nothing queued", async () => {
  const r = root(); const spec = earlySpec(r);
  for (const args of [["--by-request", "", "1", spec], ["--by-request", "   ", "1", spec], ["--by-request"], ["--by-request", "1", spec]]) {
    const res = await sendFile(r, ...args);
    expect(res.code).not.toBe(0);
    expect(res.lines).toEqual([]);
  }
  expect((await sendFile(r, "--by-request", "", "1", spec)).err).toContain("names no request");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

test("send-file --by-request carries its mark only on a .md or .html page", async () => {
  const r = root(); const f = join(r, "run.log"); writeFileSync(f, "log\n");
  const res = await sendFile(r, "--by-request", REQ, "1", f);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("only on a .md or .html page");
  expect(res.lines).toEqual([]);
});

test("a page sent --by-request cannot satisfy the signature check, even with every critic clean and sealed over its bytes", async () => {
  const r = root(); const b = htmlBundle(r, "<!doctype html><html><body><h1>Design</h1></body></html>\n");
  const res = await sendFile(r, "--by-request", REQ, "1", b.page);
  expect(res.code).toBe(0);
  const marked = readFileSync(res.lines[0].document_path as string, "utf8");
  writeFileSync(b.page, marked);
  criticSeals(b.spec, "spec", 2, "SPEC CLEAN", [b.sealed[0], { text: marked, file: "HIMMEL-1-design.html" }]);
  const { checkSignaturePage } = await import("./chief-route");
  await expect(checkSignaturePage(b.page)).rejects.toThrow("Not for signature");
  expect((await sendFile(r, "1", b.page)).code).not.toBe(0);
});

const D_TEXT = "# Design\n\nthe spec\n";
const P_TEXT = "# Plan\n\nthe plan\n";
const D_SEAL = { text: D_TEXT, file: "HIMMEL-1-design.md" };
const P_SEAL = { text: P_TEXT, file: "HIMMEL-1-design.plan.md" };
const fiveRounds = (r: string) => {
  const b = bundle(r);
  critic(b.spec, "spec", 1, "SPEC FINDINGS 1", D_SEAL);
  critic(b.spec, "spec", 4, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(`${b.spec}.critic-spec-r5.md`, `**F1.** finding-one <the tag> stays open\n**F2.** finding-two stays open\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nSPEC FINDINGS 2\n`);
  return b;
};
const unsealedReturn = (file: string, text: string, verdict = "SPEC FINDINGS 1", ...lines: string[]) => writeFileSync(file, `return, read ${sha(text)}\n${lines.map((l) => `${l}\n`).join("")}${verdict}\n`);
const grant = (r: string, spec: string, round: number, decision = 900, withVerbatim = true) => {
  writeFileSync(`${spec}.operator-round-r${round}.md`, `Operator allows this round.\ndecision ${decision}\n`);
  if (!withVerbatim) return;
  mkdirSync(join(r, "specs", "decisions"), { recursive: true });
  writeFileSync(join(r, "specs", "decisions", `verbatim-decision-${decision}-operator.txt`), "yes, one more\n");
};

const minorsFive = async (r: string) => {
  const b = bundle(r);
  critic(b.spec, "spec", 4, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(`${b.spec}.critic-spec-r5.md`, `- **m1** (minor) a wording note\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nSPEC FINDINGS 1\n`);
  await seedIfNeeded(join(r, "specs"));
  return b;
};
const T1_SPEC = "HIMMEL-1 spec round 6 needs a blocking finding in round 5 of either kind; sign it under 848, its minors go to the build";
const specsOf = (r: string) => join(r, "specs");

test("DoD 1: round 5 left findings open, so round 6 seals once by the ledger count; round 7 needs a record (T5), and an operator-round file opens nothing", async () => {
  const r = root(); const b = fiveRounds(r); await seedIfNeeded(specsOf(r));
  const r6 = `${b.spec}.critic-spec-r6.md`; unsealedReturn(r6, D_TEXT, "SPEC FINDINGS 1", markerFor(specsOf(r), "HIMMEL-1", "spec", 6));
  expect((await seal(r6, b.spec, sha(D_TEXT))).err).toBe("");
  const r7 = `${b.spec}.critic-spec-r7.md`; unsealedReturn(r7, D_TEXT, "SPEC CLEAN");
  grant(r, b.spec, 7);
  const five = await seal(r7, b.spec, sha(D_TEXT));
  expect(five.err).toContain("HIMMEL-1 writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)");
  expect(five.code).not.toBe(0);
  expect(readFileSync(r7, "utf8")).not.toContain("CONTENT-SHA256");
  expect(ledgerRows(specsOf(r), "HIMMEL-1").filter((x) => x.row === "round").map((x) => x.round)).toEqual([6]);
});

test("readCriticBudget reads the kind's rounds from the ledger and whether the next one may be sealed", async () => {
  const { readCriticBudget } = await import("./chief-route");
  const r = root(); const b = fiveRounds(r); await seedIfNeeded(specsOf(r));
  expect(await readCriticBudget(b.spec, "spec")).toMatchObject({ count: 5, requestedRound: 6, allowed: true, why: null, cap: 5 });
  expect((await readCriticBudget(b.spec, "spec")).rounds).toEqual([{ round: 5, path: `${b.spec}.critic-spec-r5.md` }]);
  expect(await readCriticBudget(b.spec, "spec", 7)).toMatchObject({ requestedRound: 7, allowed: false, why: "HIMMEL-1 spec round 7 is not the next round (6)" });
  const plan = await readCriticBudget(b.spec, "plan");
  expect(plan).toMatchObject({ count: 1, requestedRound: 2, allowed: true });
  expect(plan.rounds.map(f => [f.round, basename(f.path)])).toEqual([[1, "HIMMEL-1-design.md.critic-plan-r1.md"]]);
  const r6 = `${b.spec}.critic-spec-r6.md`; unsealedReturn(r6, D_TEXT, "SPEC FINDINGS 1", markerFor(specsOf(r), "HIMMEL-1", "spec", 6));
  expect((await seal(r6, b.spec, sha(D_TEXT))).err).toBe("");
  expect(await readCriticBudget(b.spec, "spec")).toMatchObject({ count: 6, requestedRound: 7, allowed: false, why: "HIMMEL-1 writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)" });
});

const seededAtThree = (r: string) => {
  const b = bundle(r);
  writeFileSync(`${b.spec}.critic-spec-r3.md`, `**F1.** finding-one stays open\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nSPEC FINDINGS 1\n`);
  return b;
};

test("cap 5: rounds 4 and 5 seal as free full rounds, round 6 is a closure check of a blocking round 5, round 7 needs a record", async () => {
  const { readCriticBudget, roundState } = await import("./chief-route");
  const r = root(); const b = seededAtThree(r); await seedIfNeeded(specsOf(r));
  const at = (n: number) => `${b.spec}.critic-spec-r${n}.md`;
  for (const n of [4, 5]) {
    unsealedReturn(at(n), D_TEXT, "SPEC FINDINGS 1", `**F1.** still open after round ${n}`);
    expect((await seal(at(n), b.spec, sha(D_TEXT))).err).toBe("");
  }
  expect(await readCriticBudget(b.spec, "spec")).toMatchObject({ count: 5, requestedRound: 6, allowed: true, cap: 5 });
  expect((await roundState(specsOf(r), "HIMMEL-1")).why).toContain("spec round 6: closure");
  unsealedReturn(at(6), D_TEXT, "SPEC FINDINGS 1", markerFor(specsOf(r), "HIMMEL-1", "spec", 6), "**F1.** still open");
  expect((await seal(at(6), b.spec, sha(D_TEXT))).err).toBe("");
  unsealedReturn(at(7), D_TEXT, "SPEC CLEAN");
  expect((await seal(at(7), b.spec, sha(D_TEXT))).err).toContain("HIMMEL-1 writer round 7 needs a round-critical record");
  expect(ledgerRows(specsOf(r), "HIMMEL-1").filter((x) => x.row === "round").map((x) => [x.round, x.mode])).toEqual([[4, "full"], [5, "full"], [6, "closure"]]);
});

test("cap 5: rows written under cap 3 (closure rounds 4 and 5, a closure record opening 5) still read", async () => {
  const { roundState } = await import("./chief-route");
  const r = root(); const b = seededAtThree(r); await seedIfNeeded(specsOf(r));
  mkdirSync(join(specsOf(r), "decisions"), { recursive: true });
  const decision = join(specsOf(r), "decisions", "verbatim-decision-900-operator.txt");
  const quote = "yes, open one more review round for HIMMEL-1";
  writeFileSync(decision, `HIMMEL-1\n${quote}\n`);
  const ledger = join(specsOf(r), "ledgers", "spec-rounds", "HIMMEL-1.jsonl");
  const old = (n: number) => ({ v: 1, ts: n, key: "HIMMEL-1", row: "round", critic: "spec", round: n, epoch: 0, return_sha: sha(`return ${n}`), verdict_path: `${b.spec}.critic-spec-r${n}.md`, read_path: b.spec, read_sha: sha(D_TEXT), verdict: "SPEC FINDINGS 1", mode: "closure", findings: [{ id: "F1", severity: "major" }], unrated_ids: [] });
  const record = { v: 1, ts: 5, key: "HIMMEL-1", row: "critical", closure: true, critics: ["spec"], epoch: 0, opens: 5, decision: "900", quote, decision_path: realpathSync(decision), decision_sha: sha(readFileSync(decision, "utf8")) };
  appendFileSync(ledger, [old(4), record, old(5)].map((x) => `${JSON.stringify(x)}\n`).join(""));
  expect(await roundState(specsOf(r), "HIMMEL-1")).toMatchObject({ spec: 5, writer: 5, invalid: [] });
});

test("DoD 1: an unsealed fourth return found on disk still keeps the page from going", async () => {
  const r = root(); const b = fiveRounds(r);
  unsealedReturn(`${b.spec}.critic-spec-r6.md`, D_TEXT);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("critic-spec-r6.md");
  expect(res.lines).toEqual([]);
});

test("DoD 2: a page sent after round 5 opens with the count and the rule line, and shows each open finding verbatim", async () => {
  const r = root(); const b = fiveRounds(r);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  const html = readFileSync(res.lines.at(-1)!.document_path, "utf8");
  const lead = html.slice(html.indexOf("<body>"));
  expect(lead.indexOf("Round count: spec 5, plan 1. 1 critic did not end clean.")).toBeGreaterThan(-1);
  expect(lead.indexOf("Round count")).toBeLessThan(lead.indexOf("Rule, don't just sign"));
  expect(lead.indexOf("Rule, don't just sign")).toBeLessThan(lead.indexOf("finding-one"));
  expect(lead.indexOf("finding-two")).toBeLessThan(lead.indexOf("<h1"));   // the page's own text follows the block
  expect(html).toContain("finding-one &lt;the tag&gt; stays open");
  expect(html).toContain("design.md.critic-spec-r5.md");
  expect(res.lines.at(-1)!.caption).toContain("SPEC FINDINGS 2 r5");
});

test("DoD 2: a sealed .html page past round 5 goes as the sealed bytes with the block after <body>", async () => {
  const r = root(); const b = fiveRounds(r);
  const page = join(b.dir, "HIMMEL-1-design.html"); const pageText = "<!doctype html><html><head><title>D</title></head><body><h1>D</h1></body></html>\n";
  writeFileSync(page, pageText);
  writeFileSync(`${b.spec}.critic-spec-r5.md`, `**F1.** finding-one\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nCONTENT-SHA256 ${sha(pageText)} HIMMEL-1-design.html\nSPEC FINDINGS 1\n`);
  const res = await sendFile(r, "1", page);
  expect(res.code).toBe(0);
  const sent = readFileSync(res.lines.at(-1)!.document_path, "utf8");
  expect(sent).toContain("finding-one");
  expect(sent.indexOf("<body>")).toBeLessThan(sent.indexOf("Round count"));
  expect(sent.replace(/<section class="open-findings">[\s\S]*<\/section>\n/, "")).toBe(pageText);
  writeFileSync(page, pageText + "<!-- edited after round 5 -->\n");
  const edited = await sendFile(r, "1", page);
  expect(edited.code).not.toBe(0);
  expect(edited.err).toContain("critic-spec-r5.md");
});

test("DoD 2: rounds below 5 with findings stay refused, and each kind must reach 5 on its own count", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 4, "SPEC FINDINGS 1", D_SEAL);
  expect((await sendFile(r, "1", b.spec)).code).not.toBe(0);
  const r2 = root(); const t = fiveRounds(r2);
  critic(t.spec, "plan", 4, "PLAN FINDINGS 1", P_SEAL);
  const plan2 = await sendFile(r2, "1", t.spec);
  expect(plan2.code).not.toBe(0);
  expect(plan2.err).toContain("critic-plan-r4.md");
  await ledgerSeals(r2, t.spec, "plan", 5, "PLAN FINDINGS 2", [P_SEAL]);
  const plan3 = await sendFile(r2, "1", t.spec);
  expect(plan3.code).toBe(0);
  const html = readFileSync(plan3.lines.at(-1)!.document_path, "utf8");
  expect(html).toContain("Round count: spec 5, plan 5. 2 critics did not end clean.");
  expect(html).toContain("design.md.critic-plan-r5.md");
});

test("a spec seeded past 3 still goes with its findings when it is the bytes its last critic read, and its next round needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)", async () => {
  const r = root(); const b = bundle(r);
  for (const n of [7, 8, 9]) critic(b.spec, "spec", n, "SPEC FINDINGS 4", D_SEAL);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  expect(readFileSync(res.lines.at(-1)!.document_path, "utf8")).toContain("Round count: spec 9, plan 1.");
  const r10 = `${b.spec}.critic-spec-r10.md`; unsealedReturn(r10, D_TEXT);
  const next = await seal(r10, b.spec, sha(D_TEXT));
  expect(next.code).not.toBe(0);
  expect(next.err).toContain("HIMMEL-1 writer round 10 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)");
});

const sendSealedPage = async (r: string, b: ReturnType<typeof bundle>, pageText: string) => {
  const page = join(b.dir, "HIMMEL-1-design.html"); writeFileSync(page, pageText);
  writeFileSync(`${b.spec}.critic-spec-r5.md`, `**F1.** finding-one\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nCONTENT-SHA256 ${sha(pageText)} HIMMEL-1-design.html\nSPEC FINDINGS 1\n`);
  return sendFile(r, "1", page);
};

test("a page that cannot carry the findings block is refused rather than sent without them", async () => {
  for (const pageText of [
    "<!doctype html><h1>D</h1>\n",
    "<!doctype html><head><!-- <body> old --></head><h1>D</h1>\n",
    "<!doctype html><head><title>The <body> tag</title></head><h1>D</h1>\n",
    "<!doctype html><head><!-- <body> never closed\n",
    "<!doctype html><head><meta name=\"note\" content=\"<body>\"></head><h1>D</h1>\n",
    "<!doctype html><template><body><h1>D</h1></template>\n",
    "<!doctype html><div hidden><body><h1>D</h1></div>\n",
    "<!doctype html><head><script><!-- <script></script><body>--></script></head><h1>D</h1>\n",
    "<!doctype html><body class=\"never closed\n",
    "<!doctype html><head></head data-x=\"><body>\"><h1>D</h1>\n",
    "<!doctype html><head><title>T</title x=\"><body>\"></head><h1>D</h1>\n",
    "<!doctype html><head><meta a=b\"c><link title=\"d\"e=\"><body>\"></head><h1>D</h1>\n",
  ]) {
    const r = root(); const res = await sendSealedPage(r, fiveRounds(r), pageText);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain("<body>");
    expect(res.lines).toEqual([]);
  }
});

test("the findings block goes in the real body, not in a comment, a title or an attribute that spells the tag", async () => {
  const real = "<body class=\"a>b\">\n<h1>D</h1></body></html>\n";
  for (const head of [
    "<head><!-- <body> old --></head>",
    "<head><title>The <body> tag</title></head>",
    "<head><meta name=\"note\" content=\"<body>\"></head>",
    "<head><style>/* <body> */</style><script>const a = \"<body>\";</script></head>",
    "<HEAD><TITLE>The <BODY> tag</TITLE></HEAD>",
    "<head></head data-x=\"<body>\">",
    "<head><meta a=b\"c></head>",
  ]) {
    const pageText = `<!doctype html><html>${head}${real}`;
    const r = root(); const res = await sendSealedPage(r, fiveRounds(r), pageText);
    expect(res.code).toBe(0);
    const sent = readFileSync(res.lines.at(-1)!.document_path, "utf8");
    expect(sent.indexOf("<body class=")).toBeLessThan(sent.indexOf("Round count"));
    expect(sent.indexOf("Round count")).toBeLessThan(sent.indexOf("<h1>D"));
    expect(sent.replace(/<section class="open-findings">[\s\S]*<\/section>\n/, "")).toBe(pageText);
  }
});

test("planted: a return named for the third round, written after the seed, does not open the page and buys no round (T20)", async () => {
  const r = root(); const b = bundle(r); await seedIfNeeded(specsOf(r));
  critic(b.spec, "spec", 3, "SPEC FINDINGS 1", D_SEAL);
  const res = await sendFile(r, "1", b.spec);
  expect(res.err).toContain(`${b.spec}.critic-spec-r3.md: its return is not in HIMMEL-1's ledger`);
  expect(res.lines).toEqual([]);
  const r4 = `${b.spec}.critic-spec-r4.md`; unsealedReturn(r4, D_TEXT);
  expect((await seal(r4, b.spec, sha(D_TEXT))).err).toBe("");
  expect(ledgerRows(specsOf(r), "HIMMEL-1").at(-1)).toMatchObject({ row: "round", critic: "spec", round: 2 });
});

test("DoD 3: a scope edit on the same spec does not reset the count: round 6 after a minors-only round 5 gives T1", async () => {
  const r = root(); const b = await minorsFive(r);
  const edited = "# Design\n\nthe spec, with a wider scope\n"; writeFileSync(b.spec, edited);
  const r6 = `${b.spec}.critic-spec-r6.md`; unsealedReturn(r6, edited);
  const res = await seal(r6, b.spec, sha(edited));
  expect(res.code).not.toBe(0);
  expect(res.err).toContain(T1_SPEC);
});

test("DoD 3, planted: a renamed critic cannot restart the count, under any new name (T1)", async () => {
  const r = root(); const b = await minorsFive(r);
  for (const name of ["design.md.critic-fresh-r1.md", "design.md.critic-spec-opus-r1.md", "design.md.critic-r1.md", "fresh.critic-spec-r1.md", "other.md.critic-spec-r1.md"]) {
    const v = join(b.dir, name); unsealedReturn(v, D_TEXT, "SPEC CLEAN");
    const res = await seal(v, b.spec, sha(D_TEXT));
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(T1_SPEC);
    expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
    unlinkSync(v);
  }
});

test("DoD 3, planted: a renamed critic file planted after the seed is no round: the next real seal is round 3", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", D_SEAL); await seedIfNeeded(specsOf(r));
  writeFileSync(join(b.dir, "fresh.critic-spec-r1.md"), `renamed return\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nSPEC FINDINGS 1\n`);
  const r3 = `${b.spec}.critic-spec-r3.md`; unsealedReturn(r3, D_TEXT);
  expect((await seal(r3, b.spec, sha(D_TEXT))).err).toBe("");
  expect(ledgerRows(specsOf(r), "HIMMEL-1").at(-1)).toMatchObject({ row: "round", critic: "spec", round: 3 });
});

test("DoD 4: a judge round is not counted and not limited", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 4, "SPEC CLEAN", D_SEAL);
  for (let i = 1; i <= 9; i++) writeFileSync(`${b.spec}.judge-r${i}.md`, `judge round ${i}\nVERDICT: SPEC FINDINGS 1\n`);
  await seedIfNeeded(specsOf(r));
  const r5 = `${b.spec}.critic-spec-r5.md`; unsealedReturn(r5, D_TEXT, "SPEC CLEAN");
  expect((await seal(r5, b.spec, sha(D_TEXT))).code).toBe(0);
  const r6 = `${b.spec}.critic-spec-r6.md`; unsealedReturn(r6, D_TEXT);
  const res = await seal(r6, b.spec, sha(D_TEXT));
  expect(res.err).toContain(T1_SPEC);   // the count names critics alone
  expect(ledgerRows(specsOf(r), "HIMMEL-1").filter((x) => x.row === "round").map((x) => x.round)).toEqual([5]);
});

test("planted: a renamed return is no round and does not decide the page: before round 5 the page is refused, at round 5 it goes without that return", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 4, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(join(b.dir, "fresh.critic-spec-r1.md"), `renamed return, finding-renamed\nCONTENT-SHA256 ${sha(D_TEXT)} HIMMEL-1-design.md\nSPEC FINDINGS 1\n`);
  const early = await sendFile(r, "1", b.spec);
  expect(early.code).not.toBe(0);
  expect(early.err).toContain("HIMMEL-1-design.md.critic-spec-r4.md");
  expect(early.lines).toEqual([]);
  await ledgerSeals(r, b.spec, "spec", 5, "SPEC FINDINGS 1", [D_SEAL]);
  const res = await sendFile(r, "1", b.spec);
  expect(res.err).toBe("");
  const page = readFileSync(res.lines[0].document_path as string, "utf8");
  expect(page).not.toContain("finding-renamed");
  expect(page).toContain("Round count: spec 5, plan 1. 1 critic did not end clean.");
});

test("DoD 4: a judge return that ends in a verdict line can be sealed past the cap, and adds no round", async () => {
  const r = root(); const b = fiveRounds(r);
  const judge = `${b.spec}.judge-r1.md`; unsealedReturn(judge, D_TEXT, "SPEC CLEAN");
  expect((await seal(judge, b.spec, sha(D_TEXT))).code).toBe(0);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  expect(readFileSync(res.lines[0].document_path as string, "utf8")).toContain("Round count: spec 5, plan 1.");
});

test("DoD 4: every judge file name in use can be sealed past the cap", async () => {
  const r = root(); const b = fiveRounds(r);
  for (const name of ["judge.md", "judge2.md", "judge-input.md"]) {
    const judge = `${b.spec}.${name}`; unsealedReturn(judge, D_TEXT, "SPEC CLEAN");
    expect((await seal(judge, b.spec, sha(D_TEXT))).code).toBe(0);
  }
});

test("planted: a spec named like a judge file is counted as critic rounds, not skipped as a judge", async () => {
  const r = root(); const b = bundle(r);
  const spec = join(b.dir, "HIMMEL-2-judge-design.md"); writeFileSync(spec, D_TEXT);
  for (const n of [1, 2, 3, 4, 5]) critic(spec, "spec", n, "SPEC FINDINGS 1", { text: D_TEXT, file: "HIMMEL-2-judge-design.md" });
  await seedIfNeeded(specsOf(r));
  const r6 = `${spec}.critic-spec-r6.md`; unsealedReturn(r6, D_TEXT, "SPEC FINDINGS 1", markerFor(specsOf(r), "HIMMEL-2", "spec", 6));
  expect((await seal(r6, spec, sha(D_TEXT))).err).toBe("");
  expect(ledgerRows(specsOf(r), "HIMMEL-2").at(-1)).toMatchObject({ row: "round", critic: "spec", round: 6, verdict_path: r6 });
});

// The page the router renders opens dark with no saved choice, whatever the system preference says; print alone goes back to light.
test("the routed markdown page opens dark with readable text, no system-preference flip, and a light print", () => {
  const html = renderMarkdownHtml("# T\n\nbody `code`\n\n```\npre\n```\n\n> quote\n\n| a |\n|---|\n| b |\n", "T");
  const root = /:root\{([^}]*)\}/.exec(html)?.[1] ?? "";
  const val = (v: string) => new RegExp(`${v}:(#[0-9a-fA-F]{6})`).exec(root)?.[1];
  const lum = (h: string) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const [bg, ink, mute] = ["--bg", "--ink", "--mute"].map(val);
  expect(bg && ink && mute).toBeTruthy();
  expect(lum(bg!)).toBeLessThan(0.1);
  expect(ratio(ink!, bg!)).toBeGreaterThanOrEqual(4.5);
  expect(ratio(mute!, bg!)).toBeGreaterThanOrEqual(4.5);
  expect(html).not.toContain("prefers-color-scheme");
  expect(html).toContain("color-scheme:dark");
  expect(html).toMatch(/@media print\{:root\{[^}]*--bg:#fff/);
});

import { chmodSync, readdirSync, appendFileSync, copyFileSync } from "node:fs";

const H1 = "a1".repeat(20);
const H2 = "b2".repeat(20);
const GH_STUB = `#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "\${STUB_MODE:-ok}" in
  fail) exit 1 ;;
  junk) echo 'not json at all' ;;
  sleep) sleep 30 ;;
  *) printf '{"state":"%s","author":{"login":"Stranger","id":"U_stranger"},"headRefName":"feat/x","headRefOid":"%s"}\\n' "\${STUB_STATE:-OPEN}" "\${STUB_OID:?}" ;;
esac
`;
const LIB_DIR = join(import.meta.dir, "../lib");

function approveEnv(liveHead = H1) {
  const home = mkdtempSync(join(tmpdir(), "approve-home-"));
  const bin = join(home, "bin"); mkdirSync(bin);
  writeFileSync(join(bin, "gh"), GH_STUB); chmodSync(join(bin, "gh"), 0o755);
  const access = join(home, "access.json"); writeFileSync(access, JSON.stringify({ allowFrom: ["1"] }));
  const repo = join(home, "repo");
  expect(Bun.spawnSync(["git", "init", "-q", repo]).exitCode).toBe(0);
  const ledger = join(repo, ".git", "cr-critic-scores.jsonl");
  const anchor = join(home, "anchor"); mkdirSync(join(anchor, "scripts", "lib"), { recursive: true }); mkdirSync(join(anchor, "scripts", "cr", "perspectives"), { recursive: true });
  for (const f of ["outside-contributors.sh", "timeout-bin.sh"]) copyFileSync(join(LIB_DIR, f), join(anchor, "scripts", "lib", f));
  const persp = join(anchor, "scripts", "cr", "perspectives", "outside-security.md"); writeFileSync(persp, "# fixture outside-security perspective\n");
  const psha = createHash("sha256").update(readFileSync(persp)).digest("hex");
  for (const head of [H1, H2]) {
    const report = join(repo, `audit-${head.slice(0, 7)}.md`); writeFileSync(report, `audit pass ${head}\n`);
    appendFileSync(ledger, JSON.stringify({ kind: "security-audit", ts: "2026-11-07T10:00:00Z", pr: 7, branch: "feat/x", head, verdict: "pass", perspective_sha256: psha, report, report_sha256: sha(readFileSync(report, "utf8")), status: "ok" }) + "\n");
  }
  const log = join(home, "gh.log");
  const keys = { HOME: home, PATH: `${bin}:${process.env.PATH}`, TELEGRAM_ACCESS_PATH: access, STUB_LOG: log, STUB_OID: liveHead, STUB_STATE: "OPEN", STUB_MODE: "ok" } as Record<string, string>;
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(keys)) { saved[k] = process.env[k]; process.env[k] = v; }
  return {
    home, repo, log, store: join(home, ".himmel", "outside-pr-approvals.jsonl"),
    set: (k: string, v: string) => { process.env[k] = v; },
    gh: () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(l => l.includes("state,headRefOid")) : []),
    authorize: (pr: number, head: string) => {
      const p = Bun.spawnSync([BASH_BIN, "-c", '. "$1" && shift && outside_pr_authorize "$@"', "_", join(anchor, "scripts", "lib", "outside-contributors.sh"), String(pr), head, "0"], { cwd: repo, env: process.env as Record<string, string> });
      return `${p.exitCode}:${p.stdout.toString().trim()}`;
    },
    done: () => { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } },
  };
}
const requestText = (pr: number, head: string) => `outside-approve-request ${pr} ${head}`;
const approveMsg = (text: string, extra: Record<string, unknown> = {}) =>
  fresh(text, { reply_to_message_id: 500, reply_to_bot: true, reply_to_text: requestText(7, H1), ...extra });
const rows = (store: string) => (existsSync(store) ? readFileSync(store, "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l)) : []);

test("approve: an unlisted author's PR is refused, then reviewable at the same head after the operator's reply", async () => {
  const e = approveEnv(); const r = root(); const replies: string[] = []; const ran: string[] = [];
  try {
    expect(e.authorize(7, H1)).toBe("1:");
    await inbound(r, approveMsg(`approve 7 ${H1.slice(0, 7)}`), replies, ran);
    expect(e.authorize(7, H1)).toBe("0:approval:123");
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain(`approved PR 7 at ${H1.slice(0, 7)}`);
    expect(e.gh()).toEqual([expect.stringMatching(/^pr view 7 --json state,headRefOid/)]);
    const lines = readFileSync(e.store, "utf8").split("\n").filter(Boolean);
    expect(lines).toHaveLength(1);
    const jq = Bun.spawnSync(["jq", "-e", '(keys | length == 11) and (.pr | type == "number") and (.head | test("^[0-9a-f]{40}$")) and .stage == "review" and (.from | type == "number") and (.chat | type == "number") and (.message_id | type == "number") and (.ts | type == "string" and test("^[0-9]{4}-")) and .v == 1 and (.host | type == "string" and length > 0) and .source == "telegram-approve" and .kind == "approval"'], { stdin: Buffer.from(lines[0]) });
    expect(jq.exitCode).toBe(0);
    expect(rows(e.store)[0]).toMatchObject({ pr: 7, head: H1, stage: "review", from: 1, chat: 1, message_id: 123 });
  } finally { e.done(); }
});

test("approve: a row for head H1 does not authorize H2; a second approve at H2 writes a second row", async () => {
  const e = approveEnv(); const r = root(); const replies: string[] = [];
  try {
    await inbound(r, approveMsg(`approve 7 ${H1.slice(0, 7)}`), replies);
    expect(e.authorize(7, H1)).toBe("0:approval:123");
    e.set("STUB_OID", H2);
    expect(e.authorize(7, H2)).toBe("1:");
    await inbound(r, approveMsg(`approve 7 ${H2.slice(0, 9)}`, { reply_to_text: requestText(7, H2), message_id: 124 }), replies);
    expect(rows(e.store).map(x => [x.head, x.message_id])).toEqual([[H1, 123], [H2, 124]]);
    expect(e.authorize(7, H2)).toBe("0:approval:124");
    e.set("STUB_OID", H1);
    expect(e.authorize(7, H1)).toBe("0:approval:123");
  } finally { e.done(); }
});

test("approve: a repeated approve for the same PR and head writes no second row and says so", async () => {
  const e = approveEnv(); const r = root(); const replies: string[] = [];
  try {
    await inbound(r, approveMsg(`approve 7 ${H1.slice(0, 7)}`), replies);
    const before = readFileSync(e.store, "utf8");
    await inbound(r, approveMsg(`approve 7 ${H1.slice(0, 12)}`, { message_id: 130 }), replies);
    expect(readFileSync(e.store, "utf8")).toBe(before);
    expect(replies.at(-1)).toContain("already approved");
    expect(e.authorize(7, H1)).toBe("0:approval:123");
  } finally { e.done(); }
});

test("approve: a reply with no message id writes no row and says why", async () => {
  const e = approveEnv(); const r = root(); const replies: string[] = [];
  try {
    await inbound(r, approveMsg(`approve 7 ${H1.slice(0, 7)}`, { message_id: undefined }), replies);
    expect(existsSync(e.store)).toBe(false);
    expect(replies.join("\n")).toContain("no message id");
    expect(e.gh()).toEqual([]);
  } finally { e.done(); }
});

const REFUSALS: { name: string; text?: string; extra?: Record<string, unknown>; env?: [string, string]; reply: string; gh: boolean }[] = [
  { name: "a prefix shorter than 7 hex", text: `approve 7 ${H1.slice(0, 6)}`, reply: "at least 7 hex", gh: false },
  { name: "a prefix of another sha", text: `approve 7 ${"c3".repeat(4)}`, reply: "not a prefix", gh: false },
  { name: "a PR number that differs from the request", text: `approve 8 ${H1.slice(0, 7)}`, reply: "request is for PR 7", gh: false },
  { name: "a PR that is not open", env: ["STUB_STATE", "MERGED"], reply: "PR 7 is not open", gh: true },
  { name: "a live head that differs from the requested sha", env: ["STUB_OID", H2], reply: "head changed", gh: true },
  { name: "gh exits non-zero", env: ["STUB_MODE", "fail"], reply: "cannot read PR 7; nothing stored", gh: true },
  { name: "gh prints junk", env: ["STUB_MODE", "junk"], reply: "cannot read PR 7; nothing stored", gh: true },
  { name: "not a reply at all", extra: { reply_to_message_id: undefined, reply_to_bot: undefined, reply_to_text: undefined }, reply: "reply to the outside-approve-request", gh: false },
  { name: "a reply to a message that is not from the bot", extra: { reply_to_bot: undefined }, reply: "reply to the outside-approve-request", gh: false },
  { name: "a reply to a bot message that is not a request", extra: { reply_to_text: "hello there" }, reply: "reply to the outside-approve-request", gh: false },
  { name: "a request whose sha is not 40 hex", extra: { reply_to_text: `outside-approve-request 7 ${H1.slice(0, 12)}` }, reply: "reply to the outside-approve-request", gh: false },
  { name: "an authorized chat that is not the operator chat", extra: { chat_id: -1 }, reply: "operator's own chat", gh: false },
  { name: "a stale command", extra: { ts: Math.floor(Date.now() / 1000) - 301 }, reply: "stale, resend", gh: false },
  { name: "a sender who is not the operator", extra: { from: 999 }, reply: "", gh: false },
  { name: "a forwarded message", extra: { forwarded: true }, reply: "", gh: false },
  { name: "a voice transcript or caption", extra: { caption: true }, reply: "", gh: false },
  { name: "a model-tagged line", text: `model:opus approve 7 ${H1.slice(0, 7)}`, reply: "", gh: false },
];
test("approve: every refusal replies with its reason, stores nothing and leaves the file bytes unchanged", async () => {
  for (const seeded of [false, true]) {
    for (const c of REFUSALS) {
      const e = approveEnv(); const r = root(); const replies: string[] = []; const ran: string[] = [];
      try {
        const seed = JSON.stringify({ pr: 99, head: H2, stage: "review", from: 1, chat: 1, message_id: 9, ts: "2026-11-07T10:00:00Z" }) + "\n";
        if (seeded) { mkdirSync(join(e.home, ".himmel")); writeFileSync(e.store, seed); }
        if (c.env) e.set(...c.env);
        await inbound(r, approveMsg(c.text ?? `approve 7 ${H1.slice(0, 7)}`, c.extra), replies, ran);
        const label = `${c.name} (seeded=${seeded})`;
        expect(existsSync(e.store), label).toBe(seeded);
        if (seeded) expect(readFileSync(e.store, "utf8"), label).toBe(seed);
        expect(ran, label).toEqual([]);
        if (c.reply) expect(replies.join("\n"), label).toContain(c.reply); else expect(replies, label).toEqual([]);
        expect(e.gh().length > 0, label).toBe(c.gh);
        expect(e.authorize(7, H1), label).toBe("1:");
      } finally { e.done(); }
    }
  }
});

test("approve: a gh call that outlives its bound is killed, replies cannot-read and stores nothing", async () => {
  const e = approveEnv(); const r = root(); const replies: string[] = [];
  try {
    e.set("STUB_MODE", "sleep");
    const { routeApprove } = await import("./chief-route");
    const t0 = Date.now();
    await routeApprove(approveMsg(`approve 7 ${H1.slice(0, 7)}`) as never, { kind: "approve", pr: 7, prefix: H1.slice(0, 7) }, gate(replies), { ghTimeoutMs: 300 });
    expect(Date.now() - t0).toBeLessThan(5000);
    expect(replies.join("\n")).toContain("cannot read PR 7; nothing stored");
    expect(existsSync(e.store)).toBe(false);
  } finally { e.done(); }
});

test("approve: only the verb writes the store: another word, a non-numeric PR or a trailing word is chat and writes nothing", async () => {
  const e = approveEnv(); const r = root(); const ran: string[] = [];
  try {
    for (const text of ["approved 7 a1a1a1a", "approve seven a1a1a1a", "approve 7", "approve 7 a1a1a1a and more", "approve 7 zzzzzzz"]) await inbound(r, approveMsg(text), [], ran);
    expect(existsSync(e.store)).toBe(false);
    expect(e.gh()).toEqual([]);
    expect(readdirSync(e.home).includes(".himmel")).toBe(false);
  } finally { e.done(); }
});

import { realpathSync } from "node:fs";

const ROUTE_TS = join(import.meta.dir, "chief-route.ts");
const routeCli = async (...args: string[]) => {
  const p = Bun.spawn(["bun", ROUTE_TS, ...args], { stdout: "pipe", stderr: "pipe" });
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  return { code: await p.exited, out, err };
};
const ROUND_KEY = "HIMMEL-9701";
const roundsDir = (specs: string) => join(specs, "ledgers", "spec-rounds");
const ledgerRows = (specs: string, key: string) => readFileSync(join(roundsDir(specs), `${key}.jsonl`), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const ledgerFolder = (specs: string) => readdirSync(roundsDir(specs)).filter((n) => n !== "round-seed.jsonl.lock").sort();
const specsTree = () => {
  const specs = join(realpathSync(root()), "specs"); mkdirSync(join(specs, "designs"), { recursive: true }); mkdirSync(join(specs, "plans"), { recursive: true });
  return { specs, dir: join(specs, "designs"), plans: join(specs, "plans") };
};
const ret = (verdict: string, ...lines: string[]) => `critic return\n${lines.map((l) => `${l}\n`).join("")}${verdict}\n`;
const front = (key: string, body: string) => `---\ntickets: ${key}\n---\n${body}`;

test("R18: the first round of a key with no seed row needs a front matter tickets: line naming it, and the refusal sits beside its siblings (T17)", async () => {
  const t = specsTree();
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const spec = join(t.dir, `${ROUND_KEY}-x.md`); const v = `${spec}.critic-spec-r1.md`;
  const text = "# X\n\nno front matter\n";
  writeFileSync(spec, text); writeFileSync(v, ret("SPEC CLEAN", `read ${sha(text)}`));
  const refused = await seal(v, spec, sha(text));
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain(`${spec}: front matter has no tickets: line naming ${ROUND_KEY}`);
  expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
  expect(existsSync(join(roundsDir(t.specs), `${ROUND_KEY}.jsonl`))).toBe(false);
  for (const other of [`${ROUND_KEY}0`, `${ROUND_KEY}OTHER`]) {
    const prefix = front(other, text);
    writeFileSync(spec, prefix); writeFileSync(v, ret("SPEC CLEAN", `read ${sha(prefix)}`));
    expect((await seal(v, spec, sha(prefix))).err).toContain(`front matter has no tickets: line naming ${ROUND_KEY}`);
  }
  expect(ledgerFolder(t.specs)).toEqual([`${ROUND_KEY}.jsonl.lock`, "manifest.json"]);
  const named = front(ROUND_KEY, text);
  writeFileSync(spec, named); writeFileSync(v, ret("SPEC CLEAN", `read ${sha(named)}`));
  expect((await seal(v, spec, sha(named))).code).toBe(0);
  expect(ledgerRows(t.specs, ROUND_KEY).map((r) => [r.row, r.critic, r.round])).toEqual([["round", "spec", 1]]);
  const s = specsTree(); const old = join(s.dir, `${ROUND_KEY}-y.md`);
  writeFileSync(old, text); writeFileSync(`${old}.critic-spec-r1.md`, ret("SPEC FINDINGS 1", "- **a1** (minor) a note"));
  expect((await routeCli("round-seed", "--all", s.specs)).code).toBe(0);
  const r2 = `${old}.critic-spec-r2.md`; writeFileSync(r2, ret("SPEC CLEAN", `read ${sha(text)}`));
  expect((await seal(r2, old, sha(text))).code).toBe(0);
  expect(ledgerRows(s.specs, ROUND_KEY).map((r) => [r.row, r.critic === undefined ? r.spec : r.round])).toEqual([["seed", 1], ["round", 2]]);
});

test("a seal whose verdict is named for one ticket and whose read file belongs to another is refused, beside its sibling that seals", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${ROUND_KEY}-x.md`); const b = join(t.dir, "HIMMEL-9702-y.md");
  const aText = front(ROUND_KEY, "# A\n"); const bText = front("HIMMEL-9702", "# B\n");
  writeFileSync(a, aText); writeFileSync(b, bText);
  const v = `${a}.critic-spec-r1.md`; writeFileSync(v, ret("SPEC CLEAN", `read ${sha(aText)} and ${sha(bText)}`));
  const refused = await seal(v, b, sha(bText));
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain(`${basename(v)} is named for ${ROUND_KEY} but the file it read belongs to HIMMEL-9702; the seal is refused`);
  expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
  expect(ledgerFolder(t.specs)).toEqual(["manifest.json"]);
  expect((await seal(v, a, sha(aText))).code).toBe(0);
  expect(ledgerRows(t.specs, ROUND_KEY).map((r) => r.row)).toEqual(["round"]);
});

test("a seal for a spec with no ticket key in its path is refused, beside a spec in a ticket folder that seals", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const keyless = join(t.dir, "plain.md"); const text = front(ROUND_KEY, "# P\n");
  writeFileSync(keyless, text);
  const v = `${keyless}.critic-spec-r1.md`; writeFileSync(v, ret("SPEC CLEAN", `read ${sha(text)}`));
  const refused = await seal(v, keyless, sha(text));
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain(`${keyless}: has no ticket key; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
  expect(ledgerFolder(t.specs)).toEqual(["manifest.json"]);
  mkdirSync(join(t.specs, ROUND_KEY)); const folder = join(t.specs, ROUND_KEY, "design.md");
  writeFileSync(folder, text); writeFileSync(`${folder}.critic-spec-r1.md`, ret("SPEC CLEAN", `read ${sha(text)}`));
  expect((await seal(`${folder}.critic-spec-r1.md`, folder, sha(text))).code).toBe(0);
  expect(ledgerRows(t.specs, ROUND_KEY).map((r) => r.row)).toEqual(["round"]);
});

test("R-sha: returnSha drops CONTENT-SHA256 lines, trailing whitespace and trailing blank lines; a second seal of one return writes a seal row, not a round", async () => {
  const { returnSha } = await import("./chief-route");
  const plain = "a finding\nSPEC CLEAN\n";
  expect(returnSha(plain)).toBe(sha(plain));
  for (const same of ["a finding  \nCONTENT-SHA256 " + "a".repeat(64) + " x.md\nSPEC CLEAN", "a finding\nSPEC CLEAN\n\n\n", "a finding\r\nSPEC CLEAN  \r\n"]) expect(returnSha(same)).toBe(sha(plain));
  expect(returnSha("a finding\nSPEC FINDINGS 1\n")).not.toBe(sha(plain));
  const none = specsTree(); const nspec = join(none.dir, "plain.md"); writeFileSync(nspec, "# P\n");
  writeFileSync(`${nspec}.critic-spec-r1.md`, ret("SPEC CLEAN", `read ${sha("# P\n")}`));
  expect((await seal(`${nspec}.critic-spec-r1.md`, nspec, sha("# P\n"))).err).toContain(`no round manifest under ${none.specs}; run round-seed --all once`);
  expect(existsSync(join(none.specs, "ledgers"))).toBe(false);
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const md = join(t.dir, `${ROUND_KEY}-x.md`); const html = join(t.dir, `${ROUND_KEY}-x.html`);
  const mdText = front(ROUND_KEY, "# X\n"); const htmlText = "<h1>X</h1>\n";
  writeFileSync(md, mdText); writeFileSync(html, htmlText);
  const v = `${md}.critic-spec-r1.md`; writeFileSync(v, ret("SPEC CLEAN", `read ${sha(mdText)} and ${sha(htmlText)}`));
  expect((await seal(v, md, sha(mdText))).code).toBe(0);
  expect((await seal(v, html, sha(htmlText))).code).toBe(0);
  const rows = ledgerRows(t.specs, ROUND_KEY);
  expect(rows.map((r) => r.row)).toEqual(["round", "seal"]);
  expect(rows[0]).toMatchObject({ v: 1, key: ROUND_KEY, critic: "spec", round: 1, epoch: 0, mode: "full", verdict: "SPEC CLEAN", verdict_path: v, read_path: md, read_sha: sha(mdText), findings: [], unrated_ids: [] });
  expect(rows[0].return_sha).toBe(returnSha(readFileSync(v, "utf8")));
  expect(typeof rows[0].ts).toBe("number");
  expect(rows[1]).toMatchObject({ v: 1, key: ROUND_KEY, row: "seal", return_sha: rows[0].return_sha, read_path: html, read_sha: sha(htmlText) });
  for (const s of [mdText, htmlText]) expect(readFileSync(join(roundsDir(t.specs), ROUND_KEY, sha(s)), "utf8")).toBe(s);
  const v2 = `${md}.critic-spec-r2.md`; writeFileSync(v2, ret("SPEC FINDINGS 1", `read ${sha(mdText)}`, "- **n1** (major) changed"));
  expect((await seal(v2, md, sha(mdText))).code).toBe(0);
  expect(ledgerRows(t.specs, ROUND_KEY).at(-1)).toMatchObject({ row: "round", round: 2, findings: [{ id: "n1", severity: "major" }] });
});

test("R-sha (seeded): a seeded round-3 return sealed on another file writes a seal row, the round stays 3", async () => {
  const t = specsTree(); const md = join(t.dir, `${ROUND_KEY}-s.md`); const html = join(t.dir, `${ROUND_KEY}-s.html`);
  const mdText = front(ROUND_KEY, "# S\n"); const htmlText = "<h1>S</h1>\n";
  writeFileSync(md, mdText); writeFileSync(html, htmlText);
  const r3 = `${md}.critic-spec-r3.md`;
  writeFileSync(r3, `critic return, read ${sha(mdText)} and ${sha(htmlText)}\nCONTENT-SHA256 ${sha(mdText)} ${basename(md)}\nSPEC FINDINGS 0\n`);
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const seeded = ledgerRows(t.specs, ROUND_KEY)[0];
  expect(seeded.latest.spec.map((x: { verdict_path: string }) => x.verdict_path)).toEqual([r3]);
  expect((await seal(r3, html, sha(htmlText))).code).toBe(0);
  const rows = ledgerRows(t.specs, ROUND_KEY);
  expect(rows.map((r) => r.row)).toEqual(["seed", "seal"]);
  expect(rows[1]).toMatchObject({ return_sha: seeded.latest.spec[0].return_sha, read_path: html, read_sha: sha(htmlText) });
  expect(readFileSync(join(roundsDir(t.specs), ROUND_KEY, sha(htmlText)), "utf8")).toBe(htmlText);
});

test("R-seed-forms: round-seed reads every critic name form, takes the highest round per kind, and skips code and judge returns", async () => {
  const t = specsTree();
  const w = (name: string, text: string) => { writeFileSync(join(t.dir, name), text); return join(t.dir, name); };
  w(`${ROUND_KEY}-x.md.critic-spec-r2.md`, ret("SPEC FINDINGS 1", "- **a1** (major) older"));
  const r3 = w(`${ROUND_KEY}-x.critic-r3.md`, ret("SPEC FINDINGS 1", "- **b1** (minor) kindless"));
  const p2 = w(`${ROUND_KEY}-x.md.critic-plan-r2.md`, ret("PLAN FINDINGS 0"));
  const p2b = w(`${ROUND_KEY}-x.md.critic-plan-r2b.md`, ret("PLAN FINDINGS 0"));
  w(`${ROUND_KEY}-x.md.critic-plan-r1.md`, ret("PLAN FINDINGS 1", "- **p1** (minor) first"));
  w(`${ROUND_KEY}-x.md.critic-code-r4.md`, ret("CODE FINDINGS 1"));
  w(`${ROUND_KEY}-x.md.judge-r5.md`, ret("SPEC FINDINGS 1"));
  const nov = w(`${ROUND_KEY}-z.critic-r1.md`, "a return with no verdict line\n");
  const res = await routeCli("round-seed", "--all", t.specs);
  expect(res.err).toBe("");
  expect(res.code).toBe(0);
  expect(res.out).toContain(`skipped ${nov}`);
  const [seed, ...rest] = ledgerRows(t.specs, ROUND_KEY);
  expect(rest).toEqual([]);
  expect(seed).toMatchObject({ v: 1, row: "seed", key: ROUND_KEY, spec: 3, plan: 2 });
  expect(seed.latest.spec.map((x: { verdict_path: string }) => x.verdict_path)).toEqual([r3]);
  expect(seed.latest.spec[0]).toMatchObject({ verdict: "SPEC FINDINGS 1", findings: [{ id: "b1", severity: "minor" }], unrated_ids: [] });
  expect(seed.latest.plan.map((x: { verdict_path: string }) => x.verdict_path)).toEqual([p2, p2b]);
  expect(JSON.parse(readFileSync(join(roundsDir(t.specs), "manifest.json"), "utf8"))).toMatchObject({ v: 1, keys: { [ROUND_KEY]: { spec: 3, plan: 2 } } });
  expect(existsSync(join(roundsDir(t.specs), `${ROUND_KEY}-z.jsonl`))).toBe(false);
});

test("R-seed-seals: the seed row records each latest return's seal lines as absolute paths and a snapshot of every file whose bytes still match", async () => {
  const t = specsTree(); const md = join(t.dir, `${ROUND_KEY}-s.md`); const plan = join(t.plans, `${ROUND_KEY}-s.plan.md`); const old = join(t.dir, `${ROUND_KEY}-s.old.md`);
  const mdText = "# S\n"; const planText = "# S plan\n"; const oldRead = "# S old, as the critic read it\n";
  writeFileSync(md, mdText); writeFileSync(plan, planText); writeFileSync(old, `${oldRead}edited after the critic read it\n`);
  const r3 = `${md}.critic-spec-r3.md`;
  writeFileSync(r3, `critic return\nCONTENT-SHA256 ${sha(mdText)} ${basename(md)}\nCONTENT-SHA256 ${sha(planText)} ../plans/${basename(plan)}\nCONTENT-SHA256 ${sha(oldRead)} ${basename(old)}\nSPEC FINDINGS 0\n`);
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const seed = ledgerRows(t.specs, ROUND_KEY)[0];
  expect(seed.latest.spec[0].seals).toEqual([
    { read_path: md, read_sha: sha(mdText) },
    { read_path: plan, read_sha: sha(planText) },
    { read_path: old, read_sha: sha(oldRead) },
  ]);
  expect(seed.latest.spec[0].return_sha).toBe(sha("critic return\nSPEC FINDINGS 0\n"));
  expect(readFileSync(join(roundsDir(t.specs), ROUND_KEY, sha(mdText)), "utf8")).toBe(mdText);
  expect(readFileSync(join(roundsDir(t.specs), ROUND_KEY, sha(planText)), "utf8")).toBe(planText);
  expect(existsSync(join(roundsDir(t.specs), ROUND_KEY, sha(oldRead)))).toBe(false);
  expect(seed.latest.plan).toEqual([]);
});

test("R-seed-twice: round-seed refuses a root that already holds a ledger, a snapshot folder or a manifest (T19), and seeds beside a lock file and ceilings.tsv", async () => {
  const t = specsTree(); writeFileSync(join(t.dir, `${ROUND_KEY}-x.md.critic-spec-r1.md`), ret("SPEC CLEAN"));
  mkdirSync(join(t.specs, "ledgers", "spec-rounds"), { recursive: true });
  writeFileSync(join(t.specs, "ledgers", "ceilings.tsv"), "x\n"); writeFileSync(join(roundsDir(t.specs), `${ROUND_KEY}.jsonl.lock`), "");
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const before = readFileSync(join(roundsDir(t.specs), "manifest.json"), "utf8");
  const again = await routeCli("round-seed", "--all", t.specs);
  expect(again.code).not.toBe(0);
  expect(again.err).toContain(`round-seed: ${t.specs}/ledgers/spec-rounds already holds a ledger, snapshot or manifest`);
  expect(readFileSync(join(roundsDir(t.specs), "manifest.json"), "utf8")).toBe(before);
  expect(ledgerRows(t.specs, ROUND_KEY).length).toBe(1);
  const s = specsTree(); mkdirSync(join(roundsDir(s.specs), "HIMMEL-1"), { recursive: true });
  expect((await routeCli("round-seed", "--all", s.specs)).err).toContain("already holds a ledger, snapshot or manifest");
  const l = specsTree(); mkdirSync(roundsDir(l.specs), { recursive: true }); writeFileSync(join(roundsDir(l.specs), `${ROUND_KEY}.jsonl`), "{}\n");
  expect((await routeCli("round-seed", "--all", l.specs)).err).toContain("already holds a ledger, snapshot or manifest");
});

test("round-seed refuses a root whose real folder is not named specs, and seeds a symlink to one under its real path", async () => {
  const base = realpathSync(root()); const other = join(base, "spec-store"); mkdirSync(join(other, "designs"), { recursive: true });
  writeFileSync(join(other, "designs", `${ROUND_KEY}-x.md.critic-spec-r1.md`), ret("SPEC CLEAN"));
  const named = await routeCli("round-seed", "--all", other);
  expect(named.code).not.toBe(0);
  expect(named.err).toContain(`round-seed: ${other} is not a specs root; seals look for the ledger under the last folder named specs`);
  expect(existsSync(join(other, "ledgers"))).toBe(false);
  const link = join(base, "specs"); symlinkSync(other, link);
  const viaLink = await routeCli("round-seed", "--all", link);
  expect(viaLink.code).not.toBe(0);
  expect(viaLink.err).toContain(`round-seed: ${other} is not a specs root`);
  const t = specsTree(); const alias = join(realpathSync(root()), "alias"); symlinkSync(t.specs, alias);
  writeFileSync(join(t.dir, `${ROUND_KEY}-x.md.critic-spec-r1.md`), ret("SPEC CLEAN"));
  expect((await routeCli("round-seed", "--all", alias)).code).toBe(0);
  expect(ledgerRows(t.specs, ROUND_KEY).map((r) => r.row)).toEqual(["seed"]);
});

test("round-seed removes what it wrote when it fails, so the root can be seeded again", async () => {
  const t = specsTree();
  for (const key of [ROUND_KEY, "HIMMEL-9702"]) {
    const md = join(t.dir, `${key}-x.md`); const text = `# ${key}\n`;
    writeFileSync(md, text); writeFileSync(`${md}.critic-spec-r1.md`, `critic return\nCONTENT-SHA256 ${sha(text)} ${basename(md)}\nSPEC CLEAN\n`);
  }
  mkdirSync(roundsDir(t.specs), { recursive: true });
  writeFileSync(join(roundsDir(t.specs), "HIMMEL-9702"), "in the way");
  const failed = await routeCli("round-seed", "--all", t.specs);
  expect(failed.code).not.toBe(0);
  const held = () => readdirSync(roundsDir(t.specs)).filter((n) => n !== "round-seed.jsonl.lock").sort();
  expect(held()).toEqual(["HIMMEL-9702"]);
  unlinkSync(join(roundsDir(t.specs), "HIMMEL-9702"));
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  expect(held()).toEqual([ROUND_KEY, `${ROUND_KEY}.jsonl`, "HIMMEL-9702", "HIMMEL-9702.jsonl", "manifest.json"].sort());
});

test("two round-seed runs on one root: one seeds, the other is refused, and nothing the winner wrote is lost", async () => {
  const t = specsTree();
  for (const key of [ROUND_KEY, "HIMMEL-9702"]) {
    const md = join(t.dir, `${key}-x.md`); const text = `# ${key}\n`;
    writeFileSync(md, text); writeFileSync(`${md}.critic-spec-r1.md`, `critic return\nCONTENT-SHA256 ${sha(text)} ${basename(md)}\nSPEC CLEAN\n`);
  }
  const runs = await Promise.all([routeCli("round-seed", "--all", t.specs), routeCli("round-seed", "--all", t.specs), routeCli("round-seed", "--all", t.specs)]);
  expect(runs.map((r) => r.code).sort()).toEqual([0, 1, 1]);
  for (const r of runs.filter((x) => x.code !== 0)) expect(r.err).toContain("already holds a ledger, snapshot or manifest");
  expect(readdirSync(roundsDir(t.specs)).filter((n) => n !== "round-seed.jsonl.lock").sort()).toEqual([ROUND_KEY, `${ROUND_KEY}.jsonl`, "HIMMEL-9702", "HIMMEL-9702.jsonl", "manifest.json"].sort());
  for (const key of [ROUND_KEY, "HIMMEL-9702"]) expect(readFileSync(join(roundsDir(t.specs), key, sha(`# ${key}\n`)), "utf8")).toBe(`# ${key}\n`);
});

test("keyOf reads the ticket key by the D1 rule, and parseFindings gives every unlabeled finding a synthetic id (D3)", async () => {
  const { keyOf, parseFindings } = await import("./chief-route");
  expect(keyOf("/s/specs/designs/HIMMEL-9687-x.md")).toBe("HIMMEL-9687");
  expect(keyOf("/s/specs/designs/HIMMEL-96870-x.md")).toBe("HIMMEL-96870");
  expect(keyOf("/s/specs/designs/HIMMEL-9687.md")).toBe("HIMMEL-9687");
  expect(keyOf("/s/specs/HIMMEL-9687/design.md")).toBe("HIMMEL-9687");
  expect(keyOf("/s/specs/plans/2026-11-04-HIMMEL-8943-x-plan.md")).toBeNull();
  expect(keyOf("/s/specs/designs/design.md")).toBeNull();
  const text = [
    "intro prose with (major) in it",
    "- **F1** (major) first",
    "* **m-2.a** (minor; operator-critical: spend-grant) second",
    "- **F3** (medium; operator-critical: security) third",
    "- **F4** (minor; reopens F1) fourth",
    "- **F5** (major; regression) fifth",
    "- **F6** (high) a label outside the three does not parse",
    "SPEC FINDINGS 8",
  ].join("\n");
  const got = parseFindings(text, "spec", 4);
  expect(got.findings).toEqual([
    { id: "F1", severity: "major" },
    { id: "m-2.a", severity: "minor", critical: "spend-grant" },
    { id: "F3", severity: "medium", critical_refused: "security" },
    { id: "F4", severity: "minor", reopens: "F1" },
    { id: "F5", severity: "major", regression: true },
  ]);
  expect(got.unrated_ids).toEqual(["spec-r4-U1", "spec-r4-U2", "spec-r4-U3"]);
  expect(parseFindings("all good\nPLAN CLEAN\n", "plan", 1)).toEqual({ findings: [], unrated_ids: [] });
});

import { dirname, relative } from "node:path";
import { renderQuestion } from "../jira/src/release/verbatim.ts";

const CAP_KEY = "HIMMEL-9711";
const T1 = (kind: string) => `${CAP_KEY} ${kind} round 6 needs a blocking finding in round 5 of either kind; sign it under 848, its minors go to the build`;
const verdictFor = (kind: "SPEC" | "PLAN", findings: string[]) => (findings.length ? `${kind} FINDINGS ${findings.length}` : `${kind} CLEAN`);
const sealOn = async (v: string, reads: string[], verdict: string, ...lines: string[]) => {
  writeFileSync(v, ret(verdict, `${basename(v)} read ${reads.map((p) => sha(readFileSync(p, "utf8"))).join(" and ")}`, ...lines));
  let last = { code: 0, err: "" };
  for (const p of reads) { last = await seal(v, p, sha(readFileSync(p, "utf8"))); if (last.code !== 0) break; }
  return last;
};
const roundTree = async (spec3: string[], plan3: string[], withHtml = false, spec2: string[] = [], aBody = "# A\n") => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`); const html = join(t.dir, `${CAP_KEY}-a.html`);
  writeFileSync(a, front(CAP_KEY, aBody)); writeFileSync(plan, "# A plan\n"); if (withHtml) writeFileSync(html, "<h1>A</h1>\n");
  for (const n of [1, 2, 3, 4, 5]) {
    const s = n === 5 ? spec3 : n === 4 ? spec2 : []; const p = n === 5 ? plan3 : [];
    expect((await sealOn(`${a}.critic-spec-r${n}.md`, withHtml ? [a, html] : [a], verdictFor("SPEC", s), ...s)).err).toBe("");
    expect((await sealOn(`${a}.critic-plan-r${n}.md`, [plan], verdictFor("PLAN", p), ...p)).err).toBe("");
  }
  return { ...t, a, plan, html, r: dirname(t.specs) };
};
function markerFor(specs: string, key: string, kind: "spec" | "plan", r: number) {
  const rows = ledgerRows(specs, key);
  const row = rows.filter((x) => x.row === "round" && x.critic === kind && x.round === r - 1).at(-1) ?? rows.find((x) => x.row === "seed").latest[kind][0];
  return `CLOSURE-CHECK ${key} ${kind} r${r - 1} ${row.return_sha.slice(0, 12)}`;
}
const preSeal = (v: string, reads: string[], verdict: string, lines: string[], quoted = reads) =>
  writeFileSync(v, `critic return ${basename(v)}, read ${quoted.map((p) => sha(readFileSync(p, "utf8"))).join(" and ")}\n${lines.map((l) => `${l}\n`).join("")}${reads.map((p) => `CONTENT-SHA256 ${sha(readFileSync(p, "utf8"))} ${relative(dirname(v), p)}\n`).join("")}${verdict}\n`);
const seededTree = async (plan3: string[]) => {
  const t = specsTree(); const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`); const html = join(t.dir, `${CAP_KEY}-a.html`);
  writeFileSync(a, "# A\n\na seeded key needs no tickets: line\n"); writeFileSync(plan, "# A plan\n"); writeFileSync(html, "<h1>A</h1>\n");
  for (const n of [1, 2, 3, 4, 5]) {
    const s = n === 5 ? ["- **m1** (minor) a wording note"] : []; const p = n === 5 ? plan3 : [];
    preSeal(`${a}.critic-spec-r${n}.md`, [a], verdictFor("SPEC", s), s, [a, html]);
    preSeal(`${a}.critic-plan-r${n}.md`, [plan], verdictFor("PLAN", p), p);
  }
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  return { ...t, a, plan, html, r: dirname(t.specs) };
};
const S1B = 120_000;

test("R1: a return named for another spec file of the ticket is refused at round 6 by the ledger count (T1), beside R2 whose round 5 holds a major and seals round 6", async () => {
  const t = await roundTree([], []);
  const b = join(t.dir, `${CAP_KEY}-b.md`); writeFileSync(b, front(CAP_KEY, "# B\n"));
  const v = `${b}.critic-spec-r1.md`;
  const refused = await sealOn(v, [b], "SPEC CLEAN");
  expect(refused.err).toContain(T1("spec"));
  expect(refused.code).not.toBe(0);
  expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
  expect(ledgerRows(t.specs, CAP_KEY).filter((r) => r.row === "round").length).toBe(10);
  const m = await roundTree(["- **M1** (major) still open"], []);
  const r6 = `${m.a}.critic-spec-r6.md`;
  const four = await sealOn(r6, [m.a], "SPEC FINDINGS 1", markerFor(m.specs, CAP_KEY, "spec", 6), "- **M2** (major; reopens M1) still open");
  expect(four.err).toBe("");
  expect(ledgerRows(m.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "spec", round: 6, verdict_path: r6 });
  const five = await sealOn(`${m.a}.critic-spec-r7.md`, [m.a], "SPEC CLEAN");
  expect(five.err).toContain(`${CAP_KEY} writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)`);
}, S1B);

test("R3d: a plan round-3 major opens spec round 6 too, beside R1's fixture where both round 3s are clean (T1)", async () => {
  const t = await roundTree([], ["- **P1** (major) the plan misses a step"]);
  const r6 = `${t.a}.critic-spec-r6.md`;
  const res = await sealOn(r6, [t.a], "SPEC CLEAN", markerFor(t.specs, CAP_KEY, "spec", 6));
  expect(res.err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "spec", round: 6, verdict_path: r6 });
  const c = await roundTree([], []);
  expect((await sealOn(`${c.a}.critic-spec-r6.md`, [c.a], "SPEC CLEAN")).err).toContain(T1("spec"));
  expect((await sealOn(`${c.a}.critic-plan-r6.md`, [c.plan], "PLAN CLEAN")).err).toContain(T1("plan"));
}, S1B);

test("R10: deleting every critic file does not lower the count: the next seal reads round 6, as it does with the files kept", async () => {
  for (const del of [true, false]) {
    const t = await roundTree(["- **M1** (major) still open"], []);
    if (del) for (const n of readdirSync(t.dir)) if (n.includes(".critic-")) unlinkSync(join(t.dir, n));
    const v = `${t.a}.critic-spec-r${del ? 1 : 4}.md`;
    const res = await sealOn(v, [t.a], "SPEC FINDINGS 1", markerFor(t.specs, CAP_KEY, "spec", 6), "- **n1** (minor) a new return, not round 1's bytes again");
    expect(res.err, del ? "files deleted" : "files kept").toBe("");
    expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "spec", round: 6, verdict_path: v });
  }
}, S1B);

test("R10b: a seeded key whose ledger was deleted refuses the seal (T10), and so does a key whose snapshot folder outlived its ledger, beside the seals before the delete", async () => {
  const t = specsTree(); const a = join(t.dir, `${CAP_KEY}-a.md`); writeFileSync(a, front(CAP_KEY, "# A\n"));
  preSeal(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN", []);
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  expect((await sealOn(`${a}.critic-spec-r2.md`, [a], "SPEC CLEAN")).err).toBe("");
  unlinkSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`));
  const v3 = `${a}.critic-spec-r3.md`;
  const gone = await sealOn(v3, [a], "SPEC CLEAN");
  expect(gone.err).toContain(`${CAP_KEY} is in the round manifest but has no ledger; restore it from the state repo history`);
  expect(gone.code).not.toBe(0);
  expect(readFileSync(v3, "utf8")).not.toContain("CONTENT-SHA256");
  const other = "HIMMEL-9712"; const o = join(t.dir, `${other}-o.md`); writeFileSync(o, front(other, "# O\n"));
  expect((await sealOn(`${o}.critic-spec-r1.md`, [o], "SPEC CLEAN")).err).toBe("");
  unlinkSync(join(roundsDir(t.specs), `${other}.jsonl`));
  expect((await sealOn(`${o}.critic-spec-r2.md`, [o], "SPEC CLEAN")).err).toContain(`${other} is in the round manifest but has no ledger; restore it from the state repo history`);
}, S1B);

test("R10c: an emptied ledger is a deleted one: a seeded key and a key with a snapshot folder both refuse (T10), beside the seals before it was emptied", async () => {
  const t = specsTree(); const a = join(t.dir, `${CAP_KEY}-a.md`); writeFileSync(a, front(CAP_KEY, "# A\n"));
  preSeal(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN", []);
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  expect((await sealOn(`${a}.critic-spec-r2.md`, [a], "SPEC CLEAN")).err).toBe("");
  writeFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), "");
  const v3 = `${a}.critic-spec-r3.md`;
  const emptied = await sealOn(v3, [a], "SPEC CLEAN");
  expect(emptied.err).toContain(`${CAP_KEY} is in the round manifest but has no ledger; restore it from the state repo history`);
  expect(emptied.code).not.toBe(0);
  expect(readFileSync(v3, "utf8")).not.toContain("CONTENT-SHA256");
  const other = "HIMMEL-9712"; const o = join(t.dir, `${other}-o.md`); writeFileSync(o, front(other, "# O\n"));
  expect((await sealOn(`${o}.critic-spec-r1.md`, [o], "SPEC CLEAN")).err).toBe("");
  writeFileSync(join(roundsDir(t.specs), `${other}.jsonl`), "\n\n");
  const status = await routeCli("round-status", other, "--specs", t.specs);
  expect(status.err).toContain(`${other} is in the round manifest but has no ledger; restore it from the state repo history`);
  expect(status.code).not.toBe(0);
}, S1B);

test("R11: one unparseable ledger line refuses the seal, round-status, ledger-verify and the findings page (T11), and the same ledger without it seals", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`);
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(plan, "# A plan\n");
  expect((await sealOn(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN")).err).toBe("");
  expect((await sealOn(`${a}.critic-plan-r1.md`, [plan], "PLAN CLEAN")).err).toBe("");
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const good = readFileSync(ledger, "utf8");
  writeFileSync(ledger, `${good}{"v":1,"row":\n`);
  const t11 = `${CAP_KEY} ledger line ${good.split("\n").filter(Boolean).length + 1} does not parse; restore it from the state repo history`;
  const v2 = `${a}.critic-spec-r2.md`;
  const sealed = await sealOn(v2, [a], "SPEC CLEAN");
  expect(sealed.err).toContain(t11);
  expect(sealed.code).not.toBe(0);
  const status = await routeCli("round-status", CAP_KEY, "--specs", t.specs);
  expect(status.err).toContain(t11); expect(status.code).not.toBe(0);
  const verify = await routeCli("ledger-verify", `${a}.critic-spec-r1.md`);
  expect(verify.err).toContain(t11); expect(verify.code).not.toBe(0);
  const page = await sendFile(dirname(t.specs), "1", a);
  expect(page.err).toContain(t11); expect(page.lines).toEqual([]);
  writeFileSync(ledger, good);
  expect((await sealOn(v2, [a], "SPEC CLEAN")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "spec", round: 2 });
  const sealed2 = readFileSync(ledger, "utf8"); const top = ledgerRows(t.specs, CAP_KEY).at(-1);
  writeFileSync(ledger, `${sealed2}${JSON.stringify({ ...top, return_sha: "f".repeat(64), round: "x" })}\n`);
  const damaged = await routeCli("round-status", CAP_KEY, "--specs", t.specs);
  expect(damaged.err).toContain(`${CAP_KEY} ledger line ${sealed2.split("\n").filter(Boolean).length + 1} does not parse; restore it from the state repo history`);
  expect(damaged.code).not.toBe(0);
  const { findings, ...noFindings } = top;
  writeFileSync(ledger, `${sealed2}${JSON.stringify({ ...noFindings, return_sha: "e".repeat(64), round: 3 })}\n`);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).err).toContain(`${CAP_KEY} ledger line ${sealed2.split("\n").filter(Boolean).length + 1} does not parse`);
  writeFileSync(ledger, sealed2);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).code).toBe(0);
}, S1B);

test("R12: planted critic files for a key the manifest lacks buy nothing: the real seal is round 1, the planted page gives T20, and the page with the real return sends", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`);
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(plan, "# A plan\n");
  for (const n of [1, 2, 3]) {
    preSeal(`${a}.critic-spec-r${n}.md`, [a], "SPEC FINDINGS 1", ["- **F1** (major) planted"]);
    preSeal(`${a}.critic-plan-r${n}.md`, [plan], "PLAN FINDINGS 1", ["- **P1** (major) planted"]);
  }
  const planted = await sendFile(dirname(t.specs), "1", a);
  expect(planted.err).toContain(`${a}.critic-spec-r3.md: its return is not in ${CAP_KEY}'s ledger`);
  expect(planted.lines).toEqual([]);
  const v = `${a}.critic-spec-r4.md`;
  expect((await sealOn(v, [a], "SPEC CLEAN")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).map((r) => [r.row, r.round])).toEqual([["round", 1]]);
  expect((await sealOn(`${a}.critic-plan-r4.md`, [plan], "PLAN CLEAN")).err).toBe("");
  const sent = await sendFile(dirname(t.specs), "1", a);
  expect(sent.err).toBe("");
  expect(sent.lines.at(-1)!.caption).toBe("SPEC CLEAN r1 | PLAN CLEAN r1");
}, S1B);

test("R12b: a specs root with no manifest refuses every seal (T12), and the same seal passes once the root is seeded", async () => {
  const t = specsTree(); const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`);
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(plan, "# A plan\n");
  const t12 = `no round manifest under ${t.specs}; run round-seed --all once`;
  for (const [v, p, verdict] of [[`${a}.critic-spec-r1.md`, a, "SPEC CLEAN"], [`${a}.critic-plan-r1.md`, plan, "PLAN CLEAN"]]) {
    const res = await sealOn(v, [p], verdict);
    expect(res.err).toContain(t12);
    expect(res.code).not.toBe(0);
    expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
  }
  expect(existsSync(join(t.specs, "ledgers"))).toBe(false);
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  expect((await sealOn(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN")).err).toBe("");
}, S1B);

test("R15 (control): returns sealed before the seed send and verify as mode seed, until a later round of their kind is sealed (T16)", async () => {
  const t = await seededTree(["- **P1** (major) the plan misses a step"]);
  const s3 = `${t.a}.critic-spec-r5.md`; const p3 = `${t.a}.critic-plan-r5.md`;
  const page = await sendFile(t.r, "1", t.a);
  expect(page.err).toBe("");
  expect(page.lines.at(-1)!.caption).toBe("SPEC FINDINGS 1 r5 | PLAN FINDINGS 1 r5");
  for (const [f, kind] of [[s3, "spec"], [p3, "plan"]]) {
    const v = await routeCli("ledger-verify", f, "--spec", t.a);
    expect(v.err).toBe("");
    expect(v.out.trim()).toBe(`${CAP_KEY} ${kind} round 5 seed`);
  }
  expect((await seal(s3, t.html, sha("<h1>A</h1>\n"))).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).map((r) => r.row)).toEqual(["seed", "seal"]);
  expect((await routeCli("ledger-verify", s3, "--spec", t.a)).out.trim()).toBe(`${CAP_KEY} spec round 5 seed`);
  expect((await sendFile(t.r, "1", t.a)).lines.length).toBe(2);
  const p4 = `${t.a}.critic-plan-r6.md`;
  expect((await sealOn(p4, [t.plan], "PLAN CLEAN", markerFor(t.specs, CAP_KEY, "plan", 6))).err).toBe("");
  const stale = await routeCli("ledger-verify", p3, "--spec", t.a);
  expect(stale.err).toContain(`${p3} is not ${CAP_KEY}'s latest plan round (round 6 is ${p4})`);
  expect(stale.code).not.toBe(0);
  expect((await routeCli("ledger-verify", s3, "--spec", t.a)).code).toBe(0);
}, S1B);

test("R15b (control): with both seeded round 3s holding only minors, a round-4 seal of either kind gives T1 and ledger-verify --spec passes on both round-3 files", async () => {
  const t = await seededTree(["- **p1** (minor) a plan note"]);
  for (const [kind, read, verdict] of [["spec", t.a, "SPEC CLEAN"], ["plan", t.plan, "PLAN CLEAN"]]) {
    const res = await sealOn(`${t.a}.critic-${kind}-r6.md`, [read], verdict);
    expect(res.err).toContain(T1(kind));
    expect(res.code).not.toBe(0);
  }
  for (const kind of ["spec", "plan"]) {
    const v = await routeCli("ledger-verify", `${t.a}.critic-${kind}-r5.md`, "--spec", t.a);
    expect(v.err).toBe("");
    expect(v.out.trim()).toBe(`${CAP_KEY} ${kind} round 5 seed`);
    const signed = await routeCli("ledger-verify", `${t.a}.critic-${kind}-r5.md`, "--spec", t.a, "--sign");
    expect(signed.err).toBe(""); expect(signed.code).toBe(0);
    expect(signed.out.trim()).toBe(`${CAP_KEY} ${kind} round 5 seed`);
  }
}, S1B);

test("R16: a clean latest critic file with a hand-appended CONTENT-SHA256 line no ledger row holds is refused by send-file (T15), beside the same file before the edit, which sends", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${CAP_KEY}-a.md`); const plan = join(t.plans, `${CAP_KEY}-a.md`); const html = join(t.dir, `${CAP_KEY}-a.html`);
  const htmlText = "<!doctype html><html><head></head><body><h1>A</h1></body></html>\n";
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(plan, "# A plan\n"); writeFileSync(html, htmlText);
  const s1 = `${a}.critic-spec-r1.md`;
  expect((await sealOn(s1, [a], "SPEC CLEAN")).err).toBe("");
  expect((await sealOn(`${a}.critic-plan-r1.md`, [plan], "PLAN CLEAN")).err).toBe("");
  const r = dirname(t.specs);
  const ok = await sendFile(r, "1", a);
  expect(ok.err).toBe(""); expect(ok.lines.length).toBe(1);
  writeFileSync(s1, readFileSync(s1, "utf8").replace("SPEC CLEAN\n", `CONTENT-SHA256 ${sha(htmlText)} ${basename(html)}\nSPEC CLEAN\n`));
  const res = await sendFile(r, "1", html);
  expect(res.err).toContain(`${s1}: the CONTENT-SHA256 line for ${html} is not in ${CAP_KEY}'s ledger`);
  expect(res.code).not.toBe(0);
  expect(res.lines.length).toBe(1);
}, S1B);

const OVR_WORDS = "open one more review round for this ticket";
const withOverrideWords = (args: string[]): string[] => {
  const at = args.indexOf("--no-words");
  if (at >= 0) return args.filter((_, i) => i !== at);
  if (args[0] !== "round-override" || args.includes("--decision")) return args;
  const specs = args[args.indexOf("--specs") + 1];
  mkdirSync(join(specs, "decisions"), { recursive: true });
  const f = join(specs, "decisions", "verbatim-decision-7311-operator.txt"); writeFileSync(f, `${args[1]} operator: ${OVR_WORDS}\n`);
  const later = new Date(Date.now() + 5000); utimesSync(f, later, later);
  return [...args, "--decision", "7311", "--quote", OVR_WORDS];
};
const verb = async (console: boolean, ...rawArgs: string[]) => {
  const args = withOverrideWords(rawArgs);
  const env: Record<string, string | undefined> = { ...process.env };
  if (console) env.HIMMEL_CONSOLE = "1"; else delete env.HIMMEL_CONSOLE;
  const p = Bun.spawn(["bun", ROUTE_TS, ...args], { env, stdout: "pipe", stderr: "pipe" });
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  return { code: await p.exited, out, err };
};
const T2 = (kind: string, r: number) => `${CAP_KEY} ${kind} round ${r} is a closure check of round ${r - 1}; build its input with closure-pack`;
const T3 = (kind: string, r: number, paths: string) => `${CAP_KEY} ${kind} round ${r} is a closure check of the files round ${r - 1} read: ${paths}`;
const T5 = (r: number) => `${CAP_KEY} writer round ${r} needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)`;
const T7 = (cls: string) => `round-critical: '${cls}' is not an operator-critical class (spend-grant, account-or-terms, public-policy, reverses-ruling)`;
const closeOn = (t: { a: string; specs: string }, kind: "spec" | "plan", r: number, reads: string[], verdict: string, ...lines: string[]) =>
  sealOn(`${t.a}.critic-${kind}-r${r}.md`, reads, verdict, markerFor(t.specs, CAP_KEY, kind, r), ...lines);
const decide = (specs: string, d: number, text: string, older = false) => {
  mkdirSync(join(specs, "decisions"), { recursive: true });
  const f = join(specs, "decisions", `verbatim-decision-${d}-operator.txt`); writeFileSync(f, text);
  const later = new Date(Date.now() + (older ? -600_000 : 5000)); utimesSync(f, later, later);
  return f;
};
const critical = (console: boolean, specs: string, id: string, d: number, quote: string, ...more: string[]) =>
  verb(console, "round-critical", CAP_KEY, "--finding", id, "--decision", String(d), "--quote", quote, "--specs", specs, ...more);
const rowsOf = (specs: string, kind: string) => ledgerRows(specs, CAP_KEY).filter((x) => x.row === kind);
const status = async (specs: string) => JSON.parse((await routeCli("round-status", CAP_KEY, "--specs", specs, "--json")).out);
const MAJOR = ["- **M1** (major) still open"];
const SPEND = "approve the spend after another look";

test("round-status at writer round 7 names round-critical with the operator's words and never round-override, and a ledger holding an old override row still reads", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens M1) still open")).err).toBe("");
  const json = await status(t.specs);
  expect(json.writer).toBe(6);
  expect(json.why).toContain(T5(7)); expect(json.why).toContain("round-critical"); expect(json.why).toContain("operator's words"); expect(json.why).not.toContain("round-override");
  const plain = await routeCli("round-status", CAP_KEY, "--specs", t.specs);
  expect(plain.out).toContain("round-critical"); expect(plain.out).not.toContain("round-override");
  const r6 = rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 6);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "override", epoch: 0, round_opened: 7, findings: [{ id: "M2", severity: "major", critic: "spec", return_sha: r6.return_sha }], why: "the build cannot carry it", chief: "chief-x" })}\n`);
  const old = await status(t.specs);
  expect(old).toMatchObject({ writer: 6, overrideUsed: true, invalid: [] }); expect(old.why).not.toContain(T5(7));
  expect((await routeCli("ledger-verify", `${t.a}.critic-spec-r6.md`, "--spec", t.a)).code).toBe(0);
});

test("round-override needs the operator's decision and a quote the decision holds, and writes no row without them", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens M1) still open")).err).toBe("");
  const bare = await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--specs", t.specs, "--no-words");
  expect(bare.code).toBe(1); expect(bare.err).toBe("round-override: --decision is required\n");
  const noQuote = await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--decision", "7312", "--specs", t.specs, "--no-words");
  expect(noQuote.code).toBe(1); expect(noQuote.err).toBe("round-override: --quote is required\n");
  decide(t.specs, 7312, `${CAP_KEY} operator: ${OVR_WORDS}\n`);
  const lie = await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--decision", "7312", "--quote", "words the operator never wrote", "--specs", t.specs, "--no-words");
  expect(lie.code).toBe(1); expect(lie.err).toContain("round-override: decision 7312 does not hold the quote");
  const { roundOverride } = await import("./chief-route.ts");
  const consoleWas = process.env.HIMMEL_CONSOLE; process.env.HIMMEL_CONSOLE = "1";
  try { await expect(roundOverride(t.specs, CAP_KEY, { findings: ["M2"], why: "w", chief: "chief-x", decision: "7399", quote: OVR_WORDS })).rejects.toThrow("round-override: 0 files match specs/decisions/verbatim-decision-7399-*.txt"); }
  finally { if (consoleWas === undefined) Reflect.deleteProperty(process.env, "HIMMEL_CONSOLE"); else process.env.HIMMEL_CONSOLE = consoleWas; }
  expect(rowsOf(t.specs, "override")).toEqual([]);
});

test("R2, R3, R3b, R3c: round 6 is a closure check: no marker gives T2, a new file gives T3, an edited snapshot gives T4 from closure-pack and the seal, and the marked return on the sealed file seals as closure", async () => {
  const t = await roundTree(MAJOR, []);
  const r6 = `${t.a}.critic-spec-r6.md`; const lines = ["- **M2** (major; reopens M1) still open", "- **n1** (major) a new class in unchanged text"];
  const plain = await sealOn(r6, [t.a], "SPEC FINDINGS 2", ...lines);
  expect(plain.err).toContain(T2("spec", 6)); expect(plain.code).not.toBe(0);
  expect(readFileSync(r6, "utf8")).not.toContain("CONTENT-SHA256");
  const v2 = join(t.dir, `${CAP_KEY}-a-v2.md`); writeFileSync(v2, front(CAP_KEY, "# A v2\n"));
  const moved = await closeOn(t, "spec", 6, [v2], "SPEC FINDINGS 2", ...lines);
  expect(moved.err).toContain(T3("spec", 6, t.a)); expect(moved.code).not.toBe(0);
  const snap = join(roundsDir(t.specs), CAP_KEY, sha(front(CAP_KEY, "# A\n"))); const good = readFileSync(snap, "utf8");
  writeFileSync(snap, "tampered\n");
  const T4 = `snapshot ${sha(good)} was edited`;
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.err).toContain(T4); expect(pack.code).not.toBe(0);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", ...lines)).err).toContain(T4);
  writeFileSync(snap, good);
  const ok = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", ...lines);
  expect(ok.err).toBe("");
  const row = ledgerRows(t.specs, CAP_KEY).at(-1);
  expect(row).toMatchObject({ row: "round", critic: "spec", round: 6, mode: "closure", verdict_path: r6 });
  expect(row.findings).toMatchObject([{ id: "M2", class: "reopens" }, { id: "n1", class: "out-of-closure" }]);
}, S1B);

test("a closure return reopening R5-M1 classes as blocking against the bare open id M1, and a reopen of an id that was never open stays out-of-closure", async () => {
  const t = await roundTree(MAJOR, []);
  const ok = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens R5-M1) still open", "- **n1** (major; reopens R5-Z9) never open", "- **n2** (major; reopens Z9) never open");
  expect(ok.err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "M2", class: "reopens" }, { id: "n1", class: "out-of-closure" }, { id: "n2", class: "out-of-closure" }]);
  const over = (id: string) => verb(true, "round-override", CAP_KEY, "--findings", id, "--why", "the build cannot carry it", "--chief", "chief-x", "--specs", t.specs);
  expect((await over("n1")).err).toContain(`round-override: n1 is not an open blocking finding of ${CAP_KEY}'s latest round`);
  expect((await over("M2")).code).toBe(0);
});

test("R4, R5, R8, R9: round 7 needs a record (T5); the override names only an open blocking id of the latest round (T9), once (T8), and only from the console", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens M1) still open", "- **n1** (minor) a note")).err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toContain(T5(7));
  const over = (console: boolean, ids: string) => verb(console, "round-override", CAP_KEY, "--findings", ids, "--why", "the build cannot carry it", "--chief", "chief-x", "--specs", t.specs);
  const T9 = (id: string) => `round-override: ${id} is not an open blocking finding of ${CAP_KEY}'s latest round`;
  for (const id of ["n1", "M1", "nope"]) { const r = await over(true, id); expect(r.err).toContain(T9(id)); expect(r.code).not.toBe(0); }
  const bare = await over(false, "M2"); expect(bare.code).not.toBe(0); expect(rowsOf(t.specs, "override")).toEqual([]);
  expect((await over(true, "M2")).code).toBe(0);
  expect(rowsOf(t.specs, "override")).toMatchObject([{ key: CAP_KEY, round_opened: 7, why: "the build cannot carry it", chief: "chief-x", findings: [{ id: "M2", severity: "major", critic: "spec" }] }]);
  const five = await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN");
  expect(five.err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", round: 7, mode: "closure" });
  const again = await over(true, "M2");
  expect(again.err).toContain(`round-override: ${CAP_KEY} already used its one override`); expect(again.code).not.toBe(0);
  expect(rowsOf(t.specs, "override").length).toBe(1);
}, S1B);

test("round override nonblocking hint preserves refusal and names the normal verified carry inputs", async () => {
  const t = await roundTree(["- **F1** (minor) spec note"], ["- **F1** (medium) plan note"]);
  const refused = await verb(true, "round-override", CAP_KEY, "--findings", "F1", "--why", "carry the notes", "--chief", "chief-x", "--specs", t.specs);
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("not an open blocking finding");
  for (const input of ["normal signing", "--spec", "canonical spec", "--plan", "distinct canonical plan", "both actual latest paired", "--verdict", "verified carry", "frozen bytes unchanged"]) expect(refused.err).toContain(input);
  expect(rowsOf(t.specs, "override")).toEqual([]);

  const criticalTree = await roundTree(["- **O1** (minor; operator-critical: spend-grant) needs a ruling"], []);
  const held = await verb(true, "round-override", CAP_KEY, "--findings", "O1", "--why", "carry it", "--chief", "chief-x", "--specs", criticalTree.specs);
  expect(held.code).not.toBe(0);
  expect(held.err).toContain("operator rules on them first (round-critical)");
  expect(held.err).not.toContain("verified carry");
}, S1B);

const QUOTE_OLD = "# A\n\nthe realpath of the primary checkout is read by cd and pwd\n";
const QUOTE_NEW = "# A\n\nthe realpath of the primary checkout, resolved by realpath -e\n";
const QUOTED = "the realpath of the primary checkout, resolved by";
const closureTree = async (plan3: string[] = [], next = QUOTE_NEW) => {
  const t = await roundTree(MAJOR, plan3, false, [], QUOTE_OLD);
  writeFileSync(t.a, front(CAP_KEY, next));
  return t;
};
const overrideOf = (specs: string, ids: string) => verb(true, "round-override", CAP_KEY, "--findings", ids, "--why", "a regression the fix made", "--chief", "chief-x", "--specs", specs);

const legacyTree = async (spec3: string[], top = 5) => {
  const t = specsTree(); const a = join(t.dir, `${CAP_KEY}-a.md`); const html = join(t.dir, `${CAP_KEY}-a.html`);
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(html, "<h1>A</h1>\n");
  for (const n of Array.from({ length: top }, (_, i) => i + 1)) { const s = n === top ? spec3 : []; writeFileSync(`${a}.critic-spec-r${n}.md`, ret(verdictFor("SPEC", s), "a return from before the round ledger", ...s)); }
  expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  return { ...t, a, html };
};
const readLine = (p: string, shaOf = p) => `READ-SHA256 ${sha(readFileSync(shaOf, "utf8"))} ${p}`;

test("a round-4 closure seals over a round 5 that sealed no file, taking the files its READ-SHA256 lines quote as the baseline and recording that it was inferred", async () => {
  const t = await legacyTree(MAJOR);
  expect(ledgerRows(t.specs, CAP_KEY)[0].latest.spec[0].seals).toEqual([]);
  const ok = await closeOn(t, "spec", 6, [t.a, t.html], "SPEC FINDINGS 1", readLine(t.a), readLine(t.html), "- **M2** (major; reopens M1) still open");
  expect(ok.err).toBe("");
  const round4 = ledgerRows(t.specs, CAP_KEY).filter((x) => x.row === "round").at(-1);
  expect(round4).toMatchObject({ critic: "spec", round: 6, mode: "closure", baseline: "inferred", baseline_files: [{ read_path: t.a, read_sha: sha(readFileSync(t.a, "utf8")) }, { read_path: t.html, read_sha: sha(readFileSync(t.html, "utf8")) }] });
  expect(round4.findings).toMatchObject([{ id: "M2", class: "reopens" }]);
  expect(ledgerRows(t.specs, CAP_KEY).filter((x) => x.row === "seal").length).toBe(1);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toContain(T5(7));
});

test("a round-4 closure over a round 5 that sealed no file is still refused when its return quotes no READ line for the file it seals, or quotes another sha for it", async () => {
  const t = await legacyTree(MAJOR);
  const none = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open");
  expect(none.err).toContain(T3("spec", 6, "")); expect(none.code).not.toBe(0);
  const other = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", readLine(t.html), "- **M2** (major; reopens M1) still open");
  expect(other.err).toContain(T3("spec", 6, t.html)); expect(other.code).not.toBe(0);
  const wrong = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", `READ-SHA256 ${sha("not the spec")} ${t.a}`, "- **M2** (major; reopens M1) still open");
  expect(wrong.err).toContain(T3("spec", 6, t.a)); expect(wrong.code).not.toBe(0);
  expect(ledgerRows(t.specs, CAP_KEY).filter((x) => x.row === "round").length).toBe(0);
});

test("under an inferred baseline a regression finding is blocking, since no round 5 bytes show it out of closure, and the override can name it", async () => {
  const t = await legacyTree(MAJOR);
  const ok = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", readLine(t.a), "- **P1** (major; regression `the realpath of the primary checkout`) the fix broke it", "- **n1** (minor) a note");
  expect(ok.err).toBe("");
  const round4 = ledgerRows(t.specs, CAP_KEY).filter((x) => x.row === "round").at(-1);
  expect(round4.findings).toMatchObject([{ id: "P1", severity: "major", regression: true, class: "regression" }, { id: "n1", class: "out-of-closure" }]);
  expect((await overrideOf(t.specs, "P1")).code).toBe(0);
});

test("an inferred baseline serves round 6 only: a round-5 closure over a seeded round 6 that sealed no file is refused", async () => {
  const t = await legacyTree(MAJOR, 6);
  const over = await verb(true, "round-override", CAP_KEY, "--findings", "M1", "--why", "the build cannot carry it", "--chief", "chief-x", "--specs", t.specs);
  expect(over.err).toBe("");
  const five = await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 1", readLine(t.a), "- **M2** (major; reopens M1) still open");
  expect(five.err).toContain(T3("spec", 7, "")); expect(five.code).not.toBe(0);
});

test("baseline_files of an inferred baseline holds only the quoted files whose bytes match their quoted sha", async () => {
  const t = await legacyTree(MAJOR);
  const ok = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", readLine(t.a), `READ-SHA256 ${sha("not the page")} ${t.html}`, `READ-SHA256 ${sha("")} ${join(t.dir, "missing.md")}`, "- **M2** (major; reopens M1) still open");
  expect(ok.err).toBe("");
  const round4 = ledgerRows(t.specs, CAP_KEY).filter((x) => x.row === "round").at(-1);
  expect(round4.baseline_files).toEqual([{ read_path: t.a, read_sha: sha(readFileSync(t.a, "utf8")) }]);
});

test("a round 5 that sealed a file keeps the strict match: a closure return quoting another file for its READ line is refused", async () => {
  const t = await roundTree(MAJOR, []);
  const v2 = join(t.dir, `${CAP_KEY}-a-v2.md`); writeFileSync(v2, front(CAP_KEY, "# A v2\n"));
  const moved = await closeOn(t, "spec", 6, [v2], "SPEC FINDINGS 1", readLine(v2), "- **M2** (major; reopens M1) still open");
  expect(moved.err).toContain(T3("spec", 6, t.a)); expect(moved.code).not.toBe(0);
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).not.toHaveProperty("baseline");
});

test("closure-pack for a round 5 that sealed no file says the closure return's READ-SHA256 lines are the baseline", async () => {
  const t = await legacyTree(MAJOR);
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.code).toBe(0);
  expect(pack.out).toContain("round 5 sealed no file; the READ-SHA256 lines of the closure return are its baseline");
});

test("a closure return whose regression heading holds its quote inside the parenthesis is a blocking regression the override can name; a minor finding in it is still refused", async () => {
  const t = await closureTree();
  const lines = [`- **P1** (major; regression \`${QUOTED}\`) the fix did not resolve the path`, "- **n1** (minor) a note"];
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", ...lines)).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", severity: "major", regression: true, class: "regression" }, { id: "n1", class: "out-of-closure" }]);
  const minor = await overrideOf(t.specs, "n1");
  expect(minor.err).toContain(`round-override: n1 is not an open blocking finding of ${CAP_KEY}'s latest round`); expect(minor.code).not.toBe(0);
  const ok = await overrideOf(t.specs, "P1");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "override")).toMatchObject([{ round_opened: 7, findings: [{ id: "P1", severity: "major", critic: "spec" }] }]);
});

test("a closure return whose regression heading escapes its quote backticks still classes as regression; a minor finding next to it keeps its class", async () => {
  const t = await closureTree();
  const lines = [`- **P1** (major; regression) the fix asks \\\`${QUOTED}\\\` and did not resolve the path`, "- **n1** (minor) a note"];
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", ...lines)).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", severity: "major", regression: true, class: "regression" }, { id: "n1", class: "out-of-closure" }]);
  expect((await overrideOf(t.specs, "P1")).code).toBe(0);
});

test("a quote with a semicolon inside the parenthesis, and a reopens heading with a quote, still read as their tags", async () => {
  const { parseFindings } = await import("./chief-route");
  const got = parseFindings(["- **P1** (major; regression `a; b; c`) x", "- **P2** (major; reopens M1 `the quoted line`) y", "- **P3** (major; regression) z", "- **P4** (minor; operator-critical: spend-grant `q`) w", "SPEC FINDINGS 4"].join("\n"), "spec", 4);
  expect(got.findings).toEqual([{ id: "P1", severity: "major", regression: true }, { id: "P2", severity: "major", reopens: "M1" }, { id: "P3", severity: "major", regression: true }, { id: "P4", severity: "minor", critical: "spend-grant" }]);
});

test("an ordinary full-mode major finding of the lagging kind is still an open blocking finding next to a closure return", async () => {
  const t = await closureTree(["- **P1** (major) a plan finding still open"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", `- **R1** (major; regression \`${QUOTED}\`) a fault`)).err).toBe("");
  const lag = await overrideOf(t.specs, "P1,R1");
  expect(lag.err).toContain("round-override: P1 is open only in plan, which lags the writer round; plan round 6 needs no record, so seal it as it is"); expect(lag.code).not.toBe(0);
  expect(rowsOf(t.specs, "override")).toEqual([]);
  const ok = await overrideOf(t.specs, "R1");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "override")).toMatchObject([{ findings: [{ id: "R1", critic: "spec" }] }]);
});

const QUOTE_WRAPPED = "# A\n\nthe realpath of the primary checkout,\n   resolved by realpath -e\n";
const CONTEXT_OLD = "# A\n\nthis context line is the same in both rounds\nold text\n";
const CONTEXT_NEW = "# A\n\nthis context line is the same in both rounds\nnew text\n";
const SPLIT_OLD = "# A\n\nthe first context line stays\nthe second context line stays\n";
const SPLIT_NEW = "# A\n\nthe first context line stays\n\nthe second context line stays\n";
const WRAPPED_P1 = `- **P1** (major; regression) the fix asks \`${QUOTED}\``;
const reclassOf = (console: boolean, specs: string, round = "spec:6") => verb(console, "round-reclass", CAP_KEY, "--round", round, "--why", "the quote wrapped", "--chief", "chief-x", "--specs", specs);
const storeAs = (specs: string, cls: (f: any) => string = () => "out-of-closure") => {
  const rows = ledgerRows(specs, CAP_KEY); const at = rows.findLastIndex(r => r.row === "round");
  rows[at].findings = rows[at].findings.map((f: any) => ({ ...f, class: cls(f) }));
  writeFileSync(ledgerFile(specs), rows.map(r => JSON.stringify(r)).join("\n") + "\n");
};
const storeAsBase = (specs: string) => storeAs(specs);
const appendReclass = (specs: string, findings: unknown[], returnSha?: string) => {
  const round = ledgerRows(specs, CAP_KEY).findLast(r => r.row === "round" && r.critic === "spec");
  appendFileSync(ledgerFile(specs), JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "reclass", epoch: 0, critic: "spec", round: 6, return_sha: returnSha ?? round.return_sha, findings, why: "w", chief: "c" }) + "\n");
};
const freshWrapped = async (plan3: string[] = [], ...more: string[]) => {
  const t = await closureTree(plan3, QUOTE_WRAPPED);
  expect((await closeOn(t, "spec", 6, [t.a], `SPEC FINDINGS ${1 + more.length}`, WRAPPED_P1, ...more)).err).toBe("");
  return t;
};
const refusedReclass = async (t: { specs: string }, console: boolean, text: string, round = "spec:6") => {
  const before = ledgerRows(t.specs, CAP_KEY).length; const res = await reclassOf(console, t.specs, round);
  expect(res.err).toContain(text); expect(res.code).not.toBe(0); expect(ledgerRows(t.specs, CAP_KEY).length).toBe(before);
};

test("CQ1: a major closure regression whose quote wraps over two changed lines is a blocking regression the override can name", async () => {
  const t = await freshWrapped();
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", class: "regression" }]);
  expect((await overrideOf(t.specs, "P1")).code).toBe(0);
});

test("CQ1b: a medium closure regression whose quote wraps over two changed lines is a regression", async () => {
  const t = await closureTree([], QUOTE_WRAPPED);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", `- **P1** (medium; regression) the fix asks \`${QUOTED}\``)).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", class: "regression" }]);
});

test("CQ2: a major closure regression whose quote is in no changed line is regression-unverified, carried by round-status and fold-list, and the override can name it", async () => {
  const t = await closureTree();
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **P1** (major; regression) `no such text is in either round`")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", class: "regression-unverified" }]);
  expect(JSON.stringify(JSON.parse((await routeCli("round-status", CAP_KEY, "--specs", t.specs, "--json")).out).latest.spec)).toContain('"class":"regression-unverified"');
  expect((await verb(false, "fold-list", "--spec", t.a, "--specs", t.specs)).out).toContain("- P1 (major; regression-unverified; regression) spec r6");
  expect((await overrideOf(t.specs, "P1")).code).toBe(0);
});

test("CQ3a: a medium closure regression whose quote is in no changed line stays out-of-closure", async () => {
  const t = await closureTree();
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **P1** (medium; regression) `no such text is in either round`")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P1", class: "out-of-closure" }]);
});

test("CQ3b: a quote that lies only in a context line does not match", async () => {
  const t = await roundTree(MAJOR, [], false, [], CONTEXT_OLD); writeFileSync(t.a, front(CAP_KEY, CONTEXT_NEW));
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **P2** (medium; regression) `this context line is the same in both rounds`")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P2", class: "out-of-closure" }]);
});

test("CQ3c: a quote over two context lines around an added blank line does not match", async () => {
  const t = await roundTree(MAJOR, [], false, [], SPLIT_OLD); writeFileSync(t.a, front(CAP_KEY, SPLIT_NEW));
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **P2** (medium; regression) `the first context line stays the second context line stays`")).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "P2", class: "out-of-closure" }]);
});

test("CQ4: round-reclass re-classes a stored closure round once, records one row, and round-override then opens round 7", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  expect((await overrideOf(t.specs, "P1")).code).not.toBe(0);
  const res = await reclassOf(true, t.specs);
  expect(res.err).toBe(""); expect(res.code).toBe(0);
  expect(res.out).toContain(`round-reclass: ${CAP_KEY} spec round 6: P1 out-of-closure to regression`);
  expect(rowsOf(t.specs, "reclass")).toMatchObject([{ critic: "spec", round: 6, findings: [{ id: "P1", class: "regression" }], chief: "chief-x" }]);
  const ok = await overrideOf(t.specs, "P1");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "override")).toMatchObject([{ round_opened: 7, findings: [{ id: "P1", critic: "spec" }] }]);
});

for (const order of [["plan:6", "spec:6"], ["spec:6", "plan:6"]]) {
  test(`CQ4b: round-reclass repairs the latest spec round and the latest plan round (${order.join(" then ")}), and both rows apply`, async () => {
    const t = await freshWrapped();
    expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 1", "- **Q1** (major; regression) `no such text is in either round`")).err).toBe("");
    const rows = ledgerRows(t.specs, CAP_KEY);
    for (const r of rows) if (r.row === "round" && r.round === 6) r.findings = r.findings.map((f: any) => ({ ...f, class: "out-of-closure" }));
    writeFileSync(ledgerFile(t.specs), rows.map(r => JSON.stringify(r)).join("\n") + "\n");
    for (const round of order) { const res = await reclassOf(true, t.specs, round); expect(res.err).toBe(""); expect(res.code).toBe(0); }
    expect(rowsOf(t.specs, "reclass")).toHaveLength(2);
    const st = await routeCli("round-status", CAP_KEY, "--specs", t.specs, "--json");
    expect(st.code).toBe(0); expect(JSON.parse(st.out)).toMatchObject({ invalid: [], latest: { spec: { findings: [{ id: "P1", class: "regression" }] }, plan: { findings: [{ id: "Q1", class: "regression-unverified" }] } } });
  });
}

test("CQ5a: round-reclass refuses off the chief console and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  await refusedReclass(t, false, "round-reclass: needs HIMMEL_CONSOLE=1");
});

test("CQ5b: round-reclass refuses a second run on the same round and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  expect((await reclassOf(true, t.specs)).code).toBe(0);
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 was already re-classed`);
});

test("CQ5c: round-reclass refuses when no class would change and writes nothing", async () => {
  const t = await freshWrapped();
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 has nothing to re-class`);
});

test("CQ5d: round-reclass refuses a round that a record follows and writes nothing", async () => {
  const t = await freshWrapped(); expect((await overrideOf(t.specs, "P1")).code).toBe(0); storeAsBase(t.specs);
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 is followed by an override record`);
});

test("CQ5e: round-reclass refuses a return edited after its seal and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs); appendFileSync(`${t.a}.critic-spec-r6.md`, "\nan edit after the seal\n");
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6's return changed since it was sealed`);
});

test("CQ5f: round-reclass refuses a full-mode round and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 3 is not the latest closure round of spec`, "spec:3");
});

test("CQ5g: round-reclass refuses a malformed --round and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  await refusedReclass(t, true, "round-reclass: --round is <spec|plan>:<round>, not 'spec-4'", "spec-4");
});

test("CQ5h: round-reclass refuses a round over an inferred baseline and writes nothing", async () => {
  const t = await legacyTree(MAJOR);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", readLine(t.a), "- **P1** (major; regression `the realpath of the primary checkout`) the fix broke it")).err).toBe("");
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 has an inferred baseline or a round 5 that sealed no file; nothing to re-class`);
});

test("CQ5i: round-reclass refuses a blank --why and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs); const before = ledgerRows(t.specs, CAP_KEY).length;
  const res = await verb(true, "round-reclass", CAP_KEY, "--round", "spec:4", "--why", " ", "--chief", "chief-x", "--specs", t.specs);
  expect(res.err).toContain("round-reclass: --round, --why and --chief are all required"); expect(res.code).not.toBe(0); expect(ledgerRows(t.specs, CAP_KEY).length).toBe(before);
});

test("CQ5j: round-reclass refuses a round that sealed one path at two shas and writes nothing", async () => {
  const t = await freshWrapped(); storeAsBase(t.specs);
  const x = ledgerRows(t.specs, CAP_KEY).findLast(r => r.row === "round" && r.critic === "spec");
  appendFileSync(ledgerFile(t.specs), JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "seal", return_sha: x.return_sha, read_path: x.read_path, read_sha: "0".repeat(64) }) + "\n");
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 sealed ${x.read_path} at more than one sha`);
});

test("CQ5k: round-reclass refuses when the recomputed classes would move a finding off blocking, and writes nothing", async () => {
  const t = await freshWrapped([], "- **m2** (medium; regression) `no such text is in either round`");
  storeAs(t.specs, (f: any) => f.id === "P1" ? "out-of-closure" : "regression");
  await refusedReclass(t, true, `round-reclass: ${CAP_KEY} spec round 6 would move m2 to out-of-closure, which the fold refuses; nothing was written`);
});

for (const fault of ["off-blocking", "severity", "untagged", "after-override", "twice", "wrong-sha", "reorder", "later-round"]) {
  test(`CQ6: the reader drops a reclass row that breaks a fold rule (${fault}), lists it as invalid, and keeps the stored classes`, async () => {
    const t = fault === "after-override" ? await freshWrapped(["- **P9** (major) a plan finding still open"]) : await freshWrapped([], "- **n1** (minor) a note");
    const stored = () => ledgerRows(t.specs, CAP_KEY).findLast(r => r.row === "round" && r.critic === "spec").findings;
    if (fault !== "off-blocking") storeAsBase(t.specs);
    if (fault === "after-override") {
      const p3 = ledgerRows(t.specs, CAP_KEY).find(r => r.row === "round" && r.critic === "plan" && r.round === 5);
      appendFileSync(ledgerFile(t.specs), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "override", epoch: 0, round_opened: 7, findings: [{ id: "P9", severity: "major", critic: "plan", return_sha: p3.return_sha }], why: "a legacy override", chief: "chief-x" })}\n`);
    }
    const up = stored().map((f: any) => f.id === "P1" ? { ...f, class: "regression" } : f);
    if (fault === "off-blocking") appendReclass(t.specs, stored().map((f: any) => f.id === "P1" ? { ...f, class: "out-of-closure" } : f));
    if (fault === "severity") appendReclass(t.specs, up.map((f: any) => f.id === "n1" ? { ...f, severity: "medium" } : f));
    if (fault === "untagged") appendReclass(t.specs, up.map((f: any) => f.id === "n1" ? { ...f, class: "regression" } : f));
    if (fault === "reorder") appendReclass(t.specs, [...up].reverse());
    if (fault === "later-round") { const x = ledgerRows(t.specs, CAP_KEY).findLast(r => r.row === "round" && r.critic === "spec");
      appendFileSync(ledgerFile(t.specs), JSON.stringify({ ...x, ts: Date.now(), round: 7, return_sha: "1".repeat(64) }) + "\n"); appendReclass(t.specs, up, x.return_sha); }
    if (fault === "after-override" || fault === "wrong-sha") appendReclass(t.specs, up, fault === "wrong-sha" ? "0".repeat(64) : undefined);
    if (fault === "twice") { appendReclass(t.specs, up); appendReclass(t.specs, up); }
    expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: reclass");
    expect(JSON.parse((await routeCli("round-status", CAP_KEY, "--specs", t.specs, "--json")).out).latest.spec.findings).toEqual(fault === "twice" ? up : stored());
    if (fault === "later-round") expect((await verb(false, "fold-list", "--spec", t.a, "--specs", t.specs)).out).toContain("- P1 (major; out-of-closure; regression) spec r6");
  });
}

test("R5b: a round whose findings carry no format line holds synthetic ids the override can name", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "prose, no finding line")).err).toBe("");
  const r = await verb(true, "round-override", CAP_KEY, "--findings", "spec-r6-U1", "--why", "no label", "--chief", "chief-x", "--specs", t.specs);
  expect(r.err).toBe(""); expect(r.code).toBe(0);
  expect(rowsOf(t.specs, "override")[0].findings).toMatchObject([{ id: "spec-r6-U1", severity: "unrated", critic: "spec" }]);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
}, S1B);

test("R6, R6c, R6d: round-critical needs the console, a decision naming the ticket and holding the quote, used once; a hand-appended row counts for nothing; a valid one opens round 7", async () => {
  const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
  decide(t.specs, 901, `${CAP_KEY} operator: ${SPEND}\n`); decide(t.specs, 902, `no ticket named here: ${SPEND}\n`); const d903 = decide(t.specs, 903, `${CAP_KEY} operator: something else\n`);
  const bare = await critical(false, t.specs, "C1", 901, SPEND); expect(bare.code).not.toBe(0); expect(rowsOf(t.specs, "critical")).toEqual([]);
  const other = await critical(true, t.specs, "C1", 902, SPEND);
  expect(other.err).toContain(`round-critical: decision 902 does not name ${CAP_KEY}`); expect(other.code).not.toBe(0);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", opens: 7, id: "C1", class: "spend-grant", decision: "903", quote: "a quote the file never holds", decision_path: d903, decision_sha: sha(readFileSync(d903, "utf8")), return_sha: "f".repeat(64) })}\n`);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: critical 903");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toContain(T5(7));
  expect((await status(t.specs)).critical_open).toMatchObject([{ id: "C1", class: "spend-grant" }]);
  const good = await critical(true, t.specs, "C1", 901, SPEND);
  expect(good.err).toBe(""); expect(good.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ key: CAP_KEY, opens: 7, id: "C1", class: "spend-grant", decision: "901", quote: SPEND, return_sha: rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 5).return_sha });
  expect((await status(t.specs)).critical_open).toEqual([]);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  const reused = await critical(true, t.specs, "C1", 901, SPEND);
  expect(reused.err).toContain(`round-critical: decision 901 was already used for ${CAP_KEY}`); expect(reused.code).not.toBe(0);
}, S1B);

test("round-critical --closure: an operator decision alone opens exactly one more writer round past the cap, closure-pack builds it, and the decision is spent", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect((await overrideOf(t.specs, "M2")).code).toBe(0);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  writeFileSync(t.a, front(CAP_KEY, "# A\n\na lint fix after the seal\n"));
  const closure = (d: number) => verb(true, "round-critical", CAP_KEY, "--decision", String(d), "--quote", SPEND, "--closure", "--specs", t.specs);
  const before = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(before.err).toContain(T5(8)); expect(before.code).not.toBe(0);
  decide(t.specs, 1349, `${CAP_KEY} operator: ${SPEND}\n`);
  const bare = await verb(false, "round-critical", CAP_KEY, "--decision", "1349", "--quote", SPEND, "--closure", "--specs", t.specs);
  expect(bare.code).not.toBe(0); expect(rowsOf(t.specs, "critical")).toEqual([]);
  const ok = await closure(1349);
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical")).toMatchObject([{ key: CAP_KEY, closure: true, opens: 8, decision: "1349", quote: SPEND }]);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).not.toContain("invalid");
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.err).toBe(""); expect(pack.code).toBe(0); expect(pack.out).toContain(markerFor(t.specs, CAP_KEY, "spec", 8));
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
  const again = await closure(1349);
  expect(again.err).toContain(`round-critical: decision 1349 was already used for ${CAP_KEY}`); expect(again.code).not.toBe(0);
  const seven = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(seven.err).toContain(T5(9)); expect(seven.code).not.toBe(0);
  const d = decide(t.specs, 1350, `${CAP_KEY} operator: ${SPEND}\n`);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", closure: true, epoch: 0, opens: 9, decision: "1349", quote: SPEND, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")) })}\n`);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: critical 1349");
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
});

test("round-critical --closure is refused below the cap, next to --finding, and on a decision a finding ruling already spent", async () => {
  const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
  decide(t.specs, 1351, `${CAP_KEY} operator: ${SPEND}\n`);
  const low = await verb(true, "round-critical", CAP_KEY, "--decision", "1351", "--quote", SPEND, "--closure", "--specs", t.specs);
  expect(low.err).toContain(`round-critical: ${CAP_KEY} writer round 6 needs no record; --closure is for a refused round only`); expect(low.code).not.toBe(0);
  const both = await critical(true, t.specs, "C1", 1351, SPEND, "--closure");
  expect(both.err).toContain("round-critical: --closure opens a round on the decision alone; drop --finding"); expect(both.code).not.toBe(0);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
  expect((await critical(true, t.specs, "C1", 1351, SPEND, "--no-round")).code).toBe(0);
  const spent = await verb(true, "round-critical", CAP_KEY, "--decision", "1351", "--quote", SPEND, "--closure", "--specs", t.specs);
  expect(spent.err).toContain(`round-critical: decision 1351 was already used for ${CAP_KEY}`); expect(spent.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical").length).toBe(1);
});

test("a decision a --closure round spent is never reused as a finding ruling: the verb refuses it and a hand-appended row reads invalid", async () => {
  const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
  const d = decide(t.specs, 1352, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await verb(true, "round-critical", CAP_KEY, "--decision", "1352", "--quote", SPEND, "--closure", "--specs", t.specs)).code).toBe(0);
  const reuse = await critical(true, t.specs, "C1", 1352, SPEND, "--no-round");
  expect(reuse.err).toContain(`round-critical: decision 1352 was already used for ${CAP_KEY}`); expect(reuse.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical").length).toBe(1);
  const r5 = rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 5);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", epoch: 0, opens: 0, id: "C1", class: "spend-grant", decision: "1352", quote: SPEND, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")), return_sha: r5.return_sha })}\n`);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: critical 1352");
  expect((await status(t.specs)).critical_open).toMatchObject([{ id: "C1", class: "spend-grant" }]);
});

const threeCriticals = async () => {
  const t = await roundTree(["- **F5** (major; operator-critical: spend-grant) grants a spend", "- **C6** (major; operator-critical: public-policy) sets a policy", "- **H3** (major; operator-critical: reverses-ruling) reverses a ruling"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **X1** (major) still open")).err).toBe("");
  return t;
};
const critRows = (specs: string) => rowsOf(specs, "critical");

test("multi-finding round-critical: one decision rules F5, C6 and H3 in one call, opens round 7 once, and the ledger reads three valid rows", async () => {
  const t = await threeCriticals(); decide(t.specs, 1205, `${CAP_KEY} operator: ${SPEND}\n`);
  const r = await critical(true, t.specs, "F5,C6,H3", 1205, SPEND);
  expect(r.err).toBe(""); expect(r.code).toBe(0);
  expect(critRows(t.specs).map((x) => [x.id, x.decision, x.opens])).toEqual([["F5", "1205", 7], ["C6", "1205", 0], ["H3", "1205", 0]]);
  const s = await status(t.specs); expect(s.critical_open).toEqual([]);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).not.toContain("invalid");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  const again = await critical(true, t.specs, "F5", 1205, SPEND);
  expect(again.err).toContain(`round-critical: decision 1205 was already used for ${CAP_KEY}`); expect(again.code).not.toBe(0);
  expect(critRows(t.specs).length).toBe(3);
});

test("multi-finding round-critical: a list is refused whole when the decision does not name the ticket or one id is bad, and a duplicate id", async () => {
  const t = await threeCriticals(); decide(t.specs, 1205, `${CAP_KEY} operator: ${SPEND}\n`); decide(t.specs, 1206, `no ticket here: ${SPEND}\n`);
  const named = await critical(true, t.specs, "F5,C6,H3", 1206, SPEND);
  expect(named.err).toContain(`round-critical: decision 1206 does not name ${CAP_KEY}`); expect(named.code).not.toBe(0);
  const unknown = await critical(true, t.specs, "F5,ZZ9", 1205, SPEND);
  expect(unknown.err).toContain("ZZ9 is not a finding"); expect(unknown.code).not.toBe(0);
  const dup = await critical(true, t.specs, "F5,F5", 1205, SPEND);
  expect(dup.err).toContain("F5 is named twice"); expect(dup.code).not.toBe(0);
  expect(critRows(t.specs)).toEqual([]);
  expect((await critical(true, t.specs, "F5", 1205, SPEND, "--no-round")).err).toBe("");
  const ruled = await critical(true, t.specs, "C6,F5", 1205, SPEND);
  expect(ruled.code).not.toBe(0); expect(critRows(t.specs).length).toBe(1);
  const minor = await roundTree(["- **S1** (minor; operator-critical: security) a note", "- **C1** (minor; operator-critical: spend-grant) a spend"], []);
  decide(minor.specs, 1205, `${CAP_KEY} operator: ${SPEND}\n`);
  const cls = await critical(true, minor.specs, "C1,S1", 1205, SPEND);
  expect(cls.err).toContain(T7("security")); expect(cls.code).not.toBe(0); expect(critRows(minor.specs)).toEqual([]);
});

test("multi-finding round-critical: a decision used for another finding may open the round once, and a second record opening the same round is refused", async () => {
  const t = await threeCriticals(); decide(t.specs, 1205, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "F5", 1205, SPEND, "--no-round")).err).toBe("");
  const open = await critical(true, t.specs, "C6", 1205, SPEND);
  expect(open.err).toBe(""); expect(open.code).toBe(0);
  expect(critRows(t.specs).map((x) => [x.id, x.opens])).toEqual([["F5", 0], ["C6", 7]]);
  const twice = await critical(true, t.specs, "H3", 1205, SPEND);
  expect(twice.err).toContain(`round-critical: decision 1205 was already used for ${CAP_KEY}`); expect(twice.code).not.toBe(0);
  expect((await critical(true, t.specs, "H3", 1205, SPEND, "--no-round")).err).toBe("");
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).not.toContain("invalid");
});

test("multi-finding round-critical: read side agrees: three hand-built rows of one decision are valid, a repeated (decision, finding) is invalid", async () => {
  const t = await threeCriticals(); const d = decide(t.specs, 1205, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "F5,C6,H3", 1205, SPEND)).err).toBe("");
  const rows = critRows(t.specs); expect(rows.length).toBe(3);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).not.toContain("invalid");
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ ...rows[1], ts: Date.now(), opens: 0 })}\n`);
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: critical 1205");
  expect(d).toContain("verbatim-decision-1205");
});

test("R7 (control), R6b: a tag outside the four classes opens nothing (T7); a minor spend-grant finding opens round 6 by itself, where the same fixture without the record gives T1", async () => {
  const t = await roundTree(["- **S1** (minor; operator-critical: security) a note"], []);
  decide(t.specs, 901, `${CAP_KEY} operator: ${SPEND}\n`);
  const r = await critical(true, t.specs, "S1", 901, SPEND);
  expect(r.err).toContain(T7("security")); expect(r.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
  expect((await status(t.specs)).critical_open).toEqual([]);
  const u = await roundTree(["- **O1** (minor; operator-critical: spend-grant) a spend"], []);
  decide(u.specs, 904, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await closeOn(u, "spec", 6, [u.a], "SPEC CLEAN")).err).toContain(T1("spec"));
  expect((await critical(true, u.specs, "O1", 904, SPEND)).err).toBe("");
  expect((await closeOn(u, "spec", 6, [u.a], "SPEC CLEAN")).err).toBe("");
  expect(ledgerRows(u.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", round: 6, mode: "closure" });
}, S1B);

test("R-pack-sha: closure-pack prints the marker, the open blocking findings, the sha of the md and the html round 5 sealed, and the diff of each against its snapshot; a clean round 5 gives T1", async () => {
  const t = await roundTree(MAJOR, [], true);
  const mdText = front(CAP_KEY, "# A\n"); const htmlText = "<h1>A</h1>\n";
  writeFileSync(t.a, `${mdText}a changed line here\n`);
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.err).toBe("");
  expect(pack.out.split("\n")[0]).toBe(markerFor(t.specs, CAP_KEY, "spec", 6));
  for (const s of [mdText, htmlText]) expect(pack.out).toContain(sha(s));
  expect(pack.out).toContain("- **M1** (major) still open");
  expect(pack.out).toContain("+a changed line here");
  const c = await roundTree([], []);
  const clean = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", c.specs);
  expect(clean.err).toContain(T1("spec")); expect(clean.code).not.toBe(0);
}, S1B);

test("R13-fold, R13b-fold: fold-list keeps round 5's minors after a closure round, drops the blocking id that round closed, and reads only its own ticket", async () => {
  const t = await roundTree(["- **m-a** (minor) one", "- **m-b** (medium) two", "- **M-c** (major) three"], []);
  const r5 = `${t.a}.critic-spec-r5.md`; const r6 = `${t.a}.critic-spec-r6.md`;
  const fold = async (spec: string) => (await verb(false, "fold-list", "--spec", spec, "--specs", t.specs));
  const before = await fold(t.a);
  expect(before.err).toBe("");
  expect(before.out.trim().split("\n")).toEqual([`- m-a (minor) spec r5 ${r5}`, `- m-b (medium) spec r5 ${r5}`, `- M-c (major) spec r5 ${r5}`]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **c1** (minor) a note on unchanged text")).err).toBe("");
  const key2 = "HIMMEL-9712"; const y = join(t.dir, `${key2}-y.md`); writeFileSync(y, front(key2, "# Y\n"));
  expect((await sealOn(`${y}.critic-spec-r1.md`, [y], "SPEC FINDINGS 1", "- **m-z** (minor) elsewhere")).err).toBe("");
  expect((await fold(t.a)).out.trim().split("\n")).toEqual([`- m-a (minor) spec r5 ${r5}`, `- m-b (medium) spec r5 ${r5}`, `- c1 (minor; out-of-closure) spec r6 ${r6}`]);
  expect((await fold(y)).out.trim().split("\n")).toEqual([`- m-z (minor) spec r1 ${y}.critic-spec-r1.md`]);
}, S1B);

test("fold-list kind scoped collisions preserve first-added provenance within each kind", async () => {
  const t = await roundTree(["- **F1** (minor) original spec note", "- **M1** (major) close this"], ["- **F1** (medium) plan note"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **F1** (medium) repeated note", "- **F2** (minor) later note")).err).toBe("");
  const folded = await verb(false, "fold-list", "--spec", t.a, "--specs", t.specs);
  expect(folded.code).toBe(0);
  expect(folded.out.trim().split("\n")).toEqual([
    `- F1 (minor) spec r5 ${t.a}.critic-spec-r5.md`,
    `- F2 (minor; out-of-closure) spec r6 ${t.a}.critic-spec-r6.md`,
    `- F1 (medium) plan r5 ${t.a}.critic-plan-r5.md`,
  ]);
}, S1B);

test("R19-status, R20: an open operator-critical finding is listed by round-status, refuses --sign (T18) and is named in the send-file lead; round-critical --no-round closes it and opens no round", async () => {
  const t = await roundTree(["- **o1** (minor; operator-critical: spend-grant) a spend"], []);
  const s3 = `${t.a}.critic-spec-r5.md`;
  expect((await status(t.specs)).critical_open).toEqual([{ id: "o1", class: "spend-grant", kind: "spec", round: 5, verdict_path: s3 }]);
  const sign = await routeCli("ledger-verify", s3, "--spec", t.a, "--sign");
  expect(sign.err).toContain(`${CAP_KEY} has open operator-critical findings: o1 (spend-grant); the operator rules on them first (round-critical)`); expect(sign.code).not.toBe(0);
  expect((await routeCli("ledger-verify", s3, "--spec", t.a)).code).toBe(0);
  const page = await sendFile(t.r, "1", t.a);
  expect(page.err).toBe("");
  expect(readFileSync(page.lines.at(-1)!.document_path as string, "utf8")).toContain("o1 (spend-grant)");
  decide(t.specs, 905, `${CAP_KEY} operator: ${SPEND}\n`);
  const done = await critical(true, t.specs, "o1", 905, SPEND, "--no-round");
  expect(done.err).toBe(""); expect(done.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ opens: 0, id: "o1" });
  expect(await status(t.specs)).toMatchObject({ critical_open: [], spec: 5, plan: 5 });
  const signed = await routeCli("ledger-verify", s3, "--spec", t.a, "--sign");
  expect(signed.err).toBe(""); expect(signed.code).toBe(0);
}, S1B);

test("a hand-appended critical row whose opens, or an override whose round_opened, is not what the verb would write is listed invalid and counts for nothing", async () => {
  const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
  const d = decide(t.specs, 901, `${CAP_KEY} operator: ${SPEND}\n`);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`);
  const add = (row: object) => appendFileSync(ledger, `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, ...row })}\n`);
  add({ row: "critical", epoch: 0, opens: 11, id: "C1", class: "spend-grant", decision: "901", quote: SPEND, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")), return_sha: "f".repeat(64) });
  add({ row: "override", epoch: 0, round_opened: 11, findings: [{ id: "C2", severity: "major", critic: "spec", return_sha: "f".repeat(64) }], why: "x", chief: "chief-x" });
  const s = await status(t.specs);
  expect(s.invalid).toEqual(["critical 901", "override"]);
  expect(s.critical_open).toMatchObject([{ id: "C1" }]);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toContain(T5(7));
}, S1B);

test("closure-pack refuses when diff itself fails, rather than reporting the file unchanged", async () => {
  if (process.getuid?.() === 0) return;
  const t = await roundTree(MAJOR, []);
  chmodSync(t.a, 0o000);
  try {
    const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
    expect(pack.code).not.toBe(0); expect(pack.err).toContain("diff of");
  } finally { chmodSync(t.a, 0o644); }
}, S1B);

test("a finding id raised again in a later round is a second open finding: ruling on the first leaves the second open and the signature refused", async () => {
  const again = "- **o1** (minor; operator-critical: spend-grant) the same id in a later round";
  const t = await roundTree([again], [], false, [again]);
  const s3 = `${t.a}.critic-spec-r5.md`;
  const open = async () => (await status(t.specs)).critical_open;
  expect((await open()).map((o: { round: number }) => o.round)).toEqual([4, 5]);
  decide(t.specs, 905, `${CAP_KEY} operator: ${SPEND}\n`); decide(t.specs, 906, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "o1", 905, SPEND, "--no-round")).err).toBe("");
  expect((await open()).map((o: { round: number }) => o.round)).toEqual([5]);
  const sign = await routeCli("ledger-verify", s3, "--spec", t.a, "--sign");
  expect(sign.err).toContain("has open operator-critical findings: o1 (spend-grant)"); expect(sign.code).not.toBe(0);
  expect((await critical(true, t.specs, "o1", 906, SPEND, "--no-round")).err).toBe("");
  expect(await open()).toEqual([]);
  expect((await routeCli("ledger-verify", s3, "--spec", t.a, "--sign")).code).toBe(0);
}, S1B);

test("a changed line that starts with dashes still counts as changed: a regression quoting a dropped markdown rule line is blocking", async () => {
  const rule = "--- a markdown rule line";
  const t = await roundTree(MAJOR, [], false, [], `# A\n\n${rule}\n`);
  writeFileSync(t.a, front(CAP_KEY, "# A\n\nthe rule line was dropped here\n"));
  const res = await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", `- **R1** (major; regression) the rule is gone: \`${rule}\``);
  expect(res.err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1).findings).toMatchObject([{ id: "R1", class: "regression" }]);
}, S1B);

test("round-reset: one reset per ticket, from the console, on a decision naming it; the next round of the new epoch is round 1", async () => {
  const t = await roundTree(MAJOR, []);
  decide(t.specs, 906, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  const reset = (console: boolean) => verb(console, "round-reset", CAP_KEY, "--decision", "906", "--quote", "start this ticket over from scratch", "--specs", t.specs);
  expect((await reset(false)).code).not.toBe(0); expect(rowsOf(t.specs, "reset")).toEqual([]);
  expect((await reset(true)).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ spec: 0, plan: 0, next: "full" });
  const again = `${t.a}.critic-spec-r9.md`;
  writeFileSync(again, readFileSync(`${t.a}.critic-spec-r1.md`, "utf8").split("\n").filter((l) => !l.startsWith("CONTENT-SHA256 ")).join("\n"));
  expect((await seal(again, t.a, sha(front(CAP_KEY, "# A\n")))).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", round: 1, epoch: 1, mode: "full" });
  const second = await reset(true);
  expect(second.err).toContain(`round-reset: ${CAP_KEY} already used its one reset`); expect(second.code).not.toBe(0);
}, S1B);

const BLK_A = ["- **A1** (major) the quota rule is stated twice", "  Second paragraph of the same finding, still A1.", "  - nested bullet one", "    - deeper bullet", "", "  - fix: replace the first rule with a pointer", "    and keep only the second rule"].join("\n");
const BLK_N = ["- **N1** (minor) a wording note between the two", "  - N1 sub bullet that must not reach the pack"].join("\n");
const BLK_B = ["- **B1** (major) the example contradicts rule one", "  - fix: delete the example"].join("\n");

test("closure-pack carries each open blocking finding's complete block, in order, through the next protocol finding or the return's READ line", async () => {
  const read = `READ-SHA256 ${sha(front(CAP_KEY, "# A\n"))} ${CAP_KEY}-a.md`;
  const t = await roundTree([BLK_A, BLK_N, `${BLK_B}\n${read}`], []);
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.err).toBe(""); expect(pack.code).toBe(0);
  const section = /## open blocking findings\n([\s\S]*?)\n\n## files round 5 read/.exec(pack.out)?.[1];
  expect(section).toBe(`${BLK_A}\n${BLK_B}`);
  for (const absent of ["N1", "CONTENT-SHA256", "READ-SHA256", "SPEC FINDINGS", "critic return"]) expect(section).not.toContain(absent);
  expect(pack.out.split("\n")[0]).toBe(markerFor(t.specs, CAP_KEY, "spec", 6));
  expect(pack.out).toContain(`## diff against the round 5 snapshots`);
}, S1B);

test("closure-pack fails closed when a blocking finding's sealed return is unreadable, was edited, or holds no block, and marks an unrated finding explicitly", async () => {
  const t = await roundTree([BLK_A], []);
  const r5 = `${t.a}.critic-spec-r5.md`; const good = readFileSync(r5, "utf8");
  const pack = () => verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect((await pack()).out).toContain(BLK_A);
  writeFileSync(r5, good.replace("nested bullet one", "nested bullet ONE"));
  const edited = await pack(); expect(edited.code).not.toBe(0); expect(edited.err).toContain("changed since it was sealed"); expect(edited.out).toBe("");
  rmSync(r5);
  const gone = await pack(); expect(gone.code).not.toBe(0); expect(gone.err).toContain("cannot read"); expect(gone.out).toBe("");
  writeFileSync(r5, good);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const rows = readFileSync(ledger, "utf8");
  writeFileSync(ledger, rows.replaceAll('"id":"A1"', '"id":"ZZ"'));
  const none = await pack(); expect(none.code).not.toBe(0); expect(none.err).toContain("ZZ has no finding block"); expect(none.out).toBe("");
  writeFileSync(ledger, rows);
  expect((await pack()).code).toBe(0);
  const u = await roundTree(["prose only, no finding line"], []);
  const unrated = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", u.specs);
  expect(unrated.err).toBe(""); expect(unrated.out).toContain("- **spec-r5-U1** (unrated) [no protocol finding block");
}, S1B);

const APPROVE = "approve one closure round for the two corrections";
const F3_R4 = ["- **F3** (major; reopens M2) the quota rule is stated twice", "  A second paragraph of F3.", "  - nested bullet", "    - deeper bullet", "", "  - fix: point the first rule at the second"].join("\n");
const F4_R4 = ["- **F4** (major; reopens M2) the example contradicts rule one", "  - fix: delete the example"].join("\n");
const F3_R5 = ["- **F3** (major; reopens F3) the pointer still repeats the quota", "  Still the same finding, second paragraph.", "  - nested fix bullet", "    - deeper fix bullet", "", "  - fix: drop the repeated sentence"].join("\n");
const F4_R5 = ["- **F4** (major; reopens F4) the example is gone but rule one lost its test", "  - fix: restore the rule one test"].join("\n");
const extTree = async (planFindings: string[] = []) => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], planFindings);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 3", F3_R4, BLK_N, F4_R4)).err).toBe("");
  const over = await verb(true, "round-override", CAP_KEY, "--findings", "F3,F4", "--why", "a second closure", "--chief", "chief-x", "--specs", t.specs);
  expect(over.err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 2", F3_R5, F4_R5)).err).toBe("");
  return t;
};
const extend = (console: boolean, t: { specs: string }, o: { findings?: string; decision?: number; quote?: string; why?: string; chief?: string } = {}) =>
  verb(console, "round-extension", CAP_KEY, "--findings", o.findings ?? "F3,F4", "--decision", String(o.decision ?? 986), "--quote", o.quote ?? APPROVE, "--why", o.why ?? "one closure for the two corrections", "--chief", o.chief ?? "chief-x", "--specs", t.specs);
const T5_WHY = (r: number) => `spec round ${r}: ${T5(r)}`;

test("round-extension: its approval cannot be replayed as a reset, including copied bytes and reader rows", async () => {
  const t = await extTree();
  const text = `${CAP_KEY} operator: ${APPROVE}\n`;
  const path = decide(t.specs, 986, text); decide(t.specs, 988, text);
  expect((await extend(true, t)).code).toBe(0);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const before = readFileSync(ledger, "utf8");
  for (const decision of [986, 988]) {
    const result = await verb(true, "round-reset", CAP_KEY, "--decision", String(decision), "--quote", APPROVE, "--specs", t.specs);
    expect(result.code).not.toBe(0); expect(result.err).toContain("round-extension");
    expect(readFileSync(ledger, "utf8")).toBe(before);
  }
  appendFileSync(ledger, `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "reset", epoch: 1, decision: "986", quote: APPROVE, decision_path: path, decision_sha: sha(text) })}\n`);
  expect(await status(t.specs)).toMatchObject({ epoch: 0, invalid: ["reset 986"] });
  writeFileSync(ledger, before);
  decide(t.specs, 992, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  expect((await verb(true, "round-reset", CAP_KEY, "--decision", "992", "--quote", "start this ticket over from scratch", "--specs", t.specs)).code).toBe(0);
}, S1B);

test("round-extension: its approval cannot be replayed as a critical ruling, including copied bytes and reader rows", async () => {
  const t = await extTree(["- **o1** (minor; operator-critical: spend-grant) the operator decides the spend"]);
  const text = `${CAP_KEY} operator: ${APPROVE}\n`;
  const path = decide(t.specs, 986, text); decide(t.specs, 988, text);
  expect((await extend(true, t)).code).toBe(0);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const before = readFileSync(ledger, "utf8");
  for (const decision of [986, 988]) {
    const result = await critical(true, t.specs, "o1", decision, APPROVE, "--no-round");
    expect(result.code).not.toBe(0); expect(result.err).toContain("round-extension");
    expect(readFileSync(ledger, "utf8")).toBe(before);
  }
  const plan = rowsOf(t.specs, "round").find(r => r.critic === "plan" && r.round === 5);
  appendFileSync(ledger, `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", epoch: 0, opens: 0, id: "o1", class: "spend-grant", decision: "986", quote: APPROVE, decision_path: path, decision_sha: sha(text), return_sha: plan.return_sha })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["critical 986"]);
  writeFileSync(ledger, before);
  decide(t.specs, 992, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "o1", 992, SPEND, "--no-round")).code).toBe(0);
}, S1B);

test("closure-pack: READ prose is retained, and unheaded return notes stay contextual until actual metadata", async () => {
  const body = `${BLK_A}\nREAD the input once before choosing the fix.\n\n## Notes (not counted)\nThis is contextual return text, not another finding.`;
  const t = await roundTree([body], []);
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.code).toBe(0); expect(pack.out).toContain(body);
  expect(pack.out).not.toContain("CONTENT-SHA256");
}, S1B);

test("round-extension: refuses a worker, a missing flag, a wrong finding set, a decision that does not hold, and a round that needs none; the default cap still refuses writer round 8", async () => {
  const t = await extTree();
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toContain(T5(8));
  expect((await status(t.specs)).why).toContain(T5_WHY(8));
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`); decide(t.specs, 987, `no ticket named here: ${APPROVE}\n`);
  const refused = async (r: Promise<{ code: number; err: string }>, text: string) => { const x = await r; expect(x.err).toContain(text); expect(x.code).not.toBe(0); expect(rowsOf(t.specs, "extension")).toEqual([]); };
  await refused(extend(false, t), "round-extension: needs HIMMEL_CONSOLE=1");
  await refused(extend(true, t, { findings: "F3" }), "name every open blocking finding");
  await refused(extend(true, t, { findings: "F3,F4,F9" }), "F9 is not an open blocking finding");
  await refused(extend(true, t, { findings: "M2" }), "M2 is not an open blocking finding");
  await refused(extend(true, t, { decision: 987 }), `decision 987 does not name ${CAP_KEY}`);
  await refused(extend(true, t, { decision: 986, quote: "a quote the decision never holds at all" }), "does not hold the quote");
  await refused(extend(true, t, { decision: 55 }), "0 files match");
  await refused(verb(true, "round-extension", CAP_KEY, "--findings", "F3,F4", "--decision", "986", "--quote", APPROVE, "--chief", "chief-x", "--specs", t.specs), "--why is required");
  await refused(extend(true, t, { why: "  " }), "are all required");
  const reused = decide(t.specs, 990, `${CAP_KEY} operator: ${APPROVE}\n`);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", epoch: 0, opens: 0, id: "F3", class: "spend-grant", decision: "990", quote: APPROVE, decision_path: reused, decision_sha: sha(readFileSync(reused, "utf8")), return_sha: "f".repeat(64) })}\n`);
  await refused(extend(true, t, { decision: 990 }), "was already used");
  expect((await status(t.specs)).why).toContain(T5_WHY(8));
  const early = await roundTree(["- **M1** (major) still open"], []);
  decide(early.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const x = await extend(true, early); expect(x.err).toContain("is at writer round 5"); expect(x.code).not.toBe(0);
  const m1 = rowsOf(early.specs, "round").find((r) => r.critic === "spec" && r.round === 5); const p3 = rowsOf(early.specs, "round").find((r) => r.critic === "plan" && r.round === 5);
  const ed = join(early.specs, "decisions", "verbatim-decision-986-operator.txt");
  appendFileSync(join(roundsDir(early.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "extension", epoch: 0, round_opened: 7, findings: [{ id: "M1", severity: "major", critic: "spec", return_sha: m1.return_sha }], returns: { spec: [m1.return_sha], plan: [p3.return_sha] }, why: "w", chief: "c", decision: "986", quote: APPROVE, decision_path: ed, decision_sha: sha(readFileSync(ed, "utf8")) })}\n`);
  expect((await status(early.specs)).invalid).toEqual(["extension 986"]);
}, S1B);

test("round-extension: one chief record bound to the sealed returns and the open blocking findings opens exactly writer round 8; the real pack carries complete blocks and the sealed round consumes the grant", async () => {
  const t = await extTree(); const d = decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const ok = await extend(true, t); expect(ok.err).toBe(""); expect(ok.code).toBe(0); expect(ok.out).toContain("writer round 8");
  const r7 = rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 7); const p3 = rowsOf(t.specs, "round").find((x) => x.critic === "plan" && x.round === 5);
  const ext = rowsOf(t.specs, "extension");
  expect(ext).toHaveLength(1);
  expect(ext[0]).toMatchObject({ key: CAP_KEY, epoch: 0, round_opened: 8, why: "one closure for the two corrections", chief: "chief-x", decision: "986", quote: APPROVE, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")),
    findings: [{ id: "F3", severity: "major", critic: "spec", return_sha: r7.return_sha }, { id: "F4", severity: "major", critic: "spec", return_sha: r7.return_sha }], returns: { spec: [r7.return_sha], plan: [p3.return_sha] } });
  expect(await status(t.specs)).toMatchObject({ invalid: [], overrideUsed: true });
  expect((await status(t.specs)).why).toContain("spec round 8: closure");
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.err).toBe(""); expect(pack.out.split("\n")[0]).toBe(markerFor(t.specs, CAP_KEY, "spec", 8));
  expect(pack.out).toContain(`## open blocking findings\n${F3_R5}\n${F4_R5}\n\n## files round 7 read`);
  const dup = await extend(true, t, { decision: 986 }); expect(dup.code).not.toBe(0); expect(dup.err).toContain("already open"); expect(rowsOf(t.specs, "extension")).toHaveLength(1);
  const F5 = "- **F5** (major; reopens F3) still open after the one granted round";
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC FINDINGS 1", F5)).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "spec", round: 8, mode: "closure" });
  expect(await status(t.specs)).toMatchObject({ spec: 8, invalid: [] });
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
  expect((await status(t.specs)).why).toContain(T5_WHY(9));
  const again = await extend(true, t, { findings: "F5" }); expect(again.err).toContain("was already used"); expect(again.code).not.toBe(0);
  const copy = decide(t.specs, 988, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect(readFileSync(copy, "utf8")).toBe(readFileSync(d, "utf8"));
  const copied = await extend(true, t, { findings: "F5", decision: 988 }); expect(copied.err).toContain("already used"); expect(copied.code).not.toBe(0);
  expect(rowsOf(t.specs, "extension")).toHaveLength(1);
  decide(t.specs, 989, `${CAP_KEY} operator: approve a second closure round after a fresh look\n`);
  const fresh = await extend(true, t, { findings: "F5", decision: 989, quote: "approve a second closure round after a fresh look" });
  expect(fresh.err).toBe(""); expect(fresh.code).toBe(0);
  expect(rowsOf(t.specs, "extension").map((x) => x.round_opened)).toEqual([8, 9]);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const all = readFileSync(ledger, "utf8"); const kept = all.split("\n").filter(Boolean);
  writeFileSync(ledger, `${kept.slice(0, -1).join("\n")}\n`);
  appendFileSync(ledger, `${JSON.stringify({ ...JSON.parse(kept.at(-1)!), decision: "988", quote: APPROVE, decision_path: copy, decision_sha: sha(readFileSync(copy, "utf8")) })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 988"]);
  writeFileSync(ledger, all);
  expect((await status(t.specs)).invalid).toEqual([]);
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toBe("");
  expect((await closeOn(t, "spec", 10, [t.a], "SPEC CLEAN")).err).toContain(T5(10));
  expect(await status(t.specs)).toMatchObject({ spec: 9, invalid: [] });
}, S1B);

test("round-extension: the grant opens round 8 only for the kind that carries the named findings, not for a clean plan at the same round", async () => {
  const t = await extTree();
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 985, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toContain(T5(7));
  expect((await closureVerb(t.specs, 985, "--round", "plan:7")).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toContain(T5(8));
  expect((await status(t.specs)).why).toContain("spec round 8: closure; plan round 8: " + T5(8));
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
}, S1B);

test("round-extension: the reader replays each record at its append point; a stale epoch, return, finding set, round, chief, decision or file digest leaves it invalid and writer round 8 refused", async () => {
  const t = await extTree(); const d = decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const base = readFileSync(ledger, "utf8");
  expect((await extend(true, t)).err).toBe("");
  const after = readFileSync(ledger, "utf8"); const real = JSON.parse(after.slice(base.length));
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  const bad = { ...real.findings[0], return_sha: "f".repeat(64) };
  const cases: Record<string, object> = {
    "epoch": { epoch: 1 }, "no epoch": { epoch: undefined }, "round": { round_opened: 9 }, "past round": { round_opened: 7 },
    "returns": { returns: { ...real.returns, spec: ["f".repeat(64)] } }, "plan return": { returns: { ...real.returns, plan: [] } }, "no returns": { returns: undefined },
    "subset": { findings: [real.findings[0]] }, "extra": { findings: [...real.findings, { ...real.findings[0], id: "F9" }] }, "wrong return": { findings: [bad, real.findings[1]] }, "none": { findings: [] },
    "chief": { chief: "" }, "no chief": { chief: undefined }, "why": { why: " " }, "quote": { quote: "a quote the decision never holds at all" },
    "digest": { decision_sha: "e".repeat(64) }, "path": { decision_path: `${d}.moved` }, "decision": { decision: "991" },
  };
  for (const [name, change] of Object.entries(cases)) {
    writeFileSync(ledger, base); appendFileSync(ledger, `${JSON.stringify({ ...real, ...change })}\n`);
    const s = await status(t.specs);
    expect({ name, invalid: s.invalid }).toEqual({ name, invalid: [`extension ${(change as { decision?: string }).decision ?? "986"}`] });
    expect(s.why).toContain(T5_WHY(8));
  }
  writeFileSync(ledger, after); appendFileSync(ledger, `${JSON.stringify(real)}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 986"]);
  expect((await status(t.specs)).why).toContain("spec round 8: closure");
  const second = decide(t.specs, 993, `${CAP_KEY} operator: approve yet another closure round for the same writer round\n`);
  writeFileSync(ledger, after); appendFileSync(ledger, `${JSON.stringify({ ...real, decision: "993", quote: "approve yet another closure round for the same writer round", decision_path: second, decision_sha: sha(readFileSync(second, "utf8")) })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 993"]);
  const burnt = decide(t.specs, 994, `${CAP_KEY} operator: ${APPROVE} (a third file)\n`);
  writeFileSync(ledger, base); appendFileSync(ledger, `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", decision: "994", opens: 0, id: "zz", class: "spend-grant", quote: "x", return_sha: "f".repeat(64) })}\n`);
  appendFileSync(ledger, `${JSON.stringify({ ...real, decision: "994", decision_path: burnt, decision_sha: sha(readFileSync(burnt, "utf8")) })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["critical 994", "extension 994"]);
  writeFileSync(ledger, base);
  expect((await extend(true, t)).err).toBe("");
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
}, S1B);

test("round-extension: editing the approval after the record kills the grant; a reset ends the epoch, so the old grant opens nothing and a hand-copied row is invalid", async () => {
  const t = await extTree(); const d = decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const grant = readFileSync(ledger, "utf8").split("\n").filter(Boolean).at(-1)!;
  const text = readFileSync(d, "utf8"); writeFileSync(d, `${text}and a sentence the operator never said\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 986"]);
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toContain(T5(8));
  writeFileSync(d, text);
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  decide(t.specs, 992, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  expect((await verb(true, "round-reset", CAP_KEY, "--decision", "992", "--quote", "start this ticket over from scratch", "--specs", t.specs)).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ epoch: 1, spec: 0, plan: 0, invalid: [] });
  appendFileSync(ledger, `${grant}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 986"]);
  const worker = await extend(true, t, { decision: 986 }); expect(worker.err).toContain("is at writer round 0"); expect(worker.code).not.toBe(0);
}, S1B);

// A kind that lags the writer round: the other kind went ahead on its own grant, so the lagging kind's next refused round is below writer + 1.
const LAG_APPROVE = "approve one plan closure round for the two regressions";
const LAG_OPEN = "open the lagging closure round five";
const REG = (id: string, line: string) => `- **${id}** (major; regression) the changed line breaks an earlier rule: \`${line}\``;
const lagTree = async (lag: "spec" | "plan" = "plan", aheadSix: string[] | null = null) => {
  const ahead = lag === "plan" ? "spec" : "plan"; const A = ahead.toUpperCase(); const L = lag.toUpperCase();
  const M2 = "- **M2** (major) the quota rule is stated twice";
  const t = await roundTree(ahead === "spec" ? [M2] : [], ahead === "plan" ? [M2] : []);
  const files = { spec: [t.a], plan: [t.plan] };
  expect((await closeOn(t, ahead, 6, files[ahead], `${A} FINDINGS 3`, F3_R4, BLK_N, F4_R4)).err).toBe("");
  expect((await verb(true, "round-override", CAP_KEY, "--findings", "F3,F4", "--why", "a second closure", "--chief", "chief-x", "--specs", t.specs)).err).toBe("");
  expect((await closeOn(t, ahead, 7, files[ahead], `${A} FINDINGS 2`, F3_R5, F4_R5)).err).toBe("");
  expect((await closeOn(t, lag, 6, files[lag], `${L} CLEAN`)).err).toBe("");
  decide(t.specs, 985, `${CAP_KEY} operator: ${LAG_OPEN}\n`);
  expect((await verb(true, "round-critical", CAP_KEY, "--decision", "985", "--quote", LAG_OPEN, "--closure", "--round", `${lag}:7`, "--specs", t.specs)).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  const one = `the first changed ${lag} line`; const two = `the second changed ${lag} line`;
  writeFileSync(files[lag][0], lag === "spec" ? front(CAP_KEY, `# A\n\n${one}\n${two}\n`) : `# A plan\n\n${one}\n${two}\n`);
  expect((await closeOn(t, lag, 7, files[lag], `${L} FINDINGS 2`, REG("R1", one), REG("R2", two))).err).toBe("");
  expect((await (aheadSix ? closeOn(t, ahead, 8, files[ahead], `${A} FINDINGS ${aheadSix.length}`, ...aheadSix) : closeOn(t, ahead, 8, files[ahead], `${A} CLEAN`))).err).toBe("");
  return t;
};
const lagExtend = (t: { specs: string }, o: { findings?: string; decision?: number; quote?: string } = {}) =>
  extend(true, t, { findings: "R1,R2", decision: 987, quote: LAG_APPROVE, why: "one closure for the two regressions", ...o });
const latestOf = (specs: string, critic: string, round: number) => rowsOf(specs, "round").find((x) => x.critic === critic && x.round === round);

test("round-extension: a kind that lags the writer round gets its own next refused round: Spec6 CLEAN / Plan5 R1,R2 opens Plan6 only, never Plan7 or Spec7", async () => {
  const t = await lagTree();
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 7, writer: 8, invalid: [] });
  expect((await status(t.specs)).why).toContain(`plan round 8: ${T5(8)}`);
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toContain(T5(8));
  expect(rowsOf(t.specs, "extension").map((x) => x.round_opened)).toEqual([8]);
  const d = decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  const ok = await lagExtend(t); expect(ok.err).toBe("");
  const ext = rowsOf(t.specs, "extension"); const p5 = latestOf(t.specs, "plan", 7); const s6 = latestOf(t.specs, "spec", 8);
  expect(ext.map((x) => x.round_opened)).toEqual([8, 8]);
  expect(ext[1]).toMatchObject({ epoch: 0, round_opened: 8, decision: "987", decision_path: d, decision_sha: sha(readFileSync(d, "utf8")),
    findings: [{ id: "R1", severity: "major", critic: "plan", return_sha: p5.return_sha }, { id: "R2", severity: "major", critic: "plan", return_sha: p5.return_sha }], returns: { spec: [s6.return_sha], plan: [p5.return_sha] } });
  expect(ok.out).toContain("plan round 8 opens as a closure check of R1, R2");
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 7, invalid: [] });
  expect((await status(t.specs)).why).toContain(`spec round 9: ${T5(9)}; plan round 8: closure`);
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
  const pack = await verb(false, "closure-pack", CAP_KEY, "plan", "--specs", t.specs);
  expect(pack.err).toBe(""); expect(pack.out.split("\n")[0]).toBe(markerFor(t.specs, CAP_KEY, "plan", 8));
  expect(pack.out).toContain("- **R1** (major; regression)"); expect(pack.out).toContain("- **R2** (major; regression)");
  const sealed = await closeOn(t, "plan", 8, [t.plan], "PLAN FINDINGS 1", "- **R3** (major; reopens R1) still broken after the one granted round");
  expect(sealed.err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", critic: "plan", round: 8, mode: "closure" });
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 8, invalid: [] });
  expect((await status(t.specs)).why).toContain(`spec round 9: ${T5(9)}; plan round 9: ${T5(9)}`);
  expect((await closeOn(t, "plan", 9, [t.plan], "PLAN CLEAN")).err).toContain(T5(9));
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
  const again = await lagExtend(t, { findings: "R3" }); expect(again.err).toContain("was already used"); expect(again.code).not.toBe(0);
  expect(rowsOf(t.specs, "extension")).toHaveLength(2);
}, S1B);

test("round-extension: the reverse kind lags the same way: Plan6 CLEAN / Spec5 R1,R2 opens Spec6 only", async () => {
  const t = await lagTree("spec");
  expect(await status(t.specs)).toMatchObject({ spec: 7, plan: 8, writer: 8, invalid: [] });
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  const ok = await lagExtend(t); expect(ok.err).toBe("");
  const ext = rowsOf(t.specs, "extension");
  expect(ext.map((x) => x.round_opened)).toEqual([8, 8]);
  expect(ext[1].findings.map((f: { critic: string }) => f.critic)).toEqual(["spec", "spec"]);
  expect(ok.out).toContain("spec round 8 opens as a closure check of R1, R2");
  expect((await status(t.specs)).why).toContain(`spec round 8: closure; plan round 9: ${T5(9)}`);
  expect((await closeOn(t, "plan", 9, [t.plan], "PLAN CLEAN")).err).toContain(T5(9));
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 8, invalid: [] });
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
}, S1B);

test("round-extension: aligned counters keep the old grant: one row at writer + 1 opens both kinds that carry open findings, with the unchanged output", async () => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], ["- **P2** (major) the plan repeats the quota rule"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 3", F3_R4, BLK_N, F4_R4)).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 1", "- **P3** (major; reopens P2) the plan still repeats it")).err).toBe("");
  expect((await verb(true, "round-override", CAP_KEY, "--findings", "F3,F4,P3", "--why", "a second closure", "--chief", "chief-x", "--specs", t.specs)).err).toBe("");
  expect(rowsOf(t.specs, "override")[0].findings.map((f: { critic: string }) => f.critic)).toEqual(["spec", "spec", "plan"]);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 2", F3_R5, F4_R5)).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN FINDINGS 1", "- **P4** (major; reopens P3) the plan repeats it once more")).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const ok = await extend(true, t, { findings: "F3,F4,P4" });
  expect(ok.err).toBe(""); expect(ok.out).toContain("writer round 8 opens as a closure check of F3, F4, P4 (decision 986)");
  expect(rowsOf(t.specs, "extension").map((x) => [x.round_opened, x.findings.map((f: { critic: string }) => f.critic)])).toEqual([[8, ["spec", "spec", "plan"]]]);
  expect((await status(t.specs)).why).toContain("spec round 8: closure; plan round 8: closure");
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toBe("");
  expect((await closeOn(t, "plan", 9, [t.plan], "PLAN CLEAN")).err).toContain(T5(9));
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 8, invalid: [] });
}, S1B);

test("round-extension: open findings in kinds whose next rounds differ fail closed with no row, while an old row at writer + 1 still replays", async () => {
  const t = await lagTree("plan", ["- **F5** (major; reopens F3) still open after the one granted round"]);
  expect(await status(t.specs)).toMatchObject({ spec: 8, plan: 7, invalid: [] });
  const d = decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const before = readFileSync(ledger, "utf8");
  const mixed = await lagExtend(t, { findings: "F5,R1,R2" });
  expect(mixed.code).not.toBe(0); expect(mixed.err).toContain("spec round 9, plan round 8"); expect(mixed.err).toContain("nothing was written");
  expect(readFileSync(ledger, "utf8")).toBe(before);
  const s6 = latestOf(t.specs, "spec", 8); const p5 = latestOf(t.specs, "plan", 7);
  const old = { v: 1, ts: Date.now(), key: CAP_KEY, row: "extension", epoch: 0, round_opened: 9, why: "w", chief: "c", decision: "987", quote: LAG_APPROVE, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")),
    findings: [{ id: "F5", severity: "major", critic: "spec", return_sha: s6.return_sha }, { id: "R1", severity: "major", critic: "plan", return_sha: p5.return_sha }, { id: "R2", severity: "major", critic: "plan", return_sha: p5.return_sha }],
    returns: { spec: [s6.return_sha], plan: [p5.return_sha] } };
  appendFileSync(ledger, `${JSON.stringify(old)}\n`);
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  expect((await status(t.specs)).why).toContain(`spec round 9: closure; plan round 8: ${T5(8)}`);
}, S1B);

test("round-extension: a lagging kind below the default cap needs no grant, and a request for it is refused rather than opening a later round", async () => {
  const t = await roundTree(["- **M1** (major) still open"], ["- **P1** (major) the plan is wrong"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC CLEAN")).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const x = await extend(true, t, { findings: "P1" });
  expect(x.code).not.toBe(0); expect(x.err).toContain("plan round 6 needs no extension"); expect(rowsOf(t.specs, "extension")).toEqual([]);
  expect((await status(t.specs)).why).toContain("plan round 6: closure");
  const d = join(t.specs, "decisions", "verbatim-decision-986-operator.txt"); const p3 = latestOf(t.specs, "plan", 5); const s4 = latestOf(t.specs, "spec", 6);
  appendFileSync(join(roundsDir(t.specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "extension", epoch: 0, round_opened: 8, findings: [{ id: "P1", severity: "major", critic: "plan", return_sha: p3.return_sha }], returns: { spec: [s4.return_sha], plan: [p3.return_sha] }, why: "w", chief: "c", decision: "986", quote: APPROVE, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")) })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 986"]);
}, S1B);

test("round-extension: the lagging grant refuses a worker, wrong scope, words, number, stale or reused decision, and writes nothing", async () => {
  const t = await lagTree();
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`); decide(t.specs, 988, `no ticket named here: ${LAG_APPROVE}\n`);
  const stale = decide(t.specs, 989, `${CAP_KEY} operator: ${LAG_APPROVE}\n`); const past = new Date(Date.now() - 600_000); utimesSync(stale, past, past);
  const copy = decide(t.specs, 990, `${CAP_KEY} operator: ${APPROVE}\n`);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const before = readFileSync(ledger, "utf8");
  const refused = async (r: Promise<{ code: number; err: string }>, text: string) => { const x = await r; expect(x.err).toContain(text); expect(x.code).not.toBe(0); expect(readFileSync(ledger, "utf8")).toBe(before); };
  await refused(verb(false, "round-extension", CAP_KEY, "--findings", "R1,R2", "--decision", "987", "--quote", LAG_APPROVE, "--why", "w", "--chief", "c", "--specs", t.specs), "round-extension: needs HIMMEL_CONSOLE=1");
  await refused(lagExtend(t, { findings: "R1" }), "name every open blocking finding of");
  await refused(lagExtend(t, { findings: "R1,R2,F3" }), "F3 is not an open blocking finding");
  await refused(lagExtend(t, { findings: "F3,F4" }), "F3 is not an open blocking finding");
  await refused(lagExtend(t, { decision: 988 }), `decision 988 does not name ${CAP_KEY}`);
  await refused(lagExtend(t, { quote: "a quote the decision never holds at all" }), "does not hold the quote");
  await refused(lagExtend(t, { decision: 55 }), "0 files match");
  await refused(lagExtend(t, { decision: 989 }), "is not newer than the latest round");
  await refused(lagExtend(t, { decision: 986, quote: APPROVE }), "was already used");
  await refused(lagExtend(t, { decision: 990, quote: APPROVE }), "repeats an approval file already used");
  expect(readFileSync(copy, "utf8")).toBe(readFileSync(join(t.specs, "decisions", "verbatim-decision-986-operator.txt"), "utf8"));
  expect((await status(t.specs)).why).toContain(`plan round 8: ${T5(8)}`);
}, S1B);

test("round-extension: concurrent and repeated lagging grants open Plan6 once; the loser sees it already open, and a second decision does not open Plan7", async () => {
  const t = await lagTree();
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`); decide(t.specs, 988, `${CAP_KEY} operator: ${LAG_APPROVE} (a second file)\n`);
  const raced = await Promise.all([lagExtend(t), lagExtend(t, { decision: 988 }), lagExtend(t)]);
  expect(raced.filter((x) => x.code === 0)).toHaveLength(1);
  for (const x of raced.filter((y) => y.code !== 0)) expect(x.err).toContain("already open");
  expect(rowsOf(t.specs, "extension").map((x) => x.round_opened)).toEqual([8, 8]);
  const later = await lagExtend(t, { decision: 988 }); expect(later.code).not.toBe(0); expect(later.err).toContain("already open");
  expect(rowsOf(t.specs, "extension")).toHaveLength(2);
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  expect((await closeOn(t, "spec", 9, [t.a], "SPEC CLEAN")).err).toContain(T5(9));
}, S1B);

test("round-extension: the reader replays a lagging grant at its append point: a stale epoch, return, finding set, kind, round, chief, decision or file digest is invalid and Plan6 stays refused; a second row for the same kind is invalid", async () => {
  const t = await lagTree(); const d = decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const base = readFileSync(ledger, "utf8");
  expect((await lagExtend(t)).err).toBe("");
  const after = readFileSync(ledger, "utf8"); const real = JSON.parse(after.slice(base.length));
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  const bad = { ...real.findings[0], return_sha: "f".repeat(64) };
  const cases: Record<string, object> = {
    "epoch": { epoch: 1 }, "no epoch": { epoch: undefined }, "round 7": { round_opened: 7 }, "round 6": { round_opened: 6 }, "round 10": { round_opened: 10 }, "round 8.5": { round_opened: 8.5 },
    "returns": { returns: { ...real.returns, plan: ["f".repeat(64)] } }, "spec return": { returns: { ...real.returns, spec: [] } }, "no returns": { returns: undefined },
    "subset": { findings: [real.findings[0]] }, "extra": { findings: [...real.findings, { ...real.findings[0], id: "F9" }] }, "wrong return": { findings: [bad, real.findings[1]] }, "none": { findings: [] },
    "wrong kind": { findings: real.findings.map((f: object) => ({ ...f, critic: "spec" })) },
    "chief": { chief: "" }, "why": { why: " " }, "quote": { quote: "a quote the decision never holds at all" },
    "digest": { decision_sha: "e".repeat(64) }, "path": { decision_path: `${d}.moved` }, "decision": { decision: "991" },
  };
  for (const [name, change] of Object.entries(cases)) {
    writeFileSync(ledger, base); appendFileSync(ledger, `${JSON.stringify({ ...real, ...change })}\n`);
    const s = await status(t.specs);
    expect({ name, invalid: s.invalid }).toEqual({ name, invalid: [`extension ${(change as { decision?: string }).decision ?? "987"}`] });
    expect(s.why).toContain(`plan round 8: ${T5(8)}`);
  }
  writeFileSync(ledger, base); appendFileSync(ledger, `${JSON.stringify({ ...real, round_opened: 9 })}\n`);
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  expect((await status(t.specs)).why).toContain(`plan round 8: ${T5(8)}`);
  const second = decide(t.specs, 993, `${CAP_KEY} operator: approve yet another closure round for the same lagging kind\n`);
  writeFileSync(ledger, after);
  appendFileSync(ledger, `${JSON.stringify({ ...real, decision: "993", quote: "approve yet another closure round for the same lagging kind", decision_path: second, decision_sha: sha(readFileSync(second, "utf8")) })}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 993"]);
  writeFileSync(ledger, after);
  expect((await status(t.specs)).invalid).toEqual([]);
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toBe("");
}, S1B);

test("round-extension: the lagging grant's approval is spent for reset and critical, editing it kills the grant, and a reset ends the epoch so the old grant opens nothing", async () => {
  const t = await lagTree(); const d = decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  expect((await lagExtend(t)).err).toBe("");
  const ledger = join(roundsDir(t.specs), `${CAP_KEY}.jsonl`); const before = readFileSync(ledger, "utf8"); const grant = before.split("\n").filter(Boolean).at(-1)!;
  const reset = await verb(true, "round-reset", CAP_KEY, "--decision", "987", "--quote", LAG_APPROVE, "--specs", t.specs);
  expect(reset.code).not.toBe(0); expect(reset.err).toContain("round-extension"); expect(readFileSync(ledger, "utf8")).toBe(before);
  const text = readFileSync(d, "utf8"); writeFileSync(d, `${text}and a sentence the operator never said\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 987"]);
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toContain(T5(8));
  writeFileSync(d, text);
  expect(await status(t.specs)).toMatchObject({ invalid: [] });
  decide(t.specs, 992, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  expect((await verb(true, "round-reset", CAP_KEY, "--decision", "992", "--quote", "start this ticket over from scratch", "--specs", t.specs)).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ epoch: 1, spec: 0, plan: 0, invalid: [] });
  appendFileSync(ledger, `${grant}\n`);
  expect((await status(t.specs)).invalid).toEqual(["extension 987"]);
}, S1B);

const HX = "HIMMEL-nextleg-2026-11-10YN-roadmap-chief";
const HY = "HIMMEL-nextleg-2026-11-10YO-roadmap-chief";
const HZ = "HIMMEL-nextleg-2026-11-10YP-roadmap-chief";
const handOver = (r: string, from: string, to: string) => writeFileSync(join(r, "consoles", `${from}.md.handover`), `${to}\n`);
const inboxText = (r: string, name: string) => readFileSync(join(r, "consoles", `${name}.md`), "utf8");

test("a line addressed by full name to a chief that handed over lands in its successor's inbox", async () => {
  const r = root(); heartbeat(r, HX); heartbeat(r, HY); handOver(r, HX, HY);
  const reply = await routeText(r, `/chief ${HX} the v1.1.3-only directive`);
  expect(inboxText(r, HY)).toContain("[telegram from=1 chat=1] the v1.1.3-only directive\n");
  expect(inboxText(r, HX)).toBe("");
  expect(reply).toContain(HY);
});

test("the alias and the single-live-chief path follow the hand-over marker too", async () => {
  for (const [text, line] of [["/chief chief:himmel by alias", "by alias"], ["/chief by the only live chief", "by the only live chief"]]) {
    const r = root(); heartbeat(r, HX); armInbox(r, HY); handOver(r, HX, HY);
    const reply = await routeText(r, text);
    expect(inboxText(r, HY)).toContain(`] ${line}\n`);
    expect(inboxText(r, HX)).toBe("");
    expect(reply).toContain(HY);
  }
});

test("a hand-over chain is followed to its end, and a loop stops and still delivers once", async () => {
  const r = root(); heartbeat(r, HX); armInbox(r, HY); armInbox(r, HZ); handOver(r, HX, HY); handOver(r, HY, HZ);
  await routeText(r, `/chief ${HX} chained`);
  expect(inboxText(r, HZ)).toContain("] chained\n");
  expect(inboxText(r, HX) + inboxText(r, HY)).toBe("");
  const c = root(); const a = heartbeat(c, HX); armInbox(c, HY); armInbox(c, HZ); handOver(c, HX, HY); handOver(c, HY, HZ);
  const t = Date.now() / 1000;
  utimesSync(a + ".handover", t - 60, t - 60);
  writeFileSync(a, "- 00:02 [telegram from=1 chat=1] raced the hand-over\n");
  await routeText(c, `/chief ${HX} after the chain`);
  expect(inboxText(c, HZ)).toMatch(/^- 00:02 \[telegram from=1 chat=1\] raced the hand-over\n- \d\d:\d\dZ \[telegram from=1 chat=1\] after the chain\n$/);
  const l = root(); heartbeat(l, HX); armInbox(l, HY); handOver(l, HX, HY); handOver(l, HY, HX);
  await routeText(l, `/chief ${HX} looped`);
  expect(inboxText(l, HY)).toContain("] looped\n");
  expect(inboxText(l, HX)).toBe("");
});

test("a marker naming no existing inbox, an empty or an unsafe name keeps the line in the old inbox", async () => {
  for (const marker of [`${HY}\n`, "", "\n", "../evil\n", "a/b\n"]) {
    const r = root(); heartbeat(r, HX); writeFileSync(join(r, "consoles", `${HX}.md.handover`), marker);
    await routeText(r, `/chief ${HX} never lost`);
    expect(inboxText(r, HX)).toContain("] never lost\n");
  }
});

test("a chief without a hand-over marker still receives its own line", async () => {
  const r = root(); heartbeat(r, HX); armInbox(r, HY);
  await routeText(r, `/chief ${HX} still mine`);
  expect(inboxText(r, HX)).toContain("] still mine\n");
  expect(inboxText(r, HY)).toBe("");
});

test("an unread line that reached the old inbox after the hand-over moves to the successor once", async () => {
  const r = root(); const x = heartbeat(r, HX); heartbeat(r, HY);
  const read = "- 23:46 [telegram from=1 chat=1] already read\n";
  const unread = "- 00:02 [telegram from=1 chat=1] listen very carefully\n- 00:03 [telegram from=1 chat=1] Posted\n";
  writeFileSync(x, read + unread + "- 00:04 [telegram from=1 chat=1] partial");
  writeFileSync(x + ".cursor", `${Buffer.byteLength(read)}\n`);
  handOver(r, HX, HY);
  const t = Date.now() / 1000;
  utimesSync(x + ".handover", t - 60, t - 60);
  utimesSync(x, t, t);
  await routeText(r, `/chief ${HY} next line`);
  const moved = inboxText(r, HY);
  expect(moved.startsWith(unread)).toBe(true);
  expect(moved.slice(unread.length)).toMatch(/^- \d\d:\d\dZ \[telegram from=1 chat=1\] next line\n$/);
  expect(readFileSync(x + ".cursor", "utf8").trim()).toBe(String(Buffer.byteLength(read + unread)));
  await routeText(r, `/chief ${HY} second pass`);
  expect(inboxText(r, HY).match(/listen very carefully/g)).toHaveLength(1);
  expect(inboxText(r, HY)).not.toContain("already read");
  expect(inboxText(r, HY)).not.toContain("partial");

  const early = root(); const b = heartbeat(early, HX); heartbeat(early, HY);
  writeFileSync(b, unread); handOver(early, HX, HY);
  utimesSync(b, t - 60, t - 60); utimesSync(b + ".handover", t, t);
  await routeText(early, `/chief ${HY} after`);
  expect(inboxText(early, HY)).not.toContain("listen very carefully");
});

test("an unread tail behind a hand-over marker older than the window stays put; the new line still reaches the successor", async () => {
  const r = root(); const x = heartbeat(r, HX); armInbox(r, HY); handOver(r, HX, HY);
  writeFileSync(x, "- 09:00 [telegram from=1 chat=1] yesterday's line\n");
  const t = Date.now() / 1000;
  utimesSync(x + ".handover", t - 61 * 60, t - 61 * 60);
  utimesSync(x, t, t);
  await routeText(r, `/chief ${HX} today`);
  expect(inboxText(r, HY)).toMatch(/^- \d\d:\d\dZ \[telegram from=1 chat=1\] today\n$/);
  expect(existsSync(x + ".cursor")).toBe(false);
});

test("a config-audit broadcast in an old inbox is never moved, only the operator's lines are", async () => {
  const r = root(); const x = heartbeat(r, HX); const y = armInbox(r, HY); const z = armInbox(r, HZ); handOver(r, HX, HY); handOver(r, HY, HZ);
  const broadcast = "[config-audit] settings.json lost keys\n";
  writeFileSync(x, broadcast + "- 00:02 [telegram from=1 chat=1] raced\n");
  writeFileSync(y, broadcast);
  writeFileSync(z, broadcast);
  const t = Date.now() / 1000;
  for (const f of [x, y]) { utimesSync(f + ".handover", t - 60, t - 60); utimesSync(f, t, t); }
  await routeText(r, `/chief ${HX} after`);
  expect(inboxText(r, HZ)).toMatch(/^\[config-audit\] settings\.json lost keys\n- 00:02 \[telegram from=1 chat=1\] raced\n- \d\d:\d\dZ \[telegram from=1 chat=1\] after\n$/);
});

const US_KEY = "HIMMEL-9731"; const US_OTHER = "HIMMEL-9732";
const unsealedLines = (out: string) => out.split("\n").filter((l) => l.startsWith("unsealed: "));
const sealCmd = "bash scripts/handover/chief-kit/critic-seal.sh";

test("U1: a key with three critic files and no seal rows is flagged with all three files, in every name shape, and the exit code stays 0", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0); const a = join(t.dir, `${US_KEY}-a.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  const files = [`${a}.critic-spec-r1.md`, `${a}.critic-plan-r1.md`, `${a}.critic-r2-spec.md`];
  for (const f of files) writeFileSync(f, ret("SPEC FINDINGS 1", "- **f1** (major) a gap"));
  const s = await routeCli("round-status", US_KEY, "--specs", t.specs);
  expect(s.code).toBe(0);
  const lines = unsealedLines(s.out);
  expect(lines).toHaveLength(3);
  for (const f of files) expect(lines.some((l) => l.includes(f) && l.includes(sealCmd))).toBe(true);
  expect(s.out.split("\n")[0]).toContain(`${US_KEY} spec=0 plan=0`);
  const j = JSON.parse((await routeCli("round-status", US_KEY, "--specs", t.specs, "--json")).out);
  expect(j.unsealed.map((u: { file: string }) => u.file).sort()).toEqual([...files].sort());
}, S1B);

test("U2: a sealed round is not flagged", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${US_KEY}-a.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  expect((await sealOn(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN")).err).toBe("");
  const s = await routeCli("round-status", US_KEY, "--specs", t.specs);
  expect(s.code).toBe(0);
  expect(s.out).toContain(`${US_KEY} spec=1`);
  expect(unsealedLines(s.out)).toEqual([]);
  expect(JSON.parse((await routeCli("round-status", US_KEY, "--specs", t.specs, "--json")).out).unsealed).toEqual([]);
}, S1B);

test("U3: a mixed set flags only the unsealed round", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${US_KEY}-a.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  expect((await sealOn(`${a}.critic-spec-r1.md`, [a], "SPEC CLEAN")).err).toBe("");
  const loose = `${a}.critic-spec-r2.md`; writeFileSync(loose, ret("SPEC CLEAN"));
  const s = await routeCli("round-status", US_KEY, "--specs", t.specs);
  const lines = unsealedLines(s.out);
  expect(lines).toHaveLength(1);
  expect(lines[0]).toContain(loose);
  expect(lines[0]).not.toContain("critic-spec-r1.md");
}, S1B);

test("U4: a verdict file for another key is not flagged", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${US_KEY}-a.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  const o = join(t.dir, `${US_OTHER}-o.md`); writeFileSync(o, front(US_OTHER, "# O\n"));
  writeFileSync(`${o}.critic-spec-r1.md`, ret("SPEC CLEAN"));
  writeFileSync(`${a}.critic-spec-r1.md`, ret("SPEC CLEAN"));
  const s = await routeCli("round-status", US_KEY, "--specs", t.specs);
  const lines = unsealedLines(s.out);
  expect(lines).toHaveLength(1);
  expect(lines[0]).toContain(`${US_KEY}-a.md.critic-spec-r1.md`);
  expect(s.out).not.toContain(US_OTHER);
}, S1B);

test("U5: the seal command single-quotes a verdict path that holds a space or a quote", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${US_KEY}-a b's.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  const f = `${a}.critic-spec-r1.md`; writeFileSync(f, ret("SPEC CLEAN"));
  const lines = unsealedLines((await routeCli("round-status", US_KEY, "--specs", t.specs)).out);
  expect(lines).toHaveLength(1);
  expect(lines[0]).toContain(`${sealCmd} '${f.replace(/'/g, "'\\''")}' <file the critic read>`);
}, S1B);

const resetOn = async (t: { specs: string }, d: number) => {
  decide(t.specs, d, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  return verb(true, "round-reset", CAP_KEY, "--decision", String(d), "--quote", "start this ticket over from scratch", "--specs", t.specs);
};

test("U6: after a round-reset the old seed no longer accounts for a round file, and a round of the new epoch does", async () => {
  const t = await seededTree([]);
  expect(unsealedLines((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out)).toEqual([]);
  expect((await resetOn(t, 907)).err).toBe("");
  expect(unsealedLines((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out)).toHaveLength(10);
  const fresh = `${t.a}.critic-spec-r11.md`;
  expect((await sealOn(fresh, [t.a], "SPEC CLEAN")).err).toBe("");
  const lines = unsealedLines((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out);
  expect(lines).toHaveLength(10);
  expect(lines.some((l) => l.includes(fresh))).toBe(false);
}, S1B);

test("U7: after a round-reset a path named only by a row of the old epoch is flagged again", async () => {
  const t = await roundTree([], []);
  expect(unsealedLines((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out)).toEqual([]);
  expect((await resetOn(t, 908)).err).toBe("");
  expect(unsealedLines((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out)).toHaveLength(10);
}, S1B);

test("U8: a folder that cannot be read is reported on its own line and leaves the exit code and the other files alone", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${US_KEY}-a.md`); writeFileSync(a, front(US_KEY, "# A\n"));
  const f = `${a}.critic-spec-r1.md`; writeFileSync(f, ret("SPEC CLEAN"));
  const loop = join(t.specs, "plan"); symlinkSync("plan", loop);
  const s = await routeCli("round-status", US_KEY, "--specs", t.specs);
  expect(s.code).toBe(0);
  expect(unsealedLines(s.out)).toHaveLength(1);
  expect(s.out.split("\n").filter((l) => l.startsWith("unsealed-unread: ")).some((l) => l.includes(loop))).toBe(true);
  const j = JSON.parse((await routeCli("round-status", US_KEY, "--specs", t.specs, "--json")).out);
  expect(j.unsealed).toHaveLength(1);
  expect(j.unread).toHaveLength(1);
}, S1B);


test("shared pinnedSha legacy shape and same-fd mtime", async () => {
  const shared = await import("../jira/src/release/pinned.ts");
  const file = join(root(), "read.txt"); writeFileSync(file, "hello");
  utimesSync(file, 1234, 1234);
  expect(shared.pinnedSha(file)).toEqual({ bytes: Buffer.from("hello"), sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" });
  expect(shared.pinnedSha(file + ".missing")).toEqual({ missing: true });
  expect(shared.pinnedSha(dirname(file))).toEqual({ unreadable: true });
  expect(typeof shared.pinnedRead).toBe("function");
  const pinned = shared.pinnedRead(file);
  expect(pinned).toMatchObject({ mtime_ms: 1234000, bytes: Buffer.from("hello") });
  const fs = await import("node:fs");
  const original = fs.readSync; let rebound = false;
  const spy = spyOn(fs, "readSync").mockImplementation((...args: any[]) => {
    if (!rebound) { rebound = true; renameSync(file, file + ".old"); writeFileSync(file, "replacement"); }
    return (original as any)(...args);
  });
  try { expect(shared.pinnedRead(file + ".old")).toEqual({ missing: true });
    expect(shared.pinnedRead(file)).toMatchObject({ mtime_ms: 1234000, bytes: Buffer.from("hello") });
  } finally { spy.mockRestore(); }
});

test("shared bounded decision selector limits enumeration and ignores md", async () => {
  const shared = await import("../jira/src/release/pinned.ts");
  expect(typeof shared.boundedDirectoryNames).toBe("function");
  expect(typeof shared.selectDecisionNames).toBe("function");
  const dir = root();
  for (const n of ["verbatim-decision-12-z.txt", "verbatim-decision-12-a.md", "verbatim-decision-123-a.txt", "verbatim-decision-12-a.txt"]) writeFileSync(join(dir, n), "x");
  expect(shared.selectDecisionNames(shared.boundedDirectoryNames(dir), "12")).toEqual(["verbatim-decision-12-a.txt", "verbatim-decision-12-z.txt"]);
  expect(shared.boundedDirectoryNames(dir + ".missing")).toEqual([]);
  for (let i = 4; i <= 4096; i++) writeFileSync(join(dir, `entry-${i}`), "x");
  expect(() => shared.boundedDirectoryNames(dir)).toThrow("directory entry limit");
  expect(() => shared.selectDecisionNames([], "12x")).toThrow("'12x' is not a decision number");
});

test("shared quoteRule selector preserves legacy refusals", async () => {
  const t = await roundTree(["- **C1** (minor; operator-critical: spend-grant) a spend"], []);
  const check = async (decision: string, quote = SPEND) => {
    const res = await verb(true, "round-critical", CAP_KEY, "--finding", "C1", "--decision", decision, "--quote", quote, "--no-round", "--specs", t.specs);
    if (res.code !== 0) throw new Error(res.err);
  };
  await expect(check("bad")).rejects.toThrow("'bad' is not a decision number");
  mkdirSync(join(t.specs, "decisions"), { recursive: true });
  writeFileSync(join(t.specs, "decisions", "verbatim-decision-901-ignored.md"), `${CAP_KEY} ${SPEND}`);
  await expect(check("901")).rejects.toThrow("0 files match specs/decisions/verbatim-decision-901-*.txt, expected exactly one");
  const file = decide(t.specs, 901, `${CAP_KEY} ${SPEND}`);
  const second = join(t.specs, "decisions", "verbatim-decision-901-second.txt"); writeFileSync(second, "x");
  await expect(check("901")).rejects.toThrow("2 files match specs/decisions/verbatim-decision-901-*.txt, expected exactly one");
  unlinkSync(second);
  writeFileSync(file, SPEND);
  await expect(check("901")).rejects.toThrow(`decision 901 does not name ${CAP_KEY}`);
  writeFileSync(file, `${CAP_KEY} ${SPEND}`);
  await expect(check("901", "short")).rejects.toThrow("does not hold the quote");
  utimesSync(file, 1, 1);
  await expect(check("901")).rejects.toThrow(`decision 901 is not newer than the latest round of ${CAP_KEY}`);
  decide(t.specs, 901, `${CAP_KEY} ${SPEND}`);
  await check("901");
  await expect(check("901")).rejects.toThrow(`decision 901 was already used for ${CAP_KEY}`);
});

const fixtureSpecText = "---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n";
const fixturePlanText = "# HIMMEL-10205 plan\n\n- Task 1: build the fixture.\n";
const fixtureRequest = (scratchRoot: string) => ({
  scratchRoot, key: "HIMMEL-10205", specText: fixtureSpecText, planText: fixturePlanText,
  returns: [1, 2, 3, 4, 5].flatMap(round => (["spec", "plan"] as const).map(kind => ({
    kind, round, text: `- **F1** (${kind === "spec" ? "minor" : "medium"}) residual from ${kind} round ${round}\n${kind.toUpperCase()} FINDINGS 1\n`,
    reads: ["spec", "plan", { path: "specs/designs/estimate.json", text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' }],
  }))),
});

test("shared real round fixture seeds before returns and creates accepted seals and snapshots", async () => {
  const helper = await import("./testlib-capped-fold.ts").catch(() => null);
  expect(typeof helper?.buildRoundFixture).toBe("function");
  const scratch = root(); const f = await helper!.buildRoundFixture(fixtureRequest(scratch));
  for (const p of [f.specsRoot, f.spec, f.plan, f.ledgerPath, ...f.verdicts]) expect(p.startsWith(scratch + "/")).toBe(true);
  const { ledgerVerify, roundState } = await import("./chief-route");
  expect(await roundState(f.specsRoot, "HIMMEL-10205")).toMatchObject({ epoch: 0, spec: 5, plan: 5, next: "none", invalid: [] });
  for (const kind of ["spec", "plan"]) {
    const verdict = f.verdicts.find(p => p.endsWith(`critic-${kind}-r5.md`))!;
    expect(await ledgerVerify(verdict, { spec: f.spec })).toEqual({ key: "HIMMEL-10205", kind, round: 5, mode: "full" });
    const text = readFileSync(verdict, "utf8");
    expect(text).toContain(`Reviewed: spec ${sha(fixtureSpecText)}`);
    expect(text.match(/^CONTENT-SHA256 /gm)).toHaveLength(3);
  }
  const ledger = readFileSync(f.ledgerPath, "utf8").trim().split("\n").map(l => JSON.parse(l));
  expect(ledger.filter(r => r.row === "round")).toHaveLength(10);
  expect(ledger.filter(r => r.row === "seal")).toHaveLength(20);
  expect(ledger.some(r => r.row === "seed")).toBe(false);
  for (const row of ledger) expect(sha(readFileSync(join(dirname(f.ledgerPath), "HIMMEL-10205", row.read_sha), "utf8"))).toBe(row.read_sha);
  expect(JSON.parse(readFileSync(join(dirname(f.ledgerPath), "manifest.json"), "utf8")).keys).toEqual({});
  await expect(helper!.buildRoundFixture(fixtureRequest(scratch))).rejects.toThrow("already holds");
  for (const bad of ["relative", join(scratch, "missing")]) await expect(helper!.buildRoundFixture(fixtureRequest(bad))).rejects.toThrow("scratch root");
});

test("shared capped proof validator rejects finite schema mutations and preserves scoped identities", async () => {
  const shared = await import("../jira/src/release/pinned.ts");
  expect(typeof shared.validateCappedFoldProofShape).toBe("function");
  const { buildRoundFixture } = await import("./testlib-capped-fold.ts");
  const f = await buildRoundFixture(fixtureRequest(root()));
  const { returnSha } = await import("./chief-route");
  const filePin = (path: string) => ({ path, sha256: sha(readFileSync(path, "utf8")) });
  const returns = (["spec", "plan"] as const).map(kind => {
    const path = f.verdicts.find(p => p.endsWith(`critic-${kind}-r3.md`))!;
    return { ...filePin(path), kind, round: 3, return_sha: returnSha(readFileSync(path, "utf8")), residuals: 1 };
  });
  const decision = join(f.specsRoot, "decisions", "verbatim-decision-901-fixture.txt");
  mkdirSync(dirname(decision)); writeFileSync(decision, "fixture decision");
  const good = {
    schema: 1, reader_version: 1, mode: "capped-carry", key: "HIMMEL-10205", epoch: 0,
    spec: filePin(f.spec), plan: filePin(f.plan), returns,
    pins: [
      { ...filePin(f.ledgerPath), role: "ledger" },
      { ...filePin(join(dirname(f.ledgerPath), "manifest.json")), role: "manifest" },
      ...returns.map(r => ({ path: r.path, sha256: r.sha256, role: "return" })),
      ...[f.spec, f.plan].map(path => ({ ...filePin(path), role: "artifact" })),
      { ...filePin(join(dirname(f.ledgerPath), "HIMMEL-10205", sha(fixtureSpecText))), role: "snapshot" },
      { ...filePin(decision), role: "decision", mtime_ms: statSync(decision).mtimeMs },
      { role: "decision-selection", directory: dirname(decision), decision: "901", names: [basename(decision)] },
    ],
    carried: returns.map(r => ({ key: "HIMMEL-10205", epoch: 0, kind: r.kind, round: r.round, return_path: r.path, return_sha: r.return_sha, finding_id: "F1", severity: r.kind === "spec" ? "minor" : "medium", status: "open-carried" })),
  };
  expect(shared.validateCappedFoldProofShape(good)).toEqual(good);
  const separateDecision = structuredClone(good);
  const separateName = "verbatim-decision-902-fixture.txt";
  separateDecision.pins.push({ ...separateDecision.pins[7], path: join(dirname(decision), separateName) });
  separateDecision.pins.push({ ...separateDecision.pins[8], decision: "902", names: [separateName] });
  expect(shared.validateCappedFoldProofShape(separateDecision)).toEqual(separateDecision);
  const reject = (mutate: (p: any) => void) => {
    const bad = structuredClone(good); mutate(bad);
    expect(() => shared.validateCappedFoldProofShape(bad)).toThrow("invalid capped-fold proof");
  };
  for (const field of Object.keys(good)) reject(p => { delete p[field]; });
  for (const field of Object.keys(good.returns[0])) reject(p => { delete p.returns[0][field]; });
  for (const field of Object.keys(good.carried[0])) reject(p => { delete p.carried[0][field]; });
  for (const index of [0, 7, 8]) for (const field of Object.keys(good.pins[index])) reject(p => { delete p.pins[index][field]; });
  for (const mutate of [
    (p: any) => { p.extra = true; }, (p: any) => { p.spec.extra = true; },
    (p: any) => { p.schema = 2; }, (p: any) => { p.reader_version = 2; }, (p: any) => { p.mode = "clean"; },
    (p: any) => { p.returns.reverse(); }, (p: any) => { p.returns[0].kind = "plan"; },
    (p: any) => { p.returns[0].sha256 = "A".repeat(64); }, (p: any) => { p.returns[0].round = 0; },
    (p: any) => { p.returns[0].residuals = -1; }, (p: any) => { p.carried[0].round = 2; },
    (p: any) => { p.carried[0].key = "HIMMEL-1"; }, (p: any) => { p.carried[0].epoch = 1; },
    (p: any) => { p.carried[0].return_sha = "0".repeat(64); }, (p: any) => { p.carried[0].return_path = f.plan; },
    (p: any) => { p.carried[0].severity = "major"; }, (p: any) => { p.carried[0].status = "closed"; },
    (p: any) => { p.carried.push(p.carried[0]); }, (p: any) => { p.carried.pop(); },
    (p: any) => { p.pins[0].role = "unknown"; }, (p: any) => { p.pins[0].mtime_ms = 1; },
    (p: any) => { p.pins[7].mtime_ms = Infinity; }, (p: any) => { p.pins[8].decision = "901x"; },
    (p: any) => { p.pins[8].names = ["verbatim-decision-901-x.md"]; },
    (p: any) => { p.pins[8].names = ["verbatim-decision-901-z.txt", "verbatim-decision-901-a.txt"]; },
    (p: any) => { p.pins.pop(); }, (p: any) => { p.pins.splice(7, 1); },
    (p: any) => { p.pins.push(p.pins[8]); }, (p: any) => { p.pins.push(p.pins[0]); },
    (p: any) => {
      const name = "verbatim-decision-901-second.txt";
      p.pins.push({ ...p.pins[7], path: join(dirname(decision), name) });
      p.pins.push({ ...p.pins[8], names: [name] });
    },
    (p: any) => { p.pins[0].role = "artifact"; },
    (p: any) => { p.pins.push({ ...p.pins[0], role: "snapshot" }); },
    (p: any) => { p.returns[0].extra = true; }, (p: any) => { p.carried[0].extra = true; },
    (p: any) => { p.pins[0].extra = true; }, (p: any) => { p.pins[8].extra = true; },
  ]) reject(mutate);
  for (const epoch of [-1, 1.1, Infinity, NaN, Number.MAX_SAFE_INTEGER + 1]) reject(p => { p.epoch = epoch; });
  for (const path of ["relative", "/tmp/../tmp/file", "/tmp//file", "/tmp/file/", "/tmp/\0file"]) reject(p => { p.spec.path = path; });
  expect(shared.PINNED_READ_VERSION).toBe(1);
});

test("shared fixture refuses escaping ancestors before creating directories", async () => {
  const { buildRoundFixture } = await import("./testlib-capped-fold.ts");
  const scratch = root(); const outside = root();
  symlinkSync(outside, join(scratch, "specs"));
  await expect(buildRoundFixture(fixtureRequest(scratch))).rejects.toThrow("inside the scratch root");
  expect(existsSync(join(outside, "designs"))).toBe(false);
  expect(existsSync(join(outside, "plans"))).toBe(false);
});

const cappedKey = "HIMMEL-10205";
const cappedFixture = async (options: { specFindings?: string; planFindings?: string; rounds?: number; historical?: string; status?: boolean; specText?: string; planText?: string; pageName?: string } = {}) => {
  const { buildRoundFixture } = await import("./testlib-capped-fold.ts");
  const r = root();
  const specText = options.specText ?? fixtureSpecText.replace("# HIMMEL", "Key: HIMMEL-10205\n\n# HIMMEL").replace("## Alternatives considered", "Reference: HIMMEL-8626 remains a body reference.\n\n## Alternatives considered");
  const planText = options.planText ?? `---\ntickets: ${cappedKey}\n---\nKey: ${cappedKey}\n${fixturePlanText}`;
  const returns = [1, 2, 3, 4, 5].slice(0, options.rounds ?? 5).flatMap(round => (["spec", "plan"] as const).map(kind => {
    const findings = round === 1 && options.historical ? options.historical : kind === "spec" ? options.specFindings ?? "- **F1** (minor) carry this wording fix" : options.planFindings ?? "";
    const count = findings.split("\n").filter(l => l.startsWith("- **")).length;
    const status = options.status ? Array.from({ length: 8 }, (_, i) => `- **P${i + 8}:** status prose\n`).join("") : "";
    return { kind, round, text: `${status}${findings}\n${kind.toUpperCase()} ${count ? `FINDINGS ${count}` : "CLEAN"}\n`,
      reads: ["spec", ...(kind === "plan" ? ["plan"] : []), { path: `specs/designs/${options.pageName ?? "page.html"}`, text: "<h1>Review page</h1>\n" },
        { path: "specs/designs/estimate.json", text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' }] };
  }));
  const f = await buildRoundFixture({ scratchRoot: r, key: cappedKey, specText, planText, returns });
  return { ...f, r, args: { key: cappedKey, spec: f.spec, plan: f.plan,
    specReturn: f.verdicts.filter(p => p.includes("critic-spec-")).at(-1)!, planReturn: f.verdicts.filter(p => p.includes("critic-plan-")).at(-1)! } };
};
const runCapped = async (args: { key: string; spec: string; plan: string; specReturn: string; planReturn: string }) => {
  const module = await import("./chief-route");
  expect(typeof (module as any).cappedFold).toBe("function");
  return (module as any).cappedFold(args);
};
const editLedger = (f: { ledgerPath: string }, edit: (rows: any[]) => void) => {
  const rows = readFileSync(f.ledgerPath, "utf8").trim().split("\n").map(l => JSON.parse(l));
  edit(rows); writeFileSync(f.ledgerPath, rows.map(r => JSON.stringify(r)).join("\n") + "\n");
};
const editCappedReturn = async (f: { ledgerPath: string }, path: string, edit: (text: string) => string) => {
  const { returnSha } = await import("./chief-route"); const before = readFileSync(path, "utf8"); const after = edit(before);
  editLedger(f, rows => rows.filter(row => row.return_sha === returnSha(before)).forEach(row => {
    row.return_sha = returnSha(after); if (row.row === "round") row.verdict = after.trim().split("\n").at(-1);
  }));
  writeFileSync(path, after);
};
const treeBytes = (path: string): Record<string, string> => Object.fromEntries(readdirSync(path, { recursive: true, withFileTypes: true })
  .filter(e => e.isFile()).map(e => { const p = join(e.parentPath, e.name); return [p, sha(readFileSync(p, "utf8"))]; }));

const finishCappedRounds = async (options: { externalReturn?: "spec" | "plan"; externalPlan?: boolean; ticketReturn?: "spec" | "plan"; shortRead?: boolean } = {}) => {
  const f = await cappedFixture({ rounds: 4 });
  const oldPlan = f.plan;
  if (options.externalPlan) {
    f.plan = join(root(), basename(oldPlan)); copyFileSync(oldPlan, f.plan); f.args.plan = f.plan;
  }
  const { sealRound } = await import("./chief-route");
  for (const kind of ["spec", "plan"] as const) {
    const arg = kind === "spec" ? "specReturn" : "planReturn";
    const previous = f.args[arg];
    const next = join(options.externalReturn === kind ? root() : dirname(previous), basename(previous).replace("r4.md", "r5.md"));
    let text = readFileSync(previous, "utf8").replace(`Fixture: ${kind} round 4`, `Fixture: ${kind} round 5`)
      .replace(/^((?:READ(?:-SHA256)?|CONTENT-SHA256) [0-9a-f]{64}) (.+)$/gm, (_line, prefix, rel) => {
        const path = resolve(dirname(previous), rel);
        return `${prefix} ${path === oldPlan ? f.plan : path}`;
      });
    if (options.shortRead) text = text.replace(/^READ-SHA256 /gm, "READ ");
    if (options.ticketReturn === kind) text = text.replace(/^Key:/m, "- Ticket:");
    writeFileSync(next, text);
    for (const match of text.matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(next, match[1]);
    f.args[arg] = next;
  }
  return f;
};

test("capped fold discovers newer returns in every supplied directory", async () => {
  for (const location of ["spec", "plan", "plan-document"] as const) {
    const f = await finishCappedRounds(location === "plan-document" ? { externalPlan: true } : { externalReturn: location });
    expect((await runCapped(f.args)).returns.map((r: any) => r.round)).toEqual([5, 5]);
    const current = location === "spec" ? f.args.specReturn : f.args.planReturn;
    const directory = dirname(location === "plan-document" ? f.plan : current);
    copyFileSync(current, join(directory, basename(current).replace("r5.md", "r6.md")));
    await expect(runCapped(f.args)).rejects.toThrow("unaccounted latest return");
  }
});

test("capped fold return selection preserves older and other-key eligibility", async () => {
  const f = await cappedFixture();
  expect((await runCapped(f.args)).returns.map((r: any) => r.round)).toEqual([5, 5]);
  const directory = join(f.specsRoot, "design");
  writeFileSync(directory, "optional non-directory lookup");
  expect((await runCapped(f.args)).returns).toHaveLength(2);
  unlinkSync(directory); mkdirSync(directory);
  for (const name of ["HIMMEL-10205-other.md.critic-spec-r2.md", "HIMMEL-10205-other.md.critic-r2-plan.md", "HIMMEL-10205-other.md.critic-r2a.md",
    "HIMMEL-99999-other.md.critic-spec-r99.md", "irrelevant.txt"]) copyFileSync(f.args.specReturn, join(directory, name));
  expect((await runCapped(f.args)).returns.map((r: any) => r.round)).toEqual([5, 5]);
});

test("capped fold return selection refuses tied names in every supported grammar", async () => {
  for (const filename of ["HIMMEL-10205-other.md.critic-spec-r5.md", "HIMMEL-10205-other.md.critic-r5-plan.md", "HIMMEL-10205-other.md.critic-r5a.md"]) {
    const f = await cappedFixture();
    await runCapped(f.args);
    copyFileSync(f.args.specReturn, join(dirname(f.spec), filename));
    await expect(runCapped(f.args)).rejects.toThrow("unaccounted latest return");
  }
});

test("capped fold return selection refuses aliased unreadable and unbounded directories", async () => {
  for (const fault of ["alias", "unreadable", "overflow"]) {
    const f = await cappedFixture(); await runCapped(f.args);
    const directory = join(f.specsRoot, "design");
    if (fault === "alias") { const target = join(f.r, "target"); mkdirSync(target); symlinkSync(target, directory); }
    else mkdirSync(directory);
    if (fault === "unreadable") chmodSync(directory, 0);
    if (fault === "overflow") for (let i = 0; i < 4097; i++) writeFileSync(join(directory, `irrelevant-${i}`), "");
    try { await expect(runCapped(f.args)).rejects.toThrow(); }
    finally { if (fault === "unreadable") chmodSync(directory, 0o700); }
  }
});

test("capped fold return selection rechecks cached directory observations before success", async () => {
  for (const round of [3, 4]) {
    const f = await cappedFixture();
    const directory = join(f.specsRoot, "design"); mkdirSync(directory);
    const before = treeBytes(f.r);
    const shared = await import("../jira/src/release/pinned.ts");
    const actual = shared.pinnedRead;
    let reads = 0;
    const spy = spyOn(shared, "pinnedRead").mockImplementation(path => {
      const got = actual(path);
      if (path === f.spec && ++reads === 2) copyFileSync(f.args.specReturn, join(directory, basename(f.args.specReturn).replace("r5.md", `r${round}a.md`)));
      return got;
    });
    try { await expect(runCapped(f.args)).rejects.toThrow("evidence changed or is unreadable"); }
    finally { spy.mockRestore(); }
    expect(reads).toBe(2);
    for (const [path, hash] of Object.entries(before)) expect(sha(readFileSync(path, "utf8"))).toBe(hash);
  }
});

test("capped fold reads a Key declaration in a real sealed return when there is one and takes the key from the ledger when there is none", async () => {
  expect((await runCapped((await finishCappedRounds()).args)).returns).toHaveLength(2);
  const documents = await cappedFixture({
    specText: fixtureSpecText.replace("# HIMMEL", `- Ticket: ${cappedKey}\n\n# HIMMEL`),
    planText: `---\ntickets: ${cappedKey}\n---\n- Tickets: ${cappedKey}\n${fixturePlanText}`,
  });
  expect((await runCapped(documents.args)).returns).toHaveLength(2);
  for (const kind of ["spec", "plan"] as const) {
    const f = await finishCappedRounds({ ticketReturn: kind });
    const path = kind === "spec" ? f.args.specReturn : f.args.planReturn;
    expect([...readFileSync(path, "utf8").matchAll(/^Keys?:\s*(.+)$/gm)]).toHaveLength(0);
    expect((await runCapped(f.args)).returns, `a ${kind} return with a Ticket line and no Key line is bound by its ledger row`).toHaveLength(2);
  }
});

test("capped fold exact evidence", async () => {
  const f = await cappedFixture(); const before = treeBytes(f.r); const p = await runCapped(f.args);
  expect(p).toMatchObject({ schema: 1, reader_version: 1, mode: "capped-carry", key: cappedKey, epoch: 0,
    returns: [{ kind: "spec", round: 5, residuals: 1 }, { kind: "plan", round: 5, residuals: 0 }],
    carried: [{ key: cappedKey, epoch: 0, kind: "spec", round: 5, finding_id: "F1", severity: "minor", status: "open-carried" }] });
  expect(p.carried).toHaveLength(1);
  const shared = await import("../jira/src/release/pinned.ts"); expect(shared.validateCappedFoldProofShape(p)).toEqual(p);
  expect(p.pins.filter((x: any) => x.role === "artifact")).toHaveLength(4);
  expect(p.pins.filter((x: any) => x.role === "snapshot")).toHaveLength(4);
  for (const pin of p.pins) if ("path" in pin) expect(sha(readFileSync(pin.path, "utf8"))).toBe(pin.sha256);
  expect(treeBytes(f.r)).toEqual(before);
  const both = await cappedFixture({ planFindings: "- **F1** (medium) independent PLAN finding" });
  expect((await runCapped(both.args)).carried.map((c: any) => [c.kind, c.finding_id])).toEqual([["spec", "F1"], ["plan", "F1"]]);
  const controls = await cappedFixture({ status: true, specFindings: Array.from({ length: 10 }, (_, i) => `- **F${i}** (minor) true heading`).join("\n") });
  expect((await runCapped(controls.args)).carried).toHaveLength(10);
});

test("capped fold accepts real READ-SHA256 quotes and rejects malformed or duplicate quotes", async () => {
  const standard = await finishCappedRounds();
  expect(readFileSync(standard.args.specReturn, "utf8")).toContain(`READ-SHA256 ${sha(readFileSync(standard.spec, "utf8"))} ${standard.spec}`);
  expect((await runCapped(standard.args)).carried).toHaveLength(1);
  expect((await runCapped((await finishCappedRounds({ shortRead: true })).args)).carried).toHaveLength(1);
  for (const fault of ["malformed", "conflicting", "duplicate"]) {
    const f = await finishCappedRounds();
    await editCappedReturn(f, f.args.specReturn, text => {
      if (fault === "malformed") return text.replace("SPEC FINDINGS 1", "READ-SHA256 unknown file.md\nSPEC FINDINGS 1");
      if (fault === "conflicting") return text.replace(/^READ-SHA256 [0-9a-f]{64}/m, `READ-SHA256 ${"0".repeat(64)}`);
      const line = /^READ-SHA256 .+$/m.exec(text)![0];
      return text.replace("SPEC FINDINGS 1", `${line.replace("READ-SHA256", "READ")}\nSPEC FINDINGS 1`);
    });
    await expect(runCapped(f.args)).rejects.toThrow();
  }
});

test("capped fold rejects noneligible evidence", async () => {
  await runCapped((await cappedFixture()).args);
  const cases = [{ rounds: 2 }, { specFindings: "" }, { specFindings: "- **F1** (major) blocking" }, { specFindings: "- **F1** (unrated) unknown" },
    { specFindings: "- **F1** (minor) first\n- **F1** (medium) duplicate" },
    ...["unknown", "operator-critical: spend-grant", "operator-critical: imaginary", "reopens F0", "regression", ""].map(tag => ({ specFindings: `- **F1** (minor; ${tag}) blocked tag` })),
    { specFindings: "- **F1** (minor) valid\n  - **Bad** (unknown) malformed candidate" },
    { historical: "- **C1** (minor; operator-critical: spend-grant) historically open" }];
  for (const options of cases) { const f = await cappedFixture(options); await expect(runCapped(f.args)).rejects.toThrow(); }
  for (const corrupt of ["count", "ledger-count", "ledger-tag", "unrated", "closure"]) {
    const f = await cappedFixture();
    const { returnSha } = await import("./chief-route");
    editLedger(f, rows => {
      const row = rows.find(r => r.row === "round" && r.critic === "spec" && r.round === 5);
      if (corrupt === "ledger-count") row.findings = [];
      if (corrupt === "ledger-tag") row.findings[0].critical_refused = "other";
      if (corrupt === "unrated") row.unrated_ids = ["spec-r5-U1"];
      if (corrupt === "closure") row.findings[0].class = "regression";
      if (corrupt === "count") {
        const text = readFileSync(f.args.specReturn, "utf8").replace("SPEC FINDINGS 1", "SPEC FINDINGS 2");
        const old = row.return_sha; row.return_sha = returnSha(text); row.verdict = "SPEC FINDINGS 2";
        rows.filter(r => r.return_sha === old).forEach(r => { r.return_sha = row.return_sha; }); writeFileSync(f.args.specReturn, text);
      }
    });
    await expect(runCapped(f.args)).rejects.toThrow();
  }
});

test("capped fold rejects provenance drift", async () => {
  await runCapped((await cappedFixture()).args);
  for (const fault of ["key", "epoch", "old", "copy", "higher", "tied", "quote", "reviewed", "plan-reviewed", "seal", "extra-seal", "snapshot", "spec", "plan", "page", "estimate", "ledger", "manifest", "seed", "header", "frontmatter"]) {
    const f = await cappedFixture();
    if (fault === "key") editLedger(f, rows => { rows[0].key = "HIMMEL-99"; });
    if (fault === "epoch") editLedger(f, rows => { rows.find(r => r.row === "round" && r.round === 5).epoch = 7; });
    if (fault === "old") f.args.specReturn = f.verdicts[0];
    if (fault === "copy") { const p = join(f.r, basename(f.args.specReturn)); copyFileSync(f.args.specReturn, p); f.args.specReturn = p; }
    if (fault === "higher" || fault === "tied") copyFileSync(f.args.planReturn, fault === "higher" ? f.args.planReturn.replace("r5.md", "r6.md") : join(dirname(f.plan), basename(f.args.planReturn)));
    if (["quote", "reviewed", "plan-reviewed", "seal"].includes(fault)) {
      const p = fault === "plan-reviewed" ? f.args.planReturn : f.args.specReturn;
      await editCappedReturn(f, p, text => text.replace(fault === "quote" ? /^READ(?:-SHA256)? .*\n/m : fault === "seal" ? /^CONTENT-SHA256 .*\n/m : /^Reviewed: .*\n/m, ""));
    }
    if (fault === "extra-seal") editLedger(f, rows => { rows.push({ ...rows.at(-1), read_path: f.spec, read_sha: "f".repeat(64) }); });
    if (fault === "snapshot") writeFileSync(join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec, "utf8"))), "edited");
    const p = ({ spec: f.spec, plan: f.plan, page: join(dirname(f.spec), "page.html"), estimate: join(dirname(f.spec), "estimate.json"), ledger: f.ledgerPath, manifest: join(dirname(f.ledgerPath), "manifest.json") } as Record<string,string>)[fault];
    if (p) appendFileSync(p, "changed");
    if (fault === "seed") editLedger(f, rows => { rows.splice(0, rows.length, { row: "seed", key: cappedKey, spec: 5, plan: 5, latest: { spec: [], plan: [] } }); });
    if (fault === "header") writeFileSync(f.spec, readFileSync(f.spec, "utf8").replace(`Key: ${cappedKey}`, "Key: HIMMEL-99"));
    if (fault === "frontmatter") writeFileSync(f.plan, readFileSync(f.plan, "utf8").replace(`tickets: ${cappedKey}`, `tickets: [${cappedKey}, HIMMEL-99]`));
    await expect(runCapped(f.args)).rejects.toThrow();
  }
});

test("capped fold recording checkout bound", async () => {
  const f = await cappedFixture(); await runCapped(f.args);
  const dest = join(root(), "copy"); cpSync(f.r, dest, { recursive: true });
  const args = Object.fromEntries(Object.entries(f.args).map(([k,v]) => [k, k === "key" ? v : v.replace(f.r, dest)])) as typeof f.args;
  await expect(runCapped(args)).rejects.toThrow(); rmSync(f.r, { recursive: true }); await expect(runCapped(args)).rejects.toThrow();
});

test("capped fold bounded evidence", async () => {
  for (const role of ["return", "spec", "plan", "page", "estimate", "ledger", "manifest", "snapshot", "decision"]) for (const type of ["fifo", "directory", "oversized", "missing"]) {
    const f = role === "decision" ? await resetCappedFixture() : await cappedFixture();
    const path = ({ return: f.args.specReturn, spec: f.spec, plan: f.plan, page: join(dirname(f.spec), "page.html"), estimate: join(dirname(f.spec), "estimate.json"), ledger: f.ledgerPath, manifest: join(dirname(f.ledgerPath), "manifest.json"), snapshot: join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec,"utf8"))), decision: join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt") } as Record<string,string>)[role];
    unlinkSync(path);
    if (type === "directory") mkdirSync(path);
    else if (type === "oversized") { writeFileSync(path, ""); truncateSync(path, 16 * 1024 * 1024 + 1); }
    else if (type === "fifo") expect(Bun.spawnSync(["mkfifo", path]).exitCode).toBe(0);
    const flags = ["--key", cappedKey, "--spec", f.spec, "--plan", f.plan, "--spec-return", f.args.specReturn, "--plan-return", f.args.planReturn];
    const result = Bun.spawnSync(["bun", join(import.meta.dir, "chief-route.ts"), "capped-fold", ...flags], { timeout: 3000, stdout: "pipe", stderr: "pipe" });
    expect(result.exitCode).not.toBe(0); expect(result.signalCode ?? null).toBeNull(); expect(result.stderr.toString()).toContain("capped-fold");
  }
}, 120_000);

const resetCappedFixture = async () => {
  const f = await cappedFixture(); const decision = join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt"); mkdirSync(dirname(decision));
  const quote = "start this ticket over from scratch"; writeFileSync(decision, `${cappedKey} ${quote}\n`); utimesSync(decision, new Date(), new Date(Date.now() + 2000));
  const { roundReset, sealRound } = await import("./chief-route"); const prior = process.env.HIMMEL_CONSOLE; process.env.HIMMEL_CONSOLE = "1";
  try { await roundReset(f.specsRoot, cappedKey, { decision: "990", quote }); }
  finally { if (prior === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = prior; }
  for (const p of f.verdicts) {
    writeFileSync(p, readFileSync(p, "utf8").replace("Fixture:", "New epoch Fixture:"));
    for (const m of readFileSync(p, "utf8").matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(p, join(dirname(p), m[1]));
  }
  return { ...f, decision };
};
for (const fault of ["selection", "mtime", "alias", "directory-alias"] as const) test(`capped fold ${fault === "selection" ? "decision selection pins" : fault === "mtime" ? "decision mtime pins" : "alias rebinding"}${fault === "directory-alias" ? " directory" : ""}`, async () => {
  const shared = await import("../jira/src/release/pinned.ts"); const control = await resetCappedFixture(); const proof = await runCapped(control.args);
  expect(proof.epoch).toBe(1);
  expect(proof.pins).toContainEqual({ role: "decision-selection", directory: dirname(control.decision), decision: "990", names: [basename(control.decision)] });
  expect(proof.pins.find((p:any) => p.role === "decision").mtime_ms).toBe(statSync(control.decision).mtimeMs);
  const f = await resetCappedFixture(); const realRead = shared.pinnedRead; let calls = 0;
  const spy = spyOn(shared, "pinnedRead").mockImplementation(path => {
    const result = realRead(path);
    if (path === f.decision && ++calls === 1) {
      if (fault === "selection") copyFileSync(path, join(dirname(path), "verbatim-decision-990-second.txt"));
      if (fault === "mtime") { const st = statSync(path); utimesSync(path, st.atime, new Date(st.mtimeMs + 5000)); }
      if (fault === "alias") { const next = join(f.r, "same-decision.txt"); renameSync(path, next); symlinkSync(next, path); }
      if (fault === "directory-alias") { const next = join(f.r, "same-decisions"); renameSync(dirname(path), next); symlinkSync(next, dirname(path)); }
    }
    return result;
  });
  try { await expect(runCapped(f.args)).rejects.toThrow(); expect(calls).toBeGreaterThanOrEqual(2); }
  finally { spy.mockRestore(); }
});

test("capped fold CLI fixed five valued flags", async () => {
  const f = await cappedFixture(); const flags = ["--key", cappedKey, "--spec", f.spec, "--plan", f.plan, "--spec-return", f.args.specReturn, "--plan-return", f.args.planReturn];
  const ok = await routeCli("capped-fold", ...flags); expect(ok.code).toBe(0); expect(JSON.parse(ok.out).mode).toBe("capped-carry");
  for (const args of [flags.slice(2), [...flags, "--key", cappedKey], [...flags, "--unknown", "x"], [...flags, "x"], flags.slice(0,-1), [...flags.slice(0,3), "--plan", ...flags.slice(4)]]) {
    const bad = await routeCli("capped-fold", ...args); expect(bad.code).not.toBe(0); expect(bad.err).toContain("capped-fold");
  }
});

test("capped proof shared shape validation", async () => {
  const p = await runCapped((await cappedFixture()).args);
  const { validateCappedFoldProofShape } = await import("../jira/src/release/pinned.ts");
  expect(validateCappedFoldProofShape(p)).toEqual(p);
  for (const mutate of [(x:any) => { x.extra = true; }, (x:any) => { delete x.epoch; }, (x:any) => { x.reader_version = 2; },
    (x:any) => { x.pins[0].role = "other"; }, (x:any) => { x.returns.reverse(); }, (x:any) => { x.returns[0].residuals = -1; },
    (x:any) => { x.spec.sha256 = "A".repeat(64); }, (x:any) => { x.plan.path = "relative"; }]) {
    const bad = structuredClone(p); mutate(bad); expect(() => validateCappedFoldProofShape(bad)).toThrow("invalid capped-fold proof");
  }
});

test("capped fold strict declarations and complete seal grammar", async () => {
  for (const fault of ["bracket", "missing-key", "unknown-key", "duplicate-key"]) {
    const text = `---\ntickets: ${fault === "bracket" ? "[" : ""}${cappedKey}${fault === "missing-key" ? ` (Relates: HIMMEL-99)` : ""}\n---\nKey: ${fault === "unknown-key" ? "HIMMEL-99" : cappedKey}\n${fault === "duplicate-key" ? `Key: ${cappedKey}\n` : ""}## Body\n`;
    const f = await cappedFixture({ specText: fault === "missing-key" ? text.replace(`Key: ${cappedKey}\n`, "") : text });
    await expect(runCapped(f.args)).rejects.toThrow();
  }
  for (const fault of ["extra-read", "bad-read", "bad-seal", "huge-count", "body-key"]) {
    const f = await cappedFixture();
    await editCappedReturn(f, f.args.specReturn, text => fault === "body-key" ? text.replace("SPEC FINDINGS 1", "## Body\nKey: HIMMEL-99\nSPEC FINDINGS 1") : fault === "huge-count" ? text.replace("SPEC FINDINGS 1", "SPEC FINDINGS 999999999")
      : text.replace("SPEC FINDINGS 1", `${fault === "extra-read" ? `READ ${"a".repeat(64)} alien.md` : fault === "bad-read" ? "READ unknown spec.md" : "CONTENT-SHA256 unknown spec.md"}\nSPEC FINDINGS 1`));
    await expect(runCapped(f.args)).rejects.toThrow();
  }
});

test("capped fold refuses higher ticket returns in every supported folder/name", async () => {
  for (const filename of [`${cappedKey}-other.md.critic-spec-r6.md`, `${cappedKey}-fixture.md.critic-r6-spec.md`, `${cappedKey}-fixture.md.critic-r6.md`]) {
    const f = await cappedFixture(); copyFileSync(f.args.specReturn, join(dirname(f.spec), filename));
    await expect(runCapped(f.args)).rejects.toThrow();
  }
  const f = await cappedFixture(); const dir = join(f.specsRoot, "design"); mkdirSync(dir);
  copyFileSync(f.args.specReturn, join(dir, basename(f.args.specReturn).replace("r5", "r6")));
  await expect(runCapped(f.args)).rejects.toThrow();
});

test("capped fold refuses initially aliased evidence locations", async () => {
  for (const role of ["spec", "plan", "return", "ledger", "manifest", "snapshot", "page", "decision", "decision-directory"]) {
    const f = role.startsWith("decision") ? await resetCappedFixture() : await cappedFixture();
    await runCapped(f.args);
    const paths: Record<string,string> = { spec: f.spec, plan: f.plan, return: f.args.specReturn, ledger: f.ledgerPath,
      manifest: join(dirname(f.ledgerPath), "manifest.json"), snapshot: join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec, "utf8"))),
      page: join(dirname(f.spec), "page.html"), decision: join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt"), "decision-directory": join(f.specsRoot, "decisions") };
    const path = paths[role]; const target = join(f.r, "aliased-location"); renameSync(path, target); symlinkSync(target, path);
    await expect(runCapped(f.args)).rejects.toThrow();
  }
  const f = await cappedFixture(); const alias = join(f.r, "spec-alias.md"); symlinkSync(f.spec, alias);
  await expect(runCapped({ ...f.args, spec: alias })).rejects.toThrow();
});

test("capped fold refuses invalid ledger metadata outside the latest row", async () => {
  for (const fault of ["seal-epoch", "mode", "late-seed", "full-closure-class"]) {
    const f = await cappedFixture(); await runCapped(f.args);
    editLedger(f, rows => {
      if (fault === "seal-epoch") rows.find(row => row.row === "seal").epoch = 8;
      if (fault === "mode") rows.find(row => row.row === "round").mode = "invented";
      if (fault === "late-seed") rows.push({ key: cappedKey, row: "seed", spec: 0, plan: 0, latest: { spec: [], plan: [] } });
      if (fault === "full-closure-class") rows.find(row => row.row === "round" && row.round === 5 && row.critic === "spec").findings[0].class = "out-of-closure";
    });
    await expect(runCapped(f.args)).rejects.toThrow();
  }
});

test("capped fold pins evidence roles by use instead of filename resemblance", async () => {
  const f = await cappedFixture({ pageName: "memo.critic-spec-r1.md" }); const proof = await runCapped(f.args);
  expect(proof.pins.find((pin:any) => pin.path === join(dirname(f.spec), "memo.critic-spec-r1.md")).role).toBe("artifact");
});

test("capped fold still verifies a ledger whose latest closure round was opened by a valid operator extension, and refuses one whose extension row is invalid", async () => {
  const f = await cappedFixture({ specFindings: "- **M2** (major) blocking at the cap" }); const { sealRound } = await import("./chief-route");
  const nextSpec = async (round: number, ...body: string[]) => {
    const previous = f.args.specReturn; const lines = readFileSync(previous, "utf8").split("\n");
    const header = lines.slice(0, lines.findLastIndex(l => l.startsWith("READ-SHA256 ")) + 1).map(l => l.replace(/^Fixture: spec round \d+$/, `Fixture: spec round ${round}`));
    const next = previous.replace(/r\d+\.md$/, `r${round}.md`);
    const seals = lines.filter(l => l.startsWith("CONTENT-SHA256 "));
    writeFileSync(next, [...header, markerFor(f.specsRoot, cappedKey, "spec", round), ...body, ...seals, `SPEC FINDINGS ${body.filter(l => l.startsWith("- **")).length}`, ""].join("\n"));
    for (const s of seals) await sealRound(next, resolve(dirname(next), s.split(" ").slice(2).join(" ")));
    f.args.specReturn = next;
  };
  const run = (...args: string[]) => verb(true, ...args, "--specs", f.specsRoot);
  await nextSpec(6, "- **F3** (major; reopens M2) the blocking finding survives");
  expect((await run("round-override", cappedKey, "--findings", "F3", "--why", "a second closure", "--chief", "chief-x")).err).toBe("");
  await nextSpec(7, "- **F3** (major; reopens F3) still survives");
  const quote = "approve one closure round for the surviving finding"; const decision = join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt");
  mkdirSync(dirname(decision), { recursive: true }); writeFileSync(decision, `${cappedKey} ${quote}\n`); utimesSync(decision, new Date(), new Date(Date.now() + 5000));
  const granted = await run("round-extension", cappedKey, "--findings", "F3", "--decision", "990", "--quote", quote, "--why", "one closure", "--chief", "chief-x");
  expect(granted.err).toBe(""); expect(granted.out).toContain("writer round 8");
  await nextSpec(8, "- **m1** (minor) a nonblocking wording note");
  const proof = await runCapped(f.args);
  expect(proof).toMatchObject({ key: cappedKey, epoch: 0, returns: [{ kind: "spec", round: 8, residuals: 1 }, { kind: "plan", round: 5 }], carried: [{ finding_id: "m1", severity: "minor", round: 8 }] });
  expect(proof.pins).toContainEqual({ role: "decision-selection", directory: dirname(decision), decision: "990", names: [basename(decision)] });
  editLedger(f, rows => { rows.find(row => row.row === "extension").findings[0].return_sha = "f".repeat(64); });
  await expect(runCapped(f.args)).rejects.toThrow("invalid ledger records: extension 990");
}, S1B);

test("CQ7: a capped carry still verifies a ledger whose round 6 was re-classed and whose round 7, opened by the override, left only a minor", async () => {
  const f = await cappedFixture({ specFindings: "- **M2** (major) blocking at the cap" }); const { sealRound } = await import("./chief-route");
  const nextSpec = async (round: number, ...body: string[]) => {
    const previous = f.args.specReturn; const lines = readFileSync(previous, "utf8").split("\n");
    const header = lines.slice(0, lines.findLastIndex(l => l.startsWith("READ-SHA256 ")) + 1).map(l => l.replace(/^Fixture: spec round \d+$/, `Fixture: spec round ${round}`));
    const next = previous.replace(/r\d+\.md$/, `r${round}.md`);
    const seals = lines.filter(l => l.startsWith("CONTENT-SHA256 "));
    writeFileSync(next, [...header, markerFor(f.specsRoot, cappedKey, "spec", round), ...body, ...seals, `SPEC FINDINGS ${body.filter(l => l.startsWith("- **")).length}`, ""].join("\n"));
    for (const s of seals) await sealRound(next, resolve(dirname(next), s.split(" ").slice(2).join(" ")));
    f.args.specReturn = next;
  };
  const run = (...args: string[]) => verb(true, ...args, "--specs", f.specsRoot);
  await nextSpec(6, "- **U1** (major; regression) `this text is in no changed line`");
  editLedger(f, rows => { rows.findLast(row => row.row === "round" && row.critic === "spec").findings[0].class = "out-of-closure"; });
  const re = await run("round-reclass", cappedKey, "--round", "spec:6", "--why", "a stored unverified major", "--chief", "chief-x");
  expect(re.err).toBe(""); expect(re.out).toContain("U1 out-of-closure to regression-unverified");
  expect((await run("round-override", cappedKey, "--findings", "U1", "--why", "the re-classed major", "--chief", "chief-x")).err).toBe("");
  await nextSpec(7, "- **m1** (minor) a nonblocking wording note");
  const proof = await runCapped(f.args);
  expect(proof).toMatchObject({ key: cappedKey, epoch: 0, returns: [{ kind: "spec", round: 7, residuals: 1 }, { kind: "plan", round: 5 }], carried: [{ finding_id: "m1", severity: "minor", round: 7 }] });
});

const B1_LIB = join(import.meta.dir, "testlib-capped-fold.ts");
const B1_MINERVA = join(import.meta.dir, "..", "..", "marketplace", "plugins", "himmel-ops", "scripts");
const b1Lib = async (): Promise<any> => import("./testlib-capped-fold.ts");
const b1Rows = (f: { ledgerPath: string }): any[] => readFileSync(f.ledgerPath, "utf8").trim().split("\n").map(l => JSON.parse(l));
const b1Rel = (scratch: string, p: string) => p.startsWith(scratch + "/") ? p.slice(scratch.length + 1) : p;
const b1Status = async (f: { specsRoot: string }, key: string) => JSON.parse((await routeCli("round-status", key, "--specs", f.specsRoot, "--json")).out);
const b1Selector = (request: unknown) => {
  const p = Bun.spawnSync(["bun", B1_LIB], { stdin: Buffer.from(JSON.stringify(request)), stdout: "pipe", stderr: "pipe" });
  return { code: p.exitCode, out: p.stdout.toString(), err: p.stderr.toString() };
};
// What a reader sees of a fixture, with every scratch path made relative so an in-process build and a selector build compare equal.
const b1Summary = async (f: any, scratch: string, key: string) => {
  const rows = b1Rows(f).map((r: any) => [r.row, r.critic ?? null, r.round ?? null, r.epoch ?? null, r.mode ?? null, r.verdict ?? null, r.round_opened ?? null,
    r.verdict_path ? b1Rel(scratch, r.verdict_path) : null, r.row === "reset" ? b1Rel(scratch, r.decision_path) : null]);
  const s = await b1Status(f, key);
  return { fields: Object.keys(f).sort(), rows, state: { epoch: s.epoch, spec: s.spec, plan: s.plan, next: s.next, why: s.why, invalid: s.invalid, critical_open: s.critical_open },
    spec: b1Rel(scratch, f.spec), plan: b1Rel(scratch, f.plan), verdicts: f.verdicts.map((p: string) => b1Rel(scratch, p)), earlier: (f.earlier ?? []).map((p: string) => b1Rel(scratch, p)),
    decision: f.decision ? b1Rel(scratch, f.decision) : null, keys: f.keys ?? null, anchor: f.anchor ?? null, members: f.members ?? null };
};
const b1Lint = (f: { spec: string; plan: string; specsRoot: string }) => {
  const scratch = dirname(f.specsRoot); const home = mkdtempSync(join(tmpdir(), "b1-home-"));
  expect(Bun.spawnSync(["git", "init", "-q", scratch]).exitCode).toBe(0);
  const env = { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, NODE_ENV: "test", LANG: "C.UTF-8" };
  const run = (script: string, ...args: string[]) => {
    const p = Bun.spawnSync([BASH_BIN, join(B1_MINERVA, script), ...args], { cwd: script === "minerva-spec-gate.sh" ? dirname(f.spec) : scratch, env, stdout: "pipe", stderr: "pipe" });
    return { code: p.exitCode, out: p.stdout.toString() + p.stderr.toString() };
  };
  return { gate: run("minerva-spec-gate.sh", f.spec), trace: run("minerva-trace-lint.sh", f.spec, f.plan, scratch) };
};
const b1Kind = (f: { verdicts: string[] }, kind: "spec" | "plan") => f.verdicts.filter(p => p.includes(`.critic-${kind}-r`));

test("B1 availability: the typed builders and the real closureMarker exist, beside a control that the pre-existing builder still works", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  expect(typeof lib.buildRoundFixture, "control: the pre-existing generic builder").toBe("function");
  expect((await cappedFixture()).verdicts).toHaveLength(10);
  for (const name of ["buildGroupFixture", "buildKnownSingleFixture", "buildFreshSingleFixture"]) expect(typeof lib[name], `${name} builder`).toBe("function");
  expect(typeof route.closureMarker, "chief-route exports the real closureMarker").toBe("function");
  expect(route.closureMarker("HIMMEL-1", "spec", 4, "a".repeat(64))).toBe("CLOSURE-CHECK HIMMEL-1 spec r3 aaaaaaaaaaaa");
  expect(route.closureMarker("HIMMEL-1", "plan", 6, "0123456789abcdef".repeat(4))).toBe("CLOSURE-CHECK HIMMEL-1 plan r5 0123456789ab");
});

test("B1 group reset new-stem: a real reset, five preserved earlier returns, a restarted epoch 1, in process and through the selector", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  const scratch = realpathSync(root()); const consoleBefore = process.env.HIMMEL_CONSOLE;
  const actual = route.roundReset; let frozen: Record<string, string> = {}; let resets = 0;
  const spy = spyOn(route, "roundReset").mockImplementation((...a: any[]) => {
    resets++;
    const dir = join(scratch, "specs", "designs");
    frozen = Object.fromEntries(readdirSync(dir).filter(n => n.includes(".critic-")).map(n => [join(dir, n), sha(readFileSync(join(dir, n), "utf8"))]));
    expect(process.env.HIMMEL_CONSOLE, "the console marker is set around the real helper call").toBe("1");
    return actual(...a);
  });
  let f: any; try { f = await lib.buildGroupFixture(scratch); } finally { spy.mockRestore(); }
  expect(resets).toBe(1);
  expect(process.env.HIMMEL_CONSOLE, "the marker is restored").toBe(consoleBefore);
  expect(f.keys).toHaveLength(7); expect(f.anchor).toBe(f.keys[0]); expect(f.members).toEqual(f.keys.slice(1));
  const specText = readFileSync(f.spec, "utf8"); const planText = readFileSync(f.plan, "utf8");
  expect(specText).toContain(`tickets: [${f.keys.join(", ")}]`); expect(specText).not.toMatch(/^Keys?:|^- Tickets?:/m);
  expect(planText.startsWith("---")).toBe(false); expect(planText).not.toMatch(/^Keys?:/m);
  expect(f.spec.endsWith("-group-epoch1.md")).toBe(true); expect(f.plan.endsWith("-group-epoch1.md")).toBe(true);
  const ledgerDir = dirname(f.ledgerPath);
  for (const m of f.members) {
    expect(existsSync(join(ledgerDir, `${m}.jsonl`)), `${m} ledger`).toBe(false); expect(existsSync(join(ledgerDir, m)), `${m} snapshot folder`).toBe(false);
    expect(Object.keys(JSON.parse(readFileSync(join(ledgerDir, "manifest.json"), "utf8")).keys)).not.toContain(m);
  }
  expect(readdirSync(ledgerDir).sort()).toEqual([f.anchor, `${f.anchor}.jsonl`, `${f.anchor}.jsonl.lock`, "manifest.json", "round-seed.jsonl.lock"].filter(n => existsSync(join(ledgerDir, n))).sort());
  const rows = b1Rows(f); const rounds = rows.filter(r => r.row === "round");
  expect(rows.map(r => r.row).filter(k => !["round", "seal", "override", "reset"].includes(k))).toEqual([]);
  const old = rounds.filter(r => r.epoch === 0); const current = rounds.filter(r => r.epoch === 1);
  expect(old.map(r => [r.critic, r.round, r.mode])).toEqual([...[1, 2, 3, 4, 5].map(n => ["spec", n, "full"]), ["spec", 6, "closure"], ["spec", 7, "closure"]]);
  expect(old[4].findings.map((x: any) => x.severity)).toContain("major");
  expect(old[5].findings).toMatchObject([{ id: expect.any(String), severity: "major", regression: true, class: "regression" }]);
  expect(old[6].verdict).toBe("SPEC CLEAN");
  expect(old.filter(r => r.round >= 5)).toHaveLength(3);
  expect(rows.filter(r => r.row === "override")).toMatchObject([{ round_opened: 7, epoch: 0 }]);
  const reset = rows.filter(r => r.row === "reset"); expect(reset).toHaveLength(1);
  expect(reset[0]).toMatchObject({ epoch: 1, decision_path: f.decision });
  expect(rows.indexOf(reset[0])).toBeGreaterThan(rows.indexOf(old.at(-1)));
  expect(f.earlier).toEqual(old.map(r => r.verdict_path)); expect(f.earlier).toHaveLength(7);
  expect(current.map(r => [r.critic, r.round]).sort()).toEqual([["plan", 1], ["plan", 2], ["plan", 3], ["plan", 4], ["plan", 5], ["spec", 1], ["spec", 2], ["spec", 3], ["spec", 4], ["spec", 5]]);
  const currentPaths = new Set(current.map(r => r.verdict_path));
  expect(currentPaths.size).toBe(10);
  for (const p of f.earlier) expect(currentPaths.has(p), `${p} is not a current path`).toBe(false);
  for (const p of currentPaths) expect(String(p)).toContain("-epoch1.md.critic-");
  expect(readFileSync(current.find(r => r.critic === "spec").verdict_path, "utf8")).toContain("(medium; Fact overlap)");
  expect(f.verdicts).toEqual([...f.earlier, ...current.map(r => r.verdict_path)]);
  for (const r of old) {
    const text = readFileSync(r.verdict_path, "utf8");
    expect(route.returnSha(text), `${r.verdict_path} hashes to its row`).toBe(r.return_sha);
    expect(sha(text), "byte-identical to before the reset").toBe(frozen[r.verdict_path]);
  }
  expect(Object.keys(frozen).sort()).toEqual([...f.earlier].sort());
  for (const [i, r] of old.entries()) if (r.mode === "closure") expect(readFileSync(r.verdict_path, "utf8").split("\n")).toContain(route.closureMarker(f.anchor, "spec", r.round, old[i - 1].return_sha));
  expect(statSync(f.decision).mtimeMs, "decision strictly newer than the latest round row by the fixture's margin").toBeGreaterThan(Math.max(...old.map(r => r.ts)) + 1000);
  expect(readFileSync(f.decision, "utf8")).toStartWith(`${f.anchor} `);
  const state = await route.roundState(f.specsRoot, f.anchor);
  expect(state).toMatchObject({ epoch: 1, spec: 5, plan: 5, next: "none", invalid: [], critical_open: [] });
  expect(state.why).toContain("needs a blocking finding in round 5 of either kind");
  const lint = b1Lint(f); expect(lint.gate.out).toContain("minerva-spec-gate: ok"); expect(lint.trace.out).toContain("minerva-trace-lint: ok");
  const scratch2 = realpathSync(root()); const sel = b1Selector({ builder: "group", scratchRoot: scratch2, reset: "new-stem" });
  expect(sel.err).toBe(""); expect(sel.code).toBe(0); expect(sel.out.trimEnd().split("\n")).toHaveLength(1);
  expect(await b1Summary(JSON.parse(sel.out), scratch2, f.anchor)).toEqual(await b1Summary(f, scratch, f.anchor));
  const dflt = b1Selector({ builder: "group", scratchRoot: realpathSync(root()) });
  expect(JSON.parse(dflt.out).earlier).toHaveLength(7);
}, S1B);

test("B1 group reset in-place and none: the in-place earlier paths are all current rows, and none is epoch 0 with no reset", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  const scratch = realpathSync(root()); const f = await lib.buildGroupFixture(scratch, { reset: "in-place" });
  expect(f.earlier).toEqual([]);
  const rows = b1Rows(f); const rounds = rows.filter(r => r.row === "round");
  const old = rounds.filter(r => r.epoch === 0); const current = rounds.filter(r => r.epoch === 1);
  expect(old.length).toBeGreaterThan(0);
  const currentPaths = new Set(current.map(r => r.verdict_path));
  for (const r of old) {
    expect(currentPaths.has(r.verdict_path), `${r.verdict_path} is reused by a current row`).toBe(true);
    const text = readFileSync(r.verdict_path, "utf8"); const again = current.find(c => c.verdict_path === r.verdict_path);
    expect(text, "the existing recipe rewrites the return").toContain("New epoch Fixture:");
    expect(again.return_sha, "the current row seals the rewritten bytes").toBe(route.returnSha(text));
    expect(again.return_sha, "and not the epoch 0 bytes").not.toBe(r.return_sha);
  }
  expect(rows.filter(r => r.row === "reset")).toHaveLength(1); expect(f.decision).not.toBeNull(); expect(existsSync(f.decision)).toBe(true);
  expect(current.map(r => [r.critic, r.round]).sort()).toEqual([["plan", 1], ["plan", 2], ["plan", 3], ["plan", 4], ["plan", 5], ["spec", 1], ["spec", 2], ["spec", 3], ["spec", 4], ["spec", 5]]);
  const state = await route.roundState(f.specsRoot, f.anchor);
  expect(state).toMatchObject({ epoch: 1, spec: 5, plan: 5, next: "none", invalid: [], critical_open: [] });
  for (const kind of ["spec", "plan"]) {
    const latest = current.find(r => r.critic === kind && r.round === 5);
    expect(latest.findings.length).toBeGreaterThan(0);
    expect(latest.findings.every((finding: any) => ["medium", "minor"].includes(finding.severity))).toBe(true);
    expect(latest.unrated_ids ?? []).toEqual([]);
  }
  expect(f.spec.endsWith("-epoch1.md")).toBe(false);
  const lint = b1Lint(f); expect(lint.gate.out).toContain("minerva-spec-gate: ok"); expect(lint.trace.out).toContain("minerva-trace-lint: ok");
  const scratch2 = realpathSync(root()); const sel = b1Selector({ builder: "group", scratchRoot: scratch2, reset: "in-place" });
  expect(sel.err).toBe(""); expect(await b1Summary(JSON.parse(sel.out), scratch2, f.anchor)).toEqual(await b1Summary(f, scratch, f.anchor));

  const nscratch = realpathSync(root()); const n = await lib.buildGroupFixture(nscratch, { reset: "none" });
  expect(n.earlier).toEqual([]); expect(n.decision).toBeNull();
  const nrows = b1Rows(n);
  expect(nrows.filter(r => r.row === "reset" || r.row === "override")).toEqual([]);
  expect(nrows.filter(r => r.row === "round").map(r => [r.critic, r.round, r.epoch]).sort()).toEqual([["plan", 1, 0], ["plan", 2, 0], ["plan", 3, 0], ["plan", 4, 0], ["plan", 5, 0], ["spec", 1, 0], ["spec", 2, 0], ["spec", 3, 0], ["spec", 4, 0], ["spec", 5, 0]]);
  expect(await route.roundState(n.specsRoot, n.anchor)).toMatchObject({ epoch: 0, spec: 5, plan: 5, next: "none", invalid: [] });
  for (const m of n.members) { expect(existsSync(join(dirname(n.ledgerPath), `${m}.jsonl`))).toBe(false); expect(existsSync(join(dirname(n.ledgerPath), m))).toBe(false); }
  const nl = b1Lint(n); expect(nl.gate.out).toContain("minerva-spec-gate: ok"); expect(nl.trace.out).toContain("minerva-trace-lint: ok");
  const scratch3 = realpathSync(root()); const nsel = b1Selector({ builder: "group", scratchRoot: scratch3, reset: "none" });
  expect(await b1Summary(JSON.parse(nsel.out), scratch3, n.anchor)).toEqual(await b1Summary(n, nscratch, n.anchor));
  const cited = await lib.buildGroupFixture(realpathSync(root()), { reset: "none", citation: "scripts/telegram/chief-route.ts" });
  expect(readFileSync(cited.spec, "utf8")).toContain("## Fact ownership\n\n| Fact | Existing surfaces | Owner after | Non-owners |\n|---|---|---|---|\n| source | `scripts/telegram/chief-route.ts` | source | n/a |\n");
  expect(readFileSync(n.spec, "utf8")).not.toContain("Fact ownership");
}, S1B);

test("B1 known-single: refusedCap, overrideAdmitted and admittedNextRound each read back through the ledger, round-status and the selector", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  const seen: Record<string, any> = {};
  for (const variant of ["refusedCap", "overrideAdmitted", "admittedNextRound"] as const) {
    const scratch = realpathSync(root()); const f = await lib.buildKnownSingleFixture(scratch, { variant }); seen[variant] = f;
    const key = basename(f.spec).replace(/-fixture\.md$/, "");
    const specText = readFileSync(f.spec, "utf8"); const planText = readFileSync(f.plan, "utf8");
    expect(specText).toMatch(new RegExp(`^tickets: ${key} \\([^()]+\\)$`, "m")); expect(specText).not.toMatch(/^Keys?:|^- Tickets?:/m);
    expect(planText.startsWith("---")).toBe(false);
    const rows = b1Rows(f); const rounds = rows.filter(r => r.row === "round");
    expect(rows.map(r => r.row).filter(k => !["round", "seal", "override"].includes(k))).toEqual([]);
    expect(rounds.every(r => r.epoch === 0)).toBe(true);
    expect(rounds.filter(r => r.critic === "spec").map(r => [r.round, r.mode])).toEqual([[1, "full"], [2, "full"], [3, "full"], [4, "full"], [5, "full"], [6, "closure"], [7, "closure"]]);
    expect(rows.filter(r => r.row === "override")).toMatchObject([{ round_opened: 7 }]);
    const specReturn = readFileSync(b1Kind(f, "spec")[0], "utf8"); const planReturn = readFileSync(b1Kind(f, "plan")[0], "utf8");
    expect(specReturn).toMatch(/^READ-SHA256 [0-9a-f]{64}  \/\S+$/m);
    expect(planReturn).toMatch(/^READ-SHA256 \/\S+ [0-9a-f]{64}$/m);
    for (const t of [specReturn, planReturn]) { expect(t).not.toMatch(/^Key:/m); expect(t).not.toMatch(/^Reviewed:/m); }
    const state = await route.roundState(f.specsRoot, key); const status = await b1Status(f, key);
    expect(status).toMatchObject({ epoch: 0, spec: 7, invalid: [] }); expect(status.next).toBe(state.next);
    if (variant === "refusedCap") {
      expect(rounds.filter(r => r.critic === "plan").map(r => [r.round, r.mode])).toEqual([[1, "full"], [2, "full"], [3, "full"], [4, "full"], [5, "full"], [6, "closure"]]);
      const four = rounds.filter(r => r.critic === "plan").at(-1);
      expect(four.findings).toHaveLength(2); for (const x of four.findings) expect(x).toMatchObject({ severity: "minor", class: "out-of-closure" });
      expect(state.next).toBe("none"); expect(state.plan).toBe(6); expect(state.why).toContain(`${key} writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)`);
    }
    if (variant === "overrideAdmitted") {
      const four = rounds.filter(r => r.critic === "plan").at(-1);
      expect(four).toMatchObject({ round: 6, mode: "closure", findings: [{ severity: "major", regression: true, class: "regression" }] });
      expect(state.plan).toBe(6); expect(state.next).toBe("closure"); expect(state.why).toContain("plan round 7: closure");
    }
    if (variant === "admittedNextRound") {
      expect(rounds.filter(r => r.critic === "plan").map(r => r.round)).toEqual([1, 2, 3, 4, 5]);
      expect(state.plan).toBe(5); expect(state.next).toBe("closure"); expect(state.why).toContain("plan round 6: closure");
    }
    const lint = b1Lint(f); expect(lint.gate.out, variant).toContain("minerva-spec-gate: ok"); expect(lint.trace.out, variant).toContain("minerva-trace-lint: ok");
    const scratch2 = realpathSync(root()); const sel = b1Selector({ builder: "known-single", scratchRoot: scratch2, variant });
    expect(sel.err).toBe(""); expect(sel.out.trimEnd().split("\n")).toHaveLength(1);
    expect(await b1Summary(JSON.parse(sel.out), scratch2, key)).toEqual(await b1Summary(f, scratch, key));
  }
  expect(new Set(Object.values(seen).map((f: any) => f.verdicts.length)).size).toBe(2);
  const cited = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "admittedNextRound", citation: "scripts/telegram/chief-route.ts" });
  expect(readFileSync(cited.spec, "utf8")).toContain("| source | `scripts/telegram/chief-route.ts` | source | n/a |");
  await expect(lib.buildKnownSingleFixture(realpathSync(root()), { variant: "unknown" })).rejects.toThrow();
  expect(b1Selector({ builder: "known-single", scratchRoot: realpathSync(root()), variant: "unknown" }).code).not.toBe(0);
}, S1B);

test("B1 fresh single: a plain non-frozen key whose real ledger refuses round 6, with every redundant declaration omitted", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  const scratch = realpathSync(root()); const f = await lib.buildFreshSingleFixture(scratch);
  const key = basename(f.spec).replace(/-fixture\.md$/, "");
  const specText = readFileSync(f.spec, "utf8");
  expect(specText).toMatch(new RegExp(`^tickets: ${key}$`, "m")); expect(specText).not.toMatch(/^Keys?:|^- Tickets?:/m);
  expect(readFileSync(f.plan, "utf8").startsWith("---")).toBe(false);
  for (const v of f.verdicts) { const t = readFileSync(v, "utf8"); expect(t).not.toMatch(/^Key:/m); expect(t).not.toMatch(/^Reviewed:/m); }
  const rounds = b1Rows(f).filter(r => r.row === "round");
  expect(rounds.map(r => [r.critic, r.round, r.epoch, r.mode]).sort()).toEqual(["plan", "spec"].flatMap(k => [1, 2, 3, 4, 5].map(n => [k, n, 0, "full"])));
  for (const r of rounds.filter(x => x.round === 5)) for (const x of r.findings) expect(x.severity).not.toBe("major");
  const state = await route.roundState(f.specsRoot, key);
  expect(state).toMatchObject({ epoch: 0, spec: 5, plan: 5, next: "none", invalid: [] }); expect(state.why).toContain("needs a blocking finding in round 5 of either kind");
  const lint = b1Lint(f); expect(lint.gate.out).toContain("minerva-spec-gate: ok"); expect(lint.trace.out).toContain("minerva-trace-lint: ok");
  const scratch2 = realpathSync(root()); const sel = b1Selector({ builder: "fresh-single", scratchRoot: scratch2 });
  expect(sel.err).toBe(""); expect(await b1Summary(JSON.parse(sel.out), scratch2, key)).toEqual(await b1Summary(f, scratch, key));
  const grouped = await lib.buildGroupFixture(realpathSync(root()), { reset: "none" });
  const lines = readFileSync(grouped.spec, "utf8").split("\n").filter((l: string) => !l.startsWith("Estimate record:")).join("\n");
  const missing = await lib.buildRoundFixture({ scratchRoot: realpathSync(root()), key: grouped.anchor, specText: lines, planText: readFileSync(grouped.plan, "utf8"),
    returns: [{ kind: "spec", round: 1, text: "SPEC CLEAN\n", reads: ["spec"] }] });
  const refused = b1Lint(missing);
  expect(refused.gate.code).not.toBe(0); expect(refused.gate.out).toContain("minerva-spec-gate: REFUSED");
}, S1B);

test("B1 selector: a request without builder prints today's one JSON line, and an unknown builder is refused", async () => {
  const scratch = realpathSync(root()); const sel = b1Selector(fixtureRequest(scratch));
  expect(sel.err).toBe(""); expect(sel.code).toBe(0); expect(sel.out.trimEnd().split("\n")).toHaveLength(1);
  const f = JSON.parse(sel.out);
  expect(Object.keys(f).sort()).toEqual(["ledgerPath", "plan", "specsRoot", "spec", "verdicts"].sort());
  expect(f.verdicts).toHaveLength(10); expect(f.spec).toBe(join(scratch, "specs", "designs", "HIMMEL-10205-fixture.md")); expect(f.ledgerPath).toBe(join(scratch, "specs", "ledgers", "spec-rounds", "HIMMEL-10205.jsonl"));
  expect(b1Selector({ builder: "nonsense", scratchRoot: realpathSync(root()) }).code).not.toBe(0);
});

test("B1 generic options: declarations, specStem, quote shapes, real closure with rewrite, override and reset steps, each against a control", async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route");
  const KEY = "HIMMEL-9731"; const est = { path: "specs/designs/estimate.json", text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
  const specOf = (line: string) => `---\ntickets: ${KEY}\n---\n# ${KEY} generic\n\nEstimate record: estimate.json\n\n${line}\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`;
  const LINE = "The generic contract names every member.";
  const ret = (kind: "spec" | "plan", n: number, text: string, extra: Record<string, unknown> = {}) => ({ kind, round: n, text, reads: kind === "spec" ? ["spec", est] : ["spec", "plan", est], ...extra });
  const run = (extra: Record<string, unknown>, returns: any[]) => lib.buildRoundFixture({ scratchRoot: realpathSync(root()), key: KEY, specText: specOf(LINE), planText: "# generic plan\n\n- Task 1: build it.\n", ...extra, returns });
  const text = (f: any, i: number) => readFileSync(f.verdicts[i], "utf8");
  const dflt = await run({}, [ret("spec", 1, "- **A1** (minor) note\nSPEC FINDINGS 1\n")]);
  expect(text(dflt, 0).split("\n").slice(0, 3)).toEqual([`Key: ${KEY}`, `Reviewed: spec ${sha(readFileSync(dflt.spec, "utf8"))}`, "Fixture: spec round 1"]);
  expect(dflt.spec.endsWith(`${KEY}-fixture.md`)).toBe(true);
  const bare = await run({ declarations: false }, [ret("spec", 1, "SPEC CLEAN\n")]);
  expect(text(bare, 0)).not.toMatch(/^Key:|^Reviewed:/m); expect(text(bare, 0)).toContain("Fixture: spec round 1");
  const stem = await run({ specStem: `${KEY}-custom-stem` }, [ret("spec", 1, "SPEC CLEAN\n"), ret("plan", 1, "PLAN CLEAN\n")]);
  expect(stem.spec.endsWith("/designs/HIMMEL-9731-custom-stem.md")).toBe(true); expect(stem.plan.endsWith("/plans/HIMMEL-9731-custom-stem.md")).toBe(true);
  expect(stem.verdicts.map((p: string) => basename(p))).toEqual(["HIMMEL-9731-custom-stem.md.critic-spec-r1.md", "HIMMEL-9731-custom-stem.md.critic-plan-r1.md"]);
  const shapes = await run({}, [ret("spec", 1, "SPEC CLEAN\n", { quote: "sha-path-two-space" }), ret("spec", 2, "SPEC CLEAN\n"), ret("spec", 3, "SPEC CLEAN\n", { quote: "legacy-path-sha" })]);
  const readOf = (i: number) => text(shapes, i).split("\n").filter(l => l.startsWith("READ-SHA256 "))[0];
  const spec0 = sha(readFileSync(shapes.spec, "utf8"));
  expect(readOf(0)).toBe(`READ-SHA256 ${spec0}  ${shapes.spec}`); expect(readOf(1)).toBe(`READ-SHA256 ${spec0} ${shapes.spec}`); expect(readOf(2)).toBe(`READ-SHA256 ${shapes.spec} ${spec0}`);
  expect(b1Rows(shapes).filter(r => r.row === "round").map(r => r.round)).toEqual([1, 2, 3]);

  const full = (n: number) => ret("spec", n, n === 5 ? "- **M1** (major) the contract omits a member\nSPEC FINDINGS 1\n" : `- **A${n}** (minor) note\nSPEC FINDINGS 1\n`);
  const REG = `- **R1** (major; regression) the line \`${LINE}\` regressed\nSPEC FINDINGS 1\n`;
  const withRewrite = await run({ steps: [{ after: 5, step: "override", findings: ["R1"], why: "fixture override", chief: "fixture-chief" }] },
    [full(1), full(2), full(3), full(4), full(5), ret("spec", 6, REG, { closure: true, rewrite: { spec: specOf("The generic contract names each member and its owner.") } }), ret("spec", 7, "SPEC CLEAN\n", { closure: true })]);
  const wr = b1Rows(withRewrite); const r6 = wr.find(r => r.row === "round" && r.round === 6); const r5 = wr.find(r => r.row === "round" && r.round === 5);
  expect(r6).toMatchObject({ mode: "closure", findings: [{ id: "R1", class: "regression" }] });
  expect(text(withRewrite, 5).split("\n")).toContain(route.closureMarker(KEY, "spec", 6, r5.return_sha));
  expect(text(withRewrite, 6).split("\n")).toContain(route.closureMarker(KEY, "spec", 7, r6.return_sha));
  expect(wr.filter(r => r.row === "override")).toMatchObject([{ round_opened: 7, findings: [{ id: "R1", critic: "spec" }] }]);
  expect(wr.find(r => r.row === "round" && r.round === 7)).toMatchObject({ mode: "closure", verdict: "SPEC CLEAN" });
  expect(readFileSync(withRewrite.spec, "utf8")).toContain("and its owner");
  // control: without the rewrite the same quoted line is not among the changed lines, so the ledger classes it out-of-closure and nothing is blocking
  const noRewrite = await run({}, [full(1), full(2), full(3), full(4), full(5), ret("spec", 6, REG.replace("(major; regression)", "(medium; regression)"), { closure: true })]);
  expect(b1Rows(noRewrite).find(r => r.row === "round" && r.round === 6).findings).toMatchObject([{ id: "R1", class: "out-of-closure" }]);
  // control: a closure round without the real marker is refused by the real ledger
  await expect(run({}, [full(1), full(2), full(3), full(4), full(5), ret("spec", 6, "SPEC CLEAN\n")])).rejects.toThrow("closure check of round 5");
  // a second build on one scratch root is refused by the builder's own manifest check
  const again = realpathSync(root()); await lib.buildRoundFixture({ scratchRoot: again, key: KEY, specText: specOf(LINE), planText: "# p\n", returns: [ret("spec", 1, "SPEC CLEAN\n")] });
  await expect(lib.buildRoundFixture({ scratchRoot: again, key: KEY, specText: specOf(LINE), planText: "# p\n", returns: [ret("spec", 1, "SPEC CLEAN\n")] })).rejects.toThrow("already holds");
  // reset step: the decision recipe, a real reset, new-stem documents, counters restarting at 1, earlier files untouched
  const decision = "start this ticket over from scratch"; const stem1 = `${KEY}-group-epoch1`;
  const reset = await run({ steps: [{ after: 4, step: "reset", decision: "990", quote: decision, documents: { specStem: stem1, specText: specOf("The reset contract names every member."), planText: "# reset plan\n\n- Task 1: build it.\n" } }] },
    [full(1), full(2), full(3), full(4), full(5), ret("spec", 1, "SPEC CLEAN\n"), ret("plan", 1, "PLAN CLEAN\n")]);
  const rr = b1Rows(reset);
  expect(rr.filter(r => r.row === "reset")).toMatchObject([{ epoch: 1, decision: "990", quote: decision }]);
  expect(rr.filter(r => r.row === "round").map(r => [r.critic, r.round, r.epoch])).toEqual([["spec", 1, 0], ["spec", 2, 0], ["spec", 3, 0], ["spec", 4, 0], ["spec", 5, 0], ["spec", 1, 1], ["plan", 1, 1]]);
  expect(reset.spec.endsWith(`${stem1}.md`)).toBe(true); expect(reset.verdicts.slice(0, 5).every((p: string) => p.includes(`${KEY}-fixture.md.critic-`))).toBe(true);
  expect(readFileSync(join(reset.specsRoot, "decisions", "verbatim-decision-990-fixture.txt"), "utf8")).toBe(`${KEY} ${decision}\n`);
  // the builder supplies the console marker only around the real helper call: with the variable unset before the build it is unset after
  const before = process.env.HIMMEL_CONSOLE; delete process.env.HIMMEL_CONSOLE;
  try { await run({ steps: [{ after: 4, step: "reset", decision: "991", quote: decision, documents: { specStem: stem1, specText: specOf(LINE), planText: "# p\n" } }] }, [full(1), full(2), full(3), full(4), full(5)]); expect(process.env.HIMMEL_CONSOLE).toBeUndefined(); }
  finally { if (before !== undefined) process.env.HIMMEL_CONSOLE = before; }
  // and a value set before the build comes back as it was, not as "1" and not deleted
  process.env.HIMMEL_CONSOLE = "0";
  try {
    await run({ steps: [{ after: 5, step: "override", findings: ["R1"], why: "control", chief: "fixture-chief" }] },
      [full(1), full(2), full(3), full(4), full(5), ret("spec", 6, REG, { closure: true, rewrite: { spec: specOf("A changed control line for the console marker.") } })]);
    expect(process.env.HIMMEL_CONSOLE).toBe("0");
  } finally { if (before === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = before; }
  for (const prior of [undefined, "0"]) {
    if (prior === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = prior;
    try {
      await expect(run({ steps: [{ after: 4, step: "override", findings: ["not-open"], why: "failure control", chief: "fixture-chief" }] },
        [full(1), full(2), full(3), full(4), full(5)])).rejects.toThrow("not an open blocking finding");
      expect(process.env.HIMMEL_CONSOLE, "a throwing helper restores the prior console marker").toBe(prior);
    } finally { if (before === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = before; }
  }
}, S1B);

test("G0a v1 control: the shipped --key path refuses the real-shaped group header, beside a control that the same argv accepts a declared single", async () => {
  const lib = await b1Lib();
  const control = await cappedFixture(); const ok = await routeCli("capped-fold", "--key", cappedKey, "--spec", control.spec, "--plan", control.plan, "--spec-return", control.args.specReturn, "--plan-return", control.args.planReturn);
  expect(ok.code, "control: --key accepts a declared single").toBe(0); expect(JSON.parse(ok.out).mode).toBe("capped-carry");
  expect(typeof lib.buildGroupFixture, "group builder").toBe("function");
  const f = await lib.buildGroupFixture(realpathSync(root()));
  const res = await routeCli("capped-fold", "--key", f.anchor, "--spec", f.spec, "--plan", f.plan, "--spec-return", b1Kind(f, "spec").at(-1)!, "--plan-return", b1Kind(f, "plan").at(-1)!);
  expect(res.out).toBe(""); expect(res.code).toBe(1); expect(res.err).toBe(`capped-fold: capped-fold: tickets must declare only ${f.anchor}\n`);
}, S1B);

test("G0b v1 control: the shipped --key path refuses the legacy known-single header at refusedCap, beside the same control", async () => {
  const lib = await b1Lib();
  const control = await cappedFixture(); const ok = await routeCli("capped-fold", "--key", cappedKey, "--spec", control.spec, "--plan", control.plan, "--spec-return", control.args.specReturn, "--plan-return", control.args.planReturn);
  expect(ok.code, "control: --key accepts a declared single").toBe(0);
  expect(typeof lib.buildKnownSingleFixture, "known-single builder").toBe("function");
  const f = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" });
  const key = basename(f.spec).replace(/-fixture\.md$/, "");
  const res = await routeCli("capped-fold", "--key", key, "--spec", f.spec, "--plan", f.plan, "--spec-return", b1Kind(f, "spec").at(-1)!, "--plan-return", b1Kind(f, "plan").at(-1)!);
  expect(res.out).toBe(""); expect(res.code).toBe(1); expect(res.err).toBe(`capped-fold: capped-fold: header must declare only ${key}\n`);
}, S1B);

const t2Key = (n: number) => `HIMMEL-${n}`;
const t2Pinned = async (): Promise<any> => import("../jira/src/release/pinned.ts");
const t2File = (path: string) => ({ path, sha256: sha(readFileSync(path, "utf8")) });
const t2Clone = (base: any, fn: (p: any) => void) => { const p = structuredClone(base); fn(p); return p; };
const T2_INVALID = "invalid capped-fold proof";
let t2Cache: Promise<{ f: any; good: any; one: any }> | null = null;
const t2Build = async () => {
  const lib = await b1Lib(); const route: any = await import("./chief-route"); const shared = await t2Pinned();
  const f = await lib.buildGroupFixture(realpathSync(root()));
  const ledgerDir = dirname(f.ledgerPath);
  const returns = (["spec", "plan"] as const).map(kind => {
    const path = b1Kind(f, kind).at(-1)!;
    return { ...t2File(path), kind, round: 5, return_sha: route.returnSha(readFileSync(path, "utf8")), residuals: 1 };
  });
  const snapshot = join(ledgerDir, f.anchor, readdirSync(join(ledgerDir, f.anchor))[0]);
  const keys = [...f.keys].sort(); const members = keys.filter(k => k !== f.anchor);
  const good = {
    schema: 2, reader_version: 2, mode: "capped-carry-ledger", anchor: f.anchor, keys, epoch: 1,
    spec: t2File(f.spec), plan: t2File(f.plan), returns,
    pins: [
      { ...t2File(f.ledgerPath), role: "ledger" }, { ...t2File(join(ledgerDir, "manifest.json")), role: "manifest" },
      ...returns.map(r => ({ path: r.path, sha256: r.sha256, role: "return" })),
      ...[f.spec, f.plan].map(path => ({ ...t2File(path), role: "artifact" })),
      { ...t2File(snapshot), role: "snapshot" },
      ...f.earlier.map((path: string) => ({ ...t2File(path), role: "history" })),
      { ...t2File(f.decision), role: "decision", mtime_ms: statSync(f.decision).mtimeMs },
      { role: "decision-selection", directory: dirname(f.decision), decision: "990", names: [basename(f.decision)] },
      { role: "member-absence", directory: shared.ledgerDirOf(f.specsRoot), keys: members },
    ],
    carried: [["spec", "F1", "medium"], ["plan", "P1", "minor"]].map(([kind, id, severity], i) => ({
      key: f.anchor, epoch: 1, kind, round: 5, return_path: returns[i].path, return_sha: returns[i].return_sha, finding_id: id, severity, status: "open-carried" })),
  };
  const one = t2Clone(good, p => { p.keys = [f.anchor]; p.pins = p.pins.filter((x: any) => x.role !== "member-absence"); });
  return { f, good, one };
};
const t2Group = () => { t2Cache ??= t2Build(); return t2Cache; };
const t2Pin = (p: any, role: string) => p.pins.findIndex((x: any) => x.role === role);

test("S4 dispatcher: a stored v1 proof from the real verifier is valid and equals the shipped validator's answer; a v1 body stays strict", async () => {
  const shared = await t2Pinned();
  const v1 = await runCapped((await cappedFixture()).args);
  expect(v1.schema).toBe(1);
  expect(shared.validateCappedProofShape(v1)).toEqual(v1);
  expect(shared.validateCappedProofShape(v1)).toEqual(shared.validateCappedFoldProofShape(v1));
  for (const mutate of [(x: any) => { x.extra = true; }, (x: any) => { delete x.epoch; }, (x: any) => { x.reader_version = 2; }, (x: any) => { x.mode = "capped-carry-ledger"; },
    (x: any) => { x.pins[0].role = "other"; }, (x: any) => { x.returns.reverse(); },
    (x: any) => { x.pins.push({ role: "history", path: join(dirname(x.spec.path), "old-return.md"), sha256: "a".repeat(64) }); }]) {
    const bad = structuredClone(v1); mutate(bad);
    expect(() => shared.validateCappedProofShape(bad)).toThrow(T2_INVALID);
  }
}, S1B);

test("S2 dispatcher: unknown, absent and mixed schemas refuse with the one shipped message", async () => {
  const shared = await t2Pinned(); const { good } = await t2Group();
  expect(shared.LEDGER_READ_VERSION).toBe(2); expect(shared.PINNED_READ_VERSION).toBe(1);
  expect(shared.validateCappedProofShape(good)).toEqual(good);
  expect(() => shared.validateCappedFoldProofShape(good), "the unchanged v1 validator refuses a schema 2 proof").toThrow(T2_INVALID);
  const v1 = await runCapped((await cappedFixture()).args);
  const refuse = (value: unknown) => expect(() => shared.validateCappedProofShape(value)).toThrow(T2_INVALID);
  for (const schema of [0, 3, "1", "2", null, undefined, true, 2.5]) refuse(t2Clone(good, p => { p.schema = schema; }));
  for (const value of [null, undefined, [], "x", 5, true, {}, { schema: 2 }, { schema: 1 }]) refuse(value);
  refuse(t2Clone(good, p => { delete p.schema; }));
  refuse(t2Clone(good, p => { p.mode = "capped-carry"; }));
  refuse(t2Clone(good, p => { p.key = p.anchor; }));
  refuse(t2Clone(good, p => { delete p.anchor; delete p.keys; delete p.mode; p.key = good.anchor; p.mode = "capped-carry"; }));
  refuse(t2Clone(good, p => { p.schema = 1; }));
  refuse(t2Clone(good, p => { p.schema = 1; p.reader_version = 1; p.mode = "capped-carry"; }));
  for (const [field, value] of [["anchor", good.anchor], ["keys", good.keys], ["mode", "capped-carry-ledger"]] as const) refuse(t2Clone(v1, p => { p[field] = value; }));
  refuse(t2Clone(v1, p => { p.schema = 2; }));
  refuse(t2Clone(v1, p => { p.schema = 2; p.reader_version = 2; }));
}, S1B);

test("S3 v2 shape: the exact fields, sorted unique keys, an anchor member, history file pins and the group-exact member-absence pin", async () => {
  const shared = await t2Pinned(); const { f, good, one } = await t2Group();
  const accept = (value: any) => expect(shared.validateCappedLedgerProofShape(value)).toEqual(value);
  const refuse = (value: unknown) => expect(() => shared.validateCappedLedgerProofShape(value)).toThrow(T2_INVALID);
  accept(good); accept(one);
  expect(one.keys).toEqual([f.anchor]); expect(t2Pin(one, "member-absence")).toBe(-1);
  expect(good.pins.filter((p: any) => p.role === "history").map((p: any) => p.path)).toEqual(f.earlier);
  const middle = t2Clone(good, p => {
    p.anchor = p.keys[3]; for (const c of p.carried) c.key = p.anchor;
    p.pins[t2Pin(p, "member-absence")].keys = p.keys.filter((k: string) => k !== p.anchor);
  });
  accept(middle);
  const memberKeys = (p: any, fn: (keys: string[]) => string[]) => { const i = t2Pin(p, "member-absence"); p.pins[i].keys = fn(p.pins[i].keys); };

  for (const field of Object.keys(good)) refuse(t2Clone(good, p => { delete p[field]; }));
  refuse(t2Clone(good, p => { p.extra = true; }));
  for (const value of [1, 3, "2"]) refuse(t2Clone(good, p => { p.schema = value; }));
  for (const value of [1, 3, "2", undefined]) refuse(t2Clone(good, p => { p.reader_version = value; }));
  for (const value of ["capped-carry", "capped-carry-ledger ", "Capped-Carry-Ledger", "", undefined, 2]) refuse(t2Clone(good, p => { p.mode = value; }));
  for (const value of [-1, 1.5, "1", null]) refuse(t2Clone(good, p => { p.epoch = value; }));
  for (const value of [t2Key(1), "himmel-9801", "HIMMEL", "", 9801, null]) refuse(t2Clone(good, p => { p.anchor = value; }));

  refuse(t2Clone(good, p => { [p.keys[1], p.keys[2]] = [p.keys[2], p.keys[1]]; memberKeys(p, () => p.keys.filter((k: string) => k !== p.anchor)); }));
  refuse(t2Clone(good, p => { p.keys[2] = p.keys[1]; memberKeys(p, () => p.keys.filter((k: string) => k !== p.anchor)); }));
  refuse(t2Clone(good, p => { p.keys.push(p.keys[3]); memberKeys(p, () => p.keys.filter((k: string) => k !== p.anchor)); }));
  refuse(t2Clone(good, p => { p.keys = []; }));
  refuse(t2Clone(one, p => { p.keys = []; }));
  refuse(t2Clone(good, p => { p.keys = "x"; }));
  for (const bad of ["himmel-9803", "HIMMEL", "", 9803, null]) refuse(t2Clone(good, p => { p.keys[2] = bad; memberKeys(p, () => p.keys.filter((k: string) => k !== p.anchor)); }));
  refuse(t2Clone(good, p => { p.keys = p.keys.filter((k: string) => k !== p.anchor); memberKeys(p, () => p.keys); }));

  const big = (n: number) => t2Clone(good, p => {
    p.keys = [...Array.from({ length: n - 1 }, (_, i) => t2Key(100000 + i)), p.anchor].sort();
    memberKeys(p, () => p.keys.filter((k: string) => k !== p.anchor));
  });
  accept(big(4096)); refuse(big(4097));

  const history = (p: any) => p.pins.findIndex((x: any) => x.role === "history");
  for (const field of ["path", "sha256"]) refuse(t2Clone(good, p => { delete p.pins[history(p)][field]; }));
  refuse(t2Clone(good, p => { p.pins[history(p)].mtime_ms = 1; }));
  refuse(t2Clone(good, p => { p.pins[history(p)].extra = true; }));
  refuse(t2Clone(good, p => { p.pins[history(p)].sha256 = "A".repeat(64); }));
  refuse(t2Clone(good, p => { p.pins[history(p)].path = "relative.md"; }));
  refuse(t2Clone(good, p => { p.pins.push({ ...p.pins[history(p)] }); }));
  for (const target of [() => good.returns[0].path, () => good.spec.path, () => f.ledgerPath]) refuse(t2Clone(good, p => { p.pins[history(p)].path = target(); }));
  refuse(t2Clone(good, p => { p.pins.push({ role: "history" }); }));
  refuse(t2Clone(good, p => { p.pins = "x"; }));

  refuse(t2Clone(good, p => { p.pins.splice(t2Pin(p, "member-absence"), 1); }));
  refuse(t2Clone(one, p => { p.pins.push(good.pins[t2Pin(good, "member-absence")]); }));
  refuse(t2Clone(good, p => { p.pins.push(structuredClone(p.pins[t2Pin(p, "member-absence")])); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => k.slice(1)); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => k.slice(0, -1)); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => [...k, t2Key(99999)]); }));
  refuse(t2Clone(good, p => { memberKeys(p, () => []); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => [p.anchor, ...k].sort()); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => [...k, t2Key(1)].sort()); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => [...k].reverse()); }));
  refuse(t2Clone(good, p => { memberKeys(p, k => [k[0], ...k]); }));
  refuse(t2Clone(good, p => { memberKeys(p, () => "x" as any); }));
  refuse(t2Clone(good, p => { p.pins[t2Pin(p, "member-absence")].extra = true; }));
  for (const field of ["directory", "keys"]) refuse(t2Clone(good, p => { delete p.pins[t2Pin(p, "member-absence")][field]; }));

  for (const field of Object.keys(good.returns[0])) refuse(t2Clone(good, p => { delete p.returns[0][field]; }));
  refuse(t2Clone(good, p => { p.returns.reverse(); }));
  refuse(t2Clone(good, p => { p.returns.pop(); }));
  refuse(t2Clone(good, p => { p.returns[1].kind = "spec"; }));
  refuse(t2Clone(good, p => { p.returns[0].round = 0; }));
  refuse(t2Clone(good, p => { p.returns[0].residuals = 2; }));
  refuse(t2Clone(good, p => { p.returns[0].sha256 = "0".repeat(64); }));
  for (const bad of ["x", "A".repeat(64), "a".repeat(63), "a".repeat(65), ""]) {
    refuse(t2Clone(good, p => { p.returns[0].return_sha = bad; p.carried[0].return_sha = bad; }));
  }

  for (const field of Object.keys(good.carried[0])) refuse(t2Clone(good, p => { delete p.carried[0][field]; }));
  refuse(t2Clone(good, p => { p.carried[0].key = p.keys[1]; }));
  refuse(t2Clone(good, p => { p.carried[0].epoch = 0; }));
  refuse(t2Clone(good, p => { p.carried[0].round = 2; }));
  refuse(t2Clone(good, p => { p.carried[0].return_path = p.returns[1].path; }));
  refuse(t2Clone(good, p => { p.carried[0].return_sha = "0".repeat(64); }));
  refuse(t2Clone(good, p => { p.carried.push({ ...p.carried[0] }); p.returns[0].residuals = 2; }));
  for (const bad of ["major", "operator-critical", undefined]) refuse(t2Clone(good, p => { p.carried[0].severity = bad; }));
  refuse(t2Clone(good, p => { p.carried[0].status = "closed"; }));
  refuse(t2Clone(good, p => { p.carried[0].finding_id = "1bad"; }));
  refuse(t2Clone(good, p => { p.carried[0].extra = true; }));
  refuse(t2Clone(good, p => { p.carried.pop(); }));

  for (const role of ["ledger", "manifest"]) {
    refuse(t2Clone(good, p => { p.pins.splice(t2Pin(p, role), 1); }));
    refuse(t2Clone(good, p => { p.pins.push({ ...p.pins[t2Pin(p, role)], path: `${f.specsRoot}/other-${role}` }); }));
  }
  refuse(t2Clone(good, p => { p.pins.splice(t2Pin(p, "return"), 1); }));
  refuse(t2Clone(good, p => { p.pins[t2Pin(p, "return")].sha256 = "0".repeat(64); }));
  refuse(t2Clone(good, p => { p.pins.splice(t2Pin(p, "artifact"), 1); }));
  refuse(t2Clone(good, p => { p.pins[t2Pin(p, "snapshot")].role = "other"; }));
  refuse(t2Clone(good, p => { p.pins.splice(t2Pin(p, "decision-selection"), 1); }));
  refuse(t2Clone(good, p => { delete p.pins[t2Pin(p, "decision")].mtime_ms; }));
  refuse(t2Clone(good, p => { p.pins[t2Pin(p, "decision-selection")].names.push("verbatim-decision-990-second.txt"); }));
  refuse(t2Clone(good, p => { p.pins.push(structuredClone(p.pins[t2Pin(p, "decision-selection")])); }));
}, S1B);

test("M7 member-absence pin: its directory must be the shared ledger folder under the spec's own specs root", async () => {
  const shared = await t2Pinned(); const { f, good } = await t2Group();
  const real = shared.ledgerDirOf(f.specsRoot);
  expect(real).toBe(dirname(f.ledgerPath));
  expect(shared.specsRootOf(good.spec.path)).toBe(f.specsRoot);
  const withDirectory = (directory: unknown) => t2Clone(good, p => { p.pins[t2Pin(p, "member-absence")].directory = directory; });
  expect(shared.validateCappedLedgerProofShape(withDirectory(real))).toEqual(good);
  const other = realpathSync(root());
  for (const directory of [join(other, "ledgers", "spec-rounds"), join(other, "specs", "ledgers", "spec-rounds"), join(f.specsRoot, "ledgers"), dirname(f.specsRoot),
    `${real}/`, `${real}/.`, `${real}/../spec-rounds`, "ledgers/spec-rounds", "", undefined, 7, join(f.specsRoot, "ledgers", "spec-rounds", t2Key(9801))]) {
    expect(() => shared.validateCappedLedgerProofShape(withDirectory(directory)), String(directory)).toThrow(T2_INVALID);
  }
  const outside = t2Clone(good, p => {
    const to = "/tmp/no-specs-root/spec.md";
    for (const pin of p.pins) if (pin.path === p.spec.path) pin.path = to;
    p.spec.path = to;
  });
  expect(() => shared.validateCappedLedgerProofShape(outside), "a spec path with no specs root cannot hold the pin").toThrow(T2_INVALID);
}, S1B);

test("U1 shared ledger names, manifest parser and member predicate", async () => {
  const shared = await t2Pinned(); const { f } = await t2Group();
  expect(shared.ledgerDirOf("/x/specs")).toBe("/x/specs/ledgers/spec-rounds");
  expect(shared.ledgerDirOf(f.specsRoot)).toBe(dirname(f.ledgerPath));
  expect(shared.ledgerEntryNames("K-1")).toEqual({ file: "K-1.jsonl", folder: "K-1", lock: "K-1.jsonl.lock" });
  const ledgerDir = dirname(f.ledgerPath); const real = readdirSync(ledgerDir);
  const names = shared.ledgerEntryNames(f.anchor);
  expect(real).toContain(names.file); expect(real).toContain(names.folder); expect(real).toContain(names.lock);
  expect(join(ledgerDir, names.file)).toBe(f.ledgerPath);
  expect(statSync(join(ledgerDir, names.folder)).isDirectory()).toBe(true);

  expect(shared.ledgerKeyOfFile("K-1.jsonl")).toBe("K-1");
  expect(shared.ledgerKeyOfFile(names.file)).toBe(f.anchor);
  for (const name of ["K-1.jsonl.lock", "manifest.json", "K-1", "K-1.json", "notes.txt", "K-1.jsonl.bak", "round-seed.jsonl.lock"]) expect(shared.ledgerKeyOfFile(name), name).toBeNull();
  const listing = [...real, "stray.jsonl", ".jsonl", "other.json", "x.jsonl.lock"];
  expect(listing.map((n: string) => shared.ledgerKeyOfFile(n)).filter((k: string | null) => k !== null),
    "the same key set the shipped no-key round-status listing derives").toEqual(listing.filter(n => n.endsWith(".jsonl")).map(n => n.slice(0, -".jsonl".length)));

  const manifestText = readFileSync(join(ledgerDir, "manifest.json"), "utf8");
  expect(shared.parseManifest(manifestText)).toEqual(JSON.parse(manifestText));
  expect(shared.parseManifest('{"keys":{}}')).toEqual({ keys: {} });
  expect(shared.parseManifest('{"keys":{"a":1},"other":2}')).toEqual({ keys: { a: 1 }, other: 2 });
  for (const text of ["", "{", "null", "[]", "5", '"x"', "true", "{}", '{"keys":[]}', '{"keys":null}', '{"keys":"x"}', '{"keys":5}', '{"key":{}}']) expect(shared.parseManifest(text), text).toBeNull();

  const members = [t2Key(1), t2Key(2), t2Key(3)]; const state = (listing: string[], manifest: string[]) => shared.memberLedgerState(listing, manifest, members).present;
  expect(state([], [])).toEqual([]);
  expect(state([`${members[0]}.jsonl`], [])).toEqual([members[0]]);
  expect(state([members[1]], [])).toEqual([members[1]]);
  expect(state([], [members[2]])).toEqual([members[2]]);
  expect(state([members[2], `${members[0]}.jsonl`], [members[1]])).toEqual(members);
  expect(state([`${members[0]}.jsonl.lock`, `${members[2]}.jsonl.lock`], [])).toEqual([]);
  expect(state([`${members[0]}.jsonl.lock`, `${members[0]}.jsonl`], [])).toEqual([members[0]]);
  expect(state(["manifest.json", `${t2Key(9)}.jsonl`, t2Key(9), `${members[0]}.json`, `${members[0]}.jsonl.bak`], [t2Key(9)])).toEqual([]);
  expect(state([], ["manifest.json"])).toEqual([]);
  expect(shared.memberLedgerState([`${members[1]}.jsonl`], [], []).present).toEqual([]);

  const manifestKeys = Object.keys(shared.parseManifest(manifestText).keys);
  expect(shared.memberLedgerState(real, manifestKeys, f.members).present, "the real group fixture holds no member state").toEqual([]);
  expect(shared.memberLedgerState(real, manifestKeys, [f.anchor]).present, "the real anchor ledger file and folder are seen").toEqual([f.anchor]);
  expect(real.some((n: string) => n === "round-seed.jsonl.lock"), "the real writer left a lock file").toBe(true);
  expect(shared.memberLedgerState(real, manifestKeys, ["round-seed"]).present, "a real lock file alone is not member state").toEqual([]);
}, S1B);

test("H1 checkLatestReturns: omitted equals empty equals the shipped refusal, a listed path is skipped, every unlisted file at or above the signed round still refuses", async () => {
  const lib = await b1Lib(); const shared = await t2Pinned(); const route: any = await import("./chief-route");
  const f = await lib.buildGroupFixture(realpathSync(root()));
  const pin = (kind: "spec" | "plan") => {
    const path = b1Kind(f, kind).at(-1)!;
    return { ...t2File(path), kind, round: 5, return_sha: route.returnSha(readFileSync(path, "utf8")), residuals: 1 };
  };
  const expected = [pin("spec"), pin("plan")];
  const scan = (...history: unknown[]) => { for (const d of shared.returnDirectories(f.anchor, f.spec, f.plan, expected)) shared.checkLatestReturns(d, shared.canonicalDirectoryNames(d).names, f.anchor, expected, ...history); };
  const refusal = (path: string) => `capped-fold: ambiguous or unaccounted latest return: ${path}`;
  expect(f.earlier).toHaveLength(7);
  expect(() => scan(), "v1 refuses the first earlier file at or above the signed round").toThrow(refusal(f.earlier[4]));
  expect(() => scan(undefined)).toThrow(refusal(f.earlier[4]));
  expect(() => scan(new Set<string>()), "an empty set equals omitted").toThrow(refusal(f.earlier[4]));
  expect(() => scan(new Set(f.earlier))).not.toThrow();
  expect(() => scan(new Set(f.earlier.slice(4))), "files below the signed round pass without being listed").not.toThrow();
  expect(() => scan(new Set([f.earlier[4], f.earlier[6]])), "one unlisted file at the signed round or above refuses").toThrow(refusal(f.earlier[5]));
  expect(() => scan(new Set(f.earlier.map((p: string) => join(dirname(f.spec), "..", "plans", basename(p)))))).toThrow(refusal(f.earlier[4]));
  expect(() => scan(new Set(f.earlier.map((p: string) => basename(p))))).toThrow(refusal(f.earlier[4]));
  expect(() => scan(new Set([...f.earlier, join(dirname(f.spec), "unrelated-file.md")]))).not.toThrow();
  const fresh = join(dirname(f.spec), `${basename(f.spec, ".md")}.critic-spec-r6.md`);
  writeFileSync(fresh, "SPEC CLEAN\n");
  expect(() => scan(new Set(f.earlier)), "a new unlisted return at the same stem still refuses").toThrow(refusal(fresh));
  expect(() => scan(new Set([...f.earlier, fresh])), "only the listed path is skipped").not.toThrow();
  expect(() => scan(new Set([...f.earlier, join(dirname(f.spec), "other.md")])), "an unrelated listed path skips nothing").toThrow(refusal(fresh));
}, S1B);

const t2Front = (line: string, rest = "") => `---\n${line}\n---\n# Title\n${rest}`;
const T2_NOTE = "a partial merge owes proof by default, and only chief-only steps owe the chief";

test("D1 declaredTickets: plain, flow, comma and annotated scalars, with commas inside an annotation never splitting items", async () => {
  const shared = await t2Pinned(); const lib = await b1Lib();
  const [a, b, c] = [t2Key(9), t2Key(10), t2Key(11)]; const read = (line: string, rest?: string) => shared.declaredTickets(t2Front(line, rest));
  expect(read(`tickets: ${a}`)).toEqual([a]);
  expect(read(`tickets:${a}`)).toEqual([a]);
  expect(read(`tickets:   ${a}  `)).toEqual([a]);
  expect(read(`tickets: [${a}]`)).toEqual([a]);
  expect(read(`tickets: [${a}, ${b}, ${c}]`)).toEqual([a, b, c]);
  expect(read(`tickets: [ ${a} ,${b}\t,  ${c} ]`)).toEqual([a, b, c]);
  expect(read(`tickets: ${a}, ${b}`)).toEqual([a, b]);
  expect(read(`tickets: ${c},${a}`), "declared order is kept").toEqual([c, a]);
  expect(read(`tickets: ${a} (${T2_NOTE})`), "the real annotated scalar").toEqual([a]);
  expect(read(`tickets: ${a}(${T2_NOTE})`)).toEqual([a]);
  expect(read(`tickets: [${a} (first, with a comma), ${b}]`)).toEqual([a, b]);
  expect(read(`tickets: ${a} (x, y), ${b} (z)`)).toEqual([a, b]);
  expect(read(`tickets: [${a} (x, y, z), ${b} (w, v)]`)).toEqual([a, b]);
  expect(read(`tickets: [${a} (a]b, c)]`), "brackets inside an annotation are not interpreted").toEqual([a]);
  expect(read(`tickets: ${a} ()`)).toEqual([a]);
  expect(read(`tickets: ${a} (${"x".repeat(200)})`), "an annotation of exactly 200 characters").toEqual([a]);
  expect(read(`tickets: ${a} (see the note on Fact overlap)`)).toEqual([a]);
  expect(read(`tickets: ${a}`, `\ntickets: ${b}\n`), "a tickets: line after the front matter is not read").toEqual([a]);
  expect(shared.declaredTickets(`---\ntickets: ${a}\nother: 1\n---\n# T\n`)).toEqual([a]);
  expect(shared.declaredTickets(`---\ntitle: x\ntickets: [${a}, ${b}]\n---\n`)).toEqual([a, b]);
  expect(shared.declaredTickets(`---\ntickets: ${a}\n---`)).toEqual([a]);
  const maximum = Array.from({ length: 4096 }, (_, i) => t2Key(100000 + i));
  expect(read(`tickets: [${maximum.join(", ")}]`)).toEqual(maximum);
  expect(read(`tickets: [${[...maximum, t2Key(200000)].join(", ")}]`)).toBeNull();

  const group = await lib.buildGroupFixture(realpathSync(root()));
  expect(shared.declaredTickets(readFileSync(group.spec, "utf8")), "the real seven-key flow list").toEqual(group.keys);
  const known = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" });
  const knownKey = basename(known.spec).replace(/-fixture\.md$/, "");
  expect(readFileSync(known.spec, "utf8")).toMatch(new RegExp(`^tickets: ${knownKey} \\([^()]+\\)$`, "m"));
  expect(shared.declaredTickets(readFileSync(known.spec, "utf8")), "the real annotated scalar of a known single").toEqual([knownKey]);
  const fresh = await lib.buildFreshSingleFixture(realpathSync(root()));
  expect(shared.declaredTickets(readFileSync(fresh.spec, "utf8"))).toEqual([basename(fresh.spec).replace(/-fixture\.md$/, "")]);
}, S1B);

test("D5 declaredTickets refuses a key inside an annotation, nested or unbalanced parentheses, an over-long annotation, prose, duplicates, block lists, empty values and a second tickets: line", async () => {
  const shared = await t2Pinned();
  const [a, b] = [t2Key(9), t2Key(10)]; const read = (line: string, rest?: string) => shared.declaredTickets(t2Front(line, rest));
  const refused = (line: string) => expect(read(line), line).toBeNull();
  expect(read(`tickets: ${a}`), "control: the same reader accepts a plain key").toEqual([a]);
  refused(`tickets: ${a} (see ${b})`); refused(`tickets: ${a} (re ${a})`); refused(`tickets: [${a} (x), ${b} (also ${a})]`);
  refused(`tickets: ${a} (finding ${t2Key(3).replace("HIMMEL", "R4")})`); refused(`tickets: ${a} (x ${b} y, z)`);
  refused(`tickets: ${a} (a (b))`); refused(`tickets: ${a} ((a))`); refused(`tickets: ${a} (a (b) c)`);
  refused(`tickets: ${a} (a`); refused(`tickets: ${a} a)`); refused(`tickets: ${a} ((a)`); refused(`tickets: ${a} (a))`); refused(`tickets: ${a} )(`); refused(`tickets: [${a} (a, ${b}]`);
  refused(`tickets: ${a} (${"x".repeat(201)})`); refused(`tickets: [${a} (${"x".repeat(201)}), ${b}]`);
  refused(`tickets: see ${a}`); refused(`tickets: ${a} and ${b}`); refused(`tickets: ${a} done`); refused(`tickets: ${a} (a) more`); refused(`tickets: ${a} (a) (b)`);
  refused(`tickets: ${a} - ${b}`); refused(`tickets: ${a};${b}`); refused(`tickets: ${a} ${b}`); refused(`tickets: "${a}"`); refused(`tickets: '${a}'`);
  refused(`tickets: ${a}, ${a}`); refused(`tickets: [${a}, ${b}, ${a}]`); refused(`tickets: [${a} (x), ${a} (y)]`);
  refused("tickets:"); refused("tickets:   "); refused("tickets: []"); refused("tickets: [ ]"); refused("tickets: ,"); refused("tickets: ()");
  refused(`tickets: [${a},]`); refused(`tickets: [,${a}]`); refused(`tickets: ${a},,${b}`); refused(`tickets: ${a},`); refused(`tickets: ,${a}`);
  refused(`tickets: [${a}`); refused(`tickets: [${a}, ${b}`); refused(`tickets: ${a}]`); refused(`tickets: [[${a}]]`); refused(`tickets: [${a}] extra`); refused(`tickets: x[${a}]`);
  refused("tickets: himmel-9"); refused("tickets: HIMMEL"); refused("tickets: HIMMEL-"); refused("tickets: 9"); refused("tickets: -9"); refused(`tickets: ${a.toLowerCase()}`);
  expect(shared.declaredTickets(`---\ntickets:\n  - ${a}\n  - ${b}\n---\n# T\n`), "a block-style list").toBeNull();
  expect(shared.declaredTickets(`---\ntickets:\n- ${a}\n---\n# T\n`)).toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}\ntickets: ${b}\n---\n# T\n`), "a second tickets: line").toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}\ntickets: ${a}\n---\n# T\n`)).toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}\ntickets:\n---\n# T\n`)).toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}\n  tickets: ${b}\n---\n# T\n`), "an indented line is not a second declaration").toEqual([a]);
  expect(shared.declaredTickets(`---\ntitle: x\n---\n# T\n`), "no tickets line").toBeNull();
  expect(shared.declaredTickets(`# T\n\ntickets: ${a}\n`), "no front matter").toBeNull();
  expect(shared.declaredTickets(`\n---\ntickets: ${a}\n---\n`), "front matter not at the start").toBeNull();
  expect(shared.declaredTickets(`---\ntitle: x\n---\ntickets: ${a}\n`), "a body line is not front matter").toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}`), "an unterminated block").toBeNull();
  expect(shared.declaredTickets(""), "empty text").toBeNull();
  expect(shared.declaredTickets(`---\ntickets: ${a}\n---\n---\ntickets: ${b}\n---\n`), "only the first block is read").toEqual([a]);
});

const T2_KEYS_REFUSAL = "capped return Keys? declaration disagrees with the declared keys";
const T2_REVIEWED_REFUSAL = "capped return Reviewed declaration disagrees with the current spec";

test("D4 optionalReturnAgreement: absent and equal pass; two lines, a subset, a superset, one key of many, a wrong or a doubled Reviewed refuse, all through one function", async () => {
  const shared = await t2Pinned(); const { f } = await t2Group();
  const real = readFileSync(b1Kind(f, "spec").at(-1)!, "utf8"); const specSha = sha(readFileSync(f.spec, "utf8"));
  expect(real).not.toMatch(/^(Keys?|Reviewed):/m);
  const keys: string[] = [...f.keys]; const other = "0123456789abcdef".repeat(4);
  const run = (extra: string, expect_: { keys?: readonly string[]; specSha?: string }) => () => shared.optionalReturnAgreement(`${real}${extra}`, expect_);
  expect(run("", { keys, specSha }), "absent lines pass").not.toThrow();
  expect(run("", {}), "no part given").not.toThrow();
  expect(run("Keys: ???\nReviewed: spec nonsense\n", {}), "an ungiven part is never read").not.toThrow();

  const keyLine = (value: string) => `Keys: ${value}\n`;
  for (const line of [keyLine(keys.join(", ")), keyLine(keys.join(",")), keyLine(`[${keys.join(", ")}]`), keyLine([...keys].reverse().join(", ")), `Keys:${keys.join(",")}\n`]) expect(run(line, { keys }), line).not.toThrow();
  expect(run(keyLine(keys[0]), { keys: [keys[0]] }), "one key of one").not.toThrow();
  expect(run(`Key: ${keys[0]}\n`, { keys: [keys[0]] }), "the singular spelling").not.toThrow();
  expect(run(`Key: ${keys[0]}\n`, { keys }), "one key of many").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(keys.slice(1).join(", ")), { keys }), "a subset").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(keys.slice(0, 3).join(", ")), { keys }), "a subset").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine([...keys, t2Key(1)].join(", ")), { keys }), "a superset").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine([...keys.slice(1), t2Key(1)].join(", ")), { keys }), "wrong").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(keys.join(", ")) + keyLine(keys.join(", ")), { keys }), "two equal lines").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(keys.join(", ")) + keyLine(keys[0]), { keys }), "two lines, one equal").toThrow(T2_KEYS_REFUSAL);
  expect(run(`Key: ${keys[0]}\nKeys: ${keys.join(", ")}\n`, { keys }), "a Key line beside a Keys line").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(`${keys.join(", ")}, ${keys[0]}`), { keys }), "a doubled key in the line").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(`${keys[0]}, ${keys[0]}`), { keys: [keys[0]] })).toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(`${keys[0]}, ${keys[0]}`), { keys: keys.slice(0, 2) }), "duplicate keys with the expected item count").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(`${keys.join(", ")} and more`), { keys })).toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(`${keys[0]} (note)`), { keys: [keys[0]] }), "an annotation is not part of a return declaration").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(""), { keys })).toThrow(T2_KEYS_REFUSAL);
  expect(run("Keys:\n", { keys: [keys[0]] })).toThrow(T2_KEYS_REFUSAL);
  expect(run(`Keys:\n${keys[0]}\n`, { keys: [keys[0]] }), "a value on the next line is not the declaration").toThrow(T2_KEYS_REFUSAL);
  expect(run(`  Keys: ${keys[0]}\n`, { keys }), "an indented line is not a declaration").not.toThrow();

  const reviewed = (sha_: string) => `Reviewed: spec ${sha_}\n`;
  expect(run(reviewed(specSha), { specSha }), "equal").not.toThrow();
  expect(run(reviewed(specSha), { keys }), "the Reviewed part is untested when not given").not.toThrow();
  expect(run(reviewed(other), { specSha }), "wrong").toThrow(T2_REVIEWED_REFUSAL);
  expect(run(reviewed(specSha) + reviewed(specSha), { specSha }), "doubled").toThrow(T2_REVIEWED_REFUSAL);
  expect(run(reviewed(specSha) + reviewed(other), { specSha }), "doubled, one wrong").toThrow(T2_REVIEWED_REFUSAL);
  expect(run(reviewed(other) + reviewed(specSha), { specSha })).toThrow(T2_REVIEWED_REFUSAL);
  expect(run(`Reviewed: spec ${specSha}, plan ${other}\n`, { specSha }), "the paired declaration format").not.toThrow();
  expect(run(`Reviewed:\tspec\t${specSha}\r\n`, { specSha }), "horizontal spacing and CRLF").not.toThrow();
  for (const line of [`Reviewed: spec ${other.toUpperCase()}\n`, `Reviewed: spec ${specSha.slice(1)}\n`,
    `Reviewed: spec ${specSha}a\n`, `Reviewed: spec ${specSha}suffix\n`, `Reviewed: spec sha256 ${specSha}\n`,
    "Reviewed: spec\n", `Reviewed: spec ${specSha}, plan invalid\n`]) {
    expect(run(line, { specSha }), line).toThrow(T2_REVIEWED_REFUSAL);
    expect(run(reviewed(specSha) + line, { specSha }), "a second malformed declaration").toThrow(T2_REVIEWED_REFUSAL);
  }

  expect(run(keyLine(keys.join(", ")) + reviewed(specSha), { keys, specSha }), "both given, both equal").not.toThrow();
  expect(run(keyLine(keys[0]) + reviewed(specSha), { keys, specSha }), "keys wrong").toThrow(T2_KEYS_REFUSAL);
  expect(run(keyLine(keys.join(", ")) + reviewed(other), { keys, specSha }), "reviewed wrong").toThrow(T2_REVIEWED_REFUSAL);
  expect(run(keyLine(keys[0]) + reviewed(other), { keys, specSha }), "the declaration fires first when both are wrong").toThrow(T2_KEYS_REFUSAL);
  expect(run(reviewed(other), { keys, specSha })).toThrow(T2_REVIEWED_REFUSAL);
}, S1B);

// ---- Task 3a step 0: boundary rows the Task2 review named, green against the unchanged Task2 product code ----
const T2_WRONG = "0123456789abcdef".repeat(4);

test("D4b optionalReturnAgreement: a wrong hash on a non-declaration form passes as absent, while the same hash on a real declaration refuses", async () => {
  const shared = await t2Pinned(); const { f } = await t2Group();
  const real = readFileSync(b1Kind(f, "spec").at(-1)!, "utf8"); const specSha = sha(readFileSync(f.spec, "utf8"));
  expect(real).not.toMatch(/^(Keys?|Reviewed):/m);
  const agree = (extra: string) => () => shared.optionalReturnAgreement(`${real}${extra}`, { specSha });
  const nonDeclarations: [string, string][] = [
    ["indented by spaces", `  Reviewed: spec ${T2_WRONG}\n`], ["indented by a tab", `\tReviewed: spec ${T2_WRONG}\n`],
    ["lowercase reviewed", `reviewed: spec ${T2_WRONG}\n`], ["Reviewed: plan", `Reviewed: plan ${T2_WRONG}\n`],
    ["Reviewed: specs", `Reviewed: specs ${T2_WRONG}\n`],
  ];
  for (const [name, line] of nonDeclarations) {
    expect(agree(line), `${name} is not a declaration of the spec part`).not.toThrow();
    expect(agree(`Reviewed: spec ${specSha}\n${line}`), `${name} beside one valid declaration`).not.toThrow();
    expect(agree(`${line}Reviewed: spec ${T2_WRONG}\n`), `${name} never hides a real wrong declaration`).toThrow(T2_REVIEWED_REFUSAL);
  }
  expect(agree(`Reviewed: spec ${T2_WRONG}\n`), "control: the same hash on a column-zero declaration refuses").toThrow(T2_REVIEWED_REFUSAL);
}, S1B);

test("D4c optionalReturnAgreement: a tab before spec with a wrong hash and an uppercase paired plan hash both refuse", async () => {
  const shared = await t2Pinned(); const { f } = await t2Group();
  const real = readFileSync(b1Kind(f, "spec").at(-1)!, "utf8"); const specSha = sha(readFileSync(f.spec, "utf8"));
  const agree = (extra: string) => () => shared.optionalReturnAgreement(`${real}${extra}`, { specSha });
  expect(agree(`Reviewed:\tspec\t${specSha}\n`), "control: the tab form with the equal hash is a valid declaration").not.toThrow();
  for (const line of [`Reviewed:\tspec\t${T2_WRONG}\n`, `Reviewed:\tspec ${T2_WRONG}\n`, `Reviewed: spec\t${T2_WRONG}\n`, `Reviewed:\tspec\t${T2_WRONG}\r\n`]) {
    expect(agree(line), JSON.stringify(line)).toThrow(T2_REVIEWED_REFUSAL);
  }
  expect(agree(`Reviewed: spec ${specSha}, plan ${T2_WRONG}\n`), "control: a lowercase paired plan hash is valid").not.toThrow();
  for (const plan of [T2_WRONG.toUpperCase(), `${T2_WRONG.slice(0, 63)}F`, T2_WRONG.slice(1), `${T2_WRONG}a`]) {
    expect(agree(`Reviewed: spec ${specSha}, plan ${plan}\n`), `paired plan ${plan.length} chars`).toThrow(T2_REVIEWED_REFUSAL);
  }
}, S1B);

test("S3b v2 shape: a malformed return_sha refuses on the spec return and on the plan return when its carried value matches", async () => {
  const shared = await t2Pinned(); const { good } = await t2Group();
  const refuse = (value: unknown) => expect(() => shared.validateCappedLedgerProofShape(value)).toThrow(T2_INVALID);
  expect(shared.validateCappedLedgerProofShape(good), "control: the unmodified proof is valid").toEqual(good);
  expect(good.returns.map((r: any) => r.kind)).toEqual(["spec", "plan"]);
  expect(good.carried.map((c: any) => c.kind)).toEqual(["spec", "plan"]);
  for (const index of [0, 1]) for (const bad of ["x", "A".repeat(64), "a".repeat(63), "a".repeat(65), ""]) {
    refuse(t2Clone(good, p => { p.returns[index].return_sha = bad; p.carried[index].return_sha = bad; }));
  }
}, S1B);

// ---- Task 3a, rows P1 to P3: the strict v1 `capped-fold --key` verifier through its real CLI ----
// A permanent static contract, written green against the unchanged verifier and kept green by the extraction. Every refusal is its exact shipped
// stderr line and exit code; every success is the whole proof computed from the fixture's own files (paths, sha256, return_sha, decision mtime).
// The verifier prefixes `capped-fold: ` to a message that already starts with it, so a shipped refusal reads `capped-fold: capped-fold: ...`.
const P1_ROUTE = join(import.meta.dir, "chief-route.ts");
type P1Args = { key: string; spec: string; plan: string; specReturn: string; planReturn: string };
type P1Run = { code: number | null; signal: string | null; out: string; err: string };
const p1Flags = (a: P1Args) => ["--key", a.key, "--spec", a.spec, "--plan", a.plan, "--spec-return", a.specReturn, "--plan-return", a.planReturn];
const p1Cli = (...argv: string[]): P1Run => {
  const p = Bun.spawnSync(["bun", P1_ROUTE, "capped-fold", ...argv], { stdout: "pipe", stderr: "pipe", timeout: 60_000 });
  return { code: p.exitCode, signal: p.signalCode ?? null, out: p.stdout.toString(), err: p.stderr.toString() };
};
const p1Fold = (a: P1Args) => p1Cli(...p1Flags(a));
const p1Line = (message: string) => `capped-fold: ${message}\n`;
type P1Fixture = { ledgerPath: string; spec: string; plan: string };
type P1Want = { epoch?: number; rounds: [number, number]; residuals: [number, number]; carried: [kind: "spec" | "plan", id: string, severity: string, round: number][]; decision?: string };

// The pins the verifier must hold, in the order it first reads them: both documents, the manifest and ledger, then per return the return,
// each distinct sealed artifact and its content-addressed snapshot. Every sha256 is read from the actual file.
const p1Pins = (f: P1Fixture, a: P1Args) => {
  const ledgerDir = dirname(f.ledgerPath); const pins: { role: string; path: string; sha256: string }[] = []; const seen = new Set<string>();
  const add = (role: string, path: string) => { if (!seen.has(path)) { seen.add(path); pins.push({ role, path, sha256: sha(readFileSync(path, "utf8")) }); } };
  add("artifact", a.spec); add("artifact", a.plan); add("manifest", join(ledgerDir, "manifest.json")); add("ledger", f.ledgerPath);
  for (const ret of [a.specReturn, a.planReturn]) {
    add("return", ret);
    for (const m of readFileSync(ret, "utf8").matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (\S.*)$/gm)) {
      const artifact = resolve(dirname(ret), m[1]); add("artifact", artifact); add("snapshot", join(ledgerDir, a.key, sha(readFileSync(artifact, "utf8"))));
    }
  }
  return pins;
};

const p1Success = async (id: string, f: P1Fixture, a: P1Args, want: P1Want, run: P1Run = p1Fold(a)): Promise<string[]> => {
  const { returnSha } = await import("./chief-route") as any;
  const problems: string[] = [];
  if (run.code !== 0 || run.signal !== null || run.err !== "") problems.push(`rc ${run.code} signal ${run.signal} stderr ${JSON.stringify(run.err)}`);
  let proof: any;
  try { proof = JSON.parse(run.out); } catch { return [`${id}: ${problems.join("; ")} stdout is not JSON: ${JSON.stringify(run.out.slice(0, 300))}`]; }
  if (run.out !== `${JSON.stringify(proof)}\n`) problems.push("stdout is not exactly one JSON line");
  const text = (p: string) => readFileSync(p, "utf8"); const file = (path: string) => ({ path, sha256: sha(text(path)) });
  const returns = [a.specReturn, a.planReturn].map((path, i) => ({ kind: i === 0 ? "spec" : "plan", ...file(path), round: want.rounds[i], return_sha: returnSha(text(path)), residuals: want.residuals[i] }));
  const carried = want.carried.map(([kind, finding_id, severity, round]) => { const r = returns[kind === "spec" ? 0 : 1];
    return { key: a.key, epoch: want.epoch ?? 0, kind, round, return_path: r.path, return_sha: r.return_sha, finding_id, severity, status: "open-carried" }; });
  const expected = { schema: 1, reader_version: 1, mode: "capped-carry", key: a.key, epoch: want.epoch ?? 0, spec: file(a.spec), plan: file(a.plan), returns, pins: p1Pins(f, a), carried };
  let seen = proof;
  if (want.decision) {
    const decision = proof.pins.filter((p: any) => p.role === "decision" || p.role === "decision-selection");
    const path = want.decision; const st = statSync(path);
    const wantDecision = [{ role: "decision", ...file(path), mtime_ms: st.mtimeMs }, { role: "decision-selection", directory: dirname(path), decision: "990", names: [basename(path)] }];
    if (JSON.stringify([...decision].sort((x: any, y: any) => x.role.localeCompare(y.role))) !== JSON.stringify(wantDecision)) problems.push(`decision pins differ: ${JSON.stringify(decision)}`);
    seen = { ...proof, pins: proof.pins.filter((p: any) => p.role !== "decision" && p.role !== "decision-selection") };
  }
  if (JSON.stringify(seen) !== JSON.stringify(expected)) problems.push(`proof differs\n    want ${JSON.stringify(expected)}\n    got  ${JSON.stringify(seen)}`);
  return problems.map(p => `${id}: ${p}`);
};

const p1Cases = () => {
  const bad: string[] = []; const ids: string[] = [];
  const refuses = (id: string, a: P1Args, message: string) => {
    ids.push(id); const run = p1Fold(a); const want = { code: 1, signal: null, out: "", err: p1Line(message) };
    if (JSON.stringify(run) !== JSON.stringify(want)) bad.push(`${id}\n  want ${JSON.stringify(want)}\n  got  ${JSON.stringify(run)}`);
  };
  const accepts = async (id: string, f: P1Fixture, a: P1Args, want: P1Want) => { ids.push(id); bad.push(...await p1Success(id, f, a, want)); };
  return { bad, ids, refuses, accepts };
};
const P1_DECLARED = `capped-fold: header must declare only ${cappedKey}`;
const P1_RETURN = `capped-fold: return must declare only ${cappedKey}`;
const P1_ONE_CARRIED: P1Want = { rounds: [5, 5], residuals: [1, 0], carried: [["spec", "F1", "minor", 5]] };

test("P1 newer returns in every supplied directory: round 5 is accepted, then a copied round 6 is refused as unaccounted", async () => {
  const c = p1Cases();
  for (const location of ["spec", "plan", "plan-document"] as const) {
    const f = await finishCappedRounds(location === "plan-document" ? { externalPlan: true } : { externalReturn: location });
    await c.accepts(`newer/${location}/r5`, f, f.args, P1_ONE_CARRIED);
    const current = location === "spec" ? f.args.specReturn : f.args.planReturn;
    const copy = join(dirname(location === "plan-document" ? f.plan : current), basename(current).replace("r5.md", "r6.md"));
    copyFileSync(current, copy);
    c.refuses(`newer/${location}/r6`, f.args, `capped-fold: ambiguous or unaccounted latest return: ${copy}`);
  }
  expect(c.ids).toHaveLength(6); expect(c.bad).toEqual([]);
}, S1B);

test("P1 return selection preserves older and other-key eligibility: three accepted states of one fixture", async () => {
  const c = p1Cases(); const f = await cappedFixture();
  await c.accepts("eligibility/plain", f, f.args, P1_ONE_CARRIED);
  const directory = join(f.specsRoot, "design");
  writeFileSync(directory, "optional non-directory lookup");
  await c.accepts("eligibility/non-directory-lookup", f, f.args, P1_ONE_CARRIED);
  unlinkSync(directory); mkdirSync(directory);
  for (const name of ["HIMMEL-10205-other.md.critic-spec-r2.md", "HIMMEL-10205-other.md.critic-r2-plan.md", "HIMMEL-10205-other.md.critic-r2a.md",
    "HIMMEL-99999-other.md.critic-spec-r99.md", "irrelevant.txt"]) copyFileSync(f.args.specReturn, join(directory, name));
  await c.accepts("eligibility/older-and-other-key", f, f.args, P1_ONE_CARRIED);
  expect(c.ids).toHaveLength(3); expect(c.bad).toEqual([]);
}, S1B);

test("P1 return selection refuses a tied name in every supported grammar, after the same fixture is accepted", async () => {
  const c = p1Cases();
  for (const filename of ["HIMMEL-10205-other.md.critic-spec-r5.md", "HIMMEL-10205-other.md.critic-r5-plan.md", "HIMMEL-10205-other.md.critic-r5a.md"]) {
    const f = await cappedFixture();
    await c.accepts(`tied/${filename}/before`, f, f.args, P1_ONE_CARRIED);
    const copy = join(dirname(f.spec), filename); copyFileSync(f.args.specReturn, copy);
    c.refuses(`tied/${filename}/after`, f.args, `capped-fold: ambiguous or unaccounted latest return: ${copy}`);
  }
  expect(c.ids).toHaveLength(6); expect(c.bad).toEqual([]);
}, S1B);

test("P1 return selection refuses an aliased, an unreadable and an unbounded directory", async () => {
  const c = p1Cases();
  for (const fault of ["alias", "unreadable", "overflow"]) {
    const f = await cappedFixture(); await c.accepts(`directory/${fault}/before`, f, f.args, P1_ONE_CARRIED);
    const directory = join(f.specsRoot, "design");
    if (fault === "alias") { const target = join(f.r, "target"); mkdirSync(target); symlinkSync(target, directory); }
    else mkdirSync(directory);
    if (fault === "unreadable") chmodSync(directory, 0);
    if (fault === "overflow") for (let i = 0; i < 4097; i++) writeFileSync(join(directory, `irrelevant-${i}`), "");
    const message = { alias: `capped-fold: directory lookup must be canonical: ${directory}`, unreadable: `EACCES: permission denied, scandir '${directory}'`,
      overflow: `${directory}: directory entry limit (4096) exceeded` }[fault]!;
    try { c.refuses(`directory/${fault}/after`, f.args, message); } finally { if (fault === "unreadable") chmodSync(directory, 0o700); }
  }
  expect(c.ids).toHaveLength(6); expect(c.bad).toEqual([]);
}, S1B);

test("P1 Key declarations in real sealed returns: a Ticket line in the documents is accepted, a Ticket line in a return is no Key line and the ledger binds the key", async () => {
  const c = p1Cases();
  const finished = await finishCappedRounds(); await c.accepts("declarations/finished", finished, finished.args, P1_ONE_CARRIED);
  const documents = await cappedFixture({
    specText: fixtureSpecText.replace("# HIMMEL", `- Ticket: ${cappedKey}\n\n# HIMMEL`),
    planText: `---\ntickets: ${cappedKey}\n---\n- Tickets: ${cappedKey}\n${fixturePlanText}`,
  });
  await c.accepts("declarations/ticket-lines-in-documents", documents, documents.args, P1_ONE_CARRIED);
  for (const kind of ["spec", "plan"] as const) {
    const f = await finishCappedRounds({ ticketReturn: kind });
    const path = kind === "spec" ? f.args.specReturn : f.args.planReturn;
    expect([...readFileSync(path, "utf8").matchAll(/^Keys?:\s*(.+)$/gm)]).toHaveLength(0);
    await c.accepts(`declarations/ticket-line-in-${kind}-return`, f, f.args, P1_ONE_CARRIED);
  }
  expect(c.ids).toHaveLength(4); expect(c.bad).toEqual([]);
}, S1B);

test("P1 exact evidence: the whole proof of the standard, the two-finding and the ten-finding fixture, and the tree is unchanged", async () => {
  const c = p1Cases();
  const f = await cappedFixture(); const before = treeBytes(f.r);
  await c.accepts("evidence/standard", f, f.args, P1_ONE_CARRIED);
  expect(treeBytes(f.r)).toEqual(before);
  const both = await cappedFixture({ planFindings: "- **F1** (medium) independent PLAN finding" });
  await c.accepts("evidence/spec-and-plan-finding", both, both.args, { rounds: [5, 5], residuals: [1, 1], carried: [["spec", "F1", "minor", 5], ["plan", "F1", "medium", 5]] });
  const controls = await cappedFixture({ status: true, specFindings: Array.from({ length: 10 }, (_, i) => `- **F${i}** (minor) true heading`).join("\n") });
  await c.accepts("evidence/ten-findings-with-status-prose", controls, controls.args,
    { rounds: [5, 5], residuals: [10, 0], carried: Array.from({ length: 10 }, (_, i) => ["spec", `F${i}`, "minor", 5] as ["spec", string, string, number]) });
  expect(c.ids).toHaveLength(3); expect(c.bad).toEqual([]);
}, S1B);

test("P1 READ quotes: the standard and the short READ spelling are accepted; a malformed, a conflicting and a duplicate quote are refused", async () => {
  const c = p1Cases();
  const standard = await finishCappedRounds();
  expect(readFileSync(standard.args.specReturn, "utf8")).toContain(`READ-SHA256 ${sha(readFileSync(standard.spec, "utf8"))} ${standard.spec}`);
  await c.accepts("quotes/standard", standard, standard.args, P1_ONE_CARRIED);
  const short = await finishCappedRounds({ shortRead: true }); await c.accepts("quotes/short-read-spelling", short, short.args, P1_ONE_CARRIED);
  for (const fault of ["malformed", "conflicting", "duplicate"]) {
    const f = await finishCappedRounds();
    await editCappedReturn(f, f.args.specReturn, text => {
      if (fault === "malformed") return text.replace("SPEC FINDINGS 1", "READ-SHA256 unknown file.md\nSPEC FINDINGS 1");
      if (fault === "conflicting") return text.replace(/^READ-SHA256 [0-9a-f]{64}/m, `READ-SHA256 ${"0".repeat(64)}`);
      const line = /^READ-SHA256 .+$/m.exec(text)![0];
      return text.replace("SPEC FINDINGS 1", `${line.replace("READ-SHA256", "READ")}\nSPEC FINDINGS 1`);
    });
    c.refuses(`quotes/${fault}`, f.args, { malformed: "capped-fold: malformed seal or READ quote", duplicate: "capped-fold: duplicate critic READ quotes",
      conflicting: `capped-fold: missing/conflicting critic READ quote: ${f.spec}` }[fault]!);
  }
  expect(c.ids).toHaveLength(5); expect(c.bad).toEqual([]);
}, S1B);

test("P1 noneligible evidence: eighteen ineligible finding sets and corrupted ledger rows, each with its own shipped refusal", async () => {
  const c = p1Cases();
  const control = await cappedFixture(); await c.accepts("noneligible/control", control, control.args, P1_ONE_CARRIED);
  const heading = (line: string) => `capped-fold: ineligible finding heading: ${line}`;
  const OPEN_CRITICAL = "capped-fold: open historical operator-critical findings"; const DISAGREE = "capped-fold: finding count/IDs do not agree";
  const cases: [string, Parameters<typeof cappedFixture>[0], string][] = [
    ["rounds-2", { rounds: 2 }, "capped-fold: findings have not reached the refused round cap"],
    ["clean-spec", { specFindings: "" }, "capped-fold: requires at least one carried finding"],
    ["major", { specFindings: "- **F1** (major) blocking" }, heading("- **F1** (major) blocking")],
    ["unrated", { specFindings: "- **F1** (unrated) unknown" }, heading("- **F1** (unrated) unknown")],
    ["duplicate-id", { specFindings: "- **F1** (minor) first\n- **F1** (medium) duplicate" }, DISAGREE],
    ...["unknown", "operator-critical: spend-grant", "operator-critical: imaginary", "reopens F0", "regression", ""].map(tag =>
      [`tag-${tag || "empty"}`, { specFindings: `- **F1** (minor; ${tag}) blocked tag` }, tag === "operator-critical: spend-grant" ? OPEN_CRITICAL : heading(`- **F1** (minor; ${tag}) blocked tag`)] as [string, Parameters<typeof cappedFixture>[0], string]),
    ["nested-malformed-candidate", { specFindings: "- **F1** (minor) valid\n  - **Bad** (unknown) malformed candidate" }, heading("  - **Bad** (unknown) malformed candidate")],
    ["historical-operator-critical", { historical: "- **C1** (minor; operator-critical: spend-grant) historically open" }, OPEN_CRITICAL],
  ];
  for (const [name, options, message] of cases) { const f = await cappedFixture(options); c.refuses(`noneligible/${name}`, f.args, message); }
  const { returnSha } = await import("./chief-route");
  for (const corrupt of ["count", "ledger-count", "ledger-tag", "unrated", "closure"]) {
    const f = await cappedFixture();
    editLedger(f, rows => {
      const row = rows.find(r => r.row === "round" && r.critic === "spec" && r.round === 5);
      if (corrupt === "ledger-count") row.findings = [];
      if (corrupt === "ledger-tag") row.findings[0].critical_refused = "other";
      if (corrupt === "unrated") row.unrated_ids = ["spec-r5-U1"];
      if (corrupt === "closure") row.findings[0].class = "regression";
      if (corrupt === "count") {
        const text = readFileSync(f.args.specReturn, "utf8").replace("SPEC FINDINGS 1", "SPEC FINDINGS 2");
        const old = row.return_sha; row.return_sha = returnSha(text); row.verdict = "SPEC FINDINGS 2";
        rows.filter(r => r.return_sha === old).forEach(r => { r.return_sha = row.return_sha; }); writeFileSync(f.args.specReturn, text);
      }
    });
    c.refuses(`noneligible/corrupt-${corrupt}`, f.args, { count: DISAGREE, "ledger-count": DISAGREE, unrated: DISAGREE,
      "ledger-tag": "capped-fold: ledger findings do not agree or are blocking", closure: "capped-fold: ledger findings do not agree or are blocking" }[corrupt]!);
  }
  expect(c.ids).toHaveLength(1 + 13 + 5); expect(c.bad).toEqual([]);
}, S1B);

const P1_DRIFT = ["key", "epoch", "old", "copy", "higher", "tied", "quote", "reviewed", "plan-reviewed", "seal", "extra-seal", "snapshot", "spec", "plan", "page", "estimate", "ledger", "manifest", "seed", "header", "frontmatter"];
test("P1 provenance drift: twenty-one single faults of the recorded evidence, each with its own shipped refusal", async () => {
  const c = p1Cases();
  const control = await cappedFixture(); await c.accepts("drift/control", control, control.args, P1_ONE_CARRIED);
  for (const fault of P1_DRIFT) {
    const f = await cappedFixture();
    if (fault === "key") editLedger(f, rows => { rows[0].key = "HIMMEL-99"; });
    if (fault === "epoch") editLedger(f, rows => { rows.find(r => r.row === "round" && r.round === 5).epoch = 7; });
    if (fault === "old") f.args.specReturn = f.verdicts[0];
    if (fault === "copy") { const p = join(f.r, basename(f.args.specReturn)); copyFileSync(f.args.specReturn, p); f.args.specReturn = p; }
    if (fault === "higher" || fault === "tied") copyFileSync(f.args.planReturn, fault === "higher" ? f.args.planReturn.replace("r5.md", "r6.md") : join(dirname(f.plan), basename(f.args.planReturn)));
    if (["quote", "reviewed", "plan-reviewed", "seal"].includes(fault)) {
      const p = fault === "plan-reviewed" ? f.args.planReturn : f.args.specReturn;
      await editCappedReturn(f, p, text => text.replace(fault === "quote" ? /^READ(?:-SHA256)? .*\n/m : fault === "seal" ? /^CONTENT-SHA256 .*\n/m : /^Reviewed: .*\n/m, ""));
    }
    if (fault === "extra-seal") editLedger(f, rows => { rows.push({ ...rows.at(-1), read_path: f.spec, read_sha: "f".repeat(64) }); });
    if (fault === "snapshot") writeFileSync(join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec, "utf8"))), "edited");
    const p = ({ spec: f.spec, plan: f.plan, page: join(dirname(f.spec), "page.html"), estimate: join(dirname(f.spec), "estimate.json"), ledger: f.ledgerPath, manifest: join(dirname(f.ledgerPath), "manifest.json") } as Record<string,string>)[fault];
    if (p) appendFileSync(p, "changed");
    if (fault === "seed") editLedger(f, rows => { rows.splice(0, rows.length, { row: "seed", key: cappedKey, spec: 5, plan: 5, latest: { spec: [], plan: [] } }); });
    if (fault === "header") writeFileSync(f.spec, readFileSync(f.spec, "utf8").replace(`Key: ${cappedKey}`, "Key: HIMMEL-99"));
    if (fault === "frontmatter") writeFileSync(f.plan, readFileSync(f.plan, "utf8").replace(`tickets: ${cappedKey}`, `tickets: [${cappedKey}, HIMMEL-99]`));
    const latest = "capped-fold: not the actual latest real spec round"; const reviewed = (kind: string) => `capped-fold: ${kind} must review the current spec exactly once`;
    const coverage = "capped-fold: missing/extra ledger seals or review coverage"; const provenance = (path: string) => `capped-fold: seal provenance disagrees: ${path}`;
    const manifest = join(dirname(f.ledgerPath), "manifest.json");
    const message: Record<string, string> = {
      key: "capped-fold: invalid ledger key/record", epoch: "capped-fold: invalid ledger epoch", old: latest, copy: latest, seed: latest,
      higher: `capped-fold: ambiguous or unaccounted latest return: ${f.args.planReturn.replace("r5.md", "r6.md")}`,
      tied: `capped-fold: ambiguous or unaccounted latest return: ${join(dirname(f.plan), basename(f.args.planReturn))}`,
      quote: `capped-fold: missing/conflicting critic READ quote: ${f.spec}`, reviewed: reviewed("spec"), "plan-reviewed": reviewed("plan"), spec: reviewed("spec"),
      seal: coverage, "extra-seal": coverage, snapshot: "capped-fold: content-addressed snapshot changed",
      plan: provenance(f.plan), page: provenance(join(dirname(f.spec), "page.html")), estimate: provenance(join(dirname(f.spec), "estimate.json")),
      ledger: `${cappedKey} ledger line ${readFileSync(f.ledgerPath, "utf8").split("\n").filter(Boolean).length} does not parse; restore it from the state repo history`,
      manifest: `${manifest}: the round manifest does not parse; restore it from the state repo history`,
      header: P1_DECLARED, frontmatter: `capped-fold: tickets must declare only ${cappedKey}`,
    };
    c.refuses(`drift/${fault}`, f.args, message[fault]);
  }
  expect(c.ids).toHaveLength(1 + P1_DRIFT.length); expect(c.bad).toEqual([]);
}, S1B);

test("P1 recording checkout bound: a copied tree and a removed original are each refused", async () => {
  const c = p1Cases();
  const f = await cappedFixture(); await c.accepts("checkout/original", f, f.args, P1_ONE_CARRIED);
  const dest = join(root(), "copy"); cpSync(f.r, dest, { recursive: true });
  const args = Object.fromEntries(Object.entries(f.args).map(([k, v]) => [k, k === "key" ? v : v.replace(f.r, dest)])) as typeof f.args;
  c.refuses("checkout/copied-tree", args, "capped-fold: not the actual latest real spec round");
  rmSync(f.r, { recursive: true });
  c.refuses("checkout/original-removed", args, "capped-fold: not the actual latest real spec round");
  expect(c.ids).toHaveLength(3); expect(c.bad).toEqual([]);
}, S1B);

test("P1 strict declarations and complete seal grammar: four malformed headers and five malformed returns", async () => {
  const c = p1Cases();
  for (const fault of ["bracket", "missing-key", "unknown-key", "duplicate-key"]) {
    const text = `---\ntickets: ${fault === "bracket" ? "[" : ""}${cappedKey}${fault === "missing-key" ? ` (Relates: HIMMEL-99)` : ""}\n---\nKey: ${fault === "unknown-key" ? "HIMMEL-99" : cappedKey}\n${fault === "duplicate-key" ? `Key: ${cappedKey}\n` : ""}## Body\n`;
    const f = await cappedFixture({ specText: fault === "missing-key" ? text.replace(`Key: ${cappedKey}\n`, "") : text });
    c.refuses(`grammar/header-${fault}`, f.args, fault === "bracket" || fault === "missing-key" ? `capped-fold: tickets must declare only ${cappedKey}` : P1_DECLARED);
  }
  for (const fault of ["extra-read", "bad-read", "bad-seal", "huge-count", "body-key"]) {
    const f = await cappedFixture();
    await editCappedReturn(f, f.args.specReturn, text => fault === "body-key" ? text.replace("SPEC FINDINGS 1", "## Body\nKey: HIMMEL-99\nSPEC FINDINGS 1") : fault === "huge-count" ? text.replace("SPEC FINDINGS 1", "SPEC FINDINGS 999999999")
      : text.replace("SPEC FINDINGS 1", `${fault === "extra-read" ? `READ ${"a".repeat(64)} alien.md` : fault === "bad-read" ? "READ unknown spec.md" : "CONTENT-SHA256 unknown spec.md"}\nSPEC FINDINGS 1`));
    c.refuses(`grammar/return-${fault}`, f.args, { "extra-read": `ENOENT: no such file or directory, realpath '${join(dirname(f.spec), "alien.md")}'`,
      "bad-read": "capped-fold: malformed seal or READ quote", "bad-seal": "capped-fold: malformed seal or READ quote",
      "huge-count": "capped-fold: invalid finding count", "body-key": P1_RETURN }[fault]!);
  }
  expect(c.ids).toHaveLength(9); expect(c.bad).toEqual([]);
}, S1B);

test("P1 higher ticket returns in every supported folder and name are refused", async () => {
  const c = p1Cases();
  for (const filename of [`${cappedKey}-other.md.critic-spec-r6.md`, `${cappedKey}-fixture.md.critic-r6-spec.md`, `${cappedKey}-fixture.md.critic-r6.md`]) {
    const f = await cappedFixture(); const copy = join(dirname(f.spec), filename); copyFileSync(f.args.specReturn, copy);
    c.refuses(`higher/${filename}`, f.args, `capped-fold: ambiguous or unaccounted latest return: ${copy}`);
  }
  const f = await cappedFixture(); const dir = join(f.specsRoot, "design"); mkdirSync(dir);
  const copy = join(dir, basename(f.args.specReturn).replace("r5", "r6")); copyFileSync(f.args.specReturn, copy);
  c.refuses("higher/design-folder", f.args, `capped-fold: ambiguous or unaccounted latest return: ${copy}`);
  expect(c.ids).toHaveLength(4); expect(c.bad).toEqual([]);
}, S1B);

test("P1 initially aliased evidence locations: nine roles and an aliased spec, each accepted before the alias and refused after", async () => {
  const c = p1Cases();
  for (const role of ["spec", "plan", "return", "ledger", "manifest", "snapshot", "page", "decision", "decision-directory"]) {
    const f = role.startsWith("decision") ? await resetCappedFixture() : await cappedFixture();
    const reset = role.startsWith("decision");
    await c.accepts(`aliased/${role}/before`, f, f.args, reset ? { epoch: 1, rounds: [5, 5], residuals: [1, 0], carried: [["spec", "F1", "minor", 5]], decision: (f as any).decision } : P1_ONE_CARRIED);
    const paths: Record<string,string> = { spec: f.spec, plan: f.plan, return: f.args.specReturn, ledger: f.ledgerPath,
      manifest: join(dirname(f.ledgerPath), "manifest.json"), snapshot: join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec, "utf8"))),
      page: join(dirname(f.spec), "page.html"), decision: join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt"), "decision-directory": join(f.specsRoot, "decisions") };
    const path = paths[role]; const target = join(f.r, "aliased-location"); renameSync(path, target); symlinkSync(target, path);
    const canonical = `capped-fold: evidence lookup must be canonical: ${path}`;
    c.refuses(`aliased/${role}/after`, f.args, {
      spec: "capped-fold: spec filename/folder key disagrees", plan: canonical, return: canonical, snapshot: canonical, page: canonical, decision: canonical,
      "decision-directory": `capped-fold: directory lookup must be canonical: ${path}`,
      ledger: `${cappedKey} ledger cannot be read (${canonical}); restore it from the state repo history`,
      manifest: `${path}: cannot read the round manifest (${canonical}); restore it from the state repo history`,
    }[role]!);
  }
  const f = await cappedFixture(); const alias = join(f.r, "spec-alias.md"); symlinkSync(f.spec, alias);
  c.refuses("aliased/spec-argument", { ...f.args, spec: alias }, `capped-fold: evidence lookup must be canonical: ${alias}`);
  expect(c.ids).toHaveLength(9 * 2 + 1); expect(c.bad).toEqual([]);
}, S1B);

test("P1 invalid ledger metadata outside the latest row: four faults, each accepted before and refused after", async () => {
  const c = p1Cases();
  for (const fault of ["seal-epoch", "mode", "late-seed", "full-closure-class"]) {
    const f = await cappedFixture(); await c.accepts(`metadata/${fault}/before`, f, f.args, P1_ONE_CARRIED);
    editLedger(f, rows => {
      if (fault === "seal-epoch") rows.find(row => row.row === "seal").epoch = 8;
      if (fault === "mode") rows.find(row => row.row === "round").mode = "invented";
      if (fault === "late-seed") rows.push({ key: cappedKey, row: "seed", spec: 0, plan: 0, latest: { spec: [], plan: [] } });
      if (fault === "full-closure-class") rows.find(row => row.row === "round" && row.round === 5 && row.critic === "spec").findings[0].class = "out-of-closure";
    });
    c.refuses(`metadata/${fault}/after`, f.args, { "seal-epoch": "capped-fold: invalid ledger epoch", mode: "capped-fold: invalid round epoch/order/mode",
      "late-seed": "capped-fold: seed must be the first ledger record", "full-closure-class": "capped-fold: ledger findings do not agree or are blocking" }[fault]!);
  }
  expect(c.ids).toHaveLength(8); expect(c.bad).toEqual([]);
}, S1B);

test("P1 evidence roles are pinned by use: a page named like a return is an artifact pin", async () => {
  const c = p1Cases();
  const f = await cappedFixture({ pageName: "memo.critic-spec-r1.md" });
  await c.accepts("roles/page-named-like-a-return", f, f.args, P1_ONE_CARRIED);
  const proof = JSON.parse(p1Fold(f.args).out);
  expect(proof.pins.find((pin: any) => pin.path === join(dirname(f.spec), "memo.critic-spec-r1.md")).role).toBe("artifact");
  expect(c.ids).toHaveLength(1); expect(c.bad).toEqual([]);
}, S1B);

test("P1 a closure round opened by a valid operator extension is accepted with its decision pins, and refused once the extension row is invalid", async () => {
  const c = p1Cases();
  const f = await cappedFixture({ specFindings: "- **M2** (major) blocking at the cap" }); const { sealRound } = await import("./chief-route");
  const nextSpec = async (round: number, ...body: string[]) => {
    const previous = f.args.specReturn; const lines = readFileSync(previous, "utf8").split("\n");
    const header = lines.slice(0, lines.findLastIndex(l => l.startsWith("READ-SHA256 ")) + 1).map(l => l.replace(/^Fixture: spec round \d+$/, `Fixture: spec round ${round}`));
    const next = previous.replace(/r\d+\.md$/, `r${round}.md`);
    const seals = lines.filter(l => l.startsWith("CONTENT-SHA256 "));
    writeFileSync(next, [...header, markerFor(f.specsRoot, cappedKey, "spec", round), ...body, ...seals, `SPEC FINDINGS ${body.filter(l => l.startsWith("- **")).length}`, ""].join("\n"));
    for (const s of seals) await sealRound(next, resolve(dirname(next), s.split(" ").slice(2).join(" ")));
    f.args.specReturn = next;
  };
  const run = (...args: string[]) => verb(true, ...args, "--specs", f.specsRoot);
  await nextSpec(6, "- **F3** (major; reopens M2) the blocking finding survives");
  expect((await run("round-override", cappedKey, "--findings", "F3", "--why", "a second closure", "--chief", "chief-x")).err).toBe("");
  await nextSpec(7, "- **F3** (major; reopens F3) still survives");
  const quote = "approve one closure round for the surviving finding"; const decision = join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt");
  mkdirSync(dirname(decision), { recursive: true }); writeFileSync(decision, `${cappedKey} ${quote}\n`); utimesSync(decision, new Date(), new Date(Date.now() + 5000));
  const granted = await run("round-extension", cappedKey, "--findings", "F3", "--decision", "990", "--quote", quote, "--why", "one closure", "--chief", "chief-x");
  expect(granted.err).toBe(""); expect(granted.out).toContain("writer round 8");
  await nextSpec(8, "- **m1** (minor) a nonblocking wording note");
  await c.accepts("extension/valid", f, f.args, { rounds: [8, 5], residuals: [1, 0], carried: [["spec", "m1", "minor", 8]], decision });
  editLedger(f, rows => { rows.find(row => row.row === "extension").findings[0].return_sha = "f".repeat(64); });
  c.refuses("extension/invalid-row", f.args, "capped-fold: invalid ledger records: extension 990");
  expect(c.ids).toHaveLength(2); expect(c.bad).toEqual([]);
}, S1B);

test("P1 bounded evidence: nine evidence roles, each a missing file, a directory, an oversized file and a fifo, each with its own shipped stderr line", async () => {
  const c = p1Cases();
  for (const role of ["return", "spec", "plan", "page", "estimate", "ledger", "manifest", "snapshot", "decision"]) for (const type of ["fifo", "directory", "oversized", "missing"]) {
    const f = role === "decision" ? await resetCappedFixture() : await cappedFixture();
    const path = ({ return: f.args.specReturn, spec: f.spec, plan: f.plan, page: join(dirname(f.spec), "page.html"), estimate: join(dirname(f.spec), "estimate.json"), ledger: f.ledgerPath, manifest: join(dirname(f.ledgerPath), "manifest.json"), snapshot: join(dirname(f.ledgerPath), cappedKey, sha(readFileSync(f.spec,"utf8"))), decision: join(f.specsRoot, "decisions", "verbatim-decision-990-fixture.txt") } as Record<string,string>)[role];
    unlinkSync(path);
    if (type === "directory") mkdirSync(path);
    else if (type === "oversized") { writeFileSync(path, ""); truncateSync(path, 16 * 1024 * 1024 + 1); }
    else if (type === "fifo") expect(Bun.spawnSync(["mkfifo", path]).exitCode).toBe(0);
    const unreadable = `capped-fold: evidence changed or is unreadable: ${path}`;
    const message = role === "ledger" ? (type === "missing" ? `${cappedKey} is in the round manifest but has no ledger; restore it from the state repo history`
        : `${cappedKey} ledger cannot be read (${unreadable}); restore it from the state repo history`)
      : role === "manifest" ? (type === "missing" ? `no round manifest under ${f.specsRoot}; run round-seed --all once`
        : `${path}: cannot read the round manifest (${unreadable}); restore it from the state repo history`)
      : role === "decision" && type === "missing" ? "capped-fold: invalid ledger records: reset 990"
      : type === "missing" ? `ENOENT: no such file or directory, realpath '${path}'` : unreadable;
    c.refuses(`bounded/${role}/${type}`, f.args, message);
  }
  expect(c.ids).toHaveLength(36); expect(c.bad).toEqual([]);
}, 240_000);

// ---- P2: the twelve two-fault fixtures O1 to O12 (recipes of the Task 0 inventory), each refused by the earlier step in shipped order ----
type P2Fault = { opts?: Parameters<typeof cappedFixture>[0]; apply?: (f: any) => void | Promise<void>; message: (f: any) => string };
const P2_FAULTS: Record<string, P2Fault> = {
  retkey: { apply: f => { const p = join(dirname(f.spec), `HIMMEL-99-fixture.md.critic-spec-r${f.args.specReturn.match(/r(\d+)\.md$/)![1]}.md`); copyFileSync(f.args.specReturn, p); f.args.specReturn = p; },
    message: () => "capped-fold: return filename/folder key disagrees" },
  decl: { apply: f => editCappedReturn(f, f.args.specReturn, t => t.replace(`Key: ${cappedKey}`, "Key: HIMMEL-99")), message: () => P1_RETURN },
  old: { apply: f => { f.args.specReturn = f.verdicts[0]; }, message: () => "capped-fold: not the actual latest real spec round" },
  reviewed: { apply: f => editCappedReturn(f, f.args.specReturn, t => t.replace(/^Reviewed: .*\n/m, "")), message: () => "capped-fold: spec must review the current spec exactly once" },
  cap: { opts: { rounds: 2 }, message: () => "capped-fold: findings have not reached the refused round cap" },
  malformed: { apply: f => editCappedReturn(f, f.args.specReturn, t => t.replace("SPEC FINDINGS 1", "READ-SHA256 unknown file.md\nSPEC FINDINGS 1")), message: () => "capped-fold: malformed seal or READ quote" },
  duplicate: { apply: f => editCappedReturn(f, f.args.specReturn, t => { const line = /^READ-SHA256 .+$/m.exec(t)![0]; return t.replace(/(SPEC (?:FINDINGS 1|CLEAN))/, `${line.replace("READ-SHA256", "READ")}\n$1`); }),
    message: () => "capped-fold: duplicate critic READ quotes" },
  page: { apply: f => appendFileSync(join(dirname(f.spec), "page.html"), "changed"), message: f => `capped-fold: seal provenance disagrees: ${join(dirname(f.spec), "page.html")}` },
  seal: { apply: f => editCappedReturn(f, f.args.specReturn, t => t.replace(/^CONTENT-SHA256 .*\n/m, "")), message: () => "capped-fold: missing/extra ledger seals or review coverage" },
  header: { apply: f => writeFileSync(f.spec, readFileSync(f.spec, "utf8").replace(`Key: ${cappedKey}`, "Key: HIMMEL-99")), message: () => P1_DECLARED },
  ledger: { apply: f => appendFileSync(f.ledgerPath, `${JSON.stringify({ v: 1, ts: Date.now(), key: cappedKey, row: "critical", opens: 7, id: "C1", class: "spend-grant", decision: "903", quote: "a quote the file never holds", decision_path: "/x", decision_sha: "a".repeat(64), return_sha: "f".repeat(64) })}\n`),
    message: () => "capped-fold: invalid ledger records: critical 903" },
  zero: { opts: { specFindings: "", planFindings: "" }, message: () => "capped-fold: requires at least one carried finding" },
  tie: { apply: f => copyFileSync(f.args.specReturn, join(dirname(f.spec), "HIMMEL-10205-other.md.critic-spec-r5.md")),
    message: f => `capped-fold: ambiguous or unaccounted latest return: ${join(dirname(f.spec), "HIMMEL-10205-other.md.critic-spec-r5.md")}` },
  // the three steps of the ledger load, in shipped order: invalid records ("ledger"), then the epoch and key evidence, then an open historical critical finding
  evkey: { apply: f => editLedger(f, rows => { rows[0].key = "HIMMEL-99"; }), message: () => "capped-fold: invalid ledger key/record" },
  evepoch: { apply: f => editLedger(f, rows => { rows.find(r => r.row === "round" && r.round === 5).epoch = 7; }), message: () => "capped-fold: invalid ledger epoch" },
  critopen: { opts: { historical: "- **C1** (minor; operator-critical: spend-grant) historically open" }, message: () => "capped-fold: open historical operator-critical findings" },
};
// [row, the two faults applied in this order, the fault whose step comes first in the shipped order of cappedFold]
const P2_PAIRS: [string, [string, string], string][] = [
  ["O1", ["decl", "retkey"], "retkey"], ["O2", ["old", "decl"], "decl"], ["O3", ["old", "reviewed"], "old"], ["O4", ["reviewed", "cap"], "reviewed"],
  ["O5", ["malformed", "cap"], "cap"], ["O6", ["malformed", "duplicate"], "malformed"], ["O7", ["duplicate", "page"], "duplicate"], ["O8", ["seal", "page"], "page"],
  ["O9", ["header", "ledger"], "header"], ["O10", ["ledger", "reviewed"], "ledger"], ["O11", ["seal", "zero"], "seal"], ["O12", ["zero", "tie"], "zero"],
];
const p2Run = async (names: string[]) => {
  const f = await cappedFixture(Object.assign({}, ...names.map(n => P2_FAULTS[n].opts ?? {})));
  for (const n of names) await P2_FAULTS[n].apply?.(f);
  return f;
};

test("P2 single faults: each of the sixteen recipes alone gives its own shipped refusal, so every pair below holds two live faults", async () => {
  const c = p1Cases();
  const control = await cappedFixture(); await c.accepts("single/control", control, control.args, P1_ONE_CARRIED);
  for (const name of Object.keys(P2_FAULTS)) { const f = await p2Run([name]); c.refuses(`single/${name}`, f.args, P2_FAULTS[name].message(f)); }
  expect(c.ids).toHaveLength(1 + 16); expect(c.bad).toEqual([]);
}, S1B);

test("P2b the three ledger-load steps keep their shipped order: invalid records, then epoch and key evidence, then an open historical critical finding", async () => {
  const c = p1Cases();
  for (const [row, names, first] of [["O13", ["evkey", "ledger"], "ledger"], ["O14", ["critopen", "evepoch"], "evepoch"], ["O15", ["critopen", "ledger"], "ledger"]] as [string, string[], string][]) {
    const f = await p2Run(names);
    c.refuses(`${row}/${names.join("+")}`, f.args, P2_FAULTS[first].message(f));
  }
  expect(c.ids).toHaveLength(3); expect(c.bad).toEqual([]);
}, S1B);

test("P2 twelve two-fault pairs O1 to O12: the refusal is exactly the earlier step's shipped message, in the shipped order", async () => {
  const c = p1Cases();
  for (const [row, names, first] of P2_PAIRS) {
    const f = await p2Run(names);
    c.refuses(`${row}/${names.join("+")}`, f.args, P2_FAULTS[first].message(f));
  }
  expect(c.ids).toHaveLength(12); expect(c.bad).toEqual([]);
}, S1B);

const P3_USAGE = "capped-fold: capped-fold: requires exactly --key, --spec, --plan, --spec-return and --plan-return, each once\n";
test("P3 capped-fold argv grammar: any other shape than five valued flags each once prints the one usage line and exits 1", async () => {
  const f = await cappedFixture(); const flags = p1Flags(f.args);
  const swap = (flag: string, value: string) => flags.map((x, i) => flags[i - 1] === flag ? value : x);
  const rename = (flag: string, to: string) => flags.map(x => x === flag ? to : x);
  const shapes: [string, string[]][] = [
    ["no flag at all", []], ["a flag without a value", ["--key"]],
    ...["--key", "--spec", "--plan", "--spec-return", "--plan-return"].map(flag => [`${flag} missing`, flags.filter((x, i) => x !== flag && flags[i - 1] !== flag)] as [string, string[]]),
    ["a flag repeated", [...flags, "--key", cappedKey]], ["a flag repeated in place of another", rename("--spec", "--key")],
    ["an unknown flag after the five", [...flags, "--unknown", "x"]], ["an unknown flag in place of one", rename("--spec", "--specs")],
    ["a trailing positional", [...flags, "x"]], ["a leading positional", ["x", ...flags]], ["the last value missing", flags.slice(0, -1)],
    ["the equals spelling", ["--key=" + cappedKey, ...flags.slice(2)]], ["a value that starts with two dashes", swap("--key", "--x")],
    ["an empty value", swap("--spec", "")], ["an empty key", swap("--key", "")], ["a flag as the value of another", swap("--plan", "--spec-return")],
    ["only the five flag names", ["--key", "--spec", "--plan", "--spec-return", "--plan-return"]], ["the five names as pairs of themselves", flags.map(x => x.startsWith("--") ? x : "--v")],
    ["the next flag name as the value of --spec", [...flags.slice(0, 3), "--plan", ...flags.slice(4)]],
  ];
  const bad: string[] = [];
  for (const [name, argv] of shapes) {
    const run = p1Cli(...argv); const want = { code: 1, signal: null, out: "", err: P3_USAGE };
    if (JSON.stringify(run) !== JSON.stringify(want)) bad.push(`${name}: ${JSON.stringify(argv)}\n  got ${JSON.stringify(run)}`);
  }
  expect(shapes).toHaveLength(22); expect(bad).toEqual([]);
}, S1B);

test("P3 capped-fold argv grammar: the flags are accepted in any order with the same bytes, and a value the grammar accepts is refused by its own shipped message", async () => {
  const f = await cappedFixture(); const a = f.args; const pairs = [["--key", a.key], ["--spec", a.spec], ["--plan", a.plan], ["--spec-return", a.specReturn], ["--plan-return", a.planReturn]];
  const canonical = p1Cli(...p1Flags(a));
  expect(await p1Success("grammar/canonical", f, a, P1_ONE_CARRIED, canonical)).toEqual([]);
  const orders = [[4, 3, 2, 1, 0], [1, 0, 3, 2, 4], [2, 4, 0, 1, 3], [3, 0, 4, 2, 1]];
  for (const order of orders) {
    const run = p1Cli(...order.flatMap(i => pairs[i]));
    expect(run, `order ${order}`).toEqual(canonical);
  }
  const bad: string[] = [];
  const refused = (name: string, argv: string[], message: string) => {
    const run = p1Cli(...argv); const want = { code: 1, signal: null, out: "", err: p1Line(message) };
    if (JSON.stringify(run) !== JSON.stringify(want)) bad.push(`${name}\n  want ${JSON.stringify(want)}\n  got  ${JSON.stringify(run)}`);
  };
  const with_ = (flag: string, value: string) => pairs.flatMap(([k, v]) => [k, k === flag ? value : v]);
  refused("a key that is not a ticket key", with_("--key", "not-a-key"), "capped-fold: expected one ticket key");
  refused("a lowercase ticket key", with_("--key", cappedKey.toLowerCase()), "capped-fold: expected one ticket key");
  refused("a single-dash value for the key", with_("--key", "-x"), "capped-fold: expected one ticket key");
  refused("a relative spec", with_("--spec", "relative.md"), "capped-fold: paths must be absolute");
  refused("a relative return", with_("--plan-return", "r5.md"), "capped-fold: paths must be absolute");
  refused("a missing spec", with_("--spec", join(f.r, "missing.md")), `ENOENT: no such file or directory, realpath '${join(f.r, "missing.md")}'`);
  refused("the plan equal to the spec", with_("--plan", a.spec), "capped-fold: expected a distinct plan for this key");
  refused("another key than the fixture's", with_("--key", "HIMMEL-99"), "capped-fold: spec filename/folder key disagrees");
  expect(bad).toEqual([]);
}, S1B);

test("P2c cross-return failures preserve spec evidence before plan lookup", async () => {
  for (const planFault of ["missing", "aliased"]) {
    const f = await cappedFixture();
    expect((await runCapped(f.args)).schema, "the original pair is valid").toBe(1);
    if (planFault === "missing") unlinkSync(f.args.planReturn);
    else {
      const target = join(f.r, "plan-target.md"); renameSync(f.args.planReturn, target); symlinkSync(target, f.args.planReturn);
    }
    await expect(runCapped(f.args), "the plan fault alone is observable").rejects.toThrow(planFault === "missing" ? "ENOENT" : "evidence lookup must be canonical");
    await editCappedReturn(f, f.args.specReturn, text => text.replace(/^Reviewed: .*\n/m, ""));
    await expect(runCapped(f.args)).rejects.toThrow("capped-fold: spec must review the current spec exactly once");
  }
  const f = await cappedFixture(); const args = { ...f.args, specReturn: f.verdicts[0] };
  await expect(runCapped(args), "the stale spec fault alone is observable").rejects.toThrow("capped-fold: not the actual latest real spec round");
  unlinkSync(f.args.planReturn);
  await expect(runCapped(args)).rejects.toThrow("capped-fold: not the actual latest real spec round");
}, S1B);

test("P1 legacy syntax refusals remain strict", async () => {
  for (const variant of ["bare-read", "bare-read-sha", "bare-content", "quote-spacing", "quote-uppercase", "heading-case"]) {
    const f = await cappedFixture();
    expect((await runCapped(f.args)).schema, "the original syntax is valid").toBe(1);
    await editCappedReturn(f, f.args.specReturn, text => {
      const changed = variant.startsWith("bare-")
        ? text.replace(/\nSPEC FINDINGS/, `\n${variant === "bare-read" ? "READ" : variant === "bare-read-sha" ? "READ-SHA256" : "CONTENT-SHA256"}\nSPEC FINDINGS`)
        : variant === "quote-spacing" ? text.replace(/^(READ(?:-SHA256)? [0-9a-f]{64}) /m, "$1  ")
        : variant === "quote-uppercase" ? text.replace(/^(READ(?:-SHA256)? )([0-9a-f]{64})/m, (_, prefix, sum) => prefix + sum.toUpperCase())
        : text.replace("(minor)", "(Minor)");
      expect(changed, "the fixture fault really changes the return").not.toBe(text);
      return changed;
    });
    await expect(runCapped(f.args), variant).rejects.toThrow(variant === "heading-case" ? "capped-fold: ineligible finding heading:" : "capped-fold: malformed seal or READ quote");
  }
}, S1B);

// ---- Task 3b: the shared ledger names change no path, order or word --------------------------------------------------
// W1 to W7 and M6 characterize the writers, the readers and the on-disk layout: they are green before the migration and
// after it. X3 is the migration tripwire and is red until every duplicated construction is gone. Every path below is a
// literal on purpose: it is the independent assertion of the on-disk contract, not an import of the names under test.
import { lstatSync, readlinkSync } from "node:fs";

const wDir = (specs: string) => join(specs, "ledgers", "spec-rounds");
const wRows = (file: string) => readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
const wSha = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
const wTree = (dir: string, prefix = ""): Record<string, string> => Object.fromEntries(readdirSync(dir).sort().flatMap((name): [string, string][] => {
  const path = join(dir, name); const rel = prefix + name; const st = lstatSync(path);
  if (st.isSymbolicLink()) return [[rel, `link ${readlinkSync(path)}`]];
  if (st.isDirectory()) return [[rel, "dir"], ...Object.entries(wTree(path, `${rel}/`))];
  return [[rel, wSha(path)]];
}));
const wSeedable = (specs: string, keys: string[]) => keys.map((key) => {
  const md = join(specs, "designs", `${key}-w.md`); const text = `# ${key}\n`;
  writeFileSync(md, text); writeFileSync(`${md}.critic-spec-r1.md`, `critic return\nCONTENT-SHA256 ${sha(text)} ${basename(md)}\nSPEC CLEAN\n`);
  return { key, md, text, verdict: `${md}.critic-spec-r1.md` };
});
const W_HOLDS = (dir: string) => `round-seed: ${dir} already holds a ledger, snapshot or manifest\n`;

test("W1 round-seed --all: the created layout, the seed and manifest rows, and the already-holds refusal", async () => {
  const t = specsTree(); const made = wSeedable(t.specs, [ROUND_KEY, "HIMMEL-9702"]); const dir = wDir(t.specs);
  expect(existsSync(join(t.specs, "ledgers"))).toBe(false);
  const fresh = await routeCli("round-seed", "--all", t.specs);
  expect(fresh).toEqual({ code: 0, err: "", out: made.map((m) => `seeded ${m.key} spec=1 plan=0\n`).join("") });
  expect(readdirSync(join(t.specs, "ledgers"))).toEqual(["spec-rounds"]);
  expect(readdirSync(dir).sort()).toEqual([ROUND_KEY, `${ROUND_KEY}.jsonl`, "HIMMEL-9702", "HIMMEL-9702.jsonl", "manifest.json", "round-seed.jsonl.lock"]);
  for (const m of made) {
    const text = readFileSync(join(dir, `${m.key}.jsonl`), "utf8");
    expect(text.split("\n").length, "one row on one line").toBe(2); expect(text.endsWith("\n")).toBe(true);
    const seed = JSON.parse(text);
    expect(Object.keys(seed)).toEqual(["v", "ts", "key", "row", "spec", "plan", "latest"]);
    expect(seed).toMatchObject({ v: 1, key: m.key, row: "seed", spec: 1, plan: 0, latest: { spec: [{ verdict_path: m.verdict, verdict: "SPEC CLEAN", findings: [], unrated_ids: [], seals: [{ read_path: m.md, read_sha: sha(m.text) }] }], plan: [] } });
    expect(seed.latest.spec[0].return_sha).toBe(sha("critic return\nSPEC CLEAN\n"));
    expect(Number.isInteger(seed.ts)).toBe(true);
    expect(readdirSync(join(dir, m.key))).toEqual([sha(m.text)]);
    expect(readFileSync(join(dir, m.key, sha(m.text)), "utf8")).toBe(m.text);
  }
  const manifestText = readFileSync(join(dir, "manifest.json"), "utf8"); const manifest = JSON.parse(manifestText);
  expect(Object.keys(manifest)).toEqual(["v", "ts", "keys"]);
  expect(manifest).toMatchObject({ v: 1, keys: { [made[0].key]: { spec: 1, plan: 0 }, [made[1].key]: { spec: 1, plan: 0 } } });
  expect(Number.isInteger(manifest.ts)).toBe(true);
  expect(manifestText).toBe(`${JSON.stringify(manifest)}\n`);
  expect(statSync(join(dir, "round-seed.jsonl.lock")).size).toBe(0);
  const seeded = wTree(dir);
  expect(await routeCli("round-seed", "--all", t.specs)).toEqual({ code: 1, out: "", err: W_HOLDS(dir) });
  expect(wTree(dir), "a refusal writes nothing").toEqual(seeded);
  // what already holds a root and what does not: a manifest, a ledger file (also one with no key), a snapshot folder or a link to one
  // hold it; a lock, a foreign file and a dangling link do not
  const holders: [string, (d: string) => void, boolean][] = [
    ["a manifest", (d) => writeFileSync(join(d, "manifest.json"), ""), true],
    ["a ledger file", (d) => writeFileSync(join(d, "HIMMEL-1.jsonl"), ""), true],
    ["a ledger file with no key", (d) => writeFileSync(join(d, ".jsonl"), ""), true],
    ["a snapshot folder", (d) => mkdirSync(join(d, "HIMMEL-1")), true],
    ["a link to a folder", (d) => { mkdirSync(join(d, "..", "elsewhere")); symlinkSync(join(d, "..", "elsewhere"), join(d, "HIMMEL-1")); }, true],
    ["a lock file", (d) => writeFileSync(join(d, "HIMMEL-1.jsonl.lock"), ""), false],
    ["a foreign file", (d) => writeFileSync(join(d, "notes.txt"), "x\n"), false],
    ["a dangling link", (d) => symlinkSync(join(d, "nowhere"), join(d, "HIMMEL-1")), false],
  ];
  for (const [name, setup, holds] of holders) {
    const s = specsTree(); wSeedable(s.specs, [ROUND_KEY]); const d = wDir(s.specs); mkdirSync(d, { recursive: true }); setup(d);
    const staged = wTree(d); const run = await routeCli("round-seed", "--all", s.specs);
    if (holds) { expect(run, name).toEqual({ code: 1, out: "", err: W_HOLDS(d) }); expect(wTree(d), name).toEqual({ ...staged, "round-seed.jsonl.lock": EMPTY_FILE }); }
    else {
      expect(run, name).toEqual({ code: 0, err: "", out: `seeded ${ROUND_KEY} spec=1 plan=0\n` });
      expect(Object.keys(wTree(d)).filter((n) => !n.includes("/")).sort(), name).toEqual([...new Set([...Object.keys(staged), ROUND_KEY, `${ROUND_KEY}.jsonl`, "manifest.json", "round-seed.jsonl.lock"])].sort());
    }
  }
  // a seed that fails midway removes every file and snapshot folder it made, so the root can be seeded again
  const f = specsTree(); const both = wSeedable(f.specs, [ROUND_KEY, "HIMMEL-9702"]); const fd = wDir(f.specs); mkdirSync(fd, { recursive: true });
  const blocker = join(fd, both[1].key); writeFileSync(blocker, "in the way");
  const failed = await routeCli("round-seed", "--all", f.specs);
  expect(failed.code).toBe(1); expect(failed.out).toBe(""); expect(failed.err).not.toBe("");
  expect(wTree(fd), "everything the failed seed made is gone").toEqual({ [both[1].key]: sha("in the way"), "round-seed.jsonl.lock": EMPTY_FILE });
  unlinkSync(blocker);
  expect((await routeCli("round-seed", "--all", f.specs)).code).toBe(0);
  expect(readdirSync(fd).sort()).toEqual([...both.flatMap((m) => [m.key, `${m.key}.jsonl`]), "manifest.json", "round-seed.jsonl.lock"].sort());
});
const EMPTY_FILE = createHash("sha256").update("").digest("hex");

test("W2 critic-round-check: the round and seal rows, the snapshots and the lock at their literal paths", async () => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const md = join(t.dir, `${ROUND_KEY}-w2.md`); const html = join(t.dir, `${ROUND_KEY}-w2.html`);
  const mdText = front(ROUND_KEY, "# W2\n"); const htmlText = "<h1>W2</h1>\n"; writeFileSync(md, mdText); writeFileSync(html, htmlText);
  const v = `${md}.critic-spec-r1.md`; writeFileSync(v, ret("SPEC FINDINGS 1", `read ${sha(mdText)} and ${sha(htmlText)}`, "- **a1** (minor) a note"));
  const dir = wDir(t.specs); const file = join(dir, `${ROUND_KEY}.jsonl`);
  expect(await seal(v, md, sha(mdText))).toEqual({ code: 0, err: "" });
  const { returnSha } = await import("./chief-route"); const sum = returnSha(readFileSync(v, "utf8"));
  const [round, ...none] = wRows(file); expect(none).toEqual([]);
  expect(Object.keys(round)).toEqual(["v", "ts", "key", "row", "critic", "round", "epoch", "return_sha", "verdict_path", "read_path", "read_sha", "verdict", "mode", "findings", "unrated_ids"]);
  expect(round).toMatchObject({ v: 1, key: ROUND_KEY, row: "round", critic: "spec", round: 1, epoch: 0, return_sha: sum, verdict_path: v, read_path: md, read_sha: sha(mdText), verdict: "SPEC FINDINGS 1", mode: "full", findings: [{ id: "a1", severity: "minor" }], unrated_ids: [] });
  expect(await seal(v, html, sha(htmlText))).toEqual({ code: 0, err: "" });
  const rows = wRows(file); expect(rows.map((r) => r.row)).toEqual(["round", "seal"]);
  expect(Object.keys(rows[1])).toEqual(["v", "ts", "key", "row", "return_sha", "read_path", "read_sha"]);
  expect(rows[1]).toMatchObject({ v: 1, key: ROUND_KEY, row: "seal", return_sha: sum, read_path: html, read_sha: sha(htmlText) });
  expect(readdirSync(dir).sort()).toEqual([ROUND_KEY, `${ROUND_KEY}.jsonl`, `${ROUND_KEY}.jsonl.lock`, "manifest.json", "round-seed.jsonl.lock"]);
  expect(readdirSync(join(dir, ROUND_KEY)).sort()).toEqual([sha(mdText), sha(htmlText)].sort());
  expect(readFileSync(join(dir, ROUND_KEY, sha(mdText)), "utf8")).toBe(mdText); expect(readFileSync(join(dir, ROUND_KEY, sha(htmlText)), "utf8")).toBe(htmlText);
  expect(statSync(join(dir, `${ROUND_KEY}.jsonl.lock`)).size).toBe(0);
  expect(readFileSync(v, "utf8")).toContain(`CONTENT-SHA256 ${sha(mdText)} ${basename(md)}\n`);
  const before = wTree(dir); const again = await seal(v, md, sha(mdText));
  expect(again.code).toBe(1); expect(again.err).toBe(`critic-seal: ${v} already seals ${basename(md)}\n`); expect(wTree(dir)).toEqual(before);
});

test("W2 seal faults: each refusal keeps its words, its order and what it leaves on disk", async () => {
  const W_MISSING = (specs: string) => `no round manifest under ${specs}; run round-seed --all once`;
  const fresh = (seeded: boolean) => { const t = specsTree(); if (seeded) mkdirSync(wDir(t.specs), { recursive: true }); return t; };
  const sealed = async (t: { specs: string; dir: string }, name: string, text: string, verdictName = name) => {
    const spec = join(t.dir, name); writeFileSync(spec, text);
    const v = join(t.dir, `${verdictName}.critic-spec-r1.md`); writeFileSync(v, ret("SPEC CLEAN", `read ${sha(text)}`));
    return { spec, v, run: await seal(v, spec, sha(text)) };
  };
  // 1. no manifest at all, then with a spec that has no key either: the manifest message comes first and creates nothing
  for (const name of [`${ROUND_KEY}-w.md`, "plain.md"]) {
    const t = specsTree(); const r = await sealed(t, name, front(ROUND_KEY, "# w\n"));
    expect(r.run.code, name).not.toBe(0); expect(r.run.err, name).toContain(W_MISSING(t.specs)); expect(existsSync(join(t.specs, "ledgers")), name).toBe(false);
  }
  // 2. a manifest that does not parse comes before the key faults
  { const t = specsTree(); mkdirSync(wDir(t.specs), { recursive: true }); writeFileSync(join(wDir(t.specs), "manifest.json"), "{");
    const r = await sealed(t, "plain.md", front(ROUND_KEY, "# w\n"));
    expect(r.run.err).toContain(`${join(wDir(t.specs), "manifest.json")}: the round manifest does not parse; restore it from the state repo history`); }
  { const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
    const text = front(ROUND_KEY, "# w\n"); const other = join(t.dir, "HIMMEL-9702-y.md"); writeFileSync(other, front("HIMMEL-9702", "# y\n"));
    const named = join(t.dir, `${ROUND_KEY}-w.md`); const v = `${named}.critic-spec-r1.md`; writeFileSync(named, text);
    writeFileSync(v, ret("SPEC CLEAN", `read ${sha(text)} and ${sha(front("HIMMEL-9702", "# y\n"))}`));
    const mixed = await seal(v, other, sha(front("HIMMEL-9702", "# y\n")));
    expect(mixed.err).toContain(`${basename(v)} is named for ${ROUND_KEY} but the file it read belongs to HIMMEL-9702; the seal is refused`);
    const keyless = await sealed(t, "plain.md", text);
    expect(keyless.run.err).toContain(`${keyless.spec}: has no ticket key; name the spec <KEY>-<slug>.md or put it in specs/<KEY>/`);
    expect(readdirSync(wDir(t.specs)).sort(), "refused before the lock").toEqual(["manifest.json", "round-seed.jsonl.lock"]); }
  // 5. a first round whose front matter names no such ticket: refused under the lock, so the lock stays and nothing else
  { const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
    const r = await sealed(t, `${ROUND_KEY}-w.md`, "# no front matter\n");
    expect(r.run.err).toContain(`${r.spec}: front matter has no tickets: line naming ${ROUND_KEY}`);
    expect(readdirSync(wDir(t.specs)).sort()).toEqual([`${ROUND_KEY}.jsonl.lock`, "manifest.json", "round-seed.jsonl.lock"]);
    expect(readFileSync(r.v, "utf8")).not.toContain("CONTENT-SHA256"); }
  for (const [name, setup, message] of [
    ["a ledger line that does not parse", (dir: string) => writeFileSync(join(dir, `${ROUND_KEY}.jsonl`), "garbage\n"), `${ROUND_KEY} ledger line 1 does not parse; restore it from the state repo history`],
    ["a manifested key with no ledger", (dir: string) => writeFileSync(join(dir, "manifest.json"), `${JSON.stringify({ v: 1, ts: 1, keys: { [ROUND_KEY]: { spec: 1, plan: 0 } } })}\n`), `${ROUND_KEY} is in the round manifest but has no ledger; restore it from the state repo history`],
  ] as const) {
    const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0); setup(wDir(t.specs));
    const r = await sealed(t, `${ROUND_KEY}-w.md`, "# no front matter either\n");
    expect(r.run.err, name).toContain(message); expect(r.run.err, name).not.toContain("front matter");
  }
  // 8. the cap: a fourth round with no blocking finding is refused with the ledger and its folder untouched
  { const t = await roundTree([], []); const dir = wDir(t.specs); const before = wTree(dir);
    const refused = await sealOn(`${t.a}.critic-spec-r6.md`, [t.a], "SPEC CLEAN");
    expect(refused.err).toContain(T1("spec")); expect(refused.code).not.toBe(0); expect(wTree(dir)).toEqual(before); }
}, S1B);

test("W3 round-override, round-critical, round-reset and round-extension append one row at the literal ledger path; each one-use refusal keeps its words and writes nothing", async () => {
  const appended = async (specs: string, run: () => Promise<{ code: number; err: string }>, keys: string[], fields: Record<string, unknown>) => {
    const dir = wDir(specs); const file = join(dir, `${CAP_KEY}.jsonl`); const before = readFileSync(file, "utf8"); const tree = wTree(dir);
    const res = await run(); expect(res.err).toBe(""); expect(res.code).toBe(0);
    const after = readFileSync(file, "utf8"); expect(after.startsWith(before), "earlier bytes untouched").toBe(true);
    const added = after.slice(before.length); expect(added.endsWith("\n") && added.indexOf("\n") === added.length - 1, "exactly one line").toBe(true);
    const row = JSON.parse(added); expect(Object.keys(row)).toEqual(keys); expect(row).toMatchObject({ v: 1, key: CAP_KEY, ...fields }); expect(Number.isInteger(row.ts)).toBe(true);
    expect(wTree(dir), "no other file changed").toEqual({ ...tree, [`${CAP_KEY}.jsonl`]: wSha(file) });
    return row;
  };
  const refused = async (specs: string, run: () => Promise<{ code: number; err: string }>, message: string) => {
    const dir = wDir(specs); const tree = wTree(dir); const res = await run();
    expect(res.code).toBe(1); expect(res.err).toBe(`${message}\n`); expect(wTree(dir), message).toEqual(tree);
  };
  // override: once, from an open blocking finding of the latest round
  { const t = await roundTree(MAJOR, []); expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens M1) still open", "- **n1** (minor) a note")).err).toBe("");
    const over = () => verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "the build cannot carry it", "--chief", "chief-x", "--specs", t.specs);
    const row = await appended(t.specs, over, ["v", "ts", "key", "row", "epoch", "round_opened", "findings", "why", "chief", "decision", "quote", "decision_path", "decision_sha"], { row: "override", epoch: 0, round_opened: 7, why: "the build cannot carry it", chief: "chief-x", decision: "7311", quote: OVR_WORDS, findings: [{ id: "M2", severity: "major", critic: "spec" }] });
    expect(row.findings[0].return_sha).toBe(rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 6).return_sha);
    await refused(t.specs, over, `round-override: ${CAP_KEY} already used its one override`); }
  // critical: needs the console, a decision naming the ticket, and is spent once
  { const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
    expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
    const d = decide(t.specs, 901, `${CAP_KEY} operator: ${SPEND}\n`);
    await refused(t.specs, () => critical(false, t.specs, "C1", 901, SPEND), "round-critical: needs HIMMEL_CONSOLE=1, the chief's marker; a worker never writes a record");
    const row = await appended(t.specs, () => critical(true, t.specs, "C1", 901, SPEND), ["v", "ts", "key", "row", "epoch", "opens", "id", "class", "decision", "quote", "decision_path", "decision_sha", "return_sha"],
      { row: "critical", epoch: 0, opens: 7, id: "C1", class: "spend-grant", decision: "901", quote: SPEND, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")) });
    expect(row.return_sha).toBe(rowsOf(t.specs, "round").find((x) => x.critic === "spec" && x.round === 5).return_sha);
    await refused(t.specs, () => critical(true, t.specs, "C1", 901, SPEND), `round-critical: decision 901 was already used for ${CAP_KEY}`); }
  // reset: a new epoch, once
  { const t = await roundTree(MAJOR, []); const d = decide(t.specs, 906, `${CAP_KEY} operator: start this ticket over from scratch\n`);
    const reset = () => verb(true, "round-reset", CAP_KEY, "--decision", "906", "--quote", "start this ticket over from scratch", "--specs", t.specs);
    await appended(t.specs, reset, ["v", "ts", "key", "row", "epoch", "decision", "quote", "decision_path", "decision_sha"], { row: "reset", epoch: 1, decision: "906", quote: "start this ticket over from scratch", decision_path: d, decision_sha: sha(readFileSync(d, "utf8")) });
    await refused(t.specs, reset, `round-reset: ${CAP_KEY} already used its one reset`); }
  // extension: one grant for one round, bound to the sealed returns
  { const t = await extTree(); const d = decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
    await refused(t.specs, () => extend(false, t), "round-extension: needs HIMMEL_CONSOLE=1, the chief's marker; a worker never writes a record");
    const row = await appended(t.specs, () => extend(true, t), ["v", "ts", "key", "row", "epoch", "round_opened", "findings", "returns", "why", "chief", "decision", "quote", "decision_path", "decision_sha"],
      { row: "extension", epoch: 0, round_opened: 8, why: "one closure for the two corrections", chief: "chief-x", decision: "986", quote: APPROVE, decision_path: d, decision_sha: sha(readFileSync(d, "utf8")) });
    expect(row.findings.map((f: { id: string }) => f.id)).toEqual(["F3", "F4"]);
    const dup = await extend(true, t); expect(dup.code).toBe(1); expect(dup.err).toContain("already open"); }
}, S1B);

test("W4 round-status: the keyed form and the no-key listing take a key from a ledger file or the manifest only, never from a lock, a folder or another name", async () => {
  const t = await roundTree(MAJOR, []); const dir = wDir(t.specs); const manifestFile = join(dir, "manifest.json");
  const head = await routeCli("round-status", CAP_KEY, "--specs", t.specs);
  expect(head.code).toBe(0); expect(head.err).toBe(""); expect(head.out.split("\n")[0]).toMatch(new RegExp(`^${CAP_KEY} spec=5 plan=5 writer=5 next=closure cap=5: `));
  const manifest = JSON.parse(readFileSync(manifestFile, "utf8")); manifest.keys["HIMMEL-9801"] = { spec: 0, plan: 0 }; writeFileSync(manifestFile, `${JSON.stringify(manifest)}\n`);
  writeFileSync(join(dir, "HIMMEL-9802.jsonl"), "");                         // a ledger file the manifest does not list
  writeFileSync(join(dir, "HIMMEL-9803.jsonl.lock"), "");                    // a lock: not a key
  mkdirSync(join(dir, "HIMMEL-9804"));                                       // a snapshot folder alone: not a key
  mkdirSync(join(dir, "HIMMEL-9805.jsonl"));                                 // listed by its name, so it is a key, and unreadable as a ledger
  writeFileSync(join(dir, "HIMMEL-9806.jsonl.bak"), ""); writeFileSync(join(dir, "notes.txt"), "x\n");   // other names: not keys
  writeFileSync(join(dir, ".jsonl"), "");                                    // the ledger file of the empty key: shipped, listed, and refused by its own message
  const all = await routeCli("round-status", "--all", "--json", "--specs", t.specs);
  expect(all.code).toBe(0); expect(all.err).toBe(""); expect(all.out.endsWith("\n") && all.out.indexOf("\n") === all.out.length - 1).toBe(true);
  const parsed = JSON.parse(all.out);
  expect(Object.keys(parsed)).toEqual(["cap", "classes", "keys"]); expect(parsed.cap).toBe(5);
  expect(Object.keys(parsed.keys)).toEqual(["", CAP_KEY, "HIMMEL-9801", "HIMMEL-9802", "HIMMEL-9805"]);
  expect(parsed.keys[CAP_KEY]).toMatchObject({ key: CAP_KEY, spec: 5, plan: 5, writer: 5, next: "closure" });
  expect(parsed.keys["HIMMEL-9801"]).toEqual({ key: "HIMMEL-9801", error: "HIMMEL-9801 is in the round manifest but has no ledger; restore it from the state repo history" });
  expect(parsed.keys["HIMMEL-9802"]).toMatchObject({ key: "HIMMEL-9802", spec: 0, plan: 0, next: "full" });
  expect(parsed.keys["HIMMEL-9805"].error).toMatch(/^HIMMEL-9805 ledger cannot be read \(.*\); restore it from the state repo history$/);
  expect(parsed.keys[""]).toEqual({ key: "", error: " is in the round manifest but has no ledger; restore it from the state repo history" });
  // the keyed form of a lock or a folder name answers as an unknown key, not as one of the listed keys
  for (const name of ["HIMMEL-9803", "HIMMEL-9804"]) {
    const unlisted = await routeCli("round-status", name, "--specs", t.specs);
    expect(unlisted.code, name).toBe(name === "HIMMEL-9804" ? 1 : 0);
  }
});

test("W5 the lock: its name and path, and what a refused or a successful writer leaves behind", async () => {
  // a refused writer on a root nobody seeded still takes the lock first: the folder and the lock exist, nothing else
  const bare = specsTree(); expect(existsSync(join(bare.specs, "ledgers"))).toBe(false);
  const refused = await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--specs", bare.specs);
  expect(refused).toEqual({ code: 1, out: "", err: `no round manifest under ${bare.specs}; run round-seed --all once\n` });
  expect(readdirSync(join(bare.specs, "ledgers"))).toEqual(["spec-rounds"]);
  expect(wTree(wDir(bare.specs))).toEqual({ [`${CAP_KEY}.jsonl.lock`]: EMPTY_FILE });
  const t = await roundTree(MAJOR, []); const dir = wDir(t.specs);
  expect(readdirSync(dir).sort()).toEqual([CAP_KEY, `${CAP_KEY}.jsonl`, `${CAP_KEY}.jsonl.lock`, "manifest.json", "round-seed.jsonl.lock"]);
  const before = wTree(dir); expect((await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--specs", t.specs)).code).toBe(1);
  expect(wTree(dir), "a refused append").toEqual(before);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect((await verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--specs", t.specs)).err).toBe("");
  expect(readdirSync(dir).sort(), "an append").toEqual([CAP_KEY, `${CAP_KEY}.jsonl`, `${CAP_KEY}.jsonl.lock`, "manifest.json", "round-seed.jsonl.lock"]);
  for (const name of [`${CAP_KEY}.jsonl.lock`, "round-seed.jsonl.lock"]) expect(statSync(join(dir, name)).size, name).toBe(0);
  // two writers racing for one key take turns: both rows land, whole
  const racing = await roundTree(MAJOR, []); expect((await closeOn(racing, "spec", 6, [racing.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  const both = await Promise.all([1, 2].map(() => verb(true, "round-override", CAP_KEY, "--findings", "M2", "--why", "w", "--chief", "chief-x", "--specs", racing.specs)));
  expect(both.map((r) => r.code).sort()).toEqual([0, 1]); expect(rowsOf(racing.specs, "override")).toHaveLength(1);
}, S1B);

test("W6 snapshots: the sealed bytes at their literal path, and the role the capped reader gives a ledger, a manifest, a snapshot and any other path", async () => {
  const t = await roundTree(MAJOR, [], true); const dir = wDir(t.specs); const mdText = front(CAP_KEY, "# A\n"); const htmlText = "<h1>A</h1>\n";
  const planText = "# A plan\n";
  expect(readdirSync(join(dir, CAP_KEY)).sort()).toEqual([sha(mdText), sha(htmlText), sha(planText)].sort());
  for (const s of [mdText, htmlText, planText]) expect(readFileSync(join(dir, CAP_KEY, sha(s)), "utf8")).toBe(s);
  const f = await cappedFixture(); const proof = await runCapped(f.args); const cdir = wDir(f.specsRoot);
  expect(f.ledgerPath, "the fixture builder names the ledger file by the shared rule").toBe(join(cdir, `${cappedKey}.jsonl`));
  expect(existsSync(f.ledgerPath)).toBe(true);
  const byRole =(role: string) => proof.pins.filter((pin: { role: string }) => pin.role === role);
  expect(byRole("ledger").map((p: { path: string }) => p.path)).toEqual([join(cdir, `${cappedKey}.jsonl`)]);
  expect(byRole("manifest").map((p: { path: string }) => p.path)).toEqual([join(cdir, "manifest.json")]);
  const snapshots = byRole("snapshot"); expect(snapshots).toHaveLength(4);
  for (const pin of snapshots) { expect(pin.path).toBe(join(cdir, cappedKey, pin.sha256)); expect(wSha(pin.path)).toBe(pin.sha256); }
  expect(snapshots.map((p: { path: string }) => p.path).sort()).toEqual(readdirSync(join(cdir, cappedKey)).map((n) => join(cdir, cappedKey, n)).sort());
  expect(byRole("artifact").map((p: { path: string }) => p.path).sort()).toEqual([join(f.specsRoot, "designs", "estimate.json"), join(f.specsRoot, "designs", "page.html"), f.plan, f.spec].sort());
  expect(proof.pins.filter((p: { role: string }) => ["ledger", "manifest", "snapshot"].includes(p.role))).toHaveLength(6);
  const lookalike = await cappedFixture({ pageName: `${cappedKey}.jsonl` }); const lookProof = await runCapped(lookalike.args);
  expect(lookProof.pins.find((p: { path: string }) => p.path === join(lookalike.specsRoot, "designs", `${cappedKey}.jsonl`)).role).toBe("artifact");
  expect(lookProof.pins.filter((p: { role: string }) => p.role === "ledger")).toHaveLength(1);
  const reset = await resetCappedFixture(); const resetProof = await runCapped(reset.args);
  expect(resetProof.pins.find((p: { role: string }) => p.role === "decision").path).toBe(join(reset.specsRoot, "decisions", "verbatim-decision-990-fixture.txt"));
}, S1B);

test("W7 readManifest: a missing, unreadable, malformed or wrong-shaped manifest keeps its words, and loadLedger reads the manifest, then the ledger, then the snapshot folder", async () => {
  const status = async (specs: string, key = CAP_KEY) => routeCli("round-status", key, "--specs", specs);
  const t = await roundTree([], []); const dir = wDir(t.specs); const manifestFile = join(dir, "manifest.json");
  const parse = `${manifestFile}: the round manifest does not parse; restore it from the state repo history\n`;
  // missing, then unreadable (a folder where the file belongs), then every malformed or wrong shape
  rmSync(manifestFile); expect(await status(t.specs)).toEqual({ code: 1, out: "", err: `no round manifest under ${t.specs}; run round-seed --all once\n` });
  mkdirSync(manifestFile); const unreadable = await status(t.specs);
  expect(unreadable.code).toBe(1); expect(unreadable.out).toBe("");
  expect(unreadable.err).toMatch(new RegExp(`^${manifestFile.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}: cannot read the round manifest \\(.*\\); restore it from the state repo history\\n$`)); rmSync(manifestFile, { recursive: true });
  for (const text of ["", "{", "null", "[]", "5", '"keys"', "{}", '{"keys":null}', '{"keys":[]}', '{"keys":"x"}', '{"keys":5}', '{"v":1,"keys":true}']) {
    writeFileSync(manifestFile, text); expect(await status(t.specs), JSON.stringify(text)).toEqual({ code: 1, out: "", err: parse });
    expect(await routeCli("round-status", "--all", "--json", "--specs", t.specs), `no key ${JSON.stringify(text)}`).toEqual({ code: 1, out: "", err: parse });
  }
  for (const text of ['{"keys":{}}', JSON.stringify({ v: 1, ts: 1, keys: { [ROUND_KEY]: 3 }, extra: true })]) { writeFileSync(manifestFile, text); expect((await status(t.specs, "HIMMEL-9799")).code, text).toBe(0); }
  const u = specsTree(); mkdirSync(wDir(u.specs), { recursive: true }); const udir = wDir(u.specs); const umanifest = join(udir, "manifest.json"); const KEY = "HIMMEL-9798";
  writeFileSync(umanifest, "{"); writeFileSync(join(udir, `${KEY}.jsonl`), "garbage\n"); symlinkSync(join(udir, KEY), join(udir, KEY));
  expect((await status(u.specs, KEY)).err).toBe(`${umanifest}: the round manifest does not parse; restore it from the state repo history\n`);
  writeFileSync(umanifest, `${JSON.stringify({ v: 1, ts: 1, keys: {} })}\n`);
  expect((await status(u.specs, KEY)).err).toBe(`${KEY} ledger line 1 does not parse; restore it from the state repo history\n`);
  writeFileSync(join(udir, `${KEY}.jsonl`), "");
  expect((await status(u.specs, KEY)).err).toMatch(new RegExp(`^${KEY}: cannot read its snapshot folder \\(.*\\); restore it from the state repo history\\n$`));
  rmSync(join(udir, `${KEY}.jsonl`)); mkdirSync(join(udir, `${KEY}.jsonl`));
  expect((await status(u.specs, KEY)).err, "a folder where the ledger belongs").toMatch(new RegExp(`^${KEY} ledger cannot be read \\(.*\\); restore it from the state repo history\\n$`));
  rmSync(join(udir, `${KEY}.jsonl`), { recursive: true }); symlinkSync(join(udir, "nowhere"), join(udir, `${KEY}.jsonl`)); rmSync(join(udir, KEY));
  expect((await status(u.specs, KEY)).code, "a dangling ledger link reads as no ledger").toBe(0);
}, S1B);

test("M6 loadLedger of the anchor on the existing ledger fixtures: the state it answers and the message it refuses with are unchanged", async () => {
  const json = async (specs: string, key: string) => JSON.parse((await routeCli("round-status", key, "--specs", specs, "--json")).out);
  const sealedTree = await roundTree(MAJOR, []);
  expect(await json(sealedTree.specs, CAP_KEY)).toMatchObject({ key: CAP_KEY, epoch: 0, spec: 5, plan: 5, writer: 5, next: "closure", invalid: [], critical_open: [] });
  const seeded = await seededTree([]);
  expect(await json(seeded.specs, CAP_KEY)).toMatchObject({ key: CAP_KEY, epoch: 0, spec: 5, plan: 5, next: "none", invalid: [] });
  const reset = await roundTree(MAJOR, []); decide(reset.specs, 906, `${CAP_KEY} operator: start this ticket over from scratch\n`);
  expect((await verb(true, "round-reset", CAP_KEY, "--decision", "906", "--quote", "start this ticket over from scratch", "--specs", reset.specs)).err).toBe("");
  expect(await json(reset.specs, CAP_KEY)).toMatchObject({ key: CAP_KEY, epoch: 1, spec: 0, plan: 0, next: "full" });
  expect(await json(sealedTree.specs, "HIMMEL-9799")).toMatchObject({ key: "HIMMEL-9799", epoch: 0, spec: 0, plan: 0, writer: 0, next: "full", invalid: [] });
  // the same loads through the capped reader, whose reads are cached and pinned: the standard fixture folds, and each fault keeps its words
  const f = await cappedFixture(); const dir = wDir(f.specsRoot); const manifestFile = join(dir, "manifest.json"); const ledgerFile = join(dir, `${cappedKey}.jsonl`);
  expect((await runCapped(f.args)).epoch).toBe(0);
  const manifest = readFileSync(manifestFile, "utf8"); const ledger = readFileSync(ledgerFile, "utf8");
  rmSync(manifestFile); await expect(runCapped(f.args)).rejects.toThrow(`no round manifest under ${f.specsRoot}; run round-seed --all once`);
  writeFileSync(manifestFile, "{}"); await expect(runCapped(f.args)).rejects.toThrow(`${manifestFile}: the round manifest does not parse; restore it from the state repo history`);
  writeFileSync(manifestFile, manifest); writeFileSync(ledgerFile, "garbage\n"); await expect(runCapped(f.args)).rejects.toThrow(`${cappedKey} ledger line 1 does not parse; restore it from the state repo history`);
  rmSync(ledgerFile); await expect(runCapped(f.args)).rejects.toThrow(`${cappedKey} is in the round manifest but has no ledger; restore it from the state repo history`);
  writeFileSync(ledgerFile, ledger); expect((await runCapped(f.args)).epoch).toBe(0);
}, S1B);

// X3, the migration tripwire. Four patterns over the text of the two files; a hit is allowed only as one of the exact lines below.
// The list is finite and spelled out: a manifestFile line in its old spelling, or any other construction, is a hit that fails.
const X3_PATTERNS = ["spec-rounds", "manifest.json", ".jsonl", "ledgerDir("];
const x3Hits = (text: string) => text.split("\n").filter((line) => X3_PATTERNS.some((pattern) => line.includes(pattern)));
const x3Verdict = (text: string, keep: readonly string[]) => ({
  unexpected: x3Hits(text).filter((line) => !keep.includes(line)),
  missing: keep.filter((line) => x3Hits(text).filter((hit) => hit === line).length !== 1),
});
const X3_ROUTE_KEEP = [
  "const APPROVALS_FILE = \"outside-pr-approvals.jsonl\";",
  "const manifestFile = (specs: string) => join(ledgerDirOf(specs), \"manifest.json\");",
  "  await appendFile(join(root, \"monitor\", \"outbox.jsonl\"), `${JSON.stringify({ text, kind, at: new Date().toISOString() })}\\n`, { mode: 0o600 });",
  "      const file = join(root, \"sessions\", chat < 0 ? `group_${chat}` : \"__chat__\", \"outbox.jsonl\");",
] as const;
const X3_LIB_KEEP = ["  if (await stat(join(ledgerDirOf(specsRoot), 'manifest.json')).then(() => true, () => false)) await roundSeed(specsRoot);"] as const;
const x3Imports = (text: string) => [...text.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']\.\.\/jira\/src\/release\/pinned\.ts["']/g)]
  .flatMap((m) => m[1].split(",").map((name) => name.trim().replace(/^type\s+/, "")).filter(Boolean));

test("X3 controls: the scanner reports any other construction, an old spelling of an allowed line, and a known line that is doubled or gone", () => {
  const keep = X3_ROUTE_KEEP; const all = keep.join("\n");
  expect(x3Verdict(all, keep)).toEqual({ unexpected: [], missing: [] });
  for (const [name, extra] of [
    ["a ledger file", "  const f = join(dir, `${key}.jsonl`);"],
    ["a lock", "  const l = join(dir, `${key}.jsonl.lock`);"],
    ["a manifest", "  const m = join(dir, \"manifest.json\");"],
    ["the folder", "  const d = join(specs, \"ledgers\", \"spec-rounds\");"],
    ["the old helper", "  const d = ledgerDir(specs);"],
    ["a suffix test", "  const k = names.filter(n => n.endsWith(\".jsonl\"));"],
    ["a comment", "  // the spec-rounds folder"],
    ["the manifest line with a wildcard-shaped tail", `${keep[1]} // ok`],
  ] as const) expect(x3Verdict(`${all}\n${extra}`, keep).unexpected, name).toEqual([extra]);
  const old = keep[1].replace("ledgerDirOf(specs)", "ledgerDir(specs)");
  expect(x3Verdict(all.replace(keep[1], old), keep), "the old spelling of the manifestFile line").toEqual({ unexpected: [old], missing: [keep[1]] });
  expect(x3Verdict(`${all}\n${keep[0]}`, keep), "a known line doubled").toEqual({ unexpected: [], missing: [keep[0]] });
  expect(x3Verdict(all.replace(keep[0], ""), keep), "a known line gone").toEqual({ unexpected: [], missing: [keep[0]] });
  const oldLib = "  if (await stat(join(specsRoot, 'ledgers', 'spec-rounds', 'manifest.json')).then(() => true, () => false)) await roundSeed(specsRoot);";
  expect(x3Verdict(oldLib, X3_LIB_KEEP), "the testlib's old spelling").toEqual({ unexpected: [oldLib], missing: [X3_LIB_KEEP[0]] });
});
test("X3 migration tripwire: every ledger-path construction in chief-route.ts and the capped-fold testlib is a shared name, but five known lines", () => {
  const route = readFileSync(join(import.meta.dir, "chief-route.ts"), "utf8"); const lib = readFileSync(join(import.meta.dir, "testlib-capped-fold.ts"), "utf8");
  expect(x3Verdict(route, X3_ROUTE_KEEP), "chief-route.ts").toEqual({ unexpected: [], missing: [] });
  expect(x3Verdict(lib, X3_LIB_KEEP), "testlib-capped-fold.ts").toEqual({ unexpected: [], missing: [] });
  for (const name of ["ledgerDirOf", "ledgerEntryNames", "ledgerKeyOfFile", "parseManifest"]) {
    expect(x3Imports(route), `chief-route.ts imports ${name}`).toContain(name);
    expect(route.split("\n").filter((line) => line.includes(`${name}(`) || line.includes(`(${name})`)).length, `chief-route.ts uses ${name}`).toBeGreaterThan(0);
  }
  for (const name of ["ledgerDirOf", "ledgerEntryNames"]) {
    expect(x3Imports(lib), `testlib imports ${name}`).toContain(name);
    expect(lib.includes(`${name}(`), `testlib uses ${name}`).toBe(true);
  }
});

type C3Fixture = { specsRoot: string; spec: string; plan: string; verdicts: string[]; ledgerPath: string };
type C3Shape = { verb: "READ" | "READ-SHA256"; order: "sha" | "sha2" | "legacy" };
const c3Shape = (verb: C3Shape["verb"], order: C3Shape["order"]): C3Shape => ({ verb, order });
const C3_SHAPES: C3Shape[] = (["READ-SHA256", "READ"] as const).flatMap(verb => (["sha", "sha2", "legacy"] as const).map(order => c3Shape(verb, order)));
const C3_MALFORMED = "capped-fold: malformed seal or READ quote";
const C3_DUPLICATE = "capped-fold: duplicate critic READ quotes";
const C3_CAP = "capped-fold: findings have not reached the refused round cap";
const C3_COVERAGE = "capped-fold: missing/extra ledger seals or review coverage";
const C3_KEYS = "capped return Keys? declaration disagrees with the declared keys";
const C3_REVIEWED = "capped return Reviewed declaration disagrees with the current spec";
const c3Heading = (line: string) => `capped-fold: ineligible finding heading: ${line}`;
const c3Flip = (hex: string) => (hex[0] === "a" ? "b" : "a") + hex.slice(1);

const c3Route = async (): Promise<any> => {
  const route: any = await import("./chief-route");
  for (const name of ["cappedReader", "cappedLedger", "cappedReturnEvidence", "readQuotesOf", "v2Policy"]) expect(typeof route[name], `${name} is reachable by an in-process caller`).toBe("function");
  expect(typeof route.v1Policy?.quotes, "v1Policy is reachable").toBe("function");
  return route;
};
// The helper exactly as cappedFold wires it for one kind: the canonical spec, one reader on its specs root, the real ledger load, then the helper.
const c3Kind = async (f: C3Fixture, kind: "spec" | "plan", policy: any, path = b1Kind(f, kind).at(-1)!) => {
  const route = await c3Route(); const key = route.keyOf(f.spec);
  const spec = realpathSync(f.spec); const plan = realpathSync(f.plan);
  expect(spec.startsWith(`${f.specsRoot}/`), "the canonical spec lies under the reader's specs root").toBe(true);
  const reader = route.cappedReader(f.specsRoot, key);
  const specRead = await reader.read(spec); const planRead = await reader.read(plan);
  const rows = await route.cappedLedger(f.specsRoot, key, reader);
  return route.cappedReturnEvidence({ key, kind, path, spec, plan, specSha: specRead.sha256, planSha: planRead.sha256, rows, reader }, policy);
};
const c3Both = async (f: C3Fixture, policy: any) => ({ spec: await c3Kind(f, "spec", policy), plan: await c3Kind(f, "plan", policy) });
const c3Message = async (run: Promise<unknown>): Promise<string> => {
  try { await run; } catch (error) { return (error as Error).message; }
  throw new Error("expected a refusal and the helper accepted");
};
const c3Edit = (f: C3Fixture, kind: "spec" | "plan", edit: (text: string) => string) => editCappedReturn(f, b1Kind(f, kind).at(-1)!, edit);
// The pin and the carried findings, computed from the actual return file and the actual ledger epoch, never from a stored hash.
const c3Expect = async (f: C3Fixture, kind: "spec" | "plan", got: any, round: number, epoch: number, carried: [string, string][]) => {
  const route: any = await import("./chief-route"); const path = b1Kind(f, kind).at(-1)!; const text = readFileSync(path, "utf8"); const key = route.keyOf(f.spec);
  expect(got.pin, `${kind} pin`).toEqual({ kind, path, sha256: sha(text), round, return_sha: route.returnSha(text), residuals: carried.length });
  expect(got.carried, `${kind} carried`).toEqual(carried.map(([id, severity]) => ({ key, epoch, kind, round, return_path: path, return_sha: route.returnSha(text), finding_id: id, severity, status: "open-carried" })));
};
const c3Requote = (text: string, shape: C3Shape) => text.replace(/^READ(?:-SHA256)? ([0-9a-f]{64}) (\S.*)$/gm, (_line, digest: string, path: string) =>
  shape.order === "legacy" ? `${shape.verb} ${path} ${digest}` : `${shape.verb} ${digest}${shape.order === "sha2" ? "  " : " "}${path}`);
const c3Quotes = (text: string) => [...text.matchAll(/^READ-SHA256 ([0-9a-f]{64}) (\S.*)$/gm)];
const c3BeforeSeals = (text: string, line: string) => text.replace(/^CONTENT-SHA256 /m, `${line}\nCONTENT-SHA256 `);
const c3Build = async (rounds: { kind: "spec" | "plan"; round: number; findings?: string; closure?: boolean }[]) => {
  const { buildRoundFixture } = await import("./testlib-capped-fold.ts");
  const reads = (kind: "spec" | "plan") => ["spec", ...(kind === "plan" ? ["plan"] : []), { path: "specs/designs/page.html", text: "<h1>Review page</h1>\n" },
    { path: "specs/designs/estimate.json", text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' }];
  const seen = { spec: 0, plan: 0 };
  const padded = rounds.flatMap(r => {
    const fill = Array.from({ length: Math.max(0, r.round - seen[r.kind] - 1) }, (_, i) => ({ kind: r.kind, round: seen[r.kind] + i + 1, findings: undefined, closure: undefined }));
    seen[r.kind] = r.round;
    return [...fill, r];
  });
  const returns = padded.map(r => {
    const findings = r.findings ?? ""; const count = findings.split("\n").filter(l => l.startsWith("- **")).length;
    return { kind: r.kind, round: r.round, closure: r.closure, text: `${findings ? `${findings}\n` : ""}${r.kind.toUpperCase()} ${count ? `FINDINGS ${count}` : "CLEAN"}\n`, reads: reads(r.kind) };
  });
  return buildRoundFixture({ scratchRoot: root(), key: cappedKey, specText: fixtureSpecText.replace("# HIMMEL", `Key: ${cappedKey}\n\n# HIMMEL`), planText: `---\ntickets: ${cappedKey}\n---\nKey: ${cappedKey}\n${fixturePlanText}`, returns });
};

test("3c availability: the helper, both policies and the quote reader are reachable in process, and v2Policy builds a fresh policy of the four decisions", async () => {
  const route = await c3Route(); const first = route.v2Policy([cappedKey]); const second = route.v2Policy([cappedKey]);
  for (const policy of [route.v1Policy, first]) for (const name of ["declaration", "reviewed", "headingOk", "quotes"]) expect(typeof policy[name], name).toBe("function");
  expect(first).not.toBe(second); expect(first).not.toBe(route.v1Policy);
});

test("3c v1Policy keeps its strict decisions: one quote shape, exactly minor or medium, one Key line and exactly one Reviewed line", async () => {
  const route = await c3Route(); const v1 = route.v1Policy; const S = "c3".repeat(32); const p = "/work/page.md"; const specSha = "d4".repeat(32);
  for (const verb of ["READ", "READ-SHA256"]) expect(v1.quotes(`${verb} ${S} ${p}`), verb).toEqual([{ sha: S, path: p }]);
  for (const line of [`READ-SHA256 ${S}  ${p}`, `READ-SHA256 ${p} ${S}`, `READ-SHA256 ${S}   ${p}`, `READ-SHA256 ${S.toUpperCase()} ${p}`, "READ", "READ-SHA256"]) expect(() => v1.quotes(line), line).toThrow(C3_MALFORMED);
  for (const ok of ["minor", "medium"]) expect(v1.headingOk(ok), ok).toBe(true);
  for (const bad of ["medium; Fact overlap", "major", "Minor", " medium", "minor; regression", ""]) expect(v1.headingOk(bad), bad).toBe(false);
  expect(() => v1.declaration("Fixture: no key\n", cappedKey), "no Key line: the ledger row binds the key").not.toThrow();
  expect(() => v1.declaration("Key: HIMMEL-99\n", cappedKey)).toThrow(`capped-fold: return must declare only ${cappedKey}`);
  expect(() => v1.declaration(`Key: ${cappedKey}\nKey: ${cappedKey}\n`, cappedKey)).toThrow(`capped-fold: return must declare only ${cappedKey}`);
  expect(() => v1.declaration(`Key: ${cappedKey}\n`, cappedKey)).not.toThrow();
  expect(() => v1.reviewed("Fixture: none\n", specSha, "spec")).toThrow("capped-fold: spec must review the current spec exactly once");
  expect(() => v1.reviewed(`Reviewed: spec ${specSha}\n`, specSha, "plan")).not.toThrow();
  expect(() => v1.reviewed(`Reviewed: spec ${specSha}\nReviewed: spec ${specSha}\n`, specSha, "plan")).toThrow("capped-fold: plan must review the current spec exactly once");
});

test("Q1 readQuotesOf: exactly two anchored shapes at column zero, a space or two after the sha, the legacy path absolute; every other READ line refuses", async () => {
  const route = await c3Route(); const S = "a1".repeat(32); const T = "0f".repeat(32); const p = "/work/specs/designs/page.md";
  const parse = (...lines: string[]) => route.readQuotesOf(["Fixture: x", ...lines, "SPEC CLEAN", ""].join("\n"));
  for (const verb of ["READ", "READ-SHA256"]) {
    expect(parse(`${verb} ${S} ${p}`), `${verb} sha then path`).toEqual([{ sha: S, path: p }]);
    expect(parse(`${verb} ${S}  ${p}`), `${verb} sha, two spaces, path`).toEqual([{ sha: S, path: p }]);
    expect(parse(`${verb} ${S} rel/page.md`), `${verb} sha first may name a relative path`).toEqual([{ sha: S, path: "rel/page.md" }]);
    expect(parse(`${verb} ${p} ${S}`), `${verb} legacy absolute path then sha`).toEqual([{ sha: S, path: p }]);
  }
  expect(parse(`READ-SHA256 ${S} ${p}`, "READING notes", `prose READ ${T}`, ` READ-SHA256 ${T} /indented.md`, `READ ${p}b ${T}`, `CONTENT-SHA256 ${S} page.md`),
    "lines that are not column-zero READ lines are not quotes; the quotes keep their line order").toEqual([{ sha: S, path: p }, { sha: T, path: `${p}b` }]);
  expect(parse()).toEqual([]);
  for (const [what, line] of [
    ["three spaces after the sha", `READ-SHA256 ${S}   ${p}`], ["a tab after the verb", `READ-SHA256\t${S} ${p}`], ["a tab after the sha", `READ-SHA256 ${S}\t${p}`],
    ["an uppercase sha", `READ-SHA256 ${S.toUpperCase()} ${p}`], ["a 63 digit sha", `READ-SHA256 ${S.slice(1)} ${p}`], ["a 65 digit sha", `READ-SHA256 ${S}0 ${p}`],
    ["a sha with no path", `READ-SHA256 ${S}`], ["a sha and a trailing space only", `READ-SHA256 ${S} `], ["a lowercase algorithm word", `READ sha256 ${S}`],
    ["a role word before the path", `READ-SHA256 SPEC ${p}`], ["a role word, a path and a sha", `READ-SHA256 SPEC ${p} ${S}`],
    ["a relative legacy path", `READ-SHA256 rel/page.md ${S}`], ["a dot-relative legacy path", `READ-SHA256 ./page.md ${S}`],
    ["an uppercase legacy sha", `READ-SHA256 ${p} ${S.toUpperCase()}`], ["a legacy line with a trailing space", `READ-SHA256 ${p} ${S} `], ["two spaces before the legacy sha", `READ-SHA256 ${p}  ${S}`],
    ["a carriage return after the path", `READ-SHA256 ${S} ${p}\r`], ["a carriage return after the legacy sha", `READ-SHA256 ${p} ${S}\r`],
    ["a bare READ", "READ"], ["a bare READ-SHA256", "READ-SHA256"], ["READ and a space", "READ "],
  ] as const) expect(() => parse(line), what).toThrow(C3_MALFORMED);
  expect(() => parse(`READ-SHA256 ${S} ${p}`, "READ-SHA256 unknown file.md"), "one malformed line refuses the whole return").toThrow(C3_MALFORMED);
  expect(parse(`READ-SHA256 ${S} ${p} `), "a trailing space after a sha-first path stays part of the path, never trimmed").toEqual([{ sha: S, path: `${p} ` }]);
});

test("Q1 v2 quotes: each accepted shape, in either return and mixed across the two, reads as the same sealed evidence and equals the seals", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const build = () => cappedFixture({ planFindings: "- **P1** (minor) a plan wording note" });
  const control = await build(); const expected = await c3Both(control, policy);
  await c3Expect(control, "spec", expected.spec, 5, 0, [["F1", "minor"]]); await c3Expect(control, "plan", expected.plan, 5, 0, [["P1", "minor"]]);
  const sealed = (text: string, path: string) => [...text.matchAll(/^CONTENT-SHA256 ([0-9a-f]{64}) (\S.*)$/gm)].map(m => ({ sha: m[1], path: resolve(dirname(path), m[2]) }));
  for (const kind of ["spec", "plan"] as const) {
    const path = b1Kind(control, kind).at(-1)!; const text = readFileSync(path, "utf8");
    expect(sealed(text, path).length, `${kind} seals`).toBeGreaterThan(2);
    expect(route.readQuotesOf(text), `${kind}: the standard quotes are the seals, in order`).toEqual(sealed(text, path));
  }
  const pairs: [C3Shape, C3Shape][] = [...C3_SHAPES.map(s => [s, s] as [C3Shape, C3Shape]),
    [c3Shape("READ-SHA256", "sha2"), c3Shape("READ-SHA256", "legacy")], [c3Shape("READ-SHA256", "legacy"), c3Shape("READ", "sha")], [c3Shape("READ", "sha2"), c3Shape("READ", "legacy")]];
  for (const [specShape, planShape] of pairs) {
    const f = await build();
    for (const [kind, shape] of [["spec", specShape], ["plan", planShape]] as const) {
      const path = b1Kind(f, kind).at(-1)!; const before = readFileSync(path, "utf8");
      await c3Edit(f, kind, text => c3Requote(text, shape));
      const after = readFileSync(path, "utf8");
      expect(after === before, `${kind} ${JSON.stringify(shape)} rewrote the quote lines`).toBe(shape.verb === "READ-SHA256" && shape.order === "sha");
      expect(route.readQuotesOf(after), `${kind} ${JSON.stringify(shape)} parses to the same quotes`).toEqual(route.readQuotesOf(before));
    }
    const got = await c3Both(f, policy);
    await c3Expect(f, "spec", got.spec, 5, 0, [["F1", "minor"]]); await c3Expect(f, "plan", got.plan, 5, 0, [["P1", "minor"]]);
  }
}, S1B);

test("Q2 v2 quotes must equal the seals: an altered sha, swapped paths, a quote of an unsealed file and a sealed file without a quote each refuse, in every shape", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const shapes = [c3Shape("READ-SHA256", "sha"), c3Shape("READ-SHA256", "sha2"), c3Shape("READ-SHA256", "legacy"), c3Shape("READ", "legacy")];
  const faults: [string, (text: string, f: C3Fixture) => string, (f: C3Fixture) => string][] = [
    ["an altered sha", text => text.replace(/^(READ-SHA256 )([0-9a-f]{64})/m, (_line, verb: string, digest: string) => verb + c3Flip(digest)), f => `capped-fold: missing/conflicting critic READ quote: ${realpathSync(f.spec)}`],
    ["two paths swapped", text => { const [a, b] = c3Quotes(text); return text.replace(a[0], `READ-SHA256 ${a[1]} ${b[2]}`).replace(b[0], `READ-SHA256 ${b[1]} ${a[2]}`); },
      f => `capped-fold: missing/conflicting critic READ quote: ${realpathSync(f.spec)}`],
    ["a quote of an unsealed file", (text, f) => c3BeforeSeals(text, `READ-SHA256 ${c3Flip(sha(readFileSync(f.plan, "utf8")))} ${f.plan}`), () => C3_COVERAGE],
    ["a sealed file with no quote", text => text.replace(`${c3Quotes(text).at(-1)![0]}\n`, ""), f => `capped-fold: missing/conflicting critic READ quote: ${join(f.specsRoot, "designs", "estimate.json")}`],
  ];
  for (const shape of shapes) {
    const control = await cappedFixture(); await c3Edit(control, "spec", text => c3Requote(text, shape));
    await c3Expect(control, "spec", await c3Kind(control, "spec", policy), 5, 0, [["F1", "minor"]]);
    for (const [what, fault, message] of faults) {
      const f = await cappedFixture(); await c3Edit(f, "spec", text => c3Requote(fault(text, f), shape));
      expect(await c3Message(c3Kind(f, "spec", policy)), `${what} in ${JSON.stringify(shape)}`).toBe(message(f));
    }
  }
}, S1B);

test("Q3 v2 quotes: a duplicate artifact quote, an unknown shape, a relative legacy path, three spaces and an uppercase sha each refuse with the shipped words", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const first = (text: string) => c3Quotes(text)[0]; const last = (text: string) => c3Quotes(text).at(-1)!;
  const cases: [string, (text: string, f: C3Fixture) => string, string][] = [
    ["a duplicate quote with the same sha", text => c3BeforeSeals(text, first(text)[0]), C3_DUPLICATE],
    ["a duplicate quote with another sha", text => c3BeforeSeals(text, `READ-SHA256 ${c3Flip(first(text)[1])} ${first(text)[2]}`), C3_DUPLICATE],
    ["a duplicate quote spelled in the legacy order", text => c3BeforeSeals(text, `READ ${first(text)[2]} ${first(text)[1]}`), C3_DUPLICATE],
    ["a sha-only line", text => c3BeforeSeals(text, `READ-SHA256 ${first(text)[1]}`), C3_MALFORMED],
    ["a lowercase algorithm word", text => c3BeforeSeals(text, `READ sha256 ${first(text)[1]}`), C3_MALFORMED],
    ["a role word before the path", text => text.replace(first(text)[0], `READ-SHA256 SPEC ${first(text)[2]}`), C3_MALFORMED],
    ["a role word before a legacy quote", text => text.replace(first(text)[0], `READ-SHA256 SPEC ${first(text)[2]} ${first(text)[1]}`), C3_MALFORMED],
    ["a relative legacy path", text => text.replace(last(text)[0], `READ-SHA256 estimate.json ${last(text)[1]}`), C3_MALFORMED],
    ["three spaces after the sha", text => text.replace(first(text)[0], `READ-SHA256 ${first(text)[1]}   ${first(text)[2]}`), C3_MALFORMED],
    ["two spaces before the legacy sha", text => text.replace(first(text)[0], `READ-SHA256 ${first(text)[2]}  ${first(text)[1]}`), C3_MALFORMED],
    ["an uppercase sha", text => text.replace(first(text)[0], `READ-SHA256 ${first(text)[1].toUpperCase()} ${first(text)[2]}`), C3_MALFORMED],
    ["a bare READ", text => c3BeforeSeals(text, "READ"), C3_MALFORMED],
  ];
  const control = await cappedFixture(); await c3Expect(control, "spec", await c3Kind(control, "spec", policy), 5, 0, [["F1", "minor"]]);
  for (const [what, edit, message] of cases) {
    const f = await cappedFixture(); await c3Edit(f, "spec", text => edit(text, f));
    expect(await c3Message(c3Kind(f, "spec", policy)), what).toBe(message);
  }
  const spaced = await cappedFixture(); await c3Edit(spaced, "spec", text => text.replace(first(text)[0], `${first(text)[0]} `));
  expect(await c3Message(c3Kind(spaced, "spec", policy)), "a path with a trailing space is not trimmed into the real file, so its seal has no quote").toContain("missing/conflicting critic READ quote");
}, S1B);

test("Q4 v2 quotes: an altered seal line and a sealed file edited after the critic read each refuse in every shape, and so does a ledger seal row that disagrees", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  for (const shape of [c3Shape("READ-SHA256", "sha"), c3Shape("READ-SHA256", "sha2"), c3Shape("READ-SHA256", "legacy")]) {
    const seal = await cappedFixture(); await c3Edit(seal, "spec", text => c3Requote(text.replace(/^(CONTENT-SHA256 )([0-9a-f]{64})/m, (_line, verb: string, digest: string) => verb + c3Flip(digest)), shape));
    expect(await c3Message(c3Kind(seal, "spec", policy)), `an altered seal line in ${JSON.stringify(shape)}`).toBe(`capped-fold: seal provenance disagrees: ${realpathSync(seal.spec)}`);
    const edited = await cappedFixture(); await c3Edit(edited, "spec", text => c3Requote(text, shape));
    const page = join(edited.specsRoot, "designs", "page.html"); writeFileSync(page, `${readFileSync(page, "utf8")}<p>edited after the critic read it</p>\n`);
    expect(await c3Message(c3Kind(edited, "spec", policy)), `a sealed file edited after the read in ${JSON.stringify(shape)}`).toBe(`capped-fold: seal provenance disagrees: ${page}`);
    const row = await cappedFixture(); await c3Edit(row, "spec", text => c3Requote(text, shape));
    const rowPage = join(row.specsRoot, "designs", "page.html"); const returned = route.returnSha(readFileSync(b1Kind(row, "spec").at(-1)!, "utf8"));
    editLedger(row, rows => { const r = rows.find(x => x.row === "seal" && x.read_path === rowPage && x.return_sha === returned)!; r.read_sha = c3Flip(r.read_sha); });
    expect(await c3Message(c3Kind(row, "spec", policy)), `a ledger seal row that disagrees in ${JSON.stringify(shape)}`).toBe(`capped-fold: seal provenance disagrees: ${rowPage}`);
  }
}, S1B);

test("C1 v2 cap: the known single shape whose plan next round is admitted refuses at the cap rule with the shipped words, and its quotes and headings read", async () => {
  const route = await c3Route(); const lib = await b1Lib();
  const f = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "admittedNextRound" }); const key = route.keyOf(f.spec); const policy = route.v2Policy([key]);
  const state = await route.roundState(f.specsRoot, key);
  expect(state.plan).toBe(5); expect(state.next).toBe("closure"); expect(state.why).toContain("plan round 6: closure");
  await c3Expect(f, "spec", await c3Kind(f, "spec", policy), 7, 0, []);
  expect(await c3Message(c3Kind(f, "plan", policy)), "the admitted next round").toBe(C3_CAP);
  const refused = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" });
  await c3Expect(refused, "plan", await c3Kind(refused, "plan", policy), 6, 0, [["P6", "minor"], ["P7", "minor"]]);
}, S1B);

test("C2 v2 cap: the refusedCap closure shape carries its minors under legacy and two-space quotes, and a kind under the cap refuses even when the other kind is capped", async () => {
  const route = await c3Route(); const lib = await b1Lib();
  const f = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = route.keyOf(f.spec); const policy = route.v2Policy([key]);
  const state = await route.roundState(f.specsRoot, key);
  expect(state.plan).toBe(6); expect(state.next).toBe("none"); expect(state.why).toContain(`${key} writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)`);
  const got = await c3Both(f, policy);
  await c3Expect(f, "spec", got.spec, 7, 0, []); await c3Expect(f, "plan", got.plan, 6, 0, [["P6", "minor"], ["P7", "minor"]]);
  expect(readFileSync(b1Kind(f, "spec").at(-1)!, "utf8")).toMatch(/^READ-SHA256 [0-9a-f]{64}  \/\S+$/m);
  expect(readFileSync(b1Kind(f, "plan").at(-1)!, "utf8")).toMatch(/^READ-SHA256 \/\S+ [0-9a-f]{64}$/m);
  expect(await c3Message(c3Kind(f, "spec", route.v1Policy)), "the strict v1 policy refuses the same real bytes at its Reviewed step: the Key line is optional there too").toBe("capped-fold: spec must review the current spec exactly once");
  const finding = (id: string) => `- **${id}** (minor) a wording note`;
  const specCapped = await c3Build([1, 2, 3, 4, 5].map(round => ({ kind: "spec" as const, round, findings: finding("F1") })).concat([1, 2, 3, 4].map(round => ({ kind: "plan" as const, round, findings: round === 4 ? finding("P1") : "" }))));
  await c3Expect(specCapped, "spec", await c3Kind(specCapped, "spec", route.v2Policy([cappedKey])), 5, 0, [["F1", "minor"]]);
  expect(await c3Message(c3Kind(specCapped, "plan", route.v2Policy([cappedKey]))), "the plan has findings in its fourth round").toBe(C3_CAP);
  const planCapped = await c3Build([1, 2, 3, 4].map(round => ({ kind: "spec" as const, round, findings: round === 4 ? finding("F1") : "" })).concat([1, 2, 3, 4, 5].map(round => ({ kind: "plan" as const, round, findings: finding("P1") }))));
  await c3Expect(planCapped, "plan", await c3Kind(planCapped, "plan", route.v2Policy([cappedKey])), 5, 0, [["P1", "minor"]]);
  expect(await c3Message(c3Kind(planCapped, "spec", route.v2Policy([cappedKey]))), "the spec has findings in its fourth round").toBe(C3_CAP);
}, S1B);

test("C3 v2 cap: when the live override admits the next plan round, the blocking regression refuses at the heading step, before the cap check", async () => {
  const route = await c3Route(); const lib = await b1Lib();
  const f = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "overrideAdmitted" }); const key = route.keyOf(f.spec); const policy = route.v2Policy([key]);
  const status = await b1Status(f, key);
  expect(status.next).toBe("closure"); expect(status.why).toContain("plan round 7: closure"); expect(status.plan).toBe(6);
  expect(b1Rows(f).filter(r => r.row === "override")).toMatchObject([{ round_opened: 7 }]);
  await c3Expect(f, "spec", await c3Kind(f, "spec", policy), 7, 0, []);
  const line = readFileSync(b1Kind(f, "plan").at(-1)!, "utf8").split("\n").find(l => l.startsWith("- **PR1**"))!;
  expect(line).toContain("(major; regression)");
  expect(await c3Message(c3Kind(f, "plan", policy)), "the heading step, not the cap").toBe(c3Heading(line));
}, S1B);

test("F1 v2 headings: a plain minor, a plain medium and a contextual medium carry, on the real group fixture and on a standard one, where the strict heading refuses the contextual tag", async () => {
  const route = await c3Route(); const lib = await b1Lib();
  for (const reset of ["none", "new-stem"] as const) {
    const f = await lib.buildGroupFixture(realpathSync(root()), { reset }); const got = await c3Both(f, route.v2Policy(f.keys)); const epoch = reset === "none" ? 0 : 1;
    await c3Expect(f, "spec", got.spec, 5, epoch, [["F1", "medium"]]); await c3Expect(f, "plan", got.plan, 5, epoch, [["P1", "minor"]]);
    expect(readFileSync(b1Kind(f, "spec").at(-1)!, "utf8")).toContain("- **F1** (medium; Fact overlap)");
  }
  const f = await cappedFixture({ specFindings: ["- **F1** (minor) a wording fix", "- **F2** (medium) a scope note", "- **F3** (medium; Fact overlap) the contract overlaps an owner"].join("\n") });
  await c3Expect(f, "spec", await c3Kind(f, "spec", route.v2Policy([cappedKey])), 5, 0, [["F1", "minor"], ["F2", "medium"], ["F3", "medium"]]);
  expect(await c3Message(c3Kind(f, "spec", route.v1Policy))).toBe(c3Heading("- **F3** (medium; Fact overlap) the contract overlaps an owner"));
}, S1B);

test("F1 v2Policy.headingOk reads the heading as the ledger does: the first semicolon token is minor or medium and no other tag is reserved", async () => {
  const route = await c3Route(); const heading = route.v2Policy([cappedKey]).headingOk;
  for (const ok of ["minor", "medium", "medium; Fact overlap", "minor;Fact overlap", "medium; Fact overlap; Scope", " medium ; Fact overlap "]) expect(heading(ok), ok).toBe(true);
  for (const bad of ["major", "major; Fact overlap", "Minor", "MEDIUM", "", ";", "fact overlap; medium", "critical", "medium; operator-critical: spend-grant", "minor; operator-critical: account-or-terms",
    "medium; operator-critical: unknown", "medium; operator-critical:", "minor; reopens M1", "medium; regression", "minor; Fact overlap; regression", "minor; regression; Fact overlap"]) expect(heading(bad), bad).toBe(false);
});

test("F2 v2 headings: a reserved tag, an unknown operator-critical subtype, a reopen, a regression and a major each refuse at the heading step on a real return", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const control = await cappedFixture(); await c3Expect(control, "spec", await c3Kind(control, "spec", policy), 5, 0, [["F1", "minor"]]);
  for (const heading of ["medium; operator-critical: spend-grant", "medium; operator-critical: unknown", "medium; operator-critical:", "minor; reopens M1", "medium; regression", "minor; Fact overlap; regression", "major", "major; Fact overlap", "Minor", "fact overlap; medium", ""]) {
    const f = await cappedFixture(); const line = `- **F1** (${heading}) carry this wording fix`;
    await c3Edit(f, "spec", text => text.replace("- **F1** (minor) carry this wording fix", line));
    expect(await c3Message(c3Kind(f, "spec", policy)), heading).toBe(c3Heading(line));
  }
  const second = await cappedFixture({ specFindings: "- **F1** (minor) a wording fix\n- **F2** (medium; regression) the second heading is reserved" });
  expect(await c3Message(c3Kind(second, "spec", policy)), "a later heading is judged too").toBe(c3Heading("- **F2** (medium; regression) the second heading is reserved"));
  for (const heading of ["major", "medium; regression", "medium; operator-critical: unknown", "minor; reopens F0"]) {
    const real = await cappedFixture({ specFindings: `- **F1** (${heading}) the real ledger holds this heading` });
    expect(await c3Message(c3Kind(real, "spec", policy)), `a real ledger row: ${heading}`).toBe(c3Heading(`- **F1** (${heading}) the real ledger holds this heading`));
  }
  const critical = await cappedFixture({ specFindings: "- **F1** (medium; operator-critical: spend-grant) the real ledger holds an open critical finding" });
  expect(await c3Message(c3Kind(critical, "spec", policy)), "an open operator-critical finding stops at the shared ledger check, before any policy").toBe("capped-fold: open historical operator-critical findings");
}, S1B);

test("F3 v2 findings: a hidden indented heading, an unrated count, a duplicate id, a ledger finding with an extra key and a wrong closure class stay common refusals", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]); const lib = await b1Lib();
  const hidden = await cappedFixture(); await c3Edit(hidden, "spec", text => text.replace("SPEC FINDINGS 1", "  - **F2** (minor) a hidden heading\nSPEC FINDINGS 1"));
  expect(await c3Message(c3Kind(hidden, "spec", policy)), "a hidden indented heading").toBe(c3Heading("  - **F2** (minor) a hidden heading"));
  const unrated = await cappedFixture(); await c3Edit(unrated, "spec", text => text.replace("SPEC FINDINGS 1", "SPEC FINDINGS 2"));
  expect(await c3Message(c3Kind(unrated, "spec", policy)), "an unrated count").toBe("capped-fold: finding count/IDs do not agree");
  const duplicate = await cappedFixture({ specFindings: "- **F1** (minor) one note\n- **F1** (minor) the same id again" });
  expect(await c3Message(c3Kind(duplicate, "spec", policy)), "a duplicate id").toBe("capped-fold: finding count/IDs do not agree");
  const extra = await cappedFixture(); editLedger(extra, rows => { rows.filter(r => r.row === "round" && r.critic === "spec").at(-1)!.findings[0].note = "extra"; });
  expect(await c3Message(c3Kind(extra, "spec", policy)), "a ledger finding with an extra key").toBe("capped-fold: ledger findings do not agree or are blocking");
  const surplus = await cappedFixture(); editLedger(surplus, rows => { rows.filter(r => r.row === "round" && r.critic === "spec").at(-1)!.findings.push({ id: "F9", severity: "minor" }); });
  expect(await c3Message(c3Kind(surplus, "spec", policy)), "a ledger row that holds a finding the return does not").toBe("capped-fold: finding count/IDs do not agree");
  const full = await cappedFixture(); editLedger(full, rows => { rows.filter(r => r.row === "round" && r.critic === "spec").at(-1)!.findings[0].class = "out-of-closure"; });
  expect(await c3Message(c3Kind(full, "spec", policy)), "a class on a full row").toBe("capped-fold: ledger findings do not agree or are blocking");
  const known = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = route.keyOf(known.spec); const knownPolicy = route.v2Policy([key]);
  await c3Expect(known, "plan", await c3Kind(known, "plan", knownPolicy), 6, 0, [["P6", "minor"], ["P7", "minor"]]);
  editLedger(known, rows => { rows.filter(r => r.row === "round" && r.critic === "plan").at(-1)!.findings[0].class = "reopens"; });
  expect(await c3Message(c3Kind(known, "plan", knownPolicy)), "a closure class other than out-of-closure").toBe("capped-fold: ledger findings do not agree or are blocking");
}, S1B);

test("F9 v2 headings: a closure major is nonblocking yet never carries, and the same closure return with a minor carries", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const run = (severity: "major" | "minor") => c3Build([{ kind: "spec", round: 1, findings: "- **F1** (minor) a wording fix" }, { kind: "spec", round: 2, findings: "- **F2** (minor) another wording fix" },
    { kind: "spec", round: 5, findings: "- **M1** (major) the contract omits a member" }, { kind: "spec", round: 6, findings: `- **C1** (${severity}) a closure note`, closure: true }]);
  const major = await run("major"); const state = await route.roundState(major.specsRoot, cappedKey);
  const row = b1Rows(major).filter(r => r.row === "round" && r.critic === "spec").at(-1);
  expect(row).toMatchObject({ round: 6, mode: "closure", findings: [{ id: "C1", severity: "major", class: "out-of-closure" }] });
  expect(state.why, "the ledger refuses the next round, so only the heading stands in the way").toContain(`spec round 7: ${cappedKey} writer round 7 needs a round-critical record with the operator's words (--decision and --quote; under decision 1418 a chief decision file quotes them and gives its reason)`);
  expect(await c3Message(c3Kind(major, "spec", policy))).toBe(c3Heading("- **C1** (major) a closure note"));
  const minor = await run("minor"); await c3Expect(minor, "spec", await c3Kind(minor, "spec", policy), 6, 0, [["C1", "minor"]]);
}, S1B);

test("D6 v2 declarations: Key and Reviewed absent or equal are accepted, wrong or doubled refuse at their own step, and the declaration step fires first", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]); const lines = (text: string, prefix: string) => text.split("\n").filter(l => l.startsWith(prefix));
  const control = await cappedFixture();
  for (const kind of ["spec", "plan"] as const) { const text = readFileSync(b1Kind(control, kind).at(-1)!, "utf8"); expect(lines(text, "Key:").length, `${kind} control Key`).toBe(1); expect(lines(text, "Reviewed:").length, `${kind} control Reviewed`).toBe(1); }
  await c3Expect(control, "spec", await c3Kind(control, "spec", policy), 5, 0, [["F1", "minor"]]); await c3Expect(control, "plan", await c3Kind(control, "plan", policy), 5, 0, []);
  const strip = (pattern: RegExp) => (text: string) => text.replace(pattern, "");
  const strictReviewed = "capped-fold: spec must review the current spec exactly once";
  for (const [what, edit, strict] of [["both absent", strip(/^(?:Key|Reviewed): .*\n/gm), strictReviewed], ["Key absent", strip(/^Key: .*\n/m), null], ["Reviewed absent", strip(/^Reviewed: .*\n/m), strictReviewed]] as const) {
    const f = await cappedFixture(); await c3Edit(f, "spec", edit); await c3Edit(f, "plan", edit);
    const got = await c3Both(f, policy); await c3Expect(f, "spec", got.spec, 5, 0, [["F1", "minor"]]); await c3Expect(f, "plan", got.plan, 5, 0, []);
    if (strict) expect(await c3Message(c3Kind(f, "spec", route.v1Policy)), `${what}: the strict policy refuses the same bytes`).toBe(strict);
    else await c3Kind(f, "spec", route.v1Policy);
  }
  const wrongSha = (text: string) => text.replace(/^(Reviewed: spec )([0-9a-f]{64})/m, (_line, head: string, digest: string) => head + c3Flip(digest));
  const refused: [string, (text: string) => string, string][] = [
    ["a wrong Key", text => text.replace(`Key: ${cappedKey}`, "Key: HIMMEL-99"), C3_KEYS],
    ["a doubled Key", text => text.replace(`Key: ${cappedKey}`, `Key: ${cappedKey}\nKey: ${cappedKey}`), C3_KEYS],
    ["a wrong Reviewed", wrongSha, C3_REVIEWED],
    ["a doubled Reviewed", text => text.replace(/^Reviewed: .*$/m, line => `${line}\n${line}`), C3_REVIEWED],
    ["a malformed Reviewed", text => text.replace(/^Reviewed: spec [0-9a-f]{64}/m, "Reviewed: spec not-a-sha"), C3_REVIEWED],
    ["both wrong: the declaration step first", text => wrongSha(text.replace(`Key: ${cappedKey}`, "Key: HIMMEL-99")), C3_KEYS],
  ];
  for (const kind of ["spec", "plan"] as const) for (const [what, edit, message] of refused) {
    const f = await cappedFixture(); await c3Edit(f, kind, edit);
    expect(await c3Message(c3Kind(f, kind, policy)), `${what} in the ${kind} return`).toBe(message);
  }
}, S1B);

test("D6 v2 declarations: a Keys line must name exactly the declared key set of a group, never just the anchor", async () => {
  const route = await c3Route(); const lib = await b1Lib();
  const add = (line: string) => (text: string) => text.replace(/^Fixture:/m, `${line}\nFixture:`);
  const build = async () => lib.buildGroupFixture(realpathSync(root()), { reset: "none" });
  const probe = await build(); const keys: string[] = probe.keys; const policy = route.v2Policy(keys);
  for (const line of [`Keys: ${keys.join(", ")}`, `Keys: [${[...keys].reverse().join(", ")}]`, `Key: ${keys.join(", ")}`]) {
    const f = await build(); await c3Edit(f, "spec", add(line)); await c3Edit(f, "plan", add(line));
    const got = await c3Both(f, policy); await c3Expect(f, "spec", got.spec, 5, 0, [["F1", "medium"]]); await c3Expect(f, "plan", got.plan, 5, 0, [["P1", "minor"]]);
  }
  for (const [what, line] of [["the anchor alone", `Key: ${keys[0]}`], ["six of seven", `Keys: ${keys.slice(0, 6).join(", ")}`], ["an extra key", `Keys: ${keys.join(", ")}, HIMMEL-99`], ["a repeated key", `Keys: ${[...keys.slice(0, 6), keys[0]].join(", ")}`]] as const) {
    const f = await build(); await c3Edit(f, "spec", add(line));
    expect(await c3Message(c3Kind(f, "spec", policy)), what).toBe(C3_KEYS);
  }
  const twice = await build(); await c3Edit(twice, "spec", add(`Keys: ${keys.join(", ")}\nKeys: ${keys.join(", ")}`));
  expect(await c3Message(c3Kind(twice, "spec", policy)), "two Keys lines").toBe(C3_KEYS);
}, S1B);

// ---- the v2 quote-line filter and the heading near-misses (follow-ups of the rows above) ----
type C3Quote = RegExpMatchArray;
const C3_PROSE: [string, (q: C3Quote) => string][] = [
  ["READY", () => "READY on R1 and R2. Both sealed."], ["READ colon", () => "READ: the spec twice"], ["README", () => "README first"], ["READING", () => "READING notes"],
  ["an indented READ-SHA512 quote", q => ` READ-SHA512 ${q[1]} ${q[2]}`], ["a mid-line READ-SHA512 quote", q => `see READ-SHA512 ${q[1]} ${q[2]}`],
];
const c3FirstQuote = (text: string) => c3Quotes(text)[0];

test("Q1 readQuotesOf: an unknown READ-prefixed spelling refuses, and READ-like prose is not a quote line", async () => {
  const route = await c3Route(); const S = "a1".repeat(32); const p = "/work/specs/designs/page.md";
  const parse = (...lines: string[]) => route.readQuotesOf(["Fixture: x", ...lines, "SPEC CLEAN", ""].join("\n"));
  for (const spelling of ["READ-SHA512", "READ-MD5", "READ-SHA1"]) {
    for (const line of [`${spelling} ${S} ${p}`, `${spelling} ${S}  ${p}`, `${spelling} ${p} ${S}`, spelling]) expect(() => parse(line), line).toThrow(C3_MALFORMED);
  }
  for (const [what, line] of C3_PROSE) expect(parse(line(["", S, p] as unknown as C3Quote)), `${what} is not a quote line`).toEqual([]);
  expect(() => parse(`READ-SHA256 ${S} ${p}`, `READ-SHA512 ${S} ${p}`), "a valid quote beside it does not make it a quote").toThrow(C3_MALFORMED);
});

test("Q1 v2 quotes: READ-SHA512 and READ-MD5 refuse at the helper, in place of a valid quote and beside a complete valid quote set", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  const control = await cappedFixture(); await c3Expect(control, "spec", await c3Kind(control, "spec", policy), 5, 0, [["F1", "minor"]]);
  for (const spelling of ["READ-SHA512", "READ-MD5"]) {
    for (const [what, line] of [["sha first", (q: C3Quote) => `${spelling} ${q[1]} ${q[2]}`], ["legacy order", (q: C3Quote) => `${spelling} ${q[2]} ${q[1]}`]] as const) {
      const beside = await cappedFixture(); await c3Edit(beside, "spec", text => c3BeforeSeals(text, line(c3FirstQuote(text))));
      expect(await c3Message(c3Kind(beside, "spec", policy)), `${spelling}, ${what}, beside a complete valid quote set`).toBe(C3_MALFORMED);
    }
    const replaced = await cappedFixture(); await c3Edit(replaced, "spec", text => text.replace(c3FirstQuote(text)[0], `${spelling} ${c3FirstQuote(text)[1]} ${c3FirstQuote(text)[2]}`));
    expect(await c3Message(c3Kind(replaced, "spec", policy)), `${spelling} in place of a valid quote`).toBe(C3_MALFORMED);
  }
}, S1B);

test("Q1 v2 quotes: READ-like prose beside a complete valid quote set stays prose and the return is accepted", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]);
  for (const [what, make] of C3_PROSE) {
    const f = await cappedFixture(); const line = make(c3FirstQuote(readFileSync(b1Kind(f, "spec").at(-1)!, "utf8")));
    await c3Edit(f, "spec", text => c3BeforeSeals(text, line));
    expect(readFileSync(b1Kind(f, "spec").at(-1)!, "utf8").split("\n"), `${what} sits in the return`).toContain(line);
    await c3Expect(f, "spec", await c3Kind(f, "spec", policy), 5, 0, [["F1", "minor"]]);
  }
}, S1B);

test("F1 v2Policy.headingOk follows parseFindings exactly: the near-misses the ledger reads as contextual carry, the tags it reads as reserved refuse", async () => {
  const route = await c3Route(); const policy = route.v2Policy([cappedKey]); const heading = policy.headingOk;
  const read = (parenthetical: string) => route.parseFindings(`- **x** (${parenthetical})\n`, "spec", 1).findings[0];
  for (const near of ["medium; Regression", "medium; regression test", "medium; operator-critical", "minor; reopens"]) {
    const finding = read(near); const severity = near.split(";")[0];
    expect(finding?.id, `${near}: parseFindings reads a finding`).toBe("x");
    expect([finding.critical, finding.critical_refused, finding.reopens, finding.regression], `${near}: parseFindings reads no reserved tag`).toEqual([undefined, undefined, undefined, undefined]);
    expect(heading(near), `${near}: headingOk agrees`).toBe(true);
    const f = await cappedFixture({ specFindings: `- **F1** (${near}) the real ledger holds this near-miss` });
    expect(b1Rows(f).filter(r => r.row === "round" && r.critic === "spec").at(-1).findings, `${near}: the ledger row reads the same finding`).toEqual([{ id: "F1", severity }]);
    await c3Expect(f, "spec", await c3Kind(f, "spec", policy), 5, 0, [["F1", severity]]);
  }
  for (const [reserved, field, value] of [["medium; operator-critical: spend-grant", "critical", "spend-grant"], ["medium; operator-critical: unknown", "critical_refused", "unknown"],
    ["minor; reopens M1", "reopens", "M1"], ["medium; regression", "regression", true], ["major", "severity", "major"]] as const) {
    expect(read(reserved)?.[field], `${reserved}: parseFindings reads the reserved field`).toBe(value);
    expect(heading(reserved), `${reserved}: headingOk agrees`).toBe(false);
  }
}, S1B);

const M3D_PRESENT = (keys: string[]) => `capped-fold: group member holds ledger state: ${keys.join(", ")}`;
const m3Route = async (): Promise<any> => {
  const route: any = await import("./chief-route");
  for (const name of ["cappedMemberState", "cappedReader", "cappedLedger"]) expect(typeof route[name], `${name} is reachable by an in-process caller`).toBe("function");
  return route;
};
const m3Group = async () => {
  const lib = await b1Lib(); const route = await m3Route(); const shared = await t2Pinned();
  const f = await lib.buildGroupFixture(realpathSync(root()), { reset: "none" });
  const reader = () => route.cappedReader(f.specsRoot, f.anchor);
  return { f, route, shared, dir: shared.ledgerDirOf(f.specsRoot) as string, reader, names: (key: string) => shared.ledgerEntryNames(key) as { file: string; folder: string; lock: string },
    state: (members: string[], r: any = reader()) => route.cappedMemberState(f.specsRoot, f.anchor, members, r) };
};
type M3Group = Awaited<ReturnType<typeof m3Group>>;
// A member's own ledger file, snapshot folder and lock as the real writer leaves them. The writer runs in a root of its own: the group's
// root already holds the anchor's ledger, and the writer refuses a second key there.
const m3Writer = async (key: string) => {
  const lib = await b1Lib(); const scratch = realpathSync(root());
  await lib.buildRoundFixture({ scratchRoot: scratch, key, specText: `---\ntickets: ${key}\n---\n# ${key} member\n`, planText: "# member plan\n",
    returns: [{ kind: "spec", round: 1, text: "SPEC CLEAN\n", reads: ["spec"] }] });
  return join(scratch, "specs", "ledgers", "spec-rounds");
};
const m3Put = async (g: M3Group, key: string, what: "file" | "folder" | "lock") => {
  const own = await m3Writer(key); const name = g.names(key)[what];
  if (what === "folder") cpSync(join(own, name), join(g.dir, name), { recursive: true }); else copyFileSync(join(own, name), join(g.dir, name));
  expect(existsSync(join(g.dir, name)), `${key} ${what} is in the group's ledger folder`).toBe(true);
};
const m3Manifest = (g: M3Group, edit: (manifest: any) => void) => {
  const path = join(g.dir, "manifest.json"); const manifest = JSON.parse(readFileSync(path, "utf8")); edit(manifest); writeFileSync(path, `${JSON.stringify(manifest)}\n`);
};
const m3Pin = (g: M3Group, members: string[]) => ({ role: "member-absence", directory: g.shared.ledgerDirOf(g.f.specsRoot), keys: [...members].sort() });
// A permission fault the sandbox user really feels; the mode is restored whatever happens so the scratch folder can be removed.
const m3Unreadable = async (path: string, run: () => Promise<void>) => {
  const mode = statSync(path).mode & 0o777; chmodSync(path, 0o000);
  try {
    expect(() => statSync(path).isDirectory() ? readdirSync(path) : readFileSync(path), "the permission fault is real for this user").toThrow();
    await run();
  } finally { chmodSync(path, mode); }
};

test("3d availability: cappedMemberState is reachable in process beside the reader and the ledger load", async () => {
  const route = await m3Route();
  expect(route.cappedMemberState.length, "specs, anchor, members and the reader").toBe(4);
});

test("3d member state: a group without member state returns the exact sorted pin for any input order, the anchor and strangers never count, and no member returns null", async () => {
  const g = await m3Group(); const pin = m3Pin(g, g.f.members); const anchor = g.names(g.f.anchor);
  expect(g.f.members).toHaveLength(6); expect(readdirSync(g.dir), "the anchor owns a ledger, a folder and a lock here").toEqual(expect.arrayContaining([anchor.file, anchor.folder, anchor.lock]));
  expect(await g.state(g.f.members)).toEqual(pin);
  expect(pin).toEqual({ role: "member-absence", directory: join(g.f.specsRoot, "ledgers", "spec-rounds"), keys: [...g.f.members].sort() });
  expect(await g.state(g.f.keys), "the whole declared key set, the anchor included").toEqual(pin);
  const k = g.f.keys;
  for (const order of [[...k].reverse(), [k[3], k[0], k[6], k[1], k[5], k[2], k[4]], [k[6], k[5], k[4], k[3], k[2], k[1]]]) expect(await g.state(order), order.join()).toEqual(pin);
  const given = [...k].reverse(); await g.state(given); expect(given, "the caller's array is not reordered").toEqual([...k].reverse());
  expect(pin.keys).not.toContain(g.f.anchor);
  m3Manifest(g, m => { m.keys[g.f.anchor] = { spec: 3, plan: 3 }; m.keys["HIMMEL-9999"] = { spec: 1, plan: 1 }; });
  writeFileSync(join(g.dir, "HIMMEL-9999.jsonl"), ""); mkdirSync(join(g.dir, "HIMMEL-9999"));
  expect(await g.state(g.f.keys), "the anchor's manifest entry and a stranger's ledger file, folder and manifest entry").toEqual(pin);
  for (const none of [[], [g.f.anchor]]) {
    const reader = g.reader(); expect(await g.state(none, reader), JSON.stringify(none)).toBeNull(); expect(reader.pins(), "no member: nothing is read").toEqual([]);
  }
}, S1B);

test("M1 a non-anchor member with its own ledger file, made by the real writer, refuses and names that member", async () => {
  for (const index of [0, 3, 5]) {
    const g = await m3Group(); const member = g.f.members[index]; await m3Put(g, member, "file");
    expect(await c3Message(g.state(g.f.members)), member).toBe(M3D_PRESENT([member]));
    expect(await c3Message(g.state(g.f.keys)), `${member}, the anchor in the input`).toBe(M3D_PRESENT([member]));
  }
  const two = await m3Group(); const [first, last] = [two.f.members[0], two.f.members[5]];
  await m3Put(two, last, "file"); await m3Put(two, first, "file");
  expect(await c3Message(two.state([...two.f.members].reverse())), "two members, named in sorted order").toBe(M3D_PRESENT([first, last]));
}, S1B);

test("M2 a member snapshot folder only refuses, with no ledger file and no manifest entry for it", async () => {
  for (const index of [0, 5]) {
    const g = await m3Group(); const member = g.f.members[index]; await m3Put(g, member, "folder");
    expect(readdirSync(g.dir), "the folder stands alone").not.toContain(g.names(member).file);
    expect(Object.keys(JSON.parse(readFileSync(join(g.dir, "manifest.json"), "utf8")).keys), "no manifest entry").toEqual([]);
    expect(await c3Message(g.state(g.f.members)), member).toBe(M3D_PRESENT([member]));
  }
}, S1B);

test("M3 a member manifest entry only refuses, with no ledger file and no folder for it", async () => {
  for (const index of [0, 2, 5]) {
    const g = await m3Group(); const member = g.f.members[index]; m3Manifest(g, m => { m.keys[member] = { spec: 1, plan: 1 }; });
    expect(readdirSync(g.dir), "the entry stands alone: no ledger file").not.toContain(g.names(member).file);
    expect(readdirSync(g.dir), "the entry stands alone: no folder").not.toContain(g.names(member).folder);
    expect(await c3Message(g.state(g.f.members)), member).toBe(M3D_PRESENT([member]));
  }
  const both = await m3Group(); m3Manifest(both, m => { m.keys[both.f.members[4]] = { spec: 1, plan: 1 }; m.keys[both.f.members[1]] = { spec: 1, plan: 1 }; });
  expect(await c3Message(both.state(both.f.keys)), "two entries, sorted").toBe(M3D_PRESENT([both.f.members[1], both.f.members[4]]));
}, S1B);

test("M4 a malformed member ledger, a ledger that is a folder or a dangling link, and an unreadable ledger or folder refuse as present, never as absent", async () => {
  const shapes: [string, (g: M3Group, key: string) => void][] = [
    ["garbage bytes", (g, key) => writeFileSync(join(g.dir, g.names(key).file), "this is not a ledger\n{\n")],
    ["an empty file", (g, key) => writeFileSync(join(g.dir, g.names(key).file), "")],
    ["a folder in its place", (g, key) => mkdirSync(join(g.dir, g.names(key).file))],
    ["a dangling link", (g, key) => symlinkSync(join(g.dir, "no-such-target"), join(g.dir, g.names(key).file))],
    ["a plain file where the snapshot folder belongs", (g, key) => writeFileSync(join(g.dir, g.names(key).folder), "not a folder")],
  ];
  for (const [what, make] of shapes) {
    const g = await m3Group(); const member = g.f.members[2]; make(g, member);
    expect(await c3Message(g.state(g.f.members)), what).toBe(M3D_PRESENT([member]));
  }
  const file = await m3Group(); const owner = file.f.members[1]; await m3Put(file, owner, "file");
  await m3Unreadable(join(file.dir, file.names(owner).file), async () => { expect(await c3Message(file.state(file.f.members)), "an unreadable member ledger file").toBe(M3D_PRESENT([owner])); });
  const folder = await m3Group(); const holder = folder.f.members[4]; await m3Put(folder, holder, "folder");
  await m3Unreadable(join(folder.dir, folder.names(holder).folder), async () => { expect(await c3Message(folder.state(folder.f.members)), "an unreadable member snapshot folder").toBe(M3D_PRESENT([holder])); });
}, S1B);

test("M4 a read fault of the ledger folder or the manifest refuses with its own words and is never read as absence", async () => {
  const group = async () => m3Group();
  const folder = await group();
  await m3Unreadable(folder.dir, async () => {
    const message = await c3Message(folder.state(folder.f.members));
    expect(message, "an unreadable ledger folder: the reader's own refusal, naming the folder").toContain("EACCES"); expect(message).toContain(folder.dir);
  });
  const gone = await group(); rmSync(gone.dir, { recursive: true });
  expect(await c3Message(gone.state(gone.f.members)), "a ledger folder that is gone").toBe(`no round manifest under ${gone.f.specsRoot}; run round-seed --all once`);
  const missing = await group(); unlinkSync(join(missing.dir, "manifest.json"));
  expect(await c3Message(missing.state(missing.f.members)), "a missing manifest").toBe(`no round manifest under ${missing.f.specsRoot}; run round-seed --all once`);
  const unreadable = await group(); const manifest = join(unreadable.dir, "manifest.json");
  await m3Unreadable(manifest, async () => { expect(await c3Message(unreadable.state(unreadable.f.members)), "an unreadable manifest").toContain(`${manifest}: cannot read the round manifest`); });
  for (const text of ["not json at all", "[]", '{"keys":[]}', '{"keys":null}', '{"v":1}']) {
    const bad = await group(); writeFileSync(join(bad.dir, "manifest.json"), `${text}\n`);
    expect(await c3Message(bad.state(bad.f.members)), `a manifest of ${text}`).toBe(`${join(bad.dir, "manifest.json")}: the round manifest does not parse; restore it from the state repo history`);
  }
  const wide = await group(); for (let i = 0; i < 4097; i++) writeFileSync(join(wide.dir, `pad-${i}`), "");
  expect(await c3Message(wide.state(wide.f.members)), "an over-bounded listing").toBe(`${wide.dir}: directory entry limit (4096) exceeded`);
}, S1B);

test("M5 a member lock file only is accepted, because a lock is not a ledger fact", async () => {
  const g = await m3Group(); const pin = m3Pin(g, g.f.members);
  await m3Put(g, g.f.members[0], "lock");
  expect(readdirSync(g.dir)).toContain(g.names(g.f.members[0]).lock); expect(readdirSync(g.dir)).not.toContain(g.names(g.f.members[0]).file);
  expect(await g.state(g.f.members), "one member lock").toEqual(pin);
  for (const member of g.f.members.slice(1)) writeFileSync(join(g.dir, g.names(member).lock), "");
  expect(readdirSync(g.dir).filter(n => n.endsWith(".jsonl.lock")), "every member holds a lock beside the anchor's and the seed's").toHaveLength(8);
  expect(await g.state(g.f.keys), "a lock for every member").toEqual(pin);
  await m3Put(g, g.f.members[3], "file");
  expect(await c3Message(g.state(g.f.members)), "a lock does not hide a ledger file beside it").toBe(M3D_PRESENT([g.f.members[3]]));
}, S1B);

test("3d member state: the listing and the manifest are read through the reader, so a member that appears after the check fails the reader's recheck", async () => {
  const g = await m3Group(); const reader = g.reader(); const pin = m3Pin(g, g.f.members);
  await g.route.cappedLedger(g.f.specsRoot, g.f.anchor, reader);
  expect(await g.state(g.f.members, reader)).toEqual(pin);
  const manifest = join(g.dir, "manifest.json");
  expect(reader.pins().filter((p: any) => p.role === "manifest"), "the anchor's load and the member check pin the manifest once").toEqual([{ role: "manifest", path: manifest, sha256: sha(readFileSync(manifest, "utf8")) }]);
  await expect(reader.recheck()).resolves.toBeUndefined();
  await m3Put(g, g.f.members[2], "file");
  await expect(reader.recheck(), "a member ledger file created after the check").rejects.toThrow(`capped-fold: evidence changed or is unreadable: ${g.dir}`);
  const second = await m3Group(); const again = second.reader(); await second.state(second.f.members, again);
  m3Manifest(second, m => { m.keys[second.f.members[0]] = { spec: 1, plan: 1 }; });
  await expect(again.recheck(), "a manifest entry written after the check").rejects.toThrow(`capped-fold: evidence changed or is unreadable: ${join(second.dir, "manifest.json")}`);
}, S1B);

const N3_UNACCOUNTED = (path: string) => `capped-fold: ambiguous or unaccounted latest return: ${path}`;
const n3Route = async (): Promise<any> => {
  const route: any = await import("./chief-route");
  for (const name of ["cappedHistory", "cappedLatest", "cappedReader", "cappedLedger", "cappedReturnEvidence", "v2Policy"]) expect(typeof route[name], `${name} is reachable by an in-process caller`).toBe("function");
  return route;
};
// The fold as the verifier will wire it, up to the namespace: the canonical spec, one reader, the real ledger load, both returns through the helper
// with the v2 policy, then the proven history. `latest()` runs the namespace check with that history, `v1()` without any.
const n3Fold = async (f: C3Fixture, keys: string[]) => {
  const route = await n3Route(); const key = route.keyOf(f.spec); const spec = realpathSync(f.spec); const plan = realpathSync(f.plan);
  const reader = route.cappedReader(f.specsRoot, key); const specRead = await reader.read(spec); const planRead = await reader.read(plan);
  const rows = await route.cappedLedger(f.specsRoot, key, reader); const policy = route.v2Policy(keys); const pins: any[] = [];
  for (const kind of ["spec", "plan"] as const) {
    pins.push((await route.cappedReturnEvidence({ key, kind, path: b1Kind(f, kind).at(-1)!, spec, plan, specSha: specRead.sha256, planSha: planRead.sha256, rows, reader }, policy)).pin);
  }
  const history = await route.cappedHistory(rows, pins.map(p => p.path), reader);
  return { route, key, spec, plan, reader, rows, pins, history, latest: () => route.cappedLatest(spec, plan, reader, pins, history.set), v1: () => route.cappedLatest(spec, plan, reader, pins) };
};
const n3NewStem = async () => { const lib = await b1Lib(); return lib.buildGroupFixture(realpathSync(root()), { reset: "new-stem" }); };
// A file dropped into a scanned folder after a first accepted fold; a second fold with a fresh reader then reads the folder again.
const n3Intruder = async (make: (f: any) => { from: string; to: string }) => {
  const f = await n3NewStem(); const before = await n3Fold(f, f.keys);
  await expect(before.latest(), "control: accepted before the file appears").resolves.toBeUndefined();
  const { from, to } = make(f); copyFileSync(from, to);
  const after = await n3Fold(f, f.keys);
  await expect(after.latest(), "with the proven history").rejects.toThrow(N3_UNACCOUNTED(to));
  await expect(after.v1(), "without history the group is refused too, at whichever unaccounted file sorts first").rejects.toThrow(N3_UNACCOUNTED(""));
  return { f, to };
};

test("3e availability: cappedHistory and the namespace check are reachable in process", async () => {
  const route = await n3Route();
  expect(route.cappedHistory.length, "rows, current paths and the reader").toBe(3);
  expect(route.cappedLatest.length, "spec, plan, reader, expected pins and the optional proven history").toBeGreaterThanOrEqual(4);
});

test("N1 the new-stem group's seven preserved earlier-epoch files are the proven history, pinned through the reader, and the namespace accepts them", async () => {
  const f = await n3NewStem(); const g = await n3Fold(f, f.keys); const earlier = [...f.earlier].sort();
  expect(f.earlier).toHaveLength(7); expect(g.rows.checked.epoch).toBe(1);
  expect([...g.history.set].sort()).toEqual(earlier);
  expect(g.history.pins).toEqual(earlier.map(path => ({ role: "history", path, sha256: sha(readFileSync(path, "utf8")) })));
  expect(g.reader.pins().filter((p: any) => p.role === "history"), "the same pins live in the reader").toEqual(g.history.pins);
  expect(g.pins.map((p: any) => p.round), "the signed rounds").toEqual([5, 5]);
  expect(f.earlier.map((path: string) => Number(/-r(\d+)\.md$/.exec(path)![1])), "three of the seven are at or above the signed round").toEqual([1, 2, 3, 4, 5, 6, 7]);
  await expect(g.latest(), "with the proven history").resolves.toBeUndefined();
  await expect(g.v1(), "without it, the first file at or above the signed round is refused").rejects.toThrow(N3_UNACCOUNTED(f.earlier[4]));
  await expect(g.reader.recheck()).resolves.toBeUndefined();
}, S1B);

test("N1 a ledger with one epoch has no history: the known-single fixture proves nothing and the namespace is the v1 one", async () => {
  const lib = await b1Lib(); const f = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = basename(f.spec).replace(/-fixture\.md$/, "");
  const g = await n3Fold(f, [key]);
  expect(g.rows.checked.epoch).toBe(0); expect([...g.history.set]).toEqual([]); expect(g.history.pins).toEqual([]);
  expect(g.reader.pins().filter((p: any) => p.role === "history")).toEqual([]);
  await expect(g.latest()).resolves.toBeUndefined(); await expect(g.v1()).resolves.toBeUndefined();
}, S1B);

test("3e a seed row's latest returns are history only once the epoch is above zero, through the real seed and the real reset", async () => {
  const route = await n3Route(); const t = specsTree(); const [m] = wSeedable(t.specs, [ROUND_KEY]);
  expect((await routeCli("round-seed", "--all", t.specs)).code, "the real round-seed").toBe(0);
  const open = async () => { const reader = route.cappedReader(t.specs, ROUND_KEY); const rows = await route.cappedLedger(t.specs, ROUND_KEY, reader); return { reader, rows }; };
  const zero = await open();
  expect(zero.rows.checked.epoch).toBe(0);
  expect([...(await route.cappedHistory(zero.rows, [], zero.reader)).set], "at epoch zero the seeded return is current evidence, not history").toEqual([]);
  const quote = "start this ticket over from scratch"; const decision = join(t.specs, "decisions", "verbatim-decision-990-seed.txt");
  mkdirSync(join(t.specs, "decisions"), { recursive: true }); writeFileSync(decision, `${ROUND_KEY} ${quote}\n`);
  const later = new Date(Date.now() + 2000); utimesSync(decision, later, later);
  const marker = process.env.HIMMEL_CONSOLE; process.env.HIMMEL_CONSOLE = "1";
  try { await route.roundReset(t.specs, ROUND_KEY, { decision: "990", quote }); } finally { if (marker === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = marker; }
  const one = await open(); expect(one.rows.checked.epoch).toBe(1);
  const proven = await route.cappedHistory(one.rows, [], one.reader);
  expect([...proven.set]).toEqual([m.verdict]); expect(proven.pins).toEqual([{ role: "history", path: m.verdict, sha256: wSha(m.verdict) }]);
  expect(one.reader.pins().filter((p: any) => p.role === "history")).toEqual(proven.pins);
  const named = await open(); expect([...(await route.cappedHistory(named.rows, [m.verdict], named.reader)).set], "a path the caller names as current is not history").toEqual([]);
  writeFileSync(m.verdict, `${readFileSync(m.verdict, "utf8")}drift\n`);
  const drifted = await open(); const none = await route.cappedHistory(drifted.rows, [], drifted.reader);
  expect([...none.set], "bytes that no longer hash to the seeded digest").toEqual([]); expect(drifted.reader.pins().filter((p: any) => p.role === "history")).toEqual([]);
}, S1B);

test("N2 a fresh unsealed current spec return one round above the signed round is refused", async () => {
  await n3Intruder(f => { const from = b1Kind(f, "spec").at(-1)!; return { from, to: from.replace("r5.md", "r6.md") }; });
}, S1B);

test("N3 a fresh unsealed current plan return in plans/ is refused", async () => {
  await n3Intruder(f => { const from = b1Kind(f, "plan").at(-1)!; return { from, to: join(f.specsRoot, "plans", basename(from).replace("r5.md", "r6.md")) }; });
}, S1B);

test("N4 a second plan return of the signed round in another scanned folder, a tie, is refused", async () => {
  const { f, to } = await n3Intruder(f => { const from = b1Kind(f, "plan").at(-1)!; return { from, to: join(f.specsRoot, "plans", basename(from)) }; });
  expect(basename(to), "the tie has the signed round").toContain("critic-plan-r5.md"); expect(to).not.toBe(b1Kind(f, "plan").at(-1)!);
}, S1B);

test("N5 a new return under a foreign stem at or above the signed round is refused", async () => {
  await n3Intruder(f => { const from = b1Kind(f, "spec").at(-1)!; return { from, to: join(dirname(from), "HIMMEL-9801-foreign.md.critic-spec-r6.md") }; });
}, S1B);

test("N6 a history file whose bytes drifted is not history: refused at or above the signed round, and never pinned", async () => {
  const f = await n3NewStem(); const drift = (path: string) => writeFileSync(path, `${readFileSync(path, "utf8")}drifted after the reset\n`);
  drift(f.earlier[5]); const g = await n3Fold(f, f.keys);
  expect([...g.history.set].sort()).toEqual(f.earlier.filter((p: string) => p !== f.earlier[5]).sort());
  expect(g.history.pins.map((p: any) => p.path)).not.toContain(f.earlier[5]); expect(g.reader.pins().map((p: any) => p.path)).not.toContain(f.earlier[5]);
  await expect(g.latest()).rejects.toThrow(N3_UNACCOUNTED(f.earlier[5]));
  const low = await n3NewStem(); drift(low.earlier[0]); const h = await n3Fold(low, low.keys);
  expect([...h.history.set]).not.toContain(low.earlier[0]); expect(h.history.set.size).toBe(6);
  await expect(h.latest(), "below the signed round the v1 rule still passes it").resolves.toBeUndefined();
}, S1B);

test("N7 a history file whose ledger row was removed is not history: refused at or above the signed round", async () => {
  const f = await n3NewStem(); editLedger(f, rows => { const at = rows.findIndex(r => r.row === "round" && r.verdict_path === f.earlier[6]); expect(at, "the row of the last earlier return").toBeGreaterThan(-1); rows.splice(at, 1); });
  const g = await n3Fold(f, f.keys);
  expect([...g.history.set].sort()).toEqual(f.earlier.slice(0, 6).sort()); expect(g.reader.pins().map((p: any) => p.path)).not.toContain(f.earlier[6]);
  await expect(g.latest()).rejects.toThrow(N3_UNACCOUNTED(f.earlier[6]));
}, S1B);

test("N8 classification half: on the in-place group every earlier path is also a current row's path, so cappedHistory proves none of them", async () => {
  const lib = await b1Lib(); const f = await lib.buildGroupFixture(realpathSync(root()), { reset: "in-place" }); const g = await n3Fold(f, f.keys);
  const earlier = g.rows.filter((r: any) => r.row === "round" && (r.epoch ?? 0) === 0); const current = g.rows.filter((r: any) => r.row === "round" && r.epoch === 1);
  expect(g.rows.checked.epoch).toBe(1); expect(earlier).toHaveLength(5);
  for (const row of earlier) {
    const same = current.find((c: any) => c.verdict_path === row.verdict_path);
    expect(same, `${row.verdict_path} is a current row's path`).toBeDefined(); expect(same.return_sha, "its current digest is not its earlier digest").not.toBe(row.return_sha);
    expect(g.route.returnSha(readFileSync(row.verdict_path, "utf8")), "the current digest matches the rewritten bytes").toBe(same.return_sha);
  }
  expect([...g.history.set], "no earlier path is proven history").toEqual([]); expect(g.history.pins).toEqual([]);
  expect(g.reader.pins().filter((p: any) => p.role === "history")).toEqual([]);
  expect([...(await g.route.cappedHistory(g.rows, [], g.reader)).set], "with no path named as current: the ledger's own current rows already exclude them").toEqual([]);
}, S1B);

test("N8 classification half, isolated: a path a current round row uses is not history even when its bytes still hash to the earlier digest", async () => {
  const f = await n3NewStem(); const shared = f.earlier[5]; const route = await n3Route(); const key = route.keyOf(f.spec);
  editLedger(f, rows => { rows.find(r => r.row === "round" && r.epoch === 1 && r.critic === "spec" && r.round === 1)!.verdict_path = shared; });
  const reader = route.cappedReader(f.specsRoot, key); const rows = await route.cappedLedger(f.specsRoot, key, reader);
  const earlierRow = rows.find((r: any) => r.row === "round" && (r.epoch ?? 0) === 0 && r.verdict_path === shared);
  expect(route.returnSha(readFileSync(shared, "utf8")), "the bytes still hash to the earlier row's digest").toBe(earlierRow.return_sha);
  expect(rows.some((r: any) => r.row === "round" && r.epoch === 1 && r.verdict_path === shared), "a current row uses the path").toBe(true);
  const proven = await route.cappedHistory(rows, [], reader);
  expect([...proven.set].sort()).toEqual(f.earlier.filter((path: string) => path !== shared).sort()); expect(reader.pins().map((p: any) => p.path)).not.toContain(shared);
  const folded = await n3Fold(f, f.keys); expect(folded.history.set.has(shared), "the whole fold: still not history").toBe(false);
  await expect(folded.latest(), "and the reused path's file is refused as unaccounted, the plan's not history, refused").rejects.toThrow(N3_UNACCOUNTED(shared));
}, S1B);

test("N9 an unsealed historical file at or above the signed round is refused, and the same file below it is accepted as v1", async () => {
  const f = await n3NewStem(); const base = f.earlier[0].replace(/\.critic-spec-r1\.md$/, ""); const body = readFileSync(b1Kind(f, "plan").at(-1)!, "utf8");
  const old = (round: number) => `${base}.critic-plan-r${round}.md`;
  const g = await n3Fold(f, f.keys); await expect(g.latest(), "control").resolves.toBeUndefined();
  writeFileSync(old(6), body); const above = await n3Fold(f, f.keys);
  await expect(above.latest(), "an old-stem plan return at round 6, with no ledger row").rejects.toThrow(N3_UNACCOUNTED(old(6)));
  renameSync(old(6), old(4)); const below = await n3Fold(f, f.keys);
  await expect(below.latest(), "the same file named for round 4").resolves.toBeUndefined();
  const lib = await b1Lib(); const single = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = basename(single.spec).replace(/-fixture\.md$/, "");
  const stale = (round: number) => join(dirname(single.spec), `${basename(single.spec)}.critic-plan-r${round}.md`);
  writeFileSync(stale(7), readFileSync(b1Kind(single, "plan").at(-1)!, "utf8")); const hot = await n3Fold(single, [key]);
  await expect(hot.latest(), "single epoch: a plan return at round 7 with no ledger row, the signed plan round being 6").rejects.toThrow(N3_UNACCOUNTED(stale(7)));
  await expect(hot.v1()).rejects.toThrow(N3_UNACCOUNTED(stale(7)));
  renameSync(stale(7), stale(4)); const cold = await n3Fold(single, [key]);
  await expect(cold.v1(), "the same file named for round 4 is accepted as v1").resolves.toBeUndefined(); await expect(cold.latest()).resolves.toBeUndefined();
}, S1B);

test("N10 a kindless legacy name is compared with both kinds: the lower signed round decides, whichever kind holds it", async () => {
  const lib = await b1Lib(); const single = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = basename(single.spec).replace(/-fixture\.md$/, "");
  const kindless = (f: C3Fixture, round: number) => join(dirname(realpathSync(f.spec)), `${basename(f.spec)}.critic-r${round}.md`);
  const specReturn = b1Kind(single, "spec").at(-1)!; const first = await n3Fold(single, [key]);
  expect(first.pins.map((p: any) => [p.kind, p.round])).toEqual([["spec", 7], ["plan", 6]]);
  copyFileSync(specReturn, kindless(single, 5)); const low = await n3Fold(single, [key]);
  await expect(low.latest(), "round 5 is below both signed rounds").resolves.toBeUndefined();
  renameSync(kindless(single, 5), kindless(single, 6)); const mid = await n3Fold(single, [key]);
  await expect(mid.latest(), "round 6 is at the plan's signed round, below the spec's").rejects.toThrow(N3_UNACCOUNTED(kindless(single, 6)));
  await expect(mid.v1()).rejects.toThrow(N3_UNACCOUNTED(kindless(single, 6)));
  const finding = "- **P3** (major) a blocking plan note";
  const mixed = await c3Build([{ kind: "spec", round: 1 }, { kind: "spec", round: 2 }, { kind: "spec", round: 5 }, { kind: "plan", round: 1 }, { kind: "plan", round: 2 },
    { kind: "plan", round: 5, findings: finding }, { kind: "plan", round: 6, closure: true }]);
  const lower = await n3Fold(mixed, [cappedKey]);
  expect(lower.pins.map((p: any) => [p.kind, p.round])).toEqual([["spec", 5], ["plan", 6]]);
  copyFileSync(b1Kind(mixed, "spec").at(-1)!, kindless(mixed, 4)); const under = await n3Fold(mixed, [cappedKey]);
  await expect(under.latest(), "round 4 is below both").resolves.toBeUndefined();
  renameSync(kindless(mixed, 4), kindless(mixed, 5)); const spec = await n3Fold(mixed, [cappedKey]);
  await expect(spec.latest(), "round 5 is at the spec's signed round, below the plan's").rejects.toThrow(N3_UNACCOUNTED(kindless(mixed, 5)));
}, S1B);

test("N13 an aliased, an unreadable and an over-bounded scanned folder are refused as in v1: on the group with its history and on the single-epoch fixture with and without", async () => {
  const lib = await b1Lib();
  for (const fault of ["alias", "unreadable", "overflow"] as const) {
    const group = await n3NewStem(); const single = await lib.buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" }); const key = basename(single.spec).replace(/-fixture\.md$/, "");
    await expect((await n3Fold(group, group.keys)).latest(), `${fault}: group control`).resolves.toBeUndefined(); await expect((await n3Fold(single, [key])).v1(), `${fault}: v1 control`).resolves.toBeUndefined();
    const plant = (specsRoot: string) => {
      const directory = join(specsRoot, "design");
      if (fault === "alias") { const target = join(dirname(specsRoot), "alias-target"); mkdirSync(target); symlinkSync(target, directory); } else mkdirSync(directory);
      if (fault === "unreadable") chmodSync(directory, 0);
      if (fault === "overflow") for (let i = 0; i < 4097; i++) writeFileSync(join(directory, `irrelevant-${i}`), "");
      return { directory, message: { alias: `capped-fold: directory lookup must be canonical: ${directory}`, unreadable: `EACCES: permission denied, scandir '${directory}'`, overflow: `${directory}: directory entry limit (4096) exceeded` }[fault] };
    };
    const planted = [plant(group.specsRoot), plant(single.specsRoot)];
    try {
      await expect((await n3Fold(group, group.keys)).latest(), `${fault}: the group with its history`).rejects.toThrow(planted[0].message);
      const solo = await n3Fold(single, [key]);
      await expect(solo.latest(), `${fault}: single epoch with history`).rejects.toThrow(planted[1].message); await expect(solo.v1(), `${fault}: single epoch, v1`).rejects.toThrow(planted[1].message);
    } finally { if (fault === "unreadable") for (const p of planted) chmodSync(p.directory, 0o700); }
  }
}, S1B);

// ---- review follow-ups of the history seam: the peek-versus-pin guard, the any-digest choice and an unusable earlier path ----
test("3e the peek and the pinned read of a history file must agree: a reader that already holds other bytes for it refuses", async () => {
  const route = await n3Route(); const f = await n3NewStem(); const target = f.earlier[3]; const key = route.keyOf(f.spec);
  const reader = route.cappedReader(f.specsRoot, key); const rows = await route.cappedLedger(f.specsRoot, key, reader);
  const original = readFileSync(target, "utf8");
  writeFileSync(target, `${original}drifted while the reader looked\n`); await reader.read(target, "history");
  writeFileSync(target, original);
  await expect(route.cappedHistory(rows, [], reader), "the peek hashes to the ledger's digest, the reader holds other bytes").rejects.toThrow(`capped-fold: evidence changed or is unreadable: ${target}`);
  expect((await n3Fold(f, f.keys)).history.set.has(target), "control: through a fresh reader the same file is proven").toBe(true);
}, S1B);

test("3e a path recorded under several earlier digests is proven when any one of them matches its bytes", async () => {
  const route = await n3Route(); const stale = "0".repeat(64);
  const earlierRow = (rows: any[], path: string) => rows.find(r => r.row === "round" && (r.epoch ?? 0) === 0 && r.verdict_path === path);
  const build = async (edit: (rows: any[], older: string, newer: string) => void) => {
    const f = await n3NewStem(); const [, , , , older, newer] = f.earlier; const key = route.keyOf(f.spec);
    editLedger(f, rows => edit(rows, older, newer));
    const reader = route.cappedReader(f.specsRoot, key); const rows = await route.cappedLedger(f.specsRoot, key, reader);
    return { f, older, newer, set: (await route.cappedHistory(rows, [], reader)).set as ReadonlySet<string> };
  };
  const first = await build((rows, older, newer) => { earlierRow(rows, newer).verdict_path = older; });
  expect(first.set.has(first.older), "recorded first with a matching digest, then again with a stale one").toBe(true);
  expect(first.set.size, "the other six earlier files stay proven and the re-pointed one has no row left").toBe(6);
  const last = await build((rows, older, newer) => { const a = earlierRow(rows, older); const b = earlierRow(rows, newer); b.verdict_path = older; b.return_sha = a.return_sha; a.return_sha = stale; });
  expect(last.set.has(last.older), "recorded first with a stale digest, then again with a matching one").toBe(true);
  expect(route.returnSha(readFileSync(last.older, "utf8")), "the file's bytes are unchanged").not.toBe(stale);
  const none = await build((rows, older, newer) => { earlierRow(rows, newer).verdict_path = older; earlierRow(rows, older).return_sha = stale; });
  expect(none.set.has(none.older), "neither recorded digest matches").toBe(false); expect(none.set.size).toBe(5);
}, S1B);

test("3e an earlier path that is a link or not spelled canonically is not history instead of a refusal: below the signed round the v1 rule accepts it, at or above it the namespace refuses it", async () => {
  const link = (path: string) => { const copy = `${path}.elsewhere`; copyFileSync(path, copy); unlinkSync(path); symlinkSync(copy, path); };
  const spelled = (path: string) => `${dirname(path)}/../${basename(dirname(path))}/${basename(path)}`;
  const place = { 0: "below the signed round", 4: "at the signed round", 5: "above the signed round" } as const;
  for (const how of ["a link", "a spelling that is not canonical"] as const) {
    for (const index of [0, 4, 5] as const) {
      const f = await n3NewStem(); const target = f.earlier[index];
      if (how === "a link") link(target); else editLedger(f, rows => { rows.find(r => r.row === "round" && r.verdict_path === target).verdict_path = spelled(target); });
      const g = await n3Fold(f, f.keys); const label = `${how} ${place[index]}`;
      expect(g.history.set.has(target), `${label}: not history`).toBe(false); expect(g.history.set.size, `${label}: the other six stay proven`).toBe(6);
      expect(g.reader.pins().map((p: any) => p.path), label).not.toContain(target);
      if (index === 0) await expect(g.latest(), `${label}: accepted as v1`).resolves.toBeUndefined();
      else await expect(g.latest(), `${label}: refused as unaccounted`).rejects.toThrow(N3_UNACCOUNTED(target));
    }
  }
}, S1B);

// ---- the v2 assembly and the --keys verb form (rows D2, D3, D7, F4 to F8, N11, N12, L1, T1 to T4, the chief-route half of R1 and R2, and the v2 goals of G0a and G0b) ----
const F3_USAGE_KEYS = "capped-fold: capped-fold: requires exactly --keys, --spec, --plan, --spec-return and --plan-return, each once\n";
const F3_BOTH = "capped-fold: capped-fold: use exactly one of --key and --keys\n";
const F3_LIST = "capped-fold: capped-fold: expected one or more distinct ticket keys\n";
const f3Route = async (): Promise<any> => {
  const route: any = await import("./chief-route");
  for (const name of ["cappedFoldLedger", "cappedHeadDeclared", "foldList"]) expect(typeof route[name], `${name} is reachable by an in-process caller`).toBe("function");
  return route;
};
const f3Key = (f: { spec: string }) => /(HIMMEL-\d+)/.exec(basename(f.spec))![1];
const f3Keys = (f: any): string[] => f.keys ?? [f3Key(f)];
const f3Args = (f: any, keys: string[]) => ({ keys, spec: f.spec, plan: f.plan, specReturn: b1Kind(f, "spec").at(-1)!, planReturn: b1Kind(f, "plan").at(-1)! });
const f3Argv = (f: any, keys = f3Keys(f).join(",")) => ["--keys", keys, "--spec", f.spec, "--plan", f.plan, "--spec-return", b1Kind(f, "spec").at(-1)!, "--plan-return", b1Kind(f, "plan").at(-1)!];
const f3Fold = async (f: any, keys = f3Keys(f)) => (await f3Route()).cappedFoldLedger(f3Args(f, keys));
const f3Refusal = async (f: any, keys = f3Keys(f)) => c3Message(f3Fold(f, keys));
const f3Group = async () => (await b1Lib()).buildGroupFixture(realpathSync(root()));
const f3Known = async () => (await b1Lib()).buildKnownSingleFixture(realpathSync(root()), { variant: "refusedCap" });
const f3Fresh = async () => (await b1Lib()).buildFreshSingleFixture(realpathSync(root()));
// Every file under the specs root by relative path and sha256, every decision's mtime, and the anchor ledger's rows by kind.
const f3Tree = (f: any) => {
  const files: Record<string, string> = {}; const decisions: Record<string, number> = {};
  for (const entry of readdirSync(f.specsRoot, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile()) continue; const path = join(entry.parentPath, entry.name); const rel = path.slice(f.specsRoot.length + 1);
    files[rel] = sha(readFileSync(path, "utf8")); if (rel.startsWith("decisions/")) decisions[rel] = statSync(path).mtimeMs;
  }
  return { files, decisions, rows: b1Rows(f).map((r: any) => r.row) };
};
// The exact proof, computed from the fixture's own files: every path, hash and round is read back from disk or from the fixture, never stored.
const f3Check = async (proof: any, f: any, o: { keys?: string[]; epoch: number; rounds: [number, number]; carried: [kind: string, id: string, severity: string][]; history?: string[] }) => {
  const route: any = await import("./chief-route"); const shared = await t2Pinned(); const keys = [...(o.keys ?? f3Keys(f))].sort(); const anchor = route.keyOf(f.spec);
  const file = (path: string) => ({ path, sha256: sha(readFileSync(path, "utf8")) });
  const returns = (["spec", "plan"] as const).map((kind, i) => {
    const path = b1Kind(f, kind).at(-1)!; const text = readFileSync(path, "utf8");
    return { ...file(path), kind, round: o.rounds[i], return_sha: route.returnSha(text), residuals: o.carried.filter(c => c[0] === kind).length };
  });
  expect(proof).toMatchObject({ schema: 2, reader_version: 2, mode: "capped-carry-ledger", anchor, keys, epoch: o.epoch, spec: file(realpathSync(f.spec)), plan: file(realpathSync(f.plan)), returns });
  expect(Object.keys(proof)).toEqual(["schema", "reader_version", "mode", "anchor", "keys", "epoch", "spec", "plan", "returns", "pins", "carried"]);
  expect(proof.carried).toEqual(o.carried.map(([kind, id, severity]) => ({ key: anchor, epoch: o.epoch, kind, round: returns[kind === "spec" ? 0 : 1].round, return_path: returns[kind === "spec" ? 0 : 1].path,
    return_sha: returns[kind === "spec" ? 0 : 1].return_sha, finding_id: id, severity, status: "open-carried" })));
  for (const pin of proof.pins) if (pin.path) expect(pin.sha256, `${pin.role} ${pin.path}`).toBe(sha(readFileSync(pin.path, "utf8")));
  const roles = (role: string) => proof.pins.filter((p: any) => p.role === role);
  expect(roles("ledger").map((p: any) => p.path)).toEqual([f.ledgerPath]); expect(roles("manifest").map((p: any) => p.path)).toEqual([join(dirname(f.ledgerPath), "manifest.json")]);
  expect(roles("return").map((p: any) => p.path).sort()).toEqual(returns.map(r => r.path).sort());
  expect(roles("history").map((p: any) => p.path).sort(), "the history pins").toEqual([...(o.history ?? [])].sort());
  expect(roles("member-absence"), "the member-absence pin").toEqual(keys.length > 1 ? [{ role: "member-absence", directory: shared.ledgerDirOf(f.specsRoot), keys: keys.filter(k => k !== anchor) }] : []);
  expect(shared.validateCappedProofShape(proof)).toEqual(proof);
};
// A positive run through the real verb form: the proof is one JSON line, nothing is written under the specs root, no ledger row appears (R1, R2).
const f3Cli = async (f: any, o: Parameters<typeof f3Check>[2], keys = f3Keys(f)) => {
  const before = f3Tree(f); const run = p1Cli("--keys", ...f3Argv(f, keys.join(",")).slice(1));
  expect(run.err).toBe(""); expect(run.code).toBe(0); expect(run.out.endsWith("\n") && run.out.trimEnd().split("\n").length).toBe(1);
  const proof = JSON.parse(run.out); await f3Check(proof, f, { ...o, keys });
  expect(f3Tree(f), "R1: the artifact tree, every decision's mtime and the ledger rows are unchanged").toEqual(before);
  expect(proof.carried.every((c: any) => c.status === "open-carried"), "R2: every carried entry is open-carried").toBe(true);
  expect(f3Tree(f).rows, "R2: no ledger row of any run").toEqual(before.rows);
  return proof;
};

test("3f availability: the assembly and the head declaration are reachable in process", async () => {
  const route = await f3Route(); expect(route.cappedFoldLedger.length).toBe(1); expect(route.cappedHeadDeclared.length).toBe(3);
});

test("D7 cappedHeadDeclared: the head and the plan header are optional, one equal line passes, two lines, a subset, a superset, one key of many or an empty line refuse", async () => {
  const route = await f3Route(); const keys = ["HIMMEL-9801", "HIMMEL-9802", "HIMMEL-9803"]; const all = keys.join(", ");
  const doc = (head: string, front = `tickets: ${all}`) => `---\n${front}\n---\n# Title\n${head}\n\n## Body\nKeys: HIMMEL-1\n- Tickets: HIMMEL-2\n`;
  for (const ok of ["", `Keys: ${all}`, `Keys: [${[...keys].reverse().join(", ")}]`, `Key: ${all}`, `- Tickets: ${all}`, `- Ticket: ${all}`]) expect(() => route.cappedHeadDeclared(doc(ok), keys, true), ok).not.toThrow();
  const header = `capped-fold: header must declare only ${all}`;
  for (const [what, head] of [["two lines", `Keys: ${all}\nKeys: ${all}`], ["two spellings", `Keys: ${all}\n- Tickets: ${all}`], ["a subset", "Keys: HIMMEL-9801, HIMMEL-9802"],
    ["a superset", `Keys: ${all}, HIMMEL-9899`], ["one key of many", "Keys: HIMMEL-9801"], ["a repeated key", `Keys: ${all}, HIMMEL-9801`], ["an empty line", "Keys:"], ["a wrong key", "- Tickets: HIMMEL-9801, HIMMEL-9802, HIMMEL-9899"]] as const) {
    expect(() => route.cappedHeadDeclared(doc(head), keys, true), what).toThrow(header);
  }
  expect(() => route.cappedHeadDeclared(doc("", ""), keys, true), "a plan without a tickets line").not.toThrow();
  expect(() => route.cappedHeadDeclared("# Plan\n\n- Task 1\n", keys, true), "a plan with no front matter at all").not.toThrow();
  const tickets = `capped-fold: tickets must declare only ${all}`;
  for (const [what, front] of [["a subset", "tickets: HIMMEL-9801, HIMMEL-9802"], ["a superset", `tickets: ${all}, HIMMEL-9899`], ["one key of many", "tickets: HIMMEL-9801"], ["two lines", `tickets: ${all}\ntickets: ${all}`], ["prose", "tickets: all of them"]] as const) {
    expect(() => route.cappedHeadDeclared(doc("", front), keys, true), what).toThrow(tickets);
  }
  expect(() => route.cappedHeadDeclared(doc("", `tickets: [${all}]`), keys, true), "a flow list").not.toThrow();
  expect(() => route.cappedHeadDeclared(doc("", `tickets: ${keys.map(k => `${k} (a note)`).join(", ")}`), keys, true), "annotated items").not.toThrow();
  expect(() => route.cappedHeadDeclared(`Keys: ${all}\n`, keys, false), "without front matter the whole text is read, one equal line").not.toThrow();
  expect(() => route.cappedHeadDeclared("Keys: HIMMEL-9801\n", keys, false), "without front matter, one key of many").toThrow(header);
  expect(() => route.cappedHeadDeclared("# Return\n- Tickets: HIMMEL-9801\nSPEC CLEAN\n", keys, false), "without front matter only a Keys line counts").not.toThrow();
  expect(() => route.cappedHeadDeclared(`---\ntickets: HIMMEL-9801\n---\nKeys: ${all}\n`, keys, false), "without front matter the front matter is not read").not.toThrow();
});

test("D2 requested keys: the exact set and a reordered set give the same proof; a missing, an extra, a duplicate, an empty and a malformed key refuse", async () => {
  const f = await f3Group(); const keys = f.keys as string[]; const exact = await f3Fold(f, keys);
  expect(await f3Fold(f, [...keys].reverse()), "reordered").toEqual(exact); expect(exact.keys).toEqual([...keys].sort());
  const tickets = (list: string[]) => `capped-fold: tickets must declare only ${[...list].sort().join(", ")}`;
  expect(await f3Refusal(f, keys.slice(0, 6)), "a missing key").toBe(tickets(keys.slice(0, 6)));
  expect(await f3Refusal(f, [...keys, "HIMMEL-9899"]), "an extra key").toBe(tickets([...keys, "HIMMEL-9899"]));
  const list = "capped-fold: expected one or more distinct ticket keys";
  expect(await f3Refusal(f, [...keys, keys[0]]), "a duplicate key").toBe(list); expect(await f3Refusal(f, []), "no key").toBe(list);
  for (const bad of ["", "himmel-9801", "HIMMEL", "HIMMEL-", "HIMMEL-9801 "]) expect(await f3Refusal(f, [...keys.slice(1), bad]), JSON.stringify(bad)).toBe(list);
});

test("D3 the anchor must be one of the keys, and the spec, the plan and the return filename keys must all equal it", async () => {
  const f = await f3Group(); const keys = f.keys as string[]; const specs = f.specsRoot;
  const spec = join(specs, "designs", "HIMMEL-9899-copy.md"); copyFileSync(f.spec, spec);
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), spec })), "the spec's own key is not a requested key").toBe("capped-fold: the anchor HIMMEL-9899 is not one of the keys");
  const nested = join(specs, "HIMMEL-9801"); mkdirSync(nested); const confused = join(nested, "HIMMEL-9802-confused.md"); copyFileSync(f.spec, confused);
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), spec: confused })), "a spec whose folder and filename keys differ").toBe("capped-fold: spec filename/folder key disagrees");
  const plan = join(specs, "plans", "HIMMEL-9899-plan.md"); copyFileSync(f.plan, plan);
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), plan })), "a plan of another key").toBe("capped-fold: expected a distinct plan for this key");
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), plan: f.spec })), "the spec given as the plan").toBe("capped-fold: expected a distinct plan for this key");
  const specReturn = join(specs, "designs", "HIMMEL-9899-x.md.critic-spec-r5.md"); copyFileSync(b1Kind(f, "spec").at(-1)!, specReturn);
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), specReturn })), "a return filename of another key").toBe("capped-fold: return filename/folder key disagrees");
  expect(await c3Message((await f3Route()).cappedFoldLedger({ ...f3Args(f, keys), spec: "relative/spec.md" })), "a relative path").toBe("capped-fold: paths must be absolute");
});

test("G0a v2 goal: --keys over the real new-stem group fixture prints the exact proof, validated, with its seven history pins and member-absence pin, and writes nothing", async () => {
  const f = await f3Group();
  const refused = p1Cli("--key", f.anchor, ...f3Argv(f).slice(2)); expect(refused.out).toBe(""); expect(refused.err, "the v1 control still refuses the group tickets line").toBe(`capped-fold: capped-fold: tickets must declare only ${f.anchor}\n`);
  const proof = await f3Cli(f, { epoch: 1, rounds: [5, 5], carried: [["spec", "F1", "medium"], ["plan", "P1", "minor"]], history: f.earlier });
  expect(proof.keys).toHaveLength(7); expect(proof.pins.filter((p: any) => p.role === "history")).toHaveLength(7);
  expect(JSON.stringify(await f3Fold(f)), "in process equals the verb").toBe(JSON.stringify(proof));
}, S1B);

test("G0b v2 goal and F4: --keys over the real known-single refusedCap fixture accepts a spec that is CLEAN in closure mode after a real major and a plan with minor findings", async () => {
  const f = await f3Known(); const key = f3Key(f);
  const refused = p1Cli("--key", key, ...f3Argv(f).slice(2)); expect(refused.err, "the v1 control still refuses the legacy header").toBe(`capped-fold: capped-fold: header must declare only ${key}\n`);
  const proof = await f3Cli(f, { epoch: 0, rounds: [7, 6], carried: [["plan", "P6", "minor"], ["plan", "P7", "minor"]], history: [] });
  expect(proof.keys).toEqual([key]); expect(proof.pins.some((p: any) => p.role === "member-absence"), "one key has no member pin").toBe(false);
  expect(proof.returns.map((r: any) => r.residuals)).toEqual([0, 2]);
  expect(b1Rows(f).filter((r: any) => r.row === "round" && r.critic === "spec").map((r: any) => [r.round, r.mode, r.findings.map((x: any) => x.severity)]).slice(4, 7),
    "the spec had a real major, then closure rounds, the last CLEAN").toEqual([[5, "full", ["major"]], [6, "closure", ["major"]], [7, "closure", []]]);
  const again = await f3Known(); const second = await f3Cli(again, { epoch: 0, rounds: [7, 6], carried: [["plan", "P6", "minor"], ["plan", "P7", "minor"]], history: [] });
  expect(second.carried.map((c: any) => c.finding_id), "F4, a second positive run over the same shape: only the plan's minors are carried").toEqual(["P6", "P7"]);
}, S1B);

test("T1 a fresh single-key fixture with every redundant declaration omitted: --key refuses with the shipped words, --keys accepts with the exact proof", async () => {
  const f = await f3Fresh(); const key = f3Key(f); const text = readFileSync(b1Kind(f, "spec").at(-1)!, "utf8");
  expect(text).not.toMatch(/^Key:|^Reviewed:/m); expect(readFileSync(f.spec, "utf8")).not.toMatch(/^Keys?:|^- Tickets?:/m);
  const refused = p1Cli("--key", key, ...f3Argv(f).slice(2)); expect(refused.code).toBe(1); expect(refused.out).toBe("");
  expect(refused.err, "the shipped words").toBe(`capped-fold: capped-fold: header must declare only ${key}\n`);
  const status = await b1Status(f, key); expect(status.next, "the ledger really refuses round 6").toBe("none");
  await f3Cli(f, { epoch: 0, rounds: [5, 5], carried: [["spec", "F5", "minor"], ["plan", "P5", "minor"]], history: [] });
}, S1B);

test("F5 zero findings in both kinds is refused as a direct v2 proof: it needs one carried finding", async () => {
  const f = await c3Build([1, 2, 3].flatMap(round => (["spec", "plan"] as const).map(kind => ({ kind, round }))));
  expect(await f3Refusal(f, [cappedKey])).toBe("capped-fold: requires at least one carried finding");
});

test("F6 an open historical operator-critical finding is refused by the shared ledger check before any policy", async () => {
  const f = await cappedFixture({ specFindings: "- **F1** (medium; operator-critical: spend-grant) the real ledger holds an open critical finding" });
  expect(await f3Refusal(f, [cappedKey])).toBe("capped-fold: open historical operator-critical findings");
});

test("F7 blocking history in an earlier epoch and in earlier rounds, latest rows nonblocking: accepted, and no carried id is a history id", async () => {
  for (const f of [await f3Group(), await f3Known()]) {
    const proof = await f3Fold(f); const signed = new Set(proof.returns.map((r: any) => r.path));
    const historyIds = b1Rows(f).filter((r: any) => r.row === "round" && !signed.has(r.verdict_path))
      .flatMap((r: any) => r.findings.filter((x: any) => x.severity === "major" || x.regression || x.class === "regression").map((x: any) => x.id));
    expect(historyIds.length, "the fixture holds blocking history").toBeGreaterThan(0);
    for (const id of historyIds) expect(proof.carried.map((c: any) => c.finding_id), `history id ${id} is not carried`).not.toContain(id);
    expect(proof.carried.every((c: any) => c.status === "open-carried" && (c.severity === "minor" || c.severity === "medium"))).toBe(true);
  }
}, S1B);

test("F8 the verifier never reads the fold list: foldList is spied across a positive and three refusing runs and is never called, and the assembly's source does not name it", async () => {
  const route = await f3Route(); const spy = spyOn(route, "foldList");
  try {
    await f3Fold(await f3Known());
    expect(await f3Refusal(await cappedFixture({ specFindings: "- **F1** (major) a major in the latest row" }), [cappedKey])).toBe(c3Heading("- **F1** (major) a major in the latest row"));
    expect(await f3Refusal(await cappedFixture({ specFindings: "- **F1** (medium; regression) a regression in the latest row" }), [cappedKey])).toBe(c3Heading("- **F1** (medium; regression) a regression in the latest row"));
    const closure = await c3Build([{ kind: "spec", round: 1, findings: "- **F1** (minor) a" }, { kind: "spec", round: 2, findings: "- **F2** (minor) b" }, { kind: "spec", round: 5, findings: "- **M1** (major) c" },
      { kind: "spec", round: 6, findings: "- **C1** (major) a closure major", closure: true }, { kind: "plan", round: 1 }, { kind: "plan", round: 2 }, { kind: "plan", round: 5 }]);
    expect(await f3Refusal(closure, [cappedKey]), "a closure major in the latest row").toBe(c3Heading("- **C1** (major) a closure major"));
    expect(spy, "never called").not.toHaveBeenCalled();
    const known = await f3Known(); await route.foldList(known.spec, known.specsRoot).catch(() => []); expect(spy, "control: the spy sees an outside call").toHaveBeenCalledTimes(1);
  } finally { spy.mockRestore(); }
  const source = readFileSync(join(import.meta.dir, "chief-route.ts"), "utf8"); const start = source.indexOf("export async function cappedFoldLedger("); const body = source.slice(start, source.indexOf("\n}\n", start));
  expect(start).toBeGreaterThan(-1); expect(body.length).toBeGreaterThan(500); expect(body).not.toContain("foldList");
}, S1B);

// A real file system change at a fixed point of the fold: the real validator is called through a spy that first applies the change, so the reader's
// cached reads and listings are older than the disk when its final recheck runs.
const f3Late = async (f: any, keys: string[], change: () => void) => {
  const route = await f3Route(); const shared = await t2Pinned(); const real = shared.validateCappedLedgerProofShape; let calls = 0;
  const spy = spyOn(shared, "validateCappedLedgerProofShape").mockImplementation((value: unknown) => { calls++; change(); return real(value); });
  try { const message = await c3Message(route.cappedFoldLedger(f3Args(f, keys))); expect(calls, "the change landed before the proof was validated, once").toBe(1); return message; } finally { spy.mockRestore(); }
};

test("N11 a file that appears after the first listing and before the final recheck is refused: a return in a scanned folder, a member's ledger file, a plan folder file and a manifest entry", async () => {
  const f = await f3Group(); const keys = f.keys as string[]; const shared = await t2Pinned(); const ledgerDir = shared.ledgerDirOf(f.specsRoot);
  await expect(f3Fold(f, keys), "control: the same fold without a change").resolves.toBeDefined();
  const specReturn = b1Kind(f, "spec").at(-1)!; const planReturn = b1Kind(f, "plan").at(-1)!; const lateSpec = specReturn.replace("r5.md", "r6.md");
  expect(await f3Late(f, keys, () => copyFileSync(specReturn, lateSpec)), "a fresh return in the spec's folder").toBe(`capped-fold: evidence changed or is unreadable: ${dirname(specReturn)}`);
  unlinkSync(lateSpec);
  const lateFolder = join(f.specsRoot, "plans"); const lateReturn = join(lateFolder, basename(planReturn).replace("r5.md", "r6.md"));
  expect(await f3Late(f, keys, () => copyFileSync(planReturn, lateReturn)), "a fresh return in plans/").toBe(`capped-fold: evidence changed or is unreadable: ${lateFolder}`);
  unlinkSync(lateReturn);
  const member = f.members[2]; const memberFile = join(ledgerDir, `${member}.jsonl`);
  expect(await f3Late(f, keys, () => writeFileSync(memberFile, "")), "a member's ledger file after the member listing").toBe(`capped-fold: evidence changed or is unreadable: ${ledgerDir}`);
  unlinkSync(memberFile);
  const manifest = join(ledgerDir, "manifest.json"); const kept = readFileSync(manifest, "utf8");
  expect(await f3Late(f, keys, () => writeFileSync(manifest, kept.replace('"keys":{}', `"keys":{"${member}":{"spec":1,"plan":1}}`))), "a member's manifest entry").toBe(`capped-fold: evidence changed or is unreadable: ${manifest}`);
  writeFileSync(manifest, kept); await expect(f3Fold(f, keys), "control again: restored").resolves.toBeDefined();
}, S1B);

test("N12 a current return, the estimate, the plan, the spec or a snapshot edited in the middle of the run is refused by the final recheck", async () => {
  const f = await f3Group(); const keys = f.keys as string[]; const dir = dirname(f.spec); const snapshots = join(dirname(f.ledgerPath), f.anchor);
  const edits: [string, string][] = [["a current spec return", b1Kind(f, "spec").at(-1)!], ["a current plan return", b1Kind(f, "plan").at(-1)!], ["the estimate", join(dir, "estimate.json")], ["the plan", realpathSync(f.plan)],
    ["the spec", realpathSync(f.spec)], ["the spec's snapshot", join(snapshots, sha(readFileSync(realpathSync(f.spec), "utf8")))]];
  for (const [what, path] of edits) {
    const kept = readFileSync(path, "utf8");
    try { expect(await f3Late(f, keys, () => appendFileSync(path, "edited during the run")), what).toBe(`capped-fold: evidence changed or is unreadable: ${path}`); } finally { writeFileSync(path, kept); }
  }
}, S1B);

test("L1 the v1 provenance-drift faults replayed on the group and on the known single through --keys: each refused with its own words", async () => {
  const faults = ["key", "epoch", "old", "copy", "higher", "tied", "quote", "seal", "extra-seal", "snapshot", "spec", "plan", "estimate", "ledger", "manifest", "seed"] as const;
  for (const make of [f3Group, f3Known]) {
    const control = await make(); await expect(f3Fold(control), "control").resolves.toBeDefined();
    for (const fault of faults) {
      const f = await make(); const key = f3Key(f); const spec = realpathSync(f.spec); const plan = realpathSync(f.plan); const dir = dirname(spec);
      const specReturn = b1Kind(f, "spec").at(-1)!; const planReturn = b1Kind(f, "plan").at(-1)!; const manifest = join(dirname(f.ledgerPath), "manifest.json"); let run = f3Args(f, f3Keys(f));
      const latest = "capped-fold: not the actual latest real spec round"; const coverage = "capped-fold: missing/extra ledger seals or review coverage"; const provenance = (path: string) => `capped-fold: seal provenance disagrees: ${path}`;
      const bump = (path: string) => path.replace(/r(\d)\.md$/, (_m, n) => `r${Number(n) + 1}.md`);
      const want: Record<string, string> = { key: "capped-fold: invalid ledger key/record", epoch: "capped-fold: invalid ledger epoch", old: latest, copy: latest, seed: latest, higher: N3_UNACCOUNTED(bump(planReturn)),
        tied: N3_UNACCOUNTED(join(f.specsRoot, "plans", basename(planReturn))), quote: `capped-fold: missing/conflicting critic READ quote: ${spec}`, seal: coverage, "extra-seal": coverage,
        snapshot: "capped-fold: content-addressed snapshot changed", spec: provenance(spec), plan: provenance(plan), estimate: provenance(join(dir, "estimate.json")),
        manifest: `${manifest}: the round manifest does not parse; restore it from the state repo history`, ledger: "" };
      if (fault === "key") editLedger(f, rows => { rows[0].key = "HIMMEL-99"; });
      if (fault === "epoch") editLedger(f, rows => { rows.filter((r: any) => r.row === "round").at(-1).epoch = 7; });
      if (fault === "old") run = { ...run, specReturn: b1Kind(f, "spec")[0] };
      if (fault === "copy") { const p = join(dirname(f.ledgerPath), `${basename(specReturn)}.copy`); copyFileSync(specReturn, p); run = { ...run, specReturn: p }; }
      if (fault === "higher") copyFileSync(planReturn, bump(planReturn));
      if (fault === "tied") copyFileSync(planReturn, join(f.specsRoot, "plans", basename(planReturn)));
      if (fault === "quote") await editCappedReturn(f, specReturn, t => t.replace(/^READ(?:-SHA256)? .*\n/m, ""));
      if (fault === "seal") await editCappedReturn(f, specReturn, t => t.replace(/^CONTENT-SHA256 .*\n/m, ""));
      if (fault === "extra-seal") editLedger(f, rows => { rows.push({ ...rows.at(-1), read_path: spec, read_sha: "f".repeat(64) }); });
      if (fault === "snapshot") writeFileSync(join(dirname(f.ledgerPath), key, sha(readFileSync(f.spec, "utf8"))), "edited");
      if (fault === "spec") appendFileSync(f.spec, "\nchanged\n");
      if (fault === "plan") appendFileSync(f.plan, "\nchanged\n");
      if (fault === "estimate") appendFileSync(join(dir, "estimate.json"), " ");
      if (fault === "ledger") { appendFileSync(f.ledgerPath, "not json\n"); want.ledger = `${key} ledger line ${readFileSync(f.ledgerPath, "utf8").split("\n").filter(Boolean).length} does not parse; restore it from the state repo history`; }
      if (fault === "manifest") appendFileSync(manifest, "changed");
      if (fault === "seed") editLedger(f, rows => { rows.splice(0, rows.length, { row: "seed", key, spec: 5, plan: 5, latest: { spec: [], plan: [] } }); });
      expect(await c3Message((await f3Route()).cappedFoldLedger(run)), `${fault} on ${key}`).toBe(want[fault]);
    }
  }
}, S1B);

test("T2 the fresh single-key fixture with a Key naming another key, a wrong Reviewed, a missing or extra seal row, a forged ledger key or return hash, a missing or edited snapshot, a quote that differs from its seal or the spec edited after the seal: each refused", async () => {
  type Case = { f: any; key: string; spec: string; specReturn: string; ledger: string };
  const fixture = async (): Promise<Case> => { const f = await f3Fresh(); return { f, key: f3Key(f), spec: realpathSync(f.spec), specReturn: b1Kind(f, "spec").at(-1)!, ledger: f.ledgerPath }; };
  const snapshotOf = (c: Case) => join(dirname(c.ledger), c.key, sha(readFileSync(c.spec, "utf8")));
  const cases: [string, (c: Case) => Promise<void> | void, (c: Case) => string][] = [
    ["a Key naming another key", c => editCappedReturn(c.f, c.specReturn, t => t.replace(/^Fixture:/m, "Key: HIMMEL-99\nFixture:")), () => C3_KEYS],
    ["a wrong Reviewed", c => editCappedReturn(c.f, c.specReturn, t => t.replace(/^Fixture:/m, `Reviewed: spec ${"0".repeat(64)}\nFixture:`)), () => C3_REVIEWED],
    ["a missing seal row", async c => { const { returnSha } = await import("./chief-route"); const sum = returnSha(readFileSync(c.specReturn, "utf8")); editLedger(c.f, rows => { rows.splice(rows.findIndex((r: any) => r.row === "seal" && r.return_sha === sum), 1); }); }, c => `capped-fold: seal provenance disagrees: ${join(dirname(c.spec), "estimate.json")}`],
    ["an extra seal row", c => editLedger(c.f, rows => { rows.push({ ...rows.at(-1), read_path: c.spec, read_sha: "f".repeat(64) }); }), () => "capped-fold: missing/extra ledger seals or review coverage"],
    ["a forged ledger key", c => editLedger(c.f, rows => { rows[0].key = "HIMMEL-99"; }), () => "capped-fold: invalid ledger key/record"],
    ["a forged return hash", c => editLedger(c.f, rows => { rows.filter((r: any) => r.row === "round" && r.critic === "spec").at(-1).return_sha = "0".repeat(64); }), () => "capped-fold: not the actual latest real spec round"],
    ["a missing snapshot", c => unlinkSync(snapshotOf(c)), c => `ENOENT: no such file or directory, realpath '${snapshotOf(c)}'`],
    ["an edited snapshot", c => writeFileSync(snapshotOf(c), "edited"), () => "capped-fold: content-addressed snapshot changed"],
    ["a quote that differs from its seal", c => editCappedReturn(c.f, c.specReturn, t => t.replace(/^(READ-SHA256 )([0-9a-f]{64})/m, (_l, v: string, h: string) => v + c3Flip(h))), c => `capped-fold: missing/conflicting critic READ quote: ${c.spec}`],
    ["the spec edited after the seal", c => appendFileSync(c.spec, "\nedited after the seal\n"), c => `capped-fold: seal provenance disagrees: ${c.spec}`],
  ];
  await expect(f3Fold((await fixture()).f), "control").resolves.toBeDefined();
  for (const [what, apply, message] of cases) { const c = await fixture(); await apply(c); expect(await f3Refusal(c.f), what).toBe(message(c)); }
}, S1B);

test("T3 direct --key on the T1 fixture and on a stored v1 proof stays strict and reads as before", async () => {
  const shared = await t2Pinned(); const f = await f3Fresh(); const key = f3Key(f);
  expect(p1Cli("--key", key, ...f3Argv(f).slice(2))).toEqual({ code: 1, signal: null, out: "", err: `capped-fold: capped-fold: header must declare only ${key}\n` });
  const v1 = await cappedFixture(); const run = p1Fold(v1.args); expect(run.code).toBe(0); expect(run.err).toBe("");
  const stored = JSON.parse(run.out); expect(stored.schema).toBe(1); expect(stored.mode).toBe("capped-carry");
  expect(shared.validateCappedProofShape(stored), "the dispatcher reads the stored v1 proof").toEqual(stored); expect(shared.validateCappedFoldProofShape(stored)).toEqual(stored);
  expect(p1Fold(v1.args), "a second run gives the same bytes").toEqual(run);
  const v2 = p1Cli("--keys", cappedKey, "--spec", v1.spec, "--plan", v1.plan, "--spec-return", v1.args.specReturn, "--plan-return", v1.args.planReturn);
  expect(v2.code, "the v1 fixture is also accepted by --keys, as schema 2").toBe(0); expect(JSON.parse(v2.out).schema).toBe(2);
  expect(() => shared.validateCappedFoldProofShape(JSON.parse(v2.out)), "the v1 validator refuses a schema 2 proof").toThrow("invalid capped-fold proof");
}, S1B);

test("T4 the --keys argv: exactly one of --key and --keys, each flag once; both together, an empty, duplicate or trailing-comma item and a missing flag refuse; one key works; the --key grammar is unchanged", async () => {
  const f = await f3Fresh(); const key = f3Key(f); const good = f3Argv(f); const want = (err: string) => ({ code: 1, signal: null, out: "", err });
  const swap = (flag: string, value: string) => good.map((x, i) => good[i - 1] === flag ? value : x);
  const shapes: [string, string[], string][] = [
    ...["--keys", "--spec", "--plan", "--spec-return", "--plan-return"].map(flag => [`${flag} missing`, good.filter((x, i) => x !== flag && good[i - 1] !== flag), flag === "--keys" ? P3_USAGE : F3_USAGE_KEYS] as [string, string[], string]),
    ["--keys repeated", [...good, "--keys", key], F3_USAGE_KEYS], ["an unknown flag after the five", [...good, "--unknown", "x"], F3_USAGE_KEYS], ["a trailing positional", [...good, "x"], F3_USAGE_KEYS],
    ["a leading positional", ["x", ...good], F3_USAGE_KEYS], ["the last value missing", good.slice(0, -1), F3_USAGE_KEYS], ["the equals spelling is no --keys flag, so the shipped usage line", [`--keys=${key}`, ...good.slice(2)], P3_USAGE],
    ["a value that starts with two dashes", swap("--keys", "--x"), F3_USAGE_KEYS], ["an empty --keys value", swap("--keys", ""), F3_USAGE_KEYS], ["an empty --spec value", swap("--spec", ""), F3_USAGE_KEYS],
    ["a flag as the value of another", swap("--plan", "--spec-return"), F3_USAGE_KEYS], ["only the five flag names", ["--keys", "--spec", "--plan", "--spec-return", "--plan-return"], F3_USAGE_KEYS],
    ["--key beside --keys", ["--key", key, ...good], F3_BOTH], ["--key with --keys at the end", ["--key", key, ...good.slice(2), "--keys", key], F3_BOTH], ["--key last", [...good, "--key", key], F3_BOTH],
    ["an empty first item", swap("--keys", `,${key}`), F3_LIST], ["an empty middle item", swap("--keys", `${key},,HIMMEL-9822`), F3_LIST], ["a trailing comma", swap("--keys", `${key},`), F3_LIST],
    ["a duplicate item", swap("--keys", `${key},${key}`), F3_LIST], ["a malformed item", swap("--keys", `${key},himmel-1`), F3_LIST], ["a space in the list", swap("--keys", `${key}, HIMMEL-9822`), F3_LIST],
  ];
  const bad: string[] = [];
  for (const [name, argv, err] of shapes) { const run = p1Cli(...argv); if (JSON.stringify(run) !== JSON.stringify(want(err))) bad.push(`${name}: ${JSON.stringify(argv.slice(0, 4))}\n  got ${JSON.stringify(run)}`); }
  expect(shapes).toHaveLength(25); expect(bad).toEqual([]);
  const one = p1Cli(...good); expect(one.code, "one key works").toBe(0); expect(JSON.parse(one.out).keys).toEqual([key]);
  const [specReturn, planReturn] = [b1Kind(f, "spec").at(-1)!, b1Kind(f, "plan").at(-1)!];
  expect(JSON.parse(p1Cli("--plan-return", planReturn, "--spec-return", specReturn, "--plan", f.plan, "--spec", f.spec, "--keys", key).out), "the flags are accepted in any order with the same proof").toEqual(JSON.parse(one.out));
  expect(p1Cli("--spec", f.spec, "--plan", f.plan, "--spec-return", specReturn, "--plan-return", planReturn), "neither flag: the shipped usage line, byte for byte").toEqual(want(P3_USAGE));
  expect(p1Cli("--key", key, "--spec", f.spec), "--key with missing flags: the shipped usage line, byte for byte").toEqual(want(P3_USAGE));
  const control = await cappedFixture(); const v1 = p1Fold(control.args); expect(v1.code).toBe(0); expect(JSON.parse(v1.out).mode, "--key still reaches v1 only").toBe("capped-carry");
  await c3Edit(control, "spec", text => text.replace(/^Fixture:/m, "Key: HIMMEL-99\nFixture:"));
  const refusal = p1Cli("--keys", cappedKey, "--spec", control.spec, "--plan", control.plan, "--spec-return", control.args.specReturn, "--plan-return", control.args.planReturn);
  expect(refusal, "--keys never falls back to v1: a refusal carries the v2 words").toEqual(want(`capped-fold: ${C3_KEYS}\n`));
  expect(p1Fold(control.args).err, "--key refuses the same bytes with its own words").toBe("capped-fold: capped-fold: return must declare only HIMMEL-10205\n");
}, S1B);

test("D7 through the fold: a spec head or a plan header that declares one key of many, a superset or two lines refuses before the ledger is read, and one equal line passes", async () => {
  const spec = "---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n";
  const plan = "---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 plan\n\n- Task 1: build the fixture.\n";
  await expect(f3Fold(await cappedFixture({ specText: spec.replace("# HIMMEL", "Key: HIMMEL-10205\n\n# HIMMEL"), planText: plan }), [cappedKey]), "one equal head line").resolves.toBeDefined();
  const header = `capped-fold: header must declare only ${cappedKey}`; const tickets = `capped-fold: tickets must declare only ${cappedKey}`;
  const cases: [string, { specText?: string; planText?: string }, string][] = [
    ["a spec head naming a superset", { specText: spec.replace("# HIMMEL", "Keys: HIMMEL-10205, HIMMEL-99\n\n# HIMMEL") }, header],
    ["a spec head naming another key", { specText: spec.replace("# HIMMEL", "Key: HIMMEL-99\n\n# HIMMEL") }, header],
    ["a spec head with two lines", { specText: spec.replace("# HIMMEL", "Key: HIMMEL-10205\n- Tickets: HIMMEL-10205\n\n# HIMMEL") }, header],
    ["a plan header naming another key", { planText: plan.replace("# HIMMEL", "Key: HIMMEL-99\n# HIMMEL") }, header],
    ["a plan front matter naming a superset", { planText: plan.replace("tickets: HIMMEL-10205", "tickets: [HIMMEL-10205, HIMMEL-99]") }, tickets],
  ];
  for (const [what, texts, message] of cases) {
    const f = await cappedFixture({ specText: spec, planText: plan, ...texts }); expect(await f3Refusal(f, [cappedKey]), what).toBe(message);
  }
  const bare = await cappedFixture(); writeFileSync(bare.spec, readFileSync(bare.spec, "utf8").replace(/^---\n[\s\S]*?\n---\n/, ""));
  expect(await f3Refusal(bare, [cappedKey]), "a spec with no front matter declares no tickets, so it is refused before the ledger is read").toBe(tickets);
  const blank = await cappedFixture(); writeFileSync(blank.spec, readFileSync(blank.spec, "utf8").replace("tickets: HIMMEL-10205\n", ""));
  expect(await f3Refusal(blank, [cappedKey]), "a front matter with no tickets line").toBe(tickets);
}, S1B);

test("3f the fold reads every part of the evidence: a member's ledger file, a fresh return, a Keys line naming the group, and the proven history each decide the result", async () => {
  const shared = await t2Pinned(); const group = await f3Group(); const keys = group.keys as string[]; const baseline = await f3Fold(group, keys);
  expect(baseline.pins.filter((p: any) => p.role === "history"), "the group needs its history to pass").toHaveLength(7);
  const memberFile = join(shared.ledgerDirOf(group.specsRoot), `${group.members[4]}.jsonl`); writeFileSync(memberFile, "");
  expect(await f3Refusal(group, keys), "a member's ledger file").toBe(`capped-fold: group member holds ledger state: ${group.members[4]}`); unlinkSync(memberFile);
  const specReturn = b1Kind(group, "spec").at(-1)!; copyFileSync(specReturn, specReturn.replace("r5.md", "r6.md"));
  expect(await f3Refusal(group, keys), "a fresh unsealed spec return one round above").toBe(N3_UNACCOUNTED(specReturn.replace("r5.md", "r6.md"))); unlinkSync(specReturn.replace("r5.md", "r6.md"));
  const keyed = await f3Group(); const line = `Keys: ${keys.join(", ")}\n`;
  for (const kind of ["spec", "plan"] as const) await c3Edit(keyed, kind, text => text.replace(/^Fixture:/m, `${line}Fixture:`));
  const accepted = await f3Fold(keyed, keys); expect(accepted.keys, "every return names the whole group").toEqual([...keys].sort());
  const wrong = await f3Group(); await c3Edit(wrong, "spec", text => text.replace(/^Fixture:/m, `Key: ${keys[0]}\nFixture:`));
  expect(await f3Refusal(wrong, keys), "a return naming only the anchor").toBe(C3_KEYS);
}, S1B);

test("N12 a history file edited in the middle of the run is refused by the final recheck: each of the seven earlier-epoch returns of the new-stem group", async () => {
  const f = await f3Group(); const keys = f.keys as string[]; const baseline = await f3Fold(f, keys);
  expect(f.earlier).toHaveLength(7);
  expect(baseline.pins.filter((p: any) => p.role === "history").map((p: any) => p.path).sort(), "the edited paths are exactly the proven history").toEqual([...f.earlier].sort());
  for (const path of f.earlier) {
    const kept = readFileSync(path, "utf8");
    try { expect(await f3Late(f, keys, () => appendFileSync(path, "edited during the run")), path).toBe(`capped-fold: evidence changed or is unreadable: ${path}`); } finally { writeFileSync(path, kept); }
  }
  await expect(f3Fold(f, keys), "control: the restored files are accepted again").resolves.toBeDefined();
}, S1B);

const f3Estimate = { path: "specs/designs/estimate.json", text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
test("3f anchor last: a group whose anchor sorts last among its keys, the shape of the real family, is folded for that anchor in any requested order", async () => {
  const anchor = "HIMMEL-9899"; const keys = ["HIMMEL-9801", "HIMMEL-9802", "HIMMEL-9803", anchor];
  expect([...keys].sort().at(-1), "the anchor sorts last, the other fixtures sort it first").toBe(anchor);
  const specText = `---\ntickets: [${keys.join(", ")}]\n---\n# ${anchor} group\n\nEstimate record: estimate.json\n\nThe contract names every member.\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`;
  const issue = (kind: "spec" | "plan", round: number, finding: string) => ({ kind, round, text: `${finding}\n${kind.toUpperCase()} FINDINGS 1\n`, reads: kind === "spec" ? ["spec", f3Estimate] : ["spec", "plan", f3Estimate] });
  const f = await (await b1Lib()).buildRoundFixture({ scratchRoot: realpathSync(root()), key: anchor, specText, planText: `# ${anchor} plan\n\n- Task 1\n`, declarations: false,
    returns: [1, 2, 3, 4, 5].flatMap(round => [issue("spec", round, "- **F1** (medium; Fact overlap) the group contract overlaps an owner"), issue("plan", round, "- **P1** (minor) a plan wording note")]) });
  const proof = await f3Cli(f, { epoch: 0, rounds: [5, 5], carried: [["spec", "F1", "medium"], ["plan", "P1", "minor"]], history: [] }, keys);
  expect(proof.anchor).toBe(anchor); expect(proof.carried.every((c: any) => c.key === anchor), "every carried finding belongs to the anchor").toBe(true);
  expect(proof.pins.filter((p: any) => p.role === "member-absence").map((p: any) => p.keys), "the member-absence pin names the other three").toEqual([keys.slice(0, 3)]);
  expect(JSON.stringify(await f3Fold(f, [...keys].reverse())), "the requested order does not matter").toBe(JSON.stringify(proof));
  expect(await f3Refusal(f, ["HIMMEL-9801", "HIMMEL-9802", "HIMMEL-9898", anchor]), "a member swapped for another of the same count").toBe(`capped-fold: tickets must declare only HIMMEL-9801, HIMMEL-9802, HIMMEL-9898, ${anchor}`);
}, S1B);

const RULING = "the park rm keeps its simple placement under the park root";
const RULING_FILE = `operator, on the park rm: ${RULING}, rule 1.\nIt stays a plain rm.\n`;
const SPLIT_QUOTE = "rule 1. It stays a plain rm";
const REV = (id: string, d = 1096) => `- **${id}** (major; operator-critical: reverses-ruling) the spec moves the park rm off its simple placement. That reverses decision ${d} rule 1.`;
const MENTION = (id: string) => `- **${id}** (major; operator-critical: reverses-ruling) the spec rests on decision 1096 rule 1 for its placement`;
const decisionOf = (specs: string, d = 1096) => join(specs, "decisions", `verbatim-decision-${d}-operator.txt`);
const tokenOf = (specs: string, returnSha: string, d = 1096, quote = RULING) => sha(`${sha(readFileSync(decisionOf(specs, d), "utf8"))}\n${returnSha}\n${quote}`).slice(0, 12);
const restore = (specs: string, id = "R1", d = 1096, quote = RULING, ...more: string[]) => critical(true, specs, id, d, quote, "--restores", ...more);
const roundAt = (specs: string, kind: string, round: number) => rowsOf(specs, "round").filter((x) => x.critic === kind && x.round === round).at(-1);
const ledgerFile = (specs: string) => join(roundsDir(specs), `${CAP_KEY}.jsonl`);
const statusText = async (specs: string) => (await routeCli("round-status", CAP_KEY, "--specs", specs)).out;
const CHECK = (m: number, n: number, tok: string, id = "R1", kind = "spec") => `RESTORE-CHECK ${id} (${kind} round ${m}) decision 1096 check ${kind} round ${n} token ${tok}`;
const BLOCK = (m: number, n: number, tok: string, id = "R1", kind = "spec") => `${CHECK(m, n, tok, id, kind)}\n${RULING}\nAnswer on one line directly above your READ-SHA256 lines, exactly \`RESTORE-HOLDS ${id} decision 1096 ${tok}\` if the quote is the operator's own words in \`specs/decisions/verbatim-decision-1096-*.txt\` (not a chief reading), it is the ruling finding ${id} says the spec reversed, no later decision in \`specs/decisions/\` changes that ruling, and the files under review now match it; otherwise exactly \`RESTORE-BREAKS ${id} decision 1096 ${tok}\`. Write one of the two, never both. A return without one is refused at the seal. RESTORE-BREAKS sends ${id} to the operator.`;
const T_CHECK = (n: number, id = "R1", kind = "spec") => `${CAP_KEY} ${kind} round ${n} is the restore check of ${id}: its return needs one RESTORE-HOLDS or RESTORE-BREAKS line for ${id} decision 1096 with the block's token; give the critic the RESTORE-CHECK block`;
const restoreTree = async (spec: string[][] = [[], [REV("R1")]], plan: string[][] = []) => {
  const t = specsTree(); expect((await routeCli("round-seed", "--all", t.specs)).code).toBe(0);
  const a = join(t.dir, `${CAP_KEY}-a.md`); const p = join(t.plans, `${CAP_KEY}-a.md`);
  writeFileSync(a, front(CAP_KEY, "# A\n")); writeFileSync(p, "# A plan\n");
  decide(t.specs, 1096, RULING_FILE, true);
  for (const [i, s] of spec.entries()) expect((await sealOn(`${a}.critic-spec-r${i + 1}.md`, [a], verdictFor("SPEC", s), ...s)).err).toBe("");
  for (const [i, s] of plan.entries()) expect((await sealOn(`${a}.critic-plan-r${i + 1}.md`, [p], verdictFor("PLAN", s), ...s)).err).toBe("");
  return { ...t, a, plan: p };
};
const restoreRow = (specs: string, from: any, o: Record<string, unknown> = {}) => {
  const d = String(o.decision ?? "1096"); const path = decisionOf(specs, Number(d));
  return `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", restore: true, critic: from.critic, epoch: 0, opens: from.round + 1, id: "R1", class: "reverses-ruling", decision: d, quote: RULING, decision_path: path, decision_sha: sha(readFileSync(path, "utf8")), return_sha: from.return_sha, ...o })}\n`;
};

const GOLDEN = join(import.meta.dir, "fixtures", "round-status-golden.json");
test("I5 golden: a ledger with no restore row reads byte for byte as it did before the restore route", async () => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice", "- **O1** (major; operator-critical: spend-grant) the spec grants a spend"], ["- **P1** (major) the plan skips a step"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", F3_R4, F4_R4)).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 901, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "O1", 901, SPEND)).err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 2", F3_R5, F4_R5)).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  const st = JSON.parse((await routeCli("round-status", CAP_KEY, "--specs", t.specs, "--json")).out); delete st.restore_owed;
  const verify: { code: number; out: string; err: string }[] = [];
  for (const v of [`${t.a}.critic-spec-r7.md`, `${t.a}.critic-plan-r6.md`]) for (const sign of [[], ["--sign"]]) { const x = await routeCli("ledger-verify", v, "--spec", t.a, ...sign); verify.push({ code: x.code, out: x.out, err: x.err }); }
  const got = `${JSON.stringify({ status: st, verify }, null, 1).replaceAll(t.r, "<root>").replace(/"ts": \d+/g, '"ts": 0')}\n`;
  if (!existsSync(GOLDEN)) { writeFileSync(GOLDEN, got); throw new Error(`wrote ${GOLDEN} from this run; review it and run again`); }
  expect(got).toBe(readFileSync(GOLDEN, "utf8"));
});

test("I5 key set: a plain round, and one whose reverses-ruling finding names no ruling, keep today's round-row and finding keys", async () => {
  const t = await restoreTree([["- **M1** (major) a plain finding"], [MENTION("M2")]]);
  const keys = ["critic", "epoch", "findings", "key", "mode", "read_path", "read_sha", "return_sha", "round", "row", "ts", "unrated_ids", "v", "verdict", "verdict_path"];
  for (const r of [1, 2]) expect(Object.keys(roundAt(t.specs, "spec", r)).sort()).toEqual(keys);
  expect(roundAt(t.specs, "spec", 1).findings).toEqual([{ id: "M1", severity: "major" }]);
  expect(roundAt(t.specs, "spec", 2).findings).toEqual([{ id: "M2", severity: "major", critical: "reverses-ruling" }]);
});

test("R3, R8 parse: rulings come from the finding's own block; an answer line at column zero ends the block above it and is read into restore_holds or restore_breaks", async () => {
  const { parseFindings, findingBlock } = await import("./chief-route");
  const tok = "0123456789ab";
  const D1 = "- **D1** (major; operator-critical: reverses-ruling) that reverses Decision-1096 and reverses decision 1101, not decision 1102";
  const body = ["critic return", REV("R1"), "  second line of R1", MENTION("M1"), D1];
  const holds = [...body, `RESTORE-HOLDS R1 decision 1096 ${tok}`, "SPEC FINDINGS 3"].join("\n");
  expect(parseFindings(holds, "spec", 3)).toEqual({ findings: [{ id: "R1", severity: "major", critical: "reverses-ruling", rulings: ["1096"] }, { id: "M1", severity: "major", critical: "reverses-ruling" }, { id: "D1", severity: "major", critical: "reverses-ruling", rulings: ["1096", "1101"] }], unrated_ids: [], restore_holds: [`R1@1096@${tok}`] });
  expect(findingBlock(holds, "D1")).toBe(D1);
  expect(findingBlock(holds, "R1")).toBe(`${REV("R1")}\n  second line of R1`);
  const breaks = parseFindings(holds.replace("RESTORE-HOLDS", "RESTORE-BREAKS"), "spec", 3);
  expect(breaks.restore_breaks).toEqual([`R1@1096@${tok}`]); expect("restore_holds" in breaks).toBe(false);
  const neither = parseFindings([...body, "SPEC FINDINGS 3"].join("\n"), "spec", 3);
  expect("restore_holds" in neither).toBe(false); expect("restore_breaks" in neither).toBe(false);
  expect("restore_holds" in parseFindings([...body, ` RESTORE-HOLDS R1 decision 1096 ${tok}`, "SPEC FINDINGS 3"].join("\n"), "spec", 3)).toBe(false);
  expect(parseFindings(REV("R1").replace("reverses-ruling", "spend-grant"), "spec", 1).findings[0].rulings).toBeUndefined();
});

test("R13 characterization: round-status and the seal give the same cap answers before and after roundNeedsRecord", async () => {
  const c = await roundTree([], []);
  expect(await status(c.specs)).toMatchObject({ next: "none", why: `spec round 6: ${T1("spec")}; plan round 6: ${T1("plan")}` });
  expect((await closeOn(c, "plan", 6, [c.plan], "PLAN CLEAN")).err).toContain(T1("plan"));
  const t = await roundTree(MAJOR, []);
  expect(await status(t.specs)).toMatchObject({ next: "closure", why: "spec round 6: closure; plan round 6: closure" });
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ next: "closure", why: `spec round 7: ${T5(7)}; plan round 6: closure` });
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toContain(T5(7));
  const e = await extTree();
  expect(await status(e.specs)).toMatchObject({ next: "closure", why: `spec round 8: ${T5(8)}; plan round 6: closure` });
  decide(e.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, e)).err).toBe("");
  expect(await status(e.specs)).toMatchObject({ next: "closure", why: `spec round 8: closure; plan round 6: closure` });
});

test("DoD 1 (1a to 1e): a restore of a reverses-ruling finding is recorded, owed until its kind's next round answers the block, and then closes it", async () => {
  const t = await restoreTree();
  const r2 = roundAt(t.specs, "spec", 2);
  expect(r2.findings).toEqual([{ id: "R1", severity: "major", critical: "reverses-ruling", rulings: ["1096"] }]);
  expect((await status(t.specs)).critical_open).toMatchObject([{ id: "R1", class: "reverses-ruling", kind: "spec", round: 2 }]);
  const ok = await restore(t.specs); expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  const row = rowsOf(t.specs, "critical").at(-1);
  expect(row).toMatchObject({ restore: true, critic: "spec", opens: 3, id: "R1", class: "reverses-ruling", decision: "1096", quote: RULING, return_sha: r2.return_sha });
  expect("token" in row).toBe(false);
  const s = await status(t.specs);
  expect(s.critical_open).toEqual([]); expect(s.invalid).toEqual([]);
  expect(s.restore_owed).toEqual([{ id: "R1", class: "reverses-ruling", kind: "spec", round: 2, decision: "1096", quote: RULING, opens: 3 }]);
  const tok = tokenOf(t.specs, r2.return_sha);
  expect(await statusText(t.specs)).toContain(BLOCK(2, 3, tok));
  const sign = await routeCli("ledger-verify", `${t.a}.critic-spec-r2.md`, "--spec", t.a, "--sign");
  expect(sign.err).toContain(`${CAP_KEY} has a restore check owed: R1 (decision 1096) in spec round 3`); expect(sign.code).not.toBe(0);
  const v3 = `${t.a}.critic-spec-r3.md`;
  expect((await sealOn(v3, [t.a], "SPEC FINDINGS 1", "- **n1** (minor) a wording note", "  - fix: reword it", `RESTORE-HOLDS R1 decision 1096 ${tok}`)).err).toBe("");
  const r3 = roundAt(t.specs, "spec", 3);
  expect(r3.restore_holds).toEqual([`R1@1096@${tok}`]); expect("restore_breaks" in r3).toBe(false);
  expect(r3.findings).toEqual([{ id: "n1", severity: "minor" }]);
  const { findingBlock } = await import("./chief-route");
  expect(findingBlock(readFileSync(v3, "utf8"), "n1")).toBe("- **n1** (minor) a wording note\n  - fix: reword it");
  const after = await status(t.specs); expect(after.restore_owed).toEqual([]); expect(after.critical_open).toEqual([]); expect(after.invalid).toEqual([]);
  expect((await routeCli("ledger-verify", v3, "--spec", t.a, "--sign")).code).toBe(0);
});

test("DoD 2: --restores refuses the other three classes, a finding that only mentions the decision and a list; a verbatim-decision name counts; a plain record of a spend grant is as today", async () => {
  const t = await restoreTree([[], ["- **F1** (major; operator-critical: spend-grant) grants a spend. That reverses decision 1096 rule 1.", "- **F2** (major; operator-critical: account-or-terms) signs new terms", "- **F3** (major; operator-critical: public-policy) sets a policy", MENTION("M1"), "- **V1** (major; operator-critical: reverses-ruling) moves it again; that reverses verbatim-decision-1096-park-rm-simple-placement.txt"]]);
  const found = (id: string) => roundAt(t.specs, "spec", 2).findings.find((f: { id: string }) => f.id === id);
  expect(found("M1")).toEqual({ id: "M1", severity: "major", critical: "reverses-ruling" });
  expect(found("V1").rulings).toEqual(["1096"]); expect("rulings" in found("F1")).toBe(false);
  for (const [id, cls] of [["F1", "spend-grant"], ["F2", "account-or-terms"], ["F3", "public-policy"]]) {
    const x = await restore(t.specs, id); expect(x.err).toContain(`round-critical: --restores closes only a reverses-ruling finding; ${id} is ${cls}`); expect(x.code).not.toBe(0);
  }
  const m = await restore(t.specs, "M1"); expect(m.err).toContain("round-critical: M1 does not say it reverses decision 1096; the operator rules on it"); expect(m.code).not.toBe(0);
  const list = await restore(t.specs, "V1,M1"); expect(list.err).toContain("round-critical: --restores closes one finding"); expect(list.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
  decide(t.specs, 1101, `${CAP_KEY} operator: ${SPEND}\n`);
  const plain = await critical(true, t.specs, "F1", 1101, SPEND); expect(plain.err).toBe(""); expect(plain.code).toBe(0);
  expect(rowsOf(t.specs, "critical")).toMatchObject([{ id: "F1", class: "spend-grant", decision: "1101", opens: 3 }]);
  expect("restore" in rowsOf(t.specs, "critical")[0]).toBe(false);
});

test("DoD 3: a quote the decision holds only after whitespace is normalised, or a short one, is refused and writes no row", async () => {
  const t = await restoreTree();
  const x = await restore(t.specs, "R1", 1096, SPLIT_QUOTE);
  expect(x.err).toContain("round-critical: decision 1096 does not hold the quote byte for byte (20 characters or more)"); expect(x.code).not.toBe(0);
  const short = await restore(t.specs, "R1", 1096, "simple placement"); expect(short.err).toContain("does not hold the quote byte for byte (20 characters or more)"); expect(short.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
});

test("DoD 4, DoD 9: a broken restore goes back to the operator, once; a plain record closes a broken or an owed restore and replays valid", async () => {
  const t = await restoreTree();
  const tok = tokenOf(t.specs, roundAt(t.specs, "spec", 2).return_sha);
  expect((await restore(t.specs)).err).toBe("");
  expect((await sealOn(`${t.a}.critic-spec-r3.md`, [t.a], "SPEC FINDINGS 1", REV("R2"), `RESTORE-BREAKS R1 decision 1096 ${tok}`)).err).toBe("");
  expect(roundAt(t.specs, "spec", 3).restore_breaks).toEqual([`R1@1096@${tok}`]);
  const s = await status(t.specs);
  expect(s.critical_open).toEqual([{ id: "R1", class: "reverses-ruling", kind: "spec", round: 2, verdict_path: `${t.a}.critic-spec-r2.md`, restore: "broken" }, { id: "R2", class: "reverses-ruling", kind: "spec", round: 3, verdict_path: `${t.a}.critic-spec-r3.md` }]);
  expect(s.restore_owed).toEqual([]);
  const again = await restore(t.specs); expect(again.err).toContain("round-critical: R1 already had a restore"); expect(again.code).not.toBe(0);
  const second = await restore(t.specs, "R2"); expect(second.err).toBe(""); expect(second.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ id: "R2", restore: true, critic: "spec", opens: 4 });
  decide(t.specs, 1101, `${CAP_KEY} operator: ${SPEND}\n`);
  const plain = await critical(true, t.specs, "R1", 1101, SPEND); expect(plain.err).toBe(""); expect(plain.code).toBe(0);
  const after = await status(t.specs);
  expect(after.critical_open).toEqual([]); expect(after.invalid).toEqual([]); expect(after.restore_owed).toMatchObject([{ id: "R2", opens: 4 }]);
  decide(t.specs, 1102, `${CAP_KEY} operator: ${SPEND} once more\n`);
  const owed = await critical(true, t.specs, "R2", 1102, `${SPEND} once more`); expect(owed.err).toBe(""); expect(owed.code).toBe(0);
  const fin = await status(t.specs); expect(fin.restore_owed).toEqual([]); expect(fin.critical_open).toEqual([]); expect(fin.invalid).toEqual([]);
});

test("DoD 5: the seal refuses a check round with no answer, both answers, a wrong token or an answer no restore owes, writes no round row and leaves the restore owed", async () => {
  const t = await restoreTree(); const tok = tokenOf(t.specs, roundAt(t.specs, "spec", 2).return_sha);
  expect((await restore(t.specs)).err).toBe("");
  const v3 = `${t.a}.critic-spec-r3.md`;
  for (const lines of [[], [`RESTORE-HOLDS R1 decision 1096 ${tok}`, `RESTORE-BREAKS R1 decision 1096 ${tok}`], [`RESTORE-HOLDS R1 decision 1096 ${"0".repeat(12)}`], [`RESTORE-HOLDS R1 decision 1096 ${tok}`, `RESTORE-HOLDS R9 decision 1096 ${tok}`]]) {
    const x = await sealOn(v3, [t.a], "SPEC CLEAN", ...lines);
    expect(x.err, lines.join(" / ")).toContain(T_CHECK(3)); expect(x.code).not.toBe(0);
    expect(readFileSync(v3, "utf8")).not.toContain("CONTENT-SHA256");
    expect(roundAt(t.specs, "spec", 3)).toBeUndefined();
    expect((await status(t.specs)).restore_owed).toMatchObject([{ id: "R1" }]);
  }
});

test("R8: the seal refuses an answer line in a round that owes no restore check, writes no round row and leaves the restore owed", async () => {
  const t = await restoreTree(); const tok = tokenOf(t.specs, roundAt(t.specs, "spec", 2).return_sha);
  expect((await restore(t.specs)).err).toBe("");
  for (const line of [`RESTORE-HOLDS R1 decision 1096 ${tok}`, `RESTORE-BREAKS R1 decision 1096 ${tok}`]) {
    const v1 = `${t.a}.critic-plan-r1.md`;
    const x = await sealOn(v1, [t.plan], "PLAN CLEAN", line);
    expect(x.err, line).toContain(`${CAP_KEY} plan round 1 owes no restore check: its return carries a RESTORE-HOLDS or RESTORE-BREAKS line; give that block to the round it names`); expect(x.code).not.toBe(0);
    expect(readFileSync(v1, "utf8")).not.toContain("CONTENT-SHA256");
    expect(roundAt(t.specs, "plan", 1)).toBeUndefined();
    expect((await status(t.specs)).restore_owed).toMatchObject([{ id: "R1", kind: "spec" }]);
  }
});

const twoRestores = async () => {
  const t = await restoreTree([[REV("F1")], [REV("F1")]]);
  const bare = await restore(t.specs, "F1"); expect(bare.err).toContain("round-critical: F1 names findings in spec round 1 and spec round 2; add --round spec:2"); expect(bare.code).not.toBe(0);
  expect((await restore(t.specs, "F1", 1096, RULING, "--round", "spec:1")).err).toBe("");
  expect((await restore(t.specs, "F1", 1096, RULING, "--round", "spec:2")).err).toBe("");
  return { t, t1: tokenOf(t.specs, roundAt(t.specs, "spec", 1).return_sha), t2: tokenOf(t.specs, roundAt(t.specs, "spec", 2).return_sha) };
};
test("DoD 5, two restores of one id: two blocks with their own tokens; one answer is refused; each answer lands on its own token's restore, and the swapped return gives the reverse", async () => {
  const { t, t1, t2 } = await twoRestores();
  expect(rowsOf(t.specs, "critical").map((x) => [x.id, x.opens])).toEqual([["F1", 3], ["F1", 3]]);
  expect(t1).not.toBe(t2);
  const text = await statusText(t.specs);
  expect(text).toContain(BLOCK(1, 3, t1, "F1")); expect(text).toContain(BLOCK(2, 3, t2, "F1"));
  const v3 = `${t.a}.critic-spec-r3.md`;
  const single = await sealOn(v3, [t.a], "SPEC CLEAN", `RESTORE-HOLDS F1 decision 1096 ${t1}`); expect(single.err).toContain(T_CHECK(3, "F1")); expect(single.code).not.toBe(0);
  expect((await sealOn(v3, [t.a], "SPEC CLEAN", `RESTORE-HOLDS F1 decision 1096 ${t1}`, `RESTORE-BREAKS F1 decision 1096 ${t2}`)).err).toBe("");
  expect((await status(t.specs)).critical_open).toEqual([{ id: "F1", class: "reverses-ruling", kind: "spec", round: 2, verdict_path: `${t.a}.critic-spec-r2.md`, restore: "broken" }]);
  const u = await twoRestores();
  expect((await sealOn(`${u.t.a}.critic-spec-r3.md`, [u.t.a], "SPEC CLEAN", `RESTORE-BREAKS F1 decision 1096 ${u.t1}`, `RESTORE-HOLDS F1 decision 1096 ${u.t2}`)).err).toBe("");
  const s = await status(u.t.specs);
  expect(s.critical_open).toEqual([{ id: "F1", class: "reverses-ruling", kind: "spec", round: 1, verdict_path: `${u.t.a}.critic-spec-r1.md`, restore: "broken" }]); expect(s.restore_owed).toEqual([]);
});

test("DoD 6, order: a plan round after the restore row does not close a spec finding, and a spec round before the row does not count", async () => {
  const t = await restoreTree(); const r2 = roundAt(t.specs, "spec", 2); const tok = tokenOf(t.specs, r2.return_sha);
  const file = ledgerFile(t.specs); const base = readFileSync(file, "utf8");
  expect((await restore(t.specs)).err).toBe("");
  const withRow = readFileSync(file, "utf8"); const restoreLine = withRow.slice(base.length);
  const fake = (critic: string) => `${JSON.stringify({ ...r2, ts: Date.now(), critic, round: 3, return_sha: sha(`a ${critic} round 3`), findings: [], unrated_ids: [], verdict: `${critic.toUpperCase()} CLEAN`, restore_holds: [`R1@1096@${tok}`] })}\n`;
  writeFileSync(file, withRow + fake("plan"));
  const plan = await status(t.specs); expect(plan.restore_owed).toMatchObject([{ id: "R1", opens: 3 }]); expect(plan.critical_open).toEqual([]);
  writeFileSync(file, base + fake("spec") + restoreLine);
  const before = await status(t.specs); expect(before.restore_owed).toEqual([]); expect(before.critical_open).toMatchObject([{ id: "R1" }]); expect(before.invalid).toEqual(["critical 1096"]);
});

test("DoD 6, kinds: a plan finding's restore names the plan and is checked by the plan round of that number, never the spec round", async () => {
  const t = await restoreTree([[], []], [[], [REV("P1")]]);
  const p2 = roundAt(t.specs, "plan", 2); const tok = tokenOf(t.specs, p2.return_sha);
  expect((await restore(t.specs, "P1")).err).toBe("");
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ restore: true, critic: "plan", opens: 3, id: "P1", return_sha: p2.return_sha });
  const s2 = roundAt(t.specs, "spec", 2);
  appendFileSync(ledgerFile(t.specs), `${JSON.stringify({ ...s2, ts: Date.now(), round: 3, return_sha: sha("a spec round 3"), restore_holds: [`P1@1096@${tok}`] })}\n`);
  expect((await status(t.specs)).restore_owed).toMatchObject([{ id: "P1", kind: "plan", round: 2, opens: 3 }]);
  expect((await sealOn(`${t.a}.critic-plan-r3.md`, [t.plan], "PLAN CLEAN", `RESTORE-HOLDS P1 decision 1096 ${tok}`)).err).toBe("");
  const s = await status(t.specs); expect(s.restore_owed).toEqual([]); expect(s.critical_open).toEqual([]);
});

test("DoD 6, openers: a restore opens no round; the spec-only extension's round stays refused to the plan, and the lagging plan's own grant of that round is not already open", async () => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], []);
  decide(t.specs, 1096, RULING_FILE, true);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", F3_R4, F4_R4)).err).toBe("");
  expect((await verb(true, "round-override", CAP_KEY, "--findings", "F3,F4", "--why", "a second closure", "--chief", "chief-x", "--specs", t.specs)).err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 3", F3_R5, F4_R5, REV("X1"))).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 985, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await closureVerb(t.specs, 985, "--round", "plan:7")).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  const ok = await restore(t.specs, "X1"); expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ restore: true, critic: "spec", opens: 8, id: "X1" });
  const one = "the first changed plan line"; const two = "the second changed plan line";
  writeFileSync(t.plan, `# A plan\n\n${one}\n${two}\n`);
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN FINDINGS 2", REG("R1", one), REG("R2", two))).err).toBe("");
  const tok = tokenOf(t.specs, latestOf(t.specs, "spec", 7).return_sha);
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN", `RESTORE-HOLDS X1 decision 1096 ${tok}`)).err).toBe("");
  expect((await status(t.specs)).restore_owed).toEqual([]);
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN CLEAN")).err).toContain(T5(8));
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  const lag = await lagExtend(t); expect(lag.err).toBe(""); expect(lag.code).toBe(0);
  expect((await closeOn(t, "plan", 8, [t.plan], "PLAN FINDINGS 1", "- **R3** (major; reopens R1) still broken")).err).toBe("");
  expect((await status(t.specs)).invalid).toEqual([]);
});

test("DoD 6, openers: a restore whose round loses its opener goes back to the operator", async () => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], []);
  decide(t.specs, 1096, RULING_FILE, true);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", F3_R4, F4_R4)).err).toBe("");
  const p1 = "- **P1** (minor; operator-critical: reverses-ruling) the plan moves the park rm off its simple placement. That reverses decision 1096 rule 1.";
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 1", p1)).err).toBe("");
  expect((await verb(true, "round-override", CAP_KEY, "--findings", "F3,F4", "--why", "a second closure", "--chief", "chief-x", "--specs", t.specs)).err).toBe("");
  const x = await restore(t.specs, "P1");
  expect(x.err).toContain("round-critical: plan round 7 needs a record to open and a restore opens none; the operator rules on P1"); expect(x.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
  expect((await status(t.specs)).restore_owed).toEqual([]);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  const s = await status(t.specs);
  expect(s.restore_owed).toEqual([]); expect(s.critical_open).toMatchObject([{ id: "P1", kind: "plan" }]);
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toContain(T5(7));
});

test("DoD 6, DoD 7 cap: a restore whose round needs a record to open is refused, and the same row appended by hand replays invalid", async () => {
  const t = await roundTree(MAJOR, []); decide(t.specs, 1096, RULING_FILE, true);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", REV("R1"))).err).toBe("");
  const x = await restore(t.specs); expect(x.err).toContain("round-critical: spec round 7 needs a record to open and a restore opens none; the operator rules on R1"); expect(x.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
  appendFileSync(ledgerFile(t.specs), restoreRow(t.specs, latestOf(t.specs, "spec", 6)));
  const s = await status(t.specs); expect(s.invalid).toEqual(["critical 1096"]); expect(s.critical_open).toMatchObject([{ id: "R1" }]); expect(s.restore_owed).toEqual([]);
});

test("DoD 6, ids: an id raised in two rounds needs --round, and --round picks that round's finding", async () => {
  const t = await restoreTree([[], [REV("F1")], [REV("F1")]]);
  const x = await restore(t.specs, "F1"); expect(x.err).toContain("round-critical: F1 names findings in spec round 2 and spec round 3; add --round spec:3"); expect(x.code).not.toBe(0);
  const ok = await restore(t.specs, "F1", 1096, RULING, "--round", "spec:3"); expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ id: "F1", opens: 4, return_sha: roundAt(t.specs, "spec", 3).return_sha });
});

test("DoD 7, replay: a hand-appended restore row replays valid, each one-fault copy of it is invalid, and --no-round is refused", async () => {
  const t = await restoreTree([[], [REV("R1"), "- **S1** (major; operator-critical: spend-grant) grants a spend", MENTION("M1")]]);
  decide(t.specs, 1097, `operator, another ruling: ${RULING}\n`, true);
  const r2 = roundAt(t.specs, "spec", 2); const file = ledgerFile(t.specs); const base = readFileSync(file, "utf8");
  const replay = async (o: Record<string, unknown>) => { writeFileSync(file, base + restoreRow(t.specs, r2, o)); return status(t.specs); };
  const good = await replay({});
  expect(good.invalid).toEqual([]); expect(good.critical_open.map((c: { id: string }) => c.id)).toEqual(["S1", "M1"]); expect(good.restore_owed).toMatchObject([{ id: "R1", opens: 3 }]);
  for (const [o, d] of [[{ id: "S1", class: "spend-grant" }, "1096"], [{ quote: SPLIT_QUOTE }, "1096"], [{ opens: 4 }, "1096"], [{ decision: "1097" }, "1097"], [{ id: "M1" }, "1096"]] as [Record<string, unknown>, string][]) {
    const s = await replay(o);
    expect(s.invalid, JSON.stringify(o)).toEqual([`critical ${d}`]); expect(s.restore_owed, JSON.stringify(o)).toEqual([]);
    expect(s.critical_open.map((c: { id: string }) => c.id), JSON.stringify(o)).toContain(String(o.id ?? "R1"));
  }
  writeFileSync(file, base);
  const noRound = await restore(t.specs, "R1", 1096, RULING, "--no-round"); expect(noRound.err).toContain("round-critical: --restores needs a critic round to check it; drop --no-round"); expect(noRound.code).not.toBe(0);
  expect(rowsOf(t.specs, "critical")).toEqual([]);
});

test("DoD 8: closure-pack for the check round prints the finding's sealed block and under it the RESTORE-CHECK block round-status prints", async () => {
  const t = await roundTree([REV("R1")], []); decide(t.specs, 1096, RULING_FILE, true);
  expect((await restore(t.specs)).err).toBe("");
  const tok = tokenOf(t.specs, latestOf(t.specs, "spec", 5).return_sha);
  expect(await statusText(t.specs)).toContain(BLOCK(5, 6, tok));
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs); expect(pack.err).toBe(""); expect(pack.code).toBe(0);
  expect(pack.out).toContain(`${REV("R1")}\n${BLOCK(5, 6, tok)}\n`);
});

test("DoD 10: a restore spends no decision: plain records and restores share a decision both ways, and a held restore's decision restores another finding", async () => {
  const t = await restoreTree([[], [REV("R1"), REV("R3", 1101), REV("R4", 1102), "- **S1** (major; operator-critical: spend-grant) grants a spend", "- **S2** (major; operator-critical: spend-grant) grants another"]]);
  decide(t.specs, 1101, `${CAP_KEY} operator: ${SPEND}; on the park rm: ${RULING}\n`);
  decide(t.specs, 1102, `${CAP_KEY} operator: approve the second spend; on the park rm: ${RULING}\n`);
  expect((await critical(true, t.specs, "S1", 1101, SPEND)).err).toBe("");
  expect((await restore(t.specs, "R3", 1101)).err).toBe("");
  expect((await restore(t.specs, "R4", 1102)).err).toBe("");
  const plain = await critical(true, t.specs, "S2", 1102, "approve the second spend"); expect(plain.err).toBe(""); expect(plain.code).toBe(0);
  expect((await restore(t.specs)).err).toBe("");
  expect((await status(t.specs)).invalid).toEqual([]);
  const r2 = roundAt(t.specs, "spec", 2).return_sha;
  expect((await sealOn(`${t.a}.critic-spec-r3.md`, [t.a], "SPEC FINDINGS 1", REV("R2"), `RESTORE-HOLDS R3 decision 1101 ${tokenOf(t.specs, r2, 1101)}`, `RESTORE-HOLDS R4 decision 1102 ${tokenOf(t.specs, r2, 1102)}`, `RESTORE-HOLDS R1 decision 1096 ${tokenOf(t.specs, r2)}`)).err).toBe("");
  const again = await restore(t.specs, "R2"); expect(again.err).toBe(""); expect(again.code).toBe(0);
  const s = await status(t.specs); expect(s.invalid).toEqual([]); expect(s.critical_open).toEqual([]); expect(s.restore_owed).toMatchObject([{ id: "R2", decision: "1096", opens: 4 }]);
});

test("DoD 11: the capped fold refuses while a restore check is owed", async () => {
  const t = await roundTree([REV("R1")], []); decide(t.specs, 1096, RULING_FILE, true);
  expect((await restore(t.specs)).err).toBe("");
  const route = await import("./chief-route");
  await expect(route.cappedLedger(t.specs, CAP_KEY, route.cappedReader(t.specs, CAP_KEY))).rejects.toThrow("capped-fold: a restore check is owed: R1 (decision 1096) in spec round 6");
});

test("T-T1..T-T4: v1 capped-fold reads the tickets line with the one parser", async () => {
  const headerless = (tickets: string) => `---\ntickets: ${tickets}\n---\n` + fixtureSpecText.replace(/^---\ntickets: .*\n---\n/, "").replace("## Alternatives considered", "Reference: HIMMEL-8626 remains a body reference.\n\n## Alternatives considered");
  const kinds = (r: P1Run) => ["tickets must declare only", "header must declare only"].filter(t => r.err.includes(t));
  const titled = await cappedFixture({ specText: headerless(`${cappedKey} (a title)`) });
  expect(kinds(p1Fold(titled.args)), "T-T1: a titled tickets line with no Key header passes the v1 header checks").toEqual([]);
  const relates = await cappedFixture({ specText: headerless(`${cappedKey} (Relates: HIMMEL-2)`) });
  expect(p1Fold(relates.args).err, "T-T2: a key-shaped annotation still refuses on --key").toBe(p1Line(`capped-fold: tickets must declare only ${cappedKey}`));
  expect(p1Cli("--keys", cappedKey, ...p1Flags(relates.args).slice(2)).err, "T-T2: and on --keys").toContain("tickets must declare only");
  const keyless = await cappedFixture();
  await editCappedReturn(keyless, keyless.args.specReturn, text => text.replace(/^Keys?: .*\n/m, ""));
  expect(p1Fold(keyless.args), "T-T3: a return with no Key line is bound to its key by the ledger row and accepted").toMatchObject({ code: 0, err: "" });
  const bare = await cappedFixture();
  expect(kinds(p1Fold(bare.args)), "T-T4: a bare tickets line with one Key header passes (control)").toEqual([]);
});

const specAheadOfLedger = async (options: Parameters<typeof cappedFixture>[0] = {}, keyless = false) => {
  const f = await cappedFixture(options);
  const specReturns = f.verdicts.filter(p => p.includes("critic-spec-")).sort().reverse();
  for (const path of specReturns) renameSync(path, path.replace(/-r(\d+)\.md$/, (_m, n) => `-r${Number(n) + 1}.md`));
  editLedger(f, rows => rows.filter(row => row.critic === "spec" && row.verdict_path).forEach(row => { row.verdict_path = row.verdict_path.replace(/-r(\d+)\.md$/, (_m: string, n: string) => `-r${Number(n) + 1}.md`); }));
  f.args.specReturn = f.args.specReturn.replace(/-r(\d+)\.md$/, (_m, n) => `-r${Number(n) + 1}.md`);
  if (keyless) for (const path of [f.args.specReturn, f.args.planReturn]) await editCappedReturn(f, path, text => text.replace(/^Keys?: .*\n/m, ""));
  return f;
};
const v2Cli = (a: P1Args) => p1Cli("--keys", a.key, ...p1Flags(a).slice(2));

test("capped carry: a sealed closure whose file round is past its ledger round, with or without a Key line, signs on the v1 and the v2 route", async () => {
  const c = p1Cases();
  for (const keyless of [false, true]) {
    const f = await specAheadOfLedger({}, keyless);
    if (keyless) for (const path of [f.args.specReturn, f.args.planReturn]) expect([...readFileSync(path, "utf8").matchAll(/^Keys?:\s*(.+)$/gm)]).toHaveLength(0);
    await c.accepts(`ahead/${keyless ? "keyless" : "keyed"}/v1`, f, f.args, { rounds: [6, 5], residuals: [1, 0], carried: [["spec", "F1", "minor", 6]] });
    const v2 = v2Cli(f.args); expect(v2.err, `ahead/${keyless ? "keyless" : "keyed"}/v2`).toBe(""); expect(v2.code).toBe(0);
    const proof = JSON.parse(v2.out); expect(proof.mode).toBe("capped-carry-ledger");
    expect(proof.returns.map((r: any) => r.round)).toEqual([6, 5]);
    expect(proof.carried.map((x: any) => [x.kind, x.finding_id, x.severity, x.round, x.status])).toEqual([["spec", "F1", "minor", 6, "open-carried"]]);
  }
  expect(c.bad).toEqual([]);
});

test("capped carry: a keyless sealed final round still refuses a major finding, a wrong Key line, a stray later return and a changed spec", async () => {
  const major = await specAheadOfLedger({ specFindings: "- **F1** (major) a blocking gap" }, true);
  for (const run of [p1Fold(major.args), v2Cli(major.args)]) { expect(run.out).toBe(""); expect(run.err).toContain("capped-fold: ineligible finding heading: - **F1** (major) a blocking gap"); }
  const wrong = await specAheadOfLedger({}, true);
  await editCappedReturn(wrong, wrong.args.specReturn, text => `Key: HIMMEL-99999\n${text}`);
  expect(p1Fold(wrong.args).err).toBe(p1Line(`capped-fold: return must declare only ${cappedKey}`));
  const stray = await specAheadOfLedger({}, true);
  const copy = stray.args.specReturn.replace("-r6.md", "-r7.md"); copyFileSync(stray.args.specReturn, copy);
  for (const run of [p1Fold(stray.args), v2Cli(stray.args)]) expect(run.err).toContain(`ambiguous or unaccounted latest return: ${copy}`);
  const changed = await specAheadOfLedger({}, true);
  writeFileSync(changed.spec, readFileSync(changed.spec, "utf8") + "\nA later edit.\n");
  for (const run of [p1Fold(changed.args), v2Cli(changed.args)]) { expect(run.out).toBe(""); expect(run.code).toBe(1); expect(run.err).toMatch(/must review the current spec|seal provenance disagrees|missing\/extra ledger seals|Reviewed declaration/); }
});

test("capped carry: a closure return's READ quote that names no seal is context on the v2 route and still refused on the strict v1 route", async () => {
  const f = await cappedFixture();
  const stray = `READ-SHA256 ${"a".repeat(64)} /pruned-worktree/scripts/check-ci.sh\n`;
  await editCappedReturn(f, f.args.specReturn, text => stray + text);
  const v2 = v2Cli(f.args); expect(v2.err).toBe(""); expect(v2.code).toBe(0);
  expect(JSON.parse(v2.out).returns.map((r: any) => r.round)).toEqual([5, 5]);
  const v1 = p1Fold(f.args); expect(v1.out).toBe(""); expect(v1.code).toBe(1);
  const wrong = await cappedFixture();
  await editCappedReturn(wrong, wrong.args.specReturn, text => text.replace(/^(READ-SHA256 )[0-9a-f]{64}( .*estimate\.json)$/m, `$1${"b".repeat(64)}$2`));
  expect(v2Cli(wrong.args).err, "a sealed artifact's quote still has to carry its sha").toContain("capped-fold:");
  expect(v2Cli(wrong.args).code).toBe(1);
});

const planSpecOnlyQuoted = async (edit?: (text: string) => string) => {
  const { returnSha } = await import("./chief-route");
  const f = await cappedFixture(); const planReturn = f.args.planReturn; const specPath = realpathSync(f.spec);
  const text = readFileSync(planReturn, "utf8");
  const sealsSpec = (line: string) => { const m = /^CONTENT-SHA256 [0-9a-f]{64} (\S.*)$/.exec(line); return !!m && resolve(dirname(planReturn), m[1]) === specPath; };
  expect(text.split("\n").filter(sealsSpec), "the fixture's plan return seals the spec").toHaveLength(1);
  writeFileSync(planReturn, text.split("\n").filter(line => !sealsSpec(line)).join("\n"));
  const planPath = realpathSync(f.plan); const planSha = sha(readFileSync(f.plan, "utf8"));
  editLedger(f, rows => {
    for (let i = rows.length - 1; i >= 0; i--) {
      if (rows[i].return_sha !== returnSha(text)) continue;
      if (rows[i].row === "round") { rows[i].read_path = planPath; rows[i].read_sha = planSha; }
      else if (rows[i].row === "seal" && (rows[i].read_path === specPath || rows[i].read_path === planPath)) rows.splice(i, 1);
    }
  });
  if (edit) await editCappedReturn(f, planReturn, edit);
  return f;
};
const specQuote = /^READ-SHA256 ([0-9a-f]{64}) (\S*designs\/\S*\.md)$/m;

test("capped carry: a plan return whose spec is only quoted at the current sha is covered on the v2 route and refused on the strict v1 route", async () => {
  const f = await planSpecOnlyQuoted();
  expect(readFileSync(f.args.planReturn, "utf8")).toMatch(specQuote);
  const v2 = v2Cli(f.args); expect(v2.err).toBe(""); expect(v2.code).toBe(0);
  const v1 = p1Fold(f.args); expect(v1.out).toBe(""); expect(v1.err).toContain("missing/extra ledger seals or review coverage");
});

test("capped carry: a plan return whose spec is quoted at another sha or not quoted at all is refused on coverage", async () => {
  const flipped = await planSpecOnlyQuoted(text => text.replace(specQuote, (_line, digest: string, path: string) => `READ-SHA256 ${"0".repeat(64) === digest ? "1".repeat(64) : "0".repeat(64)} ${path}`));
  const wrong = v2Cli(flipped.args); expect(wrong.out).toBe(""); expect(wrong.err).toContain("missing/extra ledger seals or review coverage");
  const absent = await planSpecOnlyQuoted(text => text.replace(specQuote, "").replace(/\n\n+/g, "\n"));
  const none = v2Cli(absent.args); expect(none.out).toBe(""); expect(none.err).toContain("missing/extra ledger seals or review coverage");
});

test("capped carry: a return sealed under a file name ahead of the ledger's own offset refuses on both routes", async () => {
  const f = await specAheadOfLedger({}, true);
  const inflated = f.args.specReturn.replace("-r6.md", "-r11.md"); renameSync(f.args.specReturn, inflated);
  editLedger(f, rows => rows.filter(row => row.critic === "spec" && row.verdict_path === f.args.specReturn).forEach(row => { row.verdict_path = inflated; }));
  f.args.specReturn = inflated;
  for (const run of [p1Fold(f.args), v2Cli(f.args)]) { expect(run.out).toBe(""); expect(run.err).toContain("not the actual latest real spec round"); }
});

const signShape = (...argv: string[]): P1Run => {
  const p = Bun.spawnSync(["bun", P1_ROUTE, "sign-shape", ...argv], { stdout: "pipe", stderr: "pipe", timeout: 60_000 });
  return { code: p.exitCode, signal: p.signalCode ?? null, out: p.stdout.toString(), err: p.stderr.toString() };
};
const shapeFile = (name: string, text: string) => { const d = join(root(), "specs", "designs"); mkdirSync(d, { recursive: true }); const p = join(d, name); writeFileSync(p, text); return p; };
const shapeSpec = (tickets: string | null, rounds: string[] = [], head = "") =>
  `${tickets === null ? "" : `---\ntickets: ${tickets}\n---\n`}${head}# A spec\n\n## Critic rounds\n\n${rounds.join("\n")}\n\n## Next\n`;

test("T-G1, T-G2, T-G1b, T-G4, T-G5: sign-shape refuses the shapes the signer cannot read", () => {
  const g1 = signShape(shapeFile("HIMMEL-1-a.md", shapeSpec("HIMMEL-1", ["- R1: F1, F2 fixed"])));
  expect(g1.code, "T-G1").toBe(3); expect(g1.out).toMatch(/^SIGN-SHAPE REFUSED: .*R1: F1, F2 fixed/m);
  const g2 = signShape(shapeFile("HIMMEL-1-b.md", shapeSpec(`HIMMEL-1 (Relates: HIMMEL-2)`)));
  expect(g2.code, "T-G2 refuse").toBe(3); expect(g2.out).toMatch(/^SIGN-SHAPE REFUSED: /m);
  expect(signShape(shapeFile("HIMMEL-1-c.md", shapeSpec("HIMMEL-1", ["- R1-F1: fixed"]))), "T-G2 clean").toEqual({ code: 0, signal: null, out: "SIGN-SHAPE OK\n", err: "" });
  const g1b = signShape(shapeFile("HIMMEL-1-d.md", shapeSpec("HIMMEL-1", ["- R3-F2: fixed", "- R3-F2x: deferred → later"])));
  expect(g1b.code, "T-G1b").toBe(3); expect(g1b.out).toContain("R3-F2x: deferred → later");
  expect(signShape(shapeFile("HIMMEL-1-e.md", shapeSpec("HIMMEL-1", [], "Key: HIMMEL-2\n"))).code, "T-G4 header disagrees").toBe(3);
  expect(signShape(shapeFile("HIMMEL-3-f.md", shapeSpec("HIMMEL-1"))).code, "T-G4 file-name key undeclared").toBe(3);
  expect(signShape(shapeFile("HIMMEL-1-g.md", shapeSpec("HIMMEL-1, HIMMEL-2"))).code, "T-G4 file-name key among two").toBe(0);
  expect(signShape(shapeFile("HIMMEL-1-h.md", shapeSpec(null))).out, "T-G5 no tickets line").toBe("SIGN-SHAPE OK\n");
  const plan = shapeFile("HIMMEL-1-plan.md", shapeSpec(`HIMMEL-1 (Relates: HIMMEL-2)`));
  expect(signShape(shapeFile("HIMMEL-1-i.md", shapeSpec(null)), "--plan", plan).code, "T-G5 the plan's tickets line").toBe(3);
  expect(signShape().code, "usage").toBe(2);
});

test("T-G3: sign-shape and the signer agree on every row of the shared table", async () => {
  const { RESIDUAL_ROWS } = await import("../jira/src/release/test-residual-fixtures.ts");
  const { checkResiduals } = await import("../jira/src/release/spec-sign.ts");
  const { parseResidualLines } = await import("../jira/src/release/pinned.ts");
  const returnsFor = (section: string[]) => {
    const q = parseResidualLines(section).qualified;
    return (["spec", "plan"] as const).map(kind => {
      const round = Math.max(1, ...q.filter(x => x.kind === kind).map(x => x.round));
      const ids = [...new Set(q.filter(x => x.kind === kind && x.round === round).map(x => x.id))];
      const v = kind.toUpperCase();
      return { path: `/s/specs/designs/S.md.critic-${kind}-r${round}.md`, text: `${ids.map(id => `- **${id}** (minor) one`).join("\n")}\n\n${ids.length ? `${v} FINDINGS ${ids.length}` : `${v} CLEAN`}\n` };
    });
  };
  const verdicts = (drop?: string) => RESIDUAL_ROWS.map((row, i) => {
    const section = [...row.context, row.line];
    const shape = signShape(shapeFile(`HIMMEL-1-t${i}.md`, shapeSpec("HIMMEL-1", section))).code === 0;
    const returns = returnsFor(row.context);
    const residuals = returns.reduce((n, r) => n + (r.text.match(/^- \*\*/gm)?.length ?? 0), 0);
    const signerSection = row.line === drop ? row.context : section;
    let signer = true; try { checkResiduals(shapeSpec("HIMMEL-1", signerSection), residuals, returns); } catch { signer = false; }
    return `${row.line} :: ${shape ? "pass" : "refuse"} / ${signer ? "pass" : "refuse"}`;
  });
  const agree = RESIDUAL_ROWS.map(row => `${row.line} :: ${["idList", "nearMiss"].includes(row.cls) ? "refuse / refuse" : "pass / pass"}`);
  expect(verdicts()).toEqual(agree);
  const dropped = RESIDUAL_ROWS.find(r => r.cls === "idList")!.line;
  expect(verdicts(dropped).filter((v, i) => v !== agree[i]), "control: dropping one refuse row from the signer side breaks only that row").toEqual([`${dropped} :: refuse / pass`]);
});

test("T-T5: v1, v2, the signer's binding and sign-shape agree on one tickets table", async () => {
  const { declaredTickets } = await import("../jira/src/release/pinned.ts");
  const rows: [string, boolean][] = [[cappedKey, true], [`${cappedKey} (a title)`, true], [`[${cappedKey}]`, true], [`${cappedKey} ()`, true], [`${cappedKey} (Relates: HIMMEL-2)`, false]];
  const got = await Promise.all(rows.map(async ([tickets]) => {
    const specText = `---\ntickets: ${tickets}\n---\n` + fixtureSpecText.replace(/^---\ntickets: .*\n---\n/, "").replace("## Alternatives considered", "Reference: HIMMEL-8626 remains a body reference.\n\n## Alternatives considered");
    const f = await cappedFixture({ specText });
    const declares = (r: P1Run) => !/(?:tickets|header) must declare only/.test(r.err);
    const signer = JSON.stringify(declaredTickets(specText)) === JSON.stringify([cappedKey]);
    return [declares(p1Fold(f.args)), declares(p1Cli("--keys", cappedKey, ...p1Flags(f.args).slice(2))), signer, signShape(f.spec).code === 0];
  }));
  expect(got).toEqual(rows.map(([, ok]) => [ok, ok, ok, ok]));
});

test("T-C1: FINDING_LINE is the one imported grammar with the base source", async () => {
  const { FINDING_LINE } = await import("../jira/src/release/pinned.ts");
  expect(FINDING_LINE.source).toBe(String.raw`^[-*] \*\*([A-Za-z][\w.-]*)\*\* \(([^)]*)\)`);
  expect(readFileSync(P1_ROUTE, "utf8")).not.toMatch(/^const FINDING_LINE\b/m);
});

test("a split never lands inside a code span, and every part renders with balanced tags", () => {
  const para = (n: number) => `Paragraph ${n} with **bold ${n}** and \`code ${n} a b\` and a < b.`;
  const text = Array.from({ length: 12 }, (_, i) => para(i)).join("\n\n");
  const parts = splitParts(text, 200);
  expect(parts.length).toBeGreaterThan(2);
  for (const p of parts) {
    const html = toTelegramHtml(p);
    for (const tag of ["b", "code"]) expect(html.split(`<${tag}>`).length).toBe(html.split(`</${tag}>`).length);
    expect((p.match(/`/g) ?? []).length % 2).toBe(0);
  }
});

test("the flush hands the format flag on for a flagged reply row only", async () => {
  const r = root(); await ensureSession(r, "__chat__");
  await replyViaOutbox(r, 1, "flagged", undefined, undefined, undefined, undefined, undefined, true);
  await replyViaOutbox(r, 1, "plain");
  const seen: Array<[string, boolean | undefined]> = [];
  await flushOutboxes(r, async (_chat, text, _reply, _markup, format) => { seen.push([text, format]); return 5; });
  expect(seen).toEqual([["flagged", true], ["plain", false]]);
});

const ASK_ONE = "Needs you: approve the bypass for the station restart. Blocks: the bridge fix.";
const ASK_TWO = "Needs you: sign the release notes. Blocks: the version cut.";
async function sendAsk(r: string, text: string) { expect((await route(["--kind", "chief-reply", "1", text], { r })).code).toBe(0); }
async function answer(r: string, f: string, text: string, extra: Record<string, unknown> = {}) {
  await handleInbound(r, say(`/chief ${NAME} ${text}`, extra), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  return readFileSync(f, "utf8").split("\n").filter(Boolean).at(-1)!;
}

test("HIMMEL-10935 one open ask: a bare yes carries answers=<id> and a UTC Z stamp, and the ask closes", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, ASK_ONE);
  const line = await answer(r, f, "yes");
  expect(line).toMatch(/^- \d\d:\d\dZ \[telegram from=1 chat=1 answers=1\] yes$/);
  expect(await answer(r, f, "again")).not.toContain("answers=");
});

test("HIMMEL-10935 the inbox stamp is the UTC hour, not the local one", async () => {
  const r = root(); const f = armInbox(r);
  await handleInbound(r, say(`/chief ${NAME} hi`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  const stamp = /^- (\d\d):(\d\d)Z /.exec(readFileSync(f, "utf8"));
  expect(stamp).not.toBeNull();
  const utcMin = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();
  const got = Number(stamp![1]) * 60 + Number(stamp![2]);
  expect(Math.min((utcMin - got + 1440) % 1440, (got - utcMin + 1440) % 1440)).toBeLessThanOrEqual(2);
});

test("HIMMEL-10935 two open asks and a bare yes with no reply-to: no answers=, the line says the answer is ambiguous", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, ASK_ONE); await sendAsk(r, ASK_TWO);
  const line = await answer(r, f, "yes");
  expect(line).not.toContain("answers=");
  expect(line).toContain("ambiguous-answer=1,2");
});

test("HIMMEL-10935 a reply to a bot message carries reply_to and the quote, and picks its ask out of two", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, ASK_ONE); await sendAsk(r, ASK_TWO);
  const line = await answer(r, f, "yes", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: ASK_TWO });
  expect(line).toMatch(/\[telegram from=1 chat=1 reply_to=9001 quote="Needs you: sign the release notes\. Blocks: the version cut\." answers=2\] yes$/);
  expect(line).not.toContain("ambiguous");
});

test("HIMMEL-10935 two asks recorded at the same moment get two ids, and answering one leaves the other open", async () => {
  const r = root(); const f = armInbox(r);
  await Promise.all([sendAsk(r, ASK_ONE), sendAsk(r, ASK_TWO)]);
  expect(await answer(r, f, "yes")).toContain("ambiguous-answer=1,2");
  const one = await answer(r, f, "yes", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: ASK_ONE });
  const two = await answer(r, f, "no", { reply_to_message_id: 9002, reply_to_bot: true, reply_to_text: ASK_TWO });
  expect([one, two].map(l => /answers=(\d)/.exec(l)?.[1]).sort()).toEqual(["1", "2"]);
});

test("HIMMEL-10935 two open asks that open with the same line stay ambiguous when the reply quotes that line", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, "Needs you: two items.\n1. approve the restart");
  await sendAsk(r, "Needs you: two items.\n1. sign the notes");
  const line = await answer(r, f, "yes", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: "Needs you: two items." });
  expect(line).not.toContain("answers=");
  expect(line).toContain("ambiguous-answer=1,2");
});

test("HIMMEL-10935 a reply quoting an answered ask binds nothing and leaves the other open ask open", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, ASK_ONE); await sendAsk(r, ASK_TWO);
  expect(await answer(r, f, "yes", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: ASK_ONE })).toContain("answers=1");
  const late = await answer(r, f, "thanks", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: ASK_ONE });
  expect(late).not.toContain("answers=");
  expect(await answer(r, f, "yes")).toContain("answers=2");
});

test("HIMMEL-10935 a reply quoting an answered ask whose first line an open ask shares binds nothing and closes nothing", async () => {
  const r = root(); const f = armInbox(r);
  const FIRST = "Needs you: two items.";
  await sendAsk(r, `${FIRST}\n1. approve the restart`);
  expect(await answer(r, f, "yes")).toContain("answers=1");
  await sendAsk(r, `${FIRST}\n1. sign the notes`);
  const late = await answer(r, f, "no", { reply_to_message_id: 9001, reply_to_bot: true, reply_to_text: FIRST });
  expect(late).not.toContain("answers=");
  expect(await answer(r, f, "yes")).toContain("answers=2");
});

test("HIMMEL-10935 an ask recorded for one chief is not answered by a yes sent to another chief", async () => {
  const r = root(); const first = armInbox(r); const SECOND = "HIMMEL-nextleg-2026-09-22W-chief"; const second = armInbox(r, SECOND);
  expect((await route(["--chief", SECOND, "--kind", "chief-reply", "1", ASK_ONE], { r })).code).toBe(0);
  expect(await answer(r, first, "yes")).not.toContain("answers=");
  await handleInbound(r, say(`/chief ${SECOND} yes`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(second, "utf8").split("\n").filter(Boolean).at(-1)).toContain("answers=1");
});

test("HIMMEL-10935 a reply to a bot message that is no ask binds nothing while one ask is open", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, ASK_ONE);
  const line = await answer(r, f, "ok", { reply_to_message_id: 9005, reply_to_bot: true, reply_to_text: "Merge refused. Blocks: the merge." });
  expect(line).toContain("reply_to=9005");
  expect(line).not.toContain("answers=");
  expect(await answer(r, f, "yes")).toContain("answers=1");
});

test("HIMMEL-10935 an ask that lands in a later part of a split reply is recorded as one ask", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, `${filler(2900)}\n\n${filler(2900)}\n\nNeeds you: sign the notes. Blocks: the cut.`);
  const rows = lines(join(r, "consoles", "asks.ndjson")).map(l => JSON.parse(l));
  expect(rows).toHaveLength(1);
  expect(rows[0].quote).toMatch(/^\(2\/2\) /);
  expect(await answer(r, f, "yes")).toContain("answers=1");
});

test("HIMMEL-10935 a text with no Needs you: line records no ask", async () => {
  const r = root(); const f = armInbox(r);
  await sendAsk(r, "Merge refused. Blocks: the merge. Do: ask a reviewer");
  expect(existsSync(join(r, "consoles", "asks.ndjson"))).toBe(false);
  expect(await answer(r, f, "yes")).toMatch(/^- \d\d:\d\dZ \[telegram from=1 chat=1\] yes$/);
});

const OP = (d: number) => `${CAP_KEY} operator: ${SPEND} ${d}\n`;
const legacyClosure = (specs: string, opens: number, d: number, o: Record<string, unknown> = {}) => {
  const path = decide(specs, d, OP(d));
  return `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", closure: true, epoch: 0, opens, decision: String(d), quote: SPEND, decision_path: path, decision_sha: sha(readFileSync(path, "utf8")), ...o })}\n`;
};
const closureVerb = (specs: string, d: number, ...more: string[]) => verb(true, "round-critical", CAP_KEY, "--decision", String(d), "--quote", SPEND, "--closure", ...more, "--specs", specs);
const resetVerb = (specs: string, d: number) => verb(true, "round-reset", CAP_KEY, "--decision", String(d), "--quote", SPEND, "--specs", specs);
const lagClosureTree = async () => {
  const t = await roundTree([], []);
  for (const [i, n] of [6, 7, 8, 9].entries()) {
    appendFileSync(ledgerFile(t.specs), legacyClosure(t.specs, n, 1400 + i));
    expect((await closeOn(t, "plan", n, [t.plan], "PLAN CLEAN")).err).toBe("");
  }
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC CLEAN")).err).toBe("");
  return t;
};
const C1_MEDIUM = "- **C1** (medium; operator-critical: spend-grant) the spec grants a spend";
const lag3Tree = async (specBlocking = false) => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 3", F3_R4, BLK_N, F4_R4)).err).toBe("");
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  expect((await extend(true, t)).err).toBe("");
  const five = specBlocking ? [F3_R5, C1_MEDIUM] : [C1_MEDIUM];
  expect((await closeOn(t, "spec", 7, [t.a], `SPEC FINDINGS ${five.length}`, ...five)).err).toBe("");
  const one = "the first changed plan line"; const two = "the second changed plan line";
  writeFileSync(t.plan, `# A plan\n\n${one}\n${two}\n`);
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 2", REG("R1", one), REG("R2", two))).err).toBe("");
  return t;
};
const m2Tree = async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  return t;
};

test("HIMMEL-11321 1 lagging closure", async () => {
  const t = await lagClosureTree(); decide(t.specs, 1409, OP(1409));
  const ok = await closureVerb(t.specs, 1409, "--round", "spec:7");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ closure: true, critics: ["spec"], opens: 7 });
  const why = (await status(t.specs)).why;
  expect(why).toContain("spec round 7: closure"); expect(why).toContain(`plan round 10: ${T5(10)}`);
});

test("HIMMEL-11321 2 stale override", async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  expect((await overrideOf(t.specs, "M2")).err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC FINDINGS 1", "- **M3** (major; reopens M2) still open")).err).toBe("");
  const s = await status(t.specs);
  expect(s).toMatchObject({ spec: 7, plan: 6, invalid: [] });
  expect(s.why).toContain(`plan round 7: ${T5(7)}`);
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toContain(T5(7));
});

test("HIMMEL-11321 3 writer plus one critical", async () => {
  const t = await lag3Tree();
  decide(t.specs, 990, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "C1", 990, SPEND)).err).toBe("");
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ id: "C1", opens: 8 });
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`);
  expect((await lagExtend(t)).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toBe("");
  const s = await status(t.specs);
  expect(s).toMatchObject({ spec: 7, plan: 7, invalid: [] });
  expect(s.why).toContain(`plan round 8: ${T5(8)}`); expect(s.why).toContain("spec round 8: closure");
});

test("HIMMEL-11321 3b --round refusals", async () => {
  const t = await lagClosureTree(); decide(t.specs, 1409, OP(1409));
  const file = ledgerFile(t.specs); const before = readFileSync(file, "utf8");
  for (const at of ["plan:8", "spec:8"]) {
    const x = await closureVerb(t.specs, 1409, "--round", at);
    expect(x.err).toContain("is not a closure target"); expect(x.code).not.toBe(0);
  }
  for (const more of [["--no-round"], ["--restores"]]) {
    const x = await closureVerb(t.specs, 1409, "--round", "spec:7", ...more);
    expect(x.code, more.join(" ")).not.toBe(0);
  }
  const named = await verb(true, "round-critical", CAP_KEY, "--finding", "C1", "--decision", "1409", "--quote", SPEND, "--closure", "--round", "spec:7", "--specs", t.specs);
  expect(named.err).toContain("drop --finding"); expect(named.code).not.toBe(0);
  expect(readFileSync(file, "utf8")).toBe(before);
  const ok = await closureVerb(t.specs, 1409, "--round", "spec:7");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
});

test("HIMMEL-11321 3c critics validation", async () => {
  const t = await m2Tree(); const file = ledgerFile(t.specs); const base = readFileSync(file, "utf8");
  const replay = async (o: Record<string, unknown>) => { writeFileSync(file, base + legacyClosure(t.specs, 7, 1400, o)); return status(t.specs); };
  for (const o of [{ critics: [] }, { critics: ["spec", "spec"] }, { critics: ["draft"] }, { critics: ["plan"] }, { critics: ["spec"], epoch: 1 }]) {
    const s = await replay(o);
    expect(s.invalid, JSON.stringify(o)).toEqual(["critical 1400"]);
    expect(s.why, JSON.stringify(o)).toContain(`spec round 7: ${T5(7)}`);
  }
  const good = await replay({ critics: ["spec"] });
  expect(good.invalid).toEqual([]); expect(good.why).toContain("spec round 7: closure");
});

test("HIMMEL-11321 4a reset CLI refuses", async () => {
  const t = await m2Tree(); decide(t.specs, 1349, OP(1349));
  expect((await closureVerb(t.specs, 1349)).err).toBe("");
  const x = await resetVerb(t.specs, 1349);
  expect(x.code).not.toBe(0); expect(rowsOf(t.specs, "reset")).toEqual([]);
  const u = await m2Tree(); decide(u.specs, 1350, OP(1350));
  const ok = await resetVerb(u.specs, 1350);
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(u.specs, "reset")).toHaveLength(1); expect((await status(u.specs)).epoch).toBe(1);
});

test("HIMMEL-11321 4b reset replay invalid", async () => {
  const t = await m2Tree(); const path = decide(t.specs, 1349, OP(1349));
  expect((await closureVerb(t.specs, 1349)).err).toBe("");
  appendFileSync(ledgerFile(t.specs), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "reset", epoch: 1, decision: "1349", quote: SPEND, decision_path: path, decision_sha: sha(readFileSync(path, "utf8")) })}\n`);
  const s = await status(t.specs);
  expect(s.invalid).toEqual(["reset 1349"]); expect(s.epoch).toBe(0);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ epoch: 0, spec: 7, invalid: ["reset 1349"] });
});

test("HIMMEL-11321 5a two rounds refuse", async () => {
  const t = await lagClosureTree(); decide(t.specs, 1409, OP(1409));
  const before = readFileSync(ledgerFile(t.specs), "utf8");
  const x = await closureVerb(t.specs, 1409);
  expect(x.code).not.toBe(0); expect(x.err).toContain("--round spec:7"); expect(x.err).toContain("--round plan:10");
  expect(readFileSync(ledgerFile(t.specs), "utf8")).toBe(before);
});

test("HIMMEL-11321 5b level closure opens both", async () => {
  const t = await roundTree(["- **M1** (major) the spec is open"], ["- **P1** (major) the plan is open"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 1", "- **P2** (major; reopens P1) still open")).err).toBe("");
  expect((await overrideOf(t.specs, "M2,P2")).err).toBe("");
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 1409, OP(1409));
  const ok = await closureVerb(t.specs, 1409);
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ closure: true, critics: ["spec", "plan"], opens: 8 });
  const s = await status(t.specs);
  expect(s.invalid).toEqual([]); expect(s.why).toBe("spec round 8: closure; plan round 8: closure");
});

test("HIMMEL-11321 5c round-4 closure", async () => {
  const t = await roundTree([], []); decide(t.specs, 1409, OP(1409));
  const ok = await closureVerb(t.specs, 1409);
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical")).toMatchObject([{ closure: true, opens: 6 }]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC CLEAN")).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  expect((await status(t.specs)).invalid).toEqual([]);
});

test("HIMMEL-11321 5d lagging-only override", async () => {
  const t = await lag3Tree(); const before = readFileSync(ledgerFile(t.specs), "utf8");
  const x = await overrideOf(t.specs, "R1,R2");
  expect(x.code).not.toBe(0); expect(x.err).toContain("--closure --round plan:7 or round-extension");
  expect(readFileSync(ledgerFile(t.specs), "utf8")).toBe(before);
  const split = await lag3Tree(true); const none = await overrideOf(split.specs, "R1,R2");
  expect(none.code).not.toBe(0); expect(none.err).toContain("--closure --round plan:7,"); expect(none.err).not.toContain("round-extension");
});

test("HIMMEL-11321 5e id in both kinds", async () => {
  const t = await roundTree(["- **M1** (major) the spec is open"], ["- **P1** (major) the plan is open"]);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **X1** (major; reopens M1) still open")).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN FINDINGS 1", "- **X1** (major; reopens P1) still open")).err).toBe("");
  const ok = await overrideOf(t.specs, "X1"); expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "override")[0].findings.map((f: { critic: string }) => f.critic)).toEqual(["spec", "plan"]);
  const s = await status(t.specs);
  expect(s.invalid).toEqual([]); expect(s.why).toBe("spec round 7: closure; plan round 7: closure");
});

test("HIMMEL-11321 7a refusal suffix", async () => {
  const lagging = (kind: string, n: number) => `${kind} lags the writer round: open it with round-critical --closure --round ${kind}:${n}`;
  const a = await lagClosureTree(); const whyA = (await status(a.specs)).why;
  expect(whyA).toContain(`spec round 7: ${T5(7)} (${lagging("spec", 7)})`);
  expect(whyA.endsWith(`plan round 10: ${T5(10)}`)).toBe(true);
  const b = await lag3Tree(); const whyB = (await status(b.specs)).why;
  expect(whyB).toContain(`spec round 8: ${T5(8)}; plan round 7: ${T5(7)} (${lagging("plan", 7)} or round-extension)`);
  const c = await lag3Tree(true); const whyC = (await status(c.specs)).why;
  expect(whyC).toContain(`plan round 7: ${T5(7)} (${lagging("plan", 7)})`); expect(whyC).not.toContain("round-extension");
});

test("HIMMEL-11321 7d round-4 refusal of a lagging kind", async () => {
  const t = await roundTree([], []); decide(t.specs, 1409, OP(1409));
  expect((await closureVerb(t.specs, 1409, "--round", "plan:6")).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  const why = (await status(t.specs)).why;
  expect(why).toContain(`spec round 6: ${T1("spec")} (spec lags the writer round: open it with round-critical --closure --round spec:6)`);
  expect(why).not.toContain("round-extension");
});

test("HIMMEL-11321 7b no named kinds", async () => {
  const t = await extTree(); const path = decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  appendFileSync(ledgerFile(t.specs), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "extension", epoch: 0, round_opened: 8, findings: "not a list", returns: {}, why: "w", chief: "c", decision: "986", quote: APPROVE, decision_path: path, decision_sha: sha(readFileSync(path, "utf8")) })}\n`);
  const x = await routeCli("round-status", CAP_KEY, "--specs", t.specs, "--json");
  expect(x.code).toBe(0); expect(JSON.parse(x.out).invalid).toEqual(["extension 986"]);
});

test("HIMMEL-11321 7c empty override", async () => {
  const t = await lag3Tree(); const p4 = latestOf(t.specs, "plan", 6);
  const entry = (id: string) => ({ id, severity: "major", critic: "plan", return_sha: p4.return_sha });
  appendFileSync(ledgerFile(t.specs), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "override", epoch: 0, round_opened: 8, findings: [entry("R1"), entry("R2")], why: "a legacy override", chief: "chief-x" })}\n`);
  const s = await status(t.specs);
  expect(s.invalid).toEqual([]); expect(s.why).toContain(`spec round 8: ${T5(8)}`);
  expect((await overrideOf(t.specs, "R1,R2")).err).toContain("already used its one override");
  decide(t.specs, 1409, OP(1409));
  expect((await closureVerb(t.specs, 1409, "--round", "plan:7")).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN FINDINGS 1", "- **R3** (major; reopens R1) still broken")).err).toBe("");
  const after = await status(t.specs);
  expect(after.invalid).toEqual([]); expect(after.why).toContain(`plan round 8: ${T5(8)}`);
});

test("HIMMEL-11321 8a pre-reset opener", async () => {
  const t = await m2Tree(); expect((await overrideOf(t.specs, "M2")).err).toBe("");
  decide(t.specs, 1500, OP(1500)); expect((await resetVerb(t.specs, 1500)).err).toBe("");
  expect(await status(t.specs)).toMatchObject({ epoch: 1, spec: 0, plan: 0 });
  const r = ledgerRows(t.specs, CAP_KEY).filter(x => x.row === "round" && x.critic === "spec" && x.round === 6).at(-1);
  const fake = (round: number, findings: unknown[]) => JSON.stringify({ ...r, ts: Date.now(), epoch: 1, round, mode: round > 5 ? "closure" : "full", return_sha: sha(`a spec round ${round}`), findings, unrated_ids: [] });
  appendFileSync(ledgerFile(t.specs), `${[fake(1, []), fake(2, []), fake(3, []), fake(4, []), fake(5, []), fake(6, [{ id: "Z1", severity: "major", class: "reopens" }])].join("\n")}\n`);
  const s = await status(t.specs);
  expect(s).toMatchObject({ epoch: 1, spec: 6, invalid: [] }); expect(s.why).toContain(`spec round 7: ${T5(7)}`);
});

test("HIMMEL-11321 8b plan opener does not block a spec extension", async () => {
  const t = await roundTree(["- **M2** (major) the quota rule is stated twice"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 3", F3_R4, BLK_N, F4_R4)).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  appendFileSync(ledgerFile(t.specs), legacyClosure(t.specs, 7, 1500, { critics: ["plan"] }));
  decide(t.specs, 986, `${CAP_KEY} operator: ${APPROVE}\n`);
  const ok = await extend(true, t);
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "extension")).toHaveLength(1);
  const s = await status(t.specs);
  expect(s.invalid).toEqual([]); expect(s.why).toBe("spec round 7: closure; plan round 7: closure");
});

test("HIMMEL-11321 8c closurePack kinds", async () => {
  const t = await lag3Tree();
  decide(t.specs, 990, `${CAP_KEY} operator: ${SPEND}\n`); expect((await critical(true, t.specs, "C1", 990, SPEND)).err).toBe("");
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`); expect((await lagExtend(t)).err).toBe("");
  expect((await closeOn(t, "plan", 7, [t.plan], "PLAN CLEAN")).err).toBe("");
  appendFileSync(ledgerFile(t.specs), legacyClosure(t.specs, 8, 1500, { critics: ["plan"] }));
  const pack = await verb(false, "closure-pack", CAP_KEY, "plan", "--specs", t.specs);
  expect(pack.err).toBe(""); expect(pack.code).toBe(0);
  expect(pack.out).not.toContain("- **C1**");
});

test("HIMMEL-11321 8d level finding critical", async () => {
  const t = await roundTree(["- **M1** (major) the quota rule is stated twice"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 2", "- **M2** (major; reopens M1) still open", C1_MEDIUM)).err).toBe("");
  expect((await closeOn(t, "plan", 6, [t.plan], "PLAN CLEAN")).err).toBe("");
  decide(t.specs, 990, `${CAP_KEY} operator: ${SPEND}\n`);
  expect((await critical(true, t.specs, "C1", 990, SPEND)).err).toBe("");
  expect(rowsOf(t.specs, "critical").at(-1)).toMatchObject({ id: "C1", opens: 7 });
  const s = await status(t.specs);
  expect(s.invalid).toEqual([]); expect(s.why).toBe("spec round 7: closure; plan round 7: closure");
});

test("HIMMEL-11321 8e stored kinds", async () => {
  const t = await lag3Tree();
  decide(t.specs, 990, `${CAP_KEY} operator: ${SPEND}\n`); expect((await critical(true, t.specs, "C1", 990, SPEND)).err).toBe("");
  decide(t.specs, 987, `${CAP_KEY} operator: ${LAG_APPROVE}\n`); expect((await lagExtend(t)).err).toBe("");
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
  decide(t.specs, 988, `${CAP_KEY} operator: ${LAG_APPROVE} (a second file)\n`);
  const again = await lagExtend(t, { decision: 988 });
  expect(again.err).toContain("already open"); expect(again.code).not.toBe(0);
  expect(rowsOf(t.specs, "extension")).toHaveLength(2);
});

const ANSWERS = [{ answer: "a1", meaning: "sign the spec exactly as it stands today" }, { answer: "a2", meaning: "revise the spec and run the critic again" }];
const askedText = (answer: string, o: { options?: typeof ANSWERS; subject?: string; ask?: string; tail?: string } = {}) =>
  `${renderQuestion({ subject: o.subject ?? `${CAP_KEY} round-critical C1`, asked: null, ask: [o.ask ?? "sign it as it stands, or revise it?"], options: o.options ?? ANSWERS })}\n${answer}\n${o.tail ?? ""}`;
const askedFile = (specs: string, d: number, answer: string, o: Parameters<typeof askedText>[1] = {}, older = false) => decide(specs, d, askedText(answer, o), older);
const criticalTree = async () => {
  const t = await roundTree(["- **C1** (major; operator-critical: spend-grant) the spec grants a spend"], []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **C2** (major; reopens C1) still grants it")).err).toBe("");
  return t;
};
const capTree = async () => {
  const t = await roundTree(MAJOR, []);
  expect((await closeOn(t, "spec", 6, [t.a], "SPEC FINDINGS 1", "- **M2** (major; reopens M1) still open")).err).toBe("");
  expect((await overrideOf(t.specs, "M2")).code).toBe(0);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
  writeFileSync(t.a, front(CAP_KEY, "# A\n\na lint fix after the seal\n"));
  return t;
};
const shortClosure = (specs: string, d: number, quote: string) => verb(true, "round-critical", CAP_KEY, "--decision", String(d), "--quote", quote, "--closure", "--specs", specs);
const noInvalid = async (specs: string) => expect((await routeCli("round-status", CAP_KEY, "--specs", specs)).out).not.toContain("invalid:");
const refusedWith = async (r: Promise<{ code: number; err: string }>, specs: string, text: string) => {
  const x = await r; expect(x.err).toContain(text); expect(x.code).not.toBe(0); expect(rowsOf(specs, "critical")).toEqual([]);
};

test("short answer: round-critical a1 closes C1", async () => {
  const t = await criticalTree(); askedFile(t.specs, 1401, "a1");
  const ok = await critical(true, t.specs, "C1", 1401, "a1");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical")).toMatchObject([{ id: "C1", decision: "1401", quote: "a1" }]);
  await noInvalid(t.specs);
  expect((await closeOn(t, "spec", 7, [t.a], "SPEC CLEAN")).err).toBe("");
});

test("short answer: round-reset a1", async () => {
  const t = await roundTree(MAJOR, []); askedFile(t.specs, 1402, "a1");
  expect((await verb(true, "round-reset", CAP_KEY, "--decision", "1402", "--quote", "a1", "--specs", t.specs)).err).toBe("");
  await noInvalid(t.specs);
  const again = `${t.a}.critic-spec-r9.md`;
  writeFileSync(again, readFileSync(`${t.a}.critic-spec-r1.md`, "utf8").split("\n").filter((l) => !l.startsWith("CONTENT-SHA256 ")).join("\n"));
  expect((await seal(again, t.a, sha(front(CAP_KEY, "# A\n")))).err).toBe("");
  expect(ledgerRows(t.specs, CAP_KEY).at(-1)).toMatchObject({ row: "round", round: 1, epoch: 1 });
});

test("short answer: round-extension a1", async () => {
  const t = await extTree(); askedFile(t.specs, 986, "a1");
  expect((await extend(true, t, { quote: "a1" })).err).toBe("");
  await noInvalid(t.specs);
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
});

test("short answer: round-critical --closure yes opens the next round", async () => {
  const t = await capTree();
  askedFile(t.specs, 1403, "yes", { options: [{ answer: "yes", meaning: "open one more round" }, { answer: "no", meaning: "stop here" }] });
  const ok = await shortClosure(t.specs, 1403, "yes");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0);
  expect(rowsOf(t.specs, "critical")).toMatchObject([{ closure: true, opens: 8, quote: "yes" }]);
  await noInvalid(t.specs);
  const pack = await verb(false, "closure-pack", CAP_KEY, "spec", "--specs", t.specs);
  expect(pack.code).toBe(0); expect(pack.out).toContain(markerFor(t.specs, CAP_KEY, "spec", 8));
  expect((await closeOn(t, "spec", 8, [t.a], "SPEC CLEAN")).err).toBe("");
});

test("short answer: a short quote with no block is refused, and a hand-appended row reads invalid", async () => {
  const t = await criticalTree(); const f = decide(t.specs, 1404, `${CAP_KEY} operator:\n\na1\n`);
  await refusedWith(critical(true, t.specs, "C1", 1404, "a1"), t.specs, "or the answer to a Question block");
  const hand = (specs: string, path: string, quote: string) => appendFileSync(join(roundsDir(specs), `${CAP_KEY}.jsonl`), `${JSON.stringify({ v: 1, ts: Date.now(), key: CAP_KEY, row: "critical", epoch: 0, opens: 7, id: "C1", class: "spend-grant", decision: "1404", quote, decision_path: path, decision_sha: sha(readFileSync(path, "utf8")), return_sha: rowsOf(specs, "round").find((x) => x.critic === "spec" && x.round === 5).return_sha })}\n`);
  hand(t.specs, f, "a1");
  expect((await routeCli("round-status", CAP_KEY, "--specs", t.specs)).out).toContain("invalid: critical 1404");
  const twin = await criticalTree(); const g = decide(twin.specs, 1404, `${CAP_KEY} operator:\n\na1\n`);
  hand(twin.specs, g, `${CAP_KEY} operator:`);
  await noInvalid(twin.specs);
});

test("short answer: --closure with no block is refused", async () => {
  const t = await capTree(); decide(t.specs, 1405, `${CAP_KEY} operator:\n\nyes\n`);
  await refusedWith(shortClosure(t.specs, 1405, "yes"), t.specs, "or the answer to a Question block");
});

test("short answer: a quote that is not the listed answer is refused", async () => {
  const t = await criticalTree();
  const cases: [number, string, string, Parameters<typeof askedText>[1]?][] = [
    [1411, "a1", "a3"], [1412, "a3", "a3"], [1413, "a1", "a2"],
    [1414, "a1", "a1", { subject: "HIMMEL-2 round-critical C1", ask: `about ${CAP_KEY}?` }], [1415, "a1", "a1 for now"],
  ];
  for (const [d, answer, quote, o] of cases) {
    askedFile(t.specs, d, answer, o);
    await refusedWith(critical(true, t.specs, "C1", d, quote), t.specs, `holds no recorded question for ${CAP_KEY}`);
  }
  askedFile(t.specs, 1416, "a1", { tail: "\nand a second thing the operator never said\n" });
  await refusedWith(critical(true, t.specs, "C1", 1416, "a1"), t.specs, "has a Question block that does not hold");
});

test("short answer: the block's own text and a Context note never count", async () => {
  const t = await criticalTree();
  askedFile(t.specs, 1421, "a1"); askedFile(t.specs, 1422, "a1", { tail: "\nContext: the operator wants a longer test run\n" });
  await refusedWith(critical(true, t.specs, "C1", 1421, ANSWERS[0].meaning), t.specs, "decision 1421");
  await refusedWith(critical(true, t.specs, "C1", 1422, "the operator wants a longer test run"), t.specs, "decision 1422");
});

test("short answer: a malformed block refuses a long quote", async () => {
  const t = await criticalTree();
  decide(t.specs, 1431, `Question: ${CAP_KEY} round-critical C1\nWhy: unknown line\n\n${SPEND}\n`);
  await refusedWith(critical(true, t.specs, "C1", 1431, SPEND), t.specs, "has a Question block that does not hold");
});

test("short answer: a reused decision is refused", async () => {
  const t = await criticalTree(); askedFile(t.specs, 1441, "a1");
  await critical(true, t.specs, "C1", 1441, "a1");
  const again = await critical(true, t.specs, "C1", 1441, "a1");
  expect(again.err).toContain(`decision 1441 was already used for ${CAP_KEY}`); expect(again.code).not.toBe(0);
});

test("short answer: an older block file is refused as not newer", async () => {
  const t = await criticalTree(); askedFile(t.specs, 1442, "a1", {}, true);
  await refusedWith(critical(true, t.specs, "C1", 1442, "a1"), t.specs, "is not newer than the latest round");
});

const LINT_REFUSAL = "reads bytes the signer's trace lint refuses";
const LINT_ESTIMATE = '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n';
const lintSpecText = (o: { cite?: string; inv?: string; plan?: boolean } = {}) =>
  `---\ntickets: HIMMEL-1\n${o.plan ? "plan: ../plans/HIMMEL-1-p.md\n" : ""}---\n# D\n\nEstimate record: estimate.json\n\n## Fact ownership\n\n| Fact | Existing surfaces | Owner after | Non-owners |\n|---|---|---|---|\n| route | \`${o.cite ?? "scripts/telegram/chief-route.ts"}\` | route | n/a |\n\n## Invariants\n\n${o.inv ?? "none"}\n`;
const lintShim = (mode: "log" | "exit2" = "log") => {
  const dir = root(); const log = join(dir, "lint.log");
  const answer = mode === "exit2" ? "; echo 'shim: lint cannot run' >&2; exit 2" : "";
  writeFileSync(join(dir, "bash"), `#!/bin/sh\ncase "$*" in *minerva-trace-lint.sh*) printf '%s\\n' "$*" >> '${log}'` + answer + `;; esac\nexec '${Bun.which("bash")}' "$@"\n`);
  chmodSync(join(dir, "bash"), 0o755);
  return { env: { ...process.env, PATH: `${dir}:${process.env.PATH}` }, runs: () => existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").length : 0 };
};
const routeRun = (argv: string[], env: Record<string, string | undefined> = process.env): P1Run => {
  const p = Bun.spawnSync(["bun", P1_ROUTE, ...argv], { stdout: "pipe", stderr: "pipe", timeout: 60_000, env });
  return { code: p.exitCode, signal: p.signalCode ?? null, out: p.stdout.toString(), err: p.stderr.toString() };
};
const lintTree = async (specText: string, planText?: string, specs = specsTree().specs) => {
  const spec = join(specs, "designs", "HIMMEL-1-d.md"); writeFileSync(spec, specText);
  const plan = join(specs, "plans", "HIMMEL-1-p.md"); if (planText !== undefined) writeFileSync(plan, planText);
  const page = join(specs, "designs", "HIMMEL-1-d.html"); writeFileSync(page, "<h1>D</h1>\n");
  const estimate = join(specs, "designs", "estimate.json"); writeFileSync(estimate, LINT_ESTIMATE);
  await seedIfNeeded(specs);
  return { specs, spec, plan, page, estimate };
};
const lintReturn = (spec: string, kind: "spec" | "plan", reads: string[]) => {
  const v = `${spec}.critic-${kind}-r1.md`;
  writeFileSync(v, `read ${reads.map(f => sha(readFileSync(f, "utf8"))).join(" and ")}\n${kind.toUpperCase()} CLEAN\n`);
  return v;
};
const sealRead = (v: string, f: string) => seal(v, f, sha(readFileSync(f, "utf8")));
const refusedEveryCall = async (specs: string, v: string, reads: string[], label: string) => {
  const before = wTree(roundsDir(specs)); const text = readFileSync(v, "utf8");
  for (const f of reads) {
    const res = await sealRead(v, f);
    expect(res.err, `${label} ${basename(f)}`).toContain(LINT_REFUSAL);
    expect(res.code, `${label} ${basename(f)}`).toBe(1);
    expect(wTree(roundsDir(specs)), `${label} ${basename(f)} ledger`).toEqual(before);
    expect(readFileSync(v, "utf8"), `${label} ${basename(f)} return`).toBe(text);
  }
};

test("lint: sign-shape --lint refuses a path:line citation, with and without a plan", async () => {
  const f = await lintTree(lintSpecText({ cite: "scripts/telegram/chief-route.ts:12" }), "# P\n\n- Task 1: build.\n");
  for (const argv of [["--plan", f.plan, "--lint"], ["--lint"]]) {
    const res = routeRun(["sign-shape", f.spec, ...argv]);
    expect(res.code, argv.join(" ")).toBe(3);
    expect(res.out, argv.join(" ")).toMatch(/^SIGN-SHAPE REFUSED: minerva-trace-lint: .*chief-route\.ts:12/m);
  }
});

test("lint: sign-shape --lint accepts a lint-clean spec, with and without a plan, given as relative paths too", async () => {
  const f = await lintTree(lintSpecText({ inv: "I1. one rule." }), "# P\n\n- I1: test-x.sh\n");
  const ok = { code: 0, signal: null, out: "SIGN-SHAPE OK\n", err: "" };
  expect(routeRun(["sign-shape", f.spec, "--plan", f.plan, "--lint"])).toEqual(ok);
  expect(routeRun(["sign-shape", f.spec, "--lint"])).toEqual(ok);
  expect(routeRun(["sign-shape", relative(process.cwd(), f.spec), "--plan", relative(process.cwd(), f.plan), "--lint"])).toEqual(ok);
});

test("lint: sign-shape without --lint runs no trace lint", async () => {
  const f = await lintTree(lintSpecText({ cite: "scripts/telegram/chief-route.ts:12" }), "# P\n\n- Task 1: build.\n");
  const shim = lintShim();
  expect(routeRun(["sign-shape", f.spec, "--plan", f.plan], shim.env)).toEqual({ code: 0, signal: null, out: "SIGN-SHAPE OK\n", err: "" });
  expect(shim.runs()).toBe(0);
  expect(routeRun(["sign-shape", f.spec, "--plan", f.plan, "--lint"], shim.env).code, "control: the shim sees the lint").toBe(3);
  expect(shim.runs()).toBe(1);
});

test("lint seal: a spec return whose spec cites a bare file name is refused on every call", async () => {
  const f = await lintTree(lintSpecText({ cite: "chief-route.ts" }));
  await refusedEveryCall(f.specs, lintReturn(f.spec, "spec", [f.spec, f.page]), [f.spec, f.page], "spec return");
});

test("lint seal: a plan return whose plan names no test for an invariant is refused in either call order", async () => {
  for (const order of [["plan", "spec"], ["spec", "plan"]] as const) {
    const f = await lintTree(lintSpecText({ inv: "I1. one rule.", plan: true }), "# P\n\n- I1: build it.\n");
    const reads = order.map(k => f[k]);
    await refusedEveryCall(f.specs, lintReturn(f.spec, "plan", reads), reads, order.join(","));
  }
});

test("lint seal: a lint-clean plan return seals the plan, the spec and the estimate record", async () => {
  const f = await lintTree(lintSpecText({ inv: "I1. one rule.", plan: true }), "# P\n\n- I1: test-x.sh\n");
  const reads = [f.plan, f.spec, f.estimate]; const v = lintReturn(f.spec, "plan", reads);
  for (const read of reads) expect(await sealRead(v, read), basename(read)).toEqual({ code: 0, err: "" });
  expect(ledgerRows(f.specs, "HIMMEL-1").map(r => r.row)).toEqual(["round", "seal", "seal"]);
});

test("lint seal: a spec-kind and a plan-kind closure return whose diff adds a bare-name cell are refused", async () => {
  const { buildRoundFixture } = await import("./testlib-capped-fold.ts");
  const { closureMarker, returnSha } = await import("./chief-route");
  for (const kind of ["spec", "plan"] as const) {
    const clean = lintSpecText();
    const f = await buildRoundFixture({ scratchRoot: root(), key: "HIMMEL-1", specText: clean, planText: "# P\n\n- Task 1: build.\n",
      returns: [1, 2, 3, 4, 5].map(round => ({ kind, round,
        text: `- **M${round}** (${round === 5 ? "major" : "minor"}) a finding\n${kind.toUpperCase()} FINDINGS 1\n`,
        reads: kind === "spec" ? ["spec"] : ["spec", "plan"] })) });
    writeFileSync(f.spec, clean.replace("\n\n## Invariants", "\n| other | `chief-route.ts` | route | n/a |\n\n## Invariants"));
    const reads = kind === "spec" ? [f.spec] : [f.spec, f.plan];
    const v = `${f.spec}.critic-${kind}-r6.md`;
    writeFileSync(v, `read ${reads.map(p => sha(readFileSync(p, "utf8"))).join(" and ")}\n${closureMarker("HIMMEL-1", kind, 6, returnSha(readFileSync(f.verdicts.at(-1)!, "utf8")))}\n${kind.toUpperCase()} CLEAN\n`);
    await refusedEveryCall(f.specsRoot, v, reads, `${kind} closure`);
  }
});

test("lint seal: a spec in another git repo may cite a path of that repo", async () => {
  const t = specsTree();
  expect(Bun.spawnSync(["git", "init", "-q", t.specs]).exitCode).toBe(0);
  mkdirSync(join(t.specs, "only-here")); writeFileSync(join(t.specs, "only-here", "source.ts"), "export {};\n");
  const f = await lintTree(lintSpecText({ cite: "only-here/source.ts" }), undefined, t.specs);
  const v = lintReturn(f.spec, "spec", [f.spec]);
  expect(await sealRead(v, f.spec)).toEqual({ code: 0, err: "" });
});

test("lint seal: a trace lint that cannot run is a NOTE, not a refusal, at the seal and at sign-shape --lint", async () => {
  const f = await lintTree(lintSpecText({ cite: "chief-route.ts" }));
  const shim = lintShim("exit2");
  const v = lintReturn(f.spec, "spec", [f.spec]);
  const note = "NOTE: trace lint unavailable (shim: lint cannot run); not checked\n";
  const sealed = routeRun(["critic-round-check", v, f.spec], shim.env);
  expect(sealed.err).toBe(note);
  expect(sealed.code).toBe(0);
  expect(ledgerRows(f.specs, "HIMMEL-1").map(r => r.row)).toEqual(["round"]);
  expect(routeRun(["sign-shape", f.spec, "--lint"], shim.env)).toEqual({ code: 0, signal: null, out: "SIGN-SHAPE OK\n", err: note });
  expect(shim.runs()).toBe(2);
});
