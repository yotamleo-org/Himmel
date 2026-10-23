#!/usr/bin/env node
// scripts/ci/check-lockfile-release-age.mjs — fail on a lockfile entry whose
// release is younger than N days, unless it is allowlisted as a security fix.
// A hijacked release is usually pulled within hours; an entry that
// has been public for 3 days has survived that window.
//
// The npm registry is the only source of publish times, so this needs the network:
// the per-PR gate .github/workflows/lockfile-release-age.yml runs it with --base, and
// fails closed when a publish time cannot be read. `--times` swaps the registry for a
// file, which is how the test runs offline.
//
// Usage:
//   check-lockfile-release-age.mjs [--days N] [--now ISO] [--times FILE]
//                                  [--allow FILE] [--root DIR] [--base SHA] [lockfile ...]
//   default lockfiles: every tracked package-lock.json / bun.lock under --root
//   (default: the checkout this lives in), except the benchmark fixtures.
//   --times FILE   JSON {"name@version": "<ISO publish time>"}; no network
//   --allow FILE   default scripts/ci/release-age-allow.txt: `name@version  reason`
//   --base SHA     check only entries a lockfile gained since commit SHA (the PR gate);
//                  an entry already on the base is not this change's to answer for
//
// Exit codes:
//   0 — every entry is old enough (or allowlisted)
//   1 — at least one young entry (printed as `YOUNG: ...`)
//   2 — no young entry found, but a publish time could not be read (`UNKNOWN: ...`)
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const opts = { days: 3, now: null, times: null, base: null, allow: join(here, 'release-age-allow.txt'), root: resolve(here, '../..') };
const files = [];
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--days') opts.days = Number(argv[++i]);
  else if (a === '--now') opts.now = argv[++i];
  else if (a === '--times') opts.times = argv[++i];
  else if (a === '--allow') opts.allow = argv[++i];
  else if (a === '--root') opts.root = resolve(argv[++i]);
  else if (a === '--base') opts.base = argv[++i];
  else files.push(a);
}
if (!Number.isFinite(opts.days) || opts.days <= 0) { console.error('ERROR: --days must be a positive number'); process.exit(2); }
const now = opts.now ? Date.parse(opts.now) : Date.now();
if (Number.isNaN(now)) { console.error('ERROR: --now is not a date'); process.exit(2); }

const EXEMPT = ['scripts/lanes/bench/fixtures/'];

function trackedLockfiles(root) {
  const out = execFileSync('git', ['-C', root, 'ls-files'], { encoding: 'utf8' });
  return out.split('\n')
    .filter((p) => /(^|\/)(package-lock\.json|bun\.lock)$/.test(p) && !EXEMPT.some((e) => p.startsWith(e)))
    .map((p) => join(root, p));
}

// name@version for every registry-resolved entry of one lockfile's text.
function parse(file, text) {
  const found = [];
  if (file.endsWith('package-lock.json')) {
    for (const [key, v] of Object.entries(JSON.parse(text).packages ?? {})) {
      const at = key.lastIndexOf('node_modules/');
      if (at < 0 || !v.version || v.link || !/^https?:/.test(v.resolved ?? '')) continue;
      // An npm alias (`compat@npm:actual@1`) is installed under one name and published under v.name.
      found.push(`${v.name ?? key.slice(at + 'node_modules/'.length)}@${v.version}`);
    }
  } else {
    // bun.lock is JSONC: trailing commas only.
    const lock = JSON.parse(text.replace(/,(\s*[}\]])/g, '$1'));
    for (const v of Object.values(lock.packages ?? {})) {
      const id = Array.isArray(v) ? v[0] : '';
      const at = id.lastIndexOf('@');
      if (at > 0 && /^\d+\.\d+\.\d+/.test(id.slice(at + 1))) found.push(id);
    }
  }
  return found;
}

function readAllow(file) {
  if (!existsSync(file)) return new Set();
  return new Set(readFileSync(file, 'utf8').split('\n')
    .map((l) => l.replace(/#.*$/, '').trim().split(/\s+/)[0])
    .filter(Boolean));
}

async function registryTimes(names) {
  const times = new Map();
  const queue = [...names];
  const worker = async () => {
    for (let name = queue.pop(); name; name = queue.pop()) {
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const r = await fetch(`https://registry.npmjs.org/${name.replace('/', '%2F')}`, { signal: AbortSignal.timeout(30000) });
          if (r.ok) {
            for (const [ver, t] of Object.entries((await r.json()).time ?? {})) times.set(`${name}@${ver}`, t);
            break;
          }
        } catch { /* retry; after the last attempt the entry stays UNKNOWN */ }
        await new Promise((done) => setTimeout(done, attempt * 2000));
      }
    }
  };
  await Promise.all(Array.from({ length: 8 }, worker));
  return times;
}

const lockfiles = files.length ? files.map((f) => resolve(f)) : trackedLockfiles(opts.root);
const rel = (f) => (f.startsWith(`${opts.root}/`) ? f.slice(opts.root.length + 1) : f);

// The lockfile's entries at --base; an absent file means every entry is new.
function baseIds(file) {
  try {
    const text = execFileSync('git', ['-C', opts.root, 'show', `${opts.base}:${rel(file)}`],
      { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] });
    return new Set(parse(file, text));
  } catch { return new Set(); }
}

const perFile = lockfiles.map((f) => {
  const ids = parse(f, readFileSync(f, 'utf8'));
  if (!opts.base) return { file: f, ids };
  const before = baseIds(f);
  return { file: f, ids: ids.filter((id) => !before.has(id)) };
});
const allIds = new Set(perFile.flatMap((p) => p.ids));
const times = opts.times
  ? new Map(Object.entries(JSON.parse(readFileSync(opts.times, 'utf8'))))
  : await registryTimes(new Set([...allIds].map((id) => id.slice(0, id.lastIndexOf('@')))));
const allow = readAllow(opts.allow);

let young = 0;
let unknown = 0;
let allowed = 0;
for (const { file, ids } of perFile) {
  for (const id of ids) {
    const t = times.get(id);
    if (!t) { console.log(`UNKNOWN: ${rel(file)}: ${id} has no publish time`); unknown++; continue; }
    const age = (now - Date.parse(t)) / 86400000;
    if (age >= opts.days) continue;
    if (allow.has(id)) { allowed++; continue; }
    console.log(`YOUNG: ${rel(file)}: ${id} published ${t} (${age.toFixed(1)} days old, below ${opts.days})`);
    young++;
  }
}
console.log(`release-age: ${allIds.size} unique entr${allIds.size === 1 ? 'y' : 'ies'} in ${lockfiles.length} lockfile(s), ${young} young, ${allowed} allowlisted, ${unknown} unknown`);
process.exit(young ? 1 : unknown ? 2 : 0);
