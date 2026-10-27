#!/usr/bin/env bash
# test-observability-stack-manifest.sh — regression guard for the observability-stack manifest item
# (observability stack has zero install-manifest coverage).
#
# Mirrors test-himmel-ops-plugin-enablement.sh's structure exactly: a
# handful of self-contained cases run against the REAL manifest.json/
# manifest-lint.mjs/probes.js, no fixture harness invented.
#
# Cases:
#   a. manifest.json still lints clean.
#   b. manifest.json carries an "observability-stack" item wired to
#      probe.type:observability-stack and install.type:observability
#      (target:stack) — the item this ticket exists to add.
#   c. a malformed observability-stack probe descriptor (an unknown extra
#      field) is REJECTED by manifest-lint — the closed-shape check.
#   e. when not opted in, the probe reads absent, honestly naming the
#      observability.enabled opt-in key — never present, never a
#      repairable-looking degraded.
#   g. status-report.js's severity mapping: probe.actual:absent (not opted in)
#      is downgraded to 'n/a' — the operator can never converge this without
#      opting in, so it must not read as an alarm. Proves the false-red class
#      the doc-guard-map/graphify-mcp precedent blocks already fixed doesn't
#      reopen for this item.
#   h. status-report.js's severity mapping: probe.actual:degraded stays
#      'degraded' — proves the n/a downgrade is scoped to 'absent' only and
#      can never swallow a real partial-install warning.
#   j. install-engine.js's dispatch for install.type:observability:
#      planInstall() with an injected ctx.platform (no global process.platform
#      stubbing needed — install-engine.js reads ctx.platform directly)
#      resolves to an `unrunnable` entry (never a cmd/args spawn shape at all)
#      naming the opt-in key when not opted in, and to
#      `bash install-stack.sh install` when opted in — asserted on the
#      returned descriptor, not on side effects.
# shellcheck disable=SC2016  # case k's stub scripts expand $* / $OBS_* when THEY run, not here
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
install_engine_lib="$repo_root/scripts/himmelctl/lib/install-engine.js"
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-obs-stack-test.XXXXXX") || fail "mktemp -d failed"
[ -n "$work" ] || fail "mktemp -d produced an empty path"
trap 'rm -rf "$work"' EXIT

# posix is opt-in via observability.enabled in the luna config.
# Pin BOTH fixtures so no case ever reads the operator's real config file.
cfg_off="$work/config-off.json"   # absent file = defaults = not opted in
cfg_on="$work/config-on.json"
printf '{"version":1,"observability":{"enabled":true}}\n' > "$cfg_on"
export HIMMEL_LUNA_CONFIG_PATH="$cfg_off"

# winpath <path> — MSYS/Git-Bash paths confuse node's own path resolution
# when handed straight through; convert to a Windows-form path there, pass
# through unchanged elsewhere. Mirrors test-wizard-manifest-v2.sh's own
# helper.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── case a: manifest.json still lints clean ─────────────────────────────
outA=$(MANIFEST_PATH="$(winpath "$manifest_path")" "$node_bin" "$(winpath "$lint")" 2>&1) \
  || fail "case a: manifest.json should lint clean (got): $outA"
echo "ok: case a — manifest.json lints clean"

# ── case b: manifest.json has an observability-stack item wired to the
# new probe.type + install.type ──────────────────────────────────────────
obsItem=$(jq -c '[.items[] | select(.id == "observability-stack")] | .[0] // empty' "$manifest_path")
[ -n "$obsItem" ] || fail "case b: manifest.json has no 'observability-stack' item — HIMMEL-2326 regression"
[ "$(echo "$obsItem" | jq -r '.probe.type')" = "observability-stack" ] \
  || fail "case b: observability-stack item's probe.type must be 'observability-stack', got: $obsItem"
[ "$(echo "$obsItem" | jq -r '.install.type')" = "observability" ] \
  || fail "case b: observability-stack item's install.type must be 'observability', got: $obsItem"
[ "$(echo "$obsItem" | jq -r '.install.target')" = "stack" ] \
  || fail "case b: observability-stack item's install.target must be 'stack', got: $obsItem"
echo "ok: case b — manifest.json has an observability-stack item probing observability-stack, install.type:observability target:stack"

# ── case c: a malformed probe descriptor (unknown extra field) is
# REJECTED — closed-shape check ──────────────────────────────────────────
badManifest="$work/manifest-bad-probe.json"
jq '(.items[] | select(.id == "observability-stack") | .probe) |= (. + {"bogus": true})' \
  "$manifest_path" > "$badManifest"
outC=$(MANIFEST_PATH="$(winpath "$badManifest")" "$node_bin" "$(winpath "$lint")" 2>&1) && \
  fail "case c: manifest-lint should have REJECTED an observability-stack probe with an unknown 'bogus' field, but it exited 0: $outC"
outC_match=$(printf '%s' "$outC" | grep -E "unexpected field" || true)
[ -n "$outC_match" ] \
  || fail "case c: manifest-lint's rejection should name the unexpected field, got: $outC"
echo "ok: case c — a malformed observability-stack probe descriptor (extra field) is rejected"

# ── case e: NOT opted in, the probe reads a CLEAN absence naming
# the opt-in key — never present, never degraded ──────────────
outE=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = { probe: { type: 'observability-stack' } };
const ctx = { repoRoot: process.cwd(), targetPath: process.cwd(), scope: 'user', env: process.env, platform: 'linux' };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$(winpath "$probes_lib")")
[ "$(echo "$outE" | jq -r '.actual')" = "absent" ] \
  || fail "case e: posix not opted in must probe 'absent', got: $outE"
[ "$(echo "$outE" | jq -r '.cleanAbsence')" = "true" ] \
  || fail "case e: posix not opted in must carry cleanAbsence:true, got: $outE"
grep -q 'observability.enabled' <<< "$outE" \
  || fail "case e: the detail must name observability.enabled, got: $outE"
echo "ok: case e — posix not opted in reads a clean absence naming observability.enabled"

# ── cases g/h: status-report.js's severity mapping for observability-stack
# Runs the REAL statusReport() end to end, filtered
# to just this item, with a synthetic empty state (never touches the real
# operator's ~/.himmel state.json) so scope:'user' + profiles:[core,all]
# derives desired:true via state.js's own deriveTarget(). process.platform is
# monkeypatched inside the (isolated, disposable) child node process — this
# repo's real dev host stays untouched. ──────────
status_report_probe() {
  # status-report.js's ctxForItem() never threads a platform field into ctx, so
  # the ONLY way to force linux here is the process.platform monkeypatch. Pin
  # HIMMELCTL_BASH to the real bash so the probe's spawn resolves regardless of
  # which host this runs on.
  HIMMELCTL_BASH="$(command -v bash)" "$node_bin" -e "
Object.defineProperty(process, 'platform', { value: 'linux' });
const { statusReport } = require(process.argv[1]);
const manifest = { items: [{ id: 'observability-stack', kind: 'scheduler', scopes: ['user'], profiles: ['core','all'], deps: [], probe: { type: 'observability-stack' } }] };
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers: {}, state: { targets: {} } });
console.log(JSON.stringify(report.items.find((r) => r.id === 'observability-stack')));
" "$(winpath "$status_report_lib")"
}

# ── case g: not opted in -> n/a, remedy names the key ────────────
outG=$(status_report_probe)
[ "$(echo "$outG" | jq -r '.severity')" = "n/a" ] \
  || fail "case g: posix not opted in must read severity:n/a (never nag every adopter), got: $outG"
detailG=$(echo "$outG" | jq -r '.detail')
grep -q '"observability": {"enabled": true}' <<< "$detailG" \
  || fail "case g: the n/a remedy must show how to set observability.enabled, got: $outG"
echo "ok: case g — status-report.js: posix not opted in reads severity:n/a with the opt-in remedy"

# ── case h: degraded stays degraded — the n/a downgrade never swallows a real
# partial-install warning. This stubs probesLib.runProbe directly
# (module-cache monkeypatch: mutating the SAME exports object
# status-report.js's own internal `require('./probes.js')` resolves to) to
# exercise status-report.js's severity mapping in isolation from the probe's
# own gating — proving the n/a downgrade is scoped to probe.actual ─────────
status_report_degraded_stub() {
  # $1 = process.platform value to force
  "$node_bin" -e "
Object.defineProperty(process, 'platform', { value: process.argv[2] });
const probesLib = require(process.argv[1]);
probesLib.runProbe = () => ({ actual: 'degraded', detail: 'stub: partial install' });
const { statusReport } = require(process.argv[3]);
const manifest = { items: [{ id: 'observability-stack', kind: 'scheduler', scopes: ['user'], profiles: ['core','all'], deps: [], probe: { type: 'observability-stack' } }] };
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers: {}, state: { targets: {} } });
console.log(JSON.stringify(report.items.find((r) => r.id === 'observability-stack')));
" "$(winpath "$probes_lib")" "$1" "$(winpath "$status_report_lib")"
}
outH_posix=$(status_report_degraded_stub linux)
[ "$(echo "$outH_posix" | jq -r '.severity')" = "degraded" ] \
  || fail "case h: probe.actual:degraded must stay severity:degraded (the n/a downgrade is scoped to 'absent' only), got: $outH_posix"
echo "ok: case h — status-report.js: degraded stays severity:degraded"

# ── case j: install-engine.js's dispatch for install.type:observability
# Drives planInstall() with an injected
# ctx.platform (install-engine.js reads ctx.platform, not process.platform,
# so no global stubbing is needed) and asserts on the RETURNED descriptor
# only, never on a real spawn ──────────────────────────────────────────────
outJ=$("$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'observability-stack', deps: [], install: { type: 'observability', target: 'stack' } };
const ctx = { repoRoot: process.cwd(), scope: 'user', profile: 'core', targetPath: process.cwd(), platform: 'linux', env: process.env };
console.log(JSON.stringify(ie.planInstall([item], ctx)[0]));
" "$(winpath "$install_engine_lib")")

posixUnrunnable=$(echo "$outJ" | jq -r '.unrunnable // empty')
[ -n "$posixUnrunnable" ] \
  || fail "case j: plan entry must be unrunnable when not opted in, got: $outJ"
grep -q 'observability.*enabled' <<< "$posixUnrunnable" \
  || fail "case j: unrunnable reason must name the opt-in key, got: $posixUnrunnable"
[ "$(echo "$outJ" | jq -r '.cmd // empty')" = "" ] \
  || fail "case j: not opted in must carry NO cmd (ensure never enables a service unasked), got: $outJ"
echo "ok: case j (not opted in) — install-engine.js returns unrunnable naming the opt-in key, no cmd"

outJ2=$(HIMMEL_LUNA_CONFIG_PATH="$cfg_on" "$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'observability-stack', deps: [], install: { type: 'observability', target: 'stack' } };
const ctx = { repoRoot: process.cwd(), scope: 'user', profile: 'core', targetPath: process.cwd(), platform: 'linux', env: process.env };
console.log(JSON.stringify(ie.planInstall([item], ctx)[0]));
" "$(winpath "$install_engine_lib")")
[ "$(echo "$outJ2" | jq -r '.cmd')" = "bash" ] \
  || fail "case j: posix opted in must plan a bash cmd, got: $outJ2"
argsJ2=$(echo "$outJ2" | jq -r '.args | join(" ")')
grep -qE 'observability[/\\]install-stack\.sh install$' <<< "$argsJ2" \
  || fail "case j: posix opted in must run install-stack.sh install, got: $outJ2"
echo "ok: case j (posix, opted in) — install-engine.js plans bash install-stack.sh install"

# ── case k: opted-in posix probe against a fixture repo, systemctl/curl/
# doctor-cadence stubbed (never a real service, never the network). Also
# asserts the probe is read-only (no enable/start/restart) and bounded ───
fake="$work/fakerepo"; fbin="$work/fbin"; fcalls="$work/calls.log"
mkdir -p "$fake/scripts/observability" "$fbin"
cp "$repo_root/scripts/observability/install-stack.sh" "$fake/scripts/observability/"
printf '#!/bin/sh\necho Linux\n' > "$fbin/uname"
printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n[ -z "$OBS_SVC_DOWN" ]\n' "$fcalls" > "$fbin/systemctl"
printf '#!/bin/sh\necho "launchctl $*" >> "%s"\n[ -z "$OBS_SVC_DOWN" ]\n' "$fcalls" > "$fbin/launchctl"
printf '#!/bin/sh\nif [ -n "$OBS_HEALTH_DOWN" ]; then printf 000; else printf 200; fi\n' > "$fbin/curl"
printf '#!/bin/sh\nif [ -n "$OBS_CADENCE_DOWN" ]; then echo NOT-ARMED; else echo ARMED; fi\n' > "$fake/scripts/doctor-cadence.sh"
chmod +x "$fbin"/*
k_probe() {
  # $@ = VAR=1 overrides for the stubs
  : > "$fcalls"
  env "$@" HIMMEL_LUNA_CONFIG_PATH="$cfg_on" PATH="$fbin:$PATH" HOME="$work" "$node_bin" -e "
const { runProbe } = require(process.argv[1]);
console.log(JSON.stringify(runProbe({ probe: { type: 'observability-stack' } }, { repoRoot: process.argv[2], targetPath: process.cwd(), scope: 'user', env: process.env, platform: 'linux' })));
" "$(winpath "$probes_lib")" "$(winpath "$fake")"
}
[ "$(k_probe X=1 | jq -r '.actual')" = "present" ] || fail "case k: registered + healthy + cadence armed must probe present"
mutating_re='systemctl --user (enable|start|restart|daemon-reload|disable)|launchctl (bootstrap|enable|bootout|kickstart)'
# positive control: the matcher must hit a planted mutating call, or "no match" below proves nothing
grep -qE "$mutating_re" <<< "systemctl --user enable himmel-flow-exporter.service" \
  || fail "case k: the read-only matcher failed to match a planted mutating command"
rc_ro=0; grep -qE "$mutating_re" "$fcalls" || rc_ro=$?
[ "$rc_ro" = 1 ] || fail "case k: the probe must be read-only (grep rc=$rc_ro; 0=mutation seen, 2=grep error), saw: $(cat "$fcalls")"
[ "$(k_probe OBS_SVC_DOWN=1 OBS_HEALTH_DOWN=1 | jq -r '.actual')" = "absent" ] || fail "case k: service + health down must probe absent (not installed)"
outK=$(k_probe OBS_CADENCE_DOWN=1)
[ "$(echo "$outK" | jq -r '.actual')" = "degraded" ] || fail "case k: cadence unarmed must probe degraded, got: $outK"
grep -q 'doctor-cadence' <<< "$outK" || fail "case k: degraded detail must name doctor-cadence, got: $outK"
[ "$(k_probe OBS_HEALTH_DOWN=1 | jq -r '.actual')" = "degraded" ] || fail "case k: service up but exporter unhealthy must probe degraded"
# bounded: a hanging status script reads degraded within the probe timeout
printf '#!/bin/sh\nsleep 30\n' > "$fbin/curl"; chmod +x "$fbin/curl"
outT=$(k_probe HIMMELCTL_PROBE_TIMEOUT_SECS=1 X=1)
[ "$(echo "$outT" | jq -r '.actual')" = "degraded" ] || fail "case k: a hanging status must read degraded, got: $outT"
grep -q 'timed out' <<< "$outT" || fail "case k: the hanging-status detail must say 'timed out', got: $outT"
echo "ok: case k — opted-in posix probe: present/absent/degraded from install-stack.sh status, read-only, bounded"

# ── case l: himmel-update never converges it (DRIFT_CONVERGE_IDS allow-list) ─
convergeIds=$(grep -E '^DRIFT_CONVERGE_IDS=' "$repo_root/scripts/himmel-update.sh" || true)
[ -n "$convergeIds" ] || fail "case l: could not find DRIFT_CONVERGE_IDS in himmel-update.sh"
if grep -q 'observability-stack' <<< "$convergeIds"; then
  fail "case l: himmel-update must never auto-converge observability-stack, saw: $convergeIds"
fi
echo "ok: case l — observability-stack is not in himmel-update's DRIFT_CONVERGE_IDS"

echo "PASS"
