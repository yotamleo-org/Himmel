import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer, type ServerOpts } from "../server";

const TOKEN = "t".repeat(64);
const H = { "X-Himmel-Token": TOKEN };
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const dirs: string[] = [];
const stops: (() => void)[] = [];
afterEach(() => { while (stops.length) stops.pop()!(); while (dirs.length) rmSync(dirs.pop()!, { recursive: true, force: true }); });

function boot(x: Partial<ServerOpts> & Record<string, unknown>) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-idle-"));
  dirs.push(dir);
  mkdirSync(join(dir, "home"), { recursive: true });
  const feedCount = join(dir, "feed-count"), fleetCount = join(dir, "fleet-count"), script = join(dir, "fleet.sh");
  writeFileSync(script, `#!/bin/sh\necho run >> '${fleetCount}'\n`);
  chmodSync(script, 0o755);
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, fleetScript: script, env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_IDLE_MS: "60000", CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_COUNT: feedCount, STUB_FEED_SLEEP: "50" }, ...x } as never);
  stops.push(() => s.stop());
  const n = (f: string) => { try { return readFileSync(f, "utf8").split("\n").filter(Boolean).length; } catch { return 0; } };
  return { port: s.port, reports: () => n(feedCount), fleets: () => n(fleetCount) };
}
const get = (port: number, path: string) => fetch(`http://127.0.0.1:${port}${path}`, { headers: H });

test("a service-mode server with no client makes no report and no fleet read", async () => {
  const { reports, fleets } = boot({ backgroundFeed: true, noIdle: true, feedRefreshMs: 200 });
  await sleep(1500);
  expect(reports()).toBe(0);
  expect(fleets()).toBe(0);
});

test("a client that only polls the fleet page never makes the Config report refresh, and each poll still reads the fleet", async () => {
  const { port, reports, fleets } = boot({ backgroundFeed: true, feedRefreshMs: 400 });
  await sleep(300);
  expect(reports()).toBe(1);
  for (let i = 0; i < 8; i++) {
    expect((await get(port, "/api/agui/fleet")).status).toBe(200);
    await sleep(250);
  }
  expect(fleets()).toBe(8);
  expect(reports()).toBe(1);
});
