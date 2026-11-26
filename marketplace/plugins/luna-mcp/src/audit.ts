import { mkdir, open, rename, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface AuditEntry {
  ts: string;
  reqId: string;
  principal: string | null;
  keyId: string | null;
  role: string | null;
  collection: string | null;
  corpus: string | null;
  provider: string | null;
  purpose: string;
  path: string | null;
  tool: string;
  verdict: "allow" | "deny";
  reason: string | null;
}

export type AuditInput = Omit<AuditEntry, "ts">;

export interface Audit {
  write(entry: AuditInput): Promise<void>;
}

export interface AuditOptions {
  file: string;
  now: () => number;
  maxBytes?: number;
  keep?: number;
}

const FIELDS = ["reqId", "principal", "keyId", "role", "collection", "corpus", "provider", "purpose", "path", "tool", "verdict", "reason"] as const;
const PATH_LIMIT = 512;

export function defaultAuditFile(env: NodeJS.ProcessEnv): string {
  const state = env["XDG_STATE_HOME"] || join(env["HOME"] || homedir(), ".local", "state");
  return join(state, "himmel", "luna-mcp-audit.jsonl");
}

export function createAudit(opts: AuditOptions): Audit {
  const maxBytes = opts.maxBytes ?? 10 * 1024 * 1024;
  const keep = opts.keep ?? 5;
  let chain: Promise<void> = Promise.resolve();

  async function rotateIfNeeded(incoming: number): Promise<void> {
    let size: number;
    try {
      size = (await stat(opts.file)).size;
    } catch {
      return;
    }
    if (size === 0 || size + incoming <= maxBytes) return;
    for (let i = keep; i >= 1; i--) {
      const from = i === 1 ? opts.file : `${opts.file}.${i - 1}`;
      if (i === keep) await rm(`${opts.file}.${i}`, { force: true });
      try {
        await rename(from, `${opts.file}.${i}`);
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
      }
    }
  }

  async function append(entry: AuditInput): Promise<void> {
    const row: Record<string, unknown> = { ts: new Date(opts.now()).toISOString() };
    for (const field of FIELDS) {
      const value = entry[field] ?? null;
      row[field] = field === "path" && typeof value === "string" ? value.slice(0, PATH_LIMIT) : value;
    }
    const line = `${JSON.stringify(row)}\n`;
    await mkdir(dirname(opts.file), { recursive: true, mode: 0o700 });
    await rotateIfNeeded(Buffer.byteLength(line));
    const handle = await open(opts.file, "a", 0o600);
    try {
      await handle.chmod(0o600);
      await handle.write(line);
    } finally {
      await handle.close();
    }
  }

  return {
    write(entry) {
      const run = chain.then(() => append(entry));
      chain = run.catch(() => undefined);
      return run;
    },
  };
}
