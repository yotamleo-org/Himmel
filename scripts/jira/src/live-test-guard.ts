// The live-test guard: the Jira test project setting, the HIMMEL_JIRA_LIVE_TEST marker and its own-key
// grammar, and the loopback / unreachable URL tests.
// Imports env-file.ts only, never client.ts, so client.ts can call the guard without an import cycle.
import { readFileSync, readlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { readEnvFile, underTest } from './env-file.js';

const PROJECT_KEY = /^[A-Z][A-Z0-9]+$/;
const OWN_KEYS = /^([A-Z][A-Z0-9]+-[0-9]+)(,[A-Z][A-Z0-9]+-[0-9]+)*$/;

/** The marker value's grammar: `none`, or a comma list of ticket keys. null = malformed. */
export function parseOwnKeys(value: string): string[] | null {
  if (value === 'none') return [];
  return OWN_KEYS.test(value) ? value.split(',') : null;
}

/** Keys read from the two station files only: himmel.conf.local, then himmel.conf. */
function stationFiles(configDir: string, keys: string[]): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const file of ['himmel.conf.local', 'himmel.conf']) readEnvFile(join(configDir, file), new Set(keys), env);
  return env;
}

/** JIRA_TEST_PROJECT (or `candidate`), valid only when it is a project key and not a work project. */
export function resolveTestProject(configDir: string, candidate?: string): { testProject: string | null; problem: string | null } {
  const station = stationFiles(configDir, ['JIRA_TEST_PROJECT', 'JIRA_PROJECTS', 'JIRA_PROJECT_KEY']);
  const key = candidate ?? station.JIRA_TEST_PROJECT;
  if (!key) return { testProject: null, problem: 'no JIRA_TEST_PROJECT is set in himmel.conf or himmel.conf.local' };
  if (!PROJECT_KEY.test(key)) return { testProject: null, problem: `${key} is not a Jira project key (^[A-Z][A-Z0-9]+$)` };
  const work = (station.JIRA_PROJECTS ?? '').split(',').map((k) => k.trim());
  if (work.includes(key)) return { testProject: null, problem: `${key} is a work project (JIRA_PROJECTS)` };
  if (station.JIRA_PROJECT_KEY === key) return { testProject: null, problem: `${key} is a work project (the station JIRA_PROJECT_KEY)` };
  return { testProject: key, problem: null };
}

/** `_csg_is_claude`'s three rules (scripts/lib/chokepoint-seam-guard.sh): plain, native versioned, npm. */
export function isClaudeProc(procRoot: string, pid: number): boolean {
  let exe = '';
  try {
    exe = readlinkSync(join(procRoot, String(pid), 'exe'));
  } catch {
    // no exe link: argv decides
  }
  if (basename(exe) === 'claude' || exe.includes('/claude/versions/')) return true;
  let argv: string[] = [];
  try {
    argv = readFileSync(join(procRoot, String(pid), 'cmdline'), 'utf8').split('\0');
  } catch {
    return false;
  }
  const [a0 = '', a1 = ''] = argv;
  if (a0 && basename(a0) === 'claude') return true;
  return basename(a0) === 'node' && /\/@anthropic-ai\/claude-code\/cli\.m?js$/.test(a1);
}

const dirOf = (env: NodeJS.ProcessEnv): string | null =>
  env.HIMMEL_CONFIG_DIR || (env.HOME ? join(env.HOME, '.himmel') : null);

function parentOf(procRoot: string, pid: number): number | 'gone' | 'malformed' {
  let status: string;
  try {
    status = readFileSync(join(procRoot, String(pid), 'status'), 'utf8');
  } catch {
    return 'gone';
  }
  const m = /^PPid:\s*(\d+)\s*$/m.exec(status);
  return m ? Number(m[1]) : 'malformed';
}

function environOf(procRoot: string, pid: number): NodeJS.ProcessEnv | null {
  try {
    const env: NodeJS.ProcessEnv = {};
    for (const kv of readFileSync(join(procRoot, String(pid), 'environ'), 'utf8').split('\0')) {
      const i = kv.indexOf('=');
      if (i > 0) env[kv.slice(0, i)] = kv.slice(i + 1);
    }
    return env;
  } catch {
    return null;
  }
}

/**
 * Is this process a live test? The marker is the union of the own env and every claude ancestor's
 * exec-time environ; the own keys are the intersection of every value present (`none` or a malformed
 * value adds the empty set). The config dir is the outermost marked ancestor's, else the own env's.
 * A malformed status or an unreadable claude environ is marked with no keys and no config dir; a
 * vanished ancestor ends the walk. Under the vitest harness (underTest(env)) the walk is skipped.
 */
export function liveTestContext(opts: { procRoot?: string; env?: NodeJS.ProcessEnv; pid?: number } = {}): {
  set: boolean; ownKeys: string[]; configDir: string | null;
} {
  const env = opts.env ?? process.env;
  const procRoot = opts.procRoot ?? '/proc';
  const values: string[] = [];
  let configDir: string | null = null;
  let failed = false;
  if (env.HIMMEL_JIRA_LIVE_TEST) {
    values.push(env.HIMMEL_JIRA_LIVE_TEST);
    configDir = dirOf(env);
  }
  if (!underTest(env)) {
    let next = parentOf(procRoot, opts.pid ?? process.pid);
    while (typeof next === 'number' && next > 0) {
      const pid = next;
      next = parentOf(procRoot, pid);
      if (next === 'gone') break;
      if (!isClaudeProc(procRoot, pid)) continue;
      const theirs = environOf(procRoot, pid);
      if (!theirs) { failed = true; continue; }
      if (!theirs.HIMMEL_JIRA_LIVE_TEST) continue;
      values.push(theirs.HIMMEL_JIRA_LIVE_TEST);
      configDir = dirOf(theirs);
    }
    if (next === 'malformed') failed = true;
  }
  if (failed) return { set: true, ownKeys: [], configDir: null };
  if (values.length === 0) return { set: false, ownKeys: [], configDir: null };
  const sets = values.map((v) => parseOwnKeys(v) ?? []);
  return { set: true, ownKeys: sets[0].filter((k) => sets.every((s) => s.includes(k))), configDir };
}

/** The one config dir every test-project question reads: marked, the context's; else the loadEnvFile rule. */
export function testProjectConfigDir(env: NodeJS.ProcessEnv = process.env): string | null {
  const ctx = liveTestContext({ env });
  if (ctx.set) return ctx.configDir;
  return env.HIMMEL_CONFIG_DIR || join(env.HOME || homedir(), '.himmel');
}

/** Is `project` the configured test project (read from testProjectConfigDir())? */
export function isTestProject(project: string): boolean {
  const dir = testProjectConfigDir();
  return dir !== null && resolveTestProject(dir).testProject === project;
}

const hostOf = (url: string): string | null => {
  try {
    return new URL(url).hostname;
  } catch {
    return null;
  }
};

/** A loopback Jira is a local stub: it cannot reach the real one. */
export function jiraIsLoopback(url: string): boolean {
  const host = hostOf(url);
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
}

/** Loopback or a `.invalid` host: no real Jira answers there. Only liveTestGuard asks this. */
export function jiraIsUnreachable(url: string): boolean {
  return jiraIsLoopback(url) || (hostOf(url) ?? '').endsWith('.invalid');
}
