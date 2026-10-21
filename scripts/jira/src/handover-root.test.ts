import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { handoverRoot } from './handover-root.js';

describe('handoverRoot (HIMMEL-6917)', () => {
  let dir: string;
  let dotenv: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'handover-root-'));
    dotenv = join(dir, '.env');
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('an explicit HANDOVER_DIR wins over the .env line', () => {
    const root = join(dir, 'live');
    mkdirSync(root);
    writeFileSync(dotenv, 'HANDOVER_DIR=/from/dotenv\n');
    expect(handoverRoot({ HANDOVER_DIR: root }, dotenv)).toBe(root);
  });

  it('an explicit HANDOVER_DIR that is not a directory throws', () => {
    expect(() => handoverRoot({ HANDOVER_DIR: join(dir, 'missing') }, dotenv)).toThrow(/is not a directory/);
  });

  it('falls back to the HANDOVER_DIR line of the .env when the env is unset', () => {
    writeFileSync(dotenv, '# comment\nJIRA_PROJECT_KEY=HIMMEL\nHANDOVER_DIR=/from/dotenv\n');
    expect(handoverRoot({}, dotenv)).toBe('/from/dotenv');
  });

  it('an empty HANDOVER_DIR line in the .env does not win over the default', () => {
    writeFileSync(dotenv, 'HANDOVER_DIR=\n');
    expect(handoverRoot({}, dotenv)).toMatch(/handovers$/);
  });

  it('defaults to <primary checkout>/handovers when neither env nor .env sets it', () => {
    expect(handoverRoot({}, join(dir, 'absent.env'))).toMatch(/handovers$/);
  });
});
