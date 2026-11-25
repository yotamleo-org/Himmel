import { createHash } from "node:crypto";
import { hostname as osHostname } from "node:os";
import { evaluate, loadMatrix } from "../guardrails/egress-matrix-eval.mjs";
import type { Peer } from "./config";
import { parseEnvelopeLine } from "./envelope";
import { ENV_LINE_RE, SIG_LINE_RE } from "./grammar";
import { runProc } from "./proc";
import { currentSigningKey, publicKeyOf, verify } from "./sign";

export type OutCtx = {
  peer: Peer | undefined;
  kind: string;                 // question | status | info | answer, or a template name
  isRoot: boolean;
  isTemplate: boolean;
  tainted?: boolean;
  tty?: boolean;
  himmelRoot: string;
  maxTextChars?: number;
  allowShape?: string;
  claudecode?: boolean;
  hostname?: string;
  matrix?: { default: string; rules: unknown[] };
  usage?: { openOutbound: number; sentLastMinute: number };
  corpus?: "peer-desk" | "operator-reply";
};
export type Refusal = { ok: false; rule: string; shape?: string };
export type Outcome = { ok: true } | Refusal;

const refuse = (rule: string, shape?: string): Refusal => (shape ? { ok: false, rule, shape } : { ok: false, rule });

const OPENING = ["question", "status", "info"];
let defaultMatrix: any;

function matrixAllows(ctx: Pick<OutCtx, "matrix">, corpus: "peer-desk" | "operator-reply" | "peer-jobs" = "peer-desk"): boolean {
  try {
    const m = ctx.matrix ?? (defaultMatrix ??= loadMatrix());
    const { verdict } = evaluate(m, corpus, "peer-telegram", "peer-message");
    return verdict === "allow" || verdict === "allow+log";
  } catch { return false; }
}

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function privateIPv4(a: number, b: number): boolean {
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
}
export function badHost(text: string, host: string): boolean {
  for (const m of text.matchAll(/(?<![0-9.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9])/g)) {
    const o = [m[1], m[2], m[3], m[4]].map(Number);
    if (o.every(n => n <= 255) && privateIPv4(o[0], o[1])) return true;
  }
  if (/(?<![A-Za-z0-9-])localhost(?![A-Za-z0-9-])/i.test(text)) return true;
  if (/(?<![0-9A-Fa-f:])::1(?![0-9A-Fa-f:])/.test(text) || /(?<![0-9A-Fa-f])(?:fe80|f[cd][0-9a-f]{2}):/i.test(text)) return true;
  if (/(?<![A-Za-z0-9-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:local|lan|internal|home\.arpa)(?![A-Za-z0-9-])/i.test(text)) return true;
  for (const name of new Set([host, host.split(".")[0]])) {
    if (name.length >= 3 && new RegExp(`(?<![A-Za-z0-9-])${esc(name)}(?![A-Za-z0-9-])`, "i").test(text)) return true;
  }
  return false;
}

const URL_RE = /https?:\/\/[^\s<>"')\]]+/gi;
// `/seg` not preceded by `:`, `/` or an alphanumeric, a drive path, or `~/`.
const PATH_RE = /(?<![:/A-Za-z0-9])\/[A-Za-z0-9._~@-]|[A-Za-z]:[\\/]|~\//;
const ENV_FILE_RE = /(?<![A-Za-z0-9])[A-Za-z0-9_.-]*\.env(?![A-Za-z0-9_])/;
const AUTHORITY: RegExp[] = [
  /(?<![0-9A-Fa-f])R-[0-9a-f]{32}(?![0-9A-Fa-f])/,
  /(?<![0-9A-Fa-f])[0-9a-f]{32}(?![0-9A-Fa-f])/,
  /(?<![A-Za-z0-9])[a-z0-9]+-[a-z][0-9]+-[0-9a-f]{4}(?![0-9A-Fa-f])/,
  /(?<![A-Za-z0-9])[A-Z]{1,3}-[A-Za-z0-9._-]+-[0-9a-f]{8}(?![A-Za-z0-9])/,
  /nonce[:=]/i,
  /Security reviewed:/i,
  /\b(?:approve|deny)\b[\s:]*\b[0-9]{6}\b/i,
];
const PEM_RE = /-----BEGIN[A-Z ]*PRIVATE KEY-----/;

export async function checkOutbound(text: string, ctx: OutCtx): Promise<Outcome> {
  const peer = ctx.peer;
  if (!peer) return refuse("unknown-peer");
  if (peer.chatId === null) return refuse("peer-not-live");
  if (!ctx.isTemplate) {
    if (ctx.kind !== "answer" && !OPENING.includes(ctx.kind)) return refuse("unknown-kind");
    if (ctx.isRoot) {
      if (ctx.kind === "answer") return refuse("answer-needs-thread");
      if (!(peer.theirs.opens as string[]).includes(ctx.kind)) return refuse("kind-not-open");
    }
  }
  if (ctx.usage) {
    if (ctx.isRoot && !ctx.isTemplate && ctx.usage.openOutbound >= peer.theirs.maxOpenThreads) return refuse("their-open-threads");
    if (ctx.usage.sentLastMinute >= peer.theirs.maxPerMinute) return refuse("their-rate");
  }
  if (text.trim() === "") return refuse("empty");
  if (text.length > (ctx.maxTextChars ?? 4000)) return refuse("too-long");
  if (!matrixAllows(ctx, ctx.corpus ?? "peer-desk")) return refuse("egress-matrix");
  return contentRules(text, ctx);
}

async function contentRules(text: string, ctx: Pick<OutCtx, "hostname" | "himmelRoot" | "allowShape" | "claudecode" | "tty" | "tainted">): Promise<Outcome> {
  if (badHost(text, ctx.hostname ?? osHostname())) return refuse("host");
  if (ENV_FILE_RE.test(text)) return refuse("env-file");
  if (PATH_RE.test(text.replace(URL_RE, " "))) return refuse("path");
  if (AUTHORITY.some(re => re.test(text))) return refuse("authority-token");

  return secretShapes(text, ctx);
}

export type EnvOutCtx = {
  peer: Peer | undefined;
  self: string | undefined;
  keyDir: string;
  himmelRoot: string;
  maxTextChars?: number;
  hostname?: string;
  matrix?: { default: string; rules: unknown[] };
};

export async function checkEnvelopeOutbound(lines: string[], ctx: EnvOutCtx): Promise<Outcome> {
  const peer = ctx.peer;
  if (!peer) return refuse("unknown-peer");
  if (peer.chatId === null) return refuse("peer-not-live");
  if (lines.length !== 4) return refuse("line-shape");
  const [l1, l2, l3, l4] = lines;
  if (l1 !== `/peer@${peer.theirs.username}`) return refuse("address");
  const m = ENV_LINE_RE.exec(l2);
  if (!m) return refuse("line-shape");
  if (lines.join("\n").length > (ctx.maxTextChars ?? 4000)) return refuse("too-long");

  if (!SIG_LINE_RE.test(l4)) return refuse("signature");
  let key: { id: string; path: string };
  try { key = currentSigningKey(ctx.keyDir); } catch { return refuse("no-key"); }
  if (m[1] !== key.id) return refuse("key-id");
  if (!verify(l2, l3, l4.slice(4), publicKeyOf(key.path))) return refuse("signature");

  const parsed = parseEnvelopeLine(l3);
  if (!parsed.ok) return refuse("schema");
  const env = parsed.env;
  if (env.msg !== m[2] || env.from !== ctx.self || env.to !== peer.theirs.stationName || env.chat !== String(peer.chatId)) return refuse("binding");

  if (!matrixAllows(ctx, "peer-jobs")) return refuse("egress-matrix");
  return contentRules(l3, { hostname: ctx.hostname, himmelRoot: ctx.himmelRoot });
}

const SAFE_ROOT = /^[A-Za-z0-9_\/.@+-]+$/;
async function secretShapes(text: string, ctx: OutCtx): Promise<Outcome> {
  if (!SAFE_ROOT.test(ctx.himmelRoot)) return refuse("redact-check-failed");
  const run = await runProc(["bash", "-c", `. ${ctx.himmelRoot}/scripts/lib/redact.sh && redact_check`], {
    input: text, env: { PATH: process.env.PATH ?? "/usr/bin:/bin" }, timeoutMs: 15_000,
  });
  if (run.timedOut || run.code === null) return refuse("redact-check-failed");
  if (run.code === 0) return { ok: true };
  const m = /^shape=(\S+) precision=(high|low)$/m.exec(run.stdout);
  if (run.code < 10 || !m) return refuse("redact-check-failed");
  const [, shape, precision] = m;
  const inClaude = ctx.claudecode ?? Boolean(process.env.CLAUDECODE);
  const waiver = ctx.allowShape === shape && precision === "low" && ctx.tty === true && !inClaude && !ctx.tainted;
  if (!waiver) return refuse("secret-shape", shape);
  // The key-block check is the last shape, so a waived low shape cannot hide one.
  return PEM_RE.test(text) ? refuse("secret-shape", "pem") : { ok: true };
}

export function refusalRecord(text: string, res: Refusal, ts: number) {
  return { kind: "refused" as const, reason: res.rule, shape: res.shape ?? null, sha256: createHash("sha256").update(text).digest("hex"), length: text.length, ts };
}
