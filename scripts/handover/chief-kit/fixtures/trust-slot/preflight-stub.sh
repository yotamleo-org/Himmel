#!/usr/bin/env bash
# Stands in for scripts/lib/usage-preflight.sh: prints the file PF_ERR on stderr and PF_OUT on stdout, exits PF_RC.
[ -z "${PF_ERR:-}" ] || cat "$PF_ERR" >&2  # read-sink-ok: a test stub; the suite names its own fixture file
[ -z "${PF_OUT:-}" ] || cat "$PF_OUT"  # read-sink-ok: a test stub; the suite names its own fixture file
exit "${PF_RC:-0}"
