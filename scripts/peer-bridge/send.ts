// send.ts <peer> --kind K [--reply-to N] --text '...' [--allow-shape NAME]
// The only free-text path. It runs the egress gate to refuse early, writes one
// draft spool file and waits for the poller's result; the poller checks again
// and is the authority. Nothing leaves until the operator approves the draft
// with a tap on Telegram. There is no file input.
// Exit: 0 drafted (approve it on Telegram), 2 refused (names the rule),
// 3 not a desk or not set up, 4 queued but unconfirmed: do not resend.
import fs from "node:fs";
import { join } from "node:path";
import { pollerStale, readChain, submitSpool } from "./chain";
import { readPeersFile } from "./config";
import { checkOutbound } from "./egress";
import { PEER_NAME_RE, SESSION_ID_RE, peerDir, peersFile, stateDir } from "./ids";
import { Threads, type ThreadRec } from "./threads";

const KINDS = ["question", "status", "info", "answer"] as const;
type Kind = (typeof KINDS)[number];

function out(code: number, line: string): never {
  (code === 0 ? process.stdout : process.stderr).write(line + "\n");
  process.exit(code);
}

const hhmm = (ms: number) => { const d = new Date(ms); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };

function parseArgs(argv: string[]) {
  const peer = argv[0];
  if (!peer || !PEER_NAME_RE.test(peer)) out(3, "usage: send.ts <peer> --kind K [--reply-to N] --text '...'");
  let kind: string | undefined, replyTo: number | undefined, text: string | undefined, allowShape: string | undefined;
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    if (a === "--kind" && v !== undefined) { kind = v; i++; }
    else if (a === "--reply-to" && /^[0-9]+$/.test(v ?? "")) { replyTo = Number(v); i++; }
    else if (a === "--text" && v !== undefined) { text = v; i++; }
    else if (a === "--allow-shape" && /^[a-z_]+$/.test(v ?? "")) { allowShape = v; i++; }
    else out(2, `refused: unknown or malformed argument ${JSON.stringify(a)}`);
  }
  return { peer, kind, replyTo, text, allowShape };
}

// Our open outbound threads and the sends of the last minute, for the `theirs` caps.
function usage(peer: string, cfg: ReturnType<typeof readPeersFile>) {
  const dir = peerDir(peer);
  const threads = Threads.load(readChain(join(dir, "threads.jsonl")).filter(r => r.kind === "thread") as unknown as ThreadRec[], { peers: cfg.peers, clock: Date.now });
  const recent = readChain(join(dir, "outbox.jsonl")).filter(r => r.kind === "sent" && Date.now() - r.ts * 1000 < 60_000).length;
  return { openOutbound: threads.openOutbound(peer), sentLastMinute: recent };
}

async function main() {
  const { peer, kind, replyTo, text, allowShape } = parseArgs(process.argv.slice(2));
  const inClaude = Boolean(process.env.CLAUDECODE);
  if (inClaude && process.env.PEER_DESK !== peer) out(3, "send.ts runs only from the peer desk");
  let cfg;
  try { cfg = readPeersFile(peersFile()); } catch { out(3, "peer bridge is not set up"); }
  if (!fs.existsSync(join(peerDir(peer), "spool"))) out(3, "peer bridge is not set up for this peer");
  if (!kind || !(KINDS as readonly string[]).includes(kind)) out(2, "refused: unknown-kind");
  if (text === undefined) out(2, "refused: empty");
  if (kind === "answer" && replyTo === undefined) out(2, "refused: answer-needs-thread");
  const sid = process.env.CLAUDE_CODE_SESSION_ID ?? "";
  const tainted = inClaude || Boolean(process.env.PEER_DESK) || (SESSION_ID_RE.test(sid) && fs.existsSync(join(stateDir(), "taint", sid)));
  const tty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  const isRoot = replyTo === undefined;

  const res = await checkOutbound(text!, {
    peer: cfg.peers[peer], kind: kind as Kind, isRoot, isTemplate: false, tainted, tty, claudecode: inClaude, allowShape,
    himmelRoot: cfg.himmelRoot, maxTextChars: cfg.maxTextChars, usage: usage(peer, cfg),
  });
  if (!res.ok) out(2, `refused: ${res.rule}${res.shape ? ` (${res.shape})` : ""}`);

  if (pollerStale(join(stateDir(), "poller.pid"))) process.stderr.write("warning: the running poller loaded older peer-bridge code than this checkout and may refuse this send; restart it (himmel-peer-bridge)\n");
  const name = submitSpool(peerDir(peer), { type: "draft", source: "send.ts", kind: kind as Kind, ...(replyTo !== undefined ? { replyTo } : {}), text: text!, ...(allowShape && tty && !inClaude ? { allowShape } : {}) });
  const resultFile = join(peerDir(peer), "spool", "results", name);
  const deadline = Date.now() + (Number(process.env.PEER_SEND_WAIT_MS) || 10_000);
  while (Date.now() < deadline) {
    try {
      const r = JSON.parse(fs.readFileSync(resultFile, "utf8"));
      fs.rmSync(resultFile, { force: true });
      if (r.ok) out(0, `drafted ${r.draft}; approve it on Telegram by ${hhmm(r.deadline)}`);
      out(2, `refused: ${r.rule}${r.shape ? ` (${r.shape})` : ""}${r.why ? `: ${r.why}` : ""}`);
    } catch (e) { if (!(e instanceof SyntaxError) && (e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    await new Promise(r => setTimeout(r, 100));
  }
  out(4, `queued as ${name}; the poller will draft it; do not resend`);
}

main();
