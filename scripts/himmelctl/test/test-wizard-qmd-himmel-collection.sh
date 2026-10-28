#!/usr/bin/env bash
# test-wizard-qmd-himmel-collection.sh — hermetic tests for the
# `qmd-himmel-collection` install item: a core-profile install
# with qmd on the machine registers the himmel qmd collection, as adopt.sh's
# wire_qmd_core already does. Drives the REAL manifest + REAL qmd-bin.sh
# against a STUB `qmd` on PATH (a state file standing in for the index) under
# a fake HOME, so nothing is ever registered on the station.
#
# Covers:
#   a. RED row: core profile + stub qmd -> `ensure --items qmd-himmel-collection`
#      exits 0 and himmel is in the registered collections.
#   b. negative control: the same fixture WITHOUT qmd -> exit 0, nothing
#      registered, status reads n/a with a hint (never red).
#   c. luna/all: qmd-index still requires himmel+luna+skills, and the new item
#      never registers himmel a second time once it is registered.
#   d. manifest-lint passes.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
manifest_path="$repo_root/scripts/install/manifest.json"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)
fail() { echo "FAIL: $*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/qmd-himmel-collection-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/target" "$work/cache"

# Stub qmd: QMD_STATE is the registered-collections list (one name per line).
stubBin="$work/stub-bin"; mkdir -p "$stubBin"
cat > "$stubBin/qmd" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "collection" ] || exit 0
case "$2" in
  list) [ -f "$QMD_STATE" ] && cat "$QMD_STATE"; exit "${QMD_LIST_RC:-0}" ;;
  add) name=""; while [ $# -gt 0 ]; do [ "$1" = "--name" ] && name="$2"; shift; done
       echo "$name" >> "$QMD_STATE"; echo "add $name" >> "$QMD_STATE.adds"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$stubBin/qmd"
link_hermetic_tool bash "$stubBin"
link_hermetic_tool jq "$stubBin"
link_hermetic_tool timeout "$stubBin" 2>/dev/null || true
withQmdPath="$stubBin:$(scrub_path "$PATH" qmd)"
noQmdDir="$work/no-qmd-bin"; mkdir -p "$noQmdDir"
link_hermetic_tool bash "$noQmdDir"
link_hermetic_tool jq "$noQmdDir"
link_hermetic_tool timeout "$noQmdDir" 2>/dev/null || true
noQmdPath="$noQmdDir:$(scrub_path "$PATH" qmd)"

cat > "$work/cache/install-profile.json" <<JSON
{"role":"adopter","tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON

run_wizard() { # <PATH> <qmd-state> <args...>
  local p="$1" st="$2"; shift 2
  ( cd "$work/target" && PATH="$p" QMD_STATE="$(winpath "$st")" HIMMELCTL_REPO_ROOT="$(winpath "$repo_root")" HIMMELCTL_CACHE_DIR="$(winpath "$work/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/cache")-luna-config.json" HOME="$work/home" USERPROFILE="$(winpath "$work/home")" BUN_INSTALL="$work/home/.bun" \
      "$node_bin" "$wizard" "$@" </dev/null 2>&1 )
}

# ── a. core + stub qmd: himmel gets registered ─────────────────────────────
stateA="$work/qmd-state-a"; : > "$stateA"
outA=$(run_wizard "$withQmdPath" "$stateA" ensure --items qmd-himmel-collection --yes); rcA=$?
[ "$rcA" -eq 0 ] || fail "a: core + qmd ensure should exit 0 (rc=$rcA): $outA"
grep -qxF himmel "$stateA" || fail "a: himmel not in the registered collections (state: $(cat "$stateA"); out: $outA)"
st=$(run_wizard "$withQmdPath" "$stateA" status --json --items qmd-himmel-collection) || fail "a: status failed: $st"
echo "$st" | jq -e '.items[] | select(.id=="qmd-himmel-collection") | .severity == "green"' >/dev/null || fail "a: post-ensure status not green: $st"
echo "ok: a — core + qmd registers the himmel collection"

# ── b. core, no qmd: nothing registered, exit 0, a hint (not red) ──────────
stateB="$work/qmd-state-b"; : > "$stateB"
outB=$(run_wizard "$noQmdPath" "$stateB" ensure --items qmd-himmel-collection --yes); rcB=$?
[ "$rcB" -eq 0 ] || fail "b: core without qmd must exit 0 (rc=$rcB): $outB"
[ ! -s "$stateB" ] || fail "b: nothing may be registered without qmd (state: $(cat "$stateB"))"
st=$(run_wizard "$noQmdPath" "$stateB" status --json --items qmd-himmel-collection) || fail "b: status failed: $st"
echo "$st" | jq -e '.items[] | select(.id=="qmd-himmel-collection") | .severity == "n/a" and (.detail | test("qmd is not installed"))' >/dev/null || fail "b: without qmd the item must read n/a with the install hint, not red: $st"
echo "ok: b — core without qmd registers nothing, exits 0, reports a hint"

# ── c. luna/all keep the three-collection requirement; no double register ──
jq -e '(.items[] | select(.id=="qmd-index")) | (.probe.collections == ["himmel","luna","skills"]) and (.profiles == ["luna","all"])' "$manifest_path" >/dev/null \
  || fail "c: qmd-index must still require himmel, luna and skills on luna/all"
jq -e '(.items[] | select(.id=="qmd-himmel-collection")) | (.profiles == ["core","luna","all"]) and (.probe.collections == ["himmel"])' "$manifest_path" >/dev/null \
  || fail "c: qmd-himmel-collection must cover core, luna, all and probe only himmel"
stateC="$work/qmd-state-c"; printf 'himmel\nluna\nskills\n' > "$stateC"; : > "$stateC.adds"
cmdline=$("$node_bin" -e "
const eng = require('$(winpath "$repo_root/scripts/himmelctl/lib/install-engine.js")');
const m = JSON.parse(require('fs').readFileSync('$(winpath "$manifest_path")', 'utf8'));
const item = m.items.find((i) => i.id === 'qmd-himmel-collection');
const [e] = eng.planInstall([item], { repoRoot: '$(winpath "$repo_root")', scope: 'project', profile: 'luna', targetPath: '$(winpath "$work/target")', env: process.env, vaultPath: '$(winpath "$work")' });
console.log(JSON.stringify([e.cmd, ...e.args]));
")
[ -n "$cmdline" ] || fail "c: planInstall produced no command"
argv=(); while IFS= read -r a; do argv+=("$a"); done < <(echo "$cmdline" | jq -r '.[]')
( PATH="$withQmdPath" QMD_STATE="$stateC" HOME="$work/home" BUN_INSTALL="$work/home/.bun" "${argv[@]}" >/dev/null 2>&1 ) || fail "c: the register-only command failed against an already-registered himmel"
[ ! -s "$stateC.adds" ] || fail "c: himmel was registered a second time (adds: $(cat "$stateC.adds"))"
echo "ok: c — luna/all keep qmd-index's three collections; an already-registered himmel is not added again"

# ── e. an installed qmd whose `collection list` exits 3 is a failure, not "no qmd" ──
stateE="$work/qmd-state-e"; : > "$stateE"
st=$(QMD_LIST_RC=3 run_wizard "$withQmdPath" "$stateE" status --json --items qmd-himmel-collection) || fail "e: status failed: $st"
echo "$st" | jq -e '.items[] | select(.id=="qmd-himmel-collection") | .severity != "n/a"' >/dev/null || fail "e: a failing collection list on an installed qmd must not read as the no-qmd hint: $st"
echo "ok: e — a failing collection list on an installed qmd is not reported as qmd absent"

# ── d. manifest-lint ───────────────────────────────────────────────────────
node "$repo_root/scripts/install/manifest-lint.mjs" "$manifest_path" >/dev/null || fail "d: manifest-lint rejects the manifest"
echo "ok: d — manifest-lint passes"
echo "PASS test-wizard-qmd-himmel-collection.sh"
