#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-run-shell-tests-ledger-fresh.sh -- Case 22-fresh, the committed ledger balances measured shard time.
#
# Split from scripts/ci/test-run-shell-tests.sh so no CI shard is bounded by one
# runner self-test file: the sharder parallelises across FILES. Siblings: test-run-shell-tests.sh (Cases 1-25) and test-run-shell-tests-retry.sh (Cases 26-34).
# Shared fixtures (grepq, pass/fail, the sandboxed lock) are in run-shell-tests-fixture.sh.
#
# Usage: bash scripts/ci/test-run-shell-tests-ledger-fresh.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# run_lines <runner --list output> -- the suite paths on its [RUN ] lines (the
# same one-liner test-run-shell-tests.sh defines for Cases 22 onward).
run_lines() { grep -F '[RUN ] ' <<< "$1" | sed 's/^\[RUN \] //'; }

# Case 22-fresh — the COMMITTED ledger keeps the real shard split balanced.
#
# 22i..22m pin the packing algorithm against synthetic ledgers; none of them
# can notice the committed ledger going stale, which is how the real split
# drifted to a 2800s slowest shard against a 2304s floor. The
# fixture below is copied from the real CI logs of green main run 41928036090
# (head 11b19d623ec945b58496257457804e390f5cecaa, the first full run after the
# run-shell-tests and uninstall-provenance split, shell-unit-shard 1..8): every suite
# that ran >= 10s, with its measured seconds.
# The sandbox holds a stub for each, the runner packs them with the
# committed ledger, and the measured seconds of each shard are summed.
# The slowest shard cannot beat the heaviest single suite, so the bound is that
# floor plus 5%.
echo "== Case 22-fresh (HIMMEL-4075): the committed ledger balances measured shard time =="
sb22w=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22w.XXXXXX") || { fail "22w: mktemp failed"; sb22w=""; }
if [ -n "$sb22w" ]; then
fix22w="$sb22w/measured.tsv"
cat > "$fix22w" <<'FIXEOF'
marketplace/plugins/himmel-ops/hooks/test-block-agent-native-egress.sh	18
marketplace/plugins/obsidian-triage/tests/test-fxtwitter-enrich.sh	90
marketplace/plugins/obsidian-triage/tests/test-ig-media-enrich.sh	16
marketplace/plugins/obsidian-triage/tests/test-requirements-resolve-ci-mode.sh	15
marketplace/plugins/obsidian-triage/tests/test-yt-scrapling.sh	33
marketplace/plugins/telegram-himmel/tests/test-telegram-poller-gate.sh	11
scripts/afk/test-self-heal.sh	16
scripts/api-lane/test-claude-api.sh	72
scripts/chief/test-base-status.sh	21
scripts/ci/test-billed-optin.sh	32
scripts/ci/test-check-ci-install-locks.sh	50
scripts/ci/test-check-critic-eval.sh	11
scripts/ci/test-check-flags.sh	28
scripts/ci/test-ci-lint-tree-gates.sh	38
scripts/ci/test-home-canary.sh	34
scripts/ci/test-impacted-selection.sh	27
scripts/ci/test-knockout-gate.sh	15
scripts/ci/test-queue-latency.sh	16
scripts/ci/test-run-shell-tests-discovery.sh	23
scripts/ci/test-run-shell-tests-flake.sh	22
scripts/ci/test-run-shell-tests-impacted.sh	17
scripts/ci/test-run-shell-tests-ledger-fresh.sh	207
scripts/ci/test-run-shell-tests-parallel.sh	74
scripts/ci/test-run-shell-tests-retry.sh	61
scripts/ci/test-run-shell-tests-rotation-cursor.sh	14
scripts/ci/test-run-shell-tests-rotation-guards.sh	13
scripts/ci/test-run-shell-tests-rotation.sh	15
scripts/ci/test-run-shell-tests-timing.sh	81
scripts/ci/test-run-shell-tests.sh	78
scripts/ci/test-suite-concurrency.sh	155
scripts/ci/test-suite-lock-brand-gap.sh	70
scripts/ci/test-suite-lock-orphan-reaper.sh	16
scripts/ci/test-suite-tiers.sh	36
scripts/ci/test-tier-replay.sh	100
scripts/cloud/test-parity-probe.sh	11
scripts/codex/test-dispatch-codex-exec.sh	90
scripts/codex/test-hook-smoke-demo.sh	12
scripts/cr/test-claude-floor-review.sh	16
scripts/cr/test-clear-cr-marker.sh	218
scripts/cr/test-cr-guarded-closure.sh	10
scripts/cr/test-critic-first-pass-claude.sh	47
scripts/cr/test-critic-first-pass.sh	41
scripts/cr/test-critic-panel-fallback.sh	23
scripts/cr/test-critic-panel.sh	74
scripts/cr/test-dependabot-go.sh	10
scripts/cr/test-finding-reraise.sh	42
scripts/cr/test-impacted-suites.sh	69
scripts/cr/test-ledger-append.sh	24
scripts/cr/test-panel-first-pass.sh	13
scripts/cr/test-pr-check-context.sh	100
scripts/docs/test-dev-graph.sh	10
scripts/docs/test-docs-dropped-terms.sh	10
scripts/eval/compaction-handoff/test-compaction-ab.sh	20
scripts/eval/graphify-ab/test-graphify-ab.sh	12
scripts/eval/guard-corpus/test-guard-corpus.sh	76
scripts/eval/lane-quality/pilot-4869/test-pilot.sh	102
scripts/eval/lane-quality/test-lane-quality-calibration.sh	40
scripts/eval/lane-quality/test-lane-quality.sh	56
scripts/eval/lane-quality/test-trajectory.sh	10
scripts/eval/mcp-tasks-probe/test-probe.sh	10
scripts/eval/qmd-quality/test-qmd-burst-proof.sh	10
scripts/eval/relay-cost/test-relay-cost.sh	18
scripts/eval/retrieval-eval/test-retrieval-eval.sh	12
scripts/eval/review-panel/test-review-panel.sh	1295
scripts/eval/routing/test-score.sh	24
scripts/eval/steering-cull/test-steering-cull.sh	16
scripts/eval/test-eval-runs.sh	12
scripts/eval/worker-digest/test-worker-ledger.sh	12
scripts/graphify/test-graph-cadence.sh	66
scripts/graphify/test-refresh-graph-map-lock.sh	104
scripts/graphify/test-refresh-graph-map-resume.sh	24
scripts/graphify/test-refresh-graph-map.sh	119
scripts/graphify/test-semantic-update.sh	64
scripts/guardrails/test-check-git-env-scrub.sh	36
scripts/guardrails/test-graphify-fence.sh	53
scripts/guardrails/test-hook-probe.sh	10
scripts/guardrails/test-lesson-write-fence.sh	191
scripts/handover/chief-kit/test-append-results.sh	52
scripts/handover/chief-kit/test-auto-go.sh	219
scripts/handover/chief-kit/test-board.sh	90
scripts/handover/chief-kit/test-brief-lint.sh	52
scripts/handover/chief-kit/test-chief-kit-e2e.sh	45
scripts/handover/chief-kit/test-chief-wait-b.sh	533
scripts/handover/chief-kit/test-chief-wait-pool.sh	168
scripts/handover/chief-kit/test-chief-wait-r0.sh	201
scripts/handover/chief-kit/test-chief-wait.sh	353
scripts/handover/chief-kit/test-close-wrapped-worker.sh	51
scripts/handover/chief-kit/test-cr-disposition.sh	25
scripts/handover/chief-kit/test-doc-reader-agreement.sh	156
scripts/handover/chief-kit/test-fleet.sh	18
scripts/handover/chief-kit/test-gen-briefs.sh	49
scripts/handover/chief-kit/test-go.sh	77
scripts/handover/chief-kit/test-grant-round.sh	14
scripts/handover/chief-kit/test-handover-token-grammar.sh	25
scripts/handover/chief-kit/test-headed-arm-worker-env.sh	16
scripts/handover/chief-kit/test-headed-arm-worker.sh	279
scripts/handover/chief-kit/test-holds.sh	34
scripts/handover/chief-kit/test-judge-ladder.sh	11
scripts/handover/chief-kit/test-live-state.sh	23
scripts/handover/chief-kit/test-next-dispatchable.sh	130
scripts/handover/chief-kit/test-orphan-pr-check.sh	14
scripts/handover/chief-kit/test-ready-check.sh	368
scripts/handover/chief-kit/test-ready-go.sh	11
scripts/handover/chief-kit/test-relay-batch.sh	33
scripts/handover/chief-kit/test-series-next.sh	24
scripts/handover/chief-kit/test-series-publish.sh	22
scripts/handover/chief-kit/test-status-drift.sh	94
scripts/handover/chief-kit/test-tick-busedge.sh	11
scripts/handover/chief-kit/test-tick-deadwin.sh	10
scripts/handover/chief-kit/test-tick-fields.sh	289
scripts/handover/chief-kit/test-tick-nolive.sh	17
scripts/handover/chief-kit/test-tick-repair.sh	89
scripts/handover/chief-kit/test-tick-rmqueue.sh	25
scripts/handover/chief-kit/test-tick.sh	264
scripts/handover/chief-kit/test-tracker.sh	18
scripts/handover/chief-kit/test-worker-doc-lock.sh	13
scripts/handover/chief-kit/test-worker-event.sh	10
scripts/handover/chief-kit/test-worker-jira-status.sh	52
scripts/handover/chief-kit/test-worker-pretrust.sh	90
scripts/handover/chief-kit/test-wrap-merged.sh	67
scripts/handover/chief-kit/test-write-verdict.sh	43
scripts/handover/chief/test-chief-handoff-roundtrip.sh	11
scripts/handover/chief/test-chief.sh	249
scripts/handover/test-arm-resume-1879.sh	388
scripts/handover/test-arm-resume-bus-rebind.sh	19
scripts/handover/test-arm-resume-context.sh	27
scripts/handover/test-arm-resume-cron.sh	22
scripts/handover/test-arm-resume-fast.sh	233
scripts/handover/test-arm-resume-identity.sh	35
scripts/handover/test-arm-resume-proxy.sh	16
scripts/handover/test-arm-resume-queue-lock.sh	56
scripts/handover/test-bus-idle-waker.sh	57
scripts/handover/test-generate-morning-briefing.sh	28
scripts/handover/test-handover-root-dotenv.sh	13
scripts/handover/test-headed-arm-tabs.sh	27
scripts/handover/test-headed-arm.sh	185
scripts/handover/test-konsole-macos.sh	22
scripts/handover/test-merge-fork-pr.sh	15
scripts/handover/test-merge-forward-check.sh	12
scripts/handover/test-merge-on-green-jira-end-state.sh	14
scripts/handover/test-merge-on-green-static-recheck.sh	31
scripts/handover/test-merge-on-green.sh	254
scripts/handover/test-pr-merge.sh	20
scripts/handover/test-queue-lock.sh	120
scripts/handover/test-register-state.sh	11
scripts/handover/test-worker-lifecycle.sh	11
scripts/hermes/test-parity-guard.sh	57
scripts/hermes/test-parity-measure.sh	20
scripts/himmelctl/test/test-luna-config-migration.sh	10
scripts/himmelctl/test/test-versioned-layout.sh	38
scripts/himmelctl/test/test-wizard-adopter-profile.sh	35
scripts/himmelctl/test/test-wizard-config.sh	14
scripts/himmelctl/test/test-wizard-derive.sh	12
scripts/himmelctl/test/test-wizard-luna-sections.sh	23
scripts/himmelctl/test/test-wizard-probes.sh	53
scripts/himmelctl/test/test-wizard-save-profile.sh	247
scripts/himmelctl/test/test-wizard-statusreport.sh	21
scripts/himmelctl/test/test-wizard-vm-mode.sh	13
scripts/hooks/test-auto-approve-safe-bash.sh	67
scripts/hooks/test-auto-arm-on-cap.sh	13
scripts/hooks/test-block-bank-lift-writes.sh	12
scripts/hooks/test-block-bare-qmd-query.sh	132
scripts/hooks/test-block-chokepoint-env-prefix.sh	183
scripts/hooks/test-block-destructive-commands-a.sh	71
scripts/hooks/test-block-destructive-commands-b.sh	78
scripts/hooks/test-block-destructive-commands-c.sh	52
scripts/hooks/test-block-destructive-commands-d.sh	116
scripts/hooks/test-block-docker-privesc.sh	23
scripts/hooks/test-block-edit-live-settings.sh	200
scripts/hooks/test-block-git-stash.sh	16
scripts/hooks/test-block-graphify-egress.sh	25
scripts/hooks/test-block-himmel-config-writes.sh	17
scripts/hooks/test-block-jira-compound-write.sh	25
scripts/hooks/test-block-primary-git-writes.sh	345
scripts/hooks/test-block-read-secrets.sh	107
scripts/hooks/test-block-tail-pipe-on-gates.sh	31
scripts/hooks/test-block-terminal-write-fence.sh	10
scripts/hooks/test-block-unresolved-cr-merge.sh	443
scripts/hooks/test-block-vault-sweep.sh	14
scripts/hooks/test-block-worker-write-fence.sh	20
scripts/hooks/test-block-write-into-main-checkout-adopted.sh	18
scripts/hooks/test-block-write-into-main-checkout-cd.sh	97
scripts/hooks/test-block-write-into-main-checkout-evaldata.sh	197
scripts/hooks/test-block-write-into-main-checkout-heredoc.sh	89
scripts/hooks/test-block-write-into-main-checkout-matrix1.sh	197
scripts/hooks/test-block-write-into-main-checkout-matrix2.sh	221
scripts/hooks/test-block-write-into-main-checkout-matrix3.sh	146
scripts/hooks/test-block-write-into-main-checkout-wrappers.sh	78
scripts/hooks/test-block-write-into-main-checkout.sh	237
scripts/hooks/test-bus-deliver-hook.sh	20
scripts/hooks/test-cadence-approve-engines.sh	18
scripts/hooks/test-check-cr-before-push.sh	16
scripts/hooks/test-check-hook-file-parse.sh	14
scripts/hooks/test-ci-doc-invariants.sh	17
scripts/hooks/test-crlf-boundary.sh	39
scripts/hooks/test-end-session-wiki.sh	41
scripts/hooks/test-escape-class-corpus.sh	57
scripts/hooks/test-fork-precommit-core.sh	62
scripts/hooks/test-guard-bus-store.sh	17
scripts/hooks/test-guard-empty-expansion.sh	16
scripts/hooks/test-guard-implementor-dispatch.sh	237
scripts/hooks/test-guard-pr-check-literal.sh	97
scripts/hooks/test-guard-relay-writes.sh	10
scripts/hooks/test-guard-worker-context-handoff.sh	24
scripts/hooks/test-hook-chain-latency.sh	134
scripts/hooks/test-hook-construct-scaling.sh	90
scripts/hooks/test-hook-rewrite-integrity.sh	18
scripts/hooks/test-log-classifier-denial.sh	10
scripts/hooks/test-qmd-staleness-notice.sh	42
scripts/hooks/test-refresh-where-are-we-on-end.sh	14
scripts/hooks/test-run-hook-with-bash-unroll.sh	25
scripts/hooks/test-session-end-timeout-budget.sh	12
scripts/hooks/test-stop-chief-idle-guard.sh	15
scripts/hooks/test-telegram-session-end.sh	13
scripts/lanes/test-lane-canary.sh	15
scripts/lanes/test-worker-pr-open.sh	19
scripts/lanes/tests/test-stop-worker.sh	20
scripts/lib/test-afk-sudo.sh	86
scripts/lib/test-api-credit-state.sh	11
scripts/lib/test-bank-monitor.sh	11
scripts/lib/test-bank-preflight-fleet.sh	23
scripts/lib/test-bank-preflight.sh	91
scripts/lib/test-claude-headless-trap.sh	17
scripts/lib/test-claude-headless.sh	54
scripts/lib/test-config-audit.sh	12
scripts/lib/test-cr-first-release.sh	27
scripts/lib/test-cr-merge-gate.sh	38
scripts/lib/test-fixture-trap-clean.sh	71
scripts/lib/test-go-gate.sh	22
scripts/lib/test-graphify-bin.sh	23
scripts/lib/test-provenance-read.sh	21
scripts/lib/test-qmd-bin.sh	14
scripts/lib/test-qmd-bounded.sh	20
scripts/lib/test-red-control-lint.sh	10
scripts/lib/test-sandbox-run.sh	11
scripts/lib/test-suite-semaphore.sh	11
scripts/lib/test-timeout-bin.sh	13
scripts/lib/test-watch-loop.sh	13
scripts/lib/test-wire-pretooluse-hooks.sh	14
scripts/lib/test-wire-statusline.sh	31
scripts/lint/test-shell-lint.sh	23
scripts/luna/test-graphmap-cadence.sh	32
scripts/luna/test-qmd-cadence.sh	11
scripts/luna/test-qmd-reindex.sh	44
scripts/luna/test-vault-stall-cadence.sh	52
scripts/machine-setup/test-install-plugins-ondemand.sh	21
scripts/machine-setup/test-install-plugins-provenance.sh	33
scripts/machine-setup/test-machine-setup-hermetic.sh	17
scripts/observability/test-tool-call-census.sh	11
scripts/parity/test-t13b-daemon-prose.sh	12
scripts/qmd/test-ensure-qmd-daemon-leak.sh	11
scripts/qmd/test-ensure-qmd-daemon.sh	49
scripts/qmd/test-qmd-jina-gate.sh	23
scripts/setup/test-migrate-env.sh	252
scripts/station-ops/test-station-ops.sh	18
scripts/statusline/test-hud-composer-parity.sh	11
scripts/statusline/test-usage-cache-producer.sh	22
scripts/telegram/test-dispatch-lane.sh	39
scripts/telegram/test-restart-bridge.sh	65
scripts/test-adopt-features.sh	302
scripts/test-adopt-hooks-chain.sh	520
scripts/test-adopt-hooks-gates.sh	92
scripts/test-adopt-merge-gate.sh	110
scripts/test-adopt-provenance.sh	195
scripts/test-adopt-sequences.sh	580
scripts/test-adopt-wizard.sh	311
scripts/test-check-ci-cache.sh	24
scripts/test-check-ci-run.sh	22
scripts/test-check-ci.sh	145
scripts/test-check-plugin-drift.sh	75
scripts/test-claude-codex.sh	23
scripts/test-claude-openrouter.sh	21
scripts/test-clean-garden-accounting.sh	15
scripts/test-doctor-cadence.sh	13
scripts/test-e2e-provenance-settings.sh	14
scripts/test-e2e-symmetry-isolation.sh	17
scripts/test-e2e-symmetry.sh	10
scripts/test-himmel-doctor.sh	766
scripts/test-himmel-update-axis-b.sh	14
scripts/test-himmel-update-check.sh	19
scripts/test-himmel-update-clis.sh	10
scripts/test-himmel-update-migrations.sh	14
scripts/test-himmel-update-plugin-update.sh	11
scripts/test-himmel-update-versions.sh	11
scripts/test-lane-mirror-seed.sh	74
scripts/test-luna-upgrade-all.sh	26
scripts/test-quiet-run.sh	34
scripts/test-real-state-guard.sh	33
scripts/test-template-nostash-hooks.sh	70
scripts/test-tmp-reap.sh	51
scripts/test-uninstall-plugins.sh	16
scripts/test-uninstall-provenance-legacy.sh	150
scripts/test-uninstall-provenance-qmd.sh	193
scripts/test-uninstall-provenance-tty-block.sh	217
scripts/test-uninstall-provenance.sh	207
scripts/test-uninstall-real-home-callers.sh	71
scripts/test-uninstall-real-home-runtime.sh	199
scripts/test-uninstall-routines.sh	107
scripts/test-uninstall-standalone.sh	248
scripts/test-uninstall-ux.sh	113
scripts/test-uninstall.sh	567
scripts/test-worktree-orphans.sh	24
scripts/test-worktree-verbs.sh	17
scripts/testing/test-documented-commands.sh	115
scripts/upstreams/test-upstream-watch.sh	17
scripts/usage/test-usage.sh	20
scripts/vm/test-adopted-features-stage.sh	32
scripts/vm/test-after-report.sh	28
scripts/vm/test-assert-provenance.sh	19
scripts/vm/test-ci-runner.sh	11
scripts/vm/test-claudex-guest.sh	12
scripts/vm/test-dry-run-restore.sh	10
scripts/vm/test-provenance-roundtrip-dry.sh	68
scripts/vm/test-vm-lock.sh	23
templates/luna-second-brain/scripts/test-upgrade.sh	72
templates/luna-second-brain/scripts/test-vault-autosync-stall.sh	10
templates/luna-second-brain/scripts/test-vault-git.sh	60
FIXEOF
while IFS=$'\t' read -r _p _s; do
  mkdir -p "$sb22w/stubs/$(dirname "$_p")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb22w/stubs/$_p"
  chmod +x "$sb22w/stubs/$_p"
done < "$fix22w"
# The runner keys the ledger by the path it prints, which for a scan root other
# than `.` is "<root>/<suite>"; re-root the committed ledger's keys the same way.
awk -F'\t' -v r="$sb22w/stubs/" '/^[[:space:]]*#/ { next } { print r $1 "\t" $2 }' \
  "$RST_FIXTURE_DIR/suite-durations.tsv" > "$sb22w/ledger.tsv"
fakebin22w=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22w-fakebin.XXXXXX") || { fail "22w: fakebin mktemp failed"; fakebin22w=""; }
if [ -n "$fakebin22w" ]; then
printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin22w/uname"
# Darwin refuses to list the sandboxed corpus suites without sandbox-exec.
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin22w/sandbox-exec"
chmod +x "$fakebin22w/uname" "$fakebin22w/sandbox-exec"
fi
nfix22w=$(grep -c . "$fix22w")
# SKIP_LIST suites are kept out of the plan on purpose, so a fixture row named
# there is expected unplaced: count those out of the expectation.
skip22w=$(awk '/^SKIP_LIST="$/{f=1; next} f && /^"$/{exit} f && /^scripts\//{print $1}' "$RUNNER")
nonlinux22w=$(awk '/^SKIP_LIST_NON_LINUX="$/{f=1; next} f && /^"$/{exit} f && /^scripts\//{print $1}' "$RUNNER")
# The real pass uses the host's own uname; the Darwin pass stubs it so every
# host covers the off-Linux plan. Darwin+notool also gives a fixture suite a
# required tool the host lacks: on a real macOS runner flock is absent, so
# test-worker-doc-lock.sh is a capability [SKIP] there (run 41010394001) and is
# expected unplaced, which no Linux host would otherwise show.
for os22w in "" Darwin Darwin+notool Linux+notool; do
# Both +notool passes inject a tool a Linux host has but a macOS host lacks. On a
# real macOS runner flock is already absent, so its real and Darwin passes show
# the tool-absent case themselves; replaying it there only spends the suite's cap.
case "$os22w" in *+notool) [ "$(uname -s)" = "Linux" ] || continue ;; esac
tot22w=0; max22w=0; slow22w=0; n22w=0; rc22w=0; capl22w=""
_pass22w="${os22w:-$(uname -s)}"
_uname22w="${_pass22w%%+*}"
_req22w=""
[ "${os22w%+notool}" = "$os22w" ] || _req22w="scripts/handover/chief-kit/test-worker-doc-lock.sh  no-such-tool-22w  # HIMMEL-8148: a required tool the host lacks"
_skips22w="$skip22w"
[ "$_uname22w" = "Linux" ] || _skips22w="$skip22w
$nonlinux22w"
nskip22w=$(S22W="$_skips22w" awk -F'\t' 'BEGIN{n=split(ENVIRON["S22W"],a,"\n"); for(i=1;i<=n;i++) k[a[i]]=1} ($1 in k){c++} END{print c+0}' "$fix22w")
nexp22w=$((nfix22w - nskip22w))
_path22w="$PATH"; [ "${os22w%%+*}" != "Darwin" ] || _path22w="$fakebin22w:$PATH"
for _i in 1 2 3 4 5 6 7 8; do
  _out=$(HIMMEL_RUNTIME_PREFLIGHT=0 PATH="$_path22w" SUITE_DURATIONS="$sb22w/ledger.tsv" SUITE_REQUIRE_TOOL="$_req22w" bash "$RUNNER" --list --shard "$_i/8" "$sb22w/stubs" 2>&1) || rc22w=$((rc22w + 1))
  capl22w="$capl22w$_out
"
  _t=0
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _s=$(awk -F'\t' -v k="${_p#"$sb22w"/stubs/}" '$1 == k { print $2 + 0; exit }' "$fix22w")
    _t=$(( _t + ${_s:-0} ))
    [ -n "$_s" ] && n22w=$((n22w + 1))
    [ "${_s:-0}" -gt "$max22w" ] && max22w=${_s:-0}
  done <<< "$(run_lines "$_out")"
  tot22w=$((tot22w + _t))
  [ "$_t" -gt "$slow22w" ] && slow22w=$_t
done
# A fixture suite the runner loud-[SKIP]s as "capability: <tool> not on PATH" is
# expected unplaced, but only when the tool is really absent from this pass's
# PATH: a skip the host's tools do not explain still counts as dropped. Linux is
# never excused: it is the gate, so a required tool going missing there must
# leave the suite short and turn 22w red.
ncap22w=0
while IFS= read -r _l; do
  _l="${_l#"[SKIP] $sb22w/stubs/"}"
  _p="${_l%% — capability: *}"
  _tool="${_l#* — capability: }"; _tool="${_tool%% not on PATH*}"
  awk -F'\t' -v k="$_p" '$1 == k { f = 1 } END { exit !f }' "$fix22w" || continue
  grep -qxF "$_p" <<< "$_skips22w" && continue
  # shellcheck disable=SC2030
  ( PATH="$_path22w"; command -v "$_tool" >/dev/null 2>&1 ) && continue
  ncap22w=$((ncap22w + 1))
done <<< "$(grep -F "[SKIP] $sb22w/stubs/" <<< "$capl22w" | grep -F ' — capability: ' | sort -u)"
[ "$_uname22w" = "Linux" ] || nexp22w=$((nexp22w - ncap22w))
floor22w=$(( tot22w / 8 )); [ "$max22w" -gt "$floor22w" ] && floor22w=$max22w
bound22w=$(( floor22w * 105 / 100 ))
# A +notool pass must see its one injected suite skipped, or it proves nothing.
# Linux+notool is the negative control: a tool-absent skip on Linux is NOT
# subtracted, so the suite comes up one short, which is what makes 22w red there.
want22w=$nexp22w; [ "$os22w" != "Linux+notool" ] || want22w=$((nexp22w - 1))
if [ "$rc22w" -eq 0 ] && [ "$n22w" -eq "$want22w" ] && [ "$slow22w" -le "$bound22w" ] \
   && { [ "${os22w%+notool}" = "$os22w" ] || [ "$ncap22w" -eq 1 ]; }; then
  pass "22w (uname=$_pass22w): slowest measured shard ${slow22w}s is within 5% of the ${floor22w}s floor ($n22w suites, $nskip22w skip-listed, $ncap22w tool-absent)"
else
  fail "22w (uname=$_pass22w): slowest measured shard ${slow22w}s vs bound ${bound22w}s (floor ${floor22w}s), $n22w of $nexp22w expected suites placed ($nskip22w skip-listed, $ncap22w tool-absent), $rc22w failed shard listings: refresh scripts/ci/suite-durations.tsv if the ledger is stale"
fi
done
rm -rf "$sb22w" "$fakebin22w"
fi


rst_tally
