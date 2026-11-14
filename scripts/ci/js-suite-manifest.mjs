#!/usr/bin/env node
// scripts/ci/js-suite-manifest.mjs — turns each JS/TS runner's own report into
// the per-file lines item 19 reads, beside the shell shard manifest:
//   ran <rc> <repo-relative path>    skip <repo-relative path>
//
//   js-suite-manifest.mjs --out <file> --report <node|bun|vitest> <report-file> <cwd> [--report ...]
//
// Per file, from the reports only (no glob, no suffix list):
//   node    a counted pass is a test:pass of kind "test", skip and todo unset, that
//           is no parent (the line before it for the same file has no greater
//           nesting) and is not the pass node writes for a file with no tests
//           (named after its file); skip or todo set is a skip (a failing todo
//           too); any other test:fail is a failure.
//   bun     the top-level <testsuite> (no line=): tests - failures - skipped
//           passes, skipped skips, failures fail.
//   vitest  an assertionResults[] status "passed" passes; skipped, pending, todo
//           or disabled skips; "failed", or a file status "failed", fails.
// Then: any failure is `ran 1`, a counted pass `ran 0` (with a skip too, also a
// `::notice title=js-suite-mixed::<path>` on stdout), only skips `skip`, else no
// line. A path resolves against its report's <cwd> and is kept only when
// `git ls-files` lists it. A missing or unreadable report prints a ::warning and
// gives no lines. Exit 0 once the arguments parse: a writer fault means fewer
// lines, so suites go local, never a red CI step.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { dirname, resolve, relative, isAbsolute, sep } from 'node:path';
import { execFileSync } from 'node:child_process';

const USAGE = 'usage: js-suite-manifest.mjs --out <file> --report <node|bun|vitest> <report-file> <cwd> [--report ...]';

function parseArgs(argv) {
  let out = '';
  const reports = [];
  for (let i = 0; i < argv.length; ) {
    if (argv[i] === '--out' && i + 1 < argv.length) {
      out = argv[i + 1];
      i += 2;
    } else if (argv[i] === '--report' && i + 3 < argv.length && ['node', 'bun', 'vitest'].includes(argv[i + 1])) {
      reports.push({ kind: argv[i + 1], file: argv[i + 2], cwd: argv[i + 3] });
      i += 4;
    } else {
      return null;
    }
  }
  return out && reports.length ? { out, reports } : null;
}

function warn(msg) {
  process.stdout.write(`::warning title=js-suite-manifest::${msg}\n`);
}

// count(tally, absPath, kind) — kind is 'pass', 'skip' or 'fail'.
function count(tally, absPath, kind, n = 1) {
  if (!absPath || n <= 0) return;
  const t = tally.get(absPath) || { pass: 0, skip: 0, fail: 0 };
  t[kind] += n;
  tally.set(absPath, t);
}

function readNode(text, cwd, tally) {
  const lastNesting = new Map();
  for (const raw of text.split('\n')) {
    let e;
    try {
      e = JSON.parse(raw);
    } catch {
      continue;
    }
    if (!e || typeof e.file !== 'string') continue;
    const file = resolve(cwd, e.file);
    const nesting = Number.isInteger(e.nesting) ? e.nesting : 0;
    const prev = lastNesting.get(file);
    lastNesting.set(file, nesting);
    if (e.skip || e.todo) {
      count(tally, file, 'skip');
    } else if (e.fail) {
      count(tally, file, 'fail');
    } else if (e.kind === 'test' && !(prev !== undefined && prev > nesting) && !namesItsFile(e.name, file)) {
      count(tally, file, 'pass');
    }
  }
}

function namesItsFile(name, file) {
  return typeof name === 'string' && name !== '' && (file === name || file.endsWith(sep + name) || file.endsWith('/' + name));
}

function xmlAttrs(tag) {
  const attrs = {};
  for (const m of tag.matchAll(/([A-Za-z_][\w.-]*)="([^"]*)"/g)) attrs[m[1]] = m[2];
  return attrs;
}

function unescapeXml(s) {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, '&');
}

function readBun(text, cwd, tally) {
  for (const m of text.matchAll(/<testsuite\s([^>]*)>/g)) {
    const a = xmlAttrs(m[1]);
    if ('line' in a || typeof a.file !== 'string') continue;
    const file = resolve(cwd, unescapeXml(a.file));
    const tests = Number(a.tests) || 0;
    const failures = Number(a.failures) || 0;
    const skipped = Number(a.skipped) || 0;
    count(tally, file, 'fail', failures);
    count(tally, file, 'skip', skipped);
    count(tally, file, 'pass', tests - failures - skipped);
  }
}

const VITEST_SKIP = new Set(['skipped', 'pending', 'todo', 'disabled']);

function readVitest(text, cwd, tally) {
  const report = JSON.parse(text);
  for (const r of Array.isArray(report?.testResults) ? report.testResults : []) {
    if (!r || typeof r.name !== 'string') continue;
    const file = resolve(cwd, r.name);
    if (r.status === 'failed') count(tally, file, 'fail');
    for (const a of Array.isArray(r.assertionResults) ? r.assertionResults : []) {
      if (a?.status === 'passed') count(tally, file, 'pass');
      else if (a?.status === 'failed') count(tally, file, 'fail');
      else if (VITEST_SKIP.has(a?.status)) count(tally, file, 'skip');
    }
  }
}

const READERS = { node: readNode, bun: readBun, vitest: readVitest };

function repoRelative(root, tracked, abs) {
  for (const candidate of [abs, safeRealpath(abs)]) {
    if (!candidate) continue;
    const rel = relative(root, candidate);
    if (rel && !rel.startsWith('..') && !isAbsolute(rel)) {
      const posix = rel.split(sep).join('/');
      if (tracked.has(posix)) return posix;
    }
  }
  return '';
}

function safeRealpath(p) {
  try {
    return realpathSync(p);
  } catch {
    return '';
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args) {
    process.stderr.write(`${USAGE}\n`);
    return 2;
  }
  try {
    const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
    const tracked = new Set(
      execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
        .split('\0')
        .filter(Boolean),
    );
    const tally = new Map();
    for (const r of args.reports) {
      let text;
      try {
        text = readFileSync(r.file, 'utf8');
      } catch {
        warn(`cannot read the ${r.kind} report ${r.file}, so its suites go local`);
        continue;
      }
      try {
        READERS[r.kind](text, resolve(r.cwd), tally);
      } catch {
        warn(`cannot parse the ${r.kind} report ${r.file}, so its suites go local`);
      }
    }
    const byPath = new Map();
    for (const [abs, t] of tally) {
      const rel = repoRelative(root, tracked, abs);
      if (!rel) continue;
      const s = byPath.get(rel) || { pass: 0, skip: 0, fail: 0 };
      s.pass += t.pass;
      s.skip += t.skip;
      s.fail += t.fail;
      byPath.set(rel, s);
    }
    const lines = [];
    for (const rel of [...byPath.keys()].sort()) {
      const s = byPath.get(rel);
      if (s.fail > 0) {
        lines.push(`ran 1 ${rel}`);
      } else if (s.pass > 0) {
        lines.push(`ran 0 ${rel}`);
        if (s.skip > 0) process.stdout.write(`::notice title=js-suite-mixed::${rel}\n`);
      } else if (s.skip > 0) {
        lines.push(`skip ${rel}`);
      }
    }
    mkdirSync(dirname(resolve(args.out)), { recursive: true });
    writeFileSync(args.out, lines.length ? `${lines.join('\n')}\n` : '');
    process.stdout.write(`js-suite-manifest: ${lines.length} line(s) to ${args.out}\n`);
  } catch (err) {
    warn(`the writer failed (${err && err.message ? err.message.split('\n')[0] : err}), so these suites go local`);
  }
  return 0;
}

process.exitCode = main();
