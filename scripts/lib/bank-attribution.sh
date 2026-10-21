#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-attribution.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "bank-attribution.sh is deprecated: use 'usage-attribution.sh' instead" >&2
exec bash "$SCRIPT_DIR/usage-attribution.sh" "$@"
