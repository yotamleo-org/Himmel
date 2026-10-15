#!/usr/bin/env bash
# gap-audit.sh — the read-only "gap audit" offer that himmel-update prints last.
# Source it, then call gap_audit_offer. It PRINTS the checks that came back
# non-green, each with a remedy, and offers the full audit; it never runs the
# audit, never writes, never fails the caller (always returns 0).
#
# Checks (all cheap, all read-only):
#   doctor rows  C50/C49/C56/C40 (qmd), C33/C8 (graphify) — reused, not redone
#   qmd          needsEmbedding backlog; collections not scanned for > 3 days
#   graphify     semantic manifest missing or older than 14 days
#   tickets      in-work tickets with no session/PR (next-dispatchable.sh
#                --resume-only); skipped when absent or Jira unset
#   ponytail     markers whose upgrade ticket is already Done in the Jira mirror
#
# Test seams: GAP_AUDIT_ROOT, GAP_AUDIT_NOW (epoch), GAP_AUDIT_DOCTOR_CMD,
# GAP_AUDIT_QMD_STATUS_FILE, GAP_AUDIT_GRAPH_OUT, GAP_AUDIT_MIRROR,
# GAP_AUDIT_RESUME_CMD (set-but-empty disables the check).
# PLATFORM GUARD: no .ps1 twin, by design — himmel-update.sh is bash-only.

GAP_AUDIT_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
GAP_AUDIT_FINDINGS=""

_ga_add() { # _ga_add <area> <message> [remedy]
    GAP_AUDIT_FINDINGS="${GAP_AUDIT_FINDINGS}      · $1: $2${3:+
          → $3}
"
}

_ga_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

_ga_check_doctor() {
    local root="$1" cmd rows line
    command -v jq >/dev/null 2>&1 || return 0
    cmd="${GAP_AUDIT_DOCTOR_CMD:-bash $root/scripts/himmel-doctor.sh --json --no-color --only C8,C33,C40,C49,C50,C56}"
    rows="$($cmd 2>/dev/null | jq -r 'select(.sev == "WARN" or .sev == "FAIL") | "\(.id)\t\(.msg)\t\(.remedy)"' 2>/dev/null)" || return 0
    [ -n "$rows" ] || return 0
    while IFS="$(printf '\t')" read -r id msg remedy; do
        [ -n "$id" ] && _ga_add "doctor $id" "$msg" "$remedy"
    done <<EOF
$rows
EOF
}

_ga_check_qmd() {
    local text pending stale
    if [ -n "${GAP_AUDIT_QMD_STATUS_FILE:-}" ]; then
        text="$(cat "$GAP_AUDIT_QMD_STATUS_FILE" 2>/dev/null)"
    elif command -v qmd >/dev/null 2>&1; then
        text="$(qmd status 2>/dev/null)"
    fi
    [ -n "${text:-}" ] || return 0
    pending="$(printf '%s\n' "$text" | sed -n 's/^ *Pending: *\([0-9][0-9]*\) need embedding.*/\1/p' | head -1)"
    if [ -n "$pending" ] && [ "$pending" -gt 0 ]; then
        _ga_add qmd "$pending document(s) need embedding" "qmd embed"
    fi
    # a collection line "name (qmd://name/)" is followed by "Files: N (updated <n><unit> ago)";
    # m/h/s are fresh, d counts only past 3, w/mo/y are always stale.
    stale="$(printf '%s\n' "$text" | awk '
        /\(qmd:\/\// { name = $1; next }
        /updated [0-9]+[a-z]+ ago/ {
            match($0, /updated [0-9]+[a-z]+ ago/)
            s = substr($0, RSTART + 8, RLENGTH - 12)
            n = s + 0; u = s; sub(/^[0-9]+/, "", u)
            if (name != "" && ((u == "d" && n > 3) || u == "w" || u == "mo" || u == "y")) printf "%s(%s) ", name, s
            name = ""
        }')"
    [ -n "$stale" ] && _ga_add qmd "collection(s) not scanned for more than 3 days: $stale" "bash scripts/luna/qmd-reindex.sh"
    return 0
}

_ga_check_semantic() {
    local out="${GAP_AUDIT_GRAPH_OUT:-$1/graphify-out}" now="$2" mt age
    [ -f "$out/graph.json" ] || return 0   # no graph on this machine: graphify is unused
    if [ ! -f "$out/semantic-manifest.json" ]; then
        _ga_add graphify "no semantic manifest — the semantic layer has never been built" "bash scripts/graphify/semantic-update.sh --seed-manifest (see the script header)"
        return 0
    fi
    mt="$(_ga_mtime "$out/semantic-manifest.json")" || return 0
    [ -n "$mt" ] || return 0
    age=$(( (now - mt) / 86400 ))
    [ "$age" -gt 14 ] && _ga_add graphify "semantic manifest is ${age}d old (limit 14d)" "bash scripts/graphify/semantic-update.sh (see the script header)"
    return 0
}

_ga_check_resume() {
    local root="$1" cmd rows n
    [ -n "${JIRA_PROJECT_KEY:-}" ] || return 0
    if [ "${GAP_AUDIT_RESUME_CMD+set}" = set ]; then
        cmd="$GAP_AUDIT_RESUME_CMD"
    else
        local nd="$root/scripts/handover/console-kit/next-dispatchable.sh"
        grep -q -- '--resume-only' "$nd" 2>/dev/null || return 0
        cmd="bash $nd --resume-only"
    fi
    [ -n "$cmd" ] || return 0
    rows="$($cmd 2>/dev/null | awk -F'\t' '$1 == "RESUME" { printf "%s (%s, %s); ", $2, $5, $7 }')"
    [ -n "$rows" ] && _ga_add tickets "in-work with no session or open PR: $rows" "bash scripts/handover/console-kit/next-dispatchable.sh --resume-only"
    return 0
}

_ga_check_ponytail() {
    local root="$1" mirror="${GAP_AUDIT_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}" hits shown="" n=0 line key loc
    [ -d "$mirror" ] || return 0
    hits="$(git -C "$root" grep -nE 'ponytail:.*[Uu]pgrade.*HIMMEL-[0-9]+' 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        loc="$(printf '%s' "$line" | cut -d: -f1,2)"
        key="$(printf '%s' "$line" | sed 's/.*[Uu]pgrade//' | grep -oE 'HIMMEL-[0-9]+' | head -1)"
        [ -n "$key" ] || continue
        grep -q '^status: "Done"' "$mirror/$key.md" 2>/dev/null || continue
        n=$((n+1))
        [ "$n" -le 5 ] && shown="${shown}${loc} (${key}); "
    done <<EOF
$hits
EOF
    [ "$n" -gt 0 ] || return 0
    [ "$n" -gt 5 ] && shown="${shown}+$((n-5)) more; "
    _ga_add ponytail "$n marker(s) whose upgrade ticket is already Done: $shown" "revisit the ceiling or drop the marker (docs/internals/ponytail-convention.md)"
}

gap_audit_offer() {
    local root="${GAP_AUDIT_ROOT:-$GAP_AUDIT_ROOT_DEFAULT}" now="${GAP_AUDIT_NOW:-$(date +%s)}"
    GAP_AUDIT_FINDINGS=""
    echo ""
    echo "==> gap audit (HIMMEL-5836)"
    _ga_check_doctor "$root" || true
    _ga_check_qmd || true
    _ga_check_semantic "$root" "$now" || true
    _ga_check_resume "$root" || true
    _ga_check_ponytail "$root" || true
    if [ -z "$GAP_AUDIT_FINDINGS" ]; then
        echo "    all clear: qmd, graphify, in-work tickets and ponytail markers show no gap."
        return 0
    fi
    echo "    checks that came back non-green:"
    printf '%s' "$GAP_AUDIT_FINDINGS"
    echo "    Run the full audit? Say yes and ask Claude to run: bash scripts/himmel-doctor.sh"
    echo "    (this offer is print-only; nothing was changed and no audit runs unattended)."
    return 0
}
