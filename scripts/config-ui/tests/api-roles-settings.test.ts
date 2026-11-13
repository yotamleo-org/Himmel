// T5a: GET/POST /api/api-roles and the api-roles-settings module. The module only calls the two owner CLIs
// (scripts/lib/api-roles.mjs, scripts/lib/api-credit-state.mjs); it holds no role list, path or validator.
// Hermetic: HOME, HIMMEL_API_CREDIT_CONFIG and HIMMEL_API_CREDIT_SNAPSHOT point at a temp dir.
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { readRoles, saveRoles } from "../api-roles-settings";

const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "api-roles-settings-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project"), credit = join(dir, "credit");
  for (const d of [home, root, project, credit]) mkdirSync(d);
  const accounts = Object.fromEntries(["A", "B"].map((l) => [l, { organization_id: `org-${l}`, cycle_id: `cycle-${l}`, cap_usd: "25.00" }]));
  writeFileSync(join(credit, "config.json"), JSON.stringify({ version: 1, ledger_path: join(credit, "ledger.json"), accounts }));
  const env = { PATH: process.env.PATH, HOME: home, HIMMEL_API_CREDIT_CONFIG: join(credit, "config.json"), HIMMEL_API_CREDIT_SNAPSHOT: join(credit, "snapshot.json"), HIMMEL_SECRETS_KEYRING: "off", CONFIG_UI_IDLE_MS: "60000", CADENCE_ALERT_DEDUPE_DIR: join(dir, "dedupe") };
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, root, projectRoot: project, env });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const get = async () => (await (await fetch(`${base}/api/api-roles`, { headers: { "x-himmel-token": TOKEN } })).json()) as Record<string, any>;
  const post = async (body: unknown) => {
    const r = await fetch(`${base}/api/api-roles`, { method: "POST", headers: { "content-type": "application/json", origin: base, "x-himmel-token": TOKEN }, body: JSON.stringify(body) });
    return { status: r.status, j: (await r.json()) as Record<string, any> };
  };
  const rolesFile = join(credit, "roles.json");
  const dedupe = env.CADENCE_ALERT_DEDUPE_DIR;
  const plantSentinel = () => { mkdirSync(dedupe, { recursive: true }); writeFileSync(join(dedupe, "graph-key-A.planted"), ""); };
  const sentinel = () => existsSync(join(dedupe, "graph-key-A.planted"));
  const tagA = () => writeFileSync(join(credit, "ledger.json"), JSON.stringify({ version: 1, accounts: { A: { organization_id: "org-A", cycle_id: "cycle-A", discrepancy: false, jobs: {}, key_rejected_at: 1700000000 } } }));
  return { dir, credit, env, get, post, rolesFile, plantSentinel, sentinel, tagA };
}

function stub(dir: string, name: string, source: string) {
  const path = join(dir, name);
  writeFileSync(path, source);
  return path;
}

test("GET with a partial file returns state partial and the unknown-role error", async () => {
  const b = boot();
  writeFileSync(b.rolesFile, JSON.stringify({ version: 1, roles: { judge: ["B"], jduge: ["B"] } }));
  const j = await b.get();
  expect(j.roleMap.state).toBe("partial");
  expect(j.roleMap.errors).toContain("unknown-role:jduge");
  expect(j.roleMap.roles).toEqual({ judge: ["B"] });
  expect(j.ROLES).toEqual(["graphify", "judge"]);
  expect(j.rows.map((r: any) => r.account)).toEqual(["A", "B", "C"]);
  expect(JSON.stringify(j)).not.toContain("org-A");
});

test("POST saves through the CLI writer with mode 600 and the saved map is read back", async () => {
  const b = boot();
  const r = await b.post({ judge: ["B"], graphify: ["A", "B"] });
  expect(r.status).toBe(200);
  expect(r.j).toEqual({ ok: true, errors: [] });
  expect(statSync(b.rolesFile).mode & 0o777).toBe(0o600);
  expect(JSON.parse(readFileSync(b.rolesFile, "utf8"))).toEqual({ version: 1, roles: { judge: ["B"], graphify: ["A", "B"] } });
  expect((await b.get()).roleMap.state).toBe("valid");
});

test("POST of an unknown account is a 422 naming it, and the file is untouched", async () => {
  const b = boot();
  const r = await b.post({ judge: ["D"] });
  expect(r.status).toBe(422);
  expect(r.j.errors).toContain("unknown-account:judge:D");
  expect(existsSync(b.rolesFile)).toBe(false);
});

test("POST with an extra key is a 422 naming unknown-role:note and the file is byte-unchanged", async () => {
  const b = boot();
  const before = JSON.stringify({ version: 1, roles: { judge: ["A"] } }) + "\n";
  writeFileSync(b.rolesFile, before);
  const r = await b.post({ judge: ["B"], note: "sk-ant-fake" });
  expect(r.status).toBe(422);
  expect(r.j.errors).toContain("unknown-role:note");
  expect(readFileSync(b.rolesFile, "utf8")).toBe(before);
  expect(readFileSync(b.rolesFile, "utf8")).not.toContain("sk-ant-fake");
});

test("the roles card shows a rejected key: A's row carries the tag key rejected", async () => {
  const b = boot();
  b.tagA();
  const j = await b.get();
  expect(j.rows.find((r: any) => r.account === "A").tag).toBe("key rejected");
  expect(j.rows.find((r: any) => r.account === "B").tag).not.toBe("key rejected");
});

test("a save that drops A from graphify clears A's graph-key alert sentinel and keeps A's tag; a save that keeps A leaves it", async () => {
  const b = boot();
  b.tagA();
  writeFileSync(b.rolesFile, JSON.stringify({ version: 1, roles: { graphify: ["A", "B"] } }));
  b.plantSentinel();
  const kept = await b.post({ graphify: ["A"] });
  expect(kept.status).toBe(200);
  expect(b.sentinel()).toBe(true);
  const dropped = await b.post({ graphify: ["B"] });
  expect(dropped.status).toBe(200);
  expect(b.sentinel()).toBe(false);
  expect((await b.get()).rows.find((r: any) => r.account === "A").tag).toBe("key rejected");
});

test("an accounts CLI that outlasts the bound makes every row unknown with reason timeout", async () => {
  const b = boot();
  const creditCli = stub(b.dir, "slow-accounts.mjs", "await new Promise((r) => setTimeout(r, 30000));\n");
  const out = await readRoles(b.env, { creditCli, timeoutMs: 300 });
  expect(out.status).toBe(200);
  expect(out.body.rows).toEqual(["A", "B", "C"].map((account) => ({ account, configured: null, cap_usd: null, tag: "unknown", reason: "timeout" })));
  expect(out.body.roleMap.state).toBe("absent");
});

test("a role list from the check CLI passes through GET and a POST of it reaches the writer unchanged", async () => {
  const b = boot();
  const recorded = join(b.dir, "stdin.json");
  const rolesCli = stub(b.dir, "stub-roles.mjs", `import { readFileSync, writeFileSync } from "node:fs";
if (process.argv[2] === "check") console.log(JSON.stringify({ roleMap: { state: "absent", roles: {}, errors: [] }, warnings: [], ROLES: ["zzz"], accounts: "ok" }));
else if (process.argv[2] === "walk") console.log("A");
else { writeFileSync(${JSON.stringify(recorded)}, readFileSync(0, "utf8")); console.log(JSON.stringify({ ok: true, errors: [] })); }
`);
  expect((await readRoles(b.env, { rolesCli })).body.ROLES).toEqual(["zzz"]);
  const saved = await saveRoles({ zzz: ["A"] }, b.env, { rolesCli });
  expect(saved.status).toBe(200);
  expect(JSON.parse(readFileSync(recorded, "utf8"))).toEqual({ version: 1, roles: { zzz: ["A"] } });
});
