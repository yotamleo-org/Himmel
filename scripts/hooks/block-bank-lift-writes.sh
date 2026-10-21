#!/usr/bin/env bash
# PreToolUse hook (Bash | Edit|Write|MultiEdit|NotebookEdit | apply_patch) —
# Keeps to the literal-path core. The usage lift
# (~/.himmel/state/usage-lift.json, written by `scripts/lib/usage-lift.sh set`;
# the old names bank-lift.json / bank-lift.sh are fenced the same way)
# relaxes the 7-day bank gate while it is valid. Raising your own
# spending ceiling is an OPERATOR call, so an agent session may not:
#   1. write the lift file by a LITERAL path (~, $HOME, ${HOME}, /home/<user>,
#      relative, a case-folded or glob spelling of the name, a symlink or a
#      symlinked directory that resolves to it) with a redirect, tee/sponge/
#      touch/truncate/patch/ex/ed, cp/mv/install/ln/rsync (a rename-replace
#      onto it included), dd of=, sed -i / sed w, an -o/--output option, an
#      interpreter handed the path or inline code that spells its name, or the
#      Write/Edit/NotebookEdit/apply_patch tools; nor fill the state dir (or an
#      ancestor of it) with a lift-named entry;
#   2. run `usage-lift.sh set` or `bank-lift.sh set` (bash/sh/direct/source/.;
#      through env, sudo, timeout, nice-style wrappers; in a bash -c / eval /
#      stdin script, a literal echo/printf piped into a shell included), or
#      copy either script to another name.
# Reading the lift, `usage-lift.sh show` / `clear`, and any text that merely
# NAMES the lift (a commit message, a ticket title, a Results bullet) stay
# allowed. Remedy named in every deny: the operator runs
# `! bash scripts/lib/usage-lift.sh set ...` at their own prompt. There is
# deliberately NO env bypass — a bypass an agent can request is the very thing
# this fence exists to remove.
#
# Layering: this is a text guard for common mistakes and known shapes, not a
# proof. A spelling that needs evaluation to read is NOT chased here; it
# belongs to the OS (sandbox) layer. Left to that layer: a destination built from a variable the command
# assigns, from $( ) / backticks or `$_`; an inherited env value or a ${E-x} /
# ${!R} / zsh-flag expansion naming the lift; a brace-built or split ("bank"+
# "-lift") name; the lift path handed to a writer through a reader, xargs or
# find -exec; a shell reading a script a file or a non-literal word supplies
# (`cat f | bash`, `echo "$x" | bash`); an archive extraction (tar/unzip/cpio/7z/…) into HOME or the
# state dir, with or without a symlink member; a variable command word; sed's
# `e` command and `s///e` flag; `less --log-file=`.
#
# Fail-closed (security fence): missing jq, malformed / non-object JSON, or a
# tokenizer error -> deny. Any other non-0/2 exit is clamped to 2.
#
# ponytail: text-level literal-path fence, sandbox layer HIMMEL-5685 owns the rest — it cannot see Write-tool CONTENT
# that is itself a script writing the lift, a script FILE that writes the lift
# without being handed its path, or a bind mount. Those are bounded at RUNTIME:
# bank-preflight honours only an account-bound lift capped by the seven_day
# resets_at and fails closed on anything else, so a forged lift buys at most
# the rest of one window; upgrade path is an operator-owned lift the gate verifies.
# ponytail: a `cd`/`pushd`/`popd` word anywhere makes the cwd unknown, so a
# relative word is judged by its name alone (a lift-named word denies, any
# other relative word is allowed); upgrade path is a cd model, only if a
# transcript shows a relative write that slipped through.
# ponytail: macOS `readlink -m` is unavailable (HIMMEL-5352), so a dangling-symlink chain
# resolves one readlink hop at a time; accepted ceiling.
# ponytail: the PowerShell tool is not wired, Windows is parked under
# HIMMEL-4102 — wire it when Windows legs resume.
#
# Hook I/O: JSON on stdin; exit 0 = allow, exit 2 = block (stderr shown).
# Platform guard: bash 3.2-safe (no mapfile, no associative arrays).
set -uo pipefail
# shellcheck disable=SC2154  # rc is set inside the single-quoted trap body
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    {
        echo "block-bank-lift-writes: refusing — $1."
        echo
        echo "    ~/.himmel/state/usage-lift.json (old name bank-lift.json) relaxes the"
        echo "    7-day usage gate, so setting it is operator-only. Ask the operator"
        echo "    to run, at their own prompt:"
        echo
        echo "        ! bash scripts/lib/usage-lift.sh set ..."
        echo
        echo "    Reading the lift, \`usage-lift.sh show\` and \`usage-lift.sh clear\` stay"
        echo "    allowed. There is no env bypass: the operator's own command is the path."
    } >&2
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "jq not found on PATH (fail-closed)"
input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || deny "malformed or non-object JSON payload (fail-closed)"

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || deny "unreadable tool_name (fail-closed)"
case "$tool" in
    Bash|Write|Edit|MultiEdit|NotebookEdit|apply_patch) ;;
    *) exit 0 ;;
esac
CWD=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD=$PWD

LIFT_NAMES='usage-lift.json bank-lift.json'  # the new name, then the read-both old one
STATE_REAL="$HOME/.himmel/state"
CWD_UNPROVEN=0  # set for Bash: a cd/pushd/popd word makes the cwd unknown
LREF=NONE       # lift_ref result: LIFT | STATE | HIMMEL | HOME | NONE
DK=NONE         # _dir_kind result: STATE | HIMMEL | HOME | UNKNOWN | NONE
EXP=""          # _expand result
NORM=""         # _norm result

# ---------------------------------------------------------------- paths ---
# These helpers return through globals (LREF, DK, EXP, NORM), never through
# $( ): a command substitution is a fork per path reference.

# _norm <abs-path> -> NORM = lexically normalised (., .., //), no trailing slash.
_norm() {
    local p="$1" out="" seg rest
    rest="${p#/}"
    while [ -n "$rest" ]; do
        case "$rest" in */*) seg="${rest%%/*}"; rest="${rest#*/}" ;; *) seg="$rest"; rest="" ;; esac
        case "$seg" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    NORM="${out:-/}"
}

# _expand <word> -> EXP = word with ~ / ~user / $HOME / ${HOME} expanded and,
# when the cwd is known, made absolute. "?/<word>" for an unknown directory.
# shellcheck disable=SC2088,SC2016  # literal ~ / $HOME spellings are matched as text
_expand() {
    local w="$1"
    case "$w" in
        '~') w="$HOME" ;;
        '~/'*) w="$HOME/${w#\~/}" ;;
        '~'*) w="/home/${w#\~}" ;;
        '$HOME'|'${HOME}') w="$HOME" ;;
        '$HOME/'*) w="$HOME/${w#\$HOME/}" ;;
        '${HOME}/'*) w="$HOME/${w#\$\{HOME\}/}" ;;
    esac
    case "$w" in
        /*) ;;
        '$'*|'`'*) EXP="?/$w"; return ;;
        *) if [ "$CWD_UNPROVEN" = 1 ]; then EXP="?/$w"; return; fi; w="$CWD/$w" ;;
    esac
    # A `..` after a symlink climbs out of the link's TARGET, not out of the
    # lexical parent: resolve the existing directory part physically.
    case "$w" in
        *..*)
            local d="${w%/*}" b="${w##*/}" pd
            case "$b" in .|..) d="$w"; b="" ;; esac
            if pd=$(CDPATH='' cd -P -- "${d:-/}" 2>/dev/null && pwd -P); then
                w="$pd${b:+/$b}"
            fi
            ;;
    esac
    _norm "$w"; EXP=$NORM
}

_is_dynamic() { case "$1" in *'$'*|*'`'*) return 0 ;; esac; return 1; }

# _name_matches <component-from-word> <real-name>: the word component could
# name real-name (literal, glob, case-folded), or is dynamic.
_name_matches() {
    _is_dynamic "$1" && return 0
    _name_match1 "$1" "$2"
}
_name_match1() {
    # Case-folded only here: option parsing elsewhere is case-sensitive (-t/-T).
    local r=1
    shopt -s nocasematch extglob
    # shellcheck disable=SC2053  # the RHS is deliberately a pattern
    [[ "$2" == $1 ]] && r=0
    shopt -u nocasematch extglob
    return "$r"
}

# _dir_kind <expanded-dir> -> DK = STATE | HIMMEL | HOME | UNKNOWN | NONE
_dir_kind() {
    local d="$1" last parent
    last="${d##*/}"; parent="${d%/*}"; parent="${parent##*/}"
    # .himmel/state is two components. A slash-less word (a JSON argument) has
    # parent == last == the whole word. Tested before the unknown-cwd return so
    # a relative `.himmel/state` still reads as the state dir.
    if [ -n "$last" ] && [ -n "$parent" ] && [ "$d" != "$last" ] && ! _is_dynamic "$d" && _name_matches "$parent" .himmel && _name_matches "$last" state; then
        DK=STATE; return
    fi
    case "$d" in '?'|'?/'*) DK=UNKNOWN; return ;; esac
    if _is_dynamic "$d"; then DK=UNKNOWN; return; fi
    if [ -d "$d" ] && [ -d "$STATE_REAL" ] && [ "$d" -ef "$STATE_REAL" ]; then DK=STATE; return; fi
    if [ -n "$last" ] && _name_matches "$last" .himmel; then DK=HIMMEL; return; fi
    if [ -d "$d" ] && [ -d "$HOME/.himmel" ] && [ "$d" -ef "$HOME/.himmel" ]; then DK=HIMMEL; return; fi
    if [ "$d" = "$HOME" ] || { [ -d "$d" ] && [ -d "$HOME" ] && [ "$d" -ef "$HOME" ]; }; then DK=HOME; return; fi
    case "$d" in /home/*/*|/Users/*/*|/root/*) ;; /home/*|/Users/*|/root) DK=HOME; return ;; esac
    DK=NONE
}

# _is_lift_name <component>: the component could name either lift file.
_is_lift_name() {
    local n
    for n in $LIFT_NAMES; do _name_matches "$1" "$n" && return 0; done
    return 1
}
# _is_lift_script <component>: the component could name either lift script.
_is_lift_script() { _name_matches "$1" usage-lift.sh || _name_matches "$1" bank-lift.sh; }

# _is_pure_glob <s>: nothing left after removing glob metacharacters.
_is_pure_glob() { local t="${1//[\*\?\[\]\{\},]/}"; [ -z "$t" ]; }

# _lift_ref1 <word> [depth] -> LREF. LIFT = the word may name the lift file
# itself (also through a symlink, dangling ones included); STATE | HIMMEL |
# HOME = it names an ancestor directory a whole-directory write could put a
# lift into.
_lift_ref1() {
    local w="$1" depth="${2:-0}" e dir base tgt n
    LREF=NONE
    [ -n "$w" ] || return 0
    _expand "$w"; e=$EXP
    case "$e" in
        '?/'*)
            # Unproven cwd: a relative word may still be a symlink to the lift
            # from the hook's own cwd, so resolve it there too.
            w="${e#\?/}"
            case "$w" in
                /*|'$'*|'`'*|'~'*) ;;
                *) _lift_ref1 "$CWD/$w" $((depth+1)); [ "$LREF" = LIFT ] && return 0; LREF=NONE ;;
            esac
            ;;
        *)
            for n in $LIFT_NAMES; do
                if [ -e "$STATE_REAL/$n" ] && [ -e "$e" ] && [ "$e" -ef "$STATE_REAL/$n" ]; then
                    LREF=LIFT; return 0
                fi
            done
            if [ -L "$e" ] && [ "$depth" -lt 8 ]; then
                tgt=$(readlink "$e" 2>/dev/null) || tgt=""
                if [ -n "$tgt" ]; then
                    case "$tgt" in /*) ;; *) tgt="${e%/*}/$tgt" ;; esac
                    _lift_ref1 "$tgt" $((depth+1)); [ "$LREF" = LIFT ] && return 0; LREF=NONE
                fi
            fi
            ;;
    esac
    base="${e##*/}"; dir="${e%/*}"
    [ -n "$dir" ] || dir=/
    _dir_kind "$dir"
    if [ -n "$base" ] && _is_lift_name "$base"; then
        case "$DK" in
            STATE) LREF=LIFT; return 0 ;;
            # Unknown dir: only a lift-NAMED word (not `$x`, not a bare `*`).
            UNKNOWN) if ! _is_dynamic "$base" && ! _is_pure_glob "$base"; then LREF=LIFT; return 0; fi ;;
        esac
    fi
    # The word itself as a directory.
    _dir_kind "$e"
    case "$DK" in STATE|HIMMEL|HOME) LREF=$DK; return 0 ;; esac
    LREF=NONE
}
is_lift() { _lift_ref1 "$1" 0; [ "$LREF" = LIFT ]; }

# _names_lift_lit <text>: the text spells a lift file or script name
# (usage-lift / bank-lift, .json / .sh) literally, in any case (inline
# interpreter code).
_names_lift_lit() {
    case "$1" in
        *[bB][aA][nN][kK]-[lL][iI][fF][tT].[jJ][sS][oO][nN]*|*[bB][aA][nN][kK]-[lL][iI][fF][tT].[sS][hH]*) return 0 ;;
        *[uU][sS][aA][gG][eE]-[lL][iI][fF][tT].[jJ][sS][oO][nN]*|*[uU][sS][aA][gG][eE]-[lL][iI][fF][tT].[sS][hH]*) return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------ file tools ---
case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
        p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) \
            || deny "unreadable tool_input (fail-closed)"
        if [ -n "$p" ] && is_lift "$p"; then deny "$tool targets the bank lift ($p)"; fi
        exit 0
        ;;
    apply_patch)
        patch=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // ""' 2>/dev/null) \
            || deny "unreadable apply_patch payload (fail-closed)"
        while IFS= read -r ln; do
            ln="${ln%$'\r'}"
            case "$ln" in
                '*** Add File: '*) p="${ln#\*\*\* Add File: }" ;;
                '*** Update File: '*) p="${ln#\*\*\* Update File: }" ;;
                '*** Move to: '*) p="${ln#\*\*\* Move to: }" ;;
                *) continue ;;
            esac
            if is_lift "$p"; then deny "apply_patch targets the bank lift ($p)"; fi
        done <<EOF
$patch
EOF
        exit 0
        ;;
esac

# ------------------------------------------------------------------ Bash ---
CMD=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || deny "unreadable command (fail-closed)"
# CRLF text must not hide a target: strip CRs at the capture boundary.
CMD="${CMD//$'\r'/}"
[ -n "$CMD" ] || exit 0
# The tokenizer marks below start with the control byte \002, so no word of
# the command can spell one; the byte in the input itself is refused.
case "$CMD" in *$'\002'*|*$'\003'*|*$'\004'*|*$'\005'*|*$'\036'*|*$'\037'*) deny "the command carries a tokenizer control byte (\\x02-\\x05, \\x1e, \\x1f)" ;; esac

read -r -d '' TOKENIZER <<'AWK'
function hexv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function addc(c) { if (c == SB || c == US || c == NL || c == BO || c == BC || c == CM) forged = 1; tok = tok c }
function emit_tok() {
    pe = 0
    if (tok != "" || quoted) { buf[d] = buf[d] (bn[d]++ ? US : "") tok }
    tok = ""; quoted = 0
}
function emit_mark(m) { emit_tok(); buf[d] = buf[d] (bn[d]++ ? US : "") m }
function flush(   l) {
    emit_tok()
    if (bn[d] > 0) { l = buf[d]; gsub(/\n/, NL, l); print l }
    buf[d] = ""; bn[d] = 0
}
function open_sub(t) {
    savetok[d] = tok "$"; d++; typ[d] = t; ret[d] = mode
    tok = ""; quoted = 0; buf[d] = ""; bn[d] = 0; mode = "o"
}
function close_sub(   m) {
    m = ret[d]; flush(); d--; mode = m; tok = savetok[d]; quoted = 1
}
function heredocs(   k, body, line, e, del, stripped) {
    for (k = 1; k <= nhd; k++) {
        body = ""; del = hd[k]
        while (i < n) {
            e = index(substr(s, i + 1), "\n")
            if (e == 0) { line = substr(s, i + 1); i = n } else { line = substr(s, i + 1, e - 1); i = i + e }
            stripped = line; sub(/^\t+/, "", stripped)
            if (stripped == del) break
            body = body (body == "" ? "" : "\n") line
        }
        if (!hdq[k]) subs(body)
        gsub(/\n/, NL, body); print SB "B" US body
    }
    nhd = 0
}
# An unquoted-delimiter heredoc body runs its $( ) and backtick commands:
# print each as "\002S\037<command>" (nesting counted on parens, quotes not).
function subs(b,   p, L, j, dep, x, inner, e) {
    L = length(b); p = 1
    while (p <= L) {
        x = substr(b, p, 1)
        if (x == "\\") { p += 2; continue }
        if (x == "$" && substr(b, p + 1, 1) == "(") {
            dep = 1; j = p + 2
            while (j <= L && dep > 0) {
                x = substr(b, j, 1)
                if (x == "\\") { j += 2; continue }
                if (x == "(") dep++; else if (x == ")") dep--
                j++
            }
            inner = dep > 0 ? substr(b, p + 2) : substr(b, p + 2, j - p - 3)
            gsub(/\n/, NL, inner); print SB "S" US inner
            p = j; continue
        }
        if (x == "`") {
            e = index(substr(b, p + 1), "`")
            if (e == 0) { inner = substr(b, p + 1); j = L + 1 } else { inner = substr(b, p + 1, e - 1); j = p + e + 1 }
            gsub(/\n/, NL, inner); print SB "S" US inner
            p = j; continue
        }
        p++
    }
}
{ s = (NR > 1 ? s "\n" : "") $0 }
END {
    US = "\037"; NL = "\036"; SB = "\002"; BO = "\003"; BC = "\004"; CM = "\005"; FDRE = "^([0-9]+|[{][A-Za-z_][A-Za-z0-9_]*[}])$"; forged = 0; pe = 0
    n = length(s); d = 0; mode = "o"; tok = ""; quoted = 0; nhd = 0
    buf[0] = ""; bn[0] = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); c2 = substr(s, i + 1, 1)
        if (mode == "s") { if (c == "'") mode = "o"; else addc(c); continue }
        if (mode == "a") {
            if (c == "'") { mode = "o"; continue }
            if (c != "\\") { addc(c); continue }
            i++; c = substr(s, i, 1)
            if (c == "n") addc("\n"); else if (c == "t") addc("\t"); else if (c == "r") addc("\r")
            else if (c == "x") {
                v = 0; k = 0
                while (k < 2 && hexv(substr(s, i + 1, 1)) >= 0) { v = v * 16 + hexv(substr(s, i + 1, 1)); i++; k++ }
                addc(sprintf("%c", v))
            } else if (c == "u" || c == "U") {
                v = 0; k = 0
                while (k < (c == "u" ? 4 : 8) && hexv(substr(s, i + 1, 1)) >= 0) { v = v * 16 + hexv(substr(s, i + 1, 1)); i++; k++ }
                addc(v < 128 ? sprintf("%c", v) : "?")
            } else if (c ~ /[0-7]/) {
                v = c + 0; k = 1
                while (k < 3 && substr(s, i + 1, 1) ~ /[0-7]/) { v = v * 8 + substr(s, i + 1, 1); i++; k++ }
                addc(sprintf("%c", v))
            } else if (c == "c") { i++ }
            else if (c == "a" || c == "b" || c == "e" || c == "E" || c == "f" || c == "v") { }
            else addc(c)
            continue
        }
        if (mode == "q") {
            if (c == "\"") { mode = "o"; continue }
            if (c == "\\" && (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\")) { addc(c2); i++; continue }
            if (c == "\\" && c2 == "\n") { i++; continue }
            if (c == "$" && c2 == "(") { i++; open_sub("p"); continue }
            if (c == "`") { open_sub("b"); continue }
            addc(c); continue
        }
        # mode o
        if (c == " " || c == "\t") { emit_tok(); continue }
        if (c == "\n") { flush(); if (nhd > 0) heredocs(); continue }
        if (c == "\\") { if (c2 == "\n") { i++; continue } addc(c2); quoted = 1; i++; continue }
        if (c == "'") { mode = "s"; quoted = 1; continue }
        if (c == "\"") { mode = "q"; quoted = 1; continue }
        if (c == "$" && c2 == "'") { mode = "a"; quoted = 1; i++; continue }
        if (c == "$" && c2 == "{") { addc(c); addc(c2); pe = 1; i++; continue }
        if (c == "$" && c2 == "(") { i++; open_sub("p"); continue }
        if (c == "`") { if (d > 0 && typ[d] == "b") close_sub(); else open_sub("b"); continue }
        if (c == "#" && tok == "" && !quoted) {
            while (i < n && substr(s, i + 1, 1) != "\n") i++
            continue
        }
        if (c == ")") { if (d > 0 && typ[d] == "p") close_sub(); else flush(); continue }
        if ((c == "<" || c == ">") && c2 == "(") { emit_tok(); i++; open_sub("p"); continue }
        if (c == "&" && c2 == ">") {
            i++
            if (substr(s, i + 1, 1) == ">") i++
            if (substr(s, i + 1, 1) == "!") { i++; emit_mark(SB "C") } else emit_mark(SB "W")
            continue
        }
        if (c == ";" || c == "&" || c == "|" || c == "(") { flush(); continue }
        if (c == ">") {
            if (!quoted && tok ~ FDRE) tok = ""
            j = i + 1; bang = 0
            if (substr(s, j, 1) == ">") j++
            if (substr(s, j, 1) == "|") j++
            if (substr(s, j, 1) == "!") { j++; bang = 1 }
            if (substr(s, j, 1) == "&") {
                j++
                if (substr(s, j, 1) ~ /[0-9-]/) {
                    while (substr(s, j, 1) ~ /[0-9-]/) j++
                    emit_tok(); i = j - 1; continue
                }
                if (substr(s, j, 1) == "!") { j++; bang = 1 }
            }
            emit_mark(SB (bang ? "C" : "W")); i = j - 1; continue
        }
        if (c == "<") {
            if (!quoted && tok ~ FDRE) tok = ""
            if (c2 == ">") { emit_mark(SB "W"); i++; continue }
            if (c2 == "&") {
                emit_tok(); i++
                while (substr(s, i + 1, 1) ~ /[0-9-]/) i++
                continue
            }
            if (c2 == "<" && substr(s, i + 2, 1) == "<") { emit_mark(SB "R"); i += 2; continue }
            if (c2 == "<") {
                emit_tok(); i++
                if (substr(s, i + 1, 1) == "-") i++
                while (substr(s, i + 1, 1) == " " || substr(s, i + 1, 1) == "\t") i++
                del = ""; dq = 0; inq = ""
                # HIMMEL-4458: the delimiter is one shell word — quoted parts
                # keep spaces and the other quote char, `\` escapes as bash's.
                while (i < n) {
                    x = substr(s, i + 1, 1)
                    if (x == "\n") break
                    if (inq == "'") { if (x == "'") inq = ""; else del = del x; i++; continue }
                    if (inq == "\"") {
                        if (x == "\"") { inq = ""; i++; continue }
                        if (x == "\\" && substr(s, i + 2, 1) ~ /[$`"\\]/) { del = del substr(s, i + 2, 1); i += 2; continue }
                        del = del x; i++; continue
                    }
                    if (x ~ /[ \t;&|<>()]/) break
                    if (x == "'" || x == "\"") { inq = x; dq = 1; i++; continue }
                    if (x == "\\") { dq = 1; if (substr(s, i + 2, 1) != "\n") del = del substr(s, i + 2, 1); i += 2; continue }
                    del = del x; i++
                }
                hd[++nhd] = del; hdq[nhd] = dq
                continue
            }
            emit_mark(SB "R"); continue
        }
        if (pe > 0) { if (c == "{") pe++; else if (c == "}") pe--; addc(c); continue }
        addc(c)
    }
    while (d > 0) { flush(); d-- }
    flush()
    if (forged) print SB "X"
}
AWK

# --------------------------------------------------------- clause checks ---
INTERP_RE='^(python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|deno|bun|php[0-9.]*|lua[0-9.]*|luajit|[gmn]?awk|busybox-awk|osascript|pwsh|powershell|rscript|julia|tclsh|wish|jshell|groovy|scala|kotlin|swift)$'
SHELL_RE='^(bash|sh|zsh|dash|ksh|mksh|yash|ash|fish|rbash)$'
# Verbs that only read their operands (grep --o is --only-matching, not --output).
READ_RE='^(cat|jq|grep|egrep|fgrep|rg|head|tail|less|more|wc|stat|ls|file|diff|cmp|md5sum|sha1sum|sha256sum|readlink|realpath)$'

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# _lb <word>: R = the lowercased basename, forking only for an uppercase letter.
_lb() { R="${1%/}"; R="${R##*/}"; case "$R" in *[A-Z]*) R=$(_lower "$R") ;; esac; }

# set_rule <script-word> <first-subcommand-or-empty> <has-sub 0|1>
set_rule() {
    local scrb="${1%/}"
    scrb="${scrb##*/}"
    if [ "$3" = 1 ] && { [ "$scrb" = "_usage_lift_cmd" ] || [ "$scrb" = "_bank_lift_cmd" ] || { ! _is_dynamic "$scrb" && _is_lift_script "$scrb"; }; }; then
        if ! _is_dynamic "$2" && _name_matches "$2" set; then deny "\`usage-lift.sh set\` is operator-only"; fi
    fi
    return 0
}

# _opt_prefix <full-name> <typed>: true when <typed> is a getopt prefix of <full-name>.
_opt_prefix() { case "$1" in "$2"*) return 0 ;; esac; return 1; }

# check_copy <verb> <args...>: cp / mv / install / rsync / ln destination and
# aliasing rules.
check_copy() {
    local verb="$1"; shift
    local tdir="" T=0 sym=0 rel=0 unk=0 a v n src srcb need dest dk endopts=0
    local -a pos=()
    while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$endopts" = 1 ]; then pos+=("$a"); continue; fi
        case "$a" in
            --) endopts=1 ;;
            --target-directory=*) tdir="${a#*=}" ;;
            --target-directory) tdir="${1:-}"; shift ;;
            --no-target-directory) T=1 ;;
            --no-dereference) [ "$verb" = ln ] && T=1 ;;
            --symbolic*|--link) sym=1 ;;
            --parents|--relative) rel=1 ;;
            --suffix|--mode|--owner|--group|--backup-dir|--rsh|--filter|--exclude|--include|--temp-dir|--partial-dir|--compare-dest|--copy-dest|--link-dest|--chmod|--chown) shift ;;
            --pa*) n="${a#--}"; n="${n%%=*}"; if _opt_prefix parents "$n"; then rel=1; fi ;;
            --t*)
                n="${a#--}"; n="${n%%=*}"
                if _opt_prefix target-directory "$n"; then
                    case "$a" in *=*) tdir="${a#*=}" ;; *) tdir="${1:-}"; shift ;; esac
                fi ;;
            --*) ;;
            -?*)
                v="${a#-}"
                while [ -n "$v" ]; do
                    case "$v" in
                        t*) if [ "$verb" = rsync ]; then v="${v#?}"; continue; fi
                            if [ -n "${v#t}" ]; then tdir="${v#t}"; else tdir="${1:-}"; shift; fi; v="" ;;
                        R*) if [ "$verb" = rsync ]; then rel=1; fi; v="${v#?}" ;;
                        T*) if [ "$verb" = rsync ]; then shift; v=""; else T=1; v="${v#?}"; fi ;;
                        s*) case "$verb" in ln|cp) sym=1 ;; esac; v="${v#?}" ;;
                        l*) case "$verb" in cp) sym=1 ;; esac; v="${v#?}" ;;
                        n*) case "$verb" in ln) T=1 ;; esac; v="${v#?}" ;;
                        S*|m*|o*|g*|e*|f*|B*|M*)
                            case "$verb:${v%"${v#?}"}" in
                                cp:S|mv:S|ln:S|install:[Smog]|rsync:[efBM])
                                    if [ -z "${v#?}" ]; then shift; fi; v="" ;;
                                *) v="${v#?}" ;;
                            esac ;;
                        *) v="${v#?}" ;;
                    esac
                done
                ;;
            *) pos+=("$a") ;;
        esac
    done
    if [ -n "$tdir" ]; then
        dest="$tdir"
    elif [ "${#pos[@]}" -ge 2 ]; then
        dest="${pos[${#pos[@]}-1]}"
        unset "pos[${#pos[@]}-1]"
    else
        return 0
    fi
    [ "$verb" = ln ] && sym=1
    # A copy/link/rename of a lift script runs `set` under another name.
    for src in ${pos[@]+"${pos[@]}"}; do
        srcb="${src%/}"; srcb="${srcb##*/}"
        case "$srcb" in *[bB][aA][nN][kK]*|*[uU][sS][aA][gG][eE]*) ;; *) continue ;; esac
        if ! _is_dynamic "$srcb" && _is_lift_script "$srcb"; then
            deny "$verb makes an alias of a lift script ($src)"
        fi
    done
    # Aliasing: a link TO the lift or its directory lets a later write reach
    # it without naming it.
    if [ "$sym" = 1 ]; then
        for src in ${pos[@]+"${pos[@]}"}; do
            _lift_ref1 "$src" 0
            case "$LREF" in LIFT|STATE) deny "$verb links to the bank lift or its directory ($src)" ;; esac
        done
    fi
    # --parents / -R rebuild each source path under the destination.
    if [ "$rel" = 1 ]; then
        for src in ${pos[@]+"${pos[@]}"}; do
            _lift_ref1 "$dest/$src" 0
            case "$LREF" in LIFT|STATE) deny "$verb rebuilds the bank lift path under $dest ($src)" ;; esac
        done
    fi
    _lift_ref1 "$dest" 0
    dk=$LREF
    case "$dk" in
        LIFT) deny "$verb writes the bank lift ($dest)" ;;
        STATE) need=LIFT ;;
        HIMMEL) need=state ;;
        HOME) need=.himmel ;;
        *)
            # A destination relative to an unproven cwd may be the state dir.
            _expand "$dest"
            case "$EXP" in '?'|'?/'*) unk=1; need=LIFT ;; *) return 0 ;; esac ;;
    esac
    # Whole-directory write into an ancestor of the lift.
    if [ "$T" = 1 ] && [ -z "$tdir" ]; then deny "$verb -T replaces/fills $dest wholesale"; fi
    for src in ${pos[@]+"${pos[@]}"}; do
        case "$src" in
            */|*/.) deny "$verb copies a directory's contents into $dest" ;;
        esac
        srcb="${src%/}"; srcb="${srcb##*/}"
        if { [ "$need" = LIFT ] && _is_lift_name "$srcb"; } || { [ "$need" != LIFT ] && _name_matches "$srcb" "$need"; }; then
            deny "$verb puts a \`$need\`-named (or unknowable) entry into $dest"
        fi
        if [ "$unk" = 1 ] && { _name_matches "$srcb" state || _name_matches "$srcb" .himmel; }; then
            deny "$verb puts a state- or .himmel-named entry into $dest (cwd unknown)"
        fi
    done
    return 0
}

# check_sed <sed-args...>: -i / --in-place on the lift, and a sed SCRIPT that
# writes it with w/W (also the s///w flag). The script is each -e / --expression
# value, else the first operand; -f files are not read.
check_sed() {
    local -a scripts=() ops=() files=()
    local a nx="" have=0 eoo=0 inplace=0 rest ch line p cand n
    for a in "$@"; do
        case "$nx" in
            e) scripts+=("$a"); nx=""; continue ;;
            skip) nx=""; continue ;;
        esac
        if [ "$eoo" = 1 ]; then ops+=("$a"); continue; fi
        case "$a" in
            --) eoo=1 ;;
            --in-place*) inplace=1 ;;
            --i*) n="${a#--}"; n="${n%%=*}"; _opt_prefix in-place "$n" && inplace=1 ;;
            --expression=*) have=1; scripts+=("${a#*=}") ;;
            --expression) have=1; nx=e ;;
            --e*)
                n="${a#--}"; n="${n%%=*}"
                if _opt_prefix expression "$n"; then
                    have=1
                    case "$a" in *=*) scripts+=("${a#*=}") ;; *) nx=e ;; esac
                fi ;;
            --file=*) have=1 ;;
            --file) have=1; nx=skip ;;
            --line-length) nx=skip ;;
            --*|-) ;;
            -*)
                rest="${a#-}"
                while [ -n "$rest" ]; do
                    ch="${rest:0:1}"; rest="${rest:1}"
                    case "$ch" in
                        e) have=1; if [ -n "$rest" ]; then scripts+=("$rest"); else nx=e; fi; break ;;
                        f) have=1; [ -n "$rest" ] || nx=skip; break ;;
                        l) [ -n "$rest" ] || nx=skip; break ;;
                        i) inplace=1; break ;;
                    esac
                done ;;
            *) ops+=("$a") ;;
        esac
    done
    if [ "$have" = 1 ]; then
        files=(${ops[@]+"${ops[@]}"})
    elif [ "${#ops[@]}" -gt 0 ]; then
        scripts+=("${ops[0]}")
        files=("${ops[@]:1}")
    fi
    if [ "$inplace" = 1 ]; then
        for a in ${files[@]+"${files[@]}"}; do
            is_lift "$a" && deny "sed -i edits the bank lift ($a)"
        done
    fi
    for a in ${scripts[@]+"${scripts[@]}"}; do
        while IFS= read -r line; do
            p="$line"
            while [ -n "$p" ]; do
                case "$p" in *[wW]*) ;; *) break ;; esac
                p="${p#*[wW]}"
                cand="${p#"${p%%[![:space:]]*}"}"
                [ -n "$cand" ] || continue
                is_lift "$cand" && deny "a sed w/W command writes the bank lift ($cand)"
            done
        done <<EOF
$a
EOF
    done
    return 0
}

# analyse <command-text> <depth>
analyse() {
    local text="$1" depth="$2" out line
    if [ "$depth" -gt 4 ]; then
        _names_lift_lit "$text" && deny "command nests too deep to inspect and names the bank lift"
        return 0
    fi
    out=$(printf '%s' "$text" | LC_ALL=C awk "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
    local stdin_shell=0 bodies=""
    local CUR_BODIES=""
    while IFS= read -r line; do
        case "$line" in $'\002B\037'*) CUR_BODIES="$CUR_BODIES${line#$'\002B\037'}"$'\n' ;; esac
    done <<EOF
$out
EOF
    _c_replace "$CUR_BODIES" $'\036' $'\n'
    CUR_BODIES=$REPLY
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            $'\002X') deny "the command decodes a tokenizer control byte (\\x02-\\x05, \\x1e, \\x1f)" ;;
            $'\002B\037'*) bodies="$bodies${line#$'\002B\037'}"$'\n'; continue ;;
            $'\002S\037'*) line="${line#$'\002S\037'}"; _c_replace "$line" $'\036' $'\n'; analyse "$REPLY" $((depth+1)); continue ;;
        esac
        local -a tk=() args=() rt=()
        IFS=$'\037' read -r -a tk <<<"$line"
        local i=0 t nt=${#tk[@]}
        # Redirect targets; build args without them.
        while [ "$i" -lt "$nt" ]; do
            t="${tk[$i]//$'\036'/$'\n'}"
            case "$t" in
                $'\002W'|$'\002C')
                    local mk="$t"
                    i=$((i+1)); t="${tk[$i]:-}"
                    if [ -n "$t" ] && is_lift "$t"; then deny "a redirect writes the bank lift ($t)"; fi
                    # bash reads `>!` as `>` to a file named `!`: the word is an operand too
                    if [ "$mk" = $'\002C' ] && [ -n "$t" ]; then args+=("$t"); fi
                    ;;
                $'\002R')
                    i=$((i+1)); rt+=("${tk[$i]:-}")
                    ;;
                *) args+=("$t") ;;
            esac
            i=$((i+1))
        done
        [ "${#args[@]}" -gt 0 ] || continue
        check_clause "$depth" "${args[@]}"
        case "$?" in
            # A here-string (<<<) into a shell is its script text; a `< file`
            # target analysed as text is a harmless command word.
            10) stdin_shell=1
                for t in ${rt[@]+"${rt[@]}"}; do analyse "$t" $((depth+1)); done ;;
        esac
    done <<EOF
$out
EOF
    if [ -n "$bodies" ] && [ "$stdin_shell" = 1 ]; then
        _c_replace "$bodies" $'\036' $'\n'
        analyse "$REPLY" $((depth+1))
    fi
    return 0
}

# _c_replace <text> <byte> <replacement>: REPLY = text with every <byte>
# replaced, under a function-local LC_ALL=C (a UTF-8 ${x//b/r} re-decodes the
# text for each match).
_c_replace() { local LC_ALL=C; REPLY=${1//"$2"/"$3"}; }

# check_clause <depth> <args...> — returns 10 when the clause is a shell reading
# its script from stdin (heredoc bodies then get analysed), 11 for an
# interpreter (already decided here).
check_clause() {
    local depth="$1"; shift
    local w cmd a
    # Command-position walk: keywords, assignments, wrappers.
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            '{'|'}'|'!'|if|then|else|elif|do|while|until|fi|done|coproc|builtin|nohup|setsid|unbuffer|caffeinate)
                shift; continue ;;
            function) shift; [ $# -gt 0 ] && shift; [ "${1:-}" = '()' ] && shift; continue ;;
        esac
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
            shift; continue
        fi
        _lb "$w"; cmd=$R
        case "$cmd" in
            env)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -S|--split-string) analyse "${2:-}" $((depth+1)); shift 2 || shift ;;
                        -S*) analyse "${1#-S}" $((depth+1)); shift ;;
                        --split-string=*) analyse "${1#*=}" $((depth+1)); shift ;;
                        -u|-C|--unset|--chdir) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *=*) shift ;;
                        *) break ;;
                    esac
                done
                continue ;;
            sudo|doas|run0)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -u|-g|-C|-D|-h|-p|-r|-t|-U|-T|--user|--group|--chdir|--host|--prompt|--role|--type|--other-user|--command-timeout) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) break ;;
                    esac
                done
                continue ;;
            timeout)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -s|-k|--signal|--kill-after) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) shift; break ;;   # the duration
                    esac
                done
                continue ;;
            nice|ionice|stdbuf|command|exec|time)
                shift
                case "$cmd" in
                    command)
                        case "${1:-}" in -v|-V) return 0 ;; esac
                        while [ $# -gt 0 ]; do case "$1" in -p|--) shift ;; *) break ;; esac; done ;;
                    exec)
                        while [ $# -gt 0 ]; do case "$1" in -a) shift 2 || shift ;; -c|-l|-cl|-lc|--) shift ;; *) break ;; esac; done ;;
                    nice|ionice)
                        while [ $# -gt 0 ]; do
                            case "$1" in -n|-c|-p|-t|--adjustment|--class|--classdata) shift 2 || shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac
                        done ;;
                    stdbuf)
                        while [ $# -gt 0 ]; do
                            case "$1" in -i|-o|-e) shift 2 || shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac
                        done ;;
                    time)
                        while [ $# -gt 0 ]; do case "$1" in -f|-o|--format|--output) shift 2 || shift ;; -*) shift ;; *) break ;; esac; done ;;
                esac
                continue ;;
            eval)
                shift
                analyse "$*" $((depth+1)); return 0 ;;
        esac
        break
    done
    [ $# -gt 0 ] || return 0
    w="$1"; shift
    _lb "$w"; cmd=$R

    # Generic output-file options (-o / -O / --output[=] / --output-document):
    # the full spellings plus a getopt prefix of --output.
    local pexp=0 prev="" n
    for a in "$@"; do
        if [ "$pexp" = 1 ] && is_lift "$a"; then
            deny "$cmd $prev writes the bank lift ($a)"
        fi
        pexp=0
        case "$a" in
            -o|-O) pexp=1 ;;
            -o?*|-O?*) is_lift "${a:2}" && deny "$cmd $a writes the bank lift" ;;
            -[A-Za-z]*[oO]) [[ "$cmd" =~ $READ_RE ]] || pexp=1 ;;
            --output=*|--output-document=*|--out-file=*|--outfile=*)
                is_lift "${a#*=}" && deny "$cmd writes the bank lift (${a#*=})" ;;
            --output|--output-document|--out-file|--outfile)
                [[ "$cmd" =~ $READ_RE ]] || pexp=1 ;;
            --o*)
                n="${a#--}"; n="${n%%=*}"
                if _opt_prefix output "$n"; then
                    case "$a" in
                        *=*) is_lift "${a#*=}" && deny "$cmd writes the bank lift (${a#*=})" ;;
                        *) [[ "$cmd" =~ $READ_RE ]] || pexp=1 ;;
                    esac
                fi ;;
        esac
        prev="$a"
    done

    # Shells.
    if [[ "$cmd" =~ $SHELL_RE ]]; then
        local cflag=0 sflag=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --) shift; break ;;
                -o|+o|-O|+O|--rcfile|--init-file) shift 2 || shift ;;
                --*) shift ;;
                [-+]*)
                    case "$1" in *c*) cflag=1 ;; esac
                    case "$1" in *s*) sflag=1 ;; esac
                    shift ;;
                *) break ;;
            esac
        done
        if [ "$cflag" = 1 ]; then
            analyse "${1:-}" $((depth+1)); return 0
        fi
        if [ "$sflag" = 1 ] || [ $# -eq 0 ] || [ "${1:-}" = - ] || [ "${1:-}" = /dev/stdin ]; then
            return 10
        fi
        w="$1"; shift
        set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 ))
        return 0
    fi
    case "$cmd" in
        source|.)
            [ $# -gt 0 ] || return 0
            w="$1"; shift
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 ))
            return 0 ;;
    esac

    # Interpreters: their code is text the hook cannot parse. Any argument that
    # IS the lift (or its dir) denies. INLINE code (-c/-e/…, an awk program, or
    # a script read from stdin/heredoc) also denies when it spells a lift FILE
    # or script name. A script FILE's other arguments are data — a ticket title
    # that merely mentions the lift is not code.
    if [[ "$cmd" =~ $INTERP_RE ]]; then
        local inline=0 seen=0 iscode=0
        case "$cmd" in *awk) inline=1 ;; esac
        for a in "$@"; do
            # The code word itself (after -c/-e, or awk's program) is not a path.
            if [ "$iscode" = 0 ] && ! { [ "$seen" = 0 ] && [[ "$cmd" == *awk ]] && [[ "$a" != -* ]]; }; then
                _lift_ref1 "$a" 0
                case "$LREF" in LIFT|STATE) deny "an interpreter ($cmd) is handed the bank lift path ($a)" ;; esac
            fi
            iscode=0
            case "$a" in
                -c|-e|-E|-p|-r|--eval|--print|--command|-command|-Command|-[a-zA-Z]e|-[a-zA-Z]c) inline=1; iscode=1 ;;
                -f|--file) [ "$seen" = 0 ] && inline=0 ;;
                -) [ "$seen" = 0 ] && inline=1 ;;
                -*) ;;
                *) [ "$seen" = 0 ] && case "$cmd" in *awk) ;; *) case "$a" in /dev/stdin|/proc/self/fd/0) inline=1 ;; esac ;; esac
                   seen=1 ;;
            esac
        done
        [ "$seen" = 0 ] && inline=1
        if [ "$inline" = 1 ] && _names_lift_lit "$* $CUR_BODIES"; then
            deny "an interpreter ($cmd) runs inline code naming the bank lift"
        fi
        return 11
    fi

    case "$cmd" in
        tee|sponge|touch|truncate|patch|ex|ed)
            for a in "$@"; do
                case "$a" in -*) continue ;; esac
                is_lift "$a" && deny "$cmd writes the bank lift ($a)"
            done ;;
        sed|gsed) check_sed "$@" ;;
        dd)
            for a in "$@"; do
                case "$a" in of=*) is_lift "${a#of=}" && deny "dd of= writes the bank lift (${a#of=})" ;; esac
            done ;;
        cp|mv|install|ln|rsync|gcp|gmv|gln|ginstall) check_copy "${cmd#g}" "$@" ;;
        *) set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) ;;
    esac
    return 0
}

# A directory-changing word makes the cwd unknown for the whole command, so a
# relative word is judged by its name alone (see the ponytail in the header).
# Read from the raw text with no fork.
if [[ "$CMD" =~ (^|[^A-Za-z0-9_.-])(cd|pushd|popd)([^A-Za-z0-9_.-]|$) ]]; then
    CWD_UNPROVEN=1
fi
analyse "$CMD" 0

# A shell reading its script from a pipe runs the text an earlier stage prints.
# The command-position model (scripts/lib/bash-ast.sh) says which stage feeds
# which: through tee and a bare cat back to the producer, and when that is an
# echo or printf of literal words, its words are analysed as the script. It only
# adds a deny; a missing lib, shfmt or jq, or a command shfmt cannot parse
# leaves the tokenizer's verdict above. Pre-gated on a pipe beside a shell word.
# swallow-ok: read -d '' on a literal heredoc always returns 1 at EOF
IFS= read -r -d '' BL_JQ <<'BL_JQ_EOF' || true
def thru: length == 1 and (.[0] | .prog == "tee"
  or (.prog == "cat" and all(.argv[1:][]; .t == "lit" and (.v | startswith("-")))));
[.[] | select(.pipe != null)] as $ps
| $ps[] | select(((.opaque // "") | test("stdin")) and .pipe.stage > 0) as $sh
| first(range($sh.pipe.stage - 1; -1; -1) as $j
        | [$ps[] | select(.pipe.id == $sh.pipe.id and .pipe.stage == $j)] | select(thru | not))
| .[] | select(((.prog // "") | IN("echo", "printf")) and all(.argv[1:][]; .t == "lit"))
| .prog as $p | [.argv[1:][] | .v] as $a
| $a[], (if $p == "echo" then $a | until(length == 0 or (.[0] | test("^-[neE]+$") | not); .[1:])
         else $a[1:] end | join(" "))
BL_JQ_EOF
if [[ $CMD == *'|'* ]] && [[ "$CMD" =~ (^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh)([^A-Za-z0-9_.-]|$) ]]; then
    bl_lib=${BASH_SOURCE[0]%/*}/../lib/bash-ast.sh
    bl_texts=
    # shellcheck source=../lib/bash-ast.sh
    if { [ -r "$bl_lib" ] && . "$bl_lib"; } 2>/dev/null; then
        # swallow-ok: the model only adds denies; a failed parse keeps the tokenizer verdict above
        bl_texts=$(bash_ast_positions "$CMD" 2>/dev/null | jq -c "$BL_JQ" 2>/dev/null)
    fi
    while IFS= read -r bl_t; do
        [ -n "$bl_t" ] || continue
        # swallow-ok: an undecodable text adds no deny; the tokenizer verdict stands
        bl_t=$(printf '%s' "$bl_t" | jq -r . 2>/dev/null) || continue
        analyse "$bl_t" 1
    done <<EOF
$bl_texts
EOF
fi
exit 0
