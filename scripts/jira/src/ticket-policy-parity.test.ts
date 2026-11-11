import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

vi.mock('./client.js', async (orig) => ({
  ...(await orig<typeof import('./client.js')>()),
  request: vi.fn(),
  projectKey: () => 'HIMMEL',
}));
vi.mock('./breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from './client.js';
import { markdownToAdf } from './adf.js';
import { lintPlainBlock, lintPlainBlockAdf } from './plain-block.js';
import { registerCreate } from './commands/create.js';
import { registerEdit } from './commands/edit.js';
import { registerMove } from './commands/move.js';
import { registerTransition } from './commands/transition.js';
import { registerRelease } from './commands/release.js';
import { createTools, type ToolDeps } from './mcp.js';
import { releaseRoot } from './release/paths.js';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..', '..');
const checker = join(repo, 'marketplace', 'plugins', 'himmel-ops', 'scripts', 'ticket-standard-check.sh');

type Case = {
  id: string; type: string; labels?: string[]; omit?: string[]; replace?: Record<string, string>;
  bold?: string[]; plain?: string[]; append?: string; expect: string[];
};
const cases = (JSON.parse(readFileSync(join(here, 'fixtures', 'ticket-policy-cases.json'), 'utf8')) as { cases: Case[] }).cases;

const SECTIONS = ['Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'];
const BASE: Record<string, string> = {
  Impact: 'Anyone filing a ticket sees right away what is missing.',
  What: 'Check a ticket body the same way on every write path.',
  Why: 'Tickets without a plan fail late.',
  Plan: '1. Write the checker.\n2. Add the tests.',
  DoD: '- A draft missing a DoD is refused.',
  Proof: 'Run the checker on a real draft: refused, then accepted.',
  'Agent detail': 'Files under scripts/jira.',
};
export function bodyOf(c: Partial<Case>): string {
  const parts = SECTIONS.filter((s) => !(c.omit ?? []).includes(s)).map(
    (s) => `${(c.bold ?? []).includes(s) ? `**${s}**` : (c.plain ?? []).includes(s) ? s : `## ${s}`}\n${c.replace?.[s] ?? BASE[s]}`,
  );
  return parts.join('\n\n') + (c.append ? `\n\n${c.append}\n` : '\n');
}
const warnOnly = (t: string) => /^(epic|subtask|sub-task)$/i.test(t);
const refused = (c: Case) => c.expect.length > 0 && !warnOnly(c.type);
const placement = (t: string) => (warnOnly(t) ? [] : ['--backlog', '--proposed-version', 'backlog', '--why', 'waits for the parity test']);

type Issue = { key: string; fields: Record<string, unknown> };
type Fake = {
  issues: Map<string, Issue>; mutations: string[]; transitions: Array<{ id: string; name: string; to?: { name: string } }>;
  swallow: boolean; search: Array<{ key: string; fields: Record<string, unknown> }>; onCreate?: () => void; next: number;
};
let jira: Fake;
const mockRequest = request as unknown as ReturnType<typeof vi.fn>;
function issue(key: string, md: string, extra: Record<string, unknown> = {}): void {
  jira.issues.set(key, {
    key,
    fields: {
      summary: 'Planning & tracking: a ticket', issuetype: { name: 'Task' }, labels: ['standalone'], status: { name: 'To Do', statusCategory: { key: 'new' } },
      description: markdownToAdf(md), project: { key: key.split('-')[0] }, fixVersions: [], ...extra,
    },
  });
}
function fakeRequest(method: string, path: string, body?: unknown): unknown {
  const p = path.split('?')[0]!;
  if (method !== 'GET') jira.mutations.push(`${method} ${p}`);
  let m: RegExpExecArray | null;
  if (method === 'POST' && p === '/issue') {
    jira.onCreate?.();
    const fields = (body as { fields: Record<string, unknown> }).fields;
    const key = `${(fields.project as { key: string }).key}-${jira.next++}`;
    jira.issues.set(key, { key, fields: { ...fields, status: { name: 'To Do', statusCategory: { key: 'new' } } } });
    return { key, id: '1' };
  }
  if (method === 'GET' && p.startsWith('/search')) return { issues: jira.search };
  if (method === 'GET' && /^\/project\/[^/]+\/versions$/.test(p)) return [{ id: '1', name: 'v1.1.3', released: false, archived: false }];
  if (method === 'GET' && /^\/project\/[^/]+$/.test(p)) return { key: p.split('/')[2] };
  if ((m = /^\/issue\/([^/]+)\/transitions$/.exec(p))) {
    if (method === 'GET') return { transitions: jira.transitions };
    const t = jira.transitions.find((x) => x.id === (body as { transition: { id: string } }).transition.id)!;
    if (!jira.swallow) jira.issues.get(m[1]!)!.fields.status = { name: t.to?.name ?? t.name, statusCategory: { key: 'done' } };
    return {};
  }
  if ((m = /^\/issue\/([^/]+)\/comment$/.exec(p))) return method === 'GET' ? { comments: [] } : {};
  if ((m = /^\/issue\/([^/]+)$/.exec(p))) {
    const it = jira.issues.get(m[1]!);
    if (!it) throw new Error(`404 ${m[1]}`);
    if (method === 'GET') return { key: it.key, fields: it.fields };
    const b = body as { fields?: Record<string, unknown>; update?: { labels?: Array<{ add?: string; remove?: string }> } };
    Object.assign(it.fields, b.fields ?? {});
    for (const op of b.update?.labels ?? []) {
      const ls = new Set((it.fields.labels as string[]) ?? []);
      if (op.add) ls.add(op.add);
      if (op.remove) ls.delete(op.remove);
      it.fields.labels = [...ls];
    }
    return {};
  }
  return {};
}
const writes = () => jira.mutations;

type Run = { code: number; stdout: string; stderr: string };
async function cli(argv: string[]): Promise<Run> {
  const out: string[] = [];
  const err: string[] = [];
  const log = vi.spyOn(console, 'log').mockImplementation((s: unknown) => { out.push(String(s)); });
  const error = vi.spyOn(console, 'error').mockImplementation((s: unknown) => { err.push(String(s)); });
  const exit = vi.spyOn(process, 'exit').mockImplementation(((c?: number) => { throw new Error(`__exit ${c ?? 0}`); }) as never);
  process.exitCode = undefined;
  const p = new Command();
  p.exitOverride();
  for (const r of [registerCreate, registerEdit, registerMove, registerTransition, registerRelease]) r(p);
  let code = 0;
  try {
    await p.parseAsync(['node', 'jira', ...argv]);
    code = Number(process.exitCode ?? 0);
  } catch (e) {
    const msg = (e as Error).message;
    const x = /^__exit (\d+)$/.exec(msg);
    if (x) code = Number(x[1]);
    else { err.push(msg); code = 1; }
  } finally {
    log.mockRestore(); error.mockRestore(); exit.mockRestore();
    process.exitCode = undefined;
  }
  return { code, stdout: out.join('\n'), stderr: err.join('\n') };
}
const mcpDeps = (): ToolDeps => ({ request: mockRequest as never, uploadAttachment: vi.fn() as never, agileRequest: vi.fn() as never, runCli: cli } as ToolDeps);
const tool = (name: string) => createTools().find((t) => t.name === name)!;

let root: string;
beforeEach(async () => {
  vi.clearAllMocks();
  jira = { issues: new Map(), mutations: [], transitions: [], swallow: false, search: [], next: 1 };
  mockRequest.mockImplementation(async (m: string, p: string, b?: unknown) => fakeRequest(m, p, b));
  root = mkdtempSync(join(tmpdir(), 'policy-parity-'));
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'state'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
  vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
  writeFileSync(join(root, 'verbatim.txt'), 'R1 = v1.1.3\n');
  const r = await cli(['release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(root, 'verbatim.txt')]);
  if (r.code !== 0) throw new Error(`declare failed: ${r.stderr}`);
  jira.mutations = [];
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(root, { recursive: true, force: true });
});

describe.each(cases)('corpus $id', (c) => {
  const md = bodyOf(c);
  const names = (msgs: string) => c.expect.every((f) => msgs.includes(f));

  it('offline draft checker', () => {
    const draft = join(root, `${c.id}.md`);
    writeFileSync(draft, md);
    const r = spawnSync('bash', [checker, '--type', c.type, '--draft', draft, '--sector', 'X', '--labels', ['standalone', ...(c.labels ?? [])].join(',')], {
      encoding: 'utf8', env: { ...process.env, TICKET_STANDARD_QUEUE_DIR: join(root, 'queue') },
    });
    expect(r.status, r.stdout + r.stderr).toBe(refused(c) ? 1 : 0);
    expect(names(r.stdout + r.stderr), r.stdout + r.stderr).toBe(true);
  });

  it('markdown and ADF name the same fields', () => {
    const a = lintPlainBlock(md, c.labels ?? []);
    const b = lintPlainBlockAdf(markdownToAdf(md), c.labels ?? []);
    expect(a.length === 0).toBe(c.expect.length === 0);
    expect(names(a.join('; ')), a.join('; ')).toBe(true);
    expect(b).toEqual(a);
  });

  it('CLI create refuses or files, and a refusal writes nothing', async () => {
    const f = join(root, `${c.id}.md`);
    writeFileSync(f, md);
    const r = await cli(['create', '--type', c.type, '--title', 'Planning & tracking: one policy', '--desc-file', f,
      '--labels', ['standalone', ...(c.labels ?? [])].join(','), ...placement(c.type)]);
    if (refused(c)) {
      expect(r.code, r.stderr).not.toBe(0);
      expect(names(r.stderr), r.stderr).toBe(true);
      expect(writes()).toEqual([]);
    } else {
      expect(r.code, r.stderr).toBe(0);
      expect(writes()).toContain('POST /issue');
    }
  });

  it('MCP create goes through the CLI and agrees with it', async () => {
    const args: Record<string, unknown> = { type: c.type, title: 'Planning & tracking: one policy', desc: md, labels: ['standalone', ...(c.labels ?? [])].join(',') };
    if (!warnOnly(c.type)) Object.assign(args, { backlog: true, proposedVersion: 'backlog', why: 'waits for the parity test' });
    const run = tool('create').handler(args, mcpDeps());
    if (refused(c)) {
      await expect(run).rejects.toThrow();
      expect(writes()).toEqual([]);
    } else {
      await expect(run).resolves.toMatch(/Created HIMMEL-\d+/);
    }
  });
});

const VALID = bodyOf({});

describe('MCP bridge (7412 1, 6281, F3, F6)', () => {
  it('mcp-no-placement: a bare Task with a valid body and home is refused like the CLI, with no write', async () => {
    await expect(tool('create').handler({ type: 'Task', title: 'Planning & tracking: x', desc: VALID, labels: 'standalone' }, mcpDeps())).rejects.toThrow(/placement/);
    expect(writes()).toEqual([]);
  });

  it('6281: an explicit sector with sectors not configured comes back as a warning in the MCP reply', async () => {
    const out = await tool('create').handler({ type: 'Epic', title: 'Planning & tracking: x', desc: VALID, labels: 'standalone', sector: 'Ship loop' }, mcpDeps());
    expect(out).toMatch(/--sector ignored/);
  });

  it('mcp-transition-no-op: a 2xx transition that leaves the status unchanged is not reported as success', async () => {
    issue('HIMMEL-5', VALID);
    jira.transitions = [{ id: '31', name: 'In Progress', to: { name: 'In Progress' } }];
    jira.swallow = true;
    await expect(tool('transition').handler({ key: 'HIMMEL-5', status: 'In Progress' }, mcpDeps())).rejects.toThrow(/not changed/);
  });

  it('the bridge cannot reach a direct Jira write: with no CLI runner it refuses before any request', async () => {
    const deps = { ...mcpDeps(), runCli: undefined } as unknown as ToolDeps;
    await expect(tool('create').handler({ type: 'Epic', title: 'x', desc: VALID }, deps)).rejects.toThrow();
    expect(mockRequest).not.toHaveBeenCalled();
  });
});

describe('CLI transition (6797)', () => {
  it('a transition with no to.name still reads the status back and fails when it did not move', async () => {
    issue('HIMMEL-5', VALID);
    jira.transitions = [{ id: '31', name: 'In Progress' }];
    jira.swallow = true;
    const r = await cli(['transition', 'HIMMEL-5', 'In Progress']);
    expect(r.code, r.stdout).not.toBe(0);
    expect(r.stderr).toMatch(/not changed/);
  });

  it('control: a transition with no to.name that lands is confirmed', async () => {
    issue('HIMMEL-5', VALID);
    jira.transitions = [{ id: '31', name: 'In Progress' }];
    const r = await cli(['transition', 'HIMMEL-5', 'In Progress']);
    expect(r.code, r.stderr).toBe(0);
  });
});

describe('CLI edit (F4)', () => {
  it('edit-valid-to-todo: a valid ticket edited to a TODO Plan is refused before the PUT', async () => {
    issue('HIMMEL-5', VALID);
    const f = join(root, 'todo.md');
    writeFileSync(f, bodyOf({ replace: { Plan: '1. TODO' } }));
    const r = await cli(['edit', 'HIMMEL-5', '--desc-file', f]);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/Plan/);
    expect(writes()).toEqual([]);
  });

  it('legacy-partial-repair: a legacy ticket gaining its Plan is saved, and the Proof it still lacks is named as a warning', async () => {
    issue('HIMMEL-5', bodyOf({ omit: ['Plan', 'Proof'] }));
    const f = join(root, 'repair.md');
    writeFileSync(f, bodyOf({ omit: ['Proof'] }));
    const r = await cli(['edit', 'HIMMEL-5', '--desc-file', f]);
    expect(r.code, r.stderr).toBe(0);
    expect(writes()).toContain('PUT /issue/HIMMEL-5');
    expect(r.stderr).toMatch(/warning.*Proof/s);
  });

  it('an added ci label with no Metric is refused before the PUT', async () => {
    issue('HIMMEL-5', VALID);
    const r = await cli(['edit', 'HIMMEL-5', '--add-labels', 'ci']);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/Metric/);
    expect(writes()).toEqual([]);
  });

  it('edit --add-labels phase:sliced on a phase:design ticket is refused with no PUT', async () => {
    issue('HIMMEL-5', VALID, { labels: ['standalone', 'phase:design'] });
    const r = await cli(['edit', 'HIMMEL-5', '--add-labels', 'phase:sliced']);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/two phase labels/);
    expect(writes()).toEqual([]);
  });

  it('edit --labels phase:design,phase:build is refused with no PUT', async () => {
    issue('HIMMEL-5', VALID);
    const r = await cli(['edit', 'HIMMEL-5', '--labels', 'standalone,phase:design,phase:build']);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/two phase labels/);
    expect(writes()).toEqual([]);
  });

  it('control: a priority-only edit of a legacy ticket is not asked to repair it', async () => {
    issue('HIMMEL-5', bodyOf({ omit: ['Proof'] }), { priority: { name: 'Medium' } });
    const r = await cli(['edit', 'HIMMEL-5', '--priority', 'High']);
    expect(r.code, r.stderr).toBe(0);
  });
});

describe('CLI move (F5)', () => {
  it('move-no-target-home: a move with no destination home or placement is refused before any write', async () => {
    issue('HIMMEL-5', VALID);
    const r = await cli(['move', 'HIMMEL-5', '--to-project', 'LUNA']);
    expect(r.code).not.toBe(0);
    expect(writes()).toEqual([]);
  });

  it('a source whose body fails the standard is refused before the target is created', async () => {
    issue('HIMMEL-5', bodyOf({ omit: ['Proof'] }));
    const r = await cli(['move', 'HIMMEL-5', '--to-project', 'LUNA', '--labels', 'standalone', ...placement('Task')]);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/Proof/);
    expect(writes()).toEqual([]);
  });

  it('control: a valid move files the target through create, then closes the source', async () => {
    issue('HIMMEL-5', VALID);
    jira.transitions = [{ id: '41', name: 'Done', to: { name: 'Done' } }];
    const r = await cli(['move', 'HIMMEL-5', '--to-project', 'LUNA', '--labels', 'standalone', ...placement('Task')]);
    expect(r.code, r.stderr).toBe(0);
    expect(writes()[0]).toBe('POST /issue');
    expect(writes()).toContain('POST /issue/HIMMEL-5/transitions');
  });
});

describe('CLI create effects (I4, I8)', () => {
  it('duplicate residual: a refusal for a missing home happens before the duplicate is commented on or linked', async () => {
    jira.search = [{ key: 'HIMMEL-77', fields: {} }];
    issue('HIMMEL-5', VALID);
    const f = join(root, 'dup.md');
    writeFileSync(f, VALID);
    const r = await cli(['create', '--type', 'Task', '--title', 'Planning & tracking: dup', '--desc-file', f,
      '--residual-of', 'HIMMEL-5', '--fu-class', 'escape', '--class', 'c1', '--area', 'a1']);
    expect(r.code).not.toBe(0);
    expect(r.stderr).toMatch(/home/);
    expect(writes()).toEqual([]);
  });

  it('created-intake-failed: a created ticket whose INTAKE fails reports PARTIAL with its key and the unfinished INTAKE', async () => {
    jira.onCreate = () => rmSync(join(root, 'state'), { recursive: true, force: true });
    const f = join(root, 'ok.md');
    writeFileSync(f, VALID);
    const r = await cli(['create', '--type', 'Task', '--title', 'Planning & tracking: partial', '--desc-file', f, '--labels', 'standalone', ...placement('Task')]);
    expect(r.code).not.toBe(0);
    expect(r.stdout).toMatch(/Created HIMMEL-1/);
    expect(r.stderr).toMatch(/PARTIAL.*HIMMEL-1.*INTAKE/s);
  });
});

describe('release root (cwd bug)', () => {
  it('a CLI run from another repository still resolves the release root of its own checkout', () => {
    const foreign = join(root, 'luna');
    mkdirSync(foreign);
    execFileSync('git', ['init', '-q', foreign]);
    const own = basename(dirname(execFileSync('git', ['-C', here, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim()));
    const cwd = process.cwd();
    try {
      process.chdir(foreign);
      const got = releaseRoot({ HANDOVER_DIR: root, USER_SLUG: 'u' });
      expect(got).toBe(join(root, 'u', own, 'release'));
    } finally {
      process.chdir(cwd);
    }
  });
});
