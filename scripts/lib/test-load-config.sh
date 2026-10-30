#!/usr/bin/env bash
# Tests for the config layers in scripts/lib/load-dotenv.sh — the behaviour-config / gate-policy
# split out of .env. Hermetic: every case runs with HOME pointed at a temp dir,
# so the operator's real ~/.himmel is never read, except row (h), which proves
# the policy dir ignores HOME, and row (i), which proves it fails closed.
# Each case runs in its own $(...) subshell so exports stay scoped.
# shellcheck disable=SC2030,SC2031,SC2016,SC1090
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/load-dotenv.sh"
SECRETS_HOOK="$HERE/../hooks/block-read-secrets.sh"

FAILED=0
assert_eq_fp() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — got a value of length ${#actual}, sha256 $(printf '%s' "$actual" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
        FAILED=$((FAILED + 1))
    fi
}
assert_has() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "PASS $label" ;;
        *) assert_eq_fp "$label (missing match)" "$needle" "$hay" ;;
    esac
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet
export HOME="$TMP/home"
# The policy dir comes from the account entry; this seam points it back at HOME.
export HIMMEL_POLICY_FOLLOWS_HOME=1
export HIMMEL_REPO="$REPO" HIMMEL_CONFIG_DIR="$HOME/.himmel"
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
export HIMMEL_SECRETS_KEYRING=off CREDENTIALS_DIRECTORY="$TMP/credentials"
mkdir -p "$HOME/.himmel" "$CREDENTIALS_DIRECTORY"
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE HANDOVER_DIR CR_PROFILE
unset JIRA_BASE_URL TELEGRAM_GROUP_CHAT_ID JIRA_API_TOKEN TELEGRAM_BOT_TOKEN
unset GCP_SERVICE_ACCOUNT_KEY SNYK_TOKEN VERCEL_TOKEN ANTHROPIC_API_KEY CONFLUENCE_EMAIL

reset() { rm -f "$HOME/.himmel/"* "$REPO/.env"; }

# run <snippet> — source the loader in a subshell inside the fixture repo.
run() { ( cd "$REPO" && . "$LIB" && eval "$1" ) 2>&1; }

# Exercise a forced failure in a child so its diagnostic never reaches the log.
if [ "${1:-}" = --failure-output-probe ]; then
    sentinel='dummy-config-secret-sentinel-7841'
    printf 'JIRA_API_TOKEN=%s\n' "$sentinel" > "$REPO/.env"
    mkdir -p "$TMP/probe-bin"
    printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$sentinel" > "$TMP/probe-bin/secret-tool"
    chmod +x "$TMP/probe-bin/secret-tool"
    export PATH="$TMP/probe-bin:$PATH" HIMMEL_SECRETS_KEYRING=off
    export HIMMEL_CONFIG_DIR="$HOME/.himmel"
    out=$(run 'unset JIRA_API_TOKEN; load_dotenv --root "$REPO" JIRA_API_TOKEN; printf "[%s]" "${JIRA_API_TOKEN-}"')
    assert_eq_fp "forced secret failure" "[]" "$out"
    exit "$FAILED"
fi
probe_out=$(bash "$0" --failure-output-probe 2>&1)
probe_rc=$?
assert_eq_fp "forced secret failure exits non-zero" "1" "$probe_rc"
case "$probe_out" in
    *dummy-config-secret-sentinel-7841*)
        echo "FAIL forced secret failure does not print the sentinel"
        exit 1 ;;
    *) echo "PASS forced secret failure does not print the sentinel" ;;
esac
assert_has "forced secret failure prints a length" "length " "$probe_out"
assert_has "forced secret failure prints a short hash" "sha256 " "$probe_out"

# Reclassifying only the named service identifiers makes the config layers usable.
identifiers='JIRA_EMAIL JIRA_PROJECTS JIRA_PROJECT_KEY JIRA_CLOUD_ID
GCP_CI_PROJECT_ID SNYK_ORG_ID SNYK_ORG_SLUG
VERCEL_TEAM_ID VERCEL_USER_ID ANTHROPIC_API_ORG_ID_A ANTHROPIC_API_ORG_ID_B'
for k in $identifiers; do
    reset
    assert_eq_fp "$k is config" "config" "$(run '_himmel_key_class "$k"')"
    printf '%s=dummy-legacy\n' "$k" > "$REPO/.env"
    printf '%s=dummy-config\n' "$k" > "$HOME/.himmel/himmel.conf"
    out=$(run 'unset "$k"; load_dotenv "$k"; rc=$?; printf "[%s|rc=%s]" "${!k-}" "$rc"')
    assert_eq_fp "$k loads from config before legacy .env" "[dummy-config|rc=0]" "$out"
    printf '%s=dummy-local\n' "$k" > "$HOME/.himmel/himmel.conf.local"
    out=$(run 'unset "$k"; load_dotenv "$k"; rc=$?; printf "[%s|rc=%s]" "${!k-}" "$rc"')
    assert_eq_fp "$k loads from local override before config" "[dummy-local|rc=0]" "$out"
    out=$(run 'export "$k=dummy-process"; load_dotenv "$k"; rc=$?; printf "[%s|rc=%s]" "${!k-}" "$rc"')
    assert_eq_fp "$k preserves non-empty process env" "[dummy-process|rc=0]" "$out"
done
for k in JIRA_API_TOKEN TELEGRAM_BOT_TOKEN GCP_SERVICE_ACCOUNT_KEY SNYK_TOKEN VERCEL_TOKEN ANTHROPIC_API_KEY CONFLUENCE_EMAIL; do
    reset
    assert_eq_fp "$k remains secret" "secret" "$(run '_himmel_key_class "$k"')"
    printf '%s=dummy-planted\n' "$k" > "$HOME/.himmel/himmel.conf"
    printf '%s=dummy-planted\n' "$k" > "$HOME/.himmel/himmel.conf.local"
    out=$(run 'unset "$k"; load_dotenv "$k"; rc=$?; printf "[%s|rc=%s]" "${!k-}" "$rc"')
    assert_eq_fp "$k is never read from config" "[|rc=0]" "$out"
done

# (a) A gate-policy key set in config.json is NOT overridden by the env.
reset
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1","CR_FLOOR_FALLBACK":"off"}}\n' > "$HOME/.himmel/config.json"
out=$(run 'export CR_REQUIRE_CROSS_MODEL=0 CR_FLOOR_FALLBACK=claude-only; load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK; printf "[%s|%s]" "${CR_REQUIRE_CROSS_MODEL-}" "${CR_FLOOR_FALLBACK-}"')
assert_has "(a) config.json policy beats env override" "[1|off]" "$out"
assert_has "(a) env override is reported as ignored" "ignoring" "$out"

# (a2) An env-only policy value (no file anywhere) is dropped, not honoured.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
out=$(run 'export CR_FLOOR_FALLBACK=claude-only; load_policy --root "$PWD" CR_FLOOR_FALLBACK; printf "[%s|rc=%s]" "${CR_FLOOR_FALLBACK-}" "$?"')
assert_has "(a2) env-only policy value is not honoured" "[|rc=0]" "$out"

# (a3) The fleet cap is gate policy: a config.json value beats an env override.
reset
printf '{"policy":{"HIMMEL_FLEET_CAP":3}}\n' > "$HOME/.himmel/config.json"
out=$(run 'export HIMMEL_FLEET_CAP=50; load_policy --root "$PWD" HIMMEL_FLEET_CAP; printf "[%s|rc=%s]" "${HIMMEL_FLEET_CAP-}" "$?"')
assert_has "(a3) config.json fleet cap beats env override" "[3|rc=0]" "$out"
assert_has "(a3) fleet cap env override is reported as ignored" "ignoring process-env HIMMEL_FLEET_CAP" "$out"

# (b) A legacy .env-only config key still applies, with a deprecation notice.
reset
printf 'HANDOVER_DIR=/legacy/handovers\n' > "$REPO/.env"
out=$(run 'load_dotenv HANDOVER_DIR; printf "[%s]" "${HANDOVER_DIR-}"')
assert_has "(b) legacy .env config key still applies" "[/legacy/handovers]" "$out"
assert_has "(b) legacy .env config key prints a deprecation notice" "DEPRECATED" "$out"

# (b2) A legacy .env-only policy key still applies, with a deprecation notice.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
printf 'CR_REQUIRE_CROSS_MODEL=1\n' > "$REPO/.env"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[%s]" "${CR_REQUIRE_CROSS_MODEL-}"')
assert_has "(b2) legacy .env policy key still applies" "[1]" "$out"
assert_has "(b2) legacy .env policy key prints a deprecation notice" "DEPRECATED" "$out"

# (b2a) A legacy .env fleet cap still applies, and its notice names it a policy
# key to move, not a secret.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
printf 'HIMMEL_FLEET_CAP=6\n' > "$REPO/.env"
out=$(run 'unset HIMMEL_FLEET_CAP; load_policy --root "$PWD" HIMMEL_FLEET_CAP; printf "[%s]" "${HIMMEL_FLEET_CAP-}"')
assert_has "(b2a) legacy .env fleet cap still applies" "[6]" "$out"
assert_has "(b2a) legacy .env fleet cap gets the policy-key notice" "DEPRECATED: HIMMEL_FLEET_CAP read from .env" "$out"

# (b3) A secret key read from .env still loads, with exactly one deprecation
# notice where a keyring CLI exists to move it to (a stub secret-tool here; the
# keyring step itself is off). Darwin has no keyring backend yet, so no notice.
reset
mkdir -p "$TMP/stub-bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/stub-bin/secret-tool"
chmod +x "$TMP/stub-bin/secret-tool"
printf 'JIRA_API_TOKEN=dummy\n' > "$REPO/.env"
out=$(PATH="$TMP/stub-bin:$PATH" HIMMEL_SECRETS_KEYRING=off run 'load_dotenv JIRA_API_TOKEN; printf "[%s]" "${JIRA_API_TOKEN-}"')
want=1; [ "$(uname -s)" = Darwin ] && want=0
assert_has "(b3) legacy .env secret key still loads" "[dummy]" "$out"
assert_eq_fp "(b3) legacy .env secret key prints one deprecation notice" "$want" "$(printf '%s\n' "$out" | grep -c DEPRECATED)"

# (c) Missing config file: safe default (unset) plus a visible notice.
reset
out=$(run 'load_policy --root "$PWD" CR_FLOOR_FALLBACK ARMAUTOMERGE; rc=$?; printf "[%s|%s|%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}" "$rc"')
assert_has "(c) missing config.json gives the safe default" "[||0]" "$out"
assert_has "(c) missing config.json prints a notice" "no ~/.himmel/config.json" "$out"

# (c2) An unparseable config.json fails closed (non-zero), never a default.
reset
printf '{not json\n' > "$HOME/.himmel/config.json"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[rc=%s]" "$?"')
assert_has "(c2) unparseable config.json returns non-zero" "[rc=1]" "$out"

# (c3) A policy value that is not a string, number or boolean fails closed
# rather than reading as unset; a null value or a null .policy is unset.
reset
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":{"on":1}}}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[rc=%s]" "$?"')
assert_has "(c3) a non-scalar policy value returns non-zero" "[rc=1]" "$out"
printf '{"policy":"on"}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[rc=%s]" "$?"')
assert_has "(c3) a non-object .policy returns non-zero" "[rc=1]" "$out"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":null}}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[%s|rc=%s]" "${CR_REQUIRE_CROSS_MODEL-}" "$?"')
assert_has "(c3) a null policy value reads as unset" "[|rc=0]" "$out"
printf '{"version":1,"policy":null}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL; printf "[%s|rc=%s]" "${CR_REQUIRE_CROSS_MODEL-}" "$?"')
assert_has "(c3) a null .policy reads as unset" "[|rc=0]" "$out"

# (e) A policy key planted in the agent-writable himmel.conf is NOT honoured.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
printf 'CR_FLOOR_FALLBACK=claude-only\n' > "$HOME/.himmel/himmel.conf"
printf 'ARMAUTOMERGE=1\n' > "$HOME/.himmel/himmel.conf.local"
out=$(run 'load_policy --root "$PWD" CR_FLOOR_FALLBACK ARMAUTOMERGE; printf "[%s|%s|rc=%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}" "$?"')
assert_has "(e) policy in himmel.conf/.local is not honoured by load_policy" "[||rc=0]" "$out"
out=$(run 'load_dotenv CR_FLOOR_FALLBACK ARMAUTOMERGE; printf "[%s|%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}"')
assert_has "(e) policy in himmel.conf/.local is not honoured by load_dotenv" "[|]" "$out"

# Ordinary keys follow the table: env > .local > himmel.conf > legacy .env.
reset
printf 'CR_PROFILE=from-dotenv\n' > "$REPO/.env"
printf 'CR_PROFILE=from-conf\n' > "$HOME/.himmel/himmel.conf"
out=$(run 'load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq_fp "himmel.conf beats legacy .env, no notice" "[from-conf]" "$out"
printf 'CR_PROFILE=from-local\n' > "$HOME/.himmel/himmel.conf.local"
out=$(run 'load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq_fp ".local beats himmel.conf" "[from-local]" "$out"
out=$(run 'export CR_PROFILE=from-env; load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq_fp "process env wins for an ordinary key" "[from-env]" "$out"

# (p) Profiles: himmel.conf is the DEFAULT profile; a named station profile is
# <vault>/.himmel/profiles/<name>.conf, found beside the link target of
# himmel.conf. Order: env > project > .local > profile > himmel.conf.
MIGRATE="$HERE/../setup/migrate-env-config.sh"
VAULT="$TMP/vault"
mkdir -p "$VAULT/.himmel/profiles"
plink() { ln -s "$VAULT/.himmel/himmel.conf" "$HOME/.himmel/himmel.conf"; }
pload() { run 'unset CR_PROFILE HANDOVER_DIR; load_dotenv CR_PROFILE HANDOVER_DIR; printf "[%s|%s]" "${CR_PROFILE-}" "${HANDOVER_DIR-}"'; }
reset
printf 'CR_PROFILE=from-default\n' > "$VAULT/.himmel/himmel.conf"
printf 'CR_PROFILE=from-lab\n' > "$VAULT/.himmel/profiles/lab.conf"
plink
assert_eq_fp "(p) DEFAULT applies with no station profile" "[from-default|]" "$(pload)"
assert_eq_fp "(p) a named profile overrides DEFAULT" "[from-lab|]" "$(HIMMEL_PROFILE=lab pload)"
printf 'HANDOVER_DIR=/lab/handovers\n' >> "$VAULT/.himmel/profiles/lab.conf"
assert_eq_fp "(p) a profile adds keys DEFAULT lacks" "[from-lab|/lab/handovers]" "$(HIMMEL_PROFILE=lab pload)"
printf 'HIMMEL_PROFILE=lab\n' > "$HOME/.himmel/himmel.conf.local"
assert_eq_fp "(p) himmel.conf.local selects the profile" "[from-lab|/lab/handovers]" "$(pload)"
printf 'HIMMEL_PROFILE=lab\nCR_PROFILE=from-local\n' > "$HOME/.himmel/himmel.conf.local"
assert_eq_fp "(p) .local beats the profile" "[from-local|/lab/handovers]" "$(pload)"
assert_eq_fp "(p) the process env beats the profile" "[from-env|/lab/handovers]" "$(HIMMEL_PROFILE=lab run 'export CR_PROFILE=from-env; unset HANDOVER_DIR; load_dotenv CR_PROFILE HANDOVER_DIR; printf "[%s|%s]" "${CR_PROFILE-}" "${HANDOVER_DIR-}"')"
printf 'HIMMEL_PROFILE=lab\n' > "$HOME/.himmel/himmel.conf.local"
assert_eq_fp "(p) the env profile name beats the .local one" "[from-default|]" "$(HIMMEL_PROFILE=other pload)"
mkdir -p "$VAULT/.himmel/hostile"
printf 'CR_PROFILE=from-escape\n' > "$VAULT/.himmel/hostile/x.conf"
assert_eq_fp "(p) a path-shaped profile name is ignored" "[from-default|]" "$(HIMMEL_PROFILE=../hostile/x pload)"
reset
printf 'CR_PROFILE=from-plain\n' > "$HOME/.himmel/himmel.conf"
assert_eq_fp "(p) a plain himmel.conf has no profiles dir" "[from-plain|]" "$(HIMMEL_PROFILE=lab pload)"
# A policy or secret key in a station profile is refused (trusted-file bridge).
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
printf 'CR_FLOOR_FALLBACK=claude-only\nARMAUTOMERGE=1\nJIRA_API_TOKEN=planted\n' > "$VAULT/.himmel/profiles/lab.conf"
: > "$VAULT/.himmel/himmel.conf"
plink
out=$(HIMMEL_PROFILE=lab run 'load_policy --root "$PWD" CR_FLOOR_FALLBACK ARMAUTOMERGE; printf "[%s|%s|rc=%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}" "$?"')
assert_has "(p) a policy key in a station profile is not honoured by load_policy" "[||rc=0]" "$out"
out=$(HIMMEL_PROFILE=lab run 'unset JIRA_API_TOKEN; load_dotenv CR_FLOOR_FALLBACK ARMAUTOMERGE JIRA_API_TOKEN; printf "[%s|%s|%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}" "${JIRA_API_TOKEN-}"')
assert_has "(p) policy and secret keys in a station profile are not honoured by load_dotenv" "[||]" "$out"
# The profile step creates <vault>/.himmel and the profile file, and links DEFAULT.
reset
rm -rf "$TMP/newvault"
out=$(bash "$MIGRATE" --vault "$TMP/newvault" --profile lab 2>&1); rc=$?
assert_eq_fp "(p) the profile step exits 0 with no .env" "0" "$rc"
assert_eq_fp "(p) the profile step creates <vault>/.himmel/profiles/<name>.conf" "yes" "$([ -f "$TMP/newvault/.himmel/profiles/lab.conf" ] && echo yes)"
assert_eq_fp "(p) the profile step links himmel.conf into the vault" "$TMP/newvault/.himmel/himmel.conf" "$(readlink "$HOME/.himmel/himmel.conf")"
printf 'CR_PROFILE=from-new-lab\n' > "$TMP/newvault/.himmel/profiles/lab.conf"
assert_eq_fp "(p) a profile the step created is read" "[from-new-lab|]" "$(HIMMEL_PROFILE=lab pload)"
printf 'CR_PROFILE=kept\n' > "$TMP/newvault/.himmel/profiles/lab.conf"
bash "$MIGRATE" --profile lab >/dev/null 2>&1; rc=$?
assert_eq_fp "(p) re-running the step on a linked vault succeeds" "0" "$rc"
assert_eq_fp "(p) re-running the step keeps the profile's keys" "CR_PROFILE=kept" "$(cat "$TMP/newvault/.himmel/profiles/lab.conf")"
reset
bash "$MIGRATE" --profile lab >/dev/null 2>&1; rc=$?
assert_eq_fp "(p) the profile step with no vault and no link exits 2" "2" "$rc"
bash "$MIGRATE" --vault "$TMP/v2" --profile ../x >/dev/null 2>&1; rc=$?
assert_eq_fp "(p) the profile step refuses a path-shaped name" "2" "$rc"
assert_eq_fp "(p) a refused name creates no vault dir" "" "$([ -e "$TMP/v2" ] && echo exists)"
: > "$TMP/blocker"
out=$(bash "$MIGRATE" --vault "$TMP/blocker/v" --profile lab 2>&1); rc=$?
assert_eq_fp "(p) a vault dir that cannot be created exits 1" "1" "$rc"
assert_eq_fp "(p) a failed profile step does not report created" "" "$(printf '%s' "$out" | grep '^created ')"

# A policy key requested through load_dotenv (advisory readers) comes from
# config.json, and the process env still wins there (only load_policy ignores it).
reset
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":true}}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_dotenv CR_REQUIRE_CROSS_MODEL; printf "[%s]" "${CR_REQUIRE_CROSS_MODEL-}"')
assert_eq_fp "load_dotenv reads a policy key from config.json" "[true]" "$out"

# A secret key is never read from himmel.conf (secrets stay in .env only).
reset
printf 'JIRA_API_TOKEN=planted\n' > "$HOME/.himmel/himmel.conf"
out=$(run 'load_dotenv JIRA_API_TOKEN; printf "[%s]" "${JIRA_API_TOKEN-}"')
assert_eq_fp "secret key is not read from himmel.conf" "[]" "$out"

# (d) block-read-secrets still refuses .env and allows the new config file.
hook() { printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$1" "$2" "$3" | bash "$SECRETS_HOOK" >/dev/null 2>&1; echo $?; }
assert_eq_fp "(d) Bash cat .env is denied" "2" "$(hook Bash command 'cat .env')"
assert_eq_fp "(d) Bash cat ~/.himmel/himmel.conf is allowed" "0" "$(hook Bash command 'cat ~/.himmel/himmel.conf')"
assert_eq_fp "(d) Bash cat himmel.conf.local is allowed" "0" "$(hook Bash command 'cat ~/.himmel/himmel.conf.local')"
assert_eq_fp "(d) Read of himmel.conf is allowed" "0" "$(hook Read file_path "$HOME/.himmel/himmel.conf")"
assert_eq_fp "(d) Read of .env is denied" "2" "$(hook Read file_path "$REPO/.env")"

# (f) The tracked templates only name keys of their own class, so an adopter
# who copies them never parks a policy key in himmel.conf or a secret anywhere.
CONF_TEMPLATE="$HERE/../../docs/setup/himmel.conf.example"
POLICY_TEMPLATE="$HERE/../../docs/setup/himmel-config.example.json"
conf_keys=$(sed -nE 's/^#?[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$CONF_TEMPLATE" 2>/dev/null | sort -u)
policy_keys=$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(d.policy||{}).join("\n"))' "$POLICY_TEMPLATE" 2>/dev/null)
bad=""
for k in $conf_keys; do
    [ "$(run '_himmel_key_class "$k"')" = config ] || bad="$bad $k"
done
assert_eq_fp "(f) himmel.conf.example names only behaviour keys" "yes|" "$([ -n "$conf_keys" ] && echo yes)|$bad"
registry_conf_keys=$(awk '/^_himmel_key_class\(\)/{f=1} f&&/printf .config./{exit} f' "$LIB" \
    | sed -n '/HANDOVER_DIR/,$p' | tr -d ' \\)' | tr '|' '\n' | sed '/^$/d' | sort -u)
assert_eq_fp "(f) himmel.conf.example names every behaviour key" "$registry_conf_keys" "$conf_keys"
bad=""
for k in $policy_keys; do
    [ "$(run '_himmel_key_class "$k"')" = policy ] || bad="$bad $k"
done
assert_eq_fp "(f) himmel-config.example.json .policy names only policy keys" "yes|" "$([ -n "$policy_keys" ] && echo yes)|$bad"

# (g) The deprecation notice names the migration script as runnable now.
out=$(run '_himmel_deprecation_notice HANDOVER_DIR')
case "$out" in
    *"once setup reads"*) assert_eq_fp "(g) deprecation notice is current" "no stale clause" "$out" ;;
    *) assert_has "(g) deprecation notice is current" "migrate-env-config.sh" "$out" ;;
esac

# (h) Without the seam the policy dir is the account's home from its passwd
# entry, not HOME: a HOME holding a permissive policy file is not the one read.
# Reads the account's real policy file, read-only, and asserts only that the
# canary planted under HOME did not win.
acct_home=$(node -e 'process.stdout.write(require("os").userInfo().homedir)')
mkdir -p "$TMP/evil/.himmel"
printf '{"version":1,"policy":{"CR_FLOOR_FALLBACK":"CANARY-evil-floor"}}\n' > "$TMP/evil/.himmel/config.json"
out=$(unset HIMMEL_POLICY_FOLLOWS_HOME; HOME="$TMP/evil" run '_himmel_policy_dir')
assert_eq_fp "(h) the policy dir ignores HOME" "$acct_home/.himmel" "$out"
out=$(unset HIMMEL_POLICY_FOLLOWS_HOME; HOME="$TMP/evil" run 'load_policy --root "$REPO" CR_FLOOR_FALLBACK >/dev/null 2>&1; printf "rc=%s[%s]" "$?" "${CR_FLOOR_FALLBACK-}"')
case "$out" in
    *CANARY-evil-floor*) assert_eq_fp "(h) load_policy does not read a HOME-planted policy file" "not the canary" "$out" ;;
    rc=0\[*) echo "PASS (h) load_policy does not read a HOME-planted policy file" ;;
    *) assert_eq_fp "(h) load_policy succeeds with a HOME-planted policy file" "rc=0" "$out" ;;
esac
out=$(HOME="$TMP/evil" run '_himmel_policy_dir')
assert_eq_fp "(h) the seam points the policy dir at HOME" "$TMP/evil/.himmel" "$out"

# (i) With no passwd entry for the account there is no policy dir: load_policy
# fails closed instead of reading HOME. A user namespace runs the reader as a
# uid no passwd entry names.
nouid=""
for u in 54321 54329 61234 61239; do
    command -p getent passwd "$u" >/dev/null 2>&1 || { nouid=$u; break; }
done
if [ -n "$nouid" ] && unshare --user --map-user="$nouid" true 2>/dev/null; then
    out=$(unset HIMMEL_POLICY_FOLLOWS_HOME; cd "$REPO" && HOME="$TMP/evil" unshare --user --map-user="$nouid" bash -c '
        . "$1"; _himmel_policy_dir >/dev/null; printf "dir=%s|" "$?" # read-sink-ok: $1 is this repo LIB, set above
        load_policy --root "$PWD" CR_FLOOR_FALLBACK >/dev/null 2>&1; printf "policy=%s[%s]" "$?" "${CR_FLOOR_FALLBACK-}"' _ "$LIB" 2>/dev/null)
    assert_eq_fp "(i) with no passwd entry the policy dir and load_policy fail closed" "dir=1|policy=1[]" "$out"
else
    echo "SKIP (i) no user namespace to run as a uid with no passwd entry"
fi

if [ "$FAILED" -gt 0 ]; then
    echo "test-load-config: $FAILED FAILED"
    exit 1
fi
echo "test-load-config: all passed"
