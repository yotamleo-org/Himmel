#!/usr/bin/env bun
// scripts/lanes/usage-status.ts
// Reports both the routing guard verdict and the
// evidence behind it. Output remains guard-compatible in its first two fields:
//   <lane-id> <funded|spent|unknown> <measured ...|unmeasurable ...|flat-rate>
//
// PER-BANK READER CONTRACT. Three explicit bank
// states exist — measured, unmeasurable (with the reason), and
// flat-rate/not-applicable — and each bank uses the right one:
//
//   claude — readClaudeBank, live-window gated (unchanged). omitReason or zero
//            readings => unmeasurable; never a fabricated number.
//   glm    — readGlmBank, live-window gated. A live row => measured (the 5h
//            utilization is real data z.ai reports). NO live row => flat-rate,
//            NOT unmeasurable: the z.ai plan is FLAT-RATE (operator ruling;
//            confirmed by the scripts/claude-glm launcher header
//            — "Z.ai GLM flat-rate lane"), so an absent window is "not
//            applicable", not a measurement failure. `unknown` there was
//            bug-shaped: it read like a defect while the lane is in fact
//            always-available.
//   codex  — readCodexDisplay, a TTL-gated CACHE read. The
//            source of truth is `codex app-server`
//            (JSON-RPC account/rateLimits/read), captured by the BOUNDED
//            probe scripts/lanes/codex-usage-probe.ts into
//            ${CODEX_USAGE_CACHE:-${CODEX_BANK_CACHE:-~/.himmel/cache/codex-bank.json}}
//            (every CODEX_USAGE_* name here wins over its old CODEX_BANK_*
//            name, which is still read). bank-status
//            runs the probe at most once per stale/missing read, locked,
//            time-boxed and backed off: the
//            probe reaps its own app-server tree, so the bounded run does not
//            leak a process the way an unbounded spawn per call would.
//            Missing/stale/unusable cache after that => unmeasurable naming
//            the remedy (run the probe) — never a fabricated number, never a
//            silent fail-open. resetsAt arrives per limit and stays per limit in
//            both the cache and the detail line.
//
// The deleted sqlite scan, kept as history so nobody resurrects it: every
// prior attempt read `~/.codex/logs_2.sqlite` for a used_percent — that file
// is a LOG database and never contained a quota field, so its eternal
// `unmeasurable` was the right answer to the wrong question. Its hole #1
// (a reading with no window attribution is incomparable across a weekly
// reset) is now closed structurally: the probe captures resetsAt per
// limit, and readCodexBankCache drops any limit whose window already reset.
// spawn-claudex's dispatch preflight read the same file the same way and was
// therefore refusing EVERY claudex dispatch; it now reads this cache too.
// readCodexBank (sessions rollouts, quota-sources.ts) and scripts/lanes/bench/*
// are DIFFERENT consumers of ~/.codex and are intentionally untouched here.
// Do NOT read "mis-route" as "and then it falls through" (still
// true of the funded verdict): the guard's documented fall-through —
// guard-implementor-dispatch.sh lane_funded() "skipping it, not refusing
// toward it" — fires only on `spent`. A `funded` verdict does the OPPOSITE:
// it refuses the in-process Agent dispatch and names that lane.
// The codex funded threshold and spawn-claudex's refuse point are now ONE
// value (funded-max-pct.mjs, default 90), so no 90-98% disagreement band
// remains for codex; other banks keep their 99 default.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import {
  BANK_IDS,
  defaultClaudeCachePath,
  readClaudeBank,
  readClaudeCacheProvenance,
  readGlmBank,
  type BankId,
  type BankReading,
  type LaneQuotaTargets,
} from "../observability/quota-sources";
import { ledgerPath as quotaGaugeLedgerPath } from "../telegram/quota-gauge";
import { fundedMaxPctForBank } from "./funded-max-pct.mjs";
import {
  CODEX_BANK_PROBE_REMEDY,
  formatMeasured,
  formatUnmeasurable,
  guardState,
  readCodexBankCache,
} from "./bank-status-core.mjs";
import { resolveActiveAccessPath, resolveBankTargets } from "./resolve.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const LANES_PATH = process.env.LANES_REGISTRY || join(SCRIPT_DIR, "lanes.json");
// the machine-local overlay resolve.mjs loadRegistry() layers on
// top of the base registry. The bank probe must read the SAME overlay so an
// overlay-only quota bank gets a real status instead of "no status returned".
const LOCAL_LANES_PATH = join(SCRIPT_DIR, "lanes.local.json");
// codex bank read comes from the probe's TTL'd cache (default
// TTL 6h). See the header for why bank-status only ever READS this file.
const CODEX_BANK_TTL_DEFAULT_SECONDS = 6 * 60 * 60;
const nowMs = Date.now();
const env = process.env;
const home = env.HOME ?? homedir();
const claudeCache = defaultClaudeCachePath(env, process.platform);
const codexBankCachePath = env.CODEX_USAGE_CACHE || env.CODEX_BANK_CACHE || join(home, ".himmel", "cache", "codex-bank.json");
const codexBankTtlSeconds = positiveEnvNumber(env.CODEX_USAGE_CACHE_TTL_SECONDS)
  ?? positiveEnvNumber(env.CODEX_BANK_CACHE_TTL_SECONDS) ?? CODEX_BANK_TTL_DEFAULT_SECONDS;
const glmLedger = quotaGaugeLedgerPath(env);

function positiveEnvNumber(v: string | undefined): number | null {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

// mirrors scripts/lib/usage-cache-identity.sh's
// current_account_hash — same source (.oauthAccount.accountUuid), same
// 16-hex sha256 prefix — so a bash-produced cache and this TS reader agree.
function currentAccountHash(env: NodeJS.ProcessEnv): string | null {
  const configPath = env.CLAUDE_ACCOUNT_CONFIG?.trim() || join(env.HOME ?? homedir(), ".claude.json");
  try {
    const parsed = JSON.parse(readFileSync(configPath, "utf8"));
    const uuid = parsed?.oauthAccount?.accountUuid;
    if (typeof uuid !== "string" || !uuid) return null;
    return createHash("sha256").update(uuid).digest("hex").slice(0, 16);
  } catch {
    return null;
  }
}

// One short field, appended only when the cache is new enough to carry
// derived_at (legacy caches stay silent - see the "shipped lanes" test).
function claudeProvenanceSuffix(): string {
  const provenance = readClaudeCacheProvenance(claudeCache);
  if (!provenance) return "";
  const current = currentAccountHash(env);
  const accountState = !provenance.account || !current ? "unknown" : provenance.account === current ? "match" : "MISMATCH";
  const ageSeconds = Math.max(0, Math.round((nowMs - provenance.derivedAtMs) / 1000));
  const producer = provenance.producedBy ?? "unknown";
  return ` provenance=account=${accountState} age=${ageSeconds}s producer=${producer}`;
}

type CodexCacheReading = BankReading & { resetsAt?: number };
type DisplayResult =
  | { kind: "measured"; readings: CodexCacheReading[] }
  | { kind: "unmeasurable"; reason: string }
  | { kind: "flat-rate" };

// a stale or missing codex cache is refreshed by ONE bounded probe
// run, so the console's bank line stops reading codex=? for days. Guards:
//   - one refresher at a time (mkdir lock beside the cache); a concurrent
//     caller waits inside the same box, then re-reads the cache;
//   - the whole attempt is time-boxed (CODEX_USAGE_REFRESH_BOX_MS, default 30s);
//     the probe gets SIGTERM, whose handler reaps the codex app-server tree;
//   - a failed or hung attempt is not retried for CODEX_USAGE_REFRESH_BACKOFF_MS
//     (attempt stamp), so a broken codex costs one box, not one box per call;
//   - an overridden CODEX_USAGE_CACHE without CODEX_USAGE_PROBE_CMD is a test/ops
//     seam and never spawns the real codex.
// ponytail: refresh is triggered by the bank-status read (no daemon, no LLM
// cadence), so a station nobody reads stays stale until the next read; add an
// LLM-free cron only if the doctor WARN keeps firing.
const REFRESH_BOX_MS = positiveEnvNumber(env.CODEX_USAGE_REFRESH_BOX_MS)
  ?? positiveEnvNumber(env.CODEX_BANK_REFRESH_BOX_MS) ?? 30_000;
const REFRESH_BACKOFF_MS = positiveEnvNumber(env.CODEX_USAGE_REFRESH_BACKOFF_MS)
  ?? positiveEnvNumber(env.CODEX_BANK_REFRESH_BACKOFF_MS) ?? 300_000;
const REFRESH_LOCK_STALE_MS = REFRESH_BOX_MS + 30_000;

function sleepMs(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function refreshCodexCache(cachePath: string): void {
  if ((env.CODEX_USAGE_CACHE || env.CODEX_BANK_CACHE) && !(env.CODEX_USAGE_PROBE_CMD || env.CODEX_BANK_PROBE_CMD)) return;
  const lock = `${cachePath}.refresh.lock`;
  const stamp = `${cachePath}.refresh.attempt`;
  const deadline = Date.now() + REFRESH_BOX_MS;
  try {
    mkdirSync(dirname(cachePath), { recursive: true });
    // the backoff only covers a FINISHED attempt: while a lock is held the stamp is the
    // active refresher's, and this caller waits for it instead of reading it as a failure
    const stampAt = (): number => { try { return statSync(stamp).mtimeMs; } catch { return 0; } };
    const stampOnEntry = stampAt();
    if (!existsSync(lock) && Date.now() - stampOnEntry < REFRESH_BACKOFF_MS) return;
    for (;;) {
      try {
        mkdirSync(lock);
        // a refresher finished while this caller waited: its result is re-read, not re-probed
        if (stampAt() !== stampOnEntry) { rmSync(lock, { recursive: true, force: true }); return; }
        break;
      } catch (error) {
        // anything but "someone holds the lock" (unwritable dir, ...) cannot be waited out
        if (!(typeof error === "object" && error && "code" in error && error.code === "EEXIST")) return;
        if (Date.now() >= deadline) return;
        try {
          if (Date.now() - statSync(lock).mtimeMs > REFRESH_LOCK_STALE_MS) { rmSync(lock, { recursive: true, force: true }); continue; }
        } catch { continue; } // lock vanished between the two calls: retry the mkdir
        sleepMs(200);
        // the holder may have finished: the cache is re-read by the caller either way
        if (!existsSync(lock)) return;
      }
    }
  } catch {
    return;
  }
  try {
    writeFileSync(stamp, `${new Date().toISOString()}\n`);
    const remaining = Math.max(1000, deadline - Date.now());
    spawnSync("bun", [join(SCRIPT_DIR, "codex-usage-probe.ts")], {
      env,
      stdio: "ignore",
      timeout: remaining,
      killSignal: "SIGTERM",
    });
  } catch {
    /* a failed refresh leaves the cache as it was: the caller reports unmeasurable */
  } finally {
    try { rmSync(lock, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

function readCodexDisplay(cachePath: string): DisplayResult {
  const first = readCodexCacheFile(cachePath);
  if (first.kind !== "unmeasurable" || !/cache (missing|stale)/.test(first.reason)) return first;
  refreshCodexCache(cachePath);
  return readCodexCacheFile(cachePath);
}

function readCodexCacheFile(cachePath: string): DisplayResult {
  if (!existsSync(cachePath)) {
    return { kind: "unmeasurable", reason: `codex bank cache missing — ${CODEX_BANK_PROBE_REMEDY}` };
  }
  let text: string;
  try {
    text = readFileSync(cachePath, "utf8");
  } catch (error) {
    const code = typeof error === "object" && error && "code" in error ? String(error.code) : "I/O error";
    return { kind: "unmeasurable", reason: `codex bank cache unreadable (${code}) — ${CODEX_BANK_PROBE_REMEDY}` };
  }
  return readCodexBankCache(text, nowMs, codexBankTtlSeconds);
}

function readGlmDisplay(ledgerPath: string, nowMs: number): DisplayResult {
  const result = readGlmBank(ledgerPath, nowMs);
  if (!result.omitReason && result.readings.length > 0) return { kind: "measured", readings: result.readings };
  // No live ledger window: the lane is flat-rate, not broken. See the header
  // — `unmeasurable`/`unknown` here would be the bug-shaped word for a
  // not-applicable measurement.
  return { kind: "flat-rate" };
}

function readBank(bank: BankId): DisplayResult {
  if (bank === "glm") return readGlmDisplay(glmLedger, nowMs);
  if (bank === "codex") return readCodexDisplay(codexBankCachePath);
  const result = readClaudeBank(claudeCache, nowMs);
  return result.omitReason || result.readings.length === 0
    ? { kind: "unmeasurable", reason: result.omitReason || "no live Claude usage window" }
    : { kind: "measured", readings: result.readings };
}

function detail(result: DisplayResult): string {
  if (result.kind === "unmeasurable") return formatUnmeasurable(result.reason);
  if (result.kind === "flat-rate") return "flat-rate";
  return formatMeasured(result.readings);
}

// load the base registry and, when no explicit LANES_REGISTRY
// override is set, the lanes.local.json overlay — the same gating resolve.mjs
// loadRegistry() uses (LANES_REGISTRY replaces wholesale; no overlay on top).
// resolveBankTargets merges the two so an overlay-only quota bank is probed.
function readLaneRegistry(): { base: object; local: object | null } {
  let base: object = {};
  try { base = JSON.parse(readFileSync(LANES_PATH, "utf8")); } catch { base = {}; }
  if (process.env.LANES_REGISTRY || !existsSync(LOCAL_LANES_PATH)) return { base, local: null };
  try {
    return { base, local: JSON.parse(readFileSync(LOCAL_LANES_PATH, "utf8")) };
  } catch {
    return { base, local: null };
  }
}

const { base, local } = readLaneRegistry();
const targets = resolveBankTargets(base, local, BANK_IDS) as LaneQuotaTargets;
const bankCache = new Map<BankId, DisplayResult>();
let claudeSuffix: string | null = null;
for (const { lane, bank, quota } of targets.withBank) {
  let result = bankCache.get(bank);
  if (!result) {
    try {
      result = readBank(bank);
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unexpected reader failure";
      result = { kind: "unmeasurable", reason };
    }
    bankCache.set(bank, result);
  }
  // resolve the ACTIVE access path explicitly. A failed
  // selection (missing paths, out-of-range index) is a registry ERROR, not a
  // paths[0] fallback — the verdict goes unknown and the diagnostic lands on
  // stderr, keeping stdout the machine surface (<lane> <state> <detail>).
  const active = resolveActiveAccessPath(quota);
  if (!active.ok) {
    process.stderr.write(`bank-status: lane '${lane}': ${active.reason} — guard unknown\n`);
  }
  let line = `${lane} ${guardState(result, active, fundedMaxPctForBank(bank, process.env))} ${detail(result)}`;
  if (bank === "claude") {
    if (claudeSuffix === null) claudeSuffix = claudeProvenanceSuffix();
    line += claudeSuffix;
  }
  process.stdout.write(`${line}\n`);
}
