// The UI login: one operator user whose password is kept as a scrypt hash in the OS keyring, sessions held in memory.
// ponytail: the keyring is reached by spawning scripts/lib/himmel-secrets (key HIMMEL_UI_LOGIN) on every login and every authed request, ceiling: a blocking child per request (about 30 ms measured), upgrade path: cache the item for a few seconds.
import { spawnSync } from "node:child_process";
import { lstatSync, unlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import { readPrivateFile } from "./token-file";

export const SESSION_COOKIE = "himmel_session";
export const SESSION_TTL_MS = 60 * 60 * 1000;
export const MAX_FAILS = 5;
export const FAIL_WINDOW_MS = 15 * 60 * 1000;
const KEYLEN = 64;
const HEX = /^[0-9a-f]+$/;
const KEY = "HIMMEL_UI_LOGIN";
const SECRETS = resolve(import.meta.dir, "../lib/himmel-secrets");

export type Login = { user: string; salt: string; hash: string };
type Env = Record<string, string | undefined>;

export const LOGIN_EXISTS = "a login is already set";

function childEnv(env: Env, drop: string[] = []): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined && !drop.includes(k)) out[k] = v;
  return out;
}

// The keyring item, null when none is stored. The child env loses the key and $CREDENTIALS_DIRECTORY and the read skips
// .env, so only the keyring serves it: a process env that names the key never overrides or stands in for the vault.
function vaultGet(env: Env): string | null {
  const r = spawnSync("bash", [SECRETS, "get", "--no-dotenv", KEY], { env: childEnv(env, [KEY, "CREDENTIALS_DIRECTORY"]), encoding: "utf8", timeout: 15_000 });
  if (r.error) throw new Error(`the keyring could not be read: ${r.error.message}`);
  if (r.status === 0) return r.stdout.slice(KEY.length + 1).replace(/\n$/, "");
  // a locked or silent keyring is an error, not "no login": the 404 would invite setting a login over the one it hides.
  if (r.status === 1 && /keyring (locked|did not answer)/.test(r.stderr)) throw new Error(`the keyring is locked or not answering, so the login cannot be read; unlock it and retry`);
  if (r.status === 1) return null;
  throw new Error(`the keyring could not be read: ${r.stderr.trim() || `exit ${r.status}`}`);
}

function vaultPut(env: Env, line: string): void {
  const r = spawnSync("bash", [SECRETS, "put", "--stdin", KEY], { env: childEnv(env), input: line, encoding: "utf8", timeout: 15_000 });
  if (r.error) throw new Error(`the keyring could not be written: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`the keyring could not be written: ${r.stderr.trim().replace(/^himmel-secrets: /, "") || `exit ${r.status}`}`);
}

// A pre-keyring login file stays where it is until the keyring holds the login; the keyring wins on every read after.
function legacyExists(path: string): boolean {
  try { lstatSync(path); return true; } catch { return false; }
}
function removeLegacy(path: string): void {
  try { unlinkSync(path); } catch { /* absent, or not removable: the keyring item wins on read */ }
}

// createOnly refuses when a login is already stored. ponytail: the check and the put are two steps, so a --set-login
// racing between them is overwritten (the caller holds the UI write lock, --set-login takes none), ceiling: no link(2)
// atomicity, upgrade path: an atomic vault create verb.
export function writeLogin(path: string, user: string, password: string, o: { createOnly?: boolean; env?: Env } = {}): void {
  if (!user || /[\s\x00-\x1f]/.test(user)) throw new Error("the user name must be non-empty with no spaces or control characters");
  if (password.length < 8) throw new Error("the password must be at least 8 characters");
  const env = o.env ?? process.env;
  const salt = randomBytes(16).toString("hex");
  const hash = scryptSync(password, salt, KEYLEN).toString("hex");
  if (o.createOnly && (vaultGet(env) !== null || legacyExists(path))) throw new Error(LOGIN_EXISTS);
  vaultPut(env, JSON.stringify({ user, salt, hash }));
  removeLegacy(path);
}

function parse(raw: string, what: string): Login {
  let o: any;
  try { o = JSON.parse(raw); } catch { o = null; }
  if (typeof o?.user !== "string" || !HEX.test(o?.salt ?? "") || !HEX.test(o?.hash ?? "") || o.hash.length !== KEYLEN * 2) throw new Error(`${what} is malformed; set the login again`);
  return { user: o.user, salt: o.salt, hash: o.hash };
}

const noticed = new Set<string>();

// The pre-keyring file was read: say so, and move it into the keyring when the keyring will take it.
function migrate(path: string, line: string, env: Env, keyringErr: Error | null): void {
  let why = keyringErr?.message ?? "";
  let moved = false;
  if (!keyringErr) {
    try { vaultPut(env, line); unlinkSync(path); moved = true; } catch (e) { why = (e as Error).message; }
  }
  if (!moved && noticed.has(path)) return;
  noticed.add(path);
  console.error(`himmelctl: ui: ${path} is deprecated; the login lives in the OS keyring (${KEY}) now. ` +
    (moved ? "It was moved there and the file removed." : `It was not moved yet (${why}); it is tried again on the next read.`));
}

// null when no login is set; throws on a keyring that cannot be read, or a file that could have been planted or read by others.
// The keyring item wins; a pre-keyring file is the fallback and moves into the keyring on its first successful read.
export function readLogin(path: string, env: Env = process.env): Login | null {
  let line: string | null = null;
  let keyringErr: Error | null = null;
  try { line = vaultGet(env); } catch (e) { keyringErr = e as Error; }
  if (line !== null) return parse(line, `the keyring item ${KEY}`);
  const raw = readPrivateFile(path, "login file", "set the login again");
  if (raw === null) {
    if (keyringErr) throw keyringErr;
    return null;
  }
  const l = parse(raw.trim(), `login file ${path}`);
  migrate(path, raw.trim(), env, keyringErr);
  return l;
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
export function createAuth(path: string, now: () => number, env: Env = process.env) {
  const sessions = new Map<string, { exp: number; hash: string }>();
  let fails: number[] = [];
  return {
    login(user: unknown, password: unknown): LoginResult {
      const t = now();
      fails = fails.filter((f) => t - f < FAIL_WINDOW_MS);
      if (fails.length >= MAX_FAILS) return { status: 429, retryAfterS: Math.ceil((fails[0] + FAIL_WINDOW_MS - t) / 1000), error: "too many failed logins; wait and retry" };
      let l: Login | null;
      try { l = readLogin(path, env); } catch (e) { return { status: 500, error: (e as Error).message }; }
      if (!l) return { status: 404, error: `no login is set; run \`bun ${join(import.meta.dir, "server.ts")} --set-login <user>\` from your own terminal` };
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
      try { l = readLogin(path, env); } catch { /* an unreadable login ends the session */ }
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
