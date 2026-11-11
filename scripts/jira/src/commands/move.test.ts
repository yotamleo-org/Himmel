import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', () => ({ request: vi.fn(), projectKey: () => 'HIMMEL' }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import {
  findTransitionByName,
  prependSupersedesNote,
  registerMove,
  safeContent,
  wrapMovedComment,
  type AdfDoc,
  type JiraComment,
} from './move.js';
import { registerRelease } from './release.js';
import { request } from '../client.js';
import { markdownToAdf } from '../adf.js';
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import type { JiraTransition } from '../types.js';

const fixedNow = new Date('2026-05-27T08:00:00.000Z');

describe('safeContent', () => {
  it('returns [] for null', () => {
    expect(safeContent(null)).toEqual([]);
  });

  it('returns [] for undefined', () => {
    expect(safeContent(undefined)).toEqual([]);
  });

  it('returns [] when content is missing', () => {
    expect(safeContent({})).toEqual([]);
  });

  it('returns [] when content is not an array (malformed legacy ADF)', () => {
    // Legacy issues sometimes carry a stringified description that survived
    // earlier migrations. The shape is malformed for our purposes.
    expect(safeContent({ content: 'some legacy text' } as { content: unknown })).toEqual([]);
  });

  it('returns the array when content is well-formed', () => {
    const arr = [{ type: 'paragraph' }];
    expect(safeContent({ content: arr } as { content: unknown })).toEqual(arr);
  });
});

describe('prependSupersedesNote', () => {
  it('prepends a supersedes paragraph to an existing description', () => {
    const original: AdfDoc = {
      type: 'doc',
      version: 1,
      content: [
        {
          type: 'paragraph',
          content: [{ type: 'text', text: 'Existing body line.' }],
        },
      ],
    };
    const result = prependSupersedesNote('HIMMEL-180', original, fixedNow);
    expect(result.type).toBe('doc');
    expect(result.version).toBe(1);
    expect(result.content).toHaveLength(2);
    const note = result.content[0];
    expect(note.type).toBe('paragraph');
    expect((note.content?.[0] as { text: string }).text).toBe(
      'Originally filed as HIMMEL-180 — moved 2026-05-27 via jira move.',
    );
    expect((note.content?.[0] as { marks: Array<{ type: string }> }).marks).toEqual([
      { type: 'em' },
    ]);
    expect(result.content[1]).toEqual(original.content[0]);
  });

  it('handles null source description', () => {
    const result = prependSupersedesNote('HIMMEL-180', null, fixedNow);
    expect(result.content).toHaveLength(1);
    expect((result.content[0].content?.[0] as { text: string }).text).toBe(
      'Originally filed as HIMMEL-180 — moved 2026-05-27 via jira move.',
    );
  });

  it('handles undefined source description', () => {
    const result = prependSupersedesNote('HIMMEL-180', undefined, fixedNow);
    expect(result.content).toHaveLength(1);
  });

  it('preserves non-paragraph nodes (codeBlock, panel, heading) unchanged', () => {
    const original: AdfDoc = {
      type: 'doc',
      version: 1,
      content: [
        {
          type: 'codeBlock',
          attrs: { language: 'bash' },
          content: [{ type: 'text', text: 'echo hello' }],
        },
        {
          type: 'panel',
          attrs: { panelType: 'info' },
          content: [
            {
              type: 'paragraph',
              content: [{ type: 'text', text: 'callout body' }],
            },
          ],
        },
        {
          type: 'heading',
          attrs: { level: 2 },
          content: [{ type: 'text', text: 'Section' }],
        },
      ],
    };
    const result = prependSupersedesNote('HIMMEL-180', original, fixedNow);
    expect(result.content).toHaveLength(4); // note + 3 originals
    expect(result.content[1].type).toBe('codeBlock');
    expect(result.content[2].type).toBe('panel');
    expect(result.content[3].type).toBe('heading');
  });

  it('falls back to safe doc when source description has malformed content (non-array)', () => {
    // Cast through unknown to simulate a legacy/malformed shape that escaped
    // the type system in the wild.
    const malformed = {
      type: 'doc',
      version: 1,
      content: 'string content from a legacy migration',
    } as unknown as AdfDoc;
    const result = prependSupersedesNote('HIMMEL-180', malformed, fixedNow);
    expect(result.content).toHaveLength(1); // only the note; bad content dropped
    expect((result.content[0].content?.[0] as { text: string }).text).toContain(
      'Originally filed as HIMMEL-180',
    );
  });
});

describe('wrapMovedComment', () => {
  it('wraps comment body with author + date prefix', () => {
    const comment: JiraComment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: {
        type: 'doc',
        version: 1,
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: 'Original comment text.' }],
          },
        ],
      },
    };
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.type).toBe('doc');
    expect(wrapped.content).toHaveLength(2);
    expect((wrapped.content[0].content?.[0] as { text: string }).text).toBe(
      'Original by Yotam on 2026-05-15:',
    );
    expect(wrapped.content[1]).toEqual(comment.body.content[0]);
  });

  it('handles empty source comment body content', () => {
    const comment: JiraComment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: { type: 'doc', version: 1, content: [] },
    };
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.content).toHaveLength(1);
    expect((wrapped.content[0].content?.[0] as { text: string }).text).toContain(
      'Original by Yotam',
    );
  });

  it('handles malformed comment body (content non-array)', () => {
    const comment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: { type: 'doc', version: 1, content: null },
    } as unknown as JiraComment;
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.content).toHaveLength(1); // only the prefix; bad content dropped
  });
});

describe('findTransitionByName', () => {
  const transitions: JiraTransition[] = [
    { id: '11', name: 'To Do' },
    { id: '21', name: 'In Progress' },
    { id: '31', name: 'Done' },
    { id: '41', name: "Won't Do" },
  ];

  it('matches by exact name', () => {
    expect(findTransitionByName(transitions, 'Done')).toEqual({ id: '31', name: 'Done' });
  });

  it('matches case-insensitively', () => {
    expect(findTransitionByName(transitions, 'done')).toEqual({ id: '31', name: 'Done' });
    expect(findTransitionByName(transitions, 'IN PROGRESS')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('returns undefined for missing name', () => {
    expect(findTransitionByName(transitions, 'Closed')).toBeUndefined();
  });

  it('returns undefined for undefined transitions (malformed response)', () => {
    expect(findTransitionByName(undefined, 'Done')).toBeUndefined();
  });

  it('returns undefined for null transitions', () => {
    expect(findTransitionByName(null, 'Done')).toBeUndefined();
  });

  it('returns undefined for empty array', () => {
    expect(findTransitionByName([], 'Done')).toBeUndefined();
  });
});

describe('jira move into a version, for operator work', () => {
  let root: string;
  const mockRequest = vi.mocked(request);
  const posted = () => mockRequest.mock.calls.some((c) => c[0] === 'POST' && c[1] === '/issue');
  const cli = async (register: (p: Command) => void, argv: string[]) => {
    const p = new Command();
    p.exitOverride();
    register(p);
    await p.parseAsync(['node', 'jira', ...argv]);
  };
  const move = (...a: string[]) => cli(registerMove, ['move', 'HIMMEL-2', '--to-project', 'HIMMEL', '--labels', 'operator-directed',
    '--sector', 'Ship loop', '--parent', 'HIMMEL-9', '--proposed-version', 'v1.1.3', ...a]);

  beforeEach(async () => {
    root = mkdtempSync(join(tmpdir(), 'move-gate-'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'state'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((code: number) => { throw new Error(`exit ${code}`); }) as never);
    writeFileSync(join(root, 'verbatim.txt'), 'R1 = v1.1.3\n');
    await cli(registerRelease, ['release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(root, 'verbatim.txt')]);
    mockRequest.mockReset();
    mockRequest.mockImplementation((async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/project/') && path.endsWith('/versions')) return [{ name: 'v1.1.3', released: false }];
      if (method === 'GET' && path.startsWith('/project/')) return {};
      if (method === 'GET' && path.startsWith('/search/jql')) return { issues: [] };
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-2?fields=summary')) {
        return { fields: { summary: 'the console loses a worker', issuetype: { name: 'Task' }, description: markdownToAdf(PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled')) } };
      }
      if (method === 'GET' && path.startsWith('/issue/HIMMEL-2/comment')) return { comments: [] };
      if (method === 'GET' && path.includes('/transitions')) return { transitions: [{ id: '31', name: 'Done' }] };
      if (method === 'GET' && path.includes('fields=status')) return { fields: { status: { name: 'Done' } } };
      if (method === 'POST' && path === '/issue') return { key: 'HIMMEL-78' };
      return {};
    }) as never);
  });
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    rmSync(root, { recursive: true, force: true });
  });

  it('a gated move --proposed-version is refused without --decision and filed with it', async () => {
    await expect(move()).rejects.toThrow(/exit/);
    expect(vi.mocked(process.exit).mock.calls[0]).toEqual([1]);
    expect(vi.mocked(console.error).mock.calls.map((c) => String(c[0])).join('\n'))
      .toMatch(/the target create was refused, nothing was written: release request: NEW is operator-directed; a request that places it needs a record of the operator's words/);
    expect(posted()).toBe(false);
    mkdirSync(join(root, 'specs', 'decisions'), { recursive: true });
    writeFileSync(join(root, 'specs', 'decisions', 'verbatim-decision-9-op.txt'), 'Operator:\n\n"Approved one more round"\n');
    await move('--decision', '9', '--words', 'Approved one more round');
    expect(posted()).toBe(true);
    const last = JSON.parse(readFileSync(join(root, 'state', 'R1', 'requests.jsonl'), 'utf8').trim().split('\n').at(-1) ?? '{}');
    expect(last).toMatchObject({ key: 'HIMMEL-78', to_v: 'v1.1.3', evidence: { operator: expect.stringMatching(/^O-R1-\d{4}$/) } });
  });
});
