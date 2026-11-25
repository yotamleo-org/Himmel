import { test, expect, afterEach } from "bun:test";
import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { stubKeyring } from "./keyring-stub";

const TOKEN = "t".repeat(64);
const SECRET = "kr-only-" + "q7x2".repeat(2);
const stops: (() => void)[] = [];
let dir = "";
afterEach(() => { while (stops.length) stops.pop()!(); if (dir) rmSync(dir, { recursive: true, force: true }); dir = ""; });

function hangable(k: ReturnType<typeof stubKeyring>) {
  const bin = join(dir, "kbin");
  renameSync(join(bin, "secret-tool"), join(bin, "secret-tool.real"));
  writeFileSync(join(bin, "secret-tool"), '#!/usr/bin/env bash\n[ -e "$KSTUB_STORE.hang" ] && exec sleep 30\nif [ -e "$KSTUB_STORE.slow" ]; then rm -f "$KSTUB_STORE.slow"; sleep 2; fi\nexec "$(dirname "$0")/secret-tool.real" "$@"\n');
  chmodSync(join(bin, "secret-tool"), 0o755);
  return { hang: () => writeFileSync(`${k.store}.hang`, ""), release: () => rmSync(`${k.store}.hang`, { force: true }), slow: () => writeFileSync(`${k.store}.slow`, "") };
}

function boot(now?: () => number, extra: Record<string, string> = {}, setup?: (d: string) => Record<string, string>, serverOpts: Record<string, unknown> = {}) {
  dir = mkdtempSync(join(tmpdir(), "cfgui-rs-"));
  const home = join(dir, "home"), cad = join(dir, "cad"), state = join(dir, "state"), argv = join(dir, "argv"), root = join(dir, "root");
  for (const d of [home, state, root]) mkdirSync(d, { recursive: true });
  for (const c of ["scripts/luna/graphmap-cadence.sh"]) { mkdirSync(join(cad, c, ".."), { recursive: true }); copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, c)); }
  writeFileSync(argv, "");
  const k = stubKeyring(dir);
  const h = hangable(k);
  const env = { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"), HIMMEL_REPORT_CADENCE_ROOT: cad,
    STUB_ARGV: argv, STUB_STATE: state, CONFIG_UI_IDLE_MS: "60000", ...k.env, HIMMEL_SECRETS_KEYRING: "", FIRECRAWL_API_KEY: "", HIMMELCTL_SUDO_PASSWORD: "", STUB_LEAK: SECRET, GATE: join(dir, "gate"), ...(setup?.(dir) ?? {}), ...extra };
  const s = startServer({ port: 0, token: TOKEN, env, root, now, onIdle: () => {}, ...serverOpts } as never);
  stops.push(() => s.stop());
  const get = (path: string) => fetch(`http://127.0.0.1:${s.port}${path}`, { headers: { "X-Himmel-Token": TOKEN } });
  const preview = () => fetch(`http://127.0.0.1:${s.port}/api/preview`, {
    method: "POST", body: JSON.stringify({ action: "cadence.arm", target: "graphmap" }),
    headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" },
  });
  const run = (previewId: string) => fetch(`http://127.0.0.1:${s.port}/api/run`, {
    method: "POST", body: JSON.stringify({ previewId, action: "cadence.arm", target: "graphmap", consent: "graphmap" }),
    headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" },
  });
  const post = (path: string, body: unknown = {}) => fetch(`http://127.0.0.1:${s.port}${path}`, {
    method: "POST", body: JSON.stringify(body),
    headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" },
  });
  return { k, h, get, post, preview, run, gate: join(dir, "gate") };
}

test("a keyring that hangs does not stall another request: the second answers while the read is pending", async () => {
  const b = boot();
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  b.h.hang();
  const t0 = Date.now();
  const first = b.get("/api/projects");
  const second = await b.get("/api/projects");
  expect(second.status).toBe(200);
  expect(Date.now() - t0).toBeLessThan(5_000);
  expect((await first).status).toBe(200);
});

test("a timed-out read does not shrink the list: a value masked once stays masked", async () => {
  let t = Date.now();
  const b = boot(() => t);
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  const ok = await (await b.preview()).text();
  expect(ok).toContain("plan: graphmap-cadence");
  expect(ok).not.toContain(SECRET);
  b.h.hang();
  t += 6_000;
  const t0 = Date.now();
  const pt = await (await b.preview()).text();
  expect(Date.now() - t0).toBeLessThan(5_000);
  expect(pt).toContain("plan: graphmap-cadence");
  expect(pt).not.toContain(SECRET);
});

test("a value stored while the list is reused is masked from the next response after the list expires", async () => {
  let t = Date.now();
  const b = boot(() => t);
  expect(await (await b.preview()).text()).toContain(SECRET);
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  t += 6_000;
  const pt = await (await b.preview()).text();
  expect(pt).toContain("plan: graphmap-cadence");
  expect(pt).not.toContain(SECRET);
});

test("a value stored while a slow read is in flight is masked from the next response", async () => {
  const b = boot(undefined, { HIMMEL_SECRETS_TIMEOUT_MS: "2000" });
  b.h.hang();
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  writeFileSync(join(dir, "root", ".env"), `FIRECRAWL_API_KEY=${SECRET}\n`);
  const ran = await b.run(previewId);
  expect(ran.status).toBe(200);
  const rt = await ran.text();
  expect(rt).toContain("graphmap-cadence");
  expect(rt).not.toContain(SECRET);
});

test("a value stored in the keyring is masked in the response of the run that stored it, though the keyring read is slow", async () => {
  const b = boot();
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  b.h.slow();
  const ran = await b.run(previewId);
  expect(ran.status).toBe(200);
  const rt = await ran.text();
  expect(rt).toContain("graphmap-cadence");
  expect(rt).not.toContain(SECRET);
});

test("a hung keyring read ends at the resolver timeout, so a run that waits for a fresh list still answers", async () => {
  const b = boot(undefined, { HIMMEL_SECRETS_TIMEOUT_MS: "1000" });
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  b.h.hang();
  const t0 = Date.now();
  const ran = await b.run(previewId);
  expect(ran.status).toBe(200);
  expect(Date.now() - t0).toBeLessThan(5_000);
});

test("HIMMEL_SECRETS_TIMEOUT_MS is taken only as a positive integer up to 2147483647; else the 10 s timeout", async () => {
  const { timeoutMs } = await import("../../lib/resolve-secrets.mjs");
  const of = (v?: string) => timeoutMs(v === undefined ? {} : { HIMMEL_SECRETS_TIMEOUT_MS: v });
  expect([of(), of("-1"), of("0"), of("1.5"), of("abc"), of("Infinity"), of("2147483648")]).toEqual(Array(7).fill(10000));
  expect([of("1000"), of("2147483647")]).toEqual([1000, 2147483647]);
});

test("resolveSecretsAsync serves the same names as resolveSecrets and leaves the event loop running", async () => {
  dir = mkdtempSync(join(tmpdir(), "cfgui-rs-"));
  const k = stubKeyring(dir);
  k.put("FIRECRAWL_API_KEY", SECRET);
  const env = { ...k.env, HIMMEL_SECRETS_KEYRING: "", FIRECRAWL_API_KEY: "" };
  const lib = await import("../../lib/resolve-secrets.mjs");
  const root = join(dir, "root");
  mkdirSync(root);
  const sync = lib.resolveSecrets(root, ["FIRECRAWL_API_KEY", "NOT_HELD"], env);
  let ticks = 0;
  const timer = setInterval(() => { ticks++; }, 5);
  const viaAsync = await (lib as unknown as { resolveSecretsAsync: (r: string, n: string[], e: Record<string, string>) => Promise<Record<string, string>> }).resolveSecretsAsync(root, ["FIRECRAWL_API_KEY", "NOT_HELD"], env);
  clearInterval(timer);
  expect(sync).toEqual({ FIRECRAWL_API_KEY: SECRET });
  expect(viaAsync).toEqual(sync);
  expect(ticks).toBeGreaterThan(0);
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const until = async (f: () => boolean, ms = 8_000) => { const end = Date.now() + ms; while (!f()) { if (Date.now() > end) throw new Error("until: timed out"); await sleep(25); } };
const GATED_NODE = (out: string) => `const fs = require("fs"), g = process.env.GATE; fs.writeFileSync(g + ".started", "");\nconst t = setInterval(() => { if (!fs.existsSync(g + ".open")) return; clearInterval(t); ${out} }, 25);\n`;
const GATED_SH = (out: string) => `touch "$GATE.started"\nwhile [ ! -e "$GATE.open" ]; do sleep 0.05; done\n${out}\n`;
const script = (name: string, body: string) => { const p = join(dir, name); mkdirSync(join(p, ".."), { recursive: true }); writeFileSync(p, body); chmodSync(p, 0o755); return p; };
const MASK = "‹redacted›";
const storing = (name: string, fn: () => Promise<void>, skip = false) => (skip ? test.skip : test)(name, fn, 30_000);

async function whileStored<T>(b: ReturnType<typeof boot>, start: () => Promise<T>): Promise<T> {
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  const reader = start();
  await until(() => existsSync(`${b.gate}.started`));
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  b.h.slow();
  const ran = b.run(previewId);
  await until(() => !existsSync(`${b.k.store}.slow`));
  writeFileSync(`${b.gate}.open`, "");
  const answer = await reader;
  expect((await ran).status).toBe(200);
  return answer;
}
const masked = async (r: Response) => { expect(r.status).toBe(200); const t = await r.text(); expect(t).toContain(MASK); expect(t).not.toContain(SECRET); };

storing("a feed waiter's answer masks a value stored while its report ran", async () => {
  const feed = () => ({ CONFIG_UI_HIMMELCTL: script("feed-gated.js", `if (process.argv[2] !== "report" || process.argv.includes("--items")) require(${JSON.stringify(join(import.meta.dir, "stub-recorder.js"))});\nelse {\n${GATED_NODE('process.stdout.write(JSON.stringify({ schema: "himmel-config-feed/1", rows: [{ id: "x", title: "t " + process.env.STUB_LEAK }], seq: 1 }) + "\\n");')}}\n`) });
  const b = boot(undefined, {}, feed, { feedWaitMs: 10_000 });
  await masked(await whileStored(b, () => b.get("/api/feed")));
});

storing("the verify doctor's answer masks a value stored while the doctor ran", async () => {
  const doctor = () => ({ HIMMEL_REPORT_DOCTOR: script("doctor-gated.sh", GATED_SH(`echo '{"sev":"WARN","id":"C4","msg":"token '"$STUB_LEAK"' soon","remedy":""}'\necho "Summary: 0 FAIL  1 WARN  0 INFO" >&2\nexit 0`)) });
  const b = boot(undefined, {}, doctor);
  await masked(await whileStored(b, () => b.post("/api/setup/verify")));
});

storing("the stage history's answer masks a value stored while the Jira read ran", async () => {
  const jira = (d: string) => {
    mkdirSync(join(d, "home", ".himmel", "state", "jira-mirror", "HIMMEL"), { recursive: true });
    return { CONFIG_UI_JIRA_CLI: script("jira-gated.js", GATED_NODE('console.log(JSON.stringify([{ created: "2026-10-27T09:00:00.000+0000", author: { displayName: process.env.STUB_LEAK }, items: [{ field: "status", fromString: "To Do", toString: "In Progress" }] }]));')) };
  };
  const b = boot(undefined, {}, jira);
  await masked(await whileStored(b, () => b.get("/api/roadmap/history?key=HIMMEL-2")));
});

storing("the drift refresh's answer masks a value stored while the check ran", async () => {
  const drift = (d: string) => {
    const mirror = join(d, "home", ".himmel", "state", "jira-mirror", "HIMMEL");
    mkdirSync(mirror, { recursive: true });
    const file = join(d, "focus-drift.txt");
    writeFileSync(file, "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=jira release request v1.1.3\nsdrift=1:abc\n");
    return { HIMMEL_FOCUS_DRIFT: file, HIMMEL_JIRA_MIRROR: mirror, CONFIG_UI_DRIFT_CHECK: script("drift-gated.sh", GATED_SH(`echo 'sdrift=1:'"$STUB_LEAK"`)) };
  };
  const b = boot(undefined, {}, drift);
  await masked(await whileStored(b, () => b.post("/api/board/drift-refresh")));
});

storing("the roll-up's answer masks a value stored while its job probe ran", async () => {
  const rollup = (d: string) => {
    const file = join(d, "weekly.jsonl");
    writeFileSync(file, JSON.stringify({ kind: "week", key: SECRET, partial: false, since: "a", until: "b", delta: { merges: null, cost_eq_per_ticket: null, red_main: null }, merges: 10, cost_eq_per_ticket: 100, red_main: 1 }) + "\n");
    script(join("cad", "scripts", "eval", "rollup-cadence.sh"), GATED_SH("echo ARMED"));
    return { WEEKLY_ROLLUP_FILE: file };
  };
  const b = boot(undefined, {}, rollup);
  await masked(await whileStored(b, () => b.get("/api/rollup")));
});

storing("the journal stream masks a chunk written while a stored value is still being read in", async () => {
  const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
  const lines = readFileSync(join(import.meta.dir, "fixtures", "agui", "happy-path.jsonl"), "utf8").split("\n").filter(Boolean);
  const b = boot(undefined, {}, (d) => {
    mkdirSync(join(d, "home", ".claude", "projects", "-proj"), { recursive: true });
    writeFileSync(join(d, "home", ".claude", "projects", "-proj", `${RUN}.jsonl`), lines.slice(0, 2).join("\n") + "\n");
    return {};
  }, { aguiPollMs: 20, aguiIdleMs: 60_000, aguiMaxMs: 60_000 });
  const res = await b.get(`/api/agui/${RUN}`);
  expect(res.status).toBe(200);
  const reader = res.body!.getReader(), dec = new TextDecoder();
  let text = "";
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  b.h.slow();
  const ran = b.run(previewId);
  await until(() => !existsSync(`${b.k.store}.slow`));
  appendFileSync(join(dir, "home", ".claude", "projects", "-proj", `${RUN}.jsonl`), lines.slice(2, 4).join("\n").replace("Listing the root.", `Seen ${SECRET} here`) + "\n");
  const end = Date.now() + 8_000;
  while (!text.includes("Seen ") && Date.now() < end) {
    const n = await Promise.race([reader.read(), sleep(end - Date.now()).then(() => null)]);
    if (!n || n.done) break;
    text += dec.decode(n.value, { stream: true });
  }
  await reader.cancel();
  expect((await ran).status).toBe(200);
  expect(text).toContain(`Seen ${MASK} here`);
  expect(text).not.toContain(SECRET);
});

const enforcesModes = process.getuid?.() !== 0;
storing("a run that fails after it started still invalidates the list: a value its child stored is masked in the next response", async () => {
  const stateDir = (d: string) => join(d, "home", ".himmel", "state", "config-ui");
  const b = boot(undefined, {}, (d) => { mkdirSync(stateDir(d), { recursive: true }); writeFileSync(join(stateDir(d), "actions.jsonl"), ""); return { STUB_RO_DIR: stateDir(d) }; });
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  b.k.put("FIRECRAWL_API_KEY", SECRET);
  try {
    const ran = await b.run(previewId);
    expect(ran.status).toBe(500);
  } finally { chmodSync(stateDir(dir), 0o755); rmSync(join(stateDir(dir), "write.lock"), { force: true }); }
  const next = await (await b.preview()).text();
  expect(next).toContain("plan: graphmap-cadence");
  expect(next).not.toContain(SECRET);
}, !enforcesModes);
