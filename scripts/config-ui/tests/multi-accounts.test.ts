// The Multi accounts section of Configure -> Secrets lists accounts A, B and C with the roles the role map
// (scripts/lib/api-roles.mjs) gives them, and an edit through the validated writer changes the map auto routing reads.
// Hermetic: HOME, HIMMEL_API_CREDIT_CONFIG and HIMMEL_API_CREDIT_SNAPSHOT point at a temp dir; no real ~/.himmel is read.
import { test, expect, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-ignore plain browser ES module, no types
import { renderConfigure } from "../public/setup.js";

const TOKEN = "t".repeat(64);
const ROLES_CLI = join(import.meta.dir, "../../lib/api-roles.mjs");
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "multi-accounts-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project"), credit = join(dir, "credit");
  for (const d of [home, root, project, credit]) mkdirSync(d);
  const accounts = Object.fromEntries(["A", "B"].map((l) => [l, { organization_id: `org-${l}`, cycle_id: `cycle-${l}`, cap_usd: "40.00" }]));
  writeFileSync(join(credit, "config.json"), JSON.stringify({ version: 1, ledger_path: join(credit, "ledger.json"), accounts }));
  const env = { PATH: process.env.PATH, HOME: home, HIMMEL_API_CREDIT_CONFIG: join(credit, "config.json"), HIMMEL_API_CREDIT_SNAPSHOT: join(credit, "snapshot.json"), HIMMEL_SECRETS_KEYRING: "off", CONFIG_UI_IDLE_MS: "60000" };
  const s = startServer({ port: 0, token: TOKEN, root, projectRoot: project, env });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const get = async () => (await (await fetch(`${base}/api/api-roles`, { headers: { "x-himmel-token": TOKEN } })).json()) as Record<string, any>;
  const post = (body: unknown) => fetch(`${base}/api/api-roles`, { method: "POST", headers: { "content-type": "application/json", origin: base, "x-himmel-token": TOKEN }, body: JSON.stringify(body) });
  const routed = (kind: string) => spawnSync("node", [ROLES_CLI, "accounts", kind], { env, encoding: "utf8" }).stdout.trim();
  return { credit, env, get, post, routed };
}

const secrets = ["JIRA_API_TOKEN", "TELEGRAM_BOT_TOKEN"].map((name) => ({ name, collect: "file", status: "not-set", feature: "core" }));
const setup = { secrets, account: { status: "not-set", create: "ui" }, commit: { tracker: "jira", ticketIdRequired: true }, choices: { paths: [], forge: { value: "github" } } };
const secretsTile = (apiRoles: unknown) => renderConfigure({ rows: [] }, { tile: "secrets", setup, state: { plans: {}, apiRoles }, msgs: {} }) as string;
const text = (html: string) => html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

test("the Secrets tile has a Multi accounts section with rows A, B and C and their roles from the role map", async () => {
  const b = boot();
  writeFileSync(join(b.credit, "roles.json"), JSON.stringify({ version: 1, roles: { judge: ["B"], graphify: ["A"] } }));
  const data = await b.get();
  expect(data.rows.map((r: any) => r.account)).toEqual(["A", "B", "C"]);
  const html = secretsTile({ data, error: null, draft: data.roleMap.roles });
  expect(html).toContain("<h3>Multi accounts</h3>");
  const rowOf = (l: string) => (html.match(new RegExp(`<tr[^>]*data-account-row="${l}"[\\s\\S]*?</tr>`)) || [""])[0];
  expect(text(rowOf("A"))).toContain("graphify");
  expect(text(rowOf("B"))).toContain("judge");
  expect(text(rowOf("C"))).toContain("not configured");
  expect(html).not.toContain("org-A");
});

test("an edit through POST /api/api-roles changes the map that auto routing reads", async () => {
  const b = boot();
  expect(b.routed("judge")).toBe("");
  const r = await b.post({ judge: ["B"], graphify: ["A", "B"] });
  expect(r.status).toBe(200);
  expect(b.routed("judge")).toBe("B");
  expect(b.routed("graphify")).toBe("A,B");
  expect((await b.get()).roleMap.roles.judge).toEqual(["B"]);
});
