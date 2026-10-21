#!/usr/bin/env bash
# review-merge-gate.sh — shared predicate for the CR merge gate.
#
# cr_merge_gate <pr-selector> [<owner/repo>]
#   rc 0 = allow; rc 2 = block, one-line reason on stdout.
#   rc 3 = allow, but the SELECTOR did not resolve to a PR (gh pr view failed)
#          — callers that extracted the selector heuristically (the PreToolUse
#          hook) should retry once with a better-anchored selector (the cwd
#          branch) so quoted/mis-tokenized selectors cannot dodge the gate
# (/ codex-adv-1, CR round). Top-level consumers
#          treat any non-2 rc as allow.
# Who must pass is configuration (docs/configuration.md): every critics.json
#   row is `mode` hard (must pass at the head) or best-effort (only a posted,
#   open finding holds). cr_reviewer_gate below is that predicate, shared
#   with the release check; this gate reads its HOLD as a block, then adds
#   CodeRabbit's outside-diff body findings. As shipped (codex + claude hard,
#   CodeRabbit best-effort), CodeRabbit's commit-status state (pending/absent/
#   rate_limited/skipped/etc.) prints an advisory NOTE and never blocks on its
#   own; an unresolved coderabbitai review thread, or an outside-diff body
#   finding with no ledger disposition at this exact head, does.
#
#   A clone without the CodeRabbit app has the coderabbit row absent: no
#   CodeRabbit call is made (scripts/lib/cr-available.sh).
#   A config error (a critics file that does not parse, a bad mode, no hard
#   reviewer without "review": "no_code_review") BLOCKS: rc 2,
#   `cr-reviewer-gate: config error: <file>: <why>` on stdout.
#   INFRASTRUCTURE failures (gh missing, API error, no PR, parse failure) still
#   fail OPEN (rc 0/3) with a "cr-merge-gate: degraded (...) - failing open" note
#   — a broken query is not evidence of anything. The one exception: in an
#   armed clone an unreadable CR ledger holds every hard or required critic,
#   and a failed CodeRabbit read holds a hard coderabbit row.
#   CR_MERGE_GATE_OK=1 or CR_PROFILE=none skip the gate entirely (rc 0).
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).

_cmg_degrade() { echo "cr-merge-gate: degraded ($*) - failing open" >&2; }

# _cmg_prior_outside_block — operator ruling + the
# PR's real head carries no CodeRabbit review of its own, but prior head(s)
# carry posted outside-diff findings. EVERY such head governs
# (cr_body_prior_outside_heads), each finding dispositioned at the head that
# raised it — a newer prior review must not mask an older head's finding
# (mirrors check-ci's _cr_prior_outside_gate). Every blocking
# head's reason is printed on stdout; rc 2 if any blocks. Reads
# $owner/$name/$num/$head from the caller (cr_merge_gate), same dynamic-scoping
# convention as every other _cmg_* helper here.
_cmg_prior_outside_block() {
    local heads ph out msg="" rc=0
    heads=$(cr_body_prior_outside_heads "$owner" "$name" "$num" "$head") || heads=""
    if [ -z "$heads" ]; then
        echo "BLOCK: could not resolve which prior heads carry CodeRabbit's outside-diff findings on PR #$num — cannot check for a disposition; re-run."
        return 2
    fi
    while IFS= read -r ph; do
        [ -n "$ph" ] || continue
        if ! out=$(_cmg_outside_block "$ph" ""); then
            rc=2
            msg="${msg:+$msg
}$out"
        fi
    done <<<"$heads"
    [ "$rc" -eq 0 ] || echo "$msg"
    return "$rc"
}

# _cmg_outside_block <gate_head> <expected_count> — /.
# Reads + dispositions the outside-diff findings CodeRabbit posted AT
# <gate_head> — either the PR's real head, or a PRIOR head
# _cmg_prior_outside_block walks, when the real head carries no review of its
# own (best effort covers ABSENCE at that head only, never a finding
# CodeRabbit already posted at a prior one). <expected_count> is the
# reader's own header count for a format-drift cross-check; empty skips it
# (the prior-head path's own header-vs-parsed check inside the reader already
# covers it). rc 0 = allow (ALLOW note on stderr); rc 2 = block (BLOCK reason
# already echoed to stdout, same convention as every other block here).
_cmg_outside_block() {
    local gate_head="$1" expected="$2"
    local od_rows od_rc od_id od_file od_line od_n=0 od_ok=0 od_list="" extra="" prefix=""
    od_rows=$(cr_body_outside_findings "$owner" "$name" "$num" "$gate_head")
    od_rc=$?
    case "$od_rc" in
        0) ;;
        2)
            echo "BLOCK: CodeRabbit's review body on head $gate_head of PR #$num lists outside-diff findings the parser cannot fully read (format drift, cannot count) — check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
            return 2 ;;
        *)
            echo "BLOCK: CodeRabbit's review body reports outside-diff-range finding(s) on head $gate_head of PR #$num but the per-finding read failed — cannot check for a disposition; re-run."
            return 2 ;;
    esac
    if [ "$gate_head" != "$head" ]; then
        extra='   (or: --verdict fixed --reason "fixed in <sha>")'
    fi
    while IFS=$'\t' read -r od_id _ od_file od_line _; do
        [ -n "$od_id" ] || continue
        od_n=$((od_n + 1))
        if [ "$gate_head" != "$head" ]; then
            if cr_ledger_outside_dispositioned "$gate_head" "$od_id" "$od_file" "$od_line" "$head"; then
                od_ok=$((od_ok + 1))
            else
                od_list="$od_list [$od_id $od_file:$od_line]"
            fi
        else
            if cr_ledger_outside_dispositioned "$gate_head" "$od_id" "$od_file" "$od_line"; then
                od_ok=$((od_ok + 1))
            else
                od_list="$od_list [$od_id $od_file:$od_line]"
            fi
        fi
    done <<<"$od_rows"
    if [ -n "$expected" ] && [ "$od_n" -ne "$expected" ]; then
        echo "BLOCK: CodeRabbit's review body on head $gate_head of PR #$num counts $expected outside-diff finding(s) but $od_n parsed out (format drift, cannot count) — check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
        return 2
    fi
    if [ "$od_ok" -lt "$od_n" ]; then
        if [ "$gate_head" != "$head" ]; then
            prefix="head $head of PR #$num carries no CodeRabbit review (best effort, HIMMEL-3360: nothing waits or re-triggers); a prior review, at head $gate_head, "
        else
            prefix="CodeRabbit's review body "
        fi
        echo "BLOCK: ${prefix}reports $od_n outside-diff-range finding(s) on head $gate_head of PR #$num, $((od_n - od_ok)) not dispositioned:$od_list — these carry no thread to resolve. Fix them, or record an explicit disposition at head $gate_head (ledger-append.sh finding --branch <pr-branch> --model coderabbit-outside --verdict deferred --deferred-to <TICKET> --fu-class <escape|hardening|polish> --reason <why>; check-ci.sh prints the full recipe), or --verdict fixed --reason \"fixed in <sha>\"; or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated.$extra"
        return 2
    fi
    echo "ALLOW: PR #$num — CodeRabbit's review body reports outside-diff dispositioned=$od_ok (each has an explicit ledger disposition at head $gate_head)." >&2
    return 0
}

# The ONE reader for CodeRabbit's verdict. Sourced relative to this
# file so a hook can source this gate from any cwd.
# shellcheck source=scripts/lib/coderabbit-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
# every nested source is readability-checked first and a missing one
# makes THIS file's own source fail (`return 1`), so the hook's load check denies
# instead of the gate running with its helper functions undefined (fail open).
_cmg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
{ [ -r "$_cmg_dir/coderabbit-signal.sh" ] && . "$_cmg_dir/coderabbit-signal.sh"; } || return 1

# The ONE reader for CodeRabbit's review-BODY findings —
# outside-diff-range / nitpick / additional comments the thread gate below
# cannot see (S1: no thread, no isResolved, unresolvable by construction).
# shellcheck source=scripts/lib/coderabbit-body-findings.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
{ [ -r "$_cmg_dir/coderabbit-body-findings.sh" ] && . "$_cmg_dir/coderabbit-body-findings.sh"; } || return 1

# Is CodeRabbit configured here at all? Same posture as check-ci:
# this whole gate is CodeRabbit-specific, so on a repo without it the gate is a
# no-op rather than a permanent block on "absent".
# shellcheck source=scripts/lib/coderabbit-available.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
{ [ -r "$_cmg_dir/coderabbit-available.sh" ] && . "$_cmg_dir/coderabbit-available.sh"; } || return 1

# The CR-ledger evidence reader: tells the outside-diff body-
# findings gate below (stage 3) whether a given finding carries an explicit
# disposition at this exact head (deferred + tracked ticket, or disproved).
# shellcheck source=scripts/lib/review-ledger-evidence.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
{ [ -r "$_cmg_dir/review-ledger-evidence.sh" ] && . "$_cmg_dir/review-ledger-evidence.sh"; } || return 1

# _cmg_canon_nwo / _cmg_nwo_eq / _cmg_local_nwo — moved to scripts/lib/nwo.sh
#  so the CodeRabbit TRIGGER path can reuse the same "is this OUR
# repo?" answer instead of re-deriving origin-URL parsing. Names unchanged.
# shellcheck source=scripts/lib/nwo.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
{ [ -r "$_cmg_dir/nwo.sh" ] && . "$_cmg_dir/nwo.sh"; } || return 1

# Which reviewers gate this repo and how hard (critics.json + its overlay),
# and the absent-vs-unavailable vocabulary of a critic skip.
# shellcheck source=scripts/lib/critics-config.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
{ [ -r "$_cmg_dir/critics-config.sh" ] && . "$_cmg_dir/critics-config.sh"; } || return 1

# _crg_critic_states <head> <slug>... — each critic's state at <head>, read
# from the CR ledger: one `slug<TAB>state<TAB>detail` line per slug, or one
# `degraded<TAB><why>` line when the ledger cannot be read.
#   pass           an avail ok row, and no open crit/imp finding of its own
#   findings-open  open finding(s), whatever the avail rows say; detail = their ids
#   absent         a critic-skipped row whose detail matches _CCFG_ABSENT_RE
#                  (cannot run on this machine); detail = the matched phrase
#   not-selected   tier-excluded / keep-one-skipped: not picked for this PR
#   unavailable    any other refusal or failure; detail = its reason
#   not-yet-run    no avail row at the head
# A row naming `trivial-descendant of reviewed head <sha>` carries the whole
# head (clear-review-marker.sh writes it once, as model claude): a slug with no
# row of its own at <head> is read at the reviewed head instead, and a
# finding posted at <head> itself still counts. Heads, amends and tracked deferrals
# match as in cr-ledger-evidence.sh; a malformed line is a degraded read,
# never a skip. The ledger path is fixed (never env-overridable).
_crg_critic_states() {
    local head="$1" common node
    shift
    node=$(_ccfg_node) || { printf 'degraded\tnode not found\n'; return 0; }
    common=$(git rev-parse --git-common-dir 2>/dev/null) || { printf 'degraded\tnot in a git repository\n'; return 0; }
    RG_LEDGER="$common/cr-critic-scores.jsonl" RG_HEAD="$head" RG_SLUGS="$*" \
    RG_ABSENT_RE="$_CCFG_ABSENT_RE" "$node" -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
let txt;
try { txt = fs.readFileSync(e.RG_LEDGER, "utf8"); }
catch (_) { process.stdout.write("degraded\tno readable critic ledger at " + e.RG_LEDGER + "\n"); process.exit(0); }
const HEX = /^[0-9a-f]{7,40}$/;
const cache = new Map();
const resolve = (h) => {
    if (!cache.has(h)) {
        let full = null;
        try {
            full = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
                { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
        } catch (_) { full = null; }
        cache.set(h, full || null);
    }
    return cache.get(h);
};
const atHead = (o, head) => {
    const h = String(o.head || "");
    if (h === head) return true;
    if (!HEX.test(h) || !head.startsWith(h)) return false;
    return resolve(h) === head;
};
const SEP = String.fromCharCode(31), lines = txt.split("\n").filter(Boolean);
const amends = new Map();
for (const l of lines) {
    let a;
    try { a = JSON.parse(l); } catch (_) { continue; }
    if (!a || a.kind !== "amend" || !a.set || typeof a.set !== "object") continue;
    const k = [a.target_head, a.finding_id, a.artifact || "diff", a.perspective || "off"].join(SEP);
    amends.set(k, Object.assign({}, amends.get(k) || {}, a.set));
}
const recs = [];
let malformed = 0;
for (const l of lines) {
    let o;
    try { o = JSON.parse(l); } catch (_) { malformed++; continue; }
    if (!o || typeof o !== "object") { malformed++; continue; }
    if (o.kind === "amend") continue;
    if (o.kind === "finding") {
        const k = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
        if (amends.has(k)) o = Object.assign({}, o, amends.get(k));
    }
    recs.push(o);
}
if (malformed > 0) {
    process.stdout.write("degraded\t" + malformed + " malformed critic ledger line(s)\n");
    process.exit(0);
}
const ABSENT = new RegExp(e.RG_ABSENT_RE);
const CARRY = /trivial-descendant of reviewed head ([0-9a-f]{7,40})/;
const model = (o) => (typeof o.model === "string" ? o.model : "").trim();
const str = (v) => (typeof v === "string" ? v.trim() : "");
const avail = (slug, head) => recs.filter((o) => o.kind === "avail" && model(o) === slug && atHead(o, head));
const own = (rows) => rows.filter((o) => !CARRY.test(String(o.detail || "")));
const carry = recs.filter((o) => o.kind === "avail" && atHead(o, e.RG_HEAD))
    .map((o) => String(o.detail || "").match(CARRY)).find(Boolean);
const out = [];
for (const slug of e.RG_SLUGS.split(" ").filter(Boolean)) {
    let head = e.RG_HEAD;
    let rows = own(avail(slug, head));
    if (rows.length === 0 && carry) { head = resolve(carry[1]) || carry[1]; rows = own(avail(slug, head)); }
    let state, detail = "";
    const open = recs.filter((o) => o.kind === "finding" && model(o) === slug
        && (atHead(o, head) || atHead(o, e.RG_HEAD))
        && (o.severity === "crit" || o.severity === "imp") && o.verdict !== "disproved"
        && !(o.verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(str(o.deferred_to)) && str(o.reason)));
    if (open.length) {
        state = "findings-open"; detail = open.map((o) => o.finding_id || "?").join(",");
    } else if (rows.length === 0) {
        state = "not-yet-run";
    } else if (rows.some((o) => o.status === "ok")) {
        state = "pass";
    } else {
        const absent = rows.map((o) => String(o.reason || "").startsWith("critic-skipped")
            ? String(o.detail || "").match(ABSENT) : null).find(Boolean);
        const other = rows.find((o) => o.reason !== "tier-excluded" && o.reason !== "keep-one-skipped");
        if (absent) { state = "absent"; detail = absent[0]; }
        else if (other) { state = "unavailable"; detail = String(other.reason || other.status || "unknown"); }
        else { state = "not-selected"; detail = String(rows[0].reason); }
    }
    out.push([slug, state, detail.replace(/[\t\n]/g, " ")].join("\t"));
}
process.stdout.write(out.length ? out.join("\n") + "\n" : "");
'
}

# _crg_alert <slug> <head> <text> — `ALERT: <text>` on stderr, once per
# (slug, head): the stamp file in the git common dir remembers what was said.
_crg_alert() {
    local common stamp
    common=$(git rev-parse --git-common-dir 2>/dev/null) || common=""
    if [ -n "$common" ]; then
        stamp="$common/cr-reviewer-alerts"
        grep -qxF "$1 $2" "$stamp" 2>/dev/null && return 0
        printf '%s %s\n' "$1" "$2" >> "$stamp" 2>/dev/null || true
    fi
    echo "ALERT: $3" >&2
}

# _crg_coderabbit <owner> <name> <pr> <head> — the CodeRabbit github-app row's
# state, into _CRG_CR_STATE / _CRG_CR_DETAIL, its raw status word into
# _CRG_CR_RAW, a findings HOLD reason into _CRG_CR_HOLD and a failed read into
# _CRG_CR_DEG. The commit status is read BEFORE the review threads
# (coderabbit-10): once CodeRabbit has concluded, the thread set is final;
# threads-first would pass over findings posted between the two reads. A
# failed status read does not stop the thread read (codex-1): an unresolved
# thread is evidence on its own.
_crg_coderabbit() {
    local owner="$1" name="$2" num="$3" head="$4" st rl threads complete unresolved locs
    _CRG_CR_STATE=""; _CRG_CR_DETAIL=""; _CRG_CR_RAW=""; _CRG_CR_HOLD=""; _CRG_CR_DEG=""
    if st=$(cr_signal_state "$owner" "$name" "$head" </dev/null); then
        _CRG_CR_RAW="$st"
        case "$st" in
            success) _CRG_CR_STATE=pass ;;
            pending) _CRG_CR_STATE=in-progress ;;
            *)
                rl=""
                case "$st" in
                    skipped|absent|paged) rl=$(cr_signal_rate_limit "$owner" "$name" "$num" "$head" </dev/null) || rl="" ;;
                esac
                if [ "$rl" = rate_limited ]; then
                    _CRG_CR_RAW=rate_limited; _CRG_CR_STATE=unavailable; _CRG_CR_DETAIL=rate_limited
                elif [ "$st" = absent ]; then
                    _CRG_CR_STATE=not-yet-run
                else
                    _CRG_CR_STATE=unavailable; _CRG_CR_DETAIL="$st"
                fi ;;
        esac
    else
        _CRG_CR_STATE=degraded; _CRG_CR_DETAIL="status query failed"; _CRG_CR_DEG="CodeRabbit status query failed"
    fi

    # shellcheck disable=SC2016  # GraphQL variables ($owner/$name/$number) are literal here
    if ! threads=$(gh api graphql \
        -f owner="$owner" -f name="$name" -F number="$num" \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved path line comments(first:1){nodes{author{login}}}}}}}}' \
        </dev/null 2>/dev/null); then
        _CRG_CR_DEG="${_CRG_CR_DEG:+$_CRG_CR_DEG; }reviewThreads query failed"
        [ "$_CRG_CR_STATE" = pass ] && { _CRG_CR_STATE=degraded; _CRG_CR_DETAIL="threads query failed"; }
        return 0
    fi
    # Page-completeness marker (codex-adv-1): this single-page query is the
    # only thread evidence, so "zero unresolved on page one" is a pass ONLY
    # when page one was the whole story. `== false` on purpose (coderabbit
    # 980-r2): only an EXPLICIT hasNextPage:false proves completeness; jq's
    # `hasNextPage // true` would swallow a legitimate false.
    complete=$(printf '%s' "$threads" | jq -r \
        '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false' \
        2>/dev/null || echo false)
    unresolved=$(printf '%s' "$threads" | jq -r \
        '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i"))] | length' \
        2>/dev/null || true)
    if [ -z "$unresolved" ]; then
        _CRG_CR_DEG="${_CRG_CR_DEG:+$_CRG_CR_DEG; }reviewThreads parse failed"
        [ "$_CRG_CR_STATE" = pass ] && { _CRG_CR_STATE=degraded; _CRG_CR_DETAIL="threads parse failed"; }
        return 0
    fi
    # >100 threads with zero unresolved ON PAGE ONE is positive evidence of
    # threads this query never counted (coderabbit 980-r3): it holds, unlike
    # an API/parse failure. A real PR with 100+ threads is pathological.
    if [ "$unresolved" -eq 0 ] 2>/dev/null && [ "$complete" != "true" ]; then
        _CRG_CR_STATE=findings-open; _CRG_CR_DETAIL="over 100 threads"
        _CRG_CR_HOLD="PR #$num has more review threads than the gate's single page (100) — cannot certify zero unresolved CodeRabbit threads. Check threads manually, or bypass with CR_MERGE_GATE_OK=1."
    elif [ "$unresolved" -gt 0 ] 2>/dev/null; then
        locs=$(printf '%s' "$threads" | jq -r \
            '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i")) | "\(.path // "?"):\(.line // "?")"] | join(", ")' \
            2>/dev/null || true)
        _CRG_CR_STATE=findings-open; _CRG_CR_DETAIL="$unresolved thread(s)"
        _CRG_CR_HOLD="$unresolved unresolved CodeRabbit review thread(s) on PR #$num [$locs]. Fix + RESOLVE each thread (operator rule 2026-07-12), or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated."
    fi
    return 0
}

# _crg_eval <config-json> <owner> <name> <pr> <head> — cr_reviewer_gate's body
# over an already-resolved config (a review value of no_code_review is the
# caller's to handle). Same rc and output contract as cr_reviewer_gate.
_crg_eval() {
    local cfg="$1" owner="$2" name="$3" num="$4" head="$5"
    local rows slug mode req prov state detail line crit="" states="" crit_deg=""
    local table="" hard_left=0 armed=1 clone_armed="" cr_row=0 hold="" note="" summary="" deg="" disp files
    rows=$(printf '%s' "$cfg" | jq -r '.panel[] | [.slug, .mode, (.required | tostring), (.provider // "-")] | @tsv' 2>/dev/null) \
        || { echo "cr-reviewer-gate: degraded (cannot read the resolved config)" >&2; return 3; }
    while IFS=$'\t' read -r slug mode req prov; do
        [ -n "$slug" ] || continue
        if [ "$prov" = github-app ]; then cr_row=1; else crit="$crit $slug"; fi
    done <<<"$rows"
    if [ -n "$crit" ]; then
        # shellcheck disable=SC2086  # one word per slug, by construction
        states=$(_crg_critic_states "$head" $crit) || { crit_deg="critic ledger reader failed (rc=$?)"; states=""; }
        case "$states" in degraded$'\t'*) crit_deg=${states#degraded$'\t'}; states="" ;; esac
        if [ -z "$crit_deg" ]; then
            for slug in $crit; do
                printf '%s\n' "$states" | awk -F'\t' -v s="$slug" '$1 == s { f = 1 } END { exit !f }' \
                    || { crit_deg="no ledger state for $slug"; break; }
            done
        fi
    fi
    [ "$cr_row" -eq 1 ] && { cr_app_configured "$PWD" || armed=0; }

    # Each row's state before any CodeRabbit call: absent and not-selected
    # rows leave the set, except that a required row cannot be absent (it is
    # unavailable). The CodeRabbit row stays in the set whenever the app is
    # armed; it is read below.
    while IFS=$'\t' read -r slug mode req prov; do
        [ -n "$slug" ] || continue
        if [ "$prov" = github-app ]; then
            if [ "$armed" -eq 1 ]; then state=to-read; detail=""
            else state=absent; detail="CodeRabbit app not armed"; fi
        elif [ -n "$crit_deg" ]; then
            state=degraded; detail="$crit_deg"
            # An armed clone keeps a CR ledger: not being able to read it holds
            # every hard or required critic instead of failing open.
            if [ "$mode" = hard ] || [ "$req" = true ]; then
                [ -n "$clone_armed" ] || { clone_armed=0; cr_app_configured "$PWD" && clone_armed=1; }
                [ "$clone_armed" -eq 1 ] && state=unreadable
            fi
        else
            line=$(printf '%s\n' "$states" | awk -F'\t' -v s="$slug" '$1 == s { print $2 "\t" $3; exit }')
            state=${line%%$'\t'*}; detail=${line#*$'\t'}
            [ -n "$state" ] || { state=degraded; detail="no ledger state"; }
        fi
        [ "$state" = absent ] && [ "$req" = true ] && state=unavailable
        case "$state" in absent|not-selected) ;; *) [ "$mode" = hard ] && hard_left=1 ;; esac
        table="$table$slug"$'\t'"$mode"$'\t'"$prov"$'\t'"$state"$'\t'"$detail"$'\n'
    done <<<"$rows"
    [ -n "$crit_deg" ] && deg="critic ledger: $crit_deg"

    if [ "$hard_left" -eq 0 ]; then
        files=$(printf '%s' "$cfg" | jq -r '[.files.base, .files.local] | map(select(. != null)) | join(", ")' 2>/dev/null || true)
        echo "cr-reviewer-gate: config error: $files: no hard reviewer in the effective set for head $head of PR #$num (absent and not-selected rows leave it) — make one row \"mode\": \"hard\", or set \"review\": \"no_code_review\" to merge on CI alone (docs/configuration.md)."
        return 2
    fi

    case "$table" in *$'\t'to-read$'\t'*) _crg_coderabbit "$owner" "$name" "$num" "$head" ;; esac
    [ -n "${_CRG_CR_DEG:-}" ] && deg="${deg:+$deg; }$_CRG_CR_DEG"

    while IFS=$'\t' read -r slug mode prov state detail; do
        [ -n "$slug" ] || continue
        if [ "$state" = to-read ]; then
            state="$_CRG_CR_STATE"; detail="$_CRG_CR_DETAIL"
            # Read only when the clone is armed: a hard row that cannot be read holds.
            [ "$state" = degraded ] && [ "$mode" = hard ] && state=unreadable
        fi
        disp="$state${detail:+($detail)}"
        case "$state" in
            pass|absent|not-selected|degraded) ;;
            unreadable)
                hold="${hold}HOLD: $slug ($mode) cannot be read at head $head of PR #$num: $detail — this clone is armed, so a reviewer that cannot be read holds; repair the read (the CR ledger, or the GitHub query) and re-run, or bypass with CR_MERGE_GATE_OK=1."$'\n' ;;
            findings-open)
                if [ "$prov" = github-app ]; then
                    hold="${hold}HOLD: $_CRG_CR_HOLD"$'\n'
                else
                    hold="${hold}HOLD: $slug has open finding(s) at head $head of PR #$num: $detail — fix them, or record a disposition in the CR ledger (disproved, or deferred to a ticket with a reason)."$'\n'
                fi ;;
            *)
                if [ "$mode" = hard ]; then
                    hold="${hold}HOLD: $slug (hard) is $disp at head $head of PR #$num — a hard reviewer must pass at the head; re-run it, or change its mode in critics.local.json (docs/configuration.md)."$'\n'
                    [ "$state" = unavailable ] && _crg_alert "$slug" "$head" "$slug (hard) is $disp at head $head of PR #$num — it cannot review, so the PR holds until it can or its mode changes."
                else
                    disp="relaxed(${detail:-$state})"
                    if [ "$prov" = github-app ]; then
                        note="${note}NOTE: CodeRabbit $_CRG_CR_RAW on head $head of PR #$num — best effort (HIMMEL-3360), not gating; the thread + body-findings gates still apply."$'\n'
                    else
                        note="${note}NOTE: $slug $state${detail:+($detail)} on head $head of PR #$num — best effort, not gating."$'\n'
                    fi
                fi ;;
        esac
        summary="${summary:+$summary · }$slug $mode $disp"
    done <<<"$table"

    echo "cr-reviewer-gate: PR #$num head $head: $summary" >&2
    printf '%s%s' "$note" "$hold"
    [ -n "$hold" ] && return 1
    if [ -n "$deg" ]; then echo "cr-reviewer-gate: degraded ($deg)" >&2; return 3; fi
    return 0
}

# cr_reviewer_gate <pr> <head> [<owner/name>]
#   The reviewer predicate the merge gate and the release check share: does
#   every reviewer in the effective set (critics_config_resolve) let <head> of
#   PR <pr> through? <owner/name> defaults to this clone's origin.
#   rc 0 = GO (NOTE lines on stdout); rc 1 = HOLD (`HOLD: ...` lines on
#   stdout); rc 2 = config error (`cr-reviewer-gate: config error: <file>:
#   <why>` on stdout); rc 3 = degraded: a read failed and nothing held. The
#   release never takes rc 3 as GO; the merge gate fails open on it.
#   stderr: one state line (`cr-reviewer-gate: PR #N head H: codex hard pass ·
#   claude hard absent(api lane is OFF) · coderabbit best-effort
#   relaxed(rate_limited)`), degraded notes, and one `ALERT:` per (hard
#   reviewer, head) that is unavailable.
#   States: pass, findings-open, in-progress, not-yet-run, unavailable(<why>),
#   absent(<why>), not-selected, unreadable(<why>) (an armed clone cannot read
#   a hard or required row; it holds). Absent and not-selected rows leave the set (a
#   required row that is absent is unavailable instead). A hard row holds on
#   anything but pass; a best-effort row holds only on findings-open and is
#   otherwise relaxed(<state>). No hard row left in the set is a config error,
#   unless the config says "review": "no_code_review" (or CR_PROFILE=none):
#   then GO with a NOTE and no gh call.
cr_reviewer_gate() {
    local num="${1:-}" head="${2:-}" repo="${3:-}" cfg rc=0 owner name
    if [ -z "$num" ] || [ -z "$head" ]; then
        echo "cr-reviewer-gate: degraded (usage: cr_reviewer_gate <pr> <head> [<owner/name>])" >&2; return 3
    fi
    cfg=$(critics_config_resolve 2>/dev/null) || { rc=$?; cfg=$(critics_config_resolve 2>&1 >/dev/null); }
    case "$rc" in
        0) ;;
        2) echo "cr-reviewer-gate: config error: $cfg"; return 2 ;;
        *) echo "cr-reviewer-gate: degraded ($cfg)" >&2; return 3 ;;
    esac
    command -v jq >/dev/null 2>&1 || { echo "cr-reviewer-gate: degraded (jq not on PATH)" >&2; return 3; }
    if [ "$(printf '%s' "$cfg" | jq -r '.review // empty' 2>/dev/null || true)" = no_code_review ]; then
        echo "NOTE: review is no_code_review here (critics.json \"review\", or CR_PROFILE=none) — no reviewer gates head $head of PR #$num; CI alone decides."
        return 0
    fi
    [ -n "$repo" ] || repo=$(_cmg_local_nwo || true)
    case "$repo" in */*/*) repo=${repo#*/} ;; esac
    owner=${repo%%/*}; name=${repo#*/}
    if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$repo" ]; then
        echo "cr-reviewer-gate: degraded (cannot tell the repo's owner/name)" >&2; return 3
    fi
    rc=0
    _crg_eval "$cfg" "$owner" "$name" "$num" "$head" || rc=$?
    return "$rc"
}

cr_merge_gate() {
    [ "${CR_MERGE_GATE_OK:-0}" = "1" ] && return 0

    local sel="${1:-}" repo="${2:-}"

    # cr_app_configured describes THIS clone (a repo-scoped git config), so it
    # may only answer for this clone (codex-adv-2). `gh pr merge 42 --repo
    # other/thing` targets a repo we hold no availability signal for — applying
    # the local answer there would BOTH falsely block (local armed, target has no
    # CodeRabbit) and falsely pass (local disarmed, target uses it). We have no
    # signal, so we do not gate, consistent with the default-disarmed posture.
    # A foreign target is checked BEFORE the local probe so that this costs no
    # gh call in either direction.
    # Only a WELL-FORMED owner/name counts as a foreign target. A mis-tokenized
    # value — `--repo "o/r"` arriving with its quotes, a flag, a fragment — is
    # NOT a foreign repo, and must fall through to the existing rc=3 re-anchor
    # path. Short-circuiting on garbage here would mean a
    # quoted --repo SILENTLY DISABLES this gate: a worse bypass than the one the
    # foreign-target check exists to close. Both sides are canonicalized so a
    # mere spelling (case, or a HOST/ prefix) cannot make the local repo look
    # foreign and skip the gate (coderabbit-9).
    if [ -n "$repo" ]; then
        local repo_canon local_canon
        # Not a parseable repo spec -> fall through, so the rc=3 re-anchor path
        # still sees it (that is the malformed-value case above).
        if _cmg_canon_nwo "$repo"; then
            repo_canon="$_CMG_CANON"
            local_canon=""
            if _cmg_canon_nwo "$(_cmg_local_nwo || true)"; then local_canon="$_CMG_CANON"; fi
            if [ -n "$local_canon" ]; then
                _cmg_nwo_eq "$repo_canon" "$local_canon" || return 0
            else
                # Origin didn't parse (no origin remote, a file:// origin, a
                # trailing-slash URL, ...). Arming is a deliberate per-clone
                # act, so an armed-but-unparseable clone is treated as LOCAL
                # (fall through and gate) rather than silently disabled as
                # foreign (T9). An unarmed clone still exits here
                # via the same cr_app_configured check used below, preserving
                # today's unarmed behaviour.
                cr_app_configured "$PWD" || return 0
            fi
        fi
    fi
    # Which reviewers must pass, resolved before any gh call: a broken config
    # blocks, and an explicit no_code_review (CR_PROFILE=none included) spends
    # nothing. A clone without the CodeRabbit app still holds its critics to
    # their modes; only the coderabbit row goes absent.
    local cfg cfg_rc=0
    cfg=$(critics_config_resolve 2>/dev/null) || { cfg_rc=$?; cfg=$(critics_config_resolve 2>&1 >/dev/null); }
    case "$cfg_rc" in
        0) ;;
        2) echo "cr-reviewer-gate: config error: $cfg"; return 2 ;;
        *)
            if cr_app_configured "$PWD"; then
                echo "BLOCK: critics config cannot be resolved (rc=$cfg_rc: $cfg) — this clone is armed, so the reviewer gate cannot be skipped; fix node or the resolver and re-run, or bypass with CR_MERGE_GATE_OK=1."
                return 2
            fi
            _cmg_degrade "critics config unreadable: $cfg"; return 0 ;;
    esac
    if [ -z "$sel" ]; then _cmg_degrade "no PR selector"; return 0; fi
    command -v gh >/dev/null 2>&1 || { _cmg_degrade "gh not on PATH"; return 0; }
    command -v jq >/dev/null 2>&1 || { _cmg_degrade "jq not on PATH"; return 0; }
    if [ "$(printf '%s' "$cfg" | jq -r '.review // empty' 2>/dev/null || true)" = no_code_review ]; then
        echo "NOTE: review is no_code_review here (critics.json \"review\", or CR_PROFILE=none) — no reviewer gates this merge; CI alone decides." >&2
        return 0
    fi

    local meta url num head owner name
    if [ -n "$repo" ]; then
        meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    else
        meta=$(gh pr view "$sel" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    fi
    num=$(printf '%s' "$meta" | jq -r '.number // empty' 2>/dev/null || true)
    head=$(printf '%s' "$meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    url=$(printf '%s' "$meta" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -z "$num" ] || [ -z "$head" ] || [ -z "$url" ]; then _cmg_degrade "pr metadata incomplete"; return 0; fi
    # url shape: https://github.com/OWNER/NAME/pull/N
    owner=$(printf '%s' "$url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
    name=$(printf '%s' "$url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
    if [ -z "$owner" ] || [ -z "$name" ]; then _cmg_degrade "cannot parse owner/name from $url"; return 0; fi

    # 1+2) The reviewer set, through the predicate the release check shares
    # (cr_reviewer_gate): every hard reviewer must pass at this head, a
    # posted open finding holds in either mode, a best-effort CodeRabbit
    # state prints a NOTE. A HOLD blocks the merge. A degraded read (ledger,
    # status or thread query) is remembered and fails open only at the end,
    # when nothing blocked: a broken query is not evidence here (the release
    # check never fails open on it).
    local crg_out crg_rc=0 crg_degraded=0
    crg_out=$(_crg_eval "$cfg" "$owner" "$name" "$num" "$head") || crg_rc=$?
    case "$crg_rc" in
        1) printf '%s\n' "$crg_out" | sed 's/^HOLD: /BLOCK: /'; return 2 ;;
        2) printf '%s\n' "$crg_out"; return 2 ;;
        3) crg_degraded=1 ;;
    esac
    if [ -n "$crg_out" ]; then printf '%s\n' "$crg_out"; fi

    # 3) CodeRabbit review-BODY findings (S1 — see
    # cr-body-findings.sh header): outside-diff-range comments carry NO
    # thread, so every gate above is blind to them by construction. Read only
    # now that CodeRabbit has concluded and the thread set above is final —
    # same ordering rationale as (1)/(2). Read only while the coderabbit row is
    # in the config and the app is armed here.
    #
    # Fail-open/closed asymmetry is DELIBERATE here (spec §4) — this is a
    # merge HOOK, not the certifier (check-ci fails closed on the same two
    # codes). An INFRASTRUCTURE failure (rc 1: query/parse error) is
    # remembered and only fails OPEN at the very end, mirroring cr_degraded —
    # a broken query is not evidence. An anti-drift CANARY (rc 2: the body
    # SHOWS a section keyword but the count would not parse) is POSITIVE
    # evidence of an unparseable finding and BLOCKS outright, same rank as
    # outside>0 itself. `nitpick` is surfaced on the ALLOW note only
    # (the failure was invisibility, not permissiveness —
    # blocking Trivial-severity findings tanks the loop).
    local body_line body_rc outside nitpick prior_outside substantive body_degraded=0 body_nitpick=0 tok
    if cr_app_configured "$PWD" \
        && printf '%s' "$cfg" | jq -e 'any(.panel[]; .provider == "github-app")' >/dev/null 2>&1; then
        body_line=$(cr_body_findings "$owner" "$name" "$num" "$head")
        body_rc=$?
    else
        body_rc=skip
    fi
    case "$body_rc" in
        skip) ;;
        0)
            # Word-split + anchor on `case`, NOT a `.*key=` sed/grep regex: the
            # reader's line has both `outside=` and `prior_outside=`, and an
            # unanchored `.*outside=` regex greedily matches the LATTER
            # (matched the drift-canary test's own fixture during dev — a
            # real bug this reader-line shape invites). `case` patterns match
            # from the START of the token, so `outside=*` cannot match a
            # token that begins with `prior_outside=`.
            outside=""; nitpick=""; prior_outside=""; substantive=""
            for tok in $body_line; do
                case "$tok" in
                    outside=*) outside=${tok#outside=} ;;
                    nitpick=*) nitpick=${tok#nitpick=} ;;
                    prior_outside=*) prior_outside=${tok#prior_outside=} ;;
                    substantive=*) substantive=${tok#substantive=} ;;
                esac
            done
            # Validate EACH field independently, NOT the concatenation (CR #1297):
            # an empty/missing `outside` masked by the joined string (nitpick=5 ->
            # "5" passes the all-digits test) would let `[ "$outside" -gt 0 ]` below
            # error on the empty value, read as false, and the outside-diff gate
            # fail OPEN. Per-field guards fail closed (degraded) — mirrors the same
            # fix in check-ci.sh's cr_body_gate.
            _body_bad=0
            for _v in "$outside" "$nitpick" "$prior_outside" "$substantive"; do
                case "$_v" in
                    ''|*[!0-9]*) _body_bad=1 ;;
                esac
            done
            if [ "$_body_bad" -eq 1 ]; then
                body_degraded=1
            elif [ "$prior_outside" -gt 0 ] && [ "$substantive" -eq 0 ] && [ "$outside" -eq 0 ]; then
                # operator ruling: best effort covers
                # ABSENCE at THIS head only — every prior head's ALREADY-POSTED
                # outside-diff findings still govern the gate, keyed to the
                # head that actually carries them.
                _cmg_prior_outside_block || return 2
                body_nitpick="$nitpick"
            elif [ "$outside" -gt 0 ]; then
                # each outside-diff finding may carry an explicit
                # ledger disposition AT THIS EXACT HEAD (deferred + tracked
                # ticket + reason, or disproved + reason) — same reader and rule
                # as check-ci.sh. Anything undispositioned, or a list that cannot
                # be read/trusted, BLOCKS (a known outside>0 is never failed open).
                _cmg_outside_block "$head" "$outside" || return 2
                body_nitpick="$nitpick"
            else
                body_nitpick="$nitpick"
            fi
            ;;
        1)
            body_degraded=1 ;;
        2)
            echo "BLOCK: CodeRabbit's review body on head $head of PR #$num shows a finding the parser cannot count (format drift) — positive evidence of an unparseable finding. Check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
            return 2 ;;
        *)
            body_degraded=1 ;;
    esac

    # Nothing blocked. If the verdict query or the body-findings reader
    # degraded, note it — a broken query is not
    # evidence; unresolved threads and outside-diff findings are, and both
    # are already checked above.
    if [ "$crg_degraded" -eq 1 ] || [ "$body_degraded" -eq 1 ]; then
        [ "$crg_degraded" -eq 1 ] && _cmg_degrade "a reviewer read failed, see cr-reviewer-gate above"
        [ "$body_degraded" -eq 1 ] && _cmg_degrade "cr-body-findings query/parse failed"
        return 0
    fi

    # stderr, not stdout (codex CR round): both hook callers only capture +
    # print `reason=$(cr_merge_gate ...)` when it BLOCKs (rc 2) — an ALLOW-
    # path echo on stdout here would be captured into $reason and then
    # silently dropped on every allow. stderr surfaces it regardless of
    # what the caller does with stdout, same as every _cmg_degrade note above.
    if [ "$body_nitpick" -gt 0 ]; then
        echo "ALLOW: PR #$num — CodeRabbit's review body also reports nitpick=$body_nitpick (non-blocking)." >&2
    fi

    return 0
}
