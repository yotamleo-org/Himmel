#!/usr/bin/env bash
# Tests for scripts/lib/load-config.sh — the behaviour-config / gate-policy
# split out of .env. Hermetic: every case runs with HOME pointed at a temp dir,
# so the operator's real ~/.himmel is never read.
# Each case runs in its own $(...) subshell so exports stay scoped.
# shellcheck disable=SC2030,SC2031,SC2016,SC1090
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/load-dotenv.sh"
SECRETS_HOOK="$HERE/../hooks/block-read-secrets.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}
assert_has() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — missing '$needle' in: $hay"; FAILED=$((FAILED + 1)) ;;
    esac
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet
export HOME="$TMP/home"
export HIMMELCTL_CACHE_DIR="$TMP/no-cache"
mkdir -p "$HOME/.himmel"
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE HANDOVER_DIR CR_PROFILE

reset() { rm -f "$HOME/.himmel/"* "$REPO/.env"; }

# run <snippet> — source the loader in a subshell inside the fixture repo.
run() { ( cd "$REPO" && . "$LIB" && eval "$1" ) 2>&1; }

# (a) A gate-policy key set in config.json is NOT overridden by the env.
reset
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1","CR_FLOOR_FALLBACK":"off"}}\n' > "$HOME/.himmel/config.json"
out=$(run 'export CR_REQUIRE_CROSS_MODEL=0 CR_FLOOR_FALLBACK=claude-only; load_policy --root "$PWD" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK; printf "[%s|%s]" "${CR_REQUIRE_CROSS_MODEL-}" "${CR_FLOOR_FALLBACK-}"')
assert_has "(a) config.json policy beats env override" "[1|off]" "$out"
assert_has "(a) env override is reported as ignored" "ignoring" "$out"

# (a2) An env-only policy value (no file anywhere) is dropped, not honoured.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
out=$(run 'export CR_FLOOR_FALLBACK=claude-only; load_policy --root "$PWD" CR_FLOOR_FALLBACK; printf "[%s]" "${CR_FLOOR_FALLBACK-}"')
assert_has "(a2) env-only policy value is not honoured" "[]" "$out"

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

# (b3) A secret key read from .env prints NO deprecation notice.
reset
printf 'JIRA_API_TOKEN=dummy\n' > "$REPO/.env"
out=$(run 'load_dotenv JIRA_API_TOKEN; printf "[%s]" "${JIRA_API_TOKEN-}"')
assert_eq "(b3) secret key loads from .env silently" "[dummy]" "$out"

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

# (e) A policy key planted in the agent-writable himmel.conf is NOT honoured.
reset
printf '{"version":1}\n' > "$HOME/.himmel/config.json"
printf 'CR_FLOOR_FALLBACK=claude-only\n' > "$HOME/.himmel/himmel.conf"
printf 'ARMAUTOMERGE=1\n' > "$HOME/.himmel/himmel.conf.local"
out=$(run 'load_policy --root "$PWD" CR_FLOOR_FALLBACK ARMAUTOMERGE; printf "[%s|%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}"')
assert_has "(e) policy in himmel.conf/.local is not honoured by load_policy" "[|]" "$out"
out=$(run 'load_dotenv CR_FLOOR_FALLBACK ARMAUTOMERGE; printf "[%s|%s]" "${CR_FLOOR_FALLBACK-}" "${ARMAUTOMERGE-}"')
assert_has "(e) policy in himmel.conf/.local is not honoured by load_dotenv" "[|]" "$out"

# Ordinary keys follow the table: env > .local > himmel.conf > legacy .env.
reset
printf 'CR_PROFILE=from-dotenv\n' > "$REPO/.env"
printf 'CR_PROFILE=from-conf\n' > "$HOME/.himmel/himmel.conf"
out=$(run 'load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq "himmel.conf beats legacy .env, no notice" "[from-conf]" "$out"
printf 'CR_PROFILE=from-local\n' > "$HOME/.himmel/himmel.conf.local"
out=$(run 'load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq ".local beats himmel.conf" "[from-local]" "$out"
out=$(run 'export CR_PROFILE=from-env; load_dotenv CR_PROFILE; printf "[%s]" "${CR_PROFILE-}"')
assert_eq "process env wins for an ordinary key" "[from-env]" "$out"

# A policy key requested through load_dotenv (advisory readers) comes from
# config.json, and the process env still wins there (only load_policy ignores it).
reset
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":true}}\n' > "$HOME/.himmel/config.json"
out=$(run 'load_dotenv CR_REQUIRE_CROSS_MODEL; printf "[%s]" "${CR_REQUIRE_CROSS_MODEL-}"')
assert_eq "load_dotenv reads a policy key from config.json" "[true]" "$out"

# A secret key is never read from himmel.conf (secrets stay in .env only).
reset
printf 'JIRA_API_TOKEN=planted\n' > "$HOME/.himmel/himmel.conf"
out=$(run 'load_dotenv JIRA_API_TOKEN; printf "[%s]" "${JIRA_API_TOKEN-}"')
assert_eq "secret key is not read from himmel.conf" "[]" "$out"

# (d) block-read-secrets still refuses .env and allows the new config file.
hook() { printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$1" "$2" "$3" | bash "$SECRETS_HOOK" >/dev/null 2>&1; echo $?; }
assert_eq "(d) Bash cat .env is denied" "2" "$(hook Bash command 'cat .env')"
assert_eq "(d) Bash cat ~/.himmel/himmel.conf is allowed" "0" "$(hook Bash command 'cat ~/.himmel/himmel.conf')"
assert_eq "(d) Bash cat himmel.conf.local is allowed" "0" "$(hook Bash command 'cat ~/.himmel/himmel.conf.local')"
assert_eq "(d) Read of himmel.conf is allowed" "0" "$(hook Read file_path "$HOME/.himmel/himmel.conf")"
assert_eq "(d) Read of .env is denied" "2" "$(hook Read file_path "$REPO/.env")"

if [ "$FAILED" -gt 0 ]; then
    echo "test-load-config: $FAILED FAILED"
    exit 1
fi
echo "test-load-config: all passed"
