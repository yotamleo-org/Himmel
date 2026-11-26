import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  OAuthError,
  OAuthErrorCode,
  requireBearerAuth,
  validateHostHeader,
  validateOriginHeader,
  type AuthInfo,
  type OAuthTokenVerifier,
} from "@modelcontextprotocol/server";
import * as z from "zod";

export const SUPPORTED_ROLES = ["reader"] as const;
export const PROVIDERS = ["xai-grokbot", "openai-chatgpt"] as const;
export type Provider = (typeof PROVIDERS)[number];

export const COLLECTION_NAME = /^[A-Za-z0-9._-]{1,64}$/;

const isHttpsUrl = (s: string): boolean => {
  try {
    return new URL(s).protocol === "https:";
  } catch {
    return false;
  }
};

const RecordSchema = z.object({
  keyId: z.string().regex(/^[A-Za-z0-9_-]{3,64}$/),
  hash: z.string().regex(/^[0-9a-f]{64}$/),
  principal: z.string().min(1).max(64),
  egressProvider: z.enum(PROVIDERS),
  resource: z.string().refine(isHttpsUrl),
  roles: z.array(z.enum(SUPPORTED_ROLES)).min(1),
  allowedCollections: z.array(z.string().regex(COLLECTION_NAME)).min(1),
  createdAt: z.string().optional(),
  expiresAt: z.string().refine((s) => Number.isFinite(Date.parse(s))),
  revoked: z.boolean(),
});

const EnvelopeSchema = z.object({ version: z.literal(1), keys: z.array(z.unknown()) });

export type KeyRecord = z.infer<typeof RecordSchema>;

export interface Principal {
  keyId: string;
  principal: string;
  provider: Provider;
  roles: readonly string[];
  allowedCollections: readonly string[];
  allowHandoversRead: boolean;
}

export interface AuthTrace {
  reason?: string;
  principal?: Principal;
}

export class KeysFileError extends Error {}

export function hashKey(plaintext: string): string {
  return createHash("sha256").update(plaintext).digest("hex");
}

export function defaultKeysFile(env: NodeJS.ProcessEnv): string {
  const config = env["XDG_CONFIG_HOME"] || join(env["HOME"] || homedir(), ".config");
  return join(config, "himmel", "luna-mcp-keys.json");
}

export function parseRecord(raw: unknown): KeyRecord | undefined {
  const parsed = RecordSchema.safeParse(raw);
  return parsed.success ? parsed.data : undefined;
}

export async function readKeysRaw(file: string, allowMissing = false): Promise<unknown[]> {
  let st;
  try {
    st = await stat(file);
  } catch (e) {
    if (allowMissing && (e as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw new KeysFileError("key file is not readable");
  }
  if (!st.isFile()) throw new KeysFileError("key file is not a regular file");
  if ((st.mode & 0o077) !== 0) throw new KeysFileError("key file must not be accessible by group or others (mode 0600)");
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(file, "utf8"));
  } catch {
    throw new KeysFileError("key file is not valid JSON");
  }
  const envelope = EnvelopeSchema.safeParse(parsed);
  if (!envelope.success) throw new KeysFileError("key file has an unsupported shape");
  return envelope.data.keys;
}

export async function readKeysFile(file: string): Promise<{ keys: KeyRecord[]; invalid: number }> {
  const raw = await readKeysRaw(file);
  const keys: KeyRecord[] = [];
  const seen = new Set<string>();
  let invalid = 0;
  for (const r of raw) {
    const rec = parseRecord(r);
    if (!rec || seen.has(rec.keyId) || seen.has(rec.hash)) {
      invalid++;
      continue;
    }
    seen.add(rec.keyId);
    seen.add(rec.hash);
    keys.push(rec);
  }
  return { keys, invalid };
}

export async function writeKeysFile(file: string, keys: readonly unknown[]): Promise<void> {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(tmp, `${JSON.stringify({ version: 1, keys }, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, file);
}

const refuse = (message: string): OAuthError => new OAuthError(OAuthErrorCode.InvalidToken, message);

function principalOf(key: KeyRecord): Principal {
  return {
    keyId: key.keyId,
    principal: key.principal,
    provider: key.egressProvider,
    roles: [...key.roles],
    allowedCollections: [...key.allowedCollections],
    allowHandoversRead: false,
  };
}

export class KeyStore {
  readonly #file: string;
  readonly #now: () => number;
  #cache: { sig: string; keys: KeyRecord[] } | undefined;

  constructor(file: string, now: () => number) {
    this.#file = file;
    this.#now = now;
  }

  async #keys(): Promise<KeyRecord[]> {
    let st;
    try {
      st = await stat(this.#file, { bigint: true });
    } catch {
      this.#cache = undefined;
      throw new KeysFileError("key file is not readable");
    }
    const sig = [st.ino, st.size, st.mtimeNs, st.ctimeNs, st.mode].join(":");
    if (this.#cache?.sig === sig) return this.#cache.keys;
    try {
      const { keys } = await readKeysFile(this.#file);
      this.#cache = { sig, keys };
      return keys;
    } catch (e) {
      this.#cache = undefined;
      throw e;
    }
  }

  verifier(trace: AuthTrace): OAuthTokenVerifier {
    return {
      verifyAccessToken: async (token: string): Promise<AuthInfo> => {
        let keys: KeyRecord[];
        try {
          keys = await this.#keys();
        } catch {
          trace.reason = "keystore-unavailable";
          throw new OAuthError(OAuthErrorCode.ServerError, "key store unavailable");
        }
        const presented = createHash("sha256").update(token).digest();
        let match: KeyRecord | undefined;
        for (const key of keys) {
          if (timingSafeEqual(Buffer.from(key.hash, "hex"), presented)) match = key;
        }
        if (!match) {
          trace.reason = "unknown-key";
          throw refuse("invalid token");
        }
        const principal = principalOf(match);
        trace.principal = principal;
        if (match.revoked) {
          trace.reason = "revoked";
          throw refuse("invalid token");
        }
        const expiresMs = Date.parse(match.expiresAt);
        if (expiresMs <= this.#now()) {
          trace.reason = "expired";
          throw refuse("invalid token");
        }
        return {
          token: match.keyId,
          clientId: match.principal,
          scopes: [...match.roles],
          expiresAt: expiresMs / 1000,
          resource: new URL(match.resource),
          extra: { principal },
        };
      },
    };
  }
}

export function principalFrom(info: AuthInfo): Principal {
  const principal = info.extra?.["principal"];
  if (!principal || typeof principal !== "object") throw new Error("auth info carries no principal");
  return principal as Principal;
}

export function checkHostAndOrigin(req: Request, publicUrl: URL): "host" | "origin" | null {
  const allowed = [publicUrl.hostname];
  if (!validateHostHeader(req.headers.get("host"), allowed).ok) return "host";
  if (!validateOriginHeader(req.headers.get("origin"), allowed).ok) return "origin";
  return null;
}

export function bearerGate(
  store: KeyStore,
  publicUrl: URL,
  trace: AuthTrace,
): (req: Request) => Promise<AuthInfo | Response> {
  const gate = requireBearerAuth({ verifier: store.verifier(trace), expectedResource: publicUrl });
  return async (req) => {
    const out = await gate(req);
    if (out instanceof Response && trace.reason === undefined) {
      trace.reason = trace.principal ? "resource-mismatch" : "auth";
    }
    return out;
  };
}
