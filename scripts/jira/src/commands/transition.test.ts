import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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

function wire(fixVersions: Array<{ name: string }>, versions: unknown[] = VERSIONS) {
  let current = fixVersions;
  mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
    if (method === 'PUT') {
      const ops = (body as { update: { fixVersions: Array<{ add?: { name: string } }> } }).update.fixVersions;
      current = ops.flatMap((o) => (o.add ? [o.add] : []));
    }
    if (method === 'GET' && path.endsWith('/transitions')) return { transitions: LIVE };
    if (method === 'GET' && path.endsWith('/versions')) return versions;
    if (method === 'GET' && path.includes('/issue/')) return { fields: { fixVersions: current } };
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

describe('transition to Done respects the intake gate of a frozen version (HIMMEL-6796)', () => {
  const FROZEN = [
    { id: '1', name: 'v1.1.2', released: true },
    { id: '2', name: 'v1.1.3', released: false, description: 'frozen: 2026-10-20\nfrozen-keys: HIMMEL-2, HIMMEL-3' },
  ];
  let dir: string;
  const saved = process.env['HIMMEL_ADMISSIONS_LEDGER'];

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    dir = mkdtempSync(join(tmpdir(), 'transition-gate-'));
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = join(dir, 'admissions-ledger.jsonl');
  });

  afterEach(() => {
    process.exitCode = undefined;
    if (saved === undefined) delete process.env['HIMMEL_ADMISSIONS_LEDGER'];
    else process.env['HIMMEL_ADMISSIONS_LEDGER'] = saved;
    rmSync(dir, { recursive: true, force: true });
  });

  const ledger = (...rows: object[]) =>
    writeFileSync(process.env['HIMMEL_ADMISSIONS_LEDGER']!, rows.map((r) => JSON.stringify(r) + '\n').join(''));

  it('stamps a frozen version on a ticket with no ledger row: a Done-fold, not a leak', async () => {
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
    expect(process.exitCode).toBeUndefined();
  });

  it('a deferred ticket closes unstamped, fails loudly on stderr and exits 3', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'deferral', actor: 'a' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(true);
    expect(vi.mocked(console.error).mock.calls.flat().join('\n')).toMatch(/^FAIL HIMMEL-1 closed with no fixVersion: .*deferral/m);
    expect(process.exitCode).toBe(3);
  });

  it('stamps a frozen version on a ticket with an admission row', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
  });

  it('stamps a frozen version on a ticket in its frozen set', async () => {
    wire([], FROZEN);
    await run('HIMMEL-2', 'Done');
    expect(puts()).toHaveLength(1);
  });

  it('a removal row after an admission withdraws the ruling, and a later admission restores it', async () => {
    ledger(
      { ts: 't1', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' },
      { ts: 't2', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-remove', actor: 'a' },
    );
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    ledger(
      { ts: 't1', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' },
      { ts: 't2', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-remove', actor: 'a' },
      { ts: 't3', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' },
    );
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
  });

  it('a deferral row after an admission withdraws the ruling', async () => {
    ledger(
      { ts: 't1', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' },
      { ts: 't2', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'deferral', actor: 'a' },
    );
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
  });

  it('a deferral row is not a ruling in', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'deferral', actor: 'a' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
  });
});
