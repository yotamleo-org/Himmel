#!/usr/bin/env bash
# test-wizard-guardrail-consent.sh: himmel no longer offers a machine-wide
# guardrail install. The `guardrail-block-global` manifest item,
# its wire target and its ask-first consent gate are gone; a station whose
# recorded state.json still names that item (it carries overrides.consent)
# must keep working: status and ensure read it as absent, and one migration
# note says the record was dropped.
#
# Hermetic: HIMMELCTL_CACHE_DIR points install-profile.json/state.json at a
# throwaway dir; CLAUDE_USER_SETTINGS points at a throwaway settings file the
# suite asserts is never created. No guardrail-block.mjs verb is run.
#
# Covers:
#   a. the manifest carries no guardrail-block-global item and the install
#      engine's closed wire-target list does not name it.
#   b. status --json on a recorded state naming the retired item exits 0 and
#      reports no such row.
#   c. ensure --dry-run on that state exits 0, prints the migration note
#      exactly once, never writes the settings file, and leaves state.json
#      byte-identical.
#   d. state.dropRetiredItems() removes the retired item from every target,
#      keeps every other item and its overrides, reports what it dropped, and
#      is a no-op the second time.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-guardrail-retired.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

cache="$work/cache"; mkdir -p "$cache"
cat > "$cache/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
jq -n '{schemaVersion:1,harness:"claude",targets:{user:{profile:"core",scope:"user",items:{"guardrail-block-global":{enabled:true,overrides:{consent:"yes"}},"wiring-statusline":{enabled:true,overrides:{keep:"me"}}},lastEnsured:null}}}' > "$cache/state.json"
settings="$work/settings.json"
before=$(cat "$cache/state.json")

run_ctl() {
  CLAUDE_USER_SETTINGS="$(winpath "$settings")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache")-luna-config.json" HIMMELCTL_INTERACTIVE=0 \
    "$node_bin" "$wizard" "$@" </dev/null 2>&1
}

# ── case a: the item and its wire target are gone ─
if jq -e '.items[] | select(.id == "guardrail-block-global")' "$repo_root/scripts/install/manifest.json" >/dev/null; then
  fail "case a: manifest.json still carries the guardrail-block-global item"
fi
if grep -q 'guardrail-block-global' "$repo_root/scripts/himmelctl/lib/install-engine.js"; then
  fail "case a: install-engine.js still names guardrail-block-global"
fi
echo "ok: case a — manifest and install engine no longer offer guardrail-block-global"

# ── case b: status reads a recorded retired item as absent ─
out=$(run_ctl status --json) || fail "case b: status --json must exit 0 on a state naming the retired item: $out"
if printf '%s' "$out" | grep -q 'guardrail-block-global'; then
  fail "case b: status --json still reports guardrail-block-global: $out"
fi
echo "ok: case b — status --json exits 0 and reports no guardrail-block-global row"

# ── case c: ensure --dry-run migrates quietly, once, with no writes ─
out=$(run_ctl ensure --items wiring-statusline --dry-run) || fail "case c: ensure --dry-run must exit 0: $out"
notes=$(printf '%s\n' "$out" | grep -c 'retired item guardrail-block-global' || true)
[ "$notes" -eq 1 ] || fail "case c: expected exactly one migration note, got $notes: $out"
[ ! -e "$settings" ] || fail "case c: ensure --dry-run must never write the settings file"
[ "$(cat "$cache/state.json")" = "$before" ] || fail "case c: ensure --dry-run must leave state.json byte-identical"
echo "ok: case c — ensure --dry-run prints one migration note, writes nothing"

# ── case d: dropRetiredItems prunes only the retired id, idempotently ─
res=$(HIMMELCTL_CACHE_DIR="$(winpath "$cache")" "$node_bin" -e '
const s = require(process.argv[1]);
const st = s.load();
const first = s.dropRetiredItems(st);
const second = s.dropRetiredItems(st);
process.stdout.write(JSON.stringify({ first, second, items: st.targets.user.items }));
' "$repo_root/scripts/himmelctl/lib/state.js") || fail "case d: dropRetiredItems threw: $res"
[ "$(printf '%s' "$res" | jq -c '.first')" = '["guardrail-block-global"]' ] || fail "case d: first call should report the dropped id: $res"
[ "$(printf '%s' "$res" | jq -c '.second')" = '[]' ] || fail "case d: second call must be a no-op: $res"
[ "$(printf '%s' "$res" | jq -c '.items | keys')" = '["wiring-statusline"]' ] || fail "case d: only the retired item may be dropped: $res"
[ "$(printf '%s' "$res" | jq -r '.items["wiring-statusline"].overrides.keep')" = me ] || fail "case d: other items' overrides must survive: $res"
echo "ok: case d — dropRetiredItems prunes only the retired id, idempotently"

echo "PASS: test-wizard-guardrail-consent.sh"
