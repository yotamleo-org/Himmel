#!/usr/bin/env bash
# scripts/ci/test-os-verify-workflow.sh -- static suite for the dispatch-only os-verify.yml workflow that replaces ci.yml's force_all_os input.
# The workflow exists to verify impacted suites on ONE chosen OS on demand, so
# three properties must hold or it is worse than what it replaces:
#   1. it can only ever be DISPATCHED (a pull_request/push/schedule trigger
#      would put the paid macOS/Windows legs back on every PR);
#   2. every job name carries the `os-verify / ` prefix, so a dispatch on a PR
#      head can never post a check-run that satisfies (or shadows) one of the
#      required contexts by name;
#   3. a real failure fails the job (no continue-on-error).
# Pure text assertions over the workflow file plus mutation controls that prove
# each check can fail; no network.
#
# Usage: bash scripts/ci/test-os-verify-workflow.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${OS_VERIFY_YML:-$ROOT/.github/workflows/os-verify.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# The 24 required contexts on `main` (ruleset protect-main + classic branch
# protection carry the same list, read 2026-09-29 via
# `gh api repos/yotamleo/Himmel/branches/main/protection/required_status_checks`).
# ponytail: a frozen copy, so a context added later is not checked here;
# upgrade path is a live read once the check-ci.sh required_set is reusable.
REQUIRED_CONTEXTS='bun-suites (ubuntu-latest)
codeowner-review-gate
commit-lint
doc-invariants
guardrail-matrices
lanes-and-trust-suites
leak-classes
lint
node-suites (bitbucket)
node-suites (ci-orchestrator)
node-suites (himmel-run)
node-suites (jira)
secret-scan
security-scan
shell-unit-shard (ubuntu-latest, 1)
shell-unit-shard (ubuntu-latest, 2)
shell-unit-shard (ubuntu-latest, 3)
shell-unit-shard (ubuntu-latest, 4)
shell-unit-shard (ubuntu-latest, 5)
shell-unit-shard (ubuntu-latest, 6)
shell-unit-shard (ubuntu-latest, 7)
shell-unit-shard (ubuntu-latest, 8)
shell-unit (ubuntu-latest)
pr-title-lint'

# strip_comments <file> -- drop full-line and trailing ` # ...` comments so a
# comment can never satisfy (or trip) an assertion.
strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# top_block <file> <key> -- the body of a column-0 `<key>:` block.
top_block() {
  strip_comments "$1" | awk -v k="$2" '$0 == k ":" {f=1; next} f && /^[^ ]/ {f=0} f'
}

# trigger_keys <file> -- the event names under `on:`.
trigger_keys() { top_block "$1" on | sed -n 's/^  \([a-z_]*\):.*$/\1/p'; }

# input_block <file> <input> -- the body of one workflow_dispatch input.
input_block() {
  top_block "$1" on | awk -v k="$2" '$0 == "      " k ":" {f=1; next} f && /^      [a-z_]+:/ {f=0} f'
}

# job_ids <file> -- the column-2 keys under `jobs:`.
job_ids() { top_block "$1" jobs | sed -n 's/^  \([A-Za-z0-9_-]*\):$/\1/p'; }

# job_block <file> <id> -- the body of one job.
job_block() {
  top_block "$1" jobs | awk -v k="$2" '$0 == "  " k ":" {f=1; next} f && /^  [A-Za-z0-9_-]+:$/ {f=0} f'
}

# check_dispatch_only <file> -- rc 0 iff workflow_dispatch is the only trigger.
check_dispatch_only() {
  [ "$(trigger_keys "$1")" = "workflow_dispatch" ]
}

# check_job_names <file> -- rc 0 iff every job declares a `os-verify / ` name.
check_job_names() {
  local ids id n=0
  ids="$(job_ids "$1")"
  [ -n "$ids" ] || return 1
  for id in $ids; do
    grep -q '^    name: os-verify / ' <<< "$(job_block "$1" "$id")" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# check_no_continue_on_error <file> -- rc 0 iff no job tolerates failure.
check_no_continue_on_error() {
  ! grep -q 'continue-on-error' <<< "$(strip_comments "$1")"
}

# check_permissions_exact <file> -- rc 0 iff the top-level permissions block is
# exactly `contents: read` (a dispatch can read the repo and nothing else).
check_permissions_exact() {
  [ "$(top_block "$1" permissions | sed '/^[[:space:]]*$/d')" = "  contents: read" ]
}

# check_concurrency <file> -- rc 0 iff a group keyed on the ref AND the os input
# exists and never cancels a running proof.
check_concurrency() {
  local b
  b="$(top_block "$1" concurrency)"
  grep -q '^  group: .*github\.ref' <<< "$b" \
    && grep -q '^  group: .*inputs\.os' <<< "$b" \
    && grep -q '^  cancel-in-progress: false$' <<< "$b"
}

# run_bodies <file> -- the text of every `run:` step (one-liners and | / > blocks).
run_bodies() {
  strip_comments "$1" | awk '
    inrun { match($0, /^ */); if (RLENGTH > ind || $0 ~ /^[[:space:]]*$/) { print; next } inrun = 0 }
    $0 ~ /^[[:space:]]*(- )?run:/ {
      match($0, /^[[:space:]]*(- )?/); ind = RLENGTH
      s = $0; sub(/^[[:space:]]*(- )?run:/, "", s); print s
      if (s ~ /^[[:space:]]*[|>]/) inrun = 1
    }'
}

# check_no_inputs_in_run <file> -- rc 0 iff no run: body interpolates an input
# (inputs reach the shell only through env:, never spliced into the script text).
# A run: body that could not be extracted at all fails, so the check cannot pass
# vacuously.
check_no_inputs_in_run() {
  local b
  b="$(run_bodies "$1")"
  grep -q 'run-shell-tests' <<< "$b" || return 1
  ! grep -q 'inputs\.' <<< "$b"
}

if [ -f "$WF" ]; then ok "os-verify.yml exists"
else bad "os-verify.yml does not exist at $WF"; echo "$fails failed" >&2; exit 1; fi

# --- 1. dispatch-only ------------------------------------------------------
if check_dispatch_only "$WF"; then ok "the only trigger is workflow_dispatch"
else bad "triggers are not workflow_dispatch alone: $(trigger_keys "$WF" | tr '\n' ' ')"; fi

# --- 2. inputs -------------------------------------------------------------
os_in="$(input_block "$WF" os)"
suites_in="$(input_block "$WF" suites)"
if grep -q 'type: choice' <<< "$os_in" && grep -q 'default: macos' <<< "$os_in" \
   && grep -q -- '- macos' <<< "$os_in" && ! grep -qi 'windows\|- both' <<< "$os_in"; then
  ok "input os is a choice of macos alone, default macos (Windows is dropped)"
else bad "input os is not a macos-only choice defaulting to macos"; fi
if grep -qi 'windows' <<< "$(strip_comments "$WF")"; then bad "os-verify.yml still names Windows outside comments"
else ok "os-verify.yml names no Windows leg outside comments"; fi
if grep -q 'type: choice' <<< "$suites_in" && grep -q 'default: impacted' <<< "$suites_in" \
   && grep -q -- '- impacted' <<< "$suites_in" && grep -q -- '- all' <<< "$suites_in"; then
  ok "input suites is a choice of impacted|all, default impacted"
else bad "input suites is not a choice of impacted|all defaulting to impacted"; fi

# --- 3. job-name prefix + no required-context collision ---------------------
if grep -q '^name: os-verify$' "$WF"; then
  ok "workflow name is os-verify"
else bad "workflow name is not exactly os-verify"; fi

if check_job_names "$WF"; then ok "every job name starts with 'os-verify / '"
else bad "a job has no name or a name without the 'os-verify / ' prefix"; fi

shards="$(strip_comments "$WF" | sed -n 's/^[[:space:]]*shard:[[:space:]]*\[\(.*\)\].*$/\1/p' | head -1 | tr -d ' ' | tr ',' ' ')"
collided=0
resolved=0
for id in $(job_ids "$WF"); do
  expr="$(job_block "$WF" "$id" | sed -n 's/^    name:[[:space:]]*//p')"
  for os in $(sed -n 's/^.*os: \[\(.*\)\]$/\1/p' <<< "$(strip_comments "$WF")" | tr ',' ' '); do
    for sh in ${shards:-1}; do
      name="${expr//\$\{\{ matrix.os \}\}/$os}"
      name="${name//\$\{\{ matrix.shard \}\}/$sh}"
      # shellcheck disable=SC2016  # a literal GitHub expression opener, not a shell expansion
      case "$name" in
        *'${{'*) bad "job $id name has an expression the test cannot resolve: $expr"; continue ;;
      esac
      resolved=$((resolved + 1))
      if grep -qxF -- "$name" <<< "$REQUIRED_CONTEXTS"; then
        bad "job $id resolves to the required context name '$name'"; collided=1
      fi
    done
  done
done
if [ "$resolved" -gt 0 ] && [ "$collided" -eq 0 ]; then
  ok "no resolved job name ($resolved checked) equals a required context"
elif [ "$resolved" -eq 0 ]; then bad "no job name could be resolved"; fi

# --- 4. the run: impacted suites against origin/main's merge-base ------------
body="$(strip_comments "$WF")"
if grep -q 'git merge-base origin/main HEAD' <<< "$body"; then ok "range base is the merge-base with origin/main"
else bad "no 'git merge-base origin/main HEAD' range base"; fi
if grep -q 'run-shell-tests.sh --impacted' <<< "$body"; then ok "runs run-shell-tests.sh --impacted"
else bad "does not run run-shell-tests.sh --impacted"; fi
if grep -q 'fetch-depth: 0' <<< "$body"; then ok "full-depth checkout (the merge-base needs history)"
else bad "checkout is shallow: git merge-base origin/main HEAD cannot resolve"; fi

# --- 5. the shard count is spelled twice and must agree ----------------------
nshards=$(wc -w <<< "$shards" | tr -d ' ')  # BSD wc pads its count with spaces
# shellcheck disable=SC2016  # a literal GitHub expression, not a shell expansion
argn="$(grep -o -- '--shard \${{ matrix.shard }}/[0-9]*' <<< "$body" | sed 's|.*/||' | sort -u)"
if [ "$nshards" -gt 0 ] && [ "$(wc -l <<< "$argn")" -eq 1 ] && [ "$argn" = "$nshards" ]; then
  ok "matrix shard list ($nshards) matches the --shard /N argument"
else bad "matrix has $nshards shards but --shard args say '${argn:-none}'"; fi

# --- 6. failures are real ----------------------------------------------------
if check_no_continue_on_error "$WF"; then ok "no continue-on-error: a red suite fails the job"
else bad "continue-on-error present: a red suite would not fail the job"; fi

# --- 6b. least privilege, injection-safe, non-stacking ---------
if check_permissions_exact "$WF"; then ok "permissions are exactly contents: read"
else bad "permissions are not exactly contents: read"; fi
if check_no_inputs_in_run "$WF"; then ok "no \${{ inputs.* }} inside a run: body (inputs reach the shell via env:)"
else bad "a run: body interpolates an input (or no run: body was found)"; fi
if check_concurrency "$WF"; then ok "concurrency group keys on github.ref + inputs.os, cancel-in-progress false"
else bad "concurrency must be a group keyed on github.ref and inputs.os with cancel-in-progress false"; fi

# --- 6c. macOS runs ONLY the curated POC list --------------------------------
POC_LIST="${OS_VERIFY_POC_LIST:-$ROOT/scripts/ci/macos-poc-suites.txt}"
POC_REL=scripts/ci/macos-poc-suites.txt

# poc_entries <file> -- the suite paths the list names (comments/blanks dropped).
poc_entries() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

# check_poc_list <file> -- rc 0 iff the list names at least one suite and every
# entry is a tracked suite file under the repo (a stale path fails, not skips).
check_poc_list() {
  local e n=0
  [ -f "$1" ] || return 1
  while IFS= read -r e; do
    [ -f "$ROOT/$e" ] || return 1
    case "$e" in */test-*.sh|test-*.sh) ;; *) return 1 ;; esac
    n=$((n + 1))
  done <<< "$(poc_entries "$1")"
  [ "$n" -gt 0 ]
}

# check_reads_poc_list <file> -- rc 0 iff EVERY run-shell-tests.sh invocation
# (impacted and all) passes --only-list <the list>, so no path to a suite
# outside the list exists on macOS.
check_reads_poc_list() {
  local runs n
  runs="$(strip_comments "$1" | grep 'run-shell-tests\.sh')" || return 1
  n=$(wc -l <<< "$runs" | tr -d ' ')
  [ "$n" -ge 2 ] || return 1
  [ "$(grep -c -- "--only-list $POC_REL" <<< "$runs" | tr -d ' ')" = "$n" ]
}

if check_poc_list "$POC_LIST"; then ok "macos-poc-suites.txt exists, is non-empty and every entry is a real suite file"
else bad "macos-poc-suites.txt is missing, empty, or names a path that is not a test-*.sh file"; fi
if check_reads_poc_list "$WF"; then ok "every run-shell-tests.sh call in os-verify.yml passes --only-list $POC_REL"
else bad "a run-shell-tests.sh call in os-verify.yml does not pass --only-list $POC_REL"; fi
# The 27 suites that FAILED on the macOS runner in os-verify run 38660360246
# (eb4a3e64, read 2026-10-15 from the shard logs). A suite outside the list is
# not selected on macOS, so none of these may be in it; remove a name here in
# the same change that fixes it and adds it to the list (the macOS ratchet).
MACOS_KNOWN_RED='scripts/ci/test-check-hooks-on-pr-range.sh
scripts/ci/test-main-sweep-red-issue.sh
scripts/ci/test-shard-manifest-verify.sh
scripts/cr/test-impacted-suites.sh
scripts/eval/leg-digest/test-failure-review.sh
scripts/eval/leg-digest/test-failure-router.sh
scripts/eval/leg-digest/test-leg-digest.sh
scripts/handover/console-kit/test-append-results.sh
scripts/handover/console-kit/test-close-wrapped-leg.sh
scripts/handover/console-kit/test-live-subagents.sh
scripts/handover/console-kit/test-wrap-merged.sh
scripts/handover/test-arm-resume-fast.sh
scripts/himmelctl/test/test-config-feed.sh
scripts/himmelctl/test/test-wizard-probes.sh
scripts/hooks/test-auto-approve-safe-bash.sh
scripts/hooks/test-block-bank-lift-writes.sh
scripts/hooks/test-block-chokepoint-env-prefix.sh
scripts/hooks/test-block-destructive-commands.sh
scripts/hooks/test-block-tail-pipe-on-gates.sh
scripts/hooks/test-guard-pr-check-literal.sh
scripts/hooks/test-wired-hooks-integrity-resolution.sh
scripts/lanes/test-lane-canary.sh
scripts/lib/test-claude-headless.sh
scripts/lib/test-fixture-trap-clean.sh
scripts/observability/test-suite-flake-summary.sh
scripts/telegram/test-break-glass.sh
scripts/test-quiet-run.sh'
# check_poc_excludes_red <file> -- rc 0 iff no known-red suite is in the list.
check_poc_excludes_red() {
  ! grep -qFxf <(poc_entries "$1") <<< "$MACOS_KNOWN_RED"
}
if check_poc_excludes_red "$POC_LIST"; then ok "no suite that failed on macOS (run 38660360246) is in the POC list"
else bad "the POC list names a suite that failed on macOS: $(grep -Fxf <(poc_entries "$POC_LIST") <<< "$MACOS_KNOWN_RED" | tr '\n' ' ')"; fi

# --- 7. mutation controls: each check above must be able to fail --------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/os-verify-test.XXXXXX")" || { bad "mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

awk '{print} /^on:$/ {print "  pull_request:"}' "$WF" > "$tmp/pr.yml"
if check_dispatch_only "$tmp/pr.yml"; then bad "control: an added pull_request trigger was not detected"
else ok "control: an added pull_request trigger is detected"; fi

sed 's/^    name: os-verify \/ /    name: /' "$WF" > "$tmp/noprefix.yml"
if check_job_names "$tmp/noprefix.yml"; then bad "control: a dropped os-verify prefix was not detected"
else ok "control: a dropped os-verify prefix is detected"; fi

awk '/^    runs-on:/ {print "    continue-on-error: true"} {print}' "$WF" > "$tmp/coe.yml"
if check_no_continue_on_error "$tmp/coe.yml"; then bad "control: an added continue-on-error was not detected"
else ok "control: an added continue-on-error is detected"; fi

awk '{print} /^  contents: read$/ {print "  pull-requests: write"}' "$WF" > "$tmp/perm.yml"
if check_permissions_exact "$tmp/perm.yml"; then bad "control: an extra write permission was not detected"
else ok "control: an extra permission is detected"; fi

# shellcheck disable=SC2016  # a literal GitHub expression spliced into a run: body
sed 's|bash scripts/ci/run-shell-tests.sh --impacted|echo ${{ inputs.suites }}; &|' "$WF" > "$tmp/inj.yml"
if check_no_inputs_in_run "$tmp/inj.yml"; then bad "control: an input spliced into a run: body was not detected"
else ok "control: an input spliced into a run: body is detected"; fi
: > "$tmp/empty.yml"
if check_no_inputs_in_run "$tmp/empty.yml"; then bad "control: a file with no extractable run: body passed vacuously"
else ok "control: no extractable run: body fails the check (not vacuous)"; fi

sed 's/^  cancel-in-progress: false$/  cancel-in-progress: true/' "$WF" > "$tmp/cancel.yml"
if check_concurrency "$tmp/cancel.yml"; then bad "control: cancel-in-progress true was not detected"
else ok "control: cancel-in-progress true is detected"; fi
sed 's/^  group: os-verify-.*$/  group: os-verify/' "$WF" > "$tmp/group.yml"
if check_concurrency "$tmp/group.yml"; then bad "control: a group not keyed on ref + os was not detected"
else ok "control: a group not keyed on ref + os is detected"; fi

sed 's|--only-list scripts/ci/macos-poc-suites.txt ||' "$WF" > "$tmp/nolist.yml"
if check_reads_poc_list "$tmp/nolist.yml"; then bad "control: a run-shell-tests call without --only-list was not detected"
else ok "control: a run-shell-tests call without --only-list is detected"; fi
{ cat "$POC_LIST"; echo "scripts/test-quiet-run.sh"; } > "$tmp/redlist.txt"
if check_poc_excludes_red "$tmp/redlist.txt"; then bad "control: a known-red suite added to the list was not detected"
else ok "control: a known-red suite added to the list is detected"; fi
printf '# empty\n' > "$tmp/empty-list.txt"
if check_poc_list "$tmp/empty-list.txt"; then bad "control: an empty list passed"
else ok "control: an empty list fails the check"; fi
printf 'scripts/ci/test-does-not-exist.sh\n' > "$tmp/stale-list.txt"
if check_poc_list "$tmp/stale-list.txt"; then bad "control: a stale path passed"
else ok "control: a stale list entry fails the check"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
