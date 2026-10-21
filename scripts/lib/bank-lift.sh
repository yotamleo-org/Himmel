#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-lift.sh.
# Run directly it prints one stderr line and runs usage-lift.sh with the same
# argv. Sourced it loads usage-lift.sh and keeps the old function names, with
# BANK_LIFT_REASON and BANK_LIFT_STANDING copied from the USAGE_LIFT_* pair.

_BL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "bank-lift.sh is deprecated: use 'usage-lift.sh' instead" >&2
  exec bash "$_BL_DIR/usage-lift.sh" "$@"
fi

# shellcheck source=usage-lift.sh
# shellcheck disable=SC1091
. "$_BL_DIR/usage-lift.sh"

bank_lift_file() { usage_lift_file; }
bank_lift_valid() {
  local rc=0
  usage_lift_valid "$@" || rc=$?
  # shellcheck disable=SC2034 # read by old callers after the call
  BANK_LIFT_REASON="$USAGE_LIFT_REASON"
  # shellcheck disable=SC2034 # read by old callers after the call
  BANK_LIFT_STANDING="$USAGE_LIFT_STANDING"
  return "$rc"
}
_bank_lift_cmd() { _usage_lift_cmd "$@"; }
