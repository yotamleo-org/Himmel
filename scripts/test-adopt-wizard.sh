#!/usr/bin/env bash
# test-adopt-wizard.sh — the himmelctl wizard and machine-setup shim suites.
# The adopt.sh smoke tests live in several suites so
# each stays well under the runner's per-suite time cap. Same fixture
# (scripts/lib/adopt-test-fixture.sh): stubs `claude` on PATH, throwaway temp
# dirs, a fake HOME.
#
# Runs the himmelctl wizard and machine-setup shim suites under the real PATH,
# split from scripts/test-adopt-features.sh.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# ── 20. himmelctl wizard + machine-setup shim suites ──────────
# A plain `bash scripts/test-adopt-wizard.sh` run exercises the himmelctl install
# wizard + the T7/T8 bootstrap/deprecation-shim suites, so a regression in any
# of them fails THIS harness, not just the CI shell-test sweep. Each suite runs
# as a self-contained `bash <script>` subprocess (own `set -e` + trap + temp
# dir), isolating it from this script's hermetic PATH scrub. That scrub dropped
# node/npm/bun suite-wide for the adopt.sh scenarios above; the wizard suites
# shell out to bin.js and need a REAL node, so each is invoked with `saved_path`
# (the pre-scrub environment PATH captured above).
#
# run_wizard_suite <relpath-under-scripts/> <label> — run one suite under the
# real PATH; tail its log + fail on non-zero (cleans up via this script's trap).
run_wizard_suite() {
  local _rel="$1" _label="$2" _path
  _path="$repo_root/scripts/$_rel"
  [ -f "$_path" ] || fail "wizard suite not found: $_path"
  set +e
  PATH="$saved_path" bash "$_path" >"$work/wizard-suite.log" 2>&1
  local _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    tail -20 "$work/wizard-suite.log" >&2
    fail "wizard suite failed (rc=$_rc): $_label"
  fi
  echo "ok: wizard suite green: $_label"
}

run_wizard_suite himmelctl/test/test-wizard-preflight.sh       "test-wizard-preflight"
run_wizard_suite himmelctl/test/test-wizard-questions.sh       "test-wizard-questions"
run_wizard_suite himmelctl/test/test-wizard-derive.sh          "test-wizard-derive"
run_wizard_suite himmelctl/test/test-wizard-uninstall.sh       "test-wizard-uninstall"
run_wizard_suite himmelctl/test/test-wizard-uninstall-converge.sh "test-wizard-uninstall-converge"
run_wizard_suite himmelctl/test/test-wizard-noinstall-guard.sh "test-wizard-noinstall-guard"
run_wizard_suite himmelctl/test/test-wizard-bootstrap.sh       "test-wizard-bootstrap"
run_wizard_suite himmelctl/test/test-wizard-state.sh           "test-wizard-state"
run_wizard_suite himmelctl/test/test-wizard-probes.sh          "test-wizard-probes"
run_wizard_suite himmelctl/test/test-wizard-status-cmd.sh      "test-wizard-status-cmd"
run_wizard_suite himmelctl/test/test-wizard-status-golden.sh   "test-wizard-status-golden"
run_wizard_suite himmelctl/test/test-wizard-status-multitarget.sh "test-wizard-status-multitarget"
run_wizard_suite himmelctl/test/test-wizard-manifest-v2.sh     "test-wizard-manifest-v2"
run_wizard_suite himmelctl/test/test-wizard-himmel-clone-target.sh "test-wizard-himmel-clone-target"
run_wizard_suite himmelctl/test/test-wizard-statusreport.sh    "test-wizard-statusreport"
run_wizard_suite himmelctl/test/test-wizard-reconcile.sh       "test-wizard-reconcile"
run_wizard_suite himmelctl/test/test-wizard-install-engine.sh  "test-wizard-install-engine"
run_wizard_suite himmelctl/test/test-wizard-ensure.sh          "test-wizard-ensure"
run_wizard_suite himmelctl/test/test-wizard-ensure-disable.sh  "test-wizard-ensure-disable"
run_wizard_suite himmelctl/test/test-wizard-scope-switch.sh    "test-wizard-scope-switch"
run_wizard_suite himmelctl/test/test-wizard-option-validation.sh "test-wizard-option-validation"
run_wizard_suite himmelctl/test/test-wizard-config.sh          "test-wizard-config"
run_wizard_suite himmelctl/test/test-wizard-deps.sh             "test-wizard-deps"
run_wizard_suite himmelctl/test/test-wizard-deps-lint.sh        "test-wizard-deps-lint"
run_wizard_suite machine-setup/test-ubuntu-shim.sh             "test-ubuntu-shim"

echo "PASS"
