// Write-then-read-back suite. Each row runs a CLI write, then reads
// the issue back and asserts the change landed as asked, the way a human reads
// Jira. The stub is not an author-written canned reply: it is a stateful Jira
// replaying the recorded shapes in fixtures/jira-recorded.json and the recorded
// link pair in fixtures/blocks-links-real-get.json, so a write that Jira would
// drop is dropped here too. The nightly twin is live/jira-live.test.ts.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { registerGet } from './get.js';
import { registerEdit } from './edit.js';
import { registerLink } from './link.js';
import { registerTransition } from './transition.js';
import { registerVersions } from './versions.js';

type Fields = Record<string, unknown>;
interface Named { name: string }
interface Recorded {
  issueLinkTypes: Array<{ name: string; inward: string; outward: string }>;
  versions: Named[];
  transitions: Array<{ id: string; name: string; to: Fields }>;
  priority: Named;
  status: Named;
  issuetype: Named;
  parent: { key: string };
}

const recorded = JSON.parse(
  readFileSync(new URL('./fixtures/jira-recorded.json', import.meta.url), 'utf8'),
) as Recorded;
const realLinks = JSON.parse(
  readFileSync(new URL('./fixtures/blocks-links-real-get.json', import.meta.url), 'utf8'),
) as Record<string, { fields: { issuelinks: unknown[] } }>;

const fixVersion = (name: string): Named => ({ ...(recorded.versions.find((v) => v.name === name) ?? { name }) });

class FakeJira {
  issues = new Map<string, Fields>();
  links: Array<{ id: string; type: string; inward: string; outward: string }> = [];
  // Fields Jira accepts with a 2xx and never stores (edit screen or scheme).
  dropped = new Set<string>();

  constructor() {
    for (const key of ['HIMMEL-1', 'HIMMEL-2']) {
      this.issues.set(key, {
        summary: `seed ${key}`,
        description: null,
        labels: ['seed'],
        priority: { ...recorded.priority },
        status: { ...recorded.status },
        issuetype: { ...recorded.issuetype },
        parent: { ...recorded.parent },
        fixVersions: key === 'HIMMEL-1' ? [fixVersion('v1.1.3')] : [],
        versions: [],
      });
    }
  }

  read(key: string, field: string): unknown {
    return this.issues.get(key)?.[field];
  }

  private issuelinks(key: string): unknown[] {
    const type = (name: string) => recorded.issueLinkTypes.find((t) => t.name === name);
    return this.links.flatMap((l) => {
      if (l.inward === key) return [{ id: l.id, type: type(l.type), outwardIssue: { key: l.outward } }];
      if (l.outward === key) return [{ id: l.id, type: type(l.type), inwardIssue: { key: l.inward } }];
      return [];
    });
  }

  private put(key: string, body: { fields?: Fields; update?: Record<string, Array<Record<string, Named | string>>> }): void {
    const issue = this.issues.get(key);
    if (!issue) throw new Error(`404 ${key}`);
    for (const [name, value] of Object.entries(body.fields ?? {})) {
      if (this.dropped.has(name)) continue;
      if (name === 'priority') issue[name] = { ...recorded.priority, name: (value as Named).name };
      else if (name === 'fixVersions' || name === 'versions') {
        issue[name] = (value as Named[]).map((v) => fixVersion(v.name));
      } else issue[name] = value;
    }
    for (const [name, ops] of Object.entries(body.update ?? {})) {
      if (this.dropped.has(name)) continue;
      for (const op of ops) {
        if (name === 'labels') {
          const labels = new Set(issue['labels'] as string[]);
          if (typeof op['add'] === 'string') labels.add(op['add']);
          issue['labels'] = [...labels];
        } else {
          const cur = (issue[name] as Named[]).filter((v) => v.name !== (op['remove'] as Named | undefined)?.name);
          const add = op['add'] as Named | undefined;
          issue[name] = add && !cur.some((v) => v.name === add.name) ? [...cur, fixVersion(add.name)] : cur;
        }
      }
    }
  }

  request = async (method: string, path: string, body?: unknown): Promise<unknown> => {
    const issuePath = /^\/issue\/([A-Z]+-\d+)(\/transitions|\?fields=(.*))?$/.exec(path);
    if (method === 'GET' && path === '/issueLinkType') return { issueLinkTypes: recorded.issueLinkTypes };
    if (method === 'GET' && /^\/project\/[A-Z]+\/versions$/.test(path)) return recorded.versions;
    if (issuePath) {
      const [, key, sub, fields] = issuePath;
      const issue = this.issues.get(key);
      if (!issue) throw new Error(`404 ${key}`);
      if (method === 'GET' && sub === '/transitions') return { transitions: recorded.transitions };
      if (method === 'POST' && sub === '/transitions') {
        const t = recorded.transitions.find((x) => x.id === (body as { transition: { id: string } }).transition.id);
        if (!t) throw new Error('400 unknown transition');
        if (!this.dropped.has('status')) issue['status'] = t.to;
        return {};
      }
      if (method === 'GET' && fields !== undefined) {
        const got: Fields = {};
        for (const f of fields.split(',')) {
          if (f === 'issuelinks') got[f] = this.issuelinks(key);
          else if (f in issue) got[f] = issue[f];
        }
        return { key, fields: got };
      }
      if (method === 'PUT' && sub === undefined) {
        this.put(key, body as Parameters<FakeJira['put']>[1]);
        return {};
      }
    }
    if (method === 'POST' && path === '/issueLink') {
      const b = body as { type: Named; inwardIssue: { key: string }; outwardIssue: { key: string } };
      if (!this.dropped.has('issuelinks')) {
        this.links.push({ id: String(19700 + this.links.length), type: b.type.name, inward: b.inwardIssue.key, outward: b.outwardIssue.key });
      }
      return {};
    }
    throw new Error(`fake jira: unmodelled ${method} ${path}`);
  };
}

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;
let jira: FakeJira;
let out: string[];

async function run(...args: string[]): Promise<string> {
  const before = out.length;
  const p = new Command();
  p.exitOverride();
  for (const register of [registerGet, registerEdit, registerLink, registerTransition, registerVersions]) register(p);
  await p.parseAsync(['node', 'jira', ...args]);
  return out.slice(before).join('\n');
}

beforeEach(() => {
  vi.clearAllMocks();
  out = [];
  vi.spyOn(console, 'log').mockImplementation((...a: unknown[]) => void out.push(a.join(' ')));
  vi.spyOn(console, 'error').mockImplementation(() => {});
  jira = new FakeJira();
  mockRequest.mockImplementation(jira.request);
});

const names = (v: unknown): string[] => (v as Named[]).map((x) => x.name);

describe('the stub agrees with the recorded Jira link pair', () => {
  // Recorded: link 19707 was made by `link <a> --blocked-by <b>` (POST
  // inward=<b>), link 19708 by a blocks link from the first key to the third.
  it('replays the real GET entries for both keys of both links', async () => {
    for (const key of ['HIMMEL-6494', 'HIMMEL-5556', 'HIMMEL-6572']) jira.issues.set(key, {});
    await run('link', 'HIMMEL-6494', '--blocked-by', 'HIMMEL-5556');
    await run('link', 'HIMMEL-6494', '--blocks', 'HIMMEL-6572');
    const shape = (e: unknown) => JSON.parse(JSON.stringify(e, (k, v) => (k === 'id' ? undefined : v)));
    for (const key of ['HIMMEL-6494', 'HIMMEL-5556', 'HIMMEL-6572']) {
      const got = ((await jira.request('GET', `/issue/${key}?fields=issuelinks`)) as {
        fields: { issuelinks: unknown[] };
      }).fields.issuelinks;
      expect(got.map(shape)).toEqual(realLinks[key].fields.issuelinks.map(shape));
    }
  });
});

describe('edit: every field the CLI sends is there when read back', () => {
  const rows: Array<[string, string[], () => void]> = [
    ['priority', ['--priority', 'Highest'], () => expect(jira.read('HIMMEL-1', 'priority')).toMatchObject({ name: 'Highest' })],
    ['title', ['--title', 'renamed'], () => expect(jira.read('HIMMEL-1', 'summary')).toBe('renamed')],
    ['labels', ['--labels', 'a,b'], () => expect((jira.read('HIMMEL-1', 'labels') as string[]).sort()).toEqual(['a', 'b'])],
    ['add-labels', ['--add-labels', 'extra'], () => expect((jira.read('HIMMEL-1', 'labels') as string[]).sort()).toEqual(['extra', 'seed'])],
    ['fix-version', ['--fix-version', 'v1.0.41'], () => expect(names(jira.read('HIMMEL-1', 'fixVersions'))).toEqual(['v1.0.41'])],
    ['add-fix-version', ['--add-fix-version', 'v1.0.41'], () => expect(names(jira.read('HIMMEL-1', 'fixVersions')).sort()).toEqual(['v1.0.41', 'v1.1.3'])],
    ['affects-version', ['--affects-version', 'v1.1.3'], () => expect(names(jira.read('HIMMEL-1', 'versions'))).toEqual(['v1.1.3'])],
    ['parent', ['--parent', 'HIMMEL-77'], () => expect(jira.read('HIMMEL-1', 'parent')).toMatchObject({ key: 'HIMMEL-77' })],
  ];

  it.each(rows)('--%s lands', async (_name, args, assertState) => {
    await run('edit', 'HIMMEL-1', ...args);
    assertState();
  });

  // The 4640 class: Jira answers 2xx and keeps the old value.
  it.each([
    ['priority', ['--priority', 'Highest']],
    ['summary', ['--title', 'renamed']],
    ['labels', ['--labels', 'a,b']],
    ['fixVersions', ['--fix-version', 'v1.0.41']],
    ['versions', ['--affects-version', 'v1.1.3']],
    ['parent', ['--parent', 'HIMMEL-77']],
  ])('a dropped %s makes edit fail instead of printing "edited"', async (field, args) => {
    jira.dropped.add(field);
    await expect(run('edit', 'HIMMEL-1', ...args)).rejects.toThrow(/was not changed/);
    expect(out).not.toContain('HIMMEL-1 edited');
  });

  it('get shows the new priority, the way the operator reads it', async () => {
    await run('edit', 'HIMMEL-1', '--priority', 'Highest');
    expect(await run('get', 'HIMMEL-1')).toContain('Priority: Highest');
  });

  it('get shows the new description, labels and fix version', async () => {
    await run('edit', 'HIMMEL-1', '--desc', 'marker body', '--labels', 'a', '--add-fix-version', 'v1.0.41');
    const shown = await run('get', 'HIMMEL-1');
    expect(shown).toContain('marker body');
    expect(shown).toContain('Labels: a');
    expect(shown).toContain('Fix versions: v1.1.3, v1.0.41');
  });
});

describe('link: the printed line and both ends read back the same direction', () => {
  // `<A> <relation> <B>` as the web UI shows it from A's side.
  const reads = async (a: string, b: string, relation: string): Promise<void> => {
    expect(await run('links', a)).toContain(`${a} ${relation} ${b}`);
  };

  // What Jira itself holds: the blocker's entry names the blocked issue as
  // outwardIssue, the blocked issue's entry names the blocker as inwardIssue
  // (the recorded pair above). Independent of what `links` prints.
  const stored = async (blocker: string, blocked: string): Promise<void> => {
    const raw = async (key: string) =>
      ((await jira.request('GET', `/issue/${key}?fields=issuelinks`)) as { fields: { issuelinks: unknown[] } }).fields.issuelinks;
    expect(await raw(blocker)).toMatchObject([{ outwardIssue: { key: blocked } }]);
    expect(await raw(blocked)).toMatchObject([{ inwardIssue: { key: blocker } }]);
  };

  it('--blocks: A blocks B, B is blocked by A', async () => {
    const printed = await run('link', 'HIMMEL-1', '--blocks', 'HIMMEL-2');
    await stored('HIMMEL-1', 'HIMMEL-2');
    await reads('HIMMEL-1', 'HIMMEL-2', 'blocks');
    await reads('HIMMEL-2', 'HIMMEL-1', 'is blocked by');
    expect(printed).toBe('Linked: HIMMEL-1 blocks HIMMEL-2');
  });

  it('--blocked-by: A is blocked by B, B blocks A', async () => {
    const printed = await run('link', 'HIMMEL-1', '--blocked-by', 'HIMMEL-2');
    await stored('HIMMEL-2', 'HIMMEL-1');
    await reads('HIMMEL-1', 'HIMMEL-2', 'is blocked by');
    await reads('HIMMEL-2', 'HIMMEL-1', 'blocks');
    expect(printed).toBe('Linked: HIMMEL-2 blocks HIMMEL-1');
  });

  it('bare Relates: printed in the words links shows', async () => {
    const printed = await run('link', 'HIMMEL-1', 'HIMMEL-2', '--type', 'Relates');
    await reads('HIMMEL-1', 'HIMMEL-2', 'relates to');
    await reads('HIMMEL-2', 'HIMMEL-1', 'relates to');
    expect(printed).toBe('Linked: HIMMEL-1 relates to HIMMEL-2');
  });
});

describe('transition: the status read back is the one asked for', () => {
  it('In Progress lands', async () => {
    await run('transition', 'HIMMEL-1', 'In Review');
    expect(jira.read('HIMMEL-1', 'status')).toMatchObject({ name: 'In Review' });
    expect(await run('get', 'HIMMEL-1', '--short')).toContain('In Review');
  });

  it('Done on a versionless issue lands the status and the stamped fix version', async () => {
    await run('transition', 'HIMMEL-2', 'Done');
    expect(jira.read('HIMMEL-2', 'status')).toMatchObject({ name: 'Done' });
    expect(names(jira.read('HIMMEL-2', 'fixVersions'))).toEqual(['v1.1.3']);
  });
});

describe('fix-version and affects-version verbs land', () => {
  it('fix-version --add / --remove', async () => {
    await run('fix-version', 'HIMMEL-1', '--add', 'v1.0.41');
    expect(names(jira.read('HIMMEL-1', 'fixVersions')).sort()).toEqual(['v1.0.41', 'v1.1.3']);
    await run('fix-version', 'HIMMEL-1', '--remove', 'v1.1.3');
    expect(names(jira.read('HIMMEL-1', 'fixVersions'))).toEqual(['v1.0.41']);
  });

  it('affects-version --add / --remove', async () => {
    await run('affects-version', 'HIMMEL-1', '--add', 'v1.1.3');
    expect(names(jira.read('HIMMEL-1', 'versions'))).toEqual(['v1.1.3']);
    await run('affects-version', 'HIMMEL-1', '--remove', 'v1.1.3');
    expect(names(jira.read('HIMMEL-1', 'versions'))).toEqual([]);
  });
});

// The 4640 class again: Jira answers 2xx and keeps the old value, so each write
// reads the issue back and fails loud instead of printing success.
describe('writes fail loud when Jira drops them', () => {
  it('transition', async () => {
    jira.dropped.add('status');
    await expect(run('transition', 'HIMMEL-1', 'In Review')).rejects.toThrow(/was not changed/);
    expect(out.join('\n')).not.toContain('→');
  });

  it('fix-version verb', async () => {
    jira.dropped.add('fixVersions');
    await expect(run('fix-version', 'HIMMEL-1', '--add', 'v1.0.41')).rejects.toThrow(/was not changed/);
  });

  it('affects-version verb', async () => {
    jira.dropped.add('versions');
    await expect(run('affects-version', 'HIMMEL-1', '--add', 'v1.1.3')).rejects.toThrow(/was not changed/);
  });

  it('link', async () => {
    jira.dropped.add('issuelinks');
    await expect(run('link', 'HIMMEL-1', '--blocks', 'HIMMEL-2')).rejects.toThrow(/was not changed/);
    expect(out.join('\n')).not.toContain('Linked');
  });
});
