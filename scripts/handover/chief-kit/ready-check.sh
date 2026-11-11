#!/usr/bin/env bash
# scripts/handover/chief-kit/ready-check.sh — mechanize the chief's READY
# verification. Chief A ran this same
# checklist by hand ~12 times on 2026-09-18 with zero variance; the fleet cap
# doubling (4 -> 8) doubles the READYs per hour, so it is worth a script.
#
# Read-only except the shared PR snapshot cache, which it refreshes (TTL 0:
# every run reads the PR live, never a same-head cached snapshot). Prints one
# line per check, then READY-CHECK PASS|FAIL. It does
# NOT read the three-dot diff — that judgement call stays the chief's own,
# and the script says so on its last line.
#
# Usage: ready-check.sh [--contract yes|no] [--observe] [--require-contract] <pr-number> <full-40-hex-head-sha>
#        ready-check.sh --only 7 <pr-number>
#   --only 7 runs check 7 — a worker's own pre-READY lint of its PR body, the
#   same code the chief runs — plus the warn-only check 14 and check 20 on
#   check 7's head. Prints COVERAGE-LINT PASS|FAIL.
#   --contract yes|no names the merge contract for check 17: yes when the merge
#   completes the ticket (merge-on-green.sh --jira-transition), no for a partial
#   merge. A keyed title with no --contract FAILs by default. --observe opts
#   into a warn-only read for callers that write no GO. --require-contract
#   stays accepted for compatibility (go.sh, ready-go.sh, auto-go.sh pass it).
#
# Checks:
#   1. Shared snapshot: headRefOid == <head-sha> (full 40 chars); mergeStateStatus
#      == CLEAN (retries briefly on UNKNOWN — a transient GitHub computation
#      state, not a verdict; a re-read waits 5 s for a peer's snapshot lock and
#      a failed one keeps the last good read). A failed snapshot read prints the
#      lib's reason under item 1.
#   2. statusCheckRollup: every check IDENTITY's LATEST run is COMPLETED with
#      conclusion SUCCESS/SKIPPED/NEUTRAL (CheckRun), or state SUCCESS
#      (StatusContext) — a superseded run (e.g. an earlier CANCELLED run
#      before a later SUCCESS) is not judged. A CANCELLED row of an older
#      run is also dropped when a newer run of the same workflow is wholly
#      green (read from the run id in detailsUrl); no other state is dropped
#      that way. Identity =
#      CheckRun name + workflowName when present, else StatusContext
#      context. Read via --json, never `gh pr checks` text (a green check
#      whose name contains a space mislabels under naive text parsing).
#      With the CI_GO_GATE repository variable on, a FAIL here also prints
#      the `CR-FIRST HOLD <reason> <age>` lines of scripts/lib/cr-first-release.sh
#      (read-only: no label written); variable off or unset: nothing is added.
#   3. GraphQL unresolved review threads == 0. The snapshot follows every
#      page with cursor/hasNextPage guards and the same 50-page ceiling as
#      check-ci.sh; a >100-thread PR cannot silently short-circuit to PASS.
#   4. CR ledger: <git-common-dir>/cr-critic-scores.jsonl has >=1 row for
#      <head-sha> with status "ok": a critic avail row (not claude,
#      claude-floor or codex-adv), or an evidence/judge-go/dependabot-go row for
#      this PR branch (dependabot-go: scripts/cr/dependabot-go.sh, a signed judge
#      GO at this head on a Dependabot manifest-only PR).
#   5. The PR's first commit carries the attestation trailers the pre-push
#      gates require, for the file classes that trip them: `Platforms
#      tested:` when the diff touches scripts/**, *.sh/.bash/.zsh/.ps1/.psm1/
#      .psd1/.cmd/.bat or **/bin/*, `Security reviewed:` when the diff
#      touches anything outside *.md/*.txt/docs/**/handovers/**. Reuses the
#      PLATFORM_RE / ATTEST_RE from scripts/hooks/check-platforms-tested.sh
#      and the TOKEN_RE from scripts/hooks/check-security-reviewed.sh
#      VERBATIM (git grep -n 'Platforms tested' -- scripts) rather than
#      re-deriving the token vocabulary or the file filters — those two
#      files carry the history of why each regex looks the way it does.
#   6. Every commit subject in the PR carries a ticket ID, using the same
#      pattern scripts/hooks/check-commit-msg.sh derives (TICKET_ID_PATTERN,
#      else "${JIRA_PROJECT_KEY}-[0-9]+", else a bare "#123" reference) —
#      except a commit with more than one parent (a real merge, e.g. a worker's
#      `Merge remote-tracking branch 'origin/main' into <branch>`), mirroring
#      scripts/ci/check-commit-range.sh's `git rev-list --no-merges`. Parent
#      count, not subject text, is the exemption signal. A second exemption:
#      when the PR author is an external contributor (not in
#      scripts/ci/ticket-id-internal-authors.txt, via ticket_id_author_is_external)
#      AND the PR title carries a ticket ID, unkeyed commit subjects pass with a
#      distinct PASS line, because the squash lands the title as main's subject.
#      An internal or bot author, an unkeyed title, or an unreadable author,
#      title or allowlist keeps the FAIL.
#
#   7. Ticket coverage: the PR body carries a `## Ticket coverage`
#      section, one list line per ask, each `done` or `deferred → HIMMEL-<n>`
#      (`->` accepted). FAIL on a missing/empty section, an unmarked line, a
#      deferred key that does not exist or is already Done/Closed/Resolved/
#      Won't Do, or is neither residual-labelled, older than the PR's own
#      ticket, nor linked (either direction, any type) from it. The deferral
#      keys must also equal the CR ledger's deferred_to rows for the PR head
#      (or for the reviewed head a same-branch trivial-descendant row names).
#      A Jira error reads UNKNOWN and fails — never a PASS.
#   9. A PR that changes a plugin bumps that plugin's version (same
#      rule as check-plugin-drift.sh --bump-required): the manifest version must
#      be strictly above CURRENT origin/main's (two PRs raising to the same
#      version merge CLEAN). A bump with no other file change in that plugin is
#      refused. A release cut (a PR that changes the root VERSION file) must
#      version every plugin it touches above main, bump-only included. Fetches origin/main and the PR
#      head (refs/pull/<n>/head) into the caller's repo; a PR touching no
#      plugin never reaches git. Any fetch/read failure FAILs.
#  10. Workflow dispatch: every .github/workflows/*.yml the PR
#      changes needs a completed, successful workflow_dispatch run at the PR
#      head sha (`gh run list --workflow <wf> --event workflow_dispatch
#      --commit <head>`), since ci.yml has no push trigger and the mode main
#      runs is otherwise never tested pre-merge. The FAIL line prints the exact
#      `gh workflow run` command. A dispatch run that FAILED at the head still
#      passes, as a PRE-EXISTING line, when every one of its failed jobs also
#      failed in the default branch's latest completed scheduled/push run of the
#      same workflow; a job red only on the PR still FAILs and is named, unless
#      the run logs show it failed only suites (`[FAIL] <suite> (` lines) that
#      also failed on main, in whatever job (a re-shard moved them); an
#      unreadable log or a job showing no failed suite keeps the FAIL. A head
#      with no dispatch run of its own passes the same way on a failed dispatch
#      run of the PR branch at an ANCESTOR of the head, when the PR's own change
#      to every file it touches is the same at that ancestor and at the head
#      (the head only merges main forward): the file is the same blob, or its
#      patch from the merge-base with origin/main has the same `git patch-id
#      --verbatim` (whitespace counts) at both (main edited another hunk). The old path of every rename
#      is held to the same test; an unreadable merge-base, diff or patch id
#      counts as changed. The PASS line names the ancestor sha and run id.
#      The PASS line carries the dispatch run ids. macos-cadence.yml also passes on a
#      dispatch run at the head that names its suites (run-name `macos-cadence
#      suites: <paths>`, the workflow's `suites` input) when the run's log shows
#      `[PASS] <suite>` for EVERY named suite, however red the rest of the run is;
#      the PASS line prints each suite. A named suite that failed or never ran
#      FAILs and is named. A changed workflow with no workflow_dispatch
#      trigger FAILs unless listed in WF_DISPATCH_EXEMPT below. Non-workflow
#      PRs are unaffected.
#  11. Added-but-unwired: every file the PR ADDS (status A only, so existing debt
#      never fails) that is a hook (scripts/hooks/*), a script (scripts/** with
#      an exec bit or a .sh/.mjs/.js/.ts/.py name), a skill (SKILL.md) or a suite
#      (test-*.sh, *.test.*) must be reached by some wiring at the PR head. What
#      counts as wired per kind is documented in
#      scripts/testing/check-added-unwired.sh, which this item calls. Fixture
#      paths are standalone by design.
#
# 12. Trust path: trust_path_check (scripts/lib/go-gate.sh, shared with
#      merge-on-green and ready-go) against the PR's files and the default
#      branch's scripts/ci/ci-trust-paths.txt. Prints `TRUST-PATH: yes|no` just
#      before the READY-CHECK line; go.sh refuses a plain GO on `yes`. A refusal
#      (unreadable list, unresolvable default branch, moved head) FAILs and prints
#      no TRUST-PATH line. READY_CHECK_ANCHOR (tests) replaces the harness anchor.
#
# 13. RED then GREEN: a PR that changes code carries one body line naming RED, then
#      GREEN (case-sensitive, whole words). Exempt: a doc-only PR (check 5's filter:
#      *.md/*.txt, docs/**, handovers/**) and a Dependabot dependency-only PR. An
#      unreadable file list FAILs. Not part of `--only 7`.
#
# 14. bug-origin line, WARN only: never a FAIL, never the marker or the exit code.
#      A PR whose title's first [KEY] is a Jira Bug carries one column-one line
#      outside any fence: bug-origin: <#pr|sha|unknown> <class> — <reason>. Prints
#      [PASS], [WARN] (none, malformed, duplicate), or [WARN] not checked (the title
#      or Jira read failed or timed out, an empty type, a missing lib, no timeout
#      binary). One bounded Jira read; `--only 7` adds one bounded gh pr view.
#
# 15. CodeRabbit rate-limited, WARN only: a head whose CodeRabbit status
#      is success + "Review rate limited" prints one [WARN] line saying no review was
#      posted. Never a FAIL, never the marker or the exit code; nothing prints for any
#      other state or an unreadable status. Not part of `--only 7`.
# 19. suite evidence: every suite the anchor's impacted-suites.sh lists for
#      merge-base..SHA has proof. Local proof is the head's `impacted` ledger row
#      (`local_pass`; a `ruled_skip` is counted and named apart from it); CI proof is an exact `ran 0 <path>` manifest
#      line of the run behind the latest SUCCESS `shell-unit (ubuntu-latest)`
#      check-run, whose run head_sha equals SHA. A suite on a PR-body
#      `Local suites: <path>` line needs local proof. Every subprocess and network
#      read is bounded (the reads of local files are not); an unreadable impacted
#      list, an unresolvable range, no timeout binary or a timed-out read FAILs. Not part
#      of `--only 7`.
#
# 16. outside-PR full review: for an outside PR (a fork, a deleted author, or a
#      non-Bot author not in scripts/ci/ticket-id-internal-authors.txt; the same
#      predicate `--outside <pr>` prints as `outside-pr: yes|no`, exit 2 when the
#      snapshot is unreadable), every record must sit at the head itself, keyed to
#      headRefName: 16b a full round-scope row, 16c the latest `lint` CheckRun of
#      workflow CI SUCCESS, 16d no path under scripts/ci/outside-lint-surface.txt,
#      16e no open or non-maintainer-resolved thread and check-ci.sh --threads-only
#      green, 16f an impacted row with rc 0 and skip_n 0, 16g a ran blast row when
#      scripts/cr/blast-scope.cjs says the diff touches the scope; for an author not
#      in ~/.himmel/outside-contributors.json, 16h a CodeRabbit success and 16i a
#      passed security audit (scripts/lib/outside-contributors.sh). CR_* overrides
#      are unset for 16e and 16h. Prints nothing for any other PR. Not part of `--only 7`.
#
# 17. Partial-merge remainder, the merge's exit 26 read at GO time: for a PR
#      title with a [KEY] (ticket_key_from_title, the merge's reader) and `--contract no`,
#      the PR body read through scripts/lib/pr_remainder.py (the merge's reader, run from
#      the anchor) must record a remainder, a `Remaining:` line or a `deferred -> KEY` line
#      under `## Ticket coverage`; `none`, a missing reader or no answer FAILs, and so does a
#      body whose every remaining ask is deferred to other tickets (the merge then completes
#      the ticket and refuses it too). `--contract yes` and a title with no key pass. No `--contract` on a keyed title FAILs by
#      default and warns with --observe. Not part of `--only 7`.
#
# 18. Open findings, the merge's gates 4 and 4b read at GO time: the head the
#      merge gates on can be an earlier round head (a judge GO moves it), where an Important
#      nobody ruled blocks a PR whose tip has green rows. This runs scripts/cr/
#      clear-review-marker.sh --check-findings (the merge's own ledger verdict, nothing
#      written) at the PR head as the merge reads it now and as it reads it once the GO
#      exists (--assume-go); a blocking finding, an undecided one, a malformed ledger, an
#      unreadable branch or any other exit FAILs. Not part of `--only 7`.
#
# 20. Conflicts resolved: the anchor's scripts/eval/conflicts/conflicts.py detect lists each
#      file a merge commit in origin/main..head resolved by hand. A file with no
#      `- <path> vs #<n>: <note>` line under the body's `## Conflicts resolved` (read
#      with that module's parse_body) FAILs, and the line to add is printed; an `ours`
#      resolution WARNs and names the other PR. A detection that cannot run (no head,
#      no detector, a failed fetch or git read, `unknown`) WARNs, never FAILs. Part of
#      `--only 7`, on check 7's head (headRefOid).
#
# Owner/repo are derived from `gh repo view --json owner,name`, never hard-
# coded (so this runs the same in any clone/fork). It writes no CR ledger rows,
# no GO files and no PR comments. Its writes are: `git fetch` into the repo it runs in
# (pr_fetch updates refs/remotes/origin/main and, when the head is not there, fetches
# refs/pull/<pr>/head, so it runs in a checkout where that is fine), a temp dir for
# item 19 (removed on exit), and item 19's append-only CI failure ledger (station state,
# report-only; it never changes a verdict; check-ci.sh writes the same rows at the red).
#
# Exit codes:
#   0 — READY-CHECK PASS
#   1 — READY-CHECK FAIL (one or more checks failed)
#   2 — usage, or cannot evaluate: gh/jq missing, repo/PR unreadable, a read GitHub refused or
#       stalled (the one QUOTA-PAUSE / GH-STALL line, no rows, a marker for the waiter), or the
#       READY_CHECK_DEADLINE cut (nothing was judged). A FAIL row from a refused read is never exit 1.
#
# Platform guard: POSIX bash 3.2+, same as go.sh. No mapfile.
set -u

_rcd_report() {
    local tok="" bucket="" why="" first=1 lib
    [ -s "${1:-}" ] || return 1
    lib="$(cd "$(dirname "$0")/../../lib" && pwd)"
    while read -r tok bucket why; do
        [ -n "$why" ] || continue
        (
            # shellcheck source=../../lib/gh-quota.sh
            . "$lib/gh-quota.sh" 2>/dev/null || exit 0
            [ "$first" -eq 0 ] || ghq_line "$tok" "$bucket" ready-check.sh "$why"
            [ -z "$2" ] || [ -z "$3" ] || ghq_mark_blocked "$2" "$3" ready-check.sh "$bucket" "$why"
        ) || true
        first=0
    done < "$1"  # read-sink-ok: our own mktemp refused file, never caller text
    [ "$first" -eq 0 ]
}

_rcd_child() {
    "$@" <&0 &
    rcd_pid=$!
    wait "$rcd_pid"
}
# shellcheck disable=SC2329  # reached only through _rcd_term, which the TERM trap invokes
_rcd_descendants() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do printf '%s\n' "$c"; _rcd_descendants "$c"; done  # swallow-ok: no pgrep or no children lists nothing, and only the child itself is signalled
}
# shellcheck disable=SC2329  # invoked by the TERM trap below, which shellcheck does not follow
_rcd_term() {
    local p kids
    if [ -n "${rcd_pid:-}" ]; then
        kids=$(_rcd_descendants "$rcd_pid")
        kill -TERM "$rcd_pid" 2>/dev/null
        wait "$rcd_pid" 2>/dev/null
        for p in $kids; do kill -TERM "$p" 2>/dev/null; done
    fi
    exit 143
}

# A self-armed deadline: the chief types this script bare, because a `timeout`
# prefix does not match the project allow rule. READY_CHECK_DEADLINE (whole seconds, default
# 150 = chief-wait's bound, above item 19's 105 s of bounds; 0 = none) bounds the whole run:
# the script re-runs itself under timeout and says so by name when it is cut.
if [ -z "${_READY_CHECK_ARMED:-}" ]; then
    rcd_s="${READY_CHECK_DEADLINE:-150}"
    case "$rcd_s" in ''|*[!0-9]*) rcd_s=150 ;; esac
    _TIMEOUT_BIN=""
    if [ "$rcd_s" -gt 0 ]; then
        # shellcheck source=../../lib/timeout-bin.sh
        . "$(cd "$(dirname "$0")/../../lib" && pwd)/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN runs without the deadline, as the per-read bounds below do
    fi
    rcd_ref=$(mktemp "${TMPDIR:-/tmp}/ready-check-refused.XXXXXX" 2>/dev/null) || rcd_ref=""  # swallow-ok: no scratch file runs this process unwrapped, as before
    if [ -n "$rcd_ref" ]; then
        rcd_buf=""; rcd_err=""; rcd_pid=""
        trap 'rm -f "$rcd_ref" "$rcd_buf" "$rcd_err"' EXIT
        trap '_rcd_term' TERM INT HUP
        rcd_pr=""; rcd_sha=""
        if [ "$#" -ge 2 ]; then
            rcd_sha="${*: -1}"; rcd_pr="${*: -2:1}"
            case "$rcd_pr" in ''|*[!0-9]*) rcd_pr="" ;; esac
            case "$rcd_sha" in *[!0-9a-f]*) rcd_sha="" ;; esac
            [ "${#rcd_sha}" -eq 40 ] || rcd_sha=""
            [ -n "$rcd_pr" ] && [ -n "$rcd_sha" ] || { rcd_pr=""; rcd_sha=""; }
        fi
        rcd_rc=0
        rcd_buf=""; rcd_err=""
        if [ -n "$_TIMEOUT_BIN" ]; then
            rcd_buf=$(mktemp "${TMPDIR:-/tmp}/ready-check-out.XXXXXX" 2>/dev/null) || rcd_buf=""  # swallow-ok: no buffer runs the child unbuffered below
            rcd_err=$(mktemp "${TMPDIR:-/tmp}/ready-check-err.XXXXXX" 2>/dev/null) || rcd_err=""  # swallow-ok: no buffer runs the child unbuffered below
        fi
        if [ -n "$_TIMEOUT_BIN" ] && [ -n "$rcd_buf" ] && [ -n "$rcd_err" ]; then
            _READY_CHECK_ARMED=1 _RCD_REFUSED="$rcd_ref" GH_READ_REFUSED_FILE="$rcd_ref" \
                _rcd_child "$_TIMEOUT_BIN" -k 5 "$rcd_s" bash "$0" "$@" >"$rcd_buf" 2>"$rcd_err" || rcd_rc=$?
            if [ "$rcd_rc" -ne 0 ] && _rcd_report "$rcd_ref" "$rcd_pr" "$rcd_sha"; then
                rm -f "$rcd_ref" "$rcd_buf" "$rcd_err"
                exit 2
            fi
            if [ "$rcd_rc" -eq 124 ] || [ "$rcd_rc" -eq 137 ]; then
                rm -f "$rcd_ref" "$rcd_buf" "$rcd_err"
                echo "ready-check: no verdict within the ${rcd_s} s deadline (READY_CHECK_DEADLINE); a gate read stalled, nothing was judged" >&2
                exit 2
            fi
            cat "$rcd_buf"; cat "$rcd_err" >&2  # read-sink-ok: our own mktemp buffers
            rm -f "$rcd_ref" "$rcd_buf" "$rcd_err"
            exit "$rcd_rc"
        fi
        rm -f "$rcd_buf" "$rcd_err"
        if [ -n "$_TIMEOUT_BIN" ]; then
            _READY_CHECK_ARMED=1 _RCD_REFUSED="$rcd_ref" GH_READ_REFUSED_FILE="$rcd_ref" \
                _rcd_child "$_TIMEOUT_BIN" -k 5 "$rcd_s" bash "$0" "$@" || rcd_rc=$?
        else
            _READY_CHECK_ARMED=1 _RCD_REFUSED="$rcd_ref" GH_READ_REFUSED_FILE="$rcd_ref" _rcd_child bash "$0" "$@" || rcd_rc=$?
        fi
        if [ "$rcd_rc" -ne 0 ] && _rcd_report "$rcd_ref" "$rcd_pr" "$rcd_sha"; then
            rm -f "$rcd_ref"
            exit 2
        fi
        rm -f "$rcd_ref"
        if [ "$rcd_rc" -eq 124 ] || [ "$rcd_rc" -eq 137 ]; then
            echo "ready-check: no verdict within the ${rcd_s} s deadline (READY_CHECK_DEADLINE); a gate read stalled, nothing was judged" >&2
            exit 2
        fi
        exit "$rcd_rc"
    fi
fi

usage() {
    local rc_primary
    rc_primary=$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || rc_primary=""
    case "$rc_primary" in */.git) rc_primary="${rc_primary%/.git}" ;; *) rc_primary="<primary-checkout>" ;; esac
    echo "usage: ready-check.sh [--contract yes|no] [--observe] [--require-contract] <pr-number> <full-40-hex-head-sha>" >&2
    echo "       ready-check.sh --only 7 <pr-number>   (ticket-coverage lint plus the conflicts-resolved check 20, for a worker before READY)" >&2
    echo "       ready-check.sh --outside <pr-number>  (prints outside-pr: yes|no, the item 16 predicate)" >&2
    echo "run it from the primary checkout, not a worktree (check 12 needs an up-to-date anchor): cd '$rc_primary' && bash '$rc_primary/scripts/handover/chief-kit/ready-check.sh' <pr-number> <full-40-hex-head-sha>" >&2
}

CONTRACT=""
REQUIRE_CONTRACT=1
while :; do
    case "${1:-}" in
        --contract)
            case "${2:-}" in
                yes|no) ;;
                *) usage; echo "ready-check: --contract takes yes or no (got '${2:-}')" >&2; exit 2 ;;
            esac
            [ -z "$CONTRACT" ] || { usage; echo "ready-check: --contract is given once" >&2; exit 2; }
            CONTRACT="$2"; shift 2 ;;
        --require-contract) REQUIRE_CONTRACT=1; shift ;;
        --observe) REQUIRE_CONTRACT=0; shift ;;
        *) break ;;
    esac
done

ONLY7=0
OUTSIDE_MODE=0
if [ "${1:-}" = "--only" ]; then
    if [ "$#" -ne 3 ] || [ "$2" != "7" ]; then
        usage
        echo "ready-check: --only takes exactly '7 <pr-number>' (the one lint a worker can run alone)" >&2
        exit 2
    fi
    ONLY7=1
    PR="$3"; SHA=""
elif [ "${1:-}" = "--outside" ]; then
    if [ "$#" -ne 2 ]; then
        usage
        echo "ready-check: --outside takes exactly one <pr-number>" >&2
        exit 2
    fi
    OUTSIDE_MODE=1
    PR="$2"; SHA=""
elif [ "$#" -ne 2 ]; then
    usage
    exit 2
else
    PR="$1"; SHA="$2"
fi

case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "ready-check: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$ONLY7" -eq 0 ] && [ "$OUTSIDE_MODE" -eq 0 ] && { [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; }; then
    usage
    echo "ready-check: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2
    exit 2
fi

GH="${GH_CMD:-gh}"
# Every call below is a read: with no GH_CMD seam they ride the read-only token.
GH_READ_LIB="$(cd "$(dirname "$0")/../../lib" && pwd)/gh-read.sh"
if [ -z "${GH_CMD:-}" ] && [ -f "$GH_READ_LIB" ]; then
    # shellcheck source=scripts/lib/gh-read.sh
    . "$GH_READ_LIB"
    gh_read_init
    GH="$GH_READ_LIB"
fi
if ! command -v "$GH" >/dev/null 2>&1; then
    echo "ready-check: gh not found on PATH" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ready-check: jq not found on PATH" >&2
    exit 2
fi

# one call carries the default branch too (check 12), so the GraphQL budget holds
nwo=$("$GH" repo view --json owner,name,defaultBranchRef --jq '"\(.owner.login)/\(.name) \(.defaultBranchRef.name // "")"' 2>/dev/null)
tp_branch=""
case "$nwo" in *" "*) tp_branch="${nwo#* }" ;; esac
nwo="${nwo%% *}"
if [ -z "$nwo" ]; then
    echo "ready-check: cannot resolve owner/repo (gh repo view --json owner,name failed)" >&2
    exit 2
fi
owner="${nwo%%/*}"
repo="${nwo#*/}"

RESULT=0
mark_fail() { RESULT=1; }
# crf_hold_note — with the CI_GO_GATE switch on, say why the heavy CI has not run at
# this head: the CR-FIRST HOLD lines of the release lib, read-only (no
# label, no ledger line). Switch off or unset: prints nothing, check 2 is unchanged.
crf_hold_note() {
    local lib; lib="$(cd "$(dirname "$0")/../../lib" && pwd)/cr-first-release.sh"
    [ -r "$lib" ] || return 0
    (
        # shellcheck source=../../lib/cr-first-release.sh
        . "$lib" 2>/dev/null || exit 0
        cr_first_switch_on "$nwo" || exit 0
        CR_FIRST_READONLY=1
        export CR_FIRST_READONLY
        cr_first_release "$PR" "$SHA" "$nwo" 2>/dev/null </dev/null | sed 's/^/       /'
    ) || true
}
SNAPSHOT_SCRIPT="$(cd "$(dirname "$0")/../../lib" && pwd)/gh-pr-snapshot.sh"
SNAPSHOT_REREAD_LOCK_WAIT=5
snapshot=""
snapshot_fail_reason=""
refresh_snapshot_or_keep_last() {
    local lock_wait="${1:-${GH_PR_SNAPSHOT_LOCK_WAIT:-}}" err_file out
    err_file=$(mktemp "${TMPDIR:-/tmp}/ready-check-snap.XXXXXX" 2>/dev/null) || err_file=""  # prim-ok: ready-check sources no prim.sh; no file only loses the reason line
    snapshot_fail_reason=""
    if out=$(env GH_CMD="$GH" GH_PR_SNAPSHOT_LOCK_WAIT="$lock_wait" bash "$SNAPSHOT_SCRIPT" "$nwo" 0 "$PR" 2>"${err_file:-/dev/null}"); then
        snapshot=$out
    elif [ -n "$err_file" ]; then
        snapshot_fail_reason=$(tail -n 1 "$err_file" | tr -cd '[:print:]')
    fi
    [ -z "$err_file" ] || rm -f "$err_file"
}
if [ "$ONLY7" -eq 0 ]; then
    refresh_snapshot_or_keep_last
fi

# author_class and outside_pr_of live in the lib, so scripts/cr/pr-check-outside.sh asks the same question.
# shellcheck source=../../lib/outside-contributors.sh
. "$(dirname "$0")/../../lib/outside-contributors.sh" 2>/dev/null || true  # swallow-ok: a missing lib leaves outside_pr_of undefined, which --outside reports as unreadable (exit 2) and item 16 as unknown

if [ "$OUTSIDE_MODE" -eq 1 ]; then
    if ! op=$(outside_pr_of "$snapshot"); then
        echo "ready-check: cannot read PR #$PR's author or fork flag (PR snapshot unreadable)" >&2
        exit 2
    fi
    echo "outside-pr: $op"
    exit 0
fi

# The latest run per check identity, shared by check 2 and 16c. Identity =
# CheckRun name plus workflowName when present, else StatusContext context.
# Latest = greatest startedAt/completedAt (CheckRun) or createdAt/startedAt
# (StatusContext), falling back to the row's array position when neither
# timestamp is present. A run with no timestamp at all (e.g. QUEUED, not yet
# started) has no completed/started time to compare, but it can only exist
# because GitHub created it after every already-timestamped run for that
# identity, so it always outranks them, never the reverse. An entry with no
# identifiable name is judged alone: it never merges into another group (fail closed).
# shellcheck disable=SC2016  # jq program text, expanded by jq
ROLLUP_LATEST_DEFS='
    def key_of(e):
        if e.name == null then "unk:\(e.idx)"
        elif e.is_checkrun then "cr:\(e.name)\u0001\(e.workflow)"
        else "sc:\(e.name)" end;
    def rollup_rows:
        [ to_entries[] |
            .value as $row | .key as $idx |
            ($row | has("conclusion")) as $is_checkrun |
            {
                idx: $idx,
                is_checkrun: $is_checkrun,
                name: (if $is_checkrun then ($row.name // $row.context) else ($row.context // $row.name) end),
                workflow: ($row.workflowName // ""),
                ts: (if $is_checkrun then ($row.startedAt // $row.completedAt // null)
                     else ($row.createdAt // $row.startedAt // null) end),
                ok: (if $is_checkrun then
                        ($row.status == "COMPLETED" and ($row.conclusion == "SUCCESS" or $row.conclusion == "SKIPPED" or $row.conclusion == "NEUTRAL"))
                     else
                        ($row.state == "SUCCESS")
                     end),
                detail: (if $is_checkrun then (($row.status // "?") + "/" + ($row.conclusion // "null"))
                         else ($row.state // "?") end),
                success: ($is_checkrun and $row.conclusion == "SUCCESS"),
                cancelled: ($is_checkrun and $row.status == "COMPLETED" and $row.conclusion == "CANCELLED"),
                run: (if $is_checkrun and (($row.detailsUrl | type) == "string") then
                          ([$row.detailsUrl | scan("^https://[^/]+/[^/]+/[^/]+/actions/runs/([0-9]+)/job/[0-9]+$")[0] | tonumber] | first // null)
                      else null end)
            }
        ];
    def latest_per_check:
        map(.key = key_of(.))
        | map(.sort_key = [(.ts == null), (.ts // .idx)])
        | group_by(.key)
        | map(max_by(.sort_key));
'

if [ "$ONLY7" -eq 0 ]; then

# ── 1. head + mergeStateStatus ──────────────────────────────────────────────
attempt=0
head_now=""
mss=""
while [ "$attempt" -lt 5 ]; do
    pv=$(printf '%s' "$snapshot" | jq -r '.[0] | "\(.headRefOid) \(.mergeStateStatus)"' 2>/dev/null)
    head_now="${pv%% *}"
    mss="${pv#* }"
    [ "$mss" = "UNKNOWN" ] || break
    attempt=$((attempt + 1))
    sleep 1
    if [ "$attempt" -lt 5 ]; then
        refresh_snapshot_or_keep_last "$SNAPSHOT_REREAD_LOCK_WAIT"
    fi
done
# The rollup is judged before row 1: UNSTABLE is accepted there only when
# every non-green entry is a listed non-gating context (lib/non-gating-contexts.txt).
# shellcheck source=../../lib/non-gating-contexts.sh
ng_json='[]'
if . "$(cd "$(dirname "$0")/../../lib" && pwd)/non-gating-contexts.sh" 2>/dev/null; then
    ng_json=$(ngc_json)
fi
rollup=$(printf '%s' "$snapshot" | jq -c '.[0].statusCheckRollup' 2>/dev/null)
total=0
gated=0
bad=""
skipped=""
if [ -n "$rollup" ] && [ "$rollup" != "null" ]; then
    # Judge each check IDENTITY by its LATEST run, not any matching row — a
    # superseded CANCELLED run must not fail a check whose later run at the
    # same head is green (evidence: PR #1317's pr-title-lint
    # CANCELLED 08:19:58Z then SUCCESS 08:26:47Z). Identity and latest are
    # ROLLUP_LATEST_DEFS above, shared with 16c.
    grouped=$(printf '%s' "$rollup" | jq -c --argjson ng "$ng_json" "$ROLLUP_LATEST_DEFS"'
        rollup_rows
        # A skipped job reports its unevaluated name: expression, so a fresh green
        # run never re-reports a job (fail-fast-lint) an older run of the same
        # workflow left CANCELLED. Only a COMPLETED/CANCELLED row is dropped, and
        # only when a NEWER run of that workflow finished green: every row of that
        # run completed SUCCESS/SKIPPED/NEUTRAL with at least one SUCCESS (a wholly
        # skipped run, e.g. the ci:go label, a cancelled, failed or still-running
        # run supersedes nothing). Every other state (queued, in progress, failure,
        # timed out) stays judged whatever a higher run id shows, as does a row
        # with no readable run id or no workflow (fail closed).
        # ponytail: a CANCELLED row in a job the newer run skipped stays droppable, non-required rows only (the ruleset holds the required contexts), HIMMEL-8239 confirms the run itself through the run API
        | . as $all
        | ($all | map(select(.run != null and .workflow != "")) | group_by([.workflow, .run])
           | map(select(all(.[]; .ok) and any(.[]; .success)) | {workflow: .[0].workflow, run: .[0].run})) as $green
        | map(select(. as $e | ($e.cancelled and $e.run != null and $e.workflow != "" and
              ($green | any(.workflow == $e.workflow and .run > $e.run))) | not))
        | latest_per_check
        | map(.listed = (.is_checkrun | not) and (.name != null and (.name as $n | $ng | index($n)) != null))
        | {total: length,
           gated: (map(select(.listed | not)) | length),
           bad: (map(select((.ok | not) and (.listed | not))) | map("\(.name // "?")=\(.detail)") | join(", ")),
           skipped: (map(select((.ok | not) and .listed)) | map("\(.name)=\(.detail)") | join(", "))}
    ' 2>/dev/null)
    total=$(printf '%s' "$grouped" | jq -r '.total // 0' 2>/dev/null)
    gated=$(printf '%s' "$grouped" | jq -r '.gated // 0' 2>/dev/null) # swallow-ok: an unreadable count reads 0, which fails row 2 as no gating checks
    bad=$(printf '%s' "$grouped" | jq -r '.bad // empty' 2>/dev/null)
    skipped=$(printf '%s' "$grouped" | jq -r '.skipped // empty' 2>/dev/null) # swallow-ok: an unreadable list is empty, so nothing is reported as skipped
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$gated" in ''|*[!0-9]*) gated=0 ;; esac
fi

if [ -z "$pv" ]; then
    echo "[FAIL] 1. gh pr view #$PR --repo $nwo failed — cannot read headRefOid/mergeStateStatus"
    mark_fail
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "CLEAN" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=CLEAN"
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "UNSTABLE" ] && [ "$gated" -gt 0 ] && [ -z "$bad" ] && [ -n "$skipped" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=UNSTABLE with only non-gating checks not green ($skipped)"
else
    if [ "$mss" = "BEHIND" ]; then
        echo "[FAIL] 1. head=$head_now (want $SHA), mergeStateStatus=$mss (want CLEAN) — behind main: git fetch origin && git merge origin/main into the branch, push, then re-run with the new head sha (nothing to do when mergeStateStatus is CLEAN and the head matches)"
    else
        echo "[FAIL] 1. head=$head_now (want $SHA), mergeStateStatus=$mss (want CLEAN)"
    fi
    mark_fail
fi
[ -z "$snapshot_fail_reason" ] || echo "       PR snapshot read failed: $snapshot_fail_reason"

# ── 2. statusCheckRollup ─────────────────────────────────────────────────────
if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    echo "[FAIL] 2. statusCheckRollup unreadable (gh pr view --json statusCheckRollup failed)"
    mark_fail
else
    # A listed non-gating context is skipped; with nothing else reported there
    # is no real check to pass on, so it counts as no checks.
    if [ "$gated" -eq 0 ]; then
        echo "[FAIL] 2. statusCheckRollup: no checks reported yet (0 entries — CI may not have registered)"
        crf_hold_note
        mark_fail
    elif [ -z "$bad" ] && [ -n "$skipped" ]; then
        echo "[PASS] 2. statusCheckRollup: $gated/$gated gating checks completed SUCCESS/SKIPPED/NEUTRAL; non-gating skipped: $skipped"
    elif [ -z "$bad" ]; then
        echo "[PASS] 2. statusCheckRollup: $total/$total checks completed SUCCESS/SKIPPED/NEUTRAL"
    else
        echo "[FAIL] 2. statusCheckRollup: not-green — $bad"
        crf_hold_note
        mark_fail
    fi
fi

# ── 3. unresolved review threads (paginated, mirrors scripts/check-ci.sh) ──
threads_ok=1
unresolved=$(printf '%s' "$snapshot" | jq -er '.[0].reviewThreads.nodes | select(type == "array") | [.[] | select(.isResolved | not)] | length' 2>/dev/null) || {
    echo "[FAIL] 3. review-thread GraphQL query failed"
    threads_ok=0
}
if [ "$threads_ok" -eq 1 ]; then
    if [ "$unresolved" -eq 0 ]; then
        echo "[PASS] 3. unresolved review threads = 0"
    else
        echo "[FAIL] 3. unresolved review threads = $unresolved"
        mark_fail
    fi
else
    mark_fail
fi

# ── 4. CR ledger row for this head with status ok ───────────────────────────
common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
if [ -z "$common_dir" ]; then
    echo "[FAIL] 4. cannot resolve git-common-dir (git rev-parse --git-common-dir failed)"
    mark_fail
else
    ledger="$common_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "[FAIL] 4. CR ledger not found at $ledger"
        mark_fail
    else
        # `jq -R 'fromjson?'` parses one JSON value per line and skips a
        # malformed line rather than aborting the whole read (a plain `jq -s`
        # slurp would die on the first bad line in a 7000+ line ledger).
        ledger_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null)
        n=$(jq -R -r --arg h "$SHA" --arg b "$ledger_branch" --arg p "$PR" '
            fromjson? | select(.head == $h and .status == "ok") |
            select((.kind == "avail" and (.model | type) == "string" and .model != ""
                    and .model != "claude" and .model != "claude-floor" and .model != "codex-adv")
                or ((.kind == "evidence" or .kind == "judge-go" or .kind == "dependabot-go") and $b != "" and .branch == $b
                    and (.kind != "dependabot-go" or ((.pr | type) == "number" and (.pr | tostring) == $p)))) |
            .head' "$ledger" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${n:-0}" -ge 1 ]; then
            echo "[PASS] 4. CR ledger: $n row(s) for $SHA with status=ok"
        else
            echo "[FAIL] 4. CR ledger: no critic avail or branch-bound evidence/judge-go row for $SHA with status=ok ($ledger)"
            mark_fail
        fi
    fi
fi

# ── commits (shared by checks 5 and 6) ──────────────────────────────────────
commits_json=$(printf '%s' "$snapshot" | jq -c '.[0].commits' 2>/dev/null)
files_json=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null) || files_json=""  # swallow-ok: a failed or partial read is an empty list, which checks 5, 9, 10 and 11 fail closed on

if [ -z "$commits_json" ] || [ "$commits_json" = "null" ]; then
    echo "[FAIL] 5. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
    echo "[FAIL] 6. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
else
    # ── 5. first-commit attestation trailers ────────────────────────────────
    # PLATFORM_RE / ATTEST_RE verbatim from scripts/hooks/check-platforms-tested.sh
    PLATFORM_RE='(linux|windows|macos|ubuntu|debian|fedora|arch|mac|darwin|wsl|posix|gitbash|git-bash|powershell|pwsh)'
    ATTEST_RE="^[[:space:]]*Platforms tested:[[:space:]]*${PLATFORM_RE}([^[:alnum:]]|$)"
    # TOKEN_RE verbatim from scripts/hooks/check-security-reviewed.sh
    TOKEN_RE='(manual|claude-code-security-review|pr-review-toolkit|ad-hoc)([[:space:]]|$|[.,;])'
    SEC_RE="^[[:space:]]*Security reviewed:[[:space:]]*${TOKEN_RE}"

    first_msg=$(printf '%s' "$commits_json" | jq -r '.[0].messageHeadline + "\n\n" + (.[0].messageBody // "")' 2>/dev/null)

    if [ -z "$files_json" ]; then
        echo "[FAIL] 5. cannot read PR files (gh api .../pulls/$PR/files failed or returned nothing)"
        mark_fail
    else
        # Markdown/text is never a script, even under scripts/
        # (a docs-only README edit could otherwise never get a GO).
        sensitive=$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$' | grep -E '(\.(sh|bash|zsh|ps1|psm1|psd1|cmd|bat)$|^scripts/|(^|/)bin/[^/]+$)' || true)
        non_docs=$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)

        need_plat=0; [ -n "$sensitive" ] && need_plat=1
        need_sec=0; [ -n "$non_docs" ] && need_sec=1

        plat_ok=1; [ "$need_plat" -eq 1 ] && { echo "$first_msg" | grep -qiE "$ATTEST_RE" || plat_ok=0; }
        sec_ok=1; [ "$need_sec" -eq 1 ] && { echo "$first_msg" | grep -qiE "$SEC_RE" || sec_ok=0; }

        if [ "$plat_ok" -eq 1 ] && [ "$sec_ok" -eq 1 ]; then
            echo "[PASS] 5. first commit: Platforms tested (needed=$need_plat), Security reviewed (needed=$need_sec) — attested where needed"
        else
            [ "$plat_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Platforms tested:' (diff touches scripts/shell files)"
            [ "$sec_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Security reviewed:' (diff touches non-docs code)"
            mark_fail
        fi
    fi

    # ── 6. every commit subject carries a ticket ID ─────────────────────────
    # Same config source as check-commit-msg.sh: load TICKET_ID_PATTERN /
    # JIRA_PROJECT_KEY from the primary checkout's .env (live env wins) —
    # without this, a fresh shell with nothing exported always falls through
    # to the bare "#123" pattern and flags every "[TICKET-1234]"-style subject.
    RC_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=../../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    if . "$RC_SCRIPT_DIR/../../lib/load-dotenv.sh" 2>/dev/null; then
        # pin to this script's OWN checkout, never the caller's
        # CWD repo (load_dotenv with no --root resolves via the process CWD's
        # git repo — see usage-preflight.sh for the failure mode).
        load_dotenv --root "$(_load_dotenv_primary_for "$RC_SCRIPT_DIR/../../..")" TICKET_ID_PATTERN JIRA_PROJECT_KEY || true
    fi
    TICKET_PATTERN="${TICKET_ID_PATTERN:-}"
    if [ -z "$TICKET_PATTERN" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
        ESCAPED_KEY=$(printf '%s' "$JIRA_PROJECT_KEY" | sed 's/[.[\*^$]/\\&/g')
        TICKET_PATTERN="${ESCAPED_KEY}-[0-9]+"
    fi
    TICKET_PATTERN="${TICKET_PATTERN:-(^|[^0-9A-Za-z_])#[0-9]+([^0-9A-Za-z_]|$)}"

    # Parent counts ride the shared snapshot; real merge commits stay exempt.
    merge_oids=$(printf '%s' "$commits_json" | jq -r '.[] | select(.parents.totalCount > 1) | .oid' 2>/dev/null)

    missing=$(printf '%s' "$commits_json" | jq -r --arg merges "$merge_oids" '
        ($merges | split("\n") | map(select(length > 0))) as $m
        | .[] | select((.oid // "") as $o | ($m | index($o)) == null)
        | .messageHeadline
    ' 2>/dev/null | grep -vE "$TICKET_PATTERN" || true)
    if [ -z "$missing" ]; then
        echo "[PASS] 6. every commit subject carries a ticket ID"
    else
        # An external contributor's own commits cannot be reworded (amend and
        # force-push are blocked and would drop their authorship); the squash
        # lands the PR TITLE as main's subject. Exempt only when the PR author
        # is external per the allowlist AND the title is keyed. Every unreadable
        # input keeps the FAIL; the allowlist is read, never written.
        ext_login=$(printf '%s' "$snapshot" | jq -r '.[0].author // empty' 2>/dev/null | tr -d '[:space:]') || ext_login=""  # swallow-ok: an unreadable author never takes the exemption
        ext_title=$(printf '%s' "$snapshot" | jq -r '.[0].title // empty' 2>/dev/null) || ext_title=""  # swallow-ok: an unreadable title never takes the exemption
        ext_ok=0
        # gh reports a GitHub App author as "app/<name>" (e.g. app/dependabot): a bot is never a contributor.
        if [ -n "$ext_login" ] && [ -n "$ext_title" ] && [[ "$ext_login" != app/* && "$ext_login" != *"[bot]" ]] \
            && grep -qE "$TICKET_PATTERN" <<< "$ext_title" \
            && . "$RC_SCRIPT_DIR/../../lib/ticket-id-internal.sh" 2>/dev/null \
            && ticket_id_author_is_external "$ext_login" 2>/dev/null; then
            ext_ok=1
        fi
        if [ "$ext_ok" -eq 1 ]; then
            echo "[PASS] 6. $(printf '%s\n' "$missing" | grep -c .) commit subject(s) lack a ticket ID but the PR author $ext_login is an external contributor and the PR title carries a ticket ID (squash lands the title)"
        else
            echo "[FAIL] 6. commit subject(s) missing a ticket ID: $(printf '%s' "$missing" | tr '\n' ';' | sed 's/;$//')"
            mark_fail
        fi
    fi
fi
fi  # ONLY7 == 0: checks 1-6

# ── 7. ticket coverage ────────────────────────────────────────
# A PR can close its ticket Done with asks undone. The
# body must carry a `## Ticket coverage` section, one list line per ask of each
# cited ticket, each marked `done` or `deferred → <KEY>` (`->` also accepted).
# Whether a line's "done" is TRUE stays the chief's diff read; this check
# makes an unaccounted ask structurally visible and a deferral real: every
# deferred key must exist and still be open, and the deferral keys must equal
# the CR ledger's deferred_to rows for the PR head, or for the reviewed head a
# same-branch trivial-descendant row names. A Jira error reads UNKNOWN and
# fails — never a PASS. JIRA_CMD overrides the CLI (tests), like GH_CMD.
jira_run() {
    if [ -n "${JIRA_CMD:-}" ]; then
        "$JIRA_CMD" "$@" 2>&1
    else
        cov_primary=$(cd "$(dirname "$0")" && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)
        node "$cov_primary/scripts/jira/dist/index.js" "$@" 2>&1
    fi
}

jira_get() { jira_run get "$1" --json; }

# `links <KEY>` rows are tab-separated, with inward=<KEY> and outward=<KEY> fields.
jira_links() { jira_run links "$1"; }

# cov_linked <own-key> <target-key>: the PR's own ticket has an issue link to the target, either direction, any type.
# Returns 0 linked, 1 not linked (or no own ticket), 2 the links lookup failed.
cov_linked() {
    [ -n "$1" ] && [ "$1" != "$2" ] || return 1
    cov_links_out=$(jira_links "$1") || return 2
    printf '%s\n' "$cov_links_out" | awk -F'\t' -v t="$2" '{ for (i = 1; i <= NF; i++) if ($i == "inward=" t || $i == "outward=" t) f = 1 } END { exit !f }'
}

# cov_ledger_keys <ledger> <head> <pr-branch>: the tickets the CR ledger defers findings to at <head>, one upper-case key per line.
# Findings of a reviewed head count too when a trivial-descendant row of <pr-branch> for <head> names that reviewed head,
# and so along a chain of such rows: each row names the reviewed head before it, up to 10 hops back from <head> (cycle-safe).
# A finding recorded again later at a head of the chain is judged by that later row alone.
# A deferral of <pr-branch> at any earlier head carries to <head> when a critic's ok avail row of <pr-branch> at <head> or at
# any head of that chain was written after the finding (a clean full round) and no finding row of <pr-branch> sits at any
# head of the chain: a round that re-raised
# or fixed anything there is not clean (fail-closed), a deferral later amended to fixed is no longer a deferral, and a
# finding the branch recorded again at any later head (re-raised in between) is judged by that later row alone.
# One exception: a chain-head finding does not make the round unclean when its effective verdict (its row plus later amends)
# is fixed, deferred or disproved, its head (and its effective head) is not <head>, and a clean round was written after its
# last row or amend at its effective head or a descendant of it in the chain (that round reviewed the handled code); a clean
# round at an older head does not count; a finding at <head> itself, or an open one, still blocks.
# A finding row the same branch recorded again for the same identity (key and original head) is judged by its later row alone.
# A finding is identified by its key and original head, and a later row for the same identity replaces the earlier one.
# Its effective row is its own row with every amend written after it against that original head merged over it, in file
# order (an amend's set.head re-keys the finding, and later amends keep the original head as their target_head); a finding
# whose own head is not <head> takes only amends of its branch or without a branch (fail-closed; review-ledger-evidence.sh
# merges every matching amend). The finding counts at <head> when its effective head matches, and only an effective verdict of deferred counts.
# A head matches when either spelling is a prefix of the other.
# A missing ledger is an empty set (check 4 owns that failure); an unreadable one returns 1.
cov_ledger_keys() {
    [ -f "$1" ] || return 0
    cov_led_out=$(jq -R -n -r --arg h "$2" --arg pb "${3:-}" --argjson pr "${PR:-0}" '
        def hm($x; $y): ($x | type == "string") and ($y | type == "string") and ($x | length >= 7) and ($y | length >= 7) and (($x | ascii_downcase) as $a | ($y | ascii_downcase) as $b | ($a | startswith($b)) or ($b | startswith($a)));
        def fk($r): [$r.finding_id // "?", $r.artifact // "diff", $r.perspective // "off"] | join("|");
        def vd($o): $o | {verdict, deferred_to} | with_entries(select(.value != null));
        [inputs | fromjson? | select(type == "object")] | to_entries | map(.value + {_ln: .key}) as $rows
        | def ak($r; $x): fk($r) + "|" + ($x[0:7] | ascii_downcase);
        [$rows[] | select(.kind == "avail" and $pb != "" and .branch == $pb and (.head | type == "string") and (.detail | type == "string"))
            | {head, rev: (.detail | capture("^trivial-descendant of reviewed head (?<r>[0-9a-fA-F]{7,40}) ").r? // empty)}] as $desc
        | (reduce range(10) as $_ ([$h]; . as $c | . + [$desc[] | select(. as $d | any($c[]; hm($d.head; .))) | .rev | select(. as $r | any($c[]; hm($r; .)) | not)] | unique)) as $chain
        | def inchain($x): any($chain[]; hm($x; .));
        [$rows[] | select(.kind == "avail" and $pb != "" and .branch == $pb and .status == "ok" and (.head | type == "string") and inchain(.head)
            and (.model | type == "string") and .model != "" and (.model | IN("claude", "claude-floor", "codex-adv") | not)
            and ((.detail // "") | tostring | startswith("trivial-descendant") | not)) | {ln: ._ln, head}] as $cleanrows
        | ($cleanrows | map(.ln)) as $clean
        | (reduce ($rows[] | select(.kind == "amend" and (.set | type == "object") and (.target_head | type == "string") and (.target_head | length >= 7))) as $a ({}; .[ak($a; $a.target_head)] += [$a])) as $amends
        | def descs($x): reduce range(10) as $_ ([$x]; . as $c | . + [$desc[] | select(. as $d | any($c[]; hm($d.rev; .))) | .head] | unique);
        def applied($f):[($amends[ak($f; $f.head)] // [])[] | select(._ln > $f._ln and hm(.target_head; $f.head) and (.branch == null or .branch == $f.branch))];
        def handled($f): (reduce applied($f)[] as $a ($f; . + $a.set)) as $e
            | ($e.verdict | IN("fixed", "deferred", "disproved")) and (hm($f.head; $h) | not) and (hm($e.head; $h) | not)
              and ((([$f._ln] + (applied($f) | map(._ln))) | max) as $last | descs($e.head) as $seen
                  | any($cleanrows[]; .ln > $last and (.head as $ch | any($seen[]; hm($ch; .)))));
        def replaced($f): any($rows[]; .kind == "finding" and .branch == $pb and (.head | type == "string") and (.head | length >= 7) and ak(.; .head) == ak($f; $f.head) and ._ln > $f._ln);
        ([$rows[] | select(.kind == "finding" and $pb != "" and .branch == $pb and (.head | type == "string") and inchain(.head) and (replaced(.) | not) and (handled(.) | not))] | length > 0) as $raised
        | def at_head($f; $e): hm($e.head; $h)
            or ($pb != "" and $f.branch == $pb
                and ((inchain($e.head) and (any($rows[]; .kind == "finding" and .branch == $pb and (.head | type == "string") and inchain(.head) and fk(.) == fk($f) and ._ln > $f._ln) | not))
                    or (($raised | not) and any($clean[]; . > $f._ln)
                        and (any($rows[]; .kind == "finding" and .branch == $pb and fk(.) == fk($f) and ._ln > $f._ln) | not))));
        def keyok: type == "string" and test("^[A-Za-z][A-Za-z0-9]*-[0-9]+$");
        # A disposition row (cr-disposition.sh record) counts only where cr-disposition.sh check reads it: the full <head>, this PR
        # number and branch, a Critical or Important finding of the branch at its exact head that is still deferred, and the latest
        # such row per finding. The jq side prints these as D lines; the shell side verifies each mac before a key is taken.
        ([$rows[] | select(.kind == "amend" and $pb != "" and .branch == $pb and .head == $h and .pr == $pr and (.set | type == "object") and (.set.disposition | type == "string")
                and (.target_head | type == "string") and (.target_head | test("^[0-9a-f]{40}$")))]
            | group_by(fk(.) + "|" + .target_head) | map(max_by(._ln))
            | map(select(.set.disposition | test("^follow-up:[A-Za-z][A-Za-z0-9]*-[0-9]+$")) | . as $d
                | select(any($rows[]; .kind == "finding" and .branch == $pb and fk(.) == fk($d) and .head == $d.target_head and (replaced(.) | not)
                    and (. as $f | (reduce (($amends[ak($f; $f.head)] // [])[] | select(._ln > $f._ln and hm(.target_head; $f.head) and (.branch == null or .branch == $f.branch))) as $a ($f; . + $a.set))
                        | ((.severity // "") | tostring | ascii_downcase | IN("crit", "critical", "imp", "important")) and .verdict == "deferred"))))) as $cands
        | ((reduce ($rows[] | select(.kind == "finding" and (.head | type == "string") and (.head | length >= 7))) as $f ({};
            (reduce (($amends[ak($f; $f.head)] // [])[] | select(._ln > $f._ln and hm(.target_head; $f.head) and (hm($f.head; $h) or .branch == null or .branch == $f.branch))) as $a ($f; . + $a.set)) as $e
            | .[ak($f; $f.head)] = (if at_head($f; $e) then vd($e) else {} end))
        | [.[] | select(.verdict == "deferred" and (.deferred_to | keyok)) | .deferred_to | ascii_upcase] | map(["K", .] | @tsv))
            + ($cands | map(["D", .finding_id, .target_head, .set.disposition, ((.source // "-") | tostring | if . == "" then "-" else . end),
                ((.attest // []) | if type == "array" then map(tostring) | join(",") else "-" end | if . == "" then "-" else . end), ((.mac // "-") | tostring | if . == "" then "-" else . end)] | @tsv)))[]' "$1") || return 1
    cov_led_keys_out=$(printf '%s\n' "$cov_led_out" | awk -F'\t' '$1 == "K" { print $2 }')
    cov_disp_rows=$(printf '%s\n' "$cov_led_out" | awk -F'\t' '$1 == "D"')
    if [ -n "$cov_disp_rows" ]; then
        # The mac is the one cr-disposition.sh disp_mac builds, from the same go_msg_mac, so a row passes here only if it passes there.
        cov_gg="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}/scripts/lib/go-gate.sh"
        # shellcheck source=/dev/null
        if . "$cov_gg" 2>/dev/null && declare -F go_msg_mac >/dev/null 2>&1; then
            while IFS=$'\t' read -r _ cov_fid cov_fh cov_dp cov_src cov_att cov_mac; do
                [ "$cov_att" = "ci-green,no-data-loss,no-weakened-guard" ] || continue
                cov_want=$(go_msg_mac himmel-disposition-v1 "$PR|$2|${3:-}|$cov_fid|$cov_fh|$cov_dp|$cov_src|$cov_att") || cov_want="" # swallow-ok: an unsignable row yields no key, so the body deferral fails below
                [ -n "$cov_want" ] && [ "$cov_want" = "$cov_mac" ] || continue
                cov_led_keys_out="$cov_led_keys_out
$(printf '%s' "${cov_dp#follow-up:}" | tr '[:lower:]' '[:upper:]')"
            done <<EOF
$cov_disp_rows
EOF
        fi
    fi
    printf '%s\n' "$cov_led_keys_out" | sed '/^$/d' | sort -u
}

cov_shape_help() {
    echo "       accepted shape, one line per ask, marker LAST with nothing after it (no trailing prose, parentheses or links):"
    echo "         - <ask>: done"
    echo "         - <ask>: deferred → HIMMEL-<n>"
    echo "       (-> is accepted for →; a trailing . or bold is fine). Put any explanation BEFORE the marker."
}

if [ "$ONLY7" -eq 1 ]; then
    cov_body=$("$GH" pr view "$PR" --repo "$nwo" --json body --jq '.body' 2>/dev/null | tr -d '\r')
else
    cov_body=$(printf '%s' "$snapshot" | jq -r '.[0].body' 2>/dev/null | tr -d '\r')
fi
cov_section=$(printf '%s\n' "$cov_body" | awk '
    /^##[ \t]+[Tt]icket [Cc]overage[ \t]*$/ { f = 1; next }
    f && /^#/ { exit }
    f')
cov_lines=$(printf '%s\n' "$cov_section" | grep -E '^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]' || true)
# A dependency-only Dependabot PR (author app/dependabot, every changed file a
# manifest or lockfile by name) has no asks to cover; its coverage is generated.
dep_pr_generated() {
    local author files prev bad
    author=$("$GH" pr view "$PR" --repo "$nwo" --json author --jq '.author.login' 2>/dev/null) || return 1  # swallow-ok: an unreadable author is not a Dependabot PR
    [ "$author" = "app/dependabot" ] || return 1
    files="${files_json:-}"
    [ -n "$files" ] || files=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null) || return 1  # swallow-ok: an unreadable list is not a dependency-only PR
    [ -n "$files" ] || return 1
    prev=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | .previous_filename // empty' 2>/dev/null) || return 1  # swallow-ok: an unreadable rename list is not a dependency-only PR
    [ -z "$prev" ] || files="$files
$prev"
    bad=$(printf '%s\n' "$files" | grep -Ev '(^|/)(package\.json|package-lock\.json|bun\.lock|requirements[A-Za-z0-9._-]*\.txt)$' || true)  # swallow-ok: every name a manifest is grep rc 1, and an empty set is the answer
    [ -z "$bad" ]
}
if [ -z "$cov_lines" ] && dep_pr_generated; then
    echo "[PASS] 7. ticket coverage: generated for a Dependabot dependency-only PR (manifest and lockfile files only)"
elif [ -z "$cov_lines" ]; then
    echo "[FAIL] 7. PR body has no '## Ticket coverage' section with list lines (one per ask: done | deferred → HIMMEL-<n>)"
    cov_shape_help
    mark_fail
else
    cov_bad=""; cov_shape=0; cov_body_keys=""
    # A deferral must land on a residual-verb ticket or one that predates this PR's own.
    # ponytail: key order stands for creation order (the branch name's first key is the
    # PR's ticket; the title is author text and not read); upgrade: compare Jira's created to the first commit date once
    # `jira get` fetches created.
    cov_own=""
    if printf '%s\n' "$cov_lines" | grep -qiE 'deferred'; then
        cov_own=$("$GH" pr view "$PR" --repo "$nwo" --json headRefName --jq '.headRefName' 2>/dev/null | grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]' || true) # swallow-ok: an unreadable branch leaves cov_own empty, so only a residual label passes
    fi
    while IFS= read -r cov_line; do
        [ -n "$cov_line" ] || continue
        cov_def=$(printf '%s\n' "$cov_line" | grep -ioE 'deferred[[:space:]]*(→|->)[^[:alnum:]]*[A-Za-z][A-Za-z0-9]*-[0-9]+[^[:alnum:]]*$' || true)
        if [ -n "$cov_def" ]; then
            cov_key=$(printf '%s\n' "$cov_def" | grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | tr '[:lower:]' '[:upper:]')
            if cov_out=$(jira_get "$cov_key"); then
                cov_status=$(printf '%s\n' "$cov_out" | jq -r '.fields.status.name // empty' 2>/dev/null || true) # swallow-ok: unparseable output leaves the status empty, which reads UNKNOWN below
                cov_canon=$(printf '%s\n' "$cov_out" | jq -r '(.key // empty) | ascii_upcase' 2>/dev/null || true) # swallow-ok: unparseable output leaves the key empty, which reads UNKNOWN below
                [ -z "$cov_canon" ] || cov_key="$cov_canon"
                if [ -z "$cov_canon" ]; then
                    cov_bad="$cov_bad; $cov_key UNKNOWN (jira returned no key)"
                elif [ -z "$cov_status" ]; then
                    cov_bad="$cov_bad; $cov_key UNKNOWN (jira returned no status)"
                elif printf '%s\n' "$cov_status" | grep -qiE '^(done|closed|resolved|won.?t do)$'; then
                    cov_bad="$cov_bad; $cov_key already $cov_status"
                elif [ "$cov_key" = "$cov_own" ]; then
                    cov_bad="$cov_bad; $cov_key is the PR's own ticket and cannot be its own deferral target"
                elif ! printf '%s\n' "$cov_out" | jq -e '(.fields.labels // []) | any(. == "residual")' >/dev/null 2>&1 \
                    && ! { [ -n "$cov_own" ] && [ "${cov_key%-*}" = "${cov_own%-*}" ] && [ "${cov_key##*-}" -lt "${cov_own##*-}" ]; } \
                    && ! { cov_linked "$cov_own" "$cov_key" && cov_rc=0 || cov_rc=$?; [ "$cov_rc" -eq 0 ]; }; then
                    if [ "$cov_rc" -eq 2 ]; then
                        cov_bad="$cov_bad; $cov_key UNKNOWN (jira links failed for $cov_own)"
                    else
                        cov_bad="$cov_bad; $cov_key was made by a raw jira create (no 'residual' label, not older than ${cov_own:-the PR ticket}, not linked from it) - file it with: jira create --residual-of <parent> --fu-class escape|hardening --class <id>, or link a plain ticket: jira link ${cov_own:-<PR ticket>} $cov_key"
                    fi
                fi
                cov_body_keys="$cov_body_keys $cov_key"
            elif printf '%s\n' "$cov_out" | grep -qiE '404|does not exist'; then
                cov_bad="$cov_bad; $cov_key does not exist"
            else
                cov_bad="$cov_bad; $cov_key UNKNOWN (jira get failed)"
            fi
        elif ! printf '%s\n' "$cov_line" | grep -qiE '(^|[^[:alnum:]])done[^[:alnum:]]*$' \
            || printf '%s\n' "$cov_line" | grep -qiE '(not|n.t)[[:space:]]+done'; then
            cov_bad="$cov_bad; unmarked line: $(printf '%s' "$cov_line" | cut -c1-160)"
            cov_shape=1
        fi
    done <<EOF
$cov_lines
EOF
    # The ledger's deferrals at the PR head and the body's deferral lines must name the same tickets.
    cov_head="$SHA"
    if [ "$ONLY7" -eq 1 ]; then
        cov_head=$("$GH" pr view "$PR" --repo "$nwo" --json headRefOid --jq '.headRefOid' 2>/dev/null | tr -d '\r') || cov_head="" # swallow-ok: an unreadable head is reported below
    fi
    if [ -z "$cov_head" ]; then
        cov_bad="$cov_bad; cannot read the PR head, so the CR ledger's deferrals cannot be compared"
    else
        cov_common=$(git rev-parse --git-common-dir 2>/dev/null) || cov_common="" # swallow-ok: no repo reads as no ledger, so a body deferral fails below
        cov_h12=$(printf '%.12s' "$cov_head")
        if [ "$ONLY7" -eq 1 ]; then
            cov_pr_branch=$("$GH" pr view "$PR" --repo "$nwo" --json headRefName --jq '.headRefName' 2>/dev/null | tr -d '\r') || cov_pr_branch="" # swallow-ok: an unreadable branch follows no trivial-descendant row, so a reviewed-head deferral fails below
        else
            cov_pr_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null) || cov_pr_branch="" # swallow-ok: same fallback as above
        fi
        if cov_led_out=$(cov_ledger_keys "$cov_common/cr-critic-scores.jsonl" "$cov_head" "$cov_pr_branch"); then
            cov_led_keys=$(printf '%s\n' "$cov_led_out" | tr '\n' ' ')
            for cov_k in $cov_led_keys; do
                case " $cov_body_keys " in
                    *" $cov_k "*) ;;
                    *) cov_bad="$cov_bad; $cov_k is deferred in the CR ledger for $cov_h12 but no coverage line defers to it" ;;
                esac
            done
            for cov_k in $cov_body_keys; do
                case " $cov_led_keys " in
                    *" $cov_k "*) ;;
                    *) cov_bad="$cov_bad; $cov_k is deferred in the body but has no deferred_to row in the CR ledger for $cov_h12" ;;
                esac
            done
        else
            cov_bad="$cov_bad; the CR ledger could not be read, so its deferrals cannot be compared"
        fi
    fi
    if [ -z "$cov_bad" ]; then
        echo "[PASS] 7. ticket coverage: every ask is done or deferred to an open ticket"
    else
        echo "[FAIL] 7. ticket coverage:${cov_bad#;}"
        [ "$cov_shape" -eq 1 ] && cov_shape_help
        mark_fail
    fi
fi

# pr_fetch — fetch origin/main, and the PR head when it is not here. pr_merge_base
# — pr_fetch, then set pr_mb to merge-base(origin/main, SHA). Each runs once and is
# kept for every later caller (checks 9 and 19); a failure sets pr_mb_err and
# returns 1. Each fetch is bounded at 15 s when a timeout binary resolves.
pr_mb=""
pr_mb_err=""
pr_fetch_done=0
pr_mb_done=0
_TIMEOUT_BIN=""
# shellcheck source=../../lib/timeout-bin.sh
. "$(cd "$(dirname "$0")/../../lib" && pwd)/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN leaves the fetches unbounded, and item 19 FAILs on it
pr_mb_git() { ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 15} git "$@"; }
pr_fetch() {
    if [ "$pr_fetch_done" -eq 0 ]; then
        pr_fetch_done=1
        if ! pr_mb_git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
            pr_mb_err="cannot fetch origin/main"
        elif ! git cat-file -e "$SHA^{commit}" 2>/dev/null \
            && { ! pr_mb_git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || ! git cat-file -e "$SHA^{commit}" 2>/dev/null; }; then
            pr_mb_err="cannot fetch PR head $SHA"
        fi
    fi
    [ -z "$pr_mb_err" ]
}
pr_merge_base() {
    pr_fetch || return 1
    if [ "$pr_mb_done" -eq 0 ]; then
        pr_mb_done=1
        if ! pr_mb=$(git merge-base refs/remotes/origin/main "$SHA" 2>/dev/null) || [ -z "$pr_mb" ]; then  # swallow-ok: rc checked, a failure FAILs its caller
            pr_mb=""
            pr_mb_err="cannot read the merge-base with origin/main"
        fi
    fi
    [ -z "$pr_mb_err" ]
}

if [ "$ONLY7" -eq 0 ]; then
# ── 9. a plugin change bumps that plugin's version ──────────────
# The --bump-required rule of scripts/check-plugin-drift.sh. A PR
# that changes a plugin's files must carry a version strictly above origin/main's
# as it is NOW: two PRs can raise one plugin to the same version with different
# content, which merges cleanly (check 1 stays CLEAN) and leaves stale installs.
# A bump with no other change in that plugin (a manifest edit beyond "version"
# counts as a change) is refused. A release cut (a PR that changes the root
# VERSION file) raises every plugin it touches above main. Inline rather than
# calling check-plugin-drift.sh, which hardwires HEAD and the caller's checkout.
# A file moved out of a plugin lists only its destination as filename, so the
# plugin path comes from previous_filename. A PR touching no plugin never
# reaches git. Fetch or read failure = FAIL.
plug_prev=""
plug_prev_ok=1
if [ -n "$files_json" ]; then
    plug_prev=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | .previous_filename // empty' 2>/dev/null) || plug_prev_ok=0  # swallow-ok: rc checked, an unreadable rename list FAILs check 9
fi
plug_files=$(printf '%s\n%s\n' "$files_json" "$plug_prev" | grep -E '^marketplace/plugins/[^/]+/' || true)
if [ -z "$files_json" ]; then
    echo "[FAIL] 9. cannot read PR files — plugin version bump not checked"
    mark_fail
elif [ "$plug_prev_ok" -eq 0 ]; then
    echo "[FAIL] 9. cannot read the paths the PR renames from — plugin version bump not checked"
    mark_fail
elif [ -z "$plug_files" ]; then
    echo "[PASS] 9. no plugin files touched — version bump not applicable"
else
    bump_err=""
    plug_manifest_ver() {  # <ref> <plugin> — prints the manifest "version", empty when absent
        git show "$1:marketplace/plugins/$2/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null
    }
    plug_removed() {  # <ref> <plugin> — true only when nothing is tracked at the plugin path and marketplace.json no longer lists it
        local left listed
        left=$(git ls-tree -r --name-only "$1" -- "marketplace/plugins/$2" 2>/dev/null) || return 1  # swallow-ok: a failed read counts as not removed
        [ -z "$left" ] || return 1
        listed=$(git show "$1:marketplace/.claude-plugin/marketplace.json" 2>/dev/null | jq -r --arg n "$2" '[.plugins[] | select(.name == $n or ((.source // "") | tostring | rtrimstr("/") | endswith("/" + $n)))] | length' 2>/dev/null)  # swallow-ok: unreadable counts as listed
        [ "$listed" = "0" ]
    }
    plug_manifest_rest() {  # <ref> <plugin> — the manifest without "version", canonical; "!" when jq fails
        local r
        r=$(git show "$1:marketplace/plugins/$2/.claude-plugin/plugin.json" 2>/dev/null | jq -S -c 'del(.version)' 2>/dev/null) || r="!"  # swallow-ok: an unreadable manifest compares as "!"
        printf '%s' "$r"
    }
    plug_above_main() {  # <plugin> — appends to bump_err unless the PR's version is strictly above origin/main's
        local p="$1" mpath="marketplace/plugins/$1/.claude-plugin/plugin.json" m_ls p_ls m_ver p_ver
        # absent on main = new plugin, nothing to collide with; a failed tree read or an
        # unreadable manifest = FAIL
        if ! m_ls=$(git ls-tree --name-only refs/remotes/origin/main -- "$mpath" 2>/dev/null); then
            bump_err="$bump_err; $p cannot read origin/main's tree"
            return 0
        fi
        [ -n "$m_ls" ] || return 0
        if ! p_ls=$(git ls-tree --name-only "$SHA" -- "$mpath" 2>/dev/null); then
            bump_err="$bump_err; $p cannot read the PR tree"
            return 0
        fi
        if [ -z "$p_ls" ] && plug_removed "$SHA" "$p"; then return 0; fi  # removed whole — nothing to bump
        m_ver=$(plug_manifest_ver refs/remotes/origin/main "$p")
        p_ver=$(plug_manifest_ver "$SHA" "$p")
        if ! grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$m_ver" \
            || ! grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$p_ver"; then
            bump_err="$bump_err; $p version not plain x.y.z (main '${m_ver:-none}', PR '${p_ver:-none}')"
            return 0
        fi
        if ! jq -n -e --arg a "$m_ver" --arg b "$p_ver" '
            def k: split(".") | map(tonumber);
            ($b | k) > ($a | k)' >/dev/null 2>&1; then
            bump_err="$bump_err; $p is $p_ver in the PR but origin/main is already $m_ver — bump above main"
        fi
        return 0
    }
    if ! pr_merge_base; then
        bump_err="$pr_mb_err"
    elif plug_mb="$pr_mb"; ! plug_rel=$(git diff --name-only "$plug_mb" "$SHA" -- VERSION 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
        bump_err="cannot read the VERSION diff against the merge-base"
    elif [ -z "$plug_rel" ]; then
        for plug in $(printf '%s\n' "$plug_files" | sed -n 's#^marketplace/plugins/\([^/]*\)/.*#\1#p' | sort -u); do
            main_path="marketplace/plugins/$plug/.claude-plugin/plugin.json"
            # absent at the merge-base = new plugin, removed whole at the head:
            # nothing to compare; a failed tree read = FAIL
            if ! mb_ls=$(git ls-tree --name-only "$plug_mb" -- "$main_path" 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
                bump_err="$bump_err; $plug cannot read the merge-base tree"
                continue
            fi
            if ! pr_ls=$(git ls-tree --name-only "$SHA" -- "$main_path" 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
                bump_err="$bump_err; $plug cannot read the PR tree"
                continue
            fi
            if [ -z "$mb_ls" ]; then plug_above_main "$plug"; continue; fi  # new at the merge-base: still judged against main, which may ship it now
            if [ -z "$pr_ls" ] && plug_removed "$SHA" "$plug"; then continue; fi
            # A change = any PR file of the plugin but the manifest, or a manifest edit beyond "version".
            plug_other=$(printf '%s\n' "$plug_files" | grep -F "marketplace/plugins/$plug/" | grep -vxF "$main_path" || true)  # swallow-ok: grep exits 1 when the plugin has no file but its manifest
            plug_changed=0
            [ -z "$plug_other" ] || plug_changed=1
            if [ "$plug_changed" -eq 0 ] && [ "$(plug_manifest_rest "$plug_mb" "$plug")" != "$(plug_manifest_rest "$SHA" "$plug")" ]; then
                plug_changed=1
            fi
            if [ "$plug_changed" -eq 0 ]; then
                mb_ver=$(plug_manifest_ver "$plug_mb" "$plug")
                pr_ver=$(plug_manifest_ver "$SHA" "$plug")
                if [ "$mb_ver" != "$pr_ver" ]; then
                    bump_err="$bump_err; $plug went ${mb_ver:-none} to ${pr_ver:-none} but no other file of $plug changed — a bump needs a change to the plugin; leave it as it is"
                fi
                continue
            fi
            plug_above_main "$plug"
        done
    else
        for plug in $(printf '%s\n' "$plug_files" | sed -n 's#^marketplace/plugins/\([^/]*\)/.*#\1#p' | sort -u); do
            plug_above_main "$plug"
        done
    fi
    if [ -z "$bump_err" ]; then
        if [ -z "$plug_rel" ]; then
            echo "[PASS] 9. every plugin the PR changes is bumped above current origin/main"
        else
            echo "[PASS] 9. release cut: every plugin the PR touches is versioned above current origin/main"
        fi
    else
        echo "[FAIL] 9. plugin version:${bump_err#;}"
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 9

if [ "$ONLY7" -eq 0 ]; then
# ── 10. workflow PRs need a green workflow_dispatch run AT HEAD ──
# A PR is CI-tested only in pull_request mode; the mode main runs (cron,
# dispatch) is never exercised before merge. ci.yml has no push trigger
# so a workflow_dispatch run on the branch is the only pre-merge
# test of the non-PR path. Every .github/workflows/*.yml the PR changes needs a
# completed, successful workflow_dispatch run whose headSha is this head — a run
# at an older sha proves nothing about the change. A changed workflow with no
# workflow_dispatch trigger FAILs and names the missing trigger, unless it is
# listed below: those cannot be dispatched (their trigger is pull_request_target,
# workflow_run or a tag push), so the exemption is explicit and reviewed here.
# ci-image.yml has a trigger, but its build job is gated to refs/heads/main so a
# branch cannot move :latest, and a branch dispatch concludes skipped. Its push
# trigger fires only on .github/ci-image/** paths, so a change to ci-image.yml
# alone gets no push run: its proof is the weekly cron or a workflow_dispatch on
# main. A listed workflow is skipped either way.
# macos-cadence.yml also takes a per-suite proof: a dispatch run at the head whose title names suites
# (`macos-cadence suites: <paths>`) passes when its log shows [PASS] for every named suite, however red
# the rest of the run. That route replaces the whole-run proof only when the named suites cover every
# test-*.sh the PR changes and the PR's macos-cadence.yml diff is the suites wiring alone; any other
# workflow edit, or a changed suite left unnamed, still needs an unfiltered dispatch at the head (green,
# or red only where main already is), and a suites run is never judged by the PRE-EXISTING comparison.
# A workflow the PR deletes has nothing to dispatch, and one it ADDS or renames
# to is not on the default branch, which GitHub requires to dispatch a workflow,
# so neither can be dispatched before merge and both are skipped. A PR touching no workflow
# never reaches the run API; a read/list failure FAILs.
WF_DISPATCH_EXEMPT="
.github/workflows/ci-image.yml
.github/workflows/codeowner-review-gate.yml
.github/workflows/main-sweep-red.yml
.github/workflows/pr-title-lint.yml
.github/workflows/release.yml
"
wf_files=$(printf '%s\n' "$files_json" | grep -E '^\.github/workflows/[^/]+\.ya?ml$' || true)
if [ -z "$files_json" ]; then
    echo "[FAIL] 10. cannot read PR files — workflow_dispatch run not checked"
    mark_fail
elif [ -z "$wf_files" ]; then
    echo "[PASS] 10. no workflow files touched — workflow_dispatch run not applicable"
else
    wf_err=""; wf_ids=""; wf_notes=""; wf_note=""; wf_why=""
    # wf_failed_jobs <run id> [main]: the run's failed job names, sorted, one per line (a matrix shard
    # is one job); rc 1 when the run cannot be read. The PR's run counts every unsuccessful conclusion
    # (failure, timed_out, cancelled, ...); with `main` only failure and timed_out count, because a job
    # main cancelled never ran and so is no evidence it is red there. gh pages the jobs itself.
    wf_failed_jobs() {
        local body sel='.conclusion != null and (.conclusion | IN("success", "skipped", "neutral") | not)'
        [ "${2:-}" != main ] || sel='.conclusion | IN("failure", "timed_out")'
        body=$("$GH" run view "$1" --repo "$nwo" --json jobs 2>/dev/null) || return 1  # swallow-ok: a failed read returns 1, the caller reads it as not pre-existing
        printf '%s' "$body" | jq -r ".jobs[]? | select($sel) | .name" 2>/dev/null | sort -u  # swallow-ok: unparsable jobs read as an empty set, which the caller rejects
    }
    # wf_failed_suites <run id>: the run log's failed suites as `<job><TAB><suite>` lines, sorted, from the
    # runner's own `[FAIL] <suite> (` / `[CAP EXCEEDED] <suite> (` line (the text right after the log's
    # tab-separated timestamp field, so a failed suite's indented forwarded output cannot echo one; a suite
    # whose retry passed prints neither). rc 1 when the log cannot be read.
    wf_failed_suites() {
        local log
        log=$("$GH" run view "$1" --repo "$nwo" --log 2>/dev/null) || return 1  # swallow-ok: a failed read returns 1, the caller keeps the job-name FAIL
        printf '%s\n' "$log" | awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z / {
            t = substr($3, index($3, " ") + 1)
            if (index(t, "[FAIL] ") == 1) t = substr(t, 8)
            else if (index(t, "[CAP EXCEEDED] ") == 1) t = substr(t, 16)
            else next
            split(t, a, " ")
            if (a[1] != "") print $1 "\t" a[1]
        }' | sort -u
    }
    # wf_suite_rescue <pr run id> <main run id> <jobs the job-name check refused, one per line>: rc 0 and
    # wf_rescued set (the failed suites, comma-separated) when every one of those jobs shows failed suites
    # in the PR run's log and every such suite also failed somewhere in main's run: the same test red on
    # main in another shard, so a re-shard cannot make it look new. rc 1 otherwise; wf_why names a suite red
    # only on the PR, and stays as the caller set it when a log is unreadable or a job shows no failed suite.
    wf_suite_rescue() {
        local pr_s main_s j s_new s_all="" bad=""
        pr_s=$(wf_failed_suites "$1") || return 1
        main_s=$(wf_failed_suites "$2") || return 1
        [ -n "$pr_s" ] && [ -n "$main_s" ] || return 1
        while IFS= read -r j; do
            [ -n "$j" ] || continue
            s_new=$(printf '%s\n' "$pr_s" | awk -F'\t' -v j="$j" '$1 == j { print $2 }')
            [ -n "$s_new" ] || return 1
            s_all="$s_all
$s_new"
        done <<EOF
$3
EOF
        s_all=$(printf '%s\n' "$s_all" | sed '/^$/d' | sort -u)
        bad=$(printf '%s\n' "$s_all" | grep -vxFf <(printf '%s\n' "$main_s" | cut -f2) || true)  # swallow-ok: every suite red on main is grep rc 1 and an empty set is the answer
        if [ -n "$bad" ]; then
            wf_why="run $1 failed suite(s) not red on main run $2: $(printf '%s' "$bad" | paste -sd, - | sed 's/,/, /g')"
            return 1
        fi
        wf_rescued=$(printf '%s' "$s_all" | paste -sd, - | sed 's/,/, /g')
    }
    # wf_preexisting <workflow file> <failed dispatch run id>: rc 0 and wf_note set when every failed
    # job of that run also failed in the default branch's latest completed scheduled/push run
    # of the same workflow, or (a job moved to another shard) when each refused job fails only suites that
    # also failed on main. Otherwise rc 1 and wf_why says why (empty when main is not red).
    wf_preexisting() {
        local main_runs main_row main_id main_event pr_jobs main_jobs new rc wf_rescued=""
        wf_why=""
        main_runs=$("$GH" run list --repo "$nwo" --workflow "$1" --branch "${tp_branch:-main}" --json databaseId,status,conclusion,event --limit 20 2>/dev/null) || { wf_why="cannot read main's runs"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        main_row=$(printf '%s' "$main_runs" | jq -r '[.[] | select(.status == "completed" and (.event == "schedule" or .event == "push"))][0] | select(.conclusion == "failure" or .conclusion == "timed_out") | "\(.databaseId) \(.event)"' 2>/dev/null)  # swallow-ok: unparsable runs read as empty, which returns 1 on the next line
        [ -n "$main_row" ] || return 1
        main_id="${main_row%% *}"; main_event="${main_row#* }"
        pr_jobs=$(wf_failed_jobs "$2") && [ -n "$pr_jobs" ] || { wf_why="cannot read the failed jobs of run $2"; return 1; }
        main_jobs=$(wf_failed_jobs "$main_id" main) && [ -n "$main_jobs" ] || { wf_why="cannot read the failed jobs of main run $main_id"; return 1; }
        new=$(printf '%s\n' "$pr_jobs" | grep -vxFf <(printf '%s\n' "$main_jobs")) && rc=0 || rc=$?
        if [ "$rc" -gt 1 ]; then
            wf_why="cannot compare the failed jobs of run $2 with main run $main_id"
            return 1
        fi
        if [ -n "$new" ]; then
            wf_why="run $2 failed on suites not red on main run $main_id: $(printf '%s' "$new" | paste -sd, - | sed 's/,/, /g')"
            wf_suite_rescue "$2" "$main_id" "$new" || return 1
            wf_why=""
        fi
        wf_note="PRE-EXISTING: $1 dispatch run $2 failed only on suites already red on main ($main_event run $main_id): $(printf '%s' "$pr_jobs" | paste -sd, - | sed 's/,/, /g')${wf_rescued:+ — job(s) moved shard, failed suite(s) red on main: $wf_rescued}"
    }
    # wf_wiring_only <workflow path>: rc 0 when the PR's diff of that file is the macos-cadence `suites`
    # wiring and nothing else. Every added line, trimmed, must be blank, a whole-line comment, or one of the
    # exact lines the wiring consists of (the list below); an `if:` line may instead be an existing removed
    # line plus a trailing ` && inputs.suites == ''`. Every removed line must be blank, a comment, one of the
    # two lines the wiring rewrites, or the twin of such an `if:` line. Nothing is matched by substring, so a
    # line that merely mentions "suites" is refused. rc 1 with wf_why naming the first other line, or the
    # diff unreadable. A deliberate wiring edit updates this list in the same PR.
    wf_wiring_only() {
        local patch bad wiring_lines
        wiring_lines=$(cat <<'LINES'
run-name: "${{ inputs.suites != '' && format('macos-cadence suites: {0}', inputs.suites) || 'CI (os:macos cadence)' }}"
inputs:
suites:
description: 'Space-separated repo-relative suite paths; set = run only these on one runner'
required: false
default: ''
type: string
shard: ${{ fromJSON(inputs.suites == '' && '[1, 2, 3, 4, 5, 6, 7, 8]' || '[1]') }}
run: |
if [ -n "$SUITES" ]; then
set -f
printf '%s\n' $SUITES > macos-suites.txt
if grep -qvE '^[A-Za-z0-9_./-]+$' macos-suites.txt || grep -q '\.\.' macos-suites.txt; then
echo "::error::suites must be plain repo-relative paths"
exit 2
fi
bash scripts/ci/run-shell-tests.sh --only-list macos-suites.txt .
else
bash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 .
SUITES: ${{ inputs.suites }}
LINES
)
        patch=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq ".[] | select(.filename == \"$1\") | .patch // empty" 2>/dev/null) || { wf_why="cannot read the diff of $1"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        [ -n "$patch" ] || { wf_why="the diff of $1 is not available"; return 1; }
        bad=$(printf '%s\n' "$patch" | WF_WIRING_LINES="$wiring_lines" awk -v frag=" && inputs.suites == ''" '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            function gained(s) { return length(s) > length(frag) && substr(s, length(s) - length(frag) + 1) == frag }
            function inert(l) { return l == "" || l ~ /^#/ }
            BEGIN {
                n = split(ENVIRON["WF_WIRING_LINES"], w, "\n")
                for (i = 1; i <= n; i++) ok[w[i]] = 1
                old["shard: [1, 2, 3, 4, 5, 6, 7, 8]"] = 1
                old["run: bash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 ."] = 1
            }
            /^@@/ { next }
            /^\+/ { added[++na] = trim(substr($0, 2)); next }
            /^-/ { removed[++nr] = trim(substr($0, 2)); next }
            END {
                for (i = 1; i <= nr; i++) gone[removed[i]] = 1
                for (i = 1; i <= na; i++) {
                    l = added[i]
                    if (gained(l) && substr(l, 1, length(l) - length(frag)) in gone) { twin[substr(l, 1, length(l) - length(frag))] = 1; continue }
                    if (!inert(l) && !(l in ok)) { print "+" l; exit }
                }
                for (i = 1; i <= nr; i++)
                    if (!inert(removed[i]) && !(removed[i] in old) && !(removed[i] in twin)) { print "-" removed[i]; exit }
            }') || { wf_why="cannot judge the diff of $1"; return 1; }  # swallow-ok: a failed awk sets wf_why and returns 1
        if [ -n "$bad" ]; then
            wf_why="$1 changes more than the suites wiring (${bad}), so an unfiltered dispatch at the head is required"
            return 1
        fi
    }
    # wf_suites_proof <workflow file> <dispatch runs json>: macos-cadence only. rc 0 and wf_note set when a
    # completed dispatch run at the head named its suites (displayTitle `macos-cadence suites: <paths>`),
    # the named suites cover every test-*.sh the PR changes, the PR's macos-cadence.yml diff is the suites
    # wiring only, and the run's log carries the runner's own `[PASS] <suite> (` for every named suite: the
    # text right after the log's tab-separated timestamp field, so a failed suite's indented forwarded output
    # cannot echo one. rc 1: no such run (the caller falls through to the whole-run rules). rc 2: such a run
    # exists but is not proven; wf_why says why and the verdict is final for that suites run, because the
    # job-level PRE-EXISTING comparison says nothing about which named suite failed, and a run that proves
    # too little stays refused. It never blocks judging a separate full (non-suites) failed dispatch run at
    # the head: the caller judges that run on its own, and with no such run the refusal stands.
    wf_suites_proof() {
        local wf_name="$1" row id title names s f log changed_suites pass="" bad="" uncovered=""
        wf_why=""
        wf_sp_id=""
        [ "$1" = macos-cadence.yml ] || return 1
        row=$(printf '%s' "$2" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and (.displayTitle // "" | startswith("macos-cadence suites:")))][0] | select(. != null) | "\(.databaseId) \(.displayTitle)"' 2>/dev/null)  # swallow-ok: unparsable runs read as no suites run, the caller fails closed
        [ -n "$row" ] || return 1
        id="${row%% *}"; title="${row#* }"; names="${title#macos-cadence suites:}"
        # shellcheck disable=SC2086  # word-splitting the named paths IS the point (repo paths carry no whitespace)
        set -- $names
        if [ "$#" -eq 0 ]; then wf_why="run $id names no suites"; return 2; fi
        wf_wiring_only ".github/workflows/$wf_name" || return 2
        changed_suites=$(printf '%s\n' "$files_json" | grep -E '(^|/)test-[^/]*\.sh$' || true)  # swallow-ok: no changed suite is grep rc 1, and an empty set is the answer
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case " $* " in *" $f "*) ;; *) uncovered="$uncovered, $f" ;; esac
        done <<EOF
$changed_suites
EOF
        if [ -n "$uncovered" ]; then
            wf_why="suites run $id does not name the suite(s) the PR changes: ${uncovered#, }"
            return 2
        fi
        log=$("$GH" run view "$id" --repo "$nwo" --log 2>/dev/null) || { wf_why="cannot read the log of run $id"; return 2; }  # swallow-ok: a failed read sets wf_why and returns 2, which the caller reports as a failure
        for s in "$@"; do
            if printf '%s\n' "$log" | awk -F'\t' -v want="[PASS] $s (" 'NF >= 3 && $3 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z / { if (index(substr($3, index($3, " ") + 1), want) == 1) f = 1 } END { exit !f }'; then pass="$pass, PASS $s"; else bad="$bad, $s"; fi
        done
        if [ -n "$bad" ]; then
            wf_why="suites run $id: named suite(s) with no [PASS] line (failed or never ran): ${bad#, }"
            return 2
        fi
        wf_sp_id="$id"
        wf_note="PER-SUITE: $wf_name dispatch run $id, red or green overall, named $# suite(s) and every one passed: ${pass#, }"
    }
    wf_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null)
    # wf_own_patch_id <merge-base> <commit> <file>: prints the whitespace-exact patch id of the file's change
    # from the merge-base to the commit (nothing when the file did not change). rc 1 when the diff
    # or the id cannot be read, so the caller fails closed.
    wf_own_patch_id() {
        local d p
        d=$(git --literal-pathspecs diff --no-color --no-ext-diff --no-textconv --no-renames --binary "$1" "$2" -- "$3" 2>/dev/null) || return 1  # swallow-ok: rc checked, an unreadable diff fails the comparison closed
        [ -n "$d" ] || return 0
        p=$(printf '%s\n' "$d" | git patch-id --verbatim 2>/dev/null) || return 1  # swallow-ok: rc checked, an unreadable id fails the comparison closed
        p=${p%% *}
        [ -n "$p" ] || return 1
        printf '%s' "$p"
    }
    # wf_own_patch_same <ancestor> <file>: rc 0 when the PR's own patch to the file (its merge-base
    # with origin/main to the commit) is the same at the ancestor and at the head, so the file only
    # moved because main moved forward. Any unreadable step is rc 1.
    wf_own_patch_same() {
        local a_mb a_id h_id
        if [ -z "$wf_main_ref" ]; then
            git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null || return 1  # swallow-ok: an unfetchable main fails the comparison closed
            wf_main_ref=refs/remotes/origin/main
            wf_head_mb=$(git merge-base "$wf_main_ref" "$SHA" 2>/dev/null) || wf_head_mb=""  # swallow-ok: an empty merge-base fails the comparison closed below
        fi
        [ -n "$wf_head_mb" ] || return 1
        a_mb=$(git merge-base "$wf_main_ref" "$1" 2>/dev/null) || return 1  # swallow-ok: rc checked, no merge-base fails the comparison closed
        a_id=$(wf_own_patch_id "$a_mb" "$1" "$2") || return 1
        h_id=$(wf_own_patch_id "$wf_head_mb" "$SHA" "$2") || return 1
        [ "$a_id" = "$h_id" ]
    }
    wf_main_ref=""; wf_head_mb=""
    # wf_ancestor_preexisting <workflow file>: rc 0 with wf_note, wf_anc_id and wf_anc_sha set when a
    # failed dispatch run of the PR branch at an ANCESTOR of the head passes wf_preexisting and the
    # PR's own change to every file it touches is the same at that ancestor and at the head: the file
    # is the same blob, or its patch from the merge-base with origin/main has the same patch id (the
    # head only merges main forward). That run's check runs sit on the ancestor commit, not the head.
    # Otherwise rc 1 and wf_why says why (empty when the branch has no such run).
    wf_ancestor_preexisting() {
        local rows id anc f a_ent h_ent changed prev_files
        wf_why=""
        [ -n "$wf_branch" ] || return 1
        rows=$("$GH" run list --repo "$nwo" --workflow "$1" --event workflow_dispatch --branch "$wf_branch" --json databaseId,event,status,conclusion,headSha,headBranch,displayTitle --limit 20 2>/dev/null) || { wf_why="cannot list the branch's dispatch runs"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        rows=$(printf '%s' "$rows" | jq -r --arg h "$SHA" --arg b "$wf_branch" '.[] | select(.event == "workflow_dispatch" and .status == "completed" and .conclusion == "failure" and .headBranch == $b and .headSha != $h and ((.displayTitle // "") | startswith("macos-cadence suites:") | not)) | "\(.databaseId) \(.headSha)"' 2>/dev/null)  # swallow-ok: unparsable runs read as none, which returns 1 on the next line
        [ -n "$rows" ] || return 1
        # the file list shows a rename by its new path only; the old path must match at both commits too
        prev_files=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | .previous_filename // empty' 2>/dev/null) || { wf_why="cannot read the paths the PR renames from"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        if ! git cat-file -e "$SHA^{commit}" 2>/dev/null \
            && { ! git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || ! git cat-file -e "$SHA^{commit}" 2>/dev/null; }; then  # swallow-ok: a failed fetch is reported through wf_why on the next line
            wf_why="cannot fetch PR head $SHA to compare it with an earlier dispatch"
            return 1
        fi
        while IFS=' ' read -r id anc; do
            [ -n "$id" ] || continue
            if ! git cat-file -e "$anc^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$anc" "$SHA" 2>/dev/null; then  # swallow-ok: rc is the answer, not an ancestor skips the run
                wf_why="dispatch run $id is at $anc, not an ancestor of the head"
                continue
            fi
            changed=""
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                if ! a_ent=$(git --literal-pathspecs ls-tree "$anc" -- "$f" 2>/dev/null) || ! h_ent=$(git --literal-pathspecs ls-tree "$SHA" -- "$f" 2>/dev/null); then  # swallow-ok: rc checked, an unreadable tree skips the run
                    changed="$f (unreadable)"
                    break
                fi
                if [ "$a_ent" != "$h_ent" ] && ! wf_own_patch_same "$anc" "$f"; then
                    changed="$f"
                    break
                fi
            done <<EOF
$files_json
$prev_files
EOF
            if [ -n "$changed" ]; then
                wf_why="dispatch run $id at $anc is stale: $changed differs between it and the head"
                continue
            fi
            if wf_preexisting "$1" "$id"; then
                wf_anc_id="$id"; wf_anc_sha="$anc"
                wf_note="$wf_note — run is at ancestor $anc, and the PR's own change to every file it touches is identical there and at the head"
                return 0
            fi
            wf_why="${wf_why:-dispatch run $id at $anc is not pre-existing}"
        done <<EOF
$rows
EOF
        return 1
    }
    wf_undispatchable_ok=1
    wf_undispatchable=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | select(.status == "removed" or .status == "added" or .status == "renamed") | .filename' 2>/dev/null) || wf_undispatchable_ok=0
    if [ "$wf_undispatchable_ok" -eq 0 ]; then
        wf_err="cannot read which workflow files the PR removes"
    else
        while IFS= read -r wf; do
            [ -n "$wf" ] || continue
            printf '%s\n' "$wf_undispatchable" | grep -qxF "$wf" && continue
            printf '%s' "$WF_DISPATCH_EXEMPT" | grep -qxF "$wf" && continue
            wf_base="${wf##*/}"
            if ! wf_body=$("$GH" api -H "Accept: application/vnd.github.raw" "repos/$owner/$repo/contents/$wf?ref=$SHA" 2>/dev/null); then
                wf_err="$wf_err; $wf cannot be read at $SHA"
                continue
            fi
            if ! printf '%s\n' "$wf_body" | grep -qE '^[[:space:]]*workflow_dispatch[[:space:]]*:|^[[:space:]]*-[[:space:]]*workflow_dispatch[[:space:]]*(#.*)?$|^"?on"?[[:space:]]*:.*workflow_dispatch'; then
                wf_err="$wf_err; $wf has no workflow_dispatch trigger — add one, or list it in WF_DISPATCH_EXEMPT in ready-check.sh"
                continue
            fi
            if ! wf_runs=$("$GH" run list --repo "$nwo" --workflow "$wf_base" --event workflow_dispatch --commit "$SHA" --json databaseId,status,conclusion,headSha,displayTitle --limit 20 2>/dev/null); then
                wf_err="$wf_err; $wf run list failed"
                continue
            fi
            wf_ok_id=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and .conclusion == "success" and ((.displayTitle // "") | startswith("macos-cadence suites:") | not))][0].databaseId // empty' 2>/dev/null)  # swallow-ok: unparsable runs read as no green run, the failure path then judges it
            if [ -n "$wf_ok_id" ]; then
                wf_ids="$wf_ids ${wf_base}=$wf_ok_id"
                continue
            fi
            wf_fail_id=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and .conclusion == "failure" and ((.displayTitle // "") | startswith("macos-cadence suites:") | not))][0].databaseId // empty' 2>/dev/null)  # swallow-ok: unparsable runs read as no failed run, so the check fails closed
            wf_head_runs=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h)] | length' 2>/dev/null) || wf_head_runs=1  # swallow-ok: an unreadable list counts the head as having a run, so the ancestor fallback is refused
            wf_why=""; wf_sp_rc=0
            wf_suites_proof "$wf_base" "$wf_runs" || wf_sp_rc=$?
            wf_sp_why="$wf_why"
            if [ "$wf_sp_rc" -eq 0 ]; then
                wf_ids="$wf_ids ${wf_base}=$wf_sp_id"
                wf_notes="$wf_notes
       $wf_note"
            elif [ -n "$wf_fail_id" ] && wf_preexisting "$wf_base" "$wf_fail_id"; then
                wf_ids="$wf_ids ${wf_base}=$wf_fail_id"
                wf_notes="$wf_notes
       $wf_note"
            elif [ -z "$wf_fail_id" ] && [ "$wf_head_runs" = 0 ] && wf_ancestor_preexisting "$wf_base"; then
                wf_ids="$wf_ids ${wf_base}=$wf_anc_id@$wf_anc_sha"
                wf_notes="$wf_notes
       $wf_note"
            else
                wf_why="${wf_why:-$wf_sp_why}"
                wf_err="$wf_err; $wf has no completed successful workflow_dispatch run at $SHA${wf_why:+ ($wf_why)} — run: gh workflow run $wf_base --ref ${wf_branch:-<branch>} --repo $nwo"
            fi
        done <<EOF
$wf_files
EOF
    fi
    if [ -z "$wf_err" ]; then
        if [ -n "$wf_notes" ]; then
            echo "[PASS] 10. every changed workflow has a workflow_dispatch run at head that is green or red only where main already is (or is exempt/removed)${wf_ids:+ — runs:$wf_ids}${wf_notes}"
        else
            echo "[PASS] 10. every changed workflow has a successful workflow_dispatch run at head (or is exempt/removed)${wf_ids:+ — runs:$wf_ids}"
        fi
    else
        echo "[FAIL] 10. workflow dispatch:${wf_err#;}"
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 10

if [ "$ONLY7" -eq 0 ]; then
# ── 11. an ADDED hook/script/skill/suite that nothing reaches ──
# Only status-A files are judged, so existing debt never fails a PR. The judgement
# (what counts as wired per kind) lives in scripts/testing/check-added-unwired.sh and
# reads the PR head's tree, so wiring added in the same diff counts. A PR adding
# nothing never reaches git. A files/fetch failure FAILs.
if [ -z "$files_json" ]; then
    echo "[FAIL] 11. cannot read PR files — added-but-unwired files not checked"
    mark_fail
elif ! unw_added=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | select(.status == "added") | .filename' 2>/dev/null); then
    echo "[FAIL] 11. cannot read which files the PR adds — added-but-unwired files not checked"
    mark_fail
elif [ -z "$unw_added" ]; then
    echo "[PASS] 11. the PR adds no files — added-but-unwired not applicable"
else
    unw_out=""; unw_rc=0
    # the helper reads the PR head's tree: fetch it the way check 9 does when it is not local
    if ! git cat-file -e "$SHA^{commit}" 2>/dev/null; then
        git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || true
    fi
    # shellcheck disable=SC2086  # word-splitting the added paths IS the point (repo paths carry no whitespace)
    unw_out=$(bash "$(cd "$(dirname "$0")/../../testing" && pwd)/check-added-unwired.sh" "$SHA" $unw_added 2>&1) || unw_rc=$?
    if [ "$unw_rc" -eq 0 ]; then
        echo "[PASS] 11. every added hook, script, skill or suite is reached by some wiring"
    else
        echo "[FAIL] 11. added but unwired (wire it, or allowlist it in the diff):"
        printf '%s\n' "$unw_out" | sed 's/^/       /'
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 11

TRUST_PATH=""
if [ "$ONLY7" -eq 0 ]; then
# ── 12. trust path, computed from the PR diff ──
# The same question merge-on-green asks (trust_path_check in scripts/lib/go-gate.sh:
# the default branch's list against the PR's REST file listing). The worker's READY
# text is never consulted. A refusal (unreadable list, head moved, listing cut
# short, stale anchor) FAILs and prints no TRUST-PATH line: it never reads as "no".
tp_anchor="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
tp_rc=0; tp_out=""
if [ -z "$tp_branch" ]; then
    tp_rc=2; tp_out="cannot resolve the default branch (gh repo view --json defaultBranchRef gave none)"
else
    unset -f trust_path_check 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if . "$tp_anchor/scripts/lib/go-gate.sh" 2>/dev/null && declare -F trust_path_check >/dev/null 2>&1; then
        # shellcheck disable=SC2031  # tp_branch is set in the main shell, not a subshell
        tp_out=$(GH="$GH" trust_path_check "$nwo" "$PR" "$SHA" "$tp_branch" "$tp_anchor") || tp_rc=$?
    else
        tp_rc=2; tp_out="cannot load trust_path_check from $tp_anchor/scripts/lib/go-gate.sh"
    fi
fi
if [ "$tp_rc" -ne 0 ]; then
    echo "[FAIL] 12. trust path: refused ${tp_out:-trust_path_check exited $tp_rc with no reason}"
    case "$tp_out" in
        *anchor*) echo "       hint: run ready-check.sh from the primary checkout (pulled to origin's tip), not from a worktree" ;;
    esac
    mark_fail
else
    echo "[PASS] 12. trust path: $tp_out"
    case "$tp_out" in
        hit\ *) TRUST_PATH=yes ;;
        *) TRUST_PATH=no ;;
    esac
fi
fi  # ONLY7 == 0: check 12

if [ "$ONLY7" -eq 0 ]; then
# ── 13. a code PR names a RED-then-GREEN line ──
# A PR that changes code shows the proof it was built test-first: one line of its body
# with RED, then GREEN (e.g. `RED → GREEN: test-x.sh row 4`). Exempt: a doc-only PR
# (the filter check 5 uses, so the two never disagree about what is code) and a
# Dependabot dependency-only PR (dep_pr_generated, as check 7).
if [ -z "$files_json" ]; then
    echo "[FAIL] 13. cannot read PR files — RED-then-GREEN line not checked"
    mark_fail
elif [ -z "$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)" ]; then  # swallow-ok: no non-doc line is grep rc 1, which is the doc-only answer
    echo "[PASS] 13. RED-then-GREEN line: not needed (a doc-only PR)"
elif [ -n "$(printf '%s\n' "$cov_body" | grep -E '(^|[^A-Za-z0-9])RED([^A-Za-z0-9].*[^A-Za-z0-9]|[^A-Za-z0-9])GREEN([^A-Za-z0-9]|$)' || true)" ]; then  # swallow-ok: no matching line is grep rc 1, which is the no-RED-line answer
    echo "[PASS] 13. the PR body names a RED-then-GREEN line"
elif dep_pr_generated; then
    echo "[PASS] 13. RED-then-GREEN line: not needed (a Dependabot dependency-only PR)"
else
    echo "[FAIL] 13. the PR body names no RED-then-GREEN line — add one line with RED then GREEN, e.g. 'RED → GREEN: test-x.sh row 4 failed before the change, passes after it'"
    mark_fail
fi
fi  # ONLY7 == 0: check 13

# --- 14. bug-origin line (warn only: never mark_fail, never the marker or exit code)
# bug_origin_state <body>: prints none, malformed, duplicate or ok. A column-one
# bug-origin: line outside a fence is the record; malformed beats duplicate.
bug_origin_state() {
    local lines good bad
    lines=$(printf '%s\n' "$1" | tr -d '\r' | awk '
        { s = $0; sub(/^ ? ? ?/, "", s); n = match(s, /^(```+|~~~+)/) ? RLENGTH : 0; c = substr(s, 1, 1); rest = substr(s, n + 1) }
        flen { if (n >= flen && c == fch && rest ~ /^[ \t]*$/) flen = 0; next }
        n && !(c == "`" && index(rest, "`")) { flen = n; fch = c; next }
        /^bug-origin:/ { print }
    ')
    if [ -z "$lines" ]; then echo none; return 0; fi
    # The class list is bug-origin-report.py's LINE; scripts/eval/bug-origin/line-table.tsv runs through both.
    local ere='^bug-origin:[[:blank:]]+((#[0-9]+|[0-9a-f]{7,40})[[:blank:]]+(test-gap|design-gap|review-deferred|unknown|review-miss:(cr|judge|panel)(,(cr|judge|panel))*|(residual|trigger):[A-Za-z0-9][A-Za-z0-9._/#-]*|commit:[0-9a-f]{7,40})|unknown[[:blank:]]+unknown)[[:blank:]]+(—|-)[[:blank:]]+[^[:blank:]]'
    good=$(printf '%s\n' "$lines" | LC_ALL=C grep -cE "$ere")
    bad=$(printf '%s\n' "$lines" | LC_ALL=C grep -cvE "$ere")
    if [ "$bad" -gt 0 ]; then echo malformed
    elif [ "$good" -gt 1 ]; then echo duplicate
    else echo ok
    fi
}

# check_bug_origin: prints check 14's lines, quoting no PR or Jira text. Nothing
# here touches RESULT, so a missing lib or a slow Jira costs a warn line at most.
check_bug_origin() {
    local bo_lib bo_title bo_key bo_rc bo_reply bo_type bo_state
    bo_lib="$(cd "$(dirname "$0")/../../lib" 2>/dev/null && pwd)"  # swallow-ok: no lib dir fails the two -f tests below, which warn
    _TIMEOUT_BIN=""
    # shellcheck source=/dev/null
    [ ! -f "$bo_lib/timeout-bin.sh" ] || . "$bo_lib/timeout-bin.sh" 2>/dev/null  # swallow-ok: an empty _TIMEOUT_BIN warns just below
    if [ -z "$_TIMEOUT_BIN" ]; then
        echo "[WARN] 14. bug-origin not checked: timeout"
        return 0
    fi
    if [ "$ONLY7" -eq 1 ]; then
        bo_title=$("$_TIMEOUT_BIN" -k 5 15 "$GH" pr view "$PR" --repo "$nwo" --json title --jq '.title' 2>/dev/null) || bo_title=""  # swallow-ok: an unreadable title warns just below
    else
        bo_title=$(printf '%s' "$snapshot" | jq -r '.[0].title // empty' 2>/dev/null) || bo_title=""  # swallow-ok: an unreadable title warns just below
    fi
    if [ -z "$bo_title" ]; then
        echo "[WARN] 14. bug-origin not checked: title"
        return 0
    fi
    if [ ! -f "$bo_lib/ticket-status.sh" ]; then
        echo "[WARN] 14. bug-origin not checked: lib"
        return 0
    fi
    # A subshell: that lib sources three more into this trust-path script.
    bo_key=$(
        # shellcheck source=/dev/null
        . "$bo_lib/ticket-status.sh" 2>/dev/null  # swallow-ok: declare -F on the next line decides, rc 70 warns
        declare -F ticket_key_from_title >/dev/null || exit 70
        ticket_key_from_title "$bo_title"
    )
    bo_rc=$?
    if [ "$bo_rc" -eq 1 ]; then
        echo "[PASS] 14. bug-origin: not a Bug-ticket PR"
        return 0
    elif [ "$bo_rc" -ne 0 ] || [ -z "$bo_key" ]; then
        echo "[WARN] 14. bug-origin not checked: lib"
        return 0
    fi
    bo_reply=$(
        export -f jira_run jira_get
        # shellcheck disable=SC2016  # $1 expands in the child shell
        "$_TIMEOUT_BIN" -k 5 15 bash -c 'jira_get "$1"' "$0" "$bo_key"
    ) || {
        echo "[WARN] 14. bug-origin not checked: jira"
        return 0
    }
    bo_type=$(printf '%s' "$bo_reply" | jq -r '.fields.issuetype.name // empty' 2>/dev/null) || bo_type=""  # swallow-ok: an unreadable reply warns just below
    if [ -z "$bo_type" ]; then
        echo "[WARN] 14. bug-origin not checked: type"
        return 0
    elif [ "$bo_type" != "Bug" ]; then
        echo "[PASS] 14. bug-origin: not a Bug-ticket PR"
        return 0
    fi
    bo_state=$(bug_origin_state "$cov_body")
    if [ "$bo_state" = ok ]; then
        echo "[PASS] 14. bug-origin line present"
        return 0
    fi
    echo "[WARN] 14. bug-origin: $bo_state"
    echo "        accepted: bug-origin: <#pr|sha|unknown> <test-gap|design-gap|review-deferred|review-miss:<cr,judge,panel>|residual:<token>|trigger:<token>|commit:<sha>|unknown> — <reason>"
    echo "        see the Ship step of docs/handover/worker-brief-template.md"
}
check_bug_origin

# --- 15. CodeRabbit rate-limited at the head: WARN only, never mark_fail.
# CodeRabbit posts success + "Review rate limited" and reviews nothing, so the green
# status is not a review. Same reader as check-ci (scripts/lib/coderabbit-signal.sh):
# prints only on a positive match; a repo without CodeRabbit, a reviewed head and an
# unreadable status print nothing (nothing here ever claims a head was reviewed).
check_cr_rate_limited() {
    local cr_dir cr_lib cr_out
    [ "$ONLY7" -eq 0 ] || return 0
    cr_dir="$(cd "$(dirname "$0")/../../lib" 2>/dev/null && pwd)"  # swallow-ok: no lib dir fails the -f tests below, which print nothing
    cr_lib="$cr_dir/coderabbit-signal.sh"
    [ -f "$cr_lib" ] || return 0
    _TIMEOUT_BIN=""
    # shellcheck source=/dev/null
    [ ! -f "$cr_dir/timeout-bin.sh" ] || . "$cr_dir/timeout-bin.sh" 2>/dev/null  # swallow-ok: an empty _TIMEOUT_BIN skips this advisory row just below
    [ -n "$_TIMEOUT_BIN" ] || return 0
    # Both status reads run in one child under a deadline: a stalled gh costs this
    # advisory row, never the verdict line.
    # shellcheck disable=SC2016  # the body expands in the child shell
    cr_out=$(GH_CMD="$GH" "$_TIMEOUT_BIN" -k 5 20 bash -c '
        . "$1" 2>/dev/null || exit 0  # read-sink-ok: $1 is the own lib path built from dirname of this script, never user input
        [ "$(cr_signal_state "$2" "$3" "$4" 2>/dev/null)" = skipped ] || exit 0  # swallow-ok: advisory, an unreadable status prints nothing
        d=$(cr_signal_description "$2" "$3" "$4" 2>/dev/null) || exit 0  # swallow-ok: advisory, an unreadable status prints nothing
        ! grep -qiE "rate.?limit" <<< "$d" || echo rl' _ "$cr_lib" "$owner" "$repo" "$SHA") || cr_out=""  # swallow-ok: advisory, a timeout or an unreadable status prints nothing
    if [ "$cr_out" = rl ]; then
        echo "[WARN] 15. CodeRabbit rate-limited at head ${SHA:0:8}: NO CodeRabbit review here (the green status is not a review); not gating, a posted finding still blocks. Re-request once when capacity returns: \`@coderabbitai review\`"
    fi
}
check_cr_rate_limited

# --- 16. outside-PR full review. outside_pr_of no prints nothing, so an org-member
# PR's output is unchanged. For yes, every record must sit at the head itself (an
# ancestor's never counts), keyed to headRefName; no body, title, label, branch-name
# or trailer text is read. An unreadable input, an empty files list, a missing node
# or timeout binary, or a network read past its bound FAILs.
o16_fail() { echo "[FAIL] 16$1. $2"; o16_missing=$((o16_missing + 1)); }
# o16_ledger <kind> <jq projection>: rows of <kind> at this head and branch, oldest first
o16_ledger() {
    jq -R -r --arg k "$1" --arg h "$SHA" --arg b "$o16_branch" --argjson p "$PR" '
        fromjson? | select(type == "object" and .kind == $k and .head == $h and .branch == $b and (.pr == null or .pr == $p))
        | '"$2" "$o16_ledger" 2>/dev/null
}
check_outside_pr() {
    local op o_anchor o_lib o_h7 o_rows o_last o_round o_from o_lint o_files o_frc=0 o_surf o_hits f p
    local o_thr o_unres o_res o_bad o_why o_crc o_scope o_cr o_login o_id o_rep
    o16_missing=0
    [ "$ONLY7" -eq 0 ] || return 0
    op=$(outside_pr_of "$snapshot") || op=unknown
    [ "$op" != no ] || return 0
    o_h7="${SHA:0:7}"
    if [ "$op" != yes ]; then
        echo "[FAIL] 16. outside-PR full review: cannot tell whether #$PR is an outside PR (PR snapshot unreadable)"
        mark_fail
        return 0
    fi
    o_anchor="$(cd "$(dirname "$0")/../../.." && pwd)"
    o_lib="$o_anchor/scripts/lib"
    _TIMEOUT_BIN=""
    # shellcheck source=/dev/null
    [ ! -f "$o_lib/timeout-bin.sh" ] || . "$o_lib/timeout-bin.sh" 2>/dev/null  # swallow-ok: an empty _TIMEOUT_BIN fails item 16 just below
    if [ -z "$_TIMEOUT_BIN" ]; then
        echo "[FAIL] 16. outside-PR full review: no timeout binary, so no read here can be bounded"
        mark_fail
        return 0
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "[FAIL] 16. outside-PR full review: node not found (16g reads the blast scope with it)"
        mark_fail
        return 0
    fi
    # shellcheck source=../../lib/outside-contributors.sh
    if ! . "$o_lib/outside-contributors.sh" 2>/dev/null; then
        echo "[FAIL] 16. outside-PR full review: cannot load scripts/lib/outside-contributors.sh"
        mark_fail
        return 0
    fi
    o16_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null) || o16_branch=""  # swallow-ok: an empty branch fails every ledger sub-check below
    o16_ledger=""
    if [ -n "$common_dir" ] && [ -f "$common_dir/cr-critic-scores.jsonl" ] && [ -r "$common_dir/cr-critic-scores.jsonl" ] && [ -n "$o16_branch" ]; then
        o16_ledger="$common_dir/cr-critic-scores.jsonl"
    fi

    # 16b: a full round-scope row at the head
    if [ -z "$o16_ledger" ] || ! o_rows=$(o16_ledger round-scope 'select(.status == "ok") | "\(.scope) \(.round) \(.from // "-")"'); then
        o16_fail b "cannot read the CR ledger or the PR branch: run /pr-check at $o_h7 (step 3 runs panel-first-pass.sh --full)"
    elif grep -q '^full ' <<< "$o_rows"; then
        echo "[PASS] 16b. a full review round is recorded at $o_h7 on $o16_branch"
    else
        o_last=$(grep '^delta ' <<< "$o_rows" | tail -n 1)
        read -r _ o_round o_from <<< "$o_last"
        case "$o_round" in ''|*[!0-9]*) o_round=0 ;; esac
        if [ -z "$o_last" ]; then
            o16_fail b "no full review round at $o_h7 on $o16_branch: run /pr-check at $o_h7 (step 3 runs panel-first-pass.sh --full)"
        elif [ "$o_round" -gt 3 ]; then
            o16_fail b "only a post-cap delta round at $o_h7: past its three full rounds, hand it to a maintainer takeover (HIMMEL-9019)"
        else
            o16_fail b "only a delta round (from ${o_from:0:7}) at $o_h7: run /pr-check at $o_h7 (step 3 runs panel-first-pass.sh --full)"
        fi
    fi

    # 16c: the latest lint CheckRun of workflow CI succeeded
    if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
        o16_fail c "statusCheckRollup unreadable: the CI run, or a maintainer's approve-and-run for a fork"
    elif ! o_lint=$(printf '%s' "$rollup" | jq -er "$ROLLUP_LATEST_DEFS"'
            rollup_rows | latest_per_check
            | map(select(.is_checkrun and .name == "lint" and .workflow == "CI")) | first
            | if . == null then "none" elif .success then "ok" else .detail end' 2>/dev/null); then
        o16_fail c "statusCheckRollup unreadable: the CI run, or a maintainer's approve-and-run for a fork"
    elif [ "$o_lint" = ok ]; then
        echo "[PASS] 16c. the latest lint run of workflow CI at $o_h7 is SUCCESS"
    elif [ "$o_lint" = none ]; then
        o16_fail c "no lint run of workflow CI at $o_h7: the CI run, or a maintainer's approve-and-run for a fork"
    else
        o16_fail c "the latest lint run of workflow CI at $o_h7 is $o_lint, want SUCCESS: the CI run, or a maintainer's approve-and-run for a fork"
    fi

    # 16d: no path (either side of a rename) under the anchor's lint surface
    o_files=$("$_TIMEOUT_BIN" -k 5 20 "$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) || o_frc=1  # swallow-ok: a failed read fails 16d and 16g just below
    [ -n "$o_files" ] || o_frc=1
    o_surf=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$o_anchor/scripts/ci/outside-lint-surface.txt" 2>/dev/null) || o_surf=""  # swallow-ok: an unreadable or empty list fails 16d just below
    if [ "$o_frc" -ne 0 ]; then
        o16_fail d "cannot read the PR's files (or the list is empty): re-run ready-check"
    elif [ -z "$o_surf" ]; then
        o16_fail d "cannot read scripts/ci/outside-lint-surface.txt (missing or empty)"
    else
        o_hits=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            while IFS= read -r p; do
                case "$f" in "$p"*) o_hits="$o_hits $f"; break ;; esac
            done <<< "$o_surf"
        done <<< "$o_files"
        if [ -z "$o_hits" ]; then
            echo "[PASS] 16d. the PR touches no lint surface"
        else
            o16_fail d "the PR touches the lint surface, so CI's lint verdict is not trusted:$o_hits: the HIMMEL-9019 takeover"
        fi
    fi

    # 16e: no unresolved thread, every resolver internal, check-ci --threads-only green
    o_why=""
    if ! o_thr=$(printf '%s' "$snapshot" | jq -er '.[0].reviewThreads.nodes | select(type == "array")
            | "\([.[] | select(.isResolved | not)] | length) \([.[] | select(.isResolved) | (.resolvedBy.login // "(unknown)")] | unique | join(","))"' 2>/dev/null); then
        o_why="review threads unreadable"
    else
        read -r o_unres o_res <<< "$o_thr"
        [ "$o_unres" = 0 ] || o_why="$o_unres unresolved thread(s)"
        o_bad=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ "$f" = "(unknown)" ] || [ "$(author_class "$f")" != 1 ]; then o_bad="$o_bad $f"; fi
        done <<< "${o_res//,/$'\n'}"
        [ -z "$o_bad" ] || o_why="${o_why:+$o_why; }thread(s) resolved by a non-maintainer:$o_bad (unresolve, then resolve as a maintainer)"
    fi
    if [ ! -f "$o_anchor/scripts/check-ci.sh" ]; then
        o_why="${o_why:+$o_why; }scripts/check-ci.sh not found"
    else
        o_crc=0
        env -u CR_APP -u CR_PROFILE -u CR_BOT_USER_ID "$_TIMEOUT_BIN" -k 5 20 bash "$o_anchor/scripts/check-ci.sh" "$PR" --threads-only </dev/null >/dev/null 2>&1 || o_crc=$?
        [ "$o_crc" -eq 0 ] || o_why="${o_why:+$o_why; }check-ci.sh $PR --threads-only exited $o_crc (124 or 137: past its 20s bound)"
    fi
    if [ -z "$o_why" ]; then
        echo "[PASS] 16e. no open or outsider-resolved thread, check-ci.sh --threads-only green"
    else
        o16_fail e "$o_why: resolve or re-raise each thread, then re-run check-ci.sh $PR --threads-only"
    fi

    # 16f: an impacted row with rc 0 and nothing skipped
    if [ -z "$o16_ledger" ] || ! o_rows=$(o16_ledger impacted 'select(.status == "ok") | "\(.rc) \(.skip_n)"'); then
        o_last="unreadable"
    else
        o_last=$(tail -n 1 <<< "$o_rows")
    fi
    if [ "$o_last" = "0 0" ]; then
        echo "[PASS] 16f. impacted suites recorded green at $o_h7, none skipped"
    else
        o16_fail f "no impacted row at $o_h7 on ${o16_branch:-?} with rc 0 and skip_n 0 (newest: ${o_last:-none}): impacted-suites.sh --check <base>..$SHA --from-file <f> --record --branch ${o16_branch:-<branch>} --head $SHA; when an impacted suite has no CI job and no VM run can host it, the HIMMEL-9019 takeover"
    fi

    # 16g: a diff touching the blast scope owes a ran blast row
    o_scope=""
    [ "$o_frc" -ne 0 ] || o_scope=$(printf '%s\n' "$o_files" | tr '\n' '\0' | node "$o_anchor/scripts/cr/blast-scope.cjs" 2>/dev/null) || o_scope=""  # swallow-ok: an unreadable scope fails 16g just below
    if [ "$o_scope" = untouched ]; then
        echo "[PASS] 16g. the diff does not touch the blast scope"
    elif [ "$o_scope" != touched ]; then
        o16_fail g "cannot tell whether the diff touches the blast scope (files list or scripts/cr/blast-scope.cjs unreadable)"
    elif [ -n "$o16_ledger" ] && o_rows=$(o16_ledger blast '.status') && [ "$(tail -n 1 <<< "$o_rows")" = ran ]; then
        echo "[PASS] 16g. a blast run is recorded at $o_h7"
    else
        o16_fail g "the diff touches the blast scope and no ran blast row is at $o_h7: ledger-append.sh blast --branch ${o16_branch:-<headRefName>} --head $SHA --duration-secs <s>"
    fi

    # 16h/16i: an unlisted author owes a CodeRabbit success and a passed audit
    o_login=$(printf '%s' "$snapshot" | jq -r '.[0].author // empty' 2>/dev/null) || o_login=""  # swallow-ok: an empty login is unlisted
    o_id=$(printf '%s' "$snapshot" | jq -r '.[0].authorId // empty' 2>/dev/null) || o_id=""  # swallow-ok: an empty id is unlisted
    if outside_contributor_allowed "$o_login" "$o_id"; then
        echo "[SKIP] 16h/16i listed author $o_login"
    else
        # A fresh child with every CodeRabbit pattern override unset: the lib binds them at source time.
        # shellcheck disable=SC2016  # the body expands in the child shell
        o_cr=$(env -u CR_OK_DESC_RE -u CR_SKIP_DESC_RE -u CR_BOT_USER_ID -u CR_STATUS_CONTEXT GH_CMD="$GH" \
            "$_TIMEOUT_BIN" -k 5 20 bash -c '. "$1" 2>/dev/null || exit 3; cr_signal_state "$2" "$3" "$4"' \
            _ "$o_lib/coderabbit-signal.sh" "$owner" "$repo" "$SHA" 2>/dev/null </dev/null) || o_cr="unreadable"  # read-sink-ok: $1 is this checkout's own lib path
        if [ "$o_cr" = success ]; then
            echo "[PASS] 16h. CodeRabbit reviewed $o_h7 (success)"
        else
            o16_fail h "CodeRabbit at $o_h7 is ${o_cr:-unreadable}, want success: stage 1, comment \`@coderabbitai review\` on the PR and wait for the status at $o_h7"
        fi
        if outside_audit_passed "$PR" "$SHA" "$o16_branch"; then
            echo "[PASS] 16i. the outside security audit passed at $o_h7"
        else
            o_rep=""
            [ -z "$o16_ledger" ] || o_rep=$(jq -R -r --arg h "$SHA" --argjson p "$PR" 'fromjson? | select(type == "object" and .kind == "security-audit" and .pr == $p and .head == $h and .verdict == "fail") | .report // "?"' "$o16_ledger" 2>/dev/null | tail -n 1)  # swallow-ok: no readable fail row names the audit run instead
            if [ -n "$o_rep" ]; then
                o16_fail i "the outside security audit FAILED at $o_h7 (report $o_rep): the only way out is a new head"
            elif [ -f "$o_anchor/scripts/cr/outside-security-audit.sh" ]; then
                o16_fail i "no passed outside security audit at $o_h7: stage 2, outside-security-audit.sh --pr $PR --head $SHA"
            else
                o16_fail i "no passed outside security audit at $o_h7: stage 2, outside-security-audit.sh --pr $PR --head $SHA, which this checkout does not carry yet, so the PR waits for it"
            fi
        fi
    fi

    if [ "$o16_missing" -eq 0 ]; then
        echo "[PASS] 16. outside-PR full review: every record present at $o_h7"
    else
        echo "[FAIL] 16. outside-PR full review: $o16_missing record(s) missing at $o_h7"
        mark_fail
    fi
}
check_outside_pr

# --- 17. a partial merge records what remains: merge-on-green.sh's exit 26, read at GO time.
# The merge refuses a contract-`no` merge (part of the ticket stays undone) whose PR body carries neither a `Remaining:` line
# nor a `deferred -> <KEY>` line under `## Ticket coverage`, so a GO for such a PR is a GO the merge refuses. This reads
# the title's key with the merge's own reader (ticket_key_from_title) and the body with the merge's own remainder reader
# (scripts/lib/pr_remainder.py, run from the anchor with python3 -I, never from the checkout under review). The contract is
# the merge line's (--jira-transition, or the brief's `Completes ticket:`), so the caller names it: --contract yes|no.
check_partial_remainder() {
    local pr_title lib key rc anchor reader ans
    [ "$ONLY7" -eq 0 ] || return 0
    lib="$(cd "$(dirname "$0")/../../lib" 2>/dev/null && pwd)"  # swallow-ok: no lib dir leaves the key unread, reported just below
    pr_title=$(printf '%s' "$snapshot" | jq -r '.[0].title // empty' 2>/dev/null) || pr_title=""  # swallow-ok: an unreadable title is reported just below
    key=""; rc=0
    if [ -n "$pr_title" ] && ! printf '%s' "$pr_title" | grep -Eq '[A-Za-z][A-Za-z0-9]*-[0-9]+'; then
        # No KEY-n anywhere in the title, so the merge's reader finds no key (its rc 1): skip the library load.
        rc=1
    elif [ -n "$pr_title" ] && [ -f "$lib/ticket-status.sh" ]; then
        # A subshell: that lib sources three more into this trust-path script.
        key=$(
            # shellcheck source=/dev/null
            . "$lib/ticket-status.sh" 2>/dev/null  # swallow-ok: declare -F on the next line decides, rc 70 is unreadable
            declare -F ticket_key_from_title >/dev/null || exit 70
            ticket_key_from_title "$pr_title"
        ) || rc=$?
    else
        rc=70
    fi
    if [ "$rc" -eq 1 ]; then
        echo "[PASS] 17. partial-merge remainder: not applicable (the PR title carries no [KEY], as at the merge)"
        return 0
    fi
    if [ "$rc" -ne 0 ] || [ -z "$key" ]; then
        if [ "$REQUIRE_CONTRACT" -eq 1 ]; then
            echo "[FAIL] 17. partial-merge remainder: cannot read the PR title or its ticket key, so the merge contract cannot be checked"
            mark_fail
        else
            echo "[WARN] 17. partial-merge remainder not checked: the PR title or the key reader is unreadable"
        fi
        return 0
    fi
    case "$CONTRACT" in
        '')
            if [ "$REQUIRE_CONTRACT" -eq 1 ]; then
                echo "[FAIL] 17. the PR title names $key and no merge contract was given — re-run with --contract yes|no (yes: this merge completes $key; no: a partial merge, and the body must say what remains)"
                mark_fail
            else
                echo "[WARN] 17. partial-merge remainder not checked: no --contract given for $key (a GO writer names it)"
            fi
            return 0 ;;
        yes)
            echo "[PASS] 17. contract yes: this merge completes $key, so no remainder is read"
            return 0 ;;
    esac
    anchor="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
    reader="$anchor/scripts/lib/pr_remainder.py"
    ans=""; rc=0
    if [ -f "$reader" ]; then
        ans=$(printf '%s' "${cov_body:-}" | python3 -I "$reader" "$key" 2>/dev/null) || rc=$?  # swallow-ok: a non-zero rc or empty answer FAILs item 17 below
    else
        rc=3
    fi
    if [ "$rc" -ne 0 ] || [ -z "$ans" ]; then
        echo "[FAIL] 17. cannot read the remainder of partial merge $key: the anchor's scripts/lib/pr_remainder.py is missing or gave no answer ($reader)"
        mark_fail
    elif [ "${ans%%$'\t'*}" = none ]; then
        echo "[FAIL] 17. $key is a partial merge (--contract no) but the PR body has no \`Remaining:\` line and no \`<ask>: deferred -> <KEY>\` line under \`## Ticket coverage\` — the merge refuses it (exit 26); add one (gh pr edit $PR --body-file <file>)"
        mark_fail
    elif [ "${ans%%$'\t'*}" = handed-off ]; then
        echo "[FAIL] 17. $key is a partial merge (--contract no) but every remaining ask is on $(printf '%s' "$ans" | cut -f2), so this merge completes $key and the merge refuses it (exit 26). If the brief says Completes ticket: no, the chief changes it to yes and re-issues the GO with --contract yes; else re-issue the GO with --contract yes (the merge then runs with --jira-transition); or record what stays on $key with a Remaining: line (gh pr edit $PR --body-file <file>)"
        mark_fail
    else
        echo "[PASS] 17. partial merge $key records what remains (${ans%%$'\t'*})"
    fi
}
check_partial_remainder

# --- 18. open blocking findings: the merge's gates 4 and 4b, read at GO time.
# clear-review-marker.sh refuses a merge when the ledger holds a blocking finding (gate 4) or an undecided one (gate 4b) at
# the head it gates on. That head is not always the PR head: after a judge GO it is the round head the panel last ran at,
# so an Important never ruled there blocks a PR whose tip has its own green rows (PR 4611: items 4 and 7 passed, the merge
# refused with exit 15). The GO is not written yet, so the head is read twice, as the merge reads it now and as it reads it
# once the chief's GO exists. The read is the marker's own --check-findings mode (one reader, no copy, nothing written).
check_open_findings() {
    local of_branch of_marker of_lib of_assume of_rc of_out
    [ "$ONLY7" -eq 0 ] || return 0
    of_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null) || of_branch=""  # swallow-ok: an unreadable branch fails just below
    if [ -z "$of_branch" ]; then
        echo "[FAIL] 18. open findings: cannot read the PR's head branch, so the head the merge gates on cannot be chosen"
        mark_fail
        return 0
    fi
    of_marker="$(cd "$(dirname "$0")/../../cr" 2>/dev/null && pwd)/clear-review-marker.sh"  # swallow-ok: no cr dir fails the -f test below
    if [ ! -f "$of_marker" ]; then
        echo "[FAIL] 18. open findings: scripts/cr/clear-review-marker.sh is missing ($of_marker)"
        mark_fail
        return 0
    fi
    _TIMEOUT_BIN=""
    of_lib="$(cd "$(dirname "$0")/../../lib" 2>/dev/null && pwd)"  # swallow-ok: no lib dir leaves the read unbounded, never unread
    # shellcheck source=/dev/null
    [ ! -f "$of_lib/timeout-bin.sh" ] || . "$of_lib/timeout-bin.sh" 2>/dev/null  # swallow-ok: an empty _TIMEOUT_BIN runs the read unbounded
    for of_assume in "" "--assume-go"; do
        of_rc=0
        # shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
        of_out=$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 90} bash "$of_marker" --check-findings --tip "$SHA" $of_assume "$of_branch" 2>&1 </dev/null) || of_rc=$?
        if [ "$of_rc" -ne 0 ]; then
            echo "[FAIL] 18. open findings: the merge refuses this head (clear-review-marker.sh --check-findings${of_assume:+ $of_assume} exit $of_rc): $(printf '%s' "$of_out" | tr '\n' ' ' | cut -c1-400)"
            mark_fail
            return 0
        fi
    done
    echo "[PASS] 18. no blocking or undecided finding at the head the merge gates on (read as the merge reads it, with and without the GO)"
}
check_open_findings

# --- 19. suite evidence. Each impacted suite needs local proof (the head's
# `impacted` ledger row) or CI proof (an exact `ran 0 <path>` line in a shard
# manifest of the run behind the latest SUCCESS `shell-unit (ubuntu-latest)`
# check-run in workflow CI, whose run head_sha is SHA). The manifests are read
# only when some suite lacks local proof. The row comes from o16_ledger (head,
# headRefName, .pr null or this PR). ponytail: the latest-run pick mirrors check
# 2's rather than sharing it; upgrade path: one shared latest-run reader.
S17_AGG="shell-unit (ubuntu-latest)"
s17_bound() {  # <default seconds>: READY_CHECK_ITEM19_BOUND wins only when 1 or more and lower (timeout 0 means no limit)
    local b="${READY_CHECK_ITEM19_BOUND:-}"
    case "$b" in ''|*[!0-9]*) printf '%s' "$1" ;; *) if [ "$b" -ge 1 ] && [ "$b" -lt "$1" ]; then printf '%s' "$b"; else printf '%s' "$1"; fi ;; esac
}
s17_fail() { echo "[FAIL] 19. suite evidence: $1"; mark_fail; }
# s17_run <name> <seconds> <out> <cmd...>: bounded; rc 124/137 is a timeout, said by name
s17_run() {
    local name="$1" n="$2" out="$3" rc=0
    shift 3
    "$_TIMEOUT_BIN" -k 5 "$n" "$@" > "$out" 2> "$out.err" < /dev/null || rc=$?
    case "$rc" in
        0) return 0 ;;
        124|137) s17_why="$name timed out after ${n}s" ;;
        *) s17_why="$name failed (rc $rc: $(head -n 1 "$out.err" 2>/dev/null))" ;;  # swallow-ok: a missing err file prints an empty reason
    esac
    return 1
}
# The CI failure ledger: station state, append-only, report-only.
# A `fail` row is a suite left to CI that failed there at a PR head; a `round` row
# says that PR moved on to a new head after a failure (an extra round). The rows
# never change a verdict; scripts/cr/suite-fail-ledger.sh reads them.
# ponytail: dedupe-then-append is unlocked, so two racing reads can double a row; a lock if the counts drift.
s17_fl_path() { printf '%s' "${READY_CHECK_FAIL_LEDGER:-${HOME:-/tmp}/.himmel/state/suite-evidence/ci-failures.jsonl}"; }
s17_fl_add() {  # <json row>: appended once, dir 700, file 600; the registry envelope (v, host, source) is added here
    local f row; f=$(s17_fl_path)
    row=$(printf '%s' "$1" | jq -c --arg h "${HOSTNAME:-$(uname -n)}" '{v: 1} + . + {host: $h, source: "ready-check"}') || { echo "       note: CI failure ledger row not built"; return 0; }
    mkdir -p "$(dirname "$f")" 2>/dev/null && chmod 700 "$(dirname "$f")" 2>/dev/null  # swallow-ok: an unwritable ledger only loses the advisory row
    ( umask 077; printf '%s\n' "$row" >> "$f" ) 2>/dev/null || echo "       note: CI failure ledger not written ($f)"
}
s17_fl_rounds() {  # one `round` row per earlier failed head of this PR
    local f h
    f=$(s17_fl_path)
    [ -r "$f" ] || return 0
    jq -n -R -r --arg r "$owner/$repo" --argjson p "$PR" --arg h "$SHA" '
        [inputs | fromjson? | select(type == "object" and .repo == $r and .pr == $p)] as $rows
        | ($rows | map(select(.kind == "round") | .head)) as $done
        | $rows | map(select(.kind == "fail" and .head != $h) | .head) | unique[]
        | select(. as $x | $done | index($x) | not)' "$f" 2>/dev/null | while IFS= read -r h; do  # swallow-ok: an unreadable ledger records no round
        s17_fl_add "$(jq -nc --arg r "$owner/$repo" --argjson p "$PR" --arg h "$h" --arg n "$SHA" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{kind: "round", ts: $t, repo: $r, pr: $p, head: $h, next: $n}')"
    done
}
s17_fl_failures() {  # <dir> <run id>: one `fail` row per suite in <dir>/need with a nonzero `ran` line
    local d="$1" run="$2" f s rc n=0
    f=$(s17_fl_path)
    s17_run "gh api actions/runs/$run" "$(s17_bound 15)" "$d/fhs" "$GH" api "repos/$owner/$repo/actions/runs/$run" --jq .head_sha || return 0
    [ "$(tr -d '[:space:]' < "$d/fhs")" = "$SHA" ] || return 0
    mkdir "$d/fm" 2>/dev/null || return 0  # swallow-ok: advisory
    s17_run "gh run download $run" "$(s17_bound 30)" "$d/fdl" "$GH" run download "$run" -R "$owner/$repo" -p 'shell-unit-manifest-ubuntu-latest-shard*' -D "$d/fm" || return 0
    find "$d/fm" -type f -name 'manifest-shard*.txt' -exec cat {} + 2>/dev/null | tr -d '\r' \
        | awk '$1 == "ran" && $2 ~ /^[0-9]+$/ && $2 != "0" && NF == 3 { print $2, $3 }' > "$d/fred" || return 0  # swallow-ok: advisory
    while read -r rc s; do
        grep -Fxq -- "$s" "$d/need" || continue
        if [ -r "$f" ] && jq -R -e --arg r "$owner/$repo" --argjson p "$PR" --arg h "$SHA" --arg s "$s" --argjson u "$run" '
            fromjson? | select(type == "object" and .kind == "fail" and .repo == $r and .pr == $p and .head == $h and .suite == $s and .run == $u)' "$f" > /dev/null 2>&1; then
            continue
        fi
        s17_fl_add "$(jq -nc --arg r "$owner/$repo" --argjson p "$PR" --arg h "$SHA" --arg s "$s" --argjson u "$run" --argjson c "$rc" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{kind: "fail", ts: $t, repo: $r, pr: $p, head: $h, suite: $s, run: $u, rc: $c}')"
        n=$((n + 1))
    done < "$d/fred"
    [ "$n" -eq 0 ] || echo "       note: CI failure ledger +$n row(s) for run $run ($f)"
}
check_suite_evidence() {
    local d
    [ "$ONLY7" -eq 0 ] || return 0
    d=$(mktemp -d "${TMPDIR:-/tmp}/ready-check-19.XXXXXX") || { s17_fail "mktemp failed"; return 0; }  # prim-ok: ready-check sources no prim.sh; a failed mktemp FAILs item 19
    # shellcheck disable=SC2064  # $d is fixed now on purpose: the trap removes this dir whatever exit path follows
    # shellcheck disable=SC2064  # $d is fixed now on purpose: the trap removes this dir whatever exit path follows
    trap "rm -rf '$d'" EXIT
    s17_body "$d"
    s17_fl_rounds
    rm -rf "$d"
    trap - EXIT
}
s17_body() {
    local d="$1" anchor n_imp branch ledger row="" have_row=0 run_id="" agg n_ci=0 n_local=0 n_ruled=0 s why bad=0 reasons="" ruled_names="" grc
    s17_why=""
    _TIMEOUT_BIN=""
    # shellcheck source=../../lib/timeout-bin.sh
    . "$(cd "$(dirname "$0")/../../lib" && pwd)/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN FAILs item 19 just below
    if [ -z "$_TIMEOUT_BIN" ]; then
        s17_fail "no timeout binary, so no read here can be bounded"
        return 0
    fi
    if ! pr_fetch; then
        s17_fail "cannot resolve the range: $pr_mb_err"
        return 0
    fi
    # The anchor's copy, so a PR cannot narrow its own list. It diffs from
    # merge-base(origin/main, SHA) itself and exits 2 when there is none.
    anchor="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
    if ! s17_run impacted-suites.sh "$(s17_bound 30)" "$d/imp.raw" bash "$anchor/scripts/cr/impacted-suites.sh" "refs/remotes/origin/main..$SHA"; then
        s17_fail "cannot read the impacted list for origin/main..${SHA:0:7}: $s17_why"
        return 0
    fi
    grc=0
    grep -v '^$' "$d/imp.raw" > "$d/imp.nz" 2> /dev/null || grc=$?  # grc 1 is no line, an empty list
    if [ "$grc" -gt 1 ] || ! sort -u "$d/imp.nz" > "$d/imp"; then
        s17_fail "cannot read the impacted list for origin/main..${SHA:0:7}"
        return 0
    fi
    n_imp=$(wc -l < "$d/imp" | tr -d ' ')
    if [ "$n_imp" -eq 0 ]; then
        echo "[PASS] 19. suite evidence: 0 impacted, nothing to prove"
        return 0
    fi

    # local proof: the newest ok `impacted` row at this head and branch
    branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null) || branch=""  # swallow-ok: an empty branch reads no row
    ledger="${common_dir:-}/cr-critic-scores.jsonl"
    : > "$d/lp"
    : > "$d/rs"
    if [ -n "$branch" ] && [ -n "${common_dir:-}" ] && [ -r "$ledger" ]; then
        # item 16's reader: rows of this head, branch and PR, oldest first; the newest ok one is the proof
        o16_branch="$branch"; o16_ledger="$ledger"
        row=$(o16_ledger impacted 'select(.status == "ok") | tojson' | tail -n 1)
    fi
    if [ -n "$row" ]; then
        have_row=1
        printf '%s' "$row" | jq -r '(.local_pass // []) | .[] | strings' 2>/dev/null | sort -u > "$d/lp" || : > "$d/lp"  # swallow-ok: a malformed field is no local proof
        printf '%s' "$row" | jq -r '(.ruled_skip // []) | .[] | strings' 2>/dev/null | sort -u > "$d/rs" || : > "$d/rs"  # swallow-ok: a malformed field is no local proof
    fi
    # `Local suites: <path>` body lines, one path each (the body is item 7's, CR-stripped)
    printf '%s\n' "${cov_body:-}" | sed -e 's/[[:space:]]*$//' | sed -n 's/^Local suites: \(..*\)$/\1/p' | sort -u > "$d/ls"
    while IFS= read -r s; do
        grep -Fxq -- "$s" "$d/imp" || echo "       note: a Local suites line names $s, which is not impacted"
    done < "$d/ls"

    : > "$d/need"
    while IFS= read -r s; do
        if grep -Fxq -- "$s" "$d/ls"; then
            if grep -Fxq -- "$s" "$d/lp"; then n_local=$((n_local + 1)); else reasons="$reasons, $s (Local suites line, no local PASS)"; bad=$((bad + 1)); fi
        elif grep -Fxq -- "$s" "$d/lp"; then
            n_local=$((n_local + 1))
        elif grep -Fxq -- "$s" "$d/rs"; then
            n_ruled=$((n_ruled + 1)); ruled_names="$ruled_names, $s"
        else
            printf '%s\n' "$s" >> "$d/need"
        fi
    done < "$d/imp"

    if [ -s "$d/need" ]; then
        # the latest check-run of the aggregator, check 2's latest rule
        cands=$(printf '%s' "${rollup:-null}" | jq -r --arg n "$S17_AGG" '
            def newest_first: map(.sk = [(.ts == null), (.ts // .i)]) | sort_by(.sk) | reverse;
            [ (if type == "array" then . else [] end) | to_entries[] | .key as $i | .value
              | select(type == "object" and has("conclusion") and (.workflowName // "") == "CI")
              | {i: $i, name: (.name // ""), ts: (.startedAt // .completedAt // null), st: (.status // "?"), c: (.conclusion // "null"),
                 run: ((.detailsUrl // "") | [scan("^https://[^/]+/[^/]+/[^/]+/actions/runs/([0-9]+)/job/[0-9]+$")[0]] | first // "")} ] as $all
            | ($all | map(select(.name == $n)) | newest_first | .[] | "A \(.st)/\(.c) \(.run)"),
              ($all | map(select(.run != "")) | newest_first | map(.run)
               | reduce .[] as $r ([]; if any(.[]; . == $r) then . else . + [$r] end) | .[] | "O \(.)")' 2>/dev/null) || cands="unreadable"  # swallow-ok: an unreadable rollup is no settled CI run
        agg=""; agg_first=""; agg_skipped=" "; agg_others=""
        while IFS= read -r line; do
            case "$line" in
                "O "*) agg_others="$agg_others ${line#O }" ;;
                "A "*)
                    [ -n "$agg_first" ] || agg_first="${line#A }"
                    [ -z "$agg" ] || continue
                    case "${line#A }" in
                        "COMPLETED/CANCELLED "*) agg_skipped="$agg_skipped${line##* } "; continue ;;
                        "COMPLETED/FAILURE "[0-9]*)
                            if s17_run "gh api actions/runs/${line##* }" "$(s17_bound 15)" "$d/rc" "$GH" api "repos/$owner/$repo/actions/runs/${line##* }" --jq .conclusion \
                                && [ "$(tr -d '[:space:]' < "$d/rc")" = cancelled ]; then
                                agg_skipped="$agg_skipped${line##* } "; continue
                            fi ;;
                    esac
                    agg="${line#A }" ;;
            esac
        done <<< "$cands"
        if [ -z "$agg" ] && [ -n "$agg_first" ]; then
            agg_n=0
            for r in $agg_others; do
                case "$agg_skipped" in *" $r "*) continue ;; esac
                agg_n=$((agg_n + 1)); [ "$agg_n" -le 5 ] || break
                if s17_run "gh api actions/runs/$r" "$(s17_bound 15)" "$d/rc" "$GH" api "repos/$owner/$repo/actions/runs/$r" --jq '[.conclusion, .head_sha] | join(" ")' \
                    && [ "$(tr -d '\r' < "$d/rc" | head -n 1)" = "success $SHA" ]; then
                    agg="COMPLETED/SUCCESS $r"; break
                fi
            done
            [ -n "$agg" ] || agg="$agg_first"
        fi
        case "$cands" in unreadable) agg="" ;; *) [ -n "$agg" ] || agg="none" ;; esac
        case "$agg" in
            "COMPLETED/SUCCESS "[0-9]*) run_id="${agg#* }" ;;
            *) s17_why="no settled CI run (latest $S17_AGG: ${agg:-unreadable})" ;;
        esac
        case "$agg" in "COMPLETED/FAILURE "[0-9]*) why="$s17_why"; s17_fl_failures "$d" "${agg#* }"; s17_why="$why" ;; esac
        if [ -n "$run_id" ]; then
            if ! s17_run "gh api actions/runs/$run_id" "$(s17_bound 15)" "$d/hs" "$GH" api "repos/$owner/$repo/actions/runs/$run_id" --jq .head_sha; then
                s17_fail "$s17_why"
                return 0
            fi
            if [ "$(tr -d '[:space:]' < "$d/hs")" != "$SHA" ]; then
                s17_why="no settled CI run (run $run_id is not at ${SHA:0:7})"
                run_id=""
            fi
        fi
        if [ -n "$run_id" ]; then
            mkdir "$d/m" || { s17_fail "mkdir failed"; return 0; }
            # A run whose plan left every shard out uploads no manifest: gh says so and
            # exits 1, and no shell suite is CI-proven. Any other failure is a FAIL.
            if ! s17_run "gh run download $run_id" "$(s17_bound 30)" "$d/dl" "$GH" run download "$run_id" -R "$owner/$repo" -p 'shell-unit-manifest-ubuntu-latest-shard*' -D "$d/m" \
                && ! { case "$s17_why" in *"timed out"*) false ;; esac && grep -qF 'no valid artifacts found' "$d/dl.err"; }; then
                s17_fail "$s17_why"
                return 0
            fi
            find "$d/m" -type f -name 'manifest-shard*.txt' -exec cat {} + 2>/dev/null | tr -d '\r' > "$d/man" || : > "$d/man"  # swallow-ok: no manifest proves nothing
            awk 'index($0, "ran 0 ") == 1 { print substr($0, 7) }' "$d/man" | sort -u > "$d/ran0"
            awk 'index($0, "skip ") == 1 { print substr($0, 6) }' "$d/man" | sort -u > "$d/skip"
        fi
        while IFS= read -r s; do
            if [ -z "$run_id" ]; then
                why="$s17_why"
            elif grep -Fxq -- "$s" "$d/ran0"; then
                n_ci=$((n_ci + 1)); continue
            elif grep -Fxq -- "$s" "$d/skip"; then
                why="CI skipped it"
            else
                why="no ran-0 row in run $run_id"
            fi
            reasons="$reasons, $s ($why)"; bad=$((bad + 1))
        done < "$d/need"
    fi

    if [ "$bad" -gt 0 ]; then
        s17_fail "$bad suite(s) proven nowhere: ${reasons#, }"
        if [ "$have_row" -eq 0 ]; then
            echo "       no impacted row at ${SHA:0:7} on ${branch:-?}: the chief runs pr-check step 3.6 (impacted-suites.sh --check --record) for this head from a worktree of the branch, so the row lands in the shared ledger"
        fi
        return 0
    fi
    echo "[PASS] 19. suite evidence: $n_imp impacted, $n_ci from CI run ${run_id:--}, $n_local local${ruled_names:+, $n_ruled ruled SKIP: ${ruled_names#, }}"
}
check_suite_evidence

# shellcheck disable=SC2016  # python program text
C20_READER='import os, sys
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import conflicts
for path, _prs, _note in conflicts.parse_body(sys.stdin.read()):
    print(path)'
check_conflicts_resolved() {
    local head det out listed rc h7 f prs res mc nums n_conf=0 n_miss=0 adds="" warns=""
    head="$SHA"
    [ "$ONLY7" -eq 0 ] || head="${cov_head:-}"
    if [ -z "$head" ]; then
        echo "[WARN] 20. conflicts unknown (no head)"
        return 0
    fi
    h7="${head:0:7}"
    det="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}/scripts/eval/conflicts/conflicts.py"
    _TIMEOUT_BIN=""
    # shellcheck source=../../lib/timeout-bin.sh
    . "$(cd "$(dirname "$0")/../../lib" && pwd)/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN WARNs just below
    if [ ! -f "$det" ] || [ -z "$_TIMEOUT_BIN" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "[WARN] 20. conflicts unknown (no detector, python3 or timeout binary: $det)"
        return 0
    fi
    if [ "$ONLY7" -eq 0 ] && ! pr_fetch; then
        echo "[WARN] 20. conflicts unknown ($pr_mb_err)"
        return 0
    fi
    rc=0
    out=$("$_TIMEOUT_BIN" -k 5 20 python3 -I "$det" detect --repo-dir "$PWD" --head "$head" --base-ref refs/remotes/origin/main --pr "$PR" 2>/dev/null </dev/null) || rc=$?  # swallow-ok: a non-zero rc WARNs just below
    if [ "$rc" -ne 0 ]; then
        echo "[WARN] 20. conflicts unknown (detector exit $rc)"
        return 0
    fi
    case "$out" in
        unknown*) echo "[WARN] 20. conflicts ${out%%$'\n'*}"; return 0 ;;
        '') echo "[PASS] 20. conflicts resolved: no hand-resolved merge conflict in origin/main..$h7"; return 0 ;;
    esac
    rc=0
    listed=$(printf '%s' "${cov_body:-}" | "$_TIMEOUT_BIN" -k 5 10 python3 -I -c "$C20_READER" "$det" 2>/dev/null) || rc=$?  # swallow-ok: a non-zero rc WARNs just below
    if [ "$rc" -ne 0 ]; then
        echo "[WARN] 20. conflicts unknown (body reader exit $rc)"
        return 0
    fi
    while IFS=$'\t' read -r f prs res mc; do
        [ -n "$f" ] || continue
        n_conf=$((n_conf + 1))
        nums=$(printf '%s\n' "$prs" | grep -oE '[0-9]+' | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g')
        if ! grep -Fxq -- "$f" <<<"$listed"; then
            n_miss=$((n_miss + 1))
            adds="$adds
       - $f vs ${nums:-#<other pr>}: <what you kept and why>"
        fi
        [ "$res" != ours ] || warns="$warns
[WARN] 20. $f was resolved as ours in merge ${mc:0:7}: the change from ${nums:-main} was dropped; check it does not undo ${nums:-that change}"
    done <<EOF
$out
EOF
    if [ "$n_miss" -gt 0 ]; then
        echo "[FAIL] 20. conflicts resolved: $n_miss of $n_conf conflicted file(s) in origin/main..$h7 have no line under ## Conflicts resolved; add to the PR body:"
        echo "       ## Conflicts resolved$adds"
        mark_fail
    else
        echo "[PASS] 20. conflicts resolved: each of $n_conf conflicted file(s) in origin/main..$h7 has its line"
    fi
    [ -z "$warns" ] || printf '%s\n' "${warns#?}"
}
check_conflicts_resolved

if [ "$ONLY7" -eq 1 ]; then
    if [ "$RESULT" -eq 0 ]; then echo "COVERAGE-LINT PASS"; exit 0; fi
    echo "COVERAGE-LINT FAIL"
    exit 1
fi

echo "---"
echo "The three-dot diff read (git diff origin/main...HEAD) stays the chief's own judgement — this script does not read it."
[ -z "$TRUST_PATH" ] || echo "TRUST-PATH: $TRUST_PATH"
if [ "$RESULT" -eq 0 ]; then
    echo "READY-CHECK PASS"
    exit 0
else
    echo "READY-CHECK FAIL"
    exit 1
fi
