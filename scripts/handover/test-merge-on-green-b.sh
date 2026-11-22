#!/usr/bin/env bash
# Part 2 of test-merge-on-green.sh (the Jira auto-transition rows); it sources part 1 with MOG_LIB_ONLY=1 for the harness.
# shellcheck disable=SC2034  # MOG_LIB_ONLY is read by the sourced harness
set -uo pipefail
MOG_LIB_ONLY=1
# shellcheck source=scripts/handover/test-merge-on-green.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-merge-on-green.sh"

echo "== merge-on-green.sh tests (part 2) =="
export ARMAUTOMERGE=1
export USER_SLUG=u
mog_go_fixture
# --- best-effort Jira auto-transition on merge -------------------
# No BRACKETED ticket TAG in the PR title => no Jira CLI calls, merge still
# succeeds. The trailing unbracketed ticket key satisfies the
# pre-merge title gate's JIRA_PROJECT_KEY=HIMMEL ticket pattern without
# matching the transition's own `[KEY-N]` bracket tag-extraction regex above —
# the two ticket notions are deliberately different call sites.
STUB_JIRA_BUILD=1 STUB_PR_TITLE="chore: tidy things up HIMMEL-99" \
    run_mog 0 "jira: no ticket tag skips transition"
assert_audit_has "jira: no-tag case records the skip reason" "jira-transition=skip=no-ticket-tag"
assert_jira_log_lacks "jira: no-tag case makes no jira comment call" "comment"
assert_jira_log_lacks "jira: no-tag case makes no jira transition call" "transition"

# The transition is opt-in per merge. Default (no
# --jira-transition) => the ticket's status is left alone: a Remaining comment
# and no transition call at all. This is the case that used to close an unrelated
# ticket out from under sibling in-flight work — reproduced here as the RED case
# against the pre-fix tree (it transitioned unasked; post-fix it must not).
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: default (no --jira-transition) leaves the ticket status unchanged"
assert_audit_has "jira: default case records the partial skip" "jira-transition=skip=partial key=HIMMEL-374 status-unchanged"
assert_audit_lacks "jira: default case no longer reports would-transition" "would-transition"
# A bare (partial) merge leaves the ticket's status as it is and comments the
# Remaining line taken from the PR body; it never transitions at all.
assert_jira_log_lacks "jira: partial merge makes no transition call" "index.js transition"
assert_jira_log_lacks "jira: partial merge never transitions to Done" "transition HIMMEL-374 Done"
assert_jira_log_has "jira: partial merge comments a Remaining line" "comment-body: Remaining:"
# The same ticket sitting in a later version would be folded by a completing merge (the cases below); a partial one writes no stamp.
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "8823: partial merge of a ticket in a later version"
assert_jira_log_lacks "8823: partial merge writes no stamp" "edit-writer:"
assert_jira_log_lacks "8823: partial merge makes no edit call" "index.js edit"
# A bare merge leaves the ticket open, so say so (stderr) and tell the chief doc.
assert_err_has "jira: bare merge prints the PARTIAL line" "PARTIAL HIMMEL-374: next slice not dispatched"
# A merge of a ticket held in a later unreleased version than the current one files an INTAKE
# request into the current version, whatever the merge's transition opt-in; a ticket already current, or one
# with no version, files nothing.
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a bare merge of a ticket held in a later version files an INTAKE request"
assert_jira_log_has "7641: the INTAKE goes to the current version from the held one" "release request v1.1.3 --verb INTAKE --key HIMMEL-374 --from v1.1.4 --to v1.1.3"
assert_audit_has "7641: the request rides the audit line" "intake=Q-v1.1.3-0099"
assert_jira_log_lacks "7641: the merge still never edits the ticket's versions" "edit HIMMEL-374"
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.3"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a bare merge of a ticket already in the current version files nothing"
assert_jira_log_lacks "7641: a current ticket files no request" "release request"
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"},{"name":"v1.1.3"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a bare merge of a ticket holding the current version as well files nothing"
assert_jira_log_lacks "7641: a ticket that also holds the current version files no request" "release request"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a bare merge of an unversioned ticket files nothing"
assert_jira_log_lacks "7641: an unversioned ticket files no request" "release request"
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.0"}' STUB_JIRA_VERSIONS='v1.1.3\tfalse\t2026-10-22\tfalse\nv1.1.0\tfalse\t2026-10-01\ttrue\n' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a bare merge of a ticket held in an older archived version files nothing"
assert_jira_log_lacks "7641: an archived held version is not a later one" "release request"
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_JIRA_REQUEST_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: an INTAKE request that cannot be filed still lets the merge succeed"
assert_audit_has "7641: an unfiled INTAKE request is on the audit line" "intake=failed"
mog_doc="$LAST_TMP/chief-doc.md"
printf '# chief\n\n## Results\n' > "$mog_doc"
HIMMEL_CONSOLE_DOC="$mog_doc" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: bare merge with HIMMEL_CONSOLE_DOC set"
if grep -q 'PARTIAL HIMMEL-374: next slice not dispatched' "$mog_doc"; then pass; else fail "jira: bare merge appends PARTIAL to the chief Results (doc: $(cat "$mog_doc"))"; fi
mog_doc2="$LAST_TMP/chief-doc2.md"
printf '# chief\n\n## Results\n' > "$mog_doc2"
HIMMEL_CONSOLE_DOC="$mog_doc2" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: opted-in merge with HIMMEL_CONSOLE_DOC set" -- --jira-transition
assert_err_lacks "jira: an opted-in merge prints no PARTIAL line" "PARTIAL"
if grep -q 'PARTIAL' "$mog_doc2"; then fail "jira: an opted-in merge appends no PARTIAL bullet"; else pass; fi

# A bare merge on a ticket sitting In Progress leaves it In Progress.
STUB_JIRA_BUILD=1 STUB_JIRA_STATUS="In Progress" STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
    run_mog 0 "6094: bare merge on an In Progress ticket"
assert_jira_log_lacks "6094: In Progress ticket gets no transition call" "index.js transition"
assert_jira_log_has "6094: In Progress ticket still gets the Remaining comment" "comment-body: Remaining: slice 2"
assert_audit_lacks "6094: audit never says would-transition" "would-transition"
assert_audit_has "6094: audit says the status is unchanged" "jira-transition=skip=partial key=HIMMEL-374 status-unchanged"

# The brief's dedicated `Completes ticket` line binds the merge. The
# worker doc is supplied by the caller (--worker-doc, else HIMMEL_WORKER_SESSION_DOC).
worker_no="$LAST_TMP/worker-no.md"; worker_yes="$LAST_TMP/worker-yes.md"
printf '# worker\n\n> **Completes ticket:** no\n\n## Results\n' > "$worker_no"
printf '# worker\n\n> **Completes ticket:** yes\n\n## Results\n' > "$worker_yes"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'slice 1\nRemaining: slice 2\n' \
    run_mog 0 "5843: brief says no, --jira-transition given" -- --jira-transition --worker-doc "$worker_no"
assert_err_has "5843: the ignored flag is announced" "merge-on-green: brief says completes-ticket: no; --jira-transition ignored"
assert_jira_log_lacks "5843: brief no never transitions to Done" "transition HIMMEL-374 Done"
assert_jira_log_lacks "5843: brief no leaves the ticket status alone" "index.js transition"
assert_jira_log_has "5843: brief no comments the Remaining line" "comment-body: Remaining: slice 2"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" HIMMEL_WORKER_SESSION_DOC="$worker_no" \
    run_mog 0 "5843: brief no via HIMMEL_WORKER_SESSION_DOC" -- --jira-transition
assert_jira_log_lacks "5843: HIMMEL_WORKER_SESSION_DOC binds the same way" "transition HIMMEL-374 Done"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" HIMMEL_WORKER_SESSION_DOC="$worker_no" \
    run_mog 0 "5843: --worker-doc beats HIMMEL_WORKER_SESSION_DOC" -- --jira-transition --worker-doc "$worker_yes"
assert_jira_log_has "5843: the flag value wins over the env var" "transition HIMMEL-374 Done"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: brief yes, flag missing" -- --worker-doc "$worker_yes"
assert_err_has "5843: the missing flag is warned" "brief expects the ticket to close"
assert_jira_log_lacks "5843: brief yes never transitions on its own" "transition HIMMEL-374 Done"
assert_jira_log_lacks "5843: brief yes without the flag stays partial, status untouched" "index.js transition"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: brief yes, flag given" -- --jira-transition --worker-doc "$worker_yes"
assert_jira_log_has "5843: brief yes with the flag transitions" "transition HIMMEL-374 Done"
assert_err_lacks "5843: brief yes with the flag warns nothing" "brief says completes-ticket"
printf '# worker\n\nno such line\n' > "$LAST_TMP/worker-none.md"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: worker doc without the line" -- --jira-transition --worker-doc "$LAST_TMP/worker-none.md"
assert_jira_log_has "5843: no line leaves --jira-transition working" "transition HIMMEL-374 Done"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: unreadable worker doc is a warning" -- --jira-transition --worker-doc "$LAST_TMP/absent.md"
assert_err_has "5843: unreadable worker doc is named" "cannot read worker doc"
assert_jira_log_has "5843: unreadable worker doc leaves --jira-transition working" "transition HIMMEL-374 Done"
# Only the chief's region (above `## Results`) binds: a worker appending its own
# `yes` below Results, or smuggling one in with an embedded newline, cannot widen a `no`.
printf '# worker\n\n> **Completes ticket:** no\n\n## Results\n- 10:00 LIVE — x\n> **Completes ticket:** yes\n' > "$LAST_TMP/worker-no-then-yes.md"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: header no, yes appended below Results" -- --jira-transition --worker-doc "$LAST_TMP/worker-no-then-yes.md"
assert_jira_log_lacks "5843: an appended yes does not override the header no" "transition HIMMEL-374 Done"
assert_err_has "5843: the header no still announces the ignored flag" "brief says completes-ticket: no; --jira-transition ignored"
printf '# worker\n\n> **Completes ticket:** yes\n> **Completes ticket:** no\n\n## Results\n' > "$LAST_TMP/worker-yes-then-no.md"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "5843: any no above Results wins" -- --jira-transition --worker-doc "$LAST_TMP/worker-yes-then-no.md"
assert_jira_log_lacks "5843: a no anywhere in the chief region wins" "transition HIMMEL-374 Done"
# A --worker-doc whose value is empty or another option is a usage error, not a silent drop.
run_mog 10 "5843: --worker-doc with an empty value" -- --worker-doc ""
run_mog 10 "5843: --worker-doc swallowing --dry-run" -- --worker-doc --dry-run
assert_err_has "5843: the bad --worker-doc value is named" "--worker-doc needs a path"


# The Remaining text is the PR body's own `Remaining:` line(s).
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Summary\nslice 1\nRemaining: slice 2 (the closed-unmerged handler)\n' \
    run_mog 0 "jira: partial merge quotes the PR body Remaining line"
assert_jira_log_has "jira: Remaining text is quoted in the comment" "comment-body: Remaining: slice 2 (the closed-unmerged handler)"
assert_jira_log_lacks "jira: partial merge on a Remaining body makes no transition" "index.js transition"
assert_audit_has "jira: partial merge audit records the unchanged status and comment" "jira-transition=skip=partial key=HIMMEL-374 status-unchanged comment=ok"

# A partial (contract=no) merge whose body records no remainder is REFUSED before it lands (exit 26), and the
# refusal names the missing line; nothing is merged, commented or transitioned.
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="just a summary" \
    run_mog 26 "8673: partial merge with no remainder in the body is refused"
assert_err_has "8673: the refusal names the missing Remaining: line" "has no \`Remaining:\` line and no \`<ask>: deferred -> <KEY>\` line under \`## Ticket coverage\`"
assert_audit_has "8673: the refusal is audited" "REFUSED reason=partial-remainder-missing"
assert_jira_log_lacks "8673: a refused partial merge posts no comment" "comment-body"
# a completing PR's coverage holds only done lines: run without --jira-transition it is refused, so the caller must choose
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'## Ticket coverage\n- slice one: done\n- slice two: done\n' \
    run_mog 26 "8673: a coverage of done lines only is refused without --jira-transition"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'## Summary\nslice one\n\n## Ticket coverage\n- slice one: done\n- rest: deferred \xe2\x86\x92 HIMMEL-9\n' \
    run_mog 26 "8673: a coverage line deferred wholly to another ticket is refused"
# a completing merge (--jira-transition) is not a partial one: no remainder is asked of it
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'## Ticket coverage\n- slice one: done\n' \
    run_mog 0 "8673: a completing merge needs no remainder" -- --jira-transition

# The gate's reader is the ANCHOR's scripts/lib/pr_remainder.py, never the worktree's copy, and every refusal lands before
# any merge call (also on --dry-run). Each refusal row asserts it merged nothing.
mog_rdr=$(mktemp -d "${TMPDIR:-/tmp}/mog-reader.XXXXXX")
if [ -z "$mog_rdr" ] || [ ! -d "$mog_rdr" ]; then
    fail "8673 setup: mktemp -d produced no sandbox for the stub readers"
else
    printf 'import sys\nprint("none")\n' > "$mog_rdr/says-none.py"
    printf 'import sys\n' > "$mog_rdr/says-nothing.py"
    printf 'import sys\nprint("remaining\\tslice 2")\nsys.exit(5)\n' > "$mog_rdr/fails-with-answer.py"
    # a distinct anchor whose reader says `none` refuses a body the worktree's own reader would accept
    MOG_ANCHOR_READER="$mog_rdr/says-none.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 26 "8673: the anchor's reader decides, not the worktree's"
    assert_audit_has "8673: the anchor's none is the audited reason" "REFUSED reason=partial-remainder-missing"
    assert_gh_lacks "8673: the anchor's none merged nothing" "pr merge"
    # and a branch-poisoned worktree reader never runs while the anchor's real reader accepts the body
    MOG_POISON=lib/pr_remainder.py MOG_ANCHOR_READER="$SCRIPT_DIR/../lib/pr_remainder.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 0 "8673: a poisoned worktree reader is not run, the anchor's decides"
    if [ -e "$LAST_TMP/poison.ran" ]; then fail "8673: the worktree's own reader ran inside the gate"; else pass; fi
    assert_gh_has "8673: the anchor's reader accepted, the merge happened" "pr merge"
    # a broken anchor refuses: no reader, no answer, or a reader that fails after answering
    MOG_ANCHOR_READER=ABSENT STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 26 "8673: an anchor without the reader refuses"
    assert_audit_has "8673: a missing reader is audited as unreadable" "REFUSED reason=partial-remainder-unreadable"
    assert_gh_lacks "8673: a missing reader merged nothing" "pr merge"
    MOG_ANCHOR_READER="$mog_rdr/says-nothing.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 26 "8673: a reader that answers nothing refuses"
    assert_audit_has "8673: an empty answer is audited as unreadable" "REFUSED reason=partial-remainder-unreadable"
    assert_gh_lacks "8673: an empty answer merged nothing" "pr merge"
    MOG_ANCHOR_READER="$mog_rdr/fails-with-answer.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 26 "8673: a reader that exits non-zero refuses even with an answer"
    assert_audit_has "8673: a failing reader is audited as unreadable" "REFUSED reason=partial-remainder-unreadable"
    assert_gh_lacks "8673: a failing reader merged nothing" "pr merge"
    printf 'import sys\nprint("remaining\\tslice 2")\n' > "$mog_rdr/no-units.py"
    MOG_ANCHOR_READER="$mog_rdr/no-units.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
        run_mog 26 "10194: an anchor reader with no --units answer refuses"
    assert_err_has "10194: the refusal names the --units read" "--units gave no chief-owed answer"
    assert_gh_lacks "10194: the no-units refusal merged nothing" "pr merge"
    rm -rf "$mog_rdr"
fi
# a body read where gh exits 3 (the old reader-absent code) is a refused read, never a skipped check
STUB_BODY_RC=3 STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
    run_mog 26 "8673: a body read where gh exits 3 is refused"
assert_audit_has "8673: the failed read is audited as unreadable" "REFUSED reason=partial-remainder-unreadable"
assert_gh_lacks "8673: the failed read merged nothing" "pr merge"
STUB_BODY_RC=1 STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
    run_mog 26 "8673: a body read where gh exits 1 is refused"
assert_gh_lacks "8673: the exit-1 read merged nothing" "pr merge"
# the refusals name the missing line and merge nothing, on a real merge and on --dry-run
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="just a summary" \
    run_mog 26 "8673: no remainder refuses before the merge call"
assert_gh_lacks "8673: the refused partial merge never called pr merge" "pr merge"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="just a summary" \
    run_mog 26 "8673: no remainder refuses on --dry-run too" -- --dry-run
assert_audit_has "8673: the dry-run refusal is audited" "REFUSED reason=partial-remainder-missing"
assert_audit_lacks "8673: the dry-run refusal wrote no would-merge line" "DRYRUN would-merge"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'## Ticket coverage\n- slice one: done\n' \
    run_mog 26 "8673: a coverage of done lines refuses before the merge call"
assert_gh_lacks "8673: the done-only refusal never called pr merge" "pr merge"
# the brief's completes-ticket: no binds even when --jira-transition is given
printf '# worker\n\n> **Completes ticket:** no\n\n## Results\n' > "$LAST_TMP/worker-no-8673.md"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="just a summary" \
    run_mog 26 "8673: a brief that says no is a partial merge even with --jira-transition" -- --jira-transition --worker-doc "$LAST_TMP/worker-no-8673.md"
assert_gh_lacks "8673: the brief-no refusal never called pr merge" "pr merge"
s3_body=$'## Ticket coverage\n- a: done\n- b: deferred \xe2\x86\x92 HIMMEL-2\n'
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: x" run_mog 0 "9561 S3 setup: a scratch run to own the brief path"
s3_doc="$LAST_TMP/worker-no-s3.md"
printf '# worker\n\n> **Completes ticket:** no\n\n## Results\n' > "$s3_doc"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 26 "9561 S3: brief no with a handed-off remainder is refused" -- --worker-doc "$s3_doc"
assert_err_has "9561 S3: the refusal names the other key" "HIMMEL-2"
assert_err_has "9561 S3: the refusal names the brief line" "Completes ticket: no"
assert_err_has "9561 S3: the refusal names the doc path" "$s3_doc"
assert_err_has "9561 S3: the refusal offers a Remaining: line" "Remaining:"
assert_audit_has "9561 S3: the refusal is audited" "REFUSED reason=partial-remainder-handed-off"
assert_gh_lacks "9561 S3: the handed-off refusal never called pr merge" "pr merge"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 26 "9561 S3: the brief's no beats --jira-transition on a handed-off remainder" -- --jira-transition --worker-doc "$s3_doc"
assert_err_has "9561 S3: the flag row still names the brief line" "Completes ticket: no"
assert_gh_lacks "9561 S3: the flag row never called pr merge" "pr merge"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 26 "9561 S3: no brief line and no flag refuses a handed-off remainder"
assert_err_has "9561 S3: the no-brief refusal names --jira-transition" "--jira-transition"
assert_err_has "9561 S3: the no-brief refusal names the other key" "HIMMEL-2"
assert_audit_has "9561 S3: the no-brief refusal is audited" "REFUSED reason=partial-remainder-handed-off"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'Remaining: x\n\n## Ticket coverage\n- a: done\n- b: deferred \xe2\x86\x92 HIMMEL-2\n' \
    run_mog 0 "9561 S3 control: a Remaining: line beside a deferred line still merges" -- --worker-doc "$s3_doc"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="just a summary" \
    run_mog 26 "9561 S3 control: a none body keeps the missing-remainder refusal" -- --worker-doc "$s3_doc"
assert_audit_has "9561 S3 control: a none body is still audited as missing" "REFUSED reason=partial-remainder-missing"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 0 "9561 S3 control: --jira-transition with no brief no line merges a handed-off body" -- --jira-transition
# 9561 S4a: an `owed → chief|operator by <date>` coverage line is a recorded remainder; the merge rows carry what it said
s4_day() { python3 -I -c 'import datetime, sys; print(datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1])))' "$1"; }
s4_d2=$(s4_day 2); s4_d3=$(s4_day 3); s4_d4=$(s4_day 4)
s4_arrow=$'\xe2\x86\x92'
s4_body=$'## Ticket coverage\n- a: done\n- live proof: owed '"$s4_arrow"' operator by '"$s4_d2"$'\n'
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s4_body" \
    run_mog 0 "9561 S4a: a coverage line owed to the operator by a date is a recorded remainder, the merge lands"
assert_gh_has "9561 S4a: the owed merge called pr merge" "pr merge"
assert_status_row "9561 S4a: the final merge row carries remainder=owed owed=operator owed_due=<date>" \
    '.event == "merge" and .key == "HIMMEL-374" and .contract == "no" and .result == "noop" and .remainder == "owed" and .owed == "operator" and .owed_due == "'"$s4_d2"'"'
assert_status_row "9561 S4a: the pre-merge row carries the owed fields too" \
    '.event == "merge" and .stage == "pre-merge" and .remainder == "owed" and .owed == "operator" and .owed_due == "'"$s4_d2"'"'
assert_status_row "9561 S4a: the pre-jira row carries the owed fields too" \
    '.event == "merge" and .stage == "pre-jira" and .remainder == "owed" and .owed == "operator" and .owed_due == "'"$s4_d2"'"'
# every merge row of a contract=no merge carries remainder=; a contract=yes row carries none of the three fields
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: x" run_mog 0 "9561 S4a: a Remaining: merge writes its rows"
if jq -e -s '[.[] | select(.event == "merge" and .contract == "no")] | length >= 3 and all(.remainder == "remaining" and (has("owed") | not) and (has("owed_due") | not))' \
    "$LAST_TMP/ts/status-events.jsonl" >/dev/null 2>&1; then pass
else fail "9561 S4a: every contract=no row of a Remaining: merge carries remainder=remaining and no owed fields (rows: $(cat "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null))"; fi
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s4_body" run_mog 0 "9561 S4a: an owed merge writes its rows"
if jq -e -s '[.[] | select(.event == "merge" and .contract == "no")] | length >= 3 and all(.remainder == "owed" and .owed == "operator" and .owed_due == "'"$s4_d2"'")' \
    "$LAST_TMP/ts/status-events.jsonl" >/dev/null 2>&1; then pass
else fail "9561 S4a: every contract=no row of an owed merge carries remainder=owed owed=operator owed_due (rows: $(cat "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null))"; fi
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'## Ticket coverage\n- slice one: done\n' \
    run_mog 0 "9561 S4a: a completing merge writes its rows" -- --jira-transition
if jq -e -s '[.[] | select(.event == "merge" and .contract == "yes")] | length >= 3 and all(has("remainder") == false and has("owed") == false and has("owed_due") == false)' \
    "$LAST_TMP/ts/status-events.jsonl" >/dev/null 2>&1; then pass
else fail "9561 S4a: a contract=yes row carries none of remainder, owed and owed_due (rows: $(cat "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null))"; fi
# the S3 refusals offer the owed line too
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 26 "9561 S4a: the brief-no handed-off refusal offers an owed line" -- --worker-doc "$s3_doc"
assert_err_has "9561 S4a: the brief-no refusal ends with the owed clause" "or an owed $s4_arrow line"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s3_body" \
    run_mog 26 "9561 S4a: the no-brief handed-off refusal offers an owed line"
assert_err_has "9561 S4a: the no-brief refusal ends with the owed clause" "or an owed $s4_arrow line"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- the INTAKE age (tick.sh, held by another worker): owed '"$s4_arrow"' chief by '"$s4_d2"$'\n' \
    run_mog 26 "10194: an owed-to-chief line naming a repo file is refused"
assert_err_has "10194: the refusal names the path" "tick.sh"
assert_err_has "10194: the refusal says to write it as Remaining:" "Remaining:"
assert_audit_has "10194: the refusal is audited" "REFUSED reason=partial-owed-names-path"
assert_gh_lacks "10194: the refused merge never called pr merge" "pr merge"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- part B under scripts/handover/chief-kit/ held for the chief: owed '"$s4_arrow"' chief by '"$s4_d2"$'\n' \
    run_mog 26 "10194: an owed-to-chief line naming a repo directory is refused"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- run sudo bash scripts/lib/afk-sudo/install.sh on the station: owed '"$s4_arrow"' operator by '"$s4_d2"$'\n' \
    run_mog 0 "10194 control: an owed-to-operator line naming a repo path merges"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- set enabled in /etc/himmel/afk-sudo.json and ~/.codex/config.toml on the VM: owed '"$s4_arrow"' chief by '"$s4_d2"$'\n' \
    run_mog 26 "10220: absolute paths alone do not make a step chief-only"
assert_err_has "10220: the refusal gives proof routing advice" "owed → proof"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- run the live proof on the station: owed -> chief by '"$s4_d2"$'\n' \
    run_mog 26 "10220: an executable station proof is not chief-only"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY=$'## Ticket coverage\n- sign the spec: owed -> chief by '"$s4_d2"$'\n' \
    run_mog 0 "10220: a chief signature remains allowed"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'Remaining: the INTAKE age in tick.sh\n' \
    run_mog 0 "10194 control: a Remaining: line naming a repo path merges"
s10194_dir=$(mktemp -d "${TMPDIR:-/tmp}/mog-10194.XXXXXX")
if [ -z "$s10194_dir" ] || [ ! -d "$s10194_dir" ]; then
    fail "10194b setup: mktemp -d produced no chief bucket"
else
    printf '# chief\n\n## Results\n' > "$s10194_dir/chief.md"
    HIMMEL_CONSOLE_DOC="$s10194_dir/chief.md" HIMMEL_CONSOLE_NAME=AJ-chief STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- the live proof: owed '"$s4_arrow"' proof by '"$s4_d2"$'\n- rotate the key: owed -> operator by '"$s4_d3"$'\n' \
        run_mog 0 "10194b: a partial merge with two owed lines and a chief doc set merges"
    if jq -e -s --arg k "$(printf '%s-%s' HIMMEL 374)" 'length == 2 and all(.kind == "owed" and .key == $k and .pr == 77)
        and (.[0] | .who == "proof" and .due == "'"$s4_d2"'" and .text == "the live proof: owed → proof by '"$s4_d2"'")
        and (.[1] | .who == "operator" and .due == "'"$s4_d3"'" and .text == "rotate the key: owed -> operator by '"$s4_d3"'")' \
        "$LAST_TMP/ts/owe-spool.jsonl" >/dev/null 2>&1; then pass
    else fail "10194b: with a chief doc set, the lines still go to the spool (spool: $(cat "$LAST_TMP/ts/owe-spool.jsonl" 2>/dev/null))"; fi
    if [ -e "$s10194_dir/owed.jsonl" ]; then fail "10194b: with a chief doc set, no ledger row is written ($(cat "$s10194_dir/owed.jsonl"))"; else pass; fi
    assert_audit_has "10194b: the chief-doc merge is owe=spooled:2" "owe=spooled:2"
    rm -f "$s10194_dir/owed.jsonl"
    HIMMEL_CONSOLE_DOC="$s10194_dir/chief.md" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'Remaining: slice 2\n' \
        run_mog 0 "10194b control: a Remaining: merge"
    if [ -e "$s10194_dir/owed.jsonl" ] || [ -e "$LAST_TMP/ts/owe-spool.jsonl" ]; then fail "10194b control: a Remaining: merge writes no owe row"; else pass; fi
    HIMMEL_CONSOLE_DOC="$s10194_dir/chief.md" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        STUB_PR_BODY=$'## Ticket coverage\n- a: done\n- the live proof: owed '"$s4_arrow"' proof by '"$s4_d2"$'\n' \
        run_mog 0 "10194b control: a completing merge with an owed line" -- --jira-transition
    if [ -e "$s10194_dir/owed.jsonl" ] || [ -e "$LAST_TMP/ts/owe-spool.jsonl" ]; then fail "10194b control: a completing merge writes no owe row"; else pass; fi
    printf 'import os, sys\nif "--owed-lines" in sys.argv:\n    sys.exit(3)\nos.execv(sys.executable, [sys.executable, "-I", %s] + sys.argv[1:])\n' \
        "'$(cd "$SCRIPT_DIR/../lib" && pwd)/pr_remainder.py'" > "$s10194_dir/owed-lines-fail.py"
    s10194_owed=$'## Ticket coverage\n- a: done\n- the live proof: owed '"$s4_arrow"' proof by '"$s4_d2"$'\n'
    MOG_ANCHOR_READER="$s10194_dir/owed-lines-fail.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="$s10194_owed" \
        run_mog 0 "10194b: a failing reader: exit 0"
    assert_audit_has "10194b: a failing reader is owe=unread" "owe=unread"
    if jq -e -s --arg k "$(printf '%s-%s' HIMMEL 374)" 'length == 1 and .[0].kind == "unread" and .[0].key == $k and .[0].pr == 77 and .[0].repo == "owner/repo"' \
        "$LAST_TMP/ts/owe-spool.jsonl" >/dev/null 2>&1; then pass
    else fail "10194b: a failing reader spools one unread row (spool: $(cat "$LAST_TMP/ts/owe-spool.jsonl" 2>/dev/null))"; fi
    mkdir -p "$s10194_dir/ts-bad/owe-spool.jsonl"
    MOG_TS_DIR="$s10194_dir/ts-bad" MOG_ANCHOR_READER="$s10194_dir/owed-lines-fail.py" STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        STUB_PR_BODY="$s10194_owed" run_mog 0 "10194b: a failing reader and an unwritable spool: exit 0"
    assert_audit_has "10194b: a failing reader and an unwritable spool is owe=miss:?:write" "owe=miss:?:write"
    assert_err_has "10194b: the unwritten unread row names the PR on stderr" "the owed lines of HIMMEL-374 PR #77 were not spooled"
    MOG_TS_DIR="$s10194_dir/ts-bad" assert_status_row "10194b: the unwritten unread row writes one owe-miss status row" \
        '.event == "owe-miss" and .key == "'"$(printf '%s-%s' HIMMEL 374)"'" and .pr == "77"'
    rm -rf "$s10194_dir"
fi
# the reader's precedence: remaining > owed > handed-off > none; several owed lines answer the earliest date
s4_read() { printf '%s' "$1" | python3 -I "$SCRIPT_DIR/../lib/pr_remainder.py" HIMMEL-374 2>/dev/null; }
s4_ans=$(s4_read "$(printf 'Remaining: x\n\n## Ticket coverage\n- a: done\n- b: owed %s operator by %s\n' "$s4_arrow" "$s4_d2")")
case "$s4_ans" in remaining$'\t'*) pass ;; *) fail "9561 S4a: a Remaining: line beats an owed line (reader said: $s4_ans)" ;; esac
case "$s4_ans" in remaining$'\t'*"owed $s4_arrow operator by $s4_d2"*) pass ;; *) fail "9561 S4a: a Remaining: line keeps a valid owed line in its text, so the breadcrumb names the owner and date (reader said: $s4_ans)" ;; esac
s4_ans=$(s4_read "$(printf '## Ticket coverage\n- a: owed %s chief by %s\n- b: owed %s operator by %s\n' "$s4_arrow" "$s4_d4" "$s4_arrow" "$s4_d3")")
case "$s4_ans" in owed$'\t'operator$'\t'"$s4_d3"$'\t'*) pass ;; *) fail "9561 S4a: two owed lines answer the earlier date and its who (reader said: $s4_ans)" ;; esac
s4_ans=$(s4_read "${s3_body}$(printf -- '- c: owed %s chief by %s\n' "$s4_arrow" "$s4_d2")")
case "$s4_ans" in owed$'\t'chief$'\t'"$s4_d2"$'\t'*) pass ;; *) fail "9561 S4a: an owed line beats a deferred-to-another-ticket line (reader said: $s4_ans)" ;; esac
s4_own=$(printf '%s-%s' HIMMEL 374)  # the ticket key the run's title names, built so no literal key sits in added text
s4_ans=$(s4_read "$(printf '## Ticket coverage\n- a: owed %s chief by %s\n- b: deferred %s %s\n' "$s4_arrow" "$s4_d2" "$s4_arrow" "$s4_own")")
case "$s4_ans" in remaining$'\t'*) pass ;; *) fail "9561 S4a: a deferred line naming the ticket itself stays remaining work and beats an owed line (reader said: $s4_ans)" ;; esac
s4_ans=$(s4_read "$(printf '## Ticket coverage\n- a: done\n### More\n- b: owed %s chief by 2099-01-01\n' "$s4_arrow")")
case "$s4_ans" in remaining$'\t'*) pass ;; *) fail "9561 S4a: an owed line under a ### heading is never owed, so it cannot dodge ready-check's window (reader said: $s4_ans)" ;; esac
s4_ans=$(s4_read "$(printf '## Ticket coverage\n- a: done\nowed %s chief by 2099-01-01\n' "$s4_arrow")")
case "$s4_ans" in remaining$'\t'*) pass ;; *) fail "9561 S4a: an owed line that is not a list line is never owed (reader said: $s4_ans)" ;; esac
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    STUB_PR_BODY="$(printf '## Ticket coverage\n- a: owed %s operator by %s\r- c: done\n' "$s4_arrow" "$s4_d2")" \
    run_mog 0 "9561 S4a: a lone CR in the body reads as ready-check reads it (joined), so the owed line is not owed"
assert_status_row "9561 S4a: a lone CR joined the owed line to the next, so the row says remaining" \
    '.event == "merge" and .stage == "pre-merge" and .remainder == "remaining" and (has("owed") | not)'
# a title naming no ticket is not a partial merge of one: no remainder is asked of it
STUB_PR_BODY="just a summary" run_mog 0 "8673: a title with no ticket key asks for no remainder"
assert_gh_has "8673: the keyless title merged" "pr merge"
# the breadcrumb posts what the reader found
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY=$'slice 1\nRemaining: slice 2\n\n## Ticket coverage\n- rest: deferred -> HIMMEL-9\n' \
    run_mog 0 "8673: a Remaining line beside a deferred line is one remainder"
assert_jira_log_has "8673: the breadcrumb posts both" "comment-body: Remaining: slice 2; rest: deferred -> HIMMEL-9"

# A ticket already Done is left alone by a partial merge; an Epic never moves.
# A bare merge never transitions, so the next three rows (Done, Epic, failed
# comment) pass trivially now; they stay as guards against a transition coming back.
STUB_JIRA_BUILD=1 STUB_JIRA_STATUS=Done STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: partial merge leaves an already-Done ticket alone"
assert_jira_log_lacks "jira: Done ticket gets no transition" "transition"
STUB_JIRA_BUILD=1 STUB_JIRA_ISSUE_TYPE=Epic STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: partial merge never moves an Epic"
assert_jira_log_lacks "jira: Epic partial merge gets no transition" "transition"

# A comment that fails to post means no breadcrumb: do not move the ticket.
STUB_JIRA_BUILD=1 STUB_JIRA_COMMENT_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: partial merge with a failed comment"
assert_jira_log_lacks "jira: failed comment means no To Do transition" "transition"

# A PR closed unmerged gets a comment, and the status funnel re-derives the
# ticket (its open PRs, its owner); merge-on-green writes no status itself.
STUB_JIRA_BUILD=1 STUB_STATE=CLOSED STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed-unmerged PR fires the closed event"
assert_jira_log_lacks "jira: closed PR makes no transition itself" "index.js transition"
assert_jira_log_has "jira: closed PR comments why" "comment-body: PR #77"
assert_funnel_has "jira: closed PR fires the funnel's closed event" "HIMMEL-374 --event closed --pr 77"
STUB_JIRA_BUILD=1 STUB_STATE=CLOSED STUB_JIRA_ISSUE_TYPE=Epic STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed-unmerged PR on an Epic"
assert_funnel_not_called "jira: an Epic's closed PR fires no event"
assert_jira_log_lacks "jira: an Epic's closed PR gets no comment" "comment-body:"

# A partial merge on a ticket already in To Do still posts its Remaining comment.
STUB_JIRA_BUILD=1 STUB_JIRA_STATUS="To Do" STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
    run_mog 0 "jira: partial merge on a To Do ticket still comments"
assert_jira_log_has "jira: To Do ticket still gets the Remaining comment" "comment-body: Remaining: slice 2"
assert_jira_log_lacks "jira: To Do ticket needs no transition" "index.js transition"
STUB_JIRA_BUILD=1 STUB_JIRA_STATUS="" STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" STUB_PR_BODY="Remaining: slice 2" \
    run_mog 0 "jira: partial merge with an unreadable status touches nothing"
assert_jira_log_lacks "jira: unreadable status gets no comment" "comment-body:"
assert_jira_log_lacks "jira: unreadable status gets no transition" "index.js transition"
STUB_JIRA_BUILD=1 STUB_STATE=MERGED STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: an already-MERGED PR is not treated as closed-unmerged"
assert_jira_log_lacks "jira: MERGED NOOP makes no transition" "transition"

# Ticket tag present + a built Jira CLI + matching config + --jira-transition
# => comment THEN transition, in that order (comment-then-transition
# discipline), merge exit 0. Opting in is what makes this fire at all.
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: --jira-transition runs comment then transition" -- --jira-transition
assert_audit_has "jira: opted-in case records success" "jira-transition=ok key=HIMMEL-374 status=Done"
assert_jira_log_has "jira: comment call carries the extracted key" "comment HIMMEL-374"
assert_jira_log_has "jira: transition call carries the key + configured status" "transition HIMMEL-374 Done"
jira_comment_ln=$(grep -n 'dist/index.js comment ' "$LAST_JIRA_LOG" | head -1 | cut -d: -f1)
jira_transition_ln=$(grep -n 'dist/index.js transition ' "$LAST_JIRA_LOG" | head -1 | cut -d: -f1)
if [ -n "$jira_comment_ln" ] && [ -n "$jira_transition_ln" ] && [ "$jira_comment_ln" -lt "$jira_transition_ln" ]; then
    pass
else
    fail "jira: comment precedes transition (comment@${jira_comment_ln:-none} transition@${jira_transition_ln:-none})"
fi

# A status the merge wrote marks the chief's FOCUS page dirty (focus-state
# dirty=, plus focus-state.again); a failing mark changes neither the exit nor the result.
HIMMEL_CONSOLE_DOC=/nonexistent/chief.md STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "focus: a failing mark-dirty never fails the merge" -- --jira-transition
assert_audit_has "focus: the transition is still recorded ok" "jira-transition=ok key=HIMMEL-374 status=Done"
MOG_FOCUS_DOC="$MOG_SUITE_TMP/focus-chief/chief.md"
mkdir -p "${MOG_FOCUS_DOC%/*}"; printf '# chief\nfocus-version: v1.1.3\n' > "$MOG_FOCUS_DOC"
printf 'status=ok\ngen=1\ndirty=\n' > "${MOG_FOCUS_DOC%/*}/focus-state"
# The mark follows the fixVersion fold, so a rebuild it starts sees the folded version:
# the stub CLI records whether the page was already dirty when the fold ran.
# shellcheck disable=SC2016 # $JIRA_LOG, $* and $@ must reach the stub FILE unexpanded
mog_focus_order_stub() {
    mv "$1/bin/node" "$1/bin/node.real"
    printf '#!/usr/bin/env bash\ncase "$*" in *" edit HIMMEL-374 --fix-version"*) grep -q "^dirty=." "%s" && echo "fold: dirty" >> "$JIRA_LOG" ;; esac\nexec "%s" "$@"\n' \
        "${MOG_FOCUS_DOC%/*}/focus-state" "$1/bin/node.real" > "$1/bin/node"
    chmod +x "$1/bin/node"
}
HIMMEL_CONSOLE_DOC="$MOG_FOCUS_DOC" MOG_ANCHOR_SETUP=mog_focus_order_stub STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' \
    STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" run_mog 0 "focus: a merge that folds the fixVersion" -- --jira-transition
if grep -q '^dirty=[0-9]' "${MOG_FOCUS_DOC%/*}/focus-state" && grep -q '^status=ok$' "${MOG_FOCUS_DOC%/*}/focus-state" \
    && [ -s "${MOG_FOCUS_DOC%/*}/focus-state.again" ]; then pass
else fail "focus: the transition marks the FOCUS page dirty ($(tr '\n' '|' < "${MOG_FOCUS_DOC%/*}/focus-state"))"; fi
if grep -q 'index.js edit HIMMEL-374 --fix-version' "$LAST_JIRA_LOG" && ! grep -q '^fold: dirty$' "$LAST_JIRA_LOG"; then pass
else fail "focus: the mark follows the fixVersion fold ($(grep -E 'fold: dirty|index\.js edit HIMMEL-374 ' "$LAST_JIRA_LOG" | tr '\n' '|'))"; fi
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "focus: a merge with no chief doc" -- --jira-transition
if [ -n "$(find "$LAST_TMP" -name 'focus-state*' 2>/dev/null)" ]; then fail "focus: with no chief doc nothing is marked"; else pass; fi

# A failing Jira transition must never fail the merge itself (best-effort),
# even when opted in.
STUB_JIRA_BUILD=1 STUB_JIRA_TRANSITION_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: opted-in failed transition does not fail the merge, and is surfaced" -- --jira-transition
assert_audit_has "jira: failed-transition case records the failure" "jira-transition=failed key=HIMMEL-374 status=Done"
assert_status_row "jira: a failed Done write logs a completes=yes miss" \
    '.event == "merge" and .key == "HIMMEL-374" and .contract == "yes" and .result == "miss" and .stage == "transition"'

# Every merge outcome is a status-events row, and only a completes=no merge
# hands the ticket to the funnel (a completes=yes merge owns its Done write).
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "status: opted-in merge" -- --jira-transition
assert_status_row "status: a Done write logs moved with completes=yes" \
    '.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .contract == "yes" and .result == "moved"'
assert_funnel_not_called "status: a completes=yes merge fires no funnel event"
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "status: partial merge"
assert_status_row "status: a partial merge logs noop with completes=no" \
    '.event == "merge" and .key == "HIMMEL-374" and .contract == "no" and .result == "noop"'
assert_funnel_has "status: a partial merge fires the funnel's merge event" "HIMMEL-374 --event merge --pr 77 --head abc123def456"
assert_funnel_has "status: the funnel reads the merged PR's repository" "--repo owner/repo"
STUB_JIRA_BUILD=1 STUB_JIRA_COMMENT_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "status: partial merge with a failed comment"
assert_status_row "status: a partial merge whose comment failed is a miss" \
    '.event == "merge" and .contract == "no" and .result == "miss" and .stage == "comment"'
STUB_JIRA_BUILD=1 STUB_PR_TITLE="chore: tidy things up HIMMEL-99" \
    run_mog 0 "status: no ticket tag"
assert_status_row "status: an early return is classified" '.event == "merge" and .result == "skip" and .stage == "no-ticket-tag"'
assert_funnel_not_called "status: no key, no funnel event"
STUB_JIRA_BUILD=1 STUB_JIRA_ISSUE_TYPE=Epic STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "status: Epic" -- --jira-transition
assert_status_row "status: an Epic is a classified skip" '.event == "merge" and .result == "skip" and .stage == "never-touch-type"'
# A run killed in the Jira step still leaves the merge's contract row (written once gh reports MERGED).
STUB_JIRA_BUILD=1 STUB_JIRA_KILL_RUN=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 137 "status: a partial merge killed in the Jira step"
assert_status_row "status: a partial merge killed in the Jira step still leaves its completes=no row" \
    '.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .contract == "no" and .result == "pending"'
STUB_JIRA_BUILD=1 STUB_JIRA_KILL_RUN=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 137 "status: an opted-in merge killed in the Jira step" -- --jira-transition
assert_status_row "status: an opted-in merge killed in the Jira step still leaves its completes=yes row" \
    '.event == "merge" and .key == "HIMMEL-374" and .contract == "yes" and .result == "pending"'
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "status: a finished merge keeps both rows, the Jira outcome last" -- --jira-transition
assert_status_row "status: a finished merge leaves the pre-Jira row too" \
    '.event == "merge" and .contract == "yes" and .result == "pending" and .stage == "pre-jira"'
# The pending row is written BEFORE the merge call, so a run killed right after GitHub
# merges still leaves the record. A row for a PR that did not merge is marked result=not-merged (no contract).
w0_title="feat(jira): [HIMMEL-374] reconciler"
STUB_JIRA_BUILD=1 STUB_MERGE_SNAPSHOT=1 STUB_PR_TITLE="$w0_title" run_mog 0 "W0: the row exists when the merge call runs"
if jq -e -s 'map(select(.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .repo == "owner/repo" and .contract == "no" and .result == "pending" and .stage == "pre-merge")) | length == 1' \
    "$LAST_GH_LOG.rows-at-merge" >/dev/null 2>&1; then pass
else fail "W0: the pending pre-merge row is in the log before gh pr merge runs (rows then: $(cat "$LAST_GH_LOG.rows-at-merge" 2>/dev/null))"; fi
STUB_JIRA_BUILD=1 STUB_MERGE_SNAPSHOT=1 STUB_PR_TITLE="$w0_title" run_mog 0 "W0: an opted-in merge" -- --jira-transition
if jq -e -s 'map(select(.event == "merge" and .contract == "yes" and .result == "pending" and .stage == "pre-merge")) | length == 1' \
    "$LAST_GH_LOG.rows-at-merge" >/dev/null 2>&1; then pass
else fail "W0: the pre-merge row of an opted-in merge says contract=yes (rows then: $(cat "$LAST_GH_LOG.rows-at-merge" 2>/dev/null))"; fi
STUB_JIRA_BUILD=1 STUB_MERGE_KILL=before STUB_PR_TITLE="$w0_title" run_mog 137 "W0: killed before the merge lands"
assert_status_row "W0: a run killed before the merge leaves its pre-merge row" \
    '.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .contract == "no" and .result == "pending" and .stage == "pre-merge"'
STUB_JIRA_BUILD=1 STUB_MERGE_KILL=after STUB_PR_TITLE="$w0_title" run_mog 137 "W0: killed right after the merge landed"
assert_status_row "W0: a run killed right after the merge still leaves its pending row" \
    '.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .result == "pending" and .stage == "pre-merge"'
STUB_MERGE_POLICY_REFUSED=1 STUB_PR_TITLE="$w0_title" run_mog 18 "W0: GitHub refused the merge"
assert_status_row "W0: a refused merge is marked not-merged for the same pr and head, with no contract" \
    '.event == "merge" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .result == "not-merged" and (has("contract") | not)'
STUB_MERGE_FAIL=1 STUB_POST_STATE=CLOSED STUB_PR_TITLE="$w0_title" run_mog 15 "W0: the merge failed and the PR is closed"
assert_status_row "W0: a failed merge of a PR that did not merge is marked not-merged" \
    '.event == "merge" and .pr == "77" and .head == "abc123def456" and .result == "not-merged"'
STUB_MERGE_FAIL=1 STUB_POST_STATE=OPEN STUB_PR_TITLE="$w0_title" run_mog 15 "W0: the merge outcome is unproven"
if jq -e -s 'map(select(.result == "not-merged")) | length == 0' "$LAST_TMP/ts/status-events.jsonl" >/dev/null 2>&1; then pass
else fail "W0: an unproven (still OPEN) merge is not marked not-merged (rows: $(cat "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null))"; fi
w0_file="$(mktemp "${TMPDIR:-/tmp}/mog-w0-notdir.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
MOG_TS_DIR="$w0_file" STUB_JIRA_BUILD=1 STUB_PR_TITLE="$w0_title" run_mog 0 "W0: an unwritable status log does not block the merge"
assert_gh_has "W0: the merge still ran with an unwritable status log" "pr merge 77"
rm -f "$w0_file"
# The Done write waits on the funnel's per-key lock: a held lock defers it, and
# the deferral is a completes=yes row the derive reads as done-pending. Both
# lock cases need a flock binary; without one (stock macOS) the write runs unlocked.
if command -v flock >/dev/null 2>&1; then
    mog_ts="$(mktemp -d "${TMPDIR:-/tmp}/mog-ts.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
    mkdir -p "$mog_ts/status-locks"; : > "$mog_ts/status-locks/HIMMEL-374"
    MOG_TS_DIR="$mog_ts" MOG_WRAP="flock $mog_ts/status-locks/HIMMEL-374" TICKET_STATUS_LOCK_WAIT=1 \
        STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        run_mog 0 "status: Done write under a held status lock" -- --jira-transition
    assert_audit_has "status: a held lock defers the Done write" "jira-transition=deferred stage=lock key=HIMMEL-374"
    assert_jira_log_lacks "status: a deferred Done write makes no transition" "index.js transition"
    MOG_TS_DIR="$mog_ts" assert_status_row "status: the deferral is a completes=yes row" \
        '.event == "merge" and .contract == "yes" and .result == "deferred" and .stage == "lock"'
    rm -rf "$mog_ts"
    # The completes=yes merge row lands while the per-key lock is still held, so a
    # WRAPPED event queued behind it already reads done-pending.
    ts_probe="$(mktemp -d "${TMPDIR:-/tmp}/mog-ts-probe.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
    cp "$SCRIPT_DIR/../lib/ticket-status.sh" "$ts_probe/ticket-status.sh"
    cat >>"$ts_probe/ticket-status.sh" <<'EOF'
status_event() {
    local a k=""
    for a in "$@"; do case "$a" in key=*) k=${a#key=} ;; esac; done
    if flock -n "$(ts_state_dir)/status-locks/$k" true; then echo free; else echo held; fi >> "$(ts_state_dir)/probe.log"
}
EOF
    mog_ts="$(mktemp -d "${TMPDIR:-/tmp}/mog-ts.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
    TS_LIB_SRC="$ts_probe/ticket-status.sh" MOG_TS_DIR="$mog_ts" STUB_JIRA_BUILD=1 STUB_JIRA_TRANSITION_FAIL=1 \
        STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
        run_mog 0 "status: failed Done write with a lock probe" -- --jira-transition
    if [ "$(tail -n 1 "$mog_ts/probe.log" 2>/dev/null)" = held ]; then pass
    else fail "status: the completes=yes merge row is written under the status lock (probe: $(cat "$mog_ts/probe.log" 2>/dev/null))"; fi
    rm -rf "$mog_ts" "$ts_probe"
fi

# Never touch Epic/Story (standing project invariant) — the merge hook has no
# classifyTicket call in its path, so it must check the issue type itself.
# This skip fires before the opt-in gate, so it applies regardless of the flag.
STUB_JIRA_BUILD=1 STUB_JIRA_ISSUE_TYPE=Epic STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: Epic ticket is never transitioned" -- --jira-transition
assert_audit_has "jira: Epic case records the never-touch skip" "jira-transition=skip=never-touch-type key=HIMMEL-374 type=Epic"
assert_jira_log_lacks "jira: Epic case makes no jira comment call" "comment"
assert_jira_log_lacks "jira: Epic case makes no jira transition call" "transition"

# A Story is NOT skipped: a merged PR that completes a Story must
# close it, so it transitions like a Task when --jira-transition is passed.
STUB_JIRA_BUILD=1 STUB_JIRA_ISSUE_TYPE=Story STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: Story ticket is transitioned on --jira-transition" -- --jira-transition
assert_audit_has "jira: Story case records success" "jira-transition=ok key=HIMMEL-374 status=Done"
assert_jira_log_has "jira: Story case comments" "comment HIMMEL-374"
assert_jira_log_has "jira: Story case transitions" "transition HIMMEL-374 Done"

STUB_JIRA_BUILD=1 STUB_JIRA_ISSUE_TYPE=Story STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: Story without --jira-transition leaves the status unchanged"
assert_audit_has "jira: Story bare merge records the partial skip" "jira-transition=skip=partial key=HIMMEL-374 status-unchanged"
assert_jira_log_lacks "jira: Story bare merge never transitions to Done" "transition HIMMEL-374 Done"

# A comment that fails to post leaves no evidence breadcrumb — skip the
# transition rather than close the ticket silently. Requires opt-in to reach
# the comment step at all.
STUB_JIRA_BUILD=1 STUB_JIRA_COMMENT_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: opted-in failed comment skips the transition" -- --jira-transition
assert_audit_has "jira: failed-comment case records the skip" "jira-transition=skip=comment-failed key=HIMMEL-374"
assert_jira_log_lacks "jira: failed-comment case makes no jira transition call" "index.js transition"

# A closed ticket sitting in a later unreleased version moves to
# the current one (earliest unreleased by release date); anything else is left.
STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed ticket in a later unreleased version is folded to the current one" -- --jira-transition
assert_jira_log_has "jira: fold sets fixVersion to the current unreleased version" "edit HIMMEL-374 --fix-version v1.1.3"
assert_audit_has "jira: fold is recorded on the audit line" "jira-transition=ok key=HIMMEL-374 status=Done fixversion=v1.1.3"
assert_jira_log_has "8823: merge stamp carries merge-stamp" "edit-writer: merge-stamp"
assert_jira_log_lacks "8823: no merge-stamp edit goes out unnamed" "edit-writer: unset"

assert_jira_log_has "jira: the versions lookup names the ticket's project" "versions --project HIMMEL"

STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"},{"name":"v1.1.2"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: fold keeps a released version the ticket already holds" -- --jira-transition
assert_jira_log_has "jira: fold re-adds the released version" "edit HIMMEL-374 --add-fix-version v1.1.2"

STUB_JIRA_BUILD=1 STUB_JIRA_ADD_FIX_FAIL=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"},{"name":"v1.1.2"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a failed re-add of a held version names it on the audit line" -- --jira-transition
assert_audit_has "jira: failed re-add keeps the lost version recoverable" "fixversion=failed keep=v1.1.2"

# A re-add that fails once is retried, so the swap does not leave the ticket without the version it held.
STUB_JIRA_BUILD=1 STUB_JIRA_ADD_FIX_FAIL_ONCE=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"},{"name":"v1.1.2"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a re-add that fails once is retried" -- --jira-transition
assert_audit_has "jira: the retried re-add leaves the fold ok" "jira-transition=ok key=HIMMEL-374 status=Done fixversion=v1.1.3"
# The replace, the failed re-add and its retry are three edits, and every one is named.
if [ "$(grep -c '^edit-writer: merge-stamp$' "$LAST_JIRA_LOG")" = 3 ]; then pass; else fail "8823: retry after a failed add still carries merge-stamp (jira log: $(cat "$LAST_JIRA_LOG" 2>/dev/null))"; fi  # read-sink-ok: LAST_JIRA_LOG is this suite's own stub log inside its sandbox
assert_jira_log_lacks "8823: no retry edit goes out unnamed" "edit-writer: unset"

STUB_JIRA_BUILD=1 STUB_JIRA_VERSIONS='v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n' STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: with no dated version the first unreleased one is current" -- --jira-transition
assert_jira_log_has "jira: undated fold uses the first unreleased version" "edit HIMMEL-374 --fix-version v1.1.3"

STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.3"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed ticket already in the current version is not edited" -- --jira-transition
assert_jira_log_lacks "jira: no fixVersion edit when already current" "edit "

STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.2"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed ticket in a released version is not edited" -- --jira-transition
assert_jira_log_lacks "jira: no fixVersion edit for a released version" "edit "

# A closed ticket with no fixVersion at all is stamped with the current version.
STUB_JIRA_BUILD=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: closed unversioned ticket is stamped with the current version" -- --jira-transition
assert_jira_log_has "jira: unversioned stamp sets the current unreleased version" "edit HIMMEL-374 --fix-version v1.1.3"
assert_audit_has "jira: unversioned stamp is recorded on the audit line" "jira-transition=ok key=HIMMEL-374 status=Done fixversion=v1.1.3"

STUB_JIRA_BUILD=1 STUB_JIRA_FIX_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a failed unversioned stamp is a WARN, the merge still succeeds" -- --jira-transition
assert_audit_has "jira: failed unversioned stamp is recorded" "jira-transition=ok key=HIMMEL-374 status=Done fixversion=failed"
# A closed ticket the merge could not place is a visible WARN and a Done-fold request for the release manager.
assert_err_has "jira: a failed stamp prints a WARN" "WARN HIMMEL-374 closed unplaced"
assert_jira_log_has "jira: a failed stamp files a Done-fold INTAKE into the current version" "release request v1.1.3 --verb INTAKE --key HIMMEL-374 --to v1.1.3"
assert_audit_has "jira: the Done-fold request rides the audit line" "fixversion=failed fold-request=Q-v1.1.3-0099"

STUB_JIRA_BUILD=1 STUB_JIRA_FIX_FAIL=1 STUB_JIRA_REQUEST_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a Done-fold request that cannot be filed still lets the merge succeed" -- --jira-transition
assert_err_has "jira: an unfiled Done-fold request is said on stderr" "Done-fold request into v1.1.3 was NOT filed"
assert_audit_has "jira: an unfiled Done-fold request is on the audit line" "fold-request=failed"

# The transition stamped the frozen current version, so the fold reads the ticket again and makes no edit
# (STUB_JIRA_FIX_FAIL models the frozen intake gate refusing a second --fix-version).
STUB_JIRA_BUILD=1 STUB_JIRA_TRANSITION_STAMPS=v1.1.3 STUB_JIRA_FIX_FAIL=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a ticket the transition stamped is not folded again" -- --jira-transition
assert_audit_has "jira: a transition-stamped ticket records a clean move" "jira-transition=ok key=HIMMEL-374 status=Done"
assert_audit_lacks "jira: a transition-stamped ticket is not recorded as unplaced" "fixversion=failed"
assert_jira_log_lacks "jira: a transition-stamped ticket gets no fixVersion edit" "edit HIMMEL-374"
assert_jira_log_lacks "jira: a transition-stamped ticket files no Done-fold request" "release request"

# Transition exit 3: the ticket closed, but it was deferred out of the frozen version, so the merge does not stamp it.
STUB_JIRA_BUILD=1 STUB_JIRA_TRANSITION_RC3=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a transition that closes the ticket unstamped (exit 3) is a moved status" -- --jira-transition
assert_audit_has "jira: exit 3 records the move and the failed placement" "jira-transition=ok key=HIMMEL-374 status=Done fixversion=failed fold-request=Q-v1.1.3-0099"
assert_jira_log_lacks "jira: exit 3 makes no fixVersion edit past the deferral" "edit HIMMEL-374"

STUB_JIRA_BUILD=1 STUB_JIRA_VERSIONS='v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: unversioned stamp with no dated version uses the first unreleased one" -- --jira-transition
assert_jira_log_has "jira: undated unversioned stamp uses the first unreleased version" "edit HIMMEL-374 --fix-version v1.1.3"

# A get reply with no fixVersions key is unknown, not empty: a full-replace
# stamp could drop versions the ticket holds.
STUB_JIRA_BUILD=1 STUB_JIRA_NO_FIXVERSIONS=1 STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: a get reply without a fixVersions field is not stamped" -- --jira-transition
assert_jira_log_lacks "jira: no fixVersion edit when the field is missing from the reply" "edit "

STUB_JIRA_BUILD=1 STUB_JIRA_VERSIONS='v1.1.1\tfalse\t2026-10-01\ttrue\nv1.1.3\tfalse\t2026-10-22\tfalse\nv1.1.4\tfalse\t\tfalse\n' STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: an archived earlier unreleased version is not the fold target" -- --jira-transition
assert_jira_log_has "jira: fold skips the archived version and picks the live one" "edit HIMMEL-374 --fix-version v1.1.3"

STUB_JIRA_BUILD=1 STUB_JIRA_VERSIONS='v1.1.2\ttrue\t2026-10-11\n' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: an unversioned ticket with no unreleased version is not edited" -- --jira-transition
assert_jira_log_lacks "jira: no fixVersion edit when no unreleased version exists" "edit "

STUB_JIRA_BUILD=1 STUB_JIRA_FIXVERSIONS='{"name":"v1.1.4"}' STUB_PR_TITLE="feat(jira): [HIMMEL-374] reconciler" \
    run_mog 0 "jira: bare merge (no --jira-transition) never edits fixVersion"
assert_jira_log_lacks "jira: bare merge makes no fixVersion edit" "edit "

# --- GitHub-blocked -> exit 18, one alert, never retried -------
alert_lines() { grep -c . "$LAST_ALERT_LOG" 2>/dev/null || true; }
assert_alerts() {
    local want="$1" name="$2" got; got=$(alert_lines)
    if [ "$got" = "$want" ]; then pass; else fail "$name — expected $want alert DM(s), got ${got:-0}"; fi
}

# check-ci 5 (a required check never reported / set unreadable) is GitHub-blocked.
STUB_CI_RC=5 run_mog 18 "3381-a: check-ci exit 5 → exit 18"
assert_audit_has "3381-a: audit names the rule" "REFUSED reason=github-blocked phase=check-ci rule=required-check"
assert_gh_lacks  "3381-a: no merge attempted" "pr merge"
assert_alerts 1  "3381-a: exactly one operator DM"
assert_err_has   "3381-a: MERGE-BLOCKED line on stderr" "MERGE-BLOCKED owner/repo#77"
if grep -q '^555|MERGE-BLOCKED owner/repo#77' "$LAST_ALERT_LOG"; then pass; else fail "3381-a: DM goes to the operator chat with the repo#pr"; fi

# A red CI stays 14 and never alerts from here (check-ci names a failed required check itself).
STUB_CI_RC=1 run_mog 14 "3381-b: check-ci exit 1 stays exit 14"
assert_alerts 0 "3381-b: red CI sends no DM from merge-on-green"

# BLOCKED + REVIEW_REQUIRED after green: 18 + one DM naming the review rule.
STUB_MERGE_STATE=BLOCKED STUB_REVIEW_DECISION=REVIEW_REQUIRED run_mog 18 "3381-c: BLOCKED + REVIEW_REQUIRED → exit 18"
assert_alerts 1 "3381-c: exactly one operator DM"
assert_audit_has "3381-c: audit names the rule" "rule=required-review"
assert_err_has "3381-c: alert names the review rule" "a required review is outstanding"

# gh itself refusing on a required check: exit 18 at once — no confirmation poll, no retry.
STUB_MERGE_REQUIRED_CHECK=1 STUB_POST_STATE=OPEN run_mog 18 "3381-d: gh refuses on a required check → exit 18"
assert_alerts 1 "3381-d: exactly one operator DM"
assert_audit_has "3381-d: audit names the rule" "rule=github-refusal"
assert_audit_lacks "3381-d: never pending-unconfirmed" "INDETERMINATE"
if [ "$(grep -c '^pr merge ' "$LAST_GH_LOG")" -eq 1 ]; then pass; else fail "3381-d: gh pr merge must be called exactly once (no retry)"; fi
assert_gh_lacks "3381-d: no confirmation poll after the refusal" "state,headRefOid,baseRefName"

# Dedupe: the (repo, PR, head) already alerted -> the exit stays 18, no second DM.
STUB_ALERT_PRESEED=1 STUB_CI_RC=5 run_mog 18 "3381-e: repeat block on the same head → exit 18"
assert_alerts 0 "3381-e: no second DM for the same (repo, PR, head)"

# A failed delivery never changes the exit code.
STUB_ALERT_FAIL=1 STUB_CI_RC=5 run_mog 18 "3381-f: DM delivery failure keeps exit 18"
assert_err_has "3381-f: says the delivery failed" "DM delivery failed"

# --- the merge gate must resolve check-ci.sh (and, at the
# chief-GO gate, go-gate.sh / handover-path.sh) from the anchor
# (HIMMEL_REPO), never as a sibling of its own BASH_SOURCE. This script runs
# from a worker's own worktree, so a sibling resolution lets the branch under
# review supply the bytes of its own merge gate (found live: PR #1115's
# branch was merely behind main on scripts/check-ci.sh, and its own stale
# gate wrongly refused its own green PR — the benign direction; the
# dangerous mirror is a branch whose check-ci.sh wrongly PASSES).

# Control (b): HIMMEL_REPO unset must REFUSE (exit 19) before any gate runs
# — never fall back to the worktree's own sibling check-ci.sh.
MOG_NO_HIMMEL_REPO=1 STUB_CI_RC=0 run_mog 19 "3475-b: HIMMEL_REPO empty refuses (exit 19), never falls back to the sibling"
assert_err_has "3475-b: names the missing anchor" "HIMMEL_REPO"
if [ -e "$LAST_TMP/scripts/check-ci.ran" ]; then
    fail "3475-b: the worktree's own check-ci.sh ran despite HIMMEL_REPO being empty"
else
    pass
fi
# The genuinely UNSET path (env -u), not only the empty one.
MOG_UNSET_HIMMEL_REPO=1 STUB_CI_RC=0 run_mog 19 "3483: HIMMEL_REPO unset (env -u) refuses (exit 19), never falls back to the sibling"
assert_err_has "3483: names the missing anchor" "HIMMEL_REPO"
if [ -e "$LAST_TMP/scripts/check-ci.ran" ]; then
    fail "3483: the worktree's own check-ci.sh ran despite HIMMEL_REPO being unset"
else
    pass
fi
# Control: the env -u spelling run_mog uses really removes the variable.
# shellcheck disable=SC2016 # expands in the child, by design
if HIMMEL_REPO=x env -u HIMMEL_REPO bash -c '[ -z "${HIMMEL_REPO+set}" ]'; then pass; else fail "3483 control: env -u HIMMEL_REPO left the variable set"; fi

# Control (a): a worktree that IS its own anchor (HIMMEL_REPO defaults to the
# same tree, byte-identical check-ci.sh) behaves the same as before this
# fix — this single case plus every pre-existing run_mog case above it
# (~150, none of which set MOG_HIMMEL_REPO) continuing to pass unchanged
# is that control.
STUB_CI_RC=0 run_mog 0 "3475-a: worktree is its own anchor (byte-identical) behaves as before"
if [ -e "$LAST_TMP/scripts/check-ci.ran" ]; then pass; else fail "3475-a: the anchor's (== worktree's) check-ci.sh never ran"; fi

# merge-on-green runs only after the chief's GO, so its check-ci
# call is the post-GO path: the stub must see MERGE_WATCH_POST_GO=1.
if [ "$(cat "$LAST_TMP/scripts/check-ci.postgo" 2>/dev/null)" = 1 ]; then pass; else fail "4071: merge-on-green did not mark its check-ci call post-GO (MERGE_WATCH_POST_GO=1)"; fi

# A saturated CI queue. check-ci exit 7 (opted in via
# CHECK_CI_DISTINCT_DEADLINE=1) = the --max-wait deadline passed with checks
# still pending and nothing failed. merge-on-green re-watches ONLY that, at most
# 3 rounds, re-reading the PR (OPEN at the certified head) before every re-watch.
# Every other code — a red above all — still refuses on the first round.
mog4136_calls() { cat "$LAST_TMP/scripts/check-ci.count" 2>/dev/null || echo 0; }
STUB_CI_RCS="7 0" run_mog 0 "4136-a: one DEADLINE-PENDING round, then green, merges"
if [ "$(mog4136_calls)" = 2 ]; then pass; else fail "4136-a: check-ci should run twice, ran $(mog4136_calls)"; fi
if [ "$(grep -c '^1$' "$LAST_TMP/scripts/check-ci.distinct" 2>/dev/null)" = 2 ]; then pass; else fail "4136-a: every check-ci call must carry CHECK_CI_DISTINCT_DEADLINE=1"; fi
assert_gh_has "4136-a: the head is re-read, pinned to this PR, before the re-watch" "pr view 77 --repo owner/repo --json state,headRefOid --jq"
assert_gh_has "4136-a: the merge happened" "pr merge"

STUB_CI_RCS="7 7 7 7" run_mog 14 "4136-b: still pending after the cap refuses (exit 14)"
if [ "$(mog4136_calls)" = 3 ]; then pass; else fail "4136-b: the cap is 3 check-ci rounds, ran $(mog4136_calls)"; fi
assert_audit_has "4136-b: audit names the deadline-pending refusal" "REFUSED reason=gate-not-green gate=check-ci:7 rounds=3"
assert_gh_lacks "4136-b: no merge attempted" "pr merge"

# Counter-examples: a red, and every non-deadline failure, never loops.
STUB_CI_RCS="7 1" run_mog 14 "4136-c: pending then RED refuses (exit 14), never merges"
if [ "$(mog4136_calls)" = 2 ]; then pass; else fail "4136-c: a red ends the loop at once, ran $(mog4136_calls)"; fi
assert_gh_lacks "4136-c: no merge attempted" "pr merge"
for mog4136_rc in 1 2 3; do
    STUB_CI_RCS="$mog4136_rc 0" run_mog 14 "4136-d: check-ci exit $mog4136_rc refuses on round 1 (no re-watch)"
    if [ "$(mog4136_calls)" = 1 ]; then pass; else fail "4136-d: exit $mog4136_rc must not loop, check-ci ran $(mog4136_calls)"; fi
    assert_gh_lacks "4136-d: exit $mog4136_rc never re-reads for another round" "--json state,headRefOid --jq"
    assert_gh_lacks "4136-d: exit $mog4136_rc never merges" "pr merge"
done

# A stale head never merges: the head moving (or the PR leaving OPEN, or an
# unreadable re-read) between rounds refuses before a second watch.
STUB_CI_RCS="7 0" STUB_ROUND_HEAD=feedface0000 run_mog 14 "4136-e: head moved during the wait refuses (exit 14)"
if [ "$(mog4136_calls)" = 1 ]; then pass; else fail "4136-e: no re-watch after the head moved, ran $(mog4136_calls)"; fi
assert_audit_has "4136-e: audit names the moved head" "REFUSED reason=head-moved-during-ci-wait"
assert_gh_lacks "4136-e: no merge attempted" "pr merge"
STUB_CI_RCS="7 0" STUB_ROUND_STATE=CLOSED run_mog 14 "4136-f: PR closed during the wait refuses (exit 14)"
assert_gh_lacks "4136-f: no merge attempted" "pr merge"
STUB_CI_RCS="7 0" STUB_ROUND_FAIL=1 run_mog 14 "4136-g: an unreadable re-read refuses (fail closed, exit 14)"
if [ "$(mog4136_calls)" = 1 ]; then pass; else fail "4136-g: no re-watch on an unreadable head, ran $(mog4136_calls)"; fi
assert_gh_lacks "4136-g: no merge attempted" "pr merge"

# Core RED-then-GREEN assertion: two DISTINCT trees. The worktree's own
# check-ci.sh always fails; the anchor's always passes. The anchor must
# decide (exit 0) and the worktree's copy must NEVER execute — proven via
# the check-ci.ran marker file, not just the exit code, which could pass
# vacuously if a fixture's two trees happened to agree.
mog3475_base=$(mktemp -d "${TMPDIR:-/tmp}/mog-3475-anchor.XXXXXX")
if [ -z "$mog3475_base" ] || [ ! -d "$mog3475_base" ]; then
    fail "3475-core setup: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
else
    mog3475_worktree="$mog3475_base/worktree"
    mog3475_anchor="$mog3475_base/anchor"
    mkdir -p "$mog3475_worktree" "$mog3475_anchor"
    STUB_CI_RC=1 mog_build_fixture "$mog3475_worktree"
    STUB_CI_RC=0 mog_build_fixture "$mog3475_anchor"
    mog3475_gh="$mog3475_worktree/gh.log"; : > "$mog3475_gh"
    mog3475_clear="$mog3475_worktree/clear.log"; : > "$mog3475_clear"
    mog3475_audit="$mog3475_worktree/audit.log"
    mog3475_err="$mog3475_worktree/stderr.log"
    (
        cd "$mog3475_worktree" && \
        GH_LOG="$mog3475_gh" CLEAR_LOG="$mog3475_clear" MERGE_ON_GREEN_LOG="$mog3475_audit" \
        PATH="$mog3475_worktree/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
        MERGE_BLOCK_ALERT_DIR="$mog3475_worktree/alerts" MERGE_BLOCK_ALERT_CMD="$mog3475_worktree/bin/alert-sender" \
        TELEGRAM_ACCESS_PATH="$mog3475_worktree/access.json" \
        HIMMEL_REPO="$mog3475_anchor" \
        bash "$mog3475_worktree/scripts/handover/merge-on-green.sh"
    ) >/dev/null 2>"$mog3475_err"
    mog3475_rc=$?
    if [ "$mog3475_rc" -eq 0 ]; then
        pass
    else
        fail "3475-core: expected exit 0 (the anchor's green check-ci.sh decides), got rc=$mog3475_rc stderr=$(cat "$mog3475_err" 2>/dev/null)"
    fi
    if [ -e "$mog3475_anchor/scripts/check-ci.ran" ]; then pass; else fail "3475-core: the anchor's check-ci.sh never ran"; fi
    if [ -e "$mog3475_worktree/scripts/check-ci.ran" ]; then
        fail "3475-core: the WORKTREE's own check-ci.sh ran — the branch under review supplied the bytes of its own merge gate"
    else
        pass
    fi
    rm -rf "$mog3475_base"
fi

# go-gate.sh must also come from the anchor: a malicious worktree go-gate.sh
# that unconditionally forges "yes, a chief worker, with a valid GO" must not
# be able to skip or fake the chief-GO requirement — the anchor's real
# chief_worker()/go_gate() must decide instead, and correctly refuse (no real
# GO file exists).
mog3475b_base=$(mktemp -d "${TMPDIR:-/tmp}/mog-3475-gogate.XXXXXX")
if [ -z "$mog3475b_base" ] || [ ! -d "$mog3475b_base" ]; then
    fail "3475-gogate setup: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
else
    mog3475b_worktree="$mog3475b_base/worktree"
    mog3475b_anchor="$mog3475b_base/anchor"
    mkdir -p "$mog3475b_worktree" "$mog3475b_anchor"
    mog3475b_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3475-gogate-go.XXXXXX")
    if [ -z "$mog3475b_go_root" ] || [ ! -d "$mog3475b_go_root" ]; then
        fail "3475-gogate setup: mktemp -d produced no go-root sandbox — refusing to build fixture paths on an empty root"
    else
        mog3475b_go_root=$(cd "$mog3475b_go_root" && pwd)
        mog3475b_mutant_gogate=$(mktemp "${TMPDIR:-/tmp}/mog-3475-gogate-mutant.XXXXXX")
        if [ -z "$mog3475b_mutant_gogate" ] || [ ! -f "$mog3475b_mutant_gogate" ]; then
            fail "3475-gogate setup: mktemp produced no mutant-script file — refusing to build the fixture on an empty root"
        else
            cat > "$mog3475b_mutant_gogate" <<'EOF'
#!/usr/bin/env bash
# Test mutant: forges "yes, a chief worker, with a valid GO" no
# matter what — this test proves the anchored fix never lets it run.
chief_worker() { return 0; }
go_gate() { return 0; }
EOF
            STUB_CI_RC=0 GO_GATE_SRC="$mog3475b_mutant_gogate" mog_build_fixture "$mog3475b_worktree"
            STUB_CI_RC=0 mog_build_fixture "$mog3475b_anchor"
            mog3475b_gh="$mog3475b_worktree/gh.log"; : > "$mog3475b_gh"
            mog3475b_clear="$mog3475b_worktree/clear.log"; : > "$mog3475b_clear"
            mog3475b_audit="$mog3475b_worktree/audit.log"
            mog3475b_err="$mog3475b_worktree/stderr.log"
            (
                cd "$mog3475b_worktree" && \
                GH_LOG="$mog3475b_gh" CLEAR_LOG="$mog3475b_clear" MERGE_ON_GREEN_LOG="$mog3475b_audit" \
                PATH="$mog3475b_worktree/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
                MERGE_BLOCK_ALERT_DIR="$mog3475b_worktree/alerts" MERGE_BLOCK_ALERT_CMD="$mog3475b_worktree/bin/alert-sender" \
                TELEGRAM_ACCESS_PATH="$mog3475b_worktree/access.json" \
                HIMMEL_REPO="$mog3475b_anchor" HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$mog3475b_go_root" \
                bash "$mog3475b_worktree/scripts/handover/merge-on-green.sh"
            ) >/dev/null 2>"$mog3475b_err"
            mog3475b_rc=$?
            if [ "$mog3475b_rc" -eq 17 ]; then
                pass
            else
                fail "3475-gogate: expected exit 17 (the anchor's real go-gate.sh refuses — no real GO file) despite the worktree's malicious go-gate.sh forging approval, got rc=$mog3475b_rc stderr=$(cat "$mog3475b_err" 2>/dev/null)"
            fi
            if grep -Eq '^pr merge( |$)' "$mog3475b_gh" 2>/dev/null; then
                fail "3475-gogate: merged despite no real chief GO — the worktree's forged go-gate.sh decided instead of the anchor's"
            else
                pass
            fi
            rm -f "$mog3475b_mutant_gogate"
        fi
        rm -rf "$mog3475b_go_root"
    fi
    rm -rf "$mog3475b_base"
fi

# handover-path.sh must also come from the anchor: a malicious worktree
# handover-path.sh that forges handover_root() onto an attacker-writable,
# pre-planted fake GO file must not be able to satisfy the chief-GO check —
# the anchor's real handover_root() must decide instead, and correctly
# resolve to a root with no matching GO file (refuse).
mog3475c_base=$(mktemp -d "${TMPDIR:-/tmp}/mog-3475-hpath.XXXXXX")
if [ -z "$mog3475c_base" ] || [ ! -d "$mog3475c_base" ]; then
    fail "3475-hpath setup: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
else
mog3475c_worktree="$mog3475c_base/worktree"
mog3475c_anchor="$mog3475c_base/anchor"
mkdir -p "$mog3475c_worktree" "$mog3475c_anchor"
mog3475c_fake_go_root="$mog3475c_base/attacker-writable-go-root"
mog3475c_real_go_root=$(mktemp -d "${TMPDIR:-/tmp}/mog-3475-hpath-go.XXXXXX")
if [ -z "$mog3475c_real_go_root" ] || [ ! -d "$mog3475c_real_go_root" ]; then
    fail "3475-hpath setup: mktemp -d produced no go-root sandbox — refusing to build fixture paths on an empty root"
else
mog3475c_real_go_root=$(cd "$mog3475c_real_go_root" && pwd)
mog3475c_sha=0123456789abcdef0123456789abcdef01234567
mkdir -p "$mog3475c_fake_go_root/.locks/go"
printf 'head=%s\n' "$mog3475c_sha" > "$mog3475c_fake_go_root/.locks/go/77.$mog3475c_sha"
mog3475c_mutant_hpath=$(mktemp "${TMPDIR:-/tmp}/mog-3475-hpath-mutant.XXXXXX")
if [ -z "$mog3475c_mutant_hpath" ] || [ ! -f "$mog3475c_mutant_hpath" ]; then
    fail "3475-hpath setup: mktemp produced no mutant-script file — refusing to build the fixture on an empty root"
else
cat > "$mog3475c_mutant_hpath" <<EOF
#!/usr/bin/env bash
# Test mutant: forges handover_root() onto a pre-planted fake GO
# file's directory no matter what — this test proves the anchored fix never
# lets it run.
handover_root() { printf '%s\n' "$mog3475c_fake_go_root"; }
EOF
STUB_CI_RC=0 mog_build_fixture "$mog3475c_worktree"
cp "$mog3475c_mutant_hpath" "$mog3475c_worktree/scripts/lib/handover-path.sh"
STUB_CI_RC=0 mog_build_fixture "$mog3475c_anchor"
mog3475c_gh="$mog3475c_worktree/gh.log"; : > "$mog3475c_gh"
mog3475c_clear="$mog3475c_worktree/clear.log"; : > "$mog3475c_clear"
mog3475c_audit="$mog3475c_worktree/audit.log"
mog3475c_err="$mog3475c_worktree/stderr.log"
(
    cd "$mog3475c_worktree" && \
    GH_LOG="$mog3475c_gh" CLEAR_LOG="$mog3475c_clear" MERGE_ON_GREEN_LOG="$mog3475c_audit" \
    PATH="$mog3475c_worktree/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
    MERGE_BLOCK_ALERT_DIR="$mog3475c_worktree/alerts" MERGE_BLOCK_ALERT_CMD="$mog3475c_worktree/bin/alert-sender" \
    TELEGRAM_ACCESS_PATH="$mog3475c_worktree/access.json" \
    HIMMEL_REPO="$mog3475c_anchor" HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$mog3475c_real_go_root" STUB_SHA="$mog3475c_sha" \
    bash "$mog3475c_worktree/scripts/handover/merge-on-green.sh"
) >/dev/null 2>"$mog3475c_err"
mog3475c_rc=$?
if [ "$mog3475c_rc" -eq 17 ]; then
    pass
else
    fail "3475-hpath: expected exit 17 (the anchor's real handover-path.sh resolves the genuine root, which has no matching GO file) despite the worktree's malicious handover-path.sh forging a pre-planted fake GO, got rc=$mog3475c_rc stderr=$(cat "$mog3475c_err" 2>/dev/null)"
fi
if grep -Eq '^pr merge( |$)' "$mog3475c_gh" 2>/dev/null; then
    fail "3475-hpath: merged despite no real chief GO — the worktree's forged handover-path.sh decided instead of the anchor's"
else
    pass
fi
rm -f "$mog3475c_mutant_hpath"
fi
rm -rf "$mog3475c_real_go_root"
fi
rm -rf "$mog3475c_base"
fi

# --- a MALICIOUS branch, not only a stale one. Every helper the
# gate sources or executes must come from the anchor, so a branch that rewrites
# any one of them cannot change the verdict. Each case poisons ONE helper in
# the worktree tree (MOG_POISON: marker + exit 42) and points HIMMEL_REPO at a
# distinct, clean anchor tree. At the pre-fix base every case is RED: the
# worktree's mutant runs (exit 42, or marker=clear-rc=42 for the clearer).
mog3485_anchor() {  # mog3485_anchor <check-ci rc> -> prints a clean anchor tree
    local a; a=$(mktemp -d "${TMPDIR:-/tmp}/mog-3485-anchor.XXXXXX") || return 1
    [ -n "$a" ] && [ -d "$a" ] || return 1
    STUB_CI_RC="$1" mog_build_fixture "$a" >/dev/null || { rm -rf "$a"; return 1; }
    printf '%s' "$a"
}
mog3485_no_poison() {  # mog3485_no_poison <label>
    if [ -e "$LAST_TMP/poison.ran" ]; then fail "$1: the worktree's mutant helper ran — the branch under review supplied gate bytes"; else pass; fi
}

# Sourced BEFORE the old anchor resolution: the anchor's red check-ci decides (14).
for mog3485_helper in lib/coderabbit-available.sh lib/merge-block-alert.sh; do
    if mog3485_a=$(mog3485_anchor 1); then
        MOG_HIMMEL_REPO="$mog3485_a" MOG_POISON="$mog3485_helper" STUB_CI_RC=0 \
            run_mog 14 "3485: a branch-side $mog3485_helper cannot change the verdict (anchor's red check-ci → 14)"
        mog3485_no_poison "3485: $mog3485_helper"
        rm -rf "$mog3485_a"
    else
        fail "3485 setup: no anchor sandbox for $mog3485_helper"
    fi
done

# Sourced after the gate, before the merge: the clean merge still lands (0).
if mog3485_a=$(mog3485_anchor 0); then
    MOG_HIMMEL_REPO="$mog3485_a" MOG_POISON=lib/worktree-inuse.sh STUB_CI_RC=1 \
        run_mog 0 "3485: a branch-side lib/worktree-inuse.sh cannot change the verdict (anchor green → 0)"
    mog3485_no_poison "3485: lib/worktree-inuse.sh"
    rm -rf "$mog3485_a"
else
    fail "3485 setup: no anchor sandbox for lib/worktree-inuse.sh"
fi

# Executed on the merge path: the anchor's clearer runs, never the branch's.
if mog3485_a=$(mog3485_anchor 0); then
    read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
    mk_marker "$P_REPO" "feat/mog-prune"
    MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
        MOG_HIMMEL_REPO="$mog3485_a" MOG_POISON=cr/clear-review-marker.sh STUB_CI_RC=1 \
        run_mog 0 "3485: a branch-side cr/clear-review-marker.sh is never executed (anchor green → 0)"
    assert_audit_has "3485: the anchor's clearer cleared the marker" "marker=cleared"
    mog3485_no_poison "3485: cr/clear-review-marker.sh"
    rm -rf "$mog3485_a"
else
    fail "3485 setup: no anchor sandbox for cr/clear-review-marker.sh"
fi

# HIMMEL_REPO is a registered chokepoint seam: a per-call prefix that re-points
# the anchor at the branch is denied by block-chokepoint-env-prefix.sh (run
# read-only against this tree's own registry).
mog3485_hook="$SCRIPT_DIR/../hooks/block-chokepoint-env-prefix.sh"
# shellcheck disable=SC2016 # the $HIMMEL_REPO text is the payload, never expanded here
mog3485_cmd='HIMMEL_REPO=. bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh"'
mog3485_json=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$mog3485_cmd" | jq -Rs .)")
# Captured, not piped: the hook denies with exit 2, which pipefail would carry.
mog3485_out=$(printf '%s' "$mog3485_json" | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY bash "$mog3485_hook" 2>/dev/null)
if printf '%s' "$mog3485_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    pass
else
    fail "3485: HIMMEL_REPO=. prefix on the anchored merge gate was not denied by the chokepoint hook"
fi

# check-ci exit 6 (GitHub's mergeStateStatus refuses while our
# gates are green) is GitHub-blocked: 18 + one alert, never the generic 14.
STUB_CI_RC=6 run_mog 18 "3485: check-ci exit 6 → exit 18"
assert_audit_has "3485: exit-6 audit names the rule" "REFUSED reason=github-blocked phase=check-ci rule=merge-state gate=check-ci:6"
assert_gh_lacks  "3485: exit 6 attempts no merge" "pr merge"
assert_alerts 1  "3485: exit 6 sends exactly one operator DM"

# Guard against reintroducing extraction of a historical
# commit's blob via `git show <sha>:<path>` — the class of fragility this
# ticket fixed. Once a PR's branch is squash-merged, that commit is
# permanently unreachable from a fresh clone; a RED-control mutant must come
# from a committed fixtures/red-control/ snapshot, never a live git-show of a
# past ref.
_mog_blob_hits=$(cat "$SCRIPT_DIR/test-merge-on-green.sh" "$SCRIPT_DIR/test-merge-on-green-b.sh" | grep -vE '^[[:space:]]*#' \
    | grep -E 'git[[:space:]]+(-C[[:space:]]+\S+[[:space:]]+)?show[[:space:]].*:scripts/')
if [ -n "$_mog_blob_hits" ]; then
    fail "lint: this file extracts a historical blob via git show <ref>:<path> — use a committed fixtures/red-control/ snapshot instead"
else
    pass
fi

# The entry script itself hands off a relative invocation to the
# HIMMEL_REPO anchor's own copy (scripts/cr/anchor-handoff.sh, generalized by
# this same ticket). Proven with the REAL, unmutated script — a fixture "wt"
# tree's copy is mutated AFTER the hand-off line to prove which BYTES decided:
# a real backdoor injected post-hand-off must never run when entered
# relatively with HIMMEL_REPO pointing at a clean anchor. RED-at-base for the
# resolver anchor-handoff.sh itself replaces lives in scripts/cr/test-anchor-handoff.sh
# T14/T15 — a fixture built HERE that skipped sourcing the
# real hand-off line entirely would only prove its own shape backdoors, not
# exercise the code under test, so it is not duplicated in this file.
mog3437_anchor="$(mktemp -d "${TMPDIR:-/tmp}/mog-3437-anchor.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
mog3437_wt="$(mktemp -d "${TMPDIR:-/tmp}/mog-3437-wt.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
mog_build_fixture "$mog3437_anchor"
mog_build_fixture "$mog3437_wt"
# anchor-handoff.sh resolves the sourcing script's own root via
# `git rev-parse --show-toplevel`, so a relative-entry fixture tree must be a
# real git repo (a bare `git init -q` — no commit needed).
git init -q "$mog3437_wt"
# shellcheck disable=SC2016  # the literal line merge-on-green.sh carries, not an expansion
mog3437_src_line='. "$_ah_d/../cr/anchor-handoff.sh" || exit 2'
awk -v src="$mog3437_src_line" '{ print } $0 == src { exit }' "$mog3437_wt/scripts/handover/merge-on-green.sh" > "$mog3437_wt/scripts/handover/merge-on-green.sh.head"
if grep -qxF "$mog3437_src_line" "$mog3437_wt/scripts/handover/merge-on-green.sh.head"; then
    cp "$mog3437_wt/scripts/handover/merge-on-green.sh.head" "$mog3437_wt/scripts/handover/merge-on-green.sh"
    printf 'echo "RAN:branch-backdoor"\nexit 0\n' >> "$mog3437_wt/scripts/handover/merge-on-green.sh"
    chmod +x "$mog3437_wt/scripts/handover/merge-on-green.sh"
else
    fail "3437: setup — could not locate the hand-off source line in merge-on-green.sh to build the backdoor mutant"
fi
rm -f "$mog3437_wt/scripts/handover/merge-on-green.sh.head"

mog3437_run() {  # <cwd> <HIMMEL_REPO-or-dash> <entry>
    if [ "$2" = "-" ]; then
        (cd "$1" && env -u HIMMEL_REPO -u CR_ANCHOR_HANDED_OFF -u ARMAUTOMERGE bash "$3" 2>/dev/null; echo "rc=$?")
    else
        (cd "$1" && env -u CR_ANCHOR_HANDED_OFF -u ARMAUTOMERGE HIMMEL_REPO="$2" bash "$3" 2>/dev/null; echo "rc=$?")
    fi
}

# 1. Relative entry from the mutated worktree hands off: the anchor's real,
# unmutated script runs (this fixture's ARMAUTOMERGE is unset, so its real
# gate refuses at exit 10 — "not opted in" — never the branch's backdoor).
mog3437_out="$(mog3437_run "$mog3437_wt" "$mog3437_anchor" scripts/handover/merge-on-green.sh)"
if grepq "$mog3437_out" -F -e "RAN:branch-backdoor"; then
    fail "3437: relative entry ran the worktree's own backdoor copy instead of handing off: $mog3437_out"
elif grepq "$mog3437_out" -F -e "rc=10"; then
    pass
else
    fail "3437: relative entry did not hand off to the anchor's real script as expected: $mog3437_out"
fi

# 2. Absolute entry still runs the local (branch) copy — the deliberate open door.
mog3437_abs_out="$(mog3437_run "$mog3437_wt" "$mog3437_anchor" "$mog3437_wt/scripts/handover/merge-on-green.sh")"
if grepq "$mog3437_abs_out" -F -e "RAN:branch-backdoor"; then pass; else fail "3437: absolute entry did not run the local copy: $mog3437_abs_out"; fi

# 3. Relative entry with HIMMEL_REPO unset fails closed at exit 2.
mog3437_unset_out="$(mog3437_run "$mog3437_wt" - scripts/handover/merge-on-green.sh)"
if grepq "$mog3437_unset_out" -F -e "rc=2"; then pass; else fail "3437: relative entry with HIMMEL_REPO unset did not exit 2: $mog3437_unset_out"; fi

rm -rf "$mog3437_anchor" "$mog3437_wt"

# ── refuse while main's latest COMPLETED CI run is red ─────────
# Real window (gh run list on main, 2026-10-09): the latest completed non-
# cancelled run 37964772913 FAILED (shell-unit-shard 8, exit 124 in apt-get),
# two cancelled pushes behind it. main CI runs on a cron/dispatch now, so "latest completed" is a sweep, and the refusal names the
# commit range that run covered.
MOG_RUN_RED='[{"conclusion":"failure","createdAt":"2026-10-09T17:13:47Z","databaseId":37964772913,"event":"push","headSha":"f343c0e266336aee395f2612d8f62ca3b927528f","status":"completed"},{"conclusion":"cancelled","createdAt":"2026-10-09T17:07:20Z","databaseId":37964009625,"event":"push","headSha":"7a635cad090d9d51297e61a48add1d7f7a98fb34","status":"completed"},{"conclusion":"cancelled","createdAt":"2026-10-09T17:06:12Z","databaseId":37963871864,"event":"push","headSha":"ed3a561c2321412eff3f9779eab384219ad5a61a","status":"completed"}]'
# A cancelled and an in-progress run NEWER than the red one: neither is "completed".
MOG_RUN_RED_NEWER_CANCELLED='[{"conclusion":"","createdAt":"2026-10-09T17:50:00Z","databaseId":37968999999,"event":"schedule","headSha":"3cb0693f11e8ffa3cff18f1d6b06b1078bc305da","status":"in_progress"},{"conclusion":"cancelled","createdAt":"2026-10-09T17:41:38Z","databaseId":37968070108,"event":"push","headSha":"3cb0693f11e8ffa3cff18f1d6b06b1078bc305da","status":"completed"},{"conclusion":"failure","createdAt":"2026-10-09T17:13:47Z","databaseId":37964772913,"event":"push","headSha":"f343c0e266336aee395f2612d8f62ca3b927528f","status":"completed"},{"conclusion":"cancelled","createdAt":"2026-10-09T17:07:20Z","databaseId":37964009625,"event":"push","headSha":"7a635cad090d9d51297e61a48add1d7f7a98fb34","status":"completed"}]'
# The real failed-job log lines (job, step, line; tab-separated) of run 37964772913.
MOG_RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/mog-runlog.XXXXXX")" || { echo "FAIL: 5115 setup: mktemp" >&2; exit 1; }
printf '%s\t%s\t%s\n' \
    'shell-unit-shard (ubuntu-latest, 8)' 'UNKNOWN STEP' '2026-10-09T17:44:06.7905525Z Run apt-get install at' \
    'shell-unit-shard (ubuntu-latest, 8)' 'UNKNOWN STEP' '2026-10-09T17:54:35.0819579Z ##[error]Process completed with exit code 124.' \
    'shell-unit (ubuntu-latest)' 'UNKNOWN STEP' '2026-10-09T18:24:30.5567074Z ##[error]shell-unit shards did not all pass (matrix rollup: failure)' > "$MOG_RUN_LOG"
mog5115_commits() { printf '{"commits":[{"messageHeadline":"fix: x","messageBody":"%s"}]}' "$1"; }

# 5115-a (RED, real window) — main red, no declaration: merged before this gate.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" run_mog 0 "5115-a: main's latest completed run is red → merged as advisory"
assert_audit_has "5115-a: audited as an advisory merge" "via=advisory"
assert_err_has "5115-a: stderr names the red run" "37964772913"
assert_err_has "5115-a: stderr names the range base (only cancelled runs behind, so outside the window)" "previous run outside the listed window"
assert_err_has "5115-a: stderr names the commit range (head)" "f343c0e2"
assert_merge_has "5115-a: the merge ran" "--squash"

# 5115-b — green main (cancelled pushes over a success) is allowed.
run_mog 0 "5115-b: green main (cancelled newer, success behind) → merged"
assert_gh_has "5115-b: main's runs were read" "run list"
assert_audit_lacks "5115-b: green-main merge is not an advisory" "via=advisory"

# 5115-c — cancelled and in-progress runs are skipped: fall back to the
# previous COMPLETED run, which is red.
STUB_RUN_LIST_JSON="$MOG_RUN_RED_NEWER_CANCELLED" run_mog 0 "5115-c: cancelled/in-progress latest falls back to the red completed run → merged as advisory"
assert_err_has "5115-c: the fallback run is the red one" "37964772913"

# 5115-d — declared fix by run id, verified against the red run.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: run=37964772913')" \
    run_mog 0 "5115-d: valid run= declaration → merged"
assert_audit_has "5115-d: audited as the declared fix" "main-red-declared"

# 5115-e — forged: the run id is not the red run.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: run=12345')" \
    run_mog 0 "5115-e: forged run id → merged as advisory"
assert_audit_has "5115-e: audited as an advisory merge" "via=advisory"
assert_audit_lacks "5115-e: and never as a declared fix" "main-red-declared"

# 5115-f — declared by suite, verified against the red run's failed log.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=shell-unit-shard')" \
    run_mog 0 "5115-f: suite= named in the red run's failed log → merged"
assert_gh_has "5115-f: the failed log was read for the red run" "run view 37964772913"

# 5115-g — forged: a suite the red run never failed on.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=test-unrelated.sh')" \
    run_mog 0 "5115-g: unrelated suite= → merged as advisory"
assert_audit_has "5115-g: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5115-g: and never as a declared fix" "main-red-declared"

# 5115-h — a declaration whose log cannot be read is not verified: it merges as an advisory.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_VIEW_FAIL=1 \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=shell-unit-shard')" \
    run_mog 0 "5115-h: unreadable failed log → merged as advisory"
assert_audit_has "5115-h: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5115-h: and never as a declared fix" "main-red-declared"

# 5115-l — a fragment of a failed job name is not a job: `unit` sits inside
# `shell-unit-shard (...)` but names nothing the run failed on.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=unit')" \
    run_mog 0 "5115-l: fragment suite= is not a failed job → merged as advisory"
assert_audit_has "5115-l: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5115-l: and never as a declared fix" "main-red-declared"

# 5115-m — the declaration may be the commit subject on a one-line commit.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" \
    STUB_PR_COMMITS_JSON='{"commits":[{"messageHeadline":"Fixes-main-red: run=37964772913","messageBody":""}]}' \
    run_mog 0 "5115-m: declaration on the commit subject → merged"

# 5115-n — the reported range base is the previous COMPLETED non-cancelled
# sweep, not a cancelled run sitting between.
STUB_RUN_LIST_JSON='[{"databaseId":300,"status":"completed","conclusion":"failure","event":"schedule","headSha":"aaaaaaaaaaaa1111111111111111111111111111"},{"databaseId":200,"status":"completed","conclusion":"cancelled","event":"push","headSha":"bbbbbbbbbbbb2222222222222222222222222222"},{"databaseId":100,"status":"completed","conclusion":"success","event":"schedule","headSha":"cccccccccccc3333333333333333333333333333"}]' \
    run_mog 0 "5115-n: range base skips a cancelled run → merged as advisory"
assert_err_has "5115-n: range runs from the previous completed sweep" "cccccccccccc..aaaaaaaaaaaa"

# 5115-o/p — a .sh suite on an ##[error] line must be a whole path component:
# `test-foo.sh` is named there, `foo.sh` is only the tail of it.
MOG_RUN_LOG2="$(mktemp "${TMPDIR:-/tmp}/mog-runlog2.XXXXXX")" || { echo "FAIL: 5115 setup: mktemp" >&2; exit 1; }
printf '%s\t%s\t%s\n' \
    'shell-unit-shard (ubuntu-latest, 3)' 'UNKNOWN STEP' '2026-10-09T17:54:35.0819579Z ##[error]scripts/handover/test-foo.sh failed (2 assertions)' > "$MOG_RUN_LOG2"
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG2" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=test-foo.sh')" \
    run_mog 0 "5115-o: whole .sh name on an error line → merged"
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG2" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=foo.sh')" \
    run_mog 0 "5115-p: tail fragment of a .sh name → merged as advisory"
assert_audit_has "5115-p: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5115-p: and never as a declared fix" "main-red-declared"
rm -f "$MOG_RUN_LOG2"

# 5115-q — a prefix is a matrix base name only when followed by ` (`: a job
# `shell-unit-shard extra` is a different job, not a shard of `shell-unit-shard`.
MOG_RUN_LOG3="$(mktemp "${TMPDIR:-/tmp}/mog-runlog3.XXXXXX")" || { echo "FAIL: 5115 setup: mktemp" >&2; exit 1; }
printf '%s\t%s\t%s\n' \
    'shell-unit-shard extra' 'UNKNOWN STEP' '2026-10-09T17:54:35.0819579Z ##[error]Process completed with exit code 1.' > "$MOG_RUN_LOG3"
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG3" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=shell-unit-shard')" \
    run_mog 0 "5115-q: prefix followed by a non-matrix suffix → merged as advisory"
assert_audit_has "5115-q: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5115-q: and never as a declared fix" "main-red-declared"
rm -f "$MOG_RUN_LOG3"

# 5115-i — DECIDED: no completed run in the window means no red was observed.
# Allowed, and the audit says so.
STUB_RUN_LIST_JSON='[]' run_mog 0 "5115-i: no completed run at all → merged, audited"
assert_audit_has "5115-i: audited as a decided no-completed-run" "main-red=no-completed-run"

# 5115-r — a run list that hit the --limit 50 cap with no completed
# non-cancelled run says nothing about main: refuse, never "no red observed".
mog5115_cap='['
for mog5115_i in $(seq 1 50); do
    mog5115_cap="${mog5115_cap}{\"conclusion\":\"cancelled\",\"createdAt\":\"2026-10-09T17:00:00Z\",\"databaseId\":$((38000000000 + mog5115_i)),\"event\":\"push\",\"headSha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"status\":\"completed\"},"
done
mog5115_cap="${mog5115_cap%,}]"
STUB_RUN_LIST_JSON="$mog5115_cap" run_mog 22 "5115-r: 50 cancelled runs, none completed → exit 22"
assert_audit_has "5115-r: audited as a run-list refusal" "phase=run-list seen=50"

# 5115-s — a newer completed GREEN pull_request run (a fork PR from a branch
# named main) on top of a RED schedule run must not hide the red; and a RED
# pull_request run on top of a green schedule run must not block.
STUB_RUN_LIST_JSON='[{"databaseId":400,"status":"completed","conclusion":"success","event":"pull_request","headSha":"dddddddddddd4444444444444444444444444444"},{"databaseId":300,"status":"completed","conclusion":"failure","event":"schedule","headSha":"aaaaaaaaaaaa1111111111111111111111111111"},{"databaseId":100,"status":"completed","conclusion":"success","event":"schedule","headSha":"cccccccccccc3333333333333333333333333333"}]' \
    run_mog 0 "5115-s: green fork pull_request run does not hide a red schedule run → merged as advisory"
assert_err_has "5115-s: the red run is the schedule run" "300"
STUB_RUN_LIST_JSON='[{"databaseId":400,"status":"completed","conclusion":"failure","event":"pull_request_target","headSha":"dddddddddddd4444444444444444444444444444"},{"databaseId":300,"status":"completed","conclusion":"success","event":"schedule","headSha":"aaaaaaaaaaaa1111111111111111111111111111"}]' \
    run_mog 0 "5115-s2: red fork pull_request_target run does not block a green main → merged"
assert_audit_lacks "5115-s2: green-main merge is not an advisory" "via=advisory"

# 5115-j — an unreadable run list is unverified: refuse (fail closed).
STUB_RUN_LIST_FAIL=1 run_mog 22 "5115-j: run list read fails → exit 22"
assert_audit_has "5115-j: audited" "REFUSED reason=main-red"

# 5115-k — the dry run reports the same advisory and makes no merge call.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" run_mog 0 "5115-k: dry-run on red main → advisory reported" -- --dry-run
no_merge_call "5115-k: a dry run makes no merge call"
assert_gh_lacks "5115-k: a dry run queues no re-check" "workflow run ci.yml"
assert_err_has "5115-k: the dry run prints the advisory" "MAIN-RED advisory:"

# 8675-a (RED, real window) — a red main no longer blocks a PR whose own CI is
# green: the merge proceeds, the audit line names the red run and `via=advisory`,
# and one MAIN-RED advisory line is printed.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" run_mog 0 "8675-a: red main, PR's own CI green → merged as advisory"
assert_audit_has "8675-a: audited as an advisory merge" "via=advisory"
assert_audit_has "8675-a: audit names the red run id" "run=37964772913"
assert_audit_lacks "8675-a: a readable commit list is not flagged unreadable" "commits=unreadable"
assert_audit_lacks "8675-a: not a refusal" "REFUSED reason=main-red"
assert_err_has "8675-a: prints the MAIN-RED advisory" "MAIN-RED advisory:"
assert_err_has "8675-a: the advisory names the red run" "37964772913"
assert_merge_has "8675-a: the merge ran" "--squash"
assert_gh_has "8675-a: main is re-checked after the merge" "workflow run ci.yml"
# 8675-b — a red PR on a red main is still refused, by the PR-green gate (14).
STUB_CI_RC=1 STUB_RUN_LIST_JSON="$MOG_RUN_RED" run_mog 14 "8675-b: red PR on a red main → exit 14"
no_merge_call "8675-b: no merge call"
assert_audit_lacks "8675-b: never reaches the main-red advisory" "via=advisory"
# 8675-c — an unreadable commit list only leaves a declaration unverified: an advisory merge.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_COMMITS_FAIL=1 run_mog 0 "8675-c: red main, commit list unreadable → merged as advisory"
assert_audit_has "8675-c: audited as an advisory merge" "via=advisory"
assert_audit_has "8675-c: the audit says the commits were not read" "commits=unreadable"
assert_merge_has "8675-c: the merge ran" "--squash"
rm -f "$MOG_RUN_LOG"

# ── chief-written fix-GO is the second way through the gate ───
# go.sh --fix-main-red <run> <pr> <head> writes a signed file naming ONE red
# run; the gate accepts it only when that run is the CURRENT red run, for this
# PR and head, and never without the signature.
MOG_FX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mog-fx.XXXXXX") || { echo "FAIL: 5134 setup: mktemp" >&2; exit 1; }
MOG_FX_ROOT=$(cd "$MOG_FX_ROOT" && pwd)
mog5134_run() {  # <expect rc> <label> [--] [run_mog args]: red main, PR 77 at GO_SHA, root MOG_FX_ROOT
    HANDOVER_DIR="$MOG_FX_ROOT" STUB_SHA="$GO_SHA" STUB_RUN_LIST_JSON="${MOG_RUN_FX:-$MOG_RUN_RED}" run_mog "$@"
}
# 5134-a — red main, nothing declared, no fix-GO: an advisory merge.
mog5134_run 0 "5134-a: red main, no declaration, no fix-GO → merged as advisory"

# 5134-b — a fix-GO for the red run, this PR and this head: merged, audited.
go_write "$MOG_FX_ROOT" --fix-main-red 37964772913 77 "$GO_SHA"
mog5134_run 0 "5134-b: fix-GO for the current red run → merged"
assert_audit_has "5134-b: audited as the declared fix, via the fix-GO" "via=fix-go:run=37964772913"
assert_merge_has "5134-b: merge pins the certified head" "--match-head-commit $GO_SHA"

# 5134-c — stale: main moved to a newer red run; the fix-GO names the old one.
MOG_RUN_FX='[{"conclusion":"failure","createdAt":"2026-10-10T07:00:00Z","databaseId":37999999999,"event":"schedule","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed"},{"conclusion":"failure","createdAt":"2026-10-09T17:13:47Z","databaseId":37964772913,"event":"push","headSha":"f343c0e266336aee395f2612d8f62ca3b927528f","status":"completed"}]' \
    mog5134_run 0 "5134-c: stale fix-GO (main has a newer red run) → merged as advisory"
assert_audit_has "5134-c: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5134-c: and never as a declared fix" "main-red-declared"
assert_err_has "5134-c: stderr names the CURRENT red run" "37999999999"
assert_merge_has "5134-c: the merge ran" "--squash"
# ... and a fix-GO written for the new run is accepted.
go_write "$MOG_FX_ROOT" --fix-main-red 37999999999 77 "$GO_SHA"
MOG_RUN_FX='[{"conclusion":"failure","createdAt":"2026-10-10T07:00:00Z","databaseId":37999999999,"event":"schedule","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed"}]' \
    mog5134_run 0 "5134-c2: a fix-GO for the new red run → merged"

# 5134-d — forged: the run line edited after signing (mac no longer matches).
go_write "$MOG_FX_ROOT" --fix-main-red 37964000000 77 "$GO_SHA"
sed -i.bak 's/^fix-main-red-run=.*/fix-main-red-run=37964772913/' "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964000000"
cp "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964000000" "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964772913"
rm -f "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964772913.bak" "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964000000"
rm -f "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37999999999"
mog5134_run 0 "5134-d: fix-GO edited to the red run id (mac signs another) → merged as advisory"
assert_audit_has "5134-d: audited as an advisory merge" "via=advisory"
assert_audit_lacks "5134-d: and never as a declared fix" "main-red-declared"

# 5134-e — unsigned: a hand-written file with the right fields and no mac.
printf 'pr=77\nhead=%s\nfix-main-red-run=37964772913\nby=worker\nat=2026-10-10T00:00:00Z\n' "$GO_SHA" \
    > "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964772913"
mog5134_run 0 "5134-e: unsigned fix-GO → merged as advisory"
assert_audit_has "5134-e: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5134-e: and never as a declared fix" "main-red-declared"

# 5134-f — a fix-GO for a different PR (78) is not a declaration for PR 77, even
# renamed onto PR 77's path (the mac binds the PR number): an advisory merge.
go_write "$MOG_FX_ROOT" --fix-main-red 37964772913 78 "$GO_SHA"
cp "$MOG_FX_ROOT/.locks/go/fix-main-red.78.$GO_SHA.37964772913" "$MOG_FX_ROOT/.locks/go/fix-main-red.77.$GO_SHA.37964772913"
mog5134_run 0 "5134-f: a fix-GO signed for PR 78 → merged as advisory"
assert_audit_has "5134-f: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5134-f: and never as a declared fix" "main-red-declared"

# 5134-g — green main: a fix-GO has no effect (and is not audited as a fix).
go_write "$MOG_FX_ROOT" --fix-main-red 37964772913 77 "$GO_SHA"
MOG_RUN_FX='[{"conclusion":"success","createdAt":"2026-10-10T07:00:00Z","databaseId":37999999999,"event":"schedule","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed"}]' \
    mog5134_run 0 "5134-g: green main with a fix-GO → merged"
assert_audit_lacks "5134-g: not audited as a main-red fix" "main-red-declared"

# 5134-h — a fix-GO for another head does not unblock this one.
rm -f "$MOG_FX_ROOT/.locks/go/"fix-main-red.77.*
go_write "$MOG_FX_ROOT" --fix-main-red 37964772913 77 "$GO_OLD"
mog5134_run 0 "5134-h: fix-GO for an older head → merged as advisory"
assert_audit_has "5134-h: a rejected declaration is audited as an advisory" "via=advisory"
assert_audit_lacks "5134-h: and never as a declared fix" "main-red-declared"
rm -rf "$MOG_FX_ROOT"

# ── suite= declaration: say what is accepted ────────────────────
# The matcher takes a failed job name without spaces, or any .sh script named on
# an ##[error] line; an undeclared red is now an advisory, not a refusal.
STUB_RUN_LIST_JSON="$MOG_RUN_RED" run_mog 0 "5135-a: red main, undeclared → merged as advisory"
assert_err_has "5135-a: prints the MAIN-RED advisory" "MAIN-RED advisory:"
# 5135-b — a non-test- .sh named on an ##[error] line IS accepted, as stated.
MOG_RUN_LOG4="$(mktemp "${TMPDIR:-/tmp}/mog-runlog4.XXXXXX")" || { echo "FAIL: 5135 setup: mktemp" >&2; exit 1; }
printf '%s\t%s\t%s\n' \
    'lint (ubuntu-latest)' 'UNKNOWN STEP' '2026-10-09T17:54:35.0819579Z ##[error]scripts/ci/check-foo.sh exited 1' > "$MOG_RUN_LOG4"
STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_RUN_LOG_FILE="$MOG_RUN_LOG4" \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: suite=check-foo.sh')" \
    run_mog 0 "5135-b: a non-test- .sh named on an error line → merged"
rm -f "$MOG_RUN_LOG4"

# ── a re-run of a red main run still counts as red ─────────────
# Real window (gh run view, 2026-10-25): dispatch run 40226871918 at be152579
# failed on shard 2; while the chief re-ran it (attempt 2, in progress) the newest
# COMPLETED run was the older green schedule run 40208416958, and PR 3937
# merged through the gate. A re-run keeps its run id, so the gate reads the
# previous attempt of a run that is not completed and has attempt > 1.
MOG_RUN_RERUN='[{"attempt":2,"conclusion":"","createdAt":"2026-10-25T19:37:01Z","databaseId":40226871918,"event":"workflow_dispatch","headSha":"be152579752f51ff26575c459654b1245d0f5abd","status":"in_progress"},{"attempt":1,"conclusion":"success","createdAt":"2026-10-25T15:45:05Z","databaseId":40208416958,"event":"schedule","headSha":"3f196bdadad920756c87caec0838ece0205b863c","status":"completed"}]'
# 7656-a — red run being re-run, older green completed: an advisory merge.
STUB_RUN_LIST_JSON="$MOG_RUN_RERUN" STUB_RUN_ATTEMPT_CONCLUSION=failure \
    run_mog 0 "7656-a: red run being re-run, older green behind it → merged as advisory"
assert_audit_has "7656-a: audited as an advisory merge" "via=advisory"
assert_err_has "7656-a: stderr names the re-run run" "40226871918"
assert_err_has "7656-a: stderr says it is being re-run" "re-run"
assert_gh_has "7656-a: the previous attempt was read" "run view 40226871918"
assert_merge_has "7656-a: the merge ran" "--squash"
# 7656-b — the previous attempt of the re-run was green: main is green.
STUB_RUN_LIST_JSON="$MOG_RUN_RERUN" STUB_RUN_ATTEMPT_CONCLUSION=success \
    run_mog 0 "7656-b: re-run of a green attempt → merged"
assert_audit_lacks "7656-b: green-main merge is not an advisory" "via=advisory"
# 7656-c — a FRESH run in progress (attempt 1) is not a re-run: the older
# completed green run still decides, as before.
STUB_RUN_LIST_JSON='[{"attempt":1,"conclusion":"","createdAt":"2026-10-25T19:37:01Z","databaseId":40226871918,"event":"workflow_dispatch","headSha":"be152579752f51ff26575c459654b1245d0f5abd","status":"in_progress"},{"attempt":1,"conclusion":"success","createdAt":"2026-10-25T15:45:05Z","databaseId":40208416958,"event":"schedule","headSha":"3f196bdadad920756c87caec0838ece0205b863c","status":"completed"}]' \
    run_mog 0 "7656-c: a fresh first-attempt run in progress falls back to the older green run → merged"
assert_gh_lacks "7656-c: no attempt lookup for a first attempt" "run view"
# 7656-d — the previous attempt cannot be read: main's state is unverified.
STUB_RUN_LIST_JSON="$MOG_RUN_RERUN" STUB_RUN_ATTEMPT_FAIL=1 \
    run_mog 22 "7656-d: unreadable previous attempt → exit 22"
assert_err_has "7656-d: stderr says main is pending" "main-pending"
no_merge_call "7656-d: no merge call"
# 7656-e — the PR declares itself the fix for the re-run run: merged.
STUB_RUN_LIST_JSON="$MOG_RUN_RERUN" STUB_RUN_ATTEMPT_CONCLUSION=failure \
    STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: run=40226871918')" \
    run_mog 0 "7656-e: valid run= declaration for the re-run run → merged"
assert_audit_has "7656-e: audited as the declared fix" "main-red-declared"
# 7656-f — the previous attempt was cancelled: it says nothing, so the older
# completed run decides, as for a cancelled completed run.
STUB_RUN_LIST_JSON="$MOG_RUN_RERUN" STUB_RUN_ATTEMPT_CONCLUSION=cancelled \
    run_mog 0 "7656-f: re-run of a cancelled attempt falls back to the older green run → merged"
assert_audit_lacks "7656-f: green-main merge is not an advisory" "via=advisory"

# ── a cap-timeout-only red in suites the PR does not reach passes ──
# The real failed log (gh run view --log-failed, 2026-10-25) of run 40226871918:
# shard 2 lost two suites to the runner's watchdog with their assertions passing,
# a third was a flake that passed on retry, and the rollup job failed with it.
# Fields are job, step, "timestamp message".
mog7658_row() { printf '%s\t%s\t%s\n' "$1" 'Run bash scripts/ci/home-canary.sh --shard 2/8 .' "2026-10-25T20:19:12.9906759Z $2"; }
# mog7658_log <file> <Failed-suites line>... — the shard's summary block, then the rollup.
mog7658_log() {
    local f="$1" l; shift
    {
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'Flaked suites (ledger: failed-suite-logs/flake-ledger.jsonl):'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '  scripts/test-adopt-sequences.sh (first run rc=124, passed on retry)'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' ' TIMED OUT: 2 (counted in FAIL)'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'Failed suites:'
        for l in "$@"; do mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' "$l"; done
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'Disposition order for a red suite:'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '  1. CAP EXCEEDED  -> the runner'"'"'s watchdog killed it; re-run that suite alone'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '                      (or raise its entry in _suite_timeout_for) before reading it as a bug.'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '  2. fails on main too -> pre-existing; not your diff.'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '  3. passes on main    -> re-run it ALONE before blaming your diff.'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'home-canary: FAIL runner exited rc=1'
        mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' '##[error]Process completed with exit code 1.'
        printf '%s\t%s\t%s\n' 'shell-unit (dispatch verify) (ubuntu-latest)' 'Every gating shell-unit shard must have passed' \
            '2026-10-25T20:19:29.2847420Z ##[error]shell-unit shards did not all pass (matrix rollup: failure) — see the shell-unit-shard jobs on this run.'
    } > "$f"
}
MOG7658_S1=scripts/cr/test-pr-check-rounds.sh
MOG7658_S2=scripts/hooks/test-block-write-into-main-checkout-forms.sh
MOG7658_CAP1="  $MOG7658_S1 (CAP EXCEEDED after 1203s, cap 1200s — no exit status observed, assertions passing)"
MOG7658_CAP2="  $MOG7658_S2 (CAP EXCEEDED after 603s, cap 600s — no exit status observed, assertions passing)"
MOG7658_RUN='[{"attempt":1,"conclusion":"failure","createdAt":"2026-10-25T19:37:01Z","databaseId":40226871918,"event":"workflow_dispatch","headSha":"be152579752f51ff26575c459654b1245d0f5abd","status":"completed"},{"attempt":1,"conclusion":"success","createdAt":"2026-10-25T15:45:05Z","databaseId":40208416958,"event":"schedule","headSha":"3f196bdadad920756c87caec0838ece0205b863c","status":"completed"}]'
MOG7658_LOG_CAP="$(mktemp "${TMPDIR:-/tmp}/mog-7658-cap.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_ASSERT="$(mktemp "${TMPDIR:-/tmp}/mog-7658-assert.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_CAPFAIL="$(mktemp "${TMPDIR:-/tmp}/mog-7658-capfail.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_APT="$(mktemp "${TMPDIR:-/tmp}/mog-7658-apt.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
mog7658_log "$MOG7658_LOG_CAP" "$MOG7658_CAP1" "$MOG7658_CAP2"
mog7658_log "$MOG7658_LOG_ASSERT" "$MOG7658_CAP1" "  $MOG7658_S2 (rc=1)"
mog7658_log "$MOG7658_LOG_CAPFAIL" "$MOG7658_CAP1" "  $MOG7658_S2 (CAP EXCEEDED after 603s, cap 600s — no exit status observed)"
# The shard that died in apt-get before any suite ran (run 37964772913): no Failed-suites block.
printf '%s\t%s\t%s\n' \
    'shell-unit-shard (ubuntu-latest, 8)' 'UNKNOWN STEP' '2026-10-09T17:44:06.7905525Z Run apt-get install at' \
    'shell-unit-shard (ubuntu-latest, 8)' 'UNKNOWN STEP' '2026-10-09T17:54:35.0819579Z ##[error]Process completed with exit code 124.' \
    'shell-unit (ubuntu-latest)' 'UNKNOWN STEP' '2026-10-09T18:24:30.5567074Z ##[error]shell-unit shards did not all pass (matrix rollup: failure)' > "$MOG7658_LOG_APT"
# The cap shard plus a failure that is not a suite row. home-canary.sh exits 1 on its own
# for a honeytoken leak, an unreadable atime or a timeout, and the sibling jobs of a run
# can fail for reasons that name no suite.
MOG7658_LOG_HC="$(mktemp "${TMPDIR:-/tmp}/mog-7658-hc.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_LINT="$(mktemp "${TMPDIR:-/tmp}/mog-7658-lint.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_DEAD="$(mktemp "${TMPDIR:-/tmp}/mog-7658-dead.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_NOEXIT="$(mktemp "${TMPDIR:-/tmp}/mog-7658-noexit.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_ODD="$(mktemp "${TMPDIR:-/tmp}/mog-7658-odd.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_ROLL="$(mktemp "${TMPDIR:-/tmp}/mog-7658-roll.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
# The rollup job failed in a step other than the shard-result check.
{ cat "$MOG7658_LOG_CAP"; printf '%s\t%s\t%s\n' 'shell-unit (dispatch verify) (ubuntu-latest)' 'Every shard ran exactly the selection' '2026-10-25T20:19:31.2858837Z ##[error]Process completed with exit code 1.'; } > "$MOG7658_LOG_ROLL"
# The cap shard failed a second step of its own job after the runner step.
MOG7658_LOG_STEP2="$(mktemp "${TMPDIR:-/tmp}/mog-7658-step2.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
{ cat "$MOG7658_LOG_CAP"; printf '%s\t%s\t%s\n' 'shell-unit-shard (ubuntu-latest, 2)' 'Upload shard manifest' '2026-10-25T20:19:40.1234567Z ##[error]Unable to upload the shard manifest'; } > "$MOG7658_LOG_STEP2"
# The runner stopped before every suite ran (its run budget, or SUITE_STOP_ON_FAIL).
MOG7658_LOG_BUDGET="$(mktemp "${TMPDIR:-/tmp}/mog-7658-budget.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
MOG7658_LOG_STOPPED="$(mktemp "${TMPDIR:-/tmp}/mog-7658-stopped.XXXXXX")" || { echo "FAIL: 7658 setup: mktemp" >&2; exit 1; }
{ cat "$MOG7658_LOG_CAP"; mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'ERROR: run budget of 3000s expired — these suites never ran:'; } > "$MOG7658_LOG_BUDGET"
{ cat "$MOG7658_LOG_CAP"; mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'STOPPED: SUITE_STOP_ON_FAIL=1 — a suite failed, so these suites never ran:'; } > "$MOG7658_LOG_STOPPED"
# The run's job list (gh run view --json jobs). The failed log only shows jobs that wrote
# a failure, so a shard that never ran has no lines there.
MOG7658_JOBS_OK='{"jobs":[{"name":"plan","conclusion":"success"},{"name":"lint (ubuntu-latest)","conclusion":"success"},{"name":"macos-extras","conclusion":"skipped"},{"name":"shell-unit-shard (ubuntu-latest, 2)","conclusion":"failure"},{"name":"shell-unit (dispatch verify) (ubuntu-latest)","conclusion":"failure"}]}'
MOG7658_JOBS_QUEUED='{"jobs":[{"name":"shell-unit-shard (ubuntu-latest, 2)","conclusion":"failure"},{"name":"shell-unit-shard (ubuntu-latest, 5)","conclusion":null},{"name":"shell-unit (dispatch verify) (ubuntu-latest)","conclusion":"failure"}]}'
MOG7658_JOBS_CANCELLED='{"jobs":[{"name":"shell-unit-shard (ubuntu-latest, 2)","conclusion":"failure"},{"name":"shell-unit-shard (ubuntu-latest, 5)","conclusion":"cancelled"},{"name":"shell-unit (dispatch verify) (ubuntu-latest)","conclusion":"failure"}]}'
{ cat "$MOG7658_LOG_CAP"; mog7658_row 'shell-unit-shard (ubuntu-latest, 2)' 'home-canary: FAIL honeytoken reached the runner output (a suite printed the sandbox .env); lines:'; } > "$MOG7658_LOG_HC"
{ cat "$MOG7658_LOG_CAP"; printf '%s\t%s\t%s\n' 'lint (ubuntu-latest)' 'Run shellcheck' '2026-10-25T20:19:12.9906759Z ##[error]Process completed with exit code 1.'; } > "$MOG7658_LOG_LINT"
# A shard whose runner stopped on its budget: it exits 1 with no Failed-suites block.
{ cat "$MOG7658_LOG_CAP"; printf '%s\t%s\t%s\n' 'shell-unit-shard (ubuntu-latest, 8)' 'Run bash scripts/ci/home-canary.sh --shard 8/8 .' '2026-10-25T20:19:12.9906759Z home-canary: FAIL runner exited rc=1'; } > "$MOG7658_LOG_DEAD"
grep -v 'home-canary: FAIL runner exited rc=1' "$MOG7658_LOG_CAP" > "$MOG7658_LOG_NOEXIT"
mog7658_log "$MOG7658_LOG_ODD" "$MOG7658_CAP1" "  scripts/with space/test-x.sh (rc=1)"
# cap_setup <anchor> — base on origin main (the real impacted-suites selector, one
# suite per capped test, each driving one tool), the PR head at refs/pull/77/head.
# MOG_CAP_TOUCH=doc|tool picks what the PR changes (a doc nobody reads, or the
# tool the first suite drives); MOG_CAP_NOPULL=1 leaves the PR ref off origin.
MOG_CAP_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cap_setup() {
    local a="$1"
    local g="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
    mkdir -p "$a/scripts/cr" "$a/scripts/hooks" "$a/scripts/lib" "$a/docs" || return 1
    cp "$MOG_CAP_ROOT/scripts/cr/impacted-suites.sh" "$MOG_CAP_ROOT/scripts/cr/anchor-handoff.sh" "$a/scripts/cr/" || return 1
    printf '#!/usr/bin/env bash\nbash scripts/lib/tool-a.sh\n' > "$a/$MOG7658_S1"
    printf '#!/usr/bin/env bash\nbash scripts/lib/tool-b.sh\n' > "$a/$MOG7658_S2"
    printf '#!/usr/bin/env bash\necho a\n' > "$a/scripts/lib/tool-a.sh"
    printf '#!/usr/bin/env bash\necho b\n' > "$a/scripts/lib/tool-b.sh"
    printf 'base\n' > "$a/docs/note.md"
    $g -C "$a" add scripts docs && $g -C "$a" commit -qm base && $g -C "$a" push -q origin HEAD:main || return 1
    case "${MOG_CAP_TOUCH:-doc}" in
        tool) printf '# changed\n' >> "$a/scripts/lib/tool-a.sh" ;;
        *) printf 'pr\n' > "$a/docs/note.md" ;;
    esac
    $g -C "$a" add scripts docs && $g -C "$a" commit -qm pr || return 1
    MOG_SETUP_SHA="$($g -C "$a" rev-parse HEAD)"
    if [ "${MOG_CAP_NOPULL:-0}" != 1 ]; then $g -C "$a" push -q origin HEAD:refs/pull/77/head || return 1; fi
    return 0
}
cap_run() {
    MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=cap_setup STUB_RUN_LIST_JSON="$MOG7658_RUN" \
        STUB_PR_FILES_JSON='[{"filename":"docs/note.md"}]' run_mog "$@"
}
# 7658-a (RED, real window) — both red suites hit the watchdog with assertions
# passing and the PR changes only a doc: the gate passes and prints why.
STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-a: cap-timeout-only red, PR reaches neither suite → merged"
assert_err_has "7658-a: prints the class and both suites" "main-red: cap-only ($MOG7658_S1, $MOG7658_S2)"
assert_err_has "7658-a: prints the reason it passes" "passes"
assert_err_lacks "7658-a: the flake that passed on retry is not a red suite" "test-adopt-sequences.sh"
assert_audit_has "7658-a: audited as a cap-only pass" "main-red-cap-only"
assert_audit_has "7658-a: audited with the cap-only route" "via=cap-only"
assert_merge_has "7658-a: the merge ran" "--squash"
if [ -z "$(git -C "$LAST_TMP" for-each-ref refs/himmel-mog-mr)" ]; then pass; else fail "7658-a: the private refs were deleted again"; fi
# 7658-b — one failed suite is a real assertion failure (rc=1): an advisory merge.
STUB_RUN_LOG_FILE="$MOG7658_LOG_ASSERT" cap_run 0 "7658-b: a cap timeout plus an assertion failure → merged as advisory"
assert_err_has "7658-b: prints the class and the suites" "main-red: assertion ($MOG7658_S1, $MOG7658_S2)"
assert_audit_has "7658-b: audited as an advisory merge" "via=advisory"
assert_audit_has "7658-b: the audit line names the class and the failed suites" "class=assertion suites=$MOG7658_S1,$MOG7658_S2"
assert_err_has "7658-b: the advisory names the failed suites" "MAIN-RED advisory:"
assert_merge_has "7658-b: the merge ran" "--squash"
# 7658-c — a cap exceeded WITHOUT assertions passing is not a clean cap: an advisory merge.
STUB_RUN_LOG_FILE="$MOG7658_LOG_CAPFAIL" cap_run 0 "7658-c: a cap timeout that did not have its assertions passing → merged as advisory"
assert_err_has "7658-c: prints the class" "main-red: assertion ("
assert_merge_has "7658-c: the merge ran" "--squash"
# 7658-d — cap-only, but the PR changes a tool the first capped suite drives.
MOG_CAP_TOUCH=tool STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-d: cap-timeout-only red in a suite the PR reaches → merged as advisory"
assert_err_has "7658-d: prints the class and only the reached suite" "main-red: cap-overlap ($MOG7658_S1)"
if [ -z "$(git -C "$LAST_TMP" for-each-ref refs/himmel-mog-mr)" ]; then pass; else fail "7658-d: the private refs were deleted again"; fi
assert_audit_has "7658-d: audited as an advisory merge" "via=advisory"
assert_merge_has "7658-d: the merge ran" "--squash"
# 7658-e — the PR head cannot be fetched, so what it reaches is unknown: an advisory, not a cap pass.
MOG_CAP_NOPULL=1 STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-e: cap-only red but the PR head is unfetchable → merged as advisory"
assert_err_has "7658-e: prints the class" "main-red: cap-unverified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-e: the merge ran" "--squash"
# 7658-f — the failed log cannot be read: an advisory, not a cap pass.
STUB_RUN_VIEW_FAIL=1 cap_run 0 "7658-f: unreadable failed log → merged as advisory"
assert_err_has "7658-f: prints the class" "main-red: unclassified ()"
assert_merge_has "7658-f: the merge ran" "--squash"
# 7658-g — a red with no Failed-suites block (the apt-get exit-124 log of run
# 37964772913, 5115) is no cap timeout: an advisory merge.
STUB_RUN_LOG_FILE="$MOG7658_LOG_APT" cap_run 0 "7658-g: a red whose log names no failed suite → merged as advisory"
assert_err_has "7658-g: prints the class" "main-red: unclassified ()"
assert_merge_has "7658-g: the merge ran" "--squash"
# 7658-h — a declared fix still wins over the classifier and is not a cap pass.
STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: run=40226871918')" \
    cap_run 0 "7658-h: the declared fix for the run → merged by the declaration"
assert_audit_has "7658-h: audited as the declared fix" "via=run=40226871918"
assert_audit_lacks "7658-h: not audited as a cap-only pass" "main-red-cap-only"
# 7658-i..m — a clean cap row does not make the red cap-only when the run failed for a
# reason that names no suite, or the shard did not end on the runner's own exit.
STUB_RUN_LOG_FILE="$MOG7658_LOG_HC" cap_run 0 "7658-i: cap rows plus a home-canary honeytoken FAIL → merged as advisory"
assert_err_has "7658-i: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-i: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_LINT" cap_run 0 "7658-j: cap rows plus a failed job that is not a shell-unit job → merged as advisory"
assert_err_has "7658-j: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-j: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_DEAD" cap_run 0 "7658-k: cap rows plus a shard that exited 1 with no Failed-suites block → merged as advisory"
assert_err_has "7658-k: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-k: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_NOEXIT" cap_run 0 "7658-l: cap rows but the shard never printed the runner's own exit line → merged as advisory"
assert_err_has "7658-l: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-l: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_ODD" cap_run 0 "7658-m: a Failed-suites row the classifier cannot parse → merged as advisory"
assert_err_has "7658-m: prints the class" "main-red: unclassified ($MOG7658_S1)"
assert_merge_has "7658-m: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_ROLL" cap_run 0 "7658-n: cap rows plus a rollup job that failed in another step → merged as advisory"
assert_err_has "7658-n: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-n: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_STEP2" cap_run 0 "7658-p: cap rows plus a second failed step in the same shard job → merged as advisory"
assert_err_has "7658-p: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-p: the merge ran" "--squash"
# A shard that never ran writes no failed log, so the log alone cannot show it.
STUB_RUN_JOBS_JSON="$MOG7658_JOBS_QUEUED" STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-q: cap rows plus a shard that stayed queued, no log lines → merged as advisory"
assert_err_has "7658-q: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-q: the merge ran" "--squash"
STUB_RUN_JOBS_JSON="$MOG7658_JOBS_CANCELLED" STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-r: cap rows plus a cancelled shard, no log lines → merged as advisory"
assert_err_has "7658-r: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-r: the merge ran" "--squash"
STUB_RUN_JOBS_FAIL=1 STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-s: cap rows but the run's job list cannot be read → merged as advisory"
assert_err_has "7658-s: prints the class" "main-red: unclassified ()"
assert_merge_has "7658-s: the merge ran" "--squash"
# Control: the real shape of run 40226871918, every non-success job has failed-log lines.
STUB_RUN_JOBS_JSON="$MOG7658_JOBS_OK" STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7658-t: cap rows, every failed job shows in the log, the rest passed or skipped → merged"
assert_err_has "7658-t: prints the pass reason" "main-red: cap-only ($MOG7658_S1, $MOG7658_S2)"
STUB_RUN_LOG_FILE="$MOG7658_LOG_BUDGET" cap_run 0 "7658-u: cap rows plus the runner's run-budget stop → merged as advisory"
assert_err_has "7658-u: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-u: the merge ran" "--squash"
STUB_RUN_LOG_FILE="$MOG7658_LOG_STOPPED" cap_run 0 "7658-v: cap rows plus the runner's SUITE_STOP_ON_FAIL stop → merged as advisory"
assert_err_has "7658-v: prints the class" "main-red: unclassified ($MOG7658_S1, $MOG7658_S2)"
assert_merge_has "7658-v: the merge ran" "--squash"
# 7658-o — the classifier matches text other files own: the rollup step name in ci.yml,
# the runner's exit line in home-canary.sh and the cap and stop rows in run-shell-tests.sh.
# shellcheck disable=SC2016
if grep -qF 'name: Every gating shell-unit shard must have passed' "$MOG_CAP_ROOT/.github/workflows/ci.yml" \
    && grep -qF 'FAIL runner exited rc=$rc' "$MOG_CAP_ROOT/scripts/ci/home-canary.sh" \
    && grep -qF 'no exit status observed, assertions passing)' "$MOG_CAP_ROOT/scripts/ci/run-shell-tests.sh" \
    && grep -qF "printf 'ERROR: run budget of " "$MOG_CAP_ROOT/scripts/ci/run-shell-tests.sh" \
    && grep -qF "printf 'STOPPED: SUITE_STOP_ON_FAIL=1" "$MOG_CAP_ROOT/scripts/ci/run-shell-tests.sh"; then
    pass
else
    fail "7658-o: ci.yml, home-canary.sh and run-shell-tests.sh still print the text main_red_classify reads"
fi

# ── a merge that fixes a red main queues one CI run on main ────
# ci.yml has no push trigger, so without this the fix is first judged by the next
# scheduled sweep, hours later. The new run's id is the first workflow_dispatch
# run above the newest one listed before the dispatch.
mog7323_calls() { grep -c '^workflow run ' "$LAST_GH_LOG"; }
mog7323_after_merge() {  # <label>: the dispatch is logged after `pr merge`
    local m w
    m=$(grep -n '^pr merge ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
    w=$(grep -n '^workflow run ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
    if [ -n "$m" ] && [ -n "$w" ] && [ "$m" -lt "$w" ]; then pass; else fail "$1 (pr merge at gh log line '${m:-none}', workflow run at '${w:-none}')"; fi
}
MOG7323_BEFORE='[{"databaseId":40230000001}]'
MOG7323_AFTER='[{"databaseId":40230000002},{"databaseId":40230000001}]'
mog7323_fix() {  # <expect rc> <label> [run_mog args]: red main, PR 77 declares the fix
    STUB_RUN_LIST_JSON="$MOG_RUN_RED" STUB_PR_COMMITS_JSON="$(mog5115_commits 'Fixes-main-red: run=37964772913')" \
        STUB_DISPATCH_BEFORE_JSON="$MOG7323_BEFORE" STUB_DISPATCH_AFTER_JSON="${STUB_DISPATCH_AFTER_JSON-$MOG7323_AFTER}" run_mog "$@"
}
# 7323-a (RED) — the declared fix merges: one dispatch of ci.yml on main, after the merge.
mog7323_fix 0 "7323-a: declared main-red fix → merged"
if [ "$(mog7323_calls)" = 1 ]; then pass; else fail "7323-a: exactly one dispatch (got $(mog7323_calls))"; fi
assert_gh_has "7323-a: dispatches ci.yml" "workflow run ci.yml"
assert_gh_has "7323-a: on the base branch" "--ref main"
mog7323_after_merge "7323-a: the dispatch follows the merge"
assert_audit_has "7323-a: audits the dispatch with the new run's id" "MAIN-RECHECK dispatched run=40230000002"
# 7323-b — a chief-written fix-GO is the other way onto the red-main path.
MOG7323_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mog-7323.XXXXXX") || { echo "FAIL: 7323 setup: mktemp" >&2; exit 1; }
MOG7323_ROOT=$(cd "$MOG7323_ROOT" && pwd)
go_write "$MOG7323_ROOT" --fix-main-red 37964772913 77 "$GO_SHA"
HANDOVER_DIR="$MOG7323_ROOT" STUB_SHA="$GO_SHA" STUB_RUN_LIST_JSON="$MOG_RUN_RED" \
    STUB_DISPATCH_BEFORE_JSON="$MOG7323_BEFORE" STUB_DISPATCH_AFTER_JSON="$MOG7323_AFTER" \
    run_mog 0 "7323-b: fix-GO main-red fix → merged"
if [ "$(mog7323_calls)" = 1 ]; then pass; else fail "7323-b: exactly one dispatch (got $(mog7323_calls))"; fi
assert_audit_has "7323-b: audits the dispatch" "MAIN-RECHECK dispatched run=40230000002"
rm -rf "$MOG7323_ROOT"
# 7323-c — an ordinary merge on a green main dispatches nothing.
run_mog 0 "7323-c: ordinary merge, green main → merged"
if [ "$(mog7323_calls)" = 0 ]; then pass; else fail "7323-c: no dispatch (got $(mog7323_calls))"; fi
assert_audit_lacks "7323-c: no recheck audited" "MAIN-RECHECK"
# 7323-d — a failed dispatch is a warning; the merge still succeeds.
STUB_WORKFLOW_RUN_FAIL=1 mog7323_fix 0 "7323-d: dispatch fails → merge still exits 0"
assert_err_has "7323-d: warns about the dispatch" "WARN: MAIN-RECHECK dispatch failed"
assert_audit_has "7323-d: audits the failed dispatch" "MAIN-RECHECK dispatch-failed"
assert_merge_has "7323-d: the merge ran" "--squash"
if [ "$(mog7323_calls)" = 1 ]; then pass; else fail "7323-d: one attempt, no retry (got $(mog7323_calls))"; fi
# 7323-e — dispatched, but the new run is not listed yet: still success, run id unknown.
STUB_DISPATCH_AFTER_JSON="$MOG7323_BEFORE" mog7323_fix 0 "7323-e: dispatched run not listed → merge still exits 0"
assert_audit_has "7323-e: audits the dispatch without an id" "MAIN-RECHECK dispatched run=unknown"
# 7323-f — the merge went through gh's error path but the PR is MERGED: same recheck.
STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED mog7323_fix 0 "7323-f: gh rc!=0 but PR MERGED → merged"
if [ "$(mog7323_calls)" = 1 ]; then pass; else fail "7323-f: exactly one dispatch (got $(mog7323_calls))"; fi
assert_audit_has "7323-f: audits the dispatch" "MAIN-RECHECK dispatched run=40230000002"
# 7323-g — a merge that did not complete dispatches nothing.
STUB_MERGE_FAIL=1 STUB_POST_STATE=OPEN mog7323_fix 15 "7323-g: merge fails, PR still OPEN → exit 15"
if [ "$(mog7323_calls)" = 0 ]; then pass; else fail "7323-g: no dispatch (got $(mog7323_calls))"; fi
# 7323-h — the cap-only pass is no fix: nothing to re-check.
STUB_RUN_LOG_FILE="$MOG7658_LOG_CAP" cap_run 0 "7323-h: cap-only pass → merged"
if [ "$(mog7323_calls)" = 0 ]; then pass; else fail "7323-h: no dispatch (got $(mog7323_calls))"; fi
assert_audit_lacks "7323-h: no recheck audited" "MAIN-RECHECK"
rm -f "$MOG7658_LOG_CAP" "$MOG7658_LOG_ASSERT" "$MOG7658_LOG_CAPFAIL" "$MOG7658_LOG_APT" "$MOG7658_LOG_HC" "$MOG7658_LOG_LINT" "$MOG7658_LOG_DEAD" "$MOG7658_LOG_NOEXIT" "$MOG7658_LOG_ODD" "$MOG7658_LOG_ROLL" "$MOG7658_LOG_STEP2" "$MOG7658_LOG_BUDGET" "$MOG7658_LOG_STOPPED"

# ── merge-time plugin version-bump recheck ──────────────────────
# A PR that changes a plugin bumps its version above the base; a
# release cut (a change to the root VERSION file) raises every plugin it touches.
# Two PRs that raise a plugin to the same version both go green in CI;
# only the merge gate sees the live base. The fixture manifest is copied from the
# real himmel-ops plugin.json at this checkout, never invented.
BP_REAL_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
BP_MAN="marketplace/plugins/himmel-ops/.claude-plugin/plugin.json"
BP_BASE_VER="$(jq -r .version "$BP_REAL_ROOT/$BP_MAN")"
bp_plus() { printf '%s.%s.%s' "$(printf '%s' "$1" | cut -d. -f1)" "$(printf '%s' "$1" | cut -d. -f2)" "$(( $(printf '%s' "$1" | cut -d. -f3) + $2 ))"; }
BP_V1="$(bp_plus "$BP_BASE_VER" 1)"
BP_V2="$(bp_plus "$BP_BASE_VER" 2)"
# bp_setup <anchor> — base B0 (real checker + manifest) on origin main, the PR
# head at refs/pull/77/head, then a sibling landing on main AFTER the PR
# branched. MOG_BUMP_SIB / MOG_BUMP_PR set the two plugin versions (default:
# unchanged); a sibling that changes it is a release cut, and MOG_BUMP_REL=1
# makes the PR one too; MOG_BUMP_NOPULL=1 leaves the PR ref off origin; MOG_BUMP_EVIL=1 plants a
# permissive checker in the PR head; MOG_BUMP_MOVED=1 advances the PR ref past
# the certified head.
bp_setup() {
    local a="$1" b0
    local g="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
    mkdir -p "$a/scripts/lib" "$a/marketplace/plugins/himmel-ops/.claude-plugin" || return 1
    cp "$BP_REAL_ROOT/scripts/check-plugin-drift.sh" "$a/scripts/check-plugin-drift.sh" || return 1
    cp "$BP_REAL_ROOT/scripts/lib/vm-mode.sh" "$a/scripts/lib/vm-mode.sh" || return 1
    cp "$BP_REAL_ROOT/$BP_MAN" "$a/$BP_MAN" || return 1
    printf 'base\n' > "$a/marketplace/plugins/himmel-ops/a.txt"
    printf '1.0.0\n' > "$a/VERSION"
    # MOG_BUMP_EMPTY=<blob> commits that checker blob EMPTY at the
    # base tip; MOG_BUMP_MISSING=<blob> leaves it out of the base tip entirely.
    local bp_b; local -a bp_add=()
    for bp_b in scripts/check-plugin-drift.sh scripts/lib/vm-mode.sh; do
        [ "${MOG_BUMP_EMPTY:-}" != "$bp_b" ] || : > "$a/$bp_b"
        # MOG_BUMP_STUBCHK=silent|noise commits a non-empty base-tip
        # checker that exits 0 with no output / with unrelated output.
        if [ "$bp_b" = scripts/check-plugin-drift.sh ]; then
            case "${MOG_BUMP_STUBCHK:-}" in
                silent) printf '\n' > "$a/$bp_b" ;;
                noise) printf '#!/usr/bin/env bash\necho "all good"\nexit 0\n' > "$a/$bp_b" ;;
                legacy) printf '#!/usr/bin/env bash\necho "check-plugin-drift --bump-required: no plugin version changed outside a release cut"\nexit 0\n' > "$a/$bp_b" ;;
            esac
        fi
        if [ "${MOG_BUMP_MISSING:-}" = "$bp_b" ]; then rm -f "$a/$bp_b"; else bp_add+=("$bp_b"); fi
    done
    $g -C "$a" add "${bp_add[@]}" marketplace VERSION && $g -C "$a" commit -qm base && $g -C "$a" push -q origin HEAD:main || return 1
    b0="$($g -C "$a" rev-parse HEAD)"
    printf 'pr\n' > "$a/marketplace/plugins/himmel-ops/a.txt"
    jq --arg v "${MOG_BUMP_PR:-$BP_BASE_VER}" '.version=$v' "$a/$BP_MAN" > "$a/m.tmp" && mv "$a/m.tmp" "$a/$BP_MAN" || return 1
    [ "${MOG_BUMP_REL:-0}" != 1 ] || printf '1.0.1\n' > "$a/VERSION"
    if [ "${MOG_BUMP_EVIL:-0}" = 1 ]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$a/scripts/check-plugin-drift.sh"; fi
    # (the PR commit stages only the paths it changed; a blob left out of the
    # base tip stays out because the PR never re-adds it)
    $g -C "$a" add marketplace VERSION && { [ ! -f "$a/scripts/check-plugin-drift.sh" ] || $g -C "$a" add scripts/check-plugin-drift.sh; } \
        && $g -C "$a" commit -qm pr || return 1
    MOG_SETUP_SHA="$($g -C "$a" rev-parse HEAD)"
    if [ "${MOG_BUMP_NOPULL:-0}" != 1 ]; then $g -C "$a" push -q origin HEAD:refs/pull/77/head || return 1; fi
    if [ "${MOG_BUMP_MOVED:-0}" = 1 ]; then
        $g -C "$a" commit -q --allow-empty -m moved && $g -C "$a" push -q -f origin HEAD:refs/pull/77/head || return 1
    fi
    $g -C "$a" checkout -q -b sibling "$b0" || return 1
    printf 'sibling\n' > "$a/marketplace/plugins/himmel-ops/b.txt"
    jq --arg v "${MOG_BUMP_SIB:-$BP_BASE_VER}" '.version=$v' "$a/$BP_MAN" > "$a/m.tmp" && mv "$a/m.tmp" "$a/$BP_MAN" || return 1
    [ "${MOG_BUMP_SIB:-$BP_BASE_VER}" = "$BP_BASE_VER" ] || printf '1.0.1\n' > "$a/VERSION"
    $g -C "$a" add marketplace VERSION && $g -C "$a" commit -qm sibling && $g -C "$a" push -q origin HEAD:main || return 1
    return 0
}
BP_FILES='[{"filename":"marketplace/plugins/himmel-ops/a.txt"},{"filename":"marketplace/plugins/himmel-ops/.claude-plugin/plugin.json"}]'
bp_run() {
    MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=bp_setup STUB_PR_FILES_JSON="${STUB_PR_FILES_JSON-$BP_FILES}" run_mog "$@"
}
# 8368-a (RED) — the PR edits a plugin and bumps it above the base tip (the
# sibling edited it too, without a bump): the checker's "every changed plugin
# carries a version bump" line is a verdict, so it merges.
MOG_BUMP_PR="$BP_V1" \
    bp_run 0 "8368-a: a plugin edit with a version bump above the base tip → merged"
assert_audit_has "8368-a: audited as a plugin-bump pass" "PLUGIN-BUMP ok"
# 8368-b — a base-tip checker that still prints the legacy success line stays a verdict.
MOG_BUMP_STUBCHK=legacy \
    bp_run 0 "8368-b: legacy success line from an older base-tip checker → merged"
# 7310-b — a PR that edits a plugin without raising its version: refused.
bp_run 23 "7310-b: a plugin edit with no version bump → exit 23"
assert_err_has "7310-b: stderr names the plugin and the missing bump" "himmel-ops changed but its plugin.json version"
no_merge_call "7310-b: no merge call"
# 5188-a (RED) — a sibling release cut landed the SAME version after this cut's
# CI went green: two contents under one version → refused before any merge call.
MOG_BUMP_REL=1 MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5188-a: sibling cut landed the same version → exit 23"
assert_audit_has "5188-a: audited as a plugin-bump refusal" "REFUSED reason=plugin-bump"
assert_err_has "5188-a: stderr names the plugin" "himmel-ops"
assert_clear_not_invoked "5188-a: nothing mutated before the refusal"
no_merge_call "5188-a: no merge call"
# 5188-b — the cut goes past the sibling's version: merged.
MOG_BUMP_REL=1 MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V2" \
    bp_run 0 "5188-b: cut goes past the sibling → merged"
# 5188-c — the PR's own checker is permissive; the base tip's copy decides.
MOG_BUMP_EVIL=1 MOG_BUMP_REL=1 MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5188-c: a PR-side permissive checker does not decide → exit 23"
# 5188-d — fail closed: the PR ref cannot be fetched.
MOG_BUMP_NOPULL=1 bp_run 23 "5188-d: PR head unfetchable → exit 23"
# 5188-e — fail closed: the fetched head is not the certified head.
MOG_BUMP_MOVED=1 MOG_BUMP_REL=1 MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V2" \
    bp_run 23 "5188-e: fetched PR head differs from the certified head → exit 23"
assert_audit_has "5188-e: audited as a plugin-bump refusal" "REFUSED reason=plugin-bump"
assert_audit_has "5188-e: audited as a head-moved refusal" "phase=head-moved"
# 5188-f — a PR that touches no plugin file never reaches git (unchanged).
STUB_PR_FILES_JSON='[{"filename":"README.md"}]' MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 0 "5188-f: no plugin file in the PR → merged, gate skipped"
# 5188-g — the files endpoint stops at 3000 entries, so a list that long may
# have dropped the plugin paths: the trust-path gate refuses it before the
# recheck runs (exit 21).
BP_BIG=$(jq -nc '[range(3000) | {filename: ("docs/f\(.).md")}]')
STUB_PR_FILES_JSON="$BP_BIG" MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 21 "5188-g: a possibly truncated 3000-file list is refused at the trust-path gate → exit 21"
assert_err_has "5188-g: stderr names the 3000-row cap" "3000-row cap"
# 5188-g2 — 1500 renames pass the trust-path gate (1500 unique files) yet list
# 3000 names with their previous names, so the plugin-bump recheck still runs.
BP_REN=$(jq -nc '[range(1500) | {filename: ("docs/n\(.).md"), previous_filename: ("docs/o\(.).md")}]')
STUB_PR_FILES_JSON="$BP_REN" MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5188-g2: 1500 renames list 3000 names and still run the recheck → exit 23"
# 5188-h — a plugin file FIRST in a long list must still be seen (an early-exit
# grep under pipefail would SIGPIPE the producer and read as "no plugin file").
BP_LONG=$(jq -nc '[{filename: "marketplace/plugins/himmel-ops/a.txt"}] + [range(2500) | {filename: ("docs/f\(.).md")}]')
STUB_PR_FILES_JSON="$BP_LONG" MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5188-h: plugin file first in a 2501-file list is still found → exit 23"
# 5203-a (RED) — an EMPTY checker blob at the base tip runs as `exit 0`: the
# gate must refuse it, not read the empty script's success as a bump.
MOG_BUMP_EMPTY=scripts/check-plugin-drift.sh MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5203-a: empty check-plugin-drift.sh at the base tip → exit 23"
assert_audit_has "5203-a: audited as a checker-blob refusal" "phase=checker-blob"
assert_err_has "5203-a: stderr says the blob is empty" "empty"
no_merge_call "5203-a: no merge call"
# 5203-b — the sourced helper empty at the base tip is refused the same way.
MOG_BUMP_EMPTY=scripts/lib/vm-mode.sh MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V2" \
    bp_run 23 "5203-b: empty vm-mode.sh at the base tip → exit 23"
assert_audit_has "5203-b: audited as a checker-blob refusal" "phase=checker-blob"
# 5203-c — a checker blob absent at the base tip is refused (already fail-closed).
MOG_BUMP_MISSING=scripts/check-plugin-drift.sh MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V2" \
    bp_run 23 "5203-c: check-plugin-drift.sh missing at the base tip → exit 23"
assert_audit_has "5203-c: audited as a checker-blob refusal" "phase=checker-blob"
# 5208-a (RED) — a non-empty checker that exits 0 with NO output is no verdict.
MOG_BUMP_STUBCHK=silent MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5208-a: silent exit-0 checker at the base tip → exit 23"
assert_audit_has "5208-a: audited as a checker-blob refusal" "phase=checker-blob"
assert_audit_has "5208-a: audited as no success line" "no-success-line=1"
no_merge_call "5208-a: no merge call"
# 5208-b — a checker that exits 0 with unrelated output is refused the same way.
MOG_BUMP_STUBCHK=noise MOG_BUMP_SIB="$BP_V1" MOG_BUMP_PR="$BP_V1" \
    bp_run 23 "5208-b: exit-0 checker with unrelated output → exit 23"
assert_audit_has "5208-b: audited as a checker-blob refusal" "phase=checker-blob"
no_merge_call "5208-b: no merge call"

# --- 7001. Solo mode — an adopted project whose git config says
# himmel.mergeMode=solo merges a green PR with resolved threads and no GO file;
# the mode relaxes no gate and is refused wherever a GO is the rule. -----------
solo_cfg_setup() { git -C "$1" config --local himmel.mergeMode "${SOLO_CFG-solo}"; }
solo_clone_setup() {
    solo_cfg_setup "$1" && mkdir -p "$1/scripts/handover/chief-kit" \
        && : > "$1/scripts/handover/chief-kit/go.sh"
}

# 7001-a — solo config, no GO file: a green PR merges, pinned and audited as solo.
MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001a" \
    run_mog 0 "7001-a: solo mode, green PR, no GO file → merged"
assert_merge_has "7001-a: merge pins the certified head" "--match-head-commit solo7001a"
assert_audit_has "7001-a: the merge is audited as solo" "mode=solo"
assert_audit_has "7001-a: MERGED recorded" "MERGED repo="

# 7001-b — solo mode keeps the green gate: red checks or an open review thread
# (check-ci exit 3) refuse with no merge call.
MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001b" STUB_CI_RC=3 \
    run_mog 14 "7001-b: solo mode, check-ci not green → exit 14"
assert_gh_lacks "7001-b: no merge attempted" "pr merge"

# 7001-c — a chief-spawned worker is never solo: the GO is the rule even when the
# project config says solo.
MOG_WRAP=_as_claude HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001c" \
    run_mog 17 "7001-c: solo config under a chief worker → exit 17"
assert_audit_has "7001-c: audited as a solo refusal" "phase=solo-chief-worker"
no_merge_call "7001-c: no merge call"

# 7001-c2 — an explicitly falsy marker is no worker: solo reads it the way the
# chief-GO gate does.
MOG_WRAP=_as_claude HIMMEL_CONSOLE_LEG=0 MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001i" \
    run_mog 0 "7001-c2: solo config, HIMMEL_CONSOLE_LEG=0 → merged"
assert_audit_has "7001-c2: audited as solo" "mode=solo"

# 7001-d — never in the himmel clone: an anchor carrying chief-kit/go.sh
# refuses the config rather than ignoring it.
MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_clone_setup STUB_SHA="solo7001d" \
    run_mog 17 "7001-d: solo config in the himmel clone → exit 17"
assert_audit_has "7001-d: audited as a solo refusal" "phase=solo-himmel-clone"
no_merge_call "7001-d: no merge call"

# 7001-e — a value other than solo fails closed.
SOLO_CFG=team MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001e" \
    run_mog 17 "7001-e: himmel.mergeMode=team → exit 17"
assert_audit_has "7001-e: audited as a solo refusal" "phase=solo-invalid-mode"
no_merge_call "7001-e: no merge call"

# 7001-e2 — a key that is present but empty is a value too, not an absent key.
SOLO_CFG='' MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=solo_cfg_setup STUB_SHA="solo7001h" \
    run_mog 17 "7001-e2: himmel.mergeMode set to empty → exit 17"
assert_audit_has "7001-e2: audited as a solo refusal" "phase=solo-invalid-mode"
no_merge_call "7001-e2: no merge call"

# 7001-f — no config: the default path is unchanged, merged and not labelled solo.
MOG_ANCHOR_GIT=1 STUB_SHA="solo7001f" \
    run_mog 0 "7001-f: no solo config → merged as before"
assert_audit_lacks "7001-f: not audited as solo" "mode=solo"

# 7001-g — the himmel path still needs its GO: a worker with no solo config and no
# GO file is refused.
MOG_WRAP=_as_claude HIMMEL_CONSOLE_LEG=1 HANDOVER_DIR="$GO_ROOT" MOG_ANCHOR_GIT=1 STUB_SHA="solo7001g" \
    run_mog 17 "7001-g: chief worker, no solo config, no GO → exit 17"
assert_audit_has "7001-g: still the chief-GO refusal" "phase=chief-go"

# --- 7390. Solo mode in an adopted project: the anchor is the himmel clone
# (it carries chief-kit/go.sh) and the merge runs from the adopted repo, which
# holds the config. The mode is read from, and the clone test made on, the PR's
# repo. -------------------------------------------------------------------------
SOLO_ADOPTED=$(mktemp -d "${TMPDIR:-/tmp}/mog-solo-adopted.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if ! git init -q "$SOLO_ADOPTED" || ! git -C "$SOLO_ADOPTED" config --local himmel.mergeMode solo; then
    echo "FAIL: cannot build the adopted-repo fixture" >&2; exit 1
fi
himmel_clone_setup() {
    mkdir -p "$1/scripts/handover/chief-kit" && : > "$1/scripts/handover/chief-kit/go.sh"
}
SOLO_HANDOVER=$(mktemp -d "${TMPDIR:-/tmp}/mog-solo-ho.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
# The himmel clone's origin names the harness repo, not the PR's.
SOLO_HIMMEL_URL=https://github.com/himmel-org/himmel.git

# 7390-R6 (RED) — mergeMode=solo in the adopted repo and, as the docs said, in
# the anchor: refused as the himmel clone before; merges solo now.
MOG_CWD="$SOLO_ADOPTED" HANDOVER_DIR="$SOLO_HANDOVER" MOG_ANCHOR_GIT=1 MOG_ANCHOR_URL="$SOLO_HIMMEL_URL" MOG_ANCHOR_SETUP=solo_clone_setup STUB_SHA="solo7390r6" \
    run_mog 0 "7390-R6: solo in an adopted repo, himmel-clone anchor, no GO → merged"
assert_audit_has "7390-R6: the merge is audited as solo" "mode=solo"
assert_audit_lacks "7390-R6: not refused as the himmel clone" "phase=solo-himmel-clone"

# 7390-R6b (RED) — the config only in the adopted repo is what selects the mode.
MOG_CWD="$SOLO_ADOPTED" HANDOVER_DIR="$SOLO_HANDOVER" MOG_ANCHOR_GIT=1 MOG_ANCHOR_URL="$SOLO_HIMMEL_URL" MOG_ANCHOR_SETUP=himmel_clone_setup STUB_SHA="solo7390r6b" \
    run_mog 0 "7390-R6b: solo set only in the adopted repo → merged"
assert_audit_has "7390-R6b: the merge is audited as solo" "mode=solo"

# 7390-R7 (RED) — a solo trust-path PR with no trust review stops for that
# reason (exit 21), not as the himmel clone (exit 17).
MOG_CWD="$SOLO_ADOPTED" HANDOVER_DIR="$SOLO_HANDOVER" MOG_ANCHOR_GIT=1 MOG_ANCHOR_URL="$SOLO_HIMMEL_URL" MOG_ANCHOR_SETUP=solo_clone_setup STUB_SHA="solo7390r7" \
    STUB_PR_FILES_JSON='[{"filename":".github/workflows/ci.yml"}]' \
    run_mog 21 "7390-R7: solo trust-path PR with no trust review → exit 21"
assert_audit_has "7390-R7: audited as a trust-path refusal" "REFUSED reason=trust-path"
no_merge_call "7390-R7: no merge call"

# 7390-c — a checkout posing as the PR's repo does not make the himmel clone
# solo: an anchor carrying go.sh whose origin names the PR's own repo refuses.
MOG_CWD="$SOLO_ADOPTED" HANDOVER_DIR="$SOLO_HANDOVER" MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=himmel_clone_setup STUB_SHA="solo7390c" \
    run_mog 17 "7390-c: solo cwd, himmel-clone anchor whose origin is the PR's repo → exit 17"
assert_audit_has "7390-c: audited as the himmel clone" "phase=solo-himmel-clone"
no_merge_call "7390-c: no merge call"

# 7390-d / 7390-e — the anchor's origin is read from its own config only: a
# global remote.origin.url naming another repo stands in for a missing one
# neither for solo nor for the static re-check's other-repo skip.
# The global origin is written after the anchor is built, whose own
# `remote add origin` it would otherwise collide with.
SOLO_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/mog-solo-gitconfig.XXXXXX") || { echo "FAIL: mktemp failed" >&2; exit 1; }
anchor_noorigin_setup() {
    git -C "$1" remote remove origin \
        && printf '[remote "origin"]\n\turl = %s\n' "$SOLO_HIMMEL_URL" > "$SOLO_GLOBAL_CFG"
}
himmel_clone_noorigin_setup() { himmel_clone_setup "$1" && anchor_noorigin_setup "$1"; }
: > "$SOLO_GLOBAL_CFG"
GIT_CONFIG_GLOBAL="$SOLO_GLOBAL_CFG" MOG_CWD="$SOLO_ADOPTED" HANDOVER_DIR="$SOLO_HANDOVER" MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=himmel_clone_noorigin_setup STUB_SHA="solo7390d" \
    run_mog 17 "7390-d: solo cwd, himmel-clone anchor with no origin of its own, global origin names another repo → exit 17"
assert_audit_has "7390-d: audited as the himmel clone" "phase=solo-himmel-clone"
no_merge_call "7390-d: no merge call"
: > "$SOLO_GLOBAL_CFG"
MERGE_STATIC_RECHECK=1 GIT_CONFIG_GLOBAL="$SOLO_GLOBAL_CFG" MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=anchor_noorigin_setup STUB_SHA="solo7390e" \
    run_mog 24 "7390-e: anchor with no origin of its own, global origin names another repo → re-check runs, refuses (exit 24)"
assert_audit_lacks "7390-e: the static re-check is not skipped as another repo" "STATIC-RECHECK skipped reason=other-repo"
rm -rf "$SOLO_ADOPTED" "$SOLO_HANDOVER" "$SOLO_GLOBAL_CFG"

cr_comment_count() { grep -c '^pr comment ' "$LAST_GH_LOG" 2>/dev/null || true; }
CR9697_LEDGER=$(mktemp "${TMPDIR:-/tmp}/mog-9697-ledger.XXXXXX") || { echo "FAIL: mktemp failed" >&2; exit 1; }

: > "$CR9697_LEDGER"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="owner/repo" CR_TRIGGER_SUPPRESS="" STUB_SHA="cr9697a" \
    run_mog 0 "9697-a: a head with no ledger row → merged"
if [ "$(cr_comment_count)" = "1" ]; then pass; else fail "9697-a: expected exactly one pr comment, got $(cr_comment_count)"; fi
assert_gh_has "9697-a: the one post is the CodeRabbit trigger on the PR" "pr comment 77 --repo owner/repo --body @coderabbitai review"
assert_merge_has "9697-a: the merge still runs at the certified head" "--match-head-commit cr9697a"
if grep -qxF "owner/repo 77 cr9697a" "$CR9697_LEDGER"; then pass; else fail "9697-a: the head was not recorded in the ledger"; fi

printf 'owner/repo 77 cr9697b\n' > "$CR9697_LEDGER"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="owner/repo" CR_TRIGGER_SUPPRESS="" STUB_SHA="cr9697b" \
    run_mog 0 "9697-b: a head already in the ledger → merged"
assert_gh_lacks "9697-b: no second trigger" "pr comment"
assert_merge_has "9697-b: merged" "--match-head-commit cr9697b"

: > "$CR9697_LEDGER"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="" CR_TRIGGER_SUPPRESS="" STUB_SHA="cr9697c" \
    run_mog 0 "9697-c: an unarmed repo → merged"
assert_gh_lacks "9697-c: no trigger on an unarmed repo" "pr comment"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="someone/else" CR_TRIGGER_SUPPRESS="" STUB_SHA="cr9697c2" \
    run_mog 0 "9697-c2: a foreign repo → merged"
assert_gh_lacks "9697-c2: no trigger on a foreign repo" "pr comment"

: > "$CR9697_LEDGER"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="owner/repo" CR_TRIGGER_SUPPRESS="" STUB_PR_COMMENT_FAIL=1 STUB_SHA="cr9697d" \
    run_mog 0 "9697-d: a failed trigger post → merged"
assert_gh_has "9697-d: the post was attempted" "pr comment 77"
assert_merge_has "9697-d: merged anyway" "--match-head-commit cr9697d"
if [ -s "$CR9697_LEDGER" ]; then fail "9697-d: a failed post was recorded in the ledger"; else pass; fi

: > "$CR9697_LEDGER"
CR_TRIGGER_LEDGER_PATH="$CR9697_LEDGER" CR_TRIGGER_REPOS="owner/repo" CR_TRIGGER_SUPPRESS="" STUB_SHA="cr9697e" \
    run_mog 0 "9697-e: a dry run" -- --dry-run
assert_gh_lacks "9697-e: a dry run posts no trigger" "pr comment"
rm -f "$CR9697_LEDGER"

bk_title="feat(jira): [HIMMEL-374] reconciler"
bk_out_line="OUTSIDE HIMMEL-374 v1.1.4 current=v1.1.3 open=5"
bk_root="$(mktemp -d "${TMPDIR:-/tmp}/mog-bk.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
bk_arm() { mkdir -p "$bk_root/consoles"; : > "$bk_root/consoles/chief.md"; }
bk_inbox_lines() { grep -c . "$bk_root/consoles/chief.md" 2>/dev/null || true; }
assert_bk_rows() {
    local n; n=$(grep -c '"event":"bucket-leak"' "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null || true)
    if [ "${n:-0}" = "$2" ]; then pass; else fail "$1 (bucket-leak rows: ${n:-0}, want $2; rows: $(cat "$LAST_TMP/ts/status-events.jsonl" 2>/dev/null))"; fi
}
assert_bk_inbox() {
    local n; n=$(bk_inbox_lines)
    if [ "${n:-0}" = "$2" ]; then pass; else fail "$1 (inbox lines: ${n:-0}, want $2: $(cat "$bk_root/consoles/chief.md" 2>/dev/null))"; fi
}

bk_arm
MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-a: an OUTSIDE merge is not stopped"
assert_audit_has "9001-a: the audit line carries bucket=OUTSIDE" " bucket=OUTSIDE"
assert_err_has "9001-a: the stderr line names version, current and open count" "merge-on-green: LEAK HIMMEL-374 merged outside the bucket: in v1.1.4, current v1.1.3, 5 open (PR #77). Not stopped."
assert_bk_rows "9001-a: one bucket-leak row" 1
assert_status_row "9001-a: the row names key, pr, head and verdict" '.event == "bucket-leak" and .key == "HIMMEL-374" and .pr == "77" and .head == "abc123def456" and .verdict == "OUTSIDE"'
assert_bk_inbox "9001-a: one line in the chief inbox" 1
if grep -qF 'Bucket leak, not stopped: PR #77 merged. feat(jira): [HIMMEL-374] reconciler. It sits in v1.1.4; current is v1.1.3, 5 open.' "$bk_root/consoles/chief.md"; then pass
else fail "9001-a: the inbox line holds the title, version, current and open count ($(cat "$bk_root/consoles/chief.md"))"; fi
if [ "$(alert_lines)" = "0" ]; then pass; else fail "9001-a: the operator alert sink saw an alert ($(cat "$LAST_ALERT_LOG"))"; fi # read-sink-ok: the suite's own alert-log fixture file

bk_arm
MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="OUTSIDE HIMMEL-374 none current=v1.1.3 open=2" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-a2: an OUTSIDE merge of a ticket with no version"
assert_err_has "9001-a2: the stderr line says none" "merged outside the bucket: in none, current v1.1.3, 2 open (PR #77). Not stopped."
if grep -qF 'It sits in no version; current is v1.1.3, 2 open.' "$bk_root/consoles/chief.md"; then pass
else fail "9001-a2: the inbox line says no version ($(cat "$bk_root/consoles/chief.md"))"; fi

rm -f "$bk_root/consoles/chief.md"
MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-b: OUTSIDE with no armed inbox"
assert_audit_has "9001-b: the field is still written" " bucket=OUTSIDE"
assert_bk_rows "9001-b: the row is still written" 1
if [ -e "$bk_root/consoles/chief.md" ]; then fail "9001-b: the route created the inbox it found absent"; else pass; fi
bk_arm
MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-b2: OUTSIDE with HIMMEL_CONSOLE_NAME unset"
assert_audit_has "9001-b2: the field is still written" " bucket=OUTSIDE"
assert_bk_rows "9001-b2: the row is still written" 1
assert_bk_inbox "9001-b2: no chief name, no inbox line" 0

bk_arm
MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="DONE HIMMEL-374" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-c: a merge on a ticket already Done is not stopped"
assert_audit_has "9001-c: the audit line carries bucket=DONE" " bucket=DONE"
assert_err_has "9001-c: the stderr line says Done" "merge-on-green: LEAK HIMMEL-374 merged on a ticket already Done (PR #77). Not stopped."
assert_bk_rows "9001-c: one row" 1
assert_status_row "9001-c: the row's verdict is DONE" '.event == "bucket-leak" and .verdict == "DONE"'
assert_bk_inbox "9001-c: one inbox line" 1
if grep -qF 'Bucket leak, not stopped: PR #77 merged on a ticket already Done. feat(jira): [HIMMEL-374] reconciler.' "$bk_root/consoles/chief.md"; then pass
else fail "9001-c: the inbox line says Done ($(cat "$bk_root/consoles/chief.md"))"; fi

for bk_v in "IN HIMMEL-374 current=v1.1.3 via=mirror" "NONE HIMMEL-374 /mirror" "APPROVED HIMMEL-374 decision=1 record=O-v1.1.3-0001"; do
    bk_f=${bk_v%% *}
    bk_arm
    MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_v" STUB_PR_TITLE="$bk_title" \
        run_mog 0 "9001-d: $bk_f"
    assert_audit_has "9001-d: $bk_f is on the audit line" " bucket=$bk_f"
    assert_err_lacks "9001-d: $bk_f prints no LEAK" "LEAK"
    assert_bk_rows "9001-d: $bk_f writes no row" 0
    assert_bk_inbox "9001-d: $bk_f sends no inbox line" 0
done

bk_n=0
for bk_case in "FAILED|FAILED HIMMEL-374 no readable mirror at /m|" "rc1||1" "silent||"; do
    bk_n=$((bk_n + 1))
    bk_v=${bk_case#*|}; bk_rc=${bk_v#*|}; bk_v=${bk_v%%|*}
    bk_arm
    MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_v" STUB_BUCKET_RC="$bk_rc" STUB_PR_TITLE="$bk_title" \
        run_mog 0 "9001-e$bk_n: ${bk_case%%|*} reads unread"
    assert_audit_has "9001-e$bk_n: the field is unread" " bucket=unread"
    assert_err_has "9001-e$bk_n: stderr names the merge as not checked" "not checked against the bucket"
    assert_bk_rows "9001-e$bk_n: one row" 1
    assert_status_row "9001-e$bk_n: the row's verdict is unread" '.event == "bucket-leak" and .verdict == "unread"'
    assert_bk_inbox "9001-e$bk_n: no inbox line" 0
done

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    bk_arm
    bk_t0=$SECONDS
    MERGE_BUCKET_TIMEOUT_SECS=1 STUB_BUCKET_SLEEP=20 STUB_BUCKET_VERDICT="$bk_out_line" MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_PR_TITLE="$bk_title" \
        run_mog 0 "9001-f: a hung bucket-check" -- --jira-transition
    if [ $((SECONDS - bk_t0)) -lt 15 ]; then pass; else fail "9001-f: the merge waited $((SECONDS - bk_t0))s on a hung bucket-check"; fi
    assert_audit_has "9001-f: the field is unread" " bucket=unread"
    assert_bk_rows "9001-f: one unread row" 1
    assert_jira_log_has "9001-f: the close still ran after the timeout" "transition HIMMEL-374 Done"
    assert_bk_inbox "9001-f: no inbox line" 0
    bk_arm
    MERGE_BUCKET_TIMEOUT_SECS=1 STUB_BUCKET_SLEEP_AFTER=20 STUB_BUCKET_VERDICT="$bk_out_line" MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_PR_TITLE="$bk_title" \
        run_mog 0 "9001-f2: a bucket-check killed after it printed"
    assert_audit_has "9001-f2: an answer printed before the kill is not trusted" " bucket=unread"
    assert_bk_inbox "9001-f2: no inbox line" 0
else
    echo "SKIP 9001-f: this host has neither timeout nor gtimeout, so the bucket-check bound cannot be exercised"
fi

bk_probe="$(mktemp -d "${TMPDIR:-/tmp}/mog-bk-probe.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
cp "$SCRIPT_DIR/../lib/ticket-status.sh" "$bk_probe/ticket-status.sh"
printf '\nunset -f status_event\n' >> "$bk_probe/ticket-status.sh"
cp "$SCRIPT_DIR/../lib/merge-block-alert.sh" "$bk_probe/merge-block-alert.sh"
printf '\nunset -f _mba_route_chief\n' >> "$bk_probe/merge-block-alert.sh"
bk_arm
TS_LIB_SRC="$bk_probe/ticket-status.sh" MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-g1: no status_event loaded"
assert_audit_has "9001-g1: the field is still written" " bucket=OUTSIDE"
assert_bk_inbox "9001-g1: the inbox line still goes" 1
bk_arm
MBA_LIB_SRC="$bk_probe/merge-block-alert.sh" MERGE_WATCH_ALERT_BRIDGE_ROOT="$bk_root" HIMMEL_CONSOLE_NAME=chief STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-g2: no _mba_route_chief loaded"
assert_audit_has "9001-g2: the field is still written" " bucket=OUTSIDE"
assert_bk_rows "9001-g2: the row is still written" 1
assert_bk_inbox "9001-g2: no inbox line" 0
rm -rf "$bk_probe"

STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="chore: tidy things up HIMMEL-99" \
    run_mog 0 "9001-h: a title with no bracketed key"
assert_audit_has "9001-h: the field is not-asked" " bucket=not-asked"
assert_jira_log_lacks "9001-h: no bucket-check call" "bucket-check"
mkdir -p "$bk_root/nocli" && git init -q "$bk_root/nocli"
MOG_CWD="$bk_root/nocli" STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" run_mog 0 "9001-i: no built Jira CLI"
assert_audit_has "9001-i: the field is not-asked" " bucket=not-asked"
assert_audit_has "9001-i: the Jira step skipped for the missing build" "skip=no-jira-cli-build"

STUB_JIRA_BUILD=1 STUB_JIRA_TRANSITION_STAMPS=v1.1.3 STUB_BUCKET_VERDICT="OUTSIDE HIMMEL-374 none current=v1.1.3 open=1" STUB_PR_TITLE="$bk_title" \
    run_mog 0 "9001-j: bucket-check comes before the close" -- --jira-transition
assert_audit_has "9001-j: a versionless ticket reads OUTSIDE" " bucket=OUTSIDE"
bk_check_ln=$(grep -n 'release bucket-check' "$LAST_JIRA_LOG" | head -1 | cut -d: -f1)
bk_close_ln=$(grep -n 'dist/index.js transition ' "$LAST_JIRA_LOG" | head -1 | cut -d: -f1)
if [ -n "$bk_check_ln" ] && [ -n "$bk_close_ln" ] && [ "$bk_check_ln" -lt "$bk_close_ln" ]; then pass
else fail "9001-j: bucket-check (line '${bk_check_ln:-none}') comes before the transition (line '${bk_close_ln:-none}')"; fi

STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_MERGE_POLICY_REFUSED=1 STUB_PR_TITLE="$bk_title" run_mog 18 "9001-k1: GitHub refused the merge"
assert_jira_log_lacks "9001-k1: no bucket-check on a refused merge" "bucket-check"
assert_audit_lacks "9001-k1: no bucket field on a refused merge" " bucket="
STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="[HIMMEL-1] fix the thing" run_mog 20 "9001-k2: the title gate refused"
assert_jira_log_lacks "9001-k2: no bucket-check on a title refusal" "bucket-check"
assert_audit_lacks "9001-k2: no bucket field on a title refusal" " bucket="

STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED STUB_PR_TITLE="$bk_title" run_mog 0 "9001-l1: gh failed, then MERGED"
assert_audit_has "9001-l1: that path carries the field" " bucket=OUTSIDE"
assert_audit_has "9001-l1: it is the gh-exit path" "gh-exit="
STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="IN HIMMEL-374 current=v1.1.3 via=mirror" STUB_PR_TITLE="$bk_title" run_mog 0 "9001-l2: the normal path"
assert_audit_has "9001-l2: the normal path carries the field" " bucket=IN"
assert_audit_lacks "9001-l2: it is not the gh-exit path" "gh-exit="

STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="IN HIMMEL-374 current=v1.1.3 via=mirror" STUB_PR_TITLE="$bk_title" run_mog 0 "9001-m: the mirror is read from the key's project"
assert_jira_log_has "9001-m: the mirror is the key's project" "release bucket-check --mirror $HOME/.himmel/state/jira-mirror/HIMMEL HIMMEL-374"
bk_farm=$(mktemp -d "${TMPDIR:-/tmp}/mog-bk-nt.XXXXXX") || bk_farm=""
if [ -z "$bk_farm" ] || [ ! -d "$bk_farm" ]; then
    fail "9001-n: setup: no scratch dir for the no-timeout PATH"
else
    IFS=: read -r -a bk_path <<< "$PATH"
    for bk_d in "${bk_path[@]}"; do
        case "$bk_d" in /*) [ -d "$bk_d" ] && { ln -s "$bk_d"/* "$bk_farm"/ 2>/dev/null || true; } ;; esac
    done
    rm -f "$bk_farm/timeout" "$bk_farm/gtimeout"
    MOG_PATH_BASE="$bk_farm" STUB_JIRA_BUILD=1 STUB_BUCKET_VERDICT="$bk_out_line" STUB_PR_TITLE="$bk_title" \
        run_mog 0 "9001-n: no timeout binary, the bucket-check is not run"
    assert_audit_has "9001-n: the field is unread" " bucket=unread"
    assert_jira_log_lacks "9001-n: no bucket-check call was made" "bucket-check"
    assert_err_has "9001-n: the WARN names the missing binary" "no timeout or gtimeout binary is on PATH"
    assert_bk_rows "9001-n: one unread row" 1
    rm -rf "$bk_farm"
fi
rm -rf "$bk_root"

S5_STUB="$SCRIPT_DIR/chief-kit/fixtures/gh-two-token-stub.sh"
S5_TOKEN=ghp_READTOKEN0123456789
S5_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mog-s5.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
mkdir -p "$S5_ROOT/full" "$S5_ROOT/empty" "$S5_ROOT/cfg"
printf 'himmel_github_token_vm2=%s\n' "$S5_TOKEN" > "$S5_ROOT/full/.env"
: > "$S5_ROOT/empty/.env"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
export HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$S5_ROOT/cfg"
s5_setup() {
    local t="$1"
    cp "$SCRIPT_DIR/../lib/gh-read.sh" "$SCRIPT_DIR/../lib/timeout-bin.sh" "$SCRIPT_DIR/../lib/load-dotenv.sh" "$SCRIPT_DIR/../lib/gh-quota.sh" "$t/scripts/lib/" || return 1
    mv "$t/bin/gh" "$t/bin/gh.real" || return 1
    cat > "$t/bin/gh.mid" <<'MID'
#!/usr/bin/env bash
if [ -n "${GH_TOKEN:-}" ] && [ "${S5_NOBYPASS:-0}" = 1 ]; then
    case "$*" in
        *"/rulesets/"*)
            echo "$*" >> "$GH_LOG"
            jqexpr=""
            while [ $# -gt 0 ]; do [ "$1" = --jq ] && jqexpr="${2:-}"; shift; done
            printf '{"enforcement":"active"}' | jq -r "$jqexpr"
            exit 0 ;;
    esac
fi
exec "$(dirname "$0")/gh.real" "$@"
MID
    printf '#!/usr/bin/env bash\nexport GHLOG="%s/tt.log" GH_STUB_DELEGATE="%s/bin/gh.mid"\nexec "%s" "$@"\n' "$t" "$t" "$S5_STUB" > "$t/bin/gh"
    chmod +x "$t/bin/gh" "$t/bin/gh.mid"
}
s5_mog() {
    GH_READ_ENV_ROOT="${S5_SEL:-$S5_ROOT/full}" GH_STUB_READ_TOKEN="$S5_TOKEN" MOG_ANCHOR_SETUP=s5_setup \
        STUB_NWO="${STUB_NWO:-acme/private-repo}" STUB_CWD_NWO="${STUB_CWD_NWO:-acme/private-repo}" STUB_PRIVATE="${STUB_PRIVATE:-true}" \
        STUB_SHA="${STUB_SHA:-s5ok01}" run_mog "$@"
}
s5n() { if [ -f "$LAST_TMP/tt.log" ]; then grep -c -E -- "$1" "$LAST_TMP/tt.log"; else echo 0; fi; }
s5_is() {
    local got; got=$(s5n "$2")
    if [ "$got" = "$3" ]; then pass; else fail "$1 (tok log: $3 expected, $got seen for /$2/)"; fi
}
s5_some() {
    local got; got=$(s5n "$2")
    if [ "$got" -ge 1 ]; then pass; else fail "$1 (tok log: /$2/ never seen)"; fi
}

S5_SEL="$S5_ROOT/full" GH_STUB_MAINFAIL=rate GH_STUB_MAINFAIL_BUCKET=core s5_mog 0 "8691-a: main's REST core spent, private repo: merged"
assert_merge_has "8691-a: the merge pins the certified sha" "--match-head-commit s5ok01"
s5_some "8691-a: the main-branch run list logs tok=read" '^tok=read argv=run list --repo acme/private-repo --branch main --workflow CI'
s5_some "8691-a: the PR file listing logs tok=read" '^tok=read argv=api repos/acme/private-repo/pulls/77/files'
s5_some "8691-a: the trust check's list read logs tok=read" '^tok=read argv=api repos/acme/private-repo/contents/scripts/ci/ci-trust-paths.txt'
s5_some "8691-a: the repo read logs tok=read" '^tok=read argv=repo view acme/private-repo --json isPrivate,defaultBranchRef'
s5_some "8691-a: the title read logs tok=read" '^tok=read argv=pr view 77 --repo acme/private-repo --json title,author'
s5_some "8691-a: the policy read (mergeStateStatus) logs tok=main" '^tok=main argv=pr view 77 --repo acme/private-repo --json mergeStateStatus,reviewDecision'
s5_some "8691-a: pr merge logs tok=main" '^tok=main argv=pr merge 77 --repo acme/private-repo --squash --match-head-commit s5ok01'
s5_is "8691-a: no policy read and no write rides the read token" '^tok=read argv=(pr merge|workflow run|.*mergeStateStatus)' 0
s5_is "8691-a: the token is never in a log line" "$S5_TOKEN" 0

S5_SEL="$S5_ROOT/full" STUB_NWO=yotamleo-org/Himmel STUB_CWD_NWO=yotamleo-org/Himmel STUB_PRIVATE=false \
    GH_STUB_MAINFAIL=rate GH_STUB_MAINFAIL_BUCKET=core s5_mog 12 "8691-b: main's REST core spent, public origin: refused at the protection read"
assert_err_has "8691-b: the refusal says the repo is not confirmed PRIVATE" "not confirmed PRIVATE"
assert_audit_has "8691-b: the audit line carries the unreadable protection" "protection=classic:unreadable"
s5_some "8691-b: the repo read before the gate logs tok=read" '^tok=read argv=repo view yotamleo-org/Himmel --json isPrivate,defaultBranchRef'
s5_some "8691-b: the classic protection read logs tok=main" '^tok=main argv=api repos/yotamleo-org/Himmel/branches/main/protection'
s5_is "8691-b: no protection, rules or ruleset read rides the read token" '^tok=read argv=api repos/.*(protection|/rules/|/rulesets/)' 0
s5_is "8691-b: nothing merged" '^tok=[a-z]+ argv=pr merge' 0

S5_RULES='[{"type":"required_status_checks","ruleset_id":7,"parameters":{"required_status_checks":[{"context":"ci"}]}}]'
S5_RULESET='{"enforcement":"active","bypass_actors":[]}'
S5_SEL="$S5_ROOT/full" S5_NOBYPASS=1 STUB_NWO=yotamleo-org/Himmel STUB_CWD_NWO=yotamleo-org/Himmel STUB_PRIVATE=false STUB_SHA=s5rs01 \
    STUB_PROTECTION_FAIL=1 STUB_RULES_JSON="$S5_RULES" STUB_RULESET_JSON="$S5_RULESET" s5_mog 0 "8691-c: ruleset bypass_actors absent under the read token: merged"
assert_audit_has "8691-c: the gate passed on the ruleset source" "source=ruleset"
s5_some "8691-c: the ruleset read logs tok=main" '^tok=main argv=api repos/yotamleo-org/Himmel/rulesets/7'
s5_is "8691-c: the effective rules read logs tok=main" '^tok=read argv=api repos/yotamleo-org/Himmel/rules/branches' 0
s5_is "8691-c: no ruleset read rides the read token" '^tok=read argv=api repos/yotamleo-org/Himmel/rulesets/' 0
s5_mutant="$S5_ROOT/mog-ruleset-on-read.sh"
# shellcheck disable=SC2016  # the sed pattern is literal script text
sed 's|rs=\$("\$GH" api "repos/\$nwo/rulesets/\$id"|rs=$("${GH_READ_BIN:-gh}" api "repos/$nwo/rulesets/$id"|' "$MOG" > "$s5_mutant"
if cmp -s "$MOG" "$s5_mutant"; then fail "8691-c control: the sed did not change the ruleset line"; fi
S5_SEL="$S5_ROOT/full" S5_NOBYPASS=1 STUB_NWO=yotamleo-org/Himmel STUB_CWD_NWO=yotamleo-org/Himmel STUB_PRIVATE=false STUB_SHA=s5rs01 \
    STUB_PROTECTION_FAIL=1 STUB_RULES_JSON="$S5_RULES" STUB_RULESET_JSON="$S5_RULESET" MOG_SRC="$s5_mutant" \
    s5_mog 12 "8691-c control: a ruleset read on the read token is refused (bypass_actors=-1)"

S5_SEL="$S5_ROOT/empty" s5_mog 0 "8691-d: no read token: merged"
assert_merge_has "8691-d: the merge pins the certified sha" "--match-head-commit s5ok01"
s5_is "8691-d: no call logs tok=read" '^tok=read ' 0
s5_some "8691-d: the reads log tok=main" '^tok=main argv=run list --repo acme/private-repo'

S5_SEL="$S5_ROOT/full" GH_STUB_READFAIL=rate GH_STUB_MAINFAIL=rate GH_STUB_MAINFAIL_BUCKET=core s5_mog 21 "8691-e: both tokens refused: the trust-path gate refuses"
assert_err_has "8691-e: the refusal names the trust list read" "cannot read scripts/ci/ci-trust-paths.txt"
s5_some "8691-e: the read token was tried first" '^tok=read argv=api repos/acme/private-repo/contents/scripts/ci/ci-trust-paths.txt'
s5_some "8691-e: the retry rode the main token" '^tok=main argv=api repos/acme/private-repo/contents/scripts/ci/ci-trust-paths.txt'
s5_is "8691-e: nothing merged" '^tok=[a-z]+ argv=pr merge' 0

printf 'touch "%s/dotenv-marker"\n' "$S5_ROOT" > "$S5_ROOT/evil-load-dotenv.sh"
rm -f "$S5_ROOT/dotenv-marker"
S5_SEL="$S5_ROOT/full" _GHR_LOAD_DOTENV="$S5_ROOT/evil-load-dotenv.sh" s5_mog 0 "8691-f: _GHR_LOAD_DOTENV set: merged"
if [ -e "$S5_ROOT/dotenv-marker" ]; then fail "8691-f: the named file was sourced"; else pass; fi
s5_some "8691-f: the helper ran (a read logs tok=read)" '^tok=read argv=run list'
s5_nounset="$S5_ROOT/mog-no-unset.sh"
grep -v '^unset _GHR_LOAD_DOTENV ' "$MOG" > "$s5_nounset"
rm -f "$S5_ROOT/dotenv-marker"
S5_SEL="$S5_ROOT/full" _GHR_LOAD_DOTENV="$S5_ROOT/evil-load-dotenv.sh" MOG_SRC="$s5_nounset" s5_mog 0 "8691-f control: a copy without the unset line"
if [ -e "$S5_ROOT/dotenv-marker" ]; then pass; else fail "8691-f control: a copy without the unset line never sourced the file (the row proves nothing)"; fi

echo
echo "merge-on-green: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
