#!/usr/bin/env bash
# Tests for scripts/lib/qmd-daemon-env.sh: the daemon-env key loader.
set -u
# a session's own key or base URL must not leak into the cases
unset QMD_OPENAI_API_KEY QMD_OPENAI_BASE_URL

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/qmd-daemon-env.sh"
work="$(mktemp -d -t qmd-daemon-env.XXXXXX)" || exit 1
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'models:\n  embed: openai:qwen/qwen3-embedding-8b\n  openai_base_url: https://openrouter.ai/api/v1\n' > "$work/or.yml"
printf 'models:\n  embed: hf:x/y/z.gguf\n' > "$work/local.yml"
SENTINEL=sk-test-sentinel-6125
printf 'QMD_OPENAI_API_KEY=%s\n' "$SENTINEL" > "$work/env"

# run <cfg> -> sets rc, out (stdout+stderr), exported key length in $work/keylen
run() {
  out="$(bash -c '. "$1"; qmd_daemon_key_load "$2"; rc=$?; printf "%s" "${QMD_OPENAI_API_KEY:-}" > "$3"; exit $rc' _ "$LIB" "$1" "$work/key" 2>&1)"; rc=$?
}

# (1) a 0600 file exports its key and prints nothing.
chmod 600 "$work/env"
QMD_DAEMON_ENV_FILE="$work/env" run "$work/or.yml"
[ "$rc" -eq 0 ] || fail "(1) 0600 file: expected rc 0, got $rc"
[ "$(cat "$work/key")" = "$SENTINEL" ] || fail "(1) the key was not exported"
[ -z "$out" ] || fail "(1) the loader printed output"

# (2) a 0400 file is accepted too.
chmod 400 "$work/env"
QMD_DAEMON_ENV_FILE="$work/env" run "$work/or.yml"
[ "$rc" -eq 0 ] || fail "(2) 0400 file: expected rc 0, got $rc"

# (3) a group/world-readable file is refused (rc 10) and its key is never exported or printed.
chmod 644 "$work/env"
QMD_DAEMON_ENV_FILE="$work/env" run "$work/or.yml"
[ "$rc" -eq 10 ] || fail "(3) 0644 file: expected rc 10, got $rc"
[ -z "$(cat "$work/key")" ] || fail "(3) a refused file still exported a key"
case "$out" in *"$SENTINEL"*) fail "(3) the key appeared in the output" ;; esac

# (4) no file and an OpenRouter config: rc 11, the session key is dropped.
rm -f "$work/env"
QMD_OPENAI_API_KEY=sk-stale-session QMD_DAEMON_ENV_FILE="$work/env" run "$work/or.yml"
[ "$rc" -eq 11 ] || fail "(4) no key file, OpenRouter config: expected rc 11, got $rc"
[ -z "$(cat "$work/key")" ] || fail "(4) the session key survived"

# (5) no file and a local config: rc 0, nothing exported.
QMD_DAEMON_ENV_FILE="$work/env" run "$work/local.yml"
[ "$rc" -eq 0 ] || fail "(5) no key file, local config: expected rc 0, got $rc"

# (6) a key from the file replaces a stale session key.
printf 'QMD_OPENAI_API_KEY=%s\n' "$SENTINEL" > "$work/env"; chmod 600 "$work/env"
QMD_OPENAI_API_KEY=sk-stale-session QMD_DAEMON_ENV_FILE="$work/env" run "$work/or.yml"
[ "$(cat "$work/key")" = "$SENTINEL" ] || fail "(6) the file key did not replace the session key"

# (7) tracing on: bash -x never prints the key.
trace="$(QMD_DAEMON_ENV_FILE="$work/env" bash -x -c '. "$1"; qmd_daemon_key_load "$2"' _ "$LIB" "$work/or.yml" 2>&1)"
case "$trace" in *"$SENTINEL"*) fail "(7) bash -x printed the key" ;; esac

echo "OK test-qmd-daemon-env"
