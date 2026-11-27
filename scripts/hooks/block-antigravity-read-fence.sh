#!/usr/bin/env bash
set -u

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

deny() {
    printf 'block-antigravity-read-fence: %s\n' "$1" >&2
    exit 2
}

lower_str() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

canon_path() {
    local p="$1" out=""
    [ -n "$p" ] || return 1
    # prim-ok: fail-closed hook canonicalizer must not source external libs
    if out=$(realpath -m -- "$p" 2>/dev/null) && [ -n "$out" ]; then # swallow-ok: falls back to python3 below
        printf '%s' "${out%/}"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        if out=$(python3 -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null) && [ -n "$out" ]; then # swallow-ok: callers fail closed on rc 1
            printf '%s' "${out%/}"
            return 0
        fi
    fi
    return 1
}

is_under_dir() {
    local target="$1" root="$2"
    [ -n "$root" ] || return 1
    case "$target" in
        "$root"|"$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

command -v jq >/dev/null 2>&1 || deny "jq not on PATH — fail closed"

INPUT="$(cat)"
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || deny "malformed hook stdin JSON — fail closed"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLASSIFY="$SCRIPT_DIR/../guardrails/graphify-classify.sh"

# shellcheck disable=SC2016
META="$(printf '%s' "$INPUT" | jq -r '
    def s: if . == null then "" elif type == "string" then . else error("type") end;
    [
        ((.tool_name // .toolCall.name) | s),
        (.cwd | s),
        (.artifactDirectoryPath | s),
        ((.tool_input.file_path // .toolCall.args.Path) | s),
        ((.tool_input.command // .toolCall.args.CommandLine) | s),
        ((.tool_input.Uri // .toolCall.args.Uri) | s)
    ] as $v
    | @sh "TOOL_NAME=\($v[0]) AGENT_CWD=\($v[1]) PAYLOAD_ART=\($v[2]) FILE_PATH=\($v[3]) CMD_LINE=\($v[4]) RES_URI=\($v[5])"
' 2>/dev/null)" || deny "malformed tool metadata — fail closed"

TOOL_NAME="" AGENT_CWD="" PAYLOAD_ART="" FILE_PATH="" CMD_LINE="" RES_URI=""
eval "$META"
TOOL_NAME="${TOOL_NAME//$'\r'/}"
AGENT_CWD="${AGENT_CWD//$'\r'/}"
PAYLOAD_ART="${PAYLOAD_ART//$'\r'/}"
FILE_PATH="${FILE_PATH//$'\r'/}"
CMD_LINE="${CMD_LINE//$'\r'/}"
RES_URI="${RES_URI//$'\r'/}"

HOME_REAL=""
if [ -n "${HOME:-}" ]; then
    HOME_REAL="$(canon_path "$HOME")" || HOME_REAL="" # swallow-ok: literal path checks still run
fi

T3_HOME_1=""
[ -n "$HOME_REAL" ] && T3_HOME_1="$HOME_REAL/.t3"
T3_HOME_2=""
if [ -n "${T3CODE_HOME:-}" ]; then
    T3_HOME_2="$(canon_path "$T3CODE_HOME")" || T3_HOME_2="" # swallow-ok: falls back to T3_HOME_1 and literal checks
fi

TMPDIR_REAL=""
if [ -n "${TMPDIR:-}" ]; then
    TMPDIR_REAL="$(canon_path "$TMPDIR")" || TMPDIR_REAL="" # swallow-ok: /tmp allow check still runs
fi

RAW_ART="${HIMMEL_ANTIGRAVITY_ARTIFACT_DIR:-$PAYLOAD_ART}"
ARTIFACT_REAL=""
if [ -n "$RAW_ART" ]; then
    if _ar="$(canon_path "$RAW_ART")"; then
        case "$_ar" in
            */userdata/providers/antigravity/*/antigravity-acp/brain/*)
                ARTIFACT_REAL="$_ar"
                ;;
        esac
    fi
    unset _ar
fi

OWN_MCP_REAL=""
if [ -n "$ARTIFACT_REAL" ]; then
    _acp="${ARTIFACT_REAL%/brain/*}"
    _conv="${ARTIFACT_REAL#"$_acp/brain/"}"
    _home="${_acp%/antigravity-acp}"
    if [ "$_acp" = "$_home/antigravity-acp" ]; then
        case "$_conv" in
            ''|*/*) ;;
            *)
                for _t3h in "$T3_HOME_1" "$T3_HOME_2"; do
                    [ -n "$_t3h" ] || continue
                    _prov="$(canon_path "$_t3h/userdata/providers/antigravity")" || continue
                    [ "${_home%/*}" != "$_prov" ] || OWN_MCP_REAL="$_acp/mcp"
                done
                ;;
        esac
    fi
    unset _acp _conv _home _t3h _prov
fi

deny_own_mcp_symlink() {
    [ -n "$OWN_MCP_REAL" ] || return 0
    local rest="$1" cur="" part="" parent="" inside=0
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$part" in ''|.) continue ;; esac
        if [ "$inside" -eq 0 ] && [ "$part" = mcp ]; then
            parent="$(canon_path "${cur:-/}")" || deny "cannot canonicalize an mcp/ parent — fail closed"
            [ "$parent/mcp" != "$OWN_MCP_REAL" ] || inside=1
        fi
        cur="$cur/$part"
        if [ "$inside" -eq 1 ] && [ -L "$cur" ]; then
            deny "denies a symlink at or below the own mcp/ schema dir ($cur)"
        fi
    done
    return 0
}

is_own_mcp_schema_read() {
    local raw="$1" real="$2" rel=""
    case "$TOOL_NAME" in
        Read|read_file) ;;
        *) return 1 ;;
    esac
    [ -n "$raw" ] && [ -n "$OWN_MCP_REAL" ] || return 1
    case "$raw/" in */../*) return 1 ;; esac
    case "$real" in
        "$OWN_MCP_REAL"/*) rel="${real#"$OWN_MCP_REAL"/}" ;;
        *) return 1 ;;
    esac
    case "$rel" in
        */*/*) return 1 ;;
        ?*/?*.json) ;;
        *) return 1 ;;
    esac
    case "$raw" in
        */mcp/"$rel") ;;
        *) return 1 ;;
    esac
    [ "$(canon_path "${raw%/mcp/"$rel"}")/mcp" = "$OWN_MCP_REAL" ] && [ -f "$real" ]
}

check_forbidden_homes() {
    local real="$1" raw="${2:-}" real_lc=""
    real_lc="$(lower_str "$real")"

    case "$real_lc" in
        *antigravity-oauth-token*)
            deny "denies reading antigravity-oauth-token ($real)"
            ;;
    esac

    if [ -n "$HOME_REAL" ]; then
        local home_lc
        home_lc="$(lower_str "$HOME_REAL")"
        if is_under_dir "$real_lc" "$home_lc/.gemini/config" || [ "$real_lc" = "$home_lc/.gemini/settings.json" ]; then
            deny "denies reading ~/.gemini/config ($real)"
        fi
    fi

    case "$real_lc" in
        */.gemini/config|*/.gemini/config/*|*/.gemini/settings.json)
            deny "denies reading ~/.gemini/config ($real)"
            ;;
    esac

    is_own_mcp_schema_read "$raw" "$real" && return 0

    local art_lc="" t3h t3_lc
    [ -n "$ARTIFACT_REAL" ] && art_lc="$(lower_str "$ARTIFACT_REAL")"
    for t3h in "$T3_HOME_1" "$T3_HOME_2"; do
        [ -n "$t3h" ] || continue
        t3_lc="$(lower_str "$t3h")/userdata/providers/antigravity"
        if is_under_dir "$real_lc" "$t3_lc"; then
            if [ -n "$art_lc" ] && is_under_dir "$real_lc" "$art_lc"; then
                return 0
            fi
            deny "denies reading T3 Antigravity provider home outside artifactDirectoryPath ($real)"
        fi
    done

    case "$real_lc" in
        */userdata/providers/antigravity|*/userdata/providers/antigravity/*)
            if [ -n "$art_lc" ] && is_under_dir "$real_lc" "$art_lc"; then
                return 0
            fi
            deny "denies reading T3 Antigravity provider home outside artifactDirectoryPath ($real)"
            ;;
    esac

    return 0
}

check_read_path() {
    local raw="$1" full="$1" real="" real_lc=""
    [ -n "$raw" ] || deny "empty read path — fail closed"
    case "$raw" in
        /*) full="$raw" ;;
        \~/*)
            [ -n "${HOME:-}" ] || deny "cannot expand '~' without HOME — fail closed"
            full="$HOME/${raw#\~/}"
            ;;
        *)
            [ -n "$AGENT_CWD" ] || deny "relative path '$raw' with empty cwd — fail closed"
            full="$AGENT_CWD/$raw"
            ;;
    esac
    real="$(canon_path "$full")" || deny "cannot canonicalize path '$raw' — fail closed"

    deny_own_mcp_symlink "$full"
    check_forbidden_homes "$real" "$full"

    real_lc="$(lower_str "$real")"
    if is_under_dir "$real_lc" "/tmp" || is_under_dir "$real_lc" "/private/tmp"; then
        return 0
    fi
    if [ -n "$TMPDIR_REAL" ] && is_under_dir "$real_lc" "$(lower_str "$TMPDIR_REAL")"; then
        return 0
    fi
    local t3h
    for t3h in "$T3_HOME_1" "$T3_HOME_2"; do
        [ -n "$t3h" ] || continue
        if is_under_dir "$real_lc" "$(lower_str "$t3h")/userdata/antigravity-tmp"; then
            return 0
        fi
    done
    if [ -n "$ARTIFACT_REAL" ] && is_under_dir "$real_lc" "$(lower_str "$ARTIFACT_REAL")"; then
        return 0
    fi

    [ -f "$CLASSIFY" ] || deny "graphify-classify.sh missing at $CLASSIFY — fail closed"
    local cls="" crc=0
    cls="$(bash "$CLASSIFY" "$real" 2>/dev/null)" || crc=$? # swallow-ok: crc checked immediately below
    if [ "$crc" -ne 0 ]; then
        deny "graphify-classify failed (rc=$crc) for $real — fail closed"
    fi
    case "$cls" in
        ""|himmel-code|handover-state|luna-personal|luna-clippings|salus)
            return 0
            ;;
        *)
            deny "corpus '$cls' is not allowlisted for Antigravity reads ($real)"
            ;;
    esac
}

NORM_TEXT=""
normalize_cmd_paths() {
    local s="$1" prev="" guard=0
    local dotdot_mid='([^/[:space:];|&<>()=.][^/[:space:];|&<>()=]*|\.[^./[:space:];|&<>()=][^/[:space:];|&<>()=]*|\.\.[^/[:space:];|&<>()=]+)/\.\./'
    local dotdot_end='([^/[:space:];|&<>()=.][^/[:space:];|&<>()=]*|\.[^./[:space:];|&<>()=][^/[:space:];|&<>()=]*|\.\.[^/[:space:];|&<>()=]+)/\.\.([[:space:];|&<>()]|$)'
    while [ "$guard" -lt 32 ]; do
        prev="$s"
        while [[ "$s" == *"//"* ]]; do
            s="${s//\/\//\/}"
        done
        while [[ "$s" == *"/./"* ]]; do
            s="${s//\/.\//\/}"
        done
        if [[ "$s" =~ $dotdot_mid ]]; then
            s="${s/"${BASH_REMATCH[0]}"/}"
        elif [[ "$s" =~ $dotdot_end ]]; then
            s="${s/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[2]}"}"
        fi
        [ "$s" = "$prev" ] && break
        guard=$((guard + 1))
    done
    if [ "$guard" -ge 32 ]; then
        deny "excessive path normalization depth — fail closed"
    fi
    NORM_TEXT="$s"
}

check_read_text_one() {
    local text="$1"
    local cd_gemini_re='(^|[[:space:];|&])cd[[:space:]]+[^;|&]*\.gemini([/[:space:];|&]|$)'
    if [[ "$text" =~ $cd_gemini_re ]]; then
        deny "denies accessing ~/.gemini/config"
    fi

    case "$text" in
        *antigravity-oauth-token*)
            deny "denies accessing antigravity-oauth-token"
            ;;
        *.gemini/config*|*.gemini/settings.json*)
            deny "denies accessing ~/.gemini/config"
            ;;
        *providers/antigravity*)
            if [ -n "$ARTIFACT_REAL" ]; then
                local art_lc rest sep
                art_lc="$(lower_str "$ARTIFACT_REAL")"
                rest="${text//"$art_lc/"/__artifact_dir__/}"
                for sep in ' ' $'\t' ';' '|' '&' '<' '>' '(' ')'; do
                    rest="${rest//"$art_lc$sep"/__artifact_dir__$sep}"
                done
                case "$rest" in
                    *"$art_lc") rest="${rest%"$art_lc"}__artifact_dir__" ;;
                esac
                case "$rest" in
                    *providers/antigravity*)
                        deny "denies accessing T3 Antigravity provider home outside artifactDirectoryPath"
                        ;;
                esac
            else
                deny "denies accessing T3 Antigravity provider home outside artifactDirectoryPath"
            fi
            ;;
    esac
    return 0
}

check_read_text() {
    local raw_text="$1" stripped="" lc=""
    stripped="${raw_text//[\"\'\\]/}"
    lc="$(lower_str "$stripped")"
    check_read_text_one "$lc"
    normalize_cmd_paths "$lc"
    if [ "$NORM_TEXT" != "$lc" ]; then
        check_read_text_one "$NORM_TEXT"
    fi
    return 0
}

case "$TOOL_NAME" in
    Read|read_file)
        check_read_path "$FILE_PATH"
        exit 0
        ;;
    Bash|run_command)
        if [ -n "$AGENT_CWD" ]; then
            if _cwd_real="$(canon_path "$AGENT_CWD")"; then
                check_forbidden_homes "$_cwd_real"
            fi
            unset _cwd_real
        fi
        check_read_text "$CMD_LINE"
        exit 0
        ;;
    list_resources|read_resource)
        if [ -n "$RES_URI" ]; then
            case "$RES_URI" in
                file://*)
                    check_read_path "${RES_URI#file://}"
                    ;;
                /*|\~/*)
                    check_read_path "$RES_URI"
                    ;;
                *)
                    check_read_text "$RES_URI"
                    ;;
            esac
        fi
        if ! RAW_ARGS="$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolCall.args // {}')"; then
            deny "malformed resource args — fail closed"
        fi
        check_read_text "$RAW_ARGS"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
