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
# blocked_by link (focus-chains-links.sh writes the chief's chain order as
# those links). Rank: earliest unreleased fixVersion (HIMMEL.versions.tsv,
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
# that are operator-directed, a Bug of High or above, labelled scope-<earliest version> or proposed-<earliest version>, or held by a worker or
# open PR make it `,INTAKE:<m>` instead (never a bare LOW) plus a `# intake <m> for <version>: <keys>` line; an empty
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
# Soft edges: behind the `chain_soft_edges` flag (scripts/lib/flags.sh; off by default) a
# candidate held only by open PRs is not dropped for the file collision when the overlap is
# small and merges clean: every holder is an open PR, the overlap is at most 2 files, none is
# a ci-trust path, and each holder's head merges into main with `git merge-tree` without a
# conflict. Such a ticket is listed, preceded by a `# SOFT <holders> <files> for <KEY>` line.
# With the flag off the output is unchanged.
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

# chain_soft_edges (scripts/lib/flags.tsv): off keeps the collision drop below exactly; on keeps a
# ticket whose files overlap an open PR when the trial merge is clean.
soft=0
# shellcheck source=scripts/lib/flags.sh
# shellcheck disable=SC1091
if . "$REPO/scripts/lib/flags.sh" 2>/dev/null && himmel_flag chain_soft_edges 2>/dev/null; then soft=1; fi  # swallow-ok: an unreadable registry or a bad value is flag off, today's behaviour
export ND_SOFT="$soft" ND_GIT_DIR="${NEXT_DISPATCH_GIT_DIR:-$REPO}" ND_MAIN_REF="${NEXT_DISPATCH_MAIN_REF:-origin/main}"
export ND_TOP="$top" ND_MIRROR="$mirror" ND_WORKERS_FROM="$workers_from" ND_HELD="$held" ND_CLASSIFY="$classify" ND_REPO="$REPO" ND_RESUME_ONLY="$resume_only" ND_OWNERS="$owners" ND_DOC="$doc" ND_POOL_ONLY="$pool_only" ND_WORKERS="$workers" ND_WHY="$why" ND_DISPO="$dispo" ND_LEDGER="$ledger"
exec python3 -I - <<'PY'
import datetime, json, os, re, subprocess, sys, tempfile, time

top = int(os.environ['ND_TOP']); mirror = os.environ['ND_MIRROR']
repo = os.environ['ND_REPO']
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

soft_edges = os.environ.get('ND_SOFT') == '1'
soft_rows = {}  # key -> the `# SOFT` text of a listed ticket whose file overlap is soft
trust_res = []
if soft_edges:
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
    if not soft_edges or trust_res is None or not trust_res or not hits:
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
        'prio': unq(fm_val(fm, 'priority')), 'labels': set(re.findall(r'"([^"]+)"', fm_val(fm, 'labels'))),
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
# ("Windows service stops unexpectedly") is a bug report on the dropped platform and stays dropped
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
done_pending = set()
try:
    for line in open(os.path.join(os.path.dirname(workers.rstrip('/')), 'status-events.jsonl')):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get('event') == 'merge' and r.get('contract') == 'yes':
            done_pending.add(str(r.get('key', '')).upper())
except OSError:
    pass

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

# every hard blocker of a candidate is read live, whatever the mirror says; so is every blocker of an in-work ticket (RESUME rows)
live_fetch([b for i in issues.values() if reaches_blocker_check(i) for b in i['blocked_by']]
           + [b for i in issues.values() if i['status'] in ('To Do', 'In Progress', 'In Review', 'IN CI') and i['type'] not in ('Epic', 'Sub-task')
              for b in i['blocked_by']])
print('# source live_reads=%d' % len(live_cache))
skipped_platform = []
cands = []
for i in issues.values():
    if i['status'] != 'To Do' or i['key'] in briefs:
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
    cands.append(i)
cands.sort(key=ranked)
pool_only = os.environ.get('ND_POOL_ONLY') == '1'
next_tier = [i for i in cands if tier_of(i) > 4]
if pool_only:
    cands = [i for i in cands if tier_of(i) <= 4]

# held files: live workers, open PRs, --held
held = []
workers_from = os.environ.get('ND_WORKERS_FROM', '')
workers_unknown = False
worker_keys = set(os.environ.get('ND_OWNERS', '').split())
owner = {k: 'the --owners list' for k in worker_keys}
resume_only = os.environ.get('ND_RESUME_ONLY') == '1'
if workers_from and not os.path.isfile(workers_from):
    workers_unknown = True
if workers_from and os.path.isfile(workers_from):
    try:
        for worker in json.load(open(workers_from)).get('legs', []):
            doc = worker.get('doc', '')
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
            if os.environ.get('ND_WHY') == '1':
                for f in dict.fromkeys(mine):
                    if not concrete(f):
                        print('# warn: %s holds directory %s' % (worker.get('label', '?'), f))
            if not mine and not any(lines[i][len(WRITES_LEAD):].strip() == 'none named' for i in starts if lines[i].startswith(WRITES_LEAD)):  # "none named" is what gen-briefs writes for a worker that writes nothing
                workers_unknown = True  # a scope that yields no paths could be hiding the worker's files
                print('next-dispatchable: live worker %s yields no held paths (no Writes line or scope clause in %s): its files are unknown' % (worker.get('label', '?'), os.path.basename(doc)), file=sys.stderr)
    except (OSError, ValueError):
        workers_unknown = True
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

# In-work tickets nobody holds (and wrapped To Do ones): no worker, no open PR, not parked or blocked.
resume = []
resume_held = []  # (key, holder) of in-work tickets a collision keeps off the list
for i in issues.values():
    if pool_only and (tier_of(i) > 4 or i['key'] in prio_cloud):
        continue
    wrapped = i['status'] == 'To Do' and i['key'] in briefs
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
    resume.append(i)
resume.sort(key=ranked if pool_only else rank)

free = []
for i in cands:
    if i['key'] in worker_keys or i['key'] in pr_keys:  # a live worker or an open PR already owns the ticket
        drop(i, 'owned by ' + owner.get(i['key'], 'a live worker'))
        continue
    hit = held_hit(i)
    if hit:
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
emitted = []
lane_of = {}  # key -> how a listed ticket was listed

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
            print('\t'.join(['MERGED-NOT-CLOSED', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')]))
            n += 1
            continue
        if not resume_only:
            hit = picked_hit(i)
            if hit:
                print('RESUME-HELD %s by listed %s' % (i['key'], hit[1]))
                continue
        picked.extend((f, i['key']) for f in i['files'])
        emitted.append(i)
        lane_of[i['key']] = 'RESUME'
        print('\t'.join(['RESUME', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')] + (['brief=' + briefs[i['key']]] if i['status'] == 'To Do' and i['key'] in briefs else [])))
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
        if not proof_refuse(i):
            ok_rows.append(i)
    halves = [ok_rows[:top], ok_rows[top:]]
    halves = [h for h in halves if h]
    for h in halves:
        asked.update(i['key'] for i in h)
    with ThreadPoolExecutor(max_workers=2) as pool:
        for part in pool.map(classify, halves):
            cls_cache.update(part)

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
            classify_new(batch)
        for i in batch:
            c = cls_cache.get(i['key'])
            if classified:
                if c is None or c == 'BLOCKED':
                    drop(i, 'classification ' + (('BLOCKED: ' + reasons.get(i['key'], '')[:160]).rstrip(': ') if c else 'none (cloud-route gave no verdict)'))
                    continue
                lane = 'CLOUD' if c == 'CLOUD-OK' else 'LOCAL'
            else:
                lane, c = 'LOCAL?', ''
            # one writer per file: a listed ticket holds its files against the rest of the list
            hit = picked_hit(i)
            if hit:
                drop(i, 'collision %s held by listed %s' % hit)
                continue
            picked.extend((f, i['key']) for f in i['files'])
            emitted.append(i)
            lane_of[i['key']] = lane
            if i['key'] in soft_rows:
                print('# SOFT %s for %s' % (soft_rows[i['key']], i['key']))
            print('\t'.join([lane, i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')] + (['hook'] if c == 'HOOK-BYPASS' else [])))
            n += 1
            if n >= top:
                break
        if n >= top:
            break

if pool_only:
    # tier by tier: a tier's worker-less In Progress rows lead its To Do rows
    for t in (1, 2, 3, 4):
        emit_resume([i for i in resume if tier_of(i) == t])
        if not resume_only:
            emit_free([i for i in free if tier_of(i) == t])
    if not resume_only:
        # versionless operator work is the pool's blind spot: it is INTAKE, so the pool is never a bare LOW while it is open
        intake = sorted((i['key'] for i in issues.values()
                         if not i['ver'] and i['type'] not in ('Epic', 'Sub-task') and not done_key(i['key']) and not platform_dropped(i)
                         and not any(l.startswith('residual-depth-') for l in i['labels'])
                         and ('operator-directed' in i['labels'] or (i['type'] == 'Bug' and PRIO.get(i['prio'], 5) <= 1)
                              or (first_ver is not None and 'scope-' + first_ver in i['labels']) or i['key'] in owner
                              or (first_ver is not None and 'proposed-' + first_ver in i['labels']))),
                        key=lambda k: int(k.split('-')[1]))
        print('# pool=%d/%d%s' % (n, top, (',INTAKE:%d' % len(intake)) if intake else (',LOW' if n < top else '')))
        if intake:
            print('# intake %d for %s: %s' % (len(intake), first_ver or 'no open version', ' '.join(intake)))
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
    warn_missing()
    sys.exit(0)
emit_free(free)
warn_missing()
drop_summary()
PY
