#!/usr/bin/env bash
# scripts/handover/chief-kit/test-size-override.sh - suite for size-override.sh:
# the SIZE-ESCALATE ledger, the chief-only signed size-override record and the pending read.
#   1. note writes one SIZE-ESCALATE row per call; pending reports only the rows after --since.
#   2. record: refused from a worker or relay (3) and without a reason (2); a chief record lets check pass.
#   3. an unsigned, forged, edited or non-console row, or one for another file count, is no override.
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
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

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

out=$(run check HIMMEL-9400 N940 --files 25 --trust yes); rc=$?
check "check of a trust-path brief of 25 files with no record exits 1, not 4" 1 "$rc"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9400 N940 --files 25 --trust yes --reason "trust path, keep whole"); rc=$?
check "record signs a trust-path brief over the soft band (0)" 0 "$rc"
out=$(run check HIMMEL-9400 N940 --files 25 --trust yes); rc=$?
check "check then passes the trust-path brief of 25 files (0)" 0 "$rc"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9401 N941 --files 301 --reason "huge"); rc=$?
check "record signs a brief of 301 files (0)" 0 "$rc"
lacks "the 301-file record names no operator verb" "$out" "size-override.sh operator"
lacks "the 301-file record names no operator Telegram op" "$out" "/op size-approval"
out=$(run check HIMMEL-9401 N941 --files 301); rc=$?
check "check passes the 301-file brief (0)" 0 "$rc"
lacks "the 301-file check names no operator verb" "$out" "size-override.sh operator"
lacks "the 301-file check names no operator Telegram op" "$out" "/op size-approval"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9402 N942 --files 41 --lines 1600 --reason "huge"); rc=$?
check "record signs a brief of 1600 lines (0)" 0 "$rc"
out=$(run check HIMMEL-9402 N942 --files 41); rc=$?
check "check passes the 1600-line brief (0)" 0 "$rc"
out=$(run check HIMMEL-9403 N943 --files 301); rc=$?
check "check of 301 files with no record exits 1, not 4" 1 "$rc"
out=$(run operator HIMMEL-9228 N5216 --files 272 --scope 46815c6bb3e07b0c47970c8357f49231 --reason keep-whole); rc=$?
check "operator is not a verb (2)" 2 "$rc"
out=$(run check HIMMEL-9401 N941 --files 301 --scope 46815c6bb3e07b0c47970c8357f49231); rc=$?
check "--scope is not an option (2)" 2 "$rc"

n0=$(count SIZE-ESCALATE)
out=$(run note estimate HIMMEL-9500 N950 --files 41 --band hard --trust yes --detail "projects 41 files"); rc=$?
check "note estimate --band hard exits 0" 0 "$rc"
check "note estimate writes one row" $((n0 + 1)) "$(count SIZE-ESCALATE)"
has "the row's detail starts with the band and an empty ref" "$(tail -n 1 "$LEDGER")" "band=hard ref= projects 41 files"
out=$(run note estimate HIMMEL-9500 N950 --files 41 --band hard --detail "again"); rc=$?
check "a second estimate with the same key, label and band exits 0" 0 "$rc"
check "a second estimate with the same key, label and band appends nothing" $((n0 + 1)) "$(count SIZE-ESCALATE)"
run note estimate HIMMEL-9500 N950 --files 301 --band coderabbit --detail "crossed the cap" >/dev/null
check "an estimate at --band coderabbit after --band hard appends one row" $((n0 + 2)) "$(count SIZE-ESCALATE)"
run note real HIMMEL-9500 N950 --files 45 --band hard --ref feat/a --trust unknown --detail "real" >/dev/null
check "a real row with --trust unknown appends one row" $((n0 + 3)) "$(count SIZE-ESCALATE)"
has "a real row carries the band and the ref" "$(tail -n 1 "$LEDGER")" "real${TAB}HIMMEL-9500${TAB}N950${TAB}45${TAB}unknown${TAB}band=hard ref=feat/a real"
run note real HIMMEL-9500 N950 --files 46 --band hard --ref feat/b --trust unknown --detail "real" >/dev/null
check "a real row for the same key, label and band on another --ref appends one row" $((n0 + 4)) "$(count SIZE-ESCALATE)"
run note real HIMMEL-9500 N950 --files 47 --band hard --ref feat/b --trust unknown --detail "real" >/dev/null
check "a real row on the same key, label, band and --ref appends nothing" $((n0 + 4)) "$(count SIZE-ESCALATE)"
run note refuse HIMMEL-9500 N950 --files 41 --detail "old kind" >/dev/null
run note refuse HIMMEL-9500 N950 --files 41 --detail "old kind" >/dev/null
check "note refuse with no --band is never skipped" $((n0 + 6)) "$(count SIZE-ESCALATE)"
run note estimate HIMMEL-9501 N951 --files 0 --trust unknown --detail "cannot be projected" >/dev/null
run note estimate HIMMEL-9501 N951 --files 0 --trust unknown --detail "cannot be projected" >/dev/null
run note bulk HIMMEL-9501 N951 --files 12 --detail "bulk: mechanical" >/dev/null
run note bulk HIMMEL-9501 N951 --files 12 --detail "bulk: mechanical" >/dev/null
check "an estimate or bulk row with no band is written once per key and label" $((n0 + 8)) "$(count SIZE-ESCALATE)"
for _ in 1 2 3 4 5 6 7 8; do run note estimate HIMMEL-9502 N952 --files 41 --band hard >/dev/null & done
wait
check "eight concurrent notes of one case append one row" $((n0 + 9)) "$(count SIZE-ESCALATE)"
out=$(run note estimate HIMMEL-9500 N950 --files 41 --band huge); rc=$?
check "note --band with an unknown band exits 2" 2 "$rc"
out=$(run note real HIMMEL-9500 N950 --files 41 --band hard --ref 'a b'); rc=$?
check "note --ref with a space exits 2" 2 "$rc"
out=$(run record HIMMEL-9500 N950 --files 41 --trust unknown --reason x); rc=$?
check "record --trust unknown exits 2 (a record names yes or no)" 2 "$rc"

KIT="$tmp/kit"; mkdir -p "$KIT/scripts/handover/chief-kit" "$KIT/scripts/lib"
cp "$SUT" "$KIT/scripts/handover/chief-kit/size-override.sh"
cp "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$KIT/scripts/lib/"
KROOT="$tmp/kroot"; mkdir -p "$KROOT"
out=$(CHIEF_SESSION_NAME=chief-x bash "$KIT/scripts/handover/chief-kit/size-override.sh" record HIMMEL-9600 N960 --files 301 --reason "no bands file in this kit" --root "$KROOT" 2>&1); rc=$?
check "record works in a kit with no pr-size-bands.tsv (0)" 0 "$rc"
check "the script names no size bands file" 0 "$(grep -c 'pr-size-bands' "$SUT")"
check "the script names no approvals dir, helper or operator verb" 0 "$(grep -cE 'SIZE_APPROVAL|AFK_HELPER|operator_owned' "$SUT")"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
