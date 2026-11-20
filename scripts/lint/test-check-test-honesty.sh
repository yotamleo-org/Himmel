#!/usr/bin/env bash
# Suite for the test-honesty gate: scripts/lint/check-test-honesty.sh and its
# pinned lint package. Temp repos get their own node_modules of symlinks into
# the one real install, so no case writes the shared install or its marker.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PKG="$REPO_ROOT/scripts/lint/landmines"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"

BASH_ABS=$(command -v bash)
case "$BASH_ABS" in
    /*) ;;
    *) echo "FATAL: bash must resolve to an absolute path (got '$BASH_ABS')" >&2; exit 1 ;;
esac

PASSED=0
FAILED=0
CLEANUP_PATHS=()
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
    local path
    for path in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do rm -rf -- "$path"; done
}
trap cleanup EXIT

pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Once per suite run, before any case.
ensure_shared_install() {
    if [ -d "$PKG/node_modules" ]; then
        return 0
    fi
    if ! command -v bun >/dev/null 2>&1; then
        if [ -n "${CI:-}" ] || [ -n "${OXLINT_FAIL_CLOSED:-}" ]; then
            echo "FAIL ensure_shared_install: bun not found and the install is needed" >&2
            exit 1
        fi
        echo "SKIP test-check-test-honesty: bun not on PATH and no install at $PKG/node_modules"
        exit 0
    fi
    if ! (cd "$PKG" && bun install --frozen-lockfile); then
        echo "FAIL ensure_shared_install: bun install --frozen-lockfile failed" >&2
        exit 1
    fi
}

# Makes <dir>/scripts/lint/landmines/node_modules a real directory of symlinks
# into the real install, with its own marker for the temp bun.lock.
link_install() {
    local dir="$1" nm entry name
    nm="$dir/scripts/lint/landmines/node_modules"
    rm -rf -- "$nm"
    mkdir -p "$nm/.bin"
    for entry in "$PKG"/node_modules/* "$PKG"/node_modules/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=${entry##*/}
        case "$name" in .bin|.lock-sha256) continue ;; esac
        ln -s "$entry" "$nm/$name"
    done
    ln -s "$PKG/node_modules/.bin/oxlint" "$nm/.bin/oxlint"
    sha256_of "$dir/scripts/lint/landmines/bun.lock" > "$nm/.lock-sha256"
}

# stand_in <dir> <name> <script> [record]: an executable stand-in. oxlint goes in
# the temp install's .bin; any other name goes in <dir>/bin for PATH. With a
# fourth argument the stand-in first appends its argv to <dir>/calls.log.
stand_in() {
    local dir="$1" name="$2" body="$3" record="${4:-}" target
    if [ "$name" = oxlint ]; then
        target="$dir/scripts/lint/landmines/node_modules/.bin/oxlint"
        mkdir -p "$dir/scripts/lint/landmines/node_modules/.bin"
        rm -f -- "$target"
    else
        target="$dir/bin/$name"
        mkdir -p "$dir/bin"
    fi
    {
        echo "#!$BASH_ABS"
        if [ -n "$record" ]; then
            printf '%s\n' "printf '%s\\n' \"\$*\" >> '$dir/calls.log'"
        fi
        printf '%s\n' "$body"
    } > "$target"
    chmod +x "$target"
}

# A committed temp repo shaped like the gate's inputs, with the canonical
# empty-allow config a case may edit.
new_temp_repo() {
    local dir="$1" src
    git init -q "$dir" || return 1
    git -C "$dir" config user.name suite
    git -C "$dir" config user.email suite@example.invalid
    git -C "$dir" config commit.gpgsign false
    mkdir -p "$dir/scripts/lint/landmines" "$dir/scripts/lanes" "$dir/a"
    for src in landmines/package.json landmines/bun.lock landmines/bunfig.toml \
        honesty-surface.mjs check-test-honesty.sh ticket-ref-allow.tsv; do
        if [ -f "$SCRIPT_DIR/$src" ]; then
            case "$src" in
                landmines/*) cp "$SCRIPT_DIR/$src" "$dir/scripts/lint/$src" ;;
                *) cp "$SCRIPT_DIR/$src" "$dir/scripts/lint/${src##*/}" ;;
            esac
        fi
    done
    if [ -f "$REPO_ROOT/scripts/lanes/skill-cost.mjs" ]; then
        cp "$REPO_ROOT/scripts/lanes/skill-cost.mjs" "$dir/scripts/lanes/skill-cost.mjs"
    fi
    cat > "$dir/scripts/lint/landmines/.oxlintrc.json" <<'EOF'
{
  "jsPlugins": [{ "name": "landmines-testing", "specifier": "@interfere/landmines/testing" }],
  "categories": { "correctness": "off", "suspicious": "off", "pedantic": "off", "perf": "off", "style": "off", "restriction": "off", "nursery": "off" },
  "options": { "respectEslintDisableDirectives": false },
  "rules": {
    "landmines-testing/no-fixed-sleep": ["error", { "allow": {} }],
    "landmines-testing/no-flake-masking": ["error", { "allow": {} }],
    "landmines-testing/no-unsignaled-poll": ["error", { "allow": {} }]
  }
}
EOF
    printf '%s\n' 'import { it } from "node:test";' 'it("ok", () => {});' > "$dir/a/x.test.mjs"
    git -C "$dir" add -A || return 1
    git -C "$dir" commit -q -m "temp repo" || return 1
}

ensure_shared_install

# The real install's marker, as it stood before any case.
REAL_MARKER="$PKG/node_modules/.lock-sha256"
if [ -f "$REAL_MARKER" ]; then
    REAL_MARKER_BEFORE="present $(sha256_of "$REAL_MARKER")"
else
    REAL_MARKER_BEFORE="absent"
fi
export REAL_MARKER_BEFORE

# --- cases -------------------------------------------------------------------

case_i4_oxlint_pin_equals_hardening() {
    local want got
    want=$(sed -n 's/^OXLINT_VERSION=//p' "$REPO_ROOT/scripts/hooks/check-oxlint-hardening.sh" | head -n 1)
    got=$(node -e 'process.stdout.write(String(require(process.argv[1]).dependencies.oxlint))' "$PKG/package.json" 2>&1)
    if [ -n "$want" ]; then
        assert_eq "i4-oxlint-pin-equals-hardening" "$want" "$got"
    else
        fail "i4-oxlint-pin-equals-hardening (no OXLINT_VERSION in the hardening gate)"
    fi
}

case_i5_exact_pins() {
    local out
    out=$(node -e '
const d = require(process.argv[1]).dependencies || {};
const keys = Object.keys(d);
const ok = keys.length === 3 && keys.every((k) => /^[0-9]+\.[0-9]+\.[0-9]+$/.test(d[k]));
process.stdout.write(ok ? "ok" : "bad: " + JSON.stringify(d));
' "$PKG/package.json" 2>&1)
    assert_eq "i5-exact-pins" "ok" "$out"
    if [ -f "$PKG/bun.lock" ]; then
        pass "i5-exact-pins bun.lock exists"
    else
        fail "i5-exact-pins bun.lock exists"
    fi
}

case_f1_package_shape() {
    local out
    out=$(node -e '
const assert = require("node:assert");
const p = require(process.argv[1]);
try {
  assert.deepStrictEqual(Object.keys(p).sort(), ["dependencies", "private"]);
  assert.strictEqual(p.private, true);
  assert.deepStrictEqual(Object.keys(p.dependencies).sort(),
    ["@babel/parser", "@interfere/landmines", "oxlint"]);
  process.stdout.write("ok");
} catch (e) { process.stdout.write("bad: " + e.message); }
' "$PKG/package.json" 2>&1)
    assert_eq "f1-package-shape" "ok" "$out"
}

case_config_shape() {
    local out
    out=$(node -e '
const assert = require("node:assert");
const fs = require("node:fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const rules = ["no-fixed-sleep", "no-flake-masking", "no-unsignaled-poll"];
try {
  for (const r of rules) {
    const entry = cfg.rules["landmines-testing/" + r];
    const allow = entry[1].allow;
    assert.ok(allow && typeof allow === "object" && !Array.isArray(allow), r + " allow is a map");
    for (const [k, v] of Object.entries(allow)) {
      assert.ok(typeof k === "string" && k.length > 0, "allow key");
      assert.ok(Number.isInteger(v) && v > 0, r + " allow value for " + k);
    }
    entry[1].allow = {};
  }
  const expected = {
    jsPlugins: [{ name: "landmines-testing", specifier: "@interfere/landmines/testing" }],
    categories: { correctness: "off", suspicious: "off", pedantic: "off", perf: "off", style: "off", restriction: "off", nursery: "off" },
    options: { respectEslintDisableDirectives: false },
    rules: {
      "landmines-testing/no-fixed-sleep": ["error", { allow: {} }],
      "landmines-testing/no-flake-masking": ["error", { allow: {} }],
      "landmines-testing/no-unsignaled-poll": ["error", { allow: {} }],
    },
  };
  assert.deepStrictEqual(cfg, expected);
  process.stdout.write("ok");
} catch (e) { process.stdout.write("bad: " + e.message); }
' "$PKG/.oxlintrc.json" 2>&1)
    assert_eq "config-shape" "ok" "$out"
}

case_harness_smoke() {
    local d out
    d=$(fixture_mktemp_dir) || { fail "harness-smoke (no temp dir)"; return; }
    CLEANUP_PATHS+=("$d")
    new_temp_repo "$d" || { fail "harness-smoke (new_temp_repo)"; return; }
    link_install "$d"
    stand_in "$d" bun 'exit 0' record
    "$d/bin/bun" install --frozen-lockfile
    out=$(git -C "$d" ls-files a/x.test.mjs)
    assert_eq "harness-smoke tracked default surface file" "a/x.test.mjs" "$out"
    assert_eq "harness-smoke stand-in records argv" "install --frozen-lockfile" "$(cat "$d/calls.log")"
    out=$("$d/scripts/lint/landmines/node_modules/.bin/oxlint" --version 2>&1)
    case "$out" in
        *1.93.0*) pass "harness-smoke temp install runs the real oxlint" ;;
        *) fail "harness-smoke temp install runs the real oxlint ($out)" ;;
    esac
    assert_eq "harness-smoke temp marker is the temp lock sha" \
        "$(sha256_of "$d/scripts/lint/landmines/bun.lock")" \
        "$(cat "$d/scripts/lint/landmines/node_modules/.lock-sha256")"
    if [ -L "$d/scripts/lint/landmines/node_modules/@interfere" ] \
        && [ -d "$d/scripts/lint/landmines/node_modules/.bin" ] \
        && [ ! -L "$d/scripts/lint/landmines/node_modules/.bin" ]; then
        pass "harness-smoke node_modules is a real dir of symlinks"
    else
        fail "harness-smoke node_modules is a real dir of symlinks"
    fi
}

case_i4_oxlint_pin_equals_hardening
case_i5_exact_pins
case_f1_package_shape
case_config_shape
case_harness_smoke

echo ""
echo "$PASSED passed, $FAILED failed"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
