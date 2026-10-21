import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';

// Mirrors scripts/lib/handover-path.sh handover_root: an explicit HANDOVER_DIR
// wins (and must be a directory), else the primary checkout's .env HANDOVER_DIR
// line, else <primary checkout>/handovers. Reads only that one key; never logs it.
export function handoverRoot(
  env: Record<string, string | undefined> = process.env,
  dotenvPath: string = join(primaryCheckout(), '.env'),
): string {
  const explicit = env['HANDOVER_DIR'];
  if (explicit) {
    if (!isDirectory(explicit)) throw new Error(`handover-path: HANDOVER_DIR='${explicit}' is not a directory`);
    return explicit;
  }
  const fromFile = readDotenvKey(dotenvPath, 'HANDOVER_DIR');
  if (fromFile) return fromFile;
  return join(primaryCheckout(), 'handovers');
}

function primaryCheckout(): string {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  return dirname(common);
}

function isDirectory(path: string): boolean {
  return existsSync(path) && statSync(path).isDirectory();
}

function readDotenvKey(path: string, key: string): string | undefined {
  if (!existsSync(path)) return undefined;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const [k, ...rest] = trimmed.split('=');
    if (k.trim() === key) return rest.join('=').trim() || undefined;
  }
  return undefined;
}
