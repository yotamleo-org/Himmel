#!/usr/bin/env bash
# scripts/handover/console-kit/ops-run.sh - run ONE mechanical console-kit script
# for the console and hand back ONE verdict line. The ops lane (the relay role,
# docs/internals/console-ops-lane.md) runs this instead of the console running
# the script in the foreground (blocks every leg message) or the background
# (three full-context turns per launch).
#
# Usage: ops-run.sh <script> [args...]
#
# Output (stdout, exactly one line):
#   OPS <script> rc=<n> <PASS|FAIL|ESCALATE|TIMEOUT> out=<file> :: <fact>
#   OPS <script> rc=2 REFUSED <reason>
# <fact> is the script's last output line ONLY when it is an upper-case verdict
# token line (READY-CHECK PASS, CLOSABLE: ..., HANDLED ...); any other last line
# may carry PR or leg text, which must never ride a relay line, so the fact is
# `see out file`. The full output is in <file>. rc: the script's own; 124 on
# timeout; 2 refused/usage.
#
# What it never runs: go.sh, verdict-go.sh, write-verdict.sh, inbox-send.sh,
# relay-batch.sh, anything that mints, rotates, quotes or adopts a token, writes
# a GO or rules. `action-zero.sh --acquire` is refused: a lock the ops session
# took would belong to the ops session, not the console. The script name is a
# basename on the allowlist below; a path, `..` or an unlisted name is REFUSED
# before anything runs.
#
# Seams (tests): OPS_KIT_DIR (script dir), OPS_OUT_DIR (full-output dir),
# OPS_TIMEOUT (seconds, default 300).
# Platform guard: Linux bash 3.2+ (timeout from coreutils; node for board.mjs).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="${OPS_KIT_DIR:-$HERE}"
OUT_DIR="${OPS_OUT_DIR:-${TMPDIR:-/tmp}/himmel-ops}"

[ "$#" -ge 1 ] || { echo "usage: ops-run.sh <script> [args...]" >&2; exit 2; }
name="$1"; shift

refuse() { echo "OPS $name rc=2 REFUSED $1"; exit 2; }

case "$name" in
    ready-check.sh|close-wrapped-leg.sh|leg-event.sh|wrap-merged.sh|action-zero.sh|next-dispatchable.sh|board.mjs|check-ci.sh) ;;
    *) refuse "not-on-allowlist" ;;
esac
if [ "$name" = "action-zero.sh" ]; then
    for a in "$@"; do [ "$a" = "--acquire" ] && refuse "action-zero --acquire (a lock would be the ops session's)"; done
fi
dir="$KIT"
[ "$name" = "check-ci.sh" ] && dir="${OPS_CI_DIR:-$HERE/../..}"
[ -f "$dir/$name" ] || refuse "script-missing"

mkdir -p "$OUT_DIR" || refuse "no-out-dir"
out="$OUT_DIR/$(date +%Y%m%dT%H%M%S)-$$-$name.out"

case "$name" in
    *.mjs) timeout "${OPS_TIMEOUT:-300}" node "$dir/$name" "$@" >"$out" 2>&1 ;;
    *)     timeout "${OPS_TIMEOUT:-300}" bash "$dir/$name" "$@" >"$out" 2>&1 ;;
esac
rc=$?

case "$rc" in
    0) verdict=PASS ;;
    10) verdict=ESCALATE ;;
    124) verdict=TIMEOUT ;;
    *) verdict=FAIL ;;
esac

last="$(grep -v '^[[:space:]]*$' "$out" | tail -n 1 | tr -d '\000-\010\013-\037')"
if printf '%s' "$last" | grep -Eq '^[A-Z][A-Z0-9_-]{2,}([: ]|$)'; then
    fact="$(printf '%s' "$last" | cut -c1-160)"
else
    fact="see out file"
fi

echo "OPS $name rc=$rc $verdict out=$out :: $fact"
exit "$rc"
