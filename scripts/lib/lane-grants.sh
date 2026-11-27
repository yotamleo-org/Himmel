#!/usr/bin/env bash
# lane-grants.sh — per-lane capability grants from the operator's config.json.
#
#   {"lane_grants":{"codex":["git-push-branch"]},
#    "lane_grants_origin":"github.com/OWNER/NAME"}
#
# A grant exempts ONE exact command shape from block-terminal-write-fence.sh,
# never a whole deny arm. Every read, parse, type, symlink, ownership,
# permission or path-mismatch failure grants nothing. Reference:
# docs/internals/enforcement.md#lane-capability-grants.
#
# Sourced (not run); sources nothing. The caller sources
# scripts/lib/load-dotenv.sh, scripts/lib/nwo.sh and scripts/guardrails/lib.sh
# first. Bash 3.2-safe, jq only; every function returns, never exits, and is
# safe under `set -euo pipefail` when called as `x=$(f) || x=`.
#
#   lane_config_path             the config path; rc 1 unless the policy-dir path
#                                and the $HOME path are one file.
#   lane_origin_ok <dir>         every fetch and push URL of <dir>'s origin (after
#                                insteadOf and pushurl) names the pinned repo, and
#                                no push refspec or mirror mode is set. A remote
#                                helper (`::`) or an `@` in the URL path refuses.
#   lane_grant_argv <command>    the words of ONE simple command of literal words,
#                                one per line. LC_ALL=C, so no locale collation
#                                widens the unquoted allowlist; a word starting
#                                with = is refused (zsh expands it to a path).
#   lane_net_host_ok <host>      the one host check of a granted fetch; open by
#                                default.
#   lane_grant_shape <payload>   the capability the command holds a grant for. A
#                                JSON string holding NUL is refused because bash
#                                would drop the byte. gh picks its base repo among
#                                all remotes, hence origin only.
#   lane_grants_report [<root>]  for the doctor: `info:`, `<lane>: <caps> (<state>)`
#                                and `problem:` lines in fixed text only. When
#                                $HOME is not the account home it reads only the
#                                $HOME config.

_lane_helpers() {
    local f
    for f in _himmel_policy_dir _cmg_url_nwo _cmg_canon_nwo _cmg_nwo_eq \
        primary_checkout_root default_branch is_main_ref _branch_set; do
        declare -f "$f" >/dev/null 2>&1 || return 1
    done
    command -v jq >/dev/null 2>&1 || return 1
}

lane_config_path() {
    local dir
    dir=$(_himmel_policy_dir) || return 1
    [ -n "${HOME:-}" ] || return 1
    [ "$dir/config.json" -ef "$HOME/.himmel/config.json" ] || return 1
    printf '%s\n' "$dir/config.json"
}

lane_config_owner_ok() { [ -O "$1" ]; }
lane_config_find() { find "$@"; }

lane_config_trusted() {
    local file="${1:-}" dir p bit out
    [ -n "$file" ] || return 1
    dir=${file%/*}
    [ ! -L "$dir" ] || return 1
    [ ! -L "$file" ] || return 1
    [ -f "$file" ] || return 1
    [ -r "$file" ] || return 1
    for p in "$dir" "$file"; do
        lane_config_owner_ok "$p" || return 1
        for bit in -020 -002; do
            out=$(lane_config_find "$p" -prune -perm "$bit" -print) || return 1
            [ -z "$out" ] || return 1
        done
    done
}

_lane_trusted_config() {
    local file
    file=$(lane_config_path) || return 1
    lane_config_trusted "$file" || return 1
    printf '%s\n' "$file"
}

lane_grant_origin() {
    local file value
    _lane_helpers || return 1
    file=$(_lane_trusted_config) || return 1
    value=$(jq -r -s 'if length == 1 and (.[0] | type == "object") and (.[0].lane_grants_origin | type == "string")
        then .[0].lane_grants_origin else "" end' "$file" 2>/dev/null) || return 1
    _cmg_canon_nwo "$value" || return 1
    printf '%s\n' "$_CMG_CANON"
}

lane_grant_has() {
    local lane="${1:-}" cap="${2:-}" file
    _lane_helpers || return 1
    case "$lane" in antigravity|codex) ;; *) return 1 ;; esac
    case "$cap" in
        git-push-branch|gh-pr-create|net-read) ;;
        manage-task-own) [ "$lane" = antigravity ] || return 1 ;;
        *) return 1 ;;
    esac
    file=$(_lane_trusted_config) || return 1
    jq -e -s --arg l "$lane" --arg c "$cap" 'length == 1 and (.[0] | type == "object")
        and (.[0].lane_grants | type == "object") and (.[0].lane_grants[$l] | type == "array")
        and (.[0].lane_grants[$l] | all(type == "string")) and (.[0].lane_grants[$l] | index($c) != null)' \
        "$file" >/dev/null 2>&1 || return 1
    case "$cap" in
        git-push-branch|gh-pr-create) lane_grant_origin >/dev/null || return 1 ;;
    esac
}

_lane_unset_git() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
}

lane_origin_ok() (
    dir="${1:-}"
    [ -n "$dir" ] || return 1
    want=$(lane_grant_origin) || return 1
    _lane_unset_git
    for mode in fetch push; do
        if [ "$mode" = push ]; then
            url=$(git -C "$dir" remote get-url --push --all origin 2>/dev/null) || return 1
        else
            url=$(git -C "$dir" remote get-url --all origin 2>/dev/null) || return 1
        fi
        case "$url" in
            ''|*$'\n'*|*::*|*://*/*@*) return 1 ;;
        esac
        got=$(_cmg_url_nwo "$url") || return 1
        _cmg_canon_nwo "$got" || return 1
        _cmg_nwo_eq "$_CMG_CANON" "$want" || return 1
    done
    rc=0
    git -C "$dir" config --get-all remote.origin.push >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || return 1
    rc=0
    mirror=$(git -C "$dir" config --type=bool --get remote.origin.mirror 2>/dev/null) || rc=$?
    case "$rc:$mirror" in 1:|0:false) ;; *) return 1 ;; esac
    return 0
)

lane_grant_argv() (
    LC_ALL=C
    s="${1:-}"
    case "$s" in *$'\n'*|*$'\r'*) return 1 ;; esac
    n=${#s}
    i=0
    q=''
    word=''
    have=0
    out=''
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        i=$((i + 1))
        if [ "$q" = "'" ]; then
            if [ "$c" = "'" ]; then q=''; else word=$word$c; fi
            continue
        fi
        if [ "$q" = '"' ]; then
            case "$c" in
                '"') q='' ;;
                '$'|'`'|\\|'!') return 1 ;;
                *) word=$word$c ;;
            esac
            continue
        fi
        case "$c" in
            ' '|$'\t')
                if [ "$have" = 1 ]; then out=$out$word$'\n'; word=''; have=0; fi
                ;;
            "'"|'"') q=$c; have=1 ;;
            [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@,+-])
                if [ "$have" = 0 ] && [ "$c" = '=' ]; then return 1; fi
                word=$word$c
                have=1
                ;;
            *) return 1 ;;
        esac
    done
    [ -z "$q" ] || return 1
    if [ "$have" = 1 ]; then out=$out$word$'\n'; fi
    printf '%s' "$out"
)

lane_net_host_ok() { [ -n "${1:-}" ]; }

_lane_url_ok() {
    local url="${1:-}" auth
    case "$url" in https://*) ;; *) return 1 ;; esac
    case "$url" in *[[:space:][:cntrl:]]*|*'{'*|*'}'*|*'['*|*']'*) return 1 ;; esac
    auth=${url#https://}
    auth=${auth%%[/?#]*}
    case "$auth" in ''|*@*|*\\*) return 1 ;; esac
    lane_net_host_ok "${auth%%:*}" || return 1
}

_lane_shape_curl() {
    local globoff=0 urls=0
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -g|--globoff) globoff=1 ;;
            --silent|--show-error|--fail|--compressed) ;;
            -m|--max-time)
                [ "$#" -ge 2 ] || return 1
                case "$2" in ''|*[!0-9]*) return 1 ;; esac
                shift
                ;;
            --*) return 1 ;;
            -?*)
                case "${1#-}" in *[!sSfg]*) return 1 ;; esac
                case "$1" in *g*) globoff=1 ;; esac
                ;;
            *) _lane_url_ok "$1" || return 1; urls=$((urls + 1)) ;;
        esac
        shift
    done
    [ "$globoff" = 1 ] || return 1
    [ "$urls" = 1 ] || return 1
}

_lane_shape_wget() {
    local noredirect=0 stdout=0 quiet=0 urls=0
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --max-redirect=0) noredirect=$((noredirect + 1)) ;;
            -O-|--output-document=-) stdout=$((stdout + 1)) ;;
            -qO-) stdout=$((stdout + 1)); quiet=$((quiet + 1)) ;;
            -O|-qO)
                [ "$#" -ge 2 ] && [ "$2" = '-' ] || return 1
                [ "$1" = -O ] || quiet=$((quiet + 1))
                stdout=$((stdout + 1))
                shift
                ;;
            -q|--quiet) quiet=$((quiet + 1)) ;;
            -*) return 1 ;;
            *) _lane_url_ok "$1" || return 1; urls=$((urls + 1)) ;;
        esac
        shift
    done
    [ "$noredirect" = 1 ] || return 1
    [ "$stdout" = 1 ] || return 1
    [ "$quiet" -le 1 ] || return 1
    [ "$urls" = 1 ] || return 1
}

_lane_shape_pr() {
    local seen=' ' key
    _LANE_HEAD=''
    shift 3
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -H|--head) key='head' ;;
            -t|--title) key=title ;;
            -b|--body) key=body ;;
            -B|--base) key=base ;;
            -d|--draft) key=draft ;;
            -f|--fill) key=fill ;;
            *) return 1 ;;
        esac
        case "$seen" in *" $key "*) return 1 ;; esac
        seen="$seen$key "
        case "$key" in
            draft|fill) ;;
            *)
                [ "$#" -ge 2 ] || return 1
                if [ "$key" = head ]; then _LANE_HEAD=$2; fi
                if [ "$key" = base ]; then
                    case "$2" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
                fi
                shift
                ;;
        esac
        shift
    done
    [ -n "$_LANE_HEAD" ] || return 1
}

_lane_scope_ok() (
    cwd=$1 cap=$2 named=$3
    _lane_unset_git
    case "$cwd" in /*) ;; *) return 1 ;; esac
    [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
    here=$(primary_checkout_root "$cwd") || return 1
    home_root=$(primary_checkout_root "$CLAUDE_PROJECT_DIR") || return 1
    [ -n "$here" ] || return 1
    [ "$here" = "$home_root" ] || return 1
    [ "$cap" != net-read ] || return 0
    _branch_set "$cwd" || return 1
    branch=$_BRANCH_OUT
    case "$branch" in
        ''|-*|refs/*|heads/*|tags/*|remotes/*|HEAD|*[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    [ "$named" = "$branch" ] || return 1
    full=$(git -C "$cwd" rev-parse --symbolic-full-name "$branch" 2>/dev/null) || return 1
    [ "$full" = "refs/heads/$branch" ] || return 1
    if is_main_ref "refs/heads/$branch"; then return 1; fi
    default=$(default_branch "$cwd" 2>/dev/null) || return 1
    [ "$branch" != "$default" ] || return 1
    lane_origin_ok "$cwd" || return 1
    if [ "$cap" = gh-pr-create ]; then
        remotes=$(git -C "$cwd" remote 2>/dev/null) || return 1
        [ "$remotes" = origin ] || return 1
    fi
    return 0
)

lane_grant_shape() {
    local payload="${1:-}" lane command cwd words word cap='' named=''
    local argv
    _lane_helpers || return 1
    printf '%s' "$payload" | jq -e '
        .tool_name == "Bash" and (.himmel_lane == "antigravity" or .himmel_lane == "codex")
        and (.tool_input | type == "object") and (.tool_input | has("workdir") | not)
        and ((.tool_input | has("cwd") | not) or .tool_input.cwd == .cwd)
        and (.tool_input.command | type == "string")
        and ([.tool_input.command, (.tool_input.cwd // .cwd // "")] | all(type == "string" and (explode | index(0) == null)))
        and ((.tool_input.cwd // .cwd // "") | contains("\n") | not)
    ' >/dev/null 2>&1 || return 1
    lane=$(printf '%s' "$payload" | jq -r '.himmel_lane') || return 1
    command=$(printf '%s' "$payload" | jq -r '.tool_input.command' && printf .) || return 1
    command=${command%$'\n.'}
    [[ $command =~ ^[[:blank:]]*(git[[:blank:]]+push|gh[[:blank:]]+pr[[:blank:]]+create|curl[[:blank:]]+-q|wget[[:blank:]]+--no-config)([[:blank:]]|$) ]] || return 1
    words=$(lane_grant_argv "$command" && printf .) || return 1
    words=${words%.}
    argv=()
    while IFS= read -r word; do
        argv[${#argv[@]}]=$word
    done <<<"${words%$'\n'}"
    set -- "${argv[@]}"
    case "${1:-} ${2:-}" in
        'git push')
            if [ "$#" = 4 ] && [ "$3" = origin ]; then
                named=$4
            elif [ "$#" = 5 ] && [ "$4" = origin ] && { [ "$3" = -u ] || [ "$3" = --set-upstream ]; }; then
                named=$5
            else
                return 1
            fi
            cap=git-push-branch
            ;;
        'gh pr')
            [ "${3:-}" = create ] || return 1
            _lane_shape_pr "$@" || return 1
            named=$_LANE_HEAD
            cap=gh-pr-create
            ;;
        'curl -q') _lane_shape_curl "$@" || return 1; cap=net-read ;;
        'wget --no-config') _lane_shape_wget "$@" || return 1; cap=net-read ;;
        *) return 1 ;;
    esac
    lane_grant_has "$lane" "$cap" || return 1
    cwd=$(printf '%s' "$payload" | jq -r '.tool_input.cwd // .cwd // ""') || return 1
    _lane_scope_ok "$cwd" "$cap" "$named" || return 1
    printf '%s\n' "$cap"
}

lane_grants_report() {
    local primary="${1:-}" dir file home_dir lane caps cap listed state lines
    _lane_helpers || { echo 'problem: a lane-grants helper or jq is missing; no grant applies'; return 0; }
    dir=$(_himmel_policy_dir) || { echo 'problem: the account home cannot be resolved; no grant applies'; return 0; }
    home_dir="${HOME:-}/.himmel"
    if [ "$dir" != "$home_dir" ] && ! [ "$dir" -ef "$home_dir" ]; then
        if [ -f "$home_dir/config.json" ] && grep -q '"lane_grants"' "$home_dir/config.json" 2>/dev/null; then
            echo 'problem: the two config paths are not the same file; no grant applies'
        else
            echo 'info: lane grants not checked (HOME is not the account home)'
        fi
        return 0
    fi
    file="$dir/config.json"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        echo 'info: no lane grants (antigravity and codex run the full terminal fence)'
        return 0
    fi
    if [ ! -f "$file" ]; then
        echo 'problem: config.json is not a regular file; no lane holds anything'
        return 0
    fi
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1; then
        echo 'problem: config.json cannot be read as one JSON object; no lane holds anything'
        return 0
    fi
    if jq -e 'has("lane_grants") | not' "$file" >/dev/null 2>&1; then
        echo 'info: no lane grants (antigravity and codex run the full terminal fence)'
        return 0
    fi
    for lane in antigravity codex; do
        caps=''
        for cap in git-push-branch gh-pr-create net-read manage-task-own; do
            if lane_grant_has "$lane" "$cap"; then caps="${caps:+$caps, }$cap"; fi
        done
        case "$lane" in
            antigravity) state='not wired until S2' ;;
            codex) state='hook only; the exec-lane sandbox blocks network and the git dir, a full-access T3 thread has no sandbox' ;;
        esac
        printf '%s: %s (%s)\n' "$lane" "${caps:-none}" "$state"
    done
    lane_config_path >/dev/null || echo 'problem: the two config paths are not the same file; no grant applies'
    lane_config_trusted "$file" || echo 'problem: config.json or its directory is a symlink, not yours, or group- or world-writable; no grant applies'
    lines=$(jq -r '
        def known: ["git-push-branch", "gh-pr-create", "net-read", "manage-task-own"];
        .lane_grants as $g
        | if ($g | type) != "object" then "problem: lane_grants is not an object; no lane holds anything"
          else
            (if (($g | keys) - ["antigravity", "codex"]) != [] then "problem: a key under lane_grants other than antigravity and codex is ignored" else empty end),
            (["antigravity", "codex"][] as $l | select($g | has($l)) | $g[$l]
              | if (type != "array") or (all(type == "string") | not) then "problem: lane_grants.\($l) is not an array of strings; that lane holds nothing"
                else
                  (if (. - known) != [] then "problem: an unknown capability name under \($l) is ignored" else empty end),
                  (if $l == "codex" and index("manage-task-own") != null then "problem: manage-task-own is not applicable to codex" else empty end)
                end)
          end' "$file" 2>/dev/null) || lines='problem: lane_grants cannot be checked'
    [ -z "$lines" ] || printf '%s\n' "$lines"
    listed=0
    if jq -e '[.lane_grants | objects | .antigravity, .codex | arrays | .[]]
        | index("git-push-branch") != null or index("gh-pr-create") != null' "$file" >/dev/null 2>&1; then
        listed=1
    fi
    [ "$listed" = 1 ] || return 0
    if ! lane_grant_origin >/dev/null; then
        echo 'problem: lane_grants_origin is unset or not a repo; push and PR are not held'
    elif [ -n "$primary" ] && ! lane_origin_ok "$primary"; then
        echo 'problem: a fetch or push URL, push refspec or mirror setting of origin does not match the pin; push and PR are refused'
    fi
    return 0
}
