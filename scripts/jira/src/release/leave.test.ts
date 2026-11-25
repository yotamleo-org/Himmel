import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { declare, releaseForProject, type Ctx, type DeclaredRelease, type JiraPort } from './engine.js';
import { leaveCheck, type Leave } from './leave.js';
import { readVersionWrites } from './version-writes.js';
import { setFixVersion } from '../commands/versions.js';
import type { Op, OperatorRow } from './types.js';

let root: string;

function releaseCtx(release: string): Ctx {
  return {
    release, dir: join(root, 'release', release), keyPath: join(root, 'keys', `${release}.key`),
    env: {}, now: () => new Date('2026-11-23T10:00:00.000Z'), jira: {} as JiraPort, mirrorRoot: null,
  };
}

function versionsTsv(project: string, rows: Array<[string, boolean]>): void {
  const dir = join(process.env.HOME as string, '.himmel', 'state', 'jira-mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${project}.versions.tsv`), rows.map(([n, released]) => `${n}\t${released}\t\tfalse`).join('\n') + '\n');
}

type Entry = { id: string; created: string; items: Array<{ field: string; fromString: string | null; toString: string | null }> };
interface Transport { set: string[]; entries: Entry[]; calls: Array<{ method: string; path: string; body?: unknown }>; getStatus?: number }

function transport(set: string[], o: { getStatus?: number } = {}): Transport {
  const t: Transport = { set: [...set], entries: [], calls: [], ...o };
  const reply = (status: number, body: unknown) => ({ ok: status < 400, status, headers: new Headers(), text: async () => (body === undefined ? '' : JSON.stringify(body)) });
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const method = init.method ?? 'GET';
    const u = new URL(url);
    const path = u.pathname.replace('/rest/api/3', '');
    const body = init.body ? JSON.parse(String(init.body)) as { update?: { fixVersions?: Array<{ add?: { name: string }; remove?: { name: string } }> } } : undefined;
    t.calls.push({ method, path, ...(body ? { body } : {}) });
    if (method === 'GET') {
      if (t.getStatus) return reply(t.getStatus, { errorMessages: ['boom'] });
      if (path.endsWith('/changelog')) return reply(200, { startAt: 0, maxResults: 100, total: t.entries.length, values: t.entries });
      return reply(200, { fields: { fixVersions: t.set.map((name) => ({ name })) } });
    }
    const items: Entry['items'] = [];
    for (const op of body?.update?.fixVersions ?? []) {
      if (op.add && !t.set.includes(op.add.name)) { t.set = [...t.set, op.add.name]; items.push({ field: 'Fix Version', fromString: null, toString: op.add.name }); }
      if (op.remove && t.set.includes(op.remove.name)) { t.set = t.set.filter((v) => v !== op.remove?.name); items.push({ field: 'Fix Version', fromString: op.remove.name, toString: null }); }
    }
    if (items.length) t.entries.push({ id: String(600 + t.entries.length), created: '2026-11-23T10:00:00.000+0100', items });
    return reply(204, undefined);
  }));
  return t;
}

const puts = (t: Transport) => t.calls.filter((c) => c.method !== 'GET');
const himmel = () => declare(releaseCtx('v1.1.3'), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '1', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'leave-'));
  vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
  vi.stubEnv('JIRA_ALLOW_HOST', '127.0.0.1:9');
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_VERSION_WRITES', '');
  vi.stubEnv('HIMMEL_VERSION_WRITER', '');
  vi.stubEnv('HOME', join(root, 'home'));
  mkdirSync(join(root, 'home'), { recursive: true });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  rmSync(root, { recursive: true, force: true });
});

describe('leave check (RED row)', () => {
  it('fix-version HIMMEL-1 --remove v1.1.3 on a ticket holding only v1.1.3 is refused before any PUT', async () => {
    declare(releaseCtx('v1.1.3'), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '1', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    versionsTsv('HIMMEL', [['v1.1.2', true], ['v1.1.3', false], ['v1.1.4', false]]);
    const t = transport(['v1.1.3']);
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.3')).rejects.toThrow(/v1\.1\.3/);
    expect(puts(t)).toHaveLength(0);
    expect(t.set).toEqual(['v1.1.3']);
  });
});

const R: DeclaredRelease = { release: 'R', project: 'HIMMEL', current: 'v1.1.3', versions: ['v1.1.3', 'v1.1.4'] };
const decision = (id: string, ts: string, op: string, from_v: string | null, to_v: string | null, keys = ['HIMMEL-1']): OperatorRow =>
  ({ id, kind: 'decision', ts, decision: '1', keys, op, from_v, to_v });
const chain = (...rows: OperatorRow[]) => new Map([['R', new Map(rows.map((r) => [r.id, r]))]]);

function check(o: { before: string[]; after: string[] | null; mechanism?: string; leave?: Leave; own?: string[];
  decls?: DeclaredRelease[] | 'unreadable'; ops?: Map<string, Map<string, OperatorRow> | 'unreadable'>; released?: Set<string> | 'unreadable'; key?: string }) {
  return leaveCheck({ key: o.key ?? 'HIMMEL-1', before: o.before, after: o.after, mechanism: o.mechanism ?? 'hand', leave: o.leave, ownAdds: new Set(o.own ?? []),
    decls: o.decls ?? [R], ops: o.ops ?? new Map(), released: o.released ?? new Set(['v1.1.2']) });
}
const refused = (v: ReturnType<typeof leaveCheck>): string => (v.ok ? '' : v.reason);

describe('leaveCheck (I1)', () => {
  describe('refused', () => {
    it('a hand remove that leaves no earlier version', () => {
      expect(refused(check({ before: ['v1.1.3'], after: [] }))).toMatch(/HIMMEL-1: .*open version v1\.1\.3 with no operator record.*--by <O-id>.*--chief-reason/);
    });

    it('a remove with a record that does not cover it', () => {
      const ops = chain(decision('O-1', '2026-11-01T00:00:00Z', 'add', null, 'v1.1.4'));
      expect(refused(check({ before: ['v1.1.3'], after: [], leave: { by: 'O-1' }, ops }))).toMatch(/O-1 does not cover remove v1\.1\.3→backlog or move v1\.1\.3→backlog/);
    });

    it('an unverifiable or unparsed declaration', () => {
      expect(refused(check({ before: ['v1.1.3'], after: [], decls: 'unreadable' }))).toMatch(/declared releases cannot be read/);
    });

    it('an rm-apply remove whose after-set has no earlier version', () => {
      expect(refused(check({ before: ['v1.1.3'], after: ['v1.1.4'], mechanism: 'rm-apply' }))).toMatch(/open version v1\.1\.3/);
      expect(refused(check({ before: ['v1.1.3'], after: [], mechanism: 'rm-apply' }))).toMatch(/open version v1\.1\.3/);
    });

    it('a transition-stamp fold toward a Jira current that is not the declared current', () => {
      expect(refused(check({ before: ['v1.1.3'], after: ['v1.1.4'], mechanism: 'transition-stamp' }))).toMatch(/open version v1\.1\.3/);
    });

    it('--by naming a covering record that a newer operator record on the key supersedes (F2, the O-0052 then O-0945 shape)', () => {
      const ops = chain(decision('O-v1.1.3-0052', '2026-11-01T00:00:00Z', 'remove', 'v1.1.3', null), decision('O-v1.1.3-0945', '2026-11-10T00:00:00Z', 'add', null, 'v1.1.3'));
      expect(refused(check({ before: ['v1.1.3'], after: [], leave: { by: 'O-v1.1.3-0052' }, ops }))).toMatch(/O-v1\.1\.3-0052 is not the newest operator decision on HIMMEL-1 \(O-v1\.1\.3-0945 is\)/);
    });

    it('--by with the operator chain unreadable (T3)', () => {
      expect(refused(check({ before: ['v1.1.3'], after: [], leave: { by: 'O-1' }, ops: new Map([['R', 'unreadable' as const]]) }))).toMatch(/operator chain of R cannot be read/);
    });

    it('a removal with no readable versions file (T3)', () => {
      expect(refused(check({ before: ['v1.1.3'], after: [], released: 'unreadable' }))).toMatch(/versions file cannot be read/);
    });

    it('a body the check cannot read on a ticket holding an open declared version (T12)', () => {
      expect(refused(check({ before: ['v1.1.3'], after: null }))).toMatch(/cannot read while HIMMEL-1 holds the open version v1\.1\.3/);
      expect(check({ before: ['v1.1.2'], after: null }).ok).toBe(true);
    });

    it('an unresolvable release root refuses every removal, for HIMMEL and SALUS keys, names USER_SLUG, and still passes an add (N2, P12)', () => {
      for (const key of ['HIMMEL-1', 'SALUS-1']) {
        expect(refused(check({ key, before: ['v1'], after: [], decls: 'unreadable' }))).toMatch(/USER_SLUG/);
        expect(check({ key, before: ['v1'], after: ['v1', 'v2'], decls: 'unreadable' }).ok).toBe(true);
      }
      expect(releaseForProject({ HOME: join(root, 'home') }, 'HIMMEL')).toBe('unreadable');
    });

    it('a fold whose target is a released version an old declaration still names as current (N7)', () => {
      const old: DeclaredRelease = { release: 'R0', project: 'HIMMEL', current: 'v1.1.2', versions: ['v1.1.2', 'v1.1.3'] };
      expect(refused(check({ before: ['v1.1.3'], after: ['v1.1.2'], mechanism: 'merge-stamp', decls: [old] }))).toMatch(/open version v1\.1\.3/);
    });
  });

  describe('passes', () => {
    it('a merge-stamp full replace that drops v1.1.4 while setting v1.1.3', () => {
      expect(check({ before: ['v1.1.4'], after: ['v1.1.3'], mechanism: 'merge-stamp' }).ok).toBe(true);
    });

    it('a full replace that drops a released v1.1.2', () => {
      expect(check({ before: ['v1.1.2'], after: ['v1.1.3'] }).ok).toBe(true);
    });

    it('a remove with --by naming the covering newest decision', () => {
      const ops = chain(decision('O-1', '2026-11-01T00:00:00Z', 'remove', 'v1.1.3', null));
      expect(check({ before: ['v1.1.3'], after: [], leave: { by: 'O-1' }, ops }).ok).toBe(true);
    });

    it('a version-defer remove under a move record', () => {
      const ops = chain(decision('O-2', '2026-11-01T00:00:00Z', 'move', 'v1.1.3', 'v1.1.4'));
      expect(check({ before: ['v1.1.3', 'v1.1.4'], after: ['v1.1.4'], leave: { by: 'O-2' }, ops }).ok).toBe(true);
    });

    it('a ruling\'s whole op is checked when it names the removed version', () => {
      const ops = chain(decision('O-3', '2026-11-01T00:00:00Z', 'move', 'v1.1.3', 'v1.1.4'));
      const op: Op = { kind: 'move', from_v: 'v1.1.3', to_v: 'v1.1.4' };
      expect(check({ before: ['v1.1.3', 'v1.1.4'], after: ['v1.1.4'], mechanism: 'rm-apply', leave: { by: 'O-3', op }, ops }).ok).toBe(true);
    });

    it('a version-defer rollback, as the undo of its own add', () => {
      expect(check({ before: ['v1.1.3', 'v1.1.4'], after: ['v1.1.3'], own: ['v1.1.4'] }).ok).toBe(true);
    });
  });

  describe('not checked', () => {
    it('an add-only write', () => {
      expect(check({ before: ['v1.1.3'], after: ['v1.1.3', 'v1.1.4'], decls: 'unreadable', released: 'unreadable' }).ok).toBe(true);
    });

    it('a key no declaration names', () => {
      expect(check({ key: 'SALUS-1', before: ['v1'], after: [], decls: [] }).ok).toBe(true);
    });
  });

  it('two declared releases: a version counts when either declares it, and "earlier" is read inside the one that declares both', () => {
    const next: DeclaredRelease = { release: 'R2', project: 'HIMMEL', current: 'v1.1.5', versions: ['v1.1.5'] };
    expect(check({ before: ['v1.1.4'], after: ['v1.1.3'], mechanism: 'rm-apply', decls: [R, next] }).ok).toBe(true);
    expect(refused(check({ before: ['v1.1.5'], after: ['v1.1.3'], mechanism: 'rm-apply', decls: [R, next] }))).toMatch(/open version v1\.1\.5/);
    expect(refused(check({ before: ['v1.1.5'], after: [], decls: [R, next] }))).toMatch(/open version v1\.1\.5/);
  });
});

describe('through the client on fixture roots (T4)', () => {
  beforeEach(() => {
    versionsTsv('HIMMEL', [['v1.1.2', true], ['v1.1.3', false], ['v1.1.4', false]]);
  });

  it('a hand remove with the journal off (NODE_ENV=test, no HIMMEL_VERSION_WRITES) is refused', async () => {
    himmel();
    expect(process.env.NODE_ENV).toBe('test');
    const t = transport(['v1.1.3']);
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.3')).rejects.toThrow(/open version v1\.1\.3/);
    expect(puts(t)).toHaveLength(0);
  });

  it('an unreadable before-set refuses the removal before its PUT', async () => {
    himmel();
    const t = transport(['v1.1.3'], { getStatus: 500 });
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.3')).rejects.toThrow(/versions HIMMEL-1 holds cannot be read/);
    expect(puts(t)).toHaveLength(0);
  });

  it('a declaration whose mac does not verify, or that does not parse, refuses the removal', async () => {
    himmel();
    const path = join(root, 'release', 'v1.1.3', 'release.json');
    const d = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
    writeFileSync(path, JSON.stringify({ ...d, current: 'v1.1.4' }));
    let t = transport(['v1.1.3', 'v1.1.4']);
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.4')).rejects.toThrow(/USER_SLUG/);
    writeFileSync(path, 'not json');
    t = transport(['v1.1.3', 'v1.1.4']);
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.4')).rejects.toThrow(/USER_SLUG/);
    expect(puts(t)).toHaveLength(0);
  });

  it('version-defer\'s rollback of a version the ticket already held is not an own add (N3)', async () => {
    himmel();
    const t = transport(['v1.1.3', 'v1.1.4']);
    await setFixVersion('HIMMEL-2', 'add', 'v1.1.4');
    await expect(setFixVersion('HIMMEL-2', 'remove', 'v1.1.4')).rejects.toThrow(/open version v1\.1\.4/);
    expect(t.set).toEqual(['v1.1.3', 'v1.1.4']);
  });

  it('the rollback of this process\'s own add passes (rule 3)', async () => {
    himmel();
    const t = transport(['v1.1.3']);
    await setFixVersion('HIMMEL-3', 'add', 'v1.1.4');
    await setFixVersion('HIMMEL-3', 'remove', 'v1.1.4');
    expect(t.set).toEqual(['v1.1.3']);
  });

  it('an own add is retired once removed: a version another writer re-adds is not this process\'s to remove', async () => {
    himmel();
    const t = transport(['v1.1.3']);
    await setFixVersion('HIMMEL-5', 'add', 'v1.1.4');
    await setFixVersion('HIMMEL-5', 'remove', 'v1.1.4');
    t.set = ['v1.1.3', 'v1.1.4'];
    await expect(setFixVersion('HIMMEL-5', 'remove', 'v1.1.4')).rejects.toThrow(/open version v1\.1\.4/);
    expect(t.set).toEqual(['v1.1.3', 'v1.1.4']);
  });

  it('a SALUS key under only a HIMMEL declaration is skipped, and its journal row is written', async () => {
    himmel();
    const journal = join(root, 'version-writes.jsonl');
    vi.stubEnv('HIMMEL_VERSION_WRITES', journal);
    const t = transport(['v1']);
    await setFixVersion('SALUS-1', 'remove', 'v1');
    expect(puts(t)).toHaveLength(1);
    expect(readVersionWrites(journal)).toMatchObject([{ key: 'SALUS-1', from: ['v1'], to: [], mechanism: 'hand' }]);
  });
});
