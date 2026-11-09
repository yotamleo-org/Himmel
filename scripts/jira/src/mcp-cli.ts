import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export type CliResult = { code: number; stdout: string; stderr: string };
export type CliRunner = (argv: string[]) => Promise<CliResult>;

export function cliEntry(): string {
  return join(dirname(fileURLToPath(import.meta.url)), 'index.js');
}

export function execCli(entry: string = cliEntry()): CliRunner {
  return (argv) =>
    new Promise((resolve, reject) => {
      if (!existsSync(entry)) {
        reject(new Error(`jira mcp: the jira CLI is not built (${entry} is missing): run npm --prefix <checkout>/scripts/jira run build. Nothing was sent to Jira.`));
        return;
      }
      execFile(process.execPath, [entry, ...argv], { shell: false, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, env: process.env }, (err, stdout, stderr) => {
        const code = err ? (typeof (err as { code?: unknown }).code === 'number' ? (err as { code: number }).code : 1) : 0;
        resolve({ code, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') });
      });
    });
}

/** One CLI call: its stdout (plus stderr warnings) on exit 0, else an error with what the CLI said. */
export async function runCli(runner: CliRunner | undefined, argv: string[]): Promise<string> {
  const r = await (runner ?? execCli())(argv);
  const out = r.stdout.trimEnd();
  const err = r.stderr.trimEnd();
  if (r.code !== 0) throw new Error([err, out].filter(Boolean).join('\n') || `jira ${argv[0]} exited ${r.code}`);
  return [out, err].filter(Boolean).join('\n');
}

/**
 * Flags from typed MCP arguments, in `spec` order: a string or number gives
 * `--flag value`, `true` gives `--flag`, an array repeats the flag, an object is
 * passed as JSON; undefined, null and false are left out.
 */
export function flags(args: Record<string, unknown>, spec: Record<string, string>): string[] {
  const out: string[] = [];
  for (const [name, flag] of Object.entries(spec)) {
    const v = args[name];
    if (v === undefined || v === null || v === false) continue;
    if (v === true) out.push(flag);
    else if (Array.isArray(v)) for (const x of v) out.push(flag, String(x));
    else if (typeof v === 'object') out.push(flag, JSON.stringify(v));
    else out.push(flag, String(v));
  }
  return out;
}
