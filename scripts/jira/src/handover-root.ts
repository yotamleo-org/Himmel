import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

// Mirrors scripts/lib/handover-path.sh handover_root: an explicit HANDOVER_DIR
// wins (and must be a directory), else the config layers in load_dotenv order
// (~/.himmel/himmel.conf.local, ~/.himmel/himmel.conf, the primary checkout's
// legacy .env), else <primary checkout>/handovers. Reads only that one key;
// never logs it.
export function handoverRoot(
  env: Record<string, string | undefined> = process.env,
  dotenvPath?: string,
): string {
  const resolved = behaviourKey('HANDOVER_DIR', env, dotenvPath);
  if (resolved) {
    if (!isDirectory(resolved)) throw new Error(`handover-path: HANDOVER_DIR='${resolved}' is not a directory`);
    return resolved;
  }
  return join(primaryCheckout(), 'handovers');
}

// One behaviour key (docs/internals/config-layers.md) in load_dotenv order: the
// process env, himmel.conf.local, himmel.conf, then the legacy .env. An empty
// value reads as unset at every layer.
export function behaviourKey(
  key: string,
  env: Record<string, string | undefined> = process.env,
  dotenvPath?: string,
): string | undefined {
  if (env[key]) return env[key];
  const confDir = join(env.HOME || homedir(), '.himmel');
  for (const file of [join(confDir, 'himmel.conf.local'), join(confDir, 'himmel.conf')]) {
    const value = readDotenvKey(file, key);
    if (value) return value;
  }
  return readDotenvKey(dotenvPath ?? join(primaryCheckout(), '.env'), key);
}

function primaryCheckout(): string {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  return dirname(common);
}

function unquote(value: string): string {
  const first = value[0];
  return value.length >= 2 && (first === '"' || first === "'") && value.endsWith(first) ? value.slice(1, -1) : value;
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
    if (k.trim() === key) return unquote(rest.join('=').trim()) || undefined;
  }
  return undefined;
}
