// tool-inventory.ts — the read-only station scan behind GET /api/tool-inventory (build spec 0.4 c).
// It lists which tools the station has: settings hooks, plugins and their items, project and user .claude/,
// MCP server KEYS (never an env value, arg or URL), the CLIs on PATH and the size of rtk's history.db.
// Each source is {state: ok|absent|error, found}: a missing file is absent with found null, never 0.
// Nothing here writes; the only process it runs is `<cli> --version`.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

type Env = Record<string, string | undefined>;
type State = "ok" | "absent" | "error";
type Read = { state: State; v?: any };
export type Source = { id: string; reads: string; state: State; reason?: string; found: Record<string, number> | null };
export type InvTool = { kind: string; source: string; name: string; configured_in?: string[]; loads_in_chief?: boolean; off_here?: boolean };
export type InvHook = { kind: "hook"; source: string; name: string; wired: [string, string][]; runs_twice: boolean };
export type Cli = { name: string; path: string | null; version: string | null; state: State };
export type Inventory = { state: State; scanned_at: string; sources: Source[]; tools: InvTool[]; hooks: InvHook[]; clis: Cli[] };

export const CLIS = ["rtk", "qmd", "graphify", "gh", "bun", "node", "codex", "skillspector"];
const RUNNERS = new Set(["run-hook-with-bash.js", "run-node.sh"]);
const SCRIPT = /^[\w.-]+\.(?:sh|bash|js|mjs|cjs|py|ts)$/;
const NAME = /^[\w.:-]{1,120}$/;

function readJson(file: string): Read {
  let text: string;
  try { text = readFileSync(file, "utf8"); } catch { return { state: "absent" }; }
  try { return { state: "ok", v: JSON.parse(text) }; } catch { return { state: "error" }; }
}
const isObj = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
const ls = (dir: string) => { try { return readdirSync(dir).filter((n) => NAME.test(n)).sort(); } catch { return []; } };
const isFile = (file: string) => { try { return statSync(file).isFile(); } catch { return false; } };
const stem = (n: string) => n.replace(/\.[^.]+$/, "");
const mcpKeys = (v: unknown) => isObj(v) && isObj(v.mcpServers) ? Object.keys(v.mcpServers).filter((k) => NAME.test(k)) : [];

// The hook scripts of one settings "hooks" object: basenames only, the chain runners left out.
function wirings(hooks: unknown) {
  const out: { event: string; matcher: string; scripts: string[] }[] = [];
  if (!isObj(hooks)) return out;
  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) for (const h of isObj(g) && Array.isArray(g.hooks) ? g.hooks : []) {
      if (!isObj(h) || typeof h.command !== "string") continue;
      const scripts = [...new Set(h.command.split(/[\s"'`;|&()]+/).map((t: string) => basename(t)).filter((b: string) => SCRIPT.test(b) && !RUNNERS.has(b)))] as string[];
      out.push({ event, matcher: typeof g.matcher === "string" && g.matcher ? g.matcher : "*", scripts });
    }
  }
  return out;
}

function cliRow(name: string, env: Env, home: string): Cli {
  const path = Bun.which(name, { PATH: env.PATH ?? "" });
  if (!path) return { name, path: null, version: null, state: "absent" };
  const shown = path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
  try {
    const r = Bun.spawnSync([path, "--version"], { env: { PATH: env.PATH ?? "", HOME: home }, stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: 5000 });
    const line = r.exitCode === 0 ? r.stdout.toString().split("\n")[0].trim() : "";
    const version = line.replace(new RegExp(`^${name}\\b`, "i"), "").replace(/^\s*version\b/i, "").trim().slice(0, 60);
    return version ? { name, path: shown, version, state: "ok" } : { name, path: shown, version: null, state: "error" };
  } catch { return { name, path: shown, version: null, state: "error" }; }
}

export function scanToolInventory(env: Env, now: number): Inventory {
  const home = env.HOME || homedir(), repo = env.HIMMEL_REPO || process.cwd(), claude = join(home, ".claude");
  const sources: Source[] = [], tools: InvTool[] = [], hookRows = new Map<string, InvHook>();
  const source = (id: string, reads: string, state: State, found: Record<string, number> | null, reason?: string) =>
    sources.push({ id, reads, state, ...(reason ? { reason } : {}), found: state === "ok" ? found : null });
  const addHooks = (src: string, list: ReturnType<typeof wirings>) => {
    for (const w of list) for (const name of w.scripts) {
      const key = `${src}\0${name}`, row = hookRows.get(key) || { kind: "hook" as const, source: src, name, wired: [], runs_twice: false };
      if (!row.wired.some(([e, m]) => e === w.event && m === w.matcher)) row.wired.push([w.event, w.matcher]);
      hookRows.set(key, row);
    }
  };

  // Settings hooks: project, then user.
  const settings: Record<string, Read> = { project: readJson(join(repo, ".claude", "settings.json")), user: readJson(join(claude, "settings.json")) };
  for (const scope of ["project", "user"]) {
    const s = settings[scope], list = s.state === "ok" ? wirings(s.v?.hooks) : [];
    if (s.state === "ok") addHooks(scope, list);
    source(`hooks-${scope}`, scope === "project" ? "$HIMMEL_REPO/.claude/settings.json → .hooks" : "~/.claude/settings.json → .hooks", s.state,
      { wirings: list.length, scripts: new Set(list.flatMap((w) => w.scripts)).size });
  }

  // Plugins: installed, then enabled (user settings, a project setting wins).
  const installed = readJson(join(claude, "plugins", "installed_plugins.json"));
  const enabled: Record<string, boolean> = {};
  for (const scope of ["user", "project"]) { const e = settings[scope].v?.enabledPlugins; if (isObj(e)) for (const [id, on] of Object.entries(e)) enabled[id] = on === true; }
  const plugins = installed.state === "ok" && isObj(installed.v?.plugins) ? installed.v.plugins : {};
  const ids = Object.keys(plugins).filter((id) => /^[\w.-]+@[\w.-]+$/.test(id)).sort();
  const pathOf = (id: string) => { const e = Array.isArray(plugins[id]) ? plugins[id].filter((x: any) => isObj(x) && typeof x.installPath === "string") : []; return e.length ? e[e.length - 1].installPath as string : null; };
  const on = ids.filter((id) => enabled[id] && pathOf(id));
  source("plugins", "~/.claude/plugins/installed_plugins.json · ~/.claude/settings.json → .enabledPlugins", installed.state, { on: on.length, installed: ids.length });
  const items = { skills: 0, commands: 0, agents: 0, hook_wirings: 0 }, pluginMcp = new Map<string, string>();
  let offMcp = 0;
  for (const id of ids) {
    const dir = pathOf(id);
    if (!dir) continue;
    const servers = new Set([...mcpKeys(readJson(join(dir, ".mcp.json")).v), ...mcpKeys(readJson(join(dir, ".claude-plugin", "plugin.json")).v)]);
    if (!on.includes(id)) { offMcp += servers.size; continue; }
    const plugin = id.split("@")[0];
    const skills = [...ls(join(dir, "skills")).filter((n) => isFile(join(dir, "skills", n, "SKILL.md"))), ...(isFile(join(dir, "SKILL.md")) ? [plugin] : [])];
    for (const n of new Set(skills)) { tools.push({ kind: "skill", source: id, name: `${plugin}:${n}` }); items.skills++; }
    for (const n of ls(join(dir, "commands")).filter((n) => n.endsWith(".md"))) { tools.push({ kind: "cmd", source: id, name: `${plugin}:${stem(n)}` }); items.commands++; }
    for (const n of ls(join(dir, "agents")).filter((n) => n.endsWith(".md"))) { tools.push({ kind: "agent", source: id, name: `${plugin}:${stem(n)}` }); items.agents++; }
    const hooks = readJson(join(dir, "hooks", "hooks.json")), list = hooks.state === "ok" ? wirings(hooks.v?.hooks) : [];
    addHooks(id, list); items.hook_wirings += list.length;
    for (const s of servers) if (!pluginMcp.has(s)) pluginMcp.set(s, id);
  }
  source("plugin-items", "<installPath>/skills/*/SKILL.md · commands/*.md · agents/*.md · hooks/hooks.json", installed.state, items);

  // Project and user .claude/.
  const local = (root: string, src: string, skillDirs: string[], withWorkflows: boolean) => {
    const skills = new Set(skillDirs.flatMap((d) => ls(d).filter((n) => isFile(join(d, n, "SKILL.md")))));
    const commands = ls(join(root, "commands")).filter((n) => n.endsWith(".md")).map(stem), agents = ls(join(root, "agents")).filter((n) => n.endsWith(".md")).map(stem);
    const workflows = withWorkflows ? ls(join(root, "workflows")).filter((n) => isFile(join(root, "workflows", n))).map(stem) : [];
    for (const n of skills) tools.push({ kind: "skill", source: src, name: n });
    for (const n of commands) tools.push({ kind: "cmd", source: src, name: n });
    for (const n of agents) tools.push({ kind: "agent", source: src, name: n });
    for (const n of workflows) tools.push({ kind: "wf", source: src, name: n });
    return { skills: skills.size, commands: commands.length, agents: agents.length, ...(withWorkflows ? { workflows: workflows.length } : {}) };
  };
  const projectDir = join(repo, ".claude");
  source("project-claude", "$HIMMEL_REPO/.claude/skills/*/SKILL.md · commands/*.md · agents/*.md · workflows/*", existsSync(projectDir) ? "ok" : "absent",
    existsSync(projectDir) ? local(projectDir, "project", [join(projectDir, "skills")], true) : null);
  const synced = ls(join(claude, "skills", "synced")).map((b) => join(claude, "skills", "synced", b));
  source("user-claude", "~/.claude/skills/synced/<bucket>/<name>/SKILL.md · ~/.claude/skills/*/SKILL.md · commands/*.md · agents/*.md", existsSync(claude) ? "ok" : "absent",
    existsSync(claude) ? local(claude, "user", [join(claude, "skills"), ...synced], false) : null);

  // MCP servers, keys only.
  const configured = new Map<string, Set<string>>();
  const note = (server: string, src: string) => { const s = configured.get(server) || new Set(); s.add(src); configured.set(server, s); };
  const user = readJson(join(home, ".claude.json"));
  const userServers = user.state === "ok" ? mcpKeys(user.v) : [];
  const disabled = new Set<string>(user.state === "ok" && isObj(user.v.projects) && isObj(user.v.projects[repo]) && Array.isArray(user.v.projects[repo].disabledMcpServers)
    ? user.v.projects[repo].disabledMcpServers.filter((k: unknown) => typeof k === "string") : []);
  for (const k of userServers) note(k, "mcp-user");
  source("mcp-user", "~/.claude.json → .mcpServers keys · .projects[$HIMMEL_REPO].disabledMcpServers", user.state, { servers: userServers.length, off_here: userServers.filter((k) => disabled.has(k)).length });
  const profileRoot = join(home, ".himmel", "launch-profiles"), profileDirs = ls(profileRoot).filter((n) => n.startsWith("mcp-"));
  let profileState: State = profileDirs.length ? "ok" : "absent";
  const profileServers = new Set<string>();
  for (const d of profileDirs) for (const f of ls(join(profileRoot, d)).filter((n) => n.endsWith(".mcp.json"))) {
    const r = readJson(join(profileRoot, d, f));
    if (r.state === "error") profileState = "error";
    for (const k of mcpKeys(r.v)) profileServers.add(k);
  }
  if (profileState === "ok") for (const k of profileServers) note(k, "mcp-profiles");
  source("mcp-profiles", "~/.himmel/launch-profiles/mcp-*/<profile>.mcp.json → .mcpServers keys", profileState, { servers: profileServers.size, profiles: profileDirs.length });
  const project = readJson(join(repo, ".mcp.json")), projectServers = project.state === "ok" ? mcpKeys(project.v) : [];
  for (const k of projectServers) note(k, "mcp-project");
  source("mcp-project", "$HIMMEL_REPO/.mcp.json", project.state, { servers: projectServers.length });
  for (const k of pluginMcp.keys()) note(k, "mcp-plugins");
  source("mcp-plugins", "<installPath>/.mcp.json · .claude-plugin/plugin.json → .mcpServers keys", installed.state, { on: pluginMcp.size, off: offMcp });
  for (const [server, from] of [...configured].sort(([a], [b]) => a.localeCompare(b))) {
    const list = ["mcp-user", "mcp-profiles", "mcp-project", "mcp-plugins"].filter((s) => from.has(s));
    tools.push({ kind: "mcp", source: list.some((s) => s !== "mcp-plugins") ? "mcp-config" : pluginMcp.get(server)!, name: server,
      configured_in: list, loads_in_chief: from.has("mcp-profiles"), off_here: disabled.has(server) });
  }
  source("mcp-runtime", "a live session's tool list (mcp__<server>__*)", "absent", null, "source unknown: read from recorded calls");
  source("core", "a recorded session's tool, skill and agent lists", "absent", null, "needs a session record");

  const clis = CLIS.map((name) => cliRow(name, env, home));
  source("clis", "command -v <cli> · <cli> --version (5 s timeout)", clis.some((c) => c.state !== "absent") ? "ok" : "absent",
    { found: clis.filter((c) => c.state !== "absent").length, missing: clis.filter((c) => c.state === "absent").length });
  const db = join(home, ".local", "share", "rtk", "history.db");
  let bytes: number | null = null;
  try { bytes = statSync(db).size; } catch { /* absent */ }
  source("rtk-history", "~/.local/share/rtk/history.db, opened read-only", bytes === null ? "absent" : "ok", { bytes: bytes ?? 0 });

  // A hook script wired in more than one place runs twice on the same call.
  const hooks = [...hookRows.values()];
  for (const h of hooks) h.runs_twice = hooks.some((x) => x.name === h.name && x.source !== h.source);
  const state: State = sources.some((s) => s.state === "ok") ? "ok" : sources.some((s) => s.state === "error") ? "error" : "absent";
  return { state, scanned_at: new Date(now).toISOString(), sources, tools, hooks: hooks.sort((a, b) => a.source.localeCompare(b.source) || a.name.localeCompare(b.name)), clis };
}

// One scan per station, re-read on ?rescan=1 (as /api/feed?refresh=1 does).
const cache = new Map<string, Inventory>();
export function readToolInventory(env: Env, now: number, rescan = false): Inventory {
  const key = `${env.HOME || homedir()}\0${env.HIMMEL_REPO || process.cwd()}`;
  if (rescan || !cache.has(key)) cache.set(key, scanToolInventory(env, now));
  return cache.get(key)!;
}
