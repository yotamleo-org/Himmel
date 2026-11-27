import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
const PINNED_ENV = ['PATH', 'HOME', 'LANG', 'TZ'] as const;
const TIMEOUT_MS = 15_000;

export interface VerifiedLine {
  update_id: number; from: number; chat_id: number; ts: number; message_id: number; text: string; reply_to_text?: string;
}

export interface SpawnReply { status: number | null; stdout: string; stderr: string; error?: Error }

export type VerifierSpawn = (cmd: string, args: string[], o: { cwd: string; env: Record<string, string>; timeout: number }) => SpawnReply;

export interface VerifySeams { spawn?: VerifierSpawn; env?: Readonly<Record<string, string | undefined>> }

const run: VerifierSpawn = (cmd, args, o) => spawnSync(cmd, args, { ...o, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

export function pinnedEnv(from: Readonly<Record<string, string | undefined>>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const name of PINNED_ENV) {
    const v = from[name];
    if (v !== undefined) env[name] = v;
  }
  return env;
}

export function verifyUpdate(id: number, seams: VerifySeams = {}): VerifiedLine {
  const env = pinnedEnv(seams.env ?? process.env);
  const r = (seams.spawn ?? run)('bun', [join(repo, 'scripts', 'telegram', 'operator-words.ts'), '--update', String(id)],
    { cwd: repo, env, timeout: TIMEOUT_MS });
  if (r.error || r.status !== 0) {
    const why = r.stderr?.split('\n').find((l) => l.trim())?.trim() ?? r.error?.message ?? `exit ${r.status}`;
    throw new Error(`the words verifier refused: ${why}`);
  }
  const bad = () => new Error('the words verifier did not print exactly one JSON line for this update');
  const lines = r.stdout.split('\n');
  if (lines.length !== 2 || lines[1] !== '') throw bad();
  let line: Partial<VerifiedLine> | null;
  try {
    line = JSON.parse(lines[0]) as Partial<VerifiedLine> | null;
  } catch {
    throw bad();
  }
  if (line?.update_id !== id || typeof line.text !== 'string' || !Number.isFinite(line.ts) || !Number.isSafeInteger(line.message_id)) throw bad();
  return line as VerifiedLine;
}
