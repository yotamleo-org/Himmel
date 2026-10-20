#!/usr/bin/env bash
# Advisory-then-ratchet cyclomatic-complexity gate.
#
# Runs `bunx "oxlint@$OXLINT_VERSION"` (pinned) with
# `-A all -W complexity` (oxlint's eslint(complexity) rule)
# over the surface audited: scripts/lanes scripts/jira/src
# scripts/telegram scripts/luna-vitals scripts/himmel-run, plus the *.mjs/*.js
# files directly under scripts/hooks and scripts/observability. dist/,
# node_modules/ and test fixtures are excluded — they are generated or
# deliberately-shaped inputs, not code this gate is meant to hold a line on.
#
# Ratchet rule: OXLINT_COMPLEXITY_MAX below is 58 — the audited
# MAXIMUM function complexity across that surface as last audited, so
# everything that exists today passes. This only fires on a NEW function
# regressing ABOVE that ceiling; it does not ask anyone to fix what's
# already there. As simplification work lands and lowers real
# complexity, LOWER this number to match the new maximum — never raise it.
# Raising it papers over a regression instead of fixing it; if a change
# genuinely needs a higher ceiling, that is an operator call, not a
# self-service edit.
#
# Runs through `bun x` when only bun is installed.
# `--files PATH...` lints only those changed paths; with
# OXLINT_FAIL_CLOSED=1 (CI) the two fail-open cases below exit 1 instead.
# Fails OPEN (exit 0, loud WARN) when bunx/bun/oxlint is unavailable or errors
# out for a reason unrelated to a lint finding (e.g. no bun installed, no
# network to fetch oxlint) — a lint gate must not brick commits on a box
# that doesn't have bun.
set -uo pipefail

# ---- config -----------------------------------------------------------
OXLINT_COMPLEXITY_MAX="${OXLINT_COMPLEXITY_MAX:-58}"
# Same literal as check-oxlint-hardening.sh's OXLINT_VERSION —
# keep the two pins in lockstep; test-check-oxlint-complexity.sh asserts
# parity so a future bump of one without the other goes red.
OXLINT_VERSION=1.89.0
# -------------------------------------------------------------------------

# ---- changed-files mode ---------------------------------
# `--files PATH...` lints only those repo-relative paths, narrowed to this
# gate's surface and to JS/TS extensions (dist/, node_modules/ and fixtures
# stay excluded), and exits 0 when none is left. No `--files` = the full
# surface, unchanged.
SURFACE_RE='^(scripts/(lanes|jira/src|telegram|luna-vitals|himmel-run)/|scripts/(hooks|observability)/[^/]+\.(mjs|js)$)'
EXCLUDE_RE='(^|/)(dist|node_modules|fixtures|__fixtures__)/'
files_mode=0
only_files=()
if [ "${1:-}" = "--files" ]; then
    files_mode=1
    shift
    for f in "$@"; do
        [[ "$f" =~ $SURFACE_RE ]] || continue
        [[ "$f" =~ $EXCLUDE_RE ]] && continue
        case "$f" in *.js|*.mjs|*.cjs|*.jsx|*.ts|*.mts|*.cts|*.tsx) ;; *) continue ;; esac
        only_files+=("$f")
    done
elif [ $# -gt 0 ]; then
    echo "usage: $(basename "$0") [--files PATH...]" >&2
    exit 2
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root" || exit 1

if [ "$files_mode" = 1 ]; then
    only_existing=()
    for f in ${only_files[@]+"${only_files[@]}"}; do [ -e "$f" ] && only_existing+=("$f"); done
    if [ "${#only_existing[@]}" -eq 0 ]; then
        echo "check-oxlint-complexity: no changed file in this gate's surface — nothing to lint"
        exit 0
    fi
fi

# bunx is bun's alias for `bun x`; some installs (e.g. ~/.bun/bin) ship only
# `bun`, so fall back to it before failing open.
if command -v bunx >/dev/null 2>&1; then
    runner=(bunx)
elif command -v bun >/dev/null 2>&1; then
    runner=(bun x)
else
    echo "WARN check-oxlint-complexity: neither bunx nor bun found on PATH — skipping complexity gate (fail-open)" >&2
    [ "${OXLINT_FAIL_CLOSED:-}" = 1 ] && exit 1
    exit 0
fi

targets="scripts/lanes scripts/jira/src scripts/telegram scripts/luna-vitals scripts/himmel-run"

hook_js=""
for f in scripts/hooks/*.mjs scripts/hooks/*.js scripts/observability/*.mjs scripts/observability/*.js; do
    [ -e "$f" ] && hook_js="$hook_js $f"
done
if [ "$files_mode" = 1 ]; then
    targets=""
    hook_js=""
fi

# shellcheck disable=SC2086 # word-split on purpose: directory/file list
out=$("${runner[@]}" "oxlint@$OXLINT_VERSION" -A all -W complexity \
    --ignore-pattern 'dist/**' \
    --ignore-pattern 'node_modules/**' \
    --ignore-pattern '**/fixtures/**' \
    --ignore-pattern '**/__fixtures__/**' \
    $targets $hook_js ${only_existing[@]+"${only_existing[@]}"} 2>&1)
rc=$?

lint_lines=$(printf '%s' "$out" | grep -E 'complexity of' || true)
if [ $rc -ne 0 ] && [ -z "$lint_lines" ]; then
    # oxlint didn't produce lint findings at all (crashed, couldn't fetch the
    # package, "No files found to lint", etc) — a tooling failure, not a
    # complexity regression. Fail open rather than block every commit.
    echo "WARN check-oxlint-complexity: oxlint did not run cleanly — skipping (fail-open)" >&2
    echo "$out" >&2
    [ "${OXLINT_FAIL_CLOSED:-}" = 1 ] && exit 1
    exit 0
fi

regressions=$(printf '%s\n' "$out" | grep -E 'has a complexity of [0-9]+' | while IFS= read -r line; do
    n=$(printf '%s' "$line" | grep -oE 'complexity of [0-9]+' | grep -oE '[0-9]+')
    if [ -n "$n" ] && [ "$n" -gt "$OXLINT_COMPLEXITY_MAX" ]; then
        printf '%s\n' "$line"
    fi
done)

if [ -n "$regressions" ]; then
    echo "check-oxlint-complexity: function(s) exceed the configured complexity ratchet (max $OXLINT_COMPLEXITY_MAX):" >&2
    printf '%s\n' "$regressions" >&2
    echo "" >&2
    echo "Simplify the function(s) above. If OXLINT_COMPLEXITY_MAX genuinely needs to rise, that's an operator call — lower it as cleanups land, never raise it unilaterally." >&2
    exit 1
fi

exit 0
