#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-preflight.sh.
# The old path stays a registered chokepoint, so it runs the seam guard itself.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "bank-preflight.sh is deprecated: run 'usage-preflight.sh', do not source it" >&2
  return 2
fi
set -uo pipefail

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced or run.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "bank-preflight.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/lib/bank-preflight.sh || exit 96

echo "bank-preflight.sh is deprecated: use 'usage-preflight.sh' instead" >&2
exec bash "$_csg_dir/usage-preflight.sh" "$@"
