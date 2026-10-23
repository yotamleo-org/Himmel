#!/usr/bin/env bash
# scripts/lib/portable-timeout.sh — SOURCED. Guarantee a GNU-semantics `timeout`.
#
# Stock macOS ships neither `timeout` nor `gtimeout`, and the macOS runner does
# not install coreutils. When no bare `timeout` answers `--version`, this
# prepends scripts/lib/shims (a bash `timeout`) to PATH, so a suite's bare
# `timeout` calls — and every script it runs, scripts/lib/timeout-bin.sh
# included — resolve it. With a real `timeout` present it changes nothing.
#
# Source it at the top of a suite that needs a bound:
#   . "$SCRIPT_DIR/../lib/portable-timeout.sh"
#
# bash 3.2-safe; idempotent.

_portable_timeout_src="${BASH_SOURCE[0]}"
case "$_portable_timeout_src" in */*) ;; *) _portable_timeout_src="./$_portable_timeout_src" ;; esac
_portable_timeout_dir="$(cd "${_portable_timeout_src%/*}" && pwd)/shims"
_portable_timeout_have=0
# only a bare `timeout` counts: the suites call it bare, so a gtimeout-only host still needs the shim
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    _portable_timeout_have=1
fi
if [ "$_portable_timeout_have" = 0 ]; then
    case ":$PATH:" in
        *":$_portable_timeout_dir:"*) ;;
        *) PATH="$_portable_timeout_dir:$PATH"; export PATH ;;
    esac
fi
unset _portable_timeout_src _portable_timeout_dir _portable_timeout_have
