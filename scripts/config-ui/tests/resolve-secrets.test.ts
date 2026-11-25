// A wedged Secret Service must not freeze the config UI. Every row runs on the stub keyring (./keyring-stub.ts);
// a row that hangs the keyring does it by a marker file the stub's secret-tool checks. Never against the real keyring.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
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
  writeFileSync(join(bin, "secret-tool"), '#!/usr/bin/env bash\n[ -e "$KSTUB_STORE.hang" ] && exec sleep 30\nexec "$(dirname "$0")/secret-tool.real" "$@"\n');
  chmodSync(join(bin, "secret-tool"), 0o755);
  return { hang: () => writeFileSync(`${k.store}.hang`, ""), release: () => rmSync(`${k.store}.hang`, { force: true }) };
}

function boot(now?: () => number) {
  dir = mkdtempSync(join(tmpdir(), "cfgui-rs-"));
  const home = join(dir, "home"), cad = join(dir, "cad"), state = join(dir, "state"), argv = join(dir, "argv"), root = join(dir, "root");
  for (const d of [home, state, root]) mkdirSync(d, { recursive: true });
  for (const c of ["scripts/luna/graphmap-cadence.sh"]) { mkdirSync(join(cad, c, ".."), { recursive: true }); copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, c)); }
  writeFileSync(argv, "");
  const k = stubKeyring(dir);
  const h = hangable(k);
  const env = { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"), HIMMEL_REPORT_CADENCE_ROOT: cad,
    STUB_ARGV: argv, STUB_STATE: state, CONFIG_UI_IDLE_MS: "60000", ...k.env, HIMMEL_SECRETS_KEYRING: "", FIRECRAWL_API_KEY: "", HIMMELCTL_SUDO_PASSWORD: "", STUB_LEAK: SECRET };
  const s = startServer({ port: 0, token: TOKEN, env, root, now, onIdle: () => {} } as never);
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
  return { k, h, get, preview, run };
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
  const b = boot();
  b.h.hang();
  const { previewId } = await (await b.preview()).json() as { previewId: string };
  writeFileSync(join(dir, "root", ".env"), `FIRECRAWL_API_KEY=${SECRET}\n`);
  const ran = await b.run(previewId);
  expect(ran.status).toBe(200);
  const rt = await ran.text();
  expect(rt).toContain("graphmap-cadence");
  expect(rt).not.toContain(SECRET);
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
