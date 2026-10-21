#!/usr/bin/env bash
# guard-bus-store.sh — PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit"): himmel-bus T6, the store
# guard. A SPEED BUMP, not a fence.
#
# WHY: phase 1 of himmel-bus runs every session, the server and the store as one
# uid (threat model T1, T3, T5, T6). The bus API cannot forge a
# sender or reach a peer's log, but a session's own Bash could `cat` another
# session's log, rewrite `peers/*.json`, or bind itself as its console by hand.
# This hook makes those tool-driven routes cost a denial and a named bypass
# instead of one command. Direct writes are DETECTED by the hash chain; prevention
# needs a second uid (spec §12, phase 2).
#
# DENIES:
#   Bash — the command text
#     (a) names the bus root: `himmel/bus` not preceded by [A-Za-z0-9_-]
#         and followed by `/`, end of word or a char outside [A-Za-z0-9_.-] (so
#         the sibling `himmel/bus.json` is not the root) (any spelling of the state home — `$XDG_STATE_
#         HOME/himmel/bus`, `~/.local/state/himmel/bus`, a relative
#         `himmel/bus/log/...`; the hyphenated plugin dir `himmel-bus` is not it).
#         Reads and writes are both denied: a log read is the T5 leak.
#     (b) calls `bus register`, `bus bind` or `bus rebind` (the identity verbs
#         the launcher owns; `bus` bounded the same way, so `bin/bus register`
#         counts). When the text names bus and a verb, the command-position
#         model (scripts/lib/bash-ast.sh) reads it first: `bash -c` / `eval`
#         bodies are read, a quoted string whose tokens put bus before a verb
#         denies (trap, git -c alias, tmux, expect and at run such strings),
#         and a call made only of cat, tee or a non-identity bus verb is data
#         (a heredoc body, a --summary).
#         Every other call goes to the word walker below.
#     (c) assigns a HIMMEL_BUS_* variable (`HIMMEL_BUS_NAME=x claude`, `export
#         ...`, `env ...`), including a name built by quoting or expansion
#         (`HIMMEL_BUS_"NAME"=x`, `HIMMEL_BUS_${x}=1`, `$'HIMMEL_BUS_NAME=x'`).
#         Mentioning one (`echo $HIMMEL_BUS_NAME`,
#         `git grep HIMMEL_BUS_NAME`) is not an assignment and stays allowed.
#   Edit|Write|MultiEdit|NotebookEdit — file_path (notebook_path) names the bus
#     root textually, or resolves to it (`readlink -m`: `..` segments and
#     symlinked components).
# ALLOWS: `bus status|peers|wait|send|adopt` (the CLI stamps `f` from its own
#   process ancestry, so no role check is needed here) and everything else —
#   silently, with no output.
#
# FAIL MODE: an advisory speed bump, fail-closed only for its one subject. A payload it cannot
# parse (missing jq, bad JSON, a non-string command) is scanned as raw text and
# DENIED when it names the bus root; with no mention of the root it is allowed.
# Failing closed on every unparseable call would lock the session out of every
# tool for a hook bug (scripts/hooks/CLAUDE.md fail-open-vs-closed rule).
# A missing bash-ast lib or shfmt, a shfmt parse failure or a jq failure in the
# model leaves (b) to the word walker, so the model never changes this fail mode.
#
# RESIDUAL (deliberate, plan T6, threat model T3/T5/T6): this is text matching,
# not a shell parser or a sandbox. An interpreter that assembles the path
# (`python3 -c "open(os.path.expanduser('~/.local/state/hi'+'mmel/bus/...'))"`),
# a renamed copy of the CLI, `eval`, a script file that itself does the write, a
# `$(...)`-built path, a Bash command reaching the store through a symlink alias
# (only file-tool paths are resolved), or the Read tool pointed at a log are not
# caught. The Read and Grep tools are not wired to this hook. Same-uid tampering that re-chains is
# undetected (phase 2's dedicated uid closes it).
# Also not caught: a separator inside a quoted option value when the model
# cannot read the command, the verb fed on stdin to xargs, the verb or the store
# path held in a shell variable (`v=register; bus $v x`, `$S/bus`: a bare
# expansion carries no literal character to match), an alias for the bare bus
# word (`alias b=bus`), and a symlinked payload cwd or a relative file path against it (all tracked).
# Deliberately over-denied (the safe direction): when the model hands the call
# to the word walker, a verb word anywhere after a bus-able word in one segment
# (`bus send ... --summary "rebind done" $x`), a glob or expansion under `himmel/`
# (`himmel/*`), and any word that can expand to `bus` (`*`, `b?s`, `$x`) once
# the cwd or the command names the himmel state dir. The bypass flag covers all.
# The verb side uses the same normaliser as the `bus` side: a word is verbish
# when, with ANSI-C escapes and expansions turned into `*`, it glob-matches
# register|bind|rebind and keeps at least one literal character
# (`$'reg\x69ster'`, `reg$x`, `r?gister`, `re${x}ister`).
# A substitution opener (`$(`, `<(`, backtick) ends its word and its body is
# judged as a segment of its own: `$(bus register x)` denies, while `diff <(sort a)
# <(sort b)` and `gh pr create --title "$(git log) ..." --body "$(cat f)"` do not
# read as two bus-able words in one segment.
# Closed by shape, not by spelling: backslash-newline continuations are joined
# (the pair removed) before the split; quotes, backslashes and parens are
# stripped per word; a word is bus-able when a path component glob-matches `bus`
# after `${x}`, `$x`, `$'..'` and `{a,b}` become `*`; and the early exit lets any
# payload with a quote, `$`, glob character, backslash or brace expansion through
# to these rules.
#
# Bypass: BUS_STORE_GUARD_OK=1 in the LAUNCHING shell (session-sticky; a per-call
# prefix does not reach this hook process). Needed to register or bind by hand
# (docs/internals/retask-channel.md), since the launcher's own `bus register`
# runs inside a script and never shows up in a tool call.
#
# Platform guard (gitbash-only): env + jq + `readlink -m` where present; runs
# under Git Bash or POSIX bash 3.2+. The bus itself is Linux-only. No .ps1 twin.
#
# Exit codes: 0 allow (no output); 2 deny (JSON hookSpecificOutput with
# permissionDecision "deny" on stdout, reason starting "bus store-deny: ", and
# the same text on stderr — belt-and-braces idiom of guard-leg-wakeup.sh).
set -uo pipefail

[ "${BUS_STORE_GUARD_OK:-}" = "1" ] && exit 0

input=$(cat)

# Fast path, no fork: every Bash rule below needs one of these literals. A JSON
# \u escape could spell them past a raw scan, so it falls through too, and so
# does anything that can build the word `bus` in the shell without writing it:
# a backslash (`b\<nl>us`), a quote (`b''us`; a double quote arrives as the
# JSON escape `\"`, so that pair is a trigger too), a backtick or `$` (`b${x}us`,
# `b$(true)us`), a glob
# character (`b?s`, `b[u]s`, `b*s`) or a brace expansion (`{` not followed by
# the JSON envelope's `"`). A
# file-tool path may reach the store through a symlink alias that carries no
# literal at all, so any payload with a file_path/notebook_path is resolved.
case "$input" in
    *bus*|*BUS*|*'\u'*|*\\\\*|*\\\"*|*\'*|*\$*|*\`*|*\<\(*|*\>\(*|*\**|*\?*|*\[*|*\{[!\"]*|*file_path*|*notebook_path*) ;;
    *) exit 0 ;;
esac

ROOT_RE='(^|[^A-Za-z0-9_-])himmel\\?/bus($|[^A-Za-z0-9_.-])'
# The identity verbs are matched word by word (verb_after_bus below), not by a
# regex: a `bus` word, then later in the SAME segment a word that is exactly
# register|bind|rebind. Options may sit between (`bus --role leg register x`),
# quotes are dropped (`bus 'register' x`, `b''us register x`), and a path such as
# /tmp/register.txt is not a verb.
ENV_RE='(^|[^A-Za-z0-9_])HIMMEL_BUS_[A-Za-z0-9_]*\+?='
# A component right under himmel/ that carries a glob or expansion character
# (`himmel/b?s`, `himmel/b[u]s`, `himmel/$x`) may spell the bus root.
GLOBROOT_RE='(^|[^A-Za-z0-9_-])himmel/[^/[:space:]]*[?*[{$]'

# state_view <text>: $HOME and $XDG_STATE_HOME are the state dir's own spelling,
# so they must not count as a word that could expand to `bus`.
state_view() {
    local LC_ALL=C s="$1"
    s=${s//\$\{XDG_STATE_HOME\}/XDGSTATE}
    s=${s//\$XDG_STATE_HOME/XDGSTATE}
    s=${s//\$\{HOME\}/HOMEDIR}
    s=${s//\$HOME/HOMEDIR}
    printf '%s' "$s"
}
STATE_RE='(^|/)state/himmel/?$'
# The state dir named inside the command: ~/.local/state/himmel, $XDG_STATE_HOME/himmel
# or ${XDG_STATE_HOME}/himmel (the literal XDG value is matched separately).
STATECMD_RE='(state|XDG_STATE_HOME\}?)/himmel($|[^A-Za-z0-9_-])'

# norm <string>: collapse repeated slashes and /./ so himmel//bus and himmel/./bus
# match like himmel/bus. Pure bash, 3.2-safe.
norm() {
    local LC_ALL=C s="$1"
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    while [[ "$s" == *"/./"* ]]; do s=${s//\/.\//\/}; done
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    printf '%s' "$s"
}

# normword <word>: one normaliser for both sides (the `bus` word and the verb).
# Sets NW to the word as a glob pattern and NW_UNK=1 when its value cannot be
# known (a substitution the whitespace split cut open: `b$(printf u)s` arrives
# as `b$(printf` and `u)s`; an unclosed `${`). Inside an ANSI-C span `$'..'`
# the literal characters are kept and each backslash escape becomes `*`
# (`$'reg\x69ster'` -> `reg*ster`); every other expansion (`${x}`, `$x`,
# `$(..)`, backticks, `{a,b}`) becomes `*`; parens, quotes and backslashes are
# then dropped. Pure bash, 3.2-safe.
# shellcheck disable=SC2016  # regex text; nothing is meant to expand
ANSIC_RE='\$'"'"'([^'"'"']*)'"'"
ESC_RE='\\(x[0-9A-Fa-f]{1,2}|[0-7]{1,3}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|.)'
# shellcheck disable=SC2016  # regex text; nothing is meant to expand
EXP_RE='(\$\{[^}]*\}|\$\([^)]*\)|`[^`]*`|\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)'
normword() {
    local w="$1" m inner span o t hd="" ho="" hc
    NW_HAS=0; NW_REST=""
    while [[ "$w" =~ $ANSIC_RE ]]; do
        span="${BASH_REMATCH[0]}"
        inner="${BASH_REMATCH[1]}"
        while [[ "$inner" =~ $ESC_RE ]]; do
            m="${BASH_REMATCH[0]}"
            inner=${inner/"$m"/"*"}
        done
        w=${w/"$span"/"$inner"}
    done
    while [[ "$w" =~ $EXP_RE ]]; do
        m="${BASH_REMATCH[0]}"
        w=${w/"$m"/"*"}
    done
    # A substitution opener the whitespace split left open ends this word; the
    # text after it is the first word of a segment of its own (NW_REST). The
    # head stays a candidate only when it holds a literal character
    # (`b$(printf` -> `b*`), so a bare `$(git` or `<(sort` is no word at all.
    # shellcheck disable=SC2016  # literal opener text, nothing expands
    for o in '$(' '`' '<(' '>(' '${'; do
        case "$w" in
            *"$o"*)
                t=${w%%"$o"*}
                if [ "$NW_HAS" = 0 ] || [ "${#t}" -lt "${#hd}" ]; then hd="$t"; ho="$o"; fi
                NW_HAS=1 ;;
        esac
    done
    # NW_OPEN / NW_CLOSE: parens still open or unmatched in the head (a closed
    # `$(..)` is already `*`); the walker nests and un-nests bodies with them.
    NW_OPENER="$ho"
    if [ "$NW_HAS" = 1 ]; then
        NW_REST=${w#"$hd$ho"}
        hc=${hd//[\'\"\\()]/}
        m=${hd//[^(]/}; NW_OPEN=${#m}
        m=${hd//[^)]/}; NW_CLOSE=${#m}
        if [ -n "$hc" ]; then w="$hd*"; else w=""; fi
    else
        m=${w//[^(]/}; NW_OPEN=${#m}
        m=${w//[^)]/}; NW_CLOSE=${#m}
    fi
    w=${w//\(/}; w=${w//\)/}
    NW=${w//[\'\"\\]/}
}

# A word with none of these characters has nothing to expand: it is busish iff
# a path component is exactly `bus`, verbish iff it is exactly a verb.
PLAIN_RE='[^[:alnum:]_./:=,@%+-]'

# busish <word>: could this shell word be, or contain a path component that is,
# the string `bus` once the shell has expanded it (`b?s`, `b[u]s`, `b*s`, `bus`,
# `$x`)? A component such as `bus.json` or `himmel-bus` is not.
busish() {
    local p parts
    if [[ ! "$1" =~ $PLAIN_RE ]]; then
        case "$1" in bus|bus/*|*/bus|*/bus/*) return 0 ;; esac
        return 1
    fi
    normword "$1"
    IFS=/ read -ra parts <<< "$NW"
    [ "${#parts[@]}" -gt 0 ] || return 1
    for p in "${parts[@]}"; do
        [ -n "$p" ] || continue
        # shellcheck disable=SC2053  # the glob match is the point
        [[ bus == $p ]] && return 0
    done
    return 1
}

# verbish <word>: could this word be register|bind|rebind once expanded? The
# whole word is glob-matched, and at least one literal character has to
# survive, so a bare `$x` or `*` is not a verb (a verb held in a variable is the
# documented residual). A leftover substitution opener is verbish.
verbish() {
    local lit v
    if [[ ! "$1" =~ $PLAIN_RE ]]; then
        case "$1" in register|bind|rebind) return 0 ;; esac
        return 1
    fi
    normword "$1"
    lit=${NW//[\*\?\[\]]/}
    [ -n "$lit" ] || return 1
    for v in register bind rebind; do
        # shellcheck disable=SC2053  # the glob match is the point
        [[ $v == $NW ]] && return 0
    done
    return 1
}

# walk_words <mode> <text>: per command segment (; & | newline), per word.
# A substitution opener left open by the word split (`$(`, `<(`, `>(`, backtick,
# `(`) ends its word and the text after it is a body nested in the segment: the
# outer `seen` is saved when the body opens and OR-ed back when it closes (a
# close never lowers it), so `$(bus register x)` is judged as `bus register x`,
# `diff <(sort a) <(sort b)` is two bodies, not two bus-able words (a bare opener
# is no candidate), and `bus $(true) register x` still has its bus word when the
# verb comes back in the outer segment. The body inherits the outer `seen` (a
# close that is never found keeps the rest of the segment outer, fail closed).
# mode `bus`: any busish word; mode `verb`: a busish word and, later in the same
# segment, a verbish one.
# ponytail: a text walker cannot close the shell-parsing class (parens are
# counted without modelling quotes; each round finds another spelling), so the
# hook stays advisory; upgrade path is HIMMEL-5238 (store reachable only through
# the bus CLI by permission or ownership) and HIMMEL-5233.
walk_words() {
    local mode="$1" seg word words seen rest has stk n nopen nclose opener
    while IFS= read -r seg; do
        read -ra words <<< "$seg"
        [ "${#words[@]}" -gt 0 ] || continue
        seen=0; stk=""
        for word in "${words[@]}"; do
            rest="$word"
            while [ -n "$rest" ]; do
                if [[ ! "$rest" =~ $PLAIN_RE ]]; then
                    has=0; word="$rest"; rest=""; nopen=0; nclose=0; opener=""
                else
                    normword "$rest"
                    # Snapshot: busish/verbish below run normword again.
                    has=$NW_HAS; rest="$NW_REST"; word="$NW"
                    nopen=$NW_OPEN; nclose=$NW_CLOSE; opener="$NW_OPENER"
                fi
                if [ -n "$word" ]; then
                    if [ "$mode" = bus ]; then
                        busish "$word" && return 0
                    else
                        if [ "$seen" = 1 ]; then verbish "$word" && return 0; fi
                        busish "$word" && seen=1
                    fi
                fi
                # Closers in this piece end bodies; open parens and the opener
                # itself start one. A backtick closes a backtick body. A pop never
                # lowers seen (outer OR inner): parens are counted without
                # modelling quotes, so a quoted `')'` may close a body early and
                # must not hide the verb.
                n=$nclose
                while [ "$n" -gt 0 ]; do
                    if [ -n "$stk" ]; then seen=$(( ${stk: -2:1} | seen )); stk=${stk%??}; fi
                    n=$((n - 1))
                done
                n=$nopen
                while [ "$n" -gt 0 ]; do
                    stk="$stk${seen}p"; n=$((n - 1))
                done
                if [ "$has" = 1 ]; then
                    # shellcheck disable=SC2016  # literal opener text
                    case "$opener" in
                        '`')
                            if [ "${stk: -1}" = b ]; then seen=$(( ${stk: -2:1} | seen )); stk=${stk%??}
                            else stk="$stk${seen}b"; fi ;;
                        '${') ;;
                        *) stk="$stk${seen}p" ;;
                    esac
                fi
            done
        done
    done <<< "$(printf '%s' "$2" | tr ';&|' '\n')"
    return 1
}

# cmd_busish <text>: does any word of any command segment look like `bus`?
cmd_busish() { walk_words bus "$1"; }

# verb_after_bus <text>: a segment with a busish word and, later in the same
# segment, a verbish word. Options may sit between them.
verb_after_bus() { walk_words verb "$1"; }

# Every HIMMEL_BUS_* variable the repo uses. Source:
#   git grep -ho 'HIMMEL_BUS_[A-Z_]*' -- scripts marketplace/plugins/himmel-bus
# (HIMMEL_BUS_NAME; the bare `HIMMEL_BUS_` hits are the prefix in prose). A name
# that matches none of these still falls to the `HIMMEL_BUS_*` pattern test.
BUS_ENV_NAMES='HIMMEL_BUS_NAME'

# env_assign_word <text>: a segment word that is not plain, holds `=`, and whose
# normalised name part (before the first `=`, trailing `+` dropped, at least one
# literal char surviving) can be a HIMMEL_BUS_* variable: `HIMMEL_BUS_${x}=1`,
# `HIM${y}EL_BUS_NAME=x`, `$'HIMMEL_BUS_NAME=x'`. A bare `"$k=$v"` has no
# literal char and is the documented residual. Plain words are
# the raw/quote-stripped ENV_RE's job.
env_assign_word() {
    local seg word words name lit v
    while IFS= read -r seg; do
        read -ra words <<< "$seg"
        [ "${#words[@]}" -gt 0 ] || continue
        for word in "${words[@]}"; do
            [[ "$word" == *=* ]] || continue
            [[ "$word" =~ $PLAIN_RE ]] || continue
            normword "$word"
            [[ "$NW" == *=* ]] || continue
            name=${NW%%=*}
            name=${name%+}
            lit=${name//[\*\?\[\]]/}
            [ -n "$lit" ] || continue
            # shellcheck disable=SC2053  # the glob match is the point
            [[ $name == HIMMEL_BUS_* ]] && return 0
            for v in $BUS_ENV_NAMES HIMMEL_BUS_ HIMMEL_BUS_x; do
                # shellcheck disable=SC2053  # the glob match is the point
                [[ $v == $name ]] && return 0
            done
        done
    done <<< "$(printf '%s' "$1" | tr ';&|' '\n')"
    return 1
}

deny() {
    local msg reason
    msg="bus store-deny: $1. himmel-bus keeps its store off-limits to a session's own tool calls (a soft block (speed bump), HIMMEL-4829). Allowed: bus status|peers|wait|send|adopt. Registration is the launcher's. Bypass: BUS_STORE_GUARD_OK=1 in the launching shell."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) || reason='"bus store-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

# The verdict over bash_ast_positions output: deny when one position's literal
# words hold a bus word (`bus`, or a path component `bus`) and, later, a word that
# is exactly register|bind|rebind. One literal word, an argument or a redirect
# word such as a here-string, is a string some command may run (trap, git -c
# alias, tmux, expect, at): a bus token followed by a verb token inside it
# denies too.
# The model allows only a call whose every position is cat, tee or a bus
# status|peers|wait|send|adopt with literal words: none of them runs a string,
# so a heredoc or a --summary naming bus and a verb is data.
# Every other call is "legacy": the word walker reads the text then, with its
# own quote and backslash handling and its split across words.
# swallow-ok: read -d '' on a literal heredoc always returns 1 at EOF
IFS= read -r -d '' BS_JQ <<'BS_JQ_EOF' || true
def base: (. // "") | sub("^.*/"; "");
def lit: .t == "lit" and (.g | not);
def isbus: lit and (.v | split("/") | any(. == "bus"));
def verb: IN("register", "bind", "rebind");
def isverb: lit and (.v | verb);
def tokens: [.v | scan("[A-Za-z0-9_.-]+")];
def ordered: lit and (tokens as $t | any(range(0; $t | length); $t[.] == "bus" and any($t[. + 1:][]; verb)));
def rwords: [(.redirs // [])[] | .w | select(. != null)];
def sink: .opaque == null and ((.via // []) | length == 0) and all(.argv[], rwords[]; lit)
  and (((.prog | base) | IN("cat", "tee"))
    or ((.prog | base) == "bus" and (.argv[1].v // "" | IN("status", "peers", "wait", "send", "adopt"))));
def bad: .argv as $a
  | any(range(0; $a | length); ($a[.] | isbus) and any($a[. + 1:][]; isverb))
  or any($a[], rwords[]; ordered);
if any(.[]; bad) then "deny"
elif length > 0 and all(.[]; sink) then "allow"
else "legacy" end
BS_JQ_EOF

# model_verdict <cmd>: deny, allow or legacy. The fail mode is the word walker's:
# a missing lib or shfmt, a parse failure or a jq failure is "legacy".
model_verdict() {
    local lib pos v
    lib=${BASH_SOURCE[0]%/*}/../lib/bash-ast.sh
    # shellcheck source=../lib/bash-ast.sh
    if ! { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then
        echo legacy; return
    fi
    pos=$(bash_ast_positions "$1" 2>/dev/null) || { echo legacy; return; } # swallow-ok: legacy hands the call to the unchanged word walker
    v=$(printf '%s' "$pos" | jq -r "$BS_JQ" 2>/dev/null) || v=legacy # swallow-ok: legacy hands the call to the unchanged word walker
    case "$v" in deny | allow) echo "$v" ;; *) echo legacy ;; esac
}

raw_scan() {
    [[ "$input" =~ $ROOT_RE ]] && deny "the call names the himmel-bus store (payload not parseable, scanned as raw text)"
    exit 0
}

command -v jq >/dev/null 2>&1 || raw_scan
tool=$(printf '%s' "$input" | jq -r '.tool_name | strings' 2>/dev/null) || raw_scan
[ -n "$tool" ] || raw_scan

case "$tool" in
    Bash)
        cmd=$(printf '%s' "$input" | jq -er '.tool_input.command | strings' 2>/dev/null) || raw_scan
        # Join backslash-newline continuations first: `bus \<nl> --role x \<nl>
        # register y` is one command to the shell and must be one segment here.
        # The pair is removed, not replaced: bash joins `reg\<nl>ister` into one word.
        bsnl=$'\\\n'
        # Guarded: a pattern substitution on a large multibyte string is
        # superlinear, so it only runs when there is a pair.
        if [[ "$cmd" == *"$bsnl"* ]]; then cmd=${cmd//"$bsnl"/}; fi
        cmd_n=$(norm "$cmd")
        xdg_state=""
        [ -n "${XDG_STATE_HOME:-}" ] && xdg_state=$(norm "${XDG_STATE_HOME}/himmel") && xdg_state=${xdg_state%/}
        [[ "$cmd" =~ $ROOT_RE || "$cmd_n" =~ $ROOT_RE ]] && deny "the command names the himmel-bus store (reads and writes under the bus root are off-limits)"
        # Quotes dropped: b''us, himmel/"bus" and the like name the same path.
        # (`tr`, not a substitution: linear on a large payload.)
        cmd_q=$(printf '%s' "$cmd" | tr -d "\"'\\\\")
        cmd_qn=$(norm "$cmd_q")
        [[ "$cmd_qn" =~ $ROOT_RE ]] && deny "the command names the himmel-bus store (reads and writes under the bus root are off-limits)"
        # A glob or expansion in the component right under himmel/ can spell bus.
        [[ "$cmd_qn" =~ $GLOBROOT_RE ]] && deny "the command reaches under himmel/ through a glob or expansion that can spell the bus root"
        # In-command cd: the command names the state dir and a word that can be bus.
        state_named=0
        [[ "$cmd_n" =~ $STATECMD_RE ]] && state_named=1
        [ -n "$xdg_state" ] && [[ "$cmd_n" == *"$xdg_state"* ]] && state_named=1
        if [ "$state_named" = 1 ]; then
            cmd_busish "$(state_view "$cmd_n")" && deny "the command names the himmel state dir and a word that can be bus (relative store path)"
        fi
        # cwd indirection: a relative path is read against the payload cwd.
        cwd=$(printf '%s' "$input" | jq -er '.cwd | strings' 2>/dev/null) || cwd=""
        if [ -n "$cwd" ]; then
            cwd_r=$(readlink -m -- "$cwd" 2>/dev/null) || cwd_r=""
            for c in "$cwd" "$cwd_r"; do
                [ -n "$c" ] || continue
                c_n=$(norm "$c")
                [[ "$c_n/" =~ $ROOT_RE ]] && deny "the working directory is under the himmel-bus store"
                if [[ "$c_n" =~ $STATE_RE ]] || { [ -n "$xdg_state" ] && [ "${c_n%/}" = "$xdg_state" ]; }; then
                    cmd_busish "$(state_view "$cmd_n")" && deny "the working directory is the himmel state dir and the command names a word that can be bus (relative store path)"
                fi
            done
        fi
        # Identity verbs: the command-position model first, when the text names
        # bus and a verb; the per-segment word walker otherwise.
        verdict=legacy
        case "$cmd_q" in
            *bus*) case "$cmd_q" in *register* | *bind*) verdict=$(model_verdict "$cmd") ;; esac ;;
        esac
        [ "$verdict" = deny ] && deny "bus register|bind|rebind is the launcher's, not a session's"
        if [ "$verdict" != allow ]; then
            verb_after_bus "$cmd" && deny "bus register|bind|rebind is the launcher's, not a session's"
        fi
        [[ "$cmd" =~ $ENV_RE || "$cmd_q" =~ $ENV_RE ]] && deny "a session does not set HIMMEL_BUS_* for itself or a child"
        env_assign_word "$cmd" && deny "a session does not set HIMMEL_BUS_* for itself or a child (name built by quoting or expansion)"
        ;;
    Edit|Write|MultiEdit|NotebookEdit)
        path=$(printf '%s' "$input" | jq -er '(.tool_input.file_path // .tool_input.notebook_path) | strings' 2>/dev/null) || raw_scan
        path=$(norm "$path")
        [[ "$path" =~ $ROOT_RE ]] && deny "the target path is under the himmel-bus store"
        resolved=$(readlink -m -- "$path" 2>/dev/null) || resolved=""
        [ -n "$resolved" ] && [[ "$resolved" =~ $ROOT_RE ]] && deny "the target path resolves under the himmel-bus store"
        ;;
esac
exit 0
