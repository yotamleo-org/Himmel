#!/usr/bin/env bash
# scripts/handover/console-kit/himmel-gate.sh - run a registered gate or ledger
# writer by NAME from the HIMMEL_REPO anchor: the single exec path for them.
#
#   bash "$HIMMEL_REPO/scripts/handover/console-kit/himmel-gate.sh" <name> [args...]
#
# WHY: the rule the guards enforce is "a gate script runs unmodified and its rc
# reaches the caller". That is a property of how the script is executed, so
# this file owns it instead of a text match over every command that mentions a
# gate path: guard-pr-check-literal.sh exempts this exact anchored spelling and
# denies only a direct run of a registered script outside it.
#
# What it checks before the exec, in order (any failure exits 2, nothing runs):
#   - <name> is registered below; an unknown name refuses.
#   - HIMMEL_REPO is set and absolute.
#   - the anchor is on refs/heads/main and its copy of the script, this file
#     and scripts/cr/anchor-handoff.sh equal main's committed bytes and modes
#     (scripts/hooks/lib/anchor-bytes.sh), and so do the files the script
#     runs or sources: all of scripts/cr, scripts/guardrails/lib.sh and
#     scripts/lib/load-dotenv.sh for pr-check-context / pr-check-env, and
#     scripts/lib/go-gate.sh and handover-path.sh for go.
#   - stdout is not a pipe: `| tail` would hide the rc and part of the output.
#     A lone --help / -h is exempt (a read-only usage print).
# Then it execs the anchor's copy with argv from the caller's cwd, so the
# script reviews the caller's tree with the anchor's code and its rc is the
# caller's rc.
#
# A relative entry (`bash scripts/handover/console-kit/himmel-gate.sh`) first
# hands off to the anchor's copy of this file through anchor-handoff.sh, like
# every other gate entry.
#
# Exit codes: the script's own rc; 2 when a check above refuses.
# Bash 3.2-compatible.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2
set -uo pipefail

usage() {
    echo "usage: himmel-gate.sh <name> [args...]" >&2
    echo "names: clear-cr-marker clear-review-marker cr-scores doc-freshness-advisory docs-audit-panel impacted-suites" >&2
    echo "       known-findings ledger-append orphan-check panel-first-pass pr-check-context" >&2
    echo "       pr-check-env review-round write-verdicts merge-on-green go" >&2
}

[ $# -ge 1 ] || { usage; exit 2; }
name=$1
shift
case "$name" in
    clear-cr-marker | clear-review-marker | cr-scores | doc-freshness-advisory | docs-audit-panel | impacted-suites | \
        known-findings | ledger-append | orphan-check | panel-first-pass | pr-check-context | \
        pr-check-env | review-round | write-verdicts) rel="scripts/cr/$name.sh" ;;
    merge-on-green) rel=scripts/handover/merge-on-green.sh ;;
    go) rel=scripts/handover/console-kit/go.sh ;;
    *) echo "himmel-gate: '$name' is not a registered gate" >&2; usage; exit 2 ;;
esac

repo=${HIMMEL_REPO:-}
case "$repo" in
    /*) repo=${repo%/} ;;
    *) echo "himmel-gate: HIMMEL_REPO must be an absolute path to the anchor checkout (got '${repo}')" >&2; exit 2 ;;
esac

lib="$repo/scripts/hooks/lib/anchor-bytes.sh"
gitclean="$repo/scripts/lib/git-clean.sh"
if ! { [ -r "$lib" ] && [ -r "$gitclean" ]; }; then
    echo "himmel-gate: the anchor ($repo) carries no scripts/hooks/lib/anchor-bytes.sh or scripts/lib/git-clean.sh" >&2
    exit 2
fi
# The scrub stays inside the subshell: the gate itself gets the caller's env.
if ! (
    # shellcheck source=/dev/null # the anchor's copies, not this tree's
    . "$gitclean" && git_env_scrub && . "$lib" || exit 1
    # What the gate runs or sources beyond itself, as guard-pr-check-literal.sh
    # holds it: the pr-check pair execs other scripts/cr files and sources
    # lib.sh / load-dotenv.sh; go.sh sources two scripts/lib siblings.
    deps=
    case "$name" in
        pr-check-context | pr-check-env)
            # git-env-ok: git_env_scrub from the anchor's git-clean.sh ran above, in this subshell
            deps=$(git -C "$repo" ls-tree -r --name-only --full-tree refs/heads/main -- scripts/cr) || exit 1
            deps="$deps scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh"
            ;;
        go) deps='scripts/lib/go-gate.sh scripts/lib/handover-path.sh' ;;
    esac
    # shellcheck disable=SC2086 # deps is a space-free path list
    anchor_bytes_match "$repo" "$repo" "$rel" scripts/handover/console-kit/himmel-gate.sh scripts/cr/anchor-handoff.sh $deps
); then
    echo "himmel-gate: the anchor's $rel (or this dispatcher, scripts/cr/anchor-handoff.sh, or a file $rel runs or sources) is not main's committed copy, or $repo is not on main - refusing" >&2
    exit 2
fi

help_only=0
case "$#:${1:-}" in 1:--help | 1:-h) help_only=1 ;; esac
if [ "$help_only" = 0 ] && [ -p /dev/stdout ]; then
    echo "himmel-gate: stdout is a pipe, which hides the gate's rc and part of its output - run it without '| ...' (redirect to a file and read that instead)" >&2
    exit 2
fi

exec "$BASH" "$repo/$rel" "$@"
