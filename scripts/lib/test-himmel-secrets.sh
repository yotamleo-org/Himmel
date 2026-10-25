#!/usr/bin/env bash
# Tests for scripts/lib/himmel-secrets, the secret resolver. Every row runs
# against a stub keyring (secret-tool and busctl first on PATH) and fake key
# names; none reaches a real keyring.
# shellcheck disable=SC2030,SC2031
set -uo pipefail

HS="$(cd "$(dirname "$0")" && pwd)/himmel-secrets"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-secrets.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# Stub keyring: one `attrs<TAB>value` line per item; a lookup or search matches
# an item holding every queried attribute, as libsecret does.
KBIN="$TMP/kbin"
mkdir -p "$KBIN"
export KSTUB_STORE="$TMP/keyring.tsv" KSTUB_LOG="$TMP/keyring.log" KSTUB_LOCKED=false
cat >"$KBIN/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$KSTUB_LOG"
verb="$1"; shift
[ "${1:-}" = --all ] && shift
if [ "$verb" = store ]; then shift 2; fi
q=""
while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
case "$verb" in
    store) IFS= read -r val || true; printf '%s\t%s\n' "${q# }" "$val" >>"$KSTUB_STORE"; exit 0 ;;
    lookup) [ -z "${KSTUB_LOOKUP_FAIL:-}" ] || exit 1 ;;
    search) [ -z "${KSTUB_SEARCH_FAIL:-}" ] || { echo 'secret-tool: stub failure' >&2; exit 1; } ;;
esac
rc=1
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    [ "$m" = 1 ] || continue
    case "$verb" in
        lookup) printf '%s' "$val"; exit 0 ;;
        # As libsecret's secret-tool.c: the item lines and the secret go to
        # stdout (g_print), the attribute lines to stderr (g_printerr).
        search)
            printf '[/stub]\nlabel = stub\nsecret = %s\n' "$val"
            for p in $attrs; do printf 'attribute.%s = %s\n' "${p%%=*}" "${p#*=}" >&2; done
            rc=0 ;;
    esac
done <"$KSTUB_STORE"
# A search that matches nothing exits 0, as libsecret's does.
[ "$verb" = search ] && exit 0
exit "$rc"
STUB
cat >"$KBIN/busctl" <<'STUB'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >>"$KSTUB_LOG"
case "$*" in *" Locked") echo "b ${KSTUB_LOCKED:-false}" ;; esac
STUB
chmod +x "$KBIN/secret-tool" "$KBIN/busctl"
export PATH="$KBIN:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/stub-bus"
unset CREDENTIALS_DIRECTORY HIMMEL_SECRETS_KEYRING
kreset() { : >"$KSTUB_STORE"; : >"$KSTUB_LOG"; }

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet
PROJ=$(cd "$REPO" && pwd -P)

if [ "$(uname -s)" = Darwin ]; then
    echo "SKIP S1-S9: the resolver skips the keyring on Darwin (macOS Keychain backend is a follow-up)"
else

# S1: get prints NAME=value from the keyring; a key nobody holds prints
# nothing and exits 1; a bad name is a usage error.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && unset TEST_HS_A && "$HS" get TEST_HS_A)
assert_eq "S1 get prints NAME=value" "TEST_HS_A=fake-a" "$got"
got=$(cd "$REPO" && unset TEST_HS_NONE && "$HS" get TEST_HS_NONE 2>/dev/null; echo "rc=$?")
assert_eq "S1 an unheld key prints nothing, rc 1" "rc=1" "$got"
got=$(cd "$REPO" && "$HS" get ../etc 2>/dev/null; echo "rc=$?")
assert_eq "S1 a bad key name is refused, rc 2" "rc=2" "$got"

# S2: status names the serving layer and never prints a value.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
printf 'service=himmel key=TEST_HS_B project=%s\tfake-b\n' "$PROJ" >>"$KSTUB_STORE"
out=$(cd "$REPO" && unset TEST_HS_A TEST_HS_B && export TEST_HS_C=fake-c && "$HS" status TEST_HS_A TEST_HS_B TEST_HS_C TEST_HS_NONE 2>&1)
assert_eq "S2 status names each layer" "keyring: unlocked|TEST_HS_A: keyring|TEST_HS_B: keyring-project|TEST_HS_C: env|TEST_HS_NONE: unset" "$(printf '%s' "$out" | tr '\n' '|')"
out=$(cd "$REPO" && "$HS" status 2>&1)
assert_eq "S2 bare status lists the user items by name" "keyring: unlocked|keyring item: TEST_HS_A" "$(printf '%s' "$out" | tr '\n' '|')"
assert_eq "S2 status prints no value" "0" "$(printf '%s' "$out" | grep -c 'fake-')"
out=$(cd "$REPO" && export KSTUB_SEARCH_FAIL=1 && "$HS" status 2>&1)
assert_eq "S2 bare status reports a failed listing" "keyring: unlocked|keyring items: the listing failed" "$(printf '%s' "$out" | tr '\n' '|' | sed 's/|$//')"

# S3: exec adds only the listed keys to the child.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
printf 'service=himmel key=TEST_HS_D scope=user\tfake-d\n' >>"$KSTUB_STORE"
# shellcheck disable=SC2016 # expands in the child
got=$(cd "$REPO" && unset TEST_HS_A TEST_HS_D && "$HS" exec --keys TEST_HS_A -- bash -c 'printf "%s|%s" "${TEST_HS_A:-<unset>}" "${TEST_HS_D:-<unset>}"')
assert_eq "S3 exec passes only the listed keys" "fake-a|<unset>" "$got"

# S4: put stores a user default, or a project override with --project.
kreset
out=$(cd "$REPO" && printf 'fake-put' | "$HS" put --stdin TEST_HS_P)
assert_eq "S4 put reports the name only" "stored TEST_HS_P" "$out"
assert_eq "S4 put stores a user default" "service=himmel key=TEST_HS_P scope=user	fake-put" "$(cat "$KSTUB_STORE")"
kreset
(cd "$REPO" && printf 'fake-proj' | "$HS" put --project --stdin TEST_HS_P >/dev/null)
assert_eq "S4 put --project stores a project override" "service=himmel key=TEST_HS_P project=$PROJ	fake-proj" "$(cat "$KSTUB_STORE")"

# S5: import-env stores only the manifest's secret keys and prints names, never values.
kreset
printf 'FIRECRAWL_API_KEY=fake-first\nfake frag ment=fake-tail\n' >"$TMP/in-ml.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-ml.env" 2>&1)
assert_eq "S5 import-env prints no fragment of a multi-line value" "0" "$(printf '%s' "$out" | grep -c 'fake\|frag')"
assert_eq "S5 import-env names a line that is no known key by its number" "1" "$(printf '%s' "$out" | grep -c '^skipped line 2 (not a known secret key)$')"
# shellcheck disable=SC2016 # a literal backtick-quoted value
printf 'TELEGRAM_BOT_TOKEN=`-----BEGIN FAKE KEY-----\nfakeKeyBody\nabcDEF123==\n-----END FAKE KEY-----`\n' >"$TMP/in-pem-bt.env"
printf 'TELEGRAM_BOT_TOKEN=-----BEGIN FAKE KEY-----\nfakeKeyBody\nabcDEF123==\n-----END FAKE KEY-----\n' >"$TMP/in-pem-uq.env"
printf 'TELEGRAM_BOT_TOKEN="\\"-----BEGIN FAKE KEY-----\nfakeKeyBody\nabcDEF123==\n-----END FAKE KEY-----\\""\n' >"$TMP/in-pem-esc.env"
for _s5_f in bt uq esc; do
    kreset
    out=$(cd "$REPO" && "$HS" import-env "$TMP/in-pem-$_s5_f.env" 2>&1)
    assert_eq "S5 import-env ($_s5_f PEM) prints no PEM line" "0" "$(printf '%s' "$out" | grep -c 'abcDEF\|fakeKey')"
    assert_eq "S5 import-env ($_s5_f PEM) names the base64 line by number only" "1" "$(printf '%s' "$out" | grep -c '^skipped line 3 (not a known secret key)$')"
    assert_eq "S5 import-env ($_s5_f PEM) stores no PEM line as a key" "0" "$(grep -c 'key=abcDEF' "$KSTUB_STORE")"
done
kreset
printf 'FIRECRAWL_API_KEY=fake-a\nTEST_HS_K="-----BEGIN FAKE KEY-----\nfakeKeyBody\nabcDEF123==\n-----END FAKE KEY-----"\n' >"$TMP/in-pem.env"
got=$(cd "$REPO" && "$HS" import-env "$TMP/in-pem.env" >"$TMP/s5pem.out" 2>&1; echo "rc=$?")
assert_eq "S5 import-env refuses a file with a quoted value that does not close on its line" "rc=2" "$got"
assert_eq "S5 import-env names only the opening line of an unclosed quote" "1" "$(grep -c 'line 2 opens a quoted value' "$TMP/s5pem.out")"
assert_eq "S5 import-env prints no continuation line" "0" "$(grep -c 'abcDEF\|fakeKey\|FAKE' "$TMP/s5pem.out")"
assert_eq "S5 import-env stores nothing from a refused file" "0" "$(grep -c . "$KSTUB_STORE")"
kreset
printf '# comment\nFIRECRAWL_API_KEY=fake-a\nHANDOVER_DIR=/c/h\nJIRA_API_TOKEN=\nTELEGRAM_BOT_TOKEN = "fake-b" # gutter\nJIRA_EMAIL=fake@example.invalid\nTEST_HS_U=fake-u\n' >"$TMP/in.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in.env" 2>&1)
assert_eq "S5 import-env prints names only" "0" "$(printf '%s' "$out" | grep -c 'fake')"
assert_eq "S5 import-env skips a name the manifest does not list, by line number" "2" "$(printf '%s' "$out" | grep -c '^skipped line [37] (not a known secret key)$')"
assert_eq "S5 import-env skips the manifest's config keys" "1" "$(printf '%s' "$out" | grep -c 'skipped JIRA_EMAIL (config key')"
assert_eq "S5 import-env stores the secret keys" "2" "$(grep -c '^service=himmel key=\(FIRECRAWL_API_KEY\|TELEGRAM_BOT_TOKEN\) scope=user' "$KSTUB_STORE")"
assert_eq "S5 import-env stores no other key" "2" "$(grep -c . "$KSTUB_STORE")"

# S6: export-env writes a new 0600 file that round-trips, and refuses to
# overwrite an existing one.
out=$(cd "$REPO" && "$HS" export-env "$TMP/out.env" 2>&1)
assert_eq "S6 export-env prints no value" "0" "$(printf '%s' "$out" | grep -c 'fake-')"
assert_eq "S6 export-env round-trips" "FIRECRAWL_API_KEY=fake-a|TELEGRAM_BOT_TOKEN=\"fake-b\"" "$(sort "$TMP/out.env" | tr '\n' '|' | sed 's/|$//')"
assert_eq "S6 export-env writes mode 600" "600" "$(stat -c %a "$TMP/out.env" 2>/dev/null || stat -f %Lp "$TMP/out.env")"
got=$(cd "$REPO" && "$HS" export-env "$TMP/out.env" 2>/dev/null; echo "rc=$?")
assert_eq "S6 export-env refuses an existing file" "rc=2" "$got"
got=$(cd "$REPO" && export KSTUB_LOOKUP_FAIL=1 && "$HS" export-env "$TMP/out-miss.env" >/dev/null 2>"$TMP/s6.err"; echo "rc=$?")
assert_eq "S6 export-env fails when a listed item cannot be read" "rc=2" "$got"
assert_eq "S6 export-env names the unread items" "2" "$(grep -c '^skipped [A-Z_]* (lookup failed)' "$TMP/s6.err")"
ln -s "$TMP/s6-target.env" "$TMP/out-link.env"
got=$(cd "$REPO" && "$HS" export-env "$TMP/out-link.env" 2>/dev/null; echo "rc=$?")
assert_eq "S6 export-env refuses a dangling symlink, creates no target" "rc=2|absent" "$got|$([ -e "$TMP/s6-target.env" ] && echo present || echo absent)"
SBIN="$TMP/stat-bin"
mkdir -p "$SBIN"
printf '#!/bin/sh\necho 644\n' >"$SBIN/stat"
chmod +x "$SBIN/stat"
got=$(cd "$REPO" && export PATH="$SBIN:$PATH" && "$HS" export-env "$TMP/out-mode.env" >/dev/null 2>&1; echo "rc=$?")
assert_eq "S6 export-env fails and removes a file whose mode is not 600" "rc=2|absent" "$got|$([ -e "$TMP/out-mode.env" ] && echo present || echo absent)"
FBIN="$TMP/fdstat-bin"
mkdir -p "$FBIN"
# The stub records how many bytes the open file held when its mode was checked.
printf '#!/bin/sh\ncase "$*" in */dev/fd/3*) %s -L -c %%s /dev/fd/3 >>%s; echo 644; exit 0 ;; esac\nexec %s "$@"\n' \
    "$(command -v stat)" "$TMP/fdstat.size" "$(command -v stat)" >"$FBIN/stat"
chmod +x "$FBIN/stat"
got=$(cd "$REPO" && export PATH="$FBIN:$PATH" && "$HS" export-env "$TMP/out-fdmode.env" >/dev/null 2>&1; echo "rc=$?")
assert_eq "S6 export-env checks the mode on the open descriptor before writing" "rc=2|absent|0" "$got|$([ -e "$TMP/out-fdmode.env" ] && echo present || echo absent)|$(cat "$TMP/fdstat.size" 2>/dev/null)"
got=$(cd "$REPO" && export KSTUB_SEARCH_FAIL=1 && "$HS" export-env "$TMP/out-sfail.env" >/dev/null 2>&1; echo "rc=$?")
assert_eq "S6 export-env fails when the keyring listing fails, creates no file" "rc=2|absent" "$got|$([ -e "$TMP/out-sfail.env" ] && echo present || echo absent)"
printf 'service=himmel key=TEST_HS_C scope=user\tfake-c #x\n' >>"$KSTUB_STORE"
printf 'service=himmel key=TEST_HS_D scope=user\tfake-d \n' >>"$KSTUB_STORE"
got=$(cd "$REPO" && "$HS" export-env "$TMP/out-rt.env" >/dev/null 2>"$TMP/s6rt.err"; echo "rc=$?")
assert_eq "S6 export-env fails on a value a .env cannot carry" "rc=2" "$got"
assert_eq "S6 export-env names the values a .env cannot carry" "2" "$(grep -c '^skipped TEST_HS_[CD] (the value would not read back from a .env)' "$TMP/s6rt.err")"
assert_eq "S6 export-env writes no altered value" "0" "$(grep -c 'TEST_HS_[CD]' "$TMP/out-rt.env")"

# S5b: import-env also stores the station secrets a script loads from .env
# outside the wizard's list.
kreset
printf 'GOOGLE_HEALTH_REFRESH_TOKEN=fake-g\nZAI_API_KEY=fake-z\nTELEGRAM_CHAT_ID=fake-t\nhimmel_github_token_vm2=fake-v\n' >"$TMP/in-station.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-station.env" 2>&1)
assert_eq "S5b import-env stores the station secrets" "4" "$(grep -c '^service=himmel key=\(GOOGLE_HEALTH_REFRESH_TOKEN\|ZAI_API_KEY\|TELEGRAM_CHAT_ID\|himmel_github_token_vm2\) scope=user' "$KSTUB_STORE")"
assert_eq "S5b import-env skips none of them" "0" "$(printf '%s' "$out" | grep -c '^skipped')"

# S7: a locked keyring makes no lookup, and put changes nothing.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && export KSTUB_LOCKED=true && unset TEST_HS_A && "$HS" get TEST_HS_A 2>"$TMP/s7.err"; echo "rc=$?")
assert_eq "S7 locked: nothing served" "rc=1" "$got"
assert_eq "S7 locked: one 'keyring locked' line" "1" "$(grep -c 'keyring locked' "$TMP/s7.err")"
assert_eq "S7 locked: no secret-tool call" "0" "$(grep -c '^secret-tool' "$KSTUB_LOG")"
got=$(cd "$REPO" && export KSTUB_LOCKED=true && printf 'x' | "$HS" put --stdin TEST_HS_Q 2>/dev/null; echo "rc=$?")
assert_eq "S7 locked: put refuses, rc 2" "rc=2" "$got"
assert_eq "S7 locked: put stored nothing" "0" "$(grep -c TEST_HS_Q "$KSTUB_STORE")"

# S8: HIMMEL_SECRETS_KEYRING=off and a Darwin uname both skip the keyring.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && export HIMMEL_SECRETS_KEYRING=off && unset TEST_HS_A && "$HS" get TEST_HS_A 2>/dev/null; echo "rc=$?")
assert_eq "S8 HIMMEL_SECRETS_KEYRING=off serves nothing from the keyring" "rc=1" "$got"
assert_eq "S8 HIMMEL_SECRETS_KEYRING=off makes no keyring call" "" "$(cat "$KSTUB_LOG")"
DBIN="$TMP/darwin-bin"
mkdir -p "$DBIN"
printf '#!/bin/sh\necho Darwin\n' >"$DBIN/uname"
chmod +x "$DBIN/uname"
got=$(cd "$REPO" && export PATH="$DBIN:$PATH" && unset TEST_HS_A && "$HS" get TEST_HS_A 2>/dev/null; echo "rc=$?")
assert_eq "S8 Darwin serves nothing from the keyring" "rc=1" "$got"
assert_eq "S8 Darwin makes no keyring call" "" "$(cat "$KSTUB_LOG")"

# S9: $CREDENTIALS_DIRECTORY serves a one-line value and skips a multi-line one.
kreset
CRED="$TMP/creds"
mkdir -p "$CRED"
printf 'fake-cred\n' >"$CRED/TEST_HS_A"
printf 'line1\nline2\n' >"$CRED/TEST_HS_M"
got=$(cd "$REPO" && export CREDENTIALS_DIRECTORY="$CRED" && unset TEST_HS_A && "$HS" get TEST_HS_A)
assert_eq "S9 credentials serve, trailing newline stripped" "TEST_HS_A=fake-cred" "$got"
got=$(cd "$REPO" && export CREDENTIALS_DIRECTORY="$CRED" && unset TEST_HS_M && "$HS" get TEST_HS_M 2>"$TMP/s9.err"; echo "rc=$?")
assert_eq "S9 a multi-line value is skipped" "rc=1" "$got"
assert_eq "S9 the skip line names the key only" "1|0" "$(grep -c TEST_HS_M "$TMP/s9.err")|$(grep -c line1 "$TMP/s9.err")"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All himmel-secrets tests passed."
else
    echo "$FAILED himmel-secrets test(s) failed."
    exit 1
fi
