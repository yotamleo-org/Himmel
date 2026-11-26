import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CODE_VERSION, Chain, codeState, drainSpool, readChain, signTap, startIdentity, submitSpool } from "./chain";
import { readPeersFile } from "./config";
import { checkOutbound } from "./egress";
import { MAX_CHIEF_PER_DAY, draftState } from "./drafts";
import { notifyFile, renderNotify } from "./notify";
import { Poller, type TgLike } from "./poller";
import { run, slugOf } from "./tell";
import { loadMatrix } from "../guardrails/egress-matrix-eval.mjs";

const REPO = join(import.meta.dir, "..", "..");
const TELL = join(import.meta.dir, "tell.ts");
const SID = "0b7e4a52-tell-test";
const OP = "4242";
const CHAT = -1001234567890;
const WITH_ROW = {
  default: "deny",
  rules: [
    { corpus: "chief-tell", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "t" },
    { corpus: "chief-tell", provider: "*", purpose: "*", verdict: "deny", why: "t" },
    { corpus: "operator-reply", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "t" },
    { corpus: "peer-desk", provider: "peer-telegram", purpose: "peer-message", verdict: "allow", why: "t" },
  ],
};

const NO_ROW = { default: "deny", rules: WITH_ROW.rules.filter(r => r.corpus !== "chief-tell") };

type Home = ReturnType<typeof newHome>;
function newHome() {
  const home = mkdtempSync(join(tmpdir(), "peer-tell-"));
  const S = join(home, ".himmel/peer-bridge");
  const C = join(home, ".config/himmel/peer-bridge");
  const peerDir = join(S, "example");
  const launch = mkdtempSync(join(tmpdir(), "peer-tell-launch-"));
  mkdirSync(join(peerDir, "spool"), { recursive: true });
  mkdirSync(join(S, "notify"), { recursive: true });
  mkdirSync(C, { recursive: true });
  writeFileSync(join(C, "hmac.key"), "k".repeat(32), { mode: 0o600 });
  const peer = { peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], opens: ["question", "status", "info"], maxOpenThreads: 50, maxPerMinute: 50, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30, theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 50, maxPerMinute: 50, copiedAt: "2026-11-07" } };
  writeFileSync(join(C, "peers.json"), JSON.stringify({ operatorBotId: "999000999", operatorChatId: Number(OP), bridgeRoot: join(home, "bridge"), himmelRoot: REPO, peers: { example: peer }, maxTextChars: 4000, addressing: "command" }), { mode: 0o600 });
  const h = { home, S, C, peerDir, launch };
  fresh(h, "poller.pid");
  fresh(h, "notify/bot.code");
  transcript(h, [{ type: "user", cwd: launch }]);
  return h;
}
function fresh(h: Home, rel: string, over: Record<string, unknown> = {}) {
  writeFileSync(join(h.S, rel), JSON.stringify({ pid: process.pid, start: startIdentity(process.pid), code: CODE_VERSION, ...over }));
}
const projectDir = (h: Home, cfg = ".claude", slug = slugOf(h.launch)) => join(h.home, cfg, "projects", slug);
function transcript(h: Home, recs: object[], opts: { cfg?: string; slug?: string; file?: string } = {}) {
  const dir = projectDir(h, opts.cfg, opts.slug);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, opts.file ?? `${SID}.jsonl`);
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, recs.map(r => JSON.stringify(r)).join("\n") + "\n");
  return path;
}
const use = (cwd: string, name: string, input: Record<string, unknown>) => ({ type: "assistant", cwd, message: { content: [{ type: "tool_use", id: "t1", name, input }, { type: "text", text: "ignored" }] } });
const env = (h: Home, over: Record<string, string | undefined> = {}) => ({ PATH: process.env.PATH!, HOME: h.home, CLAUDECODE: "1", CLAUDE_CODE_SESSION_ID: SID, PEER_SEND_WAIT_MS: "0", ...over }) as Record<string, string>;
const spool = (h: Home) => readdirSync(join(h.peerDir, "spool")).filter(n => n.endsWith(".json"));
const tell = (h: Home, args: string[], over: Record<string, string | undefined> = {}, opts: Parameters<typeof run>[2] = { matrix: WITH_ROW }) => run(["example", ...args], env(h, over), opts);
const info = ["--kind", "info", "--text", "the fix is merged"];
const salusVault = () => { const v = mkdtempSync(join(tmpdir(), "peer-tell-vault-")); writeFileSync(join(v, ".salus"), ""); return v; };

async function refused(h: Home, args: string[], code: number, line: string | RegExp, over: Record<string, string | undefined> = {}, opts?: Parameters<typeof run>[2]) {
  const r = await tell(h, args, over, opts);
  expect([r.code, r.line]).toEqual([code, expect.stringMatching(line) as unknown as string]);
  expect(spool(h)).toEqual([]);
  return r;
}

test("tell.ts refuses without a session id, in a desk, and in a tainted or pending-taint session; nothing is queued", async () => {
  const h = newHome();
  await refused(h, info, 3, /^refused: no-session: /, { CLAUDE_CODE_SESSION_ID: undefined });
  await refused(h, info, 3, /^refused: no-session: /, { CLAUDE_CODE_SESSION_ID: "../x" });
  await refused(h, info, 3, /^refused: tell.ts never runs in a peer desk/, { PEER_DESK: "example" });
  mkdirSync(join(h.S, "taint"), { recursive: true });
  writeFileSync(join(h.S, "taint", `${SID}.pending.1-ab`), "");
  await refused(h, info, 3, /^refused: tell.ts never runs in a peer desk/);
  rmSync(join(h.S, "taint", `${SID}.pending.1-ab`));
  writeFileSync(join(h.S, "taint", SID), "");
  await refused(h, info, 3, /^refused: tell.ts never runs in a peer desk/);
});

test("a session carrying the phi-read mark refuses phi-root and writes nothing; the same session unmarked queues", async () => {
  const h = newHome();
  const mark = join(h.home, ".himmel/phi-taint", SID);
  mkdirSync(join(mark, ".."), { recursive: true });
  writeFileSync(mark, "");
  await refused(h, info, 3, /^refused: phi-root: /);
  await refused(h, ["--status", "0a1b2c3d"], 3, /^refused: phi-root: /);
  rmSync(mark);
  expect((await tell(h, info)).code).toBe(4);
});

test("a transcript that names a salus path in a Read, a cwd, a Bash token, a Glob prefix or a subagent's Grep refuses phi-root", async () => {
  const vault = salusVault();
  const cases: [string, (h: Home) => void][] = [
    ["Read of a salus file", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Read", { file_path: join(vault, "a.md") })])],
    ["cd into salus", h => transcript(h, [{ type: "user", cwd: h.launch }, { type: "user", cwd: join(vault, "notes") }])],
    ["salus-rooted session whose cwd moved into himmel", h => { rmSync(join(h.home, ".claude"), { recursive: true }); h.launch = vault; transcript(h, [{ type: "user", cwd: vault }, { type: "user", cwd: REPO }]); }],
    ["Bash cat of an absolute salus path", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat ${vault}/x.md | head -3` })])],
    ["Monitor naming a salus path", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Monitor", { command: `tail -f "${vault}/log"` })])],
    ["Glob whose literal prefix is salus", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Glob", { pattern: `${vault}/**/*.md` })])],
    ["a subagent grepped salus", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Grep", { pattern: "x", path: vault })], { file: `${SID}/subagents/agent-a1.jsonl` })],
    ["a complete final record with no newline", h => { const p = transcript(h, [{ type: "user", cwd: h.launch }]); writeFileSync(p, readFileSync(p, "utf8") + JSON.stringify(use(h.launch, "Read", { file_path: join(vault, "last.md") }))); }],
  ];
  await phiCases(cases);
});

test("a quoted or backslash-escaped salus path holding a space in a Bash or Monitor command refuses phi-root", async () => {
  const spaced = mkdtempSync(join(tmpdir(), "peer tell vault-"));
  writeFileSync(join(spaced, ".salus"), "");
  await phiCases([
    ["double-quoted", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat "${spaced}/a b.md"` })])],
    ["single-quoted", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Monitor", { command: `tail -f '${spaced}/log'` })])],
    ["backslash-escaped", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat ${spaced.replaceAll(" ", "\\ ")}/a.md` })])],
  ]);
});

test("a backslash-newline inside a salus path or ANSI-C quoting in a Bash command refuses phi-root", async () => {
  const v = salusVault();
  const cut = v.length - 3;
  await phiCases([
    ["quoted continuation", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat "${v.slice(0, cut)}\\\n${v.slice(cut)}/a.md"` })])],
    ["unquoted continuation", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat ${v.slice(0, cut)}\\\n${v.slice(cut)}/a.md` })])],
    ["ANSI-C quoting", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cat $'${v.slice(0, cut)}\\x${v.charCodeAt(cut).toString(16)}${v.slice(cut + 1)}/a.md'` })])],
  ]);
});

test("a relative path after a cd, and a directory with a salus marker anywhere below it, refuse phi-root", async () => {
  const docs = mkdtempSync(join(tmpdir(), "peer-tell-docs-"));
  mkdirSync(join(docs, "salus", "notes"), { recursive: true });
  writeFileSync(join(docs, "salus", ".salus"), "");
  const prof = mkdtempSync(join(tmpdir(), "peer-tell-prof-"));
  mkdirSync(join(prof, "deep", "vault"), { recursive: true });
  writeFileSync(join(prof, "deep", "vault", ".salus-profile"), "");
  const far = mkdtempSync(join(tmpdir(), "peer-tell-far-"));
  const deep = join("a", "b", "c", "d", "e", "f", "g", "salus");
  mkdirSync(join(far, deep), { recursive: true });
  writeFileSync(join(far, deep, ".salus"), "");
  await phiCases([
    ["cd then a relative path to salus deeper than the find reaches", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cd ${far} && cat ${deep}/x` })])],
    ["cd with options then a relative path to salus", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cd -P -- ${far} && cat ${deep}/x` })])],
    ["a relative path to salus against the record cwd", h => transcript(h, [{ type: "user", cwd: h.launch }, { type: "user", cwd: far }, use(far, "Bash", { command: `cat ${deep}/notes.md` })])],
    ["a relative Glob pattern to salus against the record cwd", h => transcript(h, [{ type: "user", cwd: h.launch }, { type: "user", cwd: far }, use(far, "Glob", { pattern: `${deep}/**/*.md` })])],
    ["a relative Glob pattern to salus under its path", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Glob", { pattern: `${join("b", "c", "d", "e", "f", "g", "salus")}/*.md`, path: join(far, "a") })])],
  ]);
  await phiCases([
    ["cd then a relative salus path", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `cd ${docs} && cat salus/x` })])],
    ["a relative salus path against the record cwd", h => transcript(h, [{ type: "user", cwd: h.launch }, { type: "user", cwd: docs }, use(docs, "Bash", { command: "cat salus/notes/a.md" })])],
    ["Grep rooted above salus", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Grep", { pattern: "foo", path: docs })])],
    ["grep -rn rooted above salus under ~", h => { mkdirSync(join(h.home, "Documents", "salus"), { recursive: true }); writeFileSync(join(h.home, "Documents", "salus", ".salus"), ""); transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: "grep -rn foo ~/Documents" })]); }],
    ["a salus-profile marker below a named directory", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Bash", { command: `ls ${prof}` })])],
  ]);
  if (process.getuid!() !== 0) {
    const locked = mkdtempSync(join(tmpdir(), "peer-tell-locked-"));
    mkdirSync(join(locked, "closed"));
    chmodSync(join(locked, "closed"), 0o000);
    await phiCases([["a named directory find cannot read through", h => transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Glob", { pattern: "*.md", path: locked })])]]);
    chmodSync(join(locked, "closed"), 0o700);
  }
});

async function phiCases(cases: [string, (h: Home) => void][]) {
  for (const [why, seed] of cases) {
    const h = newHome();
    seed(h);
    const r = await tell(h, info);
    expect([why, r.code, r.line]).toEqual([why, 3, expect.stringMatching(/^refused: phi-root: /) as unknown as string]);
    expect(spool(h)).toEqual([]);
  }
}

test("a phi-roots hit, an unreadable phi list, an unreadable or oversized transcript and an unparsable middle line refuse phi-root", async () => {
  const phi = mkdtempSync(join(tmpdir(), "peer-tell-phi-"));
  const listed = newHome();
  mkdirSync(join(listed.home, ".config/claude-glm"), { recursive: true });
  writeFileSync(join(listed.home, ".config/claude-glm/phi-roots"), `${phi}\n`);
  transcript(listed, [{ type: "user", cwd: listed.launch }, use(listed.launch, "Read", { file_path: join(phi, "p.md") })]);
  await refused(listed, info, 3, /^refused: phi-root: /);

  const locked = newHome();
  mkdirSync(join(locked.home, ".config/claude-glm"), { recursive: true });
  writeFileSync(join(locked.home, ".config/claude-glm/phi-roots"), `${phi}\n`);
  chmodSync(join(locked.home, ".config/claude-glm/phi-roots"), 0o000);
  if (process.getuid!() !== 0) await refused(locked, info, 3, /^refused: phi-root: /);

  const unreadable = newHome();
  if (process.getuid!() !== 0) { chmodSync(join(projectDir(unreadable), `${SID}.jsonl`), 0o000); await refused(unreadable, info, 3, /^refused: (phi-root|launch-root-unknown): /); }

  const big = newHome();
  transcript(big, [{ type: "user", cwd: big.launch }, { type: "user", cwd: big.launch, pad: "x".repeat(4096) }]);
  await refused(big, info, 3, /^refused: phi-root: /, {}, { matrix: WITH_ROW, maxTranscriptBytes: 1024 });

  const torn = newHome();
  writeFileSync(join(projectDir(torn), `${SID}.jsonl`), `${JSON.stringify({ type: "user", cwd: torn.launch })}\n{not json\n${JSON.stringify({ type: "user", cwd: torn.launch })}\n`);
  await refused(torn, info, 3, /^refused: phi-root: /);
});

test("no transcript, two transcripts, a slug mismatch or no cwd record refuse launch-root-unknown", async () => {
  const none = newHome();
  rmSync(join(none.home, ".claude"), { recursive: true });
  await refused(none, info, 3, /^refused: launch-root-unknown: /);
  const two = newHome();
  transcript(two, [{ type: "user", cwd: two.launch }], { cfg: ".claude-b" });
  await refused(two, info, 3, /^refused: launch-root-unknown: /);
  const moved = newHome();
  rmSync(join(moved.home, ".claude"), { recursive: true });
  transcript(moved, [{ type: "user", cwd: moved.launch }], { slug: "-somewhere-else" });
  await refused(moved, info, 3, /^refused: launch-root-unknown: /);
  const nocwd = newHome();
  transcript(nocwd, [{ type: "summary" }]);
  await refused(nocwd, info, 3, /^refused: launch-root-unknown: /);
});

test("negative control: a transcript naming only checkout and vault paths, with a torn final line, passes the scan and queues", async () => {
  const h = newHome();
  const path = transcript(h, [{ type: "user", cwd: h.launch }, use(h.launch, "Read", { file_path: join(REPO, "README.md") }), use(h.launch, "Bash", { command: `ls ${REPO}/scripts ~/Documents/luna` }), { type: "user", cwd: REPO }]);
  writeFileSync(path, readFileSync(path, "utf8") + '{"type":"assist');
  const r = await tell(h, info);
  expect([r.code, r.line]).toEqual([4, expect.stringMatching(/^queued as .+; the poller will draft it; do not resend$/) as unknown as string]);
  const files = spool(h);
  expect(files).toHaveLength(1);
  expect(JSON.parse(readFileSync(join(h.peerDir, "spool", files[0]), "utf8"))).toEqual({ type: "draft", source: "chief", kind: "info", text: "the fix is merged", session: SID });
});

test("an unknown peer, a bad kind, empty or multi-line text and a waiver flag refuse before anything is queued", async () => {
  const h = newHome();
  const r = await run(["nobody", ...info], env(h), { matrix: WITH_ROW });
  expect([r.code, r.line]).toEqual([2, "refused: unknown-peer"]);
  await refused(h, ["--kind", "question", "--text", "x"], 2, "refused: unknown-kind");
  await refused(h, ["--kind", "answer", "--text", "x"], 2, "refused: unknown-kind");
  await refused(h, ["--kind", "info", "--text", ""], 2, "refused: empty");
  await refused(h, ["--kind", "info", "--text", "two\nlines"], 2, "refused: characters");
  await refused(h, ["--kind", "info", "--reply-to", "9", "--text", "x"], 2, "refused: unknown or malformed argument");
  await refused(h, ["--kind", "info", "--allow-shape", "pass_bare", "--text", "x"], 2, "refused: unknown or malformed argument");
});

test("a stale or unknown poller or operator bot refuses, and nothing is queued", async () => {
  const h = newHome();
  fresh(h, "poller.pid", { code: "0000000000000000" });
  await refused(h, info, 3, /^refused: poller-stale: /);
  rmSync(join(h.S, "poller.pid"));
  await refused(h, info, 3, /^refused: poller-stale: /);
  fresh(h, "poller.pid");
  rmSync(join(h.S, "notify/bot.code"));
  await refused(h, info, 3, /^refused: operator-bot-stale: /);
  fresh(h, "notify/bot.code", { code: undefined });
  await refused(h, info, 3, /^refused: operator-bot-stale: /);
  fresh(h, "notify/bot.code", { start: "not-the-start" });
  await refused(h, info, 3, /^refused: operator-bot-stale: /);
  fresh(h, "notify/bot.code", { pid: 2 ** 22 + 12345 });
  await refused(h, info, 3, /^refused: operator-bot-stale: /);
});

test("codeState is fresh only for a live pid with its start and our code; stale for other code; absent for the rest", () => {
  const d = mkdtempSync(join(tmpdir(), "peer-tell-code-"));
  const f = join(d, "stamp");
  const put = (o: object | string) => writeFileSync(f, typeof o === "string" ? o : JSON.stringify(o));
  const me = { pid: process.pid, start: startIdentity(process.pid) };
  expect(codeState(f)).toBe("absent");
  put({ ...me, code: CODE_VERSION }); expect(codeState(f)).toBe("fresh");
  put({ ...me, code: "other" }); expect(codeState(f)).toBe("stale");
  put(me); expect(codeState(f)).toBe("stale");
  put({ ...me, start: "x", code: CODE_VERSION }); expect(codeState(f)).toBe("absent");
  put({ pid: 2 ** 22 + 12345, start: "x", code: CODE_VERSION }); expect(codeState(f)).toBe("absent");
  put("null"); expect(codeState(f)).toBe("absent");
  put("{"); expect(codeState(f)).toBe("absent");
});

test("the real matrix allows chief-tell, a matrix without its row refuses it, and no matrix row names unknown-source", async () => {
  const h = newHome();
  await refused(h, info, 2, "refused: egress-matrix", {}, { matrix: NO_ROW });
  expect((await tell(h, info, {}, {})).code).toBe(4);
  const peer = readPeersFile(join(h.C, "peers.json")).peers.example;
  for (const corpus of ["unknown-source"] as const) {
    expect(await checkOutbound("hello", { peer, kind: "info", isRoot: true, isTemplate: false, himmelRoot: REPO, corpus, matrix: loadMatrix() })).toEqual({ ok: false, rule: "egress-matrix" });
  }
});

test("tell.ts the CLI exits 3 outside a Claude session and never echoes the text", () => {
  const h = newHome();
  const r = spawnSync("bun", [TELL, "example", "--kind", "info", "--text", "SECRET-MARKER-1"], { encoding: "utf8", cwd: tmpdir(), env: { PATH: process.env.PATH!, HOME: h.home } });
  expect(r.status).toBe(3);
  expect(r.stderr).toContain("refused: no-session");
  expect(r.stdout + r.stderr).not.toContain("SECRET-MARKER-1");
});

async function bridge(h: Home, matrix: object = WITH_ROW) {
  const c = { t: Date.UTC(2026, 10, 24, 12) };
  const sent: string[] = [];
  let mid = 9000;
  const tg: TgLike = { getUpdates: async () => [], getChatMember: async () => ({ user: { username: "ours_bot" } }), sendMessage: async (_c: number, text: string) => { sent.push(text); return { message_id: ++mid }; } };
  const cfg = readPeersFile(join(h.C, "peers.json"));
  const poller = await Poller.create({ cfg, tg, ourBotId: "111000111", stateDir: h.S, configDir: h.C, clock: () => c.t, hostname: "testbox", log: () => {}, matrix: matrix as any });
  await poller.recover();
  const outbox = () => readChain(join(h.peerDir, "outbox.jsonl")) as Record<string, any>[];
  const result = (name: string) => JSON.parse(readFileSync(join(h.peerDir, "spool", "results", name), "utf8"));
  const tap = async (id: string, verb: "ok" | "no" = "ok", by = OP) => {
    const rec = { verb, draft: id, by, ts: c.t };
    const name = submitSpool(h.peerDir, { type: "tap", ...rec, sig: signTap(h.C, { ...rec, peer: "example" }) });
    await poller.drainSpool();
    return result(name);
  };
  const queue = async (text = "the fix is merged") => {
    const r = await tell(h, ["--kind", "info", "--text", text]);
    expect(r.code).toBe(4);
    const name = spool(h)[0];
    await poller.drainSpool();
    return result(name);
  };
  return { poller, c, sent, outbox, tap, queue, result };
}

test("positive control: a chief draft to a neutral fake peer sends exactly once after a valid signed tap; a replayed tap sends nothing more", async () => {
  const h = newHome();
  const b = await bridge(h);
  const d = await b.queue();
  expect(d.ok).toBe(true);
  expect(d.draft).toMatch(/^[0-9a-f]{8}$/);
  expect(b.outbox().find(r => r.kind === "draft")).toMatchObject({ source: "chief", session: SID, msgKind: "info", replyTo: null });
  expect(b.sent).toHaveLength(0);
  expect(await b.tap(d.draft)).toEqual({ ok: true, draft: d.draft });
  await b.poller.drainSpool();
  expect(b.sent).toHaveLength(1);
  expect(b.sent[0]).toContain("the fix is merged");
  expect(await b.tap(d.draft)).toMatchObject({ ok: false, rule: expect.stringMatching(/^already-/) });
  await b.poller.drainSpool();
  expect(b.sent).toHaveLength(1);
});

test("a chief draft with no tap, an expired draft and a non-operator tap send nothing", async () => {
  const h = newHome();
  const b = await bridge(h);
  const d = await b.queue();
  await b.poller.drainSpool();
  expect(b.sent).toHaveLength(0);
  expect(await b.tap(d.draft, "ok", "777")).toEqual({ ok: false, rule: "not-operator" });
  b.c.t += 31 * 60_000;
  expect(await b.tap(d.draft)).toMatchObject({ ok: false, rule: "expired" });
  expect(draftState(b.outbox(), d.draft)).toBe("EXPIRED");
  expect(b.sent).toHaveLength(0);
});

test("a matrix without the chief-tell row refuses a chief draft at the poller, and under the real matrix an unknown source is refused at tap and at recovery", async () => {
  const closed = newHome();
  const noRow = await bridge(closed, NO_ROW);
  const name = submitSpool(closed.peerDir, { type: "draft", source: "chief", kind: "info", text: "hello", session: SID } as any);
  await noRow.poller.drainSpool();
  expect(noRow.result(name)).toEqual({ ok: false, rule: "egress-matrix" });
  const h = newHome();
  const real = await bridge(h, loadMatrix());
  expect((real.poller as any).corpusOf("bogus")).toBe("unknown-source");
  expect((real.poller as any).corpusOf("chief")).toBe("chief-tell");
  const store = (id: string) => new Chain().append(join(h.peerDir, "outbox.jsonl"), { kind: "draft", id, source: "bogus", msgKind: "info", replyTo: null, text: "x", spool: id + ".json", deadline: real.c.t + 60_000, ts: Math.floor(real.c.t / 1000) });
  await store("0c0c0c0c");
  expect(await real.tap("0c0c0c0c")).toEqual({ ok: false, rule: "egress-matrix" });
  await new Chain().append(join(h.peerDir, "outbox.jsonl"), { kind: "draft", id: "0d0d0d0d", source: "bogus", msgKind: "info", replyTo: null, text: "y", spool: "0d.json", deadline: real.c.t + 60_000, ts: Math.floor(real.c.t / 1000) });
  await new Chain().append(join(h.peerDir, "outbox.jsonl"), { kind: "intent", peer: "example", chat: CHAT, id: "0d0d0d0d", root: null, msgKind: "info", text: "y", isRoot: true, draft: "0d0d0d0d", by: OP, source: "bogus" });
  const again = await Poller.create({ ...(real.poller as any).deps });
  await again.recover();
  expect(real.sent).toHaveLength(0);
  expect(draftState(real.outbox(), "0d0d0d0d")).toBe("REFUSED");
});

test("a chief spool record that asks for a question, a reply, a waiver or a bad session is malformed; a session on another source is malformed", async () => {
  const h = newHome();
  const recs: [string, object][] = [
    ["draft: chief takes only status or info", { type: "draft", source: "chief", kind: "question", text: "x" }],
    ["draft: chief takes only status or info", { type: "draft", source: "chief", kind: "answer", replyTo: 3, text: "x" }],
    ["draft: chief takes no replyTo", { type: "draft", source: "chief", kind: "info", replyTo: 3, text: "x" }],
    ["draft: chief takes no allowShape", { type: "draft", source: "chief", kind: "info", allowShape: "pass_bare", text: "x" }],
    ["draft: bad session", { type: "draft", source: "chief", kind: "info", session: "../x", text: "x" }],
    ["draft: bad session", { type: "draft", source: "send.ts", kind: "info", session: SID, text: "x" }],
  ];
  for (const [why, rec] of recs) {
    const name = submitSpool(h.peerDir, rec as any);
    const got = drainSpool(h.peerDir).find(d => d.name === name);
    expect([why, got]).toEqual([why, { name, malformed: true, why }]);
    rmSync(join(h.peerDir, "spool", name));
  }
});

test("one chief draft may be pending, five a day, and neither cap takes an operator draft's slot", async () => {
  const h = newHome();
  const b = await bridge(h);
  const first = await b.queue("one");
  expect(first.ok).toBe(true);
  expect(await b.queue("two")).toEqual({ ok: false, rule: "chief-pending" });
  const op = submitSpool(h.peerDir, { type: "draft", source: "telegram", kind: "info", text: "operator words" });
  await b.poller.drainSpool();
  expect(b.result(op)).toMatchObject({ ok: true });
  await b.tap(first.draft, "no");
  for (let i = 1; i < MAX_CHIEF_PER_DAY; i++) await b.tap((await b.queue(`n${i}`)).draft, "no");
  expect(await b.queue("sixth")).toEqual({ ok: false, rule: "chief-daily" });
});

test("--status prints fixed words only: shown, review-not-shown, the final state, and refuses a bad or unknown id", async () => {
  const h = newHome();
  const b = await bridge(h);
  const d = await b.queue("SECRET-MARKER-2 is in the outbox");
  const status = (id: string, now?: number) => tell(h, ["--status", id], {}, { matrix: WITH_ROW, now });
  const draftTs = b.outbox().find(r => r.kind === "draft")!.ts * 1000;
  expect(await status(d.draft, draftTs + 1000)).toEqual({ code: 0, line: `${d.draft} PENDING` });
  expect(await status(d.draft, draftTs + 61_000)).toEqual({ code: 0, line: `${d.draft} PENDING review-not-shown` });
  mkdirSync(join(h.S, "notify/sent"), { recursive: true });
  writeFileSync(join(h.S, "notify/sent/9001"), JSON.stringify({ n: 1, type: "draft", peer: "example", root: 0, draft: d.draft, ts: draftTs }));
  expect(await status(d.draft, draftTs + 61_000)).toEqual({ code: 0, line: `${d.draft} PENDING shown` });
  await b.tap(d.draft);
  await b.poller.drainSpool();
  const sent = await status(d.draft);
  expect(sent).toEqual({ code: 0, line: `${d.draft} SENT` });
  expect(JSON.stringify(sent)).not.toContain("SECRET-MARKER-2");
  expect(await status("ZZZZ")).toEqual({ code: 2, line: "refused: bad-draft-id" });
  expect(await status("abcdef01")).toEqual({ code: 2, line: "refused: unknown-draft" });
});

test("the review of a chief draft names tell.ts and the unverified session, never the chief", () => {
  const { text } = renderNotify({ kind: "notify", type: "draft", ts: 0, peer: "example", root: 0, draft: "0a1b2c3d", source: "chief", session: SID, deadline: Date.UTC(2026, 10, 24, 12), text: "hello" }, REPO);
  expect(text.split("\n")[0]).toMatch(/^peer example · T0 · draft 0a1b2c3d via tell\.ts, unverified session 0b7e4a52 · approve by /);
  expect(text.toLowerCase()).not.toContain("chief");
  expect(() => renderNotify({ kind: "notify", type: "draft", ts: 0, peer: "example", root: 0, draft: "0a1b2c3d", source: "chief", session: "../x", deadline: 1, text: "x" } as any, REPO)).toThrow();
});

test("slugOf maps every non-alphanumeric character to a dash, as the CLI names project dirs", () => {
  expect(slugOf("/home/u/Documents/github/himmel/.claude/worktrees/feat+himmel-10581-tell-a-peer")).toBe("-home-u-Documents-github-himmel--claude-worktrees-feat-himmel-10581-tell-a-peer");
});

test("the notify chain of a queued chief draft carries the session, and the review text is the stored text", async () => {
  const h = newHome();
  const b = await bridge(h);
  await b.queue();
  const note = (readChain(notifyFile(h.S)) as Record<string, any>[]).find(r => r.type === "draft")!;
  expect(note).toMatchObject({ source: "chief", session: SID, text: "the fix is merged" });
  expect(existsSync(join(h.S, "notify"))).toBe(true);
});
