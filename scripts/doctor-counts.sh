#!/usr/bin/env bash
# doctor-counts.sh — the one writer of the statusline's doctor counts file.
# Sourced by himmel-doctor.sh (full runs only) and
# doctor-cadence.sh. The HUD segment (scripts/statusline/hud-custom-lines.sh)
# reads `<state dir>/counts` and shows its mtime age once it is over 24 h.
#
#   doctor_counts_write <state-dir> <fail> <warn>
#
# Atomic (tmp in the same dir, then mv) so a HUD read never sees a torn file.
# Returns non-zero on any failure; callers treat that as best-effort.
# bash 3.2-safe; sourced, no side effects.
# shellcheck source=lib/prim.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/prim.sh" || return 1

doctor_counts_write() {
    local dir="${1:-}" f="${2:-}" w="${3:-}"
    [ -n "$dir" ] || return 2
    case "$f" in ''|*[!0-9]*) return 2 ;; esac
    case "$w" in ''|*[!0-9]*) return 2 ;; esac
    mkdir -p "$dir" || return 1
    printf 'fail=%s warn=%s\n' "$f" "$w" | atomic_write "$dir/counts" || return 1
    return 0
}

# doctor_state_publish <state-dir> <keys-file> <fail> <warn>
# One run's published state: last.tsv ("<SEV> <id>" per FAIL/WARN, sorted
# unique, atomic) and the counts file, written together so they always come
# from the same run. Callers: a full himmel-doctor run on the primary
# checkout, and doctor-cadence.
doctor_state_publish() {
    local dir="${1:-}" keys="${2:-}" f="${3:-}" w="${4:-}" out
    [ -n "$dir" ] && [ -f "$keys" ] || return 2
    mkdir -p "$dir" || return 1
    if out="$(sed '/^$/d' "$keys" | sort -u && printf x)" && printf '%s' "${out%x}" | atomic_write "$dir/last.tsv"; then
        doctor_counts_write "$dir" "$f" "$w"
        return $?
    fi
    return 1
}
