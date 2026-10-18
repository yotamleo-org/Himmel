#!/usr/bin/env bash
# test-versionless-done.sh — versionless-done.sh counts, lists and backfills
# Done tickets with no fixVersion, against a stubbed jira CLI.
# No live Jira call. PLATFORM GUARD: no .ps1 twin, by design (Linux-only kit).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/versionless-done.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/versionless-done-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

cat > "$W/jira" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
    versions) [ "${STUB_VERSIONS_FAIL:-0}" = 1 ] && exit 1
              printf 'v1.0.0\ttrue\t2026-09-01\nv1.1.4\tfalse\t2026-11-01\nv1.1.3\tfalse\t2026-10-20\n' ;;
    list) [ "${STUB_LIST_FAIL:-0}" = 1 ] && exit 1
          cat "$STUB_ROWS" ;;
    edit) [ "$2" = "${STUB_EDIT_FAIL:-}" ] && exit 1 || exit 0 ;;
esac
STUB
chmod +x "$W/jira"
export HIMMEL_JIRA_CLI="bash $W/jira" STUB_LOG="$W/log" STUB_ROWS="$W/rows"
: > "$W/log"

: > "$W/rows"
check "clean project prints 0" 0 "$(bash "$SUT")"
check "clean project lists nothing" "" "$(bash "$SUT" --list)"

printf 'HIMMEL-1\tTask\tDone\tone\nHIMMEL-2\tBug\tDone\ttwo\n' > "$W/rows"
: > "$W/log"
check "seeded project counts 2" 2 "$(bash "$SUT")"
check "list names the seeded ticket" HIMMEL-2 "$(bash "$SUT" --list | cut -f1 | sed -n 2p)"
check "JQL asks for versionless Done since the last release" 2 \
    "$(grep -c 'list --jql project = HIMMEL AND status = Done AND fixVersion is EMPTY AND issuetype != Epic AND resolved >= "2026-09-01"' "$W/log")"

: > "$W/log"
out="$(bash "$SUT" --backfill)"
check "backfill without --apply names the earliest unreleased version" "would-set HIMMEL-1 v1.1.3
would-set HIMMEL-2 v1.1.3" "$out"
check "backfill without --apply writes nothing" 0 "$(grep -c '^edit ' "$W/log")"

: > "$W/log"
out="$(bash "$SUT" --backfill --apply)"
check "backfill --apply sets each ticket" "set HIMMEL-1 v1.1.3
set HIMMEL-2 v1.1.3" "$out"
check "backfill --apply adds, never replaces" 2 "$(grep -c '^edit HIMMEL-[12] --add-fix-version v1.1.3$' "$W/log")"

STUB_EDIT_FAIL=HIMMEL-1 bash "$SUT" --backfill --apply >/dev/null; check "a failed write exits 1" 1 $?

check "--apply alone is refused" 2 "$(bash "$SUT" --apply >/dev/null 2>&1; echo $?)"
check "a failed versions read is unknown" unknown "$(STUB_VERSIONS_FAIL=1 bash "$SUT")"
check "a failed list read is unknown" unknown "$(STUB_LIST_FAIL=1 bash "$SUT")"

STUB_LIST_FAIL=1 bash "$SUT" --backfill --apply >/dev/null; check "a failed read exits 1 in backfill mode" 1 $?

printf 'HIMMEL-3011\tTask\tDone\tx\nHIMMEL-1528\tTask\tDone\ty\nHIMMEL-5\tTask\tDone\tz\n' > "$W/rows"
check "the known no-PR closes are not counted" 1 "$(bash "$SUT")"
check "VERSIONLESS_DONE_EXCEPTIONS empty counts them" 3 "$(VERSIONLESS_DONE_EXCEPTIONS='' bash "$SUT")"

check "a full page reads as a lower bound" "3+" "$(VERSIONLESS_DONE_LIMIT=2 VERSIONLESS_DONE_EXCEPTIONS='' bash "$SUT")"
check "a full page of excluded tickets still reads as a lower bound" "1+" "$(VERSIONLESS_DONE_LIMIT=3 bash "$SUT")"
: > "$W/log"
VERSIONLESS_DONE_LIMIT=2VERSIONLESS_DONE_EXCEPTIONS='' bash "$SUT" --backfill --apply >/dev/null 2>&1; check "a truncated backfill exits 1" 1 $?

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
