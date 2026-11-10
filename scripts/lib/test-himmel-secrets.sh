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

# The stub keyring (secret-tool and busctl first on PATH) is shared with the
# migrate-env and S0 suites.
# shellcheck source=fixtures/keyring-stub.sh
. "$(dirname "$0")/fixtures/keyring-stub.sh"
# The import lock lives under the config dir; keep it inside this suite's temp dir.
export HIMMEL_CONFIG_DIR="$TMP/conf"

# R0: no row below may reach a real keyring.
# shellcheck disable=SC2153 # KBIN is set by the sourced fixture
assert_eq "R0 secret-tool resolves inside the stub dir" "$KBIN/secret-tool" "$(command -v secret-tool)"
assert_eq "R0 busctl resolves inside the stub dir" "$KBIN/busctl" "$(command -v busctl)"
[ "$FAILED" -eq 0 ] || { echo "R0 failed: refusing to run against a possible real keyring"; exit 1; }

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet
PROJ=$(cd "$REPO" && pwd -P)

# The import verb is unreachable on Darwin (no keyring), so the L rows run
# _hs_import_lock itself, cut out of the script, under a PATH with no flock.
NOFLOCK="$TMP/noflock-bin"
mkdir -p "$NOFLOCK"
for _l_t in mkdir rmdir rm mv cat cksum cut kill sleep printf dirname date ln readlink; do
    _l_p=$(command -v "$_l_t") && ln -sf "$_l_p" "$NOFLOCK/$_l_t"
done
BASH_BIN=$(command -v bash)
cat >"$TMP/lockdrv.sh" <<'DRV'
_hs_die() { printf 'himmel-secrets: %s\n' "$*" >&2; exit 2; }
_himmel_config_dir() { printf '%s\n' "$HIMMEL_CONFIG_DIR"; }
HS_SCOPE_PROJECT=""
DRV
sed -n '/^_hs_import_lock() {$/,/^}$/p' "$HS" >>"$TMP/lockdrv.sh"
cat >>"$TMP/lockdrv.sh" <<'DRV'
_hs_import_lock
echo locked
sleep "${HOLD:-0}"
DRV
REAL_RL=$(command -v readlink)
RLSTUB="$TMP/rl-stub"
mkdir -p "$RLSTUB"
cat >"$RLSTUB/readlink" <<'STUB'
#!/bin/sh
case "$1" in *.reap) exec "$REAL_RL" "$1" ;; esac
n=$(cat "$RL_COUNT" 2>/dev/null); n=$((${n:-0} + 1)); printf '%s\n' "$n" >"$RL_COUNT"
set -- $RL_SEQ
[ "$n" -le "$#" ] || n=$#
eval "printf '%s\n' \"\${$n}\""
STUB
chmod +x "$RLSTUB/readlink"
lockrun() { env -i PATH="${LPATH:-$NOFLOCK}" HIMMEL_CONFIG_DIR="${LCONF:-$HIMMEL_CONFIG_DIR}" HOLD="${1:-0}" REAL_RL="$REAL_RL" RL_COUNT="${RL_COUNT:-}" RL_SEQ="${RL_SEQ:-}" "$BASH_BIN" "$TMP/lockdrv.sh" 2>&1; echo "rc=$?"; }
lockwait() { local _w=0; while [ "$_w" -lt 100 ] && ! grep -qx locked "$1" 2>/dev/null; do sleep 0.1; _w=$((_w + 1)); done; }
LOCKLINK="$HIMMEL_CONFIG_DIR/import-env.user.owner"
assert_eq "L0 flock is hidden from the lock's PATH" "" "$(PATH="$NOFLOCK" command -v flock)"
lockrun 30 >"$TMP/l1.a" &
l1_pid=$!
lockwait "$TMP/l1.a"
assert_eq "L1 the first import took the lock" "locked" "$(head -n1 "$TMP/l1.a")"
got=$(lockrun 0)
assert_eq "L1 a second import is refused while the first runs, with no flock" "1|rc=2" "$(printf '%s' "$got" | grep -c 'another import-env')|$(printf '%s' "$got" | grep rc=)"
l1_owner=$(readlink "$LOCKLINK" 2>/dev/null)
[ -z "$l1_owner" ] || kill -9 "$l1_owner" 2>/dev/null
wait "$l1_pid" 2>/dev/null
got=$(lockrun 0)
assert_eq "L2 a killed import leaves no stale lock" "locked|rc=0" "$(printf '%s' "$got" | tr '\n' '|' | sed 's/|$//')"
assert_eq "L3 a finished import leaves nothing under the lock path" "0" "$(find "$HIMMEL_CONFIG_DIR" -name 'import-env.*' 2>/dev/null | grep -c .)"
mkdir -p "$HIMMEL_CONFIG_DIR"
sleep 0.01 & l4_dead=$!; wait "$l4_dead"
ln -s "$l4_dead" "$LOCKLINK"
for l4_i in 1 2 3 4 5 6 7 8 9 10 11 12; do lockrun 2 >"$TMP/l4.$l4_i" & done
wait
assert_eq "L4 twelve imports over one stale lock: exactly one wins" "1" "$(cat "$TMP"/l4.* | grep -c '^locked$')"
assert_eq "L4 the lock is gone once the winner ends" "0" "$(find "$HIMMEL_CONFIG_DIR" -name 'import-env.*' 2>/dev/null | grep -c .)"
L5CONF="$TMP/it's conf"
got=$(LCONF="$L5CONF" lockrun 0)
assert_eq "L5 a quote in the config path: the import runs" "locked|rc=0" "$(printf '%s' "$got" | tr '\n' '|' | sed 's/|$//')"
assert_eq "L5 a quote in the config path: the lock is removed at exit" "0" "$(find "$L5CONF" -name 'import-env.*' 2>/dev/null | grep -c .)"
ln -s "$l4_dead" "$LOCKLINK"
ln -s "$l4_dead" "$LOCKLINK.reap"
got=$(lockrun 0)
assert_eq "L6 a dead takeover guard is named in the refusal" "1|rc=2" "$(printf '%s' "$got" | grep -c 'import-env.user.owner.reap behind')|$(printf '%s' "$got" | grep rc=)"
rm -f "$LOCKLINK" "$LOCKLINK.reap"
got=$(lockrun 0)
assert_eq "L6 removing both links lets the next import run" "locked|rc=0" "$(printf '%s' "$got" | tr '\n' '|' | sed 's/|$//')"
mkdir "$LOCKLINK"
got=$(lockrun 0)
assert_eq "L7 a directory at the lock path is refused, never locked" "1|rc=2" "$(printf '%s' "$got" | grep -c 'is not a lock link')|$(printf '%s' "$got" | grep rc=)"
assert_eq "L7 the refusal leaves nothing inside the lock-path directory" "0" "$(find "$LOCKLINK" -mindepth 1 2>/dev/null | grep -c .)"
rm -rf "$LOCKLINK"
ln -s "$l4_dead" "$LOCKLINK"
mkdir "$LOCKLINK.reap"
got=$(lockrun 0)
assert_eq "L7 a directory at the takeover guard is refused, never taken over" "1|rc=2" "$(printf '%s' "$got" | grep -c 'is not a lock link')|$(printf '%s' "$got" | grep rc=)"
assert_eq "L7 the refusal leaves nothing inside the guard directory" "0" "$(find "$LOCKLINK.reap" -mindepth 1 2>/dev/null | grep -c .)"
rm -rf "$LOCKLINK.reap"
rm -f "$LOCKLINK"
ln -s "$l4_dead" "$LOCKLINK"
ln -s "$$" "$LOCKLINK.reap"
got=$(lockrun 0)
assert_eq "L8 a takeover guard held by a live import blocks the takeover" "1|rc=2" "$(printf '%s' "$got" | grep -c 'another import-env')|$(printf '%s' "$got" | grep rc=)"
assert_eq "L8 the stale lock and the live guard are left as they were" "$l4_dead|$$" "$(readlink "$LOCKLINK")|$(readlink "$LOCKLINK.reap")"
rm -f "$LOCKLINK" "$LOCKLINK.reap"
ln -s "$l4_dead" "$LOCKLINK"
got=$(LPATH="$RLSTUB:$NOFLOCK" RL_COUNT="$TMP/rl.count" RL_SEQ="$l4_dead $$" lockrun 0)
assert_eq "L9 an owner seen live on the re-read under the guard is not removed" "1|rc=2" "$(printf '%s' "$got" | grep -c 'another import-env')|$(printf '%s' "$got" | grep rc=)"
assert_eq "L9 the lock link is left and the guard released" "$l4_dead|absent" "$(readlink "$LOCKLINK")|$([ -L "$LOCKLINK.reap" ] && echo held || echo absent)"
rm -f "$TMP/rl.count"
got=$(LPATH="$RLSTUB:$NOFLOCK" RL_COUNT="$TMP/rl.count" RL_SEQ="$l4_dead $l4_dead $$" lockrun 0)
assert_eq "L10 a lock retaken between the liveness check and the removal is not removed" "1|rc=2" "$(printf '%s' "$got" | grep -c 'another import-env')|$(printf '%s' "$got" | grep rc=)"
assert_eq "L10 the lock link is left and the guard released" "$l4_dead|absent" "$(readlink "$LOCKLINK")|$([ -L "$LOCKLINK.reap" ] && echo held || echo absent)"
rm -f "$LOCKLINK" "$TMP/l11.a"
lockrun 3 >"$TMP/l11.a" &
l11_pid=$!
lockwait "$TMP/l11.a"
rm -f "$LOCKLINK"
ln -s "$$" "$LOCKLINK"
wait "$l11_pid"
assert_eq "L11 an import whose lock was retaken leaves the new owner's lock at exit" "$$" "$(readlink "$LOCKLINK")"
rm -f "$LOCKLINK"

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

# S3b: exec --require refuses to run CMD when a named key resolves to unset;
# without it the child still runs (the default is unchanged). Names, never values.
kreset
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
rm -f "$TMP/s3b.ran"
out=$(cd "$REPO" && unset TEST_HS_A && export KSTUB_LOCKED=true && "$HS" exec --require --keys TEST_HS_A -- touch "$TMP/s3b.ran" 2>&1; echo "rc=$?")
assert_eq "S3b locked keyring: --require exits 1" "rc=1" "$(printf '%s' "$out" | tail -n 1)"
assert_eq "S3b locked keyring: --require does not run CMD" "absent" "$([ -e "$TMP/s3b.ran" ] && echo ran || echo absent)"
assert_eq "S3b locked keyring: --require names the key" "1" "$(printf '%s' "$out" | grep -c 'TEST_HS_A')"
assert_eq "S3b locked keyring: --require prints no value" "0" "$(printf '%s' "$out" | grep -c 'fake-')"
rm -f "$TMP/s3b.ran"
out=$(cd "$REPO" && unset TEST_HS_NONE && "$HS" exec --require --keys TEST_HS_NONE -- touch "$TMP/s3b.ran" 2>&1; echo "rc=$?")
assert_eq "S3b unset key: --require exits 1" "rc=1" "$(printf '%s' "$out" | tail -n 1)"
assert_eq "S3b unset key: --require does not run CMD" "absent" "$([ -e "$TMP/s3b.ran" ] && echo ran || echo absent)"
assert_eq "S3b unset key: --require names the key" "1" "$(printf '%s' "$out" | grep -c 'TEST_HS_NONE')"
rm -f "$TMP/s3b.ran"
out=$(cd "$REPO" && unset TEST_HS_A TEST_HS_NONE && "$HS" exec --require --keys TEST_HS_A,TEST_HS_NONE -- touch "$TMP/s3b.ran" 2>&1; echo "rc=$?")
assert_eq "S3b one of two unset: --require exits 1 and runs nothing" "rc=1 absent" "$(printf '%s' "$out" | tail -n 1) $([ -e "$TMP/s3b.ran" ] && echo ran || echo absent)"
kreset
printf 'service=himmel key=TEST_HS_E scope=user\t\n' >"$KSTUB_STORE"
rm -f "$TMP/s3b.ran"
out=$(cd "$REPO" && unset TEST_HS_E && "$HS" exec --require --keys TEST_HS_E -- touch "$TMP/s3b.ran" 2>&1; echo "rc=$?")
assert_eq "S3b empty keyring value: --require exits 1 and runs nothing" "rc=1 absent" "$(printf '%s' "$out" | tail -n 1) $([ -e "$TMP/s3b.ran" ] && echo ran || echo absent)"
printf 'service=himmel key=TEST_HS_A scope=user\tfake-a\n' >"$KSTUB_STORE"
# shellcheck disable=SC2016 # expands in the child
got=$(cd "$REPO" && unset TEST_HS_A && "$HS" exec --require --keys TEST_HS_A -- bash -c 'printf "%s" "${TEST_HS_A:-<unset>}"')
assert_eq "S3b present key: --require runs CMD with the value" "fake-a" "$got"
rm -f "$TMP/s3b.ran"
(cd "$REPO" && unset TEST_HS_NONE && "$HS" exec --keys TEST_HS_NONE -- touch "$TMP/s3b.ran" 2>/dev/null)
assert_eq "S3b default (no --require): CMD still runs without the key" "ran" "$([ -e "$TMP/s3b.ran" ] && echo ran || echo absent)"

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

cp "$KSTUB_STORE" "$TMP/s5-store.keep"  # S6 reads the items the rows above stored
# S5b: a stored quoted-empty item holds nothing, so a real .env value replaces it instead of being held.
# The real secret-tool store replaces an item of the same attributes; the stub appends, so a wrapper does the replace.
SVBIN="$TMP/sv-bin"
mkdir -p "$SVBIN"
cat >"$SVBIN/secret-tool" <<'WRAP'
#!/usr/bin/env bash
if [ "$1" = store ]; then
    a=("$@"); q=""; i=3
    while [ "$i" -lt "${#a[@]}" ]; do q="$q ${a[$i]}=${a[$((i + 1))]}"; i=$((i + 2)); done
    grep -vF "${q# }	" "$KSTUB_STORE" >"$KSTUB_STORE.new"; cat "$KSTUB_STORE.new" >"$KSTUB_STORE"; rm -f "$KSTUB_STORE.new"
fi
exec "$KBIN/secret-tool" "$@"
WRAP
chmod +x "$SVBIN/secret-tool"
for _s5b_item in '""' "''"; do
    kreset
    printf 'service=himmel key=FIRECRAWL_API_KEY scope=user\t%s\n' "$_s5b_item" >"$KSTUB_STORE"
    printf 'FIRECRAWL_API_KEY=fake-real\n' >"$TMP/in-qe.env"
    out=$(cd "$REPO" && KBIN="$KBIN" PATH="$SVBIN:$PATH" "$HS" import-env "$TMP/in-qe.env" 2>&1)
    assert_eq "S5b a stored $_s5b_item item does not hold a real value" "1" "$(printf '%s' "$out" | grep -c '^stored FIRECRAWL_API_KEY$')"
    # read-sink-ok: KSTUB_STORE is the suite's own stub file under its mktemp dir
    assert_eq "S5b the real value replaced the $_s5b_item item" "1 1" "$(wc -l <"$KSTUB_STORE" | tr -d ' ') $(grep -cF 'fake-real' "$KSTUB_STORE")"
done
kreset
printf 'FIRECRAWL_API_KEY=""\n' >"$TMP/in-qe.env"
out=$(cd "$REPO" && KBIN="$KBIN" PATH="$SVBIN:$PATH" "$HS" import-env "$TMP/in-qe.env" 2>&1)
assert_eq "S5b a quoted-empty .env line is still stored as those characters" "stored FIRECRAWL_API_KEY" "$(printf '%s' "$out" | grep '^stored ')"
kreset
printf 'service=himmel key=FIRECRAWL_API_KEY scope=user\tfake-other\n' >"$KSTUB_STORE"
printf 'FIRECRAWL_API_KEY=fake-real\n' >"$TMP/in-qe.env"
out=$(cd "$REPO" && KBIN="$KBIN" PATH="$SVBIN:$PATH" "$HS" import-env "$TMP/in-qe.env" 2>&1)
assert_eq "S5b control: another real value is still held" "held FIRECRAWL_API_KEY" "$(printf '%s' "$out" | grep -E '^(stored|held) ')"

# S5c: a user-scope import names a key a differing project-scope item shadows, never a value.
kreset
printf 'service=himmel key=FIRECRAWL_API_KEY project=%s\tfake-proj\n' "$PROJ" >"$KSTUB_STORE"
printf 'FIRECRAWL_API_KEY=fake-user\n' >"$TMP/in-sh.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-sh.env" 2>&1)
assert_eq "S5c a differing project item is named" "1" "$(printf '%s' "$out" | grep -c '^shadowed FIRECRAWL_API_KEY$')"
assert_eq "S5c the import still stored it" "1" "$(printf '%s' "$out" | grep -c '^stored FIRECRAWL_API_KEY$')"
assert_eq "S5c no value printed" "0" "$(printf '%s' "$out" | grep -c 'fake')"
kreset
printf 'service=himmel key=FIRECRAWL_API_KEY project=%s\tfake-user\n' "$PROJ" >"$KSTUB_STORE"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-sh.env" 2>&1)
assert_eq "S5c an equal project item shadows nothing" "0" "$(printf '%s' "$out" | grep -c '^shadowed ')"
kreset
printf 'service=himmel key=FIRECRAWL_API_KEY scope=user\tfake-other\n' >"$KSTUB_STORE"
out=$(cd "$REPO" && "$HS" import-env --project "$TMP/in-sh.env" 2>&1)
assert_eq "S5c a project import shadows nothing" "0" "$(printf '%s' "$out" | grep -c '^shadowed ')"

# S5d: same-value reads candidates from stdin, compares them with the user-scope item, prints nothing.
sv() {  # <stdin text> <name>: prints the exit code, then any output
    local _sv_o _sv_rc
    _sv_o=$(cd "$REPO" && printf '%s' "$1" | "$HS" same-value "$2" 2>&1)
    _sv_rc=$?
    printf '%s%s' "$_sv_rc" "$_sv_o"
}
kreset
printf 'service=himmel key=FIRECRAWL_API_KEY scope=user\tfake-one\nservice=himmel key=TELEGRAM_BOT_TOKEN project=%s\tfake-proj\n' "$PROJ" >"$KSTUB_STORE"
assert_eq "S5d one equal line" "0" "$(sv $'fake-one\n' FIRECRAWL_API_KEY)"
assert_eq "S5d two equal lines" "0" "$(sv $'fake-one\nfake-one\n' FIRECRAWL_API_KEY)"
assert_eq "S5d a last line with no newline counts" "1" "$(sv $'fake-one\nfake-two' FIRECRAWL_API_KEY)"
assert_eq "S5d one line differs" "1" "$(sv $'fake-one\nfake-two\n' FIRECRAWL_API_KEY)"
assert_eq "S5d no line, an item" "0" "$(sv '' FIRECRAWL_API_KEY)"
assert_eq "S5d no line, no item" "1" "$(sv '' JIRA_API_TOKEN)"
assert_eq "S5d a line, no item" "1" "$(sv $'fake-one\n' JIRA_API_TOKEN)"
assert_eq "S5d a project-scope item is no user-scope item" "1" "$(sv $'fake-proj\n' TELEGRAM_BOT_TOKEN)"
assert_eq "S5d no value in the stub's argv log" "0" "$(grep -c 'fake-' "$KSTUB_LOG")"
_s5d=$(cd "$REPO" && export KSTUB_SEARCH_FAIL=1 && printf 'fake-one\n' | "$HS" same-value FIRECRAWL_API_KEY >/dev/null 2>&1; echo "rc=$?")
assert_eq "S5d a keyring that does not answer" "rc=2" "$_s5d"
_s5d=$(cd "$REPO" && export KSTUB_LOCKED=true && printf 'fake-one\n' | "$HS" same-value FIRECRAWL_API_KEY >/dev/null 2>&1; echo "rc=$?")
assert_eq "S5d a locked keyring" "rc=2" "$_s5d"
_s5d=$(cd "$REPO" && printf 'x\n' | "$HS" same-value --project FIRECRAWL_API_KEY >/dev/null 2>&1; echo "rc=$?")
assert_eq "S5d --project is refused" "rc=2" "$_s5d"
_s5d=$(cd "$REPO" && printf 'x\n' | "$HS" same-value 'not a name' >/dev/null 2>&1; echo "rc=$?")
assert_eq "S5d a bad name is refused" "rc=2" "$_s5d"

cp "$TMP/s5-store.keep" "$KSTUB_STORE"
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
printf 'GOOGLE_HEALTH_REFRESH_TOKEN=fake-g\nZAI_API_KEY=fake-z\nhimmel_github_token_vm2=fake-v\n' >"$TMP/in-station.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-station.env" 2>&1)
assert_eq "S5b import-env stores the station secrets" "3" "$(grep -c '^service=himmel key=\(GOOGLE_HEALTH_REFRESH_TOKEN\|ZAI_API_KEY\|himmel_github_token_vm2\) scope=user' "$KSTUB_STORE")"
assert_eq "S5b import-env skips none of them" "0" "$(printf '%s' "$out" | grep -c '^skipped')"

# S5c: the settings a consumer reads from .env or himmel.conf
# are not secrets, so import-env leaves each in place and names it.
kreset
printf 'JIRA_BASE_URL=https://fake.example.invalid\nTELEGRAM_CHAT_ID=fake-t\nTELEGRAM_GROUP_CHAT_ID=fake-g\nFIRECRAWL_BASE_URL=https://fake-fc.example.invalid\nWHISPER_MODEL=/fake/model.bin\nZAI_API_KEY=fake-z\n' >"$TMP/in-conf.env"
out=$(cd "$REPO" && "$HS" import-env "$TMP/in-conf.env" 2>&1)
assert_eq "S5c import-env stores none of the 5 config keys" "0" "$(grep -c 'key=\(JIRA_BASE_URL\|TELEGRAM_CHAT_ID\|TELEGRAM_GROUP_CHAT_ID\|FIRECRAWL_BASE_URL\|WHISPER_MODEL\) ' "$KSTUB_STORE")"
assert_eq "S5c import-env names each config key it leaves" "5" "$(printf '%s' "$out" | grep -c '^skipped \(JIRA_BASE_URL\|TELEGRAM_CHAT_ID\|TELEGRAM_GROUP_CHAT_ID\|FIRECRAWL_BASE_URL\|WHISPER_MODEL\) (config key')"
assert_eq "S5c import-env says an env-only key stays in .env" "2" "$(printf '%s' "$out" | grep -c '^skipped \(FIRECRAWL_BASE_URL\|WHISPER_MODEL\) (config key; it stays in \.env)$')"
assert_eq "S5c import-env says Jira URL and chat ids belong in ~/.himmel" "3" "$(printf '%s' "$out" | grep -c '^skipped \(JIRA_BASE_URL\|TELEGRAM_CHAT_ID\|TELEGRAM_GROUP_CHAT_ID\) (config key; it belongs in ~/\.himmel)$')"
assert_eq "S5c import-env still stores the real secret" "1" "$(grep -c '^service=himmel key=ZAI_API_KEY scope=user' "$KSTUB_STORE")"

# S5d: the operator's guarded station config chooses the Jira destination;
# the legacy .env remains a fallback, below config and profiles.
mkdir -p "$TMP/s5d-conf"
printf 'JIRA_BASE_URL=https://planted.example.invalid\n' >"$TMP/s5d-conf/himmel.conf"
got=$(cd "$REPO" && rm -f .env && unset JIRA_BASE_URL && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" JIRA_BASE_URL 2>/dev/null; printf '[%s]' "${JIRA_BASE_URL-}")
assert_eq "S5d himmel.conf serves JIRA_BASE_URL without .env" "[https://planted.example.invalid]" "$got"
printf 'JIRA_BASE_URL=https://from-env.example.invalid\n' >"$REPO/.env"
got=$(cd "$REPO" && unset JIRA_BASE_URL && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" JIRA_BASE_URL 2>/dev/null; printf '[%s]' "${JIRA_BASE_URL-}")
assert_eq "S5d config URL outranks the legacy .env" "[https://planted.example.invalid]" "$got"
: >"$TMP/s5d-conf/himmel.conf"
got=$(cd "$REPO" && unset JIRA_BASE_URL && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" JIRA_BASE_URL 2>/dev/null; printf '[%s]' "${JIRA_BASE_URL-}")
assert_eq "S5d .env still serves the fallback Jira URL" "[https://from-env.example.invalid]" "$got"
rm -f "$REPO/.env"
# A selected station profile also serves the URL.
mkdir -p "$TMP/s5d-prof/vault/.himmel/profiles" "$TMP/s5d-prof/conf"
printf 'JIRA_BASE_URL=https://planted-profile.example.invalid\n' >"$TMP/s5d-prof/vault/.himmel/profiles/p.conf"
: >"$TMP/s5d-prof/vault/.himmel/himmel.conf"
ln -sf "$TMP/s5d-prof/vault/.himmel/himmel.conf" "$TMP/s5d-prof/conf/himmel.conf"
got=$(cd "$REPO" && unset JIRA_BASE_URL && export HIMMEL_CONFIG_DIR="$TMP/s5d-prof/conf" HIMMEL_PROFILE=p HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" JIRA_BASE_URL 2>/dev/null; printf '[%s]' "${JIRA_BASE_URL-}")
assert_eq "S5d a profile serves JIRA_BASE_URL" "[https://planted-profile.example.invalid]" "$got"

# S5d: the other env-only keys, whose readers take the process env or .env only.
printf 'FIRECRAWL_BASE_URL=https://planted-fc.example.invalid\nWHISPER_MODEL=/planted/model.bin\n' >"$TMP/s5d-conf/himmel.conf"
got=$(cd "$REPO" && rm -f .env && unset FIRECRAWL_BASE_URL WHISPER_MODEL && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" FIRECRAWL_BASE_URL WHISPER_MODEL 2>/dev/null; printf '[%s|%s]' "${FIRECRAWL_BASE_URL-}" "${WHISPER_MODEL-}")
assert_eq "S5d himmel.conf never sets FIRECRAWL_BASE_URL or WHISPER_MODEL" "[|]" "$got"
printf 'FIRECRAWL_BASE_URL=https://from-env-fc.example.invalid\nWHISPER_MODEL=/from/env/model.bin\n' >"$REPO/.env"
got=$(cd "$REPO" && unset FIRECRAWL_BASE_URL WHISPER_MODEL && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" HIMMEL_SECRETS_KEYRING=off && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" FIRECRAWL_BASE_URL WHISPER_MODEL 2>"$TMP/s5d.err"; printf '[%s|%s]' "${FIRECRAWL_BASE_URL-}" "${WHISPER_MODEL-}")
assert_eq "S5d .env still serves FIRECRAWL_BASE_URL and WHISPER_MODEL" "[https://from-env-fc.example.invalid|/from/env/model.bin]" "$got"
assert_eq "S5d an env-only key in .env gets no DEPRECATED advice" "0" "$(grep -c DEPRECATED "$TMP/s5d.err")"
rm -f "$REPO/.env"

# S5e: the telegram hooks load through load_dotenv, so the chat ids
# come from himmel.conf and the bot token through the resolver, with no .env.
kreset
printf 'service=himmel key=TELEGRAM_BOT_TOKEN scope=user\tfake-bot\n' >"$KSTUB_STORE"
printf 'TELEGRAM_CHAT_ID=fake-chat\nTELEGRAM_GROUP_CHAT_ID=fake-group\n' >"$TMP/s5d-conf/himmel.conf"
got=$(cd "$REPO" && unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_GROUP_CHAT_ID && export HIMMEL_CONFIG_DIR="$TMP/s5d-conf" && . "$(dirname "$HS")/load-dotenv.sh" && load_dotenv --root "$REPO" TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_GROUP_CHAT_ID 2>/dev/null; printf '[%s|%s|%s]' "${TELEGRAM_BOT_TOKEN-}" "${TELEGRAM_CHAT_ID-}" "${TELEGRAM_GROUP_CHAT_ID-}")
assert_eq "S5e telegram: token from the keyring, chat ids from himmel.conf" "[fake-bot|fake-chat|fake-group]" "$got"

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

# R12: a store the keyring accepted but did not keep is `failed`, never `stored`.
kreset
printf 'JIRA_API_TOKEN=dummy-r12\n' >"$TMP/r12.env"
got=$(cd "$REPO" && env -u CLAUDECODE KSTUB_DROP_STORE=1 "$HS" import-env "$TMP/r12.env" 2>/dev/null; echo "rc=$?")
assert_eq "R12 a dropped store prints failed, exit 1" "failed JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=1" "$(printf '%s' "$got" | tr '\n' '|')"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R12 a kept store prints stored, exit 0" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"

# R12b: the read-back is keyring-only: the value in the process env, in
# CREDENTIALS_DIRECTORY and in a .env does not make a dropped store `stored`.
kreset
mkdir -p "$TMP/r12b-cred"
printf 'dummy-r12' >"$TMP/r12b-cred/JIRA_API_TOKEN"
printf 'JIRA_API_TOKEN=dummy-r12\n' >"$REPO/.env"
got=$(cd "$REPO" && env -u CLAUDECODE JIRA_API_TOKEN=dummy-r12 CREDENTIALS_DIRECTORY="$TMP/r12b-cred" KSTUB_DROP_STORE=1 "$HS" import-env "$TMP/r12.env" 2>/dev/null; echo "rc=$?")
assert_eq "R12b env, credentials and .env do not satisfy the read-back" "failed JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=1" "$(printf '%s' "$got" | tr '\n' '|')"
rm -f "$REPO/.env"

# R13: an item in the scope written with a different value is held, not overwritten.
kreset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tdummy-old\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13 a different value in user scope is held, exit 0" "held JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R13 a held key makes no store call" "0" "$(grep -c '^secret-tool store' "$KSTUB_LOG")"
# read-sink-ok: KSTUB_STORE is the suite's own stub file under its mktemp dir
assert_eq "R13 the held item keeps its value" "service=himmel key=JIRA_API_TOKEN scope=user	dummy-old" "$(cat "$KSTUB_STORE")"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env --project "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13 with --project a user-scope item does not count" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R13 --project stores the project item" "1" "$(grep -c "^service=himmel key=JIRA_API_TOKEN project=$PROJ	dummy-r12" "$KSTUB_STORE")"
kreset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tdummy-r12\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13 the same value already held is stored, with no second store call" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0|0" "$(printf '%s' "$got" | tr '\n' '|')|$(grep -c '^secret-tool store' "$KSTUB_LOG")"

# R13c: a lookup that errors or times out is not an absent item: nothing is stored.
kreset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tdummy-old\n' >"$KSTUB_STORE"
got=$(cd "$REPO" && env -u CLAUDECODE KSTUB_LOOKUP_RC=124 "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13c a timed-out lookup prints failed, exit 1" "failed JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=1" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R13c a timed-out lookup makes no store call" "0" "$(grep -c '^secret-tool store' "$KSTUB_LOG")"

got=$(cd "$REPO" && env -u CLAUDECODE KSTUB_LOOKUP_FAIL=1 "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13c an existing item whose lookup exits 1 prints failed, exit 1" "failed JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=1" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R13c an existing item whose lookup exits 1 is not stored over" "0" "$(grep -c '^secret-tool store' "$KSTUB_LOG")"
kreset
got=$(cd "$REPO" && env -u CLAUDECODE KSTUB_SEARCH_FAIL=1 "$HS" import-env "$TMP/r12.env" 2>&1; echo "rc=$?")
assert_eq "R13c a failed existence search prints failed, exit 1" "failed JIRA_API_TOKEN|imported 0 key(s) into the keyring|rc=1" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R13c a failed existence search makes no store call" "0" "$(grep -c '^secret-tool store' "$KSTUB_LOG")"

# R14: a name in the keep file is skipped, not stored; the existing lines stay.
kreset
printf 'JIRA_API_TOKEN=dummy-r12\nFIRECRAWL_API_KEY=dummy-r14\nJIRA_EMAIL=dummy@example.invalid\n' >"$TMP/r14.env"
printf 'JIRA_API_TOKEN\n' >"$TMP/r14.keep"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env --keep-file "$TMP/r14.keep" "$TMP/r14.env" 2>&1; echo "rc=$?")
assert_eq "R14 keep-file names are skipped, other lines unchanged" "skipped JIRA_API_TOKEN (env-keep)|stored FIRECRAWL_API_KEY|skipped JIRA_EMAIL (config key; it belongs in ~/.himmel)|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"
assert_eq "R14 a keep-file name makes no store call" "0" "$(grep -c 'store.*key JIRA_API_TOKEN' "$KSTUB_LOG")"

# R14d: keep-file lines read as migrate-env reads them: comments and blanks dropped.
kreset
printf '# keep list\n  JIRA_API_TOKEN  # the station needs it in .env\n\nFIRECRAWL_API_KEY\r\n' >"$TMP/r14d.keep"
printf 'JIRA_API_TOKEN=dummy-r12\nFIRECRAWL_API_KEY=dummy-r14\nTELEGRAM_BOT_TOKEN=dummy-r14d\n' >"$TMP/r14d.env"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env --keep-file "$TMP/r14d.keep" "$TMP/r14d.env" 2>&1; echo "rc=$?")
assert_eq "R14d a commented or padded keep-file line still skips its key" "skipped JIRA_API_TOKEN (env-keep)|skipped FIRECRAWL_API_KEY (env-keep)|stored TELEGRAM_BOT_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"

# R14c: a keep file that cannot be read stops the import before any store.
kreset
if [ "$(id -u)" != 0 ]; then
    cp "$TMP/r14.keep" "$TMP/r14-unreadable.keep"
    chmod 000 "$TMP/r14-unreadable.keep"
    got=$(cd "$REPO" && env -u CLAUDECODE "$HS" import-env --keep-file "$TMP/r14-unreadable.keep" "$TMP/r14.env" 2>/dev/null; echo "rc=$?")
    assert_eq "R14c an unreadable keep-file stops the import, rc 2" "rc=2" "$got"
    assert_eq "R14c an unreadable keep-file stores nothing" "0" "$(grep -c . "$KSTUB_STORE")"
fi

# R14b: names --class secret reads the class owner, needs no backend, and
# follows the owner when its case changes.
got=$(cd "$REPO" && env -u CLAUDECODE HIMMEL_SECRETS_KEYRING=off "$HS" names --class secret 2>/dev/null; echo "rc=$?")
assert_eq "R14b names lists JIRA_API_TOKEN with no backend, exit 0" "1|rc=0" "$(printf '%s' "$got" | grep -c '^JIRA_API_TOKEN$')|$(printf '%s' "$got" | grep rc=)"
assert_eq "R14b names lists no config key" "0" "$(printf '%s' "$got" | grep -c '^\(JIRA_EMAIL\|JIRA_BASE_URL\|WHISPER_MODEL\)$')"
FX="$TMP/fx"
mkdir -p "$FX/lib" "$FX/himmelctl/lib"
cp "$(dirname "$HS")/himmel-secrets" "$(dirname "$HS")/load-dotenv.sh" "$FX/lib/"
cp "$(dirname "$HS")/../himmelctl/lib/secrets-manifest.json" "$FX/himmelctl/lib/"
sed 's/^        JIRA_BASE_URL|TELEGRAM_CHAT_ID/        JIRA_API_TOKEN|JIRA_BASE_URL|TELEGRAM_CHAT_ID/' "$FX/lib/load-dotenv.sh" >"$FX/lib/load-dotenv.new" && mv "$FX/lib/load-dotenv.new" "$FX/lib/load-dotenv.sh"
got=$(cd "$REPO" && env -u CLAUDECODE HIMMEL_SECRETS_KEYRING=off "$FX/lib/himmel-secrets" names --class secret 2>/dev/null)
assert_eq "R14b a copy of the owner that classes JIRA_API_TOKEN as config drops it" "0" "$(printf '%s' "$got" | grep -c '^JIRA_API_TOKEN$')"
assert_eq "R14b the copy still lists the other secrets" "1" "$(printf '%s' "$got" | grep -c '^TELEGRAM_BOT_TOKEN$')"
got=$(cd "$REPO" && env -u CLAUDECODE "$HS" names 2>/dev/null; echo "rc=$?")
assert_eq "R14b names without --class secret is a usage error" "rc=2" "$got"

# R15: a keep file whose name starts with a dash is read as a file, never as a sed option.
kreset
mkdir -p "$TMP/r15"
printf 'JIRA_API_TOKEN\n' >"$TMP/r15/-n"
got=$(cd "$TMP/r15" && env -u CLAUDECODE "$HS" import-env --keep-file -n "$TMP/r12.env" 2>&1 </dev/null; echo "rc=$?")
assert_eq "R15 a dash-named keep file still protects its key" "skipped JIRA_API_TOKEN (env-keep)|imported 0 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|')"

# R16: the usage and unknown-verb lines name every verb, names included.
got=$(cd "$REPO" && "$HS" 2>&1; "$HS" frob 2>&1)
assert_eq "R16 the usage and unknown-verb lines name names" "2" "$(printf '%s\n' "$got" | grep -c 'import-env|same-value|export-env|names')"

# R17: two imports into one keyring scope never overlap. The lock is per scope, not per checkout.
printf 'JIRA_API_TOKEN=dummy-r17\n' >"$TMP/r17.env"
REPO2="$TMP/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" init --quiet
kreset
(cd "$REPO" && env -u CLAUDECODE KSTUB_STORE_SLEEP=2 "$HS" import-env "$TMP/r17.env" >"$TMP/r17.a" 2>&1; echo "rc=$?" >>"$TMP/r17.a") &
r17_pid=$!
sleep 1
got=$(cd "$REPO2" && env -u CLAUDECODE "$HS" import-env "$TMP/r17.env" 2>&1; echo "rc=$?")
wait "$r17_pid"
assert_eq "R17 a second import into the same scope from another checkout is refused" "1|rc=2" "$(printf '%s' "$got" | grep -c 'another import-env')|$(printf '%s' "$got" | grep rc=)"
assert_eq "R17 the first import finishes whole" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(tr '\n' '|' <"$TMP/r17.a" | sed 's/|$//')"
assert_eq "R17 only one store reached the keyring" "1" "$(grep -c '^secret-tool store' "$KSTUB_LOG")"
got=$(cd "$REPO2" && env -u CLAUDECODE "$HS" import-env "$TMP/r17.env" 2>&1; echo "rc=$?")
assert_eq "R17 the lock is gone once the first import ends" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|' | sed 's/|$//')"
kreset
(cd "$REPO" && env -u CLAUDECODE KSTUB_STORE_SLEEP=2 "$HS" import-env "$TMP/r17.env" >"$TMP/r17.b" 2>&1) &
r17_pid=$!
sleep 1
got=$(cd "$REPO2" && env -u CLAUDECODE "$HS" import-env --project "$TMP/r17.env" 2>&1; echo "rc=$?")
wait "$r17_pid"
assert_eq "R17 a project-scope import is not held up by a user-scope one" "stored JIRA_API_TOKEN|imported 1 key(s) into the keyring|rc=0" "$(printf '%s' "$got" | tr '\n' '|' | sed 's/|$//')"

# R18: sourcing the stub drops a knob the parent shell exported.
got=$( (export KSTUB_DROP_STORE=1 KSTUB_LOCKED=true; TMP="$TMP/stubchk"; mkdir -p "$TMP"; . "$(dirname "$HS")/fixtures/keyring-stub.sh"; printf '[%s|%s]' "${KSTUB_DROP_STORE:-}" "$KSTUB_LOCKED") )
assert_eq "R18 the stub clears inherited knobs on source" "[|false]" "$got"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All himmel-secrets tests passed."
else
    echo "$FAILED himmel-secrets test(s) failed."
    exit 1
fi
