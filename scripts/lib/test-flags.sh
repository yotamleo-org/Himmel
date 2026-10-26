#!/usr/bin/env bash
# test-flags.sh — flags.sh, flags.py and flags.mjs read scripts/lib/flags.tsv the same way:
# environment, then himmel.conf.local, then himmel.conf, then the registry default; an unknown
# name fails loudly; .env is never read. A fixture registry and a fixture HIMMEL_CONFIG_DIR
# keep the real ~/.himmel out of it. FLAGS_LIB_DIR overrides the readers' directory (the RED
# control: a missing directory fails every row). bash 3.2-safe.
#
# Run: bash scripts/lib/test-flags.sh
# shellcheck disable=SC2015,SC2163  # A && pass || fail reporting idiom; export "$@" exports the KEY=VAL arguments
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${FLAGS_LIB_DIR:-$HERE}"
case "$LIB" in /*) ;; *) LIB="$PWD/$LIB" ;; esac  # absolute: the .env row runs from another directory

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-flags.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
CONF="$WORK/conf"; mkdir -p "$CONF"
printf '# registry\nfoo_off\toff\tfeature\tHIMMEL-1\tHIMMEL-2\t2099-01-01\ta flag that defaults off\nfoo_on\ton\tfeature\tHIMMEL-1\tHIMMEL-2\t2099-01-01\ta flag that defaults on\n' > "$WORK/flags.tsv"

# rd <reader> <name>: the reader's exit code, its stderr in $WORK/err
rd() {
    export HIMMEL_FLAGS_TSV="$WORK/flags.tsv" HIMMEL_CONFIG_DIR="$CONF"
    case "$1" in
        sh) bash "$LIB/flags.sh" "$2" 2>"$WORK/err" ;;
        py) python3 -I "$LIB/flags.py" "$2" 2>"$WORK/err" ;;
        mjs) node "$LIB/flags.mjs" "$2" 2>"$WORK/err" ;;
    esac
    echo $?
}
want() { # <label> <reader> <name> <rc> [KEY=VAL ...]: the extra variables are exported for this one call
    local label="$1" r="$2" n="$3" rc="$4" got
    shift 4
    got="$( [ "$#" -eq 0 ] || export "$@"; rd "$r" "$n")"
    [ "$got" = "$rc" ] && pass "$label [$r]" || fail "$label [$r] (want rc $rc, got '$got')"
}

for r in sh py mjs; do
    want "the registry default off is off" "$r" foo_off 1
    want "the registry default on is on" "$r" foo_on 0
    want "env 1 beats a default off" "$r" foo_off 0 HIMMEL_FLAG_FOO_OFF=1
    want "env 0 beats a default on" "$r" foo_on 1 HIMMEL_FLAG_FOO_ON=0
    want "env 'on' is on" "$r" foo_off 0 HIMMEL_FLAG_FOO_OFF=on
    want "an empty env value falls through to the default" "$r" foo_off 1 HIMMEL_FLAG_FOO_OFF=
    want "an unknown name is rc 2" "$r" nope 2
    want "a bad name is rc 2" "$r" 'Bad-Name' 2
    want "an invalid value is rc 2" "$r" foo_off 2 HIMMEL_FLAG_FOO_OFF=maybe

    printf 'HIMMEL_FLAG_FOO_OFF=1\n' > "$CONF/himmel.conf"
    want "himmel.conf beats the default" "$r" foo_off 0
    printf 'HIMMEL_FLAG_FOO_OFF=0\n' > "$CONF/himmel.conf.local"
    want "himmel.conf.local beats himmel.conf" "$r" foo_off 1
    want "env beats himmel.conf.local" "$r" foo_off 0 HIMMEL_FLAG_FOO_OFF=1
    printf 'HIMMEL_FLAG_FOO_OFF="1"  # quoted, with a comment\n' > "$CONF/himmel.conf.local"
    want "a quoted conf value with a trailing comment is read" "$r" foo_off 0
    printf 'HIMMEL_FLAG_FOO_OFF=1\t# tab-separated comment\n' > "$CONF/himmel.conf.local"
    want "a tab before a trailing comment ends the value" "$r" foo_off 0
    printf '# HIMMEL_FLAG_FOO_OFF=1\nHIMMEL_FLAG_FOO_OFF=\n' > "$CONF/himmel.conf.local"
    printf 'HIMMEL_FLAG_FOO_OFF=1\n' > "$CONF/himmel.conf"
    want "a commented or empty local line falls through to himmel.conf" "$r" foo_off 0
    rm -f "$CONF/himmel.conf" "$CONF/himmel.conf.local"

    # the legacy .env is never a flag layer
    mkdir -p "$WORK/repo"; printf 'HIMMEL_FLAG_FOO_OFF=1\n' > "$WORK/repo/.env"
    got="$(cd "$WORK/repo" && export HOME="$WORK/repo" && rd "$r" foo_off)"
    [ "$got" = 1 ] && pass "a flag in .env is ignored [$r]" || fail "a flag in .env is ignored [$r] (want rc 1, got '$got')"
done

# a symlinked checkout path still enters the CLI (no silent exit 0 for an unknown name)
mkdir -p "$WORK/real"; cp "$LIB/flags.mjs" "$WORK/real/flags.mjs"; ln -s "$WORK/real" "$WORK/link"
got="$(export HIMMEL_FLAGS_TSV="$WORK/flags.tsv" HIMMEL_CONFIG_DIR="$CONF"; node "$WORK/link/flags.mjs" nope 2>/dev/null; echo $?)"
[ "$got" = 2 ] && pass "flags.mjs: a symlinked path still runs the CLI" || fail "flags.mjs: a symlinked path (want rc 2, got '$got')"

# unknown-name stderr is loud and names the flag
( rd sh nope >/dev/null ); grep -q "unknown flag 'nope'" "$WORK/err" && pass "unknown name: stderr names the flag" || fail "unknown name: stderr was '$(cat "$WORK/err")'"

# the shipped registry parses and the first flag is registered, default off
reg_rc="$(HIMMEL_CONFIG_DIR="$CONF" bash "$LIB/flags.sh" chain_soft_edges 2>/dev/null; echo $?)"
[ "$reg_rc" = 1 ] && pass "shipped registry: chain_soft_edges is registered and off" || fail "shipped registry: chain_soft_edges rc=$reg_rc"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
