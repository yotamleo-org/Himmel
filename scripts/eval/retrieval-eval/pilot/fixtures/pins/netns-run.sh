#!/usr/bin/env bash
# netns-run.sh <workdir> <cmd...> -- run <cmd> in a fresh network namespace with the local
# stub model endpoint listening on 127.0.0.1:18080 inside it. Nothing in the namespace can
# reach any other host, so a qmd remote model call can only ever hit the stub.
# STUB_MODE is passed through to the stub (see stub-openai.py).
set -u
W=$1; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2016  # the inner script expands its own positional args
exec bwrap --bind / / --dev /dev --proc /proc --unshare-net --die-with-parent \
  bash -c '
    here=$1 w=$2; shift 2
    rm -f "$w/stub.port"
    python3 -I "$here/stub-openai.py" --port 18080 --port-file "$w/stub.port" --log "$w/stub.log" &
    stub=$!
    for _ in $(seq 100); do [ -s "$w/stub.port" ] && break; sleep 0.05; done
    "$@"; rc=$?
    kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
    exit "$rc"' netns-run "$HERE" "$W" "$@"
