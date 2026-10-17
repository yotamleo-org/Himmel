#!/usr/bin/env bash
# scripts/ci/test-ci-vm-routing.sh -- regression suite: ci.yml routes the
# shell-unit-shard matrix to the himmel-vm self-hosted runner ONLY for a
# same-repo pull_request by an operator account while vars.HIMMEL_VM_RUNNER is
# 'on', and runs it on matrix.os (ubuntu-latest) in every other case. The repo
# is public: a fork PR must never reach the VM runner, and a PR must not hang
# queued for a runner that is switched off.
#
# Pure text assertions over the workflow file (comments stripped, so a comment
# cannot satisfy a check). No network, no PyYAML.
#
# Usage: bash scripts/ci/test-ci-vm-routing.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
HOOK="$ROOT/scripts/vm/ci-runner/job-started-hook.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

stripped="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"
job_block() { awk -v j="$1" '$0 == "  " j ":" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' <<< "$stripped"; }

blk="$(job_block shell-unit-shard)"
runs_on="$(sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p' <<< "$blk")"

if [ -n "$runs_on" ] && [ "$(wc -l <<< "$runs_on")" -eq 1 ]; then ok "shell-unit-shard has exactly one runs-on"; else bad "shell-unit-shard runs-on missing or repeated: $runs_on"; fi

# 1. Both labels of the VM runner are named, and matrix.os is the fallback.
if grep -q 'self-hosted' <<< "$runs_on" && grep -q 'himmel-vm' <<< "$runs_on"; then ok "runs-on can select [self-hosted, himmel-vm]"; else bad "runs-on never names the himmel-vm runner: $runs_on"; fi
if grep -qE '\|\|[[:space:]]*matrix\.os[[:space:]]*\}\}[[:space:]]*$' <<< "$runs_on"; then ok "runs-on falls back to matrix.os"; else bad "runs-on does not fall back to matrix.os: $runs_on"; fi

# 2. The VM route needs every one of: pull_request, same repo, operator author,
#    operator actor, the kill switch on.
need() { # <label> <fixed string>
    if grep -qF -- "$2" <<< "$runs_on"; then ok "VM route requires $1"; else bad "VM route does not require $1 ($2)"; fi
}
need "the pull_request event" "github.event_name == 'pull_request'"
need "a same-repo head" "github.event.pull_request.head.repo.full_name == github.repository"
need "an operator PR author" "github.event.pull_request.user.login"
need "an operator actor" "github.actor"
need "an operator triggering actor (a re-run by another account)" "github.triggering_actor"
need "the kill switch on" "vars.HIMMEL_VM_RUNNER == 'on'"

# 2b. The conditions are mandatory conjunctions, not just present: pin the whole
#     expression, so turning one `&&` into `||` (a route open to any fork PR or
#     any author) fails here. A deliberate routing change edits this line too.
want_expr="\${{ (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON('[\"yotamleo\",\"yotamleo11-test\"]'), github.event.pull_request.user.login) && contains(fromJSON('[\"yotamleo\",\"yotamleo11-test\"]'), github.actor) && contains(fromJSON('[\"yotamleo\",\"yotamleo11-test\"]'), github.triggering_actor) && vars.HIMMEL_VM_RUNNER == 'on') && fromJSON('[\"self-hosted\",\"himmel-vm\"]') || matrix.os }}"
if [ "$runs_on" = "$want_expr" ]; then ok "the routing expression is exactly the reviewed all-conditions-and form"; else bad "runs-on differs from the reviewed expression: $runs_on"; fi
if [ "$(grep -o '||' <<< "$runs_on" | wc -l)" -eq 1 ]; then ok "the only || is the matrix.os fallback"; else bad "runs-on carries an extra ||: $runs_on"; fi

# 3. The operator list matches the runner-side hook's, so the two cannot drift.
for who in yotamleo yotamleo11-test; do
    if grep -qF "\"$who\"" <<< "$runs_on" && grep -qE "(^|[[:space:]|])$who(\||\))" "$HOOK"; then ok "operator $who is in both ci.yml and the runner-side hook"; else bad "operator $who differs between ci.yml and job-started-hook.sh"; fi
done

# 4. Never pull_request_target, anywhere in ci.yml.
if grep -q 'pull_request_target' <<< "$stripped"; then bad "ci.yml uses pull_request_target"; else ok "ci.yml never uses pull_request_target"; fi

# 5. The required check names stay stable: the matrix is still os x shard.
if grep -qE '^[[:space:]]*os:[[:space:]]*\[ubuntu-latest\]' <<< "$blk"; then ok "matrix.os is still [ubuntu-latest] (check names stay shell-unit-shard (ubuntu-latest, N))"; else bad "matrix.os changed; required check names would move"; fi

# 6. No other job routes to the VM runner, and the aggregator stays hosted.
others="$(awk '/^  [a-zA-Z_-]+:/ {job=$1} /himmel-vm/ && !/^[[:space:]]*#/ {print job}' <<< "$stripped" | sort -u | tr '\n' ' ')"
if [ "$others" = "shell-unit-shard: " ]; then ok "only shell-unit-shard names the VM runner"; else bad "jobs naming the VM runner: $others"; fi

# 7. The guest `runner` has no sudo and its packages are baked in, so every step
#    that apt-installs, sudo-writes or re-installs a tool the guest already
#    carries runs on a GitHub-hosted runner only. An ungated step fails every
#    routed shard, and fail-fast then blocks the operator's PRs.
step_block() { # <exact step name> -> every step block with that name
    awk -v n="      - name: $1" '
        /^      - / { f = (index($0, n) == 1) }
        f' <<< "$blk"
}
for s in 'Record runner image (apt cache key)' 'Cache apt debs (at/atd)' \
         'Install + enable at/atd (Linux' 'Allow unprivileged user namespaces' \
         'Cache apt debs (ffmpeg)' 'Install pinned ffmpeg' 'Install pre-commit'; do
    sb="$(step_block "$s")"
    if [ -z "$sb" ]; then bad "step '$s' not found in shell-unit-shard"; continue; fi
    n_if="$(grep -cE '^[[:space:]]+if:' <<< "$sb")"
    n_gate="$(grep -cE "^[[:space:]]+if:.*runner\.environment == 'github-hosted'" <<< "$sb")"
    if [ "$n_if" -ge 1 ] && [ "$n_if" -eq "$n_gate" ]; then ok "step '$s' is gated on runner.environment == 'github-hosted'"; else bad "step '$s' is not gated on runner.environment == 'github-hosted' ($n_gate of $n_if)"; fi
done

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
