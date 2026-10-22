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
CR_FLOOR_FALLBACK="claude-only"
EOF

# A flag missing its value is refused, not looped on.
for flag in --env --vault; do
    timeout 10 bash "$SCRIPT" "$flag" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 2 ]; then pass "$flag with no value exits 2"; else fail "$flag with no value exited $rc"; fi
done

# Setup, adopt and himmelctl read the tracked file now, so a real run needs no
# opt-in flag; the old flag is still accepted and changes nothing.
out=$(bash "$SCRIPT" --env "$ENVF" 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "a run without --ahead-of-setup exits 0"; else fail "a run without --ahead-of-setup exited $rc"; fi
has "a run without the flag moves a config key" "moved HANDOVER_DIR" "$out"
if [ -e "$HOME/.himmel/himmel.conf" ]; then pass "a run without the flag wrote himmel.conf"; else fail "a run without the flag wrote no himmel.conf"; fi
rm -rf "$HOME/.himmel"

# Dry run writes nothing and names keys only.
out=$(bash "$SCRIPT" --env "$ENVF" --dry-run 2>&1)
has "dry run names a config key" "would move  HANDOVER_DIR" "$out"
if [ -e "$HOME/.himmel/himmel.conf" ]; then fail "dry run wrote himmel.conf"; else pass "dry run wrote nothing"; fi

# A real run copies config keys, never secrets, and prints no values.
out=$(bash "$SCRIPT" --ahead-of-setup --env "$ENVF" 2>&1)
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
out=$(bash "$SCRIPT" --ahead-of-setup --env "$ENVF" 2>&1)
has "second run skips" "skip  HANDOVER_DIR" "$out"
n=$(grep -c '^HANDOVER_DIR=' "$HOME/.himmel/himmel.conf")
if [ "$n" = 1 ]; then pass "no duplicate line"; else fail "duplicate HANDOVER_DIR lines: $n"; fi

# The printed policy command writes config.json .policy from .env.
if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s\n' "$out" | grep '^  v=\$(awk' | head -n 1)
    (cd "$TMP" && bash -c "$cmd") >/dev/null 2>&1
    v=$(jq -r '.policy.CR_FLOOR_FALLBACK // empty' "$HOME/.himmel/config.json" 2>/dev/null)
    if [ "$v" = claude-only ]; then pass "printed command writes the policy value, its dotenv quotes stripped"; else fail "printed command wrote '$v'"; fi
    got=$( (unset CR_FLOOR_FALLBACK; . "$HERE/../lib/load-dotenv.sh"; load_policy --root "$TMP/none" CR_FLOOR_FALLBACK; printf '[%s]' "${CR_FLOOR_FALLBACK-}") 2>&1)
    has "load_policy reads the migrated value" "[claude-only]" "$got"
    # The printed command creates ~/.himmel when it is missing.
    rm -rf "$HOME/.himmel"
    (cd "$TMP" && bash -c "$cmd") >/dev/null 2>&1
    v=$(jq -r '.policy.CR_FLOOR_FALLBACK // empty' "$HOME/.himmel/config.json" 2>/dev/null)
    if [ "$v" = claude-only ]; then pass "printed command creates ~/.himmel"; else fail "printed command without ~/.himmel wrote '$v'"; fi
else
    echo "SKIP printed policy command (no jq)"
fi

# A destination that cannot be written is reported, never counted as moved.
rm -rf "$HOME/.himmel"
mkdir -p "$HOME/.himmel/himmel.conf"
out=$(bash "$SCRIPT" --ahead-of-setup --env "$ENVF" 2>&1)
rc=$?
if [ "$rc" != 0 ]; then pass "unwritable himmel.conf exits non-zero"; else fail "unwritable himmel.conf exited 0"; fi
lacks "unwritable himmel.conf reports nothing moved" "moved HANDOVER_DIR" "$out"
rm -rf "$HOME/.himmel"

# A himmel.conf whose last line has no newline keeps that setting intact.
mkdir -p "$HOME/.himmel"
printf 'USER_SLUG=keepme' > "$HOME/.himmel/himmel.conf"
bash "$SCRIPT" --ahead-of-setup --env "$ENVF" >/dev/null 2>&1
if grep -qx 'USER_SLUG=keepme' "$HOME/.himmel/himmel.conf" && grep -q '^HANDOVER_DIR=' "$HOME/.himmel/himmel.conf"; then
    pass "append after a last line with no newline keeps both settings"
else
    fail "append after a last line with no newline corrupted himmel.conf"
fi
rm -rf "$HOME/.himmel"

# --vault refuses a himmel.conf link that points at a different file.
mkdir -p "$HOME/.himmel" "$TMP/othervault"
: > "$TMP/othervault/himmel.conf"
ln -s "$TMP/othervault/himmel.conf" "$HOME/.himmel/himmel.conf"
out=$(bash "$SCRIPT" --ahead-of-setup --env "$ENVF" --vault "$TMP/vault" 2>&1)
rc=$?
if [ "$rc" != 0 ]; then pass "--vault refuses a link to another file"; else fail "--vault accepted a link to another file"; fi
lacks "--vault with a foreign link moves nothing" "moved HANDOVER_DIR" "$out"
rm -rf "$HOME/.himmel" "$TMP/vault"

# --vault links ~/.himmel/himmel.conf to the tracked vault file.
rm -rf "$HOME/.himmel"
bash "$SCRIPT" --ahead-of-setup --env "$ENVF" --vault "$TMP/vault" >/dev/null 2>&1
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
