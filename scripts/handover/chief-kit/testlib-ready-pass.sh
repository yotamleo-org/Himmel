# shellcheck shell=bash
# git-env-ok: test fixture; its only git call is `git -C` on a suite-owned temp repo
# scripts/handover/chief-kit/testlib-ready-pass.sh - shared fixture for the
# suites that run go.sh for real. go.sh now runs ready-check.sh
# itself and refuses unless it passes, so a suite that only needs a GO written
# must make ready-check pass: a gh that answers ready-check's queries green, and
# an ok CR-ledger row for the head in the repo go.sh runs from.
# Sourced, never run. bash 3.2-safe.

# ready_pass_bin <dir> - write <dir>/gh. It answers ready-check.sh's queries
# green for head $READY_STUB_HEAD (export it before go.sh runs), and hands every
# other call to the next gh on PATH, so a suite's own gh stub keeps working.
# Prepend <dir> to PATH for the go.sh call only.
ready_pass_bin() {
    export GH_PR_SNAPSHOT_CACHE_DIR="$1/snapshot-cache"
    mkdir -p "$1" || return 1
    cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
# READY_STUB_BODY / READY_STUB_TITLE (set, even to empty) replace the PR body and title a suite's GO is written for;
# the default title carries no [KEY], so a suite that does not care is not a partial merge (ready-check item 17).
DEFAULT_BODY='## Ticket coverage\n- ask: done\n\nRED then GREEN: the new row failed before the change\n'
case "$*" in
    "repo view --json owner,name"*) printf '%s main\n' "${READY_STUB_NWO:-o/r}"; exit 0 ;;
    # cr-disposition.sh check (go.sh): the PR's head branch.
    "pr view "*"--json headRefName"*) printf '%s\n' "${READY_STUB_BRANCH:-b}"; exit 0 ;;
    # trust_path_check (ready-check check 12): the default branch's list, then the
    # PR's head + file count and its file listing. Default = no trust path.
    *"contents/scripts/ci/ci-trust-paths.txt"*)
        [ "${READY_STUB_TRUST_LIST_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
        printf '^scripts/ci/\n^scripts/lib/\n'; exit 0 ;;
    "api repos/"*"/pulls/"*"/files --paginate"*) printf '%s\t\n' "${READY_STUB_TRUST_FILE:-scripts/x.sh}"; exit 0 ;;
    "api repos/"*"/pulls/"*"changed_files"*) printf '%s|1\n' "${READY_STUB_HEAD:-}"; exit 0 ;;
    *"--json headRefOid,mergeStateStatus"*) printf '%s CLEAN\n' "${READY_STUB_HEAD:-}"; exit 0 ;;
    *"--json statusCheckRollup"*) printf '%s' '[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'; exit 0 ;;
    *"--json commits"*)
        printf '%s' '[{"messageHeadline":"fix(x): [HIMMEL-1] t (#1)","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
        exit 0 ;;
    *"--json body"*) printf '%b' "${READY_STUB_BODY-$DEFAULT_BODY}"; exit 0 ;;
    'api repos/'*'/pulls/'*) printf '%s\n' "${READY_STUB_HEAD:-}"; exit 0 ;;
    *':pullRequest(number:'*)
        jq -n --arg h "${READY_STUB_HEAD:-}" --arg args "$*" --arg b "${READY_STUB_GQL_BRANCH-${READY_STUB_BRANCH:-b}}" --arg t "${READY_STUB_TITLE-fix(x): t (#1)}" \
            --arg body "$(printf '%b' "${READY_STUB_BODY-$DEFAULT_BODY}")" '
            ($args | capture("p(?<n>[0-9]+):pullRequest").n) as $n |
            {data:{repository:{("p"+$n):{number:($n|tonumber),headRefOid:$h,headRefName:$b,title:$t,mergeStateStatus:"CLEAN",reviewDecision:null,isCrossRepository:false,author:{__typename:"User",login:"yotamleo",id:"U_stub"},
                body:$body,
                commits:{nodes:[{commit:{oid:$h,messageHeadline:"fix(x): [HIMMEL-1] t (#1)",messageBody:"Platforms tested: linux\nSecurity reviewed: manual",parents:{totalCount:1}}}],pageInfo:{hasNextPage:false,endCursor:null}},
                reviewThreads:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
                statusCheckRollup:{contexts:{nodes:[{__typename:"CheckRun",name:"build",status:"COMPLETED",conclusion:"SUCCESS"}],pageInfo:{hasNextPage:false,endCursor:null}}}
            }}}}'
        exit $? ;;
    # ready-check row 15 (CodeRabbit rate-limit advisory): no statuses at the head, so it
    # prints nothing. Unanswered, a suite whose own gh stub sits in front of this one
    # bounces the call between the two stubs until row 15's 20 s deadline.
    "api repos/"*"/commits/"*"/statuses"*) printf '[]\n'; exit 0 ;;
    *"commits(first:100)"*) exit 0 ;;
    *"api graphql"*) printf '0 false null\n'; exit 0 ;;
    *"api --paginate"*"/files"*'select(.status'*) exit 0 ;;
    *"api --paginate"*"/files"*) printf 'scripts/x.sh\n'; exit 0 ;;
esac
self=$(cd "$(dirname "$0")" && pwd)
IFS=:
for d in $PATH; do
    [ "$d" = "$self" ] && continue
    [ -x "$d/gh" ] && exec "$d/gh" "$@"
done
echo "ready-pass gh: no gh after $self on PATH for: $*" >&2
exit 1
STUB
    chmod +x "$1/gh"
}

# ready_pass_ledger <repo> <sha>... - record an ok CR-ledger row per sha in
# <repo>'s git-common-dir (what ready-check's check 4 reads), through the
# ledger's single writer, ledger-append.sh (test-pr-check-run invariant 7).
READY_PASS_APPEND="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../cr" && pwd)/ledger-append.sh"
ready_pass_ledger() {
    local repo="$1" gd s
    shift
    gd=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
    for s in "$@"; do
        CR_LEDGER="$gd/cr-critic-scores.jsonl" bash "$READY_PASS_APPEND" avail \
            --branch b --head "$s" --model codex --status ok || return 1
    done
}

# ready_pass_origin <repo> [<base>] - give <repo> a bare origin under its
# git-common-dir whose main is <base> (default HEAD), as ready-check's check 19
# fetches origin/main. A repo with no commit first gets an empty root commit as
# HEAD, so commits the suite makes later share its history. No-op with an origin.
ready_pass_origin() {
    local repo="$1" base="${2:-}" gd
    git -C "$repo" remote get-url origin >/dev/null 2>&1 && return 0
    gd=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
    if [ -z "$base" ] && ! base=$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}'); then
        base=$(GIT_AUTHOR_DATE="@1 +0000" GIT_COMMITTER_DATE="@1 +0000" git -C "$repo" -c user.name=t -c user.email=t@example.com \
            commit-tree -m "chore: ready-pass base" "$(git -C "$repo" hash-object -t tree -w /dev/null)") || return 1
        git -C "$repo" update-ref HEAD "$base" || return 1
    fi
    git init -q --bare "$gd/ready-pass-origin.git" || return 1
    git -C "$repo" remote add origin "$gd/ready-pass-origin.git" || return 1
    git -C "$repo" push -q origin "$base:refs/heads/main" || return 1
    git -C "$repo" fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
}

# ready_pass_repo <repo> [label] - print a real head commit for check 19, which
# reads the impacted list of origin/main..<head>: an empty commit on origin's main
# (0 impacted suites), built with commit-tree, so HEAD never moves past the base.
# Gives <repo> an origin first (ready_pass_origin). A distinct label, a distinct head.
ready_pass_repo() {
    local repo="$1" label="${2:-head}" base key=HIMMEL  # the subject's key is data, so it is built here
    ready_pass_origin "$repo" || return 1
    base=$(git -C "$repo" rev-parse refs/remotes/origin/main) || return 1
    GIT_AUTHOR_DATE="@1 +0000" GIT_COMMITTER_DATE="@1 +0000" git -C "$repo" -c user.name=t -c user.email=t@example.com \
        commit-tree -p "$base" -m "feat(x): [$key-1] ready-pass $label" "$base^{tree}"
}
