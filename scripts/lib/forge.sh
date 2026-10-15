#!/usr/bin/env bash
# forge.sh — the forge-dispatch seam.
#
# A single forge abstraction with two backends, selected per-repo from the
# `origin` remote URL. Source this file, then call the forge_* verbs; each
# routes to the github or bitbucket backend. The verbs cover exactly the
# operations himmel uses today — no speculative interface.
#
# Detection precedence (spec §2, exhaustive — no ambiguity unattended):
#   1. $FORGE (github|bitbucket) verbatim — the only disambiguator for mixed
#      remotes and the test override.
#   2. else `git remote get-url origin`, its HOST (https, ssh://, scp-like; the
#      domain or a subdomain of it, case-insensitive) matched against
#      github.com / bitbucket.org — never a substring of the URL.
#   3. else (no origin, or matches neither) → non-zero + actionable message.
#      Never infer the forge from a non-origin remote (silent wrong-API risk).
#
# Backend command overrides (test seams, exact parallel to each other):
#   GH_CMD          Default `gh`.
#   BITBUCKET_CMD   Default `node <primary-checkout>/scripts/bitbucket/dist/index.js`.
#
# Two more kinds, local-git and none. The
# detection precedence above now lives in scripts/lib/project-mode.sh
# (project_mode_forge, which also reads git config himmel.forge). forge_detect
# keeps its exits for github/bitbucket callers: 2 = invalid, 3 = the origin
# names neither forge and nothing chose local-git or none explicitly. Only an
# explicit FORGE / himmel.forge reaches the local-git or none backend, so no
# existing caller is routed off gh/bitbucket by detection alone.
#
# Adapter ledger (a test aid, spec section 6.3): with HIMMEL_ADAPTER_LEDGER
# set, every public verb appends one JSONL line {ts, tracker, forge, op, id,
# rc, ms} to that file. Unset, nothing is written.

# Resolve dir of this file so we can source the backends regardless of cwd.
_FORGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/forge-github.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$_FORGE_LIB_DIR/forge-github.sh"
# shellcheck source=scripts/lib/forge-bitbucket.sh
# shellcheck disable=SC1091
. "$_FORGE_LIB_DIR/forge-bitbucket.sh"
# shellcheck source=scripts/lib/project-mode.sh
# shellcheck disable=SC1091
. "$_FORGE_LIB_DIR/project-mode.sh"
# The local-git and none backends are optional files: an adopter install that
# ships only the github/bitbucket backends keeps working, and a verb on a
# missing backend refuses with rc 4 (see _forge_route).
# shellcheck source=scripts/lib/forge-localgit.sh
# shellcheck disable=SC1091
[ -f "$_FORGE_LIB_DIR/forge-localgit.sh" ] && . "$_FORGE_LIB_DIR/forge-localgit.sh"
# shellcheck source=scripts/lib/forge-none.sh
# shellcheck disable=SC1091
[ -f "$_FORGE_LIB_DIR/forge-none.sh" ] && . "$_FORGE_LIB_DIR/forge-none.sh"

# _forge_origin_host <url> — echo the lowercased HOST of a git remote URL:
#   scheme://[userinfo@]host[:port]/path   (https, http, ssh, git, file, …)
#   [userinfo@]host:path                   (scp-like; no `://` before the first `/`)
# One terminal DNS dot is dropped (a fully-qualified host), never more.
# Anything else (a local path) has no host and echoes empty. Case globs and
# parameter expansion only — bash 3.2-safe.
_forge_origin_host() {
    local u rest authority scheme
    u=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    scheme="${u%%://*}"
    authority=""
    case "$u" in
        *://*)
            # A real scheme is [a-z0-9+.-]+ — `git@host:p/x://y` is scp-like, not a URL.
            case "$scheme" in
                ''|*[!a-z0-9+.-]*) ;;
                *) rest="${u#*://}"; authority="${rest%%/*}" ;;
            esac
            ;;
    esac
    if [ -z "$authority" ]; then
        # scp-like needs a `:` before the first `/`; `github.com/r.git` is a local path.
        case "${u%%/*}" in
            *:*) authority="${u%%:*}" ;;
        esac
    fi
    authority="${authority##*@}"   # drop userinfo
    authority="${authority%%:*}"   # drop :port
    printf '%s' "${authority%.}"   # drop ONE terminal DNS dot (HIMMEL-3358): `github.com.` is github.com
}

forge_detect() {
    local f explicit="" origin
    if [ -n "${FORGE:-}" ] || [ -n "$(git config --get himmel.forge 2>/dev/null)" ]; then
        explicit=1
    fi
    # project_mode_forge prints its own one-line reason on an invalid or
    # contradictory setting (I8: local-git on a github/bitbucket origin).
    f=$(project_mode_forge --quiet) || return 2
    case "$f" in
        github|bitbucket) printf '%s\n' "$f"; return 0 ;;
    esac
    if [ -n "$explicit" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    # Detection alone said local-git or none: today's exit 3, so a github or
    # bitbucket caller fails loud instead of being routed to a local backend.
    origin=$(git remote get-url origin 2>/dev/null) || origin=""
    if [ -z "$origin" ]; then
        echo "forge_detect: cannot determine forge — set FORGE=github|bitbucket|local-git|none or add a github.com/bitbucket.org origin" >&2
    else
        echo "forge_detect: origin ($origin) is neither github.com nor bitbucket.org — set FORGE=github|bitbucket|local-git|none" >&2
    fi
    return 3
}

# _forge_json_str <s> — <s> as a JSON string literal: backslash and quote
# escaped, control characters dropped.
_forge_json_str() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# _forge_ms — milliseconds since the epoch (EPOCHREALTIME on bash 5, else
# whole seconds; the ledger is a test aid, not a profiler).
_forge_ms() {
    local t="${EPOCHREALTIME:-}" frac
    if [ -n "$t" ]; then
        t=${t/,/.}
        frac="${t#*.}000"
        printf '%s%s\n' "${t%.*}" "${frac:0:3}"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

# _forge_ledger <op> <forge> <id> <rc> <ms> — append one adapter-ledger line
# when HIMMEL_ADAPTER_LEDGER is set. Best-effort: never changes the verb's rc.
_forge_ledger() {
    [ -n "${HIMMEL_ADAPTER_LEDGER:-}" ] || return 0
    local tracker
    tracker=$(project_mode_tracker 2>/dev/null) || tracker=""
    printf '{"ts":%s,"tracker":%s,"forge":%s,"op":%s,"id":%s,"rc":%s,"ms":%s}\n' \
        "$(_forge_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(_forge_json_str "$tracker")" \
        "$(_forge_json_str "$2")" "$(_forge_json_str "$1")" "$(_forge_json_str "$3")" "$4" "$5" \
        >> "$HIMMEL_ADAPTER_LEDGER" 2>/dev/null || true
}

# _forge_dispatch <verb> <args...> — call gh_<verb> or bb_<verb> for the
# detected forge. Internal; the public verbs below wrap it.
_forge_dispatch() {
    local verb="$1"; shift
    if [ -n "${HIMMEL_ADAPTER_LEDGER:-}" ]; then
        local t0 rc=0 f=""
        t0=$(_forge_ms)
        _forge_route "$verb" "$@" || rc=$?
        f=$(forge_detect 2>/dev/null) || f=""
        _forge_ledger "${verb#forge_}" "$f" "${1:-}" "$rc" "$(( $(_forge_ms) - t0 ))"
        return "$rc"
    fi
    _forge_route "$verb" "$@"
}

# _forge_route <verb> <args...> — the dispatch itself. A verb a backend does
# not carry refuses with rc 4, the "unsupported here" exit
# every backend uses, rather than dying at rc 127.
_forge_route() {
    local verb="$1"; shift
    local f fn=""
    f=$(forge_detect) || return $?
    case "$f" in
        github)    fn="gh_${verb}" ;;
        bitbucket) fn="bb_${verb}" ;;
        local-git) fn="lg_${verb}" ;;
        none)      fn="none_${verb}" ;;
    esac
    if declare -F "$fn" >/dev/null; then
        "$fn" "$@"
    else
        echo "forge($f): ${verb#forge_} is not supported on a $f repo" >&2
        return 4
    fi
}

# ── public verbs ─────────────────────────────────────────────────────────────
forge_auth_status()    { _forge_dispatch forge_auth_status "$@"; }
forge_repo_nwo()       { _forge_dispatch forge_repo_nwo "$@"; }
forge_default_branch() { _forge_dispatch forge_default_branch "$@"; }
forge_user_slug()      { _forge_dispatch forge_user_slug "$@"; }
forge_pr_find_open()   { _forge_dispatch forge_pr_find_open "$@"; }
forge_pr_create()      { _forge_dispatch forge_pr_create "$@"; }
forge_pr_set_body()    { _forge_dispatch forge_pr_set_body "$@"; }
forge_pr_mergeable()   { _forge_dispatch forge_pr_mergeable "$@"; }
# args: NUMBER [VETTED_HEAD_SHA]. The optional vetted SHA binds the merge to the
# commit the gates certified (TOCTOU) — honored by github
# (--match-head-commit), accepted-and-ignored by bitbucket (no equivalent).
forge_pr_merge()       { _forge_dispatch forge_pr_merge "$@"; }
forge_pr_has_merged()  { _forge_dispatch forge_pr_has_merged "$@"; }
# issue create (CR deferred-issue filing). args: REPO TITLE BODY LABEL.
# Echoes the issue URL on success. The bitbucket backend returns rc 3 when the
# issue tracker is disabled (spec §5.2) so the caller can degrade gracefully.
forge_issue_create()   { _forge_dispatch forge_issue_create "$@"; }

# ── change-id verbs ───────────────────────────
# forge_change_id <branch>: github/bitbucket the open PR number for the branch;
#   local-git br-<branch, / to -, lowercased>, rc 2 when another branch's change
#   record already holds that id; none rc 4.
forge_change_id()      { _forge_dispatch forge_change_id "$@"; }
# forge_change_view <id>: one JSON object {id, head, base, title, state, merged}.
forge_change_view()    { _forge_dispatch forge_change_view "$@"; }
# forge_change_open <branch> <title-file> <body-file>: local-git writes the
#   change record and prints the change id; github/bitbucket open through
#   forge_pr_create and refuse here with rc 4.
forge_change_open()    { _forge_dispatch forge_change_open "$@"; }
# forge_checks <ref> [gh pr checks args...]: one "<bucket>\t<name>" row per
#   check (github); bitbucket, local-git and none rc 4 (local checks are WP5a).
forge_checks()         { _forge_dispatch forge_checks "$@"; }
# forge_repo_id: github/bitbucket owner/repo; local-git local:<abs git-common-dir>.
forge_repo_id()        { _forge_dispatch forge_repo_id "$@"; }
