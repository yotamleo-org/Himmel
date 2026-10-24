// GET /api/reviewers — the review page (scripts/eval/review-page.py, written weekly by judge-accuracy-cadence.sh) as served text, read-only; and the Health page's Reviewers section.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { renderHealth } from "../public/health.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const PAGE = `# How good are our reviewers?

Each number comes from the newest run.

## The judges

Verdicts written from 1 Oct 2026 to 24 Oct 2026. Ranges are 95 % ranges.

- A bug got past a GO on 2 of 100 merged PRs: 2 % (likely between 1 % and 7 %).

## What we changed, and whether it helped

No change yet.
`;

function boot(page?: string) {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const file = join(dir, "review-page.md");
  if (page !== undefined) writeFileSync(file, page);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, REVIEW_PAGE_FILE: file } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}/api/reviewers`, { headers, method });

test("reviewers: the stored page is served as text with the day it was written", async () => {
  const s = boot(PAGE);
  const r = await (await get(s.port)).json();
  expect(r.state).toBe("ok");
  expect(r.text).toBe(PAGE);
  expect(typeof r.writtenAt).toBe("string");
});

test("reviewers: an absent file is state absent; the route is token-gated and read-only", async () => {
  const s = boot();
  expect(await (await get(s.port)).json()).toMatchObject({ state: "absent" });
  expect((await get(s.port, {})).status).toBe(401);
  expect((await get(s.port, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
});

test("Health page: the Reviewers section shows headings, the bullets and the numbers as written", async () => {
  const s = boot(PAGE);
  const reviewers = await (await get(s.port)).json();
  const html = renderHealth(null, { bank: { state: "absent" }, legs: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, reviewers });
  expect(html).toContain('id="reviewers"');
  expect(html).toContain("<h4>The judges</h4>");
  expect(html).toContain("<li>A bug got past a GO on 2 of 100 merged PRs: 2 % (likely between 1 % and 7 %).</li>");
});

test("Health page: no page shows 'no data yet'; the page text is escaped", () => {
  expect(renderHealth(null, null)).toContain("No data: no review page yet");
  const evil = `<img src=x onerror=alert(1)>`;
  const html = renderHealth(null, { bank: { state: "absent" }, legs: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, reviewers: { state: "ok", text: `## ${evil}\n\n- ${evil}\n`, writtenAt: "2026-10-24T00:00:00Z" } });
  expect(html).not.toContain("<img");
});
