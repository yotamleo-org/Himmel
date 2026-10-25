import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

import { request } from '../client.js';
import { registerHistory } from './history.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function freshProgram(): Command {
  const p = new Command();
  p.exitOverride();
  registerHistory(p);
  return p;
}

const page = (startAt: number, isLast: boolean, values: unknown[]) => ({ startAt, maxResults: values.length, isLast, values });

const entry = (created: string, field: string, from: string | null, to: string | null) => ({
  created,
  author: { displayName: 'Bot' },
  items: [{ field, fromString: from, toString: to }],
});

describe('history', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  it('prints every changelog item across pages, one line each', async () => {
    mockRequest
      .mockResolvedValueOnce(page(0, false, [entry('2026-10-24T10:00:00.000+0000', 'status', 'To Do', 'Done')]))
      .mockResolvedValueOnce(page(1, true, [entry('2026-10-24T11:00:00.000+0000', 'Fix Version', null, 'v1.1.3')]));
    await freshProgram().parseAsync(['node', 'jira', 'history', 'HIMMEL-1']);
    expect(mockRequest.mock.calls.map((c) => c[1])).toEqual([
      '/issue/HIMMEL-1/changelog?startAt=0&maxResults=100',
      '/issue/HIMMEL-1/changelog?startAt=1&maxResults=100',
    ]);
    const lines = logSpy.mock.calls.map((c) => c[0]);
    expect(lines).toEqual([
      '2026-10-24T10:00:00.000+0000  Bot  status: To Do → Done',
      '2026-10-24T11:00:00.000+0000  Bot  Fix Version: (none) → v1.1.3',
    ]);
  });

  it('--field keeps only the items on that field', async () => {
    mockRequest.mockResolvedValueOnce(page(0, true, [
      entry('t1', 'status', 'To Do', 'Done'),
      entry('t2', 'Fix Version', 'v1.1.2', null),
    ]));
    await freshProgram().parseAsync(['node', 'jira', 'history', 'HIMMEL-1', '--field', 'fix version']);
    expect(logSpy.mock.calls.map((c) => c[0])).toEqual(['t2  Bot  Fix Version: v1.1.2 → (none)']);
  });
});
