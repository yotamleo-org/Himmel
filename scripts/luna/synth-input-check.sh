#!/usr/bin/env bash
# Usage:
#   synth-input-check.sh [vault-root] [stamp-file]   -> print NEW | NONE
#   synth-input-check.sh --stamp [vault-root] [stamp-file]
#                                                   -> record "a leg completed"
# The runner calls it as `synth-input-check.sh .` because it has already cd'd
# into the vault: the cadence crosses a cmd.exe -> bash boundary on Windows,
# where a Windows-form path (C:\...) reaching a bash argument has its
# backslashes eaten as escapes. `.` is the one spelling that is correct in both
# shells. The stamp defaults inside the vault for the same reason -- no second
set -u

STAMP_MODE=0
if [ "${1:-}" = "--stamp" ]; then
    STAMP_MODE=1
    shift
fi

VAULT="${1:-.}"
STAMP="${2:-$VAULT/Clippings/_synthesis/.cadence-last-synth}"
PENDING="$STAMP.pending"

emit() { printf '%s\n' "$1"; exit 0; }

_stamp_dir() {
    _dir=${STAMP%/*}
    [ "$_dir" = "$STAMP" ] || mkdir -p "$_dir" 2>/dev/null
}

if [ "$STAMP_MODE" -eq 1 ]; then
    _stamp_dir
    if [ -f "$PENDING" ] && mv -f "$PENDING" "$STAMP" 2>/dev/null; then
        echo "synth-input-check: stamped $STAMP (at the gate instant, not leg end)" >&2
    else
        echo "synth-input-check: no pending gate mark — reference left unchanged (next run re-checks against the previous stamp / newest synthesis page)" >&2
    fi
    exit 0
fi

_stamp_dir
date -u +%Y-%m-%dT%H:%M:%SZ > "$PENDING" 2>/dev/null || true

command -v find >/dev/null 2>&1 || {
    echo "synth-input-check: find(1) missing — cannot decide, proceeding" >&2
    emit NEW
}

CLIPS="$VAULT/Clippings"
if [ ! -d "$CLIPS" ]; then
    echo "synth-input-check: no $CLIPS — nothing to synthesize" >&2
    emit NONE
fi

REF=""
REF_KIND=""
if [ -f "$STAMP" ]; then
    REF="$STAMP"
    REF_KIND="last completed leg"
else
# shellcheck disable=SC2012
    _newest=$(ls -t "$CLIPS/_synthesis"/*.md 2>/dev/null | head -1)
    if [ -n "$_newest" ] && [ -f "$_newest" ]; then
        REF="$_newest"
        REF_KIND="newest synthesis page"
    fi
fi

_find_rc=0
if [ -n "$REF" ]; then
    _candidates=$(find "$CLIPS" -maxdepth 1 -type f -name '*.md' -newer "$REF" 2>/dev/null) || _find_rc=$?
else
    REF_KIND="no reference — every triaged clip counts"
    _candidates=$(find "$CLIPS" -maxdepth 1 -type f -name '*.md' 2>/dev/null) || _find_rc=$?
fi
if [ "$_find_rc" -ne 0 ]; then
    echo "synth-input-check: find failed (rc=$_find_rc) — cannot decide, proceeding" >&2
    emit NEW
fi

# The status is set ONLY in END. A bare `exit` in a rule runs END, and an
# `exit <n>` there overrides whatever the rule asked for — so `exit 0` in the
# match rule would be silently rewritten to END's status. Flag, then decide once.
# awk's own fatal-error status is 2 in gawk/mawk/BSD awk, and a missing awk
# gives 127; anything above 1 is therefore "did not answer", not "answered no".
is_triaged() {
    [ -r "$1" ] || return 2
    awk '
        NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { n = 1; next } exit }
        n == 1 && /^---[[:space:]]*$/ { exit }
        n == 1 && /^triaged_at:/ { found = 1; exit }
        END { exit !found }
    ' "$1" 2>/dev/null
    _awk_rc=$?
    [ "$_awk_rc" -le 1 ] || return 2
    return "$_awk_rc"
}
_found=""
_unreadable=""
while IFS= read -r _clip; do
    [ -n "$_clip" ] || continue
    is_triaged "$_clip"
    case $? in
        0) _found="$_clip"; break ;;
        2) _unreadable="$_clip"; break ;;
    esac
done <<EOF
$_candidates
EOF
if [ -n "$_unreadable" ]; then
    echo "synth-input-check: could not inspect $_unreadable — cannot decide, proceeding" >&2
    emit NEW
fi

echo "synth-input-check: reference=${REF:-none} (${REF_KIND})" >&2
if [ -n "$_found" ]; then
    echo "synth-input-check: new triaged input since the reference (first: $_found)" >&2
    emit NEW
fi
echo "synth-input-check: no triaged clip newer than the reference — skipping the leg" >&2
emit NONE
