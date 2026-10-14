#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-plan-shards.sh — scripts/ci/plan-shards.sh: the
# plan job's list of shell-unit shards that have a suite to run. Each case runs
# a COPY of plan-shards.sh beside a stub shard-has-work.sh that answers per shard.
#
#   PS1  every shard has work                  -> all n listed, nothing absent
#   PS2  no shard has work (docs-only)         -> shards=[] , every shard absent
#   PS3  some shards empty                     -> only those with work listed
#   PS4  a probe that fails or prints nothing  -> that shard is listed (fail closed)
#   PS5  a probe that prints garbage           -> that shard is listed (fail closed)
#   PS6  usage error (no / non-numeric n)      -> rc 2
#   PS7  the probe gets the shard spec and root it was asked about
#   PS8  ci.yml feeds the shard matrix from the plan output and guards the empty list
#
# Platform guard: bash-only, no .ps1 twin; Linux CI is the caller.
#
# Usage: bash scripts/ci/test-plan-shards.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
PS="$SUITE_LOCK_SANDBOX/ps"
mkdir -p "$PS"
if [ ! -f "$SRC_ROOT/scripts/ci/plan-shards.sh" ]; then
  fail "missing scripts/ci/plan-shards.sh"
  rst_tally
fi
cp "$SRC_ROOT/scripts/ci/plan-shards.sh" "$PS/plan-shards.sh"
# The stub answers from $STUB_ANSWERS, a space list of <k>=<true|false|fail|junk>,
# and records every call to $STUB_LOG.
cat > "$PS/shard-has-work.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${1:-}" "${2:-}" >> "${STUB_LOG:-/dev/null}"
k="${1%%/*}"
for a in $STUB_ANSWERS; do
  [ "${a%%=*}" = "$k" ] || continue
  case "${a#*=}" in
    true|false) echo "has_work=${a#*=}" ;;
    fail) echo "boom" >&2; exit 3 ;;
    junk) echo "has_work=maybe" ;;
  esac
  exit 0
done
exit 0
STUB

run_ps() { STUB_ANSWERS="$1" STUB_LOG="$PS/log" bash "$PS/plan-shards.sh" "${@:2}" 2>/dev/null; }
check() { # check <label> <answers> <n> <want-shards> <want-absent>
  local out
  out=$(run_ps "$2" "$3" .)
  if [ "$out" = "$(printf 'shards=%s\nabsent_shards=%s' "$4" "$5")" ]; then pass "$1"; else fail "$1: got [$out]"; fi
}

check "PS1 every shard has work" "1=true 2=true 3=true" 3 "[1,2,3]" ""
check "PS2 docs-only: no shard has work" "1=false 2=false 3=false" 3 "[]" "1 2 3"
check "PS3 some shards empty" "1=true 2=false 3=true 4=false" 4 "[1,3]" "2 4"
check "PS4 a failing and a silent probe stay listed" "1=fail 2=false 3=" 3 "[1,3]" "2"
check "PS5 a garbage probe answer stays listed" "1=junk 2=false" 2 "[1]" "2"

if STUB_ANSWERS="" bash "$PS/plan-shards.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ]; then pass "PS6 no shard count is a usage error"; else fail "PS6 no n: rc $rc"; fi
if STUB_ANSWERS="" bash "$PS/plan-shards.sh" x . >/dev/null 2>&1; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ]; then pass "PS6 non-numeric n is a usage error"; else fail "PS6 bad n: rc $rc"; fi

: > "$PS/log"
run_ps "1=true 2=true" 2 /some/root >/dev/null
if [ "$(sort "$PS/log")" = "$(printf '1/2|/some/root\n2/2|/some/root')" ]; then pass "PS7 each probe gets <k>/<n> and the root"; else fail "PS7: $(cat "$PS/log")"; fi

CI="$SRC_ROOT/.github/workflows/ci.yml"
if grep -q 'plan-shards.sh' "$CI" \
   && grep -q "shard: \${{ fromJSON(" "$CI" \
   && grep -q "shards != '\[\]'" "$CI"; then
  pass "PS8 ci.yml builds the shard matrix from the plan and skips an empty list"
else
  fail "PS8 ci.yml does not wire plan-shards.sh into the shard matrix"
fi

rst_tally
