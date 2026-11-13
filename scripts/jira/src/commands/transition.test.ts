import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Command } from 'commander';

vi.mock('../client.js', async () => {
  const actual = await vi.importActual<typeof import('../client.js')>('../client.js');
  return { request: vi.fn(), projectKey: () => 'HIMMEL', baseUrl: actual.baseUrl };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));
const ghPrs: Array<{ number: number; url: string; title: string }> = [];
vi.mock('node:child_process', async (orig) => {
  const actual = await orig<typeof import('node:child_process')>();
  const execFileSync = ((cmd: string, args?: readonly string[], opts?: object) =>
    cmd === 'gh' ? JSON.stringify(ghPrs) : actual.execFileSync(cmd, args ?? [], opts ?? {})) as typeof actual.execFileSync;
  return { ...actual, execFileSync };
});

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
  let status = 'To Do';
  mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
    if (method === 'PUT') {
      const ops = (body as { update: { fixVersions: Array<{ add?: { name: string } }> } }).update.fixVersions;
      current = ops.flatMap((o) => (o.add ? [o.add] : []));
    }
    if (method === 'POST' && path.endsWith('/transitions')) {
      status = LIVE.find((t) => t.id === (body as { transition: { id: string } }).transition.id)!.name;
    }
    if (method === 'GET' && path.endsWith('/transitions')) return { transitions: LIVE };
    if (method === 'GET' && path.endsWith('/versions')) return versions;
    if (method === 'GET' && path.includes('/issue/')) return { fields: { fixVersions: current, status: { name: status } } };
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

describe('transition to Done stamps the current fixVersion', () => {
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

  it('prints a browse: line with the site URL after the status line', async () => {
    vi.stubEnv('JIRA_BASE_URL', 'https://station.atlassian.net');
    wire([{ name: 'v1.1.2' }]);
    await run('HIMMEL-1', 'Done');
    expect(console.log).toHaveBeenCalledWith('browse: https://station.atlassian.net/browse/HIMMEL-1');
    vi.unstubAllEnvs();
  });

  it('stamp names transition-stamp', async () => {
    wire([]);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
    expect(puts()[0][3]).toBe('transition-stamp');
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

  it('a transition with no to status is still read back, and one that did not move fails', async () => {
    wire([]);
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) =>
      method === 'POST' && path.endsWith('/transitions') ? {} : base(method, path, body));
    await expect(run('HIMMEL-1', 'In Progress')).rejects.toThrow(/status was not changed.*'In Progress'.*'To Do'/s);
  });
});

describe('transition to Done respects the intake gate of a frozen version', () => {
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

  it('a ticket with no ledger row and no merged PR is no longer stamped into the frozen version', async () => {
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(process.exitCode).toBe(3);
  });

  it('a deferred ticket closes unstamped, fails loudly on stderr and exits 3', async () => {
    const key = 'HIMMEL-1';
    ledger({ ts: 't', version: 'v1.1.3', key, kind: 'deferral', actor: 'a' });
    wire([], FROZEN);
    await run(key, 'Done');
    expect(puts()).toHaveLength(0);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(true);
    expect(vi.mocked(console.error).mock.calls.flat().join('\n')).toMatch(new RegExp(`^FAIL ${key} closed with no fixVersion: .*deferral`, 'm'));
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

describe('a versionless Done close into a frozen release goes through the release manager', () => {
  const FROZEN = [
    { id: '1', name: 'v1.1.2', released: true },
    { id: '2', name: 'v1.1.3', released: false, description: 'frozen: 2026-10-20\nfrozen-keys: HIMMEL-2' },
  ];
  let dir: string;
  let errs: string[];
  beforeEach(async () => {
    vi.clearAllMocks();
    errs = [];
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation((s: unknown) => { errs.push(String(s)); });
    dir = mkdtempSync(join(tmpdir(), 'transition-frozen-'));
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(dir, 'admissions-ledger.jsonl'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(dir, 'state'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(dir, 'keys'));
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    writeFileSync(join(dir, 'verbatim.txt'), 'R1 = v1.1.3\n');
    const { registerRelease } = await import('./release.js');
    const p = new Command();
    p.exitOverride();
    registerRelease(p);
    await p.parseAsync(['node', 'jira', 'release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(dir, 'verbatim.txt')]);
    ghPrs.length = 0;
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    process.exitCode = undefined;
    rmSync(dir, { recursive: true, force: true });
  });
  const intakeRows = () => {
    const found: string[] = [];
    const walk = (d: string) => {
      for (const e of readdirSync(d, { withFileTypes: true })) {
        if (e.isDirectory()) walk(join(d, e.name));
        else found.push(...readFileSync(join(d, e.name), 'utf8').split('\n').filter((l) => l.includes('"INTAKE"') && l.includes('"HIMMEL-1"')));
      }
    };
    walk(join(dir, 'state'));
    return found;
  };

  it('RED: with a merged PR it stamps the version, files the INTAKE with the PR as evidence and prints the request id', async () => {
    ghPrs.push({ number: 4242, url: 'https://github.com/o/r/pull/4242', title: 'fix(jira): [HIMMEL-1] the close' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(1);
    expect(intakeRows()).toHaveLength(1);
    expect(intakeRows()[0]).toContain('pull/4242');
    expect(errs.join('\n')).toMatch(/INTAKE queued for HIMMEL-1 as REQ Q-R1-\d+/);
  });

  it('RED: a merged PR whose title only shares the key\'s words is not the key\'s PR', async () => {
    ghPrs.push({ number: 77, url: 'https://github.com/o/r/pull/77', title: 'fix: [HIMMEL-12] retry 1 time' });
    ghPrs.push({ number: 78, url: 'https://github.com/o/r/pull/78', title: 'fix: [HIMMEL-10] other' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(intakeRows()).toHaveLength(0);
    expect(process.exitCode).toBe(3);
  });

  it('RED: an INTAKE that cannot be filed closes unstamped with the request line and exits 3', async () => {
    ghPrs.push({ number: 4242, url: 'https://github.com/o/r/pull/4242', title: 'fix(jira): [HIMMEL-1] the close' });
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '1');
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(intakeRows()).toHaveLength(0);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST' && String(c[1]).endsWith('/transitions'))).toBe(true);
    expect(errs.join('\n')).toMatch(/could not be filed .*jira release request R1 --verb INTAKE --key HIMMEL-1 --to v1\.1\.3/);
    expect(process.exitCode).toBe(3);
  });

  it('RED: a reopened ticket the mirror still holds as Done outside the release files its INTAKE with its merged PR', async () => {
    const mirror = join(dir, 'home', '.himmel', 'state', 'jira-mirror', 'HIMMEL');
    mkdirSync(mirror, { recursive: true });
    writeFileSync(join(mirror, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T00:00:00Z' }));
    writeFileSync(join(mirror, 'HIMMEL-1.md'), '---\nkey: "HIMMEL-1"\nstatus: "Done"\nresolution: "Done"\ntype: "Task"\npriority: "Medium"\nfixVersions: ["v1.1.2"]\n---\n');
    vi.stubEnv('HOME', join(dir, 'home'));
    vi.stubEnv('JIRA_PROJECT_KEY', 'HIMMEL');
    ghPrs.push({ number: 4242, url: 'https://github.com/o/r/pull/4242', title: 'fix(jira): [HIMMEL-1] the close' });
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(intakeRows()).toHaveLength(1);
    expect(puts()).toHaveLength(1);
  });

  it('RED: with no merged PR it writes no version, closes, and prints the release request line', async () => {
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(intakeRows()).toHaveLength(0);
    expect(errs.join('\n')).toMatch(/jira release request R1 --verb INTAKE --key HIMMEL-1 --to v1\.1\.3 --why/);
    expect(process.exitCode).toBe(3);
  });

  it('control: a key in the frozen set is stamped with no request', async () => {
    wire([], FROZEN);
    await run('HIMMEL-2', 'Done');
    expect(puts()).toHaveLength(1);
    expect(intakeRows()).toHaveLength(0);
  });

  it('control: --no-version writes nothing and asks nothing', async () => {
    wire([], FROZEN);
    await run('HIMMEL-1', 'Done', '--no-version');
    expect(puts()).toHaveLength(0);
    expect(intakeRows()).toHaveLength(0);
  });
});

describe('a Done close folds a ticket held in a later unreleased version into the current one', () => {
  const OPEN = [
    { id: '1', name: 'v1.1.2', released: true, releaseDate: '2026-10-11' },
    { id: '2', name: 'v1.0.0', released: false, archived: true },
    { id: '3', name: 'v1.1.4', released: false, releaseDate: '2026-12-01' },
    { id: '4', name: 'v1.1.3', released: false, releaseDate: '2026-11-20' },
  ];
  const FROZEN = OPEN.map((v) => (v.name === 'v1.1.3' ? { ...v, description: 'frozen: 2026-11-01\nfrozen-keys: HIMMEL-2' } : v));
  let dir: string;
  let held: string[];
  let out: string[];
  let errs: string[];

  beforeEach(async () => {
    vi.clearAllMocks();
    out = [];
    errs = [];
    vi.spyOn(console, 'log').mockImplementation((s: unknown) => { out.push(String(s)); });
    vi.spyOn(console, 'error').mockImplementation((s: unknown) => { errs.push(String(s)); });
    dir = mkdtempSync(join(tmpdir(), 'transition-fold-'));
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(dir, 'admissions-ledger.jsonl'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(dir, 'state'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(dir, 'keys'));
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    writeFileSync(join(dir, 'verbatim.txt'), 'R1 = v1.1.3\n');
    const { registerRelease } = await import('./release.js');
    const p = new Command();
    p.exitOverride();
    registerRelease(p);
    await p.parseAsync(['node', 'jira', 'release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(dir, 'verbatim.txt')]);
    ghPrs.length = 0;
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    process.exitCode = undefined;
    rmSync(dir, { recursive: true, force: true });
  });

  function wireFold(start: string[], versions: unknown[] = OPEN) {
    held = start;
    let status = 'To Do';
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'PUT') {
        for (const o of (body as { update: { fixVersions: Array<{ add?: { name: string }; remove?: { name: string } }> } }).update.fixVersions) {
          if (o.add && !held.includes(o.add.name)) held = [...held, o.add.name];
          if (o.remove) held = held.filter((n) => n !== o.remove!.name);
        }
      }
      if (method === 'POST' && path.endsWith('/transitions')) {
        status = LIVE.find((t) => t.id === (body as { transition: { id: string } }).transition.id)!.name;
      }
      if (method === 'GET' && path.endsWith('/transitions')) return { transitions: LIVE };
      if (method === 'GET' && path.endsWith('/versions')) return versions;
      if (method === 'GET' && path.includes('/issue/')) return { fields: { fixVersions: held.map((name) => ({ name })), status: { name: status } } };
      return {};
    });
  }
  const ledger = (...rows: object[]) =>
    writeFileSync(process.env['HIMMEL_ADMISSIONS_LEDGER']!, rows.map((r) => JSON.stringify(r) + '\n').join(''));
  const intakeRows = () => {
    const found: string[] = [];
    const walk = (d: string) => {
      for (const e of readdirSync(d, { withFileTypes: true })) {
        if (e.isDirectory()) walk(join(d, e.name));
        else found.push(...readFileSync(join(d, e.name), 'utf8').split('\n').filter((l) => l.includes('"INTAKE"') && l.includes('"HIMMEL-1"')));
      }
    };
    if (existsSync(join(dir, 'state'))) walk(join(dir, 'state'));
    return found;
  };

  it('RED: a ticket held in a later unreleased version ends holding the current version only, and says so on one line', async () => {
    wireFold(['v1.1.4'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect(held).toEqual(['v1.1.3']);
    expect(puts().map((c) => c[3])).toEqual(['transition-stamp', 'transition-stamp']);
    expect(out.filter((l) => /^HIMMEL-1 fixVersion \+v1\.1\.3 -v1\.1\.4 /.test(l))).toHaveLength(1);
    expect(process.exitCode ?? 0).toBe(0);
  });

  it('RED: the current version is the earliest unreleased by release date, not by list order', async () => {
    wireFold(['v1.1.4'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect(held).not.toContain('v1.1.4');
    expect(held).toContain('v1.1.3');
  });

  it('RED: a held released version and a held archived version are kept', async () => {
    wireFold(['v1.1.2', 'v1.0.0', 'v1.1.4'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect([...held].sort()).toEqual(['v1.0.0', 'v1.1.2', 'v1.1.3']);
  });

  it('control: a ticket already holding the current version is not touched', async () => {
    wireFold(['v1.1.3'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
  });

  it('control: a ticket holding only released or archived versions is not touched', async () => {
    wireFold(['v1.1.2', 'v1.0.0'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
  });

  it('RED: a ticket holding both the current and a later version drops the later one', async () => {
    wireFold(['v1.1.3', 'v1.1.4'], OPEN);
    await run('HIMMEL-1', 'Done');
    expect(held).toEqual(['v1.1.3']);
  });

  it('control: --no-version folds nothing', async () => {
    wireFold(['v1.1.4'], OPEN);
    await run('HIMMEL-1', 'Done', '--no-version');
    expect(puts()).toHaveLength(0);
    expect(held).toEqual(['v1.1.4']);
  });

  it('control: a non-Done close folds nothing', async () => {
    wireFold(['v1.1.4'], OPEN);
    await run('HIMMEL-1', 'In Progress');
    await run('HIMMEL-1', 'Closed');
    await run('HIMMEL-1', 'wont do');
    expect(puts()).toHaveLength(0);
  });

  it('RED: a frozen current version the ticket is deferred out of is not written, and the skip is one printed line', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'deferral', actor: 'a' });
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(held).toEqual(['v1.1.4']);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST' && String(c[1]).endsWith('/transitions'))).toBe(true);
    expect(out.filter((l) => /^HIMMEL-1 keeps v1\.1\.4: .*deferral/.test(l))).toHaveLength(1);
    expect(process.exitCode ?? 0).toBe(0);
  });

  it('RED: a rm-remove row is skipped the same way', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-remove', actor: 'a' });
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(out.filter((l) => /^HIMMEL-1 keeps v1\.1\.4: .*rm-remove/.test(l))).toHaveLength(1);
  });

  it('RED: a frozen current version the ticket is not admitted to files the INTAKE with the merged PR, then folds', async () => {
    ghPrs.push({ number: 4242, url: 'https://github.com/o/r/pull/4242', title: 'fix(jira): [HIMMEL-1] the close' });
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(intakeRows()).toHaveLength(1);
    expect(intakeRows()[0]).toContain('pull/4242');
    expect(held).toEqual(['v1.1.3']);
  });

  it('RED: a frozen current version with no merged PR to file the INTAKE leaves the held version and prints the request line', async () => {
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(intakeRows()).toHaveLength(0);
    expect(out.filter((l) => /^HIMMEL-1 keeps v1\.1\.4: .*jira release request R1 --verb INTAKE --key HIMMEL-1 --to v1\.1\.3/.test(l))).toHaveLength(1);
  });

  it('control: a key in the frozen set folds with no request', async () => {
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-2', 'Done');
    expect(held).toEqual(['v1.1.3']);
    expect(intakeRows()).toHaveLength(0);
  });

  it('control: a frozen current version with an admission row folds', async () => {
    ledger({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'rm-admit', actor: 'a' });
    wireFold(['v1.1.4'], FROZEN);
    await run('HIMMEL-1', 'Done');
    expect(held).toEqual(['v1.1.3']);
  });

  it('an unreadable version list does not stop the close of an already-versioned ticket', async () => {
    wireFold(['v1.1.4'], OPEN);
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'GET' && path.endsWith('/versions')) throw new Error('HTTP 503');
      return base(method, path, body);
    });
    await run('HIMMEL-1', 'Done');
    expect(puts()).toHaveLength(0);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST' && String(c[1]).endsWith('/transitions'))).toBe(true);
    expect(errs.join('\n')).toMatch(/^WARN HIMMEL-1 keeps v1\.1\.4: the version list could not be read \(HTTP 503\)/m);
  });

  it('a failed add leaves the later version in place and the close still lands', async () => {
    wireFold(['v1.1.4'], OPEN);
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'PUT') throw new Error('edit rejected');
      return base(method, path, body);
    });
    await run('HIMMEL-1', 'Done');
    expect(held).toEqual(['v1.1.4']);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST' && String(c[1]).endsWith('/transitions'))).toBe(true);
    expect(errs.join('\n')).toMatch(/^WARN HIMMEL-1 .*v1\.1\.4.*edit rejected/m);
  });
});

describe('a Done-category close removes the phase label', () => {
  const CATEGORY: Record<string, string> = { 'To Do': 'new', 'In Progress': 'indeterminate', Done: 'done', Closed: 'done', 'wont do': 'done' };
  let labels: string[];
  let status: string;
  let failLabelPut: boolean;
  let errs: string[];
  let dir: string;
  const labelPuts = () => mockRequest.mock.calls.filter((c) => c[0] === 'PUT' && (c[2] as { update?: { labels?: unknown } })?.update?.labels);

  beforeEach(() => {
    vi.clearAllMocks();
    errs = [];
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation((s: unknown) => { errs.push(String(s)); });
    dir = mkdtempSync(join(tmpdir(), 'transition-phase-'));
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(dir, 'admissions-ledger.jsonl'));
    labels = ['standalone', 'phase:sliced'];
    status = 'In Progress';
    failLabelPut = false;
    mockRequest.mockImplementation(async (method: string, path: string, body?: { update?: { labels?: Array<{ remove?: string }> } }) => {
      if (method === 'GET' && path.endsWith('/transitions')) return { transitions: LIVE };
      if (method === 'GET' && path.endsWith('/versions')) return VERSIONS;
      if (method === 'POST' && path.endsWith('/transitions')) {
        status = LIVE.find((t) => t.id === (body as unknown as { transition: { id: string } }).transition.id)!.name;
        return {};
      }
      if (method === 'PUT' && body?.update?.labels) {
        if (failLabelPut) throw new Error('HTTP 400 labels');
        for (const op of body.update.labels) labels = labels.filter((l) => l !== op.remove);
        return {};
      }
      if (method === 'GET' && path.includes('/issue/')) {
        return { fields: { fixVersions: [{ name: 'v1.1.3' }], labels: [...labels], status: { name: status, statusCategory: { key: CATEGORY[status] } } } };
      }
      return {};
    });
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    process.exitCode = undefined;
    rmSync(dir, { recursive: true, force: true });
  });

  it('a close to Done of a phase:sliced ticket sends the swap to none after the status read-back and exits 0', async () => {
    await run('HIMMEL-1', 'Done');
    expect(labelPuts()).toHaveLength(1);
    expect(labelPuts()[0][2]).toEqual({ update: { labels: [{ remove: 'phase:sliced' }] } });
    const post = mockRequest.mock.calls.findIndex((c) => c[0] === 'POST');
    const put = mockRequest.mock.calls.findIndex((c) => c[0] === 'PUT');
    expect(put).toBeGreaterThan(post);
    expect(labels).toEqual(['standalone']);
    expect(process.exitCode ?? 0).toBe(0);
  });

  it('a close to Closed (statusCategory done) clears the label too', async () => {
    await run('HIMMEL-1', 'Closed');
    expect(labelPuts()).toHaveLength(1);
    expect(labels).toEqual(['standalone']);
  });

  it('a move to In Progress (statusCategory indeterminate) sends no label update', async () => {
    status = 'To Do';
    await run('HIMMEL-1', 'In Progress');
    expect(labelPuts()).toHaveLength(0);
  });

  it('a failing label PUT keeps exit 0 and prints the WARN', async () => {
    failLabelPut = true;
    await run('HIMMEL-1', 'Done');
    expect(process.exitCode ?? 0).toBe(0);
    expect(errs.join('\n')).toMatch(/^WARN HIMMEL-1 closed with phase:sliced still on it \(/m);
  });

  it('an unstamped close with a failing clear still exits 3 and prints both the FAIL and the WARN line', async () => {
    writeFileSync(join(dir, 'admissions-ledger.jsonl'), JSON.stringify({ ts: 't', version: 'v1.1.3', key: 'HIMMEL-1', kind: 'deferral', actor: 'a' }) + '\n');
    const frozen = [
      { id: '1', name: 'v1.1.2', released: true },
      { id: '2', name: 'v1.1.3', released: false, description: 'frozen: 2026-10-20\nfrozen-keys: HIMMEL-2' },
    ];
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      if (method === 'GET' && path.endsWith('/versions')) return frozen;
      if (method === 'GET' && path.includes('fields=fixVersions')) return { fields: { fixVersions: [] } };
      return base(method, path, body);
    });
    failLabelPut = true;
    await run('HIMMEL-1', 'Done');
    expect(process.exitCode).toBe(3);
    expect(errs.join('\n')).toMatch(/^FAIL \S+ closed with no fixVersion/m);
    expect(errs.join('\n')).toMatch(/^WARN HIMMEL-1 closed with phase:sliced still on it/m);
  });

  it('jira move closes its source through transitionIssue, which prints the same WARN', async () => {
    const { transitionIssue } = await import('./transition.js');
    failLabelPut = true;
    const r = await transitionIssue('HIMMEL-1', 'Done', { version: false });
    expect(r.phaseLeft).toBe('phase:sliced');
    expect(errs.join('\n')).toMatch(/^WARN HIMMEL-1 closed with phase:sliced still on it/m);
  });
});
