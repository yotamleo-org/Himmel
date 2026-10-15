#!/usr/bin/env bash
# test-wizard-handover-register.sh — the install wizard registers /
# initializes the handover state through scripts/handover/register-state.sh
# (the single writer of registry.json) when handover.mode=external AND the
# recorded answer handover.register=yes. Ask-first: no recorded answer, or
# 'no', never creates a registry entry.
#
# Covers:
#   A. external + register=yes, empty registry -> entry written for the repo
#      path, <state>/<user>/ bootstrapped (counter.md), one summary line.
#   B. external + no register answer -> no registry file, no state dir.
#   C. external + register=no -> same as B.
#   D. register=yes with an existing entry -> idempotent, no duplicate.
#   E. --dry-run previews the registration and writes nothing.
#   F. profile validation rejects handover.register outside yes|no.
# (The interactive register question is not exercised here.)
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)
repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
# shellcheck source=../../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
derive_cwd="$work/suite-cwd"; mkdir -p "$derive_cwd"; cd "$derive_cwd"
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_fixture <dir> — a git repo standing in for HIMMELCTL_REPO_ROOT with
# no-op adopt/setup stubs and REAL copies of the handover scripts under test.
build_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/handover" "$_d/scripts/lib" "$_d/scripts/machine-setup"
  git init -q "$_d"
  cp "$repo_root/scripts/machine-setup/full-plugin-enable.json" "$_d/scripts/machine-setup/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/adopt.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/setup.sh"
  printf 'exit 0\n' > "$_d/scripts/setup.ps1"
  cp "$repo_root/scripts/handover/set-handover-dir.sh" "$_d/scripts/handover/"
  cp "$repo_root/scripts/handover/register-state.sh" "$_d/scripts/handover/" 2>/dev/null || true
  cp "$repo_root/scripts/lib/git-clean.sh" "$_d/scripts/lib/"
  mkdir -p "$_d/marketplace/plugins/handover"
  cp -R "$repo_root/marketplace/plugins/handover/templates" "$_d/marketplace/plugins/handover/"
  chmod +x "$_d"/scripts/*.sh "$_d"/scripts/handover/*.sh
}

# write_profile <path> <state-dir> [<register-json-fragment>]
write_profile() {
  printf '{"schemaVersion":2,"profile":"starter","devOverlay":false,"scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"external","path":"%s"%s},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}\n' "$2" "${3:-}" > "$1"
}

# run_wizard <case> <profile> [extra wizard args...] — sets $out, $rc; the
# fixture is $work/<case>-fx, the registry $work/<case>-reg.json.
run_wizard() {
  local _c="$1" _p="$2"; shift 2
  local _h="$work/$_c-home"; mkdir -p "$_h"
  local _stub="$work/$_c-stub"; mkdir -p "$_stub"
  local _path
  _path=$(build_hermetic_path "$_stub" bash git jq python3 npm node)
  set +e
  out=$(PATH="$_path" HOME="$_h" USERPROFILE="$(winpath "$_h")" HIMMELCTL_CACHE_DIR="$(winpath "$_h.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_h.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$work/$_c-fx")" HANDOVER_REGISTRY="$(winpath "$work/$_c-reg.json")" USER_SLUG=tester \
        "$node_bin" "$wizard" install --from-profile "$(winpath "$_p")" "$@" </dev/null 2>&1); rc=$?
  set -e
}
type build_hermetic_path >/dev/null 2>&1 || build_hermetic_path() {
  local _stub="$1"; shift; local _t
  for _t in "$@"; do link_hermetic_tool "$_t" "$_stub" 2>/dev/null || true; done
  printf '%s:%s' "$_stub" "$PATH"
}

# ── A: register=yes -> registry entry + bootstrapped state ─────────────────
build_fixture "$work/A-fx"; mkdir -p "$work/A-state"
write_profile "$work/A.json" "$(winpath "$work/A-state")" ',"register":"yes"'
run_wizard A "$work/A.json"
[ "$rc" -eq 0 ] || fail "A: rc=$rc: $out"
[ -f "$work/A-reg.json" ] || fail "A: registry.json not written (out: $out)"
node_check=$("$node_bin" -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const e=Object.values(j.repos)[0];
  process.stdout.write(e && e.user==="tester" && /A-fx$/.test(e.path) ? "ok" : "bad:"+JSON.stringify(j));' "$work/A-reg.json")
[ "$node_check" = "ok" ] || fail "A: registry entry wrong: $node_check"
[ -f "$work/A-state/tester/counter.md" ] || fail "A: state dir not bootstrapped"
grepq "$out" -E 'handover state registered' || fail "A: expected the one registration summary line (out: $out)"
echo "ok: A register=yes registers through register-state.sh and bootstraps state"

# ── B: no recorded answer -> never creates anything ────────────────────────
build_fixture "$work/B-fx"; mkdir -p "$work/B-state"
write_profile "$work/B.json" "$(winpath "$work/B-state")"
run_wizard B "$work/B.json"
[ "$rc" -eq 0 ] || fail "B: rc=$rc: $out"
[ ! -e "$work/B-reg.json" ] || fail "B: registry created without a recorded answer"
[ ! -e "$work/B-state/tester" ] || fail "B: state dir created without a recorded answer"
echo "ok: B no recorded answer -> no registry entry, no state dir"

# ── C: register=no ─────────────────────────────────────────────────────────
build_fixture "$work/C-fx"; mkdir -p "$work/C-state"
write_profile "$work/C.json" "$(winpath "$work/C-state")" ',"register":"no"'
run_wizard C "$work/C.json"
[ "$rc" -eq 0 ] || fail "C: rc=$rc: $out"
[ ! -e "$work/C-reg.json" ] || fail "C: registry created for register=no"
echo "ok: C register=no -> nothing created"

# ── D: idempotent re-run ───────────────────────────────────────────────────
run_wizard A "$work/A.json"
[ "$rc" -eq 0 ] || fail "D: rerun rc=$rc: $out"
n=$("$node_bin" -e 'process.stdout.write(String(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).repos).length))' "$work/A-reg.json")
[ "$n" = "1" ] || fail "D: expected 1 registry entry after re-run, got $n"
echo "ok: D re-run is idempotent"

# ── E: --dry-run previews, writes nothing ──────────────────────────────────
build_fixture "$work/E-fx"; mkdir -p "$work/E-state"
write_profile "$work/E.json" "$(winpath "$work/E-state")" ',"register":"yes"'
run_wizard E "$work/E.json" --dry-run
[ "$rc" -eq 0 ] || fail "E: rc=$rc: $out"
grepq "$out" -E 'DRY: .*register' || fail "E: expected a DRY register line (out: $out)"
[ ! -e "$work/E-reg.json" ] || fail "E: dry-run wrote the registry"
echo "ok: E --dry-run previews and writes nothing"

# ── F: validation ──────────────────────────────────────────────────────────
build_fixture "$work/F-fx"; mkdir -p "$work/F-state"
write_profile "$work/F.json" "$(winpath "$work/F-state")" ',"register":"maybe"'
run_wizard F "$work/F.json"
[ "$rc" -ne 0 ] || fail "F: register=maybe must be rejected"
grepq "$out" -F 'handover.register' || fail "F: error should name handover.register (out: $out)"
echo "ok: F invalid handover.register rejected"

echo "PASS"
