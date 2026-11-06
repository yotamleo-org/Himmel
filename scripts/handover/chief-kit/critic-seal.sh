#!/usr/bin/env bash
# scripts/handover/chief-kit/critic-seal.sh - seal a saved critic return to the bytes the
# critic read.
#
# Usage: critic-seal.sh <verdict-file> <file-the-critic-read> <sha256-the-critic-quoted>
#
# Inserts `CONTENT-SHA256 <sha> <path of the file, relative to the verdict file's folder>` directly
# above the verdict line (the last non-blank line stays `SPEC|PLAN CLEAN` or `... FINDINGS <n>`).
# `chief-route.ts send-file` re-hashes the named file and refuses a spec or plan page whose bytes
# changed after the critic read them. Refuses, and leaves the verdict file untouched, when:
#   - the verdict file or the read file is missing, or the verdict file's last line is no verdict;
#   - the read file on disk no longer hashes to the quoted sha (it changed since the critic read it);
#   - the verdict file already carries a CONTENT-SHA256 line (a second seal is not stacked).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh" || { echo "critic-seal: cannot load primitives" >&2; exit 1; }

die() { echo "critic-seal: $*" >&2; exit 1; }

[ "$#" -eq 3 ] || die "usage: critic-seal.sh <verdict-file> <file-the-critic-read> <sha256-the-critic-quoted>"
verdict=$1; read_file=$2; quoted=$3

[ -f "$verdict" ] || die "verdict file not found: $verdict"
[ -f "$read_file" ] || die "file the critic read not found: $read_file"
[[ "$quoted" =~ ^[0-9a-f]{64}$ ]] || die "not a sha256 (64 lowercase hex): $quoted"

actual=$(sha256sum "$read_file" | cut -d' ' -f1)
[ "$actual" = "$quoted" ] || die "$read_file hashes to $actual, not the $quoted the critic quoted; it changed since the critic read it, re-run the critic"

if grep -q '^CONTENT-SHA256 ' "$verdict"; then die "$verdict already carries a CONTENT-SHA256 line"; fi

last=$(awk 'NF { l = $0 } END { print l }' "$verdict")
[[ "$last" =~ ^[[:space:]]*(SPEC|PLAN)\ (CLEAN|FINDINGS\ [0-9]+)[[:space:]]*$ ]] \
  || die "$verdict last line is '$last', not SPEC|PLAN CLEAN or SPEC|PLAN FINDINGS <n>"

verdict_dir=$(cd "$(dirname "$verdict")" && pwd -P) || die "cannot enter the verdict file's folder"
read_abs="$(cd "$(dirname "$read_file")" && pwd -P)/$(basename "$read_file")" || die "cannot resolve $read_file"
rel=$(python3 -I -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$read_abs" "$verdict_dir") || die "cannot relativise $read_file"

awk -v seal="CONTENT-SHA256 $quoted $rel" '
  { line[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
  END { for (i = 1; i <= NR; i++) { if (i == last) print seal; print line[i] } }
' "$verdict" | atomic_write "$verdict" || die "could not write $verdict"
