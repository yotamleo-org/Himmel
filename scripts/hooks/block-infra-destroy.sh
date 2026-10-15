#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# Denies commands that destroy cloud, cluster, database or docker data in one
# step: terraform/tofu/pulumi destroy, kubectl delete|drain, helm uninstall,
# aws/gcloud/az delete|terminate, SQL DROP|TRUNCATE|DELETE FROM, FLUSHALL,
# dropdb, prisma migrate reset, docker system|volume prune, volume rm and
# compose down -v. Without this floor only the classifier stands in the way.
#
# The verbs are DATA, not code: scripts/hooks/infra-destroy-verbs.json (shape
# like scripts/guardrails/egress-matrix.json). A rule matches one shell segment
# by its COMMAND WORD, so `echo terraform destroy`, `grep 'DROP TABLE' f.sql`
# and `git commit -m "kubectl delete"` pass: the verb sits in data position.
# The segment's command word is read from the guard-unwrap tokenizer, so a
# quoted (`terraform "destroy"`), wrapped (`env X=1 sudo kubectl delete`),
# chained or `bash -c` form is denied the same as the plain one.
#
# Accepted limits (prefer an over-deny to a miss; this is a floor, not a wall):
#   * a SQL client rule scans the whole command text once the command word is a
#     SQL client, so `psql -c 'select 1'; echo "drop table"` over-denies;
#   * a destroy verb carried as DATA to another executor (`ssh host terraform
#     destroy`, `kubectl exec pod -- psql ...`, `xargs`) is not read; and a SQL
#     file run by `psql -f x.sql` is not read (only inline or heredoc SQL);
#   * `terraform plan -destroy` and read forms pass; `apply -destroy` denies;
#   * a command word held in a variable (`$T destroy`) is unreadable, so it is
#     tried against every rule's arguments (`T=ls; $T delete` over-denies);
#   * the flat scan (PowerShell, or input the tokenizer cannot read) denies a
#     table-bin word followed by more than 256 words rather than crawl them
#     or leave a verb past the window unread (a long command over-denies).
#
# A pattern in the verbs table that does not compile refuses the call (exit 2).
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow   2 - block (stderr is shown to Claude and the user)
#
# Bypass: set INFRADESTROYOK=1 in the shell that launched Claude Code (a
# per-call prefix does not reach the hook). Session-sticky; restart to re-enable.
set -o pipefail

# Fail closed on any unexpected exit.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

[ "${INFRADESTROYOK:-0}" = "1" ] && exit 0

if ! command -v jq >/dev/null 2>&1; then
    echo "block-infra-destroy: jq not on PATH - refusing to evaluate; install jq or set INFRADESTROYOK=1" >&2
    exit 2
fi

input=$(cat)
[ -n "$input" ] || exit 0
if ! tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null); then
    echo "block-infra-destroy: unparseable hook input - failing closed" >&2
    exit 2
fi
case "$tool" in
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 2
[ -n "$cmd" ] || exit 0
# Strip CR at the capture boundary: a CRLF form must not change a verdict.
cmd=${cmd//$'\r'/}

case "${BASH_SOURCE[0]}" in
    */*) _here=${BASH_SOURCE[0]%/*} ;;
    *) _here=. ;;
esac
TABLE="$_here/infra-destroy-verbs.json"
_gu_lib="$_here/lib/guard-unwrap.sh"

# shellcheck source=lib/guard-unwrap.sh
if ! { [ -r "$_gu_lib" ] && . "$_gu_lib"; } 2>/dev/null; then
    echo "block-infra-destroy: cannot load $_gu_lib - failing closed" >&2
    exit 2
fi
if [ "$tool" != PowerShell ]; then
    guard_unwrap "${BASH_SOURCE[0]}" "$cmd" || exit 2
fi

if [ ! -r "$TABLE" ]; then
    echo "block-infra-destroy: cannot read verbs table $TABLE - failing closed" >&2
    exit 2
fi
# One rule per line: id, bins, argv_all, argv_any, text_any, always, note.
# Fields split on STX; patterns inside a field on US.
if ! rules=$(jq -r '.rules[] | [.id, (.bins|join(" ")), ((.argv_all // [])|join("\u001f")),
        ((.argv_any // [])|join("\u001f")), ((.text_any // [])|join("\u001f")),
        ((.always // false)|tostring), (.note // "")] | join("\u0002")' "$TABLE" 2>/dev/null); then
    echo "block-infra-destroy: verbs table $TABLE is not valid JSON - failing closed" >&2
    exit 2
fi
if ! runners=$(jq -r '(.runners // []) | join(" ")' "$TABLE" 2>/dev/null); then
    exit 2
fi
if ! allbins=$(jq -r '([.rules[].bins[]] + (.runners // [])) | join(" ")' "$TABLE" 2>/dev/null); then
    exit 2
fi
[ -n "$rules" ] || { echo "block-infra-destroy: verbs table has no rules - failing closed" >&2; exit 2; }

# A pattern bash cannot compile makes `[[ x =~ p ]]` return 2, which every
# matcher below reads as "no match": the rule would silently stop firing. Refuse
# the whole table instead.
while IFS=$'\002' read -r _vid _vbins _vall _vany _vtext _valways _vnote; do
    for _vf in "$_vall" "$_vany" "$_vtext"; do
        [ -n "$_vf" ] || continue
        IFS=$'\037' read -r -a _vpats <<<"$_vf"
        for _vp in "${_vpats[@]}"; do
            [[ x =~ $_vp ]]
            if [ $? -eq 2 ]; then
                echo "block-infra-destroy: verbs table rule '$_vid' has a malformed pattern '$_vp' - failing closed" >&2
                exit 2
            fi
        done
    done
done <<<"$rules"

SCAN_BIN=
lc_cmd=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')

deny() {
    {
        echo "block-infra-destroy: denied - $1 ($2)."
        echo "    This command destroys infra, database or docker data in one step."
        echo "    Run it yourself in your own shell, or relaunch with INFRADESTROYOK=1 set in the launching shell."
        echo "    Verbs table: scripts/hooks/infra-destroy-verbs.json"
    } >&2
    exit 2
}

# any_word_matches <pattern> <word>... -> 0 when some word matches the ERE
any_word_matches() {
    local pat="$1" w
    shift
    for w in "$@"; do
        [[ $w =~ $pat ]] && return 0
    done
    return 1
}

# eval_segment <bin> [<arg>...] - exits 2 through deny() on a match.
eval_segment() {
    local bin="$1" id rbins rall rany rtext ralways note p ok
    local -a pats
    shift
    while IFS=$'\002' read -r id rbins rall rany rtext ralways note; do
        [ -n "$id" ] || continue
        case " $rbins " in *" $bin "*) ;; *) [ "$bin" = '*' ] || continue ;; esac
        if [ "$ralways" = true ]; then
            [ "$bin" = '*' ] && continue
            deny "$note" "$id"
        fi
        if [ -n "$rtext" ]; then
            IFS=$'\037' read -r -a pats <<<"$rtext"
            for p in "${pats[@]}"; do
                [[ $lc_cmd =~ $p ]] && deny "$note" "$id"
            done
        fi
        if [ -n "$rall" ] || [ -n "$rany" ]; then
            ok=1
            if [ -n "$rall" ]; then
                IFS=$'\037' read -r -a pats <<<"$rall"
                for p in "${pats[@]}"; do
                    any_word_matches "$p" "$@" || { ok=0; break; }
                done
            fi
            if [ "$ok" = 1 ] && [ -n "$rany" ]; then
                ok=0
                IFS=$'\037' read -r -a pats <<<"$rany"
                for p in "${pats[@]}"; do
                    any_word_matches "$p" "$@" && { ok=1; break; }
                done
            fi
            [ "$ok" = 1 ] && deny "$note" "$id"
        fi
    done <<<"$rules"
}

# scan_words <word>... - the first word is the command word; resolve a package
# runner (npx prisma ...) to the tool it runs, then evaluate.
scan_words() {
    local bin
    local -a cw
    [ $# -gt 0 ] || return 0
    if [ -n "$SCAN_BIN" ]; then
        bin=$SCAN_BIN
        SCAN_BIN=
    else
        bin=$(printf '%s' "${1##*[/\\]}" | tr '[:upper:]' '[:lower:]'); bin=${bin%.exe}; bin=${bin%.cmd}
    fi
    # A command word held in a variable or substitution cannot be read, so it
    # matches every rule's arguments (the `*` bin).
    case "$bin" in *'$'*|*'`'*) bin='*' ;; esac
    case " $runners " in
        *" $bin "*)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    -c|--call)
                        # npx -c '<command string>': the value is itself a command.
                        shift
                        if [ $# -gt 0 ]; then
                            read -r -a cw <<<"$1"
                            scan_words "${cw[@]}"
                            shift
                        fi
                        ;;
                    -p|--package|-w|--workspace|--prefix|--cache) shift; [ $# -gt 0 ] && shift ;;
                    -*|dlx|exec|run|x) shift ;;
                    *) break ;;
                esac
            done
            [ $# -gt 0 ] || return 0
            bin=$(printf '%s' "${1##*[/\\]}" | tr '[:upper:]' '[:lower:]'); bin=${bin%.exe}; bin=${bin%.cmd}
            case "$bin" in *'$'*|*'`'*) bin='*' ;; esac
            ;;
    esac
    shift
    eval_segment "$bin" "$@"
}

if [ "$tool" != PowerShell ] && [ "${GU_TOKENIZED:-0}" = 1 ]; then
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        if [ "${GU_LOOKUP[s]:-0}" = 0 ]; then
            read -r -a _idx <<<"${GU_SW[s]:-}"
            _core=${GU_CORE[s]:-0}
            if [ "$_core" -lt "${#_idx[@]}" ]; then
                _w=()
                _k=$_core
                while [ "$_k" -lt "${#_idx[@]}" ]; do
                    _w[${#_w[@]}]=${ST_W[${_idx[_k]}]}
                    _k=$((_k + 1))
                done
                scan_words "${_w[@]}"
            fi
        fi
        s=$((s + 1))
    done
else
    # PowerShell, or a command the tokenizer does not model: no command-word
    # positions exist, so every word is tried as the command word. A form this
    # guard cannot read counts as a denied one if a verb rule fires.
    # Linear: only a word whose lowercased basename is a table bin or runner
    # (or holds a `$`) is tried as a command word, and one with more than
    # FLAT_SPAN words after it denies (a verb past the window would go unread).
    _flat=${cmd//[;&|()\"\'\`]/ }
    _flat=${_flat//$'\n'/ }
    read -r -a _all <<<"$_flat"
    _flat=${lc_cmd//[;&|()\"\'\`]/ }
    _flat=${_flat//$'\n'/ }
    read -r -a _lc <<<"$_flat"
    FLAT_SPAN=256
    _k=0
    while [ "$_k" -lt "${#_all[@]}" ]; do
        _b=${_lc[_k]##*[/\\]}
        _b=${_b%.exe}
        _b=${_b%.cmd}
        case "$_b" in
            *'$'*) _b='*' ;;
            *) case " $allbins " in *" $_b "*) ;; *) _k=$((_k + 1)); continue ;; esac ;;
        esac
        if [ $((${#_all[@]} - _k - 1)) -gt "$FLAT_SPAN" ]; then
            deny "more than $FLAT_SPAN words follow a command word in a command this guard cannot tokenize" flat-scan-span
        fi
        SCAN_BIN=$_b
        scan_words "${_all[@]:_k}"
        SCAN_BIN=
        _k=$((_k + 1))
    done
fi
exit 0
