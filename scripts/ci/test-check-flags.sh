#!/usr/bin/env bash
# test-check-flags.sh — check-flags.sh on fixture trees: a clean pass, then each failure class
# (expired row, flag read but unregistered, registered but never read, a read under scripts/hooks/,
# in a gate script, or on a ci-trust-paths.txt path) and the registry-shape errors.
# CHECK_FLAGS overrides the script under test (the RED control: a missing script fails every
# row). bash 3.2-safe.
#
# Run: bash scripts/ci/test-check-flags.sh
# shellcheck disable=SC2015,SC2016  # A && pass || fail reporting idiom (pass never fails); the printf bodies are literal fixture text
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${CHECK_FLAGS:-$HERE/check-flags.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check-flags.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
TODAY=2026-10-26

# tree <name>: a fixture repo with one registered, read, unexpired flag
tree() {
    local t="$WORK/$1"
    rm -rf "$t"; mkdir -p "$t/scripts/lib" "$t/scripts/ci" "$t/scripts/handover/chief-kit" "$t/scripts/hooks" "$t/scripts/cr"
    printf '# registry\nalpha\toff\tfeature\tT-1\tT-2\t2026-11-09\ta flag\n' > "$t/scripts/lib/flags.tsv"
    printf '#!/usr/bin/env bash\nif himmel_flag alpha; then echo on; fi\n' > "$t/scripts/handover/chief-kit/user.sh"
    printf '^scripts/lib/\n^scripts/ci/\n^scripts/trusted/\n' > "$t/scripts/ci/ci-trust-paths.txt"
    printf '^scripts/hooks/lib/\n' > "$t/scripts/ci/ci-trust-paths-core.txt"
    printf '%s' "$t"
}
# run <tree> -> rc on stdout line 1, output after
run() { bash "$SUT" --root "$1" --today "$TODAY" > "$WORK/out" 2>&1; echo $?; }
expect_rc() { # <label> <tree> <rc> [needle]
    local rc; rc="$(run "$2")"
    if [ "$rc" != "$3" ]; then fail "$1 (want rc $3, got $rc: $(head -3 "$WORK/out" | tr '\n' '|'))"; return; fi
    if [ -n "${4:-}" ] && ! grep -qF "$4" "$WORK/out"; then fail "$1 (output lacks '$4': $(head -3 "$WORK/out" | tr '\n' '|'))"; return; fi
    pass "$1"
}

t="$(tree clean)"
expect_rc "a clean tree passes" "$t" 0

t="$(tree expired)"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-10-25\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "an expired row fails" "$t" 1 "expired: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-10-26\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a row expiring today still passes" "$t" 0

# the expiry warning: three days or fewer left prints a WARN and still exits 0
t="$(tree expiring)"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-10-28\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a flag expiring in 2 days warns and passes" "$t" 0 "WARN flag alpha expires 2026-10-28 (in 2 days)"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-11-02\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a flag expiring across a month end in 7 days does not warn" "$t" 0
grep -q WARN "$WORK/out"; case $? in 1) pass "a flag 7 days out prints no WARN" ;; *) fail "a flag 7 days out must not warn" ;; esac
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-10-29\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a flag expiring in 3 days warns" "$t" 0 "WARN flag alpha expires 2026-10-29 (in 3 days)"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-10-30\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a flag expiring in 4 days passes" "$t" 0
grep -q WARN "$WORK/out"; case $? in 1) pass "a flag 4 days out prints no WARN" ;; *) fail "a flag 4 days out must not warn" ;; esac

t="$(tree unregistered)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\nhimmel_flag beta\n' > "$t/scripts/handover/chief-kit/user.sh"
expect_rc "a shell read of an unregistered flag fails" "$t" 1 "unregistered: beta"
printf 'from flags import himmel_flag\nhimmel_flag("alpha")\nhimmel_flag("gamma")\n' > "$t/scripts/handover/chief-kit/u.py"
expect_rc "a python read of an unregistered flag fails" "$t" 1 "unregistered: gamma"
rm -f "$t/scripts/handover/chief-kit/u.py"
printf "import { himmelFlag } from './flags.mjs';\nhimmelFlag('alpha');\nhimmelFlag('delta');\n" > "$t/scripts/handover/chief-kit/u.mjs"
expect_rc "a node read of an unregistered flag fails" "$t" 1 "unregistered: delta"
printf "himmelFlag( 'alpha');\nhimmelFlag( 'theta');\n" > "$t/scripts/handover/chief-kit/u.mjs"
expect_rc "a read with a space after the parenthesis is seen" "$t" 1 "unregistered: theta"
rm -f "$t/scripts/handover/chief-kit/u.mjs"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n[ "${HIMMEL_FLAG_EPSILON:-0}" = 1 ] && echo x\n' > "$t/scripts/handover/chief-kit/user.sh"
expect_rc "a HIMMEL_FLAG_ env read of an unregistered flag fails" "$t" 1 "unregistered: epsilon"

t="$(tree unread)"
rm -f "$t/scripts/handover/chief-kit/user.sh"
expect_rc "a registered flag that no code reads fails" "$t" 1 "unread: alpha"
printf '#!/usr/bin/env bash\nHIMMEL_FLAG_ALPHA=1 bash x\n' > "$t/scripts/handover/chief-kit/test-user.sh"
expect_rc "a read in a test file does not count as a read" "$t" 1 "unread: alpha"

t="$(tree hook)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/hooks/block-x.sh"
expect_rc "a read under scripts/hooks/ fails" "$t" 1 "forbidden: alpha read in scripts/hooks/block-x.sh"

t="$(tree gate-cr)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/cr/gate.sh"
expect_rc "a read in scripts/cr/ fails" "$t" 1 "forbidden: alpha read in scripts/cr/gate.sh"

t="$(tree gate-mog)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/handover/merge-on-green.sh"
expect_rc "a read in merge-on-green.sh fails" "$t" 1 "forbidden: alpha read in scripts/handover/merge-on-green.sh"

t="$(tree gate-go)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/handover/chief-kit/go.sh"
expect_rc "a read in go.sh fails" "$t" 1 "forbidden: alpha read in scripts/handover/chief-kit/go.sh"

t="$(tree gate-mfc)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/handover/merge-forward-check.sh"
expect_rc "a read in merge-forward-check.sh fails" "$t" 1 "forbidden: alpha read in scripts/handover/merge-forward-check.sh"

# one level down: a gate that execs or sources a helper by a literal path inherits the helper's reads
t="$(tree gate-exec)"
printf '#!/usr/bin/env bash\nSCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"\nexec bash "$SCRIPT_DIR/chief-kit/user.sh" "$@"\n' > "$t/scripts/handover/merge-forward-check.sh"
expect_rc "a gate that execs a helper reading a flag fails" "$t" 1 "forbidden: alpha read in scripts/handover/chief-kit/user.sh (reached from scripts/handover/merge-forward-check.sh)"
printf '#!/usr/bin/env bash\n. "$HERE/../handover/chief-kit/user.sh"\n' > "$t/scripts/cr/gate.sh"
rm -f "$t/scripts/handover/merge-forward-check.sh"
expect_rc "a gate that sources a helper reading a flag fails" "$t" 1 "forbidden: alpha read in scripts/handover/chief-kit/user.sh (reached from scripts/cr/gate.sh)"
printf '#!/usr/bin/env bash\npython3 -I scripts/handover/chief-kit/user.sh\n' > "$t/scripts/cr/gate.sh"
expect_rc "a repo-root literal path is followed too" "$t" 1 "(reached from scripts/cr/gate.sh)"
printf '#!/usr/bin/env bash\necho "see scripts/handover/chief-kit/user.sh"\n' > "$t/scripts/cr/gate.sh"
expect_rc "a gate that only names the helper is clean" "$t" 0

t="$(tree trust)"
mkdir -p "$t/scripts/trusted"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/trusted/x.sh"
expect_rc "a read on a ci-trust-paths.txt path fails" "$t" 1 "forbidden: alpha read in scripts/trusted/x.sh"

t="$(tree trust-core)"
mkdir -p "$t/scripts/hooks/lib"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/hooks/lib/y.sh"
expect_rc "a read on a ci-trust-paths-core.txt path fails" "$t" 1 "forbidden: alpha read in scripts/hooks/lib/y.sh"

t="$(tree notrust)"
rm -f "$t/scripts/ci/ci-trust-paths-core.txt"
expect_rc "an unreadable ci-trust-paths file fails closed" "$t" 2 "cannot read"

t="$(tree readers)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/lib/flags.sh"
printf 'himmel_flag zeta\n' > "$t/scripts/ci/check-flags.sh"
printf 'himmel_flag zeta\n' > "$t/scripts/lib/test-flags.sh"
printf 'himmel_flag zeta\n' > "$t/scripts/ci/test-check-flags.sh"
expect_rc "the readers, the check and their tests are not reads" "$t" 0

t="$(tree lookalike)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/hooks/flags.sh"
expect_rc "a reader-named file under scripts/hooks/ is still a forbidden read" "$t" 1 "forbidden: alpha read in scripts/hooks/flags.sh"
rm -f "$t/scripts/hooks/flags.sh"
printf 'himmel_flag("alpha")\n' > "$t/scripts/cr/flags.py"
expect_rc "a reader-named file under scripts/cr/ is still a forbidden read" "$t" 1 "forbidden: alpha read in scripts/cr/flags.py"

t="$(tree unreadable)"
printf '#!/usr/bin/env bash\nhimmel_flag alpha\n' > "$t/scripts/hooks/hidden.sh"
chmod 000 "$t/scripts/hooks/hidden.sh"
if [ -r "$t/scripts/hooks/hidden.sh" ]; then
    pass "an unreadable source file fails closed (skipped: this user can read mode 000, e.g. root)"
else
    expect_rc "an unreadable source file fails closed (rc 2)" "$t" 2 "scan"
fi
chmod 600 "$t/scripts/hooks/hidden.sh"

t="$(tree malformed)"
printf 'alpha\toff\tfeature\tT-1\tT-2\tsoon\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a malformed expiry date fails" "$t" 1 "malformed: alpha"
printf 'alpha\tmaybe\tfeature\tT-1\tT-2\t2026-11-09\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a default other than on or off fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a short row fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-11-09\ta\nalpha\toff\tfeature\tT-1\tT-2\t2026-11-09\tb\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a duplicate name fails" "$t" 1 "duplicate: alpha"

printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-11-09\ta\textra\n' > "$t/scripts/lib/flags.tsv"
expect_rc "a row with more than seven columns fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\t\tT-2\t2026-11-09\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "an empty owner fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\t\t2026-11-09\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "an empty removal ticket fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-99-99\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "an impossible expiry date fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2026-04-31\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "April 31 fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2027-02-29\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "February 29 of a common year fails" "$t" 1 "malformed: alpha"
printf 'alpha\toff\tfeature\tT-1\tT-2\t2028-02-29\ta flag\n' > "$t/scripts/lib/flags.tsv"
expect_rc "February 29 of a leap year passes" "$t" 0

t="$(tree noregistry)"
rm -f "$t/scripts/lib/flags.tsv"
expect_rc "a missing registry is a usage error (rc 2)" "$t" 2 "registry"

bash "$SUT" --bogus > "$WORK/out" 2>&1; rc=$?
[ "$rc" = 2 ] && pass "an unknown option is rc 2" || fail "an unknown option gave rc $rc"

# the shipped tree passes its own check (today's date, the real registry and code)
ROOT="$(cd "$HERE/../.." && pwd)"
bash "$SUT" --root "$ROOT" > "$WORK/out" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "the shipped tree passes check-flags.sh" || fail "the shipped tree fails: $(head -5 "$WORK/out" | tr '\n' '|')"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
