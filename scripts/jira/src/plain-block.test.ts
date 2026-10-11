import { describe, it, expect } from 'vitest';
import {
  lintPlainBlock,
  lintPlainBlockAdf,
  plainBlockVerdict,
  PLAIN_BLOCK_TEMPLATE,
} from './plain-block.js';

const OK =
  '## Impact\nOperators lose X.\n\n## What\nFix X.\n\n## Why\nIt hurts.\n\n## Agent detail\nfiles: a.ts';

describe('lintPlainBlock (HIMMEL-5226)', () => {
  it('passes a full block', () => expect(lintPlainBlock(OK)).toEqual([]));

  it('names every missing section on an empty body', () => {
    expect(lintPlainBlock('')).toEqual([
      'missing "## Impact"',
      'missing "## What"',
      'missing "## Why"',
      'missing "## Agent detail"',
    ]);
  });

  it('flags an empty section', () => {
    expect(lintPlainBlock(OK.replace('Fix X.', ''))).toEqual(['"## What" is empty']);
  });

  it('does not count a heading inside a code fence', () => {
    expect(lintPlainBlock('```\n' + OK + '\n```')).toHaveLength(4);
  });

  it('the template itself passes', () => {
    expect(lintPlainBlock(PLAIN_BLOCK_TEMPLATE)).toEqual([]);
  });
});

describe('lintPlainBlockAdf', () => {
  const h = (t: string) => ({
    type: 'heading',
    attrs: { level: 2 },
    content: [{ type: 'text', text: t }],
  });
  const p = (t: string) => ({ type: 'paragraph', content: [{ type: 'text', text: t }] });

  it('reads heading nodes', () => {
    const doc = {
      type: 'doc',
      content: [h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'), h('Agent detail'), p('d')],
    };
    expect(lintPlainBlockAdf(doc)).toEqual([]);
    expect(lintPlainBlockAdf({ type: 'doc', content: [p('x')] })).toHaveLength(4);
  });
});

describe('plainBlockVerdict', () => {
  it('refuses Task/Story/Bug, warns Epic/Subtask, passes when nothing is missing', () => {
    expect(plainBlockVerdict('Task', ['missing "## Why"']).action).toBe('refuse');
    expect(plainBlockVerdict('bug', ['x']).action).toBe('refuse');
    expect(plainBlockVerdict('Epic', ['x']).action).toBe('warn');
    expect(plainBlockVerdict('Subtask', ['x']).action).toBe('warn');
    expect(plainBlockVerdict('Task', []).action).toBe('ok');
  });
});
