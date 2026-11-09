
export const SECTIONS = ['Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'];

const LIST_SECTIONS = new Set(['Plan', 'DoD']);

const HINTS = {
  Impact: '<who notices, and what they see today — plain words, no file paths>',
  What: '<what we change, in one or two sentences>',
  Why: '<why it is worth doing now>',
  Plan: '1. <one to five bounded steps, each naming the surface it touches>',
  DoD: '- <one to five checkable results: a test, a command and its output, a doc section, a Jira state>',
  Proof: '<the planned verification: the real user path for a feature, a RED case and its negative control for a guard, the detection check for hygiene>',
  'Agent detail': '<files, contract, suites>',
};

/** The seven-section skeleton; every hint is a placeholder, so an unfilled skeleton is refused. */
export function renderTicketSkeleton() {
  return SECTIONS.map((s) => `## ${s}\n${HINTS[s]}`).join('\n\n');
}

/** Epic is a container and a Subtask inherits its parent's framing: their findings are warnings. */
export function isWarnOnlyType(type) {
  return ['epic', 'subtask', 'sub-task'].includes(String(type ?? '').trim().toLowerCase());
}

/** The label families whose ticket must name the stability-scorecard metric it moves. */
export const METRIC_LABEL = /^(ci|guard|guardrail|stability|flake)(-[a-z0-9-]+)?$/i;

export function needsMetric(labels) {
  return (labels ?? []).some((l) => METRIC_LABEL.test(String(l).trim()));
}

const TICKET_KEY = /\b[A-Z][A-Z0-9]+-[0-9]+\b/g;
const LIST_LINE = /^\s*(?:[-*+]|\d+[.)])\s+(\S.*?)\s*$/;
const HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const BOLD_LINE = /^\s*(\*\*|__)([^*_]+?)\1\s*:?\s*$/;

/** True when a value is a placeholder: empty, TODO/TBD/TBC/N/A/none, dots or an ellipsis, question marks, dashes, an <angle hint>. */
export function isPlaceholder(value) {
  let s = String(value ?? '').trim();
  s = s.replace(/^\s*(?:[-*+]|\d+[.)])\s+/, '');
  s = s.replace(/[*_`]/g, '').trim();
  s = s.replace(/[\s.:;,!]+$/, '').trim().toLowerCase();
  if (s === '') return true;
  if (/^<[^>]*>$/.test(s)) return true;
  if (/^(todo|tbd|tbc|n\/a|na|none|wip|placeholder|fill ?in|fill me in)$/.test(s)) return true;
  if (/^(todo|tbd|tbc)\b[\s:-]*$/.test(s)) return true;
  return /^(\.+|…+|\?+|-+|—+)$/.test(s);
}

function sectionOf(text) {
  const w = String(text ?? '').replace(/[*_`]/g, '').replace(/:\s*$/, '').trim().toLowerCase();
  return SECTIONS.find((s) => s.toLowerCase() === w);
}

/**
 * Markdown to blocks. A fence opens on 3+ backticks or tildes indented at most
 * three spaces; a backtick fence whose info string holds a backtick is not a
 * fence (CommonMark). It closes only on the same character, at least as long,
 * with nothing after it.
 */
export function normalizeMarkdown(md) {
  const out = [];
  let fence = '';
  for (const line of String(md ?? '').split(/\r?\n/)) {
    const fm = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (fm && fm[1][0] === fence[0] && fm[1].length >= fence.length && fm[2].trim() === '') {
        fence = '';
        continue;
      }
      out.push({ kind: 'code', text: line });
      continue;
    }
    if (fm && !(fm[1][0] === '`' && fm[2].includes('`'))) {
      fence = fm[1];
      continue;
    }
    if (line.trim() === '') continue;
    const h = HEADING.exec(line);
    if (h) {
      out.push({ kind: 'heading', level: h[1].length, text: h[2] ?? '' });
      continue;
    }
    const li = LIST_LINE.exec(line);
    if (li) {
      out.push({ kind: 'list', text: li[1] });
      continue;
    }
    out.push({ kind: 'prose', text: line.trim(), bold: BOLD_LINE.test(line) });
  }
  return out;
}

function adfText(n) {
  if (!n || typeof n !== 'object') return '';
  return (typeof n.text === 'string' ? n.text : '') + (Array.isArray(n.content) ? n.content.map(adfText).join('') : '');
}

function adfBold(n) {
  const leaves = [];
  const walk = (x) => {
    if (!x || typeof x !== 'object') return;
    if (typeof x.text === 'string' && x.text.trim()) leaves.push(x);
    if (Array.isArray(x.content)) x.content.forEach(walk);
  };
  walk(n);
  return leaves.length > 0 && leaves.every((l) => (l.marks ?? []).some((m) => m?.type === 'strong'));
}

/** ADF to the same blocks: heading nodes, list items (nested lists flattened), code blocks, everything else prose. */
export function normalizeAdf(doc) {
  const out = [];
  const visit = (n) => {
    if (!n || typeof n !== 'object') return;
    switch (n.type) {
      case 'heading':
        out.push({ kind: 'heading', level: Number(n.attrs?.level ?? 1), text: adfText(n) });
        return;
      case 'bulletList':
      case 'orderedList':
        for (const item of n.content ?? []) {
          const own = (item.content ?? []).filter((c) => c?.type !== 'bulletList' && c?.type !== 'orderedList');
          const text = own.map(adfText).join(' ').trim();
          if (text) out.push({ kind: 'list', text });
          for (const c of item.content ?? []) if (c?.type === 'bulletList' || c?.type === 'orderedList') visit(c);
        }
        return;
      case 'codeBlock':
        for (const line of adfText(n).split('\n')) if (line.trim()) out.push({ kind: 'code', text: line });
        return;
      case 'paragraph':
      case 'blockquote':
      case 'panel':
      default: {
        if (n.type !== 'paragraph' && Array.isArray(n.content) && n.content.some((c) => c && typeof c === 'object' && c.type && c.type !== 'text' && c.type !== 'hardBreak')) {
          n.content.forEach(visit);
          return;
        }
        const bold = adfBold(n);
        for (const line of adfText(n).split('\n')) if (line.trim()) out.push({ kind: 'prose', text: line.trim(), bold });
      }
    }
  };
  for (const n of (doc && typeof doc === 'object' && Array.isArray(doc.content) ? doc.content : [])) visit(n);
  return out;
}

export function normalizeBody(input) {
  return input?.format === 'adf' ? normalizeAdf(input.body) : normalizeMarkdown(input?.body ?? '');
}

function sectionsOf(blocks) {
  const found = new Map();
  let cur;
  let level = 0;
  for (const raw of blocks) {
    const b = raw.kind === 'prose' && !raw.bold && !/[*_`]/.test(raw.text) && sectionOf(raw.text)
      ? { kind: 'heading', level: 2, text: raw.text }
      : raw;
    if (b.kind === 'heading') {
      const s = sectionOf(b.text);
      if (s) {
        cur = found.get(s) ?? [];
        found.set(s, cur);
        level = b.level;
        continue;
      }
      if (cur && b.level > level) {
        cur.push({ kind: 'subheading', text: b.text });
        continue;
      }
      cur = undefined;
      continue;
    }
    if (cur) cur.push(b);
  }
  return found;
}

const realContent = (b) => (b.kind === 'list' || b.kind === 'code' || (b.kind === 'prose' && !b.bold)) && !isPlaceholder(b.text);

function declared(blocks, name) {
  const re = new RegExp(`^\\s*(?:[-*+]\\s+)?(?:\\*\\*|__)?${name}(?:\\*\\*|__)?\\s*:(?:\\*\\*|__)?\\s*(.*)$`, 'i');
  for (let i = 0; i < blocks.length; i += 1) {
    const b = blocks[i];
    if (b.kind === 'code') continue;
    const asHeading = b.kind === 'heading' && b.text.replace(/[*_:]/g, '').trim().toLowerCase() === name.toLowerCase();
    const line = b.kind === 'list' ? `- ${b.text}` : b.text;
    const m = b.kind === 'heading' ? null : re.exec(line);
    if (!asHeading && !m) continue;
    const value = m ? m[1].replace(/[*_]+$/, '').trim() : '';
    if (value) return value;
    const next = blocks.slice(i + 1).find((x) => x.kind !== 'code');
    return next && next.kind !== 'heading' ? next.text.trim() : '';
  }
  return undefined;
}

function diag(rule, field, severity, message) {
  return { rule, field, severity, message };
}

/**
 * Validates a ticket body against the ticket standard.
 * input: { format: 'markdown', body: string } | { format: 'adf', body: unknown }
 * context: { issueType: string, labels: string[] } — the labels actually written.
 * Returns { valid, diagnostics }; valid means no error-severity diagnostic.
 * Epic and Subtask findings are warnings.
 */
export function validateTicketBody(input, context = {}) {
  const severity = isWarnOnlyType(context.issueType) ? 'warning' : 'error';
  const blocks = normalizeBody(input);
  const found = sectionsOf(blocks);
  const out = [];
  for (const s of SECTIONS) {
    const field = `body.${s}`;
    const body = found.get(s);
    if (!body) {
      out.push(diag('body.section.missing', field, severity, `missing "## ${s}"`));
      continue;
    }
    const content = body.filter((b) => b.kind !== 'subheading');
    if (content.length === 0 || content.every((b) => b.kind === 'prose' && b.bold)) {
      out.push(diag('body.section.empty', field, severity, `"## ${s}" is empty`));
      continue;
    }
    if (!content.some(realContent)) {
      out.push(diag('body.placeholder', field, severity, `"## ${s}" holds only a placeholder (TODO, TBD, N/A, an ellipsis or an <angle hint>)`));
      continue;
    }
    if (LIST_SECTIONS.has(s) && !content.some((b) => b.kind === 'list' && !isPlaceholder(b.text)))
      out.push(diag('body.list.required', field, severity, `"## ${s}" has no bullet or numbered line beyond the placeholder`));
  }
  if (needsMetric(context.labels)) {
    const value = declared(blocks, 'metric');
    if (value === undefined || isPlaceholder(value))
      out.push(diag('metric.required', 'body.Metric', severity, 'a ci, guard, guardrail, stability or flake ticket names the scorecard metric it moves: add a "Metric: <metric>" line'));
  }
  const plan = found.get('Plan') ?? [];
  const keys = new Set(plan.flatMap((b) => String(b.text).match(TICKET_KEY) ?? []));
  if (keys.size >= 2) {
    const value = declared(blocks, 'edges');
    const bare = value === undefined ? '' : value.replace(/[*_`]/g, '').trim();
    const ok = value !== undefined && (/^none\b/i.test(bare) || (!isPlaceholder(bare) && /\b[A-Z][A-Z0-9]+-[0-9]+\b/.test(bare)));
    if (!ok)
      out.push(diag('edges.required', 'body.Edges', severity, `the Plan names ${keys.size} ticket keys: add an "Edges: <A> blocks <B> (hard|soft)" line, or "Edges: none"`));
  }
  return { valid: !out.some((d) => d.severity === 'error'), diagnostics: out };
}

/** One short name per diagnostic, for the draft checker's one-line summary. */
export function shortName(d) {
  const s = d.field.replace(/^body\./, '');
  if (d.rule === 'metric.required') return 'Metric (name the stability-scorecard metric this ticket moves)';
  if (d.rule === 'edges.required') return `Edges: (${d.message})`;
  if (d.rule === 'labels.mismatch') return `Labels (${d.message})`;
  if (d.rule === 'body.list.required') return `${s} (needs a bullet or numbered line)`;
  return s;
}

/** Compares the labels being written with a draft's Labels: line; a mismatch is a diagnostic, never a silent pick. */
export function labelsMismatch(given, draftLine, issueType) {
  if (given === undefined || draftLine === undefined) return undefined;
  const a = [...new Set(given.map((l) => l.trim()).filter(Boolean))].sort();
  const b = [...new Set(draftLine.map((l) => l.trim()).filter(Boolean))].sort();
  if (a.join(',') === b.join(',')) return undefined;
  return diag('labels.mismatch', 'labels', isWarnOnlyType(issueType) ? 'warning' : 'error',
    `the --labels set (${a.join(', ') || 'none'}) differs from the draft's Labels: line (${b.join(', ') || 'none'})`);
}

/** The labels on a draft's first `Labels:` line outside code, or undefined. */
export function draftLabels(md) {
  for (const b of normalizeMarkdown(md)) {
    if (b.kind === 'code') continue;
    const m = /^\s*(?:[-*+]\s+)?(?:\*\*|__)?labels(?:\*\*|__)?\s*:(?:\*\*|__)?\s*(.*)$/i.exec(b.kind === 'list' ? `- ${b.text}` : b.text);
    if (m) return m[1].split(/[,\s]+/).map((l) => l.trim()).filter(Boolean);
  }
  return undefined;
}
