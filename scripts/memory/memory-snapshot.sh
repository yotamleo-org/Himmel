#!/usr/bin/env bash
# Conflict-aware snapshot and rollback of the auto-memory store (himmel-ops:
# memory-compound runs it around every compaction pass).
#
#   memory-snapshot.sh take    <dir>                       copy the store into <dir>
#   memory-snapshot.sh verify  <dir>                       diff the live store against <dir>
#   memory-snapshot.sh restore <before-dir> --expect <checkpoint-dir>
#
# The live store is $MEMDIR, else the derived per-project memory dir
# (scripts/lib/memory-slug.sh). A snapshot is every top-level regular file of
# the store plus .snapshot-manifest (tab-separated sha256 and name, hashed
# through scripts/lib/sha256-bin.sh). .capture-log.jsonl is never copied,
# compared, read or written: the capture hook appends to it concurrently.
#
# verify prints one line per file: "changed: f", "added: f", "deleted: f".
# Exit 0 when equal, 1 otherwise.
#
# restore undoes a pass without clobbering anybody else. B = <before-dir>,
# C = the --expect checkpoint (the store as the pass left it), L = live now:
#   R1  B == C                          skipped, whatever L is
#   R2  B != C and L == C               restored from B (a file the pass
#                                       deleted is recreated)
#   R3  in C, not in B, and L == C      the pass added it: MOVED, never deleted,
#                                       to <before-dir>.removed-<UTC ts>/ and listed
#   R4  any other difference            conflict: printed, left untouched; exit 1
#                                       once the clean files are restored
#   R5  in neither B nor C              never touched, listed as "added since
#                                       the checkpoint"
# --expect is required (exit 2 without it): it is what tells the pass's own
# edits from another writer's.
#
# Exit codes: 0 ok, 1 differences or conflicts, 2 cannot run (usage, missing
# store or snapshot, no hasher, a snapshot copy that no longer matches its
# manifest). File names are taken to be plain names (no tab or newline).
#
# ponytail: a file another writer adds between take and the checkpoint looks
# like the pass's own addition (R3), so restore moves it to the .removed- dir
# (never deletes it); a hash alone cannot tell the two apart.
# ponytail: restore hashes a file and then copies or moves it with no lock in
# between, so a writer landing inside that few-millisecond window is
# overwritten (R2) or moved aside (R3, recoverable from the .removed- dir);
# upgrade path: an flock around the whole restore once a writer holds one too.
#
# bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 2
# shellcheck source=../lib/sha256-bin.sh
. "$HERE/../lib/sha256-bin.sh"
# shellcheck source=../lib/memory-slug.sh
. "$HERE/../lib/memory-slug.sh"

MANIFEST=.snapshot-manifest

die() { printf 'memory-snapshot: %s\n' "$1" >&2; exit 2; }
usage() {
    printf 'usage: memory-snapshot.sh take <dir> | verify <dir> | restore <before-dir> --expect <checkpoint-dir>\n' >&2
    exit 2
}

[ -n "${_SHA256_CMD:-}" ] || die "no sha256 hasher on PATH"

# Top-level regular files of a dir, one name per line, sorted, minus the capture
# log and the manifest.
store_files() {
    ( cd "$1" && find . -maxdepth 1 -type f | sed 's|^\./||' \
        | grep -vxF -e .capture-log.jsonl -e "$MANIFEST" | LC_ALL=C sort )
}
# hash of <dir>/<name>, or empty when the file is absent.
hash_in() { [ -f "$1/$2" ] && sha256_hex "$1/$2"; }
# manifest hash of <name> in snapshot <dir>, or empty when it is not listed.
manifest_hash() { awk -F'\t' -v n="$2" '$2 == n { print $1; exit }' "$1/$MANIFEST"; }
need_snapshot() { [ -f "$1/$MANIFEST" ] || die "not a snapshot (no $MANIFEST): $1"; }

[ $# -ge 1 ] || usage
CMD="$1"; shift

MEMDIR="${MEMDIR:-}"
if [ -z "$MEMDIR" ]; then MEMDIR="$(memory_resolve_memdir)" || exit 2; fi
[ -d "$MEMDIR" ] || die "memory dir not found: $MEMDIR"

case "$CMD" in
take)
    [ $# -eq 1 ] || usage
    dir="$1"
    if [ -e "$dir" ]; then
        [ -d "$dir" ] || die "not a directory: $dir"
        [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 | head -1)" ] || die "snapshot dir is not empty: $dir"
    fi
    mkdir -p "$dir" || die "cannot create $dir"
    : > "$dir/$MANIFEST" || die "cannot write $dir/$MANIFEST"
    store_files "$MEMDIR" | while IFS= read -r n; do
        cp -p "$MEMDIR/$n" "$dir/$n" || exit 2
        h="$(sha256_hex "$dir/$n")" && [ -n "$h" ] || exit 2
        printf '%s\t%s\n' "$h" "$n" >> "$dir/$MANIFEST" || exit 2
    done || die "copy, hash or manifest write failed"
    printf 'snapshot: %s files in %s\n' "$(wc -l < "$dir/$MANIFEST" | tr -d ' ')" "$dir"
    ;;
verify)
    [ $# -eq 1 ] || usage
    dir="$1"; need_snapshot "$dir"
    diffs=0
    while IFS="$(printf '\t')" read -r h n; do
        [ -n "$n" ] || continue
        if [ ! -f "$MEMDIR/$n" ]; then
            printf 'deleted: %s\n' "$n"; diffs=$((diffs+1))
        elif [ "$(sha256_hex "$MEMDIR/$n")" != "$h" ]; then
            printf 'changed: %s\n' "$n"; diffs=$((diffs+1))
        fi
    done < "$dir/$MANIFEST"
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ -z "$(manifest_hash "$dir" "$n")" ] || continue
        printf 'added: %s\n' "$n"; diffs=$((diffs+1))
    done < <(store_files "$MEMDIR")
    [ "$diffs" -eq 0 ]
    ;;
restore)
    before=""; expect=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --expect) [ $# -ge 2 ] || usage; expect="$2"; shift 2 ;;
            -*) usage ;;
            *) [ -z "$before" ] || usage; before="$1"; shift ;;
        esac
    done
    [ -n "$before" ] || usage
    [ -n "$expect" ] || { printf 'memory-snapshot: restore needs --expect <checkpoint-dir>\n' >&2; exit 2; }
    need_snapshot "$before"; need_snapshot "$expect"
    # A snapshot copy that no longer matches its manifest is not a source of truth.
    while IFS="$(printf '\t')" read -r h n; do
        [ -n "$n" ] || continue
        [ "$(hash_in "$before" "$n")" = "$h" ] || die "snapshot copy altered: $before/$n"
    done < "$before/$MANIFEST"

    TMP="$(tmpdir)" || exit 2
    trap 'rm -rf "$TMP"' EXIT
    cat "$before/$MANIFEST" "$expect/$MANIFEST" | cut -f2 | LC_ALL=C sort -u > "$TMP/names"
    removed="${before%/}.removed-$(date -u +%Y%m%dT%H%M%SZ)"
    restored=0; moved=0; conflicts=0; skipped=0
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        hb="$(manifest_hash "$before" "$n")"; hc="$(manifest_hash "$expect" "$n")"
        hl="$(hash_in "$MEMDIR" "$n")"
        if [ -n "$hb" ] && [ "$hb" = "$hc" ]; then                          # R1
            skipped=$((skipped+1))
        elif [ -z "$hl" ] && [ -f "$MEMDIR/$n" ]; then                     # present but unhashable
            printf 'conflict: %s (cannot hash the live file; left untouched)\n' "$n"
            conflicts=$((conflicts+1))
        elif [ -n "$hb" ] && [ "$hl" = "$hc" ]; then                        # R2
            cp -p "$before/$n" "$MEMDIR/$n" || die "cannot restore $n"
            printf 'restored: %s\n' "$n"; restored=$((restored+1))
        elif [ -z "$hb" ] && [ -n "$hl" ] && [ "$hl" = "$hc" ]; then        # R3
            mkdir -p "$removed" || die "cannot create $removed"
            mv "$MEMDIR/$n" "$removed/$n" || die "cannot move $n"
            printf 'moved: %s -> %s/%s\n' "$n" "$removed" "$n"; moved=$((moved+1))
        else                                                                # R4
            printf 'conflict: %s (changed by another writer since the checkpoint; left untouched)\n' "$n"
            conflicts=$((conflicts+1))
        fi
    done < "$TMP/names"
    while IFS= read -r n; do                                                # R5
        [ -n "$n" ] || continue
        [ -z "$(manifest_hash "$before" "$n")" ] && [ -z "$(manifest_hash "$expect" "$n")" ] \
            && printf 'added since the checkpoint: %s (left untouched)\n' "$n"
    done < <(store_files "$MEMDIR")
    printf 'restore: restored %s, moved %s, conflicts %s, unchanged by the pass %s\n' \
        "$restored" "$moved" "$conflicts" "$skipped"
    [ "$conflicts" -eq 0 ]
    ;;
*) usage ;;
esac
