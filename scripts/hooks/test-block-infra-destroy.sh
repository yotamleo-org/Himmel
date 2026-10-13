#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-infra-destroy.sh (HIMMEL-5282, gap G9).
#
# Usage: bash scripts/hooks/test-block-infra-destroy.sh
# Exit:  0 all cases passed, 1 at least one failed.
#
# Payloads live in fixtures/infra-destroy/{deny,allow}.tsv (`<id><TAB><command>`,
# a literal `\n` in the command is a newline), never in this file: written
# whole they would make this file hazardous to edit under the live guard.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/block-infra-destroy.sh"
FIX="$DIR/fixtures/infra-destroy"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0
FAILED=0

# run_hook <command> [env-assign...] -> hook exit code (0 when the hook is absent)
run_hook() {
    local cmd="$1" json
    shift
    json=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    if [ ! -f "$HOOK" ]; then echo 0; return; fi
    if [ $# -gt 0 ]; then
        printf '%s' "$json" | env "$@" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        echo "PASS $label (rc=$got)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $label - expected rc=$want, got rc=$got"
        FAILED=$((FAILED + 1))
    fi
}

# An absent hook allows everything (rc 0), which is the defect the DENY rows
# reproduce; the RED run of this suite shows exactly that.
[ -f "$HOOK" ] || echo "NOTE: $HOOK does not exist yet (RED)"

run_fixture() {
    local file="$1" want="$2" id cmd
    if [ ! -r "$file" ]; then
        echo "FAIL fixture $file unreadable"
        FAILED=$((FAILED + 1))
        return
    fi
    while IFS=$'\t' read -r id cmd; do
        [ -n "$id" ] || continue
        cmd=${cmd//\\n/$'\n'}
        assert_rc "$id" "$want" "$(run_hook "$cmd")"
    done <"$file"
}

run_fixture "$FIX/deny.tsv" 2
run_fixture "$FIX/allow.tsv" 0

# Bypass: INFRADESTROYOK=1 in the launching shell lets a deny row through.
first_deny=$(head -n1 "$FIX/deny.tsv" | cut -f2)
assert_rc "bypass INFRADESTROYOK=1" 0 "$(run_hook "$first_deny" INFRADESTROYOK=1)"
assert_rc "bypass INFRADESTROYOK=0 still denies" 2 "$(run_hook "$first_deny" INFRADESTROYOK=0)"

# Non-Bash tool and empty command are out of scope.
if [ -f "$HOOK" ]; then
    rc=0; printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | bash "$HOOK" >/dev/null 2>&1 || rc=$?
else rc=0; fi
assert_rc "non-Bash tool ignored" 0 "$rc"

# A missing verbs table fails closed (security fence).
if [ -f "$HOOK" ]; then
    tmp=$(mktemp -d) || exit 1
    if cp "$HOOK" "$tmp/block-infra-destroy.sh" && mkdir -p "$tmp/lib" && cp "$DIR"/lib/*.sh "$tmp/lib/" && [ -r "$tmp/lib/guard-unwrap.sh" ]; then
        rc=0
        jq -cn --arg c "$first_deny" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$tmp/block-infra-destroy.sh" >/dev/null 2>&1 || rc=$?
    else
        rc=setup-failed
    fi
    rm -rf "$tmp"
else rc=0; fi
assert_rc "missing verbs table fails closed" 2 "$rc"

echo
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
