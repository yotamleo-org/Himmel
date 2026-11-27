import { describe, it, expect } from 'vitest';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkWords, decisionsDirFor, GLOSS_OPENERS, namesKey, parseQuestion, renderQuestion, resolveDecision, shortAnswer } from './verbatim.js';

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

describe('namesKey', () => {
  const K = 'HIMMEL-10477';
  const bare = { bare: true };

  it('namesKey accepts 10477 and HIMMEL-10477 for HIMMEL-10477 and refuses PR 10477, decision 10477, #10477, SALUS-10477 and 110477', () => {
    expect(namesKey('ship 10477 now', K, bare)).toBe(true);
    expect(namesKey('ship HIMMEL-10477 now', K, bare)).toBe(true);
    for (const w of ['merge PR 10477', 'per decision 10477', 'see #10477', 'ship SALUS-10477', 'ship 110477']) {
      expect(namesKey(w, K, bare), w).toBe(false);
    }
  });

  it('bare: false accepts only the full key', () => {
    expect(namesKey('ship HIMMEL-10477 now', K, { bare: false })).toBe(true);
    expect(namesKey('ship 10477 now', K, { bare: false })).toBe(false);
    expect(namesKey('ship HIMMEL-104770', K, { bare: false })).toBe(false);
    expect(namesKey('ship XHIMMEL-10477', K, { bare: false })).toBe(false);
  });

  it('the excluded prefixes ignore spaces and case', () => {
    for (const w of ['pr 10477', 'PR10477', 'v 10477', 'V10477', 'pull 10477', 'Decision10477', '#  10477']) {
      expect(namesKey(w, K, bare), w).toBe(false);
    }
    expect(namesKey('PR 5 and 10477', K, bare)).toBe(true);
    expect(namesKey('dev 10477', K, bare)).toBe(true);
  });

  it('namesKey in bare mode refuses /pull/10477, PR: 10477, PRs 10477, 10477abc and 10477-other for HIMMEL-10477 and v1.1.3 for HIMMEL-3, and accepts 10477, 10477. and HIMMEL-10477', () => {
    for (const w of ['see /pull/10477 here', 'PR: 10477', 'PRs 10477 and 10478', 'ship 10477abc', 'ship 10477-other']) expect(namesKey(w, K, bare), w).toBe(false);
    expect(namesKey('ship v1.1.3 now', 'HIMMEL-3', bare)).toBe(false);
    for (const w of ['ship 10477', 'ship 10477.', 'ship HIMMEL-10477']) expect(namesKey(w, K, bare), w).toBe(true);
  });

  it('the key parts are escaped', () => {
    expect(namesKey('ship AXB-1', 'A.B-1', bare)).toBe(false);
    expect(namesKey('ship A.B-1', 'A.B-1', bare)).toBe(true);
  });
});

const ASKED = {
  subject: 'HIMMEL-1 round-critical C1', asked: '2026-11-27T06:10:00Z by chief',
  ask: ['the spec grants a spend; sign it as it stands, or revise it?'],
  options: [{ answer: 'a1', meaning: 'sign the spec exactly as it stands today' }, { answer: 'a2', meaning: 'revise the spec and run the critic again' }],
};
const blockFile = (answer: string, opts = ASKED.options) => `${renderQuestion({ ...ASKED, options: opts })}\n${answer}\n`;

describe('question block', () => {
  it('a rendered block parses and round-trips', () => {
    const r = parseQuestion(renderQuestion(ASKED));
    expect(r).toMatchObject({ ok: true, q: { ...ASKED, answer: null } });
  });

  it('a file without a block is none', () => {
    expect(parseQuestion(FILE)).toEqual({ none: true });
  });

  it('a malformed block is refused with a reason', () => {
    const b = renderQuestion(ASKED);
    const bad = [
      b.replace('Ask: ', 'Why: '),
      b.replace(/Option: a2.*\n/, ''),
      b.replace('Option: a2 =', 'Option: A1 ='),
      b.replace('Option: a2 =', `Option: ${'x'.repeat(20)} =`),
      b.replace('Option: a2 =', 'Option: a=b ='),
      `${b}\na1\n\nsomething the chief added later on\n`,
    ];
    for (const t of bad) expect(parseQuestion(t), t).toMatchObject({ ok: false, why: expect.any(String) });
  });

  it('blank lines of spaces and CRs end the block and the answer', () => {
    const t = `${renderQuestion(ASKED)} \t\na1\n  \r\nContext: a note\n`;
    expect(parseQuestion(t)).toMatchObject({ ok: true, q: { answer: 'a1' } });
    expect(shortAnswer(t, 'a1')).toEqual({ ok: true });
  });

  it('shortAnswer passes the answer paragraph in its norm variants', () => {
    for (const w of ['a1', 'A1.', '"a1"', '“a1”']) expect(shortAnswer(blockFile('a1'), w, 'HIMMEL-1'), w).toEqual({ ok: true });
    expect(shortAnswer(blockFile('yes 1.1.3', [{ answer: 'yes 1.1.3', meaning: 'place it in v1.1.3' }, { answer: 'no', meaning: 'leave it out' }]), 'yes 1.1.3')).toEqual({ ok: true });
  });

  it('shortAnswer refuses what is not the listed answer', () => {
    const mac = [{ answer: 'mac-ci no', meaning: 'skip the mac run' }, { answer: 'mac-ci yes', meaning: 'run it' }];
    expect(shortAnswer(blockFile('a1'), 'a3')).toMatchObject({ ok: false });
    expect(shortAnswer(blockFile('a1'), 'a2')).toMatchObject({ ok: false });
    expect(shortAnswer(blockFile('yes'), 'yes')).toMatchObject({ ok: false });
    expect(shortAnswer(blockFile('mac-ci no for now.', mac), 'mac-ci no for now.')).toMatchObject({ ok: false });
    expect(shortAnswer(blockFile('a1').replace('HIMMEL-1 round', 'HIMMEL-2 round'), 'a1', 'HIMMEL-1')).toMatchObject({ ok: false });
  });

  it('a1 on a bound file passes', () => {
    expect(checkWords(blockFile('a1'), 'a1')).toEqual({ ok: true });
  });

  it("words of the block's Option meaning are refused", () => {
    expect(checkWords(blockFile('a1'), 'sign the spec exactly as it stands today')).toMatchObject({ ok: false });
  });

  it('words of a Context note are refused', () => {
    expect(checkWords(`${blockFile('a1')}\nContext: the operator wants a longer test run\n`, 'the operator wants a longer test run')).toMatchObject({ ok: false });
  });

  it('words from a Question paragraph refused', () => {
    const f = 'Operator:\n\nok\n\nQuestion it answers: should the long migration run this week?\n';
    expect(checkWords(f, 'should the long migration run this week?'))
      .toMatchObject({ ok: false, why: expect.stringMatching(/sits only in a paragraph opening "Question"/) });
  });

  it('yes refused on an a1/a2 block answered yes', () => {
    expect(checkWords(blockFile('yes'), 'yes')).toMatchObject({ ok: false });
  });

  it("decision 1230's text passes with 10651 v1.1.3", () => {
    const f = `Operator, typed in chief console HIMMEL-nextleg-2026-11-22AY-recovery-chief, 2026-11-22 (file mtime is the true time), binding:\n\n10651 v1.1.3\n\nQuestion it answers (asked by the AY chief in the same console): the release manager refused R-v1.1.3-4978 placing HIMMEL-10651 (a refused guard-bypass launch after the operator's go reaches the operator's own chat, as a tamper signal) because the operator-directed ticket's source words ("tamper signal if possible") name no placement; reply "10651 v1.1.3" to place it in v1.1.3 or "10651 backlog" to leave it unplaced.\n\nReading: HIMMEL-10651 goes into v1.1.3.\n`;
    expect(checkWords(f, '10651 v1.1.3')).toEqual({ ok: true });
  });

  it('bare yes with no block still passes', () => {
    expect(checkWords('Operator:\n\nyes\n', 'yes')).toEqual({ ok: true });
  });

  it('a malformed block refuses every words string', () => {
    const t = `${renderQuestion(ASKED).replace('Ask: ', 'Why: ')}\nthe operator approves one more review round\n`;
    for (const w of ['the operator approves one more review round', 'a1']) expect(checkWords(t, w), w).toMatchObject({ ok: false });
  });
});
