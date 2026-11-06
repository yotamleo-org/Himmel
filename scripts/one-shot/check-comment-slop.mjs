#!/usr/bin/env node
// scripts/one-shot/check-comment-slop.mjs: hand-run proof that em dashes and three
// named tokens left the comments and docs text of a script directory, and that no
// other token moved. A removal helper, never a suite: no CI or pre-commit wiring
// (scripts/ci/check-removal-ratchets.sh keeps that shape). The last slice deletes it.
//
// Usage:
//   check-comment-slop.mjs count <dir> [--keep <file>]
//   check-comment-slop.mjs list <dir>
//   check-comment-slop.mjs filter [--keep <file>]
//   check-comment-slop.mjs words
//   check-comment-slop.mjs readers <dir>
//   check-comment-slop.mjs self-check [--noop-runtime-seed]
// filter and words compare the merge base with origin/main against the working tree.
// Exit codes: 0 clean, 1 findings or a wrong control, 2 usage or a tool refusal.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const DASH = '—';
const TOKEN_SRC = '\\b(?:additionally|robust|in order to)\\b';
const TOKEN_RE = new RegExp(TOKEN_SRC, 'i');
const TOKEN_DELETE_RE = new RegExp(`${TOKEN_SRC},?\\s?`, 'gi');
const SHFMT_VERSION = 'v3.14.1';
const SELF = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(SELF), '../..');
const HELPER = 'scripts/one-shot/check-comment-slop.mjs';
const KEEP = 'scripts/one-shot/comment-slop-keep.tsv';
// The doc line that wires this helper for the added-file check. It is the one
// change `filter` allows in that doc, in either direction.
const WIRING_DOC = 'docs/internals/testing.md';
const WIRING_LINE = '`scripts/one-shot/check-comment-slop.mjs` is the helper of the sweep that takes em dashes out of comments and docs, run by hand and deleted when that sweep ends.';
const RELEASE = 'scripts/jira/src/release/';
const LEDGER = 'scripts/jira/src/release/ledger.ts';
// Seeds read this commit, since the real lines lose their dashes slice by slice.
const SEED_BASE = '62f2cc7757147edd1adbc81449e158a7e8bedc82';
const JS_RE = /\.(ts|tsx|js|mjs|cjs)$/;
const TEST_RE = /(^|\/)(test-[^/]*|[^/]*\.(test|spec)\.[a-z]+|tests?\/.*|fixtures?\/.*|_hermetic[^/]*)$/;
const DOCS = new Set(['scripts/jira/README.md', 'scripts/jira/CLAUDE.md', 'scripts/telegram/README.md', 'scripts/telegram/run-prompt.md']);
const RUN_PROMPT = 'scripts/telegram/run-prompt.md';
const UNIT = 'scripts/telegram/systemd/telegram-bridge.service';
const DOCSTRING = 'scripts/telegram/config-restore.py';
const JSON_NAMED = new Set(['scripts/himmelctl/lib/cadence-registry.json', 'scripts/himmelctl/lib/secrets-manifest.json']);
const GATES = new Set(['history-comments', 'platform-dropped', 'rename-diff', 'hardcoded-env-values', 'ws5-invariants']);
const MARKER_RE = /gitleaks:allow|ponytail:|swallow-ok|prim-ok|old-term-ok|noqa|nosec|eslint-[\w-]*|oxlint-[\w-]*|biome-[\w-]*|prettier-[\w-]*|@ts-[\w-]*|shellcheck/g;
const ROWS = ['comment', 'release-comment', 'test-comment', 'a7', 'docs', 'fenced', 'unit', 'json', 'docstring'];
const LCS_CAP = 25_000_000;

class Refusal extends Error {}

function die(message) {
  console.error(`check-comment-slop: ${message}`);
  process.exit(2);
}

function git(args, okCodes = [0]) {
  const r = spawnSync('git', ['-C', ROOT, '-c', 'core.quotePath=false', ...args], { encoding: 'utf8', maxBuffer: 1 << 30 });
  if (!okCodes.includes(r.status)) throw new Refusal(`git ${args.join(' ')} failed: ${r.stderr}`);
  return r.stdout;
}

let parseSync;
async function loadTools() {
  const shfmt = spawnSync('shfmt', ['--version'], { encoding: 'utf8' });
  if (shfmt.error || shfmt.stdout.trim() !== SHFMT_VERSION) {
    die(`shfmt ${SHFMT_VERSION} is required, found ${shfmt.error ? 'none' : shfmt.stdout.trim()}`);
  }
  const jiraPkg = resolve(ROOT, 'scripts/jira/package.json');
  let entry;
  try {
    entry = createRequire(jiraPkg).resolve('rolldown/experimental');
  } catch {
    die('rolldown is missing: run npm ci in scripts/jira');
  }
  ({ parseSync } = await import(pathToFileURL(entry).href));
}

function isTest(path) {
  return TEST_RE.test(path);
}

function kindOf(path) {
  if (JS_RE.test(path)) return 'js';
  if (path.endsWith('.sh')) return 'sh';
  if (DOCS.has(path)) return 'docs';
  if (path === UNIT) return 'unit';
  if (path === DOCSTRING) return 'docstring';
  if (JSON_NAMED.has(path)) return 'json';
  return 'other';
}

function jsSpans(path, text) {
  const lang = path.endsWith('.tsx') ? 'tsx' : path.endsWith('.ts') ? 'ts' : 'js';
  const r = parseSync(path, text, { lang, sourceType: 'unambiguous' });
  if (r.errors.length) throw new Refusal(`${path}: ${r.errors.length} parse errors`);
  const spans = r.comments.map((c) => ({ start: c.start, end: c.end })).sort((a, b) => a.start - b.start);
  for (const s of spans) {
    const open = text.slice(s.start, s.start + 2);
    if (open !== '//' && open !== '/*' && !(open === '#!' && s.start === 0)) throw new Refusal(`${path}: comment offset ${s.start} is not a comment`);
  }
  return spans;
}

function shSpans(path, text) {
  const raw = Buffer.from(text, 'utf8');
  const r = spawnSync('shfmt', ['--to-json'], { input: raw, maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Refusal(`${path}: shfmt refused: ${String(r.stderr).trim()}`);
  const found = new Map();
  // By shape, since shfmt keeps comments under Comments, Last and ThenLast alike.
  const walk = (node) => {
    if (Array.isArray(node)) {
      node.forEach(walk);
    } else if (node && typeof node === 'object') {
      if (node.Hash && typeof node.Text === 'string') found.set(node.Hash.Offset, Buffer.byteLength(node.Text));
      Object.values(node).forEach(walk);
    }
  };
  walk(JSON.parse(r.stdout.toString('utf8')));
  // shfmt's offsets are bytes: walk the Buffer and carry the string index along.
  const spans = [];
  let byteAt = 0;
  let charAt = 0;
  const advance = (to) => {
    charAt += raw.subarray(byteAt, to).toString('utf8').length;
    byteAt = to;
    return charAt;
  };
  for (const offset of [...found.keys()].sort((a, b) => a - b)) {
    if (raw[offset] !== 0x23) throw new Refusal(`${path}: shfmt offset ${offset} is not a hash`);
    const start = advance(offset);
    const end = advance(offset + 1 + found.get(offset));
    spans.push({ start, end });
  }
  return spans;
}

function spansOf(path, text) {
  return kindOf(path) === 'js' ? jsSpans(path, text) : shSpans(path, text);
}

function inSpan(spans, offset) {
  let lo = 0;
  let hi = spans.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (offset < spans[mid].start) hi = mid - 1;
    else if (offset >= spans[mid].end) lo = mid + 1;
    else return true;
  }
  return false;
}

function lineStarts(text) {
  const starts = [0];
  for (let i = text.indexOf('\n'); i !== -1; i = text.indexOf('\n', i + 1)) starts.push(i + 1);
  return starts;
}

function lineOf(starts, offset) {
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return lo + 1;
}

// The end of a comment opener in a test-file string line, or -1. A `//` after `:` is a URL.
function a7Opener(line, at) {
  const whole = /^\s*(#|\/\/)/.exec(line);
  if (whole) return whole[0].length;
  for (let i = line.indexOf('//'); i !== -1 && i < at; i = line.indexOf('//', i + 2)) {
    if (i === 0 || line[i - 1] !== ':') return i + 2;
  }
  return -1;
}

const INLINE_RE = /(`+)(.+?)\1/g;
const LINK_RE = /\]\(([^)\s]+)/g;

// ponytail: four named files, deleted with the helper in PR 3
function walkMarkdown(text, visit) {
  let fence = null;
  text.split('\n').forEach((line, i) => {
    const n = i + 1;
    const open = /^ {0,3}(`{3,}|~{3,})\s*([\w-]*)/.exec(line);
    if (fence) {
      const closes = open && open[1][0] === fence.char && open[1].length >= fence.len && line.trim() === open[1];
      if (closes) {
        fence = null;
        visit({ n, line, kind: 'delim' });
      } else {
        visit({ n, line, kind: 'fence', lang: fence.lang });
      }
    } else if (open) {
      fence = { char: open[1][0], len: open[1].length, lang: open[2] };
      visit({ n, line, kind: 'delim' });
    } else {
      visit({ n, line, kind: 'text' });
    }
  });
}

function isShellComment(entry) {
  return entry.kind === 'fence' && (entry.lang === 'bash' || entry.lang === 'sh') && /^\s*#/.test(entry.line);
}

function isVaultClause(path, line) {
  return path === RUN_PROMPT && line.startsWith('<vault-clause');
}

function hasToken(line) {
  return TOKEN_RE.test(line);
}

function emptyClass() {
  return { inScope: new Map(), tokens: new Map(), stringData: [], otherTypes: [] };
}

function classifyCode(path, text, out) {
  const spans = spansOf(path, text);
  const test = isTest(path);
  const cls = test ? 'test-comment' : path.startsWith(RELEASE) ? 'release-comment' : 'comment';
  const tokenRe = new RegExp(TOKEN_SRC, 'gi');
  let offset = 0;
  text.split('\n').forEach((line, i) => {
    const n = i + 1;
    const dashes = [];
    for (let at = line.indexOf(DASH); at !== -1; at = line.indexOf(DASH, at + 1)) dashes.push(at);
    if (dashes.length) {
      if (dashes.every((at) => inSpan(spans, offset + at))) out.inScope.set(n, { cls, text: line });
      else if (test && a7Opener(line, dashes[0]) >= 0) out.inScope.set(n, { cls: 'a7', text: line });
      else out.stringData.push(n);
    }
    for (const m of line.matchAll(tokenRe)) {
      if (inSpan(spans, offset + m.index)) out.tokens.set(n, { cls, text: line });
      else if (test && a7Opener(line, m.index) >= 0 && !out.tokens.has(n)) out.tokens.set(n, { cls: 'a7', text: line });
    }
    offset += line.length + 1;
  });
}

function classifyDocs(path, text, out) {
  walkMarkdown(text, (e) => {
    if (e.kind === 'delim') return;
    const hasDash = e.line.includes(DASH);
    if (e.kind === 'fence') {
      const cls = isShellComment(e) ? 'fenced' : isVaultClause(path, e.line) ? 'docs' : null;
      if (cls && hasDash) out.inScope.set(e.n, { cls, text: e.line });
      if (cls && hasToken(e.line)) out.tokens.set(e.n, { cls, text: e.line });
      if (!cls && hasDash) out.otherTypes.push(e.n);
      return;
    }
    const prose = e.line.replace(INLINE_RE, '');
    if (prose.includes(DASH)) out.inScope.set(e.n, { cls: 'docs', text: e.line });
    else if (hasDash) out.stringData.push(e.n);
    if (hasToken(prose)) out.tokens.set(e.n, { cls: 'docs', text: e.line });
  });
}

// ponytail: two named files, deleted with the helper in PR 3
function classifyNamed(kind, text, out) {
  text.split('\n').forEach((line, i) => {
    const n = i + 1;
    const hasDash = line.includes(DASH);
    let cls = null;
    if (kind === 'unit' && /^\s*#/.test(line)) cls = 'unit';
    if (kind === 'docstring' && n === 2) cls = 'docstring';
    if (kind === 'json' && line.trim().startsWith('"$comment"')) cls = 'json';
    if (cls) {
      if (hasDash) out.inScope.set(n, { cls, text: line });
      if (hasToken(line)) out.tokens.set(n, { cls, text: line });
    } else if (hasDash) {
      (kind === 'json' ? out.otherTypes : out.stringData).push(n);
    }
  });
}

function classify(path, text) {
  const out = emptyClass();
  if (!text.includes(DASH) && !hasToken(text)) return out;
  const kind = kindOf(path);
  if (kind === 'js' || kind === 'sh') classifyCode(path, text, out);
  else if (kind === 'docs') classifyDocs(path, text, out);
  else if (kind === 'unit' || kind === 'docstring' || kind === 'json') classifyNamed(kind, text, out);
  else if (text.includes(DASH) && !text.slice(0, 8192).includes('\0')) {
    text.split('\n').forEach((line, i) => {
      if (line.includes(DASH)) (path.endsWith('.json') ? out.otherTypes : out.stringData).push(i + 1);
    });
  }
  return out;
}

function readTree(path) {
  const abs = resolve(ROOT, path);
  return existsSync(abs) ? readFileSync(abs, 'utf8') : null;
}

function readSeed(path) {
  return git(['show', `${SEED_BASE}:${path}`]);
}

function trackedFiles(dir) {
  const files = git(['ls-files', '--', dir]).split('\n').filter(Boolean);
  if (!files.length) throw new Refusal(`no tracked file under ${dir}`);
  return files;
}

function scanDir(dir) {
  const scanned = [];
  for (const path of trackedFiles(dir)) {
    const text = readTree(path);
    if (text !== null) scanned.push({ path, ...classify(path, text) });
  }
  return scanned;
}

function sha256(line) {
  return createHash('sha256').update(line.trim()).digest('hex');
}

function parseKeep(text) {
  return text.split('\n').filter((l) => l.trim()).map((raw) => {
    const fields = raw.split('\t');
    return { raw, path: fields[0], reason: fields[1], field: fields[2], fields: fields.length };
  });
}

function checkReader(row, read, keptLines) {
  const spec = row.reason.slice('ruled:'.length);
  const colon = spec.lastIndexOf(':');
  const readerPath = spec.slice(0, colon);
  const readerLine = Number(spec.slice(colon + 1));
  const text = colon > 0 && Number.isInteger(readerLine) ? read(readerPath) : null;
  if (text === null) return `reader ${spec} does not exist`;
  const lines = text.split('\n');
  const line = lines[readerLine - 1];
  if (readerLine < 1 || line === undefined) return `reader ${spec} is past the end of the file`;
  if (readerPath === row.path && keptLines.includes(readerLine)) return `reader ${spec} is the kept line`;
  const at = line.indexOf(row.field);
  if (at === -1) return `reader ${spec} does not hold the fragment`;
  if (classify(readerPath, text).inScope.has(readerLine)) return `reader ${spec} is itself a comment or docs line`;
  const kind = kindOf(readerPath);
  if (kind === 'js' || kind === 'sh') {
    const spans = spansOf(readerPath, text);
    const offset = lineStarts(text)[readerLine - 1];
    let outside = false;
    for (let i = at; i !== -1; i = line.indexOf(row.field, i + 1)) if (!inSpan(spans, offset + i)) outside = true;
    if (!outside) return `reader ${spec} holds the fragment only inside a comment`;
  } else if (/^\s*(#|\/\/)/.test(line)) {
    return `reader ${spec} is a comment-shaped line`;
  }
  return null;
}

// Rows are checked against the tree `read` serves. A valid row covers the lines it names.
function validateKeep(rows, read) {
  const refused = [];
  const covered = new Map();
  for (const row of rows) {
    const refuse = (why) => refused.push(`${row.raw}  [${why}]`);
    if (row.fields !== 3) { refuse('a row has three tab-separated fields'); continue; }
    const isGate = /^gate:/.test(row.reason);
    const isRuled = /^ruled:/.test(row.reason);
    if (!isGate && !isRuled) { refuse(`reason ${row.reason} is not gate: or ruled:`); continue; }
    const text = read(row.path);
    if (text === null) { refuse(`${row.path} does not exist`); continue; }
    const inScope = classify(row.path, text).inScope;
    let lines;
    if (isGate) {
      if (!GATES.has(row.reason.slice('gate:'.length))) { refuse(`${row.reason} names no gate`); continue; }
      lines = [...inScope].filter(([, v]) => sha256(v.text) === row.field).map(([n]) => n);
      if (!lines.length) { refuse('the hash matches no in-scope line of that path'); continue; }
    } else {
      if (row.field.length < 12) { refuse('a fragment is at least 12 characters'); continue; }
      if (!row.field.includes(DASH)) { refuse('a fragment holds the dash'); continue; }
      lines = [...inScope].filter(([, v]) => v.text.includes(row.field)).map(([n]) => n);
      if (!lines.length) { refuse('the fragment is on no in-scope line of that path'); continue; }
      if (row.reason === 'ruled:A3') {
        if (row.path !== LEDGER) { refuse('ruled:A3 belongs to the ledger line alone'); continue; }
      } else {
        const why = checkReader(row, read, lines);
        if (why) { refuse(why); continue; }
      }
    }
    if (!covered.has(row.path)) covered.set(row.path, new Set());
    for (const n of lines) covered.get(row.path).add(n);
  }
  return { refused, covered };
}

function loadKeep(file) {
  if (!existsSync(file)) {
    console.error(`check-comment-slop: --keep ${file} does not exist`);
    process.exit(2);
  }
  return parseKeep(readFileSync(file, 'utf8'));
}

function cmdCount(dir, keepFile) {
  const rows = keepFile ? loadKeep(keepFile).filter((r) => r.path === dir || String(r.path).startsWith(`${dir}/`)) : [];
  const scanned = scanDir(dir);
  const { refused, covered } = validateKeep(rows, readTree);
  const scope = Object.fromEntries(ROWS.map((r) => [r, 0]));
  const token = Object.fromEntries(ROWS.map((r) => [r, 0]));
  let stringData = 0;
  let otherTypes = 0;
  let kept = 0;
  let beyond = 0;
  let tokenBeyond = 0;
  for (const f of scanned) {
    const keepLines = covered.get(f.path) ?? new Set();
    for (const [n, v] of f.inScope) {
      scope[v.cls]++;
      if (keepLines.has(n)) kept++;
      else beyond++;
    }
    for (const [n, v] of f.tokens) {
      token[v.cls]++;
      if (!keepLines.has(n)) tokenBeyond++;
    }
    stringData += f.stringData.length;
    otherTypes += f.otherTypes.length;
  }
  const total = Object.values(scope).reduce((a, b) => a + b, 0);
  const tokenTotal = Object.values(token).reduce((a, b) => a + b, 0);
  console.log(`count ${dir}`);
  console.log(`${'class'.padEnd(18)}${'in-scope'.padStart(9)}${'token'.padStart(7)}`);
  for (const r of ROWS) console.log(`${r.padEnd(18)}${String(scope[r]).padStart(9)}${String(token[r]).padStart(7)}`);
  console.log(`in-scope ${total} (${total - scope['release-comment']} outside release, ${scope['release-comment']} release), test-file comment lines ${scope['test-comment'] + scope.a7}, token ${tokenTotal}`);
  console.log(`stayed string-or-data ${stringData}, stayed other-types ${otherTypes}, all dash lines ${total + stringData + otherTypes}`);
  console.log(`keep rows ${rows.length}, kept lines ${kept}, in-scope beyond valid rows ${beyond}, token beyond valid rows ${tokenBeyond}`);
  for (const r of refused) console.log(`REFUSED ${r}`);
  return beyond || tokenBeyond || refused.length ? 1 : 0;
}

function cmdList(dir) {
  for (const f of scanDir(dir)) {
    const lines = new Map([...f.inScope, ...f.tokens]);
    for (const n of [...lines.keys()].sort((a, b) => a - b)) console.log(`${f.path}:${n}\t${lines.get(n).text}`);
  }
  return 0;
}

// Base and head as ordered sequences of hunks, half-open. Null past the cap, which fails closed.
function diffHunks(a, b) {
  let pre = 0;
  while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
  let suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] === b[b.length - 1 - suf]) suf++;
  const n = a.length - pre - suf;
  const m = b.length - pre - suf;
  if (n === 0 && m === 0) return [];
  if (n === 0 || m === 0) return [{ as: pre, ae: pre + n, bs: pre, be: pre + m }];
  if (n * m > LCS_CAP) return null;
  const width = m + 1;
  const table = new Uint32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      table[i * width + j] = a[pre + i] === b[pre + j]
        ? table[(i + 1) * width + j + 1] + 1
        : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  const hunks = [];
  let i = 0;
  let j = 0;
  let open = null;
  const flush = () => { if (open) { hunks.push(open); open = null; } };
  while (i < n || j < m) {
    if (i < n && j < m && a[pre + i] === b[pre + j]) {
      flush();
      i++;
      j++;
    } else {
      if (!open) open = { as: pre + i, ae: pre + i, bs: pre + j, be: pre + j };
      if (j < m && (i === n || table[i * width + j + 1] >= table[(i + 1) * width + j])) {
        j++;
        open.be = pre + j;
      } else {
        i++;
        open.ae = pre + i;
      }
    }
  }
  flush();
  return hunks;
}

function words(text) {
  return (text.toLowerCase().match(/[\p{L}\p{N}_]+/gu) ?? []);
}

function sameWords(a, b) {
  const x = words(a);
  const y = words(b);
  return x.length === y.length && x.every((w, i) => w === y[i]);
}

// Reachability over the two strings: match by case, gain only .,(): and lose only the dash and
// the space before it. A lost backslash, backtick, quote or dollar therefore has no path.
function charRule(base, head) {
  const n = base.length;
  const m = head.length;
  const reach = new Uint8Array((n + 1) * (m + 1));
  const at = (i, j) => i * (m + 1) + j;
  reach[0] = 1;
  for (let i = 0; i <= n; i++) {
    for (let j = 0; j <= m; j++) {
      if (!reach[at(i, j)]) continue;
      if (i < n && j < m && base[i].toLowerCase() === head[j].toLowerCase()) reach[at(i + 1, j + 1)] = 1;
      if (j < m && '.,():'.includes(head[j])) reach[at(i, j + 1)] = 1;
      if (i < n && (base[i] === DASH || (base[i] === ' ' && base[i + 1] === DASH))) reach[at(i + 1, j)] = 1;
    }
  }
  return reach[at(n, m)] === 1;
}

function i6(baseLine, headLine) {
  const mark = baseLine.search(new RegExp(`${DASH}|${TOKEN_SRC}`, 'i'));
  const opener = a7Opener(baseLine, mark === -1 ? baseLine.length : mark);
  if (opener < 0) return 'the base line has no comment opener';
  if (!headLine.startsWith(baseLine.slice(0, opener))) return 'the text through the opener changed';
  const base = baseLine.slice(opener);
  const head = headLine.slice(opener);
  const deleted = base.replace(TOKEN_DELETE_RE, '');
  if (sameWords(base, head)) return charRule(base, head) ? null : 'the comment gained or lost a character outside the rule';
  if (deleted !== base && sameWords(deleted, head)) return charRule(deleted, head) ? null : 'the comment gained or lost a character outside the rule';
  return 'a comment word changed';
}

// Text minus comment spans, kept newlines, line ends trimmed, blanks dropped.
function stripSeq(text, spans) {
  let out = '';
  let at = 0;
  for (const s of spans) {
    out += text.slice(at, s.start) + text.slice(s.start, s.end).replace(/[^\n]/g, '');
    at = s.end;
  }
  out += text.slice(at);
  const seq = [];
  out.split('\n').forEach((line, i) => {
    const t = line.trimEnd();
    if (t.trim()) seq.push({ n: i + 1, text: t });
  });
  return seq;
}

function directives(text, spans) {
  return spans
    .map((s) => text.slice(s.start, s.end))
    .filter((c) => /^#\s*shellcheck\b/.test(c))
    .map((c) => {
      const inner = c.indexOf('#', 1);
      return inner === -1 ? c : c.slice(0, inner + 1);
    });
}

function compareCode(path, base, head, result) {
  let baseSpans;
  let headSpans;
  let a7Base;
  try {
    baseSpans = spansOf(path, base);
    headSpans = spansOf(path, head);
    const klass = classify(path, base);
    a7Base = new Set([...klass.inScope, ...klass.tokens].filter(([, v]) => v.cls === 'a7').map(([n]) => n));
  } catch (e) {
    if (!(e instanceof Refusal)) throw e;
    result.fail.push(`${path}: ${e.message}`);
    return;
  }
  const baseFirst = base.split('\n', 1)[0];
  const headFirst = head.split('\n', 1)[0];
  if ((baseFirst.startsWith('#!') || headFirst.startsWith('#!')) && baseFirst !== headFirst) {
    result.fail.push(`${path}:1: shebang changed: ${baseFirst} to ${headFirst}`);
  }
  if (kindOf(path) === 'sh') {
    const x = directives(base, baseSpans);
    const y = directives(head, headSpans);
    if (x.length !== y.length || x.some((d, i) => d !== y[i])) result.fail.push(`${path}: a directive changed before its inner hash`);
  }
  const a = stripSeq(base, baseSpans);
  const b = stripSeq(head, headSpans);
  const hunks = diffHunks(a.map((x) => x.text), b.map((x) => x.text));
  if (hunks === null) {
    result.fail.push(`${path}: the difference is past the compare cap`);
    return;
  }
  for (const h of hunks) {
    const left = a.slice(h.as, h.ae);
    const right = b.slice(h.bs, h.be);
    const holdsA7 = left.some((l) => a7Base.has(l.n));
    if (holdsA7 && left.length === right.length) {
      left.forEach((l, i) => {
        const r = right[i];
        const why = a7Base.has(l.n) ? i6(l.text, r.text) : 'a code line changed';
        if (why) result.fail.push(`${path}:${l.n}: ${why}: ${l.text.trim()} to ${r.text.trim()}`);
        else result.a7ok.push(`${path}:${l.n}: ${r.text.trim()}`);
      });
    } else {
      const why = holdsA7 ? 'an A7 hunk does not pair line for line' : 'a non-comment line changed';
      for (const l of left) result.fail.push(`${path}:${l.n}: ${why}: - ${l.text.trim()}`);
      for (const r of right) result.fail.push(`${path}:${r.n}: ${why}: + ${r.text.trim()}`);
    }
  }
}

function markdownShape(path, text) {
  const seq = [];
  const headings = [];
  walkMarkdown(text, (e) => {
    if (e.kind === 'delim') seq.push(`fence ${e.line.trimEnd()}`);
    else if (e.kind === 'fence') {
      if (!isShellComment(e) && !isVaultClause(path, e.line)) seq.push(`body ${e.line.trimEnd()}`);
    } else {
      for (const m of e.line.matchAll(INLINE_RE)) seq.push(`code ${m[2]}`);
      for (const m of e.line.replace(INLINE_RE, '').matchAll(LINK_RE)) seq.push(`link ${m[1]}`);
      const h = /^#{1,6}\s+(.*)$/.exec(e.line);
      if (h) headings.push({ n: e.n, text: h[1].trim() });
    }
  });
  return { seq, headings };
}

function slugOf(heading) {
  return heading.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/ /g, '-');
}

function slugHits(path, baseLine, slug, oldText, planted) {
  const out = git(['grep', '-nIF', '-e', `#${slug}`, '-e', oldText, '--', '.', `:!${HELPER}`, `:!${KEEP}`], [0, 1]);
  const anchor = new RegExp(`#${slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\w-])`);
  const hits = [];
  for (const row of [...out.split('\n').filter(Boolean), ...planted]) {
    const m = /^([^:]+):(\d+):(.*)$/.exec(row);
    if (!m) continue;
    const isOwnLine = m[1] === path && Number(m[2]) === baseLine;
    if (anchor.test(m[3]) || (m[3].includes(oldText) && !isOwnLine)) hits.push(row);
  }
  return hits;
}

function compareMarkdown(path, base, head, result, planted) {
  const x = markdownShape(path, base);
  const y = markdownShape(path, head);
  const hunks = diffHunks(x.seq, y.seq);
  if (hunks === null) result.fail.push(`${path}: the difference is past the compare cap`);
  for (const h of hunks ?? []) {
    for (const l of x.seq.slice(h.as, h.ae)) result.fail.push(`${path}: fence, inline code or link changed: - ${l}`);
    for (const r of y.seq.slice(h.bs, h.be)) result.fail.push(`${path}: fence, inline code or link changed: + ${r}`);
  }
  if (x.headings.length !== y.headings.length) {
    result.fail.push(`${path}: heading count changed: ${x.headings.length} to ${y.headings.length}`);
    return;
  }
  x.headings.forEach((b, i) => {
    const oldSlug = slugOf(b.text);
    if (oldSlug === slugOf(y.headings[i].text)) return;
    const hits = slugHits(path, b.n, oldSlug, b.text, planted);
    if (hits.length) result.fail.push(`${path}:${b.n}: old slug ${oldSlug} still has a reader: ${hits.join(' | ')}`);
    else result.headings.push(`${path}:${b.n}: old slug ${oldSlug}: git grep finds no link or old text`);
  });
}

function dropComments(value) {
  if (Array.isArray(value)) return value.map(dropComments);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).filter(([k]) => k !== '$comment').map(([k, v]) => [k, dropComments(v)]));
  }
  return value;
}

// ponytail: two named files, deleted with the helper in PR 3
function compareJson(path, base, head, result) {
  try {
    if (JSON.stringify(dropComments(JSON.parse(base))) !== JSON.stringify(dropComments(JSON.parse(head)))) {
      result.fail.push(`${path}: a json value changed`);
    }
  } catch (e) {
    result.fail.push(`${path}: json parse failed: ${e.message}`);
  }
}

function compareLinesWhere(path, base, head, keep, result) {
  const a = base.split('\n').filter(keep);
  const b = head.split('\n').filter(keep);
  const hunks = diffHunks(a, b);
  if (hunks === null) result.fail.push(`${path}: the difference is past the compare cap`);
  for (const h of hunks ?? []) {
    for (const l of a.slice(h.as, h.ae)) result.fail.push(`${path}: a non-comment line changed: - ${l}`);
    for (const r of b.slice(h.bs, h.be)) result.fail.push(`${path}: a non-comment line changed: + ${r}`);
  }
}

function compareDocstring(path, base, head, result) {
  const a = base.split('\n');
  const b = head.split('\n');
  if (a.length !== b.length || a.some((l, i) => i !== 1 && l !== b[i])) result.fail.push(`${path}: a line other than line 2 changed`);
  if (!(b[1] ?? '').startsWith('"""')) result.fail.push(`${path}:2: the docstring no longer opens with three quotes`);
}

function onlyWiringLine(path, base, head) {
  if (path !== WIRING_DOC) return false;
  const [shorter, longer] = base.length < head.length ? [base, head] : [head, base];
  const lines = longer.split('\n');
  const at = lines.indexOf(WIRING_LINE);
  if (at < 0) return false;
  lines.splice(at, 1);
  return lines.join('\n') === shorter;
}

function filterFile(path, base, head, planted = []) {
  const result = { a7ok: [], fail: [], headings: [] };
  const kind = kindOf(path);
  if (kind === 'js' || kind === 'sh') compareCode(path, base, head, result);
  else if (kind === 'docs') compareMarkdown(path, base, head, result, planted);
  else if (kind === 'unit') compareLinesWhere(path, base, head, (l) => !/^\s*#/.test(l), result);
  else if (kind === 'docstring') compareDocstring(path, base, head, result);
  else if (kind === 'json') compareJson(path, base, head, result);
  else if (base !== head && !onlyWiringLine(path, base, head)) result.fail.push(`${path}: this file type holds no comment the helper can read`);
  return result;
}

// One entry per comment or docs-text line, in file order.
function commentUnits(path, text) {
  const units = [];
  const kind = kindOf(path);
  if (kind === 'js' || kind === 'sh') {
    const starts = lineStarts(text);
    for (const s of spansOf(path, text)) {
      const first = lineOf(starts, s.start);
      text.slice(s.start, s.end).split('\n').forEach((part, i) => units.push({ n: first + i, text: part }));
    }
  } else if (kind === 'docs') {
    walkMarkdown(text, (e) => {
      if (e.kind === 'fence' && (isShellComment(e) || isVaultClause(path, e.line))) units.push({ n: e.n, text: e.line });
      if (e.kind === 'text') units.push({ n: e.n, text: e.line.replace(INLINE_RE, ' ').replace(/\]\([^)\s]+\)/g, ']') });
    });
  } else if (kind === 'unit' || kind === 'docstring' || kind === 'json') {
    text.split('\n').forEach((line, i) => {
      const n = i + 1;
      if ((kind === 'unit' && /^\s*#/.test(line)) || (kind === 'docstring' && n === 2) || (kind === 'json' && line.trim().startsWith('"$comment"'))) {
        units.push({ n, text: line });
      }
    });
  }
  return units;
}

function unitWords(units) {
  const out = [];
  for (const u of units) for (const w of words(u.text)) out.push({ w, n: u.n });
  return out;
}

function markersOf(units) {
  const out = [];
  for (const u of units) for (const m of u.text.matchAll(MARKER_RE)) out.push(m[0]);
  return out;
}

function isTokenSide(side, next) {
  const joined = side.join(' ');
  if (joined === 'in order' && next === 'to') return true;
  return /^(?:additionally|robust|in order to)(?: (?:additionally|robust|in order to))*$/.test(joined);
}

function wordsFile(path, base, head) {
  const result = { token: [], fail: [] };
  let baseUnits;
  let headUnits;
  try {
    baseUnits = commentUnits(path, base);
    headUnits = commentUnits(path, head);
  } catch (e) {
    if (!(e instanceof Refusal)) throw e;
    result.fail.push(`${path}: ${e.message}`);
    return result;
  }
  const a = unitWords(baseUnits);
  const b = unitWords(headUnits);
  const headLines = head.split('\n');
  const hunks = diffHunks(a.map((x) => x.w), b.map((x) => x.w));
  if (hunks === null) result.fail.push(`${path}: the difference is past the compare cap`);
  for (const h of hunks ?? []) {
    const left = a.slice(h.as, h.ae).map((x) => x.w);
    const right = b.slice(h.bs, h.be).map((x) => x.w);
    const n = (b[h.bs] ?? a[h.as] ?? { n: 0 }).n;
    const nextBase = a[h.ae]?.w;
    if (left.length && isTokenSide(left, nextBase) && right.length <= 2) {
      result.token.push(`${path}:${n}: ${left.join(' ')} to [${right.join(' ')}]: ${(headLines[n - 1] ?? '').trim()}`);
    } else {
      result.fail.push(`${path}:${n}: [${left.join(' ')}] to [${right.join(' ')}]`);
    }
  }
  const x = markersOf(baseUnits);
  const y = markersOf(headUnits);
  if (x.length !== y.length || x.some((m, i) => m !== y[i])) {
    result.fail.push(`${path}: a marker changed: [${x.join(' ')}] to [${y.join(' ')}]`);
  }
  return result;
}

function mergeBase() {
  return git(['merge-base', 'HEAD', 'origin/main']).trim();
}

function changedFiles(base) {
  const rows = git(['diff', '--name-status', '--no-renames', base]).split('\n').filter(Boolean);
  const files = rows.map((r) => {
    const [status, path] = r.split('\t');
    return { status: status[0], path };
  });
  for (const path of git(['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean)) {
    files.push({ status: 'A', path });
  }
  return files.filter((f) => f.path !== HELPER && f.path !== KEEP);
}

function printSection(name, rows) {
  console.log(`${name} (${rows.length})`);
  for (const r of rows) console.log(`  ${r}`);
}

function cmdFilter(keepFile) {
  const base = mergeBase();
  const all = { a7ok: [], fail: [], headings: [] };
  for (const f of changedFiles(base)) {
    if (f.status !== 'M') {
      all.fail.push(`${f.path}: added or deleted (${f.status})`);
      continue;
    }
    const r = filterFile(f.path, git(['show', `${base}:${f.path}`]), readTree(f.path));
    all.a7ok.push(...r.a7ok);
    all.fail.push(...r.fail);
    all.headings.push(...r.headings);
  }
  if (keepFile) {
    const { refused } = validateKeep(loadKeep(keepFile), readTree);
    all.fail.push(...refused.map((r) => `keep row refused: ${r}`));
  }
  console.log(`filter base ${base}`);
  printSection('a7-ok', all.a7ok);
  printSection('heading-listed', all.headings);
  printSection('FAIL', all.fail);
  return all.fail.length ? 1 : 0;
}

function cmdWords() {
  const base = mergeBase();
  const all = { token: [], fail: [] };
  for (const f of changedFiles(base)) {
    if (f.status !== 'M') continue;
    const r = wordsFile(f.path, git(['show', `${base}:${f.path}`]), readTree(f.path));
    all.token.push(...r.token);
    all.fail.push(...r.fail);
  }
  console.log(`words base ${base}`);
  printSection('token', all.token);
  printSection('FAIL', all.fail);
  return all.fail.length ? 1 : 0;
}

// ponytail: heuristic quote-parity scan, deleted with the helper in PR 3, a missed reader falls to the suites
function quotedStrings(line) {
  const found = [];
  let quote = null;
  let start = 0;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '\\') { i++; continue; }
    if (quote === null && (c === '"' || c === "'" || c === '`')) { quote = c; start = i + 1; }
    else if (c === quote) { found.push(line.slice(start, i)); quote = null; }
  }
  return found;
}

const REGEX_SHAPE = new RegExp(`\\[[^\\]]*${DASH}[^\\]]*\\]|${DASH}\\||\\|${DASH}|/[^/\\s][^/]*${DASH}[^/]*/[gimsuy]*`);

function cmdReaders(dir) {
  const inScope = [];
  for (const f of scanDir(dir)) for (const [n, v] of f.inScope) inScope.push({ path: f.path, n, text: v.text });
  const own = new Set(inScope.map((l) => `${l.path}:${l.n}`));
  const blob = inScope.map((l) => l.text).join('\n');
  const rows = git(['grep', '-nI', '-e', DASH, '--', '.', `:!${HELPER}`, `:!${KEEP}`], [0, 1]).split('\n').filter(Boolean);
  const quoted = [];
  const regex = [];
  for (const row of rows) {
    const m = /^([^:]+):(\d+):(.*)$/.exec(row);
    if (!m || own.has(`${m[1]}:${m[2]}`) || /^\s*(#|\/\/|\*)/.test(m[3])) continue;
    for (const s of quotedStrings(m[3])) {
      if (s.includes(DASH) && s.trim() !== DASH && blob.includes(s)) quoted.push(`${m[1]}:${m[2]}: ${s}`);
    }
    if (/\.(ts|tsx|js|mjs|cjs|sh|py|awk)$/.test(m[1]) && REGEX_SHAPE.test(m[3])) regex.push(`${m[1]}:${m[2]}: ${m[3].trim()}`);
  }
  console.log(`readers ${dir}`);
  printSection('quoted', quoted);
  printSection('regex-shape', regex);
  return 0;
}

function editLine(text, n, fn) {
  const lines = text.split('\n');
  const next = fn(lines[n - 1]);
  if (next === lines[n - 1]) throw new Refusal(`seed made no edit at line ${n}`);
  lines[n - 1] = next;
  return lines.join('\n');
}

function dashToComma(line) {
  return line.replace(new RegExp(` ?${DASH}( ?)`, 'g'), (_, after) => `,${after}`);
}

function firstLine(map, want) {
  for (const [n, v] of map) if (v.cls === want) return n;
  throw new Refusal(`no ${want} line`);
}

function selfCheck(noopRuntime) {
  let wrong = 0;
  const report = (name, want, got) => {
    const ok = want === got;
    if (!ok) wrong++;
    console.log(`${ok ? 'ok   ' : 'WRONG'} ${name}: want ${want}, got ${got}`);
  };
  const cache = new Map();
  const seed = (path) => {
    if (!cache.has(path)) cache.set(path, readSeed(path));
    return cache.get(path);
  };
  const lineText = (path, n) => seed(path).split('\n')[n - 1];
  const filterSeed = (name, want, path, mutate, opts = {}) => {
    const base = opts.base ?? seed(path);
    const r = filterFile(path, base, mutate(base), opts.planted ?? []);
    report(`filter ${name}`, want, r.fail.length ? 1 : 0);
    for (const line of r.fail.slice(0, 2)) console.log(`      ${line.slice(0, 220)}`);
    if (opts.a7) report(`filter ${name}, a7-ok lines`, opts.a7, r.a7ok.length);
    if (opts.listed) report(`filter ${name}, headings listed`, opts.listed, r.headings.length);
    for (const line of r.headings) console.log(`      ${line}`);
    return r;
  };
  const wordsSeed = (name, want, path, mutate) => {
    const base = seed(path);
    const r = wordsFile(path, base, mutate(base));
    report(`words ${name}`, want, r.fail.length ? 1 : 0);
    for (const line of r.fail.slice(0, 2)) console.log(`      ${line.slice(0, 220)}`);
    return r;
  };

  const BIN = 'scripts/himmelctl/bin.js';
  const DEPS = 'scripts/himmelctl/test/test-wizard-deps.sh';
  const PERSIST = 'scripts/himmelctl/test/test-bridge-persistence.sh';
  const PROBES = 'scripts/himmelctl/test/test-wizard-probes.sh';
  const STATUS = 'scripts/himmelctl/test/test-wizard-statusreport.sh';
  const DISABLE = 'scripts/himmelctl/test/test-wizard-ensure-disable.sh';
  const RECONCILE = 'scripts/jira/reconcile-lib.test.mjs';
  const TG_README = 'scripts/telegram/README.md';
  const JIRA_DOC = 'scripts/jira/CLAUDE.md';
  const CADENCE = 'scripts/himmelctl/lib/cadence-registry.json';
  const SHELL = 'scripts/telegram/restart-bridge.sh';
  const binClass = classify(BIN, seed(BIN));
  const binComment = firstLine(binClass.inScope, 'comment');
  const binToken = 1354;

  // Count.
  report('count a token in a string with no comment shape is not counted', false, binClass.tokens.has(315));
  report('count a token in a test heredoc comment with no dash is counted', 'a7', classify(DISABLE, seed(DISABLE)).tokens.get(1691)?.cls);
  const probeClass = classify(PROBES, seed(PROBES));
  report('count a dash in a test-file comment is counted', 'test-comment', probeClass.inScope.get(firstLine(probeClass.inScope, 'test-comment'))?.cls);
  report('count a comment-looking dash line in a test heredoc is counted, own row', 'a7', classify(DEPS, seed(DEPS)).inScope.get(629)?.cls);
  report('count a URL before a dash in test data is not counted', false, classify(RECONCILE, seed(RECONCILE)).inScope.has(59));

  // filter, expected clean.
  filterSeed('comment edit plus an added comment line', 0, BIN, (t) => {
    const edited = editLine(t, binComment, (l) => `${dashToComma(l)} extra words`);
    return editLine(edited, binComment, (l) => `${l}\n// a new second comment line`);
  });
  filterSeed('heredoc comment dash to comma', 0, DEPS, (t) => editLine(t, 629, dashToComma), { a7: 1 });
  filterSeed('trailing comment dash to comma', 0, PERSIST, (t) => editLine(t, 447, dashToComma), { a7: 1 });
  filterSeed('directive edit after the inner hash', 0, PROBES, (t) => editLine(t, 4898, dashToComma));
  const unitLine = firstLine(classify(UNIT, seed(UNIT)).inScope, 'unit');
  filterSeed('unit-file comment edit', 0, UNIT, (t) => editLine(t, unitLine, dashToComma));
  filterSeed('json comment key edit', 0, CADENCE, (t) => editLine(t, 2, dashToComma));
  const promptProse = 58;
  filterSeed('run-prompt prose edit', 0, RUN_PROMPT, (t) => editLine(t, promptProse, dashToComma));
  filterSeed('run-prompt line 20 edit', 0, RUN_PROMPT, (t) => editLine(t, 20, dashToComma));
  filterSeed('fenced shell comment edit', 0, TG_README, (t) => editLine(t, 152, dashToComma));
  filterSeed('docstring line 2 edit', 0, DOCSTRING, (t) => editLine(t, 2, dashToComma));

  // filter, expected to fail.
  const stayed = binClass.stringData[0];
  filterSeed('changed runtime string', 1, BIN, (t) => (noopRuntime ? t : editLine(t, stayed, dashToComma)));
  const seq = stripSeq(seed(SHELL), spansOf(SHELL, seed(SHELL)));
  const assign = /^[A-Za-z_]+=\S*$/;
  const pair = seq.findIndex((l, i) => seq[i + 1] && seq[i + 1].n === l.n + 1 && assign.test(l.text) && assign.test(seq[i + 1].text));
  filterSeed('swapped pair of lines', 1, SHELL, (t) => {
    const lines = t.split('\n');
    const at = seq[pair].n - 1;
    [lines[at], lines[at + 1]] = [lines[at + 1], lines[at]];
    return lines.join('\n');
  });
  filterSeed('directive change before the inner hash', 1, PROBES, (t) => editLine(t, 4898, (l) => l.replace('SC2088', 'SC2089')));
  const depsSeq = stripSeq(seed(DEPS), spansOf(DEPS, seed(DEPS)));
  const depsAt = depsSeq.findIndex((l) => l.n === 629);
  const neighbour = depsSeq[depsAt + 1].n;
  filterSeed('code line edited inside a test heredoc', 1, DEPS, (t) => editLine(editLine(t, 629, dashToComma), neighbour, (l) => `${l} edited`));
  filterSeed('word changed in a heredoc comment', 1, DEPS, (t) => editLine(t, 629, (l) => dashToComma(l).replace(/([a-z]{4,})/, 'changed')));
  filterSeed('code prefix changed on a trailing comment line', 1, PERSIST, (t) => editLine(t, 447, (l) => dashToComma(l).replace(/^(\s*)(\S)/, '$1x$2')));
  filterSeed('heredoc comment turned into code', 1, DEPS, (t) => editLine(t, 629, (l) => dashToComma(l).replace('#', '')));
  filterSeed('dollar gained in a heredoc comment', 1, DEPS, (t) => editLine(t, 629, (l) => `${dashToComma(l)} $`));
  filterSeed('lost backslash on the statusreport line', 1, STATUS, (t) => editLine(t, 900, (l) => dashToComma(l).replaceAll('\\`', '`')));
  filterSeed('lost closing backtick on the statusreport line', 1, STATUS, (t) => editLine(t, 900, (l) => dashToComma(l).replace('state\\`', 'state\\')));
  const quotedBase = editLine(seed(STATUS), 900, (l) => l.replace('exercises', "'exercises'"));
  filterSeed('lost quote on a copy of the statusreport line', 1, STATUS, (t) => editLine(t, 900, (l) => dashToComma(l).replace("'exercises'", "exercises'")), { base: quotedBase });
  filterSeed('one A7 line split into two', 1, DEPS, (t) => editLine(t, 629, (l) => dashToComma(l).replace(', ', ',\n# ')));
  const readmeShape = [];
  walkMarkdown(seed(TG_README), (e) => { if (e.kind === 'fence' && (e.lang === 'bash' || e.lang === 'sh') && !isShellComment(e) && e.line.trim()) readmeShape.push(e.n); });
  filterSeed('fenced code line change', 1, TG_README, (t) => editLine(t, readmeShape[0], (l) => `${l} edited`));
  filterSeed('fence comment line turned into code', 1, TG_README, (t) => editLine(t, 152, (l) => dashToComma(l).replace('#', '')));
  filterSeed('fenced run-prompt line 16 edit', 1, RUN_PROMPT, (t) => editLine(t, 16, dashToComma));
  const linkLine = seed(TG_README).split('\n').findIndex((l) => /\]\([^)\s]+\)/.test(l.replace(INLINE_RE, ''))) + 1;
  filterSeed('changed link target', 1, TG_README, (t) => editLine(t, linkLine, (l) => l.replace(/\]\(([^)\s]+)/, ']($1x')));
  const headingAt = 134;
  const plantedSlug = slugOf(/^#+\s+(.*)$/.exec(lineText(TG_README, headingAt))[1].trim());
  filterSeed('changed heading with a repo link to its old slug', 1, TG_README, (t) => editLine(t, headingAt, dashToComma), { planted: [`docs/planted.md:1:see [x](README.md#${plantedSlug})`] });
  const jsonValue = classify(CADENCE, seed(CADENCE)).otherTypes[0];
  filterSeed('json value edit', 1, CADENCE, (t) => editLine(t, jsonValue, dashToComma));
  const unitSetting = seed(UNIT).split('\n').findIndex((l) => l.trim() && !l.trim().startsWith('#') && !l.startsWith('[')) + 1;
  filterSeed('unit-file setting edit', 1, UNIT, (t) => editLine(t, unitSetting, (l) => `${l} edited`));
  filterSeed('another docstring-file line', 1, DOCSTRING, (t) => editLine(t, 4, (l) => `${l} edited`));
  filterSeed('shebang edit', 1, SHELL, (t) => editLine(t, 1, (l) => `${l} -x`));

  // filter, changed headings with no reader.
  filterSeed('changed heading with no link to its old slug', 0, TG_README, (t) => editLine(t, 259, dashToComma), { listed: 1 });
  for (const [path, n] of [[JIRA_DOC, 1], ...[1, 134, 259, 311, 492, 582, 653, 734].map((l) => [TG_README, l])]) {
    filterSeed(`real heading ${path}:${n} dash replaced`, 0, path, (t) => editLine(t, n, dashToComma), { listed: 1 });
  }

  // The wiring doc line: the exact sentence passes both ways, any other change fails.
  const withWiring = (t) => editLine(t, 40, (l) => `${l}\n${WIRING_LINE}`);
  filterSeed('wiring sentence added', 0, WIRING_DOC, withWiring);
  filterSeed('wiring sentence removed', 0, WIRING_DOC, () => seed(WIRING_DOC), { base: withWiring(seed(WIRING_DOC)) });
  filterSeed('a different line in the wiring doc', 1, WIRING_DOC, (t) => editLine(t, 40, (l) => `${l}\n${WIRING_LINE} Extra.`));
  filterSeed('wiring sentence beside another edit', 1, WIRING_DOC, (t) => editLine(withWiring(t), 1, (l) => `${l} edited`));

  // words.
  wordsSeed('dash to comma', 0, BIN, (t) => editLine(t, binComment, dashToComma));
  wordsSeed('capital after a new sentence', 0, BIN, (t) => editLine(t, binComment, (l) => l.replace(new RegExp(` ${DASH} (.)`), (_, c) => `. ${c.toUpperCase()}`)));
  const tokenOk = wordsSeed('named token replaced by one word', 0, BIN, (t) => editLine(t, binToken, (l) => l.replace(TOKEN_RE, 'also')));
  report('words named token replaced by one word, token section', 1, tokenOk.token.length);
  wordsSeed('changed comment word', 1, BIN, (t) => editLine(t, binComment, (l) => l.replace(/([a-z]{4,})/, 'changed')));
  const docLine = 58;
  wordsSeed('changed docs-text word', 1, JIRA_DOC, (t) => editLine(t, docLine, (l) => l.replace('required', 'needed')));
  wordsSeed('gained because', 1, BIN, (t) => editLine(t, binComment, (l) => `${l} because`));
  wordsSeed('named token replaced with another word changed', 1, BIN, (t) => editLine(t, binToken, (l) => l.replace(new RegExp(`${TOKEN_SRC}[, ]*\\S+`, 'i'), 'also changed')));
  wordsSeed('gitleaks:allow edit', 1, 'scripts/api-lane/measure-credit.sh', (t) => t.replace('gitleaks:allow', 'gitleaks: allow'));
  wordsSeed('ponytail: edit', 1, LEDGER, (t) => editLine(t, 9, (l) => l.replace('ponytail:', 'ponytail :')));

  // I6 on every real A7 line, in memory.
  let a7Dash = 0;
  let a7Files = 0;
  let a7Fail = 0;
  for (const path of git(['ls-tree', '-r', '--name-only', SEED_BASE, '--', 'scripts/himmelctl/test/']).split('\n').filter((p) => p.endsWith('.sh') || JS_RE.test(p))) {
    const base = seed(path);
    const klass = classify(path, base);
    const lines = [...klass.inScope].filter(([, v]) => v.cls === 'a7').map(([n]) => n);
    if (!lines.length) continue;
    a7Files++;
    const head = lines.reduce((t, n) => editLine(t, n, dashToComma), base);
    const r = filterFile(path, base, head);
    a7Dash += r.a7ok.length;
    a7Fail += r.fail.length;
    for (const f of r.fail) console.log(`      ${f}`);
  }
  report('I6 dash to comma over the A7 dash lines, a7-ok', 66, a7Dash);
  report('I6 dash to comma over the A7 dash lines, files', 9, a7Files);
  report('I6 dash to comma over the A7 dash lines, FAIL', 0, a7Fail);
  filterSeed('I6 the A7 token line loses its token', 0, DISABLE, (t) => editLine(t, 1691, (l) => l.replace(TOKEN_DELETE_RE, '')), { a7: 1 });
  filterSeed('I6 an A7 token replaced by a word', 1, DISABLE, (t) => editLine(t, 1691, (l) => l.replace(TOKEN_RE, 'sturdy')));

  // Keep file.
  const keepSeed = (name, want, row) => {
    const { refused } = validateKeep(parseKeep(row.join('\t')), (p) => {
      try { return readSeed(p); } catch { return null; }
    });
    for (const r of refused) console.log(`      ${r}`);
    report(`keep ${name}`, want, refused.length ? 'refused' : 'accepted');
  };
  const kept = binClass.inScope.get(binComment).text;
  const dashAt = kept.indexOf(DASH);
  const fragment = kept.slice(Math.max(0, dashAt - 8), dashAt + 8);
  keepSeed('a bad reason', 'refused', [BIN, 'because', fragment]);
  keepSeed('a quoted row', 'refused', [BIN, 'quoted', fragment]);
  keepSeed('a directive row', 'refused', [PROBES, 'directive', fragment]);
  keepSeed('a gate row whose hash matches no in-scope line', 'refused', [BIN, 'gate:platform-dropped', '0'.repeat(64)]);
  keepSeed('a ruled row with a bogus path:line', 'refused', [BIN, 'ruled:scripts/nope.sh:1', fragment]);
  keepSeed('a ruled row whose reader is the kept line', 'refused', [BIN, `ruled:${BIN}:${binComment}`, fragment]);
  keepSeed('a ruled row whose reader is a comment line', 'refused', ['scripts/himmelctl/lib/launcher.js', 'ruled:scripts/himmelctl/test/test-himmelctl-path-shim.sh:248', ` the link ${DASH} violatin`]);
  keepSeed('a ruled row with an unrelated code-line reader', 'refused', [BIN, `ruled:${BIN}:${stayed}`, fragment]);
  keepSeed('a fragment absent from the kept line', 'refused', [BIN, `ruled:${BIN}:${stayed}`, `absent text ${DASH} absent`]);
  keepSeed('a fragment with no dash', 'refused', [BIN, `ruled:${BIN}:${stayed}`, 'twelve chars or more']);
  const reader = findRealReader(seed);
  keepSeed(`a ruled row with a real reader (${reader.path}:${reader.n})`, 'accepted', [reader.keptPath, `ruled:${reader.path}:${reader.n}`, reader.fragment]);
  keepSeed('a gate row on an A7 line', 'accepted', [DEPS, 'gate:platform-dropped', sha256(lineText(DEPS, 629))]);

  // Exit 2.
  const missing = spawnSync(process.execPath, [SELF, 'count', 'scripts/jira', '--keep', '/nonexistent/keep.tsv'], { encoding: 'utf8' });
  report('count with a --keep path that does not exist exits', 2, missing.status);

  console.log(wrong ? `self-check: ${wrong} control(s) wrong` : 'self-check: every control is right');
  return wrong ? 1 : 0;
}

// A real code line holding the text of an in-scope comment, for the accepted ruled row.
function findRealReader(seed) {
  const path = 'scripts/himmelctl/test/test-wizard-probes.sh';
  const text = seed(path);
  const klass = classify(path, text);
  const lines = text.split('\n');
  for (const n of klass.stringData) {
    const line = lines[n - 1];
    const at = line.indexOf(DASH);
    const fragment = line.slice(Math.max(0, at - 6), at + 8);
    if (fragment.length < 12) continue;
    for (const [keptLine, v] of klass.inScope) {
      if (keptLine !== n && v.text.includes(fragment)) return { keptPath: path, path, n, fragment };
    }
  }
  throw new Refusal('no real reader found for the accepted keep seed');
}

function usage() {
  console.error('usage: check-comment-slop.mjs count <dir> [--keep <file>] | list <dir> | filter [--keep <file>] | words | readers <dir> | self-check [--noop-runtime-seed]');
  process.exit(2);
}

function parseKeepArg(args) {
  if (args.length === 0) return null;
  if (args.length === 2 && args[0] === '--keep') return args[1];
  return usage();
}

async function main() {
  const [verb, ...args] = process.argv.slice(2);
  const known = ['count', 'list', 'filter', 'words', 'readers', 'self-check'];
  if (!known.includes(verb)) usage();
  const dirArg = () => {
    if (!args[0] || args[0].startsWith('--')) usage();
    return args[0].replace(/\/+$/, '');
  };
  if (verb === 'count') {
    const dir = dirArg();
    const keep = parseKeepArg(args.slice(1));
    if (keep && !existsSync(keep)) die(`--keep ${keep} does not exist`);
    await loadTools();
    return cmdCount(dir, keep);
  }
  await loadTools();
  if (verb === 'list') return cmdList(dirArg());
  if (verb === 'readers') return cmdReaders(dirArg());
  if (verb === 'filter') return cmdFilter(parseKeepArg(args));
  if (verb === 'words') return args.length ? usage() : cmdWords();
  if (args.length > 1 || (args.length === 1 && args[0] !== '--noop-runtime-seed')) usage();
  return selfCheck(args[0] === '--noop-runtime-seed');
}

try {
  process.exitCode = await main();
} catch (e) {
  if (!(e instanceof Refusal)) throw e;
  die(e.message);
}
