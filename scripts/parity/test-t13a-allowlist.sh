#!/usr/bin/env bash
# Control for T13(a) of scripts/parity/test-ws5-invariants.sh.
#
# T13(a) refuses a new SessionStart/PreToolUse registration in any hooks.json
# or .claude/settings.json. The vendored i-have-adhd plugin's
# hooks.json registers one flag-gated SessionStart hook. The ruling is an
# explicit allowlist of (path, event) pairs, NOT a VENDORED.md exemption: a
# vendored PreToolUse hook, or a vendored SessionStart hook at an unlisted
# path, must still trip the gate.
#
# End-to-end against real fixture repos (same shape as test-t13b-relocation.sh):
#   1. the listed path adds SessionStart                       -> PASS
#   2. the listed path adds SessionStart AND PreToolUse        -> FAIL (event not listed)
#   3. an unlisted hooks.json beside a VENDORED.md, SessionStart -> FAIL (path not listed)
#
# Assertions use `case` glob matching, not `printf | grep -q`.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + shell against a temp repo; no .ps1 twin needed -- the only
# consumer is this shell test suite, which is itself gitbash-only.
#
# Usage: bash scripts/parity/test-t13a-allowlist.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/t13a-allow.XXXXXX")" || { echo "FAIL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

SESSION='{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"x"}]}]}}'
BOTH='{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"x"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"y"}]}]}}'

# run_case <name> <expect PASS|FAIL> <hooks.json path> <hooks.json body>
run_case() {
    local name="$1" expect="$2" hpath="$3" body="$4"
    local dir="$TMP_ROOT/$name"
    mkdir -p "$dir/scripts/parity" "$dir/scripts/lib" "$dir/docs/internals" "$dir/src"
    cp "$REPO/scripts/parity/test-ws5-invariants.sh" "$REPO/scripts/parity/t12-no-bloat-lib.sh" "$dir/scripts/parity/"
    printf '| gemini | deferred |\n' > "$dir/docs/internals/lane-parity.md"
    printf '# fixture\n' > "$dir/CLAUDE.md"
    printf 'export const x = 1;\n' > "$dir/src/a.ts"
    local g=(git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
    "${g[@]}" init -q -b main >/dev/null 2>&1 || { fail "$name: fixture git init failed"; return; }
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m base >/dev/null 2>&1 || { fail "$name: fixture base commit failed"; return; }
    "${g[@]}" checkout -q -b feat >/dev/null 2>&1
    mkdir -p "$dir/$(dirname "$hpath")"
    printf '%s\n' "$body" > "$dir/$hpath"
    printf '# vendored\n' > "$dir/$(dirname "$hpath")/VENDORED.md"
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m feat >/dev/null 2>&1 || { fail "$name: fixture feat commit failed"; return; }

    local out rc
    out="$(bash "$dir/scripts/parity/test-ws5-invariants.sh" --base main 2>&1)"; rc=$?
    local ok=0
    if [ "$expect" = "PASS" ]; then
        case "$out" in *"PASS T13 no-always-on"*) [ "$rc" -eq 0 ] && ok=1 ;; esac
    else
        case "$out" in *"FAIL T13(a)"*) [ "$rc" -eq 1 ] && ok=1 ;; esac
    fi
    if [ "$ok" -eq 1 ]; then
        pass "$name -> $expect (rc=$rc)"
    else
        fail "$name -> expected $expect, got rc=$rc: $(printf '%s' "$out" | grep -E 'T13|FAIL' | tr '\n' '|')"
    fi
}

echo "== T13(a): the one allowlisted (path, event) pair =="
run_case listed-session-start PASS marketplace/plugins/i-have-adhd/hooks/hooks.json "$SESSION"

echo "== T13(a): anything else still FAILS =="
run_case listed-path-extra-event FAIL marketplace/plugins/i-have-adhd/hooks/hooks.json "$BOTH"
run_case unlisted-vendored-path FAIL marketplace/plugins/other-vendored/hooks/hooks.json "$SESSION"

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
echo "PASS: T13(a) allowlist control (3 cases)"
exit 0
