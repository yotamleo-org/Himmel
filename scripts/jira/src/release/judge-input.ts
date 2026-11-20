import type { IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';

export const KEY_IN = /[A-Z][A-Z0-9]*-\d+(?!\d)/g;

export type JudgeOperatorSettings = { floorBytes: number; others: number; rulings: number; recent: number };

export const JUDGE_OPERATOR: Readonly<JudgeOperatorSettings> = Object.freeze({ floorBytes: 150_000, others: 5, rulings: 1000, recent: 30 });

const ALWAYS = new Set(['emergency', 'blocker-pull', 'delivered-follows-merge']);
const DECISION_LIST = /\bdecisions?[ \t\n\r\f\v]+(\d+(?:[ \t\n\r\f\v]*(?:,|and|to|-|–)[ \t\n\r\f\v]*\d+)*)/gi;
const LIST_TOKEN = /\d+|to|-|–/gi;
const NUMBER = /^\d+$/;
const RANGE_WORDS = new Set(['to', '-', '–']);

function decisionNumbers(text: string, into: Set<string>): void {
  for (const m of text.matchAll(DECISION_LIST)) {
    const tokens = (m[1].match(LIST_TOKEN) ?? []).map((t) => t.toLowerCase());
    let i = 0;
    while (i < tokens.length) {
      if (NUMBER.test(tokens[i])) {
        if (i + 2 < tokens.length && RANGE_WORDS.has(tokens[i + 1]) && NUMBER.test(tokens[i + 2])) {
          const lo = BigInt(tokens[i]);
          const hi = BigInt(tokens[i + 2]);
          if (hi >= lo && hi - lo <= BigInt(100)) for (let n = lo; n <= hi; n++) into.add(String(n));
          else { into.add(tokens[i]); into.add(tokens[i + 2]); }
          i += 3;
          continue;
        }
        into.add(tokens[i]);
      }
      i++;
    }
  }
}

export function judgeOperatorRows(
  release: string, operator: OperatorRow[], asked: RequestRow[], issues: IssueSnap[], receipted: RulingRow[],
  settings: JudgeOperatorSettings = JUDGE_OPERATOR,
): OperatorRow[] {
  const bytes = Buffer.byteLength(JSON.stringify(operator.map(({ mac: _mac, prev: _prev, ...r }) => r)));
  if (bytes < settings.floorBytes) return operator;

  const askedKeys = new Set(asked.map((q) => q.key));
  const recordId = new RegExp('O-' + release.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*', 'g');
  const tickets = new Set(askedKeys);
  const records = new Set<string>();
  const decisions = new Set<string>();
  const read = (text: string): void => {
    for (const k of text.match(KEY_IN) ?? []) tickets.add(k);
    for (const id of text.match(recordId) ?? []) records.add(id);
    decisionNumbers(text, decisions);
  };
  for (const q of asked) read((q.why ?? '') + ' ' + JSON.stringify(q.evidence ?? null));
  for (const r of receipted) if (askedKeys.has(r.key)) read(r.reason + ' ' + r.ground);
  for (const i of issues) {
    if (!askedKeys.has(i.key)) continue;
    if (i.parent) tickets.add(i.parent);
    for (const b of i.blockedBy ?? []) tickets.add(b);
  }

  const citedBy = new Map<string, Set<string>>();
  for (const r of receipted.slice(-settings.rulings)) {
    for (const id of new Set((r.reason + ' ' + r.ground).match(recordId) ?? [])) {
      const set = citedBy.get(id) ?? new Set<string>();
      set.add(r.key);
      citedBy.set(id, set);
    }
  }
  const recent = new Set(settings.recent ? operator.filter((o) => o.kind === 'decision').slice(-settings.recent).map((o) => o.id) : []);

  return operator.filter((o) => {
    const own = o.keys ?? [];
    if (!own.length || ALWAYS.has(o.kind) || own.some((k) => tickets.has(k)) || records.has(o.id) || decisions.has(String(o.decision))) return true;
    const others = [...(citedBy.get(o.id) ?? [])].filter((k) => !own.includes(k));
    return others.length >= settings.others || recent.has(o.id);
  });
}
