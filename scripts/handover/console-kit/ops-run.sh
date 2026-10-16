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
# <fact> is ONLY a fixed verdict phrase the script's last line starts with
# (READY-CHECK PASS|FAIL, COVERAGE-LINT PASS|FAIL, HANDLED, ESCALATE, CLOSABLE,
# WITHHELD); everything after the phrase is dropped. Any other last line may
# carry PR or leg text, which must never ride a relay line, so the fact is
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
OUT_DIR="${OPS_OUT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/himmel-ops-$(id -u)}"

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

[ -L "$OUT_DIR" ] && refuse "out-dir-is-symlink"
[ -d "$OUT_DIR" ] || mkdir -m 700 "$OUT_DIR" || refuse "no-out-dir"
[ -O "$OUT_DIR" ] && [ ! -L "$OUT_DIR" ] || refuse "out-dir-not-ours"
out="$(mktemp "$OUT_DIR/$name.XXXXXX")" || refuse "no-out-file"

case "$name" in
    *.mjs) timeout --kill-after=5 "${OPS_TIMEOUT:-300}" node "$dir/$name" "$@" >"$out" 2>&1 ;;
    *)     timeout --kill-after=5 "${OPS_TIMEOUT:-300}" bash "$dir/$name" "$@" >"$out" 2>&1 ;;
esac
rc=$?

case "$rc" in
    0) verdict=PASS ;;
    10) verdict=ESCALATE ;;
    124|137) verdict=TIMEOUT ;;
    *) verdict=FAIL ;;
esac

last="$(grep -v '^[[:space:]]*$' "$out" | tail -n 1 | tr -d '\000-\010\013-\037')"
fact="$(printf '%s' "$last" | sed -E -n 's/^((READY-CHECK|COVERAGE-LINT) (PASS|FAIL)|HANDLED|ESCALATE|CLOSABLE|WITHHELD)([^A-Za-z0-9_-].*)?$/\1/p')"
[ -n "$fact" ] || fact="see out file"

echo "OPS $name rc=$rc $verdict out=$out :: $fact"
exit "$rc"
