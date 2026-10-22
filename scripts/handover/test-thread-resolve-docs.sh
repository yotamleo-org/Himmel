#!/usr/bin/env bash
# test-thread-resolve-docs.sh — Pins the review-thread resolve flow in every
# doc a leg or a console reads: one sanctioned resolve path that carries a
# reason, a denied resolve sent to the console as `BLOCKED resolve`, and the
# console verifying and resolving it itself instead of handing it to the
# operator.
#
# The CLI half (refuses without a reason, replies before resolving) is pinned
# by plugins/himmel-gh/tests/thread-mutate-cli.test.mjs; this suite pins the
# prose that routes legs and the console to it. RED first: against the docs
# before the flow existed every assertion below fails, none of them vacuously.
#
# Docs-only reads, no network, no live state. PLATFORM GUARD: no .ps1 twin —
# Bash 3.2, grep/awk/sed/tr only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PLUGIN="${PLUGIN:-$HERE/../../plugins/himmel-gh}"
PREFACE="$DOCS/handover/leg-preface.md"
SHELL_SECTION="$DOCS/handover/leg-sections/shell-and-tests.md"
CONSOLE="$DOCS/handover/console-template.md"
MERGES="$DOCS/handover/console-sections/merges.md"
PLAYBOOK="$DOCS/internals/stuck-playbook.md"
AFK="$DOCS/handover/afk-mode.md"
RESOLVE_CMD="$PLUGIN/commands/gh-pr-resolve.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
flat() { tr '\n' ' ' | tr -s ' '; }
contains() {  # contains <label> <haystack> <needle>  (case-insensitive, fixed, whitespace-flattened)
    if printf '%s\n' "$2" | flat | grep -iF -- "$3" > /dev/null; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
# section <file> <heading-regex> -- the body under a heading, up to the next heading of any level
section() {
    awk -v re="$2" '
        $0 ~ re { f = 1; next }
        f && /^#+ / { exit }
        f { print }
    ' "$1"
}

for f in "$PREFACE" "$SHELL_SECTION" "$CONSOLE" "$MERGES" "$PLAYBOOK" "$AFK" "$RESOLVE_CMD"; do
    [ -r "$f" ] || { printf 'FAIL - unreadable %s\n' "$f"; exit 1; }
done

# --- 1. leg-preface.md: names the path, the BLOCKED shape, the loop rule ----
ship="$(section "$PREFACE" '^## Shipping')"
[ -n "$ship" ] || fail 'leg-preface.md has a "## Shipping" section'
contains 'preface Shipping names the resolve CLI' "$ship" 'thread-resolve-action-cli.mjs'
contains 'preface Shipping says every resolve carries a reason' "$ship" '--reason'
contains 'preface Shipping routes a denied resolve to the console' "$ship" 'BLOCKED resolve <pr> <ids>'
work="$(section "$PREFACE" '^## How you work')"
contains 'preface: a classifier denial on a loop shape is a shape denial' "$work" 'a denied loop is a shape denial'

# --- 2. leg-sections/shell-and-tests.md: the full call --------------------
shell="$(cat "$SHELL_SECTION")"
contains 'shell section spells the full resolve call' "$shell" 'thread-resolve-action-cli.mjs --owner <o> --repo <r> --number <pr> --thread-id'
contains 'shell section lists the followup reason' "$shell" 'followup HIMMEL-<n>'
contains 'shell section lists the rejected reason' "$shell" 'rejected <why>'
contains 'shell section: one literal call per thread' "$shell" 'one literal call per thread, never a loop'
contains 'shell section: the console resolves a denied thread itself' "$shell" 'the console verifies each thread against the head and resolves it itself'

# --- 3. console template + merges section: the console resolves, never the operator
merges_tpl="$(section "$CONSOLE" '^## Merges')"
contains 'console template Merges names BLOCKED resolve' "$merges_tpl" 'BLOCKED resolve'
contains 'console template Merges: never the operator' "$merges_tpl" 'never the operator'
merges="$(cat "$MERGES")"
contains 'merges section: a denied resolve is never an operator item' "$merges" 'never an operator item'
contains 'merges section: verify against the PR head first' "$merges" 'against the PR head'
contains 'merges section: the console runs the same CLI with a reason' "$merges" 'run the same CLI with the matching reason'
contains 'merges section names the ruling it codifies' "$merges" 'N2224'

# --- 4. stuck-playbook + overnight-mode: the carve-out from "defer to the operator"
contains 'stuck-playbook carves review-thread writes out of the operator defer' "$(cat "$PLAYBOOK")" 'review-thread resolve or reply'
contains 'stuck-playbook sends them to the chief' "$(cat "$PLAYBOOK")" 'a review-thread write goes to the chief instead'
contains 'afk-mode step 11: a review-thread resolve is never an operator action' "$(cat "$AFK")" 'review-thread resolve is never an operator action'
contains 'afk-mode external writes: the review-thread exception' "$(cat "$AFK")" 'A review-thread resolve is the exception'

# --- 5. /gh-pr-resolve passes the reason the CLI now requires --------------
# shellcheck disable=SC2016  # the literal "$2" is the needle
contains '/gh-pr-resolve passes --reason' "$(cat "$RESOLVE_CMD")" '--reason "$2"'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-thread-resolve-docs.sh'
    exit 0
fi
printf 'FAIL - test-thread-resolve-docs.sh (%s failure(s))\n' "$fails"
exit 1
