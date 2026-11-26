#!/usr/bin/env bash
# scripts/lanes/test-lane-parity-check.sh - paired suite of lane-parity-check.sh.
#
# Cases run the check against a fixture root: copies of the four wiring files
# and of docs/internals/lane-parity.md, mutated one way per case.
#   (a) the real tree passes
#   (b) a lane that lost a guard another lane has, the table still claiming it: FAIL
#   (c) negative control: the same loss with a recorded structural reason: PASS
#   (d) a cell with no recorded reason (bare word, empty reason): FAIL
#   (e) a guard wired on a lane with no table row: FAIL
#   (f) a recorded reason for a guard that is wired: FAIL
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUT="$HERE/lane-parity-check.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/lane-parity-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

WIRING="
.claude/settings.json
marketplace/plugins/himmel-ops/hooks/hooks.json
.codex/hooks.json
scripts/hooks/antigravity-hook-adapter.sh
docs/internals/lane-parity.md
"

fresh_root() {
    local r="$W/$1" f
    mkdir -p "$r"
    for f in $WIRING; do
        mkdir -p "$r/$(dirname "$f")"
        cp "$REPO/$f" "$r/$f"
    done
    printf '%s' "$r"
}

set_cell() {
    local doc="$1/docs/internals/lane-parity.md"
    awk -F'|' -v OFS='|' -v cap="$2" -v col="$3" -v txt="$4" '
        { c = $2; gsub(/[ `]/, "", c) }
        c == cap { $(col + 2) = " " txt " " }
        { print }
    ' "$doc" > "$doc.new" && mv "$doc.new" "$doc"
}

run() { bash "$SUT" --root "$1" 2>&1; }

out="$(bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "(a) real tree passes"; else fail "(a) real tree rc=$rc: $out"; fi

r="$(fresh_root b)"
sed 's/block-docker-privesc\.sh+//' "$r/.codex/hooks.json" > "$r/x" && mv "$r/x" "$r/.codex/hooks.json"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'block-docker-privesc' <<< "$out"; then
    pass "(b) lane missing a guard another has, no recorded reason: FAIL names the guard"
else
    fail "(b) rc=$rc out=$out"
fi

set_cell "$r" "guard:block-docker-privesc.sh" 2 "structural: fixture reason"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "(c) recorded structural reason passes"; else fail "(c) rc=$rc out=$out"; fi

r="$(fresh_root d)"
sed 's/block-docker-privesc\.sh+//' "$r/.codex/hooks.json" > "$r/x" && mv "$r/x" "$r/.codex/hooks.json"
set_cell "$r" "guard:block-docker-privesc.sh" 2 "gap"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "(d1) bare word cell fails"; else fail "(d1) rc=$rc out=$out"; fi
set_cell "$r" "guard:block-docker-privesc.sh" 2 "structural:"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "(d2) empty reason fails"; else fail "(d2) rc=$rc out=$out"; fi

r="$(fresh_root e)"
sed 's/block-docker-privesc\.sh+/block-docker-privesc.sh+zz-fixture-guard.sh+/' "$r/.codex/hooks.json" > "$r/x" && mv "$r/x" "$r/.codex/hooks.json"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'zz-fixture-guard' <<< "$out"; then
    pass "(e) wired guard with no row fails"
else
    fail "(e) rc=$rc out=$out"
fi

r="$(fresh_root f)"
set_cell "$r" "guard:block-docker-privesc.sh" 2 "structural: stale reason"
out="$(run "$r")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'block-docker-privesc' <<< "$out"; then
    pass "(f) reason recorded for a wired guard fails"
else
    fail "(f) rc=$rc out=$out"
fi

if [ "$fails" -eq 0 ]; then echo "test-lane-parity-check: all pass"; exit 0; fi
echo "test-lane-parity-check: $fails failed"
exit 1
