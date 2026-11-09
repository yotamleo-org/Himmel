import { describe, it, expect, vi, afterEach } from 'vitest';
import { markdownToAdf } from './adf.js';

describe('markdownToAdf', () => {
  it('empty string → doc with no content blocks', () => {
    const doc = markdownToAdf('');
    expect(doc).toEqual({ type: 'doc', version: 1, content: [] });
  });

  it('single paragraph', () => {
    const doc = markdownToAdf('Hello world');
    expect(doc.content).toHaveLength(1);
    expect(doc.content[0].type).toBe('paragraph');
  });

  it('two paragraphs separated by blank line', () => {
    const doc = markdownToAdf('First paragraph\n\nSecond paragraph');
    expect(doc.content).toHaveLength(2);
    expect(doc.content[0].type).toBe('paragraph');
    expect(doc.content[1].type).toBe('paragraph');
  });

  it('# Heading → heading block level 1', () => {
    const doc = markdownToAdf('# My Heading');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') {
      expect(block.attrs.level).toBe(1);
      expect(block.content[0]).toMatchObject({ type: 'text', text: 'My Heading' });
    }
  });

  it('## Heading → heading block level 2', () => {
    const doc = markdownToAdf('## Sub heading');
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') expect(block.attrs.level).toBe(2);
  });

  it('### Heading → heading block level 3', () => {
    const doc = markdownToAdf('### Deep heading');
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') expect(block.attrs.level).toBe(3);
  });

  it('```js code fence → codeBlock with language js', () => {
    const doc = markdownToAdf('```js\nconsole.log("hi");\n```');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('codeBlock');
    if (block.type === 'codeBlock') {
      expect(block.attrs).toMatchObject({ language: 'js' });
      expect(block.content[0].text).toBe('console.log("hi");');
    }
  });

  it('code fence without language → codeBlock with empty attrs', () => {
    const doc = markdownToAdf('```\nplain code\n```');
    const block = doc.content[0];
    expect(block.type).toBe('codeBlock');
    if (block.type === 'codeBlock') {
      expect(block.attrs).toEqual({});
    }
  });

  it('- item1\\n- item2 → bulletList with 2 listItems', () => {
    const doc = markdownToAdf('- item1\n- item2');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('bulletList');
    if (block.type === 'bulletList') {
      expect(block.content).toHaveLength(2);
      expect(block.content[0].type).toBe('listItem');
    }
  });

  it('1. a\\n2. b → orderedList with 2 listItems', () => {
    const doc = markdownToAdf('1. a\n2. b');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('orderedList');
    if (block.type === 'orderedList') {
      expect(block.content).toHaveLength(2);
    }
  });

  it('**bold** inline → text with strong mark', () => {
    const doc = markdownToAdf('**bold text**');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'bold text');
      expect(node?.marks).toEqual([{ type: 'strong' }]);
    }
  });

  it('`code` inline → text with code mark', () => {
    const doc = markdownToAdf('Use `console.log` here');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'console.log');
      expect(node?.marks).toEqual([{ type: 'code' }]);
    }
  });

  it('[text](http://x) inline → text with link mark + href', () => {
    const doc = markdownToAdf('[click here](http://example.com)');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'click here');
      expect(node?.marks).toEqual([{ type: 'link', attrs: { href: 'http://example.com' } }]);
    }
  });

  it('*italic* inline → text with em mark', () => {
    const doc = markdownToAdf('*italic text*');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'italic text');
      expect(node?.marks).toEqual([{ type: 'em' }]);
    }
  });

  it('unclosed code fence — produces valid codeBlock, emits warning to stderr', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      const doc = markdownToAdf('```js\nconsole.log("hi");');
      expect(doc.content).toHaveLength(1);
      const block = doc.content[0];
      expect(block.type).toBe('codeBlock');
      if (block.type === 'codeBlock') {
        expect(block.content[0].text).toBe('console.log("hi");');
      }
      expect(stderrSpy).toHaveBeenCalledWith(
        expect.stringContaining('unclosed code fence'),
      );
    } finally {
      stderrSpy.mockRestore();
    }
  });

  it('mixed: heading + paragraph + code block + list', () => {
    const md = [
      '# Title',
      '',
      'Some **bold** text.',
      '',
      '```ts',
      'const x = 1;',
      '```',
      '',
      '- alpha',
      '- beta',
    ].join('\n');

    const doc = markdownToAdf(md);
    expect(doc.content).toHaveLength(4);
    expect(doc.content[0].type).toBe('heading');
    expect(doc.content[1].type).toBe('paragraph');
    expect(doc.content[2].type).toBe('codeBlock');
    expect(doc.content[3].type).toBe('bulletList');
  });

  describe('heading levels', () => {
    it('#### to ###### are heading nodes with their level', () => {
      for (const [md, level] of [['#### h4', 4], ['##### h5', 5], ['###### h6', 6]] as const) {
        const doc = markdownToAdf(md);
        expect(doc.content).toHaveLength(1);
        const b = doc.content[0];
        expect(b.type).toBe('heading');
        if (b.type === 'heading') {
          expect(b.attrs.level).toBe(level);
          expect(b.content[0]).toMatchObject({ type: 'text', text: `h${level}` });
        }
      }
    });

    it('####### (7 hashes) is NOT a heading — falls through to paragraph', () => {
      const doc = markdownToAdf('####### too deep');
      expect(doc.content).toHaveLength(1);
      expect(doc.content[0].type).toBe('paragraph');
    });

    it('closing hashes are dropped: "## Proof ##" gives text "Proof"', () => {
      const b = markdownToAdf('## Proof ##').content[0];
      expect(b.type).toBe('heading');
      if (b.type === 'heading') {
        expect(b.attrs.level).toBe(2);
        expect(b.content).toEqual([{ type: 'text', text: 'Proof' }]);
      }
    });

    it('a hash glued to the text stays: "## C#" keeps "C#"', () => {
      const b = markdownToAdf('## C#').content[0];
      expect(b.type).toBe('heading');
      if (b.type === 'heading') expect(b.content[0]).toMatchObject({ text: 'C#' });
    });

    it('heading.attrs.level is always 1 to 6', () => {
      for (const md of ['# h1', '## h2', '### h3', '#### h4', '##### h5', '###### h6']) {
        const b = markdownToAdf(md).content[0];
        expect(b.type).toBe('heading');
        if (b.type === 'heading') expect([1, 2, 3, 4, 5, 6]).toContain(b.attrs.level);
      }
    });
  });

  describe('code fence parity with the ticket policy', () => {
    const code = (md: string) => markdownToAdf(md).content;

    it('a ~~~ fence opens a codeBlock with its language', () => {
      const c = code('~~~sh\necho hi\n~~~');
      expect(c).toHaveLength(1);
      expect(c[0]).toMatchObject({ type: 'codeBlock', attrs: { language: 'sh' } });
    });

    it('a fence indented up to 3 spaces opens; 4 spaces does not', () => {
      expect(code('   ```\nx\n   ```')[0].type).toBe('codeBlock');
      expect(code('    ```\nx')[0].type).toBe('paragraph');
    });

    it('a backtick fence with a backtick in its info string is not a fence', () => {
      const c = code('``` foo`bar\ntext');
      expect(c).toHaveLength(1);
      expect(c[0].type).toBe('paragraph');
    });

    it('a tilde fence may carry a backtick in its info string', () => {
      expect(code('~~~ a`b\nx\n~~~')[0].type).toBe('codeBlock');
    });

    it('a 4-backtick fence holds ``` inside and closes only on 4+', () => {
      const c = code('````md\n```\ninner\n```\n````\nafter');
      expect(c).toHaveLength(2);
      expect(c[0]).toMatchObject({
        type: 'codeBlock',
        attrs: { language: 'md' },
        content: [{ type: 'text', text: '```\ninner\n```' }],
      });
      expect(c[1].type).toBe('paragraph');
    });

    it('~~~ inside a backtick fence does not close it', () => {
      const c = code('```\na\n~~~\nb\n```');
      expect(c).toHaveLength(1);
      expect(c[0]).toMatchObject({ content: [{ text: 'a\n~~~\nb' }] });
    });

    it('a closing fence with trailing text does not close', () => {
      const c = code('```\na\n``` x\nb\n```');
      expect(c).toHaveLength(1);
      expect(c[0]).toMatchObject({ content: [{ text: 'a\n``` x\nb' }] });
    });

    it('a closing fence may have trailing whitespace', () => {
      const c = code('```\na\n```  \nafter');
      expect(c).toHaveLength(2);
    });

    it('language is the first word of the info string', () => {
      expect(code('```js title="x"\nx\n```')[0]).toMatchObject({ attrs: { language: 'js' } });
    });

    it('an unclosed ~~~ fence warns and keeps the remainder as code', () => {
      const spy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
      try {
        const c = code('~~~\nx');
        expect(c[0]).toMatchObject({ type: 'codeBlock', content: [{ text: 'x' }] });
        expect(spy).toHaveBeenCalledWith(expect.stringContaining('unclosed code fence'));
      } finally {
        spy.mockRestore();
      }
    });

    it('a ~~~ fence interrupts a paragraph', () => {
      const c = code('text\n~~~\ncode\n~~~');
      expect(c.map((b) => b.type)).toEqual(['paragraph', 'codeBlock']);
    });
  });

  describe('underscores inside identifiers', () => {
    const inline = (md: string) => {
      const b = markdownToAdf(md).content[0];
      if (b.type !== 'paragraph') throw new Error('not a paragraph');
      return b.content;
    };

    it.each(['HIMMEL_API_LANE', 'CR_SCORES_MIN_N', 'worker_tail_status', 'snake_case_name'])(
      '%s stays literal text with no mark',
      (id) => {
        expect(inline(`see ${id} here`)).toEqual([{ type: 'text', text: `see ${id} here` }]);
      },
    );

    it('two identifiers in one line stay literal', () => {
      expect(inline('HIMMEL_API_LANE and CR_SCORES_MIN_N')).toEqual([
        { type: 'text', text: 'HIMMEL_API_LANE and CR_SCORES_MIN_N' },
      ]);
    });

    it('a standalone _word_ is still italic', () => {
      expect(inline('a _word_ b')).toEqual([
        { type: 'text', text: 'a ' },
        { type: 'text', text: 'word', marks: [{ type: 'em' }] },
        { type: 'text', text: ' b' },
      ]);
    });

    it('_word_ in parentheses or alone on the line is italic', () => {
      expect(inline('(_a_)')[1]).toEqual({ type: 'text', text: 'a', marks: [{ type: 'em' }] });
      expect(inline('_a_')).toEqual([{ type: 'text', text: 'a', marks: [{ type: 'em' }] }]);
    });

    it('an identifier next to a real _word_ keeps both right', () => {
      expect(inline('FOO_BAR_BAZ and _real_')).toEqual([
        { type: 'text', text: 'FOO_BAR_BAZ and ' },
        { type: 'text', text: 'real', marks: [{ type: 'em' }] },
      ]);
    });

    it('intraword __x__ is literal, standalone __x__ is bold', () => {
      expect(inline('a__b__c')).toEqual([{ type: 'text', text: 'a__b__c' }]);
      expect(inline('a __b__ c')[1]).toEqual({ type: 'text', text: 'b', marks: [{ type: 'strong' }] });
    });

    it('asterisk emphasis is unchanged, including intraword', () => {
      expect(inline('a*b*c')[1]).toEqual({ type: 'text', text: 'b', marks: [{ type: 'em' }] });
      expect(inline('a **b** c')[1]).toEqual({ type: 'text', text: 'b', marks: [{ type: 'strong' }] });
    });

    it('underscores inside a list item identifier stay literal', () => {
      const b = markdownToAdf('- set HIMMEL_API_LANE=1').content[0];
      expect(b.type).toBe('bulletList');
      if (b.type === 'bulletList') {
        expect(b.content[0].content[0].content).toEqual([{ type: 'text', text: 'set HIMMEL_API_LANE=1' }]);
      }
    });
  });

  describe('inline-mark regex documented limitations', () => {
    it('nested bold + italic (**bold *and italic***) parses ambiguously — documented as out-of-spec', () => {
      const doc = markdownToAdf('**bold *and italic***');
      const p = doc.content[0];
      expect(p.type).toBe('paragraph');
      if (p.type === 'paragraph') {
        expect(p.content.length).toBeGreaterThan(0);
        // No node should have BOTH strong and em marks (no recursion).
        for (const node of p.content) {
          if ('marks' in node && node.marks) {
            const types = node.marks.map((m) => m.type).sort();
            expect(types).not.toEqual(['em', 'strong']);
          }
        }
      }
    });

    it('escaped delimiters (\\*not italic\\*) are NOT escaped — parsed by current regex', () => {
      const doc = markdownToAdf('\\*not italic\\*');
      const p = doc.content[0];
      expect(p.type).toBe('paragraph');
      if (p.type === 'paragraph') {
        expect(p.content.length).toBeGreaterThan(0);
      }
    });
  });
});

describe('list markers the ticket policy counts', () => {
  it('a + bullet and a 1) item are list nodes, so a body that passes the policy keeps its list in Jira', () => {
    const doc = markdownToAdf('## DoD\n+ the row is green\n\n## Plan\n1) write it\n2) test it');
    expect(doc.content.map((n) => n.type)).toEqual(['heading', 'bulletList', 'heading', 'orderedList']);
  });

  it('a bare section-name line is a heading node', () => {
    const doc = markdownToAdf('Proof\nRun it on a real draft.');
    expect(doc.content.map((n) => n.type)).toEqual(['heading', 'paragraph']);
  });
});
