import { expect, test } from "bun:test";
import type { PeerMsgRec } from "./gate";
import { ACK_BY, ANSWER_BY, CLOSE_BY, Threads, effectiveRoute, templateLine, type Action, type ThreadRec } from "./threads";
import { CHAT, H, MIN, T0, clock, inbound, mkThread, rootMsg, sig, states, threadsOf } from "./testlib-threads";

type DL = "same" | "null" | number; // an absolute offset from `now` in ms, null, or unchanged
type Cell = { name: string; rec: Partial<ThreadRec> & { state: string }; dir: "out" | "in"; ev: string; by?: number; sig: string[]; state?: string; deadline?: DL };

const NOW = T0 + 100 * H;
const out = (state: string, over: Partial<ThreadRec> = {}) => ({ state, ...over });

const OUT_TERMINAL = ["UNREACHABLE", "EXPIRED", "DECLINED", "CLOSED", "CLOSED-BY-PEER"];
const IN_TERMINAL = ["ANSWERED", "DECLINED", "EXPIRED", "CLOSED-BY-PEER"];
const WAKE_PEER = ["wake:peer message"];

const outbound: Cell[] = [];
const cell = (c: Cell) => outbound.push(c);
// Outbound thread (we opened it): SENT, AWAITING, NUDGED, ANSWERED.
for (const [state, base] of [["SENT", { deadline: T0 + ACK_BY }], ["AWAITING", { deadline: T0 + ANSWER_BY }], ["NUDGED", { deadline: T0 + 2 * ANSWER_BY }], ["ANSWERED", { deadline: T0 + CLOSE_BY }]] as [string, Partial<ThreadRec>][]) {
  const rec = out(state, base);
  const sent = state === "SENT", answered = state === "ANSWERED";
  cell({ name: `${state} receipt`, dir: "out", rec, ev: "tpl:receipt", sig: sent ? ["state:AWAITING"] : [], state: sent ? "AWAITING" : state, deadline: sent ? NOW + 24 * H : "same" });
  cell({ name: `${state} answer`, dir: "out", rec, ev: "answer", sig: answered ? ["wake:answer"] : ["state:ANSWERED", "wake:answer"], state: "ANSWERED", deadline: answered ? "same" : NOW + 72 * H });
  const clamped = Math.min(Math.max(NOW + 24 * H, NOW + 72 * H + H), T0 + 73 * H);
  cell({ name: `${state} deferred`, dir: "out", rec, ev: "tpl:deferred", by: NOW + 72 * H, sig: answered ? [] : sent ? ["state:AWAITING"] : ["state:" + state], state: answered ? state : sent ? "AWAITING" : state, deadline: answered ? "same" : clamped });
  for (const ev of ["tpl:nudge", "untagged", "ask:info"]) cell({ name: `${state} ${ev}`, dir: "out", rec, ev, sig: WAKE_PEER, state, deadline: "same" });
  cell({ name: `${state} closing`, dir: "out", rec, ev: "tpl:closing", sig: answered ? ["state:CLOSED", "wake:closed"] : ["state:CLOSED-BY-PEER", "wake:closed by peer"], state: answered ? "CLOSED" : "CLOSED-BY-PEER", deadline: "null" });
  for (const ev of ["tpl:declined-kind", "tpl:busy"]) cell({ name: `${state} ${ev}`, dir: "out", rec, ev, sig: sent ? ["state:DECLINED", "wake:declined"] : [], state: sent ? "DECLINED" : state, deadline: sent ? "null" : "same" });
}
// Deadlines of the outbound table.
cell({ name: "SENT deadline resends once", dir: "out", rec: out("SENT", { deadline: T0 + ACK_BY }), ev: "deadline", sig: ["resend", "state:SENT"], state: "SENT", deadline: NOW + 12 * H });
cell({ name: "SENT deadline after the resend is UNREACHABLE", dir: "out", rec: out("SENT", { deadline: T0 + ACK_BY, resent: true }), ev: "deadline", sig: ["send:closing", "state:UNREACHABLE", "wake:unreachable"], state: "UNREACHABLE", deadline: "null" });
cell({ name: "AWAITING deadline nudges", dir: "out", rec: out("AWAITING", { deadline: T0 + ANSWER_BY }), ev: "deadline", sig: ["send:nudge", "state:NUDGED"], state: "NUDGED", deadline: NOW + 24 * H });
cell({ name: "NUDGED deadline expires", dir: "out", rec: out("NUDGED", { deadline: T0 + 2 * ANSWER_BY }), ev: "deadline", sig: ["send:closing", "state:EXPIRED", "wake:expired"], state: "EXPIRED", deadline: "null" });
cell({ name: "ANSWERED deadline closes", dir: "out", rec: out("ANSWERED", { deadline: T0 + CLOSE_BY }), ev: "deadline", sig: ["send:closing", "state:CLOSED", "wake:closed"], state: "CLOSED", deadline: "null" });
// Terminal outbound states.
for (const state of OUT_TERMINAL) {
  const rec = out(state, { deadline: null });
  cell({ name: `${state} answer wakes and never reopens`, dir: "out", rec, ev: "answer", sig: ["wake:answer on a closed thread"], state, deadline: "null" });
  for (const ev of ["tpl:receipt", "tpl:deferred", "tpl:nudge", "untagged", "tpl:closing", "tpl:busy"]) cell({ name: `${state} ${ev} is ignored`, dir: "out", rec, ev, sig: [], state, deadline: "null" });
}

const inbox: Cell[] = [];
const icell = (c: Cell) => inbox.push(c);
// Inbound thread (they opened it): OPEN, DEFERRED.
for (const [state, base] of [["OPEN", { deadline: T0 + ANSWER_BY, remindAt: null }], ["DEFERRED", { deadline: T0 + 3 * ANSWER_BY }]] as [string, Partial<ThreadRec>][]) {
  const rec = { ...base, state };
  icell({ name: `${state} we answer`, dir: "in", rec, ev: "ours:answer", sig: ["state:ANSWERED"], state: "ANSWERED", deadline: "null" });
  icell({ name: `${state} we decline`, dir: "in", rec, ev: "ours:decline", sig: ["send:declined-kind", "state:DECLINED"], state: "DECLINED", deadline: "null" });
  for (const ev of ["ask:info", "untagged", "tpl:busy", "answer", "tpl:nudge"]) icell({ name: `${state} ${ev}`, dir: "in", rec, ev, sig: WAKE_PEER, state, deadline: "same" });
  icell({ name: `${state} closing`, dir: "in", rec, ev: "tpl:closing", sig: ["state:CLOSED-BY-PEER", "wake:closed by peer"], state: "CLOSED-BY-PEER", deadline: "null" });
}
icell({ name: "OPEN deadline defers for 72 h", dir: "in", rec: { state: "OPEN", deadline: T0 + ANSWER_BY, remindAt: null }, ev: "deadline", sig: ["send:deferred", "state:DEFERRED"], state: "DEFERRED", deadline: NOW + 72 * H });
icell({ name: "DEFERRED deadline expires", dir: "in", rec: { state: "DEFERRED", deadline: T0 + 3 * ANSWER_BY }, ev: "deadline", sig: ["send:closing", "state:EXPIRED", "wake:expired"], state: "EXPIRED", deadline: "null" });
for (const state of IN_TERMINAL) {
  const rec = { state, deadline: null };
  for (const ev of ["ask:info", "untagged", "tpl:busy", "answer"]) icell({ name: `${state} ${ev} wakes and never reopens`, dir: "in", rec, ev, sig: ["wake:message on a closed thread"], state, deadline: "null" });
  for (const ev of ["tpl:nudge", "tpl:closing", "ours:answer", "ours:decline"]) icell({ name: `${state} ${ev} is ignored`, dir: "in", rec, ev, sig: [], state, deadline: "null" });
}

function run(c: Cell): { actions: Action[]; rec: ThreadRec } {
  const clk = clock(NOW);
  const rec = mkThread(c.dir, c.rec.state, { ...c.rec });
  const t = threadsOf([rec], clk);
  let actions: Action[];
  if (c.ev === "deadline") actions = t.tick(NOW);
  else if (c.ev === "ours:answer") actions = t.onOutbound({ peer: "example", chat: CHAT, root: 100, kind: "answer", isRoot: false });
  else if (c.ev === "ours:decline") actions = t.decline("example", 100);
  else actions = t.onInbound(inbound(c.ev, 100, c.by ? { by: Math.floor(c.by / 1000) } : {})).actions;
  return { actions, rec: t.get("example", 100)! };
}

for (const c of [...outbound, ...inbox]) {
  test(`table ${c.dir}: ${c.name}`, () => {
    const { actions, rec } = run(c);
    expect(sig(actions)).toEqual(c.sig);
    if (c.state) expect(rec.state).toBe(c.state);
    if (c.deadline === "null") expect(rec.deadline).toBeNull();
    else if (c.deadline === "same") expect(rec.deadline).toBe(mkThread(c.dir, c.rec.state, { ...c.rec }).deadline);
    else if (typeof c.deadline === "number") expect(rec.deadline).toBe(c.deadline);
  });
}

test("table: the 12 h reminder wakes an OPEN inbound thread once", () => {
  const clk = clock(T0 + 12 * H);
  const t = threadsOf([mkThread("in", "OPEN", { remindAt: T0 + 12 * H })], clk);
  expect(sig(t.tick(T0 + 12 * H))).toEqual(["state:OPEN", "wake:reminder"]);
  expect(t.tick(T0 + 12 * H)).toEqual([]);
});

test("a new inbound root allocates OPEN with a 24 h reply_by, a receipt and a wake", () => {
  const clk = clock(T0);
  const t = threadsOf([], clk);
  const a = t.onInbound(rootMsg("ask:question", 200)).actions;
  expect(sig(a)).toEqual(["state:OPEN", "send:receipt", "wake:new question"]);
  const rec = states(a)[0];
  expect(rec).toMatchObject({ dir: "in", alloc: T0, deadline: T0 + 24 * H, remindAt: T0 + 12 * H, auto: 1 });
  const wake = a.find(x => "wake" in x) as any;
  expect(wake.wake.replyBy).toBe(T0 + 24 * H);
});

test("our own root allocates SENT with a 30 min ack_by", () => {
  const t = threadsOf([], clock(T0));
  const a = t.onOutbound({ peer: "example", chat: CHAT, root: 300, kind: "status", isRoot: true });
  expect(states(a)[0]).toMatchObject({ dir: "out", state: "SENT", alloc: T0, deadline: T0 + 30 * MIN });
  expect(t.openOutbound("example")).toBe(1);
});

test("a template from the peer is never answered or receipted, in any state", () => {
  for (const dir of ["out", "in"] as const) {
    for (const state of dir === "out" ? ["SENT", "AWAITING", "NUDGED", "ANSWERED", "CLOSED"] : ["OPEN", "DEFERRED", "ANSWERED"]) {
      for (const tag of ["tpl:receipt", "tpl:nudge", "tpl:deferred", "tpl:closing", "tpl:declined-kind", "tpl:busy"]) {
        const t = threadsOf([mkThread(dir, state, { deadline: ["CLOSED", "ANSWERED"].includes(state) && dir === "in" || state === "CLOSED" ? null : T0 + 24 * H })], clock(NOW));
        expect(sig(t.onInbound(inbound(tag, 100)).actions).filter(s => s.startsWith("send:"))).toEqual([]);
      }
    }
  }
  const t = threadsOf([], clock(T0));
  expect(t.onInbound(rootMsg("tpl:receipt", 400)).actions).toEqual([]);
});

test("peer text that sets answer_by or reply_by changes no deadline", () => {
  const t = threadsOf([mkThread("out", "AWAITING")], clock(NOW));
  t.onInbound(inbound("untagged", 100, { text: "answer_by=1m reply_by=1m close_by=1m" })).actions;
  expect(t.get("example", 100)!.deadline).toBe(T0 + 24 * H);
});

test("a hostile by=2099 is clamped to alloc + 73 h, and a second deferred changes nothing", () => {
  const t = threadsOf([mkThread("out", "AWAITING")], clock(NOW));
  const far = Date.UTC(2099, 11, 31) / 1000;
  t.onInbound(inbound("tpl:deferred", 100, { by: far })).actions;
  expect(t.get("example", 100)!.deadline).toBe(T0 + 73 * H);
  const again = t.onInbound(inbound("tpl:deferred", 100, { by: far, id: "0a0b0c0e" })).actions;
  expect(again).toEqual([]);
});

test("a deferred with a short by= never shortens our own 24 h wait", () => {
  const now = T0 + 5 * H;
  const t = threadsOf([mkThread("out", "AWAITING")], clock(now));
  t.onInbound(inbound("tpl:deferred", 100, { by: (now + 60 * MIN) / 1000 })).actions;
  expect(t.get("example", 100)!.deadline).toBe(now + 24 * H);
});

test("a message on a terminal thread wakes and never reopens it", () => {
  const t = threadsOf([mkThread("out", "EXPIRED", { deadline: null })], clock(NOW));
  expect(sig(t.onInbound(inbound("answer", 100)).actions)).toEqual(["wake:answer on a closed thread"]);
  expect(t.get("example", 100)!.state).toBe("EXPIRED");
  expect(t.get("example", 100)!.deadline).toBeNull();
});

test("DEFERRED followed by a decline sends declined-kind", () => {
  const t = threadsOf([mkThread("in", "DEFERRED", { deadline: T0 + 72 * H })], clock(NOW));
  expect(sig(t.decline("example", 100))).toEqual(["send:declined-kind", "state:DECLINED"]);
});

test("a reply on an unknown root queues nothing", () => {
  expect(threadsOf([], clock(NOW)).onInbound(inbound("answer", 999)).actions).toEqual([]);
});

test("per-thread cap: the 4th automatic message becomes a wake, closing still goes from its reserved slot", () => {
  const t = threadsOf([mkThread("out", "AWAITING", { auto: 3, deadline: T0 })], clock(NOW));
  const a = t.tick(NOW);
  expect(sig(a)).toEqual(["wake:cap hit", "state:NUDGED"]);
  const u = threadsOf([mkThread("out", "NUDGED", { auto: 3, deadline: T0 })], clock(NOW));
  expect(sig(u.tick(NOW))).toEqual(["send:closing", "state:EXPIRED", "wake:expired"]);
  const v = threadsOf([mkThread("out", "NUDGED", { auto: 3, closingSent: true, deadline: T0 })], clock(NOW));
  expect(sig(v.tick(NOW))).toEqual(["state:EXPIRED", "wake:expired"]);
});

test("hourly cap: 20 automatic messages per peer per hour, then wakes; closing is outside the cap", () => {
  const recs = Array.from({ length: 22 }, (_, i) => mkThread("out", "AWAITING", { root: 1000 + i, deadline: T0 + i * MIN }));
  const t = threadsOf(recs, clock(NOW));
  const a = sig(t.tick(NOW));
  expect(a.filter(s => s === "send:nudge")).toHaveLength(20);
  expect(a.filter(s => s === "wake:cap hit")).toHaveLength(2);
  const later = NOW + 25 * H;
  const closings = sig(t.tick(later)).filter(s => s === "send:closing");
  expect(closings).toHaveLength(22);
});

test("the hourly window survives a restart (autoAt is chained)", () => {
  const recs = Array.from({ length: 20 }, (_, i) => mkThread("out", "NUDGED", { root: 2000 + i, auto: 1, autoAt: NOW - 10 * MIN, autoTpl: "nudge", deadline: NOW + H }));
  const fresh = mkThread("out", "AWAITING", { root: 3000, deadline: T0 });
  const t = threadsOf([...recs, fresh], clock(NOW));
  expect(sig(t.tick(NOW))).toEqual(["wake:cap hit", "state:NUDGED"]);
});

test("a 48 h jump fires each overdue timer once, oldest first, and never again", () => {
  const recs = [
    mkThread("out", "AWAITING", { root: 3, deadline: T0 + 3 * H }),
    mkThread("out", "AWAITING", { root: 1, deadline: T0 + 1 * H }),
    mkThread("in", "OPEN", { root: 4, deadline: T0 + 3.5 * H, remindAt: T0 + 2.5 * H }),
    mkThread("out", "AWAITING", { root: 2, deadline: T0 + 2 * H }),
  ];
  const t = threadsOf(recs, clock(T0));
  const jump = T0 + 48 * H;
  const a = t.tick(jump);
  const order = a.flatMap(x => ("state" in x ? [`${x.state.root}:${x.state.state}`] : []));
  expect(order).toEqual(["1:NUDGED", "2:NUDGED", "4:OPEN", "3:NUDGED", "4:DEFERRED"]);
  expect(sig(a).filter(s => s.startsWith("send:"))).toEqual(["send:nudge", "send:nudge", "send:nudge", "send:deferred"]);
  expect(t.tick(jump)).toEqual([]);
  for (const r of t.all()) expect(r.deadline === null || r.deadline > jump).toBe(true);
});

test("a cap overflow after a long suspend becomes a wake, not a lost or doubled message", () => {
  const recs = Array.from({ length: 25 }, (_, i) => mkThread("out", "AWAITING", { root: 500 + i, deadline: T0 + i * MIN }));
  const t = threadsOf(recs, clock(T0));
  const a = sig(t.tick(T0 + 48 * H));
  expect(a.filter(s => s === "send:nudge")).toHaveLength(20);
  expect(a.filter(s => s === "wake:cap hit")).toHaveLength(5);
});

test("a restart in the middle of a deadline fires once", () => {
  const t1 = threadsOf([mkThread("out", "AWAITING", { deadline: T0 + H })], clock(T0));
  const first = t1.tick(T0 + 2 * H);
  expect(sig(first)).toEqual(["send:nudge", "state:NUDGED"]);
  const chained = states(first);
  const t2 = threadsOf([mkThread("out", "AWAITING", { deadline: T0 + H }), ...chained], clock(T0 + 2 * H));
  expect(t2.tick(T0 + 2 * H)).toEqual([]);
  expect(t2.get("example", 100)!.state).toBe("NUDGED");
});

test("templateLine renders the wire grammar", () => {
  expect(templateLine("receipt", 12, "deadbeef")).toBe("#tpl:receipt #12 id=deadbeef");
  expect(templateLine("deferred", 12, "deadbeef", new Date(Date.UTC(2026, 10, 11, 9, 30)))).toBe("#tpl:deferred #12 id=deadbeef by=20261111T093000Z");
});

type Side = { name: string; peer: string; t: Threads; skew: number; online: boolean; queue: PeerMsgRec[] };
let nextMid = 90_000;
function twoBridges(opts: { skewB?: number; offline?: [number, number]; hours?: number; answerAtB?: number } = {}) {
  const real = { t: T0 };
  const mk = (name: string, peer: string, skew: number): Side => ({ name, peer, skew, online: true, queue: [], t: Threads.load([], { peers: { [peer]: { opens: ["question", "status", "info"], maxOpenThreads: 5 } }, clock: () => real.t + skew }) });
  const A = mk("A", "b", 0), B = mk("B", "a", opts.skewB ?? 0);
  const ROOT = 700;
  const wakes: string[] = [];
  const deliver = (to: Side, rec: PeerMsgRec) => {
    if (!to.online) { to.queue.push(rec); return; }
    apply(to, to.t.onInbound(rec).actions);
  };
  const apply = (side: Side, actions: Action[]) => {
    const other = side === A ? B : A;
    for (const x of actions) {
      if ("wake" in x) wakes.push(`${side.name}:${x.wake.label}`);
      else if ("send" in x) deliver(other, inbound(`tpl:${x.send.tpl}`, x.send.root, { peer: other.peer, message_id: ++nextMid, id: (nextMid).toString(16).padStart(8, "0"), ...(x.send.by ? { by: Math.floor(x.send.by.getTime() / 1000) } : {}) }));
    }
  };
  apply(A, A.t.onOutbound({ peer: "b", chat: CHAT, root: ROOT, kind: "question", isRoot: true }));
  deliver(B, rootMsg("ask:question", ROOT, { peer: "a" }));
  const step = 30_000, end = T0 + (opts.hours ?? 120) * H;
  for (let now = T0; now <= end; now += step) {
    real.t = now;
    for (const side of [A, B]) {
      const off = side === B && opts.offline && now >= T0 + opts.offline[0] * H && now < T0 + opts.offline[1] * H;
      const wasOnline = side.online;
      side.online = !off;
      if (!wasOnline && side.online) while (side.queue.length) deliver(side, side.queue.shift()!);
      if (side.online) apply(side, side.t.tick(now + side.skew));
    }
    if (opts.answerAtB && now === T0 + opts.answerAtB * H) {
      apply(B, B.t.onOutbound({ peer: "a", chat: CHAT, root: ROOT, kind: "answer", isRoot: false }));
      deliver(A, inbound("answer", ROOT, { peer: "b", message_id: ++nextMid, id: "aaaa0001" }));
    }
  }
  return { A, B, wakes, ROOT };
}
const bothTerminal = (a: Side, b: Side, root: number) => [a.t.get("b", root)!.deadline, b.t.get("a", root)!.deadline];

test("two bridges: the 24 h collision ends terminal on both sides by 97 h", () => {
  const { A, B, ROOT, wakes } = twoBridges({ hours: 97 });
  expect(bothTerminal(A, B, ROOT)).toEqual([null, null]);
  expect(A.t.get("b", ROOT)!.state).toBe("EXPIRED");
  expect(["CLOSED-BY-PEER", "EXPIRED"]).toContain(B.t.get("a", ROOT)!.state);
  expect(wakes.filter(w => w === "B:new question")).toHaveLength(1);
  expect(wakes).toContain("B:reminder");
});

test("two bridges: an answer at 5 h settles the thread and both close within 72 h", () => {
  const { A, B, ROOT } = twoBridges({ hours: 90, answerAtB: 5 });
  expect(A.t.get("b", ROOT)!.state).toBe("CLOSED");
  expect(B.t.get("a", ROOT)!.state).toBe("ANSWERED");
  expect(bothTerminal(A, B, ROOT)[0]).toBeNull();
});

test("two bridges: a peer offline for 12 h still ends terminal on both sides", () => {
  const { A, B, ROOT } = twoBridges({ hours: 120, offline: [0.1, 12.1] });
  expect(bothTerminal(A, B, ROOT)).toEqual([null, null]);
});

test("two bridges: clocks skewed by +10 min and -10 min still end terminal on both sides", () => {
  for (const skewB of [10 * MIN, -10 * MIN]) {
    const { A, B, ROOT } = twoBridges({ hours: 98, skewB });
    expect(bothTerminal(A, B, ROOT)).toEqual([null, null]);
  }
});

test("onInbound reports opened, answered-now and other", () => {
  const t = threadsOf([], clock(NOW));
  expect(t.onInbound(rootMsg("ask:question", 300)).transition).toBe("opened");
  expect(t.onInbound(inbound("ask:info", 300)).transition).toBe("other");
  expect(t.onInbound(rootMsg("tpl:receipt", 301)).transition).toBe("other");
  for (const state of ["SENT", "AWAITING", "NUDGED"]) {
    const u = threadsOf([mkThread("out", state, { deadline: NOW + H })], clock(NOW));
    const r = u.onInbound(inbound("answer", 100));
    expect(r.transition).toBe("answered-now");
    expect(sig(r.actions)).toEqual(["state:ANSWERED", "wake:answer"]);
  }
  const answered = threadsOf([mkThread("out", "ANSWERED", { deadline: NOW + H })], clock(NOW));
  expect(answered.onInbound(inbound("answer", 100)).transition).toBe("other");
  const closed = threadsOf([mkThread("out", "CLOSED", { deadline: null })], clock(NOW));
  expect(closed.onInbound(inbound("answer", 100)).transition).toBe("other");
});

test("effectiveRoute table", () => {
  const models = ["escalate", "ack", "drop", null] as const;
  const table: [string, string, string[]][] = [
    ["question", "opened", ["escalate", "escalate", "drop", "escalate"]],
    ["status", "opened", ["escalate", "ack", "drop", "escalate"]],
    ["info", "opened", ["escalate", "ack", "drop", "escalate"]],
    ["answer", "answered-now", ["escalate", "escalate", "escalate", "escalate"]],
    ["other", "other", ["escalate", "drop", "drop", "escalate"]],
  ];
  for (const [kind, transition, want] of table) models.forEach((m, i) => expect([kind, transition, m, effectiveRoute(kind, transition as any, m)]).toEqual([kind, transition, m, want[i]]));
  for (const m of models) {
    expect(effectiveRoute("answer", "opened", m)).toBe("escalate");
    expect(effectiveRoute("status", "answered-now", m)).toBe("escalate");
  }
});

test("ack sends only closing; drop sends nothing", () => {
  const t = threadsOf([], clock(NOW));
  t.onInbound(rootMsg("status", 310));
  const a = t.ack("example", 310);
  expect(sig(a)).toEqual(["state:ACKED", "send:closing"]);
  expect(t.get("example", 310)!.deadline).toBeNull();
  t.onInbound(rootMsg("info", 311));
  const d = t.drop("example", 311);
  expect(sig(d)).toEqual(["state:DROPPED"]);
  expect(t.get("example", 311)!.deadline).toBeNull();
});

test("ack and drop on a terminal thread emit nothing", () => {
  const t = threadsOf([mkThread("in", "ANSWERED", { deadline: null, root: 320 })], clock(NOW));
  expect(t.ack("example", 320)).toEqual([]);
  expect(t.drop("example", 320)).toEqual([]);
  expect(t.ack("example", 999)).toEqual([]);
  t.onInbound(rootMsg("status", 321));
  t.ack("example", 321);
  expect(t.ack("example", 321)).toEqual([]);
  expect(t.drop("example", 321)).toEqual([]);
});
