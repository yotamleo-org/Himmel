// GET /api/bank — Claude and Codex bank windows from the caches bank-preflight reads.
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { renderHealth } from "../public/health.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const NOW = Date.parse("2026-10-13T12:00:00Z");
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(files: { claude?: unknown; codex?: unknown } = {}, usageNames = false) {
  const dir = mkdtempSync(join(tmpdir(), "bank-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const claude = join(dir, "claude.json"), codex = join(dir, "codex.json");
  if (files.claude !== undefined) writeFileSync(claude, JSON.stringify(files.claude));
  if (files.codex !== undefined) writeFileSync(codex, JSON.stringify(files.codex));
  const s = startServer({
    port: 0, token: TOKEN, now: () => NOW,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root,
      CLAUDE_USAGE_CACHE: claude, CODEX_BANK_CACHE: codex,
      ...(usageNames ? { CODEX_USAGE_CACHE: codex, CODEX_BANK_CACHE: join(dir, "absent.json"),
        CODEX_USAGE_CACHE_TTL_SECONDS: "60", CODEX_BANK_CACHE_TTL_SECONDS: "999999",
        CADENCE_USAGE_CACHE: claude, CADENCE_BANK_CACHE: join(dir, "absent.json"),
        CADENCE_USAGE_MAX_AGE: "60", CADENCE_BANK_MAX_AGE: "999999" } : {}) },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = async (port: number) => (await fetch(`http://127.0.0.1:${port}/api/bank`, { headers: { "X-Himmel-Token": TOKEN } })).json();
const epoch = (iso: string) => Math.floor(Date.parse(iso) / 1000);
const claudeCache = (derivedAt: string, extra: Record<string, unknown> = {}) => ({
  five_hour: { utilization: 9, resets_at: "2026-10-13T15:00:00+00:00" },
  seven_day: { utilization: 74, resets_at: "2026-10-17T09:00:00+00:00" },
  derived_at: epoch(derivedAt), ...extra,
});
const codexCache = (capturedAt: string, limits: unknown[]) => ({ capturedAt, limits, planType: "prolite" });
const weekly = (usedPercent: number, resetsAt: number) => ({ limitId: "codex", usedPercent, windowDurationMins: 10080, resetsAt });

test("fresh caches: used_pct, resets_at, captured_at, age_s and state ok per bank and window", async () => {
  const s = boot({
    claude: claudeCache("2026-10-13T11:58:00Z"),
    codex: codexCache("2026-10-13T10:00:00Z", [weekly(12, epoch("2026-10-18T00:00:00Z"))]),
  });
  const b = await get(s.port);
  expect(b.claude.five_hour).toMatchObject({ used_pct: 9, state: "ok", age_s: 120, possibly_reset: false });
  expect(b.claude.five_hour.resets_at).toBe("2026-10-13T15:00:00.000Z");
  expect(b.claude.seven_day).toMatchObject({ used_pct: 74, state: "ok" });
  expect(b.codex.weekly).toMatchObject({ used_pct: 12, state: "ok", age_s: 7200 });
  expect(b.codex.weekly.captured_at).toBe("2026-10-13T10:00:00.000Z");
});

test("CODEX_USAGE_CACHE and CODEX_USAGE_CACHE_TTL_SECONDS win over the old CODEX_BANK_* names", async () => {
  const s = boot({ codex: codexCache("2026-10-13T10:00:00Z", [weekly(12, epoch("2026-10-18T00:00:00Z"))]) }, true);
  expect((await get(s.port)).codex.weekly).toMatchObject({ used_pct: 12, state: "stale", age_s: 7200 });
});

test("CADENCE_USAGE_CACHE and CADENCE_USAGE_MAX_AGE win over the old CADENCE_BANK_* names", async () => {
  const s = boot({ claude: claudeCache("2026-10-13T11:58:00Z") }, true);
  expect((await get(s.port)).claude.five_hour).toMatchObject({ used_pct: 9, state: "stale", age_s: 120 });
});

test("stale: Claude over 600 s and Codex over 6 h keep their numbers but say stale", async () => {
  const s = boot({
    claude: claudeCache("2026-10-13T11:49:00Z"),
    codex: codexCache("2026-10-13T05:00:00Z", [weekly(12, epoch("2026-10-18T00:00:00Z"))]),
  });
  const b = await get(s.port);
  expect(b.claude.five_hour).toMatchObject({ state: "stale", used_pct: 9, age_s: 660 });
  expect(b.codex.weekly).toMatchObject({ state: "stale", used_pct: 12, age_s: 25200 });
});

test("missing files: unknown with a reason and null numbers, never 0", async () => {
  const s = boot();
  const b = await get(s.port);
  expect(b.claude.five_hour).toMatchObject({ state: "unknown", used_pct: null, resets_at: null, captured_at: null, age_s: null });
  expect(b.claude.five_hour.reason).toMatch(/missing/);
  expect(b.codex.weekly).toMatchObject({ state: "unknown", used_pct: null });
  expect(b.codex.weekly.reason).toMatch(/missing/);
});

test("Codex 5h window the plan does not report: unknown, reason says not reported", async () => {
  const s = boot({ codex: codexCache("2026-10-13T11:00:00Z", [weekly(12, epoch("2026-10-18T00:00:00Z"))]) });
  const b = await get(s.port);
  expect(b.codex.five_hour).toMatchObject({ state: "unknown", used_pct: null });
  expect(b.codex.five_hour.reason).toMatch(/not reported/);
});

test("a resets_at already in the past flags possibly_reset and keeps the number", async () => {
  const s = boot({
    claude: claudeCache("2026-10-13T11:59:00Z", { five_hour: { utilization: 88, resets_at: "2026-10-13T11:00:00+00:00" } }),
    codex: codexCache("2026-10-13T11:00:00Z", [weekly(90, epoch("2026-10-13T11:30:00Z"))]),
  });
  const b = await get(s.port);
  expect(b.claude.five_hour).toMatchObject({ used_pct: 88, possibly_reset: true });
  expect(b.codex.weekly).toMatchObject({ used_pct: 90, possibly_reset: true });
});

test("an unparseable cache is unknown with a reason, not an error page", async () => {
  const s = boot({ claude: "not an object", codex: { limits: "x" } });
  const b = await get(s.port);
  expect(b.claude.five_hour.state).toBe("unknown");
  expect(b.codex.weekly.state).toBe("unknown");
});

test("the route needs the token and a UI request spawns no probe or producer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "bank-route-spawn-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const marker = join(dir, "spawned");
  const sh = join(dir, "probe.sh");
  writeFileSync(sh, `#!/bin/sh\ntouch ${marker}\n`, { mode: 0o755 });
  const home = join(dir, "home"); mkdirSync(home);
  const s = startServer({
    port: 0, token: TOKEN, now: () => NOW,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: dir,
      CLAUDE_USAGE_CACHE: join(dir, "none-c.json"), CODEX_BANK_CACHE: join(dir, "none-x.json"),
      CADENCE_BANK_PRODUCER: sh, CODEX_BANK_PROBE_CMD: sh, USAGE_FORCE_REFRESH: "1" },
  });
  cleanups.push(() => s.stop());
  expect((await fetch(`http://127.0.0.1:${s.port}/api/bank`)).status).toBe(401);
  expect((await get(s.port)).claude.five_hour.state).toBe("unknown");
  await Bun.sleep(300);
  expect(existsSync(marker)).toBe(false);
});

test("panel: unknown shows 'unknown (why)' and its age, never 0 %; possibly reset is flagged", () => {
  const unknown = { state: "unknown", used_pct: null, resets_at: null, captured_at: null, age_s: null, possibly_reset: false, reason: "usage cache missing" };
  const bank = {
    claude: { five_hour: unknown, seven_day: { ...unknown, state: "stale", used_pct: 74, age_s: 700, resets_at: "2026-10-13T11:00:00.000Z", possibly_reset: true, reason: null } },
    codex: { five_hour: { ...unknown, reason: "not reported by this plan" }, weekly: { ...unknown, state: "ok", used_pct: 12, age_s: 60, reason: null } },
  };
  const html = renderHealth(null, { bank: { state: "absent" }, legs: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, quota: bank });
  expect(html).toContain("unknown (usage cache missing)");
  expect(html).toContain("unknown (not reported by this plan)");
  expect(html).toContain("possibly reset");
  expect(html).toContain("74");
  expect(html).not.toMatch(/five_hour[^<]*\b0 ?%/);
});

test("a finite timestamp outside the Date range is unknown, not an endpoint error", async () => {
  const s = boot({ claude: claudeCache("2026-10-13T11:58:00Z", { five_hour: { utilization: 9, resets_at: 1e300 } }) });
  const res = await fetch(`http://127.0.0.1:${s.port}/api/bank`, { headers: { "X-Himmel-Token": TOKEN } });
  expect(res.status).toBe(200);
  const b = await res.json();
  expect(b.claude.five_hour).toMatchObject({ used_pct: 9, resets_at: null });
});

test("an unreported window keeps the cache capture time and age", async () => {
  const s = boot({ codex: codexCache("2026-10-13T11:00:00Z", [weekly(12, epoch("2026-10-18T00:00:00Z"))]) });
  const b = await get(s.port);
  expect(b.codex.five_hour).toMatchObject({ state: "unknown", used_pct: null, age_s: 3600, captured_at: "2026-10-13T11:00:00.000Z" });
});
