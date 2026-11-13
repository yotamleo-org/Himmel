#!/usr/bin/env bash
# check-critic-eval.sh <base> <head> — the reviewer-eval merge gate.
# The diff base is <head>^1 on CI's merge ref (GITHUB_REF refs/pull/<n>/merge and <head> a real merge: the
# main that merge ref was built on, which a push rebuilds), and <base> elsewhere.
# A diff that changes a critic behaviour path (scripts/eval/review-panel/cbs.txt, expanded at the diff base AND
# at head, so deleting a line from cbs.txt does not hide the file it named) merges only when
# `score.py gate <diff base> <head>` says keep or no-loss: two eval rows at the diff base's cbs_hash and two at
# the head's, all at the head tree's confighash, in the head tree's results.jsonl. Rows come from the chief's
# sweeps (scripts/eval/review-panel/README.md "The merge gate"), the default route for a critic change;
# only skipping the sweep needs an operator decision.
# Run from inside the checkout; CI passes the event's base sha (the main the PR opened on) and HEAD (the merge ref).
# Exit 0 no critic path changed, or keep / no-loss; 1 loss / unmeasured / no rows; 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/../eval/review-panel/score.py"
[ $# -eq 2 ] || { echo "usage: check-critic-eval.sh <base> <head>" >&2; exit 2; }
base="$1"; head="$2"
repo="$(git rev-parse --show-toplevel)" || { echo "check-critic-eval: not inside a git checkout" >&2; exit 2; }

# The event's base sha stays at the main the PR opened on; the merge ref is rebuilt on newer main at each push.
# Diffing from that stale sha would blame the PR for main's own later critic changes.
diff_base="$base"
if [[ "${GITHUB_REF:-}" =~ ^refs/pull/[0-9]+/merge$ ]] && git -C "$repo" rev-parse --verify -q "$head^2" >/dev/null; then
    diff_base="$(git -C "$repo" rev-parse --verify -q "$head^1")" \
        || { echo "check-critic-eval: cannot resolve $head^1" >&2; exit 2; }
fi

changed="$(git -C "$repo" diff --name-only --no-renames "$diff_base" "$head")" \
    || { echo "check-critic-eval: cannot diff $diff_base..$head" >&2; exit 2; }
cbs_base="$(python3 "$SCORE" cbs-paths "$diff_base" --repo "$repo")" || exit 2
cbs_head="$(python3 "$SCORE" cbs-paths "$head" --repo "$repo")" || exit 2
hit="$(printf '%s\n%s\n' "$cbs_base" "$cbs_head" | sort -u | grep -vx '' | grep -Fxf - <(printf '%s\n' "$changed"))"
if [ -z "$hit" ]; then
    echo "check-critic-eval: no protected critic path changed"
    exit 0
fi
echo "check-critic-eval: critic behaviour paths changed:"
printf '%s\n' "$hit" | sed 's/^/  /'

# Neither input below is read from the head, so a PR cannot retag its own critic file as unexecuted or
# add its own bypass row: the tags come from the diff base, the bypass file from the default branch's tip
# (else the diff base).
# A path tagged `# unexecuted: <path>` in the diff base's cbs.txt is one the eval sweep never runs (run.sh feeds
# critic-panel.sh directly), so the eval cannot grade a change to it; a judge GO covers it instead.
CBS_REL=scripts/eval/review-panel/cbs.txt
BYPASS_REL=scripts/eval/review-panel/gate-bypass.tsv
unexec="$(git -C "$repo" cat-file blob "$diff_base:$CBS_REL" 2>/dev/null | sed -n 's/^#[[:space:]]*unexecuted:[[:space:]]*//p' | sed 's/[[:space:]]*$//')" # swallow-ok: a base without cbs.txt has no tags, so every changed path stays gated
rest="$(printf '%s\n' "$hit" | grep -vxFf <(printf '%s\n' "$unexec"))"
if [ -z "$rest" ]; then
    echo "check-critic-eval: only paths the sweep never executes changed: $(printf '%s\n' "$hit" | paste -sd' '); a judge GO covers them"
    exit 0
fi

# gate-bypass.tsv is read from refs/remotes/origin/<GITHUB_BASE_REF>, the default branch's tip as CI's checkout
# fetched it, when that branch is the default branch named in the event file at GITHUB_EVENT_PATH and the ref
# exists, so a row landed after the PR opened counts with no merge into the branch. Otherwise it is read at the
# diff base, with one line naming the missing input. One tab-separated row per operator-recorded bypass: pr,
# head sha prefix (7-40 hex; a new row writes the full 40), decision id, reason. Honoured only for that PR
# number (CHECK_CRITIC_EVAL_PR, else GITHUB_REF refs/pull/<n>/merge) at that head (this head, or the merge
# ref's second parent). A malformed row fails closed.
bypass_rev="$diff_base"; bypass_at="the diff base"; why=""
if [ -z "${GITHUB_BASE_REF:-}" ]; then
    why="GITHUB_BASE_REF is unset"
elif ! default_branch="$(python3 -c 'import json,sys
b = json.load(open(sys.argv[1]))["repository"]["default_branch"]
assert isinstance(b, str) and b
print(b)' "${GITHUB_EVENT_PATH:-}" 2>/dev/null)"; then # swallow-ok: any failure is named on the line below
    why="the event file at GITHUB_EVENT_PATH is unreadable or has no repository.default_branch"
elif [ "$GITHUB_BASE_REF" != "$default_branch" ]; then
    why="the base branch $GITHUB_BASE_REF is not the default branch $default_branch"
elif ! tip="$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$GITHUB_BASE_REF^{commit}")"; then
    why="refs/remotes/origin/$GITHUB_BASE_REF is absent"
else
    bypass_rev="$tip"; bypass_at="refs/remotes/origin/$GITHUB_BASE_REF"
fi
[ -z "$why" ] || echo "check-critic-eval: $BYPASS_REL read at the diff base, not the default branch's tip: $why"
bypass_rows="$(git -C "$repo" cat-file blob "$bypass_rev:$BYPASS_REL" 2>/dev/null)" # swallow-ok: a tree without the file has no bypass rows
if [ -n "$bypass_rows" ]; then
    pr="${CHECK_CRITIC_EVAL_PR:-}"
    if [ -z "$pr" ] && [[ "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/merge$ ]]; then pr="${BASH_REMATCH[1]}"; fi
    cands="$(git -C "$repo" rev-parse --verify -q "$head^{commit}")"
    # The second parent is the PR head only on CI's merge ref; on any other merge commit it is arbitrary history.
    if [[ "${GITHUB_REF:-}" =~ ^refs/pull/[0-9]+/merge$ ]]; then
        cands="$cands"$'\n'"$(git -C "$repo" rev-parse --verify -q "$head^2")" || true # swallow-ok: a merge ref without a second parent leaves only the head itself
    fi
    tab=$'\t'
    row_re="^([0-9]+)${tab}([0-9a-f]{7,40})${tab}([^${tab}[:space:]]+)${tab}([^${tab}]*[^${tab}[:space:]][^${tab}]*)\$"
    n=0; matched=""
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in ''|'#'*) continue ;; esac
        if [[ "$line" == *$'\r'* ]] || ! [[ "$line" =~ $row_re ]]; then
            echo "check-critic-eval: FAIL - malformed row $n in $BYPASS_REL at $bypass_at (want: pr<TAB>head sha prefix of 7+ hex<TAB>decision<TAB>reason): $line" >&2
            exit 1
        fi
        [ -z "$matched" ] && [ -n "$pr" ] && [ "${BASH_REMATCH[1]}" = "$pr" ] || continue
        while IFS= read -r c; do
            [ -n "$c" ] && [[ "$c" == "${BASH_REMATCH[2]}"* ]] && matched="PR ${BASH_REMATCH[1]} at head ${BASH_REMATCH[2]}: decision ${BASH_REMATCH[3]}: ${BASH_REMATCH[4]}"
        done <<< "$cands"
    done <<< "$bypass_rows"
    if [ -n "$matched" ]; then
        echo "check-critic-eval: !!! BYPASS honoured for $matched"
        echo "check-critic-eval: !!! the eval gate was NOT consulted: this merge rests on the recorded operator bypass in $BYPASS_REL at $bypass_at"
        exit 0
    fi
fi

if python3 "$SCORE" gate "$diff_base" "$head" --repo "$repo"; then
    exit 0
fi
echo "check-critic-eval: FAIL - a critic change merges only with keep or no-loss eval rows (scripts/eval/review-panel/README.md)" >&2
echo "check-critic-eval: the paid eval sweep is the default route for a critic change and needs no operator ask; only skipping it needs an operator decision (a $BYPASS_REL row). Launch: docs/internals/bypass-launch-route.md" >&2
exit 1
