import { describe, it, expect } from 'vitest';
import {
  lintPlainBlock,
  lintPlainBlockAdf,
  plainBlockVerdict,
  homeVerdict,
  titleSector,
  titleVerdict,
  TITLE_TEMPLATE,
  PLAIN_BLOCK_TEMPLATE,
} from './plain-block.js';

const OK =
  '## Impact\nOperators lose X.\n\n## What\nFix X.\n\n## Why\nIt hurts.\n\n## Plan\n1. Edit a.ts.\n\n## DoD\n- A test fails before and passes after.\n\n## Proof\nRun the suite: red before, green after.\n\n## Agent detail\nfiles: a.ts';

const NO_BULLET = 'has no bullet or numbered line beyond the placeholder';
const ONLY_PH = 'holds only a placeholder (TODO, TBD, N/A, an ellipsis or an <angle hint>)';

describe('lintPlainBlock', () => {
  it('passes a full block', () => expect(lintPlainBlock(OK)).toEqual([]));

  it('names every missing section on an empty body', () => {
    expect(lintPlainBlock('')).toEqual([
      'missing "## Impact"',
      'missing "## What"',
      'missing "## Why"',
      'missing "## Plan"',
      'missing "## DoD"',
      'missing "## Proof"',
      'missing "## Agent detail"',
    ]);
  });

  it('flags an empty section', () => {
    expect(lintPlainBlock(OK.replace('Fix X.', ''))).toEqual(['"## What" is empty']);
  });

  it('does not count a heading inside a code fence', () => {
    expect(lintPlainBlock('```\n' + OK + '\n```')).toHaveLength(7);
  });

  it('a shorter or different closing marker does not end a fence', () => {
    expect(lintPlainBlock('````\n```\n' + OK + '\n```')).toHaveLength(7);
    expect(lintPlainBlock('~~~\n```\n' + OK + '\n```')).toHaveLength(7);
    expect(lintPlainBlock('```\ncode\n```\n' + OK)).toEqual([]);
    expect(lintPlainBlock('```\n```not-a-close\n' + OK + '\n```')).toHaveLength(7);
  });

  it('a hash run with no space is text, not a heading', () => {
    const noSpace = OK.replace(/^## /gm, '##');
    expect(lintPlainBlock(noSpace)).toHaveLength(7);
  });

  it('the seven-section template alone fails on every section, so a skeleton never files as is', () => {
    expect(lintPlainBlock(PLAIN_BLOCK_TEMPLATE)).toEqual(
      ['Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'].map((s) => `"## ${s}" ${ONLY_PH}`),
    );
  });

  it('refuses a body with no DoD and names it', () => {
    expect(lintPlainBlock(OK.replace(/## DoD\n[^\n]*\n\n/, ''))).toEqual(['missing "## DoD"']);
  });

  it('refuses a body with no Plan and names it', () => {
    expect(lintPlainBlock(OK.replace(/## Plan\n[^\n]*\n\n/, ''))).toEqual(['missing "## Plan"']);
  });

  it('refuses a DoD that holds only the placeholder line', () => {
    const ph = OK.replace('- A test fails before and passes after.', '- <checkable result>');
    expect(lintPlainBlock(ph)).toEqual([`"## DoD" ${ONLY_PH}`]);
  });

  it('refuses Plan or DoD prose with no bullet or numbered line', () => {
    const prose = OK.replace('- A test fails before and passes after.', 'A test fails before.');
    expect(lintPlainBlock(prose)).toEqual([`"## DoD" ${NO_BULLET}`]);
  });

  it('accepts a real line next to a placeholder line', () => {
    expect(lintPlainBlock(OK.replace('1. Edit a.ts.', '1. <step>\n2. Edit a.ts.'))).toEqual([]);
  });
});

describe('lintPlainBlockAdf', () => {
  const h = (t: string) => ({
    type: 'heading',
    attrs: { level: 2 },
    content: [{ type: 'text', text: t }],
  });
  const p = (t: string) => ({ type: 'paragraph', content: [{ type: 'text', text: t }] });
  const list = (type: string, ts: string[]) => ({
    type,
    content: ts.map((t) => ({ type: 'listItem', content: [p(t)] })),
  });
  const ul = (...ts: string[]) => list('bulletList', ts);
  const ol = (...ts: string[]) => list('orderedList', ts);

  it('reads heading nodes', () => {
    const doc = {
      type: 'doc',
      content: [
        h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'),
        h('Plan'), ol('step'), h('DoD'), ul('check'), h('Proof'), p('run it'), h('Agent detail'), p('d'),
      ],
    };
    expect(lintPlainBlockAdf(doc)).toEqual([]);
    expect(lintPlainBlockAdf({ type: 'doc', content: [p('x')] })).toHaveLength(7);
  });

  it('agrees with the markdown path: list items count as lines, placeholders and prose do not', () => {
    const base = [h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'), h('Proof'), p('run it'), h('Agent detail'), p('d')];
    const doc = (plan: unknown[], dod: unknown[]) => ({
      type: 'doc',
      content: [...base, h('Plan'), ...plan, h('DoD'), ...dod],
    });
    const dodBad = [`"## DoD" ${NO_BULLET}`];
    expect(lintPlainBlockAdf(doc([ol('step')], [ul('<checkable result>')]))).toEqual([`"## DoD" ${ONLY_PH}`]);
    expect(lintPlainBlockAdf(doc([ol('step')], [p('only prose')]))).toEqual(dodBad);
    expect(lintPlainBlockAdf(doc([ol('<step>', 'real')], [ul('ok')]))).toEqual([]);
    expect(lintPlainBlockAdf(doc([], [ul('ok')]))).toEqual(['"## Plan" is empty']);
  });

  it('an empty paragraph under a section still leaves it empty', () => {
    const doc = { type: 'doc', content: [h('Impact'), p(''), h('What'), p('b'), h('Why'), p('c'), h('Plan'), ol('s'), h('DoD'), ul('d'), h('Proof'), p('run it'), h('Agent detail'), p('e')] };
    expect(lintPlainBlockAdf(doc)).toEqual(['"## Impact" is empty']);
  });

  it('a paragraph or code block that merely reads like a list line is not a list item', () => {
    const base = [h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'), h('Plan'), ol('step'), h('Proof'), p('run it'), h('Agent detail'), p('d')];
    const code = { type: 'codeBlock', content: [{ type: 'text', text: '- fake' }] };
    const dodBad = [`"## DoD" ${NO_BULLET}`];
    expect(lintPlainBlockAdf({ type: 'doc', content: [...base, h('DoD'), p('- fake')] })).toEqual(dodBad);
    expect(lintPlainBlockAdf({ type: 'doc', content: [...base, h('DoD'), code] })).toEqual(dodBad);
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

  it('names a missing Plan and DoD in the refusal and keeps an Epic warn-only', () => {
    const found = lintPlainBlock(
      OK.replace(/## Plan\n[^\n]*\n\n## DoD\n[^\n]*\n\n/, ''),
    );
    expect(plainBlockVerdict('Task', found).message).toMatch(/missing "## Plan"; missing "## DoD"/);
    expect(plainBlockVerdict('Epic', found).action).toBe('warn');
  });
});

describe('titleSector', () => {
  const live = ['Ship loop', 'Visibility', 'Cost & efficiency'];

  it('takes the canonical Sector from a valid "<Sector>: " prefix, case-insensitively', () => {
    expect(titleSector('Task', 'Visibility: show the board', live)).toEqual({ sector: 'Visibility' });
    expect(titleSector('Bug', 'cost & efficiency: fewer calls', live)).toEqual({ sector: 'Cost & efficiency' });
  });

  it('refuses a Task, Story or Bug whose prefix names no live option, listing the valid ones', () => {
    for (const t of ['Task', 'Story', 'Bug']) {
      const r = titleSector(t, 'Billing: charge the card', live);
      expect(r.sector).toBeUndefined();
      expect(r.refuse).toMatch(/refused.*"Billing:".*not a Sector.*Ship loop, Visibility, Cost & efficiency/s);
    }
  });

  it('derives nothing for a title with no prefix, a commit prefix, an Epic, or an unreadable option list', () => {
    expect(titleSector('Task', 'See which tickets are system work', live)).toEqual({});
    expect(titleSector('Task', 'feat(jira): add a thing', live)).toEqual({});
    expect(titleSector('Epic', 'Billing: charge the card', live)).toEqual({});
    expect(titleSector('Task', 'Visibility: x', [])).toEqual({});
  });
});

describe('homeVerdict', () => {
  const home = { sector: 'Ship loop', parent: 'HIMMEL-1', labels: [] as string[] };

  it('refuses a Task, Story or Bug with no Sector, naming the field and the fix', () => {
    for (const t of ['Task', 'Story', 'bug']) {
      const v = homeVerdict(t, { ...home, sector: undefined }, ['Ship loop', 'Visibility']);
      expect(v.action).toBe('refuse');
      expect(v.message).toMatch(/no Sector.*--sector "<Ship loop \| Visibility>".*sector setup --opt-out/s);
    }
  });

  it('drops the Sector check when sectors are not configured, keeping the epic-or-standalone check', () => {
    expect(homeVerdict('Task', { parent: 'HIMMEL-1', labels: [] }).action).toBe('ok');
    const v = homeVerdict('Task', { labels: [] });
    expect(v.action).toBe('refuse');
    expect(v.message).not.toMatch(/Sector/);
    expect(v.message).toMatch(/--parent.*--labels standalone/s);
  });

  it('refuses a Sector with neither a parent nor the standalone label, naming the marker', () => {
    const v = homeVerdict('Task', { sector: 'Ship loop', labels: ['x'] });
    expect(v.action).toBe('refuse');
    expect(v.message).toMatch(/--parent.*--labels standalone/s);
  });

  it('passes with a Sector and a parent, or with a Sector and the standalone label', () => {
    expect(homeVerdict('Task', home).action).toBe('ok');
    expect(homeVerdict('Task', { sector: 'Ship loop', labels: ['a', 'standalone'] }).action).toBe('ok');
    // Jira labels are case-sensitive, so a differently cased label is a different label.
    expect(homeVerdict('Task', { sector: 'Ship loop', labels: ['Standalone'] }).action).toBe('refuse');
  });

  it('only warns for an Epic or Subtask with neither', () => {
    expect(homeVerdict('Epic', { labels: [] }).action).toBe('warn');
    expect(homeVerdict('Subtask', { labels: [] }).action).toBe('warn');
    expect(homeVerdict('Epic', home).action).toBe('ok');
  });
});

describe('titleVerdict', () => {
  const FITTING = [
    'Ship loop: merge waits for the signed GO',
    'Safety & enforcement: edits on main are blocked in every worktree',
    'Tickets follow a title template',
    'See which tickets are system work and which change what a user sees',
  ];
  for (const t of FITTING) {
    it(`a fitting title does not warn: ${t}`, () => {
      expect(titleVerdict('Task', t)).toEqual({ action: 'ok', message: '' });
    });
  }

  const BREAKING: Array<[string, string, RegExp]> = [
    ['a conventional-commit prefix', 'feat(jira): add a title check', /commit prefix/],
    ['a bare commit prefix', 'fix: stale lock', /commit prefix/],
    ['a ticket id', 'Stop retrying HIMMEL-6778 twice', /ticket id/],
    ['a --flag', 'Create warns when --sector is missing', /internal name/],
    ['a snake_case field name', 'Read the fix_versions list', /internal name/],
    ['a backticked name', 'Rename `resolveTitle`', /internal name/],
    ['a file path', 'Edit scripts/jira/src/mcp.ts', /internal name/],
    ['an over-long title', 'x '.repeat(60).trim(), /long/],
    ['an empty title', '   ', /empty/],
    ['a sector with no result', 'Ship loop:  ', /no result/],
    ['an unknown sector prefix', 'Unknown sector: merge waits for approval', /not a Sector/],
    ['91 characters', 'x'.repeat(91), /at most 90/],
  ];
  for (const [why, t, re] of BREAKING) {
    it(`warns on ${why} and prints the template`, () => {
      const v = titleVerdict('Task', t);
      expect(v.action).toBe('warn');
      expect(v.message).toMatch(re);
      expect(v.message).toContain(TITLE_TEMPLATE);
    });
  }

  it('accepts exactly 90 characters', () => {
    expect(titleVerdict('Task', 'x'.repeat(90)).action).toBe('ok');
  });

  it('judges a sector-led title against the configured options', () => {
    expect(titleVerdict('Task', 'platform: requests finish safely', ['platform'])).toEqual({ action: 'ok', message: '' });
    const v = titleVerdict('Task', 'Ship loop: merge waits', ['platform']);
    expect(v.action).toBe('warn');
    expect(v.message).toContain('Sectors: platform');
  });

  it('warns for Story and Bug too, never refuses', () => {
    expect(titleVerdict('Story', 'feat: x').action).toBe('warn');
    expect(titleVerdict('Bug', 'feat: x').action).toBe('warn');
  });

  it('exempts Epic and Subtask silently', () => {
    expect(titleVerdict('Epic', 'feat(jira): x')).toEqual({ action: 'ok', message: '' });
    expect(titleVerdict('Subtask', 'HIMMEL-1 --flag')).toEqual({ action: 'ok', message: '' });
    expect(titleVerdict('Sub-task', 'fix: x').action).toBe('ok');
  });
});
