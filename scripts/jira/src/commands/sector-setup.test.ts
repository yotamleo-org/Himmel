import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

import { request } from '../client.js';
import { configSnippet, runSetup, setupCalls, SECTOR_EXPLANATION } from './sector-setup.js';
import { SECTORS } from './sector.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

describe('sector setup (HIMMEL-6277)', () => {
  let out: string[];
  let err: string[];
  let dir: string;

  beforeEach(() => {
    vi.clearAllMocks();
    out = [];
    err = [];
    dir = mkdtempSync(join(tmpdir(), 'sector-setup-'));
    vi.spyOn(console, 'log').mockImplementation((...a: unknown[]) => void out.push(a.join(' ')));
    vi.spyOn(console, 'error').mockImplementation((...a: unknown[]) => void err.push(a.join(' ')));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it('--dry-run prints the explanation, the default set and the exact calls, and sends nothing', async () => {
    await runSetup({ dryRun: true });
    const text = out.join('\n');
    expect(text).toContain(SECTOR_EXPLANATION);
    for (const s of SECTORS) expect(text).toContain(`- ${s}`);
    expect(text).toContain('POST /field {"name":"Sector"');
    expect(text).toContain('POST /field/<field id>/context/<context id>/option');
    expect(text).toContain('POST /screens/addToDefault/<field id>');
    expect(text).toContain('nothing was created');
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('--sectors replaces the default set', async () => {
    await runSetup({ dryRun: true, sectors: 'Billing, Search ,' });
    const text = out.join('\n');
    expect(text).toContain('- Billing');
    expect(text).toContain('- Search');
    expect(text).not.toContain('Ship loop');
    expect(setupCalls(['A'])[2]!.body).toEqual({ options: [{ value: 'A' }] });
  });

  it('--yes creates the field, its options and the screen entry, then prints the config.json snippet', async () => {
    mockRequest.mockImplementation(async (m: string, path: string) => {
      if (m === 'POST' && path === '/field') return { id: 'customfield_20001' };
      if (path.endsWith('/context')) return { values: [{ id: '77' }] };
      return {};
    });
    await runSetup({ yes: true, sectors: 'A,B' });
    expect(mockRequest.mock.calls.map((c) => `${c[0]} ${c[1]}`)).toEqual([
      'POST /field',
      'GET /field/customfield_20001/context',
      'POST /field/customfield_20001/context/77/option',
      'POST /screens/addToDefault/customfield_20001',
    ]);
    expect(mockRequest.mock.calls[2]![2]).toEqual({ options: [{ value: 'A' }, { value: 'B' }] });
    expect(out.join('\n')).toContain('"sectorField": "customfield_20001"');
  });

  it('a failed screen add is a warning, not a failure', async () => {
    mockRequest.mockImplementation(async (_m: string, path: string) => {
      if (path === '/field') return { id: 'customfield_20001' };
      if (path.endsWith('/context')) return { values: [{ id: '77' }] };
      if (path.startsWith('/screens/')) throw new Error('HTTP 400');
      return {};
    });
    await runSetup({ yes: true });
    expect(err.join('\n')).toMatch(/could not add customfield_20001 to the default screen/);
    expect(out.join('\n')).toContain('"sectorField": "customfield_20001"');
  });

  it('asks before creating; anything but y aborts with nothing sent', async () => {
    await runSetup({}, async () => 'n');
    expect(out.join('\n')).toContain('Aborted; nothing was created.');
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('--opt-out prints the "none" config snippet, explains what is lost, and writes nothing', async () => {
    const home = process.env.HOME;
    process.env.HOME = dir;
    try {
      await runSetup({ optOut: true });
      expect(out.join('\n')).toMatch(/Lost:.*no longer requires or sends a Sector/s);
      expect(out.join('\n')).toContain('"sectorField": "none"');
      expect(existsSync(join(dir, '.himmel'))).toBe(false);
      expect(mockRequest).not.toHaveBeenCalled();
    } finally {
      process.env.HOME = home;
    }
  });

  it('configSnippet is the exact jira.sectorField JSON and says setup never writes the file', () => {
    const text = configSnippet('customfield_10212');
    expect(text).toContain('~/.himmel/config.json');
    expect(JSON.parse(text.slice(text.indexOf('{')))).toEqual({ jira: { sectorField: 'customfield_10212' } });
    expect(text).toContain('never writes');
  });
});
