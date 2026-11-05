#!/usr/bin/env bash
# scripts/hooks/refresh-statusline-caches-periodic.sh — keep the statusline
# caches warm OFF the render path.
#
# WHY: the spawn-free hud composer (scripts/statusline/hud-custom-lines.sh) and
# the now cache-only where-are-we segment READ pre-computed caches but never
# rebuild them — the detached in-render rebuilds were the orphaned-bash leak
# class this migration eliminates. This hook is where those two refreshes now
# live. It runs SYNCHRONOUSLY, so nothing it spawns is detached — no orphan can
# outlive it. It feeds BOTH the still-live bash bar and the hud composer.
#
# INVOCATION CADENCE (accurate — Claude Code has no timer/"periodic" hook event):
#   - Wired at SessionStart today (docs/setup/settings-template.json). During the
#     migration interim the legacy bar's own render-time refresh
#     (statusline.sh:870, `& disown`, 30s throttle) keeps the caches warm, so a
#     SessionStart-only refresh here is sufficient.
#   - At the Task 4.1 cutover (statusLine repointed to hud, the legacy bar's
#     render-time refresh removed) this same hook ALSO gets a per-turn
#     UserPromptSubmit trigger for in-session freshness. It is TTL-throttled
#     (below) so a per-turn call is a cheap stat-check no-op until the cache
#     actually ages out — matching OQ2 (per-session, TTL-throttled; NO always-on
#     scheduler). The "periodic" in the filename is this throttled role, not a
#     timer.
#
# Refreshes (TTL-throttled — skipped when the cache is still fresh):
#   1. the epic rollup cache  (scripts/where-are-we/statusline-rollup.sh)
#
# FAIL-OPEN: a hook must never block or fail the session (a cache-warmer is not a
# guardrail — cf. auto-arm-on-cap's watchdog exception). Every step is guarded;
# the script always exits 0.
#
# Seams (tests): --cwd <dir> ; HIMMEL_WHERE_ARE_WE_ROLLUP_DIR (rollup cache dir,
#   default /tmp/claude) ; HIMMEL_WHERE_ARE_WE_ROLLUP_CMD (rollup refresh cmd) ;
#   HIMMEL_WHERE_ARE_WE_ROLLUP_TTL (rollup freshness secs, default 900).
set -uo pipefail

cwd_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) cwd_override="${2:-}"; shift 2 ;;
        *)     shift ;;
    esac
done

SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/.." && pwd)"

# Drain stdin (SessionStart JSON) so the caller's pipe never blocks; use its
# .cwd if no --cwd was passed.
input=""
if [ ! -t 0 ]; then input="$(cat 2>/dev/null || true)"; fi

cwd="$cwd_override"
if [ -z "$cwd" ] && [ -n "$input" ]; then
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

now_epoch="$(date +%s)"
# Returns 0 (fresh → skip refresh) when $1 exists and is younger than $2 secs.
# Keeps a per-turn UserPromptSubmit invocation (Task 4.1) a cheap no-op until the
# cache actually ages out.
_cache_fresh() {
    local f="$1" ttl="$2" mt
    [ -f "$f" ] || return 1
    case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$(( now_epoch - mt ))" -lt "$ttl" ]
}

# ── 1. Epic rollup ──────────────────────────────────────────────────────────
# Derive the ticket KEY from the branch (same branchToKey rule as the segment),
# then refresh that key's rollup synchronously (lock-guarded, no fork).
branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)"
key=""
case "$branch" in
    */*)
        rest="${branch#*/}"
        cand="$(printf '%s' "$rest" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p')"
        [ -n "$cand" ] && key="$(printf '%s' "$cand" | tr '[:lower:]' '[:upper:]')"
        ;;
esac
if [ -n "$key" ]; then
    cachedir="${HIMMEL_WHERE_ARE_WE_ROLLUP_DIR:-/tmp/claude}"
    cache="$cachedir/where-are-we-rollup-$key.json"
    # Reap a stale rollup lock (>300s) BEFORE the presence gate below. Once this
    # hook is the sole rollup refresher (Task 4.1 cutover), a lock leaked by a
    # hard-killed rollup — e.g. the SessionStart `timeout` killing it mid-rebuild
    # — would otherwise wedge the gate forever, since [ ! -d "$cache.lock" ]
    # skips and never re-invokes the subscript's own reaper.
    if [ -d "$cache.lock" ]; then
        rlm=$(stat -c %Y "$cache.lock" 2>/dev/null || stat -f %m "$cache.lock" 2>/dev/null || echo 0)
        if [ "$(( now_epoch - rlm ))" -gt 300 ]; then rmdir "$cache.lock" 2>/dev/null || true; fi
    fi
    if ! _cache_fresh "$cache" "${HIMMEL_WHERE_ARE_WE_ROLLUP_TTL:-900}" \
       && [ ! -d "$cache.lock" ]; then
        mkdir -p "$cachedir" 2>/dev/null || true
        rollup_cmd="${HIMMEL_WHERE_ARE_WE_ROLLUP_CMD:-bash $ROOT/where-are-we/statusline-rollup.sh}"
        # shellcheck disable=SC2086  # rollup_cmd is the intentional "bash <path>" seam word-split
        $rollup_cmd --key "$key" --out "$cache" >/dev/null 2>&1 || true
    fi
fi

exit 0
