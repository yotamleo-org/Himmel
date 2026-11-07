#!/usr/bin/env bash
# check-write-hold.sh — PreToolUse hook (Edit|Write|MultiEdit|NotebookEdit, LAST in that chain): the write half of the
# single-writer barrier. A worker's write onto a file another live worker or open PR holds is denied; a
# write onto a free file publishes the worker's row in the register holds.py owns.
#
# Blocks only on a positive answer: a readable row, another holder, that holder alive, no grant. Every other answer
# passes. A coordination guard, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs fail-closed"): no jq, bad
# stdin or a crash is silent; a register it cannot write says so once per session on stderr.
#
# Last in its chain because the chain's first deny short-circuits: an earlier deny never leaves a row (I11). NOT in
# MUST_RUN_CHAIN_MEMBERS: a must-run overrun fails the chain closed, against I5, and a member's window is 15 s, so this
# hook bounds holds.py below that itself.
#
# It parses no shell text. The tool payload names one path, so the shapes are that path's forms: relative, "..", a
# symlink, MultiEdit's file_path, NotebookEdit's notebook_path.
#
# Off: unset HIMMEL_CONSOLE_LEG, HIMMEL_HOLD_KEY or HIMMEL_HOLD_DOC (not a worker the barrier knows, and a row with no
# doc would read dead at 15 minutes); WRITE_HOLD_OK=1 in the launching shell; <register>/OFF; `.single-writer` at the
# primary checkout's root. Marker in a linked worktree only: the barrier stays on (I8).
#
# ponytail: block-chokepoint-env-prefix.sh's interpreter words are bash, sh, . and source (its header), so an empty
# HIMMEL_CONSOLE_LEG prefix on `python3 -I holds.py grant` looks unstopped; ceiling: a worker can grant itself, seen in
# events.log; upgrade path: teach that hook python3.
# ponytail: the common path does not fold scripts/lib/rename-aliases.tsv; ceiling: a renamed path passes this hook under
# its other name until the commit check; upgrade path: alias contention falls through to holds.py.
# ponytail: no scripts/chokepoints.json key for holds.py, because test-chokepoint-seam-guard.sh requires a bash guard
# line and `bash <key> --help` rc 96; ceiling: an env prefix on holds.py is not refused; upgrade path: a chokepoint key once holds.py carries a bash guard line.
#
# Platform guard: bash 3.2-safe; the uncontended path forks only jq, git, ln and rm (budget 20 ms, mean of 100 runs).
#
# Hook I/O: JSON on stdin. exit 0 = allow (nothing on stdout), exit 2 = deny (stderr plus a structured
# hookSpecificOutput.permissionDecision on stdout, the guard-worker-wakeup.sh idiom).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

exec 3>&2 2>/dev/null  # a crash stays silent; what this hook means to say goes to fd 3
scratch=""
denied=0
trap '[ -z "$scratch" ] || rm -f "$scratch"; [ "$denied" != 1 ] || exit 2; exit 0' EXIT  # exit 2 only from deny: a syntax error also exits 2

[ "${WRITE_HOLD_OK:-0}" != "1" ] || exit 0
KEY="${HIMMEL_HOLD_KEY:-}"
DOC="${HIMMEL_HOLD_DOC:-}"
[ -n "$KEY" ] && [ -n "$DOC" ] || exit 0
case "$DOC" in /*) ;; *) exit 0 ;; esac
LC_ALL=C  # bytes: a name's length and every escape below are byte-wise, as holds.py measures them
[[ "$KEY" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
payload=$(jq -r '(.tool_input.file_path // .tool_input.notebook_path // "") as $p
    | if ($p | type) != "string" or ($p | test("\n")) then "" else $p end, (.cwd // "")' 2>/dev/null) || exit 0
path=${payload%%$'\n'*}
[ -n "$path" ] || exit 0
case "$payload" in *$'\n'*) cwd=${payload#*$'\n'} ;; *) cwd="" ;; esac

HERE=${BASH_SOURCE[0]%/*}
[ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
case "$HERE" in /*) ;; *) HERE="$PWD/$HERE" ;; esac
HOLDS="$HERE/../handover/chief-kit/holds.py"
EXEMPT="$HERE/../handover/chief-kit/holds-exempt.txt"

ROOT="$HOME/.himmel/state/holds"
[ ! -e "$ROOT/OFF" ] || exit 0

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

deny() {  # deny <text>: the structured decision plus stderr, exit 2
    local reason
    reason=$(printf '%s' "$1" | jq -Rs . 2>/dev/null) || reason='"write-hold: this file is held by another worker"' # swallow-ok: the deny still names the refusal, stderr carries the full text
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$1" >&3
    denied=1
    exit 2
}

holds_real() {  # the hook's own primary checkout's holds.py, shell-quoted: a chief pastes it, and a worktree's copy is its worker's to edit
    local home real
    home=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || home=""  # swallow-ok: no git answer falls back to the hook's sibling below
    real="${home%/.git}/scripts/handover/chief-kit/holds.py"
    [ -n "$home" ] && [ -f "$real" ] || real="$(cd -P "${HOLDS%/*}" && printf '%s' "$PWD")/holds.py"
    printf '%q' "$real"
}

clean() { local s=${1//$'\t'/ }; s=${s//$'\r'/ }; printf '%s' "${s//$'\n'/ }"; }  # as holds.py clean does

event() {  # event <event> <path> <holder>: one events.log line, as holds.py log_event writes it
    mkdir -p "$ROOT" && printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(clean "$2")" "$KEY" "$3" >> "$ROOT/events.log"
}

warn_once() {  # the register itself is the fault: one line per session, keyed by the worker
    local marker="${TMPDIR:-/tmp}/himmel-hold-warned-$KEY"
    [ ! -e "$marker" ] || return 0
    : > "$marker"
    printf 'check-write-hold: cannot write the holds register at %s; this write passes unheld\n' "$ROOT" >&3
}

bounded() {  # bounded <seconds> <stdout file> <stderr file> <command...>: its rc, or 124 once the bound fires
    local ticks=$(($1 * 10)) out=$2 err=$3 pid
    shift 3
    "$@" > "$out" 2> "$err" < /dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -le 0 ]; then
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$((ticks - 1))
    done
    wait "$pid"
}

# Physical spelling of the path, with no realpath fork: cd -P each directory that exists; what does not exist yet stays
# as text, and a ".." there pops that text. A symlinked last component is followed by readlink, a few hops at most.
case "$path" in /*) ;; *) path="${cwd:-$PWD}/$path" ;; esac
hops=0
last=""
while :; do
    cd -P / || exit 0
    missing=""
    rest=$path
    while [ -n "$rest" ]; do
        case "$rest" in
            */*) part=${rest%%/*}; rest=${rest#*/} ;;
            *) part=$rest; rest="" ;;
        esac
        case "$part" in
            ''|.) continue ;;
            ..)
                if [ -n "$missing" ]; then
                    case "$missing" in */*) missing=${missing%/*} ;; *) missing="" ;; esac
                else
                    cd -P .. || exit 0
                fi
                ;;
            *)
                if [ -z "$rest" ]; then
                    last=$part
                elif [ -z "$missing" ] && cd -P "./$part" 2>/dev/null; then  # ./ so no CDPATH, and no dash option or OLDPWD
                    :
                else
                    missing="${missing:+$missing/}$part"
                fi
                ;;
        esac
    done
    [ -n "$last" ] || exit 0  # the path ended on a directory spelling: a tree never holds
    [ -z "$missing" ] && [ -L "./$last" ] || break
    hops=$((hops + 1))
    [ "$hops" -le 8 ] || exit 0
    link=$(readlink "./$last") || exit 0
    case "$link" in /*) path=$link ;; *) path="$PWD/$link" ;; esac
    last=""
done
[ ! -d "./${missing:+$missing/}$last" ] || exit 0
target="${PWD%/}/${missing:+$missing/}$last"

reg=$ROOT
if [ -d "$ROOT" ]; then
    reg=$(cd -P "$ROOT" && printf '%s' "$PWD") || reg=$ROOT
fi
case "$target/" in
    "$reg"/*|"$ROOT"/*)
        event deny "$target" register
        deny "$target is inside the holds register, which only holds.py writes. To let another worker write a held file, your chief runs: python3 -I $(holds_real) grant. Bypass: WRITE_HOLD_OK=1 in the launching shell"
        ;;
esac

# One repo identity, however the worker reached the file: git-common-dir minus /.git, as holds.py primary_of derives it.
ids=$(git rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null) || exit 0 # swallow-ok: outside a repo or git fault, the hook fails open by design
top=${ids%%$'\n'*}
common=${ids#*$'\n'}
case "$top" in /*) ;; *) exit 0 ;; esac
case "$common" in /*) ;; *) exit 0 ;; esac
primary=${common%/.git}
[ ! -f "$primary/.single-writer" ] || exit 0

# ponytail: a gitignored path is claimed like a tracked one; ceiling: two workers writing one ignored name in their own
# worktrees meet on one row and the second is refused; upgrade path: on the contested path only, pass on git check-ignore -q.
case "$target" in "$top"/*) rel=${target#"$top"/} ;; *) exit 0 ;; esac

if [ -r "$EXEMPT" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" != "$rel" ] || exit 0
    done < "$EXEMPT"
fi

slug=${primary//\%/%25}
slug=${slug//\//%2F}
name=${rel//\%/%25}
name=${name//\//%2F}
dir="$ROOT/$slug"
row="$dir/$name"

if [ "${#name}" -gt 255 ]; then
    event fault "$rel" 'path name over 255 bytes'
    exit 0
fi
# A row by this name would read as a grant sibling of another path, a false grant: holds.py claim_one refuses it too.
if [[ "$name" =~ \.grant\.[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]]; then
    event fault "$rel" 'path name looks like a grant sibling'
    exit 0
fi

if [ ! -e "$row" ]; then
    tmp="$dir/%00w.$$"
    if ! { [ -d "$dir" ] || mkdir -p "$dir"; } || ! printf '%s\t%s\t%s\tclaim\t\n' "$KEY" "$(clean "${HIMMEL_HOLD_LABEL:-}")" "$(clean "$DOC")" > "$tmp"; then
        rm -f "$tmp"
        warn_once
        exit 0
    fi
    ln "$tmp" "$row"
    linked=$?
    rm -f "$tmp"
    [ "$linked" -ne 0 ] || exit 0
    if [ ! -e "$row" ]; then
        warn_once
        exit 0
    fi
    # a rival linked it between the test and the ln: answer as for any contested row
fi

held=""
if IFS= read -r held < "$row"; then
    case "$held" in "$KEY"$'\t'*) exit 0 ;; esac
fi
[ ! -e "$row.grant.$KEY" ] || exit 0

if ! scratch=$(mktemp "${TMPDIR:-/tmp}/himmel-hold.XXXXXX"); then
    event fault "$rel" 'mktemp failed'
    exit 0
fi
bounded 10 /dev/null "$scratch" python3 -I "$HOLDS" claim --key "$KEY" --label "${HIMMEL_HOLD_LABEL:-}" --doc "$DOC" --repo "$primary" --source claim -- "$rel"
rc=$?
if [ "$rc" -eq 124 ]; then
    event fault "$rel" 'holds.py over the bound'
    exit 0
fi
[ "$rc" -ne 0 ] || exit 0
if [ "$rc" -ne 1 ]; then
    event fault "$rel" "holds.py exit $rc"
    exit 0
fi
refused=0
while IFS= read -r line; do
    case "$line" in holds:*) refused=1 ;; esac
done < "$scratch"
if [ "$refused" != 1 ]; then
    event fault "$rel" 'holds.py exit 1 with no holds: line'
    exit 0
fi

# A positive answer. holds.py already logged the deny event; re-read the row, which a takeover race may have changed.
IFS= read -r now < "$row" && held=$now
h_key=${held%%$'\t'*}
h_rest=${held#*$'\t'}
h_label=${h_rest%%$'\t'*}
h_rest=${h_rest#*$'\t'}
h_rest=${h_rest#*$'\t'}
h_source=${h_rest%%$'\t'*}

route=any
if bounded 2 "$scratch" /dev/null python3 -I "$HOLDS" grant-route --repo "$primary" -- "$rel"; then
    IFS= read -r route < "$scratch" || route=any
fi
printf -v q_repo '%q' "$primary"
printf -v q_rel '%q' "$rel"
case "$route" in
    chief)
        deny "$rel is a trust path, held by $h_key ($h_label, $h_source). Keep working on other files. This deny is logged: your chief sees it on its tick (hreg=) and can stamp a grant with: python3 -I $(holds_real) grant --key $KEY --repo $q_repo --chief-doc CHIEF_DOC $q_rel . Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1"
        ;;
    operator)
        deny "$rel is a settings or CI-workflow path, held by $h_key ($h_label, $h_source). Keep working on other files. This deny is logged: your chief sees it on its tick (hreg=), and only the operator grants it, in a real terminal. Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1"
        ;;
esac
deny "$rel is held by $h_key ($h_label, $h_source). Keep working on other files, and send your chief: HOLD-ASK $rel $KEY. Chief grants with: python3 -I $(holds_real) grant --key $KEY --repo $q_repo $q_rel . Bypass: WRITE_HOLD_OK=1 in the launching shell"
