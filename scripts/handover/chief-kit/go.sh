#!/usr/bin/env bash
# scripts/handover/chief-kit/go.sh - write the chief's GO for one PR head
# The file IS the GO: merge-on-green.sh, run from a
# chief-spawned worker (HIMMEL_CONSOLE_LEG=1, exported by headed-arm-worker.sh),
# refuses with exit 17 unless <handover_root>/.locks/go/<pr>.<head sha> exists
# and carries head=<that sha> plus a mac= line: HMAC-SHA256 of
# nwo|pr|sha under
# the key this script mints at ~/.config/himmel/go-hmac.key (see
# scripts/lib/go-gate.sh). The chief's SendMessage GO is only the
# notification. A GO binds ONE head: a push after it needs a fresh GO.
#
# Usage: go.sh [--contract yes|no] [--trust-reviewed <reviewer-id>] <pr-number> <full-40-hex-head-sha>
#        go.sh --fix-main-red <red-run-id> <pr-number> <full-40-hex-head-sha>
#        go.sh --repo <owner/repo> [--checkout <dir>] --trust-reviewed <judge-qid> <pr-number> <full-40-hex-head-sha>
# Prints the written path. Re-running overwrites (idempotent).
#
# Every merge GO (not --fix-main-red) is also persisted as a signed verdict record
# through write-verdict.sh: <root>/<user>/<bucket>/verdicts/go-pr-<n>/chief-go-<head>.md,
# a qid no judge uses. It carries the deciding session's model and effort, from
# --model <id> / --effort <level> or the HIMMEL_VERDICT_MODEL / HIMMEL_VERDICT_EFFORT
# env (effort also CLAUDE_CODE_EFFORT_LEVEL), else `unknown`. Logging never blocks
# the GO: a failed record only warns on stderr.
#
# --fix-main-red: writes a FIX-GO instead of a GO - the chief's
# way to let the PR that fixes a red main past merge-on-green.sh's main-red gate
# (exit 22) without a forged `Fixes-main-red:` commit line. It is a separate
# file, .locks/go/fix-main-red.<pr>.<head>.<run>, signed over the repo, PR,
# head AND red run id under its own domain tag (go-gate.sh's go_fixred_gate), so
# it cannot be edited after signing and is useless once main's current red run
# is another one. It is not a merge GO: the ordinary GO is still needed.
# Mutually exclusive with --trust-reviewed.
#
# --trust-reviewed: a PR touching a CI trust path
# (scripts/ci/ci-trust-paths.txt, read from the default branch) merges through
# merge-on-green.sh only on a trust-reviewed GO. The id names the independent
# review and is written as a trust-reviewed= line INSIDE the mac (a separate
# domain tag, go-gate.sh's go_mac), so it cannot be added to, or edited in, a
# GO after signing. the id is the judge's qid, which must match
# [A-Za-z0-9][A-Za-z0-9._-]* (no colon), and go.sh refuses (exit 5) unless
# <root>/<user>/<bucket>/verdicts/<qid>/*.md rules GO on that exact head
# (go-gate.sh's go_trust_verdict holds the parse).
#
# --repo: the GO for a PR on a himmel adapter (a fork we own, listed with
# merge_allowed true in scripts/guardrails/himmel-adapters.json, read from the
# DEFAULT branch so a worktree edit cannot widen it) that merge-fork-pr.sh
# merges. The mac signs THAT repo, so the GO validates nowhere else. It replaces
# the himmel-only ready-check.sh below (ledger, trailers, coverage) with: the PR
# is OPEN at <head>, MERGEABLE and based on the entry's himmel_branch, and
# --trust-reviewed names a judge whose write-verdict.sh record rules GO on
# <head> for this PR - required, because that judge IS the review of a fork that
# has no reviewer or CI gate of its own.
# --repo also takes an operator-adopted repo (listed with merge_allowed true in
# scripts/guardrails/himmel-adopted.json, read the same way, go-gate.sh's
# go_adopted_entry): the PR must be based on that repo's default branch, and the
# judge's record must be written with write-verdict.sh --repo <owner/name>, so it
# lives under that repo's bucket and names that repo.
# The NO-GO order and delta reads (git) run in that repo's own checkout, found without a cd:
# --checkout <dir>, else the first checkout under HIMMEL_FORK_ROOTS (colon list, default the
# harness checkout's parent) whose origin names the repo, else the cwd. An unreadable
# --checkout is exit 10; so is a git read that fails in the checkout that was found.
#
# --contract yes|no: the merge contract of the merge this GO lets through - yes when the
# merge completes the ticket (merge-on-green.sh --jira-transition), no for a partial merge.
# A himmel merge GO needs it (ready-check.sh runs with --require-contract: a keyed PR title
# and no contract is a refusal), because merge-on-green.sh refuses a contract-no merge whose
# PR body records no remainder (exit 26) and a GO must not be written for a merge that
# refuses. Not for --repo; optional for --fix-main-red.
#
# every himmel GO, trust-reviewed or not, first runs this directory's
# ready-check.sh <pr> <head> from the caller's cwd and refuses (exit 4) unless
# it PASSes - head, CI, threads, the CR-ledger ok row at that head (check 4),
# trailers, ticket ids, coverage. Run it from the checkout /pr-check wrote the
# ledger in (the chief's primary), as the chief already does by hand.
#
# Exit codes:
#   0  written
#   1  handover root unresolvable (incl. an .env-configured root that is gone),
#      the GO key cannot be minted or read, or the write failed; also scripts/lib/go-gate.sh
#      failed to source or did not define chief_worker (fail closed - writing a GO
#      is sensitive enough that a broken shared lib must never read as "not a worker")
#   2  usage (arg count, non-digit PR, sha not exactly 40 lowercase hex, a
#      malformed --trust-reviewed id); also
#      a relative-entry copy handed off (anchor-handoff.sh) and
#      refused - HIMMEL_REPO unset/empty, or the anchor carries no copy
#   3  refused: run from a chief-spawned worker (a judge included:
#      "the judge is a worker") - a worker never writes its own GO
#   3  refused: run from a chief relay - only the chief writes a GO
#   4  refused: ready-check.sh did not PASS for <pr> at <head>
#   5  refused: --trust-reviewed <qid> has no GO verdict for <head>
#   6  refused: --repo names no himmel adapter and no adopted repo with merge_allowed true
#   7  refused: --repo PR is not OPEN at <head>, MERGEABLE and on the himmel_branch
#      (an adopted repo: its default branch),
#      or is not CLEAN (checks green) with every review thread resolved
#   8  refused: ready-check computed `TRUST-PATH: yes` (the PR diff touches a path in
#      the default branch's scripts/ci/ci-trust-paths.txt) and this is a plain GO;
#      only --trust-reviewed <judge qid> may write it. The worker's READY text is never read.
#   9  refused: cr-disposition.sh check found a deferred Critical or Important
#      finding on the PR's branch with no valid disposition at <head>
#  10  refused: --trust-reviewed <qid> has a real GO for <head> but a judge's NO-GO
#      (any qid of the PR) sits at or after <head>; or its only GO for <head> is a
#      `delta: no-op` verdict (write-verdict.sh --delta-noop) that go-gate.sh's
#      go_noop_carry refuses (no real GO at the chain's root, a NO-GO at or after
#      <head>, an over-long or cyclic chain) or delta-class.sh no longer classifies
#      every hop of its chain as `none` (a trust-path or judged-finding delta); or any
#      read error on that path, or an unresolvable verdict scope: a real judge must rule;
#      also, with --repo, a --checkout <dir> that is not a readable git checkout (the
#      NO-GO order of a fork PR cannot be read there)
#
# A relative entry (`bash scripts/handover/chief-kit/go.sh`, the worker
# profile's pre-approved literal) hands off to the HIMMEL_REPO anchor's own
# copy before anything else runs - same reasoning as
# merge-on-green.sh's own entry-script hand-off: a worker-writable worktree copy
# must never decide what its own GO writer does. An absolute entry (the
# chief's own invocation) is unaffected - see anchor-handoff.sh's header.
#
# Platform guard: POSIX bash 3.2+, same as headed-arm-worker.sh.
set -u
# a relative-entry copy that is not the anchor's hands off to it
# (the same one-hop, fail-closed pattern scripts/cr/anchor-handoff.sh uses).
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2
# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced before the seam guard.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
# refuse a chokepoint seam that differs from the session's launch env.
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "go.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/chief-kit/go.sh || exit 96


# The reads below (PR view, repo name) ride the read-only token via gh-read.sh
# and a missing or refused read token falls back to the main one, so
# a GO is never refused for it. Nothing here writes through it: the GO file is a
# local write.
GH_READ="$(cd "$_csg_dir/../../lib" 2>/dev/null && pwd)/gh-read.sh"  # swallow-ok: a missing lib dir leaves no helper file, and the next line falls back to plain gh
[ -f "$GH_READ" ] || GH_READ=gh

usage() {
    echo "usage: go.sh [--model <id>] [--effort <level>] [--contract yes|no] [--trust-reviewed <reviewer-id>] <pr-number> <full-40-hex-head-sha>" >&2
    echo "       go.sh --fix-main-red <red-run-id> <pr-number> <full-40-hex-head-sha>" >&2
    echo "       go.sh --repo <owner/repo> [--checkout <dir>] --trust-reviewed <judge-qid> <pr-number> <full-40-hex-head-sha>" >&2
}

TRUST=""
TRUST_SET=0
FIXRUN=""
FIX_SET=0
FORK=""
FORK_SET=0
GO_MODEL=""
GO_MODEL_SET=0
GO_EFFORT=""
GO_EFFORT_SET=0
CONTRACT=""
CONTRACT_SET=0
CHECKOUT=""
CHECKOUT_SET=0
# Each option, in any order, at most once (a repeat is a usage error).
while :; do
    case "${1:-}" in
        --model)
            [ "$GO_MODEL_SET" -eq 0 ] || { usage; exit 2; }
            GO_MODEL="${2:-}"; GO_MODEL_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --effort)
            [ "$GO_EFFORT_SET" -eq 0 ] || { usage; exit 2; }
            GO_EFFORT="${2:-}"; GO_EFFORT_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --contract)
            [ "$CONTRACT_SET" -eq 0 ] || { usage; exit 2; }
            CONTRACT="${2:-}"; CONTRACT_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --trust-reviewed)
            [ "$TRUST_SET" -eq 0 ] || { usage; exit 2; }
            TRUST="${2:-}"; TRUST_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --fix-main-red)
            [ "$FIX_SET" -eq 0 ] || { usage; exit 2; }
            FIXRUN="${2:-}"; FIX_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --repo)
            [ "$FORK_SET" -eq 0 ] || { usage; exit 2; }
            FORK="${2:-}"; FORK_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        --checkout)
            [ "$CHECKOUT_SET" -eq 0 ] || { usage; exit 2; }
            CHECKOUT="${2:-}"; CHECKOUT_SET=1
            shift 2 2>/dev/null || shift "$#" ;;
        *) break ;;
    esac
done
if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi
PR="$1"; SHA="$2"
if [ "$CONTRACT_SET" -eq 1 ]; then
    case "$CONTRACT" in
        yes|no) ;;
        *) usage; echo "go: --contract takes yes or no (got '$CONTRACT')" >&2; exit 2 ;;
    esac
    if [ "$FORK_SET" -eq 1 ]; then
        usage
        echo "go: --contract belongs to a himmel merge GO and cannot be combined with --repo" >&2
        exit 2
    fi
fi
if [ "$FIX_SET" -eq 1 ]; then
    case "$FIXRUN" in
        ''|0*|*[!0123456789]*)
            usage
            echo "go: --fix-main-red needs the red run's numeric id without a leading zero (got '$FIXRUN')" >&2
            exit 2 ;;
    esac
    if [ "$TRUST_SET" -eq 1 ]; then
        usage
        echo "go: --fix-main-red and --trust-reviewed are mutually exclusive" >&2
        exit 2
    fi
fi

if [ "$FORK_SET" -eq 1 ]; then
    case "$FORK" in
        */*/*|/*|*/|*[!A-Za-z0-9._/-]*|'') FORK_BAD=1 ;;
        */*) FORK_BAD=0 ;;
        *) FORK_BAD=1 ;;
    esac
    if [ "$FORK_BAD" -eq 1 ] || [ "$FIX_SET" -eq 1 ] || [ "$TRUST_SET" -eq 0 ]; then
        usage
        echo "go: --repo needs an owner/name and --trust-reviewed <judge-qid>, and excludes --fix-main-red (got '$FORK')" >&2
        exit 2
    fi
elif [ "$CHECKOUT_SET" -eq 1 ]; then
    usage
    echo "go: --checkout belongs to --repo (the checkout holding that repo's PR commits)" >&2
    exit 2
fi

case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "go: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; then
    usage
    echo "go: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# chief_worker is the same shared predicate merge-on-green.sh and
# block-unresolved-cr-merge.sh enforce with - go.sh is the writer those two
# gate against, so it must use their exact rule, not a hand-rolled copy of it.
# Fail closed: this write is sensitive enough that a broken/missing shared lib
# must never be read as "not a worker".
unset -f go_adapter_entry go_adopted_entry _go_harness_ref chief_worker go_gate _go_gate_verify go_trust_gate go_trust_id_ok go_trust_verdict go_verdict_line go_pr_qids go_noop_chain go_nogo_after go_noop_carry go_verdict_scope go_mac go_msg_mac go_verdict_mac go_verdict_mac_ok _go_sha256 go_key_file go_resolve_root _go_in_harness go_fixred_gate go_fixred_file go_fork_ready 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F chief_worker >/dev/null 2>&1 \
        || ! declare -F go_mac >/dev/null 2>&1 || ! declare -F go_resolve_root >/dev/null 2>&1 \
        || ! declare -F go_trust_id_ok >/dev/null 2>&1 || ! declare -F go_trust_verdict >/dev/null 2>&1 \
        || ! declare -F go_verdict_scope >/dev/null 2>&1 || ! declare -F go_fixred_file >/dev/null 2>&1 \
        || ! declare -F go_adapter_entry >/dev/null 2>&1 || ! declare -F go_fork_ready >/dev/null 2>&1 \
        || ! declare -F go_adopted_entry >/dev/null 2>&1 || ! declare -F go_verdict_line >/dev/null 2>&1 \
        || ! declare -F go_pr_qids >/dev/null 2>&1 || ! declare -F go_noop_chain >/dev/null 2>&1 \
        || ! declare -F go_nogo_after >/dev/null 2>&1 || ! declare -F go_noop_carry >/dev/null 2>&1; then
    echo "go: cannot load scripts/lib/go-gate.sh - refusing (the chief-worker marker check must fail closed, not silently no-op)" >&2
    exit 1
fi
if [ "$TRUST_SET" -eq 1 ] && ! go_trust_id_ok "$TRUST"; then
    usage
    echo "go: --trust-reviewed needs a reviewer id of 1-128 chars from [A-Za-z0-9._:-] (got '$TRUST')" >&2
    exit 2
fi
# go-pr-<n> is the qid of a persisted chief GO below, never a judge's verdict.
if [ "$TRUST_SET" -eq 1 ]; then
    case "$TRUST" in
        go-pr-*)
            usage
            echo "go: --trust-reviewed cannot name a go-pr-* record: that namespace is a persisted chief GO, not a judge verdict (got '$TRUST')" >&2
            exit 2 ;;
    esac
fi
if chief_worker; then
    echo "go: refusing - this is a chief-spawned worker (HIMMEL_CONSOLE_LEG is set); only the chief writes a GO. Send READY to your chief and wait for GO." >&2
    exit 3
fi

case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "go: refusing - this is a chief relay (HIMMEL_CONSOLE_RELAY is set); only the chief writes a GO. Escalate the READY to your chief." >&2
        exit 3 ;;
esac

# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/handover-path.sh"; then
    echo "go: cannot load scripts/lib/handover-path.sh" >&2
    exit 1
fi
# the root merge-on-green's gate reads, not whatever this
# chief's env happens to say - go_resolve_root skips an empty or stub
# HANDOVER_DIR for the anchor's .env-configured root, and fails (never falls
# back to the stub) when that configured root is gone.
ANCHOR="$(cd "$HERE/../../.." && pwd)"
if ! ROOT=$(go_resolve_root "$ANCHOR"); then
    # shellcheck disable=SC2031  # go_resolve_root scopes HANDOVER_DIR in a subshell on purpose; this reads the caller's own value
    echo "go: cannot resolve the handover root merge-on-green reads (HANDOVER_DIR='${HANDOVER_DIR:-}', or the HANDOVER_DIR in $ANCHOR/.env is not a directory) - no GO written" >&2
    exit 1
fi
if _go_in_harness "$ROOT" "$ANCHOR"; then
    echo "go: note - writing the GO under the harness repo's inline handovers/ ($ROOT): no external HANDOVER_DIR is configured, so this is Mode A" >&2
fi

# a fork GO only for an allowlisted adapter or adopted repo, and only for a PR
# that is OPEN at this head, MERGEABLE and based on the adapter's himmel_branch
# (an adopted repo's default branch).
VREPO=""
if [ "$FORK_SET" -eq 1 ]; then
    if HBRANCH=$(go_adapter_entry "$ANCHOR" "$FORK"); then
        VREPO=$FORK
    else
        if ! ABRANCH=$(go_adopted_entry "$ANCHOR" "$FORK"); then
            echo "go: refusing the fork GO for $FORK PR #$PR - $HBRANCH $ABRANCH No GO written." >&2
            exit 6
        fi
        HBRANCH=$ABRANCH VREPO=$FORK
    fi
    FVIEW=$("$GH_READ" pr view "$PR" --repo "$FORK" --json state,headRefOid,mergeable,baseRefName 2>/dev/null) || FVIEW=""
    FSTATE=$(printf '%s' "$FVIEW" | jq -r '"\(.state)|\(.headRefOid)|\(.mergeable)|\(.baseRefName)"' 2>/dev/null) || FSTATE=""
    if [ "$FSTATE" != "OPEN|$SHA|MERGEABLE|$HBRANCH" ]; then
        echo "go: refusing the fork GO for $FORK PR #$PR - it must be OPEN at $SHA, MERGEABLE and based on $HBRANCH (state|head|mergeable|base read: '$FSTATE'). No GO written." >&2
        exit 7
    fi
    if ! REASON=$(GH="${GH:-$GH_READ}" go_fork_ready "$FORK" "$PR"); then
        echo "go: refusing the fork GO for $FORK PR #$PR - $REASON No GO written." >&2
        exit 7
    fi
fi

# a trust-reviewed GO only on the named judge's GO verdict for
# this exact head (go_trust_verdict parses it, failing closed). and
# for this PR - a verdict that names another PR, or none, refuses. An adopted
# repo's verdict must also name that repo.
if [ "$TRUST_SET" -eq 1 ] && ! REASON=$(go_trust_verdict "$ROOT" "$TRUST" "$SHA" "$ANCHOR" "$PR" "$VREPO"); then
    echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - $REASON No GO written." >&2
    exit 5
fi

# The checkout holding the PR's commits, where the NO-GO order and delta reads below ask git.
# A himmel PR: the cwd. --repo: --checkout <dir>, else the first checkout whose origin names
# $FORK under HIMMEL_FORK_ROOTS (colon list, default the harness checkout's parent) or the
# cwd, preferring one that holds $SHA, else the cwd - where a git read that fails refuses (exit 10).
# git-env-ok: every git call in this block runs in a subshell that unsets GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR and GIT_INDEX_FILE first
GITDIR=$PWD
if [ "$CHECKOUT_SET" -eq 1 ]; then
    if ! (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; git -C "$CHECKOUT" rev-parse --git-dir) >/dev/null 2>&1; then
        echo "go: --checkout '$CHECKOUT' is not a readable git checkout, so the NO-GO order of the fork PR cannot be read. No GO written." >&2
        exit 10
    fi
    GITDIR=$(cd "$CHECKOUT" && pwd)
elif [ "$FORK_SET" -eq 1 ]; then
    _gfc_want=$(printf '%s' "$FORK" | tr '[:upper:]' '[:lower:]') _gfc_first="" _gfc_has=""
    _gfc_try() {  # <dir>: note the first checkout whose origin names $FORK, and the first of those holding $SHA
        local u
        u=$( (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; git -C "$1" remote get-url origin) 2>/dev/null) || return 0  # swallow-ok: a directory with no origin is not a candidate, the scan moves on
        u=$(printf '%s' "$u" | sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git/?$##' | tr '[:upper:]' '[:lower:]')
        [ "$u" = "$_gfc_want" ] || return 0
        [ -n "$_gfc_first" ] || _gfc_first=$1
        [ -n "$_gfc_has" ] || { (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; git -C "$1" cat-file -e "$SHA^{commit}") 2>/dev/null && _gfc_has=$1; }
        return 0
    }
    _gfc_try "$PWD"
    _gfc_rest="${HIMMEL_FORK_ROOTS:-$(dirname "$ANCHOR")}:"
    while [ -n "$_gfc_rest" ]; do
        _gfc_root=${_gfc_rest%%:*}; _gfc_rest=${_gfc_rest#*:}
        [ -d "$_gfc_root" ] || continue
        for _gfc_d in "$_gfc_root"/*/; do
            [ -d "$_gfc_d" ] && _gfc_try "${_gfc_d%/}"
        done
    done
    GITDIR=${_gfc_has:-${_gfc_first:-$PWD}}
fi

# a `delta: no-op` verdict (write-verdict.sh --delta-noop) stands in for a judge only
# while go-gate.sh's go_noop_carry (the one carry rule auto-go.sh runs too) holds and
# the delta of every hop of its chain still classifies none. A real GO at the head is
# vetoed by any judge's NO-GO at or after it (go_nogo_after). The PR's commits are read
# in the caller's cwd, as delta-class.sh reads them; a trust or finding delta, a NO-GO
# or any read error refuses: it needs a real judge.
if [ "$TRUST_SET" -eq 1 ]; then
    REAL=0 NOOP=0
    if ! NSCOPE=$(go_verdict_scope "$ANCHOR" "$VREPO"); then
        echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - the verdict scope could not be resolved, so whether its verdict is a delta no-op cannot be checked. No GO written." >&2
        exit 10
    fi
    NVD="$ROOT/$NSCOPE/verdicts"
    for vf in "$NVD/$TRUST"/*.md; do
        [ -f "$vf" ] || continue
        if ! RL=$(go_verdict_line "$vf"); then
            echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - cannot read the verdict $vf, so whether it is a delta no-op cannot be checked. No GO written." >&2
            exit 10
        fi
        # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
        case "$RL" in '**GO** for head `'"$SHA"'`'|'**GO** for head `'"$SHA"'`.') ;; *) continue ;; esac
        DRC=0; grep -qxE "delta: no-op"$'\r'"?" "$vf" 2>/dev/null || DRC=$?
        case "$DRC" in
            0) NOOP=1 ;;
            1) REAL=1 ;;
            *) echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - cannot read the verdict $vf (grep exit $DRC), so whether it is a delta no-op cannot be checked. No GO written." >&2
               exit 10 ;;
        esac
    done
    if [ "$REAL" -eq 1 ]; then
        if ! WHY=$(go_nogo_after "$NVD" "$PR" "$GITDIR" "$SHA"); then
            echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - $WHY. No GO written." >&2
            exit 10
        fi
    elif [ "$NOOP" -eq 1 ]; then
        if ! WHY=$(go_noop_carry "$NVD" "$TRUST" "$PR" "$GITDIR" "$SHA" "$ROOT" "$ANCHOR" "$VREPO"); then
            echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - its only verdict is a delta no-op that may not carry: $WHY. No GO written." >&2
            exit 10
        fi
        if ! CHAIN=$(go_noop_chain "$NVD" "$TRUST" "$SHA"); then
            echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - $CHAIN. No GO written." >&2
            exit 10
        fi
        while read -r NH NJ; do
            [ -n "$NH" ] && [ "$NJ" != - ] || continue
            DCLASS=$(cd "$GITDIR" && bash "$HERE/delta-class.sh" --qid "$TRUST" ${VREPO:+--repo "$VREPO"} "$NJ" "$NH" 2>/dev/null) || DCLASS=trust # swallow-ok: a failed classifier reads trust, which refuses, on this line
            if [ "$DCLASS" != none ]; then
                echo "go: refusing the trust-reviewed GO for PR #$PR at $SHA - its only verdict is a delta no-op, but delta-class.sh classifies the delta from '$NJ' to '$NH' as '$DCLASS' (not none). A judge must rule on this head; a no-op never carries a trust-path or judged-finding delta. No GO written." >&2
                exit 10
            fi
        done <<< "$CHAIN"
    fi
fi

# no GO for a head ready-check does not pass. Its check 4 is the
# CR-ledger ok row at this head (read from this cwd's git-common-dir, as when
# the chief runs it by hand), so a push after /pr-check cannot get a GO
# without a fresh review. Run from $HERE: the anchor's copy, never a worktree's.
# The merge contract is named by the caller (--contract): a merge GO that does not name it is refused
# by ready-check item 17 (--require-contract), because merge-on-green.sh's remainder refusal depends on it.
RC_ARGS=""
[ "$FIX_SET" -eq 1 ] || RC_ARGS="--require-contract"
[ "$CONTRACT_SET" -eq 0 ] || RC_ARGS="$RC_ARGS --contract $CONTRACT"
# shellcheck disable=SC2086  # RC_ARGS is fixed words built just above, never caller text
if [ "$FORK_SET" -eq 0 ] && ! READY_OUT=$(bash "$HERE/ready-check.sh" $RC_ARGS "$PR" "$SHA" 2>&1); then
    printf '%s\n' "$READY_OUT" >&2
    echo "go: refusing - ready-check.sh did not PASS for PR #$PR at $SHA (above); fix what it names, re-run /pr-check for a new head, then re-run go.sh. No GO written." >&2
    exit 4
fi

# ready-check COMPUTES the trust path from the PR diff and the default branch's
# list (its TRUST-PATH line); the worker's READY prose is never read. A plain GO on
# a yes line is refused: a trust path merges only on a trust-reviewed GO.
if [ "$FORK_SET" -eq 0 ] && [ "$TRUST_SET" -eq 0 ] && [ "$FIX_SET" -eq 0 ] \
   && printf '%s\n' "$READY_OUT" | grep -qx 'TRUST-PATH: yes'; then
    echo "go: refusing the plain GO for PR #$PR at $SHA - ready-check computed TRUST-PATH: yes (the diff touches a CI trust path). Have an independent judge rule GO on this head, then run: go.sh --trust-reviewed <judge qid> $PR $SHA. No GO written." >&2
    exit 8
fi

# a Critical or Important finding the worker deferred on its own never merges:
# cr-disposition.sh check refuses unless a judge (or, for an Important off a
# trust path, the chief) recorded a follow-up with its three risk attests.
if [ "$FORK_SET" -eq 0 ] && [ "$FIX_SET" -eq 0 ]; then
    DTRUST=no
    printf '%s\n' "$READY_OUT" | grep -qx 'TRUST-PATH: yes' && DTRUST=yes
    if ! DISP_OUT=$(bash "$HERE/cr-disposition.sh" check "$PR" "$SHA" --trust-path "$DTRUST" 2>&1); then
        printf '%s\n' "$DISP_OUT" >&2
        echo "go: refusing the GO for PR #$PR at $SHA - a Critical or Important finding has no valid disposition (above). A judge (or the chief, for an Important off a trust path) records one with cr-disposition.sh record, or the PR fixes it. No GO written." >&2
        exit 9
    fi
fi

# the mac binds the repo (himmel-go-v2|<nwo>|<pr>|<sha>) - a GO
# minted for one repo's PR #N at a sha must not validate another repo's PR #N
# at the same sha. Resolve nwo from the HARNESS ANCHOR (not the PR's own
# repo), the same way merge-on-green.sh's own cwd_nwo does, so a worktree
# copy cannot forge it.
NWO=$(cd "$ANCHOR" && "$GH_READ" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || NWO=""
# A --repo GO signs that repo's nwo (an adapter or adopted repo, allowlisted
# above): it validates for that repo's PR only, never for a himmel PR of the
# same number and sha.
[ "$FORK_SET" -eq 0 ] || [ -z "$NWO" ] || NWO="$FORK"
if [ -z "$NWO" ]; then
    echo "go: cannot resolve this repo's owner/name (gh repo view failed) - no GO written; the mac binds the repo" >&2
    exit 1
fi

# sign the GO. The key is minted here, on the chief's first GO
# (umask 077 + noclobber: mode 0600, never overwrites an existing key);
# go_gate verifies it and never mints one.
if [ -z "${HOME:-}" ]; then
    echo "go: HOME is unset - cannot locate the GO key" >&2
    exit 1
fi
KEY=$(go_key_file)
if [ ! -e "$KEY" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "go: openssl is required to mint the GO key" >&2
        exit 1
    fi
    # mint to a temp file in the same directory first and
    # validate it as 64 lowercase hex BEFORE moving it into place - a failed
    # `openssl rand` (disk full, killed mid-write) used to leave an
    # empty/partial file at $KEY itself, which is sticky: every later run sees
    # `-e "$KEY"` true and never re-mints, failing closed forever. mv -n never
    # clobbers a key another process won the race to mint first.
    KEYDIR=$(dirname "$KEY")
    ( umask 077 && mkdir -p "$KEYDIR" ) 2>/dev/null || true
    TMPKEY=$(umask 077 && mktemp "$KEYDIR/.go-hmac.XXXXXX" 2>/dev/null) || TMPKEY=""
    if [ -n "$TMPKEY" ]; then
        ( umask 077; openssl rand -hex 32 > "$TMPKEY" ) 2>/dev/null || true
        if grep -qxE '[0-9a-f]{64}' "$TMPKEY" 2>/dev/null; then
            # prim-ok: mv -n never clobbers a key another process minted first; atomic_write would replace it
            mv -n "$TMPKEY" "$KEY" 2>/dev/null || true
        fi
        rm -f "$TMPKEY" 2>/dev/null || true
    fi
fi
if [ -e "$KEY" ] && ! grep -qxE '[0-9a-f]{64}' "$KEY" 2>/dev/null; then
    echo "go: the GO key at $KEY exists but is not 64 lowercase hex chars - remedy: remove $KEY (it was left behind by a previously failed mint) and re-run go.sh so it can mint a fresh one; no GO written" >&2
    exit 1
fi
MAC_OK=1
if [ "$FIX_SET" -eq 1 ]; then
    # the fix-GO signs the red run id too, under its own domain tag.
    MAC=$(go_msg_mac himmel-go-fixred-v1 "$NWO|$PR|$SHA|$FIXRUN") || MAC_OK=0
else
    MAC=$(go_mac "$PR" "$SHA" "$NWO" "$TRUST") || MAC_OK=0
fi
if [ "$MAC_OK" -eq 0 ]; then
    echo "go: cannot sign the GO - the key at $KEY is unreadable or not 64 hex chars, or openssl is missing; no GO written" >&2
    exit 1
fi

DIR="$ROOT/.locks/go"
DEST="$DIR/$PR.$SHA"
[ "$FIX_SET" -eq 0 ] || DEST=$(go_fixred_file "$ROOT" "$PR" "$SHA" "$FIXRUN")
BY="${CHIEF_SESSION_NAME:-${USER:-$(id -un 2>/dev/null || echo unknown)}@$(hostname 2>/dev/null || uname -n)}"
BY=$(printf '%s' "$BY" | tr -d '\r\n')
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if ! mkdir -p "$DIR" || ! TMP=$(mktemp "$DIR/.go.XXXXXX"); then
    echo "go: cannot create a temp file under $DIR" >&2
    exit 1
fi
if ! { printf 'pr=%s\nhead=%s\nby=%s\nat=%s\n' "$PR" "$SHA" "$BY" "$AT" \
        && { [ -z "$TRUST" ] || printf 'trust-reviewed=%s\n' "$TRUST"; } \
        && { [ "$FIX_SET" -eq 0 ] || printf 'fix-main-red-run=%s\n' "$FIXRUN"; } \
        && printf 'mac=%s\n' "$MAC"; } > "$TMP" || ! mv -f "$TMP" "$DEST"; then # prim-ok: any failed printf must fail the GO write; a pipe into atomic_write hides the producer's status
    rm -f "$TMP"
    echo "go: could not write $DEST" >&2
    exit 1
fi

# persist the GO as a verdict record under its own qid, go-pr-<n>,
# one file per head, so it never shares a directory with a judge's verdicts/<qid>/.
# The deciding session's model and effort come from --model / --effort or the
# HIMMEL_VERDICT_* env, else `unknown`. Logging never blocks the GO: a failure
# only warns, the GO file above is already written.
if [ "$FIX_SET" -eq 0 ]; then
    [ -n "$GO_MODEL" ] || GO_MODEL="${HIMMEL_VERDICT_MODEL:-}"
    [ -n "$GO_EFFORT" ] || GO_EFFORT="${HIMMEL_VERDICT_EFFORT:-${CLAUDE_CODE_EFFORT_LEVEL:-}}"
    case "$GO_MODEL" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._:/\[\]-]*) GO_MODEL=unknown ;; esac
    case "$GO_EFFORT" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._:/\[\]-]*) GO_EFFORT=unknown ;; esac
    GO_SCRATCH="/tmp/claude-$(id -u)"
    GO_EVD=""
    { [ -d "$GO_SCRATCH" ] || mkdir -m 700 "$GO_SCRATCH" 2>/dev/null; } &&
        GO_EVD=$(mktemp -d "$GO_SCRATCH/go-persist.XXXXXX") # prim-ok: write-verdict.sh takes evidence only from /tmp/claude-<uid>
    if [ -n "$GO_EVD" ] \
       && printf 'chief GO for %s PR #%s\nby: %s\nat: %s\ntrust-reviewed: %s\n' "$NWO" "$PR" "$BY" "$AT" "${TRUST:-none}" > "$GO_EVD/evidence.md" \
       && GO_WV=$(bash "$HERE/write-verdict.sh" "go-pr-$PR" GO "$SHA" --pr "$PR" --judge "chief-go-$SHA" \
            ${VREPO:+--repo "$VREPO"} --evidence-file "$GO_EVD/evidence.md" --model "$GO_MODEL" --effort "$GO_EFFORT" 2>&1); then
        :
    else
        echo "go: warning - the GO is written but its verdict record was not persisted: ${GO_WV:-could not stage the evidence under $GO_SCRATCH}" >&2
    fi
    [ -z "${GO_EVD:-}" ] || rm -rf "$GO_EVD"
fi
printf '%s\n' "$DEST"
