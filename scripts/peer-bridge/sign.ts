// Ed25519 over the exact bytes of an envelope's lines 2 and 3, and the station
// key files. The private key never leaves C/ (the config dir): it is created with
// O_EXCL at mode 0600, read only here, and never printed. Rotation keeps the old
// key signing until `activate`, so there is no gap.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign as edSign, verify as edVerify, type KeyObject } from "node:crypto";
import fs, { constants } from "node:fs";
import { join } from "node:path";
import { configDir } from "./ids";

export const DOMAIN_TAG = "himmel-peer-env-v1\n";
export const STATION_KEY = "station.ed25519";
export const NEXT_KEY = "station.ed25519.next";
export const KEY_OVERLAP_S = 30 * 86400;

export type TheirKey = { id: string; pub: string; addedAt: string };

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export function signedBytes(line2: string, line3: string): Uint8Array {
  return Buffer.from(`${DOMAIN_TAG}${line2}\n${line3}`, "utf8");
}

function readKeyFile(path: string): KeyObject {
  const fd = fs.openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o600) throw new Error("the station key must be a regular file owned by you, mode 0600");
    return createPrivateKey(fs.readFileSync(fd));
  } finally { fs.closeSync(fd); }
}

const rawPub = (key: KeyObject): Buffer => (createPublicKey(key).export({ format: "der", type: "spki" }) as Buffer).subarray(-32);
export const pubB64Of = (key: KeyObject): string => rawPub(key).toString("base64");

export function publicKeyOf(keyPath: string): string {
  return pubB64Of(readKeyFile(keyPath));
}

const digest = (pubB64: string): string => createHash("sha256").update(Buffer.from(pubB64, "base64")).digest("hex");
export const keyId = (pubB64: string): string => digest(pubB64).slice(0, 8);
export const fingerprint = (pubB64: string): string => digest(pubB64).slice(0, 20).replace(/(.{4})(?=.)/g, "$1 ");

// base64url without padding, and only the canonical spelling of it: a signature
// has one text form, so a re-spelled one is not a second valid line 4.
function sigBytes(sig: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]{86}$/.test(sig)) return null;
  const b = Buffer.from(sig, "base64url");
  return b.length === 64 && b.toString("base64url") === sig ? b : null;
}

export function sign(line2: string, line3: string, keyPath: string): string {
  return edSign(null, signedBytes(line2, line3), readKeyFile(keyPath)).toString("base64url");
}

export function verify(line2: string, line3: string, sig: string, pubB64: string): boolean {
  try {
    const s = sigBytes(sig);
    const raw = Buffer.from(pubB64, "base64");
    if (!s || raw.length !== 32 || raw.toString("base64") !== pubB64) return false;
    const pub = createPublicKey({ key: Buffer.concat([SPKI_ED25519_PREFIX, raw]), format: "der", type: "spki" });
    return edVerify(null, signedBytes(line2, line3), pub, s);
  } catch { return false; }
}

// ---- the station key files ----

export type KeyInfo = { id: string; pub: string; fingerprint: string };
const infoOf = (path: string): KeyInfo => { const pub = publicKeyOf(path); return { id: keyId(pub), pub, fingerprint: fingerprint(pub) }; };

// O_CREAT|O_EXCL: an existing key is never overwritten.
function createKeyFile(path: string): void {
  const { privateKey } = generateKeyPairSync("ed25519");
  const fd = fs.openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, privateKey.export({ format: "pem", type: "pkcs8" })); } finally { fs.closeSync(fd); }
}

export function keygen(dir: string = configDir()): KeyInfo {
  const path = join(dir, STATION_KEY);
  createKeyFile(path);
  return infoOf(path);
}

// A next key, printed for the peer to trust. We keep signing with the current one.
export function keygenRotate(dir: string = configDir()): KeyInfo {
  if (!fs.existsSync(join(dir, STATION_KEY))) throw new Error("no station key yet; run keygen first");
  const path = join(dir, NEXT_KEY);
  createKeyFile(path);
  return infoOf(path);
}

// The next key becomes the current one; the old key file is gone.
export function keygenActivate(dir: string = configDir()): KeyInfo {
  const next = join(dir, NEXT_KEY);
  if (!fs.existsSync(next)) throw new Error("no next key; run keygen --rotate first");
  const info = infoOf(next);
  fs.renameSync(next, join(dir, STATION_KEY));
  return info;
}

export function currentSigningKey(dir: string = configDir()): { id: string; path: string } {
  const path = join(dir, STATION_KEY);
  try { return { id: keyId(publicKeyOf(path)), path }; } catch { throw new Error("no usable station key; run setup.ts keygen"); }
}

// The keys a peer may sign with now: a key ages out 30 days after its successor
// was added, so a rotation never needs a flag day.
export function liveKeys(keys: TheirKey[], nowS: number): TheirKey[] {
  const at = (k: TheirKey) => Date.parse(k.addedAt) / 1000;
  return keys.filter(k => !keys.some(s => s !== k && at(s) > at(k) && nowS >= at(s) + KEY_OVERLAP_S));
}
