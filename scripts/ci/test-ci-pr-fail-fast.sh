#!/usr/bin/env bash
# scripts/ci/test-ci-pr-fail-fast.sh -- fail-fast policy of .github/workflows/ci.yml:
# the shell-unit-shard and bun-suites matrices stop at the first red
# leg on pull_request ONLY; push-to-main and the nightly keep every leg running so a
# red stays attributable. A PR with one red shard plus fail-fast-cancelled siblings
# must still read FAILED: the shell-unit aggregator's first step is executed here
# for each rollup value, and every job has a fail-fast twin that cancels the run
# when it fails (pull_request only). Pure text + local bash runs of extracted steps; no network.
#
# Usage: bash scripts/ci/test-ci-pr-fail-fast.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

PR_ONLY="\${{ github.event_name == 'pull_request' }}"

# The 'fail-fast:' value of a job's strategy block.
failfast_of() {
  awk -v job="$1" '
    /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { cur = $1; sub(/:$/, "", cur) }
    cur == job && /^      fail-fast:/ { sub(/^      fail-fast:[ ]*/, ""); sub(/[ ]+#.*$/, ""); print; exit }
  ' "$CI_YML"
}

for job in shell-unit-shard bun-suites; do
  v="$(failfast_of "$job")"
  if [ "$v" = "$PR_ONLY" ]; then ok "$job fail-fast is pull_request only"
  else bad "$job fail-fast is '${v:-<absent>}' (expected: $PR_ONLY)"; fi
done

# The aggregator's rollup step: extract its run: body and execute it per rollup value.
body="$(awk '
  /^  shell-unit:/ { j = 1; next }
  j && /^  [A-Za-z0-9_-]+:/ { j = 0 }
  j && /- name: Every gating shell-unit shard must have passed/ { s = 1; next }
  s && /^        run: \|/ { r = 1; next }
  s && r && /^          / { sub(/^          /, ""); print; next }
  s && r { exit }
' "$CI_YML")"

if [ -z "$body" ]; then
  bad "could not extract the shell-unit rollup step"
else
  for res in failure cancelled skipped; do
    SHARDS_RESULT="$res" bash -c "$body" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 1 ]; then ok "rollup '$res' fails the aggregator"
    else bad "rollup '$res' exited $rc (expected 1, never green)"; fi
  done
  SHARDS_RESULT=success bash -c "$body" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "rollup 'success' passes the aggregator"
  else bad "rollup 'success' exited $rc (expected 0)"; fi
fi

# Run-level fail-fast on pull_request: every job a PR run starts has a
# fail-fast-<job> twin that needs only that job, starts only when it failed, and
# cancels the run (the matrix fail-fast above only reaches sibling legs). A green
# run gives no runner to any twin. A twin holds actions: write and nothing else
# and runs no PR code: no checkout, no uses:. Fixtures are the real jobs-API
# payloads of two CI runs (name/status/conclusion kept):
# pr-fail-fast-jobs-green.json = run 39034533470 (every job finished green),
# pr-fail-fast-jobs-failed.json = run 39045466700 (plugin-version-bump red).
NO_TWIN=" shell-unit guard-corpus-full " # the shard aggregator; schedule-only
# needs.<job>.result, not failure() alone: failure() is also true when only an
# ancestor (plan) failed, which would fire every twin downstream of it.
twin_if() { echo "failure() && needs.$1.result == 'failure' && github.event_name == 'pull_request'"; }

job_block() {
  awk -v job="$1" '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { cur = $1; sub(/:$/, "", cur) }
    in_jobs && cur == job { print }
  ' "$CI_YML"
}
job_ids="$(awk '
  /^jobs:/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { s = $1; sub(/:$/, "", s); print s }
' "$CI_YML")"
# The run: body of a block's only step.
run_body() {
  awk '
    /^        run: \|/ { r = 1; next }
    r && /^          / { sub(/^          /, ""); print; next }
    r { exit }'
}
needs_twin() { case "$1" in fail-fast-*) return 1 ;; esac; case "$NO_TWIN" in *" $1 "*) return 1 ;; esac; return 0; }

twin_body=""
for job in $job_ids; do
  needs_twin "$job" || continue
  tb="$(job_block "fail-fast-$job")"
  if [ -z "$tb" ]; then bad "$job has no fail-fast-$job twin"; continue; fi
  perms="$(printf '%s\n' "$tb" | awk '/^    permissions:/ { p = 1; next } p && /^      / { print; next } p { exit }')"
  body="$(printf '%s\n' "$tb" | run_body)"
  if ! printf '%s\n' "$tb" | grep -qx "    needs: $job"; then bad "fail-fast-$job does not need exactly $job"
  elif ! printf '%s\n' "$tb" | grep -qxF "    if: $(twin_if "$job")"; then bad "fail-fast-$job is not gated to '$(twin_if "$job")'"
  elif [ "$perms" != "      actions: write" ]; then bad "fail-fast-$job permissions are '$perms' (expected actions: write only)"
  elif printf '%s\n' "$tb" | grep -qE '^[[:space:]]+(- )?uses:'; then bad "fail-fast-$job runs an action"
  elif [ -z "$body" ]; then bad "fail-fast-$job has no run: | step"
  elif [ -n "$twin_body" ] && [ "$body" != "$twin_body" ]; then bad "fail-fast-$job step differs from the other twins"
  else ok "fail-fast-$job cancels the run when $job fails"; twin_body="$body"; fi
done

# Every job of a real PR run, and the red job of a real red run, has a twin.
fixture_jobs() { jq -r "$2" "$ROOT/scripts/ci/fixtures/pr-fail-fast-jobs-$1.json" | sed 's/ (.*//' | sort -u; }
missing=""
for job in $(fixture_jobs green '.jobs[].name'); do
  needs_twin "$job" || continue
  [ -n "$(job_block "fail-fast-$job")" ] || missing="$missing $job"
done
if [ -z "$missing" ]; then ok "every job of PR run 39034533470 has a twin"
else bad "jobs of PR run 39034533470 with no twin:$missing"; fi
red="$(fixture_jobs failed '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .name')"
if [ -n "$red" ] && [ -n "$(job_block "fail-fast-$red")" ]; then ok "run 39045466700's red $red would cancel the run"
else bad "run 39045466700's red '${red:-<none>}' has no twin"; fi

# No job but a twin holds actions: write, so no job that runs PR code does,
# and no watcher holds a runner from the start of the run.
writers=""
for job in $job_ids; do
  case "$job" in fail-fast-*) continue ;; esac
  job_block "$job" | grep -qE '^      actions: write[[:space:]]*$' && writers="$writers $job"
done
if [ -z "$writers" ]; then ok "only fail-fast twins hold actions: write"
else bad "jobs other than the twins hold actions: write:$writers"; fi

# The shared twin step cancels this run once and never fails, even when the
# token cannot cancel (a fork PR's token is read-only).
if [ -z "$twin_body" ]; then
  bad "no well-formed twin step to run"
else
  stub="$(mktemp -d -t prfailfast.XXXXXX)" || exit 1
  trap 'rm -rf "$stub"' EXIT
  cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "cancel" ]; then echo "$3" >> "$CANCEL_LOG"; exit "${GH_RC:-0}"; fi
exit 1
STUB
  chmod +x "$stub/gh"
  for gh_rc in 0 1; do
    : > "$stub/cancel.log"
    PATH="$stub:$PATH" CANCEL_LOG="$stub/cancel.log" GH_RC="$gh_rc" RUN_ID=4242 GH_REPO=o/r \
      timeout 20 bash -c "$twin_body" >/dev/null 2>&1; rc=$?
    n="$(wc -l < "$stub/cancel.log")"
    if [ "$rc" -eq 0 ] && [ "$n" -eq 1 ] && grep -qx 4242 "$stub/cancel.log"; then ok "twin step cancels run 4242 once (gh rc $gh_rc), exit 0"
    else bad "twin step with gh rc $gh_rc: rc=$rc cancels=$n (expected 0 and one cancel of 4242)"; fi
  done
fi


[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
