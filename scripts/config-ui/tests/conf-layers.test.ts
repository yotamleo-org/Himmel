// TRACKER and TICKET_ID_REQUIRED are behaviour keys, so the UI's readers find them in
// ~/.himmel/himmel.conf.local and ~/.himmel/himmel.conf (config-layers.md), not only in the process env or the checkout .env.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { trackerSources } from "../tracker-sources";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), "conf-layers-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project, join(home, ".himmel")]) mkdirSync(d, { recursive: true });
  const conf = join(home, ".himmel", "himmel.conf");
  return { dir, home, root, project, conf };
}
const boot = (s: ReturnType<typeof scratch>, env: Record<string, string> = {}) => {
  const srv = startServer({
    port: 0, token: TOKEN, root: s.root, projectRoot: s.project,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: s.home, HANDOVER_DIR: s.root, HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1", ...env },
    legsScript: join(s.dir, "no-legs.sh"),
  });
  cleanups.push(() => srv.stop());
  return srv.port;
};
const getJson = async (port: number, p: string) => (await fetch(`http://127.0.0.1:${port}${p}`, { headers: { "X-Himmel-Token": TOKEN } })).json();

test("the health mode row reads TRACKER from himmel.conf, with himmel.conf.local over it and the process env over both", async () => {
  const s = scratch();
  writeFileSync(s.conf, "TRACKER=local\n");
  expect((await getJson(boot(s, { FORGE: "none" }), "/api/health")).mode).toMatchObject({ state: "ok", tracker: "local" });
  writeFileSync(`${s.conf}.local`, "TRACKER=none\n");
  expect((await getJson(boot(s, { FORGE: "none" }), "/api/health")).mode).toMatchObject({ state: "ok", tracker: "none" });
  expect((await getJson(boot(s, { FORGE: "none", TRACKER: "local" }), "/api/health")).mode).toMatchObject({ state: "ok", tracker: "local" });
  expect((await getJson(boot(s, { FORGE: "none", TRACKER: "" }), "/api/health")).mode).toMatchObject({ state: "ok", tracker: "none" });
});

test("trackerSources lists github when TRACKER=github is set only in himmel.conf", async () => {
  const s = scratch();
  const gh = join(s.dir, "gh");
  writeFileSync(gh, "#!/bin/sh\nexit 0\n");
  chmodSync(gh, 0o755);
  const env = { PATH: process.env.PATH, HOME: s.home, GH_CMD: gh, HIMMEL_JIRA_MIRROR: join(s.dir, "no-mirror") } as Record<string, string>;
  expect(await trackerSources(env, s.root)).toEqual([]);
  writeFileSync(s.conf, "TRACKER=github\n");
  expect(await trackerSources(env, s.root)).toEqual(["github"]);
});

test("the Setup page's commit rules come from himmel.conf.local over himmel.conf, an empty line reading as unset", async () => {
  const s = scratch();
  writeFileSync(s.conf, "TRACKER=jira\nTICKET_ID_REQUIRED=1\n");
  const port = boot(s);
  expect((await getJson(port, "/api/setup")).commit).toEqual({ tracker: "jira", ticketIdRequired: true });
  writeFileSync(`${s.conf}.local`, "TRACKER=github\nTICKET_ID_REQUIRED=0\n");
  expect((await getJson(port, "/api/setup")).commit).toEqual({ tracker: "github", ticketIdRequired: false });
  writeFileSync(`${s.conf}.local`, "TRACKER=\nTICKET_ID_REQUIRED=\n");
  expect((await getJson(port, "/api/setup")).commit).toEqual({ tracker: "jira", ticketIdRequired: true });
});
