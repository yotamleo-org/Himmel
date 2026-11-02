#!/usr/bin/env bash
# block-vault-sweep.sh — PreToolUse hook (matcher "Bash|Grep|mcp__.*qmd.*").
#
# POC, OFF BY DEFAULT. Refuses the FIRST hand sweep of the notes in
# a session, once, and names the qmd search to run instead. Whether a refusal
# converts a session that would otherwise grep is measured before this stays.
#
# Opt-in: HIMMEL_VAULT_SWEEP_DENY=1 in the LAUNCHING shell. Bypass:
# HIMMEL_VAULT_SWEEP_BYPASS=1 in the launching shell (a per-call prefix does
# not reach the hook process). Delivered by the himmel-ops PLUGIN lane, because a
# himmel project hook does not fire in a session started from the vault.
#
# ALLOWS BY DEFAULT and refuses only a closed list of shapes; all must hold:
#   1. the tool is the Grep tool, or a Bash segment that is a recursive `grep`
#      or an `rg` (a leading env assignment / timeout / rtk / env / command
#      prefix is skipped; bash -c "..." and other wrappers are not unwrapped);
#   2. a root argument is a literal known vault path (.../Documents/luna or
#      .../Clippings; a relative root is joined to the cwd first);
#   3. the pattern is plain words: ^[A-Za-z][A-Za-z ]*$. A ticket key, a
#      number, a session name, a marker or any regex metacharacter is an exact
#      lookup, which is grep's job;
#   4. no qmd call and no refusal has happened yet under the session key.
# Everything else passes, including anything this hook cannot parse. A flag
# whose value could be a pattern (-e/-f/--regexp/--file) also passes.
#
# KEY: session_id. A subagent shares its parent's session_id, so it does NOT get
# its own refusal: whoever sweeps first takes the one refusal. A qmd call by
# either clears the deny for both. Bound on a false refusal: one per key plus
# the allowed retry.
#
# Silent (exit 0) in a salus session: the replacement sends text to
# `qmd query -c luna` (OpenRouter), which scripts/guardrails/egress-matrix.json
# hard-denies for salus. Salus signals (a trimmed copy of
# block-agent-native-egress.sh): "salus" in the cwd, the command or the path, in
# the cwd's git toplevel or any remote URL, or a .salus marker on the cwd or an
# ancestor.
#
# ponytail: catches named sweep shapes over known roots, a wrapped or scripted
# sweep passes; upgrade path is the read-tool route (a backlog follow-up). A heredoc
# line that is itself a vault sweep is refused (a false refusal, counted by the
# POC); a quoted mention such as git commit -m "grep -r notes <vault>" is not,
# because the first word of its segment is not grep.
#
# Fail OPEN (exit 0) on every problem of its own: no jq, bad JSON, unwritable
# state, no resolvable himmel checkout (the deny names an absolute path).
#
# State (HIMMEL_VAULT_SWEEP_DIR, default ${TMPDIR:-/tmp}/himmel-vault-sweep-<uid>):
# <sid>.denied, <sid>.clear. Log (HIMMEL_VAULT_SWEEP_LOG, default
# ~/.claude/vault-sweep-deny/log.jsonl), one best-effort JSON row per event:
#   deny          the one refusal
#   retry_allowed a closed-list sweep after the refusal, no qmd between (no conversion)
#   qmd_clear     first qmd call of the session; had_deny=true is a conversion
# Each row: ts, session_id, event, tool, root, cmd (first 200 chars, control
# characters dropped, token-shaped runs and =values masked), cwd, had_deny.
#
# Hook I/O: tool-call JSON on stdin; exit 0 allows, exit 2 denies with stderr
# shown to Claude. bash 3.2-safe.
set -uo pipefail

[ "${HIMMEL_VAULT_SWEEP_DENY:-0}" = "1" ] || exit 0
[ "${HIMMEL_VAULT_SWEEP_BYPASS:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# \002 separates fields, \001 stands for a newline inside the command.
fields=$(printf '%s' "$input" | jq -r '[
    (.session_id // "" | tostring),
    (.tool_name // "" | tostring),
    (.cwd // "" | tostring),
    (.tool_input.path // "" | tostring),
    (.tool_input.pattern // "" | tostring),
    (.tool_input.command // "" | tostring | .[0:4000] | gsub("\n"; "\u0001"))
  ] | join("\u0002")' 2>/dev/null) || exit 0
sid=${fields%%$'\002'*};  fields=${fields#*$'\002'}
tool=${fields%%$'\002'*}; fields=${fields#*$'\002'}
cwd=${fields%%$'\002'*};  fields=${fields#*$'\002'}
gpath=${fields%%$'\002'*}; fields=${fields#*$'\002'}
gpattern=${fields%%$'\002'*}
cmd=${fields#*$'\002'}
cmd=${cmd//$'\001'/$'\n'}
sid=${sid//[!A-Za-z0-9_-]/_}
[ -n "$sid" ] || exit 0

case "$tool" in
    Bash | Grep | mcp__qmd__* | mcp__plugin_qmd_qmd__*) ;;
    *) exit 0 ;;
esac

DIR=${HIMMEL_VAULT_SWEEP_DIR:-${TMPDIR:-/tmp}/himmel-vault-sweep-$(id -u)}
LOG=${HIMMEL_VAULT_SWEEP_LOG:-${HOME:-}/.claude/vault-sweep-deny/log.jsonl}
mkdir -p "$DIR" 2>/dev/null || exit 0
[ -d "$DIR" ] && [ -w "$DIR" ] || exit 0

log_row() { # EVENT ROOT
    local shown
    shown=$(printf '%s' "$cmd$gpattern" | tr -d '[:cntrl:]' | cut -c1-200 \
        | sed -E 's/[A-Za-z0-9_-]{24,}/<masked>/g; s/=[^[:space:]]+/=<masked>/g')
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" --arg ev "$1" \
        --arg tool "$tool" --arg root "${2:-}" --arg cmd "$shown" --arg cwd "$cwd" \
        --argjson had "$had_deny" \
        '{ts: $ts, session_id: $sid, event: $ev, tool: $tool, root: $root, cmd: $cmd, cwd: $cwd, had_deny: $had}' \
        >>"$LOG" 2>/dev/null || true
}

had_deny=false
[ -e "$DIR/$sid.denied" ] && had_deny=true

# A qmd call clears the deny for the session.
is_qmd=0
case "$tool" in
    mcp__qmd__* | mcp__plugin_qmd_qmd__*) is_qmd=1 ;;
    Bash)
        flat=$(printf '%s' "$cmd" | sed -E "s/'[^']*'/Q/g; s/\"([^\"\\\\]|\\\\.)*\"/Q/g" | tr ';|&' '\n')
        while IFS= read -r seg; do
            seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//; s/^((timeout[[:space:]]+[^[:space:]]+|rtk([[:space:]]+proxy)?|env|command|bash|sh)[[:space:]]+)+//')
            if printf '%s' "$seg" | grep -Eq '(^|/)qmd-bounded\.sh([[:space:]]|$)|^qmd[[:space:]]+(-[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(query|search|vsearch|get|multi-get)([[:space:]]|$)'; then
                is_qmd=1
                break
            fi
        done <<<"$flat"
        ;;
esac
if [ "$is_qmd" = 1 ]; then
    if [ ! -e "$DIR/$sid.clear" ]; then
        : >"$DIR/$sid.clear" 2>/dev/null && log_row qmd_clear ""
    fi
    exit 0
fi
[ -e "$DIR/$sid.clear" ] && exit 0

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Is $1 (absolute, or joined to the cwd) a literal known vault path?
is_vault_path() {
    local p="$1"
    # shellcheck disable=SC2016,SC2088  # the literal text ~ and $HOME in a command word
    case "$p" in
        "~"|"~/"*) p="${HOME:-}${p#\~}" ;;
        '$HOME'|'$HOME/'*) p="${HOME:-}${p#\$HOME}" ;;
        '${HOME}'|'${HOME}/'*) p="${HOME:-}${p#\$\{HOME\}}" ;;
        /*) ;;
        *) [ -n "$cwd" ] || return 1; p="$cwd/$p" ;;
    esac
    case "$p" in
        */Documents/luna | */Documents/luna/* | */Clippings | */Clippings/*) return 0 ;;
    esac
    return 1
}

plain_words() { [[ "$1" =~ ^[A-Za-z][A-Za-z\ ]*$ ]]; }

# Split $1 into words honouring '..' and "..". Sets toks[]; returns 1 on an
# unbalanced quote.
tokenize() {
    local s="$1" cur="" in_tok=0 q="" ch i
    toks=()
    for ((i = 0; i < ${#s}; i++)); do
        ch=${s:i:1}
        if [ -n "$q" ]; then
            if [ "$ch" = "$q" ]; then q=""; else cur+=$ch; fi
        else
            case "$ch" in
                "'" | '"') q=$ch; in_tok=1 ;;
                ' ' | $'\t') if [ "$in_tok" = 1 ]; then toks+=("$cur"); cur=""; in_tok=0; fi ;;
                *) cur+=$ch; in_tok=1 ;;
            esac
        fi
    done
    [ -z "$q" ] || return 1
    if [ "$in_tok" = 1 ]; then toks+=("$cur"); fi
    return 0
}

# Does one Bash segment match the closed list? Sets root. 0 = yes.
segment_matches() {
    local seg="$1" first kind="" t skip=0 pattern="" havepat=0 recursive=0 r
    local roots=()
    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//; s/^((timeout[[:space:]]+[^[:space:]]+|rtk([[:space:]]+proxy)?|env|command)[[:space:]]+)+//')
    tokenize "$seg" || return 1
    [ "${#toks[@]}" -ge 3 ] || return 1
    first=${toks[0]}
    case "$first" in
        grep) kind="grep" ;;
        rg) kind=rg; recursive=1 ;;
        *) return 1 ;;
    esac
    for t in "${toks[@]:1}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$t" in
            -e | -f | --regexp | --regexp=* | --file | --file=* | -e* | -f*) return 1 ;;
            --recursive | --dereference-recursive) recursive=1 ;;
            -A | -B | -C | -m | -d | --include | --exclude | --exclude-dir | --max-count | --context | --after-context | --before-context | -g | -t | -T | -j | -M | --glob | --iglob | --type | --type-not | --threads | --max-depth | --max-columns) skip=1 ;;
            --*) ;;
            -?*) case "$t" in -*[rR]*) [ "$kind" = grep ] && [[ "$t" =~ ^-[A-Za-z]*[rR][A-Za-z]*$ ]] && recursive=1 ;; esac ;;
            *)
                if [ "$havepat" = 0 ]; then pattern=$t; havepat=1; else roots+=("$t"); fi
                ;;
        esac
    done
    [ "$recursive" = 1 ] && [ "$havepat" = 1 ] || return 1
    plain_words "$pattern" || return 1
    for r in "${roots[@]:-}"; do
        [ -n "$r" ] || continue
        if is_vault_path "$r"; then root=$r; return 0; fi
    done
    return 1
}

root=""
matched=0
case "$tool" in
    Grep)
        if plain_words "$gpattern"; then
            if [ -n "$gpath" ]; then
                is_vault_path "$gpath" && { matched=1; root=$gpath; }
            elif [ -n "$cwd" ] && is_vault_path "$cwd"; then
                matched=1; root=$cwd
            fi
        fi
        ;;
    Bash)
        while IFS= read -r seg; do
            if segment_matches "$seg"; then matched=1; break; fi
        done <<<"$(printf '%s' "$cmd" | tr ';|&' '\n')"
        ;;
esac
[ "$matched" = 1 ] || exit 0

# Silent in a salus session.
case "$(lc "$cwd|$cmd|$gpath|$gpattern")" in *salus*) exit 0 ;; esac
if command -v git >/dev/null 2>&1 && [ -n "$cwd" ] && [ -d "$cwd" ]; then
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
    case "$(lc "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null; git -C "$cwd" remote -v 2>/dev/null)")" in *salus*) exit 0 ;; esac
fi
d=$cwd
while [ -n "$d" ]; do
    [ -e "$d/.salus" ] && exit 0
    parent=${d%/*}
    [ "$parent" = "$d" ] && break
    d=$parent
done
[ -e "/.salus" ] && exit 0

if [ "$had_deny" = true ]; then
    log_row retry_allowed "$root"
    exit 0
fi

# The absolute himmel checkout: HIMMEL_REPO, else the cwd's primary checkout.
repo=${HIMMEL_REPO:-}
if [ -z "$repo" ] && command -v git >/dev/null 2>&1 && [ -d "$cwd" ]; then
    common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
    case "$common" in */.git) repo=${common%/.git} ;; esac
fi
case "$repo" in /*) ;; *) exit 0 ;; esac
[ -f "$repo/scripts/lib/qmd-bounded.sh" ] || exit 0
case "$repo" in *[\'\"\$\`\\]*) exit 0 ;; esac

: >"$DIR/$sid.denied" 2>/dev/null || exit 0
log_row deny "$root"

{
    printf 'vault-sweep POC: the first hand sweep of the notes in a session is refused once.\n\n'
    printf 'Search the notes with qmd, which ranks by meaning and reaches every collection:\n'
    printf '  bash %s/scripts/lib/qmd-bounded.sh query -c luna "<question>"\n\n' "$repo"
    printf 'Exactly one retry is allowed: run the same command again and it goes through, and\n'
    printf 'no chief message is needed. An exact ID or marker lookup is still a grep job.\n\n'
    printf 'Bypass: HIMMEL_VAULT_SWEEP_BYPASS=1 in the launching shell (a per-call prefix does not work).\n'
} >&2
exit 2
