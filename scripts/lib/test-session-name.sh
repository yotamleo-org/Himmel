#!/usr/bin/env bash
# test-session-name.sh — current_session_name resolves the `-n`
# session name from a fabricated NUL-delimited cmdline fixture (via the
# SESSION_NAME_CMDLINE_FILE test seam — see session-name.sh's header for why
# a real pid's /proc/<pid>/cmdline can't be fabricated in a test).
# Run: bash scripts/lib/test-session-name.sh
#
# PLATFORM GUARD: tests a Linux-only seam (see session-name.sh's header).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/session-name.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-name-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# The argv cases never read the operator's real session registry or /proc stat.
export SESSION_NAME_REGISTRY_FILE="$WORK/no-such-registry.json"
export SESSION_NAME_PROC_STAT_FILE="$WORK/no-such-stat"

# fake_cmdline <arg> <arg> ... — writes a NUL-delimited argv fixture and
# points SESSION_NAME_CMDLINE_FILE + CLAUDE_PID at it.
fake_cmdline() {
    local f="$WORK/cmdline"
    printf '%s\0' "$@" > "$f"
    export SESSION_NAME_CMDLINE_FILE="$f"
    export CLAUDE_PID="12345"
}

# --- Case 1: happy path -------------------------------------------------
fake_cmdline claude --model claude-sonnet-5 -n HIMMEL-2788-legN54 load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "HIMMEL-2788-legN54" ]; then
    pass "resolves -n value from argv"
else
    fail "resolves -n value from argv (rc=$rc out='$out')"
fi

# --- Case 2: no -n flag --------------------------------------------------
fake_cmdline claude --model claude-sonnet-5 load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "no -n flag: unresolvable (rc!=0, empty)"
else
    fail "no -n flag: unresolvable (rc=$rc out='$out')"
fi

# --- Case 3: no CLAUDE_PID -------------------------------------------------
unset CLAUDE_PID
export SESSION_NAME_CMDLINE_FILE="$WORK/cmdline"
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "no CLAUDE_PID: unresolvable"
else
    fail "no CLAUDE_PID: unresolvable (rc=$rc out='$out')"
fi

# --- Case 4: traversal refused -------------------------------------------
fake_cmdline claude -n "../../etc/passwd" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "traversal name (../..) refused"
else
    fail "traversal name (../..) refused (rc=$rc out='$out')"
fi

fake_cmdline claude -n "foo/bar" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "slash in name refused"
else
    fail "slash in name refused (rc=$rc out='$out')"
fi

# --- Case 5: whitespace refused -------------------------------------------
fake_cmdline claude -n "foo bar" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "whitespace in name refused"
else
    fail "whitespace in name refused (rc=$rc out='$out')"
fi

# --- Case 5b: glob metacharacters refused (find -name treats them as
# wildcards, not literal characters, so an unsanitized name can cross-match
# another session's chief doc under resolve_chief_doc's find -name
# "${name}.md") -----------------------------------
fake_cmdline claude -n "*-chief" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "glob star in name refused"
else
    fail "glob star in name refused (rc=$rc out='$out')"
fi

fake_cmdline claude -n "foo?bar" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "glob question-mark in name refused"
else
    fail "glob question-mark in name refused (rc=$rc out='$out')"
fi

fake_cmdline claude -n "foo[bar]" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "glob bracket in name refused"
else
    fail "glob bracket in name refused (rc=$rc out='$out')"
fi

# --- Case 6: missing cmdline file -----------------------------------------
export CLAUDE_PID="12345"
export SESSION_NAME_CMDLINE_FILE="$WORK/does-not-exist"
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "missing cmdline file: unresolvable, no crash"
else
    fail "missing cmdline file: unresolvable (rc=$rc out='$out')"
fi

# --- Registry source (T3 Code) ---------------------------------------------
# fake_registry <json> [stat-start|-] — argv without -n, a registry fixture
# and a /proc/<pid>/stat fixture whose start time is <stat-start> ("-" = no
# readable stat file, the macOS shape).
fake_registry() {
    fake_cmdline claude --session-id e2fa1afe --output-format stream-json
    printf '%s' "$1" > "$WORK/registry.json"
    export SESSION_NAME_REGISTRY_FILE="$WORK/registry.json"
    if [ "${2:-25111526}" = "-" ]; then
        export SESSION_NAME_PROC_STAT_FILE="$WORK/no-such-stat"
    else
        printf '12345 (claude (x) y) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21\n' "${2:-25111526}" > "$WORK/stat"
        export SESSION_NAME_PROC_STAT_FILE="$WORK/stat"
    fi
}
# reg <name-json> [entrypoint] [pid] — one registry line in the observed shape.
reg() {
    printf '{"pid":%s,"sessionId":"e2fa1afe","cwd":"/w","procStart":"25111526","kind":"interactive","entrypoint":"%s","name":%s,"nameSource":"user","status":"busy"}' \
        "${3:-12345}" "${2:-t3-code}" "$1"
}
expect_name() { # expect_name <label> <want>
    local out rc
    out="$(current_session_name)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then pass "$1"; else fail "$1 (rc=$rc out='$out')"; fi
}
expect_none() { # expect_none <label>
    local out rc
    out="$(current_session_name)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "$1"; else fail "$1 (rc=$rc out='$out')"; fi
}

fake_registry "$(reg '"T3-chief"')"
expect_name "registry: T3 thread titled X-chief resolves" "T3-chief"

fake_registry "$(reg '"ops-console"')"
expect_name "registry: T3 thread titled X-console resolves" "ops-console"

fake_registry "$(reg '"T3-chief"')" -
expect_name "registry: no readable /proc stat (macOS) skips the start-time check" "T3-chief"

fake_registry "$(reg '"T3-chief"')"
fake_cmdline claude -n argv-name --session-id e2fa1afe
expect_name "argv -n wins over a registry chief name" "argv-name"

fake_registry "$(reg '"T3-chief"')"
fake_cmdline claude -n "bad/name"
expect_none "an invalid argv -n name does not fall back to the registry"

fake_registry "$(reg '"worker-1"')"
expect_none "registry: non-chief name (worker-1) refused"

fake_registry "$(reg '"T3 Code Chief Integration Route"')"
expect_none "registry: title with spaces refused"

fake_registry "$(reg '"Big Plan-chief"')"
expect_none "registry: chief-shaped title with a space refused"

fake_registry "$(reg '"a-chief\n"')"
expect_none "registry: chief name ending in a newline refused"

fake_registry "$(reg '"x/y-chief"')"
expect_none "registry: name with / refused"

fake_registry "$(reg '"..-chief"')"
expect_none "registry: name with .. refused"

fake_registry "$(reg '"*-chief"')"
expect_none "registry: name with * refused"

fake_registry "$(reg '"T3-chief"' cli)"
expect_none "registry: entrypoint other than t3-code refused"

fake_registry "$(reg '"T3-chief"' t3-code 54321)"
expect_none "registry: .pid mismatch refused"

fake_registry "$(reg '"T3-chief"' t3-code '"12345"')"
expect_none "registry: string .pid refused"

fake_registry "$(reg '["T3-chief"]')"
expect_none "registry: non-string name refused"

fake_registry "$(reg '"T3-chief"')" 99999999
expect_none "registry: start-time mismatch (reused pid) refused"

fake_registry '{"pid":12345,"entrypoint":"t3-code","name":"T3-chief"}'
expect_none "registry: no procStart while /proc stat is readable refused"

fake_registry '{"pid":12345,"entrypoint":"t3-code","name":"T3-chief",'
expect_none "registry: unparseable file refused"

fake_registry "$(reg '"T3-chief"')"
export SESSION_NAME_REGISTRY_FILE="$WORK/no-such-registry.json"
expect_none "registry: missing file refused"

fake_registry "$(reg '"T3-chief"')"
chmod 000 "$WORK/registry.json"
if [ -r "$WORK/registry.json" ]; then
    pass "registry: unreadable file (skipped: running as a user who can read mode 000)"
else
    expect_none "registry: unreadable file refused"
fi
chmod 600 "$WORK/registry.json"

fake_registry "$(reg '"T3-chief"')"
export CLAUDE_PID="12x45"
expect_none "registry: non-numeric CLAUDE_PID refused"

fake_registry "$(reg '"T3-chief"')"
export SESSION_NAME_CMDLINE_FILE="$WORK/no-such-cmdline"
expect_name "registry: an unreadable argv (no /proc) still reads the registry" "T3-chief"

fake_registry "$(reg '"T3-chief"')"
mkdir -p "$WORK/nojq"
for t in bash cat env; do ln -sf "$(command -v "$t")" "$WORK/nojq/$t"; done
out="$(PATH="$WORK/nojq" current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "registry: no jq on PATH is unresolvable, not an error"
else
    fail "registry: no jq on PATH (rc=$rc out='$out')"
fi

unset SESSION_NAME_REGISTRY_FILE SESSION_NAME_PROC_STAT_FILE

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
