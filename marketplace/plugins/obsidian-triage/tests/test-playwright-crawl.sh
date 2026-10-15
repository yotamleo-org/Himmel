#!/usr/bin/env bash
# Smoke tests for the YouTube crawler (LUNA-27; the Playwright auth-save /
# crawl-x tools and the storage_state path no longer exist).
#
# Scope: validates that playwright-crawl-youtube.mjs parses, the package.json
# declares the right deps, the removed cookie-state tools stay gone, and the
# crawler exits rc=2 with a clear message when the Scrapling venv is missing.
#
# Does NOT actually launch a browser or hit the network.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# -- Test 1: the crawler exists + parses; the removed tools stay gone ----
echo "Test 1: playwright-crawl-youtube.mjs exists and parses; removed tools gone"
cy="$TOOLS_DIR/playwright-crawl-youtube.mjs"
if [ -r "$cy" ]; then ex=yes; else ex=no; fi
assert "playwright-crawl-youtube.mjs exists" "yes" "$ex"
if node --check "$cy" 2>/dev/null; then parsed=ok; else parsed=fail; fi
assert "playwright-crawl-youtube.mjs parses (node --check)" "ok" "$parsed"
for f in playwright-auth-save.mjs playwright-crawl-x.mjs; do
    if [ -e "$TOOLS_DIR/$f" ]; then gone=present; else gone=gone; fi
    assert "$f is removed" "gone" "$gone"
done

# -- Test 2: package.json declares playwright + js-yaml deps --------------
echo "Test 2: package.json declares required deps"
pkg="$TOOLS_DIR/package.json"
if [ -r "$pkg" ]; then
    assert "package.json exists" "yes" "yes"
    if grep -q '"playwright"' "$pkg"; then has_pw=yes; else has_pw=no; fi
    assert "package.json declares playwright" "yes" "$has_pw"
    if grep -q '"js-yaml"' "$pkg"; then has_yaml=yes; else has_yaml=no; fi
    assert "package.json declares js-yaml" "yes" "$has_yaml"
    # Pin check — playwright must be pinned to an EXACT version (no ^ / ~ / range)
    # for stability. The test used to hard-code 1.58.x and went red on every
    # legitimate bump; the invariant is "exact", not a version.
    if grep -qE '"playwright":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$pkg"; then pinned=yes; else pinned=no; fi
    assert "package.json pins playwright to an exact version" "yes" "$pinned"
else
    assert "package.json exists" "yes" "no"
fi

# -- Test 3: no cookie / storage-state path remains ----------------------
echo "Test 3: crawler carries no storage_state path"
if grep -q 'playwright-state\|youtube\.json\|storage_state\|HIMMEL_MEDIA_COOKIES' "$cy"; then st=present; else st=absent; fi
assert "crawl-youtube.mjs has no storage_state / switch reference" "absent" "$st"

# -- Test 4: crawler exits rc=2 when the Scrapling venv is missing --------
echo "Test 4: crawler exits rc=2 when the Scrapling venv is missing"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fake_vault="$tmpdir/vault"
mkdir -p "$fake_vault/Clippings"
HOME_SAVED="${HOME:-}"
HOME="$tmpdir" USERPROFILE="$tmpdir" YT_SCRAPLING_PYTHON="" node "$cy" --vault "$fake_vault" --dry-run >/dev/null 2>"$tmpdir/y.err"
y_rc=$?
HOME="$HOME_SAVED"
assert "crawl-youtube.mjs rc=2 on missing scrapling venv" "2" "$y_rc"
if grep -qi 'scrapling-venv' "$tmpdir/y.err"; then y_msg=yes; else y_msg=no; fi
assert "crawl-youtube.mjs error msg names the scrapling venv" "yes" "$y_msg"

# -- Test 5: --dry-run flag prevents write side-effects ------------------
# Verified at the code level: dryRun branch returns BEFORE any
# writeFileSync call. Smoke-check the branch is present in both crawlers.
echo "Test 5: --dry-run flag short-circuits write path"
f="$cy"
if grep -q 'dryRun' "$f" && grep -q 'would crawl' "$f"; then
    has_dry=yes
else
    has_dry=no
fi
assert "$(basename "$f") implements --dry-run" "yes" "$has_dry"

# -- Test 6: G-3 + revert-on-failure machinery present -------------------
echo "Test 6: G-3 invariant + revert-on-failure present"
f="$cy"
if grep -q 'G-3' "$f" && grep -q 'reverted' "$f"; then
    has_g3=yes
else
    has_g3=no
fi
assert "$(basename "$f") implements G-3 + revert" "yes" "$has_g3"

# -- Test 7: YAML parse-validate on post-write frontmatter ---------------
echo "Test 7: YAML parse-validate via js-yaml present"
f="$cy"
if grep -q "js-yaml" "$f"; then has_yaml=yes; else has_yaml=no; fi
assert "$(basename "$f") uses js-yaml" "yes" "$has_yaml"

# -- Test 8: secrets — storage_state path never logged with contents -----
# We log the PATH (acceptable, helps debugging) but never read or log the
# file's contents. Defensive check: no `readFileSync(.*state)` patterns
# in the crawler scripts beyond passing to playwright.
echo "Test 8: storage_state never read by app code"
f="$cy"
# Grep for any explicit read of the state file.
if grep -E 'readFileSync\(.*statePath' "$f" >/dev/null; then
    leak=yes
else
    leak=no
fi
assert "$(basename "$f") does NOT read storage_state contents" "no" "$leak"

# -- Summary -------------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
