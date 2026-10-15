#!/usr/bin/env bash
# block-himmel-config-writes.sh - PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit"). A SPEED BUMP, not a fence.
#
# WHY: graphify.salus_ollama_cloud_ok in ~/.himmel/config.json is the persisted
# opt-in that lets the graphify fence send salus (PHI) corpora to ollama-cloud.
# The matrix reads it from a plain file, so an agent that can
# write the file can grant itself an egress it was never given. Granting that
# opt-in is an OPERATOR call; this hook makes the tool-driven routes cost a
# denial. There is deliberately NO env bypass - a bypass an agent can request is
# the thing this hook exists to remove.
#
# WIRING: listed in EXPECTED_SCRIPT_ORDER in wire-hook-bash.mjs
# (Bash chain and Edit|Write chain, right after block-bank-lift-writes.sh) and
# wired in .claude/settings.json and .codex/hooks.json. `node
# scripts/hooks/wire-hook-bash.mjs --check` proves the three agree.
#
# DENIES
#   Bash - the command text names the config file (`.himmel` and `config.json`
#     both present, in any quoting/spelling that keeps the two literals) unless
#     it passes a STRUCTURAL ALLOW-LIST: every
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
#   apply_patch (Codex's only edit tool) - WHOLE-PATCH rule: any patch
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
# times and each patch opened the next escape), upgrade path a real
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
# Caps on an apply_patch payload; see the apply_patch branch.
MAX_PATCH_BYTES=524288
MAX_PATCH_HEADERS=1000
MAX_HEADER_LINE_BYTES=4096

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
        # Whole-patch rule (codex trims Unicode White_Space, so a
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
        # codex trims Unicode White_Space, bash's
        # [[:space:]] does not: strip the multi-byte members too, from header
        # lines and from the extracted path, until stable.
        uni_trim() {
            local v="$1" prev="" u passes=0
            while [ "$v" != "$prev" ]; do
                # Each pass costs O(length) x ~40 expansions, so a header padded
                # with alternating space/NBSP runs is quadratic (7.5 KB took 17 s,
                # 15 KB 98 s): a real header needs two passes at most.
                passes=$((passes + 1))
                if [ "$passes" -gt 8 ]; then
                    deny "apply_patch header is padded with alternating whitespace runs (the guard cannot trim it inside the hook budget); remove the padding"
                fi
                prev="$v"
                v="${v#"${v%%[![:space:]]*}"}"
                v="${v%"${v##*[![:space:]]}"}"
                for u in $'\xc2\xa0' $'\xc2\x85' $'\xe1\x9a\x80' $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a' $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80'; do
                    v="${v#"$u"}"
                    v="${v%"$u"}"
                done
            done
            UNI_TRIMMED="$v"
        }
        # Bounded cost: the Codex PreToolUse budget is 60 s and
        # its behaviour on a hook timeout is undocumented (the docs only say an
        # MCP hook error/timeout "can fail the hook without blocking"), so a
        # padded patch must DENY here instead of running out the clock. The
        # header loop is fork-free (a case glob pre-filters header lines before
        # the pure-bash trim; paths are collected and resolved by ONE readlink
        # -m afterwards) and the caps bound what is left.
        # Byte length, not ${#patch}: under a multibyte locale that counts characters.
        plen=$(printf '%s' "$patch" | LC_ALL=C wc -c 2>/dev/null) || plen=$((MAX_PATCH_BYTES + 1))
        plen=$((plen + 0))
        if [ "$plen" -gt "$MAX_PATCH_BYTES" ]; then
            deny "apply_patch payload is $plen bytes, over the $MAX_PATCH_BYTES cap (the guard cannot finish inside the hook budget; split the patch)"
        fi
        # Byte semantics for the per-line cap below (${#ln} counts characters
        # under a multibyte locale); uni_trim matches byte sequences anyway.
        LC_ALL=C
        nhdr=0
        cand=()
        while IFS= read -r ln; do
            # A header, after trimming only OUTER whitespace, starts with
            # `*** <Verb>: `, so the untrimmed line contains it (sound pre-filter).
            case "$ln" in
                *'*** Add File: '*|*'*** Update File: '*|*'*** Delete File: '*|*'*** Move to: '*) ;;
                *) continue ;;
            esac
            # One pass of uni_trim is O(length) x ~40 removals, so a long header
            # line costs about length squared (200 KB: 40 s, 400 KB: 186 s).
            # No real path exceeds PATH_MAX; deny before any per-line work.
            if [ "${#ln}" -gt "$MAX_HEADER_LINE_BYTES" ]; then
                deny "apply_patch header line is ${#ln} bytes, over the $MAX_HEADER_LINE_BYTES cap (the guard cannot trim it inside the hook budget)"
            fi
            uni_trim "$ln"
            ln="$UNI_TRIMMED"
            case "$ln" in
                '*** Add File: '*) p="${ln#\*\*\* Add File: }" ;;
                '*** Update File: '*) p="${ln#\*\*\* Update File: }" ;;
                '*** Delete File: '*) p="${ln#\*\*\* Delete File: }" ;;
                '*** Move to: '*) p="${ln#\*\*\* Move to: }" ;;
                *) continue ;;
            esac
            nhdr=$((nhdr + 1))
            if [ "$nhdr" -gt "$MAX_PATCH_HEADERS" ]; then
                deny "apply_patch carries more than $MAX_PATCH_HEADERS file headers (the guard cannot finish inside the hook budget; split the patch)"
            fi
            # A relative patch path (a `~`-led one included, codex does not
            # expand it) resolves against the payload cwd. The path is checked
            # as written AND Unicode-trimmed (codex trims; a file literally
            # named with a trailing NBSP is the as-written variant).
            uni_trim "$p"
            trimmed="$UNI_TRIMMED"
            for p in "$p" "$trimmed"; do
                case "$p" in
                    /*|"") ;;
                    *) [ -n "$pcwd" ] && p="$pcwd/$p" ;;
                esac
                case "$p" in
                    */.himmel/config.json|.himmel/config.json) deny "apply_patch targets $p" ;;
                esac
                [ -n "$p" ] && cand[${#cand[@]}]="$p"
            done
        done <<EOF
$patch
EOF
        if [ "${#cand[@]}" -gt 0 ]; then
            cfg_res=$(readlink -m -- "$CFG_REAL" 2>/dev/null) || cfg_res=""
            if [ -n "$cfg_res" ]; then
                # A failed batch (e.g. one path over the OS argument limit) must
                # DENY: an empty result would read as "nothing resolves to it".
                resolved=$(readlink -m -- "${cand[@]}" 2>/dev/null) || deny "apply_patch paths could not be resolved (an oversized path?); split the patch"
                while IFS= read -r r; do
                    [ "$r" = "$cfg_res" ] && deny "an apply_patch target resolves to ~/.himmel/config.json"
                done <<EOF
$resolved
EOF
            fi
        fi
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

# The command names the file. Structural allow-list (no shell splitter): ALLOW only when
#   1. every character is in [A-Za-z0-9 _./~:=,@+-] - no quote, $, backtick,
#      brace, paren, ; & | < > * ? [ ] # ! backslash, tab, CR or newline, so
#      there is nothing to parse: no chaining, redirect, substitution, glob;
#   2. the first word is a bare reader name (a path or VAR= prefix is not);
#   3. no option can put a file in an output position (-o/-O in any short
#      cluster, --output*, jq --arg*/--rawfile/--slurpfile) and no +command
#      argument. less is NOT a listed reader: +v launches an editor, -O logs
#      to a file, and interactive less has shell escapes.
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
