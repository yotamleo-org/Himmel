import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendAdmission, assertAdmissionsWritable, readAdmissions } from './admissions-ledger.js';

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
    appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' });
    expect(readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8')).toContain('HIMMEL-1');
  });

  it('refuses a ledger outside the temp dir under vitest (HIMMEL-7434)', () => {
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = '/srv/handovers/admissions-ledger.jsonl';
    expect(() => appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' })).toThrow(/outside the temp dir/);
  });

  it('HIMMEL_ADMISSIONS_LEDGER overrides the path', () => {
    process.env['HANDOVER_DIR'] = dir;
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = join(dir, 'x.jsonl');
    appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' });
    expect(readFileSync(join(dir, 'x.jsonl'), 'utf8')).toContain('HIMMEL-1');
  });

  it('throws on append and on read when HANDOVER_DIR is set to a missing directory', () => {
    process.env['HANDOVER_DIR'] = join(dir, 'missing');
    expect(() => appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' })).toThrow(/HANDOVER_DIR/);
    expect(() => readAdmissions()).toThrow(/HANDOVER_DIR/);
  });

  it('appends one JSON row per line and reads them back in order', () => {
    process.env['HANDOVER_DIR'] = dir;
    process.env['HIMMEL_CONSOLE_NAME'] = 'the-console';
    appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' });
    const second = appendAdmission({ version: 'v1.1.4', key: 'HIMMEL-2', kind: 'override', reason: 'why' });
    expect(second).toMatchObject({ key: 'HIMMEL-2', kind: 'override', reason: 'why', actor: 'the-console' });
    expect(readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8').trim().split('\n')).toHaveLength(2);
    expect(readAdmissions().map((r) => r.key)).toEqual(['HIMMEL-1', 'HIMMEL-2']);
    expect(readAdmissions()[0]).toMatchObject({ gate: 'critical', version: 'v1.1.3' });
  });

  it('filters the read by version', () => {
    process.env['HANDOVER_DIR'] = dir;
    appendAdmission({ version: 'v1.1.3', key: 'HIMMEL-1', gate: 'critical' });
    appendAdmission({ version: 'v1.1.4', key: 'HIMMEL-2', gate: 'regression' });
    expect(readAdmissions('v1.1.4').map((r) => r.key)).toEqual(['HIMMEL-2']);
  });

  it('assertAdmissionsWritable passes on a writable ledger and writes no row', () => {
    process.env['HANDOVER_DIR'] = dir;
    assertAdmissionsWritable();
    expect(readAdmissions()).toEqual([]);
  });

  it('assertAdmissionsWritable throws with no location, and when the location cannot be opened for append', () => {
    process.env['HANDOVER_DIR'] = join(dir, 'missing');
    expect(() => assertAdmissionsWritable()).toThrow(/HANDOVER_DIR/);
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = dir;
    expect(() => assertAdmissionsWritable()).toThrow();
  });

  it('reads an absent ledger as empty', () => {
    process.env['HANDOVER_DIR'] = dir;
    expect(readAdmissions()).toEqual([]);
  });
});
