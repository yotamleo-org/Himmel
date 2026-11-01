#!/usr/bin/env bash
# scripts/handover/chief-kit/series-next.sh - the leg-side driver of a stacked series.
#
# A series is one ledger (<sid>.json, written ONLY by series-ledger.py) and one item per leg. This script starts the next
# item, records its commit, hands the series to a successor leg and abandons an item. It never edits the JSON itself:
# every read is `series-ledger.py read`, every write is `series-ledger.py set|pass` (invariant I3). It reads no flag
# and is inert unless a ledger exists. Page for the worker: docs/handover/worker-sections/series.md.
#
# USAGE (run from any checkout or worktree of the repo; git state is read from the current directory)
#   series-next.sh status  --ledger P                       read-only: one ITEM row per item, drift, abandoned parents, GO files
#   series-next.sh start   --ledger P --doc DOC KEY         the writer's one start per leg: worktree, lock, ledger, item scope
#   series-next.sh commit  --ledger P --doc DOC KEY         record the authoring item's worktree HEAD as wip, state committed
#   series-next.sh pass    --ledger P --doc DOC RESUME-DOC  hand the series on; refuses unrecorded or drifted work
#   series-next.sh abandon --ledger P --doc DOC KEY         mark the item abandoned (status then names the next item's parent)
#
# Exit: 0 ok, 1 failure (ledger unreadable, git or ledger write failed), 2 refused (not the writer, wrong state, dirty,
# drift, one item per leg). A refusal moves nothing.
#
# Every `status` row is rebuilt from the ledger, git (the shared object store) and gh, never from a transcript (F2).
# GH_CMD overrides `gh` (tests). HANDOVER_DIR locates <handover root>/.locks/go for GO-FILE rows.
#
# ponytail: "one start per leg" is a claim file per writer doc under <ledger>.starts.d/ because series-ledger.py has no
#   started_by field; nothing there is a .json, so next-dispatchable never reads it as a ledger. Upgrade: a started_by item field.
# ponytail: an item worktree skips worktree.sh's setup (deps install) because worktree.sh new refuses a series/ branch and cuts
#   only from origin/<default>; upgrade: a start-point argument and a series type in _new-worktree.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$HERE/series-ledger.py"
GH="${GH_CMD:-gh}"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || { echo "series-next: cannot source scripts/lib/git-clean.sh" >&2; exit 1; }
git_env_scrub   # an inherited GIT_DIR would make every worktree and ahead count answer about the wrong repo

refuse() { echo "series-next: $*" >&2; exit 2; }
fail()   { echo "series-next: $*" >&2; exit 1; }
usage()  { sed -n '/^# USAGE/,/^# Exit/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
VERB="$1"; shift
case "$VERB" in status|start|commit|pass|abandon) ;; *) echo "series-next: unknown verb '$VERB'" >&2; usage ;; esac

LEDGER=""; DOC=""; ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ledger) [ $# -ge 2 ] || usage; LEDGER="$2"; shift 2 ;;
        --doc)    [ $# -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "series-next: unknown flag '$1'" >&2; usage ;;
        *) [ -z "$ARG" ] || { echo "series-next: more than one argument ('$ARG', '$1')" >&2; usage; }; ARG="$1"; shift ;;
    esac
done
[ -n "$LEDGER" ] || { echo "series-next: --ledger is required" >&2; usage; }
if [ "$VERB" = status ]; then
    [ -z "$DOC" ] && [ -z "$ARG" ] || { echo "series-next: status takes only --ledger" >&2; usage; }
else
    [ -n "$DOC" ] || { echo "series-next: --doc is required" >&2; usage; }
    [ -n "$ARG" ] || { echo "series-next: the $VERB argument (item key or resume doc) is required" >&2; usage; }
fi

# --- ledger access: read-only JSON probes over the one `series-ledger.py read` ---------------------------------------
LJ="$(python3 -I "$LEDGER_PY" read --ledger "$LEDGER")" || exit 1
top()    { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$LJ" "$1"; }
keys()   { python3 -I -c 'import json,sys; [print(i["key"]) for i in json.loads(sys.argv[1])["items"]]' "$LJ"; }
field()  { python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
it = [i for i in d["items"] if i["key"] == sys.argv[2]]
v = it[0].get(sys.argv[3]) if it else None
print("" if v is None else v)' "$LJ" "$1" "$2"; }
KEYS="$(keys)"   # captured once: a pipe into an early-exiting grep or head reads as failure under pipefail
has_item() { grep -qxF -- "$1" <<< "$KEYS"; }
rp()     { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
ledger_set() { python3 -I "$LEDGER_PY" set --ledger "$LEDGER" "$@" || fail "series-ledger.py set failed: $*"; }

need_writer() {
    local w; w="$(top writer)"
    [ "$(rp "$DOC")" = "$(rp "$w")" ] || refuse "$DOC is not the writer; the writer is $w"
}
need_item() {
    has_item "$1" || refuse "no such item in $LEDGER: $1"
}

PRIMARY="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || fail "not in a git repository"   # swallow-ok: the failure is reported by fail
PRIMARY="${PRIMARY%/.git}"

# tracked changes and untracked files both count; a git failure reads as dirty, never as clean
wt_dirty() { local s; s="$(git -C "$1" status --porcelain)" || return 0; [ -n "$s" ]; }
wt_head()  { git -C "$1" rev-parse HEAD 2>/dev/null; }
wt_ok()    { [ -n "$1" ] && [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# drift_lines: SERIES-DRIFT rows for every unpublished or published item whose worktree HEAD is not what the ledger recorded
drift_lines() {
    local k st wt exp fld head
    while IFS= read -r k; do
        st="$(field "$k" state)"; wt="$(field "$k" worktree)"
        case "$st" in
            authoring|committed) exp="$(field "$k" wip)"; fld=wip ;;
            published)           exp="$(field "$k" published_head)"; fld=published_head ;;
            *) continue ;;
        esac
        if ! wt_ok "$wt"; then
            [ "$st" = published ] || echo "SERIES-DRIFT $k worktree"   # a published item's worktree may be pruned after the merge
            continue
        fi
        head="$(wt_head "$wt")"
        [ "$head" = "$exp" ] || echo "SERIES-DRIFT $k $fld"
    done < <(keys)
}

# --- status ----------------------------------------------------------------------------------------------------------
cmd_status() {
    local k st wip cut pb ahead pr rows n state oid root short prevst="" gos=""
    echo "SERIES $(top sid) writer=$(top writer)"
    root="$(. "$HERE/../../lib/handover-path.sh" 2>/dev/null && handover_root 2>/dev/null)" || root=""   # swallow-ok: no handover root means no GO-FILE rows, never a wrong path
    while IFS= read -r k; do
        st="$(field "$k" state)"; wip="$(field "$k" wip)"; cut="$(field "$k" cut_from)"; pb="$(field "$k" publish_branch)"
        ahead="-"
        if [ -n "$wip" ] && [ -n "$cut" ]; then
            ahead="$(git -C "$PRIMARY" rev-list --count "$cut..$wip" 2>/dev/null)" || ahead="-"   # swallow-ok: an unreadable range shows "-", and drift_lines is the loud signal
            [ -n "$ahead" ] || ahead="-"
        fi
        pr="-"
        if [ -n "$pb" ]; then
            if rows="$("$GH" pr list --head "$pb" --state all --limit 100 --json number,state,headRefOid --jq '.[] | [.number, .state, .headRefOid] | @tsv' 2>/dev/null)"; then   # swallow-ok: a gh failure takes the else branch and shows pr=unknown
                pr=""
                while IFS=$'\t' read -r n state oid; do
                    [ -n "$n" ] || continue
                    pr="${pr:+$pr, }#$n $state"
                    if [ -n "$root" ] && [ -n "$oid" ] && [ -e "$root/.locks/go/$n.$oid" ]; then
                        gos="$gos"$'\n'"GO-FILE $n $root/.locks/go/$n.$oid"
                    fi
                done <<< "$rows"
                [ -n "$pr" ] || pr="none"
            else
                pr="unknown"   # gh could not say: never a guess
            fi
        fi
        short="${wip:0:12}"; [ -n "$short" ] || short="-"
        echo "ITEM $k state=$st wip=$short ahead=$ahead pr=$pr"
        case "$st" in planned|authoring|committed) [ "$prevst" = abandoned ] && echo "PARENT-ABANDONED $k" ;; esac
        prevst="$st"
    done < <(keys)
    drift_lines
    [ -z "$gos" ] || printf '%s\n' "${gos#$'\n'}"
}

# --- start -----------------------------------------------------------------------------------------------------------
print_scope() {
    python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
it = [i for i in d["items"] if i["key"] == sys.argv[2]][0]
scope, do_not, text = it.get("scope"), it.get("do_not"), it.get("commit_text")
scope = scope if isinstance(scope, str) and scope.strip() else None
do_not = [x for x in do_not if isinstance(x, str) and x.strip()] if isinstance(do_not, list) else []
text = text if isinstance(text, str) and text.strip() else None
if scope or do_not or text:
    print("ITEM-SCOPE " + sys.argv[2])
    if scope:
        for line in scope.splitlines():
            print("  " + line)
    for x in do_not:
        print("DO-NOT " + x)
    if text:
        print("COMMIT-TEXT " + text)' "$LJ" "$1"
}

cmd_start() {
    local key="$ARG" sid st idx prev cut def wt branch me
    need_writer
    need_item "$key"
    # The doc's one start is CLAIMED first, atomically (noclobber create), so two starts racing from the same doc cannot both
    # pass, and a claim that cannot be written refuses the start. Any exit before the ledger records the item releases the claim.
    me="$(rp "$DOC")"
    mkdir -p "$LEDGER.starts.d" || fail "cannot create $LEDGER.starts.d"
    CLAIM="$LEDGER.starts.d/$(python3 -I -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest())' "$me")"
    if ! ( set -o noclobber; printf '%s\n' "$me" > "$CLAIM" ) 2>/dev/null; then   # swallow-ok: a failed claim is the one-item-per-leg refusal below
        refuse "one item per leg: hand off at READY ($DOC has already started an item; run series-next.sh pass)"
    fi
    KEEP_CLAIM=0
    trap '[ "$KEEP_CLAIM" = 1 ] || rm -f "$CLAIM"' EXIT
    st="$(field "$key" state)"
    [ "$st" = planned ] || refuse "item $key is $st; only a planned item starts"
    idx="$(grep -nxF -- "$key" <<< "$KEYS")"; idx="${idx%%:*}"
    if [ "$idx" -gt 1 ]; then
        prev="$(sed -n "$((idx - 1))p" <<< "$KEYS")"
        cut="$(field "$prev" wip)"
        [ -n "$cut" ] || refuse "the previous item $prev has no wip: start and commit it first"
    else
        def="$(git -C "$PRIMARY" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || def=""   # swallow-ok: no origin/HEAD falls back to origin/main
        [ -n "$def" ] || def="origin/main"
        git -C "$PRIMARY" fetch --quiet origin "${def#origin/}" 2>/dev/null || echo "series-next: WARN git fetch origin ${def#origin/} failed; cutting from the local $def" >&2
        cut="$(git -C "$PRIMARY" rev-parse --verify --quiet "$def^{commit}")" || fail "cannot resolve $def"
    fi
    sid="$(top sid)"
    branch="series/$sid/$key"
    wt="$PRIMARY/.claude/worktrees/series+$sid+$key"
    [ ! -e "$wt" ] || fail "worktree path exists: $wt"
    git -C "$PRIMARY" worktree add -q -b "$branch" "$wt" "$cut" || fail "git worktree add failed for $branch"
    if ! git -C "$PRIMARY" worktree lock --reason "series $sid item $key: worktree.sh prune must keep it until publish" "$wt"; then
        git -C "$PRIMARY" worktree remove --force "$wt"; git -C "$PRIMARY" branch -D "$branch" >/dev/null 2>&1
        fail "git worktree lock failed for $wt"
    fi
    if ! python3 -I "$LEDGER_PY" set --ledger "$LEDGER" --key "$key" branch="$branch" worktree="$wt" cut_from="$cut" wip="$cut" state=authoring; then
        git -C "$PRIMARY" worktree unlock "$wt"; git -C "$PRIMARY" worktree remove --force "$wt"; git -C "$PRIMARY" branch -D "$branch" >/dev/null 2>&1
        fail "series-ledger.py set failed; the new worktree was removed"
    fi
    KEEP_CLAIM=1
    echo "STARTED $key branch=$branch worktree=$wt cut_from=$cut"
    print_scope "$key"
}

# --- commit ----------------------------------------------------------------------------------------------------------
cmd_commit() {
    local key="$ARG" st wt head
    need_writer
    need_item "$key"
    st="$(field "$key" state)"
    case "$st" in authoring|committed) ;; *) refuse "item $key is $st; only an authoring or committed item commits" ;; esac   # committed: a later fix commit refreshes wip
    wt="$(field "$key" worktree)"
    wt_ok "$wt" || refuse "item $key has no usable worktree ($wt)"
    wt_dirty "$wt" && refuse "item $key worktree is dirty: git add and commit its work first ($wt)"
    head="$(wt_head "$wt")"
    [ -n "$head" ] || fail "cannot read HEAD of $wt"
    ledger_set --key "$key" wip="$head" state=committed
    echo "COMMITTED $key wip=$head"
}

# --- pass ------------------------------------------------------------------------------------------------------------
cmd_pass() {
    local k st wt bad="" drift
    need_writer
    while IFS= read -r k; do
        st="$(field "$k" state)"; wt="$(field "$k" worktree)"
        case "$st" in authoring|committed)
            if wt_ok "$wt" && wt_dirty "$wt"; then bad="$bad"$'\n'"item $k worktree is dirty: commit it, then run series-next.sh commit $k ($wt)"; fi ;;
        esac
    done < <(keys)
    drift="$(drift_lines)"
    if [ -n "$bad" ] || [ -n "$drift" ]; then
        [ -z "$bad" ] || printf '%s\n' "${bad#$'\n'}" >&2
        [ -z "$drift" ] || printf '%s\n' "$drift"
        refuse "pass refused: unrecorded work in an unpublished item; nothing moved"
    fi
    python3 -I "$LEDGER_PY" pass --ledger "$LEDGER" --from "$DOC" --to "$ARG" || fail "series-ledger.py pass failed"
    echo "PASSED $DOC to $ARG"
}

# --- abandon ---------------------------------------------------------------------------------------------------------
cmd_abandon() {
    local key="$ARG" st
    need_writer
    need_item "$key"
    st="$(field "$key" state)"
    [ "$st" != abandoned ] || refuse "item $key is already abandoned"
    ledger_set --key "$key" state=abandoned
    echo "ABANDONED $key"
}

"cmd_$VERB"
