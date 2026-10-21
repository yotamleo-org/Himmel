// GET/POST /api/review-gate and the Review gate card — Configure shows how the review gate runs and edits only the
// critics.local.json overlay. Every test points the base and the overlay at a temp dir.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-ignore plain browser ES module, no types
import { renderReviewGate, reviewGateDraft } from "../public/render.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const REAL_BASE = join(import.meta.dir, "../../cr/critics.json");
const TOKEN = "t".repeat(64);
const BASE = {
  panel: [
    { slug: "codex", model: "gpt-6.1-sol", provider: "openai-codex", tier: "paid", mode: "hard", required: true },
    { slug: "claude", model: "claude-opus-5-5", provider: "claude-api", tier: "paid", mode: "hard", required: false },
    { slug: "coderabbit", provider: "github-app", mode: "best-effort" },
  ],
};
let dir = "";
let base = "";
let local = "";
let stop: (() => void) | null = null;
const sha = (p: string) => createHash("sha256").update(readFileSync(p)).digest("hex");
const realBaseSha = sha(REAL_BASE);

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "review-gate-"));
  mkdirSync(join(dir, "home"));
  base = join(dir, "critics.json");
  local = join(dir, "critics.local.json");
  writeFileSync(base, JSON.stringify(BASE, null, 2) + "\n");
});
afterEach(() => {
  stop?.(); stop = null;
  rmSync(dir, { recursive: true, force: true });
  expect(sha(REAL_BASE)).toBe(realBaseSha); // the committed base is read only, whatever a test did
});

function boot(overrides: Record<string, string> = {}) {
  const s = startServer({
    port: 0, token: TOKEN,
    env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", CRITICS_BASE_JSON: base, CRITICS_LOCAL_JSON: local, ...overrides },
  });
  stop = () => s.stop();
  return s.port;
}
const get = (port: number) => fetch(`http://127.0.0.1:${port}/api/review-gate`, { headers: { "X-Himmel-Token": TOKEN } });
const post = (port: number, body: unknown) => fetch(`http://127.0.0.1:${port}/api/review-gate`, {
  method: "POST",
  headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: `http://127.0.0.1:${port}` },
  body: JSON.stringify(body),
});

test("GET lists the reviewers in order with mode and required, and states the ruled rate-limit behaviour", async () => {
  const r = await get(boot());
  expect(r.status).toBe(200);
  const j = await r.json();
  expect(j.reviewers.map((x: { slug: string }) => x.slug)).toEqual(["codex", "claude", "coderabbit"]);
  expect(j.reviewers.map((x: { order: number }) => x.order)).toEqual([1, 2, 3]);
  expect(j.reviewers[0]).toMatchObject({ slug: "codex", mode: "hard", required: true, enabled: true });
  expect(j.reviewers[2]).toMatchObject({ slug: "coderabbit", mode: "best-effort", required: false });
  expect(j.rateLimit).toMatch(/rate.limited/i);
  expect(j.rateLimit).toMatch(/note/i);
  expect(j.rateLimit).toMatch(/never wait/i);
  expect(j.rateLimit).toMatch(/best-effort/i);
  expect(j.rateLimit).toMatch(/hard holds the merge/i);
  expect(j.env.map((e: { name: string }) => e.name)).toEqual(["CR_PROFILE", "CR_REQUIRE_CROSS_MODEL", "CR_FLOOR_FALLBACK", "CRITIC_PANEL_TIERS", "CRITIC_TIMEOUT_SECS", "CRITIC_PARALLEL"]);
});

test("POST writes the overlay only, and a read back equals what was written", async () => {
  const before = sha(base);
  const port = boot();
  const sent = [{ slug: "coderabbit", mode: "hard", required: false, enabled: true }, { slug: "claude", mode: "best-effort", required: false, enabled: false }];
  const r = await post(port, { reviewers: sent });
  expect(r.status).toBe(200);
  const j = await (await get(port)).json();
  const bySlug = Object.fromEntries(j.reviewers.map((x: { slug: string }) => [x.slug, x]));
  expect(bySlug.coderabbit).toMatchObject({ mode: "hard", required: false, enabled: true });
  expect(j.reviewers.map((x: { slug: string }) => x.slug)).toEqual(["codex", "coderabbit"]); // claude dropped
  expect(j.dropped).toEqual(["claude"]);
  const overlay = JSON.parse(readFileSync(local, "utf8"));
  expect(overlay.panel).toContainEqual({ slug: "coderabbit", mode: "hard", required: false });
  expect(overlay.panel).toContainEqual({ slug: "claude", drop: true });
  expect(sha(base)).toBe(before);
});

test("a dropped reviewer keeps its shared settings, so turning it back on restores them", async () => {
  const port = boot();
  await post(port, { reviewers: [{ slug: "claude", mode: "best-effort", required: false, enabled: false }] });
  const j = await (await get(port)).json();
  expect(j.droppedBase.claude).toEqual({ mode: "hard", required: false });
  expect(reviewGateDraft(j)).toContainEqual({ slug: "claude", mode: "hard", required: false, enabled: false });
});

test("POST refuses to write when the overlay path is the base critics.json", async () => {
  const before = sha(base);
  const port = boot({ CRITICS_LOCAL_JSON: base });
  const r = await post(port, { reviewers: [{ slug: "codex", mode: "best-effort", required: true, enabled: true }] });
  expect(r.status).toBe(400);
  expect((await r.json()).error).toMatch(/critics\.local\.json/);
  expect(sha(base)).toBe(before);
});

test("POST refuses an invalid change and leaves the overlay untouched", async () => {
  const port = boot();
  const bad = [
    { reviewers: [{ slug: "codex", mode: "soft", required: true, enabled: true }] },
    { reviewers: [{ slug: "nope", mode: "hard", required: true, enabled: true }] },
    { reviewers: [{ slug: "codex", mode: "hard", required: true, enabled: false }] }, // a required row cannot be dropped
    { reviewers: [{ slug: "codex", mode: "best-effort", required: false, enabled: true }, { slug: "coderabbit", mode: "best-effort", required: false, enabled: true }, { slug: "claude", mode: "best-effort", required: false, enabled: true }] }, // no hard reviewer left
    { reviewers: "codex" },
  ];
  for (const b of bad) {
    const r = await post(port, b);
    expect(r.status, JSON.stringify(b)).toBe(400);
  }
  expect(() => readFileSync(local, "utf8")).toThrow();
});

test("the routes need the token and, for a write, a same-origin json body", async () => {
  const port = boot();
  expect((await fetch(`http://127.0.0.1:${port}/api/review-gate`)).status).toBe(401);
  const r = await fetch(`http://127.0.0.1:${port}/api/review-gate`, { method: "POST", headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: "http://evil.example" }, body: "{}" });
  expect(r.status).toBe(403);
});

const data = {
  review: null, overlay: "/x/critics.local.json", dropped: [],
  rateLimit: "CodeRabbit rate limited or absent is a note and continue; the gate never waits for it.",
  reviewers: [
    { slug: "codex", order: 1, provider: "openai-codex", mode: "hard", required: true, enabled: true, recommended: { mode: "hard", required: true, enabled: true } },
    { slug: "coderabbit", order: 2, provider: "github-app", mode: "best-effort", required: false, enabled: true, recommended: { mode: "best-effort", required: false, enabled: true } },
  ],
  env: [{ name: "CRITIC_TIMEOUT_SECS", value: null, default: "240", means: "how long one reviewer may run, in seconds" }],
};

test("the card names each reviewer, its order, required or optional, and the rate-limit line", () => {
  const html: string = renderReviewGate({ data, error: null, draft: null, msg: null });
  expect(html).toContain('<section id="review-gate"');
  expect(html.indexOf("codex")).toBeLessThan(html.indexOf("coderabbit"));
  expect(html).toMatch(/required/);
  expect(html).toMatch(/optional/);
  expect(html).toMatch(/note and continue/);
  expect(html).toMatch(/never waits/);
  expect(html).toContain("recommended");
  expect(html).toContain("CRITIC_TIMEOUT_SECS");
  expect(html).toContain('data-act="review-gate-save"');
});

test("the card shows the loading and error states", () => {
  expect(renderReviewGate(null)).toContain("loading");
  expect(renderReviewGate({ data: null, error: "boom" })).toContain("boom");
});
