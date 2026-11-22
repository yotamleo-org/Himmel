#!/usr/bin/env bash
# Tests for handover/merge-on-green.sh — the armed-chain auto-merge
# chokepoint. The wrapper has NO env seams for `gh`/`check-ci` (gate integrity):
# so each case runs a COPY of the script in a temp tree
# ($tmp/scripts/handover/merge-on-green.sh) with a stub check-ci at the fixed
# sibling path ($tmp/scripts/check-ci.sh) and a stub `gh` FIRST on PATH. Asserts
# the fail-closed gate sequence + that a real merge only ever fires with
# --squash + --match-head-commit <certified-sha>.
set -uo pipefail
KP=HIMMEL

# An --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent in test-check-ci.sh,
# generalized). merge-on-green.sh gates on a truthy ARMAUTOMERGE
# (merge-on-green.sh:153), so an ambient =1 would make the no-opt-in refusal
# (case 1) read as opted-in. (Case 1's own inline `unset ARMAUTOMERGE` is
# retained; this is the startup defense-in-depth + the CR_MERGE_GATE_OK scrub
# for the day a sourced lib reads it.)
unset ARMAUTOMERGE CR_MERGE_GATE_OK
# A chief-spawned worker's shell carries HIMMEL_CONSOLE_LEG=1, which
# arms the chief-GO gate — ambient, it would refuse every merge case below.
# Its own line: RC-2 below mutates the line above by exact match.
unset HIMMEL_CONSOLE_LEG HIMMEL_WORKER_SESSION_DOC
# A bare merge appends a PARTIAL bullet to $HIMMEL_CONSOLE_DOC when it is set; a worker launched
# from a chief carries it, so every bare-merge row would write the live chief doc.
# The one row that wants a chief doc sets its own temp file explicitly.
unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_NAME
# An operator/worker launching shell carries HIMMEL_REPO (the
# harness-wide anchor) — ambient, it would point every case's gate at a real
# checkout instead of the fixture's own stub. run_mog always passes its own
# HIMMEL_REPO explicitly (default: the fixture tree itself), which already
# overrides this per-invocation; unset here too for hermeticity / defense in
# depth against any direct (non-run_mog) invocation added later.
unset HIMMEL_REPO
# The new pre-merge title gate invokes check-pr-title.sh ->
# check-commit-msg.sh, whose ticket pattern derives from JIRA_PROJECT_KEY.
# Exported here (inherited by every case's child bash below, matching the
# real .env's JIRA_PROJECT_KEY=HIMMEL, ci.yml's commit-lint job) rather than
# threaded through every individual invocation site in this file.
export JIRA_PROJECT_KEY=HIMMEL
# The pre-merge static re-check builds the merge of the anchor's origin and the
# PR head, so it needs a git anchor with a fetchable origin; nearly every case
# here runs against a bare stub tree. It is off for them, and
# test-merge-on-green-static-recheck.sh (which sources this file) turns it on.
export MERGE_STATIC_RECHECK=0

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOG="$SCRIPT_DIR/merge-on-green.sh"

# ~70 mktemp sites below (mog-run.*, bare `mktemp -d`, mutant files,
# red-control stderr) each leaked one entry per run. One private parent under
# TMPDIR, exported as TMPDIR for the rest of the suite and its children, is
# removed by the one EXIT trap, so every site is covered without a per-site list.
MOG_SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mog-suite.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if [ -z "$MOG_SUITE_TMP" ] || [ ! -d "$MOG_SUITE_TMP" ]; then echo "FAIL: mktemp -d produced no suite TMPDIR" >&2; exit 1; fi
trap 'chmod -R u+rwX "$MOG_SUITE_TMP"; rm -rf "$MOG_SUITE_TMP"' EXIT
export TMPDIR="$MOG_SUITE_TMP"

# chief-kit/go.sh mints, and the chief-GO gate verifies with,
# a key under $HOME/.config/himmel — a scratch HOME keeps every GO this suite
# writes off the operator's real key.
MOG_HOME=$(mktemp -d "${TMPDIR:-/tmp}/mog-home.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if [ -z "$MOG_HOME" ] || [ ! -d "$MOG_HOME" ]; then echo "FAIL: mktemp -d produced no HOME sandbox" >&2; exit 1; fi
export HOME="$MOG_HOME"

# RED-control contract for the mutation controls added below:
# proves a mutant actually ran, produced output, and
# produced the SPECIFIC predicted wrong value, not merely "differs from
# correct".
. "$SCRIPT_DIR/../lib/red-control.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# The red-main gate reads `gh run list` for main's CI. Every
# pre-existing case sees the GREEN window below, a real capture of
# `gh run list --branch main --workflow CI --json conclusion,createdAt,databaseId,event,headSha,status`
# (2026-10-10: cancelled pushes over a completed success). Exported once so a
# case that does not care about main's state is unaffected.
MOG_RUN_GREEN='[{"conclusion":"cancelled","createdAt":"2026-10-10T01:41:58Z","databaseId":38014176513,"event":"push","headSha":"34d7d3d317ee8ba21db397fa0d7abd8c10a8027c","status":"completed"},{"conclusion":"cancelled","createdAt":"2026-10-10T00:58:28Z","databaseId":38011295134,"event":"push","headSha":"5286ec495369d71a198a334d02647ba31fc78d0e","status":"completed"},{"conclusion":"success","createdAt":"2026-10-09T23:02:19Z","databaseId":38002387566,"event":"push","headSha":"3b31ceaa568b628ebb3edad04630307adfc1602f","status":"completed"},{"conclusion":"success","createdAt":"2026-10-09T21:21:08Z","databaseId":37992919316,"event":"push","headSha":"f3395dbb5a6ac2fa4f1a0c54da6dfcbd0e0c1b0c","status":"completed"}]'
export STUB_RUN_LIST_JSON_DEFAULT="$MOG_RUN_GREEN"

# run_mog <expected-exit> <test-name> [-- extra merge-on-green args...]
# Stub behavior controlled by env vars exported before the call:
#   STUB_STATE          initial PR state in the meta query. Default OPEN.
#   STUB_STATE_FAIL=1   the meta `gh pr view` exits 1 (API failure).
#   STUB_NO_PR=1        the meta `gh pr view` exits 1 with "no pull requests found".
#   STUB_GH_HINT=1      the meta `gh pr view` also prints a multi-line `hint:` notice on
#                        stderr after its output (and after the STUB_NO_PR text).
#                        STUB_STATE_FAIL=hint-only exits 1 with that notice alone.
#   STUB_PRIVATE        `gh repo view <nwo> --json isPrivate` value. Default true.
#                       Empty => undeterminable (fail closed).
#   STUB_NWO            the PR's owner/repo (in its url). Default owner/repo.
#   STUB_CWD_NWO        the CURRENT checkout's owner/repo. Default = STUB_NWO.
#   STUB_CWD_FAIL=1     `gh repo view --json nameWithOwner` (cwd) exits 1.
#   STUB_SHA            `headRefOid` in the meta query. Default a fixed fake sha.
#   STUB_BASE            `baseRefName` in the meta query. Default main.
#   STUB_HEAD_BRANCH     `headRefName` in the meta query (the
#                        branch whose worktree is pruned after a confirmed
#                        merge). Default feat/stub-head (matches nothing).
#   MOG_CWD              Directory to run merge-on-green FROM. Default: the
#                        case's own temp dir (not a git repo), so the prune
#                        finds nothing. Prune cases point it at a fixture repo
#                        or at the fixture worktree itself.
#   STUB_DEFAULT_BRANCH  `defaultBranchRef.name` in the repo-meta query. Default main.
#   STUB_MERGE_STATE     fresh mergeStateStatus. Default CLEAN.
#   STUB_REVIEW_DECISION fresh reviewDecision. Default empty (no review rule).
#   STUB_POLICY_FAIL=1   the fresh merge-policy query fails.
#   STUB_BASE_PREMERGE   `baseRefName` in the FIX-1 pre-merge re-query (fires
#                        after check-ci, before merging). Default = STUB_BASE.
#   STUB_DEFAULT_BRANCH_PREMERGE  `defaultBranchRef.name` in the FIX-1 pre-merge
#                        re-query. Default = STUB_DEFAULT_BRANCH.
#   STUB_PR_TITLE        `title` in the pre-merge title re-query
#                        (guard 3c) AND jira_auto_transition_on_merge's own
#                        title read (both --json title). Default a
#                        conventional, ticketed, unbracketed title, so every
#                        pre-existing case is unaffected. `-` (not `:-`) so an
#                        explicitly-empty STUB_PR_TITLE is reachable
#                        (undeterminable → fail closed).
#   STUB_PR_AUTHOR       `author.login` in guard 3c's --json title,author
#                        query, threaded into TICKET_ID_AUTHOR/
#                        TICKET_ID_TRUSTED_AUTHOR (so the trusted-author exemption can be exercised). Default a non-exempt login, so every
#                        pre-existing case is unaffected.
#   STUB_PRIVATE_PREMERGE  `isPrivate` in the FIX-1 pre-merge re-verify
#                        (isPrivate is folded into the
#                        pre-merge repo view). Default = STUB_PRIVATE. Set false
#                        to simulate a repo made public during the CI wait.
#   STUB_DEFAULT_BRANCH_NULL=1  the repo-meta query's defaultBranchRef is JSON
#                        null over the wire — runs the SCRIPT'S OWN --jq filter
#                        (captured from argv) through real jq against synthetic
#                        null JSON, so this proves the coalesce fix rather than
#                        a hand-picked stub string.
#   STUB_DEFAULT_BRANCH_PREMERGE_NULL=1  same, for the FIX-1 pre-merge query.
#   STUB_PROTECTION      the guard-2b branch-protection read, as
#                        the pre-joined shape the script's own --jq emits:
#                        "<enforce_admins.enabled>|<#contexts>|<#checks>".
#                        Default "true|10|0" (the live yotamleo-org/Himmel shape:
#                        enforce_admins on, 10 required contexts). Only read on
#                        the non-private path — a private repo never reaches it.
#   STUB_PROTECTION_FAIL=1  the guard-2b `gh api .../protection` exits 1 (404 /
#                        no protection / unreadable) → the guard must fail closed.
#   STUB_PROTECTION_PREMERGE       same, for the pre-merge protection re-read.
#                        Default = STUB_PROTECTION. Set it to simulate protection
#                        being weakened during the check-ci watch.
#   STUB_PROTECTION_PREMERGE_FAIL=1  the pre-merge protection re-read exits 1 →
#                        refuse (protection removed during the CI wait).
#   STUB_PROTECTION_JSON  raw protection JSON fed through the SCRIPT'S OWN --jq
#                        filter (captured from argv) via real jq, instead of the
#                        pre-joined STUB_PROTECTION string — the same technique
#                        STUB_DEFAULT_BRANCH_NULL uses, so a `required_status_checks:
#                        null` payload proves the script's `// []` coalesce rather
#                        than a hand-picked stub string.
#   STUB_PROTECTION_JSON_PREMERGE  overrides the JSON replayed on the PRE-MERGE
#                        protection read only. Unset, it falls back to
#                        STUB_PROTECTION_JSON, so an existing single-JSON case is
#                        unaffected. Exists because STUB_PROTECTION_JSON alone is
#                        replayed verbatim on BOTH reads: without this seam, a case setting
#                        STUB_PROTECTION_JSON together with STUB_PROTECTION_PREMERGE
#                        would silently exercise UNCHANGED protection across both
#                        reads — STUB_PROTECTION_PREMERGE would be dead, and the
#                        case would prove nothing about the pre-merge re-read.
#   STUB_CI_RC          exit code of the stub check-ci. Default 0.
#   STUB_CI_COMMIT=1    the stub check-ci commits in its cwd (a local commit
#                        made during the CI watch).
#   STUB_CI_RCS         space-separated exit codes, one per check-ci call (the
#                        last repeats). Overrides STUB_CI_RC.
#   STUB_ROUND_STATE / STUB_ROUND_HEAD / STUB_ROUND_FAIL=1  the between-rounds
#                        `--json state,headRefOid` re-read.
#                        Defaults OPEN / STUB_SHA.
#   STUB_MERGE_FAIL=1   `gh pr merge` exits 1 (generic failure).
#   STUB_MERGE_POLICY_REFUSED=1  merge exits 1 with GitHub's base-policy refusal.
#   STUB_POST_STATE     PR state the post-merge re-query returns. Default MERGED.
#   STUB_POST_STATE_FAIL=1  the post-merge state re-query fails (indeterminate).
#   STUB_POST_HEAD      headRefOid the failure-recovery re-query
#                        (state,headRefOid,baseRefName) returns. Default =
#                        STUB_SHA (matches the certified sha, so existing tests
#                        see an unchanged head). Set it to a different value to
#                        simulate a concurrently-merged commit.
#   STUB_POST_BASE       baseRefName the failure-recovery re-query returns.
#                        Default = STUB_BASE (matches the authorized base, so
#                        existing tests see an unchanged base). Set it to a
#                        different value to simulate a concurrent retarget.
#   STUB_POST_OPEN_TIMES  the first N post-merge re-queries report OPEN before
#                        STUB_POST_STATE takes over — a merge
#                        accepted server-side that only lands a moment later.
#                        Default 0 (the first read already reports the state).
#   NO_CHECK_CI=1       omit the stub check-ci (sibling path absent).
#   STUB_AUDIT_UNWRITABLE=1  point the audit sink at an unwritable path.
#   STUB_CLEAR_RC       exit code of the stub clear-cr-marker.
#                        Default 0.
#   STUB_NO_CLEARER=1   omit the stub clear-cr-marker (sibling path absent).
# After the run: $LAST_GH_LOG = stub gh argv log, $LAST_AUDIT = audit log,
# $LAST_CLEAR_LOG = stub clear-cr-marker argv log (empty = never invoked),
# $LAST_ERR = the run's captured stderr (the gutted-remove
# operator message is stderr-only, never the audit log).
LAST_GH_LOG=""; LAST_AUDIT=""; LAST_CLEAR_LOG=""; LAST_ERR=""; LAST_JIRA_LOG=""

# mog_build_fixture <tmpdir>
#
# Build the scratch tree run_mog executes merge-on-green.sh in: copies of the
# script + its lib siblings, a stub check-ci.sh, a stub clear-review-marker.sh,
# and a stub `gh` FIRST on PATH. Pulled out of run_mog so a
# RED control can build the SAME fixture around a MUTANT copy of
# merge-on-green.sh and run it directly through red_control_run — going
# through run_mog itself would consume the run with run_mog's own pass/fail,
# leaving nothing for the control to assert against.
#
# Takes only the tmpdir (no ghlog/clearlog parameters are passed):
# both stub scripts written below read $GH_LOG /
# $CLEAR_LOG from the environment at RUNTIME (set by whichever caller execs
# the copied merge-on-green.sh — run_mog, or a RED control's own
# red_control_run --env), never from a build-time path here, so carrying them
# as parameters was dead weight — the class of thing this repo's rules
# forbid keeping "for symmetry".
#
# MOG_SRC (read here, optional) is a TEST-HARNESS-ONLY seam: it picks which
# SOURCE FILE gets copied to the fixture's fixed
# $tmp/scripts/handover/merge-on-green.sh path, defaulting to the real $MOG.
# This is NOT the gate-integrity seam the file header above forbids — that
# ban is about merge-on-green.sh itself reading `gh`/check-ci from the
# environment at RUNTIME, which would let a live run silently swap in a fake
# gate. MOG_SRC never reaches the copied script's own runtime: the copy still
# has no env seams of its own and still resolves `gh` and check-ci.sh only
# from its fixed sibling paths. MOG_SRC just lets THIS TEST HARNESS point the
# copy step at a scratch mutant instead of the shipped script; production
# merge-on-green.sh gains no seam.
mog_build_fixture() {
    local tmp="$1"

    # Copy the script into a temp tree so its fixed `../check-ci.sh` sibling
    # resolves to our stub — no CHECK_CI env override exists any more.
    mkdir -p "$tmp/scripts/handover" "$tmp/scripts/lib" "$tmp/scripts/cr" "$tmp/scripts/hooks" "$tmp/bin"
    cp "${MOG_SRC:-$MOG}" "$tmp/scripts/handover/merge-on-green.sh"
    # merge-on-green.sh now sources ../cr/anchor-handoff.sh as its
    # first executable statement. run_mog always invokes the fixture copy by
    # ABSOLUTE path, so the hand-off's relative-entry branch never fires here —
    # but the `.` line itself still requires the sibling to exist to source
    # cleanly, or every case below would fail closed at exit 2 before its own
    # gate logic ever runs. ANCHOR_HANDOFF_SRC is MOG_SRC's own twin.
    cp "${ANCHOR_HANDOFF_SRC:-$SCRIPT_DIR/../cr/anchor-handoff.sh}" "$tmp/scripts/cr/anchor-handoff.sh"
    # merge-on-green.sh now sources its in-use predicates from the
    # shared lib (../lib/worktree-inuse.sh, relative to its own SCRIPT_DIR) —
    # the copy must carry that sibling too. WT_INUSE_SRC is MOG_SRC's own twin
    # (same TEST-HARNESS-ONLY seam, same non-gate-integrity reasoning above):
    # it lets a RED control swap in a scratch MUTANT of the shared lib while
    # merge-on-green.sh itself stays the real, unmutated script (RC-1
    # mutates the ancestry-exclusion logic, which lives in the lib, not
    # in merge-on-green.sh's own guard). Defaults to the real file, so every
    # existing case that never sets it is unaffected.
    cp "${WT_INUSE_SRC:-$SCRIPT_DIR/../lib/worktree-inuse.sh}" "$tmp/scripts/lib/worktree-inuse.sh"
    # The PARTIAL report appends to the chief doc through this sibling.
    mkdir -p "$tmp/scripts/handover/chief-kit"
    cp "$SCRIPT_DIR/chief-kit/append-results.sh" "$tmp/scripts/handover/chief-kit/append-results.sh"
    cp "$SCRIPT_DIR/chief-kit/owe.sh" "$tmp/scripts/handover/chief-kit/owe.sh"
    cp "$SCRIPT_DIR/chief-kit/owed-events.py" "$tmp/scripts/handover/chief-kit/owed-events.py"
    # The partial-merge remainder reader, read from the anchor's scripts/lib.
    cp "$SCRIPT_DIR/../lib/pr_remainder.py" "$tmp/scripts/lib/pr_remainder.py"
    # The bug-origin ingest runs from the anchor after a merge. The real tree is linked, not copied (it is large and
    # read-only here); the ledger root each row picks is its own temp HANDOVER_DIR.
    # MOG_BO_REPORT=none leaves no reporter at the anchor; MOG_BO_REPORT=hang plants one that never returns.
    case "${MOG_BO_REPORT:-real}" in
        none) ;;
        hang) mkdir -p "$tmp/scripts/eval/bug-origin"
              printf 'import time\ntime.sleep(40)\n' > "$tmp/scripts/eval/bug-origin/bug-origin-report.py" ;;
        *) if [ -n "${MOG_CONFLICTS_REPORT:-}" ]; then
               mkdir -p "$tmp/scripts/eval/conflicts"
               ln -s "$SCRIPT_DIR/../eval/bug-origin" "$tmp/scripts/eval/bug-origin"
               ln -s "$SCRIPT_DIR/../eval/judge-accuracy" "$tmp/scripts/eval/judge-accuracy"
               [ "$MOG_CONFLICTS_REPORT" != fail ] || printf 'import sys\nsys.exit(1)\n' > "$tmp/scripts/eval/conflicts/conflicts.py"
               [ "$MOG_CONFLICTS_REPORT" != hang ] || printf 'import time\ntime.sleep(40)\n' > "$tmp/scripts/eval/conflicts/conflicts.py"
           else
               ln -s "$SCRIPT_DIR/../eval" "$tmp/scripts/eval"
           fi ;;
    esac
    # MOG_TIMEOUT_SHIM=1: a `timeout` that logs the bound of the bug-origin snapshot read and ingest to timeout.log and runs
    # neither (so nothing waits), and passes every other call to the real one.
    if [ "${MOG_TIMEOUT_SHIM:-0}" = "1" ]; then
        # The cr-thread recorder's call is logged apart, to cr-timeout.log, so the bug-origin rows never read it.
        printf '#!/usr/bin/env bash\ncase "$*" in\n  *cr-thread-recorder*) printf "%%s\\n" "$*" >> "%s/cr-timeout.log"; exit 0 ;;\n  *isCrossRepository*|*conflicts.py*) printf "%%s\\n" "$*" >> "%s/cf-timeout.log"; exit 0 ;;\n  *mergedAt*|*bug-origin-report*) printf "%%s\\n" "$*" >> "%s/timeout.log"; exit 0 ;;\nesac\nexec %s "$@"\n' \
            "$tmp" "$tmp" "$tmp" "$(command -v timeout || command -v gtimeout)" > "$tmp/bin/timeout"
        chmod +x "$tmp/bin/timeout"
    fi
    # The status lib is sourced from the anchor; the status funnel at its anchor
    # path is a stub that logs each event to funnel.log.
    cp "${TS_LIB_SRC:-$SCRIPT_DIR/../lib/ticket-status.sh}" "$tmp/scripts/lib/ticket-status.sh"
    cp "$SCRIPT_DIR/../lib/required-checks.sh" "$SCRIPT_DIR/../lib/prim.sh" "$SCRIPT_DIR/../lib/status-marker.sh" "$SCRIPT_DIR/../lib/merge-rows-effective.py" "$tmp/scripts/lib/"
    # shellcheck disable=SC2016 # $* must reach the stub FILE unexpanded
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/funnel.log"\n' "$tmp" > "$tmp/scripts/handover/chief-kit/worker-jira-status.sh"
    # The CR thread recorder at its anchor path is a stub: it logs its argv to
    # recorder.log and the env it was given to recorder.env, sleeps
    # STUB_RECORDER_SLEEP seconds, and exits STUB_RECORDER_RC (default 0).
    cat > "$tmp/scripts/cr/cr-thread-recorder.sh" <<'STUB'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")/../.." && pwd)
printf '%s\n' "$*" >> "$d/recorder.log"
printf 'GH_CMD=%s LEDGER=%s WAIT=%s SLEEP=%s TOKENS=%s FLOOR=%s CAP=%s REPO=%s\n' "${GH_CMD-unset}" "${CR_LEDGER-unset}" "${CR_RECORDER_MAX_WAIT-unset}" "${CR_RECORDER_SLEEP_CMD-unset}" "${CR_RECORDER_GH_TOKENS-unset}" "${CR_RECORDER_FLOOR-unset}" "${CR_RECORDER_LIST_CAP-unset}" "${CR_RECORDER_REPO-unset}" >> "$d/recorder.env"
[ -z "${STUB_RECORDER_SLEEP:-}" ] || sleep "$STUB_RECORDER_SLEEP"
exit "${STUB_RECORDER_RC:-0}"
STUB
    # merge-on-green now records the repo's CodeRabbit-availability
    # state on its audit lines, and reads it from this sibling. Without the copy
    # the source fails, CR_STATE falls back to `unknown`, and every cr= assertion
    # below would pass while testing nothing.
    cp "$SCRIPT_DIR/../lib/coderabbit-available.sh" "$tmp/scripts/lib/coderabbit-available.sh"
    cp "$SCRIPT_DIR/../lib/coderabbit-trigger-ledger.sh" "$SCRIPT_DIR/../lib/nwo.sh" "$SCRIPT_DIR/../lib/coderabbit-signal.sh" "$tmp/scripts/lib/"
    # The chief-GO gate resolves the GO file under handover_root.
    cp "$SCRIPT_DIR/../lib/handover-path.sh" "$tmp/scripts/lib/handover-path.sh"
    # The GO file check itself now lives in the shared predicate
    # go_gate() (also used by block-unresolved-cr-merge.sh's own gate).
    # GO_GATE_SRC is MOG_SRC's own twin (same TEST-HARNESS-ONLY seam, same
    # non-gate-integrity reasoning above): it lets a RED control swap in a
    # scratch mutant of go-gate.sh (e.g. truncated, so it sources but never
    # defines go_gate) while merge-on-green.sh itself stays whichever copy
    # MOG_SRC picked. Defaults to the real file.
    cp "${GO_GATE_SRC:-$SCRIPT_DIR/../lib/go-gate.sh}" "$tmp/scripts/lib/go-gate.sh"
    # The GitHub-blocked alert lib (sourced next to coderabbit-available.sh).
    # Its sender is a stub that only logs, so the suite can never DM the operator.
    cp "${MBA_LIB_SRC:-$SCRIPT_DIR/../lib/merge-block-alert.sh}" "$tmp/scripts/lib/merge-block-alert.sh"
    cp "$SCRIPT_DIR/../lib/resolve-node.sh" "$tmp/scripts/lib/resolve-node.sh"
    # Every chokepoint fails closed without its seam-guard lib.
    cp "$SCRIPT_DIR/../lib/chokepoint-seam-guard.sh" "$tmp/scripts/lib/chokepoint-seam-guard.sh"
    # ...and its registry: a MOG_ANCHOR_GIT fixture IS the anchor, so a marked
    # run with no claude ancestor (CI) reads the seams from here.
    cp "$SCRIPT_DIR/../chokepoints.json" "$tmp/scripts/chokepoints.json"
    # The pre-merge title guard (3c) calls this sibling, which in
    # turn invokes check-commit-msg.sh — both must be copied into the fixture
    # tree, since HIMMEL_REPO defaults to the fixture tree itself (himmel_repo_dir
    # above), never the real checkout.
    cp "$SCRIPT_DIR/../lib/check-pr-title.sh" "$tmp/scripts/lib/check-pr-title.sh"
    cp "$SCRIPT_DIR/../hooks/check-commit-msg.sh" "$tmp/scripts/hooks/check-commit-msg.sh"
    # check-commit-msg.sh fails closed without its resolver.
    cp "$SCRIPT_DIR/../lib/project-mode.sh" "$tmp/scripts/lib/project-mode.sh"
    chmod +x "$tmp/scripts/lib/check-pr-title.sh" "$tmp/scripts/hooks/check-commit-msg.sh"
    # What the gh stub serves as the DEFAULT branch's trust list.
    cp "$SCRIPT_DIR/../ci/ci-trust-paths.txt" "$tmp/trust-paths.base"
    # SC2016 is the point: $1/$2/$STUB_ALERT_FAIL must reach the stub FILE unexpanded.
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s/alerts.log"\n[ -z "${STUB_ALERT_FAIL:-}" ]\n' "$tmp" > "$tmp/bin/alert-sender"
    chmod +x "$tmp/bin/alert-sender"
    printf '{"allowFrom":["555"]}\n' > "$tmp/access.json"
    : > "$tmp/alerts.log"
    if [ "${STUB_ALERT_PRESEED:-0}" = "1" ]; then
        mkdir -p "$tmp/alerts"
        : > "$tmp/alerts/owner_repo__77__${STUB_SHA-abc123def456}"
    fi
    if [ "${NO_CHECK_CI:-0}" != "1" ]; then
        # The marker (check-ci.ran, sibling to the stub) proves
        # THIS stub actually executed — the RED assertion for the anchor fix
        # is that a worktree's own check-ci.sh must NOT run once HIMMEL_REPO
        # points at a distinct anchor tree; asserting only the exit code is
        # weaker and can pass vacuously (a fixture where the two trees agree
        # would look identical either way).
        # STUB_CI_RCS ("7 7 0") answers call N with its Nth code
        # (the last one repeats); check-ci.count counts the calls and
        # check-ci.distinct records each call's CHECK_CI_DISTINCT_DEADLINE.
        # shellcheck disable=SC2086 # word-split on purpose: one code per line
        printf '%s\n' ${STUB_CI_RCS:-${STUB_CI_RC:-0}} > "$tmp/scripts/check-ci.rcs"
        cat > "$tmp/scripts/check-ci.sh" <<'STUBCI'
#!/usr/bin/env bash
d=$(dirname "$0")
: > "$d/check-ci.ran"
[ -z "${STUB_CI_COMMIT:-}" ] || git commit -q --allow-empty -m "made during the CI watch"
printf "%s" "${MERGE_WATCH_POST_GO:-}" > "$d/check-ci.postgo"
printf "%s\n" "${CHECK_CI_DISTINCT_DEADLINE:-}" >> "$d/check-ci.distinct"
n=$(( $(cat "$d/check-ci.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/check-ci.count"
rc=$(sed -n "${n}p" "$d/check-ci.rcs")
[ -n "$rc" ] || rc=$(tail -n 1 "$d/check-ci.rcs")
exit "$rc"
STUBCI
        chmod +x "$tmp/scripts/check-ci.sh"
    fi

    # Stub the CR-marker chokepoint at ITS fixed sibling path,
    # exactly like check-ci above — the wrapper has no env seam for it either.
    # The stub records its argv, so a case can prove the merge path went THROUGH
    # clear-review-marker.sh (never a raw `rm`) and with which branch.
    if [ "${STUB_NO_CLEARER:-0}" != "1" ]; then
        mkdir -p "$tmp/scripts/cr"
        # SC2016 is the point: "$*" / "$CLEAR_LOG" must reach the stub FILE
        # unexpanded, to be expanded when the wrapper runs it. It also appends a
        # PREFIXED line to the gh log, which is the suite's only ordering record
        # — that is what pins the clear to BEFORE the merge (11L).
        # shellcheck disable=SC2016
        # It also records its cwd: the real clearer refuses a
        # branch other than the one checked out where it runs, so the wrapper
        # must run it from that branch's own worktree.
        printf '#!/usr/bin/env bash\necho "clear-cr-marker $*" >> "$GH_LOG"\necho "$*" >> "$CLEAR_LOG"\npwd -P >> "$CLEAR_LOG.cwd"\nexit %s\n' \
            "${STUB_CLEAR_RC:-0}" > "$tmp/scripts/cr/clear-review-marker.sh"
        chmod +x "$tmp/scripts/cr/clear-review-marker.sh"
    fi

    # Stub `gh`, FIRST on PATH (no GH_CMD seam). FAILS CLOSED: an
    # unsupported verb or an unrecognized --json query exits non-zero rather than
    # falling through to a silent success — otherwise a wrapper that grew a new gh
    # call would be "tested" against a stub that rubber-stamps anything.
    cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
verb="$1 $2"
repo_arg="${3:-}"
api_path="${2:-}"
json=""
jqexpr=""
run_branch="" run_workflow="" run_attempt="" run_event=""
while [ $# -gt 0 ]; do case "$1" in --json) json="${2:-}";; --jq) jqexpr="${2:-}";; --branch) run_branch="${2:-}";; --workflow) run_workflow="${2:-}";; --attempt) run_attempt="${2:-}";; --event) run_event="${2:-}";; esac; shift; done
nwo="${STUB_NWO:-owner/repo}"
def_files='[{"filename":"README.md"}]'
gh_hint() { [ "${STUB_GH_HINT:-0}" = "1" ] || return 0; printf 'hint: if you need to wait for this pull request to be merged or its checks to complete, do not poll it in a loop: one blocking call returns the moment its state changes, costs a single API request instead of one per interval, and leaves the rate limit free for other work\nhint: use this instead of polling: gh event listen --repo %s\n' "$nwo" >&2; }
case "$verb" in
    "pr list")
        [ "${STUB_OPEN_PRS_FAIL:-0}" = "1" ] && { echo "gh: list failed" >&2; exit 1; }
        printf '%s' "${STUB_OPEN_PRS-}"; exit 0 ;;
    "pr view")
        [ "${STUB_NO_PR:-0}" = "1" ] && { echo 'no pull requests found for branch "x"' >&2; gh_hint; exit 1; }
        [ "${STUB_NO_CWD_PR:-0}" = "1" ] && [ "${repo_arg#-}" != "$repo_arg" ] && { echo 'no pull requests found for branch "main"' >&2; exit 1; }
        [ "${STUB_STATE_FAIL:-0}" = "hint-only" ] && { gh_hint; exit 1; }
        [ "${STUB_STATE_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
        case "$json" in
            title)
                # Shared by TWO callers: jira_auto_transition_on_merge's own
                # title read (--json title -q .title, no --jq) AND the
                # pre-merge title gate (--json title --jq '.title').
                # Defaults to a conventional, ticketed (JIRA_PROJECT_KEY=HIMMEL
                # above), UNBRACKETED title — passes the title gate (so
                # every pre-existing case, which never sets STUB_PR_TITLE, is
                # unaffected) while carrying no `[KEY-N]` bracket tag, so
                # jira_auto_transition's own extraction still resolves to its
                # no-op skip by default.
                printf '%s' "${STUB_PR_TITLE-fix(x): HIMMEL-1 stub title}" ;;
            title,author)
                # Guard 3c's
                # own query, distinct from the "title"-only case above (jira's
                # caller never asks for author) — tab-separated title\tauthor,
                # matching the wrapper's --jq expression.
                printf '%s\t%s' "${STUB_PR_TITLE-fix(x): HIMMEL-1 stub title}" "${STUB_PR_AUTHOR-someone}" ;;
            "state,url,number,headRefOid,baseRefName,headRefName")
                # Consolidated meta query (baseRefName; then headRefName, LAST, for the
                # post-merge worktree prune):
                # state|url|number|headRefOid|baseRefName|headRefName.
                if [ "${STUB_META_5FIELD:-0}" = "1" ]; then
                    # Shape without headRefName. The wrapper
                    # must refuse, not let head_branch collapse onto pr_base.
                    printf '%s|https://github.com/%s/pull/%s|%s|%s|%s' \
                        "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" "${STUB_BASE-main}"
                    exit 0
                fi
                printf '%s|https://github.com/%s/pull/%s|%s|%s|%s|%s' \
                    "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" "${STUB_BASE-main}" "${STUB_HEAD_BRANCH-feat/stub-head}"
                gh_hint ;;
            body)
                # Defaults to a body that records a remainder: a partial (bare) merge of a ticket-tagged PR
                # whose body records none is refused (exit 26), and most cases are bare merges.
                printf '%s' "${STUB_PR_BODY-Remaining: the next slice}"
                exit "${STUB_BODY_RC:-0}" ;;
            "mergeStateStatus,reviewDecision")
                [ "${STUB_POLICY_FAIL:-0}" = "1" ] && { echo "gh: policy query failed" >&2; exit 1; }
                printf '%s|%s' "${STUB_MERGE_STATE-CLEAN}" "${STUB_REVIEW_DECISION-}" ;;
            "baseRefName")
                # FIX-1 pre-merge re-query:
                # a fresh baseRefName read right before merging, independent of
                # the consolidated meta query above. Defaults to STUB_BASE so
                # existing tests (no premerge override) see an unchanged base.
                # `-` (not `:-`) so an explicitly-empty STUB_BASE_PREMERGE is
                # preserved, letting a test simulate an empty pre-merge base
                # (fail-closed path) rather than silently defaulting.
                printf '%s' "${STUB_BASE_PREMERGE-${STUB_BASE-main}}" ;;
            "state,headRefOid")
                # merge-on-green's between-rounds re-read, before
                # it watches a DEADLINE-PENDING check-ci again — the PR must
                # still be OPEN at the certified head.
                [ "${STUB_ROUND_FAIL:-0}" = "1" ] && { echo "gh: round query failed" >&2; exit 1; }
                printf '%s %s' "${STUB_ROUND_STATE:-OPEN}" "${STUB_ROUND_HEAD:-${STUB_SHA-abc123def456}}" ;;
            "state,headRefOid,baseRefName")
                # Post-merge re-query — shared by BOTH the failure-recovery
                # path AND the success-path confirmation poll:
                # state PLUS the merged head and base, so either
                # path can tell "this run's sha merged onto the authorized
                # base" apart from both "a different commit merged
                # concurrently" and "the same sha merged onto a different
                # (retargeted) base". The plain "state"-only query this used
                # to be has no caller left
                # in merge-on-green.sh; removed rather than left dead.
                [ "${STUB_POST_STATE_FAIL:-0}" = "1" ] && { echo "gh: state query failed" >&2; exit 1; }
                # STUB_POST_OPEN_TIMES=N: the first N re-queries
                # report OPEN, the rest report STUB_POST_STATE — a merge that
                # was accepted server-side and only reflects a moment later.
                # Routed by call ORDER via the gh argv log (this call is already
                # appended at the top of the stub), same trick as `repo view`.
                if [ "${STUB_POST_OPEN_TIMES:-0}" != "0" ]; then
                    n=$(grep -c 'json state,headRefOid,baseRefName' "$GH_LOG" 2>/dev/null || echo 1)
                    if [ "${n:-1}" -le "${STUB_POST_OPEN_TIMES}" ]; then
                        printf 'OPEN %s %s' "${STUB_POST_HEAD:-${STUB_SHA-abc123def456}}" "${STUB_POST_BASE:-${STUB_BASE-main}}"
                        exit 0
                    fi
                fi
                printf '%s %s %s' "${STUB_POST_STATE:-MERGED}" "${STUB_POST_HEAD:-${STUB_SHA-abc123def456}}" "${STUB_POST_BASE:-${STUB_BASE-main}}" ;;
            commits)
                # The PR's commit messages, read only when main is
                # red, to find a `Fixes-main-red:` declaration. Real jq through
                # the script's own --jq.
                [ "${STUB_COMMITS_FAIL:-0}" = "1" ] && { echo "gh: commits failed" >&2; exit 1; }
                printf '%s' "${STUB_PR_COMMITS_JSON:-{\"commits\":[]\}}" | jq -r "$jqexpr" ;;
            comments)
                # After-report pending marker: the wrapper pipes
                # this raw JSON through a REAL jq --arg pass (gh's own --jq
                # has no --arg support), so this must be realistic
                # {"comments":[...]} shape, not a pre-filtered count. A
                # matching comment embeds 'head: <STUB_SHA>' — the wrapper's
                # jq filter requires that exact head-SHA binding.
                # Default: no
                # comments at all (no after-report posted yet).
                if [ "${STUB_AFTER_REPORT_SUMMARIES:-0}" != "0" ]; then
                    printf '{"comments":[{"body":"== Summary ==\\n head: %s\\n PASS: 5\\n FAIL: 0\\n"}]}' \
                        "${STUB_SHA-abc123def456}"
                else
                    printf '{"comments":[]}'
                fi ;;
            number,title,body,mergedAt,headRefName,headRefOid,mergeCommit)
                # The bug-origin snapshot of the merged PR (one object, as `gh pr view` prints it): the body is the
                # body STUB_PR_BODY serves, the merge time is fixed.
                [ "${STUB_SNAPSHOT_FAIL:-0}" = "1" ] && { echo "gh: snapshot failed" >&2; exit 1; }
                # A hung read: the process itself sleeps (exec), so the bound's kill ends it and no child holds the pipe.
                [ "${STUB_SNAPSHOT_HANG:-0}" = "1" ] && exec sleep 40
                jq -n --argjson n "${STUB_NUM:-77}" --arg t "${STUB_PR_TITLE-fix(x): HIMMEL-1 stub title}" \
                    --arg b "${STUB_PR_BODY-Remaining: the next slice}" --arg h "${STUB_SHA-abc123def456}" \
                    '{number: $n, title: $t, body: $b, mergedAt: "2026-11-03T09:00:00Z", headRefName: "feat/stub-head", headRefOid: $h, mergeCommit: {oid: $h}}' ;;
            number,title,body,mergedAt,mergeCommit,headRefOid,isCrossRepository)
                [ "${STUB_SNAPSHOT_FAIL:-0}" = "1" ] && { echo "gh: snapshot failed" >&2; exit 1; }
                [ "${STUB_CF_SNAPSHOT_HANG:-0}" = "1" ] && exec sleep 40
                jq -n --argjson n "${STUB_NUM:-77}" --arg t "${STUB_PR_TITLE-fix(x): HIMMEL-1 stub title}" \
                    --arg b "${STUB_PR_BODY-Remaining: the next slice}" --arg h "${STUB_SHA-abc123def456}" \
                    '{number: $n, title: $t, body: $b, mergedAt: "2026-11-03T09:00:00Z", headRefOid: $h, mergeCommit: {oid: $h}, isCrossRepository: false}' ;;
            *) echo "gh stub: unhandled 'pr view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "repo view")
        # isPrivate + defaultBranchRef are queried TOGETHER (the
        # base-branch guard shares the SAME query, no extra round-trip) and
        # keyed off the repo POSITIONAL ($3) — the PR's own repo, not cwd
        # nameWithOwner (no positional) = the CURRENT checkout for
        # the same-repo binding.
        case "$json" in
            isPrivate,defaultBranchRef)
                if [ -z "$jqexpr" ]; then
                    echo "gh stub: 'repo view' isPrivate,defaultBranchRef missing required --jq expression" >&2
                    exit 93
                fi
                # Assert the positional repo arg — a regression
                # back to a cwd-scoped query would otherwise pass silently.
                if [ "$repo_arg" != "$nwo" ]; then
                    echo "gh stub: 'repo view' isPrivate,defaultBranchRef queried '$repo_arg', expected the PR repo '$nwo'" >&2
                    exit 92
                fi
                # This shape is queried TWICE per run — guard 2b (query time)
                # and the FIX-1 pre-merge re-verify (isPrivate is folded
                # into the pre-merge repo view). Route by call ORDER via
                # the gh argv log: 1st occurrence = guard 2b, 2nd = pre-merge.
                # This call is already appended to GH_LOG (top of stub), so the
                # match count is 1 on the first call, 2 on the second.
                n=$(grep -c 'isPrivate,defaultBranchRef' "$GH_LOG" 2>/dev/null || echo 1)
                if [ "${n:-1}" -le 1 ]; then
                    # guard 2b (query time). defaultBranchRef is NULLABLE:
                    # feed synthetic null JSON through the SCRIPT'S
                    # OWN --jq filter (captured above) via real jq, proving the
                    # coalesce fix in merge-on-green.sh rather than a stub string.
                    if [ "${STUB_DEFAULT_BRANCH_NULL:-0}" = "1" ]; then
                        printf '{"isPrivate":%s,"defaultBranchRef":null}' "${STUB_PRIVATE-true}" | jq -r "$jqexpr"
                    else
                        printf '%s|%s' "${STUB_PRIVATE-true}" "${STUB_DEFAULT_BRANCH-main}"
                    fi
                else
                    # FIX-1 pre-merge re-verify (privacy + default branch both
                    # re-read). STUB_PRIVATE_PREMERGE / STUB_DEFAULT_BRANCH_PREMERGE
                    # default to their guard-2b values so tests that don't
                    # override see an unchanged repo.
                    if [ "${STUB_DEFAULT_BRANCH_PREMERGE_NULL:-0}" = "1" ]; then
                        printf '{"isPrivate":%s,"defaultBranchRef":null}' "${STUB_PRIVATE_PREMERGE:-${STUB_PRIVATE-true}}" | jq -r "$jqexpr"
                    else
                        printf '%s|%s' "${STUB_PRIVATE_PREMERGE:-${STUB_PRIVATE-true}}" "${STUB_DEFAULT_BRANCH_PREMERGE:-${STUB_DEFAULT_BRANCH-main}}"
                    fi
                fi ;;
            nameWithOwner)
                # No positional — this is the CURRENT checkout query
                # not the PR's repo. Do NOT add a repo_arg check.
                [ "${STUB_CWD_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
                printf '%s' "${STUB_CWD_NWO:-${STUB_NWO:-owner/repo}}" ;;
            *) echo "gh stub: unhandled 'repo view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "pr merge")
        [ "${STUB_MERGE_POLICY_REFUSED:-0}" = "1" ] && { echo "Pull request $nwo#77 is not mergeable: the base branch policy prohibits the merge." >&2; exit 1; }
        [ "${STUB_MERGE_REQUIRED_CHECK:-0}" = "1" ] && { echo "Pull request $nwo#77 is not mergeable: Required status check \"codeowner-review-gate\" is expected." >&2; exit 1; }
        [ "${STUB_MERGE_BASE_MODIFIED:-0}" = "1" ] && { echo "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" >&2; exit 1; }
        [ "${STUB_MERGE_FAIL:-0}" = "1" ] && { echo "merge conflict / head moved" >&2; exit 1; }
        # STUB_MERGE_SNAPSHOT=1: copy the status-events rows as they stand when the merge call runs.
        [ "${STUB_MERGE_SNAPSHOT:-0}" != "1" ] || cp "$TICKET_STATUS_STATE_DIR/status-events.jsonl" "$GH_LOG.rows-at-merge" 2>/dev/null || : > "$GH_LOG.rows-at-merge"
        # STUB_MERGE_KILL=before|after: SIGKILL the outermost merge-on-green.sh before the merge lands / right after it did.
        if [ "${STUB_MERGE_KILL:-}" = "before" ] || [ "${STUB_MERGE_KILL:-}" = "after" ]; then
            [ "$STUB_MERGE_KILL" != "after" ] || echo "merged"
            victim="" pid=$$
            while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
                case "$(ps -o args= -p "$pid" 2>/dev/null)" in *scripts/handover/merge-on-green.sh*) victim=$pid ;; esac
                pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            done
            [ -z "$victim" ] || kill -9 "$victim"
            sleep 1
        fi
        echo "merged"
        ;;
    "pr comment")
        [ "${STUB_PR_COMMENT_FAIL:-0}" = "1" ] && { echo "gh: comment failed" >&2; exit 1; }
        exit 0 ;;
    "run list")
        # The red-main gate's read of main's CI runs. The JSON goes
        # through the SCRIPT'S OWN --jq via real jq. Unset STUB_RUN_LIST_JSON
        # serves STUB_RUN_LIST_JSON_DEFAULT, a real green window (exported once,
        # below the fixture builder), so every pre-existing case sees a green main.
        [ "${STUB_RUN_LIST_FAIL:-0}" = "1" ] && { echo "gh: run list failed" >&2; exit 1; }
        [ -n "$jqexpr" ] || { echo "gh stub: 'run list' missing --jq" >&2; exit 93; }
        # A real `gh run list` without these flags returns every branch's and
        # workflow's runs, so a call that drops one must not see main's window.
        [ "$run_branch" = "${STUB_DEFAULT_BRANCH-main}" ] || { echo "gh stub: 'run list' --branch '$run_branch' is not the default branch" >&2; exit 94; }
        [ "$run_workflow" = "CI" ] || { echo "gh stub: 'run list' --workflow '$run_workflow' is not CI" >&2; exit 95; }
        # --event workflow_dispatch is the post-merge recheck's look at the run it
        # dispatched: STUB_DISPATCH_BEFORE_JSON until a `workflow run` has been
        # logged, STUB_DISPATCH_AFTER_JSON from then on.
        if [ -n "$run_event" ]; then
            [ "$run_event" = workflow_dispatch ] || { echo "gh stub: 'run list' --event '$run_event' is not workflow_dispatch" >&2; exit 97; }
            if grep -q '^workflow run ' "$GH_LOG"; then
                printf '%s' "${STUB_DISPATCH_AFTER_JSON:-[]}" | jq -r "$jqexpr"
            else
                printf '%s' "${STUB_DISPATCH_BEFORE_JSON:-[]}" | jq -r "$jqexpr"
            fi
            exit 0
        fi
        printf '%s' "${STUB_RUN_LIST_JSON-${STUB_RUN_LIST_JSON_DEFAULT:-[]}}" | jq -r "$jqexpr" ;;
    "workflow run")
        # The post-merge recheck of main: `workflow run ci.yml --repo R --ref main`.
        [ "${STUB_WORKFLOW_RUN_FAIL:-0}" = "1" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
        exit 0 ;;
    "run view")
        [ "${STUB_RUN_VIEW_FAIL:-0}" = "1" ] && { echo "gh: run view failed" >&2; exit 1; }
        # `run view <id> --attempt N --json conclusion --jq ...`: the conclusion
        # of an earlier attempt of a run that is being re-run (a re-run keeps
        # the run id). STUB_RUN_ATTEMPT_CONCLUSION answers it, through the
        # script's own --jq and real jq.
        if [ "$json" = conclusion ]; then
            [ "${STUB_RUN_ATTEMPT_FAIL:-0}" = "1" ] && { echo "gh: run view --attempt failed" >&2; exit 1; }
            [ -n "$jqexpr" ] || { echo "gh stub: 'run view --json conclusion' missing --jq" >&2; exit 93; }
            [ -n "$run_attempt" ] || { echo "gh stub: 'run view --json conclusion' missing --attempt" >&2; exit 96; }
            printf '{"conclusion":"%s"}' "${STUB_RUN_ATTEMPT_CONCLUSION-failure}" | jq -r "$jqexpr"
            exit 0
        fi
        # `run view <id> --json jobs --jq ...`: the run's job list, which the cap-only
        # classifier cross-checks against the jobs the failed log shows. Unset
        # STUB_RUN_JOBS_JSON is a run whose every job passed.
        if [ "$json" = jobs ]; then
            [ "${STUB_RUN_JOBS_FAIL:-0}" = "1" ] && { echo "gh: run view --json jobs failed" >&2; exit 1; }
            [ -n "$jqexpr" ] || { echo "gh stub: 'run view --json jobs' missing --jq" >&2; exit 93; }
            stub_jobs_json="${STUB_RUN_JOBS_JSON:-}"
            [ -n "$stub_jobs_json" ] || stub_jobs_json='{"jobs":[]}'
            printf '%s' "$stub_jobs_json" | jq -r "$jqexpr"
            exit 0
        fi
        cat "${STUB_RUN_LOG_FILE:-/dev/null}" ;;
    "api repos/"*)
        # public_origin_merge_allowed's branch-protection read.
        # Match ONLY the classic protection endpoint; anything else this stub
        # does not recognize fails closed like every other unhandled shape.
        case "$api_path" in
            */branches/*/protection)
                if [ -z "$jqexpr" ]; then
                    echo "gh stub: 'api repos/.../protection' missing required --jq expression" >&2
                    exit 93
                fi
                # Queried TWICE per run when the widened path is reached: guard
                # 2b (query time) and the pre-merge re-check (mirrors
                # the isPrivate/defaultBranchRef routing above). Routed by call
                # ORDER via the gh argv log — this call is already appended at
                # the top of the stub, so the match count is 1 on the first call,
                # 2 on the second.
                n=$(grep -c '/protection' "$GH_LOG" 2>/dev/null || echo 1)
                if [ "${n:-1}" -le 1 ]; then
                    [ "${STUB_PROTECTION_FAIL:-0}" = "1" ] && { echo "gh: protection unreadable" >&2; exit 1; }
                    if [ -n "${STUB_PROTECTION_JSON:-}" ]; then
                        # Real protection JSON through the SCRIPT'S OWN --jq
                        # filter via real jq, same technique STUB_DEFAULT_BRANCH_NULL
                        # uses — proves the script's own `// []` coalesce.
                        printf '%s' "$STUB_PROTECTION_JSON" | jq -r "$jqexpr"
                    else
                        # `-` not `:-`: an explicitly-empty STUB_PROTECTION must
                        # be preserved so a fail-closed empty-body case is reachable.
                        printf '%s' "${STUB_PROTECTION-true|10|0}"
                    fi
                else
                    [ "${STUB_PROTECTION_PREMERGE_FAIL:-0}" = "1" ] && { echo "gh: protection unreadable" >&2; exit 1; }
                    # STUB_PROTECTION_JSON_PREMERGE overrides the JSON replayed
                    # on THIS (second) read only — `-` (not `:-`) so an
                    # explicitly-empty override is preserved, mirroring
                    # STUB_PROTECTION_PREMERGE's own relation to STUB_PROTECTION
                    # just below. Falls back to STUB_PROTECTION_JSON when unset,
                    # so existing single-JSON cases are unaffected.
                    json_val_premerge="${STUB_PROTECTION_JSON_PREMERGE-${STUB_PROTECTION_JSON:-}}"
                    if [ -n "$json_val_premerge" ]; then
                        printf '%s' "$json_val_premerge" | jq -r "$jqexpr"
                    else
                        printf '%s' "${STUB_PROTECTION_PREMERGE-${STUB_PROTECTION-true|10|0}}"
                    fi
                fi ;;
            */rules/branches/*|*/rulesets/*)
                # The ruleset probe: effective rules for the base
                # branch (rules/branches/<b>) then each contributing ruleset
                # (rulesets/<id>). Real JSON through the SCRIPT'S OWN --jq via
                # real jq. Routed first-read / pre-merge-read by the per-endpoint
                # count in the gh argv log (this call is already logged, so the
                # count is 1 on a site's first read). Unset JSON = 404, so every
                # pre-existing case (which never sets these) sees "no ruleset".
                if [ -z "$jqexpr" ]; then
                    echo "gh stub: ruleset read missing required --jq expression" >&2
                    exit 93
                fi
                case "$api_path" in
                    */rules/branches/*) rk=RULES; rpat='/rules/branches/' ;;
                    *) rk=RULESET; rpat='/rulesets/' ;;
                esac
                # STUB_RULESET_JSON_<id> (numeric id) overrides the
                # shared STUB_RULESET_JSON for that one ruleset, so a case can make
                # only ONE contributing ruleset weak. Unset = the shared body.
                json_var="STUB_${rk}_JSON"
                rid="${api_path##*/}"
                case "$rk|$rid" in
                    RULESET\|*[!0-9]*|RULESET\|) ;;
                    RULESET\|*) id_var="STUB_RULESET_JSON_$rid"; [ -n "${!id_var+x}" ] && json_var="$id_var" ;;
                esac
                n=$(grep -c "$rpat" "$GH_LOG" 2>/dev/null || echo 1)
                if [ "${n:-1}" -le 1 ]; then
                    fail_var="STUB_${rk}_FAIL"
                    [ "${!fail_var:-0}" = "1" ] && { echo "gh: $rk unreadable" >&2; exit 1; }
                    json_val="${!json_var:-}"
                else
                    fail_var="STUB_${rk}_PREMERGE_FAIL"; pm_var="STUB_${rk}_JSON_PREMERGE"
                    [ "${!fail_var:-0}" = "1" ] && { echo "gh: $rk unreadable" >&2; exit 1; }
                    json_val="${!pm_var-${!json_var:-}}"
                fi
                [ -n "$json_val" ] || { echo "gh: HTTP 404 (no ruleset)" >&2; exit 1; }
                printf '%s' "$json_val" | jq -r "$jqexpr"
                ;;
            */contents/scripts/ci/ci-trust-paths.txt\?ref=*)
                # The trust-path list, read from the DEFAULT
                # branch. Defaults to the real list (copied into the fixture as
                # trust-paths.base), so every case runs against what ships.
                [ "${STUB_TRUST_LIST_404:-0}" = "1" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                [ "${STUB_TRUST_LIST_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
                if [ -n "${STUB_TRUST_LIST+x}" ]; then
                    printf '%s' "$STUB_TRUST_LIST"
                else
                    cat "$(dirname "$0")/../trust-paths.base"
                fi ;;
            */pulls/[0-9]*/files)
                # The PR's changed files. Real JSON through the
                # SCRIPT'S OWN --jq via real jq. Default: one non-trust file.
                [ -n "$jqexpr" ] || { echo "gh stub: pulls/N/files missing --jq" >&2; exit 93; }
                [ "${STUB_PR_FILES_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
                printf '%s' "${STUB_PR_FILES_JSON:-$def_files}" | jq -r "$jqexpr" ;;
            */pulls/[0-9]*)
                # Head sha + changed_files, read before AND after
                # the file listing (routed by call order, as for protection).
                [ -n "$jqexpr" ] || { echo "gh stub: pulls/N missing --jq" >&2; exit 93; }
                n=$(grep -cE 'pulls/[0-9]+( |$)' "$GH_LOG" 2>/dev/null || echo 1)
                ph="${STUB_PR_HEAD:-${STUB_SHA-abc123def456}}"
                [ "${n:-1}" -gt 1 ] && ph="${STUB_PR_HEAD_SECOND:-$ph}"
                cf="${STUB_PR_CHANGED_FILES:-$(printf '%s' "${STUB_PR_FILES_JSON:-$def_files}" | jq length)}"
                printf '{"head":{"sha":"%s"},"changed_files":%s}' "$ph" "$cf" | jq -r "$jqexpr" ;;
            */contents/.claude/settings.json\?ref=*)
                # The repo's settings, read when its trust list is missing:
                # none here, so the repo has not adopted himmel.
                echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
            *) echo "gh stub: unhandled 'api' path: $api_path" >&2; exit 90 ;;
        esac
        ;;
    *) echo "gh stub: unsupported command: $*" >&2; exit 90 ;;
esac
exit 0
STUB
    chmod +x "$tmp/bin/gh"

    # STUB_JIRA_BUILD=1: fake a built Jira CLI + reconcile-config
    # so jira_auto_transition_on_merge's repo_root/config/node calls are
    # reachable. run_mog's cwd defaults to $tmp itself, so git-init IT and
    # place scripts/jira/ there — repo_root then resolves to $tmp. A stub
    # `node` intercepts ONLY the dist/index.js CLI invocations (logging their
    # argv to $JIRA_LOG, read at runtime like GH_LOG/CLEAR_LOG above) and execs
    # the REAL node for the function's own `node -e` config-parsing call, so
    # that lookup still runs for real.
    if [ "${STUB_JIRA_BUILD:-0}" = "1" ]; then
        git init -q "$tmp" >/dev/null 2>&1
        mkdir -p "$tmp/scripts/jira/dist"
        : > "$tmp/scripts/jira/dist/index.js"
        printf '{"HIMMEL":{"targetStatus":"Done"}}\n' > "$tmp/scripts/jira/reconcile-config.json"
        local real_node; real_node=$(command -v node)
        cat > "$tmp/bin/node" <<STUBNODE
#!/usr/bin/env bash
if [ "\$1" = "-e" ]; then
    exec "$real_node" "\$@"
fi
case "\$1" in
    */dist/index.js)
        echo "\$*" >> "\$JIRA_LOG"
        # The name each edit carries into the Fix Version journal.
        if [ "\$2" = "edit" ]; then echo "edit-writer: \${HIMMEL_VERSION_WRITER:-unset}" >> "\$JIRA_LOG"; fi
        if [ "\$2" = "comment" ] && [ "\$4" = "--comment-file" ] && [ -f "\$5" ]; then
            sed 's/^/comment-body: /' "\$5" >> "\$JIRA_LOG"
        fi
        # STUB_JIRA_KILL_RUN=1: the run is killed in the Jira step (SIGKILL to the outermost merge-on-green.sh process).
        if [ "\$2" = "get" ] && [ "\${STUB_JIRA_KILL_RUN:-0}" = "1" ]; then
            victim="" pid=\$\$
            while [ -n "\$pid" ] && [ "\$pid" -gt 1 ]; do
                case "\$(ps -o args= -p "\$pid" 2>/dev/null)" in *scripts/handover/merge-on-green.sh*) victim=\$pid ;; esac
                pid=\$(ps -o ppid= -p "\$pid" 2>/dev/null | tr -d ' ')
            done
            [ -z "\$victim" ] || kill -9 "\$victim"
            sleep 1
        fi
        # STUB_JIRA_TRANSITION_STAMPS=<v>: the transition stamps <v>, and every later get reads it back.
        if [ "\$2" = "get" ] && [ -n "\${STUB_JIRA_TRANSITION_STAMPS:-}" ] && [ -e "\$JIRA_LOG.stamped" ]; then
            printf '{"fields":{"issuetype":{"name":"Task"},"status":{"name":"Done"},"fixVersions":[{"name":"%s"}]}}\n' "\$STUB_JIRA_TRANSITION_STAMPS"
            exit 0
        fi
        if [ "\$2" = "transition" ] && [ -n "\${STUB_JIRA_TRANSITION_STAMPS:-}" ]; then
            : > "\$JIRA_LOG.stamped"
            echo "\$3 fixVersion +\$STUB_JIRA_TRANSITION_STAMPS (earliest unreleased; --no-version opts out)"
            exit 0
        fi
        if [ "\$2" = "get" ] && [ "\${STUB_JIRA_NO_FIXVERSIONS:-0}" = "1" ]; then
            printf '{"fields":{"issuetype":{"name":"%s"},"status":{"name":"%s"}}}\n' "\${STUB_JIRA_ISSUE_TYPE:-Task}" "\${STUB_JIRA_STATUS-In Review}"
            exit 0
        fi
        if [ "\$2" = "get" ]; then
            printf '{"fields":{"issuetype":{"name":"%s"},"status":{"name":"%s"},"fixVersions":[%s]}}\n' "\${STUB_JIRA_ISSUE_TYPE:-Task}" "\${STUB_JIRA_STATUS-In Review}" "\${STUB_JIRA_FIXVERSIONS:-}"
            exit 0
        fi
        if [ "\$2" = "versions" ]; then
            printf '%b' "\${STUB_JIRA_VERSIONS:-v1.1.2\\ttrue\\t2026-10-11\\nv1.1.4\\tfalse\\t\\nv1.1.3\\tfalse\\t2026-10-22\\n}"
            exit 0
        fi
        if [ "\${STUB_JIRA_TRANSITION_FAIL:-0}" = "1" ] && [ "\$2" = "transition" ]; then
            echo "jira transition failed" >&2
            exit 1
        fi
        if [ "\${STUB_JIRA_TRANSITION_RC3:-0}" = "1" ] && [ "\$2" = "transition" ]; then
            echo "FAIL $KP-374 closed with no fixVersion: deferred out of frozen v1.1.3" >&2
            exit 3
        fi
        if [ "\$2" = "release" ] && [ "\$3" = "bucket-check" ]; then
            [ -z "\${STUB_BUCKET_SLEEP:-}" ] || sleep "\$STUB_BUCKET_SLEEP"
            [ -z "\${STUB_BUCKET_VERDICT:-}" ] || printf '%s\n' "\$STUB_BUCKET_VERDICT"
            [ -z "\${STUB_BUCKET_SLEEP_AFTER:-}" ] || sleep "\$STUB_BUCKET_SLEEP_AFTER"
            exit "\${STUB_BUCKET_RC:-0}"
        fi
        if [ "\$2" = "release" ] && [ "\$3" = "request" ]; then
            [ "\${STUB_JIRA_REQUEST_FAIL:-0}" = "1" ] && { echo "release request: refused" >&2; exit 1; }
            req_verb="" req_key="" req_why=""
            while [ \$# -gt 0 ]; do
                case "\$1" in
                    --verb|--key|--why)
                        case "\${2:-}" in ""|--*) echo "release request: \$1 needs a value" >&2; exit 1 ;; esac ;;
                esac
                case "\$1" in
                    --verb) req_verb="\$2" ;;
                    --key) req_key="\$2" ;;
                    --why) req_why="\$2" ;;
                esac
                shift
            done
            [ -n "\$req_verb" ] && [ -n "\$req_key" ] && [ -n "\$req_why" ] || { echo "release request: --verb, --key and --why are required" >&2; exit 1; }
            echo "REQ Q-v1.1.3-0099"
            exit 0
        fi
        if [ "\${STUB_JIRA_FIX_FAIL:-0}" = "1" ] && [ "\$4" = "--fix-version" ]; then
            echo "jira fix-version failed" >&2
            exit 1
        fi
        if [ "\${STUB_JIRA_ADD_FIX_FAIL:-0}" = "1" ] && [ "\$4" = "--add-fix-version" ]; then
            echo "jira add-fix-version failed" >&2
            exit 1
        fi
        if [ "\${STUB_JIRA_ADD_FIX_FAIL_ONCE:-0}" = "1" ] && [ "\$4" = "--add-fix-version" ] && [ ! -e "\$JIRA_LOG.addfailed" ]; then
            : > "\$JIRA_LOG.addfailed"
            echo "jira add-fix-version failed once" >&2
            exit 1
        fi
        if [ "\${STUB_JIRA_COMMENT_FAIL:-0}" = "1" ] && [ "\$2" = "comment" ]; then
            echo "jira comment failed" >&2
            exit 1
        fi
        exit 0
        ;;
    *)
        exec "$real_node" "\$@"
        ;;
esac
STUBNODE
        chmod +x "$tmp/bin/node"
    fi
}

run_mog() {
    local expected="$1" name="$2"; shift 2
    [ "${1:-}" = "--" ] && shift
    # Templated + guarded (known-findings [mktemp-no-template]): a bare
    # `mktemp -d` is a BSD/macOS portability hazard, and an unchecked one
    # leaves $tmp EMPTY so every path below is built at the filesystem root.
    # Fixed rather than pre-rebutted.
    local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-run.XXXXXX")
    if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
        fail "$name — mktemp -d produced no run sandbox; refusing to build fixture paths on an empty root"
        return
    fi
    local ghlog="$tmp/gh.log"; : > "$ghlog"
    local audit="$tmp/audit.log"
    [ "${STUB_AUDIT_UNWRITABLE:-0}" = "1" ] && audit="$tmp/nodir/audit.log"  # parent absent → unwritable
    local clearlog="$tmp/clear.log"; : > "$clearlog"
    local jiralog="$tmp/jira.log"; : > "$jiralog"

    mog_build_fixture "$tmp"
    [ "${MOG_NO_RECORDER:-0}" != "1" ] || rm -f "$tmp/scripts/cr/cr-thread-recorder.sh"
    # MOG_POISON=<path under scripts/> replaces that helper in the
    # WORKTREE tree with a branch-side mutant that leaves a marker and exits 42
    # (sourced: kills the whole gate; executed: a failing clear). Paired with
    # MOG_HIMMEL_REPO at a distinct anchor, it proves the anchor's copy runs.
    if [ -n "${MOG_POISON:-}" ]; then
        if ! printf '#!/usr/bin/env bash\n: > "%s/poison.ran"\nexit 42\n' "$tmp" > "$tmp/scripts/$MOG_POISON" \
            || ! chmod +x "$tmp/scripts/$MOG_POISON"; then
            LAST_TMP="$tmp"; fail "$name (setup: could not plant the MOG_POISON mutant $MOG_POISON)"; return
        fi
    fi

    # MOG_ANCHOR_GIT=1 makes the fixture anchor a git repo whose
    # origin (https://github.com/owner/repo.git, the stub's own nwo) is rewritten
    # by insteadOf to a local bare clone, so the trust gate's anchor-behind
    # ls-remote runs for real and offline. MOG_ANCHOR_BEHIND=1 puts origin one
    # commit ahead of the anchor; MOG_ANCHOR_URL overrides the origin URL.
    if [ "${MOG_ANCHOR_GIT:-0}" = "1" ]; then
        local g="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
        { $g init -q "$tmp" && $g -C "$tmp" add -A && $g -C "$tmp" commit -qm fixture \
            && $g clone -q --bare "$tmp" "$tmp/origin.git" \
            && $g -C "$tmp" config url."$tmp/origin.git".insteadOf "${MOG_ANCHOR_URL:-https://github.com/owner/repo.git}" \
            && $g -C "$tmp" remote add origin "${MOG_ANCHOR_URL:-https://github.com/owner/repo.git}"; } >/dev/null 2>&1 \
            || { LAST_TMP="$tmp"; fail "$name (setup: MOG_ANCHOR_GIT)"; return; }
        if [ "${MOG_ANCHOR_BEHIND:-0}" = "1" ]; then
            { $g -C "$tmp" commit -q --allow-empty -m ahead && $g -C "$tmp" push -q origin HEAD \
                && $g -C "$tmp" reset -q --hard HEAD~1; } >/dev/null 2>&1 \
                || { LAST_TMP="$tmp"; fail "$name (setup: MOG_ANCHOR_BEHIND)"; return; }
            # MOG_ANCHOR_DIVERGED=1 also gives the anchor a commit origin lacks,
            # so it cannot fast-forward to origin.
            if [ "${MOG_ANCHOR_DIVERGED:-0}" = "1" ]; then
                $g -C "$tmp" commit -q --allow-empty -m local >/dev/null 2>&1 \
                    || { LAST_TMP="$tmp"; fail "$name (setup: MOG_ANCHOR_DIVERGED)"; return; }
            fi
        fi
    fi

    # MOG_ANCHOR_SETUP=<function> runs after the anchor repo is built
    # and may add commits / origin refs; it sets MOG_SETUP_SHA, the PR head the
    # stub then certifies as STUB_SHA.
    MOG_SETUP_SHA=""
    if [ -n "${MOG_ANCHOR_SETUP:-}" ]; then
        "$MOG_ANCHOR_SETUP" "$tmp" >/dev/null 2>"$tmp/setup.err" \
            || { LAST_TMP="$tmp"; fail "$name (setup: $MOG_ANCHOR_SETUP: $(head -c 400 "$tmp/setup.err"))"; return; }
    fi

    local err rc
    # The anchor. Defaults to the fixture tree itself (MOG_HIMMEL_REPO
    # unset) — mog_build_fixture already lays out scripts/check-ci.sh,
    # scripts/lib/go-gate.sh and scripts/lib/handover-path.sh at exactly the
    # paths the anchored resolution expects, so every pre-existing case here is
    # unaffected: it is its own anchor, matching the RED-first control (a) —
    # "a worktree whose check-ci.sh is byte-identical to the anchor behaves the
    # same before and after". MOG_HIMMEL_REPO points a case at a DISTINCT tree
    # (proving the anchor decides, not the worktree); MOG_NO_HIMMEL_REPO=1
    # sets it EMPTY and MOG_UNSET_HIMMEL_REPO=1 removes it from the child's
    # environment (env -u) — the two refusal paths of control (b).
    local himmel_repo_dir="${MOG_HIMMEL_REPO:-$tmp}"
    # MOG_ANCHOR_READER=<file|ABSENT> builds a DISTINCT anchor tree whose scripts/lib/pr_remainder.py is that file (or missing),
    # while the worktree keeps its own copy: the anchor's reader must be the one that decides the partial-merge gate.
    if [ -n "${MOG_ANCHOR_READER:-}" ]; then
        himmel_repo_dir="$tmp/anchor"
        mkdir -p "$himmel_repo_dir"
        mog_build_fixture "$himmel_repo_dir"
        if [ "$MOG_ANCHOR_READER" = ABSENT ]; then rm -f "$himmel_repo_dir/scripts/lib/pr_remainder.py"; else cp "$MOG_ANCHOR_READER" "$himmel_repo_dir/scripts/lib/pr_remainder.py"; fi
    fi
    [ "${MOG_NO_HIMMEL_REPO:-0}" = "1" ] && himmel_repo_dir=""
    # cwd matters: the post-merge prune reads `git worktree
    # list` from the checkout the script runs in. Default to the (non-repo)
    # temp dir so the suite is hermetic — it must never see, let alone remove,
    # a worktree of the real himmel checkout. MOG_CWD points a case at its own
    # throwaway fixture repo.
    # The confirmation poll's `sleep 2` never runs for real here —
    # a test that sleeps is a test that can hang.
    # shellcheck disable=SC2086,SC2016 # the unset flag pair splits into two words, or none; the bash -c body expands in the child
    GH_LOG="$ghlog" CLEAR_LOG="$clearlog" MERGE_ON_GREEN_LOG="$audit" JIRA_LOG="$jiralog" PATH="$tmp/bin:${MOG_PATH_BASE:-$PATH}" \
          MERGE_ON_GREEN_SLEEP_CMD=: \
          MERGE_BLOCK_ALERT_DIR="$tmp/alerts" MERGE_BLOCK_ALERT_CMD="$tmp/bin/alert-sender" \
          TELEGRAM_ACCESS_PATH="$tmp/access.json" STUB_ALERT_FAIL="${STUB_ALERT_FAIL:-}" \
          CR_APP="${MOG_CR_APP:-}" TICKET_STATUS_STATE_DIR="${MOG_TS_DIR:-$tmp/ts}" \
          HIMMEL_REPO="$himmel_repo_dir" \
          ${MOG_WRAP-} env ${MOG_UNSET_HIMMEL_REPO:+-u HIMMEL_REPO} ${MOG_SETUP_SHA:+STUB_SHA=$MOG_SETUP_SHA} \
          bash -c 'cd "$1" || exit 1; shift; exec bash "$@"' _ "${MOG_CWD:-$tmp}" \
          "$tmp/scripts/handover/merge-on-green.sh" "$@" >/dev/null 2>"$tmp/err"
    rc=$?
    err=$(cat "$tmp/err" 2>/dev/null)

    # shellcheck disable=SC2034  # LAST_ALERT_LOG is read by the second part's alert rows
    LAST_ALERT_LOG="$tmp/alerts.log"; LAST_GH_LOG="$ghlog"; LAST_AUDIT="$audit"; LAST_CLEAR_LOG="$clearlog"; LAST_ERR="$err"; LAST_JIRA_LOG="$jiralog"; LAST_TMP="$tmp"
    if [ "$rc" -eq "$expected" ]; then
        pass
    else
        fail "$name — expected exit $expected, got $rc (err: ${err:-<none>})"
    fi
}

assert_gh_has() {
    if grep -qF -- "$2" "$LAST_GH_LOG"; then pass; else fail "$1 (gh log lacks '$2')"; fi
}
assert_gh_lacks() {
    if grep -qF -- "$2" "$LAST_GH_LOG"; then fail "$1 (gh log unexpectedly has '$2')"; else pass; fi
}
assert_audit_has() {
    if grep -qF -- "$2" "$LAST_AUDIT" 2>/dev/null; then pass; else fail "$1 (audit log lacks '$2')"; fi
}
assert_audit_lacks() {
    if grep -qF -- "$2" "$LAST_AUDIT" 2>/dev/null; then fail "$1 (audit log unexpectedly has '$2')"; else pass; fi
}
assert_jira_log_has() {
    if grep -qF -- "$2" "$LAST_JIRA_LOG" 2>/dev/null; then pass; else fail "$1 (jira log: $(cat "$LAST_JIRA_LOG" 2>/dev/null))"; fi
}
assert_jira_log_lacks() {
    if grep -qF -- "$2" "$LAST_JIRA_LOG" 2>/dev/null; then fail "$1 (jira log unexpectedly has '$2')"; else pass; fi
}
assert_err_has() {
    if grepq "$LAST_ERR" -F -- "$2"; then pass; else fail "$1 (stderr lacks '$2')"; fi
}
assert_funnel_has() {
    if grep -qF -- "$2" "$LAST_TMP/funnel.log" 2>/dev/null; then pass; else fail "$1 (funnel log: $(cat "$LAST_TMP/funnel.log" 2>/dev/null))"; fi
}
assert_recorder_has() {
    if grep -qF -- "$2" "$LAST_TMP/recorder.log" 2>/dev/null; then pass; else fail "$1 (recorder log: $(cat "$LAST_TMP/recorder.log" 2>/dev/null))"; fi
}
assert_recorder_not_called() {
    if [ -s "$LAST_TMP/recorder.log" ]; then fail "$1 (recorder was called: $(cat "$LAST_TMP/recorder.log"))"; else pass; fi
}
assert_funnel_not_called() {
    if [ -s "$LAST_TMP/funnel.log" ]; then fail "$1 (funnel was called: $(cat "$LAST_TMP/funnel.log"))"; else pass; fi
}
# assert_status_row <name> <jq predicate> — a status-events row of the run matches.
assert_status_row() {
    if jq -e -s "map(select($2)) | length > 0" "${MOG_TS_DIR:-$LAST_TMP/ts}/status-events.jsonl" >/dev/null 2>&1; then pass
    else fail "$1 (status rows: $(cat "${MOG_TS_DIR:-$LAST_TMP/ts}/status-events.jsonl" 2>/dev/null))"; fi
}
assert_err_lacks() {
    if grepq "$LAST_ERR" -F -- "$2"; then fail "$1 (stderr unexpectedly has '$2')"; else pass; fi
}
# Did the run go through the clear-cr-marker chokepoint, and with
# what argv? An EMPTY log is the assertion that it was never invoked.
assert_clear_has() {
    if grep -qF -- "$2" "$LAST_CLEAR_LOG" 2>/dev/null; then pass; else fail "$1 (clear-cr-marker log lacks '$2'; got: $(cat "$LAST_CLEAR_LOG" 2>/dev/null))"; fi
}
assert_clear_not_invoked() {
    if [ -s "$LAST_CLEAR_LOG" ]; then fail "$1 (clear-cr-marker was invoked: $(cat "$LAST_CLEAR_LOG"))"; else pass; fi
}
# Scope merge-flag assertions to the `pr merge` invocation itself.
# Searching the whole GH_LOG would let a flag appearing in ANY other gh call
# satisfy an assertion about how the MERGE was invoked — which is the one thing
# these assertions exist to prove.
merge_line() { grep -E '^pr merge( |$)' "$LAST_GH_LOG" 2>/dev/null; }
assert_merge_has() {
    if merge_line | grep -qF -- "$2"; then pass
    else fail "$1 (pr merge invocation lacks '$2'; got: $(merge_line 2>/dev/null || echo '<no pr merge call>'))"; fi
}
assert_merge_lacks() {
    if merge_line | grep -qF -- "$2"; then fail "$1 (pr merge invocation unexpectedly has '$2'; got: $(merge_line))"
    else pass; fi
}
# Assert a post-merge state RE-QUERY happened. A literal
# "pr view --json state" would also match the initial metadata query
# (`--json state,url,number,headRefOid`) as a substring, so the assertion would
# pass even with post-merge confirmation removed entirely — vacuously guarding
# the one behavior it exists to prove. Anchor on a word boundary after `state`
# so only the state-ONLY or state+headRefOid re-queries match — never the
# initial metadata query (which lists FOUR more fields after `state,`).
# `state,headRefOid,baseRefName` is the failure-recovery re-query;
# `state` alone is the success-path confirmation poll — both are
# legitimate post-merge re-queries this assertion accepts.
# The re-query must be PINNED to the resolved PR number + repo:
# a selector-less `pr view` resolves from the current branch, which is wrong
# after a post-merge checkout switch or from a cwd that is not the PR's tree.
# Defined ONCE here so RC-3's own setup
# guard and paired positive below call the SAME matcher instead of hand-copying
# the pattern — if the anchor is ever tightened, all three sites move together
# instead of RC-3 staying green against a stale copy that no longer reflects
# what this assertion actually runs.
STATE_REQUERY_REGEX='^pr view [0-9]+ --repo [^ ]+ --json state(,headRefOid,baseRefName)?( |$)'
state_requery_matches() { grep -Eq "$STATE_REQUERY_REGEX" "$1"; }
assert_state_requery() {
    if state_requery_matches "$LAST_GH_LOG"; then pass
    else fail "$1 (no PINNED post-merge 'pr view <num> --repo <nwo> --json state[,headRefOid,baseRefName]' re-query found)"; fi
}
# Exact resolved identity: the pin must name THIS PR's
# number and THIS PR's repo, for the pre-merge baseRefName re-query as well as
# the post-merge state re-query — a regression that targets another PR, or
# drops the pin from one of the two, must fail.
assert_pinned_pr_view() {
    if grep -qF -- "pr view 77 --repo acme/private-repo --json $2" "$LAST_GH_LOG"; then pass
    else fail "$1 (no pinned 'pr view 77 --repo acme/private-repo --json $2' call found)"; fi
}

mk_prune_fixture() {
    # echoes: <repo> <worktree> <branch-tip-sha>
    local root branch="feat/mog-prune" repo wt
    root=$(mktemp -d "${TMPDIR:-/tmp}/mog-prune.XXXXXX") || { echo "FAIL: mk_prune_fixture: mktemp -d produced no run sandbox" >&2; return 1; }
    root=$(cd "$root" && pwd -P) || return 1
    repo="$root/repo"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m base
    git -C "$repo" branch -m main 2>/dev/null || true
    wt="$root/wt"
    git -C "$repo" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/work.txt"
    git -C "$wt" add work.txt
    git -C "$wt" commit -q -m work
    printf '%s %s %s\n' "$repo" "$wt" "$(git -C "$repo" rev-parse "$branch")"
}
mk_marker() {
    mkdir -p "$1/.git/cr-pending/$(dirname "$2")"
    printf '2026-08-20T00:00:00Z | deadbeef | full | origin | refs/heads/%s | https://example.invalid/r.git | cafebabe\n' \
        "$2" > "$1/.git/cr-pending/$2"
}
# shellcheck disable=SC2317,SC2329  # _as_claude is invoked indirectly, through MOG_WRAP
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }
go_write() {
    local root="$1" head
    shift
    for head in "$@"; do :; done
    (cd "$GO_READY_REPO" && HIMMEL_REPO="$GO_READY_REPO" READY_STUB_HEAD="$head" READY_STUB_NWO=owner/repo HANDOVER_DIR="$root" \
        PATH="$GO_READY_REPO/.bin:$GO_WRITER_BIN:$PATH" bash "$GO_WRITER" "$@" >/dev/null 2>&1)
}
no_merge_call() {
    if [ "$(grep -c '^pr merge ' "$LAST_GH_LOG")" -eq 0 ]; then pass; else fail "$1 (expected zero merge calls)"; fi
}
mog_go_fixture() {
    GO_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mog-go.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
    GO_ROOT=$(cd "$GO_ROOT" && pwd)
    GO_WRITER="$SCRIPT_DIR/chief-kit/go.sh"
    # go.sh now resolves this repo's nwo via `gh repo view` to bind
    # the GO mac. The direct $GO_WRITER invocations below run outside run_mog's
    # own per-call fixture (which stubs gh only for merge-on-green.sh itself), so
    # without this they would hit the real ambient gh CLI. This stub always
    # answers "owner/repo" — the same default merge-on-green.sh's own gh stub
    # resolves to (STUB_CWD_NWO unset in every case below), so the GO the writer
    # signs and the mac the gate verifies agree.
    GO_WRITER_BIN=$(mktemp -d "${TMPDIR:-/tmp}/mog-go-bin.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
    cat > "$GO_WRITER_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") printf 'owner/repo' ;;
    *) exit 91 ;;
esac
STUB
    chmod +x "$GO_WRITER_BIN/gh"
    # go.sh runs ready-check.sh and refuses unless it passes, so the
    # writer runs from a repo whose CR ledger holds an ok row for each head, under a
    # gh that answers ready-check green (anything else falls through to the stub
    # above). go_write <root> <go.sh args...> - the head is the last argument.
    # shellcheck source=chief-kit/testlib-ready-pass.sh
    . "$SCRIPT_DIR/chief-kit/testlib-ready-pass.sh"
    GO_READY_REPO=$(mktemp -d "${TMPDIR:-/tmp}/mog-go-repo.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
    git -C "$GO_READY_REPO" init -q
    # check 19 fetches origin/main and reads origin/main..<head>: real heads
    GO_SHA=$(ready_pass_repo "$GO_READY_REPO") || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
    GO_OLD=$(ready_pass_repo "$GO_READY_REPO" old) || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
    ready_pass_bin "$GO_READY_REPO/.bin"
    ready_pass_ledger "$GO_READY_REPO" "$GO_SHA" "$GO_OLD"
}

# Sourced with MOG_LIB_ONLY=1, this file stops here: the helpers above (run_mog,
# the assert_* family, the PASS/FAIL tally) are all a sibling suite needs.
[ -z "${MOG_LIB_ONLY:-}" ] || return 0

echo "== merge-on-green.sh tests =="

# Hermeticity probe — when this suite re-execs itself under the
# armed bypass env (see the guard at the end), short-circuit here. The startup
# unset above must have already scrubbed the parent's exported ARMAUTOMERGE=1,
# so the no-opt-in refusal STILL fires (exit 10). Exit 0 = scrub held; exit 1 =
# ARMAUTOMERGE leaked and the wrapper read as opted-in (not exit 10). Relies on
# the startup scrub (does NOT re-unset), so it guards THAT line. One run_mog.
if [ "${HIMMEL_1495_SELF:-0}" = "1" ]; then
    _probe_fail_before=$FAIL
    STUB_NO_PR=1 run_mog 10 "armed-env scrubbed: no-opt-in still refuses"
    [ "$FAIL" = "$_probe_fail_before" ] && exit 0 || exit 1
fi

# Chief-doc probe — the reinvoked copy (see the guard at the end) has the
# caller's HIMMEL_CONSOLE_DOC exported; the startup unset must have scrubbed it, so
# one bare merge leaves no PARTIAL bullet anywhere. Prints what it saw for the guard.
if [ "${HIMMEL_6079_SELF:-0}" = "1" ]; then
    export ARMAUTOMERGE=1
    _probe_fail_before=$FAIL
    STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        run_mog 0 "chief-doc probe: bare merge"
    if [ -n "${HIMMEL_CONSOLE_DOC:-}" ]; then
        echo "chief-doc-partial=$(grep -c "PARTIAL $KP-374" "$HIMMEL_CONSOLE_DOC")"
    else
        echo "chief-doc-partial=unset"
    fi
    [ "$FAIL" = "$_probe_fail_before" ] && exit 0 || exit 1
fi

# 1. No opt-in → refuse (exit 10). Unset in the PARENT shell (no subshell) so
# pass()/fail() land in the top-level tally.
unset ARMAUTOMERGE
run_mog 10 "no ARMAUTOMERGE → exit 10"
export ARMAUTOMERGE=1

# 2. Opted in, no PR (empty state) → clean no-op (exit 0).
STUB_STATE="" run_mog 0 "empty PR state → exit 0 nothing-to-merge"

# 3. PR query fails (auth/network) → refuse (exit 13), NOT a silent no-op.
STUB_STATE_FAIL=1 run_mog 13 "gh pr view auth/network failure → exit 13 (not no-op)"

# 3b. gh 'no pull requests found' → clean no-op (exit 0), NOT a refusal.
STUB_NO_PR=1 run_mog 0 "gh 'no pull requests found' → exit 0 nothing-to-merge"
assert_gh_lacks "no-PR: no merge attempted" "pr merge"

# 8918 exit 27: a --go run that resolves no OPEN PR merged nothing and says so.
# a: --go with no PR number on a branch with no PR
STUB_NO_PR=1 run_mog 27 "8918-a: --go and no PR resolved → exit 27" -- --go /nonexistent/go/77.abc123def456
assert_err_has "8918-a: stderr says nothing merged" "nothing merged"
assert_gh_lacks "8918-a: no merge attempted" "pr merge"
# a2: no --go keeps the clean no-op
STUB_NO_PR=1 run_mog 0 "8918-a2: no --go and no PR resolved → exit 0"
# a3: --go plus a selector naming a closed PR
STUB_STATE=CLOSED run_mog 27 "8918-a3: --go and a closed PR → exit 27" -- 77 --go /nonexistent/go/77.abc123def456
assert_err_has "8918-a3: stderr says nothing merged" "nothing merged"
# a3b: an empty or unknown state is refused too
STUB_STATE="" run_mog 27 "8918-a3b: --go and an empty PR state → exit 27" -- --go /nonexistent/go/77.abc123def456
# a5: --dry-run is exempt
STUB_NO_PR=1 run_mog 0 "8918-a5: --go --dry-run and no PR resolved → exit 0" -- --go /nonexistent/go/77.abc123def456 --dry-run
# a6: the PR already MERGED at the GO file's head is not a failure
STUB_STATE=MERGED run_mog 0 "8918-a6: --go and the PR already MERGED at the GO head → exit 0" -- --go /nonexistent/go/77.abc123def456
assert_err_has "8918-a6: stderr says already merged" "already merged"
# a6b: MERGED at another head is not the GO's merge
STUB_STATE=MERGED run_mog 27 "8918-a6b: --go and the PR MERGED at another head → exit 27" -- --go /nonexistent/go/77.deadbeef

# 4. PR OPEN but repo is public → fail-closed refuse (exit 12), no merge.
STUB_PRIVATE=false run_mog 12 "public repo → exit 12"
assert_gh_lacks "public repo: no merge attempted" "pr merge"
# the refusal names the chief's adapter merge path.
assert_err_has "adapter hint: not-private refusal says stop at READY, chief merges with merge-fork-pr.sh" "a worker stops at READY and the chief merges with merge-fork-pr.sh."

# --fixture-cleanup-only: test-fixture-trap-clean.sh needs the EXIT trap to
# remove every mog-* fixture, which the first cases above already create (the
# suite dir, the scratch HOME and a mog-run.* sandbox per run_mog). It stops
# here instead of running the other ~1,000 assertions under a 300 s timeout.
if [ "${1:-}" = "--fixture-cleanup-only" ]; then
    echo "merge-on-green (fixture-cleanup-only): $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
fi

# RC-3 — the comment on assert_state_requery above claims a
# LITERAL (unanchored) 'pr view .*--json state' matcher would ALSO match the
# initial metadata query as a substring. Placed right here, immediately after
# case 4: that case refuses at the privacy guard BEFORE any post-merge
# re-query ever fires, so ITS OWN $LAST_GH_LOG carries exactly the initial
# metadata query and nothing else — a fixture DERIVED from a real run just
# made, not transcribed by hand into a heredoc (an earlier
# version of this case hand-typed the gh-log line and claimed it was
# "verified empirically", which was actually derivation from reading
# merge-on-green.sh's source — the same prose-only-evidence class this PR
# exists to fix). Sitting here also keeps this case below the
# HIMMEL_1495_SELF short-circuit further down, so RC-2's self-reinvoked
# mutant no longer re-runs it on every invocation.
rc3_ghlog="$LAST_GH_LOG"
# Guard the derived fixture before trusting it: it must actually contain a
# 'pr view' call (case 4 really queried gh), and it must NOT already match
# the shipped anchored regex — a fixture that failed the anchored regex for
# the wrong reason (e.g. an empty log) would make the paired positive below
# vacuous.
if ! grep -q '^pr view' "$rc3_ghlog"; then
    fail "RC-3 setup: case 4's gh log has no 'pr view' line at all — cannot derive the fixture from it"
elif state_requery_matches "$rc3_ghlog"; then
    fail "RC-3 setup: case 4's gh log already matches the shipped anchored regex — it is not the initial-metadata-only fixture this case needs"
else
    # The mutant: the pre-anchor matcher this case exists to disprove. A
    # one-line scratch script, not a mutation of an existing file — there is
    # no prior source to diff against, so the pre/post/diff-count proof the
    # awk-mutant cases elsewhere in this file use does not apply here; the
    # "mutation" IS the whole file. Be honest about what that costs: this
    # `grep && echo || echo` shape always exits 0 no matter what it's given,
    # so contract point (a) — "the mutant RAN" — is satisfied trivially here
    # in a way it is not for RC-1/RC-2. That is inherent to a matcher-shaped
    # mutant; the real discriminating evidence is the SPECIFIC observed value
    # (point c) plus the paired positive assertion below, not point (a).
    #
    # Templated + guarded like SUITE_HOLDER_DIR above: a bare,
    # unchecked `mktemp` feeding a later `rm -f` is the same shape
    # a prior fix closed elsewhere, even though the blast radius here is smaller
    # (`rm -f ""` errors rather than deleting anything) — pin the SHAPE before
    # arming the cleanup, not just the exit status.
    rc3_mutant=$(mktemp "${TMPDIR:-/tmp}/mog-2544-rc3-mutant.XXXXXX")
    if [ -z "$rc3_mutant" ] || [ ! -f "$rc3_mutant" ]; then
        fail "RC-3 setup: mktemp produced no mutant-script file — refusing to build the fixture on an empty root"
    else
        cat > "$rc3_mutant" <<'EOF'
#!/usr/bin/env bash
grep -q -- 'pr view .*--json state' "$1" && echo 'requery=matched' || echo 'requery=no-match'
EOF
        red_control_run -- bash "$rc3_mutant" "$rc3_ghlog"
        if red_control_assert --label "RC-3" --expect-rc 0 \
            --observed     "$RED_CONTROL_OUT" \
            --expect-wrong "requery=matched" \
            --correct      "requery=no-match" \
            --note "the unanchored 'pr view --json state' substring matches the INITIAL six-field metadata query, so assert_state_requery would pass with the post-merge confirmation removed entirely; the word-boundary anchor is what makes it load-bearing"
        then
            pass
        else
            fail "RC-3 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
        # Paired POSITIVE: the SHIPPED (anchored) assert_state_requery regex
        # must NOT match this same fixture — proving both halves in one case:
        # the naive matcher is fooled, the real one is not. Calls
        # state_requery_matches(), the SAME predicate assert_state_requery
        # itself runs (not a duplicated hand-copy of the pattern), so this
        # control drifts WITH the shipped assertion rather than silently
        # diverging into a stale copy if the anchor is ever tightened further
        # — a regression there would then leave this control green while no
        # longer testing what actually ships. (The setup guard above already
        # proved this once to protect ITSELF from a vacuous fixture; this is
        # the case's own pass/fail record of the same fact, not a silent
        # reuse of the setup check's tally.)
        if state_requery_matches "$rc3_ghlog"; then
            fail "RC-3 positive: the shipped anchored regex unexpectedly matched the initial-metadata-only fixture — the anchor is not doing its job"
        else
            pass
        fi
        rm -f "$rc3_mutant"
    fi
fi

# 5. isPrivate undeterminable (empty) → fail closed (exit 12).
STUB_PRIVATE="" run_mog 12 "undeterminable privacy → exit 12 fail-closed"

# 5b. Cross-repo selector: PR repo != current checkout → refuse (exit 12),
# no merge (standing auth must not reach other private repos).
STUB_NWO="acme/other-private" STUB_CWD_NWO="acme/this-repo" run_mog 12 "cross-repo PR → exit 12"
assert_gh_lacks "cross-repo: no merge attempted" "pr merge"

# 5c. Cannot resolve cwd repo → fail closed (exit 12).
STUB_CWD_FAIL=1 run_mog 12 "unresolvable cwd repo → exit 12 fail-closed"

# ── public-origin merge relaxation ──────────────────────────────
# Guard 2b's private-only boundary widens to admit ONE named public repo (the
# configured public origin, `public_origin_merge_allowed`'s
# HIMMEL_PUBLIC_ORIGIN_NWO) while GitHub itself is enforcing required status
# checks on the branch being merged into. These cases exercise the widened
# path and every fail-closed edge: unreadable protection, no required checks,
# enforce_admins off, the `checks` list shape, a DIFFERENT public repo, the
# non-seam of the constant, the private-repo regression anchor, and the
# pre-merge re-read catching protection weakened during the CI wait.
#
# jq availability is checked ONCE here, locally to this block (the file's
# shared `have_jq` guard is computed further down, after this block, and this
# block needs it before that point) — hoisted here rather than probed
# separately in each of 2869-1b and 2869-7 below, which both need it.
have_jq_2869=0; command -v jq >/dev/null 2>&1 && have_jq_2869=1

# 2869-1. The configured public origin, under branch protection with required
# status checks → proceeds to the merge exactly like a private repo would.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="pubok01" \
    run_mog 0 "configured public origin under branch protection → merged"
assert_merge_has "2869-1: merge pins the certified sha" "--match-head-commit pubok01"
assert_merge_has "2869-1: merge uses --squash" "--squash"
assert_gh_has "2869-1: reads branch protection on the configured origin" "api repos/yotamleo-org/Himmel/branches/main/protection"
assert_audit_has "2869-1: audit records the merge" "MERGED"

# 2869-1b. Every other allow-path case above (2869-1,
# 2869-3c) feeds the stub its PRE-JOINED "enforce_admins|contexts|checks"
# string, so the script's own `--jq` filter never runs on the MERGE direction
# at all — 2869-7 below is the only case that runs real JSON through the
# real filter, and it is itself a refusal (null required_status_checks). A
# filter mutated to reject every real response (e.g. contexts/checks length
# forced to 0) would therefore leave the WHOLE suite green: it still refuses
# 2869-7 "correctly" and never touches the pre-joined-string cases at all.
# This case is the allow-direction twin of 2869-7: realistic GitHub-shaped
# protection JSON (the actual `repos/.../branches/main/protection` response
# shape, `strict` + a `contexts` array of real-looking check names) through
# the script's OWN filter, asserting the result is one the gate ACCEPTS.
if [ "$have_jq_2869" = "1" ]; then
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="jqok01" \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["lint","shell-unit (ubuntu-latest)","shellcheck"]}}' \
        run_mog 0 "realistic protected-branch JSON through the real filter → merged"
    assert_merge_has "2869-1b: merge pins the certified sha" "--match-head-commit jqok01"
    assert_gh_has "2869-1b: reads branch protection on the configured origin" "api repos/yotamleo-org/Himmel/branches/main/protection"
else
    echo "  SKIP: jq not installed — realistic protected-branch-JSON allow case ([codex-1])"
fi

# 2869-2. Protection unreadable (404 / API failure) → refuse, no merge.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 \
    run_mog 12 "public origin, protection unreadable → exit 12"
assert_gh_lacks "2869-2: no merge attempted" "pr merge"
assert_audit_has "2869-2: audits not-protected" "reason=not-protected"

# 2869-2b. The empty-body twin of 2869-2's 404: a protection endpoint that
# answers with NOTHING (rather than a non-zero gh exit) must refuse exactly
# like one that errors, never be read as "protected". The stub preserves an
# explicitly-empty STUB_PROTECTION (`-`, not `:-`) so this path is reachable.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION="" \
    run_mog 12 "public origin, empty protection body → exit 12"
assert_gh_lacks "2869-2b: no merge attempted" "pr merge"
assert_audit_has "2869-2b: audits not-protected" "reason=not-protected"

# 2869-3. Protection present but NO required status checks → refuse. This is
# the gate the whole relaxation leans on.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION="true|0|0" \
    run_mog 12 "public origin, no required checks → exit 12"
assert_gh_lacks "2869-3: no merge attempted" "pr merge"
assert_audit_has "2869-3: audits not-protected" "reason=not-protected"

# 2869-3b. enforce_admins off → refuse, even with required checks present.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION="false|10|0" \
    run_mog 12 "public origin, enforce_admins off → exit 12"
assert_gh_lacks "2869-3b: no merge attempted" "pr merge"
assert_audit_has "2869-3b: audits not-protected" "reason=not-protected"

# 2869-3c. GitHub's newer `checks` list (instead of `contexts`) also satisfies
# the gate — both required-status-check shapes count.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION="true|0|10" STUB_SHA="checksok01" \
    run_mog 0 "public origin, protection via 'checks' list → merged"
assert_merge_has "2869-3c: merge pins the certified sha" "--match-head-commit checksok01"

# 2869-4. Some OTHER public repo — not the configured origin — refuses on
# identity alone, before spending an API read on protection.
STUB_NWO="someone/Himmel" STUB_CWD_NWO="someone/Himmel" STUB_PRIVATE=false \
    run_mog 12 "other public repo → exit 12"
assert_gh_lacks "2869-4: no merge attempted" "pr merge"
assert_audit_has "2869-4: audits not-private" "reason=not-private"
assert_gh_lacks "2869-4: refuses on identity before reading protection" "/protection"

# 2869-4b. The constant is deliberately NOT env-overridable: a stray
# HIMMEL_PUBLIC_ORIGIN_NWO in the ambient environment must not widen the gate.
STUB_NWO="someone/Himmel" STUB_CWD_NWO="someone/Himmel" STUB_PRIVATE=false HIMMEL_PUBLIC_ORIGIN_NWO="someone/Himmel" \
    run_mog 12 "ambient HIMMEL_PUBLIC_ORIGIN_NWO does not widen the gate → exit 12"
assert_gh_lacks "2869-4b: no merge attempted" "pr merge"
assert_audit_has "2869-4b: audits not-private" "reason=not-private"

# 6502. The pre-org-move slug is no longer the configured origin, even under
# protection with required checks.
STUB_NWO="yotamleo/Himmel" STUB_CWD_NWO="yotamleo/Himmel" STUB_PRIVATE=false \
    run_mog 12 "old public origin slug → exit 12"
assert_gh_lacks "6502: no merge attempted" "pr merge"
assert_audit_has "6502: audits not-private" "reason=not-private"

# 2869-5. Regression anchor: a private repo is unaffected, and does not pay
# the protection round-trip at all.
STUB_PRIVATE=true STUB_NWO="acme/private-repo" STUB_CWD_NWO="acme/private-repo" STUB_SHA="privok01" \
    run_mog 0 "private repo unaffected → merged"
assert_gh_lacks "2869-5: private repo never reads protection" "/protection"

# 2869-6. Pre-merge re-read: guard 2b passes, but protection is GONE by the
# pre-merge re-check (the CI wait window) → refuse.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="protrace01" \
    STUB_PROTECTION="true|10|0" STUB_PROTECTION_PREMERGE_FAIL=1 \
    run_mog 12 "protection removed during the CI wait → exit 12"
assert_gh_lacks "2869-6: no merge attempted" "pr merge"
assert_audit_has "2869-6: audits not-protected-premerge" "reason=not-protected-premerge"

# 2869-6a. Same window, but protection stays readable and merely loses its
# required checks rather than the endpoint disappearing.
STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="protrace02" \
    STUB_PROTECTION="true|10|0" STUB_PROTECTION_PREMERGE="true|0|0" \
    run_mog 12 "required checks removed during the CI wait → exit 12"
assert_gh_lacks "2869-6a: no merge attempted" "pr merge"
assert_audit_has "2869-6a: audits not-protected-premerge" "reason=not-protected-premerge"

# 2869-6b. Existing case 9e2 below ("repo made PUBLIC during the CI wait") uses
# the default STUB_NWO=owner/repo — not the configured origin — so it must
# still refuse for not-private-premerge; verified there, nothing to add here.

# 2869-7. `required_status_checks: null` (the field absent from the API
# response) must coalesce through the script's own `// []` filter to an empty
# list, not slip past as "protected" — proven via REAL jq against synthetic
# JSON, same technique as the STUB_DEFAULT_BRANCH_NULL cases further below.
# The allow-direction twin of this refusal is 2869-1b above; both share the
# ONE have_jq_2869 probe computed at the top of this block rather
# than each probing separately (the file's own shared `have_jq` guard is
# computed further down, after this block, so it isn't reused here either).
if [ "$have_jq_2869" = "1" ]; then
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":null}' \
        run_mog 12 "null required_status_checks → exit 12 not-protected"
    assert_gh_lacks "2869-7: no merge attempted" "pr merge"
    assert_audit_has "2869-7: audits not-protected" "reason=not-protected"
else
    echo "  SKIP: jq not installed — null required_status_checks case"
fi

# jq length accepts strings and objects too. Removing either
# array type-check must make these real-JSON refusal cases fail.
if [ "$have_jq_2869" = "1" ]; then
    STUB_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":"lint"}}' \
        run_mog 12 "string contexts must not count as required checks"
    assert_audit_has "2876 contexts: not protected" "reason=not-protected"
    assert_gh_lacks "2876 contexts: no merge attempted" "pr merge"

    STUB_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":{"checks":{"context":"lint"}}}' \
        run_mog 12 "object checks must not count as required checks"
    assert_audit_has "2876 checks: not protected" "reason=not-protected"
    assert_gh_lacks "2876 checks: no merge attempted" "pr merge"

    STUB_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":{"checks":[{"context":"lint","app_id":123}]}}' \
        run_mog 0 "real checks array still permits protected-origin merge"
    assert_merge_has "2876 checks array: merge attempted" "pr merge 77 --repo yotamleo-org/Himmel"

    STUB_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        STUB_PROTECTION_JSON='{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":["lint"]}}' \
        STUB_PROTECTION_JSON_PREMERGE='{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":"lint"}}' \
        run_mog 12 "pre-merge protection re-read also rejects string contexts"
    assert_audit_has "2876 premerge: not protected" "reason=not-protected-premerge"
    assert_gh_lacks "2876 premerge: no merge attempted" "pr merge"
else
    echo "  SKIP: jq not installed — protection array type-check cases"
fi

# ── ruleset-based protection alongside classic ─────────────────
# The gate accepts the base branch's protection from the classic endpoint OR an
# effective ruleset (rules/branches/<b> + each contributing rulesets/<id>),
# per HIMMEL_PROTECTION_SOURCE (a fixed literal, like HIMMEL_PUBLIC_ORIGIN_NWO:
# classic | ruleset | either (default) | both). A ruleset satisfies only when
# every contributing ruleset is `active`, requires >=1 status check, and lists
# NO bypass actor. Cases below need real jq (the stub runs the script's own
# --jq), and set STUB_PROTECTION_FAIL=1 to make classic unreadable so the
# ruleset path alone decides.
if [ "$have_jq_2869" = "1" ]; then
    R_RULES='[{"type":"pull_request","ruleset_id":17745842},{"type":"required_status_checks","ruleset_id":17745842,"parameters":{"required_status_checks":[{"context":"lint"},{"context":"shellcheck"}]}}]'
    R_SET='{"id":17745842,"enforcement":"active","bypass_actors":[]}'

    # 3808-1. Ruleset-only, strong → accept; the audit names the source.
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="rs01" \
        STUB_PROTECTION_FAIL=1 STUB_PROTECTION_PREMERGE_FAIL=1 \
        STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET" \
        run_mog 0 "3808-1: strong ruleset alone (classic 404) → merged"
    assert_merge_has "3808-1: merge pins the certified sha" "--match-head-commit rs01"
    assert_gh_has "3808-1: reads the effective rules" "api repos/yotamleo-org/Himmel/rules/branches/main"
    assert_gh_has "3808-1: reads the contributing ruleset" "api repos/yotamleo-org/Himmel/rulesets/17745842"
    assert_audit_has "3808-1: audit names the ruleset source" "source=ruleset"

    # 3808-2. Classic-only → accept exactly as before; ruleset never read.
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="cl01" \
        run_mog 0 "3808-2: classic alone → merged (no regression)"
    assert_audit_has "3808-2: audit names the classic source" "source=classic"
    assert_gh_lacks "3808-2: classic satisfied, ruleset never read" "/rules/branches/"

    # 3808-3. Every weakness of the ruleset path refuses (classic 404).
    r3() { # <label> <rules> <ruleset> [extra VAR=val…]
        local label="$1" rules="$2" set="$3"; shift 3
        STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
            STUB_PROTECTION_FAIL=1 STUB_RULES_JSON="$rules" STUB_RULESET_JSON="$set" \
            run_mog 12 "3808-3: $label → exit 12"
        assert_gh_lacks "3808-3 ($label): no merge attempted" "pr merge"
        assert_audit_has "3808-3 ($label): audits not-protected" "reason=not-protected"
    }
    r3 "ruleset in evaluate mode" "$R_RULES" '{"id":17745842,"enforcement":"evaluate","bypass_actors":[]}'
    r3 "ruleset disabled" "$R_RULES" '{"id":17745842,"enforcement":"disabled","bypass_actors":[]}'
    r3 "admin bypass actor (pull_request mode)" "$R_RULES" \
        '{"id":17745842,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]}'
    r3 "admin bypass actor (always mode)" "$R_RULES" \
        '{"id":17745842,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}'
    r3 "null bypass_actors is unreadable" "$R_RULES" '{"id":17745842,"enforcement":"active"}'
    r3 "no required_status_checks rule" '[{"type":"pull_request","ruleset_id":17745842}]' "$R_SET"
    r3 "empty required_status_checks list" \
        '[{"type":"required_status_checks","ruleset_id":17745842,"parameters":{"required_status_checks":[]}}]' "$R_SET"
    r3 "string required_status_checks" \
        '[{"type":"required_status_checks","ruleset_id":17745842,"parameters":{"required_status_checks":"lint"}}]' "$R_SET"
    r3 "no rules at all" '[]' "$R_SET"

    # 3808-3b. One contributing ruleset strong, a SECOND (with checks) has a bypass
    # actor: every contributing ruleset must be clean. Per-id bodies
    # so ONLY ruleset 2 carries the bypass — ruleset 1 is read clean first.
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 \
        STUB_RULES_JSON='[{"type":"required_status_checks","ruleset_id":1,"parameters":{"required_status_checks":[{"context":"a"}]}},{"type":"required_status_checks","ruleset_id":2,"parameters":{"required_status_checks":[{"context":"b"}]}}]' \
        STUB_RULESET_JSON_1='{"id":1,"enforcement":"active","bypass_actors":[]}' \
        STUB_RULESET_JSON_2='{"id":2,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' \
        run_mog 12 "3808-3b: a bypass actor on the second contributing ruleset only → exit 12"
    assert_gh_lacks "3808-3b: no merge attempted" "pr merge"
    assert_audit_has "3808-3b: ruleset 1 read clean" "ruleset=1:enforcement=active,bypass_actors=0"
    assert_audit_has "3808-3b: ruleset 2 refused on its bypass actor" "ruleset=2:enforcement=active,bypass_actors=1"

    # 3808-3c. A bypass actor on a ruleset with NO required_status_checks rule
    # cannot skip a required check: ruleset 1 strong, ruleset 2 bypassable but
    # contributing only a pull_request rule → accept.
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_SHA="rs3c" \
        STUB_PROTECTION_FAIL=1 STUB_PROTECTION_PREMERGE_FAIL=1 \
        STUB_RULES_JSON='[{"type":"required_status_checks","ruleset_id":1,"parameters":{"required_status_checks":[{"context":"a"}]}},{"type":"pull_request","ruleset_id":2}]' \
        STUB_RULESET_JSON_1='{"id":1,"enforcement":"active","bypass_actors":[]}' \
        STUB_RULESET_JSON_2='{"id":2,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' \
        run_mog 0 "3808-3c: bypass actor on a ruleset without required checks → merged"
    assert_merge_has "3808-3c: merge pins the certified sha" "--match-head-commit rs3c"
    assert_gh_has "3808-3c: reads the strong ruleset" "api repos/yotamleo-org/Himmel/rulesets/1"
    assert_gh_lacks "3808-3c: never reads the non-contributing ruleset" "api repos/yotamleo-org/Himmel/rulesets/2"
    assert_audit_has "3808-3c: audit names the ruleset source" "source=ruleset"

    # 3808-4. API errors fail closed.
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 \
        STUB_RULES_FAIL=1 STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET" \
        run_mog 12 "3808-4: rules endpoint error → exit 12"
    assert_gh_lacks "3808-4: no merge attempted" "pr merge"
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 \
        STUB_RULESET_FAIL=1 STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET" \
        run_mog 12 "3808-4: ruleset endpoint error → exit 12"
    assert_gh_lacks "3808-4b: no merge attempted" "pr merge"

    # 3808-5. Weakened between the watch and the merge → the FRESH pre-merge
    # re-read refuses (same staleness class as 2869-6).
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 STUB_PROTECTION_PREMERGE_FAIL=1 \
        STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET" \
        STUB_RULESET_JSON_PREMERGE='{"id":17745842,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]}' \
        run_mog 12 "3808-5: bypass actor added during the CI wait → exit 12"
    assert_gh_lacks "3808-5: no merge attempted" "pr merge"
    assert_audit_has "3808-5: audits not-protected-premerge" "reason=not-protected-premerge"
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 STUB_PROTECTION_PREMERGE_FAIL=1 \
        STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET" STUB_RULES_JSON_PREMERGE='[]' \
        run_mog 12 "3808-5b: required checks dropped during the CI wait → exit 12"
    assert_audit_has "3808-5b: audits not-protected-premerge" "reason=not-protected-premerge"

    # 3808-5c. A rules response whose root is an object (not an array) is
    # malformed: a required_status_checks rule nested inside it must NOT satisfy
    # the gate (fail closed).
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false STUB_PROTECTION_FAIL=1 \
        STUB_RULES_JSON='{"x":{"type":"required_status_checks","ruleset_id":17745842,"parameters":{"required_status_checks":[{"context":"a"}]}}}' \
        STUB_RULESET_JSON='{"id":17745842,"enforcement":"active","bypass_actors":[]}' \
        run_mog 12 "3808-5c: object-rooted rules response → exit 12"
    assert_gh_lacks "3808-5c: no merge attempted" "pr merge"

    # 3808-6. HIMMEL_PROTECTION_SOURCE modes, via a sed'd copy of the script (the
    # literal is not env-overridable, exactly like HIMMEL_PUBLIC_ORIGIN_NWO).
    # Each copy is checked to carry the literal, so a sed that matched nothing
    # cannot leave the whole matrix silently testing the default.
    mode_dir=$(mktemp -d "${TMPDIR:-/tmp}/mog-mode.XXXXXX")
    mode_src() { # <mode> → path of a copy carrying that literal
        local out="$mode_dir/mog-$1.sh"
        sed "s/^HIMMEL_PROTECTION_SOURCE=.*/HIMMEL_PROTECTION_SOURCE=\"$1\"/" "$MOG" > "$out"
        if ! grep -Fxq "HIMMEL_PROTECTION_SOURCE=\"$1\"" "$out"; then
            echo "  NOTE: mode copy '$1' did not take the literal" >&2
        fi
        printf '%s' "$out"
    }
    mode_case() { # <mode> <classic:ok|bad> <ruleset:ok|bad> <expect rc> <label>
        local mode="$1" c="$2" r="$3" want="$4" label="$5" src
        src=$(mode_src "$mode")
        local -a v=(STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false)
        [ "$c" = "bad" ] && v+=(STUB_PROTECTION_FAIL=1 STUB_PROTECTION_PREMERGE_FAIL=1)
        [ "$r" = "ok" ] && v+=(STUB_RULES_JSON="$R_RULES" STUB_RULESET_JSON="$R_SET")
        # shellcheck disable=SC2163
        for kv in "${v[@]}"; do export "$kv"; done
        MOG_SRC="$src" run_mog "$want" "3808-6: mode=$mode classic=$c ruleset=$r → $want ($label)"
        for kv in "${v[@]}"; do unset "${kv%%=*}"; done
    }
    mode_case classic ok bad 0  "classic mode accepts classic"
    mode_case classic bad ok 12 "classic mode ignores a strong ruleset"
    assert_gh_lacks "3808-6: classic mode never reads rulesets" "/rules/branches/"
    mode_case ruleset bad ok 0  "ruleset mode accepts a strong ruleset"
    mode_case ruleset ok bad 12 "ruleset mode ignores strong classic"
    assert_gh_lacks "3808-6: ruleset mode never reads classic" "/protection"
    mode_case either ok bad 0   "either: classic"
    mode_case either bad ok 0   "either: ruleset"
    mode_case either bad bad 12 "either: neither"
    mode_case both ok ok 0      "both: both pass"
    assert_audit_has "3808-6: both names both sources" "source=classic+ruleset"
    mode_case both ok bad 12    "both: classic only"
    mode_case both bad ok 12    "both: ruleset only"
    mode_case bogus ok ok 12    "unknown mode fails closed even with strong protection"
    assert_gh_lacks "3808-6: unknown mode reads nothing" "/protection"
    assert_audit_has "3808-6: unknown mode is named in the audit" "unknown-protection-source=bogus"

    # 3808-7. The knob is a fixed literal, not an env seam: an ambient
    # HIMMEL_PROTECTION_SOURCE=ruleset must not steer the gate (classic-only
    # protection must still merge under the shipped `either`).
    STUB_NWO="yotamleo-org/Himmel" STUB_CWD_NWO="yotamleo-org/Himmel" STUB_PRIVATE=false \
        HIMMEL_PROTECTION_SOURCE=ruleset STUB_SHA="env01" \
        run_mog 0 "3808-7: ambient HIMMEL_PROTECTION_SOURCE does not steer the gate"
    assert_audit_has "3808-7: still the classic source" "source=classic"

    # 3808-8. Private repo: unaffected, reads neither source.
    STUB_PRIVATE=true STUB_NWO="acme/private-repo" STUB_CWD_NWO="acme/private-repo" STUB_SHA="priv3808" \
        run_mog 0 "3808-8: private repo unaffected"
    assert_gh_lacks "3808-8: private repo reads no rulesets" "/rules/branches/"
    rm -rf "$mode_dir"
else
    echo "  SKIP: jq not installed — ruleset protection cases"
fi

# 6. Cannot read head SHA → refuse (exit 13).
STUB_SHA="" run_mog 13 "empty head SHA → exit 13"

# 7. check-ci not found at the anchor (== the fixture itself, by default) →
# This is now the "no anchor" refusal (exit 19), not the old
# check-ci-gate-not-green path (exit 14) — the missing file is caught before
# check-ci.sh is ever invoked.
NO_CHECK_CI=1 run_mog 19 "missing check-ci at the anchor → exit 19"

# 8. check-ci non-green (exit 3) → refuse (exit 14), no merge.
STUB_CI_RC=3 run_mog 14 "check-ci exit 3 → exit 14"
assert_gh_lacks "non-green: no merge attempted" "pr merge"

# 9. All gates pass → merge (exit 0) with --squash + --match-head-commit <sha>.
STUB_SHA="feedface99" STUB_NWO="acme/private-repo" run_mog 0 "all gates pass → merged"
assert_merge_has "merge uses --squash"              "--squash"
assert_merge_has "merge pins the certified head SHA" "--match-head-commit feedface99"
# No --delete-branch — every branch is worktree-held, so gh's local
# delete failed on every real merge; the repo's deleteBranchOnMerge + /clean own
# cleanup. The merge is pinned to the resolved PR number + repo.
assert_merge_lacks "merge does not ask gh to delete the branch" "--delete-branch"
assert_merge_has "merge pinned to the resolved PR number + repo" "pr merge 77 --repo acme/private-repo"
assert_pinned_pr_view "pre-merge base re-query is pinned to THIS PR's number + repo" "baseRefName"
assert_pinned_pr_view "success-path confirmation poll is pinned to THIS PR's number + repo" "state,headRefOid,baseRefName"
# Regression guard: the privacy check targets the PR's OWN repo, not cwd.
assert_gh_has  "privacy check scoped to the PR repo" "repo view acme/private-repo"
assert_audit_has "audit records MERGING intent"   "MERGING"
assert_audit_has "audit records MERGED + sha"     "MERGED"
assert_audit_has "audit records the certified sha" "sha=feedface99"

# Removing the fresh policy guard would call merge despite an
# outstanding review rule. The call log proves refusal happens BEFORE merge.
STUB_MERGE_STATE=BLOCKED STUB_REVIEW_DECISION=REVIEW_REQUIRED run_mog 18 "green checks but required review → exit 18 pre-merge"
assert_audit_has "pre-merge policy: deterministic refusal" "REFUSED reason=policy-refused phase=premerge"
if [ "$(grep -c '^pr merge ' "$LAST_GH_LOG")" -eq 0 ]; then pass; else fail "pre-merge policy: expected zero merge calls"; fi
assert_audit_lacks "pre-merge policy: no merge intent" "MERGING"
assert_gh_has "pre-merge policy: query pins resolved PR identity" "pr view 77 --repo owner/repo --json mergeStateStatus,reviewDecision"

STUB_MERGE_STATE=BLOCKED STUB_REVIEW_DECISION=REVIEW_REQUIRED run_mog 18 "dry-run reports required review" -- --dry-run
assert_gh_lacks "dry-run policy: no merge attempted" "pr merge"

# Both halves matter: CLEAN with a review requirement, and BLOCKED without
# REVIEW_REQUIRED, still defer the actual merge decision to GitHub.
STUB_MERGE_STATE=CLEAN STUB_REVIEW_DECISION=REVIEW_REQUIRED run_mog 0 "CLEAN policy → merge call"
assert_merge_has "CLEAN policy: merge attempted" "pr merge 77 --repo owner/repo"
STUB_MERGE_STATE=BLOCKED STUB_REVIEW_DECISION=APPROVED run_mog 0 "BLOCKED but approved → merge call"
assert_merge_has "approved policy: merge attempted" "pr merge 77 --repo owner/repo"

STUB_POLICY_FAIL=1 run_mog 13 "unreadable pre-merge policy → exit 13"
assert_gh_lacks "unreadable policy: no merge attempted" "pr merge"
STUB_MERGE_STATE="" run_mog 13 "missing pre-merge state → exit 13"
assert_gh_lacks "missing policy: no merge attempted" "pr merge"
STUB_CI_RC=3 STUB_MERGE_STATE=BLOCKED STUB_REVIEW_DECISION=REVIEW_REQUIRED run_mog 14 "red checks take precedence over policy refusal"
assert_gh_lacks "red checks: policy query not reached" "--json mergeStateStatus,reviewDecision"

# 9b. Base-branch guard: PR based on the repo's default branch
# still reaches the merge — the guard is additive, not a behavior change for
# the (common) approved-target case.
STUB_SHA="basecheck01" STUB_BASE="main" STUB_DEFAULT_BRANCH="main" \
    run_mog 0 "PR on default branch → merged"
assert_merge_has "base-branch-ok merge pins the certified sha" "--match-head-commit basecheck01"

# 9c. Base-branch guard: PR based on any OTHER branch is refused
# (exit 12), no merge — the standing allow-rule only covers PRs against the
# repo's default branch (inject-initiative.sh:236: "squash-merge to PRIVATE
# main").
STUB_BASE="some/other-branch" STUB_DEFAULT_BRANCH="main" \
    run_mog 12 "PR on non-default base branch → exit 12"
assert_gh_lacks "wrong-base: no merge attempted" "pr merge"
assert_audit_has "wrong-base audits the refusal reason" "reason=wrong-base-branch"
assert_audit_has "wrong-base audit records the pr base" "pr_base=some/other-branch"
assert_audit_has "wrong-base audit records the authorized branch" "authorized_branch=main"

# 9d. Base-branch guard fail-closed: an undeterminable repo default branch
# refuses (exit 12) rather than waving the merge through.
STUB_DEFAULT_BRANCH="" run_mog 12 "undeterminable default branch → exit 12 fail-closed"
assert_gh_lacks "undeterminable-default: no merge attempted" "pr merge"
assert_audit_has "undeterminable-default audits the reason" "reason=base-branch-undeterminable"

# 9e. Base-branch retarget race: the
# PR was on the default branch at the gate (guard 2c) but got RETARGETED during
# check-ci.sh's watch window — the head SHA never moved (gh allows editing a
# PR's base without touching its head), so --match-head-commit alone would not
# catch it. The pre-merge re-query (FIX-1) must catch the retarget and refuse
# (exit 12); the merge must never fire.
STUB_SHA="retarget01" STUB_BASE="main" STUB_DEFAULT_BRANCH="main" \
    STUB_BASE_PREMERGE="some/other-branch" \
    run_mog 12 "base retargeted after the gate → exit 12"
assert_gh_lacks "retargeted-base: no merge attempted" "pr merge"
assert_audit_has "retargeted-base audits the reason" "reason=base-branch-changed"
assert_audit_has "retargeted-base audit records the base certified at the gate" "pr_base_at_gate=main"
assert_audit_has "retargeted-base audit records the new base" "pr_base_now=some/other-branch"

# 9e2. Repository made PUBLIC during the CI wait: the repo passed the private-only boundary at guard 2b
# but was flipped public during check-ci.sh's watch window — the same staleness
# class as the base retarget above. The pre-merge re-verify folds isPrivate into
# its repo view and must refuse (exit 12); the merge must never fire.
STUB_SHA="pubrace01" STUB_PRIVATE=true STUB_PRIVATE_PREMERGE=false \
    run_mog 12 "repo made public during the CI wait → exit 12"
assert_gh_lacks "public-race: no merge attempted" "pr merge"
assert_audit_has "public-race audits the pre-merge privacy reason" "reason=not-private-premerge"

# 9e3. Empty pre-merge baseRefName: a fresh
# baseRefName that comes back EMPTY right before merging is undeterminable →
# refuse (exit 12) fail-closed, never default silently. The stub preserves an
# explicitly-empty STUB_BASE_PREMERGE (`-`, not `:-`) so this path is reachable.
STUB_SHA="emptybase01" STUB_BASE_PREMERGE="" \
    run_mog 12 "empty pre-merge base → exit 12 fail-closed"
assert_gh_lacks "empty-premerge-base: no merge attempted" "pr merge"
assert_audit_has "empty-premerge-base audits undeterminable" "reason=base-branch-undeterminable"

# External `jq` availability: the two null-
# coalesce cases below feed synthetic null JSON through the SCRIPT'S OWN --jq
# filter via real jq — proving the coalesce fix in merge-on-green.sh itself
# rather than a hand-picked stub string. jq is NOT an established dependency
# of this repo (no standalone `jq` anywhere under scripts/ — the many `--jq`
# are gh's OWN embedded jq, not the external binary). On a machine without jq
# SKIP those cases cleanly instead of silently breaking: this suite has no
# skip counter, so a SKIP line is not counted as pass or fail. Behaviour is
# unchanged when jq IS installed.
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1

# 9f. Nullable defaultBranchRef at guard 2b/2c: a repo API
# response with defaultBranchRef: null must be coalesced in the script's OWN
# --jq filter to "" (undeterminable), not jq's literal "null" string sliding
# past -z and mislabeling as wrong-base-branch.
if [ "$have_jq" = "1" ]; then
    STUB_DEFAULT_BRANCH_NULL=1 run_mog 12 "null defaultBranchRef at the gate → exit 12 undeterminable"
    assert_gh_lacks "null-default-branch: no merge attempted" "pr merge"
    assert_audit_has "null-default-branch audits undeterminable, not wrong-base" "reason=base-branch-undeterminable"
else
    echo "  SKIP: jq not installed — null-defaultBranchRef-at-gate case (CodeRabbit)"
fi

# 9g. Same nullable-coalesce fix applied to the FIX-1 pre-merge re-query.
if [ "$have_jq" = "1" ]; then
    STUB_DEFAULT_BRANCH_PREMERGE_NULL=1 run_mog 12 "null defaultBranchRef at the pre-merge re-query → exit 12 undeterminable"
    assert_gh_lacks "null-default-branch-premerge: no merge attempted" "pr merge"
    assert_audit_has "null-default-branch-premerge audits undeterminable" "reason=base-branch-undeterminable"
else
    echo "  SKIP: jq not installed — null-defaultBranchRef-pre-merge case (CodeRabbit)"
fi

# 9h. Pre-merge title gate (guard 3c): the squash merge below
# makes the PR TITLE main's commit subject verbatim, but only worker-pr-open.sh
# checked it at open time — the title can still be edited in the GitHub UI any
# time up to (and during) the check-ci.sh watch. A type-less title re-verified
# right before merging refuses (exit 20), same staleness class as the
# base-branch-changed guard (9e) above.
STUB_PR_TITLE="[HIMMEL-1] fix the thing" \
    run_mog 20 "type-less title at pre-merge → exit 20"
assert_gh_lacks "title-gate: no merge attempted" "pr merge"
assert_audit_has "title-gate audits the refusal reason" "reason=title-gate-failed"
assert_audit_has "title-gate audit records the bad title" "title=[HIMMEL-1] fix the thing"
assert_err_has "title-gate stderr names the conventional-commit rule" "conventional-commit"

# 9i. Pre-merge title gate: an undeterminable title (gh returns empty) refuses
# (exit 20) fail-closed rather than waving the merge through on a title it
# could not read.
STUB_PR_TITLE="" run_mog 20 "undeterminable title at pre-merge → exit 20 fail-closed"
assert_gh_lacks "undeterminable-title: no merge attempted" "pr merge"
assert_audit_has "undeterminable-title audits the reason" "reason=title-undeterminable"

# 9j. Pre-merge title gate: a properly-typed, ticketed title still merges
# (exit 0) — the gate passes real conventional titles through unchanged.
STUB_SHA="titleok01" STUB_PR_TITLE="fix(x): [HIMMEL-42] thing" \
    run_mog 0 "conventional ticketed title → merged"
assert_merge_has "title-gate-ok merge pins the certified sha" "--match-head-commit titleok01"

# 9k. Pre-merge title gate: a ticketless Dependabot-authored title merges
# (exit 0) — guard 3c once never
# threaded the PR author, so a title that already passed worker-pr-open.sh's
# open-time check and the CI title-lint workflow (both exempt
# dependabot[bot]) was refused here instead. RED-first: the mutant below
# strips the threading and must reproduce the pre-fix exit 20.
STUB_SHA="titleok02" STUB_PR_TITLE="build(deps): bump foo from 1 to 2" STUB_PR_AUTHOR="dependabot[bot]" \
    run_mog 0 "ticketless dependabot title at pre-merge → merged"
assert_merge_has "title-gate-dependabot merge pins the certified sha" "--match-head-commit titleok02"

# shellcheck disable=SC2016  # literal match/replacement against
# merge-on-green.sh's own source text (unexpanded $fresh_title_author) --
# not a shell expansion.
rc_notitleauthor_widened_line='if ! title_err=$(TICKET_ID_AUTHOR="$fresh_title_author" TICKET_ID_TRUSTED_AUTHOR="$fresh_title_author" "$himmel_repo/scripts/lib/check-pr-title.sh" "$fresh_title" 2>&1); then'
# shellcheck disable=SC2016  # same reason as above -- literal source text.
rc_notitleauthor_reverted_line='if ! title_err=$("$himmel_repo/scripts/lib/check-pr-title.sh" "$fresh_title" 2>&1); then'
rc_notitleauthor_mutant=$(mktemp "${TMPDIR:-/tmp}/mog-3616-notitleauthor-mutant.XXXXXX")
if [ -z "$rc_notitleauthor_mutant" ] || [ ! -f "$rc_notitleauthor_mutant" ]; then
    fail "RED (no-author-threading) setup: mktemp produced no mutant-script file — refusing to build the fixture on an empty root"
else
    awk -v line="$rc_notitleauthor_widened_line" -v repl="$rc_notitleauthor_reverted_line" \
        '$0==line{print repl; next}{print}' "$MOG" > "$rc_notitleauthor_mutant"
    rc_notitleauthor_pre=$(grep -Fxc -- "$rc_notitleauthor_widened_line" "$MOG")
    rc_notitleauthor_post=$(grep -Fxc -- "$rc_notitleauthor_widened_line" "$rc_notitleauthor_mutant")
    # A SUBSTITUTION (one line replaced by a different line): diff reports 2
    # (one `<` old line, one `>` new line) — same shape as RC-4's above.
    rc_notitleauthor_diff=$(diff "$MOG" "$rc_notitleauthor_mutant" | grep -c '^[<>]')
    if [ "$rc_notitleauthor_pre" -eq 1 ] && [ "$rc_notitleauthor_post" -eq 0 ] && [ "$rc_notitleauthor_diff" -eq 2 ]; then
        STUB_SHA="titleok02" STUB_PR_TITLE="build(deps): bump foo from 1 to 2" STUB_PR_AUTHOR="dependabot[bot]" \
            MOG_SRC="$rc_notitleauthor_mutant" \
            run_mog 20 "RED: without author threading, the dependabot title is refused (exit 20)"
    else
        fail "RED (no-author-threading) setup: mutant did not cleanly substitute exactly one line (pre=$rc_notitleauthor_pre post=$rc_notitleauthor_post diff=$rc_notitleauthor_diff)"
    fi
fi

# 10. --dry-run: gates pass but NO merge fires.
run_mog 0 "dry-run passes gates, no merge" -- --dry-run
assert_gh_lacks  "dry-run does not merge"   "pr merge"
assert_audit_has "dry-run audits DRYRUN"    "DRYRUN"

# 11. gh pr merge fails (head moved / conflict) and the PR stays OPEN through the
# bounded confirmation poll → still fail-closed exit 15, but classified
# INDETERMINATE, not REFUSED: a merge accepted server-side and
# reported as failed can still land, so "not merged" is not proven here.
STUB_MERGE_FAIL=1 STUB_POST_STATE=OPEN run_mog 15 "merge failure + PR OPEN → exit 15 indeterminate"
assert_state_requery "failed merge re-queries PR state"
assert_audit_has "unproven merge outcome is INDETERMINATE" "INDETERMINATE reason=merge-pending-unconfirmed"
assert_audit_lacks "unproven merge outcome is not claimed as a refusal" "REFUSED"

# An explicit base-policy rejection is definitive, not a queued
# merge. Without the stderr classification this incorrectly exits 15 pending.
STUB_MERGE_POLICY_REFUSED=1 STUB_POST_STATE=OPEN run_mog 18 "base branch policy prohibits the merge → exit 18"
assert_merge_has "policy rejection: merge was attempted" "pr merge 77 --repo owner/repo"
assert_audit_has "policy rejection: deterministic refusal" "REFUSED reason=policy-refused"
assert_audit_lacks "policy rejection: never pending-unconfirmed" "INDETERMINATE"
assert_err_has "policy rejection: surfaces GitHub's refusal" "base branch policy prohibits the merge"

# "Base branch was modified" is GitHub's
# TRANSIENT refusal — the PR is still OPEN at the same head and a bare re-run
# merges. It is NOT a rule, so it stays on exit 15 (indeterminate), never 18.
STUB_MERGE_BASE_MODIFIED=1 STUB_POST_STATE=OPEN run_mog 15 "'Base branch was modified' + PR OPEN → exit 15, not a policy block"
assert_audit_has "base-modified: recorded as INDETERMINATE" "INDETERMINATE reason=merge-pending-unconfirmed"
assert_audit_lacks "base-modified: never a policy refusal" "REFUSED"
assert_err_lacks "base-modified: no MERGE-BLOCKED alert" "MERGE-BLOCKED"

# 11b. gh exited non-zero but the PR is MERGED at the certified sha/base →
# success (exit 0), audited with the gh exit for the record. (Historically the
# worktree-held local-branch delete, PR #1466 — that cause is gone
# with --delete-branch, but any post-merge gh failure takes this path.)
STUB_SHA="cafe01" STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED run_mog 0 "gh rc!=0 + PR MERGED → exit 0"
assert_state_requery "gh-rc!=0 path re-queries PR state (pinned)"
assert_audit_has "gh-rc!=0 path records MERGED" "MERGED"
assert_audit_has "gh-rc!=0 audit names the gh exit" "gh-exit=1"
assert_audit_lacks "gh-rc!=0 audit carries no cleanup-failed record" "cleanup-failed"
# The recovery path prunes too — here from a non-repo cwd, so the
# outcome is "no-repo", but the field must be on the line.
assert_audit_has "gh-rc!=0 path records a prune outcome" "prune="
assert_audit_lacks "gh-rc!=0 merge is not recorded as refused" "REFUSED"

# 11c. The case the single re-query got WRONG: gh reported a
# failure for a request that was actually accepted (queued behind branch
# protection / a lost response), so the PR reads OPEN first and MERGED a moment
# later. The bounded poll must see the landing and credit it (exit 0), where the
# old one-shot re-query reported REFUSED.
STUB_SHA="pollmerge01" STUB_MERGE_FAIL=1 STUB_POST_OPEN_TIMES=1 STUB_POST_STATE=MERGED \
    run_mog 0 "gh rc!=0 + OPEN then MERGED on a later poll → exit 0"
assert_audit_has "late-landing merge is credited" "MERGED repo="
assert_audit_has "late-landing merge names the gh exit" "gh-exit=1"
assert_audit_lacks "late-landing merge is not reported as indeterminate" "INDETERMINATE"

# 11c2. If the state re-query itself fails, the outcome is indeterminate rather
# than falsely classified as either MERGED or REFUSED.
STUB_MERGE_FAIL=1 STUB_POST_STATE_FAIL=1 run_mog 15 "merge failure + state query failure → indeterminate exit 15"
assert_audit_has "state-query failure records indeterminate outcome" "INDETERMINATE reason=merge-state-query-failed"
assert_audit_lacks "indeterminate outcome is not recorded as refused" "REFUSED"

# 11c3. gh's own merge call failed (so --match-head-commit never confirmed
# $sha) but the PR reports MERGED at a DIFFERENT head — a concurrent actor
# merged a different commit in the gap. Must NOT be credited to this run.
STUB_SHA="cafe01" STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED STUB_POST_HEAD="deadbeef" \
    run_mog 15 "merge failure + PR MERGED at a different head → exit 15, not credited"
assert_audit_has "head-mismatch records the mismatch reason" "REFUSED reason=merge-state-head-mismatch"
assert_audit_has "head-mismatch audit names the certified sha" "sha=cafe01"
assert_audit_has "head-mismatch audit names the merged head" "merged_head=deadbeef"
assert_audit_lacks "head-mismatch is not recorded as MERGED" "MERGED repo="

# 11c4. gh's own merge call failed, and the PR reports MERGED with the SAME
# certified head — but landed on a DIFFERENT base than the one guard 3b
# re-verified (a concurrent `gh pr edit --base` retarget, which does not move
# the head). Must NOT be credited to this run.
STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED STUB_POST_BASE="side-branch" \
    run_mog 15 "merge failure + PR MERGED at the certified sha but a different base → exit 15, not credited"
assert_audit_has "base-mismatch records the mismatch reason" "REFUSED reason=merge-state-base-mismatch"
assert_audit_has "base-mismatch audit names the authorized base" "authorized_base=main"
assert_audit_has "base-mismatch audit names the merged base" "merged_base=side-branch"
assert_audit_lacks "base-mismatch is not recorded as MERGED" "MERGED repo="

# 11d. Audit sink not writable → refuse BEFORE merging (exit 16), no merge.
STUB_AUDIT_UNWRITABLE=1 run_mog 16 "unwritable audit sink → exit 16"
assert_gh_lacks "unwritable-audit: no merge attempted" "pr merge"

# 11e. gh ACCEPTS the merge (rc 0) but the PR never reports MERGED → exit 15
# A zero rc is "accepted", not "merged" — under a merge queue the
# PR can sit queued. exit 0 must mean MERGED. CLOSED (not OPEN) is used here so
# the confirmation poll breaks on the first read instead of waiting out its
# full budget; the OPEN/queued case walks the same branch after the timeout.
STUB_POST_STATE=CLOSED run_mog 15 "merge accepted but PR not MERGED → exit 15"
assert_audit_has "unconfirmed merge audits the refusal" "reason=merge-unconfirmed"
assert_state_requery "success path confirms PR state"

# 11f. gh ACCEPTS the merge (rc 0, e.g. queue admission), and the PR reports
# MERGED — but at a DIFFERENT head than the certified sha. A concurrent actor
# merged a different commit while this run's admission sat queued. Must NOT
# be credited (the success-path analog of 11c3).
STUB_SHA="cafe01" STUB_POST_STATE=MERGED STUB_POST_HEAD="deadbeef" \
    run_mog 15 "merge accepted + PR MERGED at a different head → exit 15, not credited"
assert_audit_has "success-path head-mismatch records the mismatch reason" "REFUSED reason=merge-state-head-mismatch"
assert_audit_has "success-path head-mismatch audit names the certified sha" "sha=cafe01"
assert_audit_has "success-path head-mismatch audit names the merged head" "merged_head=deadbeef"
assert_audit_lacks "success-path head-mismatch is not recorded as MERGED" "MERGED repo="

# 11g. gh ACCEPTS the merge (rc 0), and the PR reports MERGED at the certified
# head — but on a DIFFERENT base than guard 3b re-verified. A concurrent
# `gh pr edit --base` retarget while queued. Must NOT be credited
# (the success-path analog of 11c4).
STUB_POST_STATE=MERGED STUB_POST_BASE="side-branch" \
    run_mog 15 "merge accepted + PR MERGED at the certified sha but a different base → exit 15, not credited"
assert_audit_has "success-path base-mismatch records the mismatch reason" "REFUSED reason=merge-state-base-mismatch"
assert_audit_has "success-path base-mismatch audit names the authorized base" "authorized_base=main"
assert_audit_has "success-path base-mismatch audit names the merged base" "merged_base=side-branch"
assert_audit_lacks "success-path base-mismatch is not recorded as MERGED" "MERGED repo="

# --- 11h..11k. post-merge worktree prune ------------------------
# A confirmed merge prunes the ONE local worktree checked out on the PR's head
# branch, so a merged ticket's tree never outlives its PR. Fixture: a real
# throwaway repo + a real worktree per case (never the himmel checkout — see
# run_mog's cwd note). Every case must still exit 0: a prune that cannot happen
# is reported, never escalated.
prune_branch_gone() { ! git -C "$1" rev-parse --quiet --verify refs/heads/feat/mog-prune >/dev/null 2>&1; }
# mk_prune_fixture_quoted — same shape as mk_prune_fixture, but the worktree
# path itself contains a newline. `git worktree list --porcelain` (without
# -z) prints the path RAW, with no quoting or escaping (verified: a literal
# double quote passes through unquoted too), so a path byte that collides
# with the parser's own line delimiter breaks a naive line-by-line read at
# both merge-on-green.sh call sites. -z (NUL-terminated
# records) is the only delimiter a path can never contain.
#
# Sets globals QP_REPO/QP_WT/QP_SHA instead of the usual echo+`read <<<`
# return: `read` itself always terminates a record at \n regardless of IFS,
# so a value containing an embedded newline cannot survive that channel.
mk_prune_fixture_quoted() {
    local root branch="feat/mog-prune-q" repo wt
    root=$(mktemp -d) || { echo "FAIL: mk_prune_fixture_quoted: mktemp -d produced no run sandbox" >&2; return 1; }
    repo="$root/repo"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m base
    git -C "$repo" branch -m main 2>/dev/null || true
    wt="$root/w"$'\n'"t"
    git -C "$repo" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/work.txt"
    git -C "$wt" add work.txt
    git -C "$wt" commit -q -m work
    QP_REPO="$repo"
    QP_WT="$wt"
    QP_SHA="$(git -C "$repo" rev-parse "$branch")"
}
# wt_list_has <repo> <path> — does `git worktree list --porcelain` in <repo>
# still carry a row for <path>? Normalizes both sides via cd+pwd (the same
# trick merge-on-green.sh's own worktree_intact uses) because on this
# platform the porcelain output prints a DIFFERENT but equivalent spelling of
# the path (Windows-style C:/... vs POSIX /c/...) than a plain string compare
# would expect.
wt_list_has() {
    local repo="$1" path="$2" path_pwd line wt wt_pwd
    path_pwd=$(cd "$path" 2>/dev/null && pwd -P) || path_pwd="$path"
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                wt_pwd=$(cd "$wt" 2>/dev/null && pwd -P) || wt_pwd="$wt"
                [ "$wt_pwd" = "$path_pwd" ] && return 0
                ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    return 1
}

# 11g2. A metadata line missing the headRefName field is malformed → exit 13,
# no merge. Without the shape check head_branch silently becomes pr_base and is
# handed to the prune as a branch name.
STUB_META_5FIELD=1 run_mog 13 "5-field meta (no headRefName) → exit 13"
assert_gh_lacks "malformed meta: no merge attempted" "pr merge"
assert_audit_has "malformed meta is audited" "REFUSED reason=malformed-meta"

# 11h. Clean merged worktree, invoked from the PRIMARY checkout → removed,
# branch deleted, exit still 0. Also the negative control for the
# in-use probe: nothing holds this tree, so the rename probe must not block a
# legitimate prune.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged + clean worktree → pruned, exit 0"
if [ -d "$P_WT" ]; then fail "11h: merged worktree was not removed"; else pass; fi
if prune_branch_gone "$P_REPO"; then pass; else fail "11h: merged branch was not deleted"; fi
assert_audit_has "11h: audit records the prune outcome" "prune=removed branch=deleted"

# 11h-q. Same fixture, but the worktree path holds a newline.
# `git worktree list --porcelain` prints it raw, so a naive line parse never
# matches "worktree "/"branch refs/heads/feat/mog-prune-q" to the real path
# and the prune silently skips it. RED before the -z fix.
mk_prune_fixture_quoted; P_REPO="$QP_REPO"; P_WT="$QP_WT"; P_SHA="$QP_SHA"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune-q" \
    run_mog 0 "11h-q: quoted-path worktree, merged + clean → pruned, exit 0"
if [ -d "$P_WT" ]; then fail "11h-q: merged quoted-path worktree was not removed"; else pass; fi
if git -C "$P_REPO" rev-parse --quiet --verify refs/heads/feat/mog-prune-q >/dev/null 2>&1; then
    fail "11h-q: merged branch was not deleted"
else
    pass
fi
assert_audit_has "11h-q: audit records the prune outcome" "prune=removed branch=deleted"

# 11i. Dirty worktree → plain `git worktree remove` refuses (never --force), the
# tree survives INTACT, and the merge is still a success. NEGATIVE CONTROL for
# `[ -d "$P_WT" ]` alone is not enough here — a GUTTED tree (the
# wreck) also satisfies that check, which is exactly the blind spot
# this ticket closes. Assert the tree is actually whole, not just present.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
printf 'uncommitted\n' >> "$P_WT/work.txt"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged + dirty worktree → kept, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11i: dirty worktree was destroyed"; fi
if [ -e "$P_WT/.git" ]; then pass; else fail "11i: dirty worktree's .git is gone (gutted, not kept)"; fi
if [ -f "$P_WT/work.txt" ] && grep -qF "uncommitted" "$P_WT/work.txt"; then
    pass
else
    fail "11i: dirty worktree's uncommitted work did not survive"
fi
if wt_list_has "$P_REPO" "$P_WT"; then
    pass
else
    fail "11i: dirty worktree's 'git worktree list' row is gone"
fi
if prune_branch_gone "$P_REPO"; then fail "11i: branch deleted despite a kept worktree"; else pass; fi
assert_audit_has "11i: audit records the refusal" "prune=dirty-kept"

# 11j. Invoked FROM the worktree it just merged → deferred, never removed out
# from under the caller.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged from inside the worktree → deferred, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11j: the caller's own cwd was removed"; fi
assert_audit_has "11j: audit records the deferral" "prune=own-cwd-deferred"
# 11j2. The deferral prints ONE hint on stderr (where every other
# post-merge note goes) saying the worktree was KEPT because the merge ran from
# inside it, with the exact prune command.
assert_err_has "11j2: hint says the worktree was kept" "KEPT worktree '$P_WT'"
assert_err_has "11j2: hint says why (the merge ran from inside it)" "merge ran from inside it"
assert_err_has "11j2: hint carries the prune command" "git -C '$P_REPO' worktree remove '$P_WT' && git -C '$P_REPO' branch -D 'feat/mog-prune'"
if [ "$(grep -cF 'KEPT worktree' <<< "$LAST_ERR")" = "1" ]; then pass; else fail "11j2: expected exactly one keep hint (err: $LAST_ERR)"; fi
# 11j3. Negative control: a merge NOT from inside the worktree prunes it and
# prints no keep hint.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "11j3: merged from the primary checkout → pruned, exit 0"
assert_audit_has "11j3: audit records the prune" "prune=removed"
if grepq "$LAST_ERR" -F 'KEPT worktree'; then fail "11j3: a pruning merge printed the keep hint (err: $LAST_ERR)"; else pass; fi

# 11k. A worktree whose tip is not the certified sha (here behind it) keeps the
# tree — clean-garden's exact-head-match rule, and what makes the branch -D
# fallback in 11h lossless.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
printf 'pushed from elsewhere\n' >> "$P_WT/work.txt"
git -C "$P_WT" commit -q -am "pushed from elsewhere"
P_AHEAD_SHA=$(git -C "$P_WT" rev-parse HEAD)
git -C "$P_WT" reset -q --hard "$P_SHA"
MOG_CWD="$P_REPO" STUB_SHA="$P_AHEAD_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged but tip differs → kept, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11k: worktree with post-merge commits was removed"; fi
assert_audit_has "11k: audit records the tip mismatch" "prune=tip-differs-kept"

# 11k1. A commit made in the worker's worktree after the PR head (the 4023 /
# 7f2eb545f sequence) is refused BEFORE any gate or merge, so the commit is
# never left behind on a branch whose PR merged without it.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
printf 'after the GO head\n' >> "$P_WT/work.txt"
git -C "$P_WT" commit -q -am "unpushed after the GO head"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 25 "11k1: worktree HEAD ahead of the PR head → exit 25"
assert_gh_lacks "11k1: no merge attempted" "pr merge"
assert_audit_has "11k1: refusal audited" "REFUSED reason=local-commits-not-in-pr ahead=1"
if grepq "$LAST_ERR" -F 'push them' && grepq "$LAST_ERR" -F 'follow-up'; then pass; else fail "11k1: refusal does not name both remedies (err: $LAST_ERR)"; fi

# 11k1b. The same worktree with HEAD == PR head still merges.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "11k1b: worktree HEAD == PR head → merges, exit 0"
assert_gh_has "11k1b: merge fired" "pr merge"

# 11k1c. A PR head absent from the worktree's object store cannot be compared,
# so the guard fails closed instead of reading the failed rev-list as "nothing ahead".
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_WT" STUB_SHA="0123456789abcdef0123456789abcdef01234567" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 25 "11k1c: PR head not in the local object store → exit 25"
assert_gh_lacks "11k1c: no merge attempted" "pr merge"
assert_audit_has "11k1c: refusal audited" "REFUSED reason=local-commits-unreadable"

# 11k1d. A tag named like the branch makes `symbolic-ref --short` print
# heads/<branch>; the guard still sees the checkout as on the PR's branch.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
git -C "$P_WT" tag feat/mog-prune
git -C "$P_WT" commit -q --allow-empty -m "unpushed beside a same-named tag"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 25 "11k1d: same-named tag does not hide the branch → exit 25"
assert_gh_lacks "11k1d: no merge attempted" "pr merge"

# 11k1e. A local commit made while check-ci watches CI is caught by the
# re-check right before the merge.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_CI_COMMIT=1 \
    run_mog 25 "11k1e: commit made during the CI watch → exit 25"
assert_gh_lacks "11k1e: no merge attempted" "pr merge"

read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
git -C "$P_WT" commit -q --allow-empty -m "unpushed after the GO head"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NO_CWD_PR=1 \
    run_mog 25 "11k1f: --go from the primary, PR worktree ahead → exit 25" -- --go "/nonexistent/go/77.$P_SHA"
assert_gh_has "11k1f: the PR came from the GO name" "pr view 77 --json state,url,number,"
assert_gh_lacks "11k1f: no merge attempted" "pr merge"
assert_audit_has "11k1f: refusal audited" "REFUSED reason=local-commits-not-in-pr ahead=1"

read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
wl_bin=$(mktemp -d "${TMPDIR:-/tmp}/mog-wl-bin.XXXXXX") || wl_bin=""
if [ -z "$wl_bin" ] || [ ! -d "$wl_bin" ]; then
    fail "11k1g: setup: no scratch dir for the git shim"
else
    printf "#!/usr/bin/env bash\n[ \"\$1 \$2\" != \"worktree list\" ] || exit 1\nexec %q \"\$@\"\n" "$(command -v git)" > "$wl_bin/git"
    chmod +x "$wl_bin/git"
    MOG_PATH_BASE="$wl_bin:$PATH" MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NO_CWD_PR=1 \
        run_mog 25 "11k1g: worktree listing fails → exit 25" -- --go "/nonexistent/go/77.$P_SHA"
    assert_gh_lacks "11k1g: no merge attempted" "pr merge"
    assert_err_has "11k1g: stderr names the failed listing" "cannot list this checkout's worktrees"
    rm -rf "$wl_bin"
fi

# 11k2. POSITIVE CONTROL: a worktree held open by a live native
# process is detected BEFORE the remove and skipped WHOLE. This is the case
# that FAILS before the fix (the old code let git's non-atomic-on-Windows
# remove gut the tree, then called it "left in place") and PASSES after it.
# Windows-gated: a native pwsh process holding a directory is the only thing
# MEASURED to block the final rmdir — an MSYS bash holder does not (see the
# repro table cited in prune_merged_worktree's own comment) — so
# the failure mode is not constructible on other platforms.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        PWSH=$(command -v pwsh || command -v powershell || true)
        if [ -z "$PWSH" ]; then
            echo "  SKIP: no pwsh/powershell on PATH — HIMMEL-2227 in-use-worktree case needs a native Windows holder"
        else
            read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
            # Ready marker lives OUTSIDE the worktree (a sibling path), not
            # inside it: an extra untracked file INSIDE the tree perturbs the
            # very git-worktree-remove behaviour under test. Matches the
            # repro exactly. cygpath -m (not a bare argv pass) so
            # a native pwsh.exe gets the real Windows path, not MSYS's naive
            # /tmp -> C:\tmp argv mangling (which is a DIFFERENT, wrong root
            # from /tmp's actual mount).
            ready="$P_WT.mog-test-ready"
            ready_win=$(cygpath -m "$ready" 2>/dev/null || printf '%s' "$ready")
            rm -f "$ready"
            ( cd "$P_WT" && "$PWSH" -NoProfile -Command "New-Item -ItemType File '$ready_win' | Out-Null; Start-Sleep 30" ) &
            HOLDER=$!
            tries=0
            while [ ! -f "$ready" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            if [ ! -f "$ready" ]; then
                fail "11k2: the pwsh holder never signaled ready — cannot exercise the in-use case"
            else
                MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                    run_mog 0 "merged + in-use worktree -> skipped, exit 0"
                if [ -d "$P_WT" ]; then pass; else fail "11k2: in-use worktree directory is gone"; fi
                if [ -e "$P_WT/.git" ]; then pass; else fail "11k2: in-use worktree's .git is gone (gutted)"; fi
                if [ -f "$P_WT/work.txt" ] && grep -qF "feat/mog-prune" "$P_WT/work.txt"; then
                    pass
                else
                    fail "11k2: in-use worktree's work.txt did not survive (the pre-fix wreck)"
                fi
                if wt_list_has "$P_REPO" "$P_WT"; then
                    pass
                else
                    fail "11k2: in-use worktree's 'git worktree list' row is gone"
                fi
                if prune_branch_gone "$P_REPO"; then fail "11k2: branch deleted despite an in-use worktree"; else pass; fi
                assert_audit_has "11k2: audit records the in-use skip" "prune=in-use-skipped"
                if [ -e "$P_WT.worktree-inuse-probe" ]; then
                    fail "11k2: a stranded .worktree-inuse-probe directory was left behind"
                else
                    pass
                fi
            fi
            # ALWAYS kill the holder, pass or fail, or the suite leaves an
            # orphan pwsh process behind.
            kill "$HOLDER" 2>/dev/null
            wait "$HOLDER" 2>/dev/null
        fi
        ;;
    *)
        echo "  SKIP: not Windows — a live process's cwd blocks neither rename nor rmdir on POSIX, so the in-use case is not constructible here"
        ;;
esac

# --- 11k4..11k7. a live shell-suite run inside the tree ------
# The in-use probe above cannot see this case AT ALL on POSIX: a process's
# cwd blocks neither the rename nor the rmdir, so 11k2 is Windows-gated and the
# prune sails straight through — which is exactly what happened twice on
# 2026-09-05 (PRs #2133, #2134) and again at 04:50 on #2150. These four cases
# are the POSIX half of the same guarantee, and they are Linux-gated for the
# mirror-image reason: /proc/<pid>/cwd is the only cwd oracle the detector has.
#
# The holder is a REAL process, not a fake lock file: the detector reads the
# process table, so anything less would test nothing. Its script is named
# `run-shell-tests.sh` (that name in argv is half the predicate) and lives
# OUTSIDE the fixture worktree — an extra untracked file inside the tree would
# perturb the very `git worktree remove` behaviour under test, the same
# reasoning 11k2's ready-marker placement records.
#
# Four cases, because the predicate has two independent halves and both must be
# shown load-bearing rather than merely present:
#   11k4  runner cwd INSIDE the tree                     -> refused
#   11k5  runner cwd OUTSIDE, argv silent about the tree -> pruned  (control)
#   11k6  runner cwd OUTSIDE, argv NAMES the tree        -> refused (queued-runner shape)
#   11k7  non-runner process cwd INSIDE the tree, FOREIGN -> refused (see below)
#   11k8  runner argv names a PREFIX-SHARING sibling     -> pruned  (control)
#   11k9  a non-runner process that NAMES a runner, FOREIGN -> refused (see below)
#   11k10 argv names a path that merely ENDS with ours  -> pruned  (control)
#   11k11 ONE argument embedding a space and our path  -> pruned  (control)
#   11k12 relative argv path, runner cwd OUTSIDE tree  -> refused
#   11k13 relative argv path spelled through ./ and ../ -> refused
#   11k14 a holder that IS the caller's own ANCESTRY   -> pruned
# 11k5 and 11k8/11k10/11k11 are the controls that keep 11k4/11k6/11k12/11k13
# honest: without them a detector that simply always refused would pass just
# as well.
#
# CONTRACT REVISION (2026-09-06) — 11k7 and 11k9 were originally
# NEGATIVE controls for THIS predicate specifically ("the refusal must key on
# the runner, not on 'anything is in there'"), because worktree_in_use itself
# was a no-op on Linux at the time: nothing else was watching a non-runner
# holder, so pruning around it was correct. worktree_in_use now has its OWN
# live-process detector (scripts/lib/worktree-inuse.sh) that
# catches ANY foreign holder, runner or not — and the 2517 guard was written for
# a WORKER-run merge, where the merge process's own ancestry naturally included
# the worker holding the tree. Merges are now CHIEF-run while the worker still
# holds its tree, and the first merge after that change (PR #2179) proved the
# hazard for real: merge-on-green pruned that PR's own worktree out from under
# it. Both fixtures below launch their holder as a SIBLING of the merge-on-green
# process (a direct child of this test script, same as merge-on-green itself),
# never an ancestor — so both are now FOREIGN holders under the ancestry
# predicate and correctly BLOCK the prune. 11k14, below, is the new control
# that keeps THIS predicate honest: a holder that IS the caller's ancestry
# must still be pruned around, or the auto-prune is dead on arrival.
case "$(uname -s)" in
    Linux*)
        # A failed mktemp leaves this EMPTY, and every path below is built on
        # it — the holder scripts would be written to, and later deleted from,
        # the filesystem root, and 11k4-11k9 would go vacuously green because no
        # holder ever started. Capture the failure here.
        SUITE_HOLDER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mog-2517-holder.XXXXXX")
        if [ -z "$SUITE_HOLDER_DIR" ] || [ ! -d "$SUITE_HOLDER_DIR" ]; then
            fail "11k4-11k9: mktemp -d produced no holder sandbox — refusing to build fixture paths on an empty root"
            exit 1
        fi
        cat > "$SUITE_HOLDER_DIR/run-shell-tests.sh" <<'SHEOF'
#!/usr/bin/env bash
# $1 = ready marker. Touch it (proving this process reached execution — a
# holder that never ran would make every assertion below vacuous), then idle
# until the marker is removed. Self-bounded at ~60s so a failing case can never
# strand this process on the box.
touch "$1"
n=0
while [ -e "$1" ] && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done
SHEOF
        # sleeper.sh: the same idle-until-removed shape, but for the
        # "foreign process cwd'd inside the tree" fixtures (11k7, RC-1
        # row-2), whose detector is worktree_in_use's /proc scan -- it names
        # the FIRST /proc entry it finds with a cwd inside the tree, in
        # lexicographic pid order. run-shell-tests.sh's idle
        # `sleep` inherits its parent's cwd, which is fine there (it argv-
        # matches as a real runner, so a transient sleep child never gets
        # picked); here the holder is meant to be the ONLY process cwd'd
        # inside the tree, so a sleep child that also inherited that cwd
        # could sort before the holder's own pid and get named instead.
        # A builtin read on a FIFO idles without any fork; even
        # readiness is written by a builtin, so there are no transient children.
        cat > "$SUITE_HOLDER_DIR/sleeper.sh" <<'SHEOF'
#!/usr/bin/env bash
exec 3<> "$1.idle"
printf ready > "$1"
n=0
while [ -e "$1" ] && [ "$n" -lt 60 ]; do read -r -t 1 -u 3 _idle || :; n=$((n + 1)); done
SHEOF

        # start_suite_holder <cwd> <script> [extra-argv...] — sets HOLDER_PID
        # and HOLDER_READY. `bash -c '... exec ...'` rather than a subshell so
        # HOLDER_PID IS the holder itself: its argv is what the detector matches
        # and killing it kills the thing under test, not a parent of it.
        start_suite_holder() {
            local hcwd="$1" hscript="$2"; shift 2
            HOLDER_READY="$SUITE_HOLDER_DIR/ready.$$.$RANDOM"
            rm -f "$HOLDER_READY" "$HOLDER_READY.idle"
            mkfifo "$HOLDER_READY.idle" || return 1
            bash -c 'cd "$1" || exit 1; s="$2"; shift 2; exec bash "$s" "$@"' \
                _ "$hcwd" "$hscript" "$HOLDER_READY" "$@" &
            HOLDER_PID=$!
            local tries=0
            while [ ! -f "$HOLDER_READY" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            [ -f "$HOLDER_READY" ]
        }
        stop_suite_holder() {
            rm -f "$HOLDER_READY"
            kill "$HOLDER_PID" 2>/dev/null
            wait "$HOLDER_PID" 2>/dev/null
            rm -f "$HOLDER_READY.idle"
        }

        # 11k0. A .idle FIFO left behind at the path a later
        # holder draws (same $$, same $RANDOM) must not fail its mkfifo, and a
        # stopped holder must leave no .idle behind. RANDOM is reseeded so the
        # collision is deterministic; the stale path is the one CI hit
        # ("mkfifo: cannot make fifo '.../ready.<pid>.<n>.idle': File exists").
        RANDOM=5599
        stale_ready="$SUITE_HOLDER_DIR/ready.$$.$RANDOM"
        if ! mkfifo "$stale_ready.idle"; then
            fail "11k0: could not create the stale fixture $stale_ready.idle"
        else
            RANDOM=5599
            if start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/sleeper.sh"; then
                pass
            else
                fail "11k0: start_suite_holder failed on a stale $stale_ready.idle left by an earlier holder"
            fi
            stop_suite_holder
            if [ -e "$stale_ready.idle" ]; then
                fail "11k0: stop_suite_holder left $stale_ready.idle behind"
                rm -f "$stale_ready.idle"
            else
                pass
            fi
        fi

        # run_mog_as_descendant <ancestor_cwd> <mog_cwd> <mog_script> [argv...]
        # 11k14, RC-1 — runs <mog_script> exactly the way
        # run_mog's own inner invocation does (cd to <mog_cwd>, then `exec
        # bash` so the merge-on-green PROCESS's own cwd is <mog_cwd>), but as
        # the CHILD of a REAL, separate process that cd's to <ancestor_cwd>
        # and stays alive (blocked on `wait`) for the whole run -- the actual
        # process shape of "a worker holds the tree, a chief-run merge-on-green
        # runs underneath it", not a simulated flag. GH_LOG/CLEAR_LOG/etc are
        # read from the environment by the caller's own var-prefix, exactly
        # like any other command -- prefixed vars on a function call are
        # exported for its duration (same mechanism STUB_SHA/STUB_HEAD_BRANCH
        # already rely on to reach the gh stub several process-generations
        # down from run_mog above), so they reach the ancestor subshell, the
        # exec'd mog process, and everything mog itself spawns.
        #
        # Stdout/stderr and the exit code are NOT redirected/captured here
        # (unlike run_mog): the caller wraps this call exactly like it would
        # wrap any other command (`... >/dev/null 2>"$errfile"`, `rc=$?`),
        # because the surrounding `( ... )` here is only the ancestor-fork
        # boundary, not a place to hide that plumbing from the caller.
        run_mog_as_descendant() {
            local ancestor_cwd="$1" mog_cwd="$2" mog_script="$3"; shift 3
            (
                cd "$ancestor_cwd" || exit 1
                bash -c 'cd "$1" || exit 1; shift; exec bash "$@"' _ "$mog_cwd" "$mog_script" "$@" &
                local child=$!
                wait "$child"
            )
        }

        # 11k4. POSITIVE: a runner executing inside the merged worktree. This is
        # the case that FAILS before the fix (prune=removed, tree gone, and the
        # runner then renders the 422-red artifact) and PASSES after it.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$P_WT" "$SUITE_HOLDER_DIR/run-shell-tests.sh"; then
            fail "11k4: the suite holder never signaled ready — cannot exercise the live-run case"
        else
            pass  # holder reached execution: every assertion below is about a real process
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + live suite run inside the worktree -> kept, exit 0"
            assert_audit_has "11k4: audit records the live-run refusal" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k4: worktree with a live suite run was removed"; fi
            if [ -e "$P_WT/.git" ]; then pass; else fail "11k4: worktree's .git is gone (gutted)"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k4: worktree contents did not survive"; fi
            if wt_list_has "$P_REPO" "$P_WT"; then pass; else fail "11k4: worktree's 'git worktree list' row is gone"; fi
            if prune_branch_gone "$P_REPO"; then fail "11k4: branch deleted despite a kept worktree"; else pass; fi
            case "$LAST_ERR" in
                *"is running a shell-test suite"*"$HOLDER_PID"*) pass ;;
                *) fail "11k4: the refusal message does not name the holding pid $HOLDER_PID (got: ${LAST_ERR:-<none>})" ;;
            esac
        fi
        stop_suite_holder

        # 11k5. NEGATIVE CONTROL: same runner, same name in argv, but anchored
        # OUTSIDE the tree and saying nothing about it. A detector that keyed on
        # "a run-shell-tests.sh exists anywhere" would refuse here and strand
        # every merged worktree on the box for as long as any suite is running.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh"; then
            fail "11k5: the suite holder never signaled ready — control not established"
        else
            pass  # the control's own process really is live while the prune runs
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + unrelated suite run elsewhere -> pruned, exit 0"
            assert_audit_has "11k5: an unrelated run does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k5: worktree survived despite no run inside it"; else pass; fi
        fi
        stop_suite_holder

        # 11k6. POSITIVE, the QUEUED-runner shape: a runner still waiting out
        # SUITE_LOCK_WAIT owns no lock and has executed nothing, so the lock's
        # owner file does not know about it — but it names the worktree it will
        # run against. That is the 04:50 #2150 instance; the lock file alone
        # would have missed it.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        # Normalised, because the argv match is a literal substring test against
        # the path merge-on-green itself resolved (cd + pwd) — a symlinked
        # TMPDIR would otherwise make the two spellings differ and the case
        # would pass or fail for the wrong reason.
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "$P_WT/scripts"; then
            fail "11k6: the suite holder never signaled ready — cannot exercise the argv-match case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run whose argv names the worktree -> kept, exit 0"
            assert_audit_has "11k6: audit records the argv-match refusal" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k6: worktree named by a live runner's argv was removed"; fi
        fi
        stop_suite_holder

        # 11k7. CONTRACT REVISION: a process cwd'd inside the tree
        # that is NOT a suite runner (identical script, different name) —
        # ORIGINALLY a negative control ("the refusal must key on the runner,
        # not on 'anything is in there'"), back when worktree_in_use itself
        # was a Linux no-op and nothing else was watching this holder. It now
        # has its own /proc-based detector that catches ANY
        # foreign holder, and this fixture launches its holder as a SIBLING of
        # the merge-on-green process (both direct children of this test
        # script) -- never an ancestor -- so it IS foreign under the new
        # ancestry predicate and now correctly BLOCKS the prune.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$P_WT" "$SUITE_HOLDER_DIR/sleeper.sh"; then
            fail "11k7: the sleeper never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a FOREIGN non-runner process inside the worktree -> kept, exit 0"
            assert_audit_has "11k7: a foreign non-runner process now blocks the prune" "prune=in-use-confirmed"
            if [ -d "$P_WT" ]; then pass; else fail "11k7: worktree was pruned despite a foreign holder cwd'd inside it"; fi
            case "$LAST_ERR" in
                *"Process $HOLDER_PID has its working directory"*) pass ;;
                *) fail "11k7: the WARN does not name the holding pid $HOLDER_PID (got: ${LAST_ERR:-<none>})" ;;
            esac
        fi
        stop_suite_holder

        # 11k8. NEGATIVE CONTROL: a runner whose
        # argv names a SIBLING worktree that merely shares this one's path as a
        # prefix. `.claude/worktrees/` names are branch-derived, so
        # `fix+himmel-2517-prune-race` and `fix+himmel-2517-prune-race-2` coexist
        # routinely — an open substring match would pin every merged tree open
        # for as long as any longer-named sibling is under test.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "${P_WT}-sibling/scripts"; then
            fail "11k8: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming a PREFIX-SHARING sibling -> pruned, exit 0"
            assert_audit_has "11k8: a prefix-sharing sibling does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k8: worktree retained for a run that named only a sibling path"; else pass; fi
        fi
        stop_suite_holder

        # 11k10. NEGATIVE CONTROL: the argv match
        # needs a LEADING boundary as well as a trailing one. 11k8 covers a path
        # that merely starts with ours; this covers one that merely ENDS with it
        # — a backup or snapshot root such as `/backup<worktree>/scripts`, which
        # an open-prefix pattern would read as the worktree itself.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "/backup${P_WT}/scripts"; then
            fail "11k10: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming a path that merely ENDS with ours -> pruned, exit 0"
            assert_audit_has "11k10: a path ending with ours does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k10: worktree retained for a run that named only a superstring path"; else pass; fi
        fi
        stop_suite_holder

        # 11k11. NEGATIVE CONTROL: ONE argument that
        # happens to contain a space and our worktree path. Flattened to a
        # string, that is indistinguishable from two arguments and matches every
        # boundary rule rounds 2 and 5 added; read on the kernel's own NUL
        # delimiters it is a single argument that is neither the path nor rooted
        # at it. This is the case the argv rewrite exists for, and the only one of
        # the six live-run controls that the pre-rewrite pattern could not pass.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "unrelated $P_WT"; then
            fail "11k11: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run whose ONE argument merely embeds our path -> pruned, exit 0"
            assert_audit_has "11k11: an embedded-space argument is not an argv element equal to our path" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k11: worktree retained for a single argument that merely embeds its path"; else pass; fi
        fi
        stop_suite_holder

        # 11k12. POSITIVE: a runner launched from
        # OUTSIDE the tree that names it RELATIVELY. Its cwd is the parent, so
        # the cwd check cannot see it, and `wt/scripts` is not the absolute path,
        # so a literal argv comparison cannot either — yet the scan root it walks
        # IS inside the worktree, and pruning deletes it mid-run. A false
        # negative, which is the one direction this detector may not have.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        P_PARENT=$(cd "$P_WT/.." && pwd)
        P_BASE=${P_WT##*/}
        if ! start_suite_holder "$P_PARENT" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "$P_BASE/scripts"; then
            fail "11k12: the suite holder never signaled ready — cannot exercise the relative-argv case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming the tree RELATIVELY from outside it -> kept, exit 0"
            assert_audit_has "11k12: a relative argv path resolves against the runner's cwd" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k12: worktree removed under a runner that named it relatively"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k12: worktree contents did not survive"; fi
        fi
        stop_suite_holder

        # 11k13. POSITIVE: a relative argument that
        # reaches the tree through `..`. Prefixing the cwd is not enough — the
        # resulting string names the worktree without SPELLING it — so the
        # comparison has to canonicalize. Same direction as 11k12: a miss here is
        # a false negative and the worktree is deleted under a live run.
        #
        # The `..` must come BEFORE the worktree path, not after it. A first
        # draft used `<wt>/../<wt>/scripts` from the parent and did NOT
        # discriminate: `case` globs match `/`, so `$path/*` happily matches
        # `<wt>/../<wt>/scripts` and the uncanonicalized mutant passed too.
        # Launching from the sibling repo directory and reaching back out is what
        # produces a string the prefix form genuinely cannot match.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        P_BASE=${P_WT##*/}
        if ! start_suite_holder "$P_REPO" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "../$P_BASE/scripts"; then
            fail "11k13: the suite holder never signaled ready — cannot exercise the dotted-path case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run reaching the tree through ../ -> kept, exit 0"
            assert_audit_has "11k13: a dotted relative path is canonicalized before comparing" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k13: worktree removed under a runner that named it through ../"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k13: worktree contents did not survive"; fi
        fi
        stop_suite_holder

        # 11k9. CONTRACT REVISION (the original
        # worktree_has_live_suite_run-only shape): a process that
        # NAMES a runner without being one — an editor or a `tail -f` opened on
        # `run-shell-tests.sh` — with its cwd inside the merged worktree.
        # ORIGINALLY a negative control against worktree_has_live_suite_run
        # specifically ("naming is not running"). This holder is launched as a
        # SIBLING of the merge-on-green process (both direct children of this
        # test script), never an ancestor, so it is FOREIGN under the new
        # ancestry predicate too — worktree_in_use's own /proc scan
        # now catches it independent of whether it names a runner at all, and
        # the prune is correctly BLOCKED.
        #
        # The holder must be a REAL binary, not another bash script: a script
        # with a shebang is exec'd through its interpreter, so the kernel rewrites
        # argv[0] to `bash` and the case would pass for the wrong reason. A copy
        # of `tail` named `vim` gives a genuine non-shell argv[0] while its
        # argument carries the runner token the detector matches on.
        TAIL_BIN=$(command -v tail 2>/dev/null || true)
        if [ -z "$TAIL_BIN" ]; then
            echo "  SKIP: no tail on PATH — 11k9 needs a real non-shell binary as its holder"
        else
            read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
            cp "$TAIL_BIN" "$SUITE_HOLDER_DIR/vim"
            chmod +x "$SUITE_HOLDER_DIR/vim"
            HOLDER_READY="$SUITE_HOLDER_DIR/unused-11k9"
            bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$P_WT" \
                "$SUITE_HOLDER_DIR/vim" -f "$SUITE_HOLDER_DIR/run-shell-tests.sh" &
            HOLDER_PID=$!
            # Readiness is read from the process table itself rather than from a
            # marker file: it is the exact state the detector inspects, so a pass
            # here cannot mean "the holder had not started yet".
            tries=0
            holder_cwd=""
            holder_cmd=""
            while [ "$tries" -lt 100 ]; do
                holder_cmd=$(tr '\0' ' ' < "/proc/$HOLDER_PID/cmdline" 2>/dev/null || printf '')
                holder_cwd=$(readlink -f "/proc/$HOLDER_PID/cwd" 2>/dev/null || printf '')
                case "$holder_cmd" in
                    *run-shell-tests.sh*) [ -n "$holder_cwd" ] && break ;;
                esac
                sleep 0.1
                tries=$((tries + 1))
            done
            case "$holder_cmd" in
                *run-shell-tests.sh*) holder_named=1 ;;
                *) holder_named=0 ;;
            esac
            if [ "$holder_named" -ne 1 ] || [ "$holder_cwd" != "$(cd "$P_WT" && pwd -P)" ]; then
                fail "11k9: the editor-shaped holder never reached the state under test (cmd='$holder_cmd' cwd='$holder_cwd')"
            else
                # Both halves of the trap are demonstrably in place: the runner
                # token IS in this process's argv, and its cwd IS the worktree.
                # Only argv[0] differs from a real runner.
                pass
                MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                    run_mog 0 "merged + a FOREIGN process NAMING a runner -> kept, exit 0"
                assert_audit_has "11k9: a foreign holder blocks the prune regardless of naming a runner" "prune=in-use-confirmed"
                if [ -d "$P_WT" ]; then pass; else fail "11k9: worktree was pruned despite a foreign holder cwd'd inside it"; fi
                case "$LAST_ERR" in
                    *"Process $HOLDER_PID has its working directory"*) pass ;;
                    *) fail "11k9: the WARN does not name the holding pid $HOLDER_PID (got: ${LAST_ERR:-<none>})" ;;
                esac
            fi
            stop_suite_holder
        fi

        # 11k14. POSITIVE: a holder that IS the caller's own
        # ANCESTRY -> the prune PROCEEDS. This is the row that keeps
        # auto-prune alive and the whole reason ancestry, not a bare
        # self-cwd exclusion, is the predicate: merge-on-green's own armed
        # chain worker sits in the tree it just merged, and that worker is this
        # process's own ANCESTOR, not itself. A REAL process, not a
        # simulated flag: an outer process cd's into the merged worktree and
        # stays alive (blocked on `wait`) while merge-on-green runs as its
        # CHILD with ITS OWN cwd elsewhere -- the ancestry walk must find the
        # holder via PPid, not via merge-on-green's own cwd (which would
        # instead trip the EARLIER own-cwd-deferred guard, a different code
        # path this row is not testing).
        read -r OA_REPO OA_WT OA_SHA <<< "$(mk_prune_fixture)"
        oa_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-2602-oa.XXXXXX")
        if [ -z "$oa_tmp" ] || [ ! -d "$oa_tmp" ]; then
            fail "11k14 setup: mktemp -d produced no run sandbox — refusing to build fixture paths on an empty root"
        else
            oa_gh="$oa_tmp/gh.log"; : > "$oa_gh"
            oa_clear="$oa_tmp/clear.log"; : > "$oa_clear"
            oa_audit="$oa_tmp/audit.log"
            mog_build_fixture "$oa_tmp"
            GH_LOG="$oa_gh" CLEAR_LOG="$oa_clear" MERGE_ON_GREEN_LOG="$oa_audit" PATH="$oa_tmp/bin:$PATH" \
                  MERGE_ON_GREEN_SLEEP_CMD=: CR_APP="" STUB_SHA="$OA_SHA" STUB_HEAD_BRANCH="feat/mog-prune" ARMAUTOMERGE=1 \
                  HIMMEL_REPO="$oa_tmp" \
                  run_mog_as_descendant "$OA_WT" "$OA_REPO" "$oa_tmp/scripts/handover/merge-on-green.sh" \
                  >/dev/null 2>"$oa_tmp/err"
            oa_rc=$?
            LAST_GH_LOG="$oa_gh"; LAST_AUDIT="$oa_audit"; LAST_CLEAR_LOG="$oa_clear"; LAST_ERR=$(cat "$oa_tmp/err" 2>/dev/null)
            if [ "$oa_rc" -eq 0 ]; then
                pass "11k14: merge-on-green exits 0 with an ANCESTOR holding the tree"
            else
                fail "11k14: expected exit 0, got $oa_rc (err: ${LAST_ERR:-<none>})"
            fi
            assert_audit_has "11k14: the prune proceeds when the holder is the caller's own ancestry" "prune=removed branch=deleted"
            if [ -d "$OA_WT" ]; then fail "11k14: worktree survived despite the holder being the caller's own ancestor"; else pass; fi
            rm -rf "$oa_tmp"
        fi

        # RC-1 —
        # 11k14's own claim ("a holder in mog's own ancestry does not block
        # the prune") is not expressible through red-control.sh's existing
        # red_control_run/_assert pair: their single --cwd becomes BOTH the
        # ancestor's AND (via env's exec-in-place) mog's own eventual cwd,
        # and mog's OWN cwd being the tree trips the EARLIER own-cwd-deferred
        # guard before ever reaching worktree_in_use at all -- exactly the
        # shape 11k14 exists to avoid. This control builds the SAME evidence
        # red_control_run/_assert would (ran, produced a value, that value is
        # the SPECIFIC wrong one predicted, not merely different from
        # correct) by hand, using run_mog_as_descendant's real ancestor-fork
        # shape instead.
        #
        # Mutant target: scripts/lib/worktree-inuse.sh's own ancestry
        # EXCLUSION CHECK -- NOT merge-on-green.sh's 2517 guard. That
        # guard's own mutant (this RC-1's ORIGINAL target) no longer isolates
        # anything now: worktree_in_use's own /proc scan now
        # independently catches the exact case that guard's absence used to
        # expose (measured: the old mutant produced prune=in-use-confirmed
        # wt=present, not the predicted prune=removed wt=absent -- reported
        # rather than papered over, per the ruling on this ticket). Neutralise
        # with a `case "" in` swap-in, the same minimal-single-line-diff
        # discipline the original mutant used (`false &&`).
        # shellcheck disable=SC2016  # literal match/replacement against
        # worktree-inuse.sh's own source text (unexpanded $inuse_ancestry) --
        # not a shell expansion.
        rc1_check_line='                    case "$inuse_ancestry" in'
        rc1_neutered_check='                    case "" in'
        rc1_mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/mog-2602-rc1-mutant.XXXXXX")
        if [ -z "$rc1_mutant_dir" ] || [ ! -d "$rc1_mutant_dir" ]; then
            fail "RC-1 setup: mktemp -d produced no mutant-build sandbox — refusing to build fixture paths on an empty root"
        else
            rc1_wt_inuse_mutant="$rc1_mutant_dir/worktree-inuse.mutant.sh"
            awk -v line="$rc1_check_line" -v repl="$rc1_neutered_check" \
                '$0==line{print repl; next}{print}' "$SCRIPT_DIR/../lib/worktree-inuse.sh" > "$rc1_wt_inuse_mutant"
            rc1_pre=$(grep -Fc -- "$rc1_check_line" "$SCRIPT_DIR/../lib/worktree-inuse.sh")
            rc1_post=$(grep -Fc -- "$rc1_check_line" "$rc1_wt_inuse_mutant")
            rc1_diff=$(diff "$SCRIPT_DIR/../lib/worktree-inuse.sh" "$rc1_wt_inuse_mutant" | grep -c '^[<>]')
            if [ "$rc1_pre" -eq 1 ] && [ "$rc1_post" -eq 0 ] && [ "$rc1_diff" -eq 2 ]; then
                # --- Row 1: the OWN-ANCESTRY fixture (11k14's shape) under
                # the mutant -> must FLIP to the predicted wrong value.
                read -r RC1A_REPO RC1A_WT RC1A_SHA <<< "$(mk_prune_fixture)"
                rc1a_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-2602-rc1a.XXXXXX")
                if [ -z "$rc1a_tmp" ] || [ ! -d "$rc1a_tmp" ]; then
                    fail "RC-1 row-1 setup: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
                else
                    rc1a_gh="$rc1a_tmp/gh.log"; : > "$rc1a_gh"
                    rc1a_clear="$rc1a_tmp/clear.log"; : > "$rc1a_clear"
                    rc1a_audit="$rc1a_tmp/audit.log"
                    WT_INUSE_SRC="$rc1_wt_inuse_mutant" mog_build_fixture "$rc1a_tmp"
                    GH_LOG="$rc1a_gh" CLEAR_LOG="$rc1a_clear" MERGE_ON_GREEN_LOG="$rc1a_audit" PATH="$rc1a_tmp/bin:$PATH" \
                          MERGE_ON_GREEN_SLEEP_CMD=: CR_APP="" STUB_SHA="$RC1A_SHA" STUB_HEAD_BRANCH="feat/mog-prune" ARMAUTOMERGE=1 \
                          HIMMEL_REPO="$rc1a_tmp" \
                          run_mog_as_descendant "$RC1A_WT" "$RC1A_REPO" "$rc1a_tmp/scripts/handover/merge-on-green.sh" \
                          >/dev/null 2>"$rc1a_tmp/err"
                    rc1a_rc=$?
                    rc1a_prune=$(grep -o 'prune=[^ ]*' "$rc1a_audit" 2>/dev/null | head -n1)
                    rc1a_wt=absent; [ -d "$RC1A_WT" ] && rc1a_wt=present
                    rc1a_observed="$rc1a_prune wt=$rc1a_wt"
                    if [ "$rc1a_rc" -ne 0 ]; then
                        fail "RC-1 row-1 (own-ancestry): the mutant CRASHED (rc=$rc1a_rc, expected 0) -- proves nothing (err: $(cat "$rc1a_tmp/err" 2>/dev/null))"
                    elif [ -z "$rc1a_prune" ]; then
                        fail "RC-1 row-1 (own-ancestry): the mutant produced no prune= token -- proves nothing"
                    elif [ "$rc1a_observed" = "prune=in-use-confirmed wt=present" ]; then
                        pass "RC-1 row-1 (own-ancestry) RED confirmed: with the ancestry exclusion disabled the caller's own ancestor is wrongly treated as a foreign holder ($rc1a_observed; the real script produces prune=removed wt=absent) -- 11k14's exclusion is load-bearing, not vacuously true"
                    elif [ "$rc1a_observed" = "prune=removed wt=absent" ]; then
                        fail "RC-1 row-1 (own-ancestry): the mutant reproduced the CORRECT value ($rc1a_observed) -- this mutation is not exercising the ancestry exclusion at all"
                    else
                        fail "RC-1 row-1 (own-ancestry): the mutant produced an UNPREDICTED value ($rc1a_observed) -- neither the correct nor the predicted-wrong outcome"
                    fi
                    rm -rf "$rc1a_tmp"
                fi

                # --- Row 2: the FOREIGN-holder fixture (11k7's shape) under
                # the SAME mutant -> must NOT flip -- proves the mutation is
                # isolated to the ancestry exclusion and does not touch
                # foreign-holder detection at all.
                read -r RC1B_REPO RC1B_WT RC1B_SHA <<< "$(mk_prune_fixture)"
                if ! start_suite_holder "$RC1B_WT" "$SUITE_HOLDER_DIR/sleeper.sh"; then
                    fail "RC-1 row-2 setup: the sleeper never signaled ready — control not established"
                else
                    pass  # holder reached execution: the control below is against a real process
                    WT_INUSE_SRC="$rc1_wt_inuse_mutant" MOG_CWD="$RC1B_REPO" STUB_SHA="$RC1B_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                        run_mog 0 "RC-1 row-2 (foreign holder) under the ancestry-exclusion mutant -> still kept, exit 0"
                    if grep -qF "prune=in-use-confirmed" "$LAST_AUDIT" 2>/dev/null; then
                        pass "RC-1 row-2 (foreign holder): the mutation does NOT flip a foreign holder's outcome -- isolated to the ancestry exclusion"
                    else
                        fail "RC-1 row-2 (foreign holder): expected prune=in-use-confirmed (unchanged from the real script) but got a different outcome -- the mutation is not isolated to the ancestry exclusion (audit: $(cat "$LAST_AUDIT" 2>/dev/null))"
                    fi
                fi
                stop_suite_holder
            else
                fail "RC-1 setup: mutation of the ancestry-exclusion check was not reproduced cleanly (pre=$rc1_pre post=$rc1_post diff_lines=$rc1_diff)"
            fi
            rm -rf "$rc1_mutant_dir"
        fi

        rm -rf "$SUITE_HOLDER_DIR"
        ;;
    *)
        echo "  SKIP: not Linux — the live-suite-run detector reads /proc/<pid>/cwd, which exists nowhere else"
        ;;
esac

# 11k3. A remove that fails PART-WAY (git-for-Windows deletes contents +
# deregisters the admin entry, then fails the final rmdir) is reported as
# `gutted`, never as "left in place". The gutted shape is only reachable
# through a real race otherwise (11k2 above), so this drives it deterministically
# via a `git` shim on PATH for this one run: it passes every argument through
# to the REAL git EXCEPT the exact `worktree remove <fixture-worktree>`
# invocation, where it reproduces the MEASURED git-for-Windows wreck rather
# than invented behaviour — see the repro table in
# prune_merged_worktree's comment. A test-only seam in production code is not
# acceptable here; a PATH shim is.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
REAL_GIT=$(command -v git)
P_REPO_NORM=$(cd "$P_REPO" && pwd -P)
P_WT_NORM=$(cd "$P_WT" && pwd -P)
shimdir=$(mktemp -d "${TMPDIR:-/tmp}/mog-gitshim.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
cat > "$shimdir/git" <<GITSHIM
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
P_REPO_NORM="$P_REPO_NORM"
P_WT_NORM="$P_WT_NORM"
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "remove" ]; then
    c2=\$(cd "\$2" 2>/dev/null && pwd -P) || c2="\$2"
    c5=\$(cd "\$5" 2>/dev/null && pwd -P) || c5="\$5"
    if [ "\$c2" = "\$P_REPO_NORM" ] && [ "\$c5" = "\$P_WT_NORM" ]; then
        # Reproduce the MEASURED wreck: contents + .git gone,
        # admin row pruned away, empty directory left, non-zero exit.
        rm -rf "\$P_WT_NORM"
        "\$REAL_GIT" -C "\$P_REPO_NORM" worktree prune >/dev/null 2>&1
        mkdir -p "\$P_WT_NORM"
        exit 1
    fi
fi
exec "\$REAL_GIT" "\$@"
GITSHIM
chmod +x "$shimdir/git"
PATH="$shimdir:$PATH" MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged but remove fails partway -> reported gutted, exit 0"
assert_audit_has "11k3: audit records the gutted outcome" "prune=gutted"
assert_err_has "11k3: operator message says FAILED PARTWAY" "FAILED PARTWAY"
assert_err_has "11k3: operator message says GUTTED" "GUTTED"
if prune_branch_gone "$P_REPO"; then fail "11k3: branch deleted despite a gutted (unverified) tree"; else pass; fi

# --- 11L..11o. CR-marker clear on the merge path ----------------
# A merge used to leave the branch's cr-pending marker behind; the marker lives
# in the SHARED git-common-dir while the pr-create guard resolves the branch
# from the session cwd, so it then blocked `gh pr create` on UNRELATED branches.
# The merge path must clear it THROUGH clear-review-marker.sh (never a raw rm, which
# is the self-declare-clean pattern the clearer exists to stop) and record the
# outcome on the MERGED audit line. Same prune fixture — a real throwaway repo.

# 11L. Marker present + confirmed merge → cleared through the chokepoint, with
# the branch it certifies, and the MERGED line carries marker=cleared.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "marker present → cleared via clear-review-marker.sh, exit 0"
assert_clear_has "11L: the chokepoint was invoked for the merged branch" "feat/mog-prune"
assert_audit_has "11L: audit records the marker outcome" "marker=cleared"
# The clear must run BEFORE the merge, the one thing that keeps this feature
# from silently rotting: afterwards deleteBranchOnMerge has removed the remote
# head branch and the chokepoint refuses (16) for EVERY merged branch, so a
# post-merge clear would pass its tests while never clearing anything in
# production. Ordered via the gh log, which the stub clearer also writes to.
clear_ln=$(grep -n '^clear-cr-marker ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
merge_ln=$(grep -n '^pr merge ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
if [ -n "$clear_ln" ] && [ -n "$merge_ln" ] && [ "$clear_ln" -lt "$merge_ln" ]; then
    pass
else
    fail "11L: the marker clear must precede the merge (clear@${clear_ln:-none} merge@${merge_ln:-none})"
fi
# 11L-wt. The run starts in the PRIMARY (on main) while the branch
# lives in its own worktree. clear-review-marker.sh refuses a branch other than the
# one checked out in its cwd (exit 12), so the clear must run from P_WT.
# Resolved through the parent: the post-merge prune has removed P_WT itself.
wt_real="$(cd "$(dirname "$P_WT")" && pwd -P)/$(basename "$P_WT")"
if [ "$(cat "$LAST_CLEAR_LOG.cwd" 2>/dev/null)" = "$wt_real" ]; then
    pass
else
    fail "11L-wt: the clearer must run in the branch's worktree ($wt_real), ran in: $(cat "$LAST_CLEAR_LOG.cwd" 2>/dev/null || echo none)"
fi

# 11L-q. Same hazard as 11h-q, but on clear_cr_marker_for_branch's
# parse. A worktree path with a newline must still resolve to a `wt` match so
# the clearer runs (never a spurious marker=no-worktree). RED before the -z
# fix.
mk_prune_fixture_quoted; P_REPO="$QP_REPO"; P_WT="$QP_WT"; P_SHA="$QP_SHA"
mk_marker "$P_REPO" "feat/mog-prune-q"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune-q" \
    run_mog 0 "11L-q: quoted worktree path -> marker still cleared via clear-review-marker.sh"
assert_clear_has "11L-q: the chokepoint was invoked for the merged branch" "feat/mog-prune-q"
assert_audit_has "11L-q: audit records the marker outcome" "marker=cleared"

# 11m. The chokepoint REFUSES (14 = no responders at that sha) → the merge
# verdict and exit are unchanged (it already landed), and the failure is
# RECORDED rather than swallowed.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_CLEAR_RC=14 \
    run_mog 0 "marker clear refused → merge still exit 0"
assert_audit_has "11m: audit records the clear failure" "marker=clear-rc=14"
assert_audit_has "11m: the merge is still recorded as MERGED" "MERGED repo="

# 11n. No marker → the chokepoint is not invoked at all (its gates include a
# second check-ci watch, paid for nothing), and the line says so.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "no marker → nothing to clear, exit 0"
assert_clear_not_invoked "11n: no marker means no chokepoint call"
assert_audit_has "11n: audit records the absent marker" "marker=absent"

# 11o. --dry-run changes nothing: clearing is a real mutation, so the marker
# must survive a dry run untouched.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "dry-run does not clear the marker" -- --dry-run
assert_clear_not_invoked "11o: dry-run leaves the chokepoint uninvoked"
if [ -f "$P_REPO/.git/cr-pending/feat/mog-prune" ]; then pass; else fail "11o: dry-run removed the marker file"; fi

# 11o-nowt. The branch is checked out in NO worktree, so the clearer
# (which would refuse from any cwd) is not run; the line says no-worktree and
# stderr names the fix. The merge itself is unaffected.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
git -C "$P_REPO" worktree remove --force "$P_WT" >/dev/null 2>&1
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "marker present, branch in no worktree: merge still exit 0"
assert_clear_not_invoked "11o-nowt: no worktree means no chokepoint call"
assert_audit_has "11o-nowt: audit records no-worktree" "marker=no-worktree"
case "$LAST_ERR" in
    *"from the worktree where feat/mog-prune is checked out"*) pass ;;
    *) fail "11o-nowt: stderr must name the fix, got: $LAST_ERR" ;;
esac

# --- 11p..11q. after-report pending marker -----------------------
# Red-first: no SUMMARY comment on the PR yet at merge time -> a local marker
# file is written (same dir shape as cr-pending) and the audit line says so.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NUM=77 \
    run_mog 0 "11p: no after-report SUMMARY yet -> pending marker written"
if [ -f "$P_REPO/.git/after-report-pending/feat/mog-prune" ]; then
    pass
else
    fail "11p: after-report-pending marker file was not written"
fi
assert_audit_has "11p: audit records the pending after-report" "after-report=pending"

# 11q. A SUMMARY comment already exists at merge time (STUB_AFTER_REPORT_SUMMARIES=1)
# -> no marker written (and a stale one from a prior run is cleared), audit
# says 'posted'.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mkdir -p "$P_REPO/.git/after-report-pending/feat"
printf 'stale\n' > "$P_REPO/.git/after-report-pending/feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NUM=77 \
    STUB_AFTER_REPORT_SUMMARIES=1 run_mog 0 "11q: after-report already posted -> no pending marker"
if [ -f "$P_REPO/.git/after-report-pending/feat/mog-prune" ]; then
    fail "11q: a stale after-report-pending marker was not cleared"
else
    pass
fi
assert_audit_has "11q: audit records the posted after-report" "after-report=posted"

# 11q2. A gh stderr notice after the PR read leaves the head branch name intact.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NUM=77 STUB_GH_HINT=1 \
    run_mog 0 "11q2: a gh notice on stderr after the PR read -> merged, exit 0"
assert_audit_has "11q2: the head branch was pruned" "prune=removed branch=deleted"
assert_audit_lacks "11q2: the prune did not look for a mangled branch" "prune=not-found"
if prune_branch_gone "$P_REPO"; then pass; else fail "11q2: the merged head branch was not deleted"; fi
if [ -f "$P_REPO/.git/after-report-pending/feat/mog-prune" ]; then
    pass
else
    fail "11q2: after-report-pending marker was not written at the head branch's name"
fi
assert_audit_has "11q2: audit records the pending after-report" "after-report=pending cr="
assert_audit_lacks "11q2: the marker write did not fail" "pending-unrecorded"
assert_audit_lacks "11q2: no gh notice text in the audit" "hint:"

# 11q3. A real PR-read failure is still caught when gh's stderr is only a notice (exit 1, no
# "no pull requests found"): refused, never merged.
STUB_STATE_FAIL=hint-only STUB_GH_HINT=1 run_mog 13 "11q3: gh exits 1 with only a hint on stderr -> exit 13, not a no-op"
assert_audit_has "11q3: the failed read is a refusal" "REFUSED reason=pr-query-failed"
assert_gh_lacks "11q3: no merge attempted" "pr merge"
assert_err_has "11q3: the refusal carries gh's stderr" "gh event listen"

# 11q4. 'no pull requests found' followed by a hint is still the clean no-op.
STUB_NO_PR=1 STUB_GH_HINT=1 run_mog 0 "11q4: no PR plus a gh notice -> exit 0 nothing-to-merge"
assert_audit_has "11q4: audited as a no-op" "NOOP reason=no-open-pr"
assert_gh_lacks "11q4: no merge attempted" "pr merge"

# --- 11r..11t. CR thread recorder after a confirmed merge ---------------------
# The recorder runs once, with the PR number and repo, after the merge lands. The
# fixture is a git repo so the anchor's ledger resolves.
MOG_ANCHOR_GIT=1 STUB_NUM=77 run_mog 0 "11r: a confirmed merge records the PR's CR threads"
assert_recorder_has "11r: the recorder gets the PR number and --repo" "77 --repo "
assert_audit_has "11r: audit records the recorder result" "cr-threads=ok"
# The caller's gh seam, ledger and wait settings never reach the recorder; the
# ledger is the anchor's and the recorder never sleeps inside the gate.
GH_CMD=evil-gh CR_LEDGER=/nonexistent/ledger.jsonl CR_RECORDER_SLEEP_CMD=evil-sleep CR_RECORDER_MAX_WAIT=999 \
    CR_RECORDER_GH_TOKENS=evil-token CR_RECORDER_FLOOR=1 CR_RECORDER_LIST_CAP=1 CR_RECORDER_REPO=evil/repo \
    MOG_ANCHOR_GIT=1 STUB_NUM=77 run_mog 0 "11s: the recorder runs with the gate's own env, not the caller's"
if grep -qE '^GH_CMD=unset LEDGER=.+/\.git/cr-critic-scores\.jsonl WAIT=0 SLEEP=unset TOKENS=unset FLOOR=unset CAP=unset REPO=unset$' "$LAST_TMP/recorder.env" 2>/dev/null; then
    pass
else
    fail "11s: recorder env was not scrubbed (got: $(cat "$LAST_TMP/recorder.env" 2>/dev/null))"
fi
# A failing recorder never fails the merge; the audit says so.
MOG_ANCHOR_GIT=1 STUB_NUM=77 STUB_RECORDER_RC=3 run_mog 0 "11t: a failing recorder never fails the merge"
assert_audit_has "11t: audit records the failed recorder" "cr-threads=failed"
assert_audit_has "11t: the merge is still recorded as MERGED" "MERGED repo="
# A hung recorder is cut off at the bound: the merge still exits 0, in time.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    mog_t0=$SECONDS
    MOG_ANCHOR_GIT=1 STUB_NUM=77 STUB_RECORDER_SLEEP=40 MOG_CR_THREADS_SECS=2 run_mog 0 "11u: a hung recorder cannot hold the merge"
    if [ $((SECONDS - mog_t0)) -lt 30 ]; then pass; else fail "11u: the merge waited $((SECONDS - mog_t0))s on a hung recorder"; fi
    assert_audit_has "11u: a timed-out recorder reads as failed" "cr-threads=failed"
else
    echo "SKIP 11u: this host has neither timeout nor gtimeout, so the hung-recorder bound cannot be exercised"
fi
# With no timeout binary the recorder is not run at all. The base PATH is a
# symlink farm of the real PATH minus timeout and gtimeout.
mog_nt_farm=$(mktemp -d "${TMPDIR:-/tmp}/mog-nt.XXXXXX") || mog_nt_farm=""
if [ -z "$mog_nt_farm" ] || [ ! -d "$mog_nt_farm" ]; then
    fail "11y: setup: no scratch dir for the no-timeout PATH"
else
    IFS=: read -r -a mog_nt_path <<< "$PATH"
    # Forward order and no -f, so the earliest PATH entry wins a name clash (and no
    # array is built: an empty one trips set -u on bash 3.2).
    for mog_nt_d in "${mog_nt_path[@]}"; do
        case "$mog_nt_d" in /*) [ -d "$mog_nt_d" ] && { ln -s "$mog_nt_d"/* "$mog_nt_farm"/ 2>/dev/null || true; } ;; esac
    done
    rm -f "$mog_nt_farm/timeout" "$mog_nt_farm/gtimeout"
    MOG_PATH_BASE="$mog_nt_farm" MOG_ANCHOR_GIT=1 STUB_NUM=77 run_mog 0 "11y: no timeout binary never fails the merge"
    assert_audit_has "11y: audit records the missing timeout" "cr-threads=no-timeout"
    assert_recorder_not_called "11y: no timeout binary, no recorder call"
    rm -rf "$mog_nt_farm"
fi
# No recorder script at the anchor, or no resolvable ledger: nothing runs.
MOG_NO_RECORDER=1 MOG_ANCHOR_GIT=1 STUB_NUM=77 run_mog 0 "11v: a missing recorder never fails the merge"
assert_audit_has "11v: audit records the missing recorder" "cr-threads=no-recorder"
STUB_NUM=77 run_mog 0 "11w: an anchor with no git ledger runs no recorder"
assert_audit_has "11w: audit records the missing ledger" "cr-threads=no-ledger"
assert_recorder_not_called "11w: no ledger, no recorder call"
# No merge, no recorder.
run_mog 0 "11x: a dry run records no threads" -- --dry-run
assert_recorder_not_called "11x: dry-run never calls the recorder"

# --- 11z. the bug-origin ledger row, written when a fix PR merges -----------------------
# After a confirmed merge the anchor's bug-origin-report.py ingests the merged PR (one snapshot, no Jira call) into the
# ledger root the shell tooling resolves. A failed write warns and never fails the merge. Every row runs on its own
# temp HANDOVER_DIR; the real ledger is never named. The bucket is the cwd's name, so a pair of runs that must meet share MOG_CWD.
bo_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-bo.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
bo_row() { local f; for f in "$bo_root"/zed/*/bug-origin/"$1".md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; return 0; }
bo_line=$'bug-origin: #10 test-gap \xe2\x80\x94 the first reason\nRemaining: the next slice'
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    mkdir -p "$bo_root/cwd"
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" MOG_CWD="$bo_root/cwd" STUB_NUM=77 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-a: a merged PR with a bug-origin line merges"
    bo_file=$(bo_row 77)
    if [ -n "$bo_file" ] && grep -qF 'PR #77 bug-origin: #10 test-gap' "$bo_file" 2>/dev/null; then pass; else fail "11z-a: no ledger row for PR 77 under $bo_root"; fi
    assert_audit_has "11z-a: audit records the written row" "bug-origin=wrote"
    assert_gh_has "11z-a: the snapshot is one pinned pr view of the merged PR" "pr view 77 --repo owner/repo --json number,title,body,mergedAt,headRefName,headRefOid,mergeCommit"
    bo_sum=$(cksum < "$bo_file")
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" MOG_CWD="$bo_root/cwd" STUB_NUM=77 \
        STUB_PR_BODY=$'bug-origin: #11 design-gap \xe2\x80\x94 a later reason\nRemaining: x' run_mog 0 "11z-b: a second merge run of the same PR"
    if [ "$(cksum < "$bo_file")" = "$bo_sum" ]; then pass; else fail "11z-b: the first row changed"; fi
    assert_audit_has "11z-b: audit records the kept row" "bug-origin=kept"
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=78 run_mog 0 "11z-c: a merged PR without the line merges"
    if [ -z "$(bo_row 78)" ]; then pass; else fail "11z-c: a PR with no bug-origin line got a row"; fi
    assert_audit_has "11z-c: audit records that there was nothing to write" "bug-origin=none"
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=79 STUB_MERGE_FAIL=1 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-d: a merge gh reported as failed but found MERGED"
    if [ -n "$(bo_row 79)" ]; then pass; else fail "11z-d: the recovery path wrote no row"; fi
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=80 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-e: a dry run writes no row" -- --dry-run
    if [ -z "$(bo_row 80)" ]; then pass; else fail "11z-e: a dry run wrote a row"; fi
    assert_gh_lacks "11z-e: a dry run takes no snapshot" "mergedAt"
    # a write that fails warns and leaves the merge alone
    bo_bad=$(mktemp -d "${TMPDIR:-/tmp}/mog-bo-bad.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
    : > "$bo_bad/zed"
    HANDOVER_DIR="$bo_bad" USER_SLUG=zed HANDOVER_REGISTRY="$bo_bad/none.json" STUB_NUM=81 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-f: a ledger that cannot be written never fails the merge"
    assert_audit_has "11z-f: audit records the failed write" "bug-origin=failed"
    assert_audit_has "11z-f: the merge is still recorded as MERGED" "MERGED repo="
    case "$LAST_ERR" in *"WARN bug-origin"*) pass ;; *) fail "11z-f: no WARN naming the failed write, got: $LAST_ERR" ;; esac
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=82 STUB_SNAPSHOT_FAIL=1 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-g: a snapshot gh cannot read never fails the merge"
    assert_audit_has "11z-g: audit records the failed snapshot" "bug-origin=failed"
    if [ -z "$(bo_row 82)" ]; then pass; else fail "11z-g: a row appeared without a snapshot"; fi
    # no ledger root anywhere: warn, never fail
    HANDOVER_DIR="$bo_root/not-a-dir" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=83 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-h: a ledger root that is no directory never fails the merge"
    assert_audit_has "11z-h: audit records the refused ingest" "bug-origin=failed"
    rm -rf "$bo_bad"
    # a hung snapshot read or a hung ingest is cut off at its bound: the merge exits 0, in time, and the audit says failed
    mog_t0=$SECONDS
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=84 STUB_SNAPSHOT_HANG=1 MOG_BUG_ORIGIN_SECS=2 \
        STUB_PR_BODY="$bo_line" run_mog 0 "11z-i: a hung snapshot read cannot hold the merge"
    if [ $((SECONDS - mog_t0)) -lt 30 ]; then pass; else fail "11z-i: the merge waited $((SECONDS - mog_t0))s on a hung gh"; fi
    assert_audit_has "11z-i: a timed-out snapshot reads as failed" "bug-origin=failed"
    mog_t0=$SECONDS
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=85 MOG_BO_REPORT=hang MOG_BUG_ORIGIN_SECS=2 \
        STUB_PR_BODY="$bo_line" run_mog 0 "11z-j: a hung ingest cannot hold the merge"
    if [ $((SECONDS - mog_t0)) -lt 30 ]; then pass; else fail "11z-j: the merge waited $((SECONDS - mog_t0))s on a hung ingest"; fi
    assert_audit_has "11z-j: a timed-out ingest reads as failed" "bug-origin=failed"
    # MOG_BUG_ORIGIN_SECS can only shorten the bounds (30 s for gh, 60 s for the ingest): a zero in any spelling, a value too
    # long to compare, and a value above a bound change nothing; the log of the shimmed `timeout` shows what each call got
    bo_secs_row() {
        MOG_TIMEOUT_SHIM=1 MOG_BUG_ORIGIN_SECS="$1" STUB_NUM=89 run_mog 0 "11z-n: MOG_BUG_ORIGIN_SECS=$1 bounds gh at $2 s and the ingest at $3 s"
        if grep -q "^-k 5 $2 " "$LAST_TMP/timeout.log" 2>/dev/null && grep -q "^-k 10 $3 " "$LAST_TMP/timeout.log" 2>/dev/null; then pass
        else fail "11z-n: MOG_BUG_ORIGIN_SECS=$1 wanted gh $2 s and ingest $3 s, got: $(cat "$LAST_TMP/timeout.log" 2>/dev/null | cut -c1-40 | tr '\n' ';')"; fi
    }
    bo_secs_row 00 30 60
    bo_secs_row 0 30 60
    bo_secs_row 99999999999999999999 30 60
    bo_secs_row 045 30 60
    bo_secs_row 100 30 60
    bo_secs_row 45 30 45
    bo_secs_row 7 7 7
    bo_secs_row "" 30 60
    # MOG_CR_THREADS_SECS can only shorten the 60 s bound of the cr-thread recorder: a zero in any spelling (a zero duration
    # turns `timeout` off), a value too long to compare and a value of 3 digits change nothing
    cr_secs_row() {
        MOG_ANCHOR_GIT=1 MOG_TIMEOUT_SHIM=1 MOG_CR_THREADS_SECS="$1" STUB_NUM=89 run_mog 0 "8948-$3: MOG_CR_THREADS_SECS=$1 bounds the recorder at $2 s"
        if grep -q "^-k 10 $2 " "$LAST_TMP/cr-timeout.log" 2>/dev/null; then pass
        else fail "8948-$3: MOG_CR_THREADS_SECS=$1 wanted the recorder bound $2 s, got: $(cut -c1-40 "$LAST_TMP/cr-timeout.log" 2>/dev/null | tr '\n' ';')"; fi
    }
    cr_secs_row 00 60 00
    cr_secs_row 99999999999999999999 60 20d
    cr_secs_row 045 60 045
    cr_secs_row 100 60 100
    cr_secs_row 45 45 45
    cr_secs_row 7 7 7
    # no timeout binary: the ingest is not run (a symlink farm of the real PATH minus timeout and gtimeout)
    mog_nt_farm=$(mktemp -d "${TMPDIR:-/tmp}/mog-nt.XXXXXX") || mog_nt_farm=""
    if [ -z "$mog_nt_farm" ] || [ ! -d "$mog_nt_farm" ]; then
        fail "11z-k: setup: no scratch dir for the no-timeout PATH"
    else
        IFS=: read -r -a mog_nt_path <<< "$PATH"
        for mog_nt_d in "${mog_nt_path[@]}"; do
            case "$mog_nt_d" in /*) [ -d "$mog_nt_d" ] && { ln -s "$mog_nt_d"/* "$mog_nt_farm"/ 2>/dev/null || true; } ;; esac
        done
        rm -f "$mog_nt_farm/timeout" "$mog_nt_farm/gtimeout"
        HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" MOG_PATH_BASE="$mog_nt_farm" STUB_NUM=86 \
            STUB_PR_BODY="$bo_line" run_mog 0 "11z-k: no timeout binary never fails the merge"
        assert_audit_has "11z-k: audit records the missing timeout" "bug-origin=no-timeout"
        if [ -z "$(bo_row 86)" ]; then pass; else fail "11z-k: a row was written with no timeout binary"; fi
        rm -rf "$mog_nt_farm"
    fi
    # no reporter at the anchor: nothing runs
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" MOG_BO_REPORT=none STUB_NUM=87 STUB_PR_BODY="$bo_line" \
        run_mog 0 "11z-l: a missing reporter never fails the merge"
    assert_audit_has "11z-l: audit records the missing reporter" "bug-origin=no-report"
    assert_gh_lacks "11z-l: no reporter, no snapshot" "mergedAt"
    # a bug-origin line the reporter cannot read is no silent none: the audit says unparsed and a WARN names the PR
    HANDOVER_DIR="$bo_root" USER_SLUG=zed HANDOVER_REGISTRY="$bo_root/none.json" STUB_NUM=88 \
        STUB_PR_BODY=$'bug-origin: #10 no-such-class \xe2\x80\x94 a reason\nRemaining: x' run_mog 0 "11z-m: a malformed bug-origin line never fails the merge"
    assert_audit_has "11z-m: audit records the unparsed line" "bug-origin=unparsed"
    case "$LAST_ERR" in *"WARN bug-origin"*"#88"*) pass ;; *) fail "11z-m: no WARN naming PR 88, got: $LAST_ERR" ;; esac
    if [ -z "$(bo_row 88)" ]; then pass; else fail "11z-m: a malformed line got a row"; fi
else
    echo "SKIP 11z: this host has neither timeout nor gtimeout, so the bounded ingest is not run"
fi
rm -rf "$bo_root"

cf_setup() {
    local a="$1"
    local g="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
    printf 'one\ntwo\n' > "$a/f.sh"
    $g -C "$a" add f.sh && $g -C "$a" commit -qm base && $g -C "$a" branch -M main && $g -C "$a" push -q origin main || return 1
    $g -C "$a" checkout -q -b feat && printf 'feat\ntwo\n' > "$a/f.sh" && $g -C "$a" commit -qam feat || return 1
    $g -C "$a" checkout -q main && printf 'main\ntwo\n' > "$a/f.sh" && $g -C "$a" commit -qam 'x (#12)' || return 1
    $g -C "$a" push -q origin main && $g -C "$a" fetch -q origin || return 1
    $g -C "$a" checkout -q feat && { $g -C "$a" merge -q main >/dev/null 2>&1 || true; }
    printf 'both\ntwo\n' > "$a/f.sh" && $g -C "$a" add f.sh && $g -C "$a" commit -qm 'merge main' || return 1
    MOG_SETUP_SHA="$($g -C "$a" rev-parse HEAD)"
    $g -C "$a" push -q origin HEAD:refs/pull/77/head || return 1
    return 0
}
cf_clean_setup() {
    local a="$1"
    local g="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
    printf 'one\n' > "$a/f.sh"
    $g -C "$a" add f.sh && $g -C "$a" commit -qm base && $g -C "$a" branch -M main && $g -C "$a" push -q origin main && $g -C "$a" fetch -q origin || return 1
    $g -C "$a" checkout -q -b feat && printf 'g\n' > "$a/g.sh" && $g -C "$a" add g.sh && $g -C "$a" commit -qm feat || return 1
    MOG_SETUP_SHA="$($g -C "$a" rev-parse HEAD)"
    return 0
}
cf_body=$'## Conflicts resolved\n- f.sh vs #12: kept both\n\nRemaining: x'
cf_title='fix(x): [HIMMEL-9560] stub'
cf_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-cf.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
cf_row() { local f; for f in "$1"/zed/*/conflicts/"$2".jsonl; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; return 0; }
cf_doc() { printf '# doc\n\n## Results (newest at the bottom)\n- 09:00 LIVE start\n' > "$1"; }
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    mkdir -p "$cf_root/a" "$cf_root/cfg"
    printf 'HANDOVER_DIR=%s\n' "$cf_root/a" > "$cf_root/cfg/himmel.conf.local"
    cf_run() { HANDOVER_DIR="${CF_HD:-$cf_root/a}" USER_SLUG=zed HANDOVER_REGISTRY="$cf_root/none.json" HIMMEL_CONFIG_DIR="$cf_root/cfg" MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP="${CF_SETUP-cf_setup}" STUB_PR_TITLE="$cf_title" run_mog "$@"; }
    cf_doc "$cf_root/doc-a"
    HIMMEL_CONSOLE_DOC="$cf_root/doc-a" STUB_NUM=77 STUB_PR_BODY="$cf_body" cf_run 0 "11za-a: a merged PR with a resolved conflict merges"
    cf_file=$(cf_row "$cf_root/a" 77)
    if [ -n "$cf_file" ] && grep -qF '"file": "f.sh"' "$cf_file" 2>/dev/null; then pass; else fail "11za-a: no ledger row for PR 77 under $cf_root/a"; fi
    assert_audit_has "11za-a: audit records the written row" "conflicts=wrote:1"
    cf_last=$(tail -n 1 "$cf_root/doc-a")
    case "$cf_last" in *'conflicts recorded for PR #77 (HIMMEL-9560): f.sh vs #12 merged'*) pass ;; *) fail "11za-e: the doc's last line is: $cf_last" ;; esac
    mkdir -p "$cf_root/worker"
    CF_HD="$cf_root/worker" STUB_NUM=82 STUB_PR_BODY="$cf_body" cf_run 0 "11za-d: a worker HANDOVER_DIR does not steer the ledger"
    if [ -z "$(cf_row "$cf_root/worker" 82)" ]; then pass; else fail "11za-d: a row landed under the worker's HANDOVER_DIR"; fi
    if [ -n "$(cf_row "$cf_root/a" 82)" ]; then pass; else fail "11za-d: no row under the anchor's root"; fi
    assert_audit_has "11za-d: audit records the written row" "conflicts=wrote:1"
    cf_doc "$cf_root/doc-b"
    HIMMEL_CONSOLE_DOC="$cf_root/doc-b" CF_SETUP=cf_clean_setup STUB_NUM=78 cf_run 0 "11za-b: a merged PR with no conflict merges"
    if [ -z "$(cf_row "$cf_root/a" 78)" ]; then pass; else fail "11za-b: a PR with no conflict got a row"; fi
    assert_audit_has "11za-b: audit records that there was nothing to write" "conflicts=none"
    if [ "$(tail -n 1 "$cf_root/doc-b")" = '- 09:00 LIVE start' ]; then pass; else fail "11za-b: a bullet was added: $(tail -n 1 "$cf_root/doc-b")"; fi
    cf_doc "$cf_root/doc-c"
    HIMMEL_CONSOLE_DOC="$cf_root/doc-c" MOG_CONFLICTS_REPORT=fail STUB_NUM=79 STUB_PR_BODY="$cf_body" cf_run 0 "11za-c: a failing conflicts recorder never fails the merge"
    assert_audit_has "11za-c: audit records the failed recorder" "conflicts=failed"
    assert_audit_has "11za-c: the merge is still recorded as MERGED" "MERGED repo="
    cf_last=$(tail -n 1 "$cf_root/doc-c")
    case "$cf_last" in *'conflicts not recorded for PR #79 (HIMMEL-9560): failed'*) pass ;; *) fail "11za-e: the doc's last line is: $cf_last" ;; esac
    printf '# doc\n' > "$cf_root/doc-f"
    HIMMEL_CONSOLE_DOC="$cf_root/doc-f" STUB_NUM=80 STUB_PR_BODY="$cf_body" cf_run 0 "11za-f: a doc with no Results heading never fails the merge"
    assert_audit_has "11za-f: audit still records the written row" "conflicts=wrote:1"
    MOG_CONFLICTS_REPORT=none STUB_NUM=81 STUB_PR_BODY="$cf_body" cf_run 0 "11za-g: a missing recorder never fails the merge"
    assert_audit_has "11za-g: audit records the missing recorder" "conflicts=no-recorder"
    mog_t0=$SECONDS
    STUB_NUM=83 STUB_PR_BODY="$cf_body" STUB_CF_SNAPSHOT_HANG=1 MOG_CONFLICTS_SECS=2 cf_run 0 "11za-h: a hung conflicts snapshot read cannot hold the merge"
    if [ $((SECONDS - mog_t0)) -lt 30 ]; then pass; else fail "11za-h: the merge waited $((SECONDS - mog_t0))s on a hung gh"; fi
    assert_audit_has "11za-h: a timed-out snapshot reads as failed" "conflicts=failed"
    mog_t0=$SECONDS
    STUB_NUM=84 STUB_PR_BODY="$cf_body" MOG_CONFLICTS_REPORT=hang MOG_CONFLICTS_SECS=2 cf_run 0 "11za-i: a hung conflicts recorder cannot hold the merge"
    if [ $((SECONDS - mog_t0)) -lt 30 ]; then pass; else fail "11za-i: the merge waited $((SECONDS - mog_t0))s on a hung recorder"; fi
    assert_audit_has "11za-i: a timed-out recorder reads as failed" "conflicts=failed"
    cf_secs_row() {
        MOG_TIMEOUT_SHIM=1 MOG_CONFLICTS_SECS="$1" STUB_NUM=85 STUB_PR_BODY="$cf_body" cf_run 0 "11za-j: MOG_CONFLICTS_SECS=$1 bounds gh at $2 s and the recorder at $3 s"
        if grep -q "^-k 5 $2 " "$LAST_TMP/cf-timeout.log" 2>/dev/null && grep -q "^-k 10 $3 " "$LAST_TMP/cf-timeout.log" 2>/dev/null; then pass
        else fail "11za-j: MOG_CONFLICTS_SECS=$1 wanted gh $2 s and record $3 s, got: $(cut -c1-40 "$LAST_TMP/cf-timeout.log" 2>/dev/null | tr '\n' ';')"; fi
    }
    cf_secs_row 00 30 60
    cf_secs_row 99999999999999999999 30 60
    cf_secs_row 100 30 60
    cf_secs_row 45 30 45
    cf_secs_row 7 7 7
    cf_secs_row "" 30 60
else
    echo "SKIP 11za: this host has neither timeout nor gtimeout, so the bounded recorder is not run"
fi
rm -rf "$cf_root"

# 12. A truthy-but-not-1 opt-in also enables (yes/on/true).
ARMAUTOMERGE=yes run_mog 0 "ARMAUTOMERGE=yes also enables"

# 13. `--help` prints the WHOLE header reference, not a truncated prefix
# The old `sed -n '2,30p'` stopped at exit code 11,
# so an operator diagnosing a 12-16 refusal saw none of those codes. The range
# is now anchored to the `set -uo pipefail` line, so a header edit cannot
# silently truncate the reference again — this test is what holds that.
# --help is parsed before every gate, so it needs no stubs.
help_out=$(bash "$MOG" --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ]; then
    pass
else
    fail "--help exits 0 (got $help_rc)"
fi
for _code in 0 10 11 12 13 14 15 16; do
    if grepq "$help_out" -E "^ *${_code} +[a-z]"; then
        pass
    else
        fail "--help documents exit code ${_code}"
    fi
done
for _doc in MERGE_ON_GREEN_LOG ARMAUTOMERGE 'GATE INTEGRITY'; do
    if grepq "$help_out" "$_doc"; then
        pass
    else
        fail "--help includes $_doc"
    fi
done
# The terminating `set -uo pipefail` line is code, not help text — it must be
# dropped, or the range anchor leaks the first line of the script body.
if grepq "$help_out" 'set -uo pipefail'; then
    fail "--help leaks the 'set -uo pipefail' code line"
else
    pass
fi

# Hermeticity guard — prove the startup scrub holds. Re-run this
# suite in a subprocess EXPORTING the exact armed bypass env an
# --automerge-armed shell carries; the reinvoked copy's startup unset must
# neutralize it, so its probe (no-opt-in still refuses) passes and it exits 0.
# Remove the startup `unset ARMAUTOMERGE CR_MERGE_GATE_OK` and the reinvoked
# copy instead reads ARMAUTOMERGE=1 as opted-in and exits non-zero.
# Recursion-safe: the sentinel suppresses the guard in the reinvoked copy.
if [ "${HIMMEL_1495_SELF:-0}" != "1" ]; then
    _armed_log="$(mktemp "${TMPDIR:-/tmp}/mog-armed.XXXXXX")" || exit 1
    if CR_MERGE_GATE_OK=1 ARMAUTOMERGE=1 HIMMEL_1495_SELF=1 bash "$SCRIPT_DIR/test-merge-on-green.sh" >"$_armed_log" 2>&1; then
        pass; echo "  hermetic-to-armed-env (self-reinvoke exits 0)"
    else
        fail "hermetic-to-armed-env (startup scrub missing?)"; sed 's/^/  armed: /' "$_armed_log" >&2
    fi
    rm -f "$_armed_log"

    # RC-2 — the comment above claims a specific
    # counterfactual ("remove the startup 'unset ARMAUTOMERGE
    # CR_MERGE_GATE_OK' and the reinvoked copy instead reads ARMAUTOMERGE=1
    # as opted-in and exits non-zero") that nothing here ever executed.
    # Build a scratch mutant of THIS SUITE with that one line removed and
    # prove the counterfactual holds.
    #
    # The mutant is a copy of THIS FILE, so it must live where its own
    # `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` still
    # resolves to the real merge-on-green.sh + libs — i.e. right here in
    # $SCRIPT_DIR, not an arbitrary mktemp dir. run-shell-tests.sh discovers
    # suites via `find -H "$scan" ... -name 'test-*.sh'` (scripts/ci/run-shell-tests.sh),
    # a glob matched against the FULL basename — a leading dot makes this name
    # unable to match that pattern at all, so a concurrent discovery run can
    # never pick this transient file up as a suite of its own.
    rc2_unset_line='unset ARMAUTOMERGE CR_MERGE_GATE_OK'
    rc2_mutant="$SCRIPT_DIR/.test-merge-on-green.rc2-mutant.$$.sh"
    awk -v line="$rc2_unset_line" '$0 != line' "$SCRIPT_DIR/test-merge-on-green.sh" > "$rc2_mutant"
    # -Fx (whole-LINE match), not a substring count: this RC-2 case's own
    # source (this comment block, the note text below) mentions the exact
    # unset line as prose/quoted text, which would inflate a substring count
    # to 4 without ever meaning the awk filter left anything behind. `awk`'s
    # `$0 != line` is itself a whole-line comparison, so the verification must
    # match that semantics, not merely "a line containing this text".
    rc2_pre=$(grep -Fxc -- "$rc2_unset_line" "$SCRIPT_DIR/test-merge-on-green.sh")
    rc2_post=$(grep -Fxc -- "$rc2_unset_line" "$rc2_mutant")
    rc2_diff=$(diff "$SCRIPT_DIR/test-merge-on-green.sh" "$rc2_mutant" | grep -c '^[<>]')
    if [ "$rc2_pre" -ge 1 ] && [ "$rc2_post" -eq 0 ] && [ "$rc2_diff" -eq 1 ]; then
        # The self-probe path (HIMMEL_1495_SELF=1) prints its `FAIL:` line to
        # STDERR only (run_mog's own `fail()`), and the success path (scrub
        # held) prints no comparable marker to stdout either — so merge
        # stderr into stdout here (rather than relying on red_control_run's
        # separate errfile) or the observed extraction below would have
        # nothing to read on the failure side, which is exactly the "empty"
        # vacuity mode this contract exists to catch.
        # shellcheck disable=SC2016  # the inner `$1` is bash -c's OWN
        # positional parameter (bound below to $rc2_mutant), not this shell's
        # -- intentionally unexpanded here.
        red_control_run --env CR_MERGE_GATE_OK=1 --env ARMAUTOMERGE=1 --env HIMMEL_1495_SELF=1 \
            -- bash -c 'exec bash "$1" 2>&1' _ "$rc2_mutant"
        # Anchor on the 1495 self-probe's OWN case name (run_mog's `fail()`
        # emits "FAIL: <name>"), not a bare 'FAIL:' substring.
        # The mutant is a full copy of this suite: everything ABOVE the
        # `if [ "${HIMMEL_1495_SELF:-0}" = "1" ]` short-circuit still runs
        # before it (today just top-level setup — function defs, sourcing —
        # nothing that itself emits "FAIL:", but that is an accident of the
        # current file, not a guarantee). A bare 'FAIL:' substring match would
        # let an UNRELATED regression anywhere in that path print its own
        # "FAIL: ..." line, set rc=1 for a reason that has nothing to do with
        # the startup scrub, and still read as `probe=failed` — "confirming"
        # this control without it ever having exercised the thing it claims to
        # test. Anchoring on the exact case name closes that off regardless of
        # what else ever runs ahead of the short-circuit.
        rc2_probe=passed
        grepq "$RED_CONTROL_OUT" -F -- 'FAIL: armed-env scrubbed: no-opt-in still refuses' && rc2_probe=failed
        if red_control_assert --label "RC-2" --expect-rc 1 \
            --observed     "probe=$rc2_probe" \
            --expect-wrong "probe=failed" \
            --correct      "probe=passed" \
            --note "without the startup 'unset ARMAUTOMERGE CR_MERGE_GATE_OK' an --automerge-armed launching shell's ambient ARMAUTOMERGE=1 leaks in, the no-opt-in refusal (case 1) reads as opted-in, and the suite certifies a hermeticity it does not have"
        then
            pass
        else
            fail "RC-2 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
    else
        fail "RC-2 setup: mutation of the startup unset line was not reproduced cleanly (pre=$rc2_pre post=$rc2_post diff_lines=$rc2_diff)"
    fi
    rm -f "$rc2_mutant"
fi

# Live-chief-doc guard — a launching shell that carries HIMMEL_CONSOLE_DOC must not
# have a bare merge write it. Re-run the suite's one-merge probe (above) with a
# sentinel doc exported; the sentinel must stay byte-identical. The sentinel lives
# outside the run tree, as the live chief doc does.
if [ "${HIMMEL_1495_SELF:-0}" != "1" ] && [ "${HIMMEL_6079_SELF:-0}" != "1" ]; then
    _cd_dir="$(mktemp -d)" || exit 1
    printf '# chief\n\n## Results\n- 00:00 LIVE — sentinel\n' > "$_cd_dir/sentinel.md"
    cp "$_cd_dir/sentinel.md" "$_cd_dir/sentinel.orig"
    _cd_out="$(HIMMEL_CONSOLE_DOC="$_cd_dir/sentinel.md" HIMMEL_CONSOLE_NAME="live-chief" HIMMEL_6079_SELF=1 bash "$SCRIPT_DIR/test-merge-on-green.sh" 2>&1)"; _cd_rc=$?
    if [ "$_cd_rc" -eq 0 ] && cmp -s "$_cd_dir/sentinel.md" "$_cd_dir/sentinel.orig" \
        && printf '%s\n' "$_cd_out" | grep -qF 'chief-doc-partial=unset'; then
        pass; echo "  chief-doc hermetic (sentinel byte-identical after a bare merge)"
    else
        fail "bare merge touched the caller's HIMMEL_CONSOLE_DOC (rc=$_cd_rc): $(cat "$_cd_dir/sentinel.md")"
    fi

    # RC-6079 — drop the startup unset and the same probe must write the sentinel.
    cd_unset_line='unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_NAME'
    cd_mutant="$SCRIPT_DIR/.test-merge-on-green.cd-mutant.$$.sh"
    awk -v line="$cd_unset_line" '$0 != line' "$SCRIPT_DIR/test-merge-on-green.sh" > "$cd_mutant"
    cd_pre=$(grep -Fxc -- "$cd_unset_line" "$SCRIPT_DIR/test-merge-on-green.sh")
    cd_post=$(grep -Fxc -- "$cd_unset_line" "$cd_mutant")
    cd_diff=$(diff "$SCRIPT_DIR/test-merge-on-green.sh" "$cd_mutant" | grep -c '^[<>]')
    if [ "$cd_pre" -ge 1 ] && [ "$cd_post" -eq 0 ] && [ "$cd_diff" -eq 1 ]; then
        cp "$_cd_dir/sentinel.orig" "$_cd_dir/sentinel.md"
        # shellcheck disable=SC2016  # the inner `$1` is bash -c's own positional parameter.
        red_control_run --env HIMMEL_CONSOLE_DOC="$_cd_dir/sentinel.md" --env HIMMEL_CONSOLE_NAME=live-chief --env HIMMEL_6079_SELF=1 \
            -- bash -c 'exec bash "$1" 2>&1' _ "$cd_mutant"
        cd_seen=$(printf '%s\n' "$RED_CONTROL_OUT" | grep -o 'chief-doc-partial=[a-z0-9]*' | tail -n 1)
        if red_control_assert --label "RC-6079" --expect-rc 0 \
            --observed     "$cd_seen" \
            --expect-wrong "chief-doc-partial=1" \
            --correct      "chief-doc-partial=unset" \
            --note "without the startup 'unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_NAME' a launching chief's doc leaks in and a bare merge appends PARTIAL HIMMEL-374 to it, and the suite certifies a hermeticity it does not have"
        then
            pass
        else
            fail "RC-6079 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
    else
        fail "RC-6079 setup: mutation of the chief-doc unset line was not reproduced cleanly (pre=$cd_pre post=$cd_post diff_lines=$cd_diff)"
    fi
    rm -f "$cd_mutant"
    rm -rf "$_cd_dir"
fi

# RC-4 — the guard-2b widening ("&& ! public_origin_merge_allowed
# ...") is a single conditional line; prove it is load-bearing rather than
# vacuously present. Revert JUST that line to the pre-2869 private-only form
# and confirm case 2869-1's fixture (the configured public origin, protected —
# which the real script merges) now refuses with the OLD reason instead.
# shellcheck disable=SC2016  # literal match/replacement against
# merge-on-green.sh's own source text (unexpanded $is_private/$nwo/etc.) --
# not a shell expansion.
rc4_widened_line='if [ "$is_private" != "true" ] && ! public_origin_merge_allowed "$nwo" "$default_branch"; then'
# shellcheck disable=SC2016  # same reason as above -- literal source text.
rc4_reverted_line='if [ "$is_private" != "true" ]; then'
rc4_mutant=$(mktemp "${TMPDIR:-/tmp}/mog-2869-rc4-mutant.XXXXXX")
if [ -z "$rc4_mutant" ] || [ ! -f "$rc4_mutant" ]; then
    fail "RC-4 setup: mktemp produced no mutant-script file — refusing to build the fixture on an empty root"
else
    awk -v line="$rc4_widened_line" -v repl="$rc4_reverted_line" \
        '$0==line{print repl; next}{print}' "$MOG" > "$rc4_mutant"
    rc4_pre=$(grep -Fxc -- "$rc4_widened_line" "$MOG")
    rc4_post=$(grep -Fxc -- "$rc4_widened_line" "$rc4_mutant")
    # A SUBSTITUTION (one line replaced by a different line), not a deletion
    # like RC-2's — `diff` reports that as one `<` (old line) plus one `>`
    # (new line), i.e. 2, the same shape RC-1's own substitution mutant checks
    # for above; a bare deletion (RC-2's shape) would be 1.
    rc4_diff=$(diff "$MOG" "$rc4_mutant" | grep -c '^[<>]')
    if [ "$rc4_pre" -eq 1 ] && [ "$rc4_post" -eq 0 ] && [ "$rc4_diff" -eq 2 ]; then
        rc4_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-2869-rc4-fixture.XXXXXX")
        if [ -z "$rc4_tmp" ] || [ ! -d "$rc4_tmp" ]; then
            fail "RC-4 fixture setup: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
        else
            rc4_gh="$rc4_tmp/gh.log"; : > "$rc4_gh"
            rc4_clear="$rc4_tmp/clear.log"; : > "$rc4_clear"
            rc4_audit="$rc4_tmp/audit.log"
            MOG_SRC="$rc4_mutant" mog_build_fixture "$rc4_tmp"
            red_control_run --cwd "$rc4_tmp" \
                --env GH_LOG="$rc4_gh" --env CLEAR_LOG="$rc4_clear" --env MERGE_ON_GREEN_LOG="$rc4_audit" \
                --env PATH="$rc4_tmp/bin:$PATH" --env MERGE_ON_GREEN_SLEEP_CMD=: \
                --env ARMAUTOMERGE=1 --env STUB_NWO="yotamleo-org/Himmel" --env STUB_CWD_NWO="yotamleo-org/Himmel" \
                --env STUB_PRIVATE=false --env STUB_SHA="pubok01" --env HIMMEL_REPO="$rc4_tmp" \
                -- bash "$rc4_tmp/scripts/handover/merge-on-green.sh"
            # Discriminate on whether the MERGE FIRED, not on the audit
            # reason= field: the mutant touches ONLY the `if` line, not the
            # audit call below it — which still reads $PUBLIC_ORIGIN_REASON,
            # a variable public_origin_merge_allowed (now unreached,
            # short-circuited by the reverted condition) never populates. That
            # field reads "" on BOTH the wrong side (refused) and the correct
            # side (merged, no REFUSED line at all) — zero discriminating
            # power, the exact "looks identical to one that genuinely
            # exercised the mutation" trap red-control.sh's own header warns
            # about. Anchored like merge_line() above (`^pr merge( |$)`), not
            # a bare substring, so a `--json`-shaped mention could never
            # satisfy it.
            rc4_merged=no
            grep -Eq '^pr merge( |$)' "$rc4_gh" 2>/dev/null && rc4_merged=yes
            if red_control_assert --label "RC-4" --expect-rc 12 \
                --observed     "rc=$RED_CONTROL_RC merged=$rc4_merged" \
                --expect-wrong "rc=12 merged=no" \
                --correct      "rc=0 merged=yes" \
                --note "without the guard-2b widening, the configured public origin's protected-branch merge (case 2869-1's fixture) never fires at all"
            then
                pass
            else
                fail "RC-4 mutant: RED control did not hold (see the RED-control diagnostic above)"
            fi
            rm -rf "$rc4_tmp"
        fi
    else
        fail "RC-4 setup: mutation of the guard-2b widening line was not reproduced cleanly (pre=$rc4_pre post=$rc4_post diff_lines=$rc4_diff)"
    fi
    rm -f "$rc4_mutant"
fi


# ── the merge record names its reviewer coverage ────────────────
# check-ci.sh writes to THIS script's stdout, so an operator watching a live run
# already sees what it says about CodeRabbit. An ARMAUTOMERGE chain has no such
# operator: the audit log is the only account of the merge that survives it, and
# `gate=check-ci:0` alone cannot tell "CodeRabbit reviewed this and passed" from
# "there is no CodeRabbit here". The cr= field is that distinction, and it is
# recorded on every state — a field that shows up only on bad news is one nobody
# learns to look for.
#
# The default cwd is a throwaway non-repo, so the state is `not-configured`
# without any pinning. MOG_CR_APP is the seam for the other states, mirroring
# test-check-ci.sh's CR_APP_OVERRIDE and pinned for the same reason: an
# unpinned probe would read whichever clone the suite happens to run from.

# 2380-1 — the adopter's merge is recorded AS the adopter's merge.
run_mog 0 "2380-1: adopter merge records cr=not-configured"
assert_audit_has "2380-1: MERGED line carries the CR state" "gate=check-ci:0"
assert_audit_has "2380-1: and names it as not-configured" "cr=not-configured"

# 2380-2 — and it VARIES. Without this the field could be a hardcoded string
# and 2380-1 would never notice.
MOG_CR_APP=1 run_mog 0 "2380-2: an armed repo records cr=armed"
assert_audit_has "2380-2: MERGED line says armed" "cr=armed"

# 2380-3 — the pre-existing fields are byte-stable. The cr= field was APPENDED,
# never interleaved: every assertion any other case makes about this line reads
# the same bytes it always did.
MOG_CR_APP=0 run_mog 0 "2380-3: a disabled repo records cr=disabled"
assert_audit_has "2380-3: disabled state recorded" "cr=disabled"
assert_audit_has "2380-3: the merge fields ahead of it are unchanged" "prune="

# 2380-4 — --dry-run records it too. A dry run is the shape an operator uses to
# ask "what would this merge do", and the answer includes who reviewed it.
run_mog 0 "2380-4: dry-run records the CR state" -- --dry-run
assert_audit_has "2380-4: DRYRUN line carries cr=" "DRYRUN"
assert_audit_has "2380-4: with the state named" "cr=not-configured"

# 2380-5 — the `broken` state, end to end. Cases 2380-1..4 cover not-configured / armed /
# disabled and omit the ONE state that motivated the whole field. `broken` is
# the only one where the pre-2380 behaviour was a genuinely false certification
# — the marker IS set, so the repo meant to have the CodeRabbit gates, and a
# value git cannot parse as a boolean silently disarms them. Recording every
# other state while leaving that one unverified would have shipped the field
# without its reason.
#
# Needs a REAL repo, because `broken` is the one state no env seam can stub:
# CR_APP short-circuits before the git config is read at all, so reaching it
# means an actual `git config --local himmel.coderabbit <unparseable>`. Reuses
# mk_prune_fixture (a throwaway repo + worktree) and MOG_CWD, the same way the
# 11-series marker cases do, with MOG_CR_APP left EMPTY so the marker path runs.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
git -C "$P_REPO" config --local himmel.coderabbit ture
# Prove the fixture is actually broken before the case trusts it (a zero is not evidence without a positive control). If a future git parsed
# `ture`, this case would pass for the wrong reason: it would be asserting
# cr=broken on a repo that is merely unarmed, i.e. testing nothing.
if git -C "$P_REPO" config --bool --local --get himmel.coderabbit >/dev/null 2>&1; then
    fail "2380-5 setup: fixture is not broken — this git parses 'ture' as a boolean"
else
    MOG_CR_APP="" MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
        run_mog 0 "2380-5: an unparseable himmel.coderabbit marker records cr=broken"
    assert_audit_has "2380-5: the merge record names the broken config" "cr=broken"
    # And it MERGED anyway. This is the half that would be easy to get wrong in
    # the other direction: `broken` warns, it never blocks (a separate guard exists
    # to stop blocking on CodeRabbit's absence, and a config typo must not wedge
    # a merge). A future change that made `broken` fail closed fails HERE.
    assert_audit_has "2380-5: a broken marker warns but does not block the merge" "MERGED repo="
fi

# --- 2919. Chief-GO gate — a chief-spawned worker (HIMMEL_CONSOLE_LEG=1) merges
# only on a chief-written GO file for the certified head ------------------
mog_go_fixture

# 2919-a — marker set, no GO file: refused before any merge call.
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "2919-a: chief worker without a GO file → exit 17"
assert_err_has "2919-a: stderr names the expected GO path" "has no chief GO ($GO_ROOT/.locks/go/77.$GO_SHA)"
assert_audit_has "2919-a: audited as a policy refusal" "REFUSED reason=policy-refused phase=chief-go"
assert_audit_lacks "2919-a: no merge intent recorded" "MERGING"
no_merge_call "2919-a: no merge call"

# 2919-a2 — same on --dry-run: a dry run must report the refusal, not "would merge".
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "2919-a2: dry-run chief worker without a GO file → exit 17" -- --dry-run
assert_audit_lacks "2919-a2: no DRYRUN would-merge line" "DRYRUN"

# 2919-a3 — an unresolvable handover root fails CLOSED, never "no gate".
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT/absent" STUB_SHA="$GO_SHA" \
    run_mog 17 "2919-a3: chief worker with an unresolvable handover root → exit 17"
no_merge_call "2919-a3: no merge call"

# 2919-b — marker set, GO written by the chief's own writer for the certified
# head: proceeds exactly like the unmarked happy path (2919-d's gh log).
go_write "$GO_ROOT" 77 "$GO_SHA"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 0 "2919-b: chief worker with a GO for the certified head → merged" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA"
assert_merge_has "2919-b: merge pins the certified head" "--match-head-commit $GO_SHA"
assert_audit_lacks "8918-a4: a bare --go on the PR's own branch still merges, never exit 27" "go-no-open-pr"
assert_audit_has "2919-b: MERGED recorded" "MERGED repo="
assert_err_has "2919-b: the verified GO evidence is printed" "GO evidence: file=$GO_ROOT/.locks/go/77.$GO_SHA pr=77 head=$GO_SHA"
GO_B_GHLOG=$(awk '!d && sub(/^pr view 77 --json state,url,number,/, "pr view --json state,url,number,") { d = 1 } 1' "$LAST_GH_LOG")

# 7165-a — a valid GO file exists but the worker's merge line carries no --go:
# refused before any merge call, so a merge command always shows its evidence.
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7165-a: chief worker without --go (valid GO on disk) → exit 17"
assert_err_has "7165-a: stderr says --go is required" "needs --go $GO_ROOT/.locks/go/77.$GO_SHA"
assert_audit_has "7165-a: audited as a policy refusal" "REFUSED reason=policy-refused phase=chief-go-flag"
no_merge_call "7165-a: no merge call"

# 7165-b — --go names the GO of another head (written, valid, but not this head's).
go_write "$GO_ROOT" 77 "$GO_OLD"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7165-b: --go for another head → exit 17" -- --go "$GO_ROOT/.locks/go/77.$GO_OLD"
assert_err_has "7165-b: stderr names the expected GO path" "$GO_ROOT/.locks/go/77.$GO_SHA"
no_merge_call "7165-b: no merge call"
rm -f "$GO_ROOT/.locks/go/77.$GO_OLD"

# 7165-c — --go names a valid GO of another PR number at the same head.
go_write "$GO_ROOT" 78 "$GO_SHA"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7165-c: --go for another PR number → exit 17" -- --go "$GO_ROOT/.locks/go/78.$GO_SHA"
assert_err_has "7165-c: stderr names the expected GO path" "$GO_ROOT/.locks/go/77.$GO_SHA"
no_merge_call "7165-c: no merge call"
rm -f "$GO_ROOT/.locks/go/78.$GO_SHA"

# 7165-d — --go naming a file that does not exist: refused.
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7165-d: --go for a missing file → exit 17" -- --go "$GO_ROOT/.locks/go/77.nonexistent"
no_merge_call "7165-d: no merge call"

# 7165-e — the operator path needs no --go, but one that names the wrong GO is
# refused all the same (a flag that lies is never ignored).
HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7165-e: operator path with a wrong --go → exit 17" -- --go "$GO_ROOT/.locks/go/78.$GO_SHA"
no_merge_call "7165-e: no merge call"

HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 \
    run_mog 0 "9917-a: --go from a cwd with no PR resolves the GO's PR → merged" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA"
assert_gh_has "9917-a: the PR query names the GO's PR" "pr view 77 --json state,url,number,headRefOid,baseRefName,headRefName"
assert_merge_has "9917-a: merge pins the certified head" "--match-head-commit $GO_SHA"
assert_audit_has "9917-a: MERGED recorded" "MERGED repo="
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 \
    run_mog 0 "9917-a2: --go --dry-run from a cwd with no PR → would merge" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA" --dry-run
assert_audit_has "9917-a2: dry run names the GO's PR" "DRYRUN would-merge repo=owner/repo pr=#77 sha=$GO_SHA"
no_merge_call "9917-a2: no merge call"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 \
    run_mog 17 "9917-b: a selector wins over the GO name → exit 17" -- 77 --go "$GO_ROOT/.locks/go/78.$GO_SHA"
assert_gh_lacks "9917-b: no query for the GO name's PR" "pr view 78 "
assert_err_has "9917-b: today's wrong-GO refusal" "--go $GO_ROOT/.locks/go/78.$GO_SHA is not the GO for PR #77 at $GO_SHA"
no_merge_call "9917-b: no merge call"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 \
    run_mog 27 "9917-c: a GO name not <pr>.<sha> → exit 27 as today" -- --go "$GO_ROOT/.locks/go/77.nonexistent"
assert_gh_lacks "9917-c: no PR taken from the name" "pr view 77 "
assert_err_has "9917-c: stderr says nothing merged" "nothing merged"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 \
    run_mog 17 "9917-d: a GO name at another head → exit 17" -- --go "$GO_ROOT/.locks/go/77.$GO_OLD"
assert_err_has "9917-d: today's wrong-GO refusal" "--go $GO_ROOT/.locks/go/77.$GO_OLD is not the GO for PR #77 at $GO_SHA — pass --go $GO_ROOT/.locks/go/77.$GO_SHA"
no_merge_call "9917-d: no merge call"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" STUB_NO_CWD_PR=1 STUB_STATE=MERGED \
    run_mog 0 "9917-e: the GO's PR already MERGED → exit 0" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA"
assert_err_has "9917-e: stderr says already merged" "already merged"
no_merge_call "9917-e: no merge call"

# 2919-c — only a STALE GO (an older head) exists: refused.
rm -f "$GO_ROOT/.locks/go/77.$GO_SHA"
go_write "$GO_ROOT" 77 "$GO_OLD"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "2919-c: chief worker with only a stale GO → exit 17"
assert_err_has "2919-c: stderr says a stale GO is never reused" "a GO for an older head is stale"
no_merge_call "2919-c: no merge call"

# 2919-c2 — the stale GO RENAMED onto the certified head's path still carries
# head=<old sha>: the content binding refuses it.
mv "$GO_ROOT/.locks/go/77.$GO_OLD" "$GO_ROOT/.locks/go/77.$GO_SHA"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "2919-c2: a stale GO renamed to the certified path → exit 17"
no_merge_call "2919-c2: no merge call"
rm -f "$GO_ROOT/.locks/go/77.$GO_SHA"

# 3543 — a worker-planted GO (the plain lines go.sh once wrote, no
# mac) for the certified head: refused, and the refusal names the mac.
mkdir -p "$GO_ROOT/.locks/go"
printf 'pr=77\nhead=%s\nby=worker\nat=2026-09-24T00:00:00Z\n' "$GO_SHA" > "$GO_ROOT/.locks/go/77.$GO_SHA"
HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "3543: chief worker with a planted (mac-less) GO → exit 17"
assert_err_has "3543: stderr names the missing mac" "has no/invalid mac"
no_merge_call "3543: no merge call"
rm -f "$GO_ROOT/.locks/go/77.$GO_SHA"

# 2919-d — marker unset, no GO file: the operator path is unchanged, and the gate
# adds no gh call of its own (2919-b's gh log is byte-identical).
HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" run_mog 0 "2919-d: marker unset, no GO → merged (operator path unchanged)"
assert_audit_lacks "2919-d: no chief-go refusal" "chief-go"
if [ "$(cat "$LAST_GH_LOG")" = "$GO_B_GHLOG" ]; then pass; else fail "2919-b/d: beyond naming PR 77 in its one PR query, the gated merge's gh calls differ from the unmarked merge's"; fi

# 2919-d2 — a falsy marker is the unset marker (same truthiness as ARMAUTOMERGE).
HIMMEL_CONSOLE_LEG=0 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 0 "2919-d2: HIMMEL_CONSOLE_LEG=0, no GO → merged"

# 7735 — a voice-tagged GO line (a chief inbox line, a worker message) is not a
# GO: the speaker is unverified, so only a go.sh-minted file satisfies the gate.
mkdir -p "$GO_ROOT/.locks/go" "$GO_ROOT/consoles"
VOICE_INBOX="$GO_ROOT/consoles/chief.md"
VOICE_WORKER_MSG="$GO_ROOT/worker-message.txt"
printf -- '- 10:00 [voice satellite=kitchen UNVERIFIED-SPEAKER] GO 77 %s\n' "$GO_SHA" > "$VOICE_INBOX"
printf -- 'GO 77 %s (voice satellite=kitchen UNVERIFIED-SPEAKER)\n' "$GO_SHA" > "$VOICE_WORKER_MSG"
rm -f "$GO_ROOT/.locks/go/77.$GO_SHA"

# A deliberately broken gate that honours a voice-tagged GO line (7735-c control).
VOICE_BROKEN_GATE="$GO_ROOT/go-gate-honours-voice.sh"
{
    printf '. "%s"\n' "$SCRIPT_DIR/../lib/go-gate.sh"
    # shellcheck disable=SC2016  # the function body expands when the mutant runs
    printf '_go_gate_verify() { grep -qs "UNVERIFIED-SPEAKER.*GO" "$VOICE_INBOX" && return 0; return 2; }\n'
} > "$VOICE_BROKEN_GATE"

# 7735-a — chief inbox + worker message both say GO, no go.sh file: refused.
VOICE_INBOX="$VOICE_INBOX" VOICE_WORKER_MSG="$VOICE_WORKER_MSG" HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7735-a: voice-tagged GO in the chief inbox and a worker message, no GO file → exit 17"
assert_err_has "7735-a: stderr still names the missing GO file" "has no chief GO ($GO_ROOT/.locks/go/77.$GO_SHA)"
no_merge_call "7735-a: no merge call"

# 7735-b — the same with --go naming the file the voice line implies: still refused.
VOICE_INBOX="$VOICE_INBOX" VOICE_WORKER_MSG="$VOICE_WORKER_MSG" HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 17 "7735-b: voice-tagged GO plus --go for the absent file → exit 17" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA"
no_merge_call "7735-b: no merge call"

# 7735-c — control: a deliberately broken gate that honours a voice-tagged GO
# line merges, so 7735-a/b would fail against it (the rows have teeth).
GO_GATE_SRC="$VOICE_BROKEN_GATE" VOICE_INBOX="$VOICE_INBOX" HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" STUB_SHA="$GO_SHA" \
    run_mog 0 "7735-c: control — a gate that honours the voice line merges" -- --go "$GO_ROOT/.locks/go/77.$GO_SHA"
rm -rf "$GO_ROOT"

# --- 3895. Trust-path gate — a PR touching a base-sourced trust path merges only
# on a trust-reviewed GO for the certified head, worker or not ------------------
TP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mog-tp.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
TP_ROOT=$(cd "$TP_ROOT" && pwd)
TP_GO="$TP_ROOT/.locks/go"
TP_CI='[{"filename":".github/workflows/ci.yml"}]'
tp_mint() { go_write "$TP_ROOT" "$@"; }
# The verdict counts only under <user>/<bucket> (USER_SLUG + the primary checkout basename).
export USER_SLUG=u
TP_SCOPE="u/$(basename "$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")" | tr "[:upper:]" "[:lower:]" | sed -E "s/[^a-z0-9]+/-/g; s/^-+//; s/-+\$//")"
# A trust-reviewed GO needs the judge's GO verdict for the head.
mkdir -p "$TP_ROOT/$TP_SCOPE/verdicts/judge-N9"
# shellcheck disable=SC2016  # literal backticks in the verdict line
printf '## Verdict\n\n**GO** for head `%s`.\n\npr: 77\n' "$GO_SHA" > "$TP_ROOT/$TP_SCOPE/verdicts/judge-N9/a.md"
# shellcheck disable=SC2016  # literal backticks in the verdict line
printf '## Verdict\n\n**GO** for head `%s`.\n\npr: 77\n' "$GO_OLD" > "$TP_ROOT/$TP_SCOPE/verdicts/judge-N9/b.md"
# A verdict counts only with write-verdict.sh's mac under the GO key.
mkdir -p "$HOME/.config/himmel"
[ -s "$HOME/.config/himmel/go-hmac.key" ] || printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
for tp_v in a b; do
    tp_mac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$(dirname "$0")/../lib/go-gate.sh" "$TP_SCOPE" judge-N9 "$tp_v" < "$TP_ROOT/$TP_SCOPE/verdicts/judge-N9/$tp_v.md")" || echo "FAIL: cannot sign verdict $tp_v" >&2
    printf 'mac: %s\n' "$tp_mac" >> "$TP_ROOT/$TP_SCOPE/verdicts/judge-N9/$tp_v.md"
done
tp_run() {
    MOG_ANCHOR_GIT=1 HANDOVER_DIR="$TP_ROOT" STUB_SHA="$GO_SHA" STUB_PR_FILES_JSON="${STUB_PR_FILES_JSON-$TP_CI}" run_mog "$@"
}

# 3895-a (RED) — a PR touching .github/workflows/ci.yml, operator path, no GO:
# merged before this gate; refused now, before any merge call or marker clear.
tp_run 21 "3895-a: trust-path PR with no GO → exit 21"
assert_audit_has "3895-a: audited as a trust-path refusal" "REFUSED reason=trust-path"
assert_err_has "3895-a: stderr names the matched path" ".github/workflows/ci.yml"
assert_gh_has "3895-a: the list is read from the default branch" "contents/scripts/ci/ci-trust-paths.txt?ref=main"
assert_clear_not_invoked "3895-a: nothing mutated before the refusal"
no_merge_call "3895-a: no merge call"

# 3895-a2 — the dry run reports the same refusal.
tp_run 21 "3895-a2: dry-run trust-path PR with no GO → exit 21" -- --dry-run
assert_audit_lacks "3895-a2: no DRYRUN would-merge line" "DRYRUN"

# 3895-a3 — a chief worker holding an ORDINARY GO for the head: the chief-GO
# gate passes, the trust gate still refuses.
tp_mint 77 "$GO_SHA"
# HIMMEL_CONSOLE_LEG is a Claude Code marker: with no claude ancestor (CI) and
# seams set, the anchor copy refuses 96. A chief worker always
# runs under its claude session, so these rows run under a fake one.
MOG_WRAP=_as_claude HIMMEL_CONSOLE_LEG=1 tp_run 21 "3895-a3: chief worker with an ordinary GO on a trust-path PR → exit 21" -- --go "$TP_GO/77.$GO_SHA"
assert_err_has "3895-a3: stderr asks for a trust-reviewed GO" "trust-reviewed"
no_merge_call "3895-a3: no merge call"

# 3895-b — a trust-reviewed GO minted by go.sh for this PR at this head merges,
# for a chief worker and for the operator path alike.
tp_mint --trust-reviewed judge-N9 77 "$GO_SHA"
MOG_WRAP=_as_claude HIMMEL_CONSOLE_LEG=1 tp_run 0 "3895-b: chief worker with a trust-reviewed GO → merged" -- --go "$TP_GO/77.$GO_SHA"
assert_merge_has "3895-b: merge pins the certified head" "--match-head-commit $GO_SHA"
assert_audit_has "3895-b: the trust review rides the audit" "trust=judge-N9"
tp_run 0 "3895-b2: operator path with a trust-reviewed GO → merged"

# 3895-c — forged: the trust id edited after signing breaks the mac.
sed -i.bak 's/^trust-reviewed=.*/trust-reviewed=judge-FORGED/' "$TP_GO/77.$GO_SHA"
tp_run 21 "3895-c: a trust GO whose id was edited → exit 21"
no_merge_call "3895-c: no merge call"
# 3895-c2 — an ORDINARY GO with a trust-reviewed line appended: its mac never
# covered the id, so it verifies as neither form.
tp_mint 77 "$GO_SHA"
printf 'trust-reviewed=judge-N9\n' >> "$TP_GO/77.$GO_SHA"
tp_run 21 "3895-c2: an ordinary GO with an appended trust line → exit 21"
# 3895-c3 — stale: a trust GO for an older head, renamed onto this head.
rm -f "$TP_GO/77.$GO_SHA"
tp_mint --trust-reviewed judge-N9 77 "$GO_OLD"
mv "$TP_GO/77.$GO_OLD" "$TP_GO/77.$GO_SHA"
tp_run 21 "3895-c3: a trust GO for another head, renamed → exit 21"
# 3895-c4 — a trust GO for another PR at this head, renamed onto this PR.
tp_mint --trust-reviewed judge-N9 78 "$GO_SHA"
mv "$TP_GO/78.$GO_SHA" "$TP_GO/77.$GO_SHA"
tp_run 21 "3895-c4: a trust GO for another PR, renamed → exit 21"
no_merge_call "3895-c4: no merge call"
rm -f "$TP_GO/77.$GO_SHA"

# 3895-d — a PR editing ci-trust-paths.txt itself is judged by the DEFAULT
# branch's list (the stub serves main's copy), so emptying it on the head buys
# nothing: the edit is itself a trust path.
STUB_PR_FILES_JSON='[{"filename":"scripts/ci/ci-trust-paths.txt"}]' \
    tp_run 21 "3895-d: a PR shrinking ci-trust-paths.txt → exit 21"
assert_gh_has "3895-d: base-sourced read" "ci-trust-paths.txt?ref=main"
# 3895-d2 — a rename OUT of a trust path is caught by previous_filename.
STUB_PR_FILES_JSON='[{"filename":"docs/x.yml","previous_filename":".github/workflows/ci.yml"}]' \
    tp_run 21 "3895-d2: a rename out of .github/ → exit 21"

# 3895-e — a PR touching no trust path is unchanged: merged, no trust audit.
STUB_PR_FILES_JSON='[{"filename":"README.md"},{"filename":"docs/a.md"}]' \
    tp_run 0 "3895-e: non-trust PR, no GO → merged"
assert_audit_lacks "3895-e: no trust refusal" "trust-path"

# 3895-f — fail closed on everything the gate cannot prove.
STUB_PR_CHANGED_FILES=3001 \
    tp_run 21 "3895-f: listed files short of changed_files (3000-file cap) → exit 21"
STUB_PR_HEAD_SECOND=fedcba9876543210fedcba9876543210fedcba98 \
    tp_run 21 "3895-f2: head moved while listing files → exit 21"
STUB_PR_HEAD=fedcba9876543210fedcba9876543210fedcba98 STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f3: PR head is not the certified sha → exit 21"
STUB_PR_FILES_FAIL=1 STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f4: file list unreadable → exit 21"
STUB_TRUST_LIST_FAIL=1 STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f5: trust list unreadable → exit 21"
STUB_TRUST_LIST=$'# only comments\n\n' STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f6: empty trust list → exit 21"
STUB_TRUST_LIST=$'^scripts/[\n' STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f7: invalid trust regex → exit 21"
STUB_TRUST_LIST_404=1 STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 21 "3895-f8: no trust list on the harness's own repo → exit 21"
# 3895-f10 — a list saved with CRLF endings, or with blanks around a pattern,
# must still match: a pattern carrying a stray \r or space matches nothing,
# which would parallel wave a trust-path PR through (fail open).
STUB_TRUST_LIST=$(sed 's/$/\r/' "$SCRIPT_DIR/../ci/ci-trust-paths.txt") \
    tp_run 21 "3895-f10: CRLF trust list, trust-path PR with no GO → exit 21"
no_merge_call "3895-f10: no merge call"
STUB_TRUST_LIST=$(sed 's/^\(.\)/  \1/; s/$/ 	 /' "$SCRIPT_DIR/../ci/ci-trust-paths.txt") \
    tp_run 21 "3895-f11: blank-padded trust list, trust-path PR with no GO → exit 21"
no_merge_call "3895-f11: no merge call"
# 3895-f9 — the anchor cannot catch up to origin (it holds a commit origin
# lacks): a trust-path PR is judged by a possibly stale gate, so it refuses (a
# non-trust PR is not affected).
tp_mint --trust-reviewed judge-N9 77 "$GO_SHA"
MOG_ANCHOR_BEHIND=1 MOG_ANCHOR_DIVERGED=1 tp_run 21 "3895-f9: anchor diverged from origin, trust-path PR → exit 21"
assert_err_has "3895-f9: stderr says to pull the anchor" "behind"
no_merge_call "3895-f9: no merge call"
# 7474 — an anchor merely one commit behind origin fast-forwards first, so the
# same trust-path PR with its trust-reviewed GO merges instead of exiting 21.
MOG_ANCHOR_BEHIND=1 tp_run 0 "7474-a: anchor one commit behind origin, trust-path PR → merged"
assert_merge_has "7474-a: merge pins the certified head" "--match-head-commit $GO_SHA"
assert_audit_has "7474-a: the trust review rides the audit" "trust=judge-N9"
# The catch-up does not weaken the gate: with no trust-reviewed GO it still refuses.
rm -f "$TP_GO/77.$GO_SHA"
MOG_ANCHOR_BEHIND=1 tp_run 21 "7474-b: anchor behind origin, trust-path PR with no GO → exit 21"
no_merge_call "7474-b: no merge call"
# A dry run mutates nothing: it does not fast-forward the anchor, it reports the refusal.
tp_mint --trust-reviewed judge-N9 77 "$GO_SHA"
MOG_ANCHOR_BEHIND=1 tp_run 21 "7474-c: dry-run, anchor behind origin, trust-path PR → exit 21" -- --dry-run
assert_audit_lacks "7474-c: the anchor was not fast-forwarded" "ANCHOR fast-forwarded"
tp_mint --trust-reviewed judge-N9 77 "$GO_SHA"
MOG_ANCHOR_BEHIND=1 STUB_PR_FILES_JSON='[{"filename":"README.md"}]' \
    tp_run 0 "3895-f10: anchor behind origin, non-trust PR → merged (unchanged)"
rm -f "$TP_GO/77.$GO_SHA"

# 3895-g — another repo with no list has not adopted the gate: unchanged, but
# audited so the absence is visible.
MERGE_STATIC_RECHECK=1 STUB_NWO=other/repo STUB_TRUST_LIST_404=1 \
    tp_run 0 "3895-g: no trust list on a non-harness repo → merged"
assert_audit_has "3895-g: not-adopted is audited" "trust=not-adopted"
assert_audit_has "3895-g: the static re-check is skipped for another repo" "STATIC-RECHECK skipped reason=other-repo"
# The anchor has no core file; not-adopted still rests on the repo's settings
# read (404 here), never on the anchor.
assert_gh_has "3895-g: the repo's settings are read" "api repos/other/repo/contents/.claude/settings.json?ref=main"
# 3895-h — an origin that does not positively name another github.com repo (an
# SSH host alias) cannot prove the 404 is off the harness's own repo: refuse.
MOG_ANCHOR_URL=git@gh-alias:owner/repo.git STUB_NWO=other/repo STUB_TRUST_LIST_404=1 \
    tp_run 21 "3895-h: no trust list, anchor origin is an SSH alias → exit 21"
MOG_ANCHOR_URL=https://notgithub.com/owner/repo.git STUB_NWO=other/repo STUB_TRUST_LIST_404=1 \
    tp_run 21 "3895-h2: no trust list, anchor origin host only ends in github.com → exit 21"
MOG_ANCHOR_URL=https://evil.example/github.com/owner/repo.git STUB_NWO=other/repo STUB_TRUST_LIST_404=1 \
    tp_run 21 "3895-h3: no trust list, github.com only in the origin path → exit 21"
MOG_ANCHOR_URL=git@github.com:owner/repo.git STUB_NWO=other/repo STUB_TRUST_LIST_404=1 \
    tp_run 0 "3895-h4: no trust list, scp-form github.com origin names another repo → merged"
rm -rf "$TP_ROOT"

# RED control — the pre-fix script tested
# `[ "$go_rc" = "2" ]`, enumerating go_gate's one documented refusal code
# instead of enforcing "nonzero = failure". A go-gate.sh that sources
# cleanly but never DEFINES go_gate (truncated) makes the call fail with
# "command not found" (go_rc=127), which is != "2" — so the pre-fix
# script (head 6749462a, the earlier shipped state) fell
# through the refusal entirely and continued straight to a real merge,
# with no GO file anywhere. Same fixture as 2919-a (chief worker, no GO
# file) but against a truncated go-gate.sh: prove it wrongly merges
# pre-fix, and is refused post-fix by the new `command -v go_gate`
# precondition.
RC5_TRUNC_GOGATE=$(mktemp "${TMPDIR:-/tmp}/mog-3142-rc127-gogate.XXXXXX")
head -n 29 "$SCRIPT_DIR/../lib/go-gate.sh" > "$RC5_TRUNC_GOGATE"
if grep -q '^go_gate()' "$RC5_TRUNC_GOGATE"; then
    fail "RC-5 setup: go-gate.sh header grew past line 29 — the truncated copy still defines go_gate, so this control no longer exercises a missing-symbol source"
elif ! grep -q '^chief_worker()' "$RC5_TRUNC_GOGATE"; then
    fail "RC-5 setup: go-gate.sh's chief_worker() no longer fits in the first 29 lines — the truncated copy would fail the new chief_worker lib-missing check instead of exercising the go_gate missing-symbol source this control targets"
else
    # This commit's PR branch was deleted on squash-merge, so
    # `git show <sha>:<path>` is unreachable from a fresh clone of origin —
    # not flaky, permanently gone the moment the introducing PR merges, while
    # a developer's stale local checkout may still have the object loose and
    # stay falsely green. Replaced with a committed fixture snapshot.
    RC5_PRE_SHA=6749462a6c22911d748b8a39254fbd86bdf14ece
    rc5_pre_mutant=$(mktemp "${TMPDIR:-/tmp}/mog-3142-rc127-pre.XXXXXX")
    cp "$SCRIPT_DIR/fixtures/red-control/merge-on-green.pre-rc127-fix.sh" "$rc5_pre_mutant" 2>/dev/null
    if [ ! -s "$rc5_pre_mutant" ]; then
        fail "RC-5 setup: could not extract the pre-round-3-fix merge-on-green.sh from head $RC5_PRE_SHA"
    else
        rc5_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc127-go.XXXXXX")
        rc5_go_root=$(cd "$rc5_go_root" && pwd)
        rc5_sha=0123456789abcdef0123456789abcdef01234567
        rc5_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc127-fixture.XXXXXX")
        rc5_gh="$rc5_tmp/gh.log"; : > "$rc5_gh"
        rc5_clear="$rc5_tmp/clear.log"; : > "$rc5_clear"
        rc5_audit="$rc5_tmp/audit.log"
        MOG_SRC="$rc5_pre_mutant" GO_GATE_SRC="$RC5_TRUNC_GOGATE" mog_build_fixture "$rc5_tmp"
        red_control_run --cwd "$rc5_tmp" \
            --env GH_LOG="$rc5_gh" --env CLEAR_LOG="$rc5_clear" --env MERGE_ON_GREEN_LOG="$rc5_audit" \
            --env PATH="$rc5_tmp/bin:$PATH" --env MERGE_ON_GREEN_SLEEP_CMD=: \
            --env HIMMEL_CONSOLE_LEG=1 --env HANDOVER_DIR="$rc5_go_root" --env STUB_SHA="$rc5_sha" \
            -- bash "$rc5_tmp/scripts/handover/merge-on-green.sh"
        rc5_merged=no
        grep -Eq '^pr merge( |$)' "$rc5_gh" 2>/dev/null && rc5_merged=yes
        if red_control_assert --label "HIMMEL-3142-RC127-MOG-RC" --expect-rc 0 \
            --observed     "rc=$RED_CONTROL_RC merged=$rc5_merged" \
            --expect-wrong "rc=0 merged=yes" \
            --correct      "rc=17 merged=no" \
            --note "pre-round-3-fix merge-on-green.sh (head $RC5_PRE_SHA) tested go_rc = \"2\" only; a truncated go-gate.sh sources cleanly but never defines go_gate, so the call fails with rc=127, the test is false, and the chief-GO gate never fires — same fixture as 2919-a (chief worker, no GO file), which the shipped script refuses"
        then
            pass
        else
            fail "RC-5 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
        rm -rf "$rc5_tmp" "$rc5_go_root"

        # Post-fix: same truncated go-gate.sh, but the LIVE (fixed) script.
        rc5_post_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc127-post.XXXXXX")
        rc5_post_gh="$rc5_post_tmp/gh.log"; : > "$rc5_post_gh"
        rc5_post_clear="$rc5_post_tmp/clear.log"; : > "$rc5_post_clear"
        rc5_post_audit="$rc5_post_tmp/audit.log"
        rc5_post_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc127-post-go.XXXXXX")
        rc5_post_go_root=$(cd "$rc5_post_go_root" && pwd)
        GO_GATE_SRC="$RC5_TRUNC_GOGATE" mog_build_fixture "$rc5_post_tmp"
        rc5_post_err="$rc5_post_tmp/stderr.log"
        (
            cd "$rc5_post_tmp" && \
            GH_LOG="$rc5_post_gh" CLEAR_LOG="$rc5_post_clear" MERGE_ON_GREEN_LOG="$rc5_post_audit" \
            PATH="$rc5_post_tmp/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
            HIMMEL_REPO="$rc5_post_tmp" \
            HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$rc5_post_go_root" STUB_SHA="$rc5_sha" \
            bash "$rc5_post_tmp/scripts/handover/merge-on-green.sh"
        ) >/dev/null 2>"$rc5_post_err"
        rc5_post_rc=$?
        if [ "$rc5_post_rc" -eq 17 ] && grep -qi "not defined" "$rc5_post_err" \
            && grep -q "phase=chief-go-symbol-missing" "$rc5_post_audit" 2>/dev/null; then
            pass
        else
            fail "RC-5 post-fix: expected exit 17 naming 'not defined' + phase=chief-go-symbol-missing, got rc=$rc5_post_rc stderr=$(cat "$rc5_post_err" 2>/dev/null)"
        fi
        rm -rf "$rc5_post_tmp" "$rc5_post_go_root"
    fi
    rm -f "$rc5_pre_mutant"
fi
rm -f "$RC5_TRUNC_GOGATE"

# RC-6/RC-7 — `command -v go_gate` (the earlier fix)
# answers "is the name go_gate callable", not "did sourcing go-gate.sh define
# the function". Two distinct ways that diverges, both against a truncated
# go-gate.sh (does not define go_gate):
#   RC-6: a PATH executable named go_gate — command -v finds it, the script
#         CALLS it (not a function), it exits 0, and the chief-GO gate
#         never fires. declare -F (bash-function-only) rejects this.
#   RC-7: an inherited `export -f go_gate` in the launching shell — a real
#         bash function, so declare -F ALSO passes it through unless it is
#         unset first; only `unset -f go_gate` before the source closes it.
# Pre-fix blob for both is head 6fe4ad20 (the earlier shipped script, the
# `command -v` version).
RC67_TRUNC_GOGATE=$(mktemp "${TMPDIR:-/tmp}/mog-3142-rc67-gogate.XXXXXX")
head -n 29 "$SCRIPT_DIR/../lib/go-gate.sh" > "$RC67_TRUNC_GOGATE"
if grep -q '^go_gate()' "$RC67_TRUNC_GOGATE"; then
    fail "RC-6/RC-7 setup: go-gate.sh header grew past line 29 — the truncated copy still defines go_gate, so this control no longer exercises a missing-symbol source"
elif ! grep -q '^chief_worker()' "$RC67_TRUNC_GOGATE"; then
    fail "RC-6/RC-7 setup: go-gate.sh's chief_worker() no longer fits in the first 29 lines — the truncated copy would fail the new chief_worker lib-missing check instead of exercising the go_gate missing-symbol source this control targets"
else
    # This commit's PR branch was deleted on squash-merge, so
    # `git show <sha>:<path>` is unreachable from a fresh clone of origin —
    # see the note on the RC5_PRE_SHA extraction above. Replaced with a
    # committed fixture snapshot.
    RC67_PRE_SHA=6fe4ad205612f59c71c8354ff9f5981c5d23bb5f
    rc67_pre_mutant=$(mktemp "${TMPDIR:-/tmp}/mog-3142-rc67-pre.XXXXXX")
    cp "$SCRIPT_DIR/fixtures/red-control/merge-on-green.pre-rc4-fix.sh" "$rc67_pre_mutant" 2>/dev/null
    if [ ! -s "$rc67_pre_mutant" ]; then
        fail "RC-6/RC-7 setup: could not extract the pre-round-4-fix merge-on-green.sh from head $RC67_PRE_SHA"
    else
        rc67_sha=0123456789abcdef0123456789abcdef01234567

        # ── RC-6: PATH-executable go_gate ──
        rc6_bin=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc6-bin.XXXXXX")
        cat > "$rc6_bin/go_gate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$rc6_bin/go_gate"

        rc6_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc6-go.XXXXXX")
        rc6_go_root=$(cd "$rc6_go_root" && pwd)
        rc6_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc6-fixture.XXXXXX")
        rc6_gh="$rc6_tmp/gh.log"; : > "$rc6_gh"
        rc6_clear="$rc6_tmp/clear.log"; : > "$rc6_clear"
        rc6_audit="$rc6_tmp/audit.log"
        MOG_SRC="$rc67_pre_mutant" GO_GATE_SRC="$RC67_TRUNC_GOGATE" mog_build_fixture "$rc6_tmp"
        red_control_run --cwd "$rc6_tmp" \
            --env GH_LOG="$rc6_gh" --env CLEAR_LOG="$rc6_clear" --env MERGE_ON_GREEN_LOG="$rc6_audit" \
            --env PATH="$rc6_bin:$rc6_tmp/bin:$PATH" --env MERGE_ON_GREEN_SLEEP_CMD=: \
            --env HIMMEL_CONSOLE_LEG=1 --env HANDOVER_DIR="$rc6_go_root" --env STUB_SHA="$rc67_sha" \
            -- bash "$rc6_tmp/scripts/handover/merge-on-green.sh"
        rc6_merged=no
        grep -Eq '^pr merge( |$)' "$rc6_gh" 2>/dev/null && rc6_merged=yes
        if red_control_assert --label "HIMMEL-3142-RC6-RC" --expect-rc 0 \
            --observed     "rc=$RED_CONTROL_RC merged=$rc6_merged" \
            --expect-wrong "rc=0 merged=yes" \
            --correct      "rc=17 merged=no" \
            --note "round-3-shipped merge-on-green.sh (head $RC67_PRE_SHA) used \`command -v go_gate\`, which finds a PATH executable named go_gate exactly as readily as a sourced function; against a truncated go-gate.sh plus a PATH-executable go_gate that exits 0, the script calls that executable, treats go_rc=0 as a real GO, and merges with no go_gate function ever having run"
        then
            pass
        else
            fail "RC-6 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
        rm -rf "$rc6_tmp" "$rc6_go_root"

        rc6_post_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc6-post-go.XXXXXX")
        rc6_post_go_root=$(cd "$rc6_post_go_root" && pwd)
        rc6_post_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc6-post.XXXXXX")
        rc6_post_gh="$rc6_post_tmp/gh.log"; : > "$rc6_post_gh"
        rc6_post_clear="$rc6_post_tmp/clear.log"; : > "$rc6_post_clear"
        rc6_post_audit="$rc6_post_tmp/audit.log"
        GO_GATE_SRC="$RC67_TRUNC_GOGATE" mog_build_fixture "$rc6_post_tmp"
        rc6_post_err="$rc6_post_tmp/stderr.log"
        (
            cd "$rc6_post_tmp" && \
            GH_LOG="$rc6_post_gh" CLEAR_LOG="$rc6_post_clear" MERGE_ON_GREEN_LOG="$rc6_post_audit" \
            PATH="$rc6_bin:$rc6_post_tmp/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
            HIMMEL_REPO="$rc6_post_tmp" \
            HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$rc6_post_go_root" STUB_SHA="$rc67_sha" \
            bash "$rc6_post_tmp/scripts/handover/merge-on-green.sh"
        ) >/dev/null 2>"$rc6_post_err"
        rc6_post_rc=$?
        if [ "$rc6_post_rc" -eq 17 ] && grep -qi "not defined" "$rc6_post_err" \
            && grep -q "phase=chief-go-symbol-missing" "$rc6_post_audit" 2>/dev/null; then
            pass
        else
            fail "RC-6 post-fix: expected exit 17 naming 'not defined' + phase=chief-go-symbol-missing, got rc=$rc6_post_rc stderr=$(cat "$rc6_post_err" 2>/dev/null)"
        fi
        rm -rf "$rc6_post_tmp" "$rc6_post_go_root"
        rm -rf "$rc6_bin"

        # ── RC-7: inherited `export -f go_gate` ──
        # shellcheck disable=SC2329,SC2317  # invoked indirectly via export -f in a child bash process (rc7 fixture)
        go_gate() { exit 0; }
        export -f go_gate

        rc7_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc7-go.XXXXXX")
        rc7_go_root=$(cd "$rc7_go_root" && pwd)
        rc7_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc7-fixture.XXXXXX")
        rc7_gh="$rc7_tmp/gh.log"; : > "$rc7_gh"
        rc7_clear="$rc7_tmp/clear.log"; : > "$rc7_clear"
        rc7_audit="$rc7_tmp/audit.log"
        MOG_SRC="$rc67_pre_mutant" GO_GATE_SRC="$RC67_TRUNC_GOGATE" mog_build_fixture "$rc7_tmp"
        red_control_run --cwd "$rc7_tmp" \
            --env GH_LOG="$rc7_gh" --env CLEAR_LOG="$rc7_clear" --env MERGE_ON_GREEN_LOG="$rc7_audit" \
            --env PATH="$rc7_tmp/bin:$PATH" --env MERGE_ON_GREEN_SLEEP_CMD=: \
            --env HIMMEL_CONSOLE_LEG=1 --env HANDOVER_DIR="$rc7_go_root" --env STUB_SHA="$rc67_sha" \
            -- bash "$rc7_tmp/scripts/handover/merge-on-green.sh"
        rc7_merged=no
        grep -Eq '^pr merge( |$)' "$rc7_gh" 2>/dev/null && rc7_merged=yes
        if red_control_assert --label "HIMMEL-3142-RC7-RC" --expect-rc 0 \
            --observed     "rc=$RED_CONTROL_RC merged=$rc7_merged" \
            --expect-wrong "rc=0 merged=yes" \
            --correct      "rc=17 merged=no" \
            --note "round-3-shipped merge-on-green.sh (head $RC67_PRE_SHA) used \`command -v go_gate\` with no unset -f before sourcing; an inherited export -f go_gate in the launching shell is a real bash function, so command -v finds it exactly like one the file just defined, and a truncated go-gate.sh never overrides it"
        then
            pass
        else
            fail "RC-7 mutant: RED control did not hold (see the RED-control diagnostic above)"
        fi
        rm -rf "$rc7_tmp" "$rc7_go_root"

        rc7_post_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc7-post-go.XXXXXX")
        rc7_post_go_root=$(cd "$rc7_post_go_root" && pwd)
        rc7_post_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-3142-rc7-post.XXXXXX")
        rc7_post_gh="$rc7_post_tmp/gh.log"; : > "$rc7_post_gh"
        rc7_post_clear="$rc7_post_tmp/clear.log"; : > "$rc7_post_clear"
        rc7_post_audit="$rc7_post_tmp/audit.log"
        GO_GATE_SRC="$RC67_TRUNC_GOGATE" mog_build_fixture "$rc7_post_tmp"
        rc7_post_err="$rc7_post_tmp/stderr.log"
        (
            cd "$rc7_post_tmp" && \
            GH_LOG="$rc7_post_gh" CLEAR_LOG="$rc7_post_clear" MERGE_ON_GREEN_LOG="$rc7_post_audit" \
            PATH="$rc7_post_tmp/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
            HIMMEL_REPO="$rc7_post_tmp" \
            HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$rc7_post_go_root" STUB_SHA="$rc67_sha" \
            bash "$rc7_post_tmp/scripts/handover/merge-on-green.sh"
        ) >/dev/null 2>"$rc7_post_err"
        rc7_post_rc=$?
        if [ "$rc7_post_rc" -eq 17 ] && grep -qi "not defined" "$rc7_post_err" \
            && grep -q "phase=chief-go-symbol-missing" "$rc7_post_audit" 2>/dev/null; then
            pass
        else
            fail "RC-7 post-fix: expected exit 17 naming 'not defined' + phase=chief-go-symbol-missing, got rc=$rc7_post_rc stderr=$(cat "$rc7_post_err" 2>/dev/null)"
        fi
        rm -rf "$rc7_post_tmp" "$rc7_post_go_root"
        unset -f go_gate
    fi
    rm -f "$rc67_pre_mutant"
fi
rm -f "$RC67_TRUNC_GOGATE"

ob_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mog-owe spool.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
ob_day() { python3 -I -c 'import datetime, sys; print(datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1])))' "$1"; }
ob_d2=$(ob_day 2); ob_d3=$(ob_day 3)
ob_arrow=$'\xe2\x86\x92'
ob_proof="the live proof: owed $ob_arrow proof by $ob_d2"
ob_operator="rotate the key: owed -> operator by $ob_d3"
ob_body=$'## Ticket coverage\n- a: done\n- '"$ob_proof"$'\n- '"$ob_operator"$'\n'
ob_key=$(printf '%s-%s' HIMMEL 374)
ob_id() { printf '%s\n' "$ob_key" 91 "$1" "$2" "$3" | sha256sum | cut -d' ' -f1; }
ob_spool() { printf '%s' "$ob_tmp/$1/ts/owe-spool.jsonl"; }
ob_merge() {
    local case="$1"; shift
    mkdir -p "$ob_tmp/$case/ts" "$ob_tmp/$case/handover"
    HIMMEL_CONSOLE_DOC='' HIMMEL_CONSOLE_NAME='' MOG_TS_DIR="$ob_tmp/$case/ts" HANDOVER_DIR="$ob_tmp/$case/handover" USER_SLUG=zed \
        HANDOVER_REGISTRY="$ob_tmp/none.json" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_NUM=91 \
        run_mog "$@"
}
ob_spooled() {
    if jq -e -s --arg k "$ob_key" --arg p "$ob_proof" --arg o "$ob_operator" --arg d2 "$ob_d2" --arg d3 "$ob_d3" \
        --arg ip "$(ob_id proof "$ob_d2" "$ob_proof")" --arg io "$(ob_id operator "$ob_d3" "$ob_operator")" '
        length == 2 and all(.kind == "owed" and .schema == 1 and .key == $k and .pr == 91 and .repo == "owner/repo"
            and .metadata.wake == "complete the accepted PR #91 remainder" and .metadata.action == "next-step")
        and (.[0] | .who == "proof" and .due == $d2 and .text == $p and .identity == $ip
            and .metadata.actor == "proof" and .metadata.capability == "read-only proof worker")
        and (.[1] | .who == "operator" and .due == $d3 and .text == $o and .identity == $io and .metadata.actor == "operator")' \
        "$(ob_spool "$1")" >/dev/null 2>&1; then pass
    else fail "$2 (spool: $(cat "$(ob_spool "$1")" 2>/dev/null))"; fi
}
ob_owe_miss() {
    if jq -e -s --arg k "$ob_key" 'map(select(.event == "owe-miss" and .key == $k and .pr == "91")) | length == 1' \
        "$ob_tmp/$1/ts/status-events.jsonl" >/dev/null 2>&1; then pass
    else fail "$2 (status rows: $(cat "$ob_tmp/$1/ts/status-events.jsonl" 2>/dev/null))"; fi
}

STUB_PR_BODY="$ob_body" ob_merge a 0 "10194b: an owed partial merge with no chief doc spools its two lines"
ob_spooled a "10194b: the spool holds both owed lines with key, PR, who, due, text, identity and metadata"
assert_audit_has "10194b: the MERGED line says the two lines were spooled" "owe=spooled:2"
if [ -z "$(find "$ob_tmp/a" "$LAST_TMP" -name owed.jsonl 2>/dev/null)" ]; then pass
else fail "10194b: the merge wrote an owed ledger: $(find "$ob_tmp/a" "$LAST_TMP" -name owed.jsonl)"; fi

STUB_PR_BODY=$'Remaining: slice 2\n## Ticket coverage\n- a: done\n- '"$ob_proof"$'\n- '"$ob_operator"$'\n' \
    ob_merge b 0 "10194b: a body with one Remaining: line and two owed lines merges"
ob_spooled b "10194b: a body with one Remaining: line and two owed lines spools both"
assert_audit_has "10194b: the mixed body's MERGED line says spooled:2" "owe=spooled:2"

mkdir -p "$(ob_spool c)"
STUB_PR_BODY="$ob_body" ob_merge c 0 "10194b: an unwritable spool: the merge still exits 0"
assert_audit_has "10194b: an unwritable spool is owe=miss:2:write" "owe=miss:2:write"
ob_owe_miss c "10194b: an unwritable spool writes one owe-miss status row"
assert_err_has "10194b: an unwritable spool's stderr names the proof line" "$ob_proof"
assert_err_has "10194b: an unwritable spool's stderr names the operator line" "$ob_operator"

mkdir -p "$ob_tmp/d/ts"
printf '{"kind":"claim","schema":1}\n' > "$(ob_spool d)"
ob_sum=$(cksum < "$(ob_spool d)")
python3 -I -c 'import fcntl, os, sys, time
held = open(sys.argv[1], "a")
fcntl.flock(held, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
end = time.time() + 120
while not os.path.exists(sys.argv[3]) and time.time() < end:
    time.sleep(0.05)' "$(ob_spool d)" "$ob_tmp/d/held" "$ob_tmp/d/release" &
ob_holder=$!
ob_wait=0
while [ ! -e "$ob_tmp/d/held" ] && [ "$ob_wait" -lt 200 ]; do sleep 0.05; ob_wait=$((ob_wait + 1)); done
if [ -e "$ob_tmp/d/held" ]; then
    OWE_SPOOL_LOCK_WAIT=1 STUB_PR_BODY="$ob_body" ob_merge d 0 "10194b: a spool lock held past OWE_SPOOL_LOCK_WAIT=1: the merge still exits 0"
    assert_audit_has "10194b: a held lock is owe=miss:2:write" "owe=miss:2:write"
    if [ "$(cksum < "$(ob_spool d)")" = "$ob_sum" ]; then pass; else fail "10194b: a held lock changed the spool: $(cat "$(ob_spool d)")"; fi
    ob_owe_miss d "10194b: a held lock writes one owe-miss status row"
else
    fail "10194b setup: the lock holder never took the spool lock"
fi
: > "$ob_tmp/d/release"
wait "$ob_holder" 2>/dev/null

STUB_MERGE_FAIL=1 STUB_PR_BODY="$ob_body" ob_merge e 0 "10194b: a merge gh reported as failed but found MERGED"
if grepq "$(grep -F 'MERGED ' "$LAST_AUDIT" 2>/dev/null | grep -F 'gh-exit=')" -F 'owe=spooled:2'; then pass
else fail "10194b: the confirmed merge with a non-zero gh exit carries owe= on its MERGED line"; fi
ob_spooled e "10194b: the non-zero gh exit merge still spools both lines"

STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- '"$ob_proof"$'\n' ob_merge f 0 "10194b control: a contract-yes merge" -- --jira-transition
assert_audit_has "10194b control: a contract-yes merge is owe=none" "owe=none"
if [ -e "$(ob_spool f)" ]; then fail "10194b control: a contract-yes merge wrote the spool ($(cat "$(ob_spool f)"))"; else pass; fi
STUB_PR_BODY=$'Remaining: slice 2\n' ob_merge g 0 "10194b control: a partial merge with only a Remaining: line"
assert_audit_has "10194b control: a Remaining:-only merge is owe=none" "owe=none"
if [ -e "$(ob_spool g)" ]; then fail "10194b control: a Remaining:-only merge wrote the spool ($(cat "$(ob_spool g)"))"; else pass; fi
rm -rf "$ob_tmp"

echo
echo "merge-on-green: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
