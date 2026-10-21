#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-oxlint-complexity.sh.
#
# Three cases: a clean fixture passes, a fixture function above the ratchet
# fails with a per-function listing, and a PATH with no bunx/bun fails OPEN
# (exit 0, loud WARN) rather than blocking the commit.
#
# Hermetic: throwaway tempdirs (never a git repo — same non-repo guarantee
# fixture-tempdir.sh gives the other suites here) holding a tiny
# scripts/lanes/*.mjs fixture, so the gate's own `git rev-parse
# --show-toplevel` falls back to the tempdir as repo root and only ever
# scans the fixture file, not this repo's real tree. OXLINT_COMPLEXITY_MAX
# is overridden low so a handful of if-statements is enough to trip the
# ratchet without needing a genuinely gnarly fixture. Needs a real
# bunx/oxlint on PATH for cases 1-2 (network-free once oxlint is cached);
# case 3 only needs PATH manipulation.
#
# Usage: bash scripts/hooks/test-check-oxlint-complexity.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (a here-string is not a pipeline, so `set -o pipefail` cannot
# report a SUCCESSFUL early match as a failed producer).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/check-oxlint-complexity.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# Resolve bash ONCE from the suite's own unmodified PATH, before any test
# hands the gate a narrowed one. Case 3 below invokes this absolute
# path so the narrowed PATH
# decides what the GATE sees, never whether it can start at all.
BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi
# Refusing a relative PATH is deliberate: these are hermetic fixtures.
# A bash resolved through a relative PATH means the invoking environment
# is already broken in a way that makes any result untrustworthy
#
case "$BASH_ABS" in
    /*) ;;
    *) echo "FATAL: bash resolved to a non-absolute path ('$BASH_ABS') — this fixture invokes it after a cd and/or as a shim shebang, both of which need an absolute path" >&2; exit 1 ;;
esac

FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_says() {
    local label="$1" needle="$2" text="$3"
    if grepq "$text" -- "$needle"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     output: $text"
        FAILED=$((FAILED + 1))
    fi
}

# Source-level pin plus parity with the sibling hardening gate:
# both gates must invoke the SAME oxlint version, so a future bump of one
# without the other goes red here rather than in CI.
HARDENING_GATE="$SCRIPT_DIR/check-oxlint-hardening.sh"
if grep -q '^OXLINT_VERSION=1\.89\.0$' "$GATE"; then
    echo "PASS gate pins OXLINT_VERSION=1.89.0"
else
    echo "FAIL gate must pin OXLINT_VERSION=1.89.0"
    FAILED=$((FAILED + 1))
fi

complexity_pin=$(grep -oE '^OXLINT_VERSION=.*$' "$GATE")
hardening_pin=$(grep -oE '^OXLINT_VERSION=.*$' "$HARDENING_GATE")
assert_eq "complexity gate's OXLINT_VERSION matches the hardening gate's" \
  "$hardening_pin" "$complexity_pin"

# --- bun present, bunx absent → gate runs oxlint through `bun x` ---
# PATH layout copied from the main station: ~/.bun/bin holds `bun` and NOTHING
# else (`ls -la ~/.bun/bin` → one 755 `bun`), so `command -v bunx` is empty
# while `bun x` works. The stub stands in for bun; only grep is linked in
# because the gate pipes oxlint output through it. Runs before the bunx SKIP
# below so a bunx-less box still exercises it.
BUN_ONLY=$(fixture_mktemp_dir) || exit 1
mkdir -p "$BUN_ONLY/scripts/lanes"
printf '%s\n' 'export function add(a, b) { return a + b; }' > "$BUN_ONLY/scripts/lanes/clean.mjs"
BUN_ONLY_BIN=$(fixture_mktemp_dir) || exit 1
GREP_ABS=$(command -v grep)
ln -s "$GREP_ABS" "$BUN_ONLY_BIN/grep"
cat > "$BUN_ONLY_BIN/bun" <<EOF
#!$BASH_ABS
printf 'arg=%s\n' "\$@" > "$BUN_ONLY/record.txt"
if [ "\${OXLINT_STUB_REGRESSION:-}" = 1 ]; then
    echo 'eslint(complexity): Function has a complexity of 30. Maximum allowed is 20.'
    exit 1
fi
exit 0
EOF
chmod +x "$BUN_ONLY_BIN/bun"
if PATH="$BUN_ONLY_BIN" command -v bunx >/dev/null 2>&1 || ! PATH="$BUN_ONLY_BIN" command -v bun >/dev/null 2>&1; then
    echo "FAIL fixture control: bun-only PATH must resolve bun and not bunx"
    FAILED=$((FAILED + 1))
else
    echo "PASS fixture control: bun-only PATH resolves bun and not bunx"
fi
rc=0
out=$(cd "$BUN_ONLY" && PATH="$BUN_ONLY_BIN" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "bun without bunx → gate passes (exit 0)" "0" "$rc"
rec=$(cat "$BUN_ONLY/record.txt" 2>/dev/null || true)
assert_says "bun without bunx → ran oxlint through bun x" "arg=x" "$rec"
assert_says "bun without bunx → pinned package" "arg=oxlint@1.89.0" "$rec"
rm -f "$BUN_ONLY/record.txt"
rc=0
out=$(cd "$BUN_ONLY" && OXLINT_STUB_REGRESSION=1 OXLINT_COMPLEXITY_MAX=22 PATH="$BUN_ONLY_BIN" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "bun without bunx → a regression still blocks (exit 1)" "1" "$rc"
rm -rf "$BUN_ONLY" "$BUN_ONLY_BIN"

# --- `--files` changed-files mode + OXLINT_FAIL_CLOSED ---
# The stub's finding line is copied from a real run on this station:
#   bun x oxlint@1.89.0 -A all -W complexity scripts/lanes/b.mjs  (25-branch function)
#   -> scripts/lanes/b.mjs:1:8: warning eslint(complexity): function `b` has a complexity of 26. Maximum allowed is 20.
# and real oxlint exits 0 on a warning-only run, which the stub copies.
FILES_FX=$(fixture_mktemp_dir) || exit 1
mkdir -p "$FILES_FX/scripts/lanes" "$FILES_FX/docs" "$FILES_FX/scripts/lanes/fixtures"
printf '%s\n' 'export function add(a, b) { return a + b; }' > "$FILES_FX/scripts/lanes/clean.mjs"
printf '%s\n' '# notes' > "$FILES_FX/docs/notes.md"
printf '%s\n' 'x' > "$FILES_FX/scripts/lanes/fixtures/skip.mjs"
FILES_BIN=$(fixture_mktemp_dir) || exit 1
ln -s "$(command -v grep)" "$FILES_BIN/grep"
cat > "$FILES_BIN/bun" <<EOF
#!$BASH_ABS
printf 'arg=%s\n' "\$@" > "$FILES_FX/record.txt"
echo 'scripts/lanes/b.mjs:1:8: warning eslint(complexity): function \`b\` has a complexity of 26. Maximum allowed is 20.'
exit 0
EOF
chmod +x "$FILES_BIN/bun"
rc=0
out=$(cd "$FILES_FX" && PATH="$FILES_BIN" "$BASH_ABS" "$GATE" --files docs/notes.md scripts/lanes/fixtures/skip.mjs scripts/lanes/gone.mjs 2>&1) || rc=$?
assert_eq "--files with nothing in the surface → exit 0" "0" "$rc"
assert_says "--files with nothing in the surface → says nothing to lint" "nothing to lint" "$out"
if [ -e "$FILES_FX/record.txt" ]; then
    echo "FAIL --files with nothing in the surface → oxlint must not run"
    FAILED=$((FAILED + 1))
else
    echo "PASS --files with nothing in the surface → oxlint not run"
fi
rc=0
out=$(cd "$FILES_FX" && PATH="$FILES_BIN" "$BASH_ABS" "$GATE" --files docs/notes.md scripts/lanes/clean.mjs 2>&1) || rc=$?
rec=$(cat "$FILES_FX/record.txt" 2>/dev/null || true)
assert_says "--files lints the surface file" "arg=scripts/lanes/clean.mjs" "$rec"
if grepq "$rec" -- "docs/notes.md"; then
    echo "FAIL --files must drop a path outside the surface"
    FAILED=$((FAILED + 1))
else
    echo "PASS --files drops a path outside the surface"
fi
assert_eq "--files with a function below the default ratchet (58) → exit 0" "0" "$rc"
rc=0
out=$(cd "$FILES_FX" && OXLINT_COMPLEXITY_MAX=22 PATH="$FILES_BIN" "$BASH_ABS" "$GATE" --files scripts/lanes/clean.mjs 2>&1) || rc=$?
assert_eq "--files with a function above the ratchet → exit 1" "1" "$rc"
rc=0
out=$(cd "$FILES_FX" && PATH="$FILES_BIN" "$BASH_ABS" "$GATE" scripts/lanes/clean.mjs 2>&1) || rc=$?
assert_eq "a bare path argument (no --files) → usage exit 2" "2" "$rc"
rc=0
out=$(cd "$FILES_FX" && OXLINT_FAIL_CLOSED=1 PATH="$(fixture_mktemp_dir)" "$BASH_ABS" "$GATE" --files scripts/lanes/clean.mjs 2>&1) || rc=$?
assert_eq "OXLINT_FAIL_CLOSED=1 with no bun → exit 1 (not fail-open)" "1" "$rc"
CRASH_BIN=$(fixture_mktemp_dir) || exit 1
ln -s "$(command -v grep)" "$CRASH_BIN/grep"
cat > "$CRASH_BIN/bun" <<EOF
#!$BASH_ABS
echo 'error: failed to fetch oxlint@1.89.0' >&2
exit 1
EOF
chmod +x "$CRASH_BIN/bun"
rc=0
out=$(cd "$FILES_FX" && OXLINT_FAIL_CLOSED=1 PATH="$CRASH_BIN" "$BASH_ABS" "$GATE" --files scripts/lanes/clean.mjs 2>&1) || rc=$?
assert_eq "OXLINT_FAIL_CLOSED=1 with an oxlint crash (stderr, exit 1) → exit 1" "1" "$rc"
rc=0
out=$(cd "$FILES_FX" && PATH="$CRASH_BIN" "$BASH_ABS" "$GATE" --files scripts/lanes/clean.mjs 2>&1) || rc=$?
assert_eq "OXLINT_FAIL_CLOSED unset with an oxlint crash → exit 0 (fail-open)" "0" "$rc"
rm -rf "$CRASH_BIN"
printf '%s\n' 'export function add(a, b) { return a + b; }' > "$FILES_FX/scripts/lanes/my file.mjs"
rm -f "$FILES_FX/record.txt"
rc=0
out=$(cd "$FILES_FX" && PATH="$FILES_BIN" "$BASH_ABS" "$GATE" --files "scripts/lanes/my file.mjs" 2>&1) || rc=$?
rec=$(cat "$FILES_FX/record.txt" 2>/dev/null || true)
assert_says "--files keeps a path with a space whole and lints it" "arg=scripts/lanes/my file.mjs" "$rec"
rm -rf "$FILES_FX" "$FILES_BIN"

if ! command -v bunx >/dev/null 2>&1; then
    if [ "$FAILED" -eq 0 ]; then
        echo "SKIP test-check-oxlint-complexity: bunx not on PATH — cannot exercise the pass/fail cases"
        exit 0
    fi
    echo "SKIP test-check-oxlint-complexity: bunx not on PATH — cannot exercise the pass/fail cases (pin/parity checks above already FAILED)"
    exit 1
fi

make_clean_fixture() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/scripts/lanes"
    cat > "$dir/scripts/lanes/clean.mjs" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
    echo "$dir"
}

make_regressed_fixture() {
    local dir i
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/scripts/lanes"
    {
        echo 'export function branchy(n) {'
        # oxlint's complexity rule only reports functions above ITS OWN
        # default max (20) in the first place, regardless of our ratchet —
        # so the fixture needs real complexity above 20, not just above the
        # (lower) OXLINT_COMPLEXITY_MAX the test overrides below. 25
        # branches -> complexity 26.
        i=1
        while [ "$i" -le 25 ]; do
            echo "  if (n === $i) return $i;"
            i=$((i + 1))
        done
        echo '  return 0;'
        echo '}'
    } > "$dir/scripts/lanes/branchy.mjs"
    echo "$dir"
}

# --- Case 1: clean fixture, threshold well above its complexity → passes ---
CLEAN=$(make_clean_fixture) || exit 1
rc=0
out=$(cd "$CLEAN" && OXLINT_COMPLEXITY_MAX=5 bash "$GATE" 2>&1) || rc=$?
assert_eq "clean fixture → gate passes (exit 0)" "0" "$rc"
rm -rf "$CLEAN"

# --- Case 2: fixture function (complexity 26) above a lowered ratchet → fails ---
REGRESSED=$(make_regressed_fixture) || exit 1
rc=0
out=$(cd "$REGRESSED" && OXLINT_COMPLEXITY_MAX=22 bash "$GATE" 2>&1) || rc=$?
assert_eq "regressed fixture → gate blocks (exit 1)" "1" "$rc"
assert_says "regressed fixture → names the offending function" "branchy" "$out"
assert_says "regressed fixture → names the ratchet value" "max 22" "$out"
rm -rf "$REGRESSED"

# --- Case 3: bunx/bun absent from PATH → fails OPEN (exit 0, loud WARN) ---
#
# An allowlist PATH -- an EMPTY scratch dir, so bunx/bun are absent
# regardless of where they live on the host.
# The prior version filtered PATH by NAME
# (`grep -viE '(^|/)\.?bun(/bin)?$'`), which matches a `~/.bun/bin`-shaped
# directory but NOT `/usr/bin` -- on a host where bun/bunx ship in /usr/bin
# (Arch/CachyOS: both live there), that filter left bunx fully reachable and
# the gate correctly never warned, so this case silently tested nothing. The
# gate needs no external tool before its own bunx check (`git rev-parse
# --show-toplevel` falls back to `pwd` on failure, `command -v bunx` is a
# bash builtin, verified empirically) -- an EMPTY allowlist is sufficient,
# and it is a stronger no-bunx guarantee than filtering names ever was.
NOTOOL=$(make_clean_fixture) || exit 1
NO_BUNX_PATH=$(fixture_mktemp_dir) || exit 1
# Positive control for the instrument: the allowlist PATH resolves no bunx
# or bun at all. A "bunx not found" verdict proves nothing if bunx was never
# removed.
if PATH="$NO_BUNX_PATH" command -v bunx >/dev/null 2>&1 || PATH="$NO_BUNX_PATH" command -v bun >/dev/null 2>&1; then
    echo "FAIL fixture control: allowlist PATH still resolves bun/bunx"
    FAILED=$((FAILED + 1))
else
    echo "PASS fixture control: allowlist PATH resolves no bun/bunx"
fi
rc=0
out=$(cd "$NOTOOL" && PATH="$NO_BUNX_PATH" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "no bunx on PATH → gate fails open (exit 0)" "0" "$rc"
assert_says "no bunx on PATH → loud WARN" "WARN" "$out"
rm -rf "$NOTOOL" "$NO_BUNX_PATH"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
