// GET /api/agui/fleet — bus edges and the per-row bus counts, built from the himmel-bus collector (busEvents).
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { fleetFixture, FLEET } from "./agui-fleet-fixture";
import { busRoot, append } from "../../../marketplace/plugins/himmel-bus/lib/store.mjs";
import { register } from "../../../marketplace/plugins/himmel-bus/lib/identity.mjs";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

async function boot(seed: boolean) {
  const dir = mkdtempSync(join(tmpdir(), "agui-fleet-bus-"));
  const fx = fleetFixture(dir);
  const state = join(dir, "state");
  let root = "";
  if (seed) {
    root = await busRoot({ stateHome: state });
    await register(root, FLEET.console.name, { role: "console" });
    await register(root, FLEET.leg.name, { role: "leg", console: FLEET.console.name });
    const t = Date.now() - 60_000;
    const rec = (o: Record<string, unknown>) => ({ t, b: "x", c: 0, ...o });
    await append(root, FLEET.leg.name, rec({ i: "M1", f: FLEET.console.name, r: FLEET.leg.name, c: 1, b: "GO 1 abc", t: t + 1 }));
    await append(root, FLEET.leg.name, rec({ i: "M2", f: FLEET.console.name, r: FLEET.leg.name, b: "just words", t: t + 2 }));
    await append(root, FLEET.console.name, rec({ i: "M3", f: FLEET.leg.name, r: FLEET.console.name, b: "READY 1 abc GREEN", t: t + 3 }));
  }
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", ...fx.env, XDG_STATE_HOME: state } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return { ...s, root, dir };
}
const fleet = async (port: number) => (await fetch(`http://127.0.0.1:${port}/api/agui/fleet`, { headers: { "X-Himmel-Token": TOKEN } })).json();

test("edges count each from→to pair; rows carry unacked, undelivered and unbound", async () => {
  const { port } = await boot(true);
  const b = await fleet(port);
  const edge = (from: string, to: string) => b.edges.find((e: any) => e.from === from && e.to === to);
  expect(edge(FLEET.console.name, FLEET.leg.name)).toMatchObject({ n: 2, unacked: 1, kinds: { ruling: 1, data: 1 } });
  expect(edge(FLEET.leg.name, FLEET.console.name)).toMatchObject({ n: 1, unacked: 0, kinds: { report: 1 } });
  expect(typeof edge(FLEET.console.name, FLEET.leg.name).lastAt).toBe("number");
  const by = Object.fromEntries(b.sessions.map((s: any) => [s.name, s]));
  expect(by[FLEET.leg.name].bus).toEqual({ unacked: 1, undelivered: 2, unbound: true });
  expect(by[FLEET.console.name].bus).toEqual({ unacked: 0, undelivered: 1, unbound: true });
  expect(by[FLEET.idle.name].bus).toEqual({ unacked: 0, undelivered: 0, unbound: false });
  // metadata only: no body or summary text reaches the fleet
  expect(JSON.stringify(b.edges)).not.toMatch(/GO 1|just words|READY|summary/);
});

test("an ack from the recipient clears the unacked count", async () => {
  const { port, root } = await boot(true);
  writeFileSync(join(root, "ack", `${FLEET.leg.name}.jsonl`), JSON.stringify({ i: "M1", re: "Z", t: Date.now() }) + "\n");
  const b = await fleet(port);
  expect(b.edges.find((e: any) => e.from === FLEET.console.name).unacked).toBe(0);
  expect(b.sessions.find((s: any) => s.name === FLEET.leg.name).bus.unacked).toBe(0);
});

test("no bus store: no edges and zero counts, and nothing is created", async () => {
  const { port, dir } = await boot(false);
  const b = await fleet(port);
  expect(b.edges).toEqual([]);
  expect(b.sessions.every((s: any) => s.bus.unacked === 0 && s.bus.undelivered === 0 && s.bus.unbound === false)).toBe(true);
  expect(existsSync(join(dir, "state", "himmel"))).toBe(false);
});
