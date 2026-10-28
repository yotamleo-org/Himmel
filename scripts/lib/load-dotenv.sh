#!/usr/bin/env bash
# load-dotenv.sh — shell-side .env key loader.
#
# Reads the primary checkout's .env and exports requested keys into the
# environment ONLY if they are currently ABSENT, where absent means UNSET **or
# EMPTY** (a live non-empty value wins). This makes <repo-root>/.env a real
# config source for the handover shell tooling (HANDOVER_DIR, USER_SLUG) — not
# just for the Jira CLI.
#
# The empty half is load-bearing, not incidental. Every caller
# guards with `[ -z "${KEY-}" ]` — empty is not a usable value — so a loader
# that counted set-empty as "already provided" loaded nothing and still
# returned 0. The Jira CLI's loadEnv() (scripts/jira/src/client.ts) uses JS
# `??=`, under which an exported empty string DOES win; that half of the mirror
# no longer holds and is tracked separately.
#
# Usage — source this file, then:
#   load_dotenv [KEY ...]
#   load_dotenv --root <dir> [KEY ...]
# With no keys, does nothing: every consumer must name its allowlist.
# ponytail: HIMMEL-4915 audits launch sites and passes --no-env-file;
# Bun auto-loads cwd .env before any explicit reader.
#
# The .env path is resolved like the Jira CLI: the parent of
# `git rev-parse --git-common-dir`, so from inside a git worktree it still
# finds the PRIMARY checkout's .env (the gitignored .env is not copied into
# worktrees). Falls back to two levels up from this script if git is absent.
#
# `--root <dir>`: load <dir>/.env and BYPASS the CWD-based
# `_load_dotenv_root` resolution entirely (no `git rev-parse` against the
# process CWD). The caller has already resolved the correct root — used by the
# SessionStart inject-initiative hook so a session launched inside an UNRELATED
# git repo never reads THAT repo's .env.
#
# Safety: never `source`s the file (no arbitrary code execution). Extracts
# only the requested `KEY=` lines; skips comments, blanks, and lines without
# '='; strips surrounding whitespace and a trailing CR (CRLF-safe).

# Strip leading/trailing whitespace + trailing CR. Pure (stdout only).
_load_dotenv_trim() {
    local s="$1"
    s="${s%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    printf '%s' "$s"
}

# Resolve the primary checkout root (where the gitignored .env lives).
_load_dotenv_root() {
    local common
    if common=$(git rev-parse --git-common-dir 2>/dev/null); then
        ( cd "$common/.." && pwd ) && return 0
    fi
    ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

# _load_dotenv_primary_for <dir> — resolve the .env-bearing root for
# a CANDIDATE directory, for launchers that pin the .env to their OWN repo root via
# `load_dotenv --root` (which deliberately bypasses _load_dotenv_root's CWD-based
# resolution). The gitignored .env lives ONLY in the primary checkout and is never
# copied into linked worktrees, so a launcher invoked from a worktree copy of itself
# (its parent dir is a worktree root) finds no .env at <dir> and would exit 2.
#   <dir>/.env present             → echo <dir> (already the .env-bearing root)
#   <dir> is a linked git worktree → echo the PRIMARY checkout root (parent of
#                                    `git rev-parse --git-common-dir`) when its
#                                    .env exists; emit ONE advisory line to stderr
#   otherwise                      → echo <dir> (caller's missing-.env path applies
#                                    — load_dotenv then no-ops, rc 0)
# Shared reference for primary-checkout .env resolution. Returns the path on
# stdout; the advisory is the helper's ONLY stderr output.
_load_dotenv_primary_for() {  # $1 = candidate root dir
    local dir="${1:-}" common primary dir_abs toplevel gitdir dir_phys
    [ -n "$dir" ] || dir="$(_load_dotenv_root)"
    [ -f "$dir/.env" ] && { printf '%s' "$dir"; return 0; }
    dir_abs=$(cd "$dir" 2>/dev/null && pwd) || { printf '%s' "$dir"; return 0; }
    # Resolve the primary only when <dir> is a linked worktree. cd into <dir>
    # first so a relative --git-common-dir resolves against <dir> (not the shell
    # cwd); an absolute path cd's equally well — `( cd "$common/.." && pwd )` is
    # the same idiom _load_dotenv_root uses.
    if common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) && [ -n "$common" ]; then
        primary=$(cd "$dir" && cd "$common/.." 2>/dev/null && pwd) || primary=""
        # Restrict the fallback to GENUINE linked-worktree ROOTS.
        # r1 gated only on `primary != candidate`, so ANY directory inside ANY
        # checkout qualified — a hermetically pinned root like <worktree>/scripts
        # (or <primary>/scripts) resolved common-dir to the real .git, differed
        # from the candidate, and silently loaded the operator's .env, breaking
        # the documented hermetic override. Two guards:
        #  (1) the candidate must BE its checkout root: --show-toplevel (git's
        #      resolved, physical form) == the candidate's physical path (pwd -P),
        #      so a NESTED dir inside a worktree or the primary never qualifies;
        #  (2) the checkout must be genuinely LINKED: --git-dir differs from
        #      --git-common-dir (equal = primary checkout → nothing to fall back
        #      FROM). Both resolve relative to <dir>, so the raw outputs compare.
        dir_phys=$(cd "$dir" && pwd -P)
        toplevel=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || toplevel=""
        # Re-resolve git's toplevel through bash cd+pwd -P so it lands in the
        # same physical (MSYS on Windows) form as dir_phys — git for Windows
        # prints a drive-letter path that never string-equals a bash pwd, and on
        # macOS /tmp → /private/tmp must resolve identically on both sides.
        [ -n "$toplevel" ] && toplevel=$(cd "$toplevel" 2>/dev/null && pwd -P)
        gitdir=$(cd "$dir" && git rev-parse --git-dir 2>/dev/null) || gitdir=""
        if [ -n "$primary" ] && [ -n "$toplevel" ] && [ "$toplevel" = "$dir_phys" ] \
           && [ -n "$gitdir" ] && [ "$gitdir" != "$common" ] \
           && [ "$primary" != "$dir_abs" ] && [ -f "$primary/.env" ]; then
            echo "load-dotenv: .env absent under worktree '$dir_abs' — reading the primary checkout's .env at '$primary'." >&2
            printf '%s' "$primary"
            return 0
        fi
    fi
    printf '%s' "$dir"
}

# _load_dotenv_envfile [<root>] — the .env path load_dotenv reads: <root>/.env
# when a root is given (an explicit --root bypasses CWD git resolution — never
# trust the CWD repo), else the himmelctl cache dir's .env when present, else
# the git-resolved primary checkout's .env. Prints nothing when unresolvable.
_load_dotenv_envfile() {
    local _lf_root="${1:-}"
    if [ -n "$_lf_root" ]; then
        printf '%s/.env' "$_lf_root"
        return 0
    fi
    # A read-only install tree (e.g. a packaged /usr/share
    # prefix) can never HAVE an in-tree .env, so an adopter's overrides land
    # under the himmelctl cache dir instead. Readers check there FIRST, then
    # fall back to the git-resolved root, so an existing writable clone's
    # .env is unaffected.
    local _lf_cache="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}"
    if [ -f "$_lf_cache/.env" ]; then
        printf '%s/.env' "$_lf_cache"
        return 0
    fi
    _lf_root=$(_load_dotenv_root) || return 0
    printf '%s/.env' "$_lf_root"
}

load_dotenv() {
    # Every policy key is checked against the project file once every layer
    # has run, even one the process env set, so this reader agrees with
    # load_policy; tightening can only make the value stricter.
    local _ldp_key _ldp_pol=() _ldp_first=1
    [ "${1:-}" = "--root" ] && _ldp_first=3
    for _ldp_key in "${@:$_ldp_first}"; do
        if [ "$(_himmel_key_class "$_ldp_key")" = policy ]; then
            _ldp_pol[${#_ldp_pol[@]}]="$_ldp_key"
        fi
    done
    _load_dotenv_layers "$@"
    if [ "${#_ldp_pol[@]}" -gt 0 ]; then
        _himmel_project_tighten "${_ldp_pol[@]}" || true
    fi
    return 0
}

_load_dotenv_layers() {
    local _ld_root=""
    if [ "${1:-}" = "--root" ]; then
        _ld_root="$2"; shift 2
    fi
    local _ld_keys=("$@")
    [ "${#_ld_keys[@]}" -gt 0 ] || return 0

    local _ld_key _ld_line _ld_val _ld_rc=0
    local _ld_pending=()
    for _ld_key in "${_ld_keys[@]}"; do
        # Absent means UNSET **or EMPTY**. `declare -p` is Bash
        # 3.2-compatible and short-circuits the indirect expansion when the key
        # is genuinely unset, so this stays `set -u`-safe. Every caller guards
        # with `[ -z "${KEY-}" ]`, i.e. empty is not a usable value; a loader
        # that treated set-empty as "already provided" silently loaded nothing
        # and still returned 0 — the exact silent-failure class this family of
        # tickets exists to remove. Non-clobbering therefore protects a live
        # NON-EMPTY value.
        if ! declare -p "$_ld_key" >/dev/null 2>&1 || [ -z "${!_ld_key:-}" ]; then
            _ld_pending[${#_ld_pending[@]}]="$_ld_key"
        fi
    done
    [ "${#_ld_pending[@]}" -gt 0 ] || return 0

    # Config layers first (defined at the end of this file):
    # a behaviour key comes from ~/.himmel/himmel.conf(.local), a gate-policy
    # key from ~/.himmel/config.json .policy. A secret key never comes from
    # either; it falls through to the resolver, then .env, below. This advisory
    # reader keeps going on an unreadable config.json (the notice says so); only
    # load_policy, the gate reader, fails closed on it.
    if declare -F _himmel_config_layers >/dev/null 2>&1; then
        local _ld_found _ld_rest=()
        if ! _ld_found=$(_himmel_config_layers "${_ld_pending[@]}"); then
            printf 'himmel: ~/.himmel/config.json is unreadable; policy keys fall back to .env\n' >&2
        fi
        while IFS= read -r _ld_line; do
            [ -n "$_ld_line" ] || continue
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_ld_line"
        done <<EOF
$_ld_found
EOF
        for _ld_key in "${_ld_pending[@]}"; do
            if [ -z "${!_ld_key:-}" ]; then
                _ld_rest[${#_ld_rest[@]}]="$_ld_key"
            fi
        done
        [ "${#_ld_rest[@]}" -gt 0 ] || return 0
        _ld_pending=("${_ld_rest[@]}")
    fi

    # Secret keys next: the resolver serves them from $CREDENTIALS_DIRECTORY or
    # the OS keyring. Only when one of those can exist, so a machine with
    # neither forks nothing; .env stays the fallback below.
    local _ld_resolver=. _ld_secret=()
    case "${BASH_SOURCE[0]}" in */*) _ld_resolver=${BASH_SOURCE[0]%/*} ;; esac
    _ld_resolver="$_ld_resolver/himmel-secrets"
    if declare -F _himmel_key_class >/dev/null 2>&1 && [ -x "$_ld_resolver" ] \
        && { [ -n "${CREDENTIALS_DIRECTORY:-}" ] || command -v secret-tool >/dev/null 2>&1; }; then
        for _ld_key in "${_ld_pending[@]}"; do
            [ "$(_himmel_key_class "$_ld_key")" = secret ] && _ld_secret[${#_ld_secret[@]}]="$_ld_key"
        done
    fi
    if [ "${#_ld_secret[@]}" -gt 0 ]; then
        local _ld_got _ld_rest=()
        if [ -n "$_ld_root" ]; then
            _ld_got=$("$_ld_resolver" get --no-dotenv --root "$_ld_root" "${_ld_secret[@]}") || _ld_got=""
        else
            _ld_got=$("$_ld_resolver" get --no-dotenv "${_ld_secret[@]}") || _ld_got=""
        fi
        while IFS= read -r _ld_line; do
            [ -n "$_ld_line" ] || continue
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_ld_line"
        done <<EOF
$_ld_got
EOF
        _ld_got=""
        for _ld_key in "${_ld_pending[@]}"; do
            if [ -z "${!_ld_key:-}" ]; then
                _ld_rest[${#_ld_rest[@]}]="$_ld_key"
            fi
        done
        [ "${#_ld_rest[@]}" -gt 0 ] || return 0
        _ld_pending=("${_ld_rest[@]}")
    fi

    local _ld_envfile
    _ld_envfile=$(_load_dotenv_envfile "$_ld_root")
    [ -n "$_ld_envfile" ] && [ -f "$_ld_envfile" ] || return 0

    # Read .env once. The helper forks at most once per requested match, not
    # once per .env line. A non-secret key found here is legacy: it still
    # applies for one release, with one deprecation notice per call. A secret
    # key found here is legacy too once a keyring can hold it; a .env tracked
    # by git serves no secret at all.
    local _ld_legacy=() _ld_dotsecret=() _ld_tracked=""
    while IFS= read -r _ld_line || [ -n "$_ld_line" ]; do
        _ld_key="${_ld_line%%=*}"
        _ld_val=$(_load_dotenv_trim "${_ld_line#*=}")
        if declare -F _himmel_key_class >/dev/null 2>&1 \
            && [ "$(_himmel_key_class "$_ld_key")" = secret ]; then
            if [ -z "$_ld_tracked" ]; then
                _ld_tracked=0
                if _load_dotenv_tracked "$_ld_envfile"; then
                    _ld_tracked=1
                    _himmel_tracked_dotenv_notice "$_ld_envfile"
                fi
            fi
            [ "$_ld_tracked" = 0 ] || continue
            _ld_dotsecret[${#_ld_dotsecret[@]}]="$_ld_key"
        elif declare -F _himmel_key_class >/dev/null 2>&1; then
            _ld_legacy[${#_ld_legacy[@]}]="$_ld_key"
        fi
        export "$_ld_key=$_ld_val"
    done < <(_load_dotenv_extract "$_ld_envfile" "${_ld_pending[@]}")
    if [ "${#_ld_legacy[@]}" -gt 0 ]; then
        _himmel_deprecation_notice "${_ld_legacy[@]}"
    fi
    if [ "${#_ld_dotsecret[@]}" -gt 0 ]; then
        _himmel_secret_dotenv_notice "$_ld_envfile" "${_ld_dotsecret[@]}"
    fi
    return 0
}

# _load_dotenv_tracked <file> — true when git tracks <file> in its checkout.
_load_dotenv_tracked() {
    local _lt_dir="${1%/*}" _lt_base="${1##*/}"
    [ "$_lt_dir" != "$1" ] || _lt_dir=.
    git -C "$_lt_dir" ls-files --error-unmatch -- "$_lt_base" >/dev/null 2>&1
}

# _load_dotenv_extract <file> KEY... — print `KEY=<raw value>` for the first
# line of each requested key in a dotenv-format file. Never executes the file.
# awk compares the complete trimmed key (the equivalent of anchored ^KEY=
# matching) and leaves value trimming to _load_dotenv_trim.
_load_dotenv_extract() {
        awk '
            BEGIN {
                for (i = 2; i < ARGC; i++) {
                    wanted[ARGV[i]] = 1
                    delete ARGV[i]
                }
            }
            {
                line = $0
                sub(/\r$/, "", line)
                if (line == "" || line ~ /^#/) next

                equals = index(line, "=")
                if (equals == 0) next

                key = substr(line, 1, equals - 1)
                sub(/^[[:space:]]+/, "", key)
                sub(/[[:space:]]+$/, "", key)
                if (!(key in wanted) || (key in seen)) next

                seen[key] = 1
                print key "=" strip_comment(substr(line, equals + 1))
            }
            # Drop an unquoted trailing comment. The marker is
            # WHITESPACE followed by "#", per the dotenv convention — so
            # `URL=http://x/#frag` keeps its fragment and only a real gutter
            # comment goes. A value is quoted only when it BEGINS with a quote
            # (skip leading whitespace, then check the first non-whitespace
            # char) — a quote appearing later inside an unquoted value is DATA,
            # not structure. Inside a DOUBLE-quoted value a backslash escapes
            # the next character, so `\"` does not close the quote; inside a
            # SINGLE-quoted value a backslash is a LITERAL character (shell/
            # dotenv convention — a single-quoted trailing-backslash Windows
            # path must still close on the real closing quote), so escaping
            # applies only when the opening quote was `"`. A "#" inside quotes is
            # data; an UNTERMINATED quote keeps the whole remainder rather
            # than guessing where a broken value ends. Trailing whitespace is
            # left to _load_dotenv_trim. Surrounding quotes are still NOT
            # stripped.
            #
            # Why this matters: .env.example USED TO ship
            # `JIRA_PROJECT_KEY=HIMMEL   # default project for jira ops`, and
            # check-commit-msg.sh builds its ticket pattern from that key. Every
            # machine installed from that .env.example was running the
            # commit-msg gate with the impossible pattern
            # `HIMMEL   # default project for jira ops-[0-9]+`.
            function strip_comment(v,    i, c, q, n, started, esc) {
                n = length(v)
                q = ""
                started = 0
                esc = 0
                for (i = 1; i <= n; i++) {
                    c = substr(v, i, 1)
                    if (!started) {
                        if (c == " " || c == "\t") continue
                        started = 1
                        if (c == "\"" || c == "'"'"'") { q = c; continue }
                    }
                    if (q != "") {
                        if (q == "\"" && esc) { esc = 0; continue }
                        if (q == "\"" && c == "\\") { esc = 1; continue }
                        if (c == q) q = ""
                        continue
                    }
                    if (c == "#" && i > 1 && substr(v, i - 1, 1) ~ /[ \t]/) {
                        return substr(v, 1, i - 1)
                    }
                }
                return v
            }
        ' "$@"
}

# Config layers — the behaviour-config and gate-policy layers that sit beside
# .env (layer table: docs/internals/config-layers.md). They live in this file,
# not a sibling, so every copy of the loader carries load_policy.
#
#   behaviour keys  <repo>/.himmel/project.conf (project-scope keys only,
#                   _himmel_project_scope) > ~/.himmel/himmel.conf.local
#                   > ~/.himmel/himmel.conf (KEY=value, parsed, never
#                   sourced). load_dotenv reads them with the process env
#                   still winning.
#   policy keys     ~/.himmel/config.json .policy, the operator-owned file a
#                   guard keeps agents from writing. load_policy, the gate
#                   reader, IGNORES the process env for them. The project
#                   file can only make one stricter (_himmel_project_tighten).
#   secret keys     scripts/lib/himmel-secrets ($CREDENTIALS_DIRECTORY, then
#                   the OS keyring), then .env with a DEPRECATED notice. Never
#                   read from either file above.
#
# The policy directory is <account home>/.himmel, the home taken from the
# account's passwd entry, never from $HOME, so a HOME prefix cannot pick the
# file. HIMMEL_POLICY_FOLLOWS_HOME=1 is the test seam that points it back at
# $HOME; it is a registered seam on the gates that read policy
# (scripts/chokepoints.json), so a per-call prefix is refused there.
# HIMMEL_CONFIG_DIR redirects only the himmel.conf read (tests use it to stay
# off the station's file).
# ponytail: policy keys live in config.json, not the tracked himmel.conf,
# because no guard covers writes to himmel.conf yet; move them once one does.

# Keys this layer serves. Anything else is a secret and stays in .env.
_himmel_key_class() {
    case "$1" in
        CR_REQUIRE_CROSS_MODEL|CR_FLOOR_FALLBACK|ARMAUTOMERGE|ENV_MIGRATION_CONSENT)
            printf 'policy' ;;
        HANDOVER_DIR|USER_SLUG|LUNA_VAULT_PATH|HIMMEL_DOC_FRESHNESS|\
        HIMMEL_INITIATIVE|HIMMEL_INITIATIVE_AFK|HIMMEL_AFK|\
        HIMMEL_INITIATIVE_OVERNIGHT|HIMMEL_OVERNIGHT|\
        HIMMEL_WHERE_ARE_WE|HIMMEL_WHERE_ARE_WE_STALE_HOURS|\
        HIMMEL_WORKTREE_NUDGE|HIMMEL_UPDATE_AUTOSTASH|CR_PROFILE|\
        CR_CLAUDE_AGENTS|TICKET_ID_REQUIRED|TICKET_ID_PATTERN|\
        TICKET_ID_EXEMPT_AUTHORS|TRACKER|\
        JIRA_EMAIL|JIRA_PROJECTS|JIRA_PROJECT_KEY|JIRA_CLOUD_ID|\
        GCP_CI_PROJECT_ID|SNYK_ORG_ID|SNYK_ORG_SLUG|\
        VERCEL_TEAM_ID|VERCEL_USER_ID|ANTHROPIC_API_ORG_ID_A|ANTHROPIC_API_ORG_ID_B|\
        HIMMEL_REPO|CLAUDE_HUD_ALLOW_EXTRA_CMD|HIMMEL_WHERE_ARE_WE_ROLLUP_TTL|\
        HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT|HIMMEL_JIRA_NUDGE|CR_APP|CR_PUBLIC_REPO|\
        CLAUDE_END_SESSION_WIKI|SKILL_INDEX_DIR|ALIBABA_ANTHROPIC_BASE_URL|\
        ALIBABA_CODING_PLAN_BASE_URL|ALIBABA_DASHSCOPE_BASE_URL|ALIBABA_OPENAI_BASE_URL)
            printf 'config' ;;
        *)
            printf 'secret' ;;
    esac
}

# Behaviour keys a repo's project file may set. Station-scope keys (paths,
# identity, initiative/AFK) never read it, so a committed file cannot redirect
# where a station keeps its state.
_himmel_project_scope() {
    case "$1" in
        CR_PROFILE|CR_CLAUDE_AGENTS|TICKET_ID_REQUIRED|TICKET_ID_PATTERN|\
        TICKET_ID_EXEMPT_AUTHORS|TRACKER|JIRA_PROJECT_KEY|JIRA_PROJECTS|\
        HIMMEL_DOC_FRESHNESS)
            return 0 ;;
    esac
    return 1
}

_himmel_config_dir() {
    printf '%s' "${HIMMEL_CONFIG_DIR:-$HOME/.himmel}"
}

# The gate-policy file's directory: the account's passwd home + /.himmel, so
# no env var but the registered seam can redirect what load_policy and the
# policy layer read. command -p looks tools up on the default PATH, never
# $PATH, and $UID is bash's own. Prints nothing and fails when the account
# entry cannot be read.
_himmel_policy_dir() {
    local _pd_home="" _pd_line
    if [ "${HIMMEL_POLICY_FOLLOWS_HOME:-}" = 1 ]; then
        _pd_home=$HOME
    elif _pd_line=$(command -p getent passwd "$UID" 2>/dev/null); then
        IFS=: read -r _ _ _ _ _ _pd_home _ <<< "$_pd_line"
    elif _pd_line=$(command -p dscl . -read "/Users/$(command -p id -un)" NFSHomeDirectory 2>/dev/null); then
        _pd_home=${_pd_line#NFSHomeDirectory: }
    fi
    [ -n "$_pd_home" ] || return 1
    printf '%s' "$_pd_home/.himmel"
}

# The per-project override: .himmel/project.conf in the primary checkout of
# the repo the caller runs in, so a worktree reads its primary's file. It is
# resolved from the working directory even under --root, which callers pin to
# the himmel checkout. Prints nothing outside a git repo.
_himmel_project_conf() {
    local _pc_common _pc_root
    _pc_common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    [ -n "$_pc_common" ] || return 0
    _pc_root=$(cd "$_pc_common/.." 2>/dev/null && pwd) || return 0
    printf '%s/.himmel/project.conf' "$_pc_root"
}

# _himmel_policy_strict KEY VALUE — 1 when VALUE is the strict side of the
# gate KEY controls, 0 when it is the loose side, nothing for a key with no
# known order. Normalised as the gates read it: trimmed, case-insensitive.
_himmel_policy_strict() {
    local _ps_v
    _ps_v=$(_load_dotenv_trim "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')")
    case "$1" in
        CR_REQUIRE_CROSS_MODEL)
            case "$_ps_v" in 1|true|on|yes) printf 1 ;; *) printf 0 ;; esac ;;
        CR_FLOOR_FALLBACK)
            case "$_ps_v" in claude-only) printf 0 ;; *) printf 1 ;; esac ;;
        ARMAUTOMERGE|ENV_MIGRATION_CONSENT)
            case "$_ps_v" in 1|true|on|yes) printf 0 ;; *) printf 1 ;; esac ;;
    esac
}

# _himmel_project_tighten KEY... — for each policy key the project file sets,
# export its value when it is stricter than the one already resolved; a looser
# or unordered value, or a key line with no "=", is ignored with one notice.
# Returns non-zero when the
# file exists but is not a readable file or cannot be parsed, so a gate fails
# closed.
_himmel_project_tighten() {
    local _pt_file _pt_out _pt_line _pt_key _pt_val _pt_new _pt_cur
    _pt_file=$(_himmel_project_conf)
    [ -n "$_pt_file" ] && { [ -e "$_pt_file" ] || [ -L "$_pt_file" ]; } || return 0
    if [ ! -f "$_pt_file" ] || [ ! -r "$_pt_file" ]; then
        printf 'himmel: %s exists but is unreadable or not a file; gate policy fails closed\n' "$_pt_file" >&2
        return 1
    fi
    if ! _pt_out=$(_load_dotenv_extract "$_pt_file" "$@"); then
        printf 'himmel: %s cannot be parsed; gate policy fails closed\n' "$_pt_file" >&2
        return 1
    fi
    # A policy key written without "=" sets nothing; say so instead of
    # dropping it silently.
    for _pt_key in "$@"; do
        case "
$_pt_out" in *"
$_pt_key="*) continue ;; esac
        if grep -Eq "^[[:space:]]*$_pt_key([[:space:]][^=]*)?$" "$_pt_file"; then
            printf 'himmel: ignoring %s from %s: the line has no =, so it sets nothing\n' "$_pt_key" "$_pt_file" >&2
        fi
    done
    while IFS= read -r _pt_line; do
        [ -n "$_pt_line" ] || continue
        _pt_key="${_pt_line%%=*}"
        _pt_val=$(_load_dotenv_trim "${_pt_line#*=}")
        _pt_new=$(_himmel_policy_strict "$_pt_key" "$_pt_val")
        _pt_cur=$(_himmel_policy_strict "$_pt_key" "${!_pt_key-}")
        if [ -n "$_pt_new" ] && [ "$_pt_new" -gt "$_pt_cur" ]; then
            export "$_pt_key=$_pt_val"
        elif [ -z "$_pt_new" ] || [ "$_pt_new" -lt "$_pt_cur" ]; then
            printf 'himmel: ignoring %s from %s: a project file may only tighten gate policy, never loosen it\n' "$_pt_key" "$_pt_file" >&2
        fi
    done <<EOF
$_pt_out
EOF
    return 0
}

# One stderr line naming the keys (never their values) still read from .env.
_himmel_deprecation_notice() {
    printf 'himmel: DEPRECATED: %s read from .env, which is for secrets only. Move behaviour keys to ~/.himmel/himmel.conf and policy keys to ~/.himmel/config.json .policy: run scripts/setup/migrate-env-config.sh --dry-run. Until then .env keeps working.\n' "$*" >&2
}

# _himmel_secret_dotenv_notice <file> KEY... — one stderr line naming the
# secret keys (never their values) served from .env, printed only where a
# keyring could hold them instead.
_himmel_secret_dotenv_notice() {
    local _sn_file="$1"
    shift
    [ "$(uname -s)" != Darwin ] && command -v secret-tool >/dev/null 2>&1 || return 0
    printf 'himmel: DEPRECATED: secret %s read from %s. Move them to the OS keyring: scripts/lib/himmel-secrets import-env %s\n' "$*" "$_sn_file" "$_sn_file" >&2
}

# _himmel_tracked_dotenv_notice <file> — one stderr line refusing a .env that
# git tracks: a committed secret is already leaked, so none is served from it.
_himmel_tracked_dotenv_notice() {
    printf 'himmel: refusing secret keys from %s: the file is tracked by git. Rotate any secret it held and remove it from the index (git rm --cached).\n' "$1" >&2
}

# _himmel_policy_json <config.json> KEY... — print KEY=value for each key
# present under .policy. Strings, numbers and booleans only; null reads as
# unset. Returns non-zero when the file cannot be parsed, node is missing, or
# .policy or a requested value has any other shape, so a gate fails closed.
_himmel_policy_json() {
    node -e '
        const fs = require("fs");
        const [file, ...keys] = process.argv.slice(1);
        const doc = JSON.parse(fs.readFileSync(file, "utf8"));
        const raw = doc && typeof doc === "object" ? doc.policy : undefined;
        if (raw !== undefined && raw !== null && (typeof raw !== "object" || Array.isArray(raw))) process.exit(3);
        const policy = raw || {};
        let out = "";
        for (const key of keys) {
            if (!Object.prototype.hasOwnProperty.call(policy, key) || policy[key] === null) continue;
            const v = policy[key];
            if (!["string", "number", "boolean"].includes(typeof v)) process.exit(3);
            const s = String(v);
            if (/[\r\n\0]/.test(s)) process.exit(3);
            out += key + "=" + s + "\n";
        }
        process.stdout.write(out);
    ' "$@" 2>/dev/null
}

# _himmel_config_layers KEY... — print KEY=value for every requested
# behaviour key found in himmel.conf(.local) and every policy key found in
# config.json. Secret keys are skipped. Non-zero only when config.json exists
# and cannot be read.
_himmel_config_layers() {
    local _hc_dir _hc_key _hc_line _hc_val _hc_file _hc_found=" " _hc_first=1
    local _hc_cfg=() _hc_pol=() _hc_proj=() _hc_keys=()
    _hc_dir=$(_himmel_config_dir)
    for _hc_key in "$@"; do
        case "$(_himmel_key_class "$_hc_key")" in
            config)
                _hc_cfg[${#_hc_cfg[@]}]="$_hc_key"
                if _himmel_project_scope "$_hc_key"; then
                    _hc_proj[${#_hc_proj[@]}]="$_hc_key"
                fi ;;
            policy) _hc_pol[${#_hc_pol[@]}]="$_hc_key" ;;
        esac
    done
    if [ "${#_hc_cfg[@]}" -gt 0 ]; then
        # The project file comes first and serves project-scope keys only.
        for _hc_file in "$(_himmel_project_conf)" "$_hc_dir/himmel.conf.local" "$_hc_dir/himmel.conf"; do
            if [ "$_hc_first" = 1 ]; then
                _hc_first=0
                [ "${#_hc_proj[@]}" -gt 0 ] || continue
                _hc_keys=("${_hc_proj[@]}")
            else
                _hc_keys=("${_hc_cfg[@]}")
            fi
            [ -n "$_hc_file" ] && [ -f "$_hc_file" ] || continue
            while IFS= read -r _hc_line || [ -n "$_hc_line" ]; do
                _hc_key="${_hc_line%%=*}"
                case "$_hc_found" in *" $_hc_key "*) continue ;; esac
                _hc_val=$(_load_dotenv_trim "${_hc_line#*=}")
                [ -n "$_hc_val" ] || continue
                _hc_found="$_hc_found$_hc_key "
                printf '%s=%s\n' "$_hc_key" "$_hc_val"
            done < <(_load_dotenv_extract "$_hc_file" "${_hc_keys[@]}")
        done
    fi
    if [ "${#_hc_pol[@]}" -gt 0 ] && _hc_dir=$(_himmel_policy_dir) && [ -f "$_hc_dir/config.json" ]; then
        _himmel_policy_json "$_hc_dir/config.json" "${_hc_pol[@]}" || return 1
    fi
    return 0
}

# load_policy [--root <dir>] KEY... — the gate reader for policy keys.
# Order: ~/.himmel/config.json .policy, then legacy .env (deprecation
# notice), then unset, which every gate treats as its safe default; the
# project file then replaces a value only with a stricter one. The
# process env is never used: a value there is dropped, with a notice when it
# differs from the resolved one. Returns non-zero when a file that exists
# cannot be read, so the caller fails closed instead of using a default.
load_policy() {
    local _lp_root=""
    if [ "${1:-}" = "--root" ]; then
        _lp_root="$2"; shift 2
    fi
    [ "$#" -gt 0 ] || return 0
    local _lp_key _lp_line _lp_val _lp_out _lp_envfile _lp_i _lp_found=" "
    local _lp_keys=() _lp_env=() _lp_rest=() _lp_legacy=()
    local _lp_conf
    if ! _lp_conf="$(_himmel_policy_dir)/config.json"; then
        printf 'himmel: cannot read this account'\''s home from its passwd entry; gate policy fails closed\n' >&2
        return 1
    fi

    for _lp_key in "$@"; do
        if [ "$(_himmel_key_class "$_lp_key")" != policy ]; then
            printf 'load_policy: %s is not a policy key\n' "$_lp_key" >&2
            return 1
        fi
        _lp_keys[${#_lp_keys[@]}]="$_lp_key"
        _lp_env[${#_lp_env[@]}]="${!_lp_key-}"
        unset "$_lp_key"
    done

    if [ -f "$_lp_conf" ]; then
        if ! _lp_out=$(_himmel_policy_json "$_lp_conf" "${_lp_keys[@]}"); then
            printf 'himmel: ~/.himmel/config.json cannot be parsed; gate policy fails closed\n' >&2
            return 1
        fi
        while IFS= read -r _lp_line; do
            [ -n "$_lp_line" ] || continue
            _lp_found="$_lp_found${_lp_line%%=*} "
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_lp_line"
        done <<EOF
$_lp_out
EOF
    else
        printf 'himmel: no ~/.himmel/config.json; policy keys (%s) come from legacy .env or their safe defaults\n' "${_lp_keys[*]}" >&2
    fi

    for _lp_key in "${_lp_keys[@]}"; do
        case "$_lp_found" in *" $_lp_key "*) ;; *) _lp_rest[${#_lp_rest[@]}]="$_lp_key" ;; esac
    done
    if [ "${#_lp_rest[@]}" -gt 0 ]; then
        _lp_envfile=$(_load_dotenv_envfile "$_lp_root")
        if [ -n "$_lp_envfile" ] && [ -e "$_lp_envfile" ]; then
            if [ ! -r "$_lp_envfile" ]; then
                printf 'himmel: legacy .env exists but is unreadable; gate policy fails closed\n' >&2
                return 1
            fi
            while IFS= read -r _lp_line || [ -n "$_lp_line" ]; do
                _lp_key="${_lp_line%%=*}"
                _lp_val=$(_load_dotenv_trim "${_lp_line#*=}")
                export "$_lp_key=$_lp_val"
                _lp_legacy[${#_lp_legacy[@]}]="$_lp_key"
            done < <(_load_dotenv_extract "$_lp_envfile" "${_lp_rest[@]}")
            if [ "${#_lp_legacy[@]}" -gt 0 ]; then
                _himmel_deprecation_notice "${_lp_legacy[@]}"
            fi
        fi
    fi

    _himmel_project_tighten "${_lp_keys[@]}" || return 1

    _lp_i=0
    for _lp_key in "${_lp_keys[@]}"; do
        if [ -n "${_lp_env[$_lp_i]}" ] && [ "${_lp_env[$_lp_i]}" != "${!_lp_key-}" ]; then
            printf 'himmel: ignoring process-env %s; gate policy is read from ~/.himmel/config.json only\n' "$_lp_key" >&2
        fi
        _lp_i=$((_lp_i + 1))
    done
    return 0
}
