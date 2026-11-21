import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { extname, join, relative, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import { vendoredRoot } from '../lanes/skill-cost.mjs';

export const EXTENSIONS = ['.js', '.mjs', '.cjs', '.jsx', '.ts', '.mts', '.cts', '.tsx'];

const EXCLUDED_SEGMENTS = new Set(['dist', 'node_modules', 'fixture', 'fixtures', '__fixtures__']);
const E2E = '\\.e2e\\.[^/]*$';
const ALLOW_TSV = 'scripts/lint/ticket-ref-allow.tsv';
const CONFIG = 'scripts/lint/landmines/.oxlintrc.json';
const PLUGIN = 'landmines-testing';
const RULES = ['no-fixed-sleep', 'no-flake-masking', 'no-unsignaled-poll'];

const TRIGGERS = [
  '(.*/)?VENDORED\\.md',
  'scripts/lint/(test-)?check-test-honesty\\.sh',
  'scripts/lint/honesty-surface\\.mjs',
  'scripts/lanes/skill-cost\\.mjs',
  'scripts/lint/ticket-ref-allow\\.tsv',
  'scripts/lint/landmines/(\\.oxlintrc\\.json|package\\.json|bun\\.lock|bunfig\\.toml)',
  '\\.github/workflows/ci\\.yml',
  '\\.pre-commit-config\\.yaml',
  '(.*/)?oxlint-suppressions\\.json',
];

function repoRoot() {
  return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
}

const patterns = new Map();

function testPattern(root) {
  if (patterns.has(root)) return patterns.get(root);
  const file = join(root, ALLOW_TSV);
  let row;
  try {
    row = readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.split('\t'))
      .find((cols) => cols[0] === 'test' && cols[1]);
  } catch (err) {
    throw new Error(`cannot read ${ALLOW_TSV}: ${err.message}`);
  }
  if (!row) throw new Error(`no test row in ${ALLOW_TSV}`);
  const re = new RegExp(`${row[1]}|${E2E}`);
  patterns.set(root, re);
  return re;
}

export function isSurface(relPath, root) {
  if (!EXTENSIONS.includes(extname(relPath))) return false;
  const re = testPattern(root);
  if (!re.test(relPath)) return false;
  if (relPath.split('/').slice(0, -1).some((seg) => EXCLUDED_SEGMENTS.has(seg))) return false;
  return vendoredRoot(join(root, relPath), root) === null;
}

function surfaceFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 1 << 28 });
  return out
    .split('\0')
    .filter((p) => p && existsSync(join(root, p)) && isSurface(p, root));
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function readConfig(root) {
  return JSON.parse(readFileSync(join(root, CONFIG), 'utf8'));
}

export function checkConfig(root) {
  let cfg;
  try {
    cfg = readConfig(root);
  } catch (err) {
    return [`${CONFIG}: cannot read (${err.message})`];
  }
  if (!isPlainObject(cfg)) return [`${CONFIG}: not a JSON object`];
  const bad = [];
  const top = ['jsPlugins', 'categories', 'options', 'rules'];
  const keys = Object.keys(cfg).sort();
  if (!isDeepStrictEqual(keys, [...top].sort())) {
    bad.push(`${CONFIG}: top-level keys are ${JSON.stringify(keys)}, expected exactly ${JSON.stringify(top)}`);
  }
  const plugins = [{ name: PLUGIN, specifier: '@interfere/landmines/testing' }];
  if (!isDeepStrictEqual(cfg.jsPlugins, plugins)) {
    bad.push(`${CONFIG}: jsPlugins must be exactly ${JSON.stringify(plugins)}`);
  }
  const cats = cfg.categories;
  const catNames = ['correctness', 'suspicious', 'pedantic', 'perf', 'style', 'restriction', 'nursery'];
  if (!isDeepStrictEqual(cats, Object.fromEntries(catNames.map((c) => [c, 'off'])))) {
    bad.push(`${CONFIG}: categories must be exactly ${JSON.stringify(catNames)}, each "off"`);
  }
  if (!isDeepStrictEqual(cfg.options, { respectEslintDisableDirectives: false })) {
    bad.push(`${CONFIG}: options must be exactly {"respectEslintDisableDirectives":false}`);
  }
  const rules = cfg.rules;
  const want = RULES.map((r) => `${PLUGIN}/${r}`);
  if (!isPlainObject(rules) || !isDeepStrictEqual(Object.keys(rules).sort(), [...want].sort())) {
    bad.push(`${CONFIG}: rules must be exactly ${JSON.stringify(want)}`);
    return bad;
  }
  for (const name of want) {
    const entry = rules[name];
    const ok = Array.isArray(entry)
      && entry.length === 2
      && entry[0] === 'error'
      && isPlainObject(entry[1])
      && isDeepStrictEqual(Object.keys(entry[1]), ['allow'])
      && isPlainObject(entry[1].allow)
      && Object.values(entry[1].allow).every((n) => Number.isInteger(n) && n > 0);
    if (!ok) bad.push(`${CONFIG}: ${name} must be ["error", {"allow": {<path>: <positive integer>}}] and nothing else`);
  }
  return bad;
}

function checkKeys(root) {
  const bad = checkConfig(root);
  if (bad.length) return bad;
  const cfg = readConfig(root);
  const files = surfaceFiles(root);
  const live = new Set(files);
  for (const rule of RULES) {
    const name = `${PLUGIN}/${rule}`;
    for (const key of Object.keys(cfg.rules[name][1].allow)) {
      if (!live.has(key)) {
        bad.push(`orphan allow key ${name} ${key}`);
        continue;
      }
      for (const other of files) {
        if (other !== key && other.endsWith(`/${key}`)) bad.push(`twin allow key ${name} ${key} ${other}`);
      }
    }
  }
  return bad;
}

const SHAPE_RULE = '(?:@[a-z0-9-]+/)?[a-z][a-z0-9-]*(?:/[a-z0-9-]+)?';
const SHAPE = new RegExp(
  `^(?:oxlint|eslint)-disable(?:-next-line|-line)? (${SHAPE_RULE}(?:, ?${SHAPE_RULE})*)(?: -- [^\\n\\t]*)?$`,
);
const DISABLE_WORD = /(oxlint|eslint)-disable/gi;

function parserPlugins(file) {
  if (file.endsWith('.tsx')) return ['typescript', 'jsx'];
  if (/\.[mc]?ts$/.test(file)) return ['typescript'];
  return ['jsx'];
}

function guardedRule(rule) {
  return rule.includes('landmines') || RULES.some((r) => rule.endsWith(r));
}

const parsers = new Map();

function babelParse(root) {
  if (!parsers.has(root)) {
    parsers.set(root, createRequire(join(root, 'scripts/lint/landmines/package.json'))('@babel/parser').parse);
  }
  return parsers.get(root);
}

export function checkDirectives(absPath, root = repoRoot()) {
  const parse = babelParse(root);
  const shown = relative(root, absPath).split(sep).join('/');
  const src = readFileSync(absPath, 'utf8');
  let ast;
  try {
    ast = parse(src, {
      sourceType: 'unambiguous',
      plugins: parserPlugins(absPath),
      errorRecovery: false,
      allowReturnOutsideFunction: true,
      allowAwaitOutsideFunction: true,
    });
  } catch (err) {
    return [`${shown}: parse failed (${String(err.message).replace(/\s+/g, ' ')})`];
  }
  const passing = [];
  for (const c of ast.comments) {
    if ((c.value.match(DISABLE_WORD) || []).length !== 1) continue;
    const text = c.type === 'CommentLine' ? c.value.replace(/^ /, '') : c.value.replace(/^ /, '').replace(/ $/, '');
    const m = SHAPE.exec(text);
    if (m && !m[1].split(/, ?/).some(guardedRule)) passing.push([c.start, c.end]);
  }
  const bad = [];
  for (const occ of src.matchAll(DISABLE_WORD)) {
    if (passing.some(([start, end]) => occ.index >= start && occ.index < end)) continue;
    const line = src.slice(0, occ.index).split('\n').length;
    const text = JSON.stringify(src.slice(occ.index, occ.index + 60)).slice(0, 80);
    bad.push(`${shown}:${line}: refused directive: ${text}`);
  }
  return bad;
}

function triggers() {
  return `(${TRIGGERS.join('|')})`;
}

function precommitFiles() {
  const exts = EXTENSIONS.map((e) => e.slice(1)).join('|');
  return `^(${triggers()}|.*\\.(${exts}))$`;
}

function selected(root, paths) {
  const files = surfaceFiles(root);
  if (!paths.length) return files;
  const want = new Set(paths.map((p) => relative(root, resolve(p)).split(sep).join('/')));
  return files.filter((f) => want.has(f));
}

function run(argv) {
  const [flag, ...paths] = argv;
  const lines = [];
  switch (flag) {
    case '--triggers':
      return [[triggers()], 0];
    case '--precommit-files':
      return [[precommitFiles()], 0];
    case '--list':
      return [selected(repoRoot(), paths), 0];
    case '--check-keys':
      lines.push(...checkKeys(repoRoot()));
      return [lines, lines.length ? 1 : 0];
    case '--check-directives': {
      const root = repoRoot();
      for (const f of selected(root, paths)) lines.push(...checkDirectives(join(root, f), root));
      return [lines, lines.length ? 1 : 0];
    }
    default:
      throw new Error('usage: honesty-surface.mjs --list|--check-keys|--check-directives [PATH...] | --triggers | --precommit-files');
  }
}

function isMain() {
  try {
    return Boolean(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (isMain()) {
  try {
    const [lines, code] = run(process.argv.slice(2));
    for (const line of lines) console.log(line);
    process.exitCode = code;
  } catch (err) {
    console.error(`honesty-surface: ${err.message}`);
    process.exitCode = 1;
  }
}
