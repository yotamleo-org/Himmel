import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defaultRoot } from './commands/mirror.js';
import { envFilePath, readEnvFile, underTest } from './env-file.js';

/** The readiness role's own label, loaded on use: an install without the chief kit still starts every other op. */
export async function readinessLabel(): Promise<string> {
  // @ts-expect-error readiness-tools.mjs ships no declaration file
  const tools = await import('../../handover/chief-kit/readiness-tools.mjs');
  return tools.READINESS_LABEL as string;
}

/** The gates a filer must act on: only these label a ticket. */
export const FILER_GATES: ReadonlySet<string> = new Set(['no-proof', 'prose-dependency', 'blocker-no-version']);

const CHECK = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'handover', 'chief-kit', 'next-dispatchable.sh');
const TIMEOUT_MS = 30_000;
const CHECK_DEADLINE_S = '25';
const KILL_GRACE_MS = 2_000;

export interface ReadinessGate { name: string; detail: string }

export interface Readiness {
  exit: number | null;
  gates: ReadinessGate[];
  lines: string[];
  warning?: string;
}

/** Tests only: no production caller names a tree, a mirror or a dispatcher seam. */
export interface ReadinessFixture {
  gitDir: string;
  mainRef: string;
  mirror: string;
  seams?: Record<string, string>;
}

/**
 * The station's own Jira project, from its files only: himmel.conf.local, himmel.conf, then the CLI checkout's .env.
 * Never the process JIRA_PROJECT_KEY, which a cross-project filing sets.
 */
export function ownProject(envPath: string | undefined = underTest() ? undefined : envFilePath()): string | undefined {
  const confDir = process.env.HIMMEL_CONFIG_DIR || join(process.env.HOME || homedir(), '.himmel');
  const keys = new Set(['JIRA_PROJECT_KEY']);
  const found: NodeJS.ProcessEnv = {};
  for (const path of [join(confDir, 'himmel.conf.local'), join(confDir, 'himmel.conf'), ...(envPath ? [envPath] : [])]) {
    readEnvFile(path, keys, found);
  }
  return found.JIRA_PROJECT_KEY || undefined;
}

function checkEnv(project: string, fixture: ReadinessFixture | undefined): NodeJS.ProcessEnv {
  const mine = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('NEXT_DISPATCH_')));
  return {
    ...mine,
    JIRA_PROJECT_KEY: project,
    NEXT_DISPATCH_DEADLINE: CHECK_DEADLINE_S,
    ...(fixture ? { NEXT_DISPATCH_GIT_DIR: fixture.gitDir, NEXT_DISPATCH_MAIN_REF: fixture.mainRef, ...fixture.seams } : {}),
  };
}

interface Ran { exit: number | null; stdout: string; failure?: string }

// SIGTERM goes before SIGKILL so the dispatcher can relay it to the group GNU timeout makes: https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html
function runGroup(args: string[], env: NodeJS.ProcessEnv, ms: number, signal: AbortSignal | undefined): Promise<Ran> {
  return new Promise((resolve) => {
    const child = spawn('bash', args, { detached: true, env, stdio: ['ignore', 'pipe', 'ignore'] });
    let stdout = '';
    let stopped: string | undefined;
    let hard: NodeJS.Timeout | undefined;
    const killGroup = (how: NodeJS.Signals) => {
      if (child.pid === undefined) return;
      try {
        process.kill(-child.pid, how);
      } catch { }
    };
    const stop = (why: string) => {
      if (stopped !== undefined) return;
      stopped = why;
      killGroup('SIGTERM');
      hard = setTimeout(() => {
        killGroup('SIGKILL');
        child.stdout.destroy();
      }, KILL_GRACE_MS);
    };
    const deadline = setTimeout(() => stop(`timed out after ${ms} ms`), ms);
    const onAbort = () => stop('the caller stopped it');
    signal?.addEventListener('abort', onAbort, { once: true });
    const done = (exit: number | null, failure: string | undefined) => {
      clearTimeout(deadline);
      clearTimeout(hard);
      signal?.removeEventListener('abort', onAbort);
      resolve({ exit, stdout, ...(stopped ?? failure ? { failure: stopped ?? failure } : {}) });
    };
    child.stdout.setEncoding('utf8').on('data', (chunk: string) => { stdout += chunk; });
    child.on('error', (e) => done(null, `could not start: ${e.message}`));
    child.on('close', (code, how) => done(code, code === null ? `killed by ${how}` : undefined));
  });
}

/** Runs `next-dispatchable.sh --why-ticket` on one ticket: of the dispatcher's mirror, or of `bodyFile` over it. */
export async function runReadiness(
  target: { key: string; bodyFile?: string }, project: string, signal?: AbortSignal, fixture?: ReadinessFixture,
): Promise<Readiness> {
  const unanswered = (exit: number | null, lines: string[], warning: string): Readiness => ({ exit, gates: [], lines, warning });
  const script = process.env.JIRA_READINESS_CHECK || CHECK;
  if (!existsSync(script)) return unanswered(null, [], `no check script at ${script}`);
  if (signal?.aborted) return unanswered(null, [], 'the caller stopped it');
  const mirror = fixture?.mirror ?? (process.env.HIMMEL_JIRA_MIRROR || defaultRoot(project));
  const args = [script, '--why-ticket', target.key, ...(target.bodyFile ? ['--body-file', target.bodyFile] : []), '--mirror', mirror];
  const ms = Number(process.env.JIRA_READINESS_TIMEOUT_MS) || TIMEOUT_MS;
  const ran = await runGroup(args, checkEnv(project, fixture), ms, signal);
  const lines = ran.stdout.split('\n').filter((l) => l !== '');
  if (ran.failure !== undefined) return unanswered(ran.exit, lines, ran.failure);
  if (ran.exit === 0) return { exit: 0, gates: [], lines };
  const head = `GATE ${target.key} `;
  const gates = lines.filter((l) => l.startsWith(head)).flatMap((l) => {
    const m = /^([a-z-]+): (.*)$/.exec(l.slice(head.length));
    return m ? [{ name: m[1]!, detail: m[2]! }] : [];
  });
  if (ran.exit === 1) return gates.length ? { exit: 1, gates, lines } : unanswered(1, lines, 'exit 1 with no GATE line');
  const said = lines.find((l) => l.startsWith(`UNKNOWN ${target.key}: `));
  return unanswered(ran.exit, lines, said ? `exit ${ran.exit}: ${said}` : `exit ${ran.exit}`);
}
