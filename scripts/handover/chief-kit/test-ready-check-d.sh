#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2153,SC2154
set -uo pipefail
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

# --- 8. TICKET_ID_PATTERN / JIRA_PROJECT_KEY must resolve from
# ready-check.sh's OWN checkout, never the caller's CWD repo. Fixture mirrors
# test-bank-preflight-dotenv-root.sh: a scratch "own checkout" (this script +
# scripts/lib/load-dotenv.sh, laid out at the same relative depth, plus a
# fixture .env carrying JIRA_PROJECT_KEY) is run with CWD at $REPO — a git
# repo with no .env of its own — and neither var exported by the caller.
own="$tmp/own-checkout"
mkdir -p "$own/scripts/handover/chief-kit" "$own/scripts/lib"
cp "$SCRIPT" "$own/scripts/handover/chief-kit/ready-check.sh"
cp "$REPO_ROOT/scripts/lib/load-dotenv.sh" "$own/scripts/lib/load-dotenv.sh"
cp "$REPO_ROOT/scripts/lib/gh-pr-snapshot.sh" "$own/scripts/lib/gh-pr-snapshot.sh"
cp "$REPO_ROOT/scripts/lib/go-gate.sh" "$own/scripts/lib/go-gate.sh"
mkdir -p "$own/scripts/ci"
cp "$REPO_ROOT/scripts/lib/ticket-id-internal.sh" "$own/scripts/lib/ticket-id-internal.sh"
cp "$REPO_ROOT/scripts/lib/outside-contributors.sh" "$own/scripts/lib/outside-contributors.sh"
cp "$REPO_ROOT/scripts/ci/ticket-id-internal-authors.txt" "$own/scripts/ci/ticket-id-internal-authors.txt"
mkdir -p "$own/scripts/cr"
cp "$REPO_ROOT/scripts/cr/clear-review-marker.sh" "$REPO_ROOT/scripts/cr/anchor-handoff.sh" "$REPO_ROOT/scripts/cr/ledger-amend-auth.js" "$REPO_ROOT/scripts/cr/review-round.sh" "$own/scripts/cr/"
cp "$REPO_ROOT/scripts/lib/chokepoint-seam-guard.sh" "$own/scripts/lib/chokepoint-seam-guard.sh"
cp "$REPO_ROOT/scripts/lib/git-clean.sh" "$REPO_ROOT/scripts/lib/gate-repo-resolver.sh" "$own/scripts/lib/"
cp "$REPO_ROOT/scripts/lib/attest-trailers.sh" "$own/scripts/lib/attest-trailers.sh"
cp "$REPO_ROOT/scripts/chokepoints.json" "$own/scripts/chokepoints.json"
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$own/.env"

reset_stubs
STUB_COMMITS="$GREEN_COMMITS"
rc=0
out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    HIMMEL_REPO="$REPO" STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$STUB_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" STUB_RED="$GREEN_RED" STUB_PR_BRANCH=feat/himmel-100-thing JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" \
    PATH="$PATH" GH_LOG="$GH_LOG" READY_CHECK_ANCHOR="$TP_ANCHOR" \
    bash "$own/scripts/handover/chief-kit/ready-check.sh" --observe "$PR" "$SHA")" || rc=$?
# the copy has no scripts/lib/timeout-bin.sh, so check 19 fails closed and is the only FAIL
check "own-checkout .env: only check 19 fails" "$(printf '%s\n' "$out" | grep '^\[FAIL\]' | grep -vc '^\[FAIL\] 19\. suite evidence: no timeout binary')" "0"
contains "own-checkout .env: check 19 fails closed without a timeout lib" "$out" "[FAIL] 19. suite evidence: no timeout binary"
contains "own-checkout .env: check 6 (ticket ID) passes" "$out" "[PASS] 6."

own_nohelper="$tmp/own-checkout-nohelper"
cp -R "$own" "$own_nohelper"
rm -f "$own_nohelper/scripts/lib/attest-trailers.sh"
rc=0
out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    HIMMEL_REPO="$REPO" STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$STUB_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" STUB_RED="$GREEN_RED" STUB_PR_BRANCH=feat/himmel-100-thing JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" \
    PATH="$PATH" GH_LOG="$GH_LOG" READY_CHECK_ANCHOR="$TP_ANCHOR" \
    bash "$own_nohelper/scripts/handover/chief-kit/ready-check.sh" --observe "$PR" "$SHA")" || rc=$?
contains "helper missing: check 5 fails closed" "$out" "[FAIL] 5. cannot evaluate"
contains "helper missing: check 13 fails closed" "$out" "[FAIL] 13. cannot classify the PR files"

# --- 9. a PR that changes a plugin bumps that plugin's version above the
# CURRENT origin/main's; a bump with no other plugin change is
# refused; a release cut (a PR that changes the root VERSION file) raises every
# plugin it touches above main. Two PRs can raise a plugin to the same version
# with different content and mergeStateStatus stays CLEAN, so check 1 cannot
# see it. Fixture: a
# bare origin; WORK builds history and pushes each PR head to refs/pull/77/head;
# CLONE (what run() cds into) is cloned BEFORE main moves, so its origin/main is
# stale and has none of the PR objects — check 9 must fetch both.
PLUG=marketplace/plugins/demo
ORIGIN="$tmp/origin.git"
WORK="$tmp/work"
CLONE="$tmp/clone"
git init -q --bare "$ORIGIN"
git init -q -b main "$WORK"
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name tester
git -C "$WORK" remote add origin "$ORIGIN"
write_plugin() {
    local w="${RB_WORK:-$WORK}"
    mkdir -p "$w/$PLUG/.claude-plugin"
    printf '{"name":"demo","version":"%s"}\n' "$1" > "$w/$PLUG/.claude-plugin/plugin.json"
    printf '%s\n' "$2" > "$w/$PLUG/body.txt"
    git -C "$w" add -A
    git -C "$w" commit -q -m "$3"
}
printf '1.0.0\n' > "$WORK/VERSION"
mkdir -p "$WORK/marketplace/.claude-plugin"
printf '{"plugins":[{"name":"demo","source":"./plugins/demo"}]}\n' > "$WORK/marketplace/.claude-plugin/marketplace.json"
write_plugin 0.4.70 base "chore: base"
git -C "$WORK" push -q origin main
BASE_OID=$(git -C "$WORK" rev-parse HEAD)
git clone -q "$ORIGIN" "$CLONE"
pr_head() {  # <version> <content> [release] -> commit on a branch off the base, pushed as the PR head
    local w="${RB_WORK:-$WORK}"
    git -C "$w" checkout -q -B pr "${RB_BASE:-$BASE_OID}"
    [ -z "${3:-}" ] || printf '1.1.0\n' > "$w/VERSION"
    write_plugin "$1" "$2" "fix: pr"
    git -C "$w" rev-parse HEAD
}
PR_SAME=$(pr_head 0.4.71 from-pr)
PR_UNBUMPED=$(pr_head 0.4.70 from-pr)
PR_REL_SAME=$(pr_head 0.4.71 from-pr release)
PR_REL_AHEAD=$(pr_head 0.4.72 from-pr release)
PR_PRE=$(pr_head 0.4.71-alpha from-pr release)
PR_NEW_BUMP=$(pr_head 0.4.72 from-pr)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
write_plugin 0.4.72 base "chore: pr bumps only the manifest"
PR_BUMP_ONLY=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
git -C "$WORK" rm -rq "$PLUG"
git -C "$WORK" commit -q -m "fix: pr removes the plugin, still listed"
PR_DEL_LISTED=$(git -C "$WORK" rev-parse HEAD)
printf '{"plugins":[]}\n' > "$WORK/marketplace/.claude-plugin/marketplace.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr removes the plugin"
PR_DEL=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
mkdir -p "$WORK/docs"
git -C "$WORK" mv "$PLUG/body.txt" docs/body.txt
git -C "$WORK" commit -q -m "fix: pr moves a plugin file out, no bump"
PR_MOVE=$(git -C "$WORK" rev-parse HEAD)
printf '{"name":"demo","version":"0.4.72"}\n' > "$WORK/$PLUG/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr moves a plugin file out and bumps"
PR_MOVE_BUMP=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
git -C "$WORK" rm -q "$PLUG/.claude-plugin/plugin.json"
git -C "$WORK" commit -q -m "fix: pr drops only the manifest"
PR_MANIFEST_DEL=$(git -C "$WORK" rev-parse HEAD)
pr_head 0.4.72 from-pr release >/dev/null
git -C "$WORK" rm -q "$PLUG/.claude-plugin/plugin.json"
git -C "$WORK" commit -q -m "fix: release cut drops only the manifest"
PR_REL_MANIFEST_DEL=$(git -C "$WORK" rev-parse HEAD)
# a second plugin whose manifest on main carries no version (unreadable there)
BADP=marketplace/plugins/bad
pr_head 0.4.72 from-pr release >/dev/null
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad","version":"1.0.0"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr touches bad"
PR_BAD=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad","version":"1.0.0"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
printf 'x\n' > "$WORK/$BADP/body.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr introduces bad (not a release)"
PR_BAD_NEW=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q main
write_plugin 0.4.71 from-main "feat: main shipped 0.4.71"
MAIN_0471=$(git -C "$WORK" rev-parse HEAD)
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "feat: main bad manifest"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q -B pr "$PR_SAME"
git -C "$WORK" merge -q --no-edit "$MAIN_0471" >/dev/null 2>&1 || true
write_plugin 0.4.71 from-pr "merge: main into pr, keep 0.4.71"
PR_FWD_SAME=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q main

run_bump() {  # <pr head> <files> [renames "new old" lines] [renames-unreadable flag] -> sets rc/out
    local w="${RB_WORK:-$WORK}" c="${RB_CLONE:-$CLONE}"
    git -C "$w" push -q -f origin "$1:refs/pull/$PR/head"
    local keep_sha="$SHA" keep_repo="$REPO" keep_ledger="$LEDGER"
    SHA="$1"; REPO="$c"; LEDGER="$c/.git/cr-critic-scores.jsonl"
    reset_stubs
    STUB_FILES="$2"
    STUB_RENAMES="${3:-}"
    STUB_RENAMES_FAIL="${4:-}"
    rc=0; out="$(run)" || rc=$?
    SHA="$keep_sha"; REPO="$keep_repo"; LEDGER="$keep_ledger"
}

p1() {
    local w="${RB_WORK:-$WORK}" c="${RB_CLONE:-$CLONE}" wt="$tmp/p1-wt" mb files crc=0 want=0 mark='[PASS] 9.'
    if [ "$3" = fail ]; then want=1; mark='[FAIL] 9.'; fi
    mb=$(git -C "$w" merge-base main "$2")
    files=$(git -C "$w" diff --name-only "$mb" "$2")
    run_bump "$2" "$files"
    contains "(11344-p1) $1: item 9 says $3" "$out" "$mark"
    git -C "$c" worktree add -q --detach "$wt" "$2"
    (cd "$wt" && bash "$REPO_ROOT/scripts/check-plugin-drift.sh" --bump-required refs/remotes/origin/main) >/dev/null 2>&1 || crc=$?
    git -C "$c" worktree remove --force "$wt"
    check "(11344-p1) $1: checker rc agrees" "$crc" "$want"
}

# A PR that changes a plugin bumps that plugin's version above the
# CURRENT origin/main's. Main moved the plugin to 0.4.71 after this PR branched.
# RED: the PR edits the plugin and leaves the version alone.
run_bump "$PR_UNBUMPED" "$PLUG/body.txt"
check "plugin edit, version untouched: exit 1" "$rc" "1"
contains "plugin edit, version untouched: check 9 fails" "$out" "[FAIL] 9."
contains "plugin edit, version untouched: names the plugin" "$out" "demo"
p1 "unraised head" "$PR_UNBUMPED" fail

# (11344-b1) The PR raised the plugin to the number main reached on its own: accepted.
run_bump "$PR_SAME" "$PLUG/body.txt"
contains "(11344-b1) equal version the PR raised itself: check 9 passes" "$out" "[PASS] 9."
contains "(11344-b1) equal version: the PASS line names the plugin" "$out" "equal to current origin/main, raised from an older merge-base: demo 0.4.71"
notcontains "(11344-b1) equal version: no check fails" "$out" "[FAIL]"
p1 "equal raised head" "$PR_SAME" pass

run_bump "$PR_FWD_SAME" "$PLUG/body.txt"
contains "(11344-b4) merged forward at main's number: check 9 fails" "$out" "[FAIL] 9."
contains "(11344-b4) merged forward at main's number: says why" "$out" "bump above main"
p1 "merged-forward head" "$PR_FWD_SAME" fail

# DoD: a plugin file changed AND the version bumped above main passes.
run_bump "$PR_NEW_BUMP" "$PLUG/body.txt"
contains "plugin edit bumped above main: check 9 passes" "$out" "[PASS] 9. every plugin the PR changes is bumped above current origin/main"
notcontains "plugin edit bumped above main: no check fails" "$out" "[FAIL]"

# A plugin the PR introduces but main now ships is judged against main too (here
# main's manifest carries no readable version, so the check fails closed).
run_bump "$PR_BAD_NEW" "$BADP/.claude-plugin/plugin.json"
check "new plugin main already ships: exit 1" "$rc" "1"
contains "new plugin main already ships: check 9 fails" "$out" "[FAIL] 9."

# A file moved out of the plugin is a change to the plugin: the PR file list names
# only the destination, the plugin path is its previous_filename.
run_bump "$PR_MOVE" "docs/body.txt" "docs/body.txt $PLUG/body.txt"
check "plugin file moved out, no bump: exit 1" "$rc" "1"
contains "plugin file moved out, no bump: check 9 fails" "$out" "[FAIL] 9."
contains "plugin file moved out, no bump: names the plugin" "$out" "demo"
run_bump "$PR_MOVE_BUMP" "docs/body.txt
$PLUG/.claude-plugin/plugin.json" "docs/body.txt $PLUG/body.txt"
contains "plugin file moved out and bumped: check 9 passes" "$out" "[PASS] 9. every plugin the PR changes is bumped above current origin/main"
run_bump "$PR_MOVE" "docs/body.txt" "docs/body.txt $PLUG/body.txt" 1
check "renamed-from paths unreadable: exit 1" "$rc" "1"
contains "renamed-from paths unreadable: check 9 fails closed" "$out" "[FAIL] 9."

# DoD: a bump with no other file change in the plugin is refused.
run_bump "$PR_BUMP_ONLY" "$PLUG/.claude-plugin/plugin.json"
check "bump with no plugin change: exit 1" "$rc" "1"
contains "bump with no plugin change: check 9 fails" "$out" "[FAIL] 9."
contains "bump with no plugin change: says why" "$out" "no other file of demo changed"

run_bump "$PR_REL_SAME" "$PLUG/body.txt"
check "release cut same-version-as-main: exit 1" "$rc" "1"
contains "release cut same-version-as-main: check 9 fails" "$out" "[FAIL] 9."
contains "release cut same-version-as-main: names the plugin" "$out" "demo"

run_bump "$PR_REL_AHEAD" "$PLUG/body.txt"
contains "release cut ahead of main: check 9 passes" "$out" "[PASS] 9."
notcontains "release cut ahead of main: no check fails" "$out" "[FAIL]"

run_bump "$PR_PRE" "$PLUG/body.txt"
check "prerelease PR version: exit 1" "$rc" "1"
contains "prerelease PR version: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_BAD" "$BADP/.claude-plugin/plugin.json"
check "unreadable main manifest: exit 1" "$rc" "1"
contains "unreadable main manifest: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_DEL" "$PLUG/body.txt"
contains "plugin removed by the PR: check 9 passes" "$out" "[PASS] 9."

# Only a whole removal needs no version: a dropped manifest with the plugin's
# files left, or a removed plugin marketplace.json still lists, fails, as
# check-plugin-drift.sh --bump-required does.
run_bump "$PR_MANIFEST_DEL" "$PLUG/.claude-plugin/plugin.json"
check "manifest dropped, plugin files left: exit 1" "$rc" "1"
contains "manifest dropped, plugin files left: check 9 fails" "$out" "[FAIL] 9."
run_bump "$PR_REL_MANIFEST_DEL" "$PLUG/.claude-plugin/plugin.json"
check "release cut drops the manifest, plugin files left: exit 1" "$rc" "1"
contains "release cut drops the manifest, plugin files left: check 9 fails" "$out" "[FAIL] 9."
run_bump "$PR_DEL_LISTED" "$PLUG/body.txt"
check "plugin removed but still listed in marketplace.json: exit 1" "$rc" "1"
contains "plugin removed but still listed in marketplace.json: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_SAME" "README.md"
contains "no plugin touched: check 9 passes" "$out" "[PASS] 9."

FRESHP=marketplace/plugins/fresh
add_fresh() {
    mkdir -p "$RB_WORK/$FRESHP/.claude-plugin"
    printf '{"name":"fresh","version":"1.0.0"}\n' > "$RB_WORK/$FRESHP/.claude-plugin/plugin.json"
    printf 'x\n' > "$RB_WORK/$FRESHP/$1"
    printf '{"plugins":[{"name":"demo","source":"./plugins/demo"},{"name":"fresh","source":"./plugins/fresh"}]}\n' > "$RB_WORK/marketplace/.claude-plugin/marketplace.json"
    git -C "$RB_WORK" add -A
    git -C "$RB_WORK" commit -q -m "feat: add fresh ($1)"
}
RB_ORIGIN="$tmp/origin2.git" RB_WORK="$tmp/work2" RB_CLONE="$tmp/clone2"
git init -q --bare "$RB_ORIGIN"
git init -q -b main "$RB_WORK"
git -C "$RB_WORK" config user.email t@example.com
git -C "$RB_WORK" config user.name tester
git -C "$RB_WORK" remote add origin "$RB_ORIGIN"
printf '1.0.0\n' > "$RB_WORK/VERSION"
mkdir -p "$RB_WORK/marketplace/.claude-plugin"
printf '{"plugins":[{"name":"demo","source":"./plugins/demo"}]}\n' > "$RB_WORK/marketplace/.claude-plugin/marketplace.json"
write_plugin 0.4.70 base "chore: base"
git -C "$RB_WORK" push -q origin main
RB_BASE=$(git -C "$RB_WORK" rev-parse HEAD)
git clone -q "$RB_ORIGIN" "$RB_CLONE"
add_fresh main.txt
write_plugin 0.4.71 main-1 "feat: main 0.4.71"
write_plugin 0.4.72 main-2 "feat: main 0.4.72"
git -C "$RB_WORK" push -q origin main
PR_TWO=$(pr_head 0.4.72 from-pr)
git -C "$RB_WORK" checkout -q -B pr "$RB_BASE"
add_fresh pr.txt
PR_FRESH=$(git -C "$RB_WORK" rev-parse HEAD)
git -C "$RB_WORK" checkout -q main

run_bump "$PR_TWO" "$PLUG/body.txt"
contains "(11344-b7) equal through another number: check 9 fails" "$out" "[FAIL] 9."
contains "(11344-b7) equal through another number: says why" "$out" "bump above main"
p1 "two-step head" "$PR_TWO" fail
run_bump "$PR_FRESH" "$FRESHP/.claude-plugin/plugin.json"
contains "(11344-b8) new plugin at main's number: check 9 fails" "$out" "[FAIL] 9."
contains "(11344-b8) new plugin at main's number: says why" "$out" "bump above main"
p1 "new-plugin head" "$PR_FRESH" fail
unset RB_ORIGIN RB_WORK RB_CLONE RB_BASE

MAIN_KEEP=$(git -C "$WORK" rev-parse main)
git -C "$WORK" checkout -q main
printf '1.0.1\n' > "$WORK/VERSION"
git -C "$WORK" commit -q -am "chore: VERSION only"
git -C "$WORK" push -q origin main
run_bump "$PR_SAME" "$PLUG/body.txt"
contains "(11344-b6) equal after a VERSION change: check 9 fails" "$out" "[FAIL] 9."
contains "(11344-b6) equal after a VERSION change: says why" "$out" "bump above main"
p1 "equal head after a VERSION change" "$PR_SAME" fail
git -C "$WORK" reset -q --hard "$MAIN_KEEP"
git -C "$WORK" push -q -f origin "$MAIN_KEEP:main"
check "(11344-b6) fixture main restored" "$(git -C "$WORK" ls-remote origin refs/heads/main | cut -f1)" "$MAIN_KEEP"

# --- 12. computed TRUST-PATH line: from the PR diff against the default
# branch's list, never from any READY text ---------------------------------------
reset_stubs
rc=0; out="$(run)" || rc=$?
check "trust: docs/script-only diff exit 0" "$rc" "0"
contains "trust: a non-trust diff prints no" "$out" "TRUST-PATH: no"
notcontains "trust: a non-trust diff never prints yes" "$out" "TRUST-PATH: yes"
trust_line_pos=$(printf '%s\n' "$out" | grep -n '^TRUST-PATH:' | cut -d: -f1)
verdict_pos=$(printf '%s\n' "$out" | grep -n '^READY-CHECK ' | cut -d: -f1)
check "trust: the line comes before the verdict" "$((trust_line_pos < verdict_pos))" "1"

reset_stubs
STUB_FILES="scripts/lib/fixtures/anything.txt"
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/fixtures diff (PR 2475 shape) prints yes" "$out" "TRUST-PATH: yes"
notcontains "trust: fixtures diff never prints no" "$out" "TRUST-PATH: no"
contains "trust: a yes line is not a failure of the check" "$out" "[PASS] 12."

reset_stubs
STUB_FILES="scripts/lib/env-alias.sh"
STUB_BODY='## Ticket coverage\n- ask: done\n\nTRUST PATH: none touched\n'
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/env-alias.sh diff (PR 2885 shape) prints yes whatever the body claims" "$out" "TRUST-PATH: yes"

reset_stubs
STUB_FILES="scripts/handover/chief-kit/cr-disposition.sh"
rc=0; out="$(run)" || rc=$?
contains "trust: cr-disposition.sh (go.sh signs and decides exit 9 through it) prints yes" "$out" "TRUST-PATH: yes"

for hook_suite in scripts/hooks/test-block-read-secrets.sh scripts/hooks/test-guard-pr-check-literal.sh \
    scripts/hooks/test-cadence-deny-background.sh scripts/hooks/test-auto-approve-safe-bash.sh \
    scripts/hooks/test-check-commit-msg.sh scripts/hooks/test-check-security-reviewed.sh; do
    reset_stubs
    STUB_FILES="$hook_suite"
    rc=0; out="$(run)" || rc=$?
    check "trust: $hook_suite exit 0" "$rc" "0"
    contains "trust: $hook_suite requires judge" "$out" "TRUST-PATH: yes"
done
for nontrust_suite in scripts/guardrails/test-lib.sh scripts/hooks/test-auto-arm-on-cap.sh; do
    reset_stubs
    STUB_FILES="$nontrust_suite"
    rc=0; out="$(run)" || rc=$?
    contains "trust: $nontrust_suite stays outside policy" "$out" "TRUST-PATH: no"
done

reset_stubs
STUB_TRUST_LIST_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unreadable list exits 1" "$rc" "1"
contains "trust: unreadable list fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unreadable list never prints no" "$out" "TRUST-PATH: no"
contains "trust: unreadable list ends in FAIL" "$out" "READY-CHECK FAIL"

reset_stubs
STUB_DEFAULT_BRANCH_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unresolvable default branch exits 1" "$rc" "1"
contains "trust: unresolvable default branch fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unresolvable default branch never prints no" "$out" "TRUST-PATH: no"

# --only 7 stays a coverage-only lint: no trust check
reset_stubs
rc=0; out=$(cd "$REPO" && STUB_BODY="$GREEN_BODY" STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" JIRA_PROJECT_KEY=HIMMEL HIMMEL_REPO="$REPO" STUB_HEAD="$SHA" bash "$SCRIPT" --only 7 "$PR" 2>&1) || rc=$?
notcontains "trust: --only 7 prints no TRUST-PATH line" "$out" "TRUST-PATH:"
reset_stubs

# --- Dependabot dependency-only PRs ------------------------
# Fixture copied from the real PR 3861 (numpy 2.5.3 to 2.5.4, 9d87a279): author
# app/dependabot, one file, Dependabot's own body with no Ticket coverage. The
# commit subject carries the standing key the dependabot.yml prefix now writes.
DEP_BRANCH="dependabot/pip/marketplace/plugins/obsidian-triage/tools/numpy-2.5.4"
DEP_FILES="marketplace/plugins/obsidian-triage/tools/requirements-whisper.txt"
DEP_COMMITS='[{"messageHeadline":"chore(deps): [HIMMEL-7588] Bump numpy in /marketplace/plugins/obsidian-triage/tools","messageBody":"Bumps [numpy](https://github.com/numpy/numpy) from 2.5.3 to 2.5.4.\n- [Release notes](https://github.com/numpy/numpy/releases)\n\nSigned-off-by: dependabot[bot] <support@github.com>"}]'
# shellcheck disable=SC2016  # the backticks are Dependabot's literal body text
DEP_BODY='Bumps [numpy](https://github.com/numpy/numpy) from 2.5.3 to 2.5.4.\n\nDependabot will resolve any conflicts with this PR as long as you dont alter it yourself. You can also trigger a rebase manually by commenting `@dependabot rebase`.\n'
seed_dependabot_go() {
    printf '{"kind":"dependabot-go","ts":"2026-10-25T00:00:00Z","branch":"%s","head":"%s","status":"ok","source":"judge:q1/verdict","pr":%s}\n' "${1:-$DEP_BRANCH}" "${2:-$SHA}" "${3:-77}" > "$LEDGER"
}
# The PR files sit under a marketplace plugin, so check 9 reads git: run from the
# bare-origin CLONE with a real PR head (the plugin version is left alone).
DEP_KEEP_SHA="$SHA"; DEP_KEEP_REPO="$REPO"; DEP_KEEP_LEDGER="$LEDGER"
git -C "$WORK" push -q -f origin "$PR_UNBUMPED:refs/pull/$PR/head"
SHA="$PR_UNBUMPED"; REPO="$CLONE"; LEDGER="$CLONE/.git/cr-critic-scores.jsonl"
dep_fixture() {
    reset_stubs
    STUB_AUTHOR="app/dependabot" STUB_PR_BRANCH="$DEP_BRANCH" STUB_FILES="$DEP_FILES"
    STUB_COMMITS="$DEP_COMMITS" STUB_BODY="$DEP_BODY"
    seed_dependabot_go
}

dep_fixture
rc=0; out="$(run)" || rc=$?
check "dependabot: dependency-only PR exits 0" "$rc" "0"
contains "dependabot: row 4 accepts the dependabot-go row" "$out" "[PASS] 4."
contains "dependabot: row 6 passes on the standing key" "$out" "[PASS] 6."
contains "dependabot: row 7 takes a generated Ticket coverage" "$out" "[PASS] 7. ticket coverage: generated"
contains "dependabot: READY-CHECK PASS" "$out" "READY-CHECK PASS"
notcontains "dependabot: no FAIL row" "$out" "[FAIL]"

# a dependabot-go row for another head or another branch is no review
dep_fixture; seed_dependabot_go "$DEP_BRANCH" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another head fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "some/other-branch"
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another branch fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "$DEP_BRANCH" "$SHA" 78
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another PR fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "$DEP_BRANCH" "$SHA" '"77"'
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row with a string pr fails row 4" "$out" "[FAIL] 4."

# one non-manifest file and the generated coverage is refused
dep_fixture; STUB_FILES="$DEP_FILES
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
check "dependabot: a non-manifest file exits 1" "$rc" "1"
contains "dependabot: a non-manifest file fails row 7" "$out" "[FAIL] 7."

# a manifest outside the allowlist of file names (a workflow) is refused
dep_fixture; STUB_FILES=".github/workflows/ci.yml"
rc=0; out="$(run)" || rc=$?
contains "dependabot: a workflow file fails row 7" "$out" "[FAIL] 7."

# a rename out of a non-manifest into a manifest name is refused (the old name counts)
dep_fixture; STUB_RENAMES="$DEP_FILES scripts/hooks/guard.sh"
rc=0; out="$(run)" || rc=$?
check "dependabot: a rename out of a non-manifest exits 1" "$rc" "1"
contains "dependabot: a rename out of a non-manifest fails row 7" "$out" "[FAIL] 7."

# an unreadable rename list is not a dependency-only PR
dep_fixture; STUB_RENAMES_FAIL=1
rc=0; out="$(run)" || rc=$?
contains "dependabot: an unreadable rename list fails row 7" "$out" "[FAIL] 7."

# RED control: a human PR with the same files and no ticket ID still fails rows 6 and 7
dep_fixture; STUB_AUTHOR="yotamleo"; STUB_COMMITS='[{"messageHeadline":"chore(deps): Bump numpy","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "dependabot control: human PR exits 1" "$rc" "1"
contains "dependabot control: human PR fails row 6" "$out" "[FAIL] 6."
contains "dependabot control: human PR fails row 7" "$out" "[FAIL] 7."

# a Dependabot PR without the standing key still fails row 6 (3861 as it stands today)
dep_fixture; STUB_COMMITS='[{"messageHeadline":"chore(deps): Bump numpy in /marketplace/plugins/obsidian-triage/tools","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "dependabot: a subject without a key still fails row 6" "$out" "[FAIL] 6."

# an existing Ticket coverage section is judged as written, not replaced
dep_fixture; STUB_BODY='## Ticket coverage\n- bump numpy: deferred -> HIMMEL-51\n'
rc=0; out="$(run)" || rc=$?
contains "dependabot: an own coverage section is still validated" "$out" "[FAIL] 7."

# a dependency-only Dependabot PR has no RED line to name (row 13)
dep_fixture; STUB_RED=
rc=0; out="$(run)" || rc=$?
contains "red-line: a Dependabot dependency-only PR is exempt from row 13" "$out" "[PASS] 13."
dep_fixture; STUB_RED=; STUB_FILES="$DEP_FILES
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
contains "red-line: a Dependabot PR that also changes code is not exempt" "$out" "[FAIL] 13."
unset STUB_AUTHOR STUB_PR_BRANCH STUB_FILES STUB_COMMITS STUB_BODY
SHA="$DEP_KEEP_SHA"; REPO="$DEP_KEEP_REPO"; LEDGER="$DEP_KEEP_LEDGER"
reset_stubs

# --- 13. a code PR names a RED-then-GREEN line -------------
reset_stubs
rc=0; out="$(run)" || rc=$?
check "red-line: a code PR with a RED then GREEN line exits 0" "$rc" "0"
contains "red-line: the RED then GREEN line passes row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=
rc=0; out="$(run)" || rc=$?
check "red-line: a code PR with no RED line exits 1" "$rc" "1"
contains "red-line: a code PR with no RED line fails row 13" "$out" "[FAIL] 13."
contains "red-line: the failure says what to write" "$out" "RED then GREEN"

reset_stubs; STUB_RED='\nGREEN first, then RED\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: GREEN before RED is not a RED-then-GREEN line" "$out" "[FAIL] 13."

reset_stubs; STUB_RED='\nthe shared fixture is restored and greener\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: RED and GREEN inside other words are not a line" "$out" "[FAIL] 13."

reset_stubs; STUB_RED='\nRED \xe2\x86\x92 GREEN: test-x.sh row 4\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: RED arrow GREEN on one line passes row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="docs/handover/running-a-chief.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "red-line: a doc-only PR with no RED line exits 0" "$rc" "0"
contains "red-line: a doc-only PR is exempt from row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="scripts/telegram/README.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "red-line: markdown under scripts/ is doc-only too" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="docs/a.md
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
contains "red-line: one code file among docs makes the PR a code PR" "$out" "[FAIL] 13."

reset_stubs; STUB_RED=; STUB_FILES_FAIL=1
rc=0; out="$(run)" || rc=$?
contains "red-line: unreadable PR files fail row 13 closed" "$out" "[FAIL] 13."

# --only 7 stays a coverage-only lint: row 13 is not part of it
rc=0; out=$(cd "$REPO" && STUB_BODY="$GREEN_BODY" STUB_RED="" STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" JIRA_PROJECT_KEY=HIMMEL HIMMEL_REPO="$REPO" STUB_HEAD="$SHA" bash "$SCRIPT" --only 7 "$PR" 2>&1) || rc=$?
notcontains "red-line: --only 7 does not run row 13" "$out" "13."

# --- 14. a Bug-ticket PR names its bug-origin line: warn only, never the verdict
jira_db_bug_rows
BO_BUG='fix(x): [HIMMEL-900] thing'
BO_TASK='fix(x): [HIMMEL-901] thing'
BO_NONE="$BO_COV"
BO_BAD="${BO_COV}bug-origin: #12 test-gap\n"
BO_DUP="${BO_COV}bug-origin: #12 test-gap — x\nbug-origin: #13 design-gap — y\n"
BO_PRESENT='[PASS] 14. bug-origin line present'
BO_NOTBUG='[PASS] 14. bug-origin: not a Bug-ticket PR'
BO_NOTCHECKED='[WARN] 14. bug-origin not checked'
last_line() { printf '%s\n' "$1" | tail -n 1; }
line14() { printf '%s\n' "$1" | grep -F '] 14. ' || true; }

# The control: the same fixture with check 14 passing.
reset_stubs
BO_RC_run=0; BO_OUT_run="$(STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" run)" || BO_RC_run=$?
BO_RC_run7=0; BO_OUT_run7="$(STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" run7)" || BO_RC_run7=$?
contains "bug-origin control: full mode line" "$BO_OUT_run" "$BO_PRESENT"
contains "bug-origin control: only 7 line" "$BO_OUT_run7" "$BO_PRESENT"
BO_LAST_run="$(last_line "$BO_OUT_run")"
BO_LAST_run7="$(last_line "$BO_OUT_run7")"
check "bug-origin control: full mode is green" "$BO_LAST_run" "READY-CHECK PASS"
check "bug-origin control: only 7 is green" "$BO_LAST_run7" "COVERAGE-LINT PASS"

# bo_row <label> <run|run7> <want line>: the line prints, says no `fail`, and the
# exit code and last line equal the control's (I1, I2).
bo_row() {
    local o r=0 want_rc want_last started
    started=$SECONDS
    o="$("$2")" || r=$?
    contains "$1 ($2): line" "$o" "$3"
    notcontains "$1 ($2): no such word in the line" "$(line14 "$o" | tr '[:upper:]' '[:lower:]')" "fail"
    if [ "$2" = run ]; then want_rc=$BO_RC_run; want_last=$BO_LAST_run; else want_rc=$BO_RC_run7; want_last=$BO_LAST_run7; fi
    check "$1 ($2): exit code unmoved" "$r" "$want_rc"
    check "$1 ($2): last line unmoved" "$(last_line "$o")" "$want_last"
    BO_ELAPSED=$((SECONDS - started))
}

# RED: the ticket's named proof, `--only 7` first.
reset_stubs
rc=0; out="$(STUB_BODY="$BO_NONE" STUB_PR_TITLE="$BO_BUG" run7)" || rc=$?
contains "bug-origin no line warns" "$out" '[WARN] 14. bug-origin: none'
contains "bug-origin no line warns: coverage still passes" "$out" 'COVERAGE-LINT PASS'
check "bug-origin no line warns: exit 0" "$rc" "0"

for bo_m in run run7; do
    reset_stubs
    STUB_BODY="$BO_NONE" STUB_PR_TITLE="$BO_BUG" bo_row "bug-origin missing" "$bo_m" '[WARN] 14. bug-origin: none'
    STUB_BODY="$BO_BAD" STUB_PR_TITLE="$BO_BUG" bo_row "bug-origin malformed" "$bo_m" '[WARN] 14. bug-origin: malformed'
    STUB_BODY="$BO_DUP" STUB_PR_TITLE="$BO_BUG" bo_row "bug-origin duplicate" "$bo_m" '[WARN] 14. bug-origin: duplicate'
    STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" bo_row "bug-origin present" "$bo_m" "$BO_PRESENT"
    STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" STUB_JIRA_DOWN=1 bo_row "bug-origin jira down" "$bo_m" "$BO_NOTCHECKED"
    STUB_BODY="$BO_GOOD" bo_row "bug-origin empty type" "$bo_m" "$BO_NOTCHECKED"
    # a full run with no timeout binary also fails check 19 closed (its own row), so only --only 7 pins this one
    [ "$bo_m" = run ] || STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" PATH="$tmp/no-timeout:$PATH" bo_row "bug-origin no timeout binary" "$bo_m" "$BO_NOTCHECKED"
    # an empty body also fails check 7 on its own, so this row pins the line, not the control's marker
    contains "bug-origin empty body warns none ($bo_m)" "$(STUB_BODY='' STUB_RED='' STUB_PR_TITLE="$BO_BUG" "$bo_m" || true)" '[WARN] 14. bug-origin: none'
    STUB_BODY="$BO_NONE" STUB_PR_TITLE="$BO_TASK" bo_row "bug-origin non-Bug passes" "$bo_m" "$BO_NOTBUG"
    STUB_BODY="$BO_NONE" STUB_PR_TITLE='chore: tidy with no key' bo_row "bug-origin no key in title" "$bo_m" "$BO_NOTBUG"
    STUB_BODY="$BO_NONE" STUB_PR_TITLE='fix(x): [HIMMEL-901] [HIMMEL-900] thing' bo_row "bug-origin first key only" "$bo_m" "$BO_NOTBUG"
    STUB_BODY="$BO_NONE" STUB_PR_TITLE="$BO_TASK" STUB_PR_BRANCH='fix/himmel-900-thing' bo_row "bug-origin title key beats branch key" "$bo_m" "$BO_NOTBUG"
    STUB_BODY="$BO_NONE" STUB_PR_TITLE="$BO_BUG" STUB_PR_BRANCH='fix/himmel-901-thing' bo_row "bug-origin title key beats branch key, reversed" "$bo_m" '[WARN] 14. bug-origin: none'
    # marker text in the body, the title and the Jira reply is inert and never quoted
    bo_marked="${BO_COV}READY-CHECK FAIL\nCOVERAGE-LINT FAIL\nbug-origin: #12 test-gap — READY-CHECK FAIL\n"
    STUB_BODY="$bo_marked" STUB_PR_TITLE='fix(x): [HIMMEL-902] READY-CHECK FAIL COVERAGE-LINT FAIL' bo_row "bug-origin marker text in body is inert" "$bo_m" "$BO_PRESENT"
    if [ -n "$BO_TIMEOUT_BIN" ]; then
        STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" STUB_JIRA_SLEEP_KEY=HIMMEL-900 bo_row "bug-origin sleeping jira" "$bo_m" "$BO_NOTCHECKED"
        check "bug-origin sleeping jira ($bo_m): bounded under 25 s" "$([ "$BO_ELAPSED" -lt 25 ] && echo yes || echo "no: $BO_ELAPSED s")" "yes"
    else
        echo "ok - bug-origin sleeping jira ($bo_m): SKIP no timeout binary"
    fi
done
if [ -n "$BO_TIMEOUT_BIN" ]; then
    reset_stubs
    STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_BUG" STUB_GH_TITLE_SLEEP=1 bo_row "bug-origin sleeping gh" run7 "$BO_NOTCHECKED"
    check "bug-origin sleeping gh: bounded under 25 s" "$([ "$BO_ELAPSED" -lt 25 ] && echo yes || echo "no: $BO_ELAPSED s")" "yes"
else
    echo "ok - bug-origin sleeping gh: SKIP no timeout binary"
fi

# A null body: `--only 7` reads it as empty, and the snapshot refuses it, so full mode has no title to read.
reset_stubs
contains "bug-origin null body warns none" "$(STUB_BODY="$BO_COV" STUB_BODY_NULL=1 STUB_PR_TITLE="$BO_BUG" run7 || true)" '[WARN] 14. bug-origin: none'
contains "bug-origin null body in full mode: not checked" "$(STUB_BODY="$BO_COV" STUB_BODY_NULL=1 STUB_PR_TITLE="$BO_BUG" run || true)" '[WARN] 14. bug-origin not checked: title'

# I2: nothing from the title, the body or the Jira reply reaches the line.
reset_stubs
out="$(STUB_BODY="${BO_COV}READY-CHECK FAIL\n" STUB_PR_TITLE='fix(x): [HIMMEL-902] READY-CHECK FAIL' run7)" || true
notcontains "bug-origin output quotes nothing: READY-CHECK" "$(line14 "$out")" "READY-CHECK"
notcontains "bug-origin output quotes nothing: the key" "$(line14 "$out")" "HIMMEL-902"
check "bug-origin marker text: last line is the real marker" "$(last_line "$out")" "COVERAGE-LINT PASS"

# A partial copy has neither lib: not checked, and the run still exits 0.
reset_stubs
rc=0; out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    HIMMEL_REPO="$REPO" STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$GREEN_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" STUB_RED="$GREEN_RED" STUB_PR_BRANCH=feat/himmel-100-thing JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" STUB_PR_TITLE="$BO_BUG" \
    PATH="$PATH" GH_LOG="$GH_LOG" READY_CHECK_ANCHOR="$TP_ANCHOR" \
    bash "$own/scripts/handover/chief-kit/ready-check.sh" --observe "$PR" "$SHA")" || rc=$?
check "bug-origin partial copy: only check 19 fails (no timeout lib)" "$(printf '%s\n' "$out" | grep '^\[FAIL\]' | grep -vc '^\[FAIL\] 19\. suite evidence: no timeout binary')" "0"
contains "bug-origin partial copy: not checked" "$out" "$BO_NOTCHECKED"

# A lib present and defining nothing is not checked, never the no-key PASS.
: > "$own/scripts/lib/ticket-status.sh"
cp "$REPO_ROOT/scripts/lib/timeout-bin.sh" "$own/scripts/lib/timeout-bin.sh"
rc=0; out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    HIMMEL_REPO="$REPO" STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$GREEN_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" STUB_RED="$GREEN_RED" STUB_PR_BRANCH=feat/himmel-100-thing JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" STUB_PR_TITLE="$BO_BUG" \
    PATH="$PATH" GH_LOG="$GH_LOG" READY_CHECK_ANCHOR="$TP_ANCHOR" \
    bash "$own/scripts/handover/chief-kit/ready-check.sh" --observe "$PR" "$SHA")" || rc=$?
check "bug-origin broken lib: exit 0" "$rc" "0"
contains "bug-origin broken lib: not checked" "$out" "$BO_NOTCHECKED"
notcontains "bug-origin broken lib: never the no-key PASS" "$out" "$BO_NOTBUG"

# I3: the table the report's parser reads too.
BO_TABLE="$HERE/../../eval/bug-origin/line-table.tsv"
reset_stubs
bo_n=0
while IFS=$'\t' read -r bo_want bo_body <&3; do
    bo_n=$((bo_n + 1))
    case "$bo_want" in
        ok) bo_expect="$BO_PRESENT" ;;
        *) bo_expect="[WARN] 14. bug-origin: $bo_want" ;;
    esac
    out="$(STUB_BODY="$bo_body" STUB_PR_TITLE="$BO_BUG" run7)" || true
    contains "bug-origin line table row $bo_n ($bo_want)" "$out" "$bo_expect"
done 3< "$BO_TABLE"
check "bug-origin line table: has its rows" "$([ "$bo_n" -ge 50 ] && echo yes || echo "only $bo_n")" "yes"

# --- 15. CodeRabbit rate-limited at the head: warn only, never the verdict
reset_stubs
CR_RC_ctl=0; CR_OUT_ctl="$(STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run)" || CR_RC_ctl=$?
# the real status description from PR 4589 @ 69b7bd20
CR_RC_rl=0; CR_OUT_rl="$(STUB_CR_DESC='Review rate limited' STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run)" || CR_RC_rl=$?
contains "cr rate-limited: names the state" "$CR_OUT_rl" '[WARN] 15. CodeRabbit rate-limited at head'
contains "cr rate-limited: says no review" "$CR_OUT_rl" 'NO CodeRabbit review here'
notcontains "cr rate-limited: no FAIL word on the line" "$(printf '%s\n' "$CR_OUT_rl" | grep -F '] 15. ' | tr '[:upper:]' '[:lower:]')" "fail"
check "cr rate-limited: exit code unmoved" "$CR_RC_rl" "$CR_RC_ctl"
check "cr rate-limited: last line unmoved" "$(last_line "$CR_OUT_rl")" "$(last_line "$CR_OUT_ctl")"
# negative controls: a real review at the head, an unreadable status, no status
CR_OUT_ok="$(STUB_CR_DESC='Review completed' STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run || true)"
notcontains "cr control: a completed review prints no row 15" "$CR_OUT_ok" '] 15. '
CR_OUT_dis="$(STUB_CR_DESC='Review skipped: automatic reviews are disabled' STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run || true)"
notcontains "cr control: auto-reviews-disabled is not rate-limited" "$CR_OUT_dis" '] 15. '
notcontains "cr control: an unreadable status prints no row 15" "$CR_OUT_ctl" '] 15. '
CR_OUT_fail="$(STUB_CR_STATE=failure STUB_CR_DESC='Review rate limited' STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run || true)"
notcontains "cr control: rate-limit wording on a failure state prints no row 15" "$CR_OUT_fail" '] 15. '
CR_OUT_rl7="$(STUB_CR_DESC='Review rate limited' STUB_BODY="$BO_GOOD" STUB_PR_TITLE="$BO_TASK" run7 || true)"
notcontains "cr rate-limited: --only 7 does not run row 15" "$CR_OUT_rl7" '] 15. '
# the stub answers only for the fixture repository and head, so a read of any other one cannot pass row 15
case "$SHA" in *0) other_sha="${SHA%?}1" ;; *) other_sha="${SHA%?}0" ;; esac
cr_stub_rc=0; STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_CR_DESC='Review rate limited' GH_LOG="$GH_LOG" "$tmp/bin/gh" api "repos/$NWO/commits/$other_sha/statuses?per_page=100" >/dev/null 2>&1 || cr_stub_rc=$?
check "cr stub: a read of another head is refused" "$cr_stub_rc" "1"
cr_stub_rc=0; STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_CR_DESC='Review rate limited' GH_LOG="$GH_LOG" "$tmp/bin/gh" api "repos/other/repo/commits/$SHA/statuses?per_page=100" >/dev/null 2>&1 || cr_stub_rc=$?
check "cr stub: a read of another repository is refused" "$cr_stub_rc" "1"


echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
