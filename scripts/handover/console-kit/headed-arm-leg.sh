#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use headed-arm-worker.sh.
if (return 0 2>/dev/null); then
  echo "headed-arm-leg.sh is deprecated: run 'headed-arm-worker.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac
echo "headed-arm-leg.sh is deprecated: use 'headed-arm-worker.sh' instead" >&2
exec bash "$SCRIPT_DIR/headed-arm-worker.sh" "$@"
