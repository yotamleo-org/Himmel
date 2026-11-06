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
# A stub systemctl first on PATH for every row, so none reaches a real user manager (CI has none):
# it logs its argv and answers show-environment with the names in $TMP/sysenv.
mkdir -p "$TMP/sbin"
cat > "$TMP/sbin/systemctl" <<'STUB' || fail "fixture write of the systemctl stub failed"
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1 $2" in
"--user show-environment")
    # SYS_UNREACHABLE=1: no user manager answers; SYS_READBACK_FAIL=1: the read-back after an unset fails
    [ -z "${SYS_UNREACHABLE:-}" ] || exit 1
    [ -z "${SYS_READBACK_FAIL:-}" ] || ! grep -q unset-environment "$SYSTEMCTL_LOG" || exit 1
    cat "$SYSENV" 2>/dev/null; exit 0 ;;
"--user unset-environment")
    # SYS_STICKY=1: the name stays in the manager
    [ -z "${SYS_STICKY:-}" ] || exit 0
    grep -v "^$3=" "$SYSENV" > "$SYSENV.n" 2>/dev/null; mv -f "$SYSENV.n" "$SYSENV" 2>/dev/null; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/sbin/systemctl"
export SYSTEMCTL_LOG="$TMP/systemctl.log" SYSENV="$TMP/sysenv"
export PATH="$TMP/sbin:$PATH"
unset SYS_UNREACHABLE SYS_STICKY SYS_READBACK_FAIL
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

fxval() { sed -n "s/^$1=//p" "$TMP/st/.env"; }  # a key's .env value, taken before an apply: a backup line that will equal the stored item

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
grep -v -E '^(READ_SECRET|UNREAD_SECRET|BITBUCKET_API_TOKEN)=' "$TMP/st.orig" > "$TMP/st.scrubbed"
if [ -n "$backup" ] && cmp -s "$backup" "$TMP/st.scrubbed"; then pass "the backup holds the original .env but for the moved secret lines"; else fail "no backup matching the original .env less its secrets (path '$backup')"; fi
if [ -n "$backup" ] && [ "$(mode_of "$backup")" = 600 ]; then pass "the backup is mode 600"; else fail "the backup mode is not 600"; fi
case "$backup" in "$TMP/st/"*|"") fail "the backup is inside the checkout or missing" ;; *) pass "the backup is outside the checkout" ;; esac
lacks "the scrubbed run prints no restore command that would drop the kept secrets" "restore: cp" "$out"
has "the report says the keyring serves the lines the backup lost" "the keyring serves those" "$out"
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
# R1/R4/R5(I5): the backup of this run holds no moved secret line; an env-keep line stays, nothing else serves it.
bk=$(cat "$HOME"/.himmel/env-backups/env.* 2>/dev/null)
for k in UNREAD_SECRET READ_SECRET BITBUCKET_API_TOKEN; do
    lacks "R1 the backup lost the $k line" "$k=" "$bk"
done
has "R1 the backup keeps the env-keep line" "KEEP_ME=" "$bk"
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

# R6: an older backup whose secret lines equal the stored items loses them; a config line stays.
fixture_env
printf 'JIRA_API_TOKEN=dummy-r1\n' >> "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'JIRA_API_TOKEN=dummy-r1\nexport BITBUCKET_API_TOKEN=%s\nHIMMEL_FLEET_CAP=3\n' "$(fxval BITBUCKET_API_TOKEN)" > "$HOME/.himmel/env-backups/env.20260101T000000Z.1"
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
has "R12 the report says why" "no longer holds the secret lines the keyring also holds" "$out"

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
printf 'JIRA_API_TOKEN=dummy-r14\nBITBUCKET_API_TOKEN=%s\n' "$(fxval BITBUCKET_API_TOKEN)" > "$HOME/.himmel/env-backups/env.20260101T000000Z.3"
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
r15v=$(fxval BITBUCKET_API_TOKEN)
apply_tty y
mkdir -p "$HOME/.himmel/env-backups"
printf 'export BITBUCKET_API_TOKEN=%s\nHIMMEL_FLEET_CAP=3\n' "$r15v" > "$HOME/.himmel/env-backups/env.20260102T000000Z.4"
chmod 600 "$HOME/.himmel/env-backups/env.20260102T000000Z.4"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "R15 the dry run reports a scrub is owed" "scrub only: 1 backup file(s)" "$out"
has "R15 the dry run maps to pending for the update" "dry run: nothing written." "$out"
APPLY_ARGS="" apply_tty ""
if [ "$rc" = 3 ]; then pass "R15 a retry without -y is refused"; else fail "R15 a retry without -y exited $rc: $out"; fi
has "R15 the old backup is untouched without -y" "export BITBUCKET_API_TOKEN=" "$(cat "$HOME/.himmel/env-backups/env.20260102T000000Z.4")"
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
fxput "$FX/.env" 'UNREAD_SECRET=\nBITBUCKET_API_TOKEN=%s\n' "$(canary token)"
out=$(bash "$TMP/update-step.sh" check 2>&1)
has "R16 a blank secret beside a movable one leaves the update pending" "rc=0 status=pending" "$out"
fxput "$FX/.env" 'UNREAD_SECRET=\n'
out=$(bash "$TMP/update-step.sh" check 2>&1)
has "R16 control: a blank secret alone is up-to-date" "rc=0 status=up-to-date" "$out"

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
r19v=$(fxval BITBUCKET_API_TOKEN)
apply_tty y
: > "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'export BITBUCKET_API_TOKEN=%s\nHIMMEL_FLEET_CAP=3\n' "$r19v" > "$HOME/.himmel/env-backups/env.20260103T000000Z.5"
chmod 600 "$HOME/.himmel/env-backups/env.20260103T000000Z.5"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "R19 the dry run on an emptied .env reports a scrub is owed" "scrub only: 1 backup file(s)" "$out"
apply_tty y
if [ "$rc" = 0 ]; then pass "R19 the retry on an emptied .env exits 0"; else fail "R19 the retry on an emptied .env exited $rc: $out"; fi
lacks "R19 the retry on an emptied .env scrubbed the backup" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.5")"
has "R19 the scrub kept the config line of that backup" "HIMMEL_FLEET_CAP=3" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.5")"
printf 'export BITBUCKET_API_TOKEN=%s\n' "$r19v" > "$HOME/.himmel/env-backups/env.20260103T000000Z.6"
chmod 600 "$HOME/.himmel/env-backups/env.20260103T000000Z.6"
rm -f "$TMP/st/.env"
apply_tty y
if [ "$rc" = 0 ]; then pass "R19 the retry with no .env exits 0"; else fail "R19 the retry with no .env exited $rc: $out"; fi
lacks "R19 the retry with no .env scrubbed the backup" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260103T000000Z.6")"
if [ -f "$HOME/.himmel/env-backups/env.20260103T000000Z.6" ]; then pass "R19 the scrubbed backup still exists"; else fail "R19 the scrub deleted the backup"; fi
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
    if [ -f "$HOME/.himmel/env-backups/env.20260103T000000Z.7" ]; then pass "R19c the scrubbed backup still exists"; else fail "R19c the scrub deleted the backup"; fi
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

# R20b: a value the readers see as empty is no copy either: an inline comment after a blank value.
fixture_env
printf '# station .env\nJIRA_API_TOKEN=     # note\nHIMMEL_FLEET_CAP=7\n' > "$TMP/st/.env"
chmod 600 "$TMP/st/.env"
mkdir -p "$HOME/.himmel/env-backups"
printf 'JIRA_API_TOKEN=dummy-r20b\n' > "$HOME/.himmel/env-backups/env.20260104T000001Z.9"
chmod 600 "$HOME/.himmel/env-backups/env.20260104T000001Z.9"
apply_tty y
if [ "$rc" = 0 ]; then pass "R20b the apply exits 0"; else fail "R20b the apply exited $rc: $out"; fi
has "R20b the only real value stays in the backup" "JIRA_API_TOKEN=dummy-r20b" "$(cat "$HOME/.himmel/env-backups/env.20260104T000001Z.9")"
has "R20b the report names JIRA_API_TOKEN as kept" "keeps a line for JIRA_API_TOKEN" "$out"
lacks "R20b the report prints no value" "dummy-r20b" "$out"

# R20e: a quoted-empty .env line for a key that was never imported (an env-keep key) is no copy, so the only real value in a backup stays and the key is named.
r20n=0
for r20line in 'KEEP_ME=""' "KEEP_ME=''"; do
    r20n=$((r20n + 1))
    fixture_env
    fxput "$TMP/st/.env" '# station .env\n%s\nHIMMEL_FLEET_CAP=7\n' "$r20line"
    chmod 600 "$TMP/st/.env"
    mkdir -p "$HOME/.himmel/env-backups"
    r20f="$HOME/.himmel/env-backups/env.20260104T00001$r20n""Z.8"
    fxput "$r20f" 'KEEP_ME=dummy-r20e\n'
    chmod 600 "$r20f"
    apply_tty y
    if [ "$rc" = 0 ]; then pass "R20e case $r20n: the apply exits 0"; else fail "R20e case $r20n: the apply exited $rc: $out"; fi
    if [ -f "$r20f" ]; then pass "R20e case $r20n: the backup still exists"; else fail "R20e case $r20n: the backup is gone"; fi
    has "R20e case $r20n: the only real value of KEEP_ME stays in the backup" "KEEP_ME=dummy-r20e" "$(cat "$r20f")"
    has "R20e case $r20n: the report names KEEP_ME as kept" "keeps a line for KEEP_ME" "$out"
    lacks "R20e case $r20n: the report prints no value" "dummy-r20e" "$out"
done

# --- 11. The value compare: a backup line leaves only when its value equals the user-scope keyring item ---
bk_line() {  # <stem> <line>...: one mode-600 file in env-backups; sets bf and keeps a copy to compare against
    local stem=$1
    shift
    mkdir -p "$HOME/.himmel/env-backups"
    bf="$HOME/.himmel/env-backups/env.$stem"
    printf '%s\n' "$@" > "$bf" || fail "fixture write to $bf failed"
    chmod 600 "$bf"
    cp -p "$bf" "$TMP/bf.orig"
}
kept_named() {  # <label> <key>: backup bf is byte-identical, the report names the key for it, no value printed
    if cmp -s "$bf" "$TMP/bf.orig"; then pass "$1: the backup line stays"; else fail "$1: the backup line changed or is gone"; fi
    if printf '%s\n' "$out" | grep -F "$bf keeps a line for" | grep -w "$2" > /dev/null; then pass "$1: the report names $2"; else fail "$1: the report does not name $2"; fi
    no_canary "$1: no value printed" "$out"
}
env_only() {  # <line>: a fresh fixture whose .env holds that line and one config key
    fixture_env
    fxput "$TMP/st/.env" '# station .env\n%s\nHIMMEL_FLEET_CAP=7\n' "$1"
    chmod 600 "$TMP/st/.env"
}
kitem() { fxadd "$KSTUB_STORE" 'service=himmel key=%s scope=user\t%s\n' "$1" "$2"; }
fresh_backup() { find "$HOME/.himmel/env-backups" -name 'env.*' -newer "$TMP/st.orig" -type f | sort | tail -n 1; }

# R20k: every shape whose .env value holds no real copy: the keyring gets those characters, a real value only in a backup stays, and the key is named.
r20n=0
for r20shape in '""' '"" # note' "''" "'' # note" '" "' "' '" '#' '#x' '# x' '""#x' 'your_api_token_here'; do
    r20n=$((r20n + 1))
    env_only "JIRA_API_TOKEN=$r20shape"
    bk_line "20260104T0000${r20n}Z.8" "JIRA_API_TOKEN=$(canary r20k)"
    apply_tty y
    if [ "$rc" = 0 ]; then pass "R20k shape $r20n: the apply exits 0"; else fail "R20k shape $r20n: the apply exited $rc: $out"; fi
    has "R20k shape $r20n: the keyring holds an item for JIRA_API_TOKEN" "JIRA_API_TOKEN" "$(cut -f1 "$KSTUB_STORE")"  # read-sink-ok: KSTUB_STORE is this suite's own scratch keyring, attrs column only
    kept_named "R20k shape $r20n" JIRA_API_TOKEN
done

# R30: a placeholder put back in .env after a move: a backup line that differs stays and is named, one that equals the item leaves.
fixture_env
fxadd "$TMP/st/.env" 'JIRA_API_TOKEN=%s\n' "$(canary r30)"
r30v=$(fxval JIRA_API_TOKEN)
apply_tty y
fxadd "$TMP/st/.env" 'JIRA_API_TOKEN=your_api_token_here\n'
fxput "$HOME/.himmel/env-backups/env.20260105T000000Z.2" 'JIRA_API_TOKEN=%s\n' "$r30v"
bk_line 20260105T000000Z.1 "JIRA_API_TOKEN=$(canary r30b)"
apply_tty y
if [ "$rc" = 0 ]; then pass "R30 the apply exits 0"; else fail "R30 the apply exited $rc: $out"; fi
has "R30 the placeholder is held" "held JIRA_API_TOKEN" "$out"
kept_named "R30" JIRA_API_TOKEN
lacks "R30 the line that equals the item left" "JIRA_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260105T000000Z.2")"

# R31: every line of the key in a backup must equal the item: duplicates and export lines count, a quoted-empty line blocks nothing.
r31v=$(canary r31item)
r31o=$(canary r31other)
r31n=0
for r31case in "kept|JIRA_API_TOKEN=\"\"|JIRA_API_TOKEN=$r31o" "kept|JIRA_API_TOKEN=$r31o|JIRA_API_TOKEN=\"\"" "kept|JIRA_API_TOKEN=$r31v|JIRA_API_TOKEN=$r31o" "kept|export JIRA_API_TOKEN=$r31o|" \
    "drop|JIRA_API_TOKEN=$r31v|JIRA_API_TOKEN=$r31v" "drop|JIRA_API_TOKEN=\"\"|JIRA_API_TOKEN=$r31v" "drop|export JIRA_API_TOKEN=$r31v|"; do
    r31n=$((r31n + 1))
    env_only "KEEP_ME=x"
    kitem JIRA_API_TOKEN "$r31v"
    IFS='|' read -r r31want r31a r31b <<<"$r31case"
    bk_line "20260106T00000${r31n}Z.1" "$r31a" "$r31b"
    apply_tty y
    if [ "$r31want" = kept ]; then
        kept_named "R31 case $r31n" JIRA_API_TOKEN
    else
        lacks "R31 case $r31n: every line equals the item, so the key left" "JIRA_API_TOKEN" "$(cat "$bf")"
        no_canary "R31 case $r31n: no value printed" "$out"
    fi
done

# R32: duplicate .env lines K="" then K=real: the readers take the first, the move deletes both, and this run's backup keeps the dead real line and names it.
env_only 'JIRA_API_TOKEN=""'
fxadd "$TMP/st/.env" 'JIRA_API_TOKEN=%s\n' "$(canary r32)"
apply_tty y
bf=$(fresh_backup)
if [ -n "$bf" ] && grep -q '^JIRA_API_TOKEN=CANARY-' "$bf"; then pass "R32 this run's backup keeps the dead real line"; else fail "R32 the dead real line is gone from this run's backup"; fi
lacks "R32 the move deleted both lines from .env" "JIRA_API_TOKEN" "$(cat "$TMP/st/.env")"
if printf '%s\n' "$out" | grep -F "$bf keeps a line for" | grep -w JIRA_API_TOKEN > /dev/null; then pass "R32 the report names the key"; else fail "R32 the report does not name the key"; fi

# R33: an env-keep key leaves no backup, even when its keyring item holds the same value: a restore would lose its only .env line.
r33v=$(canary r33)
env_only "KEEP_ME=$r33v"
kitem KEEP_ME "$r33v"
bk_line 20260107T000000Z.1 "KEEP_ME=$r33v"
apply_tty y
kept_named "R33" KEEP_ME

# R34: a held key and an env-keep key stay in every backup of the run, so a restore that overwrites .env loses neither; a stored key leaves.
fixture_env
kitem UNREAD_SECRET "$(canary r34item)"
apply_tty y
bf=$(fresh_backup)
r34b=$(sed 's/=.*//' "$bf")
has "R34 this run's backup keeps the held key" "UNREAD_SECRET" "$r34b"
has "R34 this run's backup keeps the env-keep key" "KEEP_ME" "$r34b"
lacks "R34 this run's backup lost the stored key" "READ_SECRET" "$(grep -v UNREAD_SECRET <<<"$r34b")"
r34c=$(find "$HOME/.himmel/state/config-audit/backups" -name .env -type f | head -n 1)
r34k=$(sed 's/=.*//' "$r34c")
has "R34 the config copy keeps the held key" "UNREAD_SECRET" "$r34k"
has "R34 the config copy keeps the env-keep key" "KEEP_ME" "$r34k"
if printf '%s\n' "$out" | grep 'config backup .* keeps a line for' | grep -w UNREAD_SECRET > /dev/null; then pass "R34 the report names the config copy's kept key"; else fail "R34 the report does not name the config copy's kept key"; fi
no_canary "R34 no value printed" "$out"

# R35: one set covers all config copies: a differing value in one keeps the key in every copy, and each copy names it.
env_only "JIRA_API_TOKEN=$(canary r35a)"
r35item=$(canary r35item)
kitem JIRA_API_TOKEN "$r35item"
apply_tty y
r35d=$(dirname "$(find "$HOME/.himmel/state/config-audit/backups" -name .env -type f | head -n 1)")
r35e="$HOME/.himmel/state/config-audit/backups/20260101T000000Z-abcd"
cp -a "$r35d" "$r35e"
fxput "$r35e/.env" 'JIRA_API_TOKEN=%s\n' "$r35item"
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
apply_tty y
if [ "$(printf '%s\n' "$out" | grep 'config backup .* keeps a line for' | grep -cw JIRA_API_TOKEN)" = 2 ]; then pass "R35 both config copies name the key"; else fail "R35 the config copies do not both name the key"; fi
has "R35 the copy that equals the item keeps its line too" "JIRA_API_TOKEN=" "$(cat "$r35e/.env")"
no_canary "R35 no value printed" "$out"

# R36: a legacy file with a later duplicate of another value keeps it: that file has no backup, so the dead line would be gone.
fixture_env
mkdir -p "$HOME/.config/secrets"
fxput "$store" 'UNREAD_SECRET=%s\nUNREAD_SECRET=%s\n' "$(canary r36a)" "$(canary r36b)"
chmod 600 "$store"
grep -v '^UNREAD_SECRET=' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
apply_tty y
if [ "$(grep -c '^UNREAD_SECRET=' "$store")" = 2 ]; then pass "R36 the legacy file keeps the key whose lines differ"; else fail "R36 the legacy file lost the key whose lines differ"; fi
has "R36 the report names it" "keeps a line for UNREAD_SECRET" "$out"
no_canary "R36 no value printed" "$out"

# --- 12. The naming promise: every exit reports the backup-only keys, and a locked keyring says so ---
only_bk() { bk_line 20260201T000000Z.1 "JIRA_API_TOKEN=$(canary only)"; }
# N1: no .env.
fixture_env
rm -f "$TMP/st/.env"
only_bk
apply_tty y
if [ "$rc" = 0 ]; then pass "N1 no .env exits 0"; else fail "N1 no .env exited $rc: $out"; fi
has "N1 the run says no .env" "no .env found; nothing to migrate" "$out"
kept_named "N1" JIRA_API_TOKEN
# N2: .env empty, the keyring lacks the key, the only value in a backup (the codex case).
fixture_env
: > "$TMP/st/.env"
only_bk
apply_tty y
if [ "$rc" = 0 ]; then pass "N2 an empty .env exits 0"; else fail "N2 an empty .env exited $rc: $out"; fi
has "N2 the run says the file holds no keys" "holds no keys; nothing to migrate" "$out"
kept_named "N2" JIRA_API_TOKEN
# N3: nothing to move.
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
only_bk
apply_tty y
if [ "$rc" = 0 ]; then pass "N3 nothing to move exits 0"; else fail "N3 nothing to move exited $rc: $out"; fi
has "N3 the run says nothing moves" "nothing to move: every key stays in .env" "$out"
kept_named "N3" JIRA_API_TOKEN
# N3b: a signal during the naming finds the temp dir gone, so the cleanup comes first. The stub signals the run on a read of the item once the plan's last line is out.
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
kitem JIRA_API_TOKEN "$(canary n3b)"
only_bk
mkdir -p "$TMP/sigbin" "$TMP/tmpd-n3b"
# shellcheck disable=SC2016 # the stub expands these
fxput "$TMP/sigbin/secret-tool" '#!/usr/bin/env bash\n[ "$1" != lookup ] || ! grep -q "nothing to move: every key" "%s" || kill -TERM "$(<"%s")"\nexec "%s" "$@"\n' "$TMP/n3b.out" "$TMP/sig.pid" "$(command -v secret-tool)"
chmod +x "$TMP/sigbin/secret-tool"
# shellcheck disable=SC2016 # the inner shell expands these
PATH="$TMP/sigbin:$PATH" TMPDIR="$TMP/tmpd-n3b" bash -c 'echo $$ > "$1"; shift; exec bash "$@"' _ "$TMP/sig.pid" "$SCRIPT" --dry-run --env "$TMP/st/.env" > "$TMP/n3b.out" 2>&1
rc=$?
if [ "$rc" = 1 ]; then pass "N3b the signal reached the run during the naming"; else fail "N3b the run exited $rc, so no signal came during the naming"; fi
if [ -z "$(ls -A "$TMP/tmpd-n3b")" ]; then pass "N3b a signal during the naming leaves no temp dir"; else fail "N3b a signal during the naming left: $(ls -A "$TMP/tmpd-n3b")"; fi
# N4 to N6: the scrub-only path, as a dry run, refused without -y, and applied.
n4v=$(canary n4)
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
kitem BITBUCKET_API_TOKEN "$n4v"
only_bk
fxput "$HOME/.himmel/env-backups/env.20260201T000000Z.2" 'BITBUCKET_API_TOKEN=%s\n' "$n4v"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "N4 the scrub-only dry run exits 0"; else fail "N4 the scrub-only dry run exited $rc: $out"; fi
has "N4 the report speaks of a value match, not of copies" "scrub only: 1 backup file(s) hold secret lines whose value matches the keyring item; the scrub drops only those." "$out"
kept_named "N4" JIRA_API_TOKEN
APPLY_ARGS="" apply_tty ""
if [ "$rc" = 3 ]; then pass "N5 a scrub-only run without -y is refused"; else fail "N5 exited $rc: $out"; fi
kept_named "N5" JIRA_API_TOKEN
apply_tty y
if [ "$rc" = 0 ]; then pass "N6 the scrub-only apply exits 0"; else fail "N6 exited $rc: $out"; fi
kept_named "N6" JIRA_API_TOKEN
lacks "N6 the line that equals the item left" "BITBUCKET_API_TOKEN" "$(cat "$HOME/.himmel/env-backups/env.20260201T000000Z.2")"
# N7: a dry run with keys moving.
fixture_env
only_bk
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1); rc=$?
has "N7 the dry run still moves keys" "dry run: nothing written." "$out"
kept_named "N7" JIRA_API_TOKEN
# N8: no unlocked keyring with -y: coverage cannot be checked, so the report names what the backups hold.
fixture_env
only_bk
apply_tty y "HIMMEL_SECRETS_KEYRING=off "
if [ "$rc" = 4 ]; then pass "N8 no keyring exits 4"; else fail "N8 no keyring exited $rc: $out"; fi
has "N8 the report says why it cannot compare" "keyring: off, so the backups cannot be compared with it" "$out"
if printf '%s\n' "$out" | grep -F 'cannot be compared with it' | grep -w JIRA_API_TOKEN > /dev/null; then pass "N8 the report names the key"; else fail "N8 the report does not name the key"; fi
if cmp -s "$bf" "$TMP/bf.orig"; then pass "N8 the backup line stays"; else fail "N8 the backup changed"; fi
no_canary "N8 no value printed" "$out"
# N9: a locked keyring says it is locked, on a no-op exit too, with no backup line to name.
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
apply_tty y "KSTUB_LOCKED=true "
has "N9 a locked keyring says so when nothing moves" "keyring: locked" "$out"
lacks "N9 a locked keyring is not called uncovered" "keeps a line for" "$out"
only_bk
apply_tty y "KSTUB_LOCKED=true "
if printf '%s\n' "$out" | grep -F 'keyring: locked' | grep -w JIRA_API_TOKEN > /dev/null; then pass "N9 a locked keyring names what the backups hold"; else fail "N9 a locked keyring does not name the key"; fi
# N10: a consent run in an agent session, and with no terminal, while keys move.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
only_bk
out=$(CLAUDECODE=1 bash "$SCRIPT" --env "$FX/.env" -y < /dev/null 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "N10 the consented agent run exits 0"; else fail "N10 exited $rc: $out"; fi
kept_named "N10 agent" JIRA_API_TOKEN
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
only_bk
out=$(bash "$SCRIPT" --env "$FX/.env" -y < /dev/null 2>&1); rc=$?
if [ "$rc" = 0 ]; then pass "N10 the consented run with no terminal exits 0"; else fail "N10 no terminal exited $rc: $out"; fi
kept_named "N10 no terminal" JIRA_API_TOKEN
# N11: a refusal without the consent names the key too.
fixture_env
only_bk
out=$(bash "$SCRIPT" --env "$TMP/st/.env" < /dev/null 2>&1); rc=$?
if [ "$rc" = 3 ]; then pass "N11 no terminal is refused"; else fail "N11 exited $rc: $out"; fi
kept_named "N11" JIRA_API_TOKEN
# N12: a config backup whose manifest does not parse is skipped by the scrub: named, for a differing and for an equal value.
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
n12d="$HOME/.himmel/state/config-audit/backups/20260101T000000Z-abcd"
mkdir -p "$n12d"
fxput "$n12d/manifest.json" 'not json\n'
n12v=$(canary n12)
fxput "$n12d/.env" 'JIRA_API_TOKEN=%s\nBITBUCKET_API_TOKEN=%s\n' "$(canary n12b)" "$n12v"
kitem BITBUCKET_API_TOKEN "$n12v"
apply_tty y
has "N12 the differing value is named" "config backup 20260101T000000Z-abcd keeps a line for JIRA_API_TOKEN" "$out"
has "N12 the equal value is named, with why it stays" "config backup 20260101T000000Z-abcd keeps a line for BITBUCKET_API_TOKEN: the scrub skips that backup" "$out"
has "N12 the skipped copy is untouched" "BITBUCKET_API_TOKEN=" "$(cat "$n12d/.env")"
no_canary "N12 no value printed" "$out"
# N13: a failed count of the config copies is a failure, not nothing owed.
cp "$FX/scripts/lib/config-audit.sh" "$TMP/config-audit.good.sh"
fxput "$FX/scripts/lib/config-audit.sh" 'config_audit_pre() { :; }\nconfig_audit_post() { :; }\nconfig_audit_scrub() { return 1; }\n'
fixture_env
fxput "$TMP/st/.env" 'KEEP_ME=%s\n' "$(canary keep)"
apply_tty y
cp "$TMP/config-audit.good.sh" "$FX/scripts/lib/config-audit.sh"
if [ "$rc" = 1 ]; then pass "N13 a failed config-backup count exits 1"; else fail "N13 exited $rc: $out"; fi
has "N13 the report says so" "could not check the .env copies in the config backups" "$out"

# --- 13. The consent and the printed command; -y outside this checkout ---
# C1: with the consent on, -y at a terminal outside an agent session is the operator's own run: the printed command moves the policy key.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
at_tty y "bash $(printf '%q --env %q -y' "$SCRIPT" "$FX/.env")"
if [ "$rc" = 0 ]; then pass "C1 -y at a prompt with the consent on exits 0"; else fail "C1 exited $rc: $out"; fi
lacks "C1 the run is not the consent's" "moving without a prompt" "$out"
lacks "C1 the policy key is not held back" "gate-policy keys move only at your own prompt" "$out"
lacks "C1 the policy key left .env" "CR_REQUIRE_CROSS_MODEL" "$(cat "$FX/.env")"
has "C1 the policy key is in config.json" "CR_REQUIRE_CROSS_MODEL" "$(cat "$HOME/.himmel/config.json")"
# C2: under CLAUDECODE the consent path is unchanged, at a terminal with -y too: the policy key stays.
consent_fixture '{"version":1,"policy":{"ENV_MIGRATION_CONSENT":"1"}}'
at_tty y "CLAUDECODE=1 bash $(printf '%q --env %q -y' "$SCRIPT" "$FX/.env")"
if [ "$rc" = 0 ]; then pass "C2 the agent's consented run exits 0"; else fail "C2 exited $rc: $out"; fi
has "C2 the consent decides" "moving without a prompt" "$out"
has "C2 the policy key is held back" "gate-policy keys move only at your own prompt" "$out"
has "C2 the policy key stays in .env" "CR_REQUIRE_CROSS_MODEL" "$(cat "$FX/.env")"
has "C2 the secrets stay in .env" "UNREAD_SECRET=CANARY-unread-" "$(cat "$FX/.env")"
# Y1: -y with no --env from inside another repository acts on nothing: that repository's .env is not this checkout's.
fixture_env
y1="$TMP/other-repo"
mkdir -p "$y1"
git init -q "$y1"
fxput "$y1/.env" 'USER_SLUG=%s\n' "$(canary y1)"
cp -p "$y1/.env" "$TMP/y1.orig"
at_tty "" "cd $(printf '%q' "$y1") && bash $(printf '%q' "$SCRIPT") -y"
if [ "$rc" = 3 ]; then pass "Y1 -y on another repository's .env is refused"; else fail "Y1 exited $rc: $out"; fi
has "Y1 the refusal names --env" "--env" "$out"
if cmp -s "$y1/.env" "$TMP/y1.orig" && [ ! -e "$HOME/.himmel/himmel.conf" ]; then pass "Y1 nothing moved"; else fail "Y1 something moved"; fi
no_canary "Y1 no value printed" "$out"
# Y2: naming that file with --env is allowed, and -y with no --env from this checkout still works.
at_tty "" "cd $(printf '%q' "$y1") && bash $(printf '%q --env %q' "$SCRIPT" "$y1/.env") -y"
if [ "$rc" = 0 ]; then pass "Y2 --env names the file and the run goes on"; else fail "Y2 exited $rc: $out"; fi
fixture_env
cp -p "$TMP/st/.env" "$FX/.env"
at_tty "" "cd $(printf '%q' "$FX") && bash $(printf '%q' "$SCRIPT") -y"
if [ "$rc" = 0 ]; then pass "Y2 -y in this checkout needs no --env"; else fail "Y2 this checkout exited $rc: $out"; fi
lacks "Y2 this checkout's config key moved" "HIMMEL_FLEET_CAP" "$(cat "$FX/.env")"
rm -f "$FX/.env"
# Y3: from a linked worktree the .env is the primary checkout's, still this checkout.
fixture_env
git -C "$FX" -c user.name=fx -c user.email=fx@example.invalid -c core.hooksPath=/dev/null commit -qm fx
y3="$TMP/fx-worktree"
git -C "$FX" worktree add -q --detach "$y3"
cp -p "$TMP/st/.env" "$FX/.env"
at_tty "" "cd $(printf '%q' "$y3") && bash $(printf '%q' "$y3/scripts/setup/migrate-env.sh") -y"
if [ "$rc" = 0 ]; then pass "Y3 -y from a worktree acts on the primary's .env"; else fail "Y3 exited $rc: $out"; fi
lacks "Y3 the primary's config key moved" "HIMMEL_FLEET_CAP" "$(cat "$FX/.env")"
rm -f "$FX/.env"

# --- 14. The plan items: loud copies, blank and export lines, the held and shadow messages, stale temp files ---
# P1: the private secrets copy that cannot be written stops the run, nothing removed.
mkdir -p "$TMP/failbin"
real_awk=$(command -v awk)
cat > "$TMP/failbin/awk" <<EOF
#!/usr/bin/env bash
case "\$*" in *'index(set, " " k " ") { print }'*) exit 1 ;; esac
exec "$real_awk" "\$@"
EOF
chmod +x "$TMP/failbin/awk"
fixture_env
apply_tty y "PATH=$TMP/failbin:\$PATH "
if [ "$rc" = 1 ]; then pass "P1 a failed secrets copy exits 1"; else fail "P1 exited $rc: $out"; fi
has "P1 the report says so" "could not write the private copy of the secrets" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "P1 .env is untouched"; else fail "P1 .env changed"; fi
# P2: the verify copy that cannot be written stops the run, nothing removed.
mkdir -p "$TMP/failcp"
real_cp=$(command -v cp)
cat > "$TMP/failcp/cp" <<EOF
#!/usr/bin/env bash
for a; do l=\$a; done
case "\$l" in */repo/.env) exit 1 ;; esac
exec "$real_cp" "\$@"
EOF
chmod +x "$TMP/failcp/cp"
fixture_env
apply_tty y "PATH=$TMP/failcp:\$PATH "
if [ "$rc" = 1 ]; then pass "P2 a failed verify copy exits 1"; else fail "P2 exited $rc: $out"; fi
has "P2 the report says so" "verify: could not copy .env into the scratch checkout" "$out"
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "P2 .env is untouched"; else fail "P2 .env changed"; fi
# P3: a blank secret line is a plan row that stays, not a pending move.
fixture_env
fxput "$TMP/st/.env" 'UNREAD_SECRET=\nREAD_SECRET=   # note\nKEEP_ME=%s\n' "$(canary keep)"
cp -p "$TMP/st/.env" "$TMP/st.orig"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "P3 the plan names a blank line" "  UNREAD_SECRET  secret  stays (blank in .env: no value)" "$out"
has "P3 the plan names a line the readers see as blank" "  READ_SECRET  secret  stays (blank in .env: no value)" "$out"
has "P3 nothing is pending" "nothing to move: every key stays in .env." "$out"
apply_tty y
if [ "$rc" = 0 ] && cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "P3 the apply leaves the blank lines"; else fail "P3 exited $rc: $out"; fi
# P4: an export line is a plan row: the readers do not read it, so it stays; a file of them is not an empty file.
fixture_env
fxput "$TMP/st/.env" 'export READ_SECRET=%s\nexport HANDOVER_DIR=/x\nexport NOT_HIMMELS=%s\n' "$(canary p4)" "$(canary p4b)"
cp -p "$TMP/st/.env" "$TMP/st.orig"
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "P4 the plan names a secret export line" "  READ_SECRET  secret  stays (an export line: the readers do not read it; remove export to move it)" "$out"
has "P4 the plan names a config export line" "  HANDOVER_DIR  config  stays (an export line: the readers do not read it; remove export to move it)" "$out"
lacks "P4 a key that is not himmel's gets no row" "NOT_HIMMELS" "$out"
lacks "P4 the file is not called empty" "holds no keys" "$out"
no_canary "P4 no value printed" "$out"
apply_tty y
if [ "$rc" = 0 ] && cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "P4 the apply leaves the export lines"; else fail "P4 exited $rc: $out"; fi
# P5: the held message says which value is served.
fixture_env
kitem UNREAD_SECRET "$(canary p5)"
apply_tty y
has "P5 the held message names the served value" "the keyring value is the one served" "$out"
# P6: a project-scope item that differs shadows the moved user-scope value, and the report says so.
fixture_env
fxadd "$KSTUB_STORE" 'service=himmel key=UNREAD_SECRET project=%s\t%s\n' "$(cd "$FX" && pwd -P)" "$(canary p6)"
at_tty y "cd $(printf '%q' "$FX") && bash $(printf '%q --env %q' "$SCRIPT" "$TMP/st/.env") -y"
has "P6 the shadowed key is named" "shadowed UNREAD_SECRET" "$out"
has "P6 the report says which is served" "a project-scope keyring item with another value is served first" "$out"
no_canary "P6 no value printed" "$out"
# P7: a .env.migrate.<pid> a killed run left beside .env holds secrets: the next apply removes it; a live run's stays.
fixture_env
p7dead=$(bash -c 'printf %s "$$"')
fxput "$TMP/st/.env.migrate.$p7dead" 'dummy\n'
fxput "$TMP/st/.env.migrate.$$" 'dummy\n'
apply_tty y
if [ ! -e "$TMP/st/.env.migrate.$p7dead" ]; then pass "P7 the dead run's copy is gone"; else fail "P7 the dead run's copy stays"; fi
if [ -e "$TMP/st/.env.migrate.$$" ]; then pass "P7 a live run's copy stays"; else fail "P7 a live run's copy was removed"; fi

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

# --- names outside the manifest, a quoted value over two lines, the systemd user manager ---
SYSPATH="PATH=$TMP/sbin:$PATH "
fixture_9360() {  # the station .env plus an entry outside the manifest whose quoted value spans two lines, and a one-line one
    fixture_env
    : > "$SYSTEMCTL_LOG"
    fxadd "$TMP/st/.env" "GGS_MQTT_PASS='%s\n'\n" "$(canary mq)"
    fxadd "$TMP/st/.env" 'PLAIN_UNOWNED=%s\n' "$(canary plain)"
    printf 'GGS_MQTT_PASS=x\nOTHER_TOOL_TOKEN=y\n' > "$SYSENV"
    cp -p "$TMP/st/.env" "$TMP/st.orig"
}
sources_clean() {  # the file still sources, and load_dotenv still reads the key after the entry
    bash -c 'set -e; . "$1"' _ "$TMP/st/.env" >/dev/null 2>&1 \
        && [ "$(bash -c '. "$1"; load_dotenv --root "$2" PLAIN_UNOWNED >/dev/null 2>&1; printf %s "${PLAIN_UNOWNED-}"' _ "$FX/scripts/lib/load-dotenv.sh" "$TMP/st")" = "$(sed -n 's/^PLAIN_UNOWNED=//p' "$TMP/st/.env")" ]
}
# N1: -y alone never moves an unowned name, and the plan says how to.
fixture_9360
apply_tty y "$SYSPATH"
has "N1 -y alone leaves the two-line entry" "GGS_MQTT_PASS='CANARY-mq-" "$(cat "$TMP/st/.env")"
has "N1 the plan names the way to move unowned names" "--unowned" "$out"
if ! grep -q 'CANARY-mq' "$KSTUB_STORE" 2>/dev/null; then pass "N1 -y alone stores no unowned value"; else fail "N1 -y alone stored an unowned value"; fi
# N2: --keys moves a name outside the manifest with a two-line quoted value, whole.
fixture_9360
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "$SYSPATH"
if [ "$rc" = 0 ]; then pass "N2 --keys apply exits 0"; else fail "N2 --keys apply exited $rc: $out"; fi
if grep -q 'CANARY-mq' "$KSTUB_STORE" 2>/dev/null; then pass "N2 the value is in the keyring"; else fail "N2 the value is not in the keyring"; fi
lacks "N2 no GGS_MQTT_PASS entry left" "GGS_MQTT_PASS" "$(cat "$TMP/st/.env")"
if [ "$(grep -c "^'$" "$TMP/st/.env")" = 0 ]; then pass "N2 no stray quote left"; else fail "N2 a stray quote is left in .env"; fi
if sources_clean; then pass "N2 the file still sources and load_dotenv still reads it"; else fail "N2 the file no longer sources cleanly"; fi
has "N2 a key not named stays" "PLAIN_UNOWNED=CANARY-plain-" "$(cat "$TMP/st/.env")"
has "N2 OTHER_TOOL_TOKEN (not named) stays" "OTHER_TOOL_TOKEN=CANARY-other-" "$(cat "$TMP/st/.env")"
no_canary "N2 no value printed" "$out"
# N3: every moved name gets an unset-environment call, and the report names them.
for n in GGS_MQTT_PASS READ_SECRET UNREAD_SECRET BITBUCKET_API_TOKEN; do
    has "N3 unset-environment for $n" "systemctl --user unset-environment $n" "$(cat "$SYSTEMCTL_LOG")"
done
lacks "N3 a name that stayed is not unset" "unset-environment OTHER_TOOL_TOKEN" "$(cat "$SYSTEMCTL_LOG")"
has "N3 the report names the systemd user manager" "systemd user manager" "$out"
# N4: a failed keyring store leaves the entry whole in the file.
fixture_9360
grep -v -E '^(READ_SECRET|UNREAD_SECRET|BITBUCKET_API_TOKEN|KEEP_ME)=' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "KSTUB_DROP_STORE=1 $SYSPATH"
if [ "$rc" != 0 ]; then pass "N4 a store the keyring did not keep fails the run (exit $rc)"; else fail "N4 the run exited 0"; fi
has "N4 the entry stays whole" "GGS_MQTT_PASS='CANARY-mq-" "$(cat "$TMP/st/.env")"
if [ "$(grep -c "^'$" "$TMP/st/.env")" = 1 ]; then pass "N4 its closing quote stays with it"; else fail "N4 the closing quote line is gone"; fi
lacks "N4 a name that did not reach the keyring is not unset" "unset-environment GGS_MQTT_PASS" "$(cat "$SYSTEMCTL_LOG")"
no_canary "N4 no value printed" "$out"
# N5: --unowned moves every unowned name.
fixture_9360
APPLY_ARGS="-y --unowned" apply_tty y "$SYSPATH"
if [ "$rc" = 0 ]; then pass "N5 --unowned apply exits 0"; else fail "N5 --unowned apply exited $rc: $out"; fi
for n in GGS_MQTT_PASS OTHER_TOOL_TOKEN PLAIN_UNOWNED; do
    lacks "N5 $n left .env" "$n=" "$(cat "$TMP/st/.env")"
done
if [ "$(grep -c 'CANARY-\(mq\|other\|plain\)' "$KSTUB_STORE")" = 3 ]; then pass "N5 the three values are in the keyring"; else fail "N5 the keyring does not hold the three values"; fi
no_canary "N5 no value printed" "$out"
# N8: a himmel secret named beside an unowned one is no error; both move.
fixture_9360
APPLY_ARGS="-y --keys READ_SECRET,GGS_MQTT_PASS" apply_tty y "$SYSPATH"
if [ "$rc" = 0 ]; then pass "N8 naming a himmel secret beside an unowned one exits 0"; else fail "N8 exited $rc: $out"; fi
lacks "N8 the himmel secret moved" "READ_SECRET=" "$(cat "$TMP/st/.env")"
lacks "N8 the unowned entry moved" "GGS_MQTT_PASS" "$(cat "$TMP/st/.env")"
# N9: a name .env.example lists but the secrets manifest does not (the station's bot token) is the user's to name.
fxadd "$FX/.env.example" 'EXAMPLE_ONLY_SECRET=\n'
fixture_9360
fxadd "$TMP/st/.env" "EXAMPLE_ONLY_SECRET='%s\n'\n" "$(canary ex)"
apply_tty y "$SYSPATH"
has "N9 -y alone leaves a name outside the manifest" "EXAMPLE_ONLY_SECRET='CANARY-ex-" "$(cat "$TMP/st/.env")"
fixture_9360
fxadd "$TMP/st/.env" "EXAMPLE_ONLY_SECRET='%s\n'\n" "$(canary ex)"
APPLY_ARGS="-y --keys EXAMPLE_ONLY_SECRET" apply_tty y "$SYSPATH"
if [ "$rc" = 0 ]; then pass "N9 --keys on it exits 0"; else fail "N9 exited $rc: $out"; fi
lacks "N9 the named entry left .env" "EXAMPLE_ONLY_SECRET" "$(cat "$TMP/st/.env")"
if grep -q 'CANARY-ex' "$KSTUB_STORE" 2>/dev/null; then pass "N9 its value is in the keyring"; else fail "N9 its value is not in the keyring"; fi
has "N9 unset-environment for it" "systemctl --user unset-environment EXAMPLE_ONLY_SECRET" "$(cat "$SYSTEMCTL_LOG")"
printf '# READ_SECRET=\nUNREAD_SECRET=\nKEEP_ME=\nJIRA_API_TOKEN=\nBITBUCKET_API_TOKEN=\n' > "$FX/.env.example" || fail "N9 restoring the fixture .env.example failed"
# N10: a retained entry whose quoted value holds a NAME=value line is not read as an entry: the real
# entry is the one stored and removed, and the retained value stays whole.
fixture_9360
{ printf "KEEP_NOTE='first line\nGGS_MQTT_PASS=INNER-CANARY\nlast'\n"; cat "$TMP/st/.env"; } > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "$SYSPATH"
if [ "$rc" = 0 ]; then pass "N10 apply exits 0"; else fail "N10 apply exited $rc: $out"; fi
if grep -q 'CANARY-mq' "$KSTUB_STORE" 2>/dev/null && ! grep -q 'INNER-CANARY' "$KSTUB_STORE" 2>/dev/null; then pass "N10 the real value is stored, not the embedded line"; else fail "N10 the keyring holds the wrong value"; fi
has "N10 the retained value keeps its embedded line" "GGS_MQTT_PASS=INNER-CANARY" "$(cat "$TMP/st/.env")"
has "N10 the retained value keeps its last line" "last'" "$(cat "$TMP/st/.env")"
lacks "N10 the real entry left" "GGS_MQTT_PASS='CANARY-mq" "$(cat "$TMP/st/.env")"
# N11: an unset whose read-back fails is not reported as an empty manager.
fixture_9360
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "SYS_READBACK_FAIL=1 $SYSPATH"
if [ "$rc" != 0 ]; then pass "N11 a failed read-back fails the run (exit $rc)"; else fail "N11 the run exited 0"; fi
has "N11 the report says it could not read the manager back" "could not be read back" "$out"
lacks "N11 it does not claim the manager holds none" "still holds 0" "$out"
# N12: an item the keyring already holds is never replaced. A store here replaces the item with
# the same attributes, as libsecret does (the shared stub only appends), so a probe-less store
# would overwrite a newer keyring value with the file's older one.
mkdir -p "$TMP/rbin"
cat > "$TMP/rbin/secret-tool" <<'STUB' || fail "fixture write of the replacing secret-tool failed"
#!/usr/bin/env bash
if [ "$1" = store ]; then
    orig=("$@"); shift 3; q=""
    while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
    if [ -f "$KSTUB_STORE" ]; then
        awk -F '\t' -v a="${q# }" '$1 != a' "$KSTUB_STORE" > "$KSTUB_STORE.r" && mv -f "$KSTUB_STORE.r" "$KSTUB_STORE"
    fi
    exec "$KBIN/secret-tool" "${orig[@]}"
fi
exec "$KBIN/secret-tool" "$@"
STUB
chmod +x "$TMP/rbin/secret-tool"
export KBIN
RPATH="PATH=$TMP/rbin:$TMP/sbin:$PATH "
fixture_9360
kitem GGS_MQTT_PASS "$(canary newer)"
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "$RPATH"
if [ "$rc" = 0 ]; then pass "N12 a held name does not fail the run"; else fail "N12 exited $rc: $out"; fi
if grep -q 'CANARY-newer' "$KSTUB_STORE" 2>/dev/null && ! grep -q 'CANARY-mq' "$KSTUB_STORE" 2>/dev/null; then pass "N12 the newer keyring value was not replaced"; else fail "N12 the keyring value was replaced"; fi
has "N12 the entry stays in .env" "GGS_MQTT_PASS='CANARY-mq-" "$(cat "$TMP/st/.env")"
has "N12 the report says held" "held GGS_MQTT_PASS" "$out"
lacks "N12 a held name is not cleared from the manager" "unset-environment GGS_MQTT_PASS" "$(cat "$SYSTEMCTL_LOG")"
no_canary "N12 no value printed" "$out"
# N12b: the same value already in the keyring lets the entry leave, with nothing stored twice.
fixture_9360
n12v=$(sed -n "s/^GGS_MQTT_PASS='//p" "$TMP/st/.env")
kitem GGS_MQTT_PASS "$n12v"
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "$RPATH"
lacks "N12b the entry left .env" "GGS_MQTT_PASS" "$(cat "$TMP/st/.env")"
if [ "$(grep -c 'key=GGS_MQTT_PASS' "$KSTUB_STORE")" = 1 ] && ! grep -q 'secret-tool store.*GGS_MQTT_PASS' "$KSTUB_LOG"; then pass "N12b nothing was stored again"; else fail "N12b the keyring was written again"; fi
# N13: a NAME= line inside another key's quoted value is not the named key's entry, even when the real entry is one line.
fixture_9360
fxadd "$TMP/st/.env" "NOTE='first\nTOK=EMBEDDED-CANARY\nlast'\nTOK=%s\n" "$(canary tok)"
APPLY_ARGS="-y --keys TOK" apply_tty y "$SYSPATH"
if grep -q 'CANARY-tok' "$KSTUB_STORE" 2>/dev/null && ! grep -q 'EMBEDDED-CANARY' "$KSTUB_STORE" 2>/dev/null; then pass "N13 the real TOK line is the one stored"; else fail "N13 the keyring holds the wrong TOK value"; fi
has "N13 the embedded line stays inside NOTE" "TOK=EMBEDDED-CANARY" "$(cat "$TMP/st/.env")"
lacks "N13 the real TOK line left" "TOK=CANARY-tok" "$(cat "$TMP/st/.env")"
# N14: the printed commands carry this run's --env.
fixture_9360
out=$(bash "$SCRIPT" --dry-run --env "$TMP/st/.env" 2>&1)
has "N14 the --unowned command carries --env" "--env $TMP/st/.env -y --unowned" "$out"
has "N14 the --keys command carries --env" "--env $TMP/st/.env -y --keys NAME" "$out"
# N15: the backups keep a named value and a two-line manifest value in plaintext: the run says so, and does not claim a kept line the keyring lacks.
fixture_9360
grep -v '^BITBUCKET_API_TOKEN=' "$TMP/st/.env" > "$TMP/st/.env.new" && mv "$TMP/st/.env.new" "$TMP/st/.env"
fxadd "$TMP/st/.env" "BITBUCKET_API_TOKEN='%s\n'\n" "$(canary bb2)"
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "$SYSPATH"
has "N15 the report names the entries the backups keep in plaintext" "still hold the entries for" "$out"
has "N15 it names the unowned entry" "GGS_MQTT_PASS" "$(printf '%s\n' "$out" | grep 'still hold the entries for')"
has "N15 it names the two-line manifest entry" "BITBUCKET_API_TOKEN" "$(printf '%s\n' "$out" | grep 'still hold the entries for')"
lacks "N15 it does not say the keyring lacks a value it stored" "keeps a line for BITBUCKET_API_TOKEN" "$out"
# N16: --unowned never moves a process environment name, and the plan lists what it will move.
fixture_9360
fxadd "$TMP/st/.env" 'PATH=/usr/local/bin\nXDG_RUNTIME_DIR=/run/user/1000\n'
out=$(bash "$SCRIPT" --dry-run --unowned --env "$TMP/st/.env" 2>&1)
has "N16 the plan lists the names --unowned will move" "these names move to the keyring" "$out"
has "N16 a plain name is in that list" "PLAIN_UNOWNED" "$(printf '%s\n' "$out" | grep 'these names move to the keyring')"
has "N16 PATH is refused in the plan" "PATH  unowned  stays (a process environment name, never moved)" "$out"
APPLY_ARGS="-y --unowned" apply_tty y "$SYSPATH"
has "N16 PATH stays in .env" "PATH=/usr/local/bin" "$(cat "$TMP/st/.env")"
has "N16 XDG_RUNTIME_DIR stays in .env" "XDG_RUNTIME_DIR=/run/user/1000" "$(cat "$TMP/st/.env")"
lacks "N16 PATH is not cleared from the manager" "unset-environment PATH" "$(cat "$SYSTEMCTL_LOG")"
# N17: a manager that cannot be reached, or that still holds a name, is not a success.
fixture_9360
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "SYS_UNREACHABLE=1 $SYSPATH"
if [ "$rc" != 0 ]; then pass "N17 an unreachable manager fails the run (exit $rc)"; else fail "N17 the run exited 0"; fi
has "N17 the report says nothing was cleared" "not reachable" "$out"
lacks "N17 the entry still left .env" "GGS_MQTT_PASS=" "$(cat "$TMP/st/.env")"
fixture_9360
APPLY_ARGS="-y --keys GGS_MQTT_PASS" apply_tty y "SYS_STICKY=1 $SYSPATH"
if [ "$rc" != 0 ]; then pass "N17 a name the manager still holds fails the run (exit $rc)"; else fail "N17 the run exited 0"; fi
has "N17 the report counts the names still held" "still holds" "$out"
# N6: a name the file does not hold is a usage error with nothing written.
fixture_9360
APPLY_ARGS="-y --keys NOT_IN_THE_FILE" apply_tty y "$SYSPATH"
if [ "$rc" = 2 ]; then pass "N6 a name absent from the file exits 2"; else fail "N6 a name absent from the file exited $rc"; fi
if cmp -s "$TMP/st/.env" "$TMP/st.orig"; then pass "N6 .env is byte-identical"; else fail "N6 .env changed"; fi
# N7: a value with a real newline inside cannot be one keyring item: the entry stays whole, others move.
fixture_9360
fxadd "$TMP/st/.env" "TWO_LINE_VALUE='%s\n%s\n'\n" "$(canary a)" "$(canary b)"
APPLY_ARGS="-y --keys TWO_LINE_VALUE,GGS_MQTT_PASS" apply_tty y "$SYSPATH"
has "N7 the entry with a newline inside stays" "TWO_LINE_VALUE='CANARY-a-" "$(cat "$TMP/st/.env")"
lacks "N7 the other named entry moved" "GGS_MQTT_PASS" "$(cat "$TMP/st/.env")"
if [ "$rc" != 0 ]; then pass "N7 the run reports the entry it kept (exit $rc)"; else fail "N7 the run exited 0"; fi
no_canary "N7 no value printed" "$out"

if [ "$FAILED" -gt 0 ]; then
    echo "test-migrate-env: $FAILED FAILED"
    exit 1
fi
echo "test-migrate-env: all passed"
