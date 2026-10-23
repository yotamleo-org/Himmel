#!/usr/bin/env bash
# test-snyk-scan.sh - snyk-scan.sh: preflight, the Open Source + Code run, the
# state-repo JSON + summary, the High/Critical exit code and the monthly quota
# guard. Hermetic: snyk is a stub on PATH, HOME, state and output dirs live in
# a mktemp dir; the real Snyk API is never called.
# Fixtures: fixtures/snyk-os-*.json are the real `snyk test --all-projects --json`
# output (lodash 4.17.15, trimmed to one vulnerability, org and path
# anonymised); fixtures/snyk-code-*.json follow the SARIF 2.1.0 shape Snyk
# documents, because the station org has Snyk Code switched off.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN="$DIR/snyk-scan.sh"
FIX="$DIR/fixtures"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi; }
hasnt() { # a missing or unreadable file is a failure, never proof of absence
    if [ ! -r "$3" ]; then fail "$1 ($3 is unreadable)"; return; fi
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail "$1 ('$2' present in $3)"; else pass "$1"; fi
}

W="$(mktemp -d "${TMPDIR:-/tmp}/snyk-scan-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
export SNYK_TOKEN="canary-token-must-never-print"

# A repo with two supported manifest dirs (a/ npm, b/ pip) and one fixture dir
# the scan must not count.
R="$W/repo"
mkdir -p "$R/a" "$R/b" "$R/fixtures/x"
printf '{}\n' > "$R/a/package.json"; printf '{}\n' > "$R/a/package-lock.json"
printf 'flask\n' > "$R/b/requirements.txt"
printf '{}\n' > "$R/fixtures/x/package.json"
git init -q "$R"; git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@t commit -q -m fixture

# Stub snyk. STUB_AUTH=0 -> whoami fails; STUB_OS / STUB_CODE name the JSON to
# print, STUB_OS_RC / STUB_CODE_RC the exit codes; STUB_CODE=off -> the real
# "not supported for your current organization" reply.
BIN="$W/bin"; mkdir -p "$BIN"
cat > "$BIN/snyk" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_DIR/calls.log"
case "$1" in
    whoami)
        [ "${STUB_AUTH:-1}" = 1 ] || { echo "Authentication failed" >&2; exit 2; }
        echo "stub-user"; exit 0 ;;
    test)
        cat "$STUB_OS"; exit "${STUB_OS_RC:-0}" ;;
    code)
        if [ "$STUB_CODE" = off ]; then
            printf '{\n  "ok": false,\n  "error": "Snyk Code is not supported for your current organization: `stub-org`.",\n  "path": "%s"\n}\n' "$PWD"
            exit 2
        fi
        cat "$STUB_CODE"; exit "${STUB_CODE_RC:-0}" ;;
esac
exit 2
SH
chmod +x "$BIN/snyk"
export STUB_DIR="$W"
# keep the real PATH for jq/git/awk but put the stub first
export PATH="$BIN:$PATH"
export SNYK_SCAN_STATE_DIR="$W/state"

run() { # <name> [args...]; sets OUT, RC; fresh out + state per call
    local n="$1"; shift
    OUTDIR="$W/out-$n"; rm -rf "$OUTDIR" "$SNYK_SCAN_STATE_DIR"
    OUT="$W/$n.log"; : > "$W/calls.log"
    bash "$SCAN" --repo "$R" --out-dir "$OUTDIR" --date 2026-10-23 "$@" > "$OUT" 2>&1
    RC=$?
}

# --- the DoD pair: High fixture exits 1, clean fixture exits 0 ---------------
export STUB_OS="$FIX/snyk-os-high.json" STUB_OS_RC=1 STUB_CODE=off
run high
check "High Open Source finding exits 1" 1 "$RC"
[ -s "$OUTDIR/2026-10-23.json" ] && pass "JSON written to out-dir/<date>.json" || fail "JSON written to out-dir/<date>.json"
[ -s "$OUTDIR/2026-10-23.summary.md" ] && pass "summary written to out-dir/<date>.summary.md" || fail "summary written"
has "summary names the High vulnerability id" "SNYK-JS-LODASH-6139239" "$OUTDIR/2026-10-23.summary.md"
has "summary counts the High finding" "high: 1" "$OUTDIR/2026-10-23.summary.md"
check "combined JSON keeps the raw Open Source result" "SNYK-JS-LODASH-6139239" "$(jq -r '.open_source[0].vulnerabilities[0].id' "$OUTDIR/2026-10-23.json")"
has "Open Source run uses --all-projects --json" "test --all-projects --json --severity-threshold=medium" "$W/calls.log"
has "scan runs from inside the repo" "$R|test" "$W/calls.log"
has "excluded dirs keep fixtures out of the quota" "--exclude=" "$W/calls.log"

export STUB_OS="$FIX/snyk-os-clean.json" STUB_OS_RC=0 STUB_CODE=off
run clean
check "clean fixture exits 0" 0 "$RC"
has "clean summary says no High or Critical" "high: 0" "$OUTDIR/2026-10-23.summary.md"

# --- Snyk Code: not enabled is SKIPPED, a High SARIF result gates ------------
has "Code not enabled reads SKIPPED not-enabled" "SKIPPED not-enabled" "$OUTDIR/2026-10-23.summary.md"
check "Code not-enabled is recorded in the JSON" "not-enabled" "$(jq -r '.code_status' "$OUTDIR/2026-10-23.json")"

export STUB_OS="$FIX/snyk-os-clean.json" STUB_OS_RC=0 STUB_CODE="$FIX/snyk-code-high.json" STUB_CODE_RC=1
run codehigh
check "High Code finding exits 1" 1 "$RC"
has "summary names the Code rule" "javascript/DOMXSS" "$OUTDIR/2026-10-23.summary.md"
has "Code run uses code test --json" "code test --json" "$W/calls.log"

export STUB_CODE="$FIX/snyk-code-clean.json" STUB_CODE_RC=0
run codeclean
check "clean Code + clean Open Source exits 0" 0 "$RC"

# --- the token never reaches an output ---------------------------------------
cat "$OUT" "$OUTDIR"/2026-10-23.* > "$W/all-out.txt"
hasnt "SNYK_TOKEN value is never printed or written" "$SNYK_TOKEN" "$W/all-out.txt"

# --- preflight: missing / unauthenticated snyk ------------------------------
export STUB_OS="$FIX/snyk-os-clean.json" STUB_OS_RC=0 STUB_CODE=off
STUB_AUTH=0 run noauth
check "unauthenticated snyk exits 2" 2 "$RC"
has "unauthenticated message names snyk auth" "snyk auth" "$OUT"
check "no scan ran without auth" 0 "$(grep -c '^[^|]*|test' "$W/calls.log")"

STUB_AUTH=0 run checkauth --check
check "--check on unauthenticated snyk exits 0" 0 "$RC"
has "--check on unauthenticated snyk prints WARN" "WARN snyk" "$OUT"

OUTDIR="$W/out-nosnyk"; rm -rf "$SNYK_SCAN_STATE_DIR"
SNYK_BIN="$W/does-not-exist" bash "$SCAN" --repo "$R" --out-dir "$OUTDIR" --date 2026-10-23 > "$W/nosnyk.log" 2>&1
check "missing snyk exits 2" 2 "$?"
has "missing snyk is named" "snyk not found" "$W/nosnyk.log"
SNYK_BIN="$W/does-not-exist" bash "$SCAN" --repo "$R" --out-dir "$OUTDIR" --check > "$W/nosnyk-check.log" 2>&1
check "--check on missing snyk exits 0" 0 "$?"
has "--check on missing snyk prints WARN" "WARN snyk" "$W/nosnyk-check.log"

: > "$W/empty.json"
STUB_OS="$W/empty.json" STUB_OS_RC=0 run emptyos
check "empty snyk test output exits 2, not a clean scan" 2 "$RC"
printf 'null\n' > "$W/null.json"
STUB_OS="$W/null.json" STUB_OS_RC=0 run nullos
check "a null snyk test result exits 2, not one clean project" 2 "$RC"
printf '"ok"\n' > "$W/scalar.json"
STUB_OS="$W/scalar.json" STUB_OS_RC=0 run scalaros
check "a scalar snyk test result exits 2" 2 "$RC"
# arrays holding a non-object, and project entries that are not scan results, never read as clean
printf '[1]\n' > "$W/arr-scalar.json"
STUB_OS="$W/arr-scalar.json" STUB_OS_RC=0 run arrscalar
check "an array holding a scalar exits 2" 2 "$RC"
printf '[null]\n' > "$W/arr-null.json"
STUB_OS="$W/arr-null.json" STUB_OS_RC=0 run arrnull
check "an array holding null exits 2" 2 "$RC"
jq -c '[., 1]' "$FIX/snyk-os-clean.json" > "$W/arr-mixed.json"
STUB_OS="$W/arr-mixed.json" STUB_OS_RC=0 run arrmixed
check "a project array with a non-object element exits 2" 2 "$RC"
printf '{"ok":false,"error":"Could not detect supported target files","path":"/example/proj"}\n' > "$W/proj-error.json"
STUB_OS="$W/proj-error.json" STUB_OS_RC=0 run projerror
check "a per-project error entry exits 2, not a clean project" 2 "$RC"
jq -c '[., {"ok":false,"error":"Could not detect supported target files","path":"/x"}]' "$FIX/snyk-os-clean.json" > "$W/arr-error.json"
STUB_OS="$W/arr-error.json" STUB_OS_RC=0 run arrerror
check "an error entry beside a clean project exits 2" 2 "$RC"
printf '{"ok":true,"path":"/example/proj"}\n' > "$W/proj-novulns.json"
STUB_OS="$W/proj-novulns.json" STUB_OS_RC=0 run projnovulns
check "a project without a vulnerabilities array exits 2" 2 "$RC"
printf '[{"ok":true,"path":"/x","vulnerabilities":[1]}]\n' > "$W/proj-badvuln.json"
STUB_OS="$W/proj-badvuln.json" STUB_OS_RC=0 run projbadvuln
check "a jq error reading the Open Source findings exits 2" 2 "$RC"
printf '{"runs":[{"results":[1]}]}\n' > "$W/code-badrow.json"
STUB_OS="$FIX/snyk-os-clean.json" STUB_OS_RC=0 STUB_CODE="$W/code-badrow.json" STUB_CODE_RC=0 run codebadrow
check "a jq error reading the Code findings exits 2" 2 "$RC"

# --- quota guard ------------------------------------------------------------
OUTDIR="$W/out-quota"; rm -rf "$OUTDIR" "$SNYK_SCAN_STATE_DIR"; mkdir -p "$SNYK_SCAN_STATE_DIR"
: > "$W/calls.log"
printf '2026-10-01\topen_source\t199\n' > "$SNYK_SCAN_STATE_DIR/usage-2026-10.tsv"
bash "$SCAN" --repo "$R" --out-dir "$OUTDIR" --date 2026-10-23 > "$W/quota.log" 2>&1
check "quota guard refuses a run that would pass the cap" 2 "$?"
has "refusal names the quota" "quota" "$W/quota.log"
check "snyk test never ran past the cap" 0 "$(grep -c '^[^|]*|test' "$W/calls.log")"
[ ! -e "$OUTDIR/2026-10-23.json" ] && pass "no JSON written when the quota refuses" || fail "no JSON written when the quota refuses"

: > "$W/calls.log"
SNYK_SCAN_OS_CAP=250 bash "$SCAN" --repo "$R" --out-dir "$OUTDIR" --date 2026-10-23 > "$W/quota-raised.log" 2>&1
check "a raised cap lets the run through" 0 "$?"

# boundary: 198 used + 2 counted dirs = the cap, allowed; counting the fixtures dir would make it 201
: > "$W/calls.log"; rm -rf "$SNYK_SCAN_STATE_DIR"; mkdir -p "$SNYK_SCAN_STATE_DIR"
printf '2026-10-01\topen_source\t198\n' > "$SNYK_SCAN_STATE_DIR/usage-2026-10.tsv"
bash "$SCAN" --repo "$R" --out-dir "$W/out-boundary" --date 2026-10-23 > "$W/boundary.log" 2>&1
check "the estimate excludes fixtures dirs (198 + 2 = cap, allowed)" 0 "$?"

# a different month does not count against this one
rm -rf "$SNYK_SCAN_STATE_DIR"; mkdir -p "$SNYK_SCAN_STATE_DIR"
printf '2026-09-30\topen_source\t199\n' > "$SNYK_SCAN_STATE_DIR/usage-2026-09.tsv"
bash "$SCAN" --repo "$R" --out-dir "$W/out-month" --date 2026-10-23 > "$W/month.log" 2>&1
check "last month's usage does not count" 0 "$?"

# --- a scan that did not complete is never a clean pass ----------------------
printf 'boom\n' > "$W/bad-code.json"
export STUB_OS="$FIX/snyk-os-clean.json" STUB_OS_RC=0 STUB_CODE="$W/bad-code.json" STUB_CODE_RC=2
run codeerr
check "a failed Code scan (not a skip) exits 2" 2 "$RC"
check "the failed Code scan is recorded as error" "error" "$(jq -r '.code_status' "$OUTDIR/2026-10-23.json")"
export STUB_CODE=off STUB_CODE_RC=0

# a state dir that cannot be created must refuse the run, never scan unmetered
printf 'x\n' > "$W/not-a-dir"
: > "$W/calls.log"
SNYK_SCAN_STATE_DIR="$W/not-a-dir/state" bash "$SCAN" --repo "$R" --out-dir "$W/out-nostate" --date 2026-10-23 > "$W/nostate.log" 2>&1
check "an unwritable usage ledger refuses the run" 2 "$?"
has "refusal names the ledger" "usage" "$W/nostate.log"
check "no scan ran with an unwritable ledger" 0 "$(grep -c '^[^|]*|test' "$W/calls.log")"

# an existing ledger file that cannot be appended to is just as unmetered
mkdir -p "$W/ro-state"
printf '2026-10-01\topen_source\t1\n' > "$W/ro-state/usage-2026-10.tsv"; chmod 444 "$W/ro-state/usage-2026-10.tsv"
: > "$W/calls.log"
SNYK_SCAN_STATE_DIR="$W/ro-state" bash "$SCAN" --repo "$R" --out-dir "$W/out-ro" --date 2026-10-23 > "$W/rostate.log" 2>&1
check "a read-only usage ledger refuses the run" 2 "$?"
has "read-only refusal names the ledger" "usage" "$W/rostate.log"
check "no scan ran with a read-only ledger" 0 "$(grep -c '^[^|]*|test' "$W/calls.log")"

# --- usage is recorded as tests (one per project), not as runs --------------
rm -rf "$SNYK_SCAN_STATE_DIR"
bash "$SCAN" --repo "$R" --out-dir "$W/out-usage" --date 2026-10-23 > "$W/usage.log" 2>&1
check "usage ledger counts one Open Source test per project" 1 "$(awk -F'\t' '$2=="open_source"{s+=$3} END{print s+0}' "$SNYK_SCAN_STATE_DIR/usage-2026-10.tsv")"

# --- weekly cadence: snyk-scan-cadence.sh ---------------------------------------
CAD="$DIR/snyk-scan-cadence.sh"
export CADENCE_ALERT_FILE="$W/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$W/alert-sent"
export CADENCE_ALERT_SEND_CMD="$W/send.sh"
# shellcheck disable=SC2016  # the stub scripts keep their own $ literal
printf '#!/usr/bin/env bash\necho "$1" >> "%s/sent.log"\n' "$W" > "$W/send.sh"; chmod +x "$W/send.sh"
# shellcheck disable=SC2016  # the stub scan keeps its own $ literal
printf '#!/usr/bin/env bash\necho "stub-scan $*"\nexit "$(cat "%s/scan.rc")"\n' "$W" > "$W/scan.sh"; chmod +x "$W/scan.sh"
export SNYKCAD_SCAN="$W/scan.sh"
export SNYK_SCAN_STATE_DIR="$W/cad-state"

echo 1 > "$W/scan.rc"
bash "$CAD" run --repo "$R" > "$W/cad-run1.log" 2>&1
check "cadence run with a High finding exits 1" 1 "$?"
has "High finding raises the shared alert" "snyk-scan high-findings" "$W/alerts.log"
has "the alert reaches the sender" "snyk-scan" "$W/sent.log"
has "the scan was handed the repo" "stub-scan --repo $R" "$W/cad-run1.log"

echo 0 > "$W/scan.rc"
bash "$CAD" run --repo "$R" > "$W/cad-run2.log" 2>&1
check "cadence run on a clean scan exits 0" 0 "$?"
[ ! -e "$W/alert-sent/snyk-scan.high-findings" ] && pass "a clean run clears the alert sentinel" || fail "a clean run clears the alert sentinel"

echo 2 > "$W/scan.rc"
bash "$CAD" run --repo "$R" > "$W/cad-run3.log" 2>&1
check "cadence run with a failed scan exits 1" 1 "$?"
has "failed scan raises scan-rc-2" "snyk-scan scan-rc-2" "$W/alerts.log"

# arm / status / disarm against a stub crontab (never the real one)
# shellcheck disable=SC2016  # the stub crontab keeps its own $ literal
# read-sink-ok: printf writes the stub script text; the $TAB reads run inside the stub, on a file under the suite's own temp dir
printf '#!/usr/bin/env bash\nTAB="%s/crontab.txt"\ncase "$1" in -l) [ -f "$TAB" ] && cat "$TAB" || { echo "no crontab for t" >&2; exit 1; } ;; -) cat > "$TAB" ;; esac\n' "$W" > "$W/crontab"; chmod +x "$W/crontab"
export SNYKCAD_CRONTAB="$W/crontab" SNYKCAD_RUNNER_DIR="$W/runner"
bash "$CAD" arm --dry-run > "$W/arm-dry.log" 2>&1
check "arm --dry-run exits 0" 0 "$?"
[ ! -e "$W/crontab.txt" ] && pass "arm --dry-run installs nothing" || fail "arm --dry-run installs nothing"
export HANDOVER_DIR="$W/ho"
bash "$CAD" arm > "$W/arm.log" 2>&1
check "arm exits 0" 0 "$?"
has "arm installs one weekly entry (Monday 06:30)" "30 06 * * 1 " "$W/crontab.txt"
has "arm tags the entry" "# HIMMEL-SnykScan" "$W/crontab.txt"
PRIMARY="$(dirname "$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir)")"
has "the runner starts in the primary checkout" "$(printf 'cd %q || exit 2' "$PRIMARY")" "$W/runner/snyk-scan-cadence.sh"
has "the runner carries the arm-time handover dir" "$(printf 'HANDOVER_DIR=%q' "$W/ho")" "$W/runner/snyk-scan-cadence.sh"
has "the runner exports the handover dir" "export HANDOVER_DIR" "$W/runner/snyk-scan-cadence.sh"
bash "$CAD" arm > "$W/arm2.log" 2>&1
check "a second arm refuses without --force" 3 "$?"
bash "$CAD" status > "$W/status.log" 2>&1
has "status reports ARMED" "ARMED" "$W/status.log"
bash "$CAD" arm --day 9 > "$W/arm-bad.log" 2>&1
check "arm rejects a bad --day" 1 "$?"
bash "$CAD" disarm > "$W/disarm.log" 2>&1
check "disarm exits 0" 0 "$?"
hasnt "disarm removes exactly the entry" "HIMMEL-SnykScan" "$W/crontab.txt"

echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
