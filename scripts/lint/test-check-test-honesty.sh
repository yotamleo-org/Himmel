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

# --- honesty-surface.mjs -----------------------------------------------------

# hs <dir> ARGS...: the surface script with cwd inside the temp repo. Sets HS_OUT, HS_RC.
hs() {
    local dir="$1"
    shift
    HS_OUT=$(cd "$dir" && node scripts/lint/honesty-surface.mjs "$@" 2>&1 </dev/null)
    HS_RC=$?
}

# mk_repo: a fresh committed temp repo in REPO.
mk_repo() {
    REPO=$(fixture_mktemp_dir) || return 1
    CLEANUP_PATHS+=("$REPO")
    new_temp_repo "$REPO"
}

# put <relpath> [content]: write a file into REPO.
put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "${2:-x}" > "$REPO/$1"
}

# edit_cfg <js body over c>: mutate the temp repo's config.
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

# dir_row <id> <inner|top|tail> <directive> <refuse|pass>
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
    hs "$REPO" --check-directives a/dir-01.test.ts
    assert_has "i7-directive-table refusal names path, line and text" \
        'a/dir-01.test.ts:3: refused directive: "oxlint-disable-next-line landmines-testing/no-fixed-sleep' "$HS_OUT"

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
        .github/workflows/ci.yml .pre-commit-config.yaml; do
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

case_i4_oxlint_pin_equals_hardening
case_i5_exact_pins
case_f1_package_shape
case_config_shape
case_harness_smoke
case_i6_surface
case_surface_row_missing
case_i2_keys
case_i7_directives
case_i8_triggers

echo ""
echo "$PASSED passed, $FAILED failed"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
