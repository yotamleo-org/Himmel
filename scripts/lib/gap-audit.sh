#!/usr/bin/env bash
# gap-audit.sh — the read-only "gap audit" offer that himmel-update prints last.
# Source it, then call gap_audit_offer. It PRINTS the checks that came back
# non-green, each with a remedy, and offers the full audit; it never runs the
# audit, never writes, never fails the caller (always returns 0).
#
# Checks (all cheap, all read-only):
#   doctor rows  C50/C49/C56/C40 (qmd), C33/C8 (graphify) — reused, not redone
#   qmd          needsEmbedding backlog; collections not scanned for > 3 days
#   graphify     semantic manifest missing or older than 14 days (the graph publisher
#                only: graph-choices.js role; other stations pull this graph)
#   tickets      in-work tickets with no session/PR (next-dispatchable.sh
#                --resume-only); skipped when absent or Jira unset
#   ceilings     open ceilings ledger rows (ceiling-lookup.sh --ids --all: ids,
#                files and anchors, never row text) whose ticket is Done in the
#                Jira mirror, whose file is gone or whose anchor no longer
#                matches; silent with no lookup or no ledger file, reported as
#                not checked when the lookup cannot read the ledger
#
# Test seams: GAP_AUDIT_ROOT, GAP_AUDIT_NOW (epoch), GAP_AUDIT_DOCTOR_CMD,
# GAP_AUDIT_QMD_STATUS_FILE, GAP_AUDIT_GRAPH_OUT, GAP_AUDIT_MIRROR,
# GAP_AUDIT_RESUME_CMD (set-but-empty disables the check).
# PLATFORM GUARD: bash-only, like himmel-update.sh.

GAP_AUDIT_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
_GA_GRAPH_CHOICES="$GAP_AUDIT_ROOT_DEFAULT/scripts/himmelctl/lib/graph-choices.js"
GAP_AUDIT_FINDINGS=""
GAP_AUDIT_SKIPPED=""

_ga_skip() { GAP_AUDIT_SKIPPED="${GAP_AUDIT_SKIPPED}${GAP_AUDIT_SKIPPED:+, }$1"; }

_ga_add() { # _ga_add <area> <message> [remedy]
    GAP_AUDIT_FINDINGS="${GAP_AUDIT_FINDINGS}      · $1: $2${3:+
          → $3}
"
}

_ga_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

_ga_check_doctor() {
    local root="$1" rows json
    command -v jq >/dev/null 2>&1 || { _ga_skip "doctor rows (jq missing)"; return 0; }
    if [ -n "${GAP_AUDIT_DOCTOR_CMD:-}" ]; then
        json="$($GAP_AUDIT_DOCTOR_CMD 2>/dev/null)"
    else
        json="$(bash "$root/scripts/himmel-doctor.sh" --json --no-color --only C8,C33,C40,C49,C50,C56 2>/dev/null)"
    fi
    # the doctor may exit non-zero precisely because it found WARN/FAIL rows: judge its output, not its rc
    [ -n "$json" ] || { _ga_skip "doctor rows (no output)"; return 0; }
    rows="$(printf '%s\n' "$json" | jq -r 'select(.sev == "WARN" or .sev == "FAIL") | "\(.id)\t\(.msg)\t\(.remedy)"' 2>/dev/null)" || { _ga_skip "doctor rows (unreadable output)"; return 0; }
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
    [ -n "${text:-}" ] || { _ga_skip "qmd (no status)"; return 0; }
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
    local out="${GAP_AUDIT_GRAPH_OUT:-$1/graphify-out}" now="$2" mt age role
    [ -f "$out/graph.json" ] || return 0   # no graph on this machine: graphify is unused
    role="$(node "$_GA_GRAPH_CHOICES" role 2>/dev/null)" || role=""
    [ "$role" = publisher ] || return 0
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
    local root="$1" out rows nd="$1/scripts/handover/chief-kit/next-dispatchable.sh"
    if [ "${GAP_AUDIT_RESUME_CMD+set}" = set ] && [ -z "$GAP_AUDIT_RESUME_CMD" ]; then return 0; fi
    [ -n "${JIRA_PROJECT_KEY:-}" ] || { _ga_skip "in-work tickets (Jira not configured)"; return 0; }
    if [ "${GAP_AUDIT_RESUME_CMD+set}" = set ]; then
        out="$($GAP_AUDIT_RESUME_CMD 2>/dev/null)" || { _ga_skip "in-work tickets (detector failed)"; return 0; }
    else
        grep -q -- '--resume-only' "$nd" 2>/dev/null || { _ga_skip "in-work tickets (detector not present)"; return 0; }
        out="$(bash "$nd" --resume-only 2>/dev/null)" || { _ga_skip "in-work tickets (detector failed)"; return 0; }
    fi
    rows="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "RESUME" { printf "%s (%s, %s); ", $2, $5, $7 }')"
    [ -n "$rows" ] && _ga_add tickets "in-work with no session or open PR: $rows" "bash scripts/handover/chief-kit/next-dispatchable.sh --resume-only"
    return 0
}

_ga_check_ceilings() {
    local root="$1" mirror="${GAP_AUDIT_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}" out
    local id file anchor ticket done_rows="" gone_rows="" stale_rows=""
    [ -f "$root/scripts/ledger/ceiling-lookup.sh" ] || return 0
    out="$(cd "$root" && bash "$root/scripts/ledger/ceiling-lookup.sh" --ids --all 2>/dev/null)" || { _ga_skip "ceilings (lookup failed)"; return 0; }
    case "$out" in
        "CEILINGS: "*" open rows "*) ;;
        "CEILINGS: none open "*|"CEILINGS: not read (no ledger for "*) return 0 ;;
        "CEILINGS: not read ("*) out="${out#CEILINGS: not read (}"; _ga_skip "ceilings (${out%)})"; return 0 ;;
        *) _ga_skip "ceilings (unreadable output)"; return 0 ;;
    esac
    while IFS="$(printf '\t')" read -r id file anchor ticket; do
        case "$id" in C-[0-9]*) ;; *) continue ;; esac
        if [ ! -f "$root/$file" ]; then
            gone_rows="${gone_rows}${id} ${file} [${anchor}]; "
        elif ! grep -qF -- "$anchor" "$root/$file" 2>/dev/null; then
            stale_rows="${stale_rows}${id} ${file} [${anchor}]; "
        elif [ -n "$ticket" ] && [ -d "$mirror" ] && grep -q '^status: "Done"' "$mirror/$ticket.md" 2>/dev/null; then
            done_rows="${done_rows}${id} ${file} [${anchor}]; "
        fi
    done <<EOF
$(printf '%s\n' "$out" | sed 1d)
EOF
    [ -z "$done_rows" ] || _ga_add ceilings "open ceilings whose ticket is Done: $done_rows" "lift or re-trigger each: scripts/ledger/ceiling-add.sh set --id <id> --state lifted --note <what fixed it>"
    [ -z "$gone_rows" ] || _ga_add ceilings "open ceilings whose file is gone: $gone_rows" "close each: scripts/ledger/ceiling-add.sh set --id <id> --state obsolete --note <why>"
    [ -z "$stale_rows" ] || _ga_add ceilings "open ceilings whose anchor no longer matches: $stale_rows" "re-anchor with ceiling-add.sh add, then close the old row with ceiling-add.sh set"
    return 0
}

gap_audit_offer() {
    local root="${GAP_AUDIT_ROOT:-$GAP_AUDIT_ROOT_DEFAULT}" now="${GAP_AUDIT_NOW:-$(date +%s)}"
    GAP_AUDIT_FINDINGS=""; GAP_AUDIT_SKIPPED=""
    echo ""
    echo "==> gap audit"
    _ga_check_doctor "$root" || true
    _ga_check_qmd || true
    _ga_check_semantic "$root" "$now" || true
    _ga_check_resume "$root" || true
    _ga_check_ceilings "$root" || true
    if [ -z "$GAP_AUDIT_FINDINGS" ]; then
        if [ -n "$GAP_AUDIT_SKIPPED" ]; then
            echo "    no gap found in the checks that ran; not checked: $GAP_AUDIT_SKIPPED."
        else
            echo "    all clear: qmd, graphify, in-work tickets and the ceilings ledger show no gap."
        fi
        return 0
    fi
    echo "    checks that came back non-green:"
    printf '%s' "$GAP_AUDIT_FINDINGS"
    [ -z "$GAP_AUDIT_SKIPPED" ] || echo "    not checked: $GAP_AUDIT_SKIPPED."
    echo "    Run the full audit? Say yes and ask Claude to run: bash scripts/himmel-doctor.sh"
    echo "    (this offer is print-only; nothing was changed and no audit runs unattended)."
    return 0
}
