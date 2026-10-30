'use strict';
// scripts/himmelctl/lib/helpers.js — shared helpers extracted out of bin.js
// Pure refactor: same implementations, same call sites,
// same seam env vars (HIMMELCTL_CACHE_DIR) — bin.js now `require`s these
// instead of defining them inline.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Resolve <tool> on PATH like `command -v` would, checking the bare name.
// Uses path.delimiter, which is the separator Node actually sees in
// process.env.PATH.
//
// optional `env` param, defaulting to
// process.env when omitted — preserves probeDep's documented exception
// (probes.js: which() reads process.env.PATH directly by design, a hermetic
// test controls it via the OUTER shell PATH, not ctx.env), while letting a
// caller that already threads a fully-controlled ctx.env (probeMcpRegistered's
// bin check) resolve PATH from THAT env instead of silently falling back to
// the real process env. The `env.Path` fallback mirrors scripts/lanes/
// resolve.mjs's pathHasFactory() — a manually-constructed env object can carry
// either casing.
//
// pick the first KEY PRESENT, not the
// first TRUTHY value. `e.PATH || e.Path || ''` treated a deliberately
// scrubbed `PATH: ''` as falsy and fell through to `e.Path` — so a hermetic
// caller that explicitly empties PATH (to prove "nothing resolves") silently
// resolved from an inherited `Path` instead, defeating the scrub.
function which(tool, env) {
  const e = env || process.env;
  const rawPath = ('PATH' in e) ? e.PATH : (('Path' in e) ? e.Path : '');
  const dirs = String(rawPath || '').split(path.delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    try {
      if (fs.existsSync(path.join(dir, tool))) return path.join(dir, tool);
    } catch (_e) { /* unreadable dir — skip */ }
  }
  return null;
}

// The interactive answers are cached so the same install can be replayed
// non-interactively via --from-profile. The cache dir defaults to
// ~/.claude/himmel/ but is overridable via HIMMELCTL_CACHE_DIR — same class of
// seam as HIMMELCTL_INTERACTIVE, and genuinely useful for CI and hermetic tests.
function cacheDir() {
  return process.env.HIMMELCTL_CACHE_DIR || path.join(os.homedir(), '.claude', 'himmel');
}

// T5a (locked Q4): map a vault mode to an adopt.sh profile.
//   none             → core
//   default-template → all (adopt.sh itself scaffolds the vault from
//                      templates/luna-second-brain — the wizard must NOT call
//                      luna-upgrade-all.sh or wire-luna-vault.sh here).
//   existing         → handled BEFORE this is reached (see the runPlan gate
//                       below) — T5b, STAMPED-only (see isStampedLunaVault).
function profileForVault(answers) {
  const mode = answers.vault && answers.vault.mode;
  return mode === 'default-template' ? 'all' : 'core';
}

// Forward-slash a path for DISPLAY in a diagnostic that tells the operator to
// run something. Display only; nothing compares against this.
function displayPath(p) {
  return String(p).split(path.sep).join('/');
}

// Shell-quote one arg for DISPLAY only (the spawn below uses argv directly,
// no shell — this only affects the printed `derived:` line).
function shellQuote(a) {
  return /\s/.test(a) ? `'${String(a).replace(/'/g, "'\\''")}'` : a;
}

// `node <script>` for a printed hint. Every printed
// "run this" line must work from ANY cwd — the operator pastes it from the
// project the summary was printed for, not from the himmel clone — so the
// script path is absolute (callers pass __filename or a path joined onto the
// clone root, never a clone-relative literal), forward-slashed and quoted.
// Unlike shellQuote (whitespace only, for the display-only `derived:` line) this
// pastes into a shell, so anything outside a plain-path charset is single-quoted:
// a `$`, `;`, `&`, backtick or apostrophe in the install path must stay inert.
const SHELL_SAFE_PATH = /^[A-Za-z0-9_@%+=:,./-]+$/;
function nodeScriptCmd(scriptPath) {
  const p = displayPath(scriptPath);
  return `node ${SHELL_SAFE_PATH.test(p) ? p : `'${p.replace(/'/g, "'\\''")}'`}`;
}

// himmelIdentity(root) — the ONE answer to "which himmel is this",
// shared by `--version` and the config feed. `version` is the VERSION file (the
// declared release line, bumped at release cut); `describe` and `commit` are the
// checkout's own git state and are the truth about what is running, so they can
// read ahead of `version` (v1.0.2-pre.1-N-g<sha> vs 1.0.0). NEVER throws:
// anything unreadable is the string 'unknown'.
function himmelIdentity(root) {
  const { spawnSync } = require('child_process');
  let version = 'unknown';
  try {
    version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim() || 'unknown';
  } catch {
    // fall through to 'unknown'
  }
  const git = (...gitArgs) => {
    // Only a root that is itself a checkout: without this an install dir
    // nested in some other repo would report THAT repo's describe/commit.
    if (!fs.existsSync(path.join(root, '.git'))) return 'unknown';
    const r = spawnSync('git', ['-C', root, ...gitArgs], { encoding: 'utf8' });
    const out = r.status === 0 && typeof r.stdout === 'string' ? r.stdout.trim() : '';
    return out || 'unknown';
  };
  return { version, describe: git('describe', '--tags', '--always'), commit: git('rev-parse', 'HEAD'), checkout: root };
}

module.exports = { himmelIdentity, cacheDir, profileForVault, which, displayPath, shellQuote, nodeScriptCmd };
