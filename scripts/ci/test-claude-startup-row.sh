#!/usr/bin/env bash
# scripts/ci/test-claude-startup-row.sh -- scripts/ci/claude-startup-row.sh, the
# recorder ci-quick wraps each mock-Claude suite in and the verifier the
# claude-startup sentinel runs. Every row builds a temp repo T, copies the real
# script to T/scripts/ci/ and runs that copy with cwd T, so a mutant copy of the
# script (and of this test beside it) is what runs.
#
#   R1-R10  record: one row per run, rc passed through, nothing run and nothing
#           written on a refusal, the suite never sees the manifest path
#   X1-X5   --expected: the SKIP_LIST scripts/testing entries, comments dropped,
#           failing closed
#   V1-V9   --verify: exactly one well-formed row per expected path and nothing
#           else, no <out> left behind on a refusal
#
# Usage: bash scripts/ci/test-claude-startup-row.sh
# Exit codes: 0 -- all rows passed; 1 -- at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/claude-startup-row.sh"
REAL_RST="$HERE/run-shell-tests.sh"

pass_n=0
fail_n=0
ROOT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/csr-test.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT_TMP"' EXIT
seq_n=0

assert() { # assert <id> <description> <command...>
  local id="$1" desc="$2"
  shift 2
  if "$@"; then
    echo "ok - $id $desc"
    pass_n=$((pass_n + 1))
  else
    echo "FAIL - $id $desc"
    fail_n=$((fail_n + 1))
  fi
}

new_t() { # a fresh temp repo T holding the script copy and the fixture suites
  seq_n=$((seq_n + 1))
  T="$ROOT_TMP/t$seq_n"
  mkdir -p "$T/scripts/ci" "$T/scripts/testing" || exit 1
  cp "$SCRIPT" "$T/scripts/ci/claude-startup-row.sh" 2>/dev/null
  printf '#!/usr/bin/env bash\ntouch ran-ok.marker\nexit 0\n' >"$T/scripts/testing/test-ok.sh"
  printf '#!/usr/bin/env bash\ntouch ran-red.marker\nexit 3\n' >"$T/scripts/testing/test-red.sh"
  printf '#!/usr/bin/env bash\ntouch ran-skip.marker\necho "SKIP: no claude"\nexit 77\n' >"$T/scripts/testing/test-skip.sh"
  # The fixture bodies are written verbatim: their variables expand when the suite runs.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ntouch ran-env.marker\nprintf "[%%s]\\n" "${CLAUDE_STARTUP_MANIFEST-unset}"\nexit 0\n' >"$T/scripts/testing/test-env.sh"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ntouch ran-swap.marker\nrm -f "$CSR_FIXTURE_M" && mkdir "$CSR_FIXTURE_M"\nexit 0\n' >"$T/scripts/testing/test-swap.sh"
}

# csr <args>: run the copy in T. The manifest comes from $M when M is set (it
# may be empty), and is unset in the child otherwise. Sets OUT and RC.
csr() {
  if [ "${M+set}" = set ]; then
    OUT="$(cd "$T" && CLAUDE_STARTUP_MANIFEST="$M" bash scripts/ci/claude-startup-row.sh "$@" 2>&1)"
    RC=$?
  else
    OUT="$(cd "$T" && env -u CLAUDE_STARTUP_MANIFEST bash scripts/ci/claude-startup-row.sh "$@" 2>&1)"
    RC=$?
  fi
}

rst_with() { # rst_with <entry-line>...: a fixture run-shell-tests.sh beside the copy
  {
    echo 'before=1'
    echo 'SKIP_LIST="'
    for l in "$@"; do printf '%s\n' "$l"; done
    echo '"'
    echo 'after=2'
  } >"$T/scripts/ci/run-shell-tests.sh"
}

rc_is() { [ "$RC" -eq "$1" ]; }
absent() { [ ! -e "$1" ]; }
no_markers() { ! ls "$T"/ran-*.marker >/dev/null 2>&1; }
content_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
no_ran0() { ! grep -rq '^ran 0 ' "$T" 2>/dev/null; }

A="scripts/testing/test-a.sh"
B="scripts/testing/test-b.sh"

# ---------------------------------------------------------------- record rows
new_t
unset M
M=new-dir/rows.txt
csr scripts/testing/test-ok.sh
assert R1 "ok suite: exit 0" rc_is 0
assert R1 "ok suite: exactly one ran 0 row in a manifest dir created on demand" content_is "$T/new-dir/rows.txt" "ran 0 scripts/testing/test-ok.sh"

new_t
M=rows.txt
csr scripts/testing/test-red.sh
assert R2 "red suite: its exit 3 passes through" rc_is 3
assert R2 "red suite: recorded as ran 3" content_is "$T/rows.txt" "ran 3 scripts/testing/test-red.sh"
assert R2 "red suite: no ran 0 anywhere" no_ran0

new_t
M=rows.txt
csr scripts/testing/test-skip.sh
assert R3 "skip suite: its exit 77 passes through" rc_is 77
assert R3 "skip suite: recorded as ran 77" content_is "$T/rows.txt" "ran 77 scripts/testing/test-skip.sh"
assert R3 "skip suite: no ran 0 anywhere" no_ran0

new_t
M=rows.txt
csr scripts/testing/test-ok.sh
r1=$RC
csr scripts/testing/test-ok.sh
r2=$RC
csr scripts/testing/test-ok.sh
r3=$RC
assert R4 "three calls each exit 0" [ "$r1$r2$r3" = 000 ]
assert R4 "three appended rows, none overwritten" content_is "$T/rows.txt" "$(printf 'ran 0 scripts/testing/test-ok.sh\nran 0 scripts/testing/test-ok.sh\nran 0 scripts/testing/test-ok.sh')"

new_t
unset M
csr scripts/testing/test-ok.sh
assert R5 "manifest unset: rc 2" rc_is 2
assert R5 "manifest unset: nothing ran" no_markers
assert R5 "manifest unset: nothing written" absent "$T/rows.txt"
M=""
csr scripts/testing/test-ok.sh
assert R5 "manifest empty: rc 2" rc_is 2
assert R5 "manifest empty: nothing ran" no_markers
assert R5 "manifest empty: nothing written" absent "$T/rows.txt"

new_t
M=rows.txt
mkdir -p "$T/etc"
printf '#!/usr/bin/env bash\ntouch ran-etc.marker\n' >"$T/etc/x.sh"
printf '#!/usr/bin/env bash\ntouch ran-space.marker\n' >"$T/scripts/testing/test ok.sh"
printf '#!/usr/bin/env bash\ntouch ran-bash.marker\n' >"$T/scripts/testing/test-ok.bash"
for p in scripts/../etc/x.sh "scripts/testing/test ok.sh" scripts/testing/test-ok.bash; do
  csr "$p"
  assert R6 "refused path '$p': rc 2" rc_is 2
done
assert R6 "refused paths: nothing ran" no_markers
assert R6 "refused paths: nothing written" absent "$T/rows.txt"
csr scripts/testing/test-missing.sh
assert R6 "missing file: rc 2" rc_is 2
assert R6 "missing file: nothing written" absent "$T/rows.txt"

new_t
mkdir -p "$T/adir"
M=adir
csr scripts/testing/test-ok.sh
assert R7 "manifest path is a directory: rc 2" rc_is 2
assert R7 "manifest path is a directory: the suite never ran" no_markers

new_t
M=rows.txt
csr scripts/testing/test-env.sh
assert R8 "the suite sees the manifest variable unset" [ "$(printf '%s' "$OUT" | grep -c '^\[unset\]$')" = 1 ]
assert R8 "the env suite is recorded ran 0" content_is "$T/rows.txt" "ran 0 scripts/testing/test-env.sh"

new_t
M=rows.txt
export CSR_FIXTURE_M="$T/rows.txt"
csr scripts/testing/test-swap.sh
unset CSR_FIXTURE_M
assert R9 "a manifest swapped for a directory mid-run: non-zero exit" [ "$RC" -ne 0 ]
assert R9 "a manifest swapped for a directory mid-run: no ran 0 anywhere" no_ran0

new_t
touch "$T/afile"
M=afile/rows.txt
csr scripts/testing/test-ok.sh
assert R10 "manifest parent is a regular file: rc 2" rc_is 2
assert R10 "manifest parent is a regular file: the suite never ran" no_markers

# ------------------------------------------------------------ --expected rows
new_t
unset M
rst_with "$A  # a reason that names scripts/testing/test-z.sh" "scripts/foo/test-b.sh  # another scripts/testing/test-z.sh" "scripts/testing/test-c.sh  # reason scripts/testing/test-z.sh"
csr --expected
assert X1 "rc 0" rc_is 0
assert X1 "exactly the two scripts/testing entry paths" [ "$OUT" = "$(printf '%s\n%s' "$A" scripts/testing/test-c.sh)" ]
assert X1 "no comment text in the output" [ "$(printf '%s' "$OUT" | grep -c '#\|test-z')" = 0 ]

new_t
unset M
printf 'SKIP_LIST="\n%s  # r\n' "$A" >"$T/scripts/ci/run-shell-tests.sh"
csr --expected
assert X2 "no closing quote: rc 2" rc_is 2

new_t
unset M
rst_with "scripts/foo/test-b.sh  # r"
csr --expected
assert X3 "no scripts/testing entry: rc 2" rc_is 2

new_t
unset M
printf 'OTHER="\n%s  # r\n"\n' "$A" >"$T/scripts/ci/run-shell-tests.sh"
csr --expected
assert X4 "no SKIP_LIST opening line: rc 2" rc_is 2

new_t
unset M
cp "$REAL_RST" "$T/scripts/ci/run-shell-tests.sh"
csr --expected
assert X5 "real run-shell-tests.sh: rc 0" rc_is 0
only_suite_paths() { [ -n "$OUT" ] && [ "$(printf '%s\n' "$OUT" | grep -vcE '^scripts/testing/test-[A-Za-z0-9._-]+\.sh$')" = 0 ]; }
assert X5 "real run-shell-tests.sh: every line is a bare scripts/testing suite path" only_suite_paths
assert X5 "real run-shell-tests.sh: no duplicate" [ -z "$(printf '%s\n' "$OUT" | sort | uniq -d)" ]
assert X5 "real run-shell-tests.sh: lists the hook smoke suite" [ "$(printf '%s\n' "$OUT" | grep -cx 'scripts/testing/test-mock-hook-smoke.sh')" = 1 ]

# --------------------------------------------------------------- --verify rows
vnew() { # a temp repo whose SKIP_LIST holds A and B (and one other entry)
  new_t
  unset M
  rst_with "$A  # r" "$B  # r" "scripts/foo/test-c.sh  # r"
  mkdir -p "$T/raw"
}
raw() { printf '%s\n' "$@" >"$T/raw/rows.txt"; }
verify() { csr --verify raw/rows.txt outd/m.txt; }
no_out() { [ ! -e "$T/outd/m.txt" ]; }

vnew
raw "ran 0 $A" "ran 3 $B"
mkdir -p "$T/outd"
echo junk >"$T/outd/junk"
verify
assert V1 "valid rows: rc 0" rc_is 0
assert V1 "valid rows: <out> holds the two rows in order" content_is "$T/outd/m.txt" "$(printf 'ran 0 %s\nran 3 %s' "$A" "$B")"
assert V1 "valid rows: a junk file pre-placed in the out directory is gone" absent "$T/outd/junk"

vnew
raw "ran 0 $A" "ran 0 $B" "ran 0 scripts/testing/test-adopt.sh"
verify
assert V2 "a well-formed row outside the set: rc 1" rc_is 1
assert V2 "a well-formed row outside the set: no <out>" no_out

vnew
raw "ran 0 $A" "ran 0 $A" "ran 0 $B"
verify
assert V3 "a duplicated path: rc 1" rc_is 1
assert V3 "a duplicated path: no <out>" no_out

vnew
raw "ran 0 $A"
verify
assert V4 "an expected path missing: rc 1" rc_is 1
assert V4 "an expected path missing: no <out>" no_out

vnew
raw "ran 0 $A extra" "ran 0 $B"
verify
assert V5 "a trailing word: rc 1" rc_is 1
assert V5 "a trailing word: no <out>" no_out
raw "ran 00 $A" "ran 0 $B"
verify
assert V5 "a zero-padded rc: rc 1" rc_is 1
assert V5 "a zero-padded rc: no <out>" no_out
raw " ran 0 $A" "ran 0 $B"
verify
assert V5 "a leading space: rc 1" rc_is 1
assert V5 "a leading space: no <out>" no_out
raw "ran 0 $B extra" "ran 0 $A"
verify
assert V5 "a trailing word on the other member: rc 1" rc_is 1
assert V5 "a trailing word on the other member: no <out>" no_out

vnew
rm -f "$T/raw/rows.txt"
verify
assert V6 "the raw file absent: rc 1" rc_is 1
assert V6 "the raw file absent: no <out>" no_out

vnew
raw "ran 0 $A" "ran 0 $B" "ran 0 scripts/testing/test-adopt.sh"
mkdir -p "$T/outd"
echo 'ran 0 scripts/test-adopt.sh' >"$T/outd/m.txt"
verify
assert V7 "a stale <out> and a refused raw: rc 1" rc_is 1
assert V7 "a stale <out> and a refused raw: neither <out> nor its directory is left" absent "$T/outd"

vnew
printf 'nothing="here"\n' >"$T/scripts/ci/run-shell-tests.sh"
: >"$T/raw/rows.txt"
verify
assert V8 "no SKIP_LIST to read: rc 2" rc_is 2
assert V8 "no SKIP_LIST to read: no <out>" no_out

vnew
raw "ran 0 $A" "ran 0 $B"
for o in x.txt a/b/x.txt ../x.txt raw/x.txt; do
  before="$(cd "$T" && find . | LC_ALL=C sort)"
  csr --verify raw/rows.txt "$o"
  after="$(cd "$T" && find . | LC_ALL=C sort)"
  assert V9 "refused <out> '$o': rc 2" rc_is 2
  assert V9 "refused <out> '$o': working tree untouched" [ "$before" = "$after" ]
  assert V9 "refused <out> '$o': raw file untouched" content_is "$T/raw/rows.txt" "$(printf 'ran 0 %s\nran 0 %s' "$A" "$B")"
done

echo "$pass_n passed, $fail_n failed"
[ "$fail_n" -eq 0 ]
