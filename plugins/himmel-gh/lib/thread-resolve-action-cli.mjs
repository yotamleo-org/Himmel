#!/usr/bin/env node
// thread-resolve-action-cli.mjs — forge-routed PR review-thread resolve (spec
// §5.3), the one sanctioned resolve path for legs and the console. Every
// resolve carries a reason, which is posted as a thread reply BEFORE the
// thread is resolved; a failed reply resolves nothing. The thread is named by
// a 6-char cache prefix (--prefix, after /gh-pr-comments) or by its full id
// (--thread-id, no cache, GitHub only). GitHub uses the GraphQL reply + resolveReviewThread
// mutations; Bitbucket (no GraphQL) routes through the `bitbucket pr reply` /
// `bitbucket pr resolve` CLI verbs. Prints a `resolved: ok` summary line the
// runner's --summary-regex captures.
//
// (Distinct from thread-resolve-cli.mjs, which only expands prefix → id and is
// kept for back-compat.)

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { expandPrefix } from './thread-prefix.mjs';
import { detectForge } from './forge/detect.mjs';
import { replyThread, resolveThread } from './forge/bitbucket-threads.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPLY_QUERY_FILE = join(__dirname, '..', 'graphql', 'reply-thread.gql');
const RESOLVE_QUERY_FILE = join(__dirname, '..', 'graphql', 'resolve-thread.gql');
const THREAD_PR_QUERY_FILE = join(__dirname, '..', 'graphql', 'thread-pr.gql');

const USAGE =
  'usage: thread-resolve-action-cli.mjs --owner O --repo R --number N (--prefix P | --thread-id ID)\n' +
  '         --reason "fixed <sha>" | "followup <KEY-n>" | "rejected <why>"\n';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[a.slice(2)] = next;
      i++;
    } else {
      out[a.slice(2)] = true;
    }
  }
  return out;
}

// The reason vocabulary → the reply body posted on the thread, or null.
function replyBody(reason) {
  if (typeof reason !== 'string') return null;
  let m = reason.match(/^fixed ([0-9a-f]{7,40})$/);
  if (m) return `Fixed at ${m[1]}.`;
  m = reason.match(/^followup ([A-Z][A-Z0-9]*-[0-9]+)$/);
  if (m) return `Follow-up: ${m[1]}.`;
  m = reason.match(/^rejected (\S.*)$/);
  if (m) return `Rejected: ${m[1].trim().replace(/\.$/, '')}.`;
  return null;
}

function execGh(args) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const proc = spawn('gh', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', (err) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      resolve({ stdout, stderr: `${stderr}${err.message}\n`, exitCode: code });
    });
    proc.on('close', (code, signal) => {
      const exitCode = code ?? (signal ? 129 : 1);
      const finalStderr = signal ? `${stderr}gh killed by signal ${signal}\n` : stderr;
      resolve({ stdout, stderr: finalStderr, exitCode });
    });
  });
}

// -f (raw-field) for threadId and body so a value is never interpreted as
// `@file` or type-coerced; -F only for the query, where `@file` must expand to
// the .gql.
async function ghStep(what, threadId, extra, queryFile) {
  const res = await execGh(['api', 'graphql', '-f', `threadId=${threadId}`, ...extra, '-F', `query=@${queryFile}`]);
  if (res.exitCode !== 0) {
    process.stderr.write(res.stderr || `gh api graphql ${what} failed (exit ${res.exitCode})\n`);
    process.exit(res.exitCode);
  }
  if (res.stdout.trim()) process.stdout.write(`${res.stdout.trim()}\n`);
}

// A full thread id is not scoped by the cache, so check it sits on the named
// PR before writing anything to it.
async function assertThreadOnPr(threadId) {
  const res = await execGh(['api', 'graphql', '-f', `threadId=${threadId}`, '-F', `query=@${THREAD_PR_QUERY_FILE}`]);
  if (res.exitCode !== 0) {
    process.stderr.write(res.stderr || `gh api graphql thread lookup failed (exit ${res.exitCode})\n`);
    process.exit(res.exitCode);
  }
  let pr;
  try {
    pr = JSON.parse(res.stdout).data?.node?.pullRequest;
  } catch {
    pr = undefined;
  }
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  if (
    !pr ||
    pr.number !== Number(number) ||
    !same(pr.repository?.owner?.login, owner) ||
    !same(pr.repository?.name, repo)
  ) {
    process.stderr.write(`refused: thread ${threadId} is not on ${owner}/${repo}#${number}\n`);
    process.exit(2);
  }
}

const args = parseArgs(process.argv.slice(2));
const { owner, repo, number, prefix, reason } = args;
const threadIdArg = args['thread-id'];

if (!owner || !repo || !number || (!prefix && !threadIdArg) || (prefix && threadIdArg)) {
  process.stderr.write(USAGE);
  process.exit(2);
}
if (reason === undefined || reason === true) {
  process.stderr.write(`refused: a resolve needs --reason\n${USAGE}`);
  process.exit(2);
}
const body = replyBody(reason);
if (!body) {
  process.stderr.write(
    `refused: reason must be "fixed <7-40 hex sha>", "followup <KEY-n>" or "rejected <why>" (got "${reason}")\n`,
  );
  process.exit(2);
}

const forge = detectForge();
// Bitbucket has no thread → PR lookup yet, so a full id there could write to
// a thread on another PR. Only the PR-scoped --prefix is accepted.
// ponytail: Bitbucket --thread-id refused outright, HIMMEL-6399 adds the check.
if (threadIdArg && forge === 'bitbucket') {
  process.stderr.write('refused: --thread-id is not checked against the PR on Bitbucket; use --prefix\n');
  process.exit(2);
}

let threadId = threadIdArg;
if (!threadId) {
  const expanded = expandPrefix({ owner, repo, number, prefix });
  if (!expanded.ok) {
    process.stderr.write(`${expanded.message}\n`);
    process.exit(1);
  }
  threadId = expanded.id;
}

if (forge === 'bitbucket') {
  try {
    const replied = await replyThread({ number: Number(number), id: threadId, body });
    if (replied.trim()) process.stdout.write(`${replied.trim()}\n`);
    const out = await resolveThread({ number: Number(number), id: threadId });
    if (out.trim()) process.stdout.write(`${out.trim()}\n`);
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
} else {
  await assertThreadOnPr(threadId);
  await ghStep('reply', threadId, ['-f', `body=${body}`], REPLY_QUERY_FILE);
  await ghStep('resolve', threadId, [], RESOLVE_QUERY_FILE);
}

process.stdout.write('resolved: ok\n');

// Event point 4 of the ci:go release: a resolved thread may clear the reviewer
// gate at the head. Best effort and GitHub only; the lib reads the CI_GO_GATE
// switch first and prints nothing when it is off, and a failure here never
// changes this command's result.
if (forge !== 'bitbucket') {
  try {
    const lib = join(__dirname, '..', '..', '..', 'scripts', 'lib', 'cr-first-release.sh');
    const head = await execGh(['pr', 'view', String(number), '--repo', `${owner}/${repo}`, '--json', 'headRefOid', '-q', '.headRefOid']);
    const sha = head.stdout.trim();
    if (head.exitCode === 0 && /^[0-9a-f]{40}$/.test(sha) && existsSync(lib)) {
      await new Promise((resolve) => {
        const p = spawn('bash', [lib, '--pr', String(number), '--head', sha, '--repo', `${owner}/${repo}`], { stdio: ['ignore', 'inherit', 'inherit'], timeout: 60000 });
        p.on('error', resolve);
        p.on('close', resolve);
      });
    }
  } catch {
    // best effort
  }
}
