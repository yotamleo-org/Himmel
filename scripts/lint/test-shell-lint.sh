#!/usr/bin/env bash
# test-shell-lint.sh — Tests for scripts/lint/shell-lint.sh.
#
# Usage: bash scripts/lint/test-shell-lint.sh
#
# Cases:
#   1. success criterion : staged .sh with unused var + BOM + set -e leak →
#                          all three caught, exit 1
#   2. clean file        : proper set -uo pipefail, no BOM, vars used → exit 0
#   3. statusline exclude : a file under scripts/statusline/ is skipped (mirror gate)
#   4. --staged mode      : lints staged shell files in a git repo, exit 1 on issue
#   5. --help             : exits 0 and prints usage
#   6. errexit variants   : set -eu / set -euo / set -o errexit all flagged;
#                          set -uo pipefail / set -o pipefail NOT flagged
# 7-10. heredoc-body set -e, --staged-from-subdir, missing-file exit 2, set -Ee.
# 11-17. CR-learnings advisory checks: regex-class,
#        mktemp template, bash32 constructs, echo-e, gnu-flag (+BSD-fallback
#        exclusion + gnu-ok exemption), BOM policy split by file type (.ps1:
#        BOM clean / non-ASCII no-BOM = trap), --staged admits .ps1.
# 16d-f. UTF-16LE/BE BOM'd .ps1 clean;
#        non-UTF-8 no-BOM .ps1 = [PS1-ENCODING] (never an automated BOM add).
# 16g. a UTF-16LE-BOM'd SHELL script is a [BOM] error (breaks the shebang);
#        UTF-16/32 is not blessed on every file type.
#  19. [parse] + [quote-break]: an apostrophe in prose inside a
#      single-quoted awk program; includes the parses-but-truncated shape
#      that `bash -n` cannot see, a clean negative control, and a sweep of
#      the real scripts/hooks/ corpus. 19i-19k: a valid `sed '...'file` concatenation must NOT fire, and a
#      truncated program past an earlier complete invocation on the same
#      line MUST fire.
#  18. self-check: shell-lint reports no findings against this
#      suite's own file (its fixtures/assertions are exempted from advisory
#      checks the same way shell-lint.sh exempts its own source).
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe; shellcheck-clean.

set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/shell-lint.sh"

[ -f "$LINT" ] || { printf 'FAIL: shell-lint.sh not found at %s\n' "$LINT"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ $# -ge 2 ] && printf '        %s\n' "$2"
    FAIL=$((FAIL + 1))
}
assert_contains() {
    if grepq "$3" -F -- "$2"; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
    if grepq "$3" -F -- "$2"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}

HAVE_SHELLCHECK=0
command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1
# iconv backs the [PS1-NO-BOM] vs [PS1-ENCODING] split. The
# [PS1-NO-BOM] assertion (valid UTF-8 + no BOM) is iconv-dependent: without
# iconv the linter fails SAFE to [PS1-ENCODING] unverified, so guard it.
HAVE_ICONV=0
command -v iconv >/dev/null 2>&1 && HAVE_ICONV=1

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/shell-lint.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$TMP_ROOT" ] || { echo "FATAL: mktemp -d returned empty" >&2; exit 1; }

# Write a UTF-8 BOM (EF BB BF) then the given body to $1.
_write_bom_file() {
    local path="$1"; shift
    printf '\xEF\xBB\xBF' > "$path"
    cat >> "$path"
}

# ---------------------------------------------------------------------------
# Case 1: success criterion — unused var + BOM + set -e leak, all three caught
# ---------------------------------------------------------------------------
printf '\nCase 1: success criterion (unused var + BOM + set -e leak)\n'

BAD="$TMP_ROOT/bad.sh"
_write_bom_file "$BAD" <<'EOF'
#!/usr/bin/env bash
set -e
unused_var="never referenced"
echo "hi"
EOF

OUT1="$(bash "$LINT" "$BAD" 2>&1)"; EC1=$?

if [ "$EC1" -eq 1 ]; then pass "exit 1 on a file with issues"; else fail "expected exit 1, got $EC1" "$OUT1"; fi
assert_contains "BOM detected" "BOM" "$OUT1"
assert_contains "errexit (set -e) leak detected" "[errexit]" "$OUT1"
if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
    assert_contains "shellcheck unused-var (SC2034) surfaced" "SC2034" "$OUT1"
else
    printf '  SKIP: shellcheck not installed — SC2034 assertion skipped\n'
fi

# ---------------------------------------------------------------------------
# Case 2: clean file → exit 0
# ---------------------------------------------------------------------------
printf '\nCase 2: clean file exits 0\n'

CLEAN="$TMP_ROOT/clean.sh"
cat > "$CLEAN" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
greeting="hello"
printf '%s\n' "$greeting"
EOF

OUT2="$(bash "$LINT" "$CLEAN" 2>&1)"; EC2=$?
if [ "$EC2" -eq 0 ]; then pass "clean file exits 0"; else fail "expected exit 0, got $EC2" "$OUT2"; fi

# ---------------------------------------------------------------------------
# Case 3: statusline path is excluded (mirror the real gate)
# ---------------------------------------------------------------------------
printf '\nCase 3: scripts/statusline/ excluded\n'

mkdir -p "$TMP_ROOT/scripts/statusline"
SL="$TMP_ROOT/scripts/statusline/vendored.sh"
_write_bom_file "$SL" <<'EOF'
#!/usr/bin/env bash
set -e
unused_var="x"
EOF

OUT3="$(bash "$LINT" "$SL" 2>&1)"; EC3=$?
if [ "$EC3" -eq 0 ]; then pass "statusline file skipped (exit 0)"; else fail "expected exit 0 (excluded), got $EC3" "$OUT3"; fi
assert_not_contains "statusline findings not reported" "[errexit]" "$OUT3"

# ---------------------------------------------------------------------------
# Case 4: --staged mode lints staged shell in a git repo
# ---------------------------------------------------------------------------
printf '\nCase 4: --staged mode\n'

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
(
    cd "$REPO" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    printf '\xEF\xBB\xBF' > staged.sh
    cat >> staged.sh <<'EOF'
#!/usr/bin/env bash
set -e
echo hi
EOF
    printf '#!/usr/bin/env bash\nset -uo pipefail\necho clean\n' > unstaged.sh
    git add staged.sh
)
OUT4="$(cd "$REPO" && bash "$LINT" --staged 2>&1)"; EC4=$?
if [ "$EC4" -eq 1 ]; then pass "--staged exits 1 on a staged issue"; else fail "expected exit 1, got $EC4" "$OUT4"; fi
assert_contains "--staged reports the staged file" "staged.sh" "$OUT4"
assert_not_contains "--staged ignores the unstaged file" "unstaged.sh" "$OUT4"

# ---------------------------------------------------------------------------
# Case 5: --help
# ---------------------------------------------------------------------------
printf '\nCase 5: --help\n'

HELP="$(bash "$LINT" --help 2>&1)"; HEC=$?
if [ "$HEC" -eq 0 ]; then pass "--help exits 0"; else fail "--help expected 0, got $HEC"; fi
assert_contains "--help mentions --staged" "--staged" "$HELP"

# ---------------------------------------------------------------------------
# Case 6: errexit variants — flagged vs not
# ---------------------------------------------------------------------------
printf '\nCase 6: errexit variant detection\n'

for variant in "set -eu" "set -euo pipefail" "set -o errexit"; do
    f="$TMP_ROOT/ee.sh"
    printf '#!/usr/bin/env bash\n%s\necho hi\n' "$variant" > "$f"
    o="$(bash "$LINT" "$f" 2>&1)"; e=$?
    if [ "$e" -eq 1 ] && grepq "$o" -F "[errexit]"; then
        pass "errexit flagged: '$variant'"
    else
        fail "errexit should be flagged: '$variant'" "$o"
    fi
done

for ok in "set -uo pipefail" "set -o pipefail" "set -u"; do
    f="$TMP_ROOT/ok.sh"
    printf '#!/usr/bin/env bash\n%s\necho ok\n' "$ok" > "$f"
    o="$(bash "$LINT" "$f" 2>&1)"; e=$?
    if grepq "$o" -F "[errexit]"; then
        fail "errexit FALSE positive: '$ok'" "$o"
    else
        pass "errexit not flagged (correct): '$ok'"
    fi
done

# ---------------------------------------------------------------------------
# Case 7: `set -e` inside a heredoc body is NOT flagged (prologue-only scan)
# ---------------------------------------------------------------------------
printf '\nCase 7: heredoc-body set -e is not a false positive\n'

HD="$TMP_ROOT/heredoc.sh"
cat > "$HD" <<'OUTER'
#!/usr/bin/env bash
set -uo pipefail
cat > /dev/null <<'INNER'
set -e
INNER
echo finished
OUTER

OUT7="$(bash "$LINT" "$HD" 2>&1)"; EC7=$?
if [ "$EC7" -eq 0 ]; then pass "heredoc-body set -e not flagged (exit 0)"; else fail "expected exit 0, got $EC7" "$OUT7"; fi
assert_not_contains "no errexit false positive on heredoc body" "[errexit]" "$OUT7"

# ---------------------------------------------------------------------------
# Case 8: --staged works from a subdirectory (repo-root path resolution)
# ---------------------------------------------------------------------------
printf '\nCase 8: --staged from a subdirectory\n'

mkdir -p "$REPO/sub/deeper"
OUT8="$(cd "$REPO/sub/deeper" && bash "$LINT" --staged 2>&1)"; EC8=$?
if [ "$EC8" -eq 1 ]; then pass "--staged from subdir still finds the staged issue"; else fail "expected exit 1 from subdir, got $EC8" "$OUT8"; fi
assert_contains "--staged from subdir reports the staged file" "staged.sh" "$OUT8"

# ---------------------------------------------------------------------------
# Case 9: explicit missing file is not a false clean (exit 2, not "clean")
# ---------------------------------------------------------------------------
printf '\nCase 9: all-missing explicit input is not a false clean\n'

OUT9="$(bash "$LINT" "$TMP_ROOT/does-not-exist.sh" 2>&1)"; EC9=$?
if [ "$EC9" -eq 2 ]; then pass "all-missing explicit input exits 2"; else fail "expected exit 2, got $EC9" "$OUT9"; fi
assert_not_contains "missing-file run does not report clean" "clean (" "$OUT9"

# ---------------------------------------------------------------------------
# Case 10: set -Ee (errtrace+errexit bundle) is flagged (case-insensitive prefix)
# ---------------------------------------------------------------------------
printf '\nCase 10: set -Ee flagged\n'

EE2="$TMP_ROOT/ee2.sh"
printf '#!/usr/bin/env bash\nset -Ee\necho hi\n' > "$EE2"
OUT10="$(bash "$LINT" "$EE2" 2>&1)"; EC10=$?
if [ "$EC10" -eq 1 ] && grepq "$OUT10" -F "[errexit]"; then
    pass "set -Ee flagged as errexit"
else
    fail "set -Ee should be flagged" "$OUT10"
fi

# ---------------------------------------------------------------------------
# Cases 11-17: CR-learnings advisory portability checks.
# ---------------------------------------------------------------------------

# Case 11: [regex-class] — \s/\d/\w in a grep -E pattern is flagged; a POSIX
# class ([[:space:]]) is not.
printf '\nCase 11: regex-class detection\n'
RC_BAD="$TMP_ROOT/rc_bad.sh"
cat > "$RC_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
grep -E '\s+' file
EOF
OUT11="$(bash "$LINT" "$RC_BAD" 2>&1)"
if grepq "$OUT11" -F '[regex-class]'; then pass "regex-class flags \\s in grep -E"; else fail "regex-class should flag \\s" "$OUT11"; fi
RC_GOOD="$TMP_ROOT/rc_good.sh"
cat > "$RC_GOOD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
grep -E '[[:space:]]+' file
EOF
OUT11b="$(bash "$LINT" "$RC_GOOD" 2>&1)"
if grepq "$OUT11b" -F '[regex-class]'; then fail "regex-class false positive on POSIX class" "$OUT11b"; else pass "regex-class ignores POSIX [[:space:]]"; fi

# Case 12: [mktemp] — no-template mktemp/-d is flagged; a templated form is not.
printf '\nCase 12: mktemp template detection\n'
MT_BAD="$TMP_ROOT/mt_bad.sh"
cat > "$MT_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d)"
EOF
OUT12="$(bash "$LINT" "$MT_BAD" 2>&1)"
if grepq "$OUT12" -F '[mktemp]'; then pass "mktemp flags no-template mktemp -d"; else fail "mktemp should flag no-template" "$OUT12"; fi
MT_GOOD="$TMP_ROOT/mt_good.sh"
cat > "$MT_GOOD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d -t prefix.XXXXXX)"
EOF
OUT12b="$(bash "$LINT" "$MT_GOOD" 2>&1)"
if grepq "$OUT12b" -F '[mktemp]'; then fail "mktemp false positive on templated form" "$OUT12b"; else pass "mktemp ignores templated form"; fi

# Case 13: [bash32] — declare -A is flagged.
printf '\nCase 13: bash32 detection\n'
B32="$TMP_ROOT/b32.sh"
cat > "$B32" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
declare -A seen
EOF
OUT13="$(bash "$LINT" "$B32" 2>&1)"
if grepq "$OUT13" -F '[bash32]'; then pass "bash32 flags declare -A"; else fail "bash32 should flag declare -A" "$OUT13"; fi

# Case 14: [echo-e] — echo -e is flagged.
printf '\nCase 14: echo-e detection\n'
EFLAG="$TMP_ROOT/eflag.sh"
cat > "$EFLAG" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo -e "hi"
EOF
OUT14="$(bash "$LINT" "$EFLAG" 2>&1)"
if grepq "$OUT14" -F '[echo-e]'; then pass "echo-e flags echo -e"; else fail "echo-e should flag echo -e" "$OUT14"; fi

# Case 15: [gnu-flag] — grep -P flagged; GNU||BSD portable idiom not; gnu-ok
# marker (preceding line) exempts.
printf '\nCase 15: gnu-flag detection + BSD-fallback + gnu-ok exemption\n'
GF_BAD="$TMP_ROOT/gf_bad.sh"
cat > "$GF_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "$x" | grep -oP '"id"'
EOF
OUT15="$(bash "$LINT" "$GF_BAD" 2>&1)"
if grepq "$OUT15" -F '[gnu-flag]'; then pass "gnu-flag flags grep -P"; else fail "gnu-flag should flag grep -P" "$OUT15"; fi
GF_FB="$TMP_ROOT/gf_fb.sh"
cat > "$GF_FB" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
EOF
OUT15b="$(bash "$LINT" "$GF_FB" 2>&1)"
if grepq "$OUT15b" -F '[gnu-flag]'; then fail "gnu-flag false positive on GNU||BSD fallback" "$OUT15b"; else pass "gnu-flag ignores GNU||BSD portable idiom"; fi
GF_OK="$TMP_ROOT/gf_ok.sh"
cat > "$GF_OK" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# gnu-ok: JSON extraction needs PCRE
echo "$x" | grep -oP '"id"'
EOF
OUT15c="$(bash "$LINT" "$GF_OK" 2>&1)"
if grepq "$OUT15c" -F '[gnu-flag]'; then fail "gnu-ok marker did not exempt grep -P" "$OUT15c"; else pass "gnu-ok marker exempts grep -P"; fi

# Case 16: BOM policy is split by file type. A BOM is CORRECT for
# *.ps1 (PS5.1 needs it to decode UTF-8) -> [BOM] is never reported on a .ps1.
# Instead a .ps1 with non-ASCII bytes (>0x7F) but NO BOM is the trap itself
# ([PS1-NO-BOM]); a pure-ASCII .ps1 without a BOM is fine. Fixtures use printf
# octal escapes (\303\251 = e-acute) so THIS test file stays pure-ASCII. A .ps1
# still runs no shell-specific check.
printf '\nCase 16: BOM policy split by file type (HIMMEL-1432)\n'

# 16a: non-ASCII .ps1 WITH a BOM -> clean (the BOM is correct; the very content
#      that is the trap without one is fine with one).
PS1B="$TMP_ROOT/bom.ps1"
printf '\xEF\xBB\xBF' > "$PS1B"
printf 'Write-Output "caf\303\251"\n' >> "$PS1B"
OUT16="$(bash "$LINT" "$PS1B" 2>&1)"; EC16=$?
if [ "$EC16" -eq 0 ]; then pass "16a: non-ASCII .ps1 + BOM exits 0 (BOM is correct)"; else fail "16a: expected exit 0, got $EC16" "$OUT16"; fi
assert_not_contains "16a: no [BOM] on a .ps1" "[BOM]" "$OUT16"
assert_not_contains "16a: no [PS1-NO-BOM] when BOM present" "[PS1-NO-BOM]" "$OUT16"
# grepq, not printf|grep -qE: this suite runs under pipefail and the sweep
# converts single-producer grep -q pipelines.
if grepq "$OUT16" -E '\[(errexit|shellcheck|regex-class|mktemp|bash32|gnu-flag|echo-e)\]'; then
    fail "16a: .ps1 ran a shell-specific check" "$OUT16"
else
    pass "16a: .ps1 runs no shell-specific check"
fi

# 16b: non-ASCII .ps1 WITHOUT a BOM -> [PS1-NO-BOM] (the trap).
PS1N="$TMP_ROOT/nobom.ps1"
printf 'Write-Output "caf\303\251"\n' > "$PS1N"
OUT16b="$(bash "$LINT" "$PS1N" 2>&1)"; EC16b=$?
if [ "$EC16b" -eq 1 ]; then pass "16b: non-ASCII no-BOM .ps1 exits 1"; else fail "16b: expected exit 1, got $EC16b" "$OUT16b"; fi
if [ "$HAVE_ICONV" -eq 1 ]; then
    assert_contains "16b: [PS1-NO-BOM] fires on the trap (valid UTF-8, no BOM)" "[PS1-NO-BOM]" "$OUT16b"
else
    printf '  SKIP: iconv not installed — 16b [PS1-NO-BOM] assertion skipped (fail-safe emits [PS1-ENCODING] unverified)\n'
fi
assert_not_contains "16b: no [BOM] reported (BOM absent, not the issue)" "[BOM]" "$OUT16b"

# 16b-big: the non-ASCII detector in
# shell-lint.sh reads the WHOLE file (`tr -d '\000-\177' | wc -c`, not `grep -q`).
# A `grep -q` detector exits on the first non-ASCII byte, SIGPIPEs `tr` under
# pipefail, and the `if PIPELINE; then flag` wrapper then reads that PIPE failure
# as "no non-ASCII" -> a heavily non-ASCII .ps1 SILENTLY SKIPS [PS1-NO-BOM].
# This guards that regression with a fixture LARGER than any pipe buffer (>=1MB):
# any early-exit detector SIGPIPEs at this size and the trap goes unflagged.
# Fixture is generated at runtime (never commit a 1MB blob); octal escapes keep
# THIS test file pure-ASCII (see Case 16 header).
PS1BIG="$TMP_ROOT/big-nobom.ps1"
_e_chunk="$TMP_ROOT/_e_chunk"
# A 64KiB valid-UTF-8 non-ASCII chunk: 32768 e-acute pairs (C3 A9) = 65536 bytes.
printf '\303\251%.0s' {1..32768} > "$_e_chunk"
# 17 chunks -> 17 * 65536 = 1114112 bytes (~1.06 MiB), all valid UTF-8, no BOM.
: > "$PS1BIG"
for _ in {1..17}; do cat "$_e_chunk" >> "$PS1BIG"; done
rm -f "$_e_chunk"
OUT16big="$(bash "$LINT" "$PS1BIG" 2>&1)"; EC16big=$?
if [ "$EC16big" -eq 1 ]; then pass "16b-big: >1MB non-ASCII no-BOM .ps1 exits 1 (detector read the whole file)"; else fail "16b-big: expected exit 1, got $EC16big" "$OUT16big"; fi
if [ "$HAVE_ICONV" -eq 1 ]; then
    assert_contains "16b-big: [PS1-NO-BOM] fires on a >1MB non-ASCII no-BOM .ps1 (no SIGPIPE short-circuit)" "[PS1-NO-BOM]" "$OUT16big"
else
    printf '  SKIP: iconv not installed — 16b-big [PS1-NO-BOM] assertion skipped\n'
fi
assert_not_contains "16b-big: no [BOM] reported (BOM absent)" "[BOM]" "$OUT16big"

# 16c: pure-ASCII .ps1 WITHOUT a BOM -> clean (BOM is optional when ASCII-only).
PS1A="$TMP_ROOT/ascii.ps1"
printf 'Write-Output "hi"\n' > "$PS1A"
OUT16c="$(bash "$LINT" "$PS1A" 2>&1)"; EC16c=$?
if [ "$EC16c" -eq 0 ]; then pass "16c: pure-ASCII no-BOM .ps1 exits 0"; else fail "16c: expected exit 0, got $EC16c" "$OUT16c"; fi
assert_not_contains "16c: no [PS1-NO-BOM] on ASCII-only .ps1" "[PS1-NO-BOM]" "$OUT16c"

# 16d-16f: recognizing only EF BB BF would send a UTF-16/UTF-32 .ps1 down the
# no-BOM branch to be told to "add a UTF-8 BOM" — corrupting a valid script.
# These lock that in: a UTF-16/32 BOM'd
# .ps1 is CLEAN, and a non-UTF-8 no-BOM .ps1 gets [PS1-ENCODING] (manual),
# never an automated BOM add. Fixtures use printf byte escapes (not iconv) so
# they build everywhere; NUL bytes go straight to the file via redirection.

# 16d: UTF-16LE .ps1 (FF FE BOM + "hi" = 68 00 69 00) -> clean. PowerShell 5.1
#      decodes BOM'd UTF-16 natively.
PS1U16LE="$TMP_ROOT/u16le.ps1"
printf '\xFF\xFE\x68\x00\x69\x00' > "$PS1U16LE"
OUT16d="$(bash "$LINT" "$PS1U16LE" 2>&1)"; EC16d=$?
if [ "$EC16d" -eq 0 ]; then pass "16d: UTF-16LE BOM .ps1 exits 0 (valid encoding)"; else fail "16d: expected exit 0, got $EC16d" "$OUT16d"; fi
assert_not_contains "16d: no [PS1-NO-BOM] on a UTF-16LE .ps1" "[PS1-NO-BOM]" "$OUT16d"
assert_not_contains "16d: no [PS1-ENCODING] on a UTF-16LE .ps1" "[PS1-ENCODING]" "$OUT16d"
assert_not_contains "16d: no [BOM] on a UTF-16LE .ps1" "[BOM]" "$OUT16d"

# 16e: UTF-16BE .ps1 (FE FF BOM + "hi" = 00 68 00 69) -> clean.
PS1U16BE="$TMP_ROOT/u16be.ps1"
printf '\xFE\xFF\x00\x68\x00\x69' > "$PS1U16BE"
OUT16e="$(bash "$LINT" "$PS1U16BE" 2>&1)"; EC16e=$?
if [ "$EC16e" -eq 0 ]; then pass "16e: UTF-16BE BOM .ps1 exits 0 (valid encoding)"; else fail "16e: expected exit 0, got $EC16e" "$OUT16e"; fi
assert_not_contains "16e: no [PS1-NO-BOM] on a UTF-16BE .ps1" "[PS1-NO-BOM]" "$OUT16e"
assert_not_contains "16e: no [PS1-ENCODING] on a UTF-16BE .ps1" "[PS1-ENCODING]" "$OUT16e"

# 16f: non-UTF-8 no-BOM .ps1 -> [PS1-ENCODING], NOT [PS1-NO-BOM]. A raw 0xA0
#      byte is invalid as a UTF-8 leading byte, so iconv rejects it; the linter
#      must NOT prescribe adding a UTF-8 BOM (that would corrupt the file). This
#      is the fail-safe that closes the corruption path. Robust without iconv:
#      both the iconv-absent and invalid-UTF-8 paths emit [PS1-ENCODING].
PS1BAD="$TMP_ROOT/badenc.ps1"
printf 'Write-Output hi\n\xA0\xA0\n' > "$PS1BAD"
OUT16f="$(bash "$LINT" "$PS1BAD" 2>&1)"; EC16f=$?
if [ "$EC16f" -eq 1 ]; then pass "16f: non-UTF-8 no-BOM .ps1 exits 1"; else fail "16f: expected exit 1, got $EC16f" "$OUT16f"; fi
assert_contains "16f: [PS1-ENCODING] on invalid-UTF-8 no-BOM .ps1" "[PS1-ENCODING]" "$OUT16f"
assert_not_contains "16f: no [PS1-NO-BOM] (must not prescribe a BOM add on non-UTF-8)" "[PS1-NO-BOM]" "$OUT16f"

# 16g: blessing UTF-16/32 on EVERY file type would let a UTF-16LE-BOM'd SHELL
# script pass clean. A shell script's first
# two bytes must be `#!`; ANY byte-order mark breaks the shebang, so the very
# same UTF-16LE bytes that are CLEAN on a .ps1 (16d) must be a [BOM] ERROR on a
# .sh. Fixture mirrors 16d (printf byte escapes — no iconv, builds everywhere).
SHU16LE="$TMP_ROOT/u16le.sh"
printf '\xFF\xFE\x68\x00\x69\x00' > "$SHU16LE"
OUT16g="$(bash "$LINT" "$SHU16LE" 2>&1)"; EC16g=$?
if [ "$EC16g" -eq 1 ]; then pass "16g: UTF-16LE BOM .sh exits 1 (breaks shebang)"; else fail "16g: expected exit 1, got $EC16g" "$OUT16g"; fi
assert_contains "16g: [BOM] fires on a UTF-16LE .sh" "[BOM]" "$OUT16g"
assert_contains "16g: [BOM] names the UTF-16LE kind" "UTF-16LE" "$OUT16g"
assert_not_contains "16g: a .sh is never routed through the .ps1 policy" "[PS1-NO-BOM]" "$OUT16g"

# Case 17: --staged admits *.ps1 and the new BOM policy applies there too. A
# staged non-ASCII no-BOM .ps1 is flagged [PS1-NO-BOM] -> proves --staged gathers
# .ps1 AND the trap fires under --staged.
printf '\nCase 17: --staged lints a staged .ps1 (BOM policy split)\n'
REPO2="$TMP_ROOT/repo2"
mkdir -p "$REPO2"
(
    cd "$REPO2" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    printf 'Write-Output "caf\303\251"\n' > staged.ps1
    git add staged.ps1
)
OUT17="$(cd "$REPO2" && bash "$LINT" --staged 2>&1)"
if [ "$HAVE_ICONV" -eq 1 ]; then
    # grepq, not printf|grep -qF.
    if grepq "$OUT17" -F 'staged.ps1' && grepq "$OUT17" -F '[PS1-NO-BOM]'; then
        pass "--staged flags [PS1-NO-BOM] on a staged non-ASCII no-BOM .ps1"
    else
        fail "--staged should flag a staged non-ASCII no-BOM .ps1" "$OUT17"
    fi
else
    printf '  SKIP: iconv not installed — Case 17 [PS1-NO-BOM] assertion skipped\n'
fi

# Case 18: shell-lint reports no findings against its own test file
# — this suite's fixtures/assertions embed the same
# patterns/tags/hints as DATA (e.g. Case 12's `mktemp -d`, Case 16's grep
# alternation naming every advisory tag), so shell-lint exempts
# scripts/lint/test-shell-lint.sh from advisory checks alongside its own
# source. Guard that exemption directly against the real file on disk.
# ---------------------------------------------------------------------------
printf '\nCase 18: shell-lint has no findings on its own test file\n'
SELF="$SCRIPT_DIR/test-shell-lint.sh"
OUT18="$(bash "$LINT" "$SELF" 2>&1)"; EC18=$?
if [ "$EC18" -eq 0 ]; then pass "shell-lint exits 0 on test-shell-lint.sh"; else fail "expected exit 0, got $EC18" "$OUT18"; fi
if grepq "$OUT18" -E '\[(regex-class|mktemp|bash32|gnu-flag|echo-e)\]'; then
    fail "shell-lint should not report advisory findings on its own test file" "$OUT18"
else
    pass "no advisory findings on test-shell-lint.sh"
fi

# ---------------------------------------------------------------------------
# Case 19: [parse] + [quote-break] — an apostrophe in prose inside
# a single-quoted awk program ends the shell string early. The motivating
# incident broke a live hook in the WORKTREE (it then denied every command
# fleet-wide) and never reached a commit, so no commit-time gate ever saw it;
# only the leg's probe harness NEGATIVE controls went red. Both broken fixtures
# below are BUILT with printf from a $Q apostrophe rather than written
# literally, so this suite's own source stays parseable and Case 18's
# self-check stays clean.
# ---------------------------------------------------------------------------
printf '\nCase 19: apostrophe inside a single-quoted awk program\n'

Q="$(printf '\047')"

# 19a POSITIVE CONTROL — the incident shape: the stray apostrophe leaves the
# file unparseable, so [parse] fires and [quote-break] names the line.
BROKEN19="$TMP_ROOT/broken-awk.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'cmd="$1"\n'
    printf 'verdict=$(printf %s%%s\n%s "$cmd" | awk %s\n' "$Q" "$Q" "$Q"
    printf '    # the scanner walks each record; it%ss the entry point\n' "$Q"
    printf '    /danger/ { print "BLOCK"; exit }\n'
    printf '    { print "ALLOW" }\n'
    printf '%s)\n' "$Q"
    printf 'printf %sverdict=%%s\n%s "$verdict"\n' "$Q" "$Q"
} > "$BROKEN19"

OUT19A="$(bash "$LINT" "$BROKEN19" 2>&1)"; EC19A=$?
if [ "$EC19A" -eq 1 ]; then pass "19a broken awk program exits 1"; else fail "19a expected exit 1, got $EC19A" "$OUT19A"; fi
assert_contains "19a [parse] fires"       "[parse]"       "$OUT19A"
assert_contains "19a [quote-break] fires" "[quote-break]" "$OUT19A"

# 19b THE SHAPE `bash -n` CANNOT SEE — two prose apostrophes re-balance the
# file, so it parses cleanly while awk receives a TRUNCATED program. This is
# exactly what [quote-break] buys over [parse] (and over shellcheck on a host
# that does not have it installed).
TRUNC19="$TMP_ROOT/truncated-awk.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %sBEGIN { x = 1 }  # it%ss the parser%ss job\n' "$Q" "$Q" "$Q"
    printf '%s /dev/null\n' "$Q"
} > "$TRUNC19"

if bash -n "$TRUNC19" 2>/dev/null; then
    pass "19b fixture parses (bash -n is blind to this shape)"
else
    fail "19b fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19B="$(bash "$LINT" "$TRUNC19" 2>&1)"
assert_contains     "19b [quote-break] fires on the parseable-but-truncated program" "[quote-break]" "$OUT19B"
assert_not_contains "19b [parse] stays silent (the file parses)"                     "[parse]"       "$OUT19B"

# 19c NEGATIVE CONTROL — the same script with no stray apostrophe. A lint that
# cannot be shown to ACCEPT is as useless as one that cannot be shown to reject.
CLEAN19="$TMP_ROOT/clean-awk.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'cmd="$1"\n'
    printf 'verdict=$(printf %s%%s\n%s "$cmd" | awk %s\n' "$Q" "$Q" "$Q"
    printf '    # the scanner walks each record; this is the entry point\n'
    printf '    /danger/ { print "BLOCK"; exit }\n'
    printf '    { print "ALLOW" }\n'
    printf '%s)\n' "$Q"
    printf 'printf %sverdict=%%s\n%s "$verdict"\n' "$Q" "$Q"
} > "$CLEAN19"

OUT19C="$(bash "$LINT" "$CLEAN19" 2>&1)"; EC19C=$?
if [ "$EC19C" -eq 0 ]; then pass "19c clean awk program exits 0"; else fail "19c expected exit 0, got $EC19C" "$OUT19C"; fi
assert_not_contains "19c no [parse] on a clean file"       "[parse]"       "$OUT19C"
assert_not_contains "19c no [quote-break] on a clean file" "[quote-break]" "$OUT19C"

# 19d the checks must stay silent across the REAL hook corpus — a lint that
# fires on healthy production files is unshippable, and scripts/hooks/ is the
# deny-level surface this ticket names. Assert it directly, not by sampling.
HOOKS19="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/scripts/hooks"
if [ -d "$HOOKS19" ]; then
    FP19=""
    for _hf in "$HOOKS19"/*.sh; do
        [ -f "$_hf" ] || continue
        bash -n "$_hf" 2>/dev/null || FP19="$FP19 $(basename "$_hf")"
    done
    if [ -z "$FP19" ]; then pass "19d every scripts/hooks/*.sh parses"; else fail "19d hook files do not parse:$FP19"; fi
else
    printf '  SKIP: scripts/hooks not found — Case 19d skipped\n'
fi

# 19e — the false-NEGATIVE regression: a
# completely ordinary `awk -v` invocation. The old opener only traversed
# `-flag` tokens between the command and the program, so the `n=1` ASSIGNMENT
# broke the chain and the whole line was skipped — a miss on an entirely
# healthy shape. Two prose apostrophes re-balance the file (bash -n is blind,
# same construction as 19b) so this proves the detector, not bash -n.
FN19E="$TMP_ROOT/awk-v-flag.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk -v n=1 %sBEGIN { x = n }  # it%ss the parser%ss job\n' "$Q" "$Q" "$Q"
    printf '%s /dev/null\n' "$Q"
} > "$FN19E"

if bash -n "$FN19E" 2>/dev/null; then
    pass "19e fixture parses (bash -n is blind to this shape)"
else
    fail "19e fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19E="$(bash "$LINT" "$FN19E" 2>&1)"
assert_contains     "19e [quote-break] fires past an awk -v flag/assignment" "[quote-break]" "$OUT19E"
assert_not_contains "19e [parse] stays silent (the file parses)"            "[parse]"       "$OUT19E"

# 19f — the false-POSITIVE regression: a
# shell comment that merely MENTIONS an awk program with an apostrophe is
# inert prose, not a program opener, and must not fire. The scanner only
# skips a `#`-led line when it is not already mid-program (19a/19b's own
# incident shape puts the stray apostrophe in a comment INSIDE the program,
# where that skip must NOT apply — this case is the other side of that line).
FP19F="$TMP_ROOT/comment-mention.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf '# example: awk %sBEGIN { print 1 } # it%ss only a comment%s\n' "$Q" "$Q" "$Q"
    printf 'echo ok\n'
} > "$FP19F"

OUT19F="$(bash "$LINT" "$FP19F" 2>&1)"; EC19F=$?
if [ "$EC19F" -eq 0 ]; then pass "19f comment-only mention exits 0"; else fail "19f expected exit 0, got $EC19F" "$OUT19F"; fi
assert_not_contains "19f no [quote-break] on a comment merely mentioning awk" "[quote-break]" "$OUT19F"

CHECKER19="$SCRIPT_DIR/hook-parse-check.sh"

# 19g — the LINE-CONTINUATION false-
# NEGATIVE regression: the command ends its physical line with a `\`, and the
# quoted program opens on the NEXT one. The walk used to give up the instant
# it ran off the end of the first physical line without finding the opener.
# Octal escapes (\134=backslash \012=LF) build the REAL continuation bytes —
# a textual `\` + `\n` in a printf format string does not reliably survive
# this shell's own quoting layers (verified empirically: it can silently
# collapse to the literal two characters backslash-n). Two prose apostrophes
# re-balance the file (bash -n is blind, same construction as 19b/19e).
CONT19G="$TMP_ROOT/awk-continuation.sh"
# SC2016: these printf format strings carry LITERAL $1/$cmd on purpose —
# they are the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk \134\012'
    printf '  %sBEGIN { x = 1 }  # it%ss the parser%ss job\n' "$Q" "$Q" "$Q"
    printf '%s /dev/null\n' "$Q"
} > "$CONT19G"

if bash -n "$CONT19G" 2>/dev/null; then
    pass "19g fixture parses (bash -n is blind to this shape)"
else
    fail "19g fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19G="$(bash "$LINT" "$CONT19G" 2>&1)"
assert_contains     "19g [quote-break] fires across a line continuation" "[quote-break]" "$OUT19G"
assert_not_contains "19g [parse] stays silent (the file parses)"        "[parse]"       "$OUT19G"

# 19h — a non-shell file handed DIRECTLY
# to hook-parse-check.sh (not through shell-lint.sh's own _is_shell_file gate)
# must be skipped outright: no output, exit 0. Both current callers already
# gate by file type, but the checker is a standalone tool with two consumers
# already — a THIRD caller must not get a bogus `bash -n` [parse] finding
# back for handing it a script in another language.
PS19H="$TMP_ROOT/example.ps1"
# SC2016: this printf format string carries LITERAL PowerShell $x on purpose —
# it is fixture source being written to disk, not an expansion here.
# shellcheck disable=SC2016
{
    printf 'param($x)\n'
    printf 'if ($x -eq 1) {\n'
    printf '    Write-Host "hi"\n'
    printf '}\n'
} > "$PS19H"

OUT19H="$(bash "$CHECKER19" "$PS19H" 2>&1)"; EC19H=$?
if [ "$EC19H" -eq 0 ]; then pass "19h .ps1 direct call exits 0"; else fail "19h expected exit 0, got $EC19H" "$OUT19H"; fi
if [ -z "$OUT19H" ]; then pass "19h .ps1 direct call prints nothing"; else fail "19h expected no output" "$OUT19H"; fi

# 19i — FALSE POSITIVE regression:
# `sed 's/x/y/'file` is ordinary, correct shell — the single-quoted program
# is complete and `file` is concatenated onto the same shell word as the
# operand. The old next-char test alone (closing quote immediately followed
# by a word character) cannot tell this apart from a genuine truncation and
# fired anyway. It must PARSE (it is valid shell, not a broken hook) and
# [quote-break] must stay silent.
FALSEPOS19I="$TMP_ROOT/concat-sed.sh"
# SC2016: this printf format string carries a LITERAL sed program on purpose —
# it is fixture source being written to disk, not an expansion here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/x/y/%sfile\n' "$Q" "$Q"
} > "$FALSEPOS19I"

if bash -n "$FALSEPOS19I" 2>/dev/null; then
    pass "19i fixture parses (ordinary shell concatenation, not a broken hook)"
else
    fail "19i fixture must PARSE — it is valid shell"
fi
OUT19I="$(bash "$CHECKER19" "$FALSEPOS19I" 2>&1)"; EC19I=$?
if [ "$EC19I" -eq 0 ]; then pass "19i exits 0 on ordinary sed-then-concatenated-word"; else fail "19i expected exit 0, got $EC19I" "$OUT19I"; fi
assert_not_contains "19i no [quote-break] on ordinary sed-then-concatenated-word (#2018)" "[quote-break]" "$OUT19I"

# 19j — NEGATIVE CONTROL for the false-
# NEGATIVE regression below: the SAME truncated awk program, but FIRST on its
# physical line (same shape as 19b/19e/19g). This must already fire —
# without this control, 19k passing would not prove anything: a test that
# stopped exercising the scanner at all would still pass.
TRUNCFIRST19J="$TMP_ROOT/truncated-first.sh"
# SC2016: this printf format string carries a LITERAL awk program on purpose —
# it is fixture source being written to disk, not an expansion here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %sBEGIN{ x = 1 } # user%ss own%ss note%s bar\n' "$Q" "$Q" "$Q" "$Q"
} > "$TRUNCFIRST19J"

if bash -n "$TRUNCFIRST19J" 2>/dev/null; then
    pass "19j fixture parses (bash -n is blind to this shape)"
else
    fail "19j fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19J="$(bash "$CHECKER19" "$TRUNCFIRST19J" 2>&1)"
assert_contains "19j [quote-break] fires when the truncated program is FIRST on the line (negative control)" "[quote-break]" "$OUT19J"

# 19k — the FALSE NEGATIVE itself: the
# identical truncated awk program from 19j, now preceded on the SAME physical
# line by a complete, unrelated `sed '...' foo;` invocation. The old rule
# found the closing quote of the awk program's opener, set inprog = 0, and
# fell off the end of the rule — the remainder of the line was never
# re-scanned, so this truncated program (the exact shape [quote-break] exists
# to catch) went unflagged.
MISSED19K="$TMP_ROOT/sed-then-truncated-awk.sh"
# SC2016: this printf format string carries a LITERAL sed+awk program on
# purpose — it is fixture source being written to disk, not an expansion here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/a/b/%s foo; awk %sBEGIN{ x = 1 } # user%ss own%ss note%s bar\n' \
        "$Q" "$Q" "$Q" "$Q" "$Q" "$Q"
} > "$MISSED19K"

if bash -n "$MISSED19K" 2>/dev/null; then
    pass "19k fixture parses (bash -n is blind to this shape)"
else
    fail "19k fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19K="$(bash "$CHECKER19" "$MISSED19K" 2>&1)"
assert_contains "19k [quote-break] fires past a complete sed invocation earlier on the same line (#2017)" "[quote-break]" "$OUT19K"

# 19l — a single-line
# truncation whose trailing prose is more than one word, but carries NO
# further apostrophe anywhere else on that physical line. A discriminator
# keyed only on "does another apostrophe reopen later on the line" (an
# earlier draft of the #2018 fix) misses this: nothing reopens, so it read
# as ordinary concatenation. The file globally re-balances via a SEPARATE,
# unrelated quoted string on the NEXT line (an ordinary `echo 'ok'`) — the
# same "bash -n is blind" shape as 19b, just spread across two lines instead
# of re-balancing within one.
TRUNCWORDS19L="$TMP_ROOT/truncated-multiword.sh"
# SC2016: this printf format string carries a LITERAL awk program on purpose —
# it is fixture source being written to disk, not an expansion here.
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %sBEGIN{ x = 1 } # user%ss note\n' "$Q" "$Q"
    printf 'echo %sok%s\n' "$Q" "$Q"
} > "$TRUNCWORDS19L"

if bash -n "$TRUNCWORDS19L" 2>/dev/null; then
    pass "19l fixture parses (bash -n is blind to this shape)"
else
    fail "19l fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19L="$(bash "$CHECKER19" "$TRUNCWORDS19L" 2>&1)"
assert_contains "19l [quote-break] fires on a multi-word single-line truncation with no further apostrophe on that line" "[quote-break]" "$OUT19L"

# 19m — the MULTI-LINE
# mirror of #2018: a program opened on an earlier line and closed on ITS OWN
# line as `'file` (the closing quote immediately followed by a concatenated
# bareword, nothing else on that line) is ordinary shell concatenation
# spanning multiple lines, not a truncation — it must not fire.
CONCATMULTILINE19M="$TMP_ROOT/concat-multiline.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %s\n' "$Q"
    printf '    BEGIN { x = 1 }\n'
    printf '%sfile\n' "$Q"
} > "$CONCATMULTILINE19M"

if bash -n "$CONCATMULTILINE19M" 2>/dev/null; then
    pass "19m fixture parses (ordinary multi-line shell concatenation, not a broken hook)"
else
    fail "19m fixture must PARSE — it is valid shell"
fi
OUT19M="$(bash "$CHECKER19" "$CONCATMULTILINE19M" 2>&1)"; EC19M=$?
if [ "$EC19M" -eq 0 ]; then pass "19m exits 0 on a multi-line program closed as 'file"; else fail "19m expected exit 0, got $EC19M" "$OUT19M"; fi
assert_not_contains "19m no [quote-break] on multi-line concatenation" "[quote-break]" "$OUT19M"

# 19n — the word-count
# discriminator (19i) fixed a BARE concatenated operand (`sed '...'file`
# alone on the line) but a later variant regressed the moment ordinary shell
# syntax followed the operand: redirection or a semicolon-chained command
# both count as "more than one word remains" under a pure word-count test,
# so `sed '...'file > out` / `sed '...'file; echo done` were flagged even
# though both are entirely valid, complete shell. Peeling off just the
# concatenated operand and checking whether a shell metacharacter follows
# (rather than counting words over the whole remainder) fixes this without
# reopening #2018 (19i stays green).
FALSEPOS19N_REDIR="$TMP_ROOT/concat-sed-redir.sh"
# SC2016: literal sed program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/x/y/%sfile > out\n' "$Q" "$Q"
} > "$FALSEPOS19N_REDIR"
if bash -n "$FALSEPOS19N_REDIR" 2>/dev/null; then
    pass "19n(redir) fixture parses (ordinary shell concatenation + redirection)"
else
    fail "19n(redir) fixture must PARSE — it is valid shell"
fi
OUT19N_REDIR="$(bash "$CHECKER19" "$FALSEPOS19N_REDIR" 2>&1)"; EC19N_REDIR=$?
if [ "$EC19N_REDIR" -eq 0 ]; then pass "19n(redir) exits 0 on concatenated-operand + redirection"; else fail "19n(redir) expected exit 0, got $EC19N_REDIR" "$OUT19N_REDIR"; fi
assert_not_contains "19n(redir) no [quote-break] past a concatenated operand + redirection (codex-1)" "[quote-break]" "$OUT19N_REDIR"

FALSEPOS19N_SEMI="$TMP_ROOT/concat-sed-semi.sh"
# SC2016: literal sed program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/x/y/%sfile; echo done\n' "$Q" "$Q"
} > "$FALSEPOS19N_SEMI"
if bash -n "$FALSEPOS19N_SEMI" 2>/dev/null; then
    pass "19n(semi) fixture parses (ordinary shell concatenation + command chaining)"
else
    fail "19n(semi) fixture must PARSE — it is valid shell"
fi
OUT19N_SEMI="$(bash "$CHECKER19" "$FALSEPOS19N_SEMI" 2>&1)"; EC19N_SEMI=$?
if [ "$EC19N_SEMI" -eq 0 ]; then pass "19n(semi) exits 0 on concatenated-operand + semicolon chaining"; else fail "19n(semi) expected exit 0, got $EC19N_SEMI" "$OUT19N_SEMI"; fi
assert_not_contains "19n(semi) no [quote-break] past a concatenated operand + semicolon chaining (codex-1)" "[quote-break]" "$OUT19N_SEMI"

# 19o — the multi-word
# test (19l) catches a truncation whose trailing prose is SEVERAL words, but
# a truncation whose trailing fragment is exactly ONE word (e.g. a
# contraction split by the closing quote into two pieces, like the second
# half of a word ending in "-n't") is indistinguishable from a bare
# concatenated operand (19i/19m) by word count alone, and went unflagged.
# The fix: once a `#` comment marker has opened INSIDE the program on this
# physical line before the close, flag on ANY word character after the
# close, regardless of word count — the motivating incident (see this
# script's own header) is exactly a stray apostrophe inside an in-body
# comment. Re-balances via an unrelated quote on the NEXT line (bash -n
# blind, same shape as 19b/19l).
TRUNCONEWORD19O="$TMP_ROOT/truncated-oneword.sh"
# SC2016: literal awk program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %sBEGIN{ x = 1 } # this program can%st\n' "$Q" "$Q"
    printf 'echo %sok%s\n' "$Q" "$Q"
} > "$TRUNCONEWORD19O"
if bash -n "$TRUNCONEWORD19O" 2>/dev/null; then
    pass "19o fixture parses (bash -n is blind to this shape)"
else
    fail "19o fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19O="$(bash "$CHECKER19" "$TRUNCONEWORD19O" 2>&1)"
assert_contains "19o [quote-break] fires on a single-trailing-word truncation past an in-body comment marker (codex-2)" "[quote-break]" "$OUT19O"

# 19p — the peel-one-
# operand-then-check-for-a-shell-metacharacter discriminator (19n) fixed
# redirection/chaining after a concatenated operand, but a SECOND,
# space-separated bareword operand (an entirely ordinary multi-file
# invocation) still isn't a shell metacharacter, so it was still flagged.
# There is no upper bound on how many further bareword arguments can
# legally follow a shell command, so no word-count-based test can be made
# reliable here -- this is the finding that forced the switch to the
# contraction-suffix discriminator, which does not look at word count at
# all.
FALSEPOS19P="$TMP_ROOT/concat-sed-twofiles.sh"
# SC2016: literal sed program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/x/y/%sfile1 file2\n' "$Q" "$Q"
} > "$FALSEPOS19P"
if bash -n "$FALSEPOS19P" 2>/dev/null; then
    pass "19p fixture parses (ordinary shell concatenation + a second bareword operand)"
else
    fail "19p fixture must PARSE — it is valid shell"
fi
OUT19P="$(bash "$CHECKER19" "$FALSEPOS19P" 2>&1)"; EC19P=$?
if [ "$EC19P" -eq 0 ]; then pass "19p exits 0 on concatenated-operand + a second space-separated operand"; else fail "19p expected exit 0, got $EC19P" "$OUT19P"; fi
assert_not_contains "19p no [quote-break] past a concatenated operand + a second operand (codex-1 round 3)" "[quote-break]" "$OUT19P"

# 19q — the comment-
# marker discriminator (19o) required a space or start-of-program before the
# `#`, so a comment with NO gap before it (program syntax ending directly
# against the `#`, e.g. a closing brace) was not recognized as a comment at
# all, and a single-trailing-word truncation past it went unflagged again.
# The contraction-suffix discriminator does not look for a `#` at all, so it
# is unaffected by whether or how a comment was introduced.
TRUNCNOGAP19Q="$TMP_ROOT/truncated-nogap-comment.sh"
# SC2016: literal awk program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'awk %sBEGIN{}# this program can%st\n' "$Q" "$Q"
    printf 'echo %sok%s\n' "$Q" "$Q"
} > "$TRUNCNOGAP19Q"
if bash -n "$TRUNCNOGAP19Q" 2>/dev/null; then
    pass "19q fixture parses (bash -n is blind to this shape)"
else
    fail "19q fixture must PARSE, else it does not prove [quote-break] adds anything over [parse]"
fi
OUT19Q="$(bash "$CHECKER19" "$TRUNCNOGAP19Q" 2>&1)"
assert_contains "19q [quote-break] fires on a truncation past a comment marker with no preceding whitespace (codex-2 round 3)" "[quote-break]" "$OUT19Q"

# 19r — the comment-
# marker discriminator (19o) treated ANY `#` preceded by whitespace as a
# comment opener, but a `#` can also be ordinary PROGRAM syntax (a sed
# pattern character, here literally " #" inside a regex) with no comment
# involved at all -- text alone cannot tell a real awk/sed/perl comment from
# `#` used as program content without actually parsing that language. The
# contraction-suffix discriminator sidesteps the question entirely: it never
# looks for a `#` anywhere, so this ordinary concatenation is not flagged.
FALSEPOS19R="$TMP_ROOT/concat-sed-hash-in-pattern.sh"
# SC2016: literal sed program on purpose (fixture source to disk).
# shellcheck disable=SC2016
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'sed %ss/ #/x/%sfile\n' "$Q" "$Q"
} > "$FALSEPOS19R"
if bash -n "$FALSEPOS19R" 2>/dev/null; then
    pass "19r fixture parses (ordinary shell concatenation, # is program syntax not a comment)"
else
    fail "19r fixture must PARSE — it is valid shell"
fi
OUT19R="$(bash "$CHECKER19" "$FALSEPOS19R" 2>&1)"; EC19R=$?
if [ "$EC19R" -eq 0 ]; then pass "19r exits 0 on a concatenated operand past a program-syntax # (not a comment)"; else fail "19r expected exit 0, got $EC19R" "$OUT19R"; fi
assert_not_contains "19r no [quote-break] past a program-syntax # mistaken for a comment (codex-3 round 3)" "[quote-break]" "$OUT19R"

# ---------------------------------------------------------------------------
# Case 20: [octal-arith] — a variable assigned from a leading-zero date field
# (date +%m/%d/%H/%M/%S/%j/%U/%V/%W, or cut of one) that later sits inside
# $(( )) / (( )) / let without 10# is octal in that context (08 and 09 error).
# Fixtures are written with quoted heredocs; Case 18 exempts this file.
# ---------------------------------------------------------------------------
printf '\nCase 20: octal-arith detection\n'
OA_BAD="$TMP_ROOT/oa_bad.sh"
cat > "$OA_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m)
echo $((m+1))
EOF
OUT20="$(bash "$LINT" "$OA_BAD" 2>&1)"; EC20=$?
if [ "$EC20" -eq 1 ]; then pass "20a exit 1 on unnormalized date field in \$(( ))"; else fail "20a expected exit 1, got $EC20" "$OUT20"; fi
assert_contains "20a [octal-arith] fires" "[octal-arith]" "$OUT20"
assert_contains "20a cites the arithmetic line" "line 4" "$OUT20"

OA_OK="$TMP_ROOT/oa_ok.sh"
cat > "$OA_OK" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m)
echo $((10#$m+1))
EOF
OUT20B="$(bash "$LINT" "$OA_OK" 2>&1)"
assert_not_contains "20b 10# normalized operand is clean" "[octal-arith]" "$OUT20B"

OA_YEAR="$TMP_ROOT/oa_year.sh"
cat > "$OA_YEAR" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
y=$(date +%Y)
echo $((y+1))
EOF
OUT20C="$(bash "$LINT" "$OA_YEAR" 2>&1)"
assert_not_contains "20c date +%Y (no leading zero) is clean" "[octal-arith]" "$OUT20C"

OA_BRACKET="$TMP_ROOT/oa_bracket.sh"
cat > "$OA_BRACKET" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m)
[ "$m" -gt 5 ] && echo late
EOF
OUT20D="$(bash "$LINT" "$OA_BRACKET" 2>&1)"
assert_not_contains "20d single-bracket test is decimal, clean" "[octal-arith]" "$OUT20D"

OA_ESC="$TMP_ROOT/oa_esc.sh"
cat > "$OA_ESC" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m)
echo $((m+1)) # octal-ok: m is checked to be 1-7 above
EOF
OUT20E="$(bash "$LINT" "$OA_ESC" 2>&1)"
assert_not_contains "20e same-line # octal-ok suppresses" "[octal-arith]" "$OUT20E"

OA_FORMS="$TMP_ROOT/oa_forms.sh"
cat > "$OA_FORMS" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d=$(date +%d)
h=$(date +%H | cut -c1-2)
(( d > 3 )) && echo a
let h2=h+1
EOF
OUT20F="$(bash "$LINT" "$OA_FORMS" 2>&1)"
assert_contains "20f (( )) form flagged" "[octal-arith] line 5" "$OUT20F"
assert_contains "20f let form flagged" "[octal-arith] line 6" "$OUT20F"

OA_EPOCH="$TMP_ROOT/oa_epoch.sh"
cat > "$OA_EPOCH" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
t=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$at" +%s)
echo $((t+1))
EOF
OUT20G="$(bash "$LINT" "$OA_EPOCH" 2>&1)"
assert_not_contains "20g epoch output (+%s) with a %m input format is clean" "[octal-arith]" "$OUT20G"

OA_SELF="$TMP_ROOT/oa_self.sh"
cat > "$OA_SELF" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m)
m=$((m+1))
EOF
OUT20I="$(bash "$LINT" "$OA_SELF" 2>&1)"
assert_contains "20i reassignment from its own unnormalized value is flagged" "[octal-arith] line 4" "$OUT20I"

OA_NORM="$TMP_ROOT/oa_norm.sh"
cat > "$OA_NORM" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$((10#$(date +%m)))
echo $((m+1))
EOF
OUT20J="$(bash "$LINT" "$OA_NORM" 2>&1)"
assert_not_contains "20j initializer already normalized with 10# is clean" "[octal-arith]" "$OUT20J"

OA_CUTFP="$TMP_ROOT/oa_cutfp.sh"
cat > "$OA_CUTFP" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
n=$(date +%d)
want=$(du -sk "x.$n" | cut -f1)
echo $((want+1))
EOF
OUT20K="$(bash "$LINT" "$OA_CUTFP" 2>&1)"
assert_not_contains "20k a cut that only mentions the tracked var in a path is clean" "[octal-arith]" "$OUT20K"

OA_CUTTP="$TMP_ROOT/oa_cuttp.sh"
cat > "$OA_CUTTP" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d=$(date +%d)
x=$(echo "$d" | cut -c1-2)
echo $((x+1))
EOF
OUT20L="$(bash "$LINT" "$OA_CUTTP" 2>&1)"
assert_contains "20l cut of a tracked value stays tracked" "[octal-arith] line 5" "$OUT20L"

OA_PATHFP="$TMP_ROOT/oa_pathfp.sh"
cat > "$OA_PATHFP" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
pre="a/$(date +%Y-%m)/f"
want="$(sha256sum "$pre" | cut -d' ' -f1)"
echo $((want+1))
EOF
OUT20M="$(bash "$LINT" "$OA_PATHFP" 2>&1)"
assert_not_contains "20m a multi-field date format in a path is not a tracked field" "[octal-arith]" "$OUT20M"

OA_CMT="$TMP_ROOT/oa_cmt.sh"
cat > "$OA_CMT" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m) # normalize with 10# later
echo $((m+1))
EOF
OUT20N="$(bash "$LINT" "$OA_CMT" 2>&1)"
assert_contains "20n a 10# inside a trailing comment does not normalize" "[octal-arith] line 4" "$OUT20N"

OA_SAMELINE="$TMP_ROOT/oa_sameline.sh"
cat > "$OA_SAMELINE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
m=$(date +%m); echo $((m+1))
EOF
OUT20O="$(bash "$LINT" "$OA_SAMELINE" 2>&1)"
assert_contains "20o assignment then arithmetic on one line is flagged" "[octal-arith] line 3" "$OUT20O"

OUT20H="$(bash "$LINT" --help 2>&1)"
assert_contains "20g --help documents [octal-arith]" "[octal-arith]" "$OUT20H"

# ---------------------------------------------------------------------------
# Case 21: the gate wiring — pre-commit entry, baseline, --changed, CI step
# ---------------------------------------------------------------------------
printf '\nCase 21: pre-commit hook + baseline + CI changed-files step\n'

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_ENTRY="$(awk '/^ *- id: shell-lint$/{f=1;next} f&&/^ *- id:/{exit} f&&/^ *entry:/{sub(/^ *entry: */,"");print;exit}' "$REPO_ROOT/.pre-commit-config.yaml")"
if [ -n "$HOOK_ENTRY" ]; then pass "21a shell-lint hook is registered in .pre-commit-config.yaml"; else fail "21a no shell-lint hook in .pre-commit-config.yaml"; fi

GATE="$TMP_ROOT/gate"
mkdir -p "$GATE/scripts/lint"
cp "$LINT" "$SCRIPT_DIR/hook-parse-check.sh" "$GATE/scripts/lint/"
printf '' > "$GATE/scripts/lint/shell-lint-baseline.txt"
(
    cd "$GATE" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    git add scripts
    git commit -q -m seed
    cat > bad.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
tmp=$(mktemp)
printf '%s\n' "$tmp"
EOF
    cat > good.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
tmp=$(mktemp "${TMPDIR:-/tmp}/x.XXXXXX")
printf '%s\n' "$tmp"
EOF
) >/dev/null 2>&1

OUT21B="$(cd "$GATE" && git add bad.sh && bash -c "${HOOK_ENTRY:-false}" 2>&1)"; EC21B=$?
if [ "$EC21B" -eq 1 ]; then pass "21b hook entry refuses a staged mktemp with no template"; else fail "21b expected exit 1, got $EC21B" "$OUT21B"; fi
assert_contains "21b reports [mktemp]" "[mktemp]" "$OUT21B"

OUT21C="$(cd "$GATE" && git reset -q bad.sh && git add good.sh && bash -c "${HOOK_ENTRY:-false}" 2>&1)"; EC21C=$?
if [ "$EC21C" -eq 0 ]; then pass "21c hook entry passes a clean staged file"; else fail "21c expected exit 0, got $EC21C" "$OUT21C"; fi

# baseline: a count within its row passes; one more finding in the file fails
printf 'bad.sh\tmktemp\t1\n' > "$GATE/scripts/lint/shell-lint-baseline.txt"
OUT21D="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline scripts/lint/shell-lint-baseline.txt bad.sh 2>&1)"; EC21D=$?
if [ "$EC21D" -eq 0 ]; then pass "21d finding within its baseline count is accepted"; else fail "21d expected exit 0, got $EC21D" "$OUT21D"; fi
cat >> "$GATE/bad.sh" <<'EOF'
x=$(mktemp)
EOF
OUT21E="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline scripts/lint/shell-lint-baseline.txt bad.sh 2>&1)"; EC21E=$?
if [ "$EC21E" -eq 1 ]; then pass "21e a finding above its baseline count fails"; else fail "21e expected exit 1, got $EC21E" "$OUT21E"; fi
_write_bom_file "$GATE/bom.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
EOF
printf 'bom.sh\tBOM\t1\n' > "$GATE/scripts/lint/shell-lint-baseline.txt"
OUT21F="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline scripts/lint/shell-lint-baseline.txt bom.sh 2>&1)"; EC21F=$?
if [ "$EC21F" -eq 1 ]; then pass "21f a [BOM] row in the baseline is never honoured"; else fail "21f expected exit 1, got $EC21F" "$OUT21F"; fi

# --changed BASE..HEAD lints only files changed in the range
(cd "$GATE" && git add bad.sh good.sh && git commit -q -m add) >/dev/null 2>&1
printf '' > "$GATE/scripts/lint/shell-lint-baseline.txt"
OUT21G="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --changed HEAD~1..HEAD --baseline scripts/lint/shell-lint-baseline.txt 2>&1)"; EC21G=$?
if [ "$EC21G" -eq 1 ]; then pass "21g --changed fails on a violating file in the range"; else fail "21g expected exit 1, got $EC21G" "$OUT21G"; fi
assert_contains "21g names the violating file" "bad.sh" "$OUT21G"
assert_not_contains "21g does not lint a file outside the range" "shell-lint.sh:" "$OUT21G"
OUT21H="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --changed no-such-ref..HEAD 2>&1)"; EC21H=$?
if [ "$EC21H" -eq 2 ]; then pass "21h --changed with an unresolvable range exits 2 (fail closed)"; else fail "21h expected exit 2, got $EC21H" "$OUT21H"; fi

# --write-baseline round trip
OUT21I="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline scripts/lint/shell-lint-baseline.txt --write-baseline bad.sh 2>&1)"; EC21I=$?
if [ "$EC21I" -eq 0 ] && grepq "$(cat "$GATE/scripts/lint/shell-lint-baseline.txt")" -F "bad.sh	mktemp	2"; then
    pass "21i --write-baseline records the per-file tag count"
else
    fail "21i baseline not written as expected (rc $EC21I)" "$OUT21I"
fi

# the committed baseline accepts the real linter and CI runs the changed-files step
OUT21J="$(cd "$REPO_ROOT" && bash scripts/lint/shell-lint.sh --baseline scripts/lint/shell-lint-baseline.txt scripts/lint/shell-lint.sh scripts/lint/test-shell-lint.sh 2>&1)"; EC21J=$?
if [ "$EC21J" -eq 0 ]; then pass "21j committed baseline: the lint's own files are clean"; else fail "21j expected exit 0, got $EC21J" "$OUT21J"; fi
if grepq "$(cat "$REPO_ROOT/.github/workflows/ci.yml")" -F "shell-lint.sh --changed"; then
    pass "21k ci.yml runs shell-lint over the PR's changed files"
else
    fail "21k ci.yml has no shell-lint --changed step"
fi

# a renamed file is linted at its new path (--changed and --staged)
(
    cd "$GATE" || exit 1
    git add bad.sh good.sh && git commit -q -m seed2
    git mv bad.sh moved.sh
    cat >> moved.sh <<'EOF'
y=$(mktemp)
EOF
    git add moved.sh && git commit -q -m rename
) >/dev/null 2>&1
printf '' > "$GATE/scripts/lint/shell-lint-baseline.txt"
OUT21L="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --changed HEAD~1..HEAD --baseline scripts/lint/shell-lint-baseline.txt 2>&1)"; EC21L=$?
if [ "$EC21L" -eq 1 ]; then pass "21l --changed lints a renamed file"; else fail "21l expected exit 1, got $EC21L" "$OUT21L"; fi
assert_contains "21l names the new path" "moved.sh" "$OUT21L"
(cd "$GATE" && git reset -q --hard HEAD~1 && git mv bad.sh moved.sh && cat >> moved.sh <<'EOF'
y=$(mktemp)
EOF
git add moved.sh) >/dev/null 2>&1
OUT21M="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --staged --baseline scripts/lint/shell-lint-baseline.txt 2>&1)"; EC21M=$?
if [ "$EC21M" -eq 1 ]; then pass "21m --staged lints a renamed file"; else fail "21m expected exit 1, got $EC21M" "$OUT21M"; fi

# --write-baseline never launders a finding no baseline can accept, and fails loudly when it cannot write
OUT21N="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline "$TMP_ROOT/wb.txt" --write-baseline bom.sh 2>&1)"; EC21N=$?
if [ "$EC21N" -eq 1 ]; then pass "21n --write-baseline still reports a [BOM] finding"; else fail "21n expected exit 1, got $EC21N" "$OUT21N"; fi
assert_contains "21n reports [BOM]" "[BOM]" "$OUT21N"
OUT21O="$(cd "$GATE" && bash scripts/lint/shell-lint.sh --baseline "$TMP_ROOT/no-such-dir/wb.txt" --write-baseline good.sh 2>&1)"; EC21O=$?
if [ "$EC21O" -eq 2 ]; then pass "21o --write-baseline to an unwritable path exits 2"; else fail "21o expected exit 2, got $EC21O" "$OUT21O"; fi

# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
