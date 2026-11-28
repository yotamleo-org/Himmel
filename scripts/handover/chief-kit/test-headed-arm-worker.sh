#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2154  # SC2015: A && B || C is intentional in check()/contains()/ends_with()/not_contains(), as in scripts/handover/test-headed-arm.sh; the rest: assigned in the sourced testlib
# scripts/handover/chief-kit/test-headed-arm-worker.sh - suite for
# headed-arm-worker.sh: the versioned WORKER launcher that
# pins the standard --autocompact 200000 ceiling. WORKER_SESSION_CONTEXT=1m is refused:
# absence of a [1m] suffix is not proof of the ceiling, because autocompact is
# the cost-driving argv lever.
#
# The suite runs as four parts so that no CI shard is bounded by one file. Each part is a suite of its own and sources
# tests/testlib-headed-arm-worker.sh (the helpers, the launch stubs and the fixtures more than one part reads):
#   test-headed-arm-worker.sh    this file: the fleet rows and sections 1 to 28 (dry-run argv, full launches, lanes,
#                                profiles, tiers, MCP allowlist, the launch record)
#   test-headed-arm-worker-b.sh  sections 29 to 41 (--headless, launcher-env, effort, re-dispatch refusal, resume_cwd
#                                inside the handover root, the consult mode)
#   test-headed-arm-worker-c.sh  sections 42 to 53 and 17r (worktree resume_cwd, pre-trust, bus, waker, memory cap, registered
#                                repos, Remote Control, single-writer, hook-loading guard, the launch-refusal ledger,
#                                the readiness launcher render)
#   test-headed-arm-worker-d.sh  section 17s (the readiness launch)
#
# Asserts:
#   1-2. usage/arg-shape: too few args -> exit 2, with and without --dry-run.
#   3-6. --dry-run argv: default standard succeeds; WORKER_SESSION_CONTEXT=1m is refused
#        for ordinary and Fable-family models; off-values (e.g. "standard" or
#        a typo) stay on the cheaper, already-correct standard ceiling.
#   6c. --judge forces --profile console-judge,
#       defaults MODEL to claude-opus-5-5 at high effort on the native lane
#       only, withholds IMPL_GUARD_OK/INLINE_IMPL_OK, raises
#       HIMMEL_READ_CLAMP_LINES, and switches the preface source to
#       docs/handover/judge-preface.md; conflicts with a mismatched --profile
#       or with --relay the same way --relay itself does. An explicit
#       claude-fable-5-1 model still hits the tier gate unchanged.
#   7. --dry-run reports WORKER_SESSION_REPO folded into HEADED_ARM_REPO.
#   8-9. full (non-dry) launch via the same KONSOLE_CMD/PGREP_CMD/
#        HEADED_ARM_PROC seams headed-arm.sh's own suite uses (the wrapper
#        execs the real headed-arm.sh, so this proves the non-dry path carries
#        --autocompact 200000); WORKER_SESSION_CONTEXT=1m refuses before headed-arm runs.
#   10. IMPL_GUARD_OK=1, INLINE_IMPL_OK=1 and HIMMEL_CONSOLE_LEG=1 (#       the marker merge-on-green's chief-GO gate keys on) reach konsole's
#       own process environment (the worker-only env headed-arm.sh's child-env
#       block does not set).
#   11. WORKER_SESSION_REPO reaches headed-arm.sh's --workdir.
#   3b/10b: CHIEF_CONTEXT is a chief-only knob (the
#       CHIEF_CONTEXT=1m 1M-context opt-in, chief.sh:382) that must never
#       reach a worker - --dry-run reports the enumerated scrub set and the
#       resolved value as <unset> even with CHIEF_CONTEXT=1m ambient in the
#       launching shell (3b); the real (non-dry) path proves it never reaches
#       the konsole child's own process environment either (10b).
#   12. RED control: a mutant headed-arm renderer with --autocompact removed is
#       refused on the full non-dry launch path before konsole runs.
#   13. usage-preflight.sh reporting SKIPPED-FLEET refuses the
#       launch (rc<>0, headed-arm.sh never invoked) - the launcher-side half
#       of the fleet-size cap; scripts/lib/test-bank-preflight.sh covers the
#       preflight's own fleet-counting logic.
#   24. FLEET_RESERVE_TTL is exported to the preflight call,
#       derived from this worker's own DEADLINE (positional $4) - a future
#       deadline reaches the preflight as (deadline - now); a past/near
#       deadline floors to 60.
#   25. on SKIPPED-BANK (reachable only AFTER usage-preflight.sh's
#       admission already created this worker's reservation), headed-arm-worker.sh
#       releases it. On SKIPPED-FLEET (never holds a reservation of its own -
#       see usage-preflight.sh's own refusal sub-paths), a same-name
#       reservation directory (belonging to a DIFFERENT still-pending arm in
#       the duplicate-name case) is left untouched.
#   26. when HANDOVER_DIR is unset, the wrapper resolves the
#       CHIEF's own handover root (its own process/cwd, before any konsole
#       child exists) and exports it explicitly into the worker's launch env -
#       reaches konsole's own process environment (mirrors case 10's shape),
#       and an end-to-end check: a GO written by go.sh from that SAME
#       chief-like cwd, then go_gate resolved from a DIFFERENT cwd
#       (simulating the worker's linked worktree) using ONLY the exported
#       HANDOVER_DIR, finds it.
#   28. a REAL launch (never --dry-run) appends one metadata line
#       to <himmelctl-cache>/launch-logs/<session>.log - profile / lane /
#       model / role / session / launched, no env values - and a write failure
#       or an unresolvable cache dir never blocks the launch.
#   36. a sanctioned operator ruling opens a worker-level 1M opt-in -
#       accepted ONLY when the brief carries a well-formed
#       `> **Context:** 1m — operator-ruling: <reason>` line (mirrors the
#       Tier-line gate, case 6c's fixture-doc shape); stays refused for no
#       line, an empty reason, or a malformed line (wrong dash, wrong mode,
#       missing marker). On acceptance: dry-run reports context=1m
#       (operator-ruling) and CHIEF_CONTEXT=1m (proving the same-process
#       export ran before this wrapper execs into headed-arm.sh, whose own
#       gate this satisfies without editing that read-only file); a direct
#       invocation of headed-arm.sh's own --dry-run with the same env proves
#       the accepted argv actually carries --autocompact auto and [1m]; the
#       full non-dry launch reaches konsole with HEADED_ARM_REQUIRED_AUTOCOMPACT
#       resolved to auto (never leaking into the launched worker's own env,
#       same non-leak shape as case 10) and CHIEF_CONTEXT=1m recorded, and
#       the arm log records context=1m (operator-ruling).
#
# Platform guard: POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/testlib-headed-arm-worker.sh
. "$HERE/tests/testlib-headed-arm-worker.sh" || { printf 'FAIL - %s (tests/testlib-headed-arm-worker.sh missing, unreadable or failing to load)\n' "$(basename "$0")"; exit 1; }


# deleting the post-handoff add must fail these manifest assertions.
# The target is a fixture: never launch a real worker or edit a live manifest.
mkdir -p "$tmp/fleet-fixture"
fleet_doc="$tmp/fleet-fixture/PROJ-3748-N7-fleet.md"
fleet_manifest="$tmp/fleet-fixture/fleet.json"
fx_brief '# fleet fixture' > "$fleet_doc"
# FLEET_TEST_LIB names the tree's lib: the stub target runs the real usage-preflight.sh, a chokepoint, with the markers this
# launcher exports and this suite's seams, which the guard refuses on a primary checkout.
fleet_launch() {
  FLEET_TEST_MANIFEST="$fleet_manifest" FLEET_TEST_LIB="$LAUNCH_TREE/scripts/lib" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_CACHE="$tmp/no-native-cache" HEADED_ARM_WORKER_TARGET="$fleet_target" \
    HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" bash "$SCRIPT" \
    --no-profile --fleet "$fleet_manifest" "$@" \
    PROJ-3748-N7-fleet "$fleet_doc" "$tmp/fleet-signal" "$PAST" "$tmp/fleet-log" claude-sonnet-5-5
}
# fleet-manifest.sh serialises the add under util-linux flock; the kit is Linux-only.
if command -v flock >/dev/null 2>&1; then
  bash "$HERE/fleet-manifest.sh" control init "$fleet_manifest" --target 4 >/dev/null || exit 1
  bash "$HERE/fleet-manifest.sh" control set "$fleet_manifest" --mode active --expect-gen 1 >/dev/null || exit 1
  bash "$HERE/fleet-manifest.sh" add "$fleet_manifest" "$fleet_doc" --lane native --pending >/dev/null || exit 1
  rc=0; out="$(fleet_launch 2>&1)" || rc=$?
  check 'fleet: successful handoff returns zero' 0 "$rc"
  check 'fleet: successful handoff adds exactly the worker doc' "$fleet_doc" "$(jq -r '.workers[].doc' "$fleet_manifest" 2>/dev/null)"
  check 'fleet: the added row records the launch lane' native "$(jq -r '.workers[0].lane' "$fleet_manifest" 2>/dev/null)"
else
  echo "SKIP - fleet: successful-handoff rows (fleet-manifest.sh needs util-linux flock, absent here)"
fi
rm -f "$fleet_manifest" "$tmp/fleet-fixture/fleet-control.json"
if command -v flock >/dev/null 2>&1; then
  bash "$HERE/fleet-manifest.sh" control init "$fleet_manifest" --target 4 >/dev/null || exit 1
  bash "$HERE/fleet-manifest.sh" control set "$fleet_manifest" --mode active --expect-gen 1 >/dev/null || exit 1
fi
rc=0; out="$(FLEET_TEST_RC=7 fleet_launch 2>&1)" || rc=$?
check 'fleet: failed target status is preserved' 7 "$rc"
check 'fleet: unconfirmed target retains exact unknown ownership' unknown "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest")"
rm -f "$fleet_manifest" "$tmp/fleet-fixture/fleet-control.json"
rc=0; out="$(fleet_launch --dry-run 2>&1)" || rc=$?
check 'fleet: dry run refuses an absent manifest as the real launch does' 10 "$rc"
check 'fleet: dry run leaves manifest absent' no "$([ -e "$fleet_manifest" ] && echo yes || echo no)"

# A managed launch with the autocompact A/B variable set records the arm on the worker's row, whether the chief or the runtime
# registered the row, and stays launched; a manifest update refused after the launch exits 1 and leaves the attempt launched.
# FLEET_TEST_RECORD=1 makes the target record the launch in the family anchor as headed-arm.sh does, so the wrapper's own
# update runs on an attempt that is already launched.
fleet_ab_slots="$tmp/fleet-ab-slots"
fleet_ab_fresh() {  # <lane of the row the chief registers, or none> [brief line...]
  local lane="$1"; shift
  rm -rf "$fleet_manifest" "$tmp/fleet-fixture/fleet-control.json" "$fleet_ab_slots"
  fx_brief '# fleet fixture' "$@" > "$fleet_doc"
  bash "$HERE/fleet-manifest.sh" control init "$fleet_manifest" --target 4 >/dev/null || exit 1
  bash "$HERE/fleet-manifest.sh" control set "$fleet_manifest" --mode active --expect-gen 1 >/dev/null || exit 1
  [ "$lane" = none ] || bash "$HERE/fleet-manifest.sh" add "$fleet_manifest" "$fleet_doc" --lane "$lane" --pending >/dev/null || exit 1
}
fleet_ab_launch() { HIMMEL_FLEET_SLOTS="$fleet_ab_slots" FLEET_TEST_RECORD=1 fleet_launch; }
if command -v flock >/dev/null 2>&1; then
  fleet_ab_fresh native
  rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=200000 fleet_ab_launch 2>&1)" || rc=$?
  check 'fleet A/B 200k: a launch on a row the chief registered returns zero' 0 "$rc"
  check 'fleet A/B 200k: the attempt stays launched' launched "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest" 2>/dev/null)"
  check 'fleet A/B 200k: the row records the arm' 200k "$(jq -r '.workers[0].arm' "$fleet_manifest" 2>/dev/null)"
  fleet_ab_fresh none '> **Context:** ab-400k — operator-ruling: fixture'
  rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=400000 fleet_ab_launch 2>&1)" || rc=$?
  check 'fleet A/B 400k: a launch on a row the runtime registered returns zero' 0 "$rc"
  check 'fleet A/B 400k: the attempt stays launched' launched "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest" 2>/dev/null)"
  check 'fleet A/B 400k: the row records the arm' 400k "$(jq -r '.workers[0].arm' "$fleet_manifest" 2>/dev/null)"
  fleet_ab_fresh native
  rc=0; out="$(fleet_ab_launch 2>&1)" || rc=$?
  check 'fleet: a launch with no A/B variable returns zero' 0 "$rc"
  check 'fleet: a launch with no A/B variable records no arm' false "$(jq '.workers[0] | has("arm")' "$fleet_manifest" 2>/dev/null)"
  fleet_ab_fresh claudex
  rc=0; out="$(fleet_ab_launch 2>&1)" || rc=$?
  check 'fleet: a manifest update refused after the launch exits one' 1 "$rc"
  contains 'fleet: a manifest update refused after the launch says so' "$out" 'launch handed off but fleet manifest update failed'
  check 'fleet: a manifest update refused after the launch leaves the row attempt launched' launched "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest" 2>/dev/null)"
  check 'fleet: a manifest update refused after the launch leaves the anchor record launched' launched "$(jq -r '[.attempts[].phase] | join(" ")' "$tmp/fleet-fixture/fleet-control.json" 2>/dev/null)"
  check 'fleet: a manifest update refused after the launch is recorded as a post-launch error' postlaunch-error "$(jq -rs '[.[] | select(.source == "headed-arm-worker" and .name == "PROJ-3748-N7-fleet")] | last | .outcome' "$HOME/.himmel/launch-refusals.jsonl" 2>/dev/null)"
  check 'fleet: a different lane on a registered row is still refused, the row keeps its lane' claudex "$(jq -r '.workers[0].lane' "$fleet_manifest" 2>/dev/null)"
  rc=0; HIMMEL_FLEET_SLOTS="$fleet_ab_slots" bash "$HERE/fleet-manifest.sh" runtime reconcile --manifest "$fleet_manifest" >/dev/null 2>&1 || rc=$?
  check 'fleet: a manifest update refused after the launch: a later reconcile leaves the attempt launched and its reservation' "0 launched 1" "$rc $(jq -r '[.attempts[].phase] | join(" ")' "$tmp/fleet-fixture/fleet-control.json" 2>/dev/null) $(find "$fleet_ab_slots" -name managed.json 2>/dev/null | grep -c .)"
  # a child that records the launch and then ends with a non-zero status (FLEET_TEST_EXIT: killed, out of memory): the wrapper
  # returns that status, the attempt stays launched, its own record is not a refusal, nothing is released, and a later reconcile frees nothing.
  fleet_ab_fresh native
  rc=0; out="$(FLEET_TEST_EXIT=137 fleet_ab_launch 2>&1)" || rc=$?
  check 'fleet: a launched child that exits non-zero: the wrapper returns that status' 137 "$rc"
  check 'fleet: a launched child that exits non-zero: the row attempt stays launched' launched "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest" 2>/dev/null)"
  check 'fleet: a launched child that exits non-zero: the anchor record stays launched' launched "$(jq -r '[.attempts[].phase] | join(" ")' "$tmp/fleet-fixture/fleet-control.json" 2>/dev/null)"
  check 'fleet: a launched child that exits non-zero: the wrapper records indeterminate, not a refusal' indeterminate "$(jq -rs '[.[] | select(.source == "headed-arm-worker" and .name == "PROJ-3748-N7-fleet")] | last | .outcome' "$HOME/.himmel/launch-refusals.jsonl" 2>/dev/null)"
  check 'fleet: a launched child that exits non-zero: its reservation is not released' 1 "$(find "$fleet_ab_slots" -name managed.json 2>/dev/null | grep -c .)"
  rc=0; HIMMEL_FLEET_SLOTS="$fleet_ab_slots" bash "$HERE/fleet-manifest.sh" runtime reconcile --manifest "$fleet_manifest" >/dev/null 2>&1 || rc=$?
  check 'fleet: a launched child that exits non-zero: a later reconcile exits zero' 0 "$rc"
  check 'fleet: a launched child that exits non-zero: a later reconcile leaves the attempt launched' launched "$(jq -r '[.attempts[].phase] | join(" ")' "$tmp/fleet-fixture/fleet-control.json" 2>/dev/null)"
  check 'fleet: a launched child that exits non-zero: a later reconcile leaves the row and its attempt' launched "$(jq -r '.workers[0].attempt.phase' "$fleet_manifest" 2>/dev/null)"
  check 'fleet: a launched child that exits non-zero: a later reconcile leaves the reservation' 1 "$(find "$fleet_ab_slots" -name managed.json 2>/dev/null | grep -c .)"
  rm -rf "$fleet_manifest" "$tmp/fleet-fixture/fleet-control.json" "$fleet_ab_slots"
  fx_brief '# fleet fixture' > "$fleet_doc"
else
  echo "SKIP - fleet: A/B arm rows (fleet-manifest.sh needs util-linux flock, absent here)"
fi

# The launch preflight reads CADENCE_USAGE_* first, so an inherited new-name
# lane or worker must not beat the values this launch passes it.
rc=0; out="$(CADENCE_USAGE_LANE=claudex CADENCE_USAGE_WORKER=stale-worker CADENCE_USAGE_LAUNCH='' \
  REC_PREFLIGHT_OUT="$tmp/rec-preflight.env" FLEET_TEST_MANIFEST="$fleet_manifest" \
  HEADED_ARM_WORKER_TARGET="$fleet_target" HEADED_ARM_WORKER_PREFLIGHT="$REC_PREFLIGHT" bash "$SCRIPT" \
  --no-profile PROJ-3748-N7-fleet "$some_doc" "$tmp/fleet-signal" "$PAST" "$tmp/fleet-log" claude-sonnet-5-5 2>&1)" || rc=$?
check 'usage names: launch with inherited CADENCE_USAGE_* exits 0' 0 "$rc"
check 'usage names: the launch preflight sees this launch, not the inherited lane and worker' \
  "$(printf '%s\n' CADENCE_USAGE_LANE=native CADENCE_USAGE_LAUNCH=1 CADENCE_USAGE_WORKER=PROJ-3748-N7-fleet)" \
  "$(cat "$tmp/rec-preflight.env" 2>/dev/null)"
rc=0; out="$(HEADED_ARM_WORKER_PREFLIGHT="$SKIPPED_FLEET_PREFLIGHT" \
  HEADED_ARM_WORKER_TARGET="$fleet_target" bash "$SCRIPT" --no-profile --fleet "$fleet_manifest" \
  PROJ-3748-N7-fleet "$fleet_doc" "$tmp/fleet-signal" "$PAST" "$tmp/fleet-log" claude-sonnet-5-5 2>&1)" || rc=$?
check 'fleet: admission refusal preserves status' 10 "$rc"
check 'fleet: admission refusal leaves manifest absent' no "$([ -e "$fleet_manifest" ] && echo yes || echo no)"

fleet_manifest="$tmp/no-such-directory/fleet.json"
rc=0; out="$(fleet_launch 2>&1)" || rc=$?
check 'fleet: missing reference refuses before handoff' 10 "$rc"
contains 'fleet: missing reference reports paused' "$out" 'fleet-paused'
rc=0; out="$(bash "$SCRIPT" --fleet 2>&1)" || rc=$?
check 'fleet: missing flag value refuses' 2 "$rc"


# --- 1-2. usage/arg-shape ---------------------------------------------------
rc=0; out="$(bash "$SCRIPT" 2>&1)" || rc=$?
check "usage: no args -> exit 2" "$rc" "2"
contains "usage: no args -> usage text" "$out" "usage:"

rc=0; out="$(bash "$SCRIPT" --dry-run HIMMEL-x doc 2>&1)" || rc=$?
check "usage: --dry-run with too few positionals -> exit 2" "$rc" "2"

# `--lane` as the LAST arg (no value) must not hang. Bounded by
# `timeout` so a regression fails loudly (rc=124) instead of wedging the suite.
# Hang-guard: with no GNU timeout/gtimeout the row SKIPs rather than run unbounded.
if [ -n "$_TIMEOUT_BIN" ]; then
    rc=0; out="$("$_TIMEOUT_BIN" 5 bash "$SCRIPT" --lane 2>&1)" || rc=$?
    check "usage: --lane with no value -> exit 2 (not an infinite loop)" "$rc" "2"
    contains "usage: --lane with no value -> usage text" "$out" "usage:"
else
    echo "SKIP - usage: --lane with no value (hang-guard row needs GNU timeout/gtimeout)"
fi

# --- 3-6. --dry-run argv -----------------------------------------------------
# review finding: default-context cases must not inherit an
# operator's own WORKER_SESSION_CONTEXT/WORKER_SESSION_REPO from the launching shell - explicitly
# clear both (empty is equivalent to unset for this wrapper's own checks)
# rather than relying on ambient env happening to be clean.
rc=0; out="$(WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run default: exit 0" "$rc" "0"
ends_with "dry-run default: context=standard, no WORKER_SESSION_CONTEXT" "$out" "standard"
not_contains "dry-run default: no [1m] suffix in the would-exec line" "$out" "[1m]"
contains "dry-run default: reports IMPL_GUARD_OK=1" "$out" "IMPL_GUARD_OK=1"
contains "dry-run default: reports INLINE_IMPL_OK=1" "$out" "INLINE_IMPL_OK=1"
contains "dry-run default: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
not_contains "dry-run default: no HIMMEL_CONSOLE_RELAY without --relay" "$out" "HIMMEL_CONSOLE_RELAY"
contains "dry-run default: scrub list names CHIEF_CONTEXT" "$out" "scrub=CHIEF_CONTEXT"
contains "dry-run default: no chief-name source -> HIMMEL_CONSOLE_NAME absent" "$out" "HIMMEL_CONSOLE_NAME=<unset>"
# the worker's context guard reads its mode and ceiling from the
# launch env - the 200000 pin by default, the chief's mode when set, and a
# junk mode refuses the launch rather than reaching the worker. the
# guard is OFF by default - no mode reaches the worker unless the caller asks.
contains "dry-run default: no context mode (the guard is off)" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=<unset>"
contains "dry-run default: the guard's ceiling is the 200000 pin" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
rc=0; out="$(WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --context-guard compact PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --context-guard compact: exit 0" "$rc" "0"
contains "dry-run --context-guard compact: propagated" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
rc=0; out="$(WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --context-guard handoff PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run --context-guard handoff: propagated" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --context-guard none PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --context-guard none over an env mode: exit 0" "$rc" "0"
contains "dry-run --context-guard none: the flag wins, no mode reaches the worker" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=<unset>"
rc=0; out="$(WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --context-guard bogus PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --context-guard bogus: refused" "$rc" "2"
rc=0; out="$(WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --context-guard 2>&1)" || rc=$?
check "dry-run --context-guard with no value: refused" "$rc" "2"
contains "usage names --context-guard and its reference doc" "$out" "docs/internals/worker-context-guard.md"
rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff: exit 0" "$rc" "0"
contains "dry-run HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff: propagated" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=bogus WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run HIMMEL_WORKER_SESSION_CONTEXT_MODE=bogus: refused" "$rc" "2"
contains "dry-run HIMMEL_WORKER_SESSION_CONTEXT_MODE=bogus: names the allowed modes" "$out" "compact or handoff"

# a chief armed with CHIEF_CONTEXT=1m in its own environ (the
# mandatory opt-in for a 1M successor, chief.sh:382) must not forward that
# chief-only knob into a worker it arms. Ambient CHIEF_CONTEXT=1m in THIS
# suite's own launching shell must not silently satisfy the assertion either -
# not_contains on a value the wrapper never receives proves nothing - so this
# sets it explicitly on the invocation, same shape as the WORKER_SESSION_CONTEXT=1m case
# below. Enumerates the expected scrub set explicitly (not merely "non-empty")
# so a future chief-only knob added without a matching scrub here fails
# this exact assertion, not a vaguer one.
rc=0; out="$(CHIEF_CONTEXT=1m WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient CHIEF_CONTEXT=1m: exit 0 (a worker is unaffected by it)" "$rc" "0"
contains "dry-run, ambient CHIEF_CONTEXT=1m: scrubbed to <unset> in the wrapper's own env" "$out" "scrub=CHIEF_CONTEXT HIMMEL_CONSOLE_JUDGE_EFFORT HIMMEL_CONSOLE_JUDGE_DOC HIMMEL_CONSOLE_JUDGE_QID HIMMEL_RELEASE_MANAGER HIMMEL_RM_DOC HIMMEL_RM_RELEASE HIMMEL_RM_EFFORT HIMMEL_CONSOLE HIMMEL_JIRA_LIVE_TEST CHIEF_CONTEXT=<unset> "
not_contains "dry-run, ambient CHIEF_CONTEXT=1m: never reported as still set" "$out" "CHIEF_CONTEXT=1m"

# --- HIMMEL_CONSOLE_NAME resolution (--chief, launching
# shell's HIMMEL_CONSOLE_NAME, this process's own session name via
# session-name.sh), charset refusal, and precedence. -------------------------

# Source 1: --chief flag.
rc=0; out="$(bash "$SCRIPT" --dry-run --chief opsdesk --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --chief opsdesk: exit 0" "$rc" "0"
contains "dry-run --chief opsdesk: reports HIMMEL_CONSOLE_NAME=opsdesk" "$out" "HIMMEL_CONSOLE_NAME=opsdesk"

# Source 2: the launching shell's own HIMMEL_CONSOLE_NAME, no --chief.
rc=0; out="$(HIMMEL_CONSOLE_NAME=ambient-chief bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient HIMMEL_CONSOLE_NAME: exit 0" "$rc" "0"
contains "dry-run, ambient HIMMEL_CONSOLE_NAME: reports it" "$out" "HIMMEL_CONSOLE_NAME=ambient-chief"

# --chief wins over an ambient HIMMEL_CONSOLE_NAME (source 1 before source 2).
rc=0; out="$(HIMMEL_CONSOLE_NAME=ambient-chief bash "$SCRIPT" --dry-run --chief flag-chief --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, --chief + ambient HIMMEL_CONSOLE_NAME: exit 0" "$rc" "0"
contains "dry-run, --chief + ambient HIMMEL_CONSOLE_NAME: flag wins" "$out" "HIMMEL_CONSOLE_NAME=flag-chief"
not_contains "dry-run, --chief + ambient HIMMEL_CONSOLE_NAME: ambient value dropped" "$out" "HIMMEL_CONSOLE_NAME=ambient-chief"

# Source 3: this process's own Claude session name, via session-name.sh's
# CLAUDE_PID + SESSION_NAME_CMDLINE_FILE test seam - only consulted when
# neither --chief nor the launching shell's HIMMEL_CONSOLE_NAME yielded one.
csn_fixture="$tmp/session-name-cmdline"
printf 'claude\0--model\0x\0-n\0detected-chief\0load doc and continue\0' > "$csn_fixture"
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture" bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, own session name via CLAUDE_PID/cmdline: exit 0" "$rc" "0"
contains "dry-run, own session name via CLAUDE_PID/cmdline: reports it" "$out" "HIMMEL_CONSOLE_NAME=detected-chief"

# --chief still wins over the auto-detected session name.
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture" bash "$SCRIPT" --dry-run --chief flag-chief --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run, --chief + own session name: flag wins" "$out" "HIMMEL_CONSOLE_NAME=flag-chief"
not_contains "dry-run, --chief + own session name: auto-detected value dropped" "$out" "HIMMEL_CONSOLE_NAME=detected-chief"

# --chief: a bad charset REFUSES the launch outright (explicit user input,
# same stance as --lane/--profile) - unlike sources 2/3 below.
rc=0; out="$(bash "$SCRIPT" --dry-run --chief 'bad name' --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "--chief with a bad charset: exit 2" "$rc" "2"
contains "--chief with a bad charset: usage text" "$out" "usage:"
contains "--chief with a bad charset: names the bad value" "$out" "bad name"

# Ambient HIMMEL_CONSOLE_NAME with a bad charset: NOT a hard refusal - treated
# as if that source yielded nothing (best-effort routing, not load-bearing),
# so the launch still succeeds and HIMMEL_CONSOLE_NAME is absent.
rc=0; out="$(HIMMEL_CONSOLE_NAME='bad/name' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient HIMMEL_CONSOLE_NAME with a bad charset: exit 0 (not refused)" "$rc" "0"
contains "dry-run, ambient HIMMEL_CONSOLE_NAME with a bad charset: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"

# The auto-detected session name is charset-checked too: session-name.sh's own
# validation would accept a colon (it only rejects '/', '..', whitespace and
# glob metacharacters), but this narrower charset must still reject it and
# fall through to "no source" rather than exporting an unsafe value.
csn_fixture_colon="$tmp/session-name-cmdline-colon"
printf 'claude\0--model\0x\0-n\0bad:name\0load doc and continue\0' > "$csn_fixture_colon"
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture_colon" bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, own session name with a bad charset: exit 0 (not refused)" "$rc" "0"
contains "dry-run, own session name with a bad charset: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"

# "." and ".." pass the charset but are path components once
# merge-block-alert.sh joins the name into the chief inbox path. Both
# validation sites refuse them, each with its own stance (flag = exit 2,
# ambient = no source).
for dots in . ..; do
  rc=0; out="$(bash "$SCRIPT" --dry-run --chief "$dots" --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
  check "--chief [$dots]: exit 2" "$rc" "2"
  contains "--chief [$dots]: names the bad value" "$out" "got: $dots"
  rc=0; out="$(HIMMEL_CONSOLE_NAME="$dots" bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
  check "dry-run, ambient HIMMEL_CONSOLE_NAME=[$dots]: exit 0 (not refused)" "$rc" "0"
  contains "dry-run, ambient HIMMEL_CONSOLE_NAME=[$dots]: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"
done

# a caller-preset HEADED_ARM_LAUNCHER_ENV is appended to, never
# replaced (worker_propagate_env), and headed-arm.sh hands its tokens to the worker
# on every lane - so a scrubbed var carried there would come back past the
# `unset`. The scrub strips it from the token list too; siblings survive.
for lane in native claudex; do
  out="$(HEADED_ARM_LAUNCHER_ENV="CHIEF_CONTEXT=1m KEEP_ME=1" bash "$SCRIPT" --dry-run --lane "$lane" --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
  lenv="$(printf '%s\n' "$out" | grep '^headed-arm-worker: lane=')"
  contains "--lane $lane, caller-preset launcher-env: dry-run reached the lane line" "$lenv" "launcher-env="
  not_contains "--lane $lane, caller-preset launcher-env: scrubbed CHIEF_CONTEXT stripped" "$lenv" "CHIEF_CONTEXT="
  not_contains "--lane $lane, caller-preset launcher-env: scrubbed CHIEF_CONTEXT stripped" "$lenv" "CHIEF_CONTEXT="
  contains "--lane $lane, caller-preset launcher-env: sibling token kept" "$lenv" "KEEP_ME=1"
done

# worker_propagate_env lets a caller-preset
# token win on a name clash, so a preset HIMMEL_CONSOLE_NAME=.. used to reach
# the worker unvalidated - past a valid --chief, or with no source at all. The
# launcher drops the preset token and propagates only the name it resolved.
out="$(HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_NAME=.. KEEP_ME=1" bash "$SCRIPT" --dry-run --chief good-chief --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
lenv="$(printf '%s\n' "$out" | grep '^headed-arm-worker: lane=')"
contains "preset HIMMEL_CONSOLE_NAME token + --chief: the validated name propagates" "$lenv" "HIMMEL_CONSOLE_NAME=good-chief"
not_contains "preset HIMMEL_CONSOLE_NAME token + --chief: the preset token is dropped" "$lenv" "HIMMEL_CONSOLE_NAME=.."
contains "preset HIMMEL_CONSOLE_NAME token + --chief: sibling token kept" "$lenv" "KEEP_ME=1"
out="$(HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_NAME=.. KEEP_ME=1" bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
lenv="$(printf '%s\n' "$out" | grep '^headed-arm-worker: lane=')"
not_contains "preset HIMMEL_CONSOLE_NAME token, no source: nothing propagates" "$lenv" "HIMMEL_CONSOLE_NAME="
contains "preset HIMMEL_CONSOLE_NAME token, no source: sibling token kept" "$lenv" "KEEP_ME=1"

# only grep's rc 1 means "absent" - an rc >1 is an execution
# error and must fail the assertion, never pass it vacuously (#1139's fix to
# the same helper in test-headed-arm.sh).
# shellcheck disable=SC2317,SC2329  # grep() is invoked indirectly, through grepq
nc_probe=$( grep() { return 2; }; not_contains "probe" "x" "y" )
check "not_contains reports a grep error as a failure, not as absence" "$nc_probe" "FAIL - probe: grep itself failed (rc 2)"

rc=0; out="$(WORKER_SESSION_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run WORKER_SESSION_CONTEXT=1m: refused with exit 2" "$rc" "2"
contains "dry-run WORKER_SESSION_CONTEXT=1m: refusal names the required ceiling" "$out" "--autocompact 200000"
contains "dry-run WORKER_SESSION_CONTEXT=1m: refusal points to the standard worker setting" "$out" "unset WORKER_SESSION_CONTEXT"

rc=0; out="$(WORKER_SESSION_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-fable-5-1 2>&1)" || rc=$?
check "dry-run WORKER_SESSION_CONTEXT=1m, Fable model: refused with exit 2" "$rc" "2"
contains "dry-run WORKER_SESSION_CONTEXT=1m, Fable model: still checks autocompact, not the model suffix" "$out" "--autocompact 200000"

# --- 36. Sanctioned operator-ruled 1m Context-line opt-in ------
# some/doc.md (nonexistent) already covers the "no line" negative above -
# these fixture docs cover the empty-reason and malformed-line negatives,
# plus the one well-formed positive case.
doc_context_none="$tmp/context-doc-none.md"
fx_brief '# fixture brief, no Context line at all' > "$doc_context_none"

doc_context_empty="$tmp/context-doc-empty.md"
fx_brief '# fixture brief' '> **Context:** 1m — operator-ruling: ' > "$doc_context_empty"

doc_context_bad_dash="$tmp/context-doc-bad-dash.md"
fx_brief '# fixture brief' '> **Context:** 1m - operator-ruling: hyphen not em dash' > "$doc_context_bad_dash"

doc_context_bad_mode="$tmp/context-doc-bad-mode.md"
fx_brief '# fixture brief' '> **Context:** 1M — operator-ruling: wrong case mode' > "$doc_context_bad_mode"

doc_context_no_marker="$tmp/context-doc-no-marker.md"
fx_brief '# fixture brief' '> **Context:** 1m — because I said so' > "$doc_context_no_marker"

doc_context_ok="$tmp/context-doc-ok.md"
fx_brief '# fixture brief' '> **Context:** 1m — operator-ruling: PROJ-3581 sanctioned 1m worker test' > "$doc_context_ok"

for d in "$doc_context_none" "$doc_context_empty" "$doc_context_bad_dash" "$doc_context_bad_mode" "$doc_context_no_marker"; do
    rc=0; out="$(WORKER_SESSION_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$d" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
    check "dry-run WORKER_SESSION_CONTEXT=1m, $(basename "$d"): still refused with exit 2" "$rc" "2"
    contains "dry-run WORKER_SESSION_CONTEXT=1m, $(basename "$d"): refusal names the required ceiling" "$out" "--autocompact 200000"
done

rc=0; out="$(WORKER_SESSION_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_context_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run WORKER_SESSION_CONTEXT=1m, sanctioned Context line: accepted (exit 0)" "$rc" "0"
contains "dry-run WORKER_SESSION_CONTEXT=1m, sanctioned Context line: reports context=1m (operator-ruling)" "$out" "context=1m (operator-ruling)"
contains "dry-run WORKER_SESSION_CONTEXT=1m, sanctioned Context line: reports the reason" "$out" "PROJ-3581 sanctioned 1m worker test"
contains "dry-run WORKER_SESSION_CONTEXT=1m, sanctioned Context line: exports CHIEF_CONTEXT=1m before the exec" "$out" "CHIEF_CONTEXT=1m"

# --- the audited autocompact A/B arm (WORKER_SESSION_AUTOCOMPACT_AB) -----
# 400000 needs the brief ruling line, standard context and a valid value; 200000
# is the control arm; the default (unset) stays 200000 for everyone not opted in.
doc_ab_none="$tmp/ab-doc-none.md"
fx_brief '# fixture brief, no Context line' > "$doc_ab_none"
doc_ab_empty="$tmp/ab-doc-empty.md"
fx_brief '# fixture brief' '> **Context:** ab-400k — operator-ruling: ' > "$doc_ab_empty"
doc_ab_ok="$tmp/ab-doc-ok.md"
fx_brief '# fixture brief' '> **Context:** ab-400k — operator-ruling: PROJ-5193' > "$doc_ab_ok"

for d in "$doc_ab_none" "$doc_ab_empty"; do
    rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=400000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$d" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
    check "ab arm 400000, $(basename "$d"): refused with exit 2" "$rc" "2"
    not_contains "ab arm 400000, $(basename "$d"): no 400000 arm reported" "$out" "ab-arm=400k"
done
rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=300000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "ab arm 300000 (not 200000/400000): refused with exit 2" "$rc" "2"
rc=0; out="$(WORKER_SESSION_CONTEXT=1m WORKER_SESSION_AUTOCOMPACT_AB=400000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "ab arm 400000 with WORKER_SESSION_CONTEXT=1m: refused with exit 2" "$rc" "2"
rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=400000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "ab arm 400000, ruling line: accepted (exit 0)" "$rc" "0"
contains "ab arm 400000, ruling line: reports ab-arm=400k autocompact=400000" "$out" "ab-arm=400k autocompact=400000"
contains "ab arm 400000, ruling line: exports HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000"
rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=200000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_none" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "ab arm 200000 (control), no ruling line: accepted (exit 0)" "$rc" "0"
contains "ab arm 200000 (control): reports ab-arm=200k autocompact=200000" "$out" "ab-arm=200k autocompact=200000"
rc=0; out="$(WORKER_SESSION_CONTEXT=1m WORKER_SESSION_AUTOCOMPACT_AB=200000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_none" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "ab arm 200000 (control) with WORKER_SESSION_CONTEXT=1m: refused with exit 2" "$rc" "2"
not_contains "ab arm 200000 with WORKER_SESSION_CONTEXT=1m: no control arm recorded" "$out" "ab-arm=200k"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "no WORKER_SESSION_AUTOCOMPACT_AB, ruling line present: default unchanged (exit 0)" "$rc" "0"
not_contains "no WORKER_SESSION_AUTOCOMPACT_AB: no ab arm reported" "$out" "ab-arm="
not_contains "no WORKER_SESSION_AUTOCOMPACT_AB: no 400000 ceiling" "$out" "autocompact=400000"
rc=0; out="$(HEADED_ARM_AB_AUTOCOMPACT=400000 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg "$doc_ab_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
not_contains "ambient HEADED_ARM_AB_AUTOCOMPACT is not honoured" "$out" "ab-arm=400k"

# Proves the ACCEPTED argv (not just this wrapper's own dry-run report) really
# carries --autocompact auto and a [1m]-suffixed model - headed-arm.sh is
# read-only for this ticket, so this drives its own --dry-run directly with
# the same CHIEF_CONTEXT=1m + context=1m pair the wrapper's sanctioned
# branch would hand it, rather than editing that file to observe it.
# KONSOLE_CMD is stubbed because headed-arm.sh's own terminal-emulator
# dependency check runs before --dry-run short-circuits, and a real konsole
# binary is not guaranteed on PATH (e.g. CI runners).
d_sanctioned="$tmp/sanctioned-pair"; mkdir -p "$d_sanctioned"
cat > "$d_sanctioned/konsole" <<'KONSOLE_STUB_EOF'
#!/usr/bin/env bash
exit 0
KONSOLE_STUB_EOF
chmod 755 "$d_sanctioned/konsole"
rc=0; out="$(CHIEF_CONTEXT=1m KONSOLE_CMD="$d_sanctioned/konsole" bash "$HEADED_ARM" --dry-run PROJ-9999-leg "$doc_context_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-4-6 1m 2>&1)" || rc=$?
check "headed-arm.sh --dry-run, sanctioned pair (CHIEF_CONTEXT=1m, context=1m): exit 0" "$rc" "0"
contains "headed-arm.sh --dry-run, sanctioned pair: accepted argv carries --autocompact auto" "$out" "--autocompact auto"
contains "headed-arm.sh --dry-run, sanctioned pair: accepted argv carries the [1m] model suffix" "$out" "claude-sonnet-4-6[1m]"

for off in "standard" "yes" "true" "1M" ""; do
  rc=0; out="$(WORKER_SESSION_CONTEXT="$off" bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
  ends_with "dry-run WORKER_SESSION_CONTEXT=[$off]: stays on standard (fail toward the cheaper default)" "$out" "standard"
done

# --- only `--profile design` resolves the 1m context with no
# env var or brief line; every other profile keeps the 200000 ceiling.
rc=0; out="$(WORKER_SESSION_CONTEXT='' bash "$SCRIPT" --dry-run --profile design PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --profile design: exit 0" "$rc" "0"
contains "dry-run --profile design: names the profile source" "$out" "context=1m (profile design contextMode 1m)"
ends_with "dry-run --profile design: context=1m" "$out" "1m"
rc=0; out="$(WORKER_SESSION_CONTEXT='' bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --profile worker-impl: exit 0" "$rc" "0"
ends_with "dry-run --profile worker-impl: stays standard" "$out" "standard"
not_contains "dry-run --profile worker-impl: no operator-ruling context" "$out" "operator-ruling"
rc=0; out="$(WORKER_SESSION_CONTEXT=1m bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --profile worker-impl + WORKER_SESSION_CONTEXT=1m: still refused" "$rc" "2"

# --- role-to-profile rule: a brief `profile:` line selects the
# profile when no --profile / WORKER_SESSION_PROFILE is given; the flag overrides it; a
# brief with no field still hits the unprofiled-launch refusal.
rule_doc="$tmp/rule-brief-design.md"
fx_brief '# fixture brief' '> profile: design' > "$rule_doc"
rc=0; out="$(WORKER_SESSION_PROFILE='' WORKER_SESSION_CONTEXT='' bash "$SCRIPT" --dry-run PROJ-9999-leg "$rule_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "brief profile: design line selects design: exit 0" "$rc" "0"
contains "brief profile: design line names the profile source" "$out" "context=1m (profile design contextMode 1m)"
rc=0; out="$(WORKER_SESSION_PROFILE='' WORKER_SESSION_CONTEXT='' bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$rule_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "explicit --profile overrides the brief line: exit 0" "$rc" "0"
not_contains "explicit --profile worker-impl overrides the brief's design" "$out" "context=1m"
rule_doc2="$tmp/rule-brief-none.md"
fx_brief '# fixture brief' 'no profile field here' > "$rule_doc2"
rc=0; out="$(WORKER_SESSION_PROFILE='' bash "$SCRIPT" --dry-run PROJ-9999-leg "$rule_doc2" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "brief with no profile field still refused" "$rc" "2"
contains "brief with no profile field: refusal text" "$out" "refusing an unprofiled launch"

# --- 6b. --relay: forces the chief-relay profile + the
# HIMMEL_CONSOLE_RELAY env marker Guard C (inbox-send.sh) and the Task 26
# write-deny hook key off. No value; defaults MODEL to claude-sonnet-5-5 when
# omitted; an explicit --profile (flag or WORKER_SESSION_PROFILE) other than
# chief-relay conflicts and refuses.
rc=0; out="$(bash "$SCRIPT" --dry-run --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --relay: exit 0" "$rc" "0"
contains "dry-run --relay: reports HIMMEL_CONSOLE_RELAY=1" "$out" "HIMMEL_CONSOLE_RELAY=1"
contains "dry-run --relay: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
contains "dry-run --relay: forces profile=chief-relay" "$out" "profile=chief-relay"
contains "dry-run --relay: defaults the model to claude-sonnet-5-5" "$out" "/tmp/worker.log claude-sonnet-5-5 standard"

rc=0; out="$(bash "$SCRIPT" --dry-run --relay --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --relay --profile worker-impl: refused with exit 2" "$rc" "2"
contains "dry-run --relay --profile worker-impl: refusal names chief-relay" "$out" "chief-relay"

rc=0; out="$(WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --relay, WORKER_SESSION_PROFILE=worker-impl: refused with exit 2" "$rc" "2"
contains "dry-run --relay, WORKER_SESSION_PROFILE=worker-impl: refusal names chief-relay" "$out" "chief-relay"

# --relay with an explicit model: explicit wins over the sonnet default. The
# existing Opus tier gate then applies exactly as today; some/doc.md carries
# no Tier line, so this refuses with exit 2 - proving the model reached the
# tier gate unchanged rather than being silently downgraded to sonnet first.
rc=0; out="$(bash "$SCRIPT" --dry-run --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "dry-run --relay, explicit opus model: tier gate still applies (exit 2)" "$rc" "2"
contains "dry-run --relay, explicit opus model: refusal is the tier gate" "$out" "Tier"

# --- 6c. --judge: forces the console-judge profile
# + the same HIMMEL_CONSOLE_LEG=1 marker every worker carries (design §3.2, "the
# judge is a worker" - Guard E refuses a judge's own GO identically, no separate
# marker). Defaults MODEL to claude-opus-5-5 at high effort on the native lane
# only (Opus 5.5 high measured ~2.7x cheaper per verdict than
# Fable 5.1 with comparable wall time and zero missed findings in the dataset
# - Fable is retired as the judge DEFAULT, kept only as an explicit,
# tier-gated choice); withholds IMPL_GUARD_OK/INLINE_IMPL_OK (a judge does not
# implement); raises HIMMEL_READ_CLAMP_LINES; and switches the preface source
# to docs/handover/judge-preface.md. The Opus default still has to clear the
# existing tier gate, so this uses a fixture doc carrying a Tier line rather
# than some/doc.md.

rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK bash "$SCRIPT" --dry-run --judge PROJ-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge: exit 0" "$rc" "0"
contains "dry-run --judge: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
contains "dry-run --judge: forces profile=console-judge" "$out" "profile=console-judge"
contains "dry-run --judge: defaults the model to claude-opus-5-5" "$out" "claude-opus-5-5"
contains "dry-run --judge: defaults the effort to high" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"
contains "dry-run --judge: withholds IMPL_GUARD_OK" "$out" "IMPL_GUARD_OK=<unset>"
contains "dry-run --judge: withholds INLINE_IMPL_OK" "$out" "INLINE_IMPL_OK=<unset>"
contains "dry-run --judge: raises the read-clamp line limit" "$out" "read-clamp-lines=4000"
contains "dry-run --judge: preface source is judge-preface.md" "$out" "docs/handover/judge-preface.md"

# a persisting worker shell that itself calls headed-arm-worker.sh to
# arm a judge keeps its OWN worker-only env (IMPL_GUARD_OK, INLINE_IMPL_OK,
# CLAUDEX_LANE_OK, WORKER_SESSION_CLAUDE_BIN, a stale HEADED_ARM_LAUNCHER pointer, and the
# HEADED_ARM_LAUNCHER_ENV token list carrying them) exported ambiently for its
# whole session. A judge never implements, so an inherited IMPL_GUARD_OK=1
# reaching it silently is the live symptom this ticket fixes - the wrapper
# must scrub all of it before arming, not just skip re-setting IMPL_GUARD_OK.
rc=0; out="$(IMPL_GUARD_OK=1 INLINE_IMPL_OK=1 HEADED_ARM_LAUNCHER=/tmp/stale-launcher \
  WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-bin HIMMEL_LEAN_WORKER_SESSION=1 CLAUDEX_LANE_OK=1 \
  HEADED_ARM_LAUNCHER_ENV='IMPL_GUARD_OK=1 INLINE_IMPL_OK=1 CLAUDEX_LANE_OK=1 HEADED_ARM_LAUNCHER=/tmp/stale-launcher WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-bin' \
  bash "$SCRIPT" --dry-run --judge PROJ-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge, ambient worker-only env: exit 0" "$rc" "0"
contains "dry-run --judge, ambient worker-only env: still withholds IMPL_GUARD_OK" "$out" "IMPL_GUARD_OK=<unset>"
contains "dry-run --judge, ambient worker-only env: still withholds INLINE_IMPL_OK" "$out" "INLINE_IMPL_OK=<unset>"
not_contains "dry-run --judge, ambient worker-only env: launcher-env drops the inherited IMPL_GUARD_OK token" "$out" "IMPL_GUARD_OK=1"
not_contains "dry-run --judge, ambient worker-only env: launcher-env drops the inherited CLAUDEX_LANE_OK token" "$out" "CLAUDEX_LANE_OK=1"
not_contains "dry-run --judge, ambient worker-only env: launcher-env drops the stale WORKER_SESSION_CLAUDE_BIN token" "$out" "/tmp/stale-claude-bin"
not_contains "dry-run --judge, ambient worker-only env: launcher-env drops the stale HEADED_ARM_LAUNCHER token" "$out" "/tmp/stale-launcher"

# The Opus default is not an
# exemption from TIER_GATE - the gate matches by MODEL PREFIX regardless of
# how MODEL got set, so a --judge launch with NO Tier line in its doc must
# still be refused even though no explicit model was named. some/doc.md
# carries no Tier line.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge, no Tier line: refused with exit 2" "$rc" "2"
contains "dry-run --judge, no Tier line: refusal is the opus tier gate" "$out" "refusing opus launch"

# an EXPLICIT --judge launch that still names claude-fable-5-1
# must clear the SAME tier gate as before - the default flipped to Opus, but
# the gate (keyed on MODEL prefix, not on how MODEL got set) is untouched.
# some/doc.md carries no Tier line, so this proves the gate still fires for
# an explicit Fable judge instead of letting the named model coast in under
# the new default's cost story.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-fable-5-1 2>&1)" || rc=$?
check "dry-run --judge, explicit fable model: still hits the tier gate (exit 2)" "$rc" "2"
contains "dry-run --judge, explicit fable model: refusal is the fable tier gate" "$out" "refusing fable launch"

# --judge --lane claudex: the Opus/high-effort default is scoped to the
# native lane only (the design explicitly leaves composing --judge with
# claudex out of scope) - claudex keeps its own gpt-6.1-sol/xhigh-effort
# default untouched, and some/doc.md (no Tier line) proves that default never
# reached the Opus/Fable tier gate.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge --lane claudex: exit 0" "$rc" "0"
not_contains "dry-run --judge --lane claudex: does not force claude-opus-5-5" "$out" "claude-opus-5-5"
not_contains "dry-run --judge --lane claudex: does not force high effort" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"
contains "dry-run --judge --lane claudex: still forces profile=console-judge" "$out" "profile=console-judge"

# --judge conflicts with an explicit non-matching --profile, same shape as --relay.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge --profile worker-impl: refused with exit 2" "$rc" "2"
contains "dry-run --judge --profile worker-impl: refusal names console-judge" "$out" "console-judge"

# --judge --relay together: each flag's own conflict check refuses in turn
# (RELAY forces chief-relay first; JUDGE then sees a mismatched non-empty
# PROFILE and refuses) - no dedicated mutual-exclusion guard needed.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --judge --relay: refused with exit 2" "$rc" "2"
contains "dry-run --judge --relay: refusal names console-judge" "$out" "console-judge"

# --- 6d. --profile release-manager: a judge-shaped role session. Read-only
# (READONLY_ROLE=1, no IMPL_GUARD_OK/INLINE_IMPL_OK), bound to its release by a
# required --rm-release, and marked HIMMEL_RELEASE_MANAGER=1 so
# guard-rm-writes.sh's mode 2 fences it. Opus at high effort by default, native
# lane only, rm-preface.md as the preface source.

rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK -u HIMMEL_RM_EFFORT bash "$SCRIPT" --dry-run --profile release-manager --rm-release v1.1.3 PROJ-9999-rm "$doc_tier_rm" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run release-manager: exit 0" "$rc" "0"
contains "dry-run release-manager: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
contains "dry-run release-manager: exports HIMMEL_RELEASE_MANAGER=1" "$out" "HIMMEL_RELEASE_MANAGER=1"
contains "dry-run release-manager: exports HIMMEL_RM_DOC as the absolute doc" "$out" "HIMMEL_RM_DOC=$doc_tier_rm_phys"
contains "dry-run release-manager: exports HIMMEL_RM_RELEASE" "$out" "HIMMEL_RM_RELEASE=v1.1.3"
contains "dry-run release-manager: READONLY_ROLE=1" "$out" "readonly-role=1"
contains "dry-run release-manager: withholds IMPL_GUARD_OK" "$out" "IMPL_GUARD_OK=<unset>"
contains "dry-run release-manager: withholds INLINE_IMPL_OK" "$out" "INLINE_IMPL_OK=<unset>"
contains "dry-run release-manager: defaults the model to claude-opus-5-5" "$out" "claude-opus-5-5"
contains "dry-run release-manager: defaults the effort to high" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"
contains "dry-run release-manager: raises the read-clamp line limit" "$out" "read-clamp-lines=4000"
contains "dry-run release-manager: preface source is rm-preface.md" "$out" "docs/handover/rm-preface.md"
contains "dry-run release-manager: profile=release-manager" "$out" "profile=release-manager"
contains "dry-run release-manager: the marker rides the launcher env" "$out" "HIMMEL_RELEASE_MANAGER=1 "

rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK HIMMEL_RM_EFFORT=max bash "$SCRIPT" --dry-run --profile release-manager --rm-release v1.1.3 PROJ-9999-rm "$doc_tier_rm" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run release-manager, HIMMEL_RM_EFFORT=max: exit 0" "$rc" "0"
contains "dry-run release-manager, HIMMEL_RM_EFFORT=max: overrides the effort" "$out" "CLAUDE_CODE_EFFORT_LEVEL=max"

# An ambient marker from a launching shell is never inherited by an ordinary worker.
rc=0; out="$(HIMMEL_RELEASE_MANAGER=1 HIMMEL_RM_RELEASE=v1.1.3 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run ordinary worker, ambient RM marker: exit 0" "$rc" "0"
not_contains "dry-run ordinary worker, ambient RM marker: never reaches the worker" "$out" "HIMMEL_RELEASE_MANAGER=1"

rm_refuses() {  # <label> <want-substring> <args...>
    local label="$1" want="$2"; shift 2
    rc=0; out="$(bash "$SCRIPT" --dry-run "$@" PROJ-9999-rm "$doc_tier_rm" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
    check "dry-run release-manager $label: refused with exit 2" "$rc" "2"
    contains "dry-run release-manager $label: refusal names the cause" "$out" "$want"
}
rm_refuses "without --rm-release" "--rm-release" --profile release-manager
rm_refuses "--judge" "console-judge" --judge --profile release-manager --rm-release v1.1.3
rm_refuses "--relay" "chief-relay" --relay --profile release-manager --rm-release v1.1.3
rm_refuses "--consult" "release-manager" --consult --profile release-manager --rm-release v1.1.3
rm_refuses "in a profile list" "release-manager" --profile release-manager,design --rm-release v1.1.3
rm_refuses "--lane claudex" "native" --lane claudex --profile release-manager --rm-release v1.1.3
rm_refuses "--rm-release with a slash" "--rm-release" --profile release-manager --rm-release ../x
rm_refuses "--rm-release on another profile" "--rm-release" --profile worker-impl --rm-release v1.1.3

# --- 7. WORKER_SESSION_REPO folded into HEADED_ARM_REPO --------------------------------
rc=0; out="$(WORKER_SESSION_REPO=/some/other/repo bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: WORKER_SESSION_REPO folded into HEADED_ARM_REPO" "$out" "HEADED_ARM_REPO=/some/other/repo"

# --- 7b. WORKER_SESSION_SUPPRESS_CR_TRIGGER folded into CR_TRIGGER_SUPPRESS
rc=0; out="$(WORKER_SESSION_SUPPRESS_CR_TRIGGER=1 bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: WORKER_SESSION_SUPPRESS_CR_TRIGGER folded into CR_TRIGGER_SUPPRESS" "$out" "CR_TRIGGER_SUPPRESS=1"

# --- 7c. unset WORKER_SESSION_SUPPRESS_CR_TRIGGER -> stays <unset> (default ON)
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: unset WORKER_SESSION_SUPPRESS_CR_TRIGGER leaves CR_TRIGGER_SUPPRESS unset (default ON)" "$out" "CR_TRIGGER_SUPPRESS=<unset>"

# --- 7d. WORKER_SESSION_API_LANE=on carries HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT=auto; otherwise neither
rc=0; out="$(WORKER_SESSION_API_LANE=on bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: WORKER_SESSION_API_LANE=on exits 0" "$rc" "0"
contains "dry-run: WORKER_SESSION_API_LANE=on carries both API-lane vars" "$out" "HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: unset WORKER_SESSION_API_LANE exits 0" "$rc" "0"
contains "dry-run: no WORKER_SESSION_API_LANE leaves both API-lane vars unset" "$out" "HIMMEL_API_LANE=<unset> HIMMEL_API_ACCOUNT=<unset>"
rc=0; out="$(WORKER_SESSION_API_LANE=off bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: WORKER_SESSION_API_LANE=off exits 0" "$rc" "0"
contains "dry-run: WORKER_SESSION_API_LANE=off leaves both API-lane vars unset" "$out" "HIMMEL_API_LANE=<unset> HIMMEL_API_ACCOUNT=<unset>"
rc=0; out="$(HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=B bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: ambient API-lane vars exit 0" "$rc" "0"
contains "dry-run: ambient API-lane vars without WORKER_SESSION_API_LANE are scrubbed" "$out" "HIMMEL_API_LANE=<unset> HIMMEL_API_ACCOUNT=<unset>"

# --- 8-9, 11. full (non-dry) launch: proves the non-dry path builds the SAME
# argv --dry-run predicted, via the real headed-arm.sh and its own KONSOLE_CMD
# seam. ----------------------------------------------------------------------
d8="$tmp/c8"; mk_launch_stubs "$d8" "PROJ-9999-leg"; mkdir -p "$tmp/repo8"
rc=0
WORKER_SESSION_CONTEXT='' RUN_WORKER_ARGS=--no-profile run_worker "$d8" "$tmp/repo8" "PROJ-9999-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d8" || true
rec8="$(cat "$d8/record" 2>/dev/null || true)"
check "full launch, default context: exit 0" "$rc" "0"
contains "full launch, default context: --autocompact 200000" "$rec8" "--autocompact 200000"
not_contains "full launch, default context: no [1m] suffix on the model" "$rec8" "claude-sonnet-5[1m]"
# native (no --lane) stays exactly as before - claude execed
# directly, no script(1) tty wrapper.
contains "full launch, native lane (default): execs claude directly" "$rec8" "claude --model"
not_contains "full launch, native lane (default): no script(1) tty wrapper" "$rec8" "script -q -a -f"
# /codex-2: run_worker sets WORKER_SESSION_REPO (never HEADED_ARM_REPO directly), so
# this now genuinely exercises the wrapper's own WORKER_SESSION_REPO->HEADED_ARM_REPO
# fold on the real (non-dry) path, not just headed-arm.sh's own seam.
contains "full launch: WORKER_SESSION_REPO folds into HEADED_ARM_REPO, reaches --workdir" "$rec8" "--workdir $tmp/repo8"

# full renderer reads a non-default numeric 1m ceiling from a
# fake registry, not the old design-name / auto branch. Konsole only records.
ceiling_reg="$tmp/ceiling-registry.json"
cat > "$ceiling_reg" <<'CEILING_EOF'
{"floor":["qmd@himmel"],"catalog":["qmd@himmel"],"profiles":{"operator":null,"design":{"enable":[],"contextBudget":50000,"contextMode":"1m","autocompact":400000}}}
CEILING_EOF
d8profile="$tmp/c8profile"; mk_launch_stubs "$d8profile" "PROJ-4021-ceiling"; mkdir -p "$tmp/repo8profile"
rc=0
mkdir -p "$tmp/profile-fleet"
profile_manifest="$tmp/profile-fleet/profile manifest.json"
profile_doc="$tmp/profile-fleet/worker.md"
cp "$some_doc" "$profile_doc"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$tmp/profile-fleet/ps"
chmod +x "$tmp/profile-fleet/ps"
if command -v flock >/dev/null 2>&1; then
  bash "$HERE/fleet-manifest.sh" control init "$profile_manifest" --target 4 >/dev/null || exit 1
  bash "$HERE/fleet-manifest.sh" control set "$profile_manifest" --mode active --expect-gen 1 >/dev/null || exit 1
fi
# the managed launch runs the real usage-preflight.sh through headed-arm.sh, so the target is the tree's headed-arm.sh
out8profile="$(PLUGIN_PROFILES_REGISTRY="$ceiling_reg" WORKER_SESSION_CONTEXT='' RUN_WORKER_ARGS='--profile design' \
  some_doc="$profile_doc" FLEET_PS_CMD="$tmp/profile-fleet/ps" CADENCE_USAGE_SKIP_REFRESH=1 HEADED_ARM="$LAUNCH_TREE/scripts/handover/headed-arm.sh" \
  run_worker "$d8profile" "$tmp/repo8profile" "PROJ-4021-ceiling" "claude-sonnet-4-6" \
  "$PROCEED_PREFLIGHT" "$profile_manifest" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || printf 'profile launch diagnostic: %s\n' "$out8profile"
if command -v flock >/dev/null 2>&1; then
  check 'fleet: real renderer preserves a spaced manifest path and profile ceiling' "$profile_doc" "$(jq -r '.workers[].doc' "$profile_manifest" 2>/dev/null)"
else
  echo "SKIP - fleet: real renderer spaced-manifest row (fleet-manifest.sh needs util-linux flock, absent here)"
fi
wait_record "$d8profile" || true
rec8profile="$(cat "$d8profile/record" 2>/dev/null || true)"
if command -v flock >/dev/null 2>&1; then
  check "profile numeric ceiling: full launch succeeds" "$rc" "0"
else
  echo "SKIP - profile numeric ceiling: full launch exit (fleet add needs util-linux flock, absent here)"
fi
contains "profile numeric ceiling: renderer carries 400000" "$rec8profile" "--autocompact 400000"
not_contains "profile numeric ceiling: no hard-coded auto" "$rec8profile" "--autocompact auto"
contains "profile numeric ceiling: model has 1m mode" "$rec8profile" "claude-sonnet-4-6[1m]"
log8profile="$(cat "$d8profile/log" 2>/dev/null || true)"
contains "profile numeric ceiling: wrapper names profile source" "$log8profile" "headed-arm-worker: context=1m (profile design contextMode 1m)"
contains "profile numeric ceiling: renderer names profile source" "$log8profile" "context=1m (profile design contextMode 1m); model="
not_contains "profile numeric ceiling: not an operator ruling" "$log8profile" "operator-ruling"

# a standard profile may carry a Sonnet-only ceiling (sonnetAutocompact) and context
# guard (sonnetContextGuard): impl hands off at 850k, eval compacts at 850k, docs stays
# at 200k, and any other model keeps today's 200000 with no guard. Full launch through
# the real renderer, so the final argv check is exercised too.
sonnet_reg="$tmp/sonnet-registry.json"
cat > "$sonnet_reg" <<'SONNET_EOF'
{"floor":["qmd@himmel"],"catalog":["qmd@himmel"],"profiles":{"operator":null,
"worker-impl":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000,"sonnetAutocompact":850000,"sonnetContextGuard":"handoff","sonnetContextShare":73},
"worker-eval":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000,"sonnetAutocompact":850000,"sonnetContextGuard":"compact"},
"worker-docs":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000}}}
SONNET_EOF
# sonnet_launch <tag> <profile> <model> [extra worker args] sets sa_rc / sa_rec / sa_env
sa_opus_doc="$tmp/sa-opus-doc.md"
fx_brief '# fixture brief' '> **Tier:** opus — design: multi-step design' > "$sa_opus_doc"
sa_fable_doc="$tmp/sa-fable-doc.md"
fx_brief '# fixture brief' '> **Tier:** fable — design: multi-step design' > "$sa_fable_doc"
sonnet_launch() {
  local d="$tmp/c-sa-$1" sa_doc="$some_doc"; mk_launch_stubs "$d" "PROJ-7667-$1"; mkdir -p "$tmp/repo-sa-$1"
  case "$3" in   # an Opus or Fable launch needs a Tier line
    claude-opus*) sa_doc="$sa_opus_doc" ;;
    claude-fable*) sa_doc="$sa_fable_doc" ;;
  esac
  sa_rc=0
  PLUGIN_PROFILES_REGISTRY="${sa_reg:-$sonnet_reg}" WORKER_SESSION_CONTEXT='' RUN_WORKER_ARGS="--profile $2 ${4-}" some_doc="$sa_doc" \
    run_worker "$d" "$tmp/repo-sa-$1" "PROJ-7667-$1" "$3" >/dev/null 2>&1 || sa_rc=$?
  wait_record "$d" || true
  sa_rec="$(cat "$d/record" 2>/dev/null || true)"
  sa_env="$(cat "$d/env-record" 2>/dev/null || true)"
}
sonnet_launch impl-sonnet worker-impl claude-sonnet-5-5
check "sonnet ceiling: impl on Sonnet launches" "$sa_rc" "0"
contains "sonnet ceiling: impl on Sonnet renders --autocompact 850000" "$sa_rec" "--autocompact 850000"
contains "sonnet ceiling: impl on Sonnet exports the 850000 ceiling" "$sa_env" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=850000"
contains "sonnet ceiling: impl on Sonnet turns the hand-off guard on" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
not_contains "sonnet ceiling: no 1m suffix" "$sa_rec" "[1m]"
check "sonnet share: a real launch delivers exactly the profile share to the worker's env" "$(printf '%s\n' "$sa_env" | grep '^HIMMEL_WORKER_SESSION_CONTEXT_SHARE=')" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
contains "sonnet share: the share rides the launcher env token list into the konsole argv" "$sa_rec" " HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73 "
not_contains "sonnet share: no mangled share value reaches the konsole argv" "$sa_rec" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=730"
sonnet_launch impl-opus worker-impl claude-opus-5-5
not_contains "sonnet share: a real launch on Opus delivers no share" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE="
check "sonnet ceiling: impl on Opus launches" "$sa_rc" "0"
contains "sonnet ceiling: impl on Opus keeps --autocompact 200000" "$sa_rec" "--autocompact 200000"
contains "sonnet ceiling: impl on Opus exports the 200000 ceiling" "$sa_env" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
not_contains "sonnet ceiling: impl on Opus sets no context guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
sonnet_launch eval-sonnet worker-eval claude-sonnet-5-5
contains "sonnet ceiling: eval on Sonnet renders --autocompact 850000" "$sa_rec" "--autocompact 850000"
contains "sonnet ceiling: eval on Sonnet compacts" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
sonnet_launch eval-opus worker-eval claude-opus-5-5
contains "sonnet ceiling: eval on Opus keeps --autocompact 200000" "$sa_rec" "--autocompact 200000"
not_contains "sonnet ceiling: eval on Opus sets no context guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
sonnet_launch docs-sonnet worker-docs claude-sonnet-5-5
contains "sonnet ceiling: docs on Sonnet stays at --autocompact 200000" "$sa_rec" "--autocompact 200000"
not_contains "sonnet ceiling: docs on Sonnet sets no context guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
sonnet_launch impl-flag worker-impl claude-sonnet-5-5 "--context-guard compact"
contains "sonnet ceiling: an explicit --context-guard wins over the profile's" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
sonnet_launch impl-none worker-impl claude-sonnet-5-5 "--context-guard none"
not_contains "sonnet ceiling: --context-guard none turns the profile's guard off" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
# The ceiling is resolved once, in the wrapper, and only for the native lane on a
# claude-sonnet-5 model. A lane that rewrites MODEL before the renderer (openrouter),
# another lane, an older Sonnet or the bare alias keep 200000 with no guard - and
# these are full launches through the real renderer, so its argv check runs.
for sl in "or-impl:worker-impl:claude-sonnet-5-5:--lane openrouter" \
          "or-eval:worker-eval:claude-sonnet-5-5:--lane openrouter" \
          "ds-impl:worker-impl:claude-sonnet-5-5:--lane deepseek" \
          "s4-impl:worker-impl:claude-sonnet-4-6:" \
          "bare-impl:worker-impl:sonnet:"; do
  IFS=: read -r sl_tag sl_prof sl_model sl_args <<< "$sl"
  sonnet_launch "$sl_tag" "$sl_prof" "$sl_model" "$sl_args"
  check "sonnet ceiling: $sl_tag launches (exit 0)" "$sa_rc" "0"
  contains "sonnet ceiling: $sl_tag keeps --autocompact 200000" "$sa_rec" "--autocompact 200000"
  not_contains "sonnet ceiling: $sl_tag has no 850000" "$sa_rec" "850000"
  not_contains "sonnet ceiling: $sl_tag sets no context guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
done
# WORKER_SESSION_CONTEXT=1m drops the profile's guard together with its ceiling.
sa_doc_1m="$tmp/sa-1m-doc.md"
fx_brief '# fixture brief' '> **Context:** 1m — operator-ruling: fixture' > "$sa_doc_1m"
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$sonnet_reg" WORKER_SESSION_CONTEXT=1m WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$sa_doc_1m" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 2>&1)" || rc=$?
check "sonnet ceiling: 1m override on worker-impl: exit 0" "$rc" "0"
contains "sonnet ceiling: 1m override drops the profile's hand-off guard" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=<unset>"
# The audited A/B arm needs the plain 200000 ceiling: a Sonnet impl launch is refused
# with the real reason, a docs launch (no Sonnet ceiling) takes the control arm.
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$sonnet_reg" WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' WORKER_SESSION_AUTOCOMPACT_AB=200000 bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 2>&1)" || rc=$?
check "A/B arm on a Sonnet worker-impl launch: refused" "$rc" "2"
contains "A/B arm on a Sonnet worker-impl launch: names the profile's Sonnet ceiling" "$out" "profile's Sonnet ceiling"
not_contains "A/B arm on a Sonnet worker-impl launch: does not blame 1m" "$out" "never combines with a 1m opt-in"
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$sonnet_reg" WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' WORKER_SESSION_AUTOCOMPACT_AB=200000 bash "$SCRIPT" --dry-run --profile worker-docs PROJ-9999-leg "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 2>&1)" || rc=$?
check "A/B arm control on a Sonnet worker-docs launch: exit 0" "$rc" "0"

# Operator decision 751: a profile may give a native-lane claude-opus-5
# launch a higher ceiling and a guard. worker-docs here has no Opus fields, so it is the
# control for a profile without them. Full launches through the real renderer.
opus_reg="$tmp/opus-registry.json"
cat > "$opus_reg" <<'OPUS_EOF'
{"floor":["qmd@himmel"],"catalog":["qmd@himmel"],"profiles":{"operator":null,
"worker-impl":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000,"sonnetAutocompact":850000,"sonnetContextGuard":"handoff","sonnetContextShare":73,"opusAutocompact":850000,"opusContextGuard":"handoff","opusContextShare":87},
"worker-eval":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000,"sonnetAutocompact":850000,"sonnetContextGuard":"compact","sonnetContextShare":73,"opusAutocompact":850000,"opusContextGuard":"compact","opusContextShare":87},
"worker-docs":{"enable":[],"contextBudget":50000,"contextMode":"standard","autocompact":200000}}}
OPUS_EOF
sa_reg="$opus_reg"
sonnet_launch opus-impl worker-impl claude-opus-5-5
check "opus ceiling: impl on Opus launches" "$sa_rc" "0"
contains "opus ceiling: impl on Opus renders --autocompact 850000" "$sa_rec" "--autocompact 850000"
contains "opus ceiling: impl on Opus exports the 850000 ceiling" "$sa_env" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=850000"
contains "opus ceiling: impl on Opus turns the hand-off guard on" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
check "opus ceiling: a real launch delivers exactly the profile share" "$(printf '%s\n' "$sa_env" | grep '^HIMMEL_WORKER_SESSION_CONTEXT_SHARE=')" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=87"
contains "opus ceiling: the share rides the launcher env token list into the konsole argv" "$sa_rec" " HIMMEL_WORKER_SESSION_CONTEXT_SHARE=87 "
not_contains "opus ceiling: no 1m suffix" "$sa_rec" "[1m]"
og_env="$sa_env"
sonnet_launch opus-eval worker-eval claude-opus-5-5
contains "opus ceiling: eval on Opus renders --autocompact 850000" "$sa_rec" "--autocompact 850000"
contains "opus ceiling: eval on Opus compacts" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
sonnet_launch opus-docs worker-docs claude-opus-5-5
contains "opus ceiling: a profile without Opus fields stays at --autocompact 200000" "$sa_rec" "--autocompact 200000"
not_contains "opus ceiling: a profile without Opus fields sets no guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
sonnet_launch opus-flag worker-impl claude-opus-5-5 "--context-guard compact"
contains "opus ceiling: an explicit --context-guard wins over the profile's" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
sonnet_launch opus-none worker-impl claude-opus-5-5 "--context-guard none"
not_contains "opus ceiling: --context-guard none turns the profile's guard off" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
contains "opus ceiling: --context-guard none keeps the ceiling" "$sa_rec" "--autocompact 850000"
sonnet_launch opus-sonnet worker-impl claude-sonnet-5-5
contains "opus ceiling: Sonnet on the same profile keeps 850000" "$sa_rec" "--autocompact 850000"
check "opus ceiling: Sonnet on the same profile keeps share 73" "$(printf '%s\n' "$sa_env" | grep '^HIMMEL_WORKER_SESSION_CONTEXT_SHARE=')" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
for ol in "or-opus:claude-opus-5-5:--lane openrouter" \
          "ds-opus:claude-opus-5-5:--lane deepseek" \
          "o4-opus:claude-opus-4-8:" \
          "bare-opus:opus:" \
          "fable-opus:claude-fable-5-1:"; do
  IFS=: read -r ol_tag ol_model ol_args <<< "$ol"
  sonnet_launch "$ol_tag" worker-impl "$ol_model" "$ol_args"
  check "opus ceiling: $ol_tag launches (exit 0)" "$sa_rc" "0"
  contains "opus ceiling: $ol_tag keeps --autocompact 200000" "$sa_rec" "--autocompact 200000"
  not_contains "opus ceiling: $ol_tag has no 850000" "$sa_rec" "850000"
  not_contains "opus ceiling: $ol_tag sets no context guard" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_MODE="
  not_contains "opus ceiling: $ol_tag sets no share" "$sa_env" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE="
done
sa_reg=""
# One dry-run row per lane and model, the ticket's proof: Opus moves, nothing else does.
for od in "claude-opus-5-5:native:850000:$sa_opus_doc" \
          "claude-sonnet-5-5:native:850000:$some_doc" \
          "claude-fable-5-1:native:200000:$sa_fable_doc" \
          "claude-opus-5-5:openrouter:200000:$sa_opus_doc"; do
  IFS=: read -r od_model od_lane od_want od_doc <<< "$od"
  rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$opus_reg" WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --profile worker-impl --lane "$od_lane" opus-dry-leg "$od_doc" /tmp/nosig 99999999999 /tmp/worker.log "$od_model" 2>&1)" || rc=$?
  check "opus ceiling dry-run: $od_model $od_lane: exit 0" "$rc" "0"
  contains "opus ceiling dry-run: $od_model $od_lane: ceiling $od_want" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=$od_want"
done
# An operator's sanctioned 1m keeps its meaning: auto, with the profile's guard and share gone.
sa_doc_1m_opus="$tmp/sa-1m-opus-doc.md"
fx_brief '# fixture brief' '> **Tier:** opus — design: multi-step design' '> **Context:** 1m — operator-ruling: fixture' > "$sa_doc_1m_opus"
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$opus_reg" WORKER_SESSION_CONTEXT=1m WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --profile worker-impl opus-dry-leg "$sa_doc_1m_opus" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "opus ceiling: 1m override: exit 0" "$rc" "0"
contains "opus ceiling: 1m override resolves auto" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=auto"
contains "opus ceiling: 1m override drops the profile's guard" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=<unset>"
contains "opus ceiling: 1m override drops the profile's share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
# An explicit A/B arm is a measurement of its own ceiling, so it wins over the Opus one.
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$opus_reg" WORKER_SESSION_CONTEXT='' WORKER_SESSION_REPO='' WORKER_SESSION_AUTOCOMPACT_AB=200000 bash "$SCRIPT" --dry-run --profile worker-impl opus-dry-leg "$sa_opus_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "opus ceiling: A/B control arm on Opus: exit 0" "$rc" "0"
contains "opus ceiling: A/B control arm keeps 200000" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
contains "opus ceiling: A/B control arm sets no guard" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=<unset>"
contains "opus ceiling: A/B control arm sets no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"

# The guard denies at its threshold: the env the launch above delivered, fed to the real
# hook. The HUD fixture is a real claude-hud snapshot from the station (2026-11-07), with
# only the numbers and time set.
og_val() { printf '%s\n' "$og_env" | sed -n "s/^HIMMEL_WORKER_SESSION_$1=//p" | head -1; }
og_cfg="$tmp/og-cfg"; og_dir="$tmp/og-handovers/u/himmel"
mkdir -p "$og_cfg/projects/p" "$og_cfg/plugins/claude-hud/context-cache" "$og_dir"
og_doc="$og_dir/PROJ-9482-N1-thing-2026-11-07.md"
og_tr="$og_cfg/projects/p/sess.jsonl"
printf -- '---\n---\n# brief\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE — fixture\n' > "$og_doc"
jq -cn --arg t "load $og_doc and continue" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}' > "$og_tr"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1}}}' >> "$og_tr"
if command -v sha256sum >/dev/null 2>&1; then og_sha="$(printf '%s' "$og_tr" | sha256sum | cut -d' ' -f1)"; else og_sha="$(printf '%s' "$og_tr" | shasum -a 256 | cut -d' ' -f1)"; fi
og_fill() {
  printf '{"used_percentage":%s,"remaining_percentage":%s,"current_usage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":4248,"cache_read_input_tokens":%s},"context_window_size":1000000,"saved_at":%s000,"session_name":"HIMMEL-nextleg-2026-11-07TT-roadmap-chief"}' \
    "$1" "$((100 - $1))" "$(($1 * 10000 - 4250))" "$(date +%s)" > "$og_cfg/plugins/claude-hud/context-cache/$og_sha.json"
}
og_hook="$(dirname "$SCRIPT")/../../hooks/guard-worker-context-handoff.sh"
og_tool="$(jq -cn --arg t "$og_tr" --arg w "$tmp" '{tool_name:"Bash",tool_input:{command:"make all"},transcript_path:$t,cwd:$w}')"
og_compact="$(jq -cn --arg t "$og_tr" --arg w "$tmp" '{hook_event_name:"PreCompact",trigger:"auto",transcript_path:$t,cwd:$w,session_id:"s"}')"
# og_run <json> <mode> <ceiling> <share> sets og_rc / og_err
og_run() {
  og_rc=0
  og_err="$(printf '%s' "$1" | env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u WORKER_SESSION_CONTEXT_HANDOFF_OK -u CONTEXT_FILL_TRANSCRIPT -u HIMMEL_WORKER \
    -u HIMMEL_WORKER_SESSION_CONTEXT_MODE -u HIMMEL_WORKER_SESSION_AUTOCOMPACT -u HIMMEL_WORKER_SESSION_CONTEXT_SHARE \
    HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=T-chief CLAUDE_CONFIG_DIR="$og_cfg" HANDOVER_DIR="$tmp/og-handovers" \
    ${2:+"HIMMEL_WORKER_SESSION_CONTEXT_MODE=$2"} "HIMMEL_WORKER_SESSION_AUTOCOMPACT=$3" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=$4" \
    bash "$og_hook" 2>&1 >/dev/null)" || og_rc=$?
}
og_mode="$(og_val CONTEXT_MODE)"; og_ceiling="$(og_val AUTOCOMPACT)"; og_share="$(og_val CONTEXT_SHARE)"
og_fill 73; og_run "$og_tool" "$og_mode" "$og_ceiling" "$og_share"
check "opus guard: at 730000 an ordinary call passes" "$og_rc" "0"
og_fill 74; og_run "$og_tool" "$og_mode" "$og_ceiling" "$og_share"
check "opus guard: at 740000 an ordinary call is denied" "$og_rc" "2"
contains "opus guard: the deny names the 74 % threshold" "$og_err" "threshold 74 %"
contains "opus guard: the deny names its basis" "$og_err" "87 % of the 850000-token autocompact ceiling on a 1000000-token window"
contains "opus guard: the deny names the hand-off" "$og_err" "mode handoff"
og_fill 74; og_run "$og_compact" "$og_mode" "$og_ceiling" "$og_share"
check "opus guard: an auto compaction at the threshold is refused until the hand-off" "$og_rc" "2"
og_fill 73; og_run "$og_compact" "$og_mode" "$og_ceiling" "$og_share"
check "opus guard: an auto compaction below the threshold passes" "$og_rc" "0"
# RED controls: the deny is the guard's and the share is what places it.
og_fill 74; og_run "$og_tool" "" "$og_ceiling" "$og_share"
check "opus guard control: with no mode the same call at 740000 passes" "$og_rc" "0"
og_fill 74; og_run "$og_tool" "$og_mode" "$og_ceiling" 88
check "opus guard control: share 88 would land at 750000, so 740000 passes" "$og_rc" "0"

# a caller passing an ALREADY-SUFFIXED model
# (claude-sonnet-5[1m]) under the DEFAULT (standard) context must still end
# up unsuffixed with --autocompact 200000 - the wrapper forwards the model
# unchanged, and it is headed-arm.sh's own contract (not this wrapper's)
# that strips a literal [1m] suffix regardless of --context; assert it
# holds end-to-end through the wrapper, not just inside headed-arm.sh's own
# suite.
d8b="$tmp/c8b"; mk_launch_stubs "$d8b" "PROJ-7777-worker"; mkdir -p "$tmp/repo8b"
rc=0
WORKER_SESSION_CONTEXT='' RUN_WORKER_ARGS=--no-profile run_worker "$d8b" "$tmp/repo8b" "PROJ-7777-worker" "claude-sonnet-5[1m]" >/dev/null 2>&1 || rc=$?
wait_record "$d8b" || true
rec8b="$(cat "$d8b/record" 2>/dev/null || true)"
check "full launch, default context, pre-suffixed model: exit 0" "$rc" "0"
contains "full launch, default context, pre-suffixed model: --autocompact 200000" "$rec8b" "--autocompact 200000"
not_contains "full launch, default context, pre-suffixed model: suffix stripped (headed-arm.sh's own contract)" "$rec8b" "claude-sonnet-5[1m]"

d9="$tmp/c9"; mk_launch_stubs "$d9" "PROJ-8888-worker"; mkdir -p "$tmp/repo9"
rc=0
WORKER_SESSION_CONTEXT=1m RUN_WORKER_ARGS=--no-profile run_worker "$d9" "$tmp/repo9" "PROJ-8888-worker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
rec9="$(cat "$d9/record" 2>/dev/null || true)"
check "full launch, WORKER_SESSION_CONTEXT=1m: refused with exit 2" "$rc" "2"
check "full launch, WORKER_SESSION_CONTEXT=1m: headed-arm was never invoked" "$rec9" ""

# --- 36 continued. full (non-dry) launch, sanctioned Context-line opt-in ----
# Inlined rather than run_worker (which is hardwired to $some_doc): the brief
# here must carry the well-formed Context line.
d9c="$tmp/c9c"; mk_launch_stubs "$d9c" "PROJ-6666-worker"; mkdir -p "$tmp/repo9c"
rc=0
IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d9c/konsole" PGREP_CMD="$d9c/pgrep" \
WORKER_SESSION_REPO="$tmp/repo9c" HEADED_ARM_LOCK_DIR="$d9c/locks" HEADED_ARM_PROC="$d9c/proc" \
WORKER_SESSION_CONTEXT=1m \
  bash "$SCRIPT" --no-profile "PROJ-6666-worker" "$doc_context_ok" "$d9c/signal-never" "$PAST" "$d9c/log" "claude-sonnet-4-6" >/dev/null 2>&1 || rc=$?
wait_record "$d9c" || true
rec9c="$(cat "$d9c/record" 2>/dev/null || true)"
env9c="$(cat "$d9c/env-record" 2>/dev/null || true)"
check "full launch, sanctioned Context line: exit 0" "$rc" "0"
contains "full launch, sanctioned Context line: --autocompact auto reaches konsole's argv" "$rec9c" "--autocompact auto"
contains "full launch, sanctioned Context line: model carries the [1m] suffix" "$rec9c" "claude-sonnet-4-6[1m]"
contains "full launch, sanctioned Context line: CHIEF_CONTEXT=1m reaches konsole's own env" "$env9c" "CHIEF_CONTEXT=1m"
not_contains "full launch, sanctioned Context line: internal autocompact requirement does not leak into the launched worker" "$env9c" "HEADED_ARM_REQUIRED_AUTOCOMPACT="
logline9c="$(cat "$d9c/log" 2>/dev/null || true)"
contains "full launch, sanctioned Context line: arm log records context=1m (operator-ruling)" "$logline9c" "context=1m (operator-ruling)"

# --- 10. IMPL_GUARD_OK reaches the konsole invocation's own environment ----
env8="$(cat "$d8/env-record" 2>/dev/null || true)"
not_contains "full launch, native: no added lane env" "$env8" "WORKER_SESSION_LANE="
not_contains "full launch, native: no added bank lane env" "$env8" "CADENCE_USAGE_LANE="
contains "full launch: IMPL_GUARD_OK=1 in the konsole invocation's env" "$env8" "IMPL_GUARD_OK=1"
contains "full launch: INLINE_IMPL_OK=1 in the konsole invocation's env" "$env8" "INLINE_IMPL_OK=1"
contains "full launch: HIMMEL_CONSOLE_LEG=1 in the konsole invocation's env" "$env8" "HIMMEL_CONSOLE_LEG=1"
not_contains "full launch: a plain worker carries no HIMMEL_CONSOLE_JUDGE" "$env8" "HIMMEL_CONSOLE_JUDGE="
not_contains "full launch: internal autocompact requirement does not leak into the launched worker" "$env8" "HEADED_ARM_REQUIRED_AUTOCOMPACT="

# --- 10b. Asserted absence on the REAL (non-dry) path: a
# chief armed with CHIEF_CONTEXT=1m in its own environ must not forward
# it into the konsole child's own process environment when it arms a worker -
# the live symptom this ticket fixes. Mirrors case 10's shape (env-record,
# not argv - CHIEF_CONTEXT never appears in argv either way, only in
# inherited env) so the control is on the same deterministic seam headed-arm's
# own suite already trusts, not a live /proc read.
d10b="$tmp/c10b"; mk_launch_stubs "$d10b" "PROJ-3139-worker"; mkdir -p "$tmp/repo10b"
rc=0
CHIEF_CONTEXT=1m WORKER_SESSION_CONTEXT='' RUN_WORKER_ARGS=--no-profile run_worker "$d10b" "$tmp/repo10b" "PROJ-3139-worker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d10b" || true
env10b="$(cat "$d10b/env-record" 2>/dev/null || true)"
check "full launch, ambient CHIEF_CONTEXT=1m: exit 0 (a worker is unaffected by it)" "$rc" "0"
not_contains "full launch, ambient CHIEF_CONTEXT=1m: absent from the konsole invocation's own env" "$env10b" "CHIEF_CONTEXT="

# --- 12. RED control: mutate the ACTUAL headed-arm launch renderer to drop
# --autocompact, then drive the wrapper's full non-dry path. The shared argv
# guard must refuse with exit 2 before konsole runs; this proves the policy is
# enforced on resolved launch argv rather than only on the wrapper's dry-run
# context report.
mutantdir="$tmp/mutant-headed-arm"
mkdir -p "$mutantdir/scripts/handover" "$mutantdir/scripts/lib"
mutant="$mutantdir/scripts/handover/headed-arm.sh"
# shellcheck disable=SC2016  # literal source-text mutation, not shell expansion
sed 's/ --autocompact "$AUTOCOMPACT"//' "$HEADED_ARM" > "$mutant"
cp "$HERE/../../lib/chief-context.sh" "$mutantdir/scripts/lib/chief-context.sh"
cp "$HERE/../../lib/claude-version.sh" "$mutantdir/scripts/lib/claude-version.sh"
cp "$HERE/../../lib/prim.sh" "$mutantdir/scripts/lib/prim.sh"
chmod 755 "$mutant"
d12="$tmp/c12"; mk_launch_stubs "$d12" "PROJ-4444-leg"; mkdir -p "$tmp/repo12"
mrc=0
mout="$(IMPL_GUARD_OK='' HEADED_ARM_WORKER_TARGET="$mutant" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d12/konsole" PGREP_CMD="$d12/pgrep" WORKER_SESSION_REPO="$tmp/repo12" \
  HEADED_ARM_LOCK_DIR="$d12/locks" HEADED_ARM_PROC="$d12/proc" \
  bash "$SCRIPT" --no-profile "PROJ-4444-leg" "some/doc.md" "$d12/signal-never" "$PAST" "$d12/log" "claude-sonnet-5" 2>&1)" || mrc=$?
check "RED control: renderer without --autocompact is refused on full launch path" "$mrc" "2"
contains "RED control: refusal names the missing resolved argv pair" "$mout" "resolved argv lacks --autocompact 200000"
check "RED control: konsole was never invoked" "$(cat "$d12/record" 2>/dev/null || true)" ""

# --- 13. SKIPPED-FLEET refuses the launch --------------------
# Points HEADED_ARM_WORKER_PREFLIGHT at the SKIPPED-FLEET stub instead of the
# PROCEED default every other full-launch case above uses. headed-arm.sh
# must never be invoked - no record file, no confirmable marker - so this
# does NOT use wait_record (which would poll out its full budget waiting for
# a write that should never happen); a bounded settle instead.
d13="$tmp/c13"; mk_launch_stubs "$d13" "PROJ-6666-worker"; mkdir -p "$tmp/repo13"
rc=0
run_worker "$d13" "$tmp/repo13" "PROJ-6666-worker" "claude-sonnet-5" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ "$rc" -ne 0 ]; then
  echo "ok - SKIPPED-FLEET: refuses the launch (exit $rc <> 0)"
else
  echo "FAIL - SKIPPED-FLEET: exit 0, expected a non-zero refusal"
  fails=$((fails+1))
fi
if [ -s "$d13/record" ]; then
  echo "FAIL - SKIPPED-FLEET: headed-arm.sh was invoked anyway (record file exists)"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-FLEET: headed-arm.sh was never invoked (no record file)"
fi
contains "SKIPPED-FLEET: log names the fleet cap and the bypass" \
  "$(cat "$d13/log" 2>/dev/null || true)" "FLEET_CAP_OK=1"

# --- 13b: SKIPPED-BANK refuses the launch ----
# Same shape as case 13, but points HEADED_ARM_WORKER_PREFLIGHT at the
# SKIPPED-BANK stub. Before the fix, headed-arm-worker.sh discarded every
# preflight_token other than SKIPPED-FLEET, so a bank-exhausted lane would
# fall through and launch anyway.
d13b="$tmp/c13b"; mk_launch_stubs "$d13b" "PROJ-5555-worker"; mkdir -p "$tmp/repo13b"
rc=0
HIMMEL_FLEET_SLOTS="$d13b/fleet-slots" run_worker "$d13b" "$tmp/repo13b" "PROJ-5555-worker" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ "$rc" -ne 0 ]; then
  echo "ok - SKIPPED-BANK: refuses the launch (exit $rc <> 0)"
else
  echo "FAIL - SKIPPED-BANK: exit 0, expected a non-zero refusal"
  fails=$((fails+1))
fi
if [ -s "$d13b/record" ]; then
  echo "FAIL - SKIPPED-BANK: headed-arm.sh was invoked anyway (record file exists)"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-BANK: headed-arm.sh was never invoked (no record file)"
fi
contains "SKIPPED-BANK: log names the bank exhaustion" \
  "$(cat "$d13b/log" 2>/dev/null || true)" "bank exhausted"

# --- 14. unknown --lane -> usage error, exit 2 ---------------
rc=0; out="$(bash "$SCRIPT" --lane bogus HIMMEL-x some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "unknown lane: exit 2" "$rc" "2"
contains "unknown lane: names the bad value" "$out" "unknown lane: bogus"

rc=0; out="$(WORKER_SESSION_LANE=bogus bash "$SCRIPT" HIMMEL-x some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "unknown lane via WORKER_SESSION_LANE: exit 2" "$rc" "2"

# --- 15. --dry-run --lane claudex: resolved launcher + env,
# default model gpt-6.1-sol, --lane wins over WORKER_SESSION_LANE. -----------------------
rc=0; out="$(WORKER_SESSION_LANE=native WORKER_SESSION_REPO='' bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --lane claudex: exit 0 (flag wins over WORKER_SESSION_LANE=native)" "$rc" "0"
contains "dry-run --lane claudex: reports lane=claudex" "$out" "lane=claudex"
contains "dry-run --lane claudex: resolved launcher names claude-codex" "$out" "claude-codex"
contains "dry-run --lane claudex: env carries CLAUDEX_LANE_OK=1" "$out" "CLAUDEX_LANE_OK=1"
contains "dry-run --lane claudex: resolved lane overrides ambient native" "$out" "WORKER_SESSION_LANE=claudex"
contains "dry-run --lane claudex: bank lane is claudex" "$out" "CADENCE_USAGE_LANE=claudex"
contains "dry-run --lane claudex: env carries CLAUDE_CODE_EFFORT_LEVEL=xhigh default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=xhigh"
contains "dry-run --lane claudex: MODEL defaults to gpt-6.1-sol" "$out" "gpt-6.1-sol"

rc=0; out="$(CADENCE_USAGE_LANE=native HEADED_ARM_LAUNCHER_ENV='WORKER_SESSION_LANE=native CADENCE_USAGE_LANE=native' bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "claudex: stale caller lane tokens do not refuse launch" "$rc" "0"
contains "claudex: resolved lane replaces stale launcher token" "$out" "WORKER_SESSION_LANE=claudex"
contains "claudex: resolved bank replaces stale launcher token" "$out" "CADENCE_USAGE_LANE=claudex"
not_contains "claudex: stale lane token is absent" "$out" "WORKER_SESSION_LANE=native"
not_contains "claudex: stale bank token is absent" "$out" "CADENCE_USAGE_LANE=native"
rc=0; out="$(CADENCE_USAGE_LANE=native HEADED_ARM_LAUNCHER_ENV='CADENCE_USAGE_LANE=native' bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "claudex: a stale CADENCE_USAGE_LANE token does not refuse launch" "$rc" "0"
contains "claudex: the resolved bank lane is propagated" "$out" "CADENCE_USAGE_LANE=claudex"
not_contains "claudex: the stale usage lane token is dropped" "$out" "CADENCE_USAGE_LANE=native"

rc=0; out="$(WORKER_SESSION_EFFORT=high bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
contains "dry-run --lane claudex: WORKER_SESSION_EFFORT overrides the xhigh default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"

rc=0; out="$(env -u UNGUARDED_LAUNCH_OK -u HIMMEL_POLICY_FOLLOWS_HOME WORKER_SESSION_REPO="$guarded_repo" CLAUDE_CODE_EFFORT_LEVEL=medium bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --lane claudex: an explicit CLAUDE_CODE_EFFORT_LEVEL exits 0" "$rc" "0"
contains "dry-run --lane claudex: an explicit CLAUDE_CODE_EFFORT_LEVEL overrides the xhigh default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=medium"
not_contains "dry-run --lane claudex: an explicit CLAUDE_CODE_EFFORT_LEVEL is not replaced by xhigh" "$out" "CLAUDE_CODE_EFFORT_LEVEL=xhigh"
rc=0; out="$(env -u UNGUARDED_LAUNCH_OK -u HIMMEL_POLICY_FOLLOWS_HOME WORKER_SESSION_REPO="$guarded_repo" CLAUDE_CODE_EFFORT_LEVEL=medium WORKER_SESSION_EFFORT=high bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "dry-run --lane claudex: an explicit CLAUDE_CODE_EFFORT_LEVEL with WORKER_SESSION_EFFORT exits 0" "$rc" "0"
contains "dry-run --lane claudex: an explicit CLAUDE_CODE_EFFORT_LEVEL wins over WORKER_SESSION_EFFORT" "$out" "CLAUDE_CODE_EFFORT_LEVEL=medium"

rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "claude-sonnet-5"
not_contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "gpt-6.1-sol"

# scripts/claude-codex reads only CODEX_MODEL, so the model the chief names
# has to reach the launcher as CODEX_MODEL.
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log gpt-6-astra 2>&1)" || rc=$?
contains "dry-run --lane claudex: a named model reaches the launcher as CODEX_MODEL" "$out" "CODEX_MODEL=gpt-6-astra"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
contains "dry-run --lane claudex: no model names the default as CODEX_MODEL" "$out" "CODEX_MODEL=gpt-6.1-sol"
rc=0; out="$(HEADED_ARM_LAUNCHER_ENV='CODEX_MODEL=preset-model' bash "$SCRIPT" --dry-run --no-profile --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log gpt-6-astra 2>&1)" || rc=$?
contains "dry-run --lane claudex: an inherited CODEX_MODEL token is scrubbed, the named model wins" "$out" "CODEX_MODEL=gpt-6-astra"
not_contains "dry-run --lane claudex: an inherited CODEX_MODEL token does not survive" "$out" "CODEX_MODEL=preset-model"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
not_contains "dry-run, native lane: CODEX_MODEL is never set" "$out" "CODEX_MODEL"

# A claudex worker-impl worker gets the native worker's knowledge access: the same profile
# settings, MCP allowlist (qmd), lean switch and handover root.
_access_env() { printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^(WORKER_SESSION_PROFILE_SETTINGS|WORKER_SESSION_PROFILE_MCP_CONFIG|HIMMEL_LEAN_WORKER_SESSION|HANDOVER_DIR)=' | sort; }
rc=0; out_n="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 2>&1)" || rc=$?
rc_x=0; out_x="$(bash "$SCRIPT" --dry-run --profile worker-impl --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc_x=$?
check "dry-run --profile worker-impl: native and claudex both exit 0" "$rc/$rc_x" "0/0"
contains "dry-run --profile worker-impl --lane claudex: carries the qmd and himmel-bus MCP allowlist" "$out_x" 'mcp=["qmd","himmel-bus"] mcp-config=/tmp/PROJ-9999-leg.leg-mcp.json'
check "dry-run --profile worker-impl: claudex access env equals native" "$(_access_env "$out_x")" "$(_access_env "$out_n")"

rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run, no --lane: reports lane=native" "$out" "lane=native"
not_contains "dry-run, no --lane: no claude-codex launcher" "$out" "claude-codex"
not_contains "dry-run, native: no added lane env" "$out" "WORKER_SESSION_LANE="
not_contains "dry-run, native: no added bank lane env" "$out" "CADENCE_USAGE_LANE="
not_contains "dry-run, native: no added usage lane env" "$out" "CADENCE_USAGE_LANE="

# a lane typo, missing model mapping or dropped backend must
# never silently start a native/subscription session. Dry runs make no calls.
rc=0; out="$(WORKER_SESSION_LANE=native bash "$SCRIPT" --dry-run --no-profile --lane openrouter PROJ-9999-or "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/or.log" 2>&1)" || rc=$?
check "openrouter: flag selects lane" "$rc" "0"
contains "openrouter: lane reported" "$out" "lane=openrouter"
contains "openrouter: bank lane remains openrouter" "$out" "CADENCE_USAGE_LANE=openrouter"
contains "openrouter: default Sonnet slug pinned" "$out" "OPENROUTER_MODEL=anthropic/claude-sonnet-5.5"
contains "openrouter: backend is claude-openrouter" "$out" "claude-openrouter"
contains "openrouter: alias route uses sonnet" "$out" " sonnet "
contains "openrouter: recorder enabled" "$out" "recorder=1"
rc=0; out="$(WORKER_SESSION_LANE=openrouter bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-or "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/or.log" claude-sonnet-5-5 2>&1)" || rc=$?
check "openrouter: ambient lane composes with profile" "$rc" "0"
contains "openrouter: Claude id mapped" "$out" "OPENROUTER_MODEL=anthropic/claude-sonnet-5.5"
contains "openrouter: profile retains backend" "$out" "WORKER_SESSION_CLAUDE_BIN="
for bad_or_model in claude-haiku-4-5 gpt-6.1-sol claude-sonnet-99-9 anthropic/claude-haiku-4.5; do
  rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane openrouter PROJ-9999-or "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/or.log" "$bad_or_model" 2>&1)" || rc=$?
  check "openrouter: refuses unsupported $bad_or_model" "$rc" "2"
  contains "openrouter: refusal explains model mapping" "$out" "OpenRouter model"
done

# lane registry. deepseek is admitted with its own
# launcher, the launcher's own default model and WORKER_SESSION_LANE=deepseek; glm is a
# registry row that refuses until it has a launcher contract; unknown stays 2.
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane deepseek PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: registry admits the lane" "$rc" "0"
contains "deepseek: lane reported" "$out" "lane=deepseek"
contains "deepseek: launcher is claude-deepseek" "$out" "claude-deepseek"
contains "deepseek: WORKER_SESSION_LANE exported" "$out" "WORKER_SESSION_LANE=deepseek"
contains "deepseek: bank lane keeps openrouter mapping" "$out" "CADENCE_USAGE_LANE=openrouter"
contains "deepseek: recorder enabled" "$out" "recorder=1"
not_contains "deepseek: no codex env" "$out" "CLAUDEX_LANE_OK"
ds_stub="$tmp/ds-stub"; printf "#!/bin/sh\nexport ANTHROPIC_MODEL='stub-model'\nexit 0\n" > "$ds_stub"; chmod +x "$ds_stub"
rc=0; out="$(HEADED_ARM_WORKER_DEEPSEEK_BIN="$ds_stub" bash "$SCRIPT" --dry-run --no-profile --lane deepseek PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: launcher seam honoured" "$rc" "0"
contains "deepseek: seam path is the exec target" "$out" "exec-target=$ds_stub"
contains "deepseek: seam launcher's model is the default" "$out" " stub-model "
printf '#!/bin/sh\nexport ANTHROPIC_MODEL=bare-model\nexit 0\n' > "$ds_stub"
rc=0; out="$(HEADED_ARM_WORKER_DEEPSEEK_BIN="$ds_stub" bash "$SCRIPT" --dry-run --no-profile --lane deepseek PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: bare export is read" "$rc" "0"
contains "deepseek: bare export value is the default" "$out" " bare-model "
printf '#!/bin/sh\nexport ANTHROPIC_MODEL="dq-model[1m]"\nexit 0\n' > "$ds_stub"
rc=0; out="$(HEADED_ARM_WORKER_DEEPSEEK_BIN="$ds_stub" bash "$SCRIPT" --dry-run --no-profile --lane deepseek PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: double-quoted export is read" "$rc" "0"
contains "deepseek: double-quoted value is the default, quotes stripped" "$out" " dq-model[1m] "
printf '#!/bin/sh\nexit 0\n' > "$ds_stub"
rc=0; out="$(HEADED_ARM_WORKER_DEEPSEEK_BIN="$ds_stub" bash "$SCRIPT" --dry-run --no-profile --lane deepseek PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: launcher without a model export fails closed" "$rc" "2"
contains "deepseek: fail-closed names the missing export" "$out" "no default model"
rc=0; out="$(WORKER_SESSION_LANE=deepseek bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-ds "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/ds.log" 2>&1)" || rc=$?
check "deepseek: ambient lane composes with profile" "$rc" "0"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane glm PROJ-9999-glm "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/glm.log" 2>&1)" || rc=$?
check "glm: refused until it has a launcher" "$rc" "2"
contains "glm: refusal says why" "$out" "no launcher contract yet"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane bogus PROJ-9999-x "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/x.log" 2>&1)" || rc=$?
check "registry: unknown lane still exits 2" "$rc" "2"

# Actual backend boundary: curl and Claude are hermetic executables. These
# checks catch overwritten pins, missing labels and a first-action billing dialog.
or_home="$tmp/or-home"; or_bin="$tmp/or-bin"
mkdir -p "$or_home/.claude-openrouter" "$or_bin"
: > "$or_home/.claude-openrouter/.seeded"
printf '%s' '{"keep":"preserved","projects":{"/other":{"hasTrustDialogAccepted":false}}}' > "$or_home/.claude-openrouter/.claude.json"
cat > "$or_bin/claude" <<'OR_CLAUDE'
#!/usr/bin/env bash
for v in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME ANTHROPIC_DEFAULT_SONNET_MODEL_NAME ANTHROPIC_DEFAULT_OPUS_MODEL_NAME CLAUDE_CODE_AUTO_MODE_SERVER; do
    eval 'printf "%s=%s\\n" "$v" "${'"$v"'-}"'
done
OR_CLAUDE
cat > "$or_bin/curl" <<'OR_CURL'
#!/usr/bin/env bash
cat >/dev/null
for last in "$@"; do :; done
case "$last" in
    */key) if [ -n "${OR_KEY_BODY:-}" ]; then printf '%s' "$OR_KEY_BODY"; else printf '%s' '{"data":{"limit":25,"limit_remaining":12}}'; fi ;;
    *) if [ -n "${OR_CREDIT_BODY:-}" ]; then printf '%s' "$OR_CREDIT_BODY"; else printf '%s' '{"data":{"total_credits":20,"total_usage":1}}'; fi ;;
esac
OR_CURL
chmod 755 "$or_bin/claude" "$or_bin/curl"
# These fixtures check defaults, not ambient operator overrides.
unset OPENROUTER_HAIKU OPENROUTER_SONNET OPENROUTER_OPUS
printf '%s' '{"providers":{"openrouter":{}},"rules":[{"corpus":"*","provider":"openrouter","purpose":"inference","verdict":"allow"}]}' > "$tmp/or-matrix.json"
rc=0; out="$(HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 OPENROUTER_HAIKU=wrong CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
check "openrouter backend: invalid tier refuses" "$rc" "2"
contains "openrouter backend: invalid tier diagnostic" "$out" "unknown or malformed OPENROUTER_HAIKU"
not_contains "openrouter backend: invalid tier never executes Claude" "$out" 'ANTHROPIC_MODEL=sonnet'
rc=0; out="$(HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
check "openrouter backend: launches stub" "$rc" "0"
contains "openrouter backend: model alias Sonnet" "$out" "ANTHROPIC_MODEL=sonnet"
contains "openrouter backend: HAIKU model independent" "$out" "ANTHROPIC_DEFAULT_HAIKU_MODEL=anthropic/claude-haiku-5.5"
contains "openrouter backend: HAIKU label" "$out" "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME=anthropic/claude-haiku-5.5"
contains "openrouter backend: SONNET model pinned" "$out" "ANTHROPIC_DEFAULT_SONNET_MODEL=anthropic/claude-sonnet-5.5"
contains "openrouter backend: SONNET label" "$out" "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME=Sonnet 5.5 (OpenRouter)"
contains "openrouter backend: OPUS model independent" "$out" "ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic/claude-opus-5.5"
contains "openrouter backend: OPUS label" "$out" "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME=anthropic/claude-opus-5.5"
contains "openrouter backend: client auto classifier" "$out" "CLAUDE_CODE_AUTO_MODE_SERVER=0"
contains "openrouter backend: credit and cap minimum logged" "$out" "effective balance \$12.00 (key limit_remaining)"

# Seed only the primary checkout trust, preserving every unrelated field.
or_primary="$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")"
check "openrouter onboarding: completed" "$(jq -r '.hasCompletedOnboarding' "$or_home/.claude-openrouter/.claude.json")" "true"
check "openrouter onboarding: primary root trusted" "$(jq -r --arg root "$or_primary" '.projects[$root].hasTrustDialogAccepted' "$or_home/.claude-openrouter/.claude.json")" "true"
check "openrouter onboarding: unrelated top-level data preserved" "$(jq -r '.keep' "$or_home/.claude-openrouter/.claude.json")" "preserved"
check "openrouter onboarding: unrelated trust preserved" "$(jq -r '.projects["/other"].hasTrustDialogAccepted' "$or_home/.claude-openrouter/.claude.json")" "false"
or_mtime="$(node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$or_home/.claude-openrouter/.claude.json")"
rc=0; out="$(HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
check "openrouter onboarding: second launch succeeds" "$rc" "0"
check "openrouter onboarding: second launch does not rewrite config" "$(node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$or_home/.claude-openrouter/.claude.json")" "$or_mtime"
rc=0; out="$(GIT_DIR="$tmp/not-a-git-dir" GIT_COMMON_DIR="$tmp/not-a-git-common-dir" HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
check "openrouter onboarding: poisoned Git env cannot steer trust lookup" "$rc" "0"

# The real backend child boundary must refuse before executing Claude,
# even though the headed parent's fleet/subscription preflight proceeded.
for or_case in low-credit exhausted-key unknown-credit unknown-cap; do
    or_credit_body='{"data":{"total_credits":20,"total_usage":1}}'
    or_key_body='{"data":{"limit":25,"limit_remaining":12}}'
    case "$or_case" in
        low-credit) or_credit_body='{"data":{"total_credits":20,"total_usage":18}}' ;;
        exhausted-key) or_key_body='{"data":{"limit":25,"limit_remaining":0}}' ;;
        unknown-credit) or_credit_body='not-json' ;;
        unknown-cap) or_key_body='not-json' ;;
    esac
    rc=0; out="$(HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter \
      OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 \
      OR_CREDIT_BODY="$or_credit_body" OR_KEY_BODY="$or_key_body" \
      CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" \
      bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
    check "openrouter backend: $or_case refuses" "$rc" "5"
    not_contains "openrouter backend: $or_case never executes Claude" "$out" 'ANTHROPIC_MODEL=sonnet'
done
or_valid_config="$(cat "$or_home/.claude-openrouter/.claude.json")"
printf '%s' 'not-json' > "$or_home/.claude-openrouter/.claude.json"
rc=0; out="$(HOME="$or_home" PATH="$or_bin:$PATH" WORKER_SESSION_LANE=openrouter \
  OPENROUTER_API_KEY=hermetic-fixture OPENROUTER_MODEL=anthropic/claude-sonnet-5.5 \
  CLAUDE_OPENROUTER_EGRESS_MATRIX="$tmp/or-matrix.json" \
  bash "$HERE/../../claude-openrouter" --model sonnet 2>&1)" || rc=$?
check "openrouter trust: malformed lane config refuses" "$rc" "4"
check "openrouter trust: malformed config is preserved" "$(cat "$or_home/.claude-openrouter/.claude.json")" 'not-json'
not_contains "openrouter trust: malformed config never executes Claude" "$out" 'ANTHROPIC_MODEL=sonnet'
printf '%s' "$or_valid_config" > "$or_home/.claude-openrouter/.claude.json"

# Slugs must not bypass the existing premium-tier dispatch permission.
for premium_or in anthropic/claude-opus-5.5 anthropic/claude-fable-5.1; do
  rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane openrouter PROJ-9999-or "$some_doc" "$tmp/no-signal" "$PAST" "$tmp/or.log" "$premium_or" 2>&1)" || rc=$?
  check "openrouter: premium slug $premium_or needs Tier reason" "$rc" "2"
  contains "openrouter: premium refusal names Tier" "$out" "Tier:"
done

# Full arm path must carry the same backend, preface, alias and recorder.
d_or="$tmp/or-arm"; mk_launch_stubs "$d_or" "PROJ-9999-or-arm"
mkdir -p "$tmp/or-repo"
rc=0
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_OPENROUTER_BIN="$HERE/../../claude-openrouter" \
KONSOLE_CMD="$d_or/konsole" PGREP_CMD="$d_or/pgrep" WORKER_SESSION_REPO="$tmp/or-repo" \
HEADED_ARM_LOCK_DIR="$d_or/locks" HEADED_ARM_PROC="$d_or/proc" \
  bash "$SCRIPT" --lane openrouter --profile worker-impl PROJ-9999-or-arm "$some_doc" "$d_or/no-signal" "$PAST" "$d_or/log" >/dev/null 2>&1 || rc=$?
wait_record "$d_or" || true
check "openrouter arm: exit 0" "$rc" "0"
rec_or="$(cat "$d_or/record" 2>/dev/null || true)"
contains "openrouter arm: recorder uses log" "$rec_or" "script -q -a -f $d_or/log -c"
contains "openrouter arm: alias argv" "$rec_or" "--model sonnet"
contains "openrouter arm: pinned slug reaches child" "$rec_or" "OPENROUTER_MODEL=anthropic/claude-sonnet-5.5"
contains "openrouter arm: backend retained" "$(cat "$d_or/env-record" 2>/dev/null || true)" "WORKER_SESSION_CLAUDE_BIN=$HERE/../../claude-openrouter"
contains "openrouter arm: namespace channel appended" "$(cat "$d_or/PROJ-9999-or-arm.worker-preface.md" 2>/dev/null || true)" "# OpenRouter coordination"

# --- 16. full (non-dry) launch, --lane claudex: proves the
# non-dry path builds the argv --dry-run predicted, via headed-arm.sh's real
# HEADED_ARM_LAUNCHER/HEADED_ARM_LAUNCHER_ENV/HEADED_ARM_RECORDER seams. A
# stub claude-codex binary on the HEADED_ARM_WORKER_CLAUDEX_BIN seam stands in
# for the real scripts/claude-codex (the konsole stub never actually execs
# the recorded command, so the stub need not run - only its path needs to
# reach the recorded argv, same reasoning as headed-arm.sh's own suite).

d16="$tmp/c16"; mk_launch_stubs "$d16" "PROJ-5555-worker"; mkdir -p "$tmp/repo16"
rc=0
IMPL_GUARD_OK='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
HEADED_ARM_WORKER_CLAUDEX_BIN="$claudex_stub" \
KONSOLE_CMD="$d16/konsole" PGREP_CMD="$d16/pgrep" \
WORKER_SESSION_REPO="$tmp/repo16" HEADED_ARM_LOCK_DIR="$d16/locks" HEADED_ARM_PROC="$d16/proc" \
  bash "$SCRIPT" --lane claudex --no-profile "PROJ-5555-worker" "some/doc.md" "$d16/signal-never" "$PAST" "$d16/log" >/dev/null 2>&1 || rc=$?
wait_record "$d16" || true
rec16="$(cat "$d16/record" 2>/dev/null || true)"
check "full launch, --lane claudex: exit 0" "$rc" "0"
contains "full launch, --lane claudex: wrapped in script(1) with the SAME log path, appending (-a)" "$rec16" "script -q -a -f $d16/log -c"
contains "full launch, --lane claudex: the preface shim reaches the recorded argv" "$rec16" "worker-claude-launcher.sh"
contains "full launch, --lane claudex: the shim retains the claudex backend" \
  "$(cat "$d16/env-record" 2>/dev/null || true)" "WORKER_SESSION_CLAUDE_BIN=$claudex_stub"
not_contains "full launch, --lane claudex: launcher not force-wrapped in bash (execs via its own shebang)" "$rec16" "bash $claudex_stub"
contains "full launch, --lane claudex: --model defaults to gpt-6.1-sol" "$rec16" "--model gpt-6.1-sol"
contains "full launch, --lane claudex: --autocompact 200000 (standard context ceiling)" "$rec16" "--autocompact 200000"
contains "full launch, --lane claudex: CLAUDEX_LANE_OK=1 reaches the konsole argv" "$rec16" "CLAUDEX_LANE_OK=1"
contains "full launch, --lane claudex: lane reaches launcher argv" "$rec16" "WORKER_SESSION_LANE=claudex"
contains "full launch, --lane claudex: bank lane reaches launcher argv" "$rec16" "CADENCE_USAGE_LANE=claudex"
env16="$(cat "$d16/env-record" 2>/dev/null || true)"
contains "full launch, --lane claudex: lane reaches child env" "$env16" "WORKER_SESSION_LANE=claudex"
contains "full launch, --lane claudex: bank lane reaches child env" "$env16" "CADENCE_USAGE_LANE=claudex"
contains "full launch, --lane claudex: CLAUDE_CODE_EFFORT_LEVEL=xhigh reaches the konsole argv" "$rec16" "CLAUDE_CODE_EFFORT_LEVEL=xhigh"
contains "full launch, --lane claudex: CODEX_MODEL=gpt-6.1-sol reaches the konsole argv" "$rec16" "CODEX_MODEL=gpt-6.1-sol"
contains "full launch, --lane claudex: CODEX_MODEL reaches child env" "$env16" "CODEX_MODEL=gpt-6.1-sol"

# --- 17. --profile <name>: a plugin profile + the standing worker
# preface, applied WITHOUT editing headed-arm.sh. headed-arm.sh builds a fixed
# claude argv with no pass-through for extra flags, so the only seam is its
# launcher binary: --profile points HEADED_ARM_LAUNCHER at
# scripts/lanes/worker-claude-launcher.sh, which prepends --settings and
# --append-system-prompt-file and execs the real claude. Three things must
# hold, and each is a separate case below: the child really does get both
# flags; omitting --profile changes nothing; and --profile on --lane claudex
# composes both launchers rather than silently losing one.

# 17a. The shim itself, driven directly: this is the only place the CHILD
# cmdline is observable (the konsole stub records the launch command but never
# execs it), so it is where "the child carries both flags" is actually proven.
shim_rec="$tmp/shim-claude"
# shellcheck disable=SC2016 # literal $* belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$(dirname "$0")/shim-record"' > "$shim_rec"
chmod 755 "$shim_rec"
: > "$tmp/settings.json"
: > "$tmp/preface.md"
rc=0
WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_SETTINGS="$tmp/settings.json" WORKER_SESSION_PROFILE_PREFACE="$tmp/preface.md" \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg "load doc" || rc=$?
shimout="$(cat "$tmp/shim-record" 2>/dev/null || true)"
check "shim: exit 0" "$rc" "0"
check "shim: prepends both flags and preserves the rest of argv in order" "$shimout" \
  "--settings $tmp/settings.json --append-system-prompt-file $tmp/preface.md --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg load doc"

# The transparency control: with no profile env set the shim must be a
# pass-through, byte for byte. A shim that reordered or dropped --model or
# --autocompact here would defeat the ceiling guard the rest of this suite
# exists to enforce.
rm -f "$tmp/shim-record"
rc=0
WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg "load doc" || rc=$?
check "shim: no profile env -> argv byte-identical (transparent exec)" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg load doc"

# Fail closed: a settings path that does not exist must refuse, not launch a
# worker with the full plugin roster while the log says it was profiled.
rc=0
out="$(WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_SETTINGS="$tmp/no-such-settings.json" bash "$SHIM" --model x 2>&1)" || rc=$?
check "shim: a missing settings file refuses with exit 2" "$rc" "2"
contains "shim: refusal names the missing file" "$out" "$tmp/no-such-settings.json"

# 17b. Full (non-dry) launch with --profile: the shim is what headed-arm.sh
# renders as the launcher, the resolved settings JSON is written next to the
# launch log, and HIMMEL_LEAN_WORKER_SESSION=1 reaches the launched process's own
# environment (that is what silences the advisory SessionStart hooks).
d17="$tmp/c17"; mk_launch_stubs "$d17" "PROJ-3333-leg"; mkdir -p "$tmp/repo17"
rc=0
IMPL_GUARD_OK='' HIMMEL_LEAN_WORKER_SESSION='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17/konsole" PGREP_CMD="$d17/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17" HEADED_ARM_LOCK_DIR="$d17/locks" HEADED_ARM_PROC="$d17/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-leg" "$some_doc" "$d17/signal-never" "$PAST" "$d17/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17" || true
rec17="$(cat "$d17/record" 2>/dev/null || true)"
env17="$(cat "$d17/env-record" 2>/dev/null || true)"
check "full launch --profile: exit 0" "$rc" "0"
contains "full launch --profile: the launcher is the profile shim" "$rec17" "worker-claude-launcher.sh"
contains "full launch --profile: the ceiling guard still holds (worker-impl on Sonnet is 850000)" "$rec17" "--autocompact 850000"
contains "full launch --profile: HIMMEL_LEAN_WORKER_SESSION=1 reaches the launched environment" "$env17" "HIMMEL_LEAN_WORKER_SESSION=1"
contains "full launch --profile: the shim is told where the settings live" "$env17" "WORKER_SESSION_PROFILE_SETTINGS=$d17/PROJ-3333-leg.leg-settings.json"
if [ -s "$d17/PROJ-3333-leg.leg-settings.json" ]; then
  echo "ok - full launch --profile: settings JSON written next to the launch log"
else
  echo "FAIL - full launch --profile: no settings JSON next to the launch log"; fails=$((fails+1))
fi
contains "full launch --profile: the settings JSON is a real enabledPlugins map" \
  "$(cat "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null || true)" "enabledPlugins"

# 17b-2. A native-lane --profile
# launch's per-worker <name>.worker-preface.md is docs/handover/worker-preface.md
# only - the brief's own contract no longer rides it (2990 moved that to
# <name>.worker-contract.md, re-injected by the compact hook; see 17b-3 below).
# Real (non-dry) launch, same stub shape as 17b - this is the writer of the
# file, not the shim (the shim only fails closed if it is missing).
d17b="$tmp/c17b"; mk_launch_stubs "$d17b" "PROJ-9999-red"; mkdir -p "$tmp/repo17b"
fixture17b="$tmp/fixture-brief.md"
cat > "$fixture17b" <<'FIXTURE_EOF'
# PROJ-9999 - fixture brief

> **Prior art:** none found (qmd -c jira-himmel "fixture")

**Contract:**
1. Do the thing the ticket asks for.

## Results (newest at the bottom)

- 00:00 this bullet must never reach the system-prompt preface.
FIXTURE_EOF
anchor7795="$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")"
rc=0
HIMMEL_REPO="$anchor7795" \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b/konsole" PGREP_CMD="$d17b/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b" HEADED_ARM_LOCK_DIR="$d17b/locks" HEADED_ARM_PROC="$d17b/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-red" "$fixture17b" "$d17b/signal-never" "$PAST" "$d17b/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b" || true
check "brief-preface: full launch exit 0" "$rc" "0"
preface17b="$d17b/PROJ-9999-red.worker-preface.md"
if [ -s "$preface17b" ]; then
  echo "ok - brief-preface: <name>.worker-preface.md written next to the launch log"
else
  echo "FAIL - brief-preface: no worker-preface.md next to the launch log"; fails=$((fails+1))
fi
prefacecontent17b="$(cat "$preface17b" 2>/dev/null || true)"
contains "brief-preface: carries the standing worker-preface heading" "$prefacecontent17b" \
  "$(head -1 "$HERE/../../../docs/handover/worker-preface.md")"
# on an adapter repo merge-on-green.sh refuses; the worker stops at READY.
contains "brief-preface: adapter worker stops at READY" "$prefacecontent17b" \
  "Adapter repo: you stop at \`READY\`."
contains "brief-preface: adapter chief merges with merge-fork-pr.sh" "$prefacecontent17b" \
  "the chief merges with \`merge-fork-pr.sh\`"
# a "system is running low on memory" background-task kill is not
# proof of memory pressure; the worker's system prompt tells it to read the
# pressure file and the cgroup's memory.events before believing one.
contains "brief-preface: names the low-memory kill" "$prefacecontent17b" \
  "running low on memory"
contains "brief-preface: says to read /proc/pressure/memory before believing it" \
  "$prefacecontent17b" "/proc/pressure/memory"
contains "brief-preface: says to read the cgroup memory.events before believing it" \
  "$prefacecontent17b" "memory.events"
# the Opus 5.5 guide's standing "how turns end" instruction goes
# at the END of the system prompt, so it must be the preface's last section.
check "brief-preface: last section is the standing turn-ending instruction" \
  "$(printf '%s\n' "$prefacecontent17b" | grep '^## ' | tail -1)" "## How your turns end"
contains "brief-preface: holding for GO stays a sanctioned stop" \
  "$prefacecontent17b" "holding for the chief's \`GO\` after \`READY\`"
not_contains "brief-preface: does NOT carry the fixture's Contract line" \
  "$prefacecontent17b" "**Contract:**"
not_contains "brief-preface: does NOT carry the Results tail" "$prefacecontent17b" \
  "this bullet must never reach the system-prompt preface"

# A worker on an adopted repo copies the preface's ship steps from
# a cwd that is not a himmel checkout, so the relative `bash scripts/...` forms
# do not resolve there. The adopter preface names the himmel anchor's absolute
# scripts; a worker in a himmel checkout keeps the relative form (the gate
# guards demand it).
not_contains "adopter preface: no bare relative 'bash scripts/cr/' ship step" \
  "$prefacecontent17b" "bash scripts/cr/"
not_contains "adopter preface: no bare relative 'bash scripts/quiet-run.sh'" \
  "$prefacecontent17b" "bash scripts/quiet-run.sh"
contains "adopter preface: gate scripts name the anchor's absolute path" \
  "$prefacecontent17b" "bash $anchor7795/scripts/cr/"
contains "adopter preface: quiet-run names the anchor's absolute path" \
  "$prefacecontent17b" "bash $anchor7795/scripts/quiet-run.sh"
contains "adopter preface: check-ci names the anchor's absolute path" \
  "$prefacecontent17b" "$anchor7795/scripts/check-ci.sh"
contains "adopter preface: already-anchored <anchor>/scripts form is untouched" \
  "$prefacecontent17b" "bash <anchor>/scripts/cr/clear-review-marker.sh"
d17h="$tmp/c17h"; mk_launch_stubs "$d17h" "PROJ-9999-himmelcwd"
rc=0
HIMMEL_REPO="$anchor7795" \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17h/konsole" PGREP_CMD="$d17h/pgrep" \
WORKER_SESSION_REPO="$(cd "$HERE/../../.." && pwd)" HEADED_ARM_LOCK_DIR="$d17h/locks" HEADED_ARM_PROC="$d17h/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-himmelcwd" "$fixture17b" "$d17h/signal-never" "$PAST" "$d17h/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17h" || true
check "himmel-cwd preface: full launch exit 0" "$rc" "0"
prefacecontent17h="$(cat "$d17h/PROJ-9999-himmelcwd.worker-preface.md" 2>/dev/null || true)"
contains "himmel-cwd preface: the relative gate-script form is unchanged" \
  "$prefacecontent17h" "bash scripts/cr/"
not_contains "himmel-cwd preface: no absolute rewrite of quiet-run" \
  "$prefacecontent17h" "bash $anchor7795/scripts/quiet-run.sh"
d17s="$tmp/c17s"; mk_launch_stubs "$d17s" "PROJ-9999-subdir"
rc=0
HIMMEL_REPO="$anchor7795" \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17s/konsole" PGREP_CMD="$d17s/pgrep" \
WORKER_SESSION_REPO="$HERE" HEADED_ARM_LOCK_DIR="$d17s/locks" HEADED_ARM_PROC="$d17s/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-subdir" "$fixture17b" "$d17s/signal-never" "$PAST" "$d17s/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17s" || true
check "himmel-subdirectory preface: full launch exit 0" "$rc" "0"
prefacecontent17s="$(cat "$d17s/PROJ-9999-subdir.worker-preface.md" 2>/dev/null || true)"
contains "himmel-subdirectory preface: quiet-run names the anchor's absolute path" \
  "$prefacecontent17s" "bash $anchor7795/scripts/quiet-run.sh"
not_contains "himmel-subdirectory preface: no bare relative 'bash scripts/cr/'" \
  "$prefacecontent17s" "bash scripts/cr/"

# --- 17b-3. 2985's per-call preface concatenation is replaced:
# the brief's own contract now goes to its own per-worker <name>.worker-contract.md,
# re-injected only after a compaction via a SessionStart `compact`-matcher
# hook wired into the generated <name>.leg-settings.json - not ridden on every
# API call inside the system-prompt preface. Same fixture brief and stub shape
# as 17b.
d17b3="$tmp/c17b3"; mk_launch_stubs "$d17b3" "PROJ-9999-hook"; mkdir -p "$tmp/repo17b3"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b3/konsole" PGREP_CMD="$d17b3/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b3" HEADED_ARM_LOCK_DIR="$d17b3/locks" HEADED_ARM_PROC="$d17b3/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-hook" "$fixture17b" "$d17b3/signal-never" "$PAST" "$d17b3/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b3" || true
check "compact-hook: full launch exit 0" "$rc" "0"

contract17b3="$d17b3/PROJ-9999-hook.worker-contract.md"
if [ -s "$contract17b3" ]; then
  echo "ok - compact-hook: <name>.worker-contract.md written next to the launch log"
else
  echo "FAIL - compact-hook: no worker-contract.md next to the launch log"; fails=$((fails+1))
fi
contractcontent17b3="$(cat "$contract17b3" 2>/dev/null || true)"
contains "compact-hook: contract carries the fixture's Contract line" "$contractcontent17b3" "**Contract:**"
not_contains "compact-hook: contract does NOT carry the Results tail" "$contractcontent17b3" \
  "this bullet must never reach the system-prompt preface"

prefacecontent17b3="$(cat "$d17b3/PROJ-9999-hook.worker-preface.md" 2>/dev/null || true)"
not_contains "compact-hook: the preface does NOT carry the contract" "$prefacecontent17b3" "**Contract:**"

rc=0
node --input-type=module - "$d17b3/PROJ-9999-hook.leg-settings.json" "$contract17b3" <<'NODE' || rc=$?
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const settings = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const contractPath = process.argv[3];
const starts = settings.hooks?.SessionStart ?? [];
const hit = starts.find((e) => e.matcher === 'compact');
assert.ok(hit, 'no SessionStart entry with matcher "compact"');
const cmd = hit.hooks?.[0]?.command ?? '';
assert.ok(cmd.includes(contractPath), `command does not name the contract file: ${cmd}`);
NODE
check "compact-hook: settings JSON carries a SessionStart compact hook naming the contract file" "$rc" "0"

rc=0
node --input-type=module - "$d17b3/PROJ-9999-hook.leg-settings.json" <<'NODE' || rc=$?
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
const settings = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const cmds = (settings.hooks?.Stop ?? []).flatMap((e) => (e.hooks ?? []).map((h) => h.command ?? ''));
const cmd = cmds.find((c) => c.includes('guard-worker-cache-ttl.sh'));
assert.ok(cmd, `no Stop hook runs guard-worker-cache-ttl.sh: ${JSON.stringify(cmds)}`);
assert.ok(existsSync(cmd.replace(/^bash /, '')), `Stop hook path does not exist: ${cmd}`);
NODE
check "cache-ttl: settings JSON carries a Stop hook running guard-worker-cache-ttl.sh" "$rc" "0"

# --- 17b-4. 17b-3 only checks that the
# generated command STRING names the contract path as a substring; it never
# actually runs the command, so it would not have caught an unescaped path
# breaking out of the re-parsed shell at hook-fire time. Log dir here carries
# a literal double quote - the exact character that breaks out of the OLD
# `cat "$PROFILE_CONTRACT"` double-quoting (a single quote does NOT: double
# quotes tolerate an embedded single quote) - so executing the generated
# command with an unescaped path would misparse rather than `cat` the file.
d17b4="$tmp/c17b4\"q"; mk_launch_stubs "$d17b4" "PROJ-9999-hookq"; mkdir -p "$tmp/repo17b4"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b4/konsole" PGREP_CMD="$d17b4/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b4" HEADED_ARM_LOCK_DIR="$d17b4/locks" HEADED_ARM_PROC="$d17b4/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-hookq" "$fixture17b" "$d17b4/signal-never" "$PAST" "$d17b4/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b4" || true
check "compact-hook exec: full launch exit 0 (log dir has a shell-special quote)" "$rc" "0"

contract17b4="$d17b4/PROJ-9999-hookq.worker-contract.md"
settings17b4="$d17b4/PROJ-9999-hookq.leg-settings.json"
contractcontent17b4="$(cat "$contract17b4" 2>/dev/null || true)"
contains "compact-hook exec: contract carries the fixture's Contract line" "$contractcontent17b4" "**Contract:**"

cmd17b4="$(node --input-type=module -e '
import { readFileSync } from "node:fs";
const settings = JSON.parse(readFileSync(process.argv[1], "utf8"));
const hit = (settings.hooks?.SessionStart ?? []).find((e) => e.matcher === "compact");
process.stdout.write(hit?.hooks?.[0]?.command ?? "");
' "$settings17b4")"
exec17b4="$(bash -c "$cmd17b4" 2>/dev/null || true)"
check "compact-hook exec: executing the generated command outputs the real contract content" "$exec17b4" "$contractcontent17b4"

# --- 17b-5. WORKER_SESSION_REPO_MAP=1 puts the repo map at the HEAD of the per-worker
# preface (the turn-ending section stays last), built from the worker repo's
# primary graphify-out/graph.json with the WORKER_SESSION_REPO_MAP_TOKENS cap; a failing
# generator launches without it and says so in the launch log. Off by default:
# 17b's preface starts with the worker-preface heading.
check "repo-map off by default: the preface starts with the worker-preface heading" \
  "$(head -1 "$preface17b" 2>/dev/null)" "$(head -1 "$HERE/../../../docs/handover/worker-preface.md")"
d17b5="$tmp/c17b5"; mk_launch_stubs "$d17b5" "PROJ-9999-map"; git init -q "$tmp/repo17b5"
cat > "$d17b5/repo-map" <<STUB_EOF
#!/bin/sh
printf '%s\n' "\$*" > "$d17b5/map-args"
echo "# Repo map STUB"
STUB_EOF
chmod +x "$d17b5/repo-map"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_REPO_MAP="$d17b5/repo-map" \
WORKER_SESSION_REPO_MAP=1 WORKER_SESSION_REPO_MAP_TOKENS=777 \
KONSOLE_CMD="$d17b5/konsole" PGREP_CMD="$d17b5/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b5" HEADED_ARM_LOCK_DIR="$d17b5/locks" HEADED_ARM_PROC="$d17b5/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-map" "$fixture17b" "$d17b5/signal-never" "$PAST" "$d17b5/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b5" || true
check "repo-map: full launch exit 0" "$rc" "0"
preface17b5="$d17b5/PROJ-9999-map.worker-preface.md"
check "repo-map: the map is the preface's first line" "$(head -1 "$preface17b5" 2>/dev/null)" "# Repo map STUB"
check "repo-map: the turn-ending section stays last" \
  "$(grep '^## ' "$preface17b5" 2>/dev/null | tail -1)" "## How your turns end"
check "repo-map: built from the worker repo's graph with the WORKER_SESSION_REPO_MAP_TOKENS cap" \
  "$(cat "$d17b5/map-args" 2>/dev/null)" "--graph $tmp/repo17b5/graphify-out/graph.json --max-tokens 777"
printf '#!/bin/sh\necho "repo-map: no graph" >&2\nexit 2\n' > "$d17b5/repo-map"
d17b6="$tmp/c17b6"; mk_launch_stubs "$d17b6" "PROJ-9999-nomap"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_REPO_MAP="$d17b5/repo-map" WORKER_SESSION_REPO_MAP=1 \
KONSOLE_CMD="$d17b6/konsole" PGREP_CMD="$d17b6/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b5" HEADED_ARM_LOCK_DIR="$d17b6/locks" HEADED_ARM_PROC="$d17b6/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-nomap" "$fixture17b" "$d17b6/signal-never" "$PAST" "$d17b6/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b6" || true
check "repo-map: a failing generator still launches" "$rc" "0"
check "repo-map: a failing generator leaves the preface unchanged" \
  "$(head -1 "$d17b6/PROJ-9999-nomap.worker-preface.md" 2>/dev/null)" "$(head -1 "$HERE/../../../docs/handover/worker-preface.md")"
contains "repo-map: a failing generator is named in the launch log" "$(cat "$d17b6/log" 2>/dev/null)" "WARN repo-map not injected"
# A generator that hangs past WORKER_SESSION_REPO_MAP_TIMEOUT is killed and the worker
# launches without the map. Hang-guard: with no GNU timeout the row SKIPs.
if [ -n "$_TIMEOUT_BIN" ]; then
    printf '#!/bin/sh\nsleep 60\necho "# Repo map LATE"\n' > "$d17b5/repo-map"
    d17b7="$tmp/c17b7"; mk_launch_stubs "$d17b7" "PROJ-9999-slowmap"
    rc=0
    HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
    HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_REPO_MAP="$d17b5/repo-map" \
    WORKER_SESSION_REPO_MAP=1 WORKER_SESSION_REPO_MAP_TIMEOUT=2 \
    KONSOLE_CMD="$d17b7/konsole" PGREP_CMD="$d17b7/pgrep" \
    WORKER_SESSION_REPO="$tmp/repo17b5" HEADED_ARM_LOCK_DIR="$d17b7/locks" HEADED_ARM_PROC="$d17b7/proc" \
      "$_TIMEOUT_BIN" 25 bash "$SCRIPT" --profile worker-impl "PROJ-9999-slowmap" "$fixture17b" "$d17b7/signal-never" "$PAST" "$d17b7/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
    wait_record "$d17b7" || true
    check "repo-map: a hung generator still launches" "$rc" "0"
    check "repo-map: a hung generator leaves the preface unchanged" \
      "$(head -1 "$d17b7/PROJ-9999-slowmap.worker-preface.md" 2>/dev/null)" "$(head -1 "$HERE/../../../docs/handover/worker-preface.md")"
    contains "repo-map: a hung generator is named in the launch log" "$(cat "$d17b7/log" 2>/dev/null)" "WARN repo-map not injected (graph=$tmp/repo17b5/graphify-out/graph.json, timed out after 2s)"
else
    echo "SKIP - repo-map: hung generator (hang-guard row needs GNU timeout/gtimeout)"
fi
# Off by default: with WORKER_SESSION_REPO_MAP unset the generator never runs.
printf '#!/bin/sh\n: > "%s"\necho "# Repo map OFF"\n' "$tmp/c17b8-ran" > "$d17b5/repo-map"
d17b8="$tmp/c17b8"; mk_launch_stubs "$d17b8" "PROJ-9999-offmap"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_REPO_MAP="$d17b5/repo-map" \
KONSOLE_CMD="$d17b8/konsole" PGREP_CMD="$d17b8/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b5" HEADED_ARM_LOCK_DIR="$d17b8/locks" HEADED_ARM_PROC="$d17b8/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-9999-offmap" "$fixture17b" "$d17b8/signal-never" "$PAST" "$d17b8/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b8" || true
check "repo-map off by default: full launch exit 0" "$rc" "0"
if [ -e "$tmp/c17b8-ran" ]; then
  echo "FAIL - repo-map off by default: the generator ran with WORKER_SESSION_REPO_MAP unset"; fails=$((fails+1))
else
  echo "ok - repo-map off by default: the generator never runs with WORKER_SESSION_REPO_MAP unset"
fi

# 17c. Omitting --profile changes nothing: no shim, no lean flag, and a
# dry-run report byte-identical to the earlier three-line form. This
# is the case that keeps every chief that never passes --profile working.
env8b="$(cat "$d8/env-record" 2>/dev/null || true)"
not_contains "no --profile: launcher is unchanged (no shim)" "$rec8" "worker-claude-launcher.sh"
not_contains "no --profile: no HIMMEL_LEAN_WORKER_SESSION in the launched environment" "$env8b" "HIMMEL_LEAN_WORKER_SESSION=1"

noprof="$(WORKER_SESSION_PROFILE='' bash "$SCRIPT" --dry-run --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
noprof_lines="$(printf '%s\n' "$noprof" | wc -l | tr -d '[:space:]')"
check "no --profile: dry-run report is still exactly four lines (effort line + three)" "$noprof_lines" "4"
not_contains "no --profile: dry-run report has no profile line" "$noprof" "profile="
not_contains "--no-profile: no profile name is propagated" "$noprof" "HIMMEL_WORKER_SESSION_PROFILE="

prof="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)"
prof_lines="$(printf '%s\n' "$prof" | wc -l | tr -d '[:space:]')"
check "--profile: dry-run report adds exactly one line" "$prof_lines" "5"
contains "--profile: dry-run names the profile, the settings path and the lean flag" "$prof" \
  "profile=worker-impl settings=$tmp/PROJ-9999-leg.leg-settings.json"
contains "--profile: dry-run reports lean=1" "$prof" "lean=1"
contains "--profile: resolved profile name is propagated" "$prof" "HIMMEL_WORKER_SESSION_PROFILE=worker-impl"
if [ -e "$tmp/PROJ-9999-leg.leg-settings.json" ]; then
  echo "FAIL - --profile: --dry-run wrote the settings file (it must only report)"; fails=$((fails+1))
else
  echo "ok - --profile: --dry-run writes nothing"
fi

# same ambient-leak scenario as the --judge case above, but for
# an ordinary --profile worker-impl (non-judge, native lane) launch. The wrapper
# DOES intend to set IMPL_GUARD_OK/INLINE_IMPL_OK=1 here (an impl worker), but
# worker_propagate_env's caller-preset-token-wins de-dupe means a stale token
# already present in an inherited HEADED_ARM_LAUNCHER_ENV silently wins over
# the wrapper's own "1" - so the worker launch must carry ONLY the value the
# wrapper itself sets, never an inherited one. CLAUDEX_LANE_OK must not
# survive at all on the native lane.
rc=0; out="$(IMPL_GUARD_OK=1 INLINE_IMPL_OK=1 CLAUDEX_LANE_OK=1 \
  HEADED_ARM_LAUNCHER_ENV='IMPL_GUARD_OK=99 INLINE_IMPL_OK=99 CLAUDEX_LANE_OK=1' \
  bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --profile worker-impl, ambient worker-only env: exit 0" "$rc" "0"
contains "dry-run --profile worker-impl, ambient worker-only env: reports the wrapper's own IMPL_GUARD_OK=1, not the inherited 99" "$out" "IMPL_GUARD_OK=1"
contains "dry-run --profile worker-impl, ambient worker-only env: reports the wrapper's own INLINE_IMPL_OK=1, not the inherited 99" "$out" "INLINE_IMPL_OK=1"
not_contains "dry-run --profile worker-impl, ambient worker-only env: never reports the inherited IMPL_GUARD_OK=99" "$out" "IMPL_GUARD_OK=99"
not_contains "dry-run --profile worker-impl, ambient worker-only env: never reports the inherited INLINE_IMPL_OK=99" "$out" "INLINE_IMPL_OK=99"
not_contains "dry-run --profile worker-impl, ambient worker-only env: drops the inherited CLAUDEX_LANE_OK token on the native lane" "$out" "CLAUDEX_LANE_OK=1"

# inspect the real seeded settings and the same resolver used by
# --dry-run; checking only the profile= line would miss dropped permissions.
rc=0
node --input-type=module - "$d17/PROJ-3333-leg.leg-settings.json" <<'NODE' || rc=$?
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const settings = JSON.parse(readFileSync(process.argv[2], 'utf8'));
// only the anchored entry literal is seeded now —
// the relative rule was retired.
assert.ok(settings.permissions?.allow.includes('Bash(bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh":*)'));
assert.ok(!settings.permissions?.allow.includes('Bash(bash scripts/handover/merge-on-green.sh:*)'));
NODE
check "full launch --profile: seeded settings carry gate permissions" "$rc" "0"

# a worker must stay cd-based, never EnterWorktree-pinned - a pinned
# session's isolation screen refuses /pr-check step 0's canonical fence.
# The same change also seeds the .locks deny below (same array), so this checks
# EnterWorktree is present, not that it is the array's only member.
contains "full launch --profile: seeded settings deny EnterWorktree" \
  "$(jq -c '.permissions.deny' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" 'EnterWorktree'

# a worker's Results writes land on its own handover doc, which
# sits outside the worker's working directories whenever the handover root is
# external (Mode B) - the auto-mode classifier inconsistently denies those
# writes as Out-of-Place Publication. additionalDirectories grants only the
# DOC's own directory, never the whole handover root - chief-kit/go.sh's
# merge GO is authenticated only by the existence of a file under
# <handover_root>/.locks/go/, unguarded by any hook, so widening the grant to
# the root would let a worker mint its own GO via an auto-approved Write.
# NOTE: this launch's doc is the shared $some_doc fixture ($tmp/some-doc.md),
# whose directory ($tmp) is coincidentally an ANCESTOR of HANDOVER_DIR here -
# a test-harness artifact of the shared tmp layout, not a real caller shape
# (real callers always resolve DOC via handover_root(), never an ancestor of
# it). The dedicated ancestor/prefix-lookalike cases below exercise that
# boundary directly, so this assertion expects no grant, matching the
# ancestor-skip behaviour.
check "full launch --profile: seeded settings grant nothing (doc dir is an ancestor of the root here)" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" '"none"'

# Never the handover root itself, on any --profile launch - the invariant the
# scoped grant above must hold even if the doc happened to sit at the root.
# jq exact-element equality, not a substring check: a legitimately narrower
# doc subdirectory can textually START WITH the root's own path.
check "full launch --profile: additionalDirectories never contains the handover root itself" \
  "$(jq --arg d "$HANDOVER_DIR" '(.permissions.additionalDirectories // []) | any(. == $d)' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" \
  "false"

# Belt and braces: Edit is denied on the handover root's .locks/** outright,
# regardless of what additionalDirectories grants - deny wins over
# additionalDirectories. only Edit is emitted - Claude Code
# applies an Edit(path) rule to every file-editing tool now, and warns on
# every worker exit that Write/MultiEdit/NotebookEdit rules on the same path
# are dead, so seeding them protects nothing.
check "full launch --profile: seeded settings deny Edit on .locks/**, naming the resolved handover root" \
  "$(jq -c '.permissions.deny' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" \
  "$(jq -cn --arg d "$HANDOVER_DIR" --argjson t "$TRIM_DENY" '$t + ["EnterWorktree", ("Edit(/" + $d + "/.locks/**)")]')"
check "full launch --profile: seeded settings deny NOTHING for Write/MultiEdit/NotebookEdit on .locks/** (dead rules dropped)" \
  "$(jq -c '(.permissions.deny // []) | map(select(startswith("Write(") or startswith("MultiEdit(") or startswith("NotebookEdit(")))' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" \
  "[]"

# additionalDirectories above only widens the directory
# boundary check - it grants no permission `allow` rule, so a worker's own
# Edit of its handover doc still needs an explicit allow (N577/N582/N564
# each parked on exactly this classifier gap). Scoped to the worker's OWN doc
# file only, an exact path - never a root-wide `**/*.md` glob, which would
# let a worker edit a SIBLING worker's or a JUDGE's doc under the same handover
# bucket. The .locks deny above still wins regardless,
# since a lock file is never `.md`. Only Edit is emitted, matching the
# dead-rule note above.
some_doc_canon="$(cd -P "$(dirname "$some_doc")" && pwd -P)/$(basename "$some_doc")"
check "full launch --profile: seeded settings grant Edit on the worker's own doc only" \
  "$(jq --arg f "$some_doc_canon" '(.permissions.allow // []) | any(. == ("Edit(/" + $f + ")"))' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" \
  "true"
check "full launch --profile: seeded settings do NOT grant a root-wide handover markdown glob" \
  "$(jq --arg d "$HANDOVER_DIR" '(.permissions.allow // []) | any(. == ("Edit(/" + $d + "/**/*.md)"))' "$d17/PROJ-3333-leg.leg-settings.json" 2>/dev/null)" \
  "false"

# A handover root containing a space must still resolve correctly -
# HANDOVER_DIR reaches this wrapper's own process as a plain export
# (worker_propagate_env's whitespace branch), not through the
# HEADED_ARM_LAUNCHER_ENV token list, which cannot carry it. The doc lives
# under the space root (a real worker bucket path), so this also exercises
# additionalDirectories resolving a doc directory containing a space; the
# .locks deny is built from HANDOVER_DIR directly, so it exercises the same
# space handling on that side.
d17s="$tmp/c17s"; mk_launch_stubs "$d17s" "PROJ-3333-space"; mkdir -p "$tmp/repo17s"
space_root="$tmp/pinned handover root"
space_doc_dir="$space_root/yotamleo/himmel"
mkdir -p "$space_doc_dir"
space_doc="$space_doc_dir/PROJ-3333-space.md"
fx_brief '# fixture doc' > "$space_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17s/konsole" PGREP_CMD="$d17s/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17s" HEADED_ARM_LOCK_DIR="$d17s/locks" HEADED_ARM_PROC="$d17s/proc" \
HANDOVER_DIR="$space_root" \
HEADED_ARM_UNAME=Linux \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-space" "$space_doc" "$d17s/signal-never" "$PAST" "$d17s/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17s" || true
check "full launch --profile (space in handover root): exit 0" "$rc" "0"
check "full launch --profile (space in handover root): additionalDirectories grants the doc's own directory" \
  "$(jq -c '.permissions.additionalDirectories' "$d17s/PROJ-3333-space.leg-settings.json" 2>/dev/null)" \
  "$(jq -cn --arg d "$space_doc_dir" '[$d]')"
check "full launch --profile (space in handover root): additionalDirectories never contains the handover root itself" \
  "$(jq --arg d "$space_root" '(.permissions.additionalDirectories // []) | any(. == $d)' "$d17s/PROJ-3333-space.leg-settings.json" 2>/dev/null)" \
  "false"
check "full launch --profile (space in handover root): .locks deny resolves with the space intact" \
  "$(jq -c '.permissions.deny' "$d17s/PROJ-3333-space.leg-settings.json" 2>/dev/null)" \
  "$(jq -cn --arg d "$space_root" --argjson t "$TRIM_DENY" '$t + ["EnterWorktree", ("Edit(/" + $d + "/.locks/**)")]')"

# A doc placed directly AT the handover root (dirname(doc) ==
# HANDOVER_DIR) must never collapse the grant to the whole root - rather than
# refusing the launch outright, the wrapper now skips
# only the additionalDirectories grant and launches normally, falling back to
# the classifier for this worker's own doc writes.
d17root="$tmp/c17root"; mk_launch_stubs "$d17root" "PROJ-3333-atroot"; mkdir -p "$tmp/repo17root"
root_doc="$HANDOVER_DIR/PROJ-3333-atroot.md"
fx_brief '# fixture doc at the handover root' > "$root_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17root/konsole" PGREP_CMD="$d17root/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17root" HEADED_ARM_LOCK_DIR="$d17root/locks" HEADED_ARM_PROC="$d17root/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-atroot" "$root_doc" "$d17root/signal-never" "$PAST" "$d17root/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17root" || true
check "full launch --profile (doc directly at handover root): exit 0, no longer refused" "$rc" "0"
check "full launch --profile (doc directly at handover root): additionalDirectories not granted" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17root/PROJ-3333-atroot.leg-settings.json" 2>/dev/null)" '"none"'

# a doc directory that is a
# strict ANCESTOR of the handover root (not merely equal to it) must also
# skip the grant - additionalDirectories to that ancestor would cover the
# root, and its .locks/, underneath it.
d17parent="$tmp/c17parent"; mk_launch_stubs "$d17parent" "PROJ-3333-parent"; mkdir -p "$tmp/repo17parent"
parent_doc="$tmp/PROJ-3333-parent.md"
fx_brief '# fixture doc in a directory that is an ancestor of the handover root' > "$parent_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17parent/konsole" PGREP_CMD="$d17parent/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17parent" HEADED_ARM_LOCK_DIR="$d17parent/locks" HEADED_ARM_PROC="$d17parent/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-parent" "$parent_doc" "$d17parent/signal-never" "$PAST" "$d17parent/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17parent" || true
check "full launch --profile (doc directory is an ancestor of the handover root): exit 0" "$rc" "0"
check "full launch --profile (doc directory is an ancestor of the handover root): additionalDirectories not granted" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17parent/PROJ-3333-parent.leg-settings.json" 2>/dev/null)" '"none"'

# a doc directory that is
# merely a textual PREFIX-lookalike of the handover root (not a real
# ancestor - no "/" boundary) must still get its normal, scoped grant. This
# is the negative control for the ancestor check above.
d17lookalike="$tmp/c17lookalike"; mk_launch_stubs "$d17lookalike" "PROJ-3333-lookalike"; mkdir -p "$tmp/repo17lookalike"
lookalike_doc_dir="${HANDOVER_DIR}x"
mkdir -p "$lookalike_doc_dir"
lookalike_doc="$lookalike_doc_dir/PROJ-3333-lookalike.md"
fx_brief '# fixture doc whose directory textually prefixes the handover root name' > "$lookalike_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17lookalike/konsole" PGREP_CMD="$d17lookalike/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17lookalike" HEADED_ARM_LOCK_DIR="$d17lookalike/locks" HEADED_ARM_PROC="$d17lookalike/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-lookalike" "$lookalike_doc" "$d17lookalike/signal-never" "$PAST" "$d17lookalike/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17lookalike" || true
check "full launch --profile (doc directory is a prefix-lookalike, not an ancestor): exit 0" "$rc" "0"
check "full launch --profile (doc directory is a prefix-lookalike, not an ancestor): additionalDirectories still grants it" \
  "$(jq -c '.permissions.additionalDirectories' "$d17lookalike/PROJ-3333-lookalike.leg-settings.json" 2>/dev/null)" \
  "$(jq -cn --arg d "$lookalike_doc_dir" '[$d]')"

# a doc directory reached through a
# SYMLINK to the handover root must still be caught by the root/ancestor
# check - the comparison resolves both sides physically (`cd -P && pwd -P`),
# not textually, so a symlinked alias cannot evade it.
d17symlink="$tmp/c17symlink"; mk_launch_stubs "$d17symlink" "PROJ-3333-symlink"; mkdir -p "$tmp/repo17symlink"
symlink_alias="$tmp/handover-root-alias"
ln -s "$HANDOVER_DIR" "$symlink_alias"
symlink_doc="$symlink_alias/PROJ-3333-symlink.md"
fx_brief '# fixture doc reached through a symlink alias of the handover root' > "$symlink_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17symlink/konsole" PGREP_CMD="$d17symlink/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17symlink" HEADED_ARM_LOCK_DIR="$d17symlink/locks" HEADED_ARM_PROC="$d17symlink/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-symlink" "$symlink_doc" "$d17symlink/signal-never" "$PAST" "$d17symlink/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17symlink" || true
check "full launch --profile (doc directory is a symlink alias of the handover root): exit 0" "$rc" "0"
check "full launch --profile (doc directory is a symlink alias of the handover root): additionalDirectories not granted" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17symlink/PROJ-3333-symlink.leg-settings.json" 2>/dev/null)" '"none"'

# a HANDOVER_DIR carrying a trailing slash
# must not bypass the root-equality check or leave the .locks deny malformed
# - both sides are normalized through `cd && pwd` before comparing/building.
d17slash="$tmp/c17slash"; mk_launch_stubs "$d17slash" "PROJ-3333-slash"; mkdir -p "$tmp/repo17slash"
slash_root="$HANDOVER_DIR/"
slash_doc="$slash_root/PROJ-3333-slash.md"
fx_brief '# fixture doc at a trailing-slash handover root' > "$slash_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17slash/konsole" PGREP_CMD="$d17slash/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17slash" HEADED_ARM_LOCK_DIR="$d17slash/locks" HEADED_ARM_PROC="$d17slash/proc" \
HANDOVER_DIR="$slash_root" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-slash" "$slash_doc" "$d17slash/signal-never" "$PAST" "$d17slash/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17slash" || true
check "full launch --profile (trailing slash on HANDOVER_DIR, doc at root): exit 0, still no grant" "$rc" "0"
check "full launch --profile (trailing slash on HANDOVER_DIR, doc at root): additionalDirectories not granted" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17slash/PROJ-3333-slash.leg-settings.json" 2>/dev/null)" '"none"'

d17slash2="$tmp/c17slash2"; mk_launch_stubs "$d17slash2" "PROJ-3333-slash2"; mkdir -p "$tmp/repo17slash2"
slash2_doc_dir="$HANDOVER_DIR/yotamleo/himmel"
mkdir -p "$slash2_doc_dir"
slash2_doc="$slash2_doc_dir/PROJ-3333-slash2.md"
fx_brief '# fixture doc under a trailing-slash handover root' > "$slash2_doc"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17slash2/konsole" PGREP_CMD="$d17slash2/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17slash2" HEADED_ARM_LOCK_DIR="$d17slash2/locks" HEADED_ARM_PROC="$d17slash2/proc" \
HANDOVER_DIR="$slash_root" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3333-slash2" "$slash2_doc" "$d17slash2/signal-never" "$PAST" "$d17slash2/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
check "full launch --profile (trailing slash on HANDOVER_DIR, doc under it): exit 0" "$rc" "0"
check "full launch --profile (trailing slash on HANDOVER_DIR): .locks deny normalizes, no double slash" \
  "$(jq -c '.permissions.deny' "$d17slash2/PROJ-3333-slash2.leg-settings.json" 2>/dev/null)" \
  "$(jq -cn --arg d "$HANDOVER_DIR" --argjson t "$TRIM_DENY" '$t + ["EnterWorktree", ("Edit(/" + $d + "/.locks/**)")]')"

# when HANDOVER_DIR cannot be resolved at
# all, the root/ancestor comparison has nothing to compare against - an
# unresolved root can never be proven NOT to be the doc's own directory, so
# the grant must be skipped rather than falling through ungated.
d17nohandover="$tmp/c17nohandover"; mk_launch_stubs "$d17nohandover" "PROJ-3333-nohandover"; mkdir -p "$tmp/repo17nohandover"
nohandover_doc="$tmp/PROJ-3333-nohandover-doc.md"
fx_brief '# fixture doc launched with HANDOVER_DIR unset' > "$nohandover_doc"
rc=0
# the wrapper now loads the .env HANDOVER_DIR, so "cannot be
# resolved at all" needs a hermetic cwd (non-git, no inline handovers/) and an
# empty .env in the cache dir load_dotenv reads first - not the operator's.
mkdir -p "$tmp/nohandover-cwd" "$tmp/nohandover-cache"; : > "$tmp/nohandover-cache/.env"
( cd "$tmp/nohandover-cwd" && \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17nohandover/konsole" PGREP_CMD="$d17nohandover/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17nohandover" HEADED_ARM_LOCK_DIR="$d17nohandover/locks" HEADED_ARM_PROC="$d17nohandover/proc" \
HIMMELCTL_CACHE_DIR="$tmp/nohandover-cache" \
  env -u HANDOVER_DIR bash "$SCRIPT" --profile worker-impl "PROJ-3333-nohandover" "$nohandover_doc" "$d17nohandover/signal-never" "$PAST" "$d17nohandover/log" "claude-sonnet-5" ) >/dev/null 2>&1 || rc=$?
wait_record "$d17nohandover" || true
check "full launch --profile (HANDOVER_DIR unset): exit 0, launch still succeeds" "$rc" "0"
check "full launch --profile (HANDOVER_DIR unset): additionalDirectories not granted" \
  "$(jq -c '.permissions.additionalDirectories // "none"' "$d17nohandover/PROJ-3333-nohandover.leg-settings.json" 2>/dev/null)" '"none"'

# The relay half of a split chief is not a worker that works in a worktree:
# its settings get no deny.
d17r="$tmp/c17r"; mk_launch_stubs "$d17r" "PROJ-9999-relay"; mkdir -p "$tmp/repo17r"
rc=0
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17r/konsole" PGREP_CMD="$d17r/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17r" HEADED_ARM_LOCK_DIR="$d17r/locks" HEADED_ARM_PROC="$d17r/proc" \
  bash "$SCRIPT" --relay "PROJ-9999-relay" "$fixture17b" "$d17r/signal-never" "$PAST" "$d17r/log" >/dev/null 2>&1 || rc=$?
wait_record "$d17r" || true
check "full launch --relay: exit 0" "$rc" "0"
check "full launch --relay: settings deny only the default Artifact" \
  "$(jq -c '.permissions.deny // "none"' "$d17r/PROJ-9999-relay.leg-settings.json" 2>/dev/null)" '["Artifact"]'

rc=0
node "$HERE/../../lanes/plugin-profiles.mjs" worker-impl > "$tmp/resolved-leg.json" || rc=$?
check "--dry-run worker-impl: resolver succeeds" "$rc" "0"
rc=0
node -e 'const j=require(process.argv[1]); if (!j.permissions?.allow.includes("Bash(bash scripts/cr/ledger-append.sh:*)")) process.exit(1)' "$tmp/resolved-leg.json" || rc=$?
check "--dry-run worker-impl: resolved settings carry permissions.allow" "$rc" "0"

rc=0
bareprof="$(bash "$SCRIPT" --dry-run --profile bare PROJ-9999-bare some/doc.md /tmp/nosig 99999999999 "$tmp/bare.log" claude-sonnet-5 2>&1)" || rc=$?
check "--dry-run bare: exit 0" "$rc" "0"
contains "--dry-run bare: names profile and settings" "$bareprof" \
  "profile=bare settings=$tmp/PROJ-9999-bare.leg-settings.json"
rc=0
node "$HERE/../../lanes/plugin-profiles.mjs" bare > "$tmp/resolved-bare.json" || rc=$?
check "--dry-run bare: resolver succeeds" "$rc" "0"
rc=0
node -e 'const j=require(process.argv[1]); if (JSON.stringify(j.permissions) !== "{\"deny\":[\"Artifact\"]}") process.exit(1)' "$tmp/resolved-bare.json" || rc=$?
check "--dry-run bare: resolved settings carry only the default Artifact deny" "$rc" "0"

# WORKER_SESSION_PROFILE is the env equivalent, and the flag wins over it.
envprof="$(WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)"
contains "WORKER_SESSION_PROFILE=worker-impl is honoured like the flag" "$envprof" "profile=worker-impl"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile no-such-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)" || rc=$?
check "an unknown profile name is refused with exit 2" "$rc" "2"

if [ -n "$_TIMEOUT_BIN" ]; then
    rc=0; out="$("$_TIMEOUT_BIN" 5 bash "$SCRIPT" --profile 2>&1)" || rc=$?
    check "usage: --profile with no value -> exit 2 (not an infinite loop)" "$rc" "2"
else
    echo "SKIP - usage: --profile with no value (hang-guard row needs GNU timeout/gtimeout)"
fi

# 17d. composition must carry the profile through the claudex
# backend, not silently select one launcher. Execute the real wrapper + shim
# against recording endpoints (never launch Claude or a terminal).
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex --profile worker-impl PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "--profile with --lane claudex: exit 0" "$rc" "0"
contains "composed dry-run: profile settings reported" "$out" "profile=worker-impl settings="
contains "composed dry-run: claudex lane retained" "$out" "lane=claudex"
rc=0; out="$(WORKER_SESSION_LANE=claudex WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "composition via the env equivalents: exit 0" "$rc" "0"

# 17e. the launcher tells the resolver its lane, so a profile's nativeDrop applies on the native
# lane only. A recording resolver stands in for plugin-profiles.mjs.
lane17e="$tmp/lane17e"; mkdir -p "$lane17e"
cat > "$lane17e/profiles.mjs" <<'PROFILE_EOF'
import { appendFileSync } from 'node:fs';
switch (process.argv[3]) {
  case '--context': console.log('{"contextMode":"standard","autocompact":200000}'); break;
  case '--mcp-servers': console.log('["qmd"]'); break;
  case '--mcp-config': console.log('{"mcpServers":{}}'); break;
  default: appendFileSync(new URL('./calls', import.meta.url), process.argv.slice(2).join(' ') + '\n'); console.log('{"enabledPlugins":{}}');
}
PROFILE_EOF
HEADED_ARM_WORKER_PROFILES="$lane17e/profiles.mjs" bash "$SCRIPT" --dry-run --lane native --profile worker-impl PROJ-9998-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 >/dev/null 2>&1 || true
HEADED_ARM_WORKER_PROFILES="$lane17e/profiles.mjs" bash "$SCRIPT" --dry-run --lane claudex --profile worker-impl PROJ-9998-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log >/dev/null 2>&1 || true
check "17e launcher passes its lane to the resolver" "$(cat "$lane17e/calls" 2>/dev/null)" "worker-impl --lane native
worker-impl --lane claudex"

composed="$tmp/composed-launch"; mkdir -p "$composed"
cat > "$composed/headed" <<'HEADED_EOF'
#!/usr/bin/env bash
read -r -a lane_env <<< "${HEADED_ARM_LAUNCHER_ENV:-}"
exec env ${lane_env[@]+"${lane_env[@]}"} "$HEADED_ARM_LAUNCHER" --model "$6" --autocompact 200000 -n "$1" "load $2 and continue"
HEADED_EOF
cat > "$composed/claude-codex" <<'CLAUDEX_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/args"
printf '%s\n' "${CLAUDEX_LANE_OK:-}" "${CLAUDE_CODE_EFFORT_LEVEL:-}" > "$(dirname "$0")/lane-env"
CLAUDEX_EOF
cat > "$composed/profiles.mjs" <<'PROFILE_EOF'
switch (process.argv[3]) {
  case '--context': console.log('{"contextMode":"standard","autocompact":200000}'); break;
  case '--mcp-servers': console.log('["qmd"]'); break;
  case '--mcp-config': console.log('{"mcpServers":{"qmd":{"type":"http","url":"http://localhost:8181/mcp"}}}'); break;
  default: console.log('{"enabledPlugins":{},"permissions":{"allow":["Bash(bash \\"$HIMMEL_REPO/scripts/handover/merge-on-green.sh\\":*)"]}}');
}
PROFILE_EOF
chmod 755 "$composed/headed" "$composed/claude-codex"
rc=0
HEADED_ARM_WORKER_TARGET="$composed/headed" HEADED_ARM_WORKER_CLAUDEX_BIN="$composed/claude-codex" \
HEADED_ARM_WORKER_PROFILES="$composed/profiles.mjs" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" WORKER_SESSION_EFFORT=high \
  bash "$SCRIPT" --lane claudex --profile worker-impl HIMMEL-composed "some/doc.md" "$composed/signal" "$PAST" "$composed/log" >/dev/null 2>&1 || rc=$?
check "composition: real wrapper + shim reaches claudex" "$rc" "0"
check "composition: lane env reaches the backend" "$(cat "$composed/lane-env" 2>/dev/null || true)" "$(printf '1\nhigh')"
contains "launch identity: claudex prompt carries resolved effort and model" \
  "$(cat "$composed/HIMMEL-composed.worker-preface.md" 2>/dev/null || true)" \
  "Worker launch: effort=high model=gpt-6.1-sol"
rc=0
node - "$composed" "$HERE/../../../docs/handover/worker-preface.md" <<'NODE' || rc=$?
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [dir, profilePreface] = process.argv.slice(2);
const preface = `${dir}/HIMMEL-composed.worker-preface.md`;
const claudexPreface = profilePreface.replace('worker-preface.md', 'worker-preface-claudex.md');
assert.strictEqual(fs.readFileSync(preface, 'utf8'),
  fs.readFileSync(profilePreface, 'utf8').replace('\n', '\n\nWorker launch: effort=high model=gpt-6.1-sol\n') +
  fs.readFileSync(claudexPreface, 'utf8'));
assert.deepStrictEqual(fs.readFileSync(`${dir}/args`, 'utf8').trimEnd().split('\n'), [
  '--settings', `${dir}/HIMMEL-composed.leg-settings.json`,
  '--append-system-prompt-file', preface,
  '--mcp-config', `${dir}/HIMMEL-composed.leg-mcp.json`, '--strict-mcp-config',
  '--model', 'gpt-6.1-sol', '--autocompact', '200000', '-n', 'HIMMEL-composed', 'load some/doc.md and continue',
]);
const settings = JSON.parse(fs.readFileSync(`${dir}/HIMMEL-composed.leg-settings.json`, 'utf8'));
assert.ok(settings.permissions.allow.includes('Bash(bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh":*)'));
// HANDOVER_DIR is exported suite-wide (line ~105), so this
// non-relay launch also seeds the .locks deny alongside EnterWorktree.
// only Edit is seeded now - the other three tools' rules were
// dead (Claude Code applies an Edit(path) rule to every file-editing tool).
assert.deepStrictEqual(settings.permissions.deny, [
  'EnterWorktree',
  `Edit(/${process.env.HANDOVER_DIR}/.locks/**)`,
]);
assert.deepStrictEqual(JSON.parse(fs.readFileSync(`${dir}/HIMMEL-composed.leg-mcp.json`, 'utf8')),
  {mcpServers: {qmd: {type: 'http', url: 'http://localhost:8181/mcp'}}});
NODE
check "composition: both prefaces, all profile flags, argv order and gate settings survive" "$rc" "0"

# Without a profile, claudex gains exactly the coordination preface pair.
rc=0
HEADED_ARM_WORKER_TARGET="$composed/headed" HEADED_ARM_WORKER_CLAUDEX_BIN="$composed/claude-codex" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  bash "$SCRIPT" --lane claudex --no-profile HIMMEL-unprofiled "some/doc.md" "$composed/signal" "$PAST" "$composed/log" >/dev/null 2>&1 || rc=$?
check "unprofiled claudex: launcher succeeds" "$rc" "0"
rc=0
node - "$composed" "$HERE/../../../docs/handover/worker-preface-claudex.md" <<'NODE' || rc=$?
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [dir, preface] = process.argv.slice(2);
assert.deepStrictEqual(fs.readFileSync(`${dir}/args`, 'utf8').trimEnd().split('\n'), [
  '--append-system-prompt-file', preface,
  '--model', 'gpt-6.1-sol', '--autocompact', '200000', '-n', 'HIMMEL-unprofiled', 'load some/doc.md and continue',
]);
NODE
check "unprofiled claudex: exactly one added preface pair, other argv unchanged" "$rc" "0"

# --- 18. --profile's mcpServers allowlist: --mcp-config +
# --strict-mcp-config narrow the worker's MCP surface to exactly the named
# servers, copied (never hand-written) from ~/.claude.json / a repo .mcp.json
# / the server's own marketplace plugin manifest. Two layers, same split as
# case 17 above: the SHIM (worker-claude-launcher.sh) is the only place the
# child cmdline is observable, so flag-propagation is proven there directly;
# headed-arm-worker.sh's own full-launch path is where the file gets resolved
# and written (or refused), proven via the written artifact, not the argv.

# 18-shim. The shim, driven directly: WORKER_SESSION_PROFILE_MCP_CONFIG set + file
# present -> both flags prepended, ahead of the rest of argv; unset -> no
# change; set but missing -> fail closed (the same shape as the settings/
# preface cases in 17a, now pinned for the third env var).
mcpfile="$tmp/leg-mcp.json"
printf '{"mcpServers":{"qmd":{"type":"http","url":"http://localhost:8181/mcp"}}}' > "$mcpfile"
rm -f "$tmp/shim-record"
rc=0
WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG="$mcpfile" \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg "load doc" || rc=$?
check "shim: mcp-config exit 0" "$rc" "0"
check "shim: prepends --mcp-config + --strict-mcp-config, rest of argv preserved" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--mcp-config $mcpfile --strict-mcp-config --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg load doc"

rm -f "$tmp/shim-record"
rc=0
WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg "load doc" || rc=$?
check "shim: no WORKER_SESSION_PROFILE_MCP_CONFIG -> argv byte-identical (no mcp flags)" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--model claude-sonnet-5 --autocompact 200000 -n PROJ-9999-leg load doc"

rc=0
out="$(WORKER_SESSION_CLAUDE_BIN="$shim_rec" WORKER_SESSION_PROFILE_MCP_CONFIG="$tmp/no-such-mcp.json" bash "$SHIM" --model x 2>&1)" || rc=$?
check "shim: a missing mcp-config file refuses with exit 2" "$rc" "2"
contains "shim: refusal names the missing mcp file" "$out" "$tmp/no-such-mcp.json"

# 18-nss. WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 prepends `--setting-sources ""`
# (an EMPTY argv element: no user/project/local scope loads, so none of their write roots
# reach the consult's sandbox). The recorder brackets each argv element so the empty one
# is visible; unset or any other value adds nothing.
rm -f "$tmp/shim-argv"
rc=0
WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS="$tmp/settings.json" WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 \
  bash "$SHIM" --model claude-sonnet-5 -n PROJ-9999-leg "load doc" || rc=$?
check "shim: no-setting-sources exit 0" "$rc" "0"
check "shim: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 prepends --setting-sources with an EMPTY value" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" \
  "[--settings][$tmp/settings.json][--setting-sources][][--model][claude-sonnet-5][-n][PROJ-9999-leg][load doc]"
for nss in '' 0 yes; do
  rm -f "$tmp/shim-argv"
  WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES="$nss" \
    bash "$SHIM" --model claude-sonnet-5 "load doc" || true
  check "shim: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES='$nss' adds no --setting-sources" \
    "$(cat "$tmp/shim-argv" 2>/dev/null || true)" "[--model][claude-sonnet-5][load doc]"
done
rm -f "$tmp/shim-argv"
(unset WORKER_SESSION_PROFILE_NO_SETTING_SOURCES; WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' \
  bash "$SHIM" --model claude-sonnet-5 "load doc") || true
check "shim: WORKER_SESSION_PROFILE_NO_SETTING_SOURCES unset adds no --setting-sources" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" "[--model][claude-sonnet-5][load doc]"
# under =1 the final argv must keep the empty list. A caller argv that names
# --setting-sources again (last wins) would re-load the scopes, so the shim refuses, execs nothing.
for over in '--setting-sources user,project' '--setting-sources=user'; do
  rm -f "$tmp/shim-argv"; rc=0
  # shellcheck disable=SC2086 # $over splits into the flag and its value on purpose
  WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 \
    bash "$SHIM" --model claude-sonnet-5 $over "load doc" 2>/dev/null || rc=$?
  check "shim: =1 with a caller '$over' refuses (exit 2)" "$rc" "2"
  check "shim: =1 with a caller '$over' execs nothing" "$(cat "$tmp/shim-argv" 2>/dev/null || true)" ""
done
# Counter-example: without the consult marker a caller --setting-sources passes through untouched.
rm -f "$tmp/shim-argv"
WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES='' \
  bash "$SHIM" --setting-sources user "load doc" || true
check "shim: no marker, a caller --setting-sources passes through" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" "[--setting-sources][user][load doc]"
# under =1 the caller's PATH (and HOME) must not pick which claude runs: a fake
# early on PATH, or in $HOME/.local/bin, never execs. The shim resolves claude from a pinned
# PATH instead, or refuses when none is there (a CI runner). --version keeps a real one inert.
rc=0; out="$(unset WORKER_SESSION_CLAUDE_BIN; PATH="$fake4152/bin:$PATH" HOME="$fake4152/home" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 \
  bash "$SHIM" --version 2>&1)" || rc=$?
# a broken launcher also runs no fake, so assert the outcome too: the pinned
# claude's own rc 0, or the specific no-pinned-claude refusal (rc 2), nothing else.
check "shim 4152: =1 outcome is the pinned claude (rc 0) or the no-pinned-claude refusal (rc 2)" \
  "$({ [ "$rc" = 0 ] || { [ "$rc" = 2 ] && grepq "$out" -F -e "no claude on the pinned PATH"; }; } && echo ok || echo "rc=$rc")" "ok"
check "shim 4152: =1 never execs a claude placed early on the caller's PATH" "$([ -e "$fake4152/bin/ran" ] && echo ran || echo not-run)" "not-run"
check "shim 4152: =1 never execs a claude in the caller's \$HOME/.local/bin" "$([ -e "$fake4152/home/.local/bin/ran" ] && echo ran || echo not-run)" "not-run"
# Counter-example: without the consult marker the caller's PATH claude still runs, unchanged.
rm -f "$fake4152/bin/ran"
rc=0; (unset WORKER_SESSION_CLAUDE_BIN; PATH="$fake4152/bin:$PATH" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_PROFILE_NO_SETTING_SOURCES='' \
  bash "$SHIM" --version) >/dev/null 2>&1 || rc=$?
check "shim 4152: no marker, the shim exits with the PATH claude's rc 0" "$rc" "0"
check "shim 4152: no marker, the caller's PATH claude still runs" "$([ -e "$fake4152/bin/ran" ] && echo ran || echo not-run)" "ran"

# 18-resolve. A tiny fixture registry exercises all four allowlist shapes
# (empty/named/unknown/absent) without touching the shipped worker-impl entry.
# floor+catalog carry one dummy id purely to satisfy validateRegistry's
# non-empty-array checks; none of these profiles enable it.
mcphome="$tmp/mcp-home"; mkdir -p "$mcphome"
cat > "$mcphome/.claude.json" <<'HOME_EOF'
{"mcpServers": {"qmd": {"type": "http", "url": "http://localhost:8181/mcp"}, "graphify": {"type": "stdio", "command": "graphify-mcp"}, "context7": {"type": "http", "url": "http://context7.example/mcp"}}}
HOME_EOF

full_launch_mcp() {
  # full_launch_mcp <dir-suffix> <name> <profile> [homedir, default: ambient $HOME]
  local suf="$1" name="$2" prof="$3" homedir="${4:-$HOME}"
  local d="$tmp/c18$suf"; mk_launch_stubs "$d" "$name"; mkdir -p "$tmp/repo18$suf"
  rc=0
  PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$homedir" \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d/konsole" PGREP_CMD="$d/pgrep" \
  WORKER_SESSION_REPO="$tmp/repo18$suf" HEADED_ARM_LOCK_DIR="$d/locks" HEADED_ARM_PROC="$d/proc" \
    bash "$SCRIPT" --profile "$prof" "$name" "$some_doc" "$d/signal-never" "$PAST" "$d/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
  wait_record "$d" || true
}

# (a) mcpServers: [] -> the written file is exactly {"mcpServers":{}} - "strip
# everything" is a real, distinct allowlist value from "field absent".
full_launch_mcp a "PROJ-4441-leg" mcp-empty
check "mcpServers=[]: full launch exit 0" "$rc" "0"
check "mcpServers=[]: mcp config file is exactly {\"mcpServers\":{}}" \
  "$(cat "$tmp/c18a/PROJ-4441-leg.leg-mcp.json" 2>/dev/null || true)" '{"mcpServers":{}}'
env18a="$(cat "$tmp/c18a/env-record" 2>/dev/null || true)"
contains "mcpServers=[]: WORKER_SESSION_PROFILE_MCP_CONFIG reaches the launched environment" "$env18a" "WORKER_SESSION_PROFILE_MCP_CONFIG=$tmp/c18a/PROJ-4441-leg.leg-mcp.json"

# (b) mcpServers: ["qmd"] against a fixture home carrying qmd+graphify+
# context7 -> the written file holds ONLY qmd's definition, byte-copied
# (deny-by-default: graphify/context7 never appear despite being right there
# in the source file).
full_launch_mcp b "PROJ-4442-leg" mcp-qmd "$mcphome"
check "mcpServers=[qmd]: full launch exit 0" "$rc" "0"
mcpout_b="$(cat "$tmp/c18b/PROJ-4442-leg.leg-mcp.json" 2>/dev/null || true)"
contains "mcpServers=[qmd]: file carries qmd's definition byte-copied" "$mcpout_b" '"qmd":{"type":"http","url":"http://localhost:8181/mcp"}'
not_contains "mcpServers=[qmd]: graphify is NOT copied despite being in the source file" "$mcpout_b" "graphify"
not_contains "mcpServers=[qmd]: context7 is NOT copied despite being in the source file" "$mcpout_b" "context7"

# (c) an allowlisted name absent from every source -> exit 2, no file
# written at all (not an empty one - the refusal must precede the write).
full_launch_mcp c "PROJ-4443-leg" mcp-missing "$mcphome"
check "mcpServers=[no-such-server]: refused with exit 2" "$rc" "2"
if [ -e "$tmp/c18c/PROJ-4443-leg.leg-mcp.json" ]; then
  echo "FAIL - mcpServers=[no-such-server]: a config file must not exist"; fails=$((fails+1))
else
  echo "ok - mcpServers=[no-such-server]: no config file written"
fi

# (d) no mcpServers field -> byte-identical to the earlier behaviour: no file, no
# WORKER_SESSION_PROFILE_MCP_CONFIG in the launched environment.
full_launch_mcp d "PROJ-4444-leg" mcp-none
check "no mcpServers field: full launch exit 0" "$rc" "0"
if [ -e "$tmp/c18d/PROJ-4444-leg.leg-mcp.json" ]; then
  echo "FAIL - no mcpServers field: a config file must not exist"; fails=$((fails+1))
else
  echo "ok - no mcpServers field: no config file written"
fi
env18d="$(cat "$tmp/c18d/env-record" 2>/dev/null || true)"
not_contains "no mcpServers field: no WORKER_SESSION_PROFILE_MCP_CONFIG in the launched environment" "$env18d" "WORKER_SESSION_PROFILE_MCP_CONFIG="

# dry-run mirrors the same four shapes without writing anything, and an
# unresolvable name is refused the same way under --dry-run too (typo'd
# names must fail identically whether or not the launch is real).
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$mcphome" bash "$SCRIPT" --dry-run --profile mcp-missing PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: an unresolvable mcpServers name is refused with exit 2" "$rc" "2"

dryempty="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$mcphome" bash "$SCRIPT" --dry-run --profile mcp-empty PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)"
contains "dry-run mcpServers=[]: reports mcp=[] and the would-be mcp-config path" "$dryempty" "mcp=[] mcp-config=$tmp/PROJ-9999-leg.leg-mcp.json"

drynone="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" bash "$SCRIPT" --dry-run --profile mcp-none PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/worker.log" claude-sonnet-5 2>&1)"
contains "dry-run: no mcpServers field reports mcp=null mcp-config=<none>" "$drynone" "mcp=null mcp-config=<none>"

# --- 19-23 + Opus/Fable workers need a named Tier
# reason that opens with one of three closed category tags --------------
# CLAUDE.md: "raise effort before tier" - an Opus or Fable worker costs
# materially more per turn than the Sonnet default, so it launches only when
# its brief names a Tier line whose reason opens with one of the three
# sanctioned category tags (a closed tag + free text, so the
# free text after the tag is never validated). Matched by MODEL PREFIX so a
# [1m] suffix cannot dodge it.
doc_no_tier="$tmp/tier-doc-none.md"
fx_brief '# fixture brief' '> no tier line here' > "$doc_no_tier"
doc_tier_fable="$tmp/tier-doc-fable.md"
fx_brief '# fixture brief' '> **Tier:** fable — tier-return: a Sonnet worker returned the work as above its tier' > "$doc_tier_fable"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: opus without a Tier line is refused with exit 2" "$rc" "2"
contains "tier gate: refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"
contains "tier gate: refusal names reason 1 (multi-step design)" "$out" "multi-step design"
contains "tier gate: refusal names reason 2 (unverifiable FINDING)" "$out" "a FINDING the chief could not verify at Sonnet"
contains "tier gate: refusal names reason 3 (above-tier return)" "$out" "a Sonnet worker returned the work as above its tier"
contains "tier gate: refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log "claude-opus-5[1m]" 2>&1)" || rc=$?
check "tier gate: a [1m] suffix does not dodge the opus match" "$rc" "2"
contains "tier gate: [1m]-suffixed refusal still names the sentence" "$out" "raise effort before tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log claude-fable-5-1 2>&1)" || rc=$?
check "tier gate: fable without a Tier line is refused with exit 2" "$rc" "2"
contains "tier gate: fable refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: opus with a design: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate: dry-run report carries tier-category=design for opus" "$out" "tier-category=design"
contains "tier gate: dry-run report carries tier-reason= for opus" "$out" "tier-reason=multi-step design"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_fable" /tmp/nosig 99999999999 /tmp/worker.log claude-fable-5-1 2>&1)" || rc=$?
check "tier gate: fable with a tier-return: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate: dry-run report carries tier-category=tier-return for fable" "$out" "tier-category=tier-return"
contains "tier gate: dry-run report carries tier-reason= for fable" "$out" "tier-reason=a Sonnet worker returned the work as above its tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "tier gate: sonnet without a Tier line is unaffected (dry-run exit 0)" "$rc" "0"
not_contains "tier gate: sonnet dry-run report carries no tier-reason=" "$out" "tier-reason="

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl --lane claudex PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "tier gate: --lane claudex is unaffected (dry-run exit 0)" "$rc" "0"

# a Tier line whose reason is whitespace-only
# must be refused exactly like a missing line - `-z` alone treats a
# whitespace-only string as non-empty and would incorrectly let the launch
# proceed.
doc_tier_opus_blank="$tmp/tier-doc-opus-blank.md"
fx_brief '# fixture brief' '> **Tier:** opus —    ' > "$doc_tier_opus_blank"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_blank" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: a whitespace-only Tier reason is refused with exit 2" "$rc" "2"
contains "tier gate: whitespace-only refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"

# --- (a)-(f): the reason must open with a closed category tag --
doc_tier_opus_bare="$tmp/tier-doc-opus-bare.md"
fx_brief '# fixture brief' '> **Tier:** opus — because I prefer it' > "$doc_tier_opus_bare"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_bare" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (a): bare free text with no category tag is refused with exit 2" "$rc" "2"
contains "tier gate (a): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

doc_tier_opus_finding="$tmp/tier-doc-opus-finding.md"
fx_brief '# fixture brief' '> **Tier:** opus — unverified-finding: a memory leak the chief could not repro at Sonnet' > "$doc_tier_opus_finding"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_finding" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (c): unverified-finding: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (c): dry-run report carries tier-category=unverified-finding" "$out" "tier-category=unverified-finding"

doc_tier_opus_return="$tmp/tier-doc-opus-return.md"
fx_brief '# fixture brief' '> **Tier:** opus — tier-return: a Sonnet worker returned the work as above its tier' > "$doc_tier_opus_return"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_return" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (d): tier-return: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (d): dry-run report carries tier-category=tier-return" "$out" "tier-category=tier-return"

doc_tier_opus_wrongcase="$tmp/tier-doc-opus-wrongcase.md"
fx_brief '# fixture brief' '> **Tier:** opus — Design: multi-step design' > "$doc_tier_opus_wrongcase"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_wrongcase" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (e): wrong-case category tag (Design:) is refused with exit 2" "$rc" "2"
contains "tier gate (e): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

doc_tier_opus_emptytext="$tmp/tier-doc-opus-emptytext.md"
fx_brief '# fixture brief' '> **Tier:** opus — design:' > "$doc_tier_opus_emptytext"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_emptytext" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (f): a category tag with empty free text is refused with exit 2" "$rc" "2"
contains "tier gate (f): refusal names the empty-text problem" "$out" "no free text after"

# CR: a bare sanctioned tag with no ':' at all must not slip
# through as category=<tag> reason=<tag> — the split is a no-op without a
# literal colon present, so this must be refused explicitly.
doc_tier_opus_notag_colon="$tmp/tier-doc-opus-notag-colon.md"
fx_brief '# fixture brief' '> **Tier:** opus — design' > "$doc_tier_opus_notag_colon"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_notag_colon" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (g): a bare sanctioned tag with no colon is refused with exit 2" "$rc" "2"
contains "tier gate (g): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

# --- a fourth closed tag, operator-ruling,
# for a standing operator ruling on model choice (2026-09-22: run only Opus
# 5.5). Same shape as the other three: exact lowercase, non-blank free text.
doc_tier_opus_ruling="$tmp/tier-doc-opus-ruling.md"
fx_brief '# fixture brief' '> **Tier:** opus — operator-ruling: run only Opus 5.5 (operator 2026-09-22, chief A)' > "$doc_tier_opus_ruling"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_ruling" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (h): operator-ruling: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (h): dry-run report carries tier-category=operator-ruling" "$out" "tier-category=operator-ruling"
contains "tier gate (h): dry-run report carries the ruling as tier-reason=" "$out" "tier-reason=run only Opus 5.5 (operator 2026-09-22, chief A)"

doc_tier_opus_ruling_blank="$tmp/tier-doc-opus-ruling-blank.md"
fx_brief '# fixture brief' '> **Tier:** opus — operator-ruling:   ' > "$doc_tier_opus_ruling_blank"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_ruling_blank" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (i): operator-ruling: with blank free text is refused with exit 2" "$rc" "2"
contains "tier gate (i): refusal names the empty-text problem" "$out" "no free text after"

doc_tier_opus_ruling_case="$tmp/tier-doc-opus-ruling-case.md"
fx_brief '# fixture brief' '> **Tier:** opus — Operator-ruling: run only Opus 5.5' > "$doc_tier_opus_ruling_case"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus_ruling_case" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (j): wrong-case Operator-ruling: is refused with exit 2" "$rc" "2"
contains "tier gate (j): refusal lists the four category tags" "$out" "design|unverified-finding|tier-return|operator-ruling"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (k): opus-5-5 without a Tier line is still refused with exit 2" "$rc" "2"
contains "tier gate (k): missing-line refusal lists the four category tags" "$out" "design|unverified-finding|tier-return|operator-ruling"
contains "tier gate (k): missing-line refusal names the operator-ruling reason" "$out" "a standing operator ruling on model choice"

# A native launch that names no model runs the claude-opus-5-5
# default, so the gate must see the resolved model, not the empty argument.
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "tier gate (l): a native launch with no model and no Tier line is refused with exit 2" "$rc" "2"
contains "tier gate (l): no-model refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$doc_tier_opus" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "tier gate (l): a native launch with no model and an opus Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (l): no-model dry-run report carries tier-category=design" "$out" "tier-category=design"

# --- 24. FLEET_RESERVE_TTL is exported, derived from DEADLINE -
# TTL_RECORD_PREFLIGHT stands in for usage-preflight.sh and records the TTL it
# was called with instead of consulting the real fleet/bank state, mirroring
# how PROCEED_PREFLIGHT/SKIPPED_FLEET_PREFLIGHT stand in above.
TTL_RECORD_PREFLIGHT="$tmp/ttl-record-preflight.sh"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$FLEET_RESERVE_TTL" > "$TTL_RECORD_OUT"' 'echo PROCEED' > "$TTL_RECORD_PREFLIGHT"
chmod 755 "$TTL_RECORD_PREFLIGHT"

# A genuinely future deadline (500s, clearly above the 60s floor so 24b's
# floor case is distinguishable) WITHOUT paying for headed-arm.sh's own
# wait loop: that loop breaks immediately once its SIGNAL file exists
# (headed-arm.sh tests `[ -e "$SIGNAL" ]` before ever comparing to DEADLINE),
# so pre-touching a real signal file here gets an immediate launch while
# still exercising the TTL computation against a real future DEADLINE value.
d24a="$tmp/c24a"; mk_launch_stubs "$d24a" "PROJ-1111-ttl"; mkdir -p "$tmp/repo24a"
future24=$(( $(date +%s) + 500 ))
touch "$d24a/signal-now"
ttl_out24a="$tmp/ttl24a-seen"
rc=0
TTL_RECORD_OUT="$ttl_out24a" IMPL_GUARD_OK='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$TTL_RECORD_PREFLIGHT" \
KONSOLE_CMD="$d24a/konsole" PGREP_CMD="$d24a/pgrep" \
WORKER_SESSION_REPO="$tmp/repo24a" HEADED_ARM_LOCK_DIR="$d24a/locks" HEADED_ARM_PROC="$d24a/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-1111-ttl" "$some_doc" "$d24a/signal-now" "$future24" "$d24a/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d24a" || true
ttl_seen24a="$(cat "$ttl_out24a" 2>/dev/null || echo NONE)"
check "TTL export: full launch, future deadline: exit 0" "$rc" "0"
# a few seconds of scheduling slop around (deadline - now + 60) is expected;
# the exact value depends on how long the test harness itself took to reach
# the preflight call, not on anything this suite controls. codex-5: the TTL now carries a fixed +60s grace past (deadline - now) so
# a reservation outlives the actual process spawn - see headed-arm-worker.sh.
if [ "$ttl_seen24a" != NONE ] && [ "$ttl_seen24a" -ge 550 ] 2>/dev/null && [ "$ttl_seen24a" -le 560 ] 2>/dev/null; then
  echo "ok - TTL export: future deadline -> FLEET_RESERVE_TTL ~= deadline - now + 60 ($ttl_seen24a)"
else
  echo "FAIL - TTL export: future deadline -> expected 550-560, got [$ttl_seen24a]"
  fails=$((fails+1))
fi

d24b="$tmp/c24b"; mk_launch_stubs "$d24b" "PROJ-2222-ttlfloor"; mkdir -p "$tmp/repo24b"
ttl_out24b="$tmp/ttl24b-seen"
rc=0
TTL_RECORD_OUT="$ttl_out24b" IMPL_GUARD_OK='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$TTL_RECORD_PREFLIGHT" \
KONSOLE_CMD="$d24b/konsole" PGREP_CMD="$d24b/pgrep" \
WORKER_SESSION_REPO="$tmp/repo24b" HEADED_ARM_LOCK_DIR="$d24b/locks" HEADED_ARM_PROC="$d24b/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-2222-ttlfloor" "$some_doc" "$d24b/signal-never" "$PAST" "$d24b/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d24b" || true
check "TTL export: past deadline floors to 60" "$(cat "$ttl_out24b" 2>/dev/null || echo NONE)" "60"

# --- 25. Reservation release on abort, SKIPPED-BANK vs
# SKIPPED-FLEET -------------------------------------------------------------
slots25a="$tmp/slots25a"; mkdir -p "$slots25a/PROJ-3333-release"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$slots25a/PROJ-3333-release/expires"
d25a="$tmp/c25a"; mk_launch_stubs "$d25a" "PROJ-3333-release"; mkdir -p "$tmp/repo25a"
rc=0
HIMMEL_FLEET_SLOTS="$slots25a" run_worker "$d25a" "$tmp/repo25a" "PROJ-3333-release" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ -d "$slots25a/PROJ-3333-release" ]; then
  echo "FAIL - SKIPPED-BANK: reservation not released after refusal"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-BANK: reservation released after refusal (this call's own, created by admission before the bank check ran)"
fi

slots25b="$tmp/slots25b"; mkdir -p "$slots25b/PROJ-4444-noown"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$slots25b/PROJ-4444-noown/expires"
d25b="$tmp/c25b"; mk_launch_stubs "$d25b" "PROJ-4444-noown"; mkdir -p "$tmp/repo25b"
rc=0
HIMMEL_FLEET_SLOTS="$slots25b" run_worker "$d25b" "$tmp/repo25b" "PROJ-4444-noown" "claude-sonnet-5" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ -d "$slots25b/PROJ-4444-noown" ]; then
  echo "ok - SKIPPED-FLEET: a same-name reservation is left untouched (never held one of its own to release)"
else
  echo "FAIL - SKIPPED-FLEET: a same-name reservation was removed - would delete a DIFFERENT pending arm's duplicate-refused slot"
  fails=$((fails+1))
fi

# --- 26. GO gate reachable from a worker worktree: the wrapper
# resolves the CHIEF's own handover root (its own process/cwd, before ANY
# konsole child exists) and exports it explicitly as HANDOVER_DIR into the
# worker's launch env - so a worker's later handover_root() call (run from a
# linked worktree, whose `git rev-parse --show-toplevel` resolves to the
# WORKTREE, not the chief's checkout) binds to the SAME root the chief
# used to write its GO (chief-kit/go.sh), instead of silently re-deriving
# (and missing) a different one. RED on today's code: no HANDOVER_DIR export
# exists at all, so every assertion below fails.
primary26="$tmp/primary26"
mkdir -p "$primary26/handovers" && git -C "$primary26" init -q
d26="$tmp/c26"; mk_launch_stubs "$d26" "PROJ-3155-worker"; mkdir -p "$tmp/repo26"
rc=0
( cd "$primary26" && \
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HANDOVER_DIR='' \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d26/konsole" PGREP_CMD="$d26/pgrep" \
  WORKER_SESSION_REPO="$tmp/repo26" HEADED_ARM_LOCK_DIR="$d26/locks" HEADED_ARM_PROC="$d26/proc" \
    bash "$SCRIPT" --profile worker-impl "PROJ-3155-worker" "$some_doc" "$d26/signal-never" "$PAST" "$d26/log" "claude-sonnet-5" \
) >/dev/null 2>&1 || rc=$?
wait_record "$d26" || true
env26="$(cat "$d26/env-record" 2>/dev/null || true)"
check "HANDOVER_DIR e2e: full launch, chief cwd has inline handovers/: exit 0" "$rc" "0"
contains "HANDOVER_DIR e2e: worker env carries the chief's resolved root verbatim" "$env26" "HANDOVER_DIR=$primary26/handovers"

# --- 26b. The root's .env HANDOVER_DIR (Mode B) reaches the worker
# even when the launching shell exported none: handover_root reads only the live
# env, so a wrapper that skipped load-dotenv.sh resolved the inline stub. An
# explicit (non-empty) env value still wins over .env. RED on the pre-fix
# wrapper: the worker env carries the inline <cwd>/handovers stub instead.
mode_b26="$tmp/modeb26"; mkdir -p "$mode_b26/repo/handovers" "$mode_b26/dotenv-root" "$mode_b26/explicit-root"
git -C "$mode_b26/repo" init -q
printf 'HANDOVER_DIR=%s\n' "$mode_b26/dotenv-root" > "$mode_b26/repo/.env"
for variant26b in dotenv explicit; do
  d26b="$tmp/c26b-$variant26b"; mk_launch_stubs "$d26b" "PROJ-4416-$variant26b"
  want26b="$mode_b26/dotenv-root"; launch_env26b=''
  if [ "$variant26b" = explicit ]; then want26b="$mode_b26/explicit-root"; launch_env26b="$want26b"; fi
  rc=0
  ( cd "$mode_b26/repo" && \
    IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HANDOVER_DIR="$launch_env26b" \
    HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    KONSOLE_CMD="$d26b/konsole" PGREP_CMD="$d26b/pgrep" \
    WORKER_SESSION_REPO="$tmp/repo26" HEADED_ARM_LOCK_DIR="$d26b/locks" HEADED_ARM_PROC="$d26b/proc" \
      bash "$SCRIPT" --profile worker-impl "PROJ-4416-$variant26b" "$some_doc" "$d26b/signal-never" "$PAST" "$d26b/log" "claude-sonnet-5" \
  ) >/dev/null 2>&1 || rc=$?
  wait_record "$d26b" || true
  env26b="$(cat "$d26b/env-record" 2>/dev/null || true)"
  check "PROJ-4416 ($variant26b): full launch exits 0" "$rc" "0"
  contains "PROJ-4416 ($variant26b): worker env carries [$want26b]" "$env26b" "HANDOVER_DIR=$want26b"
  not_contains "PROJ-4416 ($variant26b): worker env never carries the inline stub" "$env26b" "HANDOVER_DIR=$mode_b26/repo/handovers"
done

# End-to-end: a GO written by go.sh from the SAME primary-like cwd (the
# chief's own resolution), then go_gate resolved from a DIFFERENT cwd
# (simulating the worker's linked worktree) using ONLY the HANDOVER_DIR VALUE
# ACTUALLY CAPTURED FROM THE WORKER'S OWN ENV ABOVE (env26, not a hardcoded
# primary26/handovers - a hardcoded value would pass vacuously even if the
# wrapper never exported anything), must find it.
# fail closed BEFORE go.sh runs. The GO root this e2e is about to
# write into is resolved by the exact call go.sh makes (handover_root, from the
# primary-like cwd, HANDOVER_DIR cleared like the launch above) and must sit
# inside this suite's own temp dir; anything else (a live root leaking in)
# skips the write and fails loudly instead of minting a fake GO there.
# go.sh now resolves through go_resolve_root, which prefers
# the anchor's .env HANDOVER_DIR over a cwd-derived inline root - so the
# chief's resolved root is passed explicitly (as the wrapper exports it),
# the guard mirrors go_resolve_root itself, and a scratch HOME keeps go.sh
# from minting its GO key in the operator's real ~/.config/himmel.
home26="$tmp/home26"; mkdir -p "$home26"
# go.sh now resolves this repo's nwo via `gh repo view` to bind
# the GO mac. A gh stub on PATH keeps this e2e hermetic (no real gh/network
# dependency), matching test-go.sh's own stub.
bin26="$tmp/bin26"; mkdir -p "$bin26"
cat > "$bin26/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        json=""
        while [ $# -gt 0 ]; do
            case "$1" in --json) json="$2" ;; esac
            shift
        done
        case "$json" in
            nameWithOwner) printf '%s' "o/r" ;;
            *) exit 90 ;;
        esac ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$bin26/gh"
# go.sh refuses unless ready-check.sh passes, so primary26's CR
# ledger gets an ok row for the head and a gh answering ready-check green sits
# ahead of the stub above (it hands every other call on to that stub).
# shellcheck source=testlib-ready-pass.sh
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready26"
# check 19 fetches origin/main and reads origin/main..<head>: a real head
sha26=$(ready_pass_repo "$primary26") || sha26=""
ready_pass_ledger "$primary26" "$sha26"
check "ready-check's owner-review line over the ready-pass fixture" "$(PATH="$tmp/ready26:$PATH" READY_STUB_HEAD="$sha26" ready_pass_owner_review)" "$READY_PASS_OWNER_LINE"
go_root26="$(cd "$primary26" && HANDOVER_DIR="$primary26/handovers" bash -c '. "$1/../../lib/handover-path.sh" && . "$1/../../lib/go-gate.sh" && go_resolve_root "$1/../../.."' _ "$HERE" 2>/dev/null)" || go_root26=""
case "$go_root26" in
  "$tmp"/?*) echo "ok - HANDOVER_DIR e2e: resolved GO root [$go_root26] is inside the suite's temp dir"; go_root26_ok=1 ;;
  *) echo "FAIL - HANDOVER_DIR e2e: resolved GO root [$go_root26] is not inside the suite's temp dir [$tmp] - refusing to write a GO"; fails=$((fails+1)); go_root26_ok=0 ;;
esac
if [ "$go_root26_ok" -eq 1 ]; then
  go_out26="$(cd "$primary26" && HIMMEL_REPO="$primary26" HOME="$home26" READY_STUB_HEAD="$sha26" PATH="$tmp/ready26:$bin26:$PATH" HIMMEL_CONSOLE_LEG='' HIMMEL_CONSOLE_RELAY='' HANDOVER_DIR="$primary26/handovers" bash "$HERE/go.sh" 26260 "$sha26" 2>/dev/null)"
else
  go_out26="SKIPPED: unsafe GO root"
fi
worker_handover_dir26="$(printf '%s\n' "$env26" | sed -n 's/^HANDOVER_DIR=//p')"
worktree26="$tmp/worktree26"; mkdir -p "$worktree26"
gate_script26="$tmp/gate26.sh"
cat > "$gate_script26" <<EOF
#!/usr/bin/env bash
set -u
. "$HERE/../../lib/handover-path.sh"
. "$HERE/../../lib/go-gate.sh"
root="\$(handover_root)" || exit 9
go_gate 26260 "$sha26" "\$root" "o/r"
EOF
chmod 755 "$gate_script26"
rc2=0
( cd "$worktree26" && HOME="$home26" HANDOVER_DIR="$worker_handover_dir26" bash "$gate_script26" ) >/dev/null 2>&1 || rc2=$?
check "HANDOVER_DIR e2e: go.sh wrote the GO from the chief cwd" "${go_out26##*$'\n'}" "$primary26/handovers/.locks/go/26260.$sha26"
check "HANDOVER_DIR e2e: go_gate resolved from a linked worktree (HANDOVER_DIR only) finds the GO" "$rc2" "0"

# --- 27. An unprofiled launch is REFUSED, not silently launched
# preface-less. Both the dry-run seam AND the real (non-dry) stubbed path are
# driven: the refusal sits before the --dry-run exit, so the dry-run cases
# exercise the decision itself, and the real-path case proves nothing reaches
# konsole. Every shape that supplies a profile (flag, WORKER_SESSION_PROFILE, --relay,
# --judge) or opts out (--no-profile) must still launch.
args27=(PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5)
rc=0; out="$(bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27a no profile, no opt-out (dry-run): refused with exit 2" "$rc" "2"
contains "27a refusal names --profile" "$out" "--profile"
contains "27a refusal names the --no-profile opt-out" "$out" "--no-profile"
not_contains "27a nothing would exec" "$out" "would exec"

d27="$tmp/c27"; mk_launch_stubs "$d27" "PROJ-2727-leg"; mkdir -p "$tmp/repo27"
rc=0
RUN_WORKER_ARGS='' run_worker "$d27" "$tmp/repo27" "PROJ-2727-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
check "27b no profile, no opt-out (real launch): refused with exit 2" "$rc" "2"
sleep 0.3
check "27b refused launch never reached konsole" "$([ -e "$d27/record" ] && echo launched || echo none)" "none"
check "27b refused launch wrote no settings file" "$([ -e "$d27/PROJ-2727-leg.leg-settings.json" ] && echo wrote || echo none)" "none"

# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile "${args27[@]}" 2>&1)" || rc=$?
check "27c --no-profile: launches (dry-run exit 0)" "$rc" "0"
check "27c --no-profile: dry-run report is exactly four lines (effort line + three)" "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" "4"
not_contains "27c --no-profile: no profile line" "$out" "profile="

d27c="$tmp/c27c"; mk_launch_stubs "$d27c" "PROJ-2728-worker"; mkdir -p "$tmp/repo27c"
rc=0
RUN_WORKER_ARGS='--no-profile' run_worker "$d27c" "$tmp/repo27c" "PROJ-2728-worker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d27c" || true
check "27d --no-profile (real launch): exit 0" "$rc" "0"
contains "27d --no-profile records the deliberate opt-out in the launch log" "$(cat "$d27c/log" 2>/dev/null || true)" "--no-profile"
not_contains "27d --no-profile: no preface flag reached claude" "$(cat "$d27c/record" 2>/dev/null || true)" "--append-system-prompt-file"

# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --profile worker-impl "${args27[@]}" 2>&1)" || rc=$?
check "27e --no-profile with --profile: refused with exit 2" "$rc" "2"
# shellcheck disable=SC2086
rc=0; out="$(WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run --no-profile "${args27[@]}" 2>&1)" || rc=$?
check "27e --no-profile with WORKER_SESSION_PROFILE: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27e --no-profile with --relay: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --judge PROJ-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27e --no-profile with --judge: refused with exit 2" "$rc" "2"
contains "27e --no-profile with --judge: the refusal names --no-profile (not the Tier gate)" "$out" "--no-profile"

# Every profile-supplying shape must NOT trip the refusal.
# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl "${args27[@]}" 2>&1)" || rc=$?
check "27f --profile worker-impl: launches" "$rc" "0"
# shellcheck disable=SC2086
rc=0; out="$(WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27f WORKER_SESSION_PROFILE=worker-impl (env seam, no flag): launches" "$rc" "0"
contains "27f WORKER_SESSION_PROFILE=worker-impl: profile applied" "$out" "profile=worker-impl"
# shellcheck disable=SC2086
rc=0; out="$(WORKER_SESSION_PROFILE=worker-impl bash "$SCRIPT" --dry-run --profile bare "${args27[@]}" 2>&1)" || rc=$?
contains "27f flag wins over WORKER_SESSION_PROFILE" "$out" "profile=bare"
rc=0; out="$(bash "$SCRIPT" --dry-run --relay PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27f --relay alone (forces chief-relay): launches" "$rc" "0"
contains "27f --relay: forced profile applied" "$out" "profile=chief-relay"
rc=0; out="$(bash "$SCRIPT" --dry-run --judge PROJ-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27f --judge alone (forces console-judge): launches" "$rc" "0"
contains "27f --judge: forced profile applied" "$out" "profile=console-judge"

# Empty values are not a profile.
# shellcheck disable=SC2086
rc=0; out="$(WORKER_SESSION_PROFILE='' bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27g empty WORKER_SESSION_PROFILE is not a profile: refused with exit 2" "$rc" "2"
# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --profile '' "${args27[@]}" 2>&1)" || rc=$?
check "27g --profile '' is not a profile: refused with exit 2" "$rc" "2"

# claudex lane: the coordination preface alone is not the standing preface.
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27h --lane claudex, no profile, no opt-out: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex --no-profile PROJ-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "27h --lane claudex --no-profile: launches" "$rc" "0"

# --- 28. the launch record ---------------------------------------
# The cost program's cohort metric identifies `worker-impl` sessions from a launch
# record; nothing wrote one. Every REAL launch appends one line to
# $HIMMELCTL_CACHE_DIR/launch-logs/<session>.log (the dir uninstall already
# removes wholesale); --dry-run writes nothing.

check "28a no launch record exists for a session that was never launched" "$([ -e "$LL_DIR/PROJ-3270-N1-dry.log" ] && echo present || echo none)" "none"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-3270-N1-dry "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5-5 2>&1)" || rc=$?
check "28b --dry-run exits 0" "$rc" "0"
check "28b --dry-run writes no launch record" "$([ -e "$LL_DIR/PROJ-3270-N1-dry.log" ] && echo present || echo none)" "none"

d28="$tmp/c28"; mk_launch_stubs "$d28" "PROJ-3270-N2-real"; mkdir -p "$tmp/repo28"
rc=0
CANARY_SECRET=hunter2-canary ANTHROPIC_API_KEY=sk-canary-not-real \
  run_worker "$d28" "$tmp/repo28" "PROJ-3270-N2-real" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28" || true
check "28c real --profile worker-impl launch: exit 0" "$rc" "0"
rec28="$(ll_line PROJ-3270-N2-real)"
check "28c launch record is exactly one line" "$(ll_line PROJ-3270-N2-real | wc -l | tr -d '[:space:]')" "1"
# The reader (agg-postpin.sh cohort_ok) matches a whitespace-delimited field
# exactly equal to profile=<name>, so the field must stand alone.
check "28c record carries the profile field the cohort reader matches" "$(printf '%s\n' "$rec28" | awk '{for(i=1;i<=NF;i++) if($i=="profile=worker-impl"){f=1}} END{print f+0}')" "1"
contains "28c record names the session" "$rec28" " session=PROJ-3270-N2-real "
contains "28c record names the role" "$rec28" " role=worker "
contains "28c record names the lane" "$rec28" " lane=native "
contains "28c record names the model" "$rec28" " model=claude-sonnet-5 "
check "28c record ends with an ISO-8601 UTC launch time" "$(printf '%s\n' "$rec28" | grep -Ec ' launched=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
# No secrets: launch metadata only - never an env value.
not_contains "28c record holds no env value (canary secret)" "$rec28" "hunter2-canary"
not_contains "28c record holds no env value (canary key)" "$rec28" "sk-canary-not-real"
check "28c record carries only the fixed launch-metadata keys" "$(printf '%s\n' "$rec28" | tr ' ' '\n' | sed 1d | cut -d= -f1 | paste -sd, -)" "profile,lane,model,role,session,session_id,launched"

d28b="$tmp/c28b"; mk_launch_stubs "$d28b" "PROJ-3270-N3-noprof"; mkdir -p "$tmp/repo28b"
RUN_WORKER_ARGS='--no-profile' run_worker "$d28b" "$tmp/repo28b" "PROJ-3270-N3-noprof" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28b" || true
rec28b="$(ll_line PROJ-3270-N3-noprof)"
contains "28d --no-profile launch is recorded as profile=none" "$rec28b" " profile=none "
contains "28d --no-profile launch is still role=worker" "$rec28b" " role=worker "

d28c="$tmp/c28c"; mk_launch_stubs "$d28c" "PROJ-3270-N4-relay"; mkdir -p "$tmp/repo28c"
RUN_WORKER_ARGS='--relay' run_worker "$d28c" "$tmp/repo28c" "PROJ-3270-N4-relay" >/dev/null 2>&1 || true
wait_record "$d28c" || true
rec28c="$(ll_line PROJ-3270-N4-relay)"
contains "28e --relay launch is recorded with its forced profile" "$rec28c" " profile=chief-relay "
contains "28e --relay launch is recorded role=relay" "$rec28c" " role=relay "

d28d="$tmp/c28d"; mk_launch_stubs "$d28d" "PROJ-3270-N5-judge"; mkdir -p "$tmp/repo28d"
RUN_WORKER_ARGS='--judge' run_worker "$d28d" "$tmp/repo28d" "PROJ-3270-N5-judge" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28d" || true
rec28d="$(ll_line PROJ-3270-N5-judge)"
contains "28f --judge launch is recorded with its forced profile" "$rec28d" " profile=console-judge "
contains "28f --judge launch is recorded role=judge" "$rec28d" " role=judge "

# --- Full (non-dry) launches: the
# --dry-run cases above (~line 555) only prove the HEADED_ARM_LAUNCHER_ENV
# token-list channel is scrubbed - they never exec anything, so they cannot
# see a plain-var leak that only reaches a real (here: stubbed) downstream
# process. These full launches route through the real headed-arm.sh and its
# konsole stub, which records every name in its allowlist (mk_launch_stubs
# above) from ITS OWN process env - the only way to prove the plain
# WORKER_SESSION_CLAUDE_BIN/CLAUDE_CODE_EFFORT_LEVEL a worker's shell inherited from ITS OWN
# launch never survives the exec chain into an armed judge/worker. ------------

# Finding 1: a claudex worker's own ambient WORKER_SESSION_CLAUDE_BIN=<claude-codex>, still
# exported in that worker's shell, must not reach a native judge it arms.
d28e="$tmp/c28e"; mk_launch_stubs "$d28e" "PROJ-3795-N1-binleak"; mkdir -p "$tmp/repo28e"
rc=0
HIMMEL_CONSOLE_JUDGE_QID=ambient-sibling HIMMEL_CONSOLE_JUDGE_DOC=/tmp/ambient-sibling-judge-1.md \
WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-codex-bin \
  RUN_WORKER_ARGS='--judge' run_worker "$d28e" "$tmp/repo28e" "PROJ-3795-N1-binleak" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28e" || true
env28e="$(cat "$d28e/env-record" 2>/dev/null || true)"
check "full --judge launch, ambient WORKER_SESSION_CLAUDE_BIN: exit 0" "$rc" "0"
contains "full --judge launch, ambient WORKER_SESSION_CLAUDE_BIN: env-record was actually produced (judge still gets its high default)" "$env28e" "CLAUDE_CODE_EFFORT_LEVEL=high"
not_contains "full --judge launch, ambient WORKER_SESSION_CLAUDE_BIN: does not reach the armed process env" "$env28e" "WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-codex-bin"
contains "full --judge launch exports HIMMEL_CONSOLE_JUDGE=1 (guard-judge-writes.sh marker)" "$env28e" "HIMMEL_CONSOLE_JUDGE=1"
# the judge guard is bound to THIS judge's doc and qid. A doc
# whose resume_cwd is ~/.cache/himmel/verdicts/<qid>/scratch yields both; a
# plain worker gets neither; a judge doc with another resume_cwd gets the doc only.
mkdir -p "$tmp/home4608/.cache/himmel/verdicts/Q4608/scratch"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 3\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$tmp/home4608/.cache/himmel/verdicts/Q4608/scratch" > "$tmp/c4608-doc.md"
d4608="$tmp/c4608"; mk_launch_stubs "$d4608" "PROJ-4608-N1-bind"; mkdir -p "$tmp/repo4608"
rc=0
some_doc="$tmp/c4608-doc.md" RUN_WORKER_ARGS="--judge" run_worker "$d4608" "$tmp/repo4608" "PROJ-4608-N1-bind" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d4608" || true
env4608="$(cat "$d4608/env-record" 2>/dev/null || true)"
check "full --judge launch with a verdicts scratch resume_cwd: exit 0" "$rc" "0"
contains "--judge launch exports its own doc" "$env4608" "HIMMEL_CONSOLE_JUDGE_DOC=$tmp/c4608-doc.md"
contains "--judge launch exports its qid" "$env4608" "HIMMEL_CONSOLE_JUDGE_QID=Q4608"
contains "PROJ-4608 control: the env-record was produced by a judge launch" "$env4608" "HIMMEL_CONSOLE_JUDGE=1"
not_contains "full --judge launch (other doc) carries no binding to a qid it cannot derive" "$env28e" "HIMMEL_CONSOLE_JUDGE_QID="
not_contains "an ambient sibling qid never reaches a judge whose qid is underivable" "$env28e" "ambient-sibling"
not_contains "an ambient sibling doc never reaches the armed judge" "$env28e" "HIMMEL_CONSOLE_JUDGE_DOC=/tmp/ambient-sibling-judge-1.md"

# Same leak, native --profile worker-impl instead of --judge (the ticket's other
# named case).
d28f="$tmp/c28f"; mk_launch_stubs "$d28f" "PROJ-3795-N2-binleak-profile"; mkdir -p "$tmp/repo28f"
rc=0
WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-codex-bin \
  RUN_WORKER_ARGS='--profile worker-impl' run_worker "$d28f" "$tmp/repo28f" "PROJ-3795-N2-binleak-profile" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28f" || true
env28f="$(cat "$d28f/env-record" 2>/dev/null || true)"
check "full --profile worker-impl launch, ambient WORKER_SESSION_CLAUDE_BIN: exit 0" "$rc" "0"
contains "full --profile worker-impl launch, ambient WORKER_SESSION_CLAUDE_BIN: env-record was actually produced (WORKER_SESSION_PROFILE_SETTINGS still resolved)" "$env28f" "WORKER_SESSION_PROFILE_SETTINGS="
not_contains "full --profile worker-impl launch, ambient WORKER_SESSION_CLAUDE_BIN: does not reach the armed process env" "$env28f" "WORKER_SESSION_CLAUDE_BIN=/tmp/stale-claude-codex-bin"

# Finding 2: a worker's own ambient CLAUDE_CODE_EFFORT_LEVEL=low (inherited from
# ITS OWN low-effort launch) must not override a judge it arms - the judge
# still gets high.
# CLAUDE_CODE_EFFORT_LEVEL is a Claude Code marker to the seam guard
# with no claude ancestor (CI) a marker plus the preflight seam
# is refused. A real worker has a claude ancestor whose launch env carries both,
# so run under a stand-in `claude` process (argv[0]) holding them.
# shellcheck disable=SC2317,SC2329  # _as_claude is invoked indirectly, through RUN_WORKER_WRAP
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }
d28g="$tmp/c28g"; mk_launch_stubs "$d28g" "PROJ-3795-N3-effortleak"; mkdir -p "$tmp/repo28g"
rc=0
CLAUDE_CODE_EFFORT_LEVEL=low HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  RUN_WORKER_ARGS='--judge' RUN_WORKER_WRAP=_as_claude run_worker "$d28g" "$tmp/repo28g" "PROJ-3795-N3-effortleak" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28g" || true
env28g="$(cat "$d28g/env-record" 2>/dev/null || true)"
check "full --judge launch, ambient CLAUDE_CODE_EFFORT_LEVEL=low: exit 0" "$rc" "0"
contains "full --judge launch, ambient CLAUDE_CODE_EFFORT_LEVEL=low: judge still gets high" "$env28g" "CLAUDE_CODE_EFFORT_LEVEL=high"
not_contains "full --judge launch, ambient CLAUDE_CODE_EFFORT_LEVEL=low: ambient low never reaches the armed process" "$env28g" "CLAUDE_CODE_EFFORT_LEVEL=low"

# Control: a chief's DELIBERATE override (HIMMEL_CONSOLE_JUDGE_EFFORT) still
# wins over the high default - the fix must not make every override
# impossible, only the ambient/inherited kind.
d28h="$tmp/c28h"; mk_launch_stubs "$d28h" "PROJ-3795-N4-effortoverride"; mkdir -p "$tmp/repo28h"
rc=0
HIMMEL_CONSOLE_JUDGE_EFFORT=medium \
  RUN_WORKER_ARGS='--judge' run_worker "$d28h" "$tmp/repo28h" "PROJ-3795-N4-effortoverride" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28h" || true
env28h="$(cat "$d28h/env-record" 2>/dev/null || true)"
check "full --judge launch, explicit HIMMEL_CONSOLE_JUDGE_EFFORT: exit 0" "$rc" "0"
contains "full --judge launch, explicit HIMMEL_CONSOLE_JUDGE_EFFORT: the override wins" "$env28h" "CLAUDE_CODE_EFFORT_LEVEL=medium"
not_contains "full --judge launch, explicit HIMMEL_CONSOLE_JUDGE_EFFORT: the high default is not also present" "$env28h" "CLAUDE_CODE_EFFORT_LEVEL=high"

# The chief marker a chief session carries must never reach a worker it arms;
# admission authority is the chief's alone.
d28j="$tmp/c28j"; mk_launch_stubs "$d28j" "PROJ-6918-N1-consolemarker"; mkdir -p "$tmp/repo28j"
rc=0
HIMMEL_CONSOLE=1 \
  RUN_WORKER_ARGS='--profile worker-impl' run_worker "$d28j" "$tmp/repo28j" "PROJ-6918-N1-consolemarker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28j" || true
env28j="$(cat "$d28j/env-record" 2>/dev/null || true)"
check "full worker launch, ambient HIMMEL_CONSOLE=1: exit 0" "$rc" "0"
contains "full worker launch, ambient HIMMEL_CONSOLE=1: env-record was actually produced" "$env28j" "HIMMEL_CONSOLE_LEG=1"
not_contains "full worker launch, ambient HIMMEL_CONSOLE=1: the chief marker never reaches the worker" "$env28j" "HIMMEL_CONSOLE=1"

# Control (chief ruling): the two new seam names themselves
# (HEADED_ARM_WORKER_CLAUDE_BIN, HIMMEL_CONSOLE_JUDGE_EFFORT) must not reach the
# armed process's own env - otherwise a worker armed with either one ambiently
# set could push it into a judge IT arms, moving the leak one level rather
# than closing it. Both seams are exercised together so a single launch
# proves both are consumed-then-scrubbed, not merely consumed.
d28i="$tmp/c28i"; mk_launch_stubs "$d28i" "PROJ-3795-N5-seamscrub"; mkdir -p "$tmp/repo28i"
rc=0
HEADED_ARM_WORKER_CLAUDE_BIN=/tmp/test-claude-stub HIMMEL_CONSOLE_JUDGE_EFFORT=medium \
  RUN_WORKER_ARGS='--judge' run_worker "$d28i" "$tmp/repo28i" "PROJ-3795-N5-seamscrub" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28i" || true
env28i="$(cat "$d28i/env-record" 2>/dev/null || true)"
check "full --judge launch, both seams set: exit 0" "$rc" "0"
contains "full --judge launch, both seams set: WORKER_SESSION_CLAUDE_BIN takes the seam's value" "$env28i" "WORKER_SESSION_CLAUDE_BIN=/tmp/test-claude-stub"
contains "full --judge launch, both seams set: effort override applied" "$env28i" "CLAUDE_CODE_EFFORT_LEVEL=medium"
not_contains "full --judge launch, both seams set: HEADED_ARM_WORKER_CLAUDE_BIN itself never reaches the armed process (cannot leak into a nested arm)" "$env28i" "HEADED_ARM_WORKER_CLAUDE_BIN="
not_contains "full --judge launch, both seams set: HIMMEL_CONSOLE_JUDGE_EFFORT itself never reaches the armed process (cannot leak into a nested arm)" "$env28i" "HIMMEL_CONSOLE_JUDGE_EFFORT="

# a judge does not implement (design 3.2) and never needs to
# write a WORKER's handover doc, so it must not gain the Edit-allow grant even
# though it resolves its own DOC/HANDOVER_DIR too.
judge_doc_canon="$(cd -P "$(dirname "$some_doc")" && pwd -P)/$(basename "$some_doc")"
check "28f --judge launch does not gain the handover-doc Edit allow (judge never implements)" \
  "$(jq --arg f "$judge_doc_canon" '(.permissions.allow // []) | any(. == ("Edit(/" + $f + ")"))' "$d28d/PROJ-3270-N5-judge.leg-settings.json" 2>/dev/null)" \
  "false"

# The grant is scoped to THIS worker's own doc
# file, never a root-wide glob - a second worker in the same handover bucket
# must NOT gain Edit on the first worker's doc (d17's $some_doc),
# and must gain it on its own, distinct doc file.
d17b_doc="$tmp/sibling-doc.md"
fx_brief '# sibling fixture doc' > "$d17b_doc"
d17b="$tmp/c17b"; mk_launch_stubs "$d17b" "PROJ-3334-leg"; mkdir -p "$tmp/repo17b"
IMPL_GUARD_OK='' HIMMEL_LEAN_WORKER_SESSION='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b/konsole" PGREP_CMD="$d17b/pgrep" \
WORKER_SESSION_REPO="$tmp/repo17b" HEADED_ARM_LOCK_DIR="$d17b/locks" HEADED_ARM_PROC="$d17b/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-3334-leg" "$d17b_doc" "$d17b/signal-never" "$PAST" "$d17b/log" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d17b" || true
d17b_doc_canon="$(cd -P "$(dirname "$d17b_doc")" && pwd -P)/$(basename "$d17b_doc")"
check "a worker's settings grant Edit on its OWN doc" \
  "$(jq --arg f "$d17b_doc_canon" '(.permissions.allow // []) | any(. == ("Edit(/" + $f + ")"))' "$d17b/PROJ-3334-leg.leg-settings.json" 2>/dev/null)" \
  "true"
check "a worker's settings do NOT grant Edit on a SIBLING worker's doc in the same bucket" \
  "$(jq --arg f "$some_doc_canon" '(.permissions.allow // []) | any(. == ("Edit(/" + $f + ")"))' "$d17b/PROJ-3334-leg.leg-settings.json" 2>/dev/null)" \
  "false"

# A relaunch of the same session name appends, never replaces: the record is
# history, and a replaced line would erase what the first launch really was.
d28e="$tmp/c28e"; mk_launch_stubs "$d28e" "PROJ-3270-N2-real"; mkdir -p "$tmp/repo28e"
run_worker "$d28e" "$tmp/repo28e" "PROJ-3270-N2-real" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28e" || true
check "28g a relaunch of the same session appends a second line" "$(ll_line PROJ-3270-N2-real | wc -l | tr -d '[:space:]')" "2"

# Best-effort: a record that cannot be written must not stop the launch, and
# must say so in the launch log rather than fail silently.
d28f="$tmp/c28f"; mk_launch_stubs "$d28f" "PROJ-3270-N6-blocked"; mkdir -p "$tmp/repo28f"
: > "$tmp/not-a-dir"
rc=0
HIMMELCTL_CACHE_DIR="$tmp/not-a-dir" run_worker "$d28f" "$tmp/repo28f" "PROJ-3270-N6-blocked" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28f" || true
check "28h an unwritable record dir does not stop the launch (exit 0)" "$rc" "0"
check "28h ... and the launch still reached konsole" "$([ -s "$d28f/record" ] && echo launched || echo none)" "launched"
contains "28h ... and the launch log says the record was not written" "$(cat "$d28f/log" 2>/dev/null || true)" "launch record NOT written"

# With no resolvable cache dir (HOME empty, no HIMMELCTL_CACHE_DIR) nothing is
# written at all: falling back to /tmp would leave residue uninstall cannot find
# (the accepted HOME-unset divergence, not repeated here).
d28g="$tmp/c28g"; mk_launch_stubs "$d28g" "PROJ-3270-N7-nohome"; mkdir -p "$tmp/repo28g"
rc=0
HOME='' HIMMELCTL_CACHE_DIR='' run_worker "$d28g" "$tmp/repo28g" "PROJ-3270-N7-nohome" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28g" || true
check "28i no resolvable cache dir: launch still exits 0" "$rc" "0"
check "28i no resolvable cache dir: nothing written under /tmp/.claude" "$([ -e /tmp/.claude/himmel/launch-logs/PROJ-3270-N7-nohome.log ] && echo wrote || echo none)" "none"

lr_bucket="$tmp/lr-bucket"; mkdir -p "$lr_bucket"
printf '{"family":"lr"}\n' > "$lr_bucket/fleet-control.json"
export BRIDGE_ROOT="$HOME/.claude/handover/bridge"
lr_inbox="$BRIDGE_ROOT/consoles/lr-chief.md"
mkdir -p "${lr_inbox%/*}"; : > "$lr_inbox"
lr_run() {
  local d="$1" n="$2" doc="$3"; shift 3
  lr_rc=0
  lr_out="$(HIMMEL_CONSOLE_NAME=lr-chief IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
    HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" KONSOLE_CMD="$d/konsole" PGREP_CMD="$d/pgrep" \
    WORKER_SESSION_REPO="$tmp/repo29" HEADED_ARM_LOCK_DIR="$d/locks" HEADED_ARM_PROC="$d/proc" \
    bash "$SCRIPT" --profile worker-impl "$@" "$n" "$doc" "$d/signal-never" "$PAST" "$d/log" claude-sonnet-5 2>&1)" || lr_rc=$?
}
mkdir -p "$tmp/repo29"
lr_doc="$lr_bucket/PROJ-29-N1-nomanifest.md"
fx_brief '# PROJ-29 — fixture — worker N1 (claude-sonnet-5)' > "$lr_doc"
d29a="$tmp/c29a"; mk_launch_stubs "$d29a" "PROJ-29-N1-nomanifest"
lr_since=$(date +%s); lr_run "$d29a" PROJ-29-N1-nomanifest "$lr_doc"
check "29a a managed worker with no manifest reference is refused (exit 10)" "$lr_rc" "10"
contains "29a ... the launch log carries the LAUNCH-REFUSED line with the cause" "$(cat "$d29a/log" 2>/dev/null)" "LAUNCH-REFUSED PROJ-29-N1-nomanifest fleet-paused: managed worker has no manifest reference"
contains "29a ... and the chief inbox carries it" "$(cat "$lr_inbox")" "LAUNCH-REFUSED PROJ-29-N1-nomanifest fleet-paused: managed worker has no manifest reference"
check "29a ... and konsole was never reached" "$([ -s "$d29a/record" ] && echo launched || echo none)" "none"
contains "29a ... and the log opens on the attempt's LAUNCH-START line" "$(head -n 1 "$d29a/log" 2>/dev/null)" "LAUNCH-START PROJ-29-N1-nomanifest epoch="
lr_rc=0; lr_out="$(PGREP_CMD="$d29a/pgrep" bash "$HERE/launch-confirm.sh" --since "$lr_since" --chief lr-chief --secs 1 PROJ-29-N1-nomanifest "$d29a/log" 2>&1)" || lr_rc=$?
check "29a ... and launch-confirm reports the refused attempt (exit 1)" "$lr_rc" "1"
contains "29a ... naming the launcher's reason" "$lr_out" "LAUNCH-UNCONFIRMED PROJ-29-N1-nomanifest the launcher refused: fleet-paused: managed worker has no manifest reference"
lr_wt_doc="$tmp/lr-wt-doc.md"
{ printf -- '---\nresume_cwd: %s\ndescription: x\n---\n' "$tmp/repo29/.claude/worktrees/feat+missing-29"; printf '%s\n' '> **Prior art:** none found (qmd -c jira-himmel "fixture")'; } > "$lr_wt_doc"
d29b="$tmp/c29b"; mk_launch_stubs "$d29b" "PROJ-29-N2-noworktree"
lr_run "$d29b" PROJ-29-N2-noworktree "$lr_wt_doc"
check "29b a brief whose resume_cwd worktree is missing is refused (exit 2)" "$lr_rc" "2"
contains "29b ... the launch log carries the LAUNCH-REFUSED line with the cause" "$(cat "$d29b/log" 2>/dev/null)" "LAUNCH-REFUSED PROJ-29-N2-noworktree the doc's resume_cwd ($tmp/repo29/.claude/worktrees/feat+missing-29) is not an existing git worktree"
contains "29b ... and the chief inbox carries it" "$(cat "$lr_inbox")" "LAUNCH-REFUSED PROJ-29-N2-noworktree the doc's resume_cwd"
d29c="$tmp/c29c"; mk_launch_stubs "$d29c" "PROJ-29-N1-nomanifest"
lr_before="$(wc -l < "$lr_inbox")"
lr_run "$d29c" PROJ-29-N1-nomanifest "$lr_doc" --dry-run
check "29c --dry-run refuses the no-manifest launch the real launch refuses (exit 10)" "$lr_rc" "10"
contains "29c ... with the same cause" "$lr_out" "managed worker has no manifest reference"
lr_run "$d29c" PROJ-29-N2-noworktree "$lr_wt_doc" --dry-run
check "29c --dry-run refuses the missing-worktree launch (exit 2)" "$lr_rc" "2"
check "29c ... and a dry run writes no launch log" "$([ -e "$d29c/log" ] && echo wrote || echo none)" "none"
check "29c ... and no inbox line" "$(wc -l < "$lr_inbox")" "$lr_before"
lr_rc=0; HIMMEL_CONSOLE_NAME=lr-chief bash "$SCRIPT" --profile worker-impl PROJ-29-N3-short "$lr_doc" >/dev/null 2>&1 || lr_rc=$?
check "29d a usage refusal exits 2" "$lr_rc" "2"
contains "29d ... and the chief inbox names the session" "$(cat "$lr_inbox")" "LAUNCH-REFUSED PROJ-29-N3-short"
lr_other_inbox="${lr_inbox%/*}/inherited-chief.md"; : > "$lr_other_inbox"
lr_inh_log="$tmp/inherited-29h.log"
lr_rc=0; HIMMEL_CONSOLE_NAME=lr-chief LOG="$lr_inh_log" NAME=inherited-session CHIEF_NAME=inherited-chief bash "$SCRIPT" --profile worker-impl PROJ-29-N8-inherit "$lr_doc" >/dev/null 2>&1 || lr_rc=$?
check "29h a usage refusal with LOG, NAME and CHIEF_NAME exported exits 2" "$lr_rc" "2"
check "29h ... never writes the inherited LOG" "$([ -e "$lr_inh_log" ] && echo wrote || echo none)" "none"
check "29h ... never routes to the inherited CHIEF_NAME" "$(wc -c < "$lr_other_inbox" | tr -d ' ')" "0"
not_contains "29h ... never names the inherited NAME" "$(cat "$lr_inbox")" "inherited-session"
contains "29h ... names the scanned session to the scanned chief" "$(cat "$lr_inbox")" "LAUNCH-REFUSED PROJ-29-N8-inherit"
lr_form="$(sed -n '/^setsid nohup bash scripts\/handover\/chief-kit\/headed-arm-worker.sh/,/&$/p' "$HERE/../../../docs/handover/running-a-chief.md")"
contains "29e the documented launch form passes --fleet" "$lr_form" "--fleet"
not_contains "29e the documented launch form no longer sends stderr to /dev/null" "$lr_form" ">/dev/null 2>&1"
contains "29e the documented launch form logs stderr" "$lr_form" "2>&1 &"
lr_tpl="$(sed -n '/^4\. Launch:/,/^5\. /p' "$HERE/../../../docs/handover/chief-template.md")"
contains "29e the chief template's launch line passes --fleet" "$lr_tpl" "--fleet"
contains "29e the chief template's launch line runs launch-confirm.sh" "$lr_tpl" "launch-confirm.sh"
not_contains "29e the chief template's launch line no longer sends stderr to /dev/null" "$lr_tpl" ">/dev/null 2>&1"
d29f="$tmp/c29f"; mk_launch_stubs "$d29f" "PROJ-29-N6-ok"; mkdir -p "$tmp/repo29f"
lr_since=$(date +%s); lr_rc=0; run_worker "$d29f" "$tmp/repo29f" "PROJ-29-N6-ok" "claude-sonnet-5" >/dev/null 2>&1 || lr_rc=$?
check "29f a launch that starts its session exits 0" "$lr_rc" "0"
contains "29f ... and closes its attempt with LAUNCH-OK" "$(cat "$d29f/log" 2>/dev/null)" "LAUNCH-OK PROJ-29-N6-ok launched"
lr_rc=0; lr_out="$(PGREP_CMD="$d29f/pgrep" bash "$HERE/launch-confirm.sh" --since "$lr_since" --secs 2 PROJ-29-N6-ok "$d29f/log" 2>&1)" || lr_rc=$?
check "29f ... and launch-confirm confirms it" "$lr_out" "LAUNCH-CONFIRMED PROJ-29-N6-ok pid=9001"
mk_anchorless_tree "$tmp/tree29g"; rm "$tmp/tree29g/scripts/lib/chokepoint-seam-guard.sh"; mkdir -p "$tmp/c29g"
lr_rc=0; HIMMEL_CONSOLE_NAME=lr-chief bash "$tmp/tree29g/scripts/handover/chief-kit/headed-arm-worker.sh" --profile worker-impl PROJ-29-N7-noguard "$lr_doc" "$tmp/c29g/sig" 1 "$tmp/c29g/log" claude-sonnet-5 >/dev/null 2>&1 || lr_rc=$?
check "29g a launch the seam guard refuses exits 96" "$lr_rc" "96"
contains "29g ... and its log opens the attempt" "$(cat "$tmp/c29g/log" 2>/dev/null)" "LAUNCH-START PROJ-29-N7-noguard epoch="
contains "29g ... and closes it with LAUNCH-REFUSED" "$(cat "$tmp/c29g/log" 2>/dev/null)" "LAUNCH-REFUSED PROJ-29-N7-noguard cannot load"
contains "29g ... and the chief inbox carries it" "$(cat "$lr_inbox")" "LAUNCH-REFUSED PROJ-29-N7-noguard cannot load"


l1_launch() {
  local tree="$tmp/tree-l1-$1" name="PROJ-9631-N1-l1$1" doc
  mk_anchorless_tree "$tree"
  rm "$tree/scripts/lib/fleet-reservation-key.sh"
  # shellcheck disable=SC2016
  printf '. %q\nif [ %q = every ] || [ ! -e %q ]; then echo x >> %q; rm -rf "$SLOTS/.admit"; fi\n' \
    "$(cd "$HERE/../../lib" && pwd)/fleet-reservation-key.sh" "$2" "$tree/fired" "$tree/fired" > "$tree/scripts/lib/fleet-reservation-key.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tree/target.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tree/ps"
  chmod 755 "$tree/target.sh" "$tree/ps"; mkdir -p "$tree/proc"
  mkdir -p "$tmp/l1-$1"; doc="$tmp/l1-$1/$name.md"; fx_brief "# $name" > "$doc"
  l1_manifest="$tmp/l1-$1/fleet.json"
  bash "$HERE/fleet-manifest.sh" control init "$l1_manifest" --target 4 >/dev/null || return 1
  bash "$HERE/fleet-manifest.sh" control set "$l1_manifest" --mode active --expect-gen 1 >/dev/null || return 1
  bash "$HERE/fleet-manifest.sh" add "$l1_manifest" "$doc" --lane native --pending >/dev/null || return 1
  l1_tree="$tree" l1_log="$tmp/log-l1-$1" l1_rc=0
  FLEET_ADMIT_LAUNCH_WAIT_SECS=10 FLEET_PS_CMD="$tree/ps" FLEET_PROC="$tree/proc" CADENCE_USAGE_SKIP_REFRESH=1 \
    CADENCE_USAGE_CACHE="$tmp/no-native-cache" HEADED_ARM_WORKER_TARGET="$tree/target.sh" \
    HEADED_ARM_WORKER_PREFLIGHT="$tree/scripts/lib/usage-preflight.sh" \
    bash "$SCRIPT" --no-profile --fleet "$l1_manifest" "$name" "$doc" "$tmp/sig-l1-$1" "$PAST" "$l1_log" claude-sonnet-5-5 >/dev/null 2>&1 || l1_rc=$?
  l1_cause="$(jq -rs --arg n "$name" '[.[] | select(.name == $n)] | last | .cause' "$HOME/.himmel/launch-refusals.jsonl" 2>/dev/null)"
  [ -e "$tree/fired" ] || grep -E 'bank-preflight|fleet-runtime|refusing' "$l1_log" 2>/dev/null | tail -4
}
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP - L1/L1c: fleet-manifest.sh needs util-linux flock, absent here"
else
l1_launch every every
check "L1 the whole-lock loss trigger fired" yes "$([ -e "$l1_tree/fired" ] && echo yes || echo no)"
check "L1 a lock lost on every pass: exit 10" 10 "$l1_rc"
check "L1 ... recorded as an admission refusal, not a pause" fleet-admission "$l1_cause"
check "L1 ... the log holds the preflight's lost-lock refusal" yes "$(grep -qF 'was lost during admission (pre-reserve) and the re-admissions did not keep it' "$l1_log" && echo yes || echo no)"
check "L1 ... and never the fleet cap" no "$(grep -qE 'fleet-size cap reached|FLEET_CAP_OK' "$l1_log" && echo yes || echo no)"
l1_launch once once
check "L1c the whole-lock loss trigger fired once" 1 "$(grep -c x "$l1_tree/fired" 2>/dev/null)"
check "L1c a lock lost once: the launch passes the preflight" no "$(grep -q 'fleet admission refused' "$l1_log" && echo yes || echo no)"
check "L1c ... after one re-admission" yes "$(grep -qF 'admission lock lost (pre-reserve) — re-running admission (1 of 2)' "$l1_log" && echo yes || echo no)"
fi

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-headed-arm-worker.sh"
  exit 0
else
  echo "FAIL - test-headed-arm-worker.sh ($fails failure(s))"
  exit 1
fi
