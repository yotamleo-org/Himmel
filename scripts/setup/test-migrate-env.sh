#!/usr/bin/env bash
# Tests for migrate-env.sh, the one-step .env migration the update runs.
# Hermetic: HOME is a temp dir, every .env is a fixture with canary values, and
# the apply rows run a fixture checkout built from copies of the real scripts,
# so the operator's real ~/.himmel and .env are never read or written.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 — missing '$2'" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 — found '$2'" ;; *) pass "$1" ;; esac; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
no_canary() {  # <label> <text>: no fixture value reaches the text
    case "$2" in *CANARY-*) fail "$1 — a value was printed" ;; *) pass "$1" ;; esac
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-env.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
mkdir -p "$HOME"
# The script refuses to apply inside an agent session; these rows are the
# operator's run, so the marker is dropped (row 6 puts it back).
unset CLAUDECODE

canary() { printf 'CANARY-%s-%s' "$1" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

# --- 1. The real .env.example key names, classified by the real checkout ---
# Every key the template names, commented or not, as an operator's .env holds
# them, plus one secret no himmel file reads.
mkdir -p "$TMP/real"
names=$(sed -n 's/^#\{0,1\}[[:space:]]*\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$REPO/.env.example" | awk '!seen[$0]++')
{ for k in $names; do printf '%s=%s\n' "$k" "$(canary "$k")"; done
  printf 'NOT_READ_BY_HIMMEL_ZZQ=%s\n' "$(canary unread)"; } > "$TMP/real/.env"
cp "$TMP/real/.env" "$TMP/real.orig"
out=$(bash "$REPO/scripts/setup/migrate-env.sh" --dry-run --env "$TMP/real/.env" 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "real-template dry run exits 0"; else fail "real-template dry run exited $rc"; fi
missing=""
for k in $names NOT_READ_BY_HIMMEL_ZZQ; do
    printf '%s\n' "$out" | grep -q "^  $k " || missing="$missing $k"
done
if [ -z "$missing" ]; then pass "the report lists every .env key"; else fail "the report misses:$missing"; fi
has "a behaviour key goes to himmel.conf" "  HANDOVER_DIR → ~/.himmel/himmel.conf" "$out"
has "a policy key goes to config.json" "  CR_REQUIRE_CROSS_MODEL → ~/.himmel/config.json .policy" "$out"
has "a secret something reads stays" "  JIRA_API_TOKEN stays (read by " "$out"
has "a secret nothing reads goes to the secrets store" "  NOT_READ_BY_HIMMEL_ZZQ → ~/.config/secrets/himmel.env" "$out"
no_canary "the dry run prints no value" "$out"
if cmp -s "$TMP/real/.env" "$TMP/real.orig" && [ ! -e "$HOME/.himmel" ] && [ ! -e "$HOME/.config" ]; then
    pass "the dry run writes nothing"
else
    fail "the dry run wrote something"
fi

# --- fixture checkout: copies of the real scripts and readers ---
FX="$TMP/fx"
mkdir -p "$FX/scripts/setup" "$FX/scripts/lib" "$FX/scripts/lanes" "$FX/scripts/jira/dist/release" "$FX/docs/setup"
cp "$REPO"/scripts/setup/migrate-env*.sh "$REPO"/scripts/setup/migrate-env*.mjs "$FX/scripts/setup/" 2>/dev/null
rm -f "$FX/scripts/setup/test-"*
cp "$REPO/scripts/lib/load-dotenv.sh" "$REPO/scripts/lib/prim.sh" "$FX/scripts/lib/"
cp "$REPO"/scripts/lanes/resolve.mjs "$REPO"/scripts/lanes/probe.mjs "$REPO"/scripts/lanes/bank-status-core.mjs \
    "$REPO"/scripts/lanes/profile-managed.cjs "$FX/scripts/lanes/"
cp "$REPO/docs/setup/himmel-config.example.json" "$FX/docs/setup/"
# The Jira CLI readers, from their real source with the types stripped.
strip_ts() {
    node -e 'const m = require("node:module"); const fs = require("node:fs");
        process.stdout.write(m.stripTypeScriptTypes(fs.readFileSync(process.argv[1], "utf8")))' "$1" > "$2" 2>/dev/null
}
if ! strip_ts "$REPO/scripts/jira/src/handover-root.ts" "$FX/scripts/jira/dist/handover-root.js" \
    || ! strip_ts "$REPO/scripts/jira/src/release/paths.ts" "$FX/scripts/jira/dist/release/paths.js"; then
    echo "SKIP apply rows: this node cannot strip TypeScript types"
    [ "$FAILED" -eq 0 ] || { echo "test-migrate-env: $FAILED FAILED"; exit 1; }
    exit 0
fi
printf '{"type":"module"}\n' > "$FX/scripts/jira/dist/package.json"
# shellcheck disable=SC2016 # the fixture reader names the variable literally
printf 'printf %%s "$READ_SECRET"\n' >"$FX/scripts/reads-secret.sh"
git -C "$FX" init -q && git -C "$FX" add -A
SCRIPT="$FX/scripts/setup/migrate-env.sh"

mkdir -p "$TMP/handovers"
fixture_env() {  # a fresh station-shaped .env, mode 600, and no config files
    rm -rf "$HOME/.himmel" "$HOME/.config" "$TMP/st"
    mkdir -p "$TMP/st"
    { echo "# station .env"
      echo "HANDOVER_DIR=$TMP/handovers"
      echo "USER_SLUG=$(canary slug)"
      echo "CR_PROFILE=$(canary profile)"
      echo "CR_REQUIRE_CROSS_MODEL=1"
      echo "READ_SECRET=$(canary read)"
      echo "UNREAD_SECRET=$(canary unread)"
      echo "KEEP_ME=$(canary keep)"; } > "$TMP/st/.env"
    chmod 600 "$TMP/st/.env"
    cp -p "$TMP/st/.env" "$TMP/st.orig"
    mkdir -p "$HOME/.himmel"
    printf '# station-ops reads this one\nKEEP_ME\n' > "$HOME/.himmel/env-keep.txt"
}

# --- 2. A clean apply moves every key, backs up first, and verifies ---
fixture_env
out=$(bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "apply exits 0"; else fail "apply exited $rc: $out"; fi
no_canary "apply prints no value" "$out"
backup=$(printf '%s\n' "$out" | sed -n 's/^backup: \(.*\) (mode 600)$/\1/p')
if [ -n "$backup" ] && cmp -s "$backup" "$TMP/st.orig"; then pass "the backup holds the original .env"; else fail "no backup matching the original .env (path '$backup')"; fi
if [ -n "$backup" ] && [ "$(mode_of "$backup")" = 600 ]; then pass "the backup is mode 600"; else fail "the backup mode is not 600"; fi
case "$backup" in "$TMP/st/"*|"") fail "the backup is inside the checkout or missing" ;; *) pass "the backup is outside the checkout" ;; esac
has "the report names the restore command" "restore: cp $backup $TMP/st/.env" "$out"
has "the report says the backup can be removed" "rm $backup" "$out"
conf=$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)
has "HANDOVER_DIR moved to himmel.conf" "HANDOVER_DIR=$TMP/handovers" "$conf"
has "USER_SLUG moved to himmel.conf" "USER_SLUG=CANARY-slug-" "$conf"
pol=$(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.CR_REQUIRE_CROSS_MODEL))' "$HOME/.himmel/config.json" 2>/dev/null)
if [ "$pol" = 1 ]; then pass "the policy key moved to config.json with its value"; else fail "config.json .policy.CR_REQUIRE_CROSS_MODEL is '$pol'"; fi
store="$HOME/.config/secrets/himmel.env"
if grep -q '^UNREAD_SECRET=CANARY-unread-' "$store" 2>/dev/null && [ "$(mode_of "$store")" = 600 ]; then
    pass "the unread secret moved to a mode-600 store"
else
    fail "the unread secret is not in a mode-600 store"
fi
envnow=$(cat "$TMP/st/.env")
for k in HANDOVER_DIR USER_SLUG CR_PROFILE CR_REQUIRE_CROSS_MODEL UNREAD_SECRET; do
    lacks "$k removed from .env" "$k=" "$envnow"
done
has "a secret something reads stays in .env" "READ_SECRET=CANARY-read-" "$envnow"
has "a keep-list key stays in .env" "KEEP_ME=CANARY-keep-" "$envnow"
has "comments stay in .env" "# station .env" "$envnow"
if [ "$(mode_of "$TMP/st/.env")" = 600 ]; then pass ".env keeps its mode"; else fail ".env mode changed"; fi
has "the report shows the keep-list reason" "  KEEP_ME stays (keep-list)" "$out"
has "the report names the verified readers" "verified: load_dotenv, load_policy, jira config reader, jira handover root, jira release state, lanes resolve" "$out"
has "the report names the compared policy keys" "policy compared: ARMAUTOMERGE CR_FLOOR_FALLBACK CR_REQUIRE_CROSS_MODEL" "$out"
got=$( (unset HANDOVER_DIR; cd "$FX" && . "$FX/scripts/lib/load-dotenv.sh" && load_dotenv --root "$TMP/st" HANDOVER_DIR; printf '[%s]' "${HANDOVER_DIR-}") 2>&1)
has "the moved key still loads, without a deprecation notice" "[$TMP/handovers]" "$got"
lacks "no deprecation notice after the move" "DEPRECATED" "$got"

# A second run has nothing left to move and takes no new backup.
out=$(bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
has "a second run moves nothing" "nothing to move" "$out"
n=$(find "$HOME/.himmel/env-backups" -type f | wc -l | tr -d ' ')
if [ "$n" = 1 ]; then pass "a second run takes no backup"; else fail "a second run left $n backups"; fi

# --- 3. A reader that still reads .env only aborts ---
fixture_env
cp "$FX/scripts/jira/dist/handover-root.js" "$TMP/handover-root.good.js"
cat > "$FX/scripts/jira/dist/handover-root.js" <<'EOF'
import { existsSync, readFileSync } from 'node:fs';
export function behaviourKey(key, env = process.env, dotenvPath = '.env') {
  if (env[key]) return env[key];
  if (!existsSync(dotenvPath)) return undefined;
  const line = readFileSync(dotenvPath, 'utf8').split('\n').find((l) => l.startsWith(key + '='));
  return line ? line.slice(key.length + 1) : undefined;
}
export function handoverRoot(env = process.env, dotenvPath) {
  return behaviourKey('HANDOVER_DIR', env, dotenvPath) || '/nowhere/handovers';
}
EOF
out=$(bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
rc=$?
if [ "$rc" != 0 ]; then pass "a .env-only reader fails the migration"; else fail "a .env-only reader passed verify"; fi
has "the failing reader and key are named" "MISMATCH HANDOVER_DIR (jira handover root)" "$out"
has "the user is told no line was removed" "no lines were removed from .env" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the failed verify leaves .env untouched"; else fail "the failed verify changed .env"; fi
no_canary "the failed verify prints no value" "$out"
cp "$TMP/handover-root.good.js" "$FX/scripts/jira/dist/handover-root.js"

# --- 4. A policy value that would change aborts ---
fixture_env
printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n' > "$HOME/.himmel/config.json"
out=$(bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
rc=$?
if [ "$rc" != 0 ]; then pass "a policy value that would change aborts"; else fail "a policy change from 1 to 0 passed"; fi
has "the changed policy key is named" "MISMATCH CR_REQUIRE_CROSS_MODEL (load_policy)" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the policy abort leaves .env untouched"; else fail "the policy abort changed .env"; fi

# --- 5. A policy value lost by the reader aborts ---
fixture_env
cp "$FX/scripts/lib/load-dotenv.sh" "$TMP/load-dotenv.good.sh"
sed 's/out += key + "=" + s + "\\n";//' "$TMP/load-dotenv.good.sh" > "$FX/scripts/lib/load-dotenv.sh"
out=$(bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
rc=$?
if [ "$rc" != 0 ]; then pass "a policy value missing after the move aborts"; else fail "a lost policy value passed"; fi
has "the lost policy key is named" "MISMATCH CR_REQUIRE_CROSS_MODEL (load_policy)" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the lost-policy abort leaves .env untouched"; else fail "the lost-policy abort changed .env"; fi
cp "$TMP/load-dotenv.good.sh" "$FX/scripts/lib/load-dotenv.sh"

# --- 6. Inside an agent session the apply refuses and names the command ---
fixture_env
rm -rf "$HOME/.himmel"
out=$(CLAUDECODE=1 bash "$SCRIPT" --env "$TMP/st/.env" 2>&1)
rc=$?
if [ "$rc" = 3 ]; then pass "an agent session cannot apply (exit 3)"; else fail "an agent session apply exited $rc"; fi
has "the refusal names the operator command" "bash $SCRIPT" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig" && [ ! -e "$HOME/.himmel" ]; then pass "the refusal writes nothing"; else fail "the refusal wrote something"; fi

if [ "$FAILED" -gt 0 ]; then
    echo "test-migrate-env: $FAILED FAILED"
    exit 1
fi
echo "test-migrate-env: all passed"
