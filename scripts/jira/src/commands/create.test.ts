import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';

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
    await createFields(['--type', 'Bug']);
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
    await createFields(['--type', 'Bug']);
    expect(postedFields().fixVersions).toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/no unreleased version.*no fixVersion/));
  });

  it('files with no fixVersion and a warning when the versions cannot be read', async () => {
    mockRequest.mockImplementation(async (method: string) => {
      if (method === 'GET') throw new Error('boom');
      return { key: 'HIMMEL-1' };
    });
    await createFields(['--type', 'Bug']);
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
  type Opts = { parentLabels?: string[]; open?: number; budgetDesc?: string; dup?: string; noVersion?: boolean };
  let searches: string[];
  const play = (o: Opts = {}) => {
    searches = [];
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-50')) return { fields: { labels: o.parentLabels ?? [] } };
      if (method === 'GET' && path.endsWith('/versions')) {
        return o.noVersion
          ? []
          : [{ name: 'v1.1.3', released: false, description: o.budgetDesc }, { name: 'v1.1.4', released: false }];
      }
      if (method === 'GET' && path.startsWith('/search/jql')) {
        const jql = decodeURIComponent(path);
        searches.push(jql);
        if (jql.includes('area-')) return { issues: o.dup ? [{ key: o.dup }] : [] };
        return { issues: Array.from({ length: o.open ?? 0 }, (_, i) => ({ key: `HIMMEL-${900 + i}` })) };
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
    expect(f['labels']).not.toContain('residual-overflow');
  });

  it('escape goes to the current version even with the version full, and stamps affectsVersion', async () => {
    play({ open: 40 });
    await file(...RES, '--fu-class', 'escape');
    const f = created()!;
    expect(f['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
    expect(f['versions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('hardening under the budget lands in the current version', async () => {
    play({ open: 14 });
    await file(...RES, '--fu-class', 'hardening');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('hardening at 15/15 goes to the backlog with residual-overflow', async () => {
    play({ open: 15 });
    await file(...RES, '--fu-class', 'hardening');
    const f = created()!;
    expect(f['fixVersions']).toBeUndefined();
    expect(f['labels']).toContain('residual-overflow');
  });

  it('a residual-budget:N line in the version description overrides the default', async () => {
    play({ open: 3, budgetDesc: 'sprint goal\nresidual-budget:3' });
    await file(...RES, '--fu-class', 'hardening');
    expect(created()!['fixVersions']).toBeUndefined();
    expect(created()!['labels']).toContain('residual-overflow');
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
    await file(...RES, '--fu-class', 'hardening', '--area', 'cr scripts');
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
    await file(...RES, '--fu-class', 'hardening', '--area', 'cr scripts');
    expect(searches.find((j) => j.includes('area-'))).toMatch(/key != "?HIMMEL-50"?/);
  });

  it('refuses a missing --fu-class or --class, an unknown fu-class, and an explicit --fix-version', async () => {
    play();
    await expect(file('--residual-of', 'HIMMEL-50', '--class', 'x')).rejects.toThrow(/--fu-class/);
    await expect(file('--residual-of', 'HIMMEL-50', '--fu-class', 'polish')).rejects.toThrow(/--class/);
    await expect(file(...RES, '--fu-class', 'nit')).rejects.toThrow(/polish, escape, hardening/);
    await expect(file(...RES, '--fu-class', 'polish', '--fix-version', 'v1.1.3')).rejects.toThrow(/--fix-version/);
    expect(created()).toBeUndefined();
  });
});

// The cap gate: filing into the current unreleased version is
// refused at the residual cap unless --over-cap <reason> is given; an
// operator-directed ticket is exempt. The mock plays Jira: a version list and
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
        return { issues: Array.from({ length: o.open ?? 0 }, (_, i) => ({ key: `HIMMEL-${900 + i}` })) };
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

  it('refuses a filing into the current version at the cap, without POSTing', async () => {
    play({ open: 15 });
    const exit = exitSpy();
    await expect(file('--fix-version', 'v1.1.3')).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(stderr()).toMatch(/v1\.1\.3.*15\/15.*--over-cap/s);
    expect(created()).toBeUndefined();
    exit.mockRestore();
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
    const exit = exitSpy();
    await expect(file('--fix-version', 'v1.1.3')).rejects.toThrow('exit');
    exit.mockRestore();
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
    await file('--type', 'Bug');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.4' }]);
    expect(stderr()).toMatch(/over its cap.*v1\.1\.4/s);
    expect(stderr()).not.toMatch(/earliest unreleased|defaults to fixVersion/);
  });

  it('a versionless Bug over the cap with no next version files with no fixVersion', async () => {
    play({ open: 15, noNext: true });
    await file('--type', 'Bug');
    expect(created()!['fixVersions']).toBeUndefined();
    expect(stderr()).not.toMatch(/no unreleased version found/);
  });

  it('a versionless Bug under the cap still defaults to the current version', async () => {
    play({ open: 2 });
    await file('--type', 'Bug');
    expect(created()!['fixVersions']).toEqual([{ name: 'v1.1.3' }]);
  });

  it('a Bug --over-cap defaults to the current version past the cap', async () => {
    play({ open: 15 });
    await file('--type', 'Bug', '--over-cap', 'release blocker');
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

  it('--follow-up-of into the current version at the cap is gated like any filing', async () => {
    play({ open: 15 });
    const exit = exitSpy();
    await expect(file('--follow-up-of', 'HIMMEL-50', '--fix-version', 'v1.1.3')).rejects.toThrow('exit');
    expect(created()).toBeUndefined();
    exit.mockRestore();
  });

  it('--follow-up-of cannot be combined with --residual-of', async () => {
    play();
    await expect(file('--follow-up-of', 'HIMMEL-50', '--residual-of', 'HIMMEL-50')).rejects.toThrow(/--residual-of/);
  });
});
