#!/usr/bin/env bash
# probe-chunk.sh <k> — print chunk k (100000 bytes; the last may be shorter) of
# the fixed context-probe stream: the working-tree contents of every tracked
# file under docs/, scripts/ and *.md, in C-locale path order, concatenated.
#
# Read-only, no network. Exists so a dontAsk claudex worker can read the probe
# stream as ONE literal command (no pipes, redirects or $(...)):
#   bash scripts/claudex/probe-chunk.sh 0
#
# Exit: 0 ok, 2 bad/missing argument, 3 k is past the end of the stream.
set -uo pipefail

CHUNK_BYTES=100000

k="${1:-}"
if [[ $# -ne 1 || ! "$k" =~ ^[0-9]{1,9}$ ]]; then
  echo "usage: probe-chunk.sh <k>   (k = integer of at most 9 digits)" >&2
  exit 2
fi
k=$((10#$k))

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
export LC_ALL=C

# Pipeline status is deliberately not pipefail-checked: head closing early
# SIGPIPEs the producers, and cat fails on a tracked-but-deleted path.
stream() { git ls-files -z docs scripts '*.md' | sort -z | xargs -0 cat 2>/dev/null || true; }

total=$(stream | wc -c)
start=$((k * CHUNK_BYTES))
if (( start >= total )); then
  echo "probe-chunk: chunk $k is past the end (stream is $total bytes, last chunk is $(( (total - 1) / CHUNK_BYTES )))" >&2
  exit 3
fi

stream | tail -c +"$((start + 1))" | head -c "$CHUNK_BYTES" || true
