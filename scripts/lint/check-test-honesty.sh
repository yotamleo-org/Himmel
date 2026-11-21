#!/usr/bin/env bash
# Test-honesty ratchet gate: pinned oxlint plus @interfere/landmines over the
# test surface (scripts/lint/honesty-surface.mjs), against the per-file allow
# maps in scripts/lint/landmines/.oxlintrc.json.
#
# Usage: check-test-honesty.sh [--files PATH...]
#   exit 0  clean, or nothing to lint
#   exit 1  a finding, a refusal, or a run the gate could not evaluate
#   exit 2  usage error
#
# Only a missing `node`, or a missing `bun` when an install is needed, fails
# open, and only outside CI: OXLINT_FAIL_CLOSED=1 turns both into exit 1. Every
# other doubt (wrong node, bad config, failed install, version mismatch,
# redirected plugin) is exit 1.
set -uo pipefail

NODE_RANGE='^22.18.0 || >=24.11.0'
PKG_REL=scripts/lint/landmines
SURFACE=scripts/lint/honesty-surface.mjs

refuse() {
    echo "check-test-honesty: $*" >&2
    exit 1
}

# A missing tool that may be skipped locally: WARN and exit 0, or exit 1 in CI.
fail_open() {
    echo "WARN check-test-honesty: $* (fail-open)" >&2
    [ "${OXLINT_FAIL_CLOSED:-}" = 1 ] && exit 1
    exit 0
}

# ---- arguments ----------------------------------------------------------------
files_mode=0
paths=()
case "${1:-}" in
    "") ;;
    --files)
        files_mode=1
        shift
        paths=("$@")
        ;;
    *)
        echo "usage: $(basename "$0") [--files PATH...]" >&2
        exit 2
        ;;
esac

# ---- 1. repo root -------------------------------------------------------------
cwd=$(pwd -P)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$cwd")
if [ -d "$repo_root" ]; then
    if canonical_root=$(cd "$repo_root" 2>/dev/null && pwd -P); then
        repo_root="$canonical_root"
    fi
fi
# A resolver may be stubbed or otherwise return a non-ancestor. Refuse before
# changing directory: linting a different tree is not a successful gate.
case "$cwd/" in
    "$repo_root/"*) ;;
    *) refuse "cwd $cwd is outside the resolved root $repo_root - refusing to lint an unrelated tree" ;;
esac
cd "$repo_root" || refuse "cannot enter the resolved root $repo_root"

# ---- 2. node ------------------------------------------------------------------
command -v node >/dev/null 2>&1 || fail_open "node not found on PATH - skipping the test-honesty gate"
node_v=$(node --version 2>/dev/null) || node_v=""
node_ok=0
if [[ "$node_v" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    node_major=$((10#${BASH_REMATCH[1]}))
    node_minor=$((10#${BASH_REMATCH[2]}))
    if [ "$node_major" -eq 22 ] && [ "$node_minor" -ge 18 ]; then node_ok=1; fi
    if [ "$node_major" -eq 24 ] && [ "$node_minor" -ge 11 ]; then node_ok=1; fi
    if [ "$node_major" -ge 25 ]; then node_ok=1; fi
fi
[ "$node_ok" = 1 ] || refuse "node '${node_v:-unknown}' is outside $NODE_RANGE"

# ---- 3. config shape and allow keys -------------------------------------------
if ! keys_out=$(node "$SURFACE" --check-keys 2>&1); then
    printf '%s\n' "$keys_out" >&2
    refuse "config shape or allow keys refused"
fi

# ---- 4. file list -------------------------------------------------------------
list_out=""
if [ "$files_mode" = 0 ]; then
    list_out=$(node "$SURFACE" --list) || refuse "cannot list the test surface"
elif [ "${#paths[@]}" -gt 0 ]; then
    list_out=$(node "$SURFACE" --list "${paths[@]}") || refuse "cannot list the test surface"
fi
files=()
while IFS= read -r line; do
    if [ -n "$line" ]; then files+=("$line"); fi
done <<EOF
$list_out
EOF
if [ "${#files[@]}" -eq 0 ]; then
    echo "check-test-honesty: nothing to lint"
    exit 0
fi

# ---- 5. install, versions, resolved plugin ------------------------------------
# Both spellings: the slash form misses a tracked symlink named node_modules.
tracked=$(git ls-files -- "$PKG_REL/node_modules" "$PKG_REL/node_modules/") || refuse "cannot list tracked files under $PKG_REL/node_modules/"
[ -z "$tracked" ] || refuse "tracked files under $PKG_REL/node_modules/ - the install must never be committed"
[ ! -L "$PKG_REL/node_modules" ] || refuse "$PKG_REL/node_modules is a symlink - the install must be a real directory"

lock="$PKG_REL/bun.lock"
[ -f "$lock" ] || refuse "$lock is missing"
if command -v sha256sum >/dev/null 2>&1; then
    lock_sha=$(sha256sum "$lock" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    lock_sha=$(shasum -a 256 "$lock" | cut -d' ' -f1)
else
    lock_sha=""
fi
[ -n "$lock_sha" ] || refuse "no sha256 tool to hash $lock"

marker="$PKG_REL/node_modules/.lock-sha256"
marker_sha=""
if [ -f "$marker" ]; then marker_sha=$(<"$marker"); fi
if [ "$marker_sha" != "$lock_sha" ]; then
    command -v bun >/dev/null 2>&1 || fail_open "bun not found on PATH and the install is missing or stale - skipping the test-honesty gate"
    (cd "$PKG_REL" && bun install --frozen-lockfile >&2) || refuse "bun install --frozen-lockfile failed in $PKG_REL"
    mkdir -p "$PKG_REL/node_modules" || refuse "cannot create $PKG_REL/node_modules"
    printf '%s\n' "$lock_sha" > "$marker" || refuse "cannot write $marker"
fi

# The lint package.json has exactly the expected shape, the installed versions
# of the three direct dependencies equal its pins, and the plugin specifier
# resolves to the installed plugin under both CommonJS and ESM conditions, not
# to a local redirect. Run as an ES module from the package dir so that
# import.meta.resolve is anchored there.
read -r -d '' check_install_js <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
const pkgDir = path.join(process.argv[1], "scripts/lint/landmines");
const say = (m) => console.error("check-test-honesty: " + m);
const names = ["@babel/parser", "@interfere/landmines", "oxlint"];
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
try {
  const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
  const shapeOk = isObject(pkg)
    && isDeepStrictEqual(Object.keys(pkg).sort(), ["dependencies", "private"])
    && pkg.private === true
    && isObject(pkg.dependencies)
    && isDeepStrictEqual(Object.keys(pkg.dependencies).sort(), names)
    && names.every((n) => /^[0-9]+\.[0-9]+\.[0-9]+$/.test(pkg.dependencies[n]));
  if (!shapeOk) {
    say('lint package.json shape: expected exactly {"private":true,"dependencies":{"@babel/parser","@interfere/landmines","oxlint": exact versions}} and no other key');
    process.exit(1);
  }
  const deps = pkg.dependencies;
  let bad = false;
  for (const name of ["oxlint", "@interfere/landmines", "@babel/parser"]) {
    const pin = deps && deps[name];
    let got = "unreadable";
    try {
      const inst = JSON.parse(fs.readFileSync(path.join(pkgDir, "node_modules", name, "package.json"), "utf8"));
      got = inst.name === name ? inst.version : "a package named " + inst.name;
    } catch {
      got = "unreadable";
    }
    if (typeof pin !== "string" || got !== pin) {
      say(`version mismatch: ${name} installed ${got}, pinned ${pin}`);
      bad = true;
    }
  }
  if (bad) process.exit(1);
  const specifier = "@interfere/landmines/testing";
  const want = fs.realpathSync(path.join(pkgDir, "node_modules/@interfere/landmines/dist/testing.mjs"));
  const viaRequire = fs.realpathSync(createRequire(path.join(pkgDir, "package.json")).resolve(specifier));
  const viaImport = fs.realpathSync(fileURLToPath(import.meta.resolve(specifier)));
  for (const [how, got] of [["require", viaRequire], ["import", viaImport]]) {
    if (got !== want) {
      say(`${specifier} resolves to ${got} (${how}), not the installed plugin ${want}`);
      process.exit(1);
    }
  }
} catch (err) {
  say(`install check failed: ${err.message}`);
  process.exit(1);
}
EOF
(cd "$PKG_REL" && node --input-type=module -e "$check_install_js" "$repo_root" </dev/null) || refuse "install not verified - refusing to pass an unevaluated run"

exit 0
