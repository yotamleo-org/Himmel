#!/usr/bin/env bash
# testlib-config-isolation.sh — sourced by test suites that blank HANDOVER_DIR.
#
# load_dotenv falls back to $HOME/.himmel/himmel.conf for HANDOVER_DIR, so on a
# station a suite that unsets it resolves the operator's live handover root and
# can write into it. isolate_himmel_config points HIMMEL_CONFIG_DIR at an empty
# directory the suite owns (its own temp dir, removed by its own trap).

# isolate_himmel_config <suite-owned-dir> — create <dir>/himmel-config, export it.
isolate_himmel_config() {
    [ -n "${1-}" ] || { echo "isolate_himmel_config: no directory given" >&2; return 1; }
    mkdir -p "$1/himmel-config" || return 1
    export HIMMEL_CONFIG_DIR="$1/himmel-config"
}
