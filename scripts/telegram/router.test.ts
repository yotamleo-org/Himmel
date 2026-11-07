import { expect, test } from "bun:test";
import { classify } from "./router";

// `approve <pr> <hex>` parses to a closed route; any other shape stays chat.
test("classifies approve <pr> <hex> and routes a malformed line nowhere", () => {
  expect(classify("approve 7 a1a1a1a")).toEqual({ kind: "approve", pr: 7, prefix: "a1a1a1a" });
  expect(classify("  Approve #123 A1B2C3D4  ")).toEqual({ kind: "approve", pr: 123, prefix: "a1b2c3d4" });
  expect(classify(`approve 7 ${"a".repeat(40)}`)).toEqual({ kind: "approve", pr: 7, prefix: "a".repeat(40) });
  expect(classify("approve 7 abc")).toEqual({ kind: "approve", pr: 7, prefix: "abc" });   // too short: the handler refuses it with a reason
  for (const t of ["approve", "approve 7", "approve seven a1a1a1a", "approve 7 zzzzzzz", "approve 0 a1a1a1a", "approve 1234567 a1a1a1a", `approve 7 ${"a".repeat(41)}`, "approve 7 a1a1a1a now", "approve 7\na1a1a1a x", "please approve 7 a1a1a1a", "approved 7 a1a1a1a", "/approve 7 a1a1a1a"]) {
    expect(classify(t).kind, t).toBe("chat");
  }
});

test("classifies control/dispatch/followup/chat + validates key", () => {
  expect(classify("status")).toEqual({ kind: "control", verb: "status" });
  expect(classify("stop HIMMEL-9")).toEqual({ kind: "control", verb: "stop", ticket: "HIMMEL-9" });
  expect(classify("work on HIMMEL-216")).toEqual({ kind: "dispatch", ticket: "HIMMEL-216" });
  expect(classify("ABC-216: also do Z")).toEqual({ kind: "followup", ticket: "ABC-216", text: "also do Z" });
  expect(classify("hello there")).toEqual({ kind: "chat", text: "hello there" });
  expect(classify("work on lol-rm -rf")).toEqual({ kind: "chat", text: "work on lol-rm -rf" });
});

test("classifies /arm auto-commands (ticket|path + optional time), default smart", () => {
  // ticket arg, no time suffix → smart
  expect(classify("/arm HIMMEL-389")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
  // path arg → smart
  expect(classify("/arm handovers/yotam/x.md")).toEqual({ kind: "auto", op: "arm-resume", arg: "handovers/yotam/x.md", time: "smart" });
  // explicit time forms
  expect(classify("/arm HIMMEL-389 at 02:00")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "02:00" });
  expect(classify("/arm HIMMEL-389 auto")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "auto" });
  expect(classify("/arm HIMMEL-389 smart")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
  // leading/trailing whitespace tolerated (whole-message trim)
  expect(classify("  /arm HIMMEL-389  ")).toEqual({ kind: "auto", op: "arm-resume", arg: "HIMMEL-389", time: "smart" });
});

test("/arm with bad/missing pieces or mid-text falls through to chat (never auto)", () => {
  // garbage time → not auto
  expect(classify("/arm HIMMEL-389 at 99:99")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 at 99:99" });
  expect(classify("/arm HIMMEL-389 at 2pm")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 at 2pm" });
  // unknown trailing modifier → not auto
  expect(classify("/arm HIMMEL-389 now")).toEqual({ kind: "chat", text: "/arm HIMMEL-389 now" });
  // no arg → chat
  expect(classify("/arm")).toEqual({ kind: "chat", text: "/arm" });
  // mid-text /arm → chat (not anchored at start)
  expect(classify("please /arm HIMMEL-389")).toEqual({ kind: "chat", text: "please /arm HIMMEL-389" });
});

test("classifies /mergepub <pr> <sha12> auto-commands", () => {
  expect(classify("/mergepub 123 abcdef123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // optional leading # on the PR number
  expect(classify("/mergepub #123 abcdef123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // full 40-char SHA accepted
  const sha40 = "0123456789abcdef0123456789abcdef01234567".slice(0, 40);
  expect(classify(`/mergepub 9 ${sha40}`)).toEqual({ kind: "auto", op: "merge-public", arg: "9", time: sha40 });
  // case-insensitive verb + hex, but the captured SHA is normalized to lowercase
  // (git oids are lowercase; auto-action.sh + the chokepoint compare lowercase).
  expect(classify("/MERGEPUB 123 ABCDEF123456")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
  // leading/trailing whitespace tolerated (whole-message trim)
  expect(classify("  /mergepub 123 abcdef123456  ")).toEqual({ kind: "auto", op: "merge-public", arg: "123", time: "abcdef123456" });
});

test("/mergepub with bad/missing pieces or mid-text falls through to chat (never auto)", () => {
  // sha too short (<12 hex), 11 hex is one below the floor, must fall through
  expect(classify("/mergepub 123 abcdef12345")).toEqual({ kind: "chat", text: "/mergepub 123 abcdef12345" });
  // sha too long (>40 hex), the trailing chars break the whole-message anchor
  const sha41 = "0123456789abcdef0123456789abcdef012345678";
  expect(classify(`/mergepub 123 ${sha41}`)).toEqual({ kind: "chat", text: `/mergepub 123 ${sha41}` });
  // sha not hex
  expect(classify("/mergepub 123 not-a-sha")).toEqual({ kind: "chat", text: "/mergepub 123 not-a-sha" });
  // pr not numeric
  expect(classify("/mergepub abc abcdef123456")).toEqual({ kind: "chat", text: "/mergepub abc abcdef123456" });
  // pr too long (>6 digits)
  expect(classify("/mergepub 1234567 abcdef123456")).toEqual({ kind: "chat", text: "/mergepub 1234567 abcdef123456" });
  // missing sha
  expect(classify("/mergepub 123")).toEqual({ kind: "chat", text: "/mergepub 123" });
  // no args
  expect(classify("/mergepub")).toEqual({ kind: "chat", text: "/mergepub" });
  // mid-text → chat (not anchored at start)
  expect(classify("please /mergepub 123 abcdef123456")).toEqual({ kind: "chat", text: "please /mergepub 123 abcdef123456" });
  // trailing garbage after a valid pair → chat (whole-message anchor)
  expect(classify("/mergepub 123 abcdef123456 please")).toEqual({ kind: "chat", text: "/mergepub 123 abcdef123456 please" });
});

// --- /restart ---

test("/restart classifies as the restart auto-op, rung in arg", () => {
  expect(classify("/restart")).toEqual({ kind: "auto", op: "restart", arg: "poller", time: "-" });
  expect(classify("  /restart  ")).toEqual({ kind: "auto", op: "restart", arg: "poller", time: "-" });
  expect(classify("/RESTART")).toEqual({ kind: "auto", op: "restart", arg: "poller", time: "-" });
  expect(classify("/restart full")).toEqual({ kind: "auto", op: "restart", arg: "full", time: "-" });
  expect(classify("/restart FULL")).toEqual({ kind: "auto", op: "restart", arg: "full", time: "-" });
});

test("/restart is anchored on the WHOLE message — anything else is chat", () => {
  // A stray /restart inside a sentence must never bounce the bridge.
  for (const t of [
    "please /restart the bridge",
    "/restart now",
    "/restart full please",
    "/restarted",
    "/restart --hard",
    "/restart poller",
  ]) {
    expect(classify(t).kind).toBe("chat");
  }
});

// the chief verbs are case-insensitive and accept Telegram's
// `/cmd@<bot>` addressing; a mid-text or trailing /chief stays chat.
test("/chief is case-insensitive and accepts /chief@<bot>", () => {
  expect(classify("/Chief foo bar baz")).toEqual({ kind: "console", name: "foo", text: "bar baz" });
  expect(classify("/CHIEF@MyBot foo bar")).toEqual({ kind: "console", name: "foo", text: "bar" });
  expect(classify("/chief@mybot hello there", "MyBot")).toEqual({ kind: "console", name: "hello", text: "there" });
  expect(classify("/chief@mybot\nfoo bar")).toEqual({ kind: "console", name: "foo", text: "bar" });
  expect(classify("/chief@mybot just text")).toEqual({ kind: "console", name: "just", text: "text" });
  expect(classify("/Chiefs")).toEqual({ kind: "consoles" });
  expect(classify("/chiefs@mybot", "mybot")).toEqual({ kind: "consoles" });
});

test("a mid-text, trailing, or other-bot /chief stays chat", () => {
  for (const t of [
    "Note that we had the issue when console is in queue again /chief. Let's also use the cloud",
    "please /chief foo bar",
    "again /chief",
    "/consolex foo bar",
    "/chiefs foo",
    "/chief@",
    "/chief@bad-bot foo bar",
  ]) expect(classify(t).kind).toBe("chat");
  expect(classify("/chief@otherbot foo bar", "mybot").kind).toBe("chat");
  expect(classify("/chiefs@otherbot", "mybot").kind).toBe("chat");
});

test("/chief and /chiefs route like /console and /consoles", () => {
  expect(classify("/chief foo bar baz")).toEqual({ kind: "console", name: "foo", text: "bar baz" });
  expect(classify("/Chief@mybot just text", "mybot")).toEqual({ kind: "console", name: "just", text: "text" });
  expect(classify("/chiefs")).toEqual({ kind: "consoles" });
  for (const t of ["/chiefx foo bar", "/chiefs foo", "please /chief foo bar"]) expect(classify(t).kind).toBe("chat");
});

test("the old /console and /consoles aliases are gone and classify as chat", () => {
  for (const t of ["/console x", "/console foo bar baz", "/console@mybot foo bar", "/consoles"]) {
    expect(classify(t, "mybot").kind).toBe("chat");
  }
});

// fleet verbs and /lockdown take the same case-insensitive verb and
// `/cmd@<bot>` addressing as /chief; the worker label stays exact.
test("fleet verbs are case-insensitive and accept /cmd@<bot>", () => {
  expect(classify("/Fleet")).toEqual({ kind: "fleet", verb: "status" });
  expect(classify("/fleet@MyBot", "mybot")).toEqual({ kind: "fleet", verb: "status" });
  // bot name unknown: an @ suffix is unverifiable, so only halt/lockdown accept it
  expect(classify("/fleet@anybot").kind).toBe("chat");
  expect(classify("/go@anybot N1").kind).toBe("chat");
  expect(classify("/halt@anybot")).toEqual({ kind: "fleet", verb: "halt" });
  expect(classify("/WORKERS")).toEqual({ kind: "fleet", verb: "workers" });
  expect(classify("/legs")).toEqual({ kind: "fleet", verb: "workers" });
  expect(classify("/HALT")).toEqual({ kind: "fleet", verb: "halt" });
  expect(classify("/halt@mybot", "mybot")).toEqual({ kind: "fleet", verb: "halt" });
  expect(classify("/Go N1490")).toEqual({ kind: "fleet", verb: "go?", worker: "N1490" });
  expect(classify("/GO@mybot N1490", "mybot")).toEqual({ kind: "fleet", verb: "go?", worker: "N1490" });
  expect(classify("/Push@mybot Worker_A", "mybot")).toEqual({ kind: "fleet", verb: "push", worker: "Worker_A" });
  expect(classify("/halt@mybot N1490", "mybot")).toEqual({ kind: "fleet", verb: "halt", worker: "N1490" });
});

test("malformed or other-bot fleet shapes keep their refusal/chat split", () => {
  for (const t of ["/Go", "/go@mybot", "/fleet@mybot now", "/Go ../x", "/push@mybot a b"]) expect(classify(t, "mybot").kind).toBe("fleet-malformed");
  for (const t of ["/fleet@otherbot", "/go@otherbot N1", "/lockdown@otherbot", "/gopher", "/workersx", "/legsx", "/fleet@", "/fleet@bad-bot"]) expect(classify(t, "mybot").kind).toBe("chat");
});

test("/lockdown is case-insensitive and accepts /lockdown@<bot>", () => {
  expect(classify("/Lockdown")).toEqual({ kind: "lockdown" });
  expect(classify("/LOCKDOWN@MyBot", "mybot")).toEqual({ kind: "lockdown" });
  expect(classify("/lockdown now").kind).toBe("chat");
});

// Auto ops authorise bridge actions without the agent: they stay strict.
test("/Arm and /arm@<bot> (and other auto ops) authorise nothing", () => {
  for (const t of ["/Arm HIMMEL-389", "/ARM HIMMEL-389", "/arm@mybot HIMMEL-389", "/Arm@mybot HIMMEL-389 at 02:00",
    "/Mergepub@mybot 12 0123456789ab", "/restart@mybot", "/Restart@mybot full", "/Station-Status", "/confirm@mybot 0123abcd", "/Cr-Reset 12", "/cr-grant-delta@mybot 12 " + "a".repeat(40)]) {
    expect(classify(t, "mybot").kind).toBe("chat");
  }
});
