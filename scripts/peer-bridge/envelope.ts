// The typed envelope: the closed schema, the canonical encoder and the only
// JSON.parse of an envelope line. Callers verify the Ed25519 signature before
// they call parseEnvelopeLine (gate.ts admitEnvelope, egress.ts for our own
// outbound lines), so a peer's bytes are never parsed unsigned.
//
// Every time here is UTC seconds. `chat` travels as a string.
import { mintId } from "./grammar";
import { PEER_NAME_RE } from "./ids";

export const TIMEOUT_S_MAX = 10200;   // the longest `timeout_s` a res running can carry
export const ALLOWANCE_S = 1200;      // setup-and-pull allowance and the backstop floor
export const LIFETIME_S = 86400;      // exp = iat + LIFETIME_S, for every kind
export const IAT_FUTURE_SKEW_S = 600; // an iat further than this in our future is refused
export const MAX_LINE_BYTES = 3000;

// The numeric ranges the wire can carry. config.ts clamps a reported value to its
// range before it is encoded, so a reply can never fail our own egress re-check.
export const RANGES = {
  timeout_s: [60, TIMEOUT_S_MAX], minutes: [0, 180], bytes: [0, 5_242_880],
  queue: [0, 3], jobs_left: [0, 1000], vm_minutes_left: [0, 10000],
} as const;

export const STATION_NAME_RE = PEER_NAME_RE;
export const SUITE_PATH_RE = /^scripts\/[a-z0-9_/.-]{1,120}\.sh$/;
const CHAT_RE = /^-100[0-9]{1,16}$/;
const HEX8_RE = /^[0-9a-f]{8}$/;
const HEX16_RE = /^[0-9a-f]{16}$/;
const HEX40_RE = /^[0-9a-f]{40}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;

export const KINDS = ["req", "res", "capacity-ask", "capacity", "cancel", "halt"] as const;
export type Kind = (typeof KINDS)[number];
export const RES_STATES = ["accepted", "refused", "running", "done", "cancelled", "expired"] as const;
export type ResState = (typeof RES_STATES)[number];
export const REFUSED = ["not-served", "unknown-sha", "too-old", "not-allowed", "budget", "no-vm"] as const;
export type Refused = (typeof REFUSED)[number];
export const OUTCOMES = ["pass", "fail", "error"] as const;
export type Outcome = (typeof OUTCOMES)[number];
export const CAPACITY_STATES = ["idle", "busy", "not-served", "no-vm"] as const;
export type CapacityState = (typeof CAPACITY_STATES)[number];

export type Common = { v: 1; msg: string; from: string; to: string; chat: string; iat: number; exp: number };
export type Envelope = Common & (
  | { kind: "req"; job: string; op: "run-suite"; sha: string; suites: string[] }
  | { kind: "res"; job: string; state: "accepted" | "cancelled" | "expired" }
  | { kind: "res"; job: string; state: "refused"; refused: Refused }
  | { kind: "res"; job: string; state: "running"; timeout_s: number }
  | { kind: "res"; job: string; state: "done"; results: Outcome[]; minutes: number; image: string; log: { sha256: string; bytes: number } }
  | { kind: "capacity-ask" }
  | { kind: "capacity"; re: string; state: CapacityState; queue: number; jobs_left: number; vm_minutes_left: number }
  | { kind: "cancel"; job: string }
  | { kind: "halt" }
);

// A field: its key, a check, and how it is written. Every table below is in wire order.
type Field = { key: string; ok: (v: unknown) => boolean; enc: (v: any) => string };
const isInt = (v: unknown, lo: number, hi: number): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= lo && v <= hi;
const isStr = (v: unknown, re: RegExp): v is string => typeof v === "string" && re.test(v);
const jstr = (v: string) => JSON.stringify(v);

const lit1: Field = { key: "v", ok: v => v === 1, enc: () => "1" };
const str = (key: string, re: RegExp): Field => ({ key, ok: v => isStr(v, re), enc: jstr });
const int = (key: string, lo: number, hi: number): Field => ({ key, ok: v => isInt(v, lo, hi), enc: String });
const oneOf = (key: string, set: readonly string[]): Field => ({ key, ok: v => typeof v === "string" && set.includes(v), enc: jstr });
const list = (key: string, min: number, max: number, item: (v: unknown) => boolean, encItem: (v: any) => string): Field => ({
  key, ok: v => Array.isArray(v) && v.length >= min && v.length <= max && v.every(item), enc: (a: unknown[]) => `[${a.map(encItem).join(",")}]`,
});
const suite = (v: unknown) => isStr(v, SUITE_PATH_RE) && !v.includes("..");

const logField: Field = {
  key: "log",
  ok: v => {
    if (!v || typeof v !== "object" || Array.isArray(v)) return false;
    const o = v as Record<string, unknown>;
    const keys = Object.keys(o);
    return keys.length === 2 && keys.every(k => k === "sha256" || k === "bytes") && isStr(o.sha256, HEX64_RE) && isInt(o.bytes, ...RANGES.bytes);
  },
  enc: (v: { sha256: string; bytes: number }) => `{"sha256":${jstr(v.sha256)},"bytes":${v.bytes}}`,
};

const COMMON: Field[] = [
  lit1, str("msg", HEX8_RE), str("from", STATION_NAME_RE), str("to", STATION_NAME_RE), str("chat", CHAT_RE),
  int("iat", 1, Number.MAX_SAFE_INTEGER), int("exp", 2, Number.MAX_SAFE_INTEGER), oneOf("kind", KINDS),
];
const JOB = str("job", HEX16_RE);
const RES_BY_STATE: Record<ResState, Field[]> = {
  accepted: [], cancelled: [], expired: [],
  refused: [oneOf("refused", REFUSED)],
  running: [int("timeout_s", ...RANGES.timeout_s)],
  done: [
    list("results", 1, 10, v => typeof v === "string" && (OUTCOMES as readonly string[]).includes(v), jstr),
    int("minutes", ...RANGES.minutes), str("image", HEX64_RE), logField,
  ],
};
const BODY: Record<Exclude<Kind, "res">, Field[]> = {
  req: [JOB, oneOf("op", ["run-suite"]), str("sha", HEX40_RE), list("suites", 1, 10, suite, jstr)],
  "capacity-ask": [],
  capacity: [str("re", HEX8_RE), oneOf("state", CAPACITY_STATES), int("queue", ...RANGES.queue), int("jobs_left", ...RANGES.jobs_left), int("vm_minutes_left", ...RANGES.vm_minutes_left)],
  cancel: [JOB],
  halt: [],
};

function fieldsFor(o: Record<string, unknown>): Field[] | null {
  const kind = o.kind;
  if (kind === "res") {
    const state = o.state;
    if (typeof state !== "string" || !(RES_STATES as readonly string[]).includes(state)) return null;
    return [JOB, oneOf("state", RES_STATES), ...RES_BY_STATE[state as ResState]];
  }
  if (typeof kind !== "string" || !Object.hasOwn(BODY, kind)) return null;
  return BODY[kind as Exclude<Kind, "res">];
}

// Returns the schema's complaint, or null. The key set must match exactly.
function problem(o: unknown): string | null {
  if (!o || typeof o !== "object" || Array.isArray(o)) return "schema: not an object";
  const rec = o as Record<string, unknown>;
  const body = fieldsFor(rec);
  if (!body) return "schema: unknown kind or state";
  const fields = [...COMMON, ...body];
  const have = Object.keys(rec);
  if (have.length !== fields.length) return "schema: field set";
  for (const f of fields) {
    if (!Object.hasOwn(rec, f.key)) return `schema: missing ${f.key}`;
    if (!f.ok(rec[f.key])) return `schema: bad ${f.key}`;
  }
  if (have.some(k => !fields.some(f => f.key === k))) return "schema: unknown key";
  if (!((rec.exp as number) > (rec.iat as number) && (rec.exp as number) <= (rec.iat as number) + LIFETIME_S)) return "schema: exp window";
  return null;
}

// The canonical line: schema order, no whitespace, integers only. It throws on an
// envelope the schema refuses, so a bug cannot send a field the peer would refuse.
function encodeFields(rec: Record<string, unknown>): string {
  const fields = [...COMMON, ...fieldsFor(rec)!];
  return `{${fields.map(f => `${jstr(f.key)}:${f.enc(rec[f.key])}`).join(",")}}`;
}

export function encodeCanonical(e: Envelope): string {
  const bad = problem(e);
  if (bad) throw new Error(`encodeCanonical: ${bad}`);
  return encodeFields(e as unknown as Record<string, unknown>);
}

export type ParseResult = { ok: true; env: Envelope } | { ok: false; reason: string };

// Line 3 of a message whose signature has already verified. Parse, the closed
// schema, then byte-equality with the canonical re-encode. A line that equals its
// own re-encode has no duplicate key (JSON.parse keeps the last, so the re-encode
// drops one), no key out of order, no 1.0 or exponent and no whitespace. Nothing
// acts on the parse result before all three pass, so their order is not visible.
export function parseEnvelopeLine(line3: string): ParseResult {
  if (Buffer.byteLength(line3, "utf8") > MAX_LINE_BYTES) return { ok: false, reason: "length: over 3000 bytes" };
  if (!/^[\x20-\x7e]+$/.test(line3)) return { ok: false, reason: "ascii: not printable ASCII" };
  let parsed: unknown;
  try { parsed = JSON.parse(line3); } catch { return { ok: false, reason: "json: unparseable" }; }
  const bad = problem(parsed);
  if (bad) return { ok: false, reason: bad };
  if (encodeFields(parsed as Record<string, unknown>) !== line3) return { ok: false, reason: "canonical: re-encode differs" };
  return { ok: true, env: parsed as Envelope };
}

export type BuildCtx = { from: string; to: string; chat: number; now: number };

// A fresh msg id, iat = now and exp = iat + 86400 for every kind (R4-F6).
export function buildEnvelope(kind: Kind, body: Record<string, unknown>, ctx: BuildCtx): Envelope {
  const env = { v: 1, msg: mintId(), from: ctx.from, to: ctx.to, chat: String(ctx.chat), iat: ctx.now, exp: ctx.now + LIFETIME_S, kind, ...body } as Envelope;
  encodeCanonical(env);
  return env;
}
