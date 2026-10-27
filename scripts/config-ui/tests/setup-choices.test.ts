// The Setup page's setup choices: the handover root and the luna vault path read from ~/.himmel/himmel.conf (a default
// marked when unset) and written through `himmelctl config set` after a dry-run; the forge is shown as detected, and
// lanes, the plugin set and the auto-ship steps point to their Settings toggles.
import { test, expect, afterEach } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-ignore plain browser ES module, no types
import { renderSetup } from "../public/setup.js";

const STUB = join(import.meta.dir, "stub-recorder.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(conf?: string, origin?: string) {
  const dir = mkdtempSync(join(tmpdir(), "setup-choices-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project"), state = join(dir, "state");
  for (const d of [home, root, project, state]) mkdirSync(d);
  if (conf !== undefined) { mkdirSync(join(home, ".himmel")); writeFileSync(join(home, ".himmel", "himmel.conf"), conf); }
  if (origin !== undefined) {
    execFileSync("git", ["init", "-q", project]);
    if (origin) execFileSync("git", ["-C", project, "remote", "add", "origin", origin]);
  }
  const argvFile = join(dir, "argv");
  writeFileSync(argvFile, "");
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, STUB_ARGV: argvFile, STUB_STATE: state, HIMMEL_SECRETS_KEYRING: "off" },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const post = async (path: string, body: unknown) => {
    const r = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json", origin: base, "x-himmel-token": TOKEN }, body: JSON.stringify(body) });
    return { status: r.status, j: (await r.json()) as Record<string, any> };
  };
  const setup = async () => (await (await fetch(base + "/api/setup", { headers: { "x-himmel-token": TOKEN } })).json()) as Record<string, any>;
  const argv = () => readFileSync(argvFile, "utf8").split("\n").filter(Boolean);
  return { home, post, setup, argv };
}

test("the current handover root and vault path come from himmel.conf, himmel.conf.local over it", async () => {
  const h = boot("HANDOVER_DIR=/srv/state/handovers\nLUNA_VAULT_PATH=/srv/luna\n");
  writeFileSync(join(h.home, ".himmel", "himmel.conf.local"), "LUNA_VAULT_PATH=/srv/luna-here\n");
  const c = (await h.setup()).choices;
  expect(c.paths).toEqual([
    { target: "handover-root", key: "HANDOVER_DIR", value: "/srv/state/handovers", fallback: expect.any(String) },
    { target: "luna-vault", key: "LUNA_VAULT_PATH", value: "/srv/luna-here", fallback: expect.any(String) },
  ]);
});

test("an unset path reads as null with its default named", async () => {
  const paths = (await boot().setup()).choices.paths;
  expect(paths.map((p: any) => p.value)).toEqual([null, null]);
  expect(paths[0].fallback).toMatch(/handovers\//);
  expect(paths[1].fallback).toMatch(/no luna vault/i);
});

test("the forge is detected from the project's origin and shown, never offered as a write", async () => {
  expect((await boot(undefined, "git@github.com:me/repo.git").setup()).choices.forge).toEqual({ value: "github", error: null });
  expect((await boot(undefined, "").setup()).choices.forge).toEqual({ value: "local-git", error: null });
  expect((await boot().setup()).choices.forge).toEqual({ value: "none", error: null });
});

test("the page renders a dry-run form per path, the default marked, the forge read-only and a pointer to Settings", async () => {
  const s = await boot("HANDOVER_DIR=/srv/state/handovers\n", "git@github.com:me/repo.git").setup();
  const html: string = renderSetup(s, {}, {});
  expect(html).toContain("Setup choices");
  expect(html).toMatch(/data-path-form[^>]*data-target="handover-root"/);
  expect(html).toMatch(/data-path-form[^>]*data-target="luna-vault"/);
  expect(html).toContain('value="/srv/state/handovers"');
  expect(html).toMatch(/not set · default/);
  expect(html).toMatch(/Forge[\s\S]*github/);
  expect(html).not.toMatch(/data-target="forge"/);
  expect(html).toMatch(/href="#\/config"[^>]*>[^<]*Settings/);
  for (const g of ["Plugin set", "Review by a second model", "Auto-ship steps"]) expect(html).toContain(g);
});

test("a path change runs its dry-run first, and only the bound preview runs the write", async () => {
  const h = boot();
  const p = await h.post("/api/preview", { action: "config.paths", target: "handover-root", value: "/srv/new handovers" });
  expect(p.status).toBe(200);
  expect(p.j.command).toMatch(/config set handover\.root '\/srv\/new handovers' --dry-run$/);
  expect(h.argv()).toEqual([expect.stringMatching(/config set handover\.root \/srv\/new handovers --dry-run$/)]);
  const other = await h.post("/api/run", { previewId: p.j.previewId, action: "config.paths", target: "handover-root", value: "/srv/other" });
  expect(other.status).toBe(409);
  const r = await h.post("/api/run", { previewId: p.j.previewId, action: "config.paths", target: "handover-root", value: "/srv/new handovers" });
  expect(r.status).toBe(200);
  expect(h.argv().at(-1)).toBe("himmelctl config set handover.root /srv/new handovers");
});

test("a refused path answers 400 and runs nothing", async () => {
  const h = boot();
  for (const value of ["/a\nHIMMEL_INITIATIVE=merge", "relative/dir", "/a/../b", "/a #b", "/a$HOME", "/a'b"]) {
    const p = await h.post("/api/preview", { action: "config.paths", target: "luna-vault", value });
    expect([value, p.status]).toEqual([value, 400]);
  }
  expect(h.argv()).toEqual([]);
  expect(existsSync(join(h.home, ".himmel", "himmel.conf"))).toBe(false);
});
