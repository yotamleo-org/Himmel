#!/usr/bin/env bash
# scripts/handover/console-kit/ready-check.sh — mechanize the console's READY
# verification. Console A ran this same
# checklist by hand ~12 times on 2026-09-18 with zero variance; the fleet cap
# doubling (4 -> 8) doubles the READYs per hour, so it is worth a script.
#
# Read-only except the shared PR snapshot cache. Prints one
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
#   3. GraphQL unresolved review threads == 0. The snapshot follows every
#      page with cursor/hasNextPage guards and the same 50-page ceiling as
#      check-ci.sh; a >100-thread PR cannot silently short-circuit to PASS.
#   4. CR ledger: <git-common-dir>/cr-critic-scores.jsonl has >=1 row for
#      <head-sha> with status "ok" (the shape `scripts/cr/cr-scores.sh` and
#      friends read — {"kind":"avail","head":...,"status":"ok"}).
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
#      keys must also equal the CR ledger's deferred_to rows for the PR head.
#      A Jira error reads UNKNOWN and fails — never a PASS.
#   9. Plugin version bump vs CURRENT origin/main: every plugin
#      under marketplace/plugins/ the PR touches must be versioned strictly
#      above origin/main's manifest (same rule as check-plugin-drift.sh
#      --bump-required, but against main now, not the merge-base — two PRs
#      bumping to the same version merge CLEAN). Fetches origin/main and the PR
#      head (refs/pull/<n>/head) into the caller's repo; a PR touching no
#      plugin never reaches git. Any fetch/read failure FAILs.
#  10. Workflow dispatch: every .github/workflows/*.yml the PR
#      changes needs a completed, successful workflow_dispatch run at the PR
#      head sha (`gh run list --workflow <wf> --event workflow_dispatch
#      --commit <head>`), since ci.yml has no push trigger and the mode main
#      runs is otherwise never tested pre-merge. The FAIL line prints the exact
#      `gh workflow run` command. A changed workflow with no workflow_dispatch
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
SNAPSHOT_SCRIPT="$(cd "$(dirname "$0")/../../lib" && pwd)/gh-pr-snapshot.sh"
snapshot=""
if [ "$ONLY7" -eq 0 ]; then
    snapshot=$(GH_CMD="$GH" bash "$SNAPSHOT_SCRIPT" "$nwo" 60 "$PR" 2>/dev/null) || snapshot=""
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
if [ -z "$pv" ]; then
    echo "[FAIL] 1. gh pr view #$PR --repo $nwo failed — cannot read headRefOid/mergeStateStatus"
    mark_fail
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "CLEAN" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=CLEAN"
else
    echo "[FAIL] 1. head=$head_now (want $SHA), mergeStateStatus=$mss (want CLEAN)"
    mark_fail
fi

# ── 2. statusCheckRollup ─────────────────────────────────────────────────────
rollup=$(printf '%s' "$snapshot" | jq -c '.[0].statusCheckRollup' 2>/dev/null)
if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    echo "[FAIL] 2. statusCheckRollup unreadable (gh pr view --json statusCheckRollup failed)"
    mark_fail
else
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
    grouped=$(printf '%s' "$rollup" | jq -c '
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
        | {total: length, bad: (map(select(.ok | not)) | map("\(.name // "?")=\(.detail)") | join(", "))}
    ' 2>/dev/null)
    total=$(printf '%s' "$grouped" | jq -r '.total // 0' 2>/dev/null)
    bad=$(printf '%s' "$grouped" | jq -r '.bad // empty' 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    if [ "$total" -eq 0 ]; then
        echo "[FAIL] 2. statusCheckRollup: no checks reported yet (0 entries — CI may not have registered)"
        mark_fail
    elif [ -z "$bad" ]; then
        echo "[PASS] 2. statusCheckRollup: $total/$total checks completed SUCCESS/SKIPPED/NEUTRAL"
    else
        echo "[FAIL] 2. statusCheckRollup: not-green — $bad"
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
        n=$(jq -R -r --arg h "$SHA" 'fromjson? | select(.head == $h and .status == "ok") | .head' "$ledger" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${n:-0}" -ge 1 ]; then
            echo "[PASS] 4. CR ledger: $n row(s) for $SHA with status=ok"
        else
            echo "[FAIL] 4. CR ledger: no row for $SHA with status=ok ($ledger)"
            mark_fail
        fi
    fi
fi

# ── commits (shared by checks 5 and 6) ──────────────────────────────────────
commits_json=$(printf '%s' "$snapshot" | jq -c '.[0].commits' 2>/dev/null)
files_json=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null)

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
# the CR ledger's deferred_to rows for the PR head. A Jira error reads UNKNOWN and
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

# cov_ledger_keys <ledger> <head>: the tickets the CR ledger defers findings to at <head>, one upper-case key per line.
# A finding's effective row is its own row with every amend written against its original head merged over it, in file
# order (an amend's set.head re-keys the finding, and later amends keep the original head as their target_head); the
# finding counts at the head when its effective head matches, and only an effective verdict of deferred counts.
# A head matches when either spelling is a prefix of the other.
# A missing ledger is an empty set (check 4 owns that failure); an unreadable one returns 1.
cov_ledger_keys() {
    [ -f "$1" ] || return 0
    cov_led_out=$(jq -R -n -r --arg h "$2" '
        def hm($x; $y): ($x | type == "string") and ($y | type == "string") and ($x | length >= 7) and ($y | length >= 7) and (($x | ascii_downcase) as $a | ($y | ascii_downcase) as $b | ($a | startswith($b)) or ($b | startswith($a)));
        def fk($r): [$r.finding_id // "?", $r.artifact // "diff", $r.perspective // "off"] | join("|");
        def vd($o): $o | {verdict, deferred_to} | with_entries(select(.value != null));
        [inputs | fromjson? | select(type == "object")] as $rows
        | def ak($r; $x): fk($r) + "|" + ($x[0:7] | ascii_downcase);
        (reduce ($rows[] | select(.kind == "amend" and (.set | type == "object") and (.target_head | type == "string") and (.target_head | length >= 7))) as $a ({}; .[ak($a; $a.target_head)] += [$a])) as $amends
        | reduce ($rows[] | select(.kind == "finding" and (.head | type == "string") and (.head | length >= 7))) as $f ({};
            (reduce (($amends[ak($f; $f.head)] // [])[] | select(hm(.target_head; $f.head))) as $a ($f; . + $a.set)) as $e
            | if hm($e.head; $h) then .[fk($f)] = vd($e) else . end)
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
        if cov_led_out=$(cov_ledger_keys "$cov_common/cr-critic-scores.jsonl" "$cov_head"); then
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
# ── 9. plugin version bump vs CURRENT origin/main ─────────────
# The --bump-required rule of scripts/check-plugin-drift.sh, run
# against main as it is NOW rather than the PR's merge-base: two PRs can bump
# the same plugin to the same version with different content, which merges
# cleanly (check 1 stays CLEAN) and leaves stale installs. Every plugin the PR
# touches must carry a version strictly above origin/main's. Inline rather than
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
    if ! git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
        bump_err="cannot fetch origin/main"
    elif ! git cat-file -e "$SHA^{commit}" 2>/dev/null \
        && { ! git fetch -q origin "refs/pull/$PR/head" 2>/dev/null || ! git cat-file -e "$SHA^{commit}" 2>/dev/null; }; then
        bump_err="cannot fetch PR head $SHA"
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
            [ -n "$pr_ls" ] || continue  # plugin removed by the PR — nothing to bump
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
        echo "[PASS] 9. every plugin the PR touches is versioned above current origin/main"
    else
        echo "[FAIL] 9. plugin version bump:${bump_err#;}"
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
    wf_err=""
    wf_branch=$(printf '%s' "$snapshot" | jq -r '.[0].headRefName // empty' 2>/dev/null)
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
            if ! wf_runs=$("$GH" run list --repo "$nwo" --workflow "$wf_base" --event workflow_dispatch --commit "$SHA" --json status,conclusion,headSha --limit 20 2>/dev/null); then
                wf_err="$wf_err; $wf run list failed"
                continue
            fi
            if ! printf '%s' "$wf_runs" | jq -e --arg h "$SHA" 'any(.[]; .headSha == $h and .status == "completed" and .conclusion == "success")' >/dev/null 2>&1; then
                wf_err="$wf_err; $wf has no completed successful workflow_dispatch run at $SHA — run: gh workflow run $wf_base --ref ${wf_branch:-<branch>} --repo $nwo"
            fi
        done <<EOF
$wf_files
EOF
    fi
    if [ -z "$wf_err" ]; then
        echo "[PASS] 10. every changed workflow has a successful workflow_dispatch run at head (or is exempt/removed)"
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
