#!/usr/bin/env bash
# launch-guard-ok-file: folder checked by launch-guard-check.sh in headed-arm-worker.sh
# scripts/lanes/worker-claude-launcher.sh - the `claude` stand-in that applies a
# worker's plugin profile.
#
# WHY THIS EXISTS AT ALL. headed-arm.sh builds ONE fixed argv:
#
#     LAUNCH_ARGV=("$LAUNCHER" --model "$MODEL" --autocompact "$AUTOCOMPACT" \
#                  -n "$NAME" "load $DOC and continue")
#
# There is no pass-through for extra `claude` flags - only HEADED_ARM_LAUNCHER
# (which binary to exec) and HEADED_ARM_LAUNCHER_ENV (env tokens). A profile
# needs two real CLI flags, so the flags have to come from the binary side of
# that seam. That is exactly the shape scripts/claude-codex already proves on
# the claudex lane, so headed-arm.sh stays untouched (chief ruling, N159).
#
# CONTRACT (all four clauses are load-bearing; a suite case pins each):
#  1. PREPEND ONLY. We add flags in FRONT of "$@" and never reorder, drop or
#     rewrite anything headed-arm.sh built - `--model`, `--autocompact`, `-n
#     <name>` and the prompt reach claude in their original order. That keeps
#     headed-arm.sh's own resolved-argv guard, its `_argv_has_n_name`
#     positional walk and its `[c]laude .*-n <name>` pgrep confirm all valid
#     after the exec below.
#  2. FAIL CLOSED on a missing file. If a profile was requested but its
#     settings or preface file is gone, we refuse rather than launch. A worker
#     that silently runs full-fat is undetectable from the outside and
#     corrupts the very measurement this ticket exists to make.
#  3. NO PROFILE, NO CHANGE. With neither variable set this is a transparent
#     `exec claude "$@"` - byte-identical argv to today, except that a Haiku
#     `--model` gets `--disallowedTools Agent` in front (a Haiku session is
#     a leaf). Every launch also exports the subagent caps
#     (scripts/lib/subagent-caps.sh); env only, no argv change.
#  4. It never widens anything. `--settings` here can only DISABLE plugins
#     (the resolver emits a complete enabledPlugins map, deny-by-default), and
#     `--mcp-config`/`--strict-mcp-config` can only NARROW the
#     MCP servers available to the worker (the config file is a copy of real
#     definitions the resolver read elsewhere, never a hand-written one) -
#     neither ever adds a tool, permission or MCP server beyond what the
#     worker's own plugin set already carries.
#
# Env (set by headed-arm-worker.sh --profile, exported so it survives konsole's
# `-e env -u ...` line, which only unsets the session-identity vars):
#   WORKER_SESSION_PROFILE_SETTINGS   path to the resolved settings JSON  -> --settings
#   WORKER_SESSION_PROFILE_PREFACE    path to docs/handover/worker-preface.md
#                                                   -> --append-system-prompt-file
#   WORKER_SESSION_PROFILE_MCP_CONFIG path to the resolved MCP-server
#                           allowlist JSON, set only when the profile declares
#                           one -> --mcp-config <file> --strict-mcp-config.
#                           --strict-mcp-config makes that file the ONLY
#                           source of MCP servers for this launch - it strips
#                           plugin-bundled servers too, not just the
#                           ~/.claude.json user-level ones this exists to cut,
#                           which is exactly why the file is never hand-typed
#                           (see plugin-profiles.mjs's collectMcpServerDefs).
#   WORKER_SESSION_PROFILE_NO_SETTING_SOURCES exactly 1 -> --setting-sources ""
#                           (an empty list: no user, project or local settings
#                           scope loads, only --settings and managed policy).
#                           Set only by headed-arm-worker.sh --consult, whose
#                           sandbox those scopes' write roots would widen. It
#                           only ever loads LESS (clause 4).
#   WORKER_SESSION_REMOTE_CONTROL    a session name -> --remote-control <name>
#                           Set only on a native-lane launch; the
#                           claudex proxy endpoint makes that lane ineligible.
#   WORKER_SESSION_PROFILE_READINESS exactly 1 -> the READINESS role. The final argv for
#                           that role is built HERE and nowhere else, and the real exec and the
#                           validation-only render below are the same construction:
#                             --settings S [--append-system-prompt-file P] --mcp-config M
#                             --strict-mcp-config --tools "" [--permission-mode auto]
#                             --allowedTools mcp__readiness__inspect mcp__readiness__act
#                             --session-id ID <the caller's argv, untouched and in order>
#                           It is a finite protocol check, not a reading of prose: the lane and binary
#                           must be supported, no other role marker may be set, the settings must allow
#                           exactly the two grants and deny the native tools, the MCP config must name
#                           exactly the readiness server, a session id must be minted, and the caller's
#                           argv may not name any availability/settings/mode override (it may carry ONE
#                           `--permission-mode auto`, which is kept in place; otherwise one is added).
#                           Every other case refuses with exit 2 BEFORE anything runs. Each variadic
#                           option (--mcp-config, --tools, --allowedTools) is followed by a flag, so a
#                           caller's bare prompt can never be read as one more value.
#   WORKER_SESSION_RENDER_ARGV       exactly 1, readiness only -> print that final argv (binary first)
#                           NUL-terminated on stdout, exec nothing, run no native binary. headed-arm-worker
#                           calls it before acquiring the readiness lease (it prints nothing it must keep).
#                           The --session-id above is bound to the trusted private startup config: the MCP server
#                           must be `<readiness-tools.mjs> --startup-config <startup.json>`, and that private
#                           mode-0600 file (in a mode-0700 directory) must hold WORKER_SESSION_ID as its session scope.
# Seam: WORKER_SESSION_CLAUDE_BIN overrides the `claude` binary this execs (default:
# `claude` from PATH). headed-arm-worker.sh sets it to scripts/claude-codex on
# the claudex lane so all profile flags reach that backend;
# suites can point it at a recording stub.
#
# Platform: POSIX bash 3.2+ (macOS ships 3.2) - hence the
# ${PRE[@]+"${PRE[@]}"} empty-array expansion, which 3.2 needs under `set -u`.
#
# Platform guard: its only caller is headed-arm.sh via
# HEADED_ARM_LAUNCHER, and that script is Linux/KDE-only (konsole).
set -u

CLAUDE_BIN="${WORKER_SESSION_CLAUDE_BIN:-claude}"
WORKER_SESSION_PROFILE_SETTINGS="${WORKER_SESSION_PROFILE_SETTINGS:-}"
WORKER_SESSION_PROFILE_PREFACE="${WORKER_SESSION_PROFILE_PREFACE:-}"
WORKER_SESSION_PROFILE_MCP_CONFIG="${WORKER_SESSION_PROFILE_MCP_CONFIG:-}"
WORKER_SESSION_PROFILE_NO_SETTING_SOURCES="${WORKER_SESSION_PROFILE_NO_SETTING_SOURCES:-}"
WORKER_SESSION_PROFILE_READINESS="${WORKER_SESSION_PROFILE_READINESS:-}"
WORKER_SESSION_RENDER_ARGV="${WORKER_SESSION_RENDER_ARGV:-}"

# --- READINESS role: validate everything the final argv depends on before any of it is built. ---
# With neither variable set none of this runs and the launcher is the byte-identical pass-through below.
_ready_refuse() {
    echo "worker-claude-launcher: refusing to launch the readiness role: $*" >&2
    exit 2
}
_readiness=0
_render=0
_caller_modes=0
case "$WORKER_SESSION_RENDER_ARGV" in
    '') ;;
    1) _render=1 ;;
    *) _ready_refuse "WORKER_SESSION_RENDER_ARGV must be exactly 1 or unset" ;;
esac
case "$WORKER_SESSION_PROFILE_READINESS" in
    '') ;;
    1) _readiness=1 ;;
    *) _ready_refuse "WORKER_SESSION_PROFILE_READINESS must be exactly 1 or unset (a restriction marker is never half-on)" ;;
esac
[ "$_render" = 0 ] || [ "$_readiness" = 1 ] || _ready_refuse "the validation-only render is readiness-only (WORKER_SESSION_PROFILE_READINESS=1 is not set)"

if [ "$_readiness" = 1 ]; then
    # Supported lane: native only (the isolation of every other lane's tool surface is unproved).
    case "${WORKER_SESSION_LANE:-native}" in
        native) ;;
        *) _ready_refuse "unsupported lane '${WORKER_SESSION_LANE}': native only" ;;
    esac
    # Supported binary: the plain `claude` on PATH, or an absolute executable (the suites' recording seam and
    # the VM wrapper). A lane launcher (claude-codex, claude-openrouter, ...) is never accepted.
    case "${CLAUDE_BIN##*/}" in
        claude-*) _ready_refuse "the lane launcher ${CLAUDE_BIN##*/} is not a supported binary" ;;
    esac
    case "$CLAUDE_BIN" in
        claude) command -v claude >/dev/null 2>&1 || _ready_refuse "no claude on PATH" ;;
        /*) { [ -f "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; } || _ready_refuse "the binary $CLAUDE_BIN is not an executable file" ;;
        *) _ready_refuse "the binary must be 'claude' or an absolute path (got '$CLAUDE_BIN')" ;;
    esac
    # No mixed roles: any other role's marker in this launch refuses it.
    for _role_marker in "HIMMEL_CONSOLE_JUDGE=${HIMMEL_CONSOLE_JUDGE:-}" "HIMMEL_CONSOLE_RELAY=${HIMMEL_CONSOLE_RELAY:-}" \
        "HIMMEL_RELEASE_MANAGER=${HIMMEL_RELEASE_MANAGER:-}" "CHIEF_CONTEXT=${CHIEF_CONTEXT:-}" \
        "WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=${WORKER_SESSION_PROFILE_NO_SETTING_SOURCES:-}" \
        "WORKER_SESSION_REMOTE_CONTROL=${WORKER_SESSION_REMOTE_CONTROL:-}"; do
        [ -z "${_role_marker#*=}" ] || _ready_refuse "${_role_marker%%=*} is set: a judge, relay, release-manager, chief, consult or remote-control launch cannot also be the readiness role"
    done
    # The restrictions must exist: the settings, the strict MCP config and a minted session id.
    [ -n "$WORKER_SESSION_PROFILE_SETTINGS" ] && [ -f "$WORKER_SESSION_PROFILE_SETTINGS" ] || _ready_refuse "WORKER_SESSION_PROFILE_SETTINGS is unset or missing"
    [ -n "$WORKER_SESSION_PROFILE_MCP_CONFIG" ] && [ -f "$WORKER_SESSION_PROFILE_MCP_CONFIG" ] || _ready_refuse "WORKER_SESSION_PROFILE_MCP_CONFIG is unset or missing"
    [[ "${WORKER_SESSION_ID:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || _ready_refuse "WORKER_SESSION_ID must be the minted session UUID"
    command -v node >/dev/null 2>&1 || _ready_refuse "node is required to check the generated settings and MCP config"
    # The two generated files must carry exactly the role: two grants, the native tools denied, one MCP server.
    # The grant and deny lists mirror READINESS_GRANTS / READINESS_DENY in plugin-profiles.mjs; a suite pins both.
    _ready_why="$(node -e '
const fs = require("fs");
const grants = ["mcp__readiness__inspect", "mcp__readiness__act"];
const deny = ["Bash", "Read", "Write", "Edit", "NotebookEdit", "Glob", "Grep", "WebFetch", "WebSearch", "Agent", "Artifact"];
const why = (m) => { process.stdout.write(m); process.exit(1); };
let s; let m;
try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { why("the settings file is not valid JSON"); }
try { m = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch (e) { why("the MCP config is not valid JSON"); }
const strs = (v) => Array.isArray(v) && v.every((x) => typeof x === "string");
const p = s && s.permissions;
if (!p || !strs(p.allow) || p.allow.length !== grants.length || !grants.every((g) => p.allow.includes(g))) why("the settings must allow exactly mcp__readiness__inspect and mcp__readiness__act");
if (!strs(p.deny) || !deny.every((d) => p.deny.includes(d))) why("the settings must deny every native tool");
if (Object.keys(p).some((key) => !["allow", "deny"].includes(key)) || Object.keys(s).some((key) => !["enabledPlugins", "permissions", "skillListingBudgetFraction", "skillOverrides"].includes(key))) why("the settings contain an unknown permission or settings key");
const sv = m && m.mcpServers;
if (!sv || typeof sv !== "object" || Array.isArray(sv) || Object.keys(sv).join(",") !== "readiness") why("the MCP config must name exactly the readiness server");
const server = sv.readiness;
if (!server || typeof server !== "object" || Array.isArray(server) || typeof server.command !== "string" || !server.command || (server.args !== undefined && !strs(server.args))) why("the readiness MCP server entry is malformed");
if (Object.keys(server).some((key) => !["command", "args"].includes(key))) why("the readiness MCP server entry contains an unknown key");
// The --session-id this launcher emits is bound to the trusted private startup config: the adapter is started against
// exactly one private startup file, and that file must hold the minted id as its immutable session scope. The id is
// never a caller argument and no other flag or environment value names it.
const path = require("path");
const a = server.args;
if (!Array.isArray(a) || a.length !== 3 || a[1] !== "--startup-config" || !path.isAbsolute(a[0]) || path.basename(a[0]) !== "readiness-tools.mjs" || !path.isAbsolute(a[2]) || path.basename(a[2]) !== "startup.json") why("the readiness MCP server must be started as: <readiness-tools.mjs> --startup-config <startup.json>");
let dst; let fst; let c;
try { dst = fs.lstatSync(path.dirname(a[2])); fst = fs.lstatSync(a[2]); } catch (e) { why("the private startup config is missing"); }
const uid = process.getuid();
if (!dst.isDirectory() || dst.uid !== uid || (dst.mode & 0o777) !== 0o700) why("the private startup config directory must be a mode-0700 directory owned by the launching user");
if (!fst.isFile() || fst.uid !== uid || (fst.mode & 0o777) !== 0o600 || fst.nlink !== 1) why("the private startup config must be a mode-0600 regular file owned by the launching user");
try { c = JSON.parse(fs.readFileSync(a[2], "utf8")); } catch (e) { why("the private startup config is not valid JSON"); }
if (!c || c.schema !== "readiness-startup-v1" || c.lane !== "native") why("the private startup config is not a native readiness startup config");
if (c.session_scope !== process.argv[3]) why("the private startup config binds a different session id than the minted one");
' "$WORKER_SESSION_PROFILE_SETTINGS" "$WORKER_SESSION_PROFILE_MCP_CONFIG" "$WORKER_SESSION_ID" 2>&1)" || _ready_refuse "$_ready_why"
    # The caller's argv: no availability, settings, session or run-mode override, and at most one auto mode.
    _expect_value=""
    for _a in "$@"; do
        if [ -n "$_expect_value" ]; then
            if [ "$_expect_value" = --permission-mode ]; then
                [ "$_a" = auto ] || _ready_refuse "--permission-mode must be exactly auto"
            else
                case "$_a" in ''|-*) _ready_refuse "$_expect_value requires a non-option value" ;; esac
            fi
            _expect_value=""
            continue
        fi
        case "$_a" in
            --permission-mode) _caller_modes=$((_caller_modes + 1)); _expect_value=--permission-mode ;;
            --permission-mode=auto) _caller_modes=$((_caller_modes + 1)) ;;
            --permission-mode=*) _ready_refuse "--permission-mode must be exactly auto" ;;
            --model|--autocompact|-n) _expect_value="$_a" ;;
            --model=*|--autocompact=*) case "${_a#*=}" in ''|-*) _ready_refuse "${_a%%=*} requires a non-option value" ;; esac ;;
            -*) _ready_refuse "the caller's argv names unsupported option $_a: readiness permits only model, autocompact, name and auto mode" ;;
        esac
    done
    [ -z "$_expect_value" ] || _ready_refuse "$_expect_value has no value"
    [ "$_caller_modes" -le 1 ] || _ready_refuse "the caller's argv names --permission-mode more than once"
fi

# Under a consult the caller's PATH must not pick the binary: a
# foreign `claude` first on PATH could ignore `--setting-sources ""`. Resolve it
# once from the pinned PATH in consult-env.sh (its home part comes from the
# passwd entry, not the caller-set $HOME). A consult reaches here through
# worker-claude-launcher-consult.sh, which already ran this on an absolute
# `bash -p` with the startup variables and exported functions stripped, so
# `type -P` below is a plain PATH search. WORKER_SESSION_CLAUDE_BIN stays the suite's
# seam: headed-arm-worker.sh scrubs it (var + token) and refuses its
# HEADED_ARM_WORKER_CLAUDE_BIN source before a consult launches, so no consult
# reaches here with it set.
if [ "${WORKER_SESSION_PROFILE_NO_SETTING_SOURCES:-}" = 1 ] && [ -z "${WORKER_SESSION_CLAUDE_BIN:-}" ]; then
    # shellcheck source=consult-env.sh
    if ! . "${BASH_SOURCE[0]%/*}/consult-env.sh"; then
        echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 (a consult) but consult-env.sh did not load" >&2
        exit 2
    fi
    _pin_path="$(consult_pin_path)"
    # shellcheck disable=SC2030  # the lookup PATH is subshell-local on purpose
    CLAUDE_BIN="$(PATH="$_pin_path"; type -P claude 2>/dev/null)" || CLAUDE_BIN=""
    case "$CLAUDE_BIN" in
        /*) ;;
        *)
            echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 (a consult) but no claude on the pinned PATH ($_pin_path); a consult never runs the caller's PATH claude" >&2
            exit 2 ;;
    esac
    # An npm-installed claude is a `#!/usr/bin/env node` script, and claude
    # spawns helpers by name: the consult runs on the pinned PATH alone, so
    # neither can resolve through a caller-chosen dir.
    PATH="$_pin_path"
    export PATH
    unset -v _pin_path
fi

_caps_lib="${BASH_SOURCE[0]%/*}/../lib/subagent-caps.sh"
# shellcheck source=../lib/subagent-caps.sh
if ! { [ -r "$_caps_lib" ] && . "$_caps_lib"; }; then
    echo "worker-claude-launcher: refusing to launch: $_caps_lib did not load, so the session would start without the subagent caps" >&2
    exit 2
fi
subagent_caps_export
PRE=()
if [ "$_readiness" = 0 ]; then
    subagent_caps_haiku_args "$@"
    PRE+=(${SUBAGENT_CAPS_HAIKU_ARGS[@]+"${SUBAGENT_CAPS_HAIKU_ARGS[@]}"})
fi

if [ -n "${WORKER_SESSION_PROFILE_SETTINGS:-}" ]; then
    if [ ! -f "$WORKER_SESSION_PROFILE_SETTINGS" ]; then
        echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_SETTINGS is set but missing: $WORKER_SESSION_PROFILE_SETTINGS" >&2
        echo "worker-claude-launcher: launching without it would silently give this worker the FULL plugin set and a floor the ticket cannot measure." >&2
        exit 2
    fi
    PRE+=(--settings "$WORKER_SESSION_PROFILE_SETTINGS")
fi

if [ -n "${WORKER_SESSION_PROFILE_PREFACE:-}" ]; then
    if [ ! -f "$WORKER_SESSION_PROFILE_PREFACE" ]; then
        echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_PREFACE is set but missing: $WORKER_SESSION_PROFILE_PREFACE" >&2
        echo "worker-claude-launcher: the preface carries the invariant worker rules the brief no longer repeats; a worker without it is under-briefed." >&2
        exit 2
    fi
    PRE+=(--append-system-prompt-file "$WORKER_SESSION_PROFILE_PREFACE")
fi

if [ -n "${WORKER_SESSION_PROFILE_MCP_CONFIG:-}" ]; then
    if [ ! -f "$WORKER_SESSION_PROFILE_MCP_CONFIG" ]; then
        echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_MCP_CONFIG is set but missing: $WORKER_SESSION_PROFILE_MCP_CONFIG" >&2
        echo "worker-claude-launcher: launching without it under --strict-mcp-config would start the worker with NO MCP servers at all, silently breaking whatever this profile's allowlist promised it." >&2
        exit 2
    fi
    PRE+=(--mcp-config "$WORKER_SESSION_PROFILE_MCP_CONFIG" --strict-mcp-config)
fi

# The readiness role's hard boundary: no native tool at all (an EMPTY --tools value, kept as an empty argv
# element), one explicit auto mode unless the caller already carries its one, and exactly the two grants.
# --session-id follows immediately (it is required above), so a flag always ends the variadic grant list.
if [ "$_readiness" = 1 ]; then
    PRE+=(--tools "")
    [ "$_caller_modes" -eq 1 ] || PRE+=(--permission-mode auto)
    PRE+=(--allowedTools mcp__readiness__inspect mcp__readiness__act)
fi

# headed-arm-worker.sh minted this id and already recorded it in the
# worker doc's front matter, so the digest step finds the session by id.
_session_id="${WORKER_SESSION_ID:-}"
[ -z "$_session_id" ] || PRE+=(--session-id "$_session_id")

# The operator reaches a native worker from the Claude app by its
# session name. Set by headed-arm-worker.sh on native launches only; unset or
# empty adds nothing (clause 3).
_remote_control="${WORKER_SESSION_REMOTE_CONTROL:-}"
if [ -n "$_remote_control" ]; then
    # A lane launcher (claudex, openrouter, deepseek) is not a Remote Control endpoint:
    # refuse rather than hand it a flag it would misread or drop.
    case "${CLAUDE_BIN##*/}" in
        claude-codex|claude-openrouter|claude-deepseek)
            echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_REMOTE_CONTROL is set but the lane launcher ${CLAUDE_BIN##*/} is not a Remote Control endpoint (native lane only)" >&2
            exit 2 ;;
    esac
    PRE+=(--remote-control "$_remote_control")
fi
if [ "${WORKER_SESSION_PROFILE_NO_SETTING_SOURCES:-}" = 1 ]; then
    PRE+=(--setting-sources "")
    # The consult is confined only if the FINAL argv carries
    # `--setting-sources ""` and nothing after it names the flag again (the
    # last occurrence wins, so a caller-built `--setting-sources user,project`
    # would load the scopes this exists to cut). Refuse rather than launch.
    for _nss_arg in "$@"; do
        case "$_nss_arg" in
            --setting-sources|--setting-sources=*)
                echo "worker-claude-launcher: refusing to launch: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 (a consult) but the caller's argv names --setting-sources again, which would override the empty list and load the user/project/local scopes" >&2
                exit 2 ;;
        esac
    done
fi

# The readiness role's real exec and its validation-only render are ONE array: build it once, then either
# print it (NUL-terminated, binary first; nothing runs) or exec it.
if [ "$_readiness" = 1 ]; then
    _final=("$CLAUDE_BIN" "${PRE[@]}" "$@")
    if [ "$_render" = 1 ]; then
        printf '%s\0' "${_final[@]}"
        exit 0
    fi
    exec "${_final[@]}"
fi

exec "$CLAUDE_BIN" ${PRE[@]+"${PRE[@]}"} "$@"
