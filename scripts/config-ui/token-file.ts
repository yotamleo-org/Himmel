// The stable token for service mode: one mode-600 regular file, created once, read on every start.
// A symlink or a file others can read is refused (same rule as scripts/lib/qmd-key-probe.sh): the token is the only gate.
import { chmodSync, closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readFileSync, writeSync } from "node:fs";
import { dirname } from "node:path";

const TOKEN = /^[0-9a-f]{64}$/;

export function readOrCreateToken(path: string, mint: () => string): string {
  let st: ReturnType<typeof lstatSync> | null = null;
  try { st = lstatSync(path); } catch { /* absent: created below */ }
  if (st) {
    if (st.isSymbolicLink()) throw new Error(`token file ${path} is a symlink; refusing it`);
    if (!st.isFile()) throw new Error(`token file ${path} is not a regular file; refusing it`);
    if ((st.mode & 0o777) !== 0o600) throw new Error(`token file ${path} must be mode 600 (is ${(st.mode & 0o777).toString(8)}); chmod 600 it or delete it`);
    const t = readFileSync(path, "utf8").trim();
    if (!TOKEN.test(t)) throw new Error(`token file ${path} does not hold a 64-hex token; delete it to mint a new one`);
    return t;
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const token = mint();
  // O_EXCL: a racing second start fails here rather than overwriting the first one's token.
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    if (!fstatSync(fd).isFile()) throw new Error(`token file ${path} is not a regular file`);
    writeSync(fd, `${token}\n`);
  } finally { closeSync(fd); }
  chmodSync(path, 0o600);
  return token;
}
