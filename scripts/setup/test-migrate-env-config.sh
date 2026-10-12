#!/usr/bin/env bash
# Tests for migrate-env-config.sh. Hermetic: HOME is a temp dir and the env
# file is a fixture, so the operator's real ~/.himmel and .env are never read.
# shellcheck disable=SC2016 # the printed command is literal text for the operator
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/migrate-env-config.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 — missing '$2'" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 — found '$2'" ;; *) pass "$1" ;; esac; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
mkdir -p "$HOME"
ENVF="$TMP/fixture.env"
cat > "$ENVF" <<'EOF'
# a comment
HANDOVER_DIR=/val/conf/handovers
CR_PROFILE=valconfprofile   # gutter comment
JIRA_API_TOKEN=valsecrettoken
CR_FLOOR_FALLBACK=claude-only
EOF

# Dry run writes nothing and names keys only.
out=$(bash "$SCRIPT" --env "$ENVF" --dry-run 2>&1)
has "dry run names a config key" "would move  HANDOVER_DIR" "$out"
if [ -e "$HOME/.himmel/himmel.conf" ]; then fail "dry run wrote himmel.conf"; else pass "dry run wrote nothing"; fi

# A real run copies config keys, never secrets, and prints no values.
out=$(bash "$SCRIPT" --env "$ENVF" 2>&1)
conf=$(cat "$HOME/.himmel/himmel.conf")
has "HANDOVER_DIR copied" "HANDOVER_DIR=/val/conf/handovers" "$conf"
has "CR_PROFILE copied without its comment" "CR_PROFILE=valconfprofile" "$conf"
lacks "gutter comment not copied" "gutter" "$conf"
lacks "secret not copied" "JIRA_API_TOKEN" "$conf"
lacks "policy key not copied to himmel.conf" "CR_FLOOR_FALLBACK" "$conf"
lacks "output holds no config value" "/val/conf" "$out"
lacks "output holds no secret value" "valsecrettoken" "$out"
lacks "output holds no policy value" "claude-only" "$out"
has "output names the policy key" "CR_FLOOR_FALLBACK" "$out"

# The copied keys now load from himmel.conf with no deprecation notice.
got=$( (unset HANDOVER_DIR; . "$HERE/../lib/load-dotenv.sh"; load_dotenv HANDOVER_DIR; printf '[%s]' "${HANDOVER_DIR-}") 2>&1)
has "migrated key loads from himmel.conf" "[/val/conf/handovers]" "$got"
lacks "migrated key prints no deprecation notice" "DEPRECATED" "$got"

# Idempotent: a second run skips what is already there.
out=$(bash "$SCRIPT" --env "$ENVF" 2>&1)
has "second run skips" "skip  HANDOVER_DIR" "$out"
n=$(grep -c '^HANDOVER_DIR=' "$HOME/.himmel/himmel.conf")
if [ "$n" = 1 ]; then pass "no duplicate line"; else fail "duplicate HANDOVER_DIR lines: $n"; fi

# The printed policy command writes config.json .policy from .env.
if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s\n' "$out" | grep '^  v=\$(awk' | head -n 1)
    (cd "$TMP" && bash -c "$cmd") >/dev/null 2>&1
    v=$(jq -r '.policy.CR_FLOOR_FALLBACK // empty' "$HOME/.himmel/config.json" 2>/dev/null)
    if [ "$v" = claude-only ]; then pass "printed command writes the policy value"; else fail "printed command wrote '$v'"; fi
    got=$( (unset CR_FLOOR_FALLBACK; . "$HERE/../lib/load-dotenv.sh"; load_policy --root "$TMP/none" CR_FLOOR_FALLBACK; printf '[%s]' "${CR_FLOOR_FALLBACK-}") 2>&1)
    has "load_policy reads the migrated value" "[claude-only]" "$got"
else
    echo "SKIP printed policy command (no jq)"
fi

# --vault links ~/.himmel/himmel.conf to the tracked vault file.
rm -rf "$HOME/.himmel"
bash "$SCRIPT" --env "$ENVF" --vault "$TMP/vault" >/dev/null 2>&1
if [ -L "$HOME/.himmel/himmel.conf" ] && grep -q '^HANDOVER_DIR=' "$TMP/vault/.himmel/himmel.conf"; then
    pass "--vault links himmel.conf to the vault copy"
else
    fail "--vault did not link and fill the vault copy"
fi

if [ "$FAILED" -gt 0 ]; then
    echo "test-migrate-env-config: $FAILED FAILED"
    exit 1
fi
echo "test-migrate-env-config: all passed"
