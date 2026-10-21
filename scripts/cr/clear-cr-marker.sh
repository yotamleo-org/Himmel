#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use clear-review-marker.sh.
# A relative entry still hands off to the anchor first, and the old path stays
# a registered chokepoint, so it runs the seam guard itself.
set -uo pipefail
# A relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/anchor-handoff.sh" || exit 2

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced or run.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "clear-cr-marker.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/cr/clear-cr-marker.sh || exit 96

echo "clear-cr-marker.sh is deprecated: use 'clear-review-marker.sh' instead" >&2
exec bash "$_csg_dir/clear-review-marker.sh" "$@"
