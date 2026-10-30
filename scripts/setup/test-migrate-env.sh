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
# The policy dir comes from the account entry; this seam points it back at HOME.
export HIMMEL_POLICY_FOLLOWS_HOME=1
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
mkdir -p "$HOME"
# The script refuses to apply inside an agent session; these rows are the
# operator's run, so the marker is dropped (row 6 puts it back).
unset CLAUDECODE

canary() { printf 'CANARY-%s-%s' "$1" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

# --- 1. The real .env.example key names, classified by the real checkout ---
# Every key the template names, commented or not, as an operator's .env holds
# them, plus one key that is not himmel's.
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
    case "$out" in *$'\n'"  $k "*) ;; *) missing="$missing $k" ;; esac
done
if [ -z "$missing" ]; then pass "the report lists every .env key"; else fail "the report misses:$missing"; fi
has "a behaviour key goes to himmel.conf" "  HANDOVER_DIR → ~/.himmel/himmel.conf" "$out"
has "a policy key goes to config.json" "  CR_REQUIRE_CROSS_MODEL → ~/.himmel/config.json .policy" "$out"
has "a secret something reads stays" "  JIRA_API_TOKEN stays (read by " "$out"
has "a key that is not himmel's stays" "  NOT_READ_BY_HIMMEL_ZZQ stays (not himmel's, left in place)" "$out"
has "the dry run names the backup it will take" "backup: the apply first copies .env (mode 600) to $HOME/.himmel/env-backups/env." "$out"
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
cp "$REPO/scripts/lib/load-dotenv.sh" "$REPO/scripts/lib/prim.sh" "$REPO/scripts/lib/chokepoint-seam-guard.sh" "$FX/scripts/lib/"
cp "$REPO"/scripts/lanes/resolve.mjs "$REPO"/scripts/lanes/probe.mjs "$REPO"/scripts/lanes/bank-status-core.mjs \
    "$REPO"/scripts/lanes/profile-managed.cjs "$FX/scripts/lanes/"
cp "$REPO/docs/setup/himmel-config.example.json" "$FX/docs/setup/"
printf '# READ_SECRET=\nUNREAD_SECRET=\nKEEP_ME=\n' > "$FX/.env.example"
# The Jira CLI readers, from their real source with the types stripped.
strip_ts() {
    node -e 'const m = require("node:module"); const fs = require("node:fs");
        process.stdout.write(m.stripTypeScriptTypes(fs.readFileSync(process.argv[1], "utf8")))' "$1" > "$2" 2>/dev/null
}
if ! node -e 'process.exit(typeof require("node:module").stripTypeScriptTypes === "function" ? 0 : 1)'; then
    echo "SKIP apply rows: this node cannot strip TypeScript types"
    [ "$FAILED" -eq 0 ] || { echo "test-migrate-env: $FAILED FAILED"; exit 1; }
    exit 0
fi
# The apply asks y/N at a terminal: util-linux script gives it one, and
# timeout bounds a run that never gets its answer.
if ! script -qec true /dev/null >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo "SKIP apply rows: no util-linux script and timeout for a terminal"
    [ "$FAILED" -eq 0 ] || { echo "test-migrate-env: $FAILED FAILED"; exit 1; }
    exit 0
fi
at_tty() {  # <answer> <command>: run it at a terminal, typing <answer>; sets out and rc
    printf '%s\n' "$1" | SHELL=$(command -v bash) timeout 120 script -qec "$2" /dev/null > "$TMP/tty.out" 2>&1
    rc=$?
    out=$(tr -d '\r' < "$TMP/tty.out")
}
apply_tty() {  # <answer> [<prefix>]: the apply on the station .env, at a terminal
    at_tty "$1" "${2:-}bash $(printf '%q --env %q' "$SCRIPT" "$TMP/st/.env")"
}
if ! strip_ts "$REPO/scripts/jira/src/handover-root.ts" "$FX/scripts/jira/dist/handover-root.js" \
    || ! strip_ts "$REPO/scripts/jira/src/release/paths.ts" "$FX/scripts/jira/dist/release/paths.js"; then
    echo "FAIL the Jira reader sources no longer strip to JavaScript"
    echo "test-migrate-env: $((FAILED + 1)) FAILED"
    exit 1
fi
printf '{"type":"module"}\n' > "$FX/scripts/jira/dist/package.json"
# shellcheck disable=SC2016 # the fixture reader names the variable literally
printf 'printf %%s "$READ_SECRET"\n' >"$FX/scripts/reads-secret.sh"
# The git dir is not named .git: a fixture that is its own primary checkout is an
# anchor to the seam guard, which refuses the CLAUDECODE rows on CI (no claude ancestor).
if ! { git init -q --separate-git-dir "$FX/.fxgit" "$FX" && mkdir -p "$FX/.fxgit/info" && printf '.fxgit/\n' >> "$FX/.fxgit/info/exclude" && git -C "$FX" add -A; }; then
    echo "FAIL the fixture checkout could not be set up"
    echo "test-migrate-env: $((FAILED + 1)) FAILED"
    exit 1
fi
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
      echo "HIMMEL_FLEET_CAP=7"
      echo "READ_SECRET=$(canary read)"
      echo "UNREAD_SECRET=$(canary unread)"
      echo "KEEP_ME=$(canary keep)"
      echo "OTHER_TOOL_TOKEN=$(canary other)"; } > "$TMP/st/.env"
    chmod 600 "$TMP/st/.env"
    cp -p "$TMP/st/.env" "$TMP/st.orig"
    mkdir -p "$HOME/.himmel"
    printf '# station-ops reads this one\nKEEP_ME\n' > "$HOME/.himmel/env-keep.txt"
}

# --- 2a. The apply moves nothing without a yes typed at a terminal ---
fixture_env
out=$(bash "$SCRIPT" --env "$TMP/st/.env" < /dev/null 2>&1)
rc=$?
if [ "$rc" = 3 ]; then pass "an apply with no terminal is refused (exit 3)"; else fail "an apply with no terminal exited $rc"; fi
has "the no-terminal refusal says why" "no terminal to confirm the move at; nothing written." "$out"
has "the no-terminal refusal names the operator command" "bash $SCRIPT --env $TMP/st/.env" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig" && [ ! -e "$HOME/.himmel/env-backups" ] && [ ! -e "$HOME/.himmel/himmel.conf" ]; then
    pass "the no-terminal refusal leaves .env byte-identical and writes nothing"
else
    fail "the no-terminal refusal wrote something"
fi
for answer in n ""; do
    fixture_env
    apply_tty "$answer"
    if [ "$rc" = 3 ]; then pass "the answer '$answer' declines (exit 3)"; else fail "the answer '$answer' exited $rc"; fi
    has "the apply asks before it moves" "Move these keys now (backup first)? [y/N]" "$out"
    has "a declined apply names the command for later" "skipped: nothing written." "$out"
    if cmp -s "$TMP/st/.env" "$TMP/st.orig" && [ ! -e "$HOME/.himmel/env-backups" ]; then
        pass "the answer '$answer' leaves .env byte-identical"
    else
        fail "the answer '$answer' changed something"
    fi
done

# --- 2. A clean apply moves every key, backs up first, and verifies ---
fixture_env
apply_tty y
if [ "$rc" = 0 ]; then pass "apply exits 0"; else fail "apply exited $rc: $out"; fi
no_canary "apply prints no value" "$out"
# The prompt ends its line only when the answer is typed, so match mid-line.
backup=$(printf '%s\n' "$out" | sed -n 's/.*backup: \(\/.*\) (mode 600)$/\1/p')
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
cap=$(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.HIMMEL_FLEET_CAP))' "$HOME/.himmel/config.json" 2>/dev/null)
if [ "$cap" = 7 ]; then pass "the legacy fleet cap moved to config.json .policy"; else fail "config.json .policy.HIMMEL_FLEET_CAP is '$cap'"; fi
store="$HOME/.config/secrets/himmel.env"
if grep -q '^UNREAD_SECRET=CANARY-unread-' "$store" 2>/dev/null && [ "$(mode_of "$store")" = 600 ]; then
    pass "the unread secret moved to a mode-600 store"
else
    fail "the unread secret is not in a mode-600 store"
fi
envnow=$(cat "$TMP/st/.env")
for k in HANDOVER_DIR USER_SLUG CR_PROFILE CR_REQUIRE_CROSS_MODEL HIMMEL_FLEET_CAP UNREAD_SECRET; do
    lacks "$k removed from .env" "$k=" "$envnow"
done
has "a secret something reads stays in .env" "READ_SECRET=CANARY-read-" "$envnow"
has "a keep-list key stays in .env" "KEEP_ME=CANARY-keep-" "$envnow"
has "comments stay in .env" "# station .env" "$envnow"
if [ "$(mode_of "$TMP/st/.env")" = 600 ]; then pass ".env keeps its mode"; else fail ".env mode changed"; fi
has "the report shows the keep-list reason" "  KEEP_ME stays (keep-list)" "$out"
has "the report leaves a key that is not himmel's" "  OTHER_TOOL_TOKEN stays (not himmel's, left in place)" "$out"
has "a key that is not himmel's stays in .env" "OTHER_TOOL_TOKEN=CANARY-other-" "$envnow"
lacks "a key that is not himmel's is not copied to the store" "OTHER_TOOL_TOKEN" "$(cat "$store" 2>/dev/null)"
has "the report names the verified readers" "verified: load_dotenv, load_policy, jira config reader, jira handover root, jira release state, lanes resolve" "$out"
has "the report names the compared policy keys" "policy compared: ARMAUTOMERGE CR_FLOOR_FALLBACK CR_REQUIRE_CROSS_MODEL" "$out"
got=$( (unset HANDOVER_DIR; cd "$FX" && . "$FX/scripts/lib/load-dotenv.sh" && load_dotenv --root "$TMP/st" HANDOVER_DIR; printf '[%s]' "${HANDOVER_DIR-}") 2>&1)
has "the moved key still loads, without a deprecation notice" "[$TMP/handovers]" "$got"
lacks "no deprecation notice after the move" "DEPRECATED" "$got"

# A second run has nothing left to move and takes no new backup.
apply_tty y
has "a second run moves nothing" "nothing to move" "$out"
n=$(find "$HOME/.himmel/env-backups" -type f | wc -l | tr -d ' ')
if [ "$n" = 1 ]; then pass "a second run takes no backup"; else fail "a second run left $n backups"; fi

# A line with no key name is never removed, even when a key class moves nothing.
rm -rf "$HOME/.himmel" "$HOME/.config"
printf 'HANDOVER_DIR=%s\n=orphan-line\n' "$TMP/handovers" > "$TMP/st/.env"
chmod 600 "$TMP/st/.env"
apply_tty y
envnow=$(cat "$TMP/st/.env")
lacks "HANDOVER_DIR moves without USER_SLUG" "HANDOVER_DIR=" "$envnow"
has "a move without USER_SLUG still checks the handover root" "verified: load_dotenv, load_policy, jira config reader, jira handover root, lanes resolve" "$out"
has "a line with no key name stays in .env" "=orphan-line" "$envnow"

# An env-only key (no himmel.conf reader) stays in .env and the migration still
# exits 0: it is not a key the copy moves, so verify has nothing to compare.
rm -rf "$HOME/.himmel" "$HOME/.config"
printf 'HANDOVER_DIR=%s\nJIRA_BASE_URL=https://canary.example.net\nFIRECRAWL_BASE_URL=https://fc.example.net\nWHISPER_MODEL=/models/ggml-canary.bin\n' "$TMP/handovers" > "$TMP/st/.env"
chmod 600 "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "an env-only key in .env does not fail the migration"; else fail "an env-only key in .env exited $rc: $out"; fi
envnow=$(cat "$TMP/st/.env")
has "JIRA_BASE_URL stays in .env" "JIRA_BASE_URL=https://canary.example.net" "$envnow"
has "FIRECRAWL_BASE_URL stays in .env" "FIRECRAWL_BASE_URL=https://fc.example.net" "$envnow"
has "WHISPER_MODEL stays in .env" "WHISPER_MODEL=/models/ggml-canary.bin" "$envnow"
has "the report says an env-only key stays" "  JIRA_BASE_URL stays (env-only: no himmel.conf reader)" "$out"
lacks "an env-only key is not copied to himmel.conf" "JIRA_BASE_URL" "$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)"

# The keep-list holds secrets only: a behaviour key on it still moves.
rm -rf "$HOME/.himmel" "$HOME/.config"
mkdir -p "$HOME/.himmel"
printf 'HANDOVER_DIR\n' > "$HOME/.himmel/env-keep.txt"
printf 'HANDOVER_DIR=%s\nUSER_SLUG=%s\n' "$TMP/handovers" "$(canary slug)" > "$TMP/st/.env"
chmod 600 "$TMP/st/.env"
apply_tty y
envnow=$(cat "$TMP/st/.env")
lacks "a behaviour key on the keep-list still moves" "HANDOVER_DIR=" "$envnow"
lacks "the keep-list does not split the behaviour keys" "MISMATCH" "$out"

# A symlinked .env stays a link, and the rewrite leaves no temporary file.
rm -rf "$HOME/.himmel" "$HOME/.config"
printf 'HANDOVER_DIR=%s\nKEEP_LINE=1\n' "$TMP/handovers" > "$TMP/st/env.target"
chmod 600 "$TMP/st/env.target"
rm -f "$TMP/st/.env"
ln -s "$TMP/st/env.target" "$TMP/st/.env"
apply_tty y
if [ -L "$TMP/st/.env" ]; then pass "a symlinked .env stays a link"; else fail "the symlinked .env was replaced by a file"; fi
lacks "the link's target lost the moved line" "HANDOVER_DIR=" "$(cat "$TMP/st/env.target")"
n=$(find "$TMP/st" -name '.env.migrate.*' | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then pass "the rewrite leaves no temporary file"; else fail "the rewrite left $n temporary files"; fi
rm -f "$TMP/st/.env"

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
apply_tty y
if [ "$rc" != 0 ]; then pass "a .env-only reader fails the migration"; else fail "a .env-only reader passed verify"; fi
has "the failing reader and key are named" "MISMATCH HANDOVER_DIR (jira handover root)" "$out"
has "the user is told no line was removed" "no lines were removed from .env" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the failed verify leaves .env untouched"; else fail "the failed verify changed .env"; fi
no_canary "the failed verify prints no value" "$out"
# A reader that throws both times proves nothing and aborts too.
fixture_env
printf '%s\n' 'export function behaviourKey() { throw new Error("broken"); }' \
    'export function handoverRoot() { throw new Error("broken"); }' > "$FX/scripts/jira/dist/handover-root.js"
apply_tty y
has "a reader that throws fails the migration" "MISMATCH HANDOVER_DIR (jira handover root, the reader threw)" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "a throwing reader leaves .env untouched"; else fail "a throwing reader changed .env"; fi
# An unbuilt Jira CLI cannot be checked, so the move stops rather than skip it.
fixture_env
rm -f "$FX/scripts/jira/dist/handover-root.js"
apply_tty y
if [ "$rc" != 0 ]; then pass "an unbuilt Jira reader fails the migration"; else fail "an unbuilt Jira reader was skipped"; fi
has "the missing reader is named" "verify: the Jira CLI is not built" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "an unbuilt Jira reader leaves .env untouched"; else fail "an unbuilt Jira reader changed .env"; fi
cp "$TMP/handover-root.good.js" "$FX/scripts/jira/dist/handover-root.js"

# --- 4. A policy value that would change aborts ---
fixture_env
printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n' > "$HOME/.himmel/config.json"
apply_tty y
if [ "$rc" != 0 ]; then pass "a policy value that would change aborts"; else fail "a policy change from 1 to 0 passed"; fi
has "the changed policy key is named" "MISMATCH CR_REQUIRE_CROSS_MODEL (load_policy)" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the policy abort leaves .env untouched"; else fail "the policy abort changed .env"; fi

# --- 5. A policy value lost by the reader aborts ---
fixture_env
cp "$FX/scripts/lib/load-dotenv.sh" "$TMP/load-dotenv.good.sh"
sed 's/out += key + "=" + s + "\\n";//' "$TMP/load-dotenv.good.sh" > "$FX/scripts/lib/load-dotenv.sh"
apply_tty y
if [ "$rc" != 0 ]; then pass "a policy value missing after the move aborts"; else fail "a lost policy value passed"; fi
has "the lost policy key is named" "MISMATCH CR_REQUIRE_CROSS_MODEL (load_policy)" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "the lost-policy abort leaves .env untouched"; else fail "the lost-policy abort changed .env"; fi
cp "$TMP/load-dotenv.good.sh" "$FX/scripts/lib/load-dotenv.sh"

# --- 6. Inside an agent session the apply refuses, even at a terminal ---
fixture_env
rm -rf "$HOME/.himmel"
apply_tty y "CLAUDECODE=1 "
if [ "$rc" = 3 ]; then pass "an agent session cannot apply (exit 3)"; else fail "an agent session apply exited $rc"; fi
has "the refusal names the agent session" "an agent session cannot write ~/.himmel/config.json" "$out"
has "the refusal names the operator command" "bash $SCRIPT" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig" && [ ! -e "$HOME/.himmel" ]; then pass "the refusal writes nothing"; else fail "the refusal wrote something"; fi

# --- 7. The update's step: a dry run first, then apply only on a typed yes ---
fixture_env
cp -p "$TMP/st/.env" "$FX/.env"
awk '/^run_env_migration\(\) \{/,/^\}$/' "$REPO/scripts/himmel-update.sh" > "$TMP/run-env-migration.sh"
# shellcheck disable=SC2016 # expanded by the driver shell
printf 'ROOT=%q; . %q; STATUS_env_migration=""; run_env_migration "$1"; echo "rc=$? status=$STATUS_env_migration"\n' \
    "$FX" "$TMP/run-env-migration.sh" > "$TMP/update-step.sh"
out=$(bash "$TMP/update-step.sh" check 2>&1)
has "the update check marks the migration pending" "rc=0 status=pending" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "the update check writes nothing"; else fail "the update check changed .env"; fi
out=$(printf 'y\n' | bash "$TMP/update-step.sh" apply 2>&1)
has "the update prints the plan before it asks" "  HANDOVER_DIR → ~/.himmel/himmel.conf" "$out"
has "with no terminal the update does not apply" "rc=0 status=pending" "$out"
has "with no terminal the update names the apply command" "bash $FX/scripts/setup/migrate-env.sh --env $FX/.env" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "with no terminal the update writes nothing"; else fail "a run with no terminal changed .env"; fi
step=$(printf 'bash %q apply' "$TMP/update-step.sh")
at_tty y "CLAUDECODE=1 $step"
has "an agent session at a terminal never applies" "rc=0 status=pending" "$out"
has "the agent-session refusal is the one that fired" "an agent session cannot write ~/.himmel/config.json" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "an agent session at a terminal writes nothing"; else fail "an agent session at a terminal changed .env"; fi
at_tty n "$step"
has "a no at the prompt skips the move" "rc=0 status=pending" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "a no at the prompt writes nothing"; else fail "a no at the prompt changed .env"; fi
at_tty y "$step"
has "the update asks before it moves" "Move these keys now (backup first)? [y/N]" "$out"
has "a yes at the prompt applies and reports" "rc=0 status=updated" "$out"
lacks "the confirmed apply moved HANDOVER_DIR out of .env" "HANDOVER_DIR=" "$(cat "$FX/.env")"
no_canary "the update step prints no value" "$out"

# --- 7b. An operator-set consent finishes the move unattended ---
# ENV_MIGRATION_CONSENT in the policy file, and only there, stands in for the y.
consent_fixture() {  # <policy json>: the update-step fixture plus a policy file
    fixture_env
    cp -p "$TMP/st/.env" "$FX/.env"
    printf '%s\n' "$1" > "$HOME/.himmel/config.json"
}
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
out=$(CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
has "(a) consent applies with no terminal, in an agent session" "rc=0 status=updated" "$out"
has "(a) the consented apply still verifies" "verified: load_dotenv" "$out"
lacks "(a) the consented apply moved HANDOVER_DIR out of .env" "HANDOVER_DIR=" "$(cat "$FX/.env")"
if ls "$HOME/.himmel/env-backups/env."* >/dev/null 2>&1; then pass "(a) the consented apply took the backup"; else fail "(a) the consented apply took no backup"; fi
no_canary "(a) the consented apply prints no value" "$out"
has "(a) a gate-policy key stays in .env under consent" "CR_REQUIRE_CROSS_MODEL=1" "$(cat "$FX/.env")"
lacks "(a) the consent writes no gate-policy key" "CR_REQUIRE_CROSS_MODEL" "$(cat "$HOME/.himmel/config.json")"
has "(a) the report names the policy key that stays" "these stay in .env: CR_REQUIRE_CROSS_MODEL" "$out"

# An agent that plants a gate-policy key in .env cannot have the consent write it.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
printf 'ARMAUTOMERGE=1\n' >> "$FX/.env"
out=$(CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
lacks "a planted policy key never reaches config.json under consent" "ARMAUTOMERGE" "$(cat "$HOME/.himmel/config.json")"
has "a planted policy key stays in .env" "ARMAUTOMERGE=1" "$(cat "$FX/.env")"

# Nor can it point the consent at a .env of its own making.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
printf 'ARMAUTOMERGE=1\nCR_FLOOR_FALLBACK=claude-only\nUSER_SLUG=%s\n' "$(canary agent)" > "$TMP/agent.env"
cp -p "$TMP/agent.env" "$TMP/agent.orig"
cp -p "$HOME/.himmel/config.json" "$TMP/consent.orig"
out=$(CLAUDECODE=1 bash "$SCRIPT" --env "$TMP/agent.env" < /dev/null 2>&1); rc=$?
if [ "$rc" = 3 ]; then pass "the consent refuses a --env other than the checkout's (exit 3)"; else fail "a consented --env elsewhere exited $rc"; fi
has "the refusal names the checkout's .env" "the consent covers only this checkout's .env" "$out"
if cmp -s "$HOME/.himmel/config.json" "$TMP/consent.orig" && cmp -s "$TMP/agent.env" "$TMP/agent.orig" \
    && [ ! -e "$HOME/.himmel/himmel.conf" ] && [ ! -e "$HOME/.himmel/env-backups" ]; then
    pass "a consented --env elsewhere writes nothing"
else
    fail "a consented --env elsewhere wrote something"
fi

# Nor move the backup and the moved lines out of the account's own ~/.himmel.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
out=$(HIMMEL_CONFIG_DIR="$TMP/elsewhere" CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
has "the consent refuses a config dir outside the account's ~/.himmel" "rc=0 status=pending" "$out"
has "the refusal names the moved home" "HOME or HIMMEL_CONFIG_DIR points elsewhere" "$out"
if [ ! -e "$TMP/elsewhere" ] && cmp -s "$FX/.env" "$TMP/st.orig"; then
    pass "a consented move to another config dir writes nothing"
else
    fail "a consented move to another config dir wrote something"
fi

# A mismatch stops under consent, and a piped answer cannot settle it.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
hconf=$(canary hconf)
printf 'USER_SLUG=%s\n' "$hconf" > "$HOME/.himmel/himmel.conf"
out=$(printf 'e\n' | CLAUDECODE=1 bash "$TMP/update-step.sh" apply 2>&1)
has "a mismatch still stops under consent" "rc=1 status=failed" "$out"
has "the consented mismatch names the key" "MISMATCH USER_SLUG (load_dotenv)" "$out"
# shellcheck disable=SC2088 # the report prints the tilde as written
has "the consented mismatch names both sides" "USER_SLUG: $FX/.env  vs  ~/.himmel/himmel.conf" "$out"
has "the consented mismatch names the operator command" "the consent does not settle a difference" "$out"
if [ "$(sed -n 's/^USER_SLUG=//p' "$HOME/.himmel/himmel.conf")" = "$hconf" ]; then
    pass "a piped e cannot overwrite the operator's value"
else
    fail "a piped e overwrote the operator's value"
fi
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "the consented mismatch leaves .env untouched"; else fail "the consented mismatch changed .env"; fi
no_canary "the consented mismatch prints no value" "$out"

consent_fixture '{"version":1,"policy":{}}'
printf 'ENV_MIGRATION_CONSENT=1\n' >> "$FX/.env"
cp -p "$FX/.env" "$TMP/fx.orig"
out=$(ENV_MIGRATION_CONSENT=1 CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
has "(b) consent only in the env and .env applies nothing" "rc=0 status=pending" "$out"
if cmp -s "$FX/.env" "$TMP/fx.orig" && [ ! -e "$HOME/.himmel/env-backups" ]; then
    pass "(b) consent only in the env and .env writes nothing"
else
    fail "(b) consent only in the env and .env wrote something"
fi

fixture_env
cp -p "$TMP/st/.env" "$FX/.env"
out=$(bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
has "(c) with no consent the update stays pending" "rc=0 status=pending" "$out"
has "(c) with no consent the update names the apply command" "bash $FX/scripts/setup/migrate-env.sh --env $FX/.env" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "(c) with no consent nothing is written"; else fail "(c) with no consent .env changed"; fi

# --- 8. A .env vs ~/.himmel mismatch is resolved with the operator ---
env_val() { sed -n "s/^$1=//p" "$TMP/st.orig"; }   # the fixture .env's value of a key
conf_fixture() {  # a himmel.conf that disagrees with .env on USER_SLUG
    fixture_env
    hconf=$(canary hconf)
    printf 'USER_SLUG=%s\n' "$hconf" > "$HOME/.himmel/himmel.conf"
}
slug_read() {  # the value the shell reader returns for USER_SLUG with .env no longer holding it
    ( unset USER_SLUG; cd "$FX" && . "$FX/scripts/lib/load-dotenv.sh" && load_dotenv --root "$TMP/st" USER_SLUG; printf '%s' "${USER_SLUG-}" ) 2>/dev/null
}
conf_fixture
apply_tty $'y\ne'
if [ "$rc" = 0 ]; then pass "keeping .env on a mismatch applies (exit 0)"; else fail "keeping .env on a mismatch exited $rc: $out"; fi
has "a mismatch names the key" "USER_SLUG" "$out"
has "a mismatch names the .env side" "$TMP/st/.env" "$out"
# shellcheck disable=SC2088 # the report prints the tilde as written
has "a mismatch names the ~/.himmel side" "~/.himmel/himmel.conf" "$out"
no_canary "a mismatch prints no value" "$out"
if [ "$(slug_read)" = "$(env_val USER_SLUG)" ]; then pass "keep .env: the reader returns the .env value"; else fail "keep .env: the reader returned another value"; fi
lacks "keep .env: the line left .env" "USER_SLUG=" "$(cat "$TMP/st/.env")"
has "keep .env: the re-verify ran and passed" "verified: load_dotenv" "$out"
conf_fixture
apply_tty $'y\nh'
if [ "$rc" = 0 ]; then pass "keeping ~/.himmel on a mismatch applies (exit 0)"; else fail "keeping ~/.himmel on a mismatch exited $rc: $out"; fi
if [ "$(slug_read)" = "$hconf" ]; then pass "keep ~/.himmel: the reader returns the ~/.himmel value"; else fail "keep ~/.himmel: the reader returned another value"; fi
lacks "keep ~/.himmel: the line left .env" "USER_SLUG=" "$(cat "$TMP/st/.env")"
has "keep ~/.himmel: the re-verify ran and passed" "verified: load_dotenv" "$out"
no_canary "a kept choice prints no value" "$out"
for answer in $'y' $'y\nx'; do
    conf_fixture
    apply_tty "$answer"
    if [ "$rc" != 0 ]; then pass "no choice on a mismatch does not apply"; else fail "no choice on a mismatch exited 0"; fi
    if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "no choice on a mismatch leaves every .env line"; else fail "no choice on a mismatch changed .env"; fi
    has "no choice on a mismatch names the key" "USER_SLUG" "$out"
done
# A gate-policy key resolves the same way, in config.json.
policy_val() { node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.CR_REQUIRE_CROSS_MODEL))' "$HOME/.himmel/config.json" 2>/dev/null; }
fixture_env
printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n' > "$HOME/.himmel/config.json"
apply_tty $'y\ne'
if [ "$rc" = 0 ] && [ "$(policy_val)" = 1 ]; then pass "keep .env: the policy value becomes the .env value"; else fail "keep .env on a policy mismatch: rc $rc, policy '$(policy_val)'"; fi
# shellcheck disable=SC2088 # the report prints the tilde as written
has "a policy mismatch names the config.json side" "~/.himmel/config.json" "$out"
fixture_env
printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n' > "$HOME/.himmel/config.json"
apply_tty $'y\nh'
if [ "$rc" = 0 ] && [ "$(policy_val)" = 0 ]; then pass "keep ~/.himmel: the policy value stays"; else fail "keep ~/.himmel on a policy mismatch: rc $rc, policy '$(policy_val)'"; fi
lacks "keep ~/.himmel: the policy line left .env" "CR_REQUIRE_CROSS_MODEL=" "$(cat "$TMP/st/.env")"
# A kept policy value with a space and a hash survives the dotenv copy it is checked through.
fixture_env
printf '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"a # b"}}\n' > "$HOME/.himmel/config.json"
apply_tty $'y\nh'
if [ "$rc" = 0 ] && [ "$(policy_val)" = "a # b" ]; then pass "keep ~/.himmel: a policy value with a hash is kept whole"; else fail "keep ~/.himmel on a policy value with a hash: rc $rc, policy '$(policy_val)'"; fi
lacks "keep ~/.himmel: a policy value with a hash left .env" "CR_REQUIRE_CROSS_MODEL=" "$(cat "$TMP/st/.env")"
# A chosen side still has to pass the readers: a held key whose handover root
# is read from .env only fails the re-verify whichever side is kept, and .env
# stays whole. The faulty reader is the real one with only that lookup changed.
if ! sed "s/const resolved = behaviourKey('HANDOVER_DIR', env, dotenvPath);/const resolved = readDotenvKey(dotenvPath ?? join(primaryCheckout(), '.env'), 'HANDOVER_DIR');/" \
    "$TMP/handover-root.good.js" > "$TMP/handover-root.envonly.js" \
    || [ ! -s "$TMP/handover-root.envonly.js" ] \
    || cmp -s "$TMP/handover-root.good.js" "$TMP/handover-root.envonly.js"; then
    fail "the .env-only handover root fixture was not built"
fi
for answer in e h; do
    fixture_env
    # The release-state reader follows the handover root, so USER_SLUG is held too.
    printf 'HANDOVER_DIR=%s\nUSER_SLUG=%s\n' "$TMP/other" "$(canary slug)" > "$HOME/.himmel/himmel.conf"
    cp "$TMP/handover-root.envonly.js" "$FX/scripts/jira/dist/handover-root.js"
    apply_tty "y"$'\n'"$answer"$'\n'"$answer"
    if [ "$rc" != 0 ]; then pass "keep $answer with a faulty reader does not apply"; else fail "keep $answer with a faulty reader exited 0"; fi
    if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "keep $answer with a faulty reader leaves .env untouched"; else fail "keep $answer with a faulty reader changed .env"; fi
    has "keep $answer with a faulty reader says the verify failed" "verify failed" "$out"
done
cp "$TMP/handover-root.good.js" "$FX/scripts/jira/dist/handover-root.js"
# Keeping .env rewrites himmel.conf as a whole file beside it (a new inode), and
# a symlinked himmel.conf stays a link to its updated target.
conf_fixture
# shellcheck disable=SC2012 # an inode number from a fixed path
ino_before=$(ls -i "$HOME/.himmel/himmel.conf" | awk '{print $1}')
apply_tty $'y\ne'
# shellcheck disable=SC2012 # an inode number from a fixed path
ino_after=$(ls -i "$HOME/.himmel/himmel.conf" | awk '{print $1}')
if [ "$rc" = 0 ] && [ "$ino_before" != "$ino_after" ]; then pass "keep .env: himmel.conf is replaced, not truncated in place"; else fail "keep .env: himmel.conf was rewritten in place (rc $rc)"; fi
n=$(find "$HOME/.himmel" -name 'himmel.conf.migrate.*' | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then pass "keep .env: the himmel.conf rewrite leaves no temporary file"; else fail "keep .env: the himmel.conf rewrite left $n temporary files"; fi
conf_fixture
mv "$HOME/.himmel/himmel.conf" "$TMP/himmel.conf.target"
ln -s "$TMP/himmel.conf.target" "$HOME/.himmel/himmel.conf"
# shellcheck disable=SC2012 # an inode number from a fixed path
ino_before=$(ls -i "$TMP/himmel.conf.target" | awk '{print $1}')
apply_tty $'y\ne'
# shellcheck disable=SC2012 # an inode number from a fixed path
ino_after=$(ls -i "$TMP/himmel.conf.target" | awk '{print $1}')
if [ -L "$HOME/.himmel/himmel.conf" ] && grep -q "^USER_SLUG=$(env_val USER_SLUG)\$" "$TMP/himmel.conf.target"; then pass "keep .env: a symlinked himmel.conf stays a link to the updated target"; else fail "keep .env: a symlinked himmel.conf was not updated through the link (rc $rc)"; fi
if [ "$ino_before" != "$ino_after" ]; then pass "keep .env: the symlink target is replaced, not truncated in place"; else fail "keep .env: the symlink target was rewritten in place"; fi
n=$(find "$TMP" -name 'himmel.conf.target.migrate.*' | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then pass "keep .env: the symlink rewrite leaves no temporary file"; else fail "keep .env: the symlink rewrite left $n temporary files"; fi
rm -f "$HOME/.himmel/himmel.conf" "$TMP/himmel.conf.target"

# --- 9. The report says the secrets stay in .env and never advises emptying it ---
fixture_env
apply_tty y
has "the report says the secrets stay in .env" "secrets stay in .env: READ_SECRET KEEP_ME" "$out"
lacks "the report never advises emptying .env" "empty" "$out"
lacks "the report never advises deleting .env lines" "Delete" "$out"
fixture_env
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "the dry run says the secrets stay in .env" "secrets stay in .env: READ_SECRET KEEP_ME" "$out"

if [ "$FAILED" -gt 0 ]; then
    echo "test-migrate-env: $FAILED FAILED"
    exit 1
fi
echo "test-migrate-env: all passed"
