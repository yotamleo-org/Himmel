#!/usr/bin/env bash
# resolve-node.sh — locate an absolute `node` binary at RUNTIME, cross-platform.
#
# WHY: GUI-launched Claude Code starts hooks in a shell with a minimal PATH
# that often lacks node — so a SessionStart hook wired as a bare `node …` (or
# a setup-time absolute path moved by an nvm/homebrew upgrade) fails every
# session. Resolving at runtime, every call,
# survives node upgrades and a PATH-less launch. See `run-node.sh` (the wrapper
# hook commands route through) and `scripts/himmel-doctor.sh`.
#
# Source this file, then call `resolve_node`:
#   node="$(resolve_node)" || { echo "no node"; exit 1; }
# Prints the absolute path on stdout + returns 0 on success; returns 1 + empty
# stdout if no node is found. bash 3.2-safe (no mapfile / associative arrays).
# No `local`: run-node.sh sources this under whatever `sh` the hook shell has and
# ksh93 rejects it, so function-scope variables carry a `_rn_`
# prefix instead — they leak into a same-shell caller, but cannot collide.
#
# Test seams (used only by scripts/lib/test-resolve-node.sh):
#   RESOLVE_NODE_PROBE_DIRS  colon-separated dir list that REPLACES the built-in
#                            absolute-location candidates checked AFTER PATH
#                            (step 2). Set to "" to disable these fallbacks.
#   RESOLVE_NODE_NVM_ROOT    override the nvm versions root (default ~/.nvm/versions/node).

resolve_node() {
    # 1) PATH — respect the operator's chosen node before fallback locations.
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi

    # 2) Well-known absolute locations (macOS homebrew, Linux),
    #    a PATH fallback — these are generic
    #    system paths, not an operator's explicit version choice, so they stay
    #    behind PATH. The test seam replaces this list wholesale so cases stay
    #    hermetic; `_rn_dirs` is walked with IFS=:, so a bare colon in the path
    #    would split it in half.
    if [ "${RESOLVE_NODE_PROBE_DIRS+set}" = set ]; then
        _rn_dirs="$RESOLVE_NODE_PROBE_DIRS"
    else
        _rn_dirs="/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME:-}/.local/bin"
    fi
    _rn_save_ifs="$IFS"
    IFS=:
    for _rn_d in $_rn_dirs; do
        [ -n "$_rn_d" ] || continue
        if [ -x "$_rn_d/node" ]; then printf '%s\n' "$_rn_d/node"; IFS="$_rn_save_ifs"; return 0; fi
    done
    IFS="$_rn_save_ifs"

    # 3) nvm — newest installed version. sort -V (NOT lexical: "v8" > "v20"
    #    lexically would pick an EOL node that can't run modern ESM).
    _rn_nvm_root="${RESOLVE_NODE_NVM_ROOT:-${HOME:-}/.nvm/versions/node}"
    if [ -d "$_rn_nvm_root" ]; then
        # printf-on-glob (not `ls`) so SC2012 stays quiet; a non-matching glob
        # stays literal and fails the -x test below, so no false hit.
        _rn_newest="$(printf '%s\n' "$_rn_nvm_root"/*/bin/node | sort -V | tail -1)"
        if [ -n "$_rn_newest" ] && [ -x "$_rn_newest" ]; then printf '%s\n' "$_rn_newest"; return 0; fi
    fi

    # 4) fnm — newest installed version (its layout: <dir>/node-versions/*/installation/bin/node).
    _rn_fnm_root="${FNM_DIR:-${HOME:-}/.local/share/fnm}"
    if [ -d "$_rn_fnm_root/node-versions" ]; then
        _rn_fnm_newest="$(printf '%s\n' "$_rn_fnm_root"/node-versions/*/installation/bin/node | sort -V | tail -1)"
        if [ -n "$_rn_fnm_newest" ] && [ -x "$_rn_fnm_newest" ]; then printf '%s\n' "$_rn_fnm_newest"; return 0; fi
    fi

    return 1
}
