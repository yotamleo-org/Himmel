#!/usr/bin/env bash
# scripts/ci/test-ci-pr-fail-fast.sh -- fail-fast policy of .github/workflows/ci.yml:
# the shell-unit-shard and bun-suites matrices stop at the first red
# leg on pull_request ONLY; push-to-main and the nightly keep every leg running so a
# red stays attributable. A PR with one red shard plus fail-fast-cancelled siblings
# must still read FAILED: the shell-unit aggregator's first step is executed here
# for each rollup value. Pure text + a local bash run of one extracted step; no network.
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

# The pr-fail-fast watcher: on pull_request the first red job cancels the rest of
# the run (the matrix fail-fast above only reaches sibling legs). Fixtures are the
# real jobs-API payloads of two CI runs (name/status/conclusion kept):
# pr-fail-fast-jobs-failed.json = run 39045466700 (plugin-version-bump red),
# pr-fail-fast-jobs-green.json = run 39034533470 (every job finished green).
watcher_block="$(awk '/^  pr-fail-fast:/ { j = 1; print; next } j && /^  [A-Za-z0-9_-]+:/ { exit } j { print }' "$CI_YML")"

if [ -z "$watcher_block" ]; then
  bad "no pr-fail-fast job in ci.yml"
else
  if printf '%s\n' "$watcher_block" | grep -qE "^    if: github\.event_name == 'pull_request'[[:space:]]*$"; then
    ok "pr-fail-fast runs on pull_request only"
  else bad "pr-fail-fast is not gated to pull_request"; fi
  if printf '%s\n' "$watcher_block" | grep -qE '^      actions: write[[:space:]]*$'; then
    ok "pr-fail-fast holds actions: write"
  else bad "pr-fail-fast lacks actions: write"; fi

  wbody="$(printf '%s\n' "$watcher_block" | awk '
    /^      - name: Cancel the run on the first failed job/ { s = 1; next }
    s && /^        run: \|/ { r = 1; next }
    s && r && /^          / { sub(/^          /, ""); print; next }
    s && r { exit }')"
  if [ -z "$wbody" ]; then
    bad "could not extract the pr-fail-fast cancel step"
  else
    stub="$(mktemp -d -t prfailfast.XXXXXX)" || exit 1
    trap 'rm -rf "$stub"' EXIT
    cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then cat "$JOBS_FIXTURE"; exit 0; fi
if [ "$1" = "run" ] && [ "$2" = "cancel" ]; then echo "$3" >> "$CANCEL_LOG"; exit 0; fi
exit 1
STUB
    chmod +x "$stub/gh"
    for case in failed green; do
      : > "$stub/cancel.log"
      PATH="$stub:$PATH" JOBS_FIXTURE="$ROOT/scripts/ci/fixtures/pr-fail-fast-jobs-$case.json" \
        CANCEL_LOG="$stub/cancel.log" RUN_ID=4242 REPO=o/r POLL_SECS=0 \
        timeout 20 bash -c "$wbody" >/dev/null 2>&1; rc=$?
      n="$(wc -l < "$stub/cancel.log")"
      if [ "$case" = failed ]; then
        if [ "$rc" -eq 0 ] && [ "$n" -eq 1 ] && grep -qx 4242 "$stub/cancel.log"; then ok "a red job cancels run 4242"
        else bad "red-job fixture: rc=$rc cancels=$n (expected 0 and one cancel of 4242)"; fi
      else
        if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ]; then ok "an all-green run is left alone"
        else bad "green fixture: rc=$rc cancels=$n (expected 0 and no cancel)"; fi
      fi
    done
  fi
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
