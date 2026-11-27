import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const GLOSS_OPENERS: readonly string[] = [
  'Read', 'Reading', 'Readings', 'Chief', "Chief's", 'Context', 'Asked', 'Answering', 'Note', 'Ruling', 'Rulings',
  'Relayed', 'Facts', 'Replying', '(chief', '[pasted',
];

export const MIN_WORDS = 20;
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const GLOSS = new RegExp(`^(?:${GLOSS_OPENERS.map(escapeRe).join('|')})(?![\\w'])`);
const QUESTION = /^Question(?![\w'])/;
const BLANK = /\r?\n[ \t]*\r?\n/;

export const normText = (s: string) => s.replace(/\s+/g, ' ').trim();
export const isShort = (s: string) => normText(s).length < MIN_WORDS;
export const namesKeyToken = (text: string, key: string) => new RegExp(`(?<![A-Za-z0-9])${key}(?![A-Za-z0-9])`).test(text);

function unquoted(p: string): string {
  const pairs: Array<[string, string]> = [['"', '"'], ['“', '”'], ["'", "'"]];
  const hit = pairs.find(([a, b]) => p.length >= 2 && p.startsWith(a) && p.endsWith(b));
  return hit ? p.slice(1, -1).trim() : p;
}

const norm = (s: string) => unquoted(normText(s)).toLowerCase().replace(/[.!]$/, '');

export type Question = {
  subject: string; asked: string | null; ask: string[];
  options: { answer: string; meaning: string }[]; answer: string | null;
};
type Parsed = { none: true } | { ok: true; q: Question } | { ok: false; why: string };

function splitBlock(text: string): { head: string[]; paras: string[] } {
  const lines = text.split('\n').map((l) => l.replace(/\r$/, ''));
  const end = lines.findIndex((l) => /^[ \t]*$/.test(l));
  const head = end < 0 ? lines : lines.slice(0, end);
  const rest = end < 0 ? '' : lines.slice(end).join('\n');
  return { head, paras: rest.split(/\n[ \t]*(?=\n)/).map((x) => x.trim()).filter(Boolean) };
}

export function parseQuestion(text: string): Parsed {
  if (!text.startsWith('Question: ')) return { none: true };
  const { head, paras } = splitBlock(text);
  const bad = (why: string) => ({ ok: false as const, why });
  const q: Question = { subject: head[0].slice('Question: '.length).trim(), asked: null, ask: [], options: [], answer: null };
  if (!q.subject) return bad('the Question line is empty');
  for (const line of head.slice(1)) {
    const m = /^(Asked|Ask|Option): (.*\S)\s*$/.exec(line);
    if (!m) return bad(`unknown block line "${line.slice(0, 40)}"`);
    if (m[1] === 'Asked') {
      if (q.asked !== null) return bad('two Asked lines');
      q.asked = m[2];
    } else if (m[1] === 'Ask') {
      q.ask.push(m[2]);
    } else {
      const at = m[2].indexOf(' = ');
      const answer = at < 0 ? '' : m[2].slice(0, at).trim();
      const meaning = at < 0 ? '' : m[2].slice(at + 3).trim();
      if (!norm(answer) || !meaning) return bad(`an Option line is not "<answer> = <meaning>": "${line.slice(0, 40)}"`);
      if (answer.includes('=')) return bad(`the answer "${answer}" holds "="`);
      if (!isShort(answer)) return bad(`the answer "${answer}" is ${MIN_WORDS} characters or more`);
      if (q.options.some((o) => norm(o.answer) === norm(answer))) return bad(`the answer "${answer}" is listed twice`);
      q.options.push({ answer, meaning });
    }
  }
  if (!q.ask.length) return bad('no Ask line');
  if (q.options.length < 2) return bad('fewer than two Option lines');
  const [first, ...later] = paras;
  if (first !== undefined) {
    if (GLOSS.test(first) || QUESTION.test(first)) return bad('the answer paragraph opens as a chief note');
    q.answer = first;
  }
  if (later.some((x) => !GLOSS.test(x))) return bad('a paragraph after the answer is not a chief note');
  return { ok: true, q };
}

export function renderQuestion(q: Omit<Question, 'answer'>): string {
  const lines = [
    `Question: ${q.subject}`,
    ...(q.asked === null ? [] : [`Asked: ${q.asked}`]),
    ...q.ask.map((a) => `Ask: ${a}`),
    ...q.options.map((o) => `Option: ${o.answer} = ${o.meaning}`),
  ];
  return `${lines.join('\n')}\n`;
}

export function shortAnswer(text: string, quote: string, key?: string): { ok: true } | { ok: false; why: string } {
  const p = parseQuestion(text);
  if ('none' in p) return { ok: false, why: 'no Question block' };
  if (!p.ok) return { ok: false, why: p.why };
  if (p.q.answer === null) return { ok: false, why: 'the block has no answer paragraph' };
  if (key !== undefined && !namesKeyToken(p.q.subject, key)) return { ok: false, why: `the Question line does not name ${key}` };
  if (norm(p.q.answer) !== norm(quote)) return { ok: false, why: 'it is not the answer paragraph' };
  if (!p.q.options.some((o) => norm(o.answer) === norm(quote))) return { ok: false, why: 'it is not a listed option' };
  return { ok: true };
}

export function checkWords(text: string, words: string): { ok: true } | { ok: false; why: string } {
  if (!words.trim()) return { ok: false, why: '--words is empty; name the operator\'s exact words' };
  if (/\n[ \t]*\r?\n/.test(words)) return { ok: false, why: 'the words span a blank line; cite them from one paragraph' };
  const parsed = parseQuestion(text);
  if ('ok' in parsed && !parsed.ok) return { ok: false, why: `the decision file has a Question block that does not hold (${parsed.why})` };
  if ('ok' in parsed && isShort(words)) {
    const r = shortAnswer(text, words);
    return r.ok ? r : { ok: false, why: `"${words}" does not answer the recorded question (${r.why})` };
  }
  const paragraphs = 'none' in parsed ? text.split(BLANK).map((p) => p.trim()) : splitBlock(text).paras;
  if ('ok' in parsed && !normText(parsed.q.answer ?? '').includes(normText(words))) {
    return { ok: false, why: `"${words}" is not in the answer paragraph of the Question block` };
  }
  const cited = paragraphs.filter((p) => p.includes(words));
  const holding = cited.filter((p) => !QUESTION.test(p));
  if (!holding.length) {
    return { ok: false, why: cited.length ? `"${words}" sits only in a paragraph opening "Question", the chief's question, not the operator's answer` : `"${words}" is not in the decision file` };
  }
  const gloss = holding.find((p) => GLOSS.test(p));
  if (gloss) {
    return { ok: false, why: `the words are not the operator's: they sit in a paragraph opening "${gloss.slice(0, 40)}", which is the chief's gloss` };
  }
  if (isShort(words) && !holding.some((p) => unquoted(p) === words)) {
    return { ok: false, why: `"${words}" is shorter than ${MIN_WORDS} characters and not a whole paragraph; name at least 20 characters of the operator's words` };
  }
  return { ok: true };
}

export function namesKey(words: string, key: string, o: { bare: boolean }): boolean {
  if (new RegExp(`\\b${escapeRe(key)}(?!\\d)`).test(words)) return true;
  const n = /-(\d+)$/.exec(key)?.[1];
  if (!o.bare || !n) return false;
  for (const m of words.matchAll(new RegExp(`(?<![A-Za-z0-9./-])${n}(?![A-Za-z0-9-])`, 'g'))) {
    if (!/(?:#|\b(?:prs?|pulls?|decisions?|v)\s*:?)\s*$/i.test(words.slice(0, m.index))) return true;
  }
  return false;
}

export const decisionsDirFor = (releaseDir: string): string => join(dirname(dirname(releaseDir)), 'specs', 'decisions');

export function resolveDecision(decisionsDir: string, n: string): { path: string; rel: string; sha256: string; text: string } {
  if (!/^\d+$/.test(n)) throw new Error(`--decision ${n}: a decision is a number`);
  let names: string[];
  try {
    names = readdirSync(decisionsDir);
  } catch {
    names = [];
  }
  const hits = names.filter((x) => x.startsWith(`verbatim-decision-${n}-`)).sort();
  if (!hits.length) throw new Error(`--decision ${n}: no verbatim file verbatim-decision-${n}-*.txt in ${decisionsDir}`);
  if (hits.length > 1) throw new Error(`--decision ${n}: ${hits.length} files match in ${decisionsDir} (${hits.join(', ')}); one decision has one file`);
  const path = join(decisionsDir, hits[0]);
  const bytes = readFileSync(path);
  return { path, rel: `specs/decisions/${hits[0]}`, sha256: createHash('sha256').update(bytes).digest('hex'), text: bytes.toString('utf8') };
}
