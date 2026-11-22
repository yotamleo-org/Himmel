// scripts/lib/status-marker.mjs -- JS twin of scripts/lib/status-marker.sh.
// Same rows, same answers: both are pinned to fixtures/status-marker-rows.tsv
// by status-marker.test.mjs and test-status-marker.sh.
//
//   statusMarkerParse(line)    the marker a results bullet leads with, in its
//                              canonical spelling (PARKED-BANK is returned as
//                              PARKED-USAGE), or null when the line has none
//   statusMarkerIsParked(word) true for PARKED-BANK and PARKED-USAGE
//
// CLI: node status-marker.mjs parse LINE -> marker on stdout, exit 0, or exit 1
// when there is none; is-parked WORD -> exit 0 or 1; bad usage exits 2.
import { isMain } from './is-main.mjs';
import { readFileSync, statSync } from 'node:fs';

const MARKER = /^- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)(?:[^A-Za-z0-9_][\s\S]*)?$/;

export function statusMarkerParse(line) {
  const m = MARKER.exec(line);
  if (!m) return null;
  return m[1] === 'PARKED-BANK' ? 'PARKED-USAGE' : m[1];
}

export function statusMarkerIsParked(word) {
  return word === 'PARKED-BANK' || word === 'PARKED-USAGE';
}

const FENCE = /^ {0,3}(`{3,}|~{3,})([^\n]*)$/;
const RESULTS = /^## Results(?:[ \t]|$)/;
const RULINGS = /^## (?:Chief|Console) Rulings(?:[ \t]|$)/; // old-term-ok
const ACTIONABLE = /^- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?(READY|BLOCKED|FINDING|MERGED)(?:[^A-Za-z0-9_][\s\S]*)?$/;

function scopeLines(path) {
  if (!statSync(path).isFile()) {
    throw Object.assign(new Error(`not a regular file: ${path}`), { code: 'ENOTREG' });
  }
  const out = [];
  let scope = false;
  let seen = false;
  let fence = '';
  for (const raw of readFileSync(path, 'latin1').split('\n')) {
    const f = FENCE.exec(raw);
    if (f) {
      if (!fence) fence = f[1];
      else if (f[1][0] === fence[0] && f[1].length >= fence.length && /^[ \t\r]*$/.test(f[2])) fence = '';
      continue;
    }
    if (fence) continue;
    const head = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (head.startsWith('## ')) {
      const isResults = RESULTS.test(head);
      scope = isResults || (seen && RULINGS.test(head));
      seen = seen || isResults;
      continue;
    }
    if (scope) out.push(raw);
  }
  return out;
}

export function statusMarkerNewest(path) {
  let last = null;
  for (const line of scopeLines(path)) {
    if (!line.startsWith('- ')) continue;
    const marker = statusMarkerParse(line);
    if (marker !== null) last = marker;
  }
  return last;
}

export function statusMarkerActionable(path) {
  let word = null;
  let count = 0;
  for (const line of scopeLines(path)) {
    const m = ACTIONABLE.exec(line);
    if (m) {
      word = m[1];
      count += 1;
    }
  }
  return word === null ? null : `${word}#${count}`;
}

function main(argv) {
  const [cmd, arg] = argv;
  if (argv.length !== 2 || (cmd !== 'parse' && cmd !== 'is-parked')) {
    process.stderr.write('usage: status-marker.mjs parse LINE | is-parked WORD\n');
    return 2;
  }
  if (cmd === 'is-parked') return statusMarkerIsParked(arg) ? 0 : 1;
  const marker = statusMarkerParse(arg);
  if (marker === null) return 1;
  process.stdout.write(`${marker}\n`);
  return 0;
}

if (isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2));
