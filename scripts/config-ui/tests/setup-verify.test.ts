// The Setup page's Verify step: the doctor runs inline (read-only, never --fix), the page shows a green/warn/fail summary
// with one fix link per finding, and no secret value reaches the answer, the audit file, the server's output or the page's storage.
import { test, expect, afterEach, spyOn } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-ignore plain browser ES module, no types
import { renderSetup } from "../public/setup.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const DOCTOR = join(import.meta.dir, "stub-doctor.sh");
const TOKEN = "t".repeat(64);
const SECRET = "dummy-secret-Zq9x7Lm2Pw4Rt8Vb"; // gitleaks:allow a planted dummy, not a credential
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(extra: Record<string, string> = {}, opts: { verifyTimeoutMs?: number } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "setup-verify-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project]) mkdirSync(d);
  writeFileSync(join(root, ".env"), `JIRA_API_TOKEN=${SECRET}\n`);
  const argvFile = join(dir, "argv");
  writeFileSync(argvFile, "");
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project, ...opts,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HIMMEL_REPORT_DOCTOR: DOCTOR, STUB_ARGV: argvFile, ...extra },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const verify = async (method = "POST", origin = base) => {
    const r = await fetch(`${base}/api/setup/verify`, { method, headers: { "content-type": "application/json", origin, "x-himmel-token": TOKEN }, ...(method === "POST" ? { body: "{}" } : {}) });
    return { status: r.status, text: await r.text() };
  };
  return { verify, home, argvFile };
}

const setupFixture = { account: null, secrets: [], commit: { tracker: null, ticketIdRequired: null }, choices: null, coderabbit: null };
const verifyFixture = {
  state: "done", ok: 2, info: 1, warn: 1, fail: 1,
  findings: [
    { sev: "FAIL", id: "C5", msg: "qmd index is missing", remedy: "run qmd update" },
    { sev: "WARN", id: "C4", msg: "token expires soon", remedy: "rotate it" },
  ],
};

test("the page has a Verify step with a button that runs the doctor", () => {
  const html = renderSetup(setupFixture, {}, {}, null);
  expect(html).toContain("<h3>Verify</h3>");
  expect(html).toContain('data-act="setup-verify"');
});

test("the page shows a running state and an error state", () => {
  expect(renderSetup(setupFixture, {}, {}, { state: "running" })).toMatch(/running/i);
  expect(renderSetup(setupFixture, {}, {}, { state: "error", error: "the doctor timed out" })).toContain("the doctor timed out");
});

test("the summary counts ok, warn and fail, with one fix link and remedy per finding", () => {
  const html = renderSetup(setupFixture, {}, {}, verifyFixture);
  expect(html).toContain("1 fail");
  expect(html).toContain("1 warn");
  expect(html).toContain("2 ok");
  for (const id of ["C5", "C4"]) {
    expect(html.split(`data-act="open-config" data-id="doctor:${id}"`).length - 1).toBe(1);
  }
  expect(html).toContain("run qmd update");
});

test("an all-green run says so and lists no finding", () => {
  const html = renderSetup(setupFixture, {}, {}, { state: "done", ok: 4, info: 0, warn: 0, fail: 0, findings: [] });
  expect(html).toMatch(/0 fail/);
  expect(html).not.toContain('data-act="open-config"');
});

test("a finding's text is escaped", () => {
  const html = renderSetup(setupFixture, {}, {}, { ...verifyFixture, findings: [{ sev: "WARN", id: "C9", msg: "<img src=x onerror=1>", remedy: "<b>x</b>" }] });
  expect(html).not.toContain("<img src=x");
  expect(html).not.toContain("<b>x</b>");
});

test("POST /api/setup/verify runs the doctor read-only and answers a summary and the non-ok findings", async () => {
  const { verify, argvFile } = boot();
  const r = await verify();
  expect(r.status).toBe(200);
  const j = JSON.parse(r.text);
  expect([j.state, j.ok, j.info, j.warn, j.fail]).toEqual(["done", 2, 1, 1, 1]);
  expect(j.findings.map((f: any) => [f.sev, f.id])).toEqual([["FAIL", "C5"], ["WARN", "C4"]]);
  expect(j.findings[0]).toEqual({ sev: "FAIL", id: "C5", msg: "qmd index is missing", remedy: "run qmd update" });
  // exactly the read-only flags, never --fix or --file-issue
  expect(readFileSync(argvFile, "utf8").trim().split("\n")).toEqual(["--json --no-color"]);
});

test("the doctor publishes no state: its state dir is a throwaway that is removed after the run", async () => {
  const { verify, argvFile } = boot();
  await verify();
  const dirs = readFileSync(`${argvFile}.state`, "utf8").trim().split("\n");
  expect(dirs).toHaveLength(1);
  expect(dirs[0]).not.toBe("");
  expect(dirs[0]).not.toContain(".himmel");
  expect(existsSync(dirs[0])).toBe(false);
});

test("a planted secret reaches neither the answer, the audit file, the server's output nor a stderr echo", async () => {
  const spies = [spyOn(console, "log"), spyOn(console, "error"), spyOn(process.stderr, "write"), spyOn(process.stdout, "write")];
  const { verify, home } = boot({ STUB_LEAK: SECRET });
  const r = await verify();
  const seen = spies.map((s) => JSON.stringify(s.mock.calls)).join("\n");
  spies.forEach((s) => s.mockRestore());
  expect(r.status).toBe(200);
  expect(r.text).not.toContain(SECRET);
  expect(r.text).toContain("expires soon"); // the row itself survives, only the value is redacted
  expect(seen).not.toContain(SECRET);
  const state = join(home, ".himmel", "state", "config-ui");
  for (const f of existsSync(state) ? readdirSync(state) : []) expect(readFileSync(join(state, f), "utf8")).not.toContain(SECRET);
});

test("a doctor that outlives the timeout answers a timeout, not a report", async () => {
  const { verify } = boot({ STUB_SLEEP: "5" }, { verifyTimeoutMs: 300 });
  const r = await verify();
  const j = JSON.parse(r.text);
  expect(r.status).toBe(200);
  expect(j.state).toBe("timeout");
  expect(j.error).toMatch(/did not finish/);
  expect(j.findings).toBeUndefined();
});

test("a doctor that dies after some rows is an error, never a green summary", async () => {
  const j = JSON.parse((await boot({ STUB_CRASH: "1" }).verify()).text);
  expect(j.state).toBe("error");
  expect(j.error).toMatch(/did not finish its report/);
  expect(j.ok).toBeUndefined();
});

test("an exit code that contradicts the rows is an error", async () => {
  // a FAIL row with exit 0, and exit 3 (the doctor only ever exits 0 or 1)
  for (const rc of ["0", "3"]) {
    const j = JSON.parse((await boot({ STUB_RC: rc }).verify()).text);
    expect([rc, j.state]).toEqual([rc, "error"]);
  }
});

test("only a same-origin POST runs it", async () => {
  const { verify } = boot();
  expect((await verify("GET")).status).toBe(405);
  expect((await verify("POST", "http://evil.example")).status).toBe(403);
});

test("the page keeps nothing in browser storage", () => {
  for (const f of ["setup.js", "app.js"]) {
    const src = readFileSync(join(import.meta.dir, "..", "public", f), "utf8");
    expect([f, /\b(localStorage|sessionStorage|indexedDB|document\.cookie)\b/.test(src.replace(/\/\/.*$/gm, ""))]).toEqual([f, false]);
  }
});
