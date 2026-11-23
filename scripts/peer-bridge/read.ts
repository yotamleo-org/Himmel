// read.ts <peer> [--thread N] [--ack TOKEN] [--raw]
// Prints reader digests to a peer desk, and only there: PEER_DESK must name the
// peer, the gate must have stamped this session's read within 5 s, and the taint
// file is written before the first byte of output. Any refusal exits 3 and
// prints nothing. --ack only submits a spool record; the poller moves the cursor.
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import { join } from "node:path";
import { signFence } from "../../marketplace/plugins/himmel-ops/hooks/peer-marker.mjs";
import { submitSpool, readChain } from "./chain";
import { readPeersFile } from "./config";
import { ackToken, digestFile, readCursor, type DigestRec } from "./digests";
import { PEER_NAME_RE, SESSION_ID_RE, configDir, peerDir, peersFile, stateDir } from "./ids";
import { sanitize } from "./sanitize";

const STAMP_MAX_AGE_S = 5;
const BATCH = 10;

function refuse(): never { process.exit(3); }

function parseArgs(argv: string[]) {
  const peer = argv[0];
  if (!peer || !PEER_NAME_RE.test(peer)) refuse();
  let thread: number | undefined, ack: string | undefined, raw = false;
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--raw") raw = true;
    else if (a === "--thread" && /^[0-9]+$/.test(argv[i + 1] ?? "")) thread = Number(argv[++i]);
    else if (a === "--ack" && /^[A-Za-z0-9]+$/.test(argv[i + 1] ?? "")) ack = argv[++i];
    else refuse();
  }
  return { peer, thread, ack, raw };
}

function stampFresh(S: string, sid: string): boolean {
  try {
    const at = Number(fs.readFileSync(join(S, "hooked", sid), "utf8").trim());
    const age = Math.floor(Date.now() / 1000) - at;
    return Number.isFinite(at) && age >= -1 && age <= STAMP_MAX_AGE_S;
  } catch { return false; }
}

function header(rec: DigestRec): string {
  const route = rec.route === "escalate" || rec.route === "ack" || rec.route === "drop" ? ` · route ${rec.route}` : "";
  return `peer ${rec.peer} · T${rec.root_id} · ${sanitize(rec.tag, 24)} · ${new Date(rec.ts * 1000).toISOString()}${route}`;
}

function renderRecord(key: Buffer, rec: DigestRec): string {
  const nonce = randomBytes(8).toString("hex");
  const lines = [signFence(key, nonce), header(rec)];
  lines.push(rec.summary === null ? `summary: none (${sanitize(rec.reason ?? "no digest", 60)})` : `summary: ${sanitize(rec.summary, 280)}`);
  rec.asks.slice(0, 3).forEach((a, i) => lines.push(`ask ${i + 1}: ${sanitize(a, 140)}`));
  lines.push(`<<<END-PEER-UNTRUSTED nonce=${nonce}>>>`);
  return lines.join("\n");
}

function rawMode(peer: string, thread: number | undefined, maxChars: number): void {
  const tty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  if (process.env.CLAUDECODE || process.env.CLAUDE_CODE_SESSION_ID || !tty) refuse();
  const recs = readChain(join(peerDir(peer), "inbox.jsonl")).filter(r => r.kind === "peer-msg" && (thread === undefined || r.root_id === thread));
  const out = recs.map(r => `peer ${peer} · T${r.root_id} · ${sanitize(String(r.tag), 24)} · from ${sanitize(String(r.from_id), 20)}\n${sanitize(String(r.text), maxChars)}`);
  process.stdout.write((out.length ? out.join("\n\n") : `no messages from ${peer}`) + "\n");
}

function main(): void {
  const { peer, thread, ack, raw } = parseArgs(process.argv.slice(2));
  const S = stateDir();
  let cfg;
  try { cfg = readPeersFile(peersFile()); } catch { refuse(); }
  if (!cfg.peers[peer] || !fs.existsSync(S)) refuse();
  if (raw) return rawMode(peer, thread, cfg.maxTextChars);

  const sid = process.env.CLAUDE_CODE_SESSION_ID ?? "";
  if (process.env.PEER_DESK !== peer || !SESSION_ID_RE.test(sid) || !stampFresh(S, sid)) refuse();
  let key: Buffer;
  try { key = fs.readFileSync(join(configDir(), "hmac.key")); } catch { refuse(); }
  if (key.length === 0) refuse();

  fs.mkdirSync(join(S, "taint"), { recursive: true, mode: 0o700 });
  fs.closeSync(fs.openSync(join(S, "taint", sid), "a", 0o600));

  const dir = peerDir(peer);
  if (ack !== undefined) {
    submitSpool(dir, { type: "ack", sid, token: ack });
    process.stdout.write("ack submitted\n");
    return;
  }
  const cursor = readCursor(dir, sid);
  const batch = (readChain(digestFile(dir)) as unknown as DigestRec[])
    .filter(r => r.kind === "digest" && (r.n ?? 0) > cursor && (thread === undefined || r.root_id === thread))
    .slice(0, BATCH);
  if (batch.length === 0) { process.stdout.write(`no new digests for ${peer}\n`); return; }
  const body = batch.map(r => renderRecord(key, r)).join("\n");
  const last = batch[batch.length - 1].n!;
  // A thread view skips other threads' digests, so an ack from it would mark those read.
  if (thread !== undefined) { process.stdout.write(`${body}\n`); return; }
  const next = `next: bun ${cfg.himmelRoot}/scripts/peer-bridge/read.ts ${peer} --ack ${ackToken(key, sid, peer, last)}`;
  process.stdout.write(`${body}\n${next}\n`);
}

main();
