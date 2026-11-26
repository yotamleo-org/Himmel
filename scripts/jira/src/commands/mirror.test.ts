import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { formatIssueLinks } from './link.js';
import { Command } from 'commander';
import { runMirror, renderIssue, qmdRefresh, mirrorAgeMinutes, scrubEmails, registerMirror } from './mirror.js';
import type { MirrorIssue, Req } from './mirror.js';
import { mirrorState } from '../mirror-cursor.js';

// Stubbed Jira API: paging, cursor, idempotence, edit, delete.

const issue = (n: number, over: Partial<MirrorIssue['fields']> = {}): MirrorIssue => ({
  key: `HIMMEL-${n}`,
  fields: {
    summary: `summary ${n}`,
    status: { name: 'To Do', statusCategory: { name: 'To Do' } },
    issuetype: { name: 'Task' },
    priority: { name: 'Medium' },
    labels: ['a'],
    fixVersions: [{ name: 'v1.0.0' }],
    created: '2026-09-01T00:00:00.000+0000',
    updated: '2026-09-02T00:00:00.000+0000',
    comment: { comments: [], total: 0 },
    ...over,
  },
});

const k = (n: number): string => `HIMMEL-${n}`;

interface Stub {
  issues: MirrorIssue[]; pageSize: number; failKeyList?: boolean; count?: number; windowed?: MirrorIssue[]; calls: string[];
  moved?: Record<string, MirrorIssue>; get404?: string[]; failCount?: boolean;
}

// Fake /search/jql (token paging), /search/approximate-count and comments.
function makeReq(stub: Stub): Req {
  return (async (method: string, path: string) => {
    stub.calls.push(`${method} ${path}`);
    if (path.startsWith('/search/approximate-count')) {
      if (stub.failCount) throw new Error('HTTP 500');
      return { count: stub.count ?? stub.issues.length };
    }
    if (path.startsWith('/search/jql')) {
      const keysOnly = path.includes('fields=key&');
      if (keysOnly && stub.failKeyList) throw new Error('HTTP 500');
      const start = Number(/nextPageToken=(\d+)/.exec(path)?.[1] ?? 0);
      const pool = stub.windowed && decodeURIComponent(path).includes('updated >=') ? stub.windowed : stub.issues;
      const slice = pool.slice(start, start + stub.pageSize);
      const next = start + stub.pageSize < pool.length ? String(start + stub.pageSize) : undefined;
      return { issues: slice, nextPageToken: next };
    }
    const got = /^\/issue\/([A-Z][A-Z0-9_]*-\d+)\?fields=/.exec(path);
    if (method === 'GET' && got) {
      const key = got[1];
      if (stub.moved?.[key]) return stub.moved[key];
      const found = stub.get404?.includes(key) ? undefined : stub.issues.find((i) => i.key === key);
      if (!found) throw new Error('HTTP 404');
      return found;
    }
    throw new Error(`unexpected ${method} ${path}`);
  }) as unknown as Req;
}

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'jira-mirror-')); });
afterEach(() => { rmSync(root, { recursive: true, force: true }); });
const mdFiles = () => readdirSync(root).filter((n) => n.endsWith('.md')).sort();

describe('runMirror', () => {
  it('full backfill pages through every issue and matches the Jira total', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4, 5].map((n) => issue(n)), pageSize: 2, calls: [] };
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ mode: 'full', fetched: 5, written: 5, mirrorCount: 5, jiraTotal: 5 });
    expect(mdFiles()).toHaveLength(5);
  });

  it('keeps paging past an empty page that still carries a nextPageToken', async () => {
    const stub: Stub = { issues: [issue(1), issue(2), issue(3)], pageSize: 2, calls: [] };
    const inner = makeReq(stub);
    let first = true;
    const req = (async (m: string, p: string, b?: unknown) => {
      if (first && p.startsWith('/search/jql') && !p.includes('nextPageToken')) {
        first = false;
        return { issues: [], nextPageToken: '0' };
      }
      return (inner as unknown as (m: string, p: string, b?: unknown) => Promise<unknown>)(m, p, b);
    }) as unknown as Req;
    const r = await runMirror({ root, project: 'HIMMEL' }, req);
    expect(r.fetched).toBe(3);
  });

  it('is idempotent: a second run with no changes writes nothing', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ mode: 'incremental', written: 0, unchanged: 2, deleted: 0 });
  });

  it('uses a relative-minute updated>= JQL on incremental runs', async () => {
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    const t0 = new Date('2026-09-30T10:00:00Z');
    await runMirror({ root, project: 'HIMMEL', now: () => t0 }, makeReq(stub));
    stub.calls.length = 0;
    await runMirror({ root, project: 'HIMMEL', now: () => new Date('2026-09-30T10:30:00Z') }, makeReq(stub));
    const jql = decodeURIComponent(stub.calls.find((c) => c.includes('updated'))!);
    expect(jql).toContain('updated >= "-40m"');
  });

  it('an edited issue changes on the next incremental run', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues[1] = issue(2, { summary: 'edited title', status: { name: 'Done', statusCategory: { name: 'Done' } } });
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ written: 1, unchanged: 1 });
    const md = readFileSync(join(root, 'HIMMEL-2.md'), 'utf8');
    expect(md).toContain('edited title');
    expect(md).toContain('status: "Done"');
  });

  it('removes the file of a deleted/moved issue', async () => {
    const stub: Stub = { issues: [issue(1), issue(2), issue(3)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1), issue(3)];
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.deleted).toBe(1);
    expect(mdFiles()).toEqual(['HIMMEL-1.md', 'HIMMEL-3.md']);
  });

  it('fails safe: a failing key listing deletes nothing and warns', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1)];
    stub.failKeyList = true;
    const warn = vi.fn();
    const r = await runMirror({ root, project: 'HIMMEL', warn }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('key listing failed');
    expect(warn).toHaveBeenCalled();
    expect(mdFiles()).toHaveLength(2);
  });

  it('fails safe: a key listing under 50% of local files deletes nothing', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1)];
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('%');
    expect(mdFiles()).toHaveLength(4);
  });

  it('fails safe: a listing well short of the Jira count deletes nothing', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1), issue(2), issue(3)];
    stub.count = 4;
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('Jira counts 4');
    expect(mdFiles()).toHaveLength(4);
  });

  it('a truncated backfill writes repair full, so the next run is a full backfill', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [], count: 10 };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8'))).toMatchObject({ complete: false, repair: 'full' });
    stub.count = undefined;
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('full');
  });

  it('an incremental run that finds a live key missing locally gets it back through the fill', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    rmSync(join(root, 'HIMMEL-2.md'));
    stub.windowed = [];
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.mode).toBe('incremental');
    expect(r.deleteSkipped).toBeNull();
    expect(existsSync(join(root, `${k(2)}.md`))).toBe(true);
  });

  it('an incremental run whose missing live key cannot be fetched drops the cursor', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [], get404: [k(2)] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    rmSync(join(root, `${k(2)}.md`));
    stub.windowed = [];
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.mode).toBe('incremental');
    expect(r.deleteSkipped).toBe('live keys missing locally');
    expect(JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8')).complete).toBe(false);
  });

  it('an incomplete sync keeps a cursor marked complete:false with repair full and the next run is full', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [], count: 10 };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    const cur = JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8')) as { complete?: boolean };
    expect(cur.complete).toBe(false);
    stub.count = undefined;
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('full');
    expect(JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8')).complete).toBeUndefined();
  });

  it('a short run marks the cursor incomplete and the next run repairs incrementally', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.count = 10;
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8'))).toMatchObject({ complete: false, repair: 'incremental' });
    stub.count = undefined;
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('incremental');
  });

  it('a cursor from another project neither drives the window nor lets deletes reach its files', async () => {
    const other: Stub = { issues: [{ ...issue(1), key: 'OTHER-1' }], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'OTHER' }, makeReq(other));
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('full');
    expect(r.deleted).toBe(0);
    expect(existsSync(join(root, 'OTHER-1.md'))).toBe(true);
  });

  it('does not refetch comments the search page already embedded in full', async () => {
    const c = (id: string) => ({ id, author: { displayName: 'Ann' }, created: `2026-09-0${id}T00:00:00Z`, body: null });
    const stub: Stub = {
      issues: [issue(1, { comment: { comments: [c('1')], total: 1 } })],
      pageSize: 10,
      calls: [],
    };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(stub.calls.some((x) => x.includes('/comment'))).toBe(false);
  });
});

describe('runMirror fill pass (RM1)', () => {
  const cursor = () => JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8')) as Record<string, unknown>;
  const issuesTo = (n: number) => Array.from({ length: n }, (_, i) => issue(i + 1));
  const gets = (stub: Stub) => stub.calls.filter((c) => c.startsWith('GET /issue/'));
  async function seeded(listed: number, over: Partial<Stub> = {}) {
    const stub: Stub = { issues: issuesTo(3), pageSize: 100, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = issuesTo(listed);
    stub.windowed = [];
    Object.assign(stub, over);
    stub.calls.length = 0;
    const warn = vi.fn();
    const r = await runMirror({ root, project: 'HIMMEL', warn }, makeReq(stub));
    return { stub, warn, r };
  }

  it('RM1: a key filed mid-run is filled and the cursor stays complete', async () => {
    const { warn, r } = await seeded(4);
    expect(existsSync(join(root, `${k(4)}.md`))).toBe(true);
    expect(cursor()).not.toHaveProperty('complete');
    expect(cursor().total).toBe(4);
    expect(r).toMatchObject({ mode: 'incremental', fetched: 1, written: 1, mirrorCount: 4, deleteSkipped: null });
    expect(warn).toHaveBeenCalledWith(`filled 1 live key(s) missing locally: ${k(4)}`);
  });

  it('RM1b (control): a listed key whose GET is 404 leaves the cursor incomplete', async () => {
    const { r } = await seeded(4, { get404: [k(4)] });
    expect(existsSync(join(root, `${k(4)}.md`))).toBe(false);
    expect(r.deleteSkipped).toBe('live keys missing locally');
    expect(cursor().complete).toBe(false);
  });

  it('RM1c (control): 51 missing live keys are not filled', async () => {
    const { stub } = await seeded(54);
    expect(gets(stub)).toHaveLength(0);
    expect(cursor().complete).toBe(false);
  });

  it('RM1d: a moved key is never written under its old name', async () => {
    const { warn } = await seeded(4, { moved: { [k(4)]: { ...issue(9), key: 'OTHER-9' } } });
    expect(existsSync(join(root, 'OTHER-9.md'))).toBe(false);
    expect(existsSync(join(root, `${k(4)}.md`))).toBe(false);
    expect(warn).toHaveBeenCalledWith(`fill: ${k(4)} answered as OTHER-9; left missing`);
    expect(cursor().complete).toBe(false);
  });

  it('RM1e: exactly 50 missing live keys are filled and the cursor stays complete', async () => {
    const { stub } = await seeded(53);
    expect(gets(stub)).toHaveLength(50);
    expect(cursor()).not.toHaveProperty('complete');
    expect(cursor().total).toBe(53);
  });

  it('RM1f: 3 missing keys are filled whatever the count gap', async () => {
    const { stub } = await seeded(6, { count: 60 });
    expect(gets(stub)).toHaveLength(3);
    expect([`${k(4)}.md`, `${k(5)}.md`, `${k(6)}.md`].every((n) => existsSync(join(root, n)))).toBe(true);
  });
});

describe('runMirror repair kind and mode (RM2, RM4)', () => {
  const curPath = () => join(root, '.cursor.json');
  const cursor = () => JSON.parse(readFileSync(curPath(), 'utf8')) as Record<string, unknown>;
  const issuesTo = (n: number) => Array.from({ length: n }, (_, i) => issue(i + 1));
  const jqls = (stub: Stub) => stub.calls.filter((c) => c.startsWith('GET /search/jql')).map((c) => decodeURIComponent(c));
  async function mirrored(n: number): Promise<Stub> {
    const stub: Stub = { issues: issuesTo(n), pageSize: 100, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    return stub;
  }
  const plant = (c: Record<string, unknown>) => writeFileSync(curPath(), JSON.stringify({ lastSync: '2026-11-26T16:33:57.000Z', total: 3, project: 'HIMMEL', ...c }));

  it('RM2: a legacy complete:false cursor drives an incremental run that ends complete', async () => {
    const stub = await mirrored(3);
    plant({ complete: false });
    stub.calls.length = 0;
    const r = await runMirror({ root, project: 'HIMMEL', now: () => new Date('2026-11-26T17:00:00.000Z') }, makeReq(stub));
    expect(r.mode).toBe('incremental');
    expect(jqls(stub)[0]).toContain('updated >=');
    expect(cursor()).not.toHaveProperty('complete');
    expect(cursor()).not.toHaveProperty('repair');
  });

  it('RM2b (control): another project, and opts.full, run full', async () => {
    const stub = await mirrored(3);
    plant({ complete: false, project: 'OTHER' });
    expect((await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub))).mode).toBe('full');
    plant({ complete: false });
    expect((await runMirror({ root, project: 'HIMMEL', full: true, warn: vi.fn() }, makeReq(stub))).mode).toBe('full');
  });

  it('RM2c (control): repair full runs full', async () => {
    const stub = await mirrored(3);
    plant({ complete: false, repair: 'full' });
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('full');
  });

  it('RM4: the repair kind follows the residual gap', async () => {
    const a = await mirrored(3);
    a.issues = issuesTo(54);
    a.windowed = [];
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(a));
    expect(cursor()).toMatchObject({ complete: false, repair: 'full' });
    rmSync(root, { recursive: true, force: true });
    const b = await mirrored(3);
    b.issues = issuesTo(4);
    b.windowed = [];
    b.get404 = [k(4)];
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(b));
    expect(cursor()).toMatchObject({ complete: false, repair: 'incremental' });
    rmSync(root, { recursive: true, force: true });
    const c = await mirrored(3);
    c.failKeyList = true;
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(c));
    expect(cursor()).toMatchObject({ complete: false, repair: 'incremental' });
  });

  it('RM4: a full run short of Jira count writes full; with the count unavailable it writes incremental', async () => {
    rmSync(root, { recursive: true, force: true });
    const a: Stub = { issues: issuesTo(3), pageSize: 100, calls: [], count: 10 };
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(a));
    expect(cursor()).toMatchObject({ complete: false, repair: 'full' });
    const big: Stub = { issues: issuesTo(3), pageSize: 100, calls: [], count: 60 };
    await runMirror({ root, project: 'HIMMEL', full: true, warn: vi.fn() }, makeReq(big));
    expect(cursor()).toMatchObject({ repair: 'full' });
    const none: Stub = { issues: issuesTo(3), pageSize: 100, calls: [], failCount: true };
    await runMirror({ root, project: 'HIMMEL', full: true, warn: vi.fn() }, makeReq(none));
    expect(cursor()).toMatchObject({ complete: false, repair: 'incremental' });
  });

  it('RM4: a listing of 100, a count of 160 and one 404 writes incremental', async () => {
    const stub = await mirrored(100);
    rmSync(join(root, `${k(50)}.md`));
    stub.windowed = [];
    stub.count = 160;
    stub.get404 = [k(50)];
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(cursor()).toMatchObject({ complete: false, repair: 'incremental' });
  });

  it('RM4: a listing that fails with a gap over the tolerance writes full', async () => {
    const stub = await mirrored(3);
    stub.failKeyList = true;
    stub.count = 200;
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(cursor()).toMatchObject({ complete: false, repair: 'full' });
  });

  it('a missing key that cannot be fetched leaves an incremental repair (the row at base :153)', async () => {
    const stub: Stub = { issues: issuesTo(3), pageSize: 10, calls: [], get404: [k(2)] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    rmSync(join(root, `${k(2)}.md`));
    stub.windowed = [];
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    stub.windowed = undefined;
    stub.get404 = undefined;
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('incremental');
  });
});

describe('mirror CLI verbs (RM3, RM5)', () => {
  const prevProject = process.env.JIRA_PROJECT_KEY;
  beforeEach(() => { process.env.JIRA_PROJECT_KEY = 'HIMMEL'; });
  afterEach(() => {
    process.exitCode = undefined;
    vi.restoreAllMocks();
    if (prevProject === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = prevProject;
  });
  const base = { lastSync: '2026-11-26T16:33:57.000Z', total: 3, project: 'HIMMEL' };
  const plant = (c: Record<string, unknown>) => writeFileSync(join(root, '.cursor.json'), JSON.stringify(c));
  async function run(stub: Stub, ...args: string[]): Promise<string> {
    const out: string[] = [];
    vi.spyOn(console, 'log').mockImplementation((...a: unknown[]) => { out.push(a.join(' ')); });
    const program = new Command();
    registerMirror(program, makeReq(stub));
    await program.parseAsync(['node', 'jira', 'mirror', '--root', root, ...args]);
    return out.join('\n');
  }
  const status = async (project?: string) => {
    if (project) process.env.JIRA_PROJECT_KEY = project;
    return JSON.parse(await run({ issues: [], pageSize: 10, calls: [] }, '--status', '--json')) as Record<string, unknown>;
  };

  it('RM3: --status --json prints the cursor state with root, files and age', async () => {
    writeFileSync(join(root, `${k(1)}.md`), 'x');
    plant(base);
    expect(await status()).toMatchObject({ root, files: 1, complete: 'yes', repair: null, next: 'incremental', lastSync: base.lastSync, project: 'HIMMEL', repairable: false });
    plant({ ...base, complete: false });
    expect(await status()).toMatchObject({ complete: 'no', repair: 'incremental', next: 'incremental', repairable: true });
    plant({ ...base, complete: false, repair: 'full' });
    expect(await status()).toMatchObject({ complete: 'no', repair: 'full', next: 'full', repairable: false });
    rmSync(join(root, '.cursor.json'));
    expect(await status()).toMatchObject({ complete: 'none', next: 'full', age_minutes: null });
  });

  it('RM3: --status --json for another project reads next full; plain --status keeps its line', async () => {
    plant({ ...base, complete: false });
    expect(await status('OTHER')).toMatchObject({ complete: 'no', next: 'full' });
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    expect(await run({ issues: [], pageSize: 10, calls: [] }, '--status')).toMatch(/^mirror root=.* files=0 age_minutes=\d+$/);
  });

  it('RM5: --repair on a complete cursor says not needed, exit 0, no request', async () => {
    plant(base);
    const stub: Stub = { issues: [], pageSize: 10, calls: [] };
    expect(await run(stub, '--repair')).toBe('repair: not needed');
    expect(process.exitCode).toBeUndefined();
    expect(stub.calls).toHaveLength(0);
  });

  it.each([
    ['no cursor', null, `no cursor at ${'ROOT'}; a full backfill is needed`],
    ['another project', { ...base, project: 'OTHER' }, 'the cursor is for OTHER'],
    ['repair full', { ...base, complete: false, repair: 'full' }, 'a full backfill is needed'],
  ])('RM5: --repair on %s refuses with exit 3 and no request', async (_n, cur, reason) => {
    if (cur) plant(cur);
    const stub: Stub = { issues: [], pageSize: 10, calls: [] };
    expect(await run(stub, '--repair')).toBe(`repair: ${reason.replace('ROOT', root)}`);
    expect(process.exitCode).toBe(3);
    expect(stub.calls).toHaveLength(0);
  });

  it('RM5: --repair on a legacy incomplete cursor runs one incremental run', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    plant({ ...base, complete: false });
    stub.calls.length = 0;
    const out = await run(stub, '--repair');
    expect(out).toContain('mirror incremental:');
    expect(decodeURIComponent(stub.calls.find((c) => c.startsWith('GET /search/jql'))!)).toContain('updated >=');
    expect(process.exitCode).toBeUndefined();
    expect(JSON.parse(readFileSync(join(root, '.cursor.json'), 'utf8'))).not.toHaveProperty('complete');
  });

  it('--json without --status is refused with exit 2 and no request', async () => {
    const stub: Stub = { issues: [], pageSize: 10, calls: [] };
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    expect(await run(stub, '--json')).toBe('');
    expect(process.exitCode).toBe(2);
    expect(stub.calls).toHaveLength(0);
  });

  it('RM5: runMirror incrementalOnly on a repair-full cursor returns refused with no request', async () => {
    plant({ ...base, complete: false, repair: 'full' });
    const stub: Stub = { issues: [], pageSize: 10, calls: [] };
    const r = await runMirror({ root, project: 'HIMMEL', incrementalOnly: true }, makeReq(stub));
    expect(r.refused).toBe('a full backfill is needed');
    expect(stub.calls).toHaveLength(0);
  });
});

describe('renderIssue', () => {
  it('writes resolved: the resolutiondate, null when unresolved', () => {
    const done = renderIssue(issue(7, { resolutiondate: '2026-10-01T12:00:00.000+0000' }), []);
    expect(done).toContain('resolved: "2026-10-01T12:00:00.000+0000"');
    expect(renderIssue(issue(8), [])).toContain('resolved: null');
  });

  it('writes frontmatter, description and comments by display name only, no emails', () => {
    const md = renderIssue(
      issue(7, {
        description: { type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'mail bob@example.com about zebra widgets' }] }] } as never,
        parent: { key: 'HIMMEL-1' },
        issuelinks: [{ type: { outward: 'blocks', inward: 'is blocked by' }, outwardIssue: { key: 'HIMMEL-8' } }],
      }),
      [{ id: '1', author: { displayName: 'Ann Lee' }, created: '2026-09-03T00:00:00Z', body: null }],
    );
    expect(md).toContain('key: "HIMMEL-7"');
    expect(md).toContain('parent: "HIMMEL-1"');
    expect(md).toContain('  blocks: ["HIMMEL-8"]');
    expect(md).toContain('zebra widgets');
    expect(md).toContain('Ann Lee');
    expect(md).not.toContain('bob@example.com');
  });

  it('mirror and `jira links` agree on every Blocks link of a real Jira GET', () => {
    const real = JSON.parse(
      readFileSync(new URL('./fixtures/blocks-links-real-get.json', import.meta.url), 'utf8'),
    ) as Record<string, MirrorIssue>;
    const render = (key: string): string =>
      renderIssue({ ...real[key], fields: { summary: 's', ...real[key].fields } } as MirrorIssue, []);
    const fm = (md: string, field: string): string[] => {
      const m = new RegExp(`  ${field}: (.*)`).exec(md);
      return m ? (JSON.parse(m[1]) as string[]) : [];
    };
    for (const key of ['HIMMEL-6494', 'HIMMEL-5556', 'HIMMEL-6572']) {
      const md = render(key);
      const links = real[key].fields.issuelinks as unknown as Parameters<typeof formatIssueLinks>[1];
      const reads = formatIssueLinks(key, links).split('\n').map((l) => l.split('\t')[4]);
      expect(reads.filter((r) => r.startsWith(`${key} blocks `)).map((r) => r.split(' ')[2])).toEqual(fm(md, 'blocks'));
      expect(reads.filter((r) => r.startsWith(`${key} is blocked by `)).map((r) => r.split(' ')[4])).toEqual(fm(md, 'blocked_by'));
    }
    expect(fm(render('HIMMEL-6494'), 'blocked_by')).toEqual(['HIMMEL-5556']);
    expect(fm(render('HIMMEL-6494'), 'blocks')).toEqual(['HIMMEL-6572']);
  });

  it('scrubs address-shaped text out of frontmatter values too', () => {
    const md = renderIssue(issue(9, { labels: ['owner@corp.io'], fixVersions: [{ name: 'v1 x@y.org' }] }), []);
    expect(md).not.toMatch(/@corp\.io|@y\.org/);
    expect(md).toContain('[email]');
  });

  it('scrubEmails replaces address-shaped text', () => {
    expect(scrubEmails('a.b+c@x.co and d@y.org')).toBe('[email] and [email]');
  });
});

describe('cursor + qmd', () => {
  it('mirrorAgeMinutes is null before any sync and counts minutes after', async () => {
    expect(mirrorAgeMinutes(root)).toBeNull();
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL', now: () => new Date('2026-09-30T10:00:00Z') }, makeReq(stub));
    expect(mirrorAgeMinutes(root, new Date('2026-09-30T10:45:00Z'))).toBe(45);
  });

  it('a corrupt cursor falls back to a full run', async () => {
    writeFileSync(join(root, '.cursor.json'), '{nope');
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('full');
    expect(existsSync(join(root, '.cursor.json'))).toBe(true);
  });

  it('qmdRefresh registers a missing collection, then updates and embeds', () => {
    const run = vi.fn().mockReturnValueOnce('himmel (qmd://himmel/)').mockReturnValue('');
    expect(qmdRefresh(root, run)).toContain('updated and embedded');
    expect(run.mock.calls.map((c) => (c[0] as string[]).join(' '))).toEqual([
      'collection list',
      `collection add ${root} --name jira-himmel`,
      'update -c jira-himmel',
      'embed -c jira-himmel',
    ]);
  });

  it('qmdRefresh does not re-register an existing collection and never throws', () => {
    const run = vi.fn()
      .mockReturnValueOnce('jira-himmel (qmd://jira-himmel/)')
      .mockReturnValueOnce(`Collection: jira-himmel\n  Path:     ${root}\n`)
      .mockReturnValueOnce('')
      .mockImplementation(() => { throw new Error('embed boom'); });
    const msg = qmdRefresh(root, run);
    expect(msg).toContain('FAILED');
    expect(msg).toContain('sync itself succeeded');
    expect(run.mock.calls.some((c) => (c[0] as string[])[1] === 'add')).toBe(false);
  });

  it('qmdRefresh refuses to embed a collection that points at a different root', () => {
    const run = vi.fn()
      .mockReturnValueOnce('jira-himmel (qmd://jira-himmel/)')
      .mockReturnValueOnce('Collection: jira-himmel\n  Path:     /elsewhere/OTHER\n')
      .mockReturnValue('');
    const msg = qmdRefresh(root, run);
    expect(msg).toContain('FAILED');
    expect(msg).toContain('/elsewhere/OTHER');
    expect(run.mock.calls.some((c) => (c[0] as string[])[0] === 'embed')).toBe(false);
  });
});

describe('mirrorState (RM3)', () => {
  const plant = (c: Record<string, unknown>) => writeFileSync(join(root, '.cursor.json'), JSON.stringify(c));
  const base = { lastSync: '2026-11-26T16:33:57.000Z', total: 3, project: 'HIMMEL' };

  it('reads the four cursor shapes', () => {
    plant(base);
    expect(mirrorState(root)).toEqual({ complete: 'yes', repair: null, lastSync: base.lastSync, project: 'HIMMEL', next: 'incremental', repairable: false });
    plant({ ...base, complete: false });
    expect(mirrorState(root)).toEqual({ complete: 'no', repair: 'incremental', lastSync: base.lastSync, project: 'HIMMEL', next: 'incremental', repairable: true });
    plant({ ...base, complete: false, repair: 'full' });
    expect(mirrorState(root)).toMatchObject({ complete: 'no', repair: 'full', next: 'full', repairable: false });
    rmSync(join(root, '.cursor.json'));
    expect(mirrorState(root)).toEqual({ complete: 'none', repair: null, lastSync: null, project: null, next: 'full', repairable: false });
    expect(mirrorState(null)).toMatchObject({ complete: 'none', next: 'full' });
  });

  it('another project drives next full and is never repairable', () => {
    plant({ ...base, complete: false });
    expect(mirrorState(root, 'OTHER')).toMatchObject({ complete: 'no', next: 'full', repairable: false });
    expect(mirrorState(root, 'HIMMEL')).toMatchObject({ next: 'incremental', repairable: true });
    plant(base);
    expect(mirrorState(root, 'OTHER')).toMatchObject({ complete: 'yes', next: 'full' });
  });

  it('any complete value other than an absent field reads no, and an unknown repair reads incremental', () => {
    plant({ ...base, complete: true });
    expect(mirrorState(root)).toMatchObject({ complete: 'no', repair: 'incremental', repairable: true });
    plant({ ...base, complete: false, repair: 'weird' });
    expect(mirrorState(root)).toMatchObject({ repair: 'incremental' });
  });

  it('a bad lastSync reads as no cursor', () => {
    plant({ ...base, lastSync: 'nope' });
    expect(mirrorState(root)).toMatchObject({ complete: 'none', next: 'full' });
  });
});

describe('renderIssue — Sector', () => {
  const prev = process.env.JIRA_SECTOR_FIELD;
  afterEach(() => {
    if (prev === undefined) delete process.env.JIRA_SECTOR_FIELD;
    else process.env.JIRA_SECTOR_FIELD = prev;
  });

  it('writes a sector: frontmatter line from the configured field, null when unset on the ticket', () => {
    process.env.JIRA_SECTOR_FIELD = 'customfield_10212';
    const set = renderIssue(issue(7, { customfield_10212: { value: 'Visibility' } } as never), []);
    expect(set).toContain('sector: "Visibility"');
    expect(renderIssue(issue(8), [])).toContain('sector: null');
  });

  it('writes no sector line when no sector field is configured', () => {
    process.env.JIRA_SECTOR_FIELD = 'none';
    expect(renderIssue(issue(7, { customfield_10212: { value: 'Visibility' } } as never), [])).not.toContain('sector:');
  });
});
