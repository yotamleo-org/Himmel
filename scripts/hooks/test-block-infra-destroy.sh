#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-infra-destroy.sh (gap G9).
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
    local cmd="$1" json tool="${HOOK_TOOL:-Bash}"
    shift
    json=$(jq -cn --arg c "$cmd" --arg t "$tool" '{tool_name:$t,tool_input:{command:$c}}')
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
# The PowerShell scan has no command-word positions, so a verb named as text
# still denies (accepted over-deny). These rows pin it.
HOOK_TOOL=PowerShell run_fixture "$FIX/deny-powershell.tsv" 2

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

# A malformed pattern in the verbs table refuses with exit 2 (it used to read as
# no-match and silently disable the rule), whatever the command is.
if [ -f "$HOOK" ]; then
    tmp=$(mktemp -d) || exit 1
    if cp "$HOOK" "$tmp/block-infra-destroy.sh" && mkdir -p "$tmp/lib" && cp "$DIR"/lib/*.sh "$tmp/lib/" && [ -r "$tmp/lib/guard-unwrap.sh" ]; then
        for bad in 'argv_any|["^(destroy"]' 'argv_all|["^apply$","[unclosed"]' 'text_any|["drop(["]'; do
            jq -n --arg f "${bad%%|*}" --argjson v "${bad#*|}" \
                '{runners:[],rules:[{id:"bad-rule",bins:["terraform"],note:"n"}|.[$f]=$v]}' >"$tmp/infra-destroy-verbs.json"
            rc=0
            jq -cn '{tool_name:"Bash",tool_input:{command:"ls"}}' | bash "$tmp/block-infra-destroy.sh" >/dev/null 2>&1 || rc=$?
            assert_rc "malformed table (${bad%%|*}) fails closed" 2 "$rc"
        done
    else
        assert_rc "malformed table setup" 0 setup-failed
    fi
    rm -rf "$tmp"
fi

# jq missing from PATH fails closed.
if [ -f "$HOOK" ]; then
    rc=0
    jq -cn --arg c "$first_deny" '{tool_name:"Bash",tool_input:{command:$c}}' | env PATH=/nonexistent "$BASH" "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_rc "jq missing fails closed" 2 "$rc"
fi

# A command over 8 KiB takes the flat scan: it must finish well inside the 15 s
# hook timeout, still deny a verb at the tail, and deny (not crawl) past the cap
# on command words it would have to scan.
long=$(awk 'BEGIN { for (i = 0; i < 1500; i++) printf "word%d ", i }')
huge=$(awk 'BEGIN { for (i = 0; i < 6000; i++) printf "terraform plan x%d ", i }')
opts=$(awk 'BEGIN { for (i = 0; i < 256; i++) printf "--request-timeout=1s " }')
t0=$SECONDS
assert_rc "long input allowed" 0 "$(run_hook "echo $long")"
assert_rc "long input denies a verb at the tail" 2 "$(run_hook "echo $long; terraform destroy")"
assert_rc "command word with too many words after it denies" 2 "$(run_hook "echo $huge")"
assert_rc "verb past the span window denies (flat scan)" 2 "$(HOOK_TOOL=PowerShell run_hook "kubectl $opts delete pod web-1")"
edge=$(awk 'BEGIN { for (i = 0; i < 254; i++) printf "x%d ", i; printf "x254" }')
assert_rc "exactly 256 words after a command word allowed (flat scan)" 0 "$(HOOK_TOOL=PowerShell run_hook "kubectl get $edge")"
elapsed=$((SECONDS - t0))
if [ "$elapsed" -le 12 ]; then
    assert_rc "long input within budget (${elapsed}s)" 0 0
else
    assert_rc "long input within budget (${elapsed}s)" 0 1
fi

echo
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
