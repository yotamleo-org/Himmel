// GET /api/tool-inventory (build spec 0.4 c): a read-only station scan over a temp HOME and repo.
// Each source is present, absent or malformed on its own; no env value, MCP arg or secret reaches the output.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { startServer } from "../server";

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
const put = (file: string, text: string) => { mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, text); };
const json = (file: string, v: unknown) => put(file, JSON.stringify(v));

function station() {
  const dir = mkdtempSync(join(tmpdir(), "tool-inventory-")); dirs.push(dir);
  const home = join(dir, "home"), repo = join(dir, "repo"), plugins = join(dir, "plugins");
  json(join(home, ".claude", "settings.json"), {
    enabledPlugins: { "alpha@mk": true, "beta@mk": false },
    hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "bash $HOME/.claude/hooks/user-guard.sh --token=SECRET-ARG-1" }] }] },
  });
  json(join(repo, ".claude", "settings.json"), { hooks: {
    PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "node scripts/hooks/run-hook-with-bash.js --chain scripts/hooks/read-clamp.sh scripts/hooks/user-guard.sh" }] }],
    PostToolUse: [{ matcher: "Edit|Write", hooks: [{ type: "command", command: "bash scripts/hooks/post-edit.sh SECRET-ARG-2" }] }],
  } });
  json(join(home, ".claude", "plugins", "installed_plugins.json"), { version: 2, plugins: {
    "alpha@mk": [{ scope: "user", installPath: join(plugins, "alpha"), version: "1.0.0" }],
    "beta@mk": [{ scope: "user", installPath: join(plugins, "beta"), version: "2.0.0" }],
  } });
  put(join(plugins, "alpha", "skills", "one", "SKILL.md"), "---\nname: one\n---\n");
  put(join(plugins, "alpha", "commands", "go.md"), "go");
  put(join(plugins, "alpha", "agents", "helper.md"), "helper");
  json(join(plugins, "alpha", "hooks", "hooks.json"), { hooks: { SessionStart: [{ hooks: [{ type: "command", command: "${CLAUDE_PLUGIN_ROOT}/hooks/start.sh" }] }] } });
  json(join(plugins, "alpha", ".mcp.json"), { mcpServers: { "alpha-srv": { command: "x", env: { TOKEN: "SECRET-ENV-1" } } } });
  put(join(plugins, "beta", "skills", "two", "SKILL.md"), "---\nname: two\n---\n");
  json(join(plugins, "beta", ".mcp.json"), { mcpServers: { "beta-srv": {} } });
  put(join(repo, ".claude", "skills", "handover", "SKILL.md"), "x");
  put(join(repo, ".claude", "commands", "c1.md"), "x");
  put(join(repo, ".claude", "agents", "judge.md"), "x");
  put(join(repo, ".claude", "workflows", "nightly.yml"), "x");
  put(join(repo, ".mcp.json"), "{ not json");
  put(join(home, ".claude", "skills", "synced", "b1", "s-sync", "SKILL.md"), "x");
  put(join(home, ".claude", "commands", "u.md"), "x");
  json(join(home, ".claude.json"), {
    oauthAccount: { accessToken: "SECRET-OAUTH" },
    mcpServers: { graphify: { args: ["SECRET-ARG-3"], env: { K: "SECRET-ENV-2" } }, context7: { url: "https://SECRET-URL.invalid" } },
    projects: { [repo]: { disabledMcpServers: ["context7"] } },
  });
  json(join(home, ".himmel", "launch-profiles", "mcp-aaa", "console.mcp.json"), { mcpServers: { qmd: { env: { Q: "SECRET-ENV-3" } }, "himmel-bus": {} } });
  json(join(home, ".himmel", "launch-profiles", "mcp-bbb", "chief.mcp.json"), { mcpServers: { qmd: {} } });
  put(join(home, "bin", "rtk"), "#!/bin/sh\necho 'rtk 9.9.9'\n"); chmodSync(join(home, "bin", "rtk"), 0o755);
  return { home, repo, env: { HOME: home, HIMMEL_REPO: repo, PATH: join(home, "bin") } };
}

test("each source reads present, absent or malformed on its own, with counts and no secret", async () => {
  const { scanToolInventory } = await import("../tool-inventory");
  const { env } = station();
  const inv = scanToolInventory(env, Date.parse("2026-11-01T04:00:00Z"));
  expect(inv.state).toBe("ok");
  expect(inv.scanned_at).toBe("2026-11-01T04:00:00.000Z");
  const src = Object.fromEntries(inv.sources.map((s: any) => [s.id, s]));
  expect(src["hooks-project"]).toMatchObject({ state: "ok", found: { wirings: 2, scripts: 3 } });
  expect(src["hooks-user"]).toMatchObject({ state: "ok", found: { wirings: 1, scripts: 1 } });
  expect(src.plugins).toMatchObject({ state: "ok", found: { on: 1, installed: 2 } });
  expect(src["plugin-items"]).toMatchObject({ state: "ok", found: { skills: 1, commands: 1, agents: 1, hook_wirings: 1 } });
  expect(src["mcp-plugins"]).toMatchObject({ state: "ok", found: { on: 1, off: 1 } });
  expect(src["project-claude"]).toMatchObject({ state: "ok", found: { skills: 1, commands: 1, agents: 1, workflows: 1 } });
  expect(src["user-claude"]).toMatchObject({ state: "ok", found: { skills: 1, commands: 1, agents: 0 } });
  expect(src["mcp-user"]).toMatchObject({ state: "ok", found: { servers: 2, off_here: 1 } });
  expect(src["mcp-profiles"]).toMatchObject({ state: "ok", found: { servers: 2, profiles: 2 } });
  expect(src["mcp-project"]).toMatchObject({ state: "error", found: null });
  expect(src["rtk-history"]).toMatchObject({ state: "absent", found: null });
  expect(src.core).toMatchObject({ state: "absent", reason: "needs a session record", found: null });
  const tool = (kind: string, name: string) => inv.tools.find((t: any) => t.kind === kind && t.name === name);
  expect(tool("skill", "alpha:one")).toMatchObject({ source: "alpha@mk" });
  expect(tool("skill", "beta:two")).toBeUndefined();
  expect(tool("cmd", "alpha:go")).toMatchObject({ source: "alpha@mk" });
  expect(tool("agent", "alpha:helper")).toMatchObject({ source: "alpha@mk" });
  expect(tool("skill", "handover")).toMatchObject({ source: "project" });
  expect(tool("agent", "judge")).toMatchObject({ source: "project" });
  expect(tool("wf", "nightly")).toMatchObject({ source: "project" });
  expect(tool("skill", "s-sync")).toMatchObject({ source: "user" });
  expect(tool("cmd", "u")).toMatchObject({ source: "user" });
  expect(tool("mcp", "qmd")).toMatchObject({ source: "mcp-config", configured_in: ["mcp-profiles"], loads_in_chief: true });
  expect(tool("mcp", "graphify")).toMatchObject({ configured_in: ["mcp-user"], loads_in_chief: false, off_here: false });
  expect(tool("mcp", "context7")).toMatchObject({ off_here: true });
  expect(tool("mcp", "alpha-srv")).toMatchObject({ source: "alpha@mk", configured_in: ["mcp-plugins"] });
  expect(tool("mcp", "beta-srv")).toBeUndefined();
  const hook = (name: string, source: string) => inv.hooks.find((h: any) => h.name === name && h.source === source);
  expect(hook("user-guard.sh", "user")).toMatchObject({ kind: "hook", wired: [["PreToolUse", "Bash"]], runs_twice: true });
  expect(hook("user-guard.sh", "project")).toMatchObject({ runs_twice: true });
  expect(hook("read-clamp.sh", "project")).toMatchObject({ runs_twice: false });
  expect(hook("post-edit.sh", "project")).toMatchObject({ wired: [["PostToolUse", "Edit|Write"]] });
  expect(hook("start.sh", "alpha@mk")).toMatchObject({ wired: [["SessionStart", "*"]] });
  expect(inv.hooks.some((h: any) => h.name === "run-hook-with-bash.js")).toBe(false);
  expect(inv.clis.find((c: any) => c.name === "rtk")).toEqual({ name: "rtk", path: "~/bin/rtk", version: "9.9.9", state: "ok" });
  expect(inv.clis.find((c: any) => c.name === "qmd")).toEqual({ name: "qmd", path: null, version: null, state: "absent" });
  expect(inv.clis.map((c: any) => c.name)).toEqual(["rtk", "qmd", "graphify", "gh", "bun", "node", "codex", "skillspector"]);
  expect(JSON.stringify(inv)).not.toMatch(/SECRET/);
});

test("a station with no files reads absent everywhere, never zero", async () => {
  const { scanToolInventory } = await import("../tool-inventory");
  const dir = mkdtempSync(join(tmpdir(), "tool-inventory-empty-")); dirs.push(dir);
  const inv = scanToolInventory({ HOME: dir, HIMMEL_REPO: join(dir, "repo"), PATH: "/nonexistent" }, 0);
  expect(inv.state).toBe("absent");
  for (const s of inv.sources) { expect(s.state).toBe("absent"); expect(s.found).toBeNull(); }
  expect(inv.tools).toEqual([]);
  expect(inv.clis.every((c: any) => c.state === "absent")).toBe(true);
});

test("the route is authenticated and GET-only, caches its scan and re-reads on rescan", async () => {
  const token = "b".repeat(64), { env } = station();
  let clock = Date.parse("2026-11-01T04:00:00Z");
  const s = startServer({ port: 0, token, now: () => clock, env: { ...env, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js") } });
  try {
    const url = `http://127.0.0.1:${s.port}/api/tool-inventory`, headers = { "X-Himmel-Token": token };
    expect((await fetch(url)).status).toBe(401);
    expect((await fetch(url, { method: "POST", headers })).status).toBe(405);
    const first = await (await fetch(url, { headers })).json();
    expect(first.scanned_at).toBe("2026-11-01T04:00:00.000Z");
    clock += 60_000;
    expect((await (await fetch(url, { headers })).json()).scanned_at).toBe(first.scanned_at);
    expect((await (await fetch(`${url}?rescan=1`, { headers })).json()).scanned_at).toBe("2026-11-01T04:01:00.000Z");
    expect(JSON.stringify(first)).not.toMatch(/SECRET/);
  } finally { s.stop(); }
});

test("only a chief profile's servers load in chief, and an unreadable file reads error, not absent", async () => {
  const { scanToolInventory } = await import("../tool-inventory");
  const { env, home } = station();
  json(join(home, ".himmel", "launch-profiles", "mcp-ccc", "worker-impl.mcp.json"), { mcpServers: { "worker-only": {} } });
  const userFile = join(home, ".claude.json");
  chmodSync(userFile, 0o000);
  try {
    const inv = scanToolInventory(env, 0);
    expect(inv.tools.find((t: any) => t.kind === "mcp" && t.name === "worker-only")).toMatchObject({ configured_in: ["mcp-profiles"], loads_in_chief: false });
    expect(inv.tools.find((t: any) => t.kind === "mcp" && t.name === "qmd")).toMatchObject({ loads_in_chief: true });
    expect(inv.sources.find((s: any) => s.id === "mcp-user")).toMatchObject({ state: "error" });
  } finally { chmodSync(userFile, 0o644); }
});

test("an unreadable directory reads error with no count, never a scan of zero", async () => {
  const { scanToolInventory } = await import("../tool-inventory");
  const { env, repo, home } = station();
  const dirsOff = [join(repo, ".claude", "commands"), join(home, ".claude", "commands"), join(home, ".himmel", "launch-profiles", "mcp-aaa")];
  for (const d of dirsOff) chmodSync(d, 0o000);
  try {
    const src = Object.fromEntries(scanToolInventory(env, 0).sources.map((s: any) => [s.id, s]));
    for (const id of ["project-claude", "user-claude", "mcp-profiles"]) expect(src[id]).toMatchObject({ state: "error", found: null });
  } finally { for (const d of dirsOff) chmodSync(d, 0o755); }
});
