import { expect, test } from "bun:test";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { readNewLines } from "../telegram/bus";
import { makePeerNotifyFlusher, makePeerReplyRoute, PR1_REPLY_LINE } from "../telegram/peer-notify-route";
import { flushOutboxes, handleInbound, inboundToDelivered, ingestUpdates, type AutoGate } from "../telegram/poller";
import type { Config } from "./config";
import { stateDir } from "./ids";
import { readChain } from "./chain";
import { Poller, type PollerDeps, type TgLike } from "./poller";
import { procHooks } from "./proc";

const REPO = join(import.meta.dir, "..", "..");

function walk(dir: string, out: string[] = []): string[] {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === "dist") continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const GATE_FILES = ["scripts/handover/merge-on-green.sh", "scripts/check-ci.sh", "scripts/lib/check-ci-watch.sh"];
const gateFiles = (root: string): string[] => [
  ...GATE_FILES.map(f => join(root, f)),
  ...walk(join(root, "scripts/jira/src")),
  ...fs.readdirSync(join(root, "scripts/ci")).filter(n => n.endsWith(".sh")).map(n => join(root, "scripts/ci", n)),
];

const NAMES_BRIDGE = /scripts\/peer-bridge|\.\.?\/peer-bridge|peer-bridge\/|\.himmel\/peer-bridge/;
const offenders = (files: string[]): string[] => files.filter(f => NAMES_BRIDGE.test(fs.readFileSync(f, "utf8")));

test("no merge, check or Jira script names or imports scripts/peer-bridge/", () => {
  const files = gateFiles(REPO);
  expect(files.length).toBeGreaterThan(100);
  for (const f of GATE_FILES) expect(fs.existsSync(join(REPO, f))).toBe(true);
  expect(offenders(files).map(f => relative(REPO, f))).toEqual([]);
});

test("RED control: the same check fails over a merge script with a peer-bridge reference planted", () => {
  const root = fs.mkdtempSync(join(tmpdir(), "peer-routes-"));
  try {
    for (const f of GATE_FILES) { fs.mkdirSync(join(root, f, ".."), { recursive: true }); fs.copyFileSync(join(REPO, f), join(root, f)); }
    fs.mkdirSync(join(root, "scripts/jira/src"), { recursive: true });
    fs.mkdirSync(join(root, "scripts/ci"), { recursive: true });
    expect(offenders(gateFiles(root))).toEqual([]);
    fs.appendFileSync(join(root, "scripts/handover/merge-on-green.sh"), "\nbun scripts/peer-bridge/jobs.ts show J1\n");
    expect(offenders(gateFiles(root)).map(f => relative(root, f))).toEqual(["scripts/handover/merge-on-green.sh"]);
    fs.writeFileSync(join(root, "scripts/jira/src/x.ts"), 'import "../../peer-bridge/resolve";\n');
    fs.writeFileSync(join(root, "scripts/ci/x.sh"), "cat ~/.himmel/peer-bridge/example/jobs.jsonl\n");
    expect(offenders(gateFiles(root)).map(f => relative(root, f)).sort()).toEqual(["scripts/ci/x.sh", "scripts/handover/merge-on-green.sh", "scripts/jira/src/x.ts"]);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

const INDEX_CONFIGS = ["scripts/qmd/qmd-collection-corpus.json", "scripts/luna/luna-index-hygiene.sh", ".graphifyignore"];

test("no qmd, graphify or luna-hygiene config root contains the peer bridge's state directory", () => {
  for (const f of INDEX_CONFIGS) {
    const text = fs.readFileSync(join(REPO, f), "utf8");
    expect([f, /peer-bridge/.test(text)]).toEqual([f, false]);
  }
  expect(stateDir().endsWith(join(".himmel", "peer-bridge"))).toBe(true);
  expect(relative(REPO, stateDir()).startsWith("..")).toBe(true);
});

test("RED control: a config that lists the state directory fails the same check", () => {
  const dir = fs.mkdtempSync(join(tmpdir(), "peer-routes-cfg-"));
  try {
    const cfg = join(dir, "qmd-collection-corpus.json");
    fs.writeFileSync(cfg, JSON.stringify({ "peer-state": `${stateDir()}/example` }));
    expect(/peer-bridge/.test(fs.readFileSync(cfg, "utf8"))).toBe(true);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

const FENCE = [
  "scripts/telegram/peer-notify-route.test.ts -> ../peer-bridge/chain",
  "scripts/telegram/peer-notify-route.test.ts -> ../peer-bridge/notify",
  "scripts/telegram/peer-notify-route.ts -> ../peer-bridge/chain",
  "scripts/telegram/peer-notify-route.ts -> ../peer-bridge/config",
  "scripts/telegram/peer-notify-route.ts -> ../peer-bridge/ids",
  "scripts/telegram/peer-notify-route.ts -> ../peer-bridge/notify",
];
const fencePairs = (root: string): string[] => walk(join(root, "scripts"))
  .filter(f => /\.(ts|mjs|js)$/.test(f) && !f.includes(`${join("scripts", "peer-bridge")}/`) && !f.includes("/node_modules/"))
  .flatMap(f => [...fs.readFileSync(f, "utf8").matchAll(/from\s+["']([^"']*peer-bridge\/[^"']*)["']/g)].map(m => `${relative(root, f)} -> ${m[1]}`))
  .sort();

test("only the peer notify flusher, outside scripts/peer-bridge, imports a peer-bridge module, and only chain, config, ids and notify", () => {
  expect(fencePairs(REPO)).toEqual(FENCE);
});

test("RED control: a planted importer outside scripts/peer-bridge fails the fence", () => {
  const root = fs.mkdtempSync(join(tmpdir(), "peer-routes-fence-"));
  try {
    fs.mkdirSync(join(root, "scripts/telegram"), { recursive: true });
    fs.writeFileSync(join(root, "scripts/telegram/peer-notify-route.ts"), 'import { verifyChain } from "../peer-bridge/chain";\nimport { readPeersFile } from "../peer-bridge/config";\nimport { peersFile } from "../peer-bridge/ids";\nimport { renderNotify } from "../peer-bridge/notify";\n');
    fs.writeFileSync(join(root, "scripts/telegram/peer-notify-route.test.ts"), 'import { Chain } from "../peer-bridge/chain";\nimport { notifyFile } from "../peer-bridge/notify";\n');
    expect(fencePairs(root)).toEqual(FENCE);
    fs.writeFileSync(join(root, "scripts/telegram/chief-route.ts"), 'import { readChain } from "../peer-bridge/chain";\n');
    expect(fencePairs(root)).not.toEqual(FENCE);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

const CANARY = "CANARY-7f3a9c";
const OP_BOT = "999000999", OP_CHAT = 4242, OUR_NAME = "ours_bot", PEER_ID = "555000111", PEER_CHAT = -1001234567890;
const STUB_READER = `#!/usr/bin/env bash
in=$(cat)
case "$in" in *FAILRUN*) exit 1;; esac
route=escalate
case "$in" in *ROUTE=ack*) route=ack;; *ROUTE=drop*) route=drop;; esac
c=$(printf '%s' "$in" | grep -o 'CANARY-[0-9a-f]*' | head -1)
printf '{"result":"{\\\\"route\\\\":\\\\"%s\\\\",\\\\"summary\\\\":\\\\"digest %s\\\\",\\\\"asks\\\\":[\\\\"%s?\\\\"]}"}' "$route" "$c" "$c"
`;

function canaryHome() {
  const home = fs.mkdtempSync(join(tmpdir(), "peer-canary-home-"));
  const S = join(home, ".himmel", "peer-bridge"), conf = join(home, ".config", "himmel", "peer-bridge");
  const bridgeRoot = join(home, "bridge"), himmel = join(home, "himmel");
  fs.mkdirSync(join(S, "example", "spool"), { recursive: true, mode: 0o700 });
  fs.mkdirSync(conf, { recursive: true });
  fs.writeFileSync(join(conf, "hmac.key"), "k".repeat(32), { mode: 0o600 });
  fs.mkdirSync(join(bridgeRoot, "sessions", "__chat__"), { recursive: true });
  fs.writeFileSync(join(bridgeRoot, "sessions", "__chat__", "context.md"), "context\n");
  fs.mkdirSync(join(bridgeRoot, "consoles", "replies"), { recursive: true });
  fs.writeFileSync(join(bridgeRoot, "consoles", "replies", `${OP_CHAT}_1.json`), '{"name":"chief"}');
  for (const d of ["jira", "luna", "handovers"]) { fs.mkdirSync(join(home, d)); fs.writeFileSync(join(home, d, "note.md"), "note\n"); }
  fs.mkdirSync(join(himmel, "scripts", "lib"), { recursive: true });
  fs.copyFileSync(join(REPO, "scripts/lib/redact.sh"), join(himmel, "scripts/lib/redact.sh"));
  fs.writeFileSync(join(himmel, "scripts/lib/usage-preflight.sh"), "#!/usr/bin/env bash\necho PROCEED\n");
  const bin = fs.mkdtempSync(join(tmpdir(), "peer-canary-bin-"));
  fs.writeFileSync(join(bin, "claude"), STUB_READER, { mode: 0o755 });
  return { home, S, conf, bridgeRoot, himmel, stub: join(bin, "claude") };
}

const leaks = (home: string, S: string): string[] =>
  walk(home).filter(f => !f.startsWith(S + "/") && fs.readFileSync(f, "utf8").includes(CANARY)).map(f => relative(home, f)).sort();

test("canary sweep, PR1 routes", async () => {
  const h = canaryHome();
  const origSpawn = procHooks.spawn;
  procHooks.spawn = ((cmd: string, args: string[], o: any) => origSpawn(cmd === "claude" ? h.stub : cmd, args, o)) as any;
  try {
    const cfg = {
      operatorBotId: OP_BOT, operatorChatId: OP_CHAT, bridgeRoot: h.bridgeRoot, himmelRoot: h.himmel, maxTextChars: 4000, addressing: "command",
      peers: { example: { peerBotId: PEER_ID, chatId: PEER_CHAT, allowFrom: [PEER_ID], opens: ["question", "status", "info"], maxOpenThreads: 50, maxPerMinute: 1000, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
        theirs: { username: "example_bot", opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07" } } },
    } as unknown as Config;
    const clock = { t: Date.UTC(2026, 10, 20, 12) };
    const peerChat: string[] = [];
    let pmid = 9000;
    const tg: TgLike = { getUpdates: async () => [], getChatMember: async () => ({ user: { username: OUR_NAME } }), sendMessage: async (_c: number, text: string) => { peerChat.push(text); return { message_id: ++pmid }; } };
    const deps: PollerDeps = { cfg, tg, ourBotId: "111000111", stateDir: h.S, configDir: h.conf, clock: () => clock.t, hostname: "testbox", log: () => {} };
    const opSent: { mid: number; text: string }[] = [];
    let omid = 700;
    const access = { allowFrom: [String(OP_CHAT)] };
    const flusher = makePeerNotifyFlusher({
      stateDir: h.S, himmelRoot: h.himmel, token: `${OP_BOT}:${"A".repeat(35)}`, access: () => access, peersCfg: () => ({ operatorChatId: OP_CHAT, operatorBotId: OP_BOT }),
      send: async (_t, chat, text) => { expect(chat).toBe(OP_CHAT); opSent.push({ mid: ++omid, text }); return { ok: true, messageId: omid }; },
      procs: () => [], botPids: () => [], clock: () => clock.t, log: () => {},
    });
    const tick = async () => { flusher.notePoll(true); await flusher.flush(); await flushOutboxes(h.bridgeRoot, async () => true); };
    let uid = 500, mid = 100;
    const hex8 = () => Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0");
    const peerMsg = (head: string, body: string) => ({ update_id: ++uid, message: { message_id: ++mid, from: { id: Number(PEER_ID), is_bot: true }, chat: { id: PEER_CHAT, type: "supergroup" }, date: 1, text: `/peer@${OUR_NAME}\n${head} id=${hex8()}\n${body} ${CANARY}` } });

    let poller = await Poller.create(deps);
    await poller.recover();
    for (const [head, body] of [["#ask:question", "escalate me"], ["#status", "ROUTE=ack"], ["#status", "ROUTE=drop"], ["#ask:question", "FAILRUN"]]) {
      await poller.processBatch([peerMsg(head, body)]);
      await tick();
    }
    const waker = (poller as any).waker;
    for (let i = 0; i < 30 && (await waker.escalate({ peer: "example", root: 8000 + i, dir: "in", label: "new question", message_id: 8000 + i, digest: { route: "escalate", summary: "seed", asks: [] } })) === "escalated"; i++);
    await poller.processBatch([peerMsg("#ask:question", "over the cap")]);
    await tick();
    poller = await Poller.create(deps);
    await poller.recover();
    await poller.processBatch([peerMsg("#ask:question", "after restart")]);
    await tick();

    const esc = opSent.find(s => s.text.includes(CANARY))!;
    expect(esc).toBeDefined();
    await ingestUpdates(h.bridgeRoot, [{ update_id: 1, message: { message_id: 90, date: Math.floor(Date.now() / 1000), chat: { id: OP_CHAT, type: "private" }, from: { id: OP_CHAT }, text: "my answer", reply_to_message: { message_id: esc.mid, from: { id: Number(OP_BOT), is_bot: true }, text: esc.text } } }], () => true);
    const [rec] = await readNewLines(join(h.bridgeRoot, "inbound.jsonl"), join(h.bridgeRoot, "inbound.jsonl.cursor"));
    const ran: string[] = [];
    const auto: AutoGate = { enabledOps: new Set(), authorize: () => true, fire: () => {}, peerReply: makePeerReplyRoute({ stateDir: h.S, root: h.bridgeRoot, access: () => access, reply: async (_c, text) => { opSent.push({ mid: 0, text }); } }) };
    await handleInbound(h.bridgeRoot, inboundToDelivered(rec), async s => { ran.push(s); }, auto, async () => "spawn-low", () => true, async () => {}, () => false, null, { authorize: () => true, reply: async () => {} });
    await tick();

    const digests = readChain(join(h.S, "example", "digests.jsonl"));
    expect(digests.filter(r => r.kind === "effect").map(r => r.outcome)).toEqual(["escalated", "acked", "dropped", "escalated", "fallback-wake", "fallback-wake"]);
    expect(digests.filter(r => r.kind === "digest").map(r => r.reason ?? r.summary)).toEqual([`digest ${CANARY}`, `digest ${CANARY}`, `digest ${CANARY}`, "exit:1", `digest ${CANARY}`, `digest ${CANARY}`]);
    expect(ran).toEqual([]);
    expect(opSent.at(-1)!.text).toBe(PR1_REPLY_LINE);
    expect(peerChat.some(t => t.includes(CANARY))).toBe(false);
    expect(walk(h.S).some(f => fs.readFileSync(f, "utf8").includes(CANARY))).toBe(true);
    expect(leaks(h.home, h.S)).toEqual([]);

    for (const planted of ["bridge/sessions/__chat__/context.md", `bridge/consoles/replies/${OP_CHAT}_1.json`, "luna/note.md"]) {
      const f = join(h.home, planted), before = fs.readFileSync(f, "utf8");
      fs.appendFileSync(f, CANARY);
      expect(leaks(h.home, h.S)).toEqual([planted]);
      fs.writeFileSync(f, before);
    }
  } finally {
    procHooks.spawn = origSpawn;
    fs.rmSync(h.home, { recursive: true, force: true });
  }
});
