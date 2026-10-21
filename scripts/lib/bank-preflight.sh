#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-preflight.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "bank-preflight.sh is deprecated: use 'usage-preflight.sh' instead" >&2
exec bash "$SCRIPT_DIR/usage-preflight.sh" "$@"
