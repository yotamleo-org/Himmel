#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-monitor.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "bank-monitor.sh is deprecated: use 'usage-monitor.sh' instead" >&2
exec bash "$SCRIPT_DIR/usage-monitor.sh" "$@"
