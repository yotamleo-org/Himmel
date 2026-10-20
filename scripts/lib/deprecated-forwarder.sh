#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working.
# TEMPLATE for a renamed script (shape of scripts/clean-garden.sh):
# copy it to the OLD path, replace __OLD__ with the old script's name and
# __NEW__ with the new script's path relative to this file's directory, and
# drop this banner for a one-line note naming the replacement. It prints one
# stderr line, then runs the new script with the same argv, stdin and stdout;
# its exit code is the new script's. scripts/lib/test-deprecated-forwarder.sh
# proves the pass-through.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "__OLD__ is deprecated: use '__NEW__' instead" >&2
exec bash "$SCRIPT_DIR/__NEW__" "$@"
