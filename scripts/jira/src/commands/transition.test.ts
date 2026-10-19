import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn(), projectKey: () => 'HIMMEL' }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { findTransition, registerTransition } from './transition.js';
import { request } from '../client.js';
import type { JiraTransition } from '../types.js';

const transitions: JiraTransition[] = [
  { id: '11', name: 'To Do' },
  { id: '21', name: 'In Progress' },
  { id: '31', name: 'Done' },
];

describe('findTransition', () => {
  it('finds by exact name', () => {
    expect(findTransition(transitions, 'In Progress')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('finds case-insensitively', () => {
    expect(findTransition(transitions, 'in progress')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('returns undefined when not found', () => {
    expect(findTransition(transitions, 'Nonexistent')).toBeUndefined();
  });
});

// Transition list copied from the live HIMMEL project (`jira transitions <key>`).
const LIVE: JiraTransition[] = [
  { id: '11', name: 'To Do' },
  { id: '4', name: 'Backlog' },
  { id: '21', name: 'In Progress' },
  { id: '2', name: 'In Review' },
  { id: '3', name: 'IN CI' },
  { id: '31', name: 'Done' },
  { id: '5', name: 'Closed' },
  { id: '6', name: 'In Public' },
  { id: '7', name: 'wont do' },
  { id: '8', name: 'wont fix' },
];
const VERSIONS = [
  { id: '1', name: 'v1.1.2', released: true, releaseDate: '2026-10-11' },
  { id: '2', name: 'v1.1.3', released: false },
];

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function wire(fixVersions: Array<{ name: string }>) {
  mockRequest.mockImplementation(async (method: string, path: string) => {
    if (method === 'GET' && path.endsWith('/transitions')) return { transitions: LIVE };
    if (method === 'GET' && path.endsWith('/versions')) return VERSIONS;
    if (method === 'GET' && path.includes('/issue/')) return { fields: { fixVersions } };
    return {};
  });
}

async function run(...args: string[]) {
  const p = new Command();
  p.exitOverride();
  registerTransition(p);
  await p.parseAsync(['node', 'jira', 'transition', ...args]);
}

const puts = () => mockRequest.mock.calls.filter((c) => c[0] === 'PUT');

describe('transition to Done stamps the current fixVersion (HIMMEL-6416)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('sets the earliest unreleased version on a versionless ticket', async () => {
    wire([]);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
    expect(puts()[0][1]).toBe('/issue/HIMMEL-1');
    expect(JSON.stringify(puts()[0][2])).toContain('v1.1.3');
  });

  it('--no-version leaves it empty', async () => {
    wire([]);
    await run('HIMMEL-1', 'Done', '--no-version');
    expect(puts()).toHaveLength(0);
  });

  it('keeps a version the ticket already has', async () => {
    wire([{ name: 'v1.1.2' }]);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
  });

  it('does not stamp a Closed or wont-do close', async () => {
    wire([]);
    await run('HIMMEL-1', 'Closed');
    await run('HIMMEL-1', 'wont do');
    expect(puts()).toHaveLength(0);
  });

  it('stamps before transitioning, so a failed stamp leaves the issue open', async () => {
    wire([]);
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'PUT') throw new Error('edit rejected');
      return base(method, path, body);
    });
    await expect(run('HIMMEL-1', 'Done')).rejects.toThrow('edit rejected');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
  });

  it('does not stamp a non-Done transition', async () => {
    wire([]);
    await run('HIMMEL-1', 'In Progress');
    expect(puts()).toHaveLength(0);
  });
});
