#!/usr/bin/env bash
# scripts/cr/cr-trigger-ledger.sh — the per-head CI-RELEASE ledger.
#
# NOT the CodeRabbit trigger ledger. scripts/lib/coderabbit-trigger-ledger.sh
# (and its deprecated alias scripts/lib/cr-trigger-ledger.sh) records the
# `@coderabbitai review` comments a leg posts; this file records the heads
# whose `ci:go` label scripts/lib/cr-first-release.sh released, with the
# reviewer verdicts that justified it. Same words, two ledgers.
#
# Usage:
#   cr-trigger-ledger.sh append                 one JSON line on stdin
#   cr-trigger-ledger.sh has <pr> <head>        rc 0 = a line exists, 1 = none
#   cr-trigger-ledger.sh list                   one summary line per release
#   cr-trigger-ledger.sh alert-once <key> [<text>]
#                                               rc 0 = first time (text printed),
#                                               rc 1 = already raised
#   cr-trigger-ledger.sh alert-clear <slug>     forget every `<slug>|...` key
#
# A ledger line: {pr, head, ts, reviewers:[{slug, mode, state, verdict,
# findings, latency_s, cost_usd}], cheap_settled_at}. cost_usd is null: the
# critic ledger carries no cost field.
#
# Paths (env, default under the git common dir so every worktree shares them):
#   CR_FIRST_LEDGER   <common>/cr-first-release-ledger.jsonl
#   CR_FIRST_ALERTS   <common>/cr-first-release-alerts   (one key per line)
#
# bash 3.2-safe.
# git-env-ok: read-only rev-parse of the caller's own repo, no GIT_* value is written or trusted
set -u

_crl_common() {
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
        || git rev-parse --git-common-dir 2>/dev/null
}
_crl_ledger() {
    [ -n "${CR_FIRST_LEDGER:-}" ] && { printf '%s\n' "$CR_FIRST_LEDGER"; return 0; }
    local c; c=$(_crl_common) || return 1
    printf '%s/cr-first-release-ledger.jsonl\n' "$c"
}
_crl_alerts() {
    [ -n "${CR_FIRST_ALERTS:-}" ] && { printf '%s\n' "$CR_FIRST_ALERTS"; return 0; }
    local c; c=$(_crl_common) || return 1
    printf '%s/cr-first-release-alerts\n' "$c"
}

# _crl_clear <alerts file> <slug> — drop every `<slug>|...` key.
_crl_clear() {
    grep -v -- "^$2|" "$1" > "$1.tmp.$$" 2>/dev/null
    mv "$1.tmp.$$" "$1"
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
    append)
        f=$(_crl_ledger) || { echo "cr-trigger-ledger: not in a git repository and CR_FIRST_LEDGER unset" >&2; exit 2; }
        IFS= read -r line || true  # swallow-ok: an unterminated last line still sets $line, and an empty one fails the jq shape check below
        printf '%s' "$line" | jq -e 'type == "object" and (.pr | type == "number") and (.head | type == "string") and (.reviewers | type == "array")' >/dev/null 2>&1 \
            || { echo "cr-trigger-ledger: append wants one JSON object with pr, head and reviewers" >&2; exit 2; }
        printf '%s\n' "$(printf '%s' "$line" | jq -c .)" >> "$f"
        ;;
    has)
        [ "$#" -eq 2 ] || { echo "usage: cr-trigger-ledger.sh has <pr> <head>" >&2; exit 2; }
        f=$(_crl_ledger) || exit 2
        [ -f "$f" ] || exit 1
        jq -Rn --argjson pr "$1" --arg head "$2" \
            '[inputs | fromjson? | select(.pr == $pr and .head == $head)] | length > 0' "$f" 2>/dev/null \
            | grep -qx true
        ;;
    list)
        f=$(_crl_ledger) || exit 2
        [ -f "$f" ] || exit 0
        jq -Rr 'fromjson? | select(.pr != null)
                | "PR #\(.pr) \(.head[0:12]) \(.ts) " + ([.reviewers[]? | "\(.slug)=\(.verdict)"] | join(" "))' "$f"
        ;;
    alert-once)
        [ "$#" -ge 1 ] || { echo "usage: cr-trigger-ledger.sh alert-once <key> [<text>]" >&2; exit 2; }
        key="$1"; text="${2:-}"
        f=$(_crl_alerts) || exit 2
        # ponytail: a plain read-then-append, so two simultaneous callers can both
        # raise one alert; flock is used when present, upgrade path = a lockdir.
        if command -v flock >/dev/null 2>&1; then
            (
                flock -w 30 9 || exit 3  # prim-ok: guarded by command -v flock with an unlocked fallback below
                grep -qxF -- "$key" "$f" 2>/dev/null && exit 1
                printf '%s\n' "$key" >> "$f" || exit 3
                exit 0
            ) 9>>"$f.lock"
            rc=$?
        else
            if grep -qxF -- "$key" "$f" 2>/dev/null; then rc=1
            else printf '%s\n' "$key" >> "$f" && rc=0 || rc=3; fi
        fi
        [ "$rc" -eq 0 ] && [ -n "$text" ] && printf '%s\n' "$text"
        exit "$rc"
        ;;
    alert-clear)
        [ "$#" -eq 1 ] || { echo "usage: cr-trigger-ledger.sh alert-clear <slug>" >&2; exit 2; }
        f=$(_crl_alerts) || exit 2
        [ -f "$f" ] || exit 0
        # Same lock as alert-once: an unlocked rewrite drops a key appended meanwhile.
        if command -v flock >/dev/null 2>&1; then
            (
                flock -w 30 9 || exit 3  # prim-ok: guarded by command -v flock with an unlocked fallback below
                _crl_clear "$f" "$1"
            ) 9>>"$f.lock"
        else
            _crl_clear "$f" "$1"
        fi
        ;;
    *)
        echo "usage: cr-trigger-ledger.sh append|has|list|alert-once|alert-clear" >&2
        exit 2
        ;;
esac
