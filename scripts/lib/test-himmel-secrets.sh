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
esac
rc=1
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    [ "$m" = 1 ] || continue
    case "$verb" in
        lookup) printf '%s' "$val"; exit 0 ;;
        search)
            printf '[/stub]\nlabel = stub\nsecret = %s\n' "$val"
            for p in $attrs; do printf 'attribute.%s = %s\n' "${p%%=*}" "${p#*=}"; done
            rc=0 ;;
    esac
done <"$KSTUB_STORE"
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

# S5: import-env stores secret-class keys only and prints names, never values.
kreset
printf '# comment\nTEST_HS_A=fake-a\nHANDOVER_DIR=/c/h\nTEST_HS_E=\nTEST_HS_B = "fake-b" # gutter\n' >"$TMP/in.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in.env" 2>&1)
assert_eq "S5 import-env prints names only" "0" "$(printf '%s' "$out" | grep -c 'fake-')"
assert_eq "S5 import-env skips config keys" "1" "$(printf '%s' "$out" | grep -c 'skipped HANDOVER_DIR')"
assert_eq "S5 import-env stores the secret keys" "2" "$(grep -c '^service=himmel key=TEST_HS_[AB] scope=user' "$KSTUB_STORE")"
assert_eq "S5 import-env stores no config key" "0" "$(grep -c HANDOVER_DIR "$KSTUB_STORE")"

# S6: export-env writes a new 0600 file that round-trips, and refuses to
# overwrite an existing one.
out=$(cd "$REPO" && "$HS" export-env "$TMP/out.env" 2>&1)
assert_eq "S6 export-env prints no value" "0" "$(printf '%s' "$out" | grep -c 'fake-')"
assert_eq "S6 export-env round-trips" "TEST_HS_A=fake-a|TEST_HS_B=\"fake-b\"" "$(sort "$TMP/out.env" | tr '\n' '|' | sed 's/|$//')"
assert_eq "S6 export-env writes mode 600" "600" "$(stat -c %a "$TMP/out.env" 2>/dev/null || stat -f %Lp "$TMP/out.env")"
got=$(cd "$REPO" && "$HS" export-env "$TMP/out.env" 2>/dev/null; echo "rc=$?")
assert_eq "S6 export-env refuses an existing file" "rc=2" "$got"

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
