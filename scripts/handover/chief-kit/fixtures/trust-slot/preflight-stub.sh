#!/usr/bin/env bash
# Stands in for scripts/lib/usage-preflight.sh: prints the file PF_ERR on stderr and PF_OUT on stdout, exits PF_RC.
[ -z "${PF_ERR:-}" ] || cat "$PF_ERR" >&2
[ -z "${PF_OUT:-}" ] || cat "$PF_OUT"
exit "${PF_RC:-0}"
