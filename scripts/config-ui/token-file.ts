// The stable token for service mode: one mode-600 regular file, created once, read on every start.
// A symlink or a file others can read is refused (same rule as scripts/lib/qmd-key-probe.sh): the token is the only gate.
import { chmodSync, closeSync, constants, fstatSync, mkdirSync, openSync, readFileSync, writeSync } from "node:fs";
import { dirname } from "node:path";

const TOKEN = /^[0-9a-f]{64}$/;

// A mode-600 regular file's text, null when absent. The checks run on the opened descriptor, never on the path,
// so a file swapped in between cannot slip past them; O_NONBLOCK keeps a planted FIFO from hanging the open.
export function readPrivateFile(path: string, what: string, fix: string): string | null {
  let fd: number;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return null;
    if (code === "ELOOP") throw new Error(`${what} ${path} is a symlink; refusing it`);
    throw e;
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) throw new Error(`${what} ${path} is not a regular file; refusing it`);
    if ((st.mode & 0o777) !== 0o600) throw new Error(`${what} ${path} must be mode 600 (is ${(st.mode & 0o777).toString(8)}); chmod 600 it or ${fix}`);
    return readFileSync(fd, "utf8");
  } finally { closeSync(fd); }
}

export function readOrCreateToken(path: string, mint: () => string): string {
  const raw = readPrivateFile(path, "token file", "delete it");
  if (raw !== null) {
    const t = raw.trim();
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
