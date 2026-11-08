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
has "the 300-file refusal says split" "$out" "split"
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
out=$(run record HIMMEL-9407 N947 --files 21 --trust yes --reason "edge"); rc=$?
check "a trust-path brief of 21 files is the operator's (4)" 4 "$rc"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9408 N948 --files 300 --reason "edge"); rc=$?
check "a brief of 300 files is not past the cap: the chief's (0)" 0 "$rc"
out=$(CHIEF_SESSION_NAME=chief-x run record HIMMEL-9409 N949 --files 41 --lines 1500 --reason "edge"); rc=$?
check "a brief of 1500 lines is not past the max: the chief's (0)" 0 "$rc"

# ---- 5. a kit with no size bands fails closed ----
KIT="$tmp/kit"; mkdir -p "$KIT/scripts/handover/chief-kit" "$KIT/scripts/lib"
cp "$SUT" "$KIT/scripts/handover/chief-kit/size-override.sh"
cp "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$KIT/scripts/lib/"
KROOT="$tmp/kroot"; mkdir -p "$KROOT"
out=$(bash "$KIT/scripts/handover/chief-kit/size-override.sh" record HIMMEL-9500 N950 --files 25 --trust yes --reason "bands gone" --root "$KROOT" 2>&1); rc=$?
check "record with unreadable size bands exits 2, it does not sign" 2 "$rc"
has "the unreadable-bands message names the bands" "$out" "size bands"
check "record with unreadable size bands writes no row" 0 "$([ -e "$KROOT/.locks" ] && echo 1 || echo 0)"
out=$(bash "$KIT/scripts/handover/chief-kit/size-override.sh" check HIMMEL-9500 N950 --files 25 --trust yes --root "$KROOT" 2>&1); rc=$?
check "check with unreadable size bands exits 2, it does not pass" 2 "$rc"

REPO="$(cd "$HERE/../../.." && pwd)"
S=46815c6bb3e07b0c47970c8357f49231 S2=0123456789abcdef0123456789abcdef
LINUX=yes; [ "$(uname -s)" = Linux ] || LINUX=no
out=$(bash "$SUT" record HIMMEL-9400 N940 --files 25 --trust yes --reason keep --root "$ROOT" 2>&1 >/dev/null); rc=$?
check "R11: record of a 25-file trust-path brief still exits 4" 4 "$rc"
has "R11: the record refusal names the terminal verb" "$out" "size-override.sh operator"
has "R11: the record refusal names the Telegram op" "$out" "/op size-approval"
out=$(bash "$SUT" record HIMMEL-9401 N941 --files 301 --reason keep --root "$ROOT" 2>&1 >/dev/null); rc=$?
check "R11: record of 301 files still exits 4" 4 "$rc"
has "R11: the past-cap record refusal says split" "$out" "split"
has "R11: the past-cap record refusal says nothing to approve" "$out" "nothing to approve"
case "$out" in *operator*) fail "R11: the past-cap record refusal names no operator route ($out)" ;; *) pass "R11: the past-cap record refusal names no operator route" ;; esac
out=$(bash "$SUT" check HIMMEL-9406 N946 --files 25 --trust yes --root "$ROOT" 2>&1 >/dev/null); rc=$?
check "R11: check of a 25-file trust-path brief still exits 4" 4 "$rc"
has "R11: the check refusal names the terminal verb" "$out" "size-override.sh operator"
has "R11: the check refusal names the Telegram op" "$out" "/op size-approval"
out=$(bash "$SUT" check HIMMEL-9404 N944 --files 301 --root "$ROOT" 2>&1 >/dev/null); rc=$?
check "R11: check of 301 files still exits 4" 4 "$rc"
has "R11: the past-cap check refusal says split and nothing to approve" "$out" "split; there is nothing to approve"
case "$out" in *operator*) fail "R11: the past-cap check refusal names no operator route ($out)" ;; *) pass "R11: the past-cap check refusal names no operator route" ;; esac

check "R8: the approvals dir is a literal constant" 1 "$(grep -c '^SIZE_APPROVALS=/var/lib/himmel/size-approvals$' "$SUT")"
check "R8: the owner uid is a literal constant" 1 "$(grep -c '^SIZE_APPROVAL_UID=0$' "$SUT")"
check "R8: the helper path is a literal constant" 1 "$(grep -c '^AFK_HELPER=/usr/local/libexec/himmel/afk-sudo$' "$SUT")"
check "R8: the reader runs stat and date in a scrubbed bash with a fixed PATH" 1 "$(grep -c '/usr/bin/env -i PATH=/usr/bin:/bin /bin/bash --norc --noprofile -c ' "$SUT")"
for v in SIZE_APPROVALS SIZE_APPROVAL_UID AFK_HELPER; do
    check "R8: no default or assignment form reads $v from the environment" 0 "$(grep -cE "\\\$\\{$v(:?-|:?=)" "$SUT")"
done

AD="$tmp/sa/size-approvals"; mkdir -p "$AD"; chmod 0755 "$tmp/sa" "$AD"
FB="$tmp/fbin"; mkdir -p "$FB"; HLOG="$tmp/helper.log"
cat > "$tmp/fake-helper" <<'FAKEHELPER'
#!/bin/sh
echo "$*" >> "$HLOG"
echo "${HELPER_ANSWER:-result=pending id=abcdefgh expires=1 operator=4242}"
FAKEHELPER
chmod +x "$tmp/fake-helper"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$FB/sudo"; chmod +x "$FB/sudo"
mkreader() {
    local k="$1"
    mkdir -p "$k/scripts/handover/chief-kit"
    ln -s "$REPO/scripts/lib" "$k/scripts/lib"; ln -s "$REPO/scripts/ci" "$k/scripts/ci"
    sed -e "s|^SIZE_APPROVALS=/var/lib/himmel/size-approvals\$|SIZE_APPROVALS=$AD|" -e "s|^SIZE_APPROVAL_UID=0\$|SIZE_APPROVAL_UID=$2|" \
        -e "s|^AFK_HELPER=/usr/local/libexec/himmel/afk-sudo\$|AFK_HELPER=$tmp/fake-helper|" "$SUT" > "$k/scripts/handover/chief-kit/size-override.sh"
    check "the reader copy $k rewrote the approvals dir" 1 "$(grep -c "^SIZE_APPROVALS=$AD\$" "$k/scripts/handover/chief-kit/size-override.sh")"
    check "the reader copy $k rewrote the owner uid" 1 "$(grep -c "^SIZE_APPROVAL_UID=$2\$" "$k/scripts/handover/chief-kit/size-override.sh")"
    check "the reader copy $k rewrote the helper path" 1 "$(grep -c "^AFK_HELPER=$tmp/fake-helper\$" "$k/scripts/handover/chief-kit/size-override.sh")"
}
mkreader "$tmp/rkit" "$(id -u)"
RK="$tmp/rkit/scripts/handover/chief-kit/size-override.sh"
rk() { HLOG="$HLOG" PATH="$FB:$PATH" bash "$RK" "$@" --root "$ROOT"; }
approval() {
    local exp=$(( $(date +%s) + ${3:-3600} ))
    printf 'SIZE-APPROVAL\t%s\tHIMMEL-9228\tN5216\t%s\t%s\tabcdefgh\tkeep-whole\n' "$exp" "${4:-$1}" "${5:-$2}" > "$AD/HIMMEL-9228.N5216.$1.$2"
    chmod 0644 "$AD/HIMMEL-9228.N5216.$1.$2"
}
F="$AD/HIMMEL-9228.N5216.272.$S"

if [ "$LINUX" = no ]; then echo "SKIP: R1, R4 need GNU stat (macOS fails closed; Linux CI gates)"; else
approval 272 "$S"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S" 2>&1); rc=$?
check "R1: the copy accepts a valid operator approval (0)" 0 "$rc"
has "R1: the accept line says the operator kept it whole" "$out" "kept whole by the operator"
has "R1: the accept line names the request id and reason" "$out" "afk abcdefgh"
out=$(bash "$SUT" check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S" --root "$ROOT" 2>&1); rc=$?
check "R1: the real script does not read the scratch approval (4)" 4 "$rc"

r4() {
    local d="$1" why="$2"; shift 2
    out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S" "$@" 2>&1); rc=$?
    check "R4: $d (4)" 4 "$rc"
    [ -z "$why" ] || has "R4: $d names why" "$out" "$why"
}
mv "$F" "$tmp/real-approval"; ln -s "$tmp/real-approval" "$F"
r4 "a symlink in place of the file" "not a regular file"
rm -f "$F"; mv "$tmp/real-approval" "$F"
chmod 0664 "$F"; r4 "a group-writable approval file" "writable"; chmod 0644 "$F"
chmod 0775 "$AD"; r4 "a group-writable approvals dir" "writable"; chmod 0755 "$AD"
chmod 0775 "$tmp/sa"; r4 "a group-writable parent dir (I1 mutation row: drop the parent check and it passes)" "writable"; chmod 0755 "$tmp/sa"
approval 272 "$S" 3600 271; r4 "a file whose files field is 271" "does not match"
approval 272 "$S" 3600 272 "$S2"; r4 "a file whose scope field differs" "does not match"
approval 272 "$S" -1; r4 "an approval that expired a second ago" "expired"
approval 272 "$S"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes 2>&1); rc=$?
check "R4: check without --scope (4)" 4 "$rc"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust no 2>&1); rc=$?
check "R4: --trust no is not the operator's case and the approval does not lift it (1, no chief row)" 1 "$rc"
mkreader "$tmp/rkit2" "$(( $(id -u) + 1 ))"
out=$(HLOG="$HLOG" bash "$tmp/rkit2/scripts/handover/chief-kit/size-override.sh" check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S" --root "$ROOT" 2>&1); rc=$?
check "R4: a file the test user owns is no approval to a reader wanting another uid (4; I1 mutation row: drop the owner check and it passes)" 4 "$rc"
has "R4: the wrong owner is named" "$out" "owned by uid"
approval 301 "$S"
out=$(rk check HIMMEL-9228 N5216 --files 301 --trust yes --scope "$S" 2>&1); rc=$?
check "R4: a valid approval for 301 files lifts nothing past the cap (4)" 4 "$rc"
has "R4: past the cap the refusal says split" "$out" "split"
rm -f "$AD/HIMMEL-9228.N5216.301.$S"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S2" 2>&1); rc=$?
check "R4: an approval for another scope does not lift this one (4)" 4 "$rc"
has "R4: the refusal names the approval it found" "$out" "covers 272 files, scope $S"
has "R4: the refusal names this run's scope" "$out" "scope $S2"
chmod 0664 "$F"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S2" 2>&1)
case "$out" in *covers*) fail "R4: the covers scan names a group-writable approval ($out)" ;; *) pass "R4: the covers scan skips an approval that fails the safety check" ;; esac
chmod 0644 "$F"
approval 272 "$S" 3600 272 "$S2"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S2" 2>&1)
case "$out" in *covers*) fail "R4: the covers scan names an approval whose body is for another list ($out)" ;; *) pass "R4: the covers scan reads only the exact file name for this list" ;; esac
printf 'SIZE-APPROVAL\t%s\tHIMMEL-9999\tN5216\t272\t%s\tabcdefgh\tkeep-whole\n' "$(( $(date +%s) + 3600 ))" "$S" > "$F"
out=$(rk check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$S2" 2>&1)
case "$out" in *covers*) fail "R4: the covers scan names an approval for another key ($out)" ;; *) pass "R4: the covers scan skips an approval that fails the field match" ;; esac
approval 272 "$S"
fi

: > "$HLOG"
out=$(HIMMEL_CONSOLE=1 rk operator HIMMEL-9228 N5216 --files 272 --scope "$S" --reason keep-whole </dev/null 2>/dev/null); rc=$?
check "R2: the operator verb with no terminal exits 75 (pending)" 75 "$rc"
check "R2: it filed one request" 1 "$(wc -l < "$HLOG" | tr -d ' ')"
has "R2: it prints the plain-terminal hint" "$out" "himmelctl approve abcdefgh in a plain terminal"

: > "$HLOG"
out=$(env -i PATH="$FB:/usr/bin:/bin" HOME="$HOME" HLOG="$HLOG" bash "$RK" operator HIMMEL-9228 N5216 --files 272 --scope "$S" --reason keep-whole </dev/null 2>&1); rc=$?
check "R3: a clean-env run is pending (75)" 75 "$rc"
if grep -qE "^op-request --session terminal-[0-9]+ --ticket HIMMEL-9228 -- size-approval key=HIMMEL-9228 label=N5216 files=272 scope=$S reason=keep-whole\$" "$HLOG"; then
    pass "R3: the verb files exactly the size-approval op-request"
else
    fail "R3: the verb files exactly the size-approval op-request (got '$(cat "$HLOG")')"
fi
out=$(HELPER_ANSWER="result=ops-disabled" rk operator HIMMEL-9228 N5216 --files 272 --scope "$S" --reason keep-whole </dev/null 2>&1); rc=$?
check "R3: ops-disabled exits 5" 5 "$rc"
has "R3: ops-disabled names ops.enabled" "$out" "ops.enabled"
out=$(HELPER_ANSWER="result=bad-param name=scope" rk operator HIMMEL-9228 N5216 --files 272 --scope "$S" --reason keep-whole </dev/null 2>&1); rc=$?
check "R3: a schema bad-param exits 2" 2 "$rc"
: > "$HLOG"
out=$(rk operator HIMMEL-9228 N5216 --files 27x --scope "$S" --reason keep-whole </dev/null 2>&1); rc=$?
check "R3: a non-number files exits 2" 2 "$rc"
out=$(rk operator HIMMEL-9228 N5216 --files 272 --scope "$S" --reason "keep;whole" </dev/null 2>&1); rc=$?
check "R3: a reason outside ^[A-Za-z0-9,.:_-]{3,80}\$ exits 2" 2 "$rc"
out=$(rk operator HIMMEL-9228 N5216 --files 301 --scope "$S" --reason keep-whole </dev/null 2>&1 >/dev/null); rc=$?
check "R3: 301 files exits 4" 4 "$rc"
has "R3: past the cap the verb says split" "$out" "split"
check "R3: no refused call reached the helper" 0 "$(wc -l < "$HLOG" | tr -d ' ')"

if [ "$LINUX" = no ] || ! script -qec true /dev/null >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "SKIP: R9 needs util-linux script -qec and node (macOS; Linux CI gates)"
else
    printf '{"operator_id": 4242, "operator_user": "%s"}\n' "$(id -un)" > "$tmp/afk.json"
    printf '#!/bin/sh\nexec node "%s/scripts/himmelctl/bin.js" "$@"\n' "$REPO" > "$FB/himmelctl"; chmod +x "$FB/himmelctl"
    cat > "$tmp/afk-stub" <<'AFKSTUB'
#!/bin/sh
echo "$*" >> "$HLOG.approve"
cat >> "$HLOG.approve"
echo "result=ran id=abcdefgh exit=0 op_result=changed argv=size-approval"
AFKSTUB
    chmod +x "$tmp/afk-stub"
    : > "$HLOG"
    out=$( { sleep 2; printf 'K7QF 123456\r'; sleep 2; } | HLOG="$HLOG" HIMMELCTL_AFK_CONFIG="$tmp/afk.json" HIMMELCTL_AFK_SUDO="$tmp/afk-stub" PATH="$FB:$PATH" \
        script -qec "bash '$RK' operator HIMMEL-9228 N5216 --files 272 --scope $S --reason keep-whole --root '$ROOT'" /dev/null 2>&1); rc=$?
    check "R9: the terminal run exits 0 on op_result=changed" 0 "$rc"
    has "R9: the masked Nonce Code prompt reaches the terminal" "$out" "Nonce Code: "
    has "R9: himmelctl approve got the id the helper printed" "$(cat "$HLOG.approve" 2>/dev/null)" "approve abcdefgh --from 4242"
    has "R9: the typed nonce and code reached the helper on stdin" "$(cat "$HLOG.approve" 2>/dev/null)" "K7QF 123456"
    case "$out" in *K7QF*) fail "R9: the typed nonce is masked on the terminal" ;; *) pass "R9: the typed nonce is masked on the terminal" ;; esac
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
