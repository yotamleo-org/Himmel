# shellcheck shell=bash
# shell-tokenize.sh — the quote-aware, segment-wise shell tokenizer shared by
# block-edit-live-settings.sh and guard-pr-check-literal.sh (HIMMEL-3546).
#
# NOT SOURCED AT RUNTIME. hook-integrity pins each launched scripts/hooks/*.sh
# file, never a file a hook sources, so a sourced lib would be an unpinned
# edit surface under two security fences. The block between the BEGIN and END
# markers below is therefore copied byte-for-byte into BOTH hooks, and
# scripts/hooks/test-shell-tokenize.sh fails when either inlined copy differs
# from this file. Edit the block HERE, then run
# `bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-shell-tokenize.sh
# --sync` to rewrite both copies (require-quiet-run refuses a bare suite run).
#
# >>> BEGIN shell-tokenize (HIMMEL-3546; canonical: scripts/hooks/lib/shell-tokenize.sh) >>>
# st_tokenize CMD — split CMD into words and segments the way bash reads it,
# expanding nothing. Returns 0 (ST_OK=1) on success, 1 (ST_OK=0) on anything
# it does not model — an unterminated quote, an unmatched `)`, `;;`, a
# backtick inside double quotes inside backticks, a `${…}` beyond a bare
# name, a redirect with no target, more than 8 KiB — and the caller then
# falls back to its older, stricter text scan. The cap bounds the hooks'
# worst case well inside run-hook-with-bash.js's 15 s member timeout (J1242):
# every loop here and in the callers is linear and fork-free, so an 8 KiB
# command tokenizes in a fraction of a second.
#   ST_N        number of words
#   ST_W[i]     word i with quotes and escapes removed (a $'…' body
#               decoded), nothing expanded
#   ST_Q[i]     1 when any byte of word i was quoted or escaped
#   ST_X[i]     1 when word i carries a live `$` (unquoted, or inside "…")
#   ST_G[i]     1 when word i carries an unquoted * ? [ or { (a glob or
#               brace expansion, which can become any word — even `-i`)
#   ST_A[i]     1 when word i is assignment-shaped (an unquoted NAME=)
#   ST_S[i]     segment index of word i
#   ST_RO[i]    the redirect operator word i is the target of (`>`, `2>&`,
#               `<<`, …), empty for an ordinary word
#   ST_NSEG     number of segments
#   ST_SEP[s]   operator ending segment s: ; & && | || |& nl ( ) $( ` <( >(
#               or empty for the last one. A substitution's inner command is
#               a segment of its own.
#   ST_SUBST ST_HEREDOC ST_ANSIC ST_COMMENT — 1 when the command carries a
#               live command/process substitution (including inside "…" and
#               any live $ in an unquoted heredoc body), a heredoc, a $'…'
#               word, a comment.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_tokenize() {
    local LC_ALL=C
    local s="$1" n i c c2 c3 ctx='' top w='' win=0 wq=0 wx=0 wg=0 wqpos=-1
    local rop='' fd op rest body j bad=0 hd_n=0 hd_i=0
    local -a hd_d hd_q hd_t
    ST_OK=0 ST_N=0 ST_NSEG=0 ST_SUBST=0 ST_HEREDOC=0 ST_ANSIC=0 ST_COMMENT=0
    ST_W=() ST_Q=() ST_X=() ST_G=() ST_A=() ST_S=() ST_RO=() ST_SEP=()
    n=${#s}
    [ "$n" -le 8192 ] || return 1
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        top=''
        [ -z "$ctx" ] || top=${ctx:${#ctx}-1:1}
        if [ "$top" = D ]; then
            case "$c" in
                '"') ctx=${ctx%?}; i=$((i + 1)) ;;
                '\')
                    c2=${s:i+1:1}
                    case "$c2" in
                        '$'|'`'|'"'|'\') _st_q; w=$w$c2; i=$((i + 2)) ;;
                        $'\n') i=$((i + 2)) ;;
                        *) _st_q; w=$w'\'; i=$((i + 1)) ;;
                    esac
                    ;;
                '$')
                    if [ "${s:i+1:1}" = '(' ]; then
                        ST_SUBST=1; _st_seg '$('; ctx=${ctx}P; i=$((i + 2))
                    else
                        _st_q; wx=1; w=$w'$'; i=$((i + 1))
                    fi
                    ;;
                '`')
                    case "$ctx" in *B*) return 1 ;; esac
                    ST_SUBST=1; _st_seg '`'; ctx=${ctx}B; i=$((i + 1))
                    ;;
                *) _st_q; w=$w$c; i=$((i + 1)) ;;
            esac
            continue
        fi
        case "$c" in
            ' '|$'\t') _st_word; i=$((i + 1)) ;;
            $'\n')
                _st_seg nl; i=$((i + 1))
                [ "$hd_i" -ge "$hd_n" ] || _st_heredocs
                ;;
            "'")
                rest=${s:i+1}
                case "$rest" in *"'"*) ;; *) return 1 ;; esac
                body=${rest%%"'"*}
                _st_q; w=$w$body; i=$((i + ${#body} + 2))
                ;;
            '"') _st_q; ctx=${ctx}D; i=$((i + 1)) ;;
            '\')
                c2=${s:i+1:1}
                case "$c2" in
                    $'\n') i=$((i + 2)) ;;
                    '') _st_q; w=$w'\'; i=$((i + 1)) ;;
                    *) _st_q; w=$w$c2; i=$((i + 2)) ;;
                esac
                ;;
            '$')
                c2=${s:i+1:1}
                case "$c2" in
                    "'")
                        ST_ANSIC=1; body=''; j=$((i + 2))
                        while [ "$j" -lt "$n" ]; do
                            c3=${s:j:1}
                            if [ "$c3" = '\' ]; then
                                body=$body${s:j:2}; j=$((j + 2))
                            elif [ "$c3" = "'" ]; then
                                break
                            else
                                body=$body$c3; j=$((j + 1))
                            fi
                        done
                        [ "$j" -lt "$n" ] || return 1
                        # The shell runs the decoded word (`$'\x2dr'` is -r,
                        # HIMMEL-4576). ${…@E} is bash 4.4+; an older bash
                        # keeps the raw body, as before (declining here would
                        # switch guard_unwrap off for the whole command, J1946
                        # B1). The eval'd text is constant, never input.
                        if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
                            || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
                            eval 'body=${body@E}'
                        fi
                        _st_q; w=$w$body; i=$((j + 1))
                        ;;
                    '"') _st_q; ctx=${ctx}D; i=$((i + 2)) ;;
                    '(') ST_SUBST=1; _st_seg '$('; ctx=${ctx}P; i=$((i + 2)) ;;
                    '{')
                        rest=${s:i+2}
                        body=${rest%%\}*}
                        [ "$body" != "$rest" ] || return 1
                        case "$body" in ''|*[!A-Za-z0-9_#!@*?$-]*) return 1 ;; esac
                        win=1; wx=1; w=$w'${'$body'}'; i=$((i + ${#body} + 3))
                        ;;
                    *) win=1; wx=1; w=$w'$'; i=$((i + 1)) ;;
                esac
                ;;
            '`')
                if [ "$top" = B ]; then
                    _st_seg '`'; ctx=${ctx%?}; _st_resume
                else
                    ST_SUBST=1; _st_seg '`'; ctx=${ctx}B
                fi
                i=$((i + 1))
                ;;
            '#')
                if [ "$win" = 0 ]; then
                    ST_COMMENT=1; rest=${s:i}; body=${rest%%$'\n'*}; i=$((i + ${#body}))
                else
                    w=$w'#'; i=$((i + 1))
                fi
                ;;
            ';')
                [ "${s:i+1:1}" != ';' ] || return 1
                _st_seg ';'; i=$((i + 1))
                ;;
            '&')
                c2=${s:i+1:1}
                case "$c2" in
                    '&') _st_seg '&&'; i=$((i + 2)) ;;
                    '>')
                        _st_word
                        [ -z "$rop" ] || return 1
                        if [ "${s:i+2:1}" = '>' ]; then rop='&>>'; i=$((i + 3)); else rop='&>'; i=$((i + 2)); fi
                        ;;
                    *) _st_seg '&'; i=$((i + 1)) ;;
                esac
                ;;
            '|')
                c2=${s:i+1:1}
                case "$c2" in
                    '|') _st_seg '||'; i=$((i + 2)) ;;
                    '&') _st_seg '|&'; i=$((i + 2)) ;;
                    *) _st_seg '|'; i=$((i + 1)) ;;
                esac
                ;;
            '(') _st_seg '('; ctx=${ctx}S; i=$((i + 1)) ;;
            ')')
                case "$top" in
                    P|S) _st_seg ')'; ctx=${ctx%?}; _st_resume; i=$((i + 1)) ;;
                    *) return 1 ;;
                esac
                ;;
            '<'|'>')
                fd=''
                if [ "$win" = 1 ] && [ "$wq" = 0 ] && [ -z "$rop" ]; then
                    case "$w" in *[!0-9]*) ;; *) fd=$w; w=''; win=0; wqpos=-1 ;; esac
                fi
                _st_word
                [ -z "$rop" ] || return 1
                c2=${s:i+1:1}
                c3=${s:i+2:1}
                if [ "$c" = '<' ]; then
                    case "$c2" in
                        '<')
                            if [ "$c3" = '<' ]; then op='<<<'
                            elif [ "$c3" = '-' ]; then op='<<-'; ST_HEREDOC=1
                            else op='<<'; ST_HEREDOC=1
                            fi
                            ;;
                        '&') op='<&' ;;
                        '>') op='<>' ;;
                        '(') op='<(' ;;
                        *) op='<' ;;
                    esac
                else
                    case "$c2" in
                        '>') op='>>' ;;
                        '&') op='>&' ;;
                        '|') op='>|' ;;
                        '(') op='>(' ;;
                        *) op='>' ;;
                    esac
                fi
                case "$op" in
                    '<('|'>(')
                        [ -z "$fd" ] || return 1
                        ST_SUBST=1; _st_seg "$op"; ctx=${ctx}P; i=$((i + 2))
                        ;;
                    *) rop=$fd$op; i=$((i + ${#op})) ;;
                esac
                ;;
            *)
                case "$c" in '*'|'?'|'['|'{') wg=1 ;; esac
                win=1; w=$w$c; i=$((i + 1))
                ;;
        esac
    done
    [ -z "$ctx" ] || return 1
    _st_word
    [ -z "$rop" ] || return 1
    ST_SEP[ST_NSEG]=''
    ST_NSEG=$((ST_NSEG + 1))
    [ "$bad" = 0 ] || return 1
    ST_OK=1
    return 0
}

# The helpers below run in st_tokenize's dynamic scope and share its locals.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_q() { # the next byte appended to the word is quoted or escaped
    [ "$wqpos" -ge 0 ] || wqpos=${#w}
    wq=1; win=1
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_word() { # flush the pending word, if one was started
    local k e re='^[A-Za-z_][A-Za-z0-9_]*='
    if [ "$win" = 1 ]; then
        k=$ST_N
        ST_W[k]=$w; ST_Q[k]=$wq; ST_X[k]=$wx; ST_G[k]=$wg
        ST_S[k]=$ST_NSEG; ST_RO[k]=$rop; ST_A[k]=0
        if [ -z "$rop" ] && [[ $w =~ $re ]]; then
            e=${w%%=*}
            if [ "$wqpos" -lt 0 ] || [ "$wqpos" -gt "${#e}" ]; then ST_A[k]=1; fi
        fi
        case "$rop" in
            '<<'|'<<-'|[0-9]'<<'|[0-9]'<<-')
                hd_d[hd_n]=$w; hd_q[hd_n]=$wq
                case "$rop" in *-) hd_t[hd_n]=1 ;; *) hd_t[hd_n]=0 ;; esac
                hd_n=$((hd_n + 1))
                ;;
        esac
        ST_N=$((k + 1)); rop=''
    fi
    w=''; win=0; wq=0; wx=0; wg=0; wqpos=-1
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_seg() { # end the current segment with operator $1
    _st_word
    [ -z "$rop" ] || bad=1
    ST_SEP[ST_NSEG]=$1
    ST_NSEG=$((ST_NSEG + 1))
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_resume() { # back from a substitution: inside "…" the word goes on
    case "$ctx" in *D) win=1; wq=1; [ "$wqpos" -ge 0 ] || wqpos=0 ;; esac
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_heredocs() { # skip the bodies of every heredoc queued on the line just ended
    local d line t
    while [ "$hd_i" -lt "$hd_n" ]; do
        d=${hd_d[hd_i]}
        while [ "$i" -lt "$n" ]; do
            rest=${s:i}
            line=${rest%%$'\n'*}
            i=$((i + ${#line} + 1))
            if [ "${hd_t[hd_i]}" = 1 ]; then
                while [ "${line:0:1}" = $'\t' ]; do line=${line:1}; done
            fi
            [ "$line" != "$d" ] || break
            if [ "${hd_q[hd_i]}" = 0 ]; then
                # Any live $ expands: ${x@P} and an array subscript re-expand
                # a $(...) held in a variable. Only a \$ is literal.
                t=${line//\\\\/}
                t=${t//\\\$/}
                case "$t" in *'$'*|*'`'*) ST_SUBST=1 ;; esac
            fi
        done
        hd_i=$((hd_i + 1))
    done
}

# st_lower STR — ST_LOWER is STR with A-Z folded to a-z (bytes, as `tr` does
# in the C locale), without a fork: a fork per word is what made a padded
# command outrun the runner's member timeout (J1242).
# shellcheck disable=SC2034,SC2317,SC2329 # ST_LOWER is read by the caller; only block-edit calls it, the guard inlines the whole lib
st_lower() {
    local s="$1" u=ABCDEFGHIJKLMNOPQRSTUVWXYZ l=abcdefghijklmnopqrstuvwxyz i=0
    while [ "$i" -lt 26 ]; do
        s=${s//${u:i:1}/${l:i:1}}
        i=$((i + 1))
    done
    ST_LOWER=$s
}

# st_sed_inert SCRIPT — 0 when SCRIPT is one sed command that can neither
# write a file nor run one: an optional line address, then `p`, `d`, or a
# single `s` command whose flags are only g p i I m M and digits (no `w`, no
# `e`). Anything else — a second command, `e`, `w`, `r`, a newline — is 1.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_sed_inert() {
    local LC_ALL=C s="$1" d n i c part=0 re='^([0-9]+(,([0-9]+|\$))?|\$)'
    case "$s" in *$'\n'*) return 1 ;; esac
    if [[ $s =~ $re ]]; then s=${s:${#BASH_REMATCH[0]}}; fi
    case "$s" in p|d) return 0 ;; s?*) ;; *) return 1 ;; esac
    d=${s:1:1}
    case "$d" in '\'|' ') return 1 ;; esac
    n=${#s}
    i=2
    while [ "$i" -lt "$n" ] && [ "$part" -lt 2 ]; do
        c=${s:i:1}
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        [ "$c" != "$d" ] || part=$((part + 1))
        i=$((i + 1))
    done
    [ "$part" = 2 ] || return 1
    case "${s:i}" in *[!gpiImM0-9]*) return 1 ;; esac
    return 0
}

# st_sed_args K INPLACE_OK — the words after a sed at word K, up to the end
# of its segment. 0 when every script it runs is inert (st_sed_inert), each
# one a plain word (no live `$`, no unquoted glob), no script comes from a
# file (-f/--file), and -i/--in-place appears only when INPLACE_OK is 1.
# Sets ST_SED_SCRIPTS to the script words' indexes, space-separated.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_sed_args() {
    local k=$1 inpl=$2 j sg a have=0 eo=0 scripts=''
    sg=${ST_S[k]}
    j=$((k + 1))
    while [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ]; do
        if [ -n "${ST_RO[j]}" ]; then j=$((j + 1)); continue; fi
        a=${ST_W[j]}
        if [ "$eo" = 0 ]; then
            case "$a" in
                -e|--expression)
                    j=$((j + 1))
                    [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ] || return 1
                    _st_sed_script "$j" "${ST_W[j]}" || return 1
                    ;;
                --expression=*) _st_sed_script "$j" "${a#--expression=}" || return 1 ;;
                -e?*) _st_sed_script "$j" "${a#-e}" || return 1 ;;
                -f*|--file|--file=*) return 1 ;;
                -i*|--in-place|--in-place=*) [ "$inpl" = 1 ] || return 1 ;;
                -l|--line-length) j=$((j + 1)) ;;
                --line-length=*|-l[0-9]*) ;;
                --) eo=1 ;;
                --posix|--debug|--sandbox|--quiet|--silent|--regexp-extended|--separate|--unbuffered|--null-data|--zero-terminated|--follow-symlinks) ;;
                -*[!nErsuz]*) return 1 ;;
                -?*) ;;
                *)
                    if [ "$have" = 0 ]; then
                        _st_sed_script "$j" "$a" || return 1
                    fi
                    ;;
            esac
        elif [ "$have" = 0 ]; then
            _st_sed_script "$j" "$a" || return 1
        fi
        j=$((j + 1))
    done
    [ "$have" = 1 ] || return 1
    ST_SED_SCRIPTS=$scripts
    return 0
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_sed_script() { # one sed script at word $1 with text $2, in st_sed_args's scope
    [ "${ST_X[$1]}" = 0 ] && [ "${ST_G[$1]}" = 0 ] || return 1
    st_sed_inert "$2" || return 1
    have=1
    scripts="$scripts $1"
}
# <<< END shell-tokenize <<<

# --- st_expand: a parameter-expansion model (HIMMEL-5362) --------------------
# Kept OUTSIDE the BEGIN/END block on purpose: neither inlining hook calls it,
# so their copies stay byte-identical and their behaviour cannot move. Its one
# caller, block-tail-pipe-on-gates.sh, reaches it through guard-unwrap.sh,
# which sources this file at runtime.
#
# st_expand MODE CMD — ST_EXP is CMD rewritten as ONE reading of the text the
# shell would run once parameter expansion is done; returns 1 (ST_EXP empty)
# over the 16 KB bound. The values of variables are unknown, so the model takes
# one side of every alternation:
#   text   every expansion with a TEXT part becomes that text: the WORD of
#          :- := :+ - = + (zsh ::=), the replacement of / // /# /% (zsh :/),
#          and the zsh (l::) (r::) pad strings and (j::) (s::) separators.
#          Value-only expansions ($V, ${#V}, ${V#pat}, ${V:t}, ...) stay as
#          written.
#   empty  every expansion (bare $V and $V:t/$V[..] tails included) is ''.
# Anything the allowlist does not classify (zsh :s/:gs/:& and unknown flags,
# nested ${${..}}, a subscript that runs a command) stays VERBATIM in both
# modes: the caller still scans its text, so an unknown form can only hide
# what the plain text already hid. Spliced text is escaped so it stays a word:
# outside quotes `;|&<>()` and `#` get a backslash and a newline becomes a
# space. Also, in both modes: `$'...'` is decoded (bash >= 4.4) and re-quoted
# with single quotes, `$"..."` reads as "...", `$(...)` and backtick bodies are
# rewritten recursively, comments and single-quoted text are copied as is,
# and every heredoc is cut from the text: operator and delimiter go, the body
# goes through its terminator, and each `$(...)`/backtick of an UNQUOTED body
# is lifted onto a line of its own, since the shell runs it.
# Returns 1, ST_EXP empty, on text over 16 KB or constructs nested more than 32
# deep (each level re-walks its text, so depth is the cost); callers fail closed.
# bash 3.2-safe, no forks.
# shellcheck disable=SC2034,SC2317,SC2329 # ST_EXP is read by the caller; reached only through guard-unwrap's source
st_expand() {
    local LC_ALL=C _SX='' _SX_DQ=0 _SX_E=0 _SX_W='' _SX_Q=0 _SX_D=0 _SX_OVER=0
    ST_EXP=''
    [ "${#2}" -le 16384 ] || return 1
    _stx_walk "$1" "$2" 0 0
    [ "$_SX_OVER" = 0 ] || return 1
    ST_EXP=$_SX
}

# _stx_walk MODE TEXT DQ WB — _SX is TEXT rewritten; _SX_DQ the quote state it
# ends in. DQ=1 starts inside "...". WB=1: TEXT is a ${...} word being spliced
# into the command, so unquoted syntax bytes are escaped and heredocs are text.
# shellcheck disable=SC2317,SC2329
_stx_walk() {
    local m=$1 s=$2 dq=$3 wb=$4 n=${#2} i=0 j o='' c c2 b e rest sq="'"
    local -a hd_d hd_t hd_q
    local hd_n=0 _SX_D=$((_SX_D + 1))
    if [ "$_SX_D" -gt 32 ]; then _SX_OVER=1; _SX=$s; _SX_DQ=$dq; return; fi
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case $c in
            '\')
                # a backslash-newline is a line continuation: the shell drops it
                if [ "${s:i+1:1}" = $'\n' ]; then i=$((i + 2)); continue; fi
                o=$o${s:i:2}; i=$((i + 2)); continue ;;
            '"') o=$o'"'; dq=$((1 - dq)); i=$((i + 1)); continue ;;
            '`')
                _stx_end "$s" $((i + 1)) B || { o=$o${s:i}; break; }
                e=$_SX_E
                _stx_walk "$m" "${s:i+1:e-i-2}" 0 0
                o=$o'`'$_SX'`'; i=$e; continue ;;
            '$')
                while [ "${s:i+1:2}" = $'\\\n' ]; do s=${s:0:i+1}${s:i+3}; n=${#s}; done
                c2=${s:i+1:1}
                case $c2 in
                    '(')
                        _stx_end "$s" $((i + 2)) P || { o=$o${s:i}; break; }
                        e=$_SX_E
                        if [ "${s:i+2:1}" = '(' ]; then
                            o=$o${s:i:e-i}
                        else
                            _stx_walk "$m" "${s:i+2:e-i-3}" 0 0
                            o=$o'$('$_SX')'
                        fi
                        i=$e; continue ;;
                    '{')
                        _stx_end "$s" $((i + 2)) C "$dq" || { o=$o${s:i}; break; }
                        e=$_SX_E
                        b=${s:i+2:e-i-3}
                        if _stx_param "$m" "$b" "$dq"; then o=$o$_SX; else o=$o'${'$b'}'; fi
                        i=$e; continue ;;
                    "'")
                        if [ "$dq" = 0 ]; then
                            _stx_ansi "$s" $((i + 2))
                            b=$_SX_W
                            b=${b//$sq/$sq\\$sq$sq}; o=$o$sq$b$sq; i=$_SX_E; continue
                        fi ;;
                    '"')
                        if [ "$dq" = 0 ]; then o=$o'"'; dq=1; i=$((i + 2)); continue; fi ;;
                    [A-Za-z_])
                        rest=${s:i+1}
                        b=${rest%%[!A-Za-z0-9_]*}
                        j=$((i + 1 + ${#b}))
                        if [ "$m" = text ]; then o=$o'$'$b; i=$j; continue; fi
                        while :; do # zsh subscripts and modifiers belong to it
                            if [ "${s:j:1}" = '[' ]; then
                                rest=${s:j}; b=${rest%%]*}
                                [ "$b" != "$rest" ] || break
                                j=$((j + ${#b} + 1)); continue
                            fi
                            [ "${s:j:1}" = ':' ] || break
                            case ${s:j+1:1} in [aAcehlPqQrtu]) ;; *) break ;; esac
                            j=$((j + 2))
                            while case ${s:j:1} in [0-9]) true ;; *) false ;; esac; do j=$((j + 1)); done
                        done
                        i=$j; continue ;;
                    [0-9@*#?\$!-])
                        [ "$m" = text ] && o=$o'$'$c2
                        i=$((i + 2)); continue ;;
                esac
                o=$o'$'; i=$((i + 1)); continue ;;
        esac
        if [ "$dq" = 1 ]; then o=$o$c; i=$((i + 1)); continue; fi
        case $c in
            "'")
                rest=${s:i+1}; b=${rest%%\'*}
                [ "$b" != "$rest" ] || { o=$o${s:i}; break; }
                o=$o$sq$b$sq; i=$((i + ${#b} + 2)); continue ;;
            '#')
                if [ "$wb" = 1 ]; then o=$o'\#'; i=$((i + 1)); continue; fi
                case ${s:i-1:1} in
                    ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '(' | ')' | '<' | '>') ;;
                    *) [ "$i" = 0 ] || { o=$o$c; i=$((i + 1)); continue; } ;;
                esac
                rest=${s:i}; b=${rest%%$'\n'*}
                o=$o$b; i=$((i + ${#b})); continue ;;
            $'\n')
                if [ "$wb" = 1 ]; then o="$o "; i=$((i + 1)); continue; fi
                o=$o$c; i=$((i + 1))
                [ "$hd_n" = 0 ] || _stx_bodies
                hd_n=0; continue ;;
            '<')
                if [ "$wb" = 0 ] && [ "${s:i:2}" = '<<' ]; then
                    if [ "${s:i:3}" = '<<<' ]; then o=$o'<<<'; i=$((i + 3)); continue; fi
                    j=$((i + 2)); b=0
                    [ "${s:j:1}" != '-' ] || { b=1; j=$((j + 1)); }
                    while case ${s:j:1} in ' ' | $'\t') true ;; *) false ;; esac; do j=$((j + 1)); done
                    _stx_hdword "$s" "$j"
                    if [ -n "$_SX_W" ] || [ "$_SX_Q" = 1 ]; then
                        hd_d[hd_n]=$_SX_W; hd_t[hd_n]=$b; hd_q[hd_n]=$_SX_Q; hd_n=$((hd_n + 1))
                        o="$o "; i=$_SX_E; continue
                    fi
                fi ;;
        esac
        if [ "$wb" = 1 ]; then
            case $c in ';' | '|' | '&' | '<' | '>' | '(' | ')') o=$o'\'$c; i=$((i + 1)); continue ;; esac
        fi
        o=$o$c; i=$((i + 1))
    done
    _SX=$o
    _SX_DQ=$dq
}

# _stx_bodies — in _stx_walk's scope, right after the newline that ends a line
# with heredocs queued: skip each body through its terminator. An unquoted body
# joins backslash-newlines before the terminator test and lifts every `$(...)`
# and backtick it holds onto a line of its own.
# shellcheck disable=SC2317,SC2329
_stx_bodies() {
    local k=0 p q l line lift='' rest
    while [ "$k" -lt "$hd_n" ]; do
        while [ "$i" -lt "$n" ]; do
            j=$i; line=''
            while :; do
                rest=${s:j}; l=${rest%%$'\n'*}
                j=$((j + ${#l} + 1))
                if [ "${hd_q[k]}" = 0 ] && [ "$j" -le "$n" ]; then
                    rest=${l##*[!\\]}
                    [ "$rest" != "$l" ] || rest=$l
                    if [ $((${#rest} % 2)) = 1 ]; then line=$line${l%?}; continue; fi
                fi
                line=$line$l; break
            done
            if [ "${hd_t[k]}" = 1 ]; then
                while [ "${line:0:1}" = $'\t' ]; do line=${line:1}; done
            fi
            if [ "$line" = "${hd_d[k]}" ]; then i=$j; break; fi
            if [ "${hd_q[k]}" = 0 ]; then
                p=$i
                while [ "$p" -lt $((j - 1)) ]; do
                    case ${s:p:1} in
                        '\') p=$((p + 2)); continue ;;
                        '$' | '`')
                            while [ "${s:p:1}" = '$' ] && [ "${s:p+1:2}" = $'\\\n' ]; do
                                s=${s:0:p+1}${s:p+3}; n=${#s}; j=$((j - 2))
                            done
                            if [ "${s:p:1}" = '`' ]; then
                                _stx_end "$s" $((p + 1)) B || { j=$((n + 1)); break; }
                                q=$_SX_E; _stx_walk "$m" "${s:p+1:q-p-2}" 0 0
                            elif [ "${s:p+1:1}" = '(' ]; then
                                _stx_end "$s" $((p + 2)) P || { j=$((n + 1)); break; }
                                q=$_SX_E; _stx_walk "$m" "${s:p+2:q-p-3}" 0 0
                            else
                                p=$((p + 1)); continue
                            fi
                            lift=$lift$_SX$'\n'; p=$q
                            if [ "$p" -ge "$j" ]; then
                                rest=${s:p}; l=${rest%%$'\n'*}; j=$((p + ${#l} + 1))
                            fi
                            continue ;;
                    esac
                    p=$((p + 1))
                done
            fi
            i=$j
        done
        k=$((k + 1))
    done
    [ "$i" -le "$n" ] || i=$n
    o=$o$lift
}

# _stx_end TEXT START KIND [DQ] — _SX_E is the index just past the construct
# opened before START: KIND P `$(`, C `${` (DQ=1: opened inside "...", where
# `'` is plain text), B a backtick. Returns 1 when it never closes.
# shellcheck disable=SC2317,SC2329
_stx_end() {
    local s=$1 i=$2 st=$3 n=${#1} c t rest b
    [ "$st" != C ] || [ "${4:-0}" = 0 ] || st=E
    while [ "$i" -lt "$n" ]; do
        # the same 32-deep bound as _stx_walk: each byte re-reads the stack
        [ "${#st}" -le 32 ] || { _SX_OVER=1; _SX_E=-1; return 1; }
        c=${s:i:1}; t=${st#"${st%?}"}
        case $t in
            B)
                case $c in
                    '\') i=$((i + 2)); continue ;;
                    '`') st=${st%?} ;;
                esac ;;
            D)
                case $c in
                    '\') i=$((i + 2)); continue ;;
                    '"') st=${st%?} ;;
                    '`') st=${st}B ;;
                    '$')
                        case ${s:i+1:1} in
                            '(') st=${st}P; i=$((i + 2)); continue ;;
                            '{') st=${st}E; i=$((i + 2)); continue ;;
                        esac ;;
                esac ;;
            *)
                case $c in
                    '\') i=$((i + 2)); continue ;;
                    "'")
                        if [ "$t" != E ]; then
                            rest=${s:i+1}; b=${rest%%\'*}
                            [ "$b" != "$rest" ] || break
                            i=$((i + ${#b} + 2)); continue
                        fi ;;
                    '"') st=${st}D ;;
                    '`') st=${st}B ;;
                    '$')
                        case ${s:i+1:1} in
                            '(') st=${st}P; i=$((i + 2)); continue ;;
                            '{')
                                if [ "$t" = E ]; then st=${st}E; else st=${st}C; fi
                                i=$((i + 2)); continue ;;
                            "'")
                                if [ "$t" != E ]; then
                                    _stx_ansi "$s" $((i + 2)); i=$_SX_E; continue
                                fi ;;
                        esac ;;
                    '(') case $t in P | p) st=${st}p ;; esac ;;
                    ')') case $t in P | p) st=${st%?} ;; esac ;;
                    '}') case $t in C | E) st=${st%?} ;; esac ;;
                    '#')
                        case $t in
                            P | p)
                                case ${s:i-1:1} in
                                    ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '(')
                                        rest=${s:i}; b=${rest%%$'\n'*}
                                        i=$((i + ${#b})); continue ;;
                                esac ;;
                        esac ;;
                esac ;;
        esac
        i=$((i + 1))
        [ -n "$st" ] || { _SX_E=$i; return 0; }
    done
    _SX_E=-1
    return 1
}

# _stx_ansi TEXT START — the `$'...'` body starting at START: _SX_W decoded
# (bash >= 4.4; older keeps it raw, as st_tokenize does), _SX_E past its `'`.
# shellcheck disable=SC2317,SC2329
_stx_ansi() {
    local s=$1 j=$2 n=${#1} c body=''
    while [ "$j" -lt "$n" ]; do
        c=${s:j:1}
        if [ "$c" = '\' ]; then
            body=$body${s:j:2}; j=$((j + 2))
        elif [ "$c" = "'" ]; then
            break
        else
            body=$body$c; j=$((j + 1))
        fi
    done
    if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
        || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
        eval 'body=${body@E}'
    fi
    _SX_W=$body
    _SX_E=$((j + 1))
}

# _stx_hdword TEXT START — the heredoc delimiter word at START after quote
# removal: _SX_W the word, _SX_Q=1 when any part was quoted (a quoted body is
# not expanded), _SX_E the index past it.
# shellcheck disable=SC2317,SC2329
_stx_hdword() {
    local s=$1 j=$2 n=${#1} c w='' q=0 rest b
    while [ "$j" -lt "$n" ]; do
        c=${s:j:1}
        case $c in
            ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '<' | '>' | '(' | ')') break ;;
            "'") rest=${s:j+1}; b=${rest%%\'*}; w=$w$b; q=1; j=$((j + ${#b} + 2)) ;;
            '\') w=$w${s:j+1:1}; q=1; j=$((j + 2)) ;;
            '"')
                q=1; j=$((j + 1))
                while [ "$j" -lt "$n" ]; do
                    c=${s:j:1}
                    if [ "$c" = '"' ]; then j=$((j + 1)); break; fi
                    if [ "$c" = '\' ]; then
                        case ${s:j+1:1} in
                            '$' | '`' | '"' | '\') w=$w${s:j+1:1}; j=$((j + 2)); continue ;;
                            $'\n') j=$((j + 2)); continue ;;
                        esac
                    fi
                    w=$w$c; j=$((j + 1))
                done ;;
            '$')
                case ${s:j+1:1} in
                    "'") _stx_ansi "$s" $((j + 2)); w=$w$_SX_W; q=1; j=$_SX_E ;;
                    '"') j=$((j + 1)) ;;
                    *) w=$w'$'; j=$((j + 1)) ;;
                esac ;;
            *) w=$w$c; j=$((j + 1)) ;;
        esac
    done
    _SX_W=$w; _SX_Q=$q; _SX_E=$j
}

# _stx_param MODE BODY DQ — classify the ${BODY} expansion. Returns 1 when the
# allowlist does not know the form (the caller keeps it verbatim), else 0 with
# _SX its replacement: '' in empty mode; in text mode its text parts, spliced
# as words, or the expansion as written when it has none.
# shellcheck disable=SC2317,SC2329
_stx_param() {
    local m=$1 b=$2 dq=$3 r f d cl t k a np=0 pe=0 o='' re
    local -a tp
    r=$b
    if [ "${r:0:1}" = '(' ]; then # zsh flags
        r=${r:1}
        while :; do
            f=${r:0:1}; r=${r:1}
            case $f in
                ')') break ;;
                l | r | j | s | Z | _ | g | I)
                    d=${r:0:1}
                    case $d in
                        '') return 1 ;;
                        '(') cl=')' ;;
                        '[') cl=']' ;;
                        '{') cl='}' ;;
                        '<') cl='>' ;;
                        *) cl=$d ;;
                    esac
                    case $f in l | r) k=3 ;; *) k=1 ;; esac
                    a=0
                    while [ "$a" -lt "$k" ] && [ "${r:0:1}" = "$d" ]; do
                        r=${r:1}; t=${r%%"$cl"*}
                        [ "$t" != "$r" ] || return 1
                        r=${r:${#t}+1}
                        if [ "$pe" = 1 ] && { [ "${BASH_VERSINFO[0]}" -gt 4 ] \
                            || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; }; then
                            eval 't=${t@E}'
                        fi
                        case $f in
                            l | r) [ "$a" = 0 ] || { tp[np]=$t; np=$((np + 1)); } ;;
                            j | s) tp[np]=$t; np=$((np + 1)) ;;
                        esac
                        a=$((a + 1))
                    done
                    [ "$a" -gt 0 ] || return 1 ;;
                p) pe=1 ;;
                [#%@AabcCDefFikLnoOPqQtuUvVwWXz0~^=SBEMNRm*]) ;;
                *) return 1 ;;
            esac
        done
    fi
    a=0
    while [ "$a" -lt 2 ]; do # prefixes: length, indirection, zsh ^ = ~ +
        case ${r:0:1} in
            '#' | '!' | '^' | '=' | '~' | '+')
                case ${r:1:1} in
                    [A-Za-z0-9_@*#?\$!^=~+-]) r=${r:1}; a=$((a + 1)); continue ;;
                esac ;;
        esac
        break
    done
    case ${r:0:1} in
        [A-Za-z_]) t=${r%%[!A-Za-z0-9_]*} ;;
        [0-9]) t=${r%%[!0-9]*} ;;
        [@*#?\$!-]) t=${r:0:1} ;;
        *) return 1 ;;
    esac
    r=${r:${#t}}
    while [ "${r:0:1}" = '[' ]; do
        t=${r%%]*}
        [ "$t" != "$r" ] || return 1
        case $t in *'$('* | *'`'* | '['*'['*) return 1 ;; esac
        r=${r:${#t}+1}
    done
    case $r in
        '' | '*' | '@') ;;
        '::='*) tp[np]=${r:3}; np=$((np + 1)) ;;
        ':-'* | ':='* | ':+'*) tp[np]=${r:2}; np=$((np + 1)) ;;
        '-'* | '='* | '+'*) tp[np]=${r:1}; np=$((np + 1)) ;;
        ':?'* | '?'* | '#'* | '%'* | ':#'* | '^'* | ','* | '~'*) ;;
        '@'[QEPAKakuUL]) ;;
        '/'* | ':/'*)
            r=${r#:}; r=${r#/}
            case $r in '/'* | '#'* | '%'*) r=${r:1} ;; esac
            if _stx_slash "$r"; then tp[np]=${r:_SX_E+1}; np=$((np + 1)); fi ;;
        ':'*)
            case $r in *':s'* | *':S'* | *':g'* | *':G'* | *':&'*) return 1 ;; esac
            re='^(:[aAcehlPqQrtu][0-9]*)+$'
            if ! [[ $r =~ $re ]]; then
                case ${r:1:1} in [0-9' '\$'('A-Za-z_]) ;; *) return 1 ;; esac
            fi ;;
        *) return 1 ;;
    esac
    _SX=''
    [ "$m" = text ] || return 0
    if [ "$np" = 0 ]; then _SX='${'$b'}'; return 0; fi
    k=0
    while [ "$k" -lt "$np" ]; do
        _stx_walk "$m" "${tp[k]}" "$dq" 1
        o=$o$_SX
        [ "$_SX_DQ" = "$dq" ] || o=$o'"'
        k=$((k + 1))
    done
    _SX=$o
}

# _stx_slash TEXT — _SX_E is the index of TEXT's first `/` outside quotes,
# escapes and nested expansions (the pattern/replacement split); 1 when none.
# shellcheck disable=SC2317,SC2329
_stx_slash() {
    local s=$1 n=${#1} i=0 c rest b
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case $c in
            '\') i=$((i + 2)); continue ;;
            "'" | '"')
                rest=${s:i+1}; b=${rest%%"$c"*}
                [ "$b" != "$rest" ] || break
                i=$((i + ${#b} + 2)); continue ;;
            '$')
                case ${s:i+1:1} in
                    '(') _stx_end "$s" $((i + 2)) P || break; i=$_SX_E; continue ;;
                    '{') _stx_end "$s" $((i + 2)) C || break; i=$_SX_E; continue ;;
                esac ;;
            '/') _SX_E=$i; return 0 ;;
        esac
        i=$((i + 1))
    done
    _SX_E=-1
    return 1
}
