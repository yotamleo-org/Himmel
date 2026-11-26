#!/usr/bin/env bash
# Stands in for next-dispatchable.sh --why --dispositions: prints the file DP_OUT, exits DP_RC.
[ -z "${DP_OUT:-}" ] || cat "$DP_OUT"  # read-sink-ok: a test stub; the suite names its own fixture file
exit "${DP_RC:-0}"
