#!/usr/bin/env bash
# scripts/lib/test-claude-version.sh - suite for scripts/lib/claude-version.sh and
# console_context_model_takes_1m_suffix.
#
# Fixtures: `claude --version` prints `2.1.296 (Claude Code)` on the station that
# wrote this (copied from the real binary, not hand-written); the stub claude
# below reproduces that shape with a version swapped in.
# shellcheck disable=SC2015,SC2016  # `A && ok || fail` is the suite's check idiom; the stub body is a literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-version-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# shellcheck source=claude-version.sh
. "$HERE/claude-version.sh"
# shellcheck source=chief-context.sh
. "$HERE/chief-context.sh"

# --- version parse + compare ---------------------------------------------------
check "bare: real --version shape" "$(claude_version_bare '2.1.296 (Claude Code)')" "2.1.296"
check "bare: npm view shape" "$(claude_version_bare '2.1.296')" "2.1.296"
check "bare: garbage -> empty" "$(claude_version_bare 'command not found')" ""
rc=0; claude_version_lt 2.1.279 2.1.280 || rc=$?; check "lt: 2.1.279 < 2.1.280" "$rc" "0"
rc=0; claude_version_lt 2.1.280 2.1.280 || rc=$?; check "lt: equal is not below" "$rc" "1"
rc=0; claude_version_lt 2.1.296 2.1.280 || rc=$?; check "lt: newer is not below" "$rc" "1"
rc=0; claude_version_lt 2.1.1000 2.1.280 || rc=$?; check "lt: numeric not lexical (1000 > 280)" "$rc" "1"
rc=0; claude_version_lt 2.0.999 2.1.0 || rc=$?; check "lt: minor dominates patch" "$rc" "0"
rc=0; claude_version_lt 2.1.280-rc1 2.1.280 || rc=$?; check "lt: prerelease below its release" "$rc" "0"
rc=0; claude_version_lt custom 2.1.280 || rc=$?; check "lt: non-numeric -> cannot compare (2)" "$rc" "2"
rc=0; claude_version_lt "" 2.1.280 || rc=$?; check "lt: empty -> cannot compare (2)" "$rc" "2"

# --- floor check against stub binaries -----------------------------------------
mkstub() { # <name> <output> [exit]
  printf '#!/bin/sh\n[ "$1" = "--version" ] && printf "%%s\\n" "%s"\nexit %s\n' "$2" "${3:-0}" > "$tmp/$1"
  chmod 755 "$tmp/$1"
}
mkstub old "2.1.200 (Claude Code)"
mkstub exact "2.1.280 (Claude Code)"
mkstub cur "2.1.296 (Claude Code)"
mkstub junk "not a version"
rc=0; claude_floor_check "$tmp/old" || rc=$?
check "floor: 2.1.200 is below (rc 1)" "$rc" "1"
check "floor: installed version recorded" "$CLAUDE_FLOOR_INSTALLED" "2.1.200"
rc=0; claude_floor_check "$tmp/exact" || rc=$?; check "floor: exactly the floor passes" "$rc" "0"
rc=0; claude_floor_check "$tmp/cur" || rc=$?; check "floor: 2.1.296 passes" "$rc" "0"
rc=0; claude_floor_check "$tmp/junk" || rc=$?; check "floor: unreadable version is rc 2, not a refusal" "$rc" "2"
rc=0; claude_floor_check "$tmp/absent" || rc=$?; check "floor: absent binary is rc 2" "$rc" "2"
msg="$(claude_floor_message 2.1.200)"
case "$msg" in *2.1.200*"$CLAUDE_MIN_VERSION"*"claude update"*) echo "ok - message names versions and the remedy" ;; *) echo "FAIL - message: [$msg]"; fails=$((fails+1)) ;; esac

# --- [1m] only where a model needs it ------------------------------------------
yes_model() { console_context_model_takes_1m_suffix "$2" && echo "ok - $1" || { echo "FAIL - $1: [$2] should take [1m]"; fails=$((fails+1)); }; }
no_model()  { console_context_model_takes_1m_suffix "$2" && { echo "FAIL - $1: [$2] must NOT take [1m]"; fails=$((fails+1)); } || echo "ok - $1"; }
yes_model "opus 4.6 full id"            claude-opus-4-6
yes_model "sonnet 4.6 full id"          claude-sonnet-4-6
yes_model "sonnet 4.6 mixed case"       Claude-Sonnet-4-6
no_model  "opus 5.5 is native 1M"       claude-opus-5-5
no_model  "opus alias is native 1M"     opus
no_model  "sonnet 5.5 is native 1M"     claude-sonnet-5-5
no_model  "haiku 5.5 is native 1M"      claude-haiku-5-5
no_model  "fable is native"             claude-fable-5-1
no_model  "gpt id never suffixed"       gpt-6-astra
no_model  "glm id never suffixed"       glm-5
no_model  "deepseek id never suffixed"  deepseek-v4
no_model  "slash id never suffixed"     anthropic/claude-opus-4-6
no_model  "non-claude id embedding the family" gpt-opus-4-6
no_model  "empty model"                 ""

[ "$fails" -eq 0 ] && echo "all passed" && exit 0
echo "$fails FAILED"; exit 1
