import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SECTORS, resetSectorCache } from './sector.js';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

const FIELD = 'customfield_10212';

// The field's context and options are read live from Jira.
function fieldReply(path: string): unknown {
  if (path.split('?')[0].endsWith('/context')) return { values: [{ id: '1' }] };
  if (path.includes('/option')) return { values: SECTORS.map((value) => ({ value })) };
  return undefined;
}

describe('Sector field (HIMMEL-5710)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;
  let logs: string[];

  beforeEach(async () => {
    vi.clearAllMocks();
    logs = [];
    vi.spyOn(console, 'log').mockImplementation((...a: unknown[]) => {
      logs.push(a.join(' '));
    });
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
    mockRequest.mockImplementation(async (_m: string, path: string) => fieldReply(path) ?? {});
    resetSectorCache();
    process.env.JIRA_SECTOR_FIELD = FIELD;
  });

  afterEach(() => {
    delete process.env.JIRA_SECTOR_FIELD;
    vi.restoreAllMocks();
  });

  function freshProgram(register: (p: Command) => void): Command {
    const p = new Command();
    p.exitOverride();
    register(p);
    return p;
  }

  describe('resolveSector', () => {
    it('returns the canonical label, case-insensitively', async () => {
      const { resolveSector } = await import('./sector.js');
      expect(resolveSector('ship loop', SECTORS)).toBe('Ship loop');
      expect(resolveSector('Safety & enforcement', SECTORS)).toBe('Safety & enforcement');
    });

    it('refuses an unknown option, listing the valid ones and the opt-out', async () => {
      const { resolveSector } = await import('./sector.js');
      expect(() => resolveSector('Nope', SECTORS)).toThrow(
        /Unknown sector 'Nope'.*Fleet orchestration.*sector setup --opt-out/s,
      );
    });
  });

  describe('sectorField / sectorOptions', () => {
    it('treats unset, empty and none as not configured, and reads no options', async () => {
      const { sectorField, sectorOptions } = await import('./sector.js');
      for (const v of [undefined, '', '  ', 'none', 'NONE']) {
        if (v === undefined) delete process.env.JIRA_SECTOR_FIELD;
        else process.env.JIRA_SECTOR_FIELD = v;
        expect(sectorField()).toBeUndefined();
        expect(await sectorOptions()).toEqual([]);
      }
      expect(mockRequest).not.toHaveBeenCalled();
    });

    it('reads jira.sectorField from ~/.himmel/config.json; the env var overrides it', async () => {
      const { sectorField } = await import('./sector.js');
      const home = process.env.HOME!;
      mkdirSync(join(home, '.himmel'), { recursive: true });
      const cfg = join(home, '.himmel', 'config.json');
      try {
        delete process.env.JIRA_SECTOR_FIELD;
        writeFileSync(cfg, JSON.stringify({ jira: { sectorField: 'customfield_777' } }));
        expect(sectorField()).toBe('customfield_777');
        process.env.JIRA_SECTOR_FIELD = 'customfield_888';
        expect(sectorField()).toBe('customfield_888');
        delete process.env.JIRA_SECTOR_FIELD;
        writeFileSync(cfg, JSON.stringify({ jira: { sectorField: 'none' } }));
        expect(sectorField()).toBeUndefined();
        writeFileSync(cfg, '{not json');
        expect(sectorField()).toBeUndefined();
      } finally {
        rmSync(cfg, { force: true });
      }
    });

    it('reads the option list from the field contexts once, then serves the cache', async () => {
      const { sectorOptions } = await import('./sector.js');
      expect(await sectorOptions()).toEqual([...SECTORS]);
      expect(mockRequest.mock.calls.map((c) => c[1])).toEqual([
        `/field/${FIELD}/context?startAt=0&maxResults=100`,
        `/field/${FIELD}/context/1/option?startAt=0&maxResults=100`,
      ]);
      mockRequest.mockClear();
      expect(await sectorOptions()).toEqual([...SECTORS]);
      expect(mockRequest).not.toHaveBeenCalled();
    });

    it('follows pagination across contexts and options', async () => {
      const { sectorOptions } = await import('./sector.js');
      mockRequest.mockImplementation(async (_m: string, path: string) => {
        const at = Number(/startAt=(\d+)/.exec(path)![1]);
        if (path.split('?')[0].endsWith('/context')) {
          return at === 0 ? { isLast: false, values: [{ id: '1' }] } : { isLast: true, values: [{ id: '2' }] };
        }
        const ctx = /context\/(\d)\//.exec(path)![1];
        return at === 0
          ? { isLast: false, values: [{ value: `A${ctx}` }] }
          : { isLast: true, values: [{ value: `B${ctx}` }] };
      });
      expect(await sectorOptions()).toEqual(['A1', 'B1', 'A2', 'B2']);
    });

    it('returns no options, uncached, when the context API is refused, so Jira validates', async () => {
      const { sectorOptions, resolveSector } = await import('./sector.js');
      mockRequest.mockRejectedValue(new Error('403 Forbidden'));
      expect(await sectorOptions()).toEqual([]);
      expect(resolveSector(' Ship loop ', [])).toBe('Ship loop');
      mockRequest.mockImplementation(async (_m: string, path: string) => fieldReply(path) ?? {});
      expect(await sectorOptions()).toEqual([...SECTORS]);
    });
  });

  describe('edit --sector', () => {
    function readBack(value: string | null): void {
      mockRequest.mockImplementation(async (method: string, path: string) =>
        fieldReply(path) ??
        (method === 'GET' ? { fields: { [FIELD]: value === null ? null : { value } } } : {}),
      );
    }

    it('PUTs fields.customfield_10212 = {value: <canonical label>}', async () => {
      readBack('Ship loop');
      const { registerEdit } = await import('./edit.js');
      await freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--sector', 'ship loop']);
      const put = mockRequest.mock.calls.find((c) => c[0] === 'PUT');
      expect(put?.[2]).toEqual({ fields: { [FIELD]: { value: 'Ship loop' } } });
      expect(logs).toContain('HIMMEL-1 edited');
    });

    it('refuses an unknown option before any request', async () => {
      const { registerEdit } = await import('./edit.js');
      await expect(
        freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--sector', 'Bogus']),
      ).rejects.toThrow(/Unknown sector 'Bogus'/);
      expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
    });

    it('refuses --sector when sectors are not configured, before any request', async () => {
      delete process.env.JIRA_SECTOR_FIELD;
      const { registerEdit } = await import('./edit.js');
      await expect(
        freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--sector', 'Ship loop']),
      ).rejects.toThrow(/Sector is not configured.*sector setup/s);
      expect(mockRequest).not.toHaveBeenCalled();
    });

    it('fails loud when the read-back still shows another value', async () => {
      readBack('Visibility');
      const { registerEdit } = await import('./edit.js');
      await expect(
        freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--sector', 'Ship loop']),
      ).rejects.toThrow(/sector.*Ship loop.*Visibility/s);
    });
  });

  describe('get', () => {
    it('requests the Sector field and prints a Sector line', async () => {
      mockRequest.mockResolvedValue({
        key: 'HIMMEL-1',
        fields: {
          summary: 's',
          status: { name: 'To Do' },
          issuetype: { name: 'Task' },
          description: null,
          [FIELD]: { value: 'Visibility' },
        },
      });
      const { registerGet } = await import('./get.js');
      await freshProgram(registerGet).parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
      expect(mockRequest.mock.calls[0][1]).toContain(FIELD);
      expect(logs).toContain('Sector: Visibility');
    });

    it('does not request or print a Sector when sectors are not configured', async () => {
      delete process.env.JIRA_SECTOR_FIELD;
      mockRequest.mockResolvedValue({
        key: 'HIMMEL-1',
        fields: { summary: 's', status: { name: 'To Do' }, issuetype: { name: 'Task' }, description: null },
      });
      const { registerGet } = await import('./get.js');
      await freshProgram(registerGet).parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
      expect(mockRequest.mock.calls[0][1]).not.toContain('customfield');
      expect(logs.some((l) => l.startsWith('Sector:'))).toBe(false);
    });

    it('prints no Sector line when the field is empty', async () => {
      mockRequest.mockResolvedValue({
        key: 'HIMMEL-1',
        fields: { summary: 's', status: { name: 'To Do' }, issuetype: { name: 'Task' }, description: null, [FIELD]: null },
      });
      const { registerGet } = await import('./get.js');
      await freshProgram(registerGet).parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
      expect(logs.some((l) => l.startsWith('Sector:'))).toBe(false);
    });
  });

  describe('edit-batch', () => {
    let dir: string;
    beforeEach(() => {
      dir = mkdtempSync(join(tmpdir(), 'sector-batch-'));
      process.exitCode = undefined;
    });
    afterEach(() => {
      rmSync(dir, { recursive: true, force: true });
      process.exitCode = undefined;
    });

    function tsv(body: string): string {
      const p = join(dir, 'in.tsv');
      writeFileSync(p, body);
      return p;
    }

    // current: key -> sector label | null ; failPut: keys whose PUT throws
    function jira(current: Record<string, string | null>, failPut: string[] = []): void {
      const state = { ...current };
      mockRequest.mockImplementation(async (method: string, path: string, body?: { fields: Record<string, { value: string }> }) => {
        const fr = fieldReply(path);
        if (fr) return fr;
        const key = /\/issue\/([A-Z]+-\d+)/.exec(path)?.[1] ?? '';
        if (method === 'GET') {
          if (!(key in state)) throw new Error(`HTTP 404 ${key}`);
          const v = state[key];
          return { fields: { [FIELD]: v === null ? null : { value: v } } };
        }
        if (failPut.includes(key)) throw new Error('HTTP 400 boom');
        state[key] = body!.fields[FIELD].value;
        return {};
      });
    }

    async function run(file: string): Promise<void> {
      const { registerEditBatch } = await import('./edit-batch.js');
      await freshProgram(registerEditBatch).parseAsync(['node', 'jira', 'edit-batch', '--file', file]);
    }

    it('prints one result TSV row per input row: set, unchanged, failed', async () => {
      jira({ 'HIMMEL-1': null, 'HIMMEL-2': 'Visibility', 'HIMMEL-3': null }, ['HIMMEL-3']);
      await run(tsv('HIMMEL-1\tShip loop\nHIMMEL-2\tvisibility\nHIMMEL-3\tDeployment\n'));
      expect(logs).toEqual([
        'HIMMEL-1\tShip loop\tset',
        'HIMMEL-2\tVisibility\tunchanged',
        expect.stringMatching(/^HIMMEL-3\tDeployment\tfailed\t.*boom/),
      ]);
      expect(process.exitCode).toBe(1);
    });

    it('does not abort on a bad row (unknown sector, bad key, 404) and still processes the rest', async () => {
      jira({ 'HIMMEL-1': null, 'HIMMEL-9': null });
      await run(tsv('HIMMEL-5\tBogus\nnot-a-key\tShip loop\nHIMMEL-404\tShip loop\nHIMMEL-1\tShip loop\n'));
      expect(logs[0]).toMatch(/^HIMMEL-5\tBogus\tfailed\tUnknown sector/);
      expect(logs[1]).toMatch(/^not-a-key\tShip loop\tfailed\t/);
      expect(logs[2]).toMatch(/^HIMMEL-404\tShip loop\tfailed\t/);
      expect(logs[3]).toBe('HIMMEL-1\tShip loop\tset');
    });

    it('is idempotent: a second run over the same file only reports unchanged and PUTs nothing', async () => {
      jira({ 'HIMMEL-1': null });
      const f = tsv('HIMMEL-1\tShip loop\n');
      await run(f);
      mockRequest.mockClear();
      logs.length = 0;
      await run(f);
      expect(logs).toEqual(['HIMMEL-1\tShip loop\tunchanged']);
      expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
      expect(process.exitCode).toBeUndefined();
    });

    it('fails a row that does not have exactly two columns, without touching Jira', async () => {
      jira({ 'HIMMEL-1': null, 'HIMMEL-2': null });
      await run(tsv('HIMMEL-1\tShip loop\textra\nHIMMEL-2\n'));
      expect(logs[0]).toMatch(/^HIMMEL-1\tShip loop\tfailed\texpected 2 columns/);
      expect(logs[1]).toMatch(/^HIMMEL-2\t\tfailed\texpected 2 columns/);
      expect(mockRequest).not.toHaveBeenCalled();
    });

    it('skips a header row, blank lines and CRLF endings', async () => {
      jira({ 'HIMMEL-1': null });
      await run(tsv('key\tsector\r\n\r\nHIMMEL-1\tShip loop\r\n'));
      expect(logs).toEqual(['HIMMEL-1\tShip loop\tset']);
    });
  });
});
