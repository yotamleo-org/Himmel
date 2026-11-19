#!/usr/bin/env bash
# vault-sync.sh — one answer to "does something else commit this luna vault?",
# shared by the doctor's C3 and the vault-stall cadence's opt-in auto-commit so
# the two never disagree. Source it; it defines one function and prints nothing.
#
#   vault_has_sync <vault>   exit 0 when the vault has a git remote or an
#                            Obsidian plugin whose id contains "sync", or the obsidian-git plugin, which commits on its own

vault_has_sync() {
    local v="$1" d
    [ -z "$(git -C "$v" remote 2>/dev/null)" ] || return 0
    for d in "$v"/.obsidian/plugins/*sync*; do
        [ -d "$d" ] && return 0
    done
    [ -d "$v/.obsidian/plugins/obsidian-git" ] && return 0
    return 1
}
