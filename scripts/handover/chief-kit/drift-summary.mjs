#!/usr/bin/env node
// scripts/handover/chief-kit/drift-summary.mjs - sorts the saved focus-drift.txt into real drift,
// known checker bug and transient, and reports whether the saved run is stale or unknown and which
// mode the tracker is in. Read only: it never runs the drift pass and writes nothing.
//
// Usage: drift-summary.mjs --json [--drift <focus-drift.txt>] [--known <tsv>] [--mirror-dir <dir>]
//                          [--now <epoch>] [--stale-after <seconds>]
//   --drift       default $HIMMEL_FOCUS_DRIFT; a missing file reports file.exists=false
//   --known       the known-checker-bugs TSV (env DRIFT_SUMMARY_KNOWN, else the one beside this script):
//                 checker<TAB>class<TAB>key<TAB>edited-at, `#` lines skipped; class may be `unset`
//   --mirror-dir  the Jira mirror holding <checker>.md (default $HOME/.himmel/state/jira-mirror/<project>)
//   --stale-after seconds a saved run stays fresh (default 10800)
//
// A row is one `CLASS KEY detail | writer=… | fix=…` line of status-drift.sh; the last line is
// `sdrift=<n>:<sig>` or `sdrift=unknown`. A row is KNOWN when the TSV pairs its key with its class
// (or with `unset`, a pair that came in from Jira) AND the checker ticket's mirror status is not Done
// (E23). It is TRANSIENT when it is an unpaired WORKER-COMMENT row (the comment lags a marker and
// the next sweep heals it). Every other row is REAL and counts at once (K2): nothing waits for a
// second run. A checker ticket whose status cannot be read keeps its rows REAL.
//
// ponytail: fresh for a fixed 3 h because focus refreshes are event driven, upgrade path = read the
// last refresh's own spacing from focus-state.
// Platform guard: Node only, no .ps1 twin by design (shell-only harness).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TEAM_KEY = 'HIMMEL_TRACKER_TEAM_MODE';
const TRANSIENT_CLASSES = new Set(['WORKER-COMMENT']);

function usage() {
  process.stderr.write('usage: drift-summary.mjs --json [--drift <file>] [--known <tsv>] [--mirror-dir <dir>] [--now <epoch>] [--stale-after <seconds>]\n');
  process.exit(2);
}

const opt = { json: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--json') { opt.json = true; continue; }
  if (!['--drift', '--known', '--mirror-dir', '--now', '--stale-after'].includes(a) || i + 1 >= argv.length) usage();
  opt[a.slice(2)] = argv[(i += 1)];
}
if (!opt.json) usage();

const project = process.env.JIRA_PROJECT_KEY || 'HIMMEL';
const driftFile = opt.drift || process.env.HIMMEL_FOCUS_DRIFT || '';
const knownFile = opt.known || process.env.DRIFT_SUMMARY_KNOWN || path.join(HERE, 'known-checker-bugs.tsv');
const mirrorDir = opt['mirror-dir'] || path.join(os.homedir(), '.himmel', 'state', 'jira-mirror', project);
const now = /^\d+$/.test(opt.now || '') ? Number(opt.now) : Math.floor(Date.now() / 1000);
const staleAfter = /^\d+$/.test(opt['stale-after'] || '') ? Number(opt['stale-after']) : 10800;

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
}

// himmel.conf.local, then himmel.conf: the first layer that sets the key non-empty wins
function readMode() {
  const dir = process.env.HIMMEL_CONFIG_DIR || path.join(os.homedir(), '.himmel');
  for (const file of [path.join(dir, 'himmel.conf.local'), path.join(dir, 'himmel.conf')]) {
    const raw = readText(file);
    if (raw === null) continue;
    for (const line of raw.split('\n')) {
      const m = line.trim().match(new RegExp(`^${TEAM_KEY}\\s*=\\s*(.*)$`));
      const v = m ? m[1].replace(/\s+#.*$/, '').replace(/^["']|["']$/g, '').trim().toLowerCase() : '';
      if (v) return { mode: ['on', '1', 'true'].includes(v) ? 'team' : 'single-user', modeSource: file };
    }
  }
  return { mode: 'single-user', modeSource: 'default' };
}

function readKnown() {
  const raw = readText(knownFile) || '';
  const rows = [];
  for (const line of raw.split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    const [checker, cls, key, editedAt] = line.split('\t');
    if (checker && cls && key) rows.push({ checker, class: cls, key, editedAt: editedAt || '' });
  }
  return rows;
}

// the checker ticket's status category from the mirror; 'unknown' when it cannot be read
const statusCache = new Map();
function checkerStatus(key) {
  if (!statusCache.has(key)) {
    const raw = readText(path.join(mirrorDir, `${key}.md`));
    const m = raw && raw.match(/^statusCategory:\s*"?([^"\n]*?)"?\s*$/m);
    statusCache.set(key, m ? m[1] : 'unknown');
  }
  return statusCache.get(key);
}

const out = {
  file: { path: driftFile, exists: false, writtenAt: null, writtenHm: null },
  sdrift: null, unknown: false, stale: false,
  ...readMode(),
  real: [], known: [], transient: [],
  checkers: [],
};

const raw = driftFile ? readText(driftFile) : null;
if (raw !== null) {
  const st = fs.statSync(driftFile);
  const written = Math.floor(st.mtimeMs / 1000);
  const d = new Date(written * 1000);
  const p2 = (n) => String(n).padStart(2, '0');
  out.file = { path: driftFile, exists: true, writtenAt: written, writtenHm: `${p2(d.getHours())}:${p2(d.getMinutes())}` };
  out.stale = now - written > staleAfter;

  const lines = raw.split('\n').filter((l) => l.trim());
  const last = lines.length ? lines[lines.length - 1] : '';
  const m = last.match(/^sdrift=(.+)$/);
  out.sdrift = m ? m[1] : null;
  out.unknown = !m || m[1] === 'unknown';

  const known = readKnown();
  for (const line of m ? lines.slice(0, -1) : lines) {
    const r = line.match(/^([A-Z][A-Z-]*) (\S+)(?: |$)/);
    if (!r) continue;
    const row = { class: r[1], key: r[2], line };
    const pair = known.find((k) => k.key === row.key && (k.class === row.class || k.class === 'unset'));
    if (pair && checkerStatus(pair.checker) !== 'Done' && checkerStatus(pair.checker) !== 'unknown') {
      out.known.push({ ...row, checker: pair.checker, checkerStatus: checkerStatus(pair.checker) });
    } else if (!pair && TRANSIENT_CLASSES.has(row.class)) {
      out.transient.push(row);
    } else {
      out.real.push(row);
    }
  }
  out.checkers = [...new Set(out.known.map((k) => k.checker))];
}
out.counts = { real: out.real.length, known: out.known.length, transient: out.transient.length };

process.stdout.write(`${JSON.stringify(out)}\n`);
