#!/usr/bin/env bash
# Test driver, not shipped logic: sources lib.sh and runs one named lib function the way a
# subcommand would, so the suite can exercise rs_tg and friends without a subcommand.
# shellcheck source=/dev/null
. "${RS_LIB:?RS_LIB must name lib.sh}"
rs_begin drive "run one lib function"
# shellcheck disable=SC2034  # read by rs_tg in the sourced lib
RS_TOKEN=${DRIVE_TOKEN:-}
"$@"
rs_done "drive finished"
