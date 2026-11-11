#!/usr/bin/env bash
# pr-check-outside.sh <pr-number> - prints `outside-pr: yes|no`: the question /pr-check
# step 0 asks once the PR is open. It reads only guarded files (scripts/lib), so a "no"
# step-0 verdict still covers the bytes it runs. Exit 2 when the PR snapshot or
# the repository cannot be read; the caller treats that as yes.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
lib="$here/../lib"

# pr-check-outside.sh --pr <n> --head <40hex>: the no-checkout route. It lets /pr-check review an
# outside PR from its diff at its head, with no checkout: it refuses unless the PR is outside, open
# and at <head>, asks review-round.sh check --pr whether this author may be reviewed (it never decides
# that itself), refuses a local branch of the PR's head name, fetches the head into
# refs/himmel/outside/<n> (objects plus that one ref; it never touches HEAD, the index, the worktree,
# config or hooks, and runs nothing from the fetched tree), then prints
#   outside-pr: yes <n> <head> <headRefName> base=<baseRefName> authorized=allowlist|approval:<id>
# Exit 0 ok; 5 not authorized; 2 for the state, the head, a collision, the fetch or a usage error.
# A fifth argument --fetch-only skips the authorization step: it fetches and prints authorized=fetch-only,
# and writes no review-round state (the security audit reads the diff before any approval exists).
# The one-argument form below stays the classifier.
if [ "${1:-}" = "--pr" ]; then
    PR="${2:-}"; HEAD="${4:-}"; fetch_only=0
    [ "${5:-}" != "--fetch-only" ] || fetch_only=1
    if [ "$#" -ne $((4 + fetch_only)) ] || [ "${3:-}" != "--head" ] || ! [[ "$PR" =~ ^[1-9][0-9]{0,8}$ ]] || ! [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]]; then
        echo "usage: pr-check-outside.sh <pr-number> | --pr <pr-number> --head <40-hex sha> [--fetch-only]" >&2
        exit 2
    fi
    # The route runs ready-check.sh and the libraries below, none of which a branch under review may supply:
    # it runs only as the trust anchor's own copy. The anchor comes from HIMMEL_REPO, never from this script's location.
    pc_anchor="${HIMMEL_REPO:-}"
    if [ -z "$pc_anchor" ] || ! [ "$here/../.." -ef "$pc_anchor" ]; then
        echo "pr-check-outside: --pr runs only through the anchor's copy (\${HIMMEL_REPO}/scripts/cr/pr-check-outside.sh), never a branch copy ($here) - nothing was fetched or reviewed" >&2
        exit 2
    fi
    command -v jq >/dev/null 2>&1 || { echo "pr-check-outside: jq not found on PATH" >&2; exit 2; }
    # shellcheck source=../lib/outside-contributors.sh
    . "$lib/outside-contributors.sh" || { echo "pr-check-outside: cannot load scripts/lib/outside-contributors.sh" >&2; exit 2; }
    # shellcheck source=../lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    [ -n "${_TIMEOUT_BIN:-}" ] || { echo "pr-check-outside: no GNU timeout on PATH, so the forge read cannot be bounded" >&2; exit 2; }
    # A caller's repository-redirecting GIT_* variables must not steer the fetch or the ref reads below.
    # shellcheck source=../lib/git-clean.sh
    # shellcheck disable=SC1091
    . "$lib/git-clean.sh" 2>/dev/null || { echo "pr-check-outside: cannot scrub the GIT_* environment (scripts/lib/git-clean.sh)" >&2; exit 2; }
    git_env_scrub
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "pr-check-outside: not inside a git repository" >&2; exit 2; }
    # 1. read: the predicate's one owner says outside, and the forge says open at exactly this head.
    # swallow-ok: a failed or non-yes answer is refused by the check on the same line (exit 2)
    if ! pc_out="$(bash "$here/../handover/chief-kit/ready-check.sh" --outside "$PR" 2>/dev/null)" || [ "$pc_out" != "outside-pr: yes" ]; then
        echo "pr-check-outside: PR #$PR is not confirmed outside (ready-check.sh --outside said '${pc_out:-nothing}'); this route is for outside PRs only. Nothing was fetched or reviewed." >&2
        exit 2
    fi
    pc_gh=(gh)
    [ ! -f "$lib/gh-read.sh" ] || pc_gh=(bash "$lib/gh-read.sh")
    # swallow-ok: an unreadable or malformed answer is refused by the branch below (exit 2)
    if ! pc_view="$("$_TIMEOUT_BIN" -k 5 20 "${pc_gh[@]}" pr view "$PR" --json author,headRefOid,headRefName,baseRefName,state 2>/dev/null)" \
        || ! pc_f="$(printf '%s' "$pc_view" | jq -er '[.author.login, .author.id, .headRefName, .baseRefName, .headRefOid, .state]
            | select(all(.[]; type == "string" and length > 0 and (test("[\t\n]") | not))) | @tsv' 2>/dev/null)"; then
        echo "pr-check-outside: cannot read PR #$PR from the forge. Nothing was fetched or reviewed." >&2
        exit 2
    fi
    IFS=$'\t' read -r pc_login pc_id pc_branch pc_base pc_oid pc_state <<< "$pc_f"
    if [ "$pc_state" != "OPEN" ] || [ "$pc_oid" != "$HEAD" ]; then
        echo "pr-check-outside: PR #$PR is $pc_state at $pc_oid, not OPEN at $HEAD. Nothing was fetched or reviewed." >&2
        exit 2
    fi
    # The branch and base names are substituted as literals into later fences: keep them to the safe alphabet.
    if [[ "$pc_branch" =~ [^A-Za-z0-9._/+-] ]] || [[ "$pc_base" =~ [^A-Za-z0-9._/+-] ]] || ! git check-ref-format --branch "$pc_branch" >/dev/null 2>&1; then
        echo "pr-check-outside: PR #$PR's branch or base name is outside the safe alphabet [A-Za-z0-9._/+-]. Nothing was fetched or reviewed." >&2
        exit 2
    fi
    # 2. authorize: the one function, run by review-round.sh; this script never decides it.
    # --fetch-only skips it: the stage-2 audit reads the diff before any approval exists, and a fetch starts no review round.
    pc_rc=0
    pc_auth="authorized fetch-only"
    # swallow-ok: the exit code is kept in pc_rc and decides below (5 refuses, any other non-zero is exit 2)
    [ "$fetch_only" -eq 1 ] || pc_auth="$(bash "$here/review-round.sh" check --pr "$PR" --head "$HEAD" 2>/dev/null)" || pc_rc=$?
    if [ "$pc_rc" -eq 5 ]; then
        pc_ap="${HOME:-/nonexistent}/.himmel/outside-pr-approvals.jsonl"
        if jq -nRe --argjson pr "$PR" --arg h "$HEAD" '[inputs | fromjson? | select(type == "object" and .pr == $pr and .head == $h and .stage == "review")] | length > 0' "$pc_ap" >/dev/null 2>&1 \
            && ! outside_contributor_allowed "$pc_login" "$pc_id" 2>/dev/null; then
            echo "pr-check-outside: PR $PR at ${HEAD:0:7} has no security-audit pass (stage 2); run outside-security-audit.sh --pr $PR --head $HEAD after stage 1. Nothing was fetched or reviewed." >&2
        else
            echo "pr-check-outside: author $pc_login ($pc_id) is not on ~/.himmel/outside-contributors.json (or has used its 3 full rounds), and no approval in ~/.himmel/outside-pr-approvals.jsonl names PR $PR at $HEAD. The chief sends \"outside-approve-request $PR $HEAD\" on Telegram and the operator replies to it \"approve $PR ${HEAD:0:7}\"; then re-run. Nothing was fetched or reviewed." >&2
        fi
        exit 5
    fi
    if [ "$pc_rc" -ne 0 ]; then
        echo "pr-check-outside: the authorization step failed (review-round.sh check --pr rc=$pc_rc). Nothing was fetched or reviewed." >&2
        exit 2
    fi
    # 3. a local branch of that name would make the ledger key ambiguous.
    if git show-ref --verify --quiet "refs/heads/$pc_branch"; then
        echo "pr-check-outside: a local branch named $pc_branch exists, and the ledger keys on that name; use the maintainer takeover instead. Nothing was fetched or reviewed." >&2
        exit 2
    fi
    # 4. fetch: objects plus one ref under refs/himmel/outside/; the + admits a force-push.
    # swallow-ok: a failed fetch or a ref that is not at the head is refused by this same condition (exit 2)
    if ! "$_TIMEOUT_BIN" -k 5 120 git fetch -q --no-tags --no-recurse-submodules origin "+refs/pull/$PR/head:refs/himmel/outside/$PR" >/dev/null 2>&1 \
        || [ "$(git rev-parse --verify --quiet "refs/himmel/outside/$PR^{commit}" 2>/dev/null)" != "$HEAD" ]; then # swallow-ok: an unresolved ref differs from $HEAD and is refused here (exit 2)
        echo "pr-check-outside: could not fetch refs/pull/$PR/head to $HEAD (the PR moved, or origin is unreachable). Nothing was reviewed." >&2
        exit 2
    fi
    # 5. print
    echo "outside-pr: yes $PR $HEAD $pc_branch base=$pc_base authorized=${pc_auth#* }"
    exit 0
fi

PR="${1:-}"
case "$PR" in
    ''|0*|*[!0123456789]*)
        echo "usage: pr-check-outside.sh <pr-number>" >&2
        exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "usage: pr-check-outside.sh <pr-number>" >&2; exit 2; }

GH="${GH_CMD:-gh}"
# Every call below is a read: with no GH_CMD seam they ride the read-only token.
if [ -z "${GH_CMD:-}" ] && [ -f "$lib/gh-read.sh" ]; then
    # shellcheck source=../lib/gh-read.sh
    . "$lib/gh-read.sh"
    gh_read_init
    GH="$lib/gh-read.sh"
fi
command -v "$GH" >/dev/null 2>&1 || { echo "pr-check-outside: gh not found on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "pr-check-outside: jq not found on PATH" >&2; exit 2; }

nwo=$("$GH" repo view --json owner,name,defaultBranchRef --jq '"\(.owner.login)/\(.name) \(.defaultBranchRef.name // "")"' 2>/dev/null)  # swallow-ok: an empty result is reported just below (exit 2)
nwo="${nwo%% *}"
if [ -z "$nwo" ]; then
    echo "pr-check-outside: cannot resolve owner/repo (gh repo view failed)" >&2
    exit 2
fi
snapshot=$(GH_CMD="$GH" bash "$lib/gh-pr-snapshot.sh" "$nwo" 0 "$PR" 2>/dev/null) || snapshot=""  # swallow-ok: an empty snapshot makes outside_pr_of fail, reported below (exit 2)

# shellcheck source=../lib/outside-contributors.sh
. "$lib/outside-contributors.sh" || { echo "pr-check-outside: cannot load scripts/lib/outside-contributors.sh" >&2; exit 2; }
if ! op=$(outside_pr_of "$snapshot"); then
    echo "pr-check-outside: cannot read PR #$PR's author or fork flag (PR snapshot unreadable)" >&2
    exit 2
fi
echo "outside-pr: $op"
