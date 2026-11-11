import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const GLOSS_OPENERS: readonly string[] = [
  'Read', 'Reading', 'Readings', 'Chief', "Chief's", 'Context', 'Asked', 'Answering', 'Note', 'Ruling', 'Rulings',
  'Relayed', 'Facts', 'Replying', '(chief', '[pasted',
];

const MIN_WORDS = 20;
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const GLOSS = new RegExp(`^(?:${GLOSS_OPENERS.map(escapeRe).join('|')})(?![\\w'])`);

function unquoted(p: string): string {
  const pairs: Array<[string, string]> = [['"', '"'], ['“', '”'], ["'", "'"]];
  const hit = pairs.find(([a, b]) => p.length >= 2 && p.startsWith(a) && p.endsWith(b));
  return hit ? p.slice(1, -1).trim() : p;
}

export function checkWords(text: string, words: string): { ok: true } | { ok: false; why: string } {
  if (!words.trim()) return { ok: false, why: '--words is empty; name the operator\'s exact words' };
  if (/\n[ \t]*\r?\n/.test(words)) return { ok: false, why: 'the words span a blank line; cite them from one paragraph' };
  const holding = text.split(/\r?\n[ \t]*\r?\n/).map((p) => p.trim()).filter((p) => p.includes(words));
  if (!holding.length) return { ok: false, why: `"${words}" is not in the decision file` };
  const gloss = holding.find((p) => GLOSS.test(p));
  if (gloss) {
    return { ok: false, why: `the words are not the operator's: they sit in a paragraph opening "${gloss.slice(0, 40)}", which is the chief's gloss` };
  }
  if (words.length < MIN_WORDS && !holding.some((p) => unquoted(p) === words)) {
    return { ok: false, why: `"${words}" is shorter than ${MIN_WORDS} characters and not a whole paragraph; name at least 20 characters of the operator's words` };
  }
  return { ok: true };
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
