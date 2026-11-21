#!/usr/bin/env bash
# Test-honesty ratchet gate: pinned oxlint plus @interfere/landmines over the
# test surface (scripts/lint/honesty-surface.mjs), against the per-file allow
# maps in scripts/lint/landmines/.oxlintrc.json.
#
# Usage: check-test-honesty.sh [--files PATH...] | --seed | --triggers
#   exit 0  clean (the one line "test-honesty: clean (<n> files)"), or nothing to lint
#   exit 1  a finding, a refusal, or a run the gate could not evaluate
#   exit 2  usage error
#   --seed      print the three allow maps for the whole surface, counted against
#               a copy of the config with the maps emptied; never writes the
#               tracked config
#   --triggers  print the regex of paths whose change forces a full-surface run
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

fail_open() {
    echo "WARN check-test-honesty: $* (fail-open)" >&2
    [ "${OXLINT_FAIL_CLOSED:-}" = 1 ] && exit 1
    exit 0
}

files_mode=0
seed_mode=0
triggers_mode=0
paths=()
usage() {
    echo "usage: $(basename "$0") [--files PATH...] | --seed | --triggers" >&2
    exit 2
}
case "${1:-}" in
    "") ;;
    --files)
        files_mode=1
        shift
        paths=("$@")
        ;;
    --seed)
        [ "$#" -eq 1 ] || usage
        seed_mode=1
        ;;
    --triggers)
        [ "$#" -eq 1 ] || usage
        triggers_mode=1
        ;;
    *) usage ;;
esac

cwd=$(pwd -P)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$cwd")
if [ -d "$repo_root" ]; then
    if canonical_root=$(cd "$repo_root" 2>/dev/null && pwd -P); then
        repo_root="$canonical_root"
    fi
fi
case "$cwd/" in
    "$repo_root/"*) ;;
    *) refuse "cwd $cwd is outside the resolved root $repo_root - refusing to lint an unrelated tree" ;;
esac
cwd_rel=${cwd#"$repo_root"}
cwd_rel=${cwd_rel#/}
if [ -n "$cwd_rel" ] && [ "${#paths[@]}" -gt 0 ]; then
    for i in "${!paths[@]}"; do
        case "${paths[$i]}" in
            /*) ;;
            *) paths[i]="$cwd_rel/${paths[$i]}" ;;
        esac
    done
fi
cd "$repo_root" || refuse "cannot enter the resolved root $repo_root"

if [ "$triggers_mode" = 1 ]; then
    command -v node >/dev/null 2>&1 || refuse "node not found on PATH - cannot print the trigger regex"
    exec node "$SURFACE" --triggers
fi

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

if ! keys_out=$(node "$SURFACE" --check-keys 2>&1); then
    printf '%s\n' "$keys_out" >&2
    refuse "config shape or allow keys refused"
fi

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
    if [ "$seed_mode" = 1 ]; then
        printf '%s\n' '{"landmines-testing/no-fixed-sleep":{},"landmines-testing/no-flake-masking":{},"landmines-testing/no-unsignaled-poll":{}}'
        exit 0
    fi
    echo "check-test-honesty: nothing to lint"
    exit 0
fi

pkg_real=$(cd "$PKG_REL" 2>/dev/null && pwd -P) || pkg_real=""
[ "$pkg_real" = "$repo_root/$PKG_REL" ] || refuse "$PKG_REL is reached through a symlink (it resolves to '${pkg_real:-nothing}') - the lint package must be a real directory in this repo"
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

if ! dir_out=$(node "$SURFACE" --check-directives "${files[@]}" 2>&1 </dev/null); then
    printf '%s\n' "$dir_out" >&2
    refuse "refused disable directive, or a file that did not parse"
fi

tmp_dir=""
seed_cfg=""
child=""
# shellcheck disable=SC2317,SC2329 # invoked by the traps below
cleanup() {
    if [ -n "$child" ]; then
        kill "$child" 2>/dev/null
        wait "$child" 2>/dev/null
        child=""
    fi
    if [ -n "$seed_cfg" ]; then rm -f -- "$seed_cfg"; fi
    if [ -n "$tmp_dir" ]; then rm -rf -- "$tmp_dir"; fi
}
# shellcheck disable=SC2317,SC2329 # invoked by the traps below
on_signal() {
    trap - EXIT INT TERM HUP
    cleanup
    exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-honesty.XXXXXX") || refuse "cannot create a temp directory" # prim-ok: the suite runs a lone copy of this gate in temp repos that carry no scripts/lib

config="$PKG_REL/.oxlintrc.json"
if [ "$seed_mode" = 1 ]; then
    config="$PKG_REL/.oxlintrc.seed.$$.json"
    seed_cfg="$repo_root/$config"
    node -e '
const fs = require("node:fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const entry of Object.values(cfg.rules)) entry[1].allow = {};
fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + "\n");
' "$PKG_REL/.oxlintrc.json" "$seed_cfg" </dev/null || refuse "cannot write the seed config"
fi

# Background plus wait, so a signal reaches the trap while oxlint runs.
"$PKG_REL/node_modules/.bin/oxlint" -c "$config" --format json -- "${files[@]}" \
    >"$tmp_dir/oxlint.out" 2>"$tmp_dir/oxlint.err" </dev/null &
child=$!
wait "$child"
ox_rc=$?
child=""

# The exit code is set, never forced, so a long stdout through a pipe is not cut.
read -r -d '' eval_js <<'EOF'
const fs = require("node:fs");
const [mode, rcArg, wantArg, file] = process.argv.slice(1);
const RULES = ["no-fixed-sleep", "no-flake-masking", "no-unsignaled-poll"].map((r) => "landmines-testing/" + r);
const STALE = "This file now has";
const RETRY = "Do not retry tests";
const HINT = "the entry above is in scripts/lint/landmines/.oxlintrc.json, not .oxlintrc.jsonc";
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const unevaluated = (m) => {
  throw new Error(m);
};
const main = () => {
  const rc = Number(rcArg);
  const want = Number(wantArg);
  let out;
  try {
    out = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    unevaluated("stdout is not JSON (" + err.message + ")");
  }
  if (!isObject(out) || !Array.isArray(out.diagnostics)) unevaluated("no diagnostics array in the output");
  if (out.number_of_files !== want) unevaluated("number_of_files is " + JSON.stringify(out.number_of_files) + ", expected " + want);
  if (rc !== 0 && rc !== 1) unevaluated("exit code " + rc);
  if ((rc === 0) !== (out.diagnostics.length === 0)) unevaluated("exit code " + rc + " disagrees with " + out.diagnostics.length + " diagnostics");
  const found = out.diagnostics.map((d) => {
    const span = isObject(d) && Array.isArray(d.labels) && isObject(d.labels[0]) ? d.labels[0].span : null;
    const ok = isObject(d)
      && typeof d.filename === "string" && d.filename !== ""
      && typeof d.code === "string" && d.code !== ""
      && typeof d.message === "string"
      && isObject(span) && Number.isInteger(span.line) && span.line >= 1;
    if (!ok) unevaluated("a diagnostic lacks a file, a line or a rule code: " + JSON.stringify(d).slice(0, 200));
    return { file: d.filename, line: span.line, col: Number.isInteger(span.column) ? span.column : 0, code: d.code, message: d.message };
  });
  if (mode === "seed") {
    const maps = Object.fromEntries(RULES.map((r) => [r, {}]));
    for (const f of found) {
      const rule = f.code.replace(/^(.*)\((.*)\)$/, "$1/$2");
      if (!RULES.includes(rule) || f.message.startsWith(STALE) || f.message.startsWith(RETRY)) continue;
      maps[rule][f.file] = (maps[rule][f.file] || 0) + 1;
    }
    for (const r of RULES) maps[r] = Object.fromEntries(Object.entries(maps[r]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    console.log(JSON.stringify(maps, null, 2));
    return 0;
  }
  for (const f of found) {
    console.log(`${f.file}:${f.line}:${f.col} ${f.code} ${f.message}`);
    const rule = f.code.replace(/^(.*)\((.*)\)$/, "$1/$2");
    if (RULES.includes(rule) && f.message.startsWith(STALE)) console.log(HINT);
  }
  return found.length === 0 ? 0 : 10;
};
try {
  process.exitCode = main();
} catch (err) {
  console.error("check-test-honesty: oxlint run unevaluated: " + err.message);
  process.exitCode = 2;
}
EOF
eval_mode=run
if [ "$seed_mode" = 1 ]; then eval_mode=seed; fi
node -e "$eval_js" "$eval_mode" "$ox_rc" "${#files[@]}" "$tmp_dir/oxlint.out" </dev/null
eval_rc=$?
if [ "$eval_rc" -ne 0 ] && [ "$eval_rc" -ne 10 ]; then
    if [ -s "$tmp_dir/oxlint.err" ]; then cat "$tmp_dir/oxlint.err" >&2; fi
    refuse "the oxlint run could not be evaluated - refusing to pass an unevaluated run"
fi

if [ "$seed_mode" = 1 ]; then exit 0; fi
[ "$eval_rc" -eq 0 ] || exit 1
echo "test-honesty: clean (${#files[@]} files)"
exit 0
