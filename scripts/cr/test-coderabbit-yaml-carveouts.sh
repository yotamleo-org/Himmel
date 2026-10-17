#!/usr/bin/env bash
# Pins the scripts/**/*.sh false-positive carve-outs in .coderabbit.yaml: a
# non-final && failure in an errexit file, and a test that never touches
# handover state. Also guards the file parsing and the bare `wait` / `rm -f`
# rules staying single.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# One whitespace-normalized instruction per scripts/**/*.sh entry.
instrs=$(python3 -I -c '
import re, yaml
d = yaml.safe_load(open(".coderabbit.yaml"))
for e in d["reviews"]["path_instructions"]:
    if e["path"] == "scripts/**/*.sh":
        print(re.sub(r"\s+", " ", e["instructions"]))
') || { echo "FAIL: yaml extraction errored"; exit 1; }

# expect_one <label> <fixed-string> — exactly one entry contains the string.
expect_one() {
  local n
  n=$(grep -cF -- "$2" <<<"$instrs")
  if [ "$n" = 1 ]; then ok "$1"; else bad "$1 (found in $n entries)"; fi
}

if [ -n "$instrs" ]; then ok "yaml parses and has scripts/**/*.sh entries"; else bad "yaml parse"; fi

# shellcheck disable=SC2016 # backticks are literal YAML text
expect_one "errexit rule exempts a non-final && command" 'NON-FINAL position of an `&&` list'
expect_one "handover rule carves out handover-path-free tests" 'neither reads, writes, resolves nor hardcodes any handover path'
# shellcheck disable=SC2016
expect_one "bare wait rule single" 'Bare `wait` (no PID)'
# shellcheck disable=SC2016
expect_one "rm -f rule single" '`rm -f` on a quoted single-file'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
