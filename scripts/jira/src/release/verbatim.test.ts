import { describe, it, expect } from 'vitest';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkWords, decisionsDirFor, GLOSS_OPENERS, resolveDecision } from './verbatim.js';

const FILE = 'Operator, verbatim:\n\n"Approved one more round"\n\nAnswering the ask on HIMMEL-1: stop and park.\n';

describe('checkWords', () => {
  it('words in an operator paragraph pass', () => {
    expect(checkWords(FILE, 'Approved one more round')).toEqual({ ok: true });
  });

  it('words in a gloss paragraph fail', () => {
    expect(checkWords(FILE, 'stop and park')).toMatchObject({ ok: false, why: expect.stringMatching(/not the operator's/) });
  });

  it('a quoted chief ask in a gloss fails', () => {
    const f = 'Operator:\n\n"yes"\n\nAsked by XX: "my default is to move them all"\n';
    expect(checkWords(f, 'my default is to move them all')).toMatchObject({ ok: false });
  });

  it('every opener is a gloss', () => {
    const words = 'the words that need checking here';
    for (const opener of GLOSS_OPENERS) {
      const r = checkWords(`Operator:\n\n${opener} ${words}\n`, words);
      expect(r, opener).toMatchObject({ ok: false, why: expect.stringMatching(/not the operator's/) });
    }
  });

  it('an opener is a whole word', () => {
    expect(checkWords('Ready to go, approve it now please\n', 'Ready to go, approve it now please')).toEqual({ ok: true });
    expect(checkWords('Readings: approve it now please today\n', 'approve it now please today')).toMatchObject({ ok: false });
    expect(checkWords('Rulings: approve it now please today\n', 'approve it now please today')).toMatchObject({ ok: false });
  });

  it('short words must be a whole paragraph', () => {
    expect(checkWords('Operator:\n\n"yes"\n\nRead: a go for the move.\n', 'yes')).toEqual({ ok: true });
    expect(checkWords('Operator:\n\nkeep it in the version for now\n', 'keep'))
      .toMatchObject({ ok: false, why: expect.stringMatching(/at least 20 characters/) });
  });

  it('every occurrence must be outside a gloss', () => {
    const f = 'Operator:\n\nmove it into the next version\n\nRead: move it into the next version, and park the rest.\n';
    expect(checkWords(f, 'move it into the next version')).toMatchObject({ ok: false, why: expect.stringMatching(/not the operator's/) });
  });

  it('words across a blank line fail', () => {
    const f = 'Operator:\n\nfirst line of the words\n\nsecond line of the words\n';
    expect(checkWords(f, 'first line of the words\n\nsecond line of the words')).toMatchObject({ ok: false, why: expect.stringMatching(/one paragraph/) });
  });

  it('absent words fail', () => {
    expect(checkWords(FILE, 'Approved two more rounds')).toMatchObject({ ok: false, why: expect.stringMatching(/not in/) });
  });

  it('empty words fail', () => {
    expect(checkWords(FILE, '')).toMatchObject({ ok: false, why: expect.stringMatching(/empty/) });
    expect(checkWords(FILE, '   ')).toMatchObject({ ok: false, why: expect.stringMatching(/empty/) });
  });
});

describe('resolveDecision', () => {
  it('resolveDecision matches the exact number', () => {
    const dir = mkdtempSync(join(tmpdir(), 'verbatim-'));
    writeFileSync(join(dir, 'verbatim-decision-45-a.txt'), 'forty-five\n');
    writeFileSync(join(dir, 'verbatim-decision-454-b.txt'), 'four five four\n');
    const got = resolveDecision(dir, '45');
    expect(got).toEqual({
      path: join(dir, 'verbatim-decision-45-a.txt'), rel: 'specs/decisions/verbatim-decision-45-a.txt',
      sha256: createHash('sha256').update('forty-five\n').digest('hex'), text: 'forty-five\n',
    });
    expect(() => resolveDecision(dir, '99')).toThrow(/no verbatim file/);
    writeFileSync(join(dir, 'verbatim-decision-454-c.txt'), 'again\n');
    expect(() => resolveDecision(dir, '454')).toThrow(/2 files/);
  });

  it('a decision number is digits only', () => {
    const dir = mkdtempSync(join(tmpdir(), 'verbatim-'));
    expect(() => resolveDecision(dir, '4*')).toThrow(/a number/);
  });

  it('decisionsDirFor is the bucket specs/decisions two levels above the release dir', () => {
    expect(decisionsDirFor('/b/user/repo/release/v1.1.3')).toBe('/b/user/repo/specs/decisions');
  });
});
