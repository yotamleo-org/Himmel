import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { admissionsLedgerPath, appendAdmission, readAdmissions } from './admissions-ledger.js';

describe('admissions ledger (HIMMEL-6776)', () => {
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const ENV = ['HANDOVER_DIR', 'HIMMEL_ADMISSIONS_LEDGER', 'HIMMEL_CONSOLE_NAME'];

  beforeEach(() => {
    for (const k of ENV) saved[k] = process.env[k];
    for (const k of ENV) delete process.env[k];
    dir = mkdtempSync(join(tmpdir(), 'ledger-'));
  });
  afterEach(() => {
    for (const k of ENV) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    rmSync(dir, { recursive: true, force: true });
  });

  it('defaults to admissions-ledger.jsonl under HANDOVER_DIR', () => {
    process.env['HANDOVER_DIR'] = dir;
    expect(admissionsLedgerPath()).toBe(join(dir, 'admissions-ledger.jsonl'));
  });

  it('HIMMEL_ADMISSIONS_LEDGER overrides the path', () => {
    process.env['HANDOVER_DIR'] = dir;
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = join(dir, 'x.jsonl');
    expect(admissionsLedgerPath()).toBe(join(dir, 'x.jsonl'));
  });

  it('throws with neither set', () => {
    expect(() => admissionsLedgerPath()).toThrow(/HANDOVER_DIR/);
  });

  it('appends one JSON row per line and reads them back in order', () => {
    process.env['HANDOVER_DIR'] = dir;
    process.env['HIMMEL_CONSOLE_NAME'] = 'the-console';
    appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' });
    const second = appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-2', kind: 'override', reason: 'why' });
    expect(second).toMatchObject({ key: 'HIMMEL-2', kind: 'override', reason: 'why', actor: 'the-console' });
    expect(readFileSync(admissionsLedgerPath(), 'utf8').trim().split('\n')).toHaveLength(2);
    expect(readAdmissions().map((r) => r.key)).toEqual(['HIMMEL-1', 'HIMMEL-2']);
    expect(readAdmissions()[0]).toMatchObject({ gate: 'critical', version: 'v1.1.3' });
  });

  it('reads an absent ledger as empty', () => {
    process.env['HANDOVER_DIR'] = dir;
    expect(readAdmissions()).toEqual([]);
  });
});
