#!/usr/bin/env bash
# scripts/cr/docs-audit-panel.sh - the /pr-check docs-audit lane's cross-model
# critic path, extracted verbatim out of the step-2.5 fence in
# .claude/commands/pr-check.md.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE FENCE: the interactive /pr-check
# runbook is prose with ```bash fences that the orchestrating Claude session
# runs verbatim through the Bash tool. Claude Code's worktree-isolation guard
# (check-worktree-isolation.sh) statically screens every bash command run in a
# worktree-isolated session and refuses several shapes the old inline fence
# depended on: any "${CLAUDE_PROJECT_DIR:?}" reference (CLAUDE_PROJECT_DIR is
# genuinely UNSET in Bash-tool shells), any unresolvable env var, a runtime
# value passed as a dash-flag operand, and ${var} braced expansion. Shipping
# the fence as a real script file removes the parse surface entirely: only the
# runbook's own command LINE is screened, never a script's contents.
#
# BEHAVIOUR: byte-equivalent to the fence it replaces (same message text on
# the same streams, same exit codes) with two unavoidable differences, both
# required because a script cannot inherit shell state the way an inline
# fence in the same session can:
#   1. The fence consumed step-1's captured $head/$branch (this
#      lane must review the SHA the ledger will certify, never live HEAD).
#      A script cannot inherit those, so they arrive as REQUIRED --head/
#      --branch flags instead of being re-derived (re-deriving them would be
#      exactly that drift).
#   2. The fence left docs_audit_panel_avail_lines / docs_audit_panel_findings
#      as session-local shell variables for later runbook steps to read. A
#      script cannot leak variables into its caller's shell, so findings go to
#      stdout and the critic-panel.sh panel-availability lines go to stderr -
#      the exact split the fence already produced on those two streams, just
#      captured by the caller (redirection/capture) instead of by variable.
#
# Usage: docs-audit-panel.sh --head <sha> --branch <name>
#
# Arguments (both REQUIRED; missing either is a usage error, exit 2):
#   --head <sha>      the SHA step 1 of /pr-check captured.
#   --branch <name>   the branch name step 1 captured.
#
# Env:
#   CR_PROFILE - "none" disables the panel (same precedence as step 3.0 - an
#                explicit claude-only opt-out wins). Otherwise the critic runs
#                whatever CR_REQUIRE_CROSS_MODEL says: ready-check
#                item 4 and the merge gate's hard reviewer need its row at the
#                head, and the inline audit's `avail claude` row cannot be it.
#                With CR_PROFILE=none and the policy off, the marker clears and
#                the merge gate passes, but item 4 still fails that head.
#
# stdout/stderr contract (do not merge these streams):
#   stdout - ONLY the panel's findings text (docs_audit_panel_findings in the
#            old fence), when non-empty. Nothing else is ever written to
#            stdout.
#   stderr - every advisory/diagnostic line the fence printed (claude-only
#            note, empty-diff skip, git-diff-failed note, all-critics-failed
#            note), the ABORT heredocs on exit 7, and critic-panel.sh's own
#            "panel-availability: ..." lines (captured from the panel's
#            stderr and re-emitted here so step 4.5 can still record them).
#
# Exit codes:
#   0 - lane completed (including the CR_PROFILE=none / empty-diff /
#       fail-open-degrade cases - none of those are aborts).
#   2 - usage error: --head or --branch missing.
#   7 - ABORT, never a degrade. The --head given here names no commit in this
#       repo (checked before any git command consumes it); origin/<base> could
#       not be fetched, or the base names no commit; critic-panel.sh's
#       --head/--branch/--base-sha pin mismatch, on the first attempt OR the
#       rtk retry; or a panel exit 6 whose refusal could not be recorded.
#   96 - a chokepoint seam differs from the session's launch env.
#
# bash 3.2-safe (Git Bash on Windows and Linux).
set -uo pipefail
# a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced or run.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "docs-audit-panel.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/cr/docs-audit-panel.sh || exit 96

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: docs-audit-panel.sh --head <sha> --branch <name>

Runs the /pr-check docs-audit lane's cross-model critic path over the given
head SHA and branch name, unless CR_PROFILE=none. --head and --branch are the
values step 1 of /pr-check captured; this script never re-derives them.
EOF
}

HEAD_ARG=""
BRANCH_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head)   [ $# -ge 2 ] || { echo "docs-audit-panel: --head needs an argument" >&2; exit 2; }; HEAD_ARG="$2"; shift 2 ;;
        --branch) [ $# -ge 2 ] || { echo "docs-audit-panel: --branch needs an argument" >&2; exit 2; }; BRANCH_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "docs-audit-panel: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "$HEAD_ARG" ] || { echo "docs-audit-panel: --head is required" >&2; usage >&2; exit 2; }
[ -n "$BRANCH_ARG" ] || { echo "docs-audit-panel: --branch is required" >&2; usage >&2; exit 2; }
head="$HEAD_ARG"
branch="$BRANCH_ARG"

# CR_PROFILE is behaviour config, so load_dotenv keeps it, process env first,
# same as the full lane's CR_PROFILE bridge.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
export CR_PROFILE

# $head and $branch are the values STEP 1 captured - this fence runs
# independently (see step 3.0's identical note): substitute those literals
# here, never re-derive them in this fence.
# Validate the INPUT PIN first. `git rev-parse` WITHOUT
# --verify happily echoes a well-formed 40-hex string back that names no
# object, so the bare call below cannot tell a real pin from a hand-expanded
# short hash; the bad value then reaches `git diff`, which fails rc=128, and
# the lane reports "cross-model critic unavailable" - a caller error wearing
# a reviewer outage's clothes, at exit 0. Same class as the panel's own pin
# mismatch, so the same exit: 7, ABORT.
if ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
    echo "docs-audit-panel ABORT - --head $head does not resolve to a commit in this repo. This is an input-pin failure, NOT a critic outage: nothing was reviewed and nothing was recorded. Re-check the SHA step 0 printed and re-run /pr-check from step 1." >&2
    exit 7
fi
docs_audit_head=$(git rev-parse "$head")
docs_audit_panel_avail_lines=""
docs_audit_panel_findings=""
# Fail-open degrade: no temp file means no panel run, so nothing was reviewed.
no_panel_tmp() {
    [ -z "$docs_audit_panel_avail_lines" ] || printf '%s\n' "$docs_audit_panel_avail_lines" >&2
    echo "docs-audit cross-model critic unavailable (mktemp failed - check free space in TMPDIR) - ready-check item 4 and the merge gate hold this head until a re-run records avail ok" >&2
    exit 0
}
if [ "${CR_PROFILE:-}" = "none" ]; then
    # Same precedence as step 3.0: an explicit claude-only opt-out wins
    # even under CR_REQUIRE_CROSS_MODEL. The marker stays closed under
    # the cross-model floor until CR_PROFILE is unset (the two settings
    # are genuinely contradictory; we do not spend the paid critic to
    # satisfy one at the expense of the other). With the policy off the marker
    # clears, yet item 4 still wants a non-Claude row, so say both.
    echo "docs-audit: claude-only (CR_PROFILE=none) - cross-model critic not launched; marker stays closed under CR_REQUIRE_CROSS_MODEL until a non-Claude responder exists or CR_PROFILE is unset; with the policy off the marker clears and the merge gate passes, but ready-check item 4 still fails with no non-Claude row at the head" >&2
else
    # shellcheck source=scripts/cr/base-resolver.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT/scripts/cr/base-resolver.sh"
    # shellcheck disable=SC1091
    db=$(. "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null && default_branch || echo main) # swallow-ok: main is the documented default
    # Fetch once, then pin through the origin-first resolver critic-panel.sh
    # verifies with. A repo with an origin must not certify a stale cached ref
    # when the refresh failed; one with no origin falls back to its local branch.
    review_root=$(git rev-parse --show-toplevel 2>/dev/null) || review_root="" # swallow-ok: the empty value aborts just below
    if [ -z "$review_root" ] || ! cr_fetch_base "$review_root" "$db"; then
        echo "docs-audit-panel ABORT - could not fetch origin/$db, so the current diff base cannot be pinned safely. Nothing was reviewed and nothing was recorded. Re-run /pr-check from step 1." >&2
        exit 7
    fi
    base_ref=$(cr_resolve_base_ref "$review_root" "$db")
    db_sha=$(git -C "$review_root" rev-parse --verify --quiet "$base_ref^{commit}" 2>/dev/null) || db_sha="" # swallow-ok: the empty value aborts just below
    if [ -z "$db_sha" ]; then
        echo "docs-audit-panel ABORT - diff base $base_ref does not resolve to a commit. Nothing was reviewed and nothing was recorded. Re-run /pr-check from step 1." >&2
        exit 7
    fi
    diff_rc=0
    diff_out=$(git diff "$db_sha...$docs_audit_head") || diff_rc=$?
    if [ "$diff_rc" -ne 0 ]; then
        echo "docs-audit cross-model critic unavailable - git diff failed rc=$diff_rc: $diff_out" >&2
        echo "docs-audit: no critic ok row from this run - ready-check item 4 and the merge gate hold this head until a re-run records avail ok" >&2
    elif [ -z "$diff_out" ]; then
        echo "docs-audit cross-model critic skipped: empty diff (marker will stay closed under CR_REQUIRE_CROSS_MODEL unless another non-Claude avail-ok row exists; ready-check item 4 fails this head on the same condition)" >&2
    else
        panel_tmp=$(mktemp -t cr-docs-audit-panel-avail.XXXXXX) || no_panel_tmp
        docs_audit_panel_findings=$(printf '%s' "$diff_out" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$docs_audit_head" --branch "$branch" --base "$db" --base-sha "$db_sha" 2>"$panel_tmp")
        panel_rc=$?
        docs_audit_panel_avail_lines=$(cat "$panel_tmp"); rm -f "$panel_tmp"
        if [ "$panel_rc" -eq 7 ]; then
            cat >&2 <<'PINABORT'
/pr-check ABORT - docs-audit critic-panel.sh exit 7: the checkout or the diff
base moved since step 1, so the review inputs no longer match the branch/SHA/base
the ledger would stamp. Nothing was reviewed and
nothing was recorded. Re-run /pr-check from step 1.
PINABORT
            exit 7
        fi
        if [ "$panel_rc" -eq 1 ] && command -v rtk >/dev/null 2>&1; then
            retry_diff=$(rtk proxy git diff "$db_sha...$docs_audit_head" 2>/dev/null) || retry_diff="" # swallow-ok: an empty retry diff skips the retry
            if [ -n "$retry_diff" ]; then
                retry_tmp=$(mktemp -t cr-docs-audit-panel-avail.XXXXXX) || no_panel_tmp
                docs_audit_panel_findings=$(printf '%s' "$retry_diff" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$docs_audit_head" --branch "$branch" --base "$db" --base-sha "$db_sha" 2>"$retry_tmp")
                panel_rc=$?
                docs_audit_panel_avail_lines=$(cat "$retry_tmp"); rm -f "$retry_tmp"
                if [ "$panel_rc" -eq 7 ]; then
                    cat >&2 <<'PINABORTRETRY'
/pr-check ABORT - docs-audit critic-panel.sh exit 7 on the rtk retry: the
checkout or diff base moved mid-run, so the review inputs no longer match the
branch/SHA/base the ledger would stamp. Nothing was reviewed. Re-run /pr-check
from step 1.
PINABORTRETRY
                    exit 7
                fi
            fi
        fi
        if [ "$panel_rc" -ne 0 ]; then
            if [ "$panel_rc" -eq 6 ]; then
                # exit 6 is the panel's deliberate certify
                # refusal, recorded on the ledger; not a
                # failed panel. If that write failed there is nothing to
                # hold the marker, so abort instead.
                case "$docs_audit_panel_avail_lines" in
                *"could not record certify-refused"*)
                    echo "/pr-check ABORT - docs-audit critic-panel.sh exit 6 and the refusal could not be recorded on the CR ledger, so nothing would hold the CR marker closed. Fix the ledger path and re-run /pr-check from step 1." >&2
                    exit 7
                    ;;
                esac
                echo "docs-audit critic panel REFUSED to certify this run (exit 6: the citation-guard digest could not be computed - fix sha256sum/shasum); the CR marker stays held at this SHA until the panel is re-run on a new HEAD" >&2
            elif [ "$panel_rc" -eq 5 ]; then
                echo "docs-audit critic panel could not record its result on the CR ledger (exit 5: CR-ledger append failed); this run is not certified, so re-run the panel once the ledger path is fixed" >&2
            elif [ "$panel_rc" -eq 2 ]; then
                # exit 2 is a usage error or a mktemp failure, not a
                # failed critic: name the cause the panel printed.
                case "$docs_audit_panel_avail_lines" in
                *"mktemp failed"*)
                    echo "docs-audit cross-model critic unavailable (exit 2: critic-panel: mktemp failed - check free space in TMPDIR) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" >&2
                    ;;
                *)
                    echo "docs-audit cross-model critic unavailable (exit 2: usage error: ${docs_audit_panel_avail_lines%%$'\n'*}) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" >&2
                    ;;
                esac
            else
                echo "docs-audit cross-model critic unavailable (all critics failed) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" >&2
            fi
            echo "docs-audit: no critic ok row from this run - ready-check item 4 and the merge gate hold this head until a re-run records avail ok" >&2
            docs_audit_panel_findings=""
        fi
    fi
    # critic-panel.sh's own "panel-availability: ..." lines were captured
    # off its stderr above (docs_audit_panel_avail_lines); re-emit them to
    # OUR stderr now so a caller capturing this script's stderr (step 4.5
    # in the old fence, a test fixture here) still sees them - the fence
    # left them in a variable for the same session to read later; a
    # script has no variable to leave them in, so stderr is the channel.
    [ -n "$docs_audit_panel_avail_lines" ] && printf '%s\n' "$docs_audit_panel_avail_lines" >&2
    [ -n "$docs_audit_panel_findings" ] && printf '%s\n' "$docs_audit_panel_findings"
fi

# The fence above ends with `[ -n "$docs_audit_panel_findings" ] && printf ...`,
# whose own exit status (1 when there are no findings) would otherwise become
# THIS script's exit status. The inline fence never cared because later
# runbook steps ran after it regardless; a standalone script must not report
# an empty-findings SUCCESS path as a failure, so pin the exit code
# explicitly for every non-abort path.
exit 0
