#!/usr/bin/env bash
# next-dispatchable.sh — Ranked, collision-checked list of the next
# tickets a chief can dispatch. READ-ONLY: it prints, it never launches,
# creates a worktree or writes the mirror. chief-wait.sh prints it with the
# `WAKE underfilled` block; a chief can also run it by hand. It absorbs the
# spare-capacity suggestion it replaced.
#
#   next-dispatchable.sh [--top N] [--mirror DIR] [--workers-from MANIFEST]
#                        [--held FILE] [--no-classify] [--doc CHIEF_DOC]
#                        [--priority-pool-only] [--workers-dir DIR] [--why] [--dispositions]
#
# Source: the Jira mirror (`jira ... mirror`, one <KEY>.md per issue). A
# candidate is a To Do issue that is not an Epic/Sub-task, has no contract=yes
# merge row in status-events.jsonl (merged to Done, the mirror lags), carries none of
# the operator-decision / blocked labels (EXCLUDE_LABELS) and has no unresolved
# blocked_by link. Rank: earliest unreleased fixVersion (HIMMEL.versions.tsv,
# natural order; none last), then priority, then key.
#
# Tiers (the first that applies; tier_of() in the script): 1 the operator pool
# head: label ps3-blocker / must-v1.1.3, or a key on the ordered `priority:` line
# in --doc's `## Live state` (line order ranks within the tier, labelled-only
# tickets after the listed ones; groups split by `|`; a token that is not a key,
# like K1, is skipped; a key marked `(CLOUD)` is dropped from the output); 2 label
# operator-directed; 3 a Bug of High or above, or a security / data-integrity /
# data-loss label; 4 the rest of the earliest unreleased version (so with an empty or
# stale `priority:` line every unblocked To Do ticket of that version is still in the
# pool); 5 later or versionless work, by the rank above. --priority-pool-only prints
# tiers 1-4 only: per tier, the RESUME rows (In Progress / In Review / IN CI, no worker, no open PR)
# lead that tier's To Do rows, filtered like To Do rows (dropped platform, residual depth);
# the RESUME rows need a worker source (--owners or --workers-from, plus the cloud-sessions.tsv
# next to --doc, 48h) and print none without one. It ends with `# pool=<rows>/<top>`,
# `,LOW` when the pool printed fewer rows than --top (the free-slot count); open tickets with no fixVersion
# that are operator-directed, a Bug of High or above, labelled scope-<earliest version> or proposed-<earliest version> (a ticket proposed to any other version or the backlog has its INTAKE queued and is excluded), or held by a worker or
# open PR make it `,INTAKE:<m>` instead (never a bare LOW) plus a `# intake <m> for <version>: <keys>` line (`# intake <m>: <keys>` with no open version; --dispositions prints it too, for the tick's INTAKE=); an empty
# pool prints `POOL-EMPTY` and then the tier-5 To Do rows as `NEXT-TIER` rows (rank
# order, unclassified, collision-checked against held files), never dispatched from here.
#
# Residual depth: a ticket labelled residual-depth-<n> (n >= 1) is a judge, CR or
# panel residual and is excluded unless --doc records `residual-must <KEY>` on a
# line of its own, bare or as an append-results bullet (`- HH:MM residual-must <KEY>`) (security, data loss or a broken operator flow only), or the
# admissions ledger (HIMMEL_ADMISSIONS_LEDGER, else <handover root>/admissions-ledger.jsonl)
# admitted it into the earliest unreleased version: its latest row there is an
# `rm-admit` or `override` row (any other kind, or none, admits nothing). No label
# means depth 0.
#
# IN CI tickets: one nobody holds (no worker, no open PR) that a merged PR cites prints a
# `MERGED-NOT-CLOSED` row (same columns as RESUME, nothing to dispatch: it needs closing);
# with no PR at all it is a RESUME row. An unreadable merged-PR search prints a
# `merged PRs unknown` header and no IN CI row.
#
# Held RESUME rows: an in-work ticket a file collision keeps off the list prints
# `RESUME-HELD <KEY> by <holder>` (a live worker, the --held list, an open PR, or `listed <KEY>`
# for another RESUME row; the last in the full pass only), so no in-work ticket vanishes unnamed.
# A DISPOSITION ... BLOCKED-BY comment hides nothing here: stuck-scan.sh re-checks it.
#
# DESIGN rows (only with the core_gate flag on; off, the default, runs nothing and changes no line):
# the built jira CLI (`release core-check`, then `release spec-check` for the core keys; NEXT_DISPATCH_JIRA_CLI replaces
# its path) says which To Do candidates are core. A core one with no signed minerva spec prints
# `DESIGN<TAB><KEY><TAB>NO-SPEC|SPEC-STALE<TAB>prio<TAB>version<TAB>title<TAB>files=...` instead of a dispatch row: it takes a
# --top slot, holds no files, and is the design leg to dispatch first. A key the mirror lacks is withheld
# (`# drop <KEY> core-unknown`); a check that cannot run lists no To Do row and prints `# WARN CORE-CHECK-FAILED <reason>`.
#
# Chain workers: with --workers-from naming a `<prefix>-nextleg-<date><letter>-<name>.fleet.json`,
# the other manifests of that chain in the same directory (same prefix and name, any letter) also own their live
# workers' tickets, so a worker the other chief armed after `chief.sh next` copied the manifest is not offered
# again. Ownership of the ticket only: a doc that is missing, WRAPPED, or untouched for
# NEXT_DISPATCH_SIBLING_MAX_AGE_MIN (default 1440) holds nothing, and an unreadable sibling never marks the fleet unknown.
#
# Wrapped tickets: a To Do ticket whose worker record (--workers-dir, default
# $TICKET_STATUS_STATE_DIR/workers or ~/.himmel/state/workers) is in state wrapped
# with a resume_brief is a RESUME row carrying `brief=<path>`, filtered like the
# In Progress / In Review RESUME rows, and is never an ordinary To Do row. A
# ticket with a contract=yes merge row in the status-events.jsonl beside that dir
# (its Done write is pending) is never a RESUME row.
#
# Collision (one writer per file): the files a candidate names in its
# description are checked against (a) the files in the live workers' docs (the
# manifest's `workers[].doc`, scope lines), (b) the diff of every open PR (gh), and
# (c) --held FILE (one path per line). A directory a ticket names is context and
# collides with nothing. Any other path collides with an equal held path; a concrete
# file (one the repo holds, or a new one with a dotted basename) also collides with a
# directory a worker's write scope or --held names above it; an open PR's diff is files,
# compared exactly. Two listed tickets collide on an equal file only. A live worker's write
# scope is the path list after `writes confined to` up to its first sentence break (a
# `> **Writes:**` line is all of it); past the break only a concrete file holds, so a
# directory the brief merely mentions holds nothing. Paths compare after the rename registry
# (scripts/lib/rename-aliases.tsv, kind directory) maps a pre-rename spelling to its new one.
# An open PR's files come from the paginated files API (`gh api --paginate`, filename and
# previous_filename), one PR at a time: a PR whose read fails (HTTP 406 over 300 files by
# `gh pr diff`, a timeout, the API's 3000-file cap) is named in an `open PR files unknown`
# header, the other PRs still hold their files, and no RESUME or IN CI row is listed (the
# unread PR could own it). When the PR list itself fails the list is printed with an
# `open PRs unknown` header rather than silently trusting an empty set.
#
# Soft edges: a candidate held only by open PRs is not dropped for the file collision when the overlap is
# small and merges clean: every holder is an open PR, the overlap is at most 2 files, none is
# a ci-trust path, and each holder's head merges into main with `git merge-tree` without a
# conflict. Such a ticket is listed, preceded by a `# SOFT <holders> <files> for <KEY>` line.
#
# Series ledgers (stacked_series only): each ledger under the --workers-from manifest's `series/` directory, read through
# chief-kit/series-ledger.py read, holds every non-abandoned item's writes as `series <sid>`, so the files stay held
# between a predecessor's WRAPPED and its successor's launch. A published item stops holding once gh reports every PR of its
# publish_branch merged or closed. A ledger whose writer doc has no LIVE bullet and no manifest entry 2 h after the newest
# pass (a series with no pass: after the ledger's last write) prints `SERIES-ORPHAN <sid> <writer doc>`. With the flag off
# the ledgers are not read and the output is as without them.
#
# Drops: every To Do ticket of the earliest unreleased version that is not listed
# is counted by reason on a `# dropped from <version>:` line (owned, collision,
# blocker, type, label, platform, residual-depth, classification, below --top ...);
# --why adds one `# drop <KEY> <reason>` line each, the collision naming the file and
# its holder. --dispositions adds `# disposition <KEY> <class> <holder, blocker or question>`
# for EVERY open ticket of that version (To Do or in work), listed ones too (`listed LOCAL`,
# `listed RESUME`), so no ticket is silent. --resume-only prints neither.
#
# Blockers: the mirror lags in both directions, so every hard blocker of a candidate is read
# live once, bounded. A blocker the mirror shows open but live Done no longer drops the ticket;
# one live open is named `blocker KEY (<status>, live)`, or `blocker KEY (reopened live)` when
# the mirror says Done. The live read runs with the real classifier, or when
# NEXT_DISPATCH_JIRA_CMD is set; a read that fails or times out (a blocker with no mirror file
# too) drops the ticket as `blocker-unknown KEY`, never clears it. With the live read off the
# mirror is the only word. The output opens with `# source mirror_age_min=<n>` (minutes since
# the mirror's newest file changed). A classifier
# BLOCKED is never lifted: the drop carries its reason, and a ticket naming a directory with a
# held file in it is BLOCKED naming that file's holder. While any open PR's files are unreadable
# no To Do row is listed: a false free is worse than a short list.
#
# Classification: the survivors go through scripts/lanes/cloud-route.mjs
# --classify-only (the same gates as /cloud-route). CLOUD-OK prints CLOUD;
# LOCAL-NATIVE prints LOCAL; HOOK-BYPASS prints LOCAL with `hook` (the worker needs
# the hook-integrity bypass launch); BLOCKED is dropped. --no-classify prints
# every survivor as LOCAL? (no Jira or gh read for the class).
#
# Output, one line per ticket, tab-separated:
#   <LOCAL|CLOUD> <KEY> <priority> <fixVersion|-> <title> files=<a,b|->  [hook]
#
# Env (tests): NEXT_DISPATCH_MIRROR, NEXT_DISPATCH_GH_CMD (replaces `gh`),
# NEXT_DISPATCH_CLASSIFY_CMD (replaces cloud-route.mjs; called with the keys),
# NEXT_DISPATCH_JIRA_CMD (replaces the jira CLI for the live blocker read; called `get KEY`),
# NEXT_DISPATCH_EXCLUDE_LABELS (comma list, replaces the default).
#
# Exit: 0 printed (possibly nothing); 2 usage; 3 the mirror directory is missing or unreadable.
# PLATFORM GUARD: the chief kit is Linux-only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

top=8; mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
workers_from="${WORKERS_FROM:-}"; held=""; classify=1; resume_only=0; owners=""; doc=""; pool_only=0; why=0; dispo=0
workers="${TICKET_STATUS_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/workers"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --workers-dir) workers="${2:-}"; shift 2 || exit 2 ;;
        --resume-only) resume_only=1; classify=0; shift ;;
        --owners) owners="${2:-}"; shift 2 || exit 2 ;;
        --top) top="${2:-}"; shift 2 || exit 2 ;;
        --mirror) mirror="${2:-}"; shift 2 || exit 2 ;;
        --workers-from) workers_from="${2:-}"; shift 2 || exit 2 ;;
        --held) held="${2:-}"; shift 2 || exit 2 ;;
        --no-classify) classify=0; shift ;;
        --doc) doc="${2:-}"; shift 2 || exit 2 ;;
        --priority-pool-only) pool_only=1; shift ;;
        --why) why=1; shift ;;
        --dispositions) dispo=1; shift ;;
        *) echo "usage: next-dispatchable.sh [--top N] [--mirror DIR] [--workers-from MANIFEST] [--held FILE] [--no-classify] [--doc CHIEF_DOC] [--priority-pool-only] [--resume-only] [--owners \"KEY ...\"] [--workers-dir DIR] [--why] [--dispositions]" >&2; exit 2 ;;
    esac
done
case "$top" in ''|*[!0-9]*|0*) echo "next-dispatchable: --top needs a positive number" >&2; exit 2 ;; esac
ledger="${HIMMEL_ADMISSIONS_LEDGER:-}"
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if [ -z "$ledger" ] && . "$REPO/scripts/lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi  # swallow-ok: handover_root reads only the live env, so feed it the .env value first; no .env means the inline default
if [ -z "$ledger" ] && . "$REPO/scripts/lib/handover-path.sh" 2>/dev/null; then
    root="$(handover_root 2>/dev/null)" && ledger="$root/admissions-ledger.jsonl"  # swallow-ok: no handover root means no ledger, so no residual is admitted by it
fi

stacked=0
# shellcheck source=scripts/lib/flags.sh
# shellcheck disable=SC1091
if . "$REPO/scripts/lib/flags.sh" 2>/dev/null && himmel_flag stacked_series 2>/dev/null; then stacked=1; fi  # swallow-ok: an unreadable registry or bad value reads as off, which is today's output
export ND_STACKED="$stacked"
core_gate=0
if . "$REPO/scripts/lib/flags.sh" 2>/dev/null && himmel_flag core_gate 2>/dev/null; then core_gate=1; fi  # swallow-ok: an unreadable registry or bad value reads as off, which is today's output
export ND_CORE_GATE="$core_gate"
export ND_GIT_DIR="${NEXT_DISPATCH_GIT_DIR:-$REPO}" ND_MAIN_REF="${NEXT_DISPATCH_MAIN_REF:-origin/main}"
export ND_TOP="$top" ND_MIRROR="$mirror" ND_WORKERS_FROM="$workers_from" ND_HELD="$held" ND_CLASSIFY="$classify" ND_REPO="$REPO" ND_RESUME_ONLY="$resume_only" ND_OWNERS="$owners" ND_DOC="$doc" ND_POOL_ONLY="$pool_only" ND_WORKERS="$workers" ND_WHY="$why" ND_DISPO="$dispo" ND_LEDGER="$ledger"
exec python3 -I - <<'PY'
import datetime, json, os, re, subprocess, sys, tempfile, time

top = int(os.environ['ND_TOP']); mirror = os.environ['ND_MIRROR']
repo = os.environ['ND_REPO']
sys.path.insert(0, os.path.join(repo, 'scripts', 'lib'))
from env_alias import legacy_names_on


def manifest_workers(m):
    """The manifest's worker array: `workers`, else the pre-rename `legs` while legacy names are on.
    A legs-only manifest with legacy names off is unreadable (ValueError), never an empty fleet."""
    w = m.get('workers')
    if w is None and 'legs' in m and not legacy_names_on():
        raise ValueError('fleet manifest carries the pre-rename legs array and the legacy-names switch is off')
    if w is None:
        w = m.get('legs')
    return w or []

excl = set(filter(None, os.environ.get('NEXT_DISPATCH_EXCLUDE_LABELS',
    'operator-decision,operator,operator-present,operator-gated,blocked,decision,windows-parked,design-deferred,placeholder,held').split(',')))
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)")
PRIO = {'Highest': 0, 'Blocker': 0, 'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3, 'Lowest': 4}

def files_in(text):
    out = []
    for m in FILE_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and not f.endswith('/') and os.path.isdir(os.path.join(repo, f)):
            f += '/'  # a directory keeps its slash, whatever punctuation followed it in the text
        if f and f not in out:
            out.append(f)
    return out

MARKER_RE = re.compile(r'^- \d{1,2}:\d{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED)\b')
SCOPE_END_RE = re.compile(r'completes-ticket:|Other live workers|Touch nothing|READ ONLY|READ-ONLY|Stay off')

# read-only text an older scope line carries. Stripping fails open (a dropped path is a write nobody holds), so each
# pattern removes only what is unmistakably read-only: a backticked command, a command with a flag, an impacted-suites
# list, a trust-path note, a single-writer note that names ANOTHER holder
SENT = r'(?:[^.]|\.(?!\s|$))*(?:\.(?=\s)|$)'
Q = r'''(?:'[^']*'|"[^"]*")'''
ARG = r'''[^\s`;,)'"]*[/.\d_-][^\s`;,)'"]*(?<![.])'''
CMD_SPAN_RE = re.compile(r'`(?:git grep|grep|rg|find|sed -n|cat)\b[^`]*`')
CMD_BARE_RE = re.compile(r'(?<![\w./-])(?:(?:git grep|grep|rg|find|cat)(?=(?:\s+(?:%s|(?!-)%s))*\s+-\w)|sed\s+-n)(?:\s+(?:-{1,2}\w[\w=.-]*(?:\s+(?!(?:in|to|from|for|the|a|an|and|or|of|on|at|with|by)\b)\w+(?![\w./-]))?|%s|%s))+' % (Q, ARG, Q, ARG))  # a command word with a flag, never a name inside a path
CMD_PAREN_RE = re.compile(r'\((?:git grep|grep|rg|find|cat)\b(?:(?!\b(?:fix|edit|update|change|write|add|patch|replace|rename)\b)[^)])*\)')  # "(find what x uses)": a read aside, unless it says to change something
WRITING_RE = re.compile(r'\s-(?:delete|exec|execdir|ok)\b')  # a find that deletes or runs a command is not a read
IMPACTED_RE = re.compile(r'Impacted suites' + SENT)
SINGLE_WRITER_RE = re.compile(r'SINGLE-WRITER' + SENT)
OTHER_HOLDER_RE = re.compile(r'#\d+|\bN\d{3,}\b')
OWN_WRITER_RE = re.compile(r'\bthis worker\b|\b(?:the )?(?:one|sole|only) writer\b', re.I)
TRUST_RE = re.compile(r'Trust path\s*\([^)]*\)')
WRITES_LEAD = '> **Writes:**'
SERIES_LEAD = '> **Series:**'
SERIES_ITEM_RE = re.compile(r'(?<![\w.-])\d+\.\s+([A-Z]+-\d+)')  # "1. HIMMEL-9 branch=..." one item of a series worker's block
SERIES_ID_RE = re.compile(r'(?!\d+\.\s)(\S+)\s+(\S+)')  # "<sid> <ledger path> - read ...": what follows the lead on the Series line S2a writes
SERIES_CAP = 4
stacked = os.environ.get('ND_STACKED') == '1'  # the stacked_series flag, read by the shell wrapper

def clean_scope(rest):
    m = SCOPE_END_RE.search(rest)
    rest = rest[:m.start()] if m else rest
    rest = re.sub(r'(?i:(?:Do not|Never) (?:touch|edit|change))\b' + SENT, ' ', rest)  # a fence, not a write scope
    rest = re.sub(r'Touches\s+(?:[\w.+@-]+/)+,\s+an?\s+ci-trust-paths pattern\b', ' ', rest)  # "Touches scripts/ci/, a ci-trust-paths pattern" is READY boilerplate, not a held tree
    rest = IMPACTED_RE.sub(' ', rest)
    rest = TRUST_RE.sub(' ', rest)
    rest = SINGLE_WRITER_RE.sub(lambda g: ' ' if OTHER_HOLDER_RE.search(g.group(0)) and not OWN_WRITER_RE.search(g.group(0)) else g.group(0), rest)  # "SINGLE-WRITER: PR #n owns x" is another holder's; "this worker is the one writer of y" is ours, even when it also names a PR
    for rx in (CMD_SPAN_RE, CMD_PAREN_RE, CMD_BARE_RE):  # a path a quoted read-only command searches is not written
        rest = rx.sub(lambda g: g.group(0) if WRITING_RE.search(g.group(0)) else ' ', rest)
    # "dir/ (a.sh, sub/b.sh)" names those files, not the whole dir; prose in the parentheses keeps the dir
    def expand(g):
        parts = [p.strip() for p in g.group(2).split(',')]
        if all(re.fullmatch(r'[\w.+@/-]+\.\w+', p) for p in parts):
            return ' '.join(g.group(1) + p for p in parts)
        return g.group(1)
    return re.sub(r'((?:[\w.+@-]+/)+)\s*\(([^)]*)\)', expand, rest)

SENT_BREAK_RE = re.compile(r'(?<!\d)(?<!e\.g)(?<!i\.e)\.(?=\s|$)')  # the end of a sentence, not a list number or a dot inside a path

def write_scope(line):
    # the worker's own write scope: its "> **Writes:**" line, else (older briefs) after "writes confined to" / "Scope / do not:", up to the boilerplate that follows
    if line.startswith('> **Writes note:**'):
        return ''
    if line.startswith(WRITES_LEAD):
        text = line[len(WRITES_LEAD):]
        while re.search(r'\([^()]*\)', text):
            text = re.sub(r'\([^()]*\)', ' ', text)
        return text
    for lead in ('writes confined to', 'Scope / do not:'):
        if lead in line:
            return clean_scope(line.split(lead, 1)[1])
    return ''

def scope_paths(line):
    # the paths a worker holds. The "writes confined to" list (up to its first sentence break) holds whatever it names, a
    # directory included; a path named later on the line holds only when it is a concrete file, since a directory a
    # brief mentions there ("grep scripts/ci", "N3185 is the single writer in scripts/config-ui/") is context
    text = write_scope(line)
    # ponytail: the list ends at its first sentence break, so a path after a mid-list "." reads as later prose and holds only when concrete, upgrade path: end the list at the next heading
    m = SENT_BREAK_RE.search(text) if not line.startswith(WRITES_LEAD) and 'writes confined to' in line else None
    inside, outside = (text[:m.start()], text[m.end():]) if m else (text, '')
    later = [s for s in SENT_BREAK_RE.split(outside)]
    return files_in(inside) + [f for s in later for f in files_in(s) if concrete(f) or WRITING_RE.search(s)]  # a later sentence that deletes or runs a command writes its directory too

renames = []
try:
    for rline in open(os.path.join(repo, 'scripts/lib/rename-aliases.tsv'), encoding='utf-8', errors='replace'):
        cols = rline.rstrip('\n').split('\t')
        if len(cols) >= 3 and cols[2] == 'directory' and not rline.startswith('#') and cols[0].strip() and cols[1].strip():
            renames.append((cols[0].strip().rstrip('/'), cols[1].strip().rstrip('/')))
except OSError:
    pass  # swallow-ok: no registry means no rename is resolved, so a pre-rename path compares as written

def canon(p):
    # a path as the rename registry spells it now: a stale pre-rename path and its new spelling are one path
    slash = p.endswith('/')
    t = p.rstrip('/')
    for _ in range(3):
        for old, new in renames:
            if t == old or t.startswith(old + '/'):
                t = new + t[len(old):]
                break
        else:
            break
    return t + ('/' if slash else '')

def concrete(f):
    # a file, not a tree: a directory a ticket names is context and holds nothing
    if f.endswith('/'):
        return False
    p = os.path.join(repo, canon(f))
    return os.path.isfile(p) or (not os.path.exists(p) and '.' in os.path.basename(f))

def blocks(f, h, tree):
    # a candidate's concrete file is held by an equal path, or by a tree (a live worker's write scope, --held)
    f = canon(f)
    h = canon(h).rstrip('/')
    if f == h:
        return not os.path.isdir(os.path.join(repo, f))
    return tree and concrete(f) and f.startswith(h + '/')

def held_hit(i):
    # the first (file, holder) of held that holds one of the ticket's files, else None
    for f in i['files']:
        for h, who, tree in held:
            if blocks(f, h, tree):
                return f, who
    return None

def held_hits(i):
    # every (file, holder) of held that holds one of the ticket's files
    return [(f, who) for f in i['files'] for h, who, tree in held if blocks(f, h, tree)]

soft_rows = {}  # key -> the `# SOFT` text of a listed ticket whose file overlap is soft
trust_res = []
for tf in ('scripts/ci/ci-trust-paths.txt', 'scripts/ci/ci-trust-paths-core.txt'):
    try:
        trust_res += [re.compile(l.strip()) for l in open(os.path.join(repo, tf), encoding='utf-8') if l.strip() and not l.lstrip().startswith('#')]
    except (OSError, re.error):
        trust_res = None  # swallow-ok: an unreadable or invalid trust list makes every overlap hard
        break
head_cache = {}

def trial_clean(num):
    # the open PR's head merges into main with no conflict (git merge-tree, no worktree). The candidate has
    # no branch yet, so this is the holder's side of the pair; a conflict found later upgrades the edge to hard.
    if num not in head_cache:
        ok = False
        gitdir, mainref = os.environ['ND_GIT_DIR'], os.environ['ND_MAIN_REF']
        try:
            sha = subprocess.run([gh, 'api', 'repos/%s/pulls/%s' % (gh_repo, num), '--jq', '.head.sha'], capture_output=True, text=True, timeout=60, check=True).stdout.strip()
            if re.fullmatch(r'[0-9a-f]{40,64}', sha):
                have = lambda: subprocess.run(['git', '-C', gitdir, 'cat-file', '-e', sha + '^{commit}'], capture_output=True, timeout=60).returncode == 0
                if not have():
                    subprocess.run(['git', '-C', gitdir, 'fetch', '-q', 'origin', 'refs/pull/%s/head' % num], capture_output=True, timeout=120)
                if have() and subprocess.run(['git', '-C', gitdir, 'rev-parse', '--verify', '-q', mainref + '^{commit}'], capture_output=True, timeout=60).returncode == 0:
                    ok = subprocess.run(['git', '-C', gitdir, 'merge-tree', '--write-tree', '--no-messages', mainref, sha], capture_output=True, timeout=60).returncode == 0
        except (OSError, subprocess.SubprocessError):
            ok = False  # swallow-ok: a trial that cannot run is not clean, so the collision drop stands
        head_cache[num] = ok
    return head_cache[num]

def soft_overlap(i, hits):
    # the `# SOFT` text when every overlap is with an open PR, there are at most 2 files, none is a trust
    # path and each holder's trial merge is clean; else None and the collision drop stands
    if trust_res is None or not trust_res or not hits:
        return None
    files = sorted({f for f, _ in hits})
    holders = sorted({who for _, who in hits})
    if len(files) > 2 or not all(w.startswith('open PR ') for w in holders):
        return None
    if any(r.search(canon(f)) for f in files for r in trust_res):
        return None
    if not all(trial_clean(w.split()[-1]) for w in holders):
        return None
    return '%s %s' % (','.join(holders), ','.join(files))

def fm_val(fm, name):
    m = re.search(r'^%s: (.*)$' % re.escape(name), fm, re.M)
    return m.group(1).strip() if m else ''

def unq(v):
    return v.strip().strip('"')

OWED_RE = re.compile(r'stays open|still open|owed|must-fix|remaining slice|next slice', re.I)

def last_owed(body):
    # the last comment line that says work remains; '' when there is none
    i = body.find('\n## Comments')
    hit = ''
    for line in (body[i:].splitlines() if i >= 0 else []):
        if OWED_RE.search(line):
            hit = line.strip()
    return hit[:160]

issues = {}
try:
    names = sorted(n for n in os.listdir(mirror) if re.match(r'^[A-Z]+-\d+\.md$', n))
except OSError as e:
    print('# next-dispatchable: mirror missing or unreadable (%s)' % e, file=sys.stderr); sys.exit(3)  # an error, never an empty pool
try:
    mirror_age_min = int((time.time() - max([os.path.getmtime(os.path.join(mirror, n)) for n in names] or [os.path.getmtime(mirror)])) // 60)
except OSError:
    mirror_age_min = -1  # swallow-ok: a file that vanished between the listing and the stat leaves the age unknown, shown as -1
print('# source mirror_age_min=%d' % mirror_age_min)  # first on stdout, ahead of every warning
for n in names:
    try:
        txt = open(os.path.join(mirror, n), encoding='utf-8', errors='replace').read()
    except OSError as e:
        print('# next-dispatchable: mirror missing or unreadable (%s)' % e, file=sys.stderr); sys.exit(3)  # a listed file that cannot be read is the same error
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S)
    if not m:
        continue
    fm, body = m.groups()
    key = unq(fm_val(fm, 'key'))
    t = re.search(r'^# [A-Z]+-\d+: (.*)$', body, re.M)
    issues[key] = {
        'key': key, 'type': unq(fm_val(fm, 'type')), 'status': unq(fm_val(fm, 'status')), 'cat': unq(fm_val(fm, 'statusCategory')),
        'prio': unq(fm_val(fm, 'priority')), 'parent': unq(fm_val(fm, 'parent')).replace('null', ''), 'labels': set(re.findall(r'"([^"]+)"', fm_val(fm, 'labels'))),
        'ver': re.findall(r'"([^"]+)"', fm_val(fm, 'fixVersions')),
        'blocked_by': re.findall(r'[A-Z]+-\d+', re.search(r'blocked_by: (.*)', fm).group(1)) if re.search(r'blocked_by: (.*)', fm) else [],
        'title': t.group(1).strip() if t else '', 'files': files_in(body),
        'last': last_owed(body),
    }

# unreleased versions in natural order
vorder = {}
vf = mirror.rstrip('/') + '.versions.tsv'
if os.path.exists(vf):
    def nat(v): return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', v)]
    vs = []
    for line in open(vf, encoding='utf-8', errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2 and p[1].strip() == 'false' and not (len(p) >= 4 and p[3].strip() == 'true') and not p[0].startswith('zz-'):
            vs.append(p[0])
    for i, v in enumerate(sorted(vs, key=nat)):
        vorder[v] = i

first_ver = min(vorder, key=vorder.get) if vorder else None

def rank(i):
    vers = [vorder[v] for v in i['ver'] if v in vorder]
    return (min(vers) if vers else 10**6, PRIO.get(i['prio'], 5), int(i['key'].split('-')[1]))

# The operator's ordered `priority:` line, from the `## Live state` section of the chief doc.
def read_priority_line(path):
    order, cloud = {}, set()
    if not path:
        return order, cloud
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return order, cloud
    in_state = False
    for line in lines:
        if line.startswith('## '):
            in_state = line.strip() == '## Live state'
        m = re.match(r'^\s*(?:[-*]\s+)?(?:\*\*)?priority:(?:\*\*)?\s*(.*)$', line) if in_state else None
        if m:
            # Outside (...) or [...] every bare number that is not part of a dotted number is a key; inside, only HIMMEL-NNNN or a number
            # from a `+` to the closing paren. `NNN (CLOUD)` marks NNN cloud-only.
            depth, plus = 0, False
            for t in re.finditer(r'([(\[])|([)\]])|(\+)|(?<![\w.-])(HIMMEL-)?(\d{3,5})(?![\w-]|\.\d)(\s*\(CLOUD\))?', m.group(1)):
                if t.group(1):
                    depth += 1
                elif t.group(2):
                    depth, plus = max(depth - 1, 0), False
                elif t.group(3):
                    plus = plus or depth > 0
                elif depth == 0 or plus or t.group(4):
                    key = 'HIMMEL-' + t.group(5)
                    order.setdefault(key, len(order))
                    if t.group(6):
                        cloud.add(key)
            break
    return order, cloud

prio_order, prio_cloud = read_priority_line(os.environ.get('ND_DOC', ''))
TIER1_LABELS = {'ps3-blocker', 'must-v1.1.3'}
TIER3_LABELS = {'security', 'data-integrity', 'data-loss'}

def residual_depth(i):
    ds = [int(m.group(1)) for l in i['labels'] for m in [re.match(r'^residual-depth-(\d+)$', l)] if m]
    return max(ds) if ds else 0

def read_residual_must(path):
    keys = set()
    try:
        for line in open(path, encoding='utf-8', errors='replace'):
            m = re.match(r'^\s*(?:[-*]\s+)?(?:\d{1,2}:\d{2}\s+)?residual-must\s+(?:HIMMEL-)?(\d{3,5})\b', line)
            if m:
                keys.add('HIMMEL-' + m.group(1))
    except OSError:
        pass
    return keys

residual_must = read_residual_must(os.environ['ND_DOC']) if os.environ.get('ND_DOC') else set()

def read_admitted(path, ver):
    # the admissions ledger: a key whose latest row for the version is an override or an rm-admit
    # was admitted into it; a deferral, an unknown kind or a kind-less intake row was not
    last = {}
    try:
        for line in open(path, encoding='utf-8', errors='replace'):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get('version') == ver and r.get('key'):
                last[str(r['key']).upper()] = r.get('kind')
    except OSError:
        pass
    return {k for k, kind in last.items() if kind in ('override', 'rm-admit')}

admitted = read_admitted(os.environ.get('ND_LEDGER', ''), first_ver) if first_ver else set()

def residual_out(i):
    return residual_depth(i) >= 1 and i['key'] not in residual_must and i['key'] not in admitted

why = {}

def drop(i, reason):
    why.setdefault(i['key'], reason)

# A ticket whose body lacks a DoD or a Proof section is not dispatched. The verdict is the
# ticket-standard checker's (no second parser); it runs on the mirror's Description with its intake queue pointed
# at a scratch dir, because this script parks nothing. gen-briefs.py asks the same question.
proof_checker = os.path.join(repo, 'marketplace/plugins/himmel-ops/scripts/ticket-standard-check.sh')
proof_cache = {}
proof_told = set()

def proof_missing(i):
    # '' when DoD and Proof are both present, else the missing names ("DoD, Proof"); an unrunnable checker refuses
    k = i['key']
    if k not in proof_cache:
        try:
            txt = open(os.path.join(mirror, k + '.md'), encoding='utf-8', errors='replace').read()
            m = re.search(r'^## Description\n(.*?)(?=^## |\Z)', txt, re.M | re.S)
            with tempfile.TemporaryDirectory() as d:
                draft = os.path.join(d, 'draft.md')
                with open(draft, 'w', encoding='utf-8') as f:
                    f.write(m.group(1) if m else '')
                r = subprocess.run(['bash', proof_checker, '--type', 'Task', '--draft', draft], capture_output=True, text=True, timeout=30,
                                   env=dict(os.environ, TICKET_STANDARD_QUEUE_DIR=os.path.join(d, 'queue')))
            if r.returncode not in (0, 1):
                proof_cache[k] = 'DoD, Proof (the ticket-standard checker could not read the body: rc %d)' % r.returncode
            else:
                got = re.search(r'missing or empty: (.*)$', r.stdout, re.M)
                names = [n.strip() for n in got.group(1).split(',')] if got else []
                proof_cache[k] = ', '.join(n for n in ('DoD', 'Proof') if n in names)
        except (OSError, subprocess.SubprocessError):
            proof_cache[k] = 'DoD, Proof (the ticket-standard checker did not run)'
    return proof_cache[k]

def proof_refuse(i):
    # True when the ticket cannot be dispatched yet: dropped, and named once for the chief to fix first
    miss = proof_missing(i)
    if not miss:
        return False
    drop(i, 'proof missing: ' + miss)
    if i['key'] not in proof_told:
        proof_told.add(i['key'])
        print('# NO-PROOF %s missing %s: %s (fix the ticket, then it dispatches)' % (i['key'], miss, i['title']))
    return True

def tier_of(i):
    # 1 operator pool head, 2 operator-directed, 3 Bug High+ / security / data-integrity, 4 the rest of the
    # earliest unreleased version, 5 later or versionless work. Tiers 1-4 are the pool: the stale `priority:`
    # line and the labels never decide whether a current-version ticket is dispatchable.
    if i['key'] in prio_order or i['labels'] & TIER1_LABELS:
        return 1
    if first_ver is not None and first_ver not in i['ver']:
        return 5
    if 'operator-directed' in i['labels']:
        return 2
    if (i['type'] == 'Bug' and PRIO.get(i['prio'], 5) <= 1) or i['labels'] & TIER3_LABELS:
        return 3
    return 4 if first_ver is not None else 5  # no version list: nothing is known to be current

def ranked(i):
    return (tier_of(i), prio_order.get(i['key'], 10**6)) + rank(i)

def load_platform_re():
    # The one pattern file gen-briefs.py reads too: its first non-blank, non-# line.
    path = os.path.join(repo, 'scripts/handover/chief-kit/platform-dropped.re')
    try:
        for line in open(path):
            if line.strip() and not line.startswith('#'):
                return re.compile(line.strip(), re.I)
    except OSError:
        pass
    print('next-dispatchable: cannot read the dropped-platform pattern from %s' % path, file=sys.stderr); sys.exit(2)

platform_re = load_platform_re()
# a removal ticket names the dropped platform only to take it out: the windows-removal label, or a title that opens with a
# removal verb (after an optional `prefix:`), says removal, or says `stop <gerund>` ("stop citing"); a removal verb elsewhere
# ("<name> stops unexpectedly") is a bug report on the dropped platform and stays dropped
REMOVAL_RE = re.compile(r'^(?:[^:]{0,40}:\s*)?(?:(?:remove|drop|delete|retire|strip|purge)\b|removal\b)|\bstops?\s+(?:citing|referencing|mentioning|supporting|using|shipping|handling|probing|detecting|testing)\b', re.I)

def platform_dropped(i):
    return bool(platform_re.search(i['title'])) and 'windows-removal' not in i['labels'] and not REMOVAL_RE.search(i['title'])
# worker records: a To Do ticket whose worker wrapped with a resume brief is resumed, not redispatched
workers = os.environ.get('ND_WORKERS', '')
briefs = {}
try:
    names = os.listdir(workers)
except OSError:
    names = []
for name in names:
    if not name.endswith('.json'):
        continue
    try:
        rec = json.load(open(os.path.join(workers, name)))
    except (OSError, ValueError):
        continue
    if isinstance(rec, dict) and rec.get('state') == 'wrapped' and rec.get('resume_brief'):
        briefs[name[:-5].upper()] = str(rec['resume_brief'])
done_pending = set()  # keys whose LATEST contract-bearing merge row is contract=yes
partials = {}  # KEY -> PR numbers of its merged contract=no (partial) merges, oldest first
status_unreadable = False
try:
    for line in open(os.path.join(os.path.dirname(workers.rstrip('/')), 'status-events.jsonl')):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not (isinstance(r, dict) and r.get('event') == 'merge' and r.get('contract') in ('yes', 'no')):
            continue
        mkey = str(r.get('key', '')).upper()
        if r['contract'] == 'yes':
            done_pending.add(mkey)
            partials.pop(mkey, None)  # the completing merge closes every earlier partial slice
        else:
            done_pending.discard(mkey)  # a newer partial merge reopens a key an older contract=yes row closed
            if str(r.get('pr', '')).isdigit():
                prs_of = partials.setdefault(mkey, [])
                if str(r['pr']) not in prs_of:
                    prs_of.append(str(r['pr']))
except FileNotFoundError:
    pass
except OSError as e:
    status_unreadable = True
    print('# warn: %s is unreadable (%s): merged contract rows are unknown: a To Do ticket with a merge on main is withheld, but a done-pending or partially merged In Progress ticket may still be listed as RESUME' % (os.path.join(os.path.dirname(workers.rstrip('/')), 'status-events.jsonl'), e.strerror or e))

def merged_on_main(key):
    # True when the main ref carries a commit citing [KEY]; a git read that fails counts as merged (unknown fails closed)
    try:
        r = subprocess.run(['git', '-C', os.environ['ND_GIT_DIR'], 'log', os.environ['ND_MAIN_REF'], '--fixed-strings', '--grep=[%s]' % key, '-1', '--format=%h'],
                           capture_output=True, text=True, timeout=60, check=True)
        return bool(r.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return True

def partial_resume(key):
    # a ticket with a merged partial slice is in work: it is a RESUME row naming that slice, never a fresh To Do row
    return key in partials and key not in done_pending

# The mirror lags both ways, so a candidate's blockers are all read live once, bounded (20 s a key,
# 8 in parallel, every key read: no cap), through NEXT_DISPATCH_JIRA_CMD (`<cmd> get KEY` prints a tab line KEY, type, status, title) or the real
# jira CLI of the primary checkout. The real read runs only where the classifier is real too; an unreadable key
# is UNREADABLE (the candidate drops as blocker-unknown).
DONE_STATES = ('Done', 'Closed')
# Done = the Jira statusCategory is Done (catches 'wont do', 'wont fix', ...); the status names stay as a fallback
def done_key(k):
    i = issues.get(k)
    return bool(i) and (i['cat'] == 'Done' or i['status'] in DONE_STATES)
# ponytail: custom Done statuses hold until listed here, upgrade path: jira get returns statusCategory
# a live read carries only the status name, so its Done-category names are listed here
LIVE_DONE = DONE_STATES + ('wont do', 'wont fix', 'Resolved', 'In Public')
jira_cmd = os.environ.get('NEXT_DISPATCH_JIRA_CMD')
live_on = bool(jira_cmd) or (os.environ.get('ND_CLASSIFY') == '1' and not os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD'))
live_cache = {}

def jira_argv(key):
    if jira_cmd:
        return [jira_cmd, 'get', key]
    common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=repo, capture_output=True, text=True, timeout=20, check=True).stdout.strip()
    return ['node', os.path.join(os.path.dirname(common), 'scripts/jira/dist/index.js'), 'get', key]

def live_read(key):
    try:
        r = subprocess.run(jira_argv(key), capture_output=True, text=True, timeout=20, check=True, env=dict(os.environ, JIRA_PROJECT_KEY=os.environ.get('JIRA_PROJECT_KEY', key.split('-')[0])))
        cols = (r.stdout.splitlines() or [''])[0].split('\t')
        return cols[2].strip() if len(cols) >= 3 and cols[0] == key else None
    except (OSError, subprocess.SubprocessError):
        return None

def live_fetch(keys):
    fresh = sorted({k for k in keys if k not in live_cache})
    if not (live_on and fresh):
        return
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=min(8, len(fresh))) as pool:
        for k, st in zip(fresh, pool.map(live_read, fresh)):
            live_cache[k] = st

UNREADABLE = '\0unreadable'

def blocker_state(b):
    # None when the blocker is resolved, UNREADABLE when its live read failed, else its status (live when read).
    # A key never read live (live read off) is the mirror's word.
    st = issues.get(b, {}).get('status')
    if b in live_cache:
        live = live_cache[b]
        if live is None:
            return UNREADABLE
        if live in LIVE_DONE:
            return None
        return 'reopened live' if done_key(b) else '%s, live' % live
    if done_key(b):
        return None
    return st or 'not in mirror'

def reaches_blocker_check(i):
    # the same gates the candidate loop applies before it looks at blockers, without its side effects
    return (i['status'] == 'To Do' and i['key'] not in briefs and i['type'] not in ('Epic', 'Sub-task') and i['key'] not in done_pending
            and not (i['labels'] & excl or re.match(r'\s*parked:', i['title'], re.I))
            and not platform_dropped(i))

def family_candidate(i):
    # a To Do sub-task that could sit in a SERIES FAMILY row, by the checks that need no live read, held files or worker set;
    # only its blockers are read live, so an irrelevant sub-task costs no Jira call
    return bool(stacked and first_ver and i['type'] == 'Sub-task' and i['status'] == 'To Do' and first_ver in i['ver'] and i['parent'] and i['files']
                and i['key'] not in done_pending and i['key'] not in briefs and not (i['labels'] & excl)
                and not re.match(r'\s*parked:', i['title'], re.I) and not residual_out(i) and not platform_dropped(i))

# every hard blocker of a candidate is read live, whatever the mirror says; so is every blocker of an in-work ticket (RESUME rows)
live_fetch([b for i in issues.values() if reaches_blocker_check(i) for b in i['blocked_by']]
           + [b for i in issues.values() if i['status'] in ('To Do', 'In Progress', 'In Review', 'IN CI') and i['type'] not in ('Epic', 'Sub-task')
              for b in i['blocked_by']]
           + [b for i in issues.values() if family_candidate(i) for b in i['blocked_by']])  # a SERIES FAMILY member's blockers
print('# source live_reads=%d' % len(live_cache))
skipped_platform = []
withheld_unreadable = []
cands = []
for i in issues.values():
    if i['status'] != 'To Do' or i['key'] in briefs or (partial_resume(i['key']) and i['type'] not in ('Epic', 'Sub-task')):
        continue
    if i['type'] in ('Epic', 'Sub-task'):
        drop(i, 'type ' + i['type'])
        continue
    if i['key'] in done_pending:
        drop(i, 'done-pending (a contract=yes merge row; the mirror lags)')
        continue
    if i['labels'] & excl or re.match(r'\s*parked:', i['title'], re.I):
        drop(i, 'label ' + (','.join(sorted(i['labels'] & excl)) or 'parked: title'))
        continue
    if platform_dropped(i):
        skipped_platform.append(i['key'])
        drop(i, 'platform (windows/wsl title)')
        continue
    open_b = [(b, blocker_state(b)) for b in i['blocked_by'] if blocker_state(b)]
    if open_b:
        known = ['%s (%s)' % bs for bs in open_b if bs[1] != UNREADABLE]
        unknown = [b for b, st in open_b if st == UNREADABLE]
        drop(i, '; '.join(([('blocker ' + ', '.join(known))] if known else []) + ([('blocker-unknown ' + ', '.join(unknown))] if unknown else [])))
        continue
    if i['key'] in prio_cloud:
        drop(i, 'cloud-only on the priority line')
        continue
    if residual_out(i):
        drop(i, 'residual-depth %d (no residual-must line, no admissions-ledger row)' % residual_depth(i))
        continue
    if status_unreadable and merged_on_main(i['key']):
        withheld_unreadable.append(i['key'])
        drop(i, 'status-events.jsonl unreadable and the key has a merge on main')
        continue
    cands.append(i)
if withheld_unreadable:
    print('# WARN: status-events.jsonl is unreadable: withheld %s (a merge on main)' % ', '.join(withheld_unreadable))
cands.sort(key=ranked)
pool_only = os.environ.get('ND_POOL_ONLY') == '1'
next_tier = [i for i in cands if tier_of(i) > 4]
if pool_only:
    cands = [i for i in cands if tier_of(i) <= 4]

# core_gate, only with the flag on (off, the default, runs nothing and changes no line): the built jira CLI says
# which To Do candidates are core and whether each has a signed minerva spec. A core ticket with no `SPEC ok` lists as a
# `DESIGN <KEY> NO-SPEC|SPEC-STALE` row, not a build row. Fail closed: a check that cannot run lists no To Do row, and a key
# the mirror lacks (UNKNOWN) is withheld.
design = {}  # KEY -> NO-SPEC | SPEC-STALE
CORE_VERBS = ('CORE', 'NOT-CORE', 'BYPASS', 'UNKNOWN')
CORE_FIELDS = {'CORE': 3, 'BYPASS': 4}  # tokens a core-check line needs: CORE <K> <match>, BYPASS <K> <kind> <reason...>

def core_run(args, ok_rc, project):
    # (stdout, '') for a run whose exit code is in ok_rc, else (None, why). A missing CLI, node or a timeout is never an answer.
    try:
        cli = os.environ.get('NEXT_DISPATCH_JIRA_CLI')
        if not cli:
            common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=repo, capture_output=True, text=True, timeout=20, check=True).stdout.strip()
            cli = os.path.join(os.path.dirname(common), 'scripts/jira/dist/index.js')
        if not os.path.isfile(cli):
            return None, 'no built jira CLI at %s' % cli
        # cwd inside the CLI's own checkout: it runs `git rev-parse` from its cwd
        r = subprocess.run(['node', cli] + args, capture_output=True, text=True, timeout=120, cwd=os.path.dirname(os.path.abspath(cli)),
                           env=dict(os.environ, JIRA_PROJECT_KEY=os.environ.get('JIRA_PROJECT_KEY', project)))
    except (OSError, subprocess.SubprocessError) as e:
        return None, 'the jira CLI could not run (%s)' % e
    if r.returncode not in ok_rc:
        return None, '%s exited %d: %s' % (args[1], r.returncode, (r.stderr or r.stdout).strip()[:200])
    return r.stdout, ''

def core_lines(out, keys, spec=False):
    # The one line each key got (gen-briefs.py per_key_lines); a key with no line is absent from the result.
    got = {}
    for line in out.splitlines():
        t = line.split()
        if spec and t[:2] == ['SPEC', 'ok'] and len(t) >= 4:
            got[t[2]] = line
        elif t and (t[0] in ('SPEC-STALE', 'NO-SPEC') if spec else t[0] in CORE_VERBS) and len(t) >= CORE_FIELDS.get(t[0], 2):
            got[t[1]] = line  # a line shorter than its verb needs is no answer: a truncated BYPASS must never read as a bypass
    return {k: got[k] for k in keys if k in got}

def core_gate_pass(cs):
    # the candidates that may still list (a DESIGN one is recorded in `design`); core-check takes ONE --paths per call, so
    # tickets naming the same files share a call (the calls run in parallel), then spec-check asks once for every CORE key
    mdir = os.path.abspath(mirror)
    project = cs[0]['key'].split('-')[0]
    def fail(why):
        print('# WARN CORE-CHECK-FAILED %s' % ' '.join(why.split()))
        for i in cs:
            drop(i, 'core-check failed (a gate that cannot run lists no To Do row)')
        return []
    groups = {}
    for i in cs:
        groups.setdefault(tuple(i['files']), []).append(i['key'])
    items = list(groups.items())
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=min(8, len(items))) as pool:
        results = list(pool.map(lambda g: core_run(['release', 'core-check', '--paths', ','.join(g[0]), '--mirror', mdir, '--key'] + g[1], (0,), project), items))
    verdict = {}
    for (_, ks), (out, why) in zip(items, results):
        if out is None:
            return fail(why)
        got = core_lines(out, ks)
        if len(got) != len(ks):
            return fail('core-check printed no parseable line for %s' % ', '.join(k for k in ks if k not in got))
        verdict.update(got)
    keep, core = [], []
    for i in cs:
        verb = verdict[i['key']].split()[0]
        if verb == 'UNKNOWN':
            drop(i, 'core-unknown (not in the mirror: neither core nor a bypass can be proven)')
            continue
        keep.append(i)
        if verb == 'CORE':
            core.append(i['key'])
    if core:
        out, why = core_run(['release', 'spec-check', '--mirror', mdir] + core, (0, 1), project)
        if out is None:
            return fail(why)
        got = core_lines(out, core, spec=True)
        if len(got) != len(core):
            return fail('spec-check printed no parseable line for %s' % ', '.join(k for k in core if k not in got))
        for k in core:
            if not got[k].startswith('SPEC ok'):
                design[k] = got[k].split()[0]
    return keep

if os.environ.get('ND_CORE_GATE') == '1' and cands and os.environ.get('ND_RESUME_ONLY') != '1':  # --resume-only lists no To Do row
    cands = core_gate_pass(cands)

# held files: live workers, open PRs, --held
held = []
series_workers = {}  # label -> {'doc', 'sid', 'ledger', 'count'} for a live worker whose brief carries a Series line (stacked_series only); count is None until known
manifest_docs = set()  # the resolved path of every worker doc the manifest lists (the orphan check asks whether a ledger's writer is among them)
workers_from = os.environ.get('ND_WORKERS_FROM', '')
workers_unknown = False
worker_keys = set(os.environ.get('ND_OWNERS', '').split())
owner = {k: 'the --owners list' for k in worker_keys}
resume_only = os.environ.get('ND_RESUME_ONLY') == '1'
if workers_from and not os.path.isfile(workers_from):
    workers_unknown = True
if workers_from and os.path.isfile(workers_from):
    try:
        for worker in manifest_workers(json.load(open(workers_from))):
            doc = worker.get('doc', '')
            if doc:
                manifest_docs.add(os.path.realpath(doc))
            try:
                lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
            except OSError:
                for k in re.findall(r'[A-Z]+-\d+', os.path.basename(doc)):
                    worker_keys.add(k); owner.setdefault(k, 'live worker %s' % worker.get('label', '?'))
                workers_unknown = True
                continue
            marks = [m.group(1) for m in (MARKER_RE.match(l) for l in lines) if m]
            if marks and marks[-1] == 'WRAPPED':  # a wrapped worker holds no files and owns no ticket
                continue
            for k in re.findall(r'[A-Z]+-\d+', os.path.basename(doc)):
                worker_keys.add(k); owner.setdefault(k, 'live worker %s' % worker.get('label', '?'))
            def block(i):  # a wrapped line continues on the "> " lines under it, up to the next "> **" field or a blank
                text = lines[i]
                for nxt in lines[i + 1:]:
                    if not nxt.startswith('> ') or nxt.startswith('> **'):
                        break
                    text += ' ' + nxt[2:]
                return text
            starts = [i for i, l in enumerate(lines) if l.startswith(WRITES_LEAD)]  # the one source; older briefs only have the scope line
            starts = starts or [i for i, l in enumerate(lines) if l.startswith('> **Scope / do not:**') or (l.startswith('>') and 'writes confined to' in l)]  # not the front-matter description, which quotes the phrase
            mine = [f for i in starts for f in scope_paths(block(i))]
            held += [(f, 'live worker %s' % worker.get('label', '?'), True) for f in mine]
            sl = [i for i, l in enumerate(lines) if l.startswith(SERIES_LEAD)] if stacked else []
            items = set(SERIES_ITEM_RE.findall(block(sl[0]))) if sl else set()
            sid_m = SERIES_ID_RE.match(lines[sl[0]][len(SERIES_LEAD):].strip()) if sl else None
            if items or sid_m:  # a series worker: its Series line names the sid and ledger (S2a), or its block has one numbered line per item. The count is the ledger's when it is read below; a block that names neither has an unknown count, so it offers no room
                series_workers[worker.get('label', '?')] = {'doc': doc, 'sid': sid_m.group(1) if sid_m else None,
                                                            'ledger': os.path.realpath(sid_m.group(2)) if sid_m else None, 'count': len(items) or None}
            if os.environ.get('ND_WHY') == '1':
                for f in dict.fromkeys(mine):
                    if not concrete(f):
                        print('# warn: %s holds directory %s' % (worker.get('label', '?'), f))
            if not mine and not any(lines[i][len(WRITES_LEAD):].strip() == 'none named' for i in starts if lines[i].startswith(WRITES_LEAD)):  # "none named" is what gen-briefs writes for a worker that writes nothing
                workers_unknown = True  # a scope that yields no paths could be hiding the worker's files
                print('next-dispatchable: live worker %s yields no held paths (no Writes line or scope clause in %s): its files are unknown' % (worker.get('label', '?'), os.path.basename(doc)), file=sys.stderr)
    except (OSError, ValueError):
        workers_unknown = True
# `chief.sh next` copies the manifest once, so a worker the other chief of this chain arms later is
# in no manifest but its own. Read the chain's other manifests (same bucket, same prefix and chief name, any
# letter) for ownership of a ticket only: a doc that is gone, WRAPPED, or untouched for a day holds nothing, and
# an unreadable sibling never marks the fleet unknown (it is not this chief's fleet).
chain_m = re.match(r'^(.+)-nextleg-\d{4}-\d{2}-\d{2}[A-Z]+-(.+)\.fleet\.json$', os.path.basename(workers_from)) if workers_from else None
if chain_m:
    sib_dir = os.path.dirname(os.path.abspath(workers_from))
    try:
        sib_age_s = int(os.environ.get('NEXT_DISPATCH_SIBLING_MAX_AGE_MIN', '1440')) * 60
    except ValueError:
        sib_age_s = 1440 * 60  # a non-integer window reads as the default, never a crash
    try:
        siblings = sorted(os.listdir(sib_dir))
    except OSError:
        siblings = []
    for sib in siblings:
        sm = re.match(r'^(.+)-nextleg-\d{4}-\d{2}-\d{2}[A-Z]+-(.+)\.fleet\.json$', sib)
        if not sm or sm.groups() != chain_m.groups() or os.path.join(sib_dir, sib) == os.path.abspath(workers_from):
            continue
        try:
            sib_manifest = json.load(open(os.path.join(sib_dir, sib)))
            sib_workers = manifest_workers(sib_manifest) if isinstance(sib_manifest, dict) else []
            for worker in sib_workers if isinstance(sib_workers, list) else []:
                sdoc = worker.get('doc') if isinstance(worker, dict) else None
                if not isinstance(sdoc, str) or not sdoc:
                    continue  # an entry that names no doc owns nothing
                try:
                    if time.time() - os.path.getmtime(sdoc) > sib_age_s:
                        continue
                    slines = open(sdoc, encoding='utf-8', errors='replace').read().splitlines()
                except OSError:
                    continue
                smarks = [m.group(1) for m in (MARKER_RE.match(l) for l in slines) if m]
                if smarks and smarks[-1] == 'WRAPPED':
                    continue
                for k in re.findall(r'[A-Z]+-\d+', os.path.basename(sdoc)):
                    worker_keys.add(k); owner.setdefault(k, 'live worker %s of the chief on %s' % (worker.get('label', '?'), sib[:-len('.fleet.json')]))
        except (OSError, ValueError, TypeError, AttributeError):
            continue  # swallow-ok: a sibling chief's unreadable or malformed manifest names no worker; this chief's own fleet is still known
if pool_only and not workers_from and not worker_keys:
    workers_unknown = True
    print('next-dispatchable: no RESUME rows: --priority-pool-only has no worker source (--owners or --workers-from)', file=sys.stderr)
# cloud sessions own their ticket too: the same file and 48h window tick reads
cloud_tsv = os.path.join(os.path.dirname(os.environ['ND_DOC']), 'cloud-sessions.tsv') if os.environ.get('ND_DOC') else ''
if cloud_tsv and os.path.isfile(cloud_tsv):
    window_s = int(os.environ.get('CLOUD_LIVENESS_WINDOW_H', '48')) * 3600
    for line in open(cloud_tsv, encoding='utf-8', errors='replace'):
        cols = line.rstrip('\n').split('\t')
        if len(cols) < 2:
            continue
        try:
            at = datetime.datetime.fromisoformat(cols[0].replace('Z', '+00:00')).timestamp()
        except ValueError:
            continue
        if time.time() - at <= window_s:
            worker_keys.add(cols[1].strip().upper()); owner.setdefault(cols[1].strip().upper(), 'a cloud session')
hf = os.environ.get('ND_HELD', '')
if hf and os.path.isfile(hf):
    held += [(l.strip(), 'held list', True) for l in open(hf) if l.strip()]
pr_unknown = False
pr_files_unknown = []
pr_keys = set()
gh = os.environ.get('NEXT_DISPATCH_GH_CMD', 'gh')
gh_repo = 'yotamleo-org/Himmel'  # env-literal-ok: the canonical slug; --search does not follow a repo rename
try:
    nums = subprocess.run([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'],
                          capture_output=True, text=True, timeout=60, check=True).stdout.split()
    def pr_files(num):
        # the paginated files API, not `gh pr diff`: that fails with HTTP 406 on a PR over 300 files. A rename holds both names.
        try:
            files = subprocess.run([gh, 'api', '--paginate', 'repos/%s/pulls/%s/files' % (gh_repo, num), '--jq', '.[] | .filename, (.previous_filename // empty)'],
                                   capture_output=True, text=True, timeout=120, check=True).stdout.splitlines()
        except (OSError, subprocess.SubprocessError):
            return None  # this PR's files are unknown; the rest are still read
        return None if len(files) >= 3000 else files  # the API stops at 3000 files: a PR that long is cut short, so its files are unknown
    pr_nums = [] if resume_only else nums
    if pr_nums:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=min(8, len(pr_nums))) as pool:
            for num, d in zip(pr_nums, pool.map(pr_files, pr_nums)):
                if d is None:
                    pr_files_unknown.append(num)
                    continue
                held += [(f, 'open PR %s' % num, False) for f in d if f]  # a diff is files: compared exactly
    # an open PR cites a ticket by its title or head branch (the commit/PR gate puts the key in both)
    for line in subprocess.run([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'open', '--limit', '200', '--json', 'title,headRefName', '--jq', '.[] | [.number, .title, .headRefName] | @tsv'],
                               capture_output=True, text=True, timeout=60, check=True).stdout.splitlines():
        for k in re.findall(r'[A-Za-z]+-\d+', line):
            pr_keys.add(k.upper()); owner.setdefault(k.upper(), 'open PR %s' % line.split('\t')[0])
except (OSError, subprocess.SubprocessError):
    pr_unknown = True

# stacked_series: every ledger under <bucket>/series/ (the bucket is the --workers-from manifest's directory), read through
# series-ledger.py, is a holder. An item holds its writes as `series <sid>` until it is abandoned or gh reports every PR of its
# publish_branch merged or closed, whatever any worker doc says; a gh answer that is missing or fails keeps the hold.
# A writer doc with no LIVE bullet and no manifest entry SERIES_ORPHAN_S after the newest pass (or the ledger's last write, for
# a series with no pass) is named SERIES-ORPHAN for the chief; it still holds until the chief abandons the series.
# ponytail: a ledger carries no created_at, so a series with no pass ages from the ledger file's mtime, upgrade path: a created_at field in series-ledger.py create
SERIES_ORPHAN_S = 2 * 3600
series_orphans = []  # (sid, writer doc)
series_label_of = {}  # ledger sid -> the label of the live series worker that owns the ledger

BRANCH_PR_LIMIT = 100

def branch_states(branch):
    # every PR state (OPEN, MERGED, CLOSED) gh lists for the head branch; None when gh cannot say, or when the list
    # fills its limit (a PR past it could be open)
    try:
        out = subprocess.run([gh, 'pr', 'list', '--repo', gh_repo, '--head', branch, '--state', 'all', '--limit', str(BRANCH_PR_LIMIT), '--json', 'state', '--jq', '.[].state'],
                             capture_output=True, text=True, timeout=60, check=True).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return None  # swallow-ok: a PR state that cannot be read keeps the hold
    return out if len(out) < BRANCH_PR_LIMIT else None

def has_live_bullet(doc):
    try:
        return any(re.match(r'^- \d{1,2}:\d{2} LIVE\b', l) for l in open(doc, encoding='utf-8', errors='replace'))
    except OSError:
        return False  # swallow-ok: a doc that cannot be read shows no LIVE marker, so the series is named, never hidden

def last_activity(led, path):
    stamps = []
    for x in led['passes']:
        try:
            stamps.append(datetime.datetime.strptime(x['at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp())
        except (KeyError, TypeError, ValueError):
            continue  # swallow-ok: a pass with no readable time says nothing about the series' age
    return max(stamps) if stamps else os.path.getmtime(path)

if stacked and workers_from:
    ledger_py = os.path.join(repo, 'scripts/handover/chief-kit/series-ledger.py')
    series_dir = os.path.join(os.path.dirname(os.path.abspath(workers_from)), 'series')
    try:
        ledger_files = sorted(n for n in os.listdir(series_dir) if n.endswith('.json'))
    except FileNotFoundError:
        ledger_files = []  # swallow-ok: no series directory means no series
    except OSError:
        ledger_files = []
        workers_unknown = True  # a directory that cannot be listed could be hiding every hold
        print('next-dispatchable: series directory %s cannot be listed: the files its ledgers hold are unknown' % series_dir, file=sys.stderr)
    for n in ledger_files:
        path = os.path.join(series_dir, n)
        try:
            led = json.loads(subprocess.run([sys.executable, '-I', ledger_py, 'read', '--ledger', path], capture_output=True, text=True, timeout=60, check=True).stdout)
            sid = str(led.get('sid') or n[:-len('.json')])
            # the ledger of a live series worker: named by its Series line (sid or path), or naming the worker's doc as its writer.
            # Its files then belong to that worker, and its non-abandoned items are the seats the worker has used
            for lbl, w in series_workers.items():
                named = w['sid'] is not None  # a Series line that names its ledger reads that one only; the writer match serves a numbered block, which names none
                if (w['sid'] == sid or w['ledger'] == os.path.realpath(path)) if named else os.path.realpath(led['writer']) == os.path.realpath(w['doc']):
                    series_label_of[sid] = lbl
                    w['count'] = max(w['count'] or 0, sum(1 for it in led['items'] if it.get('state') != 'abandoned'))  # the fullest of the brief's numbered items and every ledger it matches
            for it in led['items']:
                if it.get('state') == 'abandoned':
                    continue
                if it.get('state') == 'published' and it.get('publish_branch'):
                    states = branch_states(it['publish_branch'])
                    if states and all(s in ('MERGED', 'CLOSED') for s in states):
                        continue
                held += [(w, 'series %s' % sid, True) for w in (it.get('writes') or []) if isinstance(w, str) and w]
            writer = led['writer']
            if time.time() - last_activity(led, path) > SERIES_ORPHAN_S and not has_live_bullet(writer) and os.path.realpath(writer) not in manifest_docs:
                series_orphans.append((sid, writer))
        except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
            workers_unknown = True  # a ledger that cannot be read could be hiding held files
            print('next-dispatchable: series ledger %s is unreadable: the files it holds are unknown' % n, file=sys.stderr)

# An IN CI ticket nobody holds is merged-not-closed when a merged PR cites it, else a RESUME row.
# One bounded search per candidate key (a merged-PR list capped at N would miss an older merge).
merged_unknown = False
merged_keys = set()
inci_keys = [i['key'] for i in issues.values() if i['status'] == 'IN CI' and i['type'] not in ('Epic', 'Sub-task')
             and i['key'] not in worker_keys and i['key'] not in pr_keys]
if inci_keys and not (pr_unknown or pr_files_unknown or workers_unknown):
    def merged_cites(key):
        out = subprocess.run([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'merged', '--search', key, '--limit', '30', '--json', 'title,headRefName', '--jq', '.[] | [.title, .headRefName] | @tsv'],
                             capture_output=True, text=True, timeout=60, check=True).stdout
        return key in {k.upper() for k in re.findall(r'[A-Za-z]+-\d+', out)}
    try:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=min(8, len(inci_keys))) as pool:
            merged_keys = {k for k, hit in zip(inci_keys, pool.map(merged_cites, inci_keys)) if hit}
    except (OSError, subprocess.SubprocessError):
        merged_unknown = True

# The `Remaining:` text of a merged partial PR's body (the line merge-on-green.sh reads); '' when the body has none.
# A body gh cannot read is recorded in unread_prs and also returns '', so the ticket is never dispatched blind.
remaining_cache = {}
unread_prs = set()
def remaining_of(pr):
    if pr not in remaining_cache:
        try:
            body = subprocess.run([gh, 'pr', 'view', pr, '--repo', gh_repo, '--json', 'body', '--jq', '.body'], capture_output=True, text=True, timeout=60, check=True).stdout
        except (OSError, subprocess.SubprocessError):
            body = ''
            unread_prs.add(pr)
        remaining_cache[pr] = ' '.join(m.strip() for m in re.findall(r'(?im)^[ \t]*remaining:[ \t]*(.*\S)', body))
    return remaining_cache[pr]

# In-work tickets nobody holds (and wrapped To Do ones): no worker, no open PR, not parked or blocked.
needs_note = []  # (key, partial PR numbers with no Remaining: text) of in-work tickets that need a chief note first
resume = []
resume_held = []  # (key, holder) of in-work tickets a collision keeps off the list
for i in issues.values():
    if pool_only and (tier_of(i) > 4 or i['key'] in prio_cloud):
        continue
    wrapped = i['status'] == 'To Do' and (i['key'] in briefs or partial_resume(i['key']))
    if not (wrapped or i['status'] in ('In Progress', 'In Review', 'IN CI')) or i['type'] in ('Epic', 'Sub-task'):
        continue
    if i['status'] == 'IN CI' and merged_unknown:  # an unread merged-PR set could hide the ticket's merge
        continue
    i['merged'] = i['status'] == 'IN CI' and i['key'] in merged_keys
    if i['key'] in done_pending:
        continue
    if i['labels'] & excl or any('parked' in l for l in i['labels']):
        continue
    if pool_only and platform_dropped(i):
        continue
    if pool_only and residual_out(i):
        continue
    if i['key'] in worker_keys or i['key'] in pr_keys:
        continue
    if pr_unknown or pr_files_unknown or workers_unknown:  # an unread PR, PR file set or worker set could hide the ticket's owner
        continue
    if i['merged']:  # nothing to dispatch: the ticket only needs closing
        resume.append(i)
        continue
    if any(blocker_state(b) for b in i['blocked_by']):
        continue
    hit = held_hit(i)
    if hit:
        resume_held.append((i['key'], hit[1]))  # a held RESUME row is named, never dropped silently
        continue
    i['partial'] = [(pr, remaining_of(pr)) for pr in partials.get(i['key'], [])] if partial_resume(i['key']) else []
    if any(not text for _, text in i['partial']):  # a merged slice whose PR body names no remaining work: not dispatched blind
        needs_note.append((i['key'], [pr for pr, text in i['partial'] if not text]))
        continue
    resume.append(i)
resume.sort(key=ranked if pool_only else rank)

def stackable_on(i):
    # (worker label, items, writer doc) when every file the ticket collides on is held by ONE live series worker with room; else None.
    # A series worker's own ledger is that same worker, not a second holder. A holder that is an open PR, the --held list or a
    # second worker, or an unread PR / worker set, keeps the drop.
    if pr_unknown or pr_files_unknown or workers_unknown:
        return None
    holders = {('live worker ' + series_label_of[who[len('series '):]]) if who.startswith('series ') and who[len('series '):] in series_label_of else who
               for _, who in held_hits(i)}
    if len(holders) != 1:
        return None
    who = next(iter(holders))
    label = who[len('live worker '):] if who.startswith('live worker ') else None
    w = series_workers.get(label)
    return (label, w['count'], w['doc']) if w and w['count'] is not None and w['count'] < SERIES_CAP else None

stackable_rows = []
free = []
for i in cands:
    if i['key'] in worker_keys or i['key'] in pr_keys:  # a live worker or an open PR already owns the ticket
        drop(i, 'owned by ' + owner.get(i['key'], 'a live worker'))
        continue
    if i['key'] in design:  # a design leg writes only its spec in the state repo: it holds no files against the rest of the list
        if pr_unknown:  # an unread PR list could hide an open PR that owns the ticket
            drop(i, 'open PRs unknown (gh failed): ownership cannot be checked')
        else:
            free.append(i)
        continue
    hit = held_hit(i)
    if hit:
        stack = stackable_on(i) if stacked else None
        if stack:
            stackable_rows.append((i, 'STACKABLE %s %s' % (i['key'], stack[2]), 'stackable on %s (%d/%d)' % (stack[0], stack[1], SERIES_CAP)))
            continue  # judged in emit_stackable once it is classified: a ticket that would be BLOCKED is not offered
        soft = soft_overlap(i, held_hits(i))
        if soft is None:
            drop(i, 'collision %s held by %s' % hit)
            continue
        soft_rows[i['key']] = soft
    if pr_unknown or pr_files_unknown:  # an unread PR list or PR file set could hold the ticket's files
        drop(i, 'open PRs unknown (gh failed): collisions cannot be checked' if pr_unknown else 'open PR files unknown (PR %s): its collisions cannot be checked' % ' '.join(pr_files_unknown))
        continue
    free.append(i)

reasons = {}  # the classifier's stated reason per key

def classify(batch):
    cls = {}
    cmd = os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD')
    argv = [cmd] if cmd else ['node', os.path.join(repo, 'scripts/lanes/cloud-route.mjs'), '--classify-only']
    hfile = None
    if held:
        import tempfile
        t = tempfile.NamedTemporaryFile('w', suffix='.held', delete=False)
        t.write('\n'.join(h for h, _, _ in held) + '\n'); t.close(); hfile = t.name
        if not cmd:
            argv += ['--held', hfile]
    try:
        r = subprocess.run(argv + [i['key'] for i in batch], capture_output=True, text=True, timeout=300)
        for line in r.stdout.splitlines():
            p = line.split('\t')
            if len(p) >= 2 and re.match(r'^[A-Z]+-\d+$', p[0]):
                cls[p[0]] = p[1]
                reasons[p[0]] = p[2].strip() if len(p) > 2 else ''
    except (OSError, subprocess.SubprocessError):
        pass
    if hfile:
        os.unlink(hfile)
    return cls

print('# next-dispatchable: %d To Do candidate(s), %d collision-free%s' % (len(cands), len(free), ', open PRs unknown (gh failed)' if pr_unknown else '') + (', open PR files unknown for PR %s (gh failed; their collisions are unchecked)' % ' '.join(pr_files_unknown) if pr_files_unknown else '') + (', %d RESUME (in work, no worker, no open PR)' % len(resume) if resume else '') + (', live workers unknown (manifest or worker doc unreadable, or a worker names no write scope)' if workers_unknown else '') + (', merged PRs unknown (gh failed)' if merged_unknown else ''))
for k, who in resume_held:
    print('RESUME-HELD %s by %s' % (k, who))
for k, prs in needs_note:
    print('NEEDS-CHIEF-NOTE %s: merged PR %s %s, needs a chief note before it is dispatched' % (k, ', '.join('#' + p for p in prs),
          'body could not be read (gh failed)' if any(p in unread_prs for p in prs) else 'has no Remaining: line'))
for sid, wdoc in series_orphans:
    print('SERIES-ORPHAN %s %s' % (sid, wdoc))

def family_of(f):
    # a path's directory family: the first two path components, as scripts/cleanup/cleanup-batch.sh cuts it
    # ponytail: the rule lives in cleanup-batch.sh (awk) and here, upgrade path = one scripts/lib helper both call
    p = canon(f).strip('/').split('/') + (['*'] if f.endswith('/') else [])  # a directory is cut as a file inside it
    return '/'.join(p[:2]) if len(p) >= 3 else (p[0] if len(p) == 2 else '.')

if stacked and first_ver and not (pr_unknown or pr_files_unknown or workers_unknown):
    # SERIES FAMILY: To Do sub-tasks of one parent whose files all sit in one directory family, free of every holder. Sub-tasks
    # are never dispatch rows; the chief composes the series from this row (`series: [...]` in workers.json)
    families = {}
    for i in sorted(issues.values(), key=lambda i: int(i['key'].split('-')[1])):
        if not family_candidate(i) or i['key'] in worker_keys or i['key'] in pr_keys:
            continue
        if held_hit(i) or any(blocker_state(b) for b in i['blocked_by']):
            continue
        fams = {family_of(f) for f in i['files']}
        if len(fams) == 1:
            families.setdefault((i['parent'], next(iter(fams))), []).append(i['key'])
    for (_, fam), keys in families.items():
        if len(keys) >= 2:
            print('SERIES FAMILY %s %s' % (fam, ','.join(keys[:SERIES_CAP])))
if skipped_platform:
    print('# skipped %d windows/wsl ticket(s): %s' % (len(skipped_platform), ' '.join(sorted(skipped_platform))))
n = 0
picked = []  # (file, key) a listed ticket holds against the rest of the list

def picked_hit(i):
    for f in i['files']:
        for h, k in picked:
            if blocks(f, h, False):
                return f, k
    return None

def picked_hits(i):
    return [(f, k) for f in i['files'] for h, k in picked if blocks(f, h, False)]
emitted = []
lane_of = {}  # key -> how a listed ticket was listed

# stacked_series: a row is held back until the pass ends, so a later candidate can join the series its head opened.
# With the flag off every row prints at once, as it always did.
out_buf = []

def say(text):
    if stacked:
        out_buf.append(text)
    else:
        print(text)

def flush_rows():
    for t in out_buf:
        print(t() if callable(t) else t)
    del out_buf[:]

series = {}     # head key -> {'keys', 'files', 'hook', 'row', 'prio', 'ver', 'lane'}
series_of = {}  # key -> the head key of the series it sits in (a free row is a series of one until another joins)

def series_text(h):
    s = series[h]
    if len(s['keys']) == 1:
        return s['row']
    return '\t'.join(['SERIES', 'LOCAL?' if s['lane'] == 'LOCAL?' else 'LOCAL', ','.join(s['keys']), s['prio'], s['ver'], 'files=' + (','.join(s['files']) or '-')] + (['hook'] if s['hook'] else []))

def list_free(i, lane, c, row):
    # a collision-free row is listed; with stacked_series it is also the head of a series others may join
    picked.extend((f, i['key']) for f in i['files'])
    emitted.append(i)
    lane_of[i['key']] = lane
    if i['key'] in soft_rows:
        say('# SOFT %s for %s' % (soft_rows[i['key']], i['key']))
    if not stacked:
        print(row)
        return
    series[i['key']] = {'keys': [i['key']], 'files': list(i['files']), 'hook': c == 'HOOK-BYPASS', 'row': row,
                        'prio': i['prio'] or '-', 'ver': ','.join(i['ver']) or '-', 'lane': lane}
    series_of[i['key']] = i['key']
    out_buf.append(lambda h=i['key']: series_text(h))

def join_series(i, lane, c):
    # True when the ticket joins the series of the listed row it collides with: every listed ticket it collides with is in that
    # one series, the series has room (cap 4), the ticket's version is the head's or earlier, and no soft-edge note rides on it
    hits = picked_hits(i)
    heads = {series_of.get(k) for _, k in hits}
    if not hits or None in heads or len(heads) != 1 or i['key'] in soft_rows:
        return False
    h = next(iter(heads))
    s = series[h]
    if len(s['keys']) >= SERIES_CAP or rank(i)[0] > rank(issues[h])[0]:
        return False
    s['keys'].append(i['key'])
    s['files'] += [f for f in i['files'] if f not in s['files']]
    s['hook'] = s['hook'] or c == 'HOOK-BYPASS'
    s['lane'] = 'LOCAL?' if lane == 'LOCAL?' else 'LOCAL'  # a series is native-only: a CLOUD member makes it LOCAL
    picked.extend((f, i['key']) for f in i['files'])
    emitted.append(i)
    series_of[i['key']] = h
    for k in s['keys']:
        lane_of[k] = 'SERIES ' + h
    return True

def intake_keys():
    # versionless operator work is the pool's blind spot: it is INTAKE, so the pool is never a bare LOW while it is open
    return sorted((i['key'] for i in issues.values()
                   if not i['ver'] and i['type'] not in ('Epic', 'Sub-task') and not done_key(i['key']) and not platform_dropped(i)
                   and not any(l.startswith('residual-depth-') for l in i['labels'])
                   and not any(l.startswith('proposed-') and l != 'proposed-' + str(first_ver) for l in i['labels'])
                   and ('operator-directed' in i['labels'] or (i['type'] == 'Bug' and PRIO.get(i['prio'], 5) <= 1)
                        or (first_ver is not None and 'scope-' + first_ver in i['labels']) or i['key'] in owner
                        or (first_ver is not None and 'proposed-' + first_ver in i['labels']))),
                  key=lambda k: int(k.split('-')[1]))

def print_intake(intake):
    # no open version: the line names no version, so a reader has no --to value to take from it
    if intake:
        print('# intake %d%s: %s' % (len(intake), (' for ' + first_ver) if first_ver else '', ' '.join(intake)))

def drop_summary():
    # every To Do ticket of the active version that is not listed, by reason (--why: one line each)
    if first_ver is None:
        return
    listed = {i['key'] for i in emitted}
    todo = sorted((i for i in issues.values() if i['status'] == 'To Do' and first_ver in i['ver']), key=lambda i: int(i['key'].split('-')[1]))
    rows = []
    for i in todo:
        if i['key'] in listed:
            continue
        r = why.get(i['key'])
        if r is None:
            if i['key'] in briefs:
                r = 'resume-brief (a wrapped worker resumes it: RESUME row)'
            elif partial_resume(i['key']):
                r = 'partial-merge (a merged contract=no PR: RESUME row, or needs a chief note)'
            elif pool_only and tier_of(i) > 4:
                r = 'tier 5 (outside the priority pool)'
            else:
                r = 'below --top %d' % top
        rows.append((i['key'], r))
    counts = {}
    for _, r in rows:
        counts[r.split(' ')[0]] = counts.get(r.split(' ')[0], 0) + 1
    print('# dropped from %s: %d of %d To Do (%s)' % (first_ver, len(rows), len(todo), ', '.join('%s %d' % kv for kv in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))) or 'none'))
    if os.environ.get('ND_WHY') == '1':
        for k, r in rows:
            print('# drop %s %s' % (k, r))
    if os.environ.get('ND_DISPO') == '1':
        # one line for every open ticket of the version, listed or not: nothing is silent
        dropped = dict(rows)
        for i in sorted((i for i in issues.values() if not done_key(i['key']) and first_ver in i['ver']),key=lambda i: int(i['key'].split('-')[1])):
            k = i['key']
            if k in lane_of:
                d = 'listed ' + lane_of[k]
            elif k in dropped:
                d = dropped[k]
            elif i['type'] in ('Epic', 'Sub-task'):
                d = 'type ' + i['type']
            elif k in worker_keys or k in pr_keys:
                d = 'in-flight owned by ' + owner.get(k, 'a live worker')
            elif i['status'] == 'To Do':
                d = 'unknown (no drop reason recorded)'
            else:
                d = 'unowned %s (no worker, no open PR; not listed: held, blocked, parked or unread)' % i['status']
            print('# disposition %s %s' % (k, d))

def warn_missing():
    # a named file that is not in the repo leaves the collision check blind for that ticket
    for i in emitted:
        gone = [f for f in i['files'] if not os.path.exists(os.path.join(repo, canon(f)))]
        if gone:
            print('# warn: %s names %s (not in the repo: a new file, or the collision check is blind)' % (i['key'], ', '.join(gone)))

def emit_resume(rows):
    global n
    for i in rows:
        if n >= top:
            break
        if i['merged']:
            lane_of[i['key']] = 'MERGED-NOT-CLOSED'
            say('\t'.join(['MERGED-NOT-CLOSED', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')]))
            n += 1
            continue
        if not resume_only:
            hit = picked_hit(i)
            if hit:
                say('RESUME-HELD %s by listed %s' % (i['key'], hit[1]))
                continue
        picked.extend((f, i['key']) for f in i['files'])
        emitted.append(i)
        lane_of[i['key']] = 'RESUME'
        say('\t'.join(['RESUME', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')] + (['brief=' + briefs[i['key']]] if i['status'] == 'To Do' and i['key'] in briefs else [])
                       + ['partial=PR #%s merged, Remaining: %s' % (pr, text) for pr, text in i.get('partial', [])]))
        n += 1

classified = os.environ.get('ND_CLASSIFY') == '1'
cls_cache = {}
asked = set()

def classify_new(batch):
    fresh = [i for i in batch if i['key'] not in asked]
    asked.update(i['key'] for i in fresh)
    if fresh:
        cls_cache.update(classify(fresh))

# One classify call costs a fixed ~20 s: the first 2*--top free rows go in two parallel calls
# of --top rows each, so a refused or colliding row in the first call does not cost a serial round.
if classified and top > len(resume):
    from concurrent.futures import ThreadPoolExecutor
    ok_rows = []
    for i in free:
        if len(ok_rows) >= top * 2:
            break
        if i['key'] in design:  # a DESIGN row is not classified
            continue
        if not proof_refuse(i):
            ok_rows.append(i)
    halves = [ok_rows[:top], ok_rows[top:]]
    halves = [h for h in halves if h]
    for h in halves:
        asked.update(i['key'] for i in h)
    with ThreadPoolExecutor(max_workers=2) as pool:
        for part in pool.map(classify, halves):
            cls_cache.update(part)

seen = set()  # keys emit_free has already judged

def row_class(i):
    # (lane, class) of a classified row, or None after dropping a BLOCKED or unclassified one
    c = cls_cache.get(i['key'])
    if classified:
        if c is None or c == 'BLOCKED':
            drop(i, 'classification ' + (('BLOCKED: ' + reasons.get(i['key'], '')[:160]).rstrip(': ') if c else 'none (cloud-route gave no verdict)'))
            return None
        return ('CLOUD' if c == 'CLOUD-OK' else 'LOCAL'), c
    return 'LOCAL?', ''

def emit_stackable():
    # STACKABLE rows for the candidates that could join a live series worker, after the same proof and classification
    # gates a dispatch row passes; one that fails them drops for that reason instead
    ok = [t for t in stackable_rows if not proof_refuse(t[0])]
    if classified:
        classify_new([t[0] for t in ok])
    for i, row, reason in ok:
        if row_class(i) is None:
            continue
        drop(i, reason)
        print(row)

def emit_free(rows):
    # Classify only the slots still open, then walk on in further batches so BLOCKED rows
    # in an early batch do not leave the list short while later candidates are dispatchable.
    global n
    start = 0
    while n < top and start < len(rows):
        batch = rows[start:start + top - n]
        start += len(batch)
        batch = [i for i in batch if not proof_refuse(i)]
        if classified:
            classify_new([i for i in batch if i['key'] not in design])
        for i in batch:
            seen.add(i['key'])
            if i['key'] in design:  # the design dispatch: no lane, and it holds no files against the rest of the list
                emitted.append(i)
                lane_of[i['key']] = 'DESIGN'
                say('\t'.join(['DESIGN', i['key'], design[i['key']], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')]))
                n += 1
                if n >= top:
                    break
                continue
            rc = row_class(i)
            if rc is None:
                continue
            lane, c = rc
            # one writer per file: a listed ticket holds its files against the rest of the list
            hit = picked_hit(i)
            if hit:
                if not (stacked and join_series(i, lane, c)):
                    drop(i, 'collision %s held by listed %s' % hit)
                continue
            list_free(i, lane, c, '\t'.join([lane, i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')] + (['hook'] if c == 'HOOK-BYPASS' else [])))
            n += 1
            if n >= top:
                break
        if n >= top:
            break
    while stacked and n >= top:
        # the list is full, but a ticket that joins a listed series takes no slot: still offer it the join. A join widens the
        # series' files, so scan again until a pass joins nobody
        late = [i for i in rows if i['key'] not in seen and i['key'] not in why and i['key'] not in design and picked_hit(i) and not proof_refuse(i)]
        if classified:
            classify_new(late)
        joined = False
        for i in late:
            rc = row_class(i)
            if rc is not None and join_series(i, *rc):  # a ticket that cannot join stays below --top, as before
                seen.add(i['key'])
                joined = True
        if not joined:
            break

if pool_only:
    # tier by tier: a tier's worker-less In Progress rows lead its To Do rows
    for t in (1, 2, 3, 4):
        emit_resume([i for i in resume if tier_of(i) == t])
        if not resume_only:
            emit_free([i for i in free if tier_of(i) == t])
    flush_rows()
    if not resume_only:
        emit_stackable()
        intake = intake_keys()
        print('# pool=%d/%d%s' % (n, top, (',INTAKE:%d' % len(intake)) if intake else (',LOW' if n < top else '')))
        print_intake(intake)
    if n == 0 and not resume_only:  # nothing in the pool, or every pool ticket was classified BLOCKED or collided
        print('POOL-EMPTY')
        # the next tier, in rank order and unclassified: for the chief to read, never to dispatch
        for i in [i for i in next_tier if i['key'] not in worker_keys and i['key'] not in pr_keys and not held_hit(i)][:top]:
            print('\t'.join(['NEXT-TIER', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')]))
    warn_missing()
    if not resume_only:
        drop_summary()
    sys.exit(0)
emit_resume(resume)
if resume_only:
    flush_rows()
    warn_missing()
    sys.exit(0)
emit_free(free)
flush_rows()
emit_stackable()
warn_missing()
drop_summary()
if os.environ.get('ND_DISPO') == '1':
    print_intake(intake_keys())  # the tick counts INTAKE= from the snapshot (HIMMEL-8336)
PY
