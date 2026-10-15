#!/usr/bin/env bash
# test-report-deep.sh — `himmelctl report --json --deep` adds the wiring layers
# (pre-commit ids, Claude hooks, git hooks, CI workflows) to the config feed
# (spec A15). declared + installed are derived from config files;
# fires is `unverified` (A9: no component run evidence exists for these).
#
# Hermetic: fixture HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT, doctor and
# cadence scripts stubbed through the report test seams.
#
# Covers:
#   a. without --deep no wiring row appears
#   b. --deep: one row per pre-commit id / Claude hook script / git hook type /
#      CI workflow, every §4 field present
#   c. installed is derived: a hook script that exists is present, a missing
#      one is absent (health fail); a git hook file that exists is present
#   d. fires is unverified on every wiring row (never yes)
#   e. read-only: the fixture tree is byte-identical before and after
#   f. --deep without --json is refused (rc 2)

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/report-deep.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lanes" "$fixtureRepo/scripts/hooks" \
  "$fixtureRepo/.claude" "$fixtureRepo/.github/workflows" "$fixtureRepo/.git/hooks"
cp "$repo_root/scripts/install/manifest.json" "$fixtureRepo/scripts/install/manifest.json"
printf '{"lanes":[]}\n' > "$fixtureRepo/scripts/lanes/lanes.json"
: > "$fixtureRepo/.env"

cat > "$fixtureRepo/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: alpha-hook
        name: alpha
        entry: true
        language: system
        stages: [pre-commit]
      - id: beta-hook
        name: beta
        entry: true
        language: system
        stages: [pre-push]
YAML
cat > "$fixtureRepo/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"node \"$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js\" --chain \"$CLAUDE_PROJECT_DIR/scripts/hooks/present.sh\" \"$CLAUDE_PROJECT_DIR/scripts/hooks/missing.sh\""}]}]}}
JSON
printf '#!/usr/bin/env bash\n' > "$fixtureRepo/scripts/hooks/present.sh"
printf '#!/usr/bin/env bash\n' > "$fixtureRepo/.git/hooks/pre-commit"
printf 'name: ci\n' > "$fixtureRepo/.github/workflows/ci.yml"

homeDir="$work/home"; mkdir -p "$homeDir/.claude"
cacheDir="$work/cache"; mkdir -p "$cacheDir"
cat > "$cacheDir/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
target="$work/target"; mkdir -p "$target"

stubDoctor="$work/stub-doctor.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "'{\"sev\":\"OK\",\"id\":\"C1-x\",\"msg\":\"ok\",\"remedy\":\"\"}'" > "$stubDoctor"
chmod +x "$stubDoctor"
scriptRoot="$work/scripts-root"
mkdir -p "$scriptRoot/scripts/luna" "$scriptRoot/scripts/cleanup" "$scriptRoot/scripts/machine-setup"
for s in luna/pipeline-cadence luna/qmd-cadence luna/graphmap-cadence doctor-cadence cleanup/codex-sweep-cadence; do
  printf '#!/usr/bin/env bash\nexit 2\n' > "$scriptRoot/scripts/$s.sh"
done
printf '#!/usr/bin/env bash\necho %s\n' "'{\"always\":[],\"connectors\":[],\"onDemand\":[]}'" > "$scriptRoot/scripts/machine-setup/plugin-profile.sh"
chmod +x "$scriptRoot"/scripts/*.sh "$scriptRoot"/scripts/*/*.sh

run_report() {
  ( cd "$target" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
      HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$scriptRoot")" \
      "$node_bin" "$wizard" report "$@" )
}

snap() { ( cd "$fixtureRepo" && find . -type f -print0 | sort -z | xargs -0 cksum ); }

# ── a. no --deep, no wiring rows ────────────────────────────────────────────
run_report --json > "$work/plain.json" 2> "$work/plain.err" || { cat "$work/plain.err" >&2; fail "report --json failed"; }
n=$(jq '[.rows[]|select(.source=="wiring")]|length' "$work/plain.json")
[ "$n" -eq 0 ] || fail "wiring rows present without --deep ($n)"
pass "a no wiring rows without --deep"

# ── b. --deep rows ──────────────────────────────────────────────────────────
before=$(snap)
run_report --json --deep > "$work/deep.json" 2> "$work/deep.err" || { cat "$work/deep.err" >&2; fail "report --json --deep failed"; }
for id in precommit:alpha-hook precommit:beta-hook claude-hook:PreToolUse:present.sh claude-hook:PreToolUse:missing.sh git-hook:pre-commit git-hook:pre-push ci:ci.yml; do
  jq -e --arg id "$id" '[.rows[]|select(.id==$id and .source=="wiring")]|length==1' "$work/deep.json" >/dev/null || fail "missing wiring row $id"
done
[ "$(jq '[.rows[]|select(.source=="wiring")]|length' "$work/deep.json")" -eq 7 ] || fail "expected exactly 7 wiring rows"
bad=$(jq -r '.rows[]|select(.source=="wiring")|select((.group|type)!="string" or (.declared.where|type)!="string" or (.installed.state|type)!="string" or (.fires.state|type)!="string" or (.health|type)!="string" or (.fix|type)!="object")|.id' "$work/deep.json")
[ -z "$bad" ] || fail "wiring rows missing fields: $bad"
[ "$(jq '[.rows[].id]|length - (unique|length)' "$work/deep.json")" -eq 0 ] || fail "duplicate row ids"
pass "b --deep adds one row per pre-commit id, Claude hook, git hook, workflow"

# ── c. installed is derived ─────────────────────────────────────────────────
inst() { jq -r --arg id "$1" '.rows[]|select(.id==$id)|.installed.state' "$work/deep.json"; }
[ "$(inst claude-hook:PreToolUse:present.sh)" = present ] || fail "present.sh not present"
[ "$(inst claude-hook:PreToolUse:missing.sh)" = absent ] || fail "missing.sh not absent"
jq -e '.rows[]|select(.id=="claude-hook:PreToolUse:missing.sh")|.health=="fail" and (.fix.remedy|length>0)' "$work/deep.json" >/dev/null || fail "missing hook not fail with a remedy"
[ "$(inst git-hook:pre-commit)" = present ] || fail "git pre-commit not present"
[ "$(inst git-hook:pre-push)" = absent ] || fail "git pre-push not absent"
[ "$(inst precommit:alpha-hook)" = present ] || fail "alpha-hook (pre-commit stage) not present"
[ "$(inst precommit:beta-hook)" = absent ] || fail "beta-hook (pre-push stage) not absent"
[ "$(inst ci:ci.yml)" = present ] || fail "ci.yml not present"
pass "c installed derived from files"

# ── d. fires unverified ─────────────────────────────────────────────────────
[ "$(jq '[.rows[]|select(.source=="wiring" and .fires.state!="unverified")]|length' "$work/deep.json")" -eq 0 ] || fail "a wiring row claims fires"
pass "d fires unverified on every wiring row"

# ── e. read-only ────────────────────────────────────────────────────────────
[ "$before" = "$(snap)" ] || fail "fixture tree changed during report --deep"
pass "e report --deep is read-only"

# ── f. --deep needs --json ──────────────────────────────────────────────────
run_report --deep > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "report --deep without --json rc=$rc, want 2"
pass "f --deep without --json refused"
