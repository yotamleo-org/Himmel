#!/usr/bin/env bash
# The test-uninstall suite's own HOME-isolation preflight (the
# real-home-under-$TMP check + the live-operator-marker check, run before the
# hermetic PATH is built) must HARD-ABORT the suite when either check fails —
# not just log a FAIL and fall through to the wet uninstall.sh rows below it.
# A soft fail there is the exact hazard this ticket exists to close: the
# suite's only independent protection would report a problem and then run
# the wet removals anyway.
#
# Static inspection only (per the ticket's harness-safety note) — this never
# invokes uninstall.sh and never runs a wet row.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/tests/testlib-uninstall.sh"
PARTS=("$HERE/test-uninstall.sh" "$HERE/test-uninstall-b.sh")
FAILED=0

# The preflight lives in the shared lib every part sources before its first case.
realhome_line=$(grep -n "operator's real .*HOME resolved under this suite" "$LIB" | head -1 | cut -d: -f1)
preflight_line=$(grep -n 'suite HOME fixture carries no live-operator marker' "$LIB" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # literal $CLI text in the source file, not expansion
lib_cli_line=$(grep -n 'bash "\$CLI"' "$LIB" | head -1 | cut -d: -f1)

if [ -z "$realhome_line" ] || [ -z "$preflight_line" ]; then
    echo "FAIL could not locate the real-\$HOME-under-\$TMP check or the live-operator-marker check in $LIB"
    FAILED=$((FAILED + 1))
else
    abort_line=$(awk -v lo="$preflight_line" \
        'NR > lo && /FAILED" -gt 0/ {print NR; exit}' "$LIB")
    if [ -n "$abort_line" ]; then
        # exit 1 must appear within the next 4 lines — i.e. inside the SAME
        # `if [ "$FAILED" -gt 0 ]; then ... fi` block, not some unrelated
        # later exit that would let this test PASS without the abort existing.
        exit_after=$(awk -v start="$abort_line" \
            'NR > start && NR <= start + 4 && /exit 1/ {print NR; exit}' "$LIB")
    fi
    if [ "$preflight_line" -le "$realhome_line" ]; then
        echo "FAIL the live-operator-marker check (line $preflight_line) does not follow the real-\$HOME-under-\$TMP check (line $realhome_line)"
        FAILED=$((FAILED + 1))
    elif [ -n "$lib_cli_line" ] && [ "$lib_cli_line" -lt "${exit_after:-0}" ]; then
        echo "FAIL the shared lib runs uninstall.sh (line $lib_cli_line) before its HOME-isolation abort (line ${exit_after:-none})"
        FAILED=$((FAILED + 1))
    elif [ -n "${abort_line:-}" ] && [ -n "${exit_after:-}" ]; then
        echo "PASS a HOME-isolation preflight failure aborts (line $abort_line of the shared lib) before any uninstall.sh invocation"
    else
        echo "FAIL no hard abort immediately following the HOME-isolation preflight (line $realhome_line) — a failed preflight falls through to a wet row"
        FAILED=$((FAILED + 1))
    fi
fi

# Every part must source that lib before its first uninstall.sh invocation.
for part in "${PARTS[@]}"; do
    source_line=$(grep -n '^\. .*tests/testlib-uninstall\.sh' "$part" | head -1 | cut -d: -f1)
    # shellcheck disable=SC2016 # literal $CLI text in the source file, not expansion
    first_cli_line=$(grep -n 'bash "\$CLI"' "$part" | head -1 | cut -d: -f1)
    if [ -n "$source_line" ] && [ -n "$first_cli_line" ] && [ "$source_line" -lt "$first_cli_line" ]; then
        echo "PASS ${part##*/} sources the preflight lib (line $source_line) before its first uninstall.sh invocation (line $first_cli_line)"
    else
        echo "FAIL ${part##*/} does not source the preflight lib (line ${source_line:-none}) before its first uninstall.sh invocation (line ${first_cli_line:-none})"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
