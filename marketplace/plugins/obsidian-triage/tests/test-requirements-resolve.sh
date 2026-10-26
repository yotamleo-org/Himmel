#!/usr/bin/env bash
# The hashed requirements files must resolve: every pin satisfies the dependency
# ranges its siblings declare. A bump of one package (a Dependabot PR) can leave a
# lock that `pip install --require-hashes` refuses; no CI job installs these files,
# so this suite resolves them (metadata only, nothing is installed).
# The scrapling lock pins `scrapling`, not `scrapling[fetchers]`, so a second input
# line activates the extra whose floors (curl-cffi, patchright, ...) the lock must meet.
# Needs uv and the package index; SKIP (exit 0) when either is unreachable.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools="$here/../tools"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/requirements-resolve.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }

if ! command -v uv >/dev/null 2>&1; then echo "SKIP: uv not on PATH"; exit 0; fi
if ! curl -sSf -m 10 -o /dev/null https://pypi.org/simple/pyee/; then echo "SKIP: package index unreachable"; exit 0; fi

printf 'scrapling[fetchers]\n' > "$tmp/fetchers.in"
resolve() { local py=$1; shift; uv pip compile --universal --python-version "$py" --no-header --no-annotate -o /dev/null "$@" 2>&1; }

# The scrapling venv is built with a bare `python3`, so its lock must resolve below 3.12
# (pyee 14 needs 3.12+). 3.11 is the lowest the lock reaches: cssselect 1.6.0 needs 3.11+.
# The whisper lock only runs under `uv run --python 3.12`.
rc=0; out=$(resolve 3.11 "$tools/requirements-scrapling.txt" "$tmp/fetchers.in") || rc=$?
if [ "$rc" = 0 ]; then ok "requirements-scrapling.txt resolves with the fetchers extra on python 3.11"; else no "requirements-scrapling.txt resolves with the fetchers extra on python 3.11 (rc=$rc: $out)"; fi
rc=0; out=$(resolve 3.12 "$tools/requirements-whisper.txt") || rc=$?
if [ "$rc" = 0 ]; then ok "requirements-whisper.txt resolves"; else no "requirements-whisper.txt resolves (rc=$rc: $out)"; fi

# A bump that edits only the `==` line leaves the previous version's --hash lines, which
# `--require-hashes` refuses. Re-pin every `==` line of a lock, regenerate its hashes from the
# index, and diff against the committed file: a stale hash on ANY package fails here.
fresh() { local lock=$1 py=$2 name=$3 rc=0 out
    grep -E '^[A-Za-z0-9_.-]+(\[[^]]*\])?==' "$lock" | sed 's/ *\\$//' > "$tmp/$name.in"
    out=$(uv pip compile --universal --python-version "$py" --generate-hashes --no-header --no-annotate -o "$tmp/$name.out" "$tmp/$name.in" 2>&1) || rc=$?
    if [ "$rc" != 0 ]; then no "$name lock regenerates (rc=$rc: $out)"; return; fi
    if diff <(grep -vE '^[[:space:]]*#' "$lock") "$tmp/$name.out" > "$tmp/$name.diff"; then ok "$name lock is fresh: committed hashes equal the regenerated ones"
    else no "$name lock is stale: committed hashes differ from the regenerated ones ($(grep -c '^[<>]' "$tmp/$name.diff") differing lines, first: $(grep -m1 '^[<>]' "$tmp/$name.diff"))"; fi
}
fresh "$tools/requirements-whisper.txt" 3.12 whisper
fresh "$tools/requirements-scrapling.txt" 3.11 scrapling

# Control: a curl-cffi below the extra's floor resolves without the extra and is refused with it.
sed 's/^curl-cffi==.*/curl-cffi==0.15.0 \\/' "$tools/requirements-scrapling.txt" > "$tmp/stale.txt"
rc=0; out=$(resolve 3.11 "$tmp/stale.txt") || rc=$?
if [ "$rc" = 0 ]; then ok "control: a stale curl-cffi resolves without the extra"; else no "control: a stale curl-cffi resolves without the extra (rc=$rc: $out)"; fi
rc=0; out=$(resolve 3.11 "$tmp/stale.txt" "$tmp/fetchers.in") || rc=$?
if [ "$rc" != 0 ] && grep -q "curl-cffi" <<< "$out"; then ok "control: a stale curl-cffi is refused with the extra"; else no "control: a stale curl-cffi is refused with the extra (rc=$rc: $out)"; fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
