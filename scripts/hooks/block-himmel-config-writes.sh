#!/usr/bin/env bash
# block-himmel-config-writes.sh - PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit") [HIMMEL-4696]. A SPEED BUMP, not a fence.
#
# WHY: graphify.salus_ollama_cloud_ok in ~/.himmel/config.json is the persisted
# opt-in that lets the graphify fence send salus (PHI) corpora to ollama-cloud
# (HIMMEL-4185). The matrix reads it from a plain file, so an agent that can
# write the file can grant itself an egress it was never given. Granting that
# opt-in is an OPERATOR call; this hook makes the tool-driven routes cost a
# denial. There is deliberately NO env bypass - a bypass an agent can request is
# the thing this hook exists to remove.
#
# WIRING: NOT YET WIRED (the auto-mode classifier denied the worktree settings
# edit as Self-Modification). Until the follow-up adds this script to
# EXPECTED_SCRIPT_ORDER in wire-hook-bash.mjs (Bash chain and Edit|Write chain,
# right after block-bank-lift-writes.sh), .claude/settings.json and
# .codex/hooks.json (HIMMEL-5290) it is inert; the fence's symlink refusal is
# the only live layer.
#
# DENIES
#   Bash - the command text names the config file (`.himmel` and `config.json`
#     both present, in any quoting/spelling that keeps the two literals) unless
#     EVERY clause is a plain reader, a bare name (cat head tail wc stat ls file jq
#     grep rg diff test [) with no redirect, no rg `--pre`/`--pre-glob`/
#     `--hostname-bin` (they run a program), and no command substitution. A
#     `ln -s ... config.json`, `cp`, `mv`, `sed -i`, `jq ... >` or `echo >
#     ...config.json` all name it and so deny (none is a plain reader).
#   Edit|Write|MultiEdit|NotebookEdit - file_path / notebook_path whose literal
#     name is `.himmel/config.json`, or which resolves (`readlink -m`: `..`
#     segments, symlinked components) to $HOME/.himmel/config.json.
# ALLOWS everything else, silently. Reads of the file stay allowed.
#
# FAIL MODE: fail-closed only for its one subject. A payload it cannot parse is
# scanned as raw text and denied when it names the file; otherwise allowed
# (failing closed on every unparseable call would lock a session out of every
# tool for a hook bug; scripts/hooks/CLAUDE.md fail-open-vs-closed rule).
#
# ponytail: text matching, not a shell parser or a sandbox. An interpreter that
# assembles the path from pieces, a script FILE that writes the config without
# being handed its name, `eval`, a variable holding the path, and a Bash command
# reaching it through a symlink alias (only file-tool paths are resolved) are
# not caught. The graphify fence is the second layer: it refuses a symlinked
# config or ~/.himmel itself. Upgrade path: an operator-owned (root-owned or
# separate-uid) store the fence verifies, filed when a forged opt-in is seen.
#
# Hook I/O: JSON on stdin; exit 0 = allow, exit 2 = block (stderr shown).
# Platform guard: bash 3.2-safe (no mapfile, no associative arrays).
set -uo pipefail
# shellcheck disable=SC2154 # rc is assigned inside the trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    {
        echo "block-himmel-config-writes: refusing - $1."
        echo
        echo "    ~/.himmel/config.json carries graphify.salus_ollama_cloud_ok, the persisted"
        echo "    opt-in that lets salus (PHI) corpora reach ollama-cloud (HIMMEL-4185), so"
        echo "    changing it is operator-only (HIMMEL-4696). Remedy: the operator edits the"
        echo "    file by hand at their own prompt (or uses the HIMMEL-4495 UI flow once it"
        echo "    lands). Reading the file stays allowed. There is no env bypass."
    } >&2
    exit 2
}

input=$(cat)
if ! command -v jq >/dev/null 2>&1; then
    # No parser: raw-text scan, deny only a mention of the subject.
    case "$input" in
        *.himmel*config.json*) deny "jq not found and the payload names ~/.himmel/config.json (fail-closed)" ;;
    esac
    exit 0
fi
if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    case "$input" in
        *.himmel*config.json*) deny "unparseable payload names ~/.himmel/config.json (fail-closed)" ;;
    esac
    exit 0
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || tool=""
CFG_REAL="${HOME:-/nonexistent}/.himmel/config.json"

case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
        p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || p=""
        [ -n "$p" ] || exit 0
        case "$p" in
            */.himmel/config.json|.himmel/config.json) deny "$tool targets $p" ;;
        esac
        r=$(readlink -m -- "$p" 2>/dev/null) || r=""
        if [ -n "$r" ] && [ "$r" = "$(readlink -m -- "$CFG_REAL" 2>/dev/null)" ]; then
            deny "$tool target $p resolves to ~/.himmel/config.json"
        fi
        exit 0
        ;;
    Bash) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0
cmd=${cmd//$'\r'/}

lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
case "$lc" in *.himmel*) ;; *) exit 0 ;; esac
case "$lc" in *config.json*|*config.j\**|*config.\**|*conf\**) ;; *) exit 0 ;; esac

# The command names the file. Allow only a pure read: no substitution, no
# redirect, and every clause's command word a plain reader.
# shellcheck disable=SC2016 # literal $( and backtick are the patterns
case "$cmd" in
    *'$('*|*'`'*|*'>'*|*'<('*) deny "the command names ~/.himmel/config.json with a redirect, command or process substitution" ;;
esac
clauses=${cmd//;/$'\n'}
clauses=${clauses//|/$'\n'}
clauses=${clauses//&/$'\n'}
while IFS= read -r clause || [ -n "$clause" ]; do
    set -f
    # shellcheck disable=SC2086 # intentional word split, globbing off via set -f
    set -- $clause
    set +f
    [ "$#" -gt 0 ] || continue
    # The command word must be a bare reader name: a path (./cat, /tmp/jq) is an
    # arbitrary program wearing a reader's basename. less/more are not readers
    # here: `less -o/-O <file>` writes a log file.
    w="$1"
    case "$w" in
        cat|head|tail|wc|stat|ls|file|jq|grep|rg|diff|test|'[') ;;
        *) deny "the command names ~/.himmel/config.json under '$w', not a plain reader" ;;
    esac
    for a in "$@"; do
        case "$a" in
            --pre|--pre=*|--pre-glob|--pre-glob=*|--hostname-bin|--hostname-bin=*) deny "the command names ~/.himmel/config.json with an option that runs a program ($a)" ;;
        esac
    done
done <<< "$clauses"
exit 0
