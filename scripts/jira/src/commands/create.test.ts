import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Mock the network + breadcrumb layers so the command action resolves without
// a real Jira or a real breadcrumb file write (same pattern as
// breadcrumb-wiring.test.ts).
vi.mock('../client.js', () => ({
  request: vi.fn(async () => ({ key: 'HIMMEL-1' })),
  projectKey: () => 'HIMMEL',
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { resolveTitle, registerCreate } from './create.js';
import { request } from '../client.js';
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { SECTORS, resetSectorCache } from './sector.js';

// A body that satisfies the plain-block rule.
const PLAIN = PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled');

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

// A Sector and a parent epic: the home a Task, Story or Bug needs to be filed.
const HOME = ['--sector', 'Ship loop', '--parent', 'HIMMEL-9'];

describe('create — resolveTitle (HIMMEL-1188)', () => {
  it('accepts --title', () => {
    expect(resolveTitle({ title: 'From title' })).toBe('From title');
  });

  it('accepts --summary as an alias for --title', () => {
    expect(resolveTitle({ summary: 'From summary' })).toBe('From summary');
  });

  it('prefers --title when both --title and --summary are given', () => {
    expect(resolveTitle({ title: 'Title wins', summary: 'Summary loses' })).toBe(
      'Title wins',
    );
  });

  it('throws when neither --title nor --summary is given', () => {
    expect(() => resolveTitle({})).toThrow(/--title.*--summary/);
  });
});

// Command-level wiring (CR #1191 follow-up): exercise Commander option parsing
// + the resulting POST /issue payload, not just resolveTitle in isolation — a
// regression in the --summary option registration or the fields.summary wiring
// would slip past the unit tests above.
describe('create — command wiring (--summary → POST /issue payload)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  it('parses --summary and wires it into the POST /issue summary field', async () => {
    const p = new Command();
    p.exitOverride(); // throw instead of process.exit on parse errors
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--summary',
      'From CLI summary',
      ...HOME,
    ]);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path, body] = mockRequest.mock.calls[0] as [
      string,
      string,
      { fields: { summary: string; issuetype: { name: string } } },
    ];
    expect(method).toBe('POST');
    expect(path).toBe('/issue');
    expect(body.fields.summary).toBe('From CLI summary');
    expect(body.fields.issuetype.name).toBe('Task');
  });

  it('lets --title win over --summary through the parsed command', async () => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--summary',
      'summary loses',
      '--title',
      'title wins',
      ...HOME,
    ]);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [, , body] = mockRequest.mock.calls.find((c) => c[0] === 'POST') as [
      string,
      string,
      { fields: { summary: string } },
    ];
    expect(body.fields.summary).toBe('title wins');
  });
});

// A Bug defaults to the earliest unreleased version at the filing point.
describe('create — Bug default fixVersion wiring', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  async function createFields(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', '--desc', PLAIN, ...HOME, ...args]);
    const [, , body] = mockRequest.mock.calls.find((c) => c[0] === 'POST') as [
      string,
      string,
      { fields: { fixVersions?: { name: string }[] } },
    ];
    return body.fields;
  }

  const VERSIONS = [
    { id: '1', name: 'v1.0.0', released: true },
    { id: '2', name: 'v1.0.1', released: true },
    { id: '3', name: 'v1.0.2', released: false },
  ];
  const withVersions = (versions: unknown) =>
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? versions : { key: 'HIMMEL-1' },
    );
  const postedFields = () => {
    const call = mockRequest.mock.calls.find((c) => c[0] === 'POST');
    return (call?.[2] as { fields: { fixVersions?: { name: string }[] } }).fields;
  };

  it('defaults a Bug to the earliest unreleased version and says so', async () => {
    withVersions(VERSIONS);
    await createFields(['--type', 'Bug', '--priority', 'Highest']);
    expect(postedFields().fixVersions).toEqual([{ name: 'v1.0.2' }]);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/defaults to fixVersion v1\.0\.2/));
  });

  it('lets an explicit --fix-version win over the default', async () => {
    withVersions(VERSIONS);
    await createFields(['--type', 'Bug', '--fix-version', 'v1.0.0']);
    expect(postedFields().fixVersions).toEqual([{ name: 'v1.0.0' }]);
  });

  it('files with no fixVersion and a warning when no unreleased version can be found', async () => {
    withVersions([{ id: '1', name: 'v1.0.0', released: true }]);
    await createFields(['--type', 'Bug', '--priority', 'Highest']);
    expect(postedFields().fixVersions).toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/no unreleased version.*no fixVersion/));
  });

  it('files with no fixVersion and a warning when the versions cannot be read', async () => {
    mockRequest.mockImplementation(async (method: string) => {
      if (method === 'GET') throw new Error('boom');
      return { key: 'HIMMEL-1' };
    });
    await createFields(['--type', 'Bug', '--priority', 'Highest']);
    expect(postedFields().fixVersions).toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/no unreleased version.*no fixVersion/));
  });

  it('sets no fixVersion on a Task', async () => {
    withVersions(VERSIONS);
    const fields = await createFields(['--type', 'Task']);
    expect(fields.fixVersions).toBeUndefined();
  });
});

describe('create --fix-version (HIMMEL-3713)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('validates against the project versions then sets fixVersions', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-20T12:00:00'));
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? [{ id: '1', name: 'v1.0.0' }] : { key: 'HIMMEL-1' },
    );
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--title',
      't',
      '--fix-version',
      'v1.0.0',
      ...HOME,
    ]);
    const postCall = mockRequest.mock.calls.find((c) => c[0] === 'POST');
    expect((postCall?.[2] as { fields: { fixVersions?: unknown } }).fields.fixVersions).toEqual([
      { name: 'v1.0.0' },
    ]);
  });

  it('rejects an unknown --fix-version naming the project, without ever POSTing', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-20T12:00:00'));
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? [{ id: '1', name: 'v1.0.0' }] : { key: 'HIMMEL-1' },
    );
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await expect(
      p.parseAsync([
        'node',
        'jira',
        'create',
        '--desc',
        PLAIN,
        '--type',
        'Task',
        '--title',
        't',
        '--fix-version',
        'v9.9.9',
        ...HOME,
      ]),
    ).rejects.toThrow(/no version named "v9\.9\.9" in project HIMMEL/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
  });
});

// A body without the plain Impact/What/Why block is refused.
describe('create — plain block rule (HIMMEL-5226)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((c?: number) => {
      throw new Error(`exit ${c}`);
    }) as never);
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  async function run(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', ...args]);
  }
  const posted = () => mockRequest.mock.calls.some((c) => c[0] === 'POST');

  it('refuses a Task whose body has no plain block, names what is missing and prints the template', async () => {
    await expect(run(['--type', 'Task', '--desc', 'just agent notes'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/missing "## Impact"/);
    expect(msg).toContain('## Agent detail');
  });

  it('refuses a Task with every section but no DoD, naming DoD (HIMMEL-5643)', async () => {
    const noDod = PLAIN.replace(/## DoD\n[^\n]*\n\n/, '');
    await expect(run(['--type', 'Task', '--desc', noDod])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/missing "## DoD"/);
  });

  it('refuses a Task whose Plan and DoD are only the skeleton placeholders (HIMMEL-5643)', async () => {
    await expect(run(['--type', 'Task', '--desc', PLAIN_BLOCK_TEMPLATE])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/"## Plan" has no bullet.*"## DoD" has no bullet/s);
  });

  it('warns, and still files, a Task whose title breaks the template (HIMMEL-6968)', async () => {
    await run(['--type', 'Task', '--title', 'feat(jira): add a thing', '--desc', PLAIN, ...HOME]);
    expect(posted()).toBe(true);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning: title.*commit prefix/s));
  });

  it('does not warn about the title of a fitting Task (HIMMEL-6968)', async () => {
    await run(['--type', 'Task', '--title', 'Ship loop: merge waits for the signed GO', '--desc', PLAIN, ...HOME]);
    expect(posted()).toBe(true);
    expect(console.error).not.toHaveBeenCalledWith(expect.stringMatching(/warning: title/));
  });

  it('refuses a body-less Task', async () => {
    await expect(run(['--type', 'Task'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });

  it('refuses a block with an empty Impact section', async () => {
    const empty = PLAIN.replace(/## Impact\n[^\n]*\n/, '## Impact\n');
    await expect(run(['--type', 'Story', '--desc', empty])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });

  it('accepts a body that carries the full block', async () => {
    await run(['--type', 'Task', '--desc', PLAIN, ...HOME]);
    expect(posted()).toBe(true);
  });

  it('--skeleton prints the six-heading body to fill and creates nothing', async () => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--skeleton']);
    expect(console.log).toHaveBeenCalledWith(PLAIN_BLOCK_TEMPLATE);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('only warns for an Epic with no body, and still files it', async () => {
    await run(['--type', 'Epic']);
    expect(posted()).toBe(true);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning.*Impact.*Epic is exempt/s));
  });

  it('only warns for an Epic that lacks Plan and DoD (HIMMEL-5643)', async () => {
    const noPlanDod = PLAIN.replace(/## Plan\n[^\n]*\n\n## DoD\n[^\n]*\n\n/, '');
    await run(['--type', 'Epic', '--desc', noPlanDod]);
    expect(posted()).toBe(true);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning.*Plan.*DoD.*Epic is exempt/s));
  });

  it('refuses a pre-built --adf-file with no plain block', async () => {
    const { writeFileSync, mkdtempSync } = await import('node:fs');
    const { join } = await import('node:path');
    const { tmpdir } = await import('node:os');
    const f = join(mkdtempSync(join(tmpdir(), 'adf-')), 'b.json');
    writeFileSync(
      f,
      JSON.stringify({ type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'x' }] }] }),
    );
    await expect(run(['--type', 'Task', '--adf-file', f])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });
});

// create refuses a ticket with no Sector and no epic / standalone marker.
describe('create — Sector and home rule (HIMMEL-6223, HIMMEL-6277)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetSectorCache();
    process.env.JIRA_SECTOR_FIELD = 'customfield_10212';
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((c?: number) => {
      throw new Error(`exit ${c}`);
    }) as never);
    // The field's context and options are read live from Jira.
    mockRequest.mockImplementation(async (_m: string, path: string) => {
      if (path.split('?')[0].endsWith('/context')) return { values: [{ id: '1' }] };
      if (path.includes('/option')) return { values: SECTORS.map((value) => ({ value })) };
      return { key: 'HIMMEL-1' };
    });
  });
  afterEach(() => {
    delete process.env.JIRA_SECTOR_FIELD;
  });

  async function run(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', '--desc', PLAIN, ...args]);
  }
  const posted = () => mockRequest.mock.calls.find((c) => c[0] === 'POST');
  const errText = () => (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');

  it('refuses a Task with no Sector, naming the field, the valid options and the opt-out', async () => {
    await expect(run(['--type', 'Task', '--parent', 'HIMMEL-9'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBeUndefined();
    expect(errText()).toMatch(/no Sector.*--sector.*Ship loop.*sector setup --opt-out/s);
  });

  it('with JIRA_SECTOR_FIELD unset, files a Task without --sector and sends no Sector field', async () => {
    delete process.env.JIRA_SECTOR_FIELD;
    await run(['--type', 'Task', '--parent', 'HIMMEL-9']);
    const body = posted()![2] as { fields: Record<string, unknown> };
    expect(Object.keys(body.fields).filter((k) => k.startsWith('customfield_'))).toEqual([]);
    expect(mockRequest.mock.calls.some((c) => String(c[1]).startsWith('/field/'))).toBe(false);
  });

  it('with JIRA_SECTOR_FIELD=none, behaves as unset; an explicit --sector is ignored with a warning', async () => {
    process.env.JIRA_SECTOR_FIELD = 'none';
    await run(['--type', 'Task', '--sector', 'Ship loop', '--parent', 'HIMMEL-9']);
    const body = posted()![2] as { fields: Record<string, unknown> };
    expect(body.fields['customfield_10212']).toBeUndefined();
    expect(errText()).toMatch(/--sector ignored.*sector setup/);
  });

  it('with the field unset, still refuses a Task with neither --parent nor the standalone label', async () => {
    delete process.env.JIRA_SECTOR_FIELD;
    await expect(run(['--type', 'Task'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBeUndefined();
    expect(errText()).toMatch(/--parent.*--labels standalone/s);
  });

  it('accepts an option that exists only in the live list, not in the default set', async () => {
    mockRequest.mockImplementation(async (_m: string, path: string) => {
      if (path.split('?')[0].endsWith('/context')) return { values: [{ id: '1' }] };
      if (path.includes('/option')) return { values: [{ value: 'Billing' }] };
      return { key: 'HIMMEL-1' };
    });
    await run(['--type', 'Task', '--sector', 'billing', '--parent', 'HIMMEL-9']);
    const body = posted()![2] as { fields: Record<string, unknown> };
    expect(body.fields['customfield_10212']).toEqual({ value: 'Billing' });
  });

  it('refuses a Task with a Sector but neither --parent nor the standalone label', async () => {
    await expect(run(['--type', 'Task', '--sector', 'Ship loop'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBeUndefined();
    expect(errText()).toMatch(/--parent.*--labels standalone/s);
  });

  it('creates with a Sector and --parent, writing the Sector field', async () => {
    await run(['--type', 'Task', '--sector', 'ship loop', '--parent', 'HIMMEL-9']);
    const body = posted()![2] as { fields: Record<string, unknown> };
    expect(body.fields['customfield_10212']).toEqual({ value: 'Ship loop' });
    expect(body.fields['parent']).toEqual({ key: 'HIMMEL-9' });
  });

  it('creates with a Sector and the standalone label', async () => {
    await run(['--type', 'Task', '--sector', 'Ship loop', '--labels', 'standalone']);
    expect(posted()).toBeDefined();
  });

  it('only warns for an Epic with neither, and still files it', async () => {
    await run(['--type', 'Epic']);
    expect(posted()).toBeDefined();
    expect(errText()).toMatch(/warning.*Sector.*Epic is exempt/s);
  });

  it('refuses an unknown --sector before posting', async () => {
    await expect(run(['--type', 'Task', '--sector', 'Bogus', '--parent', 'HIMMEL-9'])).rejects.toThrow(
      /Unknown sector 'Bogus'/,
    );
    expect(posted()).toBeUndefined();
  });
});

// The one residual writer. The mock plays Jira: a parent with labels, a
// version list, and a search whose hit count is the open residuals.
describe('create --residual-of', () => {
  type Opts = { parentLabels?: string[]; open?: number; budgetDesc?: string; dup?: string; noVersion?: boolean; parentVersion?: string };
  let searches: string[];
  const play = (o: Opts = {}) => {
    searches = [];
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-50')) {
        return { fields: { labels: o.parentLabels ?? [], fixVersions: o.parentVersion ? [{ name: o.parentVersion }] : [] } };
      }
      if (method === 'GET' && path.endsWith('/versions')) {
        return o.noVersion
          ? []
          : [{ name: 'v1.1.3', released: false, description: o.budgetDesc }, { name: 'v1.1.4', released: false }];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) {
        const jql = decodeURIComponent(path);
        searches.push(jql);
        if (jql.includes('area-')) return { issues: o.dup ? [{ key: o.dup }] : [] };
        return { issues: Array.from({ length: o.open ?? 0 }, (_, i) => ({ key: `HIMMEL-${900 + i}`,
          fields: { labels: ['residual', 'fu-hardening'], status: { name: 'In Progress', statusCategory: { key: 'indeterminate' } } } })) };
      }
      return { key: 'HIMMEL-77' };
    });
  };
  const file = async (...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 'r', '--desc', PLAIN, ...HOME, ...args]);
  };
  const created = () => {
    const c = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue');
    return c ? (c[2] as { fields: Record<string, unknown> }).fields : undefined;
  };
  const RES = ['--residual-of', 'HIMMEL-50', '--class', 'shell-quoting'];

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('polish goes to the backlog: no fixVersion, labels residual, depth 1, class', async () => {
    play();
    await file(...RES, '--fu-class', 'polish');
    const f = created()!;
    expect(f['fixVersions']).toBeUndefined();
    expect(f['labels']).toEqual(expect.arrayContaining(['residual', 'residual-depth-1', 'class-shell-quoting']));
    expect(f['labels']).not.toContain('residual-displaced');
  });

  it('RED b: escape steps down when a full version holds only started residuals, and stamps affectsVersion', async () => {
    play({ open: 40 });
    await file(...RES, '--fu-class', 'escape');
    const f = created()!;
    expect(f['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
    expect(f['versions']).toEqual([{ name: 'v1.1.3' }]);
  });

  const HARD = ['--fu-class', 'hardening', '--fu-why', 'no-check'];

  it('hardening under the budget lands in its placed version', async () => {
    play({ open: 14 });
    await file(...RES, ...HARD, '--priority', 'High');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
  });

  it('hardening at 15/15 goes to the backlog with residual-displaced', async () => {
    play({ open: 15 });
    await file(...RES, ...HARD, '--priority', 'High');
    const f = created()!;
    expect(f['fixVersions']).toBeUndefined();
    expect(f['labels']).toContain('residual-displaced');
  });

  it('a residual-budget:N line in the version description overrides the default', async () => {
    play({ open: 3, budgetDesc: 'sprint goal\nresidual-budget:3', parentVersion: 'v1.1.3' });
    await file(...RES, ...HARD);
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
    expect(created()!['labels']).toContain('residual-displaced');
  });

  it('depth 2 or more goes to the backlog even for an escape', async () => {
    play({ parentLabels: ['residual-depth-1'] });
    await file(...RES, '--fu-class', 'escape');
    const f = created()!;
    expect(f['labels']).toContain('residual-depth-2');
    expect(f['fixVersions']).toBeUndefined();
  });

  it('an open residual with the same class and area gets a comment and a link, not a ticket', async () => {
    play({ dup: 'HIMMEL-31' });
    await file(...RES, ...HARD, '--area', 'cr scripts');
    expect(created()).toBeUndefined();
    const posts = mockRequest.mock.calls.filter((x) => x[0] === 'POST').map((x) => x[1]);
    expect(posts).toEqual(['/issue/HIMMEL-31/comment', '/issueLink']);
    const comment = mockRequest.mock.calls.find((x) => x[1] === '/issue/HIMMEL-31/comment');
    expect(JSON.stringify(comment![2])).toContain('filled');
    expect(searches.join('\n')).toMatch(/class-shell-quoting.*area-cr-scripts/s);
  });

  it('a new residual is linked to its parent', async () => {
    play();
    await file(...RES, '--fu-class', 'polish');
    const link = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issueLink');
    expect(JSON.stringify(link![2])).toMatch(/HIMMEL-77.*HIMMEL-50|HIMMEL-50.*HIMMEL-77/s);
  });

  it('a failed parent link still names the created key and exits non-zero', async () => {
    play();
    const base = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (m: string, path: string, b?: unknown) => {
      if (path === '/issueLink') throw new Error('link boom');
      return base(m, path, b);
    });
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => {
      throw new Error('exit');
    }) as never);
    await expect(file(...RES, '--fu-class', 'polish')).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    const err = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0])).join('\n');
    expect(err).toMatch(/HIMMEL-77 but linking to HIMMEL-50 failed: link boom/);
    exit.mockRestore();
  });

  it('the duplicate search leaves out the parent itself', async () => {
    play();
    await file(...RES, ...HARD, '--area', 'cr scripts');
    expect(searches.find((j) => j.includes('area-'))).toMatch(/key != "?HIMMEL-50"?/);
  });

  it.each([0, 1, 2])('files a classless residual at parent depth %i without class labels or class-area deduplication', async (depth) => {
    play({ parentLabels: depth ? [`residual-depth-${depth}`] : [], dup: 'HIMMEL-31' });
    await file('--residual-of', 'HIMMEL-50', '--fu-class', 'escape', '--area', 'cr scripts',
      '--desc', `${PLAIN}\nclass: unclassified`);
    const f = created()!;
    expect(f['labels']).toEqual(['residual', 'fu-escape', 'area-cr-scripts', `residual-depth-${depth + 1}`]);
    expect(f['versions']).toEqual([{ name: 'v1.1.3' }]);
    expect(f['fixVersions']).toEqual(depth === 0 ? [{ name: 'v1.1.3' }] : undefined);
    expect(JSON.stringify(f['description'])).toContain('class: unclassified');
    expect(searches.some((q) => q.includes('area-'))).toBe(false);
  });

  it('refuses a missing --fu-class, an empty --class, an unknown fu-class, and an explicit --fix-version', async () => {
    play();
    await expect(file('--residual-of', 'HIMMEL-50', '--class', 'x')).rejects.toThrow(/--fu-class/);
    await expect(file('--residual-of', 'HIMMEL-50', '--fu-class', 'polish', '--class', '')).rejects.toThrow(/--class/);
    await expect(file(...RES, '--fu-class', 'nit')).rejects.toThrow(/polish, escape, hardening/);
    await expect(file(...RES, '--fu-class', 'polish', '--fix-version', 'v1.1.3')).rejects.toThrow(/--fix-version/);
    expect(created()).toBeUndefined();
  });
});

// The residual verb places each residual (plan 9.1 as corrected by 10.5) and
// stamps its class. The mock plays Jira: versions (v1.1.3 optionally frozen), a
// parent and a --blocks target with a status and a fixVersion.
describe('create --residual-of placement (HIMMEL-6919)', () => {
  type Ticket = { done?: boolean; version?: string };
  type Opts = { frozen?: boolean; nextFrozen?: boolean; noNext?: boolean; parentLabels?: string[]; parent?: Ticket; target?: Ticket; open?: number };
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const ENV = ['HANDOVER_DIR', 'HIMMEL_ADMISSIONS_LEDGER', 'HIMMEL_CONSOLE', 'HIMMEL_CONSOLE_NAME'];
  const issue = (t: Ticket = {}, labels: string[] = []) => ({
    fields: {
      labels,
      project: { key: 'HIMMEL' },
      status: { statusCategory: { key: t.done ? 'done' : 'indeterminate' } },
      fixVersions: t.version ? [{ name: t.version }] : [],
    },
  });
  const play = (o: Opts = {}) =>
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.endsWith('/versions')) {
        return [
          { name: 'v1.1.3', released: false, description: o.frozen ? 'frozen: 2026-10-20' : '' },
          ...(o.noNext ? [] : [{ name: 'v1.1.4', released: false, description: o.nextFrozen ? 'frozen: 2026-10-21' : '' }]),
        ];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) {
        return { issues: Array.from({ length: o.open ?? 0 }, (_, i) => ({ key: `HIMMEL-${900 + i}`,
          fields: { labels: ['residual', 'fu-hardening'], status: { name: 'In Progress', statusCategory: { key: 'indeterminate' } } } })) };
      }
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-50')) return issue(o.parent, o.parentLabels);
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-60')) return issue(o.target);
      return { key: 'HIMMEL-77' };
    });
  const file = async (...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 'r', '--desc', PLAIN, ...HOME,
      '--residual-of', 'HIMMEL-50', '--class', 'c', ...args]);
  };
  const created = () => {
    const c = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue');
    return c ? (c[2] as { fields: Record<string, unknown> }).fields : undefined;
  };
  const lands = () => (created()!['fixVersions'] as { name: string }[] | undefined)?.map((v) => v.name);
  const WHY = ['--fu-why', 'no-check'];
  const HARD = ['--fu-class', 'hardening', ...WHY];

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    for (const k of ENV) saved[k] = process.env[k];
    for (const k of ENV) delete process.env[k];
    dir = mkdtempSync(join(tmpdir(), 'placement-'));
    process.env['HANDOVER_DIR'] = dir;
  });
  afterEach(() => {
    for (const k of ENV) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    rmSync(dir, { recursive: true, force: true });
  });

  it('row a: depth 2 goes to the backlog even with a gate', async () => {
    play({ parentLabels: ['residual-depth-1'] });
    await file('--fu-class', 'escape', '--gate', 'receipt');
    expect(lands()).toBeUndefined();
  });

  it('row b: polish goes to the backlog even with a gate', async () => {
    play({ frozen: true });
    await file('--fu-class', 'polish', '--gate', 'receipt');
    expect(lands()).toBeUndefined();
  });

  it('row c: a gate files into the frozen current and records the admission', async () => {
    play({ frozen: true });
    await file(...HARD, '--gate', 'regression');
    expect(lands()).toEqual(['v1.1.3']);
    expect(readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8')).toContain('"gate":"regression"');
  });

  it('row d: an escape files into the unfrozen current', async () => {
    play();
    await file('--fu-class', 'escape');
    expect(lands()).toEqual(['v1.1.3']);
  });

  it('row d: an escape against the frozen current goes to next and does not throw', async () => {
    play({ frozen: true });
    await file('--fu-class', 'escape');
    expect(lands()).toEqual(['v1.1.4']);
    expect(created()!['versions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('row d: an escape goes to the backlog when next is frozen or missing', async () => {
    play({ frozen: true, nextFrozen: true });
    await file('--fu-class', 'escape');
    expect(lands()).toBeUndefined();
    vi.clearAllMocks();
    play({ frozen: true, noNext: true });
    await file('--fu-class', 'escape');
    expect(lands()).toBeUndefined();
  });

  it('row e: hardening whose open parent is in the unfrozen current files there', async () => {
    play({ parent: { version: 'v1.1.3' } });
    await file(...HARD);
    expect(lands()).toEqual(['v1.1.3']);
  });

  it('row e: hardening whose open parent is in the frozen current goes to next', async () => {
    play({ frozen: true, parent: { version: 'v1.1.3' } });
    await file(...HARD);
    expect(lands()).toEqual(['v1.1.4']);
  });

  it('row e: hardening that blocks an open ticket in an unfrozen version files into that version', async () => {
    play({ target: { version: 'v1.1.4' } });
    await file(...HARD, '--blocks', 'HIMMEL-60');
    expect(lands()).toEqual(['v1.1.4']);
  });

  it('row e: hardening that blocks an open ticket in the frozen current goes to next and does not throw', async () => {
    play({ frozen: true, target: { version: 'v1.1.3' } });
    await file(...HARD, '--blocks', 'HIMMEL-60');
    expect(lands()).toEqual(['v1.1.4']);
  });

  it('10.5 (2): a Done parent is no chain: hardening at Medium goes to the backlog, at High to next', async () => {
    play({ parent: { version: 'v1.1.3', done: true } });
    await file(...HARD);
    expect(lands()).toBeUndefined();
    vi.clearAllMocks();
    play({ parent: { version: 'v1.1.3', done: true } });
    await file(...HARD, '--priority', 'High');
    expect(lands()).toEqual(['v1.1.4']);
  });

  it.each(['High', 'Highest'])('row f: unchained hardening at %s goes to next', async (priority) => {
    play({ frozen: true });
    await file(...HARD, '--priority', priority);
    expect(lands()).toEqual(['v1.1.4']);
  });

  it('row g: unchained hardening at Medium goes to the backlog', async () => {
    play();
    await file(...HARD, '--priority', 'Medium');
    expect(lands()).toBeUndefined();
  });

  it('stamps fu-<class> on every residual and fu-why-<code> on hardening only', async () => {
    play();
    await file('--fu-class', 'polish');
    expect(created()!['labels']).toContain('fu-polish');
    expect(created()!['labels']).not.toEqual(expect.arrayContaining([expect.stringMatching(/^fu-why-/)]));
    vi.clearAllMocks();
    play();
    await file('--fu-class', 'hardening', '--fu-why', 'silent-rot');
    expect(created()!['labels']).toEqual(expect.arrayContaining(['fu-hardening', 'fu-why-silent-rot']));
  });

  it('refuses hardening without --fu-why, an unknown code, and --fu-why on another class, filing nothing', async () => {
    play();
    await expect(file('--fu-class', 'hardening')).rejects.toThrow(/--fu-why/);
    await expect(file('--fu-class', 'hardening', '--fu-why', 'nit')).rejects.toThrow(/unseen-failure/);
    await expect(file('--fu-class', 'escape', '--fu-why', 'no-check')).rejects.toThrow(/--fu-why/);
    expect(created()).toBeUndefined();
  });
});

describe('HIMMEL-6924 residual rank slots', () => {
  const residual = (key: string, labels = ['residual', 'fu-hardening'], status = 'To Do', priority = 'Medium') => ({
    key,
    fields: { labels, status: { name: status, statusCategory: { key: status === 'To Do' ? 'new' : status === 'Done' ? 'done' : 'indeterminate' } },
      project: { key: 'HIMMEL' }, priority: { name: priority }, created: '2026-10-01T00:00:00.000Z', fixVersions: [{ name: 'v1.1.3' }],
      issuelinks: [] as { type: { name: string }; outwardIssue?: { key: string }; inwardIssue?: { key: string } }[],
      customfield_rank: { value: 'Other' } },
  });
  let residents: ReturnType<typeof residual>[];
  let parent: ReturnType<typeof residual>;
  let frozen: boolean;
  let afterCreate: () => void;
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const env = ['HANDOVER_DIR', 'HIMMEL_ADMISSIONS_LEDGER', 'JIRA_SECTOR_FIELD'];
  const created = () => mockRequest.mock.calls.find((c) => c[0] === 'POST' && c[1] === '/issue')?.[2].fields;
  const file = async (...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 'ranked newcomer', '--desc', PLAIN,
      ...HOME, '--residual-of', 'HIMMEL-50', ...args]);
  };
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    for (const k of env) { saved[k] = process.env[k]; delete process.env[k]; }
    dir = mkdtempSync(join(tmpdir(), 'rank-slots-'));
    process.env.HANDOVER_DIR = dir;
    resetSectorCache();
    frozen = false;
    afterCreate = () => {};
    parent = residual('HIMMEL-50', [], 'In Progress');
    parent.fields.customfield_rank.value = 'Ship loop';
    residents = Array.from({ length: 15 }, (_, i) => residual(`HIMMEL-${900 + i}`));
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method !== 'GET') {
        if (method === 'POST' && path === '/issue') afterCreate();
        return { key: 'HIMMEL-77' };
      }
      if (path.endsWith('/versions')) return [
        { name: 'v1.1.3', released: false, description: frozen ? 'frozen: 2026-10-20' : '' },
        { name: 'v1.1.4', released: false },
      ];
      if (path.startsWith('/issue/HIMMEL-50')) return parent;
      if (path.includes('/context?')) return { values: [{ id: '1' }], isLast: true };
      if (path.includes('/option?')) return { values: [{ value: 'Ship loop' }, { value: 'Other' }], isLast: true };
      const found = residents.find((i) => path.startsWith(`/issue/${i.key}?`));
      if (found) return found;
      if (path.startsWith('/search/jql')) {
        const jql = new URLSearchParams(path.split('?')[1]).get('jql') ?? '';
        return { issues: jql.includes('labels = residual') ? residents : [parent, ...residents] };
      }
      throw new Error(`unexpected read ${path}`);
    });
  });
  afterEach(() => {
    for (const k of env) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    resetSectorCache();
    rmSync(dir, { recursive: true, force: true });
  });

  it('RED a: a higher-class newcomer displaces the lowest To Do residual at 15/15', async () => {
    await file('--fu-class', 'escape', '--priority', 'High');
    expect(created().fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-900', {
      fields: { fixVersions: [{ name: 'v1.1.4' }] }, update: { labels: [{ add: 'residual-displaced' }] },
    });
    const comment = mockRequest.mock.calls.find((c) => c[1] === '/issue/HIMMEL-900/comment');
    expect(JSON.stringify(comment?.[2])).toContain('HIMMEL-77');
    expect(created().labels).not.toContain('residual-displaced');
  });

  it.each(['critical', 'regression', 'must:decision-137', 'receipt'])('RED a: gate %s beats class and priority and is persisted', async (gate) => {
    residents = residents.map((r) => residual(r.key, ['residual', 'fu-escape'], 'To Do', 'Highest'));
    await file('--fu-class', 'hardening', '--fu-why', 'no-check', '--gate', gate, '--priority', 'Lowest');
    expect(created().labels).toContain(`gate-${gate.split(':')[0]}`);
    expect(mockRequest.mock.calls.find((c) => c[0] === 'PUT')?.[1]).toBe('/issue/HIMMEL-900');
  });

  it.each(['class', 'priority', 'chain', 'sector'])('RED a: rank key %s beats older creation time', async (key) => {
    residents = residents.map((r) => residual(r.key, key === 'class' ? ['residual'] : ['residual', 'fu-escape'],
      'To Do', key === 'priority' ? 'Low' : 'Medium'));
    if (key === 'sector') {
      process.env.JIRA_SECTOR_FIELD = 'customfield_rank';
      for (const r of residents) r.fields.issuelinks.push({ type: { name: 'Relates' }, outwardIssue: { key: parent.key } });
    }
    await file('--fu-class', 'escape', ...(key === 'sector' ? ['--sector', 'ship loop'] : []));
    expect(mockRequest.mock.calls.find((c) => c[0] === 'PUT')?.[1]).toBe('/issue/HIMMEL-900');
    if (key === 'sector') {
      const query = mockRequest.mock.calls.find((c) => c[1].includes('/search/jql'))?.[1];
      expect(new URLSearchParams(query.split('?')[1]).get('fields')).toContain('customfield_rank');
    }
  });

  it.each(['gate-label', 'legacy-gate', 'started', 'older'])('RED b: %s residents cannot be displaced', async (kind) => {
    residents = residents.map((r) => residual(r.key,
      ['residual', 'fu-escape', ...(kind === 'gate-label' ? ['gate-receipt'] : [])],
      kind === 'started' ? 'In Progress' : 'To Do'));
    parent.fields.status.statusCategory.key = 'done';
    if (kind === 'legacy-gate') writeFileSync(join(dir, 'admissions-ledger.jsonl'), residents.map((r) =>
      JSON.stringify({ key: r.key, version: 'v1.1.3', gate: 'receipt' })).join('\n'));
    await file('--fu-class', 'escape', ...(kind === 'older' ? [] : ['--priority', 'Highest']));
    expect(created().fixVersions).toEqual([{ name: 'v1.1.4' }]);
    expect(created().labels).toContain('residual-displaced');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('RED a: the lowest rank is selected from the whole resident set, not its first 15 keys', async () => {
    residents = Array.from({ length: 16 }, (_, i) => residual(`HIMMEL-${900 + i}`, ['residual', 'fu-escape'], 'To Do', 'Highest'));
    residents[15] = residual('HIMMEL-915');
    await file('--fu-class', 'escape');
    expect(mockRequest.mock.calls.find((c) => c[0] === 'PUT')?.[1]).toBe('/issue/HIMMEL-915');
  });

  it('RED a: displacement from next clears the version instead of going to a third version', async () => {
    frozen = true;
    for (const r of residents) r.fields.fixVersions = [{ name: 'v1.1.4' }];
    await file('--fu-class', 'escape');
    expect(created().fixVersions).toEqual([{ name: 'v1.1.4' }]);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-900', {
      fields: { fixVersions: [] }, update: { labels: [{ add: 'residual-displaced' }] },
    });
  });

  it('RED a: displacement preserves unrelated fixVersion assignments', async () => {
    residents[0].fields.fixVersions.push({ name: 'v9.0.0' });
    await file('--fu-class', 'escape');
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-900', {
      fields: { fixVersions: [{ name: 'v9.0.0' }, { name: 'v1.1.4' }] },
      update: { labels: [{ add: 'residual-displaced' }] },
    });
  });

  it.each(['started', 'gated', 'legacy-gated', 'already-displaced'])('RED b: a resident %s after creation is unavailable and the newcomer steps down', async (change) => {
    afterCreate = () => {
      if (change === 'started') residents[0].fields.status.name = 'In Progress';
      else if (change === 'gated') residents[0].fields.labels.push('gate-receipt');
      else if (change === 'already-displaced') residents[0].fields.fixVersions = [{ name: 'v1.1.4' }];
      else writeFileSync(join(dir, 'admissions-ledger.jsonl'),
        JSON.stringify({ key: residents[0].key, version: 'v1.1.3', gate: 'receipt' }) + '\n');
    };
    await file('--fu-class', 'escape');
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-77', {
      fields: { fixVersions: [{ name: 'v1.1.4' }] }, update: { labels: [{ add: 'residual-displaced' }] },
    });
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT' && c[1] === '/issue/HIMMEL-900')).toBe(false);
  });

  it.each(['--blocks', '--split-from'])('RED b: %s inheritance does not put a competed newcomer back into the full version', async (relation) => {
    residents = residents.map((r) => residual(r.key, ['residual', 'fu-escape']));
    await file('--fu-class', 'hardening', '--fu-why', 'no-check', relation, 'HIMMEL-50');
    expect(created().fixVersions).toEqual([{ name: 'v1.1.4' }]);
    expect(created().labels).toContain('residual-displaced');
    expect(console.error).toHaveBeenCalledWith('jira: residual routed to v1.1.4');
  });

  it.each(['high', 'hIgHeSt'])('RED a: newcomer priority %s outranks Medium case-insensitively', async (priority) => {
    residents = residents.map((r) => residual(r.key, ['residual', 'fu-escape']));
    for (const r of residents) r.fields.issuelinks.push({ type: { name: 'Relates' }, outwardIssue: { key: parent.key } });
    await file('--fu-class', 'escape', '--priority', priority);
    expect(created().fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIMMEL-900', {
      fields: { fixVersions: [{ name: 'v1.1.4' }] }, update: { labels: [{ add: 'residual-displaced' }] },
    });
  });

  it('RED b: higher-ranked and started residents keep their slots; newcomer steps down labelled', async () => {
    residents = residents.map((r, i) => residual(r.key, ['residual', 'fu-escape'], i % 2 ? 'In Progress' : 'To Do', 'Highest'));
    await file('--fu-class', 'hardening', '--fu-why', 'no-check', '--priority', 'Medium');
    expect(created().fixVersions).toEqual([{ name: 'v1.1.4' }]);
    expect(created().labels).toContain('residual-displaced');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });
});

// Filing into the current unreleased version at the cap warns and labels
// over-cap; an operator-directed ticket is exempt. The mock plays Jira: a version list and
// a search whose hit count is the open residuals in the current version.
describe('create — cap gate (HIMMEL-6485)', () => {
  type Opts = { open?: number; budgetDesc?: string; noNext?: boolean; searchFails?: boolean };
  let searches: string[];
  const play = (o: Opts = {}) => {
    searches = [];
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.endsWith('/versions')) {
        return [
          { name: 'v1.1.2', released: true },
          { name: 'v1.1.3', released: false, description: o.budgetDesc },
          ...(o.noNext ? [] : [{ name: 'v1.1.4', released: false }]),
        ];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) {
        if (o.searchFails) throw new Error('search boom');
        searches.push(decodeURIComponent(path));
        return { issues: Array.from({ length: o.open ?? 0 }, (_, i) => ({ key: `HIMMEL-${900 + i}`,
          fields: { labels: ['residual', 'fu-hardening'], status: { name: 'In Progress', statusCategory: { key: 'indeterminate' } } } })) };
      }
      return { key: 'HIMMEL-77' };
    });
  };
  const file = async (...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 'g', '--desc', PLAIN, ...HOME, ...args]);
  };
  const created = () => {
    const c = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue');
    return c ? (c[2] as { fields: Record<string, unknown> }).fields : undefined;
  };
  const exitSpy = () =>
    vi.spyOn(process, 'exit').mockImplementation((() => {
      throw new Error('exit');
    }) as never);
  const stderr = () => (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0])).join('\n');

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('RED c: raw Task at 15/15 warns, labels over-cap and files without an override', async () => {
    play({ open: 15 });
    const exit = exitSpy();
    try {
      await file('--fix-version', 'v1.1.3');
      expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
      expect(created()!['labels']).toContain('over-cap');
      expect(stderr()).toMatch(/warning.*v1\.1\.3.*15\/15/s);
      expect(exit).not.toHaveBeenCalled();
    } finally {
      exit.mockRestore();
    }
  });

  it('counts only open residuals in the current version', async () => {
    play({ open: 3 });
    await file('--fix-version', 'v1.1.3');
    expect(searches[0]).toMatch(/fixVersion = "v1\.1\.3".*labels = residual.*statusCategory != Done/s);
  });

  it('files under the cap', async () => {
    play({ open: 14 });
    await file('--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('a residual-budget line in the version description moves the cap', async () => {
    play({ open: 3, budgetDesc: 'residual-budget:3' });
    await file('--fix-version', 'v1.1.3');
    expect(created()!['labels']).toContain('over-cap');
    expect(stderr()).toMatch(/warning.*3\/3/s);
  });

  it('files at the cap with --over-cap, labels it and records the reason', async () => {
    play({ open: 15 });
    await file('--fix-version', 'v1.1.3', '--over-cap', 'blocks the v1 gate');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(created()!['labels']).toContain('over-cap');
    const comment = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue/HIMMEL-77/comment');
    expect(JSON.stringify(comment![2])).toContain('blocks the v1 gate');
  });

  it('an operator-directed ticket is not refused at the cap', async () => {
    play({ open: 15 });
    await file('--fix-version', 'v1.1.3', '--labels', 'operator-directed');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(created()!['labels']).not.toContain('over-cap');
  });

  it('a filing into a later version is not gated', async () => {
    play({ open: 15 });
    await file('--fix-version', 'v1.1.4');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
    expect(searches).toEqual([]);
  });

  it('a versionless Bug over the cap gets the next version, and says so', async () => {
    play({ open: 15 });
    await file('--type', 'Bug', '--priority', 'Highest');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
    expect(stderr()).toMatch(/over its cap.*v1\.1\.4/s);
    expect(stderr()).not.toMatch(/earliest unreleased|defaults to fixVersion/);
  });

  it('a versionless Bug over the cap with no next version files with no fixVersion', async () => {
    play({ open: 15, noNext: true });
    await file('--type', 'Bug', '--priority', 'Highest');
    expect(created()!['fixVersions']).toBeUndefined();
    expect(stderr()).not.toMatch(/no unreleased version found/);
  });

  it('a versionless Bug under the cap still defaults to the current version', async () => {
    play({ open: 2 });
    await file('--type', 'Bug', '--priority', 'Highest');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('a Bug --over-cap defaults to the current version past the cap', async () => {
    play({ open: 15 });
    await file('--type', 'Bug', '--priority', 'Highest', '--over-cap', 'release blocker');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(created()!['labels']).toContain('over-cap');
  });

  it('files unguarded, with a warning, when the open count cannot be read', async () => {
    play({ searchFails: true });
    await file('--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(stderr()).toMatch(/cap check skipped/);
  });

  it('--follow-up-of stamps the residual label and links the parent', async () => {
    play({ open: 0 });
    await file('--follow-up-of', 'HIMMEL-50', '--labels', 'standalone');
    expect(created()!['labels']).toEqual(expect.arrayContaining(['residual', 'standalone']));
    const link = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issueLink');
    expect(JSON.stringify(link![2])).toMatch(/HIMMEL-77.*HIMMEL-50/s);
  });

  it('RED c: --follow-up-of into the current version at the cap warns like any raw filing', async () => {
    play({ open: 15 });
    await file('--follow-up-of', 'HIMMEL-50', '--fix-version', 'v1.1.3');
    expect(created()!['labels']).toEqual(expect.arrayContaining(['residual', 'over-cap']));
    expect(stderr()).toMatch(/warning.*15\/15/s);
  });

  it('--follow-up-of cannot be combined with --residual-of', async () => {
    play();
    await expect(file('--follow-up-of', 'HIMMEL-50', '--residual-of', 'HIMMEL-50')).rejects.toThrow(/--residual-of/);
  });
});

// A Bug is placed at filing: backlog, or the active version for a Highest or
// gated one; the console can overrule with a reason that lands in the ledger.
describe('create — Bug placement (HIMMEL-6776)', () => {
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const ENV = ['HANDOVER_DIR', 'HIMMEL_ADMISSIONS_LEDGER', 'HIMMEL_CONSOLE', 'HIMMEL_CONSOLE_NAME'];

  const play = () =>
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.endsWith('/versions')) {
        return [
          { name: 'v1.1.2', released: true },
          { name: 'v1.1.3', released: false },
        ];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) return { issues: [] };
      return { key: 'HIMMEL-77' };
    });
  const file = async (...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Bug', '--title', 'b', '--desc', PLAIN, ...HOME, ...args]);
  };
  const created = () => {
    const c = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue');
    return c ? (c[2] as { fields: Record<string, unknown> }).fields : undefined;
  };
  const ledger = () => {
    try {
      return readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    } catch {
      return [];
    }
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    for (const k of ENV) saved[k] = process.env[k];
    for (const k of ENV) delete process.env[k];
    dir = mkdtempSync(join(tmpdir(), 'admissions-'));
    process.env['HANDOVER_DIR'] = dir;
    play();
  });
  afterEach(() => {
    for (const k of ENV) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    rmSync(dir, { recursive: true, force: true });
  });

  it('refuses a Bug with no placement, naming both choices and the sector hint, without POSTing', async () => {
    await expect(file()).rejects.toThrow(/Ship loop.*--backlog.*--fix-version/s);
    expect(created()).toBeUndefined();
  });

  it('files a --backlog Bug with the backlog label and no fixVersion', async () => {
    await file('--backlog');
    expect(created()!['fixVersions']).toBeUndefined();
    expect(created()!['labels']).toContain('backlog');
  });

  it('puts a Highest Bug in the earliest unreleased version', async () => {
    await file('--priority', 'Highest');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(created()!['priority']).toEqual({ name: 'Highest' });
    expect(created()!['labels'] ?? []).not.toContain('backlog');
  });

  it.each(['critical', 'regression'])('puts a --gate %s Bug in the earliest unreleased version', async (gate) => {
    await file('--gate', gate);
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('refuses an unknown --gate', async () => {
    await expect(file('--gate', 'urgent')).rejects.toThrow(/--gate/);
    expect(created()).toBeUndefined();
  });

  it('refuses --backlog together with a gate or a --fix-version', async () => {
    await expect(file('--backlog', '--gate', 'critical')).rejects.toThrow(/--backlog/);
    await expect(file('--backlog', '--fix-version', 'v1.1.3')).rejects.toThrow(/--backlog/);
    expect(created()).toBeUndefined();
  });

  it('still files a Medium Bug with an explicit --fix-version', async () => {
    await file('--priority', 'Medium', '--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(ledger()).toEqual([]);
  });

  it('does not touch a Task', async () => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 't', '--desc', PLAIN, ...HOME]);
    expect(created()!['fixVersions']).toBeUndefined();
    expect(created()!['labels']).toBeUndefined();
  });

  it('lets the console put a Medium Bug into a version, and records the reason in the ledger', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    await file('--priority', 'Medium', '--fix-version', 'v1.1.3', '--console-override', 'blocks the v1 gate');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    const [row] = ledger();
    expect(row).toMatchObject({ key: 'HIMMEL-77', version: 'v1.1.3', kind: 'override', reason: 'blocks the v1 gate' });
    expect(row.ts).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(typeof row.actor).toBe('string');
  });

  it('refuses the override without a reason', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    await expect(file('--fix-version', 'v1.1.3', '--console-override', '  ')).rejects.toThrow(/reason/);
    expect(created()).toBeUndefined();
  });

  it('refuses the override without the console marker', async () => {
    await expect(file('--fix-version', 'v1.1.3', '--console-override', 'because')).rejects.toThrow(/console/);
    expect(created()).toBeUndefined();
    expect(ledger()).toEqual([]);
  });

  it('refuses the override when there is no ledger location, rather than writing elsewhere', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    process.env['HANDOVER_DIR'] = join(dir, 'missing');
    await expect(file('--fix-version', 'v1.1.3', '--console-override', 'because')).rejects.toThrow(/HANDOVER_DIR/);
    expect(created()).toBeUndefined();
  });

  it('refuses the override without a --fix-version to admit into', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    await expect(file('--console-override', 'because')).rejects.toThrow(/--fix-version/);
    expect(created()).toBeUndefined();
  });

  it('refuses the override when the ledger is readable but not writable, before any ticket is created', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    const path = join(dir, 'admissions-ledger.jsonl');
    writeFileSync(path, '');
    chmodSync(path, 0o444);
    try {
      if (process.getuid?.() === 0) return;
      await expect(file('--fix-version', 'v1.1.3', '--console-override', 'because')).rejects.toThrow();
      expect(created()).toBeUndefined();
    } finally {
      chmodSync(path, 0o644);
    }
  });

  it('refuses the override when the ledger location cannot be opened for append, before any ticket is created', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = dir;
    await expect(file('--fix-version', 'v1.1.3', '--console-override', 'because')).rejects.toThrow();
    expect(created()).toBeUndefined();
  });
});

describe('create — intake gate for a frozen version (HIMMEL-6775)', () => {
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const ENV = ['HANDOVER_DIR', 'HIMMEL_ADMISSIONS_LEDGER', 'HIMMEL_CONSOLE', 'HIMMEL_CONSOLE_NAME'];

  const play = (description?: string) =>
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.endsWith('/versions')) {
        return [
          { name: 'v1.1.2', released: true },
          { name: 'v1.1.3', released: false, description },
        ];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) return { issues: [] };
      if (method === 'GET' && path.startsWith('/issue/')) return { fields: { labels: [] } };
      return { key: 'HIMMEL-77' };
    });
  const file = async (type: string, ...args: string[]) => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', type, '--title', 't', '--desc', PLAIN, ...HOME, ...args]);
  };
  const created = () => {
    const c = mockRequest.mock.calls.find((x) => x[0] === 'POST' && x[1] === '/issue');
    return c ? (c[2] as { fields: Record<string, unknown> }).fields : undefined;
  };
  const ledger = () => {
    try {
      return readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    } catch {
      return [];
    }
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    for (const k of ENV) saved[k] = process.env[k];
    for (const k of ENV) delete process.env[k];
    dir = mkdtempSync(join(tmpdir(), 'admissions-'));
    process.env['HANDOVER_DIR'] = dir;
    play('Release train.\nfrozen: 2026-10-20');
  });
  afterEach(() => {
    for (const k of ENV) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    rmSync(dir, { recursive: true, force: true });
  });

  it('refuses a Task into a frozen version with no gate, naming the gates, without POSTing', async () => {
    await expect(file('Task', '--fix-version', 'v1.1.3')).rejects.toThrow(/v1\.1\.3 is frozen.*--gate critical\|regression\|must:/s);
    expect(created()).toBeUndefined();
    expect(ledger()).toEqual([]);
  });

  it('admits a Task with --gate must:98 and writes a ledger row', async () => {
    await file('Task', '--fix-version', 'v1.1.3', '--gate', 'must:98');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    const [row] = ledger();
    expect(row).toMatchObject({ key: 'HIMMEL-77', version: 'v1.1.3', gate: 'must:98' });
    expect(row.kind).toBeUndefined();
    expect(row.ts).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it.each(['critical', 'regression', 'receipt'])('admits a Task with --gate %s', async (gate) => {
    await file('Task', '--fix-version', 'v1.1.3', '--gate', gate);
    expect(ledger()).toMatchObject([{ key: 'HIMMEL-77', version: 'v1.1.3', gate }]);
  });

  it.each(['must:', 'must:  ', 'urgent'])('refuses the malformed gate "%s"', async (gate) => {
    await expect(file('Task', '--fix-version', 'v1.1.3', '--gate', gate)).rejects.toThrow(/--gate/);
    expect(created()).toBeUndefined();
  });

  it('files a --backlog Bug on a frozen version with no gate and no row', async () => {
    await file('Bug', '--backlog');
    expect(created()!['fixVersions']).toBeUndefined();
    expect(created()!['labels']).toContain('backlog');
    expect(ledger()).toEqual([]);
  });

  it('holds a Highest Bug, whose default is the frozen version, to the gate', async () => {
    await expect(file('Bug', '--priority', 'Highest')).rejects.toThrow(/frozen/);
    expect(created()).toBeUndefined();
    await file('Bug', '--priority', 'Highest', '--gate', 'critical');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(ledger()).toMatchObject([{ version: 'v1.1.3', gate: 'critical' }]);
  });

  it('sends an ungated escape residual past the frozen version, and admits it only with a gate', async () => {
    const residual = ['--residual-of', 'HIMMEL-1', '--fu-class', 'escape', '--class', 'c'];
    await file('Task', ...residual);
    expect(created()!['fixVersions']).toBeUndefined();
    expect(ledger()).toEqual([]);
    vi.clearAllMocks();
    play('Release train.\nfrozen: 2026-10-20');
    await file('Task', ...residual, '--gate', 'receipt');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(ledger()).toMatchObject([{ version: 'v1.1.3', gate: 'receipt' }]);
  });

  it('lets the console past the gate with a reason, and writes an override row carrying it', async () => {
    process.env['HIMMEL_CONSOLE'] = '1';
    await file('Bug', '--fix-version', 'v1.1.3', '--console-override', 'blocks the v1 gate');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(ledger()).toMatchObject([{ key: 'HIMMEL-77', version: 'v1.1.3', kind: 'override', reason: 'blocks the v1 gate' }]);
  });

  it('refuses the override on a frozen version without a reason or without the console marker', async () => {
    await expect(file('Task', '--fix-version', 'v1.1.3', '--console-override', 'because')).rejects.toThrow(/console/);
    process.env['HIMMEL_CONSOLE'] = '1';
    await expect(file('Task', '--fix-version', 'v1.1.3', '--console-override', ' ')).rejects.toThrow(/reason/);
    expect(created()).toBeUndefined();
    expect(ledger()).toEqual([]);
  });

  it('refuses a gated filing when the ledger cannot take the row, before any ticket is created', async () => {
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = dir;
    await expect(file('Task', '--fix-version', 'v1.1.3', '--gate', 'must:98')).rejects.toThrow();
    expect(created()).toBeUndefined();
  });

  it('behaves as before on a version without a frozen: line', async () => {
    play('Release train.');
    await file('Task', '--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    await file('Task', '--fix-version', 'v1.1.3', '--gate', 'must:98');
    expect(ledger()).toEqual([]);
  });

  it('ignores a frozen: line that is not on a line of its own', async () => {
    play('not yet frozen: 2026-10-20');
    await file('Task', '--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('reads a frozen: line from a CRLF description', async () => {
    play('Release train.\r\nfrozen: 2026-10-20\r\n');
    await expect(file('Task', '--fix-version', 'v1.1.3')).rejects.toThrow(/frozen \(2026-10-20\)/);
  });

  it('ignores a frozen: marker whose date is on the next line', async () => {
    play('Release train.\nfrozen:\nnotes');
    await file('Task', '--fix-version', 'v1.1.3');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });
});

describe('create — blocker version placement', () => {
  let frozen: boolean;
  let full: boolean;
  let targetVersions: { name: string }[];

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((code: number) => { throw new Error(`exit ${code}`); }) as never);
    frozen = false;
    full = false;
    targetVersions = [{ name: 'v1.1.3' }];
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/project/')) return [
        { id: '113', name: 'v1.1.3', released: false, description: frozen ? 'frozen: 2026-10-20' : '' },
        { id: '114', name: 'v1.1.4', released: false },
      ];
      if (method === 'GET' && path.startsWith('/issue/')) return { fields: {
        project: { key: 'HIMMEL' }, fixVersions: targetVersions, status: { statusCategory: { key: 'new' } },
      } };
      if (method === 'GET' && path.startsWith('/search/')) return { issues: full ? Array(15).fill({ key: 'HIMMEL-10' }) : [] };
      if (method === 'POST' && path === '/issue') return { key: 'HIMMEL-6559' };
      return {};
    });
  });

  afterEach(() => vi.restoreAllMocks());

  const file = (...args: string[]) => {
    const p = new Command().exitOverride();
    registerCreate(p);
    return p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--title', 'Blocker', '--desc', PLAIN, '--labels', 'standalone', ...args]);
  };
  const created = () => (mockRequest.mock.calls.find(([m, p]) => m === 'POST' && p === '/issue')?.[2] as { fields: Record<string, unknown> } | undefined)?.fields;
  const writes = () => mockRequest.mock.calls.filter(([m]) => m !== 'GET');

  it.each(['HIMMEL-6575', 'HIMMEL-6582', 'HIMMEL-1620'])('inherits the version when creating a blocker of %s', async (target) => {
    await file('--blocks', target);
    expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Blocks' }, inwardIssue: { key: 'HIMMEL-6559' }, outwardIssue: { key: target },
    });
  });

  it('handles both 6559 dependents in one filing', async () => {
    await file('--blocks', 'HIMMEL-6575', '--blocks', 'HIMMEL-6582');
    expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(writes().filter(([, path]) => path === '/issueLink')).toHaveLength(2);
  });

  it('inherits on --split-from and records the source with a Relates link', async () => {
    await file('--split-from', 'HIMMEL-1620');
    expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Relates' }, inwardIssue: { key: 'HIMMEL-6559' }, outwardIssue: { key: 'HIMMEL-1620' },
    });
  });

  it('allows --backlog explicitly, labelling the Task without stamping a version', async () => {
    await file('--blocks', 'HIMMEL-1620', '--backlog');
    expect(created()?.fixVersions).toBeUndefined();
    expect(created()?.labels).toContain('backlog');
  });

  it('refuses an explicit version that omits the current dependent version', async () => {
    await expect(file('--blocks', 'HIMMEL-1620', '--fix-version', 'v1.1.4')).rejects.toThrow(/v1\.1\.3/);
    expect(writes()).toEqual([]);
  });

  it('does not bypass frozen-version admission through inheritance', async () => {
    frozen = true;
    await expect(file('--blocks', 'HIMMEL-1620')).rejects.toThrow(/frozen/);
    expect(writes()).toEqual([]);
  });

  it('inherits a frozen version only with --gate must:<ruling>, recording the admission', async () => {
    frozen = true;
    const dir = mkdtempSync(join(tmpdir(), 'inherit-gate-'));
    const prior = process.env['HIMMEL_ADMISSIONS_LEDGER'];
    process.env['HIMMEL_ADMISSIONS_LEDGER'] = join(dir, 'admissions-ledger.jsonl');
    try {
      await file('--blocks', 'HIMMEL-1620', '--gate', 'must:RULING-1');
      expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
      expect(readFileSync(join(dir, 'admissions-ledger.jsonl'), 'utf8')).toContain('"gate":"must:RULING-1"');
    } finally {
      if (prior === undefined) delete process.env['HIMMEL_ADMISSIONS_LEDGER'];
      else process.env['HIMMEL_ADMISSIONS_LEDGER'] = prior;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('files a blocker of a frozen-version ticket with --backlog and no gate', async () => {
    frozen = true;
    await file('--blocks', 'HIMMEL-1620', '--backlog');
    expect(created()?.fixVersions).toBeUndefined();
    expect(created()?.labels).toContain('backlog');
  });

  it('RED c: inherited raw placement warns and labels over-cap instead of refusing', async () => {
    full = true;
    await file('--blocks', 'HIMMEL-1620');
    expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(created()?.labels).toContain('over-cap');
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning:.*15\/15.*over-cap/));
    const comment = writes().find(([, path]) => path === '/issue/HIMMEL-6559/comment');
    expect(JSON.stringify(comment?.[2])).toContain('raw create; cap is a warning');
  });

  it('does not copy a future version from a non-current target', async () => {
    targetVersions = [{ name: 'v1.1.4' }];
    await file('--blocks', 'HIMMEL-1620');
    expect(created()?.fixVersions).toBeUndefined();
  });

  it('create --blocked-by records the existing blocker as inward, not the new issue', async () => {
    await file('--blocked-by', 'HIMMEL-1158', '--fix-version', 'v1.1.3');
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Blocks' }, inwardIssue: { key: 'HIMMEL-1158' }, outwardIssue: { key: 'HIMMEL-6559' },
    });
  });

  it('create --blocked-by refuses a versionless existing blocker before creating its dependent', async () => {
    targetVersions = [];
    await expect(file('--blocked-by', 'HIMMEL-1158', '--fix-version', 'v1.1.3')).rejects.toThrow(/v1\.1\.3.*--backlog/);
    expect(writes()).toEqual([]);
  });

  it('create --blocked-by does not inherit from the blocker in the opposite direction', async () => {
    await file('--blocked-by', 'HIMMEL-1158');
    expect(created()?.fixVersions).toBeUndefined();
  });

  it('refuses a versionless split when its source cannot be read', async () => {
    mockRequest.mockImplementation(async () => { throw new Error('Jira unavailable'); });
    await expect(file('--split-from', 'HIMMEL-1620')).rejects.toThrow(/Jira unavailable/);
    expect(writes()).toEqual([]);
  });

  it.each(['--blocks', '--split-from'])('reports the inherited residual destination for %s', async (relation) => {
    await file('--residual-of', 'HIMMEL-3', '--fu-class', 'polish', '--class', 'routing', relation, 'HIMMEL-1620');
    expect(created()?.fixVersions).toEqual([{ name: 'v1.1.3' }]);
    expect(console.error).toHaveBeenCalledWith('jira: residual routed to v1.1.3');
    expect(console.error).not.toHaveBeenCalledWith('jira: residual routed to the backlog');
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: relation === '--blocks' ? 'Blocks' : 'Relates' },
      inwardIssue: { key: 'HIMMEL-6559' }, outwardIssue: { key: 'HIMMEL-1620' },
    });
  });
});
