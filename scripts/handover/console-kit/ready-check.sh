#!/usr/bin/env bash
# scripts/handover/console-kit/ready-check.sh — mechanize the console's READY
# verification. Console A ran this same
# checklist by hand ~12 times on 2026-09-18 with zero variance; the fleet cap
# doubling (4 -> 8) doubles the READYs per hour, so it is worth a script.
#
# Read-only except the shared PR snapshot cache, which it refreshes (TTL 0:
# every run reads the PR live, never a same-head cached snapshot). Prints one
# line per check, then READY-CHECK PASS|FAIL. It does
# NOT read the three-dot diff — that judgement call stays the console's own,
# and the script says so on its last line.
#
# Usage: ready-check.sh <pr-number> <full-40-hex-head-sha>
#        ready-check.sh --only 7 <pr-number>
#   --only 7 runs ONLY check 7 — a leg's own pre-READY lint of its
#   PR body, the same code the console runs. Prints COVERAGE-LINT PASS|FAIL.
#
# Checks:
#   1. Shared snapshot: headRefOid == <head-sha> (full 40 chars); mergeStateStatus
#      == CLEAN (retries briefly on UNKNOWN — a transient GitHub computation
#      state, not a verdict).
#   2. statusCheckRollup: every check IDENTITY's LATEST run is COMPLETED with
#      conclusion SUCCESS/SKIPPED/NEUTRAL (CheckRun), or state SUCCESS
#      (StatusContext) — a superseded run (e.g. an earlier CANCELLED run
#      before a later SUCCESS) is not judged. Identity =
#      CheckRun name + workflowName when present, else StatusContext
#      context. Read via --json, never `gh pr checks` text (a green check
#      whose name contains a space mislabels under naive text parsing).
#      With the CI_GO_GATE repository variable on, a FAIL here also prints
#      the `CR-FIRST HOLD <reason> <age>` lines of scripts/lib/cr-first-release.sh
#      (read-only: no label written); variable off or unset: nothing is added.
#   3. GraphQL unresolved review threads == 0. The snapshot follows every
#      page with cursor/hasNextPage guards and the same 50-page ceiling as
#      check-ci.sh; a >100-thread PR cannot silently short-circuit to PASS.
#   4. CR ledger: <git-common-dir>/cr-critic-scores.jsonl has >=1 row for
#      <head-sha> with status "ok": a critic avail row (not claude,
#      claude-floor or codex-adv), or an evidence/judge-go row for this PR branch.
#   5. The PR's first commit carries the attestation trailers the pre-push
#      gates require, for the file classes that trip them: `Platforms
#      tested:` when the diff touches scripts/**, *.sh/.bash/.zsh/.ps1/.psm1/
#      .psd1/.cmd/.bat or **/bin/*, `Security reviewed:` when the diff
#      touches anything outside *.md/*.txt/docs/**/handovers/**. Reuses the
#      PLATFORM_RE / ATTEST_RE from scripts/hooks/check-platforms-tested.sh
#      and the TOKEN_RE from scripts/hooks/check-security-reviewed.sh
#      VERBATIM (git grep -n 'Platforms tested' -- scripts) rather than
#      re-deriving the token vocabulary or the file filters — those two
#      files carry the history of why each regex looks the way it does.
#   6. Every commit subject in the PR carries a ticket ID, using the same
#      pattern scripts/hooks/check-commit-msg.sh derives (TICKET_ID_PATTERN,
#      else "${JIRA_PROJECT_KEY}-[0-9]+", else a bare "#123" reference) —
#      except a commit with more than one parent (a real merge, e.g. a leg's
#      `Merge remote-tracking branch 'origin/main' into <branch>`), mirroring
#      scripts/ci/check-commit-range.sh's `git rev-list --no-merges`. Parent
#      count, not subject text, is the exemption signal.
#
#   7. Ticket coverage: the PR body carries a `## Ticket coverage`
#      section, one list line per ask, each `done` or `deferred → HIMMEL-<n>`
#      (`->` accepted). FAIL on a missing/empty section, an unmarked line, a
#      deferred key that does not exist or is already Done/Closed/Resolved/
#      Won't Do, or is neither residual-labelled, older than the PR's own
#      ticket, nor linked (either direction, any type) from it. The deferral
#      keys must also equal the CR ledger's deferred_to rows for the PR head
#      (or for the reviewed head a same-branch trivial-descendant row names).
#      A Jira error reads UNKNOWN and fails — never a PASS.
#   9. Plugin versions change only in a release cut (a PR that changes the
#      root VERSION file; same rule as check-plugin-drift.sh --bump-required).
#      Any other PR must leave every plugin version it touches as it is at the
#      merge-base with origin/main. A release cut must version every plugin it
#      touches strictly above CURRENT origin/main's manifest (two cuts raising
#      to the same version merge CLEAN). Fetches origin/main and the PR
#      head (refs/pull/<n>/head) into the caller's repo; a PR touching no
#      plugin never reaches git. Any fetch/read failure FAILs.
#  10. Workflow dispatch: every .github/workflows/*.yml the PR
#      changes needs a completed, successful workflow_dispatch run at the PR
#      head sha (`gh run list --workflow <wf> --event workflow_dispatch
#      --commit <head>`), since ci.yml has no push trigger and the mode main
#      runs is otherwise never tested pre-merge. The FAIL line prints the exact
#      `gh workflow run` command. A dispatch run that FAILED at the head still
#      passes, as a PRE-EXISTING line, when every one of its failed jobs also
#      failed in the default branch's latest completed scheduled/push run of the
#      same workflow; a job red only on the PR still FAILs and is named. A head
#      with no dispatch run of its own passes the same way on a failed dispatch
#      run of the PR branch at an ANCESTOR of the head, when every file the PR
#      changes is the same blob at that ancestor and at the head (the head only
#      merges main forward), including the old path of every rename; the PASS
#      line names the ancestor sha and run id.
#      The PASS line carries the dispatch run ids. macos-cadence.yml also passes on a
#      dispatch run at the head that names its suites (run-name `macos-cadence
#      suites: <paths>`, the workflow's `suites` input) when the run's log shows
#      `[PASS] <suite>` for EVERY named suite, however red the rest of the run is;
#      the PASS line prints each suite. A named suite that failed or never ran
#      FAILs and is named. A changed workflow with no workflow_dispatch
#      trigger FAILs unless listed in WF_DISPATCH_EXEMPT below. Non-workflow
#      PRs are unaffected.
#  11. Added-but-unwired: every file the PR ADDS (status A only, so existing debt
#      never fails) that is a hook (scripts/hooks/*), a script (scripts/** with
#      an exec bit or a .sh/.mjs/.js/.ts/.py name), a skill (SKILL.md) or a suite
#      (test-*.sh, *.test.*) must be reached by some wiring at the PR head. What
#      counts as wired per kind is documented in
#      scripts/testing/check-added-unwired.sh, which this item calls. Fixture
#      paths are standalone by design.
#
# 12. Trust path: trust_path_check (scripts/lib/go-gate.sh, shared with
#      merge-on-green and ready-go) against the PR's files and the default
#      branch's scripts/ci/ci-trust-paths.txt. Prints `TRUST-PATH: yes|no` just
#      before the READY-CHECK line; go.sh refuses a plain GO on `yes`. A refusal
#      (unreadable list, unresolvable default branch, moved head) FAILs and prints
#      no TRUST-PATH line. READY_CHECK_ANCHOR (tests) replaces the harness anchor.
#
# Owner/repo are derived from `gh repo view --json owner,name`, never hard-
# coded (so this runs the same in any clone/fork). It writes nothing — no
# ledger rows, no GO files, no PR comments.
#
# Exit codes:
#   0 — READY-CHECK PASS
#   1 — READY-CHECK FAIL (one or more checks failed)
#   2 — usage, or cannot evaluate (gh/jq missing, repo/PR unreadable)
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as go.sh. No mapfile.
set -u

usage() {
    echo "usage: ready-check.sh <pr-number> <full-40-hex-head-sha>" >&2
    echo "       ready-check.sh --only 7 <pr-number>   (ticket-coverage lint, for a leg before READY)" >&2
}

ONLY7=0
if [ "${1:-}" = "--only" ]; then
    if [ "$#" -ne 3 ] || [ "$2" != "7" ]; then
        usage
        echo "ready-check: --only takes exactly '7 <pr-number>' (the only check a leg can run alone)" >&2
        exit 2
    fi
    ONLY7=1
    PR="$3"; SHA=""
elif [ "$#" -ne 2 ]; then
    usage
    exit 2
else
    PR="$1"; SHA="$2"
fi

case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "ready-check: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$ONLY7" -eq 0 ] && { [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; }; then
    usage
    echo "ready-check: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2
    exit 2
fi

GH="${GH_CMD:-gh}"
# Every call below is a read: with no GH_CMD seam they ride the read-only token.
GH_READ_LIB="$(cd "$(dirname "$0")/../../lib" && pwd)/gh-read.sh"
if [ -z "${GH_CMD:-}" ] && [ -f "$GH_READ_LIB" ]; then
    # shellcheck source=scripts/lib/gh-read.sh
    . "$GH_READ_LIB"
    gh_read_init
    GH="$GH_READ_LIB"
fi
if ! command -v "$GH" >/dev/null 2>&1; then
    echo "ready-check: gh not found on PATH" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ready-check: jq not found on PATH" >&2
    exit 2
fi

# one call carries the default branch too (check 12), so the GraphQL budget holds
nwo=$("$GH" repo view --json owner,name,defaultBranchRef --jq '"\(.owner.login)/\(.name) \(.defaultBranchRef.name // "")"' 2>/dev/null)
tp_branch=""
case "$nwo" in *" "*) tp_branch="${nwo#* }" ;; esac
nwo="${nwo%% *}"
if [ -z "$nwo" ]; then
    echo "ready-check: cannot resolve owner/repo (gh repo view --json owner,name failed)" >&2
    exit 2
fi
owner="${nwo%%/*}"
repo="${nwo#*/}"

RESULT=0
mark_fail() { RESULT=1; }
# crf_hold_note — with the CI_GO_GATE switch on, say why the heavy CI has not run at
# this head: the CR-FIRST HOLD lines of the release lib, read-only (no
# label, no ledger line). Switch off or unset: prints nothing, check 2 is unchanged.
crf_hold_note() {
    local lib; lib="$(cd "$(dirname "$0")/../../lib" && pwd)/cr-first-release.sh"
    [ -r "$lib" ] || return 0
    (
        # shellcheck source=../../lib/cr-first-release.sh
        . "$lib" 2>/dev/null || exit 0
        cr_first_switch_on "$nwo" || exit 0
        CR_FIRST_READONLY=1
        export CR_FIRST_READONLY
        cr_first_release "$PR" "$SHA" "$nwo" 2>/dev/null </dev/null | sed 's/^/       /'
    ) || true
}
SNAPSHOT_SCRIPT="$(cd "$(dirname "$0")/../../lib" && pwd)/gh-pr-snapshot.sh"
snapshot=""
if [ "$ONLY7" -eq 0 ]; then
    snapshot=$(GH_CMD="$GH" bash "$SNAPSHOT_SCRIPT" "$nwo" 0 "$PR" 2>/dev/null) || snapshot=""
fi

if [ "$ONLY7" -eq 0 ]; then

# ── 1. head + mergeStateStatus ──────────────────────────────────────────────
attempt=0
head_now=""
mss=""
while [ "$attempt" -lt 5 ]; do
    pv=$(printf '%s' "$snapshot" | jq -r '.[0] | "\(.headRefOid) \(.mergeStateStatus)"' 2>/dev/null)
    head_now="${pv%% *}"
    mss="${pv#* }"
    [ "$mss" = "UNKNOWN" ] || break
    attempt=$((attempt + 1))
    sleep 1
    if [ "$attempt" -lt 5 ]; then
        snapshot=$(GH_CMD="$GH" bash "$SNAPSHOT_SCRIPT" "$nwo" 0 "$PR" 2>/dev/null) || snapshot=""
    fi
done
# The rollup is judged before row 1: UNSTABLE is accepted there only when
# every non-green entry is a listed non-gating context (lib/non-gating-contexts.txt).
# shellcheck source=../../lib/non-gating-contexts.sh
ng_json='[]'
if . "$(cd "$(dirname "$0")/../../lib" && pwd)/non-gating-contexts.sh" 2>/dev/null; then
    ng_json=$(ngc_json)
fi
rollup=$(printf '%s' "$snapshot" | jq -c '.[0].statusCheckRollup' 2>/dev/null)
total=0
gated=0
bad=""
skipped=""
if [ -n "$rollup" ] && [ "$rollup" != "null" ]; then
    # Judge each check IDENTITY by its LATEST run, not any matching row — a
    # superseded CANCELLED run must not fail a check whose later run at the
    # same head is green (evidence: PR #1317's pr-title-lint
    # CANCELLED 08:19:58Z then SUCCESS 08:26:47Z). Identity = CheckRun `name`
    # plus `workflowName` when present, else StatusContext `context`. Latest
    # = greatest startedAt/completedAt (CheckRun) or createdAt/startedAt
    # (StatusContext), falling back to the row's array position when neither
    # timestamp is present. A run with no timestamp at all (e.g. QUEUED,
    # not yet started) has no completed/started time to compare, but it can
    # only exist because GitHub created it after every already-timestamped
    # run for that identity — so it always outranks them, never the reverse.
    # An entry with no identifiable name is judged alone — it never merges
    # into another group (fail closed).
    grouped=$(printf '%s' "$rollup" | jq -c --argjson ng "$ng_json" '
        def key_of(e):
            if e.name == null then "unk:\(e.idx)"
            elif e.is_checkrun then "cr:\(e.name)\u0001\(e.workflow)"
            else "sc:\(e.name)" end;
        [ to_entries[] |
            .value as $row | .key as $idx |
            ($row | has("conclusion")) as $is_checkrun |
            {
                idx: $idx,
                is_checkrun: $is_checkrun,
                name: (if $is_checkrun then ($row.name // $row.context) else ($row.context // $row.name) end),
                workflow: ($row.workflowName // ""),
                ts: (if $is_checkrun then ($row.startedAt // $row.completedAt // null)
                     else ($row.createdAt // $row.startedAt // null) end),
                ok: (if $is_checkrun then
                        ($row.status == "COMPLETED" and ($row.conclusion == "SUCCESS" or $row.conclusion == "SKIPPED" or $row.conclusion == "NEUTRAL"))
                     else
                        ($row.state == "SUCCESS")
                     end),
                detail: (if $is_checkrun then (($row.status // "?") + "/" + ($row.conclusion // "null"))
                         else ($row.state // "?") end)
            }
        ]
        | map(.key = key_of(.))
        | map(.sort_key = [(.ts == null), (.ts // .idx)])
        | group_by(.key)
        | map(max_by(.sort_key))
        | map(.listed = (.is_checkrun | not) and (.name != null and (.name as $n | $ng | index($n)) != null))
        | {total: length,
           gated: (map(select(.listed | not)) | length),
           bad: (map(select((.ok | not) and (.listed | not))) | map("\(.name // "?")=\(.detail)") | join(", ")),
           skipped: (map(select((.ok | not) and .listed)) | map("\(.name)=\(.detail)") | join(", "))}
    ' 2>/dev/null)
    total=$(printf '%s' "$grouped" | jq -r '.total // 0' 2>/dev/null)
    gated=$(printf '%s' "$grouped" | jq -r '.gated // 0' 2>/dev/null) # swallow-ok: an unreadable count reads 0, which fails row 2 as no gating checks
    bad=$(printf '%s' "$grouped" | jq -r '.bad // empty' 2>/dev/null)
    skipped=$(printf '%s' "$grouped" | jq -r '.skipped // empty' 2>/dev/null) # swallow-ok: an unreadable list is empty, so nothing is reported as skipped
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$gated" in ''|*[!0-9]*) gated=0 ;; esac
fi

if [ -z "$pv" ]; then
    echo "[FAIL] 1. gh pr view #$PR --repo $nwo failed — cannot read headRefOid/mergeStateStatus"
    mark_fail
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "CLEAN" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=CLEAN"
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "UNSTABLE" ] && [ "$gated" -gt 0 ] && [ -z "$bad" ] && [ -n "$skipped" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=UNSTABLE with only non-gating checks not green ($skipped)"
else
    echo "[FAIL] 1. head=$head_now (want $SHA), mergeStateStatus=$mss (want CLEAN)"
    mark_fail
fi

# ── 2. statusCheckRollup ─────────────────────────────────────────────────────
if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    echo "[FAIL] 2. statusCheckRollup unreadable (gh pr view --json statusCheckRollup failed)"
    mark_fail
else
    # A listed non-gating context is skipped; with nothing else reported there
    # is no real check to pass on, so it counts as no checks.
    if [ "$gated" -eq 0 ]; then
        echo "[FAIL] 2. statusCheckRollup: no checks reported yet (0 entries — CI may not have registered)"
        crf_hold_note
        mark_fail
    elif [ -z "$bad" ] && [ -n "$skipped" ]; then
        echo "[PASS] 2. statusCheckRollup: $gated/$gated gating checks completed SUCCESS/SKIPPED/NEUTRAL; non-gating skipped: $skipped"
    elif [ -z "$bad" ]; then
        echo "[PASS] 2. statusCheckRollup: $total/$total checks completed SUCCESS/SKIPPED/NEUTRAL"
    else
        echo "[FAIL] 2. statusCheckRollup: not-green — $bad"
        crf_hold_note
        mark_fail
    fi
fi

# ── 3. unresolved review threads (paginated, mirrors scripts/check-ci.sh) ──
threads_ok=1
unresolved=$(printf '%s' "$snapshot" | jq -er '.[0].reviewThreads.nodes | select(type == "array") | [.[] | select(.isResolved | not)] | length' 2>/dev/null) || {
    echo "[FAIL] 3. review-thread GraphQL query failed"
    threads_ok=0
}
if [ "$threads_ok" -eq 1 ]; then
    if [ "$unresolved" -eq 0 ]; then
        echo "[PASS] 3. unresolved review threads = 0"
    else
        echo "[FAIL] 3. unresolved review threads = $unresolved"
        mark_fail
    fi
else
    mark_fail
fi

# ── 4. CR ledger row for this head with status ok ───────────────────────────
common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
if [ -z "$common_dir" ]; then
    echo "[FAIL] 4. cannot resolve git-common-dir (git rev-parse --git-common-dir failed)"
    mark_fail
else
    ledger="$common_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "[FAIL] 4. CR ledger not found at $ledger"
        mark_fail
    else
        # `jq -R 'fromjson?'` parses one JSON value per line and skips a
        # malformed line rather than aborting the whole read (a plain `jq -s`
        # slurp would die on the first bad line in a 7000+ line ledger).
        ledger_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null)
        n=$(jq -R -r --arg h "$SHA" --arg b "$ledger_branch" '
            fromjson? | select(.head == $h and .status == "ok") |
            select((.kind == "avail" and (.model | type) == "string" and .model != ""
                    and .model != "claude" and .model != "claude-floor" and .model != "codex-adv")
                or ((.kind == "evidence" or .kind == "judge-go") and $b != "" and .branch == $b)) |
            .head' "$ledger" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${n:-0}" -ge 1 ]; then
            echo "[PASS] 4. CR ledger: $n row(s) for $SHA with status=ok"
        else
            echo "[FAIL] 4. CR ledger: no critic avail or branch-bound evidence/judge-go row for $SHA with status=ok ($ledger)"
            mark_fail
        fi
    fi
fi

# ── commits (shared by checks 5 and 6) ──────────────────────────────────────
commits_json=$(printf '%s' "$snapshot" | jq -c '.[0].commits' 2>/dev/null)
files_json=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null) || files_json=""  # swallow-ok: a failed or partial read is an empty list, which checks 5, 9, 10 and 11 fail closed on

if [ -z "$commits_json" ] || [ "$commits_json" = "null" ]; then
    echo "[FAIL] 5. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
    echo "[FAIL] 6. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
else
    # ── 5. first-commit attestation trailers ────────────────────────────────
    # PLATFORM_RE / ATTEST_RE verbatim from scripts/hooks/check-platforms-tested.sh
    PLATFORM_RE='(linux|windows|macos|ubuntu|debian|fedora|arch|mac|darwin|wsl|posix|gitbash|git-bash|powershell|pwsh)'
    ATTEST_RE="^[[:space:]]*Platforms tested:[[:space:]]*${PLATFORM_RE}([^[:alnum:]]|$)"
    # TOKEN_RE verbatim from scripts/hooks/check-security-reviewed.sh
    TOKEN_RE='(manual|claude-code-security-review|pr-review-toolkit|ad-hoc)([[:space:]]|$|[.,;])'
    SEC_RE="^[[:space:]]*Security reviewed:[[:space:]]*${TOKEN_RE}"

    first_msg=$(printf '%s' "$commits_json" | jq -r '.[0].messageHeadline + "\n\n" + (.[0].messageBody // "")' 2>/dev/null)

    if [ -z "$files_json" ]; then
        echo "[FAIL] 5. cannot read PR files (gh api .../pulls/$PR/files failed or returned nothing)"
        mark_fail
    else
        # Markdown/text is never a script, even under scripts/
        # (a docs-only README edit could otherwise never get a GO).
        sensitive=$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$' | grep -E '(\.(sh|bash|zsh|ps1|psm1|psd1|cmd|bat)$|^scripts/|(^|/)bin/[^/]+$)' || true)
        non_docs=$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)

        need_plat=0; [ -n "$sensitive" ] && need_plat=1
        need_sec=0; [ -n "$non_docs" ] && need_sec=1

        plat_ok=1; [ "$need_plat" -eq 1 ] && { echo "$first_msg" | grep -qiE "$ATTEST_RE" || plat_ok=0; }
        sec_ok=1; [ "$need_sec" -eq 1 ] && { echo "$first_msg" | grep -qiE "$SEC_RE" || sec_ok=0; }

        if [ "$plat_ok" -eq 1 ] && [ "$sec_ok" -eq 1 ]; then
            echo "[PASS] 5. first commit: Platforms tested (needed=$need_plat), Security reviewed (needed=$need_sec) — attested where needed"
        else
            [ "$plat_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Platforms tested:' (diff touches scripts/shell files)"
            [ "$sec_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Security reviewed:' (diff touches non-docs code)"
            mark_fail
        fi
    fi

    # ── 6. every commit subject carries a ticket ID ─────────────────────────
    # Same config source as check-commit-msg.sh: load TICKET_ID_PATTERN /
    # JIRA_PROJECT_KEY from the primary checkout's .env (live env wins) —
    # without this, a fresh shell with nothing exported always falls through
    # to the bare "#123" pattern and flags every "[TICKET-1234]"-style subject.
    RC_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=../../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    if . "$RC_SCRIPT_DIR/../../lib/load-dotenv.sh" 2>/dev/null; then
        # pin to this script's OWN checkout, never the caller's
        # CWD repo (load_dotenv with no --root resolves via the process CWD's
        # git repo — see bank-preflight.sh for the failure mode).
        load_dotenv --root "$(_load_dotenv_primary_for "$RC_SCRIPT_DIR/../../..")" TICKET_ID_PATTERN JIRA_PROJECT_KEY || true
    fi
    TICKET_PATTERN="${TICKET_ID_PATTERN:-}"
    if [ -z "$TICKET_PATTERN" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
        ESCAPED_KEY=$(printf '%s' "$JIRA_PROJECT_KEY" | sed 's/[.[\*^$]/\\&/g')
        TICKET_PATTERN="${ESCAPED_KEY}-[0-9]+"
    fi
    TICKET_PATTERN="${TICKET_PATTERN:-(^|[^0-9A-Za-z_])#[0-9]+([^0-9A-Za-z_]|$)}"

    # Parent counts ride the shared snapshot; real merge commits stay exempt.
    merge_oids=$(printf '%s' "$commits_json" | jq -r '.[] | select(.parents.totalCount > 1) | .oid' 2>/dev/null)

    missing=$(printf '%s' "$commits_json" | jq -r --arg merges "$merge_oids" '
        ($merges | split("\n") | map(select(length > 0))) as $m
        | .[] | select((.oid // "") as $o | ($m | index($o)) == null)
        | .messageHeadline
    ' 2>/dev/null | grep -vE "$TICKET_PATTERN" || true)
    if [ -z "$missing" ]; then
        echo "[PASS] 6. every commit subject carries a ticket ID"
    else
        echo "[FAIL] 6. commit subject(s) missing a ticket ID: $(printf '%s' "$missing" | tr '\n' ';' | sed 's/;$//')"
        mark_fail
    fi
fi
fi  # ONLY7 == 0: checks 1-6

# ── 7. ticket coverage ────────────────────────────────────────
# A PR can close its ticket Done with asks undone. The
# body must carry a `## Ticket coverage` section, one list line per ask of each
# cited ticket, each marked `done` or `deferred → <KEY>` (`->` also accepted).
# Whether a line's "done" is TRUE stays the console's diff read; this check
# makes an unaccounted ask structurally visible and a deferral real: every
# deferred key must exist and still be open, and the deferral keys must equal
# the CR ledger's deferred_to rows for the PR head, or for the reviewed head a
# same-branch trivial-descendant row names. A Jira error reads UNKNOWN and
# fails — never a PASS. JIRA_CMD overrides the CLI (tests), like GH_CMD.
jira_run() {
    if [ -n "${JIRA_CMD:-}" ]; then
        "$JIRA_CMD" "$@" 2>&1
    else
        cov_primary=$(cd "$(dirname "$0")" && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)
        node "$cov_primary/scripts/jira/dist/index.js" "$@" 2>&1
    fi
}

jira_get() { jira_run get "$1" --json; }

# `links <KEY>` rows are tab-separated, with inward=<KEY> and outward=<KEY> fields.
jira_links() { jira_run links "$1"; }

# cov_linked <own-key> <target-key>: the PR's own ticket has an issue link to the target, either direction, any type.
# Returns 0 linked, 1 not linked (or no own ticket), 2 the links lookup failed.
cov_linked() {
    [ -n "$1" ] && [ "$1" != "$2" ] || return 1
    cov_links_out=$(jira_links "$1") || return 2
    printf '%s\n' "$cov_links_out" | awk -F'\t' -v t="$2" '{ for (i = 1; i <= NF; i++) if ($i == "inward=" t || $i == "outward=" t) f = 1 } END { exit !f }'
}

# cov_ledger_keys <ledger> <head> <pr-branch>: the tickets the CR ledger defers findings to at <head>, one upper-case key per line.
# Findings of a reviewed head count too when a trivial-descendant row of <pr-branch> for <head> names that reviewed head.
# A finding is identified by its key and original head, and a later row for the same identity replaces the earlier one.
# Its effective row is its own row with every amend written after it against that original head merged over it, in file
# order (an amend's set.head re-keys the finding, and later amends keep the original head as their target_head); a finding
# whose own head is not <head> takes only amends of its branch or without a branch (fail-closed; review-ledger-evidence.sh
# merges every matching amend). The finding counts at <head> when its effective head matches, and only an effective verdict of deferred counts.
# A head matches when either spelling is a prefix of the other.
# A missing ledger is an empty set (check 4 owns that failure); an unreadable one returns 1.
cov_ledger_keys() {
    [ -f "$1" ] || return 0
    cov_led_out=$(jq -R -n -r --arg h "$2" --arg pb "${3:-}" '
        def hm($x; $y): ($x | type == "string") and ($y | type == "string") and ($x | length >= 7) and ($y | length >= 7) and (($x | ascii_downcase) as $a | ($y | ascii_downcase) as $b | ($a | startswith($b)) or ($b | startswith($a)));
        def fk($r): [$r.finding_id // "?", $r.artifact // "diff", $r.perspective // "off"] | join("|");
        def vd($o): $o | {verdict, deferred_to} | with_entries(select(.value != null));
        [inputs | fromjson? | select(type == "object")] | to_entries | map(.value + {_ln: .key}) as $rows
        | def ak($r; $x): fk($r) + "|" + ($x[0:7] | ascii_downcase);
        [$rows[] | select(.kind == "avail" and $pb != "" and .branch == $pb and (.head | type == "string") and hm(.head; $h) and (.detail | type == "string"))
            | {branch, rev: (.detail | capture("^trivial-descendant of reviewed head (?<r>[0-9a-fA-F]{7,40}) ").r? // empty)}] as $desc
        | def at_head($f; $e): hm($e.head; $h) or any($desc[]; .branch == $f.branch and hm($e.head; .rev));
        (reduce ($rows[] | select(.kind == "amend" and (.set | type == "object") and (.target_head | type == "string") and (.target_head | length >= 7))) as $a ({}; .[ak($a; $a.target_head)] += [$a])) as $amends
        | reduce ($rows[] | select(.kind == "finding" and (.head | type == "string") and (.head | length >= 7))) as $f ({};
            (reduce (($amends[ak($f; $f.head)] // [])[] | select(._ln > $f._ln and hm(.target_head; $f.head) and (hm($f.head; $h) or .branch == null or .branch == $f.branch))) as $a ($f; . + $a.set)) as $e
            | .[ak($f; $f.head)] = (if at_head($f; $e) then vd($e) else {} end))
        | .[] | select(.verdict == "deferred" and (.deferred_to | type == "string") and (.deferred_to | test("^[A-Za-z][A-Za-z0-9]*-[0-9]+$")))
        | .deferred_to | ascii_upcase' "$1") || return 1
    printf '%s\n' "$cov_led_out" | sort -u
}

cov_shape_help() {
    echo "       accepted shape, one line per ask, marker LAST with nothing after it (no trailing prose, parentheses or links):"
    echo "         - <ask>: done"
    echo "         - <ask>: deferred → HIMMEL-<n>"
    echo "       (-> is accepted for →; a trailing . or bold is fine). Put any explanation BEFORE the marker."
}

if [ "$ONLY7" -eq 1 ]; then
    cov_body=$("$GH" pr view "$PR" --repo "$nwo" --json body --jq '.body' 2>/dev/null | tr -d '\r')
else
    cov_body=$(printf '%s' "$snapshot" | jq -r '.[0].body' 2>/dev/null | tr -d '\r')
fi
cov_section=$(printf '%s\n' "$cov_body" | awk '
    /^##[ \t]+[Tt]icket [Cc]overage[ \t]*$/ { f = 1; next }
    f && /^#/ { exit }
    f')
cov_lines=$(printf '%s\n' "$cov_section" | grep -E '^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]' || true)
if [ -z "$cov_lines" ]; then
    echo "[FAIL] 7. PR body has no '## Ticket coverage' section with list lines (one per ask: done | deferred → HIMMEL-<n>)"
    cov_shape_help
    mark_fail
else
    cov_bad=""; cov_shape=0; cov_body_keys=""
    # A deferral must land on a residual-verb ticket or one that predates this PR's own.
    # ponytail: key order stands for creation order (the branch name's first key is the
    # PR's ticket; the title is author text and not read); upgrade: compare Jira's created to the first commit date once
    # `jira get` fetches created.
    cov_own=""
    if printf '%s\n' "$cov_lines" | grep -qiE 'deferred'; then
        cov_own=$("$GH" pr view "$PR" --repo "$nwo" --json headRefName --jq '.headRefName' 2>/dev/null | grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]' || true) # swallow-ok: an unreadable branch leaves cov_own empty, so only a residual label passes
    fi
    while IFS= read -r cov_line; do
        [ -n "$cov_line" ] || continue
        cov_def=$(printf '%s\n' "$cov_line" | grep -ioE 'deferred[[:space:]]*(→|->)[^[:alnum:]]*[A-Za-z][A-Za-z0-9]*-[0-9]+[^[:alnum:]]*$' || true)
        if [ -n "$cov_def" ]; then
            cov_key=$(printf '%s\n' "$cov_def" | grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | tr '[:lower:]' '[:upper:]')
            if cov_out=$(jira_get "$cov_key"); then
                cov_status=$(printf '%s\n' "$cov_out" | jq -r '.fields.status.name // empty' 2>/dev/null || true) # swallow-ok: unparseable output leaves the status empty, which reads UNKNOWN below
                cov_canon=$(printf '%s\n' "$cov_out" | jq -r '(.key // empty) | ascii_upcase' 2>/dev/null || true) # swallow-ok: unparseable output leaves the key empty, which reads UNKNOWN below
                [ -z "$cov_canon" ] || cov_key="$cov_canon"
                if [ -z "$cov_canon" ]; then
                    cov_bad="$cov_bad; $cov_key UNKNOWN (jira returned no key)"
                elif [ -z "$cov_status" ]; then
                    cov_bad="$cov_bad; $cov_key UNKNOWN (jira returned no status)"
                elif printf '%s\n' "$cov_status" | grep -qiE '^(done|closed|resolved|won.?t do)$'; then
                    cov_bad="$cov_bad; $cov_key already $cov_status"
                elif [ "$cov_key" = "$cov_own" ]; then
                    cov_bad="$cov_bad; $cov_key is the PR's own ticket and cannot be its own deferral target"
                elif ! printf '%s\n' "$cov_out" | jq -e '(.fields.labels // []) | any(. == "residual")' >/dev/null 2>&1 \
                    && ! { [ -n "$cov_own" ] && [ "${cov_key%-*}" = "${cov_own%-*}" ] && [ "${cov_key##*-}" -lt "${cov_own##*-}" ]; } \
                    && ! { cov_linked "$cov_own" "$cov_key" && cov_rc=0 || cov_rc=$?; [ "$cov_rc" -eq 0 ]; }; then
                    if [ "$cov_rc" -eq 2 ]; then
                        cov_bad="$cov_bad; $cov_key UNKNOWN (jira links failed for $cov_own)"
                    else
                        cov_bad="$cov_bad; $cov_key was made by a raw jira create (no 'residual' label, not older than ${cov_own:-the PR ticket}, not linked from it) - file it with: jira create --residual-of <parent> --fu-class <c> --class <id>"
                    fi
                fi
                cov_body_keys="$cov_body_keys $cov_key"
            elif printf '%s\n' "$cov_out" | grep -qiE '404|does not exist'; then
                cov_bad="$cov_bad; $cov_key does not exist"
            else
                cov_bad="$cov_bad; $cov_key UNKNOWN (jira get failed)"
            fi
        elif ! printf '%s\n' "$cov_line" | grep -qiE '(^|[^[:alnum:]])done[^[:alnum:]]*$' \
            || printf '%s\n' "$cov_line" | grep -qiE '(not|n.t)[[:space:]]+done'; then
            cov_bad="$cov_bad; unmarked line: $(printf '%s' "$cov_line" | cut -c1-160)"
            cov_shape=1
        fi
    done <<EOF
$cov_lines
EOF
    # The ledger's deferrals at the PR head and the body's deferral lines must name the same tickets.
    cov_head="$SHA"
    if [ "$ONLY7" -eq 1 ]; then
        cov_head=$("$GH" pr view "$PR" --repo "$nwo" --json headRefOid --jq '.headRefOid' 2>/dev/null | tr -d '\r') || cov_head="" # swallow-ok: an unreadable head is reported below
    fi
    if [ -z "$cov_head" ]; then
        cov_bad="$cov_bad; cannot read the PR head, so the CR ledger's deferrals cannot be compared"
    else
        cov_common=$(git rev-parse --git-common-dir 2>/dev/null) || cov_common="" # swallow-ok: no repo reads as no ledger, so a body deferral fails below
        cov_h12=$(printf '%.12s' "$cov_head")
        if [ "$ONLY7" -eq 1 ]; then
            cov_pr_branch=$("$GH" pr view "$PR" --repo "$nwo" --json headRefName --jq '.headRefName' 2>/dev/null | tr -d '\r') || cov_pr_branch="" # swallow-ok: an unreadable branch follows no trivial-descendant row, so a reviewed-head deferral fails below
        else
            cov_pr_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null) || cov_pr_branch="" # swallow-ok: same fallback as above
        fi
        if cov_led_out=$(cov_ledger_keys "$cov_common/cr-critic-scores.jsonl" "$cov_head" "$cov_pr_branch"); then
            cov_led_keys=$(printf '%s\n' "$cov_led_out" | tr '\n' ' ')
            for cov_k in $cov_led_keys; do
                case " $cov_body_keys " in
                    *" $cov_k "*) ;;
                    *) cov_bad="$cov_bad; $cov_k is deferred in the CR ledger for $cov_h12 but no coverage line defers to it" ;;
                esac
            done
            for cov_k in $cov_body_keys; do
                case " $cov_led_keys " in
                    *" $cov_k "*) ;;
                    *) cov_bad="$cov_bad; $cov_k is deferred in the body but has no deferred_to row in the CR ledger for $cov_h12" ;;
                esac
            done
        else
            cov_bad="$cov_bad; the CR ledger could not be read, so its deferrals cannot be compared"
        fi
    fi
    if [ -z "$cov_bad" ]; then
        echo "[PASS] 7. ticket coverage: every ask is done or deferred to an open ticket"
    else
        echo "[FAIL] 7. ticket coverage:${cov_bad#;}"
        [ "$cov_shape" -eq 1 ] && cov_shape_help
        mark_fail
    fi
fi

if [ "$ONLY7" -eq 0 ]; then
# ── 9. plugin versions change only in a release cut ─────────────
# The --bump-required rule of scripts/check-plugin-drift.sh. A PR that does not
# change the root VERSION file must leave each touched plugin's version as it is
# at the merge-base, so a version main moved since never forces a merge of main.
# A release cut is checked against main as it is NOW: two cuts can raise the
# same plugin to the same version with different content, which merges cleanly
# (check 1 stays CLEAN) and leaves stale installs, so every plugin it touches
# must carry a version strictly above origin/main's. Inline rather than
# calling check-plugin-drift.sh, which hardwires HEAD and the caller's checkout.
# A PR touching no plugin never reaches git. Fetch or read failure = FAIL.
plug_files=$(printf '%s\n' "$files_json" | grep -E '^marketplace/plugins/[^/]+/' || true)
if [ -z "$files_json" ]; then
    echo "[FAIL] 9. cannot read PR files — plugin version bump not checked"
    mark_fail
elif [ -z "$plug_files" ]; then
    echo "[PASS] 9. no plugin files touched — version bump not applicable"
else
    bump_err=""
    plug_manifest_ver() {  # <ref> <plugin> — prints the manifest "version", empty when absent
        git show "$1:marketplace/plugins/$2/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null
    }
    plug_removed() {  # <ref> <plugin> — true only when nothing is tracked at the plugin path and marketplace.json no longer lists it
        local left listed
        left=$(git ls-tree -r --name-only "$1" -- "marketplace/plugins/$2" 2>/dev/null) || return 1  # swallow-ok: a failed read counts as not removed
        [ -z "$left" ] || return 1
        listed=$(git show "$1:marketplace/.claude-plugin/marketplace.json" 2>/dev/null | jq -r --arg n "$2" '[.plugins[] | select(.name == $n or ((.source // "") | tostring | rtrimstr("/") | endswith("/" + $n)))] | length' 2>/dev/null)  # swallow-ok: unreadable counts as listed
        [ "$listed" = "0" ]
    }
    if ! git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
        bump_err="cannot fetch origin/main"
    elif ! git cat-file -e "$SHA^{commit}" 2>/dev/null \
        && { ! git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || ! git cat-file -e "$SHA^{commit}" 2>/dev/null; }; then
        bump_err="cannot fetch PR head $SHA"
    elif ! plug_mb=$(git merge-base refs/remotes/origin/main "$SHA" 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
        bump_err="cannot read the merge-base with origin/main"
    elif ! plug_rel=$(git diff --name-only "$plug_mb" "$SHA" -- VERSION 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
        bump_err="cannot read the VERSION diff against the merge-base"
    elif [ -z "$plug_rel" ]; then
        for plug in $(printf '%s\n' "$plug_files" | sed -n 's#^marketplace/plugins/\([^/]*\)/.*#\1#p' | sort -u); do
            main_path="marketplace/plugins/$plug/.claude-plugin/plugin.json"
            # absent at the merge-base = new plugin, removed whole at the head:
            # nothing to compare; a failed tree read = FAIL
            if ! mb_ls=$(git ls-tree --name-only "$plug_mb" -- "$main_path" 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
                bump_err="$bump_err; $plug cannot read the merge-base tree"
                continue
            fi
            if ! pr_ls=$(git ls-tree --name-only "$SHA" -- "$main_path" 2>/dev/null); then  # swallow-ok: rc checked, a failure FAILs check 9
                bump_err="$bump_err; $plug cannot read the PR tree"
                continue
            fi
            [ -n "$mb_ls" ] || continue
            if [ -z "$pr_ls" ] && plug_removed "$SHA" "$plug"; then continue; fi
            mb_ver=$(plug_manifest_ver "$plug_mb" "$plug")
            pr_ver=$(plug_manifest_ver "$SHA" "$plug")
            if [ "$mb_ver" != "$pr_ver" ]; then
                bump_err="$bump_err; $plug went ${mb_ver:-none} to ${pr_ver:-none} outside a release cut — plugin versions change only in the PR that changes VERSION; leave it as it is"
            fi
        done
    else
        for plug in $(printf '%s\n' "$plug_files" | sed -n 's#^marketplace/plugins/\([^/]*\)/.*#\1#p' | sort -u); do
            main_path="marketplace/plugins/$plug/.claude-plugin/plugin.json"
            # absent on main = new plugin, nothing to collide with; a failed tree read or an
            # unreadable manifest = FAIL
            if ! main_ls=$(git ls-tree --name-only refs/remotes/origin/main -- "$main_path" 2>/dev/null); then
                bump_err="$bump_err; $plug cannot read origin/main's tree"
                continue
            fi
            [ -n "$main_ls" ] || continue
            if ! pr_ls=$(git ls-tree --name-only "$SHA" -- "$main_path" 2>/dev/null); then
                bump_err="$bump_err; $plug cannot read the PR tree"
                continue
            fi
            if [ -z "$pr_ls" ] && plug_removed "$SHA" "$plug"; then continue; fi  # removed whole — nothing to bump
            main_ver=$(plug_manifest_ver refs/remotes/origin/main "$plug")
            pr_ver=$(plug_manifest_ver "$SHA" "$plug")
            if ! printf '%s\n' "$main_ver" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' \
                || ! printf '%s\n' "$pr_ver" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+'; then
                bump_err="$bump_err; $plug version not plain x.y.z (main '${main_ver:-none}', PR '${pr_ver:-none}')"
                continue
            fi
            if ! jq -n -e --arg a "$main_ver" --arg b "$pr_ver" '
                def k: split(".") | map(tonumber);
                ($b | k) > ($a | k)' >/dev/null 2>&1; then
                bump_err="$bump_err; $plug is $pr_ver in the PR but origin/main is already $main_ver — bump above main"
            fi
        done
    fi
    if [ -z "$bump_err" ]; then
        if [ -z "$plug_rel" ]; then
            echo "[PASS] 9. no plugin version changed outside a release cut"
        else
            echo "[PASS] 9. release cut: every plugin the PR touches is versioned above current origin/main"
        fi
    else
        echo "[FAIL] 9. plugin version:${bump_err#;}"
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 9

if [ "$ONLY7" -eq 0 ]; then
# ── 10. workflow PRs need a green workflow_dispatch run AT HEAD ──
# A PR is CI-tested only in pull_request mode; the mode main runs (cron,
# dispatch) is never exercised before merge. ci.yml has no push trigger
# so a workflow_dispatch run on the branch is the only pre-merge
# test of the non-PR path. Every .github/workflows/*.yml the PR changes needs a
# completed, successful workflow_dispatch run whose headSha is this head — a run
# at an older sha proves nothing about the change. A changed workflow with no
# workflow_dispatch trigger FAILs and names the missing trigger, unless it is
# listed below: those cannot be dispatched (their trigger is pull_request_target,
# workflow_run or a tag push), so the exemption is explicit and reviewed here.
# ci-image.yml has a trigger, but its build job is gated to refs/heads/main so a
# branch cannot move :latest, and a branch dispatch concludes skipped. Its push
# trigger fires only on .github/ci-image/** paths, so a change to ci-image.yml
# alone gets no push run: its proof is the weekly cron or a workflow_dispatch on
# main. A listed workflow is skipped either way.
# macos-cadence.yml also takes a per-suite proof: a dispatch run at the head whose title names suites
# (`macos-cadence suites: <paths>`) passes when its log shows [PASS] for every named suite, however red
# the rest of the run. That route replaces the whole-run proof only when the named suites cover every
# test-*.sh the PR changes and the PR's macos-cadence.yml diff is the suites wiring alone; any other
# workflow edit, or a changed suite left unnamed, still needs an unfiltered dispatch at the head (green,
# or red only where main already is), and a suites run is never judged by the PRE-EXISTING comparison.
# A workflow the PR deletes has nothing to dispatch, and one it ADDS or renames
# to is not on the default branch, which GitHub requires to dispatch a workflow,
# so neither can be dispatched before merge and both are skipped. A PR touching no workflow
# never reaches the run API; a read/list failure FAILs.
WF_DISPATCH_EXEMPT="
.github/workflows/ci-image.yml
.github/workflows/codeowner-review-gate.yml
.github/workflows/main-sweep-red.yml
.github/workflows/pr-title-lint.yml
.github/workflows/release.yml
"
wf_files=$(printf '%s\n' "$files_json" | grep -E '^\.github/workflows/[^/]+\.ya?ml$' || true)
if [ -z "$files_json" ]; then
    echo "[FAIL] 10. cannot read PR files — workflow_dispatch run not checked"
    mark_fail
elif [ -z "$wf_files" ]; then
    echo "[PASS] 10. no workflow files touched — workflow_dispatch run not applicable"
else
    wf_err=""; wf_ids=""; wf_notes=""; wf_note=""; wf_why=""
    # wf_failed_jobs <run id> [main]: the run's failed job names, sorted, one per line (a matrix shard
    # is one job); rc 1 when the run cannot be read. The PR's run counts every unsuccessful conclusion
    # (failure, timed_out, cancelled, ...); with `main` only failure and timed_out count, because a job
    # main cancelled never ran and so is no evidence it is red there. gh pages the jobs itself.
    wf_failed_jobs() {
        local body sel='.conclusion != null and (.conclusion | IN("success", "skipped", "neutral") | not)'
        [ "${2:-}" != main ] || sel='.conclusion | IN("failure", "timed_out")'
        body=$("$GH" run view "$1" --repo "$nwo" --json jobs 2>/dev/null) || return 1  # swallow-ok: a failed read returns 1, the caller reads it as not pre-existing
        printf '%s' "$body" | jq -r ".jobs[]? | select($sel) | .name" 2>/dev/null | sort -u  # swallow-ok: unparsable jobs read as an empty set, which the caller rejects
    }
    # wf_preexisting <workflow file> <failed dispatch run id>: rc 0 and wf_note set when every failed
    # job of that run also failed in the default branch's latest completed scheduled/push run
    # of the same workflow. Otherwise rc 1 and wf_why says why (empty when main is not red).
    wf_preexisting() {
        local main_runs main_row main_id main_event pr_jobs main_jobs new rc
        wf_why=""
        main_runs=$("$GH" run list --repo "$nwo" --workflow "$1" --branch "${tp_branch:-main}" --json databaseId,status,conclusion,event --limit 20 2>/dev/null) || { wf_why="cannot read main's runs"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        main_row=$(printf '%s' "$main_runs" | jq -r '[.[] | select(.status == "completed" and (.event == "schedule" or .event == "push"))][0] | select(.conclusion == "failure" or .conclusion == "timed_out") | "\(.databaseId) \(.event)"' 2>/dev/null)  # swallow-ok: unparsable runs read as empty, which returns 1 on the next line
        [ -n "$main_row" ] || return 1
        main_id="${main_row%% *}"; main_event="${main_row#* }"
        pr_jobs=$(wf_failed_jobs "$2") && [ -n "$pr_jobs" ] || { wf_why="cannot read the failed jobs of run $2"; return 1; }
        main_jobs=$(wf_failed_jobs "$main_id" main) && [ -n "$main_jobs" ] || { wf_why="cannot read the failed jobs of main run $main_id"; return 1; }
        new=$(printf '%s\n' "$pr_jobs" | grep -vxFf <(printf '%s\n' "$main_jobs")) && rc=0 || rc=$?
        if [ "$rc" -gt 1 ]; then
            wf_why="cannot compare the failed jobs of run $2 with main run $main_id"
            return 1
        fi
        if [ -n "$new" ]; then
            wf_why="run $2 failed on suites not red on main run $main_id: $(printf '%s' "$new" | paste -sd, - | sed 's/,/, /g')"
            return 1
        fi
        wf_note="PRE-EXISTING: $1 dispatch run $2 failed only on suites already red on main ($main_event run $main_id): $(printf '%s' "$pr_jobs" | paste -sd, - | sed 's/,/, /g')"
    }
    # wf_wiring_only <workflow path>: rc 0 when the PR's diff of that file is the macos-cadence `suites`
    # wiring and nothing else. Every added line must be blank, a comment, mention a suite or --only-list,
    # or be one of the if/else and input-block lines that wiring needs; every removed line must be one of
    # the two lines the wiring rewrites or be paired with its added twin that only gained the
    # ` && inputs.suites == ''` clause. rc 1 with wf_why naming the first other line, or the diff unreadable.
    # ponytail: a line-shape allowlist, not a YAML semantic diff; a hostile line that mentions "suite" passes it, upgrade path: compare the parsed workflow with the wiring stripped.
    wf_wiring_only() {
        local patch bad
        patch=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq ".[] | select(.filename == \"$1\") | .patch // empty" 2>/dev/null) || { wf_why="cannot read the diff of $1"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        [ -n "$patch" ] || { wf_why="the diff of $1 is not available"; return 1; }
        bad=$(printf '%s\n' "$patch" | awk -v frag=" && inputs.suites == ''" '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            function strip(s,   i) { while ((i = index(s, frag)) > 0) s = substr(s, 1, i - 1) substr(s, i + length(frag)); return s }
            function wiring(l) { return l == "" || l ~ /^#/ || l ~ /[Ss][Uu][Ii][Tt][Ee]|only-list/ || (l in fixed) }
            BEGIN {
                n = split("inputs:\nrequired: false\ndefault: '"''"'\ntype: string\nrun: |\nelse\nfi\nset -f\nexit 2\nbash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 .", w, "\n")
                for (i = 1; i <= n; i++) fixed[w[i]] = 1
                old["shard: [1, 2, 3, 4, 5, 6, 7, 8]"] = 1
                old["run: bash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 ."] = 1
            }
            /^@@/ { next }
            /^\+/ { added[++na] = trim(substr($0, 2)); next }
            /^-/ { removed[++nr] = trim(substr($0, 2)); next }
            END {
                for (i = 1; i <= na; i++) {
                    if (!wiring(added[i])) { print "+" added[i]; exit }
                    twin[strip(added[i])] = 1
                }
                for (i = 1; i <= nr; i++)
                    if (!wiring(removed[i]) && !(removed[i] in old) && !(removed[i] in twin)) { print "-" removed[i]; exit }
            }') || { wf_why="cannot judge the diff of $1"; return 1; }  # swallow-ok: a failed awk sets wf_why and returns 1
        if [ -n "$bad" ]; then
            wf_why="$1 changes more than the suites wiring (${bad}), so an unfiltered dispatch at the head is required"
            return 1
        fi
    }
    # wf_suites_proof <workflow file> <dispatch runs json>: macos-cadence only. rc 0 and wf_note set when a
    # completed dispatch run at the head named its suites (displayTitle `macos-cadence suites: <paths>`),
    # the named suites cover every test-*.sh the PR changes, the PR's macos-cadence.yml diff is the suites
    # wiring only, and the run's log carries the runner's own `[PASS] <suite> (` for every named suite: the
    # text right after the log's tab-separated timestamp field, so a failed suite's indented forwarded output
    # cannot echo one. rc 1: no such run (the caller falls through to the whole-run rules). rc 2: such a run
    # exists but is not proven; wf_why says why and the verdict is final, because the job-level PRE-EXISTING
    # comparison says nothing about which named suite failed, and a run that proves too little stays refused.
    wf_suites_proof() {
        local wf_name="$1" row id title names s f log changed_suites pass="" bad="" uncovered=""
        wf_why=""
        wf_sp_id=""
        [ "$1" = macos-cadence.yml ] || return 1
        row=$(printf '%s' "$2" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and (.displayTitle // "" | startswith("macos-cadence suites:")))][0] | select(. != null) | "\(.databaseId) \(.displayTitle)"' 2>/dev/null)  # swallow-ok: unparsable runs read as no suites run, the caller fails closed
        [ -n "$row" ] || return 1
        id="${row%% *}"; title="${row#* }"; names="${title#macos-cadence suites:}"
        # shellcheck disable=SC2086  # word-splitting the named paths IS the point (repo paths carry no whitespace)
        set -- $names
        if [ "$#" -eq 0 ]; then wf_why="run $id names no suites"; return 2; fi
        wf_wiring_only ".github/workflows/$wf_name" || return 2
        changed_suites=$(printf '%s\n' "$files_json" | grep -E '(^|/)test-[^/]*\.sh$' || true)  # swallow-ok: no changed suite is grep rc 1, and an empty set is the answer
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case " $* " in *" $f "*) ;; *) uncovered="$uncovered, $f" ;; esac
        done <<EOF
$changed_suites
EOF
        if [ -n "$uncovered" ]; then
            wf_why="suites run $id does not name the suite(s) the PR changes: ${uncovered#, }"
            return 2
        fi
        log=$("$GH" run view "$id" --repo "$nwo" --log 2>/dev/null) || { wf_why="cannot read the log of run $id"; return 2; }  # swallow-ok: a failed read sets wf_why and returns 2, which the caller reports as a failure
        for s in "$@"; do
            if printf '%s\n' "$log" | awk -F'\t' -v want="[PASS] $s (" 'NF >= 3 && $3 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z / { if (index(substr($3, index($3, " ") + 1), want) == 1) f = 1 } END { exit !f }'; then pass="$pass, PASS $s"; else bad="$bad, $s"; fi
        done
        if [ -n "$bad" ]; then
            wf_why="suites run $id: named suite(s) with no [PASS] line (failed or never ran): ${bad#, }"
            return 2
        fi
        wf_sp_id="$id"
        wf_note="PER-SUITE: $wf_name dispatch run $id, red or green overall, named $# suite(s) and every one passed: ${pass#, }"
    }
    wf_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null)
    # wf_ancestor_preexisting <workflow file>: rc 0 with wf_note, wf_anc_id and wf_anc_sha set when a
    # failed dispatch run of the PR branch at an ANCESTOR of the head passes wf_preexisting and every
    # file the PR changes is the same blob at that ancestor and at the head, so the head only merges
    # main forward. That run's check runs sit on the ancestor commit, not the head. Otherwise rc 1 and
    # wf_why says why (empty when the branch has no such run).
    wf_ancestor_preexisting() {
        local rows id anc f a_ent h_ent changed prev_files
        wf_why=""
        [ -n "$wf_branch" ] || return 1
        rows=$("$GH" run list --repo "$nwo" --workflow "$1" --event workflow_dispatch --branch "$wf_branch" --json databaseId,event,status,conclusion,headSha,headBranch,displayTitle --limit 20 2>/dev/null) || { wf_why="cannot list the branch's dispatch runs"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        rows=$(printf '%s' "$rows" | jq -r --arg h "$SHA" --arg b "$wf_branch" '.[] | select(.event == "workflow_dispatch" and .status == "completed" and .conclusion == "failure" and .headBranch == $b and .headSha != $h and ((.displayTitle // "") | startswith("macos-cadence suites:") | not)) | "\(.databaseId) \(.headSha)"' 2>/dev/null)  # swallow-ok: unparsable runs read as none, which returns 1 on the next line
        [ -n "$rows" ] || return 1
        # the file list shows a rename by its new path only; the old path must match at both commits too
        prev_files=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | .previous_filename // empty' 2>/dev/null) || { wf_why="cannot read the paths the PR renames from"; return 1; }  # swallow-ok: a failed read sets wf_why and returns 1
        if ! git cat-file -e "$SHA^{commit}" 2>/dev/null \
            && { ! git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || ! git cat-file -e "$SHA^{commit}" 2>/dev/null; }; then  # swallow-ok: a failed fetch is reported through wf_why on the next line
            wf_why="cannot fetch PR head $SHA to compare it with an earlier dispatch"
            return 1
        fi
        while IFS=' ' read -r id anc; do
            [ -n "$id" ] || continue
            if ! git cat-file -e "$anc^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$anc" "$SHA" 2>/dev/null; then  # swallow-ok: rc is the answer, not an ancestor skips the run
                wf_why="dispatch run $id is at $anc, not an ancestor of the head"
                continue
            fi
            changed=""
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                if ! a_ent=$(git --literal-pathspecs ls-tree "$anc" -- "$f" 2>/dev/null) || ! h_ent=$(git --literal-pathspecs ls-tree "$SHA" -- "$f" 2>/dev/null); then  # swallow-ok: rc checked, an unreadable tree skips the run
                    changed="$f (unreadable)"
                    break
                fi
                if [ "$a_ent" != "$h_ent" ]; then
                    changed="$f"
                    break
                fi
            done <<EOF
$files_json
$prev_files
EOF
            if [ -n "$changed" ]; then
                wf_why="dispatch run $id at $anc is stale: $changed differs between it and the head"
                continue
            fi
            if wf_preexisting "$1" "$id"; then
                wf_anc_id="$id"; wf_anc_sha="$anc"
                wf_note="$wf_note — run is at ancestor $anc, and every file the PR changes is identical there and at the head"
                return 0
            fi
            wf_why="${wf_why:-dispatch run $id at $anc is not pre-existing}"
        done <<EOF
$rows
EOF
        return 1
    }
    wf_undispatchable_ok=1
    wf_undispatchable=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | select(.status == "removed" or .status == "added" or .status == "renamed") | .filename' 2>/dev/null) || wf_undispatchable_ok=0
    if [ "$wf_undispatchable_ok" -eq 0 ]; then
        wf_err="cannot read which workflow files the PR removes"
    else
        while IFS= read -r wf; do
            [ -n "$wf" ] || continue
            printf '%s\n' "$wf_undispatchable" | grep -qxF "$wf" && continue
            printf '%s' "$WF_DISPATCH_EXEMPT" | grep -qxF "$wf" && continue
            wf_base="${wf##*/}"
            if ! wf_body=$("$GH" api -H "Accept: application/vnd.github.raw" "repos/$owner/$repo/contents/$wf?ref=$SHA" 2>/dev/null); then
                wf_err="$wf_err; $wf cannot be read at $SHA"
                continue
            fi
            if ! printf '%s\n' "$wf_body" | grep -qE '^[[:space:]]*workflow_dispatch[[:space:]]*:|^[[:space:]]*-[[:space:]]*workflow_dispatch[[:space:]]*(#.*)?$|^"?on"?[[:space:]]*:.*workflow_dispatch'; then
                wf_err="$wf_err; $wf has no workflow_dispatch trigger — add one, or list it in WF_DISPATCH_EXEMPT in ready-check.sh"
                continue
            fi
            if ! wf_runs=$("$GH" run list --repo "$nwo" --workflow "$wf_base" --event workflow_dispatch --commit "$SHA" --json databaseId,status,conclusion,headSha,displayTitle --limit 20 2>/dev/null); then
                wf_err="$wf_err; $wf run list failed"
                continue
            fi
            wf_ok_id=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and .conclusion == "success" and ((.displayTitle // "") | startswith("macos-cadence suites:") | not))][0].databaseId // empty' 2>/dev/null)  # swallow-ok: unparsable runs read as no green run, the failure path then judges it
            if [ -n "$wf_ok_id" ]; then
                wf_ids="$wf_ids ${wf_base}=$wf_ok_id"
                continue
            fi
            wf_fail_id=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h and .status == "completed" and .conclusion == "failure")][0].databaseId // empty' 2>/dev/null)  # swallow-ok: unparsable runs read as no failed run, so the check fails closed
            wf_head_runs=$(printf '%s' "$wf_runs" | jq -r --arg h "$SHA" '[.[] | select(.headSha == $h)] | length' 2>/dev/null) || wf_head_runs=1  # swallow-ok: an unreadable list counts the head as having a run, so the ancestor fallback is refused
            wf_why=""; wf_sp_rc=0
            wf_suites_proof "$wf_base" "$wf_runs" || wf_sp_rc=$?
            if [ "$wf_sp_rc" -eq 0 ]; then
                wf_ids="$wf_ids ${wf_base}=$wf_sp_id"
                wf_notes="$wf_notes
       $wf_note"
            elif [ "$wf_sp_rc" -eq 1 ] && [ -n "$wf_fail_id" ] && wf_preexisting "$wf_base" "$wf_fail_id"; then
                wf_ids="$wf_ids ${wf_base}=$wf_fail_id"
                wf_notes="$wf_notes
       $wf_note"
            elif [ -z "$wf_fail_id" ] && [ "$wf_head_runs" = 0 ] && wf_ancestor_preexisting "$wf_base"; then
                wf_ids="$wf_ids ${wf_base}=$wf_anc_id@$wf_anc_sha"
                wf_notes="$wf_notes
       $wf_note"
            else
                wf_err="$wf_err; $wf has no completed successful workflow_dispatch run at $SHA${wf_why:+ ($wf_why)} — run: gh workflow run $wf_base --ref ${wf_branch:-<branch>} --repo $nwo"
            fi
        done <<EOF
$wf_files
EOF
    fi
    if [ -z "$wf_err" ]; then
        if [ -n "$wf_notes" ]; then
            echo "[PASS] 10. every changed workflow has a workflow_dispatch run at head that is green or red only where main already is (or is exempt/removed)${wf_ids:+ — runs:$wf_ids}${wf_notes}"
        else
            echo "[PASS] 10. every changed workflow has a successful workflow_dispatch run at head (or is exempt/removed)${wf_ids:+ — runs:$wf_ids}"
        fi
    else
        echo "[FAIL] 10. workflow dispatch:${wf_err#;}"
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 10

if [ "$ONLY7" -eq 0 ]; then
# ── 11. an ADDED hook/script/skill/suite that nothing reaches ──
# Only status-A files are judged, so existing debt never fails a PR. The judgement
# (what counts as wired per kind) lives in scripts/testing/check-added-unwired.sh and
# reads the PR head's tree, so wiring added in the same diff counts. A PR adding
# nothing never reaches git. A files/fetch failure FAILs.
if [ -z "$files_json" ]; then
    echo "[FAIL] 11. cannot read PR files — added-but-unwired files not checked"
    mark_fail
elif ! unw_added=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[] | select(.status == "added") | .filename' 2>/dev/null); then
    echo "[FAIL] 11. cannot read which files the PR adds — added-but-unwired files not checked"
    mark_fail
elif [ -z "$unw_added" ]; then
    echo "[PASS] 11. the PR adds no files — added-but-unwired not applicable"
else
    unw_out=""; unw_rc=0
    # the helper reads the PR head's tree: fetch it the way check 9 does when it is not local
    if ! git cat-file -e "$SHA^{commit}" 2>/dev/null; then
        git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || true
    fi
    # shellcheck disable=SC2086  # word-splitting the added paths IS the point (repo paths carry no whitespace)
    unw_out=$(bash "$(cd "$(dirname "$0")/../../testing" && pwd)/check-added-unwired.sh" "$SHA" $unw_added 2>&1) || unw_rc=$?
    if [ "$unw_rc" -eq 0 ]; then
        echo "[PASS] 11. every added hook, script, skill or suite is reached by some wiring"
    else
        echo "[FAIL] 11. added but unwired (wire it, or allowlist it in the diff):"
        printf '%s\n' "$unw_out" | sed 's/^/       /'
        mark_fail
    fi
fi
fi  # ONLY7 == 0: check 11

TRUST_PATH=""
if [ "$ONLY7" -eq 0 ]; then
# ── 12. trust path, computed from the PR diff ──
# The same question merge-on-green asks (trust_path_check in scripts/lib/go-gate.sh:
# the default branch's list against the PR's REST file listing). The leg's READY
# text is never consulted. A refusal (unreadable list, head moved, listing cut
# short, stale anchor) FAILs and prints no TRUST-PATH line: it never reads as "no".
tp_anchor="${READY_CHECK_ANCHOR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
tp_rc=0; tp_out=""
if [ -z "$tp_branch" ]; then
    tp_rc=2; tp_out="cannot resolve the default branch (gh repo view --json defaultBranchRef gave none)"
else
    unset -f trust_path_check 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if . "$tp_anchor/scripts/lib/go-gate.sh" 2>/dev/null && declare -F trust_path_check >/dev/null 2>&1; then
        # shellcheck disable=SC2031  # tp_branch is set in the main shell, not a subshell
        tp_out=$(GH="$GH" trust_path_check "$nwo" "$PR" "$SHA" "$tp_branch" "$tp_anchor") || tp_rc=$?
    else
        tp_rc=2; tp_out="cannot load trust_path_check from $tp_anchor/scripts/lib/go-gate.sh"
    fi
fi
if [ "$tp_rc" -ne 0 ]; then
    echo "[FAIL] 12. trust path: refused ${tp_out:-trust_path_check exited $tp_rc with no reason}"
    mark_fail
else
    echo "[PASS] 12. trust path: $tp_out"
    case "$tp_out" in
        hit\ *) TRUST_PATH=yes ;;
        *) TRUST_PATH=no ;;
    esac
fi
fi  # ONLY7 == 0: check 12

if [ "$ONLY7" -eq 1 ]; then
    if [ "$RESULT" -eq 0 ]; then echo "COVERAGE-LINT PASS"; exit 0; fi
    echo "COVERAGE-LINT FAIL"
    exit 1
fi

echo "---"
echo "The three-dot diff read (git diff origin/main...HEAD) stays the console's own judgement — this script does not read it."
[ -z "$TRUST_PATH" ] || echo "TRUST-PATH: $TRUST_PATH"
if [ "$RESULT" -eq 0 ]; then
    echo "READY-CHECK PASS"
    exit 0
else
    echo "READY-CHECK FAIL"
    exit 1
fi
