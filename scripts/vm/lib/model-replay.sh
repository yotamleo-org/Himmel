#!/usr/bin/env bash
# model-replay.sh — record-once / replay-without-model for a model-driven check.
# Source it; bash 3.2 safe.
#
# A check that needs a live model records the artifact the model produced under
# a key hashed from its inputs (model + prompt + any extra input file). The next
# run with the same key restores that artifact and makes NO model call; a changed
# input changes the key and re-records. Idea borrowed from tester-army/e2e
# (Apache-2.0); no code taken.
#
#   replay_key <model> <input-file>...           -> prints the sha256 key (rc 2: input unreadable)
#   replay_valid <cache-dir> <key>               -> rc 0 when a checksum-valid recording exists
#   replay_run <cache-dir> <key> <artifact> -- <record-cmd> [args...]
#       Sets REPLAY_MODE_USED=replay|record and REPLAY_MODEL_CALLS=0|1.
#       rc 0 ok; the record command's rc when it fails; 4 replay-only with no
#       valid recording; 2 an unknown HIMMEL_REPLAY_MODE; 5 the record command wrote no artifact.
#
# HIMMEL_REPLAY_MODE: auto (default: replay if recorded, else record) |
#   record (always call the model and overwrite) | replay-only (never call it).
# A recording is valid only when its stored sha256 matches the artifact bytes, so
# a hand-edited or half-written recording is re-recorded, never replayed.
#
# The key covers only what is listed: a check whose answer also depends on code
# the model read must list that code as an input file, or it will replay stale.

# shellcheck disable=SC2034  # REPLAY_MODE_USED / REPLAY_MODEL_CALLS are read by the sourcing caller
replay_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

replay_key() {
  local model="$1" f
  shift
  for f in "$@"; do
    [ -r "$f" ] || { echo "model-replay: key input not readable: $f" >&2; return 2; }
  done
  local parts="model=$model" h
  for f in "$@"; do
    h="$(replay_sha256 < "$f")" && [ -n "$h" ] || { echo "model-replay: cannot hash key input: $f" >&2; return 2; }
    parts="$parts
sha=$h"
  done
  printf '%s\n' "$parts" | replay_sha256
}

# replay_valid <cache-dir> <key>: rc 0 when the slot holds a recording whose bytes match its checksum.
replay_valid() {
  local slot="$1/$2"
  [ -s "$slot/artifact" ] && [ -r "$slot/artifact.sha256" ] \
    && [ "$(replay_sha256 < "$slot/artifact")" = "$(cat "$slot/artifact.sha256")" ]
}

replay_run() {
  local cache="$1" key="$2" art="$3" slot mode rc
  shift 3
  [ "${1:-}" = "--" ] && shift
  slot="$cache/$key"
  mode="${HIMMEL_REPLAY_MODE:-auto}"
  REPLAY_MODE_USED="" REPLAY_MODEL_CALLS=0
  case "$mode" in
    auto|record|replay-only) ;;
    *) echo "model-replay: HIMMEL_REPLAY_MODE='$mode' is not auto|record|replay-only; nothing spent" >&2; return 2 ;;
  esac

  if [ "$mode" != record ] && replay_valid "$cache" "$key"; then
    mkdir -p "$(dirname "$art")" && cp "$slot/artifact" "$art" || return 1
    REPLAY_MODE_USED=replay
    return 0
  fi
  if [ "$mode" = replay-only ]; then
    echo "model-replay: no valid recording for $key (replay-only); nothing spent" >&2
    return 4
  fi

  rm -f "$art"
  "$@"
  rc=$?
  REPLAY_MODEL_CALLS=1
  [ "$rc" -eq 0 ] || return "$rc"
  [ -s "$art" ] || { echo "model-replay: the record command wrote no artifact at $art" >&2; return 5; }
  mkdir -p "$slot" || return 1
  # The checksum lands last: a recording interrupted before it reads as invalid.
  rm -f "$slot/artifact.sha256"
  # Per-process staging names: two runs recording the same key never share a temp file.
  cp "$art" "$slot/artifact.$$.tmp" && mv "$slot/artifact.$$.tmp" "$slot/artifact" \
    && replay_sha256 < "$slot/artifact" > "$slot/artifact.sha256.$$.tmp" \
    && mv "$slot/artifact.sha256.$$.tmp" "$slot/artifact.sha256" || return 1
  REPLAY_MODE_USED=record
  return 0
}
