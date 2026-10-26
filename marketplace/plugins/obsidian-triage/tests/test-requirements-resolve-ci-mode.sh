#!/usr/bin/env bash
# test-requirements-resolve.sh fails closed when HIMMEL_REQUIRE_UV=1 (set by the CI
# shards): a missing uv or an unreachable index is a FAIL, not a SKIP. Without the
# flag both stay a SKIP. One index miss is retried. Hermetic: uv and curl are stubs
# on a PATH that holds only the tools the suite calls.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite="$here/test-requirements-resolve.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/requirements-resolve-ci.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }

bash_bin="$(command -v bash)"
# A PATH with the suite's tools but no uv; curl is a stub that fails the first
# $CURL_FAILS calls (counted in $tmp/curl-calls), then succeeds.
mkbin() {
  local bin="$tmp/$1"; mkdir -p "$bin"
  for t in bash dirname mktemp rm sed grep cat sleep diff; do ln -s "$(command -v "$t")" "$bin/$t"; done
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CURL_COUNT" # read-sink-ok: hermetic test stub, counter file the test itself set under its mktemp dir
[ "$n" -gt "${CURL_FAILS:-0}" ] || exit 7
EOF
  chmod 755 "$bin/curl"
  ln -s "$(command -v env)" "$bin/env"
}
mkbin nouv
mkbin withuv
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/withuv/uv"; chmod 755 "$tmp/withuv/uv"

run() { # <bin> <require> <curl-fails>
  rm -f "$tmp/curl-calls"
  out=$(env -i PATH="$tmp/$1" HOME="$tmp" TMPDIR="$tmp" HIMMEL_REQUIRE_UV="$2" CURL_FAILS="$3" CURL_COUNT="$tmp/curl-calls" \
    "$bash_bin" "$suite" 2>&1); rc=$?
}

run nouv 1 0
if [ "$rc" != 0 ] && grep -q "uv" <<< "$out"; then ok "no uv, HIMMEL_REQUIRE_UV=1: FAIL"; else no "no uv, HIMMEL_REQUIRE_UV=1: FAIL (rc=$rc: $out)"; fi
run nouv "" 0
if [ "$rc" = 0 ] && grep -q "^SKIP: uv" <<< "$out"; then ok "no uv, no flag: SKIP"; else no "no uv, no flag: SKIP (rc=$rc: $out)"; fi
run withuv 1 99
if [ "$rc" != 0 ] && grep -q "index" <<< "$out"; then ok "index down, HIMMEL_REQUIRE_UV=1: FAIL"; else no "index down, HIMMEL_REQUIRE_UV=1: FAIL (rc=$rc: $out)"; fi
run withuv "" 99
if [ "$rc" = 0 ] && grep -q "^SKIP: package index" <<< "$out"; then ok "index down, no flag: SKIP"; else no "index down, no flag: SKIP (rc=$rc: $out)"; fi
run withuv 1 1
# The stub uv writes no lock, so the suite's freshness rows fail: rc is 1, never 0, and the
# Results line proves the run got past the retry to the resolve rows instead of dying early.
if [ "$(cat "$tmp/curl-calls")" = 2 ] && [ "$rc" = 1 ] && grep -q "^Results: " <<< "$out" && ! grep -q "SKIP\|index" <<< "$out"; then ok "one index miss is retried"; else no "one index miss is retried (rc=$rc calls=$(cat "$tmp/curl-calls"): $out)"; fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
