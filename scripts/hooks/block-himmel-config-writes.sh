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
# WIRING (HIMMEL-5290): listed in EXPECTED_SCRIPT_ORDER in wire-hook-bash.mjs
# (Bash chain and Edit|Write chain, right after block-bank-lift-writes.sh) and
# wired in .claude/settings.json and .codex/hooks.json. `node
# scripts/hooks/wire-hook-bash.mjs --check` proves the three agree.
#
# DENIES
#   Bash - the command text names the config file (`.himmel` and `config.json`
#     both present, in any quoting/spelling that keeps the two literals) unless
#     it passes a STRUCTURAL ALLOW-LIST (HIMMEL-5290, judge j2409c): every
#     character in [A-Za-z0-9 _./~:=,@+-], first word one of cat jq grep head
#     tail wc stat ls diff sha256sum (not less: +v opens an editor), and no
#     option in an output position (-o/-O, --output*, +command arguments,
#     jq --arg*/--rawfile/--slurpfile).
#     So `cat cfg`, `jq .graphify cfg`, `grep -i x cfg`, `wc -c cfg` allow;
#     anything with a quote, redirect, pipe, ;, &, $, backtick, brace, paren,
#     glob or backslash denies. That OVER-DENIES on purpose: `jq '.a | keys'
#     cfg` (quotes), `cat cfg 2>/dev/null` (redirect), `grep x cfg | head`,
#     a CRLF-terminated read and a trailing `# comment` are all denied; the
#     deny message points at the quote-free reads and the Read tool.
#   Edit|Write|MultiEdit|NotebookEdit - file_path / notebook_path whose literal
#     name is `.himmel/config.json`, or which resolves (`readlink -m`: `..`
#     segments, symlinked components) to $HOME/.himmel/config.json.
#   apply_patch (Codex's only edit tool) - WHOLE-PATCH rule (j2409f): any patch
#     whose text anywhere contains `.himmel` and a config name (`config.json`,
#     `config.j*`, `config.*`, `conf*`) denies, whatever the headers,
#     whitespace or encoding (a patch that merely mentions the path in its
#     content denies too). ADDITIONALLY a `*** Add File:` / `Update File:` /
#     `Delete File:` / `Move to:` header path (relative ones joined with the
#     payload `.cwd`) that resolves to the config via `readlink -m` denies
#     (a symlinked directory that never names `.himmel`).
# ALLOWS everything else, silently. Reads of the file stay allowed.
#
# FAIL MODE: fail-closed only for its one subject. A payload it cannot parse is
# scanned as raw text and denied when it names the file; otherwise allowed
# (failing closed on every unparseable call would lock a session out of every
# tool for a hook bug; scripts/hooks/CLAUDE.md fail-open-vs-closed rule).
#
# ponytail: the allow-list over-denies on purpose (a splitter was patched three
# times and each patch opened the next escape: j2409a/b/c), upgrade path a real
# shared tokenizer, filed if a benign read is blocked often. The TRIGGER's
# spelling ceiling stays filed: it needs the literals `.himmel` and `config.j*`
# (or `config.*`/`conf*`) in the text, so an interpreter that assembles the
# path from pieces, `conf?g`, `[c]onfig`, split quotes, a script FILE that
# writes the config without being handed its name, `eval`, a variable holding
# the path, cwd-indirection across calls (`cd ~/.himmel`, then a later
# `cp x config.json` names no `.himmel`), and a Bash command reaching it through a symlink alias (only
# file-tool paths are resolved) are not caught. Text matching, not a sandbox.
# The graphify fence is the second layer: it refuses a symlinked config or
# ~/.himmel itself. Upgrade path: an operator-owned (root-owned or separate-uid)
# store the fence verifies, filed when a forged opt-in is seen.
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

# check_path TOOL PATH: deny when PATH is, or resolves to, the config.
check_path() {
    local t="$1" p="$2" r
    [ -n "$p" ] || return 0
    case "$p" in
        */.himmel/config.json|.himmel/config.json) deny "$t targets $p" ;;
    esac
    r=$(readlink -m -- "$p" 2>/dev/null) || r=""
    if [ -n "$r" ] && [ "$r" = "$(readlink -m -- "$CFG_REAL" 2>/dev/null)" ]; then
        deny "$t target $p resolves to ~/.himmel/config.json"
    fi
    return 0
}

case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
        p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || p=""
        check_path "$tool" "$p"
        exit 0
        ;;
    apply_patch)
        # Codex edits only through apply_patch; the paths are the header lines
        # of the patch text (same parse as block-bank-lift-writes.sh).
        patch=$(printf '%s' "$input" | jq -r '(.tool_input.command // .tool_input.patch // .tool_input.input // "") | if type == "array" then join("\n") else tostring end' 2>/dev/null) || patch=""
        pcwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || pcwd=""
        # Whole-patch rule (j2409f: codex trims Unicode White_Space, so a
        # header-parse match was a second NO-GO; stop mirroring its parser):
        # deny when the patch text ANYWHERE carries `.himmel` and a config
        # name, whatever the headers, whitespace or encoding. Over-denies a
        # patch that only mentions the path in its content, on purpose.
        lp=$(printf '%s' "$patch$input" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        case "$lp" in
            *.himmel*)
                case "$lp" in
                    *config.json*|*config.j\**|*config.\**|*conf\**) deny "apply_patch payload names .himmel and a config file (whole-patch rule; a patch that only mentions the path in its content is refused too)" ;;
                esac
                ;;
        esac
        # Additional deny: a header path that RESOLVES to the config without
        # naming .himmel (a symlinked directory or alias).
        while IFS= read -r ln; do
            ln="${ln#"${ln%%[![:space:]]*}"}"
            ln="${ln%"${ln##*[![:space:]]}"}"
            case "$ln" in
                '*** Add File: '*) p="${ln#\*\*\* Add File: }" ;;
                '*** Update File: '*) p="${ln#\*\*\* Update File: }" ;;
                '*** Delete File: '*) p="${ln#\*\*\* Delete File: }" ;;
                '*** Move to: '*) p="${ln#\*\*\* Move to: }" ;;
                *) continue ;;
            esac
            # A relative patch path (a `~`-led one included, codex does not
            # expand it) resolves against the payload cwd.
            case "$p" in
                /*|"") ;;
                *) [ -n "$pcwd" ] && p="$pcwd/$p" ;;
            esac
            check_path apply_patch "$p"
        done <<EOF
$patch
EOF
        exit 0
        ;;
    Bash) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0

# CR is stripped ONLY for the substring detection below. The command-word
# allowlist sees the raw text, so a program named `cat<CR>` is not `cat`.
lc=$(printf '%s' "${cmd//$'\r'/}" | tr '[:upper:]' '[:lower:]')
case "$lc" in *.himmel*) ;; *) exit 0 ;; esac
case "$lc" in *config.json*|*config.j\**|*config.\**|*conf\**) ;; *) exit 0 ;; esac

# The command names the file. Structural allow-list (HIMMEL-5290, judge
# j2409c: the third shell-parsing NO-GO, so no splitter): ALLOW only when
#   1. every character is in [A-Za-z0-9 _./~:=,@+-] - no quote, $, backtick,
#      brace, paren, ; & | < > * ? [ ] # ! backslash, tab, CR or newline, so
#      there is nothing to parse: no chaining, redirect, substitution, glob;
#   2. the first word is a bare reader name (a path or VAR= prefix is not);
#   3. no option can put a file in an output position (-o/-O in any short
#      cluster, --output*, jq --arg*/--rawfile/--slurpfile) and no +command
#      argument. less is NOT a listed reader: +v launches an editor, -O logs
#      to a file, and interactive less has shell escapes (codex-1, round 3).
# LC_ALL=C keeps the character ranges byte-exact under a UTF-8 locale.
LC_ALL=C
export LC_ALL
case "$cmd" in
    *[!a-zA-Z0-9\ _./~:=,@+-]*)
        deny "the command names ~/.himmel/config.json and uses a character outside [A-Za-z0-9 _./~:=,@+-] (quotes, redirects, chaining, substitution, globs and braces are all refused). Quote-free reads stay allowed: \`jq .graphify ~/.himmel/config.json\`, \`cat ~/.himmel/config.json\`, or the Read tool" ;;
esac
set -f
# shellcheck disable=SC2086 # intentional word split, globbing off via set -f
set -- $cmd
set +f
[ "$#" -gt 0 ] || exit 0
w="$1"
case "$w" in
    cat|jq|grep|head|tail|wc|stat|ls|diff|sha256sum) ;;
    *) deny "the command names ~/.himmel/config.json under '$w', not a listed plain reader (cat jq grep head tail wc stat ls diff sha256sum; less is out: +v opens an editor, -O logs to a file). Reads: \`jq .graphify ~/.himmel/config.json\`, \`cat ~/.himmel/config.json\`, or the Read tool" ;;
esac
shift
for a in "$@"; do
    case "$a" in
        -[oO]*|-[!-]*[oO]*|--output*|--arg*|--rawfile|--slurpfile)
            deny "the option '$a' can put a file in an output position" ;;
        +*) deny "the option '$a' is a +command argument" ;;
    esac
done
exit 0
