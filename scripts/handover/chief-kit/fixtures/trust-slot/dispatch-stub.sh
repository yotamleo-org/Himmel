#!/usr/bin/env bash
# Stands in for next-dispatchable.sh --why --dispositions: prints the file DP_OUT, exits DP_RC.
[ -z "${DP_OUT:-}" ] || cat "$DP_OUT"
exit "${DP_RC:-0}"
