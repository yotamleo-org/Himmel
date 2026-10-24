import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { buildEditFields, registerEdit } from './edit.js';
import { registerCreate } from './create.js';
import { registerVersions } from './versions.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

const PLAIN = PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled');
const HOME = ['--parent', 'HIMMEL-9'];

// v1.0.0 is released, so `current` is the earliest unreleased: v1.1.3.
const VERSIONS = [
  { id: '1', name: 'v1.0.0', released: true },
  { id: '2', name: 'v1.1.3' },
  { id: '3', name: 'v1.1.4' },
];

async function run(register: (p: Command) => void, args: string[]): Promise<void> {
  const p = new Command();
  p.exitOverride();
  register(p);
  await p.parseAsync(['node', 'jira', ...args]);
}

const call = (method: string) => mockRequest.mock.calls.find((c) => c[0] === method)?.[2];

describe('--affects-version (HIMMEL-6236)', () => {
  const savedKey = process.env.JIRA_PROJECT_KEY;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    let affects = [{ name: 'v1.1.3' }];
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'POST') return { key: 'HIMMEL-1' };
      if (method === 'PUT') {
        const ops = (body as { update?: { versions: Array<{ add?: { name: string } }> } }).update?.versions ?? [];
        affects = [...affects, ...ops.flatMap((o) => (o.add ? [o.add] : []))];
      }
      if (method !== 'GET') return {};
      return path.endsWith('/versions') ? VERSIONS : { fields: { versions: affects } };
    });
  });

  afterEach(() => {
    if (savedKey === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = savedKey;
  });

  describe('edit', () => {
    it('maps to a full-replace versions array', () => {
      expect(buildEditFields({ affectsVersion: 'v1.1.3' })).toEqual({ versions: [{ name: 'v1.1.3' }] });
    });

    it('validates the version then sends fields.versions', async () => {
      await run(registerEdit, ['edit', 'HIMMEL-1', '--affects-version', 'v1.1.3']);
      expect(call('PUT')).toEqual({ fields: { versions: [{ name: 'v1.1.3' }] } });
    });

    it('refuses an unknown version naming the project, without ever PUTting', async () => {
      await expect(run(registerEdit, ['edit', 'HIMMEL-1', '--affects-version', 'v9.9.9'])).rejects.toThrow(
        /no version named "v9\.9\.9" in project HIMMEL/,
      );
      expect(call('PUT')).toBeUndefined();
    });

    it('resolves `current` to the earliest unreleased version', async () => {
      await run(registerEdit, ['edit', 'HIMMEL-1', '--affects-version', 'current']);
      expect(call('PUT')).toEqual({ fields: { versions: [{ name: 'v1.1.3' }] } });
    });

    it('fails loud when the read-back shows the version was not set', async () => {
      mockRequest.mockImplementation(async (method: string, path: string) => {
        if (method !== 'GET') return {};
        return path.endsWith('/versions') ? VERSIONS : { fields: { versions: [] } };
      });
      await expect(run(registerEdit, ['edit', 'HIMMEL-1', '--affects-version', 'v1.1.3'])).rejects.toThrow(
        /affects-version was not changed/,
      );
    });
  });

  describe('create', () => {
    const create = (extra: string[]) =>
      run(registerCreate, ['create', '--desc', PLAIN, '--type', 'Task', '--backlog', '--title', 't', ...extra, ...HOME]);
    const posted = () => call('POST') as { fields: { versions?: unknown } } | undefined;

    it('validates then sets versions', async () => {
      await create(['--affects-version', 'v1.0.0']);
      expect(posted()?.fields.versions).toEqual([{ name: 'v1.0.0' }]);
    });

    it('resolves `current` to the earliest unreleased version', async () => {
      await create(['--affects-version', 'current']);
      expect(posted()?.fields.versions).toEqual([{ name: 'v1.1.3' }]);
    });

    it('refuses an unknown version without ever POSTing', async () => {
      await expect(create(['--affects-version', 'v9.9.9'])).rejects.toThrow(
        /no version named "v9\.9\.9" in project HIMMEL/,
      );
      expect(posted()).toBeUndefined();
    });

    it('sets no versions when the flag is absent', async () => {
      await create([]);
      expect(posted()?.fields.versions).toBeUndefined();
    });
  });

  describe('affects-version verb', () => {
    const verb = (args: string[]) => run(registerVersions, ['affects-version', 'HIMMEL-9', ...args]);

    it('--add validates, PUTs update.versions add, writes the breadcrumb', async () => {
      await verb(['--add', 'v1.1.4']);
      expect(call('PUT')).toEqual({ update: { versions: [{ add: { name: 'v1.1.4' } }] } });
      expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIMMEL-9');
      expect(console.log).toHaveBeenCalledWith('HIMMEL-9 affectsVersion +v1.1.4');
    });

    it('--remove sends the remove verb', async () => {
      await verb(['--remove', 'v1.0.0']);
      expect(call('PUT')).toEqual({ update: { versions: [{ remove: { name: 'v1.0.0' } }] } });
      expect(console.log).toHaveBeenCalledWith('HIMMEL-9 affectsVersion -v1.0.0');
    });

    it('--add current resolves to the earliest unreleased version', async () => {
      await verb(['--add', 'current']);
      expect(call('PUT')).toEqual({ update: { versions: [{ add: { name: 'v1.1.3' } }] } });
    });

    it('refuses an unknown version without a PUT', async () => {
      await expect(verb(['--add', 'nope'])).rejects.toThrow(/no version named "nope" in project HIMMEL/);
      expect(call('PUT')).toBeUndefined();
    });

    it('needs exactly one of --add/--remove', async () => {
      await expect(verb([])).rejects.toThrow(/exactly one of --add/);
      await expect(verb(['--add', 'a', '--remove', 'b'])).rejects.toThrow(/exactly one of --add/);
      expect(mockRequest).not.toHaveBeenCalled();
    });
  });
});
