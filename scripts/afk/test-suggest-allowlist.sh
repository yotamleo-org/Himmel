#!/usr/bin/env bash
# Test for scripts/afk/suggest-allowlist.sh (AFK approvals slice 3, spec section 10).
#
# Fixture ledger: three `crontab -l` runs, one `pacman -Syu` run, plus rows the
# script must ignore (a refused run, an old run, a sudo-kind run, a request row).
# Asserts: one suggested class for crontab (count 3), pacman listed as
# "seen once, not suggested", varying ints and $HOME paths fold into typed
# slots, --since drops old rows, and the script changes no file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/suggest-allowlist.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}

TMP_ROOT=$(mktemp -d -t suggest-allowlist.XXXXXX) || exit 1
LEDGER="$TMP_ROOT/afk-sudo.jsonl"
FAKE_HOME="$TMP_ROOT/home/op"
mkdir -p "$FAKE_HOME"
now_ts=$(date -u +%FT%TZ)

run_row() { # <id> <run_as> <exit> <argv-json> [ts] [kind]
    printf '{"argv": %s, "duration_ms": 12, "event": "run", "exit": %s, "id": "%s", "kind": "%s", "result": "ran", "run_as": "%s", "ts": "%s"}\n' \
        "$4" "$3" "$1" "${6:-run}" "$2" "${5:-$now_ts}"
}
{
    run_row c0000001 root 0 '["/usr/bin/crontab", "-l"]'
    run_row c0000002 root 0 '["/usr/bin/crontab", "-l"]'
    run_row c0000003 root 1 '["/usr/bin/crontab", "-l"]'
    run_row p0000001 root 0 '["/usr/bin/pacman", "-Syu"]'
    # folds into one group: the int and the $HOME path vary
    run_row t0000001 op 0 "[\"/opt/fixture/bin/tailx\", \"-n\", \"20\", \"$FAKE_HOME/a.log\"]"
    run_row t0000002 op 0 "[\"/opt/fixture/bin/tailx\", \"-n\", \"50\", \"$FAKE_HOME/b.log\"]"
    # ignored: older than --since, a refused run, a sudo-kind run, a bare request row
    run_row o0000001 root 0 '["/usr/bin/crontab", "-l"]' 2020-01-01T00:00:00Z
    printf '{"event": "run", "id": "n0000001", "kind": "run", "result": "never-remote", "rule": "disk-wipe", "run_as": "root", "ts": "%s", "argv": ["/usr/bin/wipefs", "-a", "/dev/sda"]}\n' "$now_ts"
    run_row s0000001 root 0 '["/usr/bin/systemctl", "restart", "x.service"]' "$now_ts" sudo
    printf '{"event": "request", "id": "q0000001", "kind": "run", "result": "pending", "run_as": "root", "ts": "%s", "argv": ["/usr/bin/crontab", "-l"]}\n' "$now_ts"
} > "$LEDGER"

snapshot() { find "$TMP_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum; }

echo "TEST: fixture ledger suggests crontab once with count 3, pacman seen once"
before=$(snapshot)
out=$(HOME="$FAKE_HOME" AFK_SUDO_LEDGER="$LEDGER" bash "$SCRIPT" --since 30d)
assert_contains "crontab is a suggested class with its count" '"count": 3' "$out"
assert_contains "the suggested class names the argv" '"/usr/bin/crontab", "-l"' "$out"
assert_contains "the suggested class carries run_as" '"run_as": "root"' "$out"
assert_contains "exit codes are reported" '"exits": [0, 1]' "$out"
assert_contains "pacman is listed seen once, not suggested" "seen once, not suggested" "$out"
suggested=$(sed -n '/^suggested/,/^seen once/p' <<< "$out")
assert_contains "pacman sits under the seen-once heading" "/usr/bin/pacman -Syu" "$(sed -n '/^seen once/,$p' <<< "$out")"
assert_not_contains "pacman is not among the suggestions" "pacman" "$suggested"
# shellcheck disable=SC2016  # the $HOME is literal ledger text
assert_contains "a varying int and \$HOME path fold into typed slots" '"/opt/fixture/bin/tailx", "-n", "<int>", "<path under $HOME>"' "$out"
assert_not_contains "a run older than --since is not counted" '"count": 4' "$out"
assert_not_contains "a refused run is not suggested" "wipefs" "$out"
assert_not_contains "a sudo-kind run is not suggested" "systemctl" "$out"

echo "TEST: the script writes nothing"
after=$(snapshot)
if [ "$before" = "$after" ]; then pass "no file under the fixture root changed"; else fail "no file under the fixture root changed" "$(diff <(echo "$before") <(echo "$after") || true)"; fi

echo "TEST: --since narrows the window"
out=$(HOME="$FAKE_HOME" AFK_SUDO_LEDGER="$LEDGER" bash "$SCRIPT" --since 1d)
assert_contains "the 1-day window still counts three crontab runs" '"count": 3' "$out"
out=$(HOME="$FAKE_HOME" AFK_SUDO_LEDGER="$LEDGER" bash "$SCRIPT" --since 36500d)
assert_contains "a huge window also counts the old crontab run" '"count": 4' "$out"
if HOME="$FAKE_HOME" AFK_SUDO_LEDGER="$LEDGER" bash "$SCRIPT" --since nope >/dev/null 2>&1; then fail "a bad --since is refused"; else pass "a bad --since is refused"; fi

echo "TEST: an absent or empty ledger"
out=$(AFK_SUDO_LEDGER="$TMP_ROOT/none.jsonl" bash "$SCRIPT")
assert_contains "an absent ledger says so" "no ledger" "$out"
: > "$TMP_ROOT/empty.jsonl"
out=$(AFK_SUDO_LEDGER="$TMP_ROOT/empty.jsonl" bash "$SCRIPT")
assert_contains "an empty ledger suggests nothing" "no run in the window" "$out"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
