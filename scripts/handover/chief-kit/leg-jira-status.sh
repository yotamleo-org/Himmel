#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use worker-jira-status.sh.
if (return 0 2>/dev/null); then
  echo "leg-jira-status.sh is deprecated: run 'worker-jira-status.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac
echo "leg-jira-status.sh is deprecated: use 'worker-jira-status.sh' instead" >&2
exec bash "$SCRIPT_DIR/worker-jira-status.sh" "$@"
