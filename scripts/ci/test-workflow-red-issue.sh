#!/usr/bin/env bash
# scripts/ci/test-workflow-red-issue.sh -- suite for scripts/ci/workflow-red-issue.sh
#
# A stub `gh` on PATH serves canned answers from a per-case stub dir and logs
# every invocation, so each case asserts the issue mutations the script chose:
# open on red, refresh on a second red, close on a later green, ignore
# pull_request events and workflows outside the list. No network, no auth.
# The fixtures under test-workflow-red-fixtures/ are copied from the real run
# 38401182192 (a red `CI (os:macos cadence)` schedule run on main): the run
# row and job list as the Actions API returned them.
#
# Usage: bash scripts/ci/test-workflow-red-issue.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] -- `grep -q` over text with NO pipeline (pipefail).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/workflow-red-issue.sh"
LIST="$ROOT/scripts/ci/workflow-red-list.txt"
FIX="$ROOT/scripts/ci/test-workflow-red-fixtures"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
has()   { if grepq "$2" -e "$1"; then ok "$3"; else bad "$3; log: $2"; fi; }
hasnt() { grepq "$2" -e "$1"; local r=$?; if [ "$r" -eq 1 ]; then ok "$3"; else bad "$3 (grep rc=$r); log: $2"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/workflow-red.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# The stub; the STUB dir names the canned files:
#   run.tsv        "<name>\t<event>\t<branch>\t<sha>\t<conclusion>\t<url>" (actions/runs/<id>)
#   jobs.tsv       "<conclusion>\t<job name>\t<id>" lines                  (actions/runs/<id>/jobs)
#   issues.json    ci-red issues [{number,body,state?}], state defaults to open
#                  (repos/<r>/issues?state=all, served 100 per page like the API, the caller's --jq runs per page)
#   default_branch the repo default branch (default: main)       (repos/<r> --jq .default_branch)
#   default_branch_fail  if present, the default-branch lookup exits 1
#   list_fail      if present, the issue lookup exits 1
#   mut_fail       if present, `issue create` exits 1
#   edit_fail      if present, `issue edit` exits 1
# `issue edit --body-file` is copied to $STUB/edit-<n>.md.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$STUB/gh.log"
case "$*" in
  "api "*"/jobs"*)          cat "$STUB/jobs.tsv" 2>/dev/null ;;
  "api "*"/actions/runs/"*) cat "$STUB/run.tsv" ;;
  "api "*"/issues?"*)
    [ -e "$STUB/list_fail" ] && exit 1
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && f="$a"; prev="$a"; done
    total="$(jq length "$STUB/issues.json")"; i=0
    case " $* " in *" --paginate "*) : ;; *) total=$(( total < 100 ? total : 100 )) ;; esac
    while [ "$i" -lt "$total" ]; do
      jq -r "[.[$i:$((i + 100))][] | .state //= \"open\"] | $f" "$STUB/issues.json"
      i=$((i + 100))
    done ;;
  "api repos/"*"--jq .default_branch") [ -e "$STUB/default_branch_fail" ] && exit 1; cat "$STUB/default_branch" 2>/dev/null || echo main ;;
  "issue create"*)          [ -e "$STUB/mut_fail" ] && exit 1 ;;
  "issue edit"*)
    [ -e "$STUB/edit_fail" ] && exit 1
    prev=""; for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$STUB/edit-$3.md"; prev="$a"; done ;;
  "issue comment"*|"issue close"*|"label create"*) : ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 99 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# newcase <name> [red|green] -> STUB seeded with the real red run + jobs.
newcase() {
  STUB="$TMP/$1"; mkdir -p "$STUB"; export STUB
  cp "$FIX/run-38401182192-macos-cadence-red.tsv" "$STUB/run.tsv"
  cp "$FIX/jobs-38401182192-macos-cadence-red.tsv" "$STUB/jobs.tsv"
  printf '[]\n' > "$STUB/issues.json"
  : > "$STUB/gh.log"
}
# setrun <field> <value>: rewrite one run.tsv column (1 name 2 event 3 branch 5 conclusion).
setrun() {
  awk -F'\t' -v OFS='\t' -v c="$1" -v v="$2" '{ $c = v; print }' "$STUB/run.tsv" > "$STUB/run.new" && mv "$STUB/run.new" "$STUB/run.tsv"
}
report() { # [run-id] -> $out $rc, log in $log
  out="$(PATH="$BIN:$PATH" GITHUB_REPOSITORY=o/r WORKFLOW_RED_LIST="$LIST" bash "$SCRIPT" "${1:-900}" 2>&1)"; rc=$?
  log="$(cat "$STUB/gh.log")"
}
BODY_MAIN='old\n<!-- ci-red-branch: main -->\n<!-- ci-red-run: 800 -->\n'

# 0. Syntax + usage.
if [ -f "$SCRIPT" ] && bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "script missing or syntax error"; fi
newcase usage
PATH="$BIN:$PATH" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi

# 1. Red run, no open issue -> ONE create with ci-red + wf:<slug>, naming the failed jobs.
newcase red-open
report
if [ "$rc" -eq 0 ]; then ok "red/no-issue exits 0"; else bad "red/no-issue exit=$rc; out: $out"; fi
has "gh issue create" "$log" "red/no-issue -> creates the issue"
has "--label ci-red" "$log" "created with the ci-red label"
has "wf:ci-os-macos-cadence" "$log" "created with the wf:<slug> label"
hasnt "gh issue close" "$log" "red never closes"
n_create="$(grep -c 'gh issue create' "$STUB/gh.log")"
if [ "$n_create" -eq 1 ]; then ok "exactly one issue created"; else bad "created $n_create issues"; fi
has "failed: macos-cadence / summary" "$out" "report names a failed job (real job names)"
has "tested sha: d0123766aa368a73065b84161893135d7ebd91e2" "$out" "report names the tested sha"
has "ci-red-branch: main" "$out" "report records the branch marker"

# 2. Second red, open issue #7 for the same branch -> edit + comment, no duplicate.
newcase red-refresh
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
report
has "gh issue edit 7" "$log" "second red -> edits #7 in place"
has "gh issue comment 7" "$log" "second red -> adds a still-red comment"
hasnt "gh issue create" "$log" "second red never opens a duplicate"
hasnt "gh issue close" "$log" "second red never closes"

# 3. Red on another branch while main's issue is open -> its own issue.
newcase red-other-branch
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
setrun 3 "feat/x"
report
has "gh issue create" "$log" "red on another branch opens its own issue"
hasnt "gh issue edit 7" "$log" "another branch does not touch main's issue"

# 3b. A branch carrying a double quote is matched as data (it once sat inside a jq string).
newcase quote-branch
printf '[{"number":9,"body":"x\\n<!-- ci-red-branch: a\\"b -->\\n<!-- ci-red-run: 800 -->\\n"}]\n' > "$STUB/issues.json"
setrun 3 'a"b'
report
has "gh issue edit 9" "$log" "a branch with a double quote finds its own issue"
hasnt "gh issue create" "$log" "a branch with a double quote opens no duplicate"

# 4. Green run closes the open issue of that workflow + branch.
newcase green-close
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
setrun 5 success
report
has "gh issue comment 7" "$log" "green -> comments"
has "gh issue close 7" "$log" "green -> closes #7"

# 5. Green with no open issue, and green on another branch -> nothing mutates.
newcase green-none
setrun 5 success
report
hasnt "gh issue \(create\|edit\|close\|comment\)" "$log" "green/no-issue changes nothing"
newcase green-other-branch
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
setrun 5 success; setrun 3 "feat/x"
report
hasnt "gh issue close" "$log" "green on another branch does not close main's issue"

# 6. pull_request events are never tracked (legs own those), red or not.
newcase pr-event
setrun 2 pull_request
report
if [ "$rc" -eq 0 ]; then ok "pull_request run exits 0"; else bad "pull_request exit=$rc"; fi
hasnt "gh issue\|gh label" "$log" "pull_request run makes no issue call"

# 7. A workflow outside the list is ignored.
newcase unlisted
setrun 1 "Some Other Workflow"
report
hasnt "gh issue\|gh label" "$log" "unlisted workflow makes no issue call"
has "not in" "$out" "unlisted workflow says why"

# 8. An older run never overwrites or closes a newer verdict.
newcase older-run
printf '[{"number":7,"body":"%s"}]\n' '<!-- ci-red-branch: main -->\n<!-- ci-red-run: 950 -->\n' > "$STUB/issues.json"
report 900
hasnt "gh issue \(create\|edit\|close\|comment\)" "$log" "run 900 is older than recorded 950 -> ignored"

# 9. A cancelled run is no verdict.
newcase cancelled
setrun 5 cancelled
report
hasnt "gh issue\|gh label" "$log" "cancelled run makes no issue call"

# 10. A failed lookup is never "no issue": exit 1, no create.
newcase lookup-fail
: > "$STUB/list_fail"
report
if [ "$rc" -eq 1 ]; then ok "lookup failure exits 1"; else bad "lookup failure exit=$rc"; fi
hasnt "gh issue create" "$log" "lookup failure never creates (no duplicate)"

# 11. A failed mutation fails the run.
newcase mut-fail
: > "$STUB/mut_fail"
report
if [ "$rc" -eq 1 ]; then ok "failed create exits 1"; else bad "failed create exit=$rc"; fi

# 12. a red workflow_dispatch run on a feature branch opens no issue
#     (real run 38660360246 and its jobs: the run behind the orphaned GH #2642).
newcase dispatch-feature-red
cp "$FIX/run-38660360246-dispatch-feature-red.tsv" "$STUB/run.tsv"
cp "$FIX/jobs-38660360246-dispatch-feature-red.tsv" "$STUB/jobs.tsv"
report 38660360246
if [ "$rc" -eq 0 ]; then ok "feature-branch dispatch red exits 0"; else bad "feature-branch dispatch red exit=$rc; out: $out"; fi
hasnt "gh issue \(create\|edit\|comment\)" "$log" "feature-branch dispatch red opens/refreshes nothing"
has "not tracked" "$out" "feature-branch dispatch red says why"
# ... the same dispatch run on the default branch is still tracked,
newcase dispatch-default-red
cp "$FIX/run-38660360246-dispatch-feature-red.tsv" "$STUB/run.tsv"
cp "$FIX/jobs-38660360246-dispatch-feature-red.tsv" "$STUB/jobs.tsv"
setrun 3 main
report 38660360246
has "gh issue create" "$log" "dispatch red on the default branch still opens the issue"
# ... a failed default-branch lookup fails the run and changes no issue.
newcase default-branch-fail
cp "$FIX/run-38660360246-dispatch-feature-red.tsv" "$STUB/run.tsv"
cp "$FIX/jobs-38660360246-dispatch-feature-red.tsv" "$STUB/jobs.tsv"
: > "$STUB/default_branch_fail"
report 38660360246
if [ "$rc" -eq 1 ]; then ok "failed default-branch lookup exits 1"; else bad "failed default-branch lookup exit=$rc; out: $out"; fi
hasnt "gh issue \(create\|edit\|comment\|close\)" "$log" "failed default-branch lookup changes no issue"
# ... and so is a non-dispatch run on a ref that is not the default branch (a Release tag).
newcase push-tag-red
setrun 2 push; setrun 3 v1.2.3
report
has "gh issue create" "$log" "push red on a tag still opens the issue"

# 13. a green run on a feature branch still closes an issue left for it
#     (the real body of orphaned GH #2642).
newcase dispatch-feature-green
cp "$FIX/run-38660360246-dispatch-feature-red.tsv" "$STUB/run.tsv"
setrun 5 success
jq -n --rawfile b "$FIX/issue-2642-body.txt" '[{number: 2642, body: $b}]' > "$STUB/issues.json"
report 38660360300
has "gh issue close 2642" "$log" "green on the feature branch closes its leftover issue"

# 14. a closed issue keeps the newest run id, so an older red finishing
#     after a newer green opens nothing.
newcase green-stamps-run
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
setrun 5 success
report 900
has "gh issue close 7" "$log" "green closes #7"
has "ci-red-run: 900" "$(cat "$STUB/edit-7.md" 2>/dev/null)" "green close stamps its run id into the body"
newcase stamp-fails
printf '[{"number":7,"body":"%s"}]\n' "$BODY_MAIN" > "$STUB/issues.json"
setrun 5 success
: > "$STUB/edit_fail"
report 900
if [ "$rc" -eq 1 ]; then ok "failed stamp exits 1"; else bad "failed stamp exit=$rc"; fi
hasnt "gh issue close" "$log" "an issue whose stamp failed stays open (no lost watermark)"
newcase stale-red-after-green
printf '[{"number":7,"state":"closed","body":"%s"}]\n' '<!-- ci-red-branch: main -->\n<!-- ci-red-run: 950 -->\n' > "$STUB/issues.json"
report 900
hasnt "gh issue \(create\|edit\|comment\|close\)" "$log" "older red after a newer green closed it opens nothing"
newcase newer-red-after-closed
printf '[{"number":7,"state":"closed","body":"%s"}]\n' '<!-- ci-red-branch: main -->\n<!-- ci-red-run: 800 -->\n' > "$STUB/issues.json"
report 900
has "gh issue create" "$log" "a newer red after a closed issue opens a fresh one"
hasnt "gh issue \(edit\|close\) 7" "$log" "a closed issue is never reopened or edited by a red"

# 15. the lookup paginates -- the branch issue sits past the first 100.
newcase paginate
jq -n '[range(0;150) | {number: (1000 + .), body: "<!-- ci-red-branch: b\(.) -->\n<!-- ci-red-run: 800 -->\n"}]
  + [{number: 7, body: "<!-- ci-red-branch: main -->\n<!-- ci-red-run: 800 -->\n"}]' > "$STUB/issues.json"
report
has "gh issue edit 7" "$log" "branch issue past the first 100 is found and refreshed"
hasnt "gh issue create" "$log" "no duplicate opened past 100 issues"

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed." >&2; exit 1; fi
echo "all passed."
