#!/usr/bin/env bash
# scripts/lib/qmd-daemon-env.sh - load the qmd provider key from the daemon env file.
#
# Source it, then: qmd_daemon_key_load <index.yml>
#   rc 0   a key from the file is exported as QMD_OPENAI_API_KEY, or nothing needed one
#   rc 10  the env file exists but is readable by others (QMD_KEY_FILE_PATH names it)
#   rc 11  an OpenRouter config has no key; the session key was dropped
# The caller prints its own message. The key is never printed or logged.

qmd_daemon_key_load() {  # t13b-ok: reads the daemon env file, starts nothing
    local cfg="$1" key_trace=0 key_openrouter=0 file_key="" key_missing=0
    # The provider key is the daemon's, never a session's: take it from the env
    # file the daemon launcher reads (one line, mode 0600/0400, never sourced)
    # for any remote model, else `qmd embed` sends no Authorization header and
    # the provider answers 401. A key from the file replaces whatever this
    # session carries. Without one, an OpenRouter config drops the session key
    # and refuses, as the daemon does.
    # ponytail: other remote providers keep a session key and are not refused
    # for a missing one (the egress gate owns that), the daemon requires one
    # for all; unify once the Jina flow is confirmed to use the file key.
    # The read runs with tracing off so `bash -x` never prints the key.
    case "$-" in *x*) key_trace=1 ;; esac
    set +x
    case "${QMD_OPENAI_BASE_URL:-}" in *openrouter.ai*) key_openrouter=1 ;; esac
    if grep -qs '^[^#]*openrouter\.ai' "$cfg"; then key_openrouter=1; fi
    QMD_KEY_FILE_PATH="${QMD_DAEMON_ENV_FILE:-$HOME/.himmel/state/qmd-daemon.env}"  # t13b-ok: path of the daemon env file, starts nothing
    if [ -f "$QMD_KEY_FILE_PATH" ]; then
        # shellcheck disable=SC2012  # the mode string is the point; the path is fixed
        case "$(ls -ld "$QMD_KEY_FILE_PATH" 2>/dev/null | cut -c1-10)" in
            -rw-------|-r--------) ;;
            *)
                if [ "$key_trace" -eq 1 ]; then set -x; fi
                return 10 ;;
        esac
        file_key="$(sed -n 's/^QMD_OPENAI_API_KEY=//p' "$QMD_KEY_FILE_PATH" | head -n 1)"
    fi
    if [ -n "$file_key" ]; then
        QMD_OPENAI_API_KEY="$file_key"
        export QMD_OPENAI_API_KEY
    elif [ "$key_openrouter" -eq 1 ]; then
        unset QMD_OPENAI_API_KEY
        key_missing=1
    fi
    file_key=""
    if [ "$key_trace" -eq 1 ]; then set -x; fi
    [ "$key_missing" -eq 0 ] || return 11
    return 0
}
