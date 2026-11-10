import { expect, test, spyOn } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, symlinkSync, unlinkSync, renameSync, statSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { classify } from "./router";
import { BASH_BIN, buildPrompt } from "./run";
import { sendMessage } from "./telegram-api";
import { appendLine, ensureSession, writeMeta, sessionDir } from "./bus";
import { handleInbound, replyViaOutbox, flushOutboxes, ingestUpdates, makeRunFn } from "./poller";
import { consoleInboxPath, foldLine, renderMarkdownHtml, type ConsoleRouteGate } from "./chief-route";

// Every test runs against a scratch bridge root and a fake reply
// seam, never the real ~/.claude/handover/bridge, never Telegram.
const root = () => mkdtempSync(join(tmpdir(), "chief-route-"));
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
  expect(readFileSync(f, "utf8").replace(/^- \d\d:\d\d /, "")).toBe("[telegram from=1 chat=1] go ahead\n");
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
  expect(lines[0]).toMatch(/^- \d\d:\d\d \[telegram from=1 chat=1\] go ahead with PR 12$/);
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
    expect(readFileSync(f, "utf8")).toContain(`[telegram from=1 chat=1] ${text}`);
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
  expect(JSON.parse(out)).toEqual({ text: "answer", console: NAME });
});

test("reply CLI appends one line to the chat's outbox under a scratch BRIDGE_ROOT", async () => {
  const r = root();
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", "1", "done", "with", "PR 12"], { env: { ...process.env, BRIDGE_ROOT: r }, stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(0);
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").split("\n").filter(Boolean);
  expect(out.map((l) => JSON.parse(l))).toEqual([{ text: "done with PR 12" }]);
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
  expect(JSON.parse(fresh.line!)).toEqual({ text: "answer", console: NAME });
  expect(old.code).toBe(1);
  expect(old.line).toBeNull();
  expect(old.err).toContain("usage: bun chief-route.ts reply");
});

async function owedReply(r: string, doc: string, flush: boolean, extra: string[] = ["--owed", "sig-1", "--doc", doc]) {
  const p = Bun.spawn(["bun", join(import.meta.dir, "chief-route.ts"), "reply", "--chief", NAME, ...extra, "1", "please sign"], {
    env: { ...process.env, BRIDGE_ROOT: r, CHIEF_ROUTE_RECEIPT_WAIT_SEC: flush ? "20" : "1" }, stdout: "pipe", stderr: "pipe",
  });
  const out = new Response(p.stdout).text(); const err = new Response(p.stderr).text();
  const outbox = join(r, "sessions", "__chat__", "outbox.jsonl");
  if (flush) {
    for (let i = 0; i < 100 && !existsSync(outbox); i++) await new Promise(res => setTimeout(res, 100));
    await flushOutboxes(r, async () => 4242);
  }
  return { code: await p.exited, out: await out, err: await err };
}

test("reply --owed prints the Telegram message id from the poller's send receipt and writes the DELIVERED bullet", async () => {
  const r = root(); heartbeat(r);
  const doc = join(r, "chief.md"); writeFileSync(doc, "# chief\n- 10:00 OWED sig-1 sign it\n");
  mkdirSync(join(r, "consoles", "replies"), { recursive: true });
  writeFileSync(join(r, "consoles", "replies", "1_100.json"), JSON.stringify({ name: NAME }));
  const res = await owedReply(r, doc, true);
  expect(res.code).toBe(0);
  expect(res.out).toContain("delivered msg=4242");
  expect(readFileSync(doc, "utf8")).toMatch(/\n- \d\d:\d\d DELIVERED sig-1 msg=4242 chat=1\n$/);
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

test("R1.4 replay 11-07: the operator gets the 4 controls, the spool the 4 monitor lines, the 5 silent lines nothing", async () => {
  const replay = readFileSync(join(FIX, "replay-11-07.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { time: string; kind?: string; expect: string; text: string });
  expect(replay).toHaveLength(13);
  const after = JSON.parse(readFileSync(TABLE, "utf8"));
  for (const row of after.kinds) { if (row.kind === "hold-ask-chief") row.class = "silent"; if (row.kind === "denial-page") row.class = "monitor"; }
  const dir = mkdtempSync(join(tmpdir(), "chief-route-table-")); const afterS4 = join(dir, "after-s4.json"); writeFileSync(afterS4, JSON.stringify(after));
  const r = root();
  for (const l of replay) {
    const x = await route([...(l.kind ? ["--kind", l.kind] : []), "operator", l.text], { r, table: afterS4 });
    expect(x.code).toBe(0);
    expect(x.out.trim()).toBe(l.expect);
  }
  const queued = operatorOutbox(r).map((m) => m.text);
  expect(queued).toHaveLength(4);
  expect(spool(r)).toHaveLength(4);
  expect(spool(r).map((m) => m.kind)).toEqual(["cadence:vault-stall", "cadence:vm-maintain-login-himmel-claudex", "cache-health", "denial-page"]);
  for (const t of [...queued, ...spool(r).map((m) => m.text)]) plainWords(t);
  expect(routeLog(r)).toHaveLength(13);
  const s1 = root();
  for (const l of replay) await route([...(l.kind ? ["--kind", l.kind] : []), "operator", l.text], { r: s1 });
  expect(operatorOutbox(s1)).toHaveLength(6);
  expect(spool(s1)).toHaveLength(3);
});

test("R1.5 the cap: 900 characters of merge-blocked come out at 400 or fewer with the Do: step whole; a long Do: step and chief-reply go uncut", async () => {
  const text = longMerge(900);
  const x = await route(["--kind", "merge-blocked", "operator", text]);
  const sent = operatorOutbox(x.r)[0].text;
  expect(sent.length).toBeLessThanOrEqual(400);
  expect(sent.endsWith(DO_STEP)).toBe(true);
  const cutDir = join(x.r, "route-cut");
  const files = readdirSync(cutDir);
  expect(files).toHaveLength(1);
  expect(readFileSync(join(cutDir, files[0]), "utf8")).toBe(text);
  expect(sent).toContain(`full text on the station: ${join(cutDir, files[0])}`);
  expect(routeLog(x.r)[0].endsWith(" cut")).toBe(true);

  const withTrailer = `${longMerge(900).slice(0, -DO_STEP.length)} Do: go.sh HIMMEL-1 abc`;
  const t = await route(["--kind", "merge-blocked", "operator", withTrailer]);
  const sentT = operatorOutbox(t.r)[0].text;
  expect(sentT.length).toBeLessThanOrEqual(400);
  expect(sentT.endsWith("Do: go.sh HIMMEL-1 abc")).toBe(true);
  expect(routeLog(t.r)[0].endsWith(" cut")).toBe(true);

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
  expect(operatorOutbox(a.r)).toEqual([{ text: "Merge refused. Blocks: x. Do: y", console: NAME }]);
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
  const text = longMerge(900);
  if (process.getuid?.() !== 0) {
    const mirror = mkdtempSync(join(tmpdir(), "chief-route-mirror-")); cpSync(FIX_MIRROR, join(mirror, "HIMMEL"), { recursive: true });
    chmodSync(join(mirror, "HIMMEL", "HIMMEL-9012.md"), 0);
    const raw = "A worker on HIMMEL-9012 needs a file. Blocks: that worker. Do: run it";
    const x = await route(["--kind", "merge-blocked", "operator", raw], { env: { HIMMEL_JIRA_MIRROR: join(mirror, "HIMMEL") } });
    expect(x.code).toBe(0); expect(x.out.trim()).toBe("escalate");
    expect(operatorOutbox(x.r).map((m) => m.text)).toEqual([raw]);
    expect(routeLog(x.r)[0]).toContain(" escalate-fallback ");
  }
  const r2 = root(); writeFileSync(join(r2, "route-cut"), "a file, so mkdir fails");
  const y = await route(["--kind", "merge-blocked", "operator", text], { r: r2 });
  expect(y.code).toBe(0); expect(y.out.trim()).toBe("escalate");
  expect(operatorOutbox(r2).map((m) => m.text)).toEqual([text]);
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
  expect(JSON.parse(line!)).toEqual({ text: "two PRs open" });
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
  expect(JSON.parse(line!)).toEqual({ text: "hi" });
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
  expect(readFileSync(next, "utf8")).toContain("[telegram from=1 chat=1] status please\n");
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

const sendFile = async (r: string, ...args: string[]) => {
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

// <r>/specs/designs/design.md + design.plan.md, each with a clean round-1 critic file sealed to its bytes.
const bundle = (r: string) => {
  const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const spec = join(dir, "design.md"); const plan = join(dir, "design.plan.md");
  writeFileSync(spec, "# Design\n\nthe spec\n"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(spec, "spec", 1, "SPEC CLEAN", { text: "# Design\n\nthe spec\n", file: "design.md" });
  critic(spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "design.plan.md" });
  return { dir, spec, plan };
};

test("send-file refuses a spec whose latest spec critic is NO-GO, names that verdict file and queues nothing", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 3", { text: "# Design\n\nthe spec\n", file: "design.md" });
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(existsSync(join(r, "outgoing"))).toBe(false);
});

test("send-file reads the highest round numerically: r10 findings beat a clean r9", async () => {
  const r = root(); const b = bundle(r);
  const sealed = { text: "# Design\n\nthe spec\n", file: "design.md" };
  critic(b.spec, "spec", 9, "SPEC CLEAN", sealed); critic(b.spec, "spec", 10, "SPEC FINDINGS 1", sealed);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);   // past the three rounds the page goes with its findings on it, and r10 is the one it shows
  expect(res.lines[0].caption).toContain("SPEC FINDINGS 1 r10");
  expect(readFileSync(res.lines[0].document_path as string, "utf8")).toContain("design.md.critic-spec-r10.md");
});

test("send-file refuses a plan whose latest plan critic is NO-GO, naming the plan verdict file", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "plan", 2, "PLAN FINDINGS 2", { text: "# Plan\n\nthe plan\n", file: "design.plan.md" });
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
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", { text: "# Design\n\nthe spec\n", file: "design.md" });
  const link = join(r, "innocent.md"); symlinkSync(b.spec, link);
  const res = await sendFile(r, "1", link);
  expect(res.code).not.toBe(0);
  expect(res.lines).toEqual([]);
});

test("send-file finds the plan critic beside the spec when the plan lives in specs/plans/, and refuses it on a NO-GO", async () => {
  const r = root(); const b = bundle(r);
  const plans = join(r, "specs", "plans"); mkdirSync(plans);
  const plan = join(plans, "design.plan.md"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(b.spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "../plans/design.plan.md" });
  const ok = await sendFile(r, "1", plan);
  expect(ok.code).toBe(0);
  critic(b.spec, "plan", 2, "PLAN FINDINGS 1", { text: "# Plan\n\nthe plan\n", file: "../plans/design.plan.md" });
  const no = await sendFile(r, "1", plan);
  expect(no.code).not.toBe(0);
  expect(no.err).toContain("design.md.critic-plan-r2.md");
  expect(no.lines.length).toBe(1);   // only the first send queued
});

test("checkSignaturePage hands back the exact bytes it hashed, so the page sent is the page the critic read", async () => {
  const { checkSignaturePage } = await import("./chief-route");
  const r = root(); const b = bundle(r);
  const res = await checkSignaturePage(b.spec);
  expect(res!.bytes.toString("utf8")).toBe("# Design\n\nthe spec\n");
  expect(await checkSignaturePage(join(r, "elsewhere.txt"))).toBeNull();
});

const SEAL_SH =join(import.meta.dir, "..", "handover", "chief-kit", "critic-seal.sh");
const seal = async (...args: string[]) => {
  const p = Bun.spawn([BASH_BIN, SEAL_SH, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: await p.exited, err: await new Response(p.stderr).text() };
};

test("critic-seal.sh adds the CONTENT-SHA256 line above the verdict line, and refuses a file that no longer hashes to the quoted sha", async () => {
  const r = root(); const spec = join(r, "specs", "designs", "d.md"); mkdirSync(join(r, "specs", "designs"), { recursive: true });
  writeFileSync(spec, "# D\n");
  const v = `${spec}.critic-spec-r1.md`; writeFileSync(v, `the critic's return, which read ${sha("# D\n")}\nSPEC CLEAN\n`);
  const ok = await seal(v, spec, sha("# D\n"));
  expect(ok.code).toBe(0);
  expect(readFileSync(v, "utf8")).toBe(`the critic's return, which read ${sha("# D\n")}\nCONTENT-SHA256 ${sha("# D\n")} d.md\nSPEC CLEAN\n`);
  expect((await seal(v, spec, sha("# D\n"))).code).not.toBe(0);   // the same file sealed twice is refused, not stacked
  const staleSha = sha("# D, as the critic read it\n");
  const v2 = `${spec}.critic-spec-r2.md`; writeFileSync(v2, `return quoting ${staleSha}\nSPEC CLEAN\n`);
  const stale = await seal(v2, spec, staleSha);
  expect(stale.code).not.toBe(0);
  expect(readFileSync(v2, "utf8")).toBe(`return quoting ${staleSha}\nSPEC CLEAN\n`);   // nothing written
  const v3 = `${spec}.critic-spec-r3.md`; writeFileSync(v3, `return with no verdict line ${sha("# D\n")}\n`);
  expect((await seal(v3, spec, sha("# D\n"))).code).not.toBe(0);
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
  const r = root(); const spec = join(r, "specs", "designs", "d.md"); mkdirSync(join(r, "specs", "designs"), { recursive: true });
  writeFileSync(spec, "# D\n");
  const v = `${spec}.critic-spec-r1.md`;
  writeFileSync(v, `read ${sha("# D\n")}\n${"a long finding line\n".repeat(20000)}SPEC CLEAN\n`);   // about 400 KB
  const res = await seal(v, spec, sha("# D\n"));
  expect(res.err).toBe("");
  expect(res.code).toBe(0);
  expect(readFileSync(v, "utf8")).toContain(`CONTENT-SHA256 ${sha("# D\n")} d.md\nSPEC CLEAN\n`);
});

test("critic-seal.sh seals each distinct file a critic read, and refuses only the same file twice", async () => {
  const r = root(); const dir = join(r, "specs", "designs"); mkdirSync(dir, { recursive: true });
  const md = join(dir, "d.md"); const html = join(dir, "d.html"); writeFileSync(md, "# D\n"); writeFileSync(html, "<h1>D</h1>\n");
  const v = `${md}.critic-spec-r1.md`; writeFileSync(v, `read ${sha("# D\n")} and ${sha("<h1>D</h1>\n")}\nSPEC CLEAN\n`);
  expect((await seal(v, md, sha("# D\n"))).code).toBe(0);
  expect((await seal(v, html, sha("<h1>D</h1>\n"))).code).toBe(0);
  expect((await seal(v, html, sha("<h1>D</h1>\n"))).code).not.toBe(0);
  const lines = readFileSync(v, "utf8").split("\n");
  expect(lines.filter((l) => l.startsWith("CONTENT-SHA256 "))).toEqual([`CONTENT-SHA256 ${sha("# D\n")} d.md`, `CONTENT-SHA256 ${sha("<h1>D</h1>\n")} d.html`]);
  expect(lines.at(-2)).toBe("SPEC CLEAN");
});

// A spec critic that read several files seals each one.
const criticSeals = (spec: string, kind: "spec" | "plan", round: number, verdict: string, sealed: { text: string; file: string }[]) =>
  writeFileSync(`${spec}.critic-${kind}-r${round}.md`, `critic return, round ${round}\n${sealed.map((s) => `CONTENT-SHA256 ${sha(s.text)} ${s.file}\n`).join("")}${verdict}\n`);

test("send-file refuses a spec critic that seals another path than the spec", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC CLEAN", { text: "# Plan\n\nthe plan\n", file: "design.plan.md" });
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-spec-r2.md");
  expect(res.err).toContain("does not seal design.md");
  expect(res.lines).toEqual([]);
});

test("send-file refuses a plan page while the spec critic failed", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", { text: "# Design\n\nthe spec\n", file: "design.md" });
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
  const b = bundle(r); const page = join(b.dir, "design.html"); writeFileSync(page, html);
  const sealed = [{ text: "# Design\n\nthe spec\n", file: "design.md" }, { text: html, file: "design.html" }];
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
  expect(res.err).toContain("design.html");
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
  critic(b.spec, "spec", 2, "SPEC CLEAN", { text: "# Design\n\nthe spec\n", file: "design.md" });   // round 2 read the .md only
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
  const own = [{ text: b.html, file: "design.html" }];
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

test("send-file compares plan critic rounds across folders: a newer FINDINGS in plans/ beats an older clean one beside the spec, and a same-round tie needs both clean", async () => {
  const r = root(); const l = planLayout(r);
  critic(l.spec, "plan", 1, "PLAN CLEAN", { text: "# X plan\n", file: "../plans/X.md" });   // r1 beside the spec; plans/ also holds r1 (clean)
  const bothClean = await sendFile(r, "1", l.spec);
  expect(bothClean.err).toBe(""); expect(bothClean.code).toBe(0);
  critic(l.plan, "plan", 1, "PLAN FINDINGS 1", { text: "# X plan\n", file: "X.md" });       // tie at r1, one of them FINDINGS
  for (const f of [l.spec, l.plan]) {
    const tie = await sendFile(r, "1", f);
    expect(tie.code).not.toBe(0);
    expect(tie.err).toContain(join("plans", "X.md.critic-plan-r1.md"));
  }
  critic(l.plan, "plan", 2, "PLAN FINDINGS 2", { text: "# X plan\n", file: "X.md" });       // newer round in plans/
  const newer = await sendFile(r, "1", l.spec);
  expect(newer.code).not.toBe(0);
  expect(newer.err).toContain(join("plans", "X.md.critic-plan-r2.md"));
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
  expect(res.err).toContain("does not seal design.md");
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
  const plan = join(plans, "design.plan.md"); writeFileSync(plan, "# Plan\n\nthe plan\n");
  critic(b.spec, "plan", 1, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "../plans/design.plan.md" });
  critic(b.spec, "plan", 2, "PLAN CLEAN", { text: "# Plan\n\nthe plan\n", file: "design.plan.md" });   // round 2 read the copy beside the spec
  const res = await sendFile(r, "1", plan);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("design.md.critic-plan-r2.md");
  expect(res.err).toContain("does not seal design.plan.md");
  expect(res.lines).toEqual([]);
});

// The real layout: specs/designs/X.md with spec critics beside it; the plan is the same-named specs/plans/X.md,
// whose plan critics sit beside the PLAN.
const planLayout = (r: string) => {
  const designs = join(r, "specs", "designs"); const plans = join(r, "specs", "plans");
  mkdirSync(designs, { recursive: true }); mkdirSync(plans, { recursive: true });
  const spec = join(designs, "X.md"); const plan = join(plans, "X.md");
  writeFileSync(spec, "# X spec\n"); writeFileSync(plan, "# X plan\n");
  critic(spec, "spec", 1, "SPEC CLEAN", { text: "# X spec\n", file: "X.md" });
  critic(plan, "plan", 1, "PLAN CLEAN", { text: "# X plan\n", file: "X.md" });
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
  critic(l.plan, "plan", 2, "PLAN FINDINGS 2", { text: "# X plan\n", file: "X.md" });
  for (const f of [l.plan, l.spec]) {
    const res = await sendFile(r, "1", f);
    expect(res.code).not.toBe(0);
    expect(res.err).toContain(join("plans", "X.md.critic-plan-r2.md"));
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
  critic(second, "plan", 1, "PLAN FINDINGS 1", { text: "# X plan\n", file: "../plans/X.md" });
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
const marked = (r: string, extra = "") => `<!doctype html><meta name="spec-source" content="${join(r, "specs", "designs", "design.md")}"><h1>Design</h1>\n${extra}`;
const copyOf = (r: string, html: string, name = "elsewhere.html") => { const d = join(r, "copies"); mkdirSync(d, { recursive: true }); const f = join(d, name); writeFileSync(f, html); return f; };

test("send-file checks a marked page copied outside the registered folders under another stem, and sends it only when a critic sealed its bytes", async () => {
  const r = root(); const html = marked(r); const b = htmlBundle(r, html);
  const copy = copyOf(r, html);
  criticSeals(b.spec, "spec", 1, "SPEC FINDINGS 2", b.sealed);
  const refused = await sendFile(r, "1", copy);
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("design.md.critic-spec-r1.md");
  expect(refused.lines).toEqual([]);
  criticSeals(b.spec, "spec", 2, "SPEC CLEAN", b.sealed);
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
  const gone = await sendFile(r, "1", copyOf(r, html.replace("design.md", "gone.md"), "gone.html"));
  expect(gone.code).not.toBe(0);
  expect(gone.err).toContain("gone.md");
  expect(edited.lines.concat(gone.lines)).toEqual([]);
});

test("send-file reads the marker whatever the attribute order or quote style, and still checks the copy", async () => {
  const r = root(); const md = join(r, "specs", "designs", "design.md");
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
  criticSeals(b.spec, "spec", 2, "SPEC CLEAN", [b.sealed[0], { text: clean, file: "design.html" }]);
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
  criticSeals(b.spec, "spec", 2, "SPEC CLEAN", [b.sealed[0], { text: marked, file: "design.html" }]);
  const { checkSignaturePage } = await import("./chief-route");
  await expect(checkSignaturePage(b.page)).rejects.toThrow("Not for signature");
  expect((await sendFile(r, "1", b.page)).code).not.toBe(0);
});

// ---- a spec gets three critic rounds per kind, then the page goes to the operator with each open finding on it ----
const D_TEXT = "# Design\n\nthe spec\n";
const P_TEXT = "# Plan\n\nthe plan\n";
const D_SEAL = { text: D_TEXT, file: "design.md" };
const P_SEAL = { text: P_TEXT, file: "design.plan.md" };
// A bundle whose spec critic used all three rounds with findings still open: r1 and r2 hold finding-one and finding-two.
const threeRounds = (r: string) => {
  const b = bundle(r);
  critic(b.spec, "spec", 1, "SPEC FINDINGS 1", D_SEAL);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(`${b.spec}.critic-spec-r3.md`, `**F1.** finding-one <the tag> stays open\n**F2.** finding-two stays open\nCONTENT-SHA256 ${sha(D_TEXT)} design.md\nSPEC FINDINGS 2\n`);
  return b;
};
const unsealedReturn = (file: string, text: string, verdict = "SPEC FINDINGS 1") => writeFileSync(file, `return, read ${sha(text)}\n${verdict}\n`);
const grant = (r: string, spec: string, round: number, decision = 900, withVerbatim = true) => {
  writeFileSync(`${spec}.operator-round-r${round}.md`, `Operator allows this round.\ndecision ${decision}\n`);
  if (!withVerbatim) return;
  mkdirSync(join(r, "specs", "decisions"), { recursive: true });
  writeFileSync(join(r, "specs", "decisions", `verbatim-decision-${decision}-operator.txt`), "yes, one more\n");
};

test("DoD 1: a spec with 3 recorded rounds cannot get a fourth without an operator record, and one record grants exactly one round", async () => {
  const r = root(); const b = threeRounds(r);
  const r4 = `${b.spec}.critic-spec-r4.md`; unsealedReturn(r4, D_TEXT);
  const refused = await seal(r4, b.spec, sha(D_TEXT));
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("operator-round-r4.md");
  expect(readFileSync(r4, "utf8")).not.toContain("CONTENT-SHA256");
  grant(r, b.spec, 4, 900, false);   // a record whose decision has no verbatim file allows nothing
  expect((await seal(r4, b.spec, sha(D_TEXT))).code).not.toBe(0);
  grant(r, b.spec, 4);
  expect((await seal(r4, b.spec, sha(D_TEXT))).code).toBe(0);
  const r5 = `${b.spec}.critic-spec-r5.md`; unsealedReturn(r5, D_TEXT);
  expect((await seal(r5, b.spec, sha(D_TEXT))).code).not.toBe(0);
});

test("readCriticBudget reports the counted paths from the cap's own pass and the exception for the exact requested round only", async () => {
  const { readCriticBudget } = await import("./chief-route");
  const r = root(); const b = threeRounds(r);
  expect(await readCriticBudget(b.spec, "spec")).toMatchObject({ count: 3, numbered: 3, requestedRound: 4, operatorAllowed: false, cap: 3, renamed: [] });
  expect((await readCriticBudget(b.spec, "spec", 4)).numberedFiles).toEqual([1, 2, 3].map(n => ({ round: n, path: `${b.spec}.critic-spec-r${n}.md` })));
  grant(r, b.spec, 4);
  expect((await readCriticBudget(b.spec, "spec", 4)).operatorAllowed).toBe(true);
  expect((await readCriticBudget(b.spec, "spec", 5)).operatorAllowed).toBe(false);
  const plan = await readCriticBudget(b.spec, "plan");
  expect(plan).toMatchObject({ count: 1, requestedRound: 2, renamed: [] });
  expect(plan.numberedFiles.map(f => [f.round, basename(f.path)])).toEqual([[1, "design.md.critic-plan-r1.md"]]);
});

test("DoD 1: an unsealed fourth round found on disk still keeps the page from going without an operator record", async () => {
  const r = root(); const b = threeRounds(r);
  unsealedReturn(`${b.spec}.critic-spec-r4.md`, D_TEXT);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("critic-spec-r4.md");
  expect(res.lines).toEqual([]);
});

test("DoD 2: a page sent after round 3 opens with the count and the rule line, and shows each open finding verbatim", async () => {
  const r = root(); const b = threeRounds(r);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  const html = readFileSync(res.lines.at(-1)!.document_path, "utf8");
  const lead = html.slice(html.indexOf("<body>"));
  expect(lead.indexOf("Round count: spec 3, plan 1. 1 critic did not end clean.")).toBeGreaterThan(-1);
  expect(lead.indexOf("Round count")).toBeLessThan(lead.indexOf("Rule, don't just sign"));
  expect(lead.indexOf("Rule, don't just sign")).toBeLessThan(lead.indexOf("finding-one"));
  expect(lead.indexOf("finding-two")).toBeLessThan(lead.indexOf("<h1"));   // the page's own text follows the block
  expect(html).toContain("finding-one &lt;the tag&gt; stays open");
  expect(html).toContain("design.md.critic-spec-r3.md");
  expect(res.lines.at(-1)!.caption).toContain("SPEC FINDINGS 2 r3");
});

test("DoD 2: a sealed .html page past round 3 goes as the sealed bytes with the block after <body>", async () => {
  const r = root(); const b = threeRounds(r);
  const page = join(b.dir, "design.html"); const pageText = "<!doctype html><html><head><title>D</title></head><body><h1>D</h1></body></html>\n";
  writeFileSync(page, pageText);
  writeFileSync(`${b.spec}.critic-spec-r3.md`, `**F1.** finding-one\nCONTENT-SHA256 ${sha(D_TEXT)} design.md\nCONTENT-SHA256 ${sha(pageText)} design.html\nSPEC FINDINGS 1\n`);
  const res = await sendFile(r, "1", page);
  expect(res.code).toBe(0);
  const sent = readFileSync(res.lines.at(-1)!.document_path, "utf8");
  expect(sent).toContain("finding-one");
  expect(sent.indexOf("<body>")).toBeLessThan(sent.indexOf("Round count"));
  expect(sent.replace(/<section class="open-findings">[\s\S]*<\/section>\n/, "")).toBe(pageText);
  writeFileSync(page, pageText + "<!-- edited after round 3 -->\n");   // the exact bytes round 3 read, or nothing
  const edited = await sendFile(r, "1", page);
  expect(edited.code).not.toBe(0);
  expect(edited.err).toContain("critic-spec-r3.md");
});

test("DoD 2: rounds 1 and 2 with findings stay refused, and each kind must reach 3 on its own count", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", D_SEAL);
  expect((await sendFile(r, "1", b.spec)).code).not.toBe(0);
  const r2 = root(); const t = threeRounds(r2);
  critic(t.spec, "plan", 2, "PLAN FINDINGS 1", P_SEAL);
  const plan2 = await sendFile(r2, "1", t.spec);
  expect(plan2.code).not.toBe(0);
  expect(plan2.err).toContain("critic-plan-r2.md");
  critic(t.spec, "plan", 3, "PLAN FINDINGS 2", P_SEAL);
  const plan3 = await sendFile(r2, "1", t.spec);
  expect(plan3.code).toBe(0);
  const html = readFileSync(plan3.lines.at(-1)!.document_path, "utf8");
  expect(html).toContain("Round count: spec 3, plan 3. 2 critics did not end clean.");
  expect(html).toContain("design.md.critic-plan-r3.md");
});

test("a spec already past 3 still goes with its findings when it is the bytes its last critic read, and its next round needs a record", async () => {
  const r = root(); const b = bundle(r);
  for (const n of [7, 8, 9]) critic(b.spec, "spec", n, "SPEC FINDINGS 4", D_SEAL);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  expect(readFileSync(res.lines.at(-1)!.document_path, "utf8")).toContain("Round count: spec 9, plan 1.");
  const r10 = `${b.spec}.critic-spec-r10.md`; unsealedReturn(r10, D_TEXT);
  const next = await seal(r10, b.spec, sha(D_TEXT));
  expect(next.code).not.toBe(0);
  expect(next.err).toContain("operator-round-r10.md");
});

const sendSealedPage = async (r: string, b: ReturnType<typeof bundle>, pageText: string) => {
  const page = join(b.dir, "design.html"); writeFileSync(page, pageText);
  writeFileSync(`${b.spec}.critic-spec-r3.md`, `**F1.** finding-one\nCONTENT-SHA256 ${sha(D_TEXT)} design.md\nCONTENT-SHA256 ${sha(pageText)} design.html\nSPEC FINDINGS 1\n`);
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
    const r = root(); const res = await sendSealedPage(r, threeRounds(r), pageText);
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
    const r = root(); const res = await sendSealedPage(r, threeRounds(r), pageText);
    expect(res.code).toBe(0);
    const sent = readFileSync(res.lines.at(-1)!.document_path, "utf8");
    expect(sent.indexOf("<body class=")).toBeLessThan(sent.indexOf("Round count"));
    expect(sent.indexOf("Round count")).toBeLessThan(sent.indexOf("<h1>D"));
    expect(sent.replace(/<section class="open-findings">[\s\S]*<\/section>\n/, "")).toBe(pageText);
  }
});

test("planted: one sealed return named for the third round does not open a page early, though it does bring the cap closer", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 3, "SPEC FINDINGS 1", D_SEAL);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("critic-spec-r3.md");
  expect(res.lines).toEqual([]);
  const r4 = `${b.spec}.critic-spec-r4.md`; unsealedReturn(r4, D_TEXT);
  expect((await seal(r4, b.spec, sha(D_TEXT))).err).toContain("operator-round-r4.md");
});

test("DoD 3: a scope edit on the same spec does not reset the count", async () => {
  const r = root(); const b = threeRounds(r);
  const edited = "# Design\n\nthe spec, with a wider scope\n"; writeFileSync(b.spec, edited);
  const r4 = `${b.spec}.critic-spec-r4.md`; unsealedReturn(r4, edited);
  const res = await seal(r4, b.spec, sha(edited));
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("operator-round-r4.md");
});

test("DoD 3, planted: a renamed critic cannot restart the count, under any new name", async () => {
  const r = root(); const b = threeRounds(r);
  for (const name of ["design.md.critic-fresh-r1.md", "design.md.critic-spec-opus-r1.md", "design.md.critic-r1.md", "fresh.critic-spec-r1.md", "other.md.critic-spec-r1.md"]) {
    const v = join(b.dir, name); unsealedReturn(v, D_TEXT, "SPEC CLEAN");
    const res = await seal(v, b.spec, sha(D_TEXT));
    expect(res.code).not.toBe(0);
    expect(res.err).toContain("operator-round-r4.md");
    expect(readFileSync(v, "utf8")).not.toContain("CONTENT-SHA256");
    unlinkSync(v);
  }
});

test("DoD 3, planted: a renamed critic on disk counts as a round, so round 3 is reached sooner, not restarted", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(join(b.dir, "fresh.critic-spec-r1.md"), `renamed return\nCONTENT-SHA256 ${sha(D_TEXT)} design.md\nSPEC FINDINGS 1\n`);
  const r3 = `${b.spec}.critic-spec-r3.md`; unsealedReturn(r3, D_TEXT);
  const res = await seal(r3, b.spec, sha(D_TEXT));
  expect(res.code).not.toBe(0);
  expect(res.err).toContain("operator-round-r4.md");
});

test("DoD 4: a judge round is not counted and not limited", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC CLEAN", D_SEAL);
  for (let i = 1; i <= 9; i++) writeFileSync(`${b.spec}.judge-r${i}.md`, `judge round ${i}\nVERDICT: SPEC FINDINGS 1\n`);
  const r3 = `${b.spec}.critic-spec-r3.md`; unsealedReturn(r3, D_TEXT);
  expect((await seal(r3, b.spec, sha(D_TEXT))).code).toBe(0);   // 9 judge rounds, and the third critic round is still free
  const r4 = `${b.spec}.critic-spec-r4.md`; unsealedReturn(r4, D_TEXT);
  const res = await seal(r4, b.spec, sha(D_TEXT));
  expect(res.err).toContain("3 spec critic rounds");   // the count names critics alone
  writeFileSync(`${b.spec}.judge-r10.md`, "a tenth judge round is written with no record\n");
  expect(existsSync(`${b.spec}.operator-round-r4.md`)).toBe(false);
});

test("planted: a renamed return cannot open the page before round 3, and past it the page lists that return too", async () => {
  const r = root(); const b = bundle(r);
  critic(b.spec, "spec", 2, "SPEC FINDINGS 1", D_SEAL);
  writeFileSync(join(b.dir, "fresh.critic-spec-r1.md"), `renamed return, finding-renamed\nCONTENT-SHA256 ${sha(D_TEXT)} design.md\nSPEC FINDINGS 1\n`);
  const early = await sendFile(r, "1", b.spec);
  expect(early.code).not.toBe(0);
  expect(early.err).toContain("design.md.critic-spec-r2.md");
  expect(early.lines).toEqual([]);
  critic(b.spec, "spec", 3, "SPEC FINDINGS 1", D_SEAL);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  const page = readFileSync(res.lines[0].document_path as string, "utf8");
  expect(page).toContain("finding-renamed");
  expect(page).toContain("Round count: spec 4, plan 1. 2 critics did not end clean.");
});

test("DoD 4: a judge return that ends in a verdict line can be sealed past the cap, and adds no round", async () => {
  const r = root(); const b = threeRounds(r);
  const judge = `${b.spec}.judge-r1.md`; unsealedReturn(judge, D_TEXT, "SPEC CLEAN");
  expect((await seal(judge, b.spec, sha(D_TEXT))).code).toBe(0);
  const res = await sendFile(r, "1", b.spec);
  expect(res.code).toBe(0);
  expect(readFileSync(res.lines[0].document_path as string, "utf8")).toContain("Round count: spec 3, plan 1.");
});

test("DoD 4: every judge file name in use can be sealed past the cap", async () => {
  const r = root(); const b = threeRounds(r);
  for (const name of ["judge.md", "judge2.md", "judge-input.md"]) {
    const judge = `${b.spec}.${name}`; unsealedReturn(judge, D_TEXT, "SPEC CLEAN");
    expect((await seal(judge, b.spec, sha(D_TEXT))).code).toBe(0);
  }
});

test("planted: a spec named like a judge file still gets three rounds", async () => {
  const r = root(); const b = bundle(r);
  const spec = join(b.dir, "judge-design.md"); writeFileSync(spec, D_TEXT);
  for (const n of [1, 2, 3]) critic(spec, "spec", n, "SPEC FINDINGS 1", { text: D_TEXT, file: "judge-design.md" });
  const r4 = `${spec}.critic-spec-r4.md`; unsealedReturn(r4, D_TEXT);
  const refused = await seal(r4, spec, sha(D_TEXT));
  expect(refused.code).not.toBe(0);
  expect(refused.err).toContain("operator-round-r4.md");
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
  expect((await seal(`${nspec}.critic-spec-r1.md`, nspec, sha("# P\n"))).code).toBe(0);
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
