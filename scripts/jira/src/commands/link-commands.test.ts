import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn() }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerLink } from './link.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerLink(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const TYPES = {
  issueLinkTypes: [
    { name: 'Relates', inward: 'relates to', outward: 'relates to' },
    { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' },
  ],
};

// GET answers the type list and, for the post-POST read-back, the link just made.
const jiraWith = (types: unknown, outward: string, type: string) => async (m: string, p: string) => {
  if (m !== 'GET') return {};
  return p.startsWith('/issue/')
    ? { fields: { issuelinks: [{ type: { name: type }, outwardIssue: { key: outward } }] } }
    : types;
};

describe('link / links / unlink', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('link A --blocks B: POSTs A as inward (the blocker) and prints the stored reading', async () => {
    mockRequest.mockImplementation(jiraWith(TYPES, 'B-2', 'Blocks'));
    await run(['link', 'A-1', '--blocks', 'B-2']);
    expect(mockRequest).toHaveBeenNthCalledWith(1, 'GET', '/issueLinkType');
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Blocks' },
      inwardIssue: { key: 'A-1' },
      outwardIssue: { key: 'B-2' },
    });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('A-1');
    expect(console.log).toHaveBeenCalledWith('Linked: A-1 blocks B-2');
  });

  it('link A --blocked-by B: POSTs B as inward (the blocker), A as outward', async () => {
    mockRequest.mockImplementation(jiraWith(TYPES, 'A-1', 'Blocks'));
    await run(['link', 'A-1', '--blocked-by', 'B-2']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Blocks' },
      inwardIssue: { key: 'B-2' },
      outwardIssue: { key: 'A-1' },
    });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('A-1');
    expect(console.log).toHaveBeenCalledWith('Linked: B-2 blocks A-1');
  });

  it('bare link A B --type Blocks is refused naming the explicit forms, never POSTs', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? TYPES : {}));
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['link', 'A-1', 'B-2', '--type', 'blocks'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toContain('--blocks');
    expect(msg).toContain('--blocked-by');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
    exit.mockRestore();
  });

  it('--blocks with a second positional, both flags, or a non-Blocks --type is refused', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? TYPES : {}));
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    for (const args of [
      ['link', 'A-1', 'B-2', '--blocks', 'C-3'],
      ['link', 'A-1', '--blocks', 'B-2', '--blocked-by', 'C-3'],
      ['link', 'A-1', '--blocks', 'B-2', '--type', 'Relates'],
    ]) {
      await expect(run(args)).rejects.toThrow('exit');
    }
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
    exit.mockRestore();
  });

  it('bare link A B --type Duplicate (other directional types) is still accepted', async () => {
    mockRequest.mockImplementation(jiraWith(
      { issueLinkTypes: [{ name: 'Duplicate', inward: 'is duplicated by', outward: 'duplicates' }] },
      'B-2',
      'Duplicate',
    ));
    await run(['link', 'A-1', 'B-2', '--type', 'Duplicate']);
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'POST', '/issueLink', {
      type: { name: 'Duplicate' },
      inwardIssue: { key: 'A-1' },
      outwardIssue: { key: 'B-2' },
    });
  });

  it('link A B with no --type (Relates) still works bare', async () => {
    mockRequest.mockImplementation(jiraWith(TYPES, 'B-2', 'Relates'));
    await run(['link', 'A-1', 'B-2', '--type', 'Relates']);
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'POST', '/issueLink', {
      type: { name: 'Relates' },
      inwardIssue: { key: 'A-1' },
      outwardIssue: { key: 'B-2' },
    });
  });

  it('link defaults to Relates', async () => {
    mockRequest.mockImplementation(jiraWith(TYPES, 'B-2', 'Relates'));
    await run(['link', 'A-1', 'B-2']);
    expect(mockRequest.mock.calls[1][2]).toMatchObject({ type: { name: 'Relates' } });
    expect(console.log).toHaveBeenCalledWith('Linked: A-1 relates to B-2');
  });

  it('link with an unknown type lists the valid ones, exits 1, never POSTs', async () => {
    mockRequest.mockResolvedValue(TYPES);
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['link', 'A-1', 'B-2', '--type', 'Nope'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(console.error).toHaveBeenCalledWith('Link type "Nope" not found. Available:');
    expect(console.error).toHaveBeenCalledWith('- Blocks');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
    exit.mockRestore();
  });

  it('links: GETs issuelinks and prints a directed row per link', async () => {
    mockRequest.mockResolvedValue({
      fields: {
        issuelinks: [
          { id: '10', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'B-2' } },
        ],
      },
    });
    await run(['links', 'A-1']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/issue/A-1?fields=issuelinks');
    expect(console.log).toHaveBeenCalledWith('10\tBlocks\tinward=A-1\toutward=B-2\tA-1 blocks B-2');
  });

  it('links with none prints the empty line', async () => {
    mockRequest.mockResolvedValue({ fields: {} });
    await run(['links', 'A-1']);
    expect(console.log).toHaveBeenCalledWith('A-1: no issue links');
  });

  it('unlink: DELETEs the single matching link id and prints it', async () => {
    mockRequest.mockImplementation(async (m: string) =>
      m === 'GET'
        ? {
            fields: {
              issuelinks: [
                { id: '10', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'B-2' } },
                { id: '11', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'C-3' } },
              ],
            },
          }
        : {},
    );
    await run(['unlink', 'A-1', 'B-2']);
    expect(mockRequest).toHaveBeenCalledWith('DELETE', '/issueLink/10');
    expect(mockRequest.mock.calls.filter((c) => c[0] === 'DELETE')).toHaveLength(1);
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('A-1');
    expect(console.log).toHaveBeenCalledWith('Unlinked inward=A-1 outward=B-2 type=Blocks id=10');
  });

  it('unlink with no matching link rejects and never DELETEs', async () => {
    mockRequest.mockResolvedValue({ fields: { issuelinks: [] } });
    await expect(run(['unlink', 'A-1', 'B-2'])).rejects.toThrow(/No issue link found with inward=A-1, outward=B-2/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'DELETE')).toBe(false);
  });
});

describe('link — blocker version placement', () => {
  let blockerVersions: { name: string }[];
  let targetVersions: { name: string }[];
  let done: boolean;
  let unreadable: boolean;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    blockerVersions = [];
    targetVersions = [{ name: 'v1.1.3' }];
    done = false;
    unreadable = false;
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method !== 'GET') return {};
      if (path === '/issueLinkType') return TYPES;
      if (path.startsWith('/project/')) return [{ id: '113', name: 'v1.1.3', released: false }];
      if (path.endsWith('?fields=issuelinks')) {
        return { fields: { issuelinks: [{ type: { name: 'Blocks' }, outwardIssue: { key: 'HIMMEL-1620' } }] } };
      }
      if (unreadable) throw new Error('Jira unavailable');
      const blocker = path.startsWith('/issue/HIMMEL-1158?') || path.startsWith('/issue/HIMMEL-6559?');
      return { fields: {
        project: { key: 'HIMMEL' },
        fixVersions: blocker ? blockerVersions : targetVersions,
        status: { statusCategory: { key: blocker && done ? 'done' : 'new' } },
      } };
    });
  });

  const writes = () => mockRequest.mock.calls.filter(([method]) => method !== 'GET');

  it.each(['HIMMEL-6575', 'HIMMEL-6582'])('refuses versionless 6559 blocking %s before any write', async (target) => {
    await expect(run(['link', 'HIMMEL-6559', '--blocks', target])).rejects.toThrow(/v1\.1\.3.*--backlog/);
    expect(writes()).toEqual([]);
  });

  it('refuses versionless 1158 through --blocked-by before any write', async () => {
    await expect(run(['link', 'HIMMEL-1620', '--blocked-by', 'HIMMEL-1158'])).rejects.toThrow(/v1\.1\.3.*--backlog/);
    expect(writes()).toEqual([]);
  });

  it('permits the existing blocker when it already carries the active target version', async () => {
    blockerVersions = [{ name: 'v1.1.3' }];
    await run(['link', 'HIMMEL-1620', '--blocked-by', 'HIMMEL-1158']);
    expect(writes()).toEqual([['POST', '/issueLink', {
      type: { name: 'Blocks' }, inwardIssue: { key: 'HIMMEL-1158' }, outwardIssue: { key: 'HIMMEL-1620' },
    }]]);
  });

  it('refuses a later-version blocker rather than treating any fixVersion as sufficient', async () => {
    blockerVersions = [{ name: 'v1.1.4' }];
    await expect(run(['link', 'HIMMEL-1158', '--blocks', 'HIMMEL-1620'])).rejects.toThrow(/v1\.1\.3.*--backlog/);
    expect(writes()).toEqual([]);
  });

  it('allows an explicit --backlog without modifying the existing blocker', async () => {
    await run(['link', 'HIMMEL-1158', '--blocks', 'HIMMEL-1620', '--backlog']);
    expect(writes().map(([method, path]) => [method, path])).toEqual([['POST', '/issueLink']]);
  });

  it('does not require a version on a Done blocker', async () => {
    done = true;
    await run(['link', 'HIMMEL-1158', '--blocks', 'HIMMEL-1620']);
    expect(writes()).toHaveLength(1);
  });

  it('does not inherit from a non-current target', async () => {
    targetVersions = [{ name: 'v1.1.4' }];
    await run(['link', 'HIMMEL-1158', '--blocks', 'HIMMEL-1620']);
    expect(writes()).toHaveLength(1);
  });

  it('fails closed when placement cannot be read', async () => {
    unreadable = true;
    await expect(run(['link', 'HIMMEL-1158', '--blocks', 'HIMMEL-1620'])).rejects.toThrow(/Jira unavailable/);
    expect(writes()).toEqual([]);
  });

  it('link --split-from refuses a versionless open split before any write', async () => {
    await expect(run(['link', 'HIMMEL-1158', '--split-from', 'HIMMEL-1620'])).rejects.toThrow(/v1\.1\.3.*--backlog/);
    expect(writes()).toEqual([]);
  });

  it('link --split-from records a Relates link when the split is already versioned', async () => {
    blockerVersions = [{ name: 'v1.1.3' }];
    const prior = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (path.endsWith('?fields=issuelinks')) return { fields: {
        issuelinks: [{ type: { name: 'Relates' }, outwardIssue: { key: 'HIMMEL-1620' } }],
      } };
      return prior(method, path, body);
    });
    await run(['link', 'HIMMEL-1158', '--split-from', 'HIMMEL-1620']);
    expect(writes()).toEqual([['POST', '/issueLink', {
      type: { name: 'Relates' }, inwardIssue: { key: 'HIMMEL-1158' }, outwardIssue: { key: 'HIMMEL-1620' },
    }]]);
  });

  afterEach(() => vi.restoreAllMocks());
});
