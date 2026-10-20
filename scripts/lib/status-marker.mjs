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

const MARKER = /^- (?:[0-9]{1,2}:[0-9]{2}[ \t\n\v\f\r]+)?(?:\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)(?:[^A-Za-z0-9_][\s\S]*)?$/;

export function statusMarkerParse(line) {
  const m = MARKER.exec(line);
  if (!m) return null;
  return m[1] === 'PARKED-BANK' ? 'PARKED-USAGE' : m[1];
}

export function statusMarkerIsParked(word) {
  return word === 'PARKED-BANK' || word === 'PARKED-USAGE';
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
