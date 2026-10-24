import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { behaviourKey, handoverRoot } from './handover-root.js';

describe('handoverRoot (HIMMEL-6917)', () => {
  let dir: string;
  let dotenv: string;
  let confDir: string;
  const realHome = process.env.HOME;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'handover-root-'));
    dotenv = join(dir, '.env');
    confDir = join(dir, 'home', '.himmel');
    mkdirSync(confDir, { recursive: true });
    process.env.HOME = join(dir, 'home');
  });
  afterEach(() => {
    process.env.HOME = realHome;
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
    const root = join(dir, 'from-dotenv');
    mkdirSync(root);
    writeFileSync(dotenv, `# comment\nJIRA_PROJECT_KEY=HIMMEL\nHANDOVER_DIR=${root}\n`);
    expect(handoverRoot({}, dotenv)).toBe(root);
  });

  it('a HANDOVER_DIR from the .env that is not a directory throws', () => {
    writeFileSync(dotenv, 'HANDOVER_DIR=/missing/from/dotenv\n');
    expect(() => handoverRoot({}, dotenv)).toThrow(/is not a directory/);
  });

  it('strips surrounding quotes from the .env value', () => {
    const root = join(dir, 'quoted');
    mkdirSync(root);
    writeFileSync(dotenv, `HANDOVER_DIR="${root}"\n`);
    expect(handoverRoot({}, dotenv)).toBe(root);
  });

  it('an empty HANDOVER_DIR line in the .env does not win over the default', () => {
    writeFileSync(dotenv, 'HANDOVER_DIR=\n');
    expect(handoverRoot({}, dotenv)).toMatch(/handovers$/);
  });

  it('defaults to <primary checkout>/handovers when neither env nor .env sets it', () => {
    expect(handoverRoot({}, join(dir, 'absent.env'))).toMatch(/handovers$/);
  });

  it('reads HANDOVER_DIR from ~/.himmel/himmel.conf when the env and the .env lack it', () => {
    const root = join(dir, 'from-conf');
    mkdirSync(root);
    writeFileSync(join(confDir, 'himmel.conf'), `# behaviour\nHANDOVER_DIR="${root}"\n`);
    expect(handoverRoot({}, join(dir, 'absent.env'))).toBe(root);
  });

  it('himmel.conf.local wins over himmel.conf, and both win over the .env', () => {
    const local = join(dir, 'from-local');
    const conf = join(dir, 'from-conf');
    const legacy = join(dir, 'from-dotenv');
    for (const d of [local, conf, legacy]) mkdirSync(d);
    writeFileSync(dotenv, `HANDOVER_DIR=${legacy}\n`);
    writeFileSync(join(confDir, 'himmel.conf'), `HANDOVER_DIR=${conf}\n`);
    expect(handoverRoot({}, dotenv)).toBe(conf);
    writeFileSync(join(confDir, 'himmel.conf.local'), `HANDOVER_DIR=${local}\n`);
    expect(handoverRoot({}, dotenv)).toBe(local);
  });

  it('an explicit HANDOVER_DIR still wins over himmel.conf', () => {
    const live = join(dir, 'live');
    mkdirSync(live);
    writeFileSync(join(confDir, 'himmel.conf'), 'HANDOVER_DIR=/from/conf\n');
    expect(handoverRoot({ HANDOVER_DIR: live }, dotenv)).toBe(live);
  });

  it('a himmel.conf HANDOVER_DIR that is not a directory throws', () => {
    writeFileSync(join(confDir, 'himmel.conf'), 'HANDOVER_DIR=/missing/from/conf\n');
    expect(() => handoverRoot({}, dotenv)).toThrow(/is not a directory/);
  });

  it('an empty himmel.conf line falls through to the .env', () => {
    const legacy = join(dir, 'from-dotenv');
    mkdirSync(legacy);
    writeFileSync(join(confDir, 'himmel.conf'), 'HANDOVER_DIR=\n');
    writeFileSync(dotenv, `HANDOVER_DIR=${legacy}\n`);
    expect(handoverRoot({}, dotenv)).toBe(legacy);
  });

  it('behaviourKey follows the HOME of the env it is given, not the process HOME', () => {
    writeFileSync(join(confDir, 'himmel.conf'), 'USER_SLUG=confslug\n');
    process.env.HOME = join(dir, 'elsewhere');
    expect(behaviourKey('USER_SLUG', { HOME: join(dir, 'home') }, join(dir, 'absent.env'))).toBe('confslug');
  });

  it('behaviourKey resolves USER_SLUG from himmel.conf when the env lacks it', () => {
    writeFileSync(join(confDir, 'himmel.conf'), 'USER_SLUG=confslug\n');
    expect(behaviourKey('USER_SLUG', {}, join(dir, 'absent.env'))).toBe('confslug');
    expect(behaviourKey('USER_SLUG', { USER_SLUG: 'live' }, join(dir, 'absent.env'))).toBe('live');
  });
});
