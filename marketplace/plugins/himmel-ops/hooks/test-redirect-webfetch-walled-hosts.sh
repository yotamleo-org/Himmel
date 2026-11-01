#!/usr/bin/env bash
# test-redirect-webfetch-walled-hosts.sh — suite for the plugin WebFetch redirect
# on login-walled hosts. The suite is the spec.
#
# Every plugin case runs the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT
# on this plugin dir and CLAUDE_PROJECT_DIR on a fixture repo that is not himmel,
# so a wiring that points at $CLAUDE_PROJECT_DIR/scripts/hooks/ (an --optional
# no-op outside himmel) reads as allow and fails the deny rows.
#
# Usage: bash marketplace/plugins/himmel-ops/hooks/test-redirect-webfetch-walled-hosts.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../../../.." && pwd)"
FAILED=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required and not on PATH"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/walled-host.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"
LOG="$TMP/deny.jsonl"

plugin_cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("redirect-webfetch-walled-hosts.sh"))' "$PLUGIN_DIR/hooks/hooks.json")

wf() { jq -nc --arg u "$1" '{session_id:"s-walled",tool_name:"WebFetch",tool_input:{url:$u,prompt:"p"}}'; }

# run_case <payload> <project dir> [VAR=value]: sets RC, ERR and OUT.
run_case() {
    rm -f "$LOG"
    ERR="$TMP/err"
    OUT=$(cd "$2" && printf '%s' "$1" | env -u WALLED_TOOLING_DIR CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
        CLAUDE_PROJECT_DIR="$2" WEBFETCH_WALLED_LOG="$LOG" HIMMEL_WEBFETCH_WALLED_OK=0 ${3:+"$3"} \
        sh -c "${plugin_cmd:-exit 0}" 2>"$ERR")
    RC=$?
    ERR=$(cat "$ERR")
}

assert_eq() {
    if [ "$3" = "$2" ]; then
        echo "PASS $1 ($3)"
    else
        echo "FAIL $1 - expected $2, got $3"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - message did not contain: $2"
           echo "  got: $3"
           FAILED=$((FAILED + 1)) ;;
    esac
}

rows() { wc -l <"$LOG" 2>/dev/null | tr -d ' '; }

# An adopter repo (not himmel) gets the redirect from the plugin.
run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo"
assert_eq "adopter: walled host denied" 2 "$RC"
assert_contains "adopter: deny names the bypass" "HIMMEL_WEBFETCH_WALLED_OK=1" "$ERR"
case "$ERR" in
    *scripts/*|*fetch-url*)
        echo "FAIL adopter: deny names a himmel script: $ERR"
        FAILED=$((FAILED + 1)) ;;
    *) echo "PASS adopter: deny names no himmel script" ;;
esac
assert_eq "adopter: structured decision is deny" deny \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
n=$(jq -c 'select(.session_id == "s-walled" and .decision == "deny" and .host == "x.com")' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "adopter: one JSONL row with the session_id and host" 1 "$n"
assert_eq "adopter: the row carries no url" 0 \
    "$(jq -c 'select(has("url"))' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"

for u in 'https://twitter.com/a/status/1' 'https://mobile.twitter.com/a/status/1' \
         'https://www.instagram.com/p/ABC/' 'https://WWW.X.COM/a/status/1' \
         'https://old.reddit.com/r/a' 'https://redd.it/abc' 'https://u:p@x.com:443/a?q=1'; do
    run_case "$(wf "$u")" "$TMP/repo"
    assert_eq "adopter: denied $u" 2 "$RC"
done

for u in 'https://example.com/x.com' 'https://notx.com/a' 'https://x.com.evil.example/a' 'https://docs.python.org/3/'; do
    run_case "$(wf "$u")" "$TMP/repo"
    assert_eq "adopter: allowed $u" 0 "$RC"
done
[ -e "$LOG" ] && present=yes || present=no
assert_eq "allow writes no row" no "$present"

run_case '{"tool_name":"Bash","tool_input":{"command":"echo https://x.com/a"}}' "$TMP/repo"
assert_eq "other tool allowed" 0 "$RC"
for j in '' 'not json' '{}' '{"tool_name":"WebFetch"}' '{"tool_name":"WebFetch","tool_input":{"url":42}}' '{"tool_name":"WebFetch","tool_input":{"url":"::::"}}'; do
    run_case "$j" "$TMP/repo"
    assert_eq "fail-open on: ${j:-<empty>}" 0 "$RC"
done

run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo" HIMMEL_WEBFETCH_WALLED_OK=1
assert_eq "bypass HIMMEL_WEBFETCH_WALLED_OK=1" 0 "$RC"

# The embedded adopter host list is the one line himmel's fetcher reads.
src="$PLUGIN_DIR/hooks/redirect-webfetch-walled-hosts.sh"
conf_line=$(head -n 1 "$HIMMEL_ROOT/scripts/web/walled-hosts.conf" 2>/dev/null)
if [ -n "$conf_line" ]; then
    assert_contains "embedded host list equals scripts/web/walled-hosts.conf" "\"$conf_line\"" "$(cat "$src" 2>/dev/null)"
else
    echo "SKIP embedded host list: no walled-hosts.conf at $HIMMEL_ROOT"
fi

# A himmel session keeps the paste-ready fetcher command and writes one row.
if [ -f "$HIMMEL_ROOT/scripts/web/fetch-url.sh" ]; then
    run_case "$(wf 'https://x.com/a/status/1')" "$HIMMEL_ROOT"
    assert_eq "himmel: plugin hook denies" 2 "$RC"
    assert_contains "himmel: deny names the fetcher with the quoted url" \
        "fetch-url.sh' 'https://x.com/a/status/1'" "$ERR"
    assert_eq "himmel: plugin writes one row" 1 "$(rows)"

    # The project-lane copy delegates to the plugin source, so the rule has one
    # source; it must not log, or a himmel deny would write two rows.
    rm -f "$LOG"
    printf '%s' "$(wf 'https://x.com/a/status/1')" | env WEBFETCH_WALLED_LOG="$LOG" \
        HIMMEL_WEBFETCH_WALLED_OK=0 bash "$HIMMEL_ROOT/scripts/hooks/redirect-webfetch-walled-hosts.sh" >/dev/null 2>&1
    assert_eq "himmel: project-lane copy denies" 2 "$?"
    [ -e "$LOG" ] && present=yes || present=no
    assert_eq "himmel: project-lane copy writes no row" no "$present"
else
    echo "SKIP himmel chain: no fetch-url.sh at $HIMMEL_ROOT/scripts/web"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All redirect-webfetch-walled-hosts.sh plugin cases passed."
    exit 0
fi
echo "$FAILED case(s) failed."
exit 1
