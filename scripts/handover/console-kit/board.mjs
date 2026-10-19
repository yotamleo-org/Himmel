#!/usr/bin/env node
// board.mjs — Render the console's progress board: a self-contained
// HTML page (console-board.html, next to the console doc) that shows the fleet,
// every leg's phase, what needs the console, epic progress and the operator's
// open decisions. The console republishes it as an artifact (that call is the
// console's own; this script never publishes).
//
//   node board.mjs --doc <console doc> [--legs "<leg doc> ..."] [--out <file>] [--repo <dir>] [--changed]
//
// --changed (Ask 1): still renders and writes the file, but prints
// one line -- `CHANGED <path>` or `UNCHANGED <path>` -- instead of the bare
// path, so a console can call this after every Live-state mutation (dispatch,
// verdict, GO, MERGED, WRAPPED) and grep the answer instead of diffing the
// file itself. "Changed" compares the embedded fingerprint (below) against
// what the file on disk carried before this render; the Artifact publish
// itself stays a model step, never done here.
//
// Leg set: --legs wins; else the console's fleet manifest
// (<console doc stem>.fleet.json, via fleet-manifest.sh list); else the Live-state scan.
//
// State comes from tick.sh (leg locks, tails, fleet, open PRs, and the board
// fingerprint via --emit-fp), the console doc's `## Live state` block, the leg
// docs' Results bullets, `gh` (open + merged PRs), and -- for a WRAPPED leg
// only -- the SAME process census tick.sh's procs= builds from
// (claude-sessions.sh), read independently because tick.sh's own procs= counts
// only HELD legs. tick.sh's `board=` field compares the fingerprint embedded
// here with a freshly recomputed one, so a stale board is structurally
// visible. The published page is public-ish: nonces, lock tokens and token
// spans are redacted from everything before it is escaped.
//
// Optional Live-state lines the console may keep (console-template.md):
//   epics: HIMMEL-3332=4, HIMMEL-3340=2     declared totals; merged is counted from gh
//   decisions: first?; second?              open operator decisions, ';'-separated
//   versions: v1.0.0, v1.0.1                one `Release <v>` panel per Jira fixVersion
//
// The published page shows live work only. WRAPPED and MERGED legs and the merged PRs
// go to <out>-archive.html beside it (console-board-archive.html by default): local,
// never published, one item per line so a grep finds a ticket key, a PR or a last bullet.
//
// ponytail: the archive is rebuilt from the fleet manifest and the 24 h merged-PR list each
// render, so a merged PR older than 24 h survives there only as its leg's line; upgrade
// path: merge the previous archive's PR lines into the new one.
//
// PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (tick.sh
// reads pgrep, atq and the konsole launch logs). Node ESM, no dependencies.
//
// ponytail: the epic "merged" count is PRs whose title cites [KEY], from one
// `gh pr list --search "KEY in:title"` (200 max); an epic whose PRs cite it only
// in the branch name, or with more than 200 merged PRs, undercounts. The declared
// total in `epics:` is the console's own number -- nothing derives it from Jira.
//
// ponytail: a Release panel is one Jira `list` per version (limit 1000; a version
// with more tickets undercounts), a ticket is done when its status reads Done /
// Closed / Resolved, and tick.sh never sees these counts, so tick's board= cannot go
// STALE on one -- only --changed (the versions fingerprint meta) reports it. Upgrade
// path: have tick.sh fold the counts into board-fp once #1421 lands.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, existsSync, openSync, readFileSync, readSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gitClean } from '../../lanes/git-clean.mjs';
import { readToolHealth } from '../../eval/leg-digest/tool-health.mjs';
import { redact } from './redact.mjs';
import { collect as collectCloud } from './cloud-liveness.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

const USAGE = 'usage: board.mjs --doc <console doc> [--legs "<leg doc> ..."] [--out <file>] [--repo <dir>] [--json <file>] [--changed]';
const rawArgs = process.argv.slice(2);
// --changed (Ask 1) is the one console step that both re-renders
// and says whether the render moved: a boolean flag, pulled out before the
// --opt pairs below so it never consumes the next pair's value.
const changedFlag = rawArgs.includes('--changed');
const args = rawArgs.filter((a) => a !== '--changed');
const opt = {};
for (let i = 0; i < args.length; i += 2) {
    if (!['--doc', '--legs', '--out', '--repo', '--json'].includes(args[i]) || args[i + 1] === undefined) {
        console.error(USAGE);
        process.exit(2);
    }
    opt[args[i].slice(2)] = args[i + 1];
}
if (!opt.doc) {
    console.error(USAGE);
    process.exit(2);
}
const docPath = resolve(opt.doc);
if (!existsSync(docPath)) {
    console.error(`board: no such console doc: ${docPath}`);
    process.exit(1);
}
const bucket = dirname(docPath);
const repo = resolve(opt.repo || join(HERE, '..', '..', '..'));
const outPath = resolve(opt.out || join(bucket, 'console-board.html'));

// ---------------------------------------------------------------- redaction
// Nonces, lock tokens and `token \`...\`` spans never reach a published page;
// the patterns live in redact.mjs (shared with himmel-bus lib/agui.mjs). Runs BEFORE escaping.
const esc = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
// Redact BEFORE clipping: a clip that cuts a lock token in half would leave a
// fragment the patterns no longer match.
const safe = (s, n = Infinity) => esc(clip(redact(String(s)), n));

// ---------------------------------------------------------------- console doc
const docText = readFileSync(docPath, 'utf8');
const docLines = docText.split('\n');
// A section runs from its heading to the next `## ` heading -- never past it. The
// tick reads `## Live state` by exact heading, so `exact` mirrors that.
const sectionOf = (lines, title, exact = false) => {
    const out = [];
    let on = false;
    for (const l of lines) {
        if (on && /^## /.test(l)) break;
        if (on) out.push(l);
        if (l === title || (!exact && l.startsWith(`${title} `))) on = true;
    }
    return out;
};
const section = (title, exact) => sectionOf(docLines, title, exact);
const live = section('## Live state', true);
const liveField = (key) => {
    const l = live.find((x) => x.startsWith(`${key}:`));
    return l ? l.slice(key.length + 1).trim() : '';
};
// The legs: BLOCK, read by tick.sh's own grammar: every `legs:` line
// plus the lines wrapped under it, up to the first blank line, the next `word:`
// field, or a list-marker / `>` / `#` line (a detail bullet may quote a span
// freely). An entry is a backtick span of exactly four non-empty colon fields
// `<label>:<nonce>:<lock-token>:<pid>`, no whitespace, the label all
// LEG_LABEL_CLASS (scripts/lib/leg-identity.sh: letters, digits, `_`, `.`, `-`),
// so a leg doc stem parses too. Only the label and the nonce are kept: the nonce
// picks the leg's doc among docs sharing a label, and is never rendered.
// ponytail: a malformed span (tick reports it MALFORMED by label) is not an entry
// here, so a leg named only by one is missing from the board's Live-state set.
const LEG_LABEL_CLASS = /^[A-Za-z0-9_.-]+$/;
const liveEntries = [];
{
    let inBlock = false;
    for (const l of live) {
        if (/^legs:/.test(l)) inBlock = true;
        else if (inBlock && (/^\s*$/.test(l) || /^[A-Za-z][A-Za-z ]*:/.test(l) || /^\s*([-*+]|\d+[.)])\s/.test(l) || /^\s*[>#]/.test(l))) inBlock = false;
        if (!inBlock) continue;
        for (const m of l.matchAll(/`([^`]*)`/g)) {
            const f = m[1].split(':');
            if (/\s/.test(m[1]) || f.length !== 4 || f.some((x) => !x) || !LEG_LABEL_CLASS.test(f[0])) continue;
            liveEntries.push({ stem: f[0], nonce: f[1] });
        }
    }
}
const epicsDeclared = liveField('epics').split(/[,\s]+/).filter(Boolean).map((e) => {
    const m = /^([A-Z][A-Z0-9]*-\d+)=(\d+)$/.exec(e);
    return m ? { key: m[1], total: Number(m[2]) } : null;
}).filter(Boolean);
// A version name lands inside a JQL string: only a plain release token is accepted.
const versionsDeclared = liveField('versions').split(/[,\s]+/).filter((v) => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(v));
// Split on ';' only at parenthesis depth 0, so "A (x; y); B?" -> ["A (x; y)", "B?"].
const splitTopLevel = (s) => {
    const out = [];
    let depth = 0;
    let cur = '';
    for (const ch of s) {
        if (ch === '(') depth += 1;
        else if (ch === ')') depth = Math.max(0, depth - 1);
        if (ch === ';' && depth === 0) { out.push(cur); cur = ''; } else cur += ch;
    }
    out.push(cur);
    return out;
};
const decisions = splitTopLevel(liveField('decisions')).map((d) => d.trim()).filter((d) => d && d !== 'none');
const queueLine = liveField('queue');
const lastGo = liveField('last GO').replace(/`/g, '');
const consoleResults = section('## Results').filter((l) => l.startsWith('- ')).slice(-8);

// ---------------------------------------------------------------- leg docs
// A leg's label comes from leg-identity.sh, the ONE derivation the tick uses for
// leg docs and its own legs= (a local regex here is how the two drift). One bash
// call labels every name.
// A lookup that fails, or labels fewer names than it was given, is not an empty
// fleet: it is reported on stderr and the board renders "leg labels unavailable".
const LEGID = process.env.BOARD_LEGID || join(HERE, '..', '..', 'lib', 'leg-identity.sh');
const legLabel = new Map();
let labelFailure = '';
const primeLabels = (names) => {
    const todo = [...new Set(names)].filter((n) => !legLabel.has(n));
    if (!todo.length) return;
    let out = '';
    try {
        out = execFileSync('bash', ['-c', 'source "$1" || exit 1; shift; for s in "$@"; do leg_label "$s"; printf "\\n"; done', 'bash', LEGID, ...todo],
            { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
    } catch (e) { labelFailure ||= `the lookup failed (${e.status !== null && e.status !== undefined ? `rc=${e.status}` : e.code || e.signal || 'no exit status'})`; }
    const lines = out.split('\n');
    todo.forEach((n, i) => legLabel.set(n, lines[i] || ''));
    const got = todo.filter((n, i) => lines[i]).length;
    if (!labelFailure && got < todo.length) labelFailure = `the lookup returned ${got} of ${todo.length} labels`;
};
const labelOf = (name) => legLabel.get(name) || '';
const ticketOf = (file) => (/^([A-Z][A-Z0-9]*-\d+)/.exec(basename(file)) || [])[1] || '';
const newer = (a, b) => (statSync(a).mtimeMs >= statSync(b).mtimeMs ? a : b);
// with no --legs, the console's fleet manifest (<console doc stem>.fleet.json,
// the file tick.sh --legs-from reads) IS the leg set. It is read through
// fleet-manifest.sh list -- the one validation -- never a second parser here. No manifest
// keeps the Live-state scan below; one that fails validation is reported and falls back.
const manifestPath = join(bucket, `${basename(docPath).replace(/\.md$/, '')}.fleet.json`);
let manifestDocs = null;
if (opt.legs === undefined && existsSync(manifestPath)) {
    try {
        manifestDocs = execFileSync('bash', [join(HERE, 'fleet-manifest.sh'), 'list', manifestPath],
            { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] }).split('\n').filter(Boolean);
    } catch { console.error(`board: warning: fleet manifest unreadable (${manifestPath}); falling back to the Live-state leg scan`); }
}
// --changed folds this in: the tick fingerprint only moves with a lock or tail, so a leg
// added to the manifest before it holds a lock would otherwise read UNCHANGED.
// A digest, not the paths: a fleet of 40 docs would put kilobytes of file names on the page.
const manifestSig = manifestDocs ? createHash('sha256').update(manifestDocs.join(',')).digest('hex').slice(0, 16) : '';
let legFiles;
if (opt.legs !== undefined || manifestDocs) {
    legFiles = (opt.legs !== undefined ? opt.legs.split(/[\s,]+/).filter(Boolean) : manifestDocs).map((f) => resolve(f));
    primeLabels([...liveEntries.map((e) => e.stem), ...legFiles.map((f) => basename(f))]);
} else {
    const docs = readdirSync(bucket).filter((f) => f.endsWith('-RESUME.md'));
    primeLabels([...liveEntries.map((e) => e.stem), ...docs]);
    // One doc per Live-state entry, from the leg's identity: the doc its stem names,
    // else -- among docs sharing the label -- the one holding the entry's nonce,
    // else the newest by mtime (a label alone cannot tell two consoles' N1 apart).
    const byLabel = new Map();
    for (const e of liveEntries) {
        const label = labelOf(e.stem);
        if (!label || byLabel.has(label)) continue;
        const exact = docs.find((f) => f === `${e.stem}.md` || f === `${e.stem}-RESUME.md`);
        const cands = docs.filter((f) => labelOf(f) === label).map((f) => join(bucket, f));
        // The nonce must stand alone as a token: a longer token that merely starts with it is another leg's.
        const tokenRe = new RegExp(`(?<![A-Za-z0-9_.-])${e.nonce.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![A-Za-z0-9_.-])`);
        const holders = cands.filter((f) => tokenRe.test(readFileSync(f, 'utf8')));
        const pool = holders.length ? holders : cands;
        const doc = exact ? join(bucket, exact) : (pool.length ? pool.reduce(newer) : null);
        if (doc) byLabel.set(label, doc);
    }
    legFiles = [...byLabel.values()];
}
if (labelFailure) console.error(`board: warning: leg labels unavailable — ${labelFailure}; the board renders the unavailable state, not an empty fleet`);
const liveLabels = [...new Set(liveEntries.map((e) => labelOf(e.stem)).filter(Boolean))];
const legInfo = new Map();
const markerOf = (b) => (/^- (?:\d{1,2}:\d{2}\s+)?([A-Z][A-Z-]*[A-Z])\b/.exec(b) || [])[1] || '';
for (const f of legFiles) {
    const label = labelOf(basename(f));
    if (!label || !existsSync(f)) continue;
    const bullets = sectionOf(readFileSync(f, 'utf8').split('\n'), '## Results').filter((l) => l.startsWith('- '));
    let pr = null;
    // A leg's PR comes only from the canonical grammar, anchored at the bullet's own
    // marker: `LIVE — PR <n> open`, `READY <pr> <head>`, `MERGED #<n>`. A FINDING or
    // prose that merely cites a PR (`#1039`, `PR 1039 merged`, a /pull/ URL) owns none.
    // ponytail: a leg that opened a PR without ever writing one of these bullets has no
    // PR here; the board does not join open PRs on headRefName to recover it.
    for (const b of bullets) {
        const m = /^- (?:\d{1,2}:\d{2}\s+)?(?:LIVE\s*[-–—:]?\s*PR\s*#?(\d{2,})\s+open\b|READY\s+#?(\d{2,})\s+[0-9a-f]{7,}|MERGED\s+#(\d{2,})\b)/.exec(b);
        if (m) pr = Number(m[1] || m[2] || m[3]);
    }
    const last = bullets.length ? bullets[bullets.length - 1] : '';
    legInfo.set(label, { file: f, ticket: ticketOf(f), last: last.slice(2), marker: markerOf(last), bullets, pr });
}

// ---------------------------------------------------------------- tick
const tickBin = process.env.BOARD_TICK || join(HERE, 'tick.sh');
const tickArgs = ['--doc', docPath, '--repo', repo, '--emit-fp'];
if (opt.legs !== undefined) tickArgs.push('--legs', opt.legs);
else if (legFiles.length) tickArgs.push('--legs', legFiles.join(' '));
// tick's own DOC/TOKEN/LEGS env must not leak in: a board render sends no
// heartbeat (no token) and reads exactly the arm passed above.
const tickEnv = { ...process.env };
for (const k of ['DOC', 'TOKEN', 'LEGS']) delete tickEnv[k];
let tickLine = '';
let fp = '';
try {
    const cmd = tickBin.endsWith('.sh') ? ['bash', [tickBin, ...tickArgs]] : [tickBin, tickArgs];
    const out = execFileSync(cmd[0], cmd[1], { encoding: 'utf8', env: tickEnv, timeout: 90000, stdio: ['ignore', 'pipe', 'ignore'] });
    for (const l of out.split('\n')) {
        if (l.startsWith('TICK ') && !tickLine) tickLine = l;
        const m = /^board-fp=([0-9a-f]{16})$/.exec(l);
        if (m) fp = m[1];
    }
} catch { /* degraded: the board still renders, marked tick-unavailable, with no fingerprint */ }
if (!tickLine) fp = '';
const field = {};
for (const m of tickLine.matchAll(/(?:^|\s)([a-z]+)=(\S*)/g)) field[m[1]] = m[2];
const pairs = (v) => new Map((v || '').split(',').map((p) => p.split(':')).filter((p) => /^N\d+[a-z]*$/.test(p[0] || '')).map((p) => [p[0], p.slice(1).join(':')]));
const locks = pairs(field.legs);
const tails = pairs(field.tails);
const [fleetLive, fleetCap] = (field.fleet || '').split('/').map(Number);
const fleetOk = Number.isFinite(fleetLive) && Number.isFinite(fleetCap) && fleetCap > 0;
const idle = fleetOk ? Math.max(0, fleetCap - fleetLive) : 0;

// ---------------------------------------------------------------- gh
// A console always runs in himmel; the checkout it is FOR is recorded on the
// doc's project line (console.sh writes it, `none — ...` for himmel itself).
// Its PRs are the ones the board shows, so gh asks that checkout. A recorded
// path that is gone reads `gh unavailable`, never himmel's PRs. tick.sh reads
// the same line for prs=, so the board fingerprint stays in step.
const projectLine = /The project this console is FOR is \*\*`([^`]*)`\*\*/.exec(docText);
const prRepo = projectLine && projectLine[1].startsWith('/') ? projectLine[1] : repo;
const ghJson = (ghArgs) => {
    try {
        return JSON.parse(execFileSync('gh', ghArgs, { cwd: prRepo, encoding: 'utf8', timeout: 45000, stdio: ['ignore', 'pipe', 'ignore'] }));
    } catch { return null; }
};
const gh = (ghArgs) => {
    const v = ghJson(ghArgs);
    return Array.isArray(v) ? v : null;
};
const openPrs = gh(['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,headRefName,isDraft,statusCheckRollup']);
const since = new Date(Date.now() - 86400e3).toISOString().slice(0, 19) + 'Z';
const mergedPrs = gh(['pr', 'list', '--state', 'merged', '--limit', '60', '--search', `merged:>=${since}`, '--json', 'number,title,mergedAt,headRefName']);
const epics = epicsDeclared.map((e) => {
    const found = gh(['pr', 'list', '--state', 'merged', '--limit', '200', '--search', `${e.key} in:title`, '--json', 'number,title']);
    const merged = found ? new Set(found.filter((p) => String(p.title).includes(`[${e.key}]`)).map((p) => p.number)).size : '?';
    return { ...e, merged };
});

// ---------------------------------------------------------------- releases
// One Jira CLI `list` per declared version, by the PRIMARY checkout's absolute path
// (a worktree has no dist/). BOARD_JIRA overrides it (test seam, mirrors BOARD_TICK).
// Any failure -- missing CLI, non-zero exit, timeout, unparseable output -- is that
// version's `unavailable`; the render never fails on it.
const primaryRoot = () => {
    try {
        const common = gitClean(['-C', HERE, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
            { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        if (common) return dirname(common);
    } catch { /* fall through to the tree this script sits in */ }
    return resolve(HERE, '..', '..', '..');
};
const JIRA_CLI = process.env.BOARD_JIRA || (versionsDeclared.length ? join(primaryRoot(), 'scripts', 'jira', 'dist', 'index.js') : '');
// the legs' Jira ladder, in the order a Release panel shows it.
const LEG_STATUSES = ['To Do', 'In Progress', 'In Review', 'IN CI', 'Done'];
const DONE_STATUS = /^(done|resolved)$/i;
// Closed and won't do are out of every count, as the tracker has it.
const OUT_STATUS = /^(closed|wont do|won't do|wont fix|won't fix)$/i;
const releaseOf = (version) => {
    const a = ['list', '--jql', `project = HIMMEL AND fixVersion = "${version}"`, '--labels', '--limit', '1000'];
    let out;
    try {
        out = execFileSync(...(JIRA_CLI.endsWith('.js') ? ['node', [JIRA_CLI, ...a]] : [JIRA_CLI, a]),
            { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
    } catch { return { version, unavailable: true }; }
    // `list --labels` rows: key, type, status, title, labels (tab-separated).
    // The CLI prints only ticket rows, so any other non-blank line means a garbled answer.
    const lines = out.split('\n').filter((l) => l.trim()).map((l) => l.split('\t'));
    const rows = lines.filter((f) => f.length >= 5 && /^[A-Z][A-Z0-9]*-\d+$/.test(f[0]))
        .map((f) => ({ key: f[0], status: f[2].trim(), title: f[3], labels: (f[4] || '').split(',').map((x) => x.trim()) }));
    if (rows.length !== lines.length) return { version, unavailable: true };
    const counted = rows.filter((r) => !OUT_STATUS.test(r.status));
    const open = counted.filter((r) => !DONE_STATUS.test(r.status));
    const byStatus = Object.fromEntries(LEG_STATUSES.map((st) => [st, rows.filter((r) => r.status === st).length]));
    return { version, done: counted.length - open.length, total: counted.length, byStatus, blockers: open.filter((r) => r.labels.includes('v1-blocker')) };
};
const releases = versionsDeclared.map(releaseOf);
// A separate fingerprint (as the census one is): tick.sh never sees these counts.
const releaseSig = releases.map((r) => (r.unavailable ? `${r.version}=unavailable`
    : `${r.version}=${r.done}/${r.total}:${LEG_STATUSES.map((st) => r.byStatus[st]).join('/')}:${r.blockers.map((b) => `${b.key}@${b.status}@${redact(b.title)}`).join('+')}`)).join(',');
const ciOf = (pr) => {
    const rollup = (pr && pr.statusCheckRollup) || [];
    // No checks reported yet is not a green build: it reads pending.
    if (!rollup.length) return 'pending';
    // A rollup mixes CheckRuns (status + conclusion) and StatusContexts (state only).
    const verdict = (c) => c.conclusion || c.state || '';
    if (rollup.some((c) => ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE'].includes(verdict(c)))) return 'failing';
    if (rollup.some((c) => (c.status ? c.status !== 'COMPLETED' : false) || ['', 'PENDING', 'EXPECTED'].includes(verdict(c)))) return 'pending';
    return 'green';
};
const openByNum = new Map((openPrs || []).map((p) => [p.number, p]));
// Merge state is asked of each PR a leg names (`gh pr view`), not read off the
// 24 h merged panel: a leg whose PR merged yesterday must still read MERGED.
// ponytail: a PR gh cannot answer for (gh down, not a PR of this repo) reads not
// merged, so its leg falls back to LIVE / READY.
const mergedNums = new Set((mergedPrs || []).map((p) => p.number));
for (const n of new Set([...legInfo.values()].map((i) => i.pr).filter(Boolean))) {
    if (openByNum.has(n) || mergedNums.has(n)) continue;
    const v = ghJson(['pr', 'view', String(n), '--json', 'state']);
    if (v && v.state === 'MERGED') mergedNums.add(n);
}

// ---------------------------------------------------------------- phases
const LADDER = ['LIVE', 'PARKED-BANK', 'READY-TO-OPEN', 'PR open', 'READY', 'BLOCKED','MERGED', 'WRAPPED', 'WRAPPED, window still open'];
const labels = [...new Set([...liveLabels, ...locks.keys(), ...tails.keys(), ...legInfo.keys()])]
    .sort((a, b) => parseInt(a.slice(1), 10) - parseInt(b.slice(1), 10) || a.localeCompare(b));
const legs = labels.map((label) => {
    const info = legInfo.get(label) || { ticket: '', last: '', pr: null };
    // tick marks a READY past the GO-hold `READY!stale`; the board's phase is READY either way.
    const tail = (tails.get(label) || '').replace(/!stale$/, '');
    const lock = locks.get(label) || '';
    // A judge's label is its doc stem, which tick's tails= never carries: with no tail,
    // the doc's own last marker says whether it finished (WRAPPED, or a judge's VERDICT).
    const docDone = !tails.has(label) && (info.marker === 'WRAPPED' || info.marker === 'VERDICT');
    let phase;
    if (tail === 'WRAPPED' || lock === 'WRAPPED' || docDone) phase = 'WRAPPED';
    else if (info.pr && mergedNums.has(info.pr)) phase = 'MERGED';
    else if (tail === 'BLOCKED' || tail === 'HALTED') phase = 'BLOCKED';
    else if (tail === 'PARKED-BANK') phase = 'PARKED-BANK';
    else if (tail === 'READY') phase = info.pr ? 'READY' : 'READY-TO-OPEN';
    else if (info.pr && openByNum.has(info.pr)) phase = 'PR open';
    else phase = 'LIVE';
    const pr = info.pr ? openByNum.get(info.pr) : null;
    const lostLock = ['STALE', 'FREE', 'MISSING', 'CORRUPT'].includes(lock) && phase !== 'WRAPPED' && phase !== 'MERGED';
    const needs = phase === 'READY' || phase === 'READY-TO-OPEN' || phase === 'BLOCKED' || tail === 'FINDING' || lostLock;
    return { label, ticket: info.ticket, phase, tail, lock, prNum: info.pr, ci: pr ? ciOf(pr) : '', last: info.last, needs, lostLock };
});

// ------------------------------------------------- WRAPPED window still open
// Ask 3: tick.sh's procs= counts only HELD (FRESH/STALE) legs,
// so a leg whose lock/tail already reads WRAPPED (the normal end of a leg) can
// still own a live claude window nobody is watching -- invisible to tick.sh.
// This reads the SAME process census tick.sh's procs= builds from
// (claude-sessions.sh's claude_sessions()) and the SAME candidate-name
// derivation (leg-identity.sh's leg_identity(), not leg_label() -- a label
// alone cannot be matched against a census row), independently of tick.sh, so
// tick.sh itself is never touched. BOARD_SESSIONS overrides the sourced file
// (test seam, mirrors BOARD_TICK/BOARD_LEGID); its absence from the census (or
// the census itself being unavailable) is never treated as "still open".
const SESSIONS_BIN = process.env.BOARD_SESSIONS || join(HERE, '..', '..', 'lanes', 'lib', 'claude-sessions.sh');
let censusNames = null; // null = census unavailable -- never read as "nothing is running"
try {
    const out = execFileSync('bash', ['-c', 'source "$1" || exit 1; claude_sessions', 'bash', SESSIONS_BIN],
        { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
    censusNames = new Set(out.split('\n').filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t')[1]).filter(Boolean));
} catch { censusNames = null; }
// The pre-close checks a hand-close needs: close-wrapped-leg.sh --check signals nothing,
// exits 0 when safe, and otherwise names what is still running. A check that cannot run
// reads as unknown, never as safe.
const CLOSE_CHECK = process.env.BOARD_CLOSE_CHECK || join(HERE, 'close-wrapped-leg.sh');
// One board render waits at most CLOSE_BUDGET_MS in all, so several slow checks cannot stall it.
const CLOSE_BUDGET_MS = 60000;
let closeBudgetLeft = CLOSE_BUDGET_MS;
const closeNote = (doc) => {
    if (closeBudgetLeft <= 0) return 'close check skipped (time budget spent)';
    const t0 = Date.now();
    const r = spawnSync('bash', [CLOSE_CHECK, '--check', doc], { encoding: 'utf8', timeout: closeBudgetLeft, killSignal: 'SIGKILL' });
    closeBudgetLeft -= Date.now() - t0;
    if (r.error || r.status === null) return 'close check did not run';
    if (r.status === 0) return 'safe to close';
    if (r.status < 3 || r.status > 7) return 'close check failed (rc ' + r.status + ')';
    const lines = (r.stdout + '\n' + r.stderr).split('\n').map((x) => x.trim()).filter(Boolean);
    const what = lines.find((x) => x.startsWith('WITHHELD')) || lines[lines.length - 1] || 'close check refused (rc ' + r.status + ')';
    return 'still running: ' + what.replace(/^close-wrapped-leg: /, '');
};
const wrappedLegs = legs.filter((l) => l.phase === 'WRAPPED' && legInfo.get(l.label)?.file);
if (censusNames && wrappedLegs.length) {
    let out = '';
    try {
        out = execFileSync('bash', ['-c', 'source "$1" || exit 1; shift; for s in "$@"; do leg_identity "$s"; done', 'bash', LEGID,
            ...wrappedLegs.map((l) => basename(legInfo.get(l.label).file))],
            { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
    } catch { out = ''; }
    const lines = out.split('\n').filter(Boolean);
    wrappedLegs.forEach((l, i) => {
        const names = (lines[i] || '').split('\t')[1] || '';
        const stillOpen = names.split(',').filter(Boolean).some((n) => censusNames.has(n));
        if (stillOpen) {
            l.phase = 'WRAPPED, window still open';
            l.needs = true;
            l.closeNote = closeNote(legInfo.get(l.label).file);
        }
    });
}
// This census runs after tick's --emit-fp is already captured, so a window
// closing/reopening on an otherwise-unchanged tick fingerprint is invisible to
// board-fp; --changed folds this signature in separately (below) rather than
// asking tick.sh to account for a read it never performs.
const censusSig = legs.filter((l) => l.phase === 'WRAPPED, window still open').map((l) => l.label).sort().join(',');
// tick keeps CI colour and fleet capacity out of board-fp on purpose (they
// move without a console act), but the page shows them, so --changed must see them too.
// board.mjs is the only reader that knows what it rendered; tick.sh stays untouched.
const ciFleetSig = [fleetOk ? `${fleetLive}/${fleetCap}` : '', ...(openPrs || []).map((p) => `#${p.number}=${ciOf(p)}`), ...legs.filter((l) => l.ci).map((l) => `${l.label}=${l.ci}`)].join(',');

// ---------------------------------------------------------------- render
const now = new Date();
const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
const consoleName = basename(docPath, '.md');

// One compact card per live leg: a 25-leg fleet must fit the 15 KB page.
const legCard = (l) => `<li data-label="${esc(l.label)}" data-phase="${esc(l.phase)}"${l.ci ? ` data-ci="${l.ci}"` : ''}><b>${esc(l.label)}</b> <span class="tk">${esc(l.ticket)}</span> <span class="ph">${esc(l.phase)}</span>${l.prNum ? ` <span class="pr">PR #${l.prNum}${l.ci ? ` · ${l.ci}` : ''}</span>` : ''}<p>${l.last ? safe(l.last, 130) : '<i>no handover bullet yet</i>'}</p></li>`;
const ladder = LADDER.map((p) => `<li data-ladder="${esc(p)}" data-count="${legs.filter((l) => l.phase === p).length}"><span>${esc(p)}</span><b>${legs.filter((l) => l.phase === p).length}</b></li>`).join('\n');
const needRows = legs.filter((l) => l.needs).map((l) => {
    const tailWhy = l.phase === 'READY' ? `READY${l.prNum ? ` · PR #${l.prNum}` : ''} — awaiting GO`
        : l.phase === 'READY-TO-OPEN' ? 'READY-TO-OPEN — awaiting PR open'
            : l.phase === 'BLOCKED' ? 'BLOCKED — needs a ruling'
                : l.phase === 'WRAPPED, window still open' ? 'WRAPPED, window still open — ' + (l.closeNote || 'close the leg window')
                    : l.tail === 'FINDING' ? 'FINDING — needs a ruling'
                        : '';
    // A lost/stale lock is its own rendered signal, never displaced by the tail/phase
    // why-text above (or hidden behind its truncation): a leg can be FINDING, BLOCKED,
    // etc. AND lock-lost at once, and the lock is the one thing the console must never miss.
    const lockWhy = l.lostLock ? `lock ${l.lock} — lost or stale` : '';
    const why = [tailWhy, lockWhy].filter(Boolean).join(' · ');
    // The bullet itself is on the leg's own card below; repeating it here doubled the page.
    return `<li data-need="${esc(l.label)}"><b>${esc(l.label)}</b> ${esc(why)}</li>`;
}).join('\n');
// orphans-wip=<n[:KEY,...]> from the tick: In Progress / In Review tickets with no leg and no
// open PR. Keys are named for n <= 5; above that only the count is known. 0, `?` and `skip` add no row.
const orphanField = /(?:^|\s)orphans-wip=(\S*)/.exec(tickLine);
const orphanMatch = orphanField && /^([1-9]\d*)(?::(\S+))?$/.exec(orphanField[1]);
const orphanRows = !orphanMatch ? ''
    : orphanMatch[2]
        ? orphanMatch[2].split(',').filter((k) => /^[A-Z][A-Z0-9]*-\d+$/.test(k)).map((k) => `<li data-orphan="${esc(k)}"><b>${esc(k)}</b> in work, no leg, no open PR — dispatch as RESUME</li>`).join('\n')
        : `<li data-orphans="${esc(orphanMatch[1])}"><b>${esc(orphanMatch[1])} tickets</b> in work, no leg, no open PR — run next-dispatchable.sh</li>`;
const epicRows = epics.map((e) => {
    const pct = e.merged === '?' ? 0 : Math.min(100, Math.round((e.merged / Math.max(1, e.total)) * 100));
    return `<li data-epic="${esc(e.key)}" data-merged="${e.merged}" data-total="${e.total}"><b>${esc(e.key)}</b> ${e.merged}/${e.total}<div class="bar"><i style="width:${pct}%"></i></div></li>`;
}).join('\n');
const releasePanel = (r) => {
    if (r.unavailable) return `<section data-release="${esc(r.version)}" data-unavailable="1"><h2>Release ${safe(r.version)}</h2><p class="none">unavailable</p></section>`;
    const pct = Math.round((r.done / Math.max(1, r.total)) * 100);
    const breakdown = LEG_STATUSES.map((st) => `<span data-status="${esc(st)}" data-count="${r.byStatus[st]}">${esc(st)} ${r.byStatus[st]}</span>`).join(' · ');
    const blockers = r.blockers.map((b) => `<li data-blocker="${esc(b.key)}"><b>${esc(b.key)}</b> ${safe(b.title, 90)} <span class="pr">${safe(b.status)}</span></li>`).join('\n');
    return `<section data-release="${esc(r.version)}" data-done="${r.done}" data-total="${r.total}"><h2>Release ${safe(r.version)}</h2><b>${r.done}/${r.total}</b><div class="bar"><i style="width:${pct}%"></i></div><p class="status">${breakdown}</p>${blockers ? `<ul>${blockers}</ul>` : '<p class="none">no open v1-blocker tickets</p>'}</section>`;
};
const prRows = (openPrs || []).map((p) => `<li data-ci="${ciOf(p)}"><b>#${p.number}</b> ${safe(p.title, 90)} <span class="pr">${ciOf(p)}${p.isDraft ? ' · draft' : ''}</span></li>`).join('\n');
// Done work never reaches the published page: a WRAPPED or MERGED leg and the merged PRs
// go to a local archive file beside it (written below), one self-contained line each.
const doneLegs = legs.filter((l) => l.phase === 'WRAPPED' || l.phase === 'MERGED');
const liveLegs = legs.filter((l) => l.phase !== 'WRAPPED' && l.phase !== 'MERGED');
const archivePath = `${outPath.replace(/\.html$/, '')}-archive.html`;
const logRows = consoleResults.map((l) => `<li>${safe(l.slice(2), 200)}</li>`).join('\n');
const panel = (title, body, empty) => `<section><h2>${title}</h2>${body ? `<ul>${body}</ul>` : `<p class="none">${empty}</p>`}</section>`;

// Cloud sessions: each session in the bucket's cloud-sessions.tsv with the
// state cloud-liveness.mjs derives -- the same derivation as tick.sh's cloud= field. No
// tsv, no panel. Display-only like the bank-lift line: not in the fingerprint, never fatal.
const cloudPanel = (() => {
    if (!existsSync(join(bucket, 'cloud-sessions.tsv'))) return '';
    let r = { skip: true };
    try { r = collectCloud({ bucket, repo: prRepo, ...(process.env.CLOUD_LIVENESS_NOW ? { now: Date.parse(process.env.CLOUD_LIVENESS_NOW) } : {}) }); } catch { /* unreadable: the panel says so */ }
    if (r.skip) return `<section data-cloud-panel="unavailable"><h2>Cloud sessions</h2><p class="none">unavailable — gh or the sessions file could not be read</p></section>`;
    const rows = r.states.map((s) => `<li data-cloud-ticket="${esc(s.ticket)}" data-state="${esc(s.state)}" data-stall="${s.stall ? 'yes' : 'no'}"><b>${esc(s.ticket)}</b> ${esc(s.state)}${s.pr ? ` · PR #${esc(s.pr)}` : ''}${s.detail ? ` — ${safe(s.detail, 140)}` : ''}</li>`).join('\n');
    return panel('Cloud sessions', rows, 'no cloud session launched in the last 48 hours');
})();

// Bank lift: one read-only line from the lift's `show` output -- the
// same reason source as the doctor's C34 row. BOARD_BANK_LIFT overrides the script
// (test seam, mirrors BOARD_LEGID/BOARD_SESSIONS). Never renders the account or any
// field but until/standing; not part of the fingerprint; never fatal.
const BANK_LIFT_BIN = process.env.BOARD_BANK_LIFT || join(HERE, '..', '..', 'lib', 'bank-lift.sh');
const bankLiftLine = (() => {
    const row = (kind, text) => `<p class="sub" data-bank-lift="${kind}">weekly budget override: ${text}</p>`;
    try {
        let out = '';
        try {
            out = execFileSync('bash', [BANK_LIFT_BIN, 'show'], { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] });
        } catch (e) {
            out = e && e.stdout ? String(e.stdout) : '';
        }
        const lines = out.split('\n').map((l) => l.replace(/\r$/, ''));
        let status = null;
        for (const l of lines) { const m = /^bank-lift: (VALID|INVALID: (.+))$/.exec(l); if (m) status = m; }
        if (!status) return row('?', 'unavailable');
        if (lines.includes('bank-lift: none') || status[2] === 'missing') return row('none', 'no lift set');
        if (status[1] !== 'VALID') return row('invalid', `lift set but INVALID: ${safe(status[2], 40)}`);
        let tail = '';
        try {
            const idx = lines.findIndex((l) => l.startsWith('bank-lift:'));
            const j = JSON.parse(lines.slice(0, idx).join('\n'));
            if (typeof j.until === 'number' && Number.isFinite(j.until)) {
                const u = new Date(j.until * 1000);
                const p2 = (n) => String(n).padStart(2, '0');
                tail = ` until ${u.getFullYear()}-${p2(u.getMonth() + 1)}-${p2(u.getDate())} ${p2(u.getHours())}:${p2(u.getMinutes())}`;
            }
            tail += j.standing === true ? ' · standing' : ' · window';
        } catch { tail = tail || ' · window'; }
        return row('valid', `VALID${tail}`);
    } catch { return row('?', 'unavailable'); }
})();

// The stats sections below also leave their numbers here for --json, and their full
// tables for the archive: the live page shows only the top rows.
const trend = { cost: null, exploration: null, failures: null };
const archiveTables = [];

// Cost today: one line from the leg cost ledger close-wrapped-leg.sh
// appends to (LEG_COST_LEDGER, else $HANDOVER_DIR/.ledger/leg-cost.jsonl). An absent
// or unreadable ledger, or no usable row dated today, renders nothing and never fails
// the render. Not part of the fingerprint: --changed does not move on a new ledger row.
const costSection = (() => {
    try {
        const ledger = process.env.LEG_COST_LEDGER
            || (process.env.HANDOVER_DIR ? join(process.env.HANDOVER_DIR, '.ledger', 'leg-cost.jsonl') : '');
        if (!ledger) return '';
        const d = new Date();
        const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
        const byClass = Object.create(null);
        let n = 0;
        let total = 0;
        for (const line of readFileSync(ledger, 'utf8').split('\n')) {
            let r;
            try { r = JSON.parse(line); } catch { continue; }
            if (!r || r.date !== today || typeof r.cost_eq !== 'number') continue;
            (byClass[r.class || 'unknown'] ||= []).push(r.cost_eq);
            n += 1;
            total += r.cost_eq;
        }
        if (!n) return '';
        const fmt = (v) => (v >= 1e6 ? `${(v / 1e6).toFixed(1)}M` : v >= 1e3 ? `${Math.round(v / 1e3)}k` : String(Math.round(v)));
        const median = (a) => { const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
        trend.cost = { unit: 'cost-eq', sessions: n, total, median_by_class: Object.fromEntries(Object.keys(byClass).sort().map((c) => [redact(c), median(byClass[c])])) };
        const per = Object.keys(byClass).sort().map((c) => `${safe(c, 20)} ${fmt(median(byClass[c]))}`).join(', ');
        return `<section data-cost-legs="${n}"><h2>Cost today</h2><p class="sub">${n} worker session${n === 1 ? '' : 's'} · ${fmt(total)} cost-eq · median ${per}</p></section>`;
    } catch { return ''; }
})();

// Exploration cost: the weighted tokens each session spent before its first
// edit or commit, read from the digest markers leg_ledger.py leaves in
// LEG_DIGEST_STATE_DIR (else ~/.himmel/state/leg-digest) -- the digest's own `exploration`
// field, not tick data. Sessions that started in the last BOARD_EXPLORATION_HOURS (24) and
// were cut by an edit or commit: fleet median, worst 5, and a FLAG on any session over
// LEG_EXPLORATION_FLAG_TOKENS (100000). No such session, or an unreadable dir, renders
// nothing and never fails the render; not part of the fingerprint.
const explorationSection = (() => {
    try {
        const dir = process.env.LEG_DIGEST_STATE_DIR || join(process.env.HOME || '', '.himmel', 'state', 'leg-digest');
        const hours = Number.parseInt(process.env.BOARD_EXPLORATION_HOURS || '', 10);
        const since = Date.now() - (hours > 0 ? hours : 24) * 3600 * 1000;
        const limit = Number.parseInt(process.env.LEG_EXPLORATION_FLAG_TOKENS || '', 10);
        const flagAt = limit > 0 ? limit : 100000;
        const rows = [];
        for (const name of readdirSync(dir)) {
            if (!name.endsWith('.json')) continue;
            let r;
            try {
                if (statSync(join(dir, name)).mtimeMs < since) continue;
                r = JSON.parse(readFileSync(join(dir, name), 'utf8'));
            } catch { continue; }
            const x = r && r.exploration;
            if (!x || (x.cut !== 'edit' && x.cut !== 'commit') || !Number.isFinite(x.tokens) || x.tokens < 0) continue;
            if (!(r.started_ts >= since)) continue;
            rows.push({ id: name.slice(0, 8), model: typeof r.model === 'string' ? r.model : '?', tokens: x.tokens, reads: x.reads, searches: x.searches });
        }
        if (!rows.length) return '';
        rows.sort((a, b) => b.tokens - a.tokens);
        const asc = rows.map((r) => r.tokens).reverse(), m = asc.length >> 1;
        const median = asc.length % 2 ? asc[m] : (asc[m - 1] + asc[m]) / 2;
        const fmt = (v) => (v >= 1e6 ? `${(v / 1e6).toFixed(1)}M` : v >= 1e3 ? `${Math.round(v / 1e3)}k` : String(Math.round(v)));
        const over = rows.filter((r) => r.tokens > flagAt).length;
        trend.exploration = { window_h: hours > 0 ? hours : 24, flag_tokens: flagAt, sessions: rows.length, median_tokens: median, over_flag: over,
            worst: rows.slice(0, 10).map((r) => ({ session: redact(r.id), model: redact(r.model), tokens: r.tokens })) };
        const trOf = (r) => `<tr data-session="${safe(r.id, 8)}"><td>${safe(r.id, 8)}</td><td>${safe(r.model, 40)}</td><td>${fmt(r.tokens)}</td><td>${Number.isFinite(r.reads) ? r.reads : '-'}r ${Number.isFinite(r.searches) ? r.searches : '-'}s</td><td>${r.tokens > flagAt ? 'OVER' : ''}</td></tr>`;
        const head = '<tr><th>session</th><th>model</th><th>tokens</th><th>reads/searches</th><th>flag</th></tr>';
        archiveTables.push(`<h2>Exploration cost — every session</h2>\n<table>${head}\n${rows.map(trOf).join('\n')}\n</table>`);
        return `<section data-exploration="${rows.length}" data-exploration-over="${over}"><h2>Exploration cost</h2><p class="sub">${rows.length} session${rows.length === 1 ? '' : 's'} · median ${fmt(median)} tokens before first edit · ${over} over ${fmt(flagAt)}${rows.length > 5 ? ' · top 5, the rest in the archive' : ''}</p><div class="tscroll"><table>${head}\n${rows.slice(0, 5).map(trOf).join('\n')}</table></div></section>`;
    } catch { return ''; }
})();

// Failure classes this shift: the leg-failures
// ledger (HIMMEL_LEG_FAILURES_LEDGER, the seam leg_ledger.py writes through) since
// the console lock's `started`, grouped by class -- distinct legs, events (sum of
// count), recovered share, and the failure router's latest decision for the class
// from its log (HIMMEL_FAILURE_ROUTES_LOG; "signal" until P5 routes one). At most 10
// rows, by legs then events. A line under the table counts the memory inbox's `- `
// lines (<bucket>/failure-loop/memory-inbox.md). No lock start or an unreadable
// ledger reads "leg failures unavailable"; never fatal; not part of the fingerprint.
const failuresSection = (() => {
    const title = '<h2>Failure classes — this shift</h2>';
    const unavailable = `<section data-failures="?">${title}<p class="none">leg failures unavailable</p></section>`;
    const jsonRows = (path, start) => {
        if (!existsSync(path)) return [];
        const rows = [];
        for (const line of readFileSync(path, 'utf8').split('\n')) {
            let r;
            try { r = JSON.parse(line); } catch { continue; }
            if (r && typeof r === 'object' && typeof r.ts === 'string' && r.ts >= start && typeof r.class === 'string') rows.push(r);
        }
        return rows;
    };
    try {
        let lock = '';
        try {
            lock = execFileSync('bash', [join(repo, 'scripts', 'handover', 'queue-lock.sh'), 'status', docPath],
                { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] });
        } catch (e) { lock = String(e.stdout || ''); }
        const start = (/"started":"([0-9TZ:-]+)"/.exec(lock) || [])[1];
        if (!start) return unavailable;
        const home = process.env.HOME || '';
        const rows = jsonRows(process.env.HIMMEL_LEG_FAILURES_LEDGER || join(home, '.himmel', 'leg-failures.jsonl'), start);
        const routes = jsonRows(process.env.HIMMEL_FAILURE_ROUTES_LOG || join(home, '.himmel', 'state', 'failure-routes.log.jsonl'), start);
        const byClass = new Map();
        for (const r of rows) {
            const c = byClass.get(r.class) || { legs: new Set(), events: 0, rec: 0, known: 0 };
            c.legs.add(r.leg);
            c.events += typeof r.count === 'number' ? r.count : 1;
            if (typeof r.recovered === 'boolean') { c.known += 1; if (r.recovered) c.rec += 1; }
            byClass.set(r.class, c);
        }
        const lastRoute = new Map();
        for (const r of routes) if (typeof r.decision === 'string') lastRoute.set(r.class, r);
        const sorted = [...byClass].sort(([a, x], [b, y]) => y.legs.size - x.legs.size || y.events - x.events || (a < b ? -1 : a > b ? 1 : 0));
        const route = (cls) => {
            const r = lastRoute.get(cls);
            if (!r) return 'signal';
            const at = `${r.decision} ${r.ts.slice(11, 16)}`;
            return typeof r.ticket === 'string' && r.ticket ? `${r.ticket} (${at})` : at;
        };
        let inbox = 0;
        const inboxPath = join(bucket, 'failure-loop', 'memory-inbox.md');
        if (existsSync(inboxPath)) inbox = readFileSync(inboxPath, 'utf8').split('\n').filter((l) => l.startsWith('- ')).length;
        const inboxLine = `<p class="sub">memory inbox: ${inbox} pending</p>`;
        trend.failures = { since: start, memory_inbox: inbox, classes: [] };
        if (!sorted.length) return `<section data-failures="0">${title}<p class="none">no leg failures this shift</p>${inboxLine}</section>`;
        const toolHealth = readToolHealth(process.env, new URLSearchParams({ since: start }));
        const rates = toolHealth.class_rates || {}, counts = toolHealth.class_counts || {};
        const rateOf = (cls, c) => (typeof rates[cls] === 'number' && counts[cls] === c.events ? rates[cls] : null);
        trend.failures.classes = sorted.map(([cls, c]) => ({ class: redact(cls), sessions: c.legs.size, events: c.events, rate: rateOf(cls, c),
            recovered: c.known ? c.rec / c.known : null, route: redact(route(cls)) }));
        const trOf = ([cls, c]) => `<tr data-class="${safe(cls, 80)}"><td>${safe(cls, 80)}</td><td>${c.legs.size}</td><td>${c.events}</td><td>${rateOf(cls, c) === null ? '—' : `${(rateOf(cls, c) * 100).toFixed(1)} %`}</td><td>${c.known ? `${Math.round((c.rec / c.known) * 100)} %` : '—'}</td><td>${safe(route(cls), 60)}</td></tr>`;
        const head = '<tr><th>class</th><th>worker sessions</th><th>events</th><th>rate</th><th>recovered</th><th>route</th></tr>';
        archiveTables.push(`<h2>Failure classes — this shift, every class</h2>\n<table>${head}\n${sorted.map(trOf).join('\n')}\n</table>`);
        const more = sorted.length > 5 ? `<p class="sub">top 5 of ${sorted.length} classes; the rest in the archive</p>` : '';
        return `<section class="wide" data-failures="${sorted.length}">${title}<div class="tscroll"><table>${head}\n${sorted.slice(0, 5).map(trOf).join('\n')}\n</table></div>${more}${inboxLine}</section>`;
    } catch { return unavailable; }
})();

// Suite flakes: this checkout's suite-flake ledger rows over the last
// BOARD_FLAKE_DAYS (default 7) days, one row per suite, most-flaked first. The rows
// come from the checkout's own scripts/observability/suite-flake-summary.sh (repo id
// filtered, bounded tail); a checkout without it renders no panel. An unreadable
// ledger reads "suite flakes unavailable"; never fatal; not part of the fingerprint.
const flakesSection = (() => {
    const reader = join(repo, 'scripts', 'observability', 'suite-flake-summary.sh');
    if (!existsSync(reader)) return '';
    const d = Number.parseInt(process.env.BOARD_FLAKE_DAYS || '', 10);
    const days = Number.isInteger(d) && d > 0 && d <= 3650 ? d : 7;
    const title = `<h2>Suite flakes — last ${days} days</h2>`;
    try {
        const out = execFileSync('bash', [reader, '--days', String(days), '--format', 'counts'],
            { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        if (out === '?') return `<section data-flakes="?">${title}<p class="none">suite flakes unavailable</p></section>`;
        const rows = out.split('\n').map((l) => /^(\d+)\t(.+)$/.exec(l)).filter(Boolean).slice(0, 10);
        if (!rows.length) return `<section data-flakes="0">${title}<p class="none">no suite flakes in the last ${days} days</p></section>`;
        const tr = rows.map((m) => `<tr data-suite="${safe(m[2], 80)}"><td>${safe(m[2], 80)}</td><td>${m[1]}</td></tr>`).join('\n');
        return `<section data-flakes="${rows.length}">${title}<table><tr><th>suite</th><th>flakes</th></tr>\n${tr}\n</table></section>`;
    } catch { return `<section data-flakes="?">${title}<p class="none">suite flakes unavailable</p></section>`; }
})();

// CR loop, last 7 days: rounds per merged PR (distinct ledger `score` heads per merged
// branch), preflight hits per PR (`preflight` rows; n/a until the pre-round pass writes them),
// residual inflow/outflow from the Jira mirror, each version's residual slots against the
// soft cap (a warning colour, never a refusal), open restructure tickets, and the plan's
// "before" row. CR_LEDGER and BOARD_MIRROR are the seams. Anything unreadable is n/a (null),
// never a failure; not part of the fingerprint. The mirror's `updated` is no proxy for Done.
// ponytail: outflow and net read n/a while any Done residual lacks a `resolved:` mirror date, upgrade path: HIMMEL-6390 (mirror writer emits it).
const CR_SOFT_CAP = 15;
const CR_BEFORE = { window: '2026-10-04..2026-10-18', rounds_mean: 2.71, rounds_p50: 2, rounds_p90: 5, residuals_per_merged_pr: 0.41, residual_inflow_per_week: 200 };
const crLoopSection = (() => {
    const out = { window_days: 7, soft_cap: CR_SOFT_CAP, rounds: { prs: 0, mean: null, p90: null }, preflight: { hits: null, per_pr: null },
        residual: { inflow: null, outflow: null, net: null, per_merged_pr: null, outflow_note: 'outflow needs a resolved date in the mirror (HIMMEL-6390)' },
        versions: [], restructure_open: null, before: CR_BEFORE };
    trend.cr_loop = out;
    const since = Date.now() - 7 * 86400e3;
    const round2 = (v) => Math.round(v * 100) / 100;
    const merged = ghJson(['pr', 'list', '--state', 'merged', '--limit', '1000', '--search', `merged:>=${new Date(since).toISOString().slice(0, 10)}`, '--json', 'number,headRefName,mergedAt']);
    const mergedWin = Array.isArray(merged) ? merged.filter((p) => Date.parse(p.mergedAt) >= since) : null;
    const branches = new Set((mergedWin || []).map((p) => p.headRefName));
    try {
        const ledger = process.env.CR_LEDGER || join(primaryRoot(), '.git', 'cr-critic-scores.jsonl');
        const heads = new Map(), pre = new Map();
        for (const line of readFileSync(ledger, 'utf8').split('\n')) {
            if (!line.includes('"kind":"score"') && !line.includes('"kind":"preflight"')) continue;
            let r;
            try { r = JSON.parse(line); } catch { continue; }
            if (!r || !branches.has(r.branch)) continue;
            if (r.kind === 'score') (heads.get(r.branch) || heads.set(r.branch, new Set()).get(r.branch)).add(r.head);
            else if (r.kind === 'preflight') pre.set(r.branch, Array.isArray(r.classes) ? r.classes.length : 0);
        }
        const rounds = [...heads.values()].map((s) => s.size).sort((a, b) => a - b);
        if (rounds.length) out.rounds = { prs: rounds.length, mean: round2(rounds.reduce((s, n) => s + n, 0) / rounds.length), p90: rounds[Math.ceil(0.9 * rounds.length) - 1] };
        if (pre.size) { const hits = [...pre.values()].reduce((s, n) => s + n, 0); out.preflight = { hits, per_pr: round2(hits / pre.size) }; }
    } catch { /* no readable ledger: rounds and preflight stay n/a */ }
    try {
        const dir = process.env.BOARD_MIRROR || join(process.env.HOME || '', '.himmel', 'state', 'jira-mirror', 'HIMMEL');
        const released = new Set();
        try {
            for (const l of readFileSync(join(dirname(dir), 'HIMMEL.versions.tsv'), 'utf8').split('\n')) {
                const f = l.split('\t');
                if (f[1] === 'true') released.add(f[0]);
            }
        } catch { /* no version list: every version with residual slots shows */ }
        let inflow = 0, restructure = 0, doneMissing = 0, outflow = 0;
        const slots = new Map();
        for (const name of readdirSync(dir)) {
            if (!name.endsWith('.md')) continue;
            const head = readFileSync(join(dir, name), 'utf8').slice(0, 3000).split('\n---')[0];
            const val = (k) => { const m = new RegExp(`^${k}: (.*)$`, 'm').exec(head); if (!m) return null; try { return JSON.parse(m[1]); } catch { return m[1]; } };
            const labels = val('labels') || [], status = String(val('status') || ''), cat = String(val('statusCategory') || '');
            const out = OUT_STATUS.test(status) || OUT_STATUS.test(cat);
            const done = !out && (DONE_STATUS.test(status) || DONE_STATUS.test(cat));
            if (labels.some((x) => /^restructure-class-/.test(x)) && !done && !out) restructure += 1;
            if (!labels.some((x) => /(^|-)residual(-|$)/.test(x))) continue;
            if (Date.parse(val('created')) >= since) inflow += 1;
            if (done) {
                const res = Date.parse(val('resolved'));
                if (Number.isNaN(res)) doneMissing += 1; else if (res >= since) outflow += 1;
            } else if (!out) {
                for (const v of val('fixVersions') || []) slots.set(v, (slots.get(v) || 0) + 1);
            }
        }
        const nMerged = mergedWin ? mergedWin.length : 0;
        out.residual.inflow = inflow;
        if (!doneMissing) { out.residual.outflow = outflow; out.residual.net = inflow - outflow; }
        if (nMerged) out.residual.per_merged_pr = round2(inflow / nMerged);
        out.restructure_open = restructure;
        out.versions = [...slots].filter(([v]) => !released.has(v)).sort(([a], [b]) => a.localeCompare(b, 'en', { numeric: true }))
            .map(([version, n]) => ({ version: redact(version), slots: n, over: n > CR_SOFT_CAP }));
    } catch { /* no readable mirror: residual fields stay n/a */ }
    const na = (v, f) => (v === null ? 'n/a' : f(v));
    const r = out.residual;
    const dark = out.rounds.mean === null && out.preflight.per_pr === null && r.inflow === null;
    const line = dark ? 'n/a — no readable CR ledger or Jira mirror' : `rounds/PR ${na(out.rounds.mean, (v) => v.toFixed(1))} (p90 ${na(out.rounds.p90, String)}) · preflight hits ${na(out.preflight.per_pr, (v) => v.toFixed(1))}/PR · residuals in ${na(r.inflow, String)} · out ${na(r.outflow, String)}${r.outflow === null ? ' (needs HIMMEL-6390)' : ''} · net ${na(r.net, (v) => (v > 0 ? `+${v}` : String(v)))} · restructure open ${na(out.restructure_open, String)} · before ${CR_BEFORE.rounds_mean}/PR, ${CR_BEFORE.residual_inflow_per_week}/wk in`;
    const rows = out.versions.map((v) => `<li data-cr-version="${esc(v.version)}" data-over="${v.over ? 1 : 0}">${esc(v.version)} ${v.slots}/${CR_SOFT_CAP} slots${v.over ? ' — past the soft cap' : ''}</li>`).join('\n');
    return `<section class="wide" data-cr-loop="1"><h2>CR loop (7d)</h2><p class="sub">${esc(line)}</p>${rows ? `<ul class="crv">${rows}</ul>` : ''}</section>`;
})();

// ICE-parked follow-ups: HIMMEL keys cited as follow-ups in the last 14 days of comments
// that now live in the icebox, from ice-followups.sh over the Jira mirror (BOARD_MIRROR is
// the seam; local files only, no network). The panel shows only when a key is parked, to
// keep the live page small (--json still carries count null for an unreadable mirror and 0
// for none); never fatal; not part of the fingerprint.
const iceFollowupsSection = (() => {
    const title = '<h2>ICE-parked follow-ups (14d)</h2>';
    const na = '';
    trend.ice_followups = { count: null, keys: [] };
    try {
        const dir = process.env.BOARD_MIRROR || join(process.env.HOME || '', '.himmel', 'state', 'jira-mirror', 'HIMMEL');
        const lines = execFileSync('bash', [join(HERE, 'ice-followups.sh'), dir],
            { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }).split('\n').filter(Boolean);
        const m = /^ice-followups=(\d+)$/.exec(lines[0] || '');
        if (!m) return na;
        const keys = lines.slice(1).filter((k) => /^HIMMEL-\d+$/.test(k));
        trend.ice_followups = { count: Number(m[1]), keys };
        if (!keys.length) return na;
        return `<section data-ice-followups="${keys.length}">${title}<p class="sub">ice-followups=${keys.length}: cited as follow-ups, now parked in ICE</p><ul>${keys.map((k) => `<li data-ice-key="${esc(k)}">${esc(k)}</li>`).join('')}</ul></section>`;
    } catch { return na; }
})();

const archiveHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Supervisor Session Board — archive</title></head>
<body>
<h1>Supervisor Session Board — archive</h1>
<p>${safe(consoleName)} · rendered ${stamp} · local only, never published · one item per line: grep it</p>
<h2>Done legs</h2>
<ul>
${doneLegs.map((l) => `<li data-archive-leg="${esc(l.label)}">${esc(l.label)} ${esc(l.ticket || '-')} ${esc(l.phase)}${l.prNum ? ` PR #${l.prNum}` : ''} — ${safe(l.last || 'no handover bullet', 400)}</li>`).join('\n')}
</ul>
<h2>Merged PRs</h2>
<ul>
${(mergedPrs || []).map((p) => `<li data-archive-pr="${p.number}">PR #${p.number} merged — ${safe(p.title, 200)}${p.mergedAt ? ` · ${safe(String(p.mergedAt).slice(0, 10))}` : ''}</li>`).join('\n')}
</ul>
${archiveTables.join('\n')}
</body></html>
`;

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Supervisor Session Board</title>
${fp ? `<meta name="console-board-fp" content="${fp}">` : ''}
${ciFleetSig ? `<meta name="console-board-cifleet-fp" content="${esc(ciFleetSig)}">\n` : ''}${censusSig ? `<meta name="console-board-census-fp" content="${safe(censusSig)}">` : ''}${releaseSig ? `\n<meta name="console-board-versions-fp" content="${esc(releaseSig)}">` : ''}${manifestSig ? `\n<meta name="console-board-manifest-fp" content="${esc(manifestSig)}">` : ''}
<style>
:root { --bg:#f6f7f9; --surface:#fff; --text:#1c2128; --muted:#5b6672; --line:#d9dee4; --accent:#2457c5; --ok:#1a7f37; --warn:#9a6700; --bad:#cf222e; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f1318; --surface:#181d24; --text:#e6e9ed; --muted:#96a1ad; --line:#2b333d; --accent:#7aa2ff; --ok:#3fb950; --warn:#d29922; --bad:#ff7b72; } }
:root[data-theme="dark"] { --bg:#0f1318; --surface:#181d24; --text:#e6e9ed; --muted:#96a1ad; --line:#2b333d; --accent:#7aa2ff; --ok:#3fb950; --warn:#d29922; --bad:#ff7b72; }
* { box-sizing: border-box; }
body { margin:0; padding:16px; background:var(--bg); color:var(--text); font:15px/1.45 system-ui, sans-serif; overflow-wrap:anywhere; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:1.35rem; margin:0 0 2px; } h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 8px; }
.sub { color:var(--muted); font-size:.85rem; margin:0 0 14px; }
.banner { background:var(--surface); border:1px solid var(--bad); color:var(--bad); border-radius:8px; padding:8px 12px; margin:0 0 12px; }
.grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap:12px; }
section { background:var(--surface); border:1px solid var(--line); border-radius:10px; padding:12px; min-width:0; }
ul { list-style:none; margin:0; padding:0; } li { padding:6px 0; border-top:1px solid var(--line); } li:first-child { border-top:0; }
.none { color:var(--muted); margin:0; }
.ladder li { display:flex; justify-content:space-between; gap:8px; padding:3px 0; } .ladder li[data-count="0"] { opacity:.45; }
.fleet { font-size:1.6rem; font-weight:650; } .fleet small { font-size:.85rem; color:var(--muted); font-weight:400; }
.idle { color:var(--warn); font-weight:600; }
.tk, .pr, li[data-label] p { color:var(--muted); font-size:.85rem; } li[data-label] p { margin:2px 0 0; } .ph { color:var(--accent); font-weight:600; }
li[data-phase="BLOCKED"] .ph, li[data-phase="WRAPPED, window still open"] .ph, li[data-ci="failing"] .pr { color:var(--bad); } li[data-phase="WRAPPED"] .ph, li[data-phase="MERGED"] .ph, li[data-ci="green"] .pr { color:var(--ok); } li[data-ci="pending"] .pr { color:var(--warn); }
.bar { height:6px; background:var(--line); border-radius:3px; margin-top:4px; } .bar i { display:block; height:100%; background:var(--accent); border-radius:3px; }
.wide { grid-column:1 / -1; }
table { width:100%; border-collapse:collapse; font-size:.85rem; } th, td { text-align:left; padding:4px 6px; border-top:1px solid var(--line); } th { color:var(--muted); font-weight:500; }
.tscroll { overflow-x:auto; } .tscroll table { width:max-content; min-width:100%; }
li[data-over="1"] { color:var(--warn); font-weight:600; }
[data-failures] td:first-child { word-break:normal; overflow-wrap:normal; }
[data-failures] th:nth-child(n+2):nth-child(-n+5), [data-failures] td:nth-child(n+2):nth-child(-n+5) { text-align:right; white-space:nowrap; }
</style>
</head>
<body>
<main>
<h1>Supervisor Session Board</h1>
<p class="sub">${safe(consoleName)} · rendered ${stamp}${lastGo ? ` · last GO ${safe(lastGo)}` : ''}${queueLine ? ` · queue ${safe(queueLine)}` : ''}</p>
<p class="sub" data-archive="${doneLegs.length}">${doneLegs.length} done leg${doneLegs.length === 1 ? '' : 's'} and the merged PRs are in ${safe(basename(archivePath))} (local, not published)</p>
${fp ? '' : '<p class="banner">tick unavailable — this board has no state fingerprint and will read STALE until it is re-rendered.</p>'}
${labelFailure ? `<p class="banner" data-banner="labels-unavailable">leg labels unavailable — ${safe(labelFailure)}; the legs below may be missing or incomplete, not an empty fleet.</p>` : ''}
<div class="grid">
<section>
<h2>Fleet</h2>
${fleetOk ? `<div class="fleet" data-fleet="${fleetLive}/${fleetCap}">${fleetLive}<small>/${fleetCap} legs live</small></div>${idle ? `<div class="idle" data-idle="${idle}">${idle} idle slot${idle === 1 ? '' : 's'} — underfilled</div>` : ''}` : '<p class="none">fleet unavailable</p>'}
<p class="sub">subscription usage budget ${safe(field.bank || '?')} · gql ${safe(field.gql || '?')}</p>
${bankLiftLine}
</section>
<section>
<h2>Phase ladder</h2>
<ul class="ladder">
${ladder}
</ul>
</section>
${costSection}
${explorationSection}
${failuresSection}
${flakesSection}
${crLoopSection}
${iceFollowupsSection}
${panel('Needs the supervisor session', [needRows, orphanRows].filter(Boolean).join('\n'),'nothing waiting on the supervisor session')}
${panel('Open operator decisions', decisions.map((d) => `<li>${safe(d)}</li>`).join('\n'), 'none recorded (Live state decisions:)')}
${epics.length ? panel('Epics — merged / total', epicRows, '') : ''}${releases.map((r) => `\n${releasePanel(r)}`).join('')}
<section class="wide">
<h2>Worker sessions</h2>
${liveLegs.length ? `<ul>${liveLegs.map(legCard).join('\n')}</ul>` : `<p class="none">${labelFailure ? 'worker-session labels unavailable' : 'no live worker sessions'}</p>`}
</section>
${cloudPanel}
${panel('Open PRs', prRows, openPrs ? 'none open' : 'gh unavailable')}
${panel('Supervisor session log — newest last', logRows, 'no Results yet')}
</div>
</main>
</body>
</html>
`;

// ---------------------------------------------------------------- --json model
// himmel.board/1: the reads above as data, for the always-on UI to render. Fields are
// only ever added within /1; a rename or removal bumps the schema. Times are ISO with
// the local offset, or null. Every bullet passes redact(): no nonce, no lock token.
const p2 = (n) => String(n).padStart(2, '0');
const isoOf = (ms) => {
    if (!Number.isFinite(ms)) return null;
    const d = new Date(ms), o = -d.getTimezoneOffset();
    return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}T${p2(d.getHours())}:${p2(d.getMinutes())}${o < 0 ? '-' : '+'}${p2(Math.floor(Math.abs(o) / 60))}:${p2(Math.abs(o) % 60)}`;
};
// A bullet's first HH:MM on its doc's date (the stem's YYYY-MM-DD, else fallbackMs's day);
// a time earlier than the bullet before it rolled past midnight.
const bulletTimes = (bullets, file, fallbackMs) => {
    const ymd = /(\d{4})-(\d{2})-(\d{2})/.exec(basename(file));
    const day = ymd ? new Date(+ymd[1], +ymd[2] - 1, +ymd[3]) : Number.isFinite(fallbackMs) ? new Date(fallbackMs) : null;
    let prev = -Infinity, roll = 0;
    return bullets.map((b) => {
        const m = /^- (\d{1,2}):(\d{2})\b/.exec(b);
        if (!m || !day) return null;
        let t = new Date(day.getFullYear(), day.getMonth(), day.getDate() + roll, +m[1], +m[2]).getTime();
        if (t < prev) { roll += 1; t = new Date(day.getFullYear(), day.getMonth(), day.getDate() + roll, +m[1], +m[2]).getTime(); }
        prev = t;
        return t;
    });
};
const docResults = section('## Results').filter((l) => l.startsWith('- '));
const docTimes = bulletTimes(docResults, docPath);
const goAt = new Map();
docResults.forEach((b, i) => {
    const m = /^- \d{1,2}:\d{2}(?:\s+\d{1,2}:\d{2})?\s+GO\s+#?(\d{2,})\s+[0-9a-f]{7,}/.exec(b);
    if (m && docTimes[i] !== null && !goAt.has(Number(m[1]))) goAt.set(Number(m[1]), docTimes[i]);
});
// GitHub blob/PR links from a checkout's origin remote; anything else reads null.
const githubOf = (dir) => {
    try {
        const url = gitClean(['-C', dir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        const m = /github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?$/.exec(url);
        if (!m) return null;
        const top = gitClean(['-C', dir, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        return { base: `https://github.com/${m[1]}/${m[2]}`, top };
    } catch { return null; }
};
// The model's extra reads (git remotes, transcripts) run only for --json.
const bucketGh = opt.json ? githubOf(bucket) : null;
const prGh = opt.json ? githubOf(prRepo) : null;
const briefUrl = (file) => (bucketGh && file && file.startsWith(`${bucketGh.top}/`) ? `${bucketGh.base}/blob/main/${file.slice(bucketGh.top.length + 1)}` : null);
const PR_OPEN = /^- (?:\d{1,2}:\d{2}\s+)?LIVE\s*[-–—:]?\s*PR\s*#?\d{2,}\s+open\b/;
const STAGES = ['dispatch', 'live', 'pr', 'ready', 'go', 'merged'];
const legModel = (l) => {
    const info = legInfo.get(l.label) || { bullets: [], file: '' };
    const bullets = info.bullets || [];
    const times = bulletTimes(bullets, info.file || '');
    const firstAt = (re) => { const i = bullets.findIndex((b) => re.test(b)); return i < 0 ? null : times[i]; };
    const stages = { dispatch: null, live: times.find((t) => t !== null) ?? null, pr: null, ready: firstAt(/^- (?:\d{1,2}:\d{2}\s+)?READY\b(?!-)/), go: null, merged: firstAt(/^- (?:\d{1,2}:\d{2}\s+)?MERGED\b/) };
    const prAt = firstAt(PR_OPEN);
    stages.pr = prAt !== null && (stages.ready === null || prAt <= stages.ready) ? prAt : stages.ready;
    if (l.prNum && goAt.has(l.prNum)) stages.go = goAt.get(l.prNum);
    let stage = 'dispatch';
    for (const s of STAGES) if (stages[s] !== null) stage = s;
    let at = 'live';
    const timeline = bullets.map((b, i) => {
        if (PR_OPEN.test(b)) at = 'pr';
        const mk = markerOf(b);
        if (mk === 'READY') at = 'ready';
        if (mk === 'MERGED') at = 'merged';
        return { at: isoOf(times[i]), stage: at, marker: mk.toLowerCase(), text: redact(b.slice(2)).slice(0, 400) };
    });
    const state = l.phase === 'BLOCKED' ? 'blocked'
        : l.tail === 'FINDING' ? 'needs-decision'
            : l.lostLock || l.phase === 'READY-TO-OPEN' || l.phase === 'WRAPPED, window still open' ? 'needs-operator'
                : l.phase === 'READY' ? (l.prNum && lastGo.startsWith(`${l.prNum}:`) ? 'merging' : 'ready-for-go')
                    : l.phase === 'PR open' ? 'in-review' : 'building';
    const pr = l.prNum ? openByNum.get(l.prNum) : null;
    const goal = pr ? redact(String(pr.title).replace(/^[a-z]+(?:\([^)]*\))?!?:\s*/i, '').replace(/\[[A-Z][A-Z0-9]*-\d+\]\s*/g, '')) : '';
    return { leg: l.label, ticket: l.ticket || '', goal, state, stage, stages: Object.fromEntries(STAGES.map((s) => [s, isoOf(stages[s] ?? NaN)])),
        pr: l.prNum ? { number: l.prNum, url: prGh ? `${prGh.base}/pull/${l.prNum}` : null } : null,
        links: { ticket: l.ticket && process.env.JIRA_BASE_URL ? `${process.env.JIRA_BASE_URL.replace(/\/$/, '')}/browse/${l.ticket}` : null, brief: briefUrl(info.file) },
        timeline, lastAt: [...times].reverse().find((t) => t !== null) ?? null };
};
const legRows = liveLegs.map((l) => ({ l, m: legModel(l) }));
const needOf = ({ l, m }) => {
    const readyB = [...(legInfo.get(l.label)?.bullets || [])].reverse().find((b) => markerOf(b) === 'READY') || '';
    const head = (/READY\s+#?\d{2,}\s+([0-9a-f]{7,40})\b/.exec(readyB) || [])[1];
    const [verb, action, command] = m.state === 'ready-for-go' ? ['go', `judge and GO PR #${l.prNum}`, head ? `bash scripts/handover/console-kit/go.sh ${l.prNum} ${head}` : null]
        : m.state === 'blocked' ? ['unblock', 'clear the BLOCKED leg', null]
            : m.state === 'needs-decision' ? ['decide', 'rule on the FINDING', null]
                : l.lostLock ? ['act', `lock ${l.lock.toLowerCase()}: re-arm or wrap the leg`, null]
                    : l.phase === 'READY-TO-OPEN' ? ['act', 'open the PR', null]
                        : ['act', 'close the leg window', null];
    return { leg: l.label, verb, action: action.slice(0, 90), detail: redact(l.last || ''), command, since: isoOf(m.lastAt ?? NaN) };
};
const needsYou = legRows.filter(({ l }) => l.needs).map(needOf).sort((a, b) => String(a.since).localeCompare(String(b.since)));
const STAGE_RANK = Object.fromEntries(STAGES.map((s, i) => [s, i]));
const needSet = new Set(needsYou.map((n) => n.leg));
const legsOut = legRows.map(({ m }) => m).sort((a, b) => (needSet.has(b.leg) - needSet.has(a.leg)) || STAGE_RANK[b.stage] - STAGE_RANK[a.stage])
    .map(({ lastAt, ...m }) => m);
const ciRows = (openPrs || []).map((p) => (!(p.statusCheckRollup || []).length ? 'no_checks' : ciOf(p) === 'failing' ? 'red' : ciOf(p)));
const ciOut = { open: ciRows.length, green: 0, pending: 0, no_checks: 0, red: 0 };
for (const c of ciRows) ciOut[c] += 1;
const pct = (re) => { const m = re.exec(field.bank || ''); return m ? Number(m[1]) : null; };
const bankOut = { week_pct: pct(/wk(\d+)/), five_hour_pct: pct(/5h(\d+)/) };
const todayKey = stamp.slice(0, 10);
const mergedToday = (mergedPrs || []).filter((p) => p.mergedAt && isoOf(Date.parse(p.mergedAt))?.slice(0, 10) === todayKey).length;
const milestones = releases.map((r) => (r.unavailable ? { version: r.version, unavailable: true }
    : { version: r.version, done: r.done, total: r.total, open_blockers: r.blockers.map((b) => b.key) }));

// Session transcripts: one jsonl per session under BOARD_TRANSCRIPTS (else this checkout's
// ~/.claude/projects dir); line 1 names the session (custom-title = a console doc stem).
// Only files touched in the last 48 h are opened. A message is counted once by id, in
// Opus-eq: input + cache_read x0.1 + cache_write x2 + output x5. Unreadable reads empty.
const txByTitle = new Map();
if (opt.json) try {
    const TX_DIR = process.env.BOARD_TRANSCRIPTS || join(process.env.HOME || '', '.claude', 'projects', primaryRoot().replace(/[^A-Za-z0-9]/g, '-'));
    const cutoff = Date.now() - 48 * 3600e3;
    for (const f of readdirSync(TX_DIR)) {
        if (!f.endsWith('.jsonl')) continue;
        const p = join(TX_DIR, f);
        try {
            if (statSync(p).mtimeMs < cutoff) continue;
            const fd = openSync(p, 'r'), buf = Buffer.alloc(4096);
            const n = readSync(fd, buf, 0, 4096, 0);
            closeSync(fd);
            const t = JSON.parse(buf.toString('utf8', 0, n).split('\n')[0]).customTitle;
            if (typeof t === 'string') txByTitle.set(t, [...(txByTitle.get(t) || []), p]);
        } catch { /* not a titled transcript */ }
    }
} catch { /* no transcript dir: no console cost, no succession row */ }
const messagesOf = (title) => {
    const byId = new Map();
    for (const p of txByTitle.get(title) || []) {
        let text = '';
        try { text = readFileSync(p, 'utf8'); } catch { continue; }
        for (const line of text.split('\n')) {
            if (!line.includes('"usage"')) continue;
            let r;
            try { r = JSON.parse(line); } catch { continue; }
            const u = r && r.message && r.message.usage, id = r && r.message && r.message.id, ts = Date.parse(r && r.timestamp);
            if (!u || !id || !Number.isFinite(ts)) continue;
            const eq = Math.round((u.input_tokens || 0) + (u.cache_read_input_tokens || 0) * 0.1 + (u.cache_creation_input_tokens || 0) * 2 + (u.output_tokens || 0) * 5);
            byId.set(id, { ts: byId.has(id) ? byId.get(id).ts : ts, eq });
        }
    }
    return [...byId.values()].sort((a, b) => a.ts - b.ts);
};
const sumEq = (ms) => ms.reduce((s, m) => s + m.eq, 0);
const consoleMsgs = messagesOf(consoleName);
const consoleCost = (() => {
    if (!consoleMsgs.length) return null;
    const hourly = new Map();
    for (const m of consoleMsgs) {
        const d = new Date(m.ts);
        const h = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()).getTime();
        hourly.set(h, (hourly.get(h) || 0) + m.eq);
    }
    const eq = sumEq(consoleMsgs);
    const span = (consoleMsgs[consoleMsgs.length - 1].ts - consoleMsgs[0].ts) / 3600e3;
    return { unit: 'opus-eq', since: isoOf(consoleMsgs[0].ts), messages: consoleMsgs.length, eq, per_hour: Math.round(eq / Math.max(1, span)),
        hourly: [...hourly].sort((a, b) => a[0] - b[0]).map(([h, v]) => ({ hour: isoOf(h), eq: v })), fleet_eq: trend.cost ? Math.round(trend.cost.total) : null };
})();
// The succession into this console as a tool-eval row: the predecessor is the one the
// live legs' `SUCCESSION accepted: <this console> replaces <pred>` bullets name. The window
// runs from this session's first message to its first `LIVE` Results bullet (the
// `<code> LIVE sent to <pred>` line), for both sessions.
const SUCCESSION_TARGET = { eq: 457000, turns: 20 };
const succession = (() => {
    const accepts = liveLegs.map((l) => [...(legInfo.get(l.label)?.bullets || [])].reverse()
        .map((b) => /SUCCESSION accepted:\s*(\S+)\s+replaces\s+(\S+)/.exec(b)).find((m) => m && m[1] === consoleName)).filter(Boolean);
    if (!accepts.length || !consoleMsgs.length) return [];
    const pred = accepts[0][2].replace(/[.,;]+$/, '');
    const start = consoleMsgs[0].ts;
    const liveIdx = docResults.findIndex((b) => /^- \d{1,2}:\d{2}(?:\s+\d{1,2}:\d{2})?\s+(?:[A-Z]{1,3}\s+)?LIVE\b/.test(b));
    const liveAt = liveIdx < 0 ? null : bulletTimes(docResults, docPath, start)[liveIdx];
    const end = liveAt === null ? Infinity : liveAt;
    const win = [...consoleMsgs, ...messagesOf(pred)].filter((m) => m.ts >= start && m.ts <= end);
    const eq = sumEq(win), turns = win.length;
    const silent = Math.max(0, liveLegs.length - accepts.length);
    const pass = liveAt !== null && eq <= SUCCESSION_TARGET.eq && turns <= SUCCESSION_TARGET.turns;
    const recommendation = liveAt === null ? 'succession still running: no LIVE bullet yet'
        : `${pass ? 'within target' : `over target (${Math.round(eq / 1e3)}k eq, ${turns} turns vs ${SUCCESSION_TARGET.eq / 1e3}k, ${SUCCESSION_TARGET.turns}): script the hand-off steps (HIMMEL-5969)`}${silent ? `; re-brief the ${silent} silent leg${silent === 1 ? '' : 's'} from the predecessor` : ''}`;
    return [{ tool: 'console-succession', from: redact(pred), to: consoleName, started: isoOf(start), live_at: isoOf(liveAt ?? NaN), wall_min: liveAt === null ? null : Math.round((liveAt - start) / 60000),
        turns, eq, legs_quoted: accepts.length, legs_silent: silent, target: SUCCESSION_TARGET, pass, recommendation }];
})();

// The legend keys every colour the UI draws; colours are theme token names (--acc, --ok, ...).
const LEGEND = {
    stage: { dispatch: ['mut', 'dispatched'], live: ['acc', 'LIVE'], pr: ['vio', 'PR open'], ready: ['warn', 'READY'], go: ['ok', 'GO'], merged: ['ok', 'merged'] },
    state: { building: ['acc', 'building'], 'in-review': ['vio', 'in review · CI'], 'needs-decision': ['bad', 'needs a decision'], 'needs-operator': ['bad', 'needs the operator'],
        'ready-for-go': ['warn', 'waiting for GO'], blocked: ['bad', 'blocked'], merging: ['ok', 'merging'] },
    verb: { decide: ['acc', 'Decide'], act: ['bad', 'Act'], go: ['warn', 'GO'], unblock: ['bad', 'Unblock'] },
    ci: { green: ['ok', 'green'], pending: ['warn', 'pending'], no_checks: ['mut', 'no checks yet'], red: ['bad', 'red'] },
    budget: { ok: ['ok', 'under 70 %'], high: ['warn', '70 to 84 %'], critical: ['bad', '85 % and over'] },
    failure: { denial: ['warn', 'guard denial'], error: ['bad', 'tool error'] },
    marker: { live: ['acc', 'LIVE'], finding: ['warn', 'FINDING'], resolved: ['ok', 'RESOLVED'], ready: ['ok', 'READY'], blocked: ['bad', 'BLOCKED'], halted: ['bad', 'HALTED'], wrapped: ['mut', 'WRAPPED'] },
};
const legend = Object.fromEntries(Object.entries(LEGEND).map(([k, v]) => [k, Object.fromEntries(Object.entries(v).map(([n, [color, label]]) => [n, { color, label }]))]));

// One recommended action per report card, derived from the data above; the UI only renders it.
const countState = (s) => legsOut.filter((l) => l.state === s).length;
const cards = {
    velocity: { recommendation: countState('ready-for-go') ? `${mergedToday} merged today; ${countState('ready-for-go')} READY wait for GO: judge them first`
        : countState('in-review') ? `${mergedToday} merged today; ${countState('in-review')} in review: keep /pr-check and CI moving`
            : mergedToday ? `${mergedToday} merged today; nothing waits for GO` : 'none merged today: check what the live legs are stuck on' },
    health: { recommendation: needsYou.length ? `${needsYou.length} leg${needsYou.length === 1 ? '' : 's'} need you: start with ${needsYou[0].leg} (${needsYou[0].verb})`
        : ciOut.red ? `${ciOut.red} open PR${ciOut.red === 1 ? '' : 's'} red: triage the CI`
            : bankOut.week_pct !== null && bankOut.week_pct >= 85 ? `weekly budget at ${bankOut.week_pct} %: hold new dispatches`
                : idle ? `${idle} idle slot${idle === 1 ? '' : 's'}: dispatch the next ticket` : 'fleet healthy: nothing to do' },
    tools: { recommendation: succession.length && !succession[0].pass ? `console succession: ${succession[0].recommendation}`
        : trend.failures && trend.failures.classes.length ? `${trend.failures.classes[0].class} hit ${trend.failures.classes[0].sessions} session${trend.failures.classes[0].sessions === 1 ? '' : 's'}: ${trend.failures.classes[0].route === 'signal' ? 'file a ticket or a memory for it' : `follow ${trend.failures.classes[0].route}`}`
            : trend.exploration && trend.exploration.over_flag ? `${trend.exploration.over_flag} session${trend.exploration.over_flag === 1 ? '' : 's'} explored past the flag: tighten their briefs`
                : 'no tool failures this shift' },
    roadmap: { recommendation: (() => {
        const ok = milestones.filter((m) => !m.unavailable);
        const blocked = ok.find((m) => m.open_blockers.length);
        if (blocked) return `${blocked.version}: ${blocked.done}/${blocked.total} done; clear ${blocked.open_blockers.join(', ')} first`;
        const open = ok.find((m) => m.done < m.total);
        if (open) return `${open.version}: ${open.total - open.done} ticket${open.total - open.done === 1 ? '' : 's'} left`;
        if (!milestones.length) return 'add a versions: line to Live state to track milestones';
        return ok.length ? 'every milestone is done' : 'milestones unavailable: check the Jira CLI';
    })() },
};
const legTimeToday = legRows.map(({ m }) => m).concat(doneLegs.map((l) => legModel(l)))
    .filter((m) => m.stages.merged && m.stages.merged.slice(0, 10) === todayKey)
    .map((m) => {
        const min = (a, b) => (m.stages[a] && m.stages[b] ? Math.round((Date.parse(m.stages[b]) - Date.parse(m.stages[a])) / 60000) : null);
        return { leg: m.leg, live_at: m.stages.live, merged_at: m.stages.merged, live_to_merged_min: min('live', 'merged'), to_pr_min: min('live', 'pr'), ready_to_merged_min: min('ready', 'merged') };
    });
const boardModel = {
    schema: 'himmel.board/1',
    generated_at: isoOf(now.getTime()),
    console: { name: consoleName, archive_legs: doneLegs.length },
    headline: { live: fleetOk ? fleetLive : liveLegs.length, cap: fleetOk ? fleetCap : null, merged_today: mergedToday, needs_you: needsYou.length, blocked: countState('blocked') },
    bank: bankOut,
    ci: ciOut,
    milestones,
    needs_you: needsYou,
    legs: legsOut,
    trends: { leg_time: { unit: 'min', today: legTimeToday }, cost: trend.cost, console_cost: consoleCost, exploration: trend.exploration, failures: trend.failures, cr_loop: trend.cr_loop, ice_followups: trend.ice_followups, tools: succession },
    legend,
    cards,
};

// Ask 1: --changed reads the PREVIOUS render's embedded
// fingerprint before overwriting it, so a console can call this after every
// Live-state mutation and know from one line whether the render moved --
// the Artifact publish itself stays a separate, deliberate model step.
let oldFp = null;
let oldCensusSig = '';
let oldReleaseSig = '';
let oldCiFleetSig = '';
let oldManifestSig = '';
if (changedFlag && existsSync(outPath)) {
    const prev = readFileSync(outPath, 'utf8');
    oldFp = (/<meta name="console-board-fp" content="([0-9a-f]{16})">/.exec(prev) || [])[1] || null;
    oldCensusSig = (/<meta name="console-board-census-fp" content="([^"]*)">/.exec(prev) || [])[1] || '';
    oldCiFleetSig = (/<meta name="console-board-cifleet-fp" content="([^"]*)">/.exec(prev) || [])[1] || '';
    oldReleaseSig = (/<meta name="console-board-versions-fp" content="([^"]*)">/.exec(prev) || [])[1] || '';
    oldManifestSig = (/<meta name="console-board-manifest-fp" content="([^"]*)">/.exec(prev) || [])[1] || '';
}
const tmp = `${outPath}.tmp${process.pid}`;
writeFileSync(tmp, html);
renameSync(tmp, outPath);
const archiveTmp = `${archivePath}.tmp${process.pid}`;
writeFileSync(archiveTmp, archiveHtml);
renameSync(archiveTmp, archivePath);
// The AG-UI page reads <console doc>.board.json beside the doc, so every render also refreshes it.
{
    const jsonPath = resolve(opt.json || join(bucket, `${basename(docPath, '.md')}.board.json`));
    const jsonTmp = `${jsonPath}.tmp${process.pid}`;
    writeFileSync(jsonTmp, `${JSON.stringify(boardModel, null, 1)}\n`);
    renameSync(jsonTmp, jsonPath);
}
if (changedFlag) {
    console.log(`${fp !== oldFp || censusSig !== oldCensusSig || esc(ciFleetSig) !== oldCiFleetSig || esc(releaseSig) !== oldReleaseSig || esc(manifestSig) !== oldManifestSig ? 'CHANGED' : 'UNCHANGED'} ${outPath}`);
} else {
    console.log(outPath);
}
