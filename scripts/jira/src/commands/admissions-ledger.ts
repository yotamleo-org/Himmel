import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { dirname, join } from 'node:path';

// Append-only record of every ticket admitted into a version past the intake
// gate: one JSON object per line, read by the board.
export interface Admission {
  ts: string;
  version: string;
  key: string;
  gate?: string;
  kind?: 'override' | 'deferral' | 'rm-admit';
  actor: string;
  reason?: string;
  /** The release-manager session that ruled an `rm-admit` row. */
  by?: string;
}

export type AdmissionInput = Pick<Admission, 'version' | 'key' | 'gate' | 'kind' | 'reason' | 'by'>;

function admissionsLedgerPath(): string {
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

/** Throws unless the ledger can take an append, so a refusal lands before the ticket is filed. Writes no row. */
export function assertAdmissionsWritable(): void {
  const path = admissionsLedgerPath();
  mkdirSync(dirname(path), { recursive: true });
  closeSync(openSync(path, 'a'));
}

/** Every row, oldest first; with a version, only that version's rows. Throws when no ledger location is set. */
export function readAdmissions(version?: string): Admission[] {
  const path = admissionsLedgerPath();
  if (!existsSync(path)) return [];
  const rows = readFileSync(path, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as Admission);
  return version === undefined ? rows : rows.filter((r) => r.version === version);
}
