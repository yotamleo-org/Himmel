#!/usr/bin/env bash
# Tests for redact_check in scripts/lib/redact.sh: it reads stdin, exits 0 when
# no secret shape matches, else 10+i for shape i and prints
# `shape=<name> precision=<high|low>`.
# Usage: bash scripts/lib/test-redact-check.sh
# Fixtures are built at run time, so no token-shaped literal sits in this file.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/redact.sh"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/redact-check-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

rep() { printf "$1%.0s" $(seq 1 "$2"); }

# check <label> <want-rc> <want-stdout> : stdin is the text
check() {
    local label="$1" want_rc="$2" want_out="$3" out rc
    out=$(bash -c '. "$1" && redact_check' _ "$LIB" 2>&1)
    rc=$?
    if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then pass "$label"; else fail "$label" "rc=$rc out=$out"; fi
}

echo "== clean prose =="
check "clean prose exits 0" 0 "" < <(printf 'The build passed and the PR is ready for review.\n')

echo "== one fixture per shape, in index order =="
names=(gh github_pat sk_ant akia xox bot_token bearer pass_dq pass_sq pass_bare flag_secret dash_p pem)
precs=(high high high high high high high low low low low low high)
fx=("ghp_$(rep b 36)"
    "github_pat_$(rep C 30)"
    "sk-ant-api03-$(rep d 30)"
    "AKIA$(rep E 16)"
    "xoxb-$(rep 1 12)-abc"
    "12345678:$(rep Z 35)"
    "Bearer $(rep f 24)"
    'password="hunter2"'
    "password='hunter2'"
    "password=hunter2"
    "--token $(rep h 20)"
    "mysql -pS3cretpw"
    "x -----BEGIN RSA PRIVATE"" KEY----- abc -----END RSA PRIVATE"" KEY----- y")
i=0
while [ "$i" -lt "${#names[@]}" ]; do
    check "shape ${names[$i]} exits $((10+i))" "$((10+i))" "shape=${names[$i]} precision=${precs[$i]}" < <(printf 'before %s after\n' "${fx[$i]}")
    i=$((i+1))
done

echo "== a 300 kB stdin with one token at the end =="
{ i=0; while [ "$i" -lt 3000 ]; do printf '%0100d\n' 0; i=$((i+1)); done; printf 'ghp_%s\n' "$(rep q 36)"; } > "$tmp/big.txt"
check "the token at the end of 300 kB matches" 10 "shape=gh precision=high" < "$tmp/big.txt"

echo "== a multi-line PEM block =="
check "a multi-line PEM block matches pem" 22 "shape=pem precision=high" < <(printf 'header\n-----BEGIN OPENSSH PRIVATE'' KEY-----\nAAAAB3Nza\n-----END OPENSSH PRIVATE'' KEY-----\n')

echo "== a low-precision shape in test output =="
check "test output matches pass_bare at low precision" 19 "shape=pass_bare precision=low" < <(printf 'Tests pass: 12 fail: 0\n')

echo "== the documented spawn form from a cwd outside the repo =="
out=$(cd "$tmp" && printf 'xoxb-%s-abc\n' "$(rep 2 12)" | bash -c ". $LIB && redact_check")
rc=$?
if [ "$rc" = 14 ] && [ "$out" = "shape=xox precision=high" ]; then pass "spawn form works outside the repo"; else fail "spawn form works outside the repo" "rc=$rc out=$out"; fi

echo
echo "redact-check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
