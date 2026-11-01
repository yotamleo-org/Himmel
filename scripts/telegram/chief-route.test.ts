import { expect, test, spyOn } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, symlinkSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { classify } from "./router";
import { BASH_BIN, buildPrompt } from "./run";
import { sendMessage } from "./telegram-api";
import { appendLine, ensureSession, writeMeta, sessionDir } from "./bus";
import { handleInbound, replyViaOutbox, flushOutboxes, ingestUpdates, makeRunFn } from "./poller";
import { consoleInboxPath, foldLine, type ConsoleRouteGate } from "./chief-route";

// Every test runs against a scratch bridge root and a fake reply
// seam — never the real ~/.claude/handover/bridge, never Telegram.
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
    for (const text of ["hello", "work on HIMMEL-1", "HIMMEL-1: x", "HIMMEL-1: delete lockdown", "/restart", "/restart full"]) await inbound(r, fresh(text, { from }), replies, ran, fired);
    expect(ran).toEqual([]);
    expect(fired).toEqual([]);
    expect(existsSync(join(r, "sessions", "HIMMEL-1", "inbox.jsonl"))).toBe(false);
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

test("HIMMEL-7573: the pick-a-chief prompts tell the operator to send /chief, never /console", async () => {
  for (const text of ["/chief halt", "/chief HIMMEL halt"]) {
    const r = root(); const replies: string[] = [];
    heartbeat(r); heartbeat(r, "HIMMEL-second-chief");
    await handleInbound(r, say(text), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
    expect(replies.join("\n")).toContain("choose /chief <name> <text>");
    expect(replies.join("\n")).not.toContain("/console");
  }
});

test("HIMMEL-8381: /chief queues the line; the dropped /console alias queues nothing", async () => {
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
// O_CREAT-free — see bus.test.ts for the TOCTOU-race regression at the
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
  for (const text of ["thanks, halt", "HIMMEL-123: halt"]) {
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

test("HIMMEL-5125: bare /chief queues to the only armed console whose waiter is stale within the busy TTL", async () => {
  const r = root(); const f = heartbeat(r, NAME, "waiting", 900);
  const reply = await routeText(r, "/chief halt the wave");
  expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] halt the wave");
  expect(reply).toContain("queued");
  expect(reply).toContain(BUSY_SAY);
});

test("HIMMEL-5125: a waiter that exited on a wake reason is busy, not released", async () => {
  const r = root(); const f = armInbox(r);
  writeFileSync(f + ".wait", `hb=${Math.floor(Date.now() / 1000) - 60} pid=123 key=- tick=ok state=exited exit=wake-tick\n`);
  const reply = await routeText(r, "/chief halt the wave");
  expect(readFileSync(f, "utf8")).toContain("halt the wave");
  expect(reply).toContain(BUSY_SAY);
});

test("HIMMEL-5125: a fleet verb queues to a busy console", async () => {
  const r = root(); const f = heartbeat(r, NAME, "sampling", 900); const replies: string[] = [];
  await inbound(r, fresh("/fleet"), replies);
  expect(readFileSync(f, "utf8")).toContain("] fleet status\n");
  expect(replies.join("\n")).toContain(BUSY_SAY);
});

test("HIMMEL-5125: a unique name fragment routes to its console and is stripped from the text", async () => {
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

test("HIMMEL-5125: an ambiguous fragment lists the candidates and sends nothing", async () => {
  const r = root(); const a = heartbeat(r, "x-chief-aa"); const b = heartbeat(r, "x-chief-bb");
  const reply = await routeText(r, "/chief console do it");
  expect(readFileSync(a, "utf8")).toBe("");
  expect(readFileSync(b, "utf8")).toBe("");
  expect(reply).toContain("x-chief-aa");
  expect(reply).toContain("x-chief-bb");
});

test("HIMMEL-5125: a dead or released console still bounces", async () => {
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

test("HIMMEL-8196: bare /chief with two live chiefs of one lineage reaches the newest", async () => {
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

test("HIMMEL-8196: two live chiefs of different lineages are still refused", async () => {
  const r = root(); heartbeat(r, NEWEST); heartbeat(r, "HIMMEL-nextleg-2026-10-30B-other-chief");
  const reply = await routeText(r, "/chief halt");
  expect(reply).toContain("More than one chief is live");
  expect(readFileSync(join(r, "consoles", `${NEWEST}.md`), "utf8")).toBe("");
});

test("HIMMEL-8196: an explicit name or unique fragment still pins the older chief", async () => {
  const r = root(); const old = heartbeat(r, OLD); heartbeat(r, NEWEST);
  await routeText(r, `/chief ${OLD} keep it`);
  expect(readFileSync(old, "utf8")).toContain("] keep it");
  writeFileSync(old, "");
  await routeText(r, "/chief KE keep it");
  expect(readFileSync(old, "utf8")).toContain("] keep it");
  expect(readFileSync(join(r, "consoles", `${NEWEST}.md`), "utf8")).toBe("");
});

test("HIMMEL-8196: the alias chief:himmel resolves to the newest chief across a simulated handover", async () => {
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

test("HIMMEL-8196: an alias with no live chief, or two lineages, queues nothing", async () => {
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

test("HIMMEL-8196: a Send-to-chief tap from outside allowFrom is refused and writes nothing", async () => {
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

test("HIMMEL-8196: an allowed Send-to-chief tap prompts for the text and the reply lands in the newest chief's inbox", async () => {
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

test("HIMMEL-8196: the picker lists the newest chief first and a pick pins that chief", async () => {
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

test("HIMMEL-8196: a tap that is not a chief button falls through, and with no live chief nothing is prompted", async () => {
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
  await appendLine(out, JSON.stringify({ document_path: "/x/spec.html", caption: "the spec" }));
  const texts: any[] = []; const docs: any[] = [];
  await flushOutboxes(r, async (chat, text) => { texts.push([chat, text]); }, async (chat, path, caption) => { docs.push([chat, path, caption]); return true; });
  expect(texts).toEqual([[5, "plain"]]);
  expect(docs).toEqual([[5, "/x/spec.html", "the spec"]]);
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
  const send = makeSendDoc("123:FAKE", r, (async (...a: any[]) => { uploads.push(a); return true; }) as any);
  expect(await send(7, ok, "cap")).toBe(true);
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
  const send = makeSendDoc("123:FAKE", r, (async (...a: any[]) => { uploads.push(a); return true; }) as any);
  for (const bad of [secret, link, join(dirLink, "secret.env"), join(sibling, "a.txt"), join(out, "..", "secret.env")]) expect(await send(7, bad)).toBe(false);
  expect(uploads).toEqual([]);
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
  await appendLine(join(sessionDir(r, "__chat__"), "outbox.jsonl"), JSON.stringify({ text: "here it is", document_path: "/x/spec.html" }));
  const texts: string[] = []; const docs: string[] = [];
  await flushOutboxes(r, async (_c, text) => { texts.push(text); }, async (_c, path) => { docs.push(path); return true; });
  expect(texts).toEqual(["here it is"]);
  expect(docs).toEqual(["/x/spec.html"]);
});

test("the bridge prompt offers the document channel to a private chat and not to a group", () => {
  const paths = { inbox: "/b/sessions/s/in.jsonl", outbox: "/b/sessions/s/outbox.jsonl", context: "c", cwd: "/r" };
  expect(buildPrompt("__chat__", paths)).toContain("/b/outgoing");
  expect(buildPrompt("group_-50", paths)).not.toContain("outgoing");
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
