#!/usr/bin/env bash
# test-redirect-webfetch-walled-hosts-plugin.sh — suite for the plugin WebFetch redirect
# on login-walled hosts. The suite is the spec.
#
# Every plugin case runs the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT
# on a copy in a plugin-cache-shaped fixture config dir (as a real install has it)
# and CLAUDE_PROJECT_DIR on a fixture repo that is not himmel,
# so a wiring that points at $CLAUDE_PROJECT_DIR/scripts/hooks/ (an --optional
# no-op outside himmel) reads as allow and fails the deny rows.
#
# Usage: bash scripts/hooks/test-redirect-webfetch-walled-hosts-plugin.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../.." && pwd)"
PLUGIN_DIR="$HIMMEL_ROOT/marketplace/plugins/himmel-ops"
FAILED=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required and not on PATH"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/walled-host.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo" || exit 1
LOG="$TMP/deny.jsonl"

# A fixture that did not get written would let a case pass without testing what
# it names, so setup stops the suite: put <file> <text with \n escapes> makes the
# parent dir and writes the file; setup_fail reports a failed write.
setup_fail() { echo "FAIL fixture setup: $*"; exit 1; }
put() {
    if ! { mkdir -p "$(dirname "$1")" && printf '%b' "$2" >"$1"; }; then setup_fail "$1"; fi
}

# The layout of a real install: the plugin runs from a copy in the plugin cache
# under the config dir, not from a checkout, and the himmel checkout is found from
# the user-scope marketplace record in that config dir. record <marketplace dir>
# writes it; record none removes it (the adopter default).
CFG="$TMP/home/.claude"
CACHE_DIR="$CFG/plugins/cache/himmel/himmel-ops/0.0.0"
mkdir -p "$CACHE_DIR" && cp -R "$PLUGIN_DIR/hooks" "$CACHE_DIR/hooks" || exit 1
record() {
    if [ "$1" = none ]; then
        rm -f "$CFG/plugins/known_marketplaces.json"
    else
        if ! { mkdir -p "$CFG/plugins" && jq -n --arg p "$1" '{himmel:{source:{source:"directory",path:$p},installLocation:$p}}' \
            >"$CFG/plugins/known_marketplaces.json"; }; then setup_fail "marketplace record for $1"; fi
    fi
}

plugin_cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("redirect-webfetch-walled-hosts.sh"))' "$PLUGIN_DIR/hooks/hooks.json")

wf() { jq -nc --arg u "$1" '{session_id:"s-walled",tool_name:"WebFetch",tool_input:{url:$u,prompt:"p"}}'; }
# wft <tool_use_id>: a deny payload carrying the id; wftj <json value>: the id as raw JSON.
wft() { jq -nc --arg id "$1" '{session_id:"s-walled",tool_use_id:$id,tool_name:"WebFetch",tool_input:{url:"https://x.com/a/status/1",prompt:"p"}}'; }
wftj() { jq -nc --argjson id "$1" '{session_id:"s-walled",tool_use_id:$id,tool_name:"WebFetch",tool_input:{url:"https://x.com/a/status/1",prompt:"p"}}'; }

# run_case <payload> <project dir> [VAR=value]: sets RC, ERR and OUT. The config
# dir is CLAUDE_CONFIG_DIR=$CFG; CFG_ASSIGN=X_UNUSED=1 leaves it unset so the
# hook takes its default, $HOME/.claude, with HOME on the fixture home.
run_case() {
    rm -f "$LOG"
    ERR="$TMP/err"
    OUT=$(cd "$2" && printf '%s' "$1" | env -u WALLED_TOOLING_DIR -u CLAUDE_CONFIG_DIR HOME="$TMP/home" \
        CLAUDE_PLUGIN_ROOT="$CACHE_DIR" "${CFG_ASSIGN:-CLAUDE_CONFIG_DIR=$CFG}" \
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

rows() { [ -f "$LOG" ] || { echo 0; return; }; wc -l <"$LOG" | tr -d ' '; }

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

# Files the PROJECT owns cannot pick the mode or the host list. An
# adopter repo carrying its own scripts/web/fetch-url.sh and an empty (or
# different) walled-hosts.conf still gets the embedded list and the adopter deny.
put "$TMP/owned/scripts/web/fetch-url.sh" '#!/bin/sh\nexit 0\n'
put "$TMP/owned/scripts/web/walled-hosts.conf" '\n'
run_case "$(wf 'https://x.com/a/status/1')" "$TMP/owned"
assert_eq "project-owned fetcher + empty conf: walled host still denied" 2 "$RC"
case "$ERR" in
    *fetch-url*) echo "FAIL project-owned files: deny names the project fetcher: $ERR"
                 FAILED=$((FAILED + 1)) ;;
    *) echo "PASS project-owned files: deny names no project script" ;;
esac
put "$TMP/owned/scripts/web/walled-hosts.conf" 'example.org\n'
run_case "$(wf 'https://x.com/a/status/1')" "$TMP/owned"
assert_eq "project-owned conf naming another host: x.com still denied" 2 "$RC"
run_case "$(wf 'https://example.org/a')" "$TMP/owned"
assert_eq "project-owned conf naming another host: that host not walled" 0 "$RC"

# The recorded himmel checkout's conf: an empty or blank first line keeps the
# embedded list (the guard must not go silent), a real line is the host list.
mkdir -p "$TMP/fx/marketplace" || setup_fail "$TMP/fx/marketplace"
put "$TMP/fx/scripts/web/fetch-url.sh" '#!/bin/sh\nexit 0\n'
record "$TMP/fx/marketplace"
for blank in '' '   '; do
    put "$TMP/fx/scripts/web/walled-hosts.conf" "$blank\\n"
    run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo"
    assert_eq "recorded checkout, blank conf line '$blank': walled host still denied" 2 "$RC"
    case "$ERR" in
        *fetch-url*) echo "FAIL recorded checkout, blank conf: deny names the fetcher: $ERR"
                     FAILED=$((FAILED + 1)) ;;
        *) echo "PASS recorded checkout, blank conf: embedded list and adopter deny" ;;
    esac
done
put "$TMP/fx/scripts/web/walled-hosts.conf" 'example.org\n'
run_case "$(wf 'https://example.org/a')" "$TMP/repo"
assert_eq "recorded checkout, conf example.org: that host denied" 2 "$RC"
assert_contains "recorded checkout, conf example.org: deny names the recorded fetcher" \
    "'$TMP/fx/scripts/web/fetch-url.sh' 'https://example.org/a'" "$ERR"
run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo"
assert_eq "recorded checkout, conf example.org: the conf line is the list" 0 "$RC"
record none

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
    record "$HIMMEL_ROOT/marketplace"
    run_case "$(wf 'https://x.com/a/status/1')" "$HIMMEL_ROOT"
    assert_eq "himmel: plugin hook denies" 2 "$RC"
    assert_contains "himmel: deny names the fetcher with the quoted url" \
        "fetch-url.sh' 'https://x.com/a/status/1'" "$ERR"
    assert_eq "himmel: plugin writes one row" 1 "$(rows)"

    # The mode comes from the user-scope record, never from the project: with the
    # record, an adopter project dir still gets himmel mode, and a project-owned
    # fetcher beside it is ignored.
    run_case "$(wf 'https://x.com/a/status/1')" "$TMP/owned"
    assert_eq "himmel record, adopter project: denies" 2 "$RC"
    assert_contains "himmel record, adopter project: names the checkout fetcher" \
        "'$HIMMEL_ROOT/scripts/web/fetch-url.sh' 'https://x.com" "$ERR"
    run_case "$(wf 'https://docs.python.org/3/')" "$HIMMEL_ROOT"
    assert_eq "himmel record: non-walled host allowed" 0 "$RC"

    # CLAUDE_CONFIG_DIR wins over HOME: with HOME on another dir the record is
    # still read from CLAUDE_CONFIG_DIR (HOME and the config dir are one path in
    # every other case, so only this row tells them apart).
    run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo" HOME="$TMP/elsewhere"
    assert_eq "CLAUDE_CONFIG_DIR over HOME: the record is found, denies" 2 "$RC"
    assert_contains "CLAUDE_CONFIG_DIR over HOME: names the recorded checkout's fetcher" \
        "'$HIMMEL_ROOT/scripts/web/fetch-url.sh' 'https://x.com" "$ERR"

    # The default config dir ($HOME/.claude, CLAUDE_CONFIG_DIR unset), a record
    # path with a trailing slash, and a record that does not parse.
    CFG_ASSIGN=X_UNUSED=1
    run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo"
    assert_eq "default config dir: the record is found, denies" 2 "$RC"
    assert_contains "default config dir: names the recorded checkout's fetcher" \
        "'$HIMMEL_ROOT/scripts/web/fetch-url.sh' 'https://x.com" "$ERR"
    CFG_ASSIGN=""
    record "$HIMMEL_ROOT/marketplace/"
    run_case "$(wf 'https://x.com/a/status/1')" "$TMP/repo"
    assert_eq "trailing-slash record: denies" 2 "$RC"
    assert_contains "trailing-slash record: names the recorded checkout's fetcher" \
        "'$HIMMEL_ROOT/scripts/web/fetch-url.sh' 'https://x.com" "$ERR"
    # The project owns a fetcher and a conf naming x.com, both beside the project
    # dir and at a relative path a non-string location (42) would resolve to, so
    # reading the project dir, or trusting a non-string location, shows up as a
    # deny that names a fetcher.
    put "$TMP/owned/scripts/web/walled-hosts.conf" 'x.com\n'
    put "$TMP/owned/42/scripts/web/fetch-url.sh" '#!/bin/sh\nexit 0\n'
    put "$TMP/owned/42/scripts/web/walled-hosts.conf" 'x.com\n'
    for bad in '{not json\n' '{"himmel":{"installLocation":42}}\n' '[]\n'; do
        put "$CFG/plugins/known_marketplaces.json" "$bad"
        run_case "$(wf 'https://x.com/a/status/1')" "$TMP/owned"
        assert_eq "unusable record $bad: walled host still denied" 2 "$RC"
        assert_contains "unusable record $bad: the adopter message" "will not return the page" "$ERR"
        case "$ERR" in
            *fetch-url*) echo "FAIL unusable record: deny names a fetcher: $ERR"
                         FAILED=$((FAILED + 1)) ;;
            *) echo "PASS unusable record: embedded list and adopter deny" ;;
        esac
    done
    record none

    # The project-lane copy delegates to the plugin source, so the rule has one
    # source. One deny is one row: the shim and the plugin lane claim
    # a deny by its tool_use_id, so the lane that fires alone writes the row and
    # both lanes together write exactly one.
    SHIM="$HIMMEL_ROOT/scripts/hooks/redirect-webfetch-walled-hosts.sh"
    run_shim() {
        printf '%s' "$1" | env -u WALLED_TOOLING_DIR WEBFETCH_WALLED_LOG="$LOG" \
            HIMMEL_WEBFETCH_WALLED_OK=0 bash "$SHIM" >/dev/null 2>&1
    }
    # Run the installed plugin command (as run_case does) without clearing the log.
    run_plugin_keep() {
        printf '%s' "$1" | env -u WALLED_TOOLING_DIR -u CLAUDE_CONFIG_DIR HOME="$TMP/home" \
            CLAUDE_PLUGIN_ROOT="${2:-$CACHE_DIR}" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$TMP/repo" \
            WEBFETCH_WALLED_LOG="$LOG" HIMMEL_WEBFETCH_WALLED_OK=0 sh -c "$plugin_cmd" >/dev/null 2>&1
    }

    # Plugin disabled: only the project shim fires, and its deny still leaves a row.
    rm -rf "$LOG" "$TMP/.claims"
    run_shim "$(wft toolu_disabled1)"
    assert_eq "plugin disabled: shim denies" 2 "$?"
    assert_eq "plugin disabled: the shim writes the row" 1 "$(rows)"
    assert_eq "plugin disabled: the row names the session and host" 1 \
        "$(jq -c 'select(.session_id == "s-walled" and .decision == "deny" and .host == "x.com")' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"

    # Plugin cached at an older version without this hook: the plugin lane does not
    # fire at all, the shim is the only writer.
    OLD_CACHE="$CFG/plugins/cache/himmel/himmel-ops/0.0.-1"
    if ! { mkdir -p "$OLD_CACHE/hooks" && cp "$PLUGIN_DIR/hooks/run-node.sh" "$PLUGIN_DIR/hooks/run-hook-with-bash.js" "$OLD_CACHE/hooks/"; }; then setup_fail "$OLD_CACHE"; fi
    rm -rf "$LOG" "$TMP/.claims"
    run_plugin_keep "$(wft toolu_older1)" "$OLD_CACHE"
    assert_eq "older cached plugin: the plugin lane writes nothing" 0 "$(rows)"
    run_shim "$(wft toolu_older1)"
    assert_eq "older cached plugin: shim denies" 2 "$?"
    assert_eq "older cached plugin: the shim writes the row" 1 "$(rows)"

    # Negative control: both lanes active on one deny write exactly one row, in
    # either order; a second deny (another tool_use_id) writes its own row.
    rm -rf "$LOG" "$TMP/.claims"
    run_plugin_keep "$(wft toolu_both1)"
    run_shim "$(wft toolu_both1)"
    assert_eq "both lanes, plugin first: one row for one deny" 1 "$(rows)"
    rm -rf "$LOG" "$TMP/.claims"
    run_shim "$(wft toolu_both2)"
    run_plugin_keep "$(wft toolu_both2)"
    assert_eq "both lanes, shim first: one row for one deny" 1 "$(rows)"
    run_shim "$(wft toolu_both3)"
    run_plugin_keep "$(wft toolu_both3)"
    assert_eq "both lanes, a second deny: its own row" 2 "$(rows)"

    # An unwritable claim directory is not "already claimed": the row is written.
    if [ "$(id -u)" != 0 ]; then
        rm -rf "$LOG" "$TMP/.claims"
        if ! { mkdir -p "$TMP/.claims" && chmod 555 "$TMP/.claims"; }; then setup_fail "$TMP/.claims"; fi
        run_shim "$(wft toolu_ro1)"
        assert_eq "unwritable claim dir: the deny still writes its row" 1 "$(rows)"
        chmod 755 "$TMP/.claims"
    fi

    # A failed append releases the claim, so the other lane can still write.
    rm -rf "$LOG" "$TMP/.claims"
    mkdir "$LOG" || setup_fail "$LOG"
    run_shim "$(wft toolu_fail1)"
    assert_eq "failed append: the claim is released" 0 "$(find "$TMP/.claims" -type f 2>/dev/null | wc -l | tr -d ' ')"
    rmdir "$LOG"

    # Lanes started together on one deny: the exclusive claim leaves exactly one row.
    rm -rf "$LOG" "$TMP/.claims"
    for k in 1 2 3 4 5; do
        for _j in 1 2 3 4; do
            run_shim "$(wft "toolu_par$k")" &
            run_plugin_keep "$(wft "toolu_par$k")" &
        done
        wait
    done
    assert_eq "parallel lanes: one row per deny (5 denies, 8 processes each)" 5 "$(rows)"

    # The claim sweep drops a stale claim and keeps a fresh one.
    rm -rf "$LOG" "$TMP/.claims"
    if ! { mkdir -p "$TMP/.claims" && : >"$TMP/.claims/toolu_old1" && : >"$TMP/.claims/toolu_fresh1" \
        && touch -t 202001010000 "$TMP/.claims/toolu_old1"; }; then setup_fail "$TMP/.claims"; fi
    run_shim "$(wft toolu_old1)"
    assert_eq "stale claim is swept: its deny writes a row" 1 "$(rows)"
    run_shim "$(wft toolu_fresh1)"
    assert_eq "fresh claim is kept: its deny writes no second row" 1 "$(rows)"
    # The sweep reaches only the claims dir: a stale file beside the log, and the
    # log itself when it is stale, survive.
    if ! { : >"$TMP/stale-sibling" && touch -t 202001010000 "$TMP/stale-sibling" "$LOG"; }; then setup_fail "$TMP/stale-sibling"; fi
    run_shim "$(wft toolu_sib1)"
    [ -e "$TMP/stale-sibling" ] && present=yes || present=no
    assert_eq "sweep leaves a stale sibling of the log alone" yes "$present"
    assert_eq "sweep leaves a stale log's rows alone" 2 "$(rows)"

    # A tool_use_id that is not a plain id string never changes the decision: the
    # deny holds and the row is written (no claim) for each.
    for idjson in 42 null '{"a":1}' '["x"]' '"a\u0001b"' '"a\nb"' '"a\n"' '"has.dot"'; do
        rm -rf "$LOG" "$TMP/.claims"
        run_plugin_keep "$(wftj "$idjson")"
        assert_eq "tool_use_id $idjson: the plugin command still denies" 2 "$?"
        assert_eq "tool_use_id $idjson: one row" 1 "$(rows)"
    done
    # An id over 10 MB (built inside jq) must not be able to error the id check:
    # the filter's error path is an allow.
    big=$(jq -nc '{session_id:"s-walled",tool_use_id:("a" * 10100000 + "."),tool_name:"WebFetch",tool_input:{url:"https://x.com/a/status/1",prompt:"p"}}') || setup_fail "10.1M id payload"
    rm -rf "$LOG" "$TMP/.claims"
    run_plugin_keep "$big"
    assert_eq "10.1M-character tool_use_id: the plugin command still denies" 2 "$?"
    assert_eq "10.1M-character tool_use_id: one row" 1 "$(rows)"
else
    echo "SKIP himmel chain: no fetch-url.sh at $HIMMEL_ROOT/scripts/web"
fi

# HOME unset and no log override: the row goes to a temp-dir log, not nowhere.
# run_home_unset <tmpdir> <payload>: the installed command with HOME and the log override unset.
run_home_unset() {
    printf '%s' "$2" | env -u HOME -u WEBFETCH_WALLED_LOG -u WALLED_TOOLING_DIR -u CLAUDE_CONFIG_DIR \
        TMPDIR="$1" CLAUDE_PLUGIN_ROOT="$CACHE_DIR" CLAUDE_PROJECT_DIR="$TMP/repo" \
        HIMMEL_WEBFETCH_WALLED_OK=0 sh -c "$plugin_cmd" >/dev/null 2>&1
}
FB_TMP="$TMP/fallback-tmp"
mkdir -p "$FB_TMP" || setup_fail "$FB_TMP"
run_home_unset "$FB_TMP" "$(wft toolu_home1)"
assert_eq "HOME unset: walled host still denied" 2 "$?"
assert_eq "HOME unset: one row in the temp-dir log" 1 \
    "$(cat "$FB_TMP"/himmel-webfetch-walled-*/denials.jsonl 2>/dev/null | jq -c 'select(.host == "x.com" and .decision == "deny")' 2>/dev/null | wc -l | tr -d ' ')"
run_home_unset "$FB_TMP" "$(wft toolu_home2)"
assert_eq "HOME unset: a second deny appends a second row" 2 \
    "$(cat "$FB_TMP"/himmel-webfetch-walled-*/denials.jsonl 2>/dev/null | wc -l | tr -d ' ')"
run_home_unset "$FB_TMP" "$(wft toolu_home2)"
assert_eq "HOME unset: the same deny claimed twice stays one row" 2 \
    "$(cat "$FB_TMP"/himmel-webfetch-walled-*/denials.jsonl 2>/dev/null | wc -l | tr -d ' ')"

# A symlink planted at the fallback dir is refused: the deny holds, nothing is
# written through the link. The target is a dir this user owns, so only the
# symlink check can refuse it.
SL_TMP="$TMP/symlink-tmp"
SL_TARGET="$TMP/symlink-target"
if ! { mkdir -p "$SL_TMP" "$SL_TARGET" && ln -s "$SL_TARGET" "$SL_TMP/himmel-webfetch-walled-$(id -u)"; }; then setup_fail "$SL_TMP"; fi
run_home_unset "$SL_TMP" "$(wft toolu_link1)"
assert_eq "HOME unset, planted symlink: the deny holds" 2 "$?"
assert_eq "HOME unset, planted symlink: nothing is written through it" 0 \
    "$(find "$SL_TARGET" -mindepth 1 | wc -l | tr -d ' ')"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All redirect-webfetch-walled-hosts.sh plugin cases passed."
    exit 0
fi
echo "$FAILED case(s) failed."
exit 1
