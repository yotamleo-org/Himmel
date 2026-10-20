#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Test for scripts/lib/env-value.sh (config, then discovery, then fail closed).
#
# Usage: bash scripts/lib/test-env-value.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/env-value.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$2' got '$3'"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h6508v.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.himmel"
export HOME="$tmp/home"

# shellcheck source=/dev/null
. "$LIB" || { echo "cannot source $LIB" >&2; exit 2; }

disc_ok() { printf 'discovered-value\n'; }
disc_empty() { :; }
disc_multiline() { printf 'line1\nline2\n'; }
disc_cr() { printf 'value\r\n'; }

echo "== config wins =="
printf '{"env_values":{"PAGES_URL":"https://configured.example/docs/"}}\n' > "$HOME/.himmel/config.json"
out=$(env_value PAGES_URL disc_ok); check "config beats discovery" "https://configured.example/docs/" "$out"

echo "== discovery when config lacks the key =="
out=$(env_value OTHER_KEY disc_ok); check "falls back to discovery" "discovered-value" "$out"

echo "== fail closed =="
out=$(env_value OTHER_KEY disc_empty); rc=$?
check "empty discovery prints nothing" "" "$out"; check "empty discovery rc" "1" "$rc"
out=$(env_value OTHER_KEY); rc=$?
check "no discovery prints nothing" "" "$out"; check "no discovery rc" "1" "$rc"
out=$(env_value OTHER_KEY disc_multiline); rc=$?
check "multiline discovery output prints nothing" "" "$out"; check "multiline discovery rc" "1" "$rc"
out=$(env_value OTHER_KEY disc_cr); rc=$?
check "carriage-return discovery output rc" "1" "$rc"

echo "== no environment seam =="
out=$(PAGES_URL=https://evil.example/ env_value OTHER_KEY disc_empty); rc=$?
check "ambient env var of the same name is ignored" "1" "$rc"
out=$(OTHER_KEY=https://evil.example/ env_value OTHER_KEY disc_empty); rc=$?
check "ambient env var named like the key is ignored" "1" "$rc"

echo "== unreadable or malformed config fails closed =="
printf '{not json\n' > "$HOME/.himmel/config.json"
out=$(env_value PAGES_URL disc_ok); rc=$?
check "malformed config does not fall through to discovery" "" "$out"; check "malformed config rc" "1" "$rc"
printf '{"env_values":{"PAGES_URL":["x"]}}\n' > "$HOME/.himmel/config.json"
out=$(env_value PAGES_URL disc_ok); rc=$?
check "non-string value fails closed" "1" "$rc"
printf '{"env_values":{"PAGES_URL":null}}\n' > "$HOME/.himmel/config.json"
out=$(env_value PAGES_URL disc_ok); rc=$?
check "explicit null does not fall through to discovery" "" "$out"; check "explicit null rc" "1" "$rc"
rm -f "$HOME/.himmel/config.json"
out=$(env_value PAGES_URL disc_ok); check "absent config file falls to discovery" "discovered-value" "$out"

echo "== bad key =="
out=$(env_value 'bad key' disc_ok); rc=$?
check "bad key rc" "1" "$rc"

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
