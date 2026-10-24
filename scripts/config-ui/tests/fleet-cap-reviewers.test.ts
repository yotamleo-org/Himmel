// Settings shows the fleet cap and each reviewer's model and effort. The cap is written to himmel.conf
// only, the model and effort to the critics.local.json overlay only; the committed critics.json is never opened for write.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { acquireLock } from "../lock";
// @ts-ignore plain browser ES module, no types
import { renderFleetCap, renderReviewGate, reviewGateDraft } from "../public/render.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const REAL_BASE = join(import.meta.dir, "../../cr/critics.json");
const TOKEN = "t".repeat(64);
const BASE = {
  panel: [
    { slug: "codex", model: "gpt-6.1-sol", provider: "openai-codex", tier: "paid", mode: "hard", required: true },
    { slug: "claude", model: "claude-opus-5-5", provider: "claude-api", tier: "paid", effort: "medium", mode: "hard", required: false },
    { slug: "coderabbit", provider: "github-app", mode: "best-effort" },
  ],
};
let dir = "";
let base = "";
let local = "";
let envFile = "";
let conf = "";
let stop: (() => void) | null = null;
const sha = (p: string) => createHash("sha256").update(readFileSync(p)).digest("hex");
const realBaseSha = sha(REAL_BASE);

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "fleet-cap-"));
  mkdirSync(join(dir, "home"));
  mkdirSync(join(dir, "station"));
  base = join(dir, "critics.json");
  local = join(dir, "critics.local.json");
  envFile = join(dir, "station", ".env");
  mkdirSync(join(dir, "home", ".himmel"));
  conf = join(dir, "home", ".himmel", "himmel.conf");
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
    env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HIMMELCTL_REPO_ROOT: join(dir, "station"), CRITICS_BASE_JSON: base, CRITICS_LOCAL_JSON: local, ...overrides },
  });
  stop = () => s.stop();
  return s.port;
}
const url = (port: number, p: string) => `http://127.0.0.1:${port}${p}`;
const get = (port: number, p: string) => fetch(url(port, p), { headers: { "X-Himmel-Token": TOKEN } });
const post = (port: number, p: string, body: unknown) => fetch(url(port, p), {
  method: "POST",
  headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: `http://127.0.0.1:${port}` },
  body: JSON.stringify(body),
});
const row = (slug: string, o: Record<string, unknown> = {}) => ({ slug, mode: slug === "coderabbit" ? "best-effort" : "hard", required: slug === "codex", enabled: true, ...o });

test("GET /api/fleet-cap shows 4 as the default when nothing sets it", async () => {
  const j = await (await get(boot(), "/api/fleet-cap")).json();
  expect(j).toMatchObject({ cap: 4, default: 4, source: "default", min: 1, max: 50 });
});

test("a cap written round-trips, lands in himmel.conf only, and keeps the other lines", async () => {
  writeFileSync(conf, "# keep\nHANDOVER_DIR=/x\n");
  writeFileSync(envFile, "JIRA_PROJECT_KEY=HIMMEL\n");
  const port = boot();
  const r = await post(port, "/api/fleet-cap", { cap: 6 });
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ cap: 6, source: "himmel.conf", file: conf });
  expect(readFileSync(conf, "utf8")).toBe("# keep\nHANDOVER_DIR=/x\nHIMMEL_FLEET_CAP=6\n");
  expect(readFileSync(envFile, "utf8")).toBe("JIRA_PROJECT_KEY=HIMMEL\n");
  expect(await (await get(port, "/api/fleet-cap")).json()).toMatchObject({ cap: 6, source: "himmel.conf" });
});

test("writing the cap again replaces the line instead of adding a second one", async () => {
  writeFileSync(conf, "HIMMEL_FLEET_CAP=3\nOTHER=1\n");
  const port = boot();
  expect((await post(port, "/api/fleet-cap", { cap: 8 })).status).toBe(200);
  expect(readFileSync(conf, "utf8")).toBe("HIMMEL_FLEET_CAP=8\nOTHER=1\n");
});

test("a new himmel.conf is created owner-only", async () => {
  expect((await post(boot(), "/api/fleet-cap", { cap: 5 })).status).toBe(200);
  expect(statSync(conf).mode & 0o777).toBe(0o600);
});

test("a symlink planted at the temporary name is replaced, never written through", async () => {
  const victim = join(dir, "victim.txt");
  writeFileSync(victim, "untouched\n");
  writeFileSync(conf, "OTHER=1\n");
  symlinkSync(victim, `${conf}.tmp-${process.pid}`);
  expect((await post(boot(), "/api/fleet-cap", { cap: 5 })).status).toBe(200);
  expect(readFileSync(victim, "utf8")).toBe("untouched\n");
  expect(readFileSync(conf, "utf8")).toBe("OTHER=1\nHIMMEL_FLEET_CAP=5\n");
});

test("a himmel.conf that is a symlink (a luna install) is written through and stays a link", async () => {
  const real = join(dir, "vault-himmel.conf");
  writeFileSync(real, "OTHER=1\n");
  symlinkSync(real, conf);
  expect((await post(boot(), "/api/fleet-cap", { cap: 7 })).status).toBe(200);
  expect(lstatSync(conf).isSymbolicLink()).toBe(true);
  expect(readFileSync(real, "utf8")).toBe("OTHER=1\nHIMMEL_FLEET_CAP=7\n");
});

test("the cap is read from himmel.conf, with himmel.conf.local over it and the legacy .env under it", async () => {
  writeFileSync(envFile, "HIMMEL_FLEET_CAP=2\n");
  const port = boot();
  expect(await (await get(port, "/api/fleet-cap")).json()).toMatchObject({ cap: 2, source: ".env" });
  writeFileSync(conf, "HIMMEL_FLEET_CAP=11\n");
  expect(await (await get(port, "/api/fleet-cap")).json()).toMatchObject({ cap: 11, source: "himmel.conf", fileValue: 11 });
  writeFileSync(`${conf}.local`, "HIMMEL_FLEET_CAP=13\n");
  expect(await (await get(port, "/api/fleet-cap")).json()).toMatchObject({ cap: 13, source: "himmel.conf.local" });
});

test("a write lands in himmel.conf.local when that file sets the cap, so the saved value takes effect", async () => {
  writeFileSync(`${conf}.local`, "HIMMEL_FLEET_CAP=13\n");
  writeFileSync(conf, "HIMMEL_FLEET_CAP=11\n");
  const port = boot();
  expect(await (await post(port, "/api/fleet-cap", { cap: 9 })).json()).toMatchObject({ cap: 9, source: "himmel.conf.local" });
  expect(readFileSync(`${conf}.local`, "utf8")).toBe("HIMMEL_FLEET_CAP=9\n");
  expect(readFileSync(conf, "utf8")).toBe("HIMMEL_FLEET_CAP=11\n");
});

test("a symlink planted at the overlay's temporary name is replaced, never written through", async () => {
  const victim = join(dir, "victim.txt");
  writeFileSync(victim, "untouched\n");
  symlinkSync(victim, `${local}.tmp-${process.pid}`);
  expect((await post(boot(), "/api/review-gate", { reviewers: [row("codex", { model: "gpt-6.2-test" })] })).status).toBe(200);
  expect(readFileSync(victim, "utf8")).toBe("untouched\n");
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([{ slug: "codex", model: "gpt-6.2-test" }]);
});

test("a cap the launching shell sets wins over .env and is reported as such", async () => {
  writeFileSync(envFile, "HIMMEL_FLEET_CAP=3\n");
  const j = await (await get(boot({ HIMMEL_FLEET_CAP: "9" }), "/api/fleet-cap")).json();
  expect(j).toMatchObject({ cap: 9, source: "env", fileValue: 3 });
});

test("a shell value the preflight would use is shown as the effective cap, even past the UI's own range", async () => {
  writeFileSync(envFile, "HIMMEL_FLEET_CAP=3\n");
  expect(await (await get(boot({ HIMMEL_FLEET_CAP: "51" }), "/api/fleet-cap")).json()).toMatchObject({ cap: 51, source: "env", fileValue: 3 });
});

test("a non-numeric shell value is shown as the 4 the preflight falls back to, not the .env value", async () => {
  writeFileSync(envFile, "HIMMEL_FLEET_CAP=3\n");
  expect(await (await get(boot({ HIMMEL_FLEET_CAP: "many" }), "/api/fleet-cap")).json()).toMatchObject({ cap: 4, source: "env", fileValue: 3 });
});

test("a cap write waits out the station write lock instead of racing another config writer", async () => {
  writeFileSync(conf, "OTHER=1\n");
  const port = boot();
  const held = acquireLock(join(dir, "home", ".himmel", "state", "config-ui", "write.lock"));
  expect("busy" in held).toBe(false);
  const r = await post(port, "/api/fleet-cap", { cap: 6 });
  expect(r.status).toBe(409);
  expect(readFileSync(conf, "utf8")).toBe("OTHER=1\n");
  (held as { release(): void }).release();
  expect((await post(port, "/api/fleet-cap", { cap: 6 })).status).toBe(200);
});

test("an invalid cap is refused with a plain message and himmel.conf is untouched", async () => {
  writeFileSync(conf, "OTHER=1\n");
  const port = boot();
  for (const cap of [0, -1, 51, 2.5, "abc", "4; rm -rf /", "", null, true, [4]]) {
    const r = await post(port, "/api/fleet-cap", { cap });
    expect(r.status, JSON.stringify(cap)).toBe(400);
    expect((await r.json()).error).toMatch(/whole number from 1 to 50/);
  }
  expect(readFileSync(conf, "utf8")).toBe("OTHER=1\n");
});

test("the cap route needs the token and a same-origin json body", async () => {
  const port = boot();
  expect((await fetch(url(port, "/api/fleet-cap"))).status).toBe(401);
  const r = await fetch(url(port, "/api/fleet-cap"), { method: "POST", headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: "http://evil.example" }, body: '{"cap":5}' });
  expect(r.status).toBe(403);
});

test("GET /api/review-gate gives each dispatched reviewer its model, the Claude critic its effort, and a github-app reviewer neither", async () => {
  const j = await (await get(boot(), "/api/review-gate")).json();
  const by = Object.fromEntries(j.reviewers.map((x: { slug: string }) => [x.slug, x]));
  expect(by.codex).toMatchObject({ model: "gpt-6.1-sol", effort: "", hasModel: true, hasEffort: false });
  expect(by.claude).toMatchObject({ model: "claude-opus-5-5", effort: "medium", hasModel: true, hasEffort: true });
  expect(by.coderabbit).toMatchObject({ hasModel: false, hasEffort: false });
  expect(j.efforts).toEqual(["low", "medium", "high", "xhigh", "max"]);
});

test("a model and effort written round-trip through the overlay and leave the base file alone", async () => {
  const before = sha(base);
  const port = boot();
  const r = await post(port, "/api/review-gate", { reviewers: [row("codex", { model: "gpt-6.2-test" }), row("claude", { effort: "high" })] });
  expect(r.status).toBe(200);
  const j = await (await get(port, "/api/review-gate")).json();
  expect(j.reviewers.find((x: { slug: string }) => x.slug === "codex")).toMatchObject({ model: "gpt-6.2-test" });
  expect(j.reviewers.find((x: { slug: string }) => x.slug === "claude")).toMatchObject({ effort: "high" });
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([{ slug: "codex", model: "gpt-6.2-test" }, { slug: "claude", effort: "high" }]);
  expect(sha(base)).toBe(before);
});

test("a model or effort put back to the base value (or cleared) leaves nothing behind in the overlay", async () => {
  const port = boot();
  await post(port, "/api/review-gate", { reviewers: [row("claude", { model: "claude-sonnet-5-5", effort: "max" })] });
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([{ slug: "claude", model: "claude-sonnet-5-5", effort: "max" }]);
  await post(port, "/api/review-gate", { reviewers: [row("claude", { model: "claude-opus-5-5", effort: "medium" })] });
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([]);
  await post(port, "/api/review-gate", { reviewers: [row("claude", { effort: "low" })] });
  await post(port, "/api/review-gate", { reviewers: [row("claude", { effort: "" })] });
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([]);
});

test("a save that names no model or effort leaves the overlay's model and effort as they were", async () => {
  const port = boot();
  await post(port, "/api/review-gate", { reviewers: [row("claude", { effort: "high" })] });
  expect((await post(port, "/api/review-gate", { reviewers: [row("claude", { mode: "hard" })] })).status).toBe(200);
  expect(JSON.parse(readFileSync(local, "utf8")).panel).toEqual([{ slug: "claude", effort: "high" }]);
});

test("an invalid effort or model is refused, and a github-app reviewer takes neither", async () => {
  const port = boot();
  const bad = [
    row("claude", { effort: "extreme" }),
    row("claude", { effort: 3 }),
    row("codex", { effort: "high" }), // nothing reads an effort for the codex reviewer yet
    row("codex", { model: "bad model; rm" }),
    row("codex", { model: "--flag" }),
    row("codex", { model: 7 }),
    row("coderabbit", { model: "gpt-6.1-sol" }),
    row("coderabbit", { effort: "high" }),
  ];
  for (const b of bad) {
    const r = await post(port, "/api/review-gate", { reviewers: [b] });
    expect(r.status, JSON.stringify(b)).toBe(400);
    expect(typeof (await r.json()).error).toBe("string");
  }
  expect(() => readFileSync(local, "utf8")).toThrow();
});

const gate = {
  review: null, overlay: "/x/critics.local.json", dropped: [], rateLimit: "x", efforts: ["low", "medium", "high", "xhigh", "max"],
  reviewers: [
    { slug: "codex", order: 1, provider: "openai-codex", mode: "hard", required: true, enabled: true, hasModel: true, hasEffort: false, model: "gpt-6.1-sol", effort: "", recommended: { mode: "hard", required: true, enabled: true } },
    { slug: "claude", order: 2, provider: "claude-api", mode: "hard", required: false, enabled: true, hasModel: true, hasEffort: true, model: "claude-opus-5-5", effort: "medium", recommended: { mode: "hard", required: false, enabled: true } },
    { slug: "coderabbit", order: 3, provider: "github-app", mode: "best-effort", required: false, enabled: true, hasModel: false, hasEffort: false, model: "", effort: "", recommended: { mode: "best-effort", required: false, enabled: true } },
  ],
  env: [],
};

test("the review gate card has a model box for a dispatched reviewer, an effort choice for the Claude critic only, and neither for a github-app one", () => {
  const html: string = renderReviewGate({ data: gate, error: null, draft: null, msg: null });
  expect(html).toContain('data-rg="model" data-slug="codex"');
  expect(html).toContain('value="gpt-6.1-sol"');
  expect(html).not.toContain('data-rg="effort" data-slug="codex"');
  expect(html).toContain('data-rg="effort" data-slug="claude"');
  for (const e of gate.efforts) expect(html).toContain(`<option value="${e}"`);
  expect(html).not.toContain('data-rg="model" data-slug="coderabbit"');
  expect(html).not.toContain('data-rg="effort" data-slug="coderabbit"');
});

test("the draft carries a model for a dispatched reviewer, an effort for the Claude critic, and neither for a github-app one", () => {
  const d = reviewGateDraft(gate);
  expect(d[0]).toEqual({ slug: "codex", mode: "hard", required: true, enabled: true, model: "gpt-6.1-sol" });
  expect(d[1]).toEqual({ slug: "claude", mode: "hard", required: false, enabled: true, model: "claude-opus-5-5", effort: "medium" });
  expect(d[2]).toEqual({ slug: "coderabbit", mode: "best-effort", required: false, enabled: true });
});

test("the fleet cap card shows the cap, its default and where it is set, with a save button", () => {
  const html: string = renderFleetCap({ data: { cap: 6, default: 4, min: 1, max: 50, source: "himmel.conf", fileValue: 6, file: "/x/himmel.conf" }, error: null, draft: 6, msg: null });
  expect(html).toContain('<section id="fleet-cap"');
  expect(html).toContain('data-fc="cap"');
  expect(html).toContain('value="6"');
  expect(html).toMatch(/default[^<]*4/);
  expect(html).toContain("/x/himmel.conf");
  expect(html).toContain('data-act="fleet-cap-save"');
});

test("the fleet cap card says when the launching shell overrides the saved cap, and shows the loading and error states", () => {
  const html: string = renderFleetCap({ data: { cap: 9, default: 4, min: 1, max: 50, source: "env", fileValue: 3, file: "/x/himmel.conf" }, error: null, draft: 9, msg: null });
  expect(html).toContain("saved in himmel.conf: 3");
  expect(html).toMatch(/launching shell/);
  expect(html).toContain("until the UI restarts without it");
  expect(html).not.toContain("until that shell restarts");
  expect(renderFleetCap(null)).toContain("loading");
  expect(renderFleetCap({ data: null, error: "boom" })).toContain("boom");
});
