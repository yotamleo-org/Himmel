// HIMMEL_LUNA_CONFIG_PATH names the same file as HIMMEL_CONFIG_DIR: bun's os.homedir() does not follow a HOME set at
// run time, so without it luna-config.js would save to the real home while graph-choices.js reads the fixture.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-expect-error CommonJS module without types
import { configPath } from "../../himmelctl/lib/luna-config.js";
// @ts-expect-error CommonJS module without types
import { NO_CHOICE_SENTENCE, ROSTER_LINES, FIX_LINES } from "../../himmelctl/lib/graph-choices.js";

const TOKEN = "t".repeat(64);
const PLANTED = "sk-ant-api03-PLANTEDKEYVALUE0123456789";
const SEAMS = ["HOME", "HIMMEL_CONFIG_DIR", "HIMMEL_CONFIG_AUDIT_DIR", "HIMMEL_CONFIG_AUDIT_ENV_FILE", "HIMMEL_CONFIG_ALERT_CMD", "HIMMEL_TEST_FIXTURE",
  "HIMMEL_LUNA_CONFIG_PATH", "HIMMEL_PROVENANCE_DIR", "GRAPHMAP_BAT_DIR", "HIMMEL_API_CREDIT_CONFIG", "HIMMEL_API_CREDIT_SNAPSHOT",
  "CADENCE_ALERT_DEDUPE_DIR", "GRAPH_CHOICES_CRONTAB", "XDG_DATA_HOME"] as const;
let saved: Record<string, string | undefined> = {};
let dir = "", home = "", station = "", credit = "", dedupe = "";
let stop: (() => void) | null = null;

beforeEach(() => {
  saved = Object.fromEntries(SEAMS.map((k) => [k, process.env[k]]));
  dir = mkdtempSync(join(tmpdir(), "graph-config-"));
  home = join(dir, "home"); station = join(home, ".himmel"); credit = join(dir, "credit"); dedupe = join(dir, "dedupe");
  for (const d of [home, station, credit, dedupe]) mkdirSync(d, { recursive: true });
  writeFileSync(join(dir, "fixture.env"), `ANTHROPIC_API_KEY=${PLANTED}\n`);
  writeFileSync(join(dir, "alert.sh"), `#!/bin/sh\necho "$*" >> "${join(dir, "alerts.log")}"\n`);
  writeFileSync(join(dir, "crontab"), "#!/bin/sh\nexit 1\n");
  chmodSync(join(dir, "alert.sh"), 0o755); chmodSync(join(dir, "crontab"), 0o755);
  Object.assign(process.env, {
    HOME: home, HIMMEL_CONFIG_DIR: station, HIMMEL_CONFIG_AUDIT_DIR: join(station, "state", "config-audit"),
    HIMMEL_CONFIG_AUDIT_ENV_FILE: join(dir, "fixture.env"), HIMMEL_CONFIG_ALERT_CMD: join(dir, "alert.sh"), HIMMEL_TEST_FIXTURE: "1",
    HIMMEL_LUNA_CONFIG_PATH: join(station, "config.json"), HIMMEL_PROVENANCE_DIR: join(dir, "prov"), GRAPHMAP_BAT_DIR: join(dir, "runners"),
    HIMMEL_API_CREDIT_CONFIG: join(credit, "config.json"), HIMMEL_API_CREDIT_SNAPSHOT: join(credit, "snapshot.json"),
    CADENCE_ALERT_DEDUPE_DIR: dedupe, GRAPH_CHOICES_CRONTAB: join(dir, "crontab"), XDG_DATA_HOME: join(dir, "data"),
  });
  roster(["A", "C"]);
});
afterEach(() => {
  stop?.(); stop = null;
  for (const k of SEAMS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  rmSync(dir, { recursive: true, force: true });
});

function roster(letters: string[]) {
  const accounts = Object.fromEntries(letters.map((l) => [l, { organization_id: `org-${l}`, cycle_id: `cycle-${l}`, cap_usd: "25.00" }]));
  writeFileSync(join(credit, "config.json"), JSON.stringify({ version: 1, ledger_path: join(credit, "ledger.json"), accounts }));
}

function boot() {
  expect(configPath()).toBe(join(station, "config.json"));
  const env: Record<string, string | undefined> = { PATH: process.env.PATH, CONFIG_UI_IDLE_MS: "60000", HIMMEL_SECRETS_KEYRING: "off" };
  for (const k of SEAMS) env[k] = process.env[k];
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, root: join(dir, "root"), projectRoot: join(dir, "project"), env });
  stop = () => s.stop();
  const base = `http://127.0.0.1:${s.port}`;
  const get = async (headers: Record<string, string> = { "X-Himmel-Token": TOKEN }) => {
    const r = await fetch(`${base}/api/graph-choices`, { headers });
    const text = await r.text();
    return { status: r.status, text, j: r.headers.get("content-type")?.includes("json") ? JSON.parse(text) : null };
  };
  const post = async (body: unknown) => {
    const r = await fetch(`${base}/api/graph-choices`, { method: "POST", headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: base }, body: JSON.stringify(body) });
    const text = await r.text();
    return { status: r.status, text, j: JSON.parse(text) };
  };
  return { get, post };
}

const cfg = () => join(station, "config.json");
const seed = (doc: unknown) => writeFileSync(cfg(), typeof doc === "string" ? doc : JSON.stringify(doc, null, 2) + "\n");
const bytes = () => (existsSync(cfg()) ? readFileSync(cfg(), "utf8") : null);
const repo = (name: string) => { const r = join(home, name); mkdirSync(join(r, ".git"), { recursive: true }); return r; };
const sentinel = (l: string) => join(dedupe, `graph-key-${l}.planted`);

test("GET with no store answers the adopter, state default, the no-choice sentence and the roster rows, with no key value", async () => {
  const s = boot();
  const r = await s.get();
  expect(r.status).toBe(200);
  expect(r.j.role).toBe("adopter");
  expect(r.j.state).toBe("default");
  expect(r.j.sentence).toBe(NO_CHOICE_SENTENCE);
  expect(r.j.corpora).toEqual([]);
  expect(r.j.primary).toBeNull();
  expect(r.j.fallbacks).toEqual([]);
  expect(r.j.worst_case.length).toBeGreaterThan(0);
  expect(r.j.accounts).toEqual([{ account: "A", configured: true, tag: "no reading" }, { account: "B", configured: false, tag: "not configured" }, { account: "C", configured: true, tag: "no reading" }]);
  expect(r.j.job).toBe("not armed");
  expect(r.text).not.toContain("sk-ant");
  expect(r.text).not.toContain("org-A");
});

test("GET without the token or a login is 401, like every other route", async () => {
  const s = boot();
  expect((await s.get({})).status).toBe(401);
});

test("POST of a valid route writes graphify.choices through save, keeps the other sections and is read back", async () => {
  seed({ version: 1, vm: { mode: "none" }, graphify: { salus_ollama_cloud_ok: false } });
  const root = repo("My Project");
  const s = boot();
  const r = await s.post({ corpora: [{ root }], primary: "C", fallbacks: ["A", "subscription"], max_usd_per_pass: 5 });
  expect(r.status).toBe(200);
  const doc = JSON.parse(bytes()!);
  expect(doc.graphify.choices).toEqual({ version: 1, corpora: [{ name: "My-Project", root }], primary: "C", fallbacks: ["A", "subscription"], max_usd_per_pass: 5 });
  expect(doc.graphify.salus_ollama_cloud_ok).toBe(false);
  expect(doc.vm).toEqual({ mode: "none" });
  expect(r.j.state).toBe("set");
  expect(r.j.primary).toBe("C");
  expect(r.j.fallbacks).toEqual(["A", "subscription"]);
  expect(r.j.corpora).toEqual([{ name: "My-Project", root }]);
  expect(r.j.worst_case.join("\n")).toContain("5.00 USD");
  expect((await s.get()).j).toEqual(r.j);
  expect(r.text).not.toContain("sk-ant");
});

test("POST of auto is 400 and writes nothing", async () => {
  seed({ version: 1, graphify: {} });
  const before = bytes();
  const s = boot();
  const r = await s.post({ corpora: [], primary: "auto", fallbacks: [] });
  expect(r.status).toBe(400);
  expect(r.j.error).toContain("primary is not none, subscription or one capital letter");
  expect(bytes()).toBe(before);
});

test("POST of a root that is not a git repo is 400 naming the reason, and writes nothing", async () => {
  const s = boot();
  const root = join(home, "plain");
  mkdirSync(root);
  const r = await s.post({ corpora: [{ root }], primary: "none", fallbacks: [] });
  expect(r.status).toBe(400);
  expect(r.j.error).toContain("the root holds no .git entry");
  expect(bytes()).toBeNull();
});

test("POST on a publisher is 409 naming how to leave the role, writes nothing, and GET is read-only with that reason", async () => {
  seed({ version: 1, graphify: { semantic_api_ok: true } });
  const before = bytes();
  const s = boot();
  const r = await s.post({ corpora: [], primary: "subscription", fallbacks: [] });
  expect(r.status).toBe(409);
  expect(r.j.error).toContain("config-audit.sh accept");
  expect(r.j.error).toContain("arm --rewrite-armed --leave-publisher");
  expect(bytes()).toBe(before);
  const g = await s.get();
  expect(g.j.role).toBe("publisher");
  expect(g.j.reason).toContain("--leave-publisher");
});

test("POST on an unreadable config is 409 with the cause word and its fixed line, and no byte of the file", async () => {
  seed(`${PLANTED} is not json`);
  const before = bytes();
  const s = boot();
  const r = await s.post({ corpora: [], primary: "subscription", fallbacks: [] });
  expect(r.status).toBe(409);
  expect(r.j.error).toContain("cause=not-json");
  expect(r.j.error).toContain(FIX_LINES["not-json"]);
  expect(r.text).not.toContain("sk-ant");
  expect(r.text).not.toContain("is not json");
  expect(bytes()).toBe(before);
  const g = await s.get();
  expect(g.j.role).toBe("unreadable");
  expect(g.j.state).toBe("unreadable");
  expect(g.j.reason).toContain("cause=not-json");
  expect(g.text).not.toContain("sk-ant");
});

for (const letter of ["B", "D"]) {
  test(`POST naming ${letter}, a letter with no configured roster row, is 400 naming it and writes nothing`, async () => {
    seed({ version: 1, graphify: {} });
    const before = bytes();
    const s = boot();
    const r = await s.post({ corpora: [], primary: "A", fallbacks: [letter], max_usd_per_pass: 5 });
    expect(r.status).toBe(400);
    expect(r.j.error).toContain(`${letter} is not a configured API account`);
    expect(bytes()).toBe(before);
  });
}

test("with an unreadable roster a POST naming any letter is 400 with that roster's fixed line, and subscription alone is 200", async () => {
  rmSync(join(credit, "config.json"));
  const s = boot();
  const refused = await s.post({ corpora: [], primary: "A", fallbacks: [], max_usd_per_pass: 5 });
  expect(refused.status).toBe(400);
  expect(refused.j.error).toContain(ROSTER_LINES["unreadable-state"]);
  expect(bytes()).toBeNull();
  const g = await s.get();
  expect(g.j.roster).toBe(ROSTER_LINES["unreadable-state"]);
  const ok = await s.post({ corpora: [], primary: "subscription", fallbacks: [] });
  expect(ok.status).toBe(200);
  expect(JSON.parse(bytes()!).graphify.choices).toEqual({ version: 1, corpora: [], primary: "subscription", fallbacks: [] });
});

test("POST that drops A from the stored route clears A's graph-key sentinel, keeps C's, and runs no key-ok", async () => {
  seed({ version: 1, graphify: { choices: { version: 1, corpora: [], primary: "A", fallbacks: ["C"], max_usd_per_pass: 5 } } });
  const ledger = JSON.stringify({ version: 1, accounts: { A: { organization_id: "org-A", cycle_id: "cycle-A", discrepancy: false, jobs: {}, key_rejected_at: 1700000000 } } });
  writeFileSync(join(credit, "ledger.json"), ledger);
  for (const l of ["A", "C"]) writeFileSync(sentinel(l), "");
  const s = boot();
  const r = await s.post({ corpora: [], primary: "C", fallbacks: [], max_usd_per_pass: 5 });
  expect(r.status).toBe(200);
  expect(existsSync(sentinel("A"))).toBe(false);
  expect(existsSync(sentinel("C"))).toBe(true);
  expect(readFileSync(join(credit, "ledger.json"), "utf8")).toBe(ledger);
  expect(r.j.accounts.find((a: { account: string }) => a.account === "A").tag).toBe("key rejected");
});
