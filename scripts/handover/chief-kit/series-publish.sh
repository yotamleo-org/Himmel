#!/usr/bin/env bash
# scripts/handover/chief-kit/series-publish.sh - publish one finished item of a stacked series as its own branch.
#
# An item is authored and committed in its own locked worktree on series/<sid>/<key>, cut from the item before it. Once
# that item has merged (or been abandoned), this verb turns the item into a branch on main: in the item's worktree it cuts
# series-pub/<sid>/<key> from origin/<default>, cherry-picks only cut_from..wip, pushes with an upstream, records
# publish_branch and published_head, sets the item published and unlocks the worktree. The worktree stays on the publish
# branch so the pre-push HEAD-match rule holds. It opens no PR: the worker runs /pr-check and worker-pr-open next.
# It never edits the ledger JSON: the one write is `series-ledger.py set` (invariant I3). Design: the stacked-series design, 5.2 Publish and rows F6/F10.
#
# USAGE
#   series-publish.sh --ledger P --doc DOC KEY
#
# Output: PUBLISHED-BRANCH <KEY> <branch>   (rc 0)
#         PUBLISH-CONFLICT <files>          (rc 2: cherry-pick aborted, item branch checked out at wip, nothing pushed, ledger untouched)
# Exit: 0 ok, 1 failure (ledger unreadable, git or ledger write failed), 2 refused (not the writer, item not committed, dirty,
# drift, branch exists, conflict). A refusal moves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$HERE/series-ledger.py"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || { echo "series-publish: cannot source scripts/lib/git-clean.sh" >&2; exit 1; }
git_env_scrub   # an inherited GIT_DIR would make every worktree and range answer about the wrong repo

refuse() { echo "series-publish: $*" >&2; exit 2; }
fail()   { echo "series-publish: $*" >&2; exit 1; }
usage()  { sed -n '/^# USAGE/,/^# Output/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }

LEDGER=""; DOC=""; KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ledger) [ $# -ge 2 ] || usage; LEDGER="$2"; shift 2 ;;
        --doc)    [ $# -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "series-publish: unknown flag '$1'" >&2; usage ;;
        *) [ -z "$KEY" ] || { echo "series-publish: more than one argument ('$KEY', '$1')" >&2; usage; }; KEY="$1"; shift ;;
    esac
done
[ -n "$LEDGER" ] || { echo "series-publish: --ledger is required" >&2; usage; }
[ -n "$DOC" ]    || { echo "series-publish: --doc is required" >&2; usage; }
[ -n "$KEY" ]    || { echo "series-publish: the item key is required" >&2; usage; }

LJ="$(python3 -I "$LEDGER_PY" read --ledger "$LEDGER")" || exit 1
top()   { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$LJ" "$1"; }
field() { python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
it = [i for i in d["items"] if i["key"] == sys.argv[2]]
v = it[0].get(sys.argv[3]) if it else None
print("" if v is None else v)' "$LJ" "$KEY" "$1"; }
rp()    { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

[ "$(rp "$DOC")" = "$(rp "$(top writer)")" ] || refuse "$DOC is not the writer; the writer is $(top writer)"
python3 -I -c 'import json,sys; sys.exit(0 if any(i["key"] == sys.argv[2] for i in json.loads(sys.argv[1])["items"]) else 1)' "$LJ" "$KEY" \
    || refuse "no such item in $LEDGER: $KEY"

st="$(field state)"; wt="$(field worktree)"; ibr="$(field branch)"; cut="$(field cut_from)"; wip="$(field wip)"
[ "$st" = committed ] || refuse "item $KEY is $st; only a committed item publishes"
# shellcheck disable=SC2015  # refuse exits, so C running after a failed A or B is the intent
[ -n "$wt" ] && [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || refuse "item $KEY has no usable worktree ($wt)"
[ -n "$cut" ] && [ -n "$wip" ] && [ -n "$ibr" ] || refuse "item $KEY has no recorded branch, cut_from or wip"
status="$(git -C "$wt" status --porcelain)" || fail "git status failed in $wt"   # a git failure is never read as clean
[ -z "$status" ] || refuse "item $KEY worktree is dirty: commit it and run series-next.sh commit first ($wt)"
sid="$(top sid)"
pub="series-pub/$sid/$KEY"
head="$(git -C "$wt" rev-parse HEAD)" || fail "cannot read HEAD of $wt"
# the lines that finish a publish whose ledger write failed; never `series-next.sh commit`, which would overwrite wip
record_lines() {
    echo "series-publish: $pub is pushed at $1 but the ledger does not say so. Run these two lines, nothing else:" >&2
    echo "python3 -I $LEDGER_PY set --ledger $LEDGER --key $KEY publish_branch=$pub published_head=$1 state=published" >&2
    echo "git -C $wt worktree unlock $wt" >&2
    echo "do NOT run series-next.sh commit: it would overwrite wip with the publish head" >&2
}
cur="$(git -C "$wt" symbolic-ref --quiet --short HEAD)" || cur=""   # swallow-ok: a detached HEAD reads as no branch and refuses below
if [ "$cur" != "$ibr" ]; then
    [ "$cur" != "$pub" ] || record_lines "$head"
    refuse "item $KEY worktree is on '${cur:-a detached HEAD}', not on the item branch $ibr; nothing moved"
fi
if [ "$head" != "$wip" ]; then
    echo "SERIES-DRIFT $KEY wip"
    refuse "item $KEY worktree HEAD is not the recorded wip; run series-next.sh commit first"
fi
ahead="$(git -C "$wt" rev-list --count "$cut..$wip")" || fail "cannot count $cut..$wip in $wt"
[ "$ahead" -gt 0 ] || refuse "item $KEY has no commits in $cut..$wip"

git -C "$wt" show-ref --verify --quiet "refs/heads/$pub" && refuse "local branch $pub already exists"

def="$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || def=""   # swallow-ok: no origin/HEAD falls back to origin/main
[ -n "$def" ] || def="origin/main"
git -C "$wt" fetch --quiet origin "${def#origin/}" || fail "git fetch origin ${def#origin/} failed; publishing needs the current main"
base="$(git -C "$wt" rev-parse --verify --quiet "$def^{commit}")" || fail "cannot resolve $def"
git -C "$wt" ls-remote --exit-code --heads origin "$pub" >/dev/null 2>&1 && refuse "$pub already exists on origin"   # swallow-ok: exit 2 (absent) is the expected case

# restore: the item branch checked out at wip, the half-made publish branch gone
back() { git -C "$wt" checkout -q "$ibr" && git -C "$wt" branch -D "$pub" >/dev/null 2>&1; }

git -C "$wt" checkout -q -b "$pub" "$base" || fail "cannot create $pub from $def in $wt"
if ! git -C "$wt" cherry-pick "$cut..$wip" >/dev/null 2>&1; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C "$wt" cherry-pick --abort >/dev/null 2>&1
    back || fail "cherry-pick failed and $wt could not be returned to $ibr; fix it by hand"
    echo "PUBLISH-CONFLICT ${files% }"
    refuse "cherry-pick of $cut..$wip onto $def conflicts; nothing pushed, ledger unchanged"
fi
if ! git -C "$wt" push -q -u origin "$pub"; then
    back || echo "series-publish: $wt could not be returned to $ibr; fix it by hand" >&2
    fail "git push of $pub failed; ledger unchanged"
fi
pubhead="$(git -C "$wt" rev-parse HEAD)" || fail "cannot read HEAD of $wt after the push; $pub is pushed, the ledger and the worktree lock are unchanged"
python3 -I "$LEDGER_PY" set --ledger "$LEDGER" --key "$KEY" publish_branch="$pub" published_head="$pubhead" state=published \
    || { record_lines "$pubhead"; exit 1; }
git -C "$wt" worktree unlock "$wt" 2>/dev/null || echo "series-publish: WARN worktree unlock failed for $wt" >&2
echo "PUBLISHED-BRANCH $KEY $pub"
