#!/usr/bin/env bash
# Suite for block-token-shaped-web-query.sh. Every row feeds a JSON payload to the hook through the
# installed hooks.json command; no real token and no network call. Token-shaped strings are built here
# at run time from pieces, never written as one literal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PLUGIN_DIR/../../.." && pwd)"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/block-token-web.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

matcher=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("block-token-shaped-web-query.sh"))) | .matcher' "$PLUGIN_DIR/hooks/hooks.json")
plugin_cmd=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("block-token-shaped-web-query.sh"))) | .hooks[].command' "$PLUGIN_DIR/hooks/hooks.json")

b62="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
crc6() {
    local body="$1" c=4294967295 i j b sum=""
    for ((i = 0; i < 30; i++)); do
        printf -v b '%d' "'${body:i:1}"
        c=$((c ^ b))
        for ((j = 0; j < 8; j++)); do
            if ((c & 1)); then c=$(((c >> 1) ^ 3988292384)); else c=$((c >> 1)); fi
        done
    done
    c=$((c ^ 4294967295))
    for ((i = 0; i < 6; i++)); do
        sum="${b62:c%62:1}$sum"
        c=$((c / 62))
    done
    printf '%s' "$sum"
}

body30="aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vWx"
good_sum=$(crc6 "$body30")
bad_sum="000000"
[ "$good_sum" != "$bad_sum" ] || bad_sum="111111"

gh_token() { printf 'gh%s_%s%s' "$1" "$body30" "$2"; }
pat_body="Zq7Xw3Er9Ty1Ui5Op2As4Df6Gh8Jk0Lm_Nb3Vc5Xz7Qw9Ee1Rr3Tt5Yy7Uu9Ii1Oo3Pp5Aa7Ss9Dd1Ff3Gg5Hh7Jj9Kk"
pat_token() { printf 'github%s%s' "_pat_" "${pat_body:0:82}"; }

run_case() {
    OUT=$(printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="${PROJ:-$REPO}" \
        WEB_TOKEN_QUERY_OK=0 ${2:+"$2"} \
        sh -c "${plugin_cmd:-exit 0}" 2>"$TMP/stderr.txt")
    RC=$?
    ERR=$(cat "$TMP/stderr.txt")
}

assert_eq() {
    if [ "$3" = "$2" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1 - expected $2, got $3"; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - did not contain: $2"; echo "  got: $3"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_lacks() {
    case "$3" in
        *"$2"*) echo "FAIL $1 - leaked the token body"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $1" ;;
    esac
}
allowed() { assert_eq "$1: exit 0" 0 "$RC"; if [ -z "$ERR$OUT" ]; then echo "PASS $1: no text on either stream"; else echo "FAIL $1: expected no text, got: $ERR$OUT"; FAILED=$((FAILED + 1)); fi; }
refused() { assert_eq "$1: refused (exit 2)" 2 "$RC"; assert_contains "$1: names the bypass" "WEB_TOKEN_QUERY_OK=1" "$ERR"; assert_eq "$1: nothing on stdout" "" "$OUT"; }

search_payload() { jq -n --arg q "$1" '{session_id:"s-web",hook_event_name:"PreToolUse",cwd:"/",tool_name:"WebSearch",tool_input:{query:$q}}'; }
fetch_payload() { jq -n --arg u "$1" '{session_id:"s-web",hook_event_name:"PreToolUse",cwd:"/",tool_name:"WebFetch",tool_input:{url:$u,prompt:"summarize"}}'; }

assert_eq "wired: one PreToolUse command" 1 "$(printf '%s' "$plugin_cmd" | grep -c block-token-shaped-web-query.sh)"
for t in WebSearch WebFetch; do
    if grep -Eq "^(${matcher})\$" <<<"$t"; then echo "PASS matcher covers $t"; else echo "FAIL matcher covers $t"; FAILED=$((FAILED + 1)); fi
done
for t in Bash Read mcp__t3-code__t3_thread_send; do
    if grep -Eq "^(${matcher})\$" <<<"$t"; then echo "FAIL matcher leaves $t alone"; FAILED=$((FAILED + 1)); else echo "PASS matcher leaves $t alone"; fi
done

detector_re=$(sed -n "s/^tok_re='\(.*\)'\$/\1/p" "$REPO/scripts/hooks/detect-token-in-output.sh")
hook_re=$(sed -n "s/^default_re='\(.*\)'\$/\1/p" "$PLUGIN_DIR/hooks/block-token-shaped-web-query.sh")
if [ -n "$detector_re" ] && [ "$detector_re" = "$hook_re" ]; then echo "PASS fallback regex equals detect-token-in-output.sh"; else echo "FAIL fallback regex equals detect-token-in-output.sh - detector=[$detector_re] hook=[$hook_re]"; FAILED=$((FAILED + 1)); fi

for l in p o u s r; do
    for kind in "valid:$good_sum" "invalid:$bad_sum"; do
        tok=$(gh_token "$l" "${kind#*:}")
        run_case "$(search_payload "how long is $tok exactly")"
        refused "WebSearch query with gh${l}_ token, ${kind%%:*} checksum"
        assert_lacks "WebSearch gh${l}_ ${kind%%:*}: message omits the token body" "$body30" "$ERR"
        run_case "$(fetch_payload "https://example.com/lookup?q=$tok")"
        refused "WebFetch url with gh${l}_ token, ${kind%%:*} checksum"
    done
done

tok=$(gh_token r "$good_sum")
pct="%"
run_case "$(fetch_payload "https://example.com/lookup?q=${pct}67${tok#g}")"
refused "WebFetch url with a percent-encoded character of a token"
run_case "$(fetch_payload "https://example.com/lookup?q=100${pct}25+sure")"
allowed "WebFetch url with an encoded percent sign passes"

tok=$(pat_token)
run_case "$(search_payload "find $tok")"
refused "WebSearch query with a github_pat_ token"
run_case "$(fetch_payload "https://example.com/$tok")"
refused "WebFetch url with a github_pat_ token"
tok="github_pat_$(printf 'A%.0s' $(seq 1 82))"
run_case "$(search_payload "find $tok")"
refused "WebSearch query with a repeated-character github_pat_ body"
tok="ghr_$(printf 'A%.0s' $(seq 1 36))"
run_case "$(fetch_payload "https://example.com/$tok")"
refused "WebFetch url with a repeated-character ghr_ body"

tok=$(gh_token r "$good_sum")
PROJ="$TMP/no-checkout" run_case "$(search_payload "x $tok")"
refused "a checkout without detect-token-in-output.sh still refuses (built-in regex)"

mkdir -p "$TMP/narrowed/scripts/hooks" "$TMP/invalid/scripts/hooks" "$TMP/wider/scripts/hooks" "$TMP/empty/scripts/hooks" "$TMP/plain/scripts/hooks" "$TMP/nojq"
printf "tok_re='(ghp_[0-9A-Za-z]{99})'\n" >"$TMP/narrowed/scripts/hooks/detect-token-in-output.sh"
printf "tok_re='(['\n" >"$TMP/invalid/scripts/hooks/detect-token-in-output.sh"
printf "tok_re='(zzq_[0-9]{4})'\n" >"$TMP/wider/scripts/hooks/detect-token-in-output.sh"
printf "tok_re='(x*)'\n" >"$TMP/empty/scripts/hooks/detect-token-in-output.sh"
printf "tok_re='(secretword)'\n" >"$TMP/plain/scripts/hooks/detect-token-in-output.sh"
ln -s "$(command -v cat)" "$TMP/nojq/cat"
fixtures=0
for d in narrowed invalid wider empty plain; do if [ -s "$TMP/$d/scripts/hooks/detect-token-in-output.sh" ]; then fixtures=$((fixtures + 1)); fi; done
assert_eq "the five detector fixtures were written" 5 "$fixtures"
if [ -L "$TMP/nojq/cat" ] && [ -x "$TMP/nojq/cat" ]; then echo "PASS the no-jq PATH holds cat"; else echo "FAIL the no-jq PATH holds cat"; FAILED=$((FAILED + 1)); fi
tok=$(gh_token r "$good_sum")
PROJ="$TMP/wider" run_case "$(search_payload "look up zzq_1234")"
refused "a checkout regex that adds a shape is followed as extra coverage"
PROJ="$TMP/plain" run_case "$(search_payload "look up secretword")"
refused "a checkout regex match with no underscore is refused"
assert_lacks "a checkout regex match with no underscore: message omits the match" "secretword" "$ERR"
PROJ="$TMP/empty" run_case "$(fetch_payload "https://example.com/lookup?q=${pct}67${tok#g}")"
refused "a checkout regex that matches the empty string does not hide a percent-encoded token"
PROJ="$TMP/narrowed" run_case "$(search_payload "x $tok")"
refused "a checkout whose detector regex is narrowed still refuses (built-in regex)"
PROJ="$TMP/invalid" run_case "$(search_payload "x $tok")"
refused "a checkout whose detector regex is invalid still refuses (built-in regex)"

run_nojq() {
    OUT=$(printf '%s' "$1" | env PATH="$TMP/nojq" CLAUDE_PROJECT_DIR="$REPO" WEB_TOKEN_QUERY_OK=0 "$BASH" "$PLUGIN_DIR/hooks/block-token-shaped-web-query.sh" 2>"$TMP/stderr.txt")
    RC=$?
    ERR=$(cat "$TMP/stderr.txt")
}
run_nojq "$(search_payload "x $tok")"
refused "without jq, a raw token is refused"
bs=$(printf '\134')
run_nojq "$(printf '{"tool_name":"WebSearch","tool_input":{"query":"x %su0067%s"}}' "$bs" "${tok:1}")"
refused "without jq, a token hidden behind a JSON escape is refused"
run_nojq "$(search_payload "latest bun release notes")"
allowed "without jq, an ordinary query passes"
run_nojq "$(printf '{"tool_name":"WebSearch","tool_input":{"query":"the %s%su0067 escape syntax"}}' "$bs" "$bs")"
allowed "without jq, a search for the literal escape syntax passes"
run_nojq "$(printf '{"tool_name":"WebSearch","tool_input":{"query":"x %s%s%su0067%s"}}' "$bs" "$bs" "$bs" "${tok:1}")"
refused "without jq, an escape behind an escaped backslash is still refused"

tok=$(gh_token r "$good_sum")
run_case "$(fetch_payload "https://example.com/lookup?a=${pct}zz&q=${pct}67${tok#g}")"
refused "a percent escape after a malformed one is still decoded"
run_case "$(fetch_payload "https://example.com/a${bs}n${pct}67${tok#g}")"
refused "a percent escape after a backslash sequence is still decoded"
run_case "$(fetch_payload "https://example.com/a${bs}c${pct}67${tok#g}")"
refused "a percent escape after a backslash-c is still decoded"

run_case "$(search_payload "latest bun release notes")"
allowed "an ordinary query passes"
run_case "$(fetch_payload "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-authentication-to-github")"
allowed "an ordinary url passes"
run_case "$(search_payload "github ghr_ refresh token prefix followed by 36 alphanumerics, 40 characters in all")"
allowed "a query describing a token shape in words passes"
run_case "$(search_payload "what is the ghr_ prefix")"
allowed "a query about the ghr_ prefix with no body passes"
run_case "$(search_payload "github_pat_ fine-grained token format")"
allowed "a query about the github_pat_ prefix with no body passes"
run_case "$(search_payload "x $(gh_token r "$good_sum")")" "WEB_TOKEN_QUERY_OK=1"
allowed "WEB_TOKEN_QUERY_OK=1 passes a refused query"

run_case 'not json at all'
allowed "garbage input without a token passes"
run_case "$(printf 'not json %s' "$(gh_token p "$good_sum")")"
refused "garbage input that holds a token is still refused (fail closed)"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
