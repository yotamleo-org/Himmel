// The Setup page's CodeRabbit step: what it is, that it is an optional add-on, how to install the GitHub App, a
// real installed check (a stub `gh` on PATH), and an example value on every secret the page can set.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import * as store from "../../himmelctl/lib/secret-store.js";
// @ts-ignore plain browser ES module, no types
import { renderSetup } from "../public/setup.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

// gh: "ok:<n>" answers n CodeRabbit checks on the recent PRs, "fail" exits 1, "none" is no gh on PATH at all.
function boot(gh: string) {
  const dir = mkdtempSync(join(tmpdir(), "setup-cr-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project"), bin = join(dir, "bin");
  for (const d of [home, root, project, bin]) mkdirSync(d);
  if (gh !== "none") {
    writeFileSync(join(bin, "gh"), gh === "fail" ? "#!/bin/sh\nexit 1\n" : `#!/bin/sh\necho ${gh.split(":")[1]}\n`);
    chmodSync(join(bin, "gh"), 0o755);
  }
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project,
    env: { PATH: gh === "none" ? bin : `${bin}:/usr/bin:/bin`, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return async () => (await fetch(`http://127.0.0.1:${s.port}/api/setup`, { headers: { "x-himmel-token": TOKEN } })).json() as Promise<any>;
}

test("the step is an optional add-on, says what it is and how to install the App", async () => {
  const cr = (await boot("ok:3")()).coderabbit;
  expect(cr.requirement).toBe("optional");
  expect(cr.what).toMatch(/review/i);
  expect(cr.steps.join("\n")).toContain("https://github.com/apps/coderabbitai");
  expect(cr.steps.join("\n")).toContain("git config --local himmel.coderabbit true");
});

test("installed: CodeRabbit shows on a recent PR", async () => {
  expect((await boot("ok:3")()).coderabbit.installed).toBe("installed");
});

test("not-installed: no CodeRabbit check on any recent PR", async () => {
  expect((await boot("ok:0")()).coderabbit.installed).toBe("not-installed");
});

test("unknown: gh fails or is missing, so the page asks for a manual confirm", async () => {
  for (const gh of ["fail", "none"]) {
    const cr = (await boot(gh)()).coderabbit;
    expect([gh, cr.installed]).toEqual([gh, "unknown"]);
    expect(cr.manual).toMatch(/confirm/i);
  }
});

test("every secret the page can set carries an example that passes its own rule", async () => {
  const secrets = (await boot("ok:0")()).secrets.filter((s: any) => s.collect === "file");
  expect(secrets.length).toBeGreaterThan(0);
  for (const s of secrets) {
    expect([s.name, typeof s.example, s.example.length > 0]).toEqual([s.name, "string", true]);
  }
  for (const n of ["JIRA_BASE_URL", "JIRA_EMAIL", "BITBUCKET_EMAIL", "JIRA_PROJECT_KEY"]) {
    const s = secrets.find((x: any) => x.name === n);
    expect([n, store.validate(n, s.example).ok]).toEqual([n, true]);
  }
});

test("the page renders the step with its label and an example under each secret form", async () => {
  const state = await boot("ok:0")();
  const html: string = renderSetup(state, {}, {});
  expect(html).toContain("CodeRabbit");
  expect(html).toMatch(/optional/i);
  expect(html).toContain("not installed");
  expect(html).toContain("https://github.com/apps/coderabbitai");
  expect(html).toContain("e.g. ");
  expect(html).toContain("you@example.com");
});
