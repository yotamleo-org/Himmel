#!/usr/bin/env bash
# Pre-push floor for .single-writer repos
#
# WHY: luna and the handover state repos are private on the GitHub Free plan,
# so server-side branch protection is unavailable ("Upgrade to GitHub Pro").
# They commit straight to main by design, so check-push-target.sh (which
# refuses EVERY push to main) cannot be installed there. This is the floor
# that fits: a push to main may fast-forward, but may not rewrite or delete it.
#
#   - non-fast-forward push to main  -> refused (check-no-force-push.sh)
#   - delete of main (`push origin :main`) -> refused here; check-no-force-push
#     deliberately skips deletions and check-main-ref-transaction ignores them.
#
# Stdin is git's pre-push contract: "<local_ref> <local_sha> <remote_ref>
# <remote_sha>" per line. Exit 1 = refuse, 0 = allow.
# Security fence: fails CLOSED (a refusal is exit 1). No bypass, matching check-no-force-push.sh's main refusal: a deliberate
# rewrite means removing the installed pre-push hook by hand.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A missing lib would leave is_main_ref undefined and every delete skipped:
# test readability first, never `. lib || ...` (bash 3.2 exits on a failed `.`).
lib="$SCRIPT_DIR/../guardrails/lib.sh"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091,SC1090
if ! { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then
    echo "ERROR: single-writer floor cannot load $lib -- REFUSING this push." >&2
    cat >/dev/null
    exit 1
fi

lines=$(cat) || { echo "ERROR: single-writer floor could not read the push list -- REFUSING this push." >&2; exit 1; }
refuse=0

while IFS=' ' read -r _local_ref local_sha remote_ref _remote_sha; do
    [ -n "${remote_ref:-}" ] || continue
    is_main_ref "$remote_ref" || continue
    case "$local_sha" in
        ''|*[!0]*) continue ;;   # not a delete
    esac
    cat >&2 <<EOF
ERROR: Deleting '${remote_ref#refs/heads/}' on the remote is not allowed (single-writer floor, HIMMEL-5284).
       This repo has no server-side branch protection; this hook is the floor.
EOF
    refuse=1
done <<EOF_LINES
$lines
EOF_LINES

if [ "$refuse" -eq 0 ]; then
    bash "$SCRIPT_DIR/check-no-force-push.sh" <<EOF_LINES
$lines
EOF_LINES
    refuse=$?
fi

[ "$refuse" -eq 0 ] || exit 1
exit 0
