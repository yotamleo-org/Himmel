import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export function checkoutRoot(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const common = execFileSync('git', ['-C', here, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  return dirname(common);
}

export const minervaScript = (name: string): string => join(checkoutRoot(), 'marketplace', 'plugins', 'himmel-ops', 'scripts', name);

export const scriptOutput = (e: unknown): string => {
  const err = e as { stderr?: string; stdout?: string; message: string };
  return (err.stderr || err.stdout || err.message).trim();
};

export type Lint = { ok: true } | { ok: false; lines: string[] } | { unavailable: string };

export function traceLint(spec: string, plan: string | null, sourceRoot?: string): Lint {
  let own: string[] = [];
  try {
    own = [execFileSync('git', ['-C', dirname(spec), 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()];
  } catch { }
  try {
    execFileSync('bash', [minervaScript('minerva-trace-lint.sh'), ...(plan === null ? ['--spec-only', spec] : [spec, plan]), ...own],
      { cwd: sourceRoot ?? checkoutRoot(), encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { ok: true };
  } catch (e) {
    return (e as { status?: number | null }).status === 1 ? { ok: false, lines: scriptOutput(e).split('\n') } : { unavailable: scriptOutput(e) };
  }
}

const isFile = (path: string): boolean => {
  try { return statSync(path).isFile(); } catch { return false; }
};

export function planOf(spec: string): string | null {
  const lines = readFileSync(spec, 'utf8').split('\n');
  if (lines[0] !== '---') return null;
  let value = '';
  for (const line of lines.slice(1)) {
    if (line === '---') break;
    if (!/^plan:\s/.test(line)) continue;
    value = line.replace(/^plan:\s+/, '').replace(/\s+\(.*$/, '').replace(/`/g, '');
    break;
  }
  if (!value) return null;
  const dir = dirname(spec);
  return [value, `${dir}/${value}`, `${dir}/../../${value}`]
    .find((c) => (c.startsWith('/') || c.startsWith(`${dir}/`)) && isFile(c)) ?? null;
}

export function estimateLine(text: string): boolean {
  return text.split('\n').some((line) => /^[ \t\r\f\v]*estimate record:/i.test(line));
}
