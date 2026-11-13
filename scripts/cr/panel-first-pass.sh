#!/usr/bin/env bash
# scripts/cr/panel-first-pass.sh - step 3.0 critic-panel first pass, extracted
# verbatim (in behavior) from .claude/commands/pr-check.md.
#
# WHY A SCRIPT, NOT AN INLINE FENCE: this logic used to run as a ```bash
# block inside the /pr-check runbook, executed by the orchestrating Claude
# session's Bash tool. Claude Code's worktree-isolation guard statically
# screens every bash command run in a worktree-isolated session and refuses
# anything it cannot verify at a glance. The step-3.0 fence trips several of
# those refusals at once: any CLAUDE_PROJECT_DIR reference (unset in Bash-tool
# shells), an unresolvable env var, a "$var"/literal path where the quote does
# not span the whole path, a runtime value passed as a dash-flag operand, and
# ${var} braced expansion. None of those restrictions apply inside a script
# file - only the runbook's own command line is screened - so pulling this
# fence into a real script removes the parse surface entirely.
#
# Usage:
#   bash scripts/cr/panel-first-pass.sh --head <sha> --branch <name> [--context-file <f>]
#   bash scripts/cr/panel-first-pass.sh --pr <n> --head <40-hex sha> --branch <headRefName> [--context-file <f>]
#
# --pr: an outside PR reviewed from its fetched ref refs/himmel/outside/<n>, its branch never
# checked out. --head must equal that ref and --branch is the PR's headRefName. The round is
# always full and comes from review-round.sh start --pr (the authorization and the cap), the
# diff base is the merge base with the PR's base branch, the panel is pinned to the ref
# (--pin-ref; a panel that lacks it is refused, exit 7, before a round is spent), the
# CR_TARGET_* seam names the branch, head and PR, and the round-scope row's source is pr-diff.
# Only the checked-out-branch check is skipped.
#
# --context-file: code beyond the diff every critic may cite (format in
# critic-first-pass.sh --help); forwarded to critic-panel.sh.
#
# The second and third rounds review only the change since the last round:
# review-round.sh from names the start point, the diff is <from>..<head>, and
# the whole PR rides as the context file (unless the caller passed one). Any
# doubt about the start point reviews the full diff, saying why on stderr. After
# the panel, critic-pre-existing-tag.py tags an Important finding on code older
# than the PR [pre-existing] and sets the ledger field review-round.sh defer reads.
#
# --head/--branch are REQUIRED and must be step 1's CAPTURED values, never
# re-derived here: review the SHA the ledger will certify, not
# live HEAD, and pin the branch too - a SHA pin alone would pass a switch to a
# different branch sitting at the same commit.
#
# Env:
#   CR_PROFILE - loaded from the primary checkout's .env (a live env var
#     already set wins); CR_PROFILE=none skips the panel entirely
#     (claude-only, no spend). Passed through to critic-panel.sh, which
#     resolves its own tiers from it - this script never
#     hand-computes a tier filter.
#
# Stdout/stderr contract (the calling session reads BOTH streams and must
# never merge them):
#   stdout - "captured diff base: <db> (<db_sha>)" (the session
#            carries $db_sha forward as a literal into step 3.2), followed by
#            the panel's merged findings block, if any.
#   stderr - every status/skip note, every "panel-availability: ..." line
#            captured from critic-panel.sh, and (on exit 7) the ABORT text.
#
# Exit codes:
#   0 - ran to completion (panel invoked, skipped, or failed open to
#       claude-only). Findings, if any, are on stdout.
#   2 - usage error: missing --head or --branch, or (--pr) a PR number or --head that is
#       not a plain number / full 40-hex sha, --branch is outside the safe alphabet, or
#       outside-contributors.sh cannot be loaded.
#   5 - (--pr only) review-round.sh check or start --pr refused: the PR's author is not
#       authorized for a no-checkout review, or the round state could not be written. The
#       check runs before the known-findings preflight, so a refused author leaves no
#       preflight row. Nothing was reviewed or recorded.
#   3 -the branch has no preflight row and the step 2.8 known-findings pass
#       it ran first has open hits: no round was started. Close the hits and
#       record the pass (the message names both commands), then re-run.
#   9 - that preflight could not be run or recorded: no round was started.
#   8 - review-round.sh refused another round: the three-round cap, or,
#       with --full, an outside PR past its three full rounds (the
#       maintainer-takeover line). Nothing was reviewed.
#   7 - input-pin failure. Causes, all ABORT: (a) the
#       --head this script was given names no commit in this repo, detected
#       here before any git command consumes it; (b)
#       pin MISMATCH reported by critic-panel.sh, on the FIRST attempt or
#       independently on the rtk retry; (c) the diff base cannot be fetched or
#       resolved; (d) (--pr only) critic-panel.sh does not refuse a --pin-ref ref name git cannot hold
#       (the probe runs the panel once; no member runs), the PR's base branch name is outside the
#       safe alphabet, refs/himmel/outside/<n>
#       is not at --head, --branch is not the PR's headRefName, or the PR's base branch
#       or merge base cannot be read, or (e) the PR diff is over the 204800 bytes the
#       critics read (CRITIC_FIRST_PASS_CAP_BYTES), refused before a round starts; the rtk
#       retry's diff is measured the same way (that round stays counted). ABORT: nothing was reviewed, nothing was recorded,
#       and a round already started is given back (review-round.sh abort, --pr for an
#       outside PR). A round whose panel recorded a row stays counted. Never degrades to claude-only - re-run
#       /pr-check from step 1.
#   Every other critic-panel.sh failure fails OPEN to claude-only (this
#   script still exits 0; panel findings are empty and a loud note went to
#   stderr). Panel exit 6 (a refusal to certify) gets its own note
#   instead of the all-critics-failed text.
set -uo pipefail
# a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/cr/base-resolver.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/base-resolver.sh"

HEAD_SHA=""
BRANCH=""
PR=""
CONTEXT_FILE=""
FULL=0
# The context file a later round builds for itself, removed on every exit.
ctx_tmp=""
trap '[ -z "$ctx_tmp" ] || rm -f "$ctx_tmp"' EXIT
while [ $# -gt 0 ]; do
    case "$1" in
        --head)
            [ $# -ge 2 ] || { echo "panel-first-pass: --head requires a commit SHA" >&2; exit 2; }
            HEAD_SHA="$2"; shift 2 ;;
        --branch)
            [ $# -ge 2 ] || { echo "panel-first-pass: --branch requires a branch name" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        --pr)
            [ $# -ge 2 ] || { echo "panel-first-pass: --pr requires a PR number" >&2; exit 2; }
            PR="$2"; shift 2 ;;
        --context-file)
            # Code beyond the diff for every critic (critic-first-pass.sh
            # --context-file); forwarded to critic-panel.sh as given.
            [ $# -ge 2 ] || { echo "panel-first-pass: --context-file requires a file" >&2; exit 2; }
            CONTEXT_FILE="$2"; shift 2 ;;
        --full)
            # Rounds 1-3 review the whole branch (an outside PR); never lifts the cap.
            FULL=1; shift ;;
        *)
            echo "panel-first-pass: unknown arg: $1" >&2; exit 2 ;;
    esac
done
if [ -n "$CONTEXT_FILE" ] && { [ ! -f "$CONTEXT_FILE" ] || [ ! -r "$CONTEXT_FILE" ]; }; then
    echo "panel-first-pass: --context-file '$CONTEXT_FILE' is not a readable file" >&2
    exit 2
fi
[ -n "$HEAD_SHA" ] || { echo "panel-first-pass: --head is required (step 1's captured SHA)" >&2; exit 2; }
[ -n "$BRANCH" ]   || { echo "panel-first-pass: --branch is required (step 1's captured branch)" >&2; exit 2; }
# the round counter and ledger are per-branch shared state; only
# the branch checked out in cwd may be written (review-round.sh refuses too).
if [ -n "$PR" ]; then
    # An outside PR's branch is never checked out: its head is the fetched ref, which --head must equal.
    if ! [[ "$PR" =~ ^[1-9][0-9]{0,8}$ ]] || ! [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "panel-first-pass: --pr needs a plain PR number and a full 40-hex --head" >&2
        exit 2
    fi
    # The branch is substituted as a literal into later fences and echoed in messages: keep it to the safe alphabet.
    if [[ "$BRANCH" =~ [^A-Za-z0-9._/+-] ]] || ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
        echo "panel-first-pass: --branch is outside the safe alphabet [A-Za-z0-9._/+-] or is not a branch name. Nothing was reviewed and nothing was recorded." >&2
        exit 2
    fi
    FULL=1
    # shellcheck source=scripts/lib/outside-contributors.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/outside-contributors.sh" || { echo "panel-first-pass: cannot load scripts/lib/outside-contributors.sh" >&2; exit 2; }
    # A panel that cannot pin to the ref would verify the live checkout instead and certify the wrong tree.
    pin_probe_err="$(printf 'pin-probe\n' | bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --branch pin-probe --pin-ref refs/himmel/outside/0..0 2>&1 >/dev/null)"
    pin_probe_rc=$?
    case "$pin_probe_err" in *"REFUSING --pin-ref"*) ;; *) pin_probe_rc=1 ;; esac
    if [ "$pin_probe_rc" -ne 7 ]; then
        echo "panel-first-pass ABORT - critic-panel.sh does not honour --pin-ref (a ref that cannot exist was not refused with exit 7), so the panel cannot be pinned to refs/himmel/outside/$PR instead of the live checkout. A --pr review is refused rather than run unpinned: nothing was reviewed, nothing was recorded, no round was spent." >&2
        exit 7
    fi
    pr_ref_sha="$(git rev-parse --verify --quiet "refs/himmel/outside/$PR^{commit}" 2>/dev/null)" || pr_ref_sha=""   # swallow-ok: an empty ref fails the equality check on the next line (exit 7)
    if [ "$pr_ref_sha" != "$HEAD_SHA" ]; then
        echo "panel-first-pass ABORT - refs/himmel/outside/$PR is at '${pr_ref_sha:-nothing}', not at --head $HEAD_SHA. Fetch the PR head first (pr-check-outside.sh --pr). Nothing was reviewed and nothing was recorded." >&2
        exit 7
    fi
else
    current_branch="$(git branch --show-current 2>/dev/null)" || current_branch=""
    if [ -z "$current_branch" ] || [ "$current_branch" != "$BRANCH" ]; then
        echo "panel-first-pass: --branch '$BRANCH' is not the branch checked out in this directory ('${current_branch:-detached HEAD}') - run it from that branch's worktree" >&2
        exit 2
    fi
fi

# validate the INPUT PIN before any git command consumes it.
# A --head naming no commit in this repo is a CALLER error, not a reviewer
# outage, and the two are indistinguishable downstream: `git diff
# <base>...<bad-head>` fails rc=128, the fail-open branch below reports
# "critic panel unavailable - claude-only review", and the run exits 0 in
# under a second having reviewed nothing. A session that trusts rc=0 then
# records a claude-only round and clears the marker. An unresolvable pin is
# a stronger failure than the MISMATCH critic-panel.sh reports at exit 7, so
# it takes the same exit: ABORT, never a degrade. This runs BEFORE the diff,
# so it never competes with the rc=128 fail-open, which keeps its own job
# (a diff that fails for some reason OTHER than an unresolvable pin).
if ! git rev-parse --verify --quiet "$HEAD_SHA^{commit}" >/dev/null 2>&1; then
    echo "panel-first-pass ABORT - --head $HEAD_SHA does not resolve to a commit in this repo. This is an input-pin failure, NOT a critic outage: nothing was reviewed and nothing was recorded. Re-check the SHA step 1 printed (never expand a short hash by hand) and re-run /pr-check from step 1." >&2
    exit 7
fi

# Resolve the protected default (main OR master) for the diff base.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if [ -n "$PR" ]; then
    # The base is the PR's own base branch as the forge names it, and the diff base the merge base of
    # that branch with the fetched PR ref (the one helper the security audit uses too).
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
    pr_gh=(gh)
    [ ! -f "$HIMMEL_ROOT/scripts/lib/gh-read.sh" ] || pr_gh=(bash "$HIMMEL_ROOT/scripts/lib/gh-read.sh")
    db=""; pr_head_name=""; pr_names=""
    if [ -n "${_TIMEOUT_BIN:-}" ]; then
        pr_names="$("$_TIMEOUT_BIN" -k 5 20 "${pr_gh[@]}" pr view "$PR" --json baseRefName,headRefName --jq '.baseRefName, .headRefName' 2>/dev/null)" || pr_names=""   # swallow-ok: empty names are refused below (exit 7)
    fi
    case "$pr_names" in
        *$'\n'*) db="${pr_names%%$'\n'*}"; pr_head_name="${pr_names#*$'\n'}" ;;
    esac
    # The ledger rows are keyed on --branch, so it must be the branch the forge names for this PR.
    if [ -n "$pr_head_name" ] && [ "$pr_head_name" != "$BRANCH" ]; then
        echo "panel-first-pass ABORT - --branch is not PR #$PR's headRefName as the forge names it. Nothing was reviewed and nothing was recorded." >&2
        exit 7
    fi
    if [ -n "$db" ] && { [[ "$db" =~ [^A-Za-z0-9._/+-] ]] || ! git check-ref-format --branch "$db" >/dev/null 2>&1; }; then
        echo "panel-first-pass ABORT - PR #$PR's base branch name as the forge names it is outside the safe alphabet [A-Za-z0-9._/+-] or is not a branch name. Nothing was reviewed and nothing was recorded." >&2
        exit 7
    fi
    db_sha=""
    if [ -n "$db" ]; then
        db_sha="$(outside_pr_merge_base "$PR" "$db")" || db_sha=""   # swallow-ok: an empty merge base is refused on the next line (exit 7)
    fi
    if [ -z "$db_sha" ] || [ -z "$pr_head_name" ]; then
        echo "panel-first-pass ABORT - could not read PR #$PR's base and head branch names, or its merge base with refs/himmel/outside/$PR. Nothing was reviewed and nothing was recorded." >&2
        exit 7
    fi
else
db=$(. "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null && default_branch || echo main)
# Fetch ONCE at the start of the row, then capture the BASE commit through the
# shared origin-first resolver. A repository with no origin falls
# back to its local branch; a repository that HAS origin must not silently
# certify a stale cached ref when the refresh itself failed.
review_root="$(git rev-parse --show-toplevel 2>/dev/null)" || review_root=""
if [ -z "$review_root" ] || ! cr_fetch_base "$review_root" "$db"; then
    echo "panel-first-pass ABORT - could not fetch origin/$db, so the current diff base cannot be pinned safely. Nothing was reviewed and nothing was recorded. Re-run /pr-check from step 1." >&2
    exit 7
fi
base_ref="$(cr_resolve_base_ref "$review_root" "$db")"
db_sha="$(git -C "$review_root" rev-parse --verify --quiet "$base_ref^{commit}" 2>/dev/null)" || db_sha=""
if [ -z "$db_sha" ]; then
    echo "panel-first-pass ABORT - diff base $base_ref does not resolve to a commit. Nothing was reviewed and nothing was recorded. Re-run /pr-check from step 1." >&2
    exit 7
fi
fi
echo "captured diff base: $db ($db_sha)"   # carry this literal into step 3.2

# load CR_PROFILE from the PRIMARY checkout's .env (a live process
# env var wins) so /pr-check honours it DETERMINISTICALLY - even from a
# worktree, where the gitignored .env is not present (load_dotenv resolves the
# primary checkout via git-common-dir). We do NOT hand-compute a tier filter:
# the panel derives its tiers from CR_PROFILE itself and treats it as
# authoritative (closes the free-only drift). Just export CR_PROFILE and
# honour the none skip below.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
export CR_PROFILE

diff_rc=0
# review the SHA the ledger will certify, not live HEAD.
# --head "$HEAD_SHA" plus --branch "$BRANCH" on the panel below make a moved
# checkout a REFUSAL (exit 7) instead of a silently-wrong review.
# Diff from the CAPTURED base SHA, not the live $db name: $db
# stays the operator-visible name in messages.
diff_range="$db_sha...$HEAD_SHA"
scoped_from=""   # the last round's head, once a round 2 or 3 reviews only the change since it
diff_out=$(git diff "$diff_range") || diff_rc=$?
# Bytes the critics count in a diff: they measure the diff text plus one trailing newline.
pr_over_cap() { # diff text: sets pr_diff_bytes and pr_cap; true when over the cap
    pr_cap="${CRITIC_FIRST_PASS_CAP_BYTES:-204800}"
    case "$pr_cap" in ''|*[!0-9]*) pr_cap=204800 ;; esac
    pr_diff_bytes="$(printf '%s\n' "$1" | wc -c | tr -d ' ')"
    [ "$pr_diff_bytes" -gt "$pr_cap" ]
}
pr_over_cap_abort() {
    echo "panel-first-pass ABORT - PR #$PR's diff is $pr_diff_bytes bytes, over the $pr_cap-byte cap the critics read, so a full review row would certify text nobody read. Nothing was reviewed and nothing was recorded; hand the PR to a maintainer takeover." >&2
    exit 7
}
if [ -n "$PR" ] && [ "$diff_rc" -eq 0 ]; then
    # The critics read only the first cap bytes of a diff: a full-scope row over a longer one would certify text nobody read.
    if pr_over_cap "$diff_out"; then pr_over_cap_abort; fi
fi
panel_avail_lines=""   # "panel-availability: <slug> ok|unavailable (rc=N)" lines
panel_findings=""      # the merged findings block
# elapsed tell: a real panel round takes ~2 minutes, so an empty
# findings block that arrived in ~0s is a bad pin or an outage, never a clean
# review. Only meaningful once the panel was actually INVOKED - the skip paths
# (CR_PROFILE=none, empty diff) legitimately return instantly.
panel_ran=0
panel_t0=$SECONDS

ceilings_header() {
    local ch_out ch_rc=0
    if [ -z "${HIMMEL_REPO:-}" ]; then
        echo "CEILINGS: not read (HIMMEL_REPO unset)" >&2
        return 0
    fi
    ch_out=$(bash "$HIMMEL_REPO/scripts/ledger/ceiling-lookup.sh" --range "$db_sha...$HEAD_SHA" </dev/null 2>/dev/null) || ch_rc=$?  # swallow-ok: a failed lookup prints a not-read header naming its rc below
    case "$ch_out" in
        CEILINGS:*) printf '%s\n' "$ch_out" >&2 ;;
        *) echo "CEILINGS: not read (the anchor's ceiling-lookup.sh failed, rc=$ch_rc)" >&2 ;;
    esac
    return 0
}

if [ "${CR_PROFILE:-}" = "none" ]; then
    # Explicit claude-only opt-out. Skip panel.
    echo "claude-only review (CR_PROFILE=none)"
    ceilings_header
elif [ "$diff_rc" -ne 0 ]; then
    # git itself failed - treat as panel unavailable, not empty-diff skip.
    echo "critic panel unavailable - claude-only review (git diff failed rc=$diff_rc: $diff_out)" >&2
    ceilings_header
elif [ -z "$diff_out" ]; then
    echo "empty diff - critic panel skipped"
    ceilings_header
else
    if [ -n "$PR" ]; then
        # Authorization first: a refused author must leave no preflight row. This only asks; start --pr below decides again.
        pr_auth_rc=0
        bash "$HIMMEL_ROOT/scripts/cr/review-round.sh" check --pr "$PR" --head "$HEAD_SHA" >/dev/null || pr_auth_rc=$?
        if [ "$pr_auth_rc" -ne 0 ]; then
            echo "panel-first-pass ABORT - PR #$PR at $HEAD_SHA is not authorized for a no-checkout review, or its round state could not be read (reason above). Nothing was reviewed and nothing was recorded." >&2
            exit 5
        fi
    fi
    # step 2.8 is structural: a branch with no preflight row gets the
    # known-findings pass run (and, when clean, recorded) before a score row
    # can exist. Open hits cannot be closed here, so they stop the run
    # with the commands that close them. clear-review-marker.sh gate 4e stays
    # the backstop.
    pf_ledger="$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl" # swallow-ok: a failed rev-parse names no ledger, so the preflight runs and ledger-append refuses (exit 9)
    if ! { [ -f "$pf_ledger" ] && awk -v b="\"branch\":\"$BRANCH\"" 'index($0, "\"kind\":\"preflight\"") && index($0, b) { f = 1 } END { exit !f }' "$pf_ledger"; }; then
        pf_t0=$SECONDS
        pf_rc=0
        pf_out=$(CR_LEDGER="$pf_ledger" bash "$HIMMEL_ROOT/scripts/cr/known-findings.sh" --diff "$diff_range" --area 2>&1) || pf_rc=$?
        printf '%s\n' "$pf_out" >&2
        if [ "$pf_rc" -eq 3 ]; then
            echo "panel-first-pass ABORT - the step 2.8 known-findings preflight has open hits on $BRANCH, so no round was started. Close each hit (fixed in a follow-up commit, waived with a reason, or checked), then record the pass and re-run /pr-check:" >&2
            echo "  bash \"$HIMMEL_ROOT/scripts/cr/known-findings.sh\" --diff --area" >&2
            echo "  bash \"$HIMMEL_ROOT/scripts/cr/ledger-append.sh\" preflight --head $HEAD_SHA --duration-secs <s> --hit <class>=fixed|checked|waived:<reason>" >&2
            exit 3
        fi
        if [ "$pf_rc" -ne 0 ] || ! CR_LEDGER="$pf_ledger" bash "$HIMMEL_ROOT/scripts/cr/ledger-append.sh" preflight --branch "$BRANCH" --head "$HEAD_SHA" --duration-secs "$((SECONDS - pf_t0))" >&2; then
            echo "panel-first-pass ABORT - could not run or record the step 2.8 known-findings preflight on $BRANCH (known-findings rc=$pf_rc). No round was started. Run it by hand, then re-run /pr-check:" >&2
            echo "  bash \"$HIMMEL_ROOT/scripts/cr/known-findings.sh\" --diff --area" >&2
            echo "  bash \"$HIMMEL_ROOT/scripts/cr/ledger-append.sh\" preflight --head $HEAD_SHA --duration-secs <s>" >&2
            exit 9
        fi
    fi
    if [ -n "$PR" ]; then
        # review-round.sh start --pr authorizes the PR itself and owns the cap; it takes no base.
        review_round="$(bash "$HIMMEL_ROOT/scripts/cr/review-round.sh" start --pr "$PR" --head "$HEAD_SHA")"
        round_rc=$?
        if [ "$round_rc" -eq 5 ]; then
            echo "panel-first-pass ABORT - PR #$PR at $HEAD_SHA is not authorized for a no-checkout review, or its round state could not be written (reason above). Nothing was reviewed and nothing was recorded." >&2
            exit 5
        fi
    else
        review_round="$(bash "$HIMMEL_ROOT/scripts/cr/review-round.sh" start --branch "$BRANCH" --head "$HEAD_SHA" --base-sha "$db_sha")"
        round_rc=$?
    fi
    full_takeover="panel-first-pass ABORT - outside PR past its three full rounds: hand it to a maintainer takeover (HIMMEL-9019). Nothing was reviewed."
    if [ "$round_rc" -eq 8 ] && [ "$FULL" -eq 1 ]; then
        echo "$full_takeover" >&2
        exit 8
    fi
    if [ "$round_rc" -eq 8 ]; then
        echo "panel-first-pass ABORT - the three-round /pr-check cap refused another round on $BRANCH (see the reason above). Nothing was reviewed." >&2
        exit 8
    fi
    if [ "$round_rc" -ne 0 ]; then
        echo "panel-first-pass ABORT - could not persist the review round for $BRANCH (rc=$round_rc). Nothing was reviewed." >&2
        exit "$round_rc"
    fi
    # give_back <rc>: an abort from here on reviewed nothing, so the round
    # just started is given back before the exit.
    give_back() {
        if [ -n "$PR" ]; then
            gb_args=(--pr "$PR" --head "$HEAD_SHA" --branch "$BRANCH")
        else
            gb_args=(--branch "$BRANCH" --head "$HEAD_SHA")
        fi
        if gb_out="$(bash "$HIMMEL_ROOT/scripts/cr/review-round.sh" abort "${gb_args[@]}")"; then
            echo "panel-first-pass: the aborted round was given back (round, reviewed head: $gb_out)" >&2
        else
            echo "panel-first-pass: the aborted round was NOT given back (review-round.sh abort rc=$?, reason above)" >&2
        fi
        exit "$1"
    }
    # scope_since_last_round: rounds 2 and 3 review only what changed since the
    # last round (review-round.sh from), with the whole PR as context for the
    # critic to cite. Any doubt about the start point keeps the full diff: an
    # empty or unreadable start point, HEAD itself, a start point HEAD does not
    # descend from, a merge of the default branch in range, an empty change, or
    # a context file that cannot be built. A caller's own --context-file stays.
    scope_since_last_round() {
        sl_why=""
        # -q --verify is spelled this way on purpose: the T9 mutant drops the head guard by its long spelling.
        sl_head="$(git rev-parse -q --verify "$HEAD_SHA^{commit}" 2>/dev/null)" || sl_head=""   # swallow-ok: an unresolvable head reads as "start point is HEAD itself" below, which keeps the full diff
        sl_from="$(bash "$HIMMEL_ROOT/scripts/cr/review-round.sh" from --branch "$BRANCH" 2>/dev/null)" || sl_why="the start point could not be read"   # swallow-ok: sl_why is set, which keeps the full diff
        sl_merges=""
        if [ -n "$sl_why" ]; then
            :
        elif [ -z "$sl_from" ]; then
            sl_why="no reviewed head precedes this round"
        elif [ -z "$sl_head" ] || [ "$sl_from" = "$sl_head" ]; then
            sl_why="the start point is HEAD itself"
        elif ! git merge-base --is-ancestor "$sl_from" "$sl_head" 2>/dev/null; then
            sl_why="HEAD does not descend from the start point"
        elif ! sl_merges="$(git rev-list --merges "$sl_from..$sl_head" "^$db_sha" 2>/dev/null)"; then   # swallow-ok: sl_why is set, which keeps the full diff
            sl_why="the range could not be listed"
        elif [ -n "$sl_merges" ]; then
            sl_why="a merge of the default branch is in range"
        elif git diff --quiet "$sl_from" "$sl_head" 2>/dev/null; then
            sl_why="the change since the start point is empty"
        fi
        if [ -z "$sl_why" ] && [ -z "$CONTEXT_FILE" ]; then
            ctx_tmp="$(mktemp -t cr-pfp-ctx.XXXXXX)" || ctx_tmp=""
            if [ -z "$ctx_tmp" ]; then
                sl_why="the context file could not be created"
            else
                # One {"range": [path, start, end]} line per new-side hunk of the
                # whole PR, a blank line, then the whole PR diff. A path git
                # quotes or that holds a control character is not listed.
                sl_ranges="$(git diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$db_sha...$sl_head" 2>/dev/null | awk '
                    /^\+\+\+ / { f = ""; p = substr($0, 5); if (substr(p, 1, 2) == "b/") { p = substr(p, 3); if (p !~ /["\\[:cntrl:]]/) f = p } next }
                    /^@@ / && f != "" && match($0, /[+][0-9]+(,[0-9]+)?/) {
                        s = substr($0, RSTART + 1, RLENGTH - 1); n = split(s, a, ",")
                        ln = (n > 1) ? a[2] + 0 : 1
                        if (ln > 0) printf "{\"range\":[\"%s\",%d,%d]}\n", f, a[1] + 0, a[1] + ln - 1
                    }')" || sl_ranges=""
                # diff_out is still the whole PR here (db_sha...HEAD_SHA, read above).
                if [ -z "$sl_ranges" ] || [ -z "$diff_out" ]; then
                    sl_why="the whole PR has no citable lines to give as context"
                elif ! printf '%s\n\n%s\n' "$sl_ranges" "$diff_out" > "$ctx_tmp"; then
                    sl_why="the context file could not be written"
                fi
            fi
        fi
        if [ -z "$sl_why" ]; then
            sl_diff="$(git diff "$sl_from..$sl_head" 2>/dev/null)" || sl_diff=""   # swallow-ok: an empty sl_diff sets sl_why on the next line, which keeps the full diff
            [ -n "$sl_diff" ] || sl_why="the change since the start point could not be read"
        fi
        if [ -n "$sl_why" ]; then
            [ -z "$ctx_tmp" ] || { rm -f "$ctx_tmp"; ctx_tmp=""; }
            echo "panel-first-pass: round $review_round reviews the full diff ($sl_why)" >&2
            return 0
        fi
        [ -z "$ctx_tmp" ] || CONTEXT_FILE="$ctx_tmp"
        diff_range="$sl_from..$sl_head"
        diff_out="$sl_diff"
        scoped_from="$sl_from"
        echo "panel-first-pass: round $review_round reviews $sl_from..$sl_head, the change since the last round; the whole PR rides as context" >&2
    }
    case "$review_round" in
        *" delta "*)
            if [ "$FULL" -eq 1 ]; then
                echo "$full_takeover" >&2
                give_back 8
            fi
            # the one delta round reviews only last-reviewed
            # head..HEAD_SHA, never the whole branch again.
            delta_from="${review_round##* delta }"
            review_round="${review_round%% *}"
            diff_range="$delta_from..$HEAD_SHA"
            diff_out=$(git diff "$diff_range") || diff_rc=$?
            if [ "$diff_rc" -ne 0 ] || [ -z "$diff_out" ]; then
                echo "panel-first-pass ABORT - could not read the delta diff $diff_range (rc=$diff_rc). Nothing was reviewed." >&2
                give_back 5
            fi
            printf 'pr-check: delta round %s on %s (from %s)\n' "$review_round" "$BRANCH" "$delta_from"
            echo "delta round blocking set: Critical or escape-class only - every other finding is deferred at step 4.9."
            ;;
        *)
            printf 'pr-check: round %s of 3 on %s\n' "$review_round" "$BRANCH"
            if [ "$FULL" -eq 0 ]; then
                case "$review_round" in 2|3) scope_since_last_round ;; esac
            fi
            ;;
    esac
    [ -z "${CR_PROFILE:-}" ] && echo "Default cross-model CR - no free critics registered, using the PAID codex anchor (~2min; set CR_PROFILE=none for instant claude-only)."
    ceilings_header
    panel_ran=1
    panel_tmp=$(mktemp -t cr-panel-avail.XXXXXX)
    # CR_USAGE_LOG=1: each critic logs a chars/4 ESTIMATED usage
    # ledger record. No CRITIC_PANEL_TIERS here: the panel
    # resolves tiers from the exported CR_PROFILE.
    # --pr: the seam critic-first-pass.sh already honours carries the PR's branch, head and number.
    [ -z "$PR" ] || export CR_TARGET_BRANCH="$BRANCH" CR_TARGET_HEAD="$HEAD_SHA" CR_TARGET_PR="$PR" CR_TRIVIALITY_OVERRIDE=full
    panel_findings=$(printf '%s' "$diff_out" | CR_USAGE_LOG=1 CR_REVIEW_ROUND="$review_round" bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$HEAD_SHA" --branch "$BRANCH" ${PR:+--pin-ref "refs/himmel/outside/$PR"} --base "$db" --base-sha "$db_sha" --context-file "$CONTEXT_FILE" 2>"$panel_tmp")
    panel_rc=$?
    panel_avail_lines=$(cat "$panel_tmp"); rm -f "$panel_tmp"
    if [ "$panel_rc" -eq 7 ]; then
        # the checkout or the base branch moved
        # since step 1. Every later step is keyed to the captured
        # branch/SHA/base, so continuing would certify a review of code
        # nobody reviewed. ABORT the whole run; do NOT degrade to claude-only.
        cat >&2 <<'PINABORT'
/pr-check ABORT - critic-panel.sh exit 7: the checkout or the diff base moved since
step 1, so the review inputs no longer match the branch/SHA/base the ledger would
stamp. Nothing was reviewed and nothing was recorded.
Re-run /pr-check from step 1.
PINABORT
        give_back 7
    fi
    if [ "$panel_rc" -ne 0 ]; then
        # rc=1 collapses two causes: a genuine all-critics-failed panel, OR
        # (in an rtk-proxied environment) the plain `git diff` above returning
        # a stat summary instead of a unified diff, which critic-panel.sh
        # rejects as "no valid diff" and exits 1 on. Re-fetch the diff through
        # the rtk proxy and retry the panel ONCE before falling back. The
        # retry's output REPLACES (overwrites, not appends) both
        # panel_findings and panel_avail_lines from the first attempt, so a
        # stale first-attempt availability line can never leak into the
        # aggregate. rc=1 after the retry still degrades to claude-only,
        # loudly (same fail-open contract as below). Only rc=1 retries: an
        # exit-6 refusal is not a diff problem, and a retry would overwrite it.
        if [ "$panel_rc" -eq 1 ] && command -v rtk >/dev/null 2>&1; then
            # Same captured-base rule as the first attempt.
            retry_diff=$(rtk proxy git diff "$diff_range" 2>/dev/null) || retry_diff=""
            # the retry diff is a second diff the panel would read: measure it like the first
            if [ -n "$PR" ] && [ -n "$retry_diff" ] && pr_over_cap "$retry_diff"; then pr_over_cap_abort; fi
            if [ -n "$retry_diff" ]; then
                retry_tmp=$(mktemp -t cr-panel-avail.XXXXXX)
                panel_findings=$(printf '%s' "$retry_diff" | CR_USAGE_LOG=1 CR_REVIEW_ROUND="$review_round" bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$HEAD_SHA" --branch "$BRANCH" ${PR:+--pin-ref "refs/himmel/outside/$PR"} --base "$db" --base-sha "$db_sha" --context-file "$CONTEXT_FILE" 2>"$retry_tmp")
                panel_rc=$?
                panel_avail_lines=$(cat "$retry_tmp"); rm -f "$retry_tmp"
                # The retry is a SECOND panel invocation, so it has its own
                # pin window: the checkout can move between the first attempt
                # and this one. Without this check a retry-time exit 7 falls
                # through to the fail-open branch below and certifies stale
                # inputs.
                if [ "$panel_rc" -eq 7 ]; then
                    cat >&2 <<'PINABORTRETRY'
/pr-check ABORT - critic-panel.sh exit 7 on the rtk retry: the checkout or the
diff base moved mid-run, so the review inputs no longer match the branch/SHA/base
the ledger would stamp. Nothing was reviewed. Re-run
/pr-check from step 1.
PINABORTRETRY
                    give_back 7
                fi
            fi
        fi
        if [ "$panel_rc" -ne 0 ]; then
            # rc=1 after retry (or rtk absent / retry-diff empty) - fail-open.
            if [ "$panel_rc" -eq 6 ]; then
                # exit 6 is a deliberate fail-closed refusal, not
                # a failed panel. The panel recorded certify-refused on the
                # ledger, so clear-review-marker.sh holds this SHA closed. If that
                # write failed there is nothing to hold, so ABORT instead.
                case "$panel_avail_lines" in
                *"could not record certify-refused"*)
                    echo "/pr-check ABORT - critic-panel.sh exit 6 and the refusal could not be recorded on the CR ledger, so nothing would hold the CR marker closed. Fix the ledger path and re-run /pr-check from step 1." >&2
                    give_back 7
                    ;;
                esac
                echo "critic panel REFUSED to certify this run (exit 6: the citation-guard digest could not be computed - fix sha256sum/shasum) - claude-only review; the CR marker stays held at this SHA until the panel is re-run on a new HEAD" >&2
            elif [ "$panel_rc" -eq 2 ]; then
                # exit 2 is a usage error or a mktemp failure, not a failed
                # critic: name the cause the panel printed.
                case "$panel_avail_lines" in
                *"mktemp failed"*)
                    echo "critic panel unavailable (exit 2: critic-panel: mktemp failed - check free space in TMPDIR) - claude-only review" >&2
                    ;;
                *)
                    echo "critic panel unavailable (exit 2: usage error: ${panel_avail_lines%%$'\n'*}) - claude-only review" >&2
                    ;;
                esac
            else
                echo "critic panel unavailable (all critics failed) - claude-only review" >&2
            fi
            panel_findings=""
        fi
    fi
fi

# write_round_scope <source> <pr>: one round-scope row for a run whose panel
# ran and exited 0, read from the final diff range: full exactly when it is the
# captured base...HEAD, otherwise delta from the range's left side. A claude-only
# fallback (panel rc 1, 2 or 6) writes no row. It decides nothing about which
# critics answered (item 4 owns that). A failed write is reported and leaves no
# row, so ready-check item 16 refuses that head.
write_round_scope() {
    [ "$panel_ran" -eq 1 ] && [ "${panel_rc:-1}" -eq 0 ] || return 0
    wrs_source="$1" wrs_pr="$2"
    if [ "$diff_range" = "$db_sha...$HEAD_SHA" ]; then
        set -- --scope full
    else
        set -- --scope delta --from "${diff_range%%..*}"
    fi
    [ -z "$wrs_pr" ] || set -- "$@" --pr "$wrs_pr"
    if ! CR_LEDGER="$pf_ledger" bash "$HIMMEL_ROOT/scripts/cr/ledger-append.sh" round-scope --branch "$BRANCH" --head "$HEAD_SHA" \
        --base-sha "$db_sha" --round "$review_round" --source "$wrs_source" "$@" >/dev/null; then
        echo "panel-first-pass: could not record the round-scope row for $HEAD_SHA (ledger-append.sh, reason above)" >&2
    fi
}
if [ -n "$PR" ]; then write_round_scope pr-diff "$PR"; else write_round_scope panel-first-pass ""; fi

# Rounds 2 and 3 tag an Important finding on code older than the PR
# (critic-pre-existing-tag.py): git blame decides, and the ledger field
# review-round.sh defer reads is set by that script, never by a finding's text.
# On any failure the findings stay as the panel gave them, and an untagged
# Important keeps blocking.
case "${review_round:-}" in
    2|3)
        if [ -n "$panel_findings" ]; then
            tag_head="$(git rev-parse -q --verify "$HEAD_SHA^{commit}" 2>/dev/null)" || tag_head=""   # swallow-ok: an empty --head makes the tagger tag nothing, and an untagged Important keeps blocking
            if tagged="$(printf '%s\n' "$panel_findings" | python3 -I "$HIMMEL_ROOT/scripts/cr/critic-pre-existing-tag.py" \
                --round "$review_round" --head "$tag_head" --db-sha "$db_sha" --branch "$BRANCH" ${scoped_from:+--from "$scoped_from"})"; then
                panel_findings="$tagged"
            else
                echo "panel-first-pass: critic-pre-existing-tag.py failed (rc=$?); the findings stay untagged" >&2
            fi
        fi
        ;;
esac

# Surface the captured availability lines to our own stderr
# step 4.5 records these): this script's process exits when it returns, so -
# unlike the original inline fence, whose shell variables lived on for later
# fences in the same session - the calling session can only carry
# panel_avail_lines forward by reading it here.
[ -n "$panel_avail_lines" ] && printf '%s\n' "$panel_avail_lines" >&2

# elapsed tell next to the availability rows, so a reader who
# sees an empty findings block also sees how long it took to produce one.
if [ "$panel_ran" -eq 1 ] && [ -z "$panel_findings" ]; then
    echo "panel-elapsed: $((SECONDS - panel_t0))s with an EMPTY findings block (a real round is ~2min; a sub-second empty round means the panel did not review anything)" >&2
fi

# Surface $panel_findings on stdout (same pattern as $codex_findings in 3.1 /
# $coderabbit_findings in 3.2) so the orchestrating session can carry it into
# step 3.2 phase A and adjudicate it before the conservation decision.
if [ -n "$panel_findings" ]; then
    printf '%s\n' "$panel_findings"
fi
exit 0
