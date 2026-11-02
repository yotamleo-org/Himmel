#!/usr/bin/env bash
# Fixture-only checks of own-Results hand-off provenance and successor identity.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${WORKER_SUCCESSOR_LIB:-$HERE/worker-successor.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/worker-successor.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
fails=0; passes=0
check() {
    local got=""
    if [ -r "$SUT" ]; then got="$(bash -c '. "$1"; worker_named_successor "$2"' bash "$SUT" "$P")"; fi
    if [ "$got" = "$2" ]; then passes=$((passes + 1)); printf 'PASS: %s\n' "$1"
    else fails=$((fails + 1)); printf 'FAIL: %s (got [%s], want [%s])\n' "$1" "$got" "$2"; fi
}
P="$T/HIMMEL-9-N80-demo-2026-01-01.md"
B="$T/HIMMEL-9-N80b-demo-2026-01-01-RESUME.md"
C="$T/HIMMEL-9-N80c-demo-2026-01-01-RESUME.md"
printf '# successor\n' > "$B"
printf '# successor\n' > "$C"
record() { printf '# worker\n\n## Results\n\n%s\n' "$1" > "$P"; }
record "- 10:00 WRAPPED - context hand-off to $B"
check "own WRAPPED hand-off names successor" "$B"
record "- 10:00 BLOCKED - context 34 percent, RESUME written: $B"
check "legacy context BLOCKED names successor" "$B"
record "- 10:00 BLOCKED - context hand-off to $(basename "$B")"
check "basename references resolve beside the worker doc" "$B"
printf '# worker\n\n## Results\n\n- 10:00 WRAPPED - hand-off to %s\n- 11:00 LIVE - resumed\n- 12:00 WRAPPED - hand-off to %s\n' "$B" "$C" > "$P"
check "latest named successor wins, not file mtime" "$C"
record "- 10:00 LIVE - unfinished, next doc $B"
check "unfinished LIVE is no hand-off" ""
record "- 10:00 BLOCKED - waiting for $B"
check "a blocked dependency is no hand-off" ""
printf '# worker\n\n- 10:00 WRAPPED - hand-off to %s\n\n## Results\n\n- 11:00 LIVE - working\n' "$B" > "$P"
check "a brief bullet is not own Results evidence" ""
printf '# worker\n\n## Results\n\n- 10:00 BLOCKED - waiting\n\n## Notes\n\n- 11:00 WRAPPED - hand-off to %s\n' "$B" > "$P"
check "a Notes hand-off cannot authorize a close" ""
printf '# worker\n\n## Results\n\n- 10:00 BLOCKED - waiting\n\n## Chief Rulings\n\n- 10:30 [chief] WRAPPED - hand-off to %s\n' "$B" > "$P"
check "a mirrored ruling is not a worker marker" ""
printf '# worker\n\n## Results\n\n## Chief Rulings\n\n- 10:30 WRAPPED - hand-off to %s\n' "$B" > "$P"
check "own EOF append below ruling heading still counts" "$B"
OTHER="$T/HIMMEL-9-N81-demo-2026-01-01-RESUME.md"
printf '# other\n' > "$OTHER"
record "- 10:00 WRAPPED - hand-off to $OTHER"
check "another worker cannot supply successor evidence" ""
record "- 10:00 WRAPPED - hand-off to $T/elsewhere/$(basename "$B")"
check "an unrelated path with the same basename is not evidence" ""
record "- 10:00 WRAPPED - hand-off to $T/missing-RESUME.md"
check "a missing successor does not count" ""
P="$B"
record "- 10:00 WRAPPED - hand-off to $C"
check "a resumed worker names its newer successor, not its original" "$C"
record "- 10:00 WRAPPED - hand-off to $T/HIMMEL-9-N80-demo-2026-01-01.md"
check "a predecessor cannot be its successor" ""
printf '%s passed, %s failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
