#!/usr/bin/env bash
# scripts/handover/chief-kit/test-size-override.sh - suite for size-override.sh:
# the SIZE-ESCALATE ledger, the chief-only signed size-override record and the pending read.
#   1. note writes one SIZE-ESCALATE row per call; pending reports only the rows after --since.
#   2. record: refused from a worker or relay (3) and without a reason (2); a chief record lets check pass.
#   3. an unsigned, forged, edited or non-console row, or one for another file count, is no override.
#   4. the operator's cases (a trust-path brief over the soft band, past 300 files, past 1500 lines)
#      are refused by record and by check, even for a row carrying a valid mac.
#
# Linux-only kit (PLATFORM GUARD). Run: bash scripts/handover/chief-kit/test-size-override.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SIZE_OVERRIDE:-$HERE/size-override.sh}"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME 2>/dev/null || true

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/size-override-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
ROOT="$tmp/root"; mkdir -p "$ROOT"
LEDGER="$ROOT/.locks/size-escalate.tsv"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/go-gate.sh"
TAB=$(printf '\t')
run() { bash "$SUT" "$@" --root "$ROOT" 2>&1; }  # every call: the verb and its args, then the root
count() { grep -c "^$1" "$LEDGER" 2>/dev/null || true; }

# ---- 1. note and pending ----
out=$(run note refuse HIMMEL-9201 N921 --files 41 --detail "41 files over the 40-file hard max"); rc=$?
check "note refuse exits 0" 0 "$rc"
check "note refuse writes one SIZE-ESCALATE row" 1 "$(count SIZE-ESCALATE)"
out=$(run pending --since 0); rc=$?
check "pending --since 0 reports the row" 0 "$rc"
has "pending names the total" "$out" "total=1"
has "pending carries the key, label and file count" "$out" "refuse${TAB}HIMMEL-9201${TAB}N921${TAB}41"
out=$(run pending --since 1); rc=$?
check "pending --since 1 finds nothing new" 1 "$rc"
run note bulk HIMMEL-9202 N922 --files 120 --detail "bulk: mechanical" >/dev/null
out=$(run pending --since 1)
has "a bulk row counts as the second row" "$out" "total=2"
has "pending --since 1 prints only the second row" "$out" "bulk${TAB}HIMMEL-9202"
case "$out" in *HIMMEL-9201*) fail "pending --since 1 printed the first row again" ;; *) pass "pending --since 1 does not repeat the first row" ;; esac
out=$(run note other HIMMEL-9201 N921 --files 41); rc=$?
check "note with an unknown kind exits 2" 2 "$rc"

# ---- 2. record ----
out=$(HIMMEL_CONSOLE_LEG=1 run record HIMMEL-9201 N921 --files 41 --reason "keep whole"); rc=$?
check "record from a chief-spawned worker exits 3" 3 "$rc"
out=$(HIMMEL_CONSOLE_RELAY=1 run record HIMMEL-9201 N921 --files 41 --reason "keep whole"); rc=$?
check "record from a chief relay exits 3" 3 "$rc"
check "a refused record writes no SIZE-OVERRIDE row" 0 "$(count SIZE-OVERRIDE)"
out=$(run record HIMMEL-9201 N921 --files 41); rc=$?
check "record without a reason exits 2" 2 "$rc"
out=$(run check HIMMEL-9201 N921 --files 41); rc=$?
check "check with no override exits 1" 1 "$rc"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9201 N921 --files 41 --reason "one scripted rename"); rc=$?
check "a chief record exits 0" 0 "$rc"
check "the chief record writes one SIZE-OVERRIDE row" 1 "$(count SIZE-OVERRIDE)"
out=$(run check HIMMEL-9201 N921 --files 41); rc=$?
check "check passes for the signed override" 0 "$rc"
has "check names the chief session and the reason" "$out" "console:chief-x: one scripted rename"

# ---- 3. what is not an override ----
out=$(run check HIMMEL-9201 N921 --files 42); rc=$?
check "an override for 41 files does not cover 42" 1 "$rc"
out=$(run check HIMMEL-9201 N999 --files 41); rc=$?
check "an override for N921 does not cover N999" 1 "$rc"
out=$(run check HIMMEL-9999 N921 --files 41); rc=$?
check "an override for HIMMEL-9201 does not cover HIMMEL-9999" 1 "$rc"
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9300\tN930\t41\t0\tno\tconsole:chief-x\tkeep whole\t\n' >> "$LEDGER"
out=$(run check HIMMEL-9300 N930 --files 41); rc=$?
check "an unsigned override row (no mac) is refused" 1 "$rc"
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9301\tN931\t41\t0\tno\tconsole:chief-x\tkeep whole\t%s\n' "$(printf 'a%.0s' $(seq 1 64))" >> "$LEDGER"
out=$(run check HIMMEL-9301 N931 --files 41); rc=$?
check "a worker-written override row (forged mac) is refused" 1 "$rc"
cp "$LEDGER" "$LEDGER.keep"
sed 's/one scripted rename/anything goes/' "$LEDGER.keep" > "$LEDGER"
out=$(run check HIMMEL-9201 N921 --files 41); rc=$?
check "an edited reason breaks the mac" 1 "$rc"
cp "$LEDGER.keep" "$LEDGER"
mac=$(go_msg_mac himmel-size-override-v1 "HIMMEL-9302|N932|41|0|no|worker:N932|big but fine")
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9302\tN932\t41\t0\tno\tworker:N932\tbig but fine\t%s\n' "$mac" >> "$LEDGER"
out=$(run check HIMMEL-9302 N932 --files 41); rc=$?
check "a validly signed row from a non-console source is refused" 1 "$rc"
out=$(bash "$SUT" check HIMMEL-9201 N921 --files 41 --root "$tmp/no-such-root" 2>&1); rc=$?
check "check with no ledger exits 1" 1 "$rc"

# ---- 4. the operator's cases ----
out=$(run record HIMMEL-9400 N940 --files 25 --trust yes --reason "trust path, keep whole"); rc=$?
check "record refuses a trust-path brief over the soft band (4)" 4 "$rc"
has "the refusal routes to the operator" "$out" "operator"
out=$(run record HIMMEL-9401 N941 --files 301 --reason "huge"); rc=$?
check "record refuses a brief past the 300-file cap (4)" 4 "$rc"
has "the 300-file refusal routes to the operator" "$out" "operator"
out=$(run record HIMMEL-9402 N942 --files 41 --lines 1501 --reason "huge"); rc=$?
check "record refuses a brief past the 1500-line max (4)" 4 "$rc"
out=$(run record HIMMEL-9403 N943 --files 20 --trust yes --reason "trust path inside the soft band"); rc=$?
check "a trust-path brief inside the soft band is the chief's (0)" 0 "$rc"
out=$(run check HIMMEL-9403 N943 --files 20 --trust yes); rc=$?
check "check passes a trust-path brief inside the soft band" 0 "$rc"
mac=$(go_msg_mac himmel-size-override-v1 "HIMMEL-9400|N940|25|0|yes|console:chief-x|older record")
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9400\tN940\t25\t0\tyes\tconsole:chief-x\tolder record\t%s\n' "$mac" >> "$LEDGER"
out=$(run check HIMMEL-9400 N940 --files 25 --trust yes); rc=$?
check "a validly signed row does not lift a trust-path brief over the soft band (4)" 4 "$rc"
has "the check message routes to the operator" "$out" "operator"
mac=$(go_msg_mac himmel-size-override-v1 "HIMMEL-9404|N944|301|0|no|console:chief-x|older record")
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9404\tN944\t301\t0\tno\tconsole:chief-x\tolder record\t%s\n' "$mac" >> "$LEDGER"
out=$(run check HIMMEL-9404 N944 --files 301); rc=$?
check "a validly signed row does not lift a brief past 300 files (4)" 4 "$rc"
mac=$(go_msg_mac himmel-size-override-v1 "HIMMEL-9405|N945|41|1501|no|console:chief-x|older record")
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9405\tN945\t41\t1501\tno\tconsole:chief-x\tolder record\t%s\n' "$mac" >> "$LEDGER"
out=$(run check HIMMEL-9405 N945 --files 41); rc=$?
check "a validly signed row recording more than 1500 lines does not pass (4)" 4 "$rc"
out=$(run check HIMMEL-9406 N946 --files 25 --trust yes); rc=$?
check "check sends a trust-path brief over the soft band to the operator even with no row (4)" 4 "$rc"

# ---- 5. a kit with no size bands fails closed ----
KIT="$tmp/kit"; mkdir -p "$KIT/scripts/handover/chief-kit" "$KIT/scripts/lib"
cp "$SUT" "$KIT/scripts/handover/chief-kit/size-override.sh"
cp "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$KIT/scripts/lib/"
KROOT="$tmp/kroot"; mkdir -p "$KROOT"
out=$(bash "$KIT/scripts/handover/chief-kit/size-override.sh" record HIMMEL-9500 N950 --files 25 --trust yes --reason "bands gone" --root "$KROOT" 2>&1); rc=$?
check "record with unreadable size bands exits 2, it does not sign" 2 "$rc"
has "the unreadable-bands message names the bands" "$out" "size bands"
check "record with unreadable size bands writes no row" 0 "$(find "$KROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
out=$(bash "$KIT/scripts/handover/chief-kit/size-override.sh" check HIMMEL-9500 N950 --files 25 --trust yes --root "$KROOT" 2>&1); rc=$?
check "check with unreadable size bands exits 2, it does not pass" 2 "$rc"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
