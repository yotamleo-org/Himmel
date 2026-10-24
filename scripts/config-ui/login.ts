// The UI login: one operator user whose password is kept as a scrypt hash, sessions held in memory.
// ponytail: the hash lives in a mode-600 file (~/.himmel/state/ui-login, the same rules as token-file.ts), upgrade path is the keyring vault backend, HIMMEL-7147.
import { closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, writeSync } from "node:fs";
import { dirname } from "node:path";
import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";

export const SESSION_COOKIE = "himmel_session";
export const SESSION_TTL_MS = 60 * 60 * 1000;
export const MAX_FAILS = 5;
export const FAIL_WINDOW_MS = 15 * 60 * 1000;
const KEYLEN = 64;
const HEX = /^[0-9a-f]+$/;

export type Login = { user: string; salt: string; hash: string };

export function writeLogin(path: string, user: string, password: string): void {
  if (!user || /[\s\x00-\x1f]/.test(user)) throw new Error("the user name must be non-empty with no spaces or control characters");
  if (password.length < 8) throw new Error("the password must be at least 8 characters");
  const salt = randomBytes(16).toString("hex");
  const hash = scryptSync(password, salt, KEYLEN).toString("hex");
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.tmp`;
  const fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    if (!fstatSync(fd).isFile()) throw new Error(`login file ${tmp} is not a regular file`);
    writeSync(fd, JSON.stringify({ user, salt, hash }) + "\n");
  } finally { closeSync(fd); }
  renameSync(tmp, path);
}

// null when no login is set; throws on a file that could have been planted or read by others.
export function readLogin(path: string): Login | null {
  let st: ReturnType<typeof lstatSync>;
  try { st = lstatSync(path); } catch { return null; }
  if (st.isSymbolicLink()) throw new Error(`login file ${path} is a symlink; refusing it`);
  if (!st.isFile()) throw new Error(`login file ${path} is not a regular file; refusing it`);
  if ((st.mode & 0o777) !== 0o600) throw new Error(`login file ${path} must be mode 600 (is ${(st.mode & 0o777).toString(8)}); chmod 600 it or set the login again`);
  const o = JSON.parse(readFileSync(path, "utf8"));
  if (typeof o?.user !== "string" || !HEX.test(o?.salt ?? "") || !HEX.test(o?.hash ?? "") || o.hash.length !== KEYLEN * 2) throw new Error(`login file ${path} is malformed; set the login again`);
  return { user: o.user, salt: o.salt, hash: o.hash };
}

function matches(l: Login, user: string, password: string): boolean {
  const got = scryptSync(password, l.salt, KEYLEN);
  const a = Buffer.from(user), b = Buffer.from(l.user);
  const userOk = a.length === b.length && timingSafeEqual(a, b);
  return timingSafeEqual(got, Buffer.from(l.hash, "hex")) && userOk;
}

export type LoginResult = { status: 200; session: string } | { status: 401 | 404 | 500; error: string } | { status: 429; retryAfterS: number; error: string };

// The server binds loopback only, so every client shares one address: the failure limit is global, not per IP.
// A session is bound to the hash it logged in against, so setting the login again ends every session.
export function createAuth(path: string, now: () => number) {
  const sessions = new Map<string, { exp: number; hash: string }>();
  let fails: number[] = [];
  return {
    login(user: unknown, password: unknown): LoginResult {
      const t = now();
      fails = fails.filter((f) => t - f < FAIL_WINDOW_MS);
      if (fails.length >= MAX_FAILS) return { status: 429, retryAfterS: Math.ceil((fails[0] + FAIL_WINDOW_MS - t) / 1000), error: "too many failed logins; wait and retry" };
      let l: Login | null;
      try { l = readLogin(path); } catch (e) { return { status: 500, error: (e as Error).message }; }
      if (!l) return { status: 404, error: "no login is set; run `bun scripts/config-ui/server.ts --set-login <user>` from your own terminal" };
      if (typeof user !== "string" || typeof password !== "string" || !matches(l, user, password)) {
        fails.push(t);
        return { status: 401, error: "wrong user or password" };
      }
      fails = [];
      for (const [k, s] of sessions) if (t >= s.exp) sessions.delete(k);
      const id = randomBytes(32).toString("hex");
      sessions.set(id, { exp: t + SESSION_TTL_MS, hash: l.hash });
      return { status: 200, session: id };
    },
    // the session id the Cookie header carries, when it names a live session; null otherwise.
    session(cookie: string | null): string | null {
      const id = sessionId(cookie);
      if (!id) return null;
      const s = sessions.get(id);
      if (s === undefined) return null;
      let l: Login | null = null;
      try { l = readLogin(path); } catch { /* an unreadable login ends the session */ }
      if (now() >= s.exp || l?.hash !== s.hash) { sessions.delete(id); return null; }
      return id;
    },
    logout(cookie: string | null): void {
      const id = sessionId(cookie);
      if (id) sessions.delete(id);
    },
  };
}

function sessionId(cookie: string | null): string | null {
  for (const part of (cookie ?? "").split(";")) {
    const [k, v] = part.trim().split("=");
    if (k === SESSION_COOKIE && v && /^[0-9a-f]{64}$/.test(v)) return v;
  }
  return null;
}

export const sessionCookie = (id: string) => `${SESSION_COOKIE}=${id}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL_MS / 1000}`;
export const clearedCookie = () => `${SESSION_COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`;
