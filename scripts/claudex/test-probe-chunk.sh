#!/usr/bin/env bash
# shellcheck disable=SC2329  # predicates below are invoked through check()
# Tests for probe-chunk.sh. Runs against the real checkout: the stream is the
# repo's own tracked docs/scripts/*.md, so the reference is recomputed here with
# the documented pipeline. The full stream is ~50 MB, so the concat check covers
# the first CONCAT_N chunks plus the last, not all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUNK="$SCRIPT_DIR/probe-chunk.sh"
CONCAT_N=5

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
# check <name> <cmd...> — pass when the command succeeds.
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
size_is() { [[ "$(wc -c < "$1")" -eq "$2" ]]; }
head_eq() { head -c "$1" "$TMP/ref" | cmp -s - "$2"; }
tail_eq() { tail -c "$1" "$TMP/ref" | cmp -s - "$2"; }
rejects() { ! bash "$CHUNK" "$@" >/dev/null 2>&1; }

TMP="$(mktemp -d -t probe-chunk.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT

[[ -f "$CHUNK" ]] || { fail "probe-chunk.sh exists"; echo "FAIL: $fails" >&2; exit 1; }

cd "$REPO" || exit 1
# Reference stream, written once to a file (no head on a live pipe: SIGPIPE).
git ls-files -z docs scripts '*.md' | LC_ALL=C sort -z | xargs -0 cat 2>/dev/null > "$TMP/ref" || true
total=$(wc -c < "$TMP/ref")
last=$(( (total - 1) / 100000 ))

echo "test: chunk 0 is 100000 bytes and the reference head"
bash "$CHUNK" 0 > "$TMP/c0"
check "chunk 0 size" size_is "$TMP/c0" 100000
check "chunk 0 matches reference" head_eq 100000 "$TMP/c0"

echo "test: determinism"
bash "$CHUNK" 1 > "$TMP/c1a"; bash "$CHUNK" 1 > "$TMP/c1b"
check "chunk 1 identical twice" cmp -s "$TMP/c1a" "$TMP/c1b"

echo "test: first $CONCAT_N chunks concatenate to the reference prefix"
: > "$TMP/cat"
for ((k = 0; k < CONCAT_N; k++)); do bash "$CHUNK" "$k" >> "$TMP/cat"; done
check "concat prefix" head_eq $((CONCAT_N * 100000)) "$TMP/cat"

echo "test: last chunk is the short remainder"
bash "$CHUNK" "$last" > "$TMP/cl"
want=$(( total - last * 100000 ))
check "last chunk size $want" size_is "$TMP/cl" "$want"
check "last chunk matches reference" tail_eq "$want" "$TMP/cl"

echo "test: k past the end exits non-zero with a message"
out="$(bash "$CHUNK" $((last + 1)) 2>&1 >/dev/null)"; rc=$?
check "past-end exit $rc" test "$rc" -ne 0
check "past-end message" test -n "$out"

echo "test: bad argument exits non-zero"
check "non-numeric rejected" rejects abc
check "missing arg rejected" rejects

[[ $fails -eq 0 ]] && { echo "all passed"; exit 0; }
echo "FAIL: $fails" >&2; exit 1
