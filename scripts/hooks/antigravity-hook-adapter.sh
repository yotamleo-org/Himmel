#!/usr/bin/env bash
# Clean PreToolUse pass MUST emit zero bytes on stdout + exit 0 (emitting `{}`
# fails closed as a deny in Antigravity's Go hook runner).
set -u

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

for _v in $(compgen -e); do
    case "$_v" in
        *_OK) unset "$_v" ;;
    esac
done
unset _v

emit_deny() {
    local r="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$r" '{decision:"deny",reason:$r}'
    else
        printf '{"decision":"deny","reason":"antigravity-hook-adapter: blocked fail-closed (jq unavailable)"}\n'
    fi
    exit 0
}

lower_str() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

canon_path() {
    local p="$1" out=""
    [ -n "$p" ] || return 1
    # prim-ok: fail-closed adapter canonicalizer must not source external libs
    if out=$(realpath -m -- "$p" 2>/dev/null) && [ -n "$out" ]; then # swallow-ok: GNU realpath -m probe falls back to python3 below
        printf '%s' "${out%/}"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        out=$(python3 -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null) && [ -n "$out" ] && { # swallow-ok: canon_path returns 1 on failure and callers fail closed
            printf '%s' "${out%/}"
            return 0
        }
    fi
    return 1
}

EVENT_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --event)
            [ $# -ge 2 ] || emit_deny "antigravity-hook-adapter: --event requires a value"
            EVENT_ARG="$2"
            shift 2
            ;;
        *)
            emit_deny "antigravity-hook-adapter: unknown argument '$1' — fail closed"
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

resolve_primary_root() {
    local base="$1" common="" root=""
    if [ -n "${HIMMEL_ANTIGRAVITY_PROJECT_DIR:-}" ] && [ -d "${HIMMEL_ANTIGRAVITY_PROJECT_DIR}" ]; then
        (cd -P "$HIMMEL_ANTIGRAVITY_PROJECT_DIR" 2>/dev/null && pwd -P)
        return 0
    fi
    if command -v git >/dev/null 2>&1; then
        common="$(git -C "$base" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common="" # swallow-ok: non-git fallback resolves relative to script dir below
        if [ -n "$common" ] && [ -d "$common" ]; then
            root="$(dirname "$common")"
            if [ -f "$root/scripts/hooks/antigravity-hook-adapter.sh" ]; then
                printf '%s' "$root"
                return 0
            fi
        fi
    fi
    (cd -P "$base/../.." 2>/dev/null && pwd -P)
}

PRIMARY_ROOT="$(resolve_primary_root "$SCRIPT_DIR")"
[ -n "$PRIMARY_ROOT" ] && [ -d "$PRIMARY_ROOT/scripts/hooks" ] || {
    if [ "$EVENT_ARG" = "SessionStart" ] || [ "$EVENT_ARG" = "PostToolUse" ] || [ "$EVENT_ARG" = "Stop" ]; then
        exit 0
    fi
    emit_deny "antigravity-hook-adapter: cannot resolve primary checkout scripts/hooks — fail closed"
}
export CLAUDE_PROJECT_DIR="$PRIMARY_ROOT"

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
    case "$EVENT_ARG" in
        SessionStart|PostToolUse|Stop) exit 0 ;;
        *) emit_deny "antigravity-hook-adapter: jq not on PATH — fail closed" ;;
    esac
fi

if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    case "$EVENT_ARG" in
        SessionStart|PostToolUse|Stop) exit 0 ;;
        *) emit_deny "antigravity-hook-adapter: malformed hook stdin JSON — fail closed" ;;
    esac
fi

HOOK_EVENT="$EVENT_ARG"
if [ -z "$HOOK_EVENT" ]; then
    HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hookEventName // empty')" || emit_deny "antigravity-hook-adapter: failed to parse hookEventName — fail closed"
fi
[ -n "$HOOK_EVENT" ] || emit_deny "antigravity-hook-adapter: missing hookEventName — fail closed"

run_node_launcher() {
    local launcher="$PRIMARY_ROOT/scripts/hooks/run-hook-with-bash.js"
    local run_node="$PRIMARY_ROOT/scripts/lib/run-node.sh"
    [ -f "$launcher" ] && [ -r "$launcher" ] || return 127
    if [ -f "$run_node" ] && [ -r "$run_node" ]; then
        command -p sh "$run_node" "$launcher" "$@"
        return $?
    fi
    command -v node >/dev/null 2>&1 || return 127
    node "$launcher" "$@"
}

run_chain_with_payload() {
    local mode="$1" payload="$2"
    shift 2
    local g abs=""
    local -a paths=()
    for g in "$@"; do
        abs="$PRIMARY_ROOT/scripts/hooks/$g"
        if [ ! -f "$abs" ]; then
            if [ "$mode" = "gate" ]; then
                emit_deny "antigravity-hook-adapter: guardrail '$g' missing at $abs — fail closed"
            fi
            return 0
        fi
        paths+=("$abs")
    done
    [ "${#paths[@]}" -gt 0 ] || {
        [ "$mode" = "gate" ] && emit_deny "antigravity-hook-adapter: empty guardrail chain — fail closed"
        return 0
    }

    local captured="" code="" out=""
    if [ "$mode" = "lifecycle" ]; then
        captured="$( { printf '%s' "$payload" | run_node_launcher --chain --lifecycle "${paths[@]}" 2>&1; printf 'EXIT:%s' "${PIPESTATUS[1]}"; } )"
        out="${captured%EXIT:*}"
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return 0
    fi

    captured="$( { printf '%s' "$payload" | run_node_launcher --chain "${paths[@]}" 2>&1; printf 'EXIT:%s' "${PIPESTATUS[1]}"; } )"
    code="${captured##*EXIT:}"
    out="${captured%EXIT:*}"
    out="${out%$'\n'}"; out="${out%$'\r'}"

    if [ "$mode" = "post" ]; then
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return 0
    fi

    local is_deny=0
    if [ "$code" != "0" ]; then
        is_deny=1
    elif printf '%s' "$out" | grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"decision"[[:space:]]*:[[:space:]]*"block"'; then
        is_deny=1
    fi

    if [ "$is_deny" -eq 1 ]; then
        [ -n "$out" ] || out="antigravity-hook-adapter: guardrail chain failed closed (rc=$code)"
        emit_deny "$out"
    fi

    [ -n "$out" ] && printf '%s\n' "$out" >&2
    return 0
}

case "$HOOK_EVENT" in
    Stop)
        exit 0
        ;;
    SessionStart)
        # shellcheck disable=SC2016
        SS_PAYLOAD="$(printf '%s' "$INPUT" | jq -cn '
            input as $in | {
                hook_event_name: "SessionStart",
                session_id: ($in.conversationId // ""),
                cwd: ($in.cwd // ""),
                transcript_path: ($in.transcriptPath // ""),
                source: "startup"
            }')" || exit 0
        run_chain_with_payload lifecycle "$SS_PAYLOAD" \
            record-hook-integrity.sh \
            record-primary-baseline.sh \
            peer-taint-resume.sh \
            check-update-available.sh
        exit 0
        ;;
    PostToolUse)
        POST_TOOL="$(printf '%s' "$INPUT" | jq -r '.toolCall.name // empty')" || POST_TOOL="" # swallow-ok: advisory PostToolUse hook exits 0 on missing tool name
        if [ "$POST_TOOL" = "run_command" ]; then
            # shellcheck disable=SC2016
            POST_PAYLOAD="$(printf '%s' "$INPUT" | jq -cn '
                input as $in | {
                    hook_event_name: "PostToolUse",
                    session_id: ($in.conversationId // ""),
                    tool_use_id: ($in.toolCall.id // ""),
                    tool_name: "Bash",
                    tool_input: {command: ($in.toolCall.args.CommandLine // "")},
                    cwd: ($in.cwd // ""),
                    transcript_path: ($in.transcriptPath // "")
                }')" || exit 0
            run_chain_with_payload post "$POST_PAYLOAD" detect-dirty-primary.sh
        fi
        printf '{}\n'
        exit 0
        ;;
    PreToolUse)
        ;;
    *)
        emit_deny "antigravity-hook-adapter: unsupported hookEventName '$HOOK_EVENT' — fail closed"
        ;;
esac

# shellcheck disable=SC2016
META="$(printf '%s' "$INPUT" | jq -r '
    def s: if . == null then "" elif type == "string" then . else error("type") end;
    (.toolCall // error("missing toolCall")) as $tc
    | ($tc.name | select(type == "string" and length > 0)) as $name
    | [(.cwd | s), (.artifactDirectoryPath | s), $name] as $v
    | @sh "AGENT_CWD=\($v[0]) ARTIFACT_DIR=\($v[1]) RAW_TOOL=\($v[2])"
' 2>/dev/null)" || emit_deny "antigravity-hook-adapter: missing or malformed toolCall metadata — fail closed"

AGENT_CWD="" ARTIFACT_DIR="" RAW_TOOL=""
eval "$META"

HOME_REAL=""
if [ -n "${HOME:-}" ]; then
    HOME_REAL="$(canon_path "$HOME")" || HOME_REAL="" # swallow-ok: empty HOME_REAL skips optional home-dir match while .agents and literal rules still run
fi
T3_HOME_1=""
[ -n "$HOME_REAL" ] && { T3_HOME_1="$(canon_path "$HOME_REAL/.t3")" || T3_HOME_1=""; }
T3_HOME_2=""
if [ -n "${T3CODE_HOME:-}" ]; then
    T3_HOME_2="$(canon_path "$T3CODE_HOME")" || T3_HOME_2="" # swallow-ok: empty T3_HOME_2 falls back to T3_HOME_1 and literal checks
fi

place_artifact() {
    ARTIFACT_REAL="" ARTIFACT_HEX=""
    local raw="${ARTIFACT_DIR%/}" mark="/userdata/providers/antigravity/"
    local pfx="" rest="" hex="" tail="" pfx_real="" home_real="" t3h="" matched="" p="" real=""
    case "$raw" in
        /*) ;;
        *) return 0 ;;
    esac
    case "$raw/" in
        *//*|*/./*|*/../*) return 0 ;;
    esac
    case "$raw" in
        *"$mark"*) ;;
        *) return 0 ;;
    esac
    rest="${raw##*"$mark"}"
    pfx="${raw%"$mark"*}${mark%/}"
    hex="${rest%%/*}"
    tail="${rest#"$hex"}"
    case "$hex" in
        *[!0-9a-f]*) return 0 ;;
    esac
    [ "${#hex}" -eq 64 ] || return 0
    case "$tail" in
        /antigravity-acp/brain/?*) ;;
        *) return 0 ;;
    esac
    pfx_real="$(canon_path "$pfx")" || return 0
    for t3h in "$T3_HOME_1" "$T3_HOME_2"; do
        [ -n "$t3h" ] || continue
        home_real="$(canon_path "$t3h/userdata/providers/antigravity")" || continue
        [ "$pfx_real" != "$home_real" ] || matched=1
    done
    [ -n "$matched" ] || return 0
    p="$raw"
    while [ "$p" != "$pfx" ]; do
        [ ! -L "$p" ] || return 0
        p="${p%/*}"
    done
    real="$(canon_path "$raw")" || return 0
    case "$real" in
        "$pfx_real/$hex/antigravity-acp/brain/"*)
            ARTIFACT_REAL="$real"
            ARTIFACT_HEX="$hex"
            ;;
    esac
    return 0
}
place_artifact
export HIMMEL_ANTIGRAVITY_ARTIFACT_DIR="$ARTIFACT_REAL"

is_under_dir() {
    local target="$1" root="$2"
    [ -n "$root" ] || return 1
    case "$target" in
        "$root"|"$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

check_self_protect_path() {
    local raw="$1" full="$1" real="" real_lc=""
    [ -n "$raw" ] || emit_deny "antigravity-hook-adapter: empty file path — fail closed"
    case "$raw" in
        /*) full="$raw" ;;
        \~/*) full="${HOME:-}/""${raw#\~/}" ;;
        *)
            [ -n "$AGENT_CWD" ] || emit_deny "antigravity-hook-adapter: relative path '$raw' with empty cwd — fail closed"
            full="$AGENT_CWD/$raw"
            ;;
    esac
    real="$(canon_path "$full")" || emit_deny "antigravity-hook-adapter: cannot canonicalize path '$raw' — fail closed"
    real_lc="$(lower_str "$real")"

    case "$real_lc" in
        */.agents|*/.agents/*)
            emit_deny "antigravity-hook-adapter: self-protect denies modifying .agents/** ($real)"
            ;;
    esac

    if [ -n "$HOME_REAL" ]; then
        local home_lc
        home_lc="$(lower_str "$HOME_REAL")"
        if is_under_dir "$real_lc" "$home_lc/.gemini/config" || [ "$real_lc" = "$home_lc/.gemini/settings.json" ]; then
            emit_deny "antigravity-hook-adapter: self-protect denies modifying ~/.gemini/config ($real)"
        fi
    fi

    local t3h t3_lc art_lc=""
    [ -n "$ARTIFACT_REAL" ] && art_lc="$(lower_str "$ARTIFACT_REAL")"
    for t3h in "$T3_HOME_1" "$T3_HOME_2"; do
        [ -n "$t3h" ] || continue
        t3_lc="$(lower_str "$t3h")/userdata/providers/antigravity"
        if is_under_dir "$real_lc" "$t3_lc"; then
            if [ -n "$art_lc" ] && is_under_dir "$real_lc" "$art_lc"; then
                return 0
            fi
            emit_deny "antigravity-hook-adapter: self-protect denies modifying T3 Antigravity provider home outside artifactDirectoryPath ($real)"
        fi
    done
    return 0
}

check_self_protect_cmd() {
    local cmd="$1" c="" raw_c=""
    raw_c="${cmd//[\"\'\\]/}"
    c="$(lower_str "$raw_c")"

    case "$c" in
        *antigravity-oauth-token*)
            emit_deny "antigravity-hook-adapter: self-protect denies accessing antigravity-oauth-token"
            ;;
    esac

    local mentions_protected=0
    case "$c" in
        *.agents*|*.gemini*)
            mentions_protected=1
            ;;
        *userdata/providers/antigravity*)
            if [ -n "$ARTIFACT_REAL" ]; then
                local art_lc stripped
                art_lc="$(lower_str "$ARTIFACT_REAL")"
                stripped="${c//"$art_lc"/__artifact_dir__}"
                case "$stripped" in
                    *userdata/providers/antigravity*) mentions_protected=1 ;;
                esac
            else
                mentions_protected=1
            fi
            ;;
    esac

    if [ "$mentions_protected" -eq 1 ]; then
        emit_deny "antigravity-hook-adapter: self-protect denies run_command referencing .agents/**, ~/.gemini/config, or T3 Antigravity home (use read_file to inspect)"
    fi

    local toks tk
    toks="${raw_c//[;&|<>=()]/ }"
    toks="${toks//\`/ }"
    set -f
    for tk in $toks; do
        case "$tk" in
            \~|\$HOME|\$\{HOME\}) continue ;;
            \$HOME/*) tk="${HOME:-}/${tk#\$HOME/}" ;;
            \$\{HOME\}/*) tk="${HOME:-}/${tk#\$\{HOME\}/}" ;;
            \~/*|/*) ;;
            *) [ -n "$AGENT_CWD" ] || continue ;;
        esac
        check_self_protect_path "$tk"
    done
    set +f
    return 0
}

build_claude_payload() {
    local mapped_tool="$1" mode="$2"
    # shellcheck disable=SC2016
    printf '%s' "$INPUT" | jq -cn --arg mt "$mapped_tool" --arg mode "$mode" '
        input as $in
        | ($in.toolCall.args // {}) as $a
        | (if $mode == "bash" then {command: ($a.CommandLine // "")}
           elif $mode == "file" then {file_path: ($a.Path // "")}
           elif $mode == "lazy" then ($a.Arguments // {})
           else $a end) as $ti
        | {
            hook_event_name: "PreToolUse",
            session_id: ($in.conversationId // ""),
            tool_use_id: ($in.toolCall.id // ""),
            tool_name: $mt,
            tool_input: $ti,
            cwd: ($in.cwd // ""),
            transcript_path: ($in.transcriptPath // "")
          }'
}

mcp_allowed_set() {
    LANE_SET="" DECLARED_SET="" SESSION_PROFILE=""
    local doc="" lane="" declared="" profiles="" prof="" p="" sum=""
    doc="$(cat "$PRIMARY_ROOT/scripts/t3/antigravity-profiles.json")" || return 1
    printf '%s' "$doc" | jq -se '
        def server_name: type == "string" and test("\\A[A-Za-z0-9.-]+\\z");
        length == 1 and (.[0]
            | (.profiles | type == "object")
              and (.laneMcpServers | type == "array" and all(.[]; server_name))
              and all(.profiles | to_entries[];
                  (.key | test("\\A[A-Za-z0-9._-]+\\z"))
                  and (.value
                      | (if has("mcpServers") then (.mcpServers | type == "object" and all(.[]; type == "object")) else true end)
                        and (if has("optionalMcpServers") then (.optionalMcpServers | type == "array" and all(.[]; type == "string")) else true end))))
    ' >/dev/null 2>&1 || return 1
    lane="$(printf '%s' "$doc" | jq -r '.laneMcpServers | join(" ")')" || return 1
    if [ -n "$ARTIFACT_HEX" ]; then
        profiles="$(printf '%s' "$doc" | jq -r '.profiles | keys[]')" || return 1
        for p in $profiles; do
            sum=""
            if command -v sha256sum >/dev/null 2>&1; then
                sum="$(printf '%s' "antigravity_$p" | sha256sum)"
            elif command -v shasum >/dev/null 2>&1; then
                sum="$(printf '%s' "antigravity_$p" | shasum -a 256)"
            fi
            if [ "${sum%% *}" = "$ARTIFACT_HEX" ]; then
                prof="$p"
                break
            fi
        done
    fi
    if [ -n "$prof" ]; then
        declared="$(printf '%s' "$doc" | jq -r --arg p "$prof" '
            .profiles[$p]
            | [((.mcpServers // {}) | keys[]), ((.optionalMcpServers // [])[])]
            | map(select(test("\\A[A-Za-z0-9.-]+\\z"))) | join(" ")')" || return 1
    fi
    LANE_SET="$lane" DECLARED_SET="$declared" SESSION_PROFILE="$prof"
}

run_mcp_gate() {
    local srv="$1" tool="$2" mode="$3" payload=""
    local -a chain=(mcp-policy.sh block-backend-tier.sh)
    [ -n "$srv" ] && [ -n "$tool" ] || emit_deny "antigravity-hook-adapter: malformed MCP tool name '$RAW_TOOL' — fail closed"
    case "$srv" in
        *[!A-Za-z0-9.-]*)
            emit_deny "antigravity-hook-adapter: invalid MCP server key '$srv' — fail closed"
            ;;
    esac
    case "$tool" in
        *[!A-Za-z0-9_.-]*)
            emit_deny "antigravity-hook-adapter: invalid MCP tool name '$tool' — fail closed"
            ;;
    esac
    mcp_allowed_set || emit_deny "antigravity-hook-adapter: cannot read laneMcpServers and profiles from $PRIMARY_ROOT/scripts/t3/antigravity-profiles.json — fail closed"
    case " $LANE_SET " in
        *" $srv "*) ;;
        *)
            case " $DECLARED_SET " in
                *" $srv "*) ;;
                *)
                    emit_deny "antigravity-hook-adapter: MCP server '$srv' is not allowlisted on the Antigravity lane: it is not in laneMcpServers and profile '${SESSION_PROFILE:-none}' does not declare it in scripts/t3/antigravity-profiles.json"
                    ;;
            esac
            local class=""
            class="$(jq -r --arg s "$srv" --arg t "$tool" \
                '.servers[$s] | select(type == "object" and .verdict == "allow") | .tools[$t] // empty' \
                "$PRIMARY_ROOT/scripts/guardrails/mcp-policy.json")" || class=""
            case "$class" in
                read|write) ;;
                *)
                    emit_deny "antigravity-hook-adapter: $srv '$tool' is not a read or write tool in mcp-policy.json and is denied on the Antigravity lane"
                    ;;
            esac
            ;;
    esac
    payload="$(build_claude_payload "mcp__${srv}__${tool}" "$mode")" || emit_deny "antigravity-hook-adapter: failed to translate MCP payload"
    if [ "$srv" = "t3-code" ]; then
        chain+=(guard-t3-thread-tools.sh)
        [ "$tool" != "unwatch_pull_request" ] || chain+=(block-t3code-unwatch-open-pr.sh)
    fi
    run_chain_with_payload gate "$payload" "${chain[@]}" peer-taint-gate.sh
}

case "$RAW_TOOL" in
    schedule)
        emit_deny "antigravity-hook-adapter: 'schedule' is denied on the Antigravity lane (unattended scheduling is disallowed)"
        ;;
    swarm|run_workflow)
        emit_deny "antigravity-hook-adapter: '$RAW_TOOL' is denied on the Antigravity lane (parallel writers violate single-writer invariant)"
        ;;
    define_subagent|manage_subagents)
        emit_deny "antigravity-hook-adapter: '$RAW_TOOL' is denied on the Antigravity lane (mutating the subagent registry is disallowed)"
        ;;
    manage_task)
        emit_deny "antigravity-hook-adapter: 'manage_task' is denied on the Antigravity lane"
        ;;
    run_command)
        CMD_LINE="$(printf '%s' "$INPUT" | jq -r '.toolCall.args.CommandLine // empty')" || emit_deny "antigravity-hook-adapter: failed to parse CommandLine — fail closed"
        check_self_protect_cmd "$CMD_LINE"
        PAYLOAD="$(build_claude_payload Bash bash)" || emit_deny "antigravity-hook-adapter: failed to translate run_command payload"
        run_chain_with_payload gate "$PAYLOAD" \
            guard-identical-denied-retry.sh \
            guard-merge-compound.sh \
            block-jira-compound-write.sh \
            block-tail-pipe-on-gates.sh \
            block-antigravity-read-fence.sh \
            block-read-secrets.sh \
            block-graphify-egress.sh \
            read-clamp.sh \
            block-destructive-commands.sh \
            block-git-stash.sh \
            block-bare-qmd-query.sh \
            block-rogue-claude-schedule.sh \
            block-chokepoint-env-prefix.sh \
            require-quiet-run.sh \
            block-edit-live-settings.sh \
            block-write-into-main-checkout.sh \
            block-docker-privesc.sh \
            block-infra-destroy.sh \
            block-merged-pr-commit.sh \
            block-rogue-codex-exec.sh \
            block-terminal-write-fence.sh \
            block-lesson-enforcement-writes.sh \
            block-bank-lift-writes.sh \
            block-himmel-config-writes.sh \
            guard-bus-store.sh \
            guard-pr-check-literal.sh \
            peer-taint-gate.sh
        exit 0
        ;;
    read_file)
        READ_PATH="$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // empty')" || emit_deny "antigravity-hook-adapter: failed to parse read_file Path — fail closed"
        [ -n "$READ_PATH" ] || emit_deny "antigravity-hook-adapter: empty read_file Path — fail closed"
        case "$(lower_str "$READ_PATH")" in
            *antigravity-oauth-token*)
                emit_deny "antigravity-hook-adapter: self-protect denies reading antigravity-oauth-token"
                ;;
        esac
        PAYLOAD="$(build_claude_payload Read file)" || emit_deny "antigravity-hook-adapter: failed to translate read_file payload"
        run_chain_with_payload gate "$PAYLOAD" \
            block-antigravity-read-fence.sh \
            block-read-secrets.sh \
            read-clamp.sh \
            peer-taint-gate.sh
        exit 0
        ;;
    edit_file)
        EDIT_PATH="$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // empty')" || emit_deny "antigravity-hook-adapter: failed to parse edit_file Path — fail closed"
        check_self_protect_path "$EDIT_PATH"
        PAYLOAD="$(build_claude_payload Edit file)" || emit_deny "antigravity-hook-adapter: failed to translate edit_file payload"
        run_chain_with_payload gate "$PAYLOAD" \
            block-edit-on-main.sh \
            block-edit-live-settings.sh \
            block-lesson-enforcement-writes.sh \
            block-bank-lift-writes.sh \
            block-himmel-config-writes.sh \
            guard-bus-store.sh \
            peer-taint-gate.sh
        exit 0
        ;;
    write_file)
        WRITE_PATH="$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // empty')" || emit_deny "antigravity-hook-adapter: failed to parse write_file Path — fail closed"
        check_self_protect_path "$WRITE_PATH"
        PAYLOAD="$(build_claude_payload Write file)" || emit_deny "antigravity-hook-adapter: failed to translate write_file payload"
        run_chain_with_payload gate "$PAYLOAD" \
            block-edit-on-main.sh \
            block-edit-live-settings.sh \
            block-lesson-enforcement-writes.sh \
            block-bank-lift-writes.sh \
            block-himmel-config-writes.sh \
            guard-bus-store.sh \
            peer-taint-gate.sh
        exit 0
        ;;
    invoke_subagent)
        PAYLOAD="$(build_claude_payload Agent raw)" || emit_deny "antigravity-hook-adapter: failed to translate invoke_subagent payload"
        run_chain_with_payload gate "$PAYLOAD" peer-taint-gate.sh
        exit 0
        ;;
    list_resources|read_resource)
        PAYLOAD="$(build_claude_payload "$RAW_TOOL" raw)" || emit_deny "antigravity-hook-adapter: failed to translate $RAW_TOOL payload"
        run_chain_with_payload gate "$PAYLOAD" \
            block-antigravity-read-fence.sh \
            peer-taint-gate.sh
        exit 0
        ;;
    search_web|send_message|ask_question|exit_plan_mode|update_steps)
        PAYLOAD="$(build_claude_payload "$RAW_TOOL" raw)" || emit_deny "antigravity-hook-adapter: failed to translate $RAW_TOOL payload"
        run_chain_with_payload gate "$PAYLOAD" peer-taint-gate.sh
        exit 0
        ;;
    mcp_*)
        REST="${RAW_TOOL#mcp_}"
        case "$REST" in
            *_*) run_mcp_gate "${REST%%_*}" "${REST#*_}" raw ;;
            *)
                emit_deny "antigravity-hook-adapter: malformed MCP tool name '$RAW_TOOL' — fail closed"
                ;;
        esac
        exit 0
        ;;
    call_mcp_tool)
        # shellcheck disable=SC2016
        LAZY_META="$(printf '%s' "$INPUT" | jq -r '
            .toolCall.args as $a
            | if ($a | type) == "object"
                and ($a | keys - ["ServerName", "ToolName", "Arguments", "toolSummary"] == [])
                and (($a | has("toolSummary") | not) or ($a.toolSummary | type == "string"))
                and ($a.ServerName | type == "string" and test("\\A[ -~]+\\z"))
                and ($a.ToolName | type == "string" and test("\\A[A-Za-z0-9_.-]+\\z") and (contains("__") | not))
                and ($a.Arguments | type == "object" or type == "null")
              then @sh "LAZY_SRV=\($a.ServerName) LAZY_TOOL=\($a.ToolName)"
              else error("shape") end
        ' 2>/dev/null)" || emit_deny "antigravity-hook-adapter: malformed call_mcp_tool args (want string ServerName and ToolName, object Arguments) — fail closed"
        LAZY_SRV="" LAZY_TOOL=""
        eval "$LAZY_META"
        run_mcp_gate "$LAZY_SRV" "$LAZY_TOOL" lazy
        exit 0
        ;;
    *)
        emit_deny "antigravity-hook-adapter: unrecognized tool '$RAW_TOOL' — fail closed"
        ;;
esac
