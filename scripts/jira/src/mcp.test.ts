import { describe, it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { createTools, buildServer, type ToolDeps, type JiraTool } from './mcp.js';
import type { CliResult, CliRunner } from './mcp-cli.js';


const TOOL_NAMES = [
  'get',
  'create',
  'list',
  'transition',
  'transitions',
  'comment',
  'attach',
  'edit',
  'projects',
  'project-create',
  'roadmap-set',
  'roadmap-get',
  'rank',
  'release',
];

function tool(name: string): JiraTool {
  const t = createTools().find((x) => x.name === name);
  if (!t) throw new Error(`tool ${name} not registered`);
  return t;
}

const argvOf = (name: string, args: Record<string, unknown>): string[] => tool(name).argv(args);

function fakeRunner(reply: Partial<CliResult> = {}): { deps: ToolDeps; runCli: ReturnType<typeof vi.fn> } {
  const runCli = vi.fn(async (_argv: string[]): Promise<CliResult> => ({ code: 0, stdout: '', stderr: '', ...reply }));
  return { deps: { runCli: runCli as unknown as CliRunner }, runCli };
}

describe('MCP tool registration', () => {
  it('registers exactly the CLI verbs', () => {
    const names = createTools().map((t) => t.name).sort();
    expect(names).toEqual([...TOOL_NAMES].sort());
  });

  it.each(TOOL_NAMES)('tool %s has a non-empty description and object input schema', (name) => {
    const t = tool(name);
    expect(t.description.length).toBeGreaterThan(0);
    expect(t.inputSchema.type).toBe('object');
    expect(t.inputSchema.additionalProperties).toBe(false);
    expect(typeof t.inputSchema.properties).toBe('object');
  });

  it('marks required args to mirror Commander required semantics', () => {
    expect(tool('get').inputSchema.required).toEqual(['key']);
    expect(tool('create').inputSchema.required).toEqual(['type', 'title']);
    expect(tool('transition').inputSchema.required).toEqual(['key', 'status']);
    expect(tool('transitions').inputSchema.required).toEqual(['key']);
    expect(tool('comment').inputSchema.required).toEqual(['key']);
    expect(tool('attach').inputSchema.required).toEqual(['key', 'paths']);
    expect(tool('edit').inputSchema.required).toEqual(['key']);
    expect(tool('project-create').inputSchema.required).toEqual(['key', 'name']);
    expect(tool('release').inputSchema.required).toEqual(['sub', 'release']);
    expect(tool('list').inputSchema.required).toBeUndefined();
    expect(tool('projects').inputSchema.required).toBeUndefined();
  });

  it('create exposes the placement fields the CLI requires', () => {
    const props = Object.keys(tool('create').inputSchema.properties);
    for (const p of ['fixVersion', 'proposedVersion', 'backlog', 'why', 'gate', 'labels', 'sector', 'parent']) {
      expect(props).toContain(p);
    }
  });

});

describe('argv mapping: one fixed CLI verb per tool', () => {
  it('get', () => {
    expect(argvOf('get', { key: 'HIMMEL-1' })).toEqual(['get', 'HIMMEL-1']);
    expect(argvOf('get', { key: 'HIMMEL-1', json: true, short: true })).toEqual(['get', 'HIMMEL-1', '--json', '--short']);
    expect(argvOf('get', { key: 'HIMMEL-1', json: false })).toEqual(['get', 'HIMMEL-1']);
  });

  it('create with placement, in spec order', () => {
    const md = '## Impact\nbody';
    expect(argvOf('create', {
      type: 'Task', title: 'T', desc: md, labels: 'standalone', backlog: true, proposedVersion: 'backlog', why: 'w',
    })).toEqual([
      'create', '--type', 'Task', '--title', 'T', '--desc', md, '--labels', 'standalone',
      '--proposed-version', 'backlog', '--backlog', '--why', 'w',
    ]);
  });

  it('create maps every field to its CLI flag', () => {
    expect(argvOf('create', {
      type: 'Bug', title: 'T', descFile: '/d.md', adfFile: '/a.json', parent: 'H-1', labels: 'a,b', sector: 'Ship loop',
      project: 'H', priority: 'Highest', fixVersion: 'v2', gate: 'critical', attach: ['x.png', 'y.png'],
    })).toEqual([
      'create', '--type', 'Bug', '--title', 'T', '--desc-file', '/d.md', '--adf-file', '/a.json', '--parent', 'H-1',
      '--labels', 'a,b', '--sector', 'Ship loop', '--project', 'H', '--priority', 'Highest', '--fix-version', 'v2',
      '--gate', 'critical', '--attach', 'x.png', '--attach', 'y.png',
    ]);
  });

  it('MCP create maps decision and words into the argv', () => {
    expect(tool('create').inputSchema.properties).toHaveProperty('decision');
    expect(tool('create').inputSchema.properties).toHaveProperty('words');
    expect(argvOf('create', { type: 'Task', title: 'T', proposedVersion: 'v2', decision: '9', words: 'Approved one more round' })).toEqual([
      'create', '--type', 'Task', '--title', 'T', '--proposed-version', 'v2', '--decision', '9', '--words', 'Approved one more round',
    ]);
  });

  it('create passes a value that looks like a flag as one argv element, never splits it', () => {
    expect(argvOf('create', { type: 'Task', title: '--why; rm -rf /' })).toEqual(['create', '--type', 'Task', '--title', '--why; rm -rf /']);
  });

  it('list', () => {
    expect(argvOf('list', {})).toEqual(['list']);
    expect(argvOf('list', { project: 'ABC', type: 'Task', status: 'Done', label: 'l', jql: 'x = 1', limit: '5' })).toEqual([
      'list', '--project', 'ABC', '--type', 'Task', '--status', 'Done', '--label', 'l', '--jql', 'x = 1', '--limit', '5',
    ]);
  });

  it('transition', () => {
    expect(argvOf('transition', { key: 'HIMMEL-1', status: 'Done' })).toEqual(['transition', 'HIMMEL-1', 'Done']);
  });

  it('transition noVersion becomes --no-version', () => {
    expect(argvOf('transition', { key: 'HIMMEL-1', status: 'Done', noVersion: true })).toEqual(['transition', 'HIMMEL-1', 'Done', '--no-version']);
    expect(argvOf('transition', { key: 'HIMMEL-1', status: 'Done', noVersion: false })).toEqual(['transition', 'HIMMEL-1', 'Done']);
  });

  it('transitions', () => {
    expect(argvOf('transitions', { key: 'HIMMEL-1' })).toEqual(['transitions', 'HIMMEL-1']);
  });

  it('comment with text puts -- before the key and the text', () => {
    expect(argvOf('comment', { key: 'HIMMEL-1', text: 'hi' })).toEqual(['comment', '--', 'HIMMEL-1', 'hi']);
    expect(argvOf('comment', { key: 'HIMMEL-1', text: '--json' })).toEqual(['comment', '--', 'HIMMEL-1', '--json']);
  });

  it('comment with a file or ADF file keeps the flags before the --', () => {
    expect(argvOf('comment', { key: 'HIMMEL-1', commentFile: '/c.md', attach: ['a.png'] })).toEqual([
      'comment', '--comment-file', '/c.md', '--attach', 'a.png', '--', 'HIMMEL-1',
    ]);
    expect(argvOf('comment', { key: 'HIMMEL-1', adfFile: '/c.json' })).toEqual(['comment', '--adf-file', '/c.json', '--', 'HIMMEL-1']);
  });

  it('comment with an empty-string text is still text', () => {
    expect(argvOf('comment', { key: 'HIMMEL-1', text: '' })).toEqual(['comment', '--', 'HIMMEL-1', '']);
  });

  it('comment with no text, file or ADF throws before anything runs', async () => {
    const { deps, runCli } = fakeRunner();
    await expect(tool('comment').handler({ key: 'HIMMEL-1' }, deps)).rejects.toThrow(/comment requires text or commentFile or adfFile/);
    expect(runCli).not.toHaveBeenCalled();
  });

  it('attach puts -- before the key and the paths', () => {
    expect(argvOf('attach', { key: 'HIMMEL-1', paths: ['x.txt', '-y.txt'] })).toEqual(['attach', '--', 'HIMMEL-1', 'x.txt', '-y.txt']);
  });

  it('edit', () => {
    expect(argvOf('edit', { key: 'HIMMEL-1' })).toEqual(['edit', 'HIMMEL-1']);
    expect(argvOf('edit', { key: 'HIMMEL-1', priority: 'High', severity: 's', title: 'New', parent: 'H-2', labels: 'a,b', sector: 'Ship loop' })).toEqual([
      'edit', 'HIMMEL-1', '--priority', 'High', '--severity', 's', '--title', 'New', '--parent', 'H-2', '--labels', 'a,b', '--sector', 'Ship loop',
    ]);
  });

  it('edit desc is an alias of --description', () => {
    expect(argvOf('edit', { key: 'HIMMEL-1', desc: 'd' })).toEqual(['edit', 'HIMMEL-1', '--description', 'd']);
    expect(argvOf('edit', { key: 'HIMMEL-1', description: 'd2', desc: 'd' })).toEqual(['edit', 'HIMMEL-1', '--description', 'd2']);
  });

  it('edit descFile wins over desc', () => {
    expect(argvOf('edit', { key: 'HIMMEL-1', descFile: '/d.md', desc: 'd' })).toEqual(['edit', 'HIMMEL-1', '--desc-file', '/d.md']);
  });

  it('projects', () => {
    expect(argvOf('projects', {})).toEqual(['projects']);
    expect(argvOf('projects', { limit: '10' })).toEqual(['projects', '--limit', '10']);
  });

  it('project-create', () => {
    expect(argvOf('project-create', { key: 'NEW', name: 'New Proj' })).toEqual(['project-create', '--key', 'NEW', '--name', 'New Proj']);
    expect(argvOf('project-create', { key: 'NEW', name: 'N', type: 'software', template: 't', lead: 'acct' })).toEqual([
      'project-create', '--key', 'NEW', '--name', 'N', '--type', 'software', '--template', 't', '--lead', 'acct',
    ]);
  });

  it('roadmap-set', () => {
    expect(argvOf('roadmap-set', { key: 'HIMMEL-1', readiness: '4', effort: 'S', noRoi: true })).toEqual([
      'roadmap', 'set', 'HIMMEL-1', '--readiness', '4', '--effort', 'S', '--no-roi',
    ]);
    expect(argvOf('roadmap-set', {
      key: 'HIMMEL-1', theme: 't', goals: 'G1', impact: '3', alignment: '0.5', guard: true, auditDate: '2026-11-09',
      auditEvidence: 'http://e', closeCandidate: 'no',
    })).toEqual([
      'roadmap', 'set', 'HIMMEL-1', '--theme', 't', '--goals', 'G1', '--impact', '3', '--alignment', '0.5', '--guard',
      '--audit-date', '2026-11-09', '--audit-evidence', 'http://e', '--close-candidate', 'no',
    ]);
  });

  it('roadmap-get', () => {
    expect(argvOf('roadmap-get', { key: 'HIMMEL-1' })).toEqual(['roadmap', 'get', 'HIMMEL-1']);
  });

  it('rank', () => {
    expect(argvOf('rank', { key: 'HIMMEL-2', after: 'HIMMEL-1' })).toEqual(['rank', 'HIMMEL-2', '--after', 'HIMMEL-1']);
    expect(argvOf('rank', { key: 'HIMMEL-2', before: 'HIMMEL-3' })).toEqual(['rank', 'HIMMEL-2', '--before', 'HIMMEL-3']);
  });
});

describe('argv mapping: release subs', () => {
  const rel = (args: Record<string, unknown>) => argvOf('release', { release: 'R1', ...args });

  it('state', () => {
    expect(rel({ sub: 'state' })).toEqual(['release', 'state', 'R1']);
    expect(rel({ sub: 'state', json: true, mirrorRoot: '/m' })).toEqual(['release', 'state', 'R1', '--json', '--mirror-root', '/m']);
  });

  it('request: an evidence object becomes one JSON string', () => {
    expect(rel({ sub: 'request', verb: 'INTAKE', key: 'K-2', from: 'backlog', to: 'v1', why: 'found work', evidence: { parent: 'K-1', n: 2 } })).toEqual([
      'release', 'request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--from', 'backlog', '--to', 'v1', '--why', 'found work',
      '--evidence', '{"parent":"K-1","n":2}',
    ]);
  });

  it('request without evidence carries no --evidence', () => {
    expect(rel({ sub: 'request', verb: 'INTAKE', key: 'K-2', to: 'v1', why: 'w' })).toEqual([
      'release', 'request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'w',
    ]);
  });

  it('claim', () => {
    expect(rel({ sub: 'claim' })).toEqual(['release', 'claim', 'R1']);
  });

  it('rule', () => {
    expect(rel({
      sub: 'rule', req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', to: 'v1', sector: 'Planning & tracking', ground: 'regression', reason: 'r',
      supersedes: 'A-1', authority: 'rm', ref: 'O-9',
    })).toEqual([
      'release', 'rule', 'R1', '--req', 'Q-R1-0001', '--outcome', 'ADMIT', '--op', 'add', '--to', 'v1', '--sector', 'Planning & tracking',
      '--ground', 'regression', '--reason', 'r', '--supersedes', 'A-1', '--authority', 'rm', '--ref', 'O-9',
    ]);
  });

  it('apply needs a ruling', () => {
    expect(rel({ sub: 'apply', ruling: 'RUL-1' })).toEqual(['release', 'apply', 'R1', 'RUL-1']);
    expect(() => rel({ sub: 'apply' })).toThrow(/ruling is required/);
  });

  it('lease-acquire', () => {
    expect(rel({ sub: 'lease-acquire', expectEpoch: 3, doc: '/abs/doc.md', session: 'chief' })).toEqual([
      'release', 'lease', 'acquire', 'R1', '--expect-epoch', '3', '--doc', '/abs/doc.md', '--session', 'chief',
    ]);
  });

  it('lease-release', () => {
    expect(rel({ sub: 'lease-release' })).toEqual(['release', 'lease', 'release', 'R1']);
  });

  it('an unknown sub throws before anything runs, including the operator-only verbs', async () => {
    const { deps, runCli } = fakeRunner();
    for (const sub of ['operator-declare', 'declare', 'lease', '', undefined]) {
      await expect(tool('release').handler({ release: 'R1', sub }, deps)).rejects.toThrow(/sub is one of/);
    }
    expect(runCli).not.toHaveBeenCalled();
  });

  it('a missing release name throws before anything runs', async () => {
    const { deps, runCli } = fakeRunner();
    await expect(tool('release').handler({ sub: 'state' }, deps)).rejects.toThrow(/release is required/);
    expect(runCli).not.toHaveBeenCalled();
  });
});

describe('handler: runs the injected runner once with that argv', () => {
  it('calls the runner exactly once with the tool argv and returns stdout', async () => {
    const { deps, runCli } = fakeRunner({ stdout: 'Created HIMMEL-9\n' });
    const out = await tool('transition').handler({ key: 'HIMMEL-1', status: 'Done' }, deps);
    expect(runCli).toHaveBeenCalledTimes(1);
    expect(runCli).toHaveBeenCalledWith(['transition', 'HIMMEL-1', 'Done']);
    expect(out).toBe('Created HIMMEL-9');
  });

  it.each(TOOL_NAMES)('tool %s runs exactly its own argv', async (name) => {
    const args: Record<string, unknown> = { key: 'K-1', status: 'Done', name: 'N', paths: ['p'], text: 't', sub: 'state', release: 'R1', type: 'Task', title: 'T' };
    const { deps, runCli } = fakeRunner();
    await tool(name).handler(args, deps);
    expect(runCli).toHaveBeenCalledTimes(1);
    expect(runCli).toHaveBeenCalledWith(tool(name).argv(args));
  });

  it('a nonzero exit rejects with the CLI stderr (the refusal) and stdout', async () => {
    const { deps } = fakeRunner({ code: 1, stdout: 'partial out\n', stderr: 'jira: refused: no placement\n' });
    const err = await tool('create').handler({ type: 'Task', title: 'T' }, deps).then(() => null, (e: Error) => e);
    expect(err).toBeInstanceOf(Error);
    expect(err?.message).toBe('jira: refused: no placement\npartial out');
  });

  it('a nonzero exit with no output names the verb and the exit code', async () => {
    const { deps } = fakeRunner({ code: 3 });
    await expect(tool('transition').handler({ key: 'K-1', status: 'Done' }, deps)).rejects.toThrow('jira transition exited 3');
  });

  it('exit 0 returns stdout plus the stderr warnings', async () => {
    const { deps } = fakeRunner({ stdout: 'Created HIMMEL-2\n', stderr: 'jira: warning: --sector ignored (no Sector field is configured)\n' });
    const out = await tool('create').handler({ type: 'Task', title: 'T', sector: 'Ship loop' }, deps);
    expect(out).toBe('Created HIMMEL-2\njira: warning: --sector ignored (no Sector field is configured)');
  });

  it('a partial stderr on exit 1 is forwarded verbatim', async () => {
    const partial = 'jira: HIMMEL-5 created, but the INTAKE request failed: lease held\nFAIL: nothing else was written';
    const { deps } = fakeRunner({ code: 1, stdout: 'Created HIMMEL-5\n', stderr: `${partial}\n` });
    const err = await tool('create').handler({ type: 'Task', title: 'T' }, deps).then(() => null, (e: Error) => e);
    expect(err?.message).toBe(`${partial}\nCreated HIMMEL-5`);
  });

  it('a runner that itself rejects (the CLI is not built) rejects the handler', async () => {
    const runCli = vi.fn(async () => {
      throw new Error('jira mcp: the jira CLI is not built');
    });
    await expect(tool('get').handler({ key: 'K-1' }, { runCli: runCli as unknown as CliRunner })).rejects.toThrow(/not built/);
  });
});

describe('MCP server wiring', () => {
  type CallResult = { isError?: boolean; content: Array<{ type: string; text: string }> };
  type Handlers = { _requestHandlers: Map<string, (req: unknown, extra: unknown) => Promise<unknown>> };
  const extra = { mcpReq: { requestState: () => undefined, inputResponses: undefined } };
  const handlerOf = (deps: ToolDeps, method: string) => {
    const h = (buildServer(deps) as unknown as Handlers)._requestHandlers.get(method);
    if (!h) throw new Error(`no ${method} handler`);
    return h;
  };
  const call = (deps: ToolDeps, name: string, args: Record<string, unknown>) =>
    handlerOf(deps, 'tools/call')({ method: 'tools/call', params: { name, arguments: args } }, extra) as Promise<CallResult>;

  it('tools/list serves every tool with its description and schema', async () => {
    const result = (await handlerOf({}, 'tools/list')({ method: 'tools/list', params: {} }, {})) as { tools: JiraTool[] };
    expect(result.tools.map((t) => t.name).sort()).toEqual([...TOOL_NAMES].sort());
    for (const t of result.tools) {
      expect(t.description.length).toBeGreaterThan(0);
      expect(t.inputSchema.type).toBe('object');
      expect(t).not.toHaveProperty('handler');
      expect(t).not.toHaveProperty('argv');
    }
  });

  it('tools/call runs the CLI and returns its text', async () => {
    const { deps, runCli } = fakeRunner({ stdout: 'HIMMEL-1 → Done\n' });
    const r = await call(deps, 'transition', { key: 'HIMMEL-1', status: 'Done' });
    expect(r.isError).toBeUndefined();
    expect(r.content[0].text).toBe('HIMMEL-1 → Done');
    expect(runCli).toHaveBeenCalledWith(['transition', 'HIMMEL-1', 'Done']);
  });

  it('tools/call of a failing tool returns isError with the CLI text', async () => {
    const { deps } = fakeRunner({ code: 1, stderr: 'jira: refused: Task needs a placement\n' });
    const r = await call(deps, 'create', { type: 'Task', title: 'T' });
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toBe('jira: refused: Task needs a placement');
  });

  it('tools/call of a tool that throws before running returns isError and runs nothing', async () => {
    const { deps, runCli } = fakeRunner();
    const r = await call(deps, 'comment', { key: 'K-1' });
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toMatch(/comment requires text/);
    expect(runCli).not.toHaveBeenCalled();
  });

  it('tools/call: a non-Error throwable yields String() text', async () => {
    const deps: ToolDeps = {
      runCli: (async () => {
        // oxlint-disable-next-line no-throw-literal -- deliberate non-Error throw; the test verifies the String() fallback
        throw 'plain string error';
      }) as unknown as CliRunner,
    };
    const r = await call(deps, 'get', { key: 'K-1' });
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toBe('plain string error');
  });

  it('tools/call of an unknown tool is rejected', async () => {
    await expect(call({}, 'nope', {})).rejects.toThrow(/Unknown tool: nope/);
  });
});

describe('MCP SDK v2', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  const src = readFileSync(new URL('./mcp.ts', import.meta.url), 'utf8');

  it('pins the split v2 server package exactly and drops the v1 monolith', () => {
    expect(pkg.dependencies['@modelcontextprotocol/server']).toBe('2.4.0');
    expect(pkg.dependencies['@modelcontextprotocol/sdk']).toBeUndefined();
  });

  it('imports only the v2 server package', () => {
    expect(src).not.toContain('@modelcontextprotocol/sdk');
    expect(src).toContain("from '@modelcontextprotocol/server'");
  });

  it('owns no Jira REST or release write: it reaches Jira only through mcp-cli', () => {
    expect(src).not.toMatch(/from '\.\/client\.js'/);
    expect(src).not.toMatch(/from '\.\/release\//);
    expect(src).not.toMatch(/\bfetch\(/);
  });
});
