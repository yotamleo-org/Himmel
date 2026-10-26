#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use worker-event.sh.
if (return 0 2>/dev/null); then
  echo "leg-event.sh is deprecated: run 'worker-event.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "leg-event.sh was renamed to worker-event.sh; legacy names are off" >&2
    exit 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac
echo "leg-event.sh is deprecated: use 'worker-event.sh' instead" >&2
exec bash "$SCRIPT_DIR/worker-event.sh" "$@"
