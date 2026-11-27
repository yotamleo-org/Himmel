#!/usr/bin/env bash
# Schema test for scripts/harnesses/*.json, run through the loader the guards use.
# shellcheck disable=SC2016,SC2034 # check() evals single-quoted conditions that read the variables
# shellcheck disable=SC2088 # token paths are literal ~/ globs, as the descriptors spell them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-registry.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

FAIL=0; N=0
check() {
    N=$((N + 1))
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=$((FAIL + 1)); fi
}

load() {
    local f a=()
    for f in "$1"/*.json; do a+=(--rawfile "${f##*/}" "$f"); done
    jq -nc "${a[@]}" --arg out registry -f "$HERE/registry.jq" 2>"$TMP/load.err"
}

egress_check() {
    local reg
    reg="$(load "$1")" || return 1
    jq -rn --argjson reg "$reg" --slurpfile m "$REPO/scripts/guardrails/egress-matrix.json" '
        $reg[] | select(.complete) | select((.egress_provider as $p | $p != null and ($m[0].providers | has($p))) | not) | .id'
}

fresh() {
    mkdir -p "$TMP/$1"
    cp "$HERE"/*.json "$TMP/$1/"
}

REG="$(load "$HERE")" || REG='[]'
q() { jq -e "$1" <<<"$REG" >/dev/null 2>&1; }
check "the shipped registry loads" '[ "$REG" != "[]" ]'
check "the schema lists the five harnesses" \
    '[ "$(jq -r ".\"x-listed-harnesses\" | sort | join(\" \")" "$HERE/harness.schema.json")" = "antigravity claude codex cursor grok" ]'
check "claude, codex and antigravity are launchable with a pending quota source" \
    'q "[.[] | select(.launchable and .quota_source == \"pending\") | .id] | sort == [\"antigravity\",\"claude\",\"codex\"]"'
check "grok and cursor ship incomplete" \
    'q "[.[] | select(.launchable | not) | .id] | sort == [\"cursor\",\"grok\"]"'
check "every complete descriptor names an egress matrix row" 'out="$(egress_check "$HERE")" && [ -z "$out" ]'
check "every schema-required field is present in every shipped descriptor" \
    'jq -e --argjson reg "$REG" ".required as \$r | all(\$reg[]; . as \$d | all(\$r[]; . as \$k | \$d | has(\$k)))" "$HERE/harness.schema.json" >/dev/null'
for id in $(jq -r '.[] | select(.launchable) | .id' <<<"$REG"); do
    for f in hook_config adapter; do
        p="$(jq -r --arg i "$id" --arg f "$f" '.[] | select(.id == $i) | .[$f]' <<<"$REG")"
        check "$id: its $f exists in the repo" '[ -n "$p" ] && [ -e "$REPO/$p" ]'
    done
done

TABLE="$REPO/scripts/hooks/lib/harness-tool-map.json"
check "grok and cursor tool maps equal the adapter's tool-name table" \
    'jq -e --slurpfile t "$TABLE" "[.[] | select(.id == \"grok\" or .id == \"cursor\") | .tool_map.tools | to_entries[] | select(.key != .value.claude)] | from_entries == \$t[0].tools" <<<"$REG" >/dev/null'
for p in '~/.codex/auth.json' '~/.gemini/oauth_creds.json' '~/.gemini/gemini-credentials.json' '~/.gemini/mcp-oauth-tokens*.json' \
         '~/.grok/auth.json' '~/.himmel/profiles/grok/*/auth.json' '~/.cursor/auth.json'; do
    check "the registry names the token path $p" 'jq -e --arg p "$p" "any(.[].token_paths[]; . == \$p)" <<<"$REG" >/dev/null'
done

fresh complete; cp "$HERE/fixtures/fake-harness-complete.json" "$TMP/complete/fake-harness.json"
fresh incomplete; cp "$HERE/fixtures/fake-harness-incomplete.json" "$TMP/incomplete/fake-harness.json"
C="$(load "$TMP/complete")" || C='[]'
I="$(load "$TMP/incomplete")" || I='[]'
check "a complete fake harness is launchable" 'jq -e "any(.[]; .id == \"fake-harness\" and .launchable)" <<<"$C" >/dev/null'
check "an incomplete fake harness is not launchable but supplies its tool map" \
    'jq -e "any(.[]; .id == \"fake-harness\" and (.launchable | not) and .tool_map.tools.fake_shell.claude == \"Bash\")" <<<"$I" >/dev/null'
jq '.lane = null' "$HERE/fixtures/fake-harness-complete.json" > "$TMP/complete/fake-harness.json"
C="$(load "$TMP/complete")" || C='[]'
check "complete:true with a null lane is not launchable" 'jq -e "any(.[]; .id == \"fake-harness\" and (.launchable | not))" <<<"$C" >/dev/null'

jq '.event_map = {"PostToolUse": "after"}' "$HERE/fixtures/fake-harness-complete.json" > "$TMP/complete/fake-harness.json"
C="$(load "$TMP/complete")" || C='[]'
check "complete:true with no PreToolUse event is not launchable" 'jq -e "any(.[]; .id == \"fake-harness\" and (.launchable | not))" <<<"$C" >/dev/null'

jq '.egress_provider = "no-such-provider"' "$HERE/fixtures/fake-harness-complete.json" > "$TMP/complete/fake-harness.json"
check "a complete descriptor with no egress matrix row fails the check" '[ "$(egress_check "$TMP/complete")" = fake-harness ]'
jq '.egress_provider = "no-such-provider" | .complete = false' "$HERE/fixtures/fake-harness-complete.json" > "$TMP/complete/fake-harness.json"
check "the same descriptor marked incomplete passes the check" 'load "$TMP/complete" >/dev/null && [ -z "$(egress_check "$TMP/complete")" ]'

broken() {
    fresh "$1"
    ( cd "$TMP/$1" && eval "$4" )
    N=$((N + 1))
    if load "$TMP/$1" >/dev/null; then echo "FAIL $2: loaded"; FAIL=$((FAIL + 1))
    elif ! grep -qF -- "$3" "$TMP/load.err"; then echo "FAIL $2: $(cat "$TMP/load.err")"; FAIL=$((FAIL + 1))
    else echo "ok   $2"; fi
}
broken b1 "a truncated descriptor" "codex.json is not one JSON document" 'printf "{\"id\":" > codex.json'
broken b2 "a missing listed descriptor" "no descriptor for the listed harness grok" 'rm grok.json'
broken b3 "an empty descriptor file" "codex.json is not one JSON document" ': > codex.json'
broken b4 "a two-document descriptor" "codex.json is not one JSON document" 'cp codex.json x && cat x >> codex.json'
broken b5 "a descriptor with no tool map" "codex.json is malformed" 'jq "del(.tool_map)" codex.json > x && mv x codex.json'
broken b6 "an id that does not match the file name" "codex.json is malformed" 'jq ".id = \"other\"" codex.json > x && mv x codex.json'
broken b7 "a relative token path" "codex.json is malformed" 'jq ".token_paths = [\"auth.json\"]" codex.json > x && mv x codex.json'
broken b8 "two descriptors for one driver" "two descriptors name the same T3 driver" 'jq ".id = \"extra\"" codex.json > extra.json'
broken b9 "a schema with no harness list" "names no harness list" 'jq "del(.\"x-listed-harnesses\")" harness.schema.json > x && mv x harness.schema.json'
broken b10 "a missing schema" "names no harness list" 'rm harness.schema.json'

broken b11 "an incomplete descriptor with a numeric adapter" "grok.json is malformed" 'jq ".adapter = 7" grok.json > x && mv x grok.json'
broken b12 "a numeric mcp_prefix" "codex.json is malformed" 'jq ".tool_map.mcp_prefix = 7" codex.json > x && mv x codex.json'
broken b13 "an event map that is not strings" "codex.json is malformed" 'jq ".event_map = [\"PreToolUse\"]" codex.json > x && mv x codex.json'

printf '\n%d cases, %d failed\n' "$N" "$FAIL"
[ "$FAIL" -eq 0 ]
