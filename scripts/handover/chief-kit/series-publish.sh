#!/usr/bin/env bash
# scripts/handover/chief-kit/series-publish.sh - publish one finished item of a stacked series as its own branch.
#
# An item is authored and committed in its own locked worktree on series/<sid>/<key>, cut from the item before it. Once
# the item before it has merged (its PR, read through gh; or it was abandoned), this verb turns the item into a branch on main: in the item's worktree it cuts
# series-pub/<sid>/<key> from origin's default branch (read from the remote), cherry-picks only cut_from..wip, pushes with an upstream, records
# publish_branch and published_head, sets the item published and unlocks the worktree. The worktree stays on the publish
# branch so the pre-push HEAD-match rule holds. It opens no PR: the worker runs /pr-check and worker-pr-open next.
# It never edits the ledger JSON: the one write is `series-ledger.py set` (invariant I3). Design: the stacked-series design, 5.2 Publish and rows F6/F10.
#
# USAGE
#   series-publish.sh --ledger P --doc DOC KEY
#
# Output: PUBLISHED-BRANCH <KEY> <branch>   (rc 0)
#         PUBLISH-CONFLICT <files>          (rc 2: cherry-pick aborted, item branch checked out at wip, nothing pushed, ledger untouched)
#         PUBLISH-WAIT <KEY>                (rc 2: the previous item <KEY> may still merge - its PR is open, none is visible yet, or gh
#                                            could not be read - so nothing is pushed; retry once it has merged. A previous item whose PR
#                                            closed unmerged, merged elsewhere or was never published is a plain refusal, no wait line)
# Exit: 0 ok, 1 failure (ledger unreadable, git or ledger write failed, a cherry-pick that failed with no conflicted file), 2 refused
# (not the writer, item not committed, dirty, drift, worktree outside <repo>/.claude/worktrees, cut not an ancestor of wip, previous
# item not merged or gh unreadable, branch exists, conflict). A refusal moves nothing. GH_CMD overrides `gh` (tests).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$HERE/series-ledger.py"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || { echo "series-publish: cannot source scripts/lib/git-clean.sh" >&2; exit 1; }
git_env_scrub   # an inherited GIT_DIR would make every worktree and range answer about the wrong repo
GH="${GH_CMD:-gh}"

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
wtcommon="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" || fail "cannot read the git directory of $wt"
wtroot="${wtcommon%/.git}/.claude/worktrees"   # where series-next.sh start makes every item worktree
case "$(rp "$wt")" in "$(rp "$wtroot")"/*) ;; *) refuse "item $KEY worktree $wt is outside $wtroot" ;; esac
[ -n "$cut" ] && [ -n "$wip" ] && [ -n "$ibr" ] || refuse "item $KEY has no recorded branch, cut_from or wip"
sid="$(top sid)"
pub="series-pub/$sid/$KEY"
head="$(git -C "$wt" rev-parse HEAD)" || fail "cannot read HEAD of $wt"
# the lines that finish a publish whose ledger write failed; never `series-next.sh commit`, which would overwrite wip
record_lines() {
    local q_py q_led q_key q_set q_wt
    printf -v q_py '%q' "$LEDGER_PY"; printf -v q_led '%q' "$LEDGER"; printf -v q_key '%q' "$KEY"; printf -v q_wt '%q' "$wt"
    printf -v q_set '%q' "publish_branch=$pub"
    echo "series-publish: $pub is pushed at $1 but the ledger does not say so. Run these two lines, nothing else:" >&2
    echo "python3 -I $q_py set --ledger $q_led --key $q_key $q_set published_head=$1 state=published" >&2
    echo "git -C $q_wt worktree unlock $q_wt" >&2
    echo "do NOT run series-next.sh commit: it would overwrite wip with the publish head" >&2
}
cur="$(git -C "$wt" symbolic-ref --quiet --short HEAD)" || cur=""   # swallow-ok: a detached HEAD reads as no branch and refuses below
if [ "$cur" != "$ibr" ]; then
    if [ "$cur" = "$pub" ]; then   # the recovery lines are only true when origin holds this exact head
        remote="$(git -C "$wt" ls-remote origin "refs/heads/$pub")" || fail "git ls-remote origin failed; cannot tell whether $pub was pushed"
        if [ "${remote%%[[:space:]]*}" = "$head" ]; then record_lines "$head"; else echo "series-publish: $pub is not on origin at $head; push it, or check out $ibr" >&2; fi
    fi
    refuse "item $KEY worktree is on '${cur:-a detached HEAD}', not on the item branch $ibr; nothing moved"
fi
# after the branch guard: on the publish branch the advice is the recovery lines, never "commit first" (that would overwrite wip)
status="$(git -C "$wt" status --porcelain)" || fail "git status failed in $wt"   # a git failure is never read as clean
[ -z "$status" ] || refuse "item $KEY worktree is dirty: commit it and run series-next.sh commit first ($wt)"
if [ "$head" != "$wip" ]; then
    echo "SERIES-DRIFT $KEY wip"
    refuse "item $KEY worktree HEAD is not the recorded wip; run series-next.sh commit first"
fi
git -C "$wt" merge-base --is-ancestor "$cut" "$wip" 2>/dev/null; ancrc=$?   # swallow-ok: the rc is read below
case "$ancrc" in
    0) ;;
    1) refuse "item $KEY cut_from $cut is not an ancestor of wip $wip; cut..wip would carry commits that are not the item's own" ;;
    *) fail "cannot tell whether $cut is an ancestor of $wip in $wt (rc $ancrc)" ;;
esac
ahead="$(git -C "$wt" rev-list --count "$cut..$wip")" || fail "cannot count $cut..$wip in $wt"
[ "$ahead" -gt 0 ] || refuse "item $KEY has no commits in $cut..$wip"

git -C "$wt" show-ref --verify --quiet "refs/heads/$pub" && refuse "local branch $pub already exists"

# the default branch is what origin says now, never the cached refs/remotes/origin/HEAD (it goes stale when the default moves)
symref="$(git -C "$wt" ls-remote --symref origin HEAD)" || fail "git ls-remote --symref origin HEAD failed; cannot tell origin's default branch"
defb="$(printf '%s\n' "$symref" | awk -F'\t' '$2 == "HEAD" && $1 ~ /^ref: refs\/heads\// { sub(/^ref: refs\/heads\//, "", $1); print $1; exit }')"
[ -n "$defb" ] || fail "origin names no default branch (git ls-remote --symref origin HEAD printed no ref); cannot publish"
def="origin/$defb"

# the item before this one (the nearest that is not abandoned) must have merged INTO the default branch this item is published
# onto: publishing earlier, or after a merge into some other branch, would leave its commits off the branch. An abandoned
# previous item never merges and never blocks. gh runs in the item worktree, so it asks about the repo the item belongs to.
prev="$(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
keys = [i["key"] for i in d["items"]]
for it in reversed(d["items"][:keys.index(sys.argv[2])]):
    if it.get("state") != "abandoned":
        print("%s\t%s" % (it["key"], it.get("publish_branch") or ""))
        break' "$LJ" "$KEY")" || fail "cannot read the previous item of $KEY from $LEDGER"
if [ -n "$prev" ]; then
    pk="${prev%%$'\t'*}"; ppb="${prev#*$'\t'}"
    [ -n "$ppb" ] || refuse "previous item $pk has no recorded PR (it was never published); publish $KEY once $pk has merged or been abandoned"
    prows="$(cd "$wt" && "$GH" pr list --head "$ppb" --state all --limit 100 --json number,state,baseRefName --jq '.[] | [.number, .state, .baseRefName] | @tsv')" \
        || { echo "PUBLISH-WAIT $pk"; refuse "cannot read the PR of previous item $pk ($ppb): gh failed; nothing moved, retry once it answers"; }
    if [ "$(printf '%s\n' "$prows" | awk -F'\t' -v b="$defb" '$2 == "MERGED" && $3 == b { f = 1 } END { print f + 0 }')" != 1 ]; then
        pstates="$(printf '%s\n' "$prows" | awk -F'\t' 'NF { printf "%s#%s %s into %s", (n++ ? ", " : ""), $1, $2, $3 }')"
        # a wait is a predecessor that may still merge (a PR is open, or none is visible yet); a closed or elsewhere-merged one is a refusal
        if [ -z "$pstates" ] || [ "$(printf '%s\n' "$prows" | awk -F'\t' '$2 == "OPEN" { f = 1 } END { print f + 0 }')" = 1 ]; then
            echo "PUBLISH-WAIT $pk"
        fi
        refuse "previous item $pk has not merged into $defb (${pstates:-no PR on $ppb}); publish $KEY once it has merged or been abandoned"
    fi
fi

git -C "$wt" fetch --quiet origin "$defb" || fail "git fetch origin $defb failed; publishing needs the current $defb"
base="$(git -C "$wt" rev-parse --verify --quiet "$def^{commit}")" || fail "cannot resolve $def"
git -C "$wt" ls-remote --exit-code --heads origin "$pub" >/dev/null 2>&1; lsrc=$?   # swallow-ok: the rc is read below
case "$lsrc" in
    0) refuse "$pub already exists on origin" ;;
    2) ;;   # no such branch: the expected case
    *) fail "git ls-remote origin failed (rc $lsrc); cannot tell whether $pub exists" ;;
esac

# restore: the item branch checked out at wip, the half-made publish branch gone
back() { git -C "$wt" checkout -q "$ibr" && git -C "$wt" branch -D "$pub" >/dev/null 2>&1; }

git -C "$wt" checkout -q -b "$pub" "$base" || fail "cannot create $pub from $def in $wt"
if ! cpout="$(git -C "$wt" cherry-pick "$cut..$wip" 2>&1)"; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C "$wt" cherry-pick --abort >/dev/null 2>&1
    back || fail "cherry-pick failed and $wt could not be returned to $ibr; fix it by hand"
    if [ -n "$files" ]; then
        echo "PUBLISH-CONFLICT ${files% }"
        refuse "cherry-pick of $cut..$wip onto $def conflicts; nothing pushed, ledger unchanged"
    fi
    fail "cherry-pick of $cut..$wip onto $def failed with no conflicted file; nothing pushed, ledger unchanged. git said: $cpout"
fi
if ! git -C "$wt" push -q -u origin "$pub"; then
    back || echo "series-publish: $wt could not be returned to $ibr; fix it by hand" >&2
    fail "git push of $pub failed; ledger unchanged"
fi
pubhead="$(git -C "$wt" rev-parse HEAD)" || fail "cannot read HEAD of $wt after the push; $pub is pushed, the ledger and the worktree lock are unchanged"
python3 -I "$LEDGER_PY" set --ledger "$LEDGER" --key "$KEY" publish_branch="$pub" published_head="$pubhead" state=published \
    || { record_lines "$pubhead"; exit 1; }
uerr="$(git -C "$wt" worktree unlock "$wt" 2>&1)" || echo "series-publish: WARN worktree unlock failed for $wt: $uerr" >&2
echo "PUBLISHED-BRANCH $KEY $pub"
