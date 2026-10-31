#!/usr/bin/env bash
# scripts/lib/test-resolve-user-home.sh — unit tests for resolve-user-home.sh.
#
# Covers resolve_user_home + default_vault, extracted
# verbatim from scripts/luna/pipeline-cadence.sh. Pins
# the fallback chain: LUNA_VAULT_PATH override wins over everything; plain
# $HOME next; /tmp as the last-resort floor when it is unset. Never touches the
# real HOME/LUNA_VAULT_PATH — every
# case runs in a subshell with its own env so it cannot leak into (or read
# from) the operator's real environment or the live luna vault.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/resolve-user-home.sh
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
. "$SCRIPT_DIR/resolve-user-home.sh"

pass=0
fail=0

# assert_eq <desc> <got> <expected>
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  ok: $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL: $desc"
    echo "        want: [$want]"
    echo "        got:  [$got]"
  fi
}

echo "[test-resolve-user-home] resolve_user_home"

# $HOME is the answer.
assert_eq "plain \$HOME" \
  "$(HOME=/home/posixuser bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; resolve_user_home')" \
  '/home/posixuser'

# HOME unset -> /tmp last-resort floor.
assert_eq "HOME unset: /tmp floor" \
  "$(env -u HOME bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; resolve_user_home')" \
  '/tmp'

echo "[test-resolve-user-home] default_vault"

# LUNA_VAULT_PATH set -> wins outright, no home resolution involved.
assert_eq "LUNA_VAULT_PATH override wins" \
  "$(LUNA_VAULT_PATH=/some/other/vault HOME=/home/whoever default_vault)" \
  '/some/other/vault'

# LUNA_VAULT_PATH unset -> falls back to <home>/Documents/luna via
# resolve_user_home (plain $HOME branch here — the resolver itself is
# covered above).
assert_eq "no LUNA_VAULT_PATH: falls back to <home>/Documents/luna" \
  "$(env -u LUNA_VAULT_PATH HOME=/home/posixuser bash -c '. "'"$SCRIPT_DIR"'/resolve-user-home.sh"; default_vault')" \
  '/home/posixuser/Documents/luna'

echo
echo "[test-resolve-user-home] pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
