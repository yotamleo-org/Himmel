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
# --why-ticket KEY [--body-file FILE] judges one ticket without GitHub or fleet
# outside reads. It prints all GATE KEY name: detail lines (exit 1), READY KEY
# (exit 0), or UNKNOWN KEY: reason (exit 3). Bad keys/combinations are usage (2).
# --mirror, --doc, --workers-dir and --no-classify are accepted; listing flags
# are refused. A body file replaces this key only, with optional mirror front matter.
#
# Source: the Jira mirror (`jira ... mirror`, one <KEY>.md per issue). A
# candidate is a To Do issue that is not an Epic/Sub-task, has no contract=yes
# merge row in status-events.jsonl (merged to Done, the mirror lags), carries none of
# the operator-decision / blocked labels (EXCLUDE_LABELS) and has no unresolved
# blocked_by link. Rank: earliest unreleased fixVersion (HIMMEL.versions.tsv,
# natural order; none last), then priority, then key.
#
# Tiers (the first that applies; tier_of() in the script): 1 the operator pool
# head: label ps3-blocker / must-<earliest unreleased version>, or a key on the ordered `priority:` line
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
# order, unclassified, with their `# overlap` lines), never dispatched from here.
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
# Partial-merge rows: a ticket with a merged contract=no PR reads that PR's remainder, a `Remaining:` line or the
# `deferred -> <KEY>` lines under `## Ticket coverage` (scripts/lib/pr_remainder.py, the one reader merge-on-green.sh and
# the brief generator share). A remainder kept on the ticket is a RESUME row (`partial=PR #n merged, Remaining: <text>`); one
# handed wholly to other tickets prints `HANDED-OFF <KEY>: remainder on <keys>` (the chief closes the ticket or keeps it as an
# umbrella by hand); a chief/operator step (`owed -> chief|operator|proof by YYYY-MM-DD`) prints
# `OWED <KEY>: merged PR #n owes <who> by <date>`; proof instead lists as an executable proof RESUME row. A body with
# neither form prints `NEEDS-CHIEF-NOTE` naming the PR and the line that clears it. PRs read in
# merge order: a clear remainder supersedes every older PR that records none; a PR newer than it that records none still asks.
# A newer hand-off or owed PR also supersedes an older `remaining` PR.
#
# Scope: a ticket waits only on the files its next step writes. That is the latest `Remaining:` text when it names a write path or
# the reader answers that it writes nothing: every slice of each `Remaining:` line (cut at a `, S<n>` or `; S<n>` label
# outside parentheses), every deferred line kept on the ticket and every malformed owed line says so (no code, no repo write,
# chief-run, state repo). Else a `Writes:` or `Files:` line of the description, else the description's paths, comments left out.
# A path a text only runs (`run`, `bash <path>`) holds nothing, unless a line naming it edits it or reports it broken. A ticket with no path and no such statement prints `NEEDS-CHIEF-NOTE <KEY>: no readable scope` and
# is not listed; those rows stop at --top, best ranked first, and --why prints them all. --why also prints `# scope <KEY> <source>: <paths> reads=<paths>`
# and `(from <source>)` on an `# overlap` line. A ticket whose next step is stated to write nothing (a `Writes:` line with no path and
# that statement, or a remainder with no path and that statement) lists with files=- and a trailing `proof` field, and --why adds ` nowrite` after its source.
#
# Overlaps (no file holds): a shared file never keeps a ticket off the list. A To Do or RESUME row that names a file
# a live worker, the --held list, an open PR, a series ledger or an earlier listed row also names is listed all the same, and
# `# overlap <KEY> <file> with <holder>` follows it (`live worker <N>`, `held list`, `open PR <n>`, `series <sid>`, `listed <KEY>`),
# so the chief sees the shared file and the merge-forward duty covers the conflict.
# A DISPOSITION ... BLOCKED-BY comment hides nothing here: stuck-scan.sh re-checks it.
#
# DESIGN rows (always on):
# the built jira CLI (`release core-check`, then `release spec-check` for the core keys; NEXT_DISPATCH_JIRA_CLI replaces
# its path) says which To Do candidates are core. A core one with no signed minerva spec prints
# `DESIGN<TAB><KEY><TAB>NO-SPEC|SPEC-STALE|BYPASS-NEEDS-SPEC<TAB>prio<TAB>version<TAB>title<TAB>files=...` instead of a dispatch row: it takes a
# --top slot, holds no files, and is the design leg to dispatch first. A key the mirror lacks is withheld
# (`# drop <KEY> core-unknown`); a check that cannot run lists no To Do row and prints `# WARN CORE-CHECK-FAILED <reason>`.
#
# Chain workers: with --workers-from naming a `<prefix>-nextleg-<date><letter>-<name>.fleet.json`,
# the other manifests of that chain in the same directory (same prefix and name, any letter) also own their live
# workers' tickets, so a worker the other chief armed after `chief.sh next` copied the manifest is not offered
# again. Ownership of the ticket only: affirmative shared terminal evidence clears it;
# unknown or inactive-looking siblings remain protected. Where the
# handover root has a queue-lock dir, a doc past its first hour also needs a lock on its ticket with a heartbeat inside QUEUE_LOCK_TTL_SECONDS.
#
# Wrapped tickets: a To Do ticket whose worker record (--workers-dir, default
# $TICKET_STATUS_STATE_DIR/workers or ~/.himmel/state/workers) is in state wrapped
# with a resume_brief is a RESUME row carrying `brief=<path>`, filtered like the
# In Progress / In Review RESUME rows, and is never an ordinary To Do row. A
# ticket with a contract=yes merge row in the status-events.jsonl beside that dir
# (its Done write is pending) is never a RESUME row.
#
# Overlap sources: a candidate's scope (see Scope above) is compared with (a) the files in the live workers' docs (the
# manifest's `workers[].doc`, their `> **Writes:**` line through holds.py parse), (b) the diff of every open PR (gh), and
# (c) --held FILE (one path per line). A directory a ticket names is context and overlaps
# nothing. Any other path overlaps an equal held path; a concrete
# file (one the repo holds, or a new one with a dotted basename) also overlaps a
# directory a worker's write scope or --held names above it; an open PR's diff is files,
# compared exactly. Two listed tickets overlap on an equal file only. Paths compare after the rename registry
# (scripts/lib/rename-aliases.tsv, kind directory) maps a pre-rename spelling to its new one.
# An open PR's files come from the paginated files API (`gh api --paginate`, filename and
# previous_filename), one PR at a time. A holder whose files cannot be read (a PR whose read fails: HTTP 406 over 300 files by
# `gh pr diff`, a timeout, the API's 3000-file cap; a live worker whose doc names no Writes line; an unreadable series ledger)
# prints `# overlap unknown for PR <n>` / `live worker <N>` / `series ledger <n>` under the header and gates no row.
# What still gates: an open-PR LIST that fails (the list is printed with an `open PRs unknown` header and no RESUME or
# IN CI row, rather than silently trusting an empty set) and a live-worker manifest that cannot be read (`live workers unknown`).
# An open PR that is not ours (cross-repository) and has been idle OUTSIDE_OWN_DAYS (7) or more days no longer owns a ticket key
# its title names: the ticket is listed with `# overlap <KEY> also named by outside PR <n> (idle <d>d)`.
#
# Series ledgers (stacked_series only): each ledger under the --workers-from manifest's `series/` directory, read through
# chief-kit/series-ledger.py read, names every non-abandoned item's writes as `series <sid>`, so the files stay an overlap
# between a predecessor's WRAPPED and its successor's launch. A published item stops holding once gh reports every PR of its
# publish_branch merged or closed. A ledger whose writer doc has no LIVE bullet and no manifest entry 2 h after the newest
# pass (a series with no pass: after the ledger's last write) prints `SERIES-ORPHAN <sid> <writer doc>`. With the flag off
# the ledgers are not read and the output is as without them.
#
# Drops: every To Do ticket of the earliest unreleased version that is not listed
# is counted by reason on a `# dropped from <version>:` line (owned,
# blocker, type, label, platform, residual-depth, classification, below --top ...; a shared file is no reason);
# --why adds one `# drop <KEY> <reason>` line each, and one `# why <KEY> listed <lane> tier <n>` line each for the listed ones; --why with no
# --top lists up to 50 rows (the fleet cap), so the RESUME rows do not fill the default 8 slots and hide the
# To Do rows the waiter counts. --dispositions adds `# disposition <KEY> <class> <holder, blocker or question>`
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
# BLOCKED is never lifted: the drop carries its reason.
#
# Classification: the survivors go through scripts/lanes/cloud-route.mjs
# --classify-only (the same gates as /cloud-route). CLOUD-OK prints CLOUD;
# LOCAL-NATIVE prints LOCAL; HOOK-BYPASS prints LOCAL with `hook` (the worker needs
# the hook-integrity bypass launch); BLOCKED is dropped. --no-classify prints
# every survivor as LOCAL? (no Jira or gh read for the class). A row that writes nothing ends in `proof` and never carries `hook`.
# When its proof needs a step only the operator or the chief can stage (scripts/handover/chief-kit/proof_staging.py: a credential,
# a token, a read-secrets relaunch, a bypass launch, a go code, a throwaway repo, a GO file) the last field is `proof-staging=<needs>`
# instead of `proof`, and an `OWED` line with a chief-owed step ends ` proof-staging=<needs>`; --why prints
# `# staging <KEY> <need> (<who>): "<words>"`. An input it cannot read is the need `unknown`.
#
# Output, one line per ticket, tab-separated:
#   <LOCAL|CLOUD> <KEY> <priority> <fixVersion|-> <title> files=<a,b|->  [hook|proof|proof-staging=<needs>]
#
# GitHub reads ride the read token through scripts/lib/gh-read.sh (main when none is configured), with no fallback to
# main on a rate limit.
#
# GitHub out: a preflight (scripts/lib/gh-quota.sh ghq_scan_gate, GraphQL and core, on the token the reads ride:
# ghq_scan_token; the classifier's searches ride main, so with it on main's GraphQL is gated too) that finds a
# bucket under the floor or a probe timed out, or a gh read during the run that names a rate limit or times out (the
# classifier's stderr or a classifier timeout too), makes the WHOLE stdout one line, `# quota-pause QUOTA-PAUSE …` or `# gh-stall GH-STALL …`, exit 0:
# no rows, no RESUME-HELD, no POOL-EMPTY, since the unread rows are unknown, not empty. After the first refused or
# stalled read every later gh read fails at once and classification is skipped. NEXT_DISPATCH_DEADLINE (seconds,
# default 400, under the waiter's 420; 0 = none) bounds the whole run, preflight included, and a cut prints `# gh-stall`.
# NEXT_DISPATCH_GH_TIMEOUT (seconds) replaces every gh read's own bound (60 or 120) and the classifier's 300.
#
# Env (tests): NEXT_DISPATCH_MIRROR, NEXT_DISPATCH_GH_CMD (replaces `gh`, the quota probes' too; with no HIMMEL_QUOTA_DIR
# its readings go to a temp quota dir removed at exit, never the station's quota.tsv),
# NEXT_DISPATCH_CLASSIFY_CMD (replaces cloud-route.mjs; called with the keys),
# NEXT_DISPATCH_JIRA_CMD (replaces the jira CLI for the live blocker read; called `get KEY`),
# NEXT_DISPATCH_EXCLUDE_LABELS (comma list, replaces the default),
# NEXT_DISPATCH_READER (replaces scripts/lib/pr_remainder.py, run as `python3 -I <file> --full-units <KEY>` by the listing and
# `--units <KEY>` by --why-ticket on a breadcrumb; NO_WRITE_RE, the supersede rule and the answer vocabulary are always loaded
# from the real scripts/lib/pr_remainder.py).
#
# Exit: 0 printed (possibly nothing); 2 usage; 3 the mirror directory is missing or unreadable, or scripts/lib/pr_remainder.py
# cannot be loaded.
# PLATFORM GUARD: the chief kit is Linux-only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

# shellcheck source=../../lib/jira-project.sh
. "$REPO/scripts/lib/jira-project.sh"
top=8; top_set=0; mirror="${NEXT_DISPATCH_MIRROR:-$(jira_mirror_dir)}"
workers_from="${WORKERS_FROM:-}"; held=""; classify=1; resume_only=0; owners=""; doc=""; pool_only=0; why=0; dispo=0
why_ticket=""; body_file=""; nd_list_flags=0
nd_usage() {
    echo 'usage: next-dispatchable.sh --why-ticket KEY [--body-file FILE] [--mirror DIR] [--doc CHIEF_DOC] [--workers-dir DIR] [--no-classify]; or listing flags --top --why --dispositions --priority-pool-only --resume-only --owners --workers-from --held' >&2
    exit 2
}
workers="${TICKET_STATUS_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/workers"
while [ "$#" -gt 0 ]; do
    case "$1" in --top|--why|--dispositions|--priority-pool-only|--resume-only|--owners|--workers-from|--held) nd_list_flags=1 ;; esac
    case "$1" in
        --why-ticket) [ "$#" -ge 2 ] && [ -n "$2" ] || nd_usage; why_ticket="$2"; shift 2 ;;
        --body-file) [ "$#" -ge 2 ] && [ -n "$2" ] || nd_usage; body_file="$2"; shift 2 ;;
        --workers-dir) workers="${2:-}"; shift 2 || exit 2 ;;
        --resume-only) resume_only=1; classify=0; shift ;;
        --owners) owners="${2:-}"; shift 2 || exit 2 ;;
        --top) top="${2:-}"; top_set=1; shift 2 || exit 2 ;;
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
if [ -n "$why_ticket" ]; then
    [[ "$why_ticket" =~ ^[A-Z]+-[0-9]+$ ]] || nd_usage
    [ "$nd_list_flags" = 0 ] || nd_usage
elif [ -n "$body_file" ]; then nd_usage
fi
export ND_WHY_TICKET="$why_ticket" ND_BODY_FILE="$body_file"
case "$top" in ''|*[!0-9]*|0*) echo "next-dispatchable: --top needs a positive number" >&2; exit 2 ;; esac
# --why with no --top asks for the whole list, not the first 8 slots the worker-less RESUME rows fill; the
# waiter counts dispatchable work against the free slots, and 50 is the fleet cap
[ "$why" != 1 ] || [ "$top_set" = 1 ] || top=50
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
export ND_GIT_DIR="${NEXT_DISPATCH_GIT_DIR:-$REPO}" ND_MAIN_REF="${NEXT_DISPATCH_MAIN_REF:-origin/main}"
export ND_TOP="$top" ND_MIRROR="$mirror" ND_WORKERS_FROM="$workers_from" ND_HELD="$held" ND_CLASSIFY="$classify" ND_REPO="$REPO" ND_RESUME_ONLY="$resume_only" ND_OWNERS="$owners" ND_DOC="$doc" ND_POOL_ONLY="$pool_only" ND_WORKERS="$workers" ND_WHY="$why" ND_DISPO="$dispo" ND_LEDGER="$ledger" ND_HOLDS="${ND_HOLDS:-$HERE/holds.py}"
export ND_STAGING="${ND_STAGING:-$HERE/proof_staging.py}" ND_TICKET_POLICY_CLI="${ND_TICKET_POLICY_CLI:-$REPO/marketplace/plugins/himmel-ops/scripts/ticket-policy-cli.mjs}"
export ND_OWE="$HERE/owe.sh"

# shellcheck source=scripts/lib/gh-quota.sh
. "$REPO/scripts/lib/gh-quota.sh"
# shellcheck disable=SC2034  # read by the probes in gh-graphql-budget.sh
GHQ_GH_CMD="${NEXT_DISPATCH_GH_CMD:-gh}"
nd_qtmp=""; nd_out=""; nd_flags=""; nd_pred_tmp=""; nd_pid=""
nd_temp_failure() {
    if [ -n "$why_ticket" ]; then
        printf 'UNKNOWN %s: temporary storage unavailable\n' "$why_ticket"
        exit 3
    fi
    exit 1
}
trap '[ -z "$nd_out" ] || rm -f "$nd_out"; [ -z "$nd_flags" ] || rm -f "$nd_flags"; [ -z "$nd_qtmp" ] || rm -rf "$nd_qtmp"; [ -z "$nd_pred_tmp" ] || rm -rf "$nd_pred_tmp"' EXIT
if [ -n "${NEXT_DISPATCH_GH_CMD:-}" ] && [ -z "${HIMMEL_QUOTA_DIR:-}" ]; then
    nd_qtmp=$(tmpdir) || nd_temp_failure
    export HIMMEL_QUOTA_DIR="$nd_qtmp"
fi
nd_pause() {
    case "$1" in GH-STALL*) printf '# gh-stall %s\n' "$1" ;; *) printf '# quota-pause %s\n' "$1" ;; esac
    exit 0
}
nd_tok=main
if [ -z "$why_ticket" ]; then
export GH_READ_NO_MAIN_FALLBACK=1
if [ -z "${NEXT_DISPATCH_GH_CMD:-}" ] && [ -f "$REPO/scripts/lib/gh-read.sh" ]; then
    # shellcheck source=scripts/lib/gh-read.sh
    . "$REPO/scripts/lib/gh-read.sh"
    _ghr_load
    [ -n "$_GHR_TOK" ] || export GH_READ_QUIET=1
    export ND_GH_READ="$REPO/scripts/lib/gh-read.sh"
fi
nd_tok=main
[ -z "${ND_GH_READ:-}" ] || nd_tok=$(ghq_scan_token next-dispatchable)
for nd_bucket in graphql core; do
    nd_line=$(ghq_scan_gate_routed "$nd_tok" "$nd_bucket" next-dispatchable) || { [ $? -ne 75 ] || nd_pause "$nd_line"; }
done
if [ "$nd_tok" = read ] && ! { ghq_row_ok read graphql && ghq_row_ok read core; }; then
    nd_tok=main
    unset ND_GH_READ
fi
if [ "$nd_tok" = read ] && [ "$classify" = 1 ] && [ -z "${NEXT_DISPATCH_CLASSIFY_CMD:-}" ]; then
    nd_line=$(ghq_scan_gate main graphql next-dispatchable) || { [ $? -ne 75 ] || nd_pause "$nd_line"; }
fi
else
    unset ND_GH_READ
    export ND_WORKERS_FROM=""
fi
export ND_TOK="$nd_tok"
nd_deadline="${NEXT_DISPATCH_DEADLINE:-400}"
case "$nd_deadline" in ''|*[!0-9]*) nd_deadline=400 ;; esac
nd_out=$(mktemp "${TMPDIR:-/tmp}/next-dispatch-out.XXXXXX") || nd_temp_failure
nd_flags=$(mktemp "${TMPDIR:-/tmp}/next-dispatch-flags.XXXXXX") || nd_temp_failure
if [ -n "$why_ticket" ]; then
    nd_pred_tmp=$(tmpdir) || nd_temp_failure
fi
export ND_PRED_TMP="$nd_pred_tmp"
# an outer kill reaches the run's own process group through timeout, which relays the signal
trap '[ -z "$nd_pid" ] || kill -TERM "$nd_pid" 2>/dev/null; exit 143' TERM INT HUP
_TIMEOUT_BIN=""
[ "$nd_deadline" -eq 0 ] || . "$REPO/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: no timeout binary runs the scan with its per-read bounds only
export ND_FLAGS="$nd_flags"
nd_left=$((nd_deadline - SECONDS))
[ "$nd_left" -gt 0 ] || nd_left=1
${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 "$nd_left"} python3 -I - > "$nd_out" <<'PY' &
import datetime, json, math, os, re, subprocess, sys, tempfile, time

why_key = os.environ.get('ND_WHY_TICKET', '')

def unknown(reason):
    print('UNKNOWN %s: %s' % (why_key, ' '.join(str(reason).split())))
    sys.exit(3)

def load_failure(reason, rc=3):
    if why_key:
        unknown(reason)
    print('# next-dispatchable: ' + reason, file=sys.stderr)
    sys.exit(rc)

if why_key:
    def predicate_error(typ, value, traceback):
        unknown('internal error ' + typ.__name__)
    sys.excepthook = predicate_error

top = int(os.environ['ND_TOP']); mirror = os.environ['ND_MIRROR']
repo = os.environ['ND_REPO']
sys.path.insert(0, os.path.join(repo, 'scripts', 'lib'))
from env_alias import legacy_names_on
from fleet_runtime import owned_rows, WorkerStates
worker_state = WorkerStates()  # one run: each doc's worker state is asked once, and each directory's manifests are read once for all of them

RATE_LIMIT_RE = re.compile(r'rate limit|RATE_LIMIT|abuse detection|secondary rate', re.I)
rate_limited = []
timed_out = []

def gh_t(secs):
    v = os.environ.get('NEXT_DISPATCH_GH_TIMEOUT', '')
    return int(v) if v.isdigit() and int(v) > 0 else secs

def gh_bucket(argv):
    if len(argv) > 1 and argv[1] == 'api':
        return 'graphql' if 'graphql' in argv else 'core'
    return 'core' if argv[1:3] == ['pr', 'diff'] else 'graphql'

def note_flag(kind, bucket, detail, tok=None):
    if rate_limited or timed_out:
        return
    (rate_limited if kind == 'rate-limit' else timed_out).append(detail)
    try:
        with open(os.environ['ND_FLAGS'], 'a') as f:
            f.write('%s\t%s\t%s\t%s\n' % (kind, bucket, int(time.time()) if kind == 'rate-limit' else detail, tok or os.environ.get('ND_TOK') or 'main'))
    except (KeyError, OSError):
        pass  # swallow-ok: with no flag file the run prints its rows with the rate-limit WARN header, as before

def ghrun(argv, **kw):
    if rate_limited or timed_out:
        raise subprocess.SubprocessError('an earlier GitHub read was refused or stalled')
    if kw.get('timeout'):
        kw['env'] = dict(os.environ, GH_READ_TIMEOUT=str(max(1, int(kw['timeout']) - 1)))
    try:
        return subprocess.run(argv, **kw)
    except subprocess.TimeoutExpired:
        note_flag('stall', gh_bucket(argv), kw.get('timeout') or 0)
        raise
    except subprocess.CalledProcessError as e:
        if e.returncode in (124, 137):
            note_flag('stall', gh_bucket(argv), kw.get('timeout') or 0)
            raise
        err = e.stderr if isinstance(e.stderr, str) else (e.stderr or b'').decode('utf-8', 'replace')
        if RATE_LIMIT_RE.search(err):
            note_flag('rate-limit', gh_bucket(argv), err.strip().splitlines()[0][:200])
        raise


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
OUTSIDE_OWN_DAYS = 7
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

# A ticket's write scope. A `Writes:` or `Files:` line of the description wins; else the description's paths, comments left
# out. A path is a read, holding nothing, only when the text runs it and no line naming it edits it or reports it broken.
EXPLICIT_RE = re.compile(r'^\W*(writes?|files?)(?:\s+(?:likely|expected|touched))?(?:\s*\([^)\n]*\))?\W{0,3}:', re.I)
RUN_BEFORE_RE = re.compile(r"(?<![\w/.-])(?:(?:re-?)?run(?:s|ning)?(?:\s+(?:bash|sh|zsh|node|python3?))?|bash|sh|zsh|node|python3?)(?:\s+-[\w=-]+)*\s*[`\"'(]?$", re.I)
WRITTEN_RE = re.compile(r'(?<![\w/.-])(?:edit|fix|change|modify|modifies|patch|add|extend|write|rewrite|remove|delete|rename|update|replace|refactor|touch|teach|wire|move|port|implement)(?:e?s|ing|ed)?(?![\w/-])'
                        r'|(?<![\w/.-])(?:fail|crash|error|bug|regress|refus|deni|hang|stall)\w*|(?<![\w/.-])(?:wrong|broken)(?![\w/-])', re.I)
try:
    import importlib.util
    _spec = importlib.util.spec_from_file_location('pr_remainder', os.path.join(repo, 'scripts', 'lib', 'pr_remainder.py'))
    _reader = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_reader)
    NO_WRITE_RE, live_answers = _reader.NO_WRITE_RE, _reader.live_answers
except Exception as e:
    load_failure('pr_remainder.py unreadable (%s)' % e)

def split_reads(text):
    # (paths it writes, paths it only runs)
    run, written = set(), set()
    for line in text.splitlines():
        for m in FILE_RE.finditer(line):
            if RUN_BEFORE_RE.search(line[:m.start()]):
                run.update(files_in(m.group(0)))
        if WRITTEN_RE.search(line):
            written.update(files_in(line))
    named = files_in(text)
    reads = [f for f in named if f in run and f not in written]
    return [f for f in named if f not in reads], reads

def scope_of(body):
    # files, the source --why names, reads, and no_scope: nothing says what the ticket writes, not even that it writes nothing
    cut = body.find('\n## Comments')
    desc = body if cut < 0 else body[:cut]
    comments = body[cut:] if cut >= 0 else ''
    readiness = []
    for comment in re.split(r'^### ', comments, flags=re.M)[1:]:
        heading, _, text = comment.partition('\n')
        lines = [line for line in text.splitlines() if line.strip()]
        if lines and re.match(r'^readiness:', lines[0], re.I):
            readiness.append((heading.partition(' — ')[2], lines))
    if readiness:
        stamp, lines = readiness[-1]
        files, nowrite = [], False
        for line in lines:
            match = EXPLICIT_RE.match(line)
            if match and match.group(1)[0].lower() == 'w':
                files.extend(path for path in files_in(line) if path not in files)
                nowrite = nowrite or bool(NO_WRITE_RE.search(line))
        if files or nowrite:
            return dict(files=files, reads=[], no_scope=False, nowrite=not files and nowrite, src='readiness comment ' + stamp)
    explicit, kinds, nowrite_line, writes_hit = [], set(), False, False
    for line in desc.splitlines():
        m = EXPLICIT_RE.match(line)
        hits = files_in(line) if m else []
        if hits:
            explicit += [f for f in hits if f not in explicit]
            kinds.add(m.group(1)[0].lower())
            writes_hit = writes_hit or m.group(1)[0].lower() == 'w'
        elif m and m.group(1)[0].lower() == 'w' and NO_WRITE_RE.search(line):
            nowrite_line = True
    if nowrite_line and not writes_hit:
        return {'files': [], 'src': 'Writes: line', 'reads': [], 'no_scope': False, 'nowrite': True}
    if explicit:
        return {'files': explicit, 'src': 'Writes: line' if 'w' in kinds else 'Files: line', 'reads': [], 'no_scope': False, 'nowrite': False}
    files, reads = split_reads(desc)
    return {'files': files, 'src': 'description', 'reads': reads, 'no_scope': not (files or reads or NO_WRITE_RE.search(desc)), 'nowrite': False}

MARKER_RE = re.compile(r'^- \d{1,2}:\d{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED)\b')
TITLE_KEY_RE = re.compile(r'([A-Z]+)-(\d+)((?:\s*\(?\s*(?:[/+,&]\s*)+\(?\s*\d+\b)*)')  # KEY-1 / 2, KEY-1 + 2, KEY-1 (+2, +3)

def title_keys(lines):
    # every ticket a worker doc's H1 title names, `KEY-1 / 2 / 3` shorthand included: a bundle worker owns more tickets than its file name lists
    h1 = next((l for l in lines if l.startswith('# ')), '')
    return [('%s-%s' % (p, n)) for p, n, _ in TITLE_KEY_RE.findall(h1)] + \
           [('%s-%s' % (p, x)) for p, _, rest in TITLE_KEY_RE.findall(h1) for x in re.findall(r'\d+', rest)]
WRITES_LEAD = '> **Writes:**'
OWN_LINE_RE = re.compile(r'^\W*Tickets?\b|^description:')  # the lines of a doc that name the tickets it carries
PRIOR_LINE_RE = re.compile(r'Original brief|Read first|successor of|Prior art', re.I)
DOC_NAME_RE = re.compile(r'[\w.+@-]+\.md')

def owned_keys(doc, lines):
    # the tickets a live worker's doc claims. A worker with no Writes line is scope-less, so its doc says all it owns: the full keys on its
    # Ticket and description lines, and the title keys of the predecessor doc it names, count too. Over-holding a parent or prior-art key
    # costs liveness while the worker lives, never safety.
    keys = title_keys(lines)
    if any(l.startswith(WRITES_LEAD) for l in lines):
        return keys
    for l in lines:
        if OWN_LINE_RE.match(l):
            keys += re.findall(r'[A-Z]+-\d+', l)
    for l in lines:
        if PRIOR_LINE_RE.search(l):
            for name in DOC_NAME_RE.findall(l):
                prior = os.path.join(os.path.dirname(doc), os.path.basename(name))
                if os.path.isfile(prior) and os.path.realpath(prior) != os.path.realpath(doc):
                    try:
                        keys += title_keys(open(prior, encoding='utf-8', errors='replace').read().splitlines())
                    except OSError:
                        pass  # swallow-ok: an unreadable prior doc adds no key; the worker still owns the rest
    return keys
SERIES_LEAD = '> **Series:**'
SERIES_ITEM_RE = re.compile(r'(?<![\w.-])\d+\.\s+([A-Z]+-\d+)')
SERIES_ID_RE = re.compile(r'(?!\d+\.\s)(\S+)\s+(\S+)')  # "<sid> <ledger path> - read ...": what follows the lead on the Series line S2a writes
SERIES_CAP = 4
stacked = os.environ.get('ND_STACKED') == '1'  # the stacked_series flag, read by the shell wrapper

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

def held_hits(i):
    return list(dict.fromkeys((f, who) for f in i['files'] for h, who, tree in held if blocks(f, h, tree)))

unknown_notes = []

def note_unknown(what):
    line = '# overlap unknown for %s' % what
    if line not in unknown_notes:
        unknown_notes.append(line)

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

def issue_from_match(m, txt):
    fm, body = m.groups()
    key = unq(fm_val(fm, 'key'))
    t = re.search(r'^# [A-Z]+-\d+: (.*)$', body, re.M)
    return {
        'key': key, 'type': unq(fm_val(fm, 'type')), 'status': unq(fm_val(fm, 'status')), 'cat': unq(fm_val(fm, 'statusCategory')),
        'prio': unq(fm_val(fm, 'priority')), 'parent': unq(fm_val(fm, 'parent')).replace('null', ''), 'labels': set(re.findall(r'"([^"]+)"', fm_val(fm, 'labels'))),
        'ver': re.findall(r'"([^"]+)"', fm_val(fm, 'fixVersions')),
        'blocked_by': re.findall(r'[A-Z]+-\d+', re.search(r'blocked_by: (.*)', fm).group(1)) if re.search(r'blocked_by: (.*)', fm) else [],
        'title': t.group(1).strip() if t else '',
        'last': last_owed(body),
        'text': txt, 'description': (re.search(r'^## Description\n(.*?)(?=^## |\Z)', body, re.M | re.S).group(1) if re.search(r'^## Description\n(.*?)(?=^## |\Z)', body, re.M | re.S) else body.split('\n## Comments', 1)[0]),
        'comments': body.split('\n## Comments', 1)[1] if '\n## Comments' in body else '',
        'linked': [key for line in re.findall(r'^\s*(?:blocks|blocked_by): (.*)$', fm, re.M) for key in re.findall(r'[A-Z]+-\d+', line)],
        **scope_of(body),
    }

issues = {}
try:
    names = sorted(n for n in os.listdir(mirror) if re.match(r'^[A-Z]+-\d+\.md$', n))
except OSError as e:
    load_failure('mirror missing or unreadable (%s)' % e)  # an error, never an empty pool
try:
    mirror_age_min = int((time.time() - max([os.path.getmtime(os.path.join(mirror, n)) for n in names] or [os.path.getmtime(mirror)])) // 60)
except OSError:
    mirror_age_min = -1  # swallow-ok: a file that vanished between the listing and the stat leaves the age unknown, shown as -1
print('# source mirror_age_min=%d' % mirror_age_min)  # first on stdout, ahead of every warning
for n in names:
    try:
        txt = open(os.path.join(mirror, n), encoding='utf-8', errors='replace').read()
    except OSError as e:
        load_failure('mirror missing or unreadable (%s)' % e)  # a listed file that cannot be read is the same error
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S)
    if m:
        issue = issue_from_match(m, txt)
        issues[issue['key']] = issue

if why_key and os.environ.get('ND_BODY_FILE'):
    try:
        txt = open(os.environ['ND_BODY_FILE'], encoding='utf-8', errors='replace').read()
    except OSError as e:
        unknown('body file unreadable (%s)' % e)
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S)
    if txt.startswith('---\n') and not m:
        unknown('malformed body file front matter')
    fm, body = m.groups() if m else ('', '## Description\n' + txt)
    body_key = unq(fm_val(fm, 'key'))
    if body_key and body_key != why_key:
        unknown('body file key %s differs' % body_key)
    defaults = {'key': why_key, 'type': 'Task', 'status': 'To Do'}
    fm += ''.join('\n%s: "%s"' % (k, v) for k, v in defaults.items() if not fm_val(fm, k))
    txt = '---\n' + fm.strip() + '\n---\n' + body
    issue = issue_from_match(re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S), txt)
    issues[why_key] = issue
    body_mirror = os.path.join(os.environ['ND_PRED_TMP'], 'mirror')
    os.mkdir(body_mirror)
    with open(os.path.join(body_mirror, why_key + '.md'), 'w', encoding='utf-8') as f:
        f.write(txt)

try:
    _sspec = importlib.util.spec_from_file_location('proof_staging', os.environ['ND_STAGING'])
    proof_staging = importlib.util.module_from_spec(_sspec)
    _sspec.loader.exec_module(proof_staging)
except Exception as e:
    load_failure('proof_staging.py unreadable (%s)' % e)
_staged = {}

def staging_of(i):
    k = i['key']
    if k not in _staged:
        needs, txt, unread = proof_staging.needs, '', []
        try:
            txt = open(os.path.join(mirror, k + '.md'), encoding='utf-8', errors='replace').read()
        except OSError:
            unread.append('mirror file absent')
        answers = list(i.get('parts', ()))
        shown = {a.get('pr') for a in answers}
        unread += ['PR #%s body could not be read' % pr for pr in partials.get(k, []) if pr in unread_prs and pr not in shown]
        if i.get('owed_next'):
            answers.append(dict(kind='remaining', handed=[], text='; '.join(r['text'] for r in i['owed_next']), nowrite=i.get('nowrite', False),
                                chief_owed=[], chief_invalid=[], owed_lines=[]))
        _staged[k] = needs(txt, answers, unread, os.environ['ND_TICKET_POLICY_CLI'])
    return _staged[k]

def proof_field(i):
    n = staging_of(i)
    return 'proof-staging=' + ','.join(x[0] for x in n) if n else 'proof'

def staging_why(i):
    for name, who, words in staging_of(i):
        print('# staging %s %s (%s): "%s"' % (i['key'], name, who, words))

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
TIER1_LABELS = {'ps3-blocker'} | ({'must-' + first_ver} if first_ver else set())  # the must label of the earliest unreleased version only: another version's label never outranks current work
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
            txt = i['text']
            m = re.search(r'^## Description\n(.*?)(?=^## |\Z)', txt, re.M | re.S)
            with tempfile.TemporaryDirectory(dir=os.environ.get('ND_PRED_TMP') or None) as d:
                draft = os.path.join(d, 'draft.md')
                with open(draft, 'w', encoding='utf-8') as f:
                    f.write(i['description'] if why_key and os.environ.get('ND_BODY_FILE') else m.group(1) if m else '')
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
    load_failure('cannot read the dropped-platform pattern from %s' % path, 2)

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
hold_row = {}
merge_fields = {}
unconfirmed = set()


def effective_rows(path):
    """The log's lines without a pre-merge row whose PR did not merge; an unreadable log raises OSError."""
    open(path).close()
    env = None
    if why_key:
        sliced = os.path.join(os.environ['ND_PRED_TMP'], 'status-events.jsonl')
        with open(path, encoding='utf-8') as source, open(sliced, 'w', encoding='utf-8') as target:
            for line in source:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                if str(row.get('key', '')).upper() == why_key:
                    target.write(line)
        path = sliced
        env = dict(os.environ, MERGE_ROWS_GH='false')
    try:  # the helper bounds its GitHub reads, not parsing a large log: a timeout reads as an unreadable log
        r = subprocess.run([sys.executable, '-I', os.path.join(repo, 'scripts', 'lib', 'merge-rows-effective.py'), path], capture_output=True, text=True, timeout=120, env=env)
    except subprocess.TimeoutExpired:
        raise OSError('merge-rows-effective timed out')
    if r.returncode != 0:
        raise OSError(r.stderr.strip() or 'merge-rows-effective failed')
    if why_key:
        unconfirmed.update(re.findall(r'warn: PR (\d+) unreadable on GitHub', r.stderr))
    return r.stdout.splitlines()


try:
    for line in effective_rows(os.path.join(os.path.dirname(workers.rstrip('/')), 'status-events.jsonl')):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if why_key and isinstance(r, dict) and str(r.get('key', '')).upper() == why_key:
            if r.get('event') in ('hold', 'hold-release') and r.get('result') == 'moved':
                hold_row[why_key] = r
            if r.get('event') == 'merge' and r.get('contract') == 'no':
                merge_fields[(why_key, str(r.get('pr', '')))] = r
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

ref_proves_absence_memo = []

def ref_proves_absence():
    # An empty `git log --grep` proves a key is absent only from a ref whose history is whole and recent: a shallow clone stops at its
    # boundary, and a ref last updated more than the 14-day window ago lacks every merge since. Either reads as unknown, never as "no".
    if not ref_proves_absence_memo:
        ok = False
        try:
            shallow = subprocess.run(['git', '-C', os.environ['ND_GIT_DIR'], 'rev-parse', '--is-shallow-repository'], capture_output=True, text=True, timeout=60, check=True).stdout.strip()
            tip = subprocess.run(['git', '-C', os.environ['ND_GIT_DIR'], 'log', '-1', '--format=%ct', os.environ['ND_MAIN_REF']], capture_output=True, text=True, timeout=60, check=True).stdout.strip()
            ok = shallow == 'false' and time.time() - int(tip) <= 14 * 86400
        except (OSError, ValueError, subprocess.SubprocessError):
            ok = False
        ref_proves_absence_memo.append(ok)
    return ref_proves_absence_memo[0]

def cited_on_main(key, subject_only=False):
    # True: the local main ref carries a commit citing [KEY] (in its message, or in its subject only when subject_only: a squash
    # subject is the PR title). False: it does not, and the ref's history can show that. None: unknown (no such ref, git failed or
    # timed out, a shallow or stale ref with no match).
    try:
        r = subprocess.run(['git', '-C', os.environ['ND_GIT_DIR'], 'log', os.environ['ND_MAIN_REF'], '--fixed-strings', '--grep=[%s]' % key, '--max-count=50', '--format=%s'],
                           capture_output=True, text=True, timeout=60, check=True)
        if any('[%s]' % key in s for s in r.stdout.splitlines()) if subject_only else bool(r.stdout.strip()):
            return True
        return False if ref_proves_absence() else None
    except (OSError, subprocess.SubprocessError):
        return None

def merged_on_main(key):
    # Unknown fails closed in THIS direction: it counts as merged, so a To Do ticket is withheld, never dispatched on a guess.
    return cited_on_main(key) is not False

def partial_resume(key):
    # a ticket with a merged partial slice is in work: it is a RESUME row naming that slice, never a fresh To Do row
    return key in partials and key not in done_pending

# The mirror lags both ways, so a candidate's blockers are all read live once, bounded (20 s a key,
# 8 in parallel, every key read: no cap), through NEXT_DISPATCH_JIRA_CMD (`<cmd> get KEY` prints a tab line KEY, type, status, title) or the real
# jira CLI of the primary checkout. The real read runs only where the classifier is real too; an unreadable key
# is UNREADABLE (the candidate drops as blocker-unknown).
DONE_RE = re.compile(r"^(?:done|closed|resolved|in public|won['’]?t (?:do|fix))$", re.I)
# Done = the Jira statusCategory is Done (catches 'wont do', 'wont fix', ...); the status names stay as a fallback
def done_key(k):
    i = issues.get(k)
    return bool(i) and (i['cat'].strip().lower() == 'done' or DONE_RE.fullmatch(i['status'].strip()))
# a live read carries only the status name, so its Done-category names are listed here
jira_cmd = os.environ.get('NEXT_DISPATCH_JIRA_CMD')
live_on = bool(jira_cmd) or (os.environ.get('ND_CLASSIFY') == '1' and not os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD'))
if why_key and os.environ.get('ND_CLASSIFY') != '1':
    live_on = False
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
        if DONE_RE.fullmatch(live.strip()):
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
if why_key:
    live_fetch(issues.get(why_key, {}).get('blocked_by', []))
else:
    live_fetch([b for i in issues.values() if reaches_blocker_check(i) for b in i['blocked_by']]
               + [b for i in issues.values() if i['status'] in ('To Do', 'In Progress', 'In Review', 'IN CI') and i['type'] not in ('Epic', 'Sub-task')
                  for b in i['blocked_by']]
               + [b for i in issues.values() if family_candidate(i) for b in i['blocked_by']])  # a SERIES FAMILY member's blockers
print('# source live_reads=%d' % len(live_cache))
skipped_platform = []
withheld_unreadable = []
def role_of(i):
    if i['status'] == 'To Do':
        if i['key'] in briefs or (partial_resume(i['key']) and i['type'] not in ('Epic', 'Sub-task')):
            return 'RESUME'
        return 'To Do'
    if i['status'] in ('In Progress', 'In Review'):
        return 'RESUME'
    return 'IN CI' if i['status'] == 'IN CI' else None

def refusals(i, role, first=False):
    out = []
    def hit(tag, reason):
        out.append((tag, reason))
    if role == 'RESUME':
        if i['type'] in ('Epic', 'Sub-task'):
            hit('type', 'type ' + i['type'])
            if first: return out
        if i['key'] in done_pending:
            hit('done-pending', 'done-pending (a contract=yes merge row; the mirror lags)')
            if first: return out
        labels = (i['labels'] & excl) | {l for l in i['labels'] if 'parked' in l}
        if labels:
            hit('label', 'label ' + ','.join(sorted(labels)))
            if first: return out
        if pool_only:
            if i['key'] in prio_cloud:
                hit('cloud', 'cloud-only on the priority line')
                if first: return out
            if platform_dropped(i):
                hit('platform', 'platform (dropped-platform title)')
                if first: return out
            if residual_out(i):
                hit('residual', 'residual-depth %d (no residual-must line, no admissions-ledger row)' % residual_depth(i))
        return out
    if i['type'] in ('Epic', 'Sub-task'):
        hit('type', 'type ' + i['type'])
        if first: return out
    if i['key'] in done_pending:
        hit('done-pending', 'done-pending (a contract=yes merge row; the mirror lags)')
        if first: return out
    if i['labels'] & excl or re.match(r'\s*parked:', i['title'], re.I):
        hit('label', 'label ' + (','.join(sorted(i['labels'] & excl)) or 'parked: title'))
        if first: return out
    if platform_dropped(i):
        hit('platform', 'platform (dropped-platform title)')
        if first: return out
    open_b = [(b, blocker_state(b)) for b in i['blocked_by'] if blocker_state(b)]
    if open_b:
        known = ['%s (%s)' % bs for bs in open_b if bs[1] != UNREADABLE]
        unknown = [b for b, st in open_b if st == UNREADABLE]
        hit('blocker', '; '.join(([('blocker ' + ', '.join(known))] if known else []) + ([('blocker-unknown ' + ', '.join(unknown))] if unknown else [])))
        if first: return out
    if i['key'] in prio_cloud:
        hit('cloud', 'cloud-only on the priority line')
        if first: return out
    if residual_out(i):
        hit('residual', 'residual-depth %d (no residual-must line, no admissions-ledger row)' % residual_depth(i))
        if first: return out
    if status_unreadable and merged_on_main(i['key']):
        hit('status-unreadable', 'status-events.jsonl unreadable and the key has a merge on main')
        if first: return out
    return out

cands = []
for i in issues.values():
    if role_of(i) != 'To Do':
        continue
    r = refusals(i, 'To Do', first=True)
    if r:
        tag, reason = r[0]
        if tag == 'platform': skipped_platform.append(i['key'])
        if tag == 'status-unreadable': withheld_unreadable.append(i['key'])
        drop(i, reason)
        continue
    cands.append(i)
if withheld_unreadable:
    print('# WARN: status-events.jsonl is unreadable: withheld %s (a merge on main)' % ', '.join(withheld_unreadable))
cands.sort(key=ranked)
pool_only = os.environ.get('ND_POOL_ONLY') == '1'
next_tier = [i for i in cands if tier_of(i) > 4]
if pool_only:
    cands = [i for i in cands if tier_of(i) <= 4]

# The core gate (permanent): the built jira CLI says
# which To Do candidates are core and whether each has a signed minerva spec. A core ticket with no `SPEC ok` lists as a
# `DESIGN <KEY> NO-SPEC|SPEC-STALE|BYPASS-NEEDS-SPEC` row, not a build row; a gated bypass with no reviewed spec lists as a DESIGN row too.
# Fail closed: a check that cannot run lists no To Do row, and a key the mirror lacks (UNKNOWN) is withheld.
design = {}  # KEY -> NO-SPEC | SPEC-STALE | BYPASS-NEEDS-SPEC
CORE_VERBS = ('CORE', 'NOT-CORE', 'BYPASS', 'BYPASS-NEEDS-SPEC', 'UNKNOWN')
CORE_FIELDS = {'CORE': 3, 'BYPASS': 4, 'BYPASS-NEEDS-SPEC': 4}  # tokens a core-check line needs: CORE <K> <match>, BYPASS <K> <kind> <reason...>, BYPASS-NEEDS-SPEC <K> <kind> <missing...>

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

core_problem = {}

def core_spec_pass(cs):
    # the candidates that may still list (a DESIGN one is recorded in `design`); core-check takes ONE --paths per call, so
    # tickets naming the same files share a call (the calls run in parallel), then spec-check asks once for every CORE key
    mdir = body_mirror if why_key and os.environ.get('ND_BODY_FILE') else os.path.abspath(mirror)
    project = cs[0]['key'].split('-')[0]
    def fail(why):
        print('# WARN CORE-CHECK-FAILED %s' % ' '.join(why.split()))
        for i in cs:
            if why_key:
                core_problem[i['key']] = 'core check could not run: ' + ' '.join(why.split())
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
            if why_key:
                core_problem[i['key']] = 'core status unknown (not in the mirror)'
            drop(i, 'core-unknown (not in the mirror: neither core nor a bypass can be proven)')
            continue
        keep.append(i)
        if verb == 'BYPASS-NEEDS-SPEC':
            design[i['key']] = verb
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

if not why_key and cands and os.environ.get('ND_RESUME_ONLY') != '1':  # --resume-only lists no To Do row
    cands = core_spec_pass(cands)

# held files: live workers, open PRs, --held
held = []
series_workers = {}  # label -> {'doc', 'sid', 'ledger', 'count'} for a live worker whose brief carries a Series line (stacked_series only); count is None until known
manifest_docs = set()  # the resolved path of every worker doc the manifest lists (the orphan check asks whether a ledger's writer is among them)
workers_from = os.environ.get('ND_WORKERS_FROM', '')
workers_unknown = False
owners_unknown = False  # only a fleet whose OWNERS are unreadable hides the orphans; a worker whose FILES are unknown still owns the key in its doc name
named_unknown = False  # a named worker source could not be fully read: nothing it may own is listed
WITHHELD = 'RESUME, IN CI, STACKABLE, SERIES FAMILY, To Do, DESIGN, NEXT-TIER'
REMEDY_DOC = "restore the doc, record the worker's end, or fleet-manifest.sh remove <manifest> <label>"
REMEDY_MANIFEST = 'repair or delete the manifest file (fleet-manifest.sh refuses an invalid one)'
REMEDY_FLEET = 'restore or pass a readable --workers-from manifest'
OWNER_UNKNOWN_DROP = 'owner unknown: a named worker source could not be fully read (see the # owner unknown line)'
owner_unknown_lines = set()

def printable(text):
    if text.isascii() and text.isprintable():
        return text
    enc = sys.stdout.encoding or 'utf-8'
    shown = []
    for ch in text:
        o = ord(ch)
        if o < 32 or 127 <= o < 160 or o in (0x2028, 0x2029) or 0xD800 <= o <= 0xDFFF:
            shown.append(ch.encode('unicode_escape').decode('ascii'))
            continue
        try:
            ch.encode(enc)
            shown.append(ch)
        except UnicodeEncodeError:
            shown.append(ch.encode('unicode_escape').decode('ascii'))
    return ''.join(shown)

def owner_unknown(owner, why, remedy, keys=()):
    global named_unknown, owners_unknown, workers_unknown
    named_unknown = owners_unknown = workers_unknown = True
    held = ','.join(sorted({printable(k) for k in keys}))
    tail = '; keys held: %s' % held if held else ''
    line = '# owner unknown: %s (%s%s); withheld: %s; reconcile: %s' % (printable(owner), printable(why), tail, WITHHELD, remedy)
    if line not in owner_unknown_lines:
        owner_unknown_lines.add(line)
        unknown_notes.append(line)
live_workers = []
worker_keys = set(os.environ.get('ND_OWNERS', '').split())
owner = {k: 'the --owners list' for k in worker_keys}
resume_only = os.environ.get('ND_RESUME_ONLY') == '1'
if workers_from and not os.path.isfile(workers_from):
    owner_unknown('the fleet', 'manifest %s missing' % os.path.basename(workers_from), REMEDY_FLEET)
if workers_from and os.path.isfile(workers_from):
    try:
        manifest_workers(json.load(open(workers_from)))  # validate legacy-array policy before shared ownership
        for worker in owned_rows(workers_from):
            doc = worker.get('doc', '')
            if doc:
                manifest_docs.add(os.path.realpath(doc))
            try:
                lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
            except OSError:
                who = 'live worker %s' % printable('%s' % worker.get('label', '?'))
                dkeys = re.findall(r'[A-Z]+-\d+', os.path.basename(doc))
                for k in dkeys:
                    worker_keys.add(k); owner.setdefault(k, who)
                note_unknown(who)
                owner_unknown(who, 'doc %s unreadable' % (os.path.basename(doc) or '(none)'), REMEDY_DOC, keys=dkeys)
                continue
            marks = [m.group(1) for m in (MARKER_RE.match(l) for l in lines) if m]
            state = worker_state(doc)
            if state == 'wrapped':
                continue
            for k in re.findall(r'[A-Z]+-\d+', os.path.basename(doc)) + owned_keys(doc, lines):
                worker_keys.add(k); owner.setdefault(k, 'live worker %s' % worker.get('label', '?'))
            def block(i):  # a wrapped line continues on the "> " lines under it, up to the next "> **" field or a blank
                text = lines[i]
                for nxt in lines[i + 1:]:
                    if not nxt.startswith('> ') or nxt.startswith('> **'):
                        break
                    text += ' ' + nxt[2:]
                return text
            live_workers.append((worker.get('label', '?'), doc, lines, re.findall(r'[A-Z]+-\d+', os.path.basename(doc))))
            sl = [i for i, l in enumerate(lines) if l.startswith(SERIES_LEAD)] if stacked else []
            items = set(SERIES_ITEM_RE.findall(block(sl[0]))) if sl else set()
            sid_m = SERIES_ID_RE.match(lines[sl[0]][len(SERIES_LEAD):].strip()) if sl else None
            if items or sid_m:  # a series worker: its Series line names the sid and ledger (S2a), or its block has one numbered line per item. The count is the ledger's when it is read below; a block that names neither has an unknown count, so it offers no room
                series_workers[worker.get('label', '?')] = {'doc': doc, 'sid': sid_m.group(1) if sid_m else None,
                                                            'ledger': os.path.realpath(sid_m.group(2)) if sid_m else None, 'count': len(items) or None}
    except (OSError, ValueError):
        owner_unknown('the fleet', 'manifest %s unreadable' % os.path.basename(workers_from), REMEDY_FLEET)
# `chief.sh next` copies the manifest once, so a worker the other chief of this chain arms later is
# in no manifest but its own. Read the chain's other manifests (same bucket, same prefix and chief name, any
# letter) for ownership of a ticket only: shared terminal evidence releases it, and a sibling manifest that
# cannot be read, is refused by its shape or holds a doc that cannot be opened is an owner unknown.
def sibling_shape_refused(parsed):
    if not isinstance(parsed, dict):
        return True
    return any(k in parsed and not isinstance(parsed[k], list) for k in ('workers', 'legs'))

chain_m = re.match(r'^(.+)-nextleg-\d{4}-\d{2}-\d{2}[A-Z]+-(.+)\.fleet\.json$', os.path.basename(workers_from)) if workers_from else None
if chain_m:
    sib_dir = os.path.dirname(os.path.abspath(workers_from))
    try:
        siblings = sorted(os.listdir(sib_dir))
    except OSError:
        siblings = []
    for sib in siblings:
        sm = re.match(r'^(.+)-nextleg-\d{4}-\d{2}-\d{2}[A-Z]+-(.+)\.fleet\.json$', sib)
        if not sm or sm.groups() != chain_m.groups() or os.path.join(sib_dir, sib) == os.path.abspath(workers_from):
            continue
        spath = os.path.join(sib_dir, sib)
        sib_chief = 'the chief on %s' % sib[:-len('.fleet.json')]
        try:
            sib_manifest = json.load(open(spath))
        except Exception:
            owner_unknown(sib_chief, 'manifest %s unreadable' % sib, REMEDY_MANIFEST)
            continue
        if sibling_shape_refused(sib_manifest):
            owner_unknown(sib_chief, 'manifest %s malformed' % sib, REMEDY_MANIFEST)
            continue
        try:
            sib_workers = owned_rows(spath)
        except Exception:
            owner_unknown(sib_chief, 'manifest %s malformed' % sib, REMEDY_MANIFEST)
            continue
        for worker in sib_workers if isinstance(sib_workers, list) else []:
            sdoc = worker.get('doc') if isinstance(worker, dict) else None
            if not isinstance(sdoc, str) or not sdoc:
                continue  # an entry that names no doc owns nothing
            sfiles = re.findall(r'[A-Z]+-\d+', os.path.basename(sdoc))
            sdoc_unreadable = False
            try:
                slines = open(sdoc, encoding='utf-8', errors='replace').read().splitlines()
            except Exception:  # swallow-ok: an unreadable sibling doc is reported as an owner unknown below, never skipped
                slines = []
                sdoc_unreadable = True
            smarks = [m.group(1) for m in (MARKER_RE.match(l) for l in slines) if m]
            try:
                sstate = worker_state(sdoc)
            except Exception:  # swallow-ok: a state that cannot be asked is unknown, which still owns the doc's keys
                sstate = 'unknown'
            if sstate == 'wrapped':
                continue
            swho = 'live worker %s of the chief on %s' % (printable('%s' % worker.get('label', '?')), printable(sib[:-len('.fleet.json')]))
            for k in sfiles + owned_keys(sdoc, slines):
                worker_keys.add(k); owner.setdefault(k, swho)
            if sdoc_unreadable:
                owner_unknown(swho, 'doc %s unreadable' % os.path.basename(sdoc), REMEDY_DOC, keys=sfiles)
if pool_only and not workers_from and not worker_keys:
    workers_unknown = owners_unknown = True
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
# The remainder of a merged partial PR's body, read by the ONE reader every partial-merge site shares
# (scripts/lib/pr_remainder.py): a `Remaining:` line, or the `deferred -> <KEY>` lines under `## Ticket coverage`.
# The listing asks the reader for --full-units: one JSON answer carrying every owed unit, checked by full_answer below. A body
# gh cannot read, or a reader that fails or prints anything but a complete answer, is recorded in unread_prs and returns kind
# none, so the ticket is never dispatched blind.
remainder_cache = {}
unread_prs = set()
reader = os.environ.get('NEXT_DISPATCH_READER') or os.path.join(repo, 'scripts', 'lib', 'pr_remainder.py')  # NEXT_DISPATCH_READER: the test seam for the reader

# A merged PR's remainder, kept in a state file by PR number and ticket key so a run does not read the same merged body from
# GitHub again (628 `pr view` calls in a 30-minute sample of the fleet). Invalidation rule: an entry is used for
# NEXT_DISPATCH_BODY_TTL seconds (default 3600) after it was read, then read again; only a remainder that SAID something
# (`remaining`, `handed-off`, `owed`) is stored, so the body a chief edits to clear a NEEDS-CHIEF-NOTE row (kind none) and a body gh could not read
# are asked again on the next run. A chief who edits a body that already holds a remainder is seen within the TTL. NEXT_DISPATCH_BODY_CACHE
# names the file (`off` disables the cache); a corrupt or unwritable file reads as no cache.
body_cache_path = os.environ.get('NEXT_DISPATCH_BODY_CACHE') or os.path.join(os.environ.get('HOME') or os.path.expanduser('~'), '.himmel', 'state', 'next-dispatchable', 'merged-pr-remainders.json')
try:
    body_ttl = max(0, int(os.environ.get('NEXT_DISPATCH_BODY_TTL', '3600')))
except ValueError:
    body_ttl = 3600

FULL_MAX = 1 << 20

class DuplicateKeyDict(dict):
    pass

def _pairs(pairs):
    d = dict(pairs)
    return DuplicateKeyDict(d) if len(d) != len(pairs) else d

def _no_constant(c):
    raise ValueError('non-finite number %s' % c)

def _strs(v):
    return type(v) is list and all(type(x) is str for x in v)

def valid_answer(a):
    if type(a) is not dict or tuple(sorted(a)) != tuple(sorted(_reader.FULL_FIELDS)):
        raise ValueError('answer fields')
    kind, handed, rows = a['kind'], a['handed'], a['owed_lines']
    if kind not in _reader.ANSWER_KINDS or not _strs(handed) or type(a['text']) is not str or type(a['nowrite']) is not bool \
            or not _strs(a['chief_owed']) or not _strs(a['chief_invalid']) or type(rows) is not list:
        raise ValueError('answer field types')
    for r in rows:
        if type(r) is not dict or tuple(sorted(r)) != tuple(sorted(_reader.OWED_FIELDS)) or not all(type(v) is str for v in r.values()) \
                or r['who'] not in _reader.OWED_ACTORS:
            raise ValueError('owed row')
    if kind in ('none', 'remaining') and handed:
        raise ValueError('%s answer names a handed value' % kind)
    if kind == 'handed-off' and not handed:
        raise ValueError('hand-off names no ticket')
    if kind == 'owed':
        if len(handed) != 2 or handed[0] not in _reader.OWED_ACTORS:
            raise ValueError('owed answer shape')
        try:
            if datetime.date.fromisoformat(handed[1]).isoformat() != handed[1]:
                raise ValueError('noncanonical date')
        except ValueError:
            raise ValueError('owed date %r' % handed[1])
        if not any(r['who'] == handed[0] and r['due'] == handed[1] for r in rows):
            raise ValueError('owed answer names no owed row')
    if len(json.dumps(a, ensure_ascii=False).encode('utf-8')) > FULL_MAX:
        raise ValueError('answer over %d bytes' % FULL_MAX)
    return a

def full_answer(raw):
    if len(raw) > 2 * FULL_MAX:
        raise ValueError('answer over %d bytes' % FULL_MAX)
    env = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs, parse_constant=_no_constant)
    if type(env) is not dict or sorted(env) != ['answer', 'schema'] or type(env['schema']) is not int or env['schema'] != 1:
        raise ValueError('answer envelope')
    return valid_answer(env['answer'])

def body_cache_load():
    if body_cache_path == 'off':
        return {}
    try:
        d = json.load(open(body_cache_path, encoding='utf-8'), object_pairs_hook=_pairs)
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}

def _fresh(e):
    at = e.get('at')
    try:
        return type(at) in (int, float) and math.isfinite(at) and 0 <= time.time() - at < body_ttl
    except OverflowError:
        return False

def cached_full(pr, key):
    e = body_cache_load().get('%s:%s' % (pr, key))
    try:
        if type(e) is dict and sorted(e) == ['ans', 'at', 'schema'] and type(e['schema']) is int and e['schema'] == 1 and _fresh(e):
            a = valid_answer(e['ans'])
            if a['kind'] != 'none':
                return a
    except ValueError:
        pass  # swallow-ok: an entry that fails the check is no entry, and the body is read again
    return None

def cached_remainder(pr, key):
    e = body_cache_load().get('%s:%s' % (pr, key))
    if isinstance(e, dict) and 'schema' in e:
        a = cached_full(pr, key)
        return None if a is None else {f: a[f] for f in ('kind', 'handed', 'text', 'nowrite', 'chief_owed')}
    try:
        age = time.time() - float(e['at'])
        kind, handed, text, nowrite, chief_owed = e['ans']
        if 0 <= age < body_ttl and kind in ('remaining', 'handed-off', 'owed') and isinstance(handed, list) and isinstance(text, str) \
                and isinstance(nowrite, bool) and isinstance(chief_owed, list):
            return dict(kind=kind, handed=[str(h) for h in handed], text=text, nowrite=nowrite, chief_owed=[str(t) for t in chief_owed])
    except (KeyError, TypeError, ValueError, OverflowError):
        pass  # swallow-ok: an entry that cannot be read is no entry
    return None

def store_remainder(pr, key, ans):
    if body_cache_path == 'off':
        return
    try:
        d = body_cache_load()
        now = time.time()
        d = {k: v for k, v in d.items() if isinstance(v, dict) and _fresh(v)}
        d['%s:%s' % (pr, key)] = {'schema': 1, 'at': now, 'ans': {f: ans[f] for f in _reader.FULL_FIELDS}}
        os.makedirs(os.path.dirname(body_cache_path), exist_ok=True)
        tmp = '%s.%d' % (body_cache_path, os.getpid())
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(d, f)
        os.replace(tmp, body_cache_path)
    except (OSError, ValueError):
        pass  # swallow-ok: a cache that cannot be written costs the next run one more read

def remainder_of(pr, key):
    if (pr, key) not in remainder_cache:
        ans = dict(kind='none', handed=[], text='', nowrite=False, chief_owed=[])
        hit = cached_full(pr, key)
        if hit is not None:
            remainder_cache[(pr, key)] = hit
            return hit
        try:
            body = ghrun([gh, 'pr', 'view', pr, '--repo', gh_repo, '--json', 'body', '--jq', '.body'], capture_output=True, timeout=gh_t(60), check=True).stdout.decode('utf-8', 'replace')
            out = subprocess.run([sys.executable, '-I', reader, '--full-units', key], input=body.encode('utf-8'), capture_output=True, timeout=60, check=True).stdout
            try:
                ans = full_answer(out)
            except ValueError:
                raise subprocess.SubprocessError('unrecognised reader answer')
            if ans['kind'] != 'none':
                store_remainder(pr, key, ans)
        except (OSError, subprocess.SubprocessError):
            unread_prs.add(pr)
        remainder_cache[(pr, key)] = ans
    return remainder_cache[(pr, key)]

def resume_eligible(i):
    # the gates an in-work ticket (or a wrapped To Do one) passes whoever holds its files
    if pool_only and (tier_of(i) > 4 or i['key'] in prio_cloud):
        return False
    if role_of(i) not in ('RESUME', 'IN CI'):
        return False
    return not refusals(i, 'RESUME', first=True)


def override_from_parts(i, parts):
    i['parts'] = parts
    latest = [p for p in i['parts'] if p['kind'] == 'remaining'][-1:]
    proof_parts = [p for p in i['parts'] if p['kind'] == 'owed' and p['handed'][0] == 'proof']
    if proof_parts and not latest:
        i.update(files=[], reads=[], src='remainder of PR #%s' % proof_parts[-1]['pr'], no_scope=False, nowrite=True,
                 proof_only=True, proof_due=proof_parts[-1]['handed'][1])
    if latest:
        files, reads = split_reads(latest[0]['text'])
        nowrite = not files and latest[0]['nowrite']
        if files or nowrite:
            i.update(files=files, reads=reads, src='remainder of PR #%s' % latest[0]['pr'], no_scope=False, nowrite=nowrite)

def apply_owed_scope(issues, actions, worker_keys, pr_keys):
    closed = {r['id']: r for r in actions if r['closed'] and r.get('action') == 'validate-proof'}
    latest_validation = {r.get('key'): r['id'] for r in actions if r.get('action') == 'validate-proof'}
    # The proof step stays open until the chief's outcome, so while the newest validation of a key is open the original
    # proof-owned scope is the chief's to settle: no second paid run. A code scope of the same ticket is a different unit.
    open_validation = {r['id'] for r in actions if not r['closed'] and r.get('action') == 'validate-proof'}
    for key, vid in latest_validation.items():
        i = issues.get(key)
        if vid in open_validation and i and i.get('proof_only') and key not in worker_keys and key not in pr_keys:
            i['owed_wait'] = {'id': vid, 'actor': 'chief', 'due': i.get('proof_due', '')}
    replacements = {}
    for action in actions:
        parent = closed.get(action.get('source_id'))
        if not action['closed'] and action.get('action') == 'next-step' and action.get('actor') in ('proof', 'worker', 'chief', 'operator') and parent and parent.get('key') == action.get('key') and latest_validation.get(action.get('key')) == parent['id']:
            replacements.setdefault(action['key'], []).append(action)
    for key, steps in replacements.items():
        i = issues.get(key)
        if not i or key in worker_keys or key in pr_keys:
            continue
        runnable = [s for s in steps if s['actor'] in ('proof', 'worker')]
        if not runnable:
            i['owed_wait'] = min(steps, key=lambda s: s.get('due', ''))
            continue
        steps = runnable
        code = [s for s in steps if s['actor'] == 'worker']
        files, reads = split_reads('; '.join(s['text'] for s in code)) if code else ([], [])
        i.update(files=files, reads=reads, src='owed next step ' + ','.join(s['id'] for s in steps),
                 no_scope=bool(code) and not files, nowrite=not code, owed_next=steps)

def read_owed_actions():
    bucket = os.path.dirname(os.environ.get('ND_DOC') or os.environ.get('ND_WORKERS_FROM') or '')
    if not bucket or not os.path.lexists(os.path.join(bucket, 'owed.jsonl')):
        return []
    result = subprocess.run(['bash', os.environ['ND_OWE'], 'list', '--bucket', bucket, '--all', '--json'],
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError('owed reader refused')
    actions = json.loads(result.stdout)
    if not isinstance(actions, list):
        raise ValueError('owed reader returned no action list')
    return actions

def predicate_remainder(i):
    answers, problems = [], []
    for pr in partials.get(i['key'], []):
        answer = cached_remainder(pr, i['key'])
        if answer is not None:
            answers.append(dict(answer, pr=pr))
            continue
        row = merge_fields.get((i['key'], pr), {})
        kind = row.get('remainder')
        text = None
        for comment in re.split(r'^### ', i['comments'], flags=re.M)[1:]:
            marker = re.search(r'PR #%s \(.*?as a partial merge; the ticket is not complete\.\s*Remaining: (.*)' % re.escape(pr), comment, re.S)
            if marker:
                text = marker.group(1).strip()
        if not kind:
            if text is None:
                problems.append('remainder of PR #%s not in the mirror' % pr)
                continue
            if text.startswith('not recorded in the PR body'):
                problems.append('remainder of PR #%s not recorded (no GitHub read)' % pr)
                continue
            if _reader.OWED_ANY_RE.search(text) or _reader.DEFERRED_RE.search(text):
                problems.append('remainder kind of PR #%s unknown without GitHub (owed or deferred text in the breadcrumb)' % pr)
                continue
            kind = 'remaining'
        answer = dict(kind=kind, handed=[], text=text or '', nowrite=False, chief_owed=[], pr=pr)
        if kind == 'remaining':
            if text is None:
                problems.append('remainder of PR #%s not yet in the mirror' % pr)
                continue
            try:
                r = subprocess.run([sys.executable, '-I', reader, '--units', i['key']], input='Remaining: ' + text,
                                   capture_output=True, text=True, timeout=60, check=True)
                fields = r.stdout.rstrip('\n').split('\t')
                sizes = {'remaining': 4, 'handed-off': 5, 'owed': 6, 'none': 3}
                if not fields or len(fields) != sizes.get(fields[0]) or fields[-2] not in ('nowrite=0', 'nowrite=1') or not fields[-1].startswith('chief-owed='):
                    raise ValueError('unrecognised --units answer')
                answer.update(nowrite=fields[-2] == 'nowrite=1', chief_owed=[t for t in fields[-1][len('chief-owed='):].split('¦') if t])
            except (OSError, ValueError, subprocess.SubprocessError) as e:
                unknown('pr_remainder.py could not read PR #%s (%s)' % (pr, e))
        elif kind == 'owed':
            who, due = row.get('owed'), row.get('owed_due')
            if who not in ('chief', 'operator', 'proof') or not isinstance(due, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', due):
                problems.append('remainder kind of PR #%s unknown without GitHub (owed owner or date missing)' % pr)
                continue
            answer['handed'] = [who, due]
        elif kind not in ('handed-off', 'none'):
            unknown('malformed remainder kind of PR #%s' % pr)
        answers.append(answer)
    return live_answers(answers), problems

def gate_detail(tag, reason):
    if tag == 'label':
        return 'title parked:' if reason == 'label parked: title' else 'labels ' + reason[len('label '):]
    if tag == 'blocker':
        details = []
        for part in reason.split('; '):
            if part.startswith('blocker-unknown '):
                details.extend(k + ' (unreadable)' for k in part[len('blocker-unknown '):].split(', '))
            else:
                details.append(part[len('blocker '):])
        return ', '.join(details)
    return reason

def prose_deps(i):
    desc = i['description']
    declared = set(i['linked']) | {i['key']}
    for line in desc.splitlines():
        if re.match(r'^\W*Edges\W{0,3}:', line, re.I):
            declared.update(re.findall(r'HIMMEL-\d+', line, re.I))
    found = {}
    for pattern in (tracker._DEP_RE, label_dep_re):
        for match in pattern.finditer(desc):
            for key in re.findall(r'HIMMEL-\d+', match.group(1), re.I):
                key = key.upper()
                if key not in declared and not done_key(key):
                    found.setdefault(key, ' '.join(match.group(0).split())[:60])
    return [(key, quote) for key, quote in found.items()]

def why_ticket(i):
    key = i['key']
    order = ('drop', 'held-label', 'open-blocker', 'blocker-no-version', 'stale-hold', 'prose-dependency', 'no-scope', 'no-proof', 'core-no-spec')
    gates = {tag: [] for tag in order}
    role = role_of(i)
    if status_unreadable and role in ('To Do', 'RESUME') and not (role == 'To Do' and merged_on_main(key)):
        unknown('status-events unreadable; merge context cannot be judged')
    if role == 'IN CI':
        gates['drop'].append('IN CI (whether a merged PR already closes it needs a GitHub read)')
    elif role is None:
        gates['drop'].append('status ' + i['status'])
    else:
        for tag, reason in refusals(i, role):
            name = 'held-label' if tag == 'label' else 'open-blocker' if tag == 'blocker' else 'drop'
            gates[name].append(gate_detail(tag, reason))
        if role == 'RESUME':
            blockers = [(b, blocker_state(b)) for b in i['blocked_by'] if blocker_state(b)]
            if blockers:
                gates['open-blocker'].append(', '.join('%s (%s)' % (b, 'unreadable' if st == UNREADABLE else st) for b, st in blockers))
        for pr in sorted(unconfirmed, key=int):
            gates['drop'].append('merge of PR #%s unconfirmed (pre-merge row; no GitHub read)' % pr)
        open_blockers = [b for b in i['blocked_by'] if blocker_state(b)]
        unversioned = [b for b in open_blockers if b in issues and not any(v in vorder for v in issues[b]['ver'])]
        if unversioned:
            gates['blocker-no-version'].append(', '.join(b + ' (no fixVersion)' for b in unversioned))
        hold = hold_row.get(key, {})
        on = hold.get('on', '')
        if 'held' in i['labels'] and hold.get('event') == 'hold' and isinstance(on, str) and re.fullmatch(r'[A-Z]+-\d+', on) and done_key(on):
            gates['stale-hold'].append('held on %s (%s); release: bash scripts/handover/chief-kit/ticket-hold.sh %s --release' % (on, issues[on]['status'], key))
        for dep, quote in prose_deps(i):
            gates['prose-dependency'].append('%s%s ("%s")' % (dep, ' (not in mirror)' if dep not in issues else '', quote))
        gates['drop'].extend(i.get('remainder_problems', []))
        parts = [] if i.get('owed_next') else i.get('parts', [])
        if i.get('owed_wait'):
            gates['drop'].append('owned next step: ' + i['owed_wait']['actor'])
        if role == 'RESUME':
            owed = [p for p in parts if p['kind'] == 'owed']
            if owed and not any(p['kind'] == 'remaining' or (p['kind'] == 'owed' and p['handed'][0] == 'proof') for p in parts):
                first_due = min(owed, key=lambda p: p['handed'][1])
                gates['drop'].append('merged PR #%s owes %s by %s' % (first_due['pr'], first_due['handed'][0], first_due['handed'][1]))
            if parts and all(p['kind'] == 'handed-off' for p in parts):
                gates['drop'].append('remainder on ' + ', '.join(k for p in parts for k in p['handed']))
        for part in parts:
            if part['kind'] == 'none':
                gates['no-scope'].append('merged PR #%s records no remainder' % part['pr'])
        if i['no_scope'] and key not in briefs:
            gates['no-scope'].append('nothing says what it writes: no Remaining: text, no readiness: Writes line, no Writes:/Files: line, no path in the description')
        if role == 'To Do':
            missing = proof_missing(i)
            if missing:
                gates['no-proof'].append('missing ' + missing)
            if key in core_problem:
                gates['core-no-spec'].append(core_problem[key])
            elif key in design:
                gates['core-no-spec'].append(design[key])
    lines = ['# scope %s %s: %s reads=%s' % (key, i['src'], ','.join(i['files']) or '-', ','.join(i['reads']) or '-')]
    for tag in order:
        if gates[tag]:
            lines.append('GATE %s %s: %s' % (key, tag, ' '.join(', '.join(gates[tag]).split())))
    refused = any(gates.values())
    if not refused:
        lines.append('READY ' + key)
    return lines, int(refused)

if why_key:
    if why_key not in issues:
        unknown('not in the mirror or the body file')
    try:
        spec = importlib.util.spec_from_file_location('tracker', os.path.join(repo, 'scripts/handover/chief-kit/tracker.py'))
        tracker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tracker)
        label_dep_re = re.compile(r'^\s*(?:[-*]\s+)?[*_]*(?:depends\s+on|blocked[\s-]*by)[*_]*\s*:?[*_]*\s*[A-Z]{1,3}\d*(?:[-.]\d+)+\s*\(\s*' + tracker._KEYS + r'\s*\)', re.I | re.M)
    except Exception as e:
        unknown('tracker.py unreadable (%s)' % e)
    issue = issues[why_key]
    if partial_resume(why_key):
        parts, issue['remainder_problems'] = predicate_remainder(issue)
        override_from_parts(issue, parts)
    if not os.environ.get('ND_DOC'):
        print('# owed-ledger not read (no --doc)')
    try:
        apply_owed_scope({why_key: issue}, read_owed_actions(), set(), set())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
        unknown('owed next-step state unreadable: ' + str(e))
    core_spec_pass([issue])
    lines, rc = why_ticket(issues[why_key])
    print('\n'.join(lines))
    sys.exit(rc)

pr_unknown = False
pr_keys = set()
pr_file_map = {}  # PR number -> its files
pr_meta = {}  # PR number -> (title, head branch)
outside_idle = {}
now_s = float(os.environ.get('NEXT_DISPATCH_NOW') or time.time())
gh = os.environ.get('NEXT_DISPATCH_GH_CMD') or os.environ.get('ND_GH_READ') or 'gh'
gh_repo = 'yotamleo-org/Himmel'  # env-literal-ok: the canonical slug; --search does not follow a repo rename
try:
    nums = ghrun([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'],
                          capture_output=True, text=True, timeout=gh_t(60), check=True).stdout.split()
    def pr_files(num):
        # the paginated files API, not `gh pr diff`: that fails with HTTP 406 on a PR over 300 files. A rename holds both names.
        try:
            files = ghrun([gh, 'api', '--paginate', 'repos/%s/pulls/%s/files' % (gh_repo, num), '--jq', '.[] | .filename, (.previous_filename // empty)'],
                                   capture_output=True, text=True, timeout=gh_t(120), check=True).stdout.splitlines()
        except (OSError, subprocess.SubprocessError):
            return None  # this PR's files are unknown; the rest are still read
        return None if len(files) >= 3000 else files  # the API stops at 3000 files: a PR that long is cut short, so its files are unknown
    pr_nums = [] if resume_only else nums
    if pr_nums:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=min(8, len(pr_nums))) as pool:
            for num, d in zip(pr_nums, pool.map(pr_files, pr_nums)):
                if d is None:
                    note_unknown('PR %s' % num)
                    continue
                held += [(f, 'open PR %s' % num, False) for f in d if f]  # a diff is files: compared exactly
                pr_file_map[num] = [f for f in d if f]
    # an open PR cites a ticket by its title or head branch (the commit/PR gate puts the key in both)
    for line in ghrun([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'open', '--limit', '200', '--json', 'number,title,headRefName,isCrossRepository,updatedAt', '--jq', '.[] | [.number, .title, .headRefName, .isCrossRepository, .updatedAt] | @tsv'],
                               capture_output=True, text=True, timeout=gh_t(60), check=True).stdout.splitlines():
        cols = line.split('\t')
        if len(cols) >= 3:
            pr_meta[cols[0]] = (cols[1], cols[2])
        idle = None
        if len(cols) >= 5 and cols[3] == 'true':
            try:
                idle = int((now_s - datetime.datetime.fromisoformat(cols[4].replace('Z', '+00:00')).timestamp()) // 86400)
            except ValueError:
                idle = None
        for k in re.findall(r'[A-Za-z]+-\d+', '\t'.join(cols[1:3]) if len(cols) >= 3 else line):
            if idle is not None and idle >= OUTSIDE_OWN_DAYS:
                outside_idle.setdefault(k.upper(), (cols[0], idle))
            else:
                pr_keys.add(k.upper()); owner.setdefault(k.upper(), 'open PR %s' % cols[0])
except (OSError, subprocess.SubprocessError):
    pr_unknown = True

for i in issues.values() if not pr_unknown else ():
    if partial_resume(i['key']) and i['key'] not in worker_keys and i['key'] not in pr_keys and resume_eligible(i):
        override_from_parts(i, live_answers([dict(remainder_of(pr, i['key']), pr=pr) for pr in partials[i['key']]]))

holds_py = os.environ['ND_HOLDS']
# A KEEP replacement becomes executable only after its validation action closed.
# Read the existing ledger once; metadata supplies routing, never permission.
owed_bucket = os.path.dirname(os.environ.get('ND_DOC') or os.environ.get('ND_WORKERS_FROM') or '')
if owed_bucket and os.path.lexists(os.path.join(owed_bucket, 'owed.jsonl')):
    try:
        actions = read_owed_actions()
        apply_owed_scope(issues, actions, worker_keys, pr_keys)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print('# next-dispatchable: owed next-step state unreadable: ' + str(exc), file=sys.stderr)
        sys.exit(3)

for label, doc, lines, wkeys in live_workers:
    try:
        r = subprocess.run([sys.executable, '-I', holds_py, 'parse', doc, '--repo', repo], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            raise subprocess.SubprocessError(r.stderr.strip())
    except (OSError, subprocess.SubprocessError) as e:
        workers_unknown = True
        note_unknown('live worker %s' % label)
        print('next-dispatchable: live worker %s: holds.py parse of %s failed (%s): its files are unknown' % (label, os.path.basename(doc), e), file=sys.stderr)
        continue
    mine = [l.split('\t', 1)[1] for l in r.stdout.splitlines() if '\t' in l]
    held += [(f, 'live worker %s' % label, True) for f in mine]
    if os.environ.get('ND_WHY') == '1':
        for f in dict.fromkeys(mine):
            if not concrete(f):
                print('# warn: %s holds directory %s' % (label, f))
    if not mine and not any(l[len(WRITES_LEAD):].strip() == 'none named' for l in lines if l.startswith(WRITES_LEAD)):  # "none named" is what gen-briefs writes for a worker that writes nothing
        workers_unknown = True  # a scope that yields no paths could be hiding the worker's files
        note_unknown('live worker %s' % label)
        print('next-dispatchable: live worker %s yields no held paths (no Writes line in %s): its files are unknown' % (label, os.path.basename(doc)), file=sys.stderr)

# stacked_series: every ledger under <bucket>/series/ (the bucket is the --workers-from manifest's directory), read through
# series-ledger.py, is a holder. An item holds its writes as `series <sid>` until it is abandoned or gh reports every PR of its
# publish_branch merged or closed, whatever any worker doc says; a gh answer that is missing or fails keeps the hold.
# A writer doc with no LIVE bullet and no manifest entry SERIES_ORPHAN_S after the newest pass (or the ledger's last write, for
# a series with no pass) is named SERIES-ORPHAN for the chief; it still holds until the chief abandons the series.
SERIES_ORPHAN_S = 2 * 3600
series_orphans = []  # (sid, writer doc)
series_label_of = {}  # ledger sid -> the label of the live series worker that owns the ledger

BRANCH_PR_LIMIT = 100

def branch_states(branch):
    # every PR state (OPEN, MERGED, CLOSED) gh lists for the head branch; None when gh cannot say, or when the list
    # fills its limit (a PR past it could be open)
    try:
        out = ghrun([gh, 'pr', 'list', '--repo', gh_repo, '--head', branch, '--state', 'all', '--limit', str(BRANCH_PR_LIMIT), '--json', 'state', '--jq', '.[].state'],
                             capture_output=True, text=True, timeout=gh_t(60), check=True).stdout.split()
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
        note_unknown('series directory %s' % series_dir)
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
            note_unknown('series ledger %s' % n)
            print('next-dispatchable: series ledger %s is unreadable: the files it holds are unknown' % n, file=sys.stderr)

# An IN CI ticket nobody holds is merged-not-closed when a merged PR cites it, else a RESUME row.
# One bounded search per candidate key (a merged-PR list capped at N would miss an older merge).
merged_unknown = False
merged_keys = set()
inci_keys = [i['key'] for i in issues.values() if i['status'] == 'IN CI' and i['type'] not in ('Epic', 'Sub-task')
             and i['key'] not in worker_keys and i['key'] not in pr_keys]
if inci_keys and not (pr_unknown or owners_unknown):
    def merged_cites(key):
        # A commit on the local main ref citing [KEY] answers "merged" with no GitHub call: this search was the dispatcher's
        # largest GraphQL cost. Local "no" and local "unknown" (no ref, git failed) are both asked of GitHub, because the
        # ref may lag a merge made minutes ago. Unknown fails closed in THIS direction: if GitHub cannot answer either, the error
        # propagates and the run reports `merged PRs unknown` with no IN CI row, so the ticket is never called merged and never dispatched on a guess.
        # (subject only: the old search read a PR's title and head branch, so a ticket named in another commit's body is not merged by it;
        # 50 matches that are all body mentions fall through to GitHub, the safe direction)
        if cited_on_main(key, subject_only=True):
            return True
        out = ghrun([gh, 'pr', 'list', '--repo', gh_repo, '--state', 'merged', '--search', key, '--limit', '30', '--json', 'title,headRefName', '--jq', '.[] | [.title, .headRefName] | @tsv'],
                             capture_output=True, text=True, timeout=gh_t(60), check=True).stdout
        return key in {k.upper() for k in re.findall(r'[A-Za-z]+-\d+', out)}
    try:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=min(8, len(inci_keys))) as pool:
            merged_keys = {k for k, hit in zip(inci_keys, pool.map(merged_cites, inci_keys)) if hit}
    except (OSError, subprocess.SubprocessError):
        merged_unknown = True

# In-work tickets nobody holds (and wrapped To Do ones): no worker, no open PR, not parked or blocked.
needs_note = []  # (key, partial PR numbers that record no remainder) of in-work tickets that need a chief note first
scope_questions = []  # keys of tickets nothing says the write scope of: a chief question, never silently free
handed_off = []  # (key, tickets) of in-work tickets whose every partial PR hands its remainder to other tickets
owed_rows = []  # (key, pr, who, date) of in-work tickets whose newest clear partial PR records a step owed to the chief or operator by a date
resume = []
for i in issues.values():
    if i.get('owed_wait'):
        step = i['owed_wait']
        owed_rows.append((i['key'], 'owed:' + step['id'], step['actor'], step['due']))
        continue
    if not resume_eligible(i):
        continue
    if i['status'] == 'IN CI' and merged_unknown:  # an unread merged-PR set could hide the ticket's merge
        continue
    i['merged'] = i['status'] == 'IN CI' and i['key'] in merged_keys
    if i['key'] in worker_keys or i['key'] in pr_keys:
        continue
    if pr_unknown or owners_unknown:
        continue
    if i['merged']:  # nothing to dispatch: the ticket only needs closing
        resume.append(i)
        continue
    if any(blocker_state(b) for b in i['blocked_by']):
        continue
    parts = [] if i.get('owed_next') else i.get('parts', [])
    i['partial'] = [(p['pr'], p['text']) for p in parts]
    if any(p['kind'] == 'none' for p in parts):  # a merged slice whose PR body names no remaining work: not dispatched blind
        needs_note.append((i['key'], [p['pr'] for p in parts if p['kind'] == 'none']))
        continue
    owed_parts = [p for p in parts if p['kind'] == 'owed']
    if owed_parts and not any(p['kind'] == 'remaining' or (p['kind'] == 'owed' and p['handed'][0] == 'proof') for p in parts):
        first_due = min(owed_parts, key=lambda p: p['handed'][1])  # the earliest due date; min keeps the older PR on a tie
        owed_rows.append((i['key'], first_due['pr'], first_due['handed'][0], first_due['handed'][1]))
        continue
    if parts and all(p['kind'] == 'handed-off' for p in parts):  # nothing left on this ticket: the chief closes it or keeps it as an umbrella
        handed_off.append((i['key'], [k for p in parts for k in p['handed']]))
        continue
    if i['no_scope'] and i['key'] not in briefs and not resume_only:  # a wrapped worker's brief carries its own Writes line; --resume-only counts orphans, dispatching nothing
        scope_questions.append(i['key'])
        continue
    resume.append(i)
resume.sort(key=ranked if pool_only else rank)

def stackable_on(i):
    if pr_unknown or owners_unknown:
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
    if i.get('owed_wait'):
        drop(i, 'owned next step: ' + i['owed_wait']['actor'])
        continue
    if i['key'] in worker_keys or i['key'] in pr_keys:  # a live worker or an open PR already owns the ticket
        drop(i, 'owned by ' + owner.get(i['key'], 'a live worker'))
        continue
    if i['key'] in design:  # a design leg writes only its spec in the state repo: it holds no files against the rest of the list
        if pr_unknown:  # an unread PR list could hide an open PR that owns the ticket
            drop(i, 'open PRs unknown (gh failed): ownership cannot be checked')
        elif named_unknown:
            drop(i, OWNER_UNKNOWN_DROP)
        else:
            free.append(i)
        continue
    if i['no_scope']:
        scope_questions.append(i['key'])
        drop(i, 'no-scope (nothing says what it writes: a chief question)')
        continue
    if named_unknown and not pr_unknown:
        drop(i, OWNER_UNKNOWN_DROP)
        continue
    if stacked and held_hits(i):
        stack = stackable_on(i)
        if stack:
            stackable_rows.append((i, 'STACKABLE %s %s' % (i['key'], stack[2]), 'stackable on %s (%d/%d)' % (stack[0], stack[1], SERIES_CAP)))
            continue  # judged in emit_stackable once it is classified: a ticket that would be BLOCKED is not offered
    if pr_unknown:
        drop(i, 'open PRs unknown (gh failed): ownership cannot be checked')
        continue
    free.append(i)

reasons = {}  # the classifier's stated reason per key

def classify(batch):
    cls = {}
    cmd = os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD')
    argv = [cmd] if cmd else ['node', os.path.join(repo, 'scripts/lanes/cloud-route.mjs'), '--classify-only']
    if rate_limited or timed_out:
        return cls
    try:
        r = subprocess.run(argv + [i['key'] for i in batch], capture_output=True, text=True, timeout=gh_t(300))
        hit = next((l for l in r.stderr.splitlines() if RATE_LIMIT_RE.search(l)), None)
        if hit:
            note_flag('rate-limit', 'graphql' if re.search(r'graphql', hit, re.I) else 'core', hit.strip()[:200], 'main')
        for line in r.stdout.splitlines():
            p = line.split('\t')
            if len(p) >= 2 and re.match(r'^[A-Z]+-\d+$', p[0]):
                cls[p[0]] = p[1]
                reasons[p[0]] = p[2].strip() if len(p) > 2 else ''
    except subprocess.TimeoutExpired:
        note_flag('stall', 'graphql', gh_t(300), 'main')
    except (OSError, subprocess.SubprocessError):
        pass
    return cls

print('# next-dispatchable: %d To Do candidate(s), %d collision-free%s' % (len(cands), len(free), ', open PRs unknown (gh failed)' if pr_unknown else '') + (', %d RESUME (in work, no worker, no open PR)' % len(resume) if resume else '') + (', live workers unknown (manifest or worker doc unreadable, or a worker names no write scope)' if workers_unknown else '') + (', merged PRs unknown (gh failed)' if merged_unknown else ''))
if rate_limited:
    print('# WARN: GitHub rate limit: gh answered "%s"; the reads it refused are unknown, not empty, so rows may be missing' % rate_limited[0])
for line in unknown_notes:
    print(line)
for k, prs in needs_note:
    unread = any(p in unread_prs for p in prs)
    print('NEEDS-CHIEF-NOTE %s: merged PR %s %s, needs a chief note before it is dispatched%s' % (k, ', '.join('#' + p for p in prs),
          'body could not be read (gh failed)' if unread else 'has no Remaining: line and no deferred line under ## Ticket coverage',
          '' if unread else '; to clear it add one to PR %s\'s body (gh pr edit <n> --body-file), or close %s by hand if nothing remains' % (', '.join('#' + p for p in prs), k)))
scope_questions.sort(key=lambda k: ranked(issues[k]))
scope_shown = scope_questions if os.environ.get('ND_WHY') == '1' else scope_questions[:top]
for k in scope_shown:
    print('NEEDS-CHIEF-NOTE %s: no readable scope: its description names no file, needs a chief note before it is dispatched; to clear it add a Writes: line to the ticket, or say no code' % k)
if len(scope_questions) > len(scope_shown):
    print('# no readable scope: %d more ticket(s) not shown, --why names them' % (len(scope_questions) - len(scope_shown)))
for k, keys in handed_off:
    print('HANDED-OFF %s: remainder on %s' % (k, ', '.join(dict.fromkeys(keys))))
for k, pr, who, due in owed_rows:
    chief_owed = any(a['chief_owed'] for a in issues[k].get('parts', []))
    named = staging_of(issues[k]) if chief_owed else []
    source = 'owed action ' + pr[5:] if isinstance(pr, str) and pr.startswith('owed:') else 'merged PR #%s' % pr
    print('OWED %s: %s owes %s by %s%s' % (k, source, who, due, (' proof-staging=' + ','.join(x[0] for x in named)) if named else ''))
    if named and os.environ.get('ND_WHY') == '1':
        staging_why(issues[k])
for sid, wdoc in series_orphans:
    print('SERIES-ORPHAN %s %s' % (sid, wdoc))

def family_of(f):
    # a path's directory family: the first two path components, as scripts/cleanup/cleanup-batch.sh cuts it
    p = canon(f).strip('/').split('/') + (['*'] if f.endswith('/') else [])  # a directory is cut as a file inside it
    return '/'.join(p[:2]) if len(p) >= 3 else (p[0] if len(p) == 2 else '.')

if stacked and first_ver and not (pr_unknown or owners_unknown):
    # SERIES FAMILY: To Do sub-tasks of one parent whose files all sit in one directory family, free of every holder. Sub-tasks
    # are never dispatch rows; the chief composes the series from this row (`series: [...]` in workers.json)
    families = {}
    for i in sorted(issues.values(), key=lambda i: int(i['key'].split('-')[1])):
        if not family_candidate(i) or i['key'] in worker_keys or i['key'] in pr_keys:
            continue
        if any(blocker_state(b) for b in i['blocked_by']):
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

def picked_hits(i):
    return [(f, k) for f in i['files'] for h, k in picked if blocks(f, h, False)]

def picked_hit(i):
    hits = picked_hits(i)
    return hits[0] if hits else None
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

def say_overlaps(i, against_listed=True):
    pairs = held_hits(i) + ([(f, 'listed ' + k) for f, k in picked_hits(i)] if against_listed else [])
    src = ' (from %s)' % i['src'] if os.environ.get('ND_WHY') == '1' else ''
    for f, who in dict.fromkeys(pairs):
        say('# overlap %s %s with %s%s' % (i['key'], f, who, src))
    if i['key'] in outside_idle:
        num, days = outside_idle[i['key']]
        say('# overlap %s also named by outside PR %s (idle %dd)' % (i['key'], num, days))

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
    if not stacked:
        print(row)
        return
    series[i['key']] = {'keys': [i['key']], 'files': list(i['files']), 'hook': c == 'HOOK-BYPASS' and not i.get('nowrite'), 'row': row,
                        'prio': i['prio'] or '-', 'ver': ','.join(i['ver']) or '-', 'lane': lane}
    series_of[i['key']] = i['key']
    out_buf.append(lambda h=i['key']: series_text(h))

def join_series(i, lane, c):
    hits = picked_hits(i)
    heads = {series_of.get(k) for _, k in hits}
    if not hits or None in heads or len(heads) != 1:
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
    if os.environ.get('ND_WHY') == '1':
        # a listed key says why too, so the list reads as the set the waiter counts
        for k in sorted(lane_of, key=lambda k: int(k.split('-')[1])):
            if k in issues:
                print('# why %s listed %s tier %d' % (k, lane_of[k], tier_of(issues[k])))
        for k in sorted(lane_of, key=lambda k: int(k.split('-')[1])):
            if k in issues:
                print('# scope %s %s%s: %s%s' % (k, issues[k]['src'], ' nowrite' if issues[k].get('nowrite') else '', ','.join(issues[k]['files']) or '-', ' reads=' + ','.join(issues[k]['reads']) if issues[k]['reads'] else ''))
                if issues[k].get('nowrite'):
                    staging_why(issues[k])
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
                r = 'partial-merge (a merged contract=no PR: RESUME row, HANDED-OFF, or needs a chief note)'
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
        say_overlaps(i, against_listed=not resume_only)
        picked.extend((f, i['key']) for f in i['files'])
        emitted.append(i)
        lane_of[i['key']] = 'RESUME'
        say('\t'.join(['RESUME', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')] + (['brief=' + briefs[i['key']]] if i['status'] == 'To Do' and i['key'] in briefs else [])
                       + ['partial=PR #%s merged, Remaining: %s' % (pr, text) for pr, text in i.get('partial', [])]
                       + ([proof_field(i)] if i.get('nowrite') else [])))
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
            if picked_hit(i) and stacked and join_series(i, lane, c):
                continue
            say_overlaps(i)
            list_free(i, lane, c, '\t'.join([lane, i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')] + (['hook'] if c == 'HOOK-BYPASS' and not i.get('nowrite') else []) + ([proof_field(i)] if i.get('nowrite') else [])))
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
        for i in [i for i in next_tier if i['key'] not in worker_keys and i['key'] not in pr_keys and not named_unknown][:top]:
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
    print_intake(intake_keys())
PY
nd_pid=$!
wait "$nd_pid"; nd_rc=$?
nd_pid=""
if [ -n "$why_ticket" ]; then
    if [ "$nd_rc" = 124 ] || [ "$nd_rc" = 137 ]; then
        printf 'UNKNOWN %s: timed out after %ss\n' "$why_ticket" "$nd_deadline"
        exit 3
    fi
    if ! awk -v key="$why_ticket" -v rc="$nd_rc" '
        /^#/ { next }
        $0 == "READY " key { ready++; next }
        index($0, "GATE " key " ") == 1 && $0 ~ /^GATE [A-Z]+-[0-9]+ (drop|held-label|open-blocker|blocker-no-version|stale-hold|prose-dependency|no-scope|no-proof|core-no-spec): [^ \t][^\t]*$/ { gate++; next }
        index($0, "UNKNOWN " key ": ") == 1 && $0 ~ /^UNKNOWN [A-Z]+-[0-9]+: [^ \t].*$/ { unknown++; next }
        { bad++ }
        END { exit !(!bad && ((rc == 0 && ready == 1 && !gate && !unknown) || (rc == 1 && gate && !ready && !unknown) || (rc == 3 && unknown == 1 && !ready && !gate))) }
    ' "$nd_out"; then
        printf 'UNKNOWN %s: unexpected exit %s\n' "$why_ticket" "$nd_rc"
        exit 3
    fi
    cat "$nd_out"
    exit "$nd_rc"
fi
IFS="$(printf '\t')" read -r nd_why nd_bucket nd_at nd_ftok < "$nd_flags" 2>/dev/null || nd_why=""
case "$nd_why" in
    rate-limit) nd_pause "$(ghq_line "${nd_ftok:-main}" "$nd_bucket" next-dispatchable rate-limit "$nd_at")" ;;
    stall) nd_pause "$(ghq_line "${nd_ftok:-main}" "$nd_bucket" next-dispatchable stall "$nd_at")" ;;
esac
if [ -n "$_TIMEOUT_BIN" ] && { [ "$nd_rc" -eq 124 ] || [ "$nd_rc" -eq 137 ]; }; then
    nd_pause "$(ghq_line "$nd_tok" graphql next-dispatchable stall "$nd_deadline")"
fi
cat "$nd_out"  # read-sink-ok: our own mktemp buffer
exit "$nd_rc"
