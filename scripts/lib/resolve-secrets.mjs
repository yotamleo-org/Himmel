// resolve-secrets.mjs — the TypeScript/JavaScript door to scripts/lib/himmel-secrets.
//
// resolveSecrets(root, names) runs this checkout's himmel-secrets (found from this file's own
// path, never the cwd) as `get --root <root> --no-dotenv <names...>` and parses NAME=value at the
// first "=". The resolver walks environment, CREDENTIALS_DIRECTORY, then the keyring; a reader
// reads its own .env only for a name this returns nothing for.
// A value is never logged and never put on argv: `put` takes it on stdin.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RESOLVER = join(dirname(fileURLToPath(import.meta.url)), 'himmel-secrets');
const TIMEOUT_MS = 10000;

function run(args, input) {
  if (!existsSync(RESOLVER)) return { status: 2, stdout: '' };
  try {
    const stdout = execFileSync('bash', [RESOLVER, ...args], {
      encoding: 'utf8', input, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'ignore'], timeout: TIMEOUT_MS,
    });
    return { status: 0, stdout: String(stdout ?? '') };
  } catch (e) {
    // A non-zero exit throws; its stdout (a partial `get` hit) is still usable.
    return { status: typeof e?.status === 'number' ? e.status : 2, stdout: String(e?.stdout ?? '') };
  }
}

/** @returns {Record<string, string>} the names the resolver serves; a name nobody holds is absent. */
export function resolveSecrets(root, names) {
  const out = {};
  if (names.length === 0) return out;
  // exit 1 = nothing served; the stdout of a partial hit is still usable.
  const { stdout } = run(['get', '--root', root, '--no-dotenv', ...names]);
  for (const line of stdout.split('\n')) {
    const i = line.indexOf('=');
    if (i < 1) continue;
    const name = line.slice(0, i);
    if (names.includes(name)) out[name] = line.slice(i + 1);
  }
  return out;
}

/** True when `himmel-secrets status` reports `keyring: unlocked`. */
export function keyringUnlocked(root) {
  const { stdout } = run(['status', '--root', root]);
  return /^keyring: unlocked$/m.test(stdout);
}

/** Store one value in the keyring through `put --stdin`; true on success. Call only when unlocked. */
export function putSecret(root, name, value) {
  return run(['put', '--root', root, '--stdin', name], value).status === 0;
}
