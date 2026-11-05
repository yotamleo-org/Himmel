// projects.ts — the projects behind the Health page's picker and its all-projects view.
// The list is the handover registry (~/.claude/handover/registry.json, repos{name:{path}}); a project's checks come
// from its own last good doctor feed, cached under ~/.himmel/state/config-ui/feeds/<name>.json by the UI that ran in it.
// Nothing here runs a doctor: a project nobody opened yet is "not checked", never guessed.
// ponytail: another project's rows are only as fresh as its own last UI run, a cross-project probe is a later step.
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

type Env = Record<string, string | undefined>;
export type Project = { name: string; path: string };
export type Slim = { id: string; health: string; scope: string; repo?: string; bundle?: string; installed: { detail: string }; fix: { by?: string; tile?: string; remedy?: string } };
// notes: shared index rows (bundle "search") that are failing. They degrade every project that searches, so each project's line
// names them, but they stay in counts.shared only, never in counts.project (the verdict).
export type Summary = {
  name: string; path: string; current: boolean; checkedAt: string | null;
  counts: { project: { fail: number; warn: number }; shared: { fail: number; warn: number } }; broken: Slim[]; notes: Slim[];
};

const NAME = /^[\w.-]+$/;
const home = (env: Env) => env.HOME || homedir();
export const registryFile = (env: Env) => env.HANDOVER_REGISTRY || join(home(env), ".claude", "handover", "registry.json");
const feedsDir = (env: Env) => join(home(env), ".himmel", "state", "config-ui", "feeds");

// The registered projects, with the one this UI runs in always present (a synthetic entry when it is unregistered).
export function readProjects(env: Env, currentPath: string): { current: string; list: Project[] } {
  const list: Project[] = [];
  try {
    const repos = JSON.parse(readFileSync(registryFile(env), "utf8")).repos;
    for (const [name, v] of Object.entries(repos ?? {})) {
      const path = (v as { path?: unknown })?.path;
      if (NAME.test(name) && typeof path === "string") list.push({ name, path });
    }
  } catch { /* no registry: only this project */ }
  const at = list.find((p) => p.path === currentPath);
  if (at) return { current: at.name, list };
  // The path is part of the name: two unregistered checkouts, or one named like a registered project, never share a cache.
  const id = createHash("sha1").update(currentPath).digest("hex").slice(0, 6);
  let name = `${NAME.test(basename(currentPath)) ? basename(currentPath) : "this-project"}.${id}`;
  while (list.some((p) => p.name === name)) name += "x";
  list.unshift({ name, path: currentPath });
  return { current: name, list };
}

// ---- the Jira projects the Board covers ----
// Enumeration source: the mirror root ~/.himmel/state/jira-mirror, one directory per project key (<KEY>/ holds <KEY>-<n>.md, <KEY>.versions.tsv
// sits beside it). Every such directory is a project on the Board, wherever config-ui is launched. It is narrowed by `--project KEY`
// (repeatable, the startServer `projects` option) or its env twin HIMMEL_BOARD_PROJECTS (comma separated). An explicit
// HIMMEL_JIRA_MIRROR dir relocates one project's mirror (the project JIRA_PROJECT_KEY names, else HIMMEL); it does not hide the others.
export type JiraProject = { key: string; dir: string };
const PROJECT_KEY = /^[A-Z][A-Z0-9]*$/;
export const mirrorRoot = (env: Env) => join(home(env), ".himmel", "state", "jira-mirror");

export function boardProjects(env: Env, narrow?: string[]): JiraProject[] {
  const want = (narrow ?? (env.HIMMEL_BOARD_PROJECTS ?? "").split(/[\s,]+/)).map((k) => k.trim().toUpperCase()).filter(Boolean);
  let all: JiraProject[] = [];
  try {
    all = readdirSync(mirrorRoot(env), { withFileTypes: true }).filter((e) => e.isDirectory() && PROJECT_KEY.test(e.name)).map((e) => ({ key: e.name, dir: join(mirrorRoot(env), e.name) }));
  } catch { /* no mirror root: only an explicit mirror, if any */ }
  if (env.HIMMEL_JIRA_MIRROR) {
    const key = env.JIRA_PROJECT_KEY || "HIMMEL";
    all = [...all.filter((p) => p.key !== key), { key, dir: env.HIMMEL_JIRA_MIRROR }];
  }
  all.sort((a, b) => a.key.localeCompare(b.key));
  return want.length ? all.filter((p) => want.includes(p.key)) : all;
}

const cacheFile = (env: Env, name: string) => join(feedsDir(env), `${name}.json`);
// A row that names the repo it judges (the doctor's C33 and C70) belongs to the project of that repo only. The project's name is
// the repo's, or the repo's plus the ".<id>" an unregistered checkout of it gets (readProjects).
const judges = (name: string, repo: unknown) => typeof repo !== "string" || !repo || name === repo || name.startsWith(`${repo}.`);
export function saveFeed(env: Env, name: string, body: string): void {
  if (!NAME.test(name)) return;
  try {
    const feed = JSON.parse(body);
    if (Array.isArray(feed.rows)) body = JSON.stringify({ ...feed, rows: feed.rows.filter((r: { repo?: unknown } | null) => !r || judges(name, r.repo)) });
  } catch { /* not JSON: stored as is, loadFeed refuses it */ }
  try {
    mkdirSync(feedsDir(env), { recursive: true });
    const tmp = `${cacheFile(env, name)}.${process.pid}.tmp`; // a reader in another UI never sees a half-written feed
    writeFileSync(tmp, body);
    renameSync(tmp, cacheFile(env, name));
  } catch { /* the cache is best effort */ }
}
export function loadFeed(env: Env, list: Project[], name: string): { body: string; at: string } | null {
  if (!list.some((p) => p.name === name)) return null; // only a registered name reaches the filesystem
  try {
    const body = readFileSync(cacheFile(env, name), "utf8");
    if (!Array.isArray(JSON.parse(body).rows)) return null; // a cache that is not a feed is not checked, in the picker and when opened
    return { body, at: statSync(cacheFile(env, name)).mtime.toISOString() };
  } catch { return null; }
}

const count = (rows: Slim[]) => ({ fail: rows.filter((r) => r.health === "fail").length, warn: rows.filter((r) => r.health === "warn").length });
export function summarize(p: Project, current: boolean, cached: { body: string; at: string } | null): Summary {
  const zero = { fail: 0, warn: 0 };
  const base = { name: p.name, path: p.path, current };
  const unchecked: Summary = { ...base, checkedAt: null, counts: { project: zero, shared: zero }, broken: [], notes: [] };
  if (!cached) return unchecked;
  let rows: Slim[];
  try {
    const parsed = JSON.parse(cached.body).rows;
    if (!Array.isArray(parsed)) return unchecked;
    rows = parsed.filter((r) => r && typeof r === "object") as Slim[];
  } catch { return unchecked; }
  const bad = rows.filter((r) => r.health === "fail" || r.health === "warn");
  // a row that judges another project's repo is not this project's (a feed cached before saveFeed dropped them)
  const mine = bad.filter((r) => r.scope !== "shared" && judges(p.name, r.repo)), shared = bad.filter((r) => r.scope === "shared");
  const slim = (r: Slim): Slim => ({ id: r.id, health: r.health, scope: r.scope, bundle: r.bundle, installed: { detail: r.installed?.detail ?? "" }, fix: { by: r.fix?.by, tile: r.fix?.tile, remedy: r.fix?.remedy } });
  return { ...base, checkedAt: cached.at, counts: { project: count(mine), shared: count(shared) }, broken: mine.map(slim), notes: shared.filter((r) => r.bundle === "search").map(slim) };
}
