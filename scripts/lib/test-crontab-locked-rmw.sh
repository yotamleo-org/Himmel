#!/usr/bin/env bash
# test-crontab-locked-rmw.sh — scripts/lib/crontab-locked-rmw.sh.
# Hermetic: temp HOME, a stub crontab whose -l read is slow on demand. Never touches the real crontab.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/crmw-test.XXXXXX")" || exit 1
W="$(cd "$W" && pwd -P)" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
unset HIMMEL_CRONTAB_LOCK

# shellcheck source=crontab-locked-rmw.sh
. "$DIR/crontab-locked-rmw.sh" || { echo "FAIL source crontab-locked-rmw.sh"; exit 1; }

TAB="$W/tab"; export TAB
export W
# stub crontab: -l prints the table after STUB_READ_DELAY; - replaces it. Flags in $W force the failures.
cat > "$W/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
    [ -f "$W/fail-read" ] && { echo "crontab: Permission denied" >&2; exit 1; }
    [ -f "$W/none" ] && { echo "no crontab for tester" >&2; exit 1; }
    out="$(cat "$TAB")"
    [ -z "${STUB_READ_DELAY:-}" ] || sleep "$STUB_READ_DELAY"
    printf '%s\n' "$out"
else
    [ -f "$W/fail-write" ] && exit 1
    cat > "$TAB"
fi
SH
chmod +x "$W/crontab"
STUB="$W/crontab"

seed() { printf '0 1 * * * /other/job # HIMMEL-Other\n30 2 * * * /keep/me # HIMMEL-Keep\n' > "$TAB"; }
has() { grep -cxF -- "$1" "$TAB"; }

add_a() { { printf '%s\n' "$CRON_TAB"; echo "1 1 * * * a # HIMMEL-A"; } | sed '/^$/d'; }
add_b() { { printf '%s\n' "$CRON_TAB"; echo "2 2 * * * b # HIMMEL-B"; } | sed '/^$/d'; }
drop_keep() { printf '%s\n' "$CRON_TAB" | { grep -vF "# HIMMEL-Keep" || true; }; }
touch_marker() { : > "$W/edit-ran"; printf '%s\n' "$CRON_TAB"; }
refuse3() { echo "already armed" >&2; return 3; }

# Control: the unlocked sequence the cadence scripts used (read, edit, write, no lock).
unlocked() { # <edit-fn>
    CRON_TAB="$("$STUB" -l)"
    "$1" | "$STUB" -
}
seed
STUB_READ_DELAY=0.4 unlocked add_a & p1=$!
STUB_READ_DELAY=0.4 unlocked add_b & p2=$!
wait "$p1" "$p2"
lost=$(( 2 - $(has "1 1 * * * a # HIMMEL-A") - $(has "2 2 * * * b # HIMMEL-B") ))
check "control: the unlocked read-edit-write loses one of two concurrent changes" 1 "$lost"

# Head: the same two runs through the helper keep both changes and every unrelated line.
seed
STUB_READ_DELAY=0.4 crontab_locked_rmw "$STUB" add_a & p1=$!
STUB_READ_DELAY=0.4 crontab_locked_rmw "$STUB" add_b & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check "two concurrent runs both return 0" "0 0" "$r1 $r2"
check "concurrent add: change A kept" 1 "$(has "1 1 * * * a # HIMMEL-A")"
check "concurrent add: change B kept" 1 "$(has "2 2 * * * b # HIMMEL-B")"
check "concurrent add: unrelated line 1 kept" 1 "$(has "0 1 * * * /other/job # HIMMEL-Other")"
check "concurrent add: unrelated line 2 kept" 1 "$(has "30 2 * * * /keep/me # HIMMEL-Keep")"

# An add with a remove (an arm with a disarm).
seed
STUB_READ_DELAY=0.4 crontab_locked_rmw "$STUB" add_a & p1=$!
STUB_READ_DELAY=0.4 crontab_locked_rmw "$STUB" drop_keep & p2=$!
wait "$p1" "$p2"
check "add with remove: the add is kept" 1 "$(has "1 1 * * * a # HIMMEL-A")"
check "add with remove: the removed line is gone" 0 "$(has "30 2 * * * /keep/me # HIMMEL-Keep")"
check "add with remove: the unrelated line is kept" 1 "$(has "0 1 * * * /other/job # HIMMEL-Other")"

# A failed read writes nothing and never runs the edit.
seed; rm -f "$W/edit-ran"; touch "$W/fail-read"
crontab_locked_rmw "$STUB" touch_marker 2>/dev/null; rc=$?
rm -f "$W/fail-read"
check "failed read returns 4" 4 "$rc"
check "failed read leaves the table as it was" 2 "$(wc -l < "$TAB" | tr -d ' ')"
[ ! -e "$W/edit-ran" ] && pass "failed read never runs the edit" || fail "failed read never runs the edit"
crontab_locked_rmw "$STUB" add_a; check "the lock was released after the failed read" 0 "$?"

# "no crontab for <user>" is an empty table.
: > "$TAB"; touch "$W/none"
crontab_locked_rmw "$STUB" add_a; rc=$?
rm -f "$W/none"
check "no-crontab read still installs (rc 0)" 0 "$rc"
check "no-crontab read installs onto an empty table" 1 "$(has "1 1 * * * a # HIMMEL-A")"

# A failed write returns non-zero, and the lock is released.
seed; touch "$W/fail-write"
crontab_locked_rmw "$STUB" add_a 2>/dev/null; rc=$?
rm -f "$W/fail-write"
check "failed write returns 4" 4 "$rc"
crontab_locked_rmw "$STUB" add_b; check "the lock was released after the failed write" 0 "$?"

# An edit that refuses writes nothing and its code comes back.
seed
crontab_locked_rmw "$STUB" refuse3 2>/dev/null; rc=$?
check "edit refusal code is passed back" 3 "$rc"
check "edit refusal writes nothing" 2 "$(wc -l < "$TAB" | tr -d ' ')"

# A held lock makes the second run wait, not skip.
seed
mkdir -p "$HOME/.himmel/state"
with_lock "$HOME/.himmel/state/crontab.lock" sleep 1 & holder=$!
sleep 0.3
crontab_locked_rmw "$STUB" add_a & waiter=$!
sleep 0.3
if kill -0 "$waiter" 2>/dev/null; then pass "second run is still waiting while the lock is held"; else fail "second run is still waiting while the lock is held"; fi
check "second run has not written while the lock is held" 0 "$(has "1 1 * * * a # HIMMEL-A")"
n=0
while kill -0 "$waiter" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
wait "$waiter"; rc=$?
wait "$holder"
check "waiting run finishes once the lock frees (rc 0)" 0 "$rc"
check "waiting run then wrote its change" 1 "$(has "1 1 * * * a # HIMMEL-A")"

echo
[ "$FAILED" -eq 0 ] && echo "all passed" || echo "$FAILED failed"
[ "$FAILED" -eq 0 ]
