// scripts/lanes/cloud-route.mjs
// classify tickets for the cloud credit lane, write the brief,
// print the operator launch line.
//
// A sibling of fanout-plan.mjs, not an extension of it: /fanout routes an
// abstract work item to a model tier through a pure function, while this gates a
// real Jira ticket (live Jira + gh reads) and writes files into the chief
// bucket. It NEVER launches a session — `claude --cloud` needs a TTY in the
// operator's terminal and spends credit, so the tool only prints the line.
//
// Classes, first match wins:
//   BLOCKED      ticket not To Do/Backlog/Open, or the file tree or merged-PR list is unknown. A held file
//                never blocks: the chief's --held list and the files of a CLOUD-OK ticket routed earlier
//                in the run are information, and the reason of whatever class is picked ends in `overlaps <file> (<why>)`,
//                a directory it names included (`contains held <file>`)
//   HOOK-BYPASS  touches scripts/hooks/ (hooks do not run in the cloud, and the
//                integrity guard locks hook edits out of a normal worker)
//   LOCAL-NATIVE a trust path (needs a trust-reviewed GO), a run-time need the
//                cloud lacks by design (luna, a vault, handover state, the state repo
//                or its specs: private data never leaves the station), more than 3 asks, or no file
//                named to scope a brief on. graphify and BM25 qmd over the repo
//                are not such a need: the cloud setup installs both.
//                qmd query, vector search and embeds are: it has no qmd models.
//                So is a semantic graphify run (/graphify, --backend): it would
//                send content to a model backend. Station-bound work is too:
//                ~/.himmel or ~/.cache state, a test VM
//                (himmel-ops:vm, vmsdk, VBoxManage), a LIVE ledger, arming a
//                cadence (at/systemd); VM-only, "on a VM" and VM snapshot wording,
//                and a named file the tree at the base cannot place
//   VERIFY-LOCAL a merged PR cites the ticket key, or touches a
//                file it names, after the ticket was created: it may already be
//                fixed on main, so a local worker verifies it first (a cloud session
//                cannot tell, and spends credit on a no-op)
//   CLOUD-OK     everything else
import { readFileSync, appendFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { gitClean } from './git-clean.mjs';
import { dirname, join, resolve, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const REPO_SLUG = 'yotamleo-org/Himmel'; // env-literal-ok: the canonical slug; --search does not follow a repo rename, and the dispatcher's own reads use this one
const HOOKS = /^scripts\/hooks\//;
// What the cloud lane can and cannot do is data: every matrix row with a `match`
// is a run-time need that keeps a ticket on the station, and max_asks caps asks.
export const MATRIX_PATH = join(HERE, 'cloud-capabilities.json');
export function loadMatrix(path = MATRIX_PATH) { return JSON.parse(readFileSync(path, 'utf8')); }
const compiled = new WeakMap();
let defaultMatrix;
function needsOf(matrix) {
  if (!compiled.has(matrix)) {
    const rows = matrix.rows.filter((r) => r.match).map((r) => ({ ...r, re: new RegExp(r.match, 'iy') }));
    // no match rows: a pattern that never matches, not the empty one that matches everything
    const re = rows.length ? new RegExp(rows.map((r) => r.match).join('|'), 'i') : /(?!)/;
    compiled.set(matrix, { rows, re, max: matrix.max_asks });
  }
  return compiled.get(matrix);
}
// the row whose own pattern produced the combined match: same start, same text
function rowOf(needs, m) {
  return needs.rows.find((r) => { r.re.lastIndex = m.index; return r.re.exec(m.input)?.[0] === m[0]; });
}
const BARE_RE = /(?<![\w./-])([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?:\.(?:sh|mjs|js|py|ps1))?(?![\w/-]|\.\w)/g;
const FILE_RE = /(?<![\w./-])((?:scripts|docs|marketplace|templates|tools|skills|plugins|packaging|tests|\.agents|\.claude|\.github|\.codex)\/[\w.+@-]+(?:\/[\w.+@-]+)*\/?|CLAUDE\.md|AGENTS\.md|\.pre-commit-config\.yaml)/g;

// The trust list is read as data, one extended regex per line (ci-trust-paths.txt).
export function loadTrust(path = join(REPO, 'scripts', 'ci', 'ci-trust-paths.txt')) {
  return readFileSync(path, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#')).map((l) => new RegExp(l));
}

export function parseJiraGet(raw) {
  const text = raw.trimEnd();
  const nl = text.indexOf('\n');
  const [key, type, status, ...title] = (nl < 0 ? text : text.slice(0, nl)).split('\t');
  return { key, type, status, title: title.join('\t'), description: nl < 0 ? '' : text.slice(nl + 1).trim(), raw: text };
}

// a slashed path (ending in an extension or a trailing slash) that FILE_RE does
// not recognise is silently dropped from the file list, so it cannot be checked against held
// files. A URL or a slashed word (and/or, owner/repo) is not one. ponytail: an extensionless
// path outside the known roots (src/lib/foo) is still invisible, upgrade path: resolve
// against the tree.
const PATH_RE = /(?<![\w./:@-])((?:[\w.+@-]+\/)+(?:[\w.+@-]*\.[A-Za-z][A-Za-z0-9]{0,11})?)(?![\w+@-]|\.\w)/g;
const KNOWN_ROOT = new RegExp(`^${FILE_RE.source}`);
export function unrecognisedPaths(text) {
  const out = [];
  for (const m of text.matchAll(PATH_RE)) {
    const p = m[1];
    if (p && !KNOWN_ROOT.test(p) && !out.includes(p)) out.push(p);
  }
  return out;
}

export function extractFiles(text) {
  const out = [];
  for (const m of text.matchAll(FILE_RE)) {
    const f = m[1].replace(/[.,;:)\]-]+$/, '');
    if (f && !out.includes(f)) out.push(f);
  }
  return out;
}

// a ticket may name a hook or script by its bare name (guard-pr-check-literal,
// not scripts/hooks/guard-pr-check-literal.sh), so the hook, trust and held checks never saw
// it. A hyphenated token that is the stem of a script under scripts/ at the base resolves to
// every such path. ponytail: a hyphenated English word that is also a script stem resolves
// too, which only over-routes local; narrow when it becomes noise.
const SCRIPT_EXT = /\.(?:sh|mjs|js|py|ps1)$/;
export function bareNames(text, tree) {
  const stems = new Map();
  for (const p of tree) {
    if (!p.startsWith('scripts/') || !SCRIPT_EXT.test(p)) continue;
    const stem = posix.basename(p).replace(SCRIPT_EXT, '');
    stems.set(stem, [...(stems.get(stem) ?? []), p]);
  }
  const out = [];
  for (const m of text.matchAll(BARE_RE)) for (const p of stems.get(m[1]) ?? []) if (!out.includes(p)) out.push(p);
  return out;
}

// A named path the router cannot place: not in the tree and no sibling under its
// directory either (a typo or a moved file; a new file in a known directory is placed).
export function unresolved(files, tree) {
  const set = new Set(tree);
  const dirs = new Set(tree.map((p) => posix.dirname(p)));
  return files.filter((f) => {
    const d = f.replace(/\/$/, '');
    if (set.has(d) || dirs.has(d) || tree.some((p) => p.startsWith(`${d}/`))) return false;
    return !dirs.has(posix.dirname(d)) && !tree.some((p) => p.startsWith(`${posix.dirname(d)}/`));
  });
}

// Ask lines: the numbered or bulleted lines under an "Asks:" header, else any
// numbered line, else any bulleted line; a ticket with none is one ask.
export function askLines(description) {
  const lines = description.split('\n');
  const pick = (ls, re) => ls.filter((l) => re.test(l)).map((l) => l.trim());
  const at = lines.findIndex((l) => /^\s*asks?\s*:/i.test(l));
  const under = at >= 0 ? pick(lines.slice(at + 1), /^\s*(\d+[.)]|[-*])\s/) : [];
  if (under.length) return under;
  const numbered = pick(lines, /^\s*\d+[.)]\s/);
  return numbered.length ? numbered : pick(lines, /^\s*[-*]\s/);
}

const overlaps = (a, b) => a === b || b.startsWith(a.replace(/\/?$/, '/')) || a.startsWith(b.replace(/\/?$/, '/'));

const STALE_DAYS = 14;
const MERGED_PAGE = 30; // the per-ticket merged search reads this many; a full page may hide more matches

// fixedBy(ticket, files, ctx) -> [{number, why, mergedAt}]: merged PRs that cite the key
// (not a longer key sharing its prefix) or touch a named file, merged after the ticket was
// created. Jira's `get` carries no creation date, so without ticket.created (chief spec)
// the cutoff is the last STALE_DAYS days. ponytail: a PR that merely lists the key as a
// deferral also matches, which only costs a local verify; narrow when it becomes noise.
export function fixedBy(t, files, ctx) {
  const parsed = Date.parse(t.created ?? '');
  const cutoff = Number.isNaN(parsed) ? (ctx.now ?? Date.now()) - STALE_DAYS * 86400e3 : parsed;
  const cites = new RegExp(`${t.key}(?!\\d)`);
  const out = [];
  for (const pr of ctx.merged ?? []) {
    const at = Date.parse(pr.mergedAt ?? '');
    if (Number.isNaN(at) || at < cutoff) continue;
    const paths = (pr.files ?? []).map((f) => (typeof f === 'string' ? f : f.path)).filter(Boolean);
    const hit = files.find((f) => paths.some((p) => overlaps(p, f)));
    if (cites.test(`${pr.title ?? ''}\n${pr.body ?? ''}`)) out.push({ number: pr.number, why: `cites ${t.key}`, mergedAt: pr.mergedAt });
    else if (hit) out.push({ number: pr.number, why: `touches ${hit}`, mergedAt: pr.mergedAt });
  }
  return out;
}

// classifyTicket(ticket, {trust, held, merged, mergedUnknown, tree, treeUnknown, now}) -> {class, reason, files, asks, prs?}. Pure.
// held is [{file, why}], information only: it adds an `overlaps ...` clause to the reason, it never picks a class.
// ticket.files (chief-supplied) overrides text extraction.
export function classifyTicket(t, ctx) {
  const text = `${t.title}\n${t.description}`;
  const named = t.files?.length ? t.files : [...extractFiles(text), ...bareNames(text, ctx.tree ?? [])];
  // a directory in the tree is named with its slash, whatever punctuation followed it in the text
  const asDir = (f) => (!f.endsWith('/') && (ctx.tree ?? []).some((p) => p.startsWith(`${f}/`)) ? `${f}/` : f);
  const files = [...new Set(named.map((f) => asDir(posix.normalize(f))))];
  const asks = Math.max(1, askLines(t.description).length);
  const shared = new Set();
  for (const f of files) {
    for (const h of ctx.held ?? []) {
      if (!overlaps(f, h.file)) continue;
      shared.add(h.file !== f && h.file.startsWith(f.replace(/\/?$/, '/')) ? `${f} (contains held ${h.file}, ${h.why})` : `${f} (${h.why})`);
    }
  }
  const overlap = shared.size ? ` — overlaps ${[...shared].join('; ')}` : '';
  const v = (cls, reason) => ({ class: cls, reason: reason + overlap, files, asks });
  const needs = needsOf(ctx.matrix ?? (defaultMatrix ??= loadMatrix()));

  if (!/^(to do|backlog|open)$/i.test(t.status ?? '')) return v('BLOCKED', `status is '${t.status}', not To Do/Backlog/Open — already in flight or done`);
  // a run-time need (state-repo spec paths and the like) is the more specific LOCAL-NATIVE reason
  const strange = t.files?.length || needs.re.test(text) ? [] : unrecognisedPaths(text);
  const hook = files.find((f) => HOOKS.test(f));
  if (hook) return v('HOOK-BYPASS', `touches ${hook} — hooks do not run in the cloud and edits need the hook-integrity bypass`);
  const trust = files.find((f) => (ctx.trust ?? []).some((re) => re.test(f)));
  if (trust) return v('LOCAL-NATIVE', `touches trust path ${trust} — needs a trust-reviewed GO`);
  if (strange.length) return v('LOCAL-NATIVE', `unrecognised path ${strange.join(', ')} — outside the known roots, so the hook, trust and held checks cannot be trusted (pass files)`);
  if (!files.length) return v('LOCAL-NATIVE', 'no file named in the ticket — nothing to scope a brief on (pass files)');
  const need = text.match(needs.re);
  if (need) {
    const row = rowOf(needs, need);
    return v('LOCAL-NATIVE', `run-time need '${need[0]}' [cloud-matrix: ${row.id}] — the cloud ${row.state === 'partial' ? 'only partly has' : 'has no'} ${row.capability}: ${row.local_split}`);
  }
  if (asks > needs.max) return v('LOCAL-NATIVE', `${asks} asks (more than ${needs.max}) [cloud-matrix: multi-ask] — past the cloud ask cap`);
  if (ctx.treeUnknown) return v('BLOCKED', 'file tree unavailable (git failed) — cannot resolve the named files');
  const lost = ctx.tree ? unresolved(files, ctx.tree) : [];
  if (lost.length) return v('LOCAL-NATIVE', `cannot resolve ${lost.join(', ')} at the base — no such file or directory, so the hook, trust and held checks cannot be trusted (pass files)`);
  if (ctx.mergedUnknown) return v('BLOCKED', 'merged-PR list unavailable (gh failed) — cannot prove the ticket is not already fixed');
  if (ctx.mergedTruncated?.has(t.key)) return v('BLOCKED', `merged-PR list unavailable for ${t.key} (${MERGED_PAGE} merged PRs match it, so the search may be truncated) — cannot prove the ticket is not already fixed`);
  const fixed = fixedBy(t, files, ctx);
  if (fixed.length) return { ...v('VERIFY-LOCAL', `may already be fixed on main — ${fixed.map((f) => `PR ${f.number} (${f.why}, merged ${String(f.mergedAt).slice(0, 10)})`).join('; ')}; verify locally before any cloud session`), prs: fixed.map((f) => f.number) };
  return v('CLOUD-OK', `${files.length} file(s), ${asks} ask(s), no hook, trust path or run-time need${shared.size ? '' : ', none held'}`);
}

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').split('-').slice(0, 6).join('-').slice(0, 40).replace(/-$/, '');

// buildBrief(ticket, opts) -> string, following docs/handover/cloud-brief-template.md.
export function buildBrief(t, o = {}) {
  const n = t.key.replace(/^HIMMEL-/, '');
  const date = o.date ?? new Date().toISOString().slice(0, 10);
  const type = o.branchType ?? (/^bug$/i.test(t.type) ? 'fix' : 'feat');
  const branch = `${type}/himmel-${n}-${slug(t.title)}`;
  const subject = `${type}: [${t.key}] ${t.title.toLowerCase()}`;
  const files = t.files?.length ? t.files : extractFiles(`${t.title}\n${t.description}`);
  const exists = o.exists ?? (() => true);
  const named = files.map((f) => `- \`${f}\`${exists(f) ? '' : ' (not on main: create it)'}`).join('\n');
  const asks = askLines(t.description);
  const coverage = asks.length ? asks.map((a) => `- ${a.replace(/^(?:\d+[.)]|[-*])\s*/, '')} — done`).join('\n') : `- ${t.title} — done`;
  const completes = o.completes ?? 'yes';
  const change = o.change ?? "Implement the ticket's asks above, in the named files only.";
  return `You are working in a cloud clone of the GitHub repo yotamleo/Himmel. This is a small, well-scoped task. Work only from this brief and the repo. You have no local state. Jira is reachable only through the Atlassian MCP connector (the local jira CLI is absent in the cloud), and that connector may not be enabled in your session. If the Atlassian MCP tools are listed in this session, use them; otherwise do not try a workaround, and list each skipped Jira step under a \`## Jira steps not done\` heading in the PR body so the local shepherd completes it. With the tools: read the ticket, comment, file follow-ups with the fixVersion this brief names. Either way, cite the ticket key in your commits and the PR. If the context7 MCP tools are listed in this session, use them for current library docs; otherwise WebFetch the library's own docs.

## Ticket ${t.key} (verbatim from Jira)

${t.raw}

## The change (verified against main on ${date}; line numbers are approximate — find the code by its text)

${change}

Files:
${named}

## How to do it
1. Read \`CLAUDE.md\` and these files in full before editing: ${files.join(' ')}
2. Claim the ticket: if the Atlassian MCP tools are listed, transition ${t.key} to \`In Progress\`; otherwise record "transition ${t.key} to In Progress" for the \`## Jira steps not done\` section (a cloud session has no handover doc and no queue lock; the ticket status is the claim).
3. Create the branch as a worktree BEFORE any edit: \`git worktree add -b ${branch} .claude/worktrees/himmel-${n} origin/main\`, and work inside it (the repo's edit-on-main guard denies edits in the cloud's primary clone, even on a feature branch).
   Run \`bash scripts/cloud/setup-env.sh\` from this worktree before any edit: the environment's setup ran in a throwaway clone, so this installs the git gate hooks here and rebuilds the AST graph and repo-only index. What this VM can and cannot do, with the local split for each gap: \`scripts/lanes/cloud-capabilities.json\`. Query \`graphify query "<question>" --graph graphify-out/graph.json\`, never the unclassified cached /tmp graph. Search with \`bash scripts/lib/qmd-bounded.sh search "<terms>" -c himmel\`, never bare qmd search or a vault collection.
4. Edit ONLY these files: ${files.join(' ')}. Keep the diff minimal and match the surrounding style.
5. Write the new or changed test FIRST and show it RED without the fix, then green. Run \`shellcheck\` on every \`.sh\` file you touch. Report rc and the PASS/FAIL tail of each.
6. Make exactly ONE commit, never amend it. Before pushing, run the impacted suites: \`bash scripts/cr/impacted-suites.sh origin/main..HEAD --shell\` lists every suite that references a changed file, and \`bash scripts/ci/run-shell-tests.sh --impacted origin/main..HEAD\` runs them. A red suite is fixed in a NEW commit, never an amend.

    ${subject}

    <2-4 line body>

    Platforms tested: linux
    Security reviewed: manual — confirm the change only does what the ticket asks and widens no permission or check

7. Push the branch and open a PR to \`main\` titled \`${subject}\`. The body must include a summary, the files changed, the test/shellcheck/impacted-suite results, the line \`cloud-pilot: ${t.key} (console ${o.consoleId ?? 'unknown'})\`, the line \`completes-ticket: ${completes}\` a \`## Jira steps not done\` section listing each Jira step you skipped (write "none" if you did them all), and a \`## Ticket coverage\` section: one line per ask of the ticket, each ending \`done\` or \`deferred → HIMMEL-<n>\`. The asks:

${coverage}

8. Turn on \`/autofix-pr\` for the PR, so you fix your own CI reds and review comments.
9. Do NOT merge, do NOT request reviewers, and do NOT touch any other file.
10. Report (this replaces the handover doc): post ONE top-level PR comment whose first line is \`CLOUD-DONE <your session URL>\` followed by the PR head SHA and the test results, then, if the Atlassian MCP tools are listed, comment on ${t.key} with the PR URL (otherwise add that comment to \`## Jira steps not done\`). Leave the ticket \`In Progress\`: the local shepherd closes it at merge. Once a local shepherd comments on the PR, stop pushing to the branch. If you are blocked on a question, post it instead as a \`CLOUD-BLOCKED <your session URL>\` PR comment (a ${t.key} comment if no PR exists yet and the Atlassian MCP tools are listed; otherwise state the blocker in your final output) and end the session.

When done, print the PR URL, the branch, the commit SHA, and a 3-line summary.
`;
}

export function launchLine(briefPath) {
  const p = /^[\w./+@:-]+$/.test(briefPath) ? briefPath : `'${briefPath.replace(/'/g, `'\\''`)}'`;
  return `konsole --separate -e claude --cloud "$(cat ${p})" --permission-mode auto`;
}

// ---- I/O (CLI only) ----
function primaryCheckout() {
  const common = gitClean(['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: REPO, encoding: 'utf8' }).trim();
  return dirname(common);
}

function fetchTicket(key) {
  const cmd = process.env.CLOUD_ROUTE_JIRA_CMD;
  const [bin, args] = cmd ? [cmd, ['get', key]] : [process.execPath, [join(primaryCheckout(), 'scripts/jira/dist/index.js'), 'get', key]];
  return parseJiraGet(execFileSync(bin, args, { encoding: 'utf8', env: { JIRA_PROJECT_KEY: 'HIMMEL', ...process.env } }));
}

// The file tree at the base: origin/main of the primary checkout, else its HEAD.
function baseTree() {
  const cwd = primaryCheckout();
  for (const ref of ['origin/main', 'HEAD']) {
    try { return gitClean(['ls-tree', '-r', '--name-only', ref], { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).split('\n').filter(Boolean); } catch { /* try the next ref */ }
  }
  throw new Error('git ls-tree failed at origin/main and HEAD');
}

// Can an empty `git log --grep` on this ref show a key is absent? Only when its history is whole and recent: a shallow clone
// stops at its boundary, and a ref last updated more than the window ago lacks every merge since. Either reads as unknown.
const refProof = new Map();
function refProvesAbsence(cwd, ref) {
  const k = `${cwd}\0${ref}`;
  if (!refProof.has(k)) {
    let ok = false;
    try {
      const shallow = gitClean(['rev-parse', '--is-shallow-repository'], { cwd, encoding: 'utf8', timeout: 60000 }).trim();
      const tip = Number(gitClean(['log', '-1', '--format=%ct', ref], { cwd, encoding: 'utf8', timeout: 60000 }).trim());
      ok = shallow === 'false' && Number.isFinite(tip) && Date.now() / 1000 - tip <= STALE_DAYS * 86400;
    } catch { ok = false; }
    refProof.set(k, ok);
  }
  return refProof.get(k);
}

// Does the local main ref carry a commit whose message (subject and body, a squash merge keeps the PR body) names the key?
// true; false when it does not and the ref's history can show that; null when it cannot be told (no such ref, git failed or
// timed out, a shallow or stale ref with no match). A superset screen: a short key also
// matches a longer one, which only costs one search that the cites test then filters.
function citedOnMain(key) {
  try {
    const cwd = process.env.CLOUD_ROUTE_GIT_DIR || primaryCheckout();
    const ref = process.env.CLOUD_ROUTE_MAIN_REF || 'origin/main';
    if (gitClean(['log', ref, '--fixed-strings', `--grep=${key}`, '-1', '--format=%h'], { cwd, encoding: 'utf8', timeout: 60000 }).trim() !== '') return true;
    return refProvesAbsence(cwd, ref) ? false : null;
  } catch { return null; }
}

// One shared list of PRs merged since STALE_DAYS ago (the file-overlap rule) plus one
// search per ticket (PRs citing the key, any age), through the same gh the open-PR list
// uses. Deduplicated by number. Returns { prs, truncated }.
// The per-ticket search was the dispatcher's largest GraphQL cost, so a key no commit on the local main ref
// names is not searched. Fails closed: a local answer of unknown (null) still searches. What a lagging ref can hide is a
// merge of the last STALE_DAYS, and the shared window list above reads exactly those from GitHub, so only the key search
// is skipped, never the window.
// ponytail: a PR older than the window whose body gained the key after it merged (the squash message never held it) is not found, upgrade path: an indexed key-to-PR map filled once per merge
// A key whose search fills the page is `truncated`: that ticket alone is BLOCKED, the other tickets of the run still classify.
function mergedPrs(keys) {
  const gh = process.env.CLOUD_ROUTE_GH_CMD || 'gh';
  const run = (extra) => JSON.parse(execFileSync(gh, ['pr', 'list', '--repo', REPO_SLUG, '--state', 'merged', '--json', 'number,title,body,mergedAt,files', ...extra], { encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 * 1024 }) || '[]');
  const since = new Date(Date.now() - STALE_DAYS * 86400e3).toISOString().slice(0, 10);
  const all = new Map();
  const truncated = new Set();
  // ponytail: the file-overlap window reads at most 200 PRs, so a busier fortnight can hide an overlap, upgrade path: paginate or search per file
  for (const pr of run(['--limit', '200', '--search', `merged:>=${since}`])) all.set(pr.number, pr);
  for (const k of keys) {
    if (citedOnMain(k) === false) continue;
    const hits = run(['--limit', String(MERGED_PAGE), '--search', `${k} in:title,body`]);
    if (hits.length >= MERGED_PAGE) truncated.add(k);
    for (const pr of hits) all.set(pr.number, pr);
  }
  return { prs: [...all.values()], truncated };
}

function main(argv) {
  const opt = { bucket: null, console: null, held: null, spec: null, classifyOnly: false };
  const keys = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--bucket') opt.bucket = argv[++i];
    else if (a === '--chief') opt.console = argv[++i];
    else if (a === '--held') opt.held = argv[++i];
    else if (a === '--spec') opt.spec = argv[++i];
    else if (a === '--classify-only') opt.classifyOnly = true;
    else if (a.startsWith('-')) {
      process.stderr.write(`unknown option: ${a}\n`);
      return 2;
    } else keys.push(a);
  }
  if (!keys.length || (!opt.classifyOnly && (!opt.bucket || !opt.console))) {
    process.stderr.write('usage: cloud-route.mjs [--classify-only] --bucket <dir> --chief <id> [--held <file>] [--spec <json>] HIMMEL-<n>...\n');
    return 2;
  }
  const spec = opt.spec ? JSON.parse(readFileSync(opt.spec, 'utf8')) : {};
  const held = opt.held ? readFileSync(opt.held, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean).map((file) => ({ file, why: 'chief held list' })) : [];
  let merged = [];
  let mergedUnknown = false;
  let mergedTruncated = new Set();
  try { ({ prs: merged, truncated: mergedTruncated } = mergedPrs(keys)); } catch (e) { mergedUnknown = true; process.stderr.write(`cloud-route: gh failed, merged PRs unknown — ${e.message.split('\n')[0]}\n`); }
  let tree = [];
  let treeUnknown = false;
  try { tree = baseTree(); } catch (e) { treeUnknown = true; process.stderr.write(`cloud-route: git failed, file tree unknown — ${e.message.split('\n')[0]}\n`); }
  const ctx = { trust: loadTrust(), held, merged, mergedUnknown, mergedTruncated, tree, treeUnknown };
  const date = new Date().toISOString().slice(0, 10);
  const launches = [];
  if (!opt.classifyOnly) mkdirSync(opt.bucket, { recursive: true });

  for (const key of keys) {
    const s = spec[key] ?? {};
    const t = { ...fetchTicket(key), ...(s.files ? { files: s.files } : {}), ...(s.created ? { created: s.created } : {}) };
    const v = classifyTicket(t, ctx);
    process.stdout.write(`${key}\t${v.class}\t${v.reason}\n`);
    if (v.class === 'CLOUD-OK') held.push(...v.files.map((file) => ({ file, why: `routed ${key} this run` })));
    let brief = null;
    if (!opt.classifyOnly) {
      if (v.class === 'CLOUD-OK') {
        brief = join(resolve(opt.bucket), `cloud-brief-${key}.md`);
        const exists = (f) => existsSync(join(REPO, f));
        writeFileSync(brief, buildBrief({ ...t, files: v.files }, { consoleId: opt.console, date, exists, change: s.change, branchType: s.branchType, completes: s.completes }));
        launches.push(launchLine(brief));
      }
      appendFileSync(join(opt.bucket, 'cloud-route.jsonl'), JSON.stringify({ ticket: key, class: v.class, reason: v.reason, files: v.files, brief, time: new Date().toISOString() }) + '\n');
    }
  }
  if (launches.length) process.stdout.write(`\nOperator launch lines (run each in your terminal; this tool never launches):\n${launches.join('\n')}\n`);
  return 0;
}

if (process.argv[1]?.endsWith('cloud-route.mjs')) {
  try { process.exit(main(process.argv.slice(2))); }
  catch (e) { process.stderr.write(`cloud-route: ${e.message}\n`); process.exit(1); }
}
