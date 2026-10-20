# shellcheck shell=bash
# Shared setup for scripts/hooks/test-block-destructive-commands-{a,b,c,d}.sh.
# Sourced by each part, never run: the parts are case ranges of one former suite
# and share this runner, the assertion helpers and the case count.
HOOK="$(cd "$(dirname "$0")" && pwd)/block-destructive-commands.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0
CASES=0

# Every case runs through sandbox-run.sh, and bwrap cannot nest, so
# inside an outer sandbox-run.sh each of the cases returns rc 1 and the verdict
# is vacuous. SANDBOX_CANARY is set only by sandbox-run.sh itself; require it AND
# a failing probe, so CI and a normal station (no canary, or a working probe)
# never skip and a broken sandbox-run.sh there still fails every case.
if [ -n "${SANDBOX_CANARY:-}" ] \
   && ! bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- true >/dev/null 2>&1; then
    echo "SKIP block-destructive-commands: running inside a nested sandbox (SANDBOX_CANARY set, sandbox-run.sh cannot nest); every case would return rc 1. Run this suite from outside the sandbox."
    exit 0
fi

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- env "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# finish_suite <part>: print the case count (the parts must sum to the former
# single suite's count) and the verdict.
finish_suite() {
    echo ""
    echo "$1: $CASES cases"
    if [ "$FAILED" -eq 0 ]; then
        echo "All cases passed."
        exit 0
    else
        echo "$FAILED case(s) failed."
        exit 1
    fi
}
