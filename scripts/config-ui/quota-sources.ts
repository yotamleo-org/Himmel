// quota-sources.ts — the read-only source behind GET /api/bank.
// Reads the two cache files bank-preflight reads: the Claude usage cache the statusline producer writes and the Codex
// bank cache codex-bank-probe writes. It never spawns a probe or producer, and never opens a credential file.
// A number that cannot be established is null with a reason (state unknown), never 0.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { codexWindowLabel } from "../lanes/bank-status-core.mjs";

type Env = Record<string, string | undefined>;
export type QuotaWindow = {
  used_pct: number | null; resets_at: string | null; captured_at: string | null; age_s: number | null;
  state: "ok" | "stale" | "unknown"; possibly_reset: boolean; reason: string | null;
};
export type Quota = {
  claude: { five_hour: QuotaWindow; seven_day: QuotaWindow };
  codex: { five_hour: QuotaWindow; weekly: QuotaWindow };
};

const unknown = (reason: string): QuotaWindow =>
  ({ used_pct: null, resets_at: null, captured_at: null, age_s: null, state: "unknown", possibly_reset: false, reason });

// A bare number is epoch seconds (ms when huge); a string is ISO. null = unusable.
function ms(v: unknown): number | null {
  let t: number | null = null;
  if (typeof v === "number" && Number.isFinite(v) && v > 0) t = v > 1e12 ? v : v * 1000;
  else if (typeof v === "string") { const p = Date.parse(v); if (Number.isFinite(p)) t = p; }
  return t !== null && Math.abs(t) <= 8.64e15 ? t : null; // outside the Date range, toISOString() would throw
}
const iso = (t: number | null) => (t === null ? null : new Date(t).toISOString());

function read(file: string, what: string): { json: Record<string, unknown> } | { reason: string } {
  let text: string;
  try { text = readFileSync(file, "utf8"); } catch { return { reason: `${what} cache missing` }; }
  try {
    const j = JSON.parse(text);
    if (j && typeof j === "object" && !Array.isArray(j)) return { json: j as Record<string, unknown> };
  } catch { /* fall through */ }
  return { reason: `${what} cache unreadable` };
}

function window(used: unknown, resets: unknown, capturedMs: number | null, now: number, maxAgeS: number, notReported = "window not reported"): QuotaWindow {
  if (capturedMs === null) return unknown("cache has no capture time");
  const age = Math.max(0, Math.floor((now - capturedMs) / 1000));
  // An unreported window still says how old the cache holding that gap is.
  if (typeof used !== "number" || !Number.isFinite(used) || used < 0 || used > 100)
    return { ...unknown(notReported), captured_at: iso(capturedMs), age_s: age };
  const r = ms(resets);
  return {
    used_pct: used, resets_at: iso(r), captured_at: iso(capturedMs), age_s: age,
    state: age > maxAgeS ? "stale" : "ok", possibly_reset: r !== null && r <= now, reason: age > maxAgeS ? `cache older than ${maxAgeS} s` : null,
  };
}

function claude(env: Env, now: number): Quota["claude"] {
  const file = env.CADENCE_USAGE_CACHE || env.CADENCE_BANK_CACHE || env.CLAUDE_USAGE_CACHE || "/tmp/claude/statusline-usage-cache.json";
  const maxAgeEnv = Number(env.CADENCE_USAGE_MAX_AGE) > 0 ? env.CADENCE_USAGE_MAX_AGE : env.CADENCE_BANK_MAX_AGE;
  const maxAge = Number(maxAgeEnv) > 0 ? Number(maxAgeEnv) : 600;
  const r = read(file, "usage");
  if ("reason" in r) return { five_hour: unknown(r.reason), seven_day: unknown(r.reason) };
  const j = r.json;
  const captured = ms(j.derived_at) ?? ms(j.oauth_checked_at);
  const one = (k: string) => {
    const w = j[k] as Record<string, unknown> | null | undefined;
    return window(w && typeof w === "object" ? w.utilization : null, w && typeof w === "object" ? w.resets_at : null, captured, now, maxAge);
  };
  return { five_hour: one("five_hour"), seven_day: one("seven_day") };
}

function codex(env: Env, now: number): Quota["codex"] {
  const file = env.CODEX_USAGE_CACHE || env.CODEX_BANK_CACHE || join(env.HOME || homedir(), ".himmel", "cache", "codex-bank.json");
  const ttlEnv = Number(env.CODEX_USAGE_CACHE_TTL_SECONDS) > 0 ? env.CODEX_USAGE_CACHE_TTL_SECONDS : env.CODEX_BANK_CACHE_TTL_SECONDS;
  const ttl = Number(ttlEnv) > 0 ? Number(ttlEnv) : 6 * 3600;
  const r = read(file, "codex bank");
  if ("reason" in r) return { five_hour: unknown(r.reason), weekly: unknown(r.reason) };
  const j = r.json;
  if (!Array.isArray(j.limits)) {
    const why = "codex bank cache malformed (no limits array)";
    return { five_hour: unknown(why), weekly: unknown(why) };
  }
  const captured = ms(j.capturedAt);
  // Several limitIds can share a window label; the governing one is the highest used%, as bank-status reads it.
  const best = new Map<string, { used: number; resets: unknown }>();
  for (const l of j.limits as Record<string, unknown>[]) {
    if (!l || typeof l !== "object") continue;
    const { usedPercent, windowDurationMins, resetsAt } = l;
    if (typeof usedPercent !== "number" || !Number.isFinite(usedPercent) || typeof windowDurationMins !== "number") continue;
    const label = codexWindowLabel(windowDurationMins);
    const prev = best.get(label);
    if (!prev || usedPercent > prev.used) best.set(label, { used: usedPercent, resets: resetsAt });
  }
  const one = (label: string) => {
    const b = best.get(label);
    return window(b ? b.used : null, b ? b.resets : null, captured, now, ttl, "not reported by this plan");
  };
  return { five_hour: one("5h"), weekly: one("weekly") };
}

export function readQuota(env: Env, now: number): Quota {
  return { claude: claude(env, now), codex: codex(env, now) };
}
