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
# A fixture write that fails fails the suite: a missing fixture would let the absence rows pass vacuously.
# shellcheck disable=SC2059 # the format is the caller's
fxput() { local f=$1 fmt=$2; shift 2; printf -- "$fmt" "$@" > "$f" || fail "fixture write to $f failed"; }
# shellcheck disable=SC2059 # the format is the caller's
fxadd() { local f=$1 fmt=$2; shift 2; printf -- "$fmt" "$@" >> "$f" || fail "fixture append to $f failed"; }
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
# No row reaches a real keyring: the stub secret-tool and busctl come first on PATH.
# shellcheck source=../lib/fixtures/keyring-stub.sh
. "$REPO/scripts/lib/fixtures/keyring-stub.sh"
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
  printf 'NOT_READ_BY_HIMMEL_ZZQ=%s\n' "$(canary unread)"; } > "$TMP/real/.env" || fail "fixture write to $TMP/real/.env failed"
cp "$TMP/real/.env" "$TMP/real.orig"
out=$(bash "$REPO/scripts/setup/migrate-env.sh" --dry-run --env "$TMP/real/.env" 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "real-template dry run exits 0"; else fail "real-template dry run exited $rc"; fi
missing=""
for k in $names NOT_READ_BY_HIMMEL_ZZQ; do
    case "$out" in *$'\n'"  $k "*) ;; *) missing="$missing $k" ;; esac
done
if [ -z "$missing" ]; then pass "the report lists every .env key"; else fail "the report misses:$missing"; fi
has "a behaviour key goes to himmel.conf" "  HANDOVER_DIR  config  → ~/.himmel/himmel.conf" "$out"
has "a policy key goes to config.json" "  CR_REQUIRE_CROSS_MODEL  config (policy)  → ~/.himmel/config.json .policy" "$out"
has "a secret goes to the keyring" "  JIRA_API_TOKEN  secret  → keyring" "$out"
has "a key that is not himmel's stays" "  NOT_READ_BY_HIMMEL_ZZQ  unrelated  stays (not himmel's, left in place)" "$out"
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
if ! mkdir -p "$FX/scripts/himmelctl/lib" || ! cp "$REPO/scripts/himmelctl/lib/config-keys.json" "$FX/scripts/himmelctl/lib/"; then
    fail "fixture copy of config-keys.json failed"
fi
# The real resolver and its guard, over a fixture manifest naming the fixture secrets.
cp "$REPO/scripts/lib/himmel-secrets" "$REPO/scripts/lib/test-run-guard" "$REPO/scripts/lib/config-audit.sh" "$FX/scripts/lib/"
fxput "$FX/scripts/himmelctl/lib/secrets-manifest.json" '{\n  "name": "READ_SECRET",\n  "name": "UNREAD_SECRET",\n  "name": "KEEP_ME",\n  "name": "JIRA_API_TOKEN",\n  "name": "BITBUCKET_API_TOKEN"\n}\n'
fxput "$FX/.env.example" '# READ_SECRET=\nUNREAD_SECRET=\nKEEP_ME=\nJIRA_API_TOKEN=\nBITBUCKET_API_TOKEN=\n'
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
apply_tty() {  # <typed input> [<prefix>]: the apply on the station .env, at a terminal, with -y unless APPLY_ARGS is set
    # shellcheck disable=SC2086 # APPLY_ARGS is a flag list
    at_tty "$1" "${2:-}bash $(printf '%q --env %q' "$SCRIPT" "$TMP/st/.env") ${APPLY_ARGS--y}"
}
if ! strip_ts "$REPO/scripts/jira/src/handover-root.ts" "$FX/scripts/jira/dist/handover-root.js" \
    || ! strip_ts "$REPO/scripts/jira/src/release/paths.ts" "$FX/scripts/jira/dist/release/paths.js"; then
    echo "FAIL the Jira reader sources no longer strip to JavaScript"
    echo "test-migrate-env: $((FAILED + 1)) FAILED"
    exit 1
fi
fxput "$FX/scripts/jira/dist/package.json" '{"type":"module"}\n'
# shellcheck disable=SC2016 # the fixture reader names the variable literally
fxput "$FX/scripts/reads-secret.sh" 'printf %%s "$READ_SECRET"\n'
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
    kreset
    mkdir -p "$TMP/st"
    { echo "# station .env"
      echo "HANDOVER_DIR=$TMP/handovers"
      echo "USER_SLUG=$(canary slug)"
      echo "CR_PROFILE=$(canary profile)"
      echo "CR_REQUIRE_CROSS_MODEL=1"
      echo "HIMMEL_FLEET_CAP=7"
      echo "READ_SECRET=$(canary read)"
      echo "UNREAD_SECRET=$(canary unread)"
      echo "BITBUCKET_API_TOKEN=$(canary bb)"
      echo "KEEP_ME=$(canary keep)"
      echo "OTHER_TOOL_TOKEN=$(canary other)"; } > "$TMP/st/.env" || fail "fixture write to $TMP/st/.env failed"
    chmod 600 "$TMP/st/.env"
    cp -p "$TMP/st/.env" "$TMP/st.orig"
    mkdir -p "$HOME/.himmel"
    fxput "$HOME/.himmel/env-keep.txt" '# station-ops reads this one\nKEEP_ME\n'
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
# R7c: at a terminal without -y a typed y is never read: the apply refuses (OS-1).
for answer in y n ""; do
    fixture_env
    APPLY_ARGS="" apply_tty "$answer"
    if [ "$rc" = 3 ]; then pass "R7c without -y the typed '$answer' is not read (exit 3)"; else fail "R7c without -y the typed '$answer' exited $rc"; fi
    has "R7c the refusal says to rerun with -y" "nothing written; rerun with -y" "$out"
    lacks "R7c the apply no longer asks" "[y/N]" "$out"
    has "R7c the refusal names the operator command with -y" "bash $SCRIPT --env $TMP/st/.env -y" "$out"
    if cmp -s "$TMP/st/.env" "$TMP/st.orig" && [ ! -e "$HOME/.himmel/env-backups" ]; then
        pass "R7c without -y (typed '$answer') .env stays byte-identical"
    else
        fail "R7c without -y (typed '$answer') changed something"
    fi
done

# --- 2. A clean apply moves every key, backs up first, and verifies ---
fixture_env
apply_tty y
if [ "$rc" = 0 ]; then pass "apply exits 0"; else fail "apply exited $rc: $out"; fi
no_canary "apply prints no value" "$out"
# The prompt ends its line only when the answer is typed, so match mid-line.
backup=$(printf '%s\n' "$out" | sed -n 's/.*backup: \(\/.*\) (mode 600)$/\1/p')
grep -v -E '^(READ_SECRET|UNREAD_SECRET|KEEP_ME|BITBUCKET_API_TOKEN)=' "$TMP/st.orig" > "$TMP/st.scrubbed"
if [ -n "$backup" ] && cmp -s "$backup" "$TMP/st.scrubbed"; then pass "the backup holds the original .env but for the secret lines"; else fail "no backup matching the original .env less its secrets (path '$backup')"; fi
if [ -n "$backup" ] && [ "$(mode_of "$backup")" = 600 ]; then pass "the backup is mode 600"; else fail "the backup mode is not 600"; fi
case "$backup" in "$TMP/st/"*|"") fail "the backup is inside the checkout or missing" ;; *) pass "the backup is outside the checkout" ;; esac
lacks "the scrubbed run prints no restore command that would drop the kept secrets" "restore: cp" "$out"
has "the report says not to copy the scrubbed backup over .env" "do not copy it over $TMP/st/.env" "$out"
has "the report says the backup can be removed" "rm $backup" "$out"
conf=$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)
has "HANDOVER_DIR moved to himmel.conf" "HANDOVER_DIR=$TMP/handovers" "$conf"
has "USER_SLUG moved to himmel.conf" "USER_SLUG=CANARY-slug-" "$conf"
pol=$(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.CR_REQUIRE_CROSS_MODEL))' "$HOME/.himmel/config.json" 2>/dev/null)
if [ "$pol" = 1 ]; then pass "the policy key moved to config.json with its value"; else fail "config.json .policy.CR_REQUIRE_CROSS_MODEL is '$pol'"; fi
cap=$(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.HIMMEL_FLEET_CAP))' "$HOME/.himmel/config.json" 2>/dev/null)
if [ "$cap" = 7 ]; then pass "the legacy fleet cap moved to config.json .policy"; else fail "config.json .policy.HIMMEL_FLEET_CAP is '$cap'"; fi
store="$HOME/.config/secrets/himmel.env"
# R1: a secret leaves .env and every backup and reads back from the keyring alone.
for k in UNREAD_SECRET READ_SECRET BITBUCKET_API_TOKEN; do
    got=$("$FX/scripts/lib/himmel-secrets" get --no-dotenv "$k" 2>/dev/null)
    case "$got" in "$k=CANARY-"*) pass "R1 $k reads back from the keyring" ;; *) fail "R1 $k is not served by the keyring" ;; esac
done
if [ ! -e "$store" ]; then pass "R1 no legacy secrets file is written with a keyring"; else fail "R1 the legacy secrets file was written"; fi
envnow=$(cat "$TMP/st/.env")
for k in HANDOVER_DIR USER_SLUG CR_PROFILE CR_REQUIRE_CROSS_MODEL HIMMEL_FLEET_CAP UNREAD_SECRET READ_SECRET BITBUCKET_API_TOKEN; do
    lacks "$k removed from .env" "$k=" "$envnow"
done
# R1/R4/R5(I5): the backup of this run holds no manifest-secret line, not even the env-keep one.
bk=$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)
for k in UNREAD_SECRET READ_SECRET BITBUCKET_API_TOKEN KEEP_ME; do
    lacks "R1 the backup lost the $k line" "$k=" "$bk"
done
has "R1 the backup keeps a config line" "HIMMEL_FLEET_CAP=7" "$bk"
# R3: no value reaches the stub's argv log.
lacks "R3 the keyring stub's argv log holds no value" "CANARY-" "$(cat "$KSTUB_LOG")"  # read-sink-ok: KSTUB_LOG is this suite's own scratch log
# R4: an unrelated key and an env-keep secret stay in .env byte for byte.
has "R4 an env-keep secret stays byte-identical" "$(grep '^KEEP_ME=' "$TMP/st.orig")" "$envnow"
has "R4 an unrelated key stays byte-identical" "$(grep '^OTHER_TOOL_TOKEN=' "$TMP/st.orig")" "$envnow"
has "a keep-list key stays in .env" "KEEP_ME=CANARY-keep-" "$envnow"
has "comments stay in .env" "# station .env" "$envnow"
if [ "$(mode_of "$TMP/st/.env")" = 600 ]; then pass ".env keeps its mode"; else fail ".env mode changed"; fi
has "the report shows the keep-list reason" "  KEEP_ME  secret  kept (env-keep)" "$out"
has "the report leaves a key that is not himmel's" "  OTHER_TOOL_TOKEN  unrelated  stays (not himmel's, left in place)" "$out"
has "the report names the stored secrets" "stored UNREAD_SECRET" "$out"
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
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s\n=orphan-line\n' "$TMP/handovers"
chmod 600 "$TMP/st/.env"
apply_tty y
envnow=$(cat "$TMP/st/.env")
lacks "HANDOVER_DIR moves without USER_SLUG" "HANDOVER_DIR=" "$envnow"
has "a move without USER_SLUG still checks the handover root" "verified: load_dotenv, load_policy, jira config reader, jira handover root, lanes resolve" "$out"
has "a line with no key name stays in .env" "=orphan-line" "$envnow"

# The Jira URL moves and verifies through every reader; the remaining env-only
# settings stay in .env.
rm -rf "$HOME/.himmel" "$HOME/.config"
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s\nJIRA_BASE_URL=https://canary.example.net\nFIRECRAWL_BASE_URL=https://fc.example.net\nWHISPER_MODEL=/models/ggml-canary.bin\n' "$TMP/handovers"
chmod 600 "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "the Jira URL migrates without a reader mismatch"; else fail "the Jira URL migration exited $rc: $out"; fi
envnow=$(cat "$TMP/st/.env")
lacks "JIRA_BASE_URL leaves .env after verification" "JIRA_BASE_URL=" "$envnow"
has "JIRA_BASE_URL reaches himmel.conf" "JIRA_BASE_URL=https://canary.example.net" "$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)"
has "FIRECRAWL_BASE_URL stays in .env" "FIRECRAWL_BASE_URL=https://fc.example.net" "$envnow"
has "WHISPER_MODEL stays in .env" "WHISPER_MODEL=/models/ggml-canary.bin" "$envnow"
has "the report says a remaining env-only key stays" "  FIRECRAWL_BASE_URL  config  stays (env-only: no himmel.conf reader)" "$out"
lacks "a remaining env-only key is not copied to himmel.conf" "FIRECRAWL_BASE_URL" "$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)"

# The chat ids are config keys himmel.conf serves: the move succeeds and the .env lines go.
rm -rf "$HOME/.himmel" "$HOME/.config"
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s\nTELEGRAM_CHAT_ID=1234567\nTELEGRAM_GROUP_CHAT_ID=-100987654\n' "$TMP/handovers"
chmod 600 "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "the chat ids move without a lanes mismatch"; else fail "the chat ids exited $rc: $out"; fi
envnow=$(cat "$TMP/st/.env")
lacks "TELEGRAM_CHAT_ID leaves .env" "TELEGRAM_CHAT_ID=" "$envnow"
lacks "TELEGRAM_GROUP_CHAT_ID leaves .env" "TELEGRAM_GROUP_CHAT_ID=" "$envnow"

# Every config key moves, whether or not the lanes resolver once kept it on a short list of its own.
rm -rf "$HOME/.himmel" "$HOME/.config"
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s\nJIRA_EMAIL=ops@example.net\nSNYK_ORG_ID=canary-org\n' "$TMP/handovers"
chmod 600 "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "JIRA_EMAIL migrates without a lanes mismatch"; else fail "JIRA_EMAIL exited $rc: $out"; fi
lacks "JIRA_EMAIL raises no mismatch" "MISMATCH" "$out"
envnow=$(cat "$TMP/st/.env")
lacks "JIRA_EMAIL leaves .env" "JIRA_EMAIL=" "$envnow"
lacks "SNYK_ORG_ID leaves .env" "SNYK_ORG_ID=" "$envnow"
has "JIRA_EMAIL reaches himmel.conf" "JIRA_EMAIL=ops@example.net" "$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)"

# A key whose line has an inline comment stays: the loader drops the comment and the
# node readers keep it, so a move would change what they read.
rm -rf "$HOME/.himmel" "$HOME/.config"
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s # archive\nTELEGRAM_CHAT_ID=1234567 # note\nJIRA_EMAIL=ops@example.net\n' "$TMP/handovers"
chmod 600 "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "a plain key still moves beside commented ones"; else fail "the commented-line run exited $rc: $out"; fi
envnow=$(cat "$TMP/st/.env")
has "a commented HANDOVER_DIR stays in .env" "HANDOVER_DIR=$TMP/handovers # archive" "$envnow"
has "a commented chat id stays in .env" "TELEGRAM_CHAT_ID=1234567 # note" "$envnow"
has "the report names the commented key" "  HANDOVER_DIR  config  stays (its .env line has an inline comment" "$out"
lacks "a commented key is not copied to himmel.conf" "HANDOVER_DIR" "$(cat "$HOME/.himmel/himmel.conf" 2>/dev/null)"
lacks "the plain key leaves .env" "JIRA_EMAIL=" "$envnow"

# The keep-list holds secrets only: a behaviour key on it still moves.
rm -rf "$HOME/.himmel" "$HOME/.config"
mkdir -p "$HOME/.himmel"
fxput "$HOME/.himmel/env-keep.txt" 'HANDOVER_DIR\n'
fxput "$TMP/st/.env" 'HANDOVER_DIR=%s\nUSER_SLUG=%s\n' "$TMP/handovers" "$(canary slug)"
chmod 600 "$TMP/st/.env"
apply_tty y
envnow=$(cat "$TMP/st/.env")
lacks "a behaviour key on the keep-list still moves" "HANDOVER_DIR=" "$envnow"
lacks "the keep-list does not split the behaviour keys" "MISMATCH" "$out"

# A symlinked .env stays a link, and the rewrite leaves no temporary file.
rm -rf "$HOME/.himmel" "$HOME/.config"
fxput "$TMP/st/env.target" 'HANDOVER_DIR=%s\nKEEP_LINE=1\n' "$TMP/handovers"
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
# Once the reader is fixed, the same .env migrates on the next run.
cp "$TMP/handover-root.good.js" "$FX/scripts/jira/dist/handover-root.js"
apply_tty y
if [ "$rc" = 0 ]; then pass "a run after a failed verify ends 0 once the reader is fixed"; else fail "the run after a failed verify exited $rc: $out"; fi
lacks "the run after a failed verify moved HANDOVER_DIR out of .env" "HANDOVER_DIR=" "$(cat "$TMP/st/.env")"
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
fxput "$HOME/.himmel/config.json" '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n'
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
has "the update prints the plan before it asks" "  HANDOVER_DIR  config  → ~/.himmel/himmel.conf" "$out"
has "with no terminal the update does not apply" "rc=0 status=pending" "$out"
has "with no terminal the update names the apply command" "bash $FX/scripts/setup/migrate-env.sh --env $FX/.env" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "with no terminal the update writes nothing"; else fail "a run with no terminal changed .env"; fi
step=$(printf 'bash %q apply' "$TMP/update-step.sh")
at_tty y "CLAUDECODE=1 $step"
has "an agent session at a terminal never applies" "rc=0 status=pending" "$out"
has "the agent-session refusal is the one that fired" "an agent session cannot write ~/.himmel/config.json" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "an agent session at a terminal writes nothing"; else fail "an agent session at a terminal changed .env"; fi
at_tty y "$step"
has "the update never passes -y, so a terminal apply stays pending" "rc=0 status=pending" "$out"
has "the update step names the -y rerun" "nothing written; rerun with -y" "$out"
has "the update step names the apply command with -y" "bash $FX/scripts/setup/migrate-env.sh --env $FX/.env -y" "$out"
lacks "the update no longer asks y/N" "[y/N]" "$out"
if cmp -s "$FX/.env" "$TMP/st.orig"; then pass "a terminal apply without -y writes nothing"; else fail "a terminal apply without -y changed .env"; fi
no_canary "the update step prints no value" "$out"

# R11: migrate-env exiting 4 (incomplete: no keyring backend) is the update's `incomplete`, not `failed`.
mkdir -p "$TMP/r11/scripts/setup"
cat > "$TMP/r11/scripts/setup/migrate-env.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--dry-run*) echo "dry run: nothing written."; exit 0 ;; esac
exit 4
EOF
: > "$TMP/r11/.env"
# shellcheck disable=SC2016 # expanded by the driver shell
printf 'ROOT=%q; . %q; STATUS_env_migration=""; run_env_migration "$1"; echo "rc=$? status=$STATUS_env_migration"\n' \
    "$TMP/r11" "$TMP/run-env-migration.sh" > "$TMP/r11-step.sh"
out=$(bash "$TMP/r11-step.sh" apply 2>&1)
has "R11 an apply that exits 4 is incomplete, and the update does not fail" "rc=0 status=incomplete" "$out"
out=$(bash "$TMP/r11-step.sh" check 2>&1)
has "R11 the dry run still maps to pending" "rc=0 status=pending" "$out"

# --- 7b. An operator-set consent finishes the move unattended ---
# ENV_MIGRATION_CONSENT in the policy file, and only there, stands in for the y.
consent_fixture() {  # <policy json>: the update-step fixture plus a policy file
    fixture_env
    cp -p "$TMP/st/.env" "$FX/.env"
    fxput "$HOME/.himmel/config.json" '%s\n' "$1"
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
fxadd "$FX/.env" 'ARMAUTOMERGE=1\n'
out=$(CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
lacks "a planted policy key never reaches config.json under consent" "ARMAUTOMERGE" "$(cat "$HOME/.himmel/config.json")"
has "a planted policy key stays in .env" "ARMAUTOMERGE=1" "$(cat "$FX/.env")"

# Nor can it point the consent at a .env of its own making.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
fxput "$TMP/agent.env" 'ARMAUTOMERGE=1\nCR_FLOOR_FALLBACK=claude-only\nUSER_SLUG=%s\n' "$(canary agent)"
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
fxput "$HOME/.himmel/himmel.conf" 'USER_SLUG=%s\n' "$hconf"
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
fxadd "$FX/.env" 'ENV_MIGRATION_CONSENT=1\n'
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
    fxput "$HOME/.himmel/himmel.conf" 'USER_SLUG=%s\n' "$hconf"
}
slug_read() {  # the value the shell reader returns for USER_SLUG with .env no longer holding it
    ( unset USER_SLUG; cd "$FX" && . "$FX/scripts/lib/load-dotenv.sh" && load_dotenv --root "$TMP/st" USER_SLUG; printf '%s' "${USER_SLUG-}" ) 2>/dev/null
}
conf_fixture
apply_tty e
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
apply_tty h
if [ "$rc" = 0 ]; then pass "keeping ~/.himmel on a mismatch applies (exit 0)"; else fail "keeping ~/.himmel on a mismatch exited $rc: $out"; fi
if [ "$(slug_read)" = "$hconf" ]; then pass "keep ~/.himmel: the reader returns the ~/.himmel value"; else fail "keep ~/.himmel: the reader returned another value"; fi
lacks "keep ~/.himmel: the line left .env" "USER_SLUG=" "$(cat "$TMP/st/.env")"
has "keep ~/.himmel: the re-verify ran and passed" "verified: load_dotenv" "$out"
no_canary "a kept choice prints no value" "$out"
for answer in "" x; do
    conf_fixture
    apply_tty "$answer"
    if [ "$rc" != 0 ]; then pass "no choice on a mismatch does not apply"; else fail "no choice on a mismatch exited 0"; fi
    if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "no choice on a mismatch leaves every .env line"; else fail "no choice on a mismatch changed .env"; fi
    has "no choice on a mismatch names the key" "USER_SLUG" "$out"
done
# A gate-policy key resolves the same way, in config.json.
policy_val() { node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}; process.stdout.write(String(p.CR_REQUIRE_CROSS_MODEL))' "$HOME/.himmel/config.json" 2>/dev/null; }
fixture_env
fxput "$HOME/.himmel/config.json" '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n'
apply_tty e
if [ "$rc" = 0 ] && [ "$(policy_val)" = 1 ]; then pass "keep .env: the policy value becomes the .env value"; else fail "keep .env on a policy mismatch: rc $rc, policy '$(policy_val)'"; fi
# shellcheck disable=SC2088 # the report prints the tilde as written
has "a policy mismatch names the config.json side" "~/.himmel/config.json" "$out"
fixture_env
fxput "$HOME/.himmel/config.json" '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n'
apply_tty h
if [ "$rc" = 0 ] && [ "$(policy_val)" = 0 ]; then pass "keep ~/.himmel: the policy value stays"; else fail "keep ~/.himmel on a policy mismatch: rc $rc, policy '$(policy_val)'"; fi
lacks "keep ~/.himmel: the policy line left .env" "CR_REQUIRE_CROSS_MODEL=" "$(cat "$TMP/st/.env")"
# A kept policy value with a space and a hash survives the dotenv copy it is checked through.
fixture_env
fxput "$HOME/.himmel/config.json" '{"version":1,"policy":{"CR_REQUIRE_CROSS_MODEL":"a # b"}}\n'
apply_tty h
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
    fxput "$HOME/.himmel/himmel.conf" 'HANDOVER_DIR=%s\nUSER_SLUG=%s\n' "$TMP/other" "$(canary slug)"
    cp "$TMP/handover-root.envonly.js" "$FX/scripts/jira/dist/handover-root.js"
    apply_tty "$answer"$'\n'"$answer"
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
apply_tty e
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
apply_tty e
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
has "the report says the env-keep secret stays in .env" "secrets stay in .env: KEEP_ME" "$out"
lacks "the report never advises emptying .env" "empty" "$out"
lacks "the report never advises deleting .env lines" "Delete" "$out"
fixture_env
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "the dry run says the env-keep secret stays in .env" "secrets stay in .env: KEEP_ME" "$out"
# R2: the dry run prints every .env key as `name  class  destination`, never a value.
has "R2 a behaviour key prints its class and destination" "  USER_SLUG  config  → ~/.himmel/himmel.conf" "$out"
has "R2 a policy key prints its class" "  CR_REQUIRE_CROSS_MODEL  config (policy)  → ~/.himmel/config.json .policy" "$out"
has "R2 a secret prints its class and the keyring" "  UNREAD_SECRET  secret  → keyring" "$out"
has "R2 an env-keep secret prints kept (env-keep)" "  KEEP_ME  secret  kept (env-keep)" "$out"
has "R2 an unrelated key prints its class" "  OTHER_TOOL_TOKEN  unrelated  stays (not himmel's, left in place)" "$out"
no_canary "R2 the dry run prints no value" "$out"

# --- 10. The secrets stage: -y, the agent and terminal checks, held, failed, concurrent ---
# R7a: an agent session with the consent and -y moves the config keys and refuses the secrets stage.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
out=$(CLAUDECODE=1 bash "$SCRIPT" --env "$FX/.env" -y < /dev/null 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "R7a the consented run exits 0"; else fail "R7a the consented run exited $rc: $out"; fi
has "R7a the secrets stage refuses inside an agent session" "migrate-env: an agent session cannot move secrets; they stay in .env" "$out"
lacks "R7a the config key moved" "HANDOVER_DIR=" "$(cat "$FX/.env")"
has "R7a the secret is still in .env" "UNREAD_SECRET=CANARY-unread-" "$(cat "$FX/.env")"
no_canary "R7a the refusal prints no value" "$out"
# R7b: the consent, -y and no terminal: config keys move, the secrets stage has its own refusal.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
out=$(bash "$SCRIPT" --env "$FX/.env" -y < /dev/null 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "R7b the consented run with no terminal exits 0"; else fail "R7b exited $rc: $out"; fi
has "R7b the secrets stage names the missing terminal" "migrate-env: no terminal to move secrets at; they stay in .env" "$out"
lacks "R7b the config key moved" "HANDOVER_DIR=" "$(cat "$FX/.env")"
has "R7b the secret is still in .env" "UNREAD_SECRET=CANARY-unread-" "$(cat "$FX/.env")"
# R7c: the consent at a terminal without -y moves the config keys and asks for -y for the secrets.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
at_tty y "bash $(printf '%q --env %q' "$SCRIPT" "$FX/.env")"
if [ "$rc" = 0 ]; then pass "R7c the consented run without -y exits 0"; else fail "R7c exited $rc: $out"; fi
has "R7c the secrets stage needs -y" "migrate-env: moving secrets needs -y; they stay in .env" "$out"
lacks "R7c the config key moved" "HANDOVER_DIR=" "$(cat "$FX/.env")"
has "R7c the typed y was not read as a yes for the secrets" "UNREAD_SECRET=CANARY-unread-" "$(cat "$FX/.env")"

# R5: a keyring that accepts a store and keeps nothing: the key stays in .env and in the backup, the run fails.
fixture_env
apply_tty "" "KSTUB_DROP_STORE=1 "
if [ "$rc" != 0 ]; then pass "R5 a dropped store fails the run"; else fail "R5 a dropped store exited 0"; fi
has "R5 the failed key is named" "failed UNREAD_SECRET" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "R5 a dropped store leaves .env untouched"; else fail "R5 a dropped store changed .env"; fi
has "R5 the backup still holds the key" "UNREAD_SECRET=CANARY-unread-" "$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)"
no_canary "R5 the failed run prints no value" "$out"

# R3b: TMPDIR is an empty fixture dir: it is empty after a good run and after a failed one.
mkdir -p "$TMP/tmpd"
fixture_env
apply_tty "" "TMPDIR=$TMP/tmpd "
if [ "$rc" = 0 ] && [ -z "$(ls -A "$TMP/tmpd")" ]; then pass "R3b a good run leaves TMPDIR empty"; else fail "R3b a good run left TMPDIR holding: $(ls -A "$TMP/tmpd") (rc $rc)"; fi
fixture_env
apply_tty "" "TMPDIR=$TMP/tmpd KSTUB_DROP_STORE=1 "
if [ "$rc" != 0 ] && [ -z "$(ls -A "$TMP/tmpd")" ]; then pass "R3b a failed run leaves TMPDIR empty"; else fail "R3b a failed run left TMPDIR holding: $(ls -A "$TMP/tmpd") (rc $rc)"; fi

# R6: an older backup holding secret lines loses them; a config line stays.
fixture_env
printf 'JIRA_API_TOKEN=dummy-r1\n' >> "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'JIRA_API_TOKEN=dummy-r1\nexport BITBUCKET_API_TOKEN=dummy-r6\nHIMMEL_FLEET_CAP=3\n' > "$HOME/.himmel/env-backups/env.20260101T000000Z.1"
chmod 600 "$HOME/.himmel/env-backups/env.20260101T000000Z.1"
apply_tty y
old=$(cat "$HOME/.himmel/env-backups/env.20260101T000000Z.1")
lacks "R6 an older backup lost the JIRA_API_TOKEN line" "JIRA_API_TOKEN" "$old"
lacks "R6 an older backup lost the exported BITBUCKET_API_TOKEN line" "BITBUCKET_API_TOKEN" "$old"
has "R6 an older backup keeps its config line" "HIMMEL_FLEET_CAP=3" "$old"
if [ "$(mode_of "$HOME/.himmel/env-backups/env.20260101T000000Z.1")" = 600 ]; then pass "R6 a scrubbed backup stays mode 600"; else fail "R6 a scrubbed backup changed mode"; fi

# R1: a dummy JIRA_API_TOKEN, migrated with -y, leaves .env and every backup.
fixture_env
printf 'JIRA_API_TOKEN=dummy-r1\n' >> "$TMP/st/.env"
apply_tty y
lacks "R1 JIRA_API_TOKEN left .env" "JIRA_API_TOKEN" "$(cat "$TMP/st/.env")"
lacks "R1 JIRA_API_TOKEN left every backup" "JIRA_API_TOKEN" "$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)"
has "R1 the keyring serves it" "JIRA_API_TOKEN=dummy-r1" "$("$FX/scripts/lib/himmel-secrets" get --no-dotenv JIRA_API_TOKEN 2>/dev/null)"

# Held is never moved: an item in the keyring with another value keeps its .env line.
fixture_env
printf 'service=himmel key=UNREAD_SECRET scope=user\tother-value\n' >> "$KSTUB_STORE"
apply_tty y
if [ "$rc" = 0 ]; then pass "a held key does not fail the run"; else fail "a held key exited $rc: $out"; fi
has "a held key is named" "held UNREAD_SECRET" "$out"
has "a held key keeps its .env line" "UNREAD_SECRET=CANARY-unread-" "$(cat "$TMP/st/.env")"
lacks "a stored key beside a held one still leaves .env" "READ_SECRET=" "$(grep -v UNREAD_SECRET "$TMP/st/.env")"

# R8: the class comes from the owner: a fixture copy that classes JIRA_API_TOKEN config moves the inventory row and destination.
cp "$FX/scripts/lib/load-dotenv.sh" "$TMP/load-dotenv.good.sh"
sed 's/^        JIRA_BASE_URL|TELEGRAM_CHAT_ID/        JIRA_API_TOKEN|JIRA_BASE_URL|TELEGRAM_CHAT_ID/' "$TMP/load-dotenv.good.sh" > "$FX/scripts/lib/load-dotenv.sh"
fixture_env
printf 'JIRA_API_TOKEN=dummy-r8\n' >> "$TMP/st/.env"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "R8 the row follows the owner's class and destination" "  JIRA_API_TOKEN  config  → ~/.himmel/himmel.conf" "$out"
cp "$TMP/load-dotenv.good.sh" "$FX/scripts/lib/load-dotenv.sh"

# R9: no keyring backend: a secret nothing reads goes to the legacy file, a WARN names the rest, the apply exits 4.
fixture_env
out=$(HIMMEL_SECRETS_KEYRING=off bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "R9 the dry run with no backend exits 0"; else fail "R9 the dry run exited $rc"; fi
has "R9 the dry run warns" "migrate-env: WARN no keyring backend" "$out"
apply_tty y "HIMMEL_SECRETS_KEYRING=off "
if [ "$rc" = 4 ]; then pass "R9 an apply with no backend exits 4"; else fail "R9 an apply with no backend exited $rc: $out"; fi
has "R9 the apply warns" "migrate-env: WARN no keyring backend" "$out"
if grep -q '^UNREAD_SECRET=CANARY-unread-' "$store" 2>/dev/null && [ "$(mode_of "$store")" = 600 ]; then pass "R9 the unread secret went to the mode-600 legacy file"; else fail "R9 the unread secret is not in the legacy file"; fi
has "R9 a secret something reads stays in .env" "READ_SECRET=CANARY-read-" "$(cat "$TMP/st/.env")"
lacks "R9 the legacy-file secret left .env" "UNREAD_SECRET=" "$(cat "$TMP/st/.env")"
lacks "R9 nothing reached the keyring stub" "secret-tool store" "$(cat "$KSTUB_LOG")"  # read-sink-ok: KSTUB_LOG is this suite's own scratch log
has "R9 the backup is not scrubbed without a keyring" "READ_SECRET=CANARY-read-" "$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)"

# R9b: no keyring and every secret has a reader: nothing moves, and the apply is still incomplete (exit 4).
fixture_env
grep -v -E '^(HANDOVER_DIR=|USER_SLUG=|CR_|HIMMEL_FLEET_CAP=|UNREAD_SECRET=|BITBUCKET_API_TOKEN=)' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
cp "$TMP/st/.env" "$TMP/st.r9b"
apply_tty y "HIMMEL_SECRETS_KEYRING=off "
has "R9b nothing moves" "nothing to move" "$out"
if [ "$rc" = 4 ]; then pass "R9b an apply that moves nothing with no backend exits 4"; else fail "R9b an apply that moves nothing with no backend exited $rc: $out"; fi
if cmp -s "$TMP/st/.env" "$TMP/st.r9b"; then pass "R9b .env is untouched"; else fail "R9b .env changed"; fi

# R10: a legacy secrets file is imported into the keyring and emptied of what it stored.
fixture_env
mkdir -p "$HOME/.config/secrets"
printf 'GEMINI_API_KEY=ignored-not-in-fixture-manifest\nUNREAD_SECRET=dummy-r10\n' > "$store"
chmod 600 "$store"
grep -v '^UNREAD_SECRET=' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
apply_tty y
has "R10 the legacy secret is in the keyring" "UNREAD_SECRET=dummy-r10" "$("$FX/scripts/lib/himmel-secrets" get --no-dotenv UNREAD_SECRET 2>/dev/null)"
lacks "R10 the legacy file lost the stored line" "UNREAD_SECRET" "$(cat "$store")"
has "R10 the legacy file keeps a line the keyring did not take" "GEMINI_API_KEY=" "$(cat "$store")"
if [ "$(mode_of "$store")" = 600 ]; then pass "R10 the legacy file stays mode 600"; else fail "R10 the legacy file changed mode"; fi

# R10b: an emptied .env does not stop the legacy file moving into the keyring.
fixture_env
mkdir -p "$HOME/.config/secrets"
printf 'UNREAD_SECRET=dummy-r10b\n' > "$store"
chmod 600 "$store"
printf '# nothing left here\n' > "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "R10b an emptied .env with a legacy file applies"; else fail "R10b exited $rc: $out"; fi
has "R10b the legacy secret is in the keyring" "UNREAD_SECRET=dummy-r10b" "$("$FX/scripts/lib/himmel-secrets" get --no-dotenv UNREAD_SECRET 2>/dev/null)"
lacks "R10b the legacy file lost the stored line" "UNREAD_SECRET" "$(cat "$store")"

# R12: a run that scrubbed the backups prints no cp that would drop the secrets which stay in .env.
fixture_env
apply_tty y
lacks "R12 no restore cp after a scrub" "restore: cp" "$out"
has "R12 the report says why" "no longer holds the secret lines another copy covers" "$out"

# R13: the config-audit copy of .env is scrubbed too, and its manifest still verifies.
fixture_env
printf 'JIRA_API_TOKEN=dummy-r13\n' >> "$TMP/st/.env"
apply_tty y
cab=$(find "$HOME/.himmel/state/config-audit/backups" -name .env -type f 2>/dev/null)
if [ -n "$cab" ]; then pass "R13 the apply left a config-audit copy of .env"; else fail "R13 no config-audit copy of .env: the rows below would be vacuous"; fi
cab_all=$(for f in $cab; do cat "$f"; done)  # read-sink-ok: the paths come from find over this suite's own HOME
lacks "R13 no config-audit copy holds JIRA_API_TOKEN" "JIRA_API_TOKEN" "$cab_all"
lacks "R13 no config-audit copy holds READ_SECRET" "READ_SECRET" "$cab_all"
lacks "R13 no config-audit copy holds BITBUCKET_API_TOKEN" "BITBUCKET_API_TOKEN" "$cab_all"
has "R13 a config-audit copy keeps its config line" "HANDOVER_DIR=" "$cab_all"
for f in $cab; do
    d=$(dirname "$f")
    ok=$(node -e 'const fs=require("fs"),c=require("crypto"),d=process.argv[1];
        const m=JSON.parse(fs.readFileSync(d+"/manifest.json","utf8")), h=(b)=>c.createHash("sha256").update(b).digest("hex");
        const ok=m.files[".env"].sha256===h(fs.readFileSync(d+"/.env")) && m.digest===h(Buffer.from(JSON.stringify(Object.keys(m.files).map((n)=>[n,m.files[n].sha256]))));
        process.stdout.write(ok?"true":"false")' "$d")
    if [ "$ok" = true ]; then pass "R13 the manifest of $(basename "$d") matches its scrubbed .env"; else fail "R13 the manifest of $(basename "$d") no longer matches its .env"; fi
done

# R14: an older backup that holds the only copy of a key keeps it, and the report names the key.
fixture_env
mkdir -p "$HOME/.himmel/env-backups"
printf 'JIRA_API_TOKEN=dummy-r14\nBITBUCKET_API_TOKEN=dummy-r14b\n' > "$HOME/.himmel/env-backups/env.20260101T000000Z.3"
chmod 600 "$HOME/.himmel/env-backups/env.20260101T000000Z.3"
apply_tty y
old=$(cat "$HOME/.himmel/env-backups/env.20260101T000000Z.3")
has "R14 the only copy of JIRA_API_TOKEN stays in the older backup" "JIRA_API_TOKEN=dummy-r14" "$old"
lacks "R14 the key the keyring now holds left the older backup" "BITBUCKET_API_TOKEN" "$old"
has "R14 the report names the key kept" "keeps a line for JIRA_API_TOKEN" "$out"
lacks "R14 the report prints no value" "dummy-r14" "$out"

# R14b: under the consent the secrets stage does not run, so the backups are not scrubbed.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
out=$(CLAUDECODE=1 bash "$TMP/update-step.sh" apply < /dev/null 2>&1)
has "R14b the consented run says the backups keep their secret lines" "the backups keep their secret lines" "$out"
has "R14b the backup of the consented run still holds READ_SECRET" "READ_SECRET=CANARY-read-" "$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)"

# R15: a retry finishes a scrub an earlier run left undone (a kill between the .env rewrite and the scrub).
fixture_env
apply_tty y
mkdir -p "$HOME/.himmel/env-backups"
printf 'export BITBUCKET_API_TOKEN=dummy-r15\nHIMMEL_FLEET_CAP=3\n' > "$HOME/.himmel/env-backups/env.20260102T000000Z.4"
chmod 600 "$HOME/.himmel/env-backups/env.20260102T000000Z.4"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "R15 the dry run reports a scrub is owed" "scrub only: 1 backup file(s)" "$out"
has "R15 the dry run maps to pending for the update" "dry run: nothing written." "$out"
APPLY_ARGS="" apply_tty ""
if [ "$rc" = 3 ]; then pass "R15 a retry without -y is refused"; else fail "R15 a retry without -y exited $rc: $out"; fi
has "R15 the old backup is untouched without -y" "BITBUCKET_API_TOKEN=dummy-r15" "$(cat "$HOME/.himmel/env-backups/env.20260102T000000Z.4")"
apply_tty y
if [ "$rc" = 0 ]; then pass "R15 the retry exits 0"; else fail "R15 the retry exited $rc: $out"; fi
old=$(cat "$HOME/.himmel/env-backups/env.20260102T000000Z.4")
lacks "R15 the retry scrubbed the older backup" "BITBUCKET_API_TOKEN" "$old"
has "R15 the retry kept the config line" "HIMMEL_FLEET_CAP=3" "$old"
lacks "R15 the retry is not read as nothing to do" "nothing to move" "$out"

# R16: with no keyring the update marks a dry run that moves nothing incomplete; with one, up-to-date.
fixture_env
grep -v -E '^(HANDOVER_DIR=|USER_SLUG=|CR_|HIMMEL_FLEET_CAP=|UNREAD_SECRET=|BITBUCKET_API_TOKEN=)' "$TMP/st/.env" > "$FX/.env"
out=$(HIMMEL_SECRETS_KEYRING=off bash "$TMP/update-step.sh" check 2>&1)
has "R16 no keyring: the update step is incomplete, not up-to-date" "rc=0 status=incomplete" "$out"
grep -v -E '^READ_SECRET=' "$FX/.env" > "$FX/.env.new" && mv "$FX/.env.new" "$FX/.env"
out=$(bash "$TMP/update-step.sh" check 2>&1)
has "R16 control: with a keyring a .env with nothing to move is up-to-date" "rc=0 status=up-to-date" "$out"

# R17: --help prints the whole header, through the Exit block and its exit 4 line.
help_rc=0
out=$(bash "$SCRIPT" --help 2>&1) || help_rc=$?
if [ "$help_rc" -eq 0 ]; then pass "R17 --help exits 0"; else fail "R17 --help exits $help_rc"; fi
has "R17 --help shows the usage line" "bash scripts/setup/migrate-env.sh [-y] [--env <file>]" "$out"
has "R17 --help shows the dry-run option" "bash scripts/setup/migrate-env.sh --dry-run [--env <file>]" "$out"
has "R17 --help reaches the exit codes" "Exit: 0 moved" "$out"
has "R17 --help describes exit 4" "4 moved, but incomplete" "$out"
has "R17 --help ends with the last header line" "96 a chokepoint seam differs" "$out"
lacks "R17 --help stops before the code" "set -uo pipefail" "$out"

# R18: a resolver whose `names` fails stops the run with nothing written; it is not an empty secret set.
fixture_env
cp -p "$TMP/st/.env" "$TMP/r18.env.orig"
mv "$FX/scripts/lib/himmel-secrets" "$FX/scripts/lib/himmel-secrets.real"
# shellcheck disable=SC2016 # the wrapper expands its own variables
printf '#!/usr/bin/env bash\ncase "$1" in names) exit 1 ;; esac\nexec bash "${BASH_SOURCE[0]}.real" "$@"\n' > "$FX/scripts/lib/himmel-secrets"
chmod +x "$FX/scripts/lib/himmel-secrets"
apply_tty ""
mv "$FX/scripts/lib/himmel-secrets.real" "$FX/scripts/lib/himmel-secrets"
if [ "$rc" = 1 ]; then pass "R18 a failing names list stops the run (exit 1)"; else fail "R18 a failing names list exited $rc: $out"; fi
has "R18 the run says it could not read the secret names" "cannot read the secret names" "$out"
if cmp -s "$TMP/st/.env" "$TMP/r18.env.orig"; then pass "R18 .env is untouched"; else fail "R18 .env changed"; fi

# R19: an owed scrub is finished even when .env holds no keys (a kill after the .env rewrite) or is gone.
fixture_env
apply_tty y
: > "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'export BITBUCKET_API_TOKEN=dummy-r19\nHIMMEL_FLEET_CAP=3\n' > "$HOME/.himmel/env-backups/env.20260103T000000Z.5"
chmod 600 "$HOME/.himmel/env-backups/env.20260103T000000Z.5"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "R19 the dry run on an emptied .env reports a scrub is owed" "scrub only: 1 backup file(s)" "$out"
apply_tty y
if [ "$rc" = 0 ]; then pass "R19 the retry on an emptied .env exits 0"; else fail "R19 the retry on an emptied .env exited $rc: $out"; fi
lacks "R19 the retry on an emptied .env scrubbed the backup" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.5")"
printf 'export BITBUCKET_API_TOKEN=dummy-r19b\n' > "$HOME/.himmel/env-backups/env.20260103T000000Z.6"
chmod 600 "$HOME/.himmel/env-backups/env.20260103T000000Z.6"
rm -f "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "R19 the retry with no .env exits 0"; else fail "R19 the retry with no .env exited $rc: $out"; fi
lacks "R19 the retry with no .env scrubbed the backup" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.6")"
apply_tty y
has "R19 a clean station with no .env still says there is nothing to migrate" "nothing to migrate" "$out"

# R19c: a scrub that failed leaves an owed scrub; the retry on the now-emptied .env finishes it.
if [ "$(id -u)" = 0 ]; then
    echo "SKIP R19c: root reads a mode-000 file"
else
    fixture_env
    printf '# station .env\nBITBUCKET_API_TOKEN=dummy-r19c\nHIMMEL_FLEET_CAP=7\n' > "$TMP/st/.env"
    chmod 600 "$TMP/st/.env"
    mkdir -p "$HOME/.himmel/env-backups"
    printf 'BITBUCKET_API_TOKEN=dummy-r19c\n' > "$HOME/.himmel/env-backups/env.20260103T000000Z.7"
    chmod 000 "$HOME/.himmel/env-backups/env.20260103T000000Z.7"
    apply_tty y
    if [ "$rc" = 1 ]; then pass "R19c the failed scrub exits 1"; else fail "R19c the failed scrub exited $rc: $out"; fi
    chmod 600 "$HOME/.himmel/env-backups/env.20260103T000000Z.7"
    apply_tty y
    if [ "$rc" = 0 ]; then pass "R19c the retry exits 0"; else fail "R19c the retry exited $rc: $out"; fi
    lacks "R19c the retry scrubbed the backup the first run could not" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.7")"
fi

# R20: a blank NAME= line in .env is not a copy of the key, so the only real value in a backup stays.
fixture_env
printf '# station .env\nJIRA_API_TOKEN=\nHIMMEL_FLEET_CAP=7\n' > "$TMP/st/.env"
chmod 600 "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'JIRA_API_TOKEN=dummy-r20\n' > "$HOME/.himmel/env-backups/env.20260104T000000Z.8"
chmod 600 "$HOME/.himmel/env-backups/env.20260104T000000Z.8"
apply_tty y
if [ "$rc" = 0 ]; then pass "R20 the apply exits 0"; else fail "R20 the apply exited $rc: $out"; fi
has "R20 the only real value of JIRA_API_TOKEN stays in the backup" "JIRA_API_TOKEN=dummy-r20" "$(cat "$HOME/.himmel/env-backups/env.20260104T000000Z.8")"
has "R20 the report names JIRA_API_TOKEN as kept" "keeps a line for JIRA_API_TOKEN" "$out"
lacks "R20 the report prints no value" "dummy-r20" "$out"

# Two migrations started together: one wins the import lock, nothing is stored twice, .env is whole.
fixture_env
grep -v -E '^(HANDOVER_DIR=|USER_SLUG=|CR_|HIMMEL_FLEET_CAP=)' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
kreset
race() {  # <n>: one apply at a terminal, a slow keyring
    printf '\n' | SHELL=$(command -v bash) KSTUB_STORE_SLEEP=1 timeout 120 script -qec "bash $(printf '%q --env %q -y' "$SCRIPT" "$TMP/st/.env")" /dev/null > "$TMP/race.$1" 2>&1  # gnu-ok: the suite skips when timeout is absent
    echo "$?" > "$TMP/race.$1.rc"
}
race 1 &
r1=$!
race 2 &
r2=$!
wait "$r1" "$r2"
stores=$(grep -c '^secret-tool store' "$KSTUB_LOG")
if [ "$stores" = 3 ]; then pass "race: each secret reached the keyring once ($stores stores)"; else fail "race: $stores stores for 3 secrets"; fi
if [ "$(cat "$TMP/race.1.rc")$(cat "$TMP/race.2.rc")" != 00 ]; then pass "race: one of the two runs stopped"; else fail "race: both runs exited 0"; fi
lacks "race: the winner took every secret out of .env" "READ_SECRET=" "$(cat "$TMP/st/.env")"
has "race: the other run says why" "another import-env" "$(cat "$TMP/race.1" "$TMP/race.2" 2>/dev/null)"
no_canary "race: no value printed" "$(cat "$TMP/race.1" "$TMP/race.2")"

if [ "$FAILED" -gt 0 ]; then
    echo "test-migrate-env: $FAILED FAILED"
    exit 1
fi
echo "test-migrate-env: all passed"
