// Served from a git worktree, `config set` must write the station's files (the primary checkout's .env and
// lanes.local.json), where the feed and the live hooks read, not the worktree's. The server hands every config.*
// child HIMMELCTL_REPO_ROOT = the primary; an operator-set HIMMELCTL_REPO_ROOT still wins.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const TOKEN = "t".repeat(64);
let dir = "", primary = "", wt = "", argvFile = "", state = "", home = "";
const stops: (() => void)[] = [];
const git = (cwd: string, ...a: string[]) => execFileSync("git", ["-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t", ...a], { stdio: "ignore" });

beforeAll(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "cfgui-wtstation-")));
  primary = join(dir, "primary"); wt = join(dir, "wt"); home = join(dir, "home"); state = join(dir, "state"); argvFile = join(dir, "argv");
  for (const d of [join(primary, "scripts/lanes"), join(primary, "docs/setup"), home, state]) mkdirSync(d, { recursive: true });
  writeFileSync(join(primary, "scripts/lanes/lanes.json"), JSON.stringify({ lanes: [{ id: "l1" }] }));
  writeFileSync(join(primary, "docs/setup/settings-template.json"), JSON.stringify({ onDemandPlugins: {} }));
  git(primary, "init", "-q", "-b", "main");
  git(primary, "add", "-A");
  git(primary, "commit", "-q", "-m", "fixture");
  git(primary, "worktree", "add", "-q", wt, "-b", "wt-branch");
});
afterAll(() => { while (stops.length) stops.pop()!(); rmSync(dir, { recursive: true, force: true }); });

async function toggle(root: string, extra: Record<string, string> = {}) {
  writeFileSync(argvFile, "");
  const env = { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-env-recorder.js"),
    STUB_ARGV: argvFile, STUB_STATE: state, CONFIG_UI_IDLE_MS: "60000", ...extra };
  const s = startServer({ port: 0, token: TOKEN, env, root } as never);
  stops.push(() => s.stop());
  const post = (path: string, body: unknown) => fetch(`http://127.0.0.1:${s.port}${path}`, {
    method: "POST", body: JSON.stringify(body),
    headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" },
  });
  const req = { action: "config.initiative", target: "execute", value: "on" };
  const pv = await post("/api/preview", req);
  const pj = await pv.json();
  expect(pv.status, JSON.stringify(pj)).toBe(200);
  const r = await post("/api/run", { previewId: pj.previewId, ...req });
  expect(r.status).toBe(200);
  return readFileSync(argvFile, "utf8").split("\n").filter((l) => l.includes("config set"));
}

test("served from a worktree, preview and run both set HIMMELCTL_REPO_ROOT to the primary checkout", async () => {
  expect(await toggle(wt)).toEqual([
    `${primary} config set initiative.execute on --dry-run`,
    `${primary} config set initiative.execute on`,
  ]);
});

test("served from the primary itself, the root is the primary", async () => {
  expect((await toggle(primary)).every((l) => l.startsWith(`${primary} `))).toBe(true);
});

test("an operator-set HIMMELCTL_REPO_ROOT still wins", async () => {
  expect((await toggle(wt, { HIMMELCTL_REPO_ROOT: "/operator/root" })).every((l) => l.startsWith("/operator/root "))).toBe(true);
});
