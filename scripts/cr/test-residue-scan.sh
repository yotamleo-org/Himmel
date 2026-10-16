#!/usr/bin/env bash
# scripts/cr/test-residue-scan.sh - one fixture diff per residue class (a-e),
# a clean diff and a waiver diff for scripts/cr/residue-scan.sh. Hermetic.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/residue-scan.sh"
FX="$HERE/testdata/residue-scan"
fails=0

check() {
    if [ "$2" = "$3" ]; then echo "ok - $1"; else
        echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

scan() { bash "$SCAN" --diff-file "$FX/$1"; }
count_class() { printf '%s\n' "$1" | grep -c "^  - \[$2\] "; }
count_all() { printf '%s\n' "$1" | grep -c '^  - \['; }

for c in a:a-removal-guard b:b-source-grep c:c-transition-code d:d-transition-gate e:e-transition-prose; do
    cls="${c%%:*}"; f="${c#*:}"
    out="$(scan "$f.diff")"; rc=$?
    check "class $cls: exit 0 (advisory)" "$rc" "0"
    check "class $cls: one finding of class $cls" "$(count_class "$out" "$cls")" "1"
    check "class $cls: total findings 1" "$(count_all "$out")" "1"
done

summary0='residue-scan (advisory): 0 finding(s)'

out="$(scan clean.diff)"; rc=$?
check "clean: exit 0" "$rc" "0"
check "clean: no finding" "$(count_all "$out")" "0"
check "clean: summary line" "$(printf '%s\n' "$out" | grep -cF "$summary0")" "1"

out="$(scan waived.diff)"; rc=$?
check "waived: exit 0" "$rc" "0"
check "waived (ponytail / residue-keep): no finding" "$(count_all "$out")" "0"
check "waived: summary line" "$(printf '%s\n' "$out" | grep -cF "$summary0")" "1"

out="$(timeout 10 bash "$SCAN" --diff-file </dev/null)"; rc=$?
check "--diff-file with no value: terminates, exit 0" "$rc" "0"

out="$(scan a-removal-guard.diff)"
check "finding names file:line" "$(printf '%s\n' "$out" | grep -c 'scripts/lanes/test-spawn.sh:21')" "1"

out="$(bash "$SCAN" --diff-file "$FX/does-not-exist.diff")"; rc=$?
check "unreadable diff: exit 0" "$rc" "0"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
