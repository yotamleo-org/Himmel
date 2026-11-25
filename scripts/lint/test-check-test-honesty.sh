#!/usr/bin/env bash
# selector: tree-scan
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

REAL_MARKER="$PKG/node_modules/.lock-sha256"
if [ -f "$REAL_MARKER" ]; then
    REAL_MARKER_BEFORE="present $(sha256_of "$REAL_MARKER")"
else
    REAL_MARKER_BEFORE="absent"
fi
export REAL_MARKER_BEFORE

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

case_package_shape() {
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
    assert_eq "package-shape" "ok" "$out"
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
        *1.94.0*) pass "harness-smoke temp install runs the real oxlint" ;;
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

hs() {
    local dir="$1"
    shift
    HS_OUT=$(cd "$dir" && node scripts/lint/honesty-surface.mjs "$@" 2>&1 </dev/null)
    HS_RC=$?
}

mk_repo() {
    REPO=$(fixture_mktemp_dir) || return 1
    CLEANUP_PATHS+=("$REPO")
    new_temp_repo "$REPO"
}

put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "${2:-x}" > "$REPO/$1"
}

edit_cfg() {
    node -e '
const fs = require("node:fs");
const f = process.argv[1];
const c = JSON.parse(fs.readFileSync(f, "utf8"));
'"$1"'
fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");
' "$REPO/scripts/lint/landmines/.oxlintrc.json" </dev/null
}

reset_cfg() {
    git -C "$REPO" checkout -q -- scripts/lint/landmines/.oxlintrc.json
}

assert_has() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$label" ;;
        *) fail "$label"; echo "     missing: $needle"; echo "     in: $hay" ;;
    esac
}

in_lines() {
    printf '%s\n' "$2" | grep -qxF -- "$1"
}

case_i6_surface() {
    local p
    mk_repo || { fail "i6-surface (no temp repo)"; return; }
    put a/x.test.ts
    put a/tests/y.mjs
    put a/test-foo.mjs
    put a/test_z.mjs
    put a/__tests__/x.js
    put a/foo-cases/y.mjs
    put docs-site/e2e/j1.e2e.ts
    put scripts/lib/test-tmpdir.mjs
    put v/VENDORED.md 'local=keep'
    put v/keep/y.test.ts
    put v/x.test.ts
    put w/VENDORED.md 'upstream prose'
    put w/z.test.ts
    put src/fleet.ts 'describe(a, b, c);'
    put a/fixtures/x.test.ts
    put a/fixture/s.test.ts
    put a/__fixtures__/r.test.ts
    put a/node_modules/q.test.js
    put dist/x.test.js
    put a/notes.test.md
    git -C "$REPO" add -A
    hs "$REPO" --list
    assert_eq "i6-surface --list exits 0" 0 "$HS_RC"
    for p in a/x.test.ts a/tests/y.mjs a/test-foo.mjs a/test_z.mjs a/__tests__/x.js a/foo-cases/y.mjs \
        docs-site/e2e/j1.e2e.ts scripts/lib/test-tmpdir.mjs v/keep/y.test.ts a/x.test.mjs; do
        if in_lines "$p" "$HS_OUT"; then pass "i6-surface on: $p"; else fail "i6-surface on: $p"; fi
    done
    for p in src/fleet.ts a/fixtures/x.test.ts a/fixture/s.test.ts a/__fixtures__/r.test.ts \
        a/node_modules/q.test.js dist/x.test.js scripts/lint/honesty-surface.mjs v/x.test.ts \
        w/z.test.ts a/notes.test.md; do
        if in_lines "$p" "$HS_OUT"; then fail "i6-surface off: $p"; else pass "i6-surface off: $p"; fi
    done
    hs "$REPO" --list a/x.test.ts src/fleet.ts nope.test.ts
    assert_eq "i6-surface --list PATH intersects" "a/x.test.ts" "$HS_OUT"
}

case_surface_row_missing() {
    mk_repo || { fail "surface-row-missing (no temp repo)"; return; }
    printf 'key\t-\t(HIMMEL)-[0-9]+\tthe key\n' > "$REPO/scripts/lint/ticket-ref-allow.tsv"
    hs "$REPO" --list
    assert_eq "surface-row-missing --list exits 1" 1 "$HS_RC"
    hs "$REPO" --check-keys
    assert_eq "surface-row-missing --check-keys exits 1" 1 "$HS_RC"
}

case_i2_keys() {
    local label body
    mk_repo || { fail "i2 (no temp repo)"; return; }
    hs "$REPO" --check-keys
    assert_eq "i2-control exits 0" 0 "$HS_RC"
    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 2 };'
    hs "$REPO" --check-keys
    assert_eq "i2-live-key exits 0" 0 "$HS_RC"
    reset_cfg
    edit_cfg 'c.rules["landmines-testing/no-flake-masking"][1].allow = { "a/gone.test.ts": 1 };'
    hs "$REPO" --check-keys
    assert_eq "i2-orphan-key exits 1" 1 "$HS_RC"
    assert_has "i2-orphan-key names the path" "orphan allow key landmines-testing/no-flake-masking a/gone.test.ts" "$HS_OUT"
    reset_cfg

    while IFS='|' read -r label body; do
        [ -n "$label" ] || continue
        edit_cfg "$body"
        hs "$REPO" --check-keys
        assert_eq "i2-config-shape $label exits 1" 1 "$HS_RC"
        reset_cfg
    done <<'EOF'
overrides turns a rule off|c.overrides = [{ files: ["**/*"], rules: { "landmines-testing/no-fixed-sleep": "off" } }];
extends|c.extends = ["./other.json"];
ignorePatterns|c.ignorePatterns = ["**/*.test.ts"];
second option|c.rules["landmines-testing/no-fixed-sleep"][1].extra = true;
third array element|c.rules["landmines-testing/no-fixed-sleep"].push({});
string jsPlugins|c.jsPlugins = ["@interfere/landmines/testing"];
extra jsPlugins entry|c.jsPlugins.push({ name: "other", specifier: "other" });
rule off|c.rules["landmines-testing/no-fixed-sleep"] = ["off", { allow: {} }];
rule warn|c.rules["landmines-testing/no-fixed-sleep"][0] = "warn";
extra rule|c.rules["no-console"] = "error";
missing rule|delete c.rules["landmines-testing/no-unsignaled-poll"];
category on|c.categories.correctness = "warn";
options flipped|c.options.respectEslintDisableDirectives = true;
allow count zero|c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 0 };
allow count fractional|c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 1.5 };
EOF

    edit_cfg 'c.jsPlugins = [{ name: "landmines-testing", specifier: "./noop.mjs" }];'
    hs "$REPO" --check-keys
    assert_eq "i2-local-specifier exits 1" 1 "$HS_RC"
    reset_cfg

    mk_repo || { fail "i2-renamed-key (no temp repo)"; return; }
    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 1 };'
    git -C "$REPO" mv a/x.test.mjs a/y.test.mjs
    hs "$REPO" --check-keys
    assert_eq "i2-renamed-key exits 1" 1 "$HS_RC"
    assert_has "i2-renamed-key names the path" "a/x.test.mjs" "$HS_OUT"

    mk_repo || { fail "i2-suffix-twin (no temp repo)"; return; }
    put a/x.test.ts
    put b/a/x.test.ts
    git -C "$REPO" add -A
    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.ts": 1 };'
    hs "$REPO" --check-keys
    assert_eq "i2-suffix-twin exits 1" 1 "$HS_RC"
    assert_has "i2-suffix-twin names both paths" "twin allow key landmines-testing/no-fixed-sleep a/x.test.ts b/a/x.test.ts" "$HS_OUT"
}

SLEEP_LINE='await new Promise((r) => setTimeout(r, 50));'
write_inner() {
    printf 'import { it } from "vitest";\nit("x", async () => {\n  %s\n  %s\n});\n' "$2" "$SLEEP_LINE" > "$REPO/$1"
}
write_top() {
    printf '%s\nimport { it } from "vitest";\nit("x", async () => {\n  %s\n});\n' "$2" "$SLEEP_LINE" > "$REPO/$1"
}
write_tail() {
    printf 'import { it } from "vitest";\nit("x", async () => {\n  %s %s\n});\n' "$SLEEP_LINE" "$2" > "$REPO/$1"
}

dir_row() {
    local id="$1" kind="$2" text="$3" want="$4" f="a/dir-$1.test.ts" rc=0
    case "$kind" in
        inner) write_inner "$f" "$text" ;;
        top) write_top "$f" "$text" ;;
        tail) write_tail "$f" "$text" ;;
    esac
    git -C "$REPO" add "$f"
    hs "$REPO" --check-directives "$f"
    [ "$want" = refuse ] && rc=1
    assert_eq "i7-directive-table $id ($want)" "$rc" "$HS_RC"
    if [ "$want" = refuse ]; then
        assert_has "i7-directive-table $id is refused, not unparsed" "refused directive" "$HS_OUT"
    fi
}

case_i7_directives() {
    mk_repo || { fail "i7 (no temp repo)"; return; }
    link_install "$REPO"
    dir_row 00 inner '' pass
    dir_row 01 inner '// oxlint-disable-next-line landmines-testing/no-fixed-sleep' refuse
    dir_row 02 inner '// oxlint-disable-next-line no-fixed-sleep' refuse
    dir_row 03 inner '// oxlint-disable-next-line landmines-testing/*' refuse
    dir_row 04 inner '// oxlint-disable-next-line ,' refuse
    dir_row 05 inner $'// oxlint-disable-next-line\t-- the child needs a moment' refuse
    dir_row 06 inner '// oxlint-disable-next-line -- the child needs a moment' refuse
    dir_row 07 top $'const base = "http://localhost"; /* oxlint-disable no-console,\n   landmines-testing/no-fixed-sleep */' refuse
    dir_row 08 top $'/* oxlint-disable no-console,\n   landmines-testing/no-fixed-sleep */' refuse
    dir_row 09 inner '// oxlint-disable-next-line no-console -- reason' pass
    dir_row 10 inner '// oxlint-disable-next-line no-console, no-fixed-sleep' refuse
    dir_row 11 inner '/* oxlint-disable-next-line no-console */' pass
    dir_row 12 inner '//oxlint-disable-next-line' refuse
    dir_row 13 inner '// OXLINT-DISABLE-NEXT-LINE' refuse
    dir_row 14 top '/** oxlint-disable */' refuse
    dir_row 15 inner '// eslint-disable-next-line landmines-testing/no-fixed-sleep' refuse
    dir_row 16 top '/* oxlint-disable */' refuse
    dir_row 17 inner '// eslint-disable-next-line no-console' pass
    dir_row 18 inner '// oxlint-disable-next-line  no-console' refuse
    dir_row 19 inner '// oxlint-disable-next-line no-console,' refuse
    dir_row 20 inner '// oxlint-disable-next-line no-console --reason' refuse
    dir_row 21 inner '// oxlint-disable-next-line landmines-testing' refuse
    dir_row 22 tail '// oxlint-disable-line' refuse
    dir_row 23 inner '// oxlint-disable-next-line foo-no-fixed-sleep' refuse
    dir_row 24 inner '// oxlint-disable-next-line foo/bar-no-unsignaled-poll' refuse
    hs "$REPO" --check-directives a/dir-01.test.ts
    assert_has "i7-directive-table refusal names path, line and text" \
        'a/dir-01.test.ts:3: refused directive: "oxlint-disable-next-line landmines-testing/no-fixed-sleep' "$HS_OUT"
    HS_OUT=$(cd "$REPO" && node --input-type=module -e '
import { checkDirectives } from "./scripts/lint/honesty-surface.mjs";
console.log(checkDirectives(process.argv[1]).join("\n"));
' "$REPO/a/dir-01.test.ts" 2>&1 </dev/null)
    assert_has "i7 checkDirectives(absPath) alone finds its own root" 'a/dir-01.test.ts:3: refused directive' "$HS_OUT"

    put a/k1-require.test.js $'const fs = require("node:fs");\nlet a = 0;\na <!-- oxlint-disable\nfs.readFileSync;'
    put a/k1-globals.test.js $'globalThis.x = 1;\nlet a = 0;\na <!-- oxlint-disable'
    put a/k1-control.test.js $'const fs = require("node:fs");\nlet a = 0;\na < !--oxlint - disable'
    put a/k1-two.test.ts '// eslint-disable-next-line no-console -- see oxlint-disable docs'
    put a/real.test.ts '// eslint-disable-next-line @typescript-eslint/no-explicit-any'
    put a/parse-fail.test.ts 'const = ;'
    git -C "$REPO" add -A
    hs "$REPO" --check-directives a/k1-require.test.js
    assert_eq "k1-html-open-require exits 1" 1 "$HS_RC"
    assert_has "k1-html-open-require is refused, not unparsed" "refused directive" "$HS_OUT"
    hs "$REPO" --check-directives a/k1-globals.test.js
    assert_eq "k1-html-open-globals exits 1" 1 "$HS_RC"
    assert_has "k1-html-open-globals is refused, not unparsed" "refused directive" "$HS_OUT"
    hs "$REPO" --check-directives a/k1-control.test.js
    assert_eq "k1-control exits 0" 0 "$HS_RC"
    hs "$REPO" --check-directives a/k1-two.test.ts
    assert_eq "k1-two-in-one exits 1" 1 "$HS_RC"
    assert_has "k1-two-in-one is refused, not unparsed" "refused directive" "$HS_OUT"
    hs "$REPO" --check-directives a/real.test.ts
    assert_eq "i7-real-shapes exits 0" 0 "$HS_RC"
    hs "$REPO" --check-directives a/parse-fail.test.ts
    assert_eq "i7-parse-fail exits 1" 1 "$HS_RC"
    assert_has "i7-parse-fail says parse failed" "parse failed" "$HS_OUT"
    hs "$REPO" --check-directives a/real.test.ts a/x.test.mjs
    assert_eq "i7 several paths, all clean, exit 0" 0 "$HS_RC"
    hs "$REPO" --check-directives
    assert_eq "i7 no paths checks the whole surface and refuses" 1 "$HS_RC"
}

case_i8_triggers() {
    local trig pre p
    mk_repo || { fail "i8 (no temp repo)"; return; }
    if [ -e "$REPO/scripts/lint/landmines/node_modules" ]; then
        fail "i8-triggers precondition: temp repo has no node_modules"
    fi
    hs "$REPO" --triggers
    assert_eq "i8-triggers exits 0 with no node_modules" 0 "$HS_RC"
    trig=$HS_OUT
    case "$trig" in
        *'^'*|*'$'*) fail "i8-triggers has no anchors of its own" ;;
        *) pass "i8-triggers has no anchors of its own" ;;
    esac
    for p in marketplace/plugins/x/VENDORED.md VENDORED.md scripts/lanes/skill-cost.mjs \
        scripts/lint/ticket-ref-allow.tsv scripts/lint/landmines/bun.lock \
        scripts/lint/landmines/.oxlintrc.json scripts/lint/landmines/package.json \
        scripts/lint/landmines/bunfig.toml scripts/lint/check-test-honesty.sh \
        scripts/lint/test-check-test-honesty.sh scripts/lint/honesty-surface.mjs \
        .github/workflows/ci.yml .pre-commit-config.yaml oxlint-suppressions.json a/oxlint-suppressions.json; do
        if printf '%s\n' "$p" | grep -qxE "$trig"; then pass "i8-triggers match: $p"; else fail "i8-triggers match: $p"; fi
    done
    for p in scripts/foo.test.ts xscripts/lanes/skill-cost.mjs.bak scripts/lanes/skill-cost.mjs.bak \
        xVENDORED.md scripts/lint/landmines/node_modules/x/bun.lock README.md; do
        if printf '%s\n' "$p" | grep -qxE "$trig"; then fail "i8-triggers no match: $p"; else pass "i8-triggers no match: $p"; fi
    done
    hs "$REPO" --precommit-files
    assert_eq "i8-precommit-files exits 0 with no node_modules" 0 "$HS_RC"
    pre=$HS_OUT
    for p in scripts/foo.test.ts a/b.tsx a/b.cjs scripts/lanes/skill-cost.mjs marketplace/plugins/x/VENDORED.md; do
        if printf '%s\n' "$p" | grep -qE "$pre"; then pass "i8-precommit-files match: $p"; else fail "i8-precommit-files match: $p"; fi
    done
    for p in README.md a/b.py xscripts/lanes/skill-cost.mjs.bak; do
        if printf '%s\n' "$p" | grep -qE "$pre"; then fail "i8-precommit-files no match: $p"; else pass "i8-precommit-files no match: $p"; fi
    done
    hs "$REPO" --list
    assert_eq "i8 --list exits 0 with no node_modules" 0 "$HS_RC"
    hs "$REPO" --check-keys
    assert_eq "i8 --check-keys exits 0 with no node_modules" 0 "$HS_RC"
}

REAL_NODE=$(command -v node)
GATE_OUT=""
GATE_RC=0

run_gate() {
    local dir="$1" closed="$2" path="$3"
    shift 3
    GATE_OUT=$(
        cd "$dir" || exit 99
        unset OXLINT_FAIL_CLOSED
        if [ "$closed" = 1 ]; then export OXLINT_FAIL_CLOSED=1; fi
        PATH="$path" "$BASH_ABS" scripts/lint/check-test-honesty.sh "$@" 2>&1 </dev/null
    )
    GATE_RC=$?
}

mk_tools() {
    local dir="$1" name src
    shift
    mkdir -p "$dir/tools"
    for name in "$@"; do
        src=$(command -v "$name") || continue
        case "$src" in /*) ln -sf "$src" "$dir/tools/$name" ;; esac
    done
}

BASE_TOOLS=(git sha256sum shasum cat cut mkdir rm mktemp dirname basename sed grep tr head sort uname env)

install_body() {
    printf "PKG='%s'\n" "$PKG"
    cat <<'EOS'
mkdir -p node_modules/.bin
for e in "$PKG"/node_modules/* "$PKG"/node_modules/.[!.]*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  n=${e##*/}
  case "$n" in .bin|.lock-sha256) continue ;; esac
  ln -s "$e" "node_modules/$n"
done
ln -s "$PKG/node_modules/.bin/oxlint" node_modules/.bin/oxlint
EOS
}

node_version_stand_in() {
    stand_in "$1" node "if [ \"\${1:-}\" = --version ]; then echo v$2; exit 0; fi; exec '$REAL_NODE' \"\$@\""
}

edit_pkg() {
    node -e '
const fs = require("node:fs");
const f = process.argv[1];
const p = JSON.parse(fs.readFileSync(f, "utf8"));
'"$1"'
fs.writeFileSync(f, JSON.stringify(p, null, 2) + "\n");
' "$REPO/scripts/lint/landmines/package.json" </dev/null
}

calls_count() {
    if [ -f "$REPO/calls.log" ]; then wc -l < "$REPO/calls.log" | tr -d ' '; else echo 0; fi
}

case_i3_node() {
    mk_repo || { fail "i3-node (no temp repo)"; return; }
    link_install "$REPO"
    mk_tools "$REPO" "${BASE_TOOLS[@]}" bun
    run_gate "$REPO" 0 "$REPO/tools"
    assert_eq "i3-no-node exits 0 locally" 0 "$GATE_RC"
    assert_has "i3-no-node warns" "node not found on PATH" "$GATE_OUT"
    run_gate "$REPO" 1 "$REPO/tools"
    assert_eq "i3-no-node exits 1 under OXLINT_FAIL_CLOSED" 1 "$GATE_RC"

    node_version_stand_in "$REPO" 20.0.0
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "i3-node-v20 exits 1" 1 "$GATE_RC"
    assert_has "i3-node-v20 names the range" "^22.18.0 || >=24.11.0" "$GATE_OUT"
    node_version_stand_in "$REPO" 24.5.0
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "i3-node-v24.5 exits 1" 1 "$GATE_RC"
}

case_node_range_within_engines() {
    local literal out
    literal=$(sed -n "s/^NODE_RANGE='\\(.*\\)'\$/\\1/p" "$SCRIPT_DIR/check-test-honesty.sh" 2>/dev/null | head -n 1)
    if [ "$literal" != '^22.18.0 || >=24.11.0' ]; then
        fail "node-range-within-engines (range literal is '$literal')"
        return
    fi
    out=$(node -e '
const fs = require("node:fs");
const [literal, ...files] = process.argv.slice(1);
const ver = (v) => v.split(".").map(Number);
const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
function parts(range) {
  return range.split("||").map((raw) => {
    const t = raw.trim();
    const caret = /^\^([1-9][0-9]*\.[0-9]+\.[0-9]+)$/.exec(t);
    if (caret) return { caret: true, lo: ver(caret[1]) };
    const ge = /^>=([0-9]+\.[0-9]+\.[0-9]+)$/.exec(t);
    if (ge) return { caret: false, lo: ver(ge[1]) };
    throw new Error("unsupported range form: " + t);
  });
}
const admits = (ps, v) => ps.some((p) => cmp(v, p.lo) >= 0 && (!p.caret || v[0] === p.lo[0]));
try {
  const mine = parts(literal);
  const theirs = files.map((f) => {
    const n = JSON.parse(fs.readFileSync(f, "utf8")).engines;
    if (!n || typeof n.node !== "string") throw new Error("no engines.node in " + f);
    return { f, ps: parts(n.node) };
  });
  const tested = ["22.17.0", "22.18.0", "24.10.0", "24.11.0", "26.0.0"];
  const got = tested.filter((v) => admits(mine, ver(v))).join(",");
  if (got !== "22.18.0,24.11.0,26.0.0") throw new Error("literal admits " + got);
  for (const v of tested) {
    if (!admits(mine, ver(v))) continue;
    for (const t of theirs) if (!admits(t.ps, ver(v))) throw new Error(v + " admitted by the literal, refused by " + t.f);
  }
  process.stdout.write("ok");
} catch (e) { process.stdout.write("bad: " + e.message); }
' "$literal" "$PKG/node_modules/oxlint/package.json" "$PKG/node_modules/@interfere/landmines/package.json" \
        "$PKG/node_modules/@babel/parser/package.json" 2>&1 </dev/null)
    assert_eq "node-range-within-engines" "ok" "$out"
}

case_gate_matches_literal() {
    local v want
    mk_repo || { fail "gate-matches-literal (no temp repo)"; return; }
    link_install "$REPO"
    for v in 22.17.0 22.18.0 24.10.0 24.11.0 26.0.0; do
        case "$v" in 22.18.0|24.11.0|26.0.0) want=0 ;; *) want=1 ;; esac
        node_version_stand_in "$REPO" "$v"
        run_gate "$REPO" 0 "$REPO/bin:$PATH"
        assert_eq "i3-node-gate-matches-literal $v" "$want" "$GATE_RC"
    done
}

case_i3_install() {
    local want
    mk_repo || { fail "i3-install (no temp repo)"; return; }
    mk_tools "$REPO" "${BASE_TOOLS[@]}" node
    run_gate "$REPO" 0 "$REPO/tools"
    assert_eq "i3-no-bun-needs-install exits 0 locally" 0 "$GATE_RC"
    assert_has "i3-no-bun-needs-install warns" "bun not found on PATH" "$GATE_OUT"
    run_gate "$REPO" 1 "$REPO/tools"
    assert_eq "i3-no-bun-needs-install exits 1 under OXLINT_FAIL_CLOSED" 1 "$GATE_RC"

    mk_repo || { fail "i3-no-bun-installed (no temp repo)"; return; }
    link_install "$REPO"
    mk_tools "$REPO" "${BASE_TOOLS[@]}" node
    run_gate "$REPO" 1 "$REPO/tools"
    assert_eq "i3-no-bun-installed passes under OXLINT_FAIL_CLOSED" 0 "$GATE_RC"

    mk_repo || { fail "i3-marker-written (no temp repo)"; return; }
    stand_in "$REPO" bun "$(install_body)" record
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "i3-marker-written first run exits 0" 0 "$GATE_RC"
    assert_eq "i3-marker-written bun called once with the frozen install" "install --frozen-lockfile" "$(cat "$REPO/calls.log" 2>/dev/null)"
    want=$(sha256_of "$REPO/scripts/lint/landmines/bun.lock")
    assert_eq "i3-marker-written marker is the lock sha" "$want" "$(cat "$REPO/scripts/lint/landmines/node_modules/.lock-sha256" 2>/dev/null)"
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "i3-marker-written second run exits 0" 0 "$GATE_RC"
    assert_eq "i3-marker-written second run does not call bun" 1 "$(calls_count)"

    mk_repo || { fail "i3-reinstall (no temp repo)"; return; }
    link_install "$REPO"
    printf '\n' >> "$REPO/scripts/lint/landmines/bun.lock"
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "i3-reinstall exits 0" 0 "$GATE_RC"
    assert_eq "i3-reinstall calls bun" "install --frozen-lockfile" "$(cat "$REPO/calls.log" 2>/dev/null)"
    want=$(sha256_of "$REPO/scripts/lint/landmines/bun.lock")
    assert_eq "i3-reinstall marker follows the lock" "$want" "$(cat "$REPO/scripts/lint/landmines/node_modules/.lock-sha256" 2>/dev/null)"

    mk_repo || { fail "i3-install-fails (no temp repo)"; return; }
    stand_in "$REPO" bun 'exit 1' record
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "i3-install-fails exits 1" 1 "$GATE_RC"
    if [ -e "$REPO/scripts/lint/landmines/node_modules/.lock-sha256" ]; then
        fail "i3-install-fails writes no marker"
    else
        pass "i3-install-fails writes no marker"
    fi
}

case_i3_version_mismatch() {
    local dep from to
    while read -r dep from to; do
        mk_repo || { fail "i3-version-mismatch-$dep (no temp repo)"; return; }
        link_install "$REPO"
        sed "s/\"$from\"/\"$to\"/" "$REPO/scripts/lint/landmines/package.json" > "$REPO/pkg.tmp"
        mv "$REPO/pkg.tmp" "$REPO/scripts/lint/landmines/package.json"
        run_gate "$REPO" 0 "$PATH"
        assert_eq "i3-version-mismatch-$dep exits 1" 1 "$GATE_RC"
        assert_has "i3-version-mismatch-$dep prints a version-mismatch line" "version mismatch: $dep" "$GATE_OUT"
    done <<'EOF'
oxlint 1.94.0 1.94.1
@interfere/landmines 0.1.1 0.1.2
@babel/parser 8.1.3 8.1.4
EOF
}

case_package_shape_gate() {
    mk_repo || { fail "package-shape-gate (no temp repo)"; return; }
    link_install "$REPO"
    run_gate "$REPO" 1 "$PATH"
    assert_eq "package-shape-gate control exits 0" 0 "$GATE_RC"

    printf '%s\n' 'export default {};' > "$REPO/scripts/lint/landmines/noop.mjs"
    edit_pkg 'p.name = "@interfere/landmines"; p.exports = { "./testing": "./noop.mjs" };'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "package-shape-gate self-reference exits 1" 1 "$GATE_RC"
    assert_has "package-shape-gate self-reference is refused at the shape line" "lint package.json shape" "$GATE_OUT"
    edit_pkg 'delete p.name; delete p.exports; p.dependencies.extra = "1.0.0";'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "package-shape-gate extra dependency exits 1" 1 "$GATE_RC"
    assert_has "package-shape-gate extra dependency is refused at the shape line" "lint package.json shape" "$GATE_OUT"
    edit_pkg 'delete p.dependencies.extra; p.dependencies.oxlint = "^1.94.0";'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "package-shape-gate inexact pin exits 1" 1 "$GATE_RC"
    assert_has "package-shape-gate inexact pin is refused at the shape line" "lint package.json shape" "$GATE_OUT"
    git -C "$REPO" checkout -q -- scripts/lint/landmines/package.json
    edit_pkg 'p.name = "x";'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "package-shape-gate extra key exits 1" 1 "$GATE_RC"
    assert_has "package-shape-gate extra key is refused at the shape line" "lint package.json shape" "$GATE_OUT"
}

fake_plugin() {
    local d="$REPO/scripts/lint/landmines/node_modules/@interfere/landmines"
    if [ -L "$REPO/scripts/lint/landmines/node_modules/@interfere" ]; then rm -f -- "$REPO/scripts/lint/landmines/node_modules/@interfere"; fi
    mkdir -p "$d/dist"
    ln -sfn "$PKG/node_modules/@interfere/landmines/dist/testing.mjs" "$d/dist/testing.mjs"
    printf '%s\n' 'export default {};' > "$d/dist/noop.mjs"
    printf '{"name":"@interfere/landmines","version":"0.1.1","type":"module","exports":{"./testing":%s}}\n' "$1" > "$d/package.json"
}

case_resolved_specifier() {
    mk_repo || { fail "resolved-specifier (no temp repo)"; return; }
    link_install "$REPO"
    fake_plugin '"./dist/testing.mjs"'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "resolved-specifier fake-plugin control exits 0" 0 "$GATE_RC"

    fake_plugin '"./dist/noop.mjs"'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "resolved-specifier exits 1" 1 "$GATE_RC"
    assert_has "resolved-specifier is refused by the resolve check" "resolves to" "$GATE_OUT"
    case "$GATE_OUT" in
        *"version mismatch"*) fail "resolved-specifier is not a version mismatch" ;;
        *) pass "resolved-specifier is not a version mismatch" ;;
    esac

    fake_plugin '{"import":"./dist/noop.mjs","default":"./dist/testing.mjs"}'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "esm-conditional-exports exits 1" 1 "$GATE_RC"
    assert_has "esm-conditional-exports names the import resolution" "(import)" "$GATE_OUT"

    fake_plugin '{"require":"./dist/noop.mjs","default":"./dist/testing.mjs"}'
    run_gate "$REPO" 0 "$PATH"
    assert_eq "cjs-conditional-exports exits 1" 1 "$GATE_RC"
    assert_has "cjs-conditional-exports names the require resolution" "(require)" "$GATE_OUT"
}

case_tracked_node_modules() {
    mk_repo || { fail "tracked-node-modules (no temp repo)"; return; }
    link_install "$REPO"
    printf '%s\n' 'x' > "$REPO/scripts/lint/landmines/node_modules/tracked.mjs"
    git -C "$REPO" add -f scripts/lint/landmines/node_modules/tracked.mjs
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "tracked-node-modules exits 1" 1 "$GATE_RC"
    assert_has "tracked-node-modules names the cause" "tracked files under scripts/lint/landmines/node_modules/" "$GATE_OUT"
    assert_eq "tracked-node-modules refuses before any install" 0 "$(calls_count)"
}

case_suppressions_file() {
    gate_repo $'import { it } from "vitest";\nit("x", async () => {\n  await new Promise((r) => setTimeout(r, 50));\n});' || { fail "suppressions-file (no temp repo)"; return; }
    (cd "$REPO" && scripts/lint/landmines/node_modules/.bin/oxlint -c scripts/lint/landmines/.oxlintrc.json --suppress-all a/x.test.mjs >/dev/null 2>&1 </dev/null)
    if [ -f "$REPO/oxlint-suppressions.json" ]; then
        pass "suppressions-file real oxlint --suppress-all wrote the file"
    else
        fail "suppressions-file real oxlint --suppress-all wrote the file"
    fi
    run_gate "$REPO" 1 "$PATH"
    assert_eq "suppressions-file at the root exits 1" 1 "$GATE_RC"
    assert_has "suppressions-file at the root names the file" "oxlint-suppressions.json at the repo root" "$GATE_OUT"
    assert_lacks "suppressions-file at the root has no success line" "$CLEAN_PREFIX" "$GATE_OUT"
    run_gate_split "$REPO" "$PATH" --seed
    assert_eq "suppressions-file at the root refuses --seed" 1 "$GATE_RC"
    assert_eq "suppressions-file at the root --seed prints no maps" "" "$GATE_STDOUT"

    gate_repo $'import { it } from "vitest";\nit("ok", () => {});' || { fail "suppressions-file (no temp repo)"; return; }
    put sub/oxlint-suppressions.json '{}'
    git -C "$REPO" add sub/oxlint-suppressions.json
    run_gate "$REPO" 1 "$PATH"
    assert_eq "suppressions-file tracked in a subdirectory exits 1" 1 "$GATE_RC"
    assert_has "suppressions-file tracked in a subdirectory names the path" "sub/oxlint-suppressions.json" "$GATE_OUT"
    git -C "$REPO" rm -q --cached sub/oxlint-suppressions.json
    run_gate "$REPO" 1 "$PATH"
    assert_eq "suppressions-file control: the same subdirectory file untracked passes" 0 "$GATE_RC"
}

case_node_modules_symlink() {
    local nm
    mk_repo || { fail "node-modules-symlink (no temp repo)"; return; }
    nm="$REPO/scripts/lint/landmines/node_modules"
    link_install "$REPO"
    stand_in "$REPO" bun 'exit 0' record

    mv "$nm" "$REPO/fake-nm"
    ln -s ../../../fake-nm "$nm"
    git -C "$REPO" add -f scripts/lint/landmines/node_modules
    rm -f -- "$nm"
    cp -R "$REPO/fake-nm" "$nm"
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "tracked-node-modules-symlink (index only) exits 1" 1 "$GATE_RC"
    assert_has "tracked-node-modules-symlink (index only) names the cause" "tracked files under scripts/lint/landmines/node_modules/" "$GATE_OUT"

    git -C "$REPO" rm -q --cached scripts/lint/landmines/node_modules
    rm -rf -- "$nm"
    ln -s ../../../fake-nm "$nm"
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "node-modules-symlink (on disk) exits 1" 1 "$GATE_RC"
    assert_has "node-modules-symlink (on disk) names the cause" "is a symlink" "$GATE_OUT"
    assert_eq "tracked-node-modules-symlink refuses before any install" 0 "$(calls_count)"
}

case_package_dir_symlink() {
    mk_repo || { fail "package-dir-symlink (no temp repo)"; return; }
    link_install "$REPO"
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "package-dir-symlink control exits 0" 0 "$GATE_RC"

    mk_repo || { fail "package-dir-symlink (no temp repo)"; return; }
    git -C "$REPO" mv scripts/lint/landmines scripts/lint/lm-real
    ln -s lm-real "$REPO/scripts/lint/landmines"
    git -C "$REPO" add scripts/lint/landmines
    git -C "$REPO" commit -q -m "symlinked package dir"
    link_install "$REPO"
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "package-dir-symlink exits 1" 1 "$GATE_RC"
    assert_has "package-dir-symlink names the cause" "reached through a symlink" "$GATE_OUT"
    assert_eq "package-dir-symlink refuses before any install" 0 "$(calls_count)"

    mk_repo || { fail "package-dir-symlink-parent (no temp repo)"; return; }
    git -C "$REPO" mv scripts/lint scripts/lint-real
    ln -s lint-real "$REPO/scripts/lint"
    git -C "$REPO" add scripts/lint
    git -C "$REPO" commit -q -m "symlinked lint dir"
    link_install "$REPO"
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "package-dir-symlink-parent exits 1" 1 "$GATE_RC"
    assert_has "package-dir-symlink-parent names the cause" "reached through a symlink" "$GATE_OUT"
    assert_eq "package-dir-symlink-parent refuses before any install" 0 "$(calls_count)"
}

case_gate_early_exits() {
    mk_repo || { fail "gate-early-exits (no temp repo)"; return; }
    stand_in "$REPO" bun 'exit 0' record
    run_gate "$REPO" 1 "$REPO/bin:$PATH" --files README.md
    assert_eq "empty-list-no-install exits 0" 0 "$GATE_RC"
    assert_has "empty-list-no-install says so" "nothing to lint" "$GATE_OUT"
    assert_eq "empty-list-no-install leaves calls.log empty" 0 "$(calls_count)"
    run_gate "$REPO" 1 "$REPO/bin:$PATH" --files
    assert_eq "empty-list bare --files exits 0" 0 "$GATE_RC"
    assert_has "empty-list bare --files says so" "nothing to lint" "$GATE_OUT"
    assert_eq "empty-list bare --files calls no bun" 0 "$(calls_count)"

    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/gone.test.ts": 1 };'
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "keys-refused exits 1" 1 "$GATE_RC"
    assert_has "keys-refused names the key" "orphan allow key" "$GATE_OUT"
    assert_eq "keys-refused calls no bun" 0 "$(calls_count)"
    reset_cfg

    run_gate "$REPO" 0 "$REPO/bin:$PATH" --bogus
    assert_eq "usage error exits 2" 2 "$GATE_RC"
}

CLEAN_PREFIX='test-honesty: clean ('
HINT_LINE='the entry above is in scripts/lint/landmines/.oxlintrc.json, not .oxlintrc.jsonc'

assert_lacks() {
    local label="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$label"; echo "     unexpected: $needle"; echo "     in: $hay" ;;
        *) pass "$label" ;;
    esac
}

gate_repo() {
    mk_repo || return 1
    link_install "$REPO"
    printf '%s\n' "$1" > "$REPO/a/x.test.mjs"
}

run_gate_split() {
    local dir="$1" path="$2"
    shift 2
    GATE_STDOUT=$(
        cd "$dir" || exit 99
        unset OXLINT_FAIL_CLOSED
        PATH="$path" "$BASH_ABS" scripts/lint/check-test-honesty.sh "$@" 2>"$dir/gate.stderr" </dev/null
    )
    GATE_RC=$?
    GATE_STDERR=$(cat "$dir/gate.stderr")
}

oxlint_stub() {
    printf '%s\n' "$1" > "$REPO/canned.out"
    stand_in "$REPO" oxlint "cat '$REPO/canned.out'; exit $2"
}

node_recorder() {
    stand_in "$REPO" node "exec '$REAL_NODE' \"\$@\"" record
}

json_equal() {
    node -e '
const assert = require("node:assert");
try { assert.deepStrictEqual(JSON.parse(process.argv[1]), JSON.parse(process.argv[2])); process.stdout.write("ok"); }
catch (e) { process.stdout.write("bad: " + e.message); }
' "$1" "$2" </dev/null
}

line_of() {
    grep -n -- "$1" "$REPO/calls.log" 2>/dev/null | head -n 1 | cut -d: -f1
}

directive_calls() {
    grep -c '^scripts/lint/honesty-surface.mjs --check-directives' "$REPO/calls.log" 2>/dev/null || true
}

seed_files_left() {
    local f n=0
    for f in "$REPO"/scripts/lint/landmines/.oxlintrc.seed.*.json; do
        if [ -e "$f" ]; then n=$((n + 1)); fi
    done
    echo "$n"
}

case_i1_rules() {
    gate_repo $'import { it } from "vitest";\nit("x", async () => {\n  await new Promise((r) => setTimeout(r, 50));\n});' || { fail "i1 (no temp repo)"; return; }
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i1-inline-sleep exits 1" 1 "$GATE_RC"
    assert_has "i1-inline-sleep prints the finding" "a/x.test.mjs:3:3 landmines-testing(no-fixed-sleep) " "$GATE_OUT"
    assert_lacks "i1-inline-sleep has no stale hint" "$HINT_LINE" "$GATE_OUT"
    assert_lacks "i1-inline-sleep has no success line" "$CLEAN_PREFIX" "$GATE_OUT"

    gate_repo $'import { test } from "bun:test";\ntest("x", async () => {\n  await Bun.sleep(5);\n});' || { fail "i1 (no temp repo)"; return; }
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i1-bun-sleep exits 1" 1 "$GATE_RC"
    assert_has "i1-bun-sleep prints the finding" "landmines-testing(no-fixed-sleep)" "$GATE_OUT"

    gate_repo $'import { it } from "vitest";\nit("x", async () => {}, 5000);' || { fail "i1 (no temp repo)"; return; }
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i1-numeric-timeout exits 1" 1 "$GATE_RC"
    assert_has "i1-numeric-timeout prints the finding" "landmines-testing(no-flake-masking)" "$GATE_OUT"

    gate_repo $'import { it, expect, vi } from "vitest";\nit("x", async () => {\n  const fn = vi.fn();\n  await expect.poll(() => fn.mock.calls.length).toBe(1);\n});' || { fail "i1 (no temp repo)"; return; }
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i1-poll-spy exits 1" 1 "$GATE_RC"
    assert_has "i1-poll-spy prints the finding" "landmines-testing(no-unsignaled-poll)" "$GATE_OUT"

    gate_repo $'import { it } from "vitest";\nit("x", async () => {\n  await new Promise((r) => setTimeout(r, 50));\n});' || { fail "i1 (no temp repo)"; return; }
    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 1 };'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i1-at-allowance exits 0" 0 "$GATE_RC"
    assert_eq "i1-at-allowance prints only the success line" "${CLEAN_PREFIX}1 files)" "$GATE_OUT"
}

case_i2_stale_and_count() {
    local after
    gate_repo $'import { it } from "vitest";\nit("x", async () => {\n  await new Promise((r) => setTimeout(r, 50));\n});' || { fail "i2 (no temp repo)"; return; }
    edit_cfg 'c.rules["landmines-testing/no-fixed-sleep"][1].allow = { "a/x.test.mjs": 2 };'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i2-stale exits 1" 1 "$GATE_RC"
    assert_has "i2-stale prints the plugin's line" "This file now has 1 fixed sleeps" "$GATE_OUT"
    after=$(printf '%s\n' "$GATE_OUT" | grep -A1 'This file now has' | sed -n '2p')
    assert_eq "i2-stale prints the config-path line right after" "$HINT_LINE" "$after"
    assert_lacks "i2-stale has no success line" "$CLEAN_PREFIX" "$GATE_OUT"

    gate_repo $'import { it } from "vitest";\nit("ok", () => {});' || { fail "i2-file-count (no temp repo)"; return; }
    oxlint_stub '{"diagnostics":[],"number_of_files":1}' 0
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i2-file-count control exits 0" 0 "$GATE_RC"
    oxlint_stub '{"diagnostics":[],"number_of_files":0}' 0
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i2-file-count exits 1" 1 "$GATE_RC"
    assert_has "i2-file-count says unevaluated" "unevaluated" "$GATE_OUT"
    assert_lacks "i2-file-count has no success line" "$CLEAN_PREFIX" "$GATE_OUT"

    gate_repo $'import { it } from "vitest";\nit("ok", () => {});' || { fail "i3-config-shape-through-gate (no temp repo)"; return; }
    stand_in "$REPO" oxlint 'exit 0' record
    edit_cfg 'c.overrides = [{ files: ["**/*"], rules: { "landmines-testing/no-fixed-sleep": "off" } }];'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i3-config-shape-through-gate exits 1" 1 "$GATE_RC"
    assert_has "i3-config-shape-through-gate names the config" "config shape or allow keys refused" "$GATE_OUT"
    assert_eq "i3-config-shape-through-gate never runs oxlint" 0 "$(calls_count)"
}

case_i3_unevaluated() {
    local diag label json rc
    diag='{"message":"m","code":"landmines-testing(no-fixed-sleep)","severity":"error","filename":"a/x.test.mjs","labels":[{"span":{"offset":0,"length":1,"line":1,"column":1}}]}'

    gate_repo $'import { it } from "vitest";\nit("ok", () => {});' || { fail "i3-unevaluated (no temp repo)"; return; }
    oxlint_stub '{"diagnostics":[],"number_of_files":1}' 0
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i3-unevaluated control (clean stand-in) exits 0" 0 "$GATE_RC"
    assert_eq "i3-unevaluated control prints the success line" "${CLEAN_PREFIX}1 files)" "$GATE_OUT"
    oxlint_stub "{\"diagnostics\":[$diag],\"number_of_files\":1}" 1
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i3-unevaluated control (findings stand-in) exits 1" 1 "$GATE_RC"
    assert_has "i3-unevaluated control prints the finding" "a/x.test.mjs:1:1 landmines-testing(no-fixed-sleep) m" "$GATE_OUT"
    assert_lacks "i3-unevaluated control is not unevaluated" "unevaluated" "$GATE_OUT"

    while IFS='|' read -r label json rc; do
        [ -n "$label" ] || continue
        oxlint_stub "$json" "$rc"
        run_gate "$REPO" 1 "$PATH"
        assert_eq "$label exits 1" 1 "$GATE_RC"
        assert_has "$label says unevaluated" "unevaluated" "$GATE_OUT"
        assert_lacks "$label has no success line" "$CLEAN_PREFIX" "$GATE_OUT"
    done <<EOF
i3-runner-exit2|{"diagnostics":[],"number_of_files":1}|2
i3-runner-exit3-with-diagnostics|{"diagnostics":[$diag],"number_of_files":1}|3
i3-non-json|oxlint: something went wrong|0
i3-empty-object|{}|0
i3-exit1-empty-diagnostics|{"diagnostics":[],"number_of_files":1}|1
i3-exit0-with-diagnostics|{"diagnostics":[$diag],"number_of_files":1}|0
i3-json-array|[]|0
i3-diagnostics-not-array|{"diagnostics":{},"number_of_files":1}|0
i3-file-count-string|{"diagnostics":[],"number_of_files":"1"}|0
i3-file-count-too-many|{"diagnostics":[],"number_of_files":2}|0
i3-diagnostic-without-line|{"diagnostics":[{"message":"m","code":"landmines-testing(no-fixed-sleep)","filename":"a/x.test.mjs","labels":[]}],"number_of_files":1}|1
i3-diagnostic-without-code|{"diagnostics":[{"message":"m","filename":"a/x.test.mjs","labels":[{"span":{"line":1,"column":1}}]}],"number_of_files":1}|1
i3-diagnostic-without-file|{"diagnostics":[{"message":"m","code":"landmines-testing(no-fixed-sleep)","labels":[{"span":{"line":1,"column":1}}]}],"number_of_files":1}|1
EOF

    rm -f -- "$REPO/scripts/lint/landmines/node_modules/.bin/oxlint"
    run_gate "$REPO" 1 "$PATH"
    assert_eq "i3-runner-missing exits 1" 1 "$GATE_RC"
    assert_has "i3-runner-missing says unevaluated" "unevaluated" "$GATE_OUT"
}

case_large_findings_whole() {
    local n
    gate_repo $'import { it } from "vitest";\nit("ok", () => {});' || { fail "large-findings-whole (no temp repo)"; return; }
    node -e '
const n = 3000;
const diagnostics = Array.from({ length: n }, (_, i) => ({
  message: "m".repeat(80), code: "landmines-testing(no-fixed-sleep)", severity: "error",
  filename: "a/x.test.mjs", labels: [{ span: { offset: 0, length: 1, line: i + 1, column: 1 } }],
}));
process.stdout.write(JSON.stringify({ diagnostics, number_of_files: 1 }));
' > "$REPO/canned.out" </dev/null
    stand_in "$REPO" oxlint "cat '$REPO/canned.out'; exit 1"
    run_gate "$REPO" 1 "$PATH"
    assert_eq "large-findings-whole exits 1" 1 "$GATE_RC"
    n=$(printf '%s\n' "$GATE_OUT" | grep -c '^a/x\.test\.mjs:[0-9]*:1 landmines-testing(no-fixed-sleep) m')
    assert_eq "large-findings-whole prints every finding" 3000 "$n"
    assert_has "large-findings-whole prints the last finding" "a/x.test.mjs:3000:1 " "$GATE_OUT"
}

case_clean_success_line() {
    gate_repo $'import { it } from "vitest";\nit("a", () => {});' || { fail "clean-success-line (no temp repo)"; return; }
    put a/y.test.mjs 'import { it } from "vitest"; it("b", () => {});'
    put a/z.test.mjs 'import { it } from "vitest"; it("c", () => {});'
    git -C "$REPO" add a/y.test.mjs a/z.test.mjs
    run_gate "$REPO" 1 "$PATH"
    assert_eq "clean-success-line full surface exits 0" 0 "$GATE_RC"
    assert_eq "clean-success-line is the one fixed line with the evaluated count" "${CLEAN_PREFIX}3 files)" "$GATE_OUT"
    run_gate "$REPO" 1 "$PATH" --files a/y.test.mjs a/z.test.mjs README.md
    assert_eq "clean-success-line --files exits 0" 0 "$GATE_RC"
    assert_eq "clean-success-line --files counts the narrowed list" "${CLEAN_PREFIX}2 files)" "$GATE_OUT"
    run_gate "$REPO" 1 "$PATH" --files README.md
    assert_eq "clean-success-line empty list keeps its own line" "check-test-honesty: nothing to lint" "$GATE_OUT"

    GATE_OUT=$(cd "$REPO/a" && OXLINT_FAIL_CLOSED=1 "$BASH_ABS" ../scripts/lint/check-test-honesty.sh --files y.test.mjs ./z.test.mjs gone.test.mjs ../README.md 2>&1 </dev/null)
    GATE_RC=$?
    assert_eq "subdir-relative --files exits 0" 0 "$GATE_RC"
    assert_eq "subdir-relative --files counts the files under the subdirectory" "${CLEAN_PREFIX}2 files)" "$GATE_OUT"
    GATE_OUT=$(cd "$REPO/a" && OXLINT_FAIL_CLOSED=1 "$BASH_ABS" ../scripts/lint/check-test-honesty.sh --files "$REPO/a/y.test.mjs" ../a/x.test.mjs 2>&1 </dev/null)
    assert_eq "subdir --files takes absolute and parent-relative paths" "${CLEAN_PREFIX}2 files)" "$GATE_OUT"

    printf '%s\n' 'import { it } from "vitest"; it("s", async () => { await Bun.sleep(5); });' > "$REPO/a/y.test.mjs"
    run_gate "$REPO" 1 "$PATH"
    assert_eq "clean-success-line absent on findings: exits 1" 1 "$GATE_RC"
    assert_lacks "clean-success-line absent on findings" "$CLEAN_PREFIX" "$GATE_OUT"

    stand_in "$REPO" oxlint 'exit 2'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "clean-success-line absent on unevaluated: exits 1" 1 "$GATE_RC"
    assert_lacks "clean-success-line absent on unevaluated" "$CLEAN_PREFIX" "$GATE_OUT"
}

case_i3_step_order() {
    local inst dir
    mk_repo || { fail "i3-install-before-directives (no temp repo)"; return; }
    node_recorder
    stand_in "$REPO" bun "$(install_body)" record
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "i3-install-before-directives exits 0" 0 "$GATE_RC"
    inst=$(line_of '^install --frozen-lockfile$')
    dir=$(line_of '^scripts/lint/honesty-surface.mjs --check-directives')
    if [ -n "$inst" ] && [ -n "$dir" ] && [ "$inst" -lt "$dir" ]; then
        pass "i3-install-before-directives bun install is logged before the directive check"
    else
        fail "i3-install-before-directives (install line '$inst', directive line '$dir')"
    fi

    mk_repo || { fail "directives-run-on-clean (no temp repo)"; return; }
    link_install "$REPO"
    node_recorder
    run_gate "$REPO" 1 "$REPO/bin:$PATH"
    assert_eq "directives-run-on-clean exits 0" 0 "$GATE_RC"
    assert_eq "directives-run-on-clean logs exactly one directive check" 1 "$(directive_calls)"

    mk_repo || { fail "i3-version-mismatch-no-directives (no temp repo)"; return; }
    link_install "$REPO"
    node_recorder
    sed 's/"1.94.0"/"1.94.1"/' "$REPO/scripts/lint/landmines/package.json" > "$REPO/pkg.tmp"
    mv "$REPO/pkg.tmp" "$REPO/scripts/lint/landmines/package.json"
    run_gate "$REPO" 0 "$REPO/bin:$PATH"
    assert_eq "i3-version-mismatch-no-directives exits 1" 1 "$GATE_RC"
    assert_eq "i3-version-mismatch-no-directives logs no directive check" 0 "$(directive_calls)"
    assert_eq "i3-version-mismatch-no-directives recorder is live (the key check was logged)" 1 \
        "$(grep -c '^scripts/lint/honesty-surface.mjs --check-keys' "$REPO/calls.log")"
}

i7_form() {
    case "$1" in
        01) FORM_KIND=inner; FORM_TEXT='// oxlint-disable-next-line landmines-testing/no-fixed-sleep' ;;
        04) FORM_KIND=inner; FORM_TEXT='// oxlint-disable-next-line ,' ;;
        05) FORM_KIND=inner; FORM_TEXT=$'// oxlint-disable-next-line\t-- the child needs a moment' ;;
        06) FORM_KIND=inner; FORM_TEXT='// oxlint-disable-next-line -- the child needs a moment' ;;
        07) FORM_KIND=top; FORM_TEXT=$'const base = "http://localhost"; /* oxlint-disable no-console,\n   landmines-testing/no-fixed-sleep */' ;;
        08) FORM_KIND=top; FORM_TEXT=$'/* oxlint-disable no-console,\n   landmines-testing/no-fixed-sleep */' ;;
        12) FORM_KIND=inner; FORM_TEXT='//oxlint-disable-next-line' ;;
        16) FORM_KIND=top; FORM_TEXT='/* oxlint-disable */' ;;
        22) FORM_KIND='tail'; FORM_TEXT='// oxlint-disable-line' ;;
    esac
}

case_i7_through_gate() {
    local id f
    mk_repo || { fail "i7-through-gate (no temp repo)"; return; }
    link_install "$REPO"
    write_inner a/dir-00.test.ts ''
    git -C "$REPO" add a/dir-00.test.ts
    run_gate "$REPO" 1 "$PATH" --files a/dir-00.test.ts
    assert_eq "i7-through-gate control (no directive) exits 1" 1 "$GATE_RC"
    assert_has "i7-through-gate control reaches oxlint and finds the sleep" "landmines-testing(no-fixed-sleep)" "$GATE_OUT"
    assert_lacks "i7-through-gate control is not a directive refusal" "refused directive" "$GATE_OUT"
    for id in 01 04 05 06 07 08 12 16 22; do
        i7_form "$id"
        f="a/dir-$id.test.ts"
        case "$FORM_KIND" in
            inner) write_inner "$f" "$FORM_TEXT" ;;
            top) write_top "$f" "$FORM_TEXT" ;;
            tail) write_tail "$f" "$FORM_TEXT" ;;
        esac
        git -C "$REPO" add "$f"
        run_gate "$REPO" 1 "$PATH" --files "$f"
        assert_eq "i7-through-gate $id exits 1" 1 "$GATE_RC"
        assert_has "i7-through-gate $id prints a refused directive line" "$f:" "$GATE_OUT"
        assert_has "i7-through-gate $id is a directive refusal" "refused directive" "$GATE_OUT"
        assert_lacks "i7-through-gate $id has no success line" "$CLEAN_PREFIX" "$GATE_OUT"
    done
}

case_seed() {
    local before maps expect
    gate_repo $'import { it } from "vitest";\nit("a", async () => {\n  await new Promise((r) => setTimeout(r, 50));\n  await Bun.sleep(5);\n});' || { fail "seed (no temp repo)"; return; }
    put a/t.test.mjs $'import { it } from "vitest";\nit("t", async () => {}, 5000);\nit("r", { retry: 2 }, () => {});'
    put a/p.test.mjs $'import { it, expect, vi } from "vitest";\nit("p", async () => {\n  const fn = vi.fn();\n  await expect.poll(() => fn.mock.calls.length).toBe(1);\n});'
    put a/r.test.mjs $'import { it } from "vitest";\nit("r", { retry: 3 }, () => {});'
    git -C "$REPO" add a/t.test.mjs a/p.test.mjs a/r.test.mjs
    before=$(sha256_of "$REPO/scripts/lint/landmines/.oxlintrc.json")
    run_gate_split "$REPO" "$PATH" --seed
    assert_eq "seed-maps exits 0" 0 "$GATE_RC"
    expect='{"landmines-testing/no-fixed-sleep":{"a/x.test.mjs":2},"landmines-testing/no-flake-masking":{"a/t.test.mjs":1},"landmines-testing/no-unsignaled-poll":{"a/p.test.mjs":1}}'
    assert_eq "seed-maps prints exactly the sleep, timeout and poll counts" "ok" "$(json_equal "$GATE_STDOUT" "$expect")"
    assert_eq "seed-maps leaves no stderr noise on a clean seed" "" "$GATE_STDERR"
    assert_eq "seed-no-residue tracked config is byte-identical" "$before" "$(sha256_of "$REPO/scripts/lint/landmines/.oxlintrc.json")"
    assert_eq "seed-no-residue no seed config is left" 0 "$(seed_files_left)"
    assert_eq "seed-no-residue git sees no change to the config" "" "$(git -C "$REPO" status --porcelain -- scripts/lint/landmines/.oxlintrc.json)"

    printf '%s\n' "$GATE_STDOUT" > "$REPO/seed.json"
    maps="$REPO/seed.json"
    edit_cfg 'const m = JSON.parse(require("node:fs").readFileSync("'"$maps"'", "utf8")); for (const [k, v] of Object.entries(m)) c.rules[k][1].allow = v;'
    run_gate "$REPO" 1 "$PATH"
    assert_eq "seed-roundtrip gate run with the seeded config exits 1 only for the retry findings" 1 "$GATE_RC"
    assert_has "seed-roundtrip still reports a retry (never counted)" "Do not retry tests" "$GATE_OUT"
    assert_lacks "seed-roundtrip reports no sleep, timeout or poll" "This file now has" "$GATE_OUT"
    assert_lacks "seed-roundtrip reports no unallowed sleep" "Replace this fixed sleep" "$GATE_OUT"

    stand_in "$REPO" oxlint 'exit 2'
    run_gate_split "$REPO" "$PATH" --seed
    assert_eq "seed-unevaluated exits 1" 1 "$GATE_RC"
    assert_eq "seed-unevaluated prints no maps" "" "$GATE_STDOUT"
    assert_eq "seed-unevaluated leaves no seed config" 0 "$(seed_files_left)"

    mk_repo || { fail "seed-excludes (no temp repo)"; return; }
    link_install "$REPO"
    cat > "$REPO/canned.out" <<'EOF'
{"diagnostics":[
{"message":"Replace this fixed sleep with a signal: await the operation.","code":"landmines-testing(no-fixed-sleep)","filename":"a/x.test.mjs","labels":[{"span":{"line":3,"column":3}}]},
{"message":"This file now has 1 fixed sleeps; lower its no-fixed-sleep allowlist entry for a/x.test.mjs in .oxlintrc.jsonc to 1, or remove the entry at 0.","code":"landmines-testing(no-fixed-sleep)","filename":"a/x.test.mjs","labels":[{"span":{"line":1,"column":1}}]},
{"message":"Do not retry tests. A test that passes on rerun is a flake.","code":"landmines-testing(no-flake-masking)","filename":"a/x.test.mjs","labels":[{"span":{"line":4,"column":3}}]},
{"message":"Do not raise a test's timeout. Wait on the event.","code":"landmines-testing(no-flake-masking)","filename":"a/x.test.mjs","labels":[{"span":{"line":5,"column":3}}]},
{"message":"This file now has 0 test timeout bumps; lower it.","code":"landmines-testing(no-flake-masking)","filename":"a/x.test.mjs","labels":[{"span":{"line":1,"column":1}}]},
{"message":"Await a signal instead of polling a request recorder or spy.","code":"landmines-testing(no-unsignaled-poll)","filename":"a/x.test.mjs","labels":[{"span":{"line":6,"column":3}}]},
{"message":"This file now has 0 unsignaled polls; lower it.","code":"landmines-testing(no-unsignaled-poll)","filename":"a/x.test.mjs","labels":[{"span":{"line":1,"column":1}}]}
],"number_of_files":1}
EOF
    stand_in "$REPO" oxlint "cat '$REPO/canned.out'; exit 1"
    run_gate_split "$REPO" "$PATH" --seed
    assert_eq "seed-excludes exits 0" 0 "$GATE_RC"
    expect='{"landmines-testing/no-fixed-sleep":{"a/x.test.mjs":1},"landmines-testing/no-flake-masking":{"a/x.test.mjs":1},"landmines-testing/no-unsignaled-poll":{"a/x.test.mjs":1}}'
    assert_eq "seed-excludes counts one per rule, never a retry or a stale line" "ok" "$(json_equal "$GATE_STDOUT" "$expect")"

    mk_repo || { fail "seed-empty (no temp repo)"; return; }
    git -C "$REPO" rm -q a/x.test.mjs
    stand_in "$REPO" bun 'exit 0' record
    run_gate_split "$REPO" "$REPO/bin:$PATH" --seed
    assert_eq "seed-empty-surface exits 0" 0 "$GATE_RC"
    assert_eq "seed-empty-surface prints three empty maps" "ok" \
        "$(json_equal "$GATE_STDOUT" '{"landmines-testing/no-fixed-sleep":{},"landmines-testing/no-flake-masking":{},"landmines-testing/no-unsignaled-poll":{}}')"
    assert_eq "seed-empty-surface runs no install" 0 "$(calls_count)"
}

seed_signal() {
    local sig="$1" want="$2" runner gate_pid msg before tmp
    mk_repo || { fail "seed-signal-$sig (no temp repo)"; return; }
    link_install "$REPO"
    mkfifo "$REPO/started.fifo" "$REPO/block.fifo" || { fail "seed-signal-$sig (mkfifo)"; return; }
    mkdir -p "$REPO/tmp"
    stand_in "$REPO" oxlint "echo \$PPID > '$REPO/gate.pid'; echo \$\$ > '$REPO/oxlint.pid'; echo started > '$REPO/started.fifo'; read -r _ < '$REPO/block.fifo'"
    before=$(sha256_of "$REPO/scripts/lint/landmines/.oxlintrc.json")
    exec 4<> "$REPO/started.fifo"
    set -m
    (
        cd "$REPO" || exit 99
        unset OXLINT_FAIL_CLOSED
        TMPDIR="$REPO/tmp" "$BASH_ABS" scripts/lint/check-test-honesty.sh --seed >"$REPO/seed.out" 2>"$REPO/seed.err" </dev/null
        echo "gate-exited $?" >&4
    ) &
    runner=$!
    set +m
    if ! read -r -t 60 -u 4 msg; then msg="timeout"; fi
    if [ "$msg" != started ]; then
        fail "seed-signal-$sig (oxlint stand-in never started: $msg)"
        kill -- "-$runner" 2>/dev/null
        exec 4>&-
        return
    fi
    gate_pid=$(cat "$REPO/gate.pid")
    assert_eq "seed-signal-$sig seed config exists while oxlint runs" 1 "$(seed_files_left)"
    kill "-$sig" "$gate_pid"
    if ! read -r -t 60 -u 4 msg; then msg="timeout"; fi
    assert_eq "seed-signal-$sig gate exits through its trap" "gate-exited $want" "$msg"
    if kill -0 "$(cat "$REPO/oxlint.pid")" 2>/dev/null; then
        fail "seed-signal-$sig leaves no oxlint process behind"
    else
        pass "seed-signal-$sig leaves no oxlint process behind"
    fi
    assert_eq "seed-signal-$sig leaves no seed config" 0 "$(seed_files_left)"
    assert_eq "seed-signal-$sig tracked config is byte-identical" "$before" "$(sha256_of "$REPO/scripts/lint/landmines/.oxlintrc.json")"
    tmp=$(find "$REPO/tmp" -mindepth 1 | head -n 1)
    assert_eq "seed-signal-$sig leaves no temp directory" "" "$tmp"
    kill -- "-$runner" 2>/dev/null
    wait "$runner" 2>/dev/null
    exec 4>&-
    assert_eq "seed-signal-$sig prints no maps" "" "$(cat "$REPO/seed.out")"
}

case_seed_signals() {
    seed_signal INT 130
    seed_signal TERM 143
}

case_triggers_and_usage() {
    mk_repo || { fail "gate-triggers (no temp repo)"; return; }
    stand_in "$REPO" bun 'exit 0' record
    hs "$REPO" --triggers
    run_gate "$REPO" 1 "$REPO/bin:$PATH" --triggers
    assert_eq "gate-triggers exits 0 with no node_modules" 0 "$GATE_RC"
    assert_eq "gate-triggers prints the surface script's regex" "$HS_OUT" "$GATE_OUT"
    assert_eq "gate-triggers runs no install" 0 "$(calls_count)"
    run_gate "$REPO" 0 "$PATH" --triggers extra
    assert_eq "gate-triggers with an argument is a usage error" 2 "$GATE_RC"
    run_gate "$REPO" 0 "$PATH" --seed --files
    assert_eq "gate-seed with an argument is a usage error" 2 "$GATE_RC"
    mk_tools "$REPO" "${BASE_TOOLS[@]}"
    run_gate "$REPO" 0 "$REPO/tools" --triggers
    assert_eq "gate-triggers without node exits 1" 1 "$GATE_RC"
}

case_i8_precommit_equals_triggers() {
    local want got
    want=$(cd "$REPO_ROOT" && node scripts/lint/honesty-surface.mjs --precommit-files 2>&1 </dev/null)
    got=$(awk '
/^[[:space:]]*-[[:space:]]+id:/ { inhook = ($0 ~ /id:[[:space:]]*test-honesty-ratchet[[:space:]]*$/); next }
inhook && /^[[:space:]]+files:[[:space:]]/ { sub(/^[[:space:]]+files:[[:space:]]+/, ""); print; exit }
' "$REPO_ROOT/.pre-commit-config.yaml")
    if [ -z "$got" ]; then
        fail "i8-precommit-equals-triggers (hook test-honesty-ratchet or its files: is missing)"
        return
    fi
    assert_eq "i8-precommit-equals-triggers" "$want" "$got"
}

case_seeded_config_keys_live() {
    local out rc
    out=$(cd "$REPO_ROOT" && node scripts/lint/honesty-surface.mjs --check-keys 2>&1 </dev/null)
    rc=$?
    assert_eq "seeded-config-keys-live" 0 "$rc"
    if [ "$rc" -ne 0 ]; then echo "     $out"; fi
}

ci_block() {
    sed -n '/^ *# test-honesty gate$/,/^ *# end test-honesty gate$/p' "$REPO_ROOT/.github/workflows/ci.yml"
}

ci_run() {
    local scope="$1" changed="$2"
    shift 2
    ci_block > "$REPO/block.sh"
    cat > "$REPO/driver.sh" <<'EOS'
scope=$1
changed=$2
shift 2
rc=0
. ./block.sh
echo "rc=$rc"
EOS
    rm -f "$REPO/calls.log"
    mkdir -p "$REPO/runner-temp"
    (cd "$REPO" && BASE_SHA="${CI_BASE:-}" RUNNER_TEMP="$REPO/runner-temp" PATH="${CI_PATH:-$PATH}" \
        "$BASH_ABS" -eo pipefail driver.sh "$scope" "$changed" "$@" >driver.out 2>&1 </dev/null)
    CI_RC=$?
    CI_CALLS=$(cat "$REPO/calls.log" 2>/dev/null)
}

ci_commit() {
    local p
    CI_BASE=$(git -C "$REPO" rev-parse HEAD)
    for p in "$@"; do
        mkdir -p "$REPO/$(dirname "$p")"
        printf '%s\n' "change after $CI_BASE" >> "$REPO/$p"
    done
    git -C "$REPO" add -- "$@"
    git -C "$REPO" commit -q -m "ci change"
    git -C "$REPO" diff --name-only -z "$CI_BASE" HEAD > "$REPO/changed.lst"
}

ci_block_placed() {
    awk '
/^ *- name: skill size \+ oxlint complexity\/hardening$/ { step = 1; next }
step && /^ *- [a-z-]+:/ { step = 0 }
step && !done_at && /^ *done < "\$changed"( *# .*)?$/ { done_at = NR }
step && /^ *exit "\$rc"$/ { exit_at = NR }
!start_at && /^ *# test-honesty gate$/ { start_at = NR; start_in = step }
!end_at && /^ *# end test-honesty gate$/ { end_at = NR; end_in = step }
END {
    if (!start_at) print "no start marker"
    else if (!start_in) print "start marker outside the lint step"
    else if (!done_at || done_at > start_at) print "start marker before the files loop"
    else if (!end_in) print "end marker outside the lint step"
    else if (!exit_at) print "no exit in the lint step"
    else if (exit_at < end_at) print "end marker after the step'"'"'s exit"
    else print "ok"
}
' "$1"
}

case_ci_scope_branches() {
    local n_start n_end fx
    n_start=$(grep -c '^ *# test-honesty gate$' "$REPO_ROOT/.github/workflows/ci.yml")
    n_end=$(grep -c '^ *# end test-honesty gate$' "$REPO_ROOT/.github/workflows/ci.yml")
    assert_eq "ci-scope-branches has one start marker" 1 "$n_start"
    assert_eq "ci-scope-branches has one end marker" 1 "$n_end"
    assert_eq "ci-scope-branches block sits after the files loop in the lint step" ok "$(ci_block_placed "$REPO_ROOT/.github/workflows/ci.yml")"
    mk_repo || { fail "ci-scope-branches (no temp repo)"; return; }
    fx="$REPO/placement.yml"
    cat > "$fx" <<'EOS'
      - name: skill size + oxlint complexity/hardening
        run: |
          # test-honesty gate
          set --
            done < "$changed" # read-sink-ok: fixture text for the placement check, never executed
EOS
    assert_eq "ci-scope-branches placement check refuses a block above the files loop" "start marker before the files loop" "$(ci_block_placed "$fx")"
    cat > "$fx" <<'EOS'
      - name: skill size + oxlint complexity/hardening
        run: |
            done < "$changed" # read-sink-ok: fixture text for the placement check, never executed
      - name: another step
        run: |
          # test-honesty gate
EOS
    assert_eq "ci-scope-branches placement check refuses a block in a later step" "start marker outside the lint step" "$(ci_block_placed "$fx")"
    cat > "$fx" <<'EOS'
      - name: skill size + oxlint complexity/hardening
        run: |
            done < "$changed" # read-sink-ok: fixture text for the placement check, never executed
          exit "$rc"
          # test-honesty gate
          # end test-honesty gate
EOS
    assert_eq "ci-scope-branches placement check refuses a block after the step's exit" "end marker after the step's exit" "$(ci_block_placed "$fx")"
    cat > "$fx" <<'EOS'
      - name: skill size + oxlint complexity/hardening
        run: |
            done < "$changed" # read-sink-ok: fixture text for the placement check, never executed
          # test-honesty gate
          # end test-honesty gate
      - name: another step
        run: |
          exit "$rc"
EOS
    assert_eq "ci-scope-branches placement check refuses a lint step with no exit" "no exit in the lint step" "$(ci_block_placed "$fx")"
    run_gate "$REPO" 1 "$PATH" --files README.md
    assert_eq "ci-scope-branches real gate on README.md exits 0" 0 "$GATE_RC"
    assert_has "ci-scope-branches real gate on README.md says nothing to lint" "nothing to lint" "$GATE_OUT"

    cat > "$REPO/scripts/lint/check-test-honesty.sh" <<'EOS'
printf 'argc=%s argv=%s\n' "$#" "$*" >> calls.log
exit "${GATE_EXIT:-0}"
EOS
    ci_commit scripts/lint/ticket-ref-allow.tsv
    ci_run files changed.lst scripts/lint/ticket-ref-allow.tsv
    assert_eq "ci-scope-branches ticket-ref-allow.tsv runs the full surface" "argc=0 argv=" "$CI_CALLS"
    ci_commit scripts/lint/landmines/bun.lock scripts/foo.test.ts
    ci_run files changed.lst scripts/lint/landmines/bun.lock scripts/foo.test.ts
    assert_eq "ci-scope-branches a trigger among others runs the full surface" "argc=0 argv=" "$CI_CALLS"
    ci_commit README.md
    ci_run files changed.lst README.md
    assert_eq "ci-scope-branches README.md runs --files" "argc=2 argv=--files README.md" "$CI_CALLS"
    assert_eq "ci-scope-branches README.md block exits 0" 0 "$CI_RC"
    ci_run all "$REPO/no-such-changed-list" README.md
    assert_eq "ci-scope-branches scope=all runs the full surface" "argc=0 argv=" "$CI_CALLS"
    assert_has "ci-scope-branches scope=all does not read the list" "rc=0" "$(cat "$REPO/driver.out")"

    git -C "$REPO" config diff.renames true
    ci_commit x/VENDORED.md
    CI_BASE=$(git -C "$REPO" rev-parse HEAD)
    git -C "$REPO" mv x/VENDORED.md x/VENDORED.txt
    git -C "$REPO" commit -q -m "rename"
    git -C "$REPO" diff --name-only -z "$CI_BASE" HEAD > "$REPO/changed.lst"
    assert_eq "ci-scope-branches rename precondition: the changed list holds only the new path" "x/VENDORED.txt" "$(tr '\0' '\n' < "$REPO/changed.lst")"
    ci_run files changed.lst x/VENDORED.txt
    assert_eq "ci-scope-branches a renamed VENDORED.md runs the full surface" "argc=0 argv=" "$CI_CALLS"
    ci_commit scripts/foo.test.ts
    CI_BASE=0000000000000000000000000000000000000000 ci_run files changed.lst scripts/foo.test.ts
    assert_eq "ci-scope-branches a rename-free diff that fails runs the full surface" "argc=0 argv=" "$CI_CALLS"

    ci_commit scripts/foo.test.ts
    ci_run files changed.lst scripts/foo.test.ts
    assert_eq "ci-scope-branches a test file runs --files" "argc=2 argv=--files scripts/foo.test.ts" "$CI_CALLS"
    GATE_EXIT=1 ci_run files changed.lst scripts/foo.test.ts
    assert_has "ci-scope-branches a failing gate sets rc=1" "rc=1" "$(cat "$REPO/driver.out")"
    GATE_EXIT=1 ci_run all x
    assert_has "ci-scope-branches a failing full gate sets rc=1" "rc=1" "$(cat "$REPO/driver.out")"

    stand_in "$REPO" node 'exit 1'
    CI_PATH="$REPO/bin:$PATH" ci_run files changed.lst scripts/foo.test.ts
    assert_eq "ci-scope-branches a failing --triggers runs the full surface" "argc=0 argv=" "$CI_CALLS"
    stand_in "$REPO" node 'echo "("'
    CI_PATH="$REPO/bin:$PATH" ci_run files changed.lst scripts/foo.test.ts
    assert_eq "ci-scope-branches an invalid trigger regex runs the full surface" "argc=0 argv=" "$CI_CALLS"
    stand_in "$REPO" node 'exit 0'
    CI_PATH="$REPO/bin:$PATH" ci_run files changed.lst scripts/foo.test.ts
    assert_eq "ci-scope-branches an empty trigger list runs the full surface" "argc=0 argv=" "$CI_CALLS"
}

case_i3_real_marker_untouched() {
    local now
    if [ -f "$REAL_MARKER" ]; then
        now="present $(sha256_of "$REAL_MARKER")"
    else
        now="absent"
    fi
    assert_eq "i3-real-marker-untouched" "$REAL_MARKER_BEFORE" "$now"
}

case_i4_oxlint_pin_equals_hardening
case_i5_exact_pins
case_package_shape
case_config_shape
case_harness_smoke
case_i6_surface
case_surface_row_missing
case_i2_keys
case_i7_directives
case_i8_triggers
case_i3_node
case_node_range_within_engines
case_gate_matches_literal
case_i3_install
case_i3_version_mismatch
case_package_shape_gate
case_resolved_specifier
case_tracked_node_modules
case_suppressions_file
case_node_modules_symlink
case_package_dir_symlink
case_gate_early_exits
case_i1_rules
case_i2_stale_and_count
case_i3_unevaluated
case_large_findings_whole
case_clean_success_line
case_i3_step_order
case_i7_through_gate
case_seed
case_seed_signals
case_triggers_and_usage
case_i8_precommit_equals_triggers
case_seeded_config_keys_live
case_ci_scope_branches
case_i3_real_marker_untouched

echo ""
echo "$PASSED passed, $FAILED failed"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
