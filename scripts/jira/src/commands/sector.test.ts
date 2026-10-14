import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

const FIELD = 'customfield_10212';

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
  });

  afterEach(() => {
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
      expect(resolveSector('ship loop')).toBe('Ship loop');
      expect(resolveSector('Safety & enforcement')).toBe('Safety & enforcement');
    });

    it('refuses an unknown option and lists the valid ones', async () => {
      const { resolveSector } = await import('./sector.js');
      expect(() => resolveSector('Nope')).toThrow(/Unknown sector 'Nope'.*Fleet orchestration/s);
    });
  });

  describe('edit --sector', () => {
    function readBack(value: string | null): void {
      mockRequest.mockImplementation(async (method: string) =>
        method === 'GET' ? { fields: { [FIELD]: value === null ? null : { value } } } : {},
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

    it('skips a header row, blank lines and CRLF endings', async () => {
      jira({ 'HIMMEL-1': null });
      await run(tsv('key\tsector\r\n\r\nHIMMEL-1\tShip loop\r\n'));
      expect(logs).toEqual(['HIMMEL-1\tShip loop\tset']);
    });
  });
});
