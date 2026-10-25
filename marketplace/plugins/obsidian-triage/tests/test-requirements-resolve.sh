#!/usr/bin/env bash
# The hashed requirements files must resolve: every pin satisfies the dependency
# ranges its siblings declare. A bump of one package (a Dependabot PR) can leave a
# lock that `pip install --require-hashes` refuses; no CI job installs these files,
# so this suite resolves them (metadata only, nothing is installed).
# Needs uv and the package index; SKIP (exit 0) when either is unreachable.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools="$here/../tools"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }

if ! command -v uv >/dev/null 2>&1; then echo "SKIP: uv not on PATH"; exit 0; fi
if ! curl -sSf -m 10 -o /dev/null https://pypi.org/simple/pyee/; then echo "SKIP: package index unreachable"; exit 0; fi

for f in requirements-scrapling.txt requirements-whisper.txt; do
    rc=0; out=$(uv pip compile --universal --python-version 3.12 --no-header --no-annotate "$tools/$f" -o /dev/null 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then ok "$f resolves"; else no "$f resolves (rc=$rc: $out)"; fi
done

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
