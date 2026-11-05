#!/usr/bin/env bash
# scripts/statusline/hud-custom-lines.sh — the SPAWN-FREE composer for himmel's
# custom statusline lines under claude-hud.
#
# This is the command claude-hud's forked `display.customLineCommand` runs each
# render (see marketplace/plugins/claude-hud/src/custom-line-cmd.ts): hud pipes
# the session stdin JSON in, runs us in the session CWD, bounds us at 3s, caps
# output at 10 lines / 10KB, and STRIPS ANSI escapes from every line
# (utils/sanitize.ts). So this composer emits PLAIN TEXT — colour is hud's job
# on its native lines; our custom lines are colourless (an accepted cosmetic
# delta from the legacy bar, like the 3.1 label deltas).
#
# It emits, multiline, the lines hud has NO native equivalent for
# (§Decisions render-native-map — CUSTOM set):
#   1. where-are-we  : ⎇ <KEY>[ 📋][ <ledger-status>][ · <EPIC> <done>/<total>]
#   2. doctor        : himmel-doctor  <n> FAIL  <n> WARN  (only when non-zero)
# It prints NO economics rows (session / all-sessions / total used), on any env:
# the HUD is the same on every machine.
# hud renders natively (so we do NOT emit): model/ctx/git/duration/effort,
# 5h/7d usage, credits (balance_label), prompt-cache countdown, session cost.
#
# SPAWN-FREE (the whole point of the epic): reads pre-computed caches ONLY. The
# one child it runs is the where-are-we segment, SYNCHRONOUSLY and timeout-bounded
# (reaped, not detached) — no `& disown` / `( … & )` here (static-no-spawn gate).
#
# FAIL-OPEN everywhere: any error omits only its own line; never errors/hangs.
#
# Env knobs (relocated onto this composer from the legacy bar):
#   HIMMEL_WHERE_ARE_WE            off (0|false|off|no) → suppress the WAW line.
#   HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT  seconds to bound the segment call (default 3).
set -uo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/.." && pwd)"

# Drain stdin (the Claude Code JSON) so the caller's pipe never blocks.
input=""
if [ ! -t 0 ]; then input="$(cat 2>/dev/null || true)"; fi

# --- Parse the session cwd from stdin (the only native field this composer reads)
cwd=""
if [ -n "$input" ]; then
    cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

lines=""
append() { [ -n "$1" ] && { [ -n "$lines" ] && lines="$lines
$1" || lines="$1"; }; }

# ── Drive the single-writer usage producer ─────────────
# The producer (usage-cache-producer.sh) mirrors THIS render's rate_limits into
# the cap-guard consumer cache ($CLAUDE_USAGE_CACHE) + the hud snapshot, and
# throttled-queries OAuth credits. It is the SINGLE writer of both (hud only
# READS externalUsagePath; we never set externalUsageWritePath — no two-writer
# race). It MUST run here, render-timed: rate_limits live ONLY in the statusline
# stdin, which the SessionStart/UserPromptSubmit hooks don't get (§Decisions
# hud-usage-schema; plan Task 2.3 decision gate = "composer receives stdin →
# drive the producer from the composer"). SYNCHRONOUS (reaped by hud's
# customLineCommand tree-kill → no detached fork, no orphan). To keep render-path
# process churn down — the whole point of the epic — we gate the producer SPAWN
# on the consumer cache's own freshness (a cheap stat, no fork), so it forks the
# producer only when the cache is actually stale (~once per USAGE_CACHE_TTL), not
# every render. Fail-open: never blocks the render.
# Producer path is a test seam (HIMMEL_USAGE_PRODUCER) so a stub can observe the
# freshness-gated fork.
producer="${HIMMEL_USAGE_PRODUCER:-$SD/usage-cache-producer.sh}"
usage_cache="${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}"
usage_ttl="${USAGE_CACHE_TTL:-300}"
case "$usage_ttl" in ''|*[!0-9]*) usage_ttl=300 ;; esac
# BOUND the producer drive BELOW hud's whole-composer budget (custom-line-cmd.ts
# TIMEOUT_MS=3000, which discards ALL stdout on timeout). The producer's OAuth
# branch curls with --max-time 5; without this cap a slow OAuth round-trip would
# blank the composer's OWN lines (WAW), not just the usage side-effect.
# Default 2s leaves ≥1s for the render's own (fast, cache-only) lines.
prod_timeout="${HIMMEL_USAGE_PRODUCER_TIMEOUT:-2}"
case "$prod_timeout" in ''|*[!0-9]*) prod_timeout=2 ;; esac
prod_to=""
if command -v timeout >/dev/null 2>&1; then prod_to="timeout $prod_timeout"
elif command -v gtimeout >/dev/null 2>&1; then prod_to="gtimeout $prod_timeout"; fi
if [ -f "$producer" ] && [ -n "$input" ]; then
    prod_stale=1
    if [ -f "$usage_cache" ]; then
        um=$(stat -c %Y "$usage_cache" 2>/dev/null || stat -f %m "$usage_cache" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - um ))
        # age>=0 guards a clock-skewed FUTURE mtime (would else read as fresh).
        [ "$age" -ge 0 ] && [ "$age" -lt "$usage_ttl" ] && prod_stale=0
    fi
    if [ "$prod_stale" -eq 1 ]; then
        # shellcheck disable=SC2086  # prod_to is the intentional "timeout N" seam word-split
        # name this caller in the cache's produced_by stamp.
        printf '%s' "$input" | USAGE_PRODUCER_CALLER=statusline $prod_to bash "$producer" >/dev/null 2>&1 || true
    fi
fi

# ── Line 1: where-are-we (reuse the tested segment; cache-only, reaped) ──────
# Early-gate on HIMMEL_WHERE_ARE_WE (0|false|off|no): the segment self-gates too,
# but checking here skips the segment subprocess entirely when WAW is off —
# honouring the header's documented opt-out at the composer level, not just via
# the child, and avoiding a wasted spawn on the render path.
_waw_enabled() {
    case "$(printf '%s' "${HIMMEL_WHERE_ARE_WE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
seg_timeout="${HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT:-3}"
case "$seg_timeout" in ''|*[!0-9]*) seg_timeout=3 ;; esac
seg="$ROOT/where-are-we/statusline-segment.sh"
if _waw_enabled && [ -f "$seg" ]; then
    seg_to=""
    if command -v timeout >/dev/null 2>&1; then seg_to="timeout $seg_timeout"
    elif command -v gtimeout >/dev/null 2>&1; then seg_to="gtimeout $seg_timeout"; fi
    # shellcheck disable=SC2086  # seg_to is the intentional "timeout N" seam word-split
    waw="$(printf '%s' "$input" | $seg_to bash "$seg" --cwd "$cwd" 2>/dev/null || true)"
    append "$waw"
fi

# ── Doctor segment: FAIL/WARN counts from the daily doctor-cadence
# state file. Read-only and one small file: no doctor run here. Silent when the
# file is absent, malformed or clean (0 FAIL 0 WARN).
doc_counts="$(cat "${HIMMEL_DOCTOR_STATE_DIR:-${HOME:-}/.himmel/state/doctor-cadence}/counts" 2>/dev/null || true)"
case "$doc_counts" in
    fail=[0-9]*" warn="[0-9]*)
        doc_fail="${doc_counts#fail=}"; doc_fail="${doc_fail%% *}"
        doc_warn="${doc_counts##*warn=}"
        case "$doc_fail$doc_warn" in
            *[!0-9]*) ;;
            *) if [ "$((10#$doc_fail + 10#$doc_warn))" -gt 0 ]; then
                   # the file's mtime is the run time; over 24 h old shows its age.
                   doc_f="${HIMMEL_DOCTOR_STATE_DIR:-${HOME:-}/.himmel/state/doctor-cadence}/counts"
                   doc_m="$(stat -c %Y "$doc_f" 2>/dev/null || stat -f %m "$doc_f" 2>/dev/null || true)"
                   doc_age=""
                   case "$doc_m" in
                       ''|*[!0-9]*) ;;
                       *) doc_h=$(( ($(date +%s) - doc_m) / 3600 ))
                          if [ "$doc_h" -ge 48 ]; then doc_age=" ($((doc_h / 24))d old)"
                          elif [ "$doc_h" -ge 24 ]; then doc_age=" (${doc_h}h old)"; fi ;;
                   esac
                   append "$(printf 'himmel-doctor  %s FAIL  %s WARN%s' "$doc_fail" "$doc_warn" "$doc_age")"
               fi ;;
        esac ;;
esac

printf '%s\n' "$lines"
exit 0
