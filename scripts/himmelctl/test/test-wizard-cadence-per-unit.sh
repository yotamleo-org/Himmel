#!/usr/bin/env bash
# test-wizard-cadence-per-unit.sh — hermetic tests for (per-
# cadence wizard selection). Covers the NEW behavior that sits on top of
# test-wizard-luna-sections.sh's existing pipeline-only cadence coverage
# (which continues to prove the legacy `luna.cadenceEnabled` fallback, byte-
# stable round-trips, and disarm-consent wiring — none of that is repeated
# here):
#
#   a. a top-level `cadences` section (no `luna` section at all — the
#      operator-capture shape, docs/setup/profiles/operator.install-
#      profile.json) arms qmd/graphmap via their OWN scripts with the
#      documented minimal argv, and does NOT spawn pipeline-cadence.sh when
#      pipeline is declined.
#   b. `cadences` is AUTHORITATIVE over the legacy `luna.cadenceEnabled`
#      boolean when both are present on the same profile: cadenceEnabled=true
#      + cadences.pipeline='off' must NOT arm pipeline.
#   e. the cadences question is PER-ROW gated, not whole-question vault
#      gated — offeredCadenceRows() filters each row by its own `requires`,
#      so vault=none still asks it, offering only the requires:'none' rows;
#      declining them records every offered row off, with the vault- and
#      env-requiring rows genuinely absent.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
luna_config_lib="$repo_root/scripts/himmelctl/lib/luna-config.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-cadence-per-unit.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# run from a THROWAWAY directory, never the himmel checkout this
# suite lives in. `install` resolves a project-scope target to $PWD, so a case
# answering scope=project from the checkout root aimed the installer at the
# repo itself -- which bin.js's himmel-clone guard now refuses outright. The cd
# also closes the older hermeticity hole that same fact created: a non-dry-run
# project install here spawned adopt.sh against the live checkout.
cadence_cwd="$work/suite-cwd"; mkdir -p "$cadence_cwd"; cd "$cadence_cwd"
luna_config_lib_w="$(winpath "$luna_config_lib")"

build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

make_git_stub() {
  local _d="$1" _url="$2"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' "$_url"
  exit 0
fi
exit 0
STUB
  chmod +x "$_d/git"
}

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# ═══════════════════════════════════════════════════════════════════════════
# case a: a `cadences`-only profile (no `luna` section) arms qmd + graphmap
# via their own scripts, and does NOT spawn pipeline-cadence.sh (declined).
# ═══════════════════════════════════════════════════════════════════════════

stubA="$work/stubA"; mkdir -p "$stubA"
pathA=$(build_path "$stubA" bash jq python3 npm --)
make_git_stub "$stubA" "https://github.com/someone/other-repo.git"
homeA="$work/homeA"; mkdir -p "$homeA"

fixtureRepoA="$work/fixture-repo-a"; mkdir -p "$fixtureRepoA/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoA/scripts/adopt.sh"
chmod +x "$fixtureRepoA/scripts/adopt.sh"

markerPipelineA="$work/marker-pipeline-a.txt"
markerQmdA="$work/marker-qmd-a.txt"
markerGraphmapA="$work/marker-graphmap-a.txt"
cat > "$fixtureRepoA/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_PIPELINE_A"
exit 0
STUB
cat > "$fixtureRepoA/scripts/luna/qmd-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_QMD_A"
exit 0
STUB
cat > "$fixtureRepoA/scripts/luna/graphmap-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_GRAPHMAP_A"
exit 0
STUB
chmod +x "$fixtureRepoA/scripts/luna/pipeline-cadence.sh" "$fixtureRepoA/scripts/luna/qmd-cadence.sh" "$fixtureRepoA/scripts/luna/graphmap-cadence.sh"

vaultPathA="$(winpath "$work/vaultA")"
configPathA="$(winpath "$work/config-a.json")"

profileA="$work/profileA.json"
cat > "$profileA" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathA" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": true,
  "cadences": { "pipeline": "off", "qmd": "armed", "graphmap": "armed" }
}
JSON

set +e
outA=$(PATH="$pathA" HOME="$homeA" USERPROFILE="$(winpath "$homeA")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoA")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathA" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-a")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-a")" \
  MARKER_PIPELINE_A="$(winpath "$markerPipelineA")" \
  MARKER_QMD_A="$(winpath "$markerQmdA")" \
  MARKER_GRAPHMAP_A="$(winpath "$markerGraphmapA")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileA")" </dev/null 2>&1)
rcA=$?
set -e
[ "$rcA" -eq 0 ] || fail "case a: a cadences-only (no luna section) apply run should exit 0 (got rc=$rcA): $outA"

[ -f "$markerQmdA" ] || fail "case a: qmd-cadence.sh should have been spawned with 'arm' (marker missing)"
grepq "$(cat "$markerQmdA")" -F -- 'arm' || fail "case a: qmd spawn should carry the 'arm' subcommand (got: $(cat "$markerQmdA"))"

[ -f "$markerGraphmapA" ] || fail "case a: graphmap-cadence.sh should have been spawned with 'arm' (marker missing)"
graphmapArgvA=$(cat "$markerGraphmapA")
grepq "$graphmapArgvA" -F -- 'arm' || fail "case a: graphmap spawn should carry the 'arm' subcommand (got: $graphmapArgvA)"
grepq "$graphmapArgvA" -F -- '--vault' || fail "case a: graphmap arm argv missing --vault (got: $graphmapArgvA)"
grepq "$graphmapArgvA" -F -- "$vaultPathA" || fail "case a: graphmap arm argv should carry the configured vault path (got: $graphmapArgvA)"

[ -f "$markerPipelineA" ] && fail "case a: pipeline-cadence.sh must NEVER be spawned when pipeline was declined (found marker: $(cat "$markerPipelineA"))"

outCfgA=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathA';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outCfgA" | jq -e '.luna.cadence.enabled == false' >/dev/null \
  || fail "case a: luna.cadence.enabled should mirror the declined pipeline row (false), even with no luna section supplied (got: $outCfgA)"

set +e
installedBlockA=$(grep -A5 '^installed:$' <<< "$outA")
set -e
grepq "$installedBlockA" -F -- 'qmd reindex cadence armed' \
  || fail "case a: the summary should report qmd reindex cadence armed under installed: (got: $outA)"
grepq "$installedBlockA" -F -- 'graphify graph refresh cadence armed' \
  || fail "case a: the summary should report graphify graph refresh cadence armed under installed: (got: $outA)"
echo "ok: case a — a cadences-only profile (no luna section) arms qmd + graphmap via their own scripts with the documented minimal argv, and never spawns pipeline-cadence.sh when pipeline is declined"

# ═══════════════════════════════════════════════════════════════════════════
# case b: `cadences` is AUTHORITATIVE over the legacy luna.cadenceEnabled
# boolean when both are present — cadenceEnabled=true + cadences.pipeline=
# 'off' must NOT arm pipeline.
# ═══════════════════════════════════════════════════════════════════════════

stubB="$work/stubB"; mkdir -p "$stubB"
pathB=$(build_path "$stubB" bash jq python3 npm --)
make_git_stub "$stubB" "https://github.com/someone/other-repo.git"
homeB="$work/homeB"; mkdir -p "$homeB"

fixtureRepoB="$work/fixture-repo-b"; mkdir -p "$fixtureRepoB/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoB/scripts/adopt.sh"
chmod +x "$fixtureRepoB/scripts/adopt.sh"
markerPipelineB="$work/marker-pipeline-b.txt"
cat > "$fixtureRepoB/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_PIPELINE_B"
exit 0
STUB
chmod +x "$fixtureRepoB/scripts/luna/pipeline-cadence.sh"

vaultPathB="$(winpath "$work/vaultB")"
configPathB="$(winpath "$work/config-b.json")"

profileB="$work/profileB.json"
cat > "$profileB" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathB" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": { "enabled": false, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": false },
  "cadences": { "pipeline": "off" }
}
JSON

set +e
outB=$(PATH="$pathB" HOME="$homeB" USERPROFILE="$(winpath "$homeB")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoB")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathB" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-b")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-b")" \
  MARKER_PIPELINE_B="$(winpath "$markerPipelineB")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileB")" </dev/null 2>&1)
rcB=$?
set -e
[ "$rcB" -eq 0 ] || fail "case b: run should exit 0 (got rc=$rcB): $outB"
[ -f "$markerPipelineB" ] && fail "case b: cadences.pipeline='off' must override luna.cadenceEnabled=true -- pipeline-cadence.sh must NOT be spawned (found marker: $(cat "$markerPipelineB")))"
outCfgB=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathB';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outCfgB" | jq -e '.luna.cadence.enabled == false' >/dev/null \
  || fail "case b: luna.cadence.enabled should reflect the AUTHORITATIVE cadences.pipeline='off', not the legacy cadenceEnabled=true (got: $outCfgB)"
echo "ok: case b — a top-level cadences section is authoritative over the legacy luna.cadenceEnabled boolean"

# ═══════════════════════════════════════════════════════════════════════════
# case e (interactive, installer v1 spec-deviation fix): vault=none -> the
# vault-gated rows (pipeline/qmd/graphmap) still don't qualify, but the
# `requires:'none'` rows (drift-fix/upstream-watch/doctor) qualify
# UNCONDITIONALLY -- so the cadences question IS asked, offering exactly
# those (pull-cadence still absent: its
# requires:'env:GOOGLE_HEALTH_REFRESH_TOKEN' is unset in this hermetic HOME).
# Declining them all (Enter -> the starter preset's empty cadenceIds
# default) records every offered row 'off', never a fabricated {} for an
# UNoffered row.
# ═══════════════════════════════════════════════════════════════════════════

stubE="$work/stubE"; mkdir -p "$stubE"
pathE=$(build_path "$stubE" bash jq python3 npm --)
homeE="$work/homeE"; mkdir -p "$homeE"

set +e
outE=$(PATH="$pathE" HOME="$homeE" USERPROFILE="$(winpath "$homeE")" HIMMELCTL_CACHE_DIR="$(winpath "$homeE.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeE.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
custom
project
none
inline

no

no
INPUT
); rcE=$?
set -e
[ "$rcE" -eq 0 ] || fail "case e: vault=none run should succeed (got rc=$rcE): $outE"
grepq "$outE" -F -- '? cadences — recurring scheduled jobs to arm now [drift-fix,upstream-watch,doctor|none] (default: none)' \
  || fail "case e: vault=none should still ask cadences, offering ONLY the requires:'none' rows (got: $outE)"
grepq "$outE" -F -- '"drift-fix": "off"' \
  || fail "case e: declining drift-fix (Enter, no recommended default) should record off (got: $outE)"
grepq "$outE" -F -- '"upstream-watch": "off"' \
  || fail "case e: declining upstream-watch should record off (got: $outE)"
grepq "$outE" -F -- '"pipeline":' \
  && fail "case e: pipeline must stay genuinely absent from cadences (requires vault, vault=none) (got: $outE)"
grepq "$outE" -F -- '"pull-cadence":' \
  && fail "case e: pull-cadence must stay genuinely absent from cadences (requires env:GOOGLE_HEALTH_REFRESH_TOKEN, unset here) (got: $outE)"
echo "ok: case e — vault=none still asks cadences (the requires:'none' rows always qualify); declining them all records every offered row off, with the vault-/env-gated rows genuinely absent"

# ═══════════════════════════════════════════════════════════════════════════
# case f: a saved profile still naming the retired codex-sweep / repo-sync
# rows loads; those ids are dropped with a notice, the rest still validate.
# ═══════════════════════════════════════════════════════════════════════════

homeF="$work/homeF"; mkdir -p "$homeF"
profileF="$work/profileF.json"
cat > "$profileF" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": true,
  "cadences": { "doctor": "off", "codex-sweep": "armed", "repo-sync": "off" }
}
JSON

set +e
outF=$(HOME="$homeF" USERPROFILE="$(winpath "$homeF")" HIMMELCTL_INTERACTIVE=0 \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-f.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-f")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-f")" \
  "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profileF")" </dev/null 2>&1)
rcF=$?
set -e
grepq "$outF" -F -- 'unknown cadence id' \
  && fail "case f: a retired cadence id must not be rejected as unknown (got rc=$rcF: $outF)"
[ "$rcF" -eq 0 ] || fail "case f: a profile naming retired cadences should load (got rc=$rcF): $outF"
grepq "$outF" -F -- "dropping retired cadence 'codex-sweep'" \
  || fail "case f: dropping codex-sweep should be announced (got: $outF)"
grepq "$outF" -F -- "dropping retired cadence 'repo-sync'" \
  || fail "case f: dropping repo-sync should be announced (got: $outF)"
grepq "$outF" -F -- 'codex-sweep cadence arm' \
  && fail "case f: a dropped cadence must never be armed (got: $outF)"
echo "ok: case f — a profile naming the retired codex-sweep / repo-sync rows loads, with each drop announced"

# ═══════════════════════════════════════════════════════════════════════════
# case g: a `cadences` section naming ONLY retired ids is dropped whole, so
# the legacy luna.cadenceEnabled=true answer still arms pipeline.
# ═══════════════════════════════════════════════════════════════════════════

homeG="$work/homeG"; mkdir -p "$homeG"
profileG="$work/profileG.json"
cat > "$profileG" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$(winpath "$work/vaultG")" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": true,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "cadences": { "codex-sweep": "armed" }
}
JSON

set +e
outG=$(HOME="$homeG" USERPROFILE="$(winpath "$homeG")" HIMMELCTL_INTERACTIVE=0 \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-g.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-g")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-g")" \
  "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profileG")" </dev/null 2>&1)
rcG=$?
set -e
[ "$rcG" -eq 0 ] || fail "case g: a profile naming only retired cadences should load (got rc=$rcG): $outG"
grepq "$outG" -F -- 'luna cadence — would arm via pipeline-cadence.sh' \
  || fail "case g: with only retired ids dropped, luna.cadenceEnabled=true should still arm pipeline (got: $outG)"
echo "ok: case g — a cadences section of only retired ids is dropped, so the legacy cadenceEnabled answer applies"

# ═══════════════════════════════════════════════════════════════════════════
# case h: the first run that drops a retired cadence rewrites the profile
# file without it, so the second run is quiet.
# ═══════════════════════════════════════════════════════════════════════════

homeH="$work/homeH"; mkdir -p "$homeH"
profileH="$work/profileH.json"
cat > "$profileH" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": true,
  "cadences": { "doctor": "off", "codex-sweep": "armed" }
}
JSON
cacheH="$work/cache-h"; mkdir -p "$cacheH"
cp "$profileH" "$cacheH/install-profile.json"
run_h() {
  ( cd "$homeH" && HOME="$homeH" USERPROFILE="$(winpath "$homeH")" HIMMELCTL_INTERACTIVE=0 \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-h.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$cacheH")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-h")" \
    "$node_bin" "$wizard" "$@" </dev/null 2>&1 )
}
saved="$cacheH/install-profile.json"
# a dry-run preview announces the drop but leaves the file alone
set +e
outH0=$(run_h install --dry-run --from-profile "$(winpath "$profileH")"); rcH0=$?
set -e
[ "$rcH0" -eq 0 ] || fail "case h: the dry-run preview should load (rc=$rcH0): $outH0"
grepq "$outH0" -F -- "dropping retired cadence 'codex-sweep'" \
  || fail "case h: the dry-run preview should announce the drop (got: $outH0)"
grepq "$(cat "$profileH")" -F -- 'codex-sweep' \
  || fail "case h: a dry-run preview must not rewrite the profile (got: $(cat "$profileH"))"
# read-only verbs and an ensure dry run read the saved profile and never rewrite it
set +e
outHs=$(run_h status --json); rcHs=$?
outHd=$(run_h ensure --dry-run --no-network --items wiring-pretooluse); rcHd=$?
set -e
[ "$rcHs" -eq 0 ] || fail "case h: status should load (rc=$rcHs): $outHs"
[ "$rcHd" -eq 0 ] || fail "case h: ensure --dry-run should load (rc=$rcHd): $outHd"
cmp -s "$profileH" "$saved" \
  || fail "case h: status and ensure --dry-run must leave the saved profile byte-identical (got: $(cat "$saved"))"
# a symlinked saved profile is never replaced by a regular file
realH="$work/profileH-real.json"
mv "$saved" "$realH"; ln -s "$realH" "$saved"
set +e
outHl=$(run_h ensure --no-network --items wiring-pretooluse); rcHl=$?
set -e
[ -L "$saved" ] || fail "case h: a symlinked saved profile must stay a symlink (rc=$rcHl): $outHl"
cmp -s "$profileH" "$realH" \
  || fail "case h: a symlinked saved profile must not be rewritten (got: $(cat "$realH"))"
grepq "$outHl" -F -- 'is a symlink' \
  || fail "case h: the symlink refusal should be said (got: $outHl)"
rm "$saved"; cp "$profileH" "$saved"; chmod 644 "$saved"
# a real ensure drops the retired cadence from the saved profile: the first run announces, the second is quiet
set +e
outH1=$(umask 077; run_h ensure --no-network --items wiring-pretooluse); rcH1=$?
outH2=$(run_h ensure --no-network --items wiring-pretooluse); rcH2=$?
set -e
[ "$rcH1" -eq 0 ] && [ "$rcH2" -eq 0 ] || fail "case h: both ensure runs should load (rc=$rcH1/$rcH2): $outH1 / $outH2"
grepq "$outH1" -F -- "dropping retired cadence 'codex-sweep'" \
  || fail "case h: the first run should announce the drop (got: $outH1)"
grepq "$outH2" -F -- "dropping retired cadence" \
  && fail "case h: the second run must be silent about the retired cadence (got: $outH2)"
grepq "$(cat "$saved")" -F -- 'codex-sweep' \
  && fail "case h: the saved profile must no longer name codex-sweep (got: $(cat "$saved"))"
jq -e '.cadences.doctor == "off"' "$saved" >/dev/null \
  || fail "case h: the kept cadence rows must survive the rewrite under .cadences (got: $(cat "$saved"))"
[ -n "$(find "$saved" -perm 644)" ] \
  || fail "case h: the rewrite must keep the profile's 0644 mode under umask 077 (got: $(ls -l "$saved"))"
echo "ok: case h — a retired cadence is announced once and leaves the saved profile on a real ensure; status, a dry run and a symlinked profile are left alone"

echo "PASS"
