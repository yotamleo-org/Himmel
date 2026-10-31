// projects.ts — the projects behind the Health page's picker and its all-projects view.
// The list is the handover registry (~/.claude/handover/registry.json, repos{name:{path}}); a project's checks come
// from its own last good doctor feed, cached under ~/.himmel/state/config-ui/feeds/<name>.json by the UI that ran in it.
// Nothing here runs a doctor: a project nobody opened yet is "not checked", never guessed.
// ponytail: another project's rows are only as fresh as its own last UI run, a cross-project probe is a later step.
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

type Env = Record<string, string | undefined>;
export type Project = { name: string; path: string };
export type Slim = { id: string; health: string; scope: string; installed: { detail: string }; fix: { by?: string; tile?: string; remedy?: string } };
export type Summary = {
  name: string; path: string; current: boolean; checkedAt: string | null;
  counts: { project: { fail: number; warn: number }; shared: { fail: number; warn: number } }; broken: Slim[];
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
  const name = NAME.test(basename(currentPath)) ? basename(currentPath) : "this-project";
  list.unshift({ name, path: currentPath });
  return { current: name, list };
}

const cacheFile = (env: Env, name: string) => join(feedsDir(env), `${name}.json`);
export function saveFeed(env: Env, name: string, body: string): void {
  if (!NAME.test(name)) return;
  try { mkdirSync(feedsDir(env), { recursive: true }); writeFileSync(cacheFile(env, name), body); } catch { /* the cache is best effort */ }
}
export function loadFeed(env: Env, list: Project[], name: string): { body: string; at: string } | null {
  if (!list.some((p) => p.name === name)) return null; // only a registered name reaches the filesystem
  try { return { body: readFileSync(cacheFile(env, name), "utf8"), at: statSync(cacheFile(env, name)).mtime.toISOString() }; } catch { return null; }
}

const count = (rows: Slim[]) => ({ fail: rows.filter((r) => r.health === "fail").length, warn: rows.filter((r) => r.health === "warn").length });
export function summarize(p: Project, current: boolean, cached: { body: string; at: string } | null): Summary {
  const zero = { fail: 0, warn: 0 };
  const base = { name: p.name, path: p.path, current };
  let rows: Slim[] = [];
  try { rows = (JSON.parse(cached?.body ?? "{}").rows ?? []) as Slim[]; } catch { return { ...base, checkedAt: null, counts: { project: zero, shared: zero }, broken: [] }; }
  if (!cached) return { ...base, checkedAt: null, counts: { project: zero, shared: zero }, broken: [] };
  const bad = rows.filter((r) => r.health === "fail" || r.health === "warn");
  const mine = bad.filter((r) => r.scope !== "shared"), shared = bad.filter((r) => r.scope === "shared");
  const slim = (r: Slim): Slim => ({ id: r.id, health: r.health, scope: r.scope, installed: { detail: r.installed?.detail ?? "" }, fix: { by: r.fix?.by, tile: r.fix?.tile, remedy: r.fix?.remedy } });
  return { ...base, checkedAt: cached.at, counts: { project: count(mine), shared: count(shared) }, broken: mine.map(slim) };
}
