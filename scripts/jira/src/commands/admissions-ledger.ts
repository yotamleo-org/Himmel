import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { dirname, join } from 'node:path';

// Append-only record of every ticket admitted into a version past the intake
// gate: one JSON object per line, read by the board.
export interface Admission {
  ts: string;
  version: string;
  key: string;
  gate?: string;
  kind?: 'override';
  actor: string;
  reason?: string;
}

export type AdmissionInput = Pick<Admission, 'version' | 'key' | 'gate' | 'kind' | 'reason'>;

export function admissionsLedgerPath(): string {
  const explicit = process.env['HIMMEL_ADMISSIONS_LEDGER'];
  if (explicit) return explicit;
  const root = process.env['HANDOVER_DIR'];
  if (!root) throw new Error('the admissions ledger needs HANDOVER_DIR (or HIMMEL_ADMISSIONS_LEDGER) set');
  return join(root, 'admissions-ledger.jsonl');
}

export function appendAdmission(row: AdmissionInput): Admission {
  const path = admissionsLedgerPath();
  const admission: Admission = {
    ts: new Date().toISOString(),
    ...row,
    actor: process.env['HIMMEL_CONSOLE_NAME'] || userInfo().username,
  };
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(admission) + '\n');
  return admission;
}

export function readAdmissions(): Admission[] {
  const path = admissionsLedgerPath();
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as Admission);
}

/**
 * Validates a console override before anything is filed: a reason, the console
 * marker and a ledger location are all required. Returns the trimmed reason.
 */
export function checkConsoleOverride(reason: string): string {
  const trimmed = reason.trim();
  if (!trimmed) throw new Error('--console-override needs a reason');
  // ponytail: any same-uid caller can set HIMMEL_CONSOLE, upgrade path: the RM signed-row design (HIMMEL-6796)
  if (process.env['HIMMEL_CONSOLE'] !== '1') {
    throw new Error('--console-override is for the console session only (HIMMEL_CONSOLE=1 is not set)');
  }
  admissionsLedgerPath();
  return trimmed;
}
