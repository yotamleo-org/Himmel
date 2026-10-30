#!/usr/bin/env bash
# Marker assertion for the premium himmel_agent SOUL asset (WS5 Task 4 / T11):
# it carries the GPT-anatomy markers (a precedence-ladder block AND XML spec
# tags) and none of the open-model markers (a "Context budget:" line or a
# fenced JSON contract block).
#
# Platform guard: the hermes asset layout this script
# resolves against is exercised under MSYS / Git Bash. On any non-MINGW /
# non-MSYS shell the script SKIPs (exit 0) so a POSIX-only CI runner does
# not false-fail; the header comment is the durable "gitbash-only" note.
# Run with: bash scripts/hermes/test-soul-markers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREMIUM="$SCRIPT_DIR/assets/himmel-agent.SOUL.md"

case "${MSYSTEM:-}" in
    MINGW* | MSYS*) : ;; # Git Bash -- run.
    *)
        echo "SKIP: test-soul-markers.sh is gitbash-only (MSYSTEM=${MSYSTEM:-unset})."
        exit 0
        ;;
esac

[ -f "$PREMIUM" ] || { echo "FAIL: premium SOUL asset absent: $PREMIUM" >&2; exit 1; }

fails=0
# has <label> <file> <pattern>  -- fixed-string grep; counts a fail if absent.
has() {
    if grep -qF -- "$3" "$2"; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1 (missing in $(basename "$2"))" >&2
        fails=$((fails + 1))
    fi
}
# lacks <label> <file> <pattern> -- fixed-string grep; counts a fail if present.
lacks() {
    if grep -qF -- "$3" "$2"; then
        echo "  FAIL: $1 (unexpectedly present in $(basename "$2"))" >&2
        fails=$((fails + 1))
    else
        echo "  ok: $1"
    fi
}

echo "== premium SOUL: GPT-anatomy markers present =="
has "premium has precedence-ladder"       "$PREMIUM" "Precedence ladder"
has "premium has spec-tag open"           "$PREMIUM" "<spec>"
has "premium has spec-tag close"          "$PREMIUM" "</spec>"

echo "== premium SOUL: open-model markers absent =="
lacks "premium lacks Context budget"      "$PREMIUM" "Context budget:"
lacks "premium lacks JSON contract block" "$PREMIUM" '```json'

if [ "$fails" -eq 0 ]; then
    echo "PASS: premium soul markers as specified"
    exit 0
fi
echo "FAIL: $fails marker assertion(s) failed" >&2
exit 1
