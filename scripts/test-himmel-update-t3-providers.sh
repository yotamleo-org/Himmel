#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }
src_scripts="$(dirname "$SCRIPT")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-t3.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
unset HIMMEL_UPDATE_CHANNEL T3CODE_HOME HIMMEL_CONFIG_DIR HIMMEL_FLAG_AGY_DESIGN_PROFILE HIMMEL_FLAGS_TSV

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
has() { grep -q -- "$1" <<< "$2"; }
check_has() { if has "$2" "$3"; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got: $3"; fi; }
check_eq() { if [ "$2" = "$3" ]; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got '$3'"; fi; }

CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib" "$CLONE/scripts/t3" "$CLONE/scripts/lanes" || exit 1
if ! { cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh" \
    && cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh" \
    && cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh" \
    && cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh" \
    && cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh" \
    && cp "$src_scripts/lib/resolve-bun.sh"       "$CLONE/scripts/lib/resolve-bun.sh" \
    && cp "$src_scripts/lib/claude-version.sh"    "$CLONE/scripts/lib/claude-version.sh" \
    && cp "$src_scripts/lib/update-channel.sh"    "$CLONE/scripts/lib/update-channel.sh" \
    && cp "$src_scripts/t3/provider-instances.sh" "$CLONE/scripts/t3/provider-instances.sh" \
    && cp "$src_scripts/t3/antigravity-profiles.sh" "$CLONE/scripts/t3/antigravity-profiles.sh" \
    && cp "$src_scripts/lib/flags.sh"             "$CLONE/scripts/lib/flags.sh" \
    && cp "$src_scripts/lib/flags.tsv"            "$CLONE/scripts/lib/flags.tsv" \
    && cp "$src_scripts/lib/prim.sh"              "$CLONE/scripts/lib/prim.sh" \
    && cp "$src_scripts/lib/sha256-bin.sh"        "$CLONE/scripts/lib/sha256-bin.sh" \
    && cp "$src_scripts/lanes/plugin-profiles.json" "$CLONE/scripts/lanes/plugin-profiles.json" \
    && cp "$src_scripts/lanes/plugin-profiles.mjs" "$CLONE/scripts/lanes/plugin-profiles.mjs" \
    && cp "$src_scripts/lib/env-alias.mjs"        "$CLONE/scripts/lib/env-alias.mjs" \
    && cp "$src_scripts/lib/is-main.mjs"          "$CLONE/scripts/lib/is-main.mjs" \
    && git init --quiet "$CLONE"; }; then
    echo "FAIL: mock clone setup" >&2
    exit 1
fi

RESOLVER="$TMP/resolver.sh"
cat > "$RESOLVER" <<EOF
#!/bin/sh
[ "\${2:-}" = --mcp-config ] && exit 0
echo "$TMP/profiles/\$1.json"
EOF
chmod +x "$RESOLVER"

AGY_STUB="$TMP/agy-empty-list.sh"
cat > "$AGY_STUB" <<'STUB'
#!/bin/sh
[ "$1" = --list ] && exit 0
exit 2
STUB
chmod +x "$AGY_STUB"
export T3_PI_AGY_PROFILES="$AGY_STUB"

T3S="$HOME/.t3/userdata/settings.json"
seed() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":true}}}' > "$1"
}

run() {
    RC=0
    OUT="$(cd "$CLONE" && T3_PI_RESOLVER="$RESOLVER" T3_PI_PROFILES="alpha,beta" \
        bash scripts/himmel-update.sh "$@" 2>&1)" || RC=$?
}
ids() { jq -r '.providerInstances | keys | join(",")' "$1"; }
baks() { find "$(dirname "$1")" -name 'settings.json.bak.*' | wc -l | tr -d ' '; }

echo "--only t3_providers: adds one claudeAgent_<profile> per profile"
seed "$T3S"
run --only t3_providers
check_eq  "exit 0" 0 "$RC"
check_eq  "one instance per profile, the hand-made one kept" "claudeAgent,claudeAgent_alpha,claudeAgent_beta" "$(ids "$T3S")"
check_eq  "launchArgs names the profile's settings file" "--settings $TMP/profiles/alpha.json" \
    "$(jq -r '.providerInstances.claudeAgent_alpha.config.launchArgs' "$T3S")"
check_has "status row reads updated" "t3_providers *updated" "$OUT"
check_eq  "a backup was written" 1 "$(baks "$T3S")"

echo "--only t3_providers: a second run changes nothing and says so"
before="$(cksum < "$T3S")"
run --only t3_providers
check_eq  "exit 0" 0 "$RC"
check_eq  "settings file bytes unchanged" "$before" "$(cksum < "$T3S")"
check_has "says no change" "no change" "$OUT"
check_has "status row reads up-to-date" "t3_providers *up-to-date" "$OUT"
check_eq  "no second backup" 1 "$(baks "$T3S")"

echo "--only t3_providers: T3CODE_HOME names the settings file"
seed "$TMP/t3alt/userdata/settings.json"
RC=0
OUT="$(cd "$CLONE" && T3CODE_HOME="$TMP/t3alt" T3_PI_RESOLVER="$RESOLVER" T3_PI_PROFILES="alpha,beta" \
    bash scripts/himmel-update.sh --only t3_providers 2>&1)" || RC=$?
check_eq  "exit 0" 0 "$RC"
check_eq  "the T3CODE_HOME file got the instances" "claudeAgent,claudeAgent_alpha,claudeAgent_beta" \
    "$(ids "$TMP/t3alt/userdata/settings.json")"

echo "--only t3_providers: no T3 settings file skips with one line"
rm -rf "$HOME/.t3"
run --only t3_providers
check_eq  "exit 0" 0 "$RC"
check_eq  "exactly one skip line" 1 "$(grep -c 'T3 provider instances: skipped' <<< "$OUT")"
check_has "status row reads skipped" "t3_providers *skipped" "$OUT"
check_eq  "no settings file created" no "$([ -e "$T3S" ] && echo yes || echo no)"

echo "--only t3_providers: jq missing skips with one line"
seed "$T3S"
NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for d in /usr/bin /bin; do
    for f in "$d"/*; do
        n="${f##*/}"
        [ "$n" = jq ] || [ -e "$NOJQ/$n" ] || ln -s "$f" "$NOJQ/$n" 2>/dev/null
    done
done
before="$(cksum < "$T3S")"
RC=0
OUT="$(cd "$CLONE" && PATH="$NOJQ" T3_PI_RESOLVER="$RESOLVER" T3_PI_PROFILES="alpha,beta" \
    bash scripts/himmel-update.sh --only t3_providers 2>&1)" || RC=$?
check_eq  "exit 0" 0 "$RC"
check_has "names jq in the skip line" "skipped (jq" "$OUT"
check_eq  "settings file untouched" "$before" "$(cksum < "$T3S")"

echo "--only t3_providers: a bypass-flag instance is refused, nothing written"
mkdir -p "$(dirname "$T3S")"
printf '%s\n' '{"providerInstances":{"x":{"driver":"claudeAgent","environment":{"EDIT_LIVE_SETTINGS_OK":"1"}}}}' > "$T3S"
before="$(cksum < "$T3S")"
run --only t3_providers
check_eq  "exit 1" 1 "$RC"
check_has "status row reads failed" "t3_providers *failed" "$OUT"
check_eq  "settings file untouched" "$before" "$(cksum < "$T3S")"

AGY_REG="$TMP/agy-registry.json"
printf '%s\n' '{"profiles":{"design":{"fromProfiles":[]}}}' > "$AGY_REG"
AGY_BACKSTOP="$TMP/agy-backstop.sh"
cat > "$AGY_BACKSTOP" <<'STUB'
#!/usr/bin/env bash
for d in "${T3CODE_HOME:-$HOME/.t3}"/userdata/providers/antigravity/*/; do
  [ -d "$d" ] || continue
  mkdir -p "$d/config"
  printf '{"himmel-antigravity-backstop":{}}' > "$d/config/hooks.json"
done
STUB
chmod +x "$AGY_BACKSTOP"
AGY_ROOT="$HOME/.t3/userdata/providers/antigravity"
runon() {
    RC=0
    OUT="$(cd "$CLONE" && HIMMEL_FLAG_AGY_DESIGN_PROFILE=1 T3_AP_REGISTRY="$AGY_REG" T3_AP_BACKSTOP="$AGY_BACKSTOP" \
        T3_PI_AGY_PROFILES="$CLONE/scripts/t3/antigravity-profiles.sh" T3_PI_RESOLVER="$RESOLVER" T3_PI_PROFILES="alpha,beta" \
        bash scripts/himmel-update.sh "$@" 2>&1)" || RC=$?
}

echo "--only agy_profiles: the flag is off by default, one skipped line and nothing written"
rm -rf "$HOME/.t3"
seed "$T3S"
before="$(cksum < "$T3S")"
run --only agy_profiles
check_eq  "exit 0" 0 "$RC"
check_eq  "exactly one skip line" 1 "$(grep -c 'Antigravity profiles: skipped' <<< "$OUT")"
check_has "the skip line names the flag" "agy_design_profile" "$OUT"
check_has "status row reads skipped" "agy_profiles *skipped" "$OUT"
check_eq  "no provider home tree created" no "$([ -e "$AGY_ROOT" ] && echo yes || echo no)"
check_eq  "settings file untouched" "$before" "$(cksum < "$T3S")"

echo "--only agy_profiles: flag on, no T3 settings file skips with one line"
rm -rf "$HOME/.t3"
runon --only agy_profiles
check_eq  "exit 0" 0 "$RC"
check_eq  "exactly one skip line" 1 "$(grep -c 'Antigravity profiles: skipped' <<< "$OUT")"
check_eq  "no provider home tree created" no "$([ -e "$AGY_ROOT" ] && echo yes || echo no)"

echo "--only agy_profiles: flag on applies every registry profile and prints the allowlist lines"
seed "$T3S"
before="$(cksum < "$T3S")"
runon --only agy_profiles
check_eq  "exit 0" 0 "$RC"
check_eq  "one profile home exists" 1 "$(find "$AGY_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
RC=0
(cd "$CLONE" && T3_AP_REGISTRY="$AGY_REG" T3_AP_BACKSTOP="$AGY_BACKSTOP" bash scripts/t3/antigravity-profiles.sh --check --profile design >/dev/null 2>&1) || RC=$?
check_eq  "antigravity-profiles --check --profile design is rc 0" 0 "$RC"
check_has "the allowlist line is printed ready to paste" '"antigravity_design"' "$OUT"
check_has "the allowlist is the operator's to paste" "instance_allowlist" "$OUT"
check_has "status row reads updated" "agy_profiles *updated" "$OUT"
check_eq  "the T3 settings file is not written by this step" "$before" "$(cksum < "$T3S")"

echo "--only agy_profiles: a second run changes nothing"
runon --only agy_profiles
check_eq  "exit 0" 0 "$RC"
check_has "status row reads up-to-date" "agy_profiles *up-to-date" "$OUT"

echo "--only agy_profiles: a bad flag value is a failed row, not a silent off"
RC=0
OUT="$(cd "$CLONE" && HIMMEL_FLAG_AGY_DESIGN_PROFILE=maybe bash scripts/himmel-update.sh --only agy_profiles 2>&1)" || RC=$?
check_eq  "exit 1" 1 "$RC"
check_has "status row reads failed" "agy_profiles *failed" "$OUT"
check_has "names the bad value" "bad value" "$OUT"

echo "--only t3_providers after agy_profiles: the antigravity_design instance is added"
runon --only t3_providers
check_eq  "exit 0" 0 "$RC"
check_has "the profile instance is in T3's settings" "antigravity_design" "$(ids "$T3S")"

echo "full run order: agy_profiles runs before sync_t3_providers"
awk '/^sync_agy_profiles \|\| true/{a=NR} /^sync_t3_providers \|\| true/{b=NR} END{exit !(a && b && a < b)}' "$SCRIPT"
check_eq  "the step is called before sync_t3_providers" 0 "$?"

echo "usage and unknown-item texts name t3_providers"
run --help
check_has "usage lists the item" "t3_providers" "$OUT"
check_has "usage lists agy_profiles" "agy_profiles" "$OUT"
run --only no_such_item
check_eq  "unknown item exits 2" 2 "$RC"
check_has "unknown-item list names t3_providers" "env_migration t3_providers" "$OUT"

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
