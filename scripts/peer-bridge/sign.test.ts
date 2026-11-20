import { afterEach, beforeEach, expect, test } from "bun:test";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NEXT_KEY, STATION_KEY, currentSigningKey, fingerprint, keyId, keygen, keygenActivate, keygenRotate, liveKeys, publicKeyOf, sign, signedBytes, verify } from "./sign";

let dir: string;
beforeEach(() => { dir = fs.mkdtempSync(join(tmpdir(), "peer-sign-")); fs.chmodSync(dir, 0o700); });
afterEach(() => { fs.rmSync(dir, { recursive: true, force: true }); });

const L2 = "#env:v1 k=0123abcd id=89abcdef";
const L3 = '{"v":1,"msg":"89abcdef"}';

test("sign then verify round-trips, and the signature is 86 base64url characters", () => {
  const k = keygen(dir);
  const sig = sign(L2, L3, join(dir, STATION_KEY));
  expect(sig).toMatch(/^[A-Za-z0-9_-]{86}$/);
  expect(verify(L2, L3, sig, k.pub)).toBe(true);
});

test("a flipped byte in line 2 or line 3 fails", () => {
  const k = keygen(dir);
  const sig = sign(L2, L3, join(dir, STATION_KEY));
  expect(verify(L2.replace("abcd", "abce"), L3, sig, k.pub)).toBe(false);
  expect(verify(L2, L3.replace("89", "88"), sig, k.pub)).toBe(false);
  expect(verify(L2, L3 + " ", sig, k.pub)).toBe(false);
});

test("another key fails", () => {
  const a = fs.mkdtempSync(join(tmpdir(), "peer-sign-a-"));
  try {
    keygen(dir);
    const other = keygen(a);
    expect(verify(L2, L3, sign(L2, L3, join(dir, STATION_KEY)), other.pub)).toBe(false);
  } finally { fs.rmSync(a, { recursive: true, force: true }); }
});

test("signing line 3 alone does not verify: the domain tag and line 2 are bound", () => {
  const k = keygen(dir);
  const sig = sign(L2, L3, join(dir, STATION_KEY));
  expect(verify("", L3, sig, k.pub)).toBe(false);
  expect(verify(L2.replace("id=89abcdef", "id=89abcde0"), L3, sig, k.pub)).toBe(false);
  expect(Buffer.from(signedBytes(L2, L3)).toString()).toBe(`himmel-peer-env-v1\n${L2}\n${L3}`);
});

test("a malformed signature or key is false, never a throw", () => {
  const k = keygen(dir);
  const sig = sign(L2, L3, join(dir, STATION_KEY));
  expect(verify(L2, L3, sig.slice(1), k.pub)).toBe(false);
  expect(verify(L2, L3, sig + "A", k.pub)).toBe(false);
  expect(verify(L2, L3, sig.replace(/.$/, "+"), k.pub)).toBe(false);
  expect(verify(L2, L3, sig, "not base64!")).toBe(false);
  expect(verify(L2, L3, sig, Buffer.alloc(31).toString("base64"))).toBe(false);
  expect(verify(L2, L3, "", k.pub)).toBe(false);
});

test("a re-spelled signature (non-canonical trailing bits) is not a second valid line 4", () => {
  const k = keygen(dir);
  const sig = sign(L2, L3, join(dir, STATION_KEY));
  const last = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".indexOf(sig[85]);
  const alt = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[last ^ 1];
  expect(verify(L2, L3, sig.slice(0, 85) + alt, k.pub)).toBe(false);
});

test("the key file is 0600 and a second keygen refuses (O_EXCL)", () => {
  keygen(dir);
  const path = join(dir, STATION_KEY);
  expect(fs.statSync(path).mode & 0o777).toBe(0o600);
  expect(() => keygen(dir)).toThrow();
  // The refused call left the first key untouched.
  expect(currentSigningKey(dir).id).toBe(keyId(publicKeyOf(path)));
});

test("a key file that is not 0600 is not used", () => {
  const k = keygen(dir);
  fs.chmodSync(join(dir, STATION_KEY), 0o640);
  expect(() => sign(L2, L3, join(dir, STATION_KEY))).toThrow();
  expect(() => currentSigningKey(dir)).toThrow();
  expect(k.id).toMatch(/^[0-9a-f]{8}$/);
});

test("keygen prints an 8-hex id and a fingerprint of 20 hex in groups of four", () => {
  const k = keygen(dir);
  expect(k.id).toBe(keyId(k.pub));
  expect(Buffer.from(k.pub, "base64").length).toBe(32);
  expect(k.fingerprint).toMatch(/^[0-9a-f]{4}( [0-9a-f]{4}){4}$/);
  expect(fingerprint(k.pub)).toBe(k.fingerprint);
});

test("--rotate leaves the old key signing; --activate switches and deletes the old file", () => {
  const first = keygen(dir);
  const next = keygenRotate(dir);
  expect(next.id).not.toBe(first.id);
  expect(fs.statSync(join(dir, NEXT_KEY)).mode & 0o777).toBe(0o600);
  expect(currentSigningKey(dir).id).toBe(first.id);
  expect(verify(L2, L3, sign(L2, L3, currentSigningKey(dir).path), first.pub)).toBe(true);
  expect(() => keygenRotate(dir)).toThrow();

  const active = keygenActivate(dir);
  expect(active.id).toBe(next.id);
  expect(currentSigningKey(dir).id).toBe(next.id);
  expect(fs.existsSync(join(dir, NEXT_KEY))).toBe(false);
  expect(verify(L2, L3, sign(L2, L3, currentSigningKey(dir).path), next.pub)).toBe(true);
  expect(verify(L2, L3, sign(L2, L3, currentSigningKey(dir).path), first.pub)).toBe(false);
  expect(() => keygenActivate(dir)).toThrow();
});

test("--rotate needs a key to rotate", () => {
  expect(() => keygenRotate(dir)).toThrow();
});

test("a key in theirs.keys ages out 30 days after its successor was added", () => {
  const day = 86400;
  const t0 = Date.parse("2026-11-01T00:00:00Z") / 1000;
  const old = { id: "00000001", pub: "a", addedAt: "2026-11-01T00:00:00Z" };
  const fresh = { id: "00000002", pub: "b", addedAt: "2026-11-10T00:00:00Z" };
  const ids = (ks: typeof old[], now: number) => liveKeys(ks, now).map(k => k.id);
  expect(ids([old], t0 + 400 * day)).toEqual(["00000001"]);                 // no successor: never ages out
  expect(ids([old, fresh], t0 + 20 * day)).toEqual(["00000001", "00000002"]); // 10 days after the successor
  expect(ids([old, fresh], t0 + 9 * day + 30 * day - 1)).toEqual(["00000001", "00000002"]);
  expect(ids([old, fresh], t0 + 9 * day + 30 * day)).toEqual(["00000002"]);
  expect(ids([fresh, old], t0 + 100 * day)).toEqual(["00000002"]);
});
