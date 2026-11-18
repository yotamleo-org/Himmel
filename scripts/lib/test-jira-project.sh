#!/usr/bin/env bash
# Tests for scripts/lib/jira-project.sh (jira_project_key, jira_mirror_dir).
# Every row runs the resolver in a clean `env -i` shell from a non-git cwd, with the config
# dir, the .env cache dir and HOME all pointed at fixtures, so the operator's own himmel.conf
# and .env never reach a row.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/jira-project.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jp.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
conf="$tmp/conf"
cache="$tmp/cache"
work="$tmp/work"
mkdir -p "$home" "$conf" "$cache" "$work"

# fixture <himmel.conf text> <.env text>: rewrite both files; an empty .env is still a file,
# which keeps the loader off the checkout's own .env.
fixture() {
    printf '%s' "$1" > "$conf/himmel.conf"
    printf '%s' "$2" > "$cache/.env"
}

# run <function> [VAR=value ...]: print the function's stdout, nothing from stderr.
run() {
    local fn="$1"; shift
    # shellcheck disable=SC2016  # the child shell expands $1 and $2, not this one
    (cd "$work" && env -i HOME="$home" PATH="$PATH" HIMMEL_CONFIG_DIR="$conf" HIMMELCTL_CACHE_DIR="$cache" "$@" \
        bash -c 'set -u; . "$1"; "$2"' _ "$LIB" "$fn" 2>/dev/null) # read-sink-ok: LIB is this suite's sibling resolver, derived from $0, never caller input
}

check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$2' got '$3'"; fi
}

echo "== project key =="
fixture 'JIRA_PROJECT_KEY=CONFKEY
' 'JIRA_PROJECT_KEY=DOTKEY
'
check "env wins over himmel.conf and .env" ENVKEY "$(run jira_project_key JIRA_PROJECT_KEY=ENVKEY)"
check "himmel.conf wins over .env" CONFKEY "$(run jira_project_key)"
check "an empty env key falls through to himmel.conf" CONFKEY "$(run jira_project_key JIRA_PROJECT_KEY=)"

fixture '' 'JIRA_PROJECT_KEY=DOTKEY
'
check ".env-only key resolves" DOTKEY "$(run jira_project_key)"

fixture 'JIRA_PROJECT_KEY=CONFKEY
' ''
check "himmel.conf-only key resolves" CONFKEY "$(run jira_project_key)"

fixture '' ''
check "nothing set gives HIMMEL" HIMMEL "$(run jira_project_key)"
check "an empty env key with nothing else gives HIMMEL" HIMMEL "$(run jira_project_key JIRA_PROJECT_KEY=)"

fixture '' 'JIRA_API_TOKEN=s3cret-token-value
JIRA_PROJECT_KEY=DOTKEY
'
check "a secret in .env is never printed" DOTKEY "$(run jira_project_key)"

echo "== an invalid key never reaches a path =="
fixture '' ''
check "a valid key with a digit and underscore is kept (control)" AB_1 "$(run jira_project_key JIRA_PROJECT_KEY=AB_1)"
check "a path-shaped key falls back to HIMMEL" HIMMEL "$(run jira_project_key JIRA_PROJECT_KEY=../x)"
check "a lowercase key falls back to HIMMEL" HIMMEL "$(run jira_project_key JIRA_PROJECT_KEY=himmel)"
check "a key with a space falls back to HIMMEL" HIMMEL "$(run jira_project_key "JIRA_PROJECT_KEY=AB CD")"
check "a key that starts with a digit falls back to HIMMEL" HIMMEL "$(run jira_project_key JIRA_PROJECT_KEY=1AB)"
check "a key with a newline after a valid line falls back to HIMMEL" HIMMEL "$(run jira_project_key "JIRA_PROJECT_KEY=AB
../x")"
check "an invalid key never builds the mirror path" "$home/.himmel/state/jira-mirror/HIMMEL" "$(run jira_mirror_dir JIRA_PROJECT_KEY=../x)"
fixture 'JIRA_PROJECT_KEY=../conf
' ''
check "an invalid himmel.conf key falls back to HIMMEL" HIMMEL "$(run jira_project_key)"
# shellcheck disable=SC2016  # the child shell expands $1, not this one
warn=$(cd "$work" && env -i HOME="$home" PATH="$PATH" HIMMEL_CONFIG_DIR="$conf" HIMMELCTL_CACHE_DIR="$cache" JIRA_PROJECT_KEY=../x \
    bash -c 'set -u; . "$1"; jira_project_key >/dev/null' _ "$LIB" 2>&1 >/dev/null) # read-sink-ok: LIB is this suite's sibling resolver, derived from $0, never caller input
case "$warn" in *"not a valid"*) pass "an invalid key warns on stderr" ;; *) fail "an invalid key warns on stderr: '$warn'" ;; esac
case "$warn" in *"../x"*) fail "the warning leaks the bad value: '$warn'" ;; *) pass "the warning does not echo the value" ;; esac

echo "== mirror dir =="
fixture '' ''
check "default is HOME/.himmel/state/jira-mirror/HIMMEL" "$home/.himmel/state/jira-mirror/HIMMEL" "$(run jira_mirror_dir)"
check "env key names the mirror dir" "$home/.himmel/state/jira-mirror/ENVKEY" "$(run jira_mirror_dir JIRA_PROJECT_KEY=ENVKEY)"
fixture 'JIRA_PROJECT_KEY=CONFKEY
' ''
check "himmel.conf key names the mirror dir" "$home/.himmel/state/jira-mirror/CONFKEY" "$(run jira_mirror_dir)"
check "HIMMEL_JIRA_MIRROR wins" "$tmp/elsewhere" "$(run jira_mirror_dir HIMMEL_JIRA_MIRROR="$tmp/elsewhere" JIRA_PROJECT_KEY=ENVKEY)"
check "an empty HIMMEL_JIRA_MIRROR falls through" "$home/.himmel/state/jira-mirror/CONFKEY" "$(run jira_mirror_dir HIMMEL_JIRA_MIRROR=)"

echo "== configured =="
# configured [VAR=value ...]: yes when jira_project_configured succeeds, else no.
configured() {
    # shellcheck disable=SC2016  # the child shell expands $1, not this one
    (cd "$work" && env -i HOME="$home" PATH="$PATH" HIMMEL_CONFIG_DIR="$conf" HIMMELCTL_CACHE_DIR="$cache" "$@" \
        bash -c 'set -u; . "$1"; if jira_project_configured; then echo yes; else echo no; fi' _ "$LIB" 2>/dev/null) # read-sink-ok: LIB is this suite's sibling resolver, derived from $0, never caller input
}
fixture '' ''
check "nothing set is not configured" no "$(configured)"
check "an empty env key is not configured" no "$(configured JIRA_PROJECT_KEY=)"
check "an env key is configured" yes "$(configured JIRA_PROJECT_KEY=ENVKEY)"
fixture 'JIRA_PROJECT_KEY=CONFKEY
' ''
check "a himmel.conf-only key is configured" yes "$(configured)"
fixture '' 'JIRA_PROJECT_KEY=DOTKEY
'
check "a .env-only key is configured" yes "$(configured)"

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
